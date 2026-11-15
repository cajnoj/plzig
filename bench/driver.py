#!/usr/bin/env python3
"""PL/Zig benchmark driver.

Runs inside the benchmark image (bench/Dockerfile) as the postgres user,
started by bench/run.sh.  Creates a throw-away cluster, loads the data and
every task's implementations, runs the correctness gate, then the timed
runs, the pgbench runs, the start-up measurements (task 11) and the memory
measurements (task 12), and writes CSV files plus meta.json to --out.

Exit status: 0 = everything ran and every gate passed, 1 = a gate failed or
something else went wrong (the partial results are still written).
"""
import argparse
import csv
import glob
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

import psycopg2

PGDATA = "/tmp/bench-pgdata"
SOCKDIR = "/tmp"
ZIG = os.environ.get("PLZIG_TEST_ZIG", "/opt/zig/zig")
BENCH = os.path.dirname(os.path.abspath(__file__))

# implementation id -> language; extra implementations are "<lang>_<name>"
LANGS = ["sql", "plpgsql", "plpython", "plperl", "plzig"]
LANG_NAME = {"sql": "SQL", "plpgsql": "PL/pgSQL", "plpython": "PL/Python",
             "plperl": "PL/Perl", "plzig": "PL/Zig"}

SIZES = {
    "full": {"big_rows": 1000000, "words": 10000, "csv_rows": 20000, "blob_kb": 1024},
    "quick": {"big_rows": 100000, "words": 1000, "csv_rows": 2000, "blob_kb": 256},
}

# Server settings: identical for every language (written to postgresql.conf).
SERVER_CONF = {
    "plzig.zig_path": f"'{ZIG}'",
    "shared_buffers": "'512MB'",
    "work_mem": "'64MB'",
    "maintenance_work_mem": "'256MB'",
    "max_parallel_workers_per_gather": "0",
    "autovacuum": "off",
    "synchronous_commit": "off",
    "max_connections": "100",
    "log_min_messages": "warning",
    "unix_socket_directories": f"'{SOCKDIR}'",
    "listen_addresses": "''",
}


def lang_of(impl):
    return impl.split("_", 1)[0]


def log(*a):
    print(*a, flush=True)


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw).stdout


# ---------------------------------------------------------------------------
# cluster

def start_cluster():
    if os.path.exists(PGDATA):
        shutil.rmtree(PGDATA)
    sh(["initdb", "-D", PGDATA, "-U", "postgres", "--no-locale", "-E", "UTF8", "-A", "trust"])
    with open(os.path.join(PGDATA, "postgresql.conf"), "a") as f:
        f.write("\n# bench/driver.py\n")
        for k, v in SERVER_CONF.items():
            f.write(f"{k} = {v}\n")
    sh(["pg_ctl", "-D", PGDATA, "-l", "/tmp/bench-server.log", "-w", "-t", "120", "start"])


def stop_cluster():
    subprocess.run(["pg_ctl", "-D", PGDATA, "-m", "fast", "-w", "stop"],
                   capture_output=True)


def connect(jit="off"):
    c = psycopg2.connect(host=SOCKDIR, dbname="postgres", user="postgres")
    c.autocommit = True
    cur = c.cursor()
    if jit == "force":
        # JIT for every statement, whatever its cost (not a setting anyone
        # would run with: shows what JIT can do where it applies at all)
        cur.execute("SET jit = on; SET jit_above_cost = 0; SET jit_inline_above_cost = 0; "
                    "SET jit_optimize_above_cost = 0")
    else:
        cur.execute(f"SET jit = {jit}")
    return c


def psql_file(path, variables=None):
    cmd = ["psql", "-h", SOCKDIR, "-U", "postgres", "-d", "postgres", "-X", "-q",
           "-v", "ON_ERROR_STOP=1", "-f", path]
    for k, v in (variables or {}).items():
        cmd += ["-v", f"{k}={v}"]
    r = subprocess.run(cmd, text=True, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql {path} failed:\n{r.stdout}\n{r.stderr}")


# ---------------------------------------------------------------------------
# tasks

def load_tasks(selected):
    tasks = []
    for d in sorted(glob.glob(os.path.join(BENCH, "tasks", "[0-9][0-9]_*"))):
        tid = int(os.path.basename(d)[:2])
        if selected and tid not in selected:
            continue
        with open(os.path.join(d, "task.json")) as f:
            t = json.load(f)
        t["id"] = tid
        t["dir"] = d
        tasks.append(t)
    return tasks


def create_functions(tasks):
    for t in tasks:
        for lang in LANGS:
            p = os.path.join(t["dir"], f"{lang}.sql")
            if os.path.exists(p):
                t0 = time.perf_counter()
                psql_file(p)
                log(f"  created task {t['id']:02d} {lang:9s} {time.perf_counter() - t0:6.2f} s")


def impls_for(conn, fn):
    cur = conn.cursor()
    cur.execute("SELECT proname FROM pg_proc WHERE proname LIKE %s", (fn + "\\_%",))
    names = [r[0][len(fn) + 1:] for r in cur.fetchall()]
    order = {l: i for i, l in enumerate(LANGS)}
    return sorted(names, key=lambda n: (order.get(lang_of(n), 99), n))


def fmt(q, fn, params):
    return q.format(fn=fn, **params)


def run_query(cur, q):
    cur.execute(q)
    return cur.fetchall() if cur.description else None


def run_check(cur, v, fn, params):
    if v.get("before_each"):
        cur.execute(v["before_each"])
    checks = v.get("check", v["query"])
    if isinstance(checks, str):
        checks = [checks]
    out = []
    for q in checks:
        out.append(repr(run_query(cur, fmt(q, fn, params))))
    return " ; ".join(out)


# ---------------------------------------------------------------------------
# measurements

def gate(tasks, mode, writer):
    """Every implementation of a variant must return what PL/pgSQL returns."""
    ok = True
    conn = connect("off")
    cur = conn.cursor()
    for t in tasks:
        params = t.get("params", {}).get(mode, {})
        for v in t.get("variants", []):
            impls = impls_for(conn, v["fn"])
            res = {}
            for impl in impls:
                try:
                    res[impl] = run_check(cur, v, f"{v['fn']}_{impl}", params)
                except Exception as e:  # noqa: BLE001 - reported as a gate failure
                    res[impl] = f"ERROR: {e}".strip()
            ref = res.get("plpgsql")
            for impl in impls:
                same = res[impl] == ref and not res[impl].startswith("ERROR")
                ok &= same
                writer.writerow([t["id"], v["name"], impl, "PASS" if same else "FAIL", res[impl][:200]])
                if not same:
                    log(f"GATE FAIL task {t['id']:02d} {v['name']} {impl}: {res[impl][:300]!r} "
                        f"(PL/pgSQL: {str(ref)[:300]!r})")
            log(f"  gate task {t['id']:02d} {v['name']:14s} {'PASS' if all(res[i] == ref for i in impls) else 'FAIL'}"
                f"  {ref[:60] if ref else ''}")
    conn.close()
    return ok


def explain_jit(tasks, mode, jits, writer, version):
    """Record the planner's total cost of every timed statement and whether
    it would be JIT-compiled under each JIT mode (EXPLAIN, not executed)."""
    for jit in jits:
        conn = connect(jit)
        cur = conn.cursor()
        for t in tasks:
            params = t.get("params", {}).get(mode, {})
            for v in t.get("variants", []):
                for i in impls_for(conn, v["fn"]):
                    cur.execute("EXPLAIN (FORMAT JSON) " + fmt(v["query"], f"{v['fn']}_{i}", params))
                    plan = cur.fetchone()[0][0]
                    writer.writerow([version, jit, t["id"], v["name"], i, plan["Plan"]["Total Cost"],
                                     "yes" if "JIT" in plan else "no"])
        conn.close()


def timed(tasks, mode, jits, warmup, runs, writer, version):
    for jit in jits:
        for t in tasks:
            params = t.get("params", {}).get(mode, {})
            for v in t.get("variants", []):
                probe = connect(jit)
                impls = impls_for(probe, v["fn"])
                probe.close()
                conns = {i: connect(jit) for i in impls}
                curs = {i: conns[i].cursor() for i in impls}
                qs = {i: fmt(v["query"], f"{v['fn']}_{i}", params) for i in impls}
                before = v.get("before_each")
                for i in impls:
                    for _ in range(warmup):
                        if before:
                            curs[i].execute(before)
                        run_query(curs[i], qs[i])
                times = {i: [] for i in impls}
                for r in range(runs):
                    # rotate the order every round so drift hits all languages alike
                    order = impls[r % len(impls):] + impls[:r % len(impls)]
                    for i in order:
                        if before:
                            curs[i].execute(before)
                        t0 = time.perf_counter()
                        run_query(curs[i], qs[i])
                        ms = (time.perf_counter() - t0) * 1000.0
                        times[i].append(ms)
                        writer.writerow([version, jit, t["id"], v["name"], i, lang_of(i), r + 1, f"{ms:.4f}"])
                for i in impls:
                    conns[i].close()
                summary = "  ".join(f"{i}={statistics.median(times[i]):.1f}" for i in impls)
                log(f"  jit={jit} task {t['id']:02d} {v['name']:14s} median ms: {summary}")


def pgbench(tasks, mode, clients, seconds, writer, version, outdir):
    for t in tasks:
        pb = t.get("pgbench")
        if not pb:
            continue
        v = next(x for x in t["variants"] if x["name"] == pb["variant"])
        params = t.get("params", {}).get(mode, {})
        probe = connect()
        impls = impls_for(probe, v["fn"])
        probe.close()
        for impl in impls:
            script = os.path.join(outdir, f"pgbench-{t['id']:02d}-{impl}.sql")
            with open(script, "w") as f:
                f.write(fmt(pb["query"], f"{v['fn']}_{impl}", params) + ";\n")
            env = dict(os.environ, PGOPTIONS="-c jit=off", PGHOST=SOCKDIR, PGUSER="postgres")
            base = ["pgbench", "-n", "-M", "prepared", "-f", script, "postgres"]
            subprocess.run(base[:1] + ["-c", "2", "-j", "2", "-T", "1"] + base[1:],
                           env=env, capture_output=True, text=True, check=True)
            for c in clients:
                r = subprocess.run(base[:1] + ["-c", str(c), "-j", str(c), "-T", str(seconds)] + base[1:],
                                   env=env, capture_output=True, text=True)
                if r.returncode != 0:
                    raise RuntimeError(f"pgbench failed: {r.stdout}\n{r.stderr}")
                tps = float(re.search(r"tps = ([0-9.]+) \(without initial connection time\)", r.stdout).group(1))
                lat = float(re.search(r"latency average = ([0-9.]+) ms", r.stdout).group(1))
                n = int(re.search(r"number of transactions actually processed: (\d+)", r.stdout).group(1))
                failed = re.search(r"number of failed transactions: (\d+)", r.stdout)
                if failed and int(failed.group(1)) != 0:
                    raise RuntimeError(f"pgbench: failed transactions\n{r.stdout}")
                writer.writerow([version, t["id"], v["name"], impl, lang_of(impl), c, seconds, f"{tps:.3f}", f"{lat:.4f}", n])
                log(f"  pgbench task {t['id']:02d} {impl:12s} clients={c:2d} tps={tps:10.1f} lat={lat:8.3f} ms")


STARTUP_BODY = {
    "sql": "CREATE FUNCTION {name}(x int) RETURNS int LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT x + 1 -- {tag}\n$$",
    "plpgsql": "CREATE FUNCTION {name}(x int) RETURNS int LANGUAGE plpgsql IMMUTABLE STRICT AS $$\nBEGIN\n    -- {tag}\n    RETURN x + 1;\nEND\n$$",
    "plpython": "CREATE FUNCTION {name}(x int) RETURNS int LANGUAGE plpython3u IMMUTABLE STRICT AS $$\n# {tag}\nreturn x + 1\n$$",
    "plperl": "CREATE FUNCTION {name}(x int) RETURNS int LANGUAGE plperl IMMUTABLE STRICT AS $$\n    # {tag}\n    return $_[0] + 1;\n$$",
    "plzig": "CREATE FUNCTION {name}(x int) RETURNS int LANGUAGE plzig IMMUTABLE STRICT AS $$\n    // {tag}\n    return x + 1;\n$$",
}


def startup(runs, cold_runs, writer, version):
    def ms(t0):
        return (time.perf_counter() - t0) * 1000.0

    for impl in LANGS:
        for r in range(runs):
            c = connect()
            cur = c.cursor()
            t0 = time.perf_counter()
            run_query(cur, f"SELECT t11_{impl}(1)")
            first = ms(t0)
            t0 = time.perf_counter()
            run_query(cur, f"SELECT t11_{impl}(1)")
            second = ms(t0)
            c.close()
            writer.writerow([version, impl, "new_session_first_call", r + 1, f"{first:.4f}"])
            writer.writerow([version, impl, "new_session_second_call", r + 1, f"{second:.4f}"])
        log(f"  startup {impl:9s} new session: first call done")

    cases = [(impl, "") for impl in LANGS] + [("plzig", "cold")]
    for impl, cache in cases:
        n = cold_runs if cache == "cold" else runs
        for r in range(n):
            if cache == "cold":
                shutil.rmtree(os.path.join(PGDATA, "plzig", "pgsql_tmp.zig-cache"), ignore_errors=True)
            name = f"t11c_{impl}_{r}"
            tag = f"bench {time.time_ns()} {os.getpid()} {r}"
            c = connect()
            cur = c.cursor()
            cur.execute(f"DROP FUNCTION IF EXISTS {name}(int)")
            t0 = time.perf_counter()
            cur.execute(STARTUP_BODY[impl].format(name=name, tag=tag))
            create = ms(t0)
            t0 = time.perf_counter()
            run_query(cur, f"SELECT {name}(1)")
            first = ms(t0)
            cur.execute(f"DROP FUNCTION {name}(int)")
            c.close()
            kind = "after_create" + ("_cold_zig_cache" if cache == "cold" else "")
            writer.writerow([version, impl, kind + "_create", r + 1, f"{create:.4f}"])
            writer.writerow([version, impl, kind + "_first_call", r + 1, f"{first:.4f}"])
        log(f"  startup {impl:9s} after CREATE {cache or 'warm'}: done")


def proc_status(pid):
    out = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("VmHWM", "VmRSS", "RssAnon"):
                out[k] = int(v.split()[0])
    return out


def memory(tasks, mode, runs, writer, version):
    for t in tasks:
        params = t.get("params", {}).get(mode, {})
        for v in t.get("variants", []):
            if not v.get("memory"):
                continue
            probe = connect()
            impls = impls_for(probe, v["fn"])
            probe.close()
            for impl in impls:
                for r in range(runs):
                    c = connect()
                    cur = c.cursor()
                    cur.execute("SELECT pg_backend_pid()")
                    pid = cur.fetchone()[0]
                    # load the language and touch the shared buffers the task reads
                    run_query(cur, f"SELECT t11_{lang_of(impl)}(1)")
                    for q in v.get("memory_pretouch", []):
                        run_query(cur, q)
                    before = proc_status(pid)
                    run_query(cur, fmt(v["query"], f"{v['fn']}_{impl}", params))
                    after = proc_status(pid)
                    c.close()
                    writer.writerow([version, t["id"], v["name"], impl, lang_of(impl), r + 1,
                                     before["VmHWM"], after["VmHWM"], before["RssAnon"], after["RssAnon"]])
                log(f"  memory task {t['id']:02d} {impl:12s} VmHWM {before['VmHWM']} -> {after['VmHWM']} kB")


def profile(query, repeat, outdir):
    """Run `query` `repeat` times in one backend while bench/profile-in-container.sh
    (as root) attaches perf to it; see that script for the handshake."""
    def wait_for(name):
        while not os.path.exists(os.path.join(outdir, name)):
            time.sleep(0.1)
    c = connect()
    cur = c.cursor()
    cur.execute("SELECT pg_backend_pid()")
    pid = cur.fetchone()[0]
    for _ in range(2):
        run_query(cur, query)
    with open(os.path.join(outdir, "backend.pid"), "w") as f:
        f.write(str(pid))
    wait_for("go")
    t0 = time.perf_counter()
    for _ in range(repeat):
        run_query(cur, query)
    elapsed = time.perf_counter() - t0
    with open(os.path.join(outdir, "profile.txt"), "w") as f:
        f.write(f"query: {query}\nruns: {repeat}\nms per run: {elapsed / repeat * 1000:.3f}\n")
    open(os.path.join(outdir, "done"), "w").close()
    wait_for("stopped")
    c.close()
    os.unlink(os.path.join(outdir, "backend.pid"))


# ---------------------------------------------------------------------------
# metadata

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def metadata(args):
    cpu = ""
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            cpu = line.split(":", 1)[1].strip()
            break
    mem = re.search(r"MemTotal:\s+(\d+)", read("/proc/meminfo"))
    affinity = sorted(os.sched_getaffinity(0))
    c = connect("on")   # pg_jit_available() is false in a session with jit = off
    cur = c.cursor()
    cur.execute("SELECT t11_plzig(1)")   # loads PL/Zig, so its settings are visible

    def q(sql):
        cur.execute(sql)
        return cur.fetchone()[0]
    meta = {
        "cpu_model": cpu,
        "cpus_visible": len(affinity),
        "cpu_list": args.cpus or "all",
        "online_cpus": os.cpu_count(),
        "mem_total_gb": round(int(mem.group(1)) / 1024 / 1024, 1) if mem else None,
        "kernel": platform.release(),
        "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "unknown"),
        "os_image": read("/etc/debian_version"),
        "server_version": q("SHOW server_version"),
        "version_string": q("SELECT version()"),
        "jit_available": q("SELECT pg_jit_available()"),
        "python": sh(["python3", "--version"]).strip(),
        "perl": sh(["perl", "-e", "print $^V"]).strip(),
        "zig": sh([ZIG, "version"]).strip(),
        "plzig_version": q("SELECT extversion FROM pg_extension WHERE extname = 'plzig'"),
        "settings": {},
        "mode": args.mode,
        "warmup": args.warmup,
        "runs": args.runs,
        "jit_modes": args.jit,
        "pgbench_clients": args.clients,
        "pgbench_seconds": args.pgbench_seconds,
        "sizes": SIZES[args.mode],
        "started": time.strftime("%Y-%m-%d %H:%M:%S %z"),
    }
    cur.execute("SELECT name, setting, unit FROM pg_settings WHERE source NOT IN ('default', 'override', 'client', 'session') ORDER BY name")
    meta["settings"] = {n: s + (u or "") for n, s, u in cur.fetchall()}
    cur.execute("SELECT name, setting FROM pg_settings WHERE name LIKE 'plzig.%' OR name IN ('jit_above_cost', 'jit_inline_above_cost', 'jit_optimize_above_cost') ORDER BY name")
    meta["defaults_of_interest"] = dict(cur.fetchall())
    c.close()
    return meta


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", choices=["full", "quick"], default="full")
    ap.add_argument("--tasks", default="", help="comma-separated task numbers (default: all)")
    ap.add_argument("--jit", default="off,on", help="comma-separated: off, on (server thresholds), force (thresholds 0)")
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--runs", type=int, default=15)
    ap.add_argument("--clients", default="1,4,8")
    ap.add_argument("--pgbench-seconds", type=int, default=15)
    ap.add_argument("--startup-runs", type=int, default=15)
    ap.add_argument("--cold-runs", type=int, default=10)
    ap.add_argument("--memory-runs", type=int, default=5)
    ap.add_argument("--cpus", default="", help="recorded only (the container's cpuset)")
    ap.add_argument("--profile", default="", help="perf-profile this query instead of benchmarking")
    ap.add_argument("--profile-repeat", type=int, default=20)
    args = ap.parse_args()
    args.jit = [j for j in args.jit.split(",") if j]
    args.clients = [int(c) for c in args.clients.split(",") if c]
    selected = {int(x) for x in args.tasks.split(",") if x}
    os.makedirs(args.out, exist_ok=True)

    tasks = load_tasks(selected)
    query_tasks = [t for t in tasks if t.get("variants")]
    log(f"=== tasks: {', '.join(str(t['id']) for t in tasks)}; mode {args.mode}")
    start_cluster()
    ok = True
    try:
        log("--- loading data")
        psql_file(os.path.join(BENCH, "setup.sql"), SIZES[args.mode])
        log("--- creating functions (PL/Zig compiles at CREATE)")
        # t11_* (trivial functions) are used by tasks 11 and 12; task 12
        # measures tasks 3, 6 and 8
        mem_tasks = [t for t in load_tasks(set()) if any(v.get("memory") for v in t.get("variants", []))]
        want = {t["id"] for t in tasks} | {11}
        if 12 in selected or not selected:
            want |= {t["id"] for t in mem_tasks}
        create_functions(load_tasks(want))
        meta = metadata(args)
        version = meta["server_version"].split()[0]
        with open(os.path.join(args.out, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)

        def open_csv(name, header):
            f = open(os.path.join(args.out, name), "w", newline="")
            w = csv.writer(f)
            w.writerow(header)
            return f, w

        if args.profile:
            profile(args.profile, args.profile_repeat, args.out)
            return 0

        log("--- correctness gate")
        f, w = open_csv("gate.csv", ["task", "variant", "impl", "result", "value"])
        ok = gate(query_tasks, args.mode, w)
        f.close()
        if not ok:
            log("GATE FAILED: implementations disagree; no timings taken")
            return 1

        f, w = open_csv("jit.csv", ["version", "jit", "task", "variant", "impl", "total_cost", "jit_compiled"])
        explain_jit(query_tasks, args.mode, args.jit, w, version)
        f.close()

        log("--- timed runs")
        f, w = open_csv("timings.csv", ["version", "jit", "task", "variant", "impl", "lang", "run", "ms"])
        timed(query_tasks, args.mode, args.jit, args.warmup, args.runs, w, version)
        f.close()

        if args.clients and any(t.get("pgbench") for t in query_tasks):
            log("--- pgbench")
            f, w = open_csv("pgbench.csv", ["version", "task", "variant", "impl", "lang", "clients",
                                            "seconds", "tps", "latency_ms", "transactions"])
            pgbench(query_tasks, args.mode, args.clients, args.pgbench_seconds, w, version, args.out)
            f.close()

        if any(t["id"] == 11 for t in tasks):
            log("--- task 11: start-up and compile")
            f, w = open_csv("startup.csv", ["version", "impl", "kind", "run", "ms"])
            startup(args.startup_runs, args.cold_runs, w, version)
            f.close()

        if 12 in selected or not selected:
            log("--- task 12: backend memory high-water mark")
            f, w = open_csv("memory.csv", ["version", "task", "variant", "impl", "lang", "run",
                                           "hwm_before_kb", "hwm_after_kb", "anon_before_kb", "anon_after_kb"])
            memory(mem_tasks, args.mode, args.memory_runs, w, version)
            f.close()
        log("=== done")
        return 0
    except Exception as e:  # noqa: BLE001
        log(f"ERROR: {e}")
        log(read("/tmp/bench-server.log")[-4000:])
        return 1
    finally:
        stop_cluster()
        shutil.copy("/tmp/bench-server.log", os.path.join(args.out, "server.log")) \
            if os.path.exists("/tmp/bench-server.log") else None


if __name__ == "__main__":
    sys.exit(main())
