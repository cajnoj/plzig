--
-- xact: transaction control in procedures and DO (plzig.commit(),
-- plzig.rollback(); doc/abi.md, "Transaction control").  Only where
-- PostgreSQL allows it; every cursor of the call is closed and the last SPI
-- result dropped at a transaction end; prepared statements survive; an
-- error during the commit aborts the call and destroys the instance.
--
\set VERBOSITY terse

CREATE TABLE xa_t (n int);
CREATE PROCEDURE xa_basic() LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (1)", &.{});
    plzig.commit();
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (2)", &.{});
    plzig.rollback();
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (3)", &.{});
$$;
CALL xa_basic();
SELECT n FROM xa_t ORDER BY n;
-- each commit starts a new transaction
CREATE PROCEDURE xa_txids(OUT same bool) LANGUAGE plzig AS $$
    const a = (try (try plzig.spi.execute("SELECT txid_current()::text", &.{})).get(0, 0)).?;
    const before = try plzig.allocator.dupe(u8, a);
    plzig.commit();
    const b = (try (try plzig.spi.execute("SELECT txid_current()::text", &.{})).get(0, 0)).?;
    return .{ .same = std.mem.eql(u8, before, b) };
$$;
CALL xa_txids(NULL);
-- batches: commit every 100 rows; an error later keeps what was committed
TRUNCATE xa_t;
CREATE PROCEDURE xa_batches(total int, fail_at int) LANGUAGE plzig AS $$
    const ins = try plzig.spi.prepare("INSERT INTO xa_t VALUES ($1)", &.{.int4});
    var i: i32 = 1;
    while (i <= total.?) : (i += 1) {
        if (i == fail_at.?) plzig.raise("failing at {d}", .{i});
        _ = try ins.execute(.{i});            // a prepared statement survives every commit
        if (@mod(i, 100) == 0) plzig.commit();
    }
$$;
CALL xa_batches(1000, 0);
SELECT count(*), max(n) FROM xa_t;
TRUNCATE xa_t;
CALL xa_batches(1000, 450);
SELECT count(*), max(n) FROM xa_t;

-- DO blocks outside a transaction block
TRUNCATE xa_t;
DO $$
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (10)", &.{});
    plzig.commit();
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (11)", &.{});
    plzig.rollback();
$$ LANGUAGE plzig;
SELECT n FROM xa_t ORDER BY n;

-- where PostgreSQL does not allow it: its own error
CREATE FUNCTION xa_fn() RETURNS int LANGUAGE plzig AS $$
    plzig.commit();
    return 1;
$$;
SELECT xa_fn();
BEGIN;
CALL xa_basic();
ROLLBACK;
BEGIN;
DO $$ plzig.rollback(); $$ LANGUAGE plzig;
ROLLBACK;
-- a procedure called from a function (through SPI) is atomic
CREATE FUNCTION xa_calls() RETURNS int LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("CALL xa_basic()", &.{});
    return 1;
$$;
SELECT xa_calls();
-- ... and so is one called through SPI from a non-atomic procedure or DO:
-- only the procedure's own commit()/rollback() can end its transaction
TRUNCATE xa_t;
DO $$ _ = try plzig.spi.execute("CALL xa_basic()", &.{}); $$ LANGUAGE plzig;
SELECT n FROM xa_t ORDER BY n;
-- SECURITY DEFINER procedures and procedures with SET clauses are atomic
CREATE PROCEDURE xa_secdef() LANGUAGE plzig SECURITY DEFINER AS $$ plzig.commit(); $$;
CALL xa_secdef();
CREATE PROCEDURE xa_set() LANGUAGE plzig SET work_mem = '1MB' AS $$ plzig.commit(); $$;
CALL xa_set();
-- a trigger function is atomic
CREATE TABLE xa_trg (n int);
CREATE FUNCTION xa_trgf() RETURNS trigger LANGUAGE plzig AS $$
    plzig.commit();
    return .new;
$$;
CREATE TRIGGER xa_trg_t BEFORE INSERT ON xa_trg FOR EACH ROW EXECUTE FUNCTION xa_trgf();
INSERT INTO xa_trg VALUES (1);
-- COMMIT as SQL is still refused (SPI)
CREATE PROCEDURE xa_sqlcommit() LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("COMMIT", &.{});
$$;
CALL xa_sqlcommit();

-- with a subsequent error: only the work after the last commit is lost
TRUNCATE xa_t;
CREATE PROCEDURE xa_then_fail() LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (20)", &.{});
    plzig.commit();
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES (21)", &.{});
    return error.AfterCommit;
$$;
CALL xa_then_fail();
SELECT n FROM xa_t ORDER BY n;

-- an error during the commit (a deferred constraint): the call fails, the
-- transaction's work is gone, and the instance is destroyed (globals reset)
CREATE TABLE xa_def (n int UNIQUE DEFERRABLE INITIALLY DEFERRED);
CREATE PROCEDURE xa_defer(dup bool, INOUT calls int) LANGUAGE plzig AS $$
    count += 1;
    _ = try plzig.spi.execute("INSERT INTO xa_def VALUES (1)", &.{});
    if (dup orelse false) _ = try plzig.spi.execute("INSERT INTO xa_def VALUES (1)", &.{});
    plzig.commit();
    _ = try plzig.spi.execute("DELETE FROM xa_def", &.{});
    plzig.commit();
    return .{ .calls = count };
}
var count: i32 = 0;
fn unused() void {
$$;
CALL xa_defer(false, NULL);
CALL xa_defer(false, NULL);
CALL xa_defer(true, NULL);
SELECT count(*) FROM xa_def;
CALL xa_defer(false, NULL);

-- cursors are closed at a transaction end: fetching is an error, closing is fine
TRUNCATE xa_t;
INSERT INTO xa_t SELECT generate_series(1, 5);
CREATE PROCEDURE xa_cursor(fetch_after bool, INOUT got text) LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT n FROM xa_t ORDER BY n", &.{});
    const first = try (try c.next()).?.get(i32, 0);
    plzig.commit();
    if (fetch_after orelse false) _ = try c.next();
    c.close();
    // a new cursor in the new transaction works
    var c2 = try plzig.spi.open("SELECT count(*) FROM xa_t", &.{});
    const n = try (try c2.next()).?.get(i64, 0);
    return .{ .got = try std.fmt.allocPrint(plzig.allocator, "first {d}, count {d}", .{ first, n }) };
$$;
CALL xa_cursor(false, NULL);
CALL xa_cursor(true, NULL);
-- ... and the last SPI result is dropped
CREATE PROCEDURE xa_result() LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT n FROM xa_t ORDER BY n", &.{});
    plzig.rollback();
    _ = try r.get(0, 0);
$$;
CALL xa_result();
-- ... a procedure called through SPI cannot end the transaction under a
-- running call (SPI runs it atomically), not even a PL/pgSQL one
CREATE PROCEDURE xa_plpgsql_commit() LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO xa_t VALUES (100);
    COMMIT;
END $$;
CREATE PROCEDURE xa_nested(what int) LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT n FROM xa_t ORDER BY n", &.{});
    _ = try c.next();
    _ = try plzig.spi.execute("CALL xa_plpgsql_commit()", &.{});
    if (what == 1) _ = try c.next();
    c.close();
    const r = try plzig.spi.execute("SELECT count(*) FROM xa_t WHERE n = 100", &.{});
    plzig.notice("rows of 100: {s}", .{(try r.get(0, 0)).?});
$$;
CALL xa_nested(0);
CALL xa_nested(1);
-- a procedure calling itself through SPI: the nested call is atomic
TRUNCATE xa_t;
CREATE PROCEDURE xa_rec(depth int) LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    _ = try plzig.spi.execute("INSERT INTO xa_t VALUES ($1::int)", &.{try std.fmt.bufPrint(&buf, "{d}", .{depth.?})});
    plzig.commit();
    if (depth.? > 0) _ = try plzig.spi.execute("CALL xa_rec($1::int - 1)", &.{try std.fmt.bufPrint(&buf, "{d}", .{depth.?})});
    plzig.rollback(); // nothing to roll back
$$;
CALL xa_rec(3);
SELECT n FROM xa_t ORDER BY n;
-- the output row of a procedure after transaction ends is built from the
-- guest's values (no pointer into an ended transaction)
CREATE PROCEDURE xa_out(INOUT x text) LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT repeat('t', 3000)", &.{});
    const v = try plzig.allocator.dupe(u8, (try r.get(0, 0)).?);
    plzig.commit();
    _ = try plzig.spi.execute("UPDATE xa_t SET n = n + 1", &.{});
    plzig.commit();
    return .{ .x = try std.fmt.allocPrint(plzig.allocator, "{s}:{d}", .{ x orelse "", v.len }) };
$$;
CALL xa_out('len');
SELECT 1 AS still_fine;

DROP TABLE xa_t, xa_def, xa_trg;
