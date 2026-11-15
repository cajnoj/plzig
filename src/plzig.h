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
#define PLZIG_ABI_VERSION		4
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
#define PLZIG_CURSOR_BATCH		50	/* rows fetched from a portal at a time */
#define PLZIG_MAX_SPI_PARAMS	65535
#define PLZIG_MAX_ROW_SIZE		((uint64) MaxAllocSize)	/* encoded row (doc/abi.md) */
/* bounds for the argument buffer a guest reports from plzig_init (doc/abi.md) */
#define PLZIG_MIN_ARGBUF		16	/* one slot: the result of a call without arguments */
#define PLZIG_MAX_ARGBUF		(1024 * 1024)

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
extern int	plzig_instance_cache_max_memory;	/* kB */
extern int	plzig_max_module_size;	/* kB */
extern int	plzig_cache_size_limit; /* MB */
extern int	plzig_max_prepared_plans;	/* per instance */
extern int	plzig_max_open_cursors; /* per call */

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
	/* fixed-width types: raw values, range-checked on the way back */
	PLZIG_T_DATE,				/* DateADT in val */
	PLZIG_T_TIME,				/* TimeADT in val */
	PLZIG_T_TIMETZ,				/* time in val, zone in len */
	PLZIG_T_TIMESTAMP,			/* Timestamp in val */
	PLZIG_T_TIMESTAMPTZ,		/* TimestampTz in val */
	PLZIG_T_INTERVAL,			/* 16-byte Interval, out of line */
	PLZIG_T_UUID,				/* 16 bytes, out of line */
	PLZIG_T_OID,				/* Oid in val */
	PLZIG_T_NUMERIC,			/* numeric_send wire format, out of line */
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

/*
 * Value kinds of the typed SPI interface (doc/abi.md, "Value"): the kind of
 * a result column is derived by the host from the tuple descriptor; the kind
 * of a prepared-statement parameter is one of KIND_BOOL..KIND_BYTEA, chosen
 * by the guest at prepare time and mapped to a fixed type OID by the host.
 */
#define PLZIG_KIND_NULL		0		/* parameter only: NULL of any type */
#define PLZIG_KIND_BOOL		1
#define PLZIG_KIND_INT2		2
#define PLZIG_KIND_INT4		3
#define PLZIG_KIND_INT8		4
#define PLZIG_KIND_FLOAT4	5
#define PLZIG_KIND_FLOAT8	6
#define PLZIG_KIND_TEXT		7		/* text, varchar, bpchar: the value's bytes */
#define PLZIG_KIND_BYTEA	8
#define PLZIG_KIND_OTHER	9		/* result only: text representation */
#define PLZIG_KIND_DATE		10
#define PLZIG_KIND_TIME		11
#define PLZIG_KIND_TIMETZ	12		/* time in val, zone in len */
#define PLZIG_KIND_TIMESTAMP	13
#define PLZIG_KIND_TIMESTAMPTZ	14
#define PLZIG_KIND_INTERVAL	15		/* 16 bytes, out of line */
#define PLZIG_KIND_UUID		16		/* 16 bytes, out of line */
#define PLZIG_KIND_OID		17
#define PLZIG_KIND_NUMERIC	18		/* wire format (numeric_send), out of line */
#define PLZIG_KIND_MAX		18

/* size of the out-of-line fixed-width values (interval, uuid) */
#define PLZIG_FIXED16		16
/*
 * Largest numeric in the wire format: 8 header bytes and at most 65535
 * base-10000 digits (ndigits is a uint16).
 */
#define PLZIG_MAX_NUMERIC_WIRE	(8 + 2 * 65535)

/* operations of the numeric_op import (doc/abi.md) */
#define PLZIG_NUMERIC_ADD		1
#define PLZIG_NUMERIC_SUB		2
#define PLZIG_NUMERIC_MUL		3
#define PLZIG_NUMERIC_DIV		4
#define PLZIG_NUMERIC_DIV_TRUNC	5
#define PLZIG_NUMERIC_MOD		6
#define PLZIG_NUMERIC_ROUND		7
#define PLZIG_NUMERIC_TRUNC		8
#define PLZIG_NUMERIC_ABS		9
#define PLZIG_NUMERIC_NEG		10
#define PLZIG_NUMERIC_OP_MAX	10

/* Typed value (params of prepared statements, result rows), 16 bytes */
typedef struct PlzigValue
{
	uint64		val;
	uint32		len;
	uint16		kind;
	uint16		is_null;
} PlzigValue;

extern PlzigTypeKind plzig_type_kind(Oid typid);
extern uint16 plzig_value_kind(Oid typid);
extern bool plzig_kind_is_bytes(uint16 kind);
extern PlzigTypeKind plzig_kind_type(uint16 kind);
extern Datum plzig_scalar_from_guest(PlzigTypeKind k, uint64 val, uint32 len,
									 const char *where);
extern void plzig_fixed16_check_len(PlzigTypeKind k, uint32 len, const char *where);
extern Datum plzig_fixed16_from_guest(PlzigTypeKind k, const char *bytes, uint32 len,
									  const char *where);
extern void plzig_numeric_check_len(uint32 len, const char *where);
extern Datum plzig_numeric_from_wire(const char *bytes, uint32 len, const char *where);
extern struct varlena *plzig_numeric_to_wire(Datum num);
extern Oid	plzig_param_kind_oid(uint32 kind);
extern uint16 plzig_param_oid_kind(Oid typid);
extern const char *plzig_zig_type_name(PlzigTypeKind kind, bool for_result);
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
extern char *plzig_get_wasm(const char *src, size_t srclen, uint32 *wasm_len,
							bool use_cache);
extern int64 plzig_cache_clear_files(void);
extern const char *plzig_sandbox_status_string(void);
extern const char *plzig_display_path(const char *path);
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
	int			seccomp;		/* probed in the parent: 0 = available, else
								 * -errno (-ENOSYS: unsupported architecture) */
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
	bool		seccomp;		/* the seccomp filter was installed */
	StringInfoData output;		/* stdout+stderr, first PLZIG_MAX_OUTPUT bytes */
} PlzigSpawnResult;

extern void plzig_spawn(const char *prog, char *const argv[], char *const envp[],
						const char *cwd, const char *stdin_path,
						const PlzigSandbox *sb, int timeout_ms,
						PlzigSpawnResult *res);
extern void plzig_spawn_atexit(void);

/* Landlock ABI that plzig.compiler_sandbox = require insists on */
#define PLZIG_LANDLOCK_MIN_REQUIRED_ABI 6

extern int	plzig_landlock_probe(void);
extern int	plzig_seccomp_probe(void);
extern int	plzig_sandbox_apply_in_child(const PlzigSandbox *sb, int *abi_used,
										 char *errbuf, size_t errlen);
extern int	plzig_seccomp_apply_in_child(const PlzigSandbox *sb,
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
/* Prepared statements of one instance (owned by it, see plzig_host.c) */
typedef struct PlzigPlanEntry PlzigPlanEntry;
typedef struct PlzigPlanTable
{
	PlzigPlanEntry *entries;	/* in the PL/Zig runtime context */
	int			size;			/* allocated entries */
	int			nlive;
} PlzigPlanTable;

extern PlzigInstance *plzig_instance_create(PlzigModule *mod);
extern PlzigPlanTable *plzig_instance_plans(PlzigInstance *inst);
extern MemoryContext plzig_runtime_context(void);
extern void plzig_instance_destroy(PlzigInstance *inst);
extern bool plzig_instance_current(PlzigInstance *inst);
extern uint64 plzig_instance_memory_size(PlzigInstance *inst);

extern Datum plzig_instance_call(PlzigInstance *inst, PlzigTypeInfo *argtypes,
								 int nargs, NullableDatum *args,
								 PlzigTypeInfo *rettype, bool read_only,
								 bool *isnull);

/* ---------------------------------------------------------------------
 * Host imports (plzig_host.c)
 * ---------------------------------------------------------------------
 */
typedef struct PlzigCursor PlzigCursor;
typedef struct PlzigRowBuf PlzigRowBuf;

struct PlzigCallCtx
{
	PlzigInstance *inst;
	MemoryContext cxt;			/* per-call context (the instance's) */
	MemoryContext scratch;		/* reset by every SPI import */
	/*
	 * Where a stashed error is copied: the caller's context.  It must outlive
	 * the instance (destroyed, with cxt, before the error is reported), since
	 * ReThrowError does not copy every string of the ErrorData (filename,
	 * funcname, domain and message_id stay where CopyErrorData put them).
	 */
	MemoryContext errcxt;
	ErrorData  *edata;			/* stashed error from a host import */
	bool		read_only;
	bool		spi_connected;
	void	   *tuptable;		/* SPITupleTable * of the last spi_execute */
	uint64		ntuples;
	PlzigRowBuf *result_row;	/* typed access to the last result */
	PlzigCursor *cursors;		/* per-call cursor table (in cxt) */
	int			ncursors;		/* allocated entries */
	int			nopen;			/* entries in use */
	/* one-entry cache for spi_value_len/spi_value_copy */
	int64		cached_row;
	int			cached_col;
	char	   *cached_val;
	int			cached_name_col;
	char	   *cached_name;
};

extern void *plzig_host_symbols(int *n);
extern void plzig_host_finish_call(PlzigCallCtx *ctx);
extern void plzig_host_free_plans(PlzigPlanTable *plans);

/* runtime helpers used by the host imports */
extern bool plzig_guest_range(void *module_inst, uint32 ptr, uint32 len);
extern void *plzig_guest_ptr(void *module_inst, uint32 ptr, uint32 len);

#endif							/* PLZIG_H */
