/*-------------------------------------------------------------------------
 *
 * harness.c
 *	  libFuzzer target "loader": a module file as a poisoned cache entry
 *	  would deliver it, through the production load path.
 *
 *	  Linked with the unchanged src/plzig_runtime.c, WAMR built with the
 *	  production configuration (third_party/wamr/CMakeLists.txt) and the
 *	  interrupt patch, the PostgreSQL stand-ins of pgshim.c and the host
 *	  import stand-ins of hoststubs.c; ASan + UBSan.  For every input:
 *
 *	    plzig_module_load()      WAMR load + validation, import allowlist,
 *	                             trial instantiation, exports, ABI version
 *	    plzig_instance_create()  instantiate under plzig.max_memory
 *	    plzig_instance_call()    begin / alloc / call with one int argument
 *	                             and copy the result out (int, text or
 *	                             bytea, chosen by the input)
 *
 *	  all under a CPU-time timer that sets QueryCancelPending (the patched
 *	  interpreter polls it, the runtime then runs CHECK_FOR_INTERRUPTS), so
 *	  endless guest loops end as a query-cancel ERROR.  Every ERROR is
 *	  caught the way the call handler catches it.  Findings: any crash,
 *	  sanitizer report, abort (ERROR outside a handler, failed assertion,
 *	  pfree of a foreign pointer), a hang beyond libFuzzer's -timeout, and
 *	  growth of the long-lived "PL/Zig runtime" memory context across
 *	  inputs (a module or instance leaked on some error path).
 *
 *	  A custom mutator keeps the WebAssembly section structure intact most
 *	  of the time (mutate one section's payload and fix its size, drop,
 *	  duplicate or swap sections, splice sections from another input), so
 *	  mutations reach the section decoders and the validator instead of
 *	  dying at the header.
 *
 *	  Not part of PL/Zig: built only by fuzz/build.sh.
 *
 *-------------------------------------------------------------------------
 */
#include "plzig.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "utils/memutils.h"

#include "pgshim.h"

/* CPU time per input before the interrupt flag is raised */
#define FUZZ_INTERRUPT_USEC 20000

static void
on_vtalrm(int sig)
{
	QueryCancelPending = true;
	InterruptPending = true;
}

static void
arm_timer(void)
{
	struct itimerval it;

	memset(&it, 0, sizeof(it));
	it.it_value.tv_usec = FUZZ_INTERRUPT_USEC;
	setitimer(ITIMER_VIRTUAL, &it, NULL);
}

static void
disarm_timer(void)
{
	struct itimerval it;

	memset(&it, 0, sizeof(it));
	setitimer(ITIMER_VIRTUAL, &it, NULL);
	QueryCancelPending = false;
	ProcDiePending = false;
	InterruptPending = false;
}

int			LLVMFuzzerInitialize(int *argc, char ***argv);
int			LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
size_t		LLVMFuzzerCustomMutator(uint8_t *data, size_t size, size_t max_size,
									unsigned int seed);
size_t		LLVMFuzzerCustomCrossOver(const uint8_t *d1, size_t s1,
									  const uint8_t *d2, size_t s2,
									  uint8_t *out, size_t max_out, unsigned int seed);
size_t		LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size);

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	struct sigaction sa;
	const char *mm = getenv("PLZIG_FUZZ_MAX_MEMORY_MB");

	pgshim_init();
	if (mm)
		plzig_max_memory = atoi(mm);
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_vtalrm;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGVTALRM, &sa, NULL);
	return 0;
}

/* runtime context usage after the first input (WAMR's global state) */
static bool baseline_set = false;
static Size baseline_bytes;
static Size baseline_chunks;

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	MemoryContext cxt;
	MemoryContext old;
	PlzigModule *volatile mod = NULL;
	PlzigInstance *volatile inst = NULL;
	PlzigTypeInfo argt;
	PlzigTypeInfo rett;
	NullableDatum arg;
	bool		isnull;
	Size		bytes;
	Size		chunks;
	uint8		sel = size > 0 ? data[size - 1] : 0;

	if (size > 1024 * 1024)
		return -1;

	cxt = AllocSetContextCreate(TopMemoryContext, "fuzz input", ALLOCSET_DEFAULT_SIZES);
	old = MemoryContextSwitchTo(cxt);

	memset(&argt, 0, sizeof(argt));
	argt.typid = INT4OID;
	argt.kind = PLZIG_T_INT4;
	memset(&rett, 0, sizeof(rett));
	/* the result class the host decodes: from the last byte of the input */
	switch (sel % 4)
	{
		case 0:
			rett.typid = INT4OID;
			rett.kind = PLZIG_T_INT4;
			break;
		case 1:
			rett.typid = TEXTOID;
			rett.kind = PLZIG_T_TEXT;
			break;
		case 2:
			rett.typid = BYTEAOID;
			rett.kind = PLZIG_T_BYTEA;
			break;
		default:
			rett.typid = VOIDOID;
			rett.kind = PLZIG_T_VOID;
			break;
	}
	arg.value = Int32GetDatum((int32) (sel >> 2) - 8);
	arg.isnull = false;

	arm_timer();
	PG_TRY();
	{
		mod = plzig_module_load((const char *) data, (uint32) size);
		inst = plzig_instance_create(mod);
		(void) plzig_instance_call(inst, &argt, 1, &arg, &rett, true, &isnull);
		/* a second call reuses the instance, like a cached one */
		(void) plzig_instance_call(inst, &argt, 1, &arg, &rett, true, &isnull);
	}
	PG_CATCH();
	{
		/* as plzig_function_execute: an instance that failed is destroyed */
		error_context_stack = NULL;
	}
	PG_END_TRY();
	disarm_timer();

	if (inst)
		plzig_instance_destroy(inst);
	if (mod)
		plzig_module_unload(mod);

	MemoryContextSwitchTo(old);
	MemoryContextDelete(cxt);

	/* nothing may stay behind in the long-lived runtime context */
	if (pgshim_context_usage("PL/Zig runtime", &bytes, &chunks))
	{
		if (!baseline_set)
		{
			baseline_set = true;
			baseline_bytes = bytes;
			baseline_chunks = chunks;
		}
		else if (bytes != baseline_bytes || chunks != baseline_chunks)
		{
			fprintf(stderr, "loader harness: PL/Zig runtime context changed from %zu bytes in %zu chunks to %zu bytes in %zu chunks (leak)\n",
					baseline_bytes, baseline_chunks, bytes, chunks);
			abort();
		}
	}
	return 0;
}

/* ---------------------------------------------------------------------
 * Structure-aware mutation
 * ---------------------------------------------------------------------
 */
typedef struct Section
{
	size_t		start;			/* offset of the id byte */
	size_t		payload;		/* offset of the payload */
	size_t		len;			/* payload length */
	uint8		id;
} Section;

#define MAX_SECTIONS 64

static bool
read_leb(const uint8_t *d, size_t size, size_t *pos, size_t *val)
{
	size_t		v = 0;
	int			shift = 0;

	while (*pos < size && shift < 35)
	{
		uint8		b = d[(*pos)++];

		v |= (size_t) (b & 0x7f) << shift;
		if (!(b & 0x80))
		{
			*val = v;
			return true;
		}
		shift += 7;
	}
	return false;
}

static int
parse_sections(const uint8_t *d, size_t size, Section *s)
{
	size_t		pos = 8;
	int			n = 0;

	if (size < 8 || memcmp(d, "\0asm", 4) != 0)
		return -1;
	while (pos < size)
	{
		size_t		len;

		if (n == MAX_SECTIONS)
			return -1;
		s[n].start = pos;
		s[n].id = d[pos++];
		if (!read_leb(d, size, &pos, &len) || len > size - pos)
			return -1;
		s[n].payload = pos;
		s[n].len = len;
		pos += len;
		n++;
	}
	return n;
}

static size_t
put_leb(uint8_t *out, size_t v)
{
	size_t		n = 0;

	do
	{
		uint8		b = v & 0x7f;

		v >>= 7;
		if (v)
			b |= 0x80;
		out[n++] = b;
	} while (v);
	return n;
}

/* append one section (id + payload) to out; false if it does not fit */
static bool
emit_section(uint8_t *out, size_t *olen, size_t max, uint8 id,
			 const uint8_t *payload, size_t len)
{
	uint8_t		leb[8];
	size_t		ll = put_leb(leb, len);

	if (*olen + 1 + ll + len > max)
		return false;
	out[(*olen)++] = id;
	memcpy(out + *olen, leb, ll);
	*olen += ll;
	memcpy(out + *olen, payload, len);
	*olen += len;
	return true;
}

static uint8_t scratch[2 * 1024 * 1024];
static uint8_t payload_buf[1024 * 1024];

size_t
LLVMFuzzerCustomMutator(uint8_t *data, size_t size, size_t max_size, unsigned int seed)
{
	Section		s[MAX_SECTIONS];
	int			n = parse_sections(data, size, s);
	unsigned int r = seed;
	size_t		olen = 8;
	int			op;
	int			pick;
	int			i;

	if (max_size > sizeof(scratch))
		max_size = sizeof(scratch);
	r = r * 1103515245u + 12345u;
	op = (r >> 16) % 8;
	if (n <= 0 || op == 0)
		return LLVMFuzzerMutate(data, size, max_size);	/* plain byte mutation */

	r = r * 1103515245u + 12345u;
	pick = (r >> 16) % n;
	memcpy(scratch, data, 8);
	for (i = 0; i < n; i++)
	{
		const uint8_t *p = data + s[i].payload;
		size_t		len = s[i].len;
		bool		ok = true;

		if (i == pick)
		{
			switch (op)
			{
				case 1:
				case 2:
				case 3:			/* mutate the payload, fix the size */
					if (len > sizeof(payload_buf) / 2)
						break;
					memcpy(payload_buf, p, len);
					len = LLVMFuzzerMutate(payload_buf, len, sizeof(payload_buf) / 2 + 64);
					ok = emit_section(scratch, &olen, max_size, s[i].id, payload_buf, len);
					continue;
				case 4:			/* drop it */
					continue;
				case 5:			/* duplicate it */
					ok = emit_section(scratch, &olen, max_size, s[i].id, p, len) &&
						emit_section(scratch, &olen, max_size, s[i].id, p, len);
					if (!ok)
						return LLVMFuzzerMutate(data, size, max_size);
					continue;
				case 6:			/* swap with the next one */
					if (i + 1 < n)
					{
						ok = emit_section(scratch, &olen, max_size, s[i + 1].id,
										  data + s[i + 1].payload, s[i + 1].len) &&
							emit_section(scratch, &olen, max_size, s[i].id, p, len);
						i++;
						if (!ok)
							return LLVMFuzzerMutate(data, size, max_size);
						continue;
					}
					break;
				default:		/* change the section id */
					r = r * 1103515245u + 12345u;
					ok = emit_section(scratch, &olen, max_size, (uint8) ((r >> 16) % 14), p, len);
					if (!ok)
						return LLVMFuzzerMutate(data, size, max_size);
					continue;
			}
		}
		if (!emit_section(scratch, &olen, max_size, s[i].id, p, len))
			return LLVMFuzzerMutate(data, size, max_size);
		(void) ok;
	}
	if (olen > max_size)
		return LLVMFuzzerMutate(data, size, max_size);
	memcpy(data, scratch, olen);
	return olen;
}

/* splice: sections of d1, with one replaced by (or followed by) one of d2 */
size_t
LLVMFuzzerCustomCrossOver(const uint8_t *d1, size_t s1, const uint8_t *d2, size_t s2,
						  uint8_t *out, size_t max_out, unsigned int seed)
{
	Section		a[MAX_SECTIONS];
	Section		b[MAX_SECTIONS];
	int			na = parse_sections(d1, s1, a);
	int			nb = parse_sections(d2, s2, b);
	unsigned int r = seed * 1103515245u + 12345u;
	int			ia;
	int			ib;
	bool		replace;
	size_t		olen = 8;
	int			i;

	if (na <= 0 || nb <= 0 || max_out < 8)
		return 0;
	ia = (r >> 16) % na;
	r = r * 1103515245u + 12345u;
	ib = (r >> 16) % nb;
	replace = ((r >> 8) & 1) != 0;
	memcpy(out, d1, 8);
	for (i = 0; i < na; i++)
	{
		if (i == ia)
		{
			if (!emit_section(out, &olen, max_out, b[ib].id, d2 + b[ib].payload, b[ib].len))
				return 0;
			if (replace)
				continue;
		}
		if (!emit_section(out, &olen, max_out, a[i].id, d1 + a[i].payload, a[i].len))
			return 0;
	}
	return olen;
}
