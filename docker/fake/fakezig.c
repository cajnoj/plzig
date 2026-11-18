/*
 * Test helper: a fake "zig" used via plzig.zig_path by docker/security-checks.sh.
 * Built with -DMODE=<n>.  Modes 1-4 write a hand-assembled out.wasm with a
 * forbidden import; mode 5 probes what the (sandboxed) compiler process can do
 * (it only attempts each operation and prints the result) and reports the
 * process state it was started with (resource limits, environment, open
 * descriptors, signal mask and dispositions, no_new_privs, seccomp mode,
 * parent-death signal, session, umask, working directory); modes 8 and 9
 * write tiny modules that declare 0x3ff00000 locals in one function, or a
 * table of 130 million elements (each costs WAMR about 1 GB and, for the
 * locals, seconds of CPU unless PL/Zig refuses them first;
 * fuzz/loader/findings/wamr-huge-*.wasm); mode 10 writes a module that
 * declares 2 GB of initial memory, more than plzig.max_memory can ever
 * allow; mode 7 leaves
 * symbolic links to CANARY_DIR and a deep directory tree in its build
 * directory and fails, to test the backend's recursive delete.
 * "zig version" prints FAKE_VERSION, which the build must define: the
 * pinned version (third_party/zig-version.sh) for a compiler PL/Zig accepts,
 * -DFAKE_VERSION='"0.16.0"' for a wrong-version compiler.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <sys/ipc.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/resource.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>

#ifndef FAKE_VERSION
#error "FAKE_VERSION must be defined (-DFAKE_VERSION='\"<version>\"')"
#endif
#ifndef PGSOCK
#define PGSOCK "/tmp/.s.PGSQL.5432"
#endif
#ifndef CANARY_DIR
#define CANARY_DIR "/tmp/plzig-canary"
#endif

static const char *
res(int ok)
{
	return ok ? "ALLOWED" : strerror(errno);
}

/* run fn in a forked child (so that it cannot change this process) */
static void
in_child(const char *label, int (*fn) (void))
{
	pid_t		pid;
	int			st;

	fflush(stdout);
	pid = fork();
	if (pid == 0)
	{
		int			ok = fn() == 0;

		printf("%s: %s\n", label, res(ok));
		fflush(stdout);
		_exit(0);
	}
	if (pid < 0)
		printf("%s: fork: %s\n", label, strerror(errno));
	else
		waitpid(pid, &st, 0);
}

static int
do_setsid(void)
{
	return setsid() < 0 ? -1 : 0;
}

static int
do_setpgid(void)
{
	return setpgid(0, 0);
}

extern char **environ;

/* the state PL/Zig set up for the child before execve (plzig_spawn.c) */
static void
report_state(const char *pgdata)
{
	static const struct
	{
		int			r;
		const char *name;
	}			lims[] = {
		{RLIMIT_CORE, "core"}, {RLIMIT_CPU, "cpu"}, {RLIMIT_FSIZE, "fsize"}, {RLIMIT_AS, "as"}
	};
	struct rlimit rl;
	sigset_t	set;
	char		buf[1024];
	char		cwd[1024];
	size_t		n = 0;
	int			i;
	int			ndisp = 0;
	int			nblocked = 0;
	int			pdeath = -1;
	mode_t		old;
	struct stat st;

	for (i = 0; i < (int) (sizeof(lims) / sizeof(lims[0])); i++)
	{
		if (getrlimit(lims[i].r, &rl) != 0)
			printf("rlimit %s: %s\n", lims[i].name, strerror(errno));
		else if (rl.rlim_cur == RLIM_INFINITY)
			printf("rlimit %s: unlimited\n", lims[i].name);
		else
			printf("rlimit %s: %llu/%llu\n", lims[i].name,
				   (unsigned long long) rl.rlim_cur, (unsigned long long) rl.rlim_max);
	}
	/* changing a limit, even to its present value, is refused by the filter */
	if (getrlimit(RLIMIT_AS, &rl) == 0)
		printf("set rlimit: %s\n", setrlimit(RLIMIT_AS, &rl) == 0 ? "ALLOWED" : strerror(errno));
	buf[0] = '\0';
	for (i = 0; environ[i]; i++)
	{
		const char *eq = strchr(environ[i], '=');
		size_t		len = eq ? (size_t) (eq - environ[i]) : strlen(environ[i]);

		n += snprintf(buf + n, sizeof(buf) - n, "%s%.*s", i ? "," : "", (int) len, environ[i]);
		if (n >= sizeof(buf))
			break;
	}
	printf("env names: %s\n", buf);
	printf("env PATH=%s\n", getenv("PATH") ? getenv("PATH") : "(unset)");
	n = 0;
	buf[0] = '\0';
	for (i = 0; i < 1024; i++)
		if (fcntl(i, F_GETFD) != -1)
			n += snprintf(buf + n, sizeof(buf) - n, "%s%d", n ? "," : "", i);
	printf("open fds: %s\n", buf);
	if (fstat(0, &st) == 0)
		printf("stdin: %s\n", S_ISCHR(st.st_mode) ? "character device" : S_ISREG(st.st_mode) ? "regular file" : "other");
	sigemptyset(&set);
	sigprocmask(SIG_BLOCK, NULL, &set);
	for (i = 1; i < 32; i++)
	{
		struct sigaction sa;

		if (sigismember(&set, i) == 1)
			nblocked++;
		if (i != SIGKILL && i != SIGSTOP && sigaction(i, NULL, &sa) == 0 && sa.sa_handler != SIG_DFL)
			ndisp++;
	}
	printf("blocked signals: %d\n", nblocked);
	printf("non-default signal dispositions: %d\n", ndisp);
	printf("no_new_privs: %d\n", prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0));
	printf("seccomp mode: %d\n", prctl(PR_GET_SECCOMP, 0, 0, 0, 0));
	prctl(PR_GET_PDEATHSIG, &pdeath, 0, 0, 0);
	printf("parent-death signal: %d\n", pdeath);
	printf("session leader: %s\n", getsid(0) == getpid() ? "yes" : "no");
	printf("process group leader: %s\n", getpgrp() == getpid() ? "yes" : "no");
	old = umask(077);
	printf("umask: %04o\n", (unsigned) old);
	if (getcwd(cwd, sizeof(cwd)) != NULL)
	{
		const char *base = strrchr(cwd, '/');

		printf("cwd: %s\n", base && strncmp(base + 1, "pgsql_tmp.build.", 16) == 0 ? "build directory" : "elsewhere");
		printf("HOME is cwd: %s\n", getenv("HOME") && strcmp(getenv("HOME"), cwd) == 0 ? "yes" : "no");
	}
	snprintf(buf, sizeof(buf), "%s/postgresql.conf", pgdata);
	printf("hardlink to postgresql.conf: %s\n", res(link(buf, "hl") == 0));
	snprintf(buf, sizeof(buf), "%s/global/pg_control", pgdata);
	printf("hardlink to pg_control: %s\n", res(link(buf, "hl2") == 0));
	printf("move out of the build dir: %s\n", res(rename("src", "../plzig-moved-src") == 0));
	fflush(stdout);
}

static const unsigned char hdr[] = {0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00};
/* one type: (i32, i32) -> () */
static const unsigned char types[] = {0x01, 0x06, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x00};
/* import "env" "system" (func type 0) */
static const unsigned char imp_env[] = {0x02, 0x0e, 0x01, 0x03, 'e', 'n', 'v', 0x06, 's', 'y', 's', 't', 'e', 'm', 0x00, 0x00};
/* import "plzig" "exec" (func type 0) */
static const unsigned char imp_unknown[] = {0x02, 0x0e, 0x01, 0x05, 'p', 'l', 'z', 'i', 'g', 0x04, 'e', 'x', 'e', 'c', 0x00, 0x00};
/* import "plzig" "log" with type (i32, i32) instead of (i32, i32, i32) */
static const unsigned char imp_badsig[] = {0x02, 0x0d, 0x01, 0x05, 'p', 'l', 'z', 'i', 'g', 0x03, 'l', 'o', 'g', 0x00, 0x00};
/* import "plzig" "memory" (memory, min 1 page) */
static const unsigned char imp_mem[] = {0x02, 0x11, 0x01, 0x05, 'p', 'l', 'z', 'i', 'g', 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00, 0x01};

/* type () -> (); one function; its body declares 0x3ff00000 i32 locals */
static const unsigned char huge_locals[] = {
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
	0x03, 0x02, 0x01, 0x00,
	0x0a, 0x0a, 0x01, 0x08, 0x01, 0x80, 0x80, 0xc0, 0xff, 0x03, 0x7f, 0x0b
};

/* one table, funcref, initial size 0x07c00000 */
static const unsigned char huge_table[] = {
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	0x04, 0x07, 0x01, 0x70, 0x00, 0x80, 0x80, 0x80, 0x3e
};

/* memory of 32768 pages (2 GB), and 16 bytes of data at 0x10000 */
static const unsigned char memory_too_large[] = {
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	0x05, 0x05, 0x01, 0x00, 0x80, 0x80, 0x02,
	0x0b, 0x18, 0x01, 0x00, 0x41, 0x80, 0x80, 0x04, 0x0b, 0x10,
	'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A'
};

static void
emit_raw(const unsigned char *m, size_t len)
{
	FILE	   *f = fopen("out.wasm", "wb");

	fwrite(m, 1, len, f);
	fclose(f);
}

static void
emit(const unsigned char *imp, size_t len)
{
	FILE	   *f = fopen("out.wasm", "wb");

	fwrite(hdr, 1, sizeof(hdr), f);
	fwrite(types, 1, sizeof(types), f);
	fwrite(imp, 1, len, f);
	fclose(f);
}

static void
try_open_l(const char *label, const char *p, int fl)
{
	int			fd = open(p, fl, 0600);

	printf("%s: %s\n", label, fd >= 0 ? "ALLOWED" : strerror(errno));
	if (fd >= 0)
		close(fd);
}

static void
try_open(const char *p, int fl)
{
	char		label[600];

	snprintf(label, sizeof(label), "open %s", p);
	try_open_l(label, p, fl);
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "version") == 0)
	{
		printf("%s\n", FAKE_VERSION);
		return 0;
	}
#if MODE == 1
	emit(imp_env, sizeof(imp_env));
#elif MODE == 2
	emit(imp_unknown, sizeof(imp_unknown));
#elif MODE == 3
	emit(imp_badsig, sizeof(imp_badsig));
#elif MODE == 4
	emit(imp_mem, sizeof(imp_mem));
#elif MODE == 8
	emit_raw(huge_locals, sizeof(huge_locals));
#elif MODE == 9
	emit_raw(huge_table, sizeof(huge_table));
#elif MODE == 10
	emit_raw(memory_too_large, sizeof(memory_too_large));
#elif MODE == 5
	struct sockaddr_in a;
	int			s;
	const char *pgdata = PGDATA;
	char		path[512];

	report_state(pgdata);
	try_open("/etc/passwd", O_RDONLY);
	snprintf(path, sizeof(path), "%s/postgresql.conf", pgdata);
	try_open(path, O_RDONLY);
	snprintf(path, sizeof(path), "%s/plzig/cache/planted.wasm", pgdata);
	try_open(path, O_WRONLY | O_CREAT);
	try_open("/tmp/planted", O_WRONLY | O_CREAT);
	try_open("src/user.zig", O_RDONLY);
	{
		const char *lib = NULL;
		char		self[512];
		ssize_t		n;
		char	   *slash;
		pid_t		pid;
		int			st;
		int			i;

		for (i = 1; i + 1 < argc; i++)
			if (strcmp(argv[i], "--zig-lib-dir") == 0)
				lib = argv[i + 1];
		printf("zig-lib-dir=%s\n", lib ? lib : "(none)");
		if (lib)
		{
			snprintf(path, sizeof(path), "%s/std/std.zig", lib);
			try_open_l("read zig lib", path, O_RDONLY);
			snprintf(path, sizeof(path), "%s/planted", lib);
			try_open_l("write zig lib", path, O_WRONLY | O_CREAT);
		}
		n = readlink("/proc/self/exe", self, sizeof(self) - 1);
		if (n > 0)
		{
			self[n] = '\0';
			slash = strrchr(self, '/');
			if (slash)
				*slash = '\0';
			snprintf(path, sizeof(path), "%s/planted", self);
			try_open_l("write compiler dir", path, O_WRONLY | O_CREAT);
			snprintf(path, sizeof(path), "%s/../m1/zig", self);
			try_open_l("read other file near compiler", path, O_RDONLY);
		}
		fflush(stdout);
		pid = fork();
		if (pid == 0)
		{
			execl("/bin/true", "true", (char *) NULL);
			printf("exec /bin/true: %s\n", strerror(errno));
			fflush(stdout);
			_exit(127);
		}
		if (pid > 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 0)
			printf("exec /bin/true: ALLOWED\n");
	}
	printf("symlink in build dir: %s\n", res(symlink("src", "probe-link") == 0));

	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(5432);
	inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);

	s = socket(AF_INET, SOCK_STREAM, 0);
	printf("inet socket: %s\n", res(s >= 0));
	if (s >= 0)
		printf("tcp connect 127.0.0.1:5432: %s\n", res(connect(s, (void *) &a, sizeof(a)) == 0));
	else
		printf("tcp connect 127.0.0.1:5432: no socket (%s)\n", strerror(errno));

	s = socket(AF_INET, SOCK_DGRAM, 0);
	printf("udp socket: %s\n", res(s >= 0));
	if (s >= 0)
		printf("udp send 127.0.0.1:5432: %s\n", res(sendto(s, "x", 1, 0, (void *) &a, sizeof(a)) == 1));
	else
		printf("udp send 127.0.0.1:5432: no socket (%s)\n", strerror(errno));

	{
		struct sockaddr_un u;

		memset(&u, 0, sizeof(u));
		u.sun_family = AF_UNIX;
		strncpy(u.sun_path, PGSOCK, sizeof(u.sun_path) - 1);
		s = socket(AF_UNIX, SOCK_STREAM, 0);
		printf("unix socket: %s\n", res(s >= 0));
		if (s >= 0)
			printf("unix connect server socket: %s\n", res(connect(s, (void *) &u, sizeof(u)) == 0));
		else
			printf("unix connect server socket: no socket (%s)\n", strerror(errno));
	}

	printf("signal parent: %s\n", res(kill(getppid(), 0) == 0));
	printf("signal self: %s\n", res(kill(getpid(), 0) == 0));
	printf("ptrace attach parent: %s\n", res(ptrace(PTRACE_ATTACH, getppid(), 0, 0) == 0));
	printf("shmget: %s\n", res(shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600) >= 0));
	in_child("setsid in child", do_setsid);
	in_child("setpgid in child", do_setpgid);
	return 1;
#elif MODE == 7
	{
		char		path[64];
		int			i;
		FILE	   *f;

		printf("escape-dir: %s\n", res(symlink(CANARY_DIR, "escape-dir") == 0));
		printf("escape-file: %s\n", res(symlink(CANARY_DIR "/canary", "escape-file") == 0));
		printf("hardlink: %s\n", res(link(CANARY_DIR "/canary", "hardlink") == 0));
		/* 50 levels, each with a file and a link to the canary directory */
		for (i = 0; i < 50; i++)
		{
			snprintf(path, sizeof(path), "d%d", i);
			if (mkdir(path, 0700) != 0 || chdir(path) != 0)
			{
				printf("deep tree: %s at level %d\n", strerror(errno), i);
				break;
			}
			f = fopen("file", "w");
			if (f)
			{
				fputs("x", f);
				fclose(f);
			}
			(void) symlink(CANARY_DIR, "up");
		}
		printf("deep tree: %d levels\n", i);
		return 1;
	}
#endif
	return 0;
}
