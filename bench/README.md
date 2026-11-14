# PL/Zig benchmark suite

Compares PL/Zig with SQL, PL/pgSQL, PL/Python (`plpython3u`) and PL/Perl
(`plperl`) on the twelve tasks of PLAN.md §13 D. The published results and
their discussion are in [`doc/benchmarks.md`](../doc/benchmarks.md).

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
bench/run.sh --versions "14.25 19rc2" --jit off --runs 10 --clients ""
bench/run.sh --tasks 1,7,10              # a subset (11 = start-up, 12 = memory)
bench/run.sh --report-only build/bench/<run> --publish   # rewrite doc/benchmarks.md
bench/run.sh --help                      # every option
```

Each run goes to `build/bench/<timestamp>/<version>/` (CSV files, `meta.json`
with the hardware, versions and settings, the server log) and a report is
rendered into `build/bench/<timestamp>/report/`; `--publish` writes it to
`doc/benchmarks.md` and `doc/benchmarks/` (SVG charts, CSV copies) instead.
The exit status is non-zero if a build, a run or the correctness gate fails.

The published report was produced by

```sh
bench/run.sh --cpus 0-11 --clients 1,2,4,8 --out build/bench/pg18
bench/run.sh --cpus 0-11 --versions "14.25 19rc2" --jit off --runs 10 --clients "" --out build/bench/xver
# combined: build/bench/pg18 plus the two version directories of xver
bench/run.sh --report-only build/bench/pg18 --history build/bench/t10-history --publish
```

where `t10-history/` held three task-10-only runs (`--tasks 10 --jit off
--clients ""`) of the code before and after the changes described in the
report.

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
  `execute` + `fetchall`. Reported: median and interquartile range.
* JIT: every task with `jit = off` and with `jit = on` (server default
  thresholds), set per session.
* pgbench (tasks 1 and 7): `-M prepared -T <s>`, clients = threads, JIT off,
  after a 1-second warm-up.
* Task 11 and task 12 are described in `tasks/11_startup/README` and in the
  report.
