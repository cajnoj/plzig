# PL/Zig host/guest ABI (version 2)

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
  is one of the 19 host functions below, and WAMR linked it (i.e. the
  signature matched the registered one) — anything else is rejected;
* it instantiates under the current `plzig.max_memory`;
* it exports a linear memory and the four functions below with the listed
  parameter/result counts;
* `plzig_abi_version()` returns `2` (`PLZIG_ABI_VERSION`; the version is
  part of the module cache key, so modules built for version 1 are
  recompiled, never loaded).

Size limit for the module file: 16 MB.

## Guest exports

| Export | Signature | Meaning |
|--------|-----------|---------|
| `plzig_abi_version` | `() -> i32` | Returns 2. |
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
8. Convert the result (copying out of guest memory); close every cursor
   the guest left open, then `SPI_finish()` if SPI was used
   (`plzig_host_finish_call`); delete the per-call memory context.

An instance whose call ended in any `ERROR` is destroyed, with its prepared
statements. Idle instances are
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
* validates every pointer/length pair before use (sizes computed in 64 bits
  or bounded first), copies data out, and never keeps a native pointer into
  guest memory across anything that could run guest code;
* validates every handle on every use (*Handles*).

19 imports, the complete list (the loader's allowlist,
`plzig_known_imports` in `src/plzig_runtime.c`, and the registration table
in `src/plzig_host.c` must match):

| Import | Signature | Semantics |
|--------|-----------|-----------|
| `log(level, ptr, len)` | `(iii)` | `level` 0..4 = `DEBUG1`, `LOG`, `INFO`, `NOTICE`, `WARNING`; anything else is an error. Message truncated to 64 kB; must be valid in the database encoding (no NUL). |
| `raise(ptr, len)` | `(ii)` | `ERROR` with SQLSTATE `P0001` and the given message (64 kB max). Does not return to the guest. |
| `panic(ptr, len)` | `(ii)` | Zig panic handler (safety-check failures, `@panic`, `unreachable`): `ERROR` `38000` `PL/Zig panic: <msg>` (1 kB max). |
| `spi_execute(sql_ptr, sql_len, params_ptr, nparams)` | `(iiii)I` | Runs one SQL string with `SPI_execute_with_args`; `params_ptr` points to `nparams` (≤ 65535) slots, each `is_null` or a text value (`val`/`len`); all parameter types are `text` (cast in SQL: `$1::int`). `read_only` is true unless the function is `VOLATILE` (`DO` blocks are volatile). The SPI connection is opened lazily (atomic, so no transaction control) and closed at the end of the call. Returns `SPI_processed` (capped at `INT64_MAX`). Any SQL error aborts the call. The previous result is freed. |
| `spi_ncols()` | `()i` | Number of columns of the last result (0 if none). |
| `spi_value_len(row, col)` | `(ii)i` | Length of the text representation of the 0-based (row, col) of the last result, `-1` for NULL. Out-of-range → `ERROR`. |
| `spi_value_copy(row, col, buf, buf_len)` | `(iiii)i` | Copy up to `buf_len` bytes of that value into guest memory; returns bytes copied (`-1` for NULL). |
| `spi_colname_len(col)` | `(i)i` | Length of the column name. Out-of-range → `ERROR`. |
| `spi_colname_copy(col, buf, buf_len)` | `(iii)i` | Copy up to `buf_len` bytes of the column name; returns bytes copied. |
| `spi_row_size(row)` | `(i)I` | Select row `row` of the last result for typed reading and return the size of its encoding (see *Rows*). Out-of-range or no result → `ERROR`. |
| `spi_row_read(row, buf, buf_len)` | `(iii)i` | Write the encoding of row `row` to `[buf, buf + buf_len)`; `buf_len` must be at least the size. Returns the number of columns. |
| `spi_prepare(sql_ptr, sql_len, types_ptr, ntypes)` | `(iiii)I` | Prepare `sql` with `ntypes` (≤ 65535) parameters; `types_ptr` points to `ntypes` u32 type codes `1`..`8` (*Kinds*), anything else → `ERROR`. The host maps the codes to fixed type OIDs; the guest never supplies an OID. `SPI_prepare_cursor(..., CURSOR_OPT_NO_SCROLL)` + `SPI_keepplan`; the plan goes into the calling instance's plan table. More than `plzig.max_prepared_plans` live plans in the instance → `ERROR` (no eviction). Returns a plan handle (never 0). |
| `spi_plan_free(plan)` | `(I)` | Free a plan (`SPI_freeplan`); the handle is invalid afterwards. |
| `spi_execute_plan(plan, params_ptr, nparams)` | `(Iii)I` | Execute a plan with `nparams` typed values (*Values*); `nparams` must equal the plan's parameter count and each value's `kind` must equal the kind of the plan's parameter type (`SPI_getargtypeid`), or be `0` with `is_null` = 1. Values must be in range for the type (`int2`/`int4` sign-extended within range, `bool` 0/1, `float4` upper 32 bits zero); text must be valid in the database encoding without NUL. `read_only` as for `spi_execute`, decided at every execution. The result replaces the last result. Returns `SPI_processed`. |
| `spi_cursor_open(sql_ptr, sql_len, params_ptr, nparams)` | `(iiii)I` | Open a cursor on `sql` with text parameters (as `spi_execute`): `SPI_cursor_open_with_args(NULL, ..., read_only, CURSOR_OPT_NO_SCROLL)`. More than `plzig.max_open_cursors` open cursors in this call → `ERROR`. Returns a cursor handle (never 0). |
| `spi_cursor_open_plan(plan, params_ptr, nparams)` | `(Iii)I` | Open a cursor on a plan with typed values (checked as for `spi_execute_plan`): `SPI_cursor_open(NULL, plan, ..., read_only)`. Only plans that return rows (`SELECT`, `... RETURNING`) can be opened. |
| `spi_cursor_next(cursor)` | `(I)I` | Advance to the next row and return the size of its encoding, or `-1` at the end. Rows are fetched from the portal `PLZIG_CURSOR_BATCH` (50) at a time with `SPI_cursor_fetch(portal, forward, 50)`; the previous batch is freed first. At the end the portal is closed (the handle stays valid until `spi_cursor_close`). |
| `spi_cursor_read(cursor, buf, buf_len)` | `(Iii)i` | Write the encoding of the current row to `[buf, buf + buf_len)` (`buf_len` ≥ size, else `ERROR`; no current row → `ERROR`). Returns the number of columns. |
| `spi_cursor_close(cursor)` | `(I)` | Close the cursor and free its handle. |

Text values of `spi_value_*` are produced with `SPI_getvalue` (type output
functions); a one-entry cache avoids converting a value twice for `len` +
`copy`.

SQL passed to `spi_execute`, `spi_prepare` and `spi_cursor_open` is
raw-parsed first, and the cursor commands `DECLARE` (in particular `WITH
HOLD`), `FETCH`, `MOVE` and `CLOSE` are refused (`0A000`): cursors are
available only through `spi_cursor_*`, which never outlive the call, and
SQL must not reach portals the function did not open. (Syntax errors from
this pre-parse are reported like SPI reports them.)

### Kinds

Value kinds (`u16`), shared by parameters and result columns:

| Code | Kind | Parameter type (OID the host uses) | Result columns of type | Encoding of `val`/`len` |
|------|------|--------------------|-----------------------|----------|
| 0 | null | parameters only: SQL NULL of any type (`is_null` = 1) | – | – |
| 1 | boolean | `boolean` | `boolean` | `val` = 0/1 |
| 2 | int2 | `smallint` | `smallint` | `val` = value sign-extended to 64 bits |
| 3 | int4 | `integer` | `integer` | same |
| 4 | int8 | `bigint` | `bigint` | same |
| 5 | float4 | `real` | `real` | low 32 bits of `val` = IEEE-754 bits |
| 6 | float8 | `double precision` | `double precision` | `val` = IEEE-754 bits |
| 7 | text | `text` | `text`, `varchar`, `bpchar` | `val` = pointer, `len` = bytes of the (detoasted) value, database encoding |
| 8 | bytea | `bytea` | `bytea` | `val` = pointer, `len` = byte length |
| 9 | other | – (pass text, cast in SQL) | every other type (exact OID match, so domains too) | `val` = pointer, `len` = length of the type's text output |

The kind of a result column is derived by the host from the actual tuple
descriptor of the result (`TupleDescAttr(...)->atttypid`), separately for
every result and every cursor; it is never taken from the guest.

### Value (16 bytes, `extern struct`)

| Offset | Field | Type |
|--------|-------|------|
| 0 | `val` | u64 |
| 8 | `len` | u32 |
| 12 | `kind` | u16 |
| 14 | `is_null` | u16 (0/1) |

### Rows

`spi_row_read` and `spi_cursor_read` write a row as `ncols` Values followed
by the bytes of the byte-kind values (kinds 7–9), each starting 8-byte
aligned; their `val` holds the guest address of the bytes. Size =
`16 * ncols` + the sum of the byte lengths rounded up to 8, at most
`MaxAllocSize` (larger rows → `ERROR`). The host converts the row when it is
selected (`spi_row_size`, `spi_cursor_next`: detoasting, output functions)
into a per-row context that is reset for the next row, so its size is known
before the guest provides a buffer, and copies it when the guest reads it.
Rows with 0 columns have size 0.

### Handles

Plan and cursor handles are u64: `serial << 16 | index`. `index` selects an
entry of a table that belongs to the calling instance (plans) or to the
current call (cursors); `serial` is taken from a per-backend counter that
starts at a random value and only increases, and is stored in the entry. A
handle is accepted only if `serial` ≠ 0, `index` is inside the table, the
entry is in use and its serial matches; anything else is `ERROR` (`invalid
prepared statement handle` / `invalid cursor handle`). So a handle can never
reach a plan of another instance (another function, or the temporary
instance of a recursive call) or a cursor of another call, and a freed or
stale handle never matches a reused entry. No host pointer and no portal
name crosses the boundary.

### Lifetimes

* **Plans** live in `CacheMemoryContext` (`SPI_keepplan`), referenced only
  from the instance's plan table (in the `PL/Zig runtime` context). They
  are freed by `spi_plan_free` or by `plzig_host_free_plans()`, which
  `plzig_instance_destroy()` calls on every path that ends an instance:
  error or trap (`plzig_function_execute`), LRU eviction (`plzig_lru_trim`),
  `plzig.instance_cache_max_memory`, function replaced or dropped
  (`plzig_function_free`), `plzig.max_memory` changed, end of a `DO` block,
  temporary instances of recursive calls. Nothing frees plans at backend
  exit. Plans are re-validated by the plan cache (DDL, `search_path`, role
  changes), and permissions are checked at every execution, as the current
  user. A portal opened from a plan holds its own reference to the cached
  plan, so freeing the plan while the cursor is open is safe.
* **Cursors** live in a per-call table (in the `PL/Zig call` context). The
  portal is unnamed (`<unnamed portal N>`), pinned (`PinPortal`, so
  `CLOSE`/`CLOSE ALL` from nested code fails with `cannot drop pinned
  portal`), forward-only (`CURSOR_OPT_NO_SCROLL`), not holdable, and looked
  up by name and compared with the original pointer on every use. When the
  call returns, `plzig_host_finish_call()` unpins and closes every cursor
  still open, before `SPI_finish`. When the call fails, the transaction or
  subtransaction abort drops the portals (and the SPI connection). At most
  `plzig.max_open_cursors` cursors are open per call (closed and exhausted
  cursors do not count).
* **Batches and rows**: each cursor holds at most one fetched batch
  (an `SPITupleTable` owned by the call's SPI connection, freed before the
  next fetch, at close, or by `SPI_finish`) and one converted row (per-row
  context); typed rows of the last result use one per-row context too.
  Per-import temporary data (copied SQL, parameters) lives in a scratch
  context reset by every SPI import. Host memory therefore does not grow
  with the number of rows or executions.

There are deliberately no imports for time, randomness, environment, files,
network, threads, memory management or transaction control; guest memory
grows only through the `memory.grow` instruction, bounded by
`plzig.max_memory`.

## Guest SDK (`plzig` module) summary

* `plzig.allocator` — the only allocator: a bump arena over the linear
  memory above the module's initial size, reset at the start of every call;
  `free`/`resize` work for the most recent allocation; `error.OutOfMemory`
  when `memory.grow` fails.
* `plzig.print(level, fmt, args)`, `debug`, `info`, `notice`, `warning`.
* `plzig.raise(fmt, args) noreturn`, `plzig.raiseMsg(msg) noreturn`.
* `plzig.spi.execute(sql, params: []const ?[]const u8) !Result`;
  `Result.rows`, `Result.columns`, `Result.get(row, col) !?[]const u8`
  (text, copied into the arena), `Result.row(i) !Row` (typed, see below),
  `Result.columnName(col) ![]const u8`. Only the most recent result is
  accessible.
* `plzig.spi.prepare(sql, types: []const Type) !Plan` with `Type` =
  `.boolean, .int2, .int4, .int8, .float4, .float8, .text, .bytea`;
  `Plan.execute(args) !Result`, `Plan.open(args) !Cursor`, `Plan.free()`.
  `args` is a tuple of `bool`, `i16`, `i32`, `i64`, `f32`, `f64`, byte
  slices / string literals (text), `plzig.bytea(bytes)` (bytea), optionals
  of these, or `null`; values are encoded on the stack (no arena use). An
  untyped numeric literal is a compile error. The `Plan` struct holds only
  the handle and may be kept in a global.
* `plzig.spi.open(sql, params: []const ?[]const u8) !Cursor`;
  `Cursor.next() !?Row` (`error.CursorClosed` after `close`), `Cursor.close()`.
  The SDK closes the cursor when `next` reaches the end. Each Cursor has a
  scratch buffer in the arena that grows to the largest row seen and is
  reused for every row, so a Row and all slices from it are invalid after
  the next `next()`. `Result.row` uses one such buffer shared by all
  Results (invalid after the next `Result.row`; reset with the arena).
* `Row.len()`, `Row.kind(col) !Kind`, `Row.isNull(col) !bool`,
  `Row.get(T, col)` with `T` = `bool`, `i16`, `i32`, `i64`, `f32`, `f64`
  (column kind must match exactly), `[]const u8` (kinds text, bytea, other),
  or `?T`; errors `error.TypeMismatch`, `error.UnexpectedNull`,
  `error.ColumnOutOfRange`. Never converts or reinterprets.
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
