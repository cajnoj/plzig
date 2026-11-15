/*-------------------------------------------------------------------------
 *
 * plzig_use.c
 *	  One PL/Zig function compiled into another: //#use directives.
 *
 * A function declares, in directive lines at the top of its body, the
 * PL/Zig functions it uses:
 *
 *	   //#use schema.function(argument types) as alias
 *
 * Each used function is compiled into the user's module as a Zig module of
 * its own, from exactly the source it is compiled from when standalone, and
 * the alias names that module: alias.call(...) is a plain Zig function call,
 * no SPI, and alias.name reaches what the function declares pub.  The lines stay
 * in the source as Zig comments (a line starting with // is always a comment
 * in Zig: there are no block comments and no string literal spans lines
 * except \\ lines), so compiler line numbers do not move, and this file needs
 * no Zig lexer.
 *
 * Compiled-in code skips everything a SQL-level call enforces, hence the
 * restrictions (plzig_check_usable, doc/security.md): same owner, EXECUTE
 * held by that owner, no SECURITY DEFINER, no SET clauses, scalar types
 * without domain constraints.  References are resolved as the owner, with a
 * fixed search_path, never the session's; at every compilation again.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/objectaddress.h"
#include "catalog/pg_depend.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/lmgr.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/resowner.h"
#include "utils/syscache.h"

/* one //#use directive as written */
typedef struct PlzigUseDecl
{
	char	   *text;			/* the whole directive, for messages */
	char	   *target;			/* "schema.function(types)" */
	char	   *alias;
	int			line;			/* line of the body, 1-based */
} PlzigUseDecl;

#define PLZIG_USE_SYNTAX "//#use schema.function(argument types) as name"

static bool
plzig_is_space(char c)
{
	/* Zig's whitespace (anything else is not valid in Zig source) */
	return c == ' ' || c == '\t' || c == '\r';
}

/* a macro, not a function: ereport(ERROR) is visibly noreturn to analysers */
#define plzig_directive_malformed(line, text, why) \
	ereport(ERROR, \
			(errcode(ERRCODE_SYNTAX_ERROR), \
			 errmsg("malformed PL/Zig directive on line %d: %s", (line), (why)), \
			 errdetail("The directive is: %s", (text)), \
			 errhint("The form is: " PLZIG_USE_SYNTAX)))

/* Parse one directive line (q[0..n), starting with "//#"). */
static PlzigUseDecl *
plzig_parse_directive(const char *q, size_t n, int line)
{
	PlzigUseDecl *d = palloc0(sizeof(PlzigUseDecl));
	char	   *text = pnstrdup(q, n);
	char	   *p = text + 3;
	char	   *kw = p;
	char	   *rest;
	char	   *rparen;
	char	   *t;
	char	   *alias;

	d->text = text;
	d->line = line;
	while ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))
		p++;
	if (p - kw != 3 || strncmp(kw, "use", 3) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("unknown PL/Zig directive on line %d", line),
				 errdetail("The directive is: %s", text),
				 errhint("The only directive is: " PLZIG_USE_SYNTAX)));
	if (!plzig_is_space(*p))
		plzig_directive_malformed(line, text, "expected a space after //#use");
	while (plzig_is_space(*p))
		p++;
	rest = p;

	/*
	 * The target ends at the last ')' (a quoted name may contain anything,
	 * but nothing after the argument list may): what follows must be
	 * exactly " as <name>".  The target itself is parsed by PostgreSQL's
	 * regprocedure input function (plzig_resolve_use).
	 */
	rparen = strrchr(rest, ')');
	if (rparen == NULL)
		plzig_directive_malformed(line, text, "expected an argument list in parentheses");
	d->target = pnstrdup(rest, rparen - rest + 1);
	t = rparen + 1;
	if (!plzig_is_space(*t))
		plzig_directive_malformed(line, text, "expected \"as\" after the argument list");
	while (plzig_is_space(*t))
		t++;
	if (strncmp(t, "as", 2) != 0 || !plzig_is_space(t[2]))
		plzig_directive_malformed(line, text, "expected \"as\" after the argument list");
	t += 2;
	while (plzig_is_space(*t))
		t++;
	alias = t;
	while (*t && !plzig_is_space(*t))
		t++;
	d->alias = pnstrdup(alias, t - alias);
	while (plzig_is_space(*t))
		t++;
	if (*t != '\0')
		plzig_directive_malformed(line, text, "unexpected text after the alias");
	if (d->alias[0] == '\0')
		plzig_directive_malformed(line, text, "expected a name after \"as\"");
	return d;
}

/*
 * The //#use directives of a body.  Directive lines are lines whose first
 * non-blank characters are //#; they must come before the first line of
 * code (only blank lines and comments may precede them).  A directive after
 * code is an error, not a comment, so that a misplaced one is never
 * silently ignored.
 */
static List *
plzig_parse_directives(const char *body)
{
	List	   *decls = NIL;
	const char *p = body;
	int			line = 0;
	bool		header = true;

	for (;;)
	{
		const char *eol = strchr(p, '\n');
		const char *end = eol ? eol : p + strlen(p);
		const char *q = p;
		size_t		len;

		line++;
		while (q < end && plzig_is_space(*q))
			q++;
		len = end - q;
		while (len > 0 && plzig_is_space(q[len - 1]))
			len--;
		if (len >= 3 && strncmp(q, "//#", 3) == 0)
		{
			if (!header)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("PL/Zig directive on line %d after the first line of code", line),
						 errhint("Directives must come before the code; only blank lines and comments may precede them.")));
			decls = lappend(decls, plzig_parse_directive(q, len, line));
		}
		else if (len > 0 && !(len >= 2 && strncmp(q, "//", 2) == 0))
			header = false;
		if (eol == NULL)
			break;
		p = eol + 1;
	}
	return decls;
}

/* ---------------------------------------------------------------------
 * Resolution and checks
 * ---------------------------------------------------------------------
 */

/* error context: which directive of which function */
typedef struct PlzigUseErrCtx
{
	const PlzigUseDecl *decl;
	const char *in;				/* the function containing it */
} PlzigUseErrCtx;

static void
plzig_use_error_context(void *arg)
{
	PlzigUseErrCtx *c = (PlzigUseErrCtx *) arg;

	errcontext("PL/Zig directive on line %d of %s: %s", c->decl->line, c->in, c->decl->text);
}

/*
 * The function a directive names, resolved as `owner` with search_path set
 * to pg_catalog (then pg_temp, which PostgreSQL would otherwise search
 * first): never the session's search_path or identity, so the result does
 * not depend on who compiles the function.  The function name must be
 * schema-qualified; unqualified type names can only be built-in types (and
 * temporary types, refused afterwards).  Errors are PostgreSQL's own
 * (undefined function or type, schema permission).
 */
static Oid
plzig_resolve_use(const PlzigUseDecl *d, Oid owner)
{
	const char *paren;
	bool		inq = false;
	char	   *namepart;
	List	   *names;
	Oid			save_userid;
	int			save_sec;
	int			nest;
	Oid			oid;

	for (paren = d->target; *paren; paren++)
	{
		if (*paren == '"')
			inq = !inq;
		else if (*paren == '(' && !inq)
			break;
	}
	if (*paren == '\0')
		plzig_directive_malformed(d->line, d->text, "expected an argument list in parentheses");
	namepart = pnstrdup(d->target, paren - d->target);
#if PG_VERSION_NUM >= 160000
	names = stringToQualifiedNameList(namepart, NULL);
#else
	names = stringToQualifiedNameList(namepart);
#endif
	if (list_length(names) < 2)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_NAME),
				 errmsg("the function in a PL/Zig //#use directive must be schema-qualified"),
				 errhint("Write schema.function(argument types); the search_path is never used.")));

	GetUserIdAndSecContext(&save_userid, &save_sec);
	SetUserIdAndSecContext(owner, save_sec | SECURITY_LOCAL_USERID_CHANGE);
	nest = NewGUCNestLevel();
	(void) set_config_option("search_path", "pg_catalog, pg_temp",
							 PGC_USERSET, PGC_S_SESSION, GUC_ACTION_SAVE,
							 true, 0, false);
	oid = DatumGetObjectId(DirectFunctionCall1(regprocedurein,
											   CStringGetDatum(d->target)));
	AtEOXact_GUC(true, nest);
	SetUserIdAndSecContext(save_userid, save_sec);
	return oid;
}

static bool
plzig_type_is_temp(Oid typid)
{
	HeapTuple	tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));
	bool		temp = false;

	if (HeapTupleIsValid(tup))
	{
		temp = isAnyTempNamespace(((Form_pg_type) GETSTRUCT(tup))->typnamespace);
		ReleaseSysCache(tup);
	}
	return temp;
}

/* A type of a used function: scalar, no domain (its constraints would be skipped). */
static void
plzig_check_use_type(Oid typid, const char *name, bool result)
{
	if (plzig_type_is_row(typid))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it has a composite %s",
						name, result ? "result" : "parameter"),
				 errdetail("Only functions with scalar parameters and results can be used.")));
	if (get_typtype(typid) == TYPTYPE_DOMAIN)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: its %s type %s is a domain",
						name, result ? "result" : "parameter", format_type_be(typid)),
				 errdetail("A compiled-in call passes Zig values directly, so the domain's constraints would not be checked.")));
	if (plzig_type_is_temp(typid))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: its %s type %s is temporary",
						name, result ? "result" : "parameter", format_type_be(typid))));
}

/*
 * May the function in btup be compiled into a function of `owner` written in
 * language `langoid`?  On success *bsig is its signature.  Everything a SQL
 * call would enforce and a compiled-in call cannot is refused here.
 */
static void
plzig_check_usable(HeapTuple btup, Oid owner, Oid langoid, PlzigSignature *bsig)
{
	Form_pg_proc b = (Form_pg_proc) GETSTRUCT(btup);
	char	   *name = format_procedure_qualified(b->oid);
	AclResult	acl;
	bool		isnull;
	int			i;

	if (b->prolang != langoid)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("%s is not a PL/Zig function", name),
				 errdetail("Only PL/Zig functions can be compiled in with //#use; call other functions through plzig.spi.")));
	if (b->prokind != PROKIND_FUNCTION)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 b->prokind == PROKIND_PROCEDURE ?
				 errmsg("cannot use %s: it is a procedure", name) :
				 errmsg("cannot use %s: it is an aggregate or window function", name)));
	if (isAnyTempNamespace(b->pronamespace))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it is a temporary function", name)));
	if (b->proowner != owner)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("cannot use %s: it has a different owner", name),
				 errdetail("A PL/Zig function can only use functions of its own owner (%s); %s is owned by %s.",
						   GetUserNameFromId(owner, true) ? GetUserNameFromId(owner, true) : "?",
						   name,
						   GetUserNameFromId(b->proowner, true) ? GetUserNameFromId(b->proowner, true) : "?")));
#if PG_VERSION_NUM >= 160000
	acl = object_aclcheck(ProcedureRelationId, b->oid, owner, ACL_EXECUTE);
#else
	acl = pg_proc_aclcheck(b->oid, owner, ACL_EXECUTE);
#endif
	if (acl != ACLCHECK_OK)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied for function %s", name),
				 errdetail("The owner of the using function needs EXECUTE on every function it uses.")));
	if (b->prosecdef)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it is SECURITY DEFINER", name),
				 errdetail("SECURITY DEFINER takes effect only when a function is called through SQL; compiled in, its code would run with the privileges of the using function.")));
	(void) SysCacheGetAttr(PROCOID, btup, Anum_pg_proc_proconfig, &isnull);
	if (!isnull)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it has SET clauses", name),
				 errdetail("SET clauses take effect only when a function is called through SQL.")));
	if (b->proretset)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it is a set-returning function", name)));
	if (b->prorettype == TRIGGEROID)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot use %s: it is a trigger function", name)));
	{
		Oid		   *argtypes;
		char	  **argnames;
		char	   *argmodes;
		int			nall = get_func_arg_info(btup, &argtypes, &argnames, &argmodes);

		for (i = 0; argmodes && i < nall; i++)
			if (argmodes[i] == PROARGMODE_OUT || argmodes[i] == PROARGMODE_INOUT ||
				argmodes[i] == PROARGMODE_TABLE)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot use %s: it has output parameters", name),
						 errdetail("Only functions with scalar parameters and results can be used.")));
	}

	/* the checks of the function itself (it passed them when created) */
	plzig_check_signature(btup, bsig);
	for (i = 0; i < bsig->nargs; i++)
		plzig_check_use_type(bsig->argtypes[i], name, false);
	if (bsig->rettype != VOIDOID)
		plzig_check_use_type(bsig->rettype, name, true);
}

/*
 * The aliases of one unit's directives: identifiers that collide with no
 * name the generated file declares or the function's parameters.
 */
static void
plzig_check_aliases(List *decls, const PlzigSignature *sig)
{
	ListCell   *lc;
	ListCell   *lc2;
	int			i;

	foreach(lc, decls)
	{
		PlzigUseDecl *d = (PlzigUseDecl *) lfirst(lc);

		if (!plzig_valid_identifier(d->alias))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_NAME),
					 errmsg("invalid PL/Zig alias \"%s\" on line %d", d->alias, d->line),
					 errhint("An alias must match [A-Za-z_][A-Za-z0-9_]* and must not be \"plzig\", \"std\" or \"call\".")));
		for (i = 0; i < sig->nargs; i++)
			if (strcmp(sig->argnames[i], d->alias) == 0)
				ereport(ERROR,
						(errcode(ERRCODE_DUPLICATE_ALIAS),
						 errmsg("PL/Zig alias \"%s\" on line %d is also the name of a parameter",
								d->alias, d->line)));
		if (((sig->rettupdesc || sig->retset) && strcmp(d->alias, "Result") == 0) ||
			(sig->retset && strcmp(d->alias, "returnNext") == 0) ||
			(sig->is_trigger && strcmp(d->alias, "tg") == 0))
			ereport(ERROR,
					(errcode(ERRCODE_DUPLICATE_ALIAS),
					 errmsg("PL/Zig alias \"%s\" on line %d is a name the generated code declares",
							d->alias, d->line)));
		foreach(lc2, decls)
		{
			PlzigUseDecl *e = (PlzigUseDecl *) lfirst(lc2);

			if (e == d)
				break;
			if (strcmp(e->alias, d->alias) == 0)
				ereport(ERROR,
						(errcode(ERRCODE_DUPLICATE_ALIAS),
						 errmsg("PL/Zig alias \"%s\" is used twice (lines %d and %d)",
								d->alias, e->line, d->line)));
		}
	}
}

/* ---------------------------------------------------------------------
 * Building the set of units
 * ---------------------------------------------------------------------
 */
typedef struct PlzigBuildCtx
{
	Oid			owner;
	Oid			langoid;
	bool		lock_uses;		/* lock the direct uses (validator) */
	int			nunits;
	PlzigUnit	units[PLZIG_MAX_USES + 1];
	int			depth;			/* edges from unit 0 to the unit being expanded */
	int			path[PLZIG_MAX_USE_DEPTH + 1];	/* unit indexes on that path */
} PlzigBuildCtx;

static const char *
plzig_unit_name(PlzigBuildCtx *bc, int u)
{
	if (bc->units[u].display)
		return bc->units[u].display;
	return format_procedure_qualified(bc->units[u].fn_oid);
}

/* Parse unit u's directives, generate its source, add its uses (depth first). */
static void
plzig_unit_expand(PlzigBuildCtx *bc, int u, const PlzigSignature *sig, const char *body)
{
	List	   *decls = plzig_parse_directives(body);
	int			n = list_length(decls);
	PlzigUnit  *unit = &bc->units[u];
	ListCell   *lc;
	int			i = 0;

	plzig_check_aliases(decls, sig);
	unit->nuses = n;
	unit->use_alias = palloc0(sizeof(char *) * (n + 1));
	unit->use_unit = palloc0(sizeof(int) * (n + 1));
	foreach(lc, decls)
		unit->use_alias[i++] = ((PlzigUseDecl *) lfirst(lc))->alias;
	unit->src = plzig_generate_source(sig, body, unit->use_alias, n, &unit->srclen);

	i = 0;
	foreach(lc, decls)
	{
		PlzigUseDecl *d = (PlzigUseDecl *) lfirst(lc);
		PlzigUseErrCtx ectx;
		ErrorContextCallback errcb;
		Oid			oid;
		int			j;
		int			found = -1;

		ectx.decl = d;
		ectx.in = plzig_unit_name(bc, u);
		errcb.callback = plzig_use_error_context;
		errcb.arg = &ectx;
		errcb.previous = error_context_stack;
		error_context_stack = &errcb;

		oid = plzig_resolve_use(d, bc->owner);
		/* the validator records a dependency: DROP must wait (and recheck) */
		if (bc->lock_uses && u == 0)
			LockDatabaseObject(ProcedureRelationId, oid, 0, AccessShareLock);

		for (j = 0; j <= bc->depth; j++)
			if (bc->units[bc->path[j]].fn_oid == oid)
			{
				StringInfoData chain;
				int			k;

				initStringInfo(&chain);
				for (k = j; k <= bc->depth; k++)
					appendStringInfo(&chain, "%s uses ", plzig_unit_name(bc, bc->path[k]));
				appendStringInfoString(&chain, plzig_unit_name(bc, bc->path[j]));
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
						 j == bc->depth ?
						 errmsg("a PL/Zig function cannot use itself") :
						 errmsg("PL/Zig functions cannot use each other in a cycle"),
						 errdetail("%s.", chain.data),
						 errhint("A function can call itself directly; it needs no //#use for that.")));
			}
		for (j = 0; j < i; j++)
			if (bc->units[unit->use_unit[j]].fn_oid == oid)
				ereport(ERROR,
						(errcode(ERRCODE_DUPLICATE_FUNCTION),
						 errmsg("%s is used twice by %s", plzig_unit_name(bc, unit->use_unit[j]),
								plzig_unit_name(bc, u))));
		for (j = 1; j < bc->nunits; j++)
			if (bc->units[j].fn_oid == oid)
				found = j;

		if (found < 0)
		{
			HeapTuple	btup;
			PlzigSignature bsig;
			char	   *bbody;
			PlzigUnit  *nu;

			if (bc->depth + 1 > PLZIG_MAX_USE_DEPTH)
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("PL/Zig functions use each other more than %d levels deep",
								PLZIG_MAX_USE_DEPTH)));
			if (bc->nunits > PLZIG_MAX_USES)
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("a PL/Zig function can use at most %d functions, directly and indirectly",
								PLZIG_MAX_USES)));
			btup = SearchSysCache1(PROCOID, ObjectIdGetDatum(oid));
			if (!HeapTupleIsValid(btup))	/* dropped concurrently */
				ereport(ERROR,
						(errcode(ERRCODE_UNDEFINED_FUNCTION),
						 errmsg("function %s does not exist", d->target)));
			plzig_check_usable(btup, bc->owner, bc->langoid, &bsig);
			bbody = plzig_get_body(btup);
			found = bc->nunits++;
			nu = &bc->units[found];
			memset(nu, 0, sizeof(*nu));
			nu->fn_oid = oid;
			nu->fn_xmin = HeapTupleHeaderGetRawXmin(btup->t_data);
			nu->fn_tid = btup->t_self;
			nu->display = format_procedure_qualified(oid);
			ReleaseSysCache(btup);

			unit->use_unit[i] = found;
			bc->path[++bc->depth] = found;
			plzig_unit_expand(bc, found, &bsig, bbody);
			bc->depth--;
		}
		else
			unit->use_unit[i] = found;

		error_context_stack = errcb.previous;
		i++;
	}
}

/*
 * The units of a function: itself and every function it uses, directly or
 * indirectly, each with its generated source.  All checks (directives,
 * resolution, usability, aliases, cycles, limits) run here, against the
 * catalog as it is now: on every compilation, not only at CREATE.
 * lock_uses: lock the directly used functions against DROP (the validator,
 * which records dependencies on them).
 */
PlzigProgram *
plzig_program_build(HeapTuple proctup, const PlzigSignature *sig, const char *body,
					bool lock_uses)
{
	Form_pg_proc proc = (Form_pg_proc) GETSTRUCT(proctup);
	PlzigBuildCtx *bc = palloc0(sizeof(PlzigBuildCtx));
	PlzigProgram *prog;

	bc->owner = proc->proowner;
	bc->langoid = proc->prolang;
	bc->lock_uses = lock_uses;
	bc->nunits = 1;
	bc->units[0].fn_oid = proc->oid;
	bc->units[0].fn_xmin = HeapTupleHeaderGetRawXmin(proctup->t_data);
	bc->units[0].fn_tid = proctup->t_self;
	bc->depth = 0;
	bc->path[0] = 0;
	plzig_unit_expand(bc, 0, sig, body);

	prog = palloc0(sizeof(PlzigProgram));
	prog->nunits = bc->nunits;
	prog->units = palloc(sizeof(PlzigUnit) * bc->nunits);
	memcpy(prog->units, bc->units, sizeof(PlzigUnit) * bc->nunits);
	pfree(bc);
	return prog;
}

/* A program of one generated source (a DO block). */
PlzigProgram *
plzig_program_single(char *src, size_t srclen)
{
	PlzigProgram *prog = palloc0(sizeof(PlzigProgram));

	prog->nunits = 1;
	prog->units = palloc0(sizeof(PlzigUnit));
	prog->units[0].src = src;
	prog->units[0].srclen = srclen;
	return prog;
}

/*
 * DO blocks cannot use functions: a block has no owner but the current
 * user, no dependencies and no cache entry, so the rules above would need
 * a variant of their own; not worth it for one-off code.  Directives are
 * still parsed, so a malformed one is reported as such.
 */
void
plzig_inline_check_directives(const char *body)
{
	if (plzig_parse_directives(body) != NIL)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("//#use is not supported in DO blocks"),
				 errhint("Create a function that uses the other functions instead.")));
}

/* ---------------------------------------------------------------------
 * Dependencies (pg_depend): a normal dependency of the function on every
 * function it uses directly, so that DROP needs CASCADE and pg_dump
 * restores the used function first.  Correctness never relies on them
 * (they are missing for functions created with check_function_bodies = off
 * before the used function existed): every compilation resolves and checks
 * again, and a loaded module is invalidated when a used function changes.
 * ---------------------------------------------------------------------
 */
static bool
plzig_dependency_exists(Oid fn_oid, Oid used)
{
	Relation	rel;
	ScanKeyData key[2];
	SysScanDesc scan;
	HeapTuple	tup;
	bool		found = false;

	rel = table_open(DependRelationId, AccessShareLock);
	ScanKeyInit(&key[0], Anum_pg_depend_classid, BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(ProcedureRelationId));
	ScanKeyInit(&key[1], Anum_pg_depend_objid, BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(fn_oid));
	scan = systable_beginscan(rel, DependDependerIndexId, true, NULL, 2, key);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_depend dep = (Form_pg_depend) GETSTRUCT(tup);

		if (dep->objsubid == 0 && dep->refclassid == ProcedureRelationId &&
			dep->refobjid == used && dep->refobjsubid == 0 &&
			dep->deptype == DEPENDENCY_NORMAL)
		{
			found = true;
			break;
		}
	}
	systable_endscan(scan);
	table_close(rel, AccessShareLock);
	return found;
}

static void
plzig_record_dependency(Oid fn_oid, Oid used)
{
	ObjectAddress myself;
	ObjectAddress referenced;

	if (used == fn_oid || plzig_dependency_exists(fn_oid, used))
		return;
	ObjectAddressSet(myself, ProcedureRelationId, fn_oid);
	ObjectAddressSet(referenced, ProcedureRelationId, used);
	recordDependencyOn(&myself, &referenced, DEPENDENCY_NORMAL);
}

/* After a successful compilation in the validator: the direct uses. */
void
plzig_record_use_dependencies(Oid fn_oid, const PlzigProgram *prog)
{
	int			i;

	for (i = 0; i < prog->units[0].nuses; i++)
		plzig_record_dependency(fn_oid, prog->units[prog->units[0].use_unit[i]].fn_oid);
}

/*
 * Run fn(arg) in an internal subtransaction; false if it raised an error
 * (discarded).  Errors of class 57 (cancel, timeout, shutdown) are re-thrown.
 */
static bool
plzig_try_subxact(void (*fn) (void *), void *arg)
{
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;
	volatile bool ok = true;

	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(oldcxt);
	PG_TRY();
	{
		fn(arg);
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(oldcxt);
		edata = CopyErrorData();
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
		if (ERRCODE_TO_CATEGORY(edata->sqlerrcode) == ERRCODE_TO_CATEGORY(ERRCODE_QUERY_CANCELED))
			ReThrowError(edata);
		FreeErrorData(edata);
		ok = false;
	}
	PG_END_TRY();
	return ok;
}

typedef struct PlzigLenientArg
{
	HeapTuple	proctup;
	List	   *decls;			/* parse result */
	PlzigUseDecl *decl;			/* the directive to resolve */
} PlzigLenientArg;

static void
plzig_lenient_parse(void *arg)
{
	PlzigLenientArg *a = (PlzigLenientArg *) arg;

	a->decls = plzig_parse_directives(plzig_get_body(a->proctup));
}

static void
plzig_lenient_record(void *arg)
{
	PlzigLenientArg *a = (PlzigLenientArg *) arg;
	Form_pg_proc proc = (Form_pg_proc) GETSTRUCT(a->proctup);
	Oid			used = plzig_resolve_use(a->decl, proc->proowner);

	LockDatabaseObject(ProcedureRelationId, used, 0, AccessShareLock);
	if (SearchSysCacheExists1(PROCOID, ObjectIdGetDatum(used)))
		plzig_record_dependency(proc->oid, used);
}

/*
 * The validator with check_function_bodies = off (pg_restore, pg_upgrade):
 * the body is not checked, but the dependencies are recorded for every
 * directive whose function exists, so that a dump of the restored database
 * orders them correctly again.  Nothing is refused here: whatever does not
 * parse or resolve is skipped, and the usability checks (which would fail
 * during a restore, where every function is created by the restoring user
 * and given to its owner afterwards) run at the first compilation.
 */
void
plzig_record_uses_lenient(HeapTuple proctup)
{
	PlzigLenientArg a;
	ListCell   *lc;

	memset(&a, 0, sizeof(a));
	a.proctup = proctup;
	if (!plzig_try_subxact(plzig_lenient_parse, &a))
		return;
	foreach(lc, a.decls)
	{
		a.decl = (PlzigUseDecl *) lfirst(lc);
		(void) plzig_try_subxact(plzig_lenient_record, &a);
	}
}
