# PL/Zig host/guest ABI (version 1)

This describes the interface between the PostgreSQL backend (host, `src/`)
and a compiled PL/Zig function (guest, a `wasm32-freestanding` module built
from `zig/sdk/root.zig` + `zig/sdk/plzig.zig` + the generated `user.zig`).
It is what the code implements, not a wish list. All integers are little
endian; guest pointers are 32-bit offsets into the guest's linear memory.

## Module shape

The compiler is invoked as (fixed argv, see `plzig_zig_flags` in
`src/plzig_build.c`):

`zig` is the binary named by `plzig.zig_path` (resolved, and checked to
report exactly the Zig version the validator was built with, see README).

```
zig build-exe --global-cache-dir <PGDATA>/plzig/pgsql_tmp.zig-cache --cache-dir .zig-cache
    --zig-lib-dir <checked Zig lib directory>
    --color off -fno-reference-trace -target wasm32-freestanding -mcpu mvp
    -O ReleaseSafe -fstrip -fno-entry -fsingle-threaded --stack 262144
    --export=plzig_abi_version --export=plzig_begin --export=plzig_alloc --export=plzig_call
    --dep plzig --dep user -Mroot=sdk/root.zig --dep plzig -Muser=src/user.zig
    -Mplzig=sdk/plzig.zig --name plzig_module -femit-bin=out.wasm
```

A module is accepted by the loader (`plzig_module_load`) only if

* WAMR's loader validates it (full validation, classic interpreter);
* every import is a **function** imported from module **`plzig`**, its name
  is one of the host functions below, and WAMR linked it (i.e. the
  signature matched the registered one) — anything else is rejected;
* it instantiates under the current `plzig.max_memory`;
* it exports a linear memory and the four functions below with the listed
  parameter/result counts;
* `plzig_abi_version()` returns `1`.

Size limit for the module file: 16 MB.

## Guest exports

| Export | Signature | Meaning |
|--------|-----------|---------|
| `plzig_abi_version` | `() -> i32` | Returns 1. |
| `plzig_begin` | `() -> ()` | Start of a call: resets the per-call arena (everything allocated by the previous call is released). |
| `plzig_alloc` | `(len: i32) -> i32` | Allocate `len` bytes, 8-byte aligned, in the per-call arena. 0 on failure. |
| `plzig_call` | `(args: i32, nargs: i32, result: i32) -> i32` | Run the user function. `args` points to `nargs` slots, `result` to one slot. Returns a status. |

Status codes of `plzig_call`: `0` = ok (result slot filled), `1` = the
user function returned a Zig error; the result slot then holds the error
name (`val` = pointer, `len` = length). Any other value is rejected by the
host.

### Slot (16 bytes, `extern struct`)

| Offset | Field | Type |
|--------|-------|------|
| 0 | `val` | u64 |
| 8 | `len` | u32 |
| 12 | `is_null` | u32 (0/1) |

Encoding of `val`/`len` by SQL type class:

| Class (SQL types) | Zig type | Encoding |
|-------------------|----------|----------|
| `boolean` | `bool` | `val` = 0/1 |
| `smallint`, `integer`, `bigint` | `i16`, `i32`, `i64` | `val` = value sign-extended to 64 bits |
| `real` | `f32` | low 32 bits of `val` = IEEE-754 bits |
| `double precision` | `f64` | `val` = IEEE-754 bits |
| `text`, `varchar`, `bpchar`, `bytea`, everything else | `[]const u8` | `val` = pointer, `len` = byte length |

For non-`bytea` byte types the bytes are: the detoasted value for
`text`/`varchar`/`bpchar` (database encoding, not NUL-terminated); the
output-function result for all other types. A zero-length slice may carry a
dangling pointer; the host never dereferences or validates pointers when
`len` is 0.

Results: `text` bytes must be valid in the database encoding and contain no
NUL (checked with `pg_verifymbstr`); `varchar`, `bpchar` and all text-I/O
types are additionally passed through the type's input function (so domain
constraints, enum labels, array syntax etc. are enforced by PostgreSQL);
`bytea` is copied verbatim.

### Call sequence (host side, `plzig_instance_call`)

1. `check_stack_depth()`; set the exec-env user data to the call context.
2. `plzig_begin()`.
3. Compute the argument block size: `(nargs + 1) * 16` plus every byte
   argument rounded up to 8; `plzig_alloc(total)`. 0 → `ERROR` (out of
   guest memory).
4. Validate `[base, base+total)` with `wasm_runtime_validate_app_addr`, write
   the slots, then the byte payloads after them; the result slot is the
   slot right after the arguments. The native pointer is not used after
   this step (the guest may grow, and so move, its memory).
5. `plzig_call(base, nargs, base + nargs*16)`.
6. If the call trapped: if a host import stashed an `ErrorData`, re-throw
   it; if the trap is the interrupt trap, run `CHECK_FOR_INTERRUPTS()` and
   otherwise raise `57014`; else raise `38000 PL/Zig function trapped: <WAMR message>`.
7. Re-validate and copy out the result slot; status 1 → `ERROR: plzig
   function failed: <name>` (`38000`; name truncated to 256 bytes,
   non-printable bytes replaced by `?`).
8. Convert the result (copying out of guest memory), `SPI_finish()` if SPI
   was used, delete the per-call memory context.

An instance whose call ended in any `ERROR` is destroyed. Idle instances are
kept per function (LRU, `plzig.instance_cache_size`); an instance created
under a different `plzig.max_memory` is not reused. A recursive call into a
function that is already running uses a temporary second instance.

## Host imports (module `plzig`)

Registered with `wasm_runtime_register_natives` (signature strings in
parentheses). Every import:

* runs its work inside `PG_TRY`; on `ERROR` it copies the `ErrorData` into
  the call context, sets a WAMR exception (so the guest traps as soon as the
  import returns) and returns; the call handler re-throws once
  `wasm_runtime_call_wasm` has returned — `ereport(ERROR)` never longjmps
  through interpreter frames, and the guest can neither observe nor swallow
  the error;
* traps immediately if called outside a call (e.g. during instantiation) or
  after an error has already been stashed;
* validates every pointer/length pair before use and copies data out.

| Import | Signature | Semantics |
|--------|-----------|-----------|
| `log(level, ptr, len)` | `(iii)` | `level` 0..4 = `DEBUG1`, `LOG`, `INFO`, `NOTICE`, `WARNING`; anything else is an error. Message truncated to 64 kB; must be valid in the database encoding (no NUL). |
| `raise(ptr, len)` | `(ii)` | `ERROR` with SQLSTATE `P0001` and the given message (64 kB max). Does not return to the guest. |
| `panic(ptr, len)` | `(ii)` | Zig panic handler (safety-check failures, `@panic`, `unreachable`): `ERROR` `38000` `PL/Zig panic: <msg>` (1 kB max). |
| `spi_execute(sql_ptr, sql_len, params_ptr, nparams)` | `(iiii)I` | Runs one SQL statement with `SPI_execute_with_args`; `params_ptr` points to `nparams` (≤ 65535) slots, each `is_null` or a text value (`val`/`len`); all parameter types are `text` (cast in SQL: `$1::int`). `read_only` is true unless the function is `VOLATILE` (`DO` blocks are volatile). The SPI connection is opened lazily (atomic, so no transaction control) and closed at the end of the call. Returns `SPI_processed` (capped at `INT64_MAX`). Any SQL error aborts the call. The previous result is freed. |
| `spi_ncols()` | `()i` | Number of columns of the last result (0 if none). |
| `spi_value_len(row, col)` | `(ii)i` | Length of the text representation of the 0-based (row, col) of the last result, `-1` for NULL. Out-of-range → `ERROR`. |
| `spi_value_copy(row, col, buf, buf_len)` | `(iiii)i` | Copy up to `buf_len` bytes of that value into guest memory; returns bytes copied (`-1` for NULL). |
| `spi_colname_len(col)` | `(i)i` | Length of the column name. Out-of-range → `ERROR`. |
| `spi_colname_copy(col, buf, buf_len)` | `(iii)i` | Copy up to `buf_len` bytes of the column name; returns bytes copied. |

Values are produced with `SPI_getvalue` (type output functions); a one-entry
cache avoids converting a value twice for `len` + `copy`.

There are deliberately no imports for time, randomness, environment, files,
network, threads or memory management; guest memory grows only through the
`memory.grow` instruction, bounded by `plzig.max_memory`.

## Guest SDK (`plzig` module) summary

* `plzig.allocator` — the only allocator: a bump arena over the linear
  memory above the module's initial size, reset at the start of every call;
  `free`/`resize` work for the most recent allocation; `error.OutOfMemory`
  when `memory.grow` fails.
* `plzig.print(level, fmt, args)`, `debug`, `info`, `notice`, `warning`.
* `plzig.raise(fmt, args) noreturn`, `plzig.raiseMsg(msg) noreturn`.
* `plzig.spi.execute(sql, params: []const ?[]const u8) !Result`;
  `Result.rows`, `Result.columns`, `Result.get(row, col) !?[]const u8`,
  `Result.columnName(col) ![]const u8`. Only the most recent result is
  accessible.
* `plzig.std` (also predeclared as `std`): `mem`, `fmt`, `math`, `ascii`,
  `unicode`, `sort`, `hash`, `hash_map`, `meta`, `base64`, `enums`,
  `bit_set`, `ArrayList`, the hash maps, `StaticStringMap`,
  `MultiArrayList`, `PriorityQueue`, `EnumMap`, `EnumSet`, `Allocator`.

## Generated `user.zig`

```zig
const plzig = @import("plzig"); const std = plzig.std; pub fn call(@"a": i32, @"b": ?[]const u8) anyerror!?i32 { _ = &@"a"; _ = &@"b";
<function body, verbatim>
}
```

* One header line, so compiler line N is body line N-1 (the host rewrites
  `src/user.zig:N:C:` to `line N-1, column C:` in diagnostics).
* `STRICT` → plain parameter types, otherwise optionals.
* Return type `anyerror!?T`, or `anyerror!void` for `void` and procedures.
* Parameter names must match `[A-Za-z_][A-Za-z0-9_]*` and must not be
  `plzig` or `std`; unnamed parameters are `arg1..argN`.
* `DO` blocks: `pub fn call() anyerror!void {`.

## Interrupts

The vendored WAMR is patched (`third_party/wamr-interrupt.patch`) so that
the classic interpreter's `CHECK_SUSPEND_FLAGS()` — evaluated at every
`br`, `br_if`, `br_table`, call and function entry — reads
`wamr_plzig_interrupt_flags[0..1]`, which the host points at
`QueryCancelPending` and `ProcDiePending`. When either is set the guest
traps with the exception `plzig: interrupted`, and the host runs
`CHECK_FOR_INTERRUPTS()`.
