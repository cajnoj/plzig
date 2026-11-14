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
