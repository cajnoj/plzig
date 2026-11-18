/*-------------------------------------------------------------------------
 *
 * plzig_spawn.c
 *	  Running the validator and the compiler as confined child processes.
 *
 * fork() + execve() with an argv array (never a shell).  In the child,
 * before execve: new session, default signal dispositions, empty signal
 * mask, stdin from a file (or /dev/null), stdout+stderr to a pipe, every
 * other descriptor closed, chdir, umask 077, rlimits, no_new_privs,
 * Landlock, seccomp filter.  The child reports sandbox status (or a setup
 * failure) over a close-on-exec status pipe.
 *
 * The parent waits with WaitLatchOrSocket() so query cancel and
 * pg_terminate_backend work, enforces a wall-clock timeout, and always
 * kills the child's process group and reaps it, on every exit path:
 * normal, timeout, ERROR (PG_CATCH) and FATAL/proc_exit (atexit hook).
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

#include "miscadmin.h"
#include "storage/fd.h"
#include "storage/latch.h"
#include "utils/timestamp.h"
#include "utils/wait_event.h"

/* the child currently running, for cleanup on FATAL */
static pid_t plzig_child_pid = 0;

static void
kill_and_reap(pid_t pid)
{
	int			status;

	if (pid <= 0)
		return;
	/* the child is a session (and group) leader: take the whole group */
	(void) kill(-pid, SIGKILL);
	(void) kill(pid, SIGKILL);
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
}

void
plzig_spawn_atexit(void)
{
	if (plzig_child_pid > 0)
	{
		kill_and_reap(plzig_child_pid);
		plzig_child_pid = 0;
	}
}

/* ---- child side: plain system calls only ---- */

static void
child_write(int fd, const char *s)
{
	size_t		len = strlen(s);

	while (len > 0)
	{
		ssize_t		n = write(fd, s, len);

		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			return;
		}
		s += n;
		len -= (size_t) n;
	}
}

static void
child_fail(int status_fd, const char *msg)
{
	child_write(status_fd, "E");
	child_write(status_fd, msg);
	_exit(126);
}

static void
child_close_from(int lowfd)
{
#if defined(__linux__) && defined(SYS_close_range)
	if (syscall(SYS_close_range, (unsigned int) lowfd, ~0U, 0) == 0)
		return;
#endif
	{
		long		maxfd = sysconf(_SC_OPEN_MAX);
		int			fd;

		if (maxfd < 0 || maxfd > 65536)
			maxfd = 65536;
		for (fd = lowfd; fd < maxfd; fd++)
			(void) close(fd);
	}
}

/*
 * Limit a resource for the compiler: hard and soft limit where the kernel
 * lets this process lower its hard limit, else the soft limit alone.
 *
 * SELinux requires the "setrlimit" permission for any change of a hard
 * limit, lowering included, and the policy of the postgresql_t domain does
 * not grant it (setrlimit fails with EACCES).  A soft limit is enforced the
 * same way; what differs is that the process may raise it again, up to the
 * hard limit.  The seccomp filter refuses the compiler every change of a
 * resource limit (plzig_sandbox.c), so with the filter installed
 * (plzig.compiler_sandbox = require always; "try" where available) the soft
 * limit stays; without the filter a compiler that misbehaves could raise it.
 */
static void
child_setrlimit(int resource, uint64 value, int status_fd)
{
	struct rlimit rl;

	rl.rlim_cur = (rlim_t) value;
	rl.rlim_max = (rlim_t) value;
	if (setrlimit(resource, &rl) == 0)
		return;
	if (errno != EACCES && errno != EPERM)
		child_fail(status_fd, "setrlimit failed");
	if (getrlimit(resource, &rl) != 0)
		child_fail(status_fd, "getrlimit failed");
	if (rl.rlim_max != RLIM_INFINITY && rl.rlim_max < (rlim_t) value)
		return;					/* already limited more tightly */
	rl.rlim_cur = (rlim_t) value;
	if (setrlimit(resource, &rl) != 0)
		child_fail(status_fd, "setrlimit failed");
}

static void
child_main(const char *prog, char *const argv[], char *const envp[],
		   const char *cwd, int stdin_fd, int out_fd, int status_fd,
		   const PlzigSandbox *sb, pid_t parent)
{
	struct sigaction sa;
	sigset_t	all;
	int			sig;
	int			abi_used = 0;
	int			ll;
	int			sc;
	char		errbuf[128];
	char		msg[32];

	/* default dispositions for everything, then unblock */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_DFL;
	sigemptyset(&sa.sa_mask);
	for (sig = 1; sig < NSIG; sig++)
	{
		if (sig == SIGKILL || sig == SIGSTOP)
			continue;
		(void) sigaction(sig, &sa, NULL);
	}
	sigemptyset(&all);
	(void) sigprocmask(SIG_SETMASK, &all, NULL);

	if (setsid() < 0)
		child_fail(status_fd, "setsid failed");
#ifdef __linux__
	(void) prctl(PR_SET_PDEATHSIG, SIGKILL);
	if (getppid() != parent)
		_exit(126);
#endif

	/* descriptors: 0 = input, 1/2 = output pipe, 3 = status pipe */
	if (dup2(stdin_fd, 0) < 0 || dup2(out_fd, 1) < 0 || dup2(out_fd, 2) < 0)
		child_fail(status_fd, "dup2 failed");
	if (status_fd != 3)
	{
		if (dup2(status_fd, 3) < 0)
			child_fail(status_fd, "dup2 failed");
		status_fd = 3;
	}
	(void) fcntl(3, F_SETFD, FD_CLOEXEC);
	child_close_from(4);

	if (chdir(cwd) != 0)
		child_fail(status_fd, "chdir failed");
	umask(077);

	child_setrlimit(RLIMIT_CORE, 0, status_fd);
	if (sb->rlimit_cpu != 0)
		child_setrlimit(RLIMIT_CPU, sb->rlimit_cpu, status_fd);
	if (sb->rlimit_fsize != 0)
		child_setrlimit(RLIMIT_FSIZE, sb->rlimit_fsize, status_fd);
	if (sb->rlimit_as != 0)
		child_setrlimit(RLIMIT_AS, sb->rlimit_as, status_fd);

#ifdef __linux__
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
		child_fail(status_fd, "PR_SET_NO_NEW_PRIVS failed");
#endif

	errbuf[0] = '\0';
	ll = plzig_sandbox_apply_in_child(sb, &abi_used, errbuf, sizeof(errbuf));
	if (ll < 0 && sb->mode == PLZIG_SANDBOX_REQUIRE)
		child_fail(status_fd, errbuf);
	if (sb->mode == PLZIG_SANDBOX_REQUIRE && ll != 1)
		child_fail(status_fd, "landlock unavailable");

	/* last: the filter denies nothing the steps above still need */
	errbuf[0] = '\0';
	sc = plzig_seccomp_apply_in_child(sb, errbuf, sizeof(errbuf));
	if (sc < 0 && sb->mode == PLZIG_SANDBOX_REQUIRE)
		child_fail(status_fd, errbuf);
	if (sb->mode == PLZIG_SANDBOX_REQUIRE && sc != 1)
		child_fail(status_fd, "seccomp unavailable");

	/* report: "S<abi>,<seccomp>;" (abi 0 = no Landlock) */
	snprintf(msg, sizeof(msg), "S%d,%d;", ll == 1 ? abi_used : 0, sc == 1 ? 1 : 0);
	child_write(status_fd, msg);

	execve(prog, argv, envp);
	child_fail(status_fd, "execve failed");
}

/* ---- parent side ---- */

static void
set_nonblock(int fd)
{
	int			fl = fcntl(fd, F_GETFL);

	if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0)
		elog(ERROR, "fcntl failed: %m");
}

/*
 * Run prog with argv/envp in cwd. stdin_path (may be NULL = /dev/null) is
 * opened by the parent with O_NOFOLLOW.  Fills *res; raises ERROR on setup
 * failure, sandbox failure in 'require' mode, cancel, or timeout.
 */
/*
 * Set when the last plzig_spawn ended in plzig.compile_timeout (reported as
 * 57014 like a cancel); plzig_check_all() tells the two apart with it.
 */
bool		plzig_spawn_timed_out = false;

void
plzig_spawn(const char *prog, char *const argv[], char *const envp[],
			const char *cwd, const char *stdin_path,
			const PlzigSandbox *sb, int timeout_ms, PlzigSpawnResult *res)
{
	int			out_pipe[2] = {-1, -1};
	int			status_pipe[2] = {-1, -1};
	int			in_fd = -1;
	sigset_t	block_all;
	sigset_t	saved_mask;
	pid_t		pid;
	pid_t		parent = getpid();
	TimestampTz deadline;
	char		status_buf[256];
	/* set inside PG_TRY, read after it: volatile (setjmp/longjmp) */
	volatile int status_len = 0;
	bool		out_eof = false;
	volatile bool status_eof = false;
	volatile bool exited = false;
	int			wstatus = 0;

	memset(res, 0, sizeof(*res));
	initStringInfo(&res->output);
	res->exit_status = -1;
	plzig_spawn_timed_out = false;

	if (plzig_child_pid != 0)
		elog(ERROR, "PL/Zig: a child process is already running");

	in_fd = OpenTransientFile(stdin_path ? stdin_path : "/dev/null",
							  O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (in_fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m",
						stdin_path ? plzig_display_path(stdin_path) : "/dev/null")));

	if (pipe(out_pipe) != 0 || pipe(status_pipe) != 0)
	{
		int			save = errno;

		if (out_pipe[0] >= 0)
		{
			close(out_pipe[0]);
			close(out_pipe[1]);
		}
		CloseTransientFile(in_fd);
		errno = save;
		elog(ERROR, "could not create pipe: %m");
	}
	(void) fcntl(out_pipe[0], F_SETFD, FD_CLOEXEC);
	(void) fcntl(status_pipe[0], F_SETFD, FD_CLOEXEC);

	deadline = TimestampTzPlusMilliseconds(GetCurrentTimestamp(), timeout_ms);

	/* no PostgreSQL signal handler may run in the child before reset */
	sigfillset(&block_all);
	sigprocmask(SIG_SETMASK, &block_all, &saved_mask);
	fflush(NULL);
	pid = fork();
	if (pid == 0)
	{
		close(out_pipe[0]);
		close(status_pipe[0]);
		child_main(prog, argv, envp, cwd, in_fd, out_pipe[1], status_pipe[1],
				   sb, parent);
		_exit(127);				/* not reached */
	}
	sigprocmask(SIG_SETMASK, &saved_mask, NULL);

	close(out_pipe[1]);
	close(status_pipe[1]);
	CloseTransientFile(in_fd);

	if (pid < 0)
	{
		int			save = errno;

		close(out_pipe[0]);
		close(status_pipe[0]);
		errno = save;
		elog(ERROR, "could not fork: %m");
	}
	plzig_child_pid = pid;

	PG_TRY();
	{
		set_nonblock(out_pipe[0]);
		set_nonblock(status_pipe[0]);

		while (!exited || !out_eof)
		{
			char		buf[8192];
			ssize_t		n;
			long		remaining;
			siginfo_t	si;

			CHECK_FOR_INTERRUPTS();

			/* drain output (bounded) */
			while (!out_eof)
			{
				n = read(out_pipe[0], buf, sizeof(buf));
				if (n > 0)
				{
					int			keep = Min((int) n, PLZIG_MAX_OUTPUT - res->output.len);

					if (keep > 0)
						appendBinaryStringInfo(&res->output, buf, keep);
					continue;
				}
				if (n == 0)
					out_eof = true;
				else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
					out_eof = true;
				break;
			}
			/* drain status pipe */
			while (!status_eof)
			{
				n = read(status_pipe[0], status_buf + status_len,
						 sizeof(status_buf) - 1 - status_len);
				if (n > 0)
				{
					status_len += (int) n;
					if (status_len >= (int) sizeof(status_buf) - 1)
						status_eof = true;
					continue;
				}
				if (n == 0)
					status_eof = true;
				else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
					status_eof = true;
				break;
			}

			/* exited? (do not reap yet: keeps the pgid reserved) */
			if (!exited)
			{
				memset(&si, 0, sizeof(si));
				if (waitid(P_PID, (id_t) pid, &si, WEXITED | WNOHANG | WNOWAIT) == 0 &&
					si.si_pid == pid)
				{
					exited = true;
					/* leftover group members must not keep the pipe open */
					(void) kill(-pid, SIGKILL);
				}
			}
			if (exited && out_eof)
				break;

			remaining = (long) ((deadline - GetCurrentTimestamp()) / 1000);
			if (remaining <= 0)
			{
				res->timed_out = true;
				break;
			}

			(void) WaitLatchOrSocket(MyLatch,
									 WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH |
									 (out_eof ? 0 : WL_SOCKET_READABLE),
									 out_eof ? PGINVALID_SOCKET : out_pipe[0],
									 Min(remaining, exited ? 10L : 100L),
									 PG_WAIT_EXTENSION);
			ResetLatch(MyLatch);
		}
	}
	PG_CATCH();
	{
		kill_and_reap(pid);
		plzig_child_pid = 0;
		close(out_pipe[0]);
		close(status_pipe[0]);
		PG_RE_THROW();
	}
	PG_END_TRY();

	/* normal path: kill any leftover group members, then reap */
	(void) kill(-pid, SIGKILL);
	if (res->timed_out)
		(void) kill(pid, SIGKILL);
	while (waitpid(pid, &wstatus, 0) < 0 && errno == EINTR)
		;
	plzig_child_pid = 0;

	/* pick up anything written to the status pipe in the meantime */
	if (!status_eof)
	{
		ssize_t		n;

		while ((n = read(status_pipe[0], status_buf + status_len,
						 sizeof(status_buf) - 1 - status_len)) > 0)
		{
			status_len += (int) n;
			if (status_len >= (int) sizeof(status_buf) - 1)
				break;
		}
	}
	close(out_pipe[0]);
	close(status_pipe[0]);
	status_buf[status_len] = '\0';

	if (WIFEXITED(wstatus))
		res->exit_status = WEXITSTATUS(wstatus);
	else if (WIFSIGNALED(wstatus))
		res->term_signal = WTERMSIG(wstatus);

	if (res->timed_out)
	{
		plzig_spawn_timed_out = true;
		ereport(ERROR,
				(errcode(ERRCODE_QUERY_CANCELED),
				 errmsg("PL/Zig compilation timed out"),
				 errdetail("plzig.compile_timeout is %d ms.", timeout_ms)));
	}

	/* status protocol: "S<abi>,<seccomp>;" then optionally "E<message>" */
	if (status_buf[0] == 'S')
	{
		char	   *semi = strchr(status_buf, ';');
		char	   *comma = strchr(status_buf, ',');

		res->landlock_abi = atoi(status_buf + 1);
		res->sandboxed = res->landlock_abi > 0;
		res->seccomp = (comma != NULL && (semi == NULL || comma < semi) &&
						comma[1] == '1');
		if (semi && semi[1] == 'E')
			ereport(ERROR,
					(errcode(ERRCODE_SYSTEM_ERROR),
					 errmsg("PL/Zig: could not start helper program"),
					 errdetail("%s", semi + 2)));
	}
	else if (status_buf[0] == 'E')
		ereport(ERROR,
				(errcode(ERRCODE_SYSTEM_ERROR),
				 errmsg("PL/Zig: could not set up helper process"),
				 errdetail("%s", status_buf + 1)));
	else
		ereport(ERROR,
				(errcode(ERRCODE_SYSTEM_ERROR),
				 errmsg("PL/Zig: helper process exited during setup")));
}
