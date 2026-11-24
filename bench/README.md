# PL/Zig benchmark suite

Compares PL/Zig with SQL, PL/pgSQL, PL/Python (`plpython3u`) and PL/Perl
(`plperl`) on the twelve tasks of PLAN.md §13 D, plus task 13 (the
natively mapped types: numeric, jsonb, timestamp; PLAN.md §12 item 12). The
published results and their discussion are in [`doc/benchmarks.md`](../doc/benchmarks.md).

**Benchmark only.** PL/Python and PL/Perl are installed only in the image
built from `bench/Dockerfile`. They are not a build, test or runtime
dependency of PL/Zig, do not appear in `docker/Dockerfile*`, the Makefile or
any package metadata, and nothing under `bench/` is installed by
`make install` (`bench/` is also excluded from the test images by
`.dockerignore`). `docker/security-checks.sh` verifies that the test image
contains neither language nor `bench/`.

## Running

Docker is the only requirement; nothing is installed on the host and nothing
is mounted into the containers (files go in and out with `docker cp`).

```sh
bench/run.sh --quick                     # smoke test: small data, 5 runs, minutes
bench/run.sh --cpus 0-11                 # PG 18.7, full size, JIT off and on, pgbench
bench/run.sh --versions "15.20 19.0" --jit off --runs 10 --clients ""
bench/run.sh --tasks 1,7,10              # a subset (11 = start-up, 12 = memory)
bench/run.sh --report-only build/bench/<run> --publish   # rewrite doc/benchmarks.md
bench/run.sh --help                      # every option
```

Each run goes to `build/bench/<timestamp>/<version>/` (CSV files, `meta.json`
with the hardware, versions and settings, the server log) and a report is
rendered into `build/bench/<timestamp>/report/`; `--publish` writes it to
`doc/benchmarks.md` and `doc/benchmarks/` (SVG charts, CSV copies) instead.
The exit status is non-zero if a build, a run or the correctness gate fails.

The published report was produced by (last done 2026-11-19, with `v62-`
directory names; the history directories are those of phase D). `--pin 8`
pins every single-session timed backend to one performance core, so the
build-to-build and core-to-core variation of *How much the numbers vary* in
the report does not also move the numbers between tasks within one run:

```sh
bench/run.sh --cpus 0-11 --pin 8 --clients 1,2,4,8 --out build/bench/v62-pg18
bench/run.sh --cpus 0-11 --pin 8 --versions "15.20 19.0" --jit off --runs 10 --clients "" --out build/bench/v62-xver
bench/run.sh --cpus 0-11 --pin 8 --tasks 1,2,8 --jit off,on,force --clients "" --out build/bench/v62-jit
# combined: build/bench/v62-pg18 plus the two version directories of v62-xver,
# and build/bench/v62-jit/18.7 as v62-pg18/jit/18.7
bench/run.sh --report-only build/bench/v62-pg18 --history build/bench/t10-history \
    --call-history build/bench/abc-history --publish
```

where `t10-history/` held three task-10-only runs (`--tasks 10 --jit off
--clients ""`) of the code before and after the copy changes of phase D, and
`abc-history/` four runs of tasks 1, 7 and 8 with pgbench (`--tasks 1,7,8
--jit off --clients 1,2,4,8`) of the code before the per-call/per-row
changes and after each of them (both described in the report; each
directory has a README naming the states). The CSV files of both are kept
under `doc/benchmarks/task10-history/` and `doc/benchmarks/call-history/`.

`--profile "QUERY"` sets up the same cluster and records a `perf` profile of
one backend running the query (output `perf-report.txt`); that mode runs the
container as root with `seccomp=unconfined` and SELinux labels disabled,
which perf needs.

## Layout

| Path | What |
|------|------|
| `run.sh` | Host entry point: builds `plzig-test:<V>` (docker/Dockerfile) and `plzig-bench:<V>`, runs the driver in a container named `plzig-bench-<V>-<pid>`, copies the results out, renders the report. |
| `Dockerfile` | `FROM plzig-test:<V>` + `postgresql-plpython3-<major>` and `postgresql-plperl-<major>` (PGDG, pinned to the server version), `python3-psycopg2`, `linux-perf`. |
| `driver.py` | Runs in the container: cluster, data (`setup.sql`), functions, correctness gate, timings, pgbench, start-up, memory, metadata. |
| `report.py` | CSV → `benchmarks.md` + SVG charts (standard library only). |
| `notes.md` | The hand-written analysis inserted into the report. |
| `profile-in-container.sh` | The perf side of `--profile`. |
| `variation.sh`, `variation.py` | Not part of a normal run: measure how much the compute tasks (2 and 5) vary run to run, between CPU cores, and between builds of `plzig.so` placed differently in memory (`perf stat`: user-space cycles, instructions, branches, branch misses, and the performance cores' front-end events). The findings are the report's *How much the numbers vary*. `bench/variation.sh --help`. |
| `tasks/NN_name/` | `task.json` (queries, sizes, variants) and one file per language: `sql.sql`, `plpgsql.sql`, `plpython.sql`, `plperl.sql`, `plzig.sql`. |

A task variant names a function prefix (`t07`); every function
`<prefix>_<impl>` that exists is an implementation (`t07_plzig`,
`t07_plzig_exec`, ...). The query template gets `{fn}` and the task's size
parameters.

## Method

* One throw-away cluster per version, `initdb --no-locale -E UTF8`; the same
  `postgresql.conf` additions for every language (see `SERVER_CONF` in
  `driver.py` and the report); PL/Zig GUCs at their defaults.
* **Correctness gate first**: every implementation's result (or the task's
  `check` query) must equal PL/pgSQL's, or the run stops with a failure.
* Per task variant: each implementation in its own session; `warmup`
  untimed runs each, then `runs` rounds in which every implementation runs
  once, the order rotated every round; client-side wall clock around
  `execute` + `fetchall`. Reported: median and interquartile range. With
  `--pin CPU` each of these backends is pinned to that one core (the cores of
  one machine differ in speed; see the report's *How much the numbers vary*).
* JIT: every task with `jit = off` and with `jit = on` (server default
  thresholds), set per session.
* pgbench (tasks 1 and 7): `-M prepared -T <s>`, clients = threads, JIT off,
  after a 1-second warm-up.
* Task 11 and task 12 are described in `tasks/11_startup/README` and in the
  report.
