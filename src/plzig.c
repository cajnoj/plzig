/*-------------------------------------------------------------------------
 *
 * plzig.c
 *	  PL/Zig: module init, GUCs, call/inline/validator handlers, and the
 *	  per-backend function cache.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "commands/event_trigger.h"
#include "commands/proclang.h"
#include "commands/trigger.h"
#include "funcapi.h"
#include "lib/ilist.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "storage/lmgr.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/resowner.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(.name = "plzig", .version = PLZIG_VERSION_STR);
#else
PG_MODULE_MAGIC;
#endif

/*
 * Compiled-in default of plzig.zig_path: none in a source build; a package
 * sets it to its Zig toolchain package's compiler (make
 * PLZIG_DEFAULT_ZIG_PATH=..., doc/packaging.md).  It gets the same checks
 * as a configured value before every use (plzig_build.c).
 */
#ifndef PLZIG_DEFAULT_ZIG_PATH
#define PLZIG_DEFAULT_ZIG_PATH ""
#endif

/* GUCs */
char	   *plzig_zig_path = NULL;
char	   *plzig_zig_lib_dir = NULL;
char	   *plzig_zig_sha256 = NULL;
char	   *plzig_compiler_sandbox = NULL;
int			plzig_compile_timeout = 30000;
int			plzig_compile_memory_limit = 4096;
int			plzig_max_source_size = 1024;
int			plzig_max_memory = 64;
int			plzig_instance_cache_size = 64;
int			plzig_instance_cache_max_memory = 4096;
int			plzig_max_module_size = 2048;
int			plzig_cache_size_limit = 256;
int			plzig_max_prepared_plans = 64;
int			plzig_max_open_cursors = 16;

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
	PlzigRowDesc *retrow;		/* row result (struct), the rows of a set, or NULL */
	bool		retset;			/* set-returning (materialize mode) */
	bool		is_trigger;		/* RETURNS trigger */
	bool		read_only;
	char	   *signature;		/* for error context */
	/*
	 * The functions compiled in (//#use, plzig_use.c), directly or
	 * indirectly: the pg_proc rows their sources were made from.  Any change
	 * of one of them (body, owner, ACL, SECURITY DEFINER, SET, name, drop)
	 * makes this entry stale, so that the next call compiles again and
	 * re-runs every check; so does any change of role memberships or roles
	 * (an EXECUTE privilege can come from a membership).
	 */
	int			nused;
	Oid		   *used_oid;
	TransactionId *used_xmin;
	ItemPointerData *used_tid;
	uint64		used_checked_gen;	/* plzig_proc_inval_gen when last verified */
	uint64		auth_gen;		/* plzig_auth_inval_gen when built */
} PlzigFunction;

typedef struct PlzigHashEnt
{
	Oid			fn_oid;
	PlzigFunction *fn;
} PlzigHashEnt;

static HTAB *plzig_fn_hash = NULL;
static bool plzig_fn_sweep_needed = false;
/* bumped by every pg_proc invalidation / every role or membership change */
static uint64 plzig_proc_inval_gen = 1;
static uint64 plzig_auth_inval_gen = 1;
static MemoryContext plzig_fn_cxt = NULL;
static dlist_head plzig_lru = DLIST_STATIC_INIT(plzig_lru);
static int	plzig_lru_count = 0;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(plzig_call_handler);
PG_FUNCTION_INFO_V1(plzig_inline_handler);
PG_FUNCTION_INFO_V1(plzig_validator);
PG_FUNCTION_INFO_V1(plzig_sandbox_status);
PG_FUNCTION_INFO_V1(plzig_cache_clear);
PG_FUNCTION_INFO_V1(plzig_check_all);

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
							   "Absolute path of the Zig compiler binary (PATH is never searched).",
							   NULL,
							   &plzig_zig_path,
							   PLZIG_DEFAULT_ZIG_PATH,
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
							   "Confinement of the compiler (Landlock and seccomp): require, try (what is available), off.",
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
							30000, 100, 3600 * 1000,
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
	DefineCustomIntVariable("plzig.instance_cache_max_memory",
							"Instances whose linear memory grew beyond this are not kept idle.",
							NULL,
							&plzig_instance_cache_max_memory,
							4096, 0, 1023 * 1024,
							PGC_SUSET,
							GUC_UNIT_KB,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.max_module_size",
							"Maximum size of a compiled PL/Zig module.",
							NULL,
							&plzig_max_module_size,
							2048, 16, PLZIG_MAX_WASM_SIZE / 1024,
							PGC_SUSET,
							GUC_UNIT_KB,
							NULL, NULL, NULL);
	/* config-file only, like the toolchain settings */
	DefineCustomIntVariable("plzig.cache_size_limit",
							"Total size of the PL/Zig module cache; least recently used modules are evicted.",
							NULL,
							&plzig_cache_size_limit,
							256, 64, 1024 * 1024,
							PGC_SIGHUP,
							GUC_UNIT_MB | GUC_DISALLOW_IN_AUTO_FILE,
							NULL, NULL, NULL);
	/* exceeding either cap is an error, never an eviction */
	DefineCustomIntVariable("plzig.max_prepared_plans",
							"Maximum number of live prepared statements per PL/Zig function instance.",
							NULL,
							&plzig_max_prepared_plans,
							64, 0, 10000,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);
	DefineCustomIntVariable("plzig.max_open_cursors",
							"Maximum number of simultaneously open cursors per PL/Zig function call.",
							NULL,
							&plzig_max_open_cursors,
							16, 0, 1000,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);
	/*
	 * Transaction ends invalidate the SPI results and cursors of running
	 * calls (a procedure's own commit()/rollback() closes them first; this
	 * guards against any other way a transaction could end under a call).
	 */
	RegisterXactCallback(plzig_host_xact_callback, NULL);

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
		/* cppcheck-suppress nullPointer ; container_of macro (docker/static-analysis.sh) */
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
		PlzigProgram *prog;
		char	   *wasm;
		uint32		wasm_len;
		int			i;

		plzig_check_signature(proctup, &sig);
		body = plzig_get_body(proctup);
		/*
		 * Generations before the sources are read: an invalidation that
		 * arrives while compiling makes the entry checked again.
		 */
		fn->auth_gen = plzig_auth_inval_gen;
		fn->used_checked_gen = plzig_proc_inval_gen;
		prog = plzig_program_build(proctup, &sig, body, false);
		wasm = plzig_get_wasm(prog, &wasm_len, true);
		fn->module = plzig_module_load(wasm, wasm_len);

		old = MemoryContextSwitchTo(cxt);
		fn->nused = prog->nunits - 1;
		fn->used_oid = palloc0(sizeof(Oid) * (fn->nused + 1));
		fn->used_xmin = palloc0(sizeof(TransactionId) * (fn->nused + 1));
		fn->used_tid = palloc0(sizeof(ItemPointerData) * (fn->nused + 1));
		for (i = 0; i < fn->nused; i++)
		{
			fn->used_oid[i] = prog->units[i + 1].fn_oid;
			fn->used_xmin[i] = prog->units[i + 1].fn_xmin;
			fn->used_tid[i] = prog->units[i + 1].fn_tid;
		}
		fn->nargs = sig.nargs;
		fn->argtypes = palloc0(sizeof(PlzigTypeInfo) * (sig.nargs > 0 ? sig.nargs : 1));
		for (i = 0; i < sig.nargs; i++)
		{
			if (plzig_type_is_row(sig.argtypes[i]))
			{
				fn->argtypes[i].typid = sig.argtypes[i];
				fn->argtypes[i].kind = PLZIG_T_ROW;
				fn->argtypes[i].row = plzig_rowdesc_for_type(sig.argtypes[i], false, cxt);
			}
			else
				plzig_type_info_init(&fn->argtypes[i], sig.argtypes[i], false, cxt);
		}
		if (sig.rettupdesc)
		{
			/*
			 * The descriptor the generated struct was made from: of a named
			 * composite type now (as the type cache has it), or of the
			 * output parameters.
			 */
			if (sig.rettype == RECORDOID)
				fn->retrow = plzig_rowdesc_for_tupdesc(sig.rettupdesc, cxt);
			else
				fn->retrow = plzig_rowdesc_for_type(sig.rettype, true, cxt);
			fn->rettype.typid = sig.rettype;
			fn->rettype.kind = PLZIG_T_ROW;
			fn->rettype.row = fn->retrow;
		}
		else if (sig.retset)
		{
			/* SETOF a scalar type: rows of one column (named "value") */
			TupleDesc	td = CreateTemplateTupleDesc(1);

			TupleDescInitEntry(td, (AttrNumber) 1, "value", sig.rettype, -1, 0);
			fn->retrow = plzig_rowdesc_for_tupdesc(td, cxt);
			plzig_type_info_init(&fn->rettype, sig.rettype, true, cxt);
		}
		else
			plzig_type_info_init(&fn->rettype, sig.rettype, true, cxt);
		fn->retset = sig.retset;
		fn->is_trigger = sig.is_trigger;
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
	plzig_proc_inval_gen++;
}

/* a role or a role membership changed: recheck functions with uses */
static void
plzig_auth_inval_callback(Datum arg, int cacheid, uint32 hashvalue)
{
	plzig_fn_sweep_needed = true;
	plzig_auth_inval_gen++;
}

/*
 * Are the functions compiled into fn (//#use) unchanged since it was built?
 * Their rows are looked up only after some pg_proc invalidation.
 */
static bool
plzig_function_uses_current(PlzigFunction *fn)
{
	int			i;

	if (fn->nused == 0)
		return true;
	if (fn->auth_gen != plzig_auth_inval_gen)
		return false;
	if (fn->used_checked_gen == plzig_proc_inval_gen)
		return true;
	for (i = 0; i < fn->nused; i++)
	{
		HeapTuple	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn->used_oid[i]));
		bool		same;

		if (!HeapTupleIsValid(tup))
			return false;
		same = fn->used_xmin[i] == HeapTupleHeaderGetRawXmin(tup->t_data) &&
			ItemPointerEquals(&fn->used_tid[i], &tup->t_self);
		ReleaseSysCache(tup);
		if (!same)
			return false;
	}
	fn->used_checked_gen = plzig_proc_inval_gen;
	return true;
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
				!ItemPointerEquals(&fn->fn_tid, &tup->t_self) ||
				!plzig_function_uses_current(fn))
				stale = lappend(stale, fn);
			ReleaseSysCache(tup);
		}
	}
	/* remove after the scan: do not modify the table while iterating */
	foreach(lc, stale)
		plzig_function_invalidate((PlzigFunction *) lfirst(lc));
	list_free(stale);
}

/*
 * Are the composite types of the arguments and of the result still those
 * the function was generated for (plzig_rowdesc_current)?  If not, the
 * function is rebuilt: its generated structs must match the types.
 */
static bool
plzig_function_rows_current(PlzigFunction *fn)
{
	int			i;

	for (i = 0; i < fn->nargs; i++)
		if (fn->argtypes[i].row && !plzig_rowdesc_current(fn->argtypes[i].row))
			return false;
	return fn->retrow == NULL || plzig_rowdesc_current(fn->retrow);
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
		CacheRegisterSyscacheCallback(AUTHOID, plzig_auth_inval_callback, (Datum) 0);
		CacheRegisterSyscacheCallback(AUTHMEMROLEMEM, plzig_auth_inval_callback, (Datum) 0);
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
			!ItemPointerEquals(&fn->fn_tid, &proctup->t_self) ||
			!plzig_function_rows_current(fn) ||
			!plzig_function_uses_current(fn))
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
	MemoryContext oldcxt = CurrentMemoryContext;
	PlzigCallSpec spec;

	errcb.callback = plzig_error_context;
	errcb.arg = fn->signature;
	errcb.previous = error_context_stack;
	error_context_stack = &errcb;

	/*
	 * plzig.instance_cache_size may have been lowered since instances were
	 * cached: release the excess now, not only when the next instance is
	 * cached (with 0, that never happens).
	 */
	if (plzig_lru_count > plzig_instance_cache_size)
		plzig_lru_trim();

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

		memset(&spec, 0, sizeof(spec));
		spec.argtypes = fn->argtypes;
		spec.nargs = fn->nargs;
		spec.args = fcinfo->args;
		spec.rettype = &fn->rettype;
		spec.retrow = fn->retrow;
		spec.retset = fn->retset;
		spec.rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
		/*
		 * Transaction control only where PostgreSQL allows it: a procedure
		 * called non-atomically (CALL outside a transaction block, not below
		 * a function; PostgreSQL also makes SECURITY DEFINER procedures and
		 * those with SET clauses atomic).  Everywhere else SPI is connected
		 * atomically and SPI_commit reports PostgreSQL's own error.
		 */
		spec.nonatomic = fcinfo->context && IsA(fcinfo->context, CallContext) &&
			!castNode(CallContext, fcinfo->context)->atomic;
		if (fn->is_trigger)
			spec.trigdata = (TriggerData *) fcinfo->context;
		spec.read_only = fn->read_only;
		if (fcinfo->nargs != fn->nargs && !fn->is_trigger)	/* cannot happen */
			elog(ERROR, "PL/Zig: function called with %d arguments, expected %d",
				 fcinfo->nargs, fn->nargs);
		result = plzig_instance_call(inst, &spec, &isnull);
	}
	PG_CATCH();
	{
		/*
		 * An instance that trapped or errored is never reused.  Its call
		 * contexts go with it: make sure we are not in one of them.
		 */
		MemoryContextSwitchTo(oldcxt);
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
	else if (fn->instance == NULL && plzig_instance_cache_size > 0 &&
			 plzig_instance_memory_size(inst) <=
			 (uint64) plzig_instance_cache_max_memory * 1024)
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

	if (CALLED_AS_EVENT_TRIGGER(fcinfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig functions cannot be used as event triggers")));

	fn = plzig_function_lookup(fcinfo->flinfo->fn_oid);
	/* a trigger function only as a trigger, and only it */
	if (fn->is_trigger != CALLED_AS_TRIGGER(fcinfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 fn->is_trigger ? errmsg("trigger functions can only be called as triggers") :
				 errmsg("PL/Zig function %s is not a trigger function", fn->signature)));
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
	MemoryContext oldcxt = CurrentMemoryContext;
	PlzigCallSpec spec;

	plzig_inline_check_directives(codeblock->source_text);
	src = plzig_generate_inline_source(codeblock->source_text, &srclen);
	/* DO blocks are never cached: compiled, run once, discarded */
	wasm = plzig_get_wasm(plzig_program_single(src, srclen), &wasm_len, false);

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
		memset(&spec, 0, sizeof(spec));
		spec.rettype = &rettype;
		/* DO outside a transaction block (and not below a function) */
		spec.nonatomic = !codeblock->atomic;
		(void) plzig_instance_call(inst, &spec, &isnull);
	}
	PG_FINALLY();
	{
		MemoryContextSwitchTo(oldcxt);
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
		PlzigProgram *prog = plzig_program_build(proctup, &sig, body, true);
		uint32		wasm_len;
		char	   *wasm = plzig_get_wasm(prog, &wasm_len, true);
		PlzigModule *mod = plzig_module_load(wasm, wasm_len);

		plzig_module_unload(mod);
		/* CREATE has reset the function's dependencies before calling us */
		plzig_record_use_dependencies(fn_oid, prog);
	}
	else
		plzig_record_uses_lenient(proctup);

	ReleaseSysCache(proctup);
	PG_RETURN_VOID();
}

/*
 * plzig_sandbox_status(): how the most recent compilation in this session
 * was confined, and the Zig version this build requires (superuser only;
 * for diagnostics and the test suite).
 */
Datum
plzig_sandbox_status(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(psprintf("%s; Zig %s",
											  plzig_sandbox_status_string(),
											  PLZIG_ZIG_VERSION)));
}

/*
 * plzig_cache_clear(): empty the module cache (superuser only by default;
 * EXECUTE is revoked from PUBLIC).  Returns the number of files removed.
 * Functions already loaded in some backend keep running; everything else
 * is recompiled on next use.
 */
Datum
plzig_cache_clear(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64(plzig_cache_clear_files());
}

/* ---------------------------------------------------------------------
 * plzig_check_all()
 * ---------------------------------------------------------------------
 */

/* OIDs of the functions of language langoid in this database, ascending */
static int
plzig_oid_cmp(const void *a, const void *b)
{
	Oid			x = *(const Oid *) a;
	Oid			y = *(const Oid *) b;

	return (x > y) - (x < y);
}

static Oid *
plzig_language_functions(Oid langoid, int *n)
{
	Relation	rel;
	SysScanDesc scan;
	HeapTuple	tup;
	int			size = 64;
	Oid		   *oids = palloc(sizeof(Oid) * size);

	*n = 0;
	/* no index on prolang: a sequential scan of pg_proc */
	rel = table_open(ProcedureRelationId, AccessShareLock);
	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_proc p = (Form_pg_proc) GETSTRUCT(tup);

		if (p->prolang != langoid)
			continue;
		if (*n == size)
		{
			size *= 2;
			oids = repalloc(oids, sizeof(Oid) * size);
		}
		oids[(*n)++] = p->oid;
	}
	systable_endscan(scan);
	table_close(rel, AccessShareLock);
	if (*n > 1)
		qsort(oids, *n, sizeof(Oid), plzig_oid_cmp);
	return oids;
}

/*
 * Compile one function exactly as its validator does with
 * check_function_bodies = on: signature checks, source generation, the
 * compile pipeline with the module cache (lookup, compile under the compile
 * lock, load-check before caching), load-check of the result.  Nothing of
 * the function is executed: loading instantiates the module and calls only
 * the SDK's plzig_abi_version and plzig_init, never plzig_call.
 *
 * Returns false if the function no longer exists or is no longer PL/Zig
 * (dropped or replaced since the list was taken).  The function is locked
 * against DROP while it is compiled; the lock is released again so a
 * long run does not accumulate one lock per function.
 */
static bool
plzig_check_one(Oid fn_oid, Oid langoid)
{
	HeapTuple	proctup;
	PlzigSignature sig;
	char	   *body;
	char	   *wasm;
	uint32		wasm_len;

	/* also makes the catalog caches current (AcceptInvalidationMessages) */
	LockDatabaseObject(ProcedureRelationId, fn_oid, 0, AccessShareLock);
	proctup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(proctup))
	{
		UnlockDatabaseObject(ProcedureRelationId, fn_oid, 0, AccessShareLock);
		return false;
	}
	if (((Form_pg_proc) GETSTRUCT(proctup))->prolang != langoid)
	{
		ReleaseSysCache(proctup);
		UnlockDatabaseObject(ProcedureRelationId, fn_oid, 0, AccessShareLock);
		return false;
	}

	plzig_check_signature(proctup, &sig);
	body = plzig_get_body(proctup);
	/* the functions it uses are resolved and checked as for a call */
	wasm = plzig_get_wasm(plzig_program_build(proctup, &sig, body, false), &wasm_len, true);
	plzig_module_unload(plzig_module_load(wasm, wasm_len));

	ReleaseSysCache(proctup);
	UnlockDatabaseObject(ProcedureRelationId, fn_oid, 0, AccessShareLock);
	return true;
}

/*
 * plzig_check_one in an internal subtransaction (its own function, so that
 * no local of the caller's loop lives across the setjmp).  Returns NULL on
 * success (or if the function is gone), else the error, copied into cxt.
 * Errors of class 57 (cancel, statement timeout, shutdown) are re-thrown:
 * they end the whole run.  The compiler exceeding plzig.compile_timeout is
 * reported with 57014 too, but that is a limit the function exceeded.
 */
static ErrorData *
plzig_check_one_caught(Oid fn_oid, Oid langoid, MemoryContext cxt)
{
	ResourceOwner oldowner = CurrentResourceOwner;
	ErrorData  *volatile edata = NULL;	/* set in PG_CATCH, read after */

	plzig_spawn_timed_out = false;
	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(cxt);
	PG_TRY();
	{
		(void) plzig_check_one(fn_oid, langoid);
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(cxt);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(cxt);
		edata = CopyErrorData();
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(cxt);
		CurrentResourceOwner = oldowner;
		if (ERRCODE_TO_CATEGORY(edata->sqlerrcode) ==
			ERRCODE_TO_CATEGORY(ERRCODE_QUERY_CANCELED) &&
			!(edata->sqlerrcode == ERRCODE_QUERY_CANCELED && plzig_spawn_timed_out))
			ReThrowError(edata);
	}
	PG_END_TRY();
	return edata;
}

/*
 * plzig_check_all(): compile every PL/Zig function of the current database
 * with the configured compiler, under the session's sandbox and limits, and
 * return those that fail with their error (EXECUTE revoked from PUBLIC).
 *
 * Each function is compiled in its own subtransaction, so one failure does
 * not stop the run and leaves nothing behind (build directory, compile
 * lock, catalog references).  A query cancel or statement timeout (any
 * SQLSTATE of class 57, operator intervention) is not a property of a
 * function: it ends the whole run with that error, as usual.
 *
 * The module cache is used as by a call: a function whose module is cached
 * is not recompiled (the cache key covers the PL/Zig ABI, the pinned Zig
 * version, the flags, the SDK and the whole generated source, so the cached
 * module is what this compiler would produce); a module compiled here is
 * cached only after it passed the load check, so failing functions leave
 * nothing in the cache.
 */
Datum
plzig_check_all(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcxt;
	MemoryContext loopcxt;
	Oid			langoid;
	Oid		   *oids;
	int			n;
	int			i;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	oldcxt = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	tupdesc = CreateTupleDescCopy(tupdesc);
	tupstore = tuplestore_begin_heap((rsinfo->allowedModes & SFRM_Materialize_Random) != 0,
									 false, work_mem);
	MemoryContextSwitchTo(oldcxt);

	langoid = get_language_oid("plzig", false);
	oids = plzig_language_functions(langoid, &n);

	loopcxt = AllocSetContextCreate(CurrentMemoryContext, "plzig_check_all",
									ALLOCSET_DEFAULT_SIZES);
	for (i = 0; i < n; i++)
	{
		ErrorData  *edata;

		CHECK_FOR_INTERRUPTS();
		MemoryContextSwitchTo(loopcxt);
		edata = plzig_check_one_caught(oids[i], langoid, loopcxt);

		if (edata)
		{
			Datum		values[4];
			bool		nulls[4] = {false, false, false, false};

			values[0] = ObjectIdGetDatum(oids[i]);
			values[1] = CStringGetTextDatum(unpack_sql_state(edata->sqlerrcode));
			values[2] = CStringGetTextDatum(edata->message ? edata->message : "");
			if (edata->detail)
				values[3] = CStringGetTextDatum(edata->detail);
			else
				nulls[3] = true;
			tuplestore_putvalues(tupstore, tupdesc, values, nulls);
		}
		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(loopcxt);
	}
	MemoryContextDelete(loopcxt);

	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;
	return (Datum) 0;
}
