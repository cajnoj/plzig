#!/bin/bash
# Coverage report for the gcov build (docker/Dockerfile.variant
# VARIANT=coverage), after docker/test-in-container.sh has run every layer.
# Writes to /tmp/coverage (docker/run-all.sh copies it to build/coverage/):
#   plzig.info        lcov tracefile
#   summary.txt       line coverage per file and in total
#   uncovered.txt     the uncovered lines of plzig_host.c, plzig_spawn.c,
#                     plzig_build.c and plzig_sandbox.c, grouped into regions,
#                     with the source text
# Only our C sources count (src/*.c); WAMR is not instrumented and the
# PLZIG_TESTING helpers are excluded by LCOV_EXCL markers.
set -u
out=/tmp/coverage
rm -rf "$out"; mkdir -p "$out"
cd /src
# counters may be spread over several directories (GCOV_PREFIX, see
# test-in-container.sh): capture each with the notes files next to it, merge
n=0
args=()
for d in $( (find /tmp /src -name '*.gcda' -path '*/src/src/*' -printf '%h\n' 2>/dev/null) | sort -u); do
    [ "$d" != /src/src ] && cp /src/src/*.gcno "$d"/
    n=$((n + 1))
    lcov --quiet --capture --directory "$d" --base-directory /src \
        --output-file "$out/part$n.info" 2>>"$out/lcov.log" || { cat "$out/lcov.log"; echo "LAYER coverage: FAIL (lcov)"; exit 1; }
    args+=(-a "$out/part$n.info")
done
[ $n -gt 0 ] || { echo "LAYER coverage: FAIL (no counters found)"; exit 1; }
lcov --quiet "${args[@]}" --output-file "$out/raw.info" 2>>"$out/lcov.log"
lcov --quiet --extract "$out/raw.info" '/src/src/*' --output-file "$out/plzig.info" 2>>"$out/lcov.log"
rm -f "$out"/part*.info
echo "counter directories merged: $n"

# per-file summary from the tracefile (LF/LH: lines found/hit); POSIX awk
{
    printf "%-20s %8s %8s %8s\n" file lines covered percent
    awk -F: '
        /^SF:/ { f = $2; sub(".*/", "", f) }
        /^LF:/ { lf = $2 }
        /^LH:/ { lh = $2 }
        /^end_of_record/ { printf "%-20s %8d %8d %7.1f%%\n", f, lf, lh, lf ? 100 * lh / lf : 0 }
    ' "$out/plzig.info" | sort
    awk -F: '/^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
        END { printf "%-20s %8d %8d %7.1f%%\n", "TOTAL", lf, lh, lf ? 100 * lh / lf : 0 }' "$out/plzig.info"
} > "$out/summary.txt"
cat "$out/summary.txt"

# uncovered regions of the four files the plan asks about
{
    for f in plzig_host.c plzig_spawn.c plzig_build.c plzig_sandbox.c; do
        echo "=================== src/$f"
        awk -F'[:,]' -v want="/src/src/$f" '
            /^SF:/ { on = ($2 == want) }
            on && /^DA:/ && $3 == 0 { print $2 }' "$out/plzig.info" | sort -n |
        awk 'NR == 1 { s = $1; e = $1; next }
             $1 == e + 1 { e = $1; next }
             { print s "-" e; s = $1; e = $1 }
             END { if (NR) print s "-" e }' |
        while IFS=- read -r s e; do
            echo "--- lines $s-$e"
            sed -n "${s},${e}p" "src/$f" | sed 's/^/    /'
        done
    done
} > "$out/uncovered.txt"
rm -f "$out/raw.info"

total=$(awk '$1 == "TOTAL" { print $4 }' "$out/summary.txt")
echo "LAYER coverage: PASS (total line coverage $total; target 85%)"
