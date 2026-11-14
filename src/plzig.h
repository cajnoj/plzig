/*-------------------------------------------------------------------------
 *
 * plzig.h
 *	  PL/Zig: shared declarations.
 *
 * See PLAN.md for the design and doc/abi.md for the host/guest ABI.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLZIG_H
#define PLZIG_H

#include "postgres.h"

#include "access/htup.h"
#include "fmgr.h"
#include "lib/stringinfo.h"

#define PLZIG_VERSION_STR		"1.0"
#define PLZIG_ABI_VERSION		1
/*
 * The Zig version the source validator was built with, from the Makefile
 * (ZIG_VERSION).  The backend runs only a compiler reporting exactly this.
 */
#ifndef PLZIG_ZIG_VERSION
#error "PLZIG_ZIG_VERSION must be defined by the build (Makefile ZIG_VERSION)"
#endif

/* Fixed limits */
#define PLZIG_MAX_WASM_SIZE		(16 * 1024 * 1024)	/* compiled module size */
#define PLZIG_MAX_OUTPUT		(64 * 1024)	/* compiler output kept */
#define PLZIG_GUEST_STACK		(256 * 1024)	/* Zig shadow stack in linear memory */
#define PLZIG_WASM_STACK		(512 * 1024)	/* interpreter operand/frame stack */
#define PLZIG_MAX_LOG_MSG		(64 * 1024)
#define PLZIG_MAX_ERROR_NAME	256

/* Compiler sandbox modes (plzig.compiler_sandbox) */
typedef enum PlzigSandboxMode
{
	PLZIG_SANDBOX_OFF,
	PLZIG_SANDBOX_TRY,
	PLZIG_SANDBOX_REQUIRE
} PlzigSandboxMode;

/* GUC variables (plzig.c) */
extern char *plzig_zig_path;
extern char *plzig_zig_lib_dir;
extern char *plzig_zig_sha256;
extern char *plzig_compiler_sandbox;
extern int	plzig_compile_timeout;	/* ms */
extern int	plzig_compile_memory_limit; /* MB, 0 = off */
extern int	plzig_max_source_size;	/* kB */
extern int	plzig_max_memory;		/* MB */
extern int	plzig_instance_cache_size;

/* ---------------------------------------------------------------------
 * Types (plzig_types.c)
 * ---------------------------------------------------------------------
 */
typedef enum PlzigTypeKind
{
	PLZIG_T_VOID,
	PLZIG_T_BOOL,
	PLZIG_T_INT2,
	PLZIG_T_INT4,
	PLZIG_T_INT8,
	PLZIG_T_FLOAT4,
	PLZIG_T_FLOAT8,
	PLZIG_T_TEXT,				/* text: bytes in, bytes out (encoding checked) */
	PLZIG_T_TEXTIO,				/* varchar/bpchar: bytes in, input function out */
	PLZIG_T_BYTEA,
	PLZIG_T_IO					/* anything else: text I/O representation */
} PlzigTypeKind;

typedef struct PlzigTypeInfo
{
	Oid			typid;
	PlzigTypeKind kind;
	FmgrInfo	out_func;		/* for arguments (PLZIG_T_IO) */
	FmgrInfo	in_func;		/* for results (PLZIG_T_IO, PLZIG_T_TEXTIO) */
	Oid			ioparam;
} PlzigTypeInfo;

/* Guest argument/result slot, 16 bytes, little endian (doc/abi.md) */
typedef struct PlzigSlot
{
	uint64		val;
	uint32		len;
	uint32		is_null;
} PlzigSlot;

extern PlzigTypeKind plzig_type_kind(Oid typid);
extern const char *plzig_zig_type_name(PlzigTypeKind kind);
extern void plzig_type_info_init(PlzigTypeInfo *ti, Oid typid, bool for_result,
								 MemoryContext mcxt);

/* ---------------------------------------------------------------------
 * Source generation (plzig_source.c)
 * ---------------------------------------------------------------------
 */
typedef struct PlzigSignature
{
	int			nargs;
	Oid		   *argtypes;
	char	  **argnames;		/* validated identifiers, never NULL entries */
	Oid			rettype;
	bool		strict;
	bool		is_procedure;
	char		volatility;
} PlzigSignature;

extern void plzig_check_signature(HeapTuple proctup, PlzigSignature *sig);
extern char *plzig_get_body(HeapTuple proctup);
extern char *plzig_generate_source(const PlzigSignature *sig, const char *body,
								   size_t *srclen);
extern char *plzig_generate_inline_source(const char *body, size_t *srclen);

/* ---------------------------------------------------------------------
 * Build pipeline (plzig_build.c)
 * ---------------------------------------------------------------------
 */
extern char *plzig_get_wasm(const char *src, size_t srclen, uint32 *wasm_len);
extern const char *plzig_sandbox_status_string(void);
extern void plzig_build_atexit(void);

/* ---------------------------------------------------------------------
 * Child processes (plzig_spawn.c) and sandbox (plzig_sandbox.c)
 * ---------------------------------------------------------------------
 */
#define PLZIG_SANDBOX_MAX_PATHS 4

typedef struct PlzigSandbox
{
	int			mode;			/* PlzigSandboxMode */
	int			landlock_abi;	/* probed in the parent; <= 0 = unavailable */
	const char *rx_files[PLZIG_SANDBOX_MAX_PATHS];	/* single files: read + execute */
	int			n_rx_files;
	const char *ro_dirs[PLZIG_SANDBOX_MAX_PATHS];	/* read only, no exec */
	int			n_ro;
	const char *rw_dirs[PLZIG_SANDBOX_MAX_PATHS];	/* read + write, no exec */
	int			n_rw;
	uint64		rlimit_cpu;		/* seconds, 0 = unchanged */
	uint64		rlimit_as;		/* bytes, 0 = unchanged */
	uint64		rlimit_fsize;	/* bytes, 0 = unchanged */
} PlzigSandbox;

typedef struct PlzigSpawnResult
{
	int			exit_status;	/* exit code, or -1 if killed by a signal */
	int			term_signal;
	bool		timed_out;
	bool		sandboxed;		/* Landlock was applied in the child */
	int			landlock_abi;
	StringInfoData output;		/* stdout+stderr, first PLZIG_MAX_OUTPUT bytes */
} PlzigSpawnResult;

extern void plzig_spawn(const char *prog, char *const argv[], char *const envp[],
						const char *cwd, const char *stdin_path,
						const PlzigSandbox *sb, int timeout_ms,
						PlzigSpawnResult *res);
extern void plzig_spawn_atexit(void);

extern int	plzig_landlock_probe(void);
extern int	plzig_sandbox_apply_in_child(const PlzigSandbox *sb, int *abi_used,
										 char *errbuf, size_t errlen);

/* ---------------------------------------------------------------------
 * WebAssembly runtime (plzig_runtime.c)
 * ---------------------------------------------------------------------
 */
typedef struct PlzigModule PlzigModule;
typedef struct PlzigInstance PlzigInstance;
typedef struct PlzigCallCtx PlzigCallCtx;

extern PlzigModule *plzig_module_load(const char *wasm, uint32 len);
extern void plzig_module_unload(PlzigModule *mod);
extern PlzigInstance *plzig_instance_create(PlzigModule *mod);
extern void plzig_instance_destroy(PlzigInstance *inst);
extern bool plzig_instance_current(PlzigInstance *inst);

extern Datum plzig_instance_call(PlzigInstance *inst, PlzigTypeInfo *argtypes,
								 int nargs, NullableDatum *args,
								 PlzigTypeInfo *rettype, bool read_only,
								 bool *isnull);

/* ---------------------------------------------------------------------
 * Host imports (plzig_host.c)
 * ---------------------------------------------------------------------
 */
struct PlzigCallCtx
{
	PlzigInstance *inst;
	MemoryContext cxt;			/* per-call context */
	ErrorData  *edata;			/* stashed error from a host import */
	bool		read_only;
	bool		spi_connected;
	void	   *tuptable;		/* SPITupleTable * of the last spi_execute */
	uint64		ntuples;
	/* one-entry cache for spi_value_len/spi_value_copy */
	int64		cached_row;
	int			cached_col;
	char	   *cached_val;
	int			cached_name_col;
	char	   *cached_name;
};

extern void *plzig_host_symbols(int *n);
extern void plzig_host_finish_call(PlzigCallCtx *ctx);

/* runtime helpers used by the host imports */
extern bool plzig_guest_range(void *module_inst, uint32 ptr, uint32 len);
extern void *plzig_guest_ptr(void *module_inst, uint32 ptr, uint32 len);

#endif							/* PLZIG_H */
