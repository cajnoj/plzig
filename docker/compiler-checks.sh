#!/bin/bash
# Build PL/Zig with GCC and with Clang, -Wall -Wextra -Werror, the release
# and the PLZIG_TESTING=1 variant (run in the "compilers" variant image, see
# docker/Dockerfile.variant).  Our own sources only: the server headers are
# passed as a system include directory, so warnings inside them do not count.
#
# Justified exceptions (documented here, nothing else is suppressed):
#   -Wno-unused-parameter   callbacks with fixed signatures (WAMR allocator
#                           and log hooks, syscache and shmem-exit callbacks)
#                           and PG_FUNCTION_ARGS functions that do not look at
#                           fcinfo; PostgreSQL's own build does not enable it
#   Clang only: -Wno-unknown-warning-option -Wno-ignored-optimization-argument
#                           GCC-only flags in the server's CFLAGS (pg_config),
#               -Wno-ignored-attributes
#                           pg_config.h was generated for GCC and spells the
#                           printf attribute gnu_printf
set -u
cd /src
fails=0
work=/tmp/plzig-compilers
for cc in gcc clang; do
    for variant in release testing; do
        rm -rf "$work"; cp -a /src "$work"
        extra=""
        [ "$cc" = clang ] && extra="-Wno-unknown-warning-option -Wno-ignored-optimization-argument -Wno-ignored-attributes"
        t=""; [ $variant = testing ] && t="PLZIG_TESTING=1"
        make -s -C "$work" clean >/dev/null 2>&1
        if make -s -C "$work" -j"$(nproc)" CC=$cc $t ZIG="$PLZIG_TEST_ZIG" WAMR_SRC=/src/vendor/wamr \
                COPT="-Wall -Wextra -Werror -Wno-unused-parameter $extra -isystem $(pg_config --includedir-server)" \
                >"$work.log" 2>&1; then
            echo "  ok   - $cc ($($cc --version | head -1)), $variant: -Wall -Wextra -Werror"
        else
            echo "  FAIL - $cc, $variant"; grep -E 'warning|error' "$work.log" | head -30 | sed 's/^/         /'
            fails=$((fails + 1))
        fi
    done
done
rm -rf "$work" "$work.log"
if [ $fails -eq 0 ]; then echo "LAYER compilers: PASS (gcc, clang x release, testing)"; echo "RESULT: PASS"; exit 0; fi
echo "LAYER compilers: FAIL ($fails build(s))"
echo "RESULT: FAIL"
exit 1
