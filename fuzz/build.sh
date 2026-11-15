#!/bin/bash
# Build the native fuzz targets of fuzz/ (inside the image of
# docker/Dockerfile.fuzz; needs clang-19 with compiler-rt, cmake, the
# PostgreSQL server headers and Zig 0.17.1 at $PLZIG_TEST_ZIG).
#
#   fuzz/build.sh <outdir>
#
# Produces in <outdir>:
#   fuzz_validator      plzig-validate (zig/validate/main.zig) + differential
#                       checks; Zig with -ffuzz, linked with libFuzzer
#   fuzz_loader         src/plzig_runtime.c + WAMR (production configuration
#                       and interrupt patch) + fuzz/loader stand-ins; libFuzzer
#                       + ASan + UBSan
#   fuzz_loader_cov     the same with source-based coverage instead of the
#                       sanitizers, to measure what a corpus reaches
#   fuzz_jsonb          the guest SDK's jsonb reader and numeric decoders
#                       (zig/sdk/plzig.zig, compiled natively); Zig with
#                       -ffuzz, linked with libFuzzer
# and runs a self-test of each (the seed corpus must pass; the validator's
# differential checks must fire on a denied input in self-test mode).
set -euo pipefail
out=${1:?usage: fuzz/build.sh <outdir>}
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
zig=${PLZIG_TEST_ZIG:-/opt/zig-0.17.1/zig}
cc=${CC_FUZZ:-clang}
work=$(mktemp -d /tmp/plzig-fuzz-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

echo "--- fuzz_validator"
"$zig" build-obj -ffuzz -fno-stack-check -O ReleaseSafe -fPIC \
    --global-cache-dir "$work/zgc" --cache-dir "$work/zlc" \
    --dep validate -Mroot="$here/validator/harness.zig" -Mvalidate="$src/zig/validate/main.zig" \
    --name harness -femit-bin="$work/validator.o"
# the C helpers are not instrumented (fuzz/common/sancov_init.c explains why)
"$cc" -c -O1 "$here/common/sancov_init.c" -o "$work/sancov_init.o"
"$cc" -c -O1 "$here/validator/selftest.c" -o "$work/selftest.o"
"$cc" -fsanitize=fuzzer "$work/validator.o" "$work/sancov_init.o" "$work/selftest.o" \
    -o "$out/fuzz_validator"
(ulimit -s 1048576 2>/dev/null || ulimit -s unlimited 2>/dev/null; "$out/fuzz_validator" -runs=0 "$here/validator/corpus") >"$work/v.log" 2>&1 ||
    { cat "$work/v.log"; echo "fuzz_validator: seed corpus fails"; exit 1; }
grep -q "inline 8-bit counters" "$work/v.log" ||
    { cat "$work/v.log"; echo "fuzz_validator: no coverage counters registered"; exit 1; }
printf 'return @embedFile("x");' >"$work/bad1"
printf 'const s = @import("std"); _ = s;' >"$work/bad2"
printf 'asm volatile ("");' >"$work/bad3"
for b in bad1 bad2 bad3; do
    if PLZIG_FUZZ_SELFTEST=1 "$out/fuzz_validator" "$work/$b" >"$work/$b.log" 2>&1; then
        cat "$work/$b.log"; echo "fuzz_validator: self-test: differential check did not fire on $b"; exit 1
    fi
    grep -q "validator differential finding" "$work/$b.log" ||
        { cat "$work/$b.log"; echo "fuzz_validator: self-test: unexpected failure on $b"; exit 1; }
done
echo "fuzz_validator: ok (seed corpus passes, differential checks fire in self-test mode)"

echo "--- fuzz_jsonb"
"$zig" build-obj -ffuzz -fno-stack-check -O ReleaseSafe -fPIC \
    --global-cache-dir "$work/zgc" --cache-dir "$work/zlc" \
    --dep plzig -Mroot="$here/jsonb/harness.zig" -Mplzig="$src/zig/sdk/plzig.zig" \
    --name jsonb -femit-bin="$work/jsonb.o"
"$cc" -fsanitize=fuzzer "$work/jsonb.o" "$work/sancov_init.o" -o "$out/fuzz_jsonb"
"$out/fuzz_jsonb" -runs=0 "$here/jsonb/corpus" >"$work/j.log" 2>&1 ||
    { cat "$work/j.log"; echo "fuzz_jsonb: seed corpus fails"; exit 1; }
grep -q "inline 8-bit counters" "$work/j.log" ||
    { cat "$work/j.log"; echo "fuzz_jsonb: no coverage counters registered"; exit 1; }
echo "fuzz_jsonb: ok (seed corpus passes)"

echo "--- WAMR (production configuration, clang, sanitizers + coverage)"
wamr_src=$src/build/wamr-src
if [ ! -f "$wamr_src/.stamp" ]; then
    wamr_src=$work/wamr-src
    sh "$src/third_party/prepare-wamr.sh" "$src/vendor/wamr" "$wamr_src" "$src/third_party/wamr-interrupt.patch" >/dev/null
fi
# Alignment checks off in WAMR only: its instance layout puts tables at
# 4-byte offsets (wasm_runtime.c, tables_instantiate); known, reported in
# doc/security.md, harmless on x86_64/aarch64.  Same as the asan variant.
san="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
build_wamr() {   # build_wamr <dir> <cflags>
    cmake -S "$src/third_party/wamr" -B "$1" -DWAMR_ROOT_DIR="$wamr_src" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$cc" -DCMAKE_ASM_COMPILER="$cc" \
        -DCMAKE_C_FLAGS="$2" >/dev/null 2>&1
    cmake --build "$1" -j"$(nproc)" >/dev/null 2>&1
}
# pointer-overflow is recoverable in WAMR so that the known report listed
# in fuzz/loader/ubsan.supp can be suppressed (run with
# UBSAN_OPTIONS=suppressions=...:halt_on_error=1, see docker/run-fuzz.sh).
build_wamr "$work/wamr-asan" "$san -fsanitize-recover=pointer-overflow -fno-sanitize=alignment -fsanitize=fuzzer-no-link -g"
build_wamr "$work/wamr-cov" "-fprofile-instr-generate -fcoverage-mapping -fsanitize=fuzzer-no-link -g"

echo "--- fuzz_loader"
# the stand-in host table must match the production one exactly
extract() { grep -oE '\{"[a-z_]+", \(void \*\) [a-z_A-Z]+, "[^"]*"' "$1" | sed -E 's/\(void \*\) [a-z_A-Z]+, //'; }
if ! diff <(extract "$src/src/plzig_host.c") <(extract "$here/loader/hoststubs.c") >"$work/table.diff"; then
    cat "$work/table.diff"; echo "fuzz/loader/hoststubs.c does not match plzig_native_symbols in src/plzig_host.c"; exit 1
fi
inc="-I$(pg_config --includedir-server) -I$wamr_src/core/iwasm/include -I$src/src -I$here/loader"
defs="-DPLZIG_ZIG_VERSION=\"0.17.1\" -Wno-ignored-attributes -Wno-unused-command-line-argument"
build_loader() {   # build_loader <name> <wamr dir> <cflags>
    local o=$work/$1
    mkdir -p "$o"
    for f in "$src/src/plzig_runtime.c" "$here/loader/pgshim.c" "$here/loader/hoststubs.c" "$here/loader/harness.c"; do
        # shellcheck disable=SC2086
        "$cc" -c -O1 -g $3 $inc $defs "$f" -o "$o/$(basename "$f" .c).o"
    done
    # shellcheck disable=SC2086
    "$cc" $3 -fsanitize=fuzzer "$o"/*.o "$2/libiwasm.a" -lm -o "$out/$1"
}
build_loader fuzz_loader "$work/wamr-asan" "$san -fsanitize=fuzzer-no-link"
build_loader fuzz_loader_cov "$work/wamr-cov" "-fprofile-instr-generate -fcoverage-mapping -fsanitize=fuzzer-no-link"
UBSAN_OPTIONS=suppressions=$here/loader/ubsan.supp:halt_on_error=1:print_stacktrace=1 \
    "$out/fuzz_loader" -runs=0 "$here/loader/corpus" >"$work/l.log" 2>&1 ||
    { cat "$work/l.log"; echo "fuzz_loader: seed corpus fails"; exit 1; }
# regression: every reproducer in fuzz/loader/findings must now pass, fast
UBSAN_OPTIONS=suppressions=$here/loader/ubsan.supp:halt_on_error=1:print_stacktrace=1 \
    "$out/fuzz_loader" -runs=0 -timeout=5 "$here/loader/findings" >"$work/f.log" 2>&1 ||
    { cat "$work/f.log"; echo "fuzz_loader: a reproducer in fuzz/loader/findings fails"; exit 1; }
echo "fuzz_loader: ok (seed corpus and the reproducers in findings/ pass)"
cp "$here/validator/zig.dict" "$out/validator.dict"
cp "$here/loader/wasm.dict" "$out/loader.dict"
cp "$here/jsonb/jsonb.dict" "$out/jsonb.dict"
cp "$here/loader/ubsan.supp" "$out/loader.ubsan.supp"
echo "built into $out"
