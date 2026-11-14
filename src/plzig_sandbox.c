/*-------------------------------------------------------------------------
 *
 * plzig_sandbox.c
 *	  Landlock confinement for the compiler child process (Linux only).
 *
 * plzig_sandbox_apply_in_child() and plzig_seccomp_apply_in_child() run in
 * the forked child between fork() and execve(): they must not call any
 * PostgreSQL function (no elog, no palloc), only plain system calls.  The
 * Landlock UAPI is declared locally so the build does not depend on the
 * kernel headers' Landlock version.
 *
 * Landlock rights by ABI (from include/uapi/linux/landlock.h and
 * Documentation/userspace-api/landlock.rst in the Linux sources):
 *   1  filesystem access rights (bits 0-12)
 *   2  FS_REFER                       3  FS_TRUNCATE
 *   4  NET_BIND_TCP, NET_CONNECT_TCP  5  FS_IOCTL_DEV
 *   6  SCOPE_ABSTRACT_UNIX_SOCKET, SCOPE_SIGNAL
 *   7  audit logging flags for landlock_restrict_self (no access rights)
 *   8  RESTRICT_SELF_TSYNC (no access rights; the child is single-threaded)
 *   9  FS_RESOLVE_UNIX: connect/sendmsg to pathname UNIX sockets
 *  10  NET_BIND_UDP, NET_CONNECT_SEND_UDP (plus audit "quiet" fields)
 * Every right the kernel reports is handled; none of the network or
 * RESOLVE_UNIX rights is granted by any rule, so they are all denied.
 *
 * The seccomp filter is a deny list independent of Landlock: networking,
 * cross-process access, signals to other processes, leaving the process
 * group, namespaces, mounts and a few kernel interfaces a compiler never
 * needs.  Denied calls fail with EPERM (a compiler that merely probes keeps
 * working); clone3 fails with ENOSYS so that callers fall back to clone,
 * whose flags the filter can inspect.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#ifdef __linux__
#include <stddef.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

#ifdef __linux__

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif

#define PLZIG_LL_CREATE_RULESET_VERSION	(1U << 0)
#define PLZIG_LL_RULE_PATH_BENEATH		1

#define LL_FS_EXECUTE		(1ULL << 0)
#define LL_FS_WRITE_FILE	(1ULL << 1)
#define LL_FS_READ_FILE		(1ULL << 2)
#define LL_FS_READ_DIR		(1ULL << 3)
#define LL_FS_REMOVE_DIR	(1ULL << 4)
#define LL_FS_REMOVE_FILE	(1ULL << 5)
#define LL_FS_MAKE_CHAR		(1ULL << 6)
#define LL_FS_MAKE_DIR		(1ULL << 7)
#define LL_FS_MAKE_REG		(1ULL << 8)
#define LL_FS_MAKE_SOCK		(1ULL << 9)
#define LL_FS_MAKE_FIFO		(1ULL << 10)
#define LL_FS_MAKE_BLOCK	(1ULL << 11)
#define LL_FS_MAKE_SYM		(1ULL << 12)
#define LL_FS_REFER			(1ULL << 13)	/* ABI 2 */
#define LL_FS_TRUNCATE		(1ULL << 14)	/* ABI 3 */
#define LL_FS_IOCTL_DEV		(1ULL << 15)	/* ABI 5 */
#define LL_FS_RESOLVE_UNIX	(1ULL << 16)	/* ABI 9 */

#define LL_NET_BIND_TCP		(1ULL << 0) /* ABI 4 */
#define LL_NET_CONNECT_TCP	(1ULL << 1) /* ABI 4 */
#define LL_NET_BIND_UDP		(1ULL << 2) /* ABI 10 */
#define LL_NET_CONNECT_SEND_UDP (1ULL << 3) /* ABI 10 */

#define LL_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)	/* ABI 6 */
#define LL_SCOPE_SIGNAL		(1ULL << 1) /* ABI 6 */

struct plzig_ll_ruleset_attr
{
	uint64		handled_access_fs;
	uint64		handled_access_net;
	uint64		scoped;
};

struct plzig_ll_path_beneath_attr
{
	uint64		allowed_access;
	int32		parent_fd;
} __attribute__((packed));

#endif							/* __linux__ */

/*
 * Return the Landlock ABI version supported by the running kernel, or a
 * value <= 0 if Landlock is unavailable (not built in, disabled, or blocked
 * by seccomp).
 */
int
plzig_landlock_probe(void)
{
#ifdef __linux__
	long		v;

	v = syscall(__NR_landlock_create_ruleset, NULL, (size_t) 0,
				PLZIG_LL_CREATE_RULESET_VERSION);
	if (v < 0)
		return -errno;
	return (int) v;
#else
	return -ENOSYS;
#endif
}

#ifdef __linux__
static size_t
child_strlcpy(char *dst, const char *src, size_t len)
{
	size_t		i = 0;

	if (len == 0)
		return 0;
	for (; i + 1 < len && src[i]; i++)
		dst[i] = src[i];
	dst[i] = '\0';
	return i;
}

static int
add_path_rule(int ruleset_fd, const char *path, uint64 access,
			  char *errbuf, size_t errlen)
{
	struct plzig_ll_path_beneath_attr pb;
	int			fd;
	int			rc;

	fd = open(path, O_PATH | O_CLOEXEC);
	if (fd < 0)
	{
		child_strlcpy(errbuf, "landlock: cannot open sandbox path", errlen);
		return -1;
	}
	pb.allowed_access = access;
	pb.parent_fd = fd;
	rc = (int) syscall(__NR_landlock_add_rule, ruleset_fd,
					   PLZIG_LL_RULE_PATH_BENEATH, &pb, 0);
	close(fd);
	if (rc != 0)
	{
		child_strlcpy(errbuf, "landlock: add_rule failed", errlen);
		return -1;
	}
	return 0;
}
#endif

/*
 * Apply the Landlock ruleset in the child.  Returns 1 if enforced, 0 if not
 * attempted/unavailable, -1 on failure (errbuf filled).  PR_SET_NO_NEW_PRIVS
 * must already be set.
 */
int
plzig_sandbox_apply_in_child(const PlzigSandbox *sb, int *abi_used,
							 char *errbuf, size_t errlen)
{
#ifdef __linux__
	struct plzig_ll_ruleset_attr attr;
	size_t		attr_size;
	uint64		fs_all;
	uint64		rx_file;
	uint64		ro;
	uint64		rw;
	int			abi = sb->landlock_abi;
	int			ruleset_fd;
	int			i;

	*abi_used = 0;
	if (sb->mode == PLZIG_SANDBOX_OFF || abi <= 0)
		return 0;

	fs_all = LL_FS_EXECUTE | LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_READ_DIR |
		LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE | LL_FS_MAKE_CHAR | LL_FS_MAKE_DIR |
		LL_FS_MAKE_REG | LL_FS_MAKE_SOCK | LL_FS_MAKE_FIFO | LL_FS_MAKE_BLOCK |
		LL_FS_MAKE_SYM;
	if (abi >= 2)
		fs_all |= LL_FS_REFER;
	if (abi >= 3)
		fs_all |= LL_FS_TRUNCATE;
	if (abi >= 5)
		fs_all |= LL_FS_IOCTL_DEV;
	if (abi >= 9)
		fs_all |= LL_FS_RESOLVE_UNIX;	/* no rule grants it: all denied */

	/*
	 * Executables get a rule on the file itself (Landlock allows only file
	 * rights there): execve() needs EXECUTE and READ_FILE on the file, and
	 * nothing in the directory around it becomes readable or executable.
	 * A dynamically linked program would additionally need its loader and
	 * libraries; plzig_build.c refuses such a compiler up front.
	 *
	 * Read-write directories get what Zig 0.17.1 was observed to use (strace
	 * of cold and warm compiles): create/remove files and directories,
	 * truncate, and rename between cache subdirectories (REFER).  No
	 * symbolic links, sockets, FIFOs or device nodes.
	 */
	rx_file = LL_FS_EXECUTE | LL_FS_READ_FILE;
	ro = LL_FS_READ_FILE | LL_FS_READ_DIR;
	rw = (LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_READ_DIR |
		  LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE | LL_FS_MAKE_DIR |
		  LL_FS_MAKE_REG | LL_FS_REFER | LL_FS_TRUNCATE) & fs_all;

	memset(&attr, 0, sizeof(attr));
	attr.handled_access_fs = fs_all;
	attr_size = sizeof(uint64);
	if (abi >= 4)
	{
		/* handle TCP (and from ABI 10 UDP) with no rules: all denied */
		attr.handled_access_net = LL_NET_BIND_TCP | LL_NET_CONNECT_TCP;
		if (abi >= 10)
			attr.handled_access_net |= LL_NET_BIND_UDP | LL_NET_CONNECT_SEND_UDP;
		attr_size = 2 * sizeof(uint64);
	}
	if (abi >= 6)
	{
		/* no signals to / abstract sockets of processes outside the domain */
		attr.scoped = LL_SCOPE_ABSTRACT_UNIX_SOCKET | LL_SCOPE_SIGNAL;
		attr_size = 3 * sizeof(uint64);
	}

	ruleset_fd = (int) syscall(__NR_landlock_create_ruleset, &attr, attr_size, 0);
	if (ruleset_fd < 0)
	{
		child_strlcpy(errbuf, "landlock: create_ruleset failed", errlen);
		return -1;
	}

	for (i = 0; i < sb->n_rx_files; i++)
		if (add_path_rule(ruleset_fd, sb->rx_files[i], rx_file, errbuf, errlen) != 0)
			goto fail;
	for (i = 0; i < sb->n_ro; i++)
		if (add_path_rule(ruleset_fd, sb->ro_dirs[i], ro, errbuf, errlen) != 0)
			goto fail;
	for (i = 0; i < sb->n_rw; i++)
		if (add_path_rule(ruleset_fd, sb->rw_dirs[i], rw, errbuf, errlen) != 0)
			goto fail;
	/* /dev/null: read/write only (not a directory, so file rights only) */
	if (access("/dev/null", F_OK) == 0)
		if (add_path_rule(ruleset_fd, "/dev/null",
						  LL_FS_READ_FILE | LL_FS_WRITE_FILE, errbuf, errlen) != 0)
			goto fail;

	if (syscall(__NR_landlock_restrict_self, ruleset_fd, 0) != 0)
	{
		child_strlcpy(errbuf, "landlock: restrict_self failed", errlen);
		goto fail;
	}
	close(ruleset_fd);
	*abi_used = abi;
	return 1;

fail:
	close(ruleset_fd);
	return -1;
#else
	*abi_used = 0;
	return 0;
#endif
}

/* ---------------------------------------------------------------------
 * seccomp-bpf deny filter
 * ---------------------------------------------------------------------
 */
#if defined(__linux__) && defined(SECCOMP_MODE_FILTER) && \
	defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && \
	((defined(__x86_64__) && !defined(__ILP32__)) || defined(__aarch64__))
#define PLZIG_HAVE_SECCOMP 1
#if defined(__x86_64__)
#define PLZIG_SECCOMP_ARCH AUDIT_ARCH_X86_64
#else
#define PLZIG_SECCOMP_ARCH AUDIT_ARCH_AARCH64
#endif
#endif

#ifdef PLZIG_HAVE_SECCOMP

/* system calls that fail with EPERM unconditionally */
static const int plzig_denied_syscalls[] = {
	/* networking: the compiler opens no sockets of any family */
	__NR_socket, __NR_socketpair, __NR_connect, __NR_bind, __NR_listen,
	__NR_accept, __NR_accept4, __NR_sendto, __NR_sendmsg, __NR_recvfrom,
	__NR_recvmsg, __NR_shutdown, __NR_getsockopt, __NR_setsockopt,
	__NR_getsockname, __NR_getpeername,
#ifdef __NR_sendmmsg
	__NR_sendmmsg,
#endif
#ifdef __NR_recvmmsg
	__NR_recvmmsg,
#endif
	/* other processes' memory and descriptors */
	__NR_ptrace, __NR_process_vm_readv, __NR_process_vm_writev,
#ifdef __NR_kcmp
	__NR_kcmp,
#endif
#ifdef __NR_pidfd_open
	__NR_pidfd_open,
#endif
#ifdef __NR_pidfd_getfd
	__NR_pidfd_getfd,
#endif
#ifdef __NR_pidfd_send_signal
	__NR_pidfd_send_signal,
#endif
#ifdef __NR_process_madvise
	__NR_process_madvise,
#endif
	/* stay in the process group the backend kills */
	__NR_setsid, __NR_setpgid,
	/* System V IPC */
	__NR_shmget, __NR_shmat, __NR_shmctl, __NR_shmdt,
	__NR_semget, __NR_semop, __NR_semctl, __NR_semtimedop,
	__NR_msgget, __NR_msgsnd, __NR_msgrcv, __NR_msgctl,
	/* mounts and namespaces */
	__NR_mount, __NR_umount2, __NR_pivot_root, __NR_chroot,
	__NR_unshare, __NR_setns,
#ifdef __NR_open_tree
	__NR_open_tree, __NR_move_mount, __NR_fsopen, __NR_fsconfig,
	__NR_fsmount, __NR_fspick,
#endif
#ifdef __NR_mount_setattr
	__NR_mount_setattr,
#endif
	/* kernel interfaces with a history of exploits, never needed here */
	__NR_bpf, __NR_perf_event_open, __NR_userfaultfd,
#ifdef __NR_io_uring_setup
	__NR_io_uring_setup, __NR_io_uring_enter, __NR_io_uring_register,
#endif
	__NR_keyctl, __NR_add_key, __NR_request_key,
	__NR_kexec_load,
#ifdef __NR_kexec_file_load
	__NR_kexec_file_load,
#endif
	__NR_init_module, __NR_finit_module, __NR_delete_module,
	__NR_open_by_handle_at, __NR_personality,
};

/* allowed only when the first argument is the compiler's own pid/tgid */
static const int plzig_self_only_syscalls[] = {
	__NR_kill, __NR_tkill, __NR_tgkill, __NR_rt_sigqueueinfo,
	__NR_rt_tgsigqueueinfo,
};

#define PLZIG_SC_MAX_INSNS 256
#define PLZIG_SC_ARG_LO(i) \
	((uint32) (offsetof(struct seccomp_data, args) + (i) * sizeof(uint64)))
#define PLZIG_SC_EPERM		(SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA))
#define PLZIG_SC_ENOSYS		(SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA))

/* clone() flags that create namespaces, or make the new process a sibling */
#define PLZIG_CLONE_DENIED \
	(CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC | \
	 CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNET | CLONE_PARENT)

/* fcntl() commands that direct SIGIO/SIGURG at another process */
#ifndef F_SETOWN
#define F_SETOWN 8
#endif
#ifndef F_SETOWN_EX
#define F_SETOWN_EX 15
#endif
#ifndef F_SETSIG
#define F_SETSIG 10
#endif

#endif							/* PLZIG_HAVE_SECCOMP */

/*
 * Can the seccomp filter be installed?  0 if so, else -errno (-ENOSYS when
 * PL/Zig has no filter for this architecture).  A NULL program makes the
 * kernel fail with EFAULT after it has checked that filter mode exists and
 * before anything is installed (EACCES, "no_new_privs not set", would also
 * mean filter mode exists; the child sets no_new_privs); EINVAL means no
 * CONFIG_SECCOMP_FILTER, and an outer seccomp policy that blocks prctl
 * gives its own error.
 */
int
plzig_seccomp_probe(void)
{
#ifdef PLZIG_HAVE_SECCOMP
	if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, NULL, 0, 0) == 0)
		return -EINVAL;			/* cannot happen */
	if (errno == EFAULT || errno == EACCES)
		return 0;
	return errno > 0 ? -errno : -EINVAL;
#else
	return -ENOSYS;
#endif
}

/*
 * Install the filter in the child.  Returns 1 if installed, 0 if not
 * attempted, -1 on failure (errbuf filled).  PR_SET_NO_NEW_PRIVS must
 * already be set.  The pid allowed for kill/tkill/tgkill is the caller's,
 * i.e. the process about to execve the compiler.
 */
int
plzig_seccomp_apply_in_child(const PlzigSandbox *sb, char *errbuf, size_t errlen)
{
#ifdef PLZIG_HAVE_SECCOMP
	struct sock_filter f[PLZIG_SC_MAX_INSNS];
	struct sock_fprog prog;
	uint32		self = (uint32) getpid();
	int			n = 0;
	int			i;

#define EMIT_STMT(code, k) \
	do { struct sock_filter _i = BPF_STMT((code), (k)); f[n++] = _i; } while (0)
#define EMIT_JUMP(code, k, jt, jf) \
	do { struct sock_filter _i = BPF_JUMP((code), (k), (jt), (jf)); f[n++] = _i; } while (0)

	if (sb->mode == PLZIG_SANDBOX_OFF || sb->seccomp != 0)
		return 0;

	StaticAssertStmt(lengthof(plzig_denied_syscalls) * 2 +
					 lengthof(plzig_self_only_syscalls) * 5 + 32 < PLZIG_SC_MAX_INSNS,
					 "seccomp program buffer too small");

	/* foreign architecture (e.g. int 0x80 on x86_64): deny everything */
	EMIT_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PLZIG_SECCOMP_ARCH, 1, 0);
	EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);

	EMIT_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
#if defined(__x86_64__)
	/* x32 system calls (bit 30) would bypass the numbers below */
	EMIT_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000U, 0, 1);
	EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);
#endif
	for (i = 0; i < (int) lengthof(plzig_denied_syscalls); i++)
	{
		EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (uint32) plzig_denied_syscalls[i], 0, 1);
		EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);
	}
	for (i = 0; i < (int) lengthof(plzig_self_only_syscalls); i++)
	{
		/* if nr matches: allow iff (pid_t) args[0] == self */
		EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (uint32) plzig_self_only_syscalls[i], 0, 4);
		EMIT_STMT(BPF_LD | BPF_W | BPF_ABS, PLZIG_SC_ARG_LO(0));
		EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, self, 0, 1);
		EMIT_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
		EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);
	}
	/* clone: threads and plain fork are fine, namespaces and CLONE_PARENT not */
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 4);
	EMIT_STMT(BPF_LD | BPF_W | BPF_ABS, PLZIG_SC_ARG_LO(0));
	EMIT_JUMP(BPF_JMP | BPF_JSET | BPF_K, PLZIG_CLONE_DENIED, 0, 1);
	EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);
	EMIT_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
#ifdef __NR_clone3
	/* flags are behind a pointer: make the caller fall back to clone() */
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1);
	EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_ENOSYS);
#endif
	/* fcntl: no F_SETOWN/F_SETOWN_EX/F_SETSIG (signals via SIGIO) */
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_fcntl, 0, 6);
	EMIT_STMT(BPF_LD | BPF_W | BPF_ABS, PLZIG_SC_ARG_LO(1));
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, F_SETOWN, 3, 0);
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, F_SETSIG, 2, 0);
	EMIT_JUMP(BPF_JMP | BPF_JEQ | BPF_K, F_SETOWN_EX, 1, 0);
	EMIT_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	EMIT_STMT(BPF_RET | BPF_K, PLZIG_SC_EPERM);

	EMIT_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

#undef EMIT_STMT
#undef EMIT_JUMP

	prog.len = (unsigned short) n;
	prog.filter = f;
	if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0) != 0)
	{
		child_strlcpy(errbuf, "seccomp: installing the filter failed", errlen);
		return -1;
	}
	return 1;
#else
	return 0;
#endif
}
