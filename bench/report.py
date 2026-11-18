#!/usr/bin/env python3
"""Render the benchmark report from a run directory (bench/run.sh).

    report.py --in RUNDIR --out OUTDIR [--history DIR] [--call-history DIR]

RUNDIR holds one subdirectory per PostgreSQL version (CSV files and
meta.json written by bench/driver.py) and a file `primary` naming the
primary version.  --history DIR holds labelled run directories (sorted by
name, e.g. 1-head, 2-sdk, 3-copy) whose task 10 results are shown as a
before/after table.  --call-history DIR is the same for runs of tasks 1, 7
and 8 with pgbench (the per-call and per-row changes).  Each may have a
README of "label: description" lines; it is copied along with the CSVs.

Writes OUTDIR/benchmarks.md, OUTDIR/benchmarks/*.svg and copies of the CSV
files to OUTDIR/benchmarks/<version>/.  The hand-written analysis in
bench/notes.md is inserted where the report says so.  Standard library
only; the charts are plain SVG written here.
"""
import argparse
import csv
import json
import math
import os
import shutil
import statistics
from collections import defaultdict
from html import escape

BENCH = os.path.dirname(os.path.abspath(__file__))
LANG_ORDER = ["sql", "plpgsql", "plpython", "plperl", "plzig"]
LANG_NAME = {"sql": "SQL", "plpgsql": "PL/pgSQL", "plpython": "PL/Python",
             "plperl": "PL/Perl", "plzig": "PL/Zig"}
# default categorical palette (slots 1-5), light and dark steps
COLORS = {"sql": ("#2a78d6", "#3987e5"), "plpgsql": ("#eb6834", "#d95926"),
          "plpython": ("#1baf7a", "#199e70"), "plperl": ("#eda100", "#c98500"),
          "plzig": ("#e87ba4", "#d55181")}


def impl_name(impl):
    lang, _, extra = impl.partition("_")
    return LANG_NAME.get(lang, lang) + (f" ({extra})" if extra else "")


def impl_key(impl):
    lang = impl.split("_")[0]
    return (LANG_ORDER.index(lang) if lang in LANG_ORDER else 99, impl)


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def med(xs):
    return statistics.median(xs) if xs else None


def quart(xs):
    if len(xs) < 4:
        return (min(xs), max(xs))
    q = statistics.quantiles(xs, n=4)
    return (q[0], q[2])


def fms(x):
    if x is None:
        return "–"
    if x >= 100:
        return f"{x:,.0f}"
    if x >= 10:
        return f"{x:.1f}"
    if x >= 1:
        return f"{x:.2f}"
    return f"{x:.3f}"


def load_tasks():
    tasks = {}
    for d in sorted(os.listdir(os.path.join(BENCH, "tasks"))):
        p = os.path.join(BENCH, "tasks", d, "task.json")
        if os.path.exists(p):
            with open(p) as f:
                tasks[int(d[:2])] = json.load(f)
    return tasks


# ---------------------------------------------------------------------------
# SVG

LIGHT = {"bg": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "grid": "#e4e3df"}
DARK = {"bg": "#1a1a19", "ink": "#f0efec", "ink2": "#c3c2b7", "grid": "#3a3a37"}


def svg_style():
    def rules(base, k):
        r = [f".bg {{ fill: {base['bg']}; }}",
             f".ring {{ stroke: {base['bg']}; stroke-width: 2; }}",
             f"text {{ fill: {base['ink2']}; }}",
             f".t, .lab {{ fill: {base['ink']}; }}",
             f".grid {{ stroke: {base['grid']}; stroke-width: 1; }}",
             f".axis {{ stroke: {base['ink2']}; stroke-width: 1; }}"]
        for lang, c in COLORS.items():
            r.append(f".f-{lang} {{ fill: {c[k]}; }} .s-{lang} {{ stroke: {c[k]}; fill: none; }}")
        return "\n  ".join(r)
    return ("<style>\n  text { font-family: system-ui, -apple-system, 'Segoe UI', 'DejaVu Sans', sans-serif; "
            "font-size: 12px; }\n  .t { font-size: 14px; font-weight: 600; }\n  "
            + rules(LIGHT, 0) + "\n  @media (prefers-color-scheme: dark) {\n  "
            + rules(DARK, 1) + "\n  }\n</style>")


def svg_open(w, h, title, desc):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-labelledby="t d">', f"<title id=\"t\">{escape(title)}</title>",
            f"<desc id=\"d\">{escape(desc)}</desc>", svg_style(),
            f'<rect width="{w}" height="{h}" class="bg"/>']


def legend(out, impls, x, y):
    for impl in impls:
        lang = impl.split("_")[0]
        if "_" in impl:   # extra implementation of a language: hollow square
            out.append(f'<rect x="{x}" y="{y - 9}" width="10" height="10" class="s-{lang}" stroke-width="2"/>')
        else:
            out.append(f'<circle cx="{x + 5}" cy="{y - 4}" r="5" class="f-{lang}"/>')
        out.append(f'<text x="{x + 14}" y="{y}" class="lab">{escape(impl_name(impl))}</text>')
        x += 24 + 7.2 * len(impl_name(impl))


def nice_step(vmax):
    """Largest of 1, 2, 5 x 10^k giving at least 3 intervals up to vmax."""
    p = 10 ** math.floor(math.log10(vmax))
    for c in (5 * p, 2 * p, p, p / 2, p / 5):
        if vmax / c >= 3:
            return c
    return p / 10


def dot_chart(rows, impls, title, desc, xlabel, path):
    """rows: [(label, {impl: ratio})]; log-scale dot plot, 1 = PL/pgSQL."""
    vals = [v for _, d in rows for v in d.values() if v and v > 0]
    lo = 10 ** math.floor(math.log10(min(vals + [1.0])))
    hi = 10 ** math.ceil(math.log10(max(vals + [1.0])))
    left, right, top, rowh = 230, 30, 70, 26
    w = 820
    h = top + rowh * len(rows) + 50
    x0, x1 = left, w - right

    def X(v):
        return x0 + (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * (x1 - x0)
    out = svg_open(w, h, title, desc)
    out.append(f'<text x="16" y="24" class="t">{escape(title)}</text>')
    legend(out, impls, 16, 48)
    p = lo
    while p <= hi * 1.0001:
        for m in (1, 2, 5):
            v = p * m
            if v > hi * 1.0001:
                break
            gx = X(v)
            dash = ' stroke-dasharray="2 3"' if m != 1 else ""
            out.append(f'<line x1="{gx:.1f}" y1="{top - 8}" x2="{gx:.1f}" y2="{h - 42}" class="grid"{dash}/>')
            if m == 1 or (hi / lo <= 100):
                lab = f"{v:g}×"
                out.append(f'<text x="{gx:.1f}" y="{h - 26}" text-anchor="middle">{lab}</text>')
        p *= 10
    out.append(f'<line x1="{X(1):.1f}" y1="{top - 8}" x2="{X(1):.1f}" y2="{h - 42}" class="axis"/>')
    out.append(f'<text x="{(x0 + x1) / 2:.0f}" y="{h - 8}" text-anchor="middle">{escape(xlabel)}</text>')
    for i, (label, d) in enumerate(rows):
        y = top + rowh * i + rowh / 2
        out.append(f'<text x="{left - 12}" y="{y + 4:.1f}" text-anchor="end" class="lab">{escape(label)}</text>')
        for impl in impls:
            v = d.get(impl)
            if not v:
                continue
            lang = impl.split("_")[0]
            shape = (f'<circle cx="{X(v):.1f}" cy="{y:.1f}" r="6" class="f-{lang} ring">' if "_" not in impl else
                     f'<rect x="{X(v) - 5:.1f}" y="{y - 5:.1f}" width="10" height="10" class="s-{lang}" stroke-width="2">')
            tag = "circle" if "_" not in impl else "rect"
            out.append(f'{shape}<title>{escape(label)} – {escape(impl_name(impl))}: '
                       f'{v:.2f}× PL/pgSQL time</title></{tag}>')
    out.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def line_chart(series, title, desc, path, xlabel, ylabel):
    """series: {panel: {impl: [(x, y)]}} -> small multiples, linear axes from 0."""
    panels = list(series)
    pw, ph, gap = 380, 240, 40
    w = 30 + len(panels) * (pw + gap)
    h = ph + 130
    out = svg_open(w, h, title, desc)
    out.append(f'<text x="16" y="24" class="t">{escape(title)}</text>')
    impls = sorted({i for p in panels for i in series[p]}, key=impl_key)
    legend(out, impls, 16, 48)
    for k, panel in enumerate(panels):
        ox, oy = 60 + k * (pw + gap), 80
        data = series[panel]
        xs = sorted({x for pts in data.values() for x, _ in pts})
        ymax = max(y for pts in data.values() for _, y in pts) * 1.08
        step = nice_step(ymax)
        def X(x):
            return ox + (xs.index(x) / max(1, len(xs) - 1)) * (pw - 40)
        def Y(y):
            return oy + ph - y / ymax * ph
        out.append(f'<text x="{ox}" y="{oy - 10}" class="lab">{escape(panel)}</text>')
        g = 0.0
        while g <= ymax:
            out.append(f'<line x1="{ox}" y1="{Y(g):.1f}" x2="{ox + pw - 40}" y2="{Y(g):.1f}" class="grid"/>')
            out.append(f'<text x="{ox - 6}" y="{Y(g) + 4:.1f}" text-anchor="end">{g:,.0f}</text>')
            g += step
        for x in xs:
            out.append(f'<text x="{X(x):.1f}" y="{oy + ph + 18}" text-anchor="middle">{x}</text>')
        out.append(f'<text x="{ox + (pw - 40) / 2:.0f}" y="{oy + ph + 36}" text-anchor="middle">{escape(xlabel)}</text>')
        out.append(f'<text x="{ox - 46}" y="{oy + ph / 2:.0f}" text-anchor="middle" '
                   f'transform="rotate(-90 {ox - 46} {oy + ph / 2:.0f})">{escape(ylabel)}</text>')
        for impl in sorted(data, key=impl_key):
            lang = impl.split("_")[0]
            pts = sorted(data[impl])
            d = " ".join(f"{'M' if i == 0 else 'L'}{X(x):.1f},{Y(y):.1f}" for i, (x, y) in enumerate(pts))
            dash = ' stroke-dasharray="5 4"' if "_" in impl else ""
            out.append(f'<path d="{d}" class="s-{lang}" stroke-width="2"{dash}/>')
            for x, y in pts:
                out.append(f'<circle cx="{X(x):.1f}" cy="{Y(y):.1f}" r="4" class="f-{lang} ring"><title>{escape(impl_name(impl))}, '
                           f'{x} clients: {y:,.0f} tps</title></circle>')
    out.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def bar_chart(groups, impls, title, desc, path, unit):
    """groups: [(label, {impl: value})]; horizontal grouped bars from 0."""
    left, top, barh, gap = 230, 70, 14, 2
    w = 820
    rows = sum(len([i for i in impls if i in d]) for _, d in groups)
    h = top + rows * (barh + gap) + len(groups) * 16 + 50
    vmax = max(v for _, d in groups for v in d.values()) * 1.1
    x0, x1 = left, w - 60

    def X(v):
        return x0 + v / vmax * (x1 - x0)
    out = svg_open(w, h, title, desc)
    out.append(f'<text x="16" y="24" class="t">{escape(title)}</text>')
    legend(out, impls, 16, 48)
    step = nice_step(vmax)
    g = 0.0
    while g <= vmax:
        out.append(f'<line x1="{X(g):.1f}" y1="{top - 6}" x2="{X(g):.1f}" y2="{h - 40}" class="grid"/>')
        out.append(f'<text x="{X(g):.1f}" y="{h - 24}" text-anchor="middle">{g:g}</text>')
        g += step
    out.append(f'<text x="{(x0 + x1) / 2:.0f}" y="{h - 6}" text-anchor="middle">{escape(unit)}</text>')
    y = top
    for label, d in groups:
        present = [i for i in impls if i in d]
        out.append(f'<text x="{left - 12}" y="{y + len(present) * (barh + gap) / 2 + 4:.1f}" '
                   f'text-anchor="end" class="lab">{escape(label)}</text>')
        for impl in present:
            lang = impl.split("_")[0]
            v = d[impl]
            wbar = max(1.0, X(v) - x0)
            out.append(f'<rect x="{x0}" y="{y}" width="{wbar:.1f}" height="{barh}" rx="2" class="f-{lang}">'
                       f'<title>{escape(label)} – {escape(impl_name(impl))}: {v:.1f} {escape(unit)}</title></rect>')
            out.append(f'<text x="{x0 + wbar + 4:.1f}" y="{y + barh - 3}">{v:.1f}</text>')
            y += barh + gap
        y += 16
    out.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


# ---------------------------------------------------------------------------

def timing_table(rows, jit):
    """rows of timings.csv -> {(task, variant): {impl: [ms]}} for one jit mode."""
    d = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r["jit"] == jit:
            d[(int(r["task"]), r["variant"])][r["impl"]].append(float(r["ms"]))
    return d


def read_history_readme(src, dst):
    """label -> description from src/README (copied to dst/README)."""
    desc = {}
    dp = os.path.join(src, "README")
    if os.path.exists(dp):
        os.makedirs(dst, exist_ok=True)
        shutil.copy(dp, os.path.join(dst, "README"))
        for line in open(dp):
            k, _, v = line.partition(":")
            if k.strip():
                desc[k.strip()] = v.strip()
    return desc


CALL_TASKS = [(1, "x+1"), (7, "by_key"), (8, "cursor_sum")]


def call_history(src, dst, w):
    """Tasks 1, 7, 8 and pgbench of labelled runs, one row per state."""
    labels = sorted(x for x in os.listdir(src) if os.path.isdir(os.path.join(src, x)))
    tv, pb = {}, {}
    for lab in labels:
        for v in sorted(os.listdir(os.path.join(src, lab))):
            p = os.path.join(src, lab, v, "timings.csv")
            if not os.path.exists(p):
                continue
            tv[lab] = timing_table(read_csv(p), "off")
            d = os.path.join(dst, lab)
            os.makedirs(d, exist_ok=True)
            shutil.copy(p, d)
            q = os.path.join(src, lab, v, "pgbench.csv")
            if os.path.exists(q):
                shutil.copy(q, d)
                pb[lab] = read_csv(q)
    desc = read_history_readme(src, dst)
    labels = [lab for lab in labels if lab in tv]
    w("## Per-call and per-row overhead before and after")
    w("")
    w("Separate runs of tasks 1, 7 and 8 (same method as the main run: 3 warm-up and "
      "15 timed runs, JIT off, container pinned to the same CPUs, one run after the other), "
      "one per state of the code, each state including the ones above it; median ms "
      "(interquartile range). PL/pgSQL did not change between the runs: its column shows "
      "the run-to-run noise. Raw data: [`benchmarks/call-history/`](benchmarks/call-history/).")
    w("")
    head = []
    for t, var in CALL_TASKS:
        head += [f"{t} {var}: PL/Zig", f"{t} {var}: PL/pgSQL"]
    w("| State | " + " | ".join(head) + " |")
    w("|---|" + "---:|" * len(head))
    for lab in labels:
        cells = []
        for t, var in CALL_TASKS:
            for i in ("plzig", "plpgsql"):
                xs = tv[lab].get((t, var), {}).get(i, [])
                if xs:
                    q1, q3 = quart(xs)
                    cells.append(f"{fms(med(xs))} ({fms(q1)}–{fms(q3)})")
                else:
                    cells.append("–")
        w(f"| {desc.get(lab, lab)} | " + " | ".join(cells) + " |")
    w("")
    if pb:
        clients = sorted({int(r["clients"]) for rows in pb.values() for r in rows})
        w("pgbench (`-M prepared`, 15 s per client count, one measurement each, so no "
          "spread): transactions per second at " + "/".join(str(c) for c in clients) +
          " clients.")
        w("")
        head = []
        for t in (1, 7):
            head += [f"{t}: PL/Zig", f"{t}: PL/pgSQL"]
        w("| State | " + " | ".join(head) + " |")
        w("|---|" + "---:|" * len(head))
        for lab in labels:
            if lab not in pb:
                continue
            cells = []
            for t in (1, 7):
                for i in ("plzig", "plpgsql"):
                    tps = {int(r["clients"]): float(r["tps"]) for r in pb[lab]
                           if int(r["task"]) == t and r["impl"] == i}
                    cells.append(" / ".join(f"{tps[c]:,.0f}" if c in tps else "–" for c in clients))
            w(f"| {desc.get(lab, lab)} | " + " | ".join(cells) + " |")
        w("")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--history", default="")
    ap.add_argument("--call-history", default="")
    args = ap.parse_args()
    with open(os.path.join(args.indir, "primary")) as f:
        primary = f.read().strip()
    versions = sorted(d for d in os.listdir(args.indir)
                      if os.path.isdir(os.path.join(args.indir, d)) and
                      os.path.exists(os.path.join(args.indir, d, "meta.json")))
    versions = [primary] + [v for v in versions if v != primary]
    pdir = os.path.join(args.indir, primary)
    with open(os.path.join(pdir, "meta.json")) as f:
        meta = json.load(f)
    tasks = load_tasks()
    figdir = os.path.join(args.out, "benchmarks")
    os.makedirs(figdir, exist_ok=True)
    for v in versions:
        dst = os.path.join(figdir, v)
        os.makedirs(dst, exist_ok=True)
        for name in ("timings.csv", "pgbench.csv", "startup.csv", "memory.csv", "gate.csv", "jit.csv", "meta.json"):
            src = os.path.join(args.indir, v, name)
            if os.path.exists(src):
                shutil.copy(src, dst)

    timings = read_csv(os.path.join(pdir, "timings.csv"))
    md = []
    w = md.append
    w("# PL/Zig benchmarks")
    w("")
    w(f"Generated by `bench/report.py` from the run of {meta['started']} "
      f"({meta['mode']} mode). Raw data: [`doc/benchmarks/`](benchmarks/) (CSV per "
      "PostgreSQL version). Reproduce with `bench/run.sh` (see `bench/README.md`). "
      "All numbers come from **one machine** (below); absolute times will differ "
      "elsewhere, ratios less so.")
    w("")
    w("<!-- the analysis below is bench/notes.md, written by hand after looking at the numbers -->")
    with open(os.path.join(BENCH, "notes.md")) as f:
        w(f.read().strip())
    w("")

    # machine
    w("## Machine, versions, settings")
    w("")
    w("| | |")
    w("|---|---|")
    w(f"| CPU | {meta['cpu_model']}; {meta['online_cpus']} logical CPUs, "
      f"benchmark container pinned to {meta['cpu_list']} ({meta['cpus_visible']} visible) |")
    w(f"| Memory | {meta['mem_total_gb']} GB |")
    w(f"| Kernel | Linux {meta['kernel']}; CPU frequency governor: {meta['governor']} |")
    w(f"| OS (container) | Debian {meta['os_image']} (`postgres:<version>-bookworm`, PGDG packages) |")
    w(f"| PostgreSQL | {meta['version_string']} |")
    w(f"| Languages | PL/Zig {meta['plzig_version']} with Zig {meta['zig']} (WAMR 2.4.5 classic interpreter); "
      f"PL/Python with {meta['python']}; PL/Perl with Perl {meta['perl']}; PL/pgSQL and SQL of the server |")
    jit_seen = any(r["jit_compiled"] == "yes" for d in (pdir, os.path.join(args.indir, "jit", primary))
                   for r in read_csv(os.path.join(d, "jit.csv")))
    w(f"| JIT | LLVM, {'available' if meta['jit_available'] or jit_seen else 'not available'}; "
      f"measured off, with the server default (on, `jit_above_cost` = "
      f"{meta['defaults_of_interest'].get('jit_above_cost')}) and forced (see *JIT*) |")
    w(f"| Runs | {meta['warmup']} warm-up + {meta['runs']} timed runs per task and implementation, "
      "interleaved round-robin across implementations, each implementation in its own session"
      + (f"; the backends of these runs pinned to CPU {meta['pin']} (pgbench, start-up and memory "
         "measurements not pinned)" if meta.get("pin") is not None else "") + " |")
    if meta.get("interp_addr"):
        w(f"| Build | `plzig.so` SHA-256 `{meta['plzig_so_sha256'][:16]}…`; the interpreter loop "
          f"(`wasm_interp_call_func_bytecode`) at offset {meta['interp_addr']}, modulo 64: "
          f"{int(meta['interp_addr'], 16) % 64} (see *How much the numbers vary*) |")
    w("")
    w("Server settings (identical for every language; everything else is the default):")
    w("")
    w("| Setting | Value |")
    w("|---|---|")
    for k, v in meta["settings"].items():
        if k in ("data_directory", "config_file", "hba_file", "ident_file", "lc_messages", "lc_monetary",
                 "lc_numeric", "lc_time", "log_timezone", "TimeZone", "default_text_search_config",
                 "DateStyle", "unix_socket_directories", "dynamic_shared_memory_type", "max_wal_size",
                 "min_wal_size", "plzig.zig_path", "transaction_deferrable", "transaction_isolation",
                 "transaction_read_only", "application_name", "client_encoding",
                 "autovacuum_worker_slots"):
            continue
        if v.endswith("8kB") and v[:-3].isdigit():   # value in 8 kB pages
            v = f"{int(v[:-3]) * 8 // 1024}MB"
        w(f"| `{k}` | {v} |")
    pz = {k: v for k, v in meta["defaults_of_interest"].items() if k.startswith("plzig.")}
    w("| PL/Zig settings | " + ("all at their defaults: " + ", ".join(f"`{k}` = {v}" for k, v in pz.items())
                                if pz else "only `plzig.zig_path` set; everything else at its default "
                                "(README, *Configuration*)") + " |")
    w("")
    w("Data sizes: " + ", ".join(f"{k} = {v}" for k, v in meta["sizes"].items()) + ".")
    w("")

    # primary table
    w(f"## Single-session results, PostgreSQL {primary}, JIT off")
    w("")
    w("Median wall-clock time of the whole statement (client side, ms); below it the "
      "spread as interquartile range, and the time relative to PL/pgSQL. Lower is better. "
      "SQL is the plain-SQL baseline where one is expressible (task 6: `levenshtein()` from "
      "contrib/fuzzystrmatch, C code; tasks 7 and 9: set-based, not a loop).")
    w("")
    tt = timing_table(timings, "off")
    allimpls = sorted({i for d in tt.values() for i in d}, key=impl_key)
    w("| Task | " + " | ".join(impl_name(i) for i in allimpls) + " |")
    w("|---|" + "---:|" * len(allimpls))
    ratios = []
    for (tid, variant), d in sorted(tt.items()):
        ref = med(d.get("plpgsql", []))
        cells = []
        rr = {}
        for i in allimpls:
            if i not in d:
                cells.append("–")
                continue
            m = med(d[i])
            q1, q3 = quart(d[i])
            r = m / ref if ref else None
            rr[i] = r
            cells.append(f"**{fms(m)}**<br>{fms(q1)}–{fms(q3)}<br>{r:.2f}×" if r else f"**{fms(m)}**")
        label = f"{tid}. {tasks[tid]['title']}" + (f" — {variant}" if len(tasks[tid]["variants"]) > 1 else "")
        w(f"| {label} | " + " | ".join(cells) + " |")
        ratios.append((f"{tid} {variant}", rr))
    w("")
    if ratios:
        dot_chart(ratios, allimpls, f"Time relative to PL/pgSQL, PostgreSQL {primary}, JIT off",
                  "Dot plot, log scale: median time of each implementation divided by the PL/pgSQL median, "
                  "one row per task. Left of 1x is faster than PL/pgSQL.",
                  "time relative to PL/pgSQL (log scale, left is faster)",
                  os.path.join(figdir, "relative.svg"))
        w("![Time relative to PL/pgSQL per task (log scale)](benchmarks/relative.svg)")
        w("")

    # jit: from the dedicated JIT run (<in>/jit/<primary>/) when there is one
    jdir = os.path.join(args.indir, "jit", primary)
    jtimings = read_csv(os.path.join(jdir, "timings.csv")) if os.path.isdir(jdir) else timings
    if not os.path.isdir(jdir):
        jdir = pdir
    else:
        dst = os.path.join(figdir, "jit", primary)
        os.makedirs(dst, exist_ok=True)
        for name in ("timings.csv", "jit.csv", "meta.json"):
            if os.path.exists(os.path.join(jdir, name)):
                shutil.copy(os.path.join(jdir, name), dst)
    jt_off = timing_table(jtimings, "off")
    modes = [m for m in ("on", "force") if timing_table(jtimings, m)]
    if modes:
        w("## JIT")
        w("")
        w("JIT compilation only ever applies to the SQL expressions of a statement (the outer "
          "query, and queries a function runs through SPI), never to the PL code itself. "
          "*on* is the server default (`jit = on`, `jit_above_cost` = "
          f"{meta['defaults_of_interest'].get('jit_above_cost')}): a statement is compiled only "
          "if its estimated cost exceeds that. *force* sets all three JIT thresholds to 0 "
          "(every statement compiled; nobody would run like that) and was measured for the "
          "SQL-heavy tasks only.")
        w("")
        if jdir != pdir:
            w("From a separate run of the SQL-heavy tasks 1, 2 and 8, all three modes one after "
              "the other in the same container, otherwise measured like the main run "
              "([`benchmarks/jit/`](benchmarks/jit/)).")
            w("")
        jc = read_csv(os.path.join(jdir, "jit.csv"))
        if jc:
            on = [r for r in jc if r["jit"] == "on"]
            yes = sorted({f"{r['task']} {r['variant']} ({impl_name(r['impl'])})" for r in on if r["jit_compiled"] == "yes"})
            top = max(on, key=lambda r: float(r["total_cost"])) if on else None
            w(f"With *on*, EXPLAIN shows JIT for {len(yes)} of {len(on)} timed statements"
              + (": " + ", ".join(yes) if yes else "")
              + (f" (highest estimated cost: {float(top['total_cost']):,.0f}, task {top['task']} "
                 f"{impl_name(top['impl'])})." if top else ".")
              + " (EXPLAIN covers the outer statement; statements run inside the functions "
              "are planned and JIT-decided separately.)")
            w("")
        w("Median ms; rows where no mode differs from *off* by more than 10 % are left out.")
        w("")
        w("| Task | Implementation | off | " + " | ".join(modes) + " |")
        w("|---|---|---:|" + "---:|" * len(modes))
        tm = {m: timing_table(jtimings, m) for m in modes}
        shown = 0
        for key in sorted(set().union(*[set(t) for t in tm.values()])):
            for i in sorted({i for m in modes for i in tm[m].get(key, {})}, key=impl_key):
                a0 = med(jt_off.get(key, {}).get(i, []))
                vals = [med(tm[m].get(key, {}).get(i, [])) for m in modes]
                if a0 and any(v and abs(v / a0 - 1) > 0.10 for v in vals):
                    w(f"| {key[0]} {key[1]} | {impl_name(i)} | {fms(a0)} | " + " | ".join(
                        f"{fms(v)} ({v / a0:.2f}×)" if v else "–" for v in vals) + " |")
                    shown += 1
        if not shown:
            w("| (no difference above 10 %) | | | |" + " |" * (len(modes) - 1))
        w("")

    # pgbench
    pg = read_csv(os.path.join(pdir, "pgbench.csv"))
    if pg:
        w(f"## Concurrency (pgbench), PostgreSQL {primary}, JIT off")
        w("")
        w(f"`pgbench -M prepared -T {meta['pgbench_seconds']}` with one statement per transaction; clients "
          f"= threads; client and server share the {meta['cpus_visible']} CPUs of the container "
          f"({'6 physical cores with 2 hardware threads each' if meta['cpus_visible'] == 12 else 'see above'}). "
          "Transactions per second (higher is better) and average latency.")
        w("")
        series = defaultdict(lambda: defaultdict(list))
        clients = sorted({int(r["clients"]) for r in pg})
        tab = defaultdict(dict)
        for r in pg:
            panel = f"Task {r['task']}: " + ("trivial function, 20 000 rows per transaction"
                                             if r["task"] == "1" else "1 000 key lookups per transaction")
            series[panel][r["impl"]].append((int(r["clients"]), float(r["tps"])))
            tab[(int(r["task"]), r["impl"])][int(r["clients"])] = (float(r["tps"]), float(r["latency_ms"]))
        w("| Task | Implementation | " + " | ".join(f"{c} clients: tps (latency ms)" for c in clients) + " |")
        w("|---|---|" + "---:|" * len(clients))
        for (tid, impl), d in sorted(tab.items(), key=lambda kv: (kv[0][0], impl_key(kv[0][1]))):
            w(f"| {tid} | {impl_name(impl)} | " + " | ".join(
                f"{d[c][0]:,.0f} ({d[c][1]:.2f})" if c in d else "–" for c in clients) + " |")
        w("")
        line_chart(series, f"pgbench throughput, PostgreSQL {primary}",
                   "Transactions per second against number of clients, one line per implementation, "
                   "one panel per task.", os.path.join(figdir, "pgbench.svg"), "clients", "transactions per second")
        w("![pgbench throughput](benchmarks/pgbench.svg)")
        w("")

    # startup
    st = read_csv(os.path.join(pdir, "startup.csv"))
    if st:
        w(f"## Task 11: start-up and compile cost, PostgreSQL {primary}")
        w("")
        w("Median ms (min–max). *New session*: connect (not timed), then the first call of a "
          "trivial function whose code is already compiled/cached, and the second call. *After "
          "CREATE*: in a new session, `CREATE FUNCTION` of a body that has never been compiled "
          "(a unique comment), then its first call. PL/Zig compiles in `CREATE FUNCTION` "
          "(validator) and stores the module in the cache, so the first call only loads it. "
          "*Cold Zig cache*: the compiler's own cache (`$PGDATA/plzig/pgsql_tmp.zig-cache`, "
          "the compiled standard library) deleted before each run — what the first PL/Zig "
          "function of a new cluster, or the first after that directory is lost, costs. For "
          "PL/Python and PL/Perl the *after CREATE* numbers include starting the interpreter, "
          "because the validator runs in a fresh session.")
        w("")
        sd = defaultdict(list)
        for r in st:
            sd[(r["impl"], r["kind"])].append(float(r["ms"]))
        kinds = [("new_session_first_call", "new session: first call"),
                 ("new_session_second_call", "new session: second call"),
                 ("after_create_create", "after CREATE: CREATE FUNCTION"),
                 ("after_create_first_call", "after CREATE: first call"),
                 ("after_create_cold_zig_cache_create", "cold Zig cache: CREATE FUNCTION"),
                 ("after_create_cold_zig_cache_first_call", "cold Zig cache: first call")]
        impls = [i for i in LANG_ORDER if any(k[0] == i for k in sd)]
        w("| | " + " | ".join(LANG_NAME[i] for i in impls) + " |")
        w("|---|" + "---:|" * len(impls))
        for k, label in kinds:
            if not any((i, k) in sd for i in impls):
                continue
            w(f"| {label} | " + " | ".join(
                f"{fms(med(sd[(i, k)]))} ({fms(min(sd[(i, k)]))}–{fms(max(sd[(i, k)]))})"
                if (i, k) in sd else "–" for i in impls) + " |")
        w("")

    # memory
    mem = read_csv(os.path.join(pdir, "memory.csv"))
    if mem:
        w(f"## Task 12: backend memory high-water mark, PostgreSQL {primary}")
        w("")
        w("`VmHWM` (peak resident set) of the backend from `/proc/<pid>/status`, in a fresh "
          "session: *before* is after loading the language (a trivial call) and reading the "
          "task's table once (so shared buffers already touched are in the baseline), *after* "
          "is after one run of the task; median of the runs, MB. The increase is the extra "
          "peak memory the task needed; it includes private memory of the executor, the "
          "language runtime and, for PL/Zig, the guest's linear memory.")
        w("")
        mm = defaultdict(lambda: defaultdict(list))
        for r in mem:
            mm[(int(r["task"]), r["variant"])][r["impl"]].append(
                (int(r["hwm_before_kb"]) / 1024, int(r["hwm_after_kb"]) / 1024))
        mimpls = sorted({i for d in mm.values() for i in d}, key=impl_key)
        w("| Task | " + " | ".join(impl_name(i) + ": before → after (+increase)" for i in mimpls) + " |")
        w("|---|" + "---:|" * len(mimpls))
        groups = []
        for key, d in sorted(mm.items()):
            cells, g = [], {}
            for i in mimpls:
                if i not in d:
                    cells.append("–")
                    continue
                b = med([x[0] for x in d[i]])
                a = med([x[1] for x in d[i]])
                inc = med([x[1] - x[0] for x in d[i]])
                g[i] = inc
                cells.append(f"{b:.1f} → {a:.1f} (+{inc:.1f})")
            w(f"| {key[0]}. {tasks[key[0]]['title']} | " + " | ".join(cells) + " |")
            groups.append((f"{key[0]} {key[1]}", g))
        w("")
        bar_chart(groups, mimpls, f"Peak memory increase per backend, PostgreSQL {primary}",
                  "Horizontal bars: increase of VmHWM during one run of the task, MB, per implementation.",
                  os.path.join(figdir, "memory.svg"), "MB (increase of VmHWM)")
        w("![Peak memory increase](benchmarks/memory.svg)")
        w("")

    # history (task 10 before/after)
    if args.history and os.path.isdir(args.history):
        w("## Task 10 before and after the copy changes")
        w("")
        w("Separate runs of task 10 only (same method, same machine, minutes apart), one per "
          "state of the code; median ms (interquartile range) for 20 calls with a 1 MB argument "
          "and a 1 MB result each.")
        w("")
        labels = sorted(x for x in os.listdir(args.history)
                        if os.path.isdir(os.path.join(args.history, x)))
        hv = {}
        for lab in labels:
            for v in os.listdir(os.path.join(args.history, lab)):
                p = os.path.join(args.history, lab, v, "timings.csv")
                if os.path.exists(p):
                    hv[lab] = timing_table(read_csv(p), "off")
                    dst = os.path.join(figdir, "task10-history", lab)
                    os.makedirs(dst, exist_ok=True)
                    shutil.copy(p, dst)
        desc = read_history_readme(args.history, os.path.join(figdir, "task10-history"))
        w("| State | " + " | ".join(f"{var}: PL/Zig" + " | " + f"{var}: PL/pgSQL" for var in ("text_1MB", "bytea_1MB")) + " |")
        w("|---|---:|---:|---:|---:|")
        for lab in labels:
            if lab not in hv:
                continue
            cells = []
            for var in ("text_1MB", "bytea_1MB"):
                for i in ("plzig", "plpgsql"):
                    xs = hv[lab].get((10, var), {}).get(i, [])
                    if xs:
                        q1, q3 = quart(xs)
                        cells.append(f"{fms(med(xs))} ({fms(q1)}–{fms(q3)})")
                    else:
                        cells.append("–")
            w(f"| {desc.get(lab, lab)} | " + " | ".join(cells) + " |")
        w("")

    # history (per-call and per-row changes: tasks 1, 7, 8 and pgbench)
    if args.call_history and os.path.isdir(args.call_history):
        call_history(args.call_history, os.path.join(figdir, "call-history"), w)

    # cross-version
    if len(versions) > 1:
        w("## Cross-version run")
        w("")
        w("Same tasks on the other versions (JIT off; see each version's meta.json for its run "
          "count). Median ms for PL/Zig and PL/pgSQL and their ratio; the full tables are in the CSV files.")
        w("")
        vt = {v: timing_table(read_csv(os.path.join(args.indir, v, "timings.csv")), "off") for v in versions}
        keys = sorted(set().union(*[set(t) for t in vt.values()]))
        w("| Task | " + " | ".join(f"{v}: PL/Zig / PL/pgSQL (ratio)" for v in versions) + " |")
        w("|---|" + "---:|" * len(versions))
        for key in keys:
            cells = []
            for v in versions:
                d = vt[v].get(key, {})
                z, p = med(d.get("plzig", [])), med(d.get("plpgsql", []))
                cells.append(f"{fms(z)} / {fms(p)} ({z / p:.2f})" if z and p else "–")
            w(f"| {key[0]} {key[1]} | " + " | ".join(cells) + " |")
        w("")
        sv = {v: read_csv(os.path.join(args.indir, v, "startup.csv")) for v in versions}
        if all(sv.values()):
            w("Task 11 on each version, PL/Zig, median ms:")
            w("")
            w("| | " + " | ".join(versions) + " |")
            w("|---|" + "---:|" * len(versions))
            for k, label in [("new_session_first_call", "new session: first call"),
                             ("after_create_create", "CREATE FUNCTION (warm Zig cache)"),
                             ("after_create_cold_zig_cache_create", "CREATE FUNCTION (cold Zig cache)")]:
                w(f"| {label} | " + " | ".join(
                    fms(med([float(r["ms"]) for r in sv[v] if r["impl"] == "plzig" and r["kind"] == k]))
                    for v in versions) + " |")
            w("")

    # gate
    w("## Correctness gate")
    w("")
    for v in versions:
        g = read_csv(os.path.join(args.indir, v, "gate.csv"))
        bad = [r for r in g if r["result"] != "PASS"]
        w(f"* {v}: {len(g)} results compared against PL/pgSQL, "
          f"{'all identical' if not bad else str(len(bad)) + ' DIFFERENT'}.")
    w("")
    with open(os.path.join(args.out, "benchmarks.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"wrote {os.path.join(args.out, 'benchmarks.md')}")


if __name__ == "__main__":
    main()
