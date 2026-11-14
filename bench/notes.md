## Read this first

* **One machine, one run per version.** A laptop-class CPU (hybrid
  performance/efficiency cores; the benchmark container was pinned to the
  six performance cores, 12 hardware threads) with frequency scaling left
  on. Ratios between languages are more meaningful than absolute times.
* **PL/Python (`plpython3u`) is untrusted and unsandboxed**: its functions
  run with the full rights of the server OS user. It is here as a speed
  reference, not as a like-for-like alternative to PL/Zig. **PL/Perl
  (`plperl`) is the trusted variant**, which runs code in `Safe`
  compartments (for example `pack`/`unpack` are not available, see task 5).
  PL/Zig is trusted and runs every function in a WebAssembly sandbox,
  executed by an **interpreter** (WAMR classic interpreter, no JIT or AOT,
  by design: PLAN.md D2).
* **Trigger and set-returning workloads are absent** because PL/Zig v1
  supports neither (README, *Not supported*).
* Every implementation is meant to be idiomatic for its language, with
  prepared plans where the language has them (PL/pgSQL caches plans by
  itself). Where the obvious code is a known trap, the trap was avoided and
  the file says so: PL/pgSQL string building appends to an array instead of
  `s := s || x` (quadratic), and task 5/10 values are passed as in-memory
  values (PL/pgSQL would re-read a TOASTed argument on every `get_byte()`).
  The SQL column is a reference: in task 6 it is C code from contrib, in
  tasks 7 and 9 a set-based statement.
* Before timing, a **correctness gate** compares every implementation's
  result with PL/pgSQL's; the run stops if any differs.

## What the numbers say

(The figures quoted in this section are those of the published run in
`doc/benchmarks.md`, PostgreSQL 18.7, JIT off.)

**Where PL/Zig wins: computation inside one call.** Integer loops (task 2
primes: 0.28× PL/pgSQL's time), floating point (Mandelbrot row: 0.20×), a
checksum loop over a 1 MB `bytea` (task 5: 0.23×) and edit distance against
10 000 rows fetched through a cursor (task 6: 0.56×). In all of these PL/Zig
is also faster than PL/Python and PL/Perl (1.7–4.3× on task 2, 6–8× on task 5). This is
the case the design predicts: compiled Zig is interpreted at roughly
10–15 ns per byte for a simple loop (task 5: 11 ms for 1 MB; one call), which
beats PL/pgSQL's per-statement expression evaluation, but is far from native
code: compiled C would be one to two orders of magnitude faster still.

**About even: per-call overhead and SPI-heavy loops with prepared
statements.** Task 1 (one million calls of a trivial function: 1.05×, about
0.24 µs per call against 0.23 µs), task 7 (100 000 lookups by key: 1.02×),
task 9 (20 000 inserts + 20 000 updates: 1.09×), and under concurrency
(pgbench: task 7 within 2 % of PL/pgSQL at 1–8 clients, task 1 within 5 %).
For SPI the time goes into the executor, which every language shares;
PL/Zig's boundary crossing (host import, typed parameter and row encoding)
costs about as much as PL/pgSQL's own statement overhead. A call now enters
the interpreter once and reuses its instance's memory contexts (see
*Per-call and per-row overhead before and after*: task 1 went from about 1.6× to
1.05×). Without a prepared statement (`spi.execute`: parse, plan, text
parameters, text result for every lookup) PL/Zig is 5.3× slower than with
one: prepare anything that runs in a loop.

**Where PL/Zig loses, and why (measured, see *Profiling*):**

* **Row-at-a-time cursor loops (task 8: 1.30×).** Every row crosses the
  boundary once (`spi_cursor_fetch` writes it into the cursor's guest
  buffer) and is encoded on the way (one `Value` per column); ~0.21 µs per
  row against ~0.17 µs for PL/pgSQL's `FOR r IN SELECT`. Before the
  per-row change it was two host calls and a per-row allocation (about 1.7×).
* **String building with `std.fmt` (task 3: 4.1×) and parsing (task 4:
  2.1×).** Here the competitors run their inner work in C: PL/pgSQL's
  `string_to_array`, `btrim`, `lower` and regular expressions, Perl's and
  Python's string primitives. PL/Zig runs it all as interpreted code: task 4
  makes about four passes over ~9 MB of input at ~13–23 ns per byte and pass
  (a loop that only counts commas already costs 13 ns per byte), and in
  `ReleaseSafe` every allocation is first filled with `0xAA` byte by byte
  (another ~8 ns per byte for the output buffer). Formatting an integer with
  `std.fmt` costs about 0.8 µs in the interpreter (task 3: 200 000 items,
  159 ms). PL/Python is 4× faster than PL/Zig on task 4 and 6× on task 3.
* **Large values (task 10): 1.12× for `bytea`, 1.32× for `text`.** One copy
  in, one copy out (plus the arena), and `text` results are validated
  (UTF-8, no NUL), which PL/pgSQL, returning its argument unchanged, does
  not need to do. Before this phase these were 20× and 8× (see *Task 10
  before and after*).
* **Start-up and compile (task 11).** The first call in a new session costs
  ~1.1 ms (WAMR initialisation, reading and validating the cached module,
  instantiation) against ~0.4 ms for PL/pgSQL, but less than the ~7–8 ms that
  PL/Python and PL/Perl need to start their interpreters. `CREATE FUNCTION`
  compiles: **~160 ms with a warm Zig cache, ~1.8 s with a cold one** (the
  first function of a new cluster, or after the Zig cache directory is
  removed), against well under a millisecond for PL/pgSQL. Compilations are
  serialised cluster-wide (PLAN.md D9), so a deployment that creates many
  PL/Zig functions at once waits for them one after the other.
* **Memory (task 12).** The peak increase per backend is small for every
  language in tasks 6 and 8 (≤ 3.1 MB). In task 3 PL/Zig's guest memory (the
  1.4 MB result built in the arena, then copied out) adds ~8 MB at peak, less
  than PL/pgSQL (~19 MB: array of 200 000 elements, then the joined string)
  and SQL (~20 MB). Guest linear memory never shrinks; an instance that grew
  beyond `plzig.instance_cache_max_memory` (4 MB) is destroyed after the call.

**JIT** makes no measurable difference to any language here: with the
default thresholds only the outer statement of task 1's PL variants is
compiled (its cost estimate counts 100 per function call), and the time is
in the function calls, which JIT does not touch. Forcing JIT for every
statement only adds compile time (task 8's SQL baseline: 1.5×).

**Concurrency (pgbench).** Every language scales similarly from 1 to 4
clients; at 8 clients the six physical cores (shared with the pgbench
threads) are saturated. PL/Zig's relative position matches the
single-session results.

## Profiling and what was changed

`bench/run.sh --profile` (perf, user-space cycles) on tasks 1, 8 and 10 at
the start of phase D:

1. **Fixed (guest SDK, no host or ABI change).** 97 % of an identity
   function on a 1 MB `bytea`, and 70 % of a trivial call, were spent in the
   interpreter. Cause: `plzig_alloc`, which the host calls to obtain the
   argument block of every call, used `Allocator.alignedAlloc`, which in
   `ReleaseSafe` fills the new block with `0xAA` — byte by byte in the
   interpreter, ~10 ns per byte — before the host overwrites it. It now uses
   the allocator's `rawAlloc`. Task 1 went from ~0.77 to ~0.37 µs per call (quick-mode runs);
   task 10 from 262/225 ms to 52/21 ms (text/bytea).
2. **PLAN.md §12 item 6 (host).** `text`/`bytea` results and SPI `text`
   parameters are copied once, straight into the final value, and
   validated there (rules unchanged). Task 10: text 52.0 → 44.2 ms, bytea
   21.1 → 12.2 ms.
3. **Per-call and per-row overhead (after phase D; ABI version 3).** The
   profile attributed ~35 % of a trivial call to entering the interpreter
   three times and ~15–20 % to creating and deleting two memory contexts,
   and the per-row cost of cursors to two host calls (with their
   native-call trampolines) and a per-row allocation. Changed one after the
   other, each measured (table *Per-call and per-row overhead before and
   after*):
   * one guest entry per call: the host writes the arguments into a buffer
     the guest reported once per instance (`plzig_init`), and `plzig_call`
     resets the arena itself; larger arguments take an extra allocating
     entry. Task 1: 384 → 256 ms.
   * one host call per cursor row: `spi_cursor_fetch` writes the row into
     the guest's buffer if it fits, otherwise reports the size and keeps
     the row for the next call; the per-row column arrays are allocated
     once per cursor. Task 8: 290 → 217 ms.
   * the two call contexts belong to the instance and are reset instead of
     created and deleted. Task 1: 253 → 234 ms; tasks 7 and 8 a few
     percent.
   Every guest address is still checked on every access, rows are still
   copied, and the stashed error of a failed call is kept in the caller's
   context (PLAN.md, *Deviations from plan*, 28).

## Recommendations (not done: they change the interpreter configuration)

* **Enable the bulk-memory proposal** (WAMR build and `-mcpu` for guests):
  `memory.copy`/`memory.fill` would turn every guest `memcpy`/`memset`
  (including `ReleaseSafe`'s `0xAA` fill of each allocation) into one native
  operation instead of an interpreted byte loop. Expected to help tasks 3
  and 4 most. It enlarges the interpreter surface a little; needs a security
  review.
* **WAMR fast interpreter or AOT** would change the compute picture by a
  large factor; D2 rejected both for code-size and attack-surface reasons
  (the fast interpreter had a heap-overflow CVE fixed in the release in
  use; AOT means native code generated from guest modules in the backend).
  Not planned; if ever reconsidered, these numbers are the baseline.
* **Skip the `ReleaseSafe` `0xAA` fill of guest allocations** (~8 ns per
  byte in the interpreter; would help tasks 3 and 4): harmless to the host,
  but a buggy function would then see leftovers of earlier calls instead of
  `0xAA` in uninitialised memory.
* These three are optional to-do items in PLAN.md §12 (9–11).
