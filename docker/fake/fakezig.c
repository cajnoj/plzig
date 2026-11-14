/*
 * Test helper: a fake "zig" used via plzig.zig_path by docker/security-checks.sh.
 * Built with -DMODE=<n>.  Modes 1-4 write a hand-assembled out.wasm with a
 * forbidden import; mode 5 probes what the (sandboxed) compiler process can do.
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
#include <sys/socket.h>
#include <sys/wait.h>

#ifndef FAKE_VERSION
#define FAKE_VERSION "0.17.1"
#endif

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
	s = socket(AF_INET, SOCK_STREAM, 0);
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(5432);
	inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
	printf("tcp connect 127.0.0.1:5432: %s\n", connect(s, (void *) &a, sizeof(a)) == 0 ? "ALLOWED" : strerror(errno));
	printf("signal parent: %s\n", kill(getppid(), 0) == 0 ? "ALLOWED" : strerror(errno));
	return 1;
#endif
	return 0;
}
