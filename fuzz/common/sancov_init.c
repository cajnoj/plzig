/*
 * Register the SanitizerCoverage sections of Zig objects built with
 * `zig build-obj -ffuzz` with libFuzzer.
 *
 * Zig 0.17.1 emits the standard inline 8-bit counter and PC table sections
 * (__sancov_cntrs, __sancov_pcs1) but, unlike clang, no module constructor
 * that announces them: Zig's own fuzzer finds them through the linker's
 * __start_/__stop_ symbols (lib/fuzzer.zig).  This file does the same for
 * libFuzzer.  It must be compiled WITHOUT coverage instrumentation, and the
 * program must contain no other instrumented code (or the ranges would be
 * announced twice).
 *
 * Only the counters are registered: Zig's PC table has one word per counter
 * where libFuzzer expects (pc, flags) pairs, so libFuzzer would refuse it.
 * The counters are what drives libFuzzer's coverage feedback; without the
 * table only its PC-based reports (-print_pcs, -print_coverage) are missing.
 */
extern char __start___sancov_cntrs[] __attribute__((weak));
extern char __stop___sancov_cntrs[] __attribute__((weak));

void		__sanitizer_cov_8bit_counters_init(char *start, char *stop);

__attribute__((constructor))
static void
plzig_sancov_register(void)
{
	if (__start___sancov_cntrs && __stop___sancov_cntrs > __start___sancov_cntrs)
		__sanitizer_cov_8bit_counters_init(__start___sancov_cntrs, __stop___sancov_cntrs);
}
