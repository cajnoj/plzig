-- Per-call cost of a small PL/Zig helper called (i) compiled in with
-- //#use and (ii) through plzig.spi (a prepared statement kept in a global,
-- typed parameter and result), with (iii) the same code written inline as
-- the baseline.  Not part of bench/run.sh: a standalone note
-- (doc/benchmarks.md, "Compiled-in calls").
--
--   psql -X -f bench/use-call.sql      (in a database with the extension)
--
-- Each loop runs the helper n times; per-call cost = time / n (the loop
-- itself is a few instructions; the inline baseline shows what they cost).
\set ON_ERROR_STOP on
\timing on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS bench_use CASCADE;
CREATE SCHEMA bench_use;
RESET client_min_messages;

-- the helper: a few arithmetic steps that do not fold away
CREATE FUNCTION bench_use.mix(x bigint) RETURNS bigint STRICT IMMUTABLE LANGUAGE plzig AS $$
    var h: u64 = @bitCast(x);
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    return @bitCast(h);
$$;

-- (iii) inline baseline: the same steps in the loop
CREATE FUNCTION bench_use.loop_inline(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var acc: i64 = 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        var h: u64 = @bitCast(acc);
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        acc = @bitCast(h);
    }
    return acc;
$$;

-- (i) compiled in
CREATE FUNCTION bench_use.loop_use(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
//#use bench_use.mix(bigint) as mix
    var acc: i64 = 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) acc = (try mix.call(acc)).?;
    return acc;
$$;

-- (ii) through SPI
CREATE FUNCTION bench_use.loop_spi(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
    };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT bench_use.mix($1)", &.{.int8});
    var acc: i64 = 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const r = try S.plan.?.execute(.{acc});
        acc = try (try r.row(0)).get(i64, 0);
    }
    return acc;
$$;

-- warm-up (load the modules, prepare the plan): all three must agree;
-- then three timed runs of each, one million calls
SELECT bench_use.loop_inline(1000) = bench_use.loop_use(1000) AND
       bench_use.loop_use(1000) = bench_use.loop_spi(1000) AS same_result;
SELECT bench_use.loop_inline(1000000);
SELECT bench_use.loop_inline(1000000);
SELECT bench_use.loop_inline(1000000);
SELECT bench_use.loop_use(1000000);
SELECT bench_use.loop_use(1000000);
SELECT bench_use.loop_use(1000000);
SELECT bench_use.loop_spi(1000000);
SELECT bench_use.loop_spi(1000000);
SELECT bench_use.loop_spi(1000000);
