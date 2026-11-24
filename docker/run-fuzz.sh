#!/bin/bash
# Run one fuzz target of fuzz/ for a time budget, in Docker.
#
#   docker/run-fuzz.sh <target> <seconds>
#   docker/run-fuzz.sh smoke [<seconds per target>]     every target, 60 s each
#
# Targets (fuzz/README.md):
#   validator  plzig-validate, raw bytes + Zig token dictionary, differential
#              check against an independent lexer and the real parser
#   loader     the module load path (src/plzig_runtime.c + WAMR) on hostile
#              module files, ASan/UBSan
#   hostabi    random host-import call sequences against a live ASan server
#   marshal    random values of every supported type and NULL patterns
#              through identity functions; random signatures and argument
#              names through the source generator
#   pipeline   mutated and generated Zig bodies through CREATE FUNCTION on
#              the ASan server
#   jsonb      the guest SDK's jsonb reader and numeric decoders, natively,
#              on mutated jsonb/numeric bytes that PostgreSQL produced
#
# Exits non-zero on a finding (or if the run could not be done).  Results
# go to build/fuzz/<target>/ (fuzz.log, corpus, artifacts, coverage); a
# corpus left there by an earlier run is used as additional seeds.
#
# Environment:
#   PLZIG_FUZZ_VERSION   PostgreSQL version of the images (default 18.7)
#   PLZIG_FUZZ_JOBS      parallel fuzzing processes for the native targets
#                        (libFuzzer -fork; default 1)
#   PLZIG_FUZZ_NO_BUILD=1  use the existing plzig-fuzz:<version> image
#   PLZIG_PLATFORM       docker --platform
set -u
cd "$(dirname "$0")/.."
target=${1:?usage: docker/run-fuzz.sh <target> <seconds> | smoke [<seconds>]}
secs=${2:-60}
v=${PLZIG_FUZZ_VERSION:-18.7}
plat=()
[ -n "${PLZIG_PLATFORM:-}" ] && plat=(--platform "$PLZIG_PLATFORM")
all_targets="validator loader jsonb hostabi marshal pipeline"

pgsrc() {
    case $1 in
        15.20) echo vendor/pg-REL_15_20 ;;
        16.16) echo vendor/pg-REL_16_16 ;; 17.12) echo vendor/pg-REL_17_12 ;;
        18.7) echo vendor/postgres ;; 19.0) echo vendor/pg-REL_19_0 ;;
        *) echo "no vendored source for $1" >&2; return 1 ;;
    esac
}

build_images() {
    # the server must be the cassert build from source for ASan (see
    # docker/run-all.sh, job_asan); the fuzz image adds clang/libFuzzer
    docker build "${plat[@]}" -q -f docker/Dockerfile --build-arg "PG_IMAGE=postgres:$v-bookworm" \
        -t "plzig-test:$v" . >/dev/null &&
    docker build "${plat[@]}" -q -f docker/Dockerfile.hardened --build-context "pgsrc=$(pgsrc "$v")" \
        --build-arg VALGRIND=0 -t "plzig-hardened:$v" . >/dev/null &&
    docker build "${plat[@]}" -q -f docker/Dockerfile.variant --build-arg "BASE=plzig-hardened:$v" \
        --build-arg VARIANT=asan -t "plzig-asan:$v" . >/dev/null &&
    docker build "${plat[@]}" -q -f docker/Dockerfile.fuzz --build-arg "BASE=plzig-asan:$v" \
        -t "plzig-fuzz:$v" . >/dev/null
}

run_one() {   # run_one <target> <seconds>
    local t=$1 s=$2 c rc dest
    dest=build/fuzz/$t
    c=plzig-fuzz-run-$t-$$
    docker rm -f "$c" >/dev/null 2>&1
    # forward a fixed seed so a finding can be replayed (fuzz/README.md); the
    # SQL targets use it (fz_seed), the native ones ignore it
    seedenv=()
    [ -n "${PLZIG_FUZZ_SEED:-}" ] && seedenv=(-e PLZIG_FUZZ_SEED="$PLZIG_FUZZ_SEED")
    case $t in
        validator|loader|jsonb)
            docker create "${plat[@]}" --init --name "$c" -e PLZIG_FUZZ_JOBS="${PLZIG_FUZZ_JOBS:-1}" \
                "${seedenv[@]}" \
                "plzig-fuzz:$v" bash /src/fuzz/run-native.sh "$t" "$s" /tmp/fuzz-out /tmp/fuzz-prev >/dev/null ;;
        hostabi|marshal|pipeline)
            docker create "${plat[@]}" --init --name "$c" -e PLZIG_LAYERS=fuzz -e PLZIG_ASAN=1 \
                -e PLZIG_FUZZ_TARGET="$t" -e PLZIG_FUZZ_SECONDS="$s" -e PLZIG_FUZZ_OUT=/tmp/fuzz-out \
                "${seedenv[@]}" \
                "plzig-fuzz:$v" >/dev/null ;;
        *) echo "unknown target $t"; return 2 ;;
    esac || { echo "FUZZ $t: FAIL (could not create the container)"; return 1; }
    if [ -d "$dest/corpus" ]; then
        docker cp "$dest/corpus" "$c:/tmp/fuzz-prev" >/dev/null 2>&1
    fi
    docker start -a "$c"
    rc=$?
    rm -rf "$dest.new"
    if docker cp "$c:/tmp/fuzz-out" "$dest.new" >/dev/null 2>&1; then
        rm -rf "$dest"; mv "$dest.new" "$dest"
    fi
    docker rm -f "$c" >/dev/null 2>&1
    return $rc
}

mkdir -p build/fuzz
if [ "${PLZIG_FUZZ_NO_BUILD:-0}" != 1 ]; then
    echo "--- building images for $v"
    build_images || { echo "FUZZ $target: FAIL (image build)"; exit 1; }
fi

if [ "$target" = smoke ]; then
    fail=0
    for t in $all_targets; do
        run_one "$t" "$secs" >"build/fuzz/$t.smoke.log" 2>&1
        rc=$?
        grep -aE '^(FUZZ |FINDING|--- |  coverage)' "build/fuzz/$t.smoke.log"
        grep -qa "^FUZZ $t: " "build/fuzz/$t.smoke.log" ||
            { tail -20 "build/fuzz/$t.smoke.log"; echo "FUZZ $t: FAIL (no result, see build/fuzz/$t.smoke.log)"; }
        [ $rc = 0 ] || fail=1
    done
    if [ $fail = 0 ]; then echo "RESULT: PASS (fuzz smoke, ${secs}s per target)"; else echo "RESULT: FAIL (fuzz smoke)"; fi
    exit $fail
fi
run_one "$target" "$secs"
