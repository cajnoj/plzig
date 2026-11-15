#!/bin/bash
# The package test matrix (doc/packaging.md "Package tests"): for each
# distribution, build the packages twice -- release 0 (the "previous" build
# for the upgrade test) and release 1 (the build under test), both from the
# same source tarball -- then run packaging/test-packages.sh for every
# PostgreSQL major PGDG provides there.
#
#   packaging/test-matrix.sh [distro...]         (default: all of packaging/distros.sh)
#
# Environment:
#   PLZIG_DIST        source tarball (default: make dist; PLZIG_DIST_WORKTREE=1
#                     packs the working tree instead)
#   PLZIG_SKIP_BUILD=1  test existing builds (build/packages/<distro>/r0, r1)
#   PLZIG_NO_UPGRADE=1  build and test without the release-0 build
#   PLZIG_JOBS        parallel builds/tests (default 6)
#   PLZIG_TEST_LOGDIR (default build/package-tests)
#
# Prints a table (also <logdir>/matrix.md): one row per distribution and
# major, one column per step; exits non-zero if anything failed.
set -uo pipefail
cd "$(dirname "$0")/.."
. packaging/distros.sh
distros=("$@")
[ ${#distros[@]} -gt 0 ] || read -r -a distros <<<"$ALL_DISTROS"
jobs=${PLZIG_JOBS:-6}
logdir=${PLZIG_TEST_LOGDIR:-build/package-tests}
export PLZIG_TEST_LOGDIR=$logdir
mkdir -p "$logdir"

if [ -z "${PLZIG_DIST:-}" ]; then
    PLZIG_DIST=$(make -s dist PG_CONFIG=/bin/false DIST_WORKTREE="${PLZIG_DIST_WORKTREE:-0}" | tail -1) || exit 1
fi
export PLZIG_DIST
echo "source: $PLZIG_DIST"

throttle() { while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done; }

declare -A buildrc
if [ "${PLZIG_SKIP_BUILD:-0}" != 1 ]; then
    rels=(1); [ "${PLZIG_NO_UPGRADE:-0}" = 1 ] || rels=(0 1)
    for d in "${distros[@]}"; do
        distro_info "$d" || exit 2
        for r in "${rels[@]}"; do
            throttle
            # lint only the build under test
            ( PLZIG_LINT=$r packaging/build-packages.sh "$d" "$r" >"$logdir/build-$d-r$r.out" 2>&1
              echo $? >"$logdir/build-$d-r$r.rc" ) &
        done
    done
    wait
    for d in "${distros[@]}"; do
        buildrc[$d]=0
        for r in "${rels[@]}"; do
            [ "$(cat "$logdir/build-$d-r$r.rc")" = 0 ] || buildrc[$d]=1
        done
        echo "build $d: $([ "${buildrc[$d]}" = 0 ] && echo ok || echo FAILED) (logs: build/packages/$d/r*/build.log)"
    done
fi

for d in "${distros[@]}"; do
    [ "${buildrc[$d]:-0}" = 0 ] || continue
    distro_info "$d"
    for m in $MAJORS; do
        throttle
        if [ "${PLZIG_NO_UPGRADE:-0}" = 1 ]; then
            ( PLZIG_PREV_DIR="" packaging/test-packages.sh "$d" "$m" >/dev/null 2>&1 ) &
        else
            ( packaging/test-packages.sh "$d" "$m" >/dev/null 2>&1 ) &
        fi
    done
done
wait

steps=(deps install upgrade files sandbox regress sqlupgrade remove)
fail=0
{
    printf '| distribution | PG | build |'; printf ' %s |' "${steps[@]}"; printf ' result |\n'
    printf '|---|---|---|'; printf -- '---|%.0s' "${steps[@]}"; printf -- '---|\n'
    for d in "${distros[@]}"; do
        distro_info "$d"
        for m in $MAJORS; do
            log=$logdir/$d-$m.log
            if [ "${buildrc[$d]:-0}" != 0 ]; then
                printf '| %s | %s | FAIL |' "$d" "$m"; printf ' - |%.0s' "${steps[@]}"; printf ' FAIL |\n'
                fail=1; continue
            fi
            printf '| %s | %s | ok |' "$d" "$m"
            for s in "${steps[@]}"; do
                r=$(grep -a "^STEP $s:" "$log" 2>/dev/null | head -1 | sed 's/^STEP [a-z]*: \([A-Z]*\).*/\1/')
                printf ' %s |' "${r:-?}"
            done
            res=$(grep -a '^RESULT:' "$log" 2>/dev/null | tail -1 | sed 's/^RESULT: //')
            printf ' %s |\n' "${res:-?}"
            [ "$res" = PASS ] || fail=1
        done
    done
} | tee "$logdir/matrix.md"
echo "logs: $logdir/<distro>-<major>.log"
exit $fail
