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
small host API PL/Zig provides (logging, errors, SPI: queries, prepared
statements, cursors). The design and the
reasoning behind every decision are in [PLAN.md](PLAN.md); the host/guest
interface is in [doc/abi.md](doc/abi.md).

Supported servers: PostgreSQL 14, 15, 16, 17, 18 and 19 (tested: 14.25,
15.20, 16.16, 17.12, 18.7, 19rc2) on Linux x86_64 (aarch64 should work:
pinned checksums are included, but it is untested).

### Compatibility

Each PL/Zig release supports exactly one Zig version (the server refuses
any other compiler); a new Zig minor release means a new PL/Zig major
(PLAN.md §14).

| PL/Zig | SQL extension version | Zig (exactly) | Host/guest ABI | PostgreSQL |
|---|---|---|---|---|
| 1.0.x (not yet released; this tree is `1.0.0-dev`) | 1.0 | 0.17.1 | 5 | 14, 15, 16, 17, 18, 19 |

This table is the one place that relates the four version numbers
(details in [doc/packaging.md](doc/packaging.md#versions)): PL/Zig's own
semantic version (`PLZIG_VERSION` in the `Makefile`, also the package
version and `plzig.so`'s module version); the SQL extension version
(`ALTER EXTENSION plzig UPDATE`), which is the release's `MAJOR.MINOR` and
changes only when SQL objects do (patch releases never need an upgrade
script); the host/guest ABI version, independent of both and part of the
module cache key; and the Zig pin. The pin is `ZIG_VERSION` in the
`Makefile`, its single source: it is compiled into `plzig.so`, written into
the extension's comment (`\dx plzig`, generated `plzig.control`), shown by
`plzig_sandbox_status()` and is the version of the `plzig-zig-toolchain`
package. Before upgrading to a PL/Zig release with another Zig, check your
functions with [`plzig_check_all()`](#checking-every-function-plzig_check_all).

## Installing from packages

RPM and Debian packages are built and tested from this repository
(`packaging/`, `debian/`; [doc/packaging.md](doc/packaging.md)), but none
are published yet. Built locally, for PGDG's PostgreSQL 14–19 on EL 8
(14–18), EL 9, EL 10, Fedora 45, Debian 12 and 13, Ubuntu 22.04, 24.04 and
26.04 (x86_64):

* `plzig_<major>` (RPM) / `postgresql-<major>-plzig` (Debian), plus
* `plzig-zig-toolchain`: the official Zig 0.17.1 build (SHA-256 pinned,
  compiler unchanged, `lib/` pruned to what PL/Zig needs) in
  `/usr/libexec/plzig-zig-toolchain/0.17.1/`, which the extension packages
  depend on and use as their compiled-in default for `plzig.zig_path`.

```sh
dnf install plzig_17          # with the packages in a repository next to PGDG's
apt install postgresql-17-plzig
```

then `CREATE EXTENSION plzig;` as a superuser and `GRANT USAGE ON LANGUAGE
plzig TO ...` as below; no `postgresql.conf` change is needed. (On Fedora
and EL 10, keep the distribution's own `postgresql*` packages out of the
way as PGDG advises, `excludepkgs=postgresql*`; they use the same names.)

**Kernel requirement.** The default `plzig.compiler_sandbox = require` needs
Landlock ABI 6 (Linux 6.12 or newer) and seccomp. On older kernels -- the
stock kernels of EL 8, EL 9, Debian 12, Ubuntu 22.04 and 24.04, for example
-- every compilation (`CREATE FUNCTION ... LANGUAGE plzig`, `DO`) is refused
until an administrator explicitly lowers the setting (see
[Configuration](#configuration-gucs) and the security model below). The
packages do not change the default. Removing the packages leaves
`$PGDATA/plzig/` (the module and Zig caches) in place; see
[doc/packaging.md](doc/packaging.md#removal-and-the-cache-directory).

An evaluation image `plzig/postgres:<major>` (PostgreSQL with PL/Zig and
no other procedural language) can be built with
`packaging/image/build-image.sh`; it is not published.

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
* Fully offline: `make ZIG=... WAMR_TARBALL=/path/WAMR-2.4.5.tar.gz` (the
  tag's source archive, SHA-256 pinned) together with `make install-zig
  ZIG_TARBALL=...`; `make dist` makes a reproducible source tarball
  ([doc/packaging.md](doc/packaging.md)).
* `make PLZIG_DEFAULT_ZIG_PATH=/abs/path/zig` compiles in a default for
  `plzig.zig_path` (what the packages do); without it there is none.

The same build can be driven with `zig build`. `build.zig` holds no build
logic of its own: each step runs one `make` target and passes the running
compiler as `ZIG=`, so the validator is built by the compiler you invoked
(it refuses any Zig other than 0.17.1).

```sh
/opt/zig-0.17.1/zig build                     # make all
sudo /opt/zig-0.17.1/zig build pg-install     # make install
/opt/zig-0.17.1/zig build test                # unit tests of the validator and SDK
/opt/zig-0.17.1/zig build --help              # all steps and -D options
```

The steps are called `pg-install` / `pg-uninstall` because Zig reserves
`install` / `uninstall` for its own prefix, which PL/Zig does not use.
Options: `-Dpg-config=`, `-Dwamr-src=`, `-Dwerror=true`, `-Dtesting=true`,
`-Ddestdir=`, `-Djobs=`, `-Dmake=`.

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

GitHub Actions (GitHub-hosted runners only) runs the per-version layers and
a 60-second smoke run of every fuzz target on every push and pull request,
an allowed-to-fail job with the newest Zig release (validator and SDK unit
tests only, `docker/zig-newest-check.sh`), and every fuzz target for about
5.5 hours nightly (`.github/workflows/fuzz-nightly.yml`, see
[fuzz/README.md](fuzz/README.md#ci)).

Two entry points, both Docker-based, CI-friendly (no TTY, plain output, exit
status non-zero on any failure):

```sh
docker/run-tests.sh                    # fast matrix: all six versions
docker/run-tests.sh 18.7 14.25         # a subset
PLZIG_PARALLEL=1 docker/run-tests.sh   # versions in parallel

docker/run-all.sh                      # every layer, every version, all variants
PLZIG_VERSIONS=18.7 PLZIG_VARIANTS="asan coverage" docker/run-all.sh
```

**Fast matrix** (`docker/run-tests.sh`). Each version is built in
`postgres:<version>-bookworm` with `docker/Dockerfile`, which installs Zig
with `make install-zig` into `/opt/zig` (the pinned version, from `vendor/` when present)
and builds against it; then `docker/test-in-container.sh` starts a scratch
cluster with `plzig.zig_path` set and runs its default layers:

* `unit`: native Zig unit tests (`make check-zig`) of the validator
  (`zig/validate/test.zig`: every builtin and keyword of the policy tables,
  a check that every builtin of the vendored Zig is classified, lexing
  corner cases, the input size limit) and of the guest SDK
  (`zig/sdk/test.zig`: the arena allocator, value and row decoding,
  parameter encoding, `plzig_call`; host imports and wasm memory are
  replaced by `zig/sdk/test_env.zig`, which only `zig test` uses);
* `regress`: `make installcheck`, the pg_regress suite in `test/`;
* `security`: `docker/security-checks.sh` (checks that need
  `postgresql.conf` changes: compiler path, ownership, version and checksum
  checks, a decoy `zig` on the server's `PATH`, fake compilers that emit
  modules with forbidden imports, a hostile guest calling the host imports
  directly with forged pointers, handles and values, a sandbox probe, the
  recursive delete against planted symbolic links, cache eviction and
  tampering, messages to unprivileged users, the `make install` file list,
  leftover processes, and that the installed `plzig.so` exports no test
  helpers);
* `leaks`: `docker/leak-checks.sh` (descriptors and child processes of a
  backend across rounds of compilations and calls) and the contents of
  `$PGDATA/plzig` after everything (only the cache, the lock file and the
  Zig cache).

The suite needs Landlock ABI 6 or later and the seccomp filter (the default
`plzig.compiler_sandbox = require`); the summary shows how the compiler was
confined. Two more containers per version run with seccomp profiles that
block Landlock (`docker/seccomp-no-landlock.json`) or the installation of
seccomp filters (`docker/seccomp-no-seccomp.json`), and check that
`require` refuses to compile, `try` compiles and logs what is missing, and
(without seccomp) what Landlock alone enforces
(`docker/no-landlock-checks.sh`, `docker/no-seccomp-checks.sh`). Logs go to
`build/test-logs/`.

**Everything** (`docker/run-all.sh`, see the header of the script for the
settings) adds, per version: the isolation tests (`test/isolation`,
`make installcheck-isolation`), the TAP tests (`test/tap/t`: crash recovery,
compile-lock concurrency, interrupts during guest loops, cursor loops,
compilations and lock waits, hot standby, dump/restore, the server
environment changing underneath, preloading), and the C unit checks
(`test/sql/testing.sql` against a `make PLZIG_TESTING=1` build, which only
the test image stages under `/opt/plzig-testing` and swaps in for that one
container). Variants on subsets of versions: PostgreSQL built from the
vendored source with `--enable-cassert` (`docker/Dockerfile.hardened`), a
Valgrind run, an ASan/UBSan build of PL/Zig and WAMR, a gcov coverage run
(report in `build/coverage/`), GCC and Clang builds with
`-Wall -Wextra -Werror` (`docker/compiler-checks.sh`), `pg_upgrade` from
PostgreSQL 14 (`docker/Dockerfile.variant`), a short run of every fuzz
target (`fuzz`), the clang static analyzer, cppcheck and a check of the
binaries' hardening (`static`, `docker/static-analysis.sh`), and
compilations on a full file system (`diskfull`,
`docker/diskfull-checks.sh`). The scripts take
`PLZIG_PLATFORM` (docker `--platform`) and pick the Zig tarball by
architecture; only x86_64 has been run.

**Fuzzing** (`docker/run-fuzz.sh <target> <seconds>`, see
`fuzz/README.md`): the validator, the module loader, the host-import ABI,
marshalling and the source generator, the SDK's jsonb reader and numeric
decoders, and the whole compile pipeline, each for a time budget, non-zero
exit status on a finding.

**Packages** (`packaging/test-matrix.sh`, `packaging/test-packages.sh
<distro> <major>`, see [doc/packaging.md](doc/packaging.md#package-tests)):
RPM and Debian packages built offline for every target distribution and
PostgreSQL major, then installed in fresh containers and checked
(dependencies, compiled-in compiler path, hardening, upgrade from an earlier
build, the regression suite against the installed package, extension
upgrade scripts, removal). CI builds and tests one RPM and one Debian
package on every push; the full matrix is a manually started workflow.

**Benchmarks** (not tests, not part of the build): `bench/run.sh`, see
[bench/README.md](bench/README.md) and [doc/benchmarks.md](doc/benchmarks.md).

Without Docker: `make check-zig ZIG=/abs/path/to/zig` runs the Zig unit
tests; `make installcheck` the regression suite against an existing
installation (the `setup` test reconnects as a test role with `\c`, so
local connections must not require a password, and `plzig.zig_path` must
be set); `make installcheck-isolation` the isolation tests. The C unit
checks need a test build installed in a throw-away installation
(`make clean && make PLZIG_TESTING=1 ZIG=... && make install PLZIG_TESTING=1`,
then `make installcheck-testing`); never install that build for real use.
The TAP tests run with `prove` from `test/tap` with `PERL5LIB` pointing at
the server's `pgxs/src/test/perl` and `test/tap`, and the environment that
`docker/test-in-container.sh` sets up (`PLZIG_TEST_ZIG`, the gated test
compiler `test/gatezig.sh`).

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
| `date` | `plzig.Date` (`.days` since 2000-01-01; `Date.infinity`, `Date.neg_infinity`) |
| `time`, `time with time zone` | `plzig.Time` (`.usecs` since midnight), `plzig.TimeTz` (`.usecs`, `.zone` = seconds west of UTC) |
| `timestamp`, `timestamp with time zone` | `plzig.Timestamp`, `plzig.TimestampTz` (`.usecs` since 2000-01-01 00:00 (UTC); infinities) |
| `interval` | `plzig.Interval` (`.months`, `.days`, `.usecs`) |
| `uuid` | `plzig.Uuid` (`.bytes`; `parse`, `format`) |
| `oid` | `plzig.Oid` (`.value`) |
| `numeric` | `plzig.Numeric` (PostgreSQL's binary format; text, comparison, conversions, arithmetic) |
| `jsonb` | argument: `plzig.Jsonb` (read in place); result: `plzig.JsonText` (JSON text) |
| a composite type (`CREATE TYPE ... AS (...)`, a table's row type) | a struct with one optional field per attribute (see *Rows*) |
| anything else (arrays, enums, domains, ranges, json, inet…) | `[]const u8` holding the type's text representation |
| `void` | `void` |

* `STRICT` functions get plain parameter types; otherwise parameters are
  optionals (`?i32`), `null` meaning SQL NULL.
* The return type is `anyerror!?T`: `return null;` returns SQL NULL,
  returning a Zig error raises `ERROR: plzig function failed: <ErrorName>`.
* Returned text must be valid in the database encoding; values of
  text-represented types go through the type's input function, so domain
  constraint violations, bad array syntax etc. are reported by PostgreSQL
  (a NULL result of a domain type is checked against the domain's
  constraints too).
* Values of the natively mapped types are PostgreSQL's own representation,
  and the types are distinct, so returning a `plzig.Date` from a function
  declared `RETURNS timestamp` does not compile. What a function returns
  (or passes as a prepared-statement parameter) is checked exactly as
  PostgreSQL's binary input functions check it: a date, time or timestamp
  outside PostgreSQL's range is `ERROR: date out of range` (`22008`) etc.;
  a `numeric` goes through `numeric_recv`; a `jsonb` result is JSON text
  parsed by `jsonb_in`. Domains over these types are passed as text. As in
  every language, the typmod of a declared result type (`timestamp(0)`,
  `numeric(5,2)`) is not applied, because PostgreSQL does not keep it;
  use a domain (`CREATE DOMAIN money2 AS numeric(12,2)`) to have it applied.
* Unnamed parameters are called `arg1`, `arg2`, …; parameter names must
  be ASCII identifiers (`[A-Za-z_][A-Za-z0-9_]*`) other than `plzig`, `std`
  and `call`. Zig keywords are fine as names: refer to them as `@"return"`.

### Rows: composite types, OUT and INOUT parameters

A composite argument or result is a struct with one optional field per
attribute, named and ordered like the attributes (`?T` with the mapping
above; a nested composite, an array of composites or a domain over a
composite stays text). Output parameters (`OUT`, `INOUT`) are the fields
of the result: with two or more (or in a procedure) the function returns
the generated struct `Result`, with one it returns that parameter's type.
`INOUT` parameters are also ordinary arguments.

```sql
CREATE FUNCTION divmod(a int, b int, OUT q int, OUT r int) STRICT LANGUAGE plzig AS $$
    if (b == 0) return null;                      // a NULL row
    return .{ .q = @divTrunc(a, b), .r = @rem(a, b) };
$$;
SELECT * FROM divmod(17, 5);                      -- 3 | 2

CREATE TYPE pair AS (a int, b text);
CREATE FUNCTION swap_sign(p pair) RETURNS pair STRICT LANGUAGE plzig AS $$
    var q = p;                                    // the same struct type
    q.a = if (p.a) |v| -v else null;
    return q;
$$;

CREATE PROCEDURE bump(INOUT n int) LANGUAGE plzig AS $$
    return .{ .n = (n orelse 0) + 1 };            // a procedure returns its row
$$;
```

* Every field must be given (a missing one is a compile error, not a
  silent NULL). `Result` is a reserved parameter name in functions that
  return a row.
* The host checks every field like a result of that type and applies the
  attribute's typmod (`varchar(3)`, `numeric(5,2)`, `timestamp(0)` as in
  `CREATE TYPE ... AS (...)`), and a domain's constraints; then it builds
  the row itself.
* A `jsonb` field is `plzig.Jsonb` in an argument and `plzig.JsonText` in a
  result, so for a type with a `jsonb` attribute the two structs differ.
* Field names must be ASCII identifiers (`[A-Za-z_][A-Za-z0-9_]*`; Zig
  keywords are fine: `.@"type"`): a composite type with other attribute
  names cannot be used as an argument or result type of a PL/Zig function.
* If a composite type (or table) changes after a function was compiled, the
  function is regenerated from the new type at its next call (and may then
  no longer compile); a row type changed during a call (`ALTER TYPE` through
  SPI) makes the call fail. A stale struct is never used.

### Set-returning functions

`RETURNS SETOF <type>`, `RETURNS TABLE (...)` and `SETOF record` with
output parameters push their rows with the generated `returnNext(row)`
(`Result` is the element type: the scalar type, or the row struct; `null`
is a NULL element, or a row of NULLs) and return `void`. The rows go into a
tuplestore as in PL/pgSQL's `RETURN NEXT` (materialize mode: the whole set
is produced by one call, spilling to a temporary file beyond `work_mem`,
bounded by `temp_file_limit`); each row is checked like a row result.

```sql
CREATE FUNCTION squares(n int) RETURNS TABLE (i int, sq bigint) STRICT LANGUAGE plzig AS $$
    var k: i32 = 1;
    while (k <= n) : (k += 1) returnNext(.{ .i = k, .sq = @as(i64, k) * k });
$$;
SELECT * FROM squares(3);
```

`returnNext` and `Result` are reserved parameter names in set-returning
functions; pushing rows from any other function is an error.

### Triggers

A trigger function (`RETURNS trigger`, no declared parameters) is
`pub fn call(tg: plzig.Trigger) anyerror!plzig.TriggerResult`. `tg` has
PostgreSQL's `TG_*` data — `when()` (`.before`, `.after`, `.instead_of`),
`forEachRow()`, `op()` (`.insert`, `.update`, `.delete`, `.truncate`),
`name()`, `tableName()`, `tableSchema()`, `relid()`, `argCount()`/`arg(i)`,
the table's columns as they are now (`columnCount()`, `columnName(i)`,
`columnKind(i)`, `columnIndex(name)`) — and NEW and OLD, as typed rows
(`newRow()`, `oldRow()`: `Row.get(T, position)`) or as structs bound to the
columns **by name** at every call (`try tg.new(T)`, `try tg.old(T)`: any
subset of the columns, in any order; null when the trigger has no such
row). The result is `.skip` (NULL: skip the operation for this row),
`.new` or `.old` (that row unchanged), or `try tg.modify(.{ .col = value,
... })`: NEW (OLD for `DELETE`) with those columns changed.

```sql
CREATE FUNCTION stamp() RETURNS trigger LANGUAGE plzig AS $$
    const Row = struct { name: ?[]const u8, qty: ?i32 };
    const new = (try tg.new(Row)) orelse return .skip;
    if ((new.qty orelse 0) < 0) return .skip;            // refuse silently
    return try tg.modify(.{ .name = new.name orelse "unnamed" });
$$;
CREATE TRIGGER items_stamp BEFORE INSERT OR UPDATE ON items
    FOR EACH ROW EXECUTE FUNCTION stamp();
```

* The row PostgreSQL gets is built by the host from the trigger's own NEW
  (or OLD) tuple: it always has the table's row type. Each changed column
  is checked like a row field (type, the column's typmod, a domain's
  constraints); generated and dropped columns cannot be set; `NOT NULL`
  and `CHECK` constraints are checked by PostgreSQL afterwards, as for any
  trigger.
* Because NEW and OLD are bound by name at every call, a table altered after
  the function was compiled is noticed (`error.NoSuchColumn`,
  `error.TypeMismatch`), never misread; added columns are simply kept.
* For `AFTER` and statement-level triggers PostgreSQL ignores the result
  (return `.skip`). Transition tables (`REFERENCING NEW TABLE AS ...`) can
  be queried through SPI. A trigger function runs with the privileges of
  the user who fires it, or of its owner if it is `SECURITY DEFINER`, as in
  every language. Event triggers are not supported.

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

### Dates, times, numeric and jsonb

```sql
CREATE FUNCTION next_monday(d date) RETURNS date STRICT LANGUAGE plzig AS $$
    const dow: i32 = try d.dayOfWeek();         // 0 = Sunday, as EXTRACT(dow)
    return .{ .days = d.days + (if (dow == 1) 7 else @mod(8 - dow, 7)) };
$$;

CREATE FUNCTION local_hour(t timestamptz, zone text) RETURNS int STRICT LANGUAGE plzig AS $$
    const f = try t.fields(zone);               // the host converts; null = session TimeZone
    return f.hour;
$$;

CREATE FUNCTION with_tax(price numeric) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const rate = try plzig.Numeric.parse("1.19");
    return try (try price.mul(rate)).round(2);  // PostgreSQL's numeric code, exactly
$$;

CREATE FUNCTION qty_of(doc jsonb) RETURNS int STRICT LANGUAGE plzig AS $$
    const v = (try (try doc.root()).object.get("qty")) orelse return null;
    return @intCast(try v.number.toI64());
$$;

CREATE FUNCTION tagged(doc jsonb) RETURNS jsonb STRICT LANGUAGE plzig AS $$
    // results are JSON text (parsed by jsonb_in)
    return plzig.jsonText(try std.fmt.allocPrint(plzig.allocator,
        "{{\"doc\": {s}, \"tag\": 1}}", .{(try doc.toJsonText()).text}));
$$;
```

* **Calendar** (in the guest, PostgreSQL's Julian-day code):
  `Date.fromYmd(y, m, d)` (as `make_date`; a negative year is BC),
  `d.ymd()`, `d.dayOfWeek()`, `d.dayOfYear()`, `d.toTimestamp()`;
  `Time.fromHms(h, m, s, us)`, `t.hms()`; `Timestamp.fromFields(.{ .year,
  .month, .day, .hour, .minute, .second, .microsecond })` (as
  `make_timestamp`; second 60 is a leap second), `ts.fields()`, `ts.date()`,
  `ts.time()`. Impossible fields are `error.InvalidDate`/`InvalidTime`,
  values outside PostgreSQL's range `error.OutOfRange`.
* **Time zones** (by the host, PostgreSQL's time zone code):
  `tz.toLocal(zone)` (`AT TIME ZONE`), `TimestampTz.fromLocal(ts, zone)`,
  `tz.fields(zone)`, `TimestampTz.fromFields(f, zone)`; `zone` is a name
  (`"Europe/Berlin"`, `"UTC"`, `"+05:30"`, ...) or `null` for the session's
  `TimeZone`.
* **numeric**: `n.toText()` (and `{f}` in format strings: numeric_out's
  text), `Numeric.parse(text)`, `n.order(m)`/`eql` (PostgreSQL's ordering:
  NaN largest), `isNaN`/`isInf`/`isFinite`/`isZero`/`isNegative`, `scale()`,
  `toI64()` (exact: `error.NotIntegral`/`Overflow`), `toF64()` (correctly
  rounded), `fromI64`, `fromF64` (as `float8::numeric`); arithmetic by the
  host: `add`, `sub`, `mul`, `div`, `divTrunc`, `mod`, `round(digits)`,
  `trunc(digits)`, `abs`, `neg` -- results are PostgreSQL's exactly,
  division by zero is the usual SQL error. Every result is allocated in the
  arena (the size of the result, typically 10–20 bytes per operation).
* **jsonb**: `doc.root()` gives a `plzig.JsonValue` (`.null`, `.bool`,
  `.string`, `.number`, `.array`, `.object`); `obj.get(key)` (a binary
  search, as jsonb does), `obj.iterator()` (keys in jsonb's order: by
  length, then bytes), `arr.len()`, `arr.get(i)`, `arr.iterator()`;
  `number.toI64()`/`toF64()`/`numeric()`; `toJsonText()` on a document or
  any value gives jsonb_out's text. Malformed bytes (never produced by
  PostgreSQL) are `error.InvalidJsonb`. On a big-endian server `jsonb`
  arguments are text instead.

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
plzig.raiseError(.{                           // ERROR with your own SQLSTATE, never returns
    .sqlstate = "23514",                      // check_violation
    .message = "quantity must be positive",
    .detail = "The order has 3 lines.",      // optional
    .hint = "Remove the line instead.",      // optional
});
plzig.raiseErrorFmt(.{ .sqlstate = "22003", .hint = "Use at most 10." },
                    "value {d} is out of range", .{x});
```

A calling PL/pgSQL function can catch these by condition name or SQLSTATE
(`EXCEPTION WHEN check_violation`, `WHEN SQLSTATE '22003'`) and read the
detail and hint with `GET STACKED DIAGNOSTICS`. The severity is always
`ERROR`. The SQLSTATE must be five characters, digits or upper-case letters
(`P0001` if omitted); codes of the classes `00`, `01`, `02` (not errors),
`08`, `53`, `57`, `58`, `F0` and `XX` (connection, resources, operator
intervention, system, configuration and internal errors: conditions that
monitoring, poolers and drivers react to) are refused with an error of
their own (`22023`), as are malformed codes. Message, detail and hint must
be valid in the database encoding without NUL bytes, are cut at 64 kB, and
control characters other than newline and tab are shown as `?`. Empty or
`null` detail and hint are omitted. The same holds for the text of
`plzig.raise`, of messages of every level (`plzig.notice`, `plzig.print`,
...) and of panic messages: a function cannot write terminal escape
sequences or carriage returns into the server log or the client's output.

Integer overflow, out-of-bounds indexing, `unreachable`, null unwrapping and
other safety checks are on (`ReleaseSafe`) and raise
`ERROR: PL/Zig panic: <message>`; WebAssembly traps (e.g. stack overflow)
raise `ERROR: PL/Zig function trapped: <reason>`. The backend is not
affected either way.

### SPI

Three ways to run SQL. All of them run with the privileges of the current
user, exactly like PL/pgSQL (`SECURITY DEFINER` works as usual); SPI is
read-only unless the function is `VOLATILE`; any SQL error aborts the whole
call and cannot be caught in Zig. Procedures and `DO` blocks can end the
transaction with `plzig.commit()` / `plzig.rollback()` (see *Procedures and
DO*).

**`spi.execute`** — one statement, text parameters, the whole result
materialised:

```sql
CREATE FUNCTION price_of(item text) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const r = try plzig.spi.execute(
        "SELECT price FROM items WHERE name = $1", &.{item});
    if (r.rows == 0) return null;
    return try (try r.row(0)).get(?plzig.Numeric, 0);
$$;
```

* Parameters are text (`null` for SQL NULL); cast them in SQL (`$1::int`).
* `r.get(row, col)` returns the value's text representation copied into the
  arena (`null` for SQL NULL); `r.rows`, `r.columns`, `r.columnName(i)`.
* `r.row(i)` gives typed access to a row (see *Typed rows*).
* Only the most recent result is accessible.

**Prepared statements** — parsed and planned once, kept for the lifetime of
the function instance, executed with typed (binary) parameters:

```sql
CREATE FUNCTION order_total(customer int) RETURNS float8 STRICT LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };   // kept between calls
    if (S.plan == null)
        S.plan = try plzig.spi.prepare(
            "SELECT sum(amount)::float8 FROM orders WHERE customer = $1 AND note <> $2",
            &.{ .int4, .text });
    const r = try S.plan.?.execute(.{ customer, "test" });
    return try (try r.row(0)).get(?f64, 0);
$$;
```

* Parameter types: `.boolean`, `.int2`, `.int4`, `.int8`, `.float4`,
  `.float8`, `.text`, `.bytea`, `.date`, `.time`, `.timetz`, `.timestamp`,
  `.timestamptz`, `.interval`, `.uuid`, `.oid`, `.numeric`, `.jsonb`.
  Other types: declare `.text` and cast in SQL.
* Arguments are a tuple whose element types must match exactly: `bool`,
  `i16`, `i32`, `i64`, `f32`, `f64`, byte slices and string literals
  (`text`), `plzig.bytea(bytes)` (`bytea`), `plzig.Date` ... `plzig.Oid`,
  `plzig.Numeric`, `plzig.JsonText` (`jsonb`: JSON text, parsed by
  `jsonb_in`), optionals of these, or `null`. Values are range-checked like
  function results.
  Untyped numeric literals do not compile (write `@as(i32, 5)`); a type or
  count mismatch is an `ERROR`.
* A `Plan` belongs to the instance that prepared it (globals persist per
  function per session; an instance that raised an error starts over, and
  its plans are freed). At most `plzig.max_prepared_plans` (default 64)
  plans per instance; exceeding it is an error, not an eviction;
  `plan.free()` releases one.
* Plans are revalidated by PostgreSQL's plan cache after DDL or
  `search_path` changes (or fail cleanly if the query no longer makes
  sense); permissions are checked at every execution, as the current user.
  Read-only is decided at every execution from the function's volatility.

**Cursors** — rows one at a time, so large results do not have to fit in
memory:

```sql
CREATE FUNCTION big_sum() RETURNS bigint LANGUAGE plzig AS $$
    var cur = try plzig.spi.open("SELECT n, label FROM big WHERE n > $1::int", &.{"0"});
    defer cur.close();
    var sum: i64 = 0;
    while (try cur.next()) |row| {
        sum += try row.get(i32, 0);
        const label = try row.get(?[]const u8, 1);   // valid until the next next()
        _ = label;
    }
    return sum;
$$;
```

* `plzig.spi.open(sql, text_params)` or `plan.open(args)`; forward only,
  no scrolling, never `WITH HOLD`.
* **A Row and every slice obtained from it are invalid after the next
  `next()`** (the row lives in a per-cursor scratch buffer that is reused);
  copy what you need to keep (`plzig.allocator.dupe`).
* Cursors never outlive the call: every cursor still open when the call
  returns or fails is closed. Reaching the end closes the cursor; `close()`
  may be called again; `next()` after `close()` is `error.CursorClosed`.
* At most `plzig.max_open_cursors` (default 16) open cursors per call.
* The backend fetches 50 rows at a time from the portal.

**Typed rows** (`Result.row(i)`, `Cursor.next()`): `row.get(T, col)` with
`T` = `bool`, `i16`, `i32`, `i64`, `f32`, `f64` (the column type must be
exactly `boolean`, `smallint`, `integer`, `bigint`, `real`, `double
precision`), `plzig.Date`, `Time`, `TimeTz`, `Timestamp`, `TimestampTz`,
`Interval`, `Uuid`, `Oid`, `Numeric`, `Jsonb` (exactly that type; a
`Jsonb` from a cursor row is valid until the next `next()`), or
`[]const u8` (`text`/`varchar`/`char(n)` bytes, `bytea` bytes, or the text
representation of any other type, e.g. an array or a domain), or `?T` to
accept NULL. Nothing is converted: a different column
type is `error.TypeMismatch`, NULL into a non-optional
`error.UnexpectedNull`, a bad column `error.ColumnOutOfRange` (cast in SQL
instead: `count(*)::int4`). `row.kind(col)`, `row.isNull(col)`,
`row.len()`. A Row from `Result.row` is valid until the next `Result.row`.

The cursor commands `DECLARE`, `FETCH`, `MOVE` and `CLOSE` are refused in
SQL run by PL/Zig functions (use `plzig.spi.open`).

### Procedures and DO

```sql
CREATE PROCEDURE log_it(m text) LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("INSERT INTO log VALUES ($1)", &.{m});
$$;
CALL log_it('hello');

DO $$ plzig.notice("hi", .{}); $$ LANGUAGE plzig;
```

A `DO` block is compiled every time it runs; its module is never cached.

**Transaction control**: `plzig.commit()` and `plzig.rollback()` end the
current transaction and start a new one, as PL/pgSQL's `COMMIT` and
`ROLLBACK`, where PostgreSQL allows it: in a procedure called with `CALL`
outside a transaction block, or in a `DO` block outside one. Anywhere else
— in a function, inside `BEGIN ... COMMIT`, in a procedure called by a
function or through SPI (including from another procedure: PL/Zig's SPI
runs nested `CALL`s atomically), in a `SECURITY DEFINER` procedure or one
with a `SET` clause, in a trigger — PostgreSQL's own error `invalid
transaction termination` aborts the call.

```sql
CREATE PROCEDURE load_batches(n int) LANGUAGE plzig AS $$
    const ins = try plzig.spi.prepare("INSERT INTO t VALUES ($1)", &.{.int4});
    var i: i32 = 1;
    while (i <= n.?) : (i += 1) {
        _ = try ins.execute(.{i});           // prepared statements survive
        if (@mod(i, 1000) == 0) plzig.commit();
    }
$$;
CALL load_batches(100000);
```

* Every cursor of the call is closed at a commit or rollback (fetching from
  it afterwards is an error; closing it is fine), and the last SPI result
  is dropped (`Result.get`/`row` afterwards: no SPI result). Values the
  function copied into its own memory stay valid.
* An error during the commit (a deferred constraint, say) aborts the call;
  the instance is discarded like after any error (its globals start over).
* `COMMIT`/`ROLLBACK` as SQL through `plzig.spi.execute` stay refused.

### Using other PL/Zig functions (`//#use`)

A function can compile other PL/Zig functions into itself and call them as
plain Zig functions — no SPI, no conversion of arguments and results. It
declares each one in a directive line at the top of its body:

```sql
CREATE FUNCTION hashids.encode_list(numbers bigint[], salt text, min_length int, alphabet text)
RETURNS text STRICT LANGUAGE plzig AS $$ ... $$;

CREATE FUNCTION hashids.encode(n bigint, salt text) RETURNS text STRICT LANGUAGE plzig AS $$
//#use hashids.encode_list(bigint[], text, integer, text) as encode_list
    const list = try std.fmt.allocPrint(plzig.allocator, "{{{d}}}", .{n});
    return (try encode_list.call(list, salt, 0, "abcdefghijklmnopqrstuvwxyz")).?;
$$;
```

* The form is `//#use schema.function(argument types) as name`. The
  function is named like a `regprocedure` value (`'hashids.encode_list(bigint[],
  text, integer, text)'::regprocedure`) and **must be schema-qualified**; the
  `search_path` is never used (unqualified type names can only be built-in
  types). It is looked up again at every compilation, as the owner of the
  using function.
* Directive lines are lines whose first non-blank characters are `//#`.
  They must come before the first line of code (blank lines and `//`
  comments may precede them). They stay in the source as comments, so line
  numbers in compiler messages do not move. A malformed directive, an
  unknown one (`//#include`) or one after code is an error at `CREATE`.
* `name` is the used function as a Zig namespace. `name.call(...)` is the
  function itself, with exactly the Zig signature its body has when it is
  compiled on its own: plain parameter types for a `STRICT` function,
  optionals otherwise; the result is `anyerror!?T` (`anyerror!void` for
  `void`). So `try name.call(...)` propagates its Zig errors, and its
  `plzig.raise`, panics and SPI errors abort the call as the caller's own
  would.
* Whatever the used function declares `pub` after its body (functions,
  constants, types) is reachable as `name.declaration`, with its native Zig
  types: no conversion to SQL types and back. Declarations without `pub`
  stay private. This makes a function usable as a library:

  ```sql
  CREATE FUNCTION lib.clamp(x int) RETURNS int STRICT LANGUAGE plzig AS $$
      return clampTo(i32, x, 0, limit);
  }
  pub const limit = 100;
  pub fn clampTo(comptime T: type, v: T, lo: T, hi: T) T {
      return @max(lo, @min(hi, v));
  $$;

  CREATE FUNCTION lib.clamp8(x bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
  //#use lib.clamp(integer) as clamp
      return clamp.clampTo(i64, x, -clamp.limit, clamp.limit);
  $$;
  ```
* Each used function is compiled as a Zig module of its own, so its private
  helpers (code after its body) never clash with the user's. It may itself
  use other functions (at most 8 levels deep and 32 functions in all); a
  cycle between different functions is an error, while a function calling
  its own `call` recursively needs no directive. A function used through
  two paths is compiled in once.
* What can be used: PL/Zig functions (not procedures, aggregates, window,
  trigger or set-returning functions) with scalar parameters and result —
  no composite types, `OUT`/`INOUT`/`TABLE` parameters or domains (a
  domain's constraints would not be checked: compiled in, values are passed
  as Zig values). Types that cross the boundary as text (`inet`, arrays,
  ...) are plain `[]const u8` between the two functions, without the input
  function's check.
* **Restrictions** (a compiled-in call skips what a SQL-level call
  enforces; see *Security model*): the used function must have **the same
  owner** as the using one, that owner must hold `EXECUTE` on it, and it
  must not be `SECURITY DEFINER` or have `SET` clauses. Callers of the
  using function need no `EXECUTE` on the used one: its code is part of the
  using function, as if the owner had copied it in.
* It runs **inside the caller**: within the caller's memory
  (`plzig.max_memory`), stack and time limits (`statement_timeout`), with
  the caller's arena and SPI connection — so under the caller's read-only
  rule (from the caller's volatility, not its own) and, in a `SECURITY
  DEFINER` caller, as the caller's owner.
* A normal dependency on each directly used function is recorded, so `DROP
  FUNCTION` of a used function needs `CASCADE`, and `pg_dump` restores
  used functions first. Correctness does not depend on it: whenever a used
  function changes (body, owner, privileges, `SECURITY DEFINER`, `SET`,
  name, dropped) or a role membership changes, sessions that loaded the
  using function compile it again at its next call and re-run every check;
  if one fails, the call fails with that error. The module cache key covers
  the generated source of every compiled-in function, so a changed used
  function always yields a new module.
* With `check_function_bodies = off` (as `pg_restore` and `pg_upgrade` run)
  nothing is checked at `CREATE`; the dependency is recorded for each used
  function that exists. Everything is checked at the first call.
* Not available in `DO` blocks (an error): a block has no owner of its
  own, no dependencies and no cache entry.

Cost: a compiled-in call is an ordinary Zig function call inside the same
module; calling the same function through `plzig.spi` costs a query
(see `doc/benchmarks.md`, *Compiled-in calls*). The user's module grows by
the used functions' code, and each compilation compiles them too.

### Session state

Globals persist per function per session (and are never shared between
functions); an instance that raised an error is discarded, so its globals
start over.

### Not supported (by design, see PLAN.md D10)

Event triggers, set-returning functions in value-per-call mode,
`VARIADIC` parameters, polymorphic and other pseudo-types (except `void`
results and `record` described by output parameters), aggregates/window
functions, catching SQL errors, and any access to the clock,
randomness, environment, files or network from guest code (use SQL through
SPI: `SELECT now()`).

## Configuration (GUCs)

| Name | Context | Default | Purpose |
|------|---------|---------|---------|
| `plzig.zig_path` | `postgresql.conf` only | *(none)*; packages: their toolchain package's compiler | Absolute path of the Zig 0.17.1 compiler. Required for compiling; `PATH` is never searched. A build can compile in a default (`make PLZIG_DEFAULT_ZIG_PATH=...`); it gets the same checks as a configured value. |
| `plzig.zig_lib_dir` | `postgresql.conf` only | *(detect)* | Zig's `lib/` directory. Empty: `<compiler dir>/lib` (tarball layout) or `<compiler dir>/../lib/zig` (FHS layout, e.g. `/usr/bin/zig` + `/usr/lib/zig`). |
| `plzig.zig_sha256` | `postgresql.conf` only | *(empty)* | If set, the SHA-256 the compiler binary must have (hex). Covers the binary only, not `lib/`. |
| `plzig.compiler_sandbox` | `postgresql.conf` / reload | `require` | Confinement of the compiler (see *Security model*): `require` (refuse to compile unless Landlock ABI 6 or later **and** the seccomp filter are available), `try` (apply whatever is available and log once per backend exactly what is missing), `off` (neither). Set only in `postgresql.conf` (not `SET`, `ALTER SYSTEM`, per role or per database). Any other value, including the former `on`, boolean spellings and other letter case, makes every compilation fail until it is corrected. There is deliberately no setting to lower the required Landlock ABI. |
| `plzig.compile_timeout` | superuser | `30s` | Wall-clock limit per child run: version check, validator, compiler (min 100 ms, max 1 h). A cold first compile takes 2–3 s. |
| `plzig.compile_memory_limit` | superuser | `4GB` | `RLIMIT_AS` of the compiler (0 = none). Zig 0.17.1 needs about 1 GB. |
| `plzig.max_source_size` | superuser | `1MB` | Maximum function body size (max 3 MB). |
| `plzig.max_module_size` | superuser | `2MB` | Maximum size of a compiled module (16 kB – 16 MB); larger ones are rejected with `the compiled module is too large`. Applies to new compilations; large constant data is what makes modules big. |
| `plzig.cache_size_limit` | `postgresql.conf` / reload | `256MB` | Total size of `$PGDATA/plzig/cache/` (min 64 MB). Before a new module is stored, least recently used modules are evicted until it fits. |
| `plzig.max_memory` | superuser | `64MB` | Linear memory cap per function instance (max 1023 MB). Lowering it retires cached instances. |
| `plzig.instance_cache_size` | superuser | `64` | Idle instances kept per backend (0 = none). |
| `plzig.instance_cache_max_memory` | superuser | `4MB` | An instance whose linear memory grew beyond this (guest memory never shrinks) is destroyed after the call instead of being kept idle; its globals start over next time. |
| `plzig.max_prepared_plans` | superuser | `64` | Live prepared statements per function instance (0–10000). Preparing more is an error (no eviction). Lowering it does not free existing plans. |
| `plzig.max_open_cursors` | superuser | `16` | Simultaneously open cursors per function call (0–1000). Opening more is an error. |

"`postgresql.conf` only" means: not `SET`, not `ALTER ROLE/DATABASE ...
SET`, not `ALTER SYSTEM`; the value is hidden from non-superusers.

`plzig_sandbox_status()` (superuser only) tells how the last compilation in
the session was confined and what was missing, followed by the pinned Zig
version, e.g.
`enforced (landlock ABI 10, seccomp); Zig 0.17.1`,
`enforced (landlock ABI 6, seccomp; missing: Landlock ABI 6 lacks restrictions on pathname UNIX sockets and UDP); Zig 0.17.1`,
`partial (no landlock, seccomp; missing: Landlock is not available (landlock_create_ruleset returned -38): no filesystem confinement); Zig 0.17.1`,
`off (plzig.compiler_sandbox = off); Zig 0.17.1`
or `no compilation in this session; Zig 0.17.1`. `enforced` means what
`require` insists on.

`plzig_cache_clear()` (superuser only; `EXECUTE` revoked from `PUBLIC`)
removes every compiled module from the cache under the compile lock and
returns the number of files removed. Functions already loaded in a backend
keep running; everything else is recompiled on next use.

### Checking every function: `plzig_check_all()`

Function bodies are stored as source, so a function that compiled once can
stop compiling: after a Zig upgrade (a new PL/Zig major), after a composite
type it uses was altered, or after a dump/restore (which restores with
`check_function_bodies = off`). Such a failure would otherwise show only
at the first call. `plzig_check_all()` finds them in advance:

```sql
SELECT function, sqlstate, message, detail FROM plzig_check_all();
```

* It compiles every PL/Zig function, procedure and trigger function of the
  **current database** with the configured compiler, exactly as `CREATE
  FUNCTION` does with `check_function_bodies = on` (signature checks,
  policy validator, compiler, load check of the module), under the normal
  sandbox and the session's limits (`plzig.compile_timeout`,
  `plzig.max_module_size`, `plzig.max_memory`, ...).
* It **executes no function**. Loading a module instantiates it and calls
  only the SDK's two set-up exports (ABI version, argument buffer), never
  the function body.
* It returns one row per failing function (`function regprocedure,
  sqlstate, message, detail`; `detail` holds the compiler's output), none
  if everything compiles.
* Each function is compiled in its own subtransaction and through the
  normal compile lock, one after another, so other sessions' compilations
  interleave with the run. A function dropped during the run is skipped;
  one replaced during the run is checked as it is now (each function is
  locked against `DROP` while it is compiled).
* A query cancel or `statement_timeout` ends the whole run with that error
  (it is not reported as a failing function); a function that exceeds
  `plzig.compile_timeout` is reported (`57014`, `PL/Zig compilation timed
  out`).
* **The module cache is used as by a call.** A function whose module is
  already cached is not recompiled: the cache key covers the PL/Zig ABI,
  the pinned Zig version, the compiler flags, the SDK and the whole
  generated source (including the structs generated from composite types),
  so a cached module is exactly what this compiler would produce. A module
  compiled during the run is stored only after it passed the load check:
  functions that fail leave nothing in the cache, functions that succeed
  are ready for their first call. On a large database the run may evict
  older modules (`plzig.cache_size_limit`).
* Superuser only: `EXECUTE` is revoked from `PUBLIC` (it runs the
  compiler on every function body). A superuser may delegate it with
  `GRANT EXECUTE ON FUNCTION plzig_check_all() TO ...`; function bodies are
  readable by everyone in `pg_proc` anyway.

Run it in each database that has PL/Zig functions, e.g. on a staging copy
before upgrading PL/Zig, and again after the upgrade.

## Security model

This section is the operator's summary. The threat model, every defence
with what it relies on, and the residual risks are in
[`doc/security.md`](doc/security.md).

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

**Functions compiled into others** (`//#use`) skip what a SQL call checks,
so only functions with the same owner, which that owner may execute and
which are neither `SECURITY DEFINER` nor have `SET` clauses, can be
compiled in; references are schema-qualified literals resolved as the
owner (never through the session's `search_path`) and checked again at
every compilation, and sessions notice every change of a used function
(*Using other PL/Zig functions*; `doc/security.md` §4.13).

**Defence in depth.** Before compiling, `plzig-validate` (built on the
compiler's own tokenizer) rejects `@import` of anything but `"plzig"` (and
the host-chosen names of the functions a file uses), every
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
`RLIMIT_CORE=0`, CPU/file-size/address-space limits and a wall-clock
timeout. It is killed (whole process group) and reaped on every exit path,
including cancel, `ERROR` and backend exit, and gets `SIGKILL` if the
backend dies (`PR_SET_PDEATHSIG`). Compilations are serialised
cluster-wide with a file lock. Two independent mechanisms confine it, and
`require` (the default) insists on both:

* **Landlock** (kernel feature, by ABI version):
  * ABI 1+: execute+read only on the compiler binary and the validator
    binary themselves (file rules, not their directories), read-only on
    the Zig `lib/` directory (passed explicitly with `--zig-lib-dir`),
    read-write only on its private build directory and the shared Zig
    cache — create/remove regular files and directories, but no symbolic
    links, sockets, FIFOs or device nodes; `/dev/null` read/write;
    nothing else in the filesystem;
  * ABI 2+: renames across directories are allowed within those
    directories (ABI 1 refuses them all, which breaks Zig's cache); ABI 3+:
    truncating files elsewhere is denied; ABI 4+: no TCP bind/connect;
    ABI 5+: no device ioctls; ABI 6+: no signals to, and no abstract UNIX
    sockets of, processes outside the sandbox; ABI 9+: no connections to
    pathname UNIX sockets created outside it (e.g. the server's own
    socket); ABI 10+: no UDP bind/send. ABIs 7 and 8 add no access rights.
  * `require` needs ABI 6 or later. Below ABI 3, `truncate(2)` by path is
    **not** mediated by Landlock: a compromised compiler could truncate
    any file the server OS user can write, data files included.
* **seccomp filter** (installed in the child before `execve`, x86_64 and
  aarch64 only; other architectures count as "unavailable"): denied with
  `EPERM` are all socket calls (`socket`, `socketpair`, `connect`, `bind`,
  `listen`, `accept*`, `send*`/`recv*`, socket options), `ptrace`,
  `process_vm_readv/writev`, `kcmp`, `pidfd_open/getfd/send_signal`,
  `process_madvise`, `setsid`, `setpgid`, System V IPC (`shm*`, `sem*`,
  `msg*`), `mount`, `umount2`, `pivot_root`, `chroot`, the new mount API,
  `unshare`, `setns`, `clone` with namespace flags or `CLONE_PARENT`,
  `bpf`, `perf_event_open`, `io_uring_*`, `userfaultfd`, `keyctl`,
  `add_key`, `request_key`, `kexec_*`, `init_module`, `finit_module`,
  `delete_module`, `open_by_handle_at`, `personality`, and
  `fcntl(F_SETOWN/F_SETOWN_EX/F_SETSIG)`; `kill`, `tkill`, `tgkill`,
  `rt_sigqueueinfo`, `rt_tgsigqueueinfo` only towards the compiler's own
  pid; `clone3` fails with `ENOSYS` (callers fall back to `clone`, whose
  flags can be checked); system calls of another architecture or ABI
  (x32, i386) are denied. Because `setsid`/`setpgid` are denied, no
  descendant can leave the process group the backend kills.

What remains uncovered even with both: the compiler can still read
everything under the Zig `lib/` directory, read and write the shared Zig
cache (see below), use CPU and memory up to the limits, and fork and
re-execute itself (it runs its own linker that way); it can learn its own
build directory path. The kernel interfaces that stay allowed (file I/O in
the allowed directories, `mmap`, threads, futexes, pipes) are the
compiler's attack surface on the kernel. A worker thread of the compiler
that aborts ends with `SIGSEGV` instead of `SIGABRT` (Zig's `abort` falls
back to a null write when `tkill` towards its own thread id is refused).

**The toolchain checks.** Before the configured compiler is run for the
first time in a backend (and again whenever a setting or the identity of
the binary or lib directory changes), PL/Zig:

* requires `plzig.zig_path` (configured, or the compiled-in default of a package) to be set and absolute (`PATH` is never
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
addressed, written via `O_EXCL` temp file + fsync + `durable_rename`; the
temp file is removed on every failure), `pgsql_tmp.zig-cache/` (the
compiler's cache; skipped by base backups) and short-lived
`pgsql_tmp.build.<pid>.<n>.<random>/` directories. Modules read from the
cache must be regular 0600 files owned by the server user and opened with
`O_NOFOLLOW`; they are re-validated (imports, exports, ABI) on every load.

The cache is bounded by `plzig.cache_size_limit`. When a module is stored
(under the compile lock), leftover temp files are removed and the least
recently used modules are evicted until the new one fits; a cache hit
refreshes the file's modification time (at most once a minute), which is
what "recently used" means — a function that stays loaded in a long-lived
backend is not re-read, so it can be evicted and is then recompiled by the
next backend that needs it. Only regular files directly in `cache/` whose
names match the cache patterns are ever removed. Rolled-back
`CREATE FUNCTION`s and dropped functions still leave their module until it
is evicted; `DO` blocks never write to the cache.

Build directories are removed with a descriptor-relative walk that never
follows symbolic links or crosses into another file system. Leftover build
directories (from a backend that died, or whose cleanup failed) are removed
by the next compilation: every compilation holds the cluster-wide compile
lock from creating its build directory to removing it, so with the lock
held any other build directory is stale, whatever its pid.

Messages that can reach a client never contain the data directory: paths
under it are shown relative to it (e.g. `plzig/cache/…`), and the full
path goes to the server log only.

**Limits — read these.**

* If Landlock is unavailable or older than ABI 6, or the seccomp filter
  cannot be installed (other architecture, kernel without
  `CONFIG_SECCOMP_FILTER`, or a container profile that forbids it), the
  default `require` refuses every compile and says what is missing (cached
  modules keep running). `try` then compiles with what is available and
  logs once per backend what is missing. Without Landlock the compiler has
  **no filesystem confinement**: a compiler exploit could read and write
  every file of the `postgres` OS user (the seccomp filter still blocks
  networking, signals to other processes and the other calls listed
  above). Without seccomp, Landlock below ABI 9/10 leaves pathname UNIX
  sockets (the server's own socket: `peer`/`trust` authentication would
  make that a superuser connection) and UDP open, and nothing then stops
  System V IPC, `setsid` or namespace creation. Check
  `plzig_sandbox_status()`.
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
  can keep the compiler busy. Disk use is bounded by
  `plzig.max_module_size` per module, `plzig.cache_size_limit` for the
  cache and the 256 MB file-size limit per file written by a running
  compile; the Zig cache does not grow per distinct function (it holds
  the standard library's compiled forms, about 45 MB).
* Idle cached instances are bounded by `plzig.instance_cache_size` and
  `plzig.instance_cache_max_memory` (default: at most 64 × 4 MB per
  backend between statements).
* Runtime resource use is bounded per instance (`plzig.max_memory`), but a
  function recursing through SPI creates one instance per level, and
  `spi.execute` results are fully materialised (cursors are not: at most 50
  rows per cursor are held); like PL/pgSQL, a determined user can use a lot
  of backend memory and CPU within `statement_timeout`. Prepared statements
  are kept in backend memory for the life of their instance (up to
  `plzig.max_prepared_plans` per instance, and `plzig.instance_cache_size`
  idle instances).
* Guest code can write to the server log via `plzig.print(.log, …)`, like
  `RAISE LOG` in PL/pgSQL.
* WAMR is a large C code base running in the backend; a bug in its
  validator or interpreter would be a sandbox escape. The build disables
  every optional feature (AOT/JIT, WASI, threads, SIMD, GC, multi-module…)
  to keep that surface small, and modules that declare more memory than `plzig.max_memory` can
  ever allow, or absurd numbers of locals or table elements (about 1 GB of
  work for a few bytes of module), are refused before WAMR loads them.
* The compiler has no process-count or memory-cgroup limit and no disk
  quota beyond the per-file size limit: a compiler exploit could fork many
  processes or fill the file system holding `$PGDATA` within the compile
  timeout. Run the server under a cgroup (`TasksMax=`, `MemoryMax=`) and
  keep `pg_wal` on its own file system (doc/security.md §8).

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
under its own license. The separate `plzig-zig-toolchain` package
repackages the official build (license `MIT AND Apache-2.0 WITH
LLVM-exception AND NCSA AND Zlib AND BSD-3-Clause`, see
`packaging/zig-toolchain/NOTICE`). Source tarballs made by `make dist`
contain neither Zig nor the benchmark suite (`bench/`). WebAssembly modules compiled from your functions
contain MIT-licensed code from the Zig standard library and compiler
runtime, which only matters if you redistribute those modules.

PL/Zig is an independent project and is not affiliated with or endorsed by
the PostgreSQL project, the Zig Software Foundation or the Bytecode Alliance.
