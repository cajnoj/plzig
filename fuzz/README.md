# PL/Zig fuzz targets

Fuzzing of the parts of PL/Zig that take hostile input, as planned in
PLAN.md §13 C. Everything runs in Docker; one command runs any target for a
time budget and exits non-zero on a finding:

```sh
docker/run-fuzz.sh <target> <seconds>      # one target
docker/run-fuzz.sh smoke 60                # every target, 60 s each (run by docker/run-all.sh)
PLZIG_FUZZ_JOBS=8 docker/run-fuzz.sh loader 1800   # native targets in 8 parallel processes
```

It builds (or reuses) the images `plzig-test:<v>` → `plzig-hardened:<v>`
(PostgreSQL from the vendored source, assertions on) → `plzig-asan:<v>`
(PL/Zig and WAMR with ASan/UBSan) → `plzig-fuzz:<v>` (`docker/Dockerfile.fuzz`:
clang 19 with libFuzzer, the native targets prebuilt by `fuzz/build.sh`),
`<v>` = `PLZIG_FUZZ_VERSION`, default 18.7. Results go to
`build/fuzz/<target>/` (`fuzz.log`, the grown corpus, `artifacts/` with
crash/leak/timeout inputs, coverage); a corpus left there by an earlier run
seeds the next one. `PLZIG_FUZZ_NO_BUILD=1` skips the image builds.

| Target | Kind | What it feeds | Oracles |
|---|---|---|---|
| `validator` | libFuzzer, Zig (`-ffuzz`) | raw bytes, and the same bytes wrapped like a function body, into `plzig-validate`'s `validate()` (`zig/validate/main.zig`, linked unchanged); Zig-token dictionary | no crash (ReleaseSafe: every safety check aborts); **differential**: whatever the validator accepts must contain, according to an independent hand-written lexer, no denied builtin, no denied keyword and no `@import` other than `@import("plzig")`; and if the real parser (`std.zig.Ast`) accepts it, no `builtin_call` node names a denied builtin, every `@import` argument is the literal `"plzig"`, and the parser's tokens contain no denied keyword |
| `loader` | libFuzzer, C, ASan + UBSan | WebAssembly module files, as a poisoned cache entry would deliver them, through the production `src/plzig_runtime.c` (load, import allowlist, trial instantiation (including `plzig_init` and its argument-buffer check), instantiate, `plzig_call` twice with the arguments in the argument buffer and once through `plzig_alloc_args` with a 5000-byte text argument, result decoding as int/text/bytea/void) on WAMR built with the production configuration and the interrupt patch; seeded with real modules; a structure-aware mutator keeps the section framing intact most of the time | no crash or sanitizer report; no abort (an `ERROR` outside a handler, a failed assertion, `pfree` of a foreign pointer); no hang (a CPU-time timer raises `QueryCancelPending`, so endless guest loops must end through the interrupt patch); no growth of the long-lived "PL/Zig runtime" memory context across inputs (a leaked module or instance) |
| `hostabi` | SQL-driven, live ASan server | random byte "scripts" to `fuzz/hostabi/driver.zig`, a PL/Zig function compiled through `docker/fake/hostilezig.c` that calls the 21 host imports directly (including `numeric_op` with valid and malformed wire-format operands and `tz_convert` with forged zones and out-of-range values): forged pointers/lengths (inside, at the edge of and beyond linear memory, `0xffffffff`), row/column numbers, plan and cursor handles (valid, stale from earlier calls, bit-flipped, forged), kinds (every parameter kind, fixed-width, numeric and jsonb included) and values, memory growth between calls, nested calls through SQL; batches of 300 scripts as an unprivileged role, one subtransaction per call | no backend crash, no sanitizer report, no internal error (`XX000`), no prepared statement outliving its instance, bounded PL/Zig memory, plus the checks below |
| `marshal` | SQL-driven, live ASan server | random values of 32 types (all scalar edge values, text with random code points up to U+10FFFF, bytea with NUL bytes, numeric/float specials, dates/times/timestamps at and near PostgreSQL's range limits including leap-second input, timetz at the zone limits, interval extremes, oid, arrays, ranges, enums, domains, composites, json, random nested jsonb documents with numbers of every on-disk form, escapes, long and same-length keys and more than 32 children, ...) through non-strict identity functions (a jsonb identity is the guest's own serialisation, `plzig.Jsonb.toJsonText`), directly and from a table where they are stored compressed and out of line; all 256 NULL patterns of an 8-argument function; random signatures (hostile parameter names, unnamed parameters, 63-byte names, reserved names, pseudo types, `OUT`/`INOUT`/`VARIADIC`, `SETOF`, up to 100 parameters) created with `check_function_bodies = off`, a sample then compiled and called | identity holds (text form); **differential**: the guest's jsonb serialisation equals `jsonb_out`'s text character for character; the guest sees exactly the NULL pattern; the validator accepts exactly the signatures the rules allow (`doc/abi.md`); every accepted signature compiles and runs |
| `jsonb` | libFuzzer, Zig (`-ffuzz`) | the guest SDK's jsonb reader and numeric decoders (`zig/sdk/plzig.zig`, compiled natively and unchanged; only the functions that take an explicit allocator), on mutated bytes that PostgreSQL produced (`fuzz/jsonb/corpus`: jsonb on-disk layouts, numerics in the wire format and in the on-disk format); dictionary of layout tokens | no panic (ReleaseSafe: every out-of-bounds read or overflow aborts) whatever the bytes; serialisations that succeed are valid JSON (std.json) unless the value holds NaN/∞/unnormalised numerics or non-UTF-8 strings; decoded numbers are valid wire format; in key-sorted objects the binary search finds every key at its position; for wire numerics `parse(toText(x))` gives the same text and value (for normalised values without digits beyond the scale, the only ones PostgreSQL has) |
| `pipeline` | SQL-driven, live ASan server | bodies from `fuzz/pipeline/gen.pl`: token-level mutations of the regression suite's bodies, and generated stress fragments (comptime loops and exponential types, huge constant data, `@compileLog`/`@compileError` floods, deep nesting, endless loops and recursion, memory growth, top-level declarations, reflection on the SDK and `std`, denied constructs, odd bytes), through `CREATE FUNCTION` (and `DO`) as an unprivileged role with the default sandbox, then a call | only expected SQLSTATEs (policy, compile error, limits, timeout; compiler crashes are counted, not failed: they are contained Zig bugs); after every statement: backend alive, no crash in the server log, no sanitizer report, no build directory, temp file, zombie or compiler process left; the module cache within its limit |

The SQL-driven targets run inside `docker/test-in-container.sh` (layer
`fuzz`), so the server runs exactly as in the `asan` variant of
`docker/run-all.sh`, and a sanitizer report anywhere also fails the
container's `sanitizers` layer. Each prints its random seed; batches are
reproducible with `PLZIG_FUZZ_SEED=<seed>`.

## Files

```
fuzz/build.sh                 builds the native targets (in the fuzz image)
fuzz/run-native.sh            runs validator/loader for a budget, coverage report
fuzz/common/sancov_init.c     registers Zig's -ffuzz counters with libFuzzer
fuzz/common/sql-lib.sh        shared checks of the SQL-driven targets
fuzz/validator/harness.zig    validator target (+ selftest.c: PLZIG_FUZZ_SELFTEST=1)
fuzz/validator/zig.dict       dictionary (builtins, keywords, punctuation)
fuzz/validator/corpus/        seeds: every body of the regression suite + lexical corner cases
fuzz/loader/harness.c         loader target and its structure-aware mutator
fuzz/loader/pgshim.c, .h      the PostgreSQL services plzig_runtime.c uses, for a standalone process
fuzz/loader/hoststubs.c       host-import stand-ins (names/signatures checked against src/plzig_host.c)
fuzz/loader/corpus/           seed modules, made by make-seeds.sh from seeds-src/
fuzz/loader/findings/         reproducers of WAMR reports (doc/security.md §8)
fuzz/loader/ubsan.supp        the known WAMR report the loader runs suppress, with reasons
fuzz/jsonb/harness.zig        jsonb reader / numeric decoder target (+ corpus/, jsonb.dict)
fuzz/hostabi/driver.zig, run.sh
fuzz/marshal/setup.sql, run.sh
fuzz/pipeline/gen.pl, run.sh
```

Nothing here is part of a PL/Zig build or installation; `plzig.so` contains
no fuzzing hook. The loader target links `src/plzig_runtime.c` as it is and
replaces only what it calls in the rest of the server (`pgshim.c`,
`hoststubs.c`).

## Notes on the method

* **Zig coverage for libFuzzer.** `zig build-obj -ffuzz` emits SanitizerCoverage
  inline 8-bit counters but no constructor announcing them;
  `fuzz/common/sancov_init.c` registers them (`__start___sancov_cntrs`).
  Zig's PC table has a layout libFuzzer does not accept, so it is not
  registered: libFuzzer's feedback works, its PC-level reports
  (`-print_coverage`) do not, and the validator's coverage is reported as
  counters/features, not source lines. Zig's own fuzzer (`zig build --fuzz`)
  was not used: it needs the build system and has no time budget or exit
  status suitable for CI.
* **Validator self-test.** `fuzz/build.sh` runs the target with
  `PLZIG_FUZZ_SELFTEST=1` (the validator's verdict ignored) on denied inputs
  and requires the differential checks to fire, so a broken oracle cannot
  pass silently.
* **Loader stand-ins.** `pgshim.c` implements memory contexts as one
  `malloc` per chunk (so ASan sees every overflow), `ereport(ERROR)` as
  `siglongjmp` to `PG_exception_stack`, and `ProcessInterrupts()`. The host
  imports need a server; their stand-ins check pointer ranges with the
  production helper and trap like a failing import. The real host imports
  are the `hostabi` target's job.
* **UBSan alignment checks are off for WAMR** in the loader target, as in
  the `asan` variant, because of the known misaligned access in
  `tables_instantiate` (doc/security.md §8). One other
  known WAMR report is suppressed by name (`fuzz/loader/ubsan.supp`).
* **What is not fuzzed**: the interpreter with `wasm-smith`-generated valid
  modules (no Rust toolchain in the images; the loader target executes the
  code of every module that validates, but its inputs are mostly invalid),
  SQLsmith-style random SQL, the TAP-level fault injection (covered
  deterministically by `test/tap`).

## Long runs (pre-release)

PLAN.md §13 C asks for at least 24 hours per target before a release:

```sh
PLZIG_FUZZ_JOBS=8 docker/run-fuzz.sh validator 86400
PLZIG_FUZZ_JOBS=8 docker/run-fuzz.sh loader 86400
docker/run-fuzz.sh hostabi 86400
docker/run-fuzz.sh marshal 86400
docker/run-fuzz.sh pipeline 86400
PLZIG_FUZZ_JOBS=8 docker/run-fuzz.sh jsonb 86400
```

Run them on a machine with Landlock ABI ≥ 6 and seccomp available to
containers (the SQL targets need the default `require` sandbox), keep
`build/fuzz/` between runs (the corpora accumulate), and treat any
artifact or `FINDING` line as a release blocker until triaged. A finding's
input is in `build/fuzz/<target>/artifacts/` (native targets; replay with
`/opt/plzig-fuzz/fuzz_<target> <file>` in the fuzz image) or described in
`build/fuzz/<target>/finding-*.txt` with the seed to replay (SQL targets).
