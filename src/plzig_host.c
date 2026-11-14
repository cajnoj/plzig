/*-------------------------------------------------------------------------
 *
 * plzig_host.c
 *	  Host imports (module "plzig"): the complete capability set of guest
 *	  code.  See doc/abi.md.
 *
 * Rules for every import:
 *	- never let ereport(ERROR) longjmp through interpreter frames: all work
 *	  runs inside PG_TRY; on error the ErrorData is stashed in the call
 *	  context, a WAMR exception is set so the guest traps immediately, and
 *	  the call handler re-throws once wasm_runtime_call_wasm has returned;
 *	- validate every guest pointer/length before use, copy data out, and
 *	  never keep a native pointer into guest memory beyond the import;
 *	- once an error is stashed, every further import traps at once.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

#include "wasm_export.h"

#define PLZIG_HOSTERR_MSG	"plzig: host error"

/* the current call context, or NULL (e.g. during instantiation) */
static PlzigCallCtx *
host_ctx(wasm_exec_env_t env)
{
	PlzigCallCtx *ctx = (PlzigCallCtx *) wasm_runtime_get_user_data(env);
	wasm_module_inst_t mi = wasm_runtime_get_module_inst(env);

	if (ctx == NULL)
	{
		wasm_runtime_set_exception(mi, "plzig: host API used outside a call");
		return NULL;
	}
	if (ctx->edata != NULL)
	{
		wasm_runtime_set_exception(mi, PLZIG_HOSTERR_MSG);
		return NULL;
	}
	return ctx;
}

/* PG_CATCH body shared by all imports. */
static void
host_catch(PlzigCallCtx *ctx, wasm_exec_env_t env, MemoryContext oldcxt)
{
	MemoryContextSwitchTo(ctx->cxt);
	ctx->edata = CopyErrorData();
	FlushErrorState();
	MemoryContextSwitchTo(oldcxt);
	wasm_runtime_set_exception(wasm_runtime_get_module_inst(env), PLZIG_HOSTERR_MSG);
}

/*
 * Copy a guest string, check it is valid in the database encoding (this also
 * rejects NUL bytes), and return a palloc'd NUL-terminated copy.
 */
static char *
guest_string(wasm_exec_env_t env, uint32 ptr, uint32 len, uint32 maxlen,
			 const char *what)
{
	void	   *src;
	char	   *s;

	if (len > maxlen || (Size) len + 1 > MaxAllocSize)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: %s is too long", what)));
	src = plzig_guest_ptr(wasm_runtime_get_module_inst(env), ptr, len);	/* NULL if len == 0 */
	s = palloc((Size) len + 1);
	if (len > 0)
		memcpy(s, src, len);
	s[len] = '\0';
	(void) pg_verifymbstr(s, (int) len, false);
	return s;
}

/* ---------------------------------------------------------------------
 * log / raise / panic
 * ---------------------------------------------------------------------
 */
static void
host_log(wasm_exec_env_t env, uint32 level, uint32 ptr, uint32 len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx == NULL)
		return;
	PG_TRY();
	{
		int			elevel;
		char	   *msg;

		switch (level)
		{
			case 0:
				elevel = DEBUG1;
				break;
			case 1:
				elevel = LOG;
				break;
			case 2:
				elevel = INFO;
				break;
			case 3:
				elevel = NOTICE;
				break;
			case 4:
				elevel = WARNING;
				break;
			default:
				ereport(ERROR,
						(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
						 errmsg("PL/Zig: invalid log level %u", level)));
				elevel = LOG;	/* keep compiler quiet */
		}
		if (len > PLZIG_MAX_LOG_MSG)
			len = PLZIG_MAX_LOG_MSG;	/* truncate (may cut a character: checked below) */
		msg = guest_string(env, ptr, len, PLZIG_MAX_LOG_MSG, "log message");
		ereport(elevel, (errmsg_internal("%s", msg)));
		pfree(msg);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
	}
	PG_END_TRY();
}

static void
host_raise(wasm_exec_env_t env, uint32 ptr, uint32 len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx == NULL)
		return;
	PG_TRY();
	{
		char	   *msg;

		if (len > PLZIG_MAX_LOG_MSG)
			len = PLZIG_MAX_LOG_MSG;
		msg = guest_string(env, ptr, len, PLZIG_MAX_LOG_MSG, "error message");
		ereport(ERROR,
				(errcode(ERRCODE_RAISE_EXCEPTION),
				 errmsg_internal("%s", msg)));
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
	}
	PG_END_TRY();
}

static void
host_panic(wasm_exec_env_t env, uint32 ptr, uint32 len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx == NULL)
		return;
	PG_TRY();
	{
		char	   *msg;

		if (len > 1024)
			len = 1024;
		msg = guest_string(env, ptr, len, 1024, "panic message");
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig panic: %s", msg)));
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
	}
	PG_END_TRY();
}

/* ---------------------------------------------------------------------
 * SPI
 * ---------------------------------------------------------------------
 */
static void
spi_forget_cache(PlzigCallCtx *ctx)
{
	if (ctx->cached_val)
		pfree(ctx->cached_val);
	ctx->cached_val = NULL;
	ctx->cached_row = -1;
	ctx->cached_col = -1;
	if (ctx->cached_name)
		pfree(ctx->cached_name);
	ctx->cached_name = NULL;
	ctx->cached_name_col = -1;
}

static int64
host_spi_execute(wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len,
				 uint32 params_ptr, uint32 nparams)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = 0;

	if (ctx == NULL)
		return 0;
	PG_TRY();
	{
		char	   *sql;
		Oid		   *types = NULL;
		Datum	   *values = NULL;
		char	   *nulls = NULL;
		uint32		i;
		int			rc;

		MemoryContextSwitchTo(ctx->cxt);
		sql = guest_string(env, sql_ptr, sql_len, MaxAllocSize - 1, "SQL statement");
		if (nparams > 65535)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("PL/Zig: too many SPI parameters")));
		if (nparams > 0)
		{
			PlzigSlot  *slots;
			PlzigSlot  *copy;

			slots = plzig_guest_ptr(wasm_runtime_get_module_inst(env), params_ptr,
									nparams * (uint32) sizeof(PlzigSlot));
			copy = palloc(sizeof(PlzigSlot) * nparams);
			memcpy(copy, slots, sizeof(PlzigSlot) * nparams);
			types = palloc(sizeof(Oid) * nparams);
			values = palloc(sizeof(Datum) * nparams);
			nulls = palloc(nparams + 1);
			for (i = 0; i < nparams; i++)
			{
				types[i] = TEXTOID;
				if (copy[i].is_null)
				{
					values[i] = (Datum) 0;
					nulls[i] = 'n';
				}
				else
				{
					char	   *v;

					if (copy[i].val > PG_UINT32_MAX && copy[i].len > 0)
						ereport(ERROR,
								(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
								 errmsg("PL/Zig: invalid SPI parameter pointer")));
					v = guest_string(env, (uint32) (copy[i].val & PG_UINT32_MAX), copy[i].len,
									 MaxAllocSize - VARHDRSZ - 1, "SPI parameter");
					values[i] = PointerGetDatum(cstring_to_text_with_len(v, (int) copy[i].len));
					nulls[i] = ' ';
				}
			}
			nulls[nparams] = '\0';
		}

		if (!ctx->spi_connected)
		{
			if (SPI_connect() != SPI_OK_CONNECT)
				elog(ERROR, "SPI_connect failed");
			ctx->spi_connected = true;
			MemoryContextSwitchTo(ctx->cxt);
		}
		spi_forget_cache(ctx);
		if (ctx->tuptable)
		{
			SPI_freetuptable((SPITupleTable *) ctx->tuptable);
			ctx->tuptable = NULL;
			ctx->ntuples = 0;
		}

		rc = SPI_execute_with_args(sql, (int) nparams, types, values, nulls,
								   ctx->read_only, 0);
		if (rc < 0)
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("PL/Zig: SPI_execute failed: %s", SPI_result_code_string(rc))));
		ctx->tuptable = SPI_tuptable;
		ctx->ntuples = SPI_tuptable ? SPI_tuptable->numvals : 0;
		SPI_tuptable = NULL;
		result = SPI_processed > (uint64) PG_INT64_MAX ? PG_INT64_MAX : (int64) SPI_processed;
		MemoryContextSwitchTo(oldcxt);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = 0;
	}
	PG_END_TRY();
	return result;
}

static uint32
host_spi_ncols(wasm_exec_env_t env)
{
	PlzigCallCtx *ctx = host_ctx(env);
	SPITupleTable *tt;

	if (ctx == NULL)
		return 0;
	tt = (SPITupleTable *) ctx->tuptable;
	return tt ? (uint32) tt->tupdesc->natts : 0;
}

/* Text value of (row, col) via the one-entry cache; NULL for SQL NULL. */
static char *
spi_value(PlzigCallCtx *ctx, uint32 row, uint32 col, bool *isnull)
{
	SPITupleTable *tt = (SPITupleTable *) ctx->tuptable;
	MemoryContext old;

	if (tt == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: no SPI result available")));
	if ((uint64) row >= ctx->ntuples || col >= (uint32) tt->tupdesc->natts)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: SPI result row %u, column %u is out of range", row, col)));
	if (ctx->cached_row == (int64) row && ctx->cached_col == (int) col)
	{
		*isnull = (ctx->cached_val == NULL);
		return ctx->cached_val;
	}
	if (ctx->cached_val)
		pfree(ctx->cached_val);
	ctx->cached_val = NULL;
	old = MemoryContextSwitchTo(ctx->cxt);
	ctx->cached_val = SPI_getvalue(tt->vals[row], tt->tupdesc, (int) col + 1);
	MemoryContextSwitchTo(old);
	ctx->cached_row = row;
	ctx->cached_col = (int) col;
	*isnull = (ctx->cached_val == NULL);
	return ctx->cached_val;
}

static int32
host_spi_value_len(wasm_exec_env_t env, uint32 row, uint32 col)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		bool		isnull;
		char	   *v = spi_value(ctx, row, col, &isnull);
		size_t		l = isnull ? 0 : strlen(v);

		if (l > (size_t) PG_INT32_MAX)
			elog(ERROR, "value too long");
		result = isnull ? -1 : (int32) l;
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

static int32
host_spi_value_copy(wasm_exec_env_t env, uint32 row, uint32 col,
					uint32 buf, uint32 buf_len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		bool		isnull;
		char	   *v = spi_value(ctx, row, col, &isnull);

		if (isnull)
			result = -1;
		else
		{
			size_t		l = strlen(v);
			uint32		n = (uint32) Min(l, (size_t) buf_len);
			char	   *dst = plzig_guest_ptr(wasm_runtime_get_module_inst(env), buf, n);

			if (n > 0)
				memcpy(dst, v, n);
			result = (int32) n;
		}
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

static char *
spi_colname(PlzigCallCtx *ctx, uint32 col)
{
	SPITupleTable *tt = (SPITupleTable *) ctx->tuptable;
	MemoryContext old;

	if (tt == NULL || col >= (uint32) tt->tupdesc->natts)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: SPI result column %u is out of range", col)));
	if (ctx->cached_name_col == (int) col && ctx->cached_name)
		return ctx->cached_name;
	if (ctx->cached_name)
		pfree(ctx->cached_name);
	old = MemoryContextSwitchTo(ctx->cxt);
	ctx->cached_name = SPI_fname(tt->tupdesc, (int) col + 1);
	MemoryContextSwitchTo(old);
	ctx->cached_name_col = (int) col;
	return ctx->cached_name;
}

static int32
host_spi_colname_len(wasm_exec_env_t env, uint32 col)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		result = (int32) strlen(spi_colname(ctx, col));
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

static int32
host_spi_colname_copy(wasm_exec_env_t env, uint32 col, uint32 buf, uint32 buf_len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		char	   *name = spi_colname(ctx, col);
		uint32		n = (uint32) Min(strlen(name), (size_t) buf_len);
		char	   *dst = plzig_guest_ptr(wasm_runtime_get_module_inst(env), buf, n);

		if (n > 0)
			memcpy(dst, name, n);
		result = (int32) n;
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

/* Called by the call handler after a successful guest call. */
void
plzig_host_finish_call(PlzigCallCtx *ctx)
{
	spi_forget_cache(ctx);
	if (ctx->spi_connected)
	{
		ctx->tuptable = NULL;	/* freed by SPI_finish */
		ctx->spi_connected = false;
		if (SPI_finish() != SPI_OK_FINISH)
			elog(ERROR, "SPI_finish failed");
	}
}

/* ---------------------------------------------------------------------
 * Registration
 * ---------------------------------------------------------------------
 */
static NativeSymbol plzig_native_symbols[] = {
	{"log", (void *) host_log, "(iii)", NULL},
	{"raise", (void *) host_raise, "(ii)", NULL},
	{"panic", (void *) host_panic, "(ii)", NULL},
	{"spi_execute", (void *) host_spi_execute, "(iiii)I", NULL},
	{"spi_ncols", (void *) host_spi_ncols, "()i", NULL},
	{"spi_value_len", (void *) host_spi_value_len, "(ii)i", NULL},
	{"spi_value_copy", (void *) host_spi_value_copy, "(iiii)i", NULL},
	{"spi_colname_len", (void *) host_spi_colname_len, "(i)i", NULL},
	{"spi_colname_copy", (void *) host_spi_colname_copy, "(iii)i", NULL},
};

void *
plzig_host_symbols(int *n)
{
	*n = lengthof(plzig_native_symbols);
	return plzig_native_symbols;
}
