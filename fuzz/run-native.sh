#!/bin/bash
# Run a native (libFuzzer) fuzz target for a time budget, inside the image of
# docker/Dockerfile.fuzz (targets prebuilt in /opt/plzig-fuzz by
# fuzz/build.sh).  Called by docker/run-fuzz.sh.
#
#   fuzz/run-native.sh <validator|loader|jsonb> <seconds> <outdir> [<previous corpus dir>]
#
# Writes to <outdir>: corpus/ (the seed corpus, plus a previous corpus if
# given, plus everything new), artifacts/ (crash-*, leak-*, timeout-*,
# oom-*: findings; slow-unit-*: an input that merely took long, kept for
# triage but not a finding), fuzz.log, and for the loader a coverage report
# (coverage.txt) of a replay of the final corpus.  Prints "FUZZ <target>:
# PASS|FAIL (...)" and exits non-zero on a finding.
#
# Environment: PLZIG_FUZZ_JOBS (parallel libFuzzer processes, -fork=N;
# default 1), PLZIG_FUZZ_BIN (default /opt/plzig-fuzz).
set -u
target=${1:?target}
secs=${2:?seconds}
out=${3:?outdir}
prev=${4:-}
bin=${PLZIG_FUZZ_BIN:-/opt/plzig-fuzz}
jobs=${PLZIG_FUZZ_JOBS:-1}
here=$(cd "$(dirname "$0")" && pwd)

case $target in
    validator) maxlen=16384; seeds=$here/validator/corpus ;;
    loader) maxlen=262144; seeds=$here/loader/corpus ;;   # findings/ are replayed by fuzz/build.sh
    jsonb) maxlen=65536; seeds=$here/jsonb/corpus ;;
    *) echo "unknown native target $target" >&2; exit 2 ;;
esac
mkdir -p "$out/corpus" "$out/artifacts"
cp -n "$seeds"/* "$out/corpus/" 2>/dev/null
[ -n "$prev" ] && [ -d "$prev" ] && cp -n "$prev"/* "$out/corpus/" 2>/dev/null

export ASAN_OPTIONS=detect_leaks=1:abort_on_error=0:symbolize=1
export UBSAN_OPTIONS=suppressions=$bin/loader.ubsan.supp:halt_on_error=1:print_stacktrace=1
# The validator target's oracle is Zig's recursive-descent parser: its stack
# use grows with the nesting depth of the input (about 3 kB per level in this
# build), so 16 kB of "(" overflows the default 8 MB stack.  That is a limit
# of the oracle, not a finding: give it room for the deepest -max_len input.
ulimit -s 1048576 2>/dev/null || ulimit -s unlimited 2>/dev/null ||
    echo "warning: could not raise the stack limit (now $(ulimit -s) kB)" >&2
mode=()
[ "$jobs" -gt 1 ] && mode=(-fork="$jobs")
start=$(date +%s)
"$bin/fuzz_$target" "${mode[@]}" -max_total_time="$secs" -timeout=20 -rss_limit_mb=4096 \
    -max_len="$maxlen" -dict="$bin/$target.dict" -print_final_stats=1 \
    -artifact_prefix="$out/artifacts/" "$out/corpus" >"$out/fuzz.log" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))

# executions: the last status line (fork mode: "#N: cov: ..."; otherwise
# stat::number_of_executed_units)
execs=$(grep -aoE '^stat::number_of_executed_units: [0-9]+' "$out/fuzz.log" | awk '{ s += $2 } END { print s + 0 }')
[ "$execs" = 0 ] && execs=$(grep -aoE '^#[0-9]+' "$out/fuzz.log" | tail -1 | tr -d '#')
cov=$(grep -aoE 'cov: [0-9]+' "$out/fuzz.log" | tail -1 | awk '{ print $2 }')
[ "$target" != loader ] && cov=""   # no PC table for the Zig targets (fuzz/README.md)
ft=$(grep -aoE 'ft: [0-9]+' "$out/fuzz.log" | tail -1 | awk '{ print $2 }')
counters=$(sed -n 's/.*(\([0-9]*\) inline 8-bit counters).*/\1/p' "$out/fuzz.log" | head -1)
ncorp=$(find "$out/corpus" -type f | wc -l)
# libFuzzer writes crash-/leak-/timeout-/oom-* for findings, and slow-unit-*
# for an input that only took long (informational: the process still exits
# 0).  Only the former count as findings; slow units are kept and reported.
nart=$(find "$out/artifacts" -type f ! -name 'slow-unit-*' | wc -l)
nslow=$(find "$out/artifacts" -type f -name 'slow-unit-*' | wc -l)
slownote=""
[ "$nslow" -gt 0 ] && slownote=", $nslow slow unit(s)"
# cov: counters hit (only reported with a PC table, i.e. not for the Zig
# target), ft: libFuzzer features (counters x hit-count buckets)
summary="${elapsed}s, ${execs:-?} executions, coverage ${cov:-n/a} of ${counters:-?} counters, ${ft:-?} features, corpus $ncorp files, jobs $jobs$slownote"

if [ "$target" = loader ] && [ -x "$bin/fuzz_loader_cov" ]; then
    # source coverage of the final corpus: plzig_runtime.c and WAMR's loader,
    # instantiation and interpreter
    rm -rf "$out/profraw"; mkdir -p "$out/profraw"
    LLVM_PROFILE_FILE="$out/profraw/%p.profraw" "$bin/fuzz_loader_cov" -runs=0 "$out/corpus" >/dev/null 2>&1
    if llvm-profdata merge -sparse "$out/profraw"/*.profraw -o "$out/loader.profdata" 2>/dev/null; then
        llvm-cov report "$bin/fuzz_loader_cov" -instr-profile="$out/loader.profdata" \
            -ignore-filename-regex='(fuzz/|/usr/)' >"$out/coverage.txt" 2>/dev/null
        grep -E 'plzig_runtime.c|wasm_loader.c|wasm_runtime.c|wasm_interp_classic.c|TOTAL' "$out/coverage.txt" |
            awk '{ n = split($1, a, "/"); printf "  coverage %-28s regions %7s  lines %7s\n", a[n], $4, $10 }' > "$out/coverage-summary.txt"
    fi
    rm -rf "$out/profraw"
fi

echo "--- $target: $summary"
[ -f "$out/coverage-summary.txt" ] && cat "$out/coverage-summary.txt"
if [ "$nart" -gt 0 ] || { [ $rc -ne 0 ] && grep -qaE 'ERROR: (libFuzzer|AddressSanitizer|LeakSanitizer)|runtime error|deadly signal|SUMMARY:' "$out/fuzz.log"; }; then
    grep -aE -A30 'ERROR: |runtime error|==ERROR|deadly signal' "$out/fuzz.log" | head -60
    ls -la "$out/artifacts"
    echo "FUZZ $target: FAIL ($nart artifact(s); $summary)"
    exit 1
fi
if [ $rc -ne 0 ]; then
    tail -30 "$out/fuzz.log"
    echo "FUZZ $target: FAIL (libFuzzer exit status $rc; $summary)"
    exit 1
fi
if [ "$nslow" -gt 0 ]; then
    echo "note: $nslow slow unit(s) kept in $out/artifacts (took >10s to run, not a finding); replay with $bin/fuzz_$target <file> to characterise"
    ls -la "$out"/artifacts/slow-unit-* 2>/dev/null
fi
echo "FUZZ $target: PASS ($summary)"
exit 0
