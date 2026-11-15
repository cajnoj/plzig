/*-------------------------------------------------------------------------
 *
 * plzig_source.c
 *	  pg_proc -> checked signature -> generated user.zig.
 *
 * The user's text is appended verbatim to a generated file of its own; it
 * is never interpolated into a build script, a command line or a path.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/htup_details.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "utils/typcache.h"

bool
plzig_valid_identifier(const char *s)
{
	const char *p;

	if (s == NULL || *s == '\0')
		return false;
	if (!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '_'))
		return false;
	for (p = s + 1; *p; p++)
	{
		if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
			  (*p >= '0' && *p <= '9') || *p == '_'))
			return false;
	}
	/*
	 * Keep generated names (argN) and our own declarations unambiguous: the
	 * generated file declares plzig, std and the function call itself, and
	 * Zig refuses a parameter that shadows any of them.
	 */
	if (strcmp(s, "plzig") == 0 || strcmp(s, "std") == 0 || strcmp(s, "call") == 0)
		return false;
	return (p - s) <= NAMEDATALEN;
}

/*
 * Every live attribute of a row type that becomes a generated struct must
 * have a name that can be emitted as a struct field (plzig_field_name_ok).
 */
static void
plzig_check_row_fields(TupleDesc td, const char *what)
{
	int			i;
	int			j;

	for (i = 0; i < td->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(td, i);

		if (att->attisdropped)
			continue;
		if (!plzig_field_name_ok(NameStr(att->attname)))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig cannot map the field \"%s\" of %s to a struct field",
							NameStr(att->attname), what),
					 errhint("Field names of composite arguments and results must match [A-Za-z_][A-Za-z0-9_]*.")));
		/*
		 * unique (always so in a composite type; output parameters can
		 * clash with the names PostgreSQL makes up for unnamed ones)
		 */
		for (j = 0; j < i; j++)
			if (!TupleDescAttr(td, j)->attisdropped &&
				strcmp(NameStr(TupleDescAttr(td, j)->attname), NameStr(att->attname)) == 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 errmsg("duplicate PL/Zig field name \"%s\" in %s",
								NameStr(att->attname), what)));
	}
}

/* plzig_check_row_fields for the named composite type typid (an argument type) */
static void
plzig_check_row_type(Oid typid)
{
	TupleDesc	td = lookup_rowtype_tupdesc(typid, -1);

	PG_TRY();
	{
		plzig_check_row_fields(td, format_type_be(typid));
	}
	PG_FINALLY();
	{
		ReleaseTupleDesc(td);
	}
	PG_END_TRY();
}

/* The type of an argument or result must be a real type (no pseudo or shell type). */
static void
plzig_check_type(Oid typid, bool result)
{
	char		typtype = get_typtype(typid);

	if (typtype == TYPTYPE_PSEUDO || typtype == '\0')
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 result ? errmsg("PL/Zig functions cannot return type %s", format_type_be(typid)) :
				 errmsg("PL/Zig functions cannot accept type %s", format_type_be(typid))));
	if (!get_typisdefined(typid))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 result ? errmsg("PL/Zig functions cannot return shell type %s", format_type_be(typid)) :
				 errmsg("PL/Zig functions cannot accept type %s", format_type_be(typid))));
}

/*
 * Check that a function's signature is supported and fill *sig.
 * Raises feature_not_supported for everything still cut (PLAN.md D10 and
 * §12 item 14).
 */
void
plzig_check_signature(HeapTuple proctup, PlzigSignature *sig)
{
	Form_pg_proc proc = (Form_pg_proc) GETSTRUCT(proctup);
	Oid		   *argtypes;
	char	  **argnames;
	char	   *argmodes;
	int			nall;
	int			nout = 0;
	int			i;

	memset(sig, 0, sizeof(*sig));

	if (proc->prokind != PROKIND_FUNCTION && proc->prokind != PROKIND_PROCEDURE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig does not support aggregate or window functions")));

	/* set-returning functions: materialize mode (doc/abi.md, "Sets") */
	if (proc->proretset && proc->prorettype == VOIDOID)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig functions cannot return SETOF void")));
	sig->retset = proc->proretset;

	nall = get_func_arg_info(proctup, &argtypes, &argnames, &argmodes);
	if (nall > FUNC_MAX_ARGS)
		elog(ERROR, "too many arguments");
	for (i = 0; i < nall; i++)
		if (argmodes && (argmodes[i] == PROARGMODE_OUT || argmodes[i] == PROARGMODE_INOUT ||
						 argmodes[i] == PROARGMODE_TABLE))
			nout++;

	/*
	 * Trigger functions (doc/abi.md, "Triggers"): no declared arguments, the
	 * trigger's data comes through plzig.Trigger.  Event triggers stay
	 * refused (their result type is a pseudo-type, checked below).
	 */
	if (proc->prorettype == TRIGGEROID)
	{
		if (proc->prokind != PROKIND_FUNCTION || proc->proretset)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("a PL/Zig trigger function must be a function returning trigger")));
		if (nall > 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("trigger functions cannot have declared arguments"),
					 errhint("The arguments of the trigger can be accessed through plzig.Trigger.arg().")));
		sig->is_trigger = true;
	}

	/* the declared result type first (RECORD is checked with the outputs below) */
	if (proc->prorettype != VOIDOID && !sig->is_trigger &&
		!(nout > 0 && proc->prorettype == RECORDOID))
		plzig_check_type(proc->prorettype, true);

	sig->argtypes = palloc0(sizeof(Oid) * (nall > 0 ? nall : 1));
	sig->argnames = palloc0(sizeof(char *) * (nall > 0 ? nall : 1));

	for (i = 0; i < nall; i++)
	{
		char		mode = argmodes ? argmodes[i] : PROARGMODE_IN;
		int			n;

		if (mode == PROARGMODE_VARIADIC)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig does not support VARIADIC parameters")));

		if (mode == PROARGMODE_OUT || mode == PROARGMODE_INOUT || mode == PROARGMODE_TABLE)
			plzig_check_type(argtypes[i], true);
		if (mode == PROARGMODE_OUT || mode == PROARGMODE_TABLE)
			continue;			/* a field of the result, checked with the row type */

		/* an input argument (IN, INOUT) */
		plzig_check_type(argtypes[i], false);
		n = sig->nargs++;
		sig->argtypes[n] = argtypes[i];

		if (argnames && argnames[i] && argnames[i][0] != '\0')
		{
			if (!plzig_valid_identifier(argnames[i]))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 errmsg("invalid PL/Zig parameter name \"%s\"", argnames[i]),
						 errhint("Parameter names must match [A-Za-z_][A-Za-z0-9_]* and must not be \"plzig\", \"std\" or \"call\".")));
			sig->argnames[n] = pstrdup(argnames[i]);
		}
		else
			sig->argnames[n] = psprintf("arg%d", n + 1);

		if (plzig_type_is_row(argtypes[i]))
			plzig_check_row_type(argtypes[i]);
	}

	/* reject duplicates (possible between explicit names and argN) */
	for (i = 0; i < sig->nargs; i++)
	{
		int			j;

		for (j = i + 1; j < sig->nargs; j++)
			if (strcmp(sig->argnames[i], sig->argnames[j]) == 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 errmsg("duplicate PL/Zig parameter name \"%s\"", sig->argnames[i])));
	}

	/*
	 * The result: void, a scalar, or a row.  A row is either a named
	 * composite type or, with output parameters, RECORD described by them
	 * (a function with exactly one output parameter returns that
	 * parameter's type; a procedure with any returns RECORD).
	 */
	if (nout > 0 && proc->prorettype == RECORDOID)
	{
		sig->rettupdesc = build_function_result_tupdesc_t(proctup);
		if (sig->rettupdesc == NULL)	/* cannot happen */
			elog(ERROR, "could not build the result row type of function %u", proc->oid);
		plzig_check_row_fields(sig->rettupdesc, "the output parameters");
	}
	else if (proc->prorettype != VOIDOID && !sig->is_trigger)
	{
		if (plzig_type_is_row(proc->prorettype))
		{
			sig->rettupdesc = lookup_rowtype_tupdesc_copy(proc->prorettype, -1);
			plzig_check_row_fields(sig->rettupdesc, format_type_be(proc->prorettype));
		}
	}

	/*
	 * The generated file declares the row type (and the element type of a
	 * set) as Result, and a set-returning function's returnNext.
	 */
	for (i = 0; i < sig->nargs; i++)
	{
		if ((sig->rettupdesc || sig->retset) && strcmp(sig->argnames[i], "Result") == 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("invalid PL/Zig parameter name \"%s\"", sig->argnames[i]),
					 errdetail("In a function returning a row or a set, the generated code declares the result type as Result.")));
		if (sig->retset && strcmp(sig->argnames[i], "returnNext") == 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("invalid PL/Zig parameter name \"%s\"", sig->argnames[i]),
					 errdetail("In a set-returning function, the generated code declares returnNext.")));
	}

	sig->rettype = proc->prorettype;
	sig->strict = proc->proisstrict;
	sig->is_procedure = (proc->prokind == PROKIND_PROCEDURE);
	sig->volatility = proc->provolatile;
}

char *
plzig_get_body(HeapTuple proctup)
{
	Datum		d;
	bool		isnull;
	char	   *body;

	d = SysCacheGetAttr(PROCOID, proctup, Anum_pg_proc_prosrc, &isnull);
	if (isnull)
		elog(ERROR, "null prosrc");
	body = TextDatumGetCString(d);

	if (strlen(body) > (Size) plzig_max_source_size * 1024)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig function body is too long"),
				 errdetail("The body is %zu bytes; plzig.max_source_size is %d kB.",
						   strlen(body), plzig_max_source_size)));
	return body;
}

/*
 * The generated file. The header is a single line so that compiler line N
 * is body line N-1.
 */
#define PLZIG_SRC_PRELUDE "const plzig = @import(\"plzig\"); const std = plzig.std; "

/* Does a row type have a jsonb field (whose Zig type differs between argument and result)? */
static bool
plzig_row_has_jsonb(TupleDesc td)
{
	int			i;

	for (i = 0; i < td->natts; i++)
		if (!TupleDescAttr(td, i)->attisdropped &&
			plzig_value_kind(TupleDescAttr(td, i)->atttypid) == PLZIG_KIND_JSONB)
			return true;
	return false;
}

/*
 * const <name> = struct { @"field": ?T, ... };  one optional field per live
 * attribute, in order (the order the host passes and expects the values
 * in); names were checked by plzig_check_row_fields.
 */
static void
plzig_emit_struct(StringInfo buf, const char *name, TupleDesc td, bool for_result)
{
	int			i;
	bool		first = true;

	appendStringInfo(buf, "const %s = struct {", name);
	for (i = 0; i < td->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(td, i);

		if (att->attisdropped)
			continue;
		Assert(plzig_field_name_ok(NameStr(att->attname)));
		appendStringInfo(buf, "%s @\"%s\": ?%s", first ? "" : ",", NameStr(att->attname),
						 plzig_field_zig_type(plzig_value_kind(att->atttypid), for_result));
		first = false;
	}
	appendStringInfoString(buf, " }; ");
}

/*
 * The struct types of the composite argument types, in order of first use:
 * @"plzig.Row1", @"plzig.Row2", ...  (names no parameter can have).  Returns
 * the index (1-based) of typid, emitting its declaration first if needed.
 */
static int
plzig_row_type_index(StringInfo buf, Oid *seen, int *nseen, Oid typid)
{
	TupleDesc	td;
	char		name[32];
	int			i;

	for (i = 0; i < *nseen; i++)
		if (seen[i] == typid)
			return i + 1;
	seen[*nseen] = typid;
	(*nseen)++;
	snprintf(name, sizeof(name), "@\"plzig.Row%d\"", *nseen);
	td = lookup_rowtype_tupdesc(typid, -1);
	plzig_emit_struct(buf, name, td, false);
	ReleaseTupleDesc(td);
	return *nseen;
}

char *
plzig_generate_source(const PlzigSignature *sig, const char *body,
					  char *const *use_aliases, int nuses, size_t *srclen)
{
	StringInfoData buf;
	int			i;
	Oid		   *seen = palloc(sizeof(Oid) * (sig->nargs + 1));
	int			nseen = 0;
	int		   *rowidx = palloc0(sizeof(int) * (sig->nargs + 1));

	initStringInfo(&buf);
	appendStringInfoString(&buf, PLZIG_SRC_PRELUDE);

	/*
	 * The functions this one uses (//#use directives, plzig_use.c): each is
	 * a module of its own, imported under a name only the host gives it;
	 * the alias is its `call`.  Aliases were validated as identifiers.
	 */
	for (i = 0; i < nuses; i++)
	{
		Assert(plzig_valid_identifier(use_aliases[i]));
		appendStringInfo(&buf, "const @\"%s\" = @import(\"" PLZIG_USE_IMPORT_PREFIX "%s\").call; ",
						 use_aliases[i], use_aliases[i]);
	}

	/*
	 * Declarations of the row types, all on the header line (so that
	 * compiler line N is still body line N-1).
	 */
	for (i = 0; i < sig->nargs; i++)
		if (plzig_type_is_row(sig->argtypes[i]))
			rowidx[i] = plzig_row_type_index(&buf, seen, &nseen, sig->argtypes[i]);
	if (sig->rettupdesc)
	{
		if (sig->rettype != RECORDOID && plzig_type_is_row(sig->rettype) &&
			!plzig_row_has_jsonb(sig->rettupdesc))
		{
			/* the same struct as an argument of this type: `return p;` works */
			int			idx = plzig_row_type_index(&buf, seen, &nseen, sig->rettype);

			appendStringInfo(&buf, "const Result = @\"plzig.Row%d\"; ", idx);
		}
		else
			plzig_emit_struct(&buf, "Result", sig->rettupdesc, true);
	}
	else if (sig->retset)
		appendStringInfo(&buf, "const Result = %s; ",
						 plzig_zig_type_name(plzig_type_kind(sig->rettype), true));
	/* a set: rows are pushed (doc/abi.md, "Sets"); NULL is a row of NULLs */
	if (sig->retset)
		appendStringInfoString(&buf, "fn returnNext(row: ?Result) void { plzig.returnNext(Result, row); } ");

	/* a trigger: the trigger's data in, what to do with the row out */
	if (sig->is_trigger)
	{
		appendStringInfoString(&buf, "pub fn call(tg: plzig.Trigger) anyerror!plzig.TriggerResult { _ = &tg;\n");
		appendStringInfoString(&buf, body);
		appendStringInfoString(&buf, "\n}\n");
		*srclen = buf.len;
		return buf.data;
	}

	appendStringInfoString(&buf, "pub fn call(");
	for (i = 0; i < sig->nargs; i++)
	{
		appendStringInfo(&buf, "%s@\"%s\": %s",
						 i > 0 ? ", " : "",
						 sig->argnames[i],
						 sig->strict ? "" : "?");
		if (rowidx[i] > 0)
			appendStringInfo(&buf, "@\"plzig.Row%d\"", rowidx[i]);
		else
			appendStringInfoString(&buf, plzig_zig_type_name(plzig_type_kind(sig->argtypes[i]), false));
	}
	if (sig->retset)
		appendStringInfoString(&buf, ") anyerror!void {");
	else if (sig->rettupdesc)
		/* a procedure must return its output row (PostgreSQL refuses NULL) */
		appendStringInfoString(&buf, sig->is_procedure ? ") anyerror!Result {" : ") anyerror!?Result {");
	else if (sig->rettype == VOIDOID)
		appendStringInfoString(&buf, ") anyerror!void {");
	else
		appendStringInfo(&buf, ") anyerror!?%s {",
						 plzig_zig_type_name(plzig_type_kind(sig->rettype), true));
	/* parameters may legitimately go unused */
	for (i = 0; i < sig->nargs; i++)
		appendStringInfo(&buf, " _ = &@\"%s\";", sig->argnames[i]);
	appendStringInfoChar(&buf, '\n');
	appendStringInfoString(&buf, body);
	appendStringInfoString(&buf, "\n}\n");

	*srclen = buf.len;
	return buf.data;
}

char *
plzig_generate_inline_source(const char *body, size_t *srclen)
{
	StringInfoData buf;

	if (strlen(body) > (Size) plzig_max_source_size * 1024)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig code block is too long")));

	initStringInfo(&buf);
	appendStringInfoString(&buf, PLZIG_SRC_PRELUDE "pub fn call() anyerror!void {\n");
	appendStringInfoString(&buf, body);
	appendStringInfoString(&buf, "\n}\n");
	*srclen = buf.len;
	return buf.data;
}

#ifdef PLZIG_TESTING
/* LCOV_EXCL_START (test helpers are not part of the coverage figures) */
/* ---------------------------------------------------------------------
 * Unit-test helpers, compiled only with -DPLZIG_TESTING (`make
 * PLZIG_TESTING=1`; never in a release build).  Declared and used by
 * test/sql/testing.sql only.
 * ---------------------------------------------------------------------
 */
#include "catalog/pg_type_d.h"
#include "utils/array.h"

PG_FUNCTION_INFO_V1(plzig_test_valid_identifier);
PG_FUNCTION_INFO_V1(plzig_test_generate_source);
PG_FUNCTION_INFO_V1(plzig_test_generate_inline_source);

/* plzig_test_valid_identifier(name text) RETURNS bool */
Datum
plzig_test_valid_identifier(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(plzig_valid_identifier(text_to_cstring(PG_GETARG_TEXT_PP(0))));
}

/*
 * plzig_test_generate_source(argtypes regtype[], argnames text[],
 *                            rettype regtype, strict bool, body text) RETURNS text
 * The generated user.zig for a signature given directly (no catalog entry).
 * argnames may contain NULLs (unnamed: argN, as plzig_check_signature does).
 */
Datum
plzig_test_generate_source(PG_FUNCTION_ARGS)
{
	ArrayType  *types = PG_GETARG_ARRAYTYPE_P(0);
	ArrayType  *names = PG_GETARG_ARRAYTYPE_P(1);
	PlzigSignature sig;
	Datum	   *tvals;
	bool	   *tnulls;
	Datum	   *nvals;
	bool	   *nnulls;
	int			nt;
	int			nn;
	int			i;
	size_t		len;
	char	   *src;

	deconstruct_array(types, REGTYPEOID, sizeof(Oid), true, TYPALIGN_INT,
					  &tvals, &tnulls, &nt);
	deconstruct_array(names, TEXTOID, -1, false, TYPALIGN_INT,
					  &nvals, &nnulls, &nn);
	if (nt != nn)
		elog(ERROR, "argtypes and argnames differ in length");
	memset(&sig, 0, sizeof(sig));
	sig.nargs = nt;
	sig.argtypes = palloc0(sizeof(Oid) * (nt + 1));
	sig.argnames = palloc0(sizeof(char *) * (nt + 1));
	for (i = 0; i < nt; i++)
	{
		sig.argtypes[i] = DatumGetObjectId(tvals[i]);
		sig.argnames[i] = nnulls[i] ? psprintf("arg%d", i + 1) :
			TextDatumGetCString(nvals[i]);
	}
	sig.rettype = PG_GETARG_OID(2);
	if (plzig_type_is_row(sig.rettype))
		sig.rettupdesc = lookup_rowtype_tupdesc_copy(sig.rettype, -1);
	sig.strict = PG_GETARG_BOOL(3);
	src = plzig_generate_source(&sig, text_to_cstring(PG_GETARG_TEXT_PP(4)), NULL, 0, &len);
	if (len != strlen(src))
		elog(ERROR, "reported length %zu differs from the text length %zu", len, strlen(src));
	PG_RETURN_TEXT_P(cstring_to_text_with_len(src, (int) len));
}

/* plzig_test_generate_inline_source(body text) RETURNS text */
Datum
plzig_test_generate_inline_source(PG_FUNCTION_ARGS)
{
	size_t		len;
	char	   *src = plzig_generate_inline_source(text_to_cstring(PG_GETARG_TEXT_PP(0)), &len);

	PG_RETURN_TEXT_P(cstring_to_text_with_len(src, (int) len));
}
/* LCOV_EXCL_STOP */
#endif							/* PLZIG_TESTING */
