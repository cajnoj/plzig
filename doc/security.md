# PL/Zig security model

This document states what PL/Zig defends, against whom, how, what each
defence relies on, and what remains open. It describes the code as it is
(checked against `src/`, `zig/`, `third_party/` and the test suites); where a
statement is an inference rather than something a test demonstrates, it says
so. README.md, section *Security model*, is the operator-facing summary;
`doc/abi.md` specifies the host/guest interface.

The project rule is **security over functionality**: nothing PL/Zig does may
put data integrity at risk or bypass PostgreSQL's permission system.

## 1. Assets

1. **Other users' data** and the integrity of the database: tables, catalogs,
   WAL, other sessions' memory, and the privileges that protect them.
2. **The server's operating-system account** (`postgres`): everything it can
   read or write — the data directory, `postgresql.conf`, other clusters,
   credentials in its home directory — and the processes it runs.
3. **Availability** of the cluster: backends, the postmaster, disk space,
   memory and CPU shared by all users.
4. **Integrity of other users' PL/Zig functions**: the compiled module of a
   function must be the result of compiling that function's source.

## 2. Attackers

| | Attacker | Capabilities assumed |
|---|---|---|
| **A** | A database role with `USAGE` on `plzig` and nothing else (the main attacker) | Can create PL/Zig functions and `DO` blocks with arbitrary source, choose their signatures, call them with arbitrary arguments, run arbitrary SQL its own privileges allow, and keep sessions open. Can read every function's source (`pg_proc.prosrc` is readable by all). Cannot change `postgresql.conf`, superuser settings, or files. |
| **B** | Someone who can write `$PGDATA/plzig/cache` (weaker assumption) | Can plant, replace or remove module files there: arbitrary bytes, symbolic and hard links, FIFOs, directories. Used to test the claim that a poisoned module stays inside the WebAssembly sandbox. |
| **C** | A compromised compiler: code execution inside the confined compiler process | What attacker A gets if a source file exploits a bug in the Zig compiler (or in `plzig-validate`), or if the compiler binary itself is malicious. Runs arbitrary native code as the server's OS user, inside the child-process confinement (§4.8). |

Out of scope: superusers (they can already do anything, including
`LANGUAGE c`), the `postgres` OS user and root, and whoever administers the
Zig installation (`plzig.zig_path` must point at a toolchain the
administrator trusts; §4.10 lists what PL/Zig checks anyway).

Note on B: the cache directory is `0700` and owned by the server user, so in
a correctly configured system only the `postgres` OS user (or root) can
write it — and they can already write the whole data directory. B is
therefore not a realistic *weaker* attacker; it is a test assumption for the
module loader, and §6.2 spells out what B can achieve.

## 3. Trust boundaries

```
 client SQL ──► backend (trusted C: plzig.so + WAMR)
                 │   ├── guest module (untrusted Wasm code, in-process,
                 │   │     interpreted by WAMR; reaches the backend only
                 │   │     through 21 host imports)              ◄── boundary 1
                 │   ├── $PGDATA/plzig/cache/*.wasm (B can write; every
                 │   │     file is re-validated when loaded)      ◄── boundary 2
                 │   └── fork + execve
                 │         └── plzig-validate, zig (untrusted input,
                 │               confined child processes)        ◄── boundary 3
                 └── SPI ──► executor, with the current user's privileges
                                                                  ◄── boundary 4
```

1. **Guest ↔ backend**: guest code is a WebAssembly module run by the
   interpreter inside the backend process. It has its own linear memory and
   no system calls; it can call only the host imports (`doc/abi.md`).
2. **Module file ↔ loader**: a module read from the cache is treated as
   hostile input: WAMR validates it, PL/Zig checks imports, exports and the
   ABI version, every time it is loaded.
3. **Compiler ↔ backend**: user source is compiled in a separate process
   with resource limits, a clean environment, Landlock and a seccomp filter;
   the backend only reads its output file and its (sanitised) messages.
4. **SQL**: guest SQL runs through SPI as the current user, under the
   normal permission checks, row-level security and read-only rules.

## 4. Defences

Each item says what it does, where it is implemented, what it relies on,
and how it is tested.

### 4.1 Language privilege

* `CREATE TRUSTED LANGUAGE plzig ...; REVOKE USAGE ON LANGUAGE plzig FROM
  PUBLIC;` (`sql/plzig--1.0.sql`). Without `USAGE` a role can create no
  function and run no `DO` block. The extension itself requires a superuser
  to install (`superuser = true`, `trusted = false` in `plzig.control`).
* `plzig_sandbox_status()` and `plzig_cache_clear()` have `EXECUTE` revoked
  from `PUBLIC`.
* The validator honours `CheckFunctionValidatorAccess` and
  `check_function_bodies` (`plzig_validator`, `src/plzig.c`); signature
  checks always run.
* The toolchain and sandbox settings are `PGC_SIGHUP` with
  `GUC_DISALLOW_IN_AUTO_FILE`, the toolchain paths `GUC_SUPERUSER_ONLY`; all
  other settings are `PGC_SUSET` (`_PG_init`). The prefix is reserved, so
  placeholders set by ordinary users are not applied when the library loads.
* Tests: `test/sql/setup.sql` (USAGE, EXECUTE, every GUC from an ordinary
  role, `ALTER SYSTEM`/`ALTER ROLE`/`ALTER DATABASE`, placeholders).

### 4.2 Lexical policy (`plzig-validate`)

* Before compiling, `zig/validate/main.zig` tokenises the generated source
  with Zig 0.17.1's own `std.zig.Tokenizer` and rejects: any builtin not on
  an allowlist (`@embedFile`, `@extern`, `@export`, `@ptrFromInt`,
  `@ptrCast`, `@intFromPtr`, `@setEvalBranchQuota`, `@wasmMemoryGrow`,
  atomics, ... — the full lists are in the file), `@import` other than the
  exact token sequence `@import ( "plzig" )`, the keywords `extern`,
  `export`, `asm`, `linksection`, `callconv`, `threadlocal`, `addrspace`,
  `volatile`, invalid tokens and NUL bytes. Inputs over 4 MB are refused.
* It relies on the compiler being exactly Zig 0.17.1 (the backend runs
  `zig version` and refuses anything else, §4.10): a different tokenizer
  could see different tokens.
* It is **defence in depth, not the boundary**: the curated `plzig.std`
  is a convenience (§4.3), and the structural defences are the target
  (§4.4) and the loader (§4.5).
* Tests: `zig/validate/test.zig` (every builtin of 0.17.1 classified, every
  keyword, lexical corner cases), `test/sql/sandbox.sql` and
  `test/sql/adversarial.sql` (rejections at `CREATE`), fuzz target
  `validator` (§7) with a differential check against an independent lexer
  and the real parser.

### 4.3 Curated `std` — not a boundary

`plzig.std` re-exports 25 pure-computation namespaces of `std`
(`zig/sdk/plzig.zig`). It does not stop comptime reflection: from a
parameter type of a curated function, `@typeInfo`/`@FieldType` reach
`std.Io.Writer`, `std.Io.File.Reader` and from there the whole `std.Io`
namespace (`Threaded`, `Dir`, `net`, ...). `test/sql/adversarial.sql`
demonstrates this, and that using any of it to open a file or a socket does
not compile: on `wasm32-freestanding` the OS layer (`std.posix.system`) is
empty. Private SDK declarations (the host import table) cannot be named
(`adversarial.sql`). This is why the boundary is §4.4–§4.6, not the
curation.

### 4.4 Compilation target

Every function is compiled as `wasm32-freestanding`, CPU `mvp`,
`ReleaseSafe`, single-threaded, no entry point, with a fixed 256 kB guest
stack and exactly four exports (`plzig_zig_flags`, `src/plzig_build.c`).
There is no operating system to call; an `extern` function that is
referenced anyway becomes a WebAssembly import, which the loader refuses.
Zig's runtime safety checks (overflow, bounds, null, `unreachable`) are on
and end in the SDK's panic handler, i.e. a clean `ERROR`.

### 4.5 Module loader

`plzig_module_load` (`src/plzig_runtime.c`), for every module, whether
freshly compiled or read from the cache:

* size between 8 bytes and 16 MB (`PLZIG_MAX_WASM_SIZE`);
* no linear memory declaring more than 1023 MB (the upper bound of
  `plzig.max_memory`), no function declaring more than 65535 locals and no
  table of more than 1048576 elements (`plzig_module_precheck`): the first
  can never be instantiated, and a module of a few bytes can otherwise make
  WAMR allocate about 1 GB and, for the locals, spend seconds of
  uninterruptible CPU.
  None of these can be part of a module that works under PL/Zig (memory
  is capped at 1023 MB, WAMR rejects more than 65535 locals anyway, the
  table limit is far above what a Zig module needs);
* full WAMR validation (`wasm_runtime_load`);
* every import must be a *function* from module `plzig`, one of the 21
  known names, and linked by WAMR (signature equal to the registered one);
* a trial instantiation under `plzig.max_memory`, the four exports with
  exactly the right parameter/result types, a linear memory,
  `plzig_abi_version() == 4`, and an argument buffer from `plzig_init()`
  of 16 bytes to 1 MB inside the linear memory (re-validated on every call
  with the actual argument size; `doc/abi.md`).

Cache files are opened with `O_NOFOLLOW | O_NONBLOCK` and must be regular
files owned by the server user with mode `0600` (`plzig_read_file`,
`src/plzig_build.c`). Tests: `docker/security-checks.sh` (fake compilers
producing each kind of forbidden import; symlinked, FIFO, hard-linked and
wrong-mode cache files), `test/tap/t/060_environment.pl`, fuzz target
`loader` (§7).

### 4.6 Interpreter

* WAMR 2.4.5 (pinned commit), **classic interpreter only**, built with
  every optional feature off (AOT/JIT, WASI, libc, threads, shared memory,
  multi-module, GC, memory64, SIMD, reference types, bulk memory, tail
  calls, exception handling; `third_party/wamr/CMakeLists.txt`) and
  software bounds checks (`WAMR_DISABLE_HW_BOUND_CHECK`), and a block
  address cache of 256 sets instead of 64 (`BLOCK_ADDR_CACHE_SIZE`, a
  performance setting: more memory per execution environment, no change to
  what is accepted or executed), so it installs
  no signal handlers and creates no threads. After initialising it the
  backend compares every signal disposition and its thread count with a
  snapshot and exits with `FATAL` on any difference
  (`plzig_runtime_init`).
* All runtime memory, including linear memory, comes from the "PL/Zig
  runtime" memory context with `MCXT_ALLOC_NO_OOM`; linear memory is capped
  at `plzig.max_memory` in that allocator (WAMR alone does not enforce the
  cap below a module's initial size).
* Endless guest loops: `third_party/wamr-interrupt.patch` makes the
  interpreter poll `QueryCancelPending`/`ProcDiePending` at every branch,
  call and function entry and trap; the host then runs
  `CHECK_FOR_INTERRUPTS()`. So `statement_timeout`, cancel and
  `pg_terminate_backend` work (TAP `030_interrupts.pl`).
* `check_stack_depth()` before every guest call; the interpreter's own
  stack is fixed (512 kB, `PLZIG_WASM_STACK`); guest stack overflow traps.
* An instance that trapped or raised an error is destroyed, with its
  prepared statements (`plzig_function_execute`, `src/plzig.c`).

### 4.7 Host imports

`src/plzig_host.c`, specified in `doc/abi.md`:

* every guest pointer/length is checked with
  `wasm_runtime_validate_app_addr` before use, sizes are computed in 64 bits
  or bounded first, data is copied out, and no native pointer into guest
  memory is kept across anything that could run guest code;
* errors never `longjmp` through interpreter frames: each import runs in
  `PG_TRY`, stashes the `ErrorData`, sets a WAMR exception, and the call
  handler re-throws after the interpreter has unwound; once an error is
  stashed every further import traps;
* plan and cursor handles are `serial << 16 | index` into tables owned by
  the calling instance (plans) or the current call (cursors), checked on
  every use;
* SQL runs through SPI as the current user: permission checks, row-level
  security, column privileges and `SECURITY DEFINER` behave as in PL/pgSQL;
  SPI is read-only unless the function is `VOLATILE` (decided at every
  execution); `DECLARE`/`FETCH`/`MOVE`/`CLOSE` are refused on the raw parse
  tree; PL/Zig's own portals are pinned; no transaction control;
* text crossing the boundary is checked for the database encoding and NUL
  bytes; `log`/`raise`/`raise_error`/`panic` messages are length-capped;
  `raise_error` raises only `ERROR`, with a well-formed SQLSTATE outside
  the classes a server condition uses (`00`, `01`, `02`, `08`, `53`, `57`,
  `58`, `F0`, `XX`), so a function cannot make its failure look like a
  connection loss, a shutdown or an internal error;
* **values of the natively mapped types** (`doc/abi.md`, *Range checks*,
  *numeric*, *jsonb*) that come back from a guest -- a function result, a
  prepared-statement parameter, an operand of `numeric_op`, the value
  `tz_convert` converts -- are never stored as the guest built them:
  `date`, `time`, `timetz`, `timestamp`, `timestamptz` and `oid` are
  range-checked with PostgreSQL's own macros as the types' receive
  functions do (`plzig_scalar_from_guest`), so no value outside what
  PostgreSQL itself can produce reaches a table or an index; `interval` and
  `uuid` must be exactly 16 bytes (every bit pattern is a valid value);
  `numeric` must have exactly the length its header announces and then goes
  through `numeric_recv`, the server's validating input path
  (`plzig_numeric_from_wire`); `jsonb` is accepted only as JSON text and
  parsed by `jsonb_in` -- a binary jsonb from a guest would be stored
  unchecked, so there is no way to pass one; a domain over any of these
  types is passed as text through the domain's input function, so its
  constraints and typmod apply;
* the two value imports call PostgreSQL's own functions on validated
  copies: `numeric_op` (`numeric_add` ... `numeric_uminus`; results are
  PostgreSQL's exactly, errors are ordinary SQL errors) and `tz_convert`
  (`timestamptz_zone` and friends; the guest sees neither the time zone
  database nor `TimeZone` itself, only what the equivalent SQL returns, and
  there is still no clock); their results are copied out only if the
  guest's buffer is large enough (validated range), else only the size is
  returned;
* arguments and columns of these types carry no host data beyond the value
  itself: fixed-width values are passed by value, `numeric` as
  `numeric_send` output, `jsonb` as the detoasted value's bytes (one copy,
  never a host pointer).

Tests: `test/sql/spi*.sql`, `test/sql/adversarial.sql` (row-level security
and column privileges through `spi.execute`, prepared statements and
cursors; a kept plan re-checked after `SET ROLE`; definer/invoker nesting;
refused identity changes; read-only transactions and data-modifying CTEs),
`docker/security-checks.sh` (73 hostile-guest calls, among them forged
fixed-width, numeric and jsonb parameters and forged `numeric_op` and
`tz_convert` calls; forged argument buffers), `test/sql/types_fixed.sql`,
`types_numeric.sql`, `types_calendar.sql`, `types_jsonb.sql` (every range
limit, malformed numerics as results and parameters), fuzz targets
`hostabi`, `marshal` and `jsonb` (§7), TAP `040_standby.pl` (read-only on a
standby).

### 4.8 The compiler process

`src/plzig_spawn.c`, `src/plzig_sandbox.c`, `src/plzig_build.c`. Each child
(`zig version`, `plzig-validate`, `zig build-exe`) is started with
`fork` + `execve` and a fixed argv (no shell; user text is never on a
command line or in a path), and before `execve`:

* default dispositions for all signals and an empty mask; `setsid` (own
  session and process group); `PR_SET_PDEATHSIG = SIGKILL`;
* stdin from `/dev/null` (or the source file for the validator),
  stdout/stderr to a pipe, every other descriptor closed;
* working directory = the private build directory, `umask 077`;
* environment built from scratch: `PATH=/usr/bin:/bin`, `HOME` and `TMPDIR`
  = build directory, `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`,
  `LC_ALL=C`, `NO_COLOR=1`;
* rlimits: `RLIMIT_CORE` 0, `RLIMIT_FSIZE` 256 MB, `RLIMIT_AS`
  `plzig.compile_memory_limit` (default 4 GB), `RLIMIT_CPU` a backstop
  derived from the timeout and the CPU count;
* `PR_SET_NO_NEW_PRIVS`;
* **Landlock** (rules by ABI version, all paths resolved by the backend):
  execute+read on the compiler binary and on `plzig-validate` (file rules,
  not their directories); read on the Zig lib directory; read/write
  (create/remove files and directories, truncate, cross-directory rename;
  no symbolic links, sockets, FIFOs or devices) on the build directory and
  the shared Zig cache; read/write on `/dev/null`; nothing else. From
  ABI 4 TCP bind/connect are handled with no rule (denied), from ABI 6
  signals to and abstract UNIX sockets of processes outside the domain are
  scoped away, ABI 9 pathname UNIX sockets, ABI 10 UDP;
* a **seccomp-bpf** deny filter, installed last (x86_64 and aarch64; foreign
  architectures and x32 denied): all socket calls, `ptrace`,
  `process_vm_*`, `kcmp`, `pidfd_*`, `setsid`/`setpgid`, System V IPC,
  mounts and namespaces, `unshare`/`setns`, `clone` with namespace flags or
  `CLONE_PARENT`, `clone3` (→ `ENOSYS`), `bpf`, `perf_event_open`,
  `io_uring_*`, `userfaultfd`, keyrings, `kexec_*`, module loading,
  `open_by_handle_at`, `personality`, `fcntl(F_SETOWN/F_SETOWN_EX/F_SETSIG)`;
  `kill`/`tkill`/`tgkill`/`rt_(tg)sigqueueinfo` only towards the child's
  own pid.

The parent waits with `WaitLatchOrSocket`, enforces
`plzig.compile_timeout`, keeps at most 64 kB of output, and on every exit
path (normal, timeout, cancel, `ERROR`, `FATAL`/exit callback) kills the
whole process group and reaps the child. Compilations are serialised
cluster-wide with a `flock` on `$PGDATA/plzig/compile.lock`.

`plzig.compiler_sandbox = require` (the default) refuses to compile unless
Landlock ABI **6 or later** and the seccomp filter are available; `try`
applies what is available and logs what is missing; `off` applies neither.
Landlock ABI versions and the Linux release that introduced them: 1 — 5.13,
2 — 5.19, 3 — 6.2, 4 — 6.7, 5 — 6.10, 6 — 6.12; ABIs 7 to 10 come with
later kernels (the 7.2 kernel the suite was last run on reports ABI 10).
`require` therefore needs **Linux 6.12 or later**, Landlock enabled in the
kernel's LSM list, `CONFIG_SECCOMP_FILTER`, and a container runtime that
lets the server use both.

Tests: `docker/security-checks.sh` mode 5 of `docker/fake/fakezig.c`
observes, from inside the confined child, every item above that a process
can see (limits, environment, descriptors, signal state, no_new_privs,
seccomp mode 2, parent-death signal, session, umask, working directory) and
tries what must fail (files outside, writing the cache or lib directory,
executing other programs, symbolic links, hard links to files outside,
moving entries out, TCP/UDP/UNIX sockets, signalling the parent, `ptrace`,
System V IPC, `setsid`/`setpgid`); `docker/no-landlock-checks.sh` and
`docker/no-seccomp-checks.sh` (refusal under `require`, what remains under
`try`); TAP `010_crash_recovery.pl`, `020_compile_lock.pl`,
`030_interrupts.pl` (cancel, timeout and backend death during compiles).

### 4.9 Files and directories

* Everything lives in `$PGDATA/plzig/` (fixed, not configurable): `cache/`,
  `pgsql_tmp.zig-cache/` (skipped by base backups), `compile.lock`, and
  short-lived `pgsql_tmp.build.<pid>.<n>.<random>/` directories. Each
  directory is `lstat`ed before use and must be a real directory owned by
  the server user with no group/other bits (`plzig_ensure_private_dir`).
* No path component comes from user input (pids, counters, random hex,
  SHA-256 digests). The cache key is SHA-256 over length-prefixed parts:
  ABI version, Zig version, compiler flags, SDK digest, generated source.
* Modules are written to `<key>.wasm.tmp.<pid>` with
  `O_CREAT | O_EXCL | O_NOFOLLOW`, fsynced and renamed with
  `durable_rename`; the temp file is removed on every failure.
* Build directories are removed with a descriptor-relative walk
  (`openat(O_NOFOLLOW | O_DIRECTORY)`, same `st_dev`, `unlinkat`, depth ≤ 64)
  that never follows a symbolic link or crosses into another file system;
  leftovers are swept by the next compilation under the compile lock.
* Cache maintenance touches only regular files directly in `cache/` whose
  names match the cache patterns; eviction and `plzig_cache_clear()`
  unlink names, never follow them.
* Tests: `docker/security-checks.sh` (planted symbolic links and a 50-level
  tree in a build directory, symbolic links in place of the compile lock,
  the Zig cache and a build directory, FIFO and hard link as cache files,
  foreign entries during eviction), TAP `060_environment.pl` (cache
  directory deleted, read-only, replaced by a file or a link),
  `docker/diskfull-checks.sh` (§4.12), the leak layer (nothing left in
  `$PGDATA/plzig` after a full run).

### 4.10 Toolchain checks

`plzig_check_toolchain` (`src/plzig_build.c`): `plzig.zig_path` must be set
and absolute (`PATH` is never searched) and is resolved with `realpath`;
the binary, the lib directory and every ancestor directory must be owned by
root or the server user and not group/other writable (sticky directories
accepted above the immediate parent); neither may be inside or contain the
data directory; optional SHA-256 pin of the binary (`plzig.zig_sha256`);
under Landlock a dynamically linked or `#!` compiler is refused; `zig
version` must report exactly 0.17.1. Path and permission checks run before
every compilation; the hash and version check are repeated when a setting
or the identity of the binary or lib directory changes. Tests:
`docker/security-checks.sh` ("toolchain checks").

### 4.11 Messages

Messages that can reach a client show paths under the data directory
relative to it; full paths go to the server log (`errdetail_log`).
Compiler output has the build directory, the Zig cache, the data directory
and the Zig lib directory replaced (`<zig lib>/`), control characters and
DEL replaced by `?`, non-ASCII replaced if the result is not valid in the
database encoding, and continuation lines indented so that nothing can
pose as a server message (`plzig_format_output`). Toolchain paths appear
in error details only for superusers. Tests: `test/sql/sandbox.sql`
(forged output), `test/sql/adversarial.sql` (an unprivileged user's view of
compile errors inside `std` and the SDK, policy rejections, panics and
traps: no data directory, no build directory, no Zig installation path),
`docker/security-checks.sh` ("messages to unprivileged users").

### 4.12 Resource limits

* Compile time: `plzig.compile_timeout` per child (default 30 s), CPU and
  address-space rlimits, one compilation at a time cluster-wide.
* Disk: `plzig.max_source_size` (≤ 3 MB), `plzig.max_module_size` (default
  2 MB), `plzig.cache_size_limit` with LRU eviction (default 256 MB),
  `RLIMIT_FSIZE` 256 MB per file written by the compiler; build directories
  are removed after every compilation. A compilation that runs out of
  space ends in an `ERROR` and leaves nothing behind
  (`docker/diskfull-checks.sh`, run on a small tmpfs).
* Runtime: linear memory per instance (`plzig.max_memory`), idle instances
  (`plzig.instance_cache_size`, `plzig.instance_cache_max_memory`), plans
  per instance and cursors per call, `statement_timeout`.

## 5. Attacker A: what a role with `USAGE` can do

* **Run code in the backend**: only as WebAssembly in the interpreter
  (§4.4–§4.6). Escaping requires a bug in WAMR's validator or interpreter,
  or in a host import (§8, items 4 and 5).
* **Run SQL**: only with its own privileges, or those of a `SECURITY
  DEFINER` function's owner — exactly as with PL/pgSQL (§4.7).
* **Run the compiler on chosen input**: yes; that is what `USAGE` grants,
  and why it is not granted to `PUBLIC`. The compiler is confined (§4.8);
  a compiler exploit makes A into attacker C.
* **Read server files through the compiler** (`@embedFile`, `@import` of
  paths): refused lexically (§4.2) and, structurally, by Landlock (the
  compiler can read only its lib directory, the build directory and the
  Zig cache).
* **Learn paths**: the data directory and the Zig installation path are not
  shown (§4.11); the guest can learn the name of its own source file
  (`user.zig`).
* **Consume resources**: compile time (bounded by the timeout, one at a
  time — so A can keep the compiler busy for everybody), backend memory and
  CPU within `statement_timeout` and the per-instance caps (like PL/pgSQL),
  cache space (bounded by `plzig.cache_size_limit`), server log volume
  (`plzig.print(.log, ...)`, like `RAISE LOG`).

## 6. Attackers B and C

### 6.1 C — a compromised compiler

It runs as the server's OS user, confined as in §4.8. With `require`
enforced it **cannot**: read or write the data directory outside its build
directory and the Zig cache (in particular not the module cache, the
catalog or `postgresql.conf`), execute any program but the compiler and the
validator, create symbolic links, hard-link files from outside, open any
socket, signal or trace processes outside its sandbox, leave the process
group the backend kills, or survive its backend. It **can**: read the Zig
lib directory; read and write the shared Zig cache (§8 item 1); learn its
build directory path; use CPU, memory and disk up to the limits (§8 items
6 and 7); fork and re-execute itself; return any output — which the backend
treats as hostile: the module goes through the loader (§4.5) and runs
sandboxed (§4.6), and the messages are sanitised (§4.11).

### 6.2 B — a cache writer

A planted module is validated like any other (§4.5) and runs inside the
interpreter, so B gains **no code execution in the backend** unless WAMR
or a host import has a bug; malformed files, links and FIFOs are refused
(§4.5, §4.9). But a module is trusted to *be* the function whose key it
carries: a module planted under the key of an existing function (the key
is computable from public information, `pg_proc.prosrc`) runs in that
function's place, so its SQL runs **with the privileges of that function's
callers — or of its owner, for `SECURITY DEFINER` functions**. Cache
integrity is therefore relied upon for the integrity of PL/Zig functions
(asset 4) and, through SPI, for data (asset 1). This is acceptable only
because the cache is writable by nobody but the server's OS user (§2).

## 7. Testing summary

* Deterministic: `test/sql` (pg_regress), `test/isolation`, `test/tap`,
  `docker/security-checks.sh`, `docker/no-landlock-checks.sh`,
  `docker/no-seccomp-checks.sh`, `docker/leak-checks.sh`,
  `docker/diskfull-checks.sh`; with sanitizers, Valgrind and an
  assertion-enabled server in `docker/run-all.sh`.
* Fuzzing (`fuzz/README.md`, `docker/run-fuzz.sh`): the validator
  (differential), the module loader (ASan/UBSan, the production runtime
  code), the host-import ABI on a live ASan server, marshalling and the
  source generator (property tests, including the guest's jsonb
  serialisation against `jsonb_out`), the SDK's jsonb reader and numeric
  decoders on mutated PostgreSQL-produced bytes, and the whole pipeline.
  Results of the runs made for this document are in §9.
* Static analysis (`docker/static-analysis.sh`): the clang static analyzer
  and cppcheck over `src/`, and the hardening of the installed binaries
  (RELRO/BIND_NOW, no executable stack, no text relocations, PIE for the
  validator, stack protector and `_FORTIFY_SOURCE` as `pg_config` asks).

## 8. Residual risks

1. **The shared Zig cache can be poisoned by a compromised compiler.** All
   compilations share `$PGDATA/plzig/pgsql_tmp.zig-cache` (the compiled
   standard library and `compiler_rt`). Attacker C can modify it, and
   thereby alter modules later compiled for *other* users' functions,
   including `SECURITY DEFINER` ones. The result is still a sandboxed
   module, but one that runs SQL with the victim function's privileges
   (as in §6.2). Treat `USAGE` as "may run the compiler". Mitigations not
   implemented: a per-compilation global cache (costs a cold compile, about
   3 s, every time), or a read-only, pre-built cache.
2. **Check-to-exec window on the compiler binary.** The toolchain checks
   (§4.10) run before `execve`; a change of the binary between the check
   and the `execve` is not detected. Only root or the server's OS user can
   make that change, and they are out of scope. The SHA-256 pin covers the
   binary, not `lib/`.
3. **`require` needs Landlock ABI 6 (Linux 6.12).** On older kernels, or
   where Landlock or seccomp filters are unavailable (container profiles,
   other architectures), the default refuses to compile; `try` compiles
   with whatever is available. Below ABI 3, `truncate(2)` by path is not
   mediated (a compromised compiler could truncate any file of the server
   user); without Landlock the compiler has no filesystem confinement at
   all; without seccomp, Landlock below ABI 9/10 leaves pathname UNIX
   sockets (the server's own socket) and UDP open.
4. **WAMR is a large C code base inside the backend.** A bug in its loader,
   validator or interpreter reachable from a module would be a sandbox
   escape into the backend. The build disables every optional feature, the
   loader target fuzzes the production load path (§9), and the
   interpreter is patched in one place only.

   Loading is not interruptible:
   WAMR's loader never checks for interrupts, so its cost per module must
   stay bounded by the module's size. The loader target found one place
   where it was not, and review of the same pattern found a second (both
   mitigated in PL/Zig, not in WAMR; reachable for B — any cache file — and
   C — the backend load-validates the compiler's output — not for A):
   * *Declared locals*: `load_function_section` allocates
     `sizeof(WASMFunction) + local_count` bytes, zeroed, and walks every
     local twice before rejecting a function with more than 65535 local
     cells. A 30-byte module declaring 0x3ff00000 locals made a production
     backend spend 1.4 s (past a 1 s `statement_timeout`) and allocate about
     1 GB on every load attempt.
   * *Table size*: `tables_instantiate` allocates and fills up to twice the
     declared initial size; a 17-byte module declaring 0x07c00000 elements
     costs about 1 GB per instance (0.9 s under ASan), outside
     `plzig.max_memory`, and an idle cached instance would keep it.

   PL/Zig now refuses both before WAMR sees the module (§4.5). Reproducers
   `fuzz/loader/findings/wamr-huge-locals.wasm` and `wamr-huge-table.wasm`
   (replayed by `fuzz/build.sh`); regression tests in
   `docker/security-checks.sh` (fake compiler modes 8 and 9). The other
   declared counts of the MVP format that WAMR accepts in this
   configuration (types, imports, functions, globals, exports, element and
   data segments, `br_table` targets) need at least one byte of module per
   unit, and linear memory is capped by the allocator; that is an
   inference from reading `wasm_loader.c`/`wasm_runtime.c`, not a proof.

   Also found by the loader target, in PL/Zig itself: the argument slots
   were written through a `PlzigSlot *` made from the guest-chosen (possibly
   misaligned) `plzig_alloc` address — undefined behaviour, though the
   copies were `memcpy`; now byte offsets
   (`fuzz/loader/findings/plzig-misaligned-args.wasm`, an ABI 2 module; in
   ABI 3 the addresses come from `plzig_init` and `plzig_alloc_args`, and
   the misaligned cases are regression tests in
   `docker/security-checks.sh`, "hostile entry points").

   Known UBSan reports, reproduced and judged harmless on x86_64/aarch64
   (not patched: vendor code; see `fuzz/loader/ubsan.supp`):
   * UBSan *misaligned access* in `tables_instantiate`
     (`core/iwasm/interpreter/wasm_runtime.c:741`): the instance layout
     places table instances at 4-byte offsets (reported by the ASan/UBSan
     variant of `docker/run-all.sh`, which therefore builds WAMR without
     the alignment check; not re-examined here). Unaligned accesses of
     that kind are legal on both supported architectures.
   * UBSan *applying zero offset to null pointer* in `memory_instantiate`
     (`wasm_runtime.c:453`) for a module whose linear memory has 0 pages:
     `NULL + 0`, never dereferenced (every access is bounds-checked
     against size 0). Reproducer `fuzz/loader/findings/wamr-null-plus-zero.wasm`.
5. **In-process sandbox.** Guest code shares the backend's address space.
   Software bounds checks stop architectural out-of-bounds access, but an
   interpreter offers no protection against microarchitectural side
   channels (Spectre-style); PL/Zig makes no claim there.
6. **No process-count or memory-cgroup limit for the compiler.** The
   compiler may `fork` (it runs its own linker that way), and no
   `RLIMIT_NPROC` or pids limit is set: a compromised compiler can create
   processes until the server user's process limit is reached within the
   compile timeout, which would also stop the postmaster from starting new
   backends, and each process may use up to `RLIMIT_AS`. They are killed
   with the process group at the end of the compilation. (Inferred from
   the code; not demonstrated by a test.) Mitigation: run the server under
   a cgroup with `pids.max` and a memory limit (systemd `TasksMax=`,
   `MemoryMax=`).
7. **No disk quota for the compiler.** `RLIMIT_FSIZE` limits each file, not
   their number: within the timeout, attacker C can fill the file system
   that holds `$PGDATA/plzig` (the build directory is removed afterwards;
   what it writes into the shared Zig cache stays). If that file system
   also holds `pg_wal`, PostgreSQL itself stops with a PANIC when it cannot
   write WAL. A benign compilation needs a few MB plus the shared cache
   (about 45 MB). The disk-full test shows that PL/Zig itself fails cleanly
   and recovers; it does not cover the server's own behaviour. Mitigation:
   keep `pg_wal` on its own file system, or put the data directory under a
   quota.
8. **The lexical policy and the curated `std` are not a boundary** (§4.3):
   reflection reaches most of `std`. What keeps it harmless is the target
   and the loader.
9. **Compile-time denial of service.** One compilation at a time
   cluster-wide, up to `plzig.compile_timeout` each: a role with `USAGE` can
   keep every other role waiting for the compiler. Grant `USAGE`
   deliberately.
10. **Server log**: guest code can write to the server log
    (`plzig.print(.log, ...)`), including newlines, like `RAISE LOG`.
11. **aarch64 is untested.** The code paths are parameterised (Zig tarball
    by architecture, the seccomp filter has an aarch64 variant with its own
    architecture check), but neither the suite nor the fuzz targets have
    run on aarch64. The seccomp filter and Landlock rules there are
    unverified.
12. **Toolchain trust.** PL/Zig checks ownership, permissions, location and
    version of the compiler, and optionally its hash, but cannot prove it
    is an authentic Zig build; the lib directory is not hashed.
13. **Guest-side readers of native values.** The jsonb reader and the
    numeric/calendar code run in the guest: a bug there can only give a
    function a wrong answer or a trap, never touch host memory (it is
    sandboxed like user code). What a function returns is checked by the
    host either way (*4.7*). The jsonb layout is read in host byte order, so
    `jsonb` falls back to text on big-endian hosts (untested).

## 9. Verification status

What was run for this document (phase C, 2026-11-14), on x86_64, kernel
7.2 (Landlock ABI 10), PostgreSQL 18.7 for the fuzz targets and all six
versions for the test matrix:

Fuzzing (method and how to repeat it: `fuzz/README.md`):

| Target | Budget | Executions | Result |
|---|---|---|---|
| validator | 1918 s × 8 processes | 34.5 M | no finding |
| loader | 1922 s × 8 | 34.0 M | 11 slow inputs → the declared-locals finding (§8 item 4) |
| loader, after the first fix | 1869 s × 8 | 50.8 M | no finding; replayed corpus covers `plzig_runtime.c` 79 % of lines, `wasm_loader.c` 87 %, `wasm_interp_classic.c` 53 % |
| loader, a further run | 161 s × 8 | 21 k | UBSan: misaligned slot pointer in `plzig_instance_call` (§8 item 4), fixed |
| loader, after all fixes | 1865 s × 8 | 53.5 M | no finding; `plzig_runtime.c` 80 % of lines, `wasm_loader.c` 87 %, `wasm_interp_classic.c` 56 % |
| hostabi | 660 s | 51 600 calls | no finding |
| marshal | 660 s | 723 600 values, 36 180 signatures | no finding |
| pipeline | 660 s | 521 bodies | no finding, no compiler crash |

Static analysis and hardening: `docker/static-analysis.sh` clean after
  the fixes listed in PLAN.md.

Runs for the native type mappings (PLAN.md §12 item 12, 2026-11-15; x86_64,
PostgreSQL 18.7, images built from that tree):

| Target | Budget | Executions | Result |
|---|---|---|---|
| jsonb (new) | 1208 s × 8 processes | 72.8 M | no finding |
| jsonb, after the hot-path changes (in-place conversions checked against the wire-format ones) | 1209 s × 8 | 66.8 M | no finding |
| marshal (range limits, jsonb documents, jsonb_out differential) | 600 s | 46 080 values, 720 stored rows, 2 160 signatures | no finding |
| hostabi (`numeric_op`, `tz_convert`, every kind) | 600 s | 98 700 calls | no finding |
| every target, smoke | 60 s each | – | no finding |

The whole test matrix (`docker/run-tests.sh`, all six versions) and every
variant of `docker/run-all.sh` (hardened, Valgrind, ASan/UBSan, coverage
89.5 % of lines, GCC/Clang `-Wextra -Werror`, upgrade from 14, fuzz smoke,
static analysis, full disk) passed on the same tree.

Not done: 24-hour fuzzing runs (a pre-release step, `fuzz/README.md`),
CodeQL, SQLsmith-style random SQL, `wasm-smith`-generated modules, aarch64.
