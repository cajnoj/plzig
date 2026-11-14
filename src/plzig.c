/*-------------------------------------------------------------------------
 *
 * plzig.c
 *	  PL/Zig: module init, GUCs, call/inline/validator handlers, and the
 *	  per-backend function cache.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "commands/event_trigger.h"
#include "commands/trigger.h"
#include "funcapi.h"
#include "lib/ilist.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/syscache.h"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(.name = "plzig", .version = PLZIG_VERSION_STR);
#else
PG_MODULE_MAGIC;
#endif

/* GUCs */
char	   *plzig_zig_path = NULL;
char	   *plzig_zig_lib_dir = NULL;
char	   *plzig_zig_sha256 = NULL;
char	   *plzig_compiler_sandbox = NULL;
int			plzig_compile_timeout = 300000;
int			plzig_compile_memory_limit = 4096;
int			plzig_max_source_size = 1024;
int			plzig_max_memory = 64;
int			plzig_instance_cache_size = 64;

/* ---------------------------------------------------------------------
 * Function cache
 * ---------------------------------------------------------------------
 */
typedef struct PlzigFunction
{
	Oid			fn_oid;			/* hash key, must be first */
	TransactionId fn_xmin;
	ItemPointerData fn_tid;
	MemoryContext cxt;
	PlzigModule *module;
	PlzigInstance *instance;	/* idle cached instance, or NULL */
	int			use_count;		/* active calls */
	bool		dead;			/* removed from the hash, free when idle */
	bool		in_lru;
	dlist_node	lru_node;
	int			nargs;
	PlzigTypeInfo *argtypes;
	PlzigTypeInfo rettype;
	bool		read_only;
	char	   *signature;		/* for error context */
} PlzigFunction;

typedef struct PlzigHashEnt
{
	Oid			fn_oid;
	PlzigFunction *fn;
} PlzigHashEnt;

static HTAB *plzig_fn_hash = NULL;
static bool plzig_fn_sweep_needed = false;
static MemoryContext plzig_fn_cxt = NULL;
static dlist_head plzig_lru = DLIST_STATIC_INIT(plzig_lru);
static int	plzig_lru_count = 0;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(plzig_call_handler);
PG_FUNCTION_INFO_V1(plzig_inline_handler);
PG_FUNCTION_INFO_V1(plzig_validator);
PG_FUNCTION_INFO_V1(plzig_sandbox_status);

void
_PG_init(void)
{
	/*
	 * The toolchain settings are config-file only (PGC_SIGHUP, not ALTER
	 * SYSTEM) and hidden from non-superusers.  They have no check hooks on
	 * purpose: a bad value must make compiles fail, not leave the previous
	 * value silently in force.  plzig_build.c validates them before use.
	 */
	DefineCustomStringVariable("plzig.zig_path",
							   "Absolute path of the Zig compiler binary (no default; PATH is never searched).",
							   NULL,
							   &plzig_zig_path,
							   "",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY | GUC_DISALLOW_IN_AUTO_FILE,
							   NULL, NULL, NULL);
	DefineCustomStringVariable("plzig.zig_lib_dir",
							   "Absolute path of the Zig lib directory (empty = detect next to the compiler).",
							   NULL,
							   &plzig_zig_lib_dir,
							   "",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY | GUC_DISALLOW_IN_AUTO_FILE,
							   NULL, NULL, NULL);
	DefineCustomStringVariable("plzig.zig_sha256",
							   "Expected SHA-256 of the Zig compiler binary (empty = not checked).",
							   NULL,
							   &plzig_zig_sha256,
							   "",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY | GUC_DISALLOW_IN_AUTO_FILE,
							   NULL, NULL, NULL);
	/*
	 * A string, not an enum, for the reason given above: with an enum an
	 * unknown value (such as the former "on") would only draw a WARNING and
	 * leave the default in force.  plzig_sandbox_mode() refuses to compile
	 * with anything but require, try or off.
	 */
	DefineCustomStringVariable("plzig.compiler_sandbox",
							   "Landlock confinement of the compiler: require, try (if available), off.",
							   NULL,
							   &plzig_compiler_sandbox,
							   "require",
							   PGC_SIGHUP,
							   GUC_DISALLOW_IN_AUTO_FILE,
							   NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.compile_timeout",
							"Wall-clock limit for one compilation.",
							NULL,
							&plzig_compile_timeout,
							300000, 100, 3600 * 1000,
							PGC_SUSET,
							GUC_UNIT_MS,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.compile_memory_limit",
							"Address-space limit (RLIMIT_AS) for the compiler, 0 = no limit.",
							NULL,
							&plzig_compile_memory_limit,
							4096, 0, INT_MAX / 2,
							PGC_SUSET,
							GUC_UNIT_MB,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.max_source_size",
							"Maximum size of a PL/Zig function body.",
							NULL,
							&plzig_max_source_size,
							1024, 1, 3072,
							PGC_SUSET,
							GUC_UNIT_KB,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.max_memory",
							"Maximum linear memory of one PL/Zig function instance.",
							NULL,
							&plzig_max_memory,
							64, 1, 1023,
							PGC_SUSET,
							GUC_UNIT_MB,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.instance_cache_size",
							"Number of idle PL/Zig instances kept per backend.",
							NULL,
							&plzig_instance_cache_size,
							64, 0, 10000,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);
#if PG_VERSION_NUM >= 150000
	MarkGUCPrefixReserved("plzig");
#else
	EmitWarningsOnPlaceholders("plzig");
#endif
}

static void
plzig_lru_remove(PlzigFunction *fn)
{
	if (fn->in_lru)
	{
		dlist_delete(&fn->lru_node);
		fn->in_lru = false;
		plzig_lru_count--;
	}
}

static void
plzig_function_free(PlzigFunction *fn)
{
	plzig_lru_remove(fn);
	if (fn->instance)
		plzig_instance_destroy(fn->instance);
	fn->instance = NULL;
	if (fn->module)
		plzig_module_unload(fn->module);
	fn->module = NULL;
	MemoryContextDelete(fn->cxt);
}

/* Remove fn from the hash; free now if idle, else when the last call ends. */
static void
plzig_function_invalidate(PlzigFunction *fn)
{
	bool		found;

	hash_search(plzig_fn_hash, &fn->fn_oid, HASH_REMOVE, &found);
	fn->dead = true;
	if (fn->use_count == 0)
		plzig_function_free(fn);
	else
		plzig_lru_remove(fn);
}

/* Evict idle instances beyond plzig.instance_cache_size (LRU tail first). */
static void
plzig_lru_trim(void)
{
	while (plzig_lru_count > plzig_instance_cache_size && !dlist_is_empty(&plzig_lru))
	{
		PlzigFunction *victim = dlist_tail_element(PlzigFunction, lru_node, &plzig_lru);

		plzig_lru_remove(victim);
		if (victim->instance)
		{
			plzig_instance_destroy(victim->instance);
			victim->instance = NULL;
		}
	}
}

static PlzigFunction *
plzig_function_build(Oid fn_oid, HeapTuple proctup)
{
	PlzigFunction *volatile fn;
	MemoryContext cxt;
	MemoryContext old;

	cxt = AllocSetContextCreate(plzig_fn_cxt, "PL/Zig function", ALLOCSET_SMALL_SIZES);
	fn = MemoryContextAllocZero(cxt, sizeof(PlzigFunction));
	fn->cxt = cxt;
	fn->fn_oid = fn_oid;
	fn->fn_xmin = HeapTupleHeaderGetRawXmin(proctup->t_data);
	fn->fn_tid = proctup->t_self;

	PG_TRY();
	{
		PlzigSignature sig;
		char	   *body;
		char	   *src;
		size_t		srclen;
		char	   *wasm;
		uint32		wasm_len;
		int			i;

		plzig_check_signature(proctup, &sig);
		body = plzig_get_body(proctup);
		src = plzig_generate_source(&sig, body, &srclen);
		wasm = plzig_get_wasm(src, srclen, &wasm_len);
		fn->module = plzig_module_load(wasm, wasm_len);

		old = MemoryContextSwitchTo(cxt);
		fn->nargs = sig.nargs;
		fn->argtypes = palloc0(sizeof(PlzigTypeInfo) * (sig.nargs > 0 ? sig.nargs : 1));
		for (i = 0; i < sig.nargs; i++)
			plzig_type_info_init(&fn->argtypes[i], sig.argtypes[i], false, cxt);
		plzig_type_info_init(&fn->rettype, sig.rettype, true, cxt);
		fn->read_only = (sig.volatility != PROVOLATILE_VOLATILE);
		fn->signature = format_procedure(fn_oid);
		MemoryContextSwitchTo(old);
	}
	PG_CATCH();
	{
		if (fn->module)
			plzig_module_unload(fn->module);
		MemoryContextDelete(cxt);
		PG_RE_THROW();
	}
	PG_END_TRY();
	return fn;
}

/*
 * pg_proc changed somewhere.  Nothing can be freed from inside an
 * invalidation callback, so only note that the cache needs a sweep.
 */
static void
plzig_proc_inval_callback(Datum arg, int cacheid, uint32 hashvalue)
{
	plzig_fn_sweep_needed = true;
}

/*
 * Drop cache entries whose function was dropped or replaced.  Without this
 * an entry (and its loaded module) would stay until backend exit, because a
 * dropped function is never looked up again.  Entries with active calls are
 * left to plzig_function_lookup/plzig_function_execute.
 */
static void
plzig_function_sweep(void)
{
	HASH_SEQ_STATUS seq;
	PlzigHashEnt *ent;
	List	   *stale = NIL;
	ListCell   *lc;

	plzig_fn_sweep_needed = false;

	hash_seq_init(&seq, plzig_fn_hash);
	while ((ent = hash_seq_search(&seq)) != NULL)
	{
		PlzigFunction *fn = ent->fn;
		HeapTuple	tup;

		if (fn->use_count > 0)
			continue;
		tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn->fn_oid));
		if (!HeapTupleIsValid(tup))
			stale = lappend(stale, fn);
		else
		{
			if (fn->fn_xmin != HeapTupleHeaderGetRawXmin(tup->t_data) ||
				!ItemPointerEquals(&fn->fn_tid, &tup->t_self))
				stale = lappend(stale, fn);
			ReleaseSysCache(tup);
		}
	}
	/* remove after the scan: do not modify the table while iterating */
	foreach(lc, stale)
		plzig_function_invalidate((PlzigFunction *) lfirst(lc));
	list_free(stale);
}

static PlzigFunction *
plzig_function_lookup(Oid fn_oid)
{
	HeapTuple	proctup;
	PlzigHashEnt *ent;
	PlzigFunction *fn = NULL;
	bool		found;

	if (plzig_fn_hash == NULL)
	{
		HASHCTL		ctl;

		plzig_fn_cxt = AllocSetContextCreate(TopMemoryContext,
											 "PL/Zig function cache",
											 ALLOCSET_DEFAULT_SIZES);
		memset(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(Oid);
		ctl.entrysize = sizeof(PlzigHashEnt);
		ctl.hcxt = plzig_fn_cxt;
		plzig_fn_hash = hash_create("PL/Zig functions", 64, &ctl,
									HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
		CacheRegisterSyscacheCallback(PROCOID, plzig_proc_inval_callback, (Datum) 0);
	}
	if (plzig_fn_sweep_needed)
		plzig_function_sweep();

	proctup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(proctup))
		elog(ERROR, "cache lookup failed for function %u", fn_oid);

	ent = hash_search(plzig_fn_hash, &fn_oid, HASH_FIND, NULL);
	if (ent)
	{
		fn = ent->fn;
		if (fn->fn_xmin != HeapTupleHeaderGetRawXmin(proctup->t_data) ||
			!ItemPointerEquals(&fn->fn_tid, &proctup->t_self))
		{
			plzig_function_invalidate(fn);
			fn = NULL;
		}
	}
	if (fn == NULL)
	{
		fn = plzig_function_build(fn_oid, proctup);
		ent = hash_search(plzig_fn_hash, &fn_oid, HASH_ENTER, &found);
		ent->fn = fn;
	}
	ReleaseSysCache(proctup);
	return fn;
}

static void
plzig_error_context(void *arg)
{
	const char *what = (const char *) arg;

	errcontext("PL/Zig function %s", what);
}

static Datum
plzig_function_execute(PlzigFunction *fn, FunctionCallInfo fcinfo)
{
	PlzigInstance *volatile inst = NULL;
	Datum		result;
	bool		isnull = false;
	ErrorContextCallback errcb;

	errcb.callback = plzig_error_context;
	errcb.arg = fn->signature;
	errcb.previous = error_context_stack;
	error_context_stack = &errcb;

	fn->use_count++;
	PG_TRY();
	{
		if (fn->instance && fn->use_count == 1)
		{
			plzig_lru_remove(fn);
			if (plzig_instance_current(fn->instance))
				inst = fn->instance;
			else
				plzig_instance_destroy(fn->instance);	/* plzig.max_memory changed */
			fn->instance = NULL;
		}
		if (inst == NULL)
			inst = plzig_instance_create(fn->module);	/* recursion: temporary instance */

		result = plzig_instance_call(inst, fn->argtypes, fn->nargs, fcinfo->args,
									 &fn->rettype, fn->read_only, &isnull);
	}
	PG_CATCH();
	{
		/* an instance that trapped or errored is never reused */
		if (inst)
			plzig_instance_destroy(inst);
		fn->use_count--;
		if (fn->dead && fn->use_count == 0)
			plzig_function_free(fn);
		PG_RE_THROW();
	}
	PG_END_TRY();

	fn->use_count--;
	if (fn->dead)
	{
		plzig_instance_destroy(inst);
		if (fn->use_count == 0)
			plzig_function_free(fn);
	}
	else if (fn->instance == NULL && plzig_instance_cache_size > 0)
	{
		fn->instance = inst;
		dlist_push_head(&plzig_lru, &fn->lru_node);
		fn->in_lru = true;
		plzig_lru_count++;
		plzig_lru_trim();
	}
	else
		plzig_instance_destroy(inst);

	error_context_stack = errcb.previous;
	fcinfo->isnull = isnull;
	return result;
}

/* ---------------------------------------------------------------------
 * Handlers
 * ---------------------------------------------------------------------
 */
Datum
plzig_call_handler(PG_FUNCTION_ARGS)
{
	PlzigFunction *fn;

	if (CALLED_AS_TRIGGER(fcinfo) || CALLED_AS_EVENT_TRIGGER(fcinfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig functions cannot be used as triggers")));

	fn = plzig_function_lookup(fcinfo->flinfo->fn_oid);
	return plzig_function_execute(fn, fcinfo);
}

Datum
plzig_inline_handler(PG_FUNCTION_ARGS)
{
	InlineCodeBlock *codeblock = (InlineCodeBlock *) DatumGetPointer(PG_GETARG_DATUM(0));
	char	   *src;
	size_t		srclen;
	char	   *wasm;
	uint32		wasm_len;
	PlzigModule *volatile mod = NULL;
	PlzigInstance *volatile inst = NULL;
	PlzigTypeInfo rettype;
	bool		isnull;
	ErrorContextCallback errcb;

	src = plzig_generate_inline_source(codeblock->source_text, &srclen);
	wasm = plzig_get_wasm(src, srclen, &wasm_len);

	memset(&rettype, 0, sizeof(rettype));
	rettype.typid = VOIDOID;
	rettype.kind = PLZIG_T_VOID;

	errcb.callback = plzig_error_context;
	errcb.arg = "anonymous code block";
	errcb.previous = error_context_stack;
	error_context_stack = &errcb;

	PG_TRY();
	{
		mod = plzig_module_load(wasm, wasm_len);
		inst = plzig_instance_create(mod);
		(void) plzig_instance_call(inst, NULL, 0, NULL, &rettype, false, &isnull);
	}
	PG_FINALLY();
	{
		if (inst)
			plzig_instance_destroy(inst);
		if (mod)
			plzig_module_unload(mod);
	}
	PG_END_TRY();

	error_context_stack = errcb.previous;
	PG_RETURN_VOID();
}

Datum
plzig_validator(PG_FUNCTION_ARGS)
{
	Oid			fn_oid = PG_GETARG_OID(0);
	HeapTuple	proctup;
	PlzigSignature sig;

	if (!CheckFunctionValidatorAccess(fcinfo->flinfo->fn_oid, fn_oid))
		PG_RETURN_VOID();

	proctup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(proctup))
		elog(ERROR, "cache lookup failed for function %u", fn_oid);

	/* signature checks always run; body checks honour check_function_bodies */
	plzig_check_signature(proctup, &sig);

	if (check_function_bodies)
	{
		char	   *body = plzig_get_body(proctup);
		size_t		srclen;
		char	   *src = plzig_generate_source(&sig, body, &srclen);
		uint32		wasm_len;
		char	   *wasm = plzig_get_wasm(src, srclen, &wasm_len);
		PlzigModule *mod = plzig_module_load(wasm, wasm_len);

		plzig_module_unload(mod);
	}

	ReleaseSysCache(proctup);
	PG_RETURN_VOID();
}

/*
 * plzig_sandbox_status(): how the most recent compilation in this session
 * was confined (superuser only; for diagnostics and the test suite).
 */
Datum
plzig_sandbox_status(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(plzig_sandbox_status_string()));
}
