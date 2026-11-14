/* fuzz/loader/pgshim.c: helpers for the loader harness (not part of PL/Zig) */
#ifndef PLZIG_FUZZ_PGSHIM_H
#define PLZIG_FUZZ_PGSHIM_H

extern void pgshim_init(void);
extern bool pgshim_context_usage(const char *name, Size *bytes, Size *nchunks);
extern bool pgshim_context_descendants(const char *name, Size *n);
extern int	pgshim_last_sqlerrcode;
extern char pgshim_last_message[1024];

#endif
