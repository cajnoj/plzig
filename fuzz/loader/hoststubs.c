/*-------------------------------------------------------------------------
 *
 * hoststubs.c
 *	  Stand-ins for the host imports of src/plzig_host.c, for the loader fuzz
 *	  target.  Same names and WAMR signature strings as the production table
 *	  (fuzz/build.sh compares them and refuses to build on any difference),
 *	  so the loader's import allowlist and signature check see exactly what
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

/* keep in sync with plzig_native_symbols in src/plzig_host.c (checked by fuzz/build.sh) */
static NativeSymbol stub_symbols[] = {
	{"log", (void *) h_log, "(iii)", NULL},
	{"raise", (void *) h_raise, "(ii)", NULL},
	{"panic", (void *) h_panic, "(ii)", NULL},
	{"raise_error", (void *) h_raise_error, "(iiiiiiii)", NULL},
	{"spi_execute", (void *) h_iiii_I, "(iiii)I", NULL},
	{"spi_ncols", (void *) h_v_i, "()i", NULL},
	{"spi_value_len", (void *) h_ii_i, "(ii)i", NULL},
	{"spi_value_copy", (void *) h_iiii_i, "(iiii)i", NULL},
	{"spi_colname_len", (void *) h_i_i, "(i)i", NULL},
	{"spi_colname_copy", (void *) h_iii_i, "(iii)i", NULL},
	{"spi_row_size", (void *) h_i_I, "(i)I", NULL},
	{"spi_row_read", (void *) h_iii_i, "(iii)i", NULL},
	{"spi_prepare", (void *) h_iiii_I, "(iiii)I", NULL},
	{"spi_plan_free", (void *) h_I, "(I)", NULL},
	{"spi_execute_plan", (void *) h_Iii_I, "(Iii)I", NULL},
	{"spi_cursor_open", (void *) h_iiii_I, "(iiii)I", NULL},
	{"spi_cursor_open_plan", (void *) h_Iii_I, "(Iii)I", NULL},
	{"spi_cursor_fetch", (void *) h_Iii_I_fetch, "(Iii)I", NULL},
	{"spi_cursor_close", (void *) h_I, "(I)", NULL},
	{"numeric_op", (void *) h_numeric_op, "(iiiiiiii)i", NULL},
};

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
