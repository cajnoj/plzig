/*-------------------------------------------------------------------------
 *
 * hoststubs.c
 *	  Stand-ins for the host imports of src/plzig_host.c, for the loader fuzz
 *	  target.  The table is built from the same import list as the
 *	  production one (PLZIG_HOST_IMPORTS, generated from
 *	  abi/plzig-abi.table), with a compile-time check of every stand-in's C
 *	  type, so the loader's import allowlist and signature check see what
 *	  they see in the server.  The SPI imports need a server; here every
 *	  import checks its pointer arguments with the production range check
 *	  (plzig_guest_range, which never throws) and then either returns or
 *	  traps the guest the way a failing import does (a WAMR exception, never
 *	  a longjmp through the interpreter).
 *
 *	  Not part of PL/Zig: built only by fuzz/build.sh.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "wasm_export.h"

static void
stub_trap(wasm_exec_env_t env, const char *what)
{
	wasm_runtime_set_exception(wasm_runtime_get_module_inst(env), what);
}

static bool
stub_range(wasm_exec_env_t env, uint32 ptr, uint32 len)
{
	return len == 0 || plzig_guest_range(wasm_runtime_get_module_inst(env), ptr, len);
}

/* log may legitimately be called: check the range and return */
static void
h_log(wasm_exec_env_t env, uint32 level, uint32 ptr, uint32 len)
{
	if (level > 4 || !stub_range(env, ptr, len > 65536 ? 65536 : len))
		stub_trap(env, "plzig: host error");
}

static void
h_raise(wasm_exec_env_t env, uint32 ptr, uint32 len)
{
	(void) stub_range(env, ptr, len > 65536 ? 65536 : len);
	stub_trap(env, "plzig: host error");
}

static void
h_raise_error(wasm_exec_env_t env, uint32 cp, uint32 cl, uint32 mp, uint32 ml,
			  uint32 dp, uint32 dl, uint32 hp, uint32 hl)
{
	(void) stub_range(env, cp, cl > 16 ? 16 : cl);
	(void) stub_range(env, mp, ml > 65536 ? 65536 : ml);
	(void) stub_range(env, dp, dl > 65536 ? 65536 : dl);
	(void) stub_range(env, hp, hl > 65536 ? 65536 : hl);
	stub_trap(env, "plzig: host error");
}

static void
h_panic(wasm_exec_env_t env, uint32 ptr, uint32 len)
{
	(void) stub_range(env, ptr, len > 1024 ? 1024 : len);
	stub_trap(env, "plzig: host error");
}

static int64
h_iiii_I(wasm_exec_env_t env, uint32 a, uint32 b, uint32 c, uint32 d)
{
	(void) stub_range(env, a, b);
	(void) stub_range(env, c, d > 65535 ? 0 : d * 16);
	stub_trap(env, "plzig: host error");
	return 0;
}

/* the same for the imports that return a handle (u64) */
static uint64
h_iiii_U(wasm_exec_env_t env, uint32 a, uint32 b, uint32 c, uint32 d)
{
	return (uint64) h_iiii_I(env, a, b, c, d);
}

static uint32
h_v_i(wasm_exec_env_t env)
{
	return 0;
}

static int32
h_ii_i(wasm_exec_env_t env, uint32 a, uint32 b)
{
	stub_trap(env, "plzig: host error");
	return -1;
}

static int32
h_iiii_i(wasm_exec_env_t env, uint32 a, uint32 b, uint32 c, uint32 d)
{
	(void) stub_range(env, c, d);
	stub_trap(env, "plzig: host error");
	return -1;
}

static int32
h_i_i(wasm_exec_env_t env, uint32 a)
{
	stub_trap(env, "plzig: host error");
	return -1;
}

static int32
h_iii_i(wasm_exec_env_t env, uint32 a, uint32 b, uint32 c)
{
	(void) stub_range(env, b, c);
	stub_trap(env, "plzig: host error");
	return -1;
}

static int64
h_i_I(wasm_exec_env_t env, uint32 a)
{
	stub_trap(env, "plzig: host error");
	return -1;
}

static void
h_I(wasm_exec_env_t env, uint64 a)
{
	stub_trap(env, "plzig: host error");
}

static int64
h_Iii_I(wasm_exec_env_t env, uint64 a, uint32 b, uint32 c)
{
	(void) stub_range(env, b, c > 65535 ? 0 : c * 16);
	stub_trap(env, "plzig: host error");
	return 0;
}

static uint64
h_Iii_U(wasm_exec_env_t env, uint64 a, uint32 b, uint32 c)
{
	return (uint64) h_Iii_I(env, a, b, c);
}

/* spi_cursor_fetch: never a row here (no cursor can be opened), so -1 */
static int64
h_Iii_I_fetch(wasm_exec_env_t env, uint64 a, uint32 b, uint32 c)
{
	(void) stub_range(env, b, c);
	stub_trap(env, "plzig: host error");
	return -1;
}

/* numeric_op: operand ranges checked, then the trap a failing import causes */
static int32
h_numeric_op(wasm_exec_env_t env, uint32 op, uint32 a, uint32 alen, uint32 b, uint32 blen,
			 int32 arg, uint32 out, uint32 out_cap)
{
	(void) stub_range(env, a, alen > 131078 ? 0 : alen);
	(void) stub_range(env, b, blen > 131078 ? 0 : blen);
	(void) stub_range(env, out, out_cap > 131078 ? 0 : out_cap);
	stub_trap(env, "plzig: host error");
	return 0;
}

/*
 * srf_return_next: the values' range checked, then the trap the import
 * causes outside a set-returning call (the harness never declares one)
 */
static void
h_srf_return_next(wasm_exec_env_t env, uint32 ptr, uint32 n)
{
	(void) stub_range(env, ptr, n > 1664 ? 1664 * 16 : n * 16);
	stub_trap(env, "plzig: host error");
}

/*
 * commit/rollback: the harness's calls are atomic (a function), where the
 * server raises "invalid transaction termination": the trap that causes
 */
static void
h_end_xact(wasm_exec_env_t env)
{
	stub_trap(env, "plzig: host error");
}

/* tz_convert: zone range checked, then the trap a failing import causes */
static int64
h_tz_convert(wasm_exec_env_t env, uint32 op, int64 value, uint32 zone, uint32 zone_len)
{
	(void) stub_range(env, zone, zone_len > 1024 ? 1024 : zone_len);
	stub_trap(env, "plzig: host error");
	return 0;
}

/*
 * The stand-in of each import (several share one); the table below takes
 * every import of PLZIG_HOST_IMPORTS, so an import without a stand-in here
 * does not compile, and a stand-in whose C type is not the import's fails
 * the static assertion.
 */
#define stub_log				h_log
#define stub_raise				h_raise
#define stub_panic				h_panic
#define stub_raise_error		h_raise_error
#define stub_spi_execute		h_iiii_I
#define stub_spi_ncols			h_v_i
#define stub_spi_value_len		h_ii_i
#define stub_spi_value_copy		h_iiii_i
#define stub_spi_colname_len	h_i_i
#define stub_spi_colname_copy	h_iii_i
#define stub_spi_row_size		h_i_I
#define stub_spi_row_read		h_iii_i
#define stub_spi_prepare		h_iiii_U
#define stub_spi_plan_free		h_I
#define stub_spi_execute_plan	h_Iii_I
#define stub_spi_cursor_open	h_iiii_U
#define stub_spi_cursor_open_plan	h_Iii_U
#define stub_spi_cursor_fetch	h_Iii_I_fetch
#define stub_spi_cursor_close	h_I
#define stub_numeric_op			h_numeric_op
#define stub_tz_convert			h_tz_convert
#define stub_srf_return_next	h_srf_return_next
#define stub_commit				h_end_xact
#define stub_rollback			h_end_xact

#define STUB_SYMBOL(name, sig, ret, params) \
	{#name, (void *) stub_##name, sig, NULL},
static NativeSymbol stub_symbols[] = {
	PLZIG_HOST_IMPORTS(STUB_SYMBOL)
};

#define STUB_TYPE_CHECK(name, sig, ret, params) \
	StaticAssertDecl(__builtin_types_compatible_p(__typeof__(&stub_##name), ret (*) params), \
					 "stand-in of " #name ": not the type of the import in abi/plzig-abi.table");
PLZIG_HOST_IMPORTS(STUB_TYPE_CHECK)

void *
plzig_host_symbols(int *n)
{
	*n = lengthof(stub_symbols);
	return stub_symbols;
}

void
plzig_host_finish_call(PlzigCallCtx *ctx)
{
}

void
plzig_host_free_plans(PlzigPlanTable *plans)
{
	plans->entries = NULL;		/* the stubs never create plans */
	plans->size = 0;
	plans->nlive = 0;
}

/*
 * The value checks of src/plzig_types.c that plzig_runtime.c calls for the
 * natively mapped types (dates, numeric, ...).  The harness only declares
 * int, text, bytea and void results (fuzz/loader/harness.c), so these are
 * never reached; if they were, they fail like a rejected value.
 */
static void
stub_value_error(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
			 errmsg("PL/Zig: native value types are not used by the loader harness")));
}

Datum
plzig_scalar_from_guest(PlzigTypeKind k, uint64 val, uint32 len, const char *where)
{
	stub_value_error();
	return (Datum) 0;
}

void
plzig_fixed16_check_len(PlzigTypeKind k, uint32 len, const char *where)
{
	stub_value_error();
}

Datum
plzig_fixed16_from_guest(PlzigTypeKind k, const char *bytes, uint32 len, const char *where)
{
	stub_value_error();
	return (Datum) 0;
}

void
plzig_numeric_check_len(uint32 len, const char *where)
{
	stub_value_error();
}

Datum
plzig_numeric_from_wire(const char *bytes, uint32 len, const char *where)
{
	stub_value_error();
	return (Datum) 0;
}

struct varlena *
plzig_numeric_to_wire(Datum num)
{
	stub_value_error();
	return NULL;
}

/*
 * Rows (src/plzig_row.c, the typed-row encoding of src/plzig_host.c): the
 * harness declares no composite arguments or results, so these are never
 * reached; if they were, they fail like a rejected value.
 */
PlzigRowBuf *
plzig_row_arg_load(PlzigRowDesc *rd, Datum value, MemoryContext cxt, uint64 *size)
{
	stub_value_error();
	return NULL;
}

int32
plzig_rowbuf_encode(PlzigRowBuf *rb, uint8 *base, uint32 guest, bool live_only)
{
	stub_value_error();
	return 0;
}

void
plzig_rowbuf_forget_row(PlzigRowBuf *rb)
{
}

Datum
plzig_row_result(void *module_inst, PlzigRowDesc *rd, const PlzigSlot *slot, bool *isnull)
{
	stub_value_error();
	return (Datum) 0;
}

PlzigSrf *
plzig_srf_begin(struct ReturnSetInfo *rsinfo, PlzigRowDesc *rd, MemoryContext cxt)
{
	stub_value_error();
	return NULL;
}

void
plzig_srf_finish(PlzigSrf *srf)
{
	stub_value_error();
}

PlzigTriggerArgs *
plzig_trigger_args_load(struct TriggerData *td, MemoryContext cxt, uint32 *sizes)
{
	stub_value_error();
	return NULL;
}

void
plzig_trigger_args_encode(PlzigTriggerArgs *ta, int which, uint8 *base, uint32 guest,
						  PlzigSlot *slot)
{
	stub_value_error();
}

Datum
plzig_trigger_result(void *module_inst, struct TriggerData *td, const PlzigSlot *slot)
{
	stub_value_error();
	return (Datum) 0;
}
