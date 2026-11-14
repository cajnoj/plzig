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

static bool
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
	/* keep generated names (argN) and our own declarations unambiguous */
	if (strcmp(s, "plzig") == 0 || strcmp(s, "std") == 0)
		return false;
	return (p - s) <= NAMEDATALEN;
}

/*
 * Check that a function's signature is supported and fill *sig.
 * Raises feature_not_supported for everything cut in PLAN.md D10.
 */
void
plzig_check_signature(HeapTuple proctup, PlzigSignature *sig)
{
	Form_pg_proc proc = (Form_pg_proc) GETSTRUCT(proctup);
	Oid		   *argtypes;
	char	  **argnames;
	char	   *argmodes;
	int			nargs;
	int			i;

	memset(sig, 0, sizeof(*sig));

	if (proc->prokind != PROKIND_FUNCTION && proc->prokind != PROKIND_PROCEDURE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig does not support aggregate or window functions")));

	if (proc->proretset)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig functions cannot return sets")));

	/* result type */
	if (proc->prorettype != VOIDOID)
	{
		char		typtype = get_typtype(proc->prorettype);

		if (typtype == TYPTYPE_PSEUDO || typtype == '\0')
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig functions cannot return type %s",
							format_type_be(proc->prorettype))));
		if (!get_typisdefined(proc->prorettype))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig functions cannot return shell type %s",
							format_type_be(proc->prorettype))));
	}

	nargs = get_func_arg_info(proctup, &argtypes, &argnames, &argmodes);
	if (nargs > FUNC_MAX_ARGS)
		elog(ERROR, "too many arguments");

	sig->nargs = nargs;
	sig->argtypes = palloc0(sizeof(Oid) * (nargs > 0 ? nargs : 1));
	sig->argnames = palloc0(sizeof(char *) * (nargs > 0 ? nargs : 1));

	for (i = 0; i < nargs; i++)
	{
		char		typtype;

		if (argmodes && argmodes[i] != PROARGMODE_IN)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig supports only IN parameters"),
					 errdetail("OUT, INOUT, VARIADIC and TABLE parameters are not supported.")));

		typtype = get_typtype(argtypes[i]);
		if (typtype == TYPTYPE_PSEUDO || typtype == '\0' ||
			!get_typisdefined(argtypes[i]))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/Zig functions cannot accept type %s",
							format_type_be(argtypes[i]))));

		sig->argtypes[i] = argtypes[i];

		if (argnames && argnames[i] && argnames[i][0] != '\0')
		{
			if (!plzig_valid_identifier(argnames[i]))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 errmsg("invalid PL/Zig parameter name \"%s\"", argnames[i]),
						 errhint("Parameter names must match [A-Za-z_][A-Za-z0-9_]* and must not be \"plzig\" or \"std\".")));
			sig->argnames[i] = pstrdup(argnames[i]);
		}
		else
			sig->argnames[i] = psprintf("arg%d", i + 1);
	}

	/* reject duplicates (possible between explicit names and argN) */
	for (i = 0; i < nargs; i++)
	{
		int			j;

		for (j = i + 1; j < nargs; j++)
			if (strcmp(sig->argnames[i], sig->argnames[j]) == 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 errmsg("duplicate PL/Zig parameter name \"%s\"", sig->argnames[i])));
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

char *
plzig_generate_source(const PlzigSignature *sig, const char *body, size_t *srclen)
{
	StringInfoData buf;
	int			i;

	initStringInfo(&buf);
	appendStringInfoString(&buf, PLZIG_SRC_PRELUDE "pub fn call(");
	for (i = 0; i < sig->nargs; i++)
	{
		PlzigTypeKind k = plzig_type_kind(sig->argtypes[i]);

		appendStringInfo(&buf, "%s@\"%s\": %s%s",
						 i > 0 ? ", " : "",
						 sig->argnames[i],
						 sig->strict ? "" : "?",
						 plzig_zig_type_name(k));
	}
	if (sig->rettype == VOIDOID)
		appendStringInfoString(&buf, ") anyerror!void {");
	else
		appendStringInfo(&buf, ") anyerror!?%s {",
						 plzig_zig_type_name(plzig_type_kind(sig->rettype)));
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
