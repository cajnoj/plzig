#!/bin/bash
# The fast matrix: build PL/Zig and run its quick test layers against each
# PostgreSQL version.  (Everything else -- isolation, TAP, C unit checks,
# hardened/Valgrind/sanitizer/coverage/compiler/upgrade runs -- is in
# docker/run-all.sh.)
#
#   docker/run-tests.sh                 # all six versions
#   docker/run-tests.sh 18.7 15.20      # a subset
#
# Environment:
#   PLZIG_PARALLEL=1           build/test versions concurrently
#   PLZIG_PLATFORM=linux/arm64 docker --platform (default: the host's)
#
# Each version runs three times: the default layers of
# docker/test-in-container.sh (Zig unit tests, the pg_regress suite, the
# security checks, leak checks; these need Landlock and the seccomp filter,
# since plzig.compiler_sandbox defaults to require), the no-Landlock checks
# in a container whose seccomp profile blocks the Landlock syscalls, and the
# no-seccomp checks in a container whose profile makes installing a seccomp
# filter fail.
#
# Prints a per-version PASS/FAIL summary, including whether the compiler was
# Landlock-confined; exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."

versions=("$@")
if [ ${#versions[@]} -eq 0 ]; then
    versions=(15.20 16.16 17.12 18.7 19.0)
fi

logdir=build/test-logs
mkdir -p "$logdir"
plat=()
[ -n "${PLZIG_PLATFORM:-}" ] && plat=(--platform "$PLZIG_PLATFORM")

run_one() {
    local v=$1
    local tag="plzig-test:${v}"
    local log="$logdir/$v.log"
    {
        echo "### building for postgres:${v}-bookworm"
        if ! docker build "${plat[@]}" -f docker/Dockerfile \
                --build-arg "PG_IMAGE=postgres:${v}-bookworm" \
                -t "$tag" . ; then
            echo "RESULT: FAIL (build)"
            echo "NOLANDLOCK: FAIL (build)"
            echo "NOSECCOMP: FAIL (build)"
            return 1
        fi
        echo "### testing"
        docker run "${plat[@]}" --rm --init "$tag"
        echo "### testing without Landlock (seccomp)"
        docker run "${plat[@]}" --rm --init -e PLZIG_NO_LANDLOCK=1 \
            --security-opt "seccomp=$PWD/docker/seccomp-no-landlock.json" "$tag" |
            sed 's/^RESULT:/NOLANDLOCK:/'
        echo "### testing without seccomp filters"
        docker run "${plat[@]}" --rm --init -e PLZIG_NO_SECCOMP=1 \
            --security-opt "seccomp=$PWD/docker/seccomp-no-seccomp.json" "$tag" |
            sed 's/^RESULT:/NOSECCOMP:/'
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
    noseccomp=$(grep -a '^NOSECCOMP:' "$log" | tail -1)
    counts=$(grep -aoE '(All [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' "$log" | tail -1)
    [ -z "$result" ] && result="RESULT: FAIL (no result line)"
    [ -z "$nolandlock" ] && nolandlock="NOLANDLOCK: FAIL (no result line)"
    [ -z "$noseccomp" ] && noseccomp="NOSECCOMP: FAIL (no result line)"
    if [ "${status[$v]}" != 0 ] || [[ "$result" != "RESULT: PASS"* ]] ||
       [[ "$nolandlock" != "NOLANDLOCK: PASS"* ]] ||
       [[ "$noseccomp" != "NOSECCOMP: PASS"* ]]; then
        fail=1
    fi
    printf '%-8s %s  %s\n' "$v" "${result#RESULT: }" "$counts"
    awk '/^=== summary/ { f = 1; next } f && /^LAYER / { sub(/^LAYER /, "         "); print }' "$log"
    printf '%-8s no-Landlock run: %s\n' "" "${nolandlock#NOLANDLOCK: }"
    printf '%-8s no-seccomp run: %s\n' "" "${noseccomp#NOSECCOMP: }"
done
echo "logs: $logdir/<version>.log"
exit $fail
