/*-------------------------------------------------------------------------
 *
 * plzig_runtime.c
 *	  Embedded WebAssembly runtime (WAMR, classic interpreter).
 *
 *	  - initialised lazily in a backend, never in the postmaster;
 *	  - every runtime allocation, including guest linear memory, comes from
 *	    the "PL/Zig runtime" memory context with MCXT_ALLOC_NO_OOM, so
 *	    allocation failure returns NULL to the runtime instead of longjmp'ing
 *	    through interpreter frames;
 *	  - guest linear memory is capped by plzig.max_memory in the allocator
 *	    itself (WAMR does not enforce max_memory_pages below the module's
 *	    initial size);
 *	  - modules are rejected unless every import is a known function in
 *	    module "plzig" whose signature matched, and the expected exports and
 *	    ABI version are present;
 *	  - interrupts: the patched interpreter polls QueryCancelPending and
 *	    ProcDiePending at every branch/call (third_party/wamr-interrupt.patch).
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <dirent.h>
#include <signal.h>

#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

#include "wasm_export.h"

/* referenced by the patched interpreter (CHECK_SUSPEND_FLAGS) */
extern volatile sig_atomic_t *wamr_plzig_interrupt_flags[2];
volatile sig_atomic_t *wamr_plzig_interrupt_flags[2] = {
	&QueryCancelPending, &ProcDiePending
};

/* WAMR's printf-style logging (BH_VPRINTF): discarded. */
extern int	plzig_wamr_vprintf(const char *format, va_list ap);
int
plzig_wamr_vprintf(const char *format, va_list ap)
{
	return 0;
}

struct PlzigModule
{
	wasm_module_t module;
	uint8	   *bytes;			/* must outlive module */
	uint32		len;
};

struct PlzigInstance
{
	PlzigModule *mod;
	wasm_module_inst_t inst;
	wasm_exec_env_t env;
	wasm_function_inst_t f_begin;
	wasm_function_inst_t f_alloc;
	wasm_function_inst_t f_call;
	uint32		max_pages;		/* plzig.max_memory at instantiation */
	PlzigPlanTable plans;		/* prepared statements (plzig_host.c) */
};

#define PLZIG_INTERRUPT_MSG "plzig: interrupted"
#define PLZIG_HOSTERR_MSG	"plzig: host error"

static MemoryContext plzig_runtime_cxt = NULL;
static bool plzig_runtime_ready = false;
static bool plzig_runtime_failed = false;

/* ---------------------------------------------------------------------
 * Allocator
 * ---------------------------------------------------------------------
 */
typedef struct PlzigAllocHdr
{
	Size		size;
	Size		magic;
} PlzigAllocHdr;

#define PLZIG_ALLOC_MAGIC ((Size) 0x706c7a6967UL)

static void *
plzig_rt_malloc(mem_alloc_usage_t usage, unsigned int size)
{
	PlzigAllocHdr *h;

	if (plzig_runtime_cxt == NULL)
		return NULL;
	/* a linear memory is never empty and never larger than plzig.max_memory */
	if (usage == Alloc_For_LinearMemory &&
		(size == 0 || (Size) size > (Size) plzig_max_memory * 1024 * 1024))
		return NULL;
	if (!AllocSizeIsValid((Size) size + sizeof(PlzigAllocHdr)))
		return NULL;
	h = MemoryContextAllocExtended(plzig_runtime_cxt,
								   (Size) size + sizeof(PlzigAllocHdr),
								   MCXT_ALLOC_NO_OOM | MCXT_ALLOC_ZERO);
	if (h == NULL)
		return NULL;
	h->size = size;
	h->magic = PLZIG_ALLOC_MAGIC;
	return (char *) h + sizeof(PlzigAllocHdr);
}

static void
plzig_rt_free(mem_alloc_usage_t usage, void *ptr)
{
	PlzigAllocHdr *h;

	if (ptr == NULL)
		return;
	h = (PlzigAllocHdr *) ((char *) ptr - sizeof(PlzigAllocHdr));
	if (h->magic != PLZIG_ALLOC_MAGIC)
		return;					/* never free what we did not allocate */
	h->magic = 0;
	pfree(h);
}

/* alloc + copy + free: same semantics on every PG version, new tail zeroed */
static void *
plzig_rt_realloc(mem_alloc_usage_t usage, bool full_size_mmaped, void *ptr,
				 unsigned int size)
{
	PlzigAllocHdr *h;
	void	   *n;

	if (ptr == NULL)
		return plzig_rt_malloc(usage, size);
	/* as in plzig_rt_malloc: a linear memory is never empty */
	if (usage == Alloc_For_LinearMemory && size == 0)
		return NULL;
	h = (PlzigAllocHdr *) ((char *) ptr - sizeof(PlzigAllocHdr));
	if (h->magic != PLZIG_ALLOC_MAGIC)
		return NULL;
	n = plzig_rt_malloc(usage, size);
	if (n == NULL)
		return NULL;
	memcpy(n, ptr, Min(h->size, (Size) size));
	plzig_rt_free(usage, ptr);
	return n;
}

/* ---------------------------------------------------------------------
 * Initialisation
 * ---------------------------------------------------------------------
 */
static int
plzig_count_threads(void)
{
	DIR		   *dir;
	struct dirent *de;
	int			n = 0;

	dir = AllocateDir("/proc/self/task");
	if (dir == NULL)
		return -1;
	while ((de = ReadDirExtended(dir, "/proc/self/task", LOG)) != NULL)
		if (de->d_name[0] != '.')
			n++;
	FreeDir(dir);
	return n;
}

static void
plzig_runtime_init(void)
{
	RuntimeInitArgs args;
	struct sigaction *before;
	int			threads_before;
	int			threads_after;
	int			sig;
	NativeSymbol *syms;
	int			nsyms;

	if (plzig_runtime_ready)
		return;
	if (plzig_runtime_failed)
		ereport(ERROR,
				(errcode(ERRCODE_SYSTEM_ERROR),
				 errmsg("PL/Zig runtime is unavailable in this session")));
	if (!IsUnderPostmaster)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/Zig runtime cannot be used in the postmaster or a standalone backend")));

	if (plzig_runtime_cxt == NULL)
		plzig_runtime_cxt = AllocSetContextCreate(TopMemoryContext,
												  "PL/Zig runtime",
												  ALLOCSET_DEFAULT_SIZES);

	/* snapshot signal dispositions and threads: WAMR must change neither */
	before = palloc0(sizeof(struct sigaction) * NSIG);
	for (sig = 1; sig < NSIG; sig++)
		(void) sigaction(sig, NULL, &before[sig]);
	threads_before = plzig_count_threads();

	syms = (NativeSymbol *) plzig_host_symbols(&nsyms);

	memset(&args, 0, sizeof(args));
	args.mem_alloc_type = Alloc_With_Allocator;
	args.mem_alloc_option.allocator.malloc_func = (void *) plzig_rt_malloc;
	args.mem_alloc_option.allocator.realloc_func = (void *) plzig_rt_realloc;
	args.mem_alloc_option.allocator.free_func = (void *) plzig_rt_free;
	args.running_mode = Mode_Interp;
	args.native_module_name = "plzig";
	args.native_symbols = syms;
	args.n_native_symbols = (uint32) nsyms;

	if (!wasm_runtime_full_init(&args))
	{
		plzig_runtime_failed = true;
		ereport(ERROR,
				(errcode(ERRCODE_SYSTEM_ERROR),
				 errmsg("could not initialize the PL/Zig WebAssembly runtime")));
	}
	wasm_runtime_set_log_level(WASM_LOG_LEVEL_FATAL);

	for (sig = 1; sig < NSIG; sig++)
	{
		struct sigaction now;

		(void) sigaction(sig, NULL, &now);
		if (now.sa_handler != before[sig].sa_handler)
		{
			plzig_runtime_failed = true;
			ereport(FATAL,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("PL/Zig: WebAssembly runtime changed the handler of signal %d", sig)));
		}
	}
	threads_after = plzig_count_threads();
	if (threads_before > 0 && threads_after != threads_before)
	{
		plzig_runtime_failed = true;
		ereport(FATAL,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("PL/Zig: WebAssembly runtime started threads (%d -> %d)",
						threads_before, threads_after)));
	}
	pfree(before);
	plzig_runtime_ready = true;
}

/* ---------------------------------------------------------------------
 * Guest memory helpers (used by plzig_host.c too)
 * ---------------------------------------------------------------------
 */
bool
plzig_guest_range(void *module_inst, uint32 ptr, uint32 len)
{
	return wasm_runtime_validate_app_addr((wasm_module_inst_t) module_inst,
										  (uint64) ptr, (uint64) len);
}

/*
 * Native pointer for guest range [ptr, ptr+len), or ERROR; NULL if len == 0
 * (callers must not dereference it then). The pointer is valid only until
 * control returns to the guest (memory.grow may move it).
 */
void *
plzig_guest_ptr(void *module_inst, uint32 ptr, uint32 len)
{
	wasm_module_inst_t mi = (wasm_module_inst_t) module_inst;

	/* Zig uses dangling (but aligned) pointers for empty slices */
	if (len == 0)
		return NULL;
	if (!wasm_runtime_validate_app_addr(mi, (uint64) ptr, (uint64) len))
	{
		wasm_runtime_clear_exception(mi);
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: guest passed an invalid memory range")));
	}
	return wasm_runtime_addr_app_to_native(mi, (uint64) ptr);
}

/* ---------------------------------------------------------------------
 * Modules
 * ---------------------------------------------------------------------
 */
/* must match plzig_native_symbols in plzig_host.c */
static const char *const plzig_known_imports[] = {
	"log", "raise", "panic", "spi_execute", "spi_ncols", "spi_value_len",
	"spi_value_copy", "spi_colname_len", "spi_colname_copy",
	"spi_row_size", "spi_row_read", "spi_prepare", "spi_plan_free",
	"spi_execute_plan", "spi_cursor_open", "spi_cursor_open_plan",
	"spi_cursor_next", "spi_cursor_read", "spi_cursor_close", NULL
};

static bool
plzig_known_import(const char *name)
{
	int			i;

	for (i = 0; plzig_known_imports[i]; i++)
		if (strcmp(plzig_known_imports[i], name) == 0)
			return true;
	return false;
}

/*
 * Declared sizes that cost WAMR far more than the module's size, or that
 * can never work under PL/Zig.
 *
 * WAMR's loader and instantiation never check for interrupts, so their cost
 * must stay proportional to the size of the module.  Two declarations break
 * that (found by the loader fuzz target, fuzz/loader/findings/):
 *
 *  - locals: load_function_section allocates (zeroed) and walks one byte
 *    per declared local before it rejects a function with more than 65535
 *    local cells, so 30 bytes declaring 2^30 locals cost about 1 GB and
 *    seconds of CPU.  Every local takes at least one cell, so a function
 *    declaring more than PLZIG_MAX_LOCALS locals can never load.
 *  - table size: tables_instantiate allocates (and fills) up to twice the
 *    declared initial size, so 17 bytes declaring 130 million elements
 *    cost about 1 GB per instance, outside plzig.max_memory (which caps
 *    linear memory only).  Without reference types and bulk memory, table
 *    entries can only come from element segments, which take at least a
 *    byte per entry; PLZIG_MAX_TABLE_ELEMS is far above anything a PL/Zig
 *    module needs (Zig sizes the table to the functions used indirectly).
 *
 *  - initial memory: plzig.max_memory is at most PLZIG_MAX_MEMORY_MB, so a
 *    module declaring more initial pages than that can never be
 *    instantiated; it is refused here rather than after WAMR has loaded it.
 *
 * Such modules are refused before WAMR sees them.  The scan refuses only
 * these three things: anything it cannot parse is left to WAMR's validation,
 * and it reads every byte at most once.
 */
#define PLZIG_MAX_LOCALS		65535
#define PLZIG_MAX_TABLE_ELEMS	(1024 * 1024)
#define PLZIG_MAX_MEMORY_MB		1023	/* upper bound of plzig.max_memory (plzig.c) */
#define PLZIG_MAX_INITIAL_PAGES	(PLZIG_MAX_MEMORY_MB * 16)	/* 64 kB pages */

static bool
plzig_read_u32_leb(const uint8 **p, const uint8 *end, uint32 *val)
{
	uint64		v = 0;
	int			shift = 0;

	while (*p < end && shift < 35)
	{
		uint8		b = *(*p)++;

		v |= (uint64) (b & 0x7f) << shift;
		if ((b & 0x80) == 0)
		{
			if (v > PG_UINT32_MAX)
				return false;
			*val = (uint32) v;
			return true;
		}
		shift += 7;
	}
	return false;
}

/* NULL if fine, else what is wrong */
static const char *
plzig_module_precheck(const uint8 *mod, uint32 len)
{
	const uint8 *p = mod + 8;	/* after magic and version */
	const uint8 *end = mod + len;

	while (p < end)
	{
		uint8		id = *p++;
		uint32		size;
		const uint8 *sec_end;
		const uint8 *q;
		uint32		n;
		uint32		i;

		if (!plzig_read_u32_leb(&p, end, &size) || size > (uint32) (end - p))
			return NULL;
		sec_end = p + size;
		q = p;
		p = sec_end;
		if (id == 5)			/* memory section: limits* */
		{
			if (!plzig_read_u32_leb(&q, sec_end, &n))
				return NULL;
			for (i = 0; i < n; i++)
			{
				uint8		flags;
				uint32		min;

				if (q >= sec_end)
					return NULL;
				flags = *q++;
				if (!plzig_read_u32_leb(&q, sec_end, &min))
					return NULL;
				if (min > PLZIG_MAX_INITIAL_PAGES)
					return "a linear memory declares more than 1023 MB";
				if ((flags & 1) && !plzig_read_u32_leb(&q, sec_end, &min))
					return NULL;
			}
		}
		else if (id == 4)		/* table section: (reftype, limits)* */
		{
			if (!plzig_read_u32_leb(&q, sec_end, &n))
				return NULL;
			for (i = 0; i < n; i++)
			{
				uint8		flags;
				uint32		min;
				uint32		max;

				if (sec_end - q < 2)
					return NULL;
				q++;			/* reference type */
				flags = *q++;
				if (!plzig_read_u32_leb(&q, sec_end, &min))
					return NULL;
				if (min > PLZIG_MAX_TABLE_ELEMS)
					return "a table declares more than 1048576 elements";
				if ((flags & 1) && !plzig_read_u32_leb(&q, sec_end, &max))
					return NULL;
			}
		}
		else if (id == 10)		/* code section: (size, locals, code)* */
		{
			if (!plzig_read_u32_leb(&q, sec_end, &n))
				return NULL;
			for (i = 0; i < n && q < sec_end; i++)
			{
				uint32		body;
				uint32		ngroups;
				uint32		g;
				uint64		total = 0;
				const uint8 *body_end;

				if (!plzig_read_u32_leb(&q, sec_end, &body) || body > (uint32) (sec_end - q))
					return NULL;
				body_end = q + body;
				if (!plzig_read_u32_leb(&q, body_end, &ngroups))
					return NULL;
				/* each group is a count and a value type: >= 2 bytes */
				for (g = 0; g < ngroups; g++)
				{
					uint32		cnt;

					if (!plzig_read_u32_leb(&q, body_end, &cnt) || q >= body_end)
						return NULL;
					q++;		/* value type */
					total += cnt;
					if (total > PLZIG_MAX_LOCALS)
						return "a function declares more than 65535 locals";
				}
				q = body_end;
			}
		}
	}
	return NULL;
}

PlzigModule *
plzig_module_load(const char *wasm, uint32 len)
{
	PlzigModule *mod;
	char		err[256];
	int32		nimports;
	int32		i;

	plzig_runtime_init();

	if (len < 8 || len > PLZIG_MAX_WASM_SIZE)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: compiled module has invalid size")));

	{
		const char *problem = plzig_module_precheck((const uint8 *) wasm, len);

		if (problem)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
					 errmsg("PL/Zig: invalid WebAssembly module: %s", problem)));
	}

	mod = MemoryContextAllocZero(plzig_runtime_cxt, sizeof(PlzigModule));
	mod->bytes = MemoryContextAlloc(plzig_runtime_cxt, len);
	memcpy(mod->bytes, wasm, len);
	mod->len = len;

	err[0] = '\0';
	mod->module = wasm_runtime_load(mod->bytes, len, err, sizeof(err));
	if (mod->module == NULL)
	{
		pfree(mod->bytes);
		pfree(mod);
		err[sizeof(err) - 1] = '\0';
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: invalid WebAssembly module: %s", err)));
	}

	/* explicit import allowlist */
	nimports = wasm_runtime_get_import_count(mod->module);
	for (i = 0; i < nimports; i++)
	{
		wasm_import_t imp;
		const char *problem = NULL;

		memset(&imp, 0, sizeof(imp));
		wasm_runtime_get_import_type(mod->module, i, &imp);
		if (imp.kind != WASM_IMPORT_EXPORT_KIND_FUNC)
			problem = "non-function import";
		else if (imp.module_name == NULL || strcmp(imp.module_name, "plzig") != 0)
			problem = "import from a module other than \"plzig\"";
		else if (imp.name == NULL || !plzig_known_import(imp.name))
			problem = "unknown host function";
		else if (!imp.linked)
			problem = "host function signature mismatch";

		if (problem)
		{
			char		what[128];

			snprintf(what, sizeof(what), "%s.%s",
					 imp.module_name ? imp.module_name : "?",
					 imp.name ? imp.name : "?");
			plzig_module_unload(mod);
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("PL/Zig: module rejected: %s", problem),
					 errdetail("Import \"%s\". Guest code can only call the PL/Zig host API.",
							   pg_any_to_server(what, strlen(what), PG_SQL_ASCII))));
		}
	}

	/*
	 * Instantiate once to check exports and ABI version.  This can fail (for
	 * example when the module's initial memory exceeds plzig.max_memory); the
	 * module must not be leaked in the long-lived runtime context then.
	 */
	PG_TRY();
	{
		PlzigInstance *inst = plzig_instance_create(mod);

		plzig_instance_destroy(inst);
	}
	PG_CATCH();
	{
		plzig_module_unload(mod);
		PG_RE_THROW();
	}
	PG_END_TRY();
	return mod;
}

void
plzig_module_unload(PlzigModule *mod)
{
	if (mod == NULL)
		return;
	if (mod->module)
		wasm_runtime_unload(mod->module);
	pfree(mod->bytes);
	pfree(mod);
}

/* ---------------------------------------------------------------------
 * Instances
 * ---------------------------------------------------------------------
 */
static wasm_function_inst_t
plzig_lookup(PlzigInstance *pi, const char *name, uint32 nparams, uint32 nresults)
{
	wasm_function_inst_t f = wasm_runtime_lookup_function(pi->inst, name);

	if (f == NULL ||
		wasm_func_get_param_count(f, pi->inst) != nparams ||
		wasm_func_get_result_count(f, pi->inst) != nresults)
		return NULL;
	return f;
}

/* Call a guest function; returns false if it trapped. */
static bool
plzig_guest_call(PlzigInstance *pi, wasm_function_inst_t f, uint32 argc, uint32 *argv)
{
	return wasm_runtime_call_wasm(pi->env, f, argc, argv);
}

PlzigInstance *
plzig_instance_create(PlzigModule *mod)
{
	PlzigInstance *pi;
	InstantiationArgs ia;
	char		err[256];
	uint32		argv[1];
	const char *problem = NULL;

	plzig_runtime_init();
	pi = MemoryContextAllocZero(plzig_runtime_cxt, sizeof(PlzigInstance));
	pi->mod = mod;

	memset(&ia, 0, sizeof(ia));
	ia.default_stack_size = PLZIG_WASM_STACK;
	ia.host_managed_heap_size = 0;
	ia.max_memory_pages = (uint32) plzig_max_memory * 16;	/* 64 kB pages */
	pi->max_pages = ia.max_memory_pages;

	err[0] = '\0';
	pi->inst = wasm_runtime_instantiate_ex(mod->module, &ia, err, sizeof(err));
	if (pi->inst == NULL)
	{
		pfree(pi);
		err[sizeof(err) - 1] = '\0';
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("PL/Zig: could not instantiate module: %s", err),
				 errhint("The module's initial memory may exceed plzig.max_memory (%d MB).",
						 plzig_max_memory)));
	}
	pi->env = wasm_runtime_create_exec_env(pi->inst, PLZIG_WASM_STACK);
	if (pi->env == NULL)
		problem = "could not create execution environment";
	else
	{
		wasm_runtime_set_user_data(pi->env, NULL);
		pi->f_begin = plzig_lookup(pi, "plzig_begin", 0, 0);
		pi->f_alloc = plzig_lookup(pi, "plzig_alloc", 1, 1);
		pi->f_call = plzig_lookup(pi, "plzig_call", 3, 1);
		{
			wasm_function_inst_t fv = plzig_lookup(pi, "plzig_abi_version", 0, 1);

			if (!pi->f_begin || !pi->f_alloc || !pi->f_call || !fv)
				problem = "missing or malformed PL/Zig entry points";
			else if (wasm_runtime_get_default_memory(pi->inst) == NULL)
				problem = "module has no linear memory";
			else
			{
				argv[0] = 0;
				if (!plzig_guest_call(pi, fv, 0, argv))
				{
					const char *exc = wasm_runtime_get_exception(pi->inst);

					if (exc && strstr(exc, PLZIG_INTERRUPT_MSG) != NULL)
					{
						plzig_instance_destroy(pi);
						CHECK_FOR_INTERRUPTS();
						ereport(ERROR,
								(errcode(ERRCODE_QUERY_CANCELED),
								 errmsg("canceling statement due to interrupt in PL/Zig function")));
					}
					problem = "plzig_abi_version trapped";
				}
				else if (argv[0] != PLZIG_ABI_VERSION)
					problem = "ABI version mismatch";
			}
		}
	}
	if (problem)
	{
		plzig_instance_destroy(pi);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("PL/Zig: module rejected: %s", problem)));
	}
	return pi;
}

/* The instance's prepared-statement table (used by plzig_host.c only). */
PlzigPlanTable *
plzig_instance_plans(PlzigInstance *pi)
{
	return &pi->plans;
}

/* Long-lived context of the runtime (instances, plan tables). */
MemoryContext
plzig_runtime_context(void)
{
	return plzig_runtime_cxt;
}

/* Was this instance created under the current plzig.max_memory? */
bool
plzig_instance_current(PlzigInstance *pi)
{
	return pi->max_pages == (uint32) plzig_max_memory * 16;
}

/* Current size of the instance's linear memory in bytes. */
uint64
plzig_instance_memory_size(PlzigInstance *pi)
{
	wasm_memory_inst_t mem = wasm_runtime_get_default_memory(pi->inst);

	if (mem == NULL)
		return 0;
	return wasm_memory_get_cur_page_count(mem) * wasm_memory_get_bytes_per_page(mem);
}

/*
 * Destroy an instance and everything it owns.  Used on every path that ends
 * an instance (error/trap, LRU eviction, instance_cache_max_memory, function
 * replaced or dropped, plzig.max_memory changed, DO block end), so its
 * prepared statements are freed here and can never outlive it.  Must not
 * throw: it runs in PG_CATCH blocks.
 */
void
plzig_instance_destroy(PlzigInstance *pi)
{
	if (pi == NULL)
		return;
	plzig_host_free_plans(&pi->plans);
	if (pi->env)
		wasm_runtime_destroy_exec_env(pi->env);
	if (pi->inst)
		wasm_runtime_deinstantiate(pi->inst);
	pfree(pi);
}

/* ---------------------------------------------------------------------
 * Calls
 * ---------------------------------------------------------------------
 */

/* Raise the appropriate ERROR after the guest trapped. */
static void
plzig_report_trap(PlzigInstance *pi, PlzigCallCtx *ctx)
{
	const char *exc = wasm_runtime_get_exception(pi->inst);
	char		msg[256];

	if (ctx && ctx->edata)
		ReThrowError(ctx->edata);

	strlcpy(msg, exc ? exc : "unknown", sizeof(msg));
	wasm_runtime_clear_exception(pi->inst);

	if (strstr(msg, PLZIG_INTERRUPT_MSG) != NULL)
	{
		CHECK_FOR_INTERRUPTS();
		ereport(ERROR,
				(errcode(ERRCODE_QUERY_CANCELED),
				 errmsg("canceling statement due to interrupt in PL/Zig function")));
	}
	/* "Exception: " prefix added by WAMR */
	if (strncmp(msg, "Exception: ", 11) == 0)
		memmove(msg, msg + 11, strlen(msg + 11) + 1);
	ereport(ERROR,
			(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
			 errmsg("PL/Zig function trapped: %s",
					pg_any_to_server(msg, strlen(msg), PG_SQL_ASCII))));
}

static void
plzig_put_bytes(uint8 *base, uint32 *off, PlzigSlot *slot, uint32 guest_base,
				const char *data, uint32 len)
{
	slot->len = len;
	slot->is_null = 0;
	slot->val = (uint64) (guest_base + *off);
	if (len > 0)
		memcpy(base + *off, data, len);
	*off += TYPEALIGN(8, len);
}

/*
 * Copy guest bytes [ptr, ptr+len) into a palloc'd, NUL-terminated buffer.
 */
static char *
plzig_copy_out(PlzigInstance *pi, uint64 ptr, uint32 len)
{
	char	   *buf;
	void	   *src;

	if (ptr > PG_UINT32_MAX && len > 0)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: guest returned an invalid pointer")));
	if ((Size) len + 1 > MaxAllocSize - VARHDRSZ)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: result value is too large")));
	src = plzig_guest_ptr(pi->inst, (uint32) (ptr & PG_UINT32_MAX), len);
	buf = palloc((Size) len + 1);
	if (len > 0)
		memcpy(buf, src, len);
	buf[len] = '\0';
	return buf;
}

/*
 * Copy guest bytes [ptr, ptr+len) straight into a new palloc'd varlena (one
 * copy across the boundary; the result never aliases guest memory).  Same
 * pointer and size checks as plzig_copy_out.
 */
static struct varlena *
plzig_copy_out_varlena(PlzigInstance *pi, uint64 ptr, uint32 len)
{
	struct varlena *v;
	void	   *src;

	if (ptr > PG_UINT32_MAX && len > 0)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("PL/Zig: guest returned an invalid pointer")));
	if ((Size) len + 1 > MaxAllocSize - VARHDRSZ)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: result value is too large")));
	src = plzig_guest_ptr(pi->inst, (uint32) (ptr & PG_UINT32_MAX), len);
	v = (struct varlena *) palloc(VARHDRSZ + (Size) len);
	SET_VARSIZE(v, VARHDRSZ + (Size) len);
	if (len > 0)
		memcpy(VARDATA(v), src, len);
	return v;
}

static Datum
plzig_decode_result(PlzigInstance *pi, PlzigSlot *slot, PlzigTypeInfo *rt,
					bool *isnull)
{
	*isnull = false;
	if (rt->kind == PLZIG_T_VOID)
		return (Datum) 0;
	if (slot->is_null)
	{
		/*
		 * NULL through the input function too: for a domain this checks its
		 * NOT NULL and CHECK constraints (domain_in is not strict); for the
		 * strict input functions of all other types it is a no-op.
		 */
		if (rt->kind == PLZIG_T_IO || rt->kind == PLZIG_T_TEXTIO)
			(void) InputFunctionCall(&rt->in_func, NULL, rt->ioparam, -1);
		*isnull = true;
		return (Datum) 0;
	}
	switch (rt->kind)
	{
		case PLZIG_T_BOOL:
			return BoolGetDatum(slot->val != 0);
		case PLZIG_T_INT2:
			return Int16GetDatum((int16) (int64) slot->val);
		case PLZIG_T_INT4:
			return Int32GetDatum((int32) (int64) slot->val);
		case PLZIG_T_INT8:
			return Int64GetDatum((int64) slot->val);
		case PLZIG_T_FLOAT4:
			{
				uint32		bits = (uint32) slot->val;
				float4		f;

				memcpy(&f, &bits, sizeof(f));
				return Float4GetDatum(f);
			}
		case PLZIG_T_FLOAT8:
			{
				float8		f;

				memcpy(&f, &slot->val, sizeof(f));
				return Float8GetDatum(f);
			}
		case PLZIG_T_BYTEA:
			return PointerGetDatum(plzig_copy_out_varlena(pi, slot->val, slot->len));
		case PLZIG_T_TEXT:
			{
				struct varlena *t = plzig_copy_out_varlena(pi, slot->val, slot->len);

				/*
				 * Validate the host copy in place: rejects invalid sequences
				 * and NUL bytes (on error t goes with the memory context).
				 */
				(void) pg_verifymbstr(VARDATA(t), (int) slot->len, false);
				return PointerGetDatum(t);
			}
		case PLZIG_T_TEXTIO:
		case PLZIG_T_IO:
			{
				/* input functions need a NUL-terminated C string */
				char	   *s = plzig_copy_out(pi, slot->val, slot->len);

				(void) pg_verifymbstr(s, (int) slot->len, false);
				return InputFunctionCall(&rt->in_func, s, rt->ioparam, -1);
			}
		case PLZIG_T_VOID:
			break;
	}
	return (Datum) 0;
}

/*
 * Run one call of the guest function.
 *
 * Arguments are copied into guest memory (allocated by the guest's arena),
 * the guest runs, and the result is copied out.  Any host-import error
 * was stashed in ctx->edata and is re-thrown here, after WAMR unwound.
 */
Datum
plzig_instance_call(PlzigInstance *pi, PlzigTypeInfo *argtypes, int nargs,
					NullableDatum *args, PlzigTypeInfo *rettype, bool read_only,
					bool *isnull)
{
	PlzigCallCtx ctx;
	MemoryContext callcxt;
	MemoryContext oldcxt;
	const char **bytes;
	uint32	   *lens;
	uint64		total;
	uint32		guest_base;
	uint32		argv[3];
	uint8	   *base;
	PlzigSlot	result;
	uint32		off;
	uint32		status;
	volatile Datum ret;			/* set inside PG_TRY, read after it */
	int			i;

	check_stack_depth();

	callcxt = AllocSetContextCreate(CurrentMemoryContext, "PL/Zig call",
									ALLOCSET_SMALL_SIZES);
	oldcxt = MemoryContextSwitchTo(callcxt);

	memset(&ctx, 0, sizeof(ctx));
	ctx.inst = pi;
	ctx.cxt = callcxt;
	ctx.scratch = AllocSetContextCreate(callcxt, "PL/Zig SPI scratch",
										ALLOCSET_SMALL_SIZES);
	ctx.read_only = read_only;
	ctx.cached_row = -1;
	ctx.cached_col = -1;
	ctx.cached_name_col = -1;

	/* prepare argument bytes on the host side first */
	bytes = palloc0(sizeof(char *) * (nargs + 1));
	lens = palloc0(sizeof(uint32) * (nargs + 1));
	total = (uint64) (nargs + 1) * sizeof(PlzigSlot);
	for (i = 0; i < nargs; i++)
	{
		PlzigTypeKind k = argtypes[i].kind;

		if (args[i].isnull)
			continue;
		if (k == PLZIG_T_TEXT || k == PLZIG_T_TEXTIO || k == PLZIG_T_BYTEA)
		{
			struct varlena *v = PG_DETOAST_DATUM_PACKED(args[i].value);

			bytes[i] = VARDATA_ANY(v);
			lens[i] = VARSIZE_ANY_EXHDR(v);
		}
		else if (k == PLZIG_T_IO)
		{
			char	   *s = OutputFunctionCall(&argtypes[i].out_func, args[i].value);

			bytes[i] = s;
			lens[i] = (uint32) strlen(s);
		}
		total += TYPEALIGN(8, (uint64) lens[i]);
	}
	if (total > PG_UINT32_MAX - 16)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("PL/Zig: arguments too large")));

	wasm_runtime_set_user_data(pi->env, &ctx);

	PG_TRY();
	{
		/* 1. reset the guest arena */
		if (!plzig_guest_call(pi, pi->f_begin, 0, argv))
			plzig_report_trap(pi, &ctx);

		/* 2. allocate and fill argument slots */
		argv[0] = (uint32) total;
		if (!plzig_guest_call(pi, pi->f_alloc, 1, argv))
			plzig_report_trap(pi, &ctx);
		guest_base = argv[0];
		if (guest_base == 0)
			ereport(ERROR,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("PL/Zig: out of guest memory for arguments"),
					 errhint("Increase plzig.max_memory.")));

		base = plzig_guest_ptr(pi->inst, guest_base, (uint32) total);
		off = (uint32) ((nargs + 1) * sizeof(PlzigSlot));
		for (i = 0; i < nargs; i++)
		{
			PlzigSlot	s;

			memset(&s, 0, sizeof(s));
			if (args[i].isnull)
				s.is_null = 1;
			else
			{
				switch (argtypes[i].kind)
				{
					case PLZIG_T_BOOL:
						s.val = DatumGetBool(args[i].value) ? 1 : 0;
						break;
					case PLZIG_T_INT2:
						s.val = (uint64) (int64) DatumGetInt16(args[i].value);
						break;
					case PLZIG_T_INT4:
						s.val = (uint64) (int64) DatumGetInt32(args[i].value);
						break;
					case PLZIG_T_INT8:
						s.val = (uint64) DatumGetInt64(args[i].value);
						break;
					case PLZIG_T_FLOAT4:
						{
							float4		f = DatumGetFloat4(args[i].value);
							uint32		bits;

							memcpy(&bits, &f, sizeof(bits));
							s.val = bits;
							break;
						}
					case PLZIG_T_FLOAT8:
						{
							float8		f = DatumGetFloat8(args[i].value);

							memcpy(&s.val, &f, sizeof(f));
							break;
						}
					case PLZIG_T_TEXT:
					case PLZIG_T_TEXTIO:
					case PLZIG_T_BYTEA:
					case PLZIG_T_IO:
						plzig_put_bytes(base, &off, &s, guest_base, bytes[i], lens[i]);
						break;
					case PLZIG_T_VOID:
						break;
				}
			}
			/*
			 * byte offsets, not &slots[i]: the address comes from the
			 * guest's plzig_alloc and need not be aligned for PlzigSlot
			 */
			memcpy(base + (Size) i * sizeof(PlzigSlot), &s, sizeof(s));
		}
		memset(base + (Size) nargs * sizeof(PlzigSlot), 0, sizeof(PlzigSlot));
		/* base is not used after this point: the guest may move memory */

		/* 3. call */
		argv[0] = guest_base;
		argv[1] = (uint32) nargs;
		argv[2] = guest_base + (uint32) (nargs * sizeof(PlzigSlot));
		if (!plzig_guest_call(pi, pi->f_call, 3, argv))
			plzig_report_trap(pi, &ctx);
		if (ctx.edata)			/* belt and braces: never lose a host error */
			ReThrowError(ctx.edata);
		status = argv[0];

		/* 4. result */
		memcpy(&result,
			   plzig_guest_ptr(pi->inst, guest_base + (uint32) (nargs * sizeof(PlzigSlot)),
							   sizeof(PlzigSlot)),
			   sizeof(PlzigSlot));

		if (status == 1)
		{
			char		name[PLZIG_MAX_ERROR_NAME + 1];
			uint32		nlen = Min(result.len, PLZIG_MAX_ERROR_NAME);
			char	   *raw = plzig_copy_out(pi, result.val, nlen);
			uint32		j;

			for (j = 0; j < nlen; j++)
			{
				unsigned char c = (unsigned char) raw[j];

				name[j] = (c >= 0x20 && c < 0x7f) ? (char) c : '?';
			}
			name[nlen] = '\0';
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("plzig function failed: %s", name)));
		}
		else if (status != 0)
			ereport(ERROR,
					(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
					 errmsg("PL/Zig: invalid status %u from guest", status)));

		MemoryContextSwitchTo(oldcxt);
		ret = plzig_decode_result(pi, &result, rettype, isnull);
		/* pass-by-reference results were allocated in the caller's context */
	}
	PG_FINALLY();
	{
		wasm_runtime_set_user_data(pi->env, NULL);
	}
	PG_END_TRY();

	plzig_host_finish_call(&ctx);
	MemoryContextSwitchTo(oldcxt);
	MemoryContextDelete(callcxt);
	return ret;
}
