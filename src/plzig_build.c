/*-------------------------------------------------------------------------
 *
 * plzig_build.c
 *	  Compile pipeline: content-addressed cache, compile lock, private build
 *	  directory, policy validator, compiler, install into the cache.
 *
 * Every path is built from fixed names, the backend pid, a counter and hex
 * digests; nothing comes from user input.  Files are opened with O_NOFOLLOW
 * through PostgreSQL's transient-file wrappers (closed automatically on
 * ERROR); the recursive delete never follows symlinks.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
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

static char plzig_sandbox_status[160] = "no compilation in this session";
static bool plzig_sandbox_logged = false;
static bool plzig_swept = false;
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
	"--export=plzig_begin",
	"--export=plzig_alloc",
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

const char *
plzig_sandbox_status_string(void)
{
	return plzig_sandbox_status;
}

/* ---------------------------------------------------------------------
 * Paths and directories
 * ---------------------------------------------------------------------
 */
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

	if (lstat(path, &st) != 0)
	{
		if (errno != ENOENT)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not stat directory \"%s\": %m", path)));
		if (mkdir(path, S_IRWXU) != 0 && errno != EEXIST)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not create directory \"%s\": %m", path)));
		if (lstat(path, &st) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not stat directory \"%s\": %m", path)));
	}
	if (!S_ISDIR(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: \"%s\" is not a directory (or is a symbolic link)", path)));
	if (st.st_uid != geteuid())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: directory \"%s\" is not owned by the server user", path)));
	if ((st.st_mode & (S_IRWXG | S_IRWXO)) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: directory \"%s\" has group or other permissions", path),
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

/* Recursive delete that never follows symbolic links. */
static void
plzig_rmtree(const char *path, int depth)
{
	DIR		   *dir;
	struct dirent *de;
	struct stat st;

	if (depth > 64)
	{
		elog(WARNING, "PL/Zig: directory tree too deep, not removing \"%s\"", path);
		return;
	}
	if (lstat(path, &st) != 0)
		return;
	if (!S_ISDIR(st.st_mode))
	{
		(void) unlink(path);
		return;
	}
	dir = AllocateDir(path);
	if (dir == NULL)
	{
		elog(WARNING, "PL/Zig: could not open directory \"%s\": %m", path);
		return;
	}
	while ((de = ReadDirExtended(dir, path, WARNING)) != NULL)
	{
		char		child[MAXPGPATH];
		int			n;

		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;
		n = snprintf(child, sizeof(child), "%s/%s", path, de->d_name);
		if (n < 0 || n >= (int) sizeof(child))
			continue;
		if (lstat(child, &st) != 0)
			continue;
		if (S_ISDIR(st.st_mode))
			plzig_rmtree(child, depth + 1);
		else
			(void) unlink(child);
	}
	FreeDir(dir);
	if (rmdir(path) != 0 && errno != ENOENT)
		elog(WARNING, "PL/Zig: could not remove directory \"%s\": %m", path);
}

/* Remove build directories (and temp cache files) left by dead backends. */
static void
plzig_sweep_stale(const char *root, const char *cache)
{
	DIR		   *dir;
	struct dirent *de;

	dir = AllocateDir(root);
	if (dir != NULL)
	{
		while ((de = ReadDirExtended(dir, root, WARNING)) != NULL)
		{
			int			pid;
			unsigned int cnt;
			char		path[MAXPGPATH];

			if (strncmp(de->d_name, PLZIG_BUILD_PREFIX, strlen(PLZIG_BUILD_PREFIX)) != 0)
				continue;
			if (sscanf(de->d_name + strlen(PLZIG_BUILD_PREFIX), "%d.%u", &pid, &cnt) != 2)
				continue;
			if (pid == MyProcPid || pid <= 0)
				continue;
			if (kill(pid, 0) == 0 || errno != ESRCH)
				continue;		/* still alive (or not ours to judge) */
			if (snprintf(path, sizeof(path), "%s/%s", root, de->d_name) >= (int) sizeof(path))
				continue;
			plzig_rmtree(path, 0);
		}
		FreeDir(dir);
	}

	dir = AllocateDir(cache);
	if (dir != NULL)
	{
		while ((de = ReadDirExtended(dir, cache, WARNING)) != NULL)
		{
			const char *t = strstr(de->d_name, ".wasm.tmp.");
			char		path[MAXPGPATH];
			int			pid;

			if (t == NULL)
				continue;
			pid = atoi(t + strlen(".wasm.tmp."));
			if (pid <= 0 || pid == MyProcPid)
				continue;
			if (kill(pid, 0) == 0 || errno != ESRCH)
				continue;
			if (snprintf(path, sizeof(path), "%s/%s", cache, de->d_name) >= (int) sizeof(path))
				continue;
			(void) unlink(path);
		}
		FreeDir(dir);
	}
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
		plzig_rmtree(plzig_current_build_dir, 0);
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

	fd = OpenTransientFilePerm(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | PG_BINARY,
							   S_IRUSR | S_IWUSR);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create file \"%s\": %m", path)));
	while (off < len)
	{
		ssize_t		n = write(fd, data + off, len - off);

		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write file \"%s\": %m", path)));
		}
		off += (size_t) n;
	}
	if (sync && pg_fsync(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", path)));
	if (CloseTransientFile(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", path)));
}

/*
 * Read a whole file. Returns NULL if it does not exist (and missing_ok).
 * If private_check, the file must be a regular file owned by us, mode 0600.
 */
static char *
plzig_read_file(const char *path, size_t maxlen, size_t *len, bool missing_ok,
				bool private_check)
{
	int			fd;
	struct stat st;
	char	   *buf;
	size_t		off = 0;

	/* O_NONBLOCK: a FIFO planted by a compromised compiler must not hang us */
	fd = OpenTransientFile(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT && missing_ok)
			return NULL;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", path)));
	}
	if (fstat(fd, &st) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat file \"%s\": %m", path)));
	if (!S_ISREG(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: \"%s\" is not a regular file", path)));
	if (private_check &&
		(st.st_uid != geteuid() || (st.st_mode & (S_IRWXG | S_IRWXO)) != 0))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("PL/Zig: file \"%s\" has wrong owner or permissions", path)));
	if ((size_t) st.st_size > maxlen)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: file \"%s\" is too large", path)));

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
					 errmsg("could not read file \"%s\": %m", path)));
		}
		if (n == 0)
			break;
		off += (size_t) n;
	}
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
	plzig_sdk_plzig = plzig_read_file(path, 1024 * 1024, &plzig_sdk_plzig_len, false, false);
	plzig_path(path, "%s/plzig/sdk/root.zig", share);
	plzig_sdk_root = plzig_read_file(path, 1024 * 1024, &plzig_sdk_root_len, false, false);
	MemoryContextSwitchTo(old);

	parts[0] = plzig_sdk_plzig;
	lens[0] = plzig_sdk_plzig_len;
	parts[1] = plzig_sdk_root;
	lens[1] = plzig_sdk_root_len;
	plzig_sha256_parts(parts, lens, 2, plzig_sdk_digest);
}

static void
plzig_cache_key(const char *src, size_t srclen, char *hex)
{
	StringInfoData flags;
	const char *parts[5];
	size_t		lens[5];
	char		abi[16];
	int			i;

	initStringInfo(&flags);
	for (i = 0; plzig_zig_flags[i]; i++)
		appendStringInfo(&flags, "%s ", plzig_zig_flags[i]);
	snprintf(abi, sizeof(abi), "abi%d", PLZIG_ABI_VERSION);

	parts[0] = abi;
	lens[0] = strlen(abi);
	parts[1] = PLZIG_ZIG_VERSION;
	lens[1] = strlen(PLZIG_ZIG_VERSION);
	parts[2] = flags.data;
	lens[2] = flags.len;
	parts[3] = plzig_sdk_digest;
	lens[3] = strlen(plzig_sdk_digest);
	parts[4] = src;
	lens[4] = srclen;
	plzig_sha256_parts(parts, lens, 5, hex);
	pfree(flags.data);
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
				 errmsg("could not open file \"%s\": %m", path)));
	for (;;)
	{
		if (flock(fd, LOCK_EX | LOCK_NB) == 0)
			break;
		if (errno != EWOULDBLOCK && errno != EINTR)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not lock file \"%s\": %m", path)));
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
 * install paths, map user.zig line numbers to function body lines, and make
 * sure the result is valid in the database encoding.
 */
static char *
plzig_format_output(const char *raw, int rawlen, const char *builddir,
					bool validator)
{
	StringInfoData b;
	char	   *s;
	char	   *tmp;
	char		prefix[MAXPGPATH + 2];
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

	snprintf(prefix, sizeof(prefix), "%s/", builddir);
	tmp = plzig_replace_all(s, prefix, "");
	s = plzig_replace_all(tmp, pkglib_path, "$libdir");
	if (plzig_tc.lib[0] != '\0')
	{
		snprintf(prefix, sizeof(prefix), "%s/", plzig_tc.lib);
		s = plzig_replace_all(s, prefix, "<zig lib>/");
	}

	initStringInfo(&b);
	p = s;
	while (*p)
	{
		/* at the start of a line (validator) or at "src/user.zig:" (zig) */
		bool		at_marker;

		if (validator)
			at_marker = (p == s || p[-1] == '\n') && isdigit((unsigned char) *p);
		else
			at_marker = strncmp(p, marker, ml) == 0 &&
				isdigit((unsigned char) p[ml]);

		if (at_marker)
		{
			char	   *end;
			long		line;
			long		col = 0;

			line = strtol(p + ml, &end, 10);
			if (*end == ':' && isdigit((unsigned char) end[1]))
			{
				col = strtol(end + 1, &end, 10);
				if (*end == ':')
				{
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

	if (!pg_verifymbstr(b.data, b.len, true))
	{
		for (i = 0; i < b.len; i++)
		{
			unsigned char c = (unsigned char) b.data[i];

			if (c >= 0x80 || (c < 0x20 && c != '\n' && c != '\t'))
				b.data[i] = '?';
		}
	}
	return b.data;
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
		for (i = 0; i < lengthof(layouts); i++)
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

static void
plzig_setup_sandbox(PlzigSandbox *sb, const char *builddir, const char *zigcache,
					const char *validator, const char *zigbin, const char *ziglib)
{
	memset(sb, 0, sizeof(*sb));
	sb->mode = plzig_sandbox_mode();
	sb->landlock_abi = (sb->mode == PLZIG_SANDBOX_OFF) ? 0 : plzig_landlock_probe();

	if (sb->mode == PLZIG_SANDBOX_REQUIRE && sb->landlock_abi <= 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig: Landlock is not available, and plzig.compiler_sandbox = require"),
				 errdetail("landlock_create_ruleset returned %d; functions whose modules are already cached still run.",
						   sb->landlock_abi),
				 errhint("An administrator can set plzig.compiler_sandbox = try in postgresql.conf to compile without confinement; the compiler then runs with the full rights of the server's operating-system user.")));
	if (sb->mode == PLZIG_SANDBOX_TRY && sb->landlock_abi <= 0 && !plzig_sandbox_logged)
	{
		ereport(LOG,
				(errmsg("PL/Zig: Landlock is not available (landlock_create_ruleset returned %d); the compiler runs without filesystem confinement",
						sb->landlock_abi)));
		plzig_sandbox_logged = true;
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

static void
plzig_record_sandbox(const PlzigSpawnResult *res, const PlzigSandbox *sb)
{
	if (res->sandboxed)
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "enforced (landlock ABI %d)", res->landlock_abi);
	else if (sb->mode == PLZIG_SANDBOX_OFF)
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "off (plzig.compiler_sandbox = off)");
	else
		snprintf(plzig_sandbox_status, sizeof(plzig_sandbox_status),
				 "unavailable (landlock_create_ruleset returned %d)", sb->landlock_abi);
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
static char *
plzig_compile(const char *root, const char *zigcache, const char *src, size_t srclen,
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
	char	   *argv[64];
	PlzigSandbox sb;
	PlzigSpawnResult res;
	char	   *wasm = NULL;
	size_t		len = 0;
	int			i;
	int			n;

	/* before anything is created or run: path, ownership, mode, checksum */
	need_version = plzig_check_toolchain(zigbin, ziglib);
	plzig_path(validator, "%s/plzig/plzig-validate", pkglib_path);

	plzig_path(builddir, "%s/%s%d.%u", root, PLZIG_BUILD_PREFIX, MyProcPid,
			   ++plzig_build_counter);
	if (mkdir(builddir, S_IRWXU) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create directory \"%s\": %m", builddir)));
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
		plzig_path(path, "%s/src/user.zig", builddir);
		plzig_write_file(path, src, srclen, false);

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

		/* 1. lexical policy check */
		argv[0] = validator;
		argv[1] = NULL;
		plzig_spawn(validator, argv, envp, builddir, path, &sb,
					plzig_compile_timeout, &res);
		plzig_record_sandbox(&res, &sb);
		if (res.exit_status == 1)
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("PL/Zig source rejected by policy"),
					 errdetail("%s", plzig_format_output(res.output.data, res.output.len,
														 builddir, true))));
		if (res.exit_status != 0)
			ereport(ERROR,
					(errcode(ERRCODE_SYSTEM_ERROR),
					 errmsg("PL/Zig source validator failed (status %d, signal %d)",
							res.exit_status, res.term_signal),
					 errdetail("%s", plzig_format_output(res.output.data, res.output.len,
														 builddir, true))));

		/* 2. compile */
		n = 0;
		argv[n++] = zigbin;
		for (i = 0; plzig_zig_flags[i]; i++)
		{
			argv[n++] = (char *) plzig_zig_flags[i];
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
		Assert(n < lengthof(argv));

		plzig_spawn(zigbin, argv, envp, builddir, NULL, &sb,
					plzig_compile_timeout, &res);
		plzig_record_sandbox(&res, &sb);
		if (res.exit_status != 0)
		{
			if (res.term_signal != 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYSTEM_ERROR),
						 errmsg("PL/Zig compiler terminated by signal %d", res.term_signal),
						 errdetail("%s", plzig_format_output(res.output.data, res.output.len,
															 builddir, false)),
						 errhint("Check plzig.compile_memory_limit and plzig.compile_timeout.")));
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("PL/Zig compilation failed"),
					 errdetail("%s", plzig_format_output(res.output.data, res.output.len,
														 builddir, false))));
		}

		/* 3. collect the module */
		plzig_path(path, "%s/out.wasm", builddir);
		wasm = plzig_read_file(path, PLZIG_MAX_WASM_SIZE, &len, false, false);
	}
	PG_FINALLY();
	{
		plzig_rmtree(builddir, 0);
		plzig_current_build_dir[0] = '\0';
	}
	PG_END_TRY();

	*wasm_len = (uint32) len;
	return wasm;
}

/*
 * Return the compiled module for src (palloc'd), compiling it if it is not
 * in the cache.
 */
char *
plzig_get_wasm(const char *src, size_t srclen, uint32 *wasm_len)
{
	char		root[MAXPGPATH];
	char		cache[MAXPGPATH];
	char		zigcache[MAXPGPATH];
	char		key[65];
	char		final[MAXPGPATH];
	char		tmp[MAXPGPATH];
	char	   *wasm;
	size_t		len;
	int			lockfd;

	if (!plzig_exit_registered)
	{
		before_shmem_exit(plzig_build_exit_cb, (Datum) 0);
		plzig_exit_registered = true;
	}

	plzig_load_sdk();
	plzig_cache_key(src, srclen, key);
	plzig_dirs(root, cache, zigcache);
	plzig_path(final, "%s/%s.wasm", cache, key);

	wasm = plzig_read_file(final, PLZIG_MAX_WASM_SIZE, &len, true, true);
	if (wasm != NULL)
	{
		*wasm_len = (uint32) len;
		return wasm;
	}

	lockfd = plzig_lock(root);
	PG_TRY();
	{
		/* somebody else may have compiled it while we waited */
		wasm = plzig_read_file(final, PLZIG_MAX_WASM_SIZE, &len, true, true);
		if (wasm == NULL)
		{
			uint32		wlen;
			PlzigModule *mod;

			if (!plzig_swept)
			{
				plzig_sweep_stale(root, cache);
				plzig_swept = true;
			}

			wasm = plzig_compile(root, zigcache, src, srclen, &wlen);
			len = wlen;

			/* load-validate (imports, exports, ABI version) before caching */
			mod = plzig_module_load(wasm, wlen);
			plzig_module_unload(mod);

			plzig_path(tmp, "%s/%s.wasm.tmp.%d", cache, key, MyProcPid);
			if (unlink(tmp) != 0 && errno != ENOENT)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not remove file \"%s\": %m", tmp)));
			plzig_write_file(tmp, wasm, len, true);
			if (durable_rename(tmp, final, ERROR) != 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not rename file \"%s\": %m", tmp)));
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
