/*-------------------------------------------------------------------------
 *
 * plzig_abi.h
 *	  PL/Zig host/guest ABI definitions shared with the guest SDK.
 *
 * GENERATED from abi/plzig-abi.table by abi/gen-abi.sh: do not edit.
 * Edit the table and run `make abi`; `make check-abi` (part of every
 * build) fails while this file is not what the table generates.  The
 * same table generates the marked regions of zig/sdk/plzig.zig.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLZIG_ABI_H
#define PLZIG_ABI_H

/* host/guest ABI version (doc/abi.md), independent of the release version */
#define PLZIG_ABI_VERSION		5

/*
 * 16-byte argument/result slot shared with the host (see doc/abi.md).
 */
typedef struct PlzigSlot
{
	uint64		val;
	uint32		len;
	uint32		is_null;
} PlzigSlot;
StaticAssertDecl(sizeof(PlzigSlot) == 16, "PlzigSlot: size");
StaticAssertDecl(offsetof(PlzigSlot, val) == 0, "PlzigSlot.val: offset");
StaticAssertDecl(offsetof(PlzigSlot, len) == 8, "PlzigSlot.len: offset");
StaticAssertDecl(offsetof(PlzigSlot, is_null) == 12, "PlzigSlot.is_null: offset");

/*
 * 16-byte typed value shared with the host: parameters of prepared
 * statements and columns of result rows (see doc/abi.md, "Value").
 */
typedef struct PlzigValue
{
	uint64		val;
	uint32		len;
	uint16		kind;
	uint16		is_null;
} PlzigValue;
StaticAssertDecl(sizeof(PlzigValue) == 16, "PlzigValue: size");
StaticAssertDecl(offsetof(PlzigValue, val) == 0, "PlzigValue.val: offset");
StaticAssertDecl(offsetof(PlzigValue, len) == 8, "PlzigValue.len: offset");
StaticAssertDecl(offsetof(PlzigValue, kind) == 12, "PlzigValue.kind: offset");
StaticAssertDecl(offsetof(PlzigValue, is_null) == 14, "PlzigValue.is_null: offset");

/*
 * Value kinds (doc/abi.md, "Kinds"): the kind of a result column is
 * derived by the host from the tuple descriptor; the kind of a
 * prepared-statement parameter is chosen by the guest at prepare time and
 * mapped to a fixed type OID by the host.
 */
#define PLZIG_KIND_NULL			0	/* parameter only: NULL of any type */
#define PLZIG_KIND_BOOL			1
#define PLZIG_KIND_INT2			2
#define PLZIG_KIND_INT4			3
#define PLZIG_KIND_INT8			4
#define PLZIG_KIND_FLOAT4		5
#define PLZIG_KIND_FLOAT8		6
#define PLZIG_KIND_TEXT			7	/* text, varchar, bpchar (char(n)): the value's bytes */
#define PLZIG_KIND_BYTEA		8
#define PLZIG_KIND_OTHER		9	/* result only: any other type, its text representation */
#define PLZIG_KIND_DATE			10
#define PLZIG_KIND_TIME			11
#define PLZIG_KIND_TIMETZ		12	/* time in val, zone in len */
#define PLZIG_KIND_TIMESTAMP	13
#define PLZIG_KIND_TIMESTAMPTZ	14
#define PLZIG_KIND_INTERVAL		15	/* 16 bytes, out of line */
#define PLZIG_KIND_UUID			16	/* 16 bytes, out of line */
#define PLZIG_KIND_OID			17
#define PLZIG_KIND_NUMERIC		18	/* wire format (numeric_send), out of line */
#define PLZIG_KIND_JSONB		19	/* column: the value's on-disk layout (plzig.Jsonb); parameter: JSON text */
#define PLZIG_KIND_MAX			19

/* operations of the numeric_op import (doc/abi.md) */
#define PLZIG_NUMERIC_ADD		1
#define PLZIG_NUMERIC_SUB		2
#define PLZIG_NUMERIC_MUL		3
#define PLZIG_NUMERIC_DIV		4
#define PLZIG_NUMERIC_DIV_TRUNC	5
#define PLZIG_NUMERIC_MOD		6
#define PLZIG_NUMERIC_ROUND		7
#define PLZIG_NUMERIC_TRUNC		8
#define PLZIG_NUMERIC_ABS		9
#define PLZIG_NUMERIC_NEG		10
#define PLZIG_NUMERIC_OP_MAX	10

/* operations of the tz_convert import (doc/abi.md) */
#define PLZIG_TZ_TO_LOCAL		1	/* timestamptz -> local timestamp */
#define PLZIG_TZ_FROM_LOCAL		2	/* local timestamp -> timestamptz */

/*
 * The host imports (module "plzig", doc/abi.md "Host imports"), in the
 * order of the registration table, as an X macro:
 *
 *   X(name, WAMR signature string, C return type, (C parameter list))
 *
 * The parameter list is that of the native function WAMR calls (its first
 * parameter is the exec env; every guest pointer is a uint32).  Only code
 * that includes wasm_export.h can expand it.
 */
#define PLZIG_HOST_IMPORT_COUNT	24
#define PLZIG_HOST_IMPORTS(X) \
	X(log, "(iii)", void, (wasm_exec_env_t env, uint32 level, uint32 ptr, uint32 len)) \
	X(raise, "(ii)", void, (wasm_exec_env_t env, uint32 ptr, uint32 len)) \
	X(panic, "(ii)", void, (wasm_exec_env_t env, uint32 ptr, uint32 len)) \
	X(raise_error, "(iiiiiiii)", void, (wasm_exec_env_t env, uint32 code_ptr, uint32 code_len, uint32 msg_ptr, uint32 msg_len, uint32 detail_ptr, uint32 detail_len, uint32 hint_ptr, uint32 hint_len)) \
	X(spi_execute, "(iiii)I", int64, (wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len, uint32 params_ptr, uint32 nparams)) \
	X(spi_ncols, "()i", uint32, (wasm_exec_env_t env)) \
	X(spi_value_len, "(ii)i", int32, (wasm_exec_env_t env, uint32 row, uint32 col)) \
	X(spi_value_copy, "(iiii)i", int32, (wasm_exec_env_t env, uint32 row, uint32 col, uint32 buf, uint32 buf_len)) \
	X(spi_colname_len, "(i)i", int32, (wasm_exec_env_t env, uint32 col)) \
	X(spi_colname_copy, "(iii)i", int32, (wasm_exec_env_t env, uint32 col, uint32 buf, uint32 buf_len)) \
	X(spi_row_size, "(i)I", int64, (wasm_exec_env_t env, uint32 row)) \
	X(spi_row_read, "(iii)i", int32, (wasm_exec_env_t env, uint32 row, uint32 buf, uint32 buf_len)) \
	X(spi_prepare, "(iiii)I", uint64, (wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len, uint32 kinds_ptr, uint32 nkinds)) \
	X(spi_plan_free, "(I)", void, (wasm_exec_env_t env, uint64 handle)) \
	X(spi_execute_plan, "(Iii)I", int64, (wasm_exec_env_t env, uint64 handle, uint32 params_ptr, uint32 nparams)) \
	X(spi_cursor_open, "(iiii)I", uint64, (wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len, uint32 params_ptr, uint32 nparams)) \
	X(spi_cursor_open_plan, "(Iii)I", uint64, (wasm_exec_env_t env, uint64 handle, uint32 params_ptr, uint32 nparams)) \
	X(spi_cursor_fetch, "(Iii)I", int64, (wasm_exec_env_t env, uint64 cursor, uint32 buf, uint32 buf_len)) \
	X(spi_cursor_close, "(I)", void, (wasm_exec_env_t env, uint64 cursor)) \
	X(numeric_op, "(iiiiiiii)i", int32, (wasm_exec_env_t env, uint32 op, uint32 a_ptr, uint32 a_len, uint32 b_ptr, uint32 b_len, int32 arg, uint32 out_ptr, uint32 out_cap)) \
	X(tz_convert, "(iIii)I", int64, (wasm_exec_env_t env, uint32 op, int64 value, uint32 zone_ptr, uint32 zone_len)) \
	X(srf_return_next, "(ii)", void, (wasm_exec_env_t env, uint32 values_ptr, uint32 n)) \
	X(commit, "()", void, (wasm_exec_env_t env)) \
	X(rollback, "()", void, (wasm_exec_env_t env))

#endif							/* PLZIG_ABI_H */
