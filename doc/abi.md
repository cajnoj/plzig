# PL/Zig host/guest ABI (version 5)

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
    --export=plzig_abi_version --export=plzig_init --export=plzig_alloc_args --export=plzig_call
    --dep plzig --dep user -Mroot=sdk/root.zig --dep plzig -Muser=src/user.zig
    -Mplzig=sdk/plzig.zig --name plzig_module -femit-bin=out.wasm
```

A module is accepted by the loader (`plzig_module_load`) only if

* its linear memory declares at most 1023 MB of initial pages, no function
  declares more than 65535 locals and no table more than 1048576 elements
  (checked before WAMR sees the module, see doc/security.md §4.5);
* WAMR's loader validates it (full validation, classic interpreter);
* every import is a **function** imported from module **`plzig`**, its name
  is one of the 22 host functions below, and WAMR linked it (i.e. the
  signature matched the registered one) — anything else is rejected;
* it instantiates under the current `plzig.max_memory`;
* it exports a linear memory and the four functions below with exactly the
  listed parameter and result types;
* `plzig_abi_version()` returns `5` (`PLZIG_ABI_VERSION`; the version is
  part of the module cache key, so modules built for earlier versions are
  recompiled, never loaded);
* `plzig_init()` reports a valid argument buffer (below).

Size limit for the module file: 16 MB.

## Guest exports

| Export | Signature | Meaning |
|--------|-----------|---------|
| `plzig_abi_version` | `() -> i32` | Returns 5. |
| `plzig_init` | `() -> i64` | Called once per instance, right after `plzig_abi_version`: the guest's argument buffer as `capacity << 32 \| address`. The SDK returns a 4096-byte static buffer outside the arena. |
| `plzig_alloc_args` | `(len: i32) -> i32` | Fallback for argument blocks larger than the buffer: start a call (reset the per-call arena: everything allocated by the previous call is released), then allocate `len` bytes, 8-byte aligned, in the arena. 0 on failure. |
| `plzig_call` | `(args: i32, nargs: i32, result: i32, begin: i32) -> i32` | Run the user function. `args` points to `nargs` slots, `result` to one slot. `begin` ≠ 0: start the call first (reset the arena); `begin` = 0: `plzig_alloc_args` has already done that. Returns a status. |

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

Encoding of `val`/`len` by SQL type (exact type OIDs: a domain over any of
these types is a text-I/O type):

| SQL type | Zig type (argument / result) | Encoding |
|----------|------------------------------|----------|
| `boolean` | `bool` | `val` = 0/1 |
| `smallint`, `integer`, `bigint` | `i16`, `i32`, `i64` | `val` = value sign-extended to 64 bits |
| `real` | `f32` | low 32 bits of `val` = IEEE-754 bits |
| `double precision` | `f64` | `val` = IEEE-754 bits |
| `date` | `plzig.Date` | `val` = DateADT (days since 2000-01-01, `INT32_MIN`/`INT32_MAX` = ∓infinity) sign-extended |
| `time` | `plzig.Time` | `val` = TimeADT (µs since midnight, 0 ..= 86 400 000 000) |
| `time with time zone` | `plzig.TimeTz` | `val` = time (µs), `len` = zone (i32 bits: seconds **west** of UTC, as TimeTzADT) |
| `timestamp`, `timestamp with time zone` | `plzig.Timestamp`, `plzig.TimestampTz` | `val` = Timestamp (µs since 2000-01-01 00:00 (UTC); `INT64_MIN`/`INT64_MAX` = ∓infinity) |
| `oid` | `plzig.Oid` | `val` = the OID, zero-extended |
| `interval` | `plzig.Interval` | `val` = pointer, `len` = 16: PostgreSQL's Interval (i64 µs, i32 days, i32 months, little endian) |
| `uuid` | `plzig.Uuid` | `val` = pointer, `len` = 16: the bytes in network order |
| `numeric` | `plzig.Numeric` | `val` = pointer, `len` = byte length of the binary wire format (*numeric*) |
| `jsonb` | `plzig.Jsonb` / `plzig.JsonText` | argument: `val` = pointer, `len` = length of the detoasted value's on-disk layout (*jsonb*); result: JSON text |
| `text`, `varchar`, `bpchar`, `bytea`, everything else | `[]const u8` | `val` = pointer, `len` = byte length |
| a named composite type (not a domain over one) | a generated struct | argument: `val` = pointer to the row's values, `len` = their number; result: the same, written by the guest (*Rows*) |

For non-`bytea` byte types the bytes are: the detoasted value for
`text`/`varchar`/`bpchar` (database encoding, not NUL-terminated); the
output-function result for all other types. A zero-length slice may carry a
dangling pointer; the host never dereferences or validates pointers when
`len` is 0. Fixed-width values are raw PostgreSQL values: nothing is
converted on the way in. `interval` and `uuid` take 16 bytes, which do not
fit next to the slot's flags, so they are passed like byte values (copied
after the slots, 8-byte aligned); a 16-byte result is copied by the SDK to a
static buffer outside the stack and the arena before `plzig_call` returns.

Results: `text` bytes must be valid in the database encoding and contain no
NUL (checked with `pg_verifymbstr`); `varchar`, `bpchar`, `jsonb` and all
text-I/O types are additionally passed through the type's input function (so
domain constraints, enum labels, array syntax, JSON syntax etc. are enforced
by PostgreSQL); `bytea` is copied verbatim; fixed-width values are
range-checked (*Range checks*); `numeric` goes through `numeric_recv`
(*numeric*). No typmod is applied to any result: PostgreSQL does not keep
the typmod of a function result (`pg_proc` has none), for any language; the
typmod of a domain is applied by the domain's input function, since domains
are text-I/O types.

### Rows

Composite arguments and results (a named composite type, or `record`
described by `OUT`/`INOUT` parameters) are structs with one optional field
per **live** attribute (dropped attributes are left out), in attribute
order. A row crosses the boundary as one *Value* (below) per field, in that
order, in the slot as `val` = guest address of the first value, `len` =
number of values; `is_null` = 1 is a NULL row.

* **Argument** (host → guest): the host converts the composite datum like
  a typed SPI row (*Rows* of the SPI interface: kinds from the attribute
  types, byte-kind payloads 8-byte aligned after the values, with absolute
  guest addresses) but writes only the live attributes, into the argument
  block. The SDK checks the number and the kind of every value against the
  struct (`plzig.decodeRow`).
* **Result** (guest → host): the SDK encodes the struct
  (`plzig.encodeRow`, the field types of SPI parameters: kinds 1–8 and
  10–19, `Jsonb` fields re-serialised to JSON text) into a static buffer per
  row type and puts its address and the number of fields into the result
  slot. The host (`plzig_row_result`, `src/plzig_row.c`) first checks that
  the row type has not changed since the function was loaded, then
  requires `len` to equal the number of live attributes (else `42804`),
  copies the values out of guest memory (range validated; nothing is read
  when `len` is 0) and converts each one against its attribute
  (`plzig_field_from_guest`):
  * `is_null` must be 0 or 1; the kind must be the attribute's kind
    (`plzig_value_kind` of its type), except that kinds 7, 8 and 9 (text,
    bytea, other) are interchangeable — the bytes are interpreted by the
    attribute's type, never by the kind — and a NULL may have kind 0.
    Otherwise `42804 ... is of type <type>, but a value of kind <k> was
    passed`.
  * The value is checked as a prepared-statement parameter of that type is
    (*Range checks*, `numeric_recv`, encoding checks); text-like
    attributes other than `text` (`varchar(n)`, `char(n)`, every
    text-represented type, `jsonb`) go through the type's input function
    **with the attribute's typmod**, and the native types with a typmod
    (`time(p)`, `timestamp(p)`, `interval` fields, `numeric(p,s)`) through
    the type's length coercion function (implicit: too long or too large is
    an error, as for an assignment); a NULL of a domain type goes through
    the domain's input function (its `NOT NULL` and `CHECK` constraints).
  * The tuple is built by the host with the row type's own descriptor
    (`heap_form_tuple`; dropped attributes NULL; blessed for `record`).
* **Sets** (`RETURNS SETOF`, `RETURNS TABLE`): materialize mode only.
  Before the guest runs, the host requires a caller that accepts a
  materialized set (`ReturnSetInfo` with `SFRM_Materialize` and an
  expected descriptor; else `0A000 set-valued function called in context
  that cannot accept a set`) and creates a tuplestore in the per-query
  context with the call's resource owner and `work_mem`. The guest pushes
  each row with `srf_return_next(values, n)`: the values of a row as for a
  row result (SETOF a scalar type: one value, the row type being one column
  named `value` of that type), checked identically, appended with
  `tuplestore_putvalues` (a temporary file, when it starts, belongs to the
  call's resource owner). `plzig_call` returns `void`; the host then
  checks the row type is unchanged, and hands the tuplestore and a copy of
  the descriptor to the executor (which compares it with the one it
  expects). There is no value-per-call mode: an instance never stays
  suspended between calls. Rows pushed by any other call are refused.
* **Staleness**: the struct is generated from the type cache's descriptor
  of the composite type when the function is loaded (`tupDesc_identifier`
  is kept). At every call the identifier is compared (and, when it
  changed, the attributes); a changed type rebuilds the function from the
  new type before it runs, and a type changed during the call makes the
  result an error (`55000 the row type ... changed during the call`).
  `record` results are described by the function's own `pg_proc` row: a
  change replaces the function.

### Triggers

A trigger function (`RETURNS trigger`, no declared parameters, not a set;
event triggers are refused) is generated as
`pub fn call(tg: plzig.Trigger) anyerror!plzig.TriggerResult`, and called
(only as a trigger; the call handler refuses it otherwise, and refuses any
other function called as a trigger) with **three slots**:

1. the trigger information, `val` = address, `len` = size; little-endian
   u32 fields: `event` (bits 0–1: 0 `BEFORE`, 1 `AFTER`, 2 `INSTEAD OF`;
   bit 2: row level; bits 4–7: 1 `INSERT`, 2 `UPDATE`, 3 `DELETE`, 4
   `TRUNCATE`), `relid`, `natts`, `nargs`, then (address, length) of the
   trigger name, the table name and its schema name, the address of
   `nargs` (address, length) pairs (`TG_ARGV`), and the address of `natts`
   16-byte column entries (address and length of the name, u16 kind as in
   *Kinds*, u16 flags: 1 dropped, 2 generated, u32 type OID) — the
   relation's descriptor **at this call**; the strings follow, 8-byte
   aligned;
2. NEW, 3. OLD: a typed row (*Rows* of the SPI interface: one value per
   attribute, dropped ones NULL of kind 9) of the trigger's tuple, or
   `is_null` = 1 where the event has none (`INSERT`: no OLD; `DELETE`: no
   NEW; statement level: neither).

The SDK binds NEW/OLD to structs by column name (`Trigger.new(T)`): nothing
about the table is compiled in.

The result slot: `is_null` holds the **action**: 1 = skip (the function
returns a NULL pointer: skip the operation for this row), 2 = NEW unchanged,
3 = OLD unchanged (2 and 3 are refused, `39P01`, when the trigger has no
such row), 4 = a modified row: `val` = address of `len` values, `len` = the
relation's current number of attributes (else `42804`), positional by
attribute; a value of kind 0 that is not NULL means "keep", anything else
replaces the column after the checks of a row field (*Rows*: kind, range,
input function with the column's typmod, domain constraints, also for
NULL); a dropped or generated column cannot be set (`39P01`). The row is
`heap_modify_tuple` of the trigger's NEW (OLD for `DELETE`; refused when
there is neither, e.g. at statement level), so it has the relation's row
type by construction. Any other action is refused. The result is never
`fcinfo->isnull`. SPI in a trigger call registers the trigger data
(`SPI_register_trigger_data`), so transition tables are visible.

### Range checks

Every fixed-width value a guest hands back -- a function result, a
prepared-statement parameter, the value converted by `tz_convert` -- is
checked by `plzig_scalar_from_guest`/`plzig_fixed16_from_guest`
(`src/plzig_types.c`) exactly as the type's binary receive function checks
it, with PostgreSQL's own macros, and an invalid one is an `ERROR` with
PostgreSQL's message and SQLSTATE (the detail names the raw value and
whether it was the result or parameter `$n`):

| Type | Accepted | Otherwise |
|------|----------|-----------|
| `date` | `DATE_NOT_FINITE(d) \|\| IS_VALID_DATE(d)`; `val` within i32 | `22008 date out of range` |
| `time` | `0 <= t <= USECS_PER_DAY` | `22008 time out of range` |
| `timetz` | time as `time`; `-TZDISP_LIMIT < zone < TZDISP_LIMIT` | `22008` / `22009 time zone displacement out of range` |
| `timestamp`, `timestamptz` | `TIMESTAMP_NOT_FINITE(t) \|\| IS_VALID_TIMESTAMP(t)` | `22008 timestamp out of range` |
| `oid` | `val <= UINT32_MAX` | `22003 OID out of range` |
| `interval`, `uuid` | `len` = 16 (every bit pattern is a value `interval_recv`/`uuid_recv` accept) | `22P03 invalid length` |

### numeric

A `numeric` crosses the boundary in PostgreSQL's binary wire format, the
one `numeric_send` writes: big-endian u16 `ndigits`, i16 `weight`, u16
`sign` (`0x0000` +, `0x4000` −, `0xC000` NaN, `0xD000` +Infinity, `0xF000`
−Infinity), u16 `dscale`, then `ndigits` u16 base-10000 digits; the value is
Σ digit[i] · 10000^(weight − i). It is architecture independent, and its
reader `numeric_recv` is the server's validating path for untrusted bytes.
On the way in (arguments, columns) the host calls `numeric_send`. On the way
back (results, parameters, `numeric_op` operands; `plzig_numeric_from_wire`)
the host first requires the length to be 8 to 131 078 bytes and exactly
`8 + 2·ndigits` (so `numeric_recv` can never run out of data: its
"insufficient data" error would carry a class-08 protocol SQLSTATE), then
calls `numeric_recv` (typmod −1) on a copy, which checks the sign, the
scale, every digit (< 10000) and the weight/scale limits, truncates digits
beyond `dscale` and normalises. Errors: `22P03` (bad length, sign, scale or
digit), `22003` (value overflows numeric format).

### jsonb

A `jsonb` argument or column is the detoasted value's on-disk layout
(`VARDATA` of the varlena: the root `JsonbContainer`), copied once into
guest memory and read in place by the SDK (`plzig.Jsonb`); jsonb results and
parameters are JSON text that the host parses with `jsonb_in`, so a guest
can never store a binary jsonb. The layout (`src/include/utils/jsonb.h`,
identical in 14–19) is in host byte order: on a big-endian host
(`WORDS_BIGENDIAN`) `jsonb` falls back to the text representation, decided
at compile time in `plzig_type_kind`; only little-endian hosts are tested.

Layout as the SDK reads it (`zig/sdk/plzig.zig`, *jsonb*): a container is a
u32 header (`count | flags`, flags `0x40000000` array, `0x20000000` object,
`0x50000000` a raw scalar — a one-element array, root only), then the
JEntries (one per element; for an object all keys, then all values), then
the children's data. A JEntry is `type (0x70000000) | HAS_OFF (0x80000000) |
length-or-end-offset (0x0FFFFFFF)`; types string, numeric, false, true,
null, container. A child's start is the sum of the preceding lengths back to
the nearest entry with `HAS_OFF` (every 32nd stores its end offset:
`getJsonbOffset`); numerics and nested containers start at the next 4-byte
boundary (`INTALIGN`, relative to the data area). Keys are unique and sorted
by length, then bytes (`lengthCompareJsonbString`); object lookup is the
binary search of `getKeyJsonValueFromContainer`. Numbers are PostgreSQL's
on-disk numerics (a varlena with a 1- or 4-byte header; numeric header
short, long or special), decoded in the guest into the wire format above.
Every read is checked against the value's bounds; malformed bytes give
`error.InvalidJsonb`, never a read outside the value.

### Argument buffer

At instantiation (`plzig_instance_create`, so also in the trial
instantiation of every module load) the host calls `plzig_init()` once and
keeps the two guest numbers, never a native pointer. The module is rejected
(`module rejected: invalid argument buffer`) unless the capacity is between
16 bytes (`PLZIG_MIN_ARGBUF`, the result slot of a call without arguments)
and 1 MB (`PLZIG_MAX_ARGBUF`) and `[address, address + capacity)` lies in
the linear memory (`wasm_runtime_validate_app_addr`, 64-bit arithmetic); a
trap in `plzig_init` rejects it too. The address need not be aligned.

### Call sequence (host side, `plzig_instance_call`)

1. `check_stack_depth()`; set the exec-env user data to the call context.
2. Compute the argument block size: `(nargs + 1) * 16` plus every byte
   argument rounded up to 8 (more than 4 GB − 16 → `ERROR`); composite
   arguments (*Rows*) and a trigger's three blobs (*Triggers*) are
   converted first and counted like byte arguments.
3. If the block fits the argument buffer, `base` = the buffer's address and
   `begin` = 1: the call enters the guest once. Otherwise
   `plzig_alloc_args(total)`, `base` = its result (0 → `ERROR`, out of guest
   memory) and `begin` = 0.
4. Validate `[base, base+total)` with `wasm_runtime_validate_app_addr` (on
   every call, in both cases), write the slots, then the byte payloads after
   them, with byte copies at byte offsets (`base` may be misaligned); the
   result slot is the slot right after the arguments. The native pointer is
   not used after this step (the guest may grow, and so move, its memory).
5. `plzig_call(base, nargs, base + nargs*16, begin)`.
6. If the call trapped: if a host import stashed an `ErrorData`, re-throw
   it; if the trap is the interrupt trap, run `CHECK_FOR_INTERRUPTS()` and
   otherwise raise `57014`; else raise `38000 PL/Zig function trapped: <WAMR message>`.
7. Re-validate and copy out the result slot; status 1 → `ERROR: plzig
   function failed: <name>` (`38000`; name truncated to 256 bytes,
   non-printable bytes replaced by `?`).
8. Convert the result (copying out of guest memory); close every cursor
   the guest left open, then `SPI_finish()` if SPI was used
   (`plzig_host_finish_call`); reset the instance's call contexts.

Host memory of a call lives in two memory contexts that belong to the
instance (`PL/Zig call`, `PL/Zig SPI scratch`, children of the `PL/Zig
runtime` context): created with the instance, reset when a call starts and
when it returns (which deletes their child contexts and frees every block
but the first, 1 kB each, so an idle instance keeps about 2 kB), deleted
with the instance. An instance runs one call at a time, so they are never
shared. Every exit from `plzig_instance_call`, also by an error, switches
back to the caller's memory context first.

An instance whose call ended in any `ERROR` is destroyed, with its prepared
statements and its call contexts, before the error is reported. So an error
stashed by a host import is copied into the caller's memory context, not
into the call contexts (`ReThrowError` does not copy every string of an
`ErrorData`). Idle instances are
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

22 imports, the complete list (the loader's allowlist,
`plzig_known_imports` in `src/plzig_runtime.c`, and the registration table
in `src/plzig_host.c` must match):

| Import | Signature | Semantics |
|--------|-----------|-----------|
| `log(level, ptr, len)` | `(iii)` | `level` 0..4 = `DEBUG1`, `LOG`, `INFO`, `NOTICE`, `WARNING`; anything else is an error. Message truncated to 64 kB; must be valid in the database encoding (no NUL). |
| `raise(ptr, len)` | `(ii)` | `ERROR` with SQLSTATE `P0001` and the given message (64 kB max). Does not return to the guest. |
| `raise_error(code_ptr, code_len, msg_ptr, msg_len, detail_ptr, detail_len, hint_ptr, hint_len)` | `(iiiiiiii)` | `ERROR` (always that severity) with the given SQLSTATE, message, detail and hint. The SQLSTATE is checked first: it must be exactly 5 bytes of `[0-9A-Z]` (at most 16 bytes are read, and shown with non-printable bytes as `?`), else `22023 PL/Zig: invalid SQLSTATE "..."`; classes `00`, `01`, `02`, `08`, `53`, `57`, `58`, `F0`, `XX` are refused with `22023 PL/Zig: SQLSTATE <code> cannot be raised by a PL/Zig function` (never substituted). Message, detail and hint are copied like `raise`'s message (64 kB each, cut on a character boundary, valid in the database encoding, no NUL); then C0 control characters other than newline and tab, and DEL, become `?`. Detail or hint with length 0 are omitted (the pointer is not looked at). Does not return to the guest. |
| `panic(ptr, len)` | `(ii)` | Zig panic handler (safety-check failures, `@panic`, `unreachable`): `ERROR` `38000` `PL/Zig panic: <msg>` (1 kB max). |
| `spi_execute(sql_ptr, sql_len, params_ptr, nparams)` | `(iiii)I` | Runs one SQL string with `SPI_execute_with_args`; `params_ptr` points to `nparams` (≤ 65535) slots, each `is_null` or a text value (`val`/`len`); all parameter types are `text` (cast in SQL: `$1::int`). `read_only` is true unless the function is `VOLATILE` (`DO` blocks are volatile). The SPI connection is opened lazily (atomic, so no transaction control) and closed at the end of the call. Returns `SPI_processed` (capped at `INT64_MAX`). Any SQL error aborts the call. The previous result is freed. |
| `spi_ncols()` | `()i` | Number of columns of the last result (0 if none). |
| `spi_value_len(row, col)` | `(ii)i` | Length of the text representation of the 0-based (row, col) of the last result, `-1` for NULL. Out-of-range → `ERROR`. |
| `spi_value_copy(row, col, buf, buf_len)` | `(iiii)i` | Copy up to `buf_len` bytes of that value into guest memory; returns bytes copied (`-1` for NULL). |
| `spi_colname_len(col)` | `(i)i` | Length of the column name. Out-of-range → `ERROR`. |
| `spi_colname_copy(col, buf, buf_len)` | `(iii)i` | Copy up to `buf_len` bytes of the column name; returns bytes copied. |
| `spi_row_size(row)` | `(i)I` | Select row `row` of the last result for typed reading and return the size of its encoding (see *Rows*). Out-of-range or no result → `ERROR`. |
| `spi_row_read(row, buf, buf_len)` | `(iii)i` | Write the encoding of row `row` to `[buf, buf + buf_len)`; `buf_len` must be at least the size. Returns the number of columns. |
| `spi_prepare(sql_ptr, sql_len, types_ptr, ntypes)` | `(iiii)I` | Prepare `sql` with `ntypes` (≤ 65535) parameters; `types_ptr` points to `ntypes` u32 type codes `1`..`8`, `10`..`19` (*Kinds*), anything else → `ERROR`. The host maps the codes to fixed type OIDs; the guest never supplies an OID. `SPI_prepare_cursor(..., CURSOR_OPT_NO_SCROLL)` + `SPI_keepplan`; the plan goes into the calling instance's plan table. More than `plzig.max_prepared_plans` live plans in the instance → `ERROR` (no eviction). Returns a plan handle (never 0). |
| `spi_plan_free(plan)` | `(I)` | Free a plan (`SPI_freeplan`); the handle is invalid afterwards. |
| `spi_execute_plan(plan, params_ptr, nparams)` | `(Iii)I` | Execute a plan with `nparams` typed values (*Values*); `nparams` must equal the plan's parameter count and each value's `kind` must equal the kind of the plan's parameter type (`SPI_getargtypeid`), or be `0` with `is_null` = 1. Values must be in range for the type (`int2`/`int4` sign-extended within range, `bool` 0/1, `float4` upper 32 bits zero, fixed-width types as in *Range checks*); text must be valid in the database encoding without NUL; a `numeric` goes through `numeric_recv`, a `jsonb` is JSON text through `jsonb_in`. `read_only` as for `spi_execute`, decided at every execution. The result replaces the last result. Returns `SPI_processed`. |
| `spi_cursor_open(sql_ptr, sql_len, params_ptr, nparams)` | `(iiii)I` | Open a cursor on `sql` with text parameters (as `spi_execute`): `SPI_cursor_open_with_args(NULL, ..., read_only, CURSOR_OPT_NO_SCROLL)`. More than `plzig.max_open_cursors` open cursors in this call → `ERROR`. Returns a cursor handle (never 0). |
| `spi_cursor_open_plan(plan, params_ptr, nparams)` | `(Iii)I` | Open a cursor on a plan with typed values (checked as for `spi_execute_plan`): `SPI_cursor_open(NULL, plan, ..., read_only)`. Only plans that return rows (`SELECT`, `... RETURNING`) can be opened. |
| `spi_cursor_fetch(cursor, buf, buf_len)` | `(Iii)I` | The next row: returns `-1` at the end, else `ncols << 32 \| size` (size of the row's encoding, see *Rows*). If `size ≤ buf_len` the row has been written to `[buf, buf + size)` (range validated) and is consumed; otherwise nothing is written and the row stays current: the next call delivers the same, already converted row (so a guest grows its buffer and calls again; a row is taken from the portal exactly once). Rows are fetched from the portal `PLZIG_CURSOR_BATCH` (50) at a time with `SPI_cursor_fetch(portal, forward, 50)`; the previous batch is freed first. At the end the portal is closed (the handle stays valid until `spi_cursor_close`; further calls return `-1`). |
| `spi_cursor_close(cursor)` | `(I)` | Close the cursor and free its handle. |
| `numeric_op(op, a_ptr, a_len, b_ptr, b_len, arg, out_ptr, out_cap)` | `(iiiiiiii)i` | One `numeric` operation by PostgreSQL's own function, operands and result in the binary wire format (*numeric*): `op` 1 `numeric_add`, 2 `numeric_sub`, 3 `numeric_mul`, 4 `numeric_div`, 5 `numeric_div_trunc`, 6 `numeric_mod`, 7 `numeric_round(a, arg)`, 8 `numeric_trunc(a, arg)`, 9 `numeric_abs`, 10 `numeric_uminus`; anything else → `ERROR`. Operand `b` is read only by ops 1–6, `arg` only by 7 and 8. Each operand is length-checked, copied and validated by `numeric_recv` before use. If the result's length ≤ `out_cap` it is written to `[out_ptr, out_ptr + len)` (range validated) and `len` is returned; otherwise nothing is written and `-len` is returned (the guest calls again with a large enough buffer; the operation is deterministic). Division by zero (`22012`), overflow (`22003`) etc. are ordinary SQL errors. |
| `tz_convert(op, value, zone_ptr, zone_len)` | `(iIii)I` | Time zone conversion by PostgreSQL's own functions: `op` 1 = timestamptz → local timestamp, 2 = local timestamp → timestamptz; anything else → `ERROR`. `value` is range-checked first (*Range checks*; infinities pass through). `zone_len` = 0: the session's `TimeZone` (`timestamptz_timestamp` / `timestamp_timestamptz`); otherwise the zone name (≤ 1024 bytes, `54000` beyond; database encoding, no NUL) is copied into a `text` and `timestamptz_zone` / `timestamp_zone` (`AT TIME ZONE`) are called, so an unknown zone is `22023`. Returns the converted value. |

| `srf_return_next(values_ptr, n)` | `(ii)` | Append one row to the result of a set-returning call (*Rows*, *Sets*): `n` values at `values_ptr`, `n` = the number of live attributes of the row type (1 for SETOF a scalar type); every value checked as for a row result; `ERROR` in any call that does not return a set. |

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
| 10 | date | `date` | `date` | `val` = DateADT sign-extended |
| 11 | time | `time` | `time` | `val` = TimeADT |
| 12 | timetz | `time with time zone` | same | `val` = time, `len` = zone (i32 bits) |
| 13 | timestamp | `timestamp` | `timestamp` | `val` = Timestamp |
| 14 | timestamptz | `timestamp with time zone` | same | `val` = TimestampTz |
| 15 | interval | `interval` | `interval` | `val` = pointer, `len` = 16 (Interval layout) |
| 16 | uuid | `uuid` | `uuid` | `val` = pointer, `len` = 16 |
| 17 | oid | `oid` | `oid` | `val` = OID |
| 18 | numeric | `numeric` | `numeric` | `val` = pointer, `len` = length of the wire format |
| 19 | jsonb | `jsonb`: the value is **JSON text**, parsed by `jsonb_in` | `jsonb`: the value's **on-disk layout** (detoasted) | `val` = pointer, `len` = byte length |

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

`spi_row_read` and `spi_cursor_fetch` write a row as `ncols` Values followed
by the bytes of the byte-kind values (kinds 7–9, 15, 16, 18, 19), each
starting 8-byte aligned; their `val` holds the guest address of the bytes. Size =
`16 * ncols` + the sum of the byte lengths rounded up to 8, at most
`MaxAllocSize` (larger rows → `ERROR`). The host converts the row when it is
selected (`spi_row_size`, or `spi_cursor_fetch` when it takes the next row
from the batch: detoasting, output functions, `numeric_send`; the per-column arrays are
allocated once per result/cursor, the values in a per-row context that is
reset for the next row), so its size is known before it is copied, and
copies it into guest memory when the guest reads it (never aliasing host
memory). Rows with 0 columns have size 0.

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
* **Cursors** live in a per-call table (in the instance's `PL/Zig call`
  context, reset at the end of the call). The
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
  Per-import temporary data (copied SQL, parameters) lives in the scratch
  context, reset by every SPI import. Host memory therefore does not grow
  with the number of rows or executions.

There are deliberately no imports for the clock, randomness, environment,
files, network, threads, memory management or transaction control
(`tz_convert` converts a timestamp the guest already has; it does not read
the clock); guest memory
grows only through the `memory.grow` instruction, bounded by
`plzig.max_memory`.

## Guest SDK (`plzig` module) summary

* `plzig.allocator` — the only allocator: a bump arena over the linear
  memory above the module's initial size, reset at the start of every call;
  `free`/`resize` work for the most recent allocation; `error.OutOfMemory`
  when `memory.grow` fails.
* `plzig.print(level, fmt, args)`, `debug`, `info`, `notice`, `warning`.
* `plzig.raise(fmt, args) noreturn`, `plzig.raiseMsg(msg) noreturn` (`P0001`).
* `plzig.raiseError(.{ .sqlstate = "23514", .message = m, .detail = d, .hint = h }) noreturn`
  (`ErrorReport`; `sqlstate` defaults to `"P0001"`, `detail`/`hint` to
  `null`) and `plzig.raiseErrorFmt(.{ .sqlstate = ..., .detail = ..., .hint = ... }, fmt, args) noreturn`
  (`ErrorFields`): `raise_error`.
* `plzig.spi.execute(sql, params: []const ?[]const u8) !Result`;
  `Result.rows`, `Result.columns`, `Result.get(row, col) !?[]const u8`
  (text, copied into the arena), `Result.row(i) !Row` (typed, see below),
  `Result.columnName(col) ![]const u8`. Only the most recent result is
  accessible.
* `plzig.spi.prepare(sql, types: []const Type) !Plan` with `Type` =
  `.boolean, .int2, .int4, .int8, .float4, .float8, .text, .bytea, .date,
  .time, .timetz, .timestamp, .timestamptz, .interval, .uuid, .oid,
  .numeric, .jsonb`; `Plan.execute(args) !Result`, `Plan.open(args)
  !Cursor`, `Plan.free()`. `args` is a tuple of `bool`, `i16`, `i32`, `i64`,
  `f32`, `f64`, byte slices / string literals (text), `plzig.bytea(bytes)`
  (bytea), `plzig.Date` ... `plzig.Oid`, `plzig.Numeric`, `plzig.JsonText`
  (jsonb), optionals of these, or `null`; values are encoded on the stack
  (16-byte values copied into a stack array; no arena use). An untyped
  numeric literal is a compile error. The `Plan` struct holds only the
  handle and may be kept in a global.
* `plzig.spi.open(sql, params: []const ?[]const u8) !Cursor`;
  `Cursor.next() !?Row` (`error.CursorClosed` after `close`), `Cursor.close()`.
  The SDK closes the cursor when `next` reaches the end. Each Cursor has a
  scratch buffer in the arena that grows to the largest row seen and is
  reused for every row, so a Row and all slices from it are invalid after
  the next `next()`. `next` calls `spi_cursor_fetch` once per row, twice
  when the buffer has to grow first. `Result.row` uses one such buffer shared by all
  Results (invalid after the next `Result.row`; reset with the arena).
* `Row.len()`, `Row.kind(col) !Kind`, `Row.isNull(col) !bool`,
  `Row.get(T, col)` with `T` = `bool`, `i16`, `i32`, `i64`, `f32`, `f64`,
  `plzig.Date`, `Time`, `TimeTz`, `Timestamp`, `TimestampTz`, `Interval`,
  `Uuid`, `Oid`, `Numeric`, `Jsonb` (column kind must match exactly),
  `[]const u8` (kinds text, bytea, other), or `?T`; errors
  `error.TypeMismatch`, `error.UnexpectedNull`, `error.ColumnOutOfRange`.
  Never converts or reinterprets.
* Fixed-width types (`plzig.Date{ .days }`, `Time{ .usecs }`,
  `TimeTz{ .usecs, .zone }`, `Timestamp{ .usecs }`, `TimestampTz{ .usecs }`,
  `Interval{ .usecs, .days, .months }`, `Uuid{ .bytes }`, `Oid{ .value }`):
  PostgreSQL's representation; calendar conversions in the guest
  (`Date.fromYmd/ymd/dayOfWeek/dayOfYear/toTimestamp`, `Time.fromHms/hms`,
  `Timestamp.fromFields/fields/date/time`; PostgreSQL's Julian-day code,
  `make_date`/`make_timestamp` rules, BC years negative) and time zones by
  the host (`TimestampTz.toLocal/fromLocal/fields/fromFields(zone)`, null =
  the session's TimeZone: `tz_convert`); `Uuid.parse/format`.
* `plzig.Numeric{ .wire }`: `fromWire` (validated), `isNaN/isInf/isFinite/
  isZero/isNegative`, `scale`, `weight`, `order/eql` (PostgreSQL's ordering),
  `toI64` (exact), `toF64` (correctly rounded), `fromI64`, `fromF64`
  (`%.15g`, as `float8::numeric`), `parse` (numeric_in's decimal syntax),
  `toText`/`{f}` (numeric_out's text); arithmetic by the host
  (`add/sub/mul/div/divTrunc/mod/round/trunc/abs/neg`: `numeric_op`).
  `*Alloc` variants take an explicit allocator.
* `plzig.Jsonb{ .bytes }`: `root() !JsonValue` (`null`, `bool`, `string`,
  `number: JsonNumber`, `array: JsonArray`, `object: JsonObject`),
  `JsonArray.len/get/iterator`, `JsonObject.len/get(key)/entry/iterator`,
  `JsonNumber.numeric/toI64/toF64`, `toJsonText()` (jsonb_out's text);
  `plzig.JsonText{ .text }` / `plzig.jsonText(t)` for jsonb results and
  parameters.
* Rows (*Rows*): `plzig.rowFieldCount(T)`, `rowFixedCount(T)`,
  `encodeRow(T, row, values, fixed)`, `decodeRow(T, values)`, `isRowType(T)`
  — used by the SDK root for composite arguments and results.
* `plzig.returnNext(T, ?T)`: `srf_return_next` with the row encoded into a
  static buffer per row type (the generated `returnNext` calls it).
* Triggers (*Triggers*): `plzig.Trigger` (`when`, `forEachRow`, `op`,
  `name`, `tableName`, `tableSchema`, `relid`, `argCount`/`arg`,
  `columnCount/Name/Kind/Dropped/Generated/Index`, `newRow`/`oldRow`,
  `new(T)`/`old(T)` bound by name, `modify(row)`), `plzig.TriggerResult`
  (`.skip`, `.new`, `.old`), `plzig.TriggerError`.
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
  `src/user.zig:N:C:` to `line N-1, column C:` in diagnostics). Struct
  declarations for rows are on the same line.
* `STRICT` → plain parameter types, otherwise optionals.
* Return type `anyerror!?T`, or `anyerror!void` for `void` and procedures.
* Rows (*Rows*): each composite argument type is declared once as
  `const @"plzig.RowN" = struct { @"field": ?T, ... };` (N = 1, 2, ... in
  order of first use; a name no parameter can have); a row result is
  `const Result = ...;` (an alias of the argument struct of the same type
  unless it has a `jsonb` attribute; else its own struct, as for output
  parameters) and the return type is `anyerror!?Result`, or
  `anyerror!Result` for a procedure (PostgreSQL refuses a NULL output
  row). Field names are attribute or output-parameter names (unnamed
  outputs: `column1`, ...), restricted to `[A-Za-z_][A-Za-z0-9_]*` (at most
  63 bytes) and unique, so they never need escaping; a parameter may not
  be called `Result` then.
* Input parameters are `IN` and `INOUT`; `argN` counts input parameters.
* Triggers: `pub fn call(tg: plzig.Trigger) anyerror!plzig.TriggerResult { _ = &tg;`.
* Sets: `const Result = <element type>;` (a scalar type, or a row struct as
  above), `fn returnNext(row: ?Result) void { plzig.returnNext(Result, row); }`,
  and the return type `anyerror!void`; `Result` and `returnNext` are then
  reserved parameter names.
* Parameter names must match `[A-Za-z_][A-Za-z0-9_]*` and must not be
  `plzig`, `std` or `call` (the generated file's own declarations);
  unnamed parameters are `arg1..argN`.
* `DO` blocks: `pub fn call() anyerror!void {`.

## Interrupts

The vendored WAMR is patched (`third_party/wamr-interrupt.patch`) so that
the classic interpreter's `CHECK_SUSPEND_FLAGS()` — evaluated at every
`br`, `br_if`, `br_table`, call and function entry — reads
`wamr_plzig_interrupt_flags[0..1]`, which the host points at
`QueryCancelPending` and `ProcDiePending`. When either is set the guest
traps with the exception `plzig: interrupted`, and the host runs
`CHECK_FOR_INTERRUPTS()`.
