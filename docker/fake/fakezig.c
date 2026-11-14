/*
 * Test helper: a fake "zig" used via plzig.zig_path by docker/security-checks.sh.
 * Built with -DMODE=<n>.  Modes 1-4 write a hand-assembled out.wasm with a
 * forbidden import; mode 5 probes what the (sandboxed) compiler process can do
 * (it only attempts each operation and prints the result); mode 7 leaves
 * symbolic links to CANARY_DIR and a deep directory tree in its build
 * directory and fails, to test the backend's recursive delete.
 * "zig version" prints FAKE_VERSION (default 0.17.1, the version PL/Zig
 * requires); building with -DFAKE_VERSION='"0.16.0"' makes a wrong-version
 * compiler.
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
#include <sys/ptrace.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>

#ifndef FAKE_VERSION
#define FAKE_VERSION "0.17.1"
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
#elif MODE == 5
	struct sockaddr_in a;
	int			s;
	const char *pgdata = PGDATA;
	char		path[512];

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
