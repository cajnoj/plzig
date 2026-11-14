#!/bin/bash
# Build PL/Zig and run its pg_regress suite against each PostgreSQL version.
#
#   docker/run-tests.sh                 # all six versions
#   docker/run-tests.sh 18.7 14.25      # a subset
#
# Environment:
#   PLZIG_PARALLEL=1           build/test versions concurrently
#
# Each version runs twice: the full suite (which needs Landlock, since
# plzig.compiler_sandbox defaults to require), and the no-Landlock checks in
# a container whose seccomp profile blocks the Landlock syscalls.
#
# Prints a per-version PASS/FAIL summary, including whether the compiler was
# Landlock-confined; exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."

versions=("$@")
if [ ${#versions[@]} -eq 0 ]; then
    versions=(14.25 15.20 16.16 17.12 18.7 19rc2)
fi

logdir=build/test-logs
mkdir -p "$logdir"

run_one() {
    local v=$1
    local tag="plzig-test:${v}"
    local log="$logdir/$v.log"
    {
        echo "### building for postgres:${v}-bookworm"
        if ! docker build -f docker/Dockerfile \
                --build-arg "PG_IMAGE=postgres:${v}-bookworm" \
                -t "$tag" . ; then
            echo "RESULT: FAIL (build)"
            echo "NOLANDLOCK: FAIL (build)"
            return 1
        fi
        echo "### testing"
        docker run --rm "$tag"
        echo "### testing without Landlock (seccomp)"
        docker run --rm -e PLZIG_NO_LANDLOCK=1 \
            --security-opt "seccomp=$PWD/docker/seccomp-no-landlock.json" "$tag" |
            sed 's/^RESULT:/NOLANDLOCK:/'
    } >"$log" 2>&1
}

declare -A status
if [ "${PLZIG_PARALLEL:-0}" = 1 ]; then
    declare -A pids
    for v in "${versions[@]}"; do
        run_one "$v" & pids[$v]=$!
    done
    for v in "${versions[@]}"; do
        if wait "${pids[$v]}"; then status[$v]=0; else status[$v]=1; fi
    done
else
    for v in "${versions[@]}"; do
        echo "--- $v ..."
        if run_one "$v"; then status[$v]=0; else status[$v]=1; fi
    done
fi

echo
echo "================ PL/Zig regression summary ================"
fail=0
for v in "${versions[@]}"; do
    log="$logdir/$v.log"
    result=$(grep -a '^RESULT:' "$log" | tail -1)
    nolandlock=$(grep -a '^NOLANDLOCK:' "$log" | tail -1)
    counts=$(grep -aoE '(All [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' "$log" | tail -1)
    [ -z "$result" ] && result="RESULT: FAIL (no result line)"
    [ -z "$nolandlock" ] && nolandlock="NOLANDLOCK: FAIL (no result line)"
    if [ "${status[$v]}" != 0 ] || [[ "$result" != "RESULT: PASS"* ]] ||
       [[ "$nolandlock" != "NOLANDLOCK: PASS"* ]]; then
        fail=1
    fi
    printf '%-8s %s  %s\n' "$v" "${result#RESULT: }" "$counts"
    printf '%-8s no-Landlock run: %s\n' "" "${nolandlock#NOLANDLOCK: }"
done
echo "logs: $logdir/<version>.log"
exit $fail
