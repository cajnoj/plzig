/*-------------------------------------------------------------------------
 *
 * plzig_sandbox.c
 *	  Landlock confinement for the compiler child process (Linux only).
 *
 * plzig_sandbox_apply_in_child() runs in the forked child between fork()
 * and execve(): it must not call any PostgreSQL function (no elog, no
 * palloc), only plain system calls.  The Landlock UAPI is declared locally
 * so the build does not depend on the kernel headers' Landlock version.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#ifdef __linux__
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

#define LL_NET_BIND_TCP		(1ULL << 0) /* ABI 4 */
#define LL_NET_CONNECT_TCP	(1ULL << 1) /* ABI 4 */

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

	/*
	 * Executables get a rule on the file itself (Landlock allows only file
	 * rights there): execve() needs EXECUTE and READ_FILE on the file, and
	 * nothing in the directory around it becomes readable or executable.
	 * A dynamically linked program would additionally need its loader and
	 * libraries; plzig_build.c refuses such a compiler up front.
	 */
	rx_file = LL_FS_EXECUTE | LL_FS_READ_FILE;
	ro = LL_FS_READ_FILE | LL_FS_READ_DIR;
	rw = (LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_READ_DIR |
		  LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE | LL_FS_MAKE_DIR |
		  LL_FS_MAKE_REG | LL_FS_MAKE_SYM | LL_FS_REFER | LL_FS_TRUNCATE) & fs_all;

	memset(&attr, 0, sizeof(attr));
	attr.handled_access_fs = fs_all;
	attr_size = sizeof(uint64);
	if (abi >= 4)
	{
		/* handle TCP bind/connect with no rules: all denied */
		attr.handled_access_net = LL_NET_BIND_TCP | LL_NET_CONNECT_TCP;
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
