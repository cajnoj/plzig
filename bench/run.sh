#!/bin/bash
# PL/Zig benchmark suite: one command, Docker only.
#
#   bench/run.sh                         # PG 18.7, full size, report in the run directory
#   bench/run.sh --quick                 # small sizes, few runs (a smoke test, minutes)
#   bench/run.sh --versions "18.7 14.25 19rc2" --tasks 1,7,10
#   bench/run.sh --publish ...           # also write doc/benchmarks.md and doc/benchmarks/
#   bench/run.sh --report-only DIR [--publish]   # regenerate the report from a run directory
#
# Options:
#   --versions "V ..."   PostgreSQL versions (postgres:<V>-bookworm), default 18.7;
#                        the first one is the primary version of the report
#   --quick              small data, 1 warm-up + 5 timed runs, 3 s pgbench, JIT off only
#   --tasks LIST         comma-separated task numbers 1..13 (default: all)
#   --jit LIST           off,on (default; quick: off)
#   --warmup N --runs N  per task and implementation (default 3 and 15)
#   --clients LIST       pgbench client counts (default 1,4,8; empty: no pgbench)
#   --pgbench-seconds N  (default 15)
#   --cpus LIST          docker --cpuset-cpus for the benchmark container
#   --out DIR            run directory (default build/bench/<timestamp>)
#   --no-build           use the existing plzig-test:<V> images
#   --history DIR        a directory of labelled run directories (1-head, 2-...;
#                        optional DIR/README with "label: description" lines);
#                        the report shows their task 10 side by side
#   --call-history DIR   the same for runs of tasks 1, 7 and 8 with pgbench
#                        (shown as the per-call/per-row before-and-after table)
#   --publish            write the report to doc/benchmarks.md + doc/benchmarks/
#   --profile "QUERY"    instead of benchmarking: set up as usual (with --tasks
#                        to create only those functions), then perf-profile one
#                        backend running QUERY (--runs times), user-space cycles
#                        only (bench/profile-in-container.sh).  perf needs the
#                        container to run as root with CAP_PERFMON/SYS_PTRACE,
#                        seccomp=unconfined and label=disable (SELinux) -- this
#                        mode only.  Output: <out>/<V>/perf-report.txt
#
# What it does, per version: builds plzig-test:<V> from docker/Dockerfile (the
# normal test image), then plzig-bench:<V> from bench/Dockerfile (adds
# PL/Python and PL/Perl: benchmark-only), copies bench/ into a container
# named plzig-bench-<V>-<pid> and runs bench/driver.py there (throw-away
# cluster, correctness gate, timings, pgbench, start-up, memory), copies the
# CSV files out to <out>/<V>/ and removes the container.  Then bench/report.py
# renders the report (Markdown + SVG charts) in another such container.
# Nothing is mounted from the host and nothing is installed on it.
#
# Exit status is non-zero if a build, a run or a correctness gate fails.
set -euo pipefail
cd "$(dirname "$0")/.."

versions="18.7"
quick=0
tasks=""
jit=""
warmup=""
runs=""
clients="1,4,8"
pgsecs=""
cpus=""
out=""
build=1
history=""
call_history=""
publish=0
report_only=""
profile=""

while [ $# -gt 0 ]; do
    case "$1" in
        --versions) versions="$2"; shift 2 ;;
        --quick) quick=1; shift ;;
        --tasks) tasks="$2"; shift 2 ;;
        --jit) jit="$2"; shift 2 ;;
        --warmup) warmup="$2"; shift 2 ;;
        --runs) runs="$2"; shift 2 ;;
        --clients) clients="$2"; shift 2 ;;
        --pgbench-seconds) pgsecs="$2"; shift 2 ;;
        --cpus) cpus="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --no-build) build=0; shift ;;
        --history) history="$2"; shift 2 ;;
        --call-history) call_history="$2"; shift 2 ;;
        --publish) publish=1; shift ;;
        --report-only) report_only="$2"; shift 2 ;;
        --profile) profile="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ $quick = 1 ]; then
    : "${jit:=off}" "${warmup:=1}" "${runs:=5}" "${pgsecs:=3}"
    mode=quick
else
    : "${jit:=off,on}" "${warmup:=3}" "${runs:=15}" "${pgsecs:=15}"
    mode=full
fi
primary=${versions%% *}
containers=()
cleanup() {
    for c in "${containers[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

render_report() {   # render_report <run dir>
    local dir=$1 c="plzig-bench-report-$$" dest
    local img="plzig-bench:$primary"
    if [ -f "$dir/primary" ]; then img="plzig-bench:$(cat "$dir/primary")"; fi
    containers+=("$c")
    local args=(--in /tmp/in --out /tmp/report)
    [ -n "$history" ] && args+=(--history /tmp/history)
    [ -n "$call_history" ] && args+=(--call-history /tmp/call-history)
    docker create --name "$c" "$img" python3 /bench/report.py "${args[@]}" >/dev/null
    docker cp bench/. "$c:/bench"
    docker cp "$dir/." "$c:/tmp/in"
    [ -n "$history" ] && docker cp "$history/." "$c:/tmp/history"
    [ -n "$call_history" ] && docker cp "$call_history/." "$c:/tmp/call-history"
    docker start -a "$c"
    if [ $publish = 1 ]; then dest=doc; else dest="$dir/report"; fi
    mkdir -p "$dest/benchmarks"
    rm -f "$dest"/benchmarks/*.svg "$dest"/benchmarks/*.csv
    docker cp "$c:/tmp/report/." "$dest/"
    docker rm "$c" >/dev/null
    echo "report: $dest/benchmarks.md"
}

if [ -n "$report_only" ]; then
    render_report "$report_only"
    exit 0
fi

[ -n "$out" ] || out="build/bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
echo "$primary" > "$out/primary"
status=0
for v in $versions; do
    echo "=== PostgreSQL $v"
    if [ $build = 1 ]; then
        echo "--- building plzig-test:$v (docker/Dockerfile)"
        docker build -q -f docker/Dockerfile --build-arg "PG_IMAGE=postgres:${v}-bookworm" \
            -t "plzig-test:$v" . >/dev/null
    fi
    echo "--- building plzig-bench:$v (bench/Dockerfile)"
    docker build -q -f bench/Dockerfile --build-arg "BASE=plzig-test:$v" \
        -t "plzig-bench:$v" bench >/dev/null
    c="plzig-bench-$v-$$"
    containers+=("$c")
    dargs=(--out /tmp/out --mode "$mode" --jit "$jit" --warmup "$warmup" --runs "$runs"
           --clients "$clients" --pgbench-seconds "$pgsecs" --cpus "$cpus")
    [ -n "$tasks" ] && dargs+=(--tasks "$tasks")
    [ $quick = 1 ] && dargs+=(--startup-runs 5 --cold-runs 2 --memory-runs 2)
    copts=(--init --shm-size=1g)
    [ -n "$cpus" ] && copts+=(--cpuset-cpus "$cpus")
    cmd=(python3 /bench/driver.py)
    if [ -n "$profile" ]; then
        dargs+=(--profile "$profile" --profile-repeat "$runs")
        copts+=(--user root --cap-add PERFMON --cap-add SYS_PTRACE
                --security-opt seccomp=unconfined --security-opt label=disable)
        cmd=(bash /bench/profile-in-container.sh)
    fi
    docker create --name "$c" "${copts[@]}" "plzig-bench:$v" \
        "${cmd[@]}" "${dargs[@]}" >/dev/null
    docker cp bench/. "$c:/bench"
    rc=0
    docker start -a "$c" || rc=$?
    mkdir -p "$out/$v"
    docker cp "$c:/tmp/out/." "$out/$v/" 2>/dev/null || true
    docker rm "$c" >/dev/null
    if [ $rc != 0 ]; then
        echo "FAIL: PostgreSQL $v (exit $rc), see $out/$v/"
        status=1
    fi
done

if [ $status = 0 ] && [ -z "$profile" ]; then
    render_report "$out"
fi
echo "results: $out"
[ $status = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $status
