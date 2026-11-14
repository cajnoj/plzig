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
 *	- once an error is stashed, every further import traps at once;
 *	- every handle (prepared statement, cursor) is validated on every use:
 *	  range, liveness and serial number, in a table that belongs to the
 *	  calling instance (plans) or to the current call (cursors).
 *
 * Lifetimes (see doc/abi.md, "Lifetimes"):
 *	- prepared statements live in the instance's plan table, in
 *	  CacheMemoryContext (SPI_keepplan), and are freed by
 *	  plzig_host_free_plans(), called from plzig_instance_destroy() on every
 *	  path that ends an instance, or by spi_plan_free;
 *	- cursors live in the per-call table; portals are pinned, referenced by
 *	  name and closed by plzig_host_finish_call() when the call returns, or
 *	  by the transaction/subtransaction abort when it fails;
 *	- per-import temporary data lives in ctx->scratch, reset by every SPI
 *	  import; row data in a per-row context reset for every row.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/portal.h"

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
 * SPI: common helpers
 * ---------------------------------------------------------------------
 */

/* One prepared statement of an instance (PlzigPlanTable, plzig.h). */
struct PlzigPlanEntry
{
	SPIPlanPtr	plan;			/* kept plan, NULL = free entry */
	uint64		serial;			/* handle serial, 0 = free entry */
};

/* Column information for typed rows. */
typedef struct PlzigColInfo
{
	uint16		kind;			/* PLZIG_KIND_*, from the tuple descriptor */
	bool		dropped;
	FmgrInfo	out;			/* output function, PLZIG_KIND_OTHER only */
} PlzigColInfo;

/* One column of the current row, ready to be copied into guest memory. */
typedef struct PlzigRowCol
{
	uint64		val;			/* scalar kinds */
	const char *data;			/* byte kinds (in the row context or tuple) */
	uint32		len;
	uint16		kind;
	bool		isnull;
} PlzigRowCol;

/*
 * Typed access to rows of one tuple source (the last execute result, or one
 * cursor).  The current row is converted when it is selected (size known
 * before the guest provides a buffer) and copied when the guest reads it.
 */
struct PlzigRowBuf
{
	MemoryContext desc_cxt;		/* column info; reset when the source changes */
	MemoryContext row_cxt;		/* current row; reset for every row */
	bool		have_desc;
	int			natts;
	PlzigColInfo *cols;
	bool		have_row;
	int64		rowno;			/* result rows: number of the current row */
	PlzigRowCol *row;
	uint64		size;			/* encoded size of the current row */
};

/* One entry of the per-call cursor table. */
struct PlzigCursor
{
	uint64		serial;			/* handle serial, 0 = free entry */
	MemoryContext cxt;			/* "PL/Zig cursor", child of the call context */
	char	   *portal_name;	/* the portal is looked up by name on every use */
	Portal		portal;			/* compared with that lookup, never trusted */
	SPITupleTable *batch;		/* current batch of rows, or NULL */
	uint64		batch_pos;		/* next row of the batch */
	bool		finished;		/* end reached; portal already closed */
	PlzigRowBuf *rb;
};

/* handle = serial << 16 | table index; serials are unique per backend */
#define PLZIG_HANDLE_INDEX_BITS	16
#define PLZIG_HANDLE_MAX_INDEX	((1 << PLZIG_HANDLE_INDEX_BITS) - 1)

static uint64 plzig_next_serial_value = 0;

/*
 * Next handle serial.  Monotonic per backend (so a handle of one instance or
 * call never matches an entry of another one in the same backend), starting
 * at a random point so that handles are not the same in every backend.  The
 * random start is not a security property: tables are per instance/call, so
 * a forged handle can at most name an object of the caller's own table.
 */
static uint64
next_serial(void)
{
	uint64		s;

	if (plzig_next_serial_value == 0)
	{
		uint64		r = 0;

		if (!pg_strong_random(&r, sizeof(r)))
			r = (uint64) MyProcPid;
		plzig_next_serial_value = (r & ((UINT64CONST(1) << 40) - 1)) + 1;
	}
	s = plzig_next_serial_value++;
	if (plzig_next_serial_value >= (UINT64CONST(1) << 47))
		plzig_next_serial_value = 1;
	return s;
}

static inline uint64
make_handle(uint64 serial, int index)
{
	return (serial << PLZIG_HANDLE_INDEX_BITS) | (uint64) index;
}

static void
spi_connect_if_needed(PlzigCallCtx *ctx)
{
	if (!ctx->spi_connected)
	{
		MemoryContext old = MemoryContextSwitchTo(ctx->cxt);

		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed");
		ctx->spi_connected = true;
		MemoryContextSwitchTo(old);
	}
}

/*
 * Report errors of our own pre-parse like SPI does: a syntax error position
 * refers to the statement, not to the client's query.
 */
static void
plzig_sql_error_callback(void *arg)
{
	const char *query = (const char *) arg;
	int			pos = geterrposition();

	if (pos > 0)
	{
		errposition(0);
		internalerrposition(pos);
		internalerrquery(query);
	}
	else
		errcontext("SQL statement \"%s\"", query);
}

/*
 * Statements a guest may not run through any SPI import: cursor commands.
 * Cursors are available only through spi_cursor_*, which never outlive the
 * call; DECLARE (in particular WITH HOLD), FETCH, MOVE and CLOSE would let
 * SQL create cursors that survive the call or reach portals the function
 * did not open.  Checked on the raw parse tree, before SPI parses again.
 * (A nested function in another language can still run them; that is the
 * other language's business, and our own portals are pinned.)
 */
static void
check_sql(const char *sql)
{
	List	   *raw;
	ListCell   *lc;
	ErrorContextCallback errcb;

	errcb.callback = plzig_sql_error_callback;
	errcb.arg = (void *) sql;
	errcb.previous = error_context_stack;
	error_context_stack = &errcb;

	raw = raw_parser(sql, RAW_PARSE_DEFAULT);

	error_context_stack = errcb.previous;

	foreach(lc, raw)
	{
		RawStmt    *rs = lfirst_node(RawStmt, lc);
		const char *what = NULL;

		switch (nodeTag(rs->stmt))
		{
			case T_DeclareCursorStmt:
				what = "DECLARE CURSOR";
				break;
			case T_FetchStmt:
				what = ((FetchStmt *) rs->stmt)->ismove ? "MOVE" : "FETCH";
				break;
			case T_ClosePortalStmt:
				what = "CLOSE";
				break;
			default:
				break;
		}
		if (what)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig: %s is not allowed in SQL run by a PL/Zig function", what),
					 errhint("Use plzig.spi.open() for cursors.")));
	}
}

/*
 * Text parameters (spi_execute, spi_cursor_open): nparams slots, each NULL
 * or a text value.  Allocated in the current (scratch) context.
 */
static void
decode_text_params(wasm_exec_env_t env, uint32 params_ptr, uint32 nparams,
				   Oid **types, Datum **values, char **nulls)
{
	PlzigSlot  *copy;
	uint32		i;

	*types = NULL;
	*values = NULL;
	*nulls = NULL;
	if (nparams > PLZIG_MAX_SPI_PARAMS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: too many SPI parameters")));
	if (nparams == 0)
		return;

	/* nparams <= 65535, so the size cannot overflow */
	copy = palloc(sizeof(PlzigSlot) * nparams);
	memcpy(copy, plzig_guest_ptr(wasm_runtime_get_module_inst(env), params_ptr,
								 nparams * (uint32) sizeof(PlzigSlot)),
		   sizeof(PlzigSlot) * nparams);
	*types = palloc(sizeof(Oid) * nparams);
	*values = palloc(sizeof(Datum) * nparams);
	*nulls = palloc(nparams + 1);
	for (i = 0; i < nparams; i++)
	{
		(*types)[i] = TEXTOID;
		if (copy[i].is_null)
		{
			(*values)[i] = (Datum) 0;
			(*nulls)[i] = 'n';
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
			(*values)[i] = PointerGetDatum(cstring_to_text_with_len(v, (int) copy[i].len));
			(*nulls)[i] = ' ';
		}
	}
	(*nulls)[nparams] = '\0';
}

static const char *
kind_name(uint32 kind)
{
	switch (kind)
	{
		case PLZIG_KIND_NULL:
			return "null";
		case PLZIG_KIND_BOOL:
			return "bool";
		case PLZIG_KIND_INT2:
			return "i16";
		case PLZIG_KIND_INT4:
			return "i32";
		case PLZIG_KIND_INT8:
			return "i64";
		case PLZIG_KIND_FLOAT4:
			return "f32";
		case PLZIG_KIND_FLOAT8:
			return "f64";
		case PLZIG_KIND_TEXT:
			return "text";
		case PLZIG_KIND_BYTEA:
			return "bytea";
		case PLZIG_KIND_OTHER:
			return "other";
	}
	return "invalid";
}

/*
 * Typed parameters of a prepared statement.  The number and the type of
 * every parameter come from the plan (SPI_getargcount/SPI_getargtypeid);
 * the kind tag the guest put in each value must match, and the value must
 * be in range for the type.  Allocated in the current (scratch) context.
 */
static void
decode_typed_params(wasm_exec_env_t env, SPIPlanPtr plan, uint32 params_ptr,
					uint32 nparams, Datum **values, char **nulls)
{
	PlzigValue *copy;
	int			nargs = SPI_getargcount(plan);
	uint32		i;

	*values = NULL;
	*nulls = NULL;
	if (nargs < 0)
		elog(ERROR, "SPI_getargcount failed");
	if (nparams != (uint32) nargs)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: the prepared statement has %d parameter(s), but %u were passed",
						nargs, nparams)));
	if (nparams == 0)
		return;

	/* nargs <= 65535 (checked at prepare), so the size cannot overflow */
	copy = palloc(sizeof(PlzigValue) * nparams);
	memcpy(copy, plzig_guest_ptr(wasm_runtime_get_module_inst(env), params_ptr,
								 nparams * (uint32) sizeof(PlzigValue)),
		   sizeof(PlzigValue) * nparams);
	*values = palloc(sizeof(Datum) * nparams);
	*nulls = palloc(nparams + 1);
	for (i = 0; i < nparams; i++)
	{
		Oid			typid = SPI_getargtypeid(plan, (int) i);
		uint16		want = plzig_param_oid_kind(typid);
		PlzigValue *v = &copy[i];

		if (want == PLZIG_KIND_NULL)	/* cannot happen: we chose the types */
			elog(ERROR, "PL/Zig: unexpected parameter type %u", typid);
		if (v->is_null > 1)
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("PL/Zig: invalid NULL flag in parameter $%u", i + 1)));
		if (v->kind != want && !(v->is_null && v->kind == PLZIG_KIND_NULL))
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("PL/Zig: parameter $%u of the prepared statement is of type %s, but a value of kind %s was passed",
							i + 1, format_type_be(typid), kind_name(v->kind))));
		(*nulls)[i] = ' ';
		if (v->is_null)
		{
			(*values)[i] = (Datum) 0;
			(*nulls)[i] = 'n';
			continue;
		}
		switch (want)
		{
			case PLZIG_KIND_BOOL:
				if (v->val > 1)
					goto out_of_range;
				(*values)[i] = BoolGetDatum(v->val != 0);
				break;
			case PLZIG_KIND_INT2:
				if ((int64) v->val < PG_INT16_MIN || (int64) v->val > PG_INT16_MAX)
					goto out_of_range;
				(*values)[i] = Int16GetDatum((int16) (int64) v->val);
				break;
			case PLZIG_KIND_INT4:
				if ((int64) v->val < PG_INT32_MIN || (int64) v->val > PG_INT32_MAX)
					goto out_of_range;
				(*values)[i] = Int32GetDatum((int32) (int64) v->val);
				break;
			case PLZIG_KIND_INT8:
				(*values)[i] = Int64GetDatum((int64) v->val);
				break;
			case PLZIG_KIND_FLOAT4:
				{
					uint32		bits;
					float4		f;

					if (v->val > PG_UINT32_MAX)
						goto out_of_range;
					bits = (uint32) v->val;
					memcpy(&f, &bits, sizeof(f));
					(*values)[i] = Float4GetDatum(f);
					break;
				}
			case PLZIG_KIND_FLOAT8:
				{
					float8		f;

					memcpy(&f, &v->val, sizeof(f));
					(*values)[i] = Float8GetDatum(f);
					break;
				}
			case PLZIG_KIND_TEXT:
				{
					char	   *s;

					if (v->val > PG_UINT32_MAX && v->len > 0)
						goto bad_pointer;
					s = guest_string(env, (uint32) (v->val & PG_UINT32_MAX), v->len,
									 MaxAllocSize - VARHDRSZ - 1, "SPI parameter");
					(*values)[i] = PointerGetDatum(cstring_to_text_with_len(s, (int) v->len));
					pfree(s);
					break;
				}
			case PLZIG_KIND_BYTEA:
				{
					bytea	   *b;
					void	   *src;

					if (v->val > PG_UINT32_MAX && v->len > 0)
						goto bad_pointer;
					if ((Size) v->len > MaxAllocSize - VARHDRSZ)
						ereport(ERROR,
								(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
								 errmsg("PL/Zig: SPI parameter is too long")));
					src = plzig_guest_ptr(wasm_runtime_get_module_inst(env),
										  (uint32) (v->val & PG_UINT32_MAX), v->len);
					b = (bytea *) palloc(VARHDRSZ + (Size) v->len);
					SET_VARSIZE(b, VARHDRSZ + v->len);
					if (v->len > 0)
						memcpy(VARDATA(b), src, v->len);
					(*values)[i] = PointerGetDatum(b);
					break;
				}
		}
		continue;

out_of_range:
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("PL/Zig: value of parameter $%u is out of range for type %s",
						i + 1, format_type_be(typid))));
bad_pointer:
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: invalid SPI parameter pointer")));
	}
	(*nulls)[nparams] = '\0';
}

/* ---------------------------------------------------------------------
 * Typed rows
 * ---------------------------------------------------------------------
 */
static PlzigRowBuf *
rowbuf_create(MemoryContext parent)
{
	PlzigRowBuf *rb = MemoryContextAllocZero(parent, sizeof(PlzigRowBuf));

	rb->desc_cxt = AllocSetContextCreate(parent, "PL/Zig row descriptor",
										 ALLOCSET_SMALL_SIZES);
	rb->row_cxt = AllocSetContextCreate(parent, "PL/Zig row",
										ALLOCSET_DEFAULT_SIZES);
	rb->rowno = -1;
	return rb;
}

static void
rowbuf_forget_row(PlzigRowBuf *rb)
{
	rb->have_row = false;
	rb->rowno = -1;
	rb->row = NULL;
	rb->size = 0;
	MemoryContextReset(rb->row_cxt);
}

/* The source changed (new result): column info must be rebuilt. */
static void
rowbuf_forget_desc(PlzigRowBuf *rb)
{
	rowbuf_forget_row(rb);
	rb->have_desc = false;
	rb->natts = 0;
	rb->cols = NULL;
	MemoryContextReset(rb->desc_cxt);
}

/* Derive every column's kind from the actual tuple descriptor. */
static void
rowbuf_set_desc(PlzigRowBuf *rb, TupleDesc td)
{
	MemoryContext old;
	int			i;

	rowbuf_forget_desc(rb);
	old = MemoryContextSwitchTo(rb->desc_cxt);
	rb->cols = palloc0(sizeof(PlzigColInfo) * (td->natts > 0 ? td->natts : 1));
	for (i = 0; i < td->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(td, i);
		PlzigColInfo *ci = &rb->cols[i];

		ci->dropped = att->attisdropped;
		ci->kind = att->attisdropped ? PLZIG_KIND_OTHER : plzig_value_kind(att->atttypid);
		if (ci->kind == PLZIG_KIND_OTHER && !att->attisdropped)
		{
			Oid			outfunc;
			bool		isvarlena;

			getTypeOutputInfo(att->atttypid, &outfunc, &isvarlena);
			fmgr_info_cxt(outfunc, &ci->out, rb->desc_cxt);
		}
	}
	rb->natts = td->natts;
	rb->have_desc = true;
	MemoryContextSwitchTo(old);
}

static inline uint64
align8(uint64 n)
{
	return (n + 7) & ~(uint64) 7;
}

/*
 * Make tup (described by td, which has the same shape as the descriptor
 * given to rowbuf_set_desc) the current row: convert it and compute its
 * encoded size.  Everything is allocated in the row context.
 */
static void
rowbuf_load(PlzigRowBuf *rb, HeapTuple tup, TupleDesc td)
{
	MemoryContext old;
	Datum	   *values;
	bool	   *nulls;
	PlzigRowCol *row;
	uint64		size;
	int			natts = rb->natts;
	int			i;

	Assert(rb->have_desc);
	if (td->natts != natts)		/* cannot happen: same portal/result */
		elog(ERROR, "PL/Zig: row descriptor changed");
	rowbuf_forget_row(rb);
	old = MemoryContextSwitchTo(rb->row_cxt);
	values = palloc(sizeof(Datum) * (natts > 0 ? natts : 1));
	nulls = palloc(sizeof(bool) * (natts > 0 ? natts : 1));
	if (natts > 0)
		heap_deform_tuple(tup, td, values, nulls);
	row = palloc0(sizeof(PlzigRowCol) * (natts > 0 ? natts : 1));
	size = (uint64) natts * sizeof(PlzigValue);
	for (i = 0; i < natts; i++)
	{
		PlzigRowCol *c = &row[i];
		PlzigColInfo *ci = &rb->cols[i];
		uint64		len = 0;

		c->kind = ci->kind;
		if (nulls[i] || ci->dropped)
		{
			c->isnull = true;
			continue;
		}
		switch (ci->kind)
		{
			case PLZIG_KIND_BOOL:
				c->val = DatumGetBool(values[i]) ? 1 : 0;
				break;
			case PLZIG_KIND_INT2:
				c->val = (uint64) (int64) DatumGetInt16(values[i]);
				break;
			case PLZIG_KIND_INT4:
				c->val = (uint64) (int64) DatumGetInt32(values[i]);
				break;
			case PLZIG_KIND_INT8:
				c->val = (uint64) DatumGetInt64(values[i]);
				break;
			case PLZIG_KIND_FLOAT4:
				{
					float4		f = DatumGetFloat4(values[i]);
					uint32		bits;

					memcpy(&bits, &f, sizeof(bits));
					c->val = bits;
					break;
				}
			case PLZIG_KIND_FLOAT8:
				{
					float8		f = DatumGetFloat8(values[i]);

					memcpy(&c->val, &f, sizeof(f));
					break;
				}
			case PLZIG_KIND_TEXT:
			case PLZIG_KIND_BYTEA:
				{
					struct varlena *v = PG_DETOAST_DATUM_PACKED(values[i]);

					c->data = VARDATA_ANY(v);
					len = VARSIZE_ANY_EXHDR(v);
					break;
				}
			default:
				c->data = OutputFunctionCall(&ci->out, values[i]);
				len = strlen(c->data);
				break;
		}
		if (len > PLZIG_MAX_ROW_SIZE)
			goto too_large;
		c->len = (uint32) len;
		size += align8(len);
		if (size > PLZIG_MAX_ROW_SIZE)
			goto too_large;
	}
	MemoryContextSwitchTo(old);
	rb->row = row;
	rb->size = size;
	rb->have_row = true;
	return;

too_large:
	ereport(ERROR,
			(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
			 errmsg("PL/Zig: result row is too large")));
}

/*
 * Copy the current row into guest memory at [buf, buf + buf_len): natts
 * values, then the bytes of the byte-kind values (8-byte aligned), whose
 * val fields hold their guest addresses.  Returns the number of columns.
 */
static int32
rowbuf_write(wasm_exec_env_t env, PlzigRowBuf *rb, uint32 buf, uint32 buf_len)
{
	uint8	   *base;
	uint64		off;
	int			i;

	if (!rb->have_row)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: there is no current row")));
	if ((uint64) buf_len < rb->size)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: row buffer is too small")));
	if (rb->size == 0)
		return 0;
	/* validates [buf, buf + size); size <= MaxAllocSize */
	base = plzig_guest_ptr(wasm_runtime_get_module_inst(env), buf, (uint32) rb->size);
	off = (uint64) rb->natts * sizeof(PlzigValue);
	for (i = 0; i < rb->natts; i++)
	{
		PlzigRowCol *c = &rb->row[i];
		PlzigValue	v;

		memset(&v, 0, sizeof(v));
		v.kind = c->kind;
		v.is_null = c->isnull ? 1 : 0;
		if (!c->isnull)
		{
			if (c->kind == PLZIG_KIND_TEXT || c->kind == PLZIG_KIND_BYTEA ||
				c->kind == PLZIG_KIND_OTHER)
			{
				Assert(off + c->len <= rb->size);
				v.len = c->len;
				v.val = (uint64) buf + off;
				if (c->len > 0)
					memcpy(base + off, c->data, c->len);
				off += align8(c->len);
			}
			else
				v.val = c->val;
		}
		memcpy(base + (Size) i * sizeof(PlzigValue), &v, sizeof(v));
	}
	return (int32) rb->natts;
}

/* ---------------------------------------------------------------------
 * SPI: execute (text parameters) and the last result
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

/* Free the last result and everything derived from it. */
static void
spi_reset_result(PlzigCallCtx *ctx)
{
	spi_forget_cache(ctx);
	if (ctx->result_row)
		rowbuf_forget_desc(ctx->result_row);
	if (ctx->tuptable)
	{
		SPI_freetuptable((SPITupleTable *) ctx->tuptable);
		ctx->tuptable = NULL;
		ctx->ntuples = 0;
	}
}

/* Take over SPI_tuptable after an execution; returns the row count. */
static int64
spi_store_result(PlzigCallCtx *ctx, int rc)
{
	if (rc < 0)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: SPI_execute failed: %s", SPI_result_code_string(rc))));
	ctx->tuptable = SPI_tuptable;
	ctx->ntuples = SPI_tuptable ? SPI_tuptable->numvals : 0;
	SPI_tuptable = NULL;
	return SPI_processed > (uint64) PG_INT64_MAX ? PG_INT64_MAX : (int64) SPI_processed;
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
		Oid		   *types;
		Datum	   *values;
		char	   *nulls;
		int			rc;

		MemoryContextReset(ctx->scratch);
		MemoryContextSwitchTo(ctx->scratch);
		sql = guest_string(env, sql_ptr, sql_len, MaxAllocSize - 1, "SQL statement");
		decode_text_params(env, params_ptr, nparams, &types, &values, &nulls);
		check_sql(sql);

		spi_connect_if_needed(ctx);
		spi_reset_result(ctx);

		rc = SPI_execute_with_args(sql, (int) nparams, types, values, nulls,
								   ctx->read_only, 0);
		result = spi_store_result(ctx, rc);
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(ctx->scratch);
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

static SPITupleTable *
spi_result_row(PlzigCallCtx *ctx, uint32 row)
{
	SPITupleTable *tt = (SPITupleTable *) ctx->tuptable;

	if (tt == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: no SPI result available")));
	if ((uint64) row >= ctx->ntuples)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: SPI result row %u is out of range", row)));
	return tt;
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

/* Select row `row` of the last result for typed reading. */
static PlzigRowBuf *
spi_select_result_row(PlzigCallCtx *ctx, uint32 row)
{
	SPITupleTable *tt = spi_result_row(ctx, row);
	PlzigRowBuf *rb;

	if (ctx->result_row == NULL)
		ctx->result_row = rowbuf_create(ctx->cxt);
	rb = ctx->result_row;
	/* spi_reset_result forgets the descriptor whenever the result changes */
	if (!rb->have_desc)
		rowbuf_set_desc(rb, tt->tupdesc);
	if (!rb->have_row || rb->rowno != (int64) row)
	{
		rowbuf_load(rb, tt->vals[row], tt->tupdesc);
		rb->rowno = row;
	}
	return rb;
}

static int64
host_spi_row_size(wasm_exec_env_t env, uint32 row)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		result = (int64) spi_select_result_row(ctx, row)->size;
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
host_spi_row_read(wasm_exec_env_t env, uint32 row, uint32 buf, uint32 buf_len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		result = rowbuf_write(env, spi_select_result_row(ctx, row), buf, buf_len);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

/* ---------------------------------------------------------------------
 * SPI: prepared statements (per instance)
 * ---------------------------------------------------------------------
 */

/*
 * The entry for handle in the calling instance's own table, or ERROR.  The
 * table belongs to ctx->inst, the instance running this call, so a handle
 * can never reach a plan of another instance (another function, or another
 * instance of the same function, e.g. in recursion).
 */
static PlzigPlanEntry *
plan_lookup(PlzigCallCtx *ctx, uint64 handle)
{
	PlzigPlanTable *t = plzig_instance_plans(ctx->inst);
	uint64		idx = handle & PLZIG_HANDLE_MAX_INDEX;
	uint64		serial = handle >> PLZIG_HANDLE_INDEX_BITS;

	if (serial == 0 || idx >= (uint64) t->size ||
		t->entries[idx].plan == NULL || t->entries[idx].serial != serial)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: invalid prepared statement handle")));
	return &t->entries[idx];
}

/*
 * Free every plan of an instance.  Called by plzig_instance_destroy, also
 * from PG_CATCH blocks: must not throw (SPI_freeplan does not).
 */
void
plzig_host_free_plans(PlzigPlanTable *t)
{
	int			i;

	for (i = 0; i < t->size; i++)
	{
		SPIPlanPtr	plan = t->entries[i].plan;

		t->entries[i].plan = NULL;
		t->entries[i].serial = 0;
		if (plan)
			(void) SPI_freeplan(plan);
	}
	if (t->entries)
		pfree(t->entries);
	t->entries = NULL;
	t->size = 0;
	t->nlive = 0;
}

static int64
host_spi_prepare(wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len,
				 uint32 kinds_ptr, uint32 nkinds)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = 0;

	if (ctx == NULL)
		return 0;
	PG_TRY();
	{
		PlzigPlanTable *t = plzig_instance_plans(ctx->inst);
		char	   *sql;
		Oid		   *types;
		uint32	   *kinds;
		uint32		i;
		int			idx;
		SPIPlanPtr	plan;
		uint64		serial;

		MemoryContextReset(ctx->scratch);
		MemoryContextSwitchTo(ctx->scratch);
		sql = guest_string(env, sql_ptr, sql_len, MaxAllocSize - 1, "SQL statement");
		if (nkinds > PLZIG_MAX_SPI_PARAMS)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("PL/Zig: too many SPI parameters")));
		types = palloc(sizeof(Oid) * (nkinds > 0 ? nkinds : 1));
		if (nkinds > 0)
		{
			kinds = palloc(sizeof(uint32) * nkinds);
			memcpy(kinds, plzig_guest_ptr(wasm_runtime_get_module_inst(env), kinds_ptr,
										  nkinds * (uint32) sizeof(uint32)),
				   sizeof(uint32) * nkinds);
			for (i = 0; i < nkinds; i++)
			{
				types[i] = plzig_param_kind_oid(kinds[i]);
				if (!OidIsValid(types[i]))
					ereport(ERROR,
							(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
							 errmsg("PL/Zig: invalid type code %u for parameter $%u",
									kinds[i], i + 1)));
			}
		}
		check_sql(sql);

		if (t->nlive >= plzig_max_prepared_plans)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("PL/Zig: too many prepared statements (%d)", t->nlive),
					 errhint("Free prepared statements that are no longer needed, or raise plzig.max_prepared_plans.")));

		/* find a free entry, growing the table first: nothing may fail later */
		for (idx = 0; idx < t->size; idx++)
			if (t->entries[idx].plan == NULL)
				break;
		if (idx == t->size)
		{
			int			newsize = t->size == 0 ? 8 : t->size * 2;

			if (newsize > PLZIG_HANDLE_MAX_INDEX + 1)
				newsize = PLZIG_HANDLE_MAX_INDEX + 1;
			if (newsize <= t->size)
				elog(ERROR, "PL/Zig: prepared statement table is full");
			if (t->entries == NULL)
				t->entries = MemoryContextAllocZero(plzig_runtime_context(),
													sizeof(PlzigPlanEntry) * newsize);
			else
			{
				t->entries = repalloc(t->entries, sizeof(PlzigPlanEntry) * newsize);
				memset(&t->entries[t->size], 0,
					   sizeof(PlzigPlanEntry) * (newsize - t->size));
			}
			t->size = newsize;
		}

		spi_connect_if_needed(ctx);
		/* no scrolling for cursors opened from this plan; planning unaffected */
		plan = SPI_prepare_cursor(sql, (int) nkinds, types, CURSOR_OPT_NO_SCROLL);
		if (plan == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("PL/Zig: SPI_prepare failed: %s",
							SPI_result_code_string(SPI_result))));
		/* until SPI_keepplan the plan belongs to the SPI connection */
		if (SPI_keepplan(plan) != 0)
			elog(ERROR, "PL/Zig: SPI_keepplan failed");
		/* from here on nothing can fail: the plan is owned by the table */
		serial = next_serial();
		t->entries[idx].plan = plan;
		t->entries[idx].serial = serial;
		t->nlive++;
		result = (int64) make_handle(serial, idx);
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(ctx->scratch);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = 0;
	}
	PG_END_TRY();
	return result;
}

static void
host_spi_plan_free(wasm_exec_env_t env, uint64 handle)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx == NULL)
		return;
	PG_TRY();
	{
		PlzigPlanEntry *e = plan_lookup(ctx, handle);
		PlzigPlanTable *t = plzig_instance_plans(ctx->inst);
		SPIPlanPtr	plan = e->plan;

		e->plan = NULL;
		e->serial = 0;
		t->nlive--;
		(void) SPI_freeplan(plan);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
	}
	PG_END_TRY();
}

static int64
host_spi_execute_plan(wasm_exec_env_t env, uint64 handle, uint32 params_ptr,
					  uint32 nparams)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = 0;

	if (ctx == NULL)
		return 0;
	PG_TRY();
	{
		SPIPlanPtr	plan = plan_lookup(ctx, handle)->plan;
		Datum	   *values;
		char	   *nulls;
		int			rc;

		MemoryContextReset(ctx->scratch);
		MemoryContextSwitchTo(ctx->scratch);
		decode_typed_params(env, plan, params_ptr, nparams, &values, &nulls);

		spi_connect_if_needed(ctx);
		spi_reset_result(ctx);
		/* read-only is decided per execution, from the function's volatility */
		rc = SPI_execute_plan(plan, values, nulls, ctx->read_only, 0);
		result = spi_store_result(ctx, rc);
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(ctx->scratch);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = 0;
	}
	PG_END_TRY();
	return result;
}

/* ---------------------------------------------------------------------
 * SPI: cursors (per call)
 * ---------------------------------------------------------------------
 */

/* The entry for handle in the current call's table, or ERROR. */
static PlzigCursor *
cursor_lookup(PlzigCallCtx *ctx, uint64 handle)
{
	uint64		idx = handle & PLZIG_HANDLE_MAX_INDEX;
	uint64		serial = handle >> PLZIG_HANDLE_INDEX_BITS;

	if (serial == 0 || idx >= (uint64) ctx->ncursors ||
		ctx->cursors[idx].serial != serial)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: invalid cursor handle")));
	return &ctx->cursors[idx];
}

/*
 * The cursor's portal, found by name and checked against the pointer we
 * got when opening it.  Portals are pinned, so nothing but a (sub)transaction
 * abort can drop them during the call; never use a stale pointer anyway.
 */
static Portal
cursor_portal(PlzigCursor *c, bool missing_ok)
{
	Portal		p = GetPortalByName(c->portal_name);

	if (!PortalIsValid(p) || p != c->portal)
	{
		if (missing_ok)
			return NULL;
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_CURSOR_STATE),
				 errmsg("PL/Zig: the cursor's portal no longer exists")));
	}
	return p;
}

/* Release the batch and close the portal (end reached, close, call end). */
static void
cursor_finish(PlzigCursor *c)
{
	Portal		p;

	rowbuf_forget_row(c->rb);
	if (c->batch)
	{
		SPI_freetuptable(c->batch);
		c->batch = NULL;
	}
	if (!c->finished)
	{
		c->finished = true;
		p = cursor_portal(c, true);
		if (p)
		{
			/* still pinned: only (sub)transaction cleanup unpins, and drops */
			if (p->portalPinned)
				UnpinPortal(p);
			SPI_cursor_close(p);
		}
	}
}

/* Close the cursor and free its table entry. */
static void
cursor_release(PlzigCallCtx *ctx, PlzigCursor *c)
{
	cursor_finish(c);
	c->serial = 0;
	ctx->nopen--;
	MemoryContextDelete(c->cxt);
	memset(c, 0, sizeof(*c));
}

/*
 * Reserve a free cursor entry (enforcing plzig.max_open_cursors) and give it
 * its memory context.  The entry stays free (serial 0) until a portal has
 * been attached by cursor_attach.
 */
static PlzigCursor *
cursor_reserve(PlzigCallCtx *ctx, int *index)
{
	PlzigCursor *c;
	int			idx;

	if (ctx->nopen >= plzig_max_open_cursors)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: too many open cursors (%d)", ctx->nopen),
				 errhint("Close cursors that are no longer needed, or raise plzig.max_open_cursors.")));
	for (idx = 0; idx < ctx->ncursors; idx++)
		if (ctx->cursors[idx].serial == 0)
			break;
	if (idx == ctx->ncursors)
	{
		int			newsize = ctx->ncursors == 0 ? 4 : ctx->ncursors * 2;

		if (newsize > PLZIG_HANDLE_MAX_INDEX + 1)
			newsize = PLZIG_HANDLE_MAX_INDEX + 1;
		if (newsize <= ctx->ncursors)
			elog(ERROR, "PL/Zig: cursor table is full");
		if (ctx->cursors == NULL)
			ctx->cursors = MemoryContextAllocZero(ctx->cxt, sizeof(PlzigCursor) * newsize);
		else
		{
			ctx->cursors = repalloc(ctx->cursors, sizeof(PlzigCursor) * newsize);
			memset(&ctx->cursors[ctx->ncursors], 0,
				   sizeof(PlzigCursor) * (newsize - ctx->ncursors));
		}
		ctx->ncursors = newsize;
	}
	c = &ctx->cursors[idx];
	if (c->cxt == NULL)
		c->cxt = AllocSetContextCreate(ctx->cxt, "PL/Zig cursor", ALLOCSET_SMALL_SIZES);
	*index = idx;
	return c;
}

/* Attach a freshly opened portal to a reserved entry; returns the handle. */
static uint64
cursor_attach(PlzigCallCtx *ctx, PlzigCursor *c, int idx, Portal portal)
{
	if (portal == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: SPI_cursor_open failed: %s",
						SPI_result_code_string(SPI_result))));
	c->portal_name = MemoryContextStrdup(c->cxt, portal->name);
	c->rb = rowbuf_create(c->cxt);
	c->portal = portal;
	/* nobody else (CLOSE, CLOSE ALL in nested SQL) can drop it now */
	PinPortal(portal);
	c->serial = next_serial();
	ctx->nopen++;
	return make_handle(c->serial, idx);
}

static int64
host_spi_cursor_open(wasm_exec_env_t env, uint32 sql_ptr, uint32 sql_len,
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
		Oid		   *types;
		Datum	   *values;
		char	   *nulls;
		PlzigCursor *c;
		int			idx;
		Portal		portal;

		MemoryContextReset(ctx->scratch);
		MemoryContextSwitchTo(ctx->scratch);
		sql = guest_string(env, sql_ptr, sql_len, MaxAllocSize - 1, "SQL statement");
		decode_text_params(env, params_ptr, nparams, &types, &values, &nulls);
		check_sql(sql);
		c = cursor_reserve(ctx, &idx);

		spi_connect_if_needed(ctx);
		/* forward-only; read-only unless the function is VOLATILE */
		portal = SPI_cursor_open_with_args(NULL, sql, (int) nparams, types, values,
										   nulls, ctx->read_only, CURSOR_OPT_NO_SCROLL);
		result = (int64) cursor_attach(ctx, c, idx, portal);
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(ctx->scratch);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = 0;
	}
	PG_END_TRY();
	return result;
}

static int64
host_spi_cursor_open_plan(wasm_exec_env_t env, uint64 handle, uint32 params_ptr,
						  uint32 nparams)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = 0;

	if (ctx == NULL)
		return 0;
	PG_TRY();
	{
		SPIPlanPtr	plan = plan_lookup(ctx, handle)->plan;
		Datum	   *values;
		char	   *nulls;
		PlzigCursor *c;
		int			idx;
		Portal		portal;

		MemoryContextReset(ctx->scratch);
		MemoryContextSwitchTo(ctx->scratch);
		decode_typed_params(env, plan, params_ptr, nparams, &values, &nulls);
		c = cursor_reserve(ctx, &idx);

		spi_connect_if_needed(ctx);
		/*
		 * The portal depends only on the CachedPlan it holds a reference to
		 * (and copies of the query string and parameters), so freeing the
		 * prepared statement while the cursor is open is safe.
		 */
		portal = SPI_cursor_open(NULL, plan, values, nulls, ctx->read_only);
		result = (int64) cursor_attach(ctx, c, idx, portal);
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(ctx->scratch);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = 0;
	}
	PG_END_TRY();
	return result;
}

/*
 * Advance to the next row.  Returns the encoded size of the row (read it
 * with spi_cursor_read), or -1 at the end.  Rows are fetched from the portal
 * PLZIG_CURSOR_BATCH at a time; the previous batch is freed first.
 */
static int64
host_spi_cursor_next(wasm_exec_env_t env, uint64 handle)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int64		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		PlzigCursor *c = cursor_lookup(ctx, handle);

		rowbuf_forget_row(c->rb);	/* the old row may point into the batch */
		if (c->finished)
			result = -1;
		else
		{
			if (c->batch == NULL || c->batch_pos >= c->batch->numvals)
			{
				Portal		p;

				if (c->batch)
				{
					SPI_freetuptable(c->batch);
					c->batch = NULL;
				}
				p = cursor_portal(c, false);
				SPI_cursor_fetch(p, true, PLZIG_CURSOR_BATCH);
				c->batch = SPI_tuptable;
				SPI_tuptable = NULL;
				c->batch_pos = 0;
				if (c->batch && !c->rb->have_desc)
					rowbuf_set_desc(c->rb, c->batch->tupdesc);
			}
			if (c->batch == NULL || c->batch_pos >= c->batch->numvals)
			{
				cursor_finish(c);
				result = -1;
			}
			else
			{
				rowbuf_load(c->rb, c->batch->vals[c->batch_pos], c->batch->tupdesc);
				c->batch_pos++;
				result = (int64) c->rb->size;
			}
		}
		MemoryContextSwitchTo(oldcxt);
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
host_spi_cursor_read(wasm_exec_env_t env, uint64 handle, uint32 buf, uint32 buf_len)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;
	int32		result = -1;

	if (ctx == NULL)
		return -1;
	PG_TRY();
	{
		result = rowbuf_write(env, cursor_lookup(ctx, handle)->rb, buf, buf_len);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
		result = -1;
	}
	PG_END_TRY();
	return result;
}

static void
host_spi_cursor_close(wasm_exec_env_t env, uint64 handle)
{
	PlzigCallCtx *ctx = host_ctx(env);
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx == NULL)
		return;
	PG_TRY();
	{
		cursor_release(ctx, cursor_lookup(ctx, handle));
		MemoryContextSwitchTo(oldcxt);
	}
	PG_CATCH();
	{
		host_catch(ctx, env, oldcxt);
	}
	PG_END_TRY();
}

/*
 * Called by the call handler after a successful guest call: close every
 * cursor the guest left open, then end the SPI connection (which frees all
 * remaining tuple tables).  After a failed call the (sub)transaction abort
 * drops the portals and the SPI connection.
 */
void
plzig_host_finish_call(PlzigCallCtx *ctx)
{
	int			i;

	spi_forget_cache(ctx);
	for (i = 0; i < ctx->ncursors; i++)
		if (ctx->cursors[i].serial != 0)
			cursor_release(ctx, &ctx->cursors[i]);
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
/* names must match plzig_known_imports in plzig_runtime.c */
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
	{"spi_row_size", (void *) host_spi_row_size, "(i)I", NULL},
	{"spi_row_read", (void *) host_spi_row_read, "(iii)i", NULL},
	{"spi_prepare", (void *) host_spi_prepare, "(iiii)I", NULL},
	{"spi_plan_free", (void *) host_spi_plan_free, "(I)", NULL},
	{"spi_execute_plan", (void *) host_spi_execute_plan, "(Iii)I", NULL},
	{"spi_cursor_open", (void *) host_spi_cursor_open, "(iiii)I", NULL},
	{"spi_cursor_open_plan", (void *) host_spi_cursor_open_plan, "(Iii)I", NULL},
	{"spi_cursor_next", (void *) host_spi_cursor_next, "(I)I", NULL},
	{"spi_cursor_read", (void *) host_spi_cursor_read, "(Iii)i", NULL},
	{"spi_cursor_close", (void *) host_spi_cursor_close, "(I)", NULL},
};

void *
plzig_host_symbols(int *n)
{
	*n = lengthof(plzig_native_symbols);
	return plzig_native_symbols;
}
