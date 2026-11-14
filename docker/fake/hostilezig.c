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
	}
	argv[0] = (char *) REAL_ZIG;
	execv(REAL_ZIG, argv);
	fprintf(stderr, "hostilezig: execv %s: %s\n", REAL_ZIG, strerror(errno));
	return 1;
}
