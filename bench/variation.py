#!/usr/bin/env python3
"""Variation measurements for the compute tasks (bench/variation.sh).

Runs as root inside the benchmark image (the server itself runs as
postgres): root is needed to replace plzig.so with a relinked copy (--pad),
and for `perf stat` on a backend (--perf).  Not part of the product and
never run by the normal benchmark.

What it does:

* optionally relinks /src/plzig.so with --pad N bytes of unused code placed
  in front of everything else (same objects, same flags, same libiwasm.a:
  only the addresses of the code change), and installs it;
* starts a throw-away cluster with the benchmark's settings, creates the
  functions of tasks 2 and 5;
* for every round and every CPU setting, runs each query in a fresh session
  whose backend is pinned to that CPU setting (a CPU number, a list such as
  0-11, or `any`): --warmup untimed executions, then --runs timed ones;
* with --perf, counts user-space cycles, instructions, branches and branch
  mispredictions of that backend over the timed executions.

Output (in --out): timings.csv, perf.csv (with --perf), build.json (digest
of plzig.so, address of the interpreter function, machine state).
"""
import argparse
import csv
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

import statistics

driver = None   # bench/driver.py, imported in the container only (psycopg2)

SRC = "/src"
INTERP = "wasm_interp_call_func_bytecode"

# name, query; the PL/pgSQL rows do not execute any code of plzig.so and
# show what the machine did meanwhile
QUERIES = [
    ("primes plzig", "SELECT t02_primes_plzig({n})"),
    ("mandelbrot plzig", "SELECT t02_mandel_plzig({w}, {maxiter})"),
    ("fnv1a plzig", "SELECT t05_plzig(b || ''::bytea) FROM bench_blob"),
    ("primes plpgsql", "SELECT t02_primes_plpgsql({n})"),
    ("mandelbrot plpgsql", "SELECT t02_mandel_plpgsql({w}, {maxiter})"),
]

# generic events (perf resolves them per core type on a hybrid CPU)
EVENTS = ["cycles:u", "instructions:u", "branches:u", "branch-misses:u"]
# --frontend: where the decoded instructions come from, as raw events of the
# performance cores of Intel Golden Cove and its successors (IDQ.DSB_UOPS:
# from the decoded-uop cache; IDQ.MITE_UOPS: from the legacy decoders;
# DSB2MITE_SWITCHES.PENALTY_CYCLES; BACLEARS.ANY: front-end resteers);
# not counted on other cores
FRONTEND = ["cpu_core/event=0x79,umask=0x08,name=dsb_uops/u",
            "cpu_core/event=0x79,umask=0x04,name=mite_uops/u",
            "cpu_core/event=0x61,umask=0x02,name=dsb2mite_cycles/u",
            "cpu_core/event=0x60,umask=0x01,name=baclears/u"]
EXTRA = ["dsb_uops", "mite_uops", "dsb2mite_cycles", "baclears"]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw).stdout


def as_postgres(cmd, **kw):
    return run(["gosu", "postgres"] + cmd, **kw)


def pkglibdir():
    return run(["pg_config", "--pkglibdir"]).strip()


def relink(pad, wamr_cflags):
    """Link plzig.so again with `pad` bytes of never-executed code first;
    with wamr_cflags, compile WAMR again with these additional flags before."""
    if wamr_cflags:
        run(["cmake", "-S", f"{SRC}/third_party/wamr", "-B", f"{SRC}/build/wamr",
             f"-DCMAKE_C_FLAGS={wamr_cflags}"])
        run(["cmake", "--build", f"{SRC}/build/wamr", "-j", str(os.cpu_count())])
    with open("/tmp/pad.S", "w") as f:
        f.write(f"\t.text\n\t.globl plzig_bench_pad\n\t.hidden plzig_bench_pad\n"
                f"plzig_bench_pad:\n\t.skip {pad}, 0xcc\n"
                f"\t.section .note.GNU-stack,\"\",@progbits\n")
    run(["gcc", "-c", "-o", f"{SRC}/src/bench_pad.o", "/tmp/pad.S"])
    os.remove(f"{SRC}/plzig.so")
    mk = ["make", "-C", SRC, "plzig.so", f"ZIG={driver.ZIG}", f"WAMR_SRC={SRC}/vendor/wamr"]
    line = [l for l in run(mk + ["-n"]).splitlines() if " -o plzig.so " in l]
    if len(line) != 1:
        raise RuntimeError("cannot find the link command of plzig.so")
    cmd = line[0].replace(" -o plzig.so ", " -o plzig.so src/bench_pad.o ", 1)
    run(["sh", "-c", cmd], cwd=SRC)
    run(["install", "-m", "755", f"{SRC}/plzig.so", pkglibdir() + "/plzig.so"])


def build_info(pad):
    so = pkglibdir() + "/plzig.so"
    with open(so, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    addr = size = None
    for l in run(["nm", "-S", so]).splitlines():
        p = l.split()
        if len(p) == 4 and p[3] == INTERP:
            addr, size = int(p[0], 16), int(p[1], 16)
    text = re.search(r"\.text\s+PROGBITS\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)",
                     run(["readelf", "-SW", so]))
    rd = driver.read
    with open("/proc/cpuinfo") as f:
        model = re.search(r"model name\s*:\s*(.*)", f.read())
    return {
        "pad": pad, "plzig_so_sha256": digest,
        "interp_addr": hex(addr), "interp_size": size, "interp_addr_mod64": addr % 64,
        "text_addr": "0x" + text.group(1), "text_size": int(text.group(2), 16),
        "cpu_model": model.group(1) if model else "",
        "kernel": os.uname().release,
        "governor": rd("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "epp": rd("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"),
        "no_turbo": rd("/sys/devices/system/cpu/intel_pstate/no_turbo"),
        "smt": rd("/sys/devices/system/cpu/smt/active"),
        "cpu_core": rd("/sys/devices/cpu_core/cpus"),
        "cpu_atom": rd("/sys/devices/cpu_atom/cpus"),
        "perf_event_paranoid": rd("/proc/sys/kernel/perf_event_paranoid"),
        "loadavg": rd("/proc/loadavg"),
    }


def cpu_set(spec):
    if spec == "any":
        return set(range(os.cpu_count()))
    out = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out |= set(range(int(a), int(b or a) + 1))
    return out


def max_khz(cpus):
    v = [driver.read(f"/sys/devices/system/cpu/cpu{c}/cpufreq/cpuinfo_max_freq") for c in cpus]
    v = sorted({int(x) for x in v if x})
    return "/".join(str(x) for x in v)


def summarize(top):
    """Print medians and counters of every run directory below `top`."""
    times, perf, builds = {}, {}, {}
    for root, _, files in sorted(os.walk(top)):
        if "timings.csv" not in files:
            continue
        with open(os.path.join(root, "build.json")) as f:
            b = json.load(f)
        builds.setdefault(b["label"], b)
        with open(os.path.join(root, "timings.csv")) as f:
            for r in csv.DictReader(f):
                times.setdefault((r["label"], r["cpus"], r["query"]), []).append(float(r["ms"]))
        if "perf.csv" in files:
            with open(os.path.join(root, "perf.csv")) as f:
                for r in csv.DictReader(f):
                    d = perf.setdefault((r["label"], r["cpus"], r["query"]), {})
                    key = (r["label"], r["round"], root, r["pmu"])
                    e = d.setdefault(key, {"runs": int(r["runs"]), "ms": float(r["ms_total"])})
                    e[r["event"].split(":")[0]] = int(r["count"])
    print("build                 plzig.so      interpreter at  mod 64  .text bytes")
    for label, b in builds.items():
        print(f"{label:21s} {b['plzig_so_sha256'][:12]}  {b['interp_addr']:>14s}  {b['interp_addr_mod64']:6d}"
              f"  {b['text_size']:11d}")
    print()
    print("build                 cpus   query                 n  median ms    min    max  IQR/med |"
          " Mcycles  Minstr   IPC  br-miss/1k  GHz  (per run; min..max of Mcycles over rounds)")
    for (label, cpus, query), v in times.items():
        q = statistics.quantiles(v, n=4) if len(v) >= 4 else [min(v), statistics.median(v), max(v)]
        med = statistics.median(v)
        line = (f"{label:21s} {cpus:6s} {query:19s} {len(v):3d} {med:10.2f} {min(v):6.1f} {max(v):6.1f}"
                f" {100 * (q[2] - q[0]) / med:7.1f}% |")
        # one line per core type that counted anything, rounds pooled
        by_pmu = {}
        for (_, _, _, pmu), e in perf.get((label, cpus, query), {}).items():
            if e.get("cycles"):
                by_pmu.setdefault(pmu, []).append(e)
        first = True
        for pmu, es in sorted(by_pmu.items()):
            cyc = [e["cycles"] / e["runs"] / 1e6 for e in es]
            ins = statistics.median(e["instructions"] / e["runs"] / 1e6 for e in es)
            ipc = statistics.median(e["instructions"] / e["cycles"] for e in es)
            brm = statistics.median(1000.0 * e["branch-misses"] / e["branches"] for e in es)
            ghz = statistics.median(e["cycles"] / (e["ms"] * 1e6) for e in es)
            txt = (f" {statistics.median(cyc):7.1f} {ins:7.1f} {ipc:5.2f} {brm:10.3f} {ghz:5.2f}"
                   f"  ({min(cyc):.1f}..{max(cyc):.1f}) {pmu}")
            extra = [f"{x}={statistics.median(e[x] / e['runs'] / 1e6 for e in es):.1f}M"
                     for x in EXTRA if all(x in e for e in es)]
            if extra:
                txt += "  " + " ".join(extra)
            print((line if first else " " * (len(line) - 1) + "|") + txt)
            first = False
        if first:
            print(line)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--summarize":
        summarize(sys.argv[2])
        return
    global driver
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import driver as drv
    driver = drv
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="build")
    ap.add_argument("--pad", type=int, default=-1, help="relink with this many bytes of padding first")
    ap.add_argument("--wamr-cflags", default="",
                    help="with --pad: compile WAMR again with these additional C flags (experiments only)")
    ap.add_argument("--cpus", default="2", help="space-separated CPU settings: N, A-B, any")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--perf", action="store_true")
    ap.add_argument("--frontend", action="store_true", help="with --perf: front-end events too")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    if args.pad >= 0:
        relink(args.pad, args.wamr_cflags)
    info = build_info(args.pad)
    info["wamr_cflags"] = args.wamr_cflags
    info["label"] = args.label
    with open(os.path.join(args.out, "build.json"), "w") as f:
        json.dump(info, f, indent=2)
    print(f"=== {args.label}: plzig.so {info['plzig_so_sha256'][:12]}, {INTERP} at "
          f"{info['interp_addr']} (mod 64: {info['interp_addr_mod64']})", flush=True)

    driver.sh = as_postgres
    driver.start_cluster()
    try:
        sizes = dict(driver.SIZES["quick"], blob_kb=driver.SIZES["full"]["blob_kb"])
        driver.psql_file(os.path.join(driver.BENCH, "setup.sql"), sizes)
        tasks = driver.load_tasks({2, 5})
        driver.create_functions(tasks)
        params = tasks[0]["params"]["full"]

        tf = open(os.path.join(args.out, "timings.csv"), "w", newline="")
        tw = csv.writer(tf)
        tw.writerow(["label", "round", "cpus", "max_khz", "query", "run", "ms"])
        pw = None
        if args.perf:
            pf = open(os.path.join(args.out, "perf.csv"), "w", newline="")
            pw = csv.writer(pf)
            pw.writerow(["label", "round", "cpus", "query", "runs", "ms_total", "event", "pmu", "count"])
        for rnd in range(1, args.rounds + 1):
            for spec in args.cpus.split():
                cpus = cpu_set(spec)
                for name, q in QUERIES:
                    conn = driver.connect("off")
                    cur = conn.cursor()
                    pid = conn.get_backend_pid()
                    os.sched_setaffinity(pid, cpus)
                    q = q.format(**params)
                    for _ in range(args.warmup):
                        driver.run_query(cur, q)
                    perf = None
                    if pw:
                        pout = "/tmp/perf-stat.csv"
                        perf = subprocess.Popen(
                            ["perf", "stat", "-x", ";", "-o", pout, "-e", ",".join(EVENTS + (FRONTEND if args.frontend else [])),
                             "-p", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        time.sleep(0.5)
                    total = 0.0
                    for r in range(args.runs):
                        t0 = time.perf_counter()
                        driver.run_query(cur, q)
                        ms = (time.perf_counter() - t0) * 1000.0
                        total += ms
                        tw.writerow([args.label, rnd, spec, max_khz(cpus), name, r + 1, f"{ms:.4f}"])
                    if perf:
                        perf.send_signal(signal.SIGINT)
                        perf.wait()
                        with open(pout) as f:
                            for l in f:
                                p = l.strip().split(";")
                                if len(p) < 3 or l.startswith("#") or not p[0].isdigit():
                                    continue
                                ev = p[2]
                                m = re.match(r"(cpu_\w+)/(.*)/$", ev)
                                pmu, ev = (m.group(1), m.group(2)) if m else ("", ev)
                                if ev in EXTRA:
                                    pmu = "cpu_core"
                                pw.writerow([args.label, rnd, spec, name, args.runs,
                                             f"{total:.3f}", ev, pmu, p[0]])
                    conn.close()
            tf.flush()
            print(f"  round {rnd} done", flush=True)
    finally:
        subprocess.run(["gosu", "postgres", "pg_ctl", "-D", driver.PGDATA, "-m", "fast", "-w", "stop"],
                       capture_output=True)
        os.system(f"chmod -R a+rX {args.out}")


if __name__ == "__main__":
    main()
