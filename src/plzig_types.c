/*-------------------------------------------------------------------------
 *
 * plzig_types.c
 *	  SQL type -> PL/Zig marshalling class, and the checks of fixed-width
 *	  values that come back from a guest.
 *
 * The actual copying into and out of guest memory lives in plzig_runtime.c
 * and plzig_host.c (they need the runtime's pointer validation); this file
 * classifies types, prepares their I/O functions and turns raw guest values
 * of the natively mapped fixed-width types into Datums after range-checking
 * them with PostgreSQL's own macros (doc/abi.md, "Range checks").
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "catalog/pg_type.h"
#include "datatype/timestamp.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/lsyscache.h"
#include "utils/timestamp.h"
#include "utils/uuid.h"

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
		case DATEOID:
			return PLZIG_T_DATE;
		case TIMEOID:
			return PLZIG_T_TIME;
		case TIMETZOID:
			return PLZIG_T_TIMETZ;
		case TIMESTAMPOID:
			return PLZIG_T_TIMESTAMP;
		case TIMESTAMPTZOID:
			return PLZIG_T_TIMESTAMPTZ;
		case INTERVALOID:
			return PLZIG_T_INTERVAL;
		case UUIDOID:
			return PLZIG_T_UUID;
		case OIDOID:
			return PLZIG_T_OID;
		case NUMERICOID:
			return PLZIG_T_NUMERIC;
		default:
			return PLZIG_T_IO;
	}
}

/*
 * The Zig type of a parameter (for_result = false) or of the result.  The
 * fixed-width types get distinct SDK types, so a body that mixes them up
 * does not compile.
 */
const char *
plzig_zig_type_name(PlzigTypeKind kind, bool for_result)
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
		case PLZIG_T_DATE:
			return "plzig.Date";
		case PLZIG_T_TIME:
			return "plzig.Time";
		case PLZIG_T_TIMETZ:
			return "plzig.TimeTz";
		case PLZIG_T_TIMESTAMP:
			return "plzig.Timestamp";
		case PLZIG_T_TIMESTAMPTZ:
			return "plzig.TimestampTz";
		case PLZIG_T_INTERVAL:
			return "plzig.Interval";
		case PLZIG_T_UUID:
			return "plzig.Uuid";
		case PLZIG_T_OID:
			return "plzig.Oid";
		case PLZIG_T_NUMERIC:
			return "plzig.Numeric";
		case PLZIG_T_TEXT:
		case PLZIG_T_TEXTIO:
		case PLZIG_T_BYTEA:
		case PLZIG_T_IO:
			return "[]const u8";
	}
	(void) for_result;
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
		case PLZIG_T_DATE:
			return PLZIG_KIND_DATE;
		case PLZIG_T_TIME:
			return PLZIG_KIND_TIME;
		case PLZIG_T_TIMETZ:
			return PLZIG_KIND_TIMETZ;
		case PLZIG_T_TIMESTAMP:
			return PLZIG_KIND_TIMESTAMP;
		case PLZIG_T_TIMESTAMPTZ:
			return PLZIG_KIND_TIMESTAMPTZ;
		case PLZIG_T_INTERVAL:
			return PLZIG_KIND_INTERVAL;
		case PLZIG_T_UUID:
			return PLZIG_KIND_UUID;
		case PLZIG_T_OID:
			return PLZIG_KIND_OID;
		case PLZIG_T_NUMERIC:
			return PLZIG_KIND_NUMERIC;
		case PLZIG_T_VOID:
		case PLZIG_T_IO:
			break;
	}
	return PLZIG_KIND_OTHER;
}

/*
 * Is a value of this kind passed as bytes after the values of a row (val =
 * guest address, len = byte length), rather than in val/len themselves?
 */
bool
plzig_kind_is_bytes(uint16 kind)
{
	switch (kind)
	{
		case PLZIG_KIND_TEXT:
		case PLZIG_KIND_BYTEA:
		case PLZIG_KIND_OTHER:
		case PLZIG_KIND_INTERVAL:
		case PLZIG_KIND_UUID:
		case PLZIG_KIND_NUMERIC:
			return true;
		default:
			return false;
	}
}

/* The marshalling class of a parameter/column kind (PLZIG_T_IO if none). */
PlzigTypeKind
plzig_kind_type(uint16 kind)
{
	Oid			typid = plzig_param_kind_oid(kind);

	return OidIsValid(typid) ? plzig_type_kind(typid) : PLZIG_T_IO;
}

/*
 * Range errors for values a guest returns or passes as an SPI parameter:
 * PostgreSQL's own message and SQLSTATE (those of the type's receive
 * function), plus where the value came from and its raw bits.
 */
static void
plzig_range_error(int sqlerrcode, const char *msg, const char *where, int64 raw)
{
	ereport(ERROR,
			(errcode(sqlerrcode),
			 errmsg("%s", msg),
			 errdetail("The PL/Zig function passed the raw value " INT64_FORMAT " as %s.",
					   raw, where)));
}

/*
 * Datum of a fixed-width value held in val (and len, for timetz) of a guest
 * slot or SPI parameter, after checking it exactly as the type's receive
 * function would (date_recv, time_recv, timetz_recv, timestamp_recv,
 * timestamptz_recv): infinities where PostgreSQL has them, every finite
 * value inside the range the input function accepts.  No typmod is applied:
 * function results have none in PostgreSQL (pg_proc keeps none), and
 * prepared-statement parameters are declared without one.  The guest's
 * value is never trusted: unused high bits must be the sign extension.
 */
Datum
plzig_scalar_from_guest(PlzigTypeKind k, uint64 val, uint32 len, const char *where)
{
	int64		v = (int64) val;

	switch (k)
	{
		case PLZIG_T_DATE:
			{
				DateADT		d;

				if (v < PG_INT32_MIN || v > PG_INT32_MAX)
					plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
									  "date out of range", where, v);
				d = (DateADT) v;
				if (!DATE_NOT_FINITE(d) && !IS_VALID_DATE(d))
					plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
									  "date out of range", where, v);
				return DateADTGetDatum(d);
			}
		case PLZIG_T_TIME:
			if (v < INT64CONST(0) || v > USECS_PER_DAY)
				plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
								  "time out of range", where, v);
			return TimeADTGetDatum((TimeADT) v);
		case PLZIG_T_TIMETZ:
			{
				TimeTzADT  *t;
				int32		zone = (int32) len;

				if (v < INT64CONST(0) || v > USECS_PER_DAY)
					plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
									  "time out of range", where, v);
				if (zone <= -TZDISP_LIMIT || zone >= TZDISP_LIMIT)
					plzig_range_error(ERRCODE_INVALID_TIME_ZONE_DISPLACEMENT_VALUE,
									  "time zone displacement out of range", where, zone);
				t = (TimeTzADT *) palloc(sizeof(TimeTzADT));
				t->time = (TimeADT) v;
				t->zone = zone;
				return TimeTzADTPGetDatum(t);
			}
		case PLZIG_T_TIMESTAMP:
			if (!TIMESTAMP_NOT_FINITE(v) && !IS_VALID_TIMESTAMP(v))
				plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
								  "timestamp out of range", where, v);
			return TimestampGetDatum((Timestamp) v);
		case PLZIG_T_TIMESTAMPTZ:
			if (!TIMESTAMP_NOT_FINITE(v) && !IS_VALID_TIMESTAMP(v))
				plzig_range_error(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE,
								  "timestamp out of range", where, v);
			return TimestampTzGetDatum((TimestampTz) v);
		case PLZIG_T_OID:
			if (val > PG_UINT32_MAX)
				plzig_range_error(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE,
								  "OID out of range", where, v);
			return ObjectIdGetDatum((Oid) val);
		default:
			elog(ERROR, "PL/Zig: not a fixed-width scalar type (%d)", (int) k);
	}
	return (Datum) 0;			/* keep compiler quiet */
}

/*
 * The length a guest gave for a 16-byte fixed-width value (interval, uuid):
 * checked before anything is copied.
 */
void
plzig_fixed16_check_len(PlzigTypeKind k, uint32 len, const char *where)
{
	if (len != PLZIG_FIXED16)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: invalid length %u of %s value", len,
						k == PLZIG_T_INTERVAL ? "interval" : "uuid"),
				 errdetail("The PL/Zig function passed it as %s; the length must be %d.",
						   where, PLZIG_FIXED16)));
}

/*
 * Datum of a 16-byte fixed-width value (interval, uuid) a guest passed out
 * of line: exactly PLZIG_FIXED16 bytes, already copied out of guest memory.
 * Every bit pattern is a value PostgreSQL's receive function accepts
 * (interval_recv, uuid_recv check nothing), so only the length is checked.
 */
Datum
plzig_fixed16_from_guest(PlzigTypeKind k, const char *bytes, uint32 len, const char *where)
{
	plzig_fixed16_check_len(k, len, where);
	if (k == PLZIG_T_INTERVAL)
	{
		Interval   *iv = (Interval *) palloc(sizeof(Interval));

		StaticAssertStmt(sizeof(Interval) == PLZIG_FIXED16, "Interval is 16 bytes");
		memcpy(iv, bytes, sizeof(Interval));
		return IntervalPGetDatum(iv);
	}
	else if (k == PLZIG_T_UUID)
	{
		pg_uuid_t  *u = (pg_uuid_t *) palloc(sizeof(pg_uuid_t));

		StaticAssertStmt(sizeof(pg_uuid_t) == PLZIG_FIXED16, "uuid is 16 bytes");
		memcpy(u, bytes, sizeof(pg_uuid_t));
		return UUIDPGetDatum(u);
	}
	elog(ERROR, "PL/Zig: not a 16-byte type (%d)", (int) k);
	return (Datum) 0;			/* keep compiler quiet */
}

/*
 * numeric from the binary wire format (numeric_send) a guest passed: a
 * result, an SPI parameter or an operand of numeric_op.  `bytes` is a host
 * copy of the guest's bytes.  The length must be exactly that of the digits
 * the header announces (checked here first, so that numeric_recv never runs
 * out of data: its "insufficient data left in message" would be a protocol
 * violation, SQLSTATE class 08); everything else -- the sign, the scale,
 * every digit < 10000, the weight and scale limits -- is checked by
 * numeric_recv, the server's validating input path for untrusted bytes,
 * called with typmod -1 (function results and prepared-statement parameters
 * have no typmod).
 */
void
plzig_numeric_check_len(uint32 len, const char *where)
{
	if (len < 8 || len > PLZIG_MAX_NUMERIC_WIRE)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: invalid length %u of numeric value", len),
				 errdetail("The PL/Zig function passed it as %s.", where)));
}

Datum
plzig_numeric_from_wire(const char *bytes, uint32 len, const char *where)
{
	StringInfoData buf;
	uint32		ndigits;
	Datum		d;

	plzig_numeric_check_len(len, where);	/* callers check it before copying */
	ndigits = ((uint32) (uint8) bytes[0] << 8) | (uint8) bytes[1];
	if (len != 8 + 2 * ndigits)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: invalid length %u of numeric value with %u digits", len, ndigits),
				 errdetail("The PL/Zig function passed it as %s.", where)));

	/* a read-only StringInfo over the copy (initReadOnlyStringInfo is 17+) */
	buf.data = (char *) bytes;
	buf.len = (int) len;
	buf.maxlen = (int) len;
	buf.cursor = 0;
	d = DirectFunctionCall3(numeric_recv, PointerGetDatum(&buf),
							ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));
	if (buf.cursor != buf.len)	/* cannot happen after the length check */
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: invalid numeric value"),
				 errdetail("The PL/Zig function passed it as %s.", where)));
	return d;
}

/* The wire format (numeric_send) of a numeric, as a palloc'd bytea. */
struct varlena *
plzig_numeric_to_wire(Datum num)
{
	return (struct varlena *) DatumGetPointer(DirectFunctionCall1(numeric_send, num));
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
		case PLZIG_KIND_DATE:
			return DATEOID;
		case PLZIG_KIND_TIME:
			return TIMEOID;
		case PLZIG_KIND_TIMETZ:
			return TIMETZOID;
		case PLZIG_KIND_TIMESTAMP:
			return TIMESTAMPOID;
		case PLZIG_KIND_TIMESTAMPTZ:
			return TIMESTAMPTZOID;
		case PLZIG_KIND_INTERVAL:
			return INTERVALOID;
		case PLZIG_KIND_UUID:
			return UUIDOID;
		case PLZIG_KIND_OID:
			return OIDOID;
		case PLZIG_KIND_NUMERIC:
			return NUMERICOID;
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
		case DATEOID:
			return PLZIG_KIND_DATE;
		case TIMEOID:
			return PLZIG_KIND_TIME;
		case TIMETZOID:
			return PLZIG_KIND_TIMETZ;
		case TIMESTAMPOID:
			return PLZIG_KIND_TIMESTAMP;
		case TIMESTAMPTZOID:
			return PLZIG_KIND_TIMESTAMPTZ;
		case INTERVALOID:
			return PLZIG_KIND_INTERVAL;
		case UUIDOID:
			return PLZIG_KIND_UUID;
		case OIDOID:
			return PLZIG_KIND_OID;
		case NUMERICOID:
			return PLZIG_KIND_NUMERIC;
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
											  plzig_zig_type_name(plzig_type_kind(t), false),
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
