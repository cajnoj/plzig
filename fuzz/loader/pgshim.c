/*-------------------------------------------------------------------------
 *
 * pgshim.c
 *	  The few PostgreSQL backend services that src/plzig_runtime.c uses,
 *	  reimplemented for the loader fuzz target (fuzz/loader/harness.c), so
 *	  that the production runtime code is linked unchanged, outside a server.
 *
 *	  Not part of PL/Zig: built only by fuzz/build.sh.
 *
 *	  - memory contexts: every chunk is a separate malloc() with a header
 *	    linking it to its context, so ASan sees every overflow and
 *	    use-after-free, and a context can report how much it holds (the
 *	    harness uses that to detect leaks into the long-lived runtime
 *	    context);
 *	  - ereport(ERROR): siglongjmp to PG_exception_stack, as in elog.c; an
 *	    ERROR with no handler, any FATAL/PANIC, and assertion failures abort
 *	    (a finding);
 *	  - interrupts: ProcessInterrupts() raises the query-cancel ERROR, as the
 *	    backend does for QueryCancelPending.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

#include "pgshim.h"

/* ---- globals the runtime references ---- */
sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;
volatile sig_atomic_t InterruptPending = false;
volatile sig_atomic_t QueryCancelPending = false;
volatile sig_atomic_t ProcDiePending = false;
bool		IsUnderPostmaster = true;
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
int			plzig_max_memory = 16;	/* MB; the harness may change it */

/* ---- memory contexts ---- */
typedef struct ShimChunk ShimChunk;
typedef struct ShimContext ShimContext;

struct ShimChunk
{
	ShimContext *cxt;
	ShimChunk  *prev;
	ShimChunk  *next;
	Size		size;
	uint64		magic;
};

#define SHIM_CHUNK_MAGIC UINT64CONST(0x7368696d63686e6b)
#define SHIM_HDR MAXALIGN(sizeof(ShimChunk))

struct ShimContext
{
	char		name[64];
	ShimContext *parent;
	ShimContext *firstchild;
	ShimContext *nextchild;
	ShimChunk  *chunks;
	Size		bytes;
	Size		nchunks;
};

/* total bytes allocated by all contexts: a backstop against runaway inputs */
static Size shim_total = 0;
#define SHIM_TOTAL_LIMIT ((Size) 1536 * 1024 * 1024)

static ShimContext *
cx(MemoryContext c)
{
	return (ShimContext *) c;
}

MemoryContext
AllocSetContextCreateInternal(MemoryContext parent, const char *name,
							  Size minContextSize, Size initBlockSize,
							  Size maxBlockSize)
{
	ShimContext *c = calloc(1, sizeof(ShimContext));

	if (c == NULL)
		abort();
	strncpy(c->name, name, sizeof(c->name) - 1);
	c->parent = cx(parent);
	if (parent)
	{
		c->nextchild = cx(parent)->firstchild;
		cx(parent)->firstchild = c;
	}
	return (MemoryContext) c;
}

static void
shim_free_chunks(ShimContext *c)
{
	while (c->chunks)
	{
		ShimChunk  *ch = c->chunks;

		c->chunks = ch->next;
		shim_total -= ch->size;
		ch->magic = 0;
		free(ch);
	}
	c->bytes = 0;
	c->nchunks = 0;
}

static void
shim_delete_children(ShimContext *c)
{
	while (c->firstchild)
	{
		ShimContext *k = c->firstchild;

		c->firstchild = k->nextchild;
		shim_delete_children(k);
		shim_free_chunks(k);
		free(k);
	}
}

void
MemoryContextReset(MemoryContext context)
{
	shim_delete_children(cx(context));
	shim_free_chunks(cx(context));
}

void
MemoryContextDelete(MemoryContext context)
{
	ShimContext *c = cx(context);
	ShimContext **pp;

	if (c == NULL)
		return;
	shim_delete_children(c);
	shim_free_chunks(c);
	if (c->parent)
	{
		for (pp = &c->parent->firstchild; *pp; pp = &(*pp)->nextchild)
			if (*pp == c)
			{
				*pp = c->nextchild;
				break;
			}
	}
	if (CurrentMemoryContext == context)
		CurrentMemoryContext = (MemoryContext) c->parent;
	free(c);
}

static void *
shim_alloc(MemoryContext context, Size size, int flags)
{
	ShimContext *c = cx(context);
	ShimChunk  *ch;

	if (c == NULL)
		elog(ERROR, "allocation without a memory context");
	if (!(flags & MCXT_ALLOC_HUGE) && !AllocSizeIsValid(size))
		elog(ERROR, "invalid memory alloc request size %zu", size);
	if (size > SHIM_TOTAL_LIMIT || shim_total + size > SHIM_TOTAL_LIMIT)
		ch = NULL;
	else
		ch = (flags & MCXT_ALLOC_ZERO) ? calloc(1, SHIM_HDR + size) : malloc(SHIM_HDR + size);
	if (ch == NULL)
	{
		if (flags & MCXT_ALLOC_NO_OOM)
			return NULL;
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("out of memory")));
	}
	ch->cxt = c;
	ch->prev = NULL;
	ch->next = c->chunks;
	if (c->chunks)
		c->chunks->prev = ch;
	c->chunks = ch;
	ch->size = size;
	ch->magic = SHIM_CHUNK_MAGIC;
	c->bytes += size;
	c->nchunks++;
	shim_total += size;
	return (char *) ch + SHIM_HDR;
}

void *
MemoryContextAllocExtended(MemoryContext context, Size size, int flags)
{
	return shim_alloc(context, size, flags);
}

void *
MemoryContextAlloc(MemoryContext context, Size size)
{
	return shim_alloc(context, size, 0);
}

void *
MemoryContextAllocZero(MemoryContext context, Size size)
{
	return shim_alloc(context, size, MCXT_ALLOC_ZERO);
}

void *
palloc(Size size)
{
	return shim_alloc(CurrentMemoryContext, size, 0);
}

void *
palloc0(Size size)
{
	return shim_alloc(CurrentMemoryContext, size, MCXT_ALLOC_ZERO);
}

void
pfree(void *pointer)
{
	ShimChunk  *ch = (ShimChunk *) ((char *) pointer - SHIM_HDR);
	ShimContext *c;

	if (ch->magic != SHIM_CHUNK_MAGIC)
	{
		fprintf(stderr, "pgshim: pfree of a pointer that is not a live chunk\n");
		abort();
	}
	c = ch->cxt;
	if (ch->prev)
		ch->prev->next = ch->next;
	else
		c->chunks = ch->next;
	if (ch->next)
		ch->next->prev = ch->prev;
	c->bytes -= ch->size;
	c->nchunks--;
	shim_total -= ch->size;
	ch->magic = 0;
	free(ch);
}

/* bytes and chunks held directly by the first context named `name` */
static ShimContext *
shim_find(ShimContext *c, const char *name)
{
	ShimContext *k;

	if (strcmp(c->name, name) == 0)
		return c;
	for (k = c->firstchild; k; k = k->nextchild)
	{
		ShimContext *f = shim_find(k, name);

		if (f)
			return f;
	}
	return NULL;
}

bool
pgshim_context_usage(const char *name, Size *bytes, Size *nchunks)
{
	ShimContext *c = TopMemoryContext ? shim_find(cx(TopMemoryContext), name) : NULL;

	if (c == NULL)
		return false;
	*bytes = c->bytes;
	*nchunks = c->nchunks;
	return true;
}

void
pgshim_init(void)
{
	if (TopMemoryContext == NULL)
		TopMemoryContext = AllocSetContextCreateInternal(NULL, "TopMemoryContext", 0, 0, 0);
	CurrentMemoryContext = TopMemoryContext;
}

/* ---- errors ---- */
static int	shim_elevel;
static int	shim_sqlerrcode;
static char shim_message[1024];

int			pgshim_last_sqlerrcode = 0;
char		pgshim_last_message[1024];

bool
errstart(int elevel, const char *domain)
{
	if (elevel < ERROR)
		return false;			/* NOTICE, LOG, ...: dropped */
	shim_elevel = elevel;
	shim_sqlerrcode = ERRCODE_INTERNAL_ERROR;
	shim_message[0] = '\0';
	return true;
}

bool
errstart_cold(int elevel, const char *domain)
{
	return errstart(elevel, domain);
}

void
errfinish(const char *filename, int lineno, const char *funcname)
{
	pgshim_last_sqlerrcode = shim_sqlerrcode;
	strlcpy(pgshim_last_message, shim_message, sizeof(pgshim_last_message));
	if (shim_elevel >= FATAL || PG_exception_stack == NULL)
	{
		fprintf(stderr, "pgshim: %s outside a handler at %s:%d (%s): %s\n",
				shim_elevel >= FATAL ? "FATAL" : "ERROR", filename, lineno,
				funcname, shim_message);
		abort();
	}
	error_context_stack = NULL;
	siglongjmp(*PG_exception_stack, 1);
}

int
errcode(int sqlerrcode)
{
	shim_sqlerrcode = sqlerrcode;
	return 0;
}

static int
shim_fmt(const char *fmt, va_list ap)
{
	vsnprintf(shim_message, sizeof(shim_message), fmt, ap);
	return 0;
}

int
errmsg(const char *fmt,...)
{
	va_list		ap;

	va_start(ap, fmt);
	shim_fmt(fmt, ap);
	va_end(ap);
	return 0;
}

int
errmsg_internal(const char *fmt,...)
{
	va_list		ap;

	va_start(ap, fmt);
	shim_fmt(fmt, ap);
	va_end(ap);
	return 0;
}

int
errdetail(const char *fmt,...)
{
	return 0;
}

int
errhint(const char *fmt,...)
{
	return 0;
}

void
elog_start(const char *filename, int lineno, const char *funcname)
{
}

void
pg_re_throw(void)
{
	if (PG_exception_stack == NULL)
	{
		fprintf(stderr, "pgshim: re-throw outside a handler\n");
		abort();
	}
	siglongjmp(*PG_exception_stack, 1);
}

void
ReThrowError(ErrorData *edata)
{
	pgshim_last_sqlerrcode = edata ? edata->sqlerrcode : ERRCODE_INTERNAL_ERROR;
	pg_re_throw();
}

void
ExceptionalCondition(const char *conditionName, const char *fileName, int lineNumber)
{
	fprintf(stderr, "pgshim: assertion \"%s\" failed at %s:%d\n",
			conditionName, fileName, lineNumber);
	abort();
}

void
ProcessInterrupts(void)
{
	InterruptPending = false;
	if (ProcDiePending)
	{
		ProcDiePending = false;
		QueryCancelPending = false;
		ereport(ERROR,
				(errcode(ERRCODE_ADMIN_SHUTDOWN),
				 errmsg("terminating connection due to administrator command")));
	}
	if (QueryCancelPending)
	{
		QueryCancelPending = false;
		ereport(ERROR,
				(errcode(ERRCODE_QUERY_CANCELED),
				 errmsg("canceling statement due to statement timeout")));
	}
}

void
check_stack_depth(void)
{
}

/* ---- files ---- */
DIR *
AllocateDir(const char *dirname)
{
	return opendir(dirname);
}

struct dirent *
ReadDirExtended(DIR *dir, const char *dirname, int elevel)
{
	return dir ? readdir(dir) : NULL;
}

int
FreeDir(DIR *dir)
{
	return dir ? closedir(dir) : 0;
}

/* ---- strings, encodings, datums ---- */
char *
pg_any_to_server(const char *s, int len, int encoding)
{
	return (char *) s;
}

/* UTF-8 (the database encoding of every test cluster), no NUL bytes */
bool
pg_verifymbstr(const char *mbstr, int len, bool noError)
{
	const unsigned char *s = (const unsigned char *) mbstr;
	int			i = 0;

	while (i < len)
	{
		int			n;
		int			k;

		if (s[i] == 0)
			goto bad;
		if (s[i] < 0x80)
			n = 1;
		else if ((s[i] & 0xe0) == 0xc0 && s[i] >= 0xc2)
			n = 2;
		else if ((s[i] & 0xf0) == 0xe0)
			n = 3;
		else if ((s[i] & 0xf8) == 0xf0 && s[i] <= 0xf4)
			n = 4;
		else
			goto bad;
		if (i + n > len)
			goto bad;
		for (k = 1; k < n; k++)
			if ((s[i + k] & 0xc0) != 0x80)
				goto bad;
		i += n;
	}
	return true;
bad:
	if (noError)
		return false;
	ereport(ERROR,
			(errcode(ERRCODE_CHARACTER_NOT_IN_REPERTOIRE),
			 errmsg("invalid byte sequence for encoding \"UTF8\"")));
	return false;
}

text *
cstring_to_text_with_len(const char *s, int len)
{
	text	   *t = palloc(len + VARHDRSZ);

	SET_VARSIZE(t, len + VARHDRSZ);
	memcpy(VARDATA(t), s, len);
	return t;
}

struct varlena *
pg_detoast_datum_packed(struct varlena *datum)
{
	return datum;				/* the harness passes plain 4-byte-header values */
}

Datum
InputFunctionCall(FmgrInfo *flinfo, char *str, Oid typioparam, int32 typmod)
{
	fprintf(stderr, "pgshim: InputFunctionCall is not supported\n");
	abort();
}

char *
OutputFunctionCall(FmgrInfo *flinfo, Datum val)
{
	fprintf(stderr, "pgshim: OutputFunctionCall is not supported\n");
	abort();
}

/* port.h maps the printf family to PostgreSQL's own (src/port/snprintf.c) */
#undef vsnprintf
#undef vfprintf

int
pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args)
{
	return vsnprintf(str, count, fmt, args);
}

int
pg_snprintf(char *str, size_t count, const char *fmt,...)
{
	va_list		ap;
	int			n;

	va_start(ap, fmt);
	n = vsnprintf(str, count, fmt, ap);
	va_end(ap);
	return n;
}

int
pg_fprintf(FILE *stream, const char *fmt,...)
{
	va_list		ap;
	int			n;

	va_start(ap, fmt);
	n = vfprintf(stream, fmt, ap);
	va_end(ap);
	return n;
}

size_t
strlcpy(char *dst, const char *src, size_t siz)
{
	size_t		n = strlen(src);

	if (siz > 0)
	{
		size_t		c = n < siz - 1 ? n : siz - 1;

		memcpy(dst, src, c);
		dst[c] = '\0';
	}
	return n;
}
