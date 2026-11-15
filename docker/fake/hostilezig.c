/*
 * Test helper for docker/security-checks.sh: a "zig" that lets user code
 * call the host imports directly, to attack them with forged pointers,
 * lengths, handles and values (the real SDK never passes such values, and
 * user code cannot declare imports itself).
 *
 * "zig version" and "zig build-exe ..." are passed on to the real compiler
 * (REAL_ZIG, so this only works with plzig.compiler_sandbox = off); before
 * building, the SDK copy in the build directory (sdk/plzig.zig) is patched:
 * the host import table becomes public (plzig.host, which is the import
 * struct inside wasm_env) and helpers
 * plzig.rawPtr(T, address), plzig.addrOf(pointer) and plzig.memSize() are
 * added (user code may not use @ptrFromInt/@intFromPtr/@wasmMemorySize).
 * The SDK root (sdk/root.zig) is patched too: if the user module declares
 * `pub fn hostileInit() u64` or `pub fn hostileAllocArgs(len: u32) u32`,
 * plzig_init / plzig_alloc_args return what those return, so that a test
 * can hand the host forged argument-buffer addresses and capacities, and
 * if it declares `pub fn hostileCall(args, nargs, result, begin) u32`,
 * plzig_call is replaced by it: the test writes the result slot (and the
 * rows and trigger results it points to) itself.
 * The module is then compiled as usual and must still pass the loader's
 * import allowlist.  Also used by the host-ABI fuzz target (fuzz/hostabi).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef REAL_ZIG
#error "REAL_ZIG must be defined"
#endif

static const char needle[] = "\nconst host = env.host;";
static const char repl[] = "\npub const host = env.host;";
static const char ext_needle[] = "\n        extern \"plzig\" fn ";
static const char ext_repl[] = "\n        pub extern \"plzig\" fn ";
static const char helper[] =
	"\npub fn rawPtr(comptime T: type, addr: usize) T {\n"
	"    return @ptrFromInt(addr);\n"
	"}\n"
	"pub fn addrOf(p: anytype) usize {\n"
	"    return @intFromPtr(p);\n"
	"}\n"
	"pub fn memSize() usize {\n"
	"    return @wasmMemorySize(0) * 65536;\n"
	"}\n";

/* entry points of sdk/root.zig and what is inserted at their start */
static const char *const root_patch[][2] = {
	{"export fn plzig_init() u64 {\n",
	"    if (@hasDecl(user, \"hostileInit\")) return user.hostileInit();\n"},
	{"export fn plzig_alloc_args(len: u32) u32 {\n",
	"    if (@hasDecl(user, \"hostileAllocArgs\")) return user.hostileAllocArgs(len);\n"},
	{"export fn plzig_call(args: [*]const Slot, nargs: u32, result: *Slot, begin: u32) u32 {\n",
	"    if (@hasDecl(user, \"hostileCall\")) return user.hostileCall(args, nargs, result, begin);\n"},
};

static char *
read_all(const char *path)
{
	FILE	   *f = fopen(path, "rb");
	char	   *buf;
	long		n;

	if (f == NULL || fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0)
	{
		perror(path);
		exit(1);
	}
	rewind(f);
	buf = calloc(1, (size_t) n + 1);
	if (buf == NULL || fread(buf, 1, (size_t) n, f) != (size_t) n)
	{
		perror(path);
		exit(1);
	}
	fclose(f);
	return buf;
}

static void
patch_root(void)
{
	char	   *buf = read_all("sdk/root.zig");
	FILE	   *f;
	const char *p = buf;
	size_t		i;

	if (unlink("sdk/root.zig") != 0 || (f = fopen("sdk/root.zig", "wb")) == NULL)
	{
		perror("hostilezig: rewrite sdk/root.zig");
		exit(1);
	}
	for (i = 0; i < sizeof(root_patch) / sizeof(root_patch[0]); i++)
	{
		const char *q = strstr(p, root_patch[i][0]);

		if (q == NULL)
		{
			fprintf(stderr, "hostilezig: entry point not found in the SDK root: %s", root_patch[i][0]);
			exit(1);
		}
		q += strlen(root_patch[i][0]);
		fwrite(p, 1, (size_t) (q - p), f);
		fputs(root_patch[i][1], f);
		p = q;
	}
	fputs(p, f);
	fclose(f);
	free(buf);
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "build-exe") == 0)
	{
		FILE	   *f = fopen("sdk/plzig.zig", "rb");
		char	   *buf;
		char	   *p;
		long		n;

		if (f == NULL || fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0)
		{
			perror("hostilezig: sdk/plzig.zig");
			return 1;
		}
		rewind(f);
		buf = calloc(1, (size_t) n + 1);
		if (buf == NULL || fread(buf, 1, (size_t) n, f) != (size_t) n)
		{
			perror("hostilezig: read");
			return 1;
		}
		fclose(f);
		p = strstr(buf, needle);
		if (p == NULL)
		{
			fprintf(stderr, "hostilezig: host table not found in the SDK\n");
			return 1;
		}
		if (unlink("sdk/plzig.zig") != 0 || (f = fopen("sdk/plzig.zig", "wb")) == NULL)
		{
			perror("hostilezig: rewrite");
			return 1;
		}
		fwrite(buf, 1, (size_t) (p - buf), f);
		fputs(repl, f);
		/* every import declaration becomes public, too */
		for (p += strlen(needle);;)
		{
			char	   *q = strstr(p, ext_needle);

			if (q == NULL)
				break;
			fwrite(p, 1, (size_t) (q - p), f);
			fputs(ext_repl, f);
			p = q + strlen(ext_needle);
		}
		fputs(p, f);
		fputs(helper, f);
		fclose(f);
		patch_root();
	}
	argv[0] = (char *) REAL_ZIG;
	execv(REAL_ZIG, argv);
	fprintf(stderr, "hostilezig: execv %s: %s\n", REAL_ZIG, strerror(errno));
	return 1;
}
