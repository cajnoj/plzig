# PL/Zig — Zig as a PostgreSQL procedural language

PL/Zig lets you write PostgreSQL functions, procedures and `DO` blocks in
[Zig](https://ziglang.org) 0.17.1:

```sql
CREATE FUNCTION add(a int, b int) RETURNS int STRICT LANGUAGE plzig AS $$
    return a + b;
$$;
SELECT add(1, 2);   -- 3
```

The Zig code is **not** compiled to native code. It is compiled to a
`wasm32-freestanding` WebAssembly module and executed by an embedded,
interpreter-only WebAssembly runtime (WAMR) inside the backend. Guest code
has its own linear memory, cannot make system calls, and can only call the
small host API PL/Zig provides (logging, errors, SPI). The design and the
reasoning behind every decision are in [PLAN.md](PLAN.md); the host/guest
interface is in [doc/abi.md](doc/abi.md).

Supported servers: PostgreSQL 14, 15, 16, 17, 18 and 19 (tested: 14.25,
15.20, 16.16, 17.12, 18.7, 19rc2) on Linux x86_64 (aarch64 should work:
pinned checksums are included, but it is untested).

## Building and installing

PL/Zig needs **Zig 0.17.1**, exactly, and does **not** ship or install it.
The Zig compiler is a mandatory external dependency that the administrator
provides and owns: it is needed to build the extension's source validator,
and at run time to compile functions. Nothing is ever downloaded by the
database server, and plain `make` / `make install` never download Zig.

Requirements: the server development package (`pg_config`, PGXS), a C
compiler, `make`, `cmake` (for WAMR), `patch`, Zig 0.17.1; `git` only if
WAMR has to be downloaded.

### 1. Get Zig 0.17.1

Use any Zig 0.17.1 you trust. Under the default Landlock sandbox it must be
**statically linked** (the official ziglang.org builds are; many
distribution packages link LLVM dynamically and are refused, see below).
The build has an optional helper that downloads the official tarball (or
takes a local copy), verifies the pinned SHA-256 and unpacks it to a prefix
you choose; it never overwrites an existing directory:

```sh
sudo make install-zig ZIG_PREFIX=/opt/zig-0.17.1
# offline / air-gapped:
sudo make install-zig ZIG_PREFIX=/opt/zig-0.17.1 ZIG_TARBALL=/path/zig-x86_64-linux-0.17.1.tar.xz
make fetch-zig            # only download + verify into build/dl/
```

### 2. Build and install the extension

```sh
make ZIG=/opt/zig-0.17.1/zig                  # [WAMR_SRC=/path/wamr] for offline builds
sudo make install
```

* `ZIG` must be an absolute path; the build fails unless `zig version`
  prints exactly `0.17.1`. The same version is compiled into `plzig.so`.
* WAMR must be tag `WAMR-2.4.5` (commit `25bd7eb6…`); the build copies it to
  `build/wamr-src` and applies `third_party/wamr-interrupt.patch` with
  `--fuzz=0` (the source tree stays pristine).
* `make install` installs `plzig.so`, the extension files, the policy
  checker `$(pkglibdir)/plzig/plzig-validate` and the guest SDK
  `$(sharedir)/plzig/sdk/`. No Zig files. (Earlier versions installed a
  bundled compiler under `$(pkglibdir)/plzig/zig-0.17.1/`; `make install`
  leaves such a directory alone, remove it yourself once nothing points
  at it.)
* `make WERROR=1` builds the C code with `-Werror`.

### 3. Point the server at the compiler

In `postgresql.conf` (these settings cannot be set any other way):

```
plzig.zig_path = '/opt/zig-0.17.1/zig'
#plzig.zig_sha256 = '<sha256 of that file>'   # optional pin
```

then reload (`SELECT pg_reload_conf();` or `pg_ctl reload`). Then, as a
superuser:

```sql
CREATE EXTENSION plzig;
GRANT USAGE ON LANGUAGE plzig TO some_developer;   -- not granted to PUBLIC
```

`CREATE EXTENSION` works without a compiler; until `plzig.zig_path` is set,
every compile fails with `no Zig compiler is configured` (and a hint naming
the setting), while functions whose modules are already in the cache keep
running.

## Running the tests

```sh
docker/run-tests.sh                    # all six versions, prints a summary
docker/run-tests.sh 18.7 14.25         # a subset
PLZIG_PARALLEL=1 docker/run-tests.sh   # versions in parallel
```

Each version is built in `postgres:<version>-bookworm` with
`docker/Dockerfile`, which installs Zig with `make install-zig` into
`/opt/zig-0.17.1` (from `vendor/` when present) and builds against it;
then `docker/test-in-container.sh` starts a scratch cluster with
`plzig.zig_path` set, runs `make installcheck` (the pg_regress suite in
`test/`) and `docker/security-checks.sh` (checks that need
`postgresql.conf` changes: compiler path, ownership, version and checksum
checks, a decoy `zig` on the server's `PATH`, fake compilers that emit
modules with forbidden imports, a Landlock probe, cache tampering, the
`make install` file list, leftover processes). The suite needs Landlock
(the default `plzig.compiler_sandbox = require`); the summary shows how
the compiler was confined. A second container per version runs with a
seccomp profile that blocks Landlock (`docker/seccomp-no-landlock.json`)
and checks that `require` refuses to compile and `try` compiles
(`docker/no-landlock-checks.sh`). Logs go to `build/test-logs/`.

To run the regression suite against an existing installation:
`make installcheck` (the `setup` test reconnects as a test role with `\c`, so
local connections must not require a password, and `plzig.zig_path` must
be set).

## Writing functions

The function body is the body of a Zig function. Every body sees two
declarations: `plzig` (the SDK) and `std` (a curated subset of the standard
library, also `plzig.std`).

### Types

| SQL | Zig |
|-----|-----|
| `boolean` | `bool` |
| `smallint`, `integer`, `bigint` | `i16`, `i32`, `i64` |
| `real`, `double precision` | `f32`, `f64` |
| `text`, `varchar`, `char(n)` | `[]const u8` (bytes in the database encoding) |
| `bytea` | `[]const u8` |
| anything else (numeric, date, arrays, enums, domains, composites, json…) | `[]const u8` holding the type's text representation |
| `void` | `void` |

* `STRICT` functions get plain parameter types; otherwise parameters are
  optionals (`?i32`), `null` meaning SQL NULL.
* The return type is `anyerror!?T`: `return null;` returns SQL NULL,
  returning a Zig error raises `ERROR: plzig function failed: <ErrorName>`.
* Returned text must be valid in the database encoding; values of other
  types go through the type's input function, so invalid dates, domain
  constraint violations etc. are reported by PostgreSQL.
* Unnamed parameters are called `arg1`, `arg2`, …

You can define helper functions and globals after the body by closing the
function yourself (the generated wrapper adds the final `}`):

```sql
CREATE FUNCTION fib(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    return fibImpl(@intCast(n));
}
fn fibImpl(n: u32) i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    for (0..n) |_| {
        const t = a + b;
        a = b;
        b = t;
    }
    return a;
$$;
```

### Memory

`plzig.allocator` is the only allocator. Everything allocated from it is
released when the call returns (like a per-call memory context); `free` is
optional. Guest memory is capped by `plzig.max_memory`; beyond that
allocations fail with `error.OutOfMemory`.

```sql
CREATE FUNCTION shout(s text) RETURNS text STRICT LANGUAGE plzig AS $$
    const out = try plzig.allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
$$;
```

### Messages and errors

```zig
plzig.notice("processed {d} rows", .{n});     // also debug/info/warning
plzig.raise("bad input: {s}", .{s});          // ERROR, SQLSTATE P0001, never returns
```

Integer overflow, out-of-bounds indexing, `unreachable`, null unwrapping and
other safety checks are on (`ReleaseSafe`) and raise
`ERROR: PL/Zig panic: <message>`; WebAssembly traps (e.g. stack overflow)
raise `ERROR: PL/Zig function trapped: <reason>`. The backend is not
affected either way.

### SPI

```sql
CREATE FUNCTION price_of(item text) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const r = try plzig.spi.execute(
        "SELECT price FROM items WHERE name = $1", &.{item});
    if (r.rows == 0) return null;
    return try r.get(0, 0);
$$;
```

* Parameters are text (`null` for SQL NULL); cast them in SQL (`$1::int`).
* Results come back as text copied into the arena (`get` returns `null` for
  SQL NULL); `r.rows`, `r.columns`, `r.columnName(i)`.
* Statements run with the privileges of the current user, exactly like
  PL/pgSQL (`SECURITY DEFINER` works as usual). SPI is read-only unless the
  function is `VOLATILE`.
* Any SQL error aborts the whole call; it cannot be caught in Zig.
* All result rows are materialised in backend memory (no cursors yet).

### Procedures and DO

```sql
CREATE PROCEDURE log_it(m text) LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("INSERT INTO log VALUES ($1)", &.{m});
$$;
CALL log_it('hello');

DO $$ plzig.notice("hi", .{}); $$ LANGUAGE plzig;
```

Transaction control (`COMMIT`/`ROLLBACK`) inside procedures is not supported.

### Session state

Globals persist per function per session (and are never shared between
functions); an instance that raised an error is discarded, so its globals
start over.

### Not supported (by design, see PLAN.md D10)

Triggers, event triggers, set-returning functions, `OUT`/`INOUT`/`VARIADIC`/
`TABLE` parameters, polymorphic and other pseudo-types (except `void`
results), aggregates/window functions, transaction control, catching SQL
errors, and any access to time, randomness, environment, files or network
from guest code (use SQL through SPI: `SELECT now()`).

## Configuration (GUCs)

| Name | Context | Default | Purpose |
|------|---------|---------|---------|
| `plzig.zig_path` | `postgresql.conf` only | *(none)* | Absolute path of the Zig 0.17.1 compiler. Required for compiling; `PATH` is never searched. |
| `plzig.zig_lib_dir` | `postgresql.conf` only | *(detect)* | Zig's `lib/` directory. Empty: `<compiler dir>/lib` (tarball layout) or `<compiler dir>/../lib/zig` (FHS layout, e.g. `/usr/bin/zig` + `/usr/lib/zig`). |
| `plzig.zig_sha256` | `postgresql.conf` only | *(empty)* | If set, the SHA-256 the compiler binary must have (hex). Covers the binary only, not `lib/`. |
| `plzig.compiler_sandbox` | `postgresql.conf` / reload | `require` | Landlock confinement of the compiler: `require` (refuse to compile without it), `try` (use it if available, otherwise compile unconfined and log once per backend), `off`. Set only in `postgresql.conf` (not `SET`, `ALTER SYSTEM`, per role or per database). Any other value, including the former `on`, boolean spellings and other letter case, makes every compilation fail until it is corrected. |
| `plzig.compile_timeout` | superuser | `300s` | Wall-clock limit per compiler run (min 100 ms). |
| `plzig.compile_memory_limit` | superuser | `4GB` | `RLIMIT_AS` of the compiler (0 = none). Zig 0.17.1 needs about 1 GB. |
| `plzig.max_source_size` | superuser | `1MB` | Maximum function body size (max 3 MB). |
| `plzig.max_memory` | superuser | `64MB` | Linear memory cap per function instance (max 1023 MB). Lowering it retires cached instances. |
| `plzig.instance_cache_size` | superuser | `64` | Idle instances kept per backend (0 = none). |

"`postgresql.conf` only" means: not `SET`, not `ALTER ROLE/DATABASE ...
SET`, not `ALTER SYSTEM`; the value is hidden from non-superusers.

`plzig_sandbox_status()` (superuser only) tells how the last compilation in
the session was confined, e.g. `enforced (landlock ABI 6)` or
`unavailable (landlock_create_ruleset returned -38)`.

## Security model

**What the sandbox gives you.** Guest code runs in a WebAssembly
interpreter with software bounds checks. It cannot read or write backend
memory, make system calls, start threads or install signal handlers; it can
only call the host imports listed in `doc/abi.md`, all of which validate
their arguments. A Zig bug in a function — overflow, out-of-bounds access,
use of a dangling pointer, stack overflow — corrupts at most that
function's own linear memory and ends in an `ERROR`. Guest memory is capped
per instance; runaway loops are stopped by query cancel,
`statement_timeout` and `pg_terminate_backend` (the vendored interpreter is
patched to poll `QueryCancelPending`/`ProcDiePending` at every branch and
call). SQL runs through SPI with the normal permission checks of the
current user.

**Defence in depth.** Before compiling, `plzig-validate` (built on the
compiler's own tokenizer) rejects `@import` of anything but `"plzig"`, every
builtin not on an allowlist (e.g. `@embedFile`, `@extern`, `@export`,
`@ptrFromInt`, `@ptrCast`, `@setEvalBranchQuota`, `@wasmMemoryGrow`,
atomics) and the keywords `extern`, `export`, `asm`, `linksection`,
`callconv`, `threadlocal`, `addrspace`, `volatile`. The loader rejects any
module that imports anything other than the known `plzig` host functions.

**The compiler.** Compiling means running the Zig compiler on user input,
so `USAGE` on the language is revoked from `PUBLIC` and should be granted
deliberately. The compiler runs as a child process: `execve` with a fixed
argv (no shell, user text never on a command line or in a path), clean
environment, new session, all other descriptors closed, `no_new_privs`,
`RLIMIT_CORE=0`, CPU/file-size/address-space limits, a wall-clock timeout,
and Landlock (required by default): execute+read only on the compiler
binary and the validator binary themselves (file rules, not their
directories), read-only on the Zig `lib/` directory (passed explicitly
with `--zig-lib-dir`), read-write only on its private build directory and
the shared Zig cache, no TCP, no signals or abstract sockets outside its
domain.
It is killed (whole process group) and reaped on every exit path, including
cancel, `ERROR` and backend exit. Compilations are serialised cluster-wide
with a file lock.

**The toolchain checks.** Before the configured compiler is run for the
first time in a backend (and again whenever a setting or the identity of
the binary or lib directory changes), PL/Zig:

* requires `plzig.zig_path` to be set and absolute (`PATH` is never
  searched), resolves it with `realpath` and requires a regular file;
* finds the lib directory (`plzig.zig_lib_dir` or the standard layouts;
  it must contain `std/std.zig`);
* requires the binary, the lib directory and every directory above them to
  be owned by root or the server user and not writable by group or others
  (above the immediate parent, a sticky directory such as `/tmp` is
  accepted); refuses paths inside or containing the data directory; these
  path and permission checks run before every compile;
* if `plzig.zig_sha256` is set, hashes the binary and compares;
* under Landlock, refuses a dynamically linked binary or a script (it could
  not start: only the binary itself is executable in the sandbox);
* runs `zig version` in the sandbox and requires exactly the version the
  validator was built with (`0.17.1`). The validator uses that version's
  tokenizer, so a different compiler could disagree with it about what
  the source contains.

What these checks do **not** guarantee: they do not prove the binary is
an authentic Zig build (only `plzig.zig_sha256` pins it, and only the
binary: files under `lib/` are not hashed or permission-checked
individually); anybody who is root or the server OS user can still change
the toolchain, and a change between the check and the `execve` is possible
for them; the version check trusts the compiler's own answer. Paths in
these errors are shown to superusers and written to the server log only.
Modules in the cache are keyed by the Zig version, so they are reused
across toolchain changes only for the same version.

**Files.** Everything lives in `$PGDATA/plzig/` (0700, owner and
symlink-checked before each use): `cache/<sha256>.wasm` (0600, content
addressed, written via `O_EXCL` temp file + fsync + `durable_rename`),
`pgsql_tmp.zig-cache/` (the compiler's cache; skipped by base backups) and
short-lived `pgsql_tmp.build.<pid>.<n>/` directories. Modules read from the
cache must be regular 0600 files owned by the server user and opened with
`O_NOFOLLOW`; they are re-validated (imports, exports, ABI) on every load.

**Limits — read these.**

* If Landlock is unavailable (old kernel, or blocked by a seccomp profile),
  the default `require` refuses every compile (cached modules keep
  running). `try` then runs the compiler **without filesystem
  confinement**: a compiler exploit would run with the full rights of the
  `postgres` OS user. Check `plzig_sandbox_status()`.
* Even with Landlock, the Zig cache directory is shared by all
  compilations. A malicious input that exploits the compiler could poison
  it and thereby alter modules later compiled for *other* users' functions,
  including `SECURITY DEFINER` ones. The sandbox stops that code from
  touching the database files, but not from influencing other functions'
  WebAssembly. Treat `USAGE ON LANGUAGE plzig` as "may run the compiler".
* The lexical policy and the curated `std` are conveniences, not the
  security boundary; clever comptime code may reach more of `std` than
  intended. The boundary is the WebAssembly sandbox plus the import check.
* Compile-time resource use is bounded only by the timeout, CPU/AS rlimits
  and the cluster-wide lock (one compile at a time): a user with `USAGE`
  can keep the compiler busy.
* Runtime resource use is bounded per instance (`plzig.max_memory`), but a
  function recursing through SPI creates one instance per level, and SPI
  results are fully materialised; like PL/pgSQL, a determined user can use
  a lot of backend memory and CPU within `statement_timeout`.
* Guest code can write to the server log via `plzig.print(.log, …)`, like
  `RAISE LOG` in PL/pgSQL.
* WAMR is a large C code base running in the backend; a bug in its
  validator or interpreter would be a sandbox escape. The build disables
  every optional feature (AOT/JIT, WASI, threads, SIMD, GC, multi-module…)
  to keep that surface small.

## License

PL/Zig is released under [The PostgreSQL License](LICENSE).
Copyright (c) 2026, Jonathan Jacobson.

Binary builds statically link the WebAssembly Micro Runtime (Apache License
2.0 with LLVM Exceptions, with one file modified by this project) and the
`plzig-validate` tool contains parts of the Zig standard library (MIT). See
[THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) and [LICENSES/](LICENSES); these
files are installed with the extension under PostgreSQL's documentation
directory (`pg_config --docdir`, subdirectory `extension/plzig`). Package
metadata for a binary build should state
`PostgreSQL AND Apache-2.0 WITH LLVM-exception AND MIT`.

PL/Zig does not include the Zig compiler; you install Zig 0.17.1 yourself
under its own license. WebAssembly modules compiled from your functions
contain MIT-licensed code from the Zig standard library and compiler
runtime, which only matters if you redistribute those modules.

PL/Zig is an independent project and is not affiliated with or endorsed by
the PostgreSQL project, the Zig Software Foundation or the Bytecode Alliance.
