--
-- leaks: PL/Zig memory contexts stay flat across 10000 calls of each of
-- several function shapes (after a warm-up), including calls that fail and
-- are caught.  Descriptors and child processes are checked by
-- docker/leak-checks.sh, which can look at the backend from outside.
--
\set VERBOSITY terse

CREATE FUNCTION lk_mem() RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(total_bytes), 0)::bigint FROM pg_backend_memory_contexts WHERE name LIKE 'PL/Zig%'
$$;
CREATE TABLE lk_t AS SELECT g AS x, md5(g::text) AS t FROM generate_series(1, 100) g;

CREATE FUNCTION lk_scalar(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    return x + 1;
$$;
-- text-I/O argument and result (a domain over numeric: domains are passed
-- as text), via the arena
CREATE DOMAIN lk_num AS numeric;
CREATE FUNCTION lk_text(n lk_num) RETURNS lk_num LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{s}.5", .{n orelse return null});
$$;
-- numeric in the wire format: numeric_send for the argument, numeric_recv
-- for the result, and a host call (numeric_op) in between
CREATE FUNCTION lk_numeric(n numeric) RETURNS numeric LANGUAGE plzig AS $$
    const half = plzig.Numeric{ .wire = &.{ 0, 1, 0xff, 0xff, 0, 0, 0, 1, 0x13, 0x88 } }; // 0.5
    return try (n orelse return null).add(half);
$$;
CREATE FUNCTION lk_spi(x int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    const r = try plzig.spi.execute("SELECT count(*), max(t) FROM lk_t WHERE x <= $1::int",
        &.{try std.fmt.bufPrint(&buf, "{d}", .{x})});
    const row = try r.row(0);
    _ = try r.get(0, 1);
    return try row.get(i64, 0);
$$;
CREATE FUNCTION lk_cursor(x int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT x, t FROM lk_t", &.{});
    var n: i64 = 0;
    while (try c.next()) |row| {
        n += try row.get(i32, 0);
        if (n > x) break; // left open: closed by the host at the end of the call
    }
    return n;
$$;
CREATE FUNCTION lk_prepared(x int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    if (plan == null) plan = try plzig.spi.prepare("SELECT t FROM lk_t WHERE x = $1", &.{.int4});
    const r = try plan.?.execute(.{x});
    _ = try (try r.row(0)).get([]const u8, 0);
    return @intCast(r.rows);
}
var plan: ?plzig.spi.Plan = null;
fn unused() void {
$$;
CREATE FUNCTION lk_fail(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT x FROM lk_t", &.{});
    _ = try c.next();
    if (@mod(x, 2) == 0) plzig.raise("even {d}", .{x});
    return x;
$$;
CREATE FUNCTION lk_run(f text, n int) RETURNS void LANGUAGE plpgsql AS $d$
DECLARE r text;
BEGIN
  FOR i IN 1..n LOOP
    BEGIN
      EXECUTE format('SELECT %s($1)::text', f) INTO r USING i % 100 + 1;
    EXCEPTION WHEN raise_exception THEN NULL;
    END;
  END LOOP;
END $d$;

-- warm up every shape (modules loaded, instances cached, plans prepared)
SELECT lk_run(f, 200) FROM unnest(ARRAY['lk_scalar', 'lk_text', 'lk_numeric', 'lk_spi', 'lk_cursor', 'lk_prepared', 'lk_fail']) f;
SELECT lk_text(NULL), lk_text(41), lk_numeric(NULL), lk_numeric(41);

SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_scalar', 10000);
SELECT lk_mem() - :m0 AS growth_scalar;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_text', 10000);
SELECT lk_mem() - :m0 AS growth_text;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_numeric', 10000);
SELECT lk_mem() - :m0 AS growth_numeric;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_spi', 10000);
SELECT lk_mem() - :m0 AS growth_spi;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_cursor', 10000);
SELECT lk_mem() - :m0 AS growth_cursor;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_prepared', 10000);
SELECT lk_mem() - :m0 AS growth_prepared;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_fail', 10000);
-- (every second call fails: those instances are destroyed, never kept)
SELECT lk_mem() - :m0 <= 0 AS no_growth_fail;
-- a plain loop in one statement (no subtransactions)
SELECT lk_mem() AS m0 \gset
SELECT sum(lk_scalar(g)) + sum(lk_text(g)) + sum(lk_numeric(g)) FROM generate_series(1, 10000) g;
SELECT lk_mem() - :m0 AS growth_one_statement;

-- the call contexts belong to the instance and are reset when a call
-- returns: a call that needed megabytes of host memory (a 1 MB value
-- detoasted for a typed row, the same value through the text interface)
-- leaves nothing behind in the kept instance
CREATE FUNCTION lk_callmem() RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(total_bytes), 0)::bigint FROM pg_backend_memory_contexts
   WHERE name IN ('PL/Zig call', 'PL/Zig SPI scratch', 'PL/Zig row', 'PL/Zig row descriptor', 'PL/Zig cursor')
$$;
CREATE TABLE lk_big_t (t text);
INSERT INTO lk_big_t SELECT repeat('x', 1000000);
CREATE FUNCTION lk_big(measure bool) RETURNS bigint STRICT LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT t FROM lk_big_t", &.{});
    const row = try r.row(0);
    const v = try row.get([]const u8, 0);
    const t = (try r.get(0, 0)).?;
    if (v.len != t.len) return error.Mismatch;
    if (!measure) return @intCast(t.len);
    // host memory of this call, seen while it runs (a cursor does not
    // replace the last result, so the row and the cached value are alive)
    var c = try plzig.spi.open("SELECT sum(total_bytes)::int8 FROM pg_backend_memory_contexts WHERE name IN ('PL/Zig call', 'PL/Zig SPI scratch', 'PL/Zig row', 'PL/Zig row descriptor', 'PL/Zig cursor')", &.{});
    return try (try c.next()).?.get(i64, 0);
$$;
SET plzig.instance_cache_max_memory = '64MB';
SELECT lk_big(false);
SELECT lk_callmem() AS m0 \gset
SELECT lk_big(true) - :m0 > 2000000 AS grew_during_call;
SELECT lk_callmem() - :m0 AS growth_after_big_call;
RESET plzig.instance_cache_max_memory;

-- the whole backend does not grow either (PL/Zig memory hangs below
-- TopMemoryContext and the per-query contexts)
SELECT sum(total_bytes) AS t0 FROM pg_backend_memory_contexts \gset
SELECT lk_run(f, 3000) FROM unnest(ARRAY['lk_scalar', 'lk_text', 'lk_numeric', 'lk_spi', 'lk_cursor', 'lk_prepared', 'lk_fail']) f;
SELECT sum(total_bytes) - :t0 < 256 * 1024 AS backend_flat FROM pg_backend_memory_contexts;

DROP TABLE lk_t CASCADE;
DROP FUNCTION lk_text(lk_num);
DROP DOMAIN lk_num;
DROP TABLE lk_big_t;
