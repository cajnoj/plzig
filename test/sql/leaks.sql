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
CREATE TABLE lk_t AS SELECT g AS x, left(encode(sha256(g::text::bytea), 'hex'), 32) AS t FROM generate_series(1, 100) g;

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
-- time zone conversions by the host (tz_convert)
CREATE FUNCTION lk_tz(x int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    const t: plzig.TimestampTz = .{ .usecs = @as(i64, x) * 86_400_000_000 };
    return t.toLocal("Europe/Berlin").usecs - t.toLocal(null).usecs;
$$;
-- jsonb: the on-disk layout copied in, read in place, JSON text out (jsonb_in)
CREATE FUNCTION lk_jsonb(x int) RETURNS jsonb STRICT LANGUAGE plzig AS $$
    const doc: plzig.Jsonb = .{ .bytes = &.{ 1, 0, 0, 0x20, 1, 0, 0, 0x80, 0x0b, 0, 0, 0x10, 'a', 0, 0, 0, 0x20, 0, 0, 0, 0, 0x80, 1, 0 } }; // {"a": 1}
    return if (x >= 0) try doc.toJsonText() else null;
$$;
CREATE FUNCTION lk_jsonb_arg(j jsonb) RETURNS int STRICT LANGUAGE plzig AS $$
    return @intCast((try (try j.root()).object.get("k")).?.string.len);
$$;
-- rows: a composite result built by the host from checked fields, and a
-- composite argument converted per call
CREATE TYPE lk_pair AS (a int, t text, n numeric(8,2), v varchar(10));
CREATE FUNCTION lk_row(x int) RETURNS lk_pair STRICT LANGUAGE plzig AS $$
    return .{ .a = x, .t = try std.fmt.allocPrint(plzig.allocator, "row {d}", .{x}),
              .n = try plzig.Numeric.fromI64(x), .v = "abc" };
$$;
CREATE FUNCTION lk_rowarg(p lk_pair) RETURNS int STRICT LANGUAGE plzig AS $$
    const t: []const u8 = p.t orelse "";
    return (p.a orelse 0) + @as(i32, @intCast(t.len));
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
SELECT lk_run(f, 200) FROM unnest(ARRAY['lk_scalar', 'lk_text', 'lk_numeric', 'lk_tz', 'lk_jsonb', 'lk_row', 'lk_spi', 'lk_cursor', 'lk_prepared', 'lk_fail']) f;
SELECT sum(lk_rowarg(lk_row(g))) FROM generate_series(1, 200) g;
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
SELECT lk_run('lk_tz', 10000);
SELECT lk_mem() - :m0 AS growth_tz;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_jsonb', 10000);
SELECT lk_mem() - :m0 AS growth_jsonb;
SELECT lk_mem() AS m0 \gset
SELECT lk_run('lk_row', 10000);
SELECT lk_mem() - :m0 AS growth_row;
SELECT lk_mem() AS m0 \gset
SELECT sum(lk_rowarg(lk_row(g))) FROM generate_series(1, 10000) g;
SELECT lk_mem() - :m0 AS growth_rowarg;
-- sets (a tuplestore per call), triggers (NEW in, a modified row out), and
-- a procedure that commits (called by a PL/pgSQL loop: non-atomic CALLs)
CREATE FUNCTION lk_srf(n int) RETURNS SETOF int STRICT LANGUAGE plzig AS $$
    for (0..@intCast(n)) |k| returnNext(@intCast(k));
$$;
CREATE TABLE lk_trg_t (a int, b text);
CREATE FUNCTION lk_trgf() RETURNS trigger LANGUAGE plzig AS $$
    const r = (try tg.new(struct { a: ?i32 })).?;
    return try tg.modify(.{ .b = if (@mod(r.a orelse 0, 2) == 0) "even" else "odd" });
$$;
CREATE TRIGGER lk_trg BEFORE INSERT ON lk_trg_t FOR EACH ROW EXECUTE FUNCTION lk_trgf();
CREATE TABLE lk_proc_t (n int);
CREATE PROCEDURE lk_proc(n int) LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT 1", &.{});
    _ = try c.next();
    var buf: [16]u8 = undefined;
    _ = try plzig.spi.execute("INSERT INTO lk_proc_t VALUES ($1::int)", &.{try std.fmt.bufPrint(&buf, "{d}", .{n.?})});
    plzig.commit();
    _ = try plzig.spi.execute("DELETE FROM lk_proc_t", &.{});
    plzig.commit();
$$;
SELECT sum(x) FROM generate_series(1, 200) g, lk_srf(10) x;
INSERT INTO lk_trg_t SELECT g FROM generate_series(1, 200) g;
DO $$ BEGIN FOR i IN 1..100 LOOP CALL lk_proc(i); END LOOP; END $$;
SELECT lk_mem() AS m0 \gset
SELECT sum(x) FROM generate_series(1, 10000) g, lk_srf(10) x;
SELECT lk_mem() - :m0 AS growth_srf;
SELECT lk_mem() AS m0 \gset
INSERT INTO lk_trg_t SELECT g FROM generate_series(1, 10000) g;
SELECT lk_mem() - :m0 AS growth_trigger, count(*) FILTER (WHERE b = 'even') AS even FROM lk_trg_t;
SELECT lk_mem() AS m0 \gset
DO $$ BEGIN FOR i IN 1..2000 LOOP CALL lk_proc(i); END LOOP; END $$;
SELECT lk_mem() - :m0 AS growth_proc, count(*) AS left_over FROM lk_proc_t;
-- a jsonb argument that is compressed and stored out of line, read 2000 times
CREATE TABLE lk_jdoc AS SELECT jsonb_build_object('k', repeat('x', 100000), 'pad', (SELECT jsonb_agg(g) FROM generate_series(1, 5000) g)) AS j;
SELECT sum(lk_jsonb_arg(j)) FROM lk_jdoc;
SELECT lk_mem() AS m0 \gset
SELECT sum(lk_jsonb_arg(j)) FROM lk_jdoc, generate_series(1, 2000);
SELECT lk_mem() - :m0 AS growth_jsonb_arg;
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
SELECT lk_run(f, 3000) FROM unnest(ARRAY['lk_scalar', 'lk_text', 'lk_numeric', 'lk_tz', 'lk_jsonb', 'lk_spi', 'lk_cursor', 'lk_prepared', 'lk_fail']) f;
SELECT sum(total_bytes) - :t0 < 256 * 1024 AS backend_flat FROM pg_backend_memory_contexts;

DROP TABLE lk_t CASCADE;
DROP TABLE lk_jdoc;
DROP FUNCTION lk_text(lk_num);
DROP DOMAIN lk_num;
DROP TABLE lk_big_t;
