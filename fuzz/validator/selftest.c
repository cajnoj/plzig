/*
 * PLZIG_FUZZ_SELFTEST=1 makes the validator harness treat every input as
 * accepted, so that a denied construct must trip the differential checks:
 * fuzz/build.sh runs the target that way on known-bad inputs to prove that
 * the checks can fire at all.  Not instrumented.
 */
#include <stdlib.h>

int			plzig_fuzz_selftest = 0;

__attribute__((constructor))
static void
plzig_fuzz_selftest_init(void)
{
	const char *e = getenv("PLZIG_FUZZ_SELFTEST");

	plzig_fuzz_selftest = (e != NULL && e[0] == '1');
}
