#!/bin/bash
# Variation of the compute tasks (2 and 5): run to run, between CPU cores,
# and between builds of plzig.so whose code is placed differently.  Docker
# only, like bench/run.sh; not part of the normal benchmark.  The findings
# are in doc/benchmarks.md (*How much the numbers vary*).
#
#   bench/variation.sh --out build/bench/var-cores --cpus "2 8 12 20 0-11 any" --perf
#   bench/variation.sh --out build/bench/var-pads  --pads "0 16 32 48 64 4096" --perf
#   bench/variation.sh --summarize build/bench/var-pads
#
# Options:
#   --image IMG      benchmark image (default plzig-bench:18.7, as built by
#                    bench/run.sh; any image built by bench/Dockerfile works)
#   --label NAME     name of the build in the output (default: the image tag)
#   --pads "N ..."   for each N: relink plzig.so in the container with N bytes
#                    of never-executed code in front of all other code (same
#                    objects, same flags; only addresses change) and measure
#                    that; `none` (default) measures the installed plzig.so
#   --wamr-cflags F  with --pads N: compile WAMR again in the container with
#                    the additional C flags F first (an experiment: the
#                    product is not built this way)
#   --cpus "S ..."   CPU settings the backend is pinned to, one after the
#                    other: a CPU number, a list (0-11) or `any` (default "2")
#   --rounds N       rounds over all CPU settings (default 3)
#   --runs N         timed executions per session (default 7; --warmup 2)
#   --perf           count user-space cycles, instructions, branches and
#                    branch misses of the backend (perf stat)
#   --frontend       --perf plus four front-end events of Intel performance
#                    cores (uops from the decoded-uop cache and from the
#                    legacy decoders, switch penalty cycles, resteers)
#   --out DIR        results: DIR/<label>[-padN]/{timings.csv,perf.csv,build.json}
#   --summarize DIR  print the medians and counters of every run below DIR
#
# The container runs as root with CAP_PERFMON, CAP_SYS_PTRACE and
# CAP_SYS_NICE, seccomp=unconfined and SELinux labels disabled (perf and
# pinning another user's process need them); the server runs as postgres.
# Nothing is changed on the host: no sysctl, no governor.
set -euo pipefail
cd "$(dirname "$0")/.."

image="plzig-bench:18.7"
label=""
pads="none"
cpus="2"
rounds=3
runs=7
warmup=2
perf=0
wamr_cflags=""
frontend=0
out=""
summarize=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --pads) pads="$2"; shift 2 ;;
        --cpus) cpus="$2"; shift 2 ;;
        --rounds) rounds="$2"; shift 2 ;;
        --runs) runs="$2"; shift 2 ;;
        --warmup) warmup="$2"; shift 2 ;;
        --wamr-cflags) wamr_cflags="$2"; shift 2 ;;
        --perf) perf=1; shift ;;
        --frontend) perf=1; frontend=1; shift ;;
        --out) out="$2"; shift 2 ;;
        --summarize) summarize="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

c="plzig-variation-$$"
trap 'docker rm -f "$c" >/dev/null 2>&1 || true' EXIT

if [ -n "$summarize" ]; then
    docker create --name "$c" "$image" python3 /bench/variation.py --summarize /tmp/in >/dev/null
    docker cp bench/. "$c:/bench"
    docker cp "$summarize/." "$c:/tmp/in"
    docker start -a "$c"
    exit 0
fi

[ -n "$out" ] || { echo "--out DIR is required" >&2; exit 2; }
[ -n "$label" ] || label="${image##*:}"
mkdir -p "$out"
for pad in $pads; do
    l="$label"; pargs=()
    if [ "$pad" != none ]; then l="$label-pad$pad"; pargs=(--pad "$pad"); fi
    args=(--out /tmp/out --label "$l" --cpus "$cpus" --rounds "$rounds" --runs "$runs"
          --warmup "$warmup" "${pargs[@]}")
    [ -n "$wamr_cflags" ] && args+=("--wamr-cflags=$wamr_cflags")
    [ $perf = 1 ] && args+=(--perf)
    [ $frontend = 1 ] && args+=(--frontend)
    docker create --name "$c" --init --shm-size=1g --user root \
        --cap-add PERFMON --cap-add SYS_PTRACE --cap-add SYS_NICE \
        --security-opt seccomp=unconfined --security-opt label=disable \
        "$image" python3 /bench/variation.py "${args[@]}" >/dev/null
    docker cp bench/. "$c:/bench"
    rc=0
    docker start -a "$c" || rc=$?
    mkdir -p "$out/$l"
    docker cp "$c:/tmp/out/." "$out/$l/" 2>/dev/null || true
    docker rm "$c" >/dev/null
    [ $rc = 0 ] || { echo "FAIL: $l (exit $rc)" >&2; exit 1; }
done
echo "results: $out"
