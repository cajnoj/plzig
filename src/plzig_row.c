/*-------------------------------------------------------------------------
 *
 * plzig_row.c
 *	  Rows: composite arguments and results of PL/Zig functions (structs in
 *	  the guest).  See doc/abi.md, "Rows".
 *
 *	  Host -> guest: a composite argument is converted like a typed SPI row
 *	  (plzig_host.c, PlzigRowBuf) and encoded into the argument block, one
 *	  value per live attribute.
 *
 *	  Guest -> host: a row is an array of values (PlzigValue), one per live
 *	  attribute of the row type, in order.  Every value is untrusted: its
 *	  NULL flag and kind are checked against the attribute (the kind is
 *	  derived by the host from the attribute's type, never taken from the
 *	  guest), pointers and lengths are validated before anything is copied,
 *	  the value is range-checked exactly like an SPI parameter of that type
 *	  (or parsed by the type's input function), the attribute's typmod is
 *	  applied, and the tuple is built by the host (heap_form_tuple) with the
 *	  row type's own descriptor.  A guest never hands over a datum, a tuple
 *	  or a binary jsonb.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/htup_details.h"
#include "access/tupdesc.h"
#include "catalog/pg_type.h"
#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "parser/parse_coerce.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/tuplestore.h"
#include "utils/typcache.h"

#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

/* ---------------------------------------------------------------------
 * Row descriptors
 * ---------------------------------------------------------------------
 */

/*
 * Field information for attribute att.  For results (for_result) the
 * input function of the text-like kinds and the length coercion function
 * of the native kinds with a typmod are looked up once here.
 */
void
plzig_field_init(PlzigField *f, Form_pg_attribute att, bool for_result, MemoryContext cxt)
{
	memset(f, 0, sizeof(*f));
	f->typid = att->atttypid;
	f->typmod = att->atttypmod;
	f->dropped = att->attisdropped;
	f->name = MemoryContextStrdup(cxt, NameStr(att->attname));
	f->where = MemoryContextStrdup(cxt, psprintf("field \"%s\"", NameStr(att->attname)));
	if (f->dropped)
	{
		f->kind = PLZIG_KIND_OTHER;
		return;
	}
	f->kind = plzig_value_kind(f->typid);
	if (!for_result)
		return;
	/*
	 * text-like kinds other than text itself (varchar and bpchar, whose input
	 * functions apply the typmod), text-represented types and jsonb: the
	 * type's input function; text: the bytes, encoding-checked
	 */
	if ((f->kind == PLZIG_KIND_TEXT && f->typid != TEXTOID) ||
		f->kind == PLZIG_KIND_OTHER || f->kind == PLZIG_KIND_JSONB)
	{
		Oid			infunc;

		getTypeInputInfo(f->typid, &infunc, &f->ioparam);
		fmgr_info_cxt(infunc, &f->in_func, cxt);
		f->have_in = true;
		return;
	}
	switch (f->kind)
	{
		case PLZIG_KIND_TEXT:
		case PLZIG_KIND_OTHER:
		case PLZIG_KIND_JSONB:
			break;
		case PLZIG_KIND_BOOL:
		case PLZIG_KIND_INT2:
		case PLZIG_KIND_INT4:
		case PLZIG_KIND_INT8:
		case PLZIG_KIND_FLOAT4:
		case PLZIG_KIND_FLOAT8:
		case PLZIG_KIND_BYTEA:
		case PLZIG_KIND_DATE:
		case PLZIG_KIND_OID:
		case PLZIG_KIND_UUID:
			break;				/* no typmod */
		default:
			/* time, timetz, timestamp, timestamptz, interval, numeric */
			if (f->typmod >= 0)
			{
				Oid			funcid;

				if (find_typmod_coercion_function(f->typid, &funcid) == COERCION_PATH_FUNC)
				{
					fmgr_info_cxt(funcid, &f->coerce, cxt);
					f->have_coerce = true;
				}
			}
			break;
	}
}

static PlzigRowDesc *
rowdesc_build(TupleDesc td, Oid typid, uint64 id, bool for_result, MemoryContext cxt)
{
	PlzigRowDesc *rd = MemoryContextAllocZero(cxt, sizeof(PlzigRowDesc));
	MemoryContext old = MemoryContextSwitchTo(cxt);
	int			i;

	rd->tupdesc = CreateTupleDescCopy(td);
	rd->typid = typid;
	rd->tupdesc_id = id;
	rd->natts = td->natts;
	rd->fields = palloc0(sizeof(PlzigField) * (td->natts > 0 ? td->natts : 1));
	for (i = 0; i < td->natts; i++)
	{
		plzig_field_init(&rd->fields[i], TupleDescAttr(td, i), for_result, cxt);
		if (!rd->fields[i].dropped)
			rd->nlive++;
	}
	MemoryContextSwitchTo(old);
	return rd;
}

/*
 * The fields of named composite type typid, as the type cache has it now
 * (its tupDesc_identifier is kept, see plzig_rowdesc_current).
 */
PlzigRowDesc *
plzig_rowdesc_for_type(Oid typid, bool for_result, MemoryContext cxt)
{
	TypeCacheEntry *tce = lookup_type_cache(typid, TYPECACHE_TUPDESC);

	if (tce->tupDesc == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("type %s is not composite", format_type_be(typid))));
	return rowdesc_build(tce->tupDesc, typid, tce->tupDesc_identifier, for_result, cxt);
}

/*
 * The fields of the result row described by td (OUT/INOUT parameters:
 * RECORD).  The copy is blessed, so that the tuples built with it can be
 * interpreted by the caller.
 */
PlzigRowDesc *
plzig_rowdesc_for_tupdesc(TupleDesc td, MemoryContext cxt)
{
	PlzigRowDesc *rd = rowdesc_build(td, td->tdtypeid, 0, true, cxt);
	MemoryContext old = MemoryContextSwitchTo(cxt);

	if (rd->typid == RECORDOID)
		BlessTupleDesc(rd->tupdesc);
	MemoryContextSwitchTo(old);
	return rd;
}

/*
 * Is the row type still what the descriptor (and so the generated struct)
 * was built from?  RECORD descriptors come from pg_proc (a change replaces
 * the function).  For a named composite type the type cache's identifier
 * changes whenever the type (or the table) might have changed; then the
 * attributes are compared.  The caller rebuilds the function, or refuses a
 * result, when they differ: a stale row type is never trusted.
 */
bool
plzig_rowdesc_current(PlzigRowDesc *rd)
{
	TypeCacheEntry *tce;

	if (rd->typid == RECORDOID)
		return true;
	tce = lookup_type_cache(rd->typid, TYPECACHE_TUPDESC);
	if (tce->tupDesc == NULL)
		return false;
	if (tce->tupDesc_identifier == rd->tupdesc_id)
		return true;
	if (!equalTupleDescs(tce->tupDesc, rd->tupdesc))
		return false;
	rd->tupdesc_id = tce->tupDesc_identifier;
	return true;
}

/* ---------------------------------------------------------------------
 * Host -> guest: composite arguments
 * ---------------------------------------------------------------------
 */

/*
 * Convert a composite argument for the guest: a PlzigRowBuf in cxt (the
 * call's context: never shared with another call, e.g. a recursive one
 * that runs while this call's arguments are being placed) holding the
 * argument's live attributes.  *size is the size of its encoding
 * (plzig_rowbuf_encode with live_only).
 */
PlzigRowBuf *
plzig_row_arg_load(PlzigRowDesc *rd, Datum value, MemoryContext cxt, uint64 *size)
{
	HeapTupleHeader th = DatumGetHeapTupleHeader(value);
	HeapTupleData tmp;
	PlzigRowBuf *rb;

	if (HeapTupleHeaderGetTypeId(th) != rd->typid ||
		HeapTupleHeaderGetNatts(th) > rd->natts)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("PL/Zig: composite argument does not match its declared type %s",
						format_type_be(rd->typid))));
	tmp.t_len = HeapTupleHeaderGetDatumLength(th);
	ItemPointerSetInvalid(&tmp.t_self);
	tmp.t_tableOid = InvalidOid;
	tmp.t_data = th;

	rb = plzig_rowbuf_create(cxt);
	plzig_rowbuf_set_desc(rb, rd->tupdesc);
	plzig_rowbuf_load(rb, &tmp, rd->tupdesc);
	*size = plzig_rowbuf_size(rb, true);
	return rb;
}

/* ---------------------------------------------------------------------
 * Guest -> host: rows
 * ---------------------------------------------------------------------
 */

static const char *
kind_label(uint16 kind)
{
	static const char *const names[] = {
		"null", "bool", "i16", "i32", "i64", "f32", "f64", "text", "bytea", "other",
		"date", "time", "timetz", "timestamp", "timestamptz", "interval", "uuid", "oid",
		"numeric", "jsonb"
	};

	return kind < lengthof(names) ? names[kind] : "invalid";
}

/* text, bytea and other carry bytes and are interchangeable in guest values */
static inline bool
bytes_kind(uint16 kind)
{
	return kind == PLZIG_KIND_TEXT || kind == PLZIG_KIND_BYTEA || kind == PLZIG_KIND_OTHER;
}

/*
 * Copy [ptr, ptr + len) of guest memory into a new palloc'd buffer with
 * `extra` bytes in front (a varlena header) and a NUL after it.  The native
 * pointer is used for this copy only.
 */
static char *
guest_copy(void *mi, uint64 ptr, uint32 len, Size extra, const char *where)
{
	char	   *buf;

	if (ptr > PG_UINT32_MAX && len > 0)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: invalid pointer in %s", where)));
	if ((Size) len + extra + 1 > MaxAllocSize)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: %s is too long", where)));
	buf = palloc(extra + (Size) len + 1);
	if (len > 0)
		memcpy(buf + extra, plzig_guest_ptr(mi, (uint32) ptr, len), len);
	buf[extra + len] = '\0';
	return buf;
}

static Datum
apply_typmod(PlzigField *f, Datum d)
{
	if (!f->have_coerce)
		return d;
	if (f->coerce.fn_nargs == 2)
		return FunctionCall2(&f->coerce, d, Int32GetDatum(f->typmod));
	return FunctionCall3(&f->coerce, d, Int32GetDatum(f->typmod), BoolGetDatum(false));
}

/*
 * The Datum of one field from a guest value v, checked as described at the
 * top of this file.  f must have been initialised for results.
 */
Datum
plzig_field_from_guest(void *mi, PlzigField *f, const PlzigValue *v, const char *what,
					   bool *isnull)
{
	*isnull = false;
	if (v->is_null > 1)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: invalid NULL flag in %s of %s", f->where, what)));
	if (v->kind != f->kind && !(bytes_kind(v->kind) && bytes_kind(f->kind)) &&
		!(v->is_null && v->kind == PLZIG_KIND_NULL))
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("PL/Zig: %s of %s is of type %s, but a value of kind %s was passed",
						f->where, what, format_type_with_typemod(f->typid, f->typmod),
						kind_label(v->kind))));
	if (v->is_null)
	{
		/* NULL through a domain's input function: its NOT NULL and CHECK constraints */
		if (f->have_in && f->kind == PLZIG_KIND_OTHER)
			(void) InputFunctionCall(&f->in_func, NULL, f->ioparam, f->typmod);
		*isnull = true;
		return (Datum) 0;
	}
	switch (f->kind)
	{
		case PLZIG_KIND_BOOL:
			if (v->val > 1)
				goto out_of_range;
			return BoolGetDatum(v->val != 0);
		case PLZIG_KIND_INT2:
			if ((int64) v->val < PG_INT16_MIN || (int64) v->val > PG_INT16_MAX)
				goto out_of_range;
			return Int16GetDatum((int16) (int64) v->val);
		case PLZIG_KIND_INT4:
			if ((int64) v->val < PG_INT32_MIN || (int64) v->val > PG_INT32_MAX)
				goto out_of_range;
			return Int32GetDatum((int32) (int64) v->val);
		case PLZIG_KIND_INT8:
			return Int64GetDatum((int64) v->val);
		case PLZIG_KIND_FLOAT4:
			{
				uint32		bits;
				float4		x;

				if (v->val > PG_UINT32_MAX)
					goto out_of_range;
				bits = (uint32) v->val;
				memcpy(&x, &bits, sizeof(x));
				return Float4GetDatum(x);
			}
		case PLZIG_KIND_FLOAT8:
			{
				float8		x;

				memcpy(&x, &v->val, sizeof(x));
				return Float8GetDatum(x);
			}
		case PLZIG_KIND_BYTEA:
			{
				char	   *b = guest_copy(mi, v->val, v->len, VARHDRSZ, f->where);

				SET_VARSIZE(b, VARHDRSZ + v->len);
				return PointerGetDatum(b);
			}
		case PLZIG_KIND_TEXT:
		case PLZIG_KIND_OTHER:
		case PLZIG_KIND_JSONB:
			if (!f->have_in)
			{
				/* text: the bytes, valid in the database encoding, no NUL */
				char	   *b;

				if (f->kind != PLZIG_KIND_TEXT)	/* cannot happen: see plzig_field_init */
					elog(ERROR, "PL/Zig: field without an input function");
				b = guest_copy(mi, v->val, v->len, VARHDRSZ, f->where);

				SET_VARSIZE(b, VARHDRSZ + v->len);
				(void) pg_verifymbstr(b + VARHDRSZ, (int) v->len, false);
				return PointerGetDatum(b);
			}
			else
			{
				/*
				 * the type's input function, with the typmod (varchar(n),
				 * domains, arrays, enums, ...); jsonb is JSON text parsed by
				 * jsonb_in: a binary jsonb from the guest is never stored
				 */
				char	   *s = guest_copy(mi, v->val, v->len, 0, f->where);

				(void) pg_verifymbstr(s, (int) v->len, false);
				return InputFunctionCall(&f->in_func, s, f->ioparam, f->typmod);
			}
		case PLZIG_KIND_DATE:
		case PLZIG_KIND_TIME:
		case PLZIG_KIND_TIMETZ:
		case PLZIG_KIND_TIMESTAMP:
		case PLZIG_KIND_TIMESTAMPTZ:
		case PLZIG_KIND_OID:
			return apply_typmod(f, plzig_scalar_from_guest(plzig_kind_type(f->kind), v->val,
														   v->len, f->where));
		case PLZIG_KIND_INTERVAL:
		case PLZIG_KIND_UUID:
			{
				char	   *b;

				plzig_fixed16_check_len(plzig_kind_type(f->kind), v->len, f->where);
				b = guest_copy(mi, v->val, PLZIG_FIXED16, 0, f->where);
				return apply_typmod(f, plzig_fixed16_from_guest(plzig_kind_type(f->kind), b,
																PLZIG_FIXED16, f->where));
			}
		case PLZIG_KIND_NUMERIC:
			{
				char	   *b;

				plzig_numeric_check_len(v->len, f->where);
				b = guest_copy(mi, v->val, v->len, 0, f->where);
				return apply_typmod(f, plzig_numeric_from_wire(b, v->len, f->where));
			}
		default:
			elog(ERROR, "PL/Zig: unexpected field kind %u", f->kind);
	}
	return (Datum) 0;			/* keep compiler quiet */

out_of_range:
	ereport(ERROR,
			(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
			 errmsg("PL/Zig: value of %s of %s is out of range for type %s",
					f->where, what, format_type_be(f->typid))));
	return (Datum) 0;			/* keep compiler quiet */
}

/*
 * values/nulls (rd->natts entries) of a row the guest passed as n values at
 * guest address ptr: n must be the number of live attributes; dropped
 * attributes are NULL.  The values are copied out of guest memory first;
 * no native pointer is kept while input functions (which may run any SQL
 * function, a domain's CHECK constraint for example) are called.
 */
void
plzig_row_values_from_guest(void *mi, PlzigRowDesc *rd, uint64 ptr, uint32 n, Datum *values,
							bool *nulls, const char *what)
{
	PlzigValue *copy;
	int			i;
	int			j = 0;

	if (n != (uint32) rd->nlive)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("PL/Zig: %s has %u field(s), but its row type has %d", what, n, rd->nlive)));
	/* n <= MaxTupleAttributeNumber: no overflow */
	copy = palloc0(sizeof(PlzigValue) * (n > 0 ? n : 1));
	if (n > 0)
	{
		if (ptr > PG_UINT32_MAX)
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("PL/Zig: invalid pointer to %s", what)));
		memcpy(copy, plzig_guest_ptr(mi, (uint32) ptr, n * (uint32) sizeof(PlzigValue)),
			   sizeof(PlzigValue) * n);
	}
	for (i = 0; i < rd->natts; i++)
	{
		if (rd->fields[i].dropped)
		{
			values[i] = (Datum) 0;
			nulls[i] = true;
			continue;
		}
		values[i] = plzig_field_from_guest(mi, &rd->fields[i], &copy[j++], what, &nulls[i]);
	}
	pfree(copy);
}

/*
 * A row result from the result slot: NULL, or val = the guest address of
 * len values (doc/abi.md, "Rows").  The tuple is built with the row type's
 * descriptor, after checking that the type has not changed since the
 * function was loaded (it can change during the call: ALTER TYPE through
 * SPI).
 */
Datum
plzig_row_result(void *mi, PlzigRowDesc *rd, const PlzigSlot *slot, bool *isnull)
{
	Datum	   *values;
	bool	   *nulls;
	HeapTuple	tup;

	*isnull = false;
	if (slot->is_null)
	{
		*isnull = true;
		return (Datum) 0;
	}
	if (!plzig_rowdesc_current(rd))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("PL/Zig: the row type %s changed during the call", format_type_be(rd->typid))));
	values = palloc(sizeof(Datum) * (rd->natts > 0 ? rd->natts : 1));
	nulls = palloc(sizeof(bool) * (rd->natts > 0 ? rd->natts : 1));
	plzig_row_values_from_guest(mi, rd, slot->val, slot->len, values, nulls, "the result");
	tup = heap_form_tuple(rd->tupdesc, values, nulls);
	return HeapTupleGetDatum(tup);
}

/* ---------------------------------------------------------------------
 * Set-returning functions (materialize mode, doc/abi.md "Sets")
 * ---------------------------------------------------------------------
 */
struct PlzigSrf
{
	ReturnSetInfo *rsinfo;
	PlzigRowDesc *rd;			/* the rows: a row type, or one column */
	Tuplestorestate *tupstore;	/* in the caller's per-query context */
	ResourceOwner owner;		/* of the call: owns the tuplestore's temp files */
};

/*
 * Start a set-returning call: the caller must accept a materialized set
 * (as PL/pgSQL requires); the tuplestore is created in the per-query
 * context with the call's resource owner and work_mem, like PL/pgSQL's.
 * Nothing is kept beyond what the executor gets back: an instance never
 * stays suspended between calls (no value-per-call mode).
 */
PlzigSrf *
plzig_srf_begin(ReturnSetInfo *rsinfo, PlzigRowDesc *rd, MemoryContext cxt)
{
	PlzigSrf   *srf;
	MemoryContext old;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0 || rsinfo->expectedDesc == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	srf = MemoryContextAllocZero(cxt, sizeof(PlzigSrf));
	srf->rsinfo = rsinfo;
	srf->rd = rd;
	srf->owner = CurrentResourceOwner;
	old = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	srf->tupstore = tuplestore_begin_heap((rsinfo->allowedModes & SFRM_Materialize_Random) != 0,
										  false, work_mem);
	MemoryContextSwitchTo(old);
	return srf;
}

/*
 * One row pushed by the guest (srf_return_next): n values at guest address
 * ptr, converted and checked like a row result, appended to the tuplestore
 * (which spills to a temporary file beyond work_mem).  The caller's current
 * memory context is a scratch context reset for every row.
 */
void
plzig_srf_push(PlzigSrf *srf, void *mi, uint64 ptr, uint32 n)
{
	PlzigRowDesc *rd = srf->rd;
	Datum	   *values = palloc(sizeof(Datum) * (rd->natts > 0 ? rd->natts : 1));
	bool	   *nulls = palloc(sizeof(bool) * (rd->natts > 0 ? rd->natts : 1));
	ResourceOwner save = CurrentResourceOwner;

	plzig_row_values_from_guest(mi, rd, ptr, n, values, nulls, "a returned row");
	/* a temporary file, if one is started now, belongs to the call */
	CurrentResourceOwner = srf->owner;
	PG_TRY();
	{
		tuplestore_putvalues(srf->tupstore, rd->tupdesc, values, nulls);
	}
	PG_FINALLY();
	{
		CurrentResourceOwner = save;
	}
	PG_END_TRY();
}

/*
 * The guest returned: hand the tuplestore and a copy of the row descriptor
 * (in the per-query context, as the executor expects; it checks the
 * descriptor against the one it expects) to the caller.  A row type
 * changed during the call is refused, as for a row result.
 */
void
plzig_srf_finish(PlzigSrf *srf)
{
	MemoryContext old;

	if (!plzig_rowdesc_current(srf->rd))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("PL/Zig: the row type %s changed during the call",
						format_type_be(srf->rd->typid))));
	srf->rsinfo->returnMode = SFRM_Materialize;
	srf->rsinfo->setResult = srf->tupstore;
	old = MemoryContextSwitchTo(srf->rsinfo->econtext->ecxt_per_query_memory);
	srf->rsinfo->setDesc = CreateTupleDescCopy(srf->rd->tupdesc);
	MemoryContextSwitchTo(old);
}
