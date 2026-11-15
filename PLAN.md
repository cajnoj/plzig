# PL/Zig (`plzig`) — design and implementation plan

Status: plan v1, 2026-11-14. Guiding rule from the project owner: **security > functionality**.
Where the two conflict, the feature is cut or restricted and the cut is recorded here.

## 1. Goal and scope

A PostgreSQL procedural-language extension that lets users write functions and
procedures in Zig **0.17.1** ("Zig 17.1"):

```sql
CREATE FUNCTION add(a int, b int) RETURNS int LANGUAGE plzig AS $$
    return a + b;
$$;
```

Supported servers (latest minors at time of writing, all verified to exist as
git tags and as official Docker images):

| Major | Version tested | Tag          |
|-------|----------------|--------------|
| 14    | 14.25          | `REL_14_25`  |
| 15    | 15.20          | `REL_15_20`  |
| 16    | 16.16          | `REL_16_16`  |
| 17    | 17.12          | `REL_17_12`  |
| 18    | 18.7           | `REL_18_7`   |
| 19    | 19 RC 2        | `REL_19_RC2` |

Local reference material (git-ignored, no network needed afterwards):

- `vendor/postgres` (18.7) and `vendor/pg-REL_*` worktrees — source **and** SGML docs (`doc/src/sgml`, esp. `plhandler.sgml`, `xfunc.sgml`, `spi.sgml`, `extend.sgml`).
- `vendor/zig/zig-x86_64-linux-0.17.1/` — compiler, `lib/std` source, `doc/langref.html`. Zig 0.17 is newer than most written material; **the vendored source is the authority**, not memory.
- `vendor/wamr` — WebAssembly Micro Runtime, tag `WAMR-2.4.5`, commit `25bd7eb63e828e4bd242cc9b38d260b4b31c6605`.

## 2. Architecture in one paragraph

User Zig source is stored in `pg_proc.prosrc`. On `CREATE`/`ALTER`/first call
the backend writes a private build directory (fixed `build.zig` template + the
wrapped user source), runs a source validator, then runs `zig build` in a
resource-limited, filesystem-confined child process. The output is **not native
code**: it is a `wasm32-freestanding` module. The module is cached on disk by
content hash and executed inside the backend by an embedded, interpreter-only
WebAssembly runtime (WAMR). The only things guest code can reach are the host
functions `plzig` exports to it: logging, raising errors, and SPI (which runs
under ordinary PostgreSQL permission checks).

```
CREATE FUNCTION ──► plzig_validator ──► generate user.zig ──► plzig-validate (token allowlist)
                                             │                        │
                                             ▼                        ▼
                        $PGDATA/plzig/pgsql_tmp.build.<pid>.<n>/   zig build  (child: rlimits, Landlock,
                                                                              clean env, timeout, cancelable)
                                             │
                                             ▼
                        $PGDATA/plzig/cache/<sha256>.wasm   (content-addressed)
                                             │
SELECT f(..) ──► plzig_call_handler ──► WAMR instance (memory in a PG MemoryContext)
                                             │  imports: plzig.log / raise / panic / spi_*
                                             ▼
                                   SPI, elog — normal PG permission checks
```

## 3. Dilemmas and how they were resolved

### D1. Native shared object vs. WebAssembly sandbox — **chose WebAssembly**

The obvious design (and the one the brief hints at) compiles each function to a
native `.so` and `dlopen`s it. I rejected it:

- Zig is not memory-safe. Even with every dangerous builtin banned and
  `ReleaseSafe` on, safe-looking code can return a pointer to a dead stack
  frame, use `undefined`, or overflow the native stack. In a backend that means
  corrupting shared buffers or crashing the whole cluster into recovery.
- "Disable dangerous std imports" cannot be enforced soundly for native code:
  `extern fn system(...)`, inline `asm` syscalls, or `@ptrFromInt` reach the OS
  without `std`. A source filter would be the *only* line of defence and one
  miss is game over.
- Consequently a native PL/Zig could only honestly be an *untrusted* language
  (superuser-only, like C). That fails "should not bypass regular pg
  permissions" for anybody but superusers, who can already do anything.

With wasm the boundary is structural, not lexical: guest code has its own linear
memory, cannot issue syscalls, and can call only the imports we link. A guest
bug becomes a trap, which becomes a normal `ERROR`. Cost: interpreter speed
(roughly 10–50x slower than native for compute-heavy code) and a vendored
runtime. Security > functionality, so this is accepted.

### D2. Which wasm runtime — **WAMR, classic interpreter only**

- wasmtime: best-in-class but Rust, ~20 MB, JIT (W+X pages) and by default
  signal-handler based traps that would fight the backend's signal handling.
- wasm3: tiny but effectively unmaintained, weak module validation.
- Own interpreter: no.
- **WAMR** (Bytecode Alliance, C, actively maintained, Apache-2.0 WITH
  LLVM-exception): builds as a static lib, has a full validator, a pure
  interpreter, pluggable allocator, per-instance memory cap.

Build config: classic interpreter only; **no** AOT, JIT, WASI, builtin libc,
threads, shared memory, multi-module, GC, memory64, SIMD, debug-interp; software
bounds checks (`WAMR_DISABLE_HW_BOUND_CHECK=1`) so the runtime installs no
signal handlers and creates no threads. Linked statically into `plzig.so` with
hidden visibility.

### D3. Interrupting runaway guest code — **3-line patch to the vendored runtime**

A guest `while (true) {}` makes no host calls, so `CHECK_FOR_INTERRUPTS()` never
runs. Options considered:

1. WAMR instruction metering: a hard instruction budget, not resumable, and
   cancel/`statement_timeout` would still be ignored until the budget runs out.
2. WAMR thread manager + `wasm_runtime_terminate` from a timer signal handler:
   pulls in pthread machinery and mutexes inside signal handlers.
3. **Chosen:** a tiny patch (`third_party/wamr-interrupt.patch`, applied with
   `--fuzz=0` to the pinned commit) defining the interpreter's
   `CHECK_SUSPEND_FLAGS()` (already evaluated at every loop back-edge, branch
   and call) to read host-provided `volatile sig_atomic_t *` flags. The host
   points them at PostgreSQL's `QueryCancelPending` and `ProcDiePending`. When
   set, the guest traps; the handler then runs `CHECK_FOR_INTERRUPTS()` and, if
   that does not throw, raises `ERRCODE_QUERY_CANCELED` itself (the instance is
   dead either way).

So query cancel, `pg_terminate_backend` and `statement_timeout` all work on
guest code using the standard PostgreSQL mechanisms, with no new threads or
signal handlers. Patching a vendored dependency is a maintenance cost; it is
small, pinned and fails loudly if upstream moves.

### D4. Trusted or untrusted language — **TRUSTED, but USAGE revoked from PUBLIC**

The sandbox makes execution safe enough for `TRUSTED`. But anyone with `USAGE`
can make the server run the Zig compiler on their input (CPU, and the compiler
itself is attack surface). So the install script does
`REVOKE USAGE ON LANGUAGE plzig FROM PUBLIC`; a DBA grants it deliberately. The
extension itself is `superuser = true`, `trusted = false`.

### D5. How the Zig compiler gets onto the server — **at `make install`, never from a backend**

"The extension will install the Zig compiler" is implemented in the build:
`make` fetches the pinned 0.17.1 tarball (sha256 pinned per architecture,
`ZIG_TARBALL=` override for air-gapped builds) and `make install` puts it in
`$(pkglibdir)/plzig/zig-0.17.1/`. Rejected: downloading at `CREATE EXTENSION`
time. A database backend making outbound HTTP requests and unpacking
executables as the `postgres` OS user is exactly the kind of behaviour a
security-first extension must not have, and most production servers have no
egress anyway.

### D6. Restricting the standard library — **yes, twice**

1. Structural: target is `wasm32-freestanding`. `std.fs`, `std.net`,
   `std.process`, `std.posix`, threads etc. have no OS to talk to; anything
   that would need one fails to compile or produces an import the loader
   refuses (the loader rejects every import outside the `plzig` namespace).
2. Lexical (defence in depth): `plzig-validate`, written in Zig on top of the
   compiler's own `std.zig.Tokenizer` (so it can never disagree with the
   compiler about what a token is), enforces on the user's source:
   - `@import` only as `@import("plzig")`. Direct `@import("std")` is denied;
     a curated subset is re-exported as `plzig.std` (mem, fmt, math, ascii,
     unicode, sort, hash, ArrayList/hash maps and similar pure-computation
     pieces). `plzig` and `std` (= `plzig.std`) are pre-declared in every body.
   - builtins by **allowlist**; notably denied: `@cImport`, `@cInclude`,
     `@embedFile` (compile-time file read), `@extern`, `@export`,
     `@ptrFromInt`, `@fieldParentPtr`, `@setEvalBranchQuota`,
     `@wasmMemoryGrow/Size`, `@setRuntimeSafety`, atomics.
   - keywords denied: `extern`, `export`, `asm`, `linksection`, `callconv`,
     `threadlocal`, `addrspace`, `usingnamespace` (if still a token).
   Zig has no macros, so a builtin or keyword cannot be produced without its
   literal token; token-level filtering is complete for these.

   Honest caveat: the curated `plzig.std` is a convenience policy, not the
   security boundary — clever comptime reflection might reach more of `std`
   than intended. That is fine *because* of (1).

### D7. Memory allocation — **one allocator, PG memory contexts on both sides**

- Host side: WAMR is initialised with `Alloc_With_Allocator`; its
  malloc/realloc/free are implemented on a dedicated `MemoryContext`
  ("PL/Zig runtime", child of `TopMemoryContext`) using
  `MCXT_ALLOC_NO_OOM` so allocation failure returns NULL to the runtime rather
  than `longjmp`ing through interpreter frames. Everything shows up in
  `pg_backend_memory_contexts`. No raw `malloc` in the extension.
- Guest side: user code gets exactly one allocator, `plzig.allocator`, an arena
  over the guest linear memory with PL/pgSQL-like semantics: allocations live
  until the function call returns, then everything is released (like a
  per-call memory context; `free` is optional). Direct use of `std.heap` is not
  exposed.
- Cap: linear memory growth is limited per instance by `plzig.max_memory`
  (default 64 MB); exceeding it yields `error.OutOfMemory` in the guest, never
  a backend OOM. Guest stack is fixed and small (256 KB); overflow traps.

A literal `palloc` allocator is impossible across the sandbox boundary (guest
pointers are offsets into linear memory), so the *behaviour* of a memory
context is reproduced instead.

### D8. Where compiled code lives — **content-addressed files, not a catalog table**

`$PGDATA/plzig/cache/<sha256>.wasm`, key = sha256(generated source ‖ SDK ABI
version ‖ Zig version ‖ build options). Rejected: a `bytea` cache table —
writing it would have to bypass table ACLs on behalf of unprivileged users, and
it must be kept transactionally in sync with `pg_proc`. A content-addressed
file cache has no invalidation problem (rollback, `pg_upgrade`, OID reuse,
restore from `pg_dump` with `check_function_bodies = off`, hot standby): a miss
just recompiles, lazily, at first call. The source of truth stays in the
catalog and is WAL-logged/replicated as usual. Directory is fixed inside
`$PGDATA` (0700, owner-checked) rather than configurable: fewer ways to point
it somewhere unsafe.

### D9. Spawning the compiler from a backend

A background worker "compile service" would be the purest design but adds
shared memory, IPC and a `shared_preload_libraries` requirement. Chosen:
`fork`+`execve` directly from the backend, done carefully (section 6), the same
basic mechanism PostgreSQL itself uses for `COPY ... PROGRAM` and
`archive_command`. A cluster-wide `flock` serialises compiles, bounding CPU use
to one compiler at a time without shared memory.

### D10. Features deliberately cut from v1

| Cut | Why |
|-----|-----|
| Transaction control (`COMMIT`/`ROLLBACK`) inside procedures | Non-atomic SPI plus live guest state across transaction boundaries is a classic source of resource/snapshot bugs. |
| Triggers, event triggers, set-returning functions, `OUT`/`INOUT` params, polymorphic/pseudo types | Each widens the marshalling surface; rejected at `CREATE` time with `feature_not_supported`. |
| Clock, randomness, env, files, network for guest code | No host import exists. Use SQL via SPI (`SELECT now()`), which is permission-checked. |
| Catching SPI errors in guest code (subtransactions) | An error always aborts the call. |
| Configurable cache dir / compiler flags / user-supplied `build.zig` | The build script is a fixed template; user text never enters it. |

Cold-cache note: the first compile on a fresh cluster takes about a minute
(Zig builds its build runner and `compiler_rt`); later compiles take ~1 s.
Measured locally: 69 s cold, 0.6–1.6 s warm. Default compile timeout is
therefore 300 s.

## 4. Repository layout

```
plzig.control            Makefile (PGXS)          PLAN.md   README.md
sql/plzig--1.0.sql
src/plzig.c              _PG_init, GUCs, call/inline/validator handlers, function cache
src/plzig_source.c       pg_proc -> signature -> generated user.zig; cache key
src/plzig_build.c        build dir, cache dir, compile lock, driving validator + zig build
src/plzig_spawn.c        fork/exec, pipes, timeout, cancel, reaping
src/plzig_sandbox.c      rlimits, no_new_privs, Landlock (Linux; no-op elsewhere)
src/plzig_runtime.c      WAMR init/allocator/load/instantiate/call, import checks
src/plzig_host.c         host imports: log, raise, panic, spi_*
src/plzig_types.c        Datum <-> guest value marshalling
src/plzig.h
zig/sdk/plzig.zig        guest SDK module (allocator, log, spi, curated std)
zig/sdk/root.zig         root module: exports, panic handler, comptime arg decoding
zig/template/build.zig   the fixed build script copied into each build dir
zig/validate/main.zig    plzig-validate (native tool, built with the bundled zig)
third_party/             fetch script, pinned checksums, wamr-interrupt.patch, wamr cmake config
test/sql, test/expected  pg_regress suite
docker/Dockerfile, docker/run-tests.sh
doc/plzig.md, doc/abi.md
```

## 5. SQL surface

- `plzig.control`: `default_version='1.0'`, `relocatable=false`, `schema=pg_catalog`, `superuser=true`, `trusted=false`.
- Script: `plzig_call_handler()`, `plzig_inline_handler(internal)`, `plzig_validator(oid)`;
  `CREATE TRUSTED LANGUAGE plzig HANDLER ... INLINE ... VALIDATOR ...;`
  `REVOKE USAGE ON LANGUAGE plzig FROM PUBLIC;` plus `COMMENT`s.
- `DO $$ ... $$ LANGUAGE plzig` supported (no args, returns void).

### Function body convention

The body is the body of a Zig function. Generated `user.zig` (user text is
appended verbatim to a file of its own, never interpolated into `build.zig` or
a shell command):

```zig
const plzig = @import("plzig"); const std = plzig.std; pub fn call(a: i32, b: i32) anyerror!?i32 {
<body>
}
```

- Header is on one line so compiler line numbers map 1:1 onto body lines
  (adjust by the fixed offset when reporting).
- `STRICT` functions get non-optional parameter types; otherwise `?T`.
- Return type is `anyerror!?T` (`return null;` = SQL NULL), `anyerror!void` for void/procedures.
- A returned Zig error becomes `ERROR: plzig function failed: <error name>`.
- Argument names must match `[A-Za-z_][A-Za-z0-9_]*` (else rejected) and are
  emitted as `@"name"`; unnamed arguments are `arg1..argN`.

### Type mapping

| SQL | Zig |
|-----|-----|
| `boolean` | `bool` |
| `smallint` / `integer` / `bigint` | `i16` / `i32` / `i64` |
| `real` / `double precision` | `f32` / `f64` |
| `text`, `varchar`, `bpchar` | `[]const u8` (database encoding, detoasted copy) |
| `bytea` | `[]const u8` |
| any other base, enum, domain, array, range, composite type | `[]const u8` holding the type's **text I/O representation** (output function in, input function out — so domain constraints and typmods are enforced by PostgreSQL itself) |
| `void` | `void` |

Rejected: pseudo-types other than `void` return, polymorphic types, `SETOF`,
`OUT`/`INOUT`/`TABLE`, trigger/event trigger, window/aggregate support use.

## 6. Compile pipeline (file operations and OS resources)

All paths below are under `$PGDATA/plzig/` (created 0700 on demand; before every
use `lstat` it and refuse to proceed unless it is a real directory owned by the
server's euid with no group/other permission bits).

1. **Generate** source in memory; reject if longer than `plzig.max_source_size`.
   Compute the cache key. If `cache/<key>.wasm` exists → done.
2. **Lock**: `flock` (non-blocking, retried with `CHECK_FOR_INTERRUPTS()` and a
   latch wait) on `compile.lock`; re-check the cache after acquiring.
3. **Build dir** `pgsql_tmp.build.<pid>.<counter>/` (the `pgsql_tmp` prefix makes
   base backups skip it), `mkdir` 0700, must not pre-exist. Contents: `build.zig`
   (copied from the installed template), `src/user.zig`. The SDK is referenced
   read-only from `$(sharedir)/plzig/sdk`. Removed in `PG_FINALLY` and again by
   a `before_shmem_exit`/abort path; stale dirs whose pid is dead are swept on a
   backend's first compile.
4. **Validate**: run `plzig-validate src/user.zig`. Non-zero → `ERROR` with its message.
5. **Build**: `zig build --release=safe` (exact flags per 0.17.1) with
   `ZIG_GLOBAL_CACHE_DIR=$PGDATA/plzig/zig-cache`, local cache inside the build
   dir. Target `wasm32-freestanding`, CPU `mvp` (+ only features WAMR is built
   with), `ReleaseSafe`, stripped, no entry, fixed 256 KB stack, exports limited
   to the SDK's entry points.
6. **Install**: check output size ≤ 16 MB, load-validate it with WAMR, write to
   `cache/<key>.wasm.tmp.<pid>` (`O_CREAT|O_EXCL`, 0600), fsync, `durable_rename`.

File-handling rules for the C code:

- Use PostgreSQL's wrappers only: `OpenTransientFile`/`CloseTransientFile`,
  `AllocateDir`/`ReadDir`/`FreeDir`, `MakePGDirectory`, `durable_rename`,
  `pg_fsync`. They are resource-owner tracked, so an `ERROR` cannot leak a
  descriptor.
- No path component ever comes from user input: names are pids, counters and
  hex digests. Opens use `O_NOFOLLOW`; recursive delete uses `lstat` and never
  follows symlinks.
- Never `system()`/`popen()`/shell. `execve` with an argv array.

Child process rules (`plzig_spawn.c`, `plzig_sandbox.c`):

- `fork()`; in the child, before `execve`: `setsid()`, reset signal handlers and
  mask, stdin ← `/dev/null`, stdout/stderr → pipe, close every other descriptor
  (`close_range` or `/proc/self/fd` walk), `chdir` to the build dir, `umask 077`.
- Environment is built from scratch: `PATH=/usr/bin:/bin`, `HOME=<build dir>`,
  `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`, `LC_ALL=C`, `NO_COLOR=1`. No `PG*`.
- `prctl(PR_SET_NO_NEW_PRIVS)`, `RLIMIT_CORE=0`, `RLIMIT_CPU`, `RLIMIT_FSIZE`,
  `RLIMIT_AS` (if the compiler tolerates it — test; otherwise document and rely on timeout).
- **Landlock** (Linux ≥ 5.13, via raw syscalls, best effort): read+execute on the
  Zig install dir, read on the SDK/template dir, read-write on the build dir and
  the Zig global cache, nothing else; deny TCP bind/connect where the ABI
  supports it. GUC `plzig.compiler_sandbox = off | on | require` (`on` = use if
  available and log once if not; `require` = refuse to compile without it).
- Parent: reads the pipe non-blockingly with a bounded buffer (64 KB kept, rest
  discarded), waits with `WaitLatchOrSocket` + `CHECK_FOR_INTERRUPTS()`, enforces
  `plzig.compile_timeout`. On timeout, cancel or any error: `kill(-pgid, SIGKILL)`
  and `waitpid` in `PG_FINALLY` — no zombies, no orphans.
- Compiler output shown to the user has the build-dir path stripped and line
  numbers adjusted to the function body.

## 7. Runtime (execution inside the backend)

- WAMR initialised lazily on first use in a backend (never in the postmaster).
- **Loading**: after `wasm_runtime_load`, enumerate imports and reject the module
  unless every import is a known function in module `plzig`; check the expected
  exports and `plzig_abi_version`.
- **Function cache** per backend: hash on function OID, validated against
  `pg_proc` `xmin` + `ctid` (as PL/pgSQL does). Entry holds module, instance,
  exec env, type I/O info. Small LRU (`plzig.instance_cache_size`, default 64) of
  entries not in use. Recursive entry into a busy instance creates a temporary
  second instance.
- **An instance that trapped or errored is destroyed**, never reused.
- **Error propagation**: host imports never `longjmp` through interpreter
  frames. Each import wraps its work in `PG_TRY`; on error it saves the
  `ErrorData`, sets a WAMR exception so the guest traps immediately, and the
  call handler re-throws after `wasm_runtime_call_wasm` has unwound. The guest
  cannot observe or swallow the error.
- **Pointers**: every guest address/length is validated
  (`wasm_runtime_validate_app_addr`) before use; native pointers into linear
  memory are never held across a call back into the guest (memory may move).
- `check_stack_depth()` before entering the guest.
- Guest globals persist per function per session (non-transactional, like other
  PLs' session state) and are never shared between functions.

### Host imports (module `plzig`) — the complete guest capability set

| Import | Notes |
|--------|-------|
| `log(level, ptr, len)` | DEBUG, LOG, INFO, NOTICE, WARNING only. |
| `raise(ptr, len)` | Raises `ERROR` (SQLSTATE `P0001`); does not return to the guest. |
| `panic(ptr, len)` | Zig safety-check failure → `ERROR` (internal error), instance discarded. |
| `spi_execute(...)` + result accessors | Parameters are passed as text (`$1::int` casts in SQL), results come back as text copied into guest memory. `read_only = true` unless the function is `VOLATILE`. Runs with the effective user's privileges exactly like PL/pgSQL (`SECURITY DEFINER` handled by fmgr). SPI connection opened lazily, closed at call end. |

Exact struct layouts are documented in `doc/abi.md` by the implementation.

## 8. GUCs

| Name | Context | Default | Purpose |
|------|---------|---------|---------|
| `plzig.zig_path` | SIGHUP (config file only), superuser-visible | bundled compiler | Compiler binary. |
| `plzig.compiler_sandbox` | SIGHUP | `on` | Landlock policy (D6/§6). |
| `plzig.compile_timeout` | SUSET | 300 s | Wall clock per compile. |
| `plzig.compile_memory_limit` | SUSET | 4 GB | `RLIMIT_AS` for the compiler (0 = off). |
| `plzig.max_source_size` | SUSET | 1 MB | Function body size limit. |
| `plzig.max_memory` | SUSET | 64 MB | Guest linear memory cap per instance. |
| `plzig.instance_cache_size` | SUSET | 64 | Cached instances per backend. |

Prefix reserved with `MarkGUCPrefixReserved` (15+) / `EmitWarningsOnPlaceholders` (14).

## 9. PostgreSQL practices checklist

PGXS build; `PG_MODULE_MAGIC` (`PG_MODULE_MAGIC_EXT` on 18+); version differences
isolated behind `PG_VERSION_NUM` checks in `plzig.h`; `ereport` with SQLSTATEs and
`errdetail`/`errhint`; all memory in contexts; no threads; no signal handlers;
validator honours `check_function_bodies` and `CheckFunctionValidatorAccess`;
compiled with `-Wall -Wmissing-prototypes -Werror` in CI; pg_regress suite via
`make installcheck`.

## 10. Testing (Docker)

`docker/Dockerfile` takes `PG_VERSION`, starts from `postgres:<ver>-bookworm`,
installs `postgresql-server-dev-<major>`, builds and installs the extension
using the vendored Zig tarball and WAMR checkout (no network needed for those).
`docker/run-tests.sh` builds and runs `make installcheck` for all six versions.

Regress coverage:

- basics: every mapped type, NULL handling, strict/non-strict, text-I/O types, procedures, `DO`.
- SPI: query, params, read-only enforcement in `STABLE`, permission denied for an
  unprivileged caller, `SECURITY DEFINER`.
- sandbox: each denied keyword/builtin/import rejected at `CREATE`; out-of-bounds,
  integer overflow, `unreachable`, deep recursion → clean `ERROR`, backend survives.
- resources: infinite loop stopped by `statement_timeout`; allocation beyond
  `plzig.max_memory` → error; arena released between calls; compile timeout.
- lifecycle: `CREATE OR REPLACE` picks up new code; `check_function_bodies=off`
  then lazy compile; `USAGE` revoked from PUBLIC; cache file permissions;
  no leftover build dirs.

## 11. Milestones

1. Skeleton: Makefile, WAMR + Zig fetch/pin, patch, `plzig.so` loads on PG 18.
2. SDK + template + validator; compile pipeline producing cached wasm.
3. Call handler with scalar types; errors/traps; interrupts.
4. SPI; text-I/O types; procedures; `DO`.
5. Sandbox hardening (Landlock, rlimits); LRU; cleanup paths.
6. Regress suite green on 14.25, 15.20, 16.16, 17.12, 18.7, 19 RC 2.
7. Docs.

## 12. To-do after v1

Not part of the v1 milestones. Both items target query-heavy functions, where
v1 is expected to be slower than PL/pgSQL; neither weakens the sandbox.

1. **Prepared statements for SPI.** v1 parses and plans every query on every
   execution. Add `plzig.prepare(sql, param_types)` returning an opaque handle,
   plus execute-by-handle.
   - Host keeps plans with `SPI_prepare` + `SPI_keepplan` in a per-instance
     table; the guest only ever sees a small integer index, validated on every
     use (range, liveness, owning instance). No host pointer crosses the boundary.
   - Plans are freed (`SPI_freeplan`) when the instance is destroyed (error,
     eviction, function replaced), so they cannot outlive the code that made them.
   - Cap the number of live plans per instance (GUC) to bound memory.
   - Read-only enforcement stays per execution (`read_only` flag from the
     function's volatility), not per plan.
   - Rely on the plan cache's own invalidation for DDL and `search_path` changes.
2. **Binary parameter and result passing.** v1 converts every SPI parameter and
   result column to and from text at the sandbox boundary.
   - Pass the natively mapped types (bool, int2/4/8, float4/8, text-like,
     bytea) as fixed-layout values with declared parameter type OIDs; keep text
     I/O as the fallback for every other type.
   - Result columns report their type so the guest SDK can offer typed getters
     (`row.get(i32, 0)`) that fail cleanly on a type mismatch.
   - Same rules as function arguments: host validates every guest pointer and
     length, copies in and out, and never trusts a guest-supplied type tag
     without checking it against the actual column or parameter type.
   - Extend `doc/abi.md` and bump the SDK ABI version (which also changes the
     cache key, so old modules recompile).
3. **Cursor-style, row-at-a-time fetching.** v1 `spi.execute` materialises the
   whole result set before the guest sees a row, so large results hit
   `plzig.max_memory`. Add `plzig.spi.open(sql, params)` returning a cursor
   with `next()` (one row, or null at the end) and `close()`.
   - Host opens a portal (`SPI_cursor_open_with_args`, or by prepared-plan
     handle once item 1 exists) and fetches in bounded batches
     (`SPI_cursor_fetch`, fixed batch size) so memory per cursor is capped on
     both sides; the SDK hands rows out one at a time.
   - The guest sees only a small integer index into a per-call cursor table,
     validated on every use. No portal name or host pointer crosses the boundary.
   - **Cursors never outlive the function call**: every cursor still open when
     the call returns or fails is closed by the host (no `WITH HOLD`, no
     returning cursors to SQL). On error, transaction abort cleans up portals
     as usual.
   - Cap on simultaneously open cursors per call (GUC) to bound portals/memory.
   - Row values live in a per-row scratch area that is recycled on `next()`,
     so iterating a huge result does not grow the arena; document that slices
     from a row are invalid after the next `next()`.
   - Read-only rule unchanged (cursor opened read-only unless the function is
     `VOLATILE`); forward-only, no scroll.
   - Works with binary passing (item 2) through the same typed getters.
4. **Licensing compliance** (from the licensing review, 2026-11-14; target
   license for our own code: The PostgreSQL License).
   - `LICENSE` added (PostgreSQL License, Copyright (c) 2026, Jonathan
     Jacobson). Owner decisions: keep The PostgreSQL License; use the pruned
     Zig install (below) once the implementation is tested.
   - Add `THIRD-PARTY-NOTICES`: WAMR 2.4.5 (Apache-2.0 WITH LLVM-exception,
     commit, copyright holders, statement of our change to
     `wasm_interp_classic.c`), the wasm-c-api header (Apache-2.0), Zig 0.17.1
     (MIT; embeds LLVM/clang/LLD), the PostgreSQL copyright notice.
   - Add `LICENSES/` with the Apache-2.0-with-LLVM-exception and Zig MIT texts.
   - `third_party/wamr-interrupt.patch`: state its license (Apache-2.0 WITH
     LLVM-exception) in the header and add a hunk putting a "modified by the
     PL/Zig project" notice at the top of the patched file (Apache-2.0 §4(b)).
   - `make install` must install `LICENSE`, the notices and the Apache text.
   - **Superseded by owner decision, 2026-11-14: Zig is an external
     mandatory dependency and is not installed by the extension, so there
     is no bundled or pruned Zig install (see Deviations from plan, 19).**
     Bundled Zig: its `lib/` carries LGPL (glibc), GPL-with-syscall-note
     (Linux headers) and Apple APSL headers without those license texts.
     Preferred fix: install a pruned `lib/` (only `std`, `compiler_rt`,
     `compiler`, `c` and top-level files — what a `wasm32-freestanding` build
     and the no-libc validator need). Untested; needs a build check on all six
     versions. Fallbacks: ship the tarball complete plus the missing license
     texts, or do not bundle Zig in binary packages.
   - Binary package license metadata: `PostgreSQL AND Apache-2.0 WITH
     LLVM-exception` (plus `MIT` while Zig is bundled).
   - README: license section, "not affiliated with or endorsed by PostgreSQL
     or the Zig Software Foundation", note that compiled `.wasm` modules
     contain MIT-licensed Zig runtime code.
5. Benchmark against equivalent PL/pgSQL (tight loop, string building, per-row
   call, SPI loop) before and after 1–3, to replace the current guesses.
6. **Done in phase D (2026-11-14), see Deviations from plan, 27.**
   **Remove the avoidable second copy of text results** (owner request,
   2026-11-14). A `text`/`varchar`/`bpchar` result is currently copied out of
   guest memory into a temporary buffer (`plzig_copy_out`), validated
   (`pg_verifymbstr`), and then copied again into the final varlena
   (`cstring_to_text_with_len`); `bytea` results are likewise copied twice.
   - Allocate the final varlena once, copy the guest bytes straight into
     `VARDATA`, and validate encoding in place (the validation rules — valid
     in the database encoding, no NUL bytes — must not change; on failure the
     allocation is simply released by the error).
   - Keep exactly one copy across the sandbox boundary: results must never
     alias guest memory.
   - Check the same pattern elsewhere and fix it where it is equally
     mechanical: SPI text/bytea parameters (`guest_string` followed by
     `cstring_to_text_with_len`), typed row values going into the guest, and
     function arguments (already a single copy — confirm).
   - Types returned through their input function (text I/O path) need the
     NUL-terminated C string and keep the temporary buffer.
   - Do it in phase D with the marshalling benchmark (task 10) measured
     before and after; add a regress case for invalid encoding and embedded
     NUL in a returned value if the suite does not already have one.
7. **Done (2026-11-14), see Deviations from plan, 28.**
   **Raising SQL errors with a chosen SQLSTATE, detail and hint** (owner
   decision, 2026-11-14). Today `plzig.raise` always uses `P0001`, and Zig
   errors and panics use `38000`.
   - SDK: e.g. `plzig.raiseError(.{ .sqlstate = "23514", .message = ...,
     .detail = ..., .hint = ... })` (formatting variants as for `raise`);
     never returns. One new host import; bump the SDK ABI version.
   - Severity is always `ERROR`. No way to raise `FATAL`/`PANIC`, and no way
     to raise a non-error level through this call.
   - SQLSTATE must be exactly five characters of `[0-9A-Z]`. Refused classes
     (the call fails with its own error naming the refused code): `00`, `01`,
     `02` (not errors); `08` (connection exception); `53` (insufficient
     resources); `57` (operator intervention, includes query_canceled and
     admin_shutdown); `58` (system error); `F0` (configuration file error);
     `XX` (internal error). Rationale: a function must not be able to make
     its own failure look like a server-level condition that monitoring,
     poolers and drivers act on. This is deliberately stricter than PL/pgSQL.
   - Message, detail and hint: validated in the database encoding, no NUL
     bytes, length-capped like `raise`; control characters handled as for
     compiler output.
   - Same propagation rule as every host import: stash the error, trap the
     guest, re-throw after the interpreter has unwound.
   - Tests: each refused class; malformed codes (length, case, non-ASCII);
     a raised code caught by `EXCEPTION WHEN SQLSTATE '...'` in a calling
     PL/pgSQL function; detail/hint visible; oversized and invalid text.
   - Still cut: catching SQL errors inside guest code. That needs a
     subtransaction around the guarded statements (see README limits).
8. **Research: subtransactions, for catching SQL errors in guest code**
   (owner request, 2026-11-14). Research and a written recommendation only —
   no implementation until the owner has seen the result.
   - Read how the in-tree languages do it, in the vendored sources for 14
     and 19: PL/pgSQL (`exec_stmt_block` in `pl_exec.c`), PL/Python
     (`plpy.subtransaction()`, `PLy_spi_subtransaction_*`), PL/Tcl
     (`pltcl_subtransaction`, `pltcl_subtrans_*`), PL/Perl; plus
     `BeginInternalSubTransaction` / `ReleaseCurrentSubTransaction` /
     `RollbackAndReleaseCurrentSubTransaction` in `xact.c` and the SPI
     hooks `AtEOSubXact_SPI`. Note version differences.
   - API shape options for PL/Zig and their trade-offs: an explicit
     scoped block (PL/Python style), an implicit subtransaction per
     "catchable" SPI call (PL/Tcl style), or both. What the guest sees
     (SQLSTATE, message, detail) when it catches.
   - Interaction with what exists: cursors and typed rows opened inside a
     rolled-back subtransaction (handles must die), prepared plans created
     inside one, the per-call SPI connection, recursion through SPI,
     temporary instances, the stash-trap-rethrow error path, the arena.
   - Which errors must never be catchable (query cancel, backend
     termination, out-of-memory?, internal errors) and how PL/pgSQL decides.
   - Bookkeeping risks: restoring `CurrentMemoryContext` and
     `CurrentResourceOwner` on every path; an error raised while aborting.
   - Costs: transaction-id consumption for writing subtransactions, the
     per-backend subtransaction cache overflow (more than 64) and its
     server-wide effect, behaviour on a hot standby and in parallel workers.
   - Whether a cap on subtransactions per call is warranted (GUC).
   - Deliverable: `doc/research-subtransactions.md` with findings, a
     recommended design or a recommendation not to do it, the tests it
     would need, and an effort estimate.
9. *Optional.* **Enable WAMR bulk-memory** (`memory.copy`/`memory.fill`;
   WAMR build and `-mcpu` for guests). Helps string- and copy-heavy code
   (every guest `memcpy`/`memset` becomes one native operation instead of
   an interpreted byte loop; doc/benchmarks.md tasks 3 and 4). Enlarges the
   interpreter surface slightly. The loader fuzz target must be run on the
   new configuration (and pass) before it is enabled.
10. *Optional, not planned.* **WAMR fast interpreter or AOT.** The fast
    interpreter had a heap-overflow CVE fixed in the release we use (2.4.5);
    AOT means running native code generated from guest modules inside the
    backend. Both stay rejected (D2); the benchmark numbers are the
    baseline if this is ever reconsidered.
11. *Optional.* **Skip the `ReleaseSafe` 0xAA fill of guest allocations**
    (`@memset(undefined)` in `Allocator.alloc`, ~8 ns per byte in the
    interpreter). Harmless to the host (guest memory only), but it changes
    what a buggy function sees: uninitialised memory would hold leftovers
    of earlier calls of the same instance instead of 0xAA.
12. **Native mappings for more built-in types** (owner decision,
    2026-11-15; before the extension port of item 13 and before packaging).
    **Steps 1–4 done (2026-11-15), see Deviations from plan, 29; step 5
    (arrays) not started.**
    Today every type other than bool, int2/4/8, float4/8, text-like and
    bytea crosses the boundary as text. In this order:
    1. **Done.** *Fixed-width types*: `date`, `time`, `timestamp`, `timestamptz`,
       `interval`, `uuid`, `oid`. Raw values in the existing 16-byte slot;
       the host range-checks every value a guest returns or passes as an SPI
       parameter (PostgreSQL's own range macros) and raises an error for an
       invalid one.
    2. **Done.** *`numeric`*: PostgreSQL's binary wire format in both directions
       (`numeric_send` / `numeric_recv`: architecture independent, and
       `numeric_recv` is the server's validating path for untrusted bytes).
       Comparison, conversion to `i64`/`f64` and formatting in the SDK;
       arithmetic as host imports that call the native functions, so results
       are PostgreSQL's exactly.
    3. **Done.** *Time zone and calendar conversion* as host imports (the guest sees
       neither the time zone database nor the session's `TimeZone`).
    4. **Done.** *`jsonb` input* in the on-disk layout (stable since 9.4, identical in
       14–19), read in place by an SDK reader: lazy, binary search on object
       keys. Parsing happens inside the sandbox. `jsonb` *results* stay text
       through `jsonb_in`: a guest-built binary value stored unchecked would
       be a data-integrity risk. The layout is in host byte order: on a
       big-endian host the type falls back to text. Fallback if the reader
       proves troublesome: host accessor imports behind the same SDK
       interface.
    5. *Arrays* of natively mapped element types: later. Composites, ranges
       and enums stay text.
    The same mappings apply to SPI parameters and result columns. Each step:
    regression tests, hostile-guest cases for returned values, and the SDK
    readers get a fuzz target.
    Considered and rejected: compiling PostgreSQL's own type code
    (`numeric.c`, `jsonb_util.c`, ...) into the guest. It needs a stand-in
    for the backend (`palloc`, `ereport`/`longjmp`, `fmgr`) and a libc in
    every module, vendored PostgreSQL sources (not installed by PGXS), and
    would run interpreted, where a host call into the native function is
    expected to be faster. ecpg's `pgtypeslib` also needs libc and differs
    from the server in behaviour.
13. **Port a real PL/pgSQL extension and compare** (owner request,
    2026-11-15): `postgres-json-schema` (`validate_json_schema(jsonb,
    jsonb)`), in a separate repository; correctness by the extension's own
    test suite; benchmark the original against the PL/Zig port (text and
    binary `jsonb`), with the Rust `pg_jsonschema` as a third data point.
14. **Features cut from v1 (D10) that are now planned** (owner decision,
    2026-11-15; after item 12, which reworks the same marshalling code, and
    before packaging, so that 1.0.0 ships with them). In this order:
    1. *`OUT`/`INOUT`/`TABLE` parameters and composite results.* The
       function returns a Zig struct; the host builds the row
       (`heap_form_tuple`) from fields it has type-checked one by one, as it
       does for a scalar result. Foundation for the next two.
    2. *Set-returning functions.* Materialize mode: the guest pushes rows
       through a host import into a tuplestore (as PL/pgSQL's `RETURN NEXT`),
       bounded by `work_mem` as usual. No value-per-call mode: an instance
       never stays suspended between calls.
    3. *Row and statement triggers.* `NEW`/`OLD` as structs, `TG_*` data
       through the SDK; the function returns a modified row, the original,
       or null to skip. The returned row is built by the host from checked
       fields and must match the table's row type; a trigger function keeps
       the permissions of its owner/caller like any other function.
    4. *Transaction control in procedures*: `plzig.commit()` and
       `plzig.rollback()` (`SPI_commit`/`SPI_rollback`), only where
       PostgreSQL allows it (non-atomic context: `CALL` or `DO` outside a
       transaction block and not below a function; otherwise PostgreSQL's
       own error is reported). To settle in the design: SPI is connected
       non-atomically only for procedures and `DO`; every cursor of the call
       is closed at commit/rollback (no holdable portals); prepared plans
       survive (they are saved plans); nothing the host keeps for the call
       may live in a transaction-lifetime memory context or resource owner;
       an error during commit destroys the instance like any other error.
       Catching SQL errors (item 8, subtransactions) stays separate.
    Still not planned: event triggers (they run around DDL with elevated
    context), polymorphic and other pseudo-types, `VARIADIC`, aggregate and
    window function support.

## 13. Roadmap after v1 is operable

Planned 2026-11-14. Phases run in this order; each has an exit gate, and a
phase does not start until the previous gate is met. Findings from phases A–C
are fixed as they are found, with a regression test added for each.

Section 12 items (prepared statements, binary passing, cursors, licensing
compliance, pruned Zig install) are scheduled between phases B and D: the
licensing and pruned-install items before packaging (E), the three SPI items
before the benchmark (D) so the published numbers describe the real product.

### A. Code review (by Fable, independent of the implementing agent)

The implementing agent's report is treated as a claim, not as evidence.

1. Re-run the full Docker matrix myself first; record the baseline.
2. Manual review, security-critical code first, in this order:
   1. `plzig_host.c` — every host import: guest pointer/length validation,
      integer overflow in size arithmetic, no native pointer held across a
      guest call, no `ereport` escaping through interpreter frames.
   2. `plzig_runtime.c` — allocator (no-OOM paths, realloc on 14/15), import
      allowlist, instance lifetime after traps, recursion, LRU eviction of
      in-use entries, interrupt flag wiring; the WAMR patch itself.
   3. `plzig_spawn.c`, `plzig_sandbox.c` — fd hygiene, signal state in the
      child, env construction, kill/reap on every path, Landlock rule set,
      behaviour when Landlock is unavailable.
   4. `plzig_build.c` — path construction, directory ownership/mode checks,
      symlink handling, TOCTOU windows, atomic cache writes, lock handling.
   5. `plzig_source.c`, `zig/validate` — can user text escape the generated
      function or reach `build.zig`; validator allowlist vs. the 0.17.1 builtin
      and keyword lists; identifier quoting.
   6. `plzig_types.c`, `plzig.c` — detoasting, NULLs, encoding, cache
      invalidation, validator permission checks, GUC contexts.
   7. `zig/sdk` — arena correctness, what `plzig.std` really exposes.
3. Per-version pass: diff the `PG_VERSION_NUM` branches against the vendored
   sources for 14 and 19.
4. Automated second opinion: `/code-review` and `/security-review` on the
   tree, findings verified before acting on them.
5. Check the code against PLAN.md; every deviation is either fixed or recorded.

Exit gate: no open high/medium finding; all six versions green; warning-free
build with `-Wall -Wextra -Werror`.

### B. Testing

| Layer | Tooling | Covers |
|-------|---------|--------|
| Unit (Zig) | `zig test`, native | Validator: one accept and one reject case per builtin/keyword, tricky tokens (`@"..."`, strings, comments, multiline literals). SDK arena: alignment, growth, reset, OOM at the cap. |
| Unit (C) | SQL-callable test helpers built only with `PLZIG_TESTING` | Source generation, cache-key stability, path builders, error-text sanitising. |
| Regress | `pg_regress` (existing suite, extended) | Types, NULLs, strict, text-I/O types, domains, procedures, `DO`, SPI, errors, every rejection path. |
| Isolation | `pg_isolation_regress` | Concurrent compile of the same and of different functions, `CREATE OR REPLACE` while another session is executing, compile-lock waits and cancel. |
| TAP | `PostgreSQL::Test::Cluster` | Restart and crash recovery (stale build dirs swept), hot standby (lazy compile on a replica), `pg_dump`/restore, `pg_upgrade` 14→19, `DROP EXTENSION`, cache dir deleted or made unwritable, compile timeout, `statement_timeout` and `pg_terminate_backend` during guest loops and during compiles. |
| Build variants | Docker | `--enable-cassert` + `MEMORY_CONTEXT_CHECKING` + `CLOBBER_FREED_MEMORY` servers; x86_64 and aarch64; GCC and Clang. |
| Leak checks | Regress under Valgrind (`USE_VALGRIND` server); fd and child-process counts before/after each test | Memory, descriptors, zombies. |

CI runs the matrix (6 versions × 2 architectures) on every change; coverage
report (`gcov`) for the C code, target ≥ 85 % lines with every error branch in
the spawn/build/host files exercised or justified.

Exit gate: all layers green on all six versions and both architectures.

### C. Security testing

Threat model written down first (`doc/security.md`): attacker is a database
user with `USAGE` on the language and nothing else; assets are other users'
data, the server OS account, and availability. A second, weaker attacker can
write to the cache directory (tests the "poisoned module stays sandboxed" claim).

**Fuzzing** (harnesses under `fuzz/`, corpora committed, run continuously in
CI for a time budget and for ≥ 24 h per target before a release):

| Target | Method | What it hunts |
|--------|--------|---------------|
| `plzig-validate` | libFuzzer/AFL++ on raw bytes + Zig-token dictionary; differential check against the compiler: anything the validator accepts must not contain a denied construct after real parsing | Validator bypass, crashes. |
| Module loader + import allowlist | libFuzzer on WAMR load → our checks → instantiate, ASan/UBSan, seeded with real modules and structure-aware mutations | Memory-safety bugs reachable from a poisoned cache file. |
| Host import ABI | Hand-written hostile wasm modules plus a fuzzer generating call sequences with arbitrary pointers, lengths, row/column indexes and re-entrancy, loaded through a test-only hook that does not exist in release builds | Out-of-bounds host reads/writes, overflow, use-after-grow. |
| Interpreter under our config | Fuzzed valid modules (wasm-smith) run with the interrupt patch | Patch correctness, hangs. |
| Marshalling | Property-based SQL: random values of every supported type round-trip through an identity function and must compare equal; random NULL patterns | Datum handling, encoding, detoast. |
| Source generator | Random signatures: odd argument names, quoted identifiers, many arguments, every type category | Injection into `user.zig`, rejected-type gaps. |
| Whole pipeline | Grammar-based random Zig bodies, plus mutated real ones | Compiler crashes/hangs handled cleanly, resource limits hold. |
| SQL surface | SQLsmith-style random calls on an ASan/UBSan server build | Backend crashes. |

**Adversarial test suite** (deterministic, kept as regress/TAP tests):

- Sandbox escape attempts: each denied construct, comptime reflection to
  reach `std` internals, `@embedFile`/`@import` path tricks, attempts to add
  imports or exports.
- Resource exhaustion: comptime bombs, giant source, deep recursion, memory
  growth, huge SPI results, many functions (instance cache), compile storms.
- Filesystem: symlinks and hard links planted in the cache/build dirs, wrong
  owner or mode, races between check and use, disk full, leftover temp files.
- Compiler confinement: with Landlock enforced, a test build script that
  tries to read outside its allowed paths and open a socket must fail;
  verify rlimits and the scrubbed environment from inside the child.
- Privilege: no `USAGE` → cannot create; `SECURITY DEFINER`/`INVOKER`
  behaviour; row-level security and column privileges respected through SPI;
  read-only enforcement; error messages leak no server paths.
- Fault injection: compiler killed mid-build, backend killed mid-compile and
  mid-call, cancel at every stage.

Static analysis: `scan-build`, `cppcheck`, CodeQL, compiler hardening flags.
Any crash of a backend, anywhere, is a release blocker.

Exit gate: fuzz targets clean for the time budget, adversarial suite green,
threat model reviewed against the final code, residual risks documented.

### D. Benchmark suite

`bench/`, Docker-based, one command, results to CSV plus a generated report
with charts. Languages: SQL (baseline where expressible), PL/pgSQL,
PL/Python (`plpython3u`), PL/Perl (`plperl`), PL/Zig. Each task implemented
idiomatically in each language and checked to return identical results.

| # | Task | Stresses |
|---|------|----------|
| 1 | Trivial function over 1 M rows | Per-call overhead |
| 2 | Integer and float loops (primes, Mandelbrot row) | Raw computation |
| 3 | String building and concatenation | Allocation, text handling |
| 4 | Parsing (split CSV line, validate/normalise identifiers) | Byte-level work |
| 5 | Hashing/checksum of a `bytea` | Tight loops over buffers |
| 6 | Edit distance against each row of a query result | Query loop + CPU work |
| 7 | Many small lookups by key in a loop | SPI round-trip cost, plan caching |
| 8 | Row-by-row aggregation over a large result | Result fetching, cursors |
| 9 | Insert/update loop | DML through SPI |
| 10 | Large text/bytea argument in and out | Marshalling |
| 11 | First call in a new session; first-ever call after `CREATE` | Load and compile cost |
| 12 | Memory high-water mark per backend for tasks 3, 6, 8 | Footprint |

Method: fixed hardware description recorded, tuned-identically server, JIT on
and off, warm-up then ≥ 10 timed runs, report median and spread, single
session plus a `pgbench` concurrency run for tasks 1 and 7. Primary numbers on
PG 18; a short cross-version run on 14 and 19. Stated openly in the report:
PL/Python is untrusted and unsandboxed, so it is a speed reference, not a
like-for-like alternative; trigger and set-returning workloads are absent
because PL/Zig v1 does not support them.

**PL/Python and PL/Perl are benchmark-only.** They are installed solely in
the benchmark's own Docker image (`bench/Dockerfile`), which is built and used
only by the benchmark stage in CI. They are never a build, runtime or test
dependency of the extension, are not in the regress/TAP test images, are not
declared or recommended by any package, and are not in the evaluation Docker
image. Nothing under `bench/` is installed by `make install` or included in
binary packages.

Exit gate: reproducible numbers published in `doc/benchmarks.md`; the guesses
in earlier discussion replaced; any task where PL/Zig is unexpectedly slow is
profiled and explained or fixed.

### E. Packaging

Prerequisite decisions:

- **Offline, reproducible builds.** Add `make dist` producing a source tarball
  and a documented fully offline build (`ZIG_TARBALL=`, `WAMR_SRC=`), since
  distribution builders have no network.
- **The Zig toolchain is the hard part.** Distribution policies generally do
  not allow downloading or bundling a prebuilt compiler inside a package, and
  Zig 0.17.1 is not packaged by most distributions. Plan: split into
  `plzig_<pgmajor>` (the extension, links WAMR statically, declares it as a
  bundled library) and a version-locked, PG-independent `plzig-zig-toolchain`
  package holding the pruned Zig install. Where a repository accepts a
  repackaged upstream binary the toolchain package uses it; where it does not,
  the extension depends on a distribution `zig` of exactly 0.17.x and refuses
  to run with another version. To be confirmed with each repository (phase F).
- `plzig.zig_path` default becomes a packaging-time setting.

Deliverables:

- RPM spec and Debian packaging (`debian/`, `pg_buildext`-based) building for
  PG 14–19 from one source, x86_64 and aarch64; EL 8/9/10, Fedora current,
  Debian 12/13, Ubuntu 22.04/24.04/26.04.
- License files, `THIRD-PARTY-NOTICES`, and correct license metadata in every
  package (section 12 item 4).
- Docker image `plzig/postgres:<major>` for evaluation. Contains PostgreSQL and
  PL/Zig only — no other procedural languages.
- Versioning: semver; extension upgrade scripts (`plzig--1.0--1.1.sql`);
  SDK ABI version independent of the extension version; documented
  compatibility table (extension × PG major × Zig).
- Package dependencies are limited to PostgreSQL itself and the Zig toolchain
  package; a packaging test asserts that no package depends on, recommends or
  suggests PL/Python or PL/Perl.
- Package tests: install on a clean image, `CREATE EXTENSION`, run the regress
  suite against the installed package, upgrade from the previous package,
  remove cleanly (cache dir handling documented).
- Release artefacts signed; checksums published; SBOM (SPDX) generated.

Exit gate: packages for all six majors install and pass the suite on every
target distribution in clean containers.

### F. Publishing to repositories

In increasing order of external dependency. Each step needs the owner's
accounts and approval; nothing is published without an explicit go-ahead.

1. **Public source repository and tagged release** — prerequisite for all
   others: issue tracker, `SECURITY.md` with a private reporting address,
   contribution terms that keep relicensing possible, CI badges.
2. **PGXN** — `META.json` (name, abstract, version, license `postgresql`,
   `provides`, PG version prerequisites, tags, resources), `pgxn-utils`/
   `pgxn-tools` to validate and bundle, upload from the release workflow.
   Document that `pgxn install plzig` needs a C toolchain, CMake, and either
   network access or a pre-fetched Zig tarball.
3. **Pigsty extension repository** — open a request with the maintainers,
   supply the spec/`debian` packaging from phase E and the toolchain-package
   proposal; adapt to their build tooling and naming.
4. **PGDG** — yum (`yum.postgresql.org`) via a packaging request with the
   spec file; apt (`apt.postgresql.org`) via the Debian packaging, which in
   practice means meeting Debian policy (source-only build, no bundled
   prebuilt binaries, WAMR either packaged separately or justified as an
   embedded patched copy). Expect this to be the slowest and to drive the
   toolchain-package decision; start the conversation early, during phase E.
5. Announcement (pgsql-announce, PGXN blurb) only after C and D are complete
   and the security model document is public.

Exit gate per repository: package installable from that repository on a clean
system and passing the installed-package test.

Open risks for E/F, to be raised with the owner when they become concrete:
whether repositories accept a bundled or repackaged Zig toolchain; whether
Debian accepts a patched embedded WAMR; upstreaming the interrupt patch to
WAMR to remove that objection.

## 14. Versioning and Zig upgrades (owner decision, 2026-11-14)

**PL/Zig has its own semantic version; it does not mirror Zig's.** A scheme
like `0.17.1.0` was considered and rejected: PL/Zig's own incompatible
changes (ABI, SDK API, SQL surface) would have no place in it, PGXN requires
three-part semantic versions, and the coupling breaks as soon as one Zig
release needs two PL/Zig lines.

- `MAJOR.MINOR.PATCH`. A new Zig minor release (0.18) forces a new PL/Zig
  **major**; a Zig patch release (0.17.2) is a PL/Zig **minor**; PL/Zig's own
  changes follow the usual rules (incompatible SDK/SQL change = major).
- The first published release is `1.0.0` (extension version `1.0`). Until
  then nothing is promised: the ABI and SDK change freely.
- The pinned Zig version is shown everywhere else: extension comment and
  control file, `plzig_sandbox_status()`, release notes, package description
  and dependency (`zig = <pin>`), and a compatibility table in the README
  (PL/Zig 1.x: Zig 0.17.1; ...).
- Not decided: semantic-version build metadata (`1.0.0+zig.0.17.1`). Check
  that PGXN, RPM and Debian all accept it before using it.

**One Zig version per PL/Zig release; Zig is not a test-matrix dimension.**
The validator uses the pinned version's tokenizer and classifies that
version's builtins (a unit test fails on an unclassified builtin), and the
server refuses any other compiler. Supporting several at once would multiply
the validator, SDK and flag sets that need review and fuzzing.

- *Zig patch release:* bump the pin, the checksums and, if needed, the
  validator tables; full suite and fuzz targets; PL/Zig minor release. The
  Zig version is in the module cache key, so every function recompiles once.
- *Zig minor release:* function bodies are stored as source and may stop
  compiling; failures surface at first call (also after dump/restore, which
  restores with `check_function_bodies = off`). Therefore:
  1. **`plzig_check_all()`** (to do; useful before any Zig upgrade too): a
     superuser-only function that compiles every PL/Zig function with the
     configured compiler, under the normal sandbox and limits, and returns
     the ones that fail with their error. It must not execute any function,
     must respect the compile lock and cancellation, and must not leave
     modules in the cache for functions that fail.
  2. An upgrade note listing the Zig language and `std` changes that affect
     function bodies; a pass over the SDK's curated `std` subset and its
     probing tests.
  3. An overlap period in which the previous PL/Zig major (previous Zig)
     still receives fixes.
- *CI:* the matrix stays PostgreSQL versions x one Zig. Add one job against
  the newest Zig release that is allowed to fail (early warning only).

## Deviations from plan

Recorded by the implementation (2026-11-14). The sections above are unchanged.

1. **No `zig build`, no `build.zig` template.** The backend runs
   `zig build-exe` directly with a fixed argv (`plzig_zig_flags` in
   `src/plzig_build.c`). `zig build` would compile and then *execute* a
   native build runner on every cache miss (and needs execute permission in
   the shared Zig cache under Landlock); the direct invocation has the same
   inputs (fixed flags, no user text on the command line) with less code
   running. Side effect: a cold compile takes ~3 s instead of ~69 s.
   `zig/template/build.zig` therefore does not exist.
2. **SDK copied into each build directory** (`sdk/plzig.zig`, `sdk/root.zig`)
   rather than referenced from `$(sharedir)`; Zig module paths are then all
   relative to the private build directory. The SDK files' SHA-256 is part
   of the cache key.
3. **Zig global cache is `$PGDATA/plzig/pgsql_tmp.zig-cache`** so base
   backups skip it.
4. **Guest allocator is a custom bump arena**, not `std.heap.ArenaAllocator`
   over `wasm_allocator`: the latter did not reuse a retained 40 MB block,
   so three 40 MB calls failed under the 64 MB cap. The bump arena is reset
   at the start of every call.
5. **SQLSTATE 38000 (external_routine_exception)** for Zig panics, traps and
   returned Zig errors, instead of XX000 (internal_error), which monitoring
   treats as a server bug. `plzig.raise` uses P0001 as planned.
6. **The WAMR patch is ~30 lines, not 3**: besides defining
   `CHECK_SUSPEND_FLAGS()` for builds without the thread manager, every
   existing call site is guarded by `#if WASM_ENABLE_THREAD_MGR != 0`, so the
   patch extends those 15 guards with `|| WASM_ENABLE_PLZIG_INTERRUPT != 0`.
   It is generated against the pinned commit and applied with `--fuzz=0`.
7. **Validator policy is stricter than listed**: additionally denied are the
   keyword `volatile` and the builtins `@ptrCast`, `@alignCast`,
   `@constCast`, `@volatileCast`, `@intFromPtr`, `@addrSpaceCast`,
   `@prefetch`, `@returnAddress`, `@frameAddress`, `@errorReturnTrace`,
   `@breakpoint`, `@disableInstrumentation`, `@disableIntrinsics`,
   `@cVa*`, `@Pointer`, `@Fn`, `@SpirvType`, `@work*`, `@frame`/`@Frame`
   (allowlist derived from `lib/std/zig/BuiltinFn.zig` of 0.17.1). Zig
   0.17.1 has no `usingnamespace`, `@cImport` or `@cInclude`, so those need
   no rule.
8. **`plzig.compile_timeout` is in milliseconds** (default 300 s, minimum
   100 ms) so the regression suite can test the timeout deterministically.
   The timeout applies to each child run (validator, compiler) separately.
9. **Added `plzig_sandbox_status()`** (superuser only, revoked from PUBLIC):
   shows whether the last compilation in the session was Landlock-confined.
   `on` mode logs once per backend (`LOG`) when Landlock is unavailable.
10. **Parameter names `plzig` and `std` are rejected** (they would shadow the
    predeclared names).
11. **`plzig.max_memory` is enforced in the host allocator**, because WAMR
    silently raises `max_memory_pages` to the module's initial size. A cached
    instance created under a different `plzig.max_memory` is discarded on
    next use. Maximum value is 1023 MB (palloc limit). `plzig.max_source_size`
    is capped at 3 MB (validator input buffer is 4 MB).
12. **Runtime self-check**: after initialising WAMR the backend compares all
    signal dispositions and its thread count with a snapshot taken before;
    any change is FATAL for that backend.
13. **WAMR build trimmed further** than D2 lists: bulk-memory, reference
    types, tail calls, exception handling, extended-const, wakeup-blocking-op
    (installs a signal handler), app entry and custom sections are also
    disabled; WAMR's own log output is discarded (`BH_VPRINTF`); linear
    memory goes through the host allocator (`WAMR_BUILD_ALLOC_WITH_USAGE`);
    the invokeNative assembly is built with `--noexecstack` and `plzig.so`
    is linked with `-z noexecstack`.
14. **Landlock rules**: in addition to the planned ones, `/dev/null` is
    read/write and, at ABI ≥ 6, signals and abstract UNIX sockets outside
    the domain are scoped away. If `plzig.zig_path` points elsewhere, its
    directory gets read+execute.
15. **`doc/plzig.md` was not written**; user documentation is in README.md.
16. **Tests that need `postgresql.conf` changes** (forbidden-import modules
    produced by fake compilers, Landlock probe, cache tampering, file modes,
    zombie check) live in `docker/security-checks.sh`, run by
    `docker/run-tests.sh` after the pg_regress suite, not in pg_regress.
17. **`-Werror`** is enabled by `make WERROR=1` (used by the Docker build),
    not unconditionally.
18. The §1 example (`add(a int, b int)` without `STRICT`, body
    `return a + b;`) does not compile under the §5 convention (non-STRICT
    parameters are optionals); documentation examples use `STRICT`.
19. **D5 is superseded by owner decision on 2026-11-14: Zig is an external
    mandatory dependency, not installed by the extension.** Reasons:
    redistributing Zig's `lib/` carries LGPL/GPL/APSL-licensed headers,
    distributions do not accept a bundled prebuilt compiler, and the
    administrator should own the toolchain. Consequences:
    - `make` needs `ZIG=/abs/path/to/zig` (only to build `plzig-validate`)
      and fails unless `zig version` is exactly 0.17.1; that version is
      compiled into `plzig.so` (`PLZIG_ZIG_VERSION`). `make install`
      installs no Zig files. `make fetch-zig` / `make install-zig
      ZIG_PREFIX=...` are opt-in helpers that download (or take
      `ZIG_TARBALL=`), verify the pinned SHA-256 and unpack to a prefix the
      user chose; they refuse to overwrite an existing directory.
    - `plzig.zig_path` has no default (§8's "bundled compiler" is gone);
      unset means every compile fails with a hint, cached modules still
      run, `CREATE EXTENSION` works. `PATH` is never searched.
    - New config-file-only, superuser-only settings `plzig.zig_lib_dir`
      (default: detect `<dir>/lib` or `<dir>/../lib/zig` next to the
      resolved binary) and `plzig.zig_sha256` (optional pin of the binary,
      not of `lib/`). No check hooks: a bad value fails compiles instead of
      silently keeping the previous value.
    - Before first use per backend (redone when a setting or the
      binary's/lib directory's identity changes): absolute path, `realpath`,
      regular file; binary, lib directory and **all** their ancestor
      directories owned by root or the server euid and not group/other
      writable (sticky directories accepted above the immediate parent —
      stricter than the brief, which named only the containing directory);
      neither inside nor containing `$PGDATA`; optional SHA-256 (PostgreSQL
      cryptohash + transient file); under Landlock a dynamically linked or
      `#!` binary is refused (it could not start); then `zig version` is run
      through the confined spawn path and must equal `PLZIG_ZIG_VERSION`.
      Path/permission checks run on every compile, the rest is cached.
    - Landlock (replaces the extra rule in item 14): execute+read **file**
      rules on the resolved compiler binary and on `plzig-validate` (no
      directory gets execute any more), read-only on the lib directory,
      which is passed explicitly with `--zig-lib-dir` (verified in 0.17.1's
      `build-exe --help`; Zig then skips its own lookup). The file-level
      execute rule works for the official statically linked compiler
      (verified by the Docker suite with Landlock enforced). A dynamically
      linked compiler would also need execute on its ELF interpreter and
      read on its shared libraries; that is not granted.
    - Cache key unchanged: it already contains `PLZIG_ZIG_VERSION`, and no
      other compiler version can produce modules, so it equals the verified
      version. Compiler output has the lib directory replaced by
      `<zig lib>/` (previously the bundled path became `$libdir`).
20. **`plzig.compiler_sandbox` is `require | try | off`, default `require`**
    (owner decision, 2026-11-14; D6/§6/§8 said `off | on | require`,
    default `on`). `try` is the old `on` (name after `huge_pages = try`);
    `on` is no longer accepted (nor booleans), so an old configuration
    fails loudly instead of meaning something weaker than the default — in
    practice a backend logs `invalid value` when it loads the library and
    keeps the default `require`. Without Landlock every compile is refused
    with the errno and a hint that `try` allows unconfined compilation with
    the server OS user's full rights; cached modules still run.
    `docker/run-tests.sh` dropped `PLZIG_REQUIRE_LANDLOCK` (the suite
    cannot pass unconfined any more) and runs a second container per
    version with Landlock blocked by seccomp.
21. **Owner decisions, 2026-11-14 (later the same day):**
    - Deviation 1 (no `build.zig`, direct `zig build-exe`) is **accepted by
      the owner**; the original "write and run a build.zig" requirement is
      withdrawn.
    - `plzig.compiler_sandbox` is now a string setting validated at compile
      time instead of an enum, which supersedes the "logs `invalid value`
      and keeps the default" behaviour in entry 20: any value other than
      exactly `require`, `try` or `off` (the former `on`, booleans, other
      letter case) makes every compilation fail with an error naming the
      setting. Cached modules still run.
    - The setting is config-file only like the toolchain paths
      (`GUC_DISALLOW_IN_AUTO_FILE` added, so `ALTER SYSTEM` is refused too);
      it can change only by editing `postgresql.conf` and reloading.
22. **Hardening round after an independent review (2026-11-14).**
    - *Module cache bounded.* `DO` blocks are compiled, run from the build
      directory and never written to the cache (`plzig_get_wasm(...,
      use_cache)`). New `plzig.max_module_size` (superuser, default 2 MB,
      16 kB–16 MB; own error, no path) and `plzig.cache_size_limit`
      (config-file only, `GUC_DISALLOW_IN_AUTO_FILE`, default 256 MB, min
      64 MB). Before a module is stored, under the compile lock, every
      `<key>.wasm.tmp.<pid>` is removed (one exists only while its writer
      holds the lock) and modules are evicted oldest-mtime first until the
      new one fits; a cache hit refreshes the mtime at most once a minute.
      Only regular files directly in `cache/` matching `^[0-9a-f]{64}\.wasm$`
      or the temp pattern are touched. New superuser-only
      `plzig_cache_clear()` (EXECUTE revoked from PUBLIC; `sql/plzig--1.0.sql`
      edited in place, no release yet). The temp file is unlinked on every
      write/fsync/rename failure; `durable_rename` gets data-directory-
      relative paths so fd.c's messages do not show `$PGDATA`.
      `plzig.compile_timeout` default lowered from 300 s to 30 s (supersedes
      the default in entry 8); the Docker suite passes with the default.
    - *Sandbox: Landlock by ABI plus a seccomp filter.* Landlock now handles
      `FS_RESOLVE_UNIX` (ABI 9) and `NET_BIND_UDP`/`NET_CONNECT_SEND_UDP`
      (ABI 10), granted by no rule; ABIs 7 (audit flags) and 8 (TSYNC) add
      no access rights. `FS_MAKE_SYM` was dropped from the read-write rule
      (strace of cold, warm and failing compiles: Zig 0.17.1 creates no
      symlinks; it needs create/remove of files and directories, truncate,
      and cross-directory renames in its caches, i.e. REFER). A seccomp-bpf
      deny filter (raw BPF, x86_64/aarch64 with an arch check, x32 and
      foreign-arch calls denied) is installed after Landlock, before
      `execve`; denied calls return EPERM, `clone3` ENOSYS, `kill`/`tkill`/
      `tgkill`/`rt_(tg)sigqueueinfo` only towards the child's own pid. Zig
      needed none of the denied calls. `require` now means Landlock ABI >= 6
      **and** the filter (probed in the backend with a NULL program, which
      fails with EFAULT exactly when filter mode is usable); the error names
      what is missing. `try` applies what is available and logs once per
      backend what is missing; `off` applies neither. There is no setting to
      lower the minimum ABI. `plzig_sandbox_status()` reports
      `enforced|partial|none (landlock ABI n|no landlock, seccomp|no
      seccomp[; missing: ...])`. The Docker matrix gained a third container
      per version whose profile makes `prctl(PR_SET_SECCOMP)` fail; it checks
      the `require` refusal and shows what Landlock alone enforces.
      (Supersedes the Landlock-only description in entries 9, 14 and 20.)
    - *Recursive delete is descriptor-relative.* `openat(O_NOFOLLOW |
      O_DIRECTORY)`, `fstat` + same `st_dev` as the top, `fdopendir`,
      `unlinkat`, depth <= 64, external descriptors accounted with
      `AcquireExternalFD`; no ERROR and no allocation while descriptors are
      open, problems reported afterwards at WARNING (LOG in the exit
      callback).
    - *Build directories* are `pgsql_tmp.build.<pid>.<n>.<16 hex from
      pg_strong_random>`; `EEXIST` draws a new name. Stale ones are swept by
      every compilation, under the compile lock, regardless of pid
      liveness: each compilation holds that lock from `mkdir` to removal, so
      any other build directory seen while holding it is stale.
    - *No data directory in client messages.* Paths under `$PGDATA` are
      shown relative to it (the backend's cwd), the full path goes to
      `errdetail_log`; compiler output additionally has the Zig cache and
      data directory replaced.
    - *Compiler output sanitised always*: C0 controls except `\n`/`\t`, and
      DEL, become `?`; non-ASCII too if the encoding check fails;
      continuation lines of the DETAIL are indented by two spaces.
    - *Idle instances*: new `plzig.instance_cache_max_memory` (superuser,
      default 4 MB): an instance whose linear memory exceeds it is destroyed
      after the call instead of being cached.
    - The validator is built with `-mcpu baseline`.
23. **§12 items 1–3 implemented (prepared statements, binary passing,
    cursors), 2026-11-14.** SDK ABI version 2 (part of the cache key, so
    every module is recompiled); 10 new host imports (19 in total, listed
    in `doc/abi.md`); new superuser GUCs `plzig.max_prepared_plans`
    (default 64, per instance) and `plzig.max_open_cursors` (default 16, per
    call), both an error when exceeded, never an eviction. Tests:
    `test/sql/spi_prepared.sql`, `test/sql/spi_cursor.sql`, and a hostile-
    guest section in `docker/security-checks.sh`. Implemented as written,
    except:
    - *Names.* `plzig.spi.prepare` (the bullet said `plzig.prepare`),
      `Plan.execute/open/free`, `plzig.spi.open`, `Cursor.next/close`,
      `Row.get(T, col)`. Added `spi_plan_free` (`Plan.free()`), so a
      function can stay under the cap; a freed handle is stale.
    - *Handles* are `serial << 16 | index`; the serial (the "generation")
      comes from a per-backend counter with a random start and is stored in
      the table entry. Plan tables belong to the instance, cursor tables to
      the call, so a forged handle can at most name the caller's own
      objects; a stale or foreign one never matches.
    - *Typed parameters only for prepared statements.* `spi.execute` and
      `spi.open(sql, ...)` keep text parameters; binary parameters need
      declared types, which only `prepare` has. Results are typed
      everywhere (`Result.row`, cursor rows). Parameter types are the eight
      native kinds; `varchar`/`char(n)`/other types are passed as `.text`
      and cast in SQL. Result columns of type `varchar`/`bpchar` are kind
      `text`; domains (exact-OID matching, as for function arguments) and
      all other types are kind `other` (text representation). The guest
      also tags each parameter with its kind and the host requires it to
      equal the plan's parameter type (or 0 for NULL), so mismatches are
      reported, never converted; values must be in range for the type.
    - *`[]const u8` getter* accepts text, bytea and other (like function
      arguments, where bytea is `[]const u8` too); numeric getters require
      the exact column type (no widening). Column names are not exposed for
      cursor rows (cut: not needed for the requirements; `Result.columnName`
      still exists).
    - *Cursor commands refused in guest SQL* (new restriction, also for the
      existing `spi.execute`): `DECLARE` (incl. `WITH HOLD`), `FETCH`,
      `MOVE`, `CLOSE` are rejected on the raw parse tree before SPI sees
      the statement. Otherwise SQL could create cursors that outlive the
      call or close/advance portals of PL/Zig cursors. Code in other
      languages called from the guest can still run them; that is why
      PL/Zig's own portals are additionally **pinned** (`CLOSE ALL` in
      nested code fails with "cannot drop pinned portal") and looked up by
      name and pointer on every use (never a stale pointer).
    - *Plans are prepared with `CURSOR_OPT_NO_SCROLL`* (all PL/Zig cursors
      are forward-only, including those opened from a plan) and without
      `CURSOR_OPT_PARALLEL_OK` (no parallel query for prepared statements;
      conservative, can be revisited). Ad-hoc `spi.execute` is unchanged.
    - *Exhausted cursors*: the host closes the portal when `next` reaches
      the end; the SDK then frees the handle, so exhausted cursors do not
      count toward `plzig.max_open_cursors`. `next()` after `close()` is
      `error.CursorClosed`; `close()` is idempotent in the SDK.
    - *When plans are freed*: always in `plzig_instance_destroy()`. For a
      replaced or dropped function that is at the next PL/Zig call in the
      session (the existing invalidation sweep), and after a
      `plzig.max_memory` change at the next call of that function (existing
      instance retirement), not at the moment of the DDL/`SET`. On error the
      plans are freed while the portals of the failed call still exist
      (until the abort); this is safe because a portal holds its own
      reference to the cached plan and copies of the query string and
      parameters (verified by a test that frees a plan with its cursor
      open).
    - *Scratch memory*: per cursor, a guest buffer that grows to the
      largest row seen (bump arena: old buffers are reclaimed only if they
      are the most recent allocation, so worst case about twice the largest
      row); `Result.row` shares one buffer, valid until the next
      `Result.row`. `Plan.execute` encodes parameters on the guest stack and
      `spi.execute` frees its parameter array, so repeated executions do not
      grow the arena. Host side: a scratch context reset by every SPI
      import, a per-row context reset for every row. Verified in the
      regression suite with `pg_backend_memory_contexts` (100k cursor rows,
      10k prepared executions within one call, 5000 calls).
    - *Hostile-guest test*: user code cannot call imports directly, so
      `docker/security-checks.sh` uses a wrapper compiler
      (`docker/fake/hostilezig.c`, `plzig.compiler_sandbox = off` for that
      part only) that makes the SDK's import table public and calls every
      new import with forged pointers, lengths, handles, kinds and values
      (40 cases, each must be a clean `ERROR`).
    - Item 5 (benchmarks) is not part of this change.
24. **Phase B test layers (2026-11-14).** Implemented as §13 B describes,
    except:
    - *Isolation tests* cover what isolationtester can observe: it detects
      a blocked step only through heavyweight-lock waits, and a session
      waiting for the compile lock (`flock`) or inside a compilation is not
      in one.  Concurrent creation/replacement, `CREATE OR REPLACE`/`DROP`
      during a call and `plzig_cache_clear()` during a call are in
      `test/isolation`; compile-lock waits, cancelling them and
      `plzig_cache_clear()` during a compilation are TAP tests
      (`test/tap/t/020_compile_lock.pl`, `030_interrupts.pl`) driven by a
      test-only compiler wrapper (`test/gatezig.sh`, unconfined, used with
      `plzig.compiler_sandbox = off`) that holds a marked compilation at a
      gate until the test releases it.
    - *C unit helpers* (`plzig_test_*`) are compiled only with
      `make PLZIG_TESTING=1`, declared by `test/sql/testing.sql` itself and
      never by the extension script; the test image stages that build
      under `/opt/plzig-testing` and the security checks fail if the
      installed `plzig.so` exports any of them.
    - *SDK unit tests* run the production `zig/sdk/plzig.zig` and
      `root.zig` natively: under `zig test` (`builtin.is_test`), plzig.zig
      takes its host imports and wasm memory from a module
      `plzig_test_env` (`zig/sdk/test_env.zig`) instead of the wasm
      externs/builtins; a function build never has that module or
      `is_test`.  `root.zig`'s `decode`/`encode` became `pub` for the tests.
    - *aarch64* is parameterised (`PLZIG_PLATFORM`, Zig tarball by
      architecture) but not run.
    - *CI* configuration is not added (hosting not chosen).
25. **Fixes from the phase B tests (2026-11-14), behaviour changes:**
    - A parameter named `call` is rejected like `plzig` and `std` (it
      shadowed the generated `pub fn call` and failed with a compiler error
      about generated code at "line 0").
    - A NULL result of a domain type is passed through the domain's input
      function, so `NOT NULL` (and `CHECK`) constraints of the result
      domain are enforced for NULL too (they were skipped).
    - `log`/`raise`/`panic` messages longer than their limit are cut at a
      character boundary (cutting inside a multibyte character turned a
      valid message into an "invalid byte sequence" error, with the wrong
      SQLSTATE for `raise`).
    - `plzig-validate` accepts input of exactly its 4 MB buffer size (it
      refused one byte early; unreachable through `plzig.max_source_size`).
    - The SDK arena's size arithmetic cannot overflow (only possible on
      64-bit hosts, i.e. in the native unit tests; no change for wasm32).
    - Lowering `plzig.instance_cache_size` takes effect at the next call
      of any PL/Zig function: idle instances beyond the new size are
      destroyed then (before, only when another instance was cached, which
      with 0 never happens: the next call still used the old instance and
      its globals; `test/expected/lifecycle.out` changed from `4 | 1` to
      `1 | 1` accordingly).
    - Locals that are set inside `PG_TRY` and read after it are `volatile`
      (GCC `-Wclobbered` with `-Wextra`; no observed failure).
    - The SDK files changed (test seam, overflow-safe arena, `pub` in
      root.zig); their digest is part of the cache key, so every cached
      module is recompiled once on first use after the update.
26. **Phase C, security testing (2026-11-14).** Done as §13 C describes,
    with these results and differences:
    - *Threat model* written as `doc/security.md` (attackers A: role with
      `USAGE`; B: can write the module cache; C: compromised compiler in
      the sandbox), checked against the code, with a residual-risk list.
      Two points the plan did not anticipate: B is not really weaker than
      the `postgres` OS user (the cache is 0700), and a module planted by B
      under another function's key runs SQL with that function's
      privileges (sandboxed, but not harmless); and the compiler has no
      process-count, memory-cgroup or disk quota (operators are told to use
      cgroups and a separate `pg_wal` file system).
    - *Fuzzing* under `fuzz/`, one entry point `docker/run-fuzz.sh <target>
      <seconds>` (`smoke` runs every target), five targets: `validator`
      (Zig `-ffuzz` linked with libFuzzer; differential against an
      independent lexer and `std.zig.Ast`; Zig's own `zig build --fuzz` was
      not used: no time budget or exit status), `loader` (libFuzzer + ASan +
      UBSan on the unchanged `src/plzig_runtime.c` and WAMR in the
      production configuration, with stand-ins for the PostgreSQL services
      and host imports; structure-aware mutator; leak check of the runtime
      context), `hostabi` (a driver function compiled through
      `docker/fake/hostilezig.c` replays random byte scripts as host-import
      calls on the ASan server), `marshal` (round trips of 30 types, NULL
      patterns, random signatures through the validator and source
      generator) and `pipeline` (generated/mutated bodies through `CREATE
      FUNCTION`). Runs made, x86_64, PG 18.7: validator 1918 s × 8 jobs,
      34.5 M executions, no finding; loader 1922 s × 8 jobs, 34.0 M
      executions, 11 slow inputs (the finding below), then after the fix
      1869 s × 8 jobs, 50.8 M executions, no finding (line coverage of the
      replayed corpus: `plzig_runtime.c` 79 %, `wasm_loader.c` 87 %,
      `wasm_runtime.c` 53 %, `wasm_interp_classic.c` 53 %); the smoke
      runs then found finding 3 below; after the fixes 1865 s × 8
      jobs, 53.5 M executions, no finding; hostabi 660 s, 51 600 calls (these three SQL runs predate fixes 0 and 3, which do not touch their paths; their 60 s smoke runs after the fixes pass);
      marshal 660 s, 723 600 values, 36 180 signatures; pipeline 660 s, 521
      bodies; no other finding. Not done: 24-hour runs (documented in
      `fuzz/README.md` as a pre-release step), wasm-smith-generated modules,
      SQLsmith, CodeQL, aarch64.
    - *Findings and fixes* (all in `doc/security.md` §8):
      0. The module pre-check also refuses a module whose declared initial
         memory exceeds the upper bound of `plzig.max_memory` (1023 MB):
         it can never be instantiated. Regression test fake compiler
         mode 10.
      1. WAMR's loader and instantiation do work proportional to *declared*
         counts that need no bytes: a 30-byte module declaring 2^30 locals
         cost a production backend 1.4 s of uninterruptible CPU (past
         `statement_timeout`) and ~1 GB per load; a 17-byte module with a
         130-million-element table ~1 GB per instance. Reachable for B and
         C only. Fixed in PL/Zig, not WAMR: `plzig_module_precheck`
         (`src/plzig_runtime.c`) refuses functions with more than 65535
         locals (WAMR rejects those anyway, later) and tables with more
         than 1048576 elements before WAMR sees the module. Reproducers in
         `fuzz/loader/findings/`, regression tests in
         `docker/security-checks.sh` (fake compiler modes 8, 9).
      2. WAMR UBSan report "applying zero offset to null pointer" in
         `memory_instantiate` for a 0-page memory: harmless, reported and
         suppressed by name for the fuzz runs (`fuzz/loader/ubsan.supp`),
         like the known misaligned access in `tables_instantiate`.
      3. Undefined behaviour in `plzig_instance_call` (UBSan, loader
         target): the argument slots were written through a `PlzigSlot *`
         derived from the address the guest's `plzig_alloc` returned, which
         a hostile module can misalign. The copies were `memcpy` (no
         effect with GCC/Clang on x86_64/aarch64), but the pointer
         arithmetic is UB; now byte offsets. Reproducer
         `fuzz/loader/findings/plzig-misaligned-args.wasm`.
      4. Static analysis: `dirfd()` results used unchecked in
         `plzig_build.c` (scan-build; replaced by the descriptor already at
         hand, or checked), a dead initialisation (cppcheck), a cppcheck
         false positive suppressed inline in `plzig.c`.
      5. Hardening: `plzig-validate` was a static non-PIE executable; now
         built with `-fPIE` (static PIE, full RELRO; Makefile).
    - *Adversarial tests*: new regress test `test/sql/adversarial.sql`
      (comptime reflection reaching `std.Io` but nothing OS-facing
      compiling, private SDK declarations, import tricks, comptime loops,
      row-level security and column privileges through all three SPI paths
      including a kept plan re-checked after `SET ROLE`, definer/invoker
      nesting, refused identity changes in an unprivileged session,
      read-only transactions and data-modifying CTEs, an unprivileged
      user's view of error messages); `docker/security-checks.sh` gained
      the child's process state observed from inside the sandbox
      (rlimits, environment, descriptors, signals, no_new_privs, seccomp,
      parent-death signal, session, umask, cwd), Landlock refusing hard
      links to outside files and moves out of the build directory, a FIFO
      and a hard link to `postgresql.conf` as cache files, symbolic links in
      place of the compile lock, the Zig cache and a build directory, and
      the two pre-check cases; new `docker/diskfull-checks.sh` (data
      directory on a small tmpfs). Already covered and not duplicated: no
      `USAGE`, `SECURITY DEFINER`, STABLE/IMMUTABLE read-only, standby,
      fault injection (TAP).
    - *Static analysis* `docker/static-analysis.sh` (scan-build and cppcheck
      over `src/`, hardening of the installed binaries), every suppression
      justified in the script.
    - *Wiring*: `docker/run-all.sh` variants `fuzz` (smoke, 60 s per
      target), `static`, `diskfull`; `docker/run-tests.sh` unchanged except
      that its layers include the new regress and security checks.
    - *Changes to security-relevant code*: the module pre-check (above),
      the runtime allocator refuses an empty linear memory, byte-offset
      writes of the argument slots in `plzig_instance_call`,
      the two `dirfd` changes in the recursive delete and cache
      maintenance, `-fPIE` for the validator. No change to the sandbox
      policy, the validator tables, permission checks, GUC defaults or the
      ABI.
27. **Phase D, benchmark suite (2026-11-14).** `bench/` as §13 D describes
    (one command `bench/run.sh`, Docker only, correctness gate, CSV, report
    `doc/benchmarks.md` with SVG charts generated by `bench/report.py`).
    Differences and decisions:
    - *Languages*: SQL is a baseline where one is expressible; for task 6
      it is `levenshtein()` from contrib/fuzzystrmatch (C code), for tasks
      7 and 9 a set-based statement, not a loop. Task 7 has a second PL/Zig
      implementation (`spi.execute` without a prepared statement) to show
      what plan caching is worth. Task 2 has two variants (primes,
      Mandelbrot row) and task 10 two (text, bytea).
    - *Idioms that are not the obvious ones*, chosen so as not to measure
      a pitfall: PL/pgSQL string building appends to an array and joins
      once (`s := s || x` is quadratic); the bytea of task 5 and the values
      of task 10 are passed as in-memory values (`b || ''::bytea`), because
      PL/pgSQL keeps a TOASTed argument as a pointer in an atomic context
      (any function called from `SELECT`) and would fetch it again on
      every `get_byte()`; PL/Perl's task 5 uses `ord(substr())`
      (`unpack` is not available in trusted PL/Perl).
    - *Server settings* identical for all languages: `shared_buffers`
      512MB, `work_mem` 64MB, `max_parallel_workers_per_gather` 0 (single
      core per statement for every language), `autovacuum` off (data is
      vacuumed after loading), `synchronous_commit` off; PL/Zig GUCs at
      their defaults. JIT on/off is set per session.
    - *JIT*: besides off and on (server default thresholds, which only task
      1's PL statements exceed), a third mode `force` (all JIT thresholds 0)
      was run for tasks 1, 2 and 8 in a separate run, and every timed
      statement's EXPLAIN (cost, JIT yes/no) is recorded (`jit.csv`). JIT
      changed nothing measurable except slowing task 8's SQL baseline when
      forced.
    - *Runs published*: PG 18.7 full (15 timed runs, JIT off and on,
      pgbench at 1/2/4/8 clients), 14.25 and 19rc2 with JIT off, 10 runs,
      no pgbench; container pinned to the six performance cores. The
      `jit.csv` step was added while the cross-version run was in progress,
      so 19rc2 has one and 14.25 does not (no effect on timings).
    - *Task 11* measures `CREATE FUNCTION` and the first call separately
      (PL/Zig compiles in the validator, so the first call only loads the
      cached module); cold Zig cache = `pgsql_tmp.zig-cache` deleted before
      each run. *Task 12* uses `VmHWM` with a baseline taken after loading
      the language and reading the task's table once.
    - *Profiling*: `bench/run.sh --profile "QUERY"` (perf, user-space
      cycles, in the benchmark container run as root with
      `seccomp=unconfined` and SELinux labels disabled -- that mode only).
      `linux-perf` and `python3-psycopg2` are in the benchmark image only.
    - *Benchmark-only languages*: PL/Python and PL/Perl are installed only
      by `bench/Dockerfile`; `bench/` is excluded from the test images
      (`.dockerignore`), and `docker/security-checks.sh` checks that the
      test image has neither language nor `bench/`.
    - *Found by profiling and fixed* (SDK only, no host or ABI change):
      `plzig_alloc` used `Allocator.alignedAlloc`, which in ReleaseSafe
      first fills the block with 0xAA (`@memset(undefined)`); without
      bulk-memory instructions the interpreter does that byte by byte, about
      10 ns per byte. The host calls `plzig_alloc` for the argument block
      of every call and overwrites all of it, so this was the main cost of
      a trivial call (task 1: 0.77 -> 0.36 us per call) and of large
      arguments (task 10, 20 x 1 MB: text 262 -> 52 ms, bytea 225 -> 21 ms).
      It now uses `rawAlloc` (no fill). Contract unchanged (8-byte aligned,
      0 on failure); the SDK digest is part of the cache key, so modules are
      recompiled once. `test/expected/sandbox.out` changed only in
      `sdk/root.zig` line numbers of a compiler trace.
    - *§12 item 6 done*: `plzig_decode_result` copies `text` and `bytea`
      results from guest memory straight into the final varlena
      (`plzig_copy_out_varlena`: same pointer and size checks as
      `plzig_copy_out`) and runs `pg_verifymbstr` on that copy in place;
      SPI `text` parameters (`decode_text_params` for `spi.execute`/
      `spi.open`, `decode_typed_params` for prepared statements) go through
      the new `guest_text`, which has `guest_string`'s length check and
      validation but copies straight into a `text`. Validation rules
      unchanged (database encoding, no NUL), exactly one copy across the
      boundary, never aliasing guest memory. Unchanged because already a
      single copy: function arguments (detoast, then one copy into the
      guest), typed row values (detoast or output function, then one copy
      into the guest), `spi_value_copy`; results of `varchar`/`bpchar` and
      text-I/O types keep the NUL-terminated buffer their input function
      needs. Task 10 after the SDK fix and before/after item 6: text 52.0 ->
      44.2 ms, bytea 21.1 -> 12.2 ms (20 x 1 MB, medians, non-overlapping
      ranges). New regress cases in `test/sql/types.sql`: NUL as the last
      or only byte, multibyte characters cut at the end, 1 MB valid and
      invalid results, identity functions returning several values in one
      statement (no aliasing of the reused guest arena), and invalid/NUL
      text parameters through all three SPI paths.
    - *Not changed, recommendations in the report*: anything in the
      interpreter configuration (bulk-memory would make guest `memcpy`/
      `memset` single instructions), the ABI (one guest call per function
      call instead of three; one host call per cursor row instead of two),
      and the per-call memory contexts.
28. **Per-call/per-row overhead and §12 item 7 (2026-11-14).** Four
    changes on top of phase D, measured one after the other
    (`doc/benchmarks.md`, *Per-call and per-row overhead before and
    after*). SDK ABI version 3 (part of the cache key: every module is
    recompiled); the three ABI changes land together, so version 3 covers
    all of them.
    - *One guest entry per call* (the recommendation of phase D). New
      exports `plzig_init() -> i64` (called once per instance: the SDK's
      4 kB static argument buffer, outside the arena, as
      `capacity << 32 | address`) and `plzig_alloc_args(len)` (reset the
      arena and allocate the argument block: the fallback for larger
      arguments); `plzig_call` gets a fourth parameter `begin` (reset the
      arena first). `plzig_begin` and `plzig_alloc` are gone. The host
      checks the buffer at instantiation (16 bytes to 1 MB, inside linear
      memory, else the module is rejected) and the actual block range on
      every call; the exports must now have exactly the expected
      parameter and result types, not only counts. Task 1: 384 -> 256 ms.
      New hostile-guest tests ("hostile entry points" in
      `docker/security-checks.sh`: forged, wrapping, too small/large and
      misaligned buffers and blocks; `docker/fake/hostilezig.c` now also
      patches the SDK root for that); the loader fuzz harness calls once
      through the fallback path too.
    - *One host call per cursor row.* `spi_cursor_next` + `spi_cursor_read`
      became `spi_cursor_fetch(cursor, buf, buf_len)`: writes the row if it
      fits, else returns its size and keeps it current for the next call
      (taken from the portal once); returns `ncols << 32 | size`. The
      per-row `palloc`s of the column arrays are gone (allocated once per
      descriptor). 18 imports (19 again with item 7). Task 8:
      290 -> 217 ms. The hostile-guest cases that tested "no current
      row" and "row buffer is too small" on `spi_cursor_read` (24-28, 40)
      were rewritten for `spi_cursor_fetch`, whose too-small buffer is not
      an error any more (the cases now check that nothing is written and
      the same row comes again); "row buffer is too small" is still
      tested, through `spi_row_read` (new case 41).
    - *Call contexts reused.* The `PL/Zig call` and `PL/Zig SPI scratch`
      contexts belong to the instance (children of `PL/Zig runtime`),
      are reset at the start and end of each call and deleted with the
      instance; every exit from `plzig_instance_call` restores the
      caller's memory context, and `plzig_instance_destroy` never leaves
      `CurrentMemoryContext` in a deleted context. An idle instance keeps
      about 2 kB (the first block of each). An error stashed by a host
      import is copied into the caller's context instead of the call
      context: the instance is destroyed before the error is reported, and
      `ReThrowError` does not copy every string of an `ErrorData`
      (filename, funcname, domain, message_id stay where `CopyErrorData`
      put them) -- found by the ASan variant as a use after free in the
      first version of this change. Task 1: 253 -> 234 ms. New
      regress case in `leaks.sql` (a call using megabytes of host memory
      leaves nothing in the kept instance); the loader harness also
      refuses any context left below the runtime context.
    - *§12 item 7*, as specified: import `raise_error` (19 imports),
      `plzig.raiseError(.{ .sqlstate, .message, .detail, .hint })` and
      `plzig.raiseErrorFmt(fields, fmt, args)`; refused or malformed codes
      are `22023` errors naming the code; strings as for `raise` (64 kB
      each, cut on a character boundary, database encoding, no NUL), then
      control characters except newline and tab become `?` (the
      compiler-output rule); empty detail/hint are omitted. `plzig.raise`
      is unchanged (and keeps control characters). Tests:
      `test/sql/errors.sql`, hostile-guest cases 42-49, fuzz driver.
    - *Not done:* the same single-call scheme for `Result.row`
      (`spi_row_size` + `spi_row_read` stay two calls); the three
      optional items 9-11 of §12.
29. **§12 item 12, steps 1–4: native mappings for more built-in types
    (2026-11-15).** SDK ABI version 4 (part of the cache key: every module
    is recompiled once); two new host imports, `numeric_op` and
    `tz_convert` (21 in total); value kinds 10–19 (`doc/abi.md`, *Kinds*);
    no new GUC. Implemented as written, except:
    - *16-byte types out of line.* `interval` and `uuid` are 16 bytes and do
      not fit in the slot next to its flags, so they are passed like byte
      values (copied after the slots, `len` = 16, checked); everything else
      of step 1 is a raw value in `val` (`timetz`: time in `val`, zone in
      `len`, so `timetz` is mapped too). A 16-byte result is copied by the
      SDK to a static buffer outside the stack and the arena.
    - *Range checks* (`plzig_scalar_from_guest`, `src/plzig_types.c`) use
      PostgreSQL's macros as the receive functions do (`DATE_NOT_FINITE`,
      `IS_VALID_DATE`, `TIMESTAMP_NOT_FINITE`, `IS_VALID_TIMESTAMP`,
      `0..USECS_PER_DAY`, `TZDISP_LIMIT`) with their messages and SQLSTATEs
      (22008, 22009; `oid` > 2^32−1: 22003); `interval` and `uuid` accept
      every bit pattern (their receive functions do), only the length is
      checked. The same checks apply to prepared-statement parameters and to
      the value `tz_convert` converts.
    - *Typmods*: no typmod is applied to results, because PostgreSQL keeps
      none for function results (as for every language; tested against
      PL/pgSQL with `timestamp(0)`, `interval day`, `numeric(5,2)`).
      Domains over the new types stay text-I/O types (exact OID matching,
      as before), so a domain's typmod and constraints are applied by its
      input function; prepared-statement parameters have no typmod either
      (a column's typmod applies at `INSERT`, tested).
    - *numeric*: the host checks the wire length against `ndigits` before
      calling `numeric_recv` (its "insufficient data left in message" would
      carry the class-08 SQLSTATE `08P01`). Guest-side: inspection,
      `order`/`eql`, `toI64` (exact, never rounded), `toF64` (correctly
      rounded, overflow/underflow are errors as in PostgreSQL), `fromI64`,
      `fromF64` (15 significant digits of the *exact* binary value, half to
      even, as glibc's `%.15g` in `float8_numeric`; Zig's own precision
      formatting rounds the shortest representation instead, which differs
      on ties, so the SDK has a small exact digit generator), `parse`
      (numeric_in's decimal syntax; PostgreSQL 16's underscores and 0x/0o/0b
      forms are refused) and `toText`. Arithmetic set: add, sub, mul, div,
      divTrunc, mod, round(scale), trunc(scale), abs, neg -- one import,
      results written to a guest buffer if they fit, else `-len` and the
      guest calls again with a larger buffer (recomputed: no host-side
      state).
    - *Time zones*: one import with two operations (to local, from local),
      zone name or the session's `TimeZone`; calendar arithmetic
      (`Date.fromYmd/ymd/dayOfWeek/dayOfYear`, `Time.fromHms/hms`,
      `Timestamp.fromFields/fields/date/time`) is in the guest, a port of
      `date2j`/`j2date` with `make_date`/`make_time`/`make_timestamp`'s
      validation order, BC years negative as EXTRACT gives them. The SQL
      comparison caught an i64 overflow in an early `Timestamp.fromFields`
      (dates far beyond the timestamp range) before it was committed.
    - *jsonb*: argument and column values are the detoasted value's bytes
      (`VARDATA_ANY`, one copy); the reader returns `error.InvalidJsonb` for
      every malformed layout instead of trapping (the plan allowed traps):
      the unit tests walk every prefix and many byte flips of each fixture,
      and the native fuzz target treats any panic as a finding. jsonb
      *parameters* are added as kind 19 = JSON text through `jsonb_in`
      (useful, and as safe as results); results are `plzig.JsonText`. The
      serialiser (`toJsonText`) reproduces `jsonb_out` exactly (checked
      against `jsonb_out` by the regression test and differentially by the
      marshal fuzz target) and is iterative, so nesting depth never meets
      the guest stack. Big-endian hosts fall back to text by
      `#ifndef WORDS_BIGENDIAN` in `plzig_type_kind` (the only new
      conditional; no new `PG_VERSION_NUM` conditional).
    - *Existing behaviour that changed*: functions and prepared statements
      with arguments/results/columns of the ten types now get the native
      Zig types (a body that returned `numeric` or `date` as text does not
      compile any more; `Row.get([]const u8, col)` on such a column is
      `error.TypeMismatch`). Tests and README examples were updated;
      `types.sql`'s text-I/O cases now use types that stay text (`inet`,
      `daterange`, `bit varying`), `leaks.sql`'s text-I/O shape uses a
      domain over `numeric`.
    - *Tests*: `test/sql/types_fixed.sql`, `types_numeric.sql`,
      `types_calendar.sql`, `types_jsonb.sql` (also in the Valgrind list),
      new shapes in `leaks.sql` (numeric, time zones, jsonb results, a
      compressed out-of-line jsonb argument), 24 new hostile-guest cases in
      `docker/security-checks.sh` (50–73), SDK unit tests (byte fixtures
      from PostgreSQL), fuzz target `jsonb` (new) and extensions of
      `hostabi` (both new imports, every kind) and `marshal` (range-limit
      values, random jsonb documents, jsonb_out differential).
    - *Verification*: `docker/run-tests.sh` (six versions) and every
      `docker/run-all.sh` variant pass (coverage 89.5 % of lines); fuzz
      `jsonb` 1208 s × 8 (72.8 M executions), `marshal` and `hostabi` 600 s
      each, no finding (doc/security.md §9). Found on the way and fixed:
      the loader fuzz harness needed stand-ins for the new type helpers
      `plzig_runtime.c` now calls; PostgreSQL 14's `interval_in` refuses
      some extreme literals the newer versions take (test data changed,
      extremes built by the function instead).
    - *Benchmark*: task 13 (`bench/tasks/13_native_types`): numeric
      arithmetic loop, jsonb field extraction per row (binary and through
      the text representation of a domain over jsonb), timestamp column sum
      over a cursor. First measurement (superseded by Deviations 30),
      PostgreSQL 18.7, full size, JIT off, PL/Zig ÷ PL/pgSQL:
      timestamp sum 0.86× (17.7 / 20.6 ms, 100 000 rows); numeric loop 52×
      (1474 / 28.4 ms, 200 000 iterations: two host calls with
      `numeric_recv`/`numeric_send` per iteration); jsonb field 34× binary,
      41× through text (933 / 1128 / 27.5 ms, 100 000 rows). The published
      report was regenerated with the commands of bench/README.md (all
      tasks rerun on this tree; tasks 1–12 moved by at most a few percent).
30. **Hot-path cost of the native types (2026-11-15, follow-up to 29).**
    Task 13 showed numeric arithmetic at 52× and jsonb field extraction at
    34× PL/pgSQL's time. Profiling (perf on the benchmark backend, the
    compiled modules' assembly, micro-functions over 100 000 rows) found:
    - *Block-address cache misses in the interpreter* (25 % of all cycles in
      `wasm_loader_find_block_addr`): WAMR's classic interpreter finds the end
      of a block, when code branches out of it, in a 64-set two-way cache per
      execution environment and rescans the bytecode up to the block's end
      on a miss. Zig inlines the SDK into the user function's one large wasm
      function, so hot blocks evicted each other on every call; the cost
      depended on code layout (`numeric()` after `get()`: 7.7 µs per call;
      `toF64` after a code change: 32 µs). `BLOCK_ADDR_CACHE_SIZE=256` (a
      WAMR build define in `third_party/wamr/CMakeLists.txt`, no source
      change; about 9 kB more per execution environment) removes it: 256,
      1024 and 4096 sets measured the same.
    - *0xAA fills*: in ReleaseSafe `undefined` stack arrays and
      `Allocator.alloc` fill memory byte by byte (~10 ns per byte in the
      interpreter). Removed from the hot paths: numeric results are written
      by the host straight into arena memory taken with `rawAlloc` (64
      bytes, shrunk in place to the result; a larger one is computed again
      into a block of the reported size); `JsonNumber.toI64/toF64` read the
      on-disk digits in place (a shared digit view; no 256-byte buffer, no
      wire copy); `toF64` uses a static text buffer and an exact fast path
      (Clinger: mantissa <= 2^53, |exponent| <= 22), falling back to
      correctly rounded parsing; `Plan.execute/open` initialise their value
      arrays word by word and reserve 16-byte slots only for interval/uuid
      parameters; text results of `Result.get`, the parameter slots of
      `spi.execute` and cursor scratch growth use unfilled memory the host
      overwrites; the jsonb serialiser's numeric scratch is static.
    - *Object lookup*: objects of up to 16 keys are searched in one forward
      pass over the key entries (offsets accumulate, lengths compared first:
      the same result as the binary search for PostgreSQL's unique sorted
      keys); larger objects keep the binary search.
    - `toI64`'s overflow check no longer needs compiler-rt's 128-bit
      `__multi3`.
    Task 13 (full run, PostgreSQL 18.7, JIT off, PL/Zig ÷ PL/pgSQL): jsonb
    field 34× → 5.0× (933 → 144 ms), numeric loop 52× → 9.9× (1474 → 287
    ms), timestamp sum 0.86× → 0.87×; tasks 1–12 within run-to-run noise.
    The published report was regenerated (bench/README.md commands).
    Measured (100 000 rows, per call, PostgreSQL 18.7): `get("qty")` 1.2 →
    0.6 µs; `get` + `numeric()` 9.2 → 1.4 µs; `get` + `toI64()` 4.8 → 1.5 µs;
    `get` + `toF64()` 6–32 → 2.1 µs; numeric add 3.1 → 0.44 µs. Not done:
    a small inline representation for `Numeric` (`wire` is a public slice
    field, so inline digits would make the struct self-referential and
    break on every copy; results are now exactly sized, 10–20 bytes each,
    and the arena is reset per call). New SDK unit test: the `toF64` fast
    path against correctly rounded parsing (20 000 random values); the
    jsonb fuzz target now also requires the in-place conversions to agree
    with the wire-format ones. A test-harness bug was fixed on the way
    (`row()` in `zig/sdk/test.zig` left `env.rows` pointing at a temporary).
    The loader fuzz seeds (`fuzz/loader/corpus`) were regenerated for ABI 4
    (they were still ABI-3 modules, rejected before execution).
    Verification: six-version matrix and every `docker/run-all.sh` variant
    pass (coverage 89.5 %); fuzz smoke on a freshly built image passes;
    jsonb 1209 s × 8 (66.8 M executions) no finding. One `pipeline` smoke
    run reported SQLSTATE 38000 for a generated `DO` block containing
    `@panic("p")`: the target accepts 38000 for calls but not for `DO`,
    which also runs its body -- an oracle gap unrelated to this change,
    left as it is for the owner (replay: `perl fuzz/pipeline/gen.pl
    690590262 50 fuzz/validator/corpus <dir>`, body 00030.zig).
