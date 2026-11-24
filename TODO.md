# PL/Zig — pending tasks

Open items that are not yet done. Completed work is recorded in PLAN.md
(Deviations).

- **Regenerate the benchmarks for the current supported set.** After the
  2026-11-24 version change (PLAN.md deviation 63), `doc/benchmarks.md`
  and `doc/benchmarks/` still carry 14.25 and 19rc2 figures. Re-run the
  benchmark suite (`bench/run.sh`, the publish recipe in `bench/README.md`)
  for **15.20, 16.16, 17.12, 18.7, 19.0** — dropping 14.25 and replacing
  19rc2 with 19.0 — and regenerate the report. 19.0 is a fresh major, so
  its numbers should be measured, not copied from 19rc2.
