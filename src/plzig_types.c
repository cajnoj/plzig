/*-------------------------------------------------------------------------
 *
 * plzig_types.c
 *	  SQL type -> PL/Zig marshalling class.
 *
 * The actual copying into and out of guest memory lives in plzig_runtime.c
 * (it needs the runtime's pointer validation); this file only classifies
 * types and prepares their I/O functions.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "catalog/pg_type.h"
#include "utils/lsyscache.h"

PlzigTypeKind
plzig_type_kind(Oid typid)
{
	switch (typid)
	{
		case VOIDOID:
			return PLZIG_T_VOID;
		case BOOLOID:
			return PLZIG_T_BOOL;
		case INT2OID:
			return PLZIG_T_INT2;
		case INT4OID:
			return PLZIG_T_INT4;
		case INT8OID:
			return PLZIG_T_INT8;
		case FLOAT4OID:
			return PLZIG_T_FLOAT4;
		case FLOAT8OID:
			return PLZIG_T_FLOAT8;
		case TEXTOID:
			return PLZIG_T_TEXT;
		case VARCHAROID:
		case BPCHAROID:
			return PLZIG_T_TEXTIO;
		case BYTEAOID:
			return PLZIG_T_BYTEA;
		default:
			return PLZIG_T_IO;
	}
}

const char *
plzig_zig_type_name(PlzigTypeKind kind)
{
	switch (kind)
	{
		case PLZIG_T_VOID:
			return "void";
		case PLZIG_T_BOOL:
			return "bool";
		case PLZIG_T_INT2:
			return "i16";
		case PLZIG_T_INT4:
			return "i32";
		case PLZIG_T_INT8:
			return "i64";
		case PLZIG_T_FLOAT4:
			return "f32";
		case PLZIG_T_FLOAT8:
			return "f64";
		case PLZIG_T_TEXT:
		case PLZIG_T_TEXTIO:
		case PLZIG_T_BYTEA:
		case PLZIG_T_IO:
			return "[]const u8";
	}
	return NULL;				/* keep compiler quiet */
}

/*
 * Fill in *ti for type typid.  For arguments we need the output function of
 * text-I/O types, for results the input function.
 */
void
plzig_type_info_init(PlzigTypeInfo *ti, Oid typid, bool for_result,
					 MemoryContext mcxt)
{
	memset(ti, 0, sizeof(*ti));
	ti->typid = typid;
	ti->kind = plzig_type_kind(typid);

	if (for_result && (ti->kind == PLZIG_T_IO || ti->kind == PLZIG_T_TEXTIO))
	{
		Oid			infunc;

		getTypeInputInfo(typid, &infunc, &ti->ioparam);
		fmgr_info_cxt(infunc, &ti->in_func, mcxt);
	}
	else if (!for_result && ti->kind == PLZIG_T_IO)
	{
		Oid			outfunc;
		bool		isvarlena;

		getTypeOutputInfo(typid, &outfunc, &isvarlena);
		fmgr_info_cxt(outfunc, &ti->out_func, mcxt);
	}
}

/*
 * Kind of a result column of type typid, as reported to the guest
 * (PLZIG_KIND_*).  Exact type OIDs only, like plzig_type_kind: a domain over
 * integer is reported as PLZIG_KIND_OTHER (text representation).
 */
uint16
plzig_value_kind(Oid typid)
{
	switch (plzig_type_kind(typid))
	{
		case PLZIG_T_BOOL:
			return PLZIG_KIND_BOOL;
		case PLZIG_T_INT2:
			return PLZIG_KIND_INT2;
		case PLZIG_T_INT4:
			return PLZIG_KIND_INT4;
		case PLZIG_T_INT8:
			return PLZIG_KIND_INT8;
		case PLZIG_T_FLOAT4:
			return PLZIG_KIND_FLOAT4;
		case PLZIG_T_FLOAT8:
			return PLZIG_KIND_FLOAT8;
		case PLZIG_T_TEXT:
		case PLZIG_T_TEXTIO:
			return PLZIG_KIND_TEXT;
		case PLZIG_T_BYTEA:
			return PLZIG_KIND_BYTEA;
		case PLZIG_T_VOID:
		case PLZIG_T_IO:
			break;
	}
	return PLZIG_KIND_OTHER;
}

/*
 * The parameter type a guest may declare for a prepared statement: only
 * these kinds, mapped to fixed OIDs (the guest never supplies an OID).
 * InvalidOid for anything else.
 */
Oid
plzig_param_kind_oid(uint32 kind)
{
	switch (kind)
	{
		case PLZIG_KIND_BOOL:
			return BOOLOID;
		case PLZIG_KIND_INT2:
			return INT2OID;
		case PLZIG_KIND_INT4:
			return INT4OID;
		case PLZIG_KIND_INT8:
			return INT8OID;
		case PLZIG_KIND_FLOAT4:
			return FLOAT4OID;
		case PLZIG_KIND_FLOAT8:
			return FLOAT8OID;
		case PLZIG_KIND_TEXT:
			return TEXTOID;
		case PLZIG_KIND_BYTEA:
			return BYTEAOID;
		default:
			return InvalidOid;
	}
}

/* Inverse of plzig_param_kind_oid; PLZIG_KIND_NULL for any other OID. */
uint16
plzig_param_oid_kind(Oid typid)
{
	switch (typid)
	{
		case BOOLOID:
			return PLZIG_KIND_BOOL;
		case INT2OID:
			return PLZIG_KIND_INT2;
		case INT4OID:
			return PLZIG_KIND_INT4;
		case INT8OID:
			return PLZIG_KIND_INT8;
		case FLOAT4OID:
			return PLZIG_KIND_FLOAT4;
		case FLOAT8OID:
			return PLZIG_KIND_FLOAT8;
		case TEXTOID:
			return PLZIG_KIND_TEXT;
		case BYTEAOID:
			return PLZIG_KIND_BYTEA;
		default:
			return PLZIG_KIND_NULL;
	}
}

#ifdef PLZIG_TESTING
/* LCOV_EXCL_START (test helpers are not part of the coverage figures) */
/* Unit-test helpers (-DPLZIG_TESTING only; see test/sql/testing.sql). */
#include "utils/builtins.h"

PG_FUNCTION_INFO_V1(plzig_test_type_map);
PG_FUNCTION_INFO_V1(plzig_test_param_kind_oid);

/* plzig_test_type_map(t regtype) RETURNS text: "<zig type> <value kind> <param kind>" */
Datum
plzig_test_type_map(PG_FUNCTION_ARGS)
{
	Oid			t = PG_GETARG_OID(0);

	PG_RETURN_TEXT_P(cstring_to_text(psprintf("%s %u %u",
											  plzig_zig_type_name(plzig_type_kind(t)),
											  (unsigned) plzig_value_kind(t),
											  (unsigned) plzig_param_oid_kind(t))));
}

/* plzig_test_param_kind_oid(kind int) RETURNS regtype (0 = none) */
Datum
plzig_test_param_kind_oid(PG_FUNCTION_ARGS)
{
	PG_RETURN_OID(plzig_param_kind_oid((uint32) PG_GETARG_INT32(0)));
}
/* LCOV_EXCL_STOP */
#endif							/* PLZIG_TESTING */
