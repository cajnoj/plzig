--
-- usage: PL/Zig functions in indexes, generated columns, constraints and
-- defaults; called from PL/pgSQL exception blocks; in parallel workers;
-- deep SQL-level recursion; transaction control; replacing or dropping a
-- function while it runs
--
\set VERBOSITY terse

CREATE FUNCTION u_norm(t text) RETURNS text STRICT IMMUTABLE LANGUAGE plzig AS $$
    const out = try plzig.allocator.alloc(u8, t.len);
    for (t, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
$$;
CREATE FUNCTION u_is_even(x int) RETURNS boolean STRICT IMMUTABLE LANGUAGE plzig AS $$
    return @mod(x, 2) == 0;
$$;
CREATE FUNCTION u_next_id() RETURNS int VOLATILE LANGUAGE plzig AS $$
    n += 1;
    return n;
}
var n: i32 = 100;
fn unused() void {
$$;
CREATE TABLE u_items (
  id int DEFAULT u_next_id(),
  name text,
  lname text GENERATED ALWAYS AS (u_norm(name)) STORED,
  v int CHECK (u_is_even(v)));
CREATE UNIQUE INDEX u_items_lname ON u_items (u_norm(name));
CREATE INDEX u_items_even ON u_items (v) WHERE u_is_even(v);
INSERT INTO u_items (name, v) VALUES ('Alice', 2), ('BOB', 4);
SELECT * FROM u_items ORDER BY id;
INSERT INTO u_items (name, v) VALUES ('alice', 6);
INSERT INTO u_items (name, v) VALUES ('carol', 3);
UPDATE u_items SET name = 'Robert' WHERE name = 'BOB';
SELECT * FROM u_items ORDER BY id;
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT id FROM u_items WHERE u_norm(name) = 'robert';
SELECT id FROM u_items WHERE u_norm(name) = 'robert';
RESET enable_seqscan;
REINDEX TABLE u_items;
-- an index expression that fails makes the statement fail
CREATE FUNCTION u_strict_len(t text) RETURNS int STRICT IMMUTABLE LANGUAGE plzig AS $$
    if (t.len > 5) plzig.raise("too long: {s}", .{t});
    return @intCast(t.len);
$$;
CREATE INDEX u_items_len ON u_items (u_strict_len(name));
CREATE INDEX u_items_len ON u_items (u_strict_len(lname)) WHERE length(name) <= 5;
INSERT INTO u_items (name, v) VALUES ('toolong', 8);
INSERT INTO u_items (name, v) VALUES ('Dan', 8);
SELECT count(*) FROM u_items;
DROP TABLE u_items;

--
-- PL/pgSQL exception blocks: every kind of PL/Zig error is catchable, many
-- times in a row, and does not leak
--
CREATE FUNCTION u_fail(kind int) RETURNS int STRICT LANGUAGE plzig AS $$
    switch (kind) {
        0 => return 42,
        1 => plzig.raise("raised {d}", .{kind}),
        2 => return error.ZigError,
        3 => @panic("panicked"),
        4 => {
            const zero: i32 = kind - 4;
            return @divTrunc(10, zero);
        },
        5 => _ = try plzig.spi.execute("SELECT 1/0", &.{}),
        6 => _ = try plzig.spi.execute("SELECT * FROM no_such_table", &.{}),
        else => {},
    }
    return -1;
$$;
DO $d$
DECLARE
  r int;
  counts int[] := array_fill(0, ARRAY[7]);
  st text;
BEGIN
  FOR i IN 1..1400 LOOP
    BEGIN
      r := u_fail(i % 7);
      counts[1] := counts[1] + 1;
    EXCEPTION
      WHEN raise_exception THEN counts[2] := counts[2] + 1;
      WHEN external_routine_exception THEN
        GET STACKED DIAGNOSTICS st = MESSAGE_TEXT;
        IF st LIKE '%ZigError%' THEN counts[3] := counts[3] + 1;
        ELSIF st LIKE '%panicked%' THEN counts[4] := counts[4] + 1;
        ELSE counts[5] := counts[5] + 1;
        END IF;
      WHEN division_by_zero THEN counts[6] := counts[6] + 1;
      WHEN undefined_table THEN counts[7] := counts[7] + 1;
    END;
  END LOOP;
  RAISE NOTICE 'ok/raise/error/panic/trap/spi-div/spi-table: %', counts;
END $d$;
-- the function keeps working afterwards, in the same transaction too
SELECT u_fail(0);
BEGIN;
SAVEPOINT s;
SELECT u_fail(1);
ROLLBACK TO s;
SELECT u_fail(0);
COMMIT;
-- state written by SPI before the error is rolled back with the subtransaction
CREATE TABLE u_log (x int);
CREATE FUNCTION u_write_then_fail(x int) RETURNS int STRICT VOLATILE LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    _ = try plzig.spi.execute("INSERT INTO u_log VALUES ($1::int)", &.{try std.fmt.bufPrint(&buf, "{d}", .{x})});
    if (x < 0) plzig.raise("negative", .{});
    return x;
$$;
DO $d$
BEGIN
  PERFORM u_write_then_fail(1);
  BEGIN
    PERFORM u_write_then_fail(-1);
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  PERFORM u_write_then_fail(2);
END $d$;
SELECT * FROM u_log ORDER BY x;
DROP TABLE u_log;

--
-- parallel workers: PARALLEL SAFE functions run in the workers (and are
-- compiled or loaded there); a function that lies about being parallel safe
-- fails cleanly when it writes
--
CREATE TABLE u_par AS SELECT g AS x FROM generate_series(1, 20000) g;
ANALYZE u_par;
CREATE FUNCTION u_psafe(x int) RETURNS int STRICT IMMUTABLE PARALLEL SAFE LANGUAGE plzig AS $$
    return x * 2;
$$;
CREATE FUNCTION u_pid() RETURNS int STABLE PARALLEL SAFE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT pg_backend_pid()", &.{});
    return try std.fmt.parseInt(i32, (try r.get(0, 0)).?, 10);
$$;
CREATE FUNCTION u_pwrite(x int) RETURNS int STRICT VOLATILE PARALLEL SAFE LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("CREATE TEMP TABLE IF NOT EXISTS u_nope (x int)", &.{});
    return x;
$$;
SELECT pg_backend_pid() AS leader_pid \gset
SET max_parallel_workers_per_gather = 2;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET parallel_leader_participation = off;
EXPLAIN (COSTS OFF) SELECT sum(u_psafe(x)) FROM u_par;
SELECT sum(u_psafe(x)) FROM u_par;
SELECT bool_and(u_pid() <> :leader_pid) AS ran_in_workers FROM u_par;
-- a function compiled for the first time inside the workers
CREATE FUNCTION u_psafe_new(x int) RETURNS int STRICT IMMUTABLE PARALLEL SAFE LANGUAGE plzig AS $$
    return x * 3 + 1;
$$;
SELECT plzig_cache_clear() >= 0 AS cleared;
SELECT sum(u_psafe_new(x)) FROM u_par;
SELECT sum(u_pwrite(x)) FROM u_par;
RESET max_parallel_workers_per_gather;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET parallel_leader_participation;
DROP TABLE u_par;

--
-- SQL-level recursion through SPI: each level is a fresh instance; the
-- depth is bounded by max_stack_depth, and running into it is a clean error
--
CREATE FUNCTION u_rec(n int) RETURNS int STRICT LANGUAGE plzig AS $$
    if (n <= 0) return 0;
    var buf: [16]u8 = undefined;
    const r = try plzig.spi.execute("SELECT u_rec($1::int)", &.{try std.fmt.bufPrint(&buf, "{d}", .{n - 1})});
    return 1 + try std.fmt.parseInt(i32, (try r.get(0, 0)).?, 10);
$$;
SELECT u_rec(50);
SELECT u_rec(1000000);
SELECT u_rec(3) AS alive;

--
-- transaction control is not available to SQL run by PL/Zig
--
CREATE TABLE u_tx (x int);
CREATE PROCEDURE u_commits() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO u_tx VALUES (1); COMMIT; END $$;
CREATE PROCEDURE u_calls() LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("CALL u_commits()", &.{});
$$;
CALL u_calls();
DO $$ _ = try plzig.spi.execute("COMMIT", &.{}); $$ LANGUAGE plzig;
DO $$ _ = try plzig.spi.execute("SAVEPOINT a", &.{}); $$ LANGUAGE plzig;
SELECT count(*) FROM u_tx;
DROP TABLE u_tx;

--
-- replacing or dropping a function from inside its own call
--
CREATE FUNCTION u_selfrep(n int) RETURNS int STRICT VOLATILE LANGUAGE plzig AS $$
    if (n == 0) {
        _ = try plzig.spi.execute("CREATE OR REPLACE FUNCTION u_selfrep(n int) RETURNS int STRICT VOLATILE LANGUAGE plzig AS 'return n + 1000;'", &.{});
        const r = try plzig.spi.execute("SELECT u_selfrep(5)", &.{});
        return try std.fmt.parseInt(i32, (try r.get(0, 0)).?, 10);
    }
    return n;
$$;
SELECT u_selfrep(0) AS inner_new, u_selfrep(1) AS outer_new;
CREATE FUNCTION u_selfdrop() RETURNS int VOLATILE LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("DROP FUNCTION u_selfdrop()", &.{});
    return 7;
$$;
SELECT u_selfdrop();
SELECT u_selfdrop();

--
-- handle tables growing while in use: 10 cursors open at once in one call
-- (the table starts with 4 entries), 20 prepared statements in one instance
-- (starts with 8); every handle keeps working after the tables moved
--
CREATE FUNCTION u_many_cursors() RETURNS text LANGUAGE plzig AS $$
    var cs: [10]plzig.spi.Cursor = undefined;
    var buf: [16]u8 = undefined;
    for (&cs, 0..) |*c, i| {
        c.* = try plzig.spi.open("SELECT g * $1::int FROM generate_series(1, 3) g",
            &.{try std.fmt.bufPrint(&buf, "{d}", .{i + 1})});
    }
    var sum: i64 = 0;
    // interleaved: one row of every cursor, three times
    for (0..3) |_| {
        for (&cs) |*c| sum += try (try c.next()).?.get(i32, 0);
    }
    for (&cs) |*c| {
        if (try c.next() != null) return error.TooManyRows;
    }
    return try std.fmt.allocPrint(plzig.allocator, "sum {d}", .{sum});
$$;
SELECT u_many_cursors();
CREATE FUNCTION u_many_plans(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var plans: [20]plzig.spi.Plan = undefined;
    const count: usize = @intCast(n);
    for (plans[0..count], 0..) |*p, i| {
        _ = i;
        p.* = try plzig.spi.prepare("SELECT $1::bigint * 2", &.{.int8});
    }
    var sum: i64 = 0;
    for (plans[0..count], 0..) |p, i| {
        const r = try p.execute(.{@as(i64, @intCast(i))});
        sum += try (try r.row(0)).get(i64, 0);
    }
    for (plans[0..count]) |*p| p.free();
    return sum;
$$;
SELECT u_many_plans(20), u_many_plans(20);

--
-- messages at every level the SDK offers; an SQL syntax error in guest SQL
-- points into the guest's statement
--
CREATE FUNCTION u_levels() RETURNS void LANGUAGE plzig AS $$
    plzig.debug("level {s}", .{"debug"});
    plzig.print(.log, "level {s}", .{"log"});
    plzig.info("level {s}", .{"info"});
    plzig.notice("level {s}", .{"notice"});
    plzig.warning("level {s}", .{"warning"});
$$;
SET client_min_messages = debug1;
SELECT u_levels();
RESET client_min_messages;
CREATE FUNCTION u_syntax() RETURNS void LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("SELEC 1", &.{});
$$;
\set VERBOSITY default
SELECT u_syntax();
\set VERBOSITY terse
