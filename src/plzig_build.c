/*-------------------------------------------------------------------------
 *
 * plzig_build.c
 *	  Compile pipeline: content-addressed cache, compile lock, private build
 *	  directory, policy validator, compiler, install into the cache.
 *
 * Every path is built from fixed names, the backend pid, a counter, random
 * hex and hex digests; nothing comes from user input.  Files are opened with
 * O_NOFOLLOW through PostgreSQL's transient-file wrappers (closed
 * automatically on ERROR); the recursive delete works relative to directory
 * descriptors and never follows symlinks or crosses file systems.
 *
 * Messages that can reach the client never contain the data directory:
 * paths under it are shown relative to it (the backend's working
 * directory), the full path goes to the server log only (errdetail_log).
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "common/cryptohash.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#ifdef __linux__
#include <elf.h>
#endif
#include "port.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "utils/memutils.h"
#include "utils/wait_event.h"

#define PLZIG_DIR_NAME		"plzig"
#define PLZIG_CACHE_NAME	"cache"
#define PLZIG_ZIGCACHE_NAME	"pgsql_tmp.zig-cache"	/* skipped by base backups */
#define PLZIG_BUILD_PREFIX	"pgsql_tmp.build."
#define PLZIG_LOCK_NAME		"compile.lock"

/* recursive delete: deepest directory level descended into */
#define PLZIG_RMTREE_MAX_DEPTH	64
/* a cache hit refreshes the module's mtime (LRU) if older than this */
#define PLZIG_CACHE_TOUCH_SECS	60

static char plzig_sandbox_status[512] = "no compilation in this session";
static bool plzig_sandbox_logged = false;
static bool plzig_exit_registered = false;
static unsigned int plzig_build_counter = 0;
static char plzig_current_build_dir[MAXPGPATH] = "";

/* SDK files and their digest, loaded once per backend */
static char *plzig_sdk_plzig = NULL;
static size_t plzig_sdk_plzig_len = 0;
static char *plzig_sdk_root = NULL;
static size_t plzig_sdk_root_len = 0;
static char plzig_sdk_digest[65] = "";

/*
 * The configured Zig toolchain as last checked in this backend.  Path,
 * ownership and mode checks run before every compile; the expensive part
 * (checksum, running `zig version`) is redone only when a setting or the
 * identity of the binary or lib directory changes.
 */
typedef struct PlzigToolchain
{
	bool		verified;		/* checksum + version passed for the below */
	char		set_path[MAXPGPATH];	/* settings at verification time */
	char		set_lib[MAXPGPATH];
	char		set_sha[MAXPGPATH];
	char		bin[MAXPGPATH]; /* resolved compiler binary */
	char		lib[MAXPGPATH]; /* resolved lib directory */
	struct stat bin_st;
	struct stat lib_st;
} PlzigToolchain;

static PlzigToolchain plzig_tc;
static bool plzig_tc_show_paths = false;	/* superuser: paths in errdetail */

/* fixed compiler flags (part of the cache key) */
static const char *const plzig_zig_flags[] = {
	"build-exe",
	"--color", "off",
	"-fno-reference-trace",
	"-target", "wasm32-freestanding",
	"-mcpu", "mvp",
	"-O", "ReleaseSafe",
	"-fstrip",
	"-fno-entry",
	"-fsingle-threaded",
	"--stack", "262144",
	"--export=plzig_abi_version",
	"--export=plzig_init",
	"--export=plzig_alloc_args",
	"--export=plzig_call",
	"--dep", "plzig",
	"--dep", "user",
	"-Mroot=sdk/root.zig",
	"--dep", "plzig",
	"-Muser=src/user.zig",
	"-Mplzig=sdk/plzig.zig",
	"--name", "plzig_module",
	"-femit-bin=out.wasm",
	NULL
};

static bool plzig_realpath(const char *path, char *out);

const char *
plzig_sandbox_status_string(void)
{
	return plzig_sandbox_status;
}

/* ---------------------------------------------------------------------
 * Paths and directories
 * ---------------------------------------------------------------------
 */
/*
 * How a path is shown in messages that may reach the client: paths inside
 * the data directory relative to it (it is the backend's working directory,
 * like PostgreSQL's own "base/16384/..."), anything else unchanged.
 */
const char *
plzig_display_path(const char *path)
{
	size_t		n = strlen(DataDir);

	if (n > 0 && strncmp(path, DataDir, n) == 0 && path[n] == '/')
		return path + n + 1;
	return path;
}

static void
plzig_path(char *dst, const char *fmt,...) pg_attribute_printf(2, 3);

static void
plzig_path(char *dst, const char *fmt,...)
{
	va_list		ap;
	int			n;

	va_start(ap, fmt);
	n = vsnprintf(dst, MAXPGPATH, fmt, ap);
	va_end(ap);
	if (n < 0 || n >= MAXPGPATH)
		ereport(ERROR,
				(errcode(ERRCODE_NAME_TOO_LONG),
				 errmsg("PL/Zig: path too long")));
}

/*
 * Make sure path is a real directory (not a symlink) owned by us with no
 * group/other permissions, creating it (0700) if missing.
 */
static void
plzig_ensure_private_dir(const char *path)
{
	struct stat st;
	const char *shown = plzig_display_path(path);

	if (lstat(path, &st) != 0)
	{
		if (errno != ENOENT)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not stat directory \"%s\": %m", shown),
					 errdetail_log("Full path: \"%s\".", path)));
		if (mkdir(path, S_IRWXU) != 0 && errno != EEXIST)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not create directory \"%s\": %m", shown),
					 errdetail_log("Full path: \"%s\".", path)));
		if (lstat(path, &st) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not stat directory \"%s\": %m", shown),
					 errdetail_log("Full path: \"%s\".", path)));
	}
	if (!S_ISDIR(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: \"%s\" is not a directory (or is a symbolic link)", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if (st.st_uid != geteuid())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: directory \"%s\" is not owned by the server user", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if ((st.st_mode & (S_IRWXG | S_IRWXO)) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: directory \"%s\" has group or other permissions", shown),
				 errdetail_log("Full path: \"%s\".", path),
				 errhint("Permissions should be u=rwx (0700).")));
}

static void
plzig_dirs(char *root, char *cache, char *zigcache)
{
	plzig_path(root, "%s/%s", DataDir, PLZIG_DIR_NAME);
	plzig_path(cache, "%s/%s", root, PLZIG_CACHE_NAME);
	plzig_path(zigcache, "%s/%s", root, PLZIG_ZIGCACHE_NAME);
	plzig_ensure_private_dir(root);
	plzig_ensure_private_dir(cache);
	plzig_ensure_private_dir(zigcache);
}

/*
 * Recursive delete.
 *
 * A child process that survived (or a compromised compiler, while it ran)
 * may rename entries and swap a directory for a symbolic link at any
 * moment, so nothing is resolved by path: each directory is opened relative
 * to its parent's descriptor with O_NOFOLLOW|O_DIRECTORY, checked to be on
 * the same file system as the top directory, read with fdopendir() and its
 * entries removed with unlinkat().  A symbolic link is only ever unlinked
 * itself.  Depth is bounded.
 *
 * Raw descriptors are open during the walk, so it never raises an error and
 * never allocates: the first problem is remembered, everything is closed,
 * and only then is it reported at `elevel` (WARNING or LOG).  It is safe in
 * PG_FINALLY blocks and in the exit callback.
 */
typedef struct PlzigRmState
{
	dev_t		dev;			/* file system of the top directory */
	int			err;			/* first errno seen, 0 = none */
	const char *what;			/* the operation that failed */
	bool		too_deep;
	bool		other_fs;
} PlzigRmState;

static void
plzig_rm_fail(PlzigRmState *st, const char *what, int err)
{
	if (st->err == 0)
	{
		st->err = err != 0 ? err : EIO;
		st->what = what;
	}
}

/* remove `name` (any type) from the directory open as dfd */
static void
plzig_rm_at(int dfd, const char *name, int depth, PlzigRmState *st)
{
	int			attempt;

	/* a few attempts in case the entry is swapped while we look at it */
	for (attempt = 0; attempt < 4; attempt++)
	{
		struct stat sb;
		struct dirent *de;
		DIR		   *d;
		int			fd;
		int			pass;
		int			uerr;

		/* anything but a directory, including a symbolic link, goes now */
		if (unlinkat(dfd, name, 0) == 0 || errno == ENOENT)
			return;
		uerr = errno;
		if (uerr != EISDIR && uerr != EPERM)
		{
			plzig_rm_fail(st, "unlink", uerr);
			return;
		}

		if (depth >= PLZIG_RMTREE_MAX_DEPTH)
		{
			st->too_deep = true;
			return;
		}
		if (!AcquireExternalFD())
		{
			plzig_rm_fail(st, "open directory", EMFILE);
			return;
		}
		fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (fd < 0)
		{
			int			save = errno;

			ReleaseExternalFD();
			if (save == ENOENT)
				return;
			if ((save == ELOOP || save == ENOTDIR) && uerr == EISDIR)
				continue;		/* no longer a directory: unlink it */
			if (save == ELOOP || save == ENOTDIR)
				save = uerr;	/* not a directory, and unlink refused */
			plzig_rm_fail(st, "open directory", save);
			return;
		}
		if (fstat(fd, &sb) != 0 || !S_ISDIR(sb.st_mode))
		{
			plzig_rm_fail(st, "stat directory", errno);
			close(fd);
			ReleaseExternalFD();
			return;
		}
		if (sb.st_dev != st->dev)
		{
			/* a mount point: never descend into another file system */
			st->other_fs = true;
			close(fd);
			ReleaseExternalFD();
			return;
		}
		d = fdopendir(fd);
		if (d == NULL)
		{
			plzig_rm_fail(st, "open directory", errno);
			close(fd);
			ReleaseExternalFD();
			return;
		}

		/* entries may be added while we work: rescan a few times */
		for (pass = 0; pass < 3; pass++)
		{
			rewinddir(d);
			while ((de = readdir(d)) != NULL)
			{
				if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
					continue;
				/* fd is the DIR's own descriptor (fdopendir took it over) */
				plzig_rm_at(fd, de->d_name, depth + 1, st);
			}
			/*
			 * If `name` was meanwhile replaced, this removes (only) whatever
			 * empty directory now has that name, or fails harmlessly.
			 */
			if (unlinkat(dfd, name, AT_REMOVEDIR) == 0 || errno == ENOENT)
				break;
			if (errno != ENOTEMPTY && errno != EEXIST)
			{
				plzig_rm_fail(st, "remove directory", errno);
				break;
			}
			if (st->too_deep || st->other_fs || st->err != 0)
				break;			/* rescanning will not help */
		}
		if (pass == 3)
			plzig_rm_fail(st, "remove directory", ENOTEMPTY);
		closedir(d);
		ReleaseExternalFD();
		return;
	}
	plzig_rm_fail(st, "unlink", ELOOP);
}

/*
 * Remove path (a build directory directly inside $PGDATA/plzig) and
 * everything below it.  Problems are reported at elevel, never as ERROR.
 */
static void
plzig_rmtree(const char *path, int elevel)
{
	char		parent[MAXPGPATH];
	const char *leaf;
	char	   *slash;
	PlzigRmState st;
	struct stat sb;
	int			pfd;

	memset(&st, 0, sizeof(st));
	if (strlcpy(parent, path, sizeof(parent)) >= sizeof(parent))
		return;
	slash = strrchr(parent, '/');
	if (slash == NULL || slash == parent || slash[1] == '\0')
		return;
	*slash = '\0';
	leaf = path + (slash - parent) + 1;

	if (!AcquireExternalFD())
	{
		errno = EMFILE;
		ereport(elevel,
				(errcode_for_file_access(),
				 errmsg("PL/Zig: could not remove \"%s\": %m", plzig_display_path(path)),
				 errdetail_log("Full path: \"%s\".", path)));
		return;
	}
	pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (pfd < 0 || fstat(pfd, &sb) != 0)
	{
		int			save = errno;

		if (pfd >= 0)
			close(pfd);
		ReleaseExternalFD();
		errno = save;
		ereport(elevel,
				(errcode_for_file_access(),
				 errmsg("PL/Zig: could not remove \"%s\": %m", plzig_display_path(path)),
				 errdetail_log("Full path: \"%s\".", path)));
		return;
	}
	st.dev = sb.st_dev;
	plzig_rm_at(pfd, leaf, 0, &st);
	close(pfd);
	ReleaseExternalFD();

	/* all descriptors are closed: now it is safe to report */
	if (st.too_deep)
		ereport(elevel,
				(errmsg("PL/Zig: directory tree too deep, could not remove \"%s\" completely",
						plzig_display_path(path)),
				 errdetail_log("Full path: \"%s\".", path)));
	if (st.other_fs)
		ereport(elevel,
				(errmsg("PL/Zig: \"%s\" contains a mount point, which was not removed",
						plzig_display_path(path)),
				 errdetail_log("Full path: \"%s\".", path)));
	if (st.err != 0)
	{
		errno = st.err;
		ereport(elevel,
				(errcode_for_file_access(),
				 errmsg("PL/Zig: could not remove \"%s\" completely (%s failed): %m",
						plzig_display_path(path), st.what),
				 errdetail_log("Full path: \"%s\".", path)));
	}
}

/*
 * Remove leftover build directories.  Called with the compile lock held,
 * before our own build directory is created.  Every compilation runs under
 * that lock from mkdir to rmtree, so while we hold it no other build
 * directory can be in use: whatever exists was left behind by a backend
 * that died, or whose cleanup failed (its pid may be alive or reused).
 * Pid liveness is therefore not consulted at all.
 */
static void
plzig_sweep_build_dirs(const char *root)
{
	DIR		   *dir;
	struct dirent *de;

	dir = AllocateDir(root);
	if (dir == NULL)
		return;
	while ((de = ReadDirExtended(dir, plzig_display_path(root), WARNING)) != NULL)
	{
		char		path[MAXPGPATH];

		if (strncmp(de->d_name, PLZIG_BUILD_PREFIX, strlen(PLZIG_BUILD_PREFIX)) != 0)
			continue;
		if (snprintf(path, sizeof(path), "%s/%s", root, de->d_name) >= (int) sizeof(path))
			continue;
		if (strcmp(path, plzig_current_build_dir) == 0)
			continue;
		plzig_rmtree(path, WARNING);
	}
	FreeDir(dir);
}

static void
plzig_build_exit_cb(int code, Datum arg)
{
	plzig_build_atexit();
}

void
plzig_build_atexit(void)
{
	plzig_spawn_atexit();
	if (plzig_current_build_dir[0] != '\0')
	{
		plzig_rmtree(plzig_current_build_dir, LOG);
		plzig_current_build_dir[0] = '\0';
	}
}

/* ---------------------------------------------------------------------
 * Files
 * ---------------------------------------------------------------------
 */
static void
plzig_write_file(const char *path, const char *data, size_t len, bool sync)
{
	int			fd;
	size_t		off = 0;
	const char *shown = plzig_display_path(path);

	fd = OpenTransientFilePerm(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | PG_BINARY,
							   S_IRUSR | S_IWUSR);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create file \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	while (off < len)
	{
		ssize_t		n = write(fd, data + off, len - off);

		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write file \"%s\": %m", shown),
					 errdetail_log("Full path: \"%s\".", path)));
		}
		off += (size_t) n;
	}
	if (sync && pg_fsync(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if (CloseTransientFile(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", path)));
}

/* what plzig_read_file reads, for its checks and messages */
typedef enum PlzigFileKind
{
	PLZIG_FILE_PLAIN,			/* SDK file */
	PLZIG_FILE_CACHED,			/* cache entry: private, refresh LRU time */
	PLZIG_FILE_COMPILED			/* fresh compiler output, size checked
								 * against plzig.max_module_size */
} PlzigFileKind;

/*
 * Read a whole file. Returns NULL if it does not exist (and missing_ok).
 * A cached module must be a regular file owned by us, mode 0600; reading it
 * refreshes its mtime (at most every PLZIG_CACHE_TOUCH_SECS), which is what
 * cache eviction orders by.
 */
static char *
plzig_read_file(const char *path, size_t maxlen, size_t *len, bool missing_ok,
				PlzigFileKind kind)
{
	int			fd;
	struct stat st;
	char	   *buf;
	size_t		off = 0;
	const char *shown = plzig_display_path(path);

	/* O_NONBLOCK: a FIFO planted by a compromised compiler must not hang us */
	fd = OpenTransientFile(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT && missing_ok)
			return NULL;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	}
	if (fstat(fd, &st) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat file \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if (!S_ISREG(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: \"%s\" is not a regular file", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if (kind == PLZIG_FILE_CACHED &&
		(st.st_uid != geteuid() || (st.st_mode & (S_IRWXG | S_IRWXO)) != 0))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: file \"%s\" has wrong owner or permissions", shown),
				 errdetail_log("Full path: \"%s\".", path)));
	if (kind == PLZIG_FILE_COMPILED && (size_t) st.st_size > maxlen)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: the compiled module is too large"),
				 errdetail("The module has %lld bytes; plzig.max_module_size is %d kB.",
						   (long long) st.st_size, plzig_max_module_size),
				 errhint("Large constant data in the function body ends up in the module.")));
	if ((size_t) st.st_size > maxlen)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: file \"%s\" is too large", shown),
				 errdetail_log("Full path: \"%s\".", path)));

	buf = palloc((size_t) st.st_size + 1);
	while (off < (size_t) st.st_size)
	{
		ssize_t		n = read(fd, buf + off, (size_t) st.st_size - off);

		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not read file \"%s\": %m", shown),
					 errdetail_log("Full path: \"%s\".", path)));
		}
		if (n == 0)
			break;
		off += (size_t) n;
	}
	/* LRU: best effort, an old timestamp only makes eviction likelier */
	if (kind == PLZIG_FILE_CACHED &&
		st.st_mtime < time(NULL) - PLZIG_CACHE_TOUCH_SECS)
		(void) futimens(fd, NULL);
	CloseTransientFile(fd);
	buf[off] = '\0';
	*len = off;
	return buf;
}

/* ---------------------------------------------------------------------
 * SDK and cache key
 * ---------------------------------------------------------------------
 */
static void
plzig_hex(const uint8 *d, int n, char *out)
{
	static const char hx[] = "0123456789abcdef";
	int			i;

	for (i = 0; i < n; i++)
	{
		out[2 * i] = hx[d[i] >> 4];
		out[2 * i + 1] = hx[d[i] & 0xf];
	}
	out[2 * n] = '\0';
}

static void
plzig_sha256_parts(const char *const *parts, const size_t *lens, int n, char *hex)
{
	pg_cryptohash_ctx *ctx;
	uint8		digest[32];
	int			i;

	ctx = pg_cryptohash_create(PG_SHA256);
	if (ctx == NULL || pg_cryptohash_init(ctx) < 0)
		elog(ERROR, "could not initialize SHA-256");
	for (i = 0; i < n; i++)
	{
		uint8		sep = 0;
		uint64		l = lens[i];

		/* length-prefixed parts: no ambiguity between boundaries */
		if (pg_cryptohash_update(ctx, (const uint8 *) &l, sizeof(l)) < 0 ||
			pg_cryptohash_update(ctx, (const uint8 *) parts[i], lens[i]) < 0 ||
			pg_cryptohash_update(ctx, &sep, 1) < 0)
			elog(ERROR, "could not compute SHA-256");
	}
	if (pg_cryptohash_final(ctx, digest, sizeof(digest)) < 0)
		elog(ERROR, "could not compute SHA-256");
	pg_cryptohash_free(ctx);
	plzig_hex(digest, 32, hex);
}

static void
plzig_load_sdk(void)
{
	char		share[MAXPGPATH];
	char		path[MAXPGPATH];
	MemoryContext old;
	const char *parts[2];
	size_t		lens[2];

	if (plzig_sdk_digest[0] != '\0')
		return;

	get_share_path(my_exec_path, share);
	old = MemoryContextSwitchTo(TopMemoryContext);
	plzig_path(path, "%s/plzig/sdk/plzig.zig", share);
	plzig_sdk_plzig = plzig_read_file(path, 1024 * 1024, &plzig_sdk_plzig_len, false,
									  PLZIG_FILE_PLAIN);
	plzig_path(path, "%s/plzig/sdk/root.zig", share);
	plzig_sdk_root = plzig_read_file(path, 1024 * 1024, &plzig_sdk_root_len, false,
									 PLZIG_FILE_PLAIN);
	MemoryContextSwitchTo(old);

	parts[0] = plzig_sdk_plzig;
	lens[0] = plzig_sdk_plzig_len;
	parts[1] = plzig_sdk_root;
	lens[1] = plzig_sdk_root_len;
	plzig_sha256_parts(parts, lens, 2, plzig_sdk_digest);
}

/*
 * The module cache key: sha256 over the ABI version, the pinned Zig version,
 * the fixed flags, the SDK digest and the generated source; for a function
 * that uses others (//#use), also the module layout (which unit imports
 * which under which name: everything the extra compiler flags are made of)
 * and the generated source of every used function, so that a change of any
 * of them makes a new module.  A function without uses has the key it had
 * before uses existed.
 */
static void
plzig_cache_key(const PlzigProgram *prog, char *hex)
{
	StringInfoData flags;
	StringInfoData layout;
	const char **parts;
	size_t	   *lens;
	int			nparts;
	char		abi[16];
	int			i;
	int			u;

	initStringInfo(&flags);
	for (i = 0; plzig_zig_flags[i]; i++)
		appendStringInfo(&flags, "%s ", plzig_zig_flags[i]);
	snprintf(abi, sizeof(abi), "abi%d", PLZIG_ABI_VERSION);

	parts = palloc(sizeof(char *) * (prog->nunits + 6));
	lens = palloc(sizeof(size_t) * (prog->nunits + 6));
	parts[0] = abi;
	lens[0] = strlen(abi);
	parts[1] = PLZIG_ZIG_VERSION;
	lens[1] = strlen(PLZIG_ZIG_VERSION);
	parts[2] = flags.data;
	lens[2] = flags.len;
	parts[3] = plzig_sdk_digest;
	lens[3] = strlen(plzig_sdk_digest);
	parts[4] = prog->units[0].src;
	lens[4] = prog->units[0].srclen;
	nparts = 5;
	initStringInfo(&layout);
	if (prog->nunits > 1)
	{
		for (u = 0; u < prog->nunits; u++)
		{
			appendStringInfo(&layout, "unit %d:", u);
			for (i = 0; i < prog->units[u].nuses; i++)
				appendStringInfo(&layout, " %s=%d", prog->units[u].use_alias[i],
								 prog->units[u].use_unit[i]);
			appendStringInfoChar(&layout, '\n');
		}
		parts[nparts] = layout.data;
		lens[nparts++] = layout.len;
		for (u = 1; u < prog->nunits; u++)
		{
			parts[nparts] = prog->units[u].src;
			lens[nparts++] = prog->units[u].srclen;
		}
	}
	plzig_sha256_parts(parts, lens, nparts, hex);
	pfree(flags.data);
	pfree(layout.data);
	pfree(parts);
	pfree(lens);
}

/* ---------------------------------------------------------------------
 * Compile lock
 * ---------------------------------------------------------------------
 */
static int
plzig_lock(const char *root)
{
	char		path[MAXPGPATH];
	int			fd;

	plzig_path(path, "%s/%s", root, PLZIG_LOCK_NAME);
	fd = OpenTransientFilePerm(path, O_RDWR | O_CREAT | O_NOFOLLOW | PG_BINARY,
							   S_IRUSR | S_IWUSR);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", plzig_display_path(path)),
				 errdetail_log("Full path: \"%s\".", path)));
	for (;;)
	{
		if (flock(fd, LOCK_EX | LOCK_NB) == 0)
			break;
		if (errno != EWOULDBLOCK && errno != EINTR)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not lock file \"%s\": %m", plzig_display_path(path)),
					 errdetail_log("Full path: \"%s\".", path)));
		(void) WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
						 100L, PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();
	}
	return fd;
}

/* ---------------------------------------------------------------------
 * Output post-processing
 * ---------------------------------------------------------------------
 */

/* Replace every occurrence of `from` by `to`. */
static char *
plzig_replace_all(const char *s, const char *from, const char *to)
{
	StringInfoData b;
	size_t		fl = strlen(from);
	const char *p = s;
	const char *q;

	if (fl == 0)
		return pstrdup(s);
	initStringInfo(&b);
	while ((q = strstr(p, from)) != NULL)
	{
		appendBinaryStringInfo(&b, p, (int) (q - p));
		appendStringInfoString(&b, to);
		p = q + fl;
	}
	appendStringInfoString(&b, p);
	return b.data;
}

/*
 * Make compiler/validator output presentable: strip the build directory and
 * other server paths, map user.zig line numbers to function body lines, and
 * neutralise anything that could be mistaken for terminal control or for a
 * server message.  The text is user-influenced (e.g. @compileError), so:
 *   - every C0 control character except newline and tab, and DEL, becomes
 *     '?' (always, not only when the encoding check fails);
 *   - bytes >= 0x80 become '?' too if the result is not valid in the
 *     database encoding;
 *   - continuation lines are indented by two spaces, so no line of the
 *     DETAIL starts in column 0 like "ERROR:  ..." would.
 */
/*
 * In compiler output, a position "src/unit<i>.zig:L:C:" (a used function,
 * plzig_use.c) is shown as "function <signature>, line L-1, column C:".
 * Returns the length of the marker at p and sets *label, or 0.
 */
static size_t
plzig_unit_marker(const char *p, const PlzigProgram *prog, const char **label)
{
	const char *q;
	long		u;
	char	   *end;

	if (prog == NULL || strncmp(p, "src/unit", 8) != 0 || !isdigit((unsigned char) p[8]))
		return 0;
	u = strtol(p + 8, &end, 10);
	if (strncmp(end, ".zig:", 5) != 0 || u < 1 || u >= prog->nunits)
		return 0;
	q = end + 5;
	if (!isdigit((unsigned char) *q))
		return 0;
	*label = prog->units[u].display;
	return q - p;
}

static char *
plzig_format_output_units(const char *raw, int rawlen, const char *builddir,
						  bool validator, const PlzigProgram *prog)
{
	StringInfoData b;
	StringInfoData out;
	char	   *s;
	char		prefix[MAXPGPATH + 2];
	char		path[MAXPGPATH];
	const char *p;
	const char *marker = validator ? "" : "src/user.zig:";
	size_t		ml = strlen(marker);
	int			i;

	s = palloc(rawlen + 1);
	memcpy(s, raw, rawlen);
	s[rawlen] = '\0';
	/* NULs would truncate messages; replace them */
	for (i = 0; i < rawlen; i++)
		if (s[i] == '\0')
			s[i] = '?';

	/* longest paths first */
	snprintf(prefix, sizeof(prefix), "%s/", builddir);
	s = plzig_replace_all(s, prefix, "");
	s = plzig_replace_all(s, builddir, ".");
	if (snprintf(path, sizeof(path), "%s/%s/%s", DataDir, PLZIG_DIR_NAME,
				 PLZIG_ZIGCACHE_NAME) < (int) sizeof(path))
		s = plzig_replace_all(s, path, "<zig cache>");
	s = plzig_replace_all(s, pkglib_path, "$libdir");
	if (plzig_tc.lib[0] != '\0')
	{
		snprintf(prefix, sizeof(prefix), "%s/", plzig_tc.lib);
		s = plzig_replace_all(s, prefix, "<zig lib>/");
	}
	s = plzig_replace_all(s, DataDir, "<data directory>");
	if (plzig_realpath(DataDir, path) && strcmp(path, DataDir) != 0)
		s = plzig_replace_all(s, path, "<data directory>");

	initStringInfo(&b);
	p = s;
	while (*p)
	{
		/* at the start of a line (validator) or at "src/user.zig:" (zig) */
		bool		at_marker;
		size_t		skip = ml;
		const char *label = NULL;

		if (validator)
			at_marker = (p == s || p[-1] == '\n') && isdigit((unsigned char) *p);
		else
		{
			at_marker = strncmp(p, marker, ml) == 0 &&
				isdigit((unsigned char) p[ml]);
			if (!at_marker && (skip = plzig_unit_marker(p, prog, &label)) > 0)
				at_marker = true;
		}

		if (at_marker)
		{
			char	   *end;
			long		line;
			long		col;

			line = strtol(p + skip, &end, 10);
			if (*end == ':' && isdigit((unsigned char) end[1]))
			{
				col = strtol(end + 1, &end, 10);
				if (*end == ':')
				{
					if (label)
						appendStringInfo(&b, "function %s, ", label);
					appendStringInfo(&b, "line %ld, column %ld:", line > 1 ? line - 1 : 0, col);
					p = end + 1;
					continue;
				}
			}
		}
		appendStringInfoChar(&b, *p);
		p++;
	}

	/* trim trailing whitespace */
	while (b.len > 0 && isspace((unsigned char) b.data[b.len - 1]))
		b.data[--b.len] = '\0';

	for (i = 0; i < b.len; i++)
	{
		unsigned char c = (unsigned char) b.data[i];

		if ((c < 0x20 && c != '\n' && c != '\t') || c == 0x7f)
			b.data[i] = '?';
	}
	if (!pg_verifymbstr(b.data, b.len, true))
	{
		for (i = 0; i < b.len; i++)
			if ((unsigned char) b.data[i] >= 0x80)
				b.data[i] = '?';
	}

	initStringInfo(&out);
	for (i = 0; i < b.len; i++)
	{
		appendStringInfoChar(&out, b.data[i]);
		if (b.data[i] == '\n')
			appendStringInfoString(&out, "  ");
	}
	return out.data;
}

/*
 * Did the compiler refuse a discard ("_ = n;") of a parameter?  The
 * generated header (src/user.zig line 1, shown as line 0) has "_ = &n;" for
 * every parameter, since an unused one is an error in Zig; Zig 0.17.1 also
 * reports the discard of a variable that is used anywhere as an error
 * ("pointless discard"), and its note may point at that header.  Such a
 * discard can only be removed, which the hint says.
 */
static bool
plzig_discard_hint(const char *raw, int rawlen)
{
	char	   *s = pnstrdup(raw, rawlen);
	bool		found = strstr(s, "error: pointless discard of function parameter") != NULL;

	pfree(s);
	return found;
}

static char *
plzig_format_output(const char *raw, int rawlen, const char *builddir, bool validator)
{
	return plzig_format_output_units(raw, rawlen, builddir, validator, NULL);
}

/* ---------------------------------------------------------------------
 * Running the tools
 * ---------------------------------------------------------------------
 */
/* ---------------------------------------------------------------------
 * The Zig toolchain: an external, administrator-provided dependency
 * ---------------------------------------------------------------------
 */

/* Paths are hidden from non-superusers (the settings are superuser-only). */
#define PLZIG_PATH_DETAIL(...) \
	(plzig_tc_show_paths ? errdetail(__VA_ARGS__) : errdetail_log(__VA_ARGS__))

static bool
plzig_same_file(const struct stat *a, const struct stat *b)
{
	return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
		a->st_size == b->st_size && a->st_mode == b->st_mode &&
		a->st_uid == b->st_uid && a->st_gid == b->st_gid &&
		a->st_mtime == b->st_mtime && a->st_ctime == b->st_ctime
#ifdef __linux__
		&& a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
		a->st_ctim.tv_nsec == b->st_ctim.tv_nsec
#endif
		;
}

/* realpath() into a MAXPGPATH buffer; false (errno set) on failure */
static bool
plzig_realpath(const char *path, char *out)
{
	char		buf[PATH_MAX];

	if (realpath(path, buf) == NULL)
		return false;
	if (strlen(buf) >= MAXPGPATH)
	{
		errno = ENAMETOOLONG;
		return false;
	}
	strlcpy(out, buf, MAXPGPATH);
	return true;
}

/*
 * Resolve an absolute path setting.  The compiler is never looked up in
 * PATH: a relative value is refused.
 */
static void
plzig_resolve_setting(const char *name, const char *value, char *out)
{
	if (!is_absolute_path(value))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: %s must be an absolute path", name),
				 errhint("PL/Zig never searches PATH for the compiler.")));
	if (!plzig_realpath(value, out))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: could not resolve %s: %m", name),
				 PLZIG_PATH_DETAIL("%s = \"%s\".", name, value)));
}

/*
 * Check `path` (already resolved: no symbolic links) and every directory
 * above it: each must be owned by root or the server user and not be
 * writable by group or others.  Directories above the immediate parent may
 * be world-writable if sticky (e.g. /tmp): nobody else can rename an entry
 * owned by root or by us there.  Returns the stat of path itself.
 */
static void
plzig_check_tree(const char *path, bool want_dir, const char *what,
				 struct stat *self_st)
{
	char		buf[MAXPGPATH];
	struct stat st;
	int			level = 0;

	strlcpy(buf, path, sizeof(buf));
	for (;;)
	{
		char	   *slash;
		const char *role;

		role = level == 0 ? "" : level == 1 ? "the directory containing " :
			"a parent directory of ";
		if (lstat(buf, &st) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("PL/Zig: could not stat %s%s: %m", role, what),
					 PLZIG_PATH_DETAIL("Path: \"%s\".", buf)));
		if (level == 0)
		{
			if (want_dir ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode))
				ereport(ERROR,
						(errcode(ERRCODE_CONFIG_FILE_ERROR),
						 errmsg("PL/Zig: %s is not a %s", what,
								want_dir ? "directory" : "regular file"),
						 PLZIG_PATH_DETAIL("Path: \"%s\".", buf)));
			*self_st = st;
		}
		else if (!S_ISDIR(st.st_mode))
			ereport(ERROR,
					(errcode(ERRCODE_CONFIG_FILE_ERROR),
					 errmsg("PL/Zig: %s%s is not a directory", role, what),
					 PLZIG_PATH_DETAIL("Path: \"%s\".", buf)));
		if (st.st_uid != 0 && st.st_uid != geteuid())
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("PL/Zig: refusing to use the Zig compiler: %s%s is not owned by root or by the server user",
							role, what),
					 PLZIG_PATH_DETAIL("Path: \"%s\".", buf)));
		if ((st.st_mode & (S_IWGRP | S_IWOTH)) != 0 &&
			!(level >= 2 && (st.st_mode & S_ISVTX) != 0))
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("PL/Zig: refusing to use the Zig compiler: %s%s is writable by group or others",
							role, what),
					 PLZIG_PATH_DETAIL("Path: \"%s\".", buf)));

		if (strcmp(buf, "/") == 0)
			break;
		slash = strrchr(buf, '/');
		if (slash == NULL)
			break;
		if (slash == buf)
			slash[1] = '\0';
		else
			*slash = '\0';
		level++;
	}
}

/* Refuse a toolchain path inside the data directory, or containing it. */
static void
plzig_check_outside_pgdata(const char *path, const char *what)
{
	char		data[MAXPGPATH];

	if (!plzig_realpath(DataDir, data))
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not resolve the data directory: %m")));
	if (path_is_prefix_of_path(data, path) || path_is_prefix_of_path(path, data))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: %s must not be inside or contain the data directory", what),
				 PLZIG_PATH_DETAIL("Path: \"%s\".", path)));
}

/* Is dir (resolved) a Zig lib directory, i.e. does it hold std/std.zig? */
static bool
plzig_is_zig_lib(const char *dir)
{
	char		test[MAXPGPATH + 16];
	struct stat st;

	snprintf(test, sizeof(test), "%s/std/std.zig", dir);
	return lstat(test, &st) == 0 && S_ISREG(st.st_mode);
}

static void
plzig_find_lib_dir(const char *bin, char *lib)
{
	if (plzig_zig_lib_dir != NULL && plzig_zig_lib_dir[0] != '\0')
	{
		plzig_resolve_setting("plzig.zig_lib_dir", plzig_zig_lib_dir, lib);
		if (!plzig_is_zig_lib(lib))
			ereport(ERROR,
					(errcode(ERRCODE_CONFIG_FILE_ERROR),
					 errmsg("PL/Zig: plzig.zig_lib_dir is not a Zig lib directory (no std/std.zig)"),
					 PLZIG_PATH_DETAIL("Resolved to \"%s\".", lib)));
	}
	else
	{
		/* the standard layouts: <dir>/lib (tarball), <dir>/../lib/zig (FHS) */
		static const char *const layouts[] = {"lib", "../lib/zig"};
		char		bindir[MAXPGPATH];
		char		cand[MAXPGPATH + 16];
		char	   *slash;
		int			i;

		strlcpy(bindir, bin, sizeof(bindir));
		slash = strrchr(bindir, '/');
		if (slash != NULL)
			*slash = '\0';
		for (i = 0; i < (int) lengthof(layouts); i++)
		{
			snprintf(cand, sizeof(cand), "%s/%s", bindir, layouts[i]);
			if (plzig_realpath(cand, lib) && plzig_is_zig_lib(lib))
				return;
		}
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: could not find the Zig lib directory next to the compiler"),
				 errdetail("Looked for <compiler directory>/lib and <compiler directory>/../lib/zig."),
				 errhint("Set plzig.zig_lib_dir in postgresql.conf.")));
	}
}

static bool
plzig_is_sha256_hex(const char *s)
{
	int			i;

	for (i = 0; i < 64; i++)
		if (!isxdigit((unsigned char) s[i]))
			return false;
	return s[64] == '\0';
}

/* SHA-256 of the (already checked) compiler binary must match the pin. */
static void
plzig_check_sha256(const char *path, const struct stat *expect)
{
	pg_cryptohash_ctx *ctx;
	struct stat st;
	uint8		digest[32];
	char		hex[65];
	char	   *buf;
	int			fd;

	fd = OpenTransientFile(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("PL/Zig: could not open the Zig compiler to check plzig.zig_sha256: %m")));
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
		st.st_dev != expect->st_dev || st.st_ino != expect->st_ino)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: the Zig compiler changed while it was being checked")));

	buf = palloc(65536);
	ctx = pg_cryptohash_create(PG_SHA256);
	if (ctx == NULL || pg_cryptohash_init(ctx) < 0)
		elog(ERROR, "could not initialize SHA-256");
	for (;;)
	{
		ssize_t		n = read(fd, buf, 65536);

		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("PL/Zig: could not read the Zig compiler: %m")));
		}
		if (n == 0)
			break;
		if (pg_cryptohash_update(ctx, (const uint8 *) buf, (size_t) n) < 0)
			elog(ERROR, "could not compute SHA-256");
		CHECK_FOR_INTERRUPTS();
	}
	if (pg_cryptohash_final(ctx, digest, sizeof(digest)) < 0)
		elog(ERROR, "could not compute SHA-256");
	pg_cryptohash_free(ctx);
	CloseTransientFile(fd);
	pfree(buf);

	plzig_hex(digest, 32, hex);
	if (pg_strcasecmp(hex, plzig_zig_sha256) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: the Zig compiler does not match plzig.zig_sha256"),
				 PLZIG_PATH_DETAIL("Expected SHA-256 %s, the file has %s.",
								   plzig_zig_sha256, hex)));
}

/*
 * True if path needs a program interpreter to run: an ELF file with a
 * PT_INTERP header (dynamically linked), or a "#!" script.  Under Landlock
 * only the binary itself is executable, so such a compiler cannot start.
 */
static bool
plzig_needs_interpreter(const char *path)
{
	bool		result = false;
#ifdef __linux__
	Elf64_Ehdr	eh;
	int			fd;
	int			i;

	fd = OpenTransientFile(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("PL/Zig: could not open the Zig compiler: %m")));
	if (pread(fd, &eh, sizeof(eh), 0) == (ssize_t) sizeof(eh))
	{
		if (memcmp(eh.e_ident, "#!", 2) == 0)
			result = true;
		else if (memcmp(eh.e_ident, ELFMAG, SELFMAG) == 0 &&
				 eh.e_ident[EI_CLASS] == ELFCLASS64 &&
				 eh.e_phentsize == sizeof(Elf64_Phdr) && eh.e_phnum < 4096)
		{
			for (i = 0; i < eh.e_phnum; i++)
			{
				Elf64_Phdr	ph;
				off_t		off = (off_t) eh.e_phoff + (off_t) i * sizeof(ph);

				if (pread(fd, &ph, sizeof(ph), off) != (ssize_t) sizeof(ph))
					break;
				if (ph.p_type == PT_INTERP)
				{
					result = true;
					break;
				}
			}
		}
	}
	CloseTransientFile(fd);
#endif
	return result;
}

/*
 * Locate and check the configured compiler and its lib directory, without
 * running anything.  Fills bin and lib (resolved paths).  Returns true if
 * the compiler still has to pass the version check (plzig_verify_version)
 * before it may be used.
 */
static bool
plzig_check_toolchain(char *bin, char *lib)
{
	struct stat bin_st;
	struct stat lib_st;
	const char *sha = plzig_zig_sha256 ? plzig_zig_sha256 : "";

	plzig_tc_show_paths = superuser();

	if (plzig_zig_path == NULL || plzig_zig_path[0] == '\0')
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: no Zig compiler is configured"),
				 errdetail("Compiling PL/Zig code needs Zig %s, which is not part of the extension; functions whose modules are already cached still run.",
						   PLZIG_ZIG_VERSION),
				 errhint("An administrator must set plzig.zig_path in postgresql.conf to the absolute path of the Zig %s compiler and reload the configuration.",
						 PLZIG_ZIG_VERSION)));

	plzig_resolve_setting("plzig.zig_path", plzig_zig_path, bin);
	plzig_check_tree(bin, false, "the Zig compiler", &bin_st);
	plzig_check_outside_pgdata(bin, "plzig.zig_path");

	plzig_find_lib_dir(bin, lib);
	plzig_check_tree(lib, true, "the Zig lib directory", &lib_st);
	plzig_check_outside_pgdata(lib, "the Zig lib directory");

	if (sha[0] != '\0' && !plzig_is_sha256_hex(sha))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: plzig.zig_sha256 is not a SHA-256 digest (64 hexadecimal digits)")));

	if (plzig_tc.verified &&
		strcmp(plzig_tc.set_path, plzig_zig_path) == 0 &&
		strcmp(plzig_tc.set_lib, plzig_zig_lib_dir ? plzig_zig_lib_dir : "") == 0 &&
		strcmp(plzig_tc.set_sha, sha) == 0 &&
		strcmp(plzig_tc.bin, bin) == 0 && strcmp(plzig_tc.lib, lib) == 0 &&
		plzig_same_file(&plzig_tc.bin_st, &bin_st) &&
		plzig_same_file(&plzig_tc.lib_st, &lib_st))
		return false;

	/* (re)verify: forget the old state first */
	memset(&plzig_tc, 0, sizeof(plzig_tc));
	if (sha[0] != '\0')
		plzig_check_sha256(bin, &bin_st);

	strlcpy(plzig_tc.set_path, plzig_zig_path, sizeof(plzig_tc.set_path));
	strlcpy(plzig_tc.set_lib, plzig_zig_lib_dir ? plzig_zig_lib_dir : "",
			sizeof(plzig_tc.set_lib));
	strlcpy(plzig_tc.set_sha, sha, sizeof(plzig_tc.set_sha));
	strlcpy(plzig_tc.bin, bin, sizeof(plzig_tc.bin));
	strlcpy(plzig_tc.lib, lib, sizeof(plzig_tc.lib));
	plzig_tc.bin_st = bin_st;
	plzig_tc.lib_st = lib_st;
	return true;
}

/*
 * Parse plzig.compiler_sandbox.  Exactly require, try or off; anything else
 * (including the former "on" and boolean spellings) refuses the compile.
 */
static int
plzig_sandbox_mode(void)
{
	const char *v = plzig_compiler_sandbox ? plzig_compiler_sandbox : "";

	if (strcmp(v, "require") == 0)
		return PLZIG_SANDBOX_REQUIRE;
	if (strcmp(v, "try") == 0)
		return PLZIG_SANDBOX_TRY;
	if (strcmp(v, "off") == 0)
		return PLZIG_SANDBOX_OFF;
	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("PL/Zig: invalid value for plzig.compiler_sandbox: \"%s\"", v),
			 errdetail("PL/Zig will not compile until this is corrected; functions whose modules are already cached still run."),
			 errhint("Valid values are require, try and off; set it in postgresql.conf and reload the configuration.")));
	return PLZIG_SANDBOX_REQUIRE;	/* keep compiler quiet */
}

/*
 * Append to buf what the compiler sandbox lacks; nothing if it is complete.
 * abi: Landlock ABI in use (> 0), or the probe's negative errno, or 0 for
 * "available but not applied".  seccomp: 0 = in use, negative errno from the
 * probe, or 1 for "available but not installed".
 */
static void
plzig_sandbox_missing(StringInfo buf, int abi, int seccomp)
{
	if (abi < 0)
		appendStringInfo(buf, "Landlock is not available (landlock_create_ruleset returned %d): no filesystem confinement",
						 abi);
	else if (abi == 0)
		appendStringInfoString(buf, "Landlock was not applied: no filesystem confinement");
	else
	{
		const char *gaps[8];
		int			n = 0;
		int			i;

		if (abi < 3)
			gaps[n++] = "file truncation";
		if (abi < 4)
			gaps[n++] = "TCP";
		if (abi < 5)
			gaps[n++] = "device ioctl";
		if (abi < 6)
			gaps[n++] = "signals and abstract UNIX sockets";
		if (abi < 9)
			gaps[n++] = "pathname UNIX sockets";
		if (abi < 10)
			gaps[n++] = "UDP";
		if (n > 0)
		{
			appendStringInfo(buf, "Landlock ABI %d lacks restrictions on ", abi);
			for (i = 0; i < n; i++)
				appendStringInfo(buf, "%s%s",
								 i == 0 ? "" : i == n - 1 ? " and " : ", ", gaps[i]);
		}
	}

	if (seccomp != 0)
	{
		if (buf->len > 0)
			appendStringInfoString(buf, "; ");
		if (seccomp == -ENOSYS)
			appendStringInfoString(buf, "no seccomp filter (not supported on this architecture)");
		else if (seccomp > 0)
			appendStringInfoString(buf, "the seccomp filter was not installed");
		else
		{
			errno = -seccomp;
			appendStringInfo(buf, "no seccomp filter (the kernel refused filter mode: %m)");
		}
	}
}

static void
plzig_setup_sandbox(PlzigSandbox *sb, const char *builddir, const char *zigcache,
					const char *validator, const char *zigbin, const char *ziglib)
{
	memset(sb, 0, sizeof(*sb));
	sb->mode = plzig_sandbox_mode();
	if (sb->mode == PLZIG_SANDBOX_OFF)
	{
		sb->landlock_abi = 0;
		sb->seccomp = -EPERM;	/* not used */
	}
	else
	{
		StringInfoData missing;

		sb->landlock_abi = plzig_landlock_probe();
		sb->seccomp = plzig_seccomp_probe();
		initStringInfo(&missing);
		plzig_sandbox_missing(&missing, sb->landlock_abi, sb->seccomp);

		/* require: Landlock ABI >= 6 and the seccomp filter, nothing less */
		if (sb->mode == PLZIG_SANDBOX_REQUIRE &&
			(sb->landlock_abi < PLZIG_LANDLOCK_MIN_REQUIRED_ABI || sb->seccomp != 0))
		{
			const char *hint = sb->landlock_abi <= 0 ?
				"An administrator can set plzig.compiler_sandbox = try in postgresql.conf to compile with only the protections that are available; without Landlock the compiler can read and write every file the server's operating-system user can." :
				"An administrator can set plzig.compiler_sandbox = try in postgresql.conf to compile with only the protections that are available.";

			if (sb->landlock_abi <= 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("PL/Zig: Landlock is not available, and plzig.compiler_sandbox = require"),
						 errdetail("Missing: %s. Landlock ABI %d or later and the seccomp filter are required; functions whose modules are already cached still run.",
								   missing.data, PLZIG_LANDLOCK_MIN_REQUIRED_ABI),
						 errhint("%s", hint)));
			if (sb->landlock_abi < PLZIG_LANDLOCK_MIN_REQUIRED_ABI)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("PL/Zig: Landlock ABI %d is too old for plzig.compiler_sandbox = require",
								sb->landlock_abi),
						 errdetail("Missing: %s. Landlock ABI %d or later and the seccomp filter are required; functions whose modules are already cached still run.",
								   missing.data, PLZIG_LANDLOCK_MIN_REQUIRED_ABI),
						 errhint("%s", hint)));
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig: the seccomp filter is not available, and plzig.compiler_sandbox = require"),
					 errdetail("Missing: %s. Landlock ABI %d or later and the seccomp filter are required; functions whose modules are already cached still run.",
							   missing.data, PLZIG_LANDLOCK_MIN_REQUIRED_ABI),
					 errhint("%s", hint)));
		}
		if (sb->mode == PLZIG_SANDBOX_TRY && missing.len > 0 && !plzig_sandbox_logged)
		{
			ereport(LOG,
					(errmsg("PL/Zig: the compiler sandbox is incomplete, compiling anyway because plzig.compiler_sandbox = try; missing: %s",
							missing.data)));
			plzig_sandbox_logged = true;
		}
		pfree(missing.data);
	}

	/* executables: rules on the files themselves; the Zig lib: read only */
	sb->rx_files[sb->n_rx_files++] = validator;
	sb->rx_files[sb->n_rx_files++] = zigbin;
	sb->ro_dirs[sb->n_ro++] = ziglib;
	sb->rw_dirs[sb->n_rw++] = builddir;
	sb->rw_dirs[sb->n_rw++] = zigcache;

	if (sb->landlock_abi > 0 && sb->mode != PLZIG_SANDBOX_OFF &&
		plzig_needs_interpreter(zigbin))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: the Zig compiler is dynamically linked (or a script) and cannot run in the Landlock sandbox"),
				 errdetail("The sandbox allows executing the compiler binary only, not a program interpreter or shared libraries."),
				 errhint("Use a statically linked Zig %s, such as the official build from ziglang.org.",
						 PLZIG_ZIG_VERSION)));

	sb->rlimit_fsize = (uint64) 256 * 1024 * 1024;
	sb->rlimit_as = (uint64) plzig_compile_memory_limit * 1024 * 1024;
	{
		long		ncpu = sysconf(_SC_NPROCESSORS_ONLN);
		uint64		secs = (uint64) plzig_compile_timeout / 1000 + 1;

		if (ncpu < 1)
			ncpu = 1;
		/* backstop only; the wall-clock timeout is the real limit */
		sb->rlimit_cpu = secs * (uint64) ncpu + 10;
	}
}

/*
 * Remember how the last child was confined, for plzig_sandbox_status():
 * "enforced" = what require insists on (Landlock >= ABI 6 and seccomp),
 * "partial" = something was applied, "none", or "off".
 */
static void
plzig_record_sandbox(const PlzigSpawnResult *res, const PlzigSandbox *sb)
{
	StringInfoData missing;
	const char *state;

	if (sb->mode == PLZIG_SANDBOX_OFF)
	{
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "off (plzig.compiler_sandbox = off)");
		return;
	}
	initStringInfo(&missing);
	plzig_sandbox_missing(&missing,
						  res->sandboxed ? res->landlock_abi :
						  (sb->landlock_abi < 0 ? sb->landlock_abi : 0),
						  res->seccomp ? 0 : (sb->seccomp < 0 ? sb->seccomp : 1));
	if (res->sandboxed && res->landlock_abi >= PLZIG_LANDLOCK_MIN_REQUIRED_ABI && res->seccomp)
		state = "enforced";
	else if (res->sandboxed || res->seccomp)
		state = "partial";
	else
		state = "none";
	if (res->sandboxed)
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "%s (landlock ABI %d, %s%s%s)", state, res->landlock_abi,
				 res->seccomp ? "seccomp" : "no seccomp",
				 missing.len > 0 ? "; missing: " : "", missing.data);
	else
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "%s (no landlock, %s%s%s)", state,
				 res->seccomp ? "seccomp" : "no seccomp",
				 missing.len > 0 ? "; missing: " : "", missing.data);
	pfree(missing.data);
}

/*
 * Run `<zig> version` (confined like a compile) and require exactly the
 * version the validator was built with: the validator uses that version's
 * tokenizer, and another compiler could disagree with it about what the
 * source contains.
 */
static void
plzig_verify_version(const char *zigbin, char **envp, const char *builddir,
					 const PlzigSandbox *sb)
{
	PlzigSpawnResult res;
	char	   *argv[3];
	char		shown[65];
	int			len;
	int			i;

	argv[0] = (char *) zigbin;
	argv[1] = "version";
	argv[2] = NULL;
	plzig_spawn(zigbin, argv, envp, builddir, NULL, sb, plzig_compile_timeout, &res);
	plzig_record_sandbox(&res, sb);

	len = res.output.len;
	while (len > 0 && isspace((unsigned char) res.output.data[len - 1]))
		len--;
	if (res.exit_status == 0 && len == (int) strlen(PLZIG_ZIG_VERSION) &&
		memcmp(res.output.data, PLZIG_ZIG_VERSION, len) == 0)
	{
		plzig_tc.verified = true;
		return;
	}

	/* first line, printable ASCII only, bounded */
	for (i = 0; i < len && i < (int) sizeof(shown) - 1 && res.output.data[i] != '\n'; i++)
	{
		unsigned char c = (unsigned char) res.output.data[i];

		shown[i] = (c >= 0x20 && c < 0x7f) ? (char) c : '?';
	}
	shown[i] = '\0';

	if (res.exit_status != 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("PL/Zig: \"zig version\" failed (status %d, signal %d); refusing to use plzig.zig_path",
						res.exit_status, res.term_signal),
				 errdetail("Output: \"%s\".", shown)));
	ereport(ERROR,
			(errcode(ERRCODE_CONFIG_FILE_ERROR),
			 errmsg("PL/Zig: the Zig compiler reports version \"%s\", but PL/Zig requires exactly %s",
					shown, PLZIG_ZIG_VERSION),
			 errdetail("The source validator was built with Zig %s; a different compiler could interpret the source differently.",
					   PLZIG_ZIG_VERSION),
			 errhint("Point plzig.zig_path at a Zig %s compiler.", PLZIG_ZIG_VERSION)));
}

/*
 * Compile src in a fresh build directory; on success the module is in
 * *wasm (palloc'd).  Caller holds the compile lock.
 */
/* the file and module of unit u of a build (plzig_use.c) */
static void
plzig_unit_file(int u, char *buf, size_t len)
{
	if (u == 0)
		strlcpy(buf, "src/user.zig", len);
	else
		snprintf(buf, len, "src/unit%d.zig", u);
}

static char *
plzig_unit_module(int u)
{
	return u == 0 ? pstrdup("user") : psprintf("plzig.unit.%d", u);
}

/* --dep entries of unit u: each use under its import name */
static int
plzig_unit_deps(const PlzigProgram *prog, int u, char **argv, int n)
{
	int			i;

	for (i = 0; i < prog->units[u].nuses; i++)
	{
		argv[n++] = "--dep";
		argv[n++] = psprintf(PLZIG_USE_IMPORT_PREFIX "%s=%s", prog->units[u].use_alias[i],
							 plzig_unit_module(prog->units[u].use_unit[i]));
	}
	return n;
}

static char *
plzig_compile(const char *root, const char *zigcache, const PlzigProgram *prog,
			  uint32 *wasm_len)
{
	char		builddir[MAXPGPATH];
	char		path[MAXPGPATH];
	char		zigbin[MAXPGPATH];
	char		ziglib[MAXPGPATH];
	char		validator[MAXPGPATH];
	bool		need_version;
	char		env_home[MAXPGPATH + 8];
	char		env_gc[MAXPGPATH + 32];
	char		env_lc[MAXPGPATH + 32];
	char		env_tmp[MAXPGPATH + 8];
	char		gc_arg[MAXPGPATH];
	char	   *envp[9];
	char	  **argv;
	int			maxargs;
	PlzigSandbox sb;
	PlzigSpawnResult res;
	char	   *volatile wasm = NULL;	/* set inside PG_TRY, read after it */
	volatile size_t len = 0;
	int			i;
	int			n;
	int			u;

	/* fixed flags, 6 inserted after the first, per unit: its module and uses */
	maxargs = 8 + lengthof(plzig_zig_flags);
	for (u = 0; u < prog->nunits; u++)
		maxargs += 4 + 2 * prog->units[u].nuses;
	argv = palloc0(sizeof(char *) * maxargs);

	/* before anything is created or run: path, ownership, mode, checksum */
	need_version = plzig_check_toolchain(zigbin, ziglib);
	plzig_path(validator, "%s/plzig/plzig-validate", pkglib_path);

	/*
	 * pgsql_tmp.build.<pid>.<counter>.<random>: the random part makes a
	 * name left behind by a dead backend whose pid was reused harmless, and
	 * on the off chance that the name exists anyway another one is drawn.
	 */
	for (i = 0;; i++)
	{
		uint8		rnd[8];
		char		rhex[17];

		if (!pg_strong_random(rnd, sizeof(rnd)))
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("PL/Zig: could not generate random bytes")));
		plzig_hex(rnd, sizeof(rnd), rhex);
		plzig_path(builddir, "%s/%s%d.%u.%s", root, PLZIG_BUILD_PREFIX, MyProcPid,
				   ++plzig_build_counter, rhex);
		if (mkdir(builddir, S_IRWXU) == 0)
			break;
		if (errno != EEXIST || i >= 10)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not create directory \"%s\": %m",
							plzig_display_path(builddir)),
					 errdetail_log("Full path: \"%s\".", builddir)));
	}
	strlcpy(plzig_current_build_dir, builddir, sizeof(plzig_current_build_dir));

	PG_TRY();
	{
		plzig_ensure_private_dir(builddir);
		plzig_path(path, "%s/src", builddir);
		plzig_ensure_private_dir(path);
		plzig_path(path, "%s/sdk", builddir);
		plzig_ensure_private_dir(path);
		plzig_path(path, "%s/sdk/plzig.zig", builddir);
		plzig_write_file(path, plzig_sdk_plzig, plzig_sdk_plzig_len, false);
		plzig_path(path, "%s/sdk/root.zig", builddir);
		plzig_write_file(path, plzig_sdk_root, plzig_sdk_root_len, false);
		for (u = 0; u < prog->nunits; u++)
		{
			char		file[32];

			plzig_unit_file(u, file, sizeof(file));
			plzig_path(path, "%s/%s", builddir, file);
			plzig_write_file(path, prog->units[u].src, prog->units[u].srclen, false);
		}

		plzig_setup_sandbox(&sb, builddir, zigcache, validator, zigbin, ziglib);

		snprintf(env_home, sizeof(env_home), "HOME=%s", builddir);
		snprintf(env_gc, sizeof(env_gc), "ZIG_GLOBAL_CACHE_DIR=%s", zigcache);
		snprintf(env_lc, sizeof(env_lc), "ZIG_LOCAL_CACHE_DIR=%s/.zig-cache", builddir);
		snprintf(env_tmp, sizeof(env_tmp), "TMPDIR=%s", builddir);
		envp[0] = "PATH=/usr/bin:/bin";
		envp[1] = env_home;
		envp[2] = env_gc;
		envp[3] = env_lc;
		envp[4] = env_tmp;
		envp[5] = "LC_ALL=C";
		envp[6] = "NO_COLOR=1";
		envp[7] = NULL;

		/* 0. the compiler must be exactly the validator's Zig version */
		if (need_version)
			plzig_verify_version(zigbin, envp, builddir, &sb);

		/*
		 * 1. lexical policy check, of every file exactly as of a standalone
		 * function; a file may import, besides "plzig", the functions it
		 * uses under the names the host gave them (and nothing else).
		 */
		for (u = 0; u < prog->nunits; u++)
		{
			char		file[32];
			char	   *shown;

			n = 0;
			argv[n++] = validator;
			for (i = 0; i < prog->units[u].nuses; i++)
			{
				argv[n++] = "--allow-import";
				argv[n++] = psprintf(PLZIG_USE_IMPORT_PREFIX "%s", prog->units[u].use_alias[i]);
			}
			argv[n] = NULL;
			Assert(n < maxargs);
			plzig_unit_file(u, file, sizeof(file));
			plzig_path(path, "%s/%s", builddir, file);
			plzig_spawn(validator, argv, envp, builddir, path, &sb,
						plzig_compile_timeout, &res);
			plzig_record_sandbox(&res, &sb);
			if (res.exit_status == 0)
				continue;
			shown = plzig_format_output(res.output.data, res.output.len, builddir, true);
			if (u > 0)
				shown = psprintf("In the used function %s:\n  %s", prog->units[u].display, shown);
			if (res.exit_status == 1)
				ereport(ERROR,
						(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
						 errmsg("PL/Zig source rejected by policy"),
						 errdetail("%s", shown)));
			ereport(ERROR,
					(errcode(ERRCODE_SYSTEM_ERROR),
					 errmsg("PL/Zig source validator failed (status %d, signal %d)",
							res.exit_status, res.term_signal),
					 errdetail("%s", shown)));
		}

		/*
		 * 2. compile.  The used functions (plzig_use.c) are modules of their
		 * own, "plzig.unit.<i>" from src/unit<i>.zig, each depending on
		 * "plzig" and on the units it uses; the user module gets its uses
		 * as --dep entries too.
		 */
		n = 0;
		argv[n++] = zigbin;
		for (i = 0; plzig_zig_flags[i]; i++)
		{
			if (strcmp(plzig_zig_flags[i], "-Muser=src/user.zig") == 0)
				n = plzig_unit_deps(prog, 0, argv, n);
			argv[n++] = (char *) plzig_zig_flags[i];
			if (strcmp(plzig_zig_flags[i], "-Mplzig=sdk/plzig.zig") == 0)
			{
				for (u = 1; u < prog->nunits; u++)
				{
					char		file[32];

					argv[n++] = "--dep";
					argv[n++] = "plzig";
					n = plzig_unit_deps(prog, u, argv, n);
					plzig_unit_file(u, file, sizeof(file));
					argv[n++] = psprintf("-M%s=%s", plzig_unit_module(u), file);
				}
			}
			if (i == 0)
			{
				snprintf(gc_arg, sizeof(gc_arg), "%s", zigcache);
				argv[n++] = "--global-cache-dir";
				argv[n++] = gc_arg;
				argv[n++] = "--cache-dir";
				argv[n++] = ".zig-cache";
				argv[n++] = "--zig-lib-dir";
				argv[n++] = ziglib;
			}
		}
		argv[n] = NULL;
		Assert(n < maxargs);

		plzig_spawn(zigbin, argv, envp, builddir, NULL, &sb,
					plzig_compile_timeout, &res);
		plzig_record_sandbox(&res, &sb);
		if (res.exit_status != 0)
		{
			if (res.term_signal != 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYSTEM_ERROR),
						 errmsg("PL/Zig compiler terminated by signal %d", res.term_signal),
						 errdetail("%s", plzig_format_output_units(res.output.data, res.output.len,
															   builddir, false, prog)),
						 errhint("Check plzig.compile_memory_limit and plzig.compile_timeout.")));
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("PL/Zig compilation failed"),
					 errdetail("%s", plzig_format_output_units(res.output.data, res.output.len,
														   builddir, false, prog)),
					 plzig_discard_hint(res.output.data, res.output.len) ?
					 errhint("The generated function header (line 0) already marks every parameter as used, so a discard such as \"_ = name;\" is not needed: remove it.") : 0));
		}

		/* 3. collect the module */
		{
			size_t		rlen;

			plzig_path(path, "%s/out.wasm", builddir);
			wasm = plzig_read_file(path, (size_t) plzig_max_module_size * 1024, &rlen,
								   false, PLZIG_FILE_COMPILED);
			len = rlen;
		}
	}
	PG_FINALLY();
	{
		plzig_rmtree(builddir, WARNING);
		plzig_current_build_dir[0] = '\0';
	}
	PG_END_TRY();

	*wasm_len = (uint32) len;
	return wasm;
}

/* ---------------------------------------------------------------------
 * Module cache
 * ---------------------------------------------------------------------
 */
#define PLZIG_CACHE_FILE_MODULE	1	/* <64 hex>.wasm */
#define PLZIG_CACHE_FILE_TEMP	2	/* <64 hex>.wasm.tmp.<pid> */

/* Which kind of cache file is `name`?  0 = not one of ours: never touched. */
static int
plzig_cache_file_kind(const char *name)
{
	int			i;

	for (i = 0; i < 64; i++)
		if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f')))
			return 0;
	if (strcmp(name + 64, ".wasm") == 0)
		return PLZIG_CACHE_FILE_MODULE;
	if (strncmp(name + 64, ".wasm.tmp.", 10) == 0 && name[74] != '\0')
	{
		for (i = 74; name[i] != '\0'; i++)
			if (!isdigit((unsigned char) name[i]) || i >= 74 + 10)
				return 0;
		return PLZIG_CACHE_FILE_TEMP;
	}
	return 0;
}

typedef struct PlzigCacheEntry
{
	char		name[72];		/* 64 hex + ".wasm" */
	struct timespec mtime;
	uint64		size;
} PlzigCacheEntry;

static int
plzig_cache_entry_cmp(const void *a, const void *b)
{
	const PlzigCacheEntry *x = (const PlzigCacheEntry *) a;
	const PlzigCacheEntry *y = (const PlzigCacheEntry *) b;

	if (x->mtime.tv_sec != y->mtime.tv_sec)
		return x->mtime.tv_sec < y->mtime.tv_sec ? -1 : 1;
	if (x->mtime.tv_nsec != y->mtime.tv_nsec)
		return x->mtime.tv_nsec < y->mtime.tv_nsec ? -1 : 1;
	return strcmp(x->name, y->name);
}

/*
 * Cache maintenance, called with the compile lock held.  Only regular files
 * directly in cache/ whose names match the cache patterns are considered;
 * anything else is left alone.
 *
 *  - Temporary files (<key>.wasm.tmp.<pid>) are always removed: one exists
 *    only while its writer holds the compile lock, so with the lock held
 *    every one we see is a leftover of a failed or killed writer.
 *  - clear_all: every module is removed (plzig_cache_clear()).
 *  - Otherwise modules are evicted, least recently used (oldest mtime)
 *    first, until `incoming` more bytes fit in plzig.cache_size_limit.
 *
 * Eviction is safe: the cache is content-addressed and a miss recompiles;
 * a backend that already read or loaded a module is not affected by its
 * removal.  Returns the number of files removed.
 */
static int64
plzig_cache_maintain(const char *cache, uint64 incoming, bool clear_all)
{
	const char *shown = plzig_display_path(cache);
	DIR		   *dir;
	struct dirent *de;
	PlzigCacheEntry *ents = NULL;
	int			nents = 0;
	int			maxents = 0;
	uint64		total = 0;
	uint64		limit = (uint64) plzig_cache_size_limit * 1024 * 1024;
	int64		removed = 0;
	int			dfd;
	int			i;

	dir = AllocateDir(cache);
	if (dir == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open directory \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", cache)));
	dfd = dirfd(dir);
	if (dfd < 0)
	{
		int			save = errno;

		FreeDir(dir);
		errno = save;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open directory \"%s\": %m", shown),
				 errdetail_log("Full path: \"%s\".", cache)));
	}
	while ((de = ReadDirExtended(dir, shown, WARNING)) != NULL)
	{
		int			kind = plzig_cache_file_kind(de->d_name);
		struct stat st;

		if (kind == 0)
			continue;
		if (fstatat(dfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
			!S_ISREG(st.st_mode))
			continue;
		if (kind == PLZIG_CACHE_FILE_TEMP || clear_all)
		{
			if (unlinkat(dfd, de->d_name, 0) == 0)
				removed++;
			else if (errno != ENOENT)
				ereport(WARNING,
						(errcode_for_file_access(),
						 errmsg("could not remove file \"%s/%s\": %m", shown, de->d_name)));
			continue;
		}
		if (nents >= maxents)
		{
			maxents = maxents == 0 ? 256 : maxents * 2;
			ents = ents == NULL ? palloc(sizeof(PlzigCacheEntry) * maxents) :
				repalloc(ents, sizeof(PlzigCacheEntry) * maxents);
		}
		strlcpy(ents[nents].name, de->d_name, sizeof(ents[nents].name));
		ents[nents].mtime = st.st_mtim;
		/* sparse or not, count what the file could occupy */
		ents[nents].size = Max((uint64) st.st_size, (uint64) st.st_blocks * 512);
		total += ents[nents].size;
		nents++;
	}

	if (!clear_all && total + incoming > limit && nents > 0)
	{
		qsort(ents, nents, sizeof(PlzigCacheEntry), plzig_cache_entry_cmp);
		for (i = 0; i < nents && total + incoming > limit; i++)
		{
			struct stat st;

			/* still the regular file we saw? */
			if (fstatat(dfd, ents[i].name, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
				!S_ISREG(st.st_mode))
				continue;
			if (unlinkat(dfd, ents[i].name, 0) == 0)
			{
				removed++;
				total -= ents[i].size;
			}
			else if (errno != ENOENT)
				ereport(WARNING,
						(errcode_for_file_access(),
						 errmsg("could not remove file \"%s/%s\": %m", shown, ents[i].name)));
		}
	}
	FreeDir(dir);
	if (ents)
		pfree(ents);
	return removed;
}

/*
 * Write a module to its temp name, fsync, and rename it into place; the
 * temp file is removed again on every failure.
 */
static void
plzig_cache_install(const char *tmp, const char *final, const char *wasm, size_t len)
{
	PG_TRY();
	{
		plzig_write_file(tmp, wasm, len, true);
		/* relative paths: fd.c's messages must not show $PGDATA */
		if (durable_rename(plzig_display_path(tmp), plzig_display_path(final), ERROR) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not rename file \"%s\": %m", plzig_display_path(tmp))));
	}
	PG_CATCH();
	{
		(void) unlink(tmp);
		PG_RE_THROW();
	}
	PG_END_TRY();
}

/*
 * Return the compiled module for src (palloc'd).
 *
 * use_cache: look it up in the content-addressed cache and store it there
 * after compiling (functions).  Without it (DO blocks) the module is always
 * compiled, returned straight from the build directory and never written to
 * the cache: a DO block is run once, and caching it would let every
 * distinct block leave a file behind.
 */
char *
plzig_get_wasm(const PlzigProgram *prog, uint32 *wasm_len, bool use_cache)
{
	char		root[MAXPGPATH];
	char		cache[MAXPGPATH];
	char		zigcache[MAXPGPATH];
	char		key[65];
	char		final[MAXPGPATH];
	char		tmp[MAXPGPATH];
	char	   *volatile wasm = NULL;	/* set inside PG_TRY, read after it */
	volatile size_t len = 0;
	int			lockfd;

	if (!plzig_exit_registered)
	{
		before_shmem_exit(plzig_build_exit_cb, (Datum) 0);
		plzig_exit_registered = true;
	}

	plzig_load_sdk();
	plzig_cache_key(prog, key);
	plzig_dirs(root, cache, zigcache);
	plzig_path(final, "%s/%s.wasm", cache, key);

	if (use_cache)
	{
		size_t		rlen;
		char	   *hit = plzig_read_file(final, PLZIG_MAX_WASM_SIZE, &rlen, true,
										  PLZIG_FILE_CACHED);

		if (hit != NULL)
		{
			*wasm_len = (uint32) rlen;
			return hit;
		}
	}

	lockfd = plzig_lock(root);
	PG_TRY();
	{
		/* somebody else may have compiled it while we waited */
		if (use_cache)
		{
			size_t		rlen = 0;

			wasm = plzig_read_file(final, PLZIG_MAX_WASM_SIZE, &rlen, true,
								   PLZIG_FILE_CACHED);
			len = rlen;
		}
		if (wasm == NULL)
		{
			uint32		wlen;

			plzig_sweep_build_dirs(root);

			wasm = plzig_compile(root, zigcache, prog, &wlen);
			len = wlen;

			if (use_cache)
			{
				PlzigModule *mod;

				/* load-validate (imports, exports, ABI version) before caching */
				mod = plzig_module_load(wasm, wlen);
				plzig_module_unload(mod);

				/* make room (and drop stale temp files) before writing */
				(void) plzig_cache_maintain(cache, TYPEALIGN(4096, (uint64) len), false);

				plzig_path(tmp, "%s/%s.wasm.tmp.%d", cache, key, MyProcPid);
				plzig_cache_install(tmp, final, wasm, len);
			}
		}
	}
	PG_FINALLY();
	{
		CloseTransientFile(lockfd);
	}
	PG_END_TRY();

	*wasm_len = (uint32) len;
	return wasm;
}

/*
 * plzig_cache_clear(): remove every module (and leftover temp file) from the
 * cache, under the compile lock.  Returns the number of files removed.
 */
int64
plzig_cache_clear_files(void)
{
	char		root[MAXPGPATH];
	char		cache[MAXPGPATH];
	char		zigcache[MAXPGPATH];
	volatile int64 removed = 0;	/* set inside PG_TRY, read after it */
	int			lockfd;

	plzig_dirs(root, cache, zigcache);
	lockfd = plzig_lock(root);
	PG_TRY();
	{
		removed = plzig_cache_maintain(cache, 0, true);
	}
	PG_FINALLY();
	{
		CloseTransientFile(lockfd);
	}
	PG_END_TRY();
	return removed;
}

#ifdef PLZIG_TESTING
/* LCOV_EXCL_START (test helpers are not part of the coverage figures) */
/* ---------------------------------------------------------------------
 * Unit-test helpers, compiled only with -DPLZIG_TESTING (`make
 * PLZIG_TESTING=1`; never in a release build).  Declared and used by
 * test/sql/testing.sql only.
 * ---------------------------------------------------------------------
 */
#include "utils/builtins.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

PG_FUNCTION_INFO_V1(plzig_test_cache_key);
PG_FUNCTION_INFO_V1(plzig_test_zig_flags);
PG_FUNCTION_INFO_V1(plzig_test_display_path);
PG_FUNCTION_INFO_V1(plzig_test_path);
PG_FUNCTION_INFO_V1(plzig_test_format_output);
PG_FUNCTION_INFO_V1(plzig_test_cache_file_kind);
PG_FUNCTION_INFO_V1(plzig_test_sandbox_missing);
PG_FUNCTION_INFO_V1(plzig_test_replace_all);
PG_FUNCTION_INFO_V1(plzig_test_is_sha256_hex);
PG_FUNCTION_INFO_V1(plzig_test_sandbox_mode);

/* plzig_test_cache_key(src bytea) RETURNS text: the module cache key */
Datum
plzig_test_cache_key(PG_FUNCTION_ARGS)
{
	bytea	   *src = PG_GETARG_BYTEA_PP(0);
	char		key[65];

	plzig_load_sdk();
	plzig_cache_key(plzig_program_single(VARDATA_ANY(src), VARSIZE_ANY_EXHDR(src)), key);
	PG_RETURN_TEXT_P(cstring_to_text(key));
}

/* plzig_test_zig_flags() RETURNS text: the flags as hashed into the key */
Datum
plzig_test_zig_flags(PG_FUNCTION_ARGS)
{
	StringInfoData flags;
	int			i;

	initStringInfo(&flags);
	for (i = 0; plzig_zig_flags[i]; i++)
		appendStringInfo(&flags, "%s ", plzig_zig_flags[i]);
	PG_RETURN_TEXT_P(cstring_to_text(flags.data));
}

/* plzig_test_display_path(path text) RETURNS text */
Datum
plzig_test_display_path(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(plzig_display_path(text_to_cstring(PG_GETARG_TEXT_PP(0)))));
}

/*
 * plzig_test_path(path text) RETURNS text: the path builder; paths of
 * MAXPGPATH bytes or more are an error.  A NULL argument builds the
 * PL/Zig directories under the data directory and returns them.
 */
Datum
plzig_test_path(PG_FUNCTION_ARGS)
{
	char		dst[MAXPGPATH];

	if (PG_ARGISNULL(0))
	{
		char		root[MAXPGPATH];
		char		cache[MAXPGPATH];
		char		zigcache[MAXPGPATH];

		plzig_dirs(root, cache, zigcache);
		PG_RETURN_TEXT_P(cstring_to_text(psprintf("%s %s %s",
												  plzig_display_path(root),
												  plzig_display_path(cache),
												  plzig_display_path(zigcache))));
	}
	plzig_path(dst, "%s", text_to_cstring(PG_GETARG_TEXT_PP(0)));
	PG_RETURN_TEXT_P(cstring_to_text(dst));
}

/*
 * plzig_test_format_output(raw bytea, builddir text, validator bool) RETURNS text
 * Compiler/validator output as shown to the user.
 */
Datum
plzig_test_format_output(PG_FUNCTION_ARGS)
{
	bytea	   *raw = PG_GETARG_BYTEA_PP(0);

	PG_RETURN_TEXT_P(cstring_to_text(plzig_format_output(VARDATA_ANY(raw),
														 (int) VARSIZE_ANY_EXHDR(raw),
														 text_to_cstring(PG_GETARG_TEXT_PP(1)),
														 PG_GETARG_BOOL(2))));
}

/* plzig_test_cache_file_kind(name text) RETURNS int: 0 other, 1 module, 2 temp */
Datum
plzig_test_cache_file_kind(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(plzig_cache_file_kind(text_to_cstring(PG_GETARG_TEXT_PP(0))));
}

/* plzig_test_sandbox_missing(abi int, seccomp int) RETURNS text */
Datum
plzig_test_sandbox_missing(PG_FUNCTION_ARGS)
{
	StringInfoData buf;

	initStringInfo(&buf);
	plzig_sandbox_missing(&buf, PG_GETARG_INT32(0), PG_GETARG_INT32(1));
	PG_RETURN_TEXT_P(cstring_to_text(buf.data));
}

/* plzig_test_replace_all(s text, from text, to text) RETURNS text */
Datum
plzig_test_replace_all(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(plzig_replace_all(text_to_cstring(PG_GETARG_TEXT_PP(0)),
													   text_to_cstring(PG_GETARG_TEXT_PP(1)),
													   text_to_cstring(PG_GETARG_TEXT_PP(2)))));
}

/* plzig_test_is_sha256_hex(s text) RETURNS bool */
Datum
plzig_test_is_sha256_hex(PG_FUNCTION_ARGS)
{
	char	   *s = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char		buf[80];

	/* the check reads 65 bytes: give it a buffer that is at least that long */
	memset(buf, 0, sizeof(buf));
	strlcpy(buf, s, sizeof(buf));
	PG_RETURN_BOOL(strlen(s) < sizeof(buf) && plzig_is_sha256_hex(buf));
}

/* plzig_test_sandbox_mode() RETURNS int: plzig.compiler_sandbox as parsed */
Datum
plzig_test_sandbox_mode(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(plzig_sandbox_mode());
}
/* LCOV_EXCL_STOP */
#endif							/* PLZIG_TESTING */
