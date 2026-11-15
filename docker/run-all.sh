#!/bin/bash
# Every test layer of PL/Zig (PLAN.md section 13 B), in Docker:
#
#   per version (default: all six), image docker/Dockerfile:
#     main         Zig unit tests, pg_regress, security checks, leak checks,
#                  isolation tests, TAP tests (Landlock + seccomp required)
#     no-landlock  checks with the Landlock syscalls blocked
#     no-seccomp   checks with seccomp filters blocked
#     testing      C unit checks against the PLZIG_TESTING=1 build, swapped in
#                  for this one container
#   variants (each on its subset of versions):
#     hardened     PostgreSQL from the vendored source with --enable-cassert
#                  (docker/Dockerfile.hardened): main layers + testing
#     valgrind     cassert + USE_VALGRIND server under Valgrind, pg_regress
#                  subset (PLZIG_VALGRIND_REGRESS)
#     asan         PL/Zig + WAMR with ASan/UBSan, in the cassert server
#                  (the PGDG server cannot run with libasan preloaded)
#     coverage     gcov build, all layers, report in build/coverage/
#     compilers    GCC and Clang, -Wall -Wextra -Werror
#     upgrade      pg_upgrade from PostgreSQL 14 (PGDG) to the version
#     fuzz         every fuzz target of fuzz/ for a short budget
#                  (docker/run-fuzz.sh smoke; PLZIG_FUZZ_SMOKE seconds each)
#     static       scan-build and cppcheck over src/, and the hardening of
#                  the installed binaries (docker/static-analysis.sh)
#     diskfull     compilations with the data directory on a full tmpfs
#                  (docker/diskfull-checks.sh)
#
#   docker/run-all.sh                       # everything
#   PLZIG_VERSIONS="18.7" PLZIG_VARIANTS="asan coverage" docker/run-all.sh
#
# Environment (all optional):
#   PLZIG_VERSIONS     versions for the per-version jobs (default: all six)
#   PLZIG_VARIANTS     which variants to run (default: all; "" = none)
#   PLZIG_HARDENED     versions for "hardened" (default: 14.25 18.7 19rc2)
#   PLZIG_VALGRIND_VERSION, PLZIG_ASAN_VERSION, PLZIG_COVERAGE_VERSION,
#   PLZIG_COMPILERS_VERSION   one version each (default: 18.7)
#   PLZIG_UPGRADE_VERSION     the new major for pg_upgrade (default: 19rc2)
#   PLZIG_FUZZ_VERSION, PLZIG_STATIC_VERSION, PLZIG_DISKFULL_VERSION
#                      one version each (default: 18.7)
#   PLZIG_FUZZ_SMOKE   seconds per fuzz target in the "fuzz" variant (default 60)
#   PLZIG_JOBS         parallel jobs (default: 6)
#   PLZIG_PLATFORM     docker --platform, e.g. linux/arm64 (default: host)
#   PLZIG_LOGDIR       where the job logs go (default: build/test-logs/all)
#
# Logs: build/test-logs/all/<job>.log.  Prints a per-layer, per-version
# summary; exits non-zero if anything failed.
set -u
cd "$(dirname "$0")/.."

all_versions=(14.25 15.20 16.16 17.12 18.7 19rc2)
read -r -a versions <<<"${PLZIG_VERSIONS:-${all_versions[*]}}"
variants=" ${PLZIG_VARIANTS-hardened valgrind asan coverage compilers upgrade fuzz static diskfull} "
read -r -a hardened <<<"${PLZIG_HARDENED:-14.25 18.7 19rc2}"
vg_v=${PLZIG_VALGRIND_VERSION:-18.7}
asan_v=${PLZIG_ASAN_VERSION:-18.7}
cov_v=${PLZIG_COVERAGE_VERSION:-18.7}
cc_v=${PLZIG_COMPILERS_VERSION:-18.7}
up_v=${PLZIG_UPGRADE_VERSION:-19rc2}
fz_v=${PLZIG_FUZZ_VERSION:-18.7}
st_v=${PLZIG_STATIC_VERSION:-18.7}
df_v=${PLZIG_DISKFULL_VERSION:-18.7}
jobs_max=${PLZIG_JOBS:-6}
plat=()
[ -n "${PLZIG_PLATFORM:-}" ] && plat=(--platform "$PLZIG_PLATFORM")

logdir=${PLZIG_LOGDIR:-build/test-logs/all}
rm -rf "$logdir"
mkdir -p "$logdir"
want() { [[ "$variants" == *" $1 "* ]]; }

pgsrc() {   # vendored source tree of a version
    case $1 in
        14.25) echo vendor/pg-REL_14_25 ;; 15.20) echo vendor/pg-REL_15_20 ;;
        16.16) echo vendor/pg-REL_16_16 ;; 17.12) echo vendor/pg-REL_17_12 ;;
        18.7) echo vendor/postgres ;; 19rc2) echo vendor/pg-REL_19_RC2 ;;
        *) echo "no vendored source for $1" >&2; return 1 ;;
    esac
}

# a job: name, command; output to its log, "JOB <name>: <rc> <seconds>" at the end
run_job() {
    local name=$1; shift
    local log="$logdir/$name.log" start=$SECONDS rc
    { "$@"; } >"$log" 2>&1
    rc=$?
    echo "JOB $name: rc=$rc time=$((SECONDS - start))s" >>"$log"
    return $rc
}

declare -a running=()
spawn() {   # spawn <name> <cmd...>: run in the background, at most $jobs_max at once
    while [ "$(jobs -rp | wc -l)" -ge "$jobs_max" ]; do wait -n; done
    run_job "$@" &
}

build_main() {   # plzig-test:<v>
    docker build "${plat[@]}" -f docker/Dockerfile --build-arg "PG_IMAGE=postgres:$1-bookworm" \
        -t "plzig-test:$1" .
}
build_variant() {   # build_variant <variant> <v> [base image, default plzig-test:<v>]
    docker build "${plat[@]}" -f docker/Dockerfile.variant --build-arg "BASE=${3:-plzig-test:$2}" \
        --build-arg "VARIANT=$1" -t "plzig-$1:$2" .
}
build_hardened() {   # build_hardened <tag> <v> <valgrind 0|1>
    docker build "${plat[@]}" -f docker/Dockerfile.hardened --build-context "pgsrc=$(pgsrc "$2")" \
        --build-arg "VALGRIND=$3" -t "$1:$2" .
}
drun() { docker run "${plat[@]}" --rm --init "$@"; }
# run the PLZIG_TESTING build: copy the staged installation over the real one
# (as root, in this throw-away container only), then test as postgres
drun_testing() {
    local image=$1; shift
    drun --user root "$@" "$image" bash -c \
        'cp -a /opt/plzig-testing/. / && exec setpriv --reuid=postgres --regid=postgres --init-groups env HOME=/tmp bash /src/docker/test-in-container.sh'
}

all_layers="unit regress security leaks isolation tap"

job_main() {
    local v=$1
    echo "### main layers"
    drun -e PLZIG_LAYERS="$all_layers" "plzig-test:$v"
    local rc1=$?
    echo "### no-Landlock"
    drun -e PLZIG_NO_LANDLOCK=1 --security-opt "seccomp=$PWD/docker/seccomp-no-landlock.json" "plzig-test:$v" |
        sed 's/^RESULT: \(.*\)$/LAYER no-landlock: \1/'
    local rc2=${PIPESTATUS[0]}
    echo "### no-seccomp"
    drun -e PLZIG_NO_SECCOMP=1 --security-opt "seccomp=$PWD/docker/seccomp-no-seccomp.json" "plzig-test:$v" |
        sed 's/^RESULT: \(.*\)$/LAYER no-seccomp: \1/'
    local rc3=${PIPESTATUS[0]}
    echo "### C unit checks (PLZIG_TESTING build)"
    drun_testing "plzig-test:$v" -e PLZIG_LAYERS=testing
    local rc4=$?
    return $((rc1 | rc2 | rc3 | rc4))
}

job_hardened() {
    local v=$1
    build_hardened plzig-hardened "$v" 0 || { echo "LAYER build: FAIL"; return 1; }
    drun -e PLZIG_LAYERS="$all_layers" "plzig-hardened:$v"
    local rc1=$?
    drun_testing "plzig-hardened:$v" -e PLZIG_LAYERS=testing
    local rc2=$?
    return $((rc1 | rc2))
}

# Valgrind: the regress suite minus the tests that loop tens of thousands of
# times through the interpreter (leaks: 60k+ calls; usage: deep recursion and
# parallel workers) -- impractically slow under Valgrind
vg_regress=${PLZIG_VALGRIND_REGRESS:-setup basics types types_more types_fixed types_numeric types_calendar types_jsonb rows srf triggers xact signatures encoding errors spi spi_prepared spi_cursor sandbox adversarial resources lifecycle}
job_valgrind() {
    local v=$1
    build_hardened plzig-valgrind "$v" 1 || { echo "LAYER build: FAIL"; return 1; }
    drun -e PLZIG_LAYERS=regress -e PLZIG_REGRESS="$vg_regress" -e PLZIG_VALGRIND=1 "plzig-valgrind:$v"
}

# ASan/UBSan: on the server built from source (docker/Dockerfile.hardened),
# not the PGDG one: with libasan preloaded, the PGDG postgres and initdb
# (built with NLS) hang in bindtextdomain() on a glibc rwlock before main()
# does anything (GCC 12 libasan, glibc 2.36); the source build has no NLS.
job_asan() {
    local v=$1
    build_hardened plzig-hardened "$v" 0 || { echo "LAYER build: FAIL"; return 1; }
    build_variant asan "$v" "plzig-hardened:$v" || { echo "LAYER build: FAIL"; return 1; }
    drun -e PLZIG_LAYERS="regress security leaks isolation" -e PLZIG_ASAN=1 "plzig-asan:$v"
}

job_coverage() {
    local v=$1 rc c
    build_variant coverage "$v" || { echo "LAYER build: FAIL"; return 1; }
    c=plzig-coverage-run-$$
    docker rm -f "$c" >/dev/null 2>&1
    docker run "${plat[@]}" --init --name "$c" \
        -e PLZIG_LAYERS="unit regress security leaks isolation tap testing" -e PLZIG_COVERAGE=1 "plzig-coverage:$v"
    rc=$?
    rm -rf build/coverage
    docker cp "$c:/tmp/coverage" build/coverage || rc=1
    docker rm -f "$c" >/dev/null
    return $rc
}

job_compilers() {
    local v=$1
    build_variant compilers "$v" || { echo "LAYER build: FAIL"; return 1; }
    drun "plzig-compilers:$v" bash /src/docker/compiler-checks.sh
}

# the fuzz image (docker/Dockerfile.fuzz) on top of the ASan image, which
# is on top of the cassert server built from source (see job_asan)
build_fuzz_images() {
    local v=$1
    build_hardened plzig-hardened "$v" 0 && build_variant asan "$v" "plzig-hardened:$v" &&
    docker build "${plat[@]}" -f docker/Dockerfile.fuzz --build-arg "BASE=plzig-asan:$v" -t "plzig-fuzz:$v" .
}

job_fuzz() {
    local v=$1 rc
    PLZIG_FUZZ_VERSION=$v PLZIG_FUZZ_NO_BUILD=1 docker/run-fuzz.sh smoke "${PLZIG_FUZZ_SMOKE:-60}" >/tmp/plzig-fuzz-smoke.$$ 2>&1
    rc=$?
    cat /tmp/plzig-fuzz-smoke.$$
    sed -n 's/^FUZZ \([a-z]*\): \(.*\)$/LAYER fuzz-\1: \2/p' /tmp/plzig-fuzz-smoke.$$
    rm -f /tmp/plzig-fuzz-smoke.$$
    return $rc
}

job_static() {
    local v=$1 rc1 rc2
    drun "plzig-fuzz:$v" bash /src/docker/static-analysis.sh analyze
    rc1=$?
    # the hardening as built against the distribution's PostgreSQL (PGDG)
    drun "plzig-test:$v" bash /src/docker/static-analysis.sh hardening
    rc2=$?
    return $((rc1 | rc2))
}

job_diskfull() {
    local v=$1
    drun --tmpfs /tmp/pgdata:rw,size=300m,uid=999,gid=999,mode=0700 \
        -e PLZIG_LAYERS=diskfull "plzig-test:$v"
}

job_upgrade() {
    local v=$1
    build_variant upgrade "$v" || { echo "LAYER build: FAIL"; return 1; }
    drun -e PLZIG_LAYERS=tap -e PLZIG_TAP_TESTS=t/080_upgrade.pl -e PLZIG_PROVE_FLAGS=-v \
        -e PLZIG_UPGRADE_OLD_PREFIX=/usr/lib/postgresql/14 "plzig-upgrade:$v"
}

# ---- phase 1: the per-version images (variants build on them)
echo "--- building images: ${versions[*]}"
need=("${versions[@]}")
for x in "$asan_v" "$cov_v" "$cc_v" "$up_v" "$fz_v" "$st_v" "$df_v"; do
    [[ " ${need[*]} " == *" $x "* ]] || need+=("$x")
done
for v in "${need[@]}"; do spawn "build-$v" build_main "$v"; done
wait
for v in "${need[@]}"; do
    grep -q 'rc=0' "$logdir/build-$v.log" || echo "image build for $v failed: $logdir/build-$v.log"
done

# the fuzz image (needed by "fuzz" and "static") before anything uses it
fuzz_images=()
want fuzz && fuzz_images+=("$fz_v")
want static && [[ " ${fuzz_images[*]} " != *" $st_v "* ]] && fuzz_images+=("$st_v")
for v in "${fuzz_images[@]}"; do spawn "build-fuzz-$v" build_fuzz_images "$v"; done
wait
for v in "${fuzz_images[@]}"; do
    grep -q 'rc=0' "$logdir/build-fuzz-$v.log" || echo "fuzz image build for $v failed: $logdir/build-fuzz-$v.log"
done

# ---- phase 2: everything else
for v in "${versions[@]}"; do spawn "main-$v" job_main "$v"; done
if want hardened; then for v in "${hardened[@]}"; do spawn "hardened-$v" job_hardened "$v"; done; fi
want valgrind && [ -n "$vg_v" ] && spawn "valgrind-$vg_v" job_valgrind "$vg_v"
want asan && [ -n "$asan_v" ] && spawn "asan-$asan_v" job_asan "$asan_v"
want coverage && [ -n "$cov_v" ] && spawn "coverage-$cov_v" job_coverage "$cov_v"
want compilers && [ -n "$cc_v" ] && spawn "compilers-$cc_v" job_compilers "$cc_v"
want upgrade && [ -n "$up_v" ] && spawn "upgrade-14-to-$up_v" job_upgrade "$up_v"
want fuzz && [ -n "$fz_v" ] && spawn "fuzz-$fz_v" job_fuzz "$fz_v"
want static && [ -n "$st_v" ] && spawn "static-$st_v" job_static "$st_v"
want diskfull && [ -n "$df_v" ] && spawn "diskfull-$df_v" job_diskfull "$df_v"
wait

# ---- summary
echo
echo "================ PL/Zig: all test layers ================"
fail=0
for log in "$logdir"/*.log; do
    name=$(basename "$log" .log)
    jobline=$(grep -a '^JOB ' "$log" | tail -1)
    rc=$(sed -n 's/.*rc=\([0-9]*\).*/\1/p' <<<"$jobline")
    t=$(sed -n 's/.*time=\(.*\)$/\1/p' <<<"$jobline")
    [ "${rc:-1}" = 0 ] || fail=1
    if [[ "$name" == build-* ]]; then
        printf '%-26s %-14s %s\n' "$name" image "$([ "${rc:-1}" = 0 ] && echo PASS || echo FAIL) ($t)"
        continue
    fi
    # LAYER lines: those of the container summaries, plus the converted
    # no-Landlock/no-seccomp results
    layers=$(awk '/^=== summary/ { f = 1; next } /^RESULT:/ { f = 0 } f && /^LAYER / { print }
                  /^LAYER (no-landlock|no-seccomp|compilers|static-[a-z]+|fuzz-[a-z]+):/ { print }' "$log" | sort -u)
    if [ -z "$layers" ]; then
        printf '%-26s %-14s %s\n' "$name" "-" "FAIL (no result; see $log)"
        fail=1
        continue
    fi
    while IFS= read -r l; do
        lname=$(sed -n 's/^LAYER \([^:]*\):.*/\1/p' <<<"$l")
        lres=${l#*: }
        printf '%-26s %-14s %s\n' "$name" "$lname" "$lres"
        [[ "$lres" == PASS* ]] || fail=1
    done <<<"$layers"
    printf '%-26s %-14s %s\n' "" "(job)" "rc=$rc, $t"
done
[ -f build/coverage/summary.txt ] && { echo; echo "--- coverage (build/coverage/summary.txt)"; cat build/coverage/summary.txt; }
echo "logs: $logdir/<job>.log"
exit $fail
