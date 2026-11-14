--
-- spi_cursor: row-at-a-time cursors, lifetimes, nesting, limits, memory
--
\set VERBOSITY terse

CREATE TABLE ct (id int, name text, data bytea);
INSERT INTO ct SELECT g, 'name ' || g, CASE WHEN g % 3 = 0 THEN NULL ELSE int4send(g) END
  FROM generate_series(1, 123) g;

-- ad-hoc cursor with text parameters, across several fetch batches
CREATE FUNCTION ct_sum(lo int) RETURNS text STRICT LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    var cur = try plzig.spi.open("SELECT id, name, data FROM ct WHERE id >= $1::int ORDER BY id",
                                 &.{try std.fmt.bufPrint(&buf, "{d}", .{lo})});
    defer cur.close();
    var n: i64 = 0;
    var sum: i64 = 0;
    var nulls: i64 = 0;
    var last: []const u8 = "";
    while (try cur.next()) |row| {
        n += 1;
        sum += try row.get(i32, 0);
        if (try row.get(?[]const u8, 2) == null) nulls += 1;
        // slices are only valid until the next next(): copy what is kept
        last = try plzig.allocator.dupe(u8, try row.get([]const u8, 1));
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d} rows, sum {d}, {d} null, last '{s}'", .{ n, sum, nulls, last });
$$;
SELECT ct_sum(1), ct_sum(100), ct_sum(1000);

-- cursor over a prepared statement with typed parameters; kinds and NULLs
CREATE FUNCTION ct_plan(lo int, hi int) RETURNS text STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT g, g::float8 / 2, g % 2 = 0, NULLIF(g, 3)::int2, now() IS NOT NULL " ++
                                  "FROM generate_series($1, $2) g", &.{ .int4, .int4 });
    defer p.free();
    var cur = try p.open(.{ lo, hi });
    defer cur.close();
    var out: std.ArrayList(u8) = .empty;
    while (try cur.next()) |row| {
        try out.print(plzig.allocator, "{d}:{d}:{any}:{?d}:{any} ", .{ try row.get(i32, 0), try row.get(f64, 1),
            try row.get(bool, 2), try row.get(?i16, 3), try row.get(bool, 4) });
    }
    return out.items;
$$;
SELECT ct_plan(1, 5);
SELECT ct_plan(5, 1);

-- forward only, not holdable, visible while open; closed when the call ends
CREATE FUNCTION ct_visible(close_it bool) RETURNS text STRICT LANGUAGE plzig AS $$
    var cur = try plzig.spi.open("SELECT 1 FROM ct", &.{});
    _ = try cur.next();
    const r = try plzig.spi.execute("SELECT count(*)::int4, bool_or(is_holdable), bool_or(is_scrollable) FROM pg_cursors", &.{});
    const row = try r.row(0);
    if (close_it) cur.close();
    return try std.fmt.allocPrint(plzig.allocator, "open: {d}, holdable: {any}, scrollable: {any}",
        .{ try row.get(i32, 0), try row.get(?bool, 1), try row.get(?bool, 2) });
$$;
BEGIN;
SELECT ct_visible(true);
SELECT count(*) AS after_close FROM pg_cursors;
-- left open at return: closed by the host
SELECT ct_visible(false);
SELECT count(*) AS after_return FROM pg_cursors;
COMMIT;

-- left open at an error: dropped by the (sub)transaction abort
CREATE FUNCTION ct_fail(at int) RETURNS int STRICT LANGUAGE plzig AS $$
    var cur = try plzig.spi.open("SELECT id FROM ct ORDER BY id", &.{});
    var cur2 = try plzig.spi.open("SELECT 10 / (60 - id) FROM ct ORDER BY id", &.{});
    _ = &cur2;
    var n: i32 = 0;
    while (try cur.next()) |row| {
        n += 1;
        if (n == at) plzig.raise("error at row {d}", .{try row.get(i32, 0)});
        if (at < 0) _ = try cur2.next();
    }
    return n;
$$;
BEGIN;
SAVEPOINT s;
SELECT ct_fail(77);
ROLLBACK TO s;
SELECT count(*) AS after_error FROM pg_cursors;
-- an SQL error while fetching (division by zero in the second batch)
SELECT ct_fail(-1);
ROLLBACK TO s;
SELECT count(*) AS after_fetch_error FROM pg_cursors;
SELECT ct_fail(0);
COMMIT;

-- use after close, forged and stale handles
CREATE FUNCTION ct_handle(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    var cur = try plzig.spi.open("SELECT 1", &.{});
    const h = cur.handle;
    var forged: plzig.spi.Cursor = .{ .handle = 0 };
    switch (what) {
        1 => {
            cur.close();
            _ = try cur.next();               // the SDK knows it is closed
        },
        2 => {
            forged = cur;                      // a copy of a closed cursor
            cur.close();
        },
        3 => forged.handle = 0,
        4 => forged.handle = 12345,
        5 => forged.handle = h + (1 << 16),
        6 => forged.handle = (h & ~@as(u64, 0xffff)) | 3,
        7 => forged.handle = h | 0xffff,
        8 => {                                 // exhausted: the SDK closed it
            forged = cur;
            while (try cur.next()) |_| {}
        },
        9 => {
            forged = cur;
            cur.close();
            forged.close();                    // closing twice through a copy
        },
        else => forged = cur,
    }
    _ = try forged.next();
    return "valid";
$$;
SELECT ct_handle(1);
SELECT ct_handle(2);
SELECT ct_handle(3);
SELECT ct_handle(4);
SELECT ct_handle(5);
SELECT ct_handle(6);
SELECT ct_handle(7);
SELECT ct_handle(8);
SELECT ct_handle(9);
SELECT ct_handle(0);

-- a cursor never outlives its call: kept in a global, it is invalid next time
CREATE FUNCTION ct_global(first bool) RETURNS text STRICT LANGUAGE plzig AS $$
    const S = struct { var cur: ?plzig.spi.Cursor = null; };
    if (first) {
        S.cur = try plzig.spi.open("SELECT 1 FROM ct", &.{});
        _ = try S.cur.?.next();
        return "opened";
    }
    _ = try S.cur.?.next();
    return "still valid";
$$;
SELECT ct_global(true);
SELECT ct_global(false);
-- nor is it valid in another function, or in a recursive call (another instance)
CREATE FUNCTION ct_use(h bigint) RETURNS text STRICT LANGUAGE plzig AS $$
    var c: plzig.spi.Cursor = .{ .handle = @bitCast(h) };
    _ = try c.next();
    return "valid";
$$;
CREATE FUNCTION ct_pass(depth int, h bigint) RETURNS text STRICT LANGUAGE plzig AS $$
    if (depth == 0) {
        var c: plzig.spi.Cursor = .{ .handle = @bitCast(h) };
        _ = try c.next();
        return "valid";
    }
    var cur = try plzig.spi.open("SELECT 1", &.{});
    defer cur.close();
    var p = try plzig.spi.prepare(if (depth == 1) "SELECT ct_pass(0, $1)" else "SELECT ct_use($1)", &.{.int8});
    defer p.free();
    const r = try p.execute(.{@as(i64, @bitCast(cur.handle))});
    return (try r.get(0, 0)).?;
$$;
SELECT ct_pass(1, 0);
SELECT ct_pass(2, 0);

-- the cap on open cursors per call (plzig.max_open_cursors) is an error;
-- closed and exhausted cursors do not count
SET plzig.max_open_cursors = 2;
CREATE FUNCTION ct_cap(n int, exhaust bool) RETURNS int STRICT LANGUAGE plzig AS $$
    var curs: [8]plzig.spi.Cursor = undefined;
    var i: usize = 0;
    var total: i32 = 0;
    while (i < n) : (i += 1) {
        curs[i] = try plzig.spi.open("SELECT 1 UNION ALL SELECT 2", &.{});
        if (exhaust) {
            while (try curs[i].next()) |_| total += 1;
        }
    }
    return total + @as(i32, @intCast(i));
$$;
SELECT ct_cap(2, false);
SELECT ct_cap(3, false);
SELECT ct_cap(8, true);
CREATE FUNCTION ct_cap_close() RETURNS int LANGUAGE plzig AS $$
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var c = try plzig.spi.open("SELECT 1", &.{});
        c.close();
    }
    return i;
$$;
SELECT ct_cap_close();
SET plzig.max_open_cursors = 0;
SELECT ct_cap(1, false);
RESET plzig.max_open_cursors;

-- read-only rule: a cursor in a STABLE function cannot modify data
CREATE FUNCTION ct_ro_adhoc() RETURNS int STABLE LANGUAGE plzig AS $$
    var c = try plzig.spi.open("INSERT INTO ct(id) VALUES (999) RETURNING id", &.{});
    return (try (try c.next()).?.get(i32, 0));
$$;
CREATE FUNCTION ct_ro_plan() RETURNS int STABLE LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("UPDATE ct SET name = 'x' WHERE id = $1 RETURNING id", &.{.int4});
    var c = try p.open(.{@as(i32, 1)});
    return (try (try c.next()).?.get(i32, 0));
$$;
SELECT ct_ro_adhoc();
SELECT ct_ro_plan();
-- in a VOLATILE function, a RETURNING query can be a cursor; other DML cannot
CREATE FUNCTION ct_returning() RETURNS int LANGUAGE plzig AS $$
    var c = try plzig.spi.open("INSERT INTO ct(id) VALUES (1000), (1001) RETURNING id", &.{});
    defer c.close();
    var s: i32 = 0;
    while (try c.next()) |row| s += try row.get(i32, 0);
    return s;
$$;
CREATE FUNCTION ct_no_returning() RETURNS int LANGUAGE plzig AS $$
    _ = try plzig.spi.open("DELETE FROM ct WHERE id > 1000", &.{});
    return 0;
$$;
SELECT ct_returning();
SELECT ct_no_returning();
DELETE FROM ct WHERE id >= 1000;

-- permissions: as the current user; SECURITY DEFINER as the owner
CREATE TABLE ct_secret (s text);
INSERT INTO ct_secret VALUES ('cursor secret');
REVOKE ALL ON ct_secret FROM PUBLIC;
CREATE FUNCTION ct_secret_adhoc() RETURNS text LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT s FROM ct_secret", &.{});
    return try plzig.allocator.dupe(u8, try (try c.next()).?.get([]const u8, 0));
$$;
CREATE FUNCTION ct_secret_plan() RETURNS text LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT s FROM ct_secret", &.{});
    var c = try S.plan.?.open(.{});
    return try plzig.allocator.dupe(u8, try (try c.next()).?.get([]const u8, 0));
$$;
CREATE FUNCTION ct_secret_definer() RETURNS text SECURITY DEFINER SET search_path = public
  LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT s FROM ct_secret", &.{});
    var c = try S.plan.?.open(.{});
    var c2 = try plzig.spi.open("SELECT s FROM ct_secret", &.{});
    const a = try plzig.allocator.dupe(u8, try (try c.next()).?.get([]const u8, 0));
    const b = try (try c2.next()).?.get([]const u8, 0);
    return try std.fmt.allocPrint(plzig.allocator, "{s}/{s}", .{ a, b });
$$;
GRANT EXECUTE ON FUNCTION ct_secret_adhoc(), ct_secret_plan(), ct_secret_definer() TO regress_plzig_nobody;
SELECT ct_secret_adhoc(), ct_secret_plan(), ct_secret_definer();
SET ROLE regress_plzig_nobody;
SELECT ct_secret_adhoc();
SELECT ct_secret_plan();
SELECT ct_secret_definer();
RESET ROLE;

-- nesting: queries, other PL/Zig functions and recursion while cursors are open
CREATE FUNCTION ct_inner(n int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT g FROM generate_series(1, $1) g", &.{.int4});
    defer p.free();
    var c = try p.open(.{n});
    var s: i64 = 0;
    while (try c.next()) |row| s += try row.get(i32, 0);
    return s;          // c left open on purpose: closed by the host
$$;
CREATE FUNCTION ct_nested() RETURNS text LANGUAGE plzig AS $$
    var outer = try plzig.spi.open("SELECT id FROM ct WHERE id <= 60 ORDER BY id", &.{});
    defer outer.close();
    var other = try plzig.spi.open("SELECT id FROM ct ORDER BY id DESC", &.{});
    defer other.close();
    var p = try plzig.spi.prepare("SELECT ct_inner($1), (SELECT count(*) FROM ct WHERE id < $1)::int", &.{.int4});
    defer p.free();
    var total: i64 = 0;
    var zipped: i64 = 0;
    while (try outer.next()) |row| {
        const id = try row.get(i32, 0);
        const r = try p.execute(.{id});                 // another query, another function
        const rr = try r.row(0);
        total += try rr.get(i64, 0) + try rr.get(i32, 1);
        const o = (try other.next()).?;                 // interleaved with a second cursor
        zipped += try o.get(i32, 0);
    }
    return try std.fmt.allocPrint(plzig.allocator, "total {d}, zipped {d}", .{ total, zipped });
$$;
SELECT ct_nested();
SELECT count(*) AS open_cursors FROM pg_cursors;
-- recursion with open cursors at every level
CREATE FUNCTION ct_rec(depth int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    if (depth == 0) return 1;
    var c = try plzig.spi.open("SELECT ct_rec($1::int - 1) FROM generate_series(1, 3)", &.{
        try std.fmt.allocPrint(plzig.allocator, "{d}", .{depth}) });
    var s: i64 = 0;
    while (try c.next()) |row| s += try row.get(i64, 0);
    return s;
$$;
SELECT ct_rec(4);
-- an error deep inside the recursion
CREATE FUNCTION ct_rec_fail(depth int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    if (depth == 0) plzig.raise("bottom reached", .{});
    var c = try plzig.spi.open("SELECT ct_rec_fail($1::int - 1)", &.{
        try std.fmt.allocPrint(plzig.allocator, "{d}", .{depth}) });
    _ = try c.next();
    return 0;
$$;
BEGIN;
SAVEPOINT s;
SELECT ct_rec_fail(3);
ROLLBACK TO s;
SELECT count(*) AS after_nested_error FROM pg_cursors;
SELECT ct_rec(2);
COMMIT;
-- an error in a nested PL/Zig function with an open cursor, caught by a
-- PL/pgSQL exception block, while the outer cursor stays open
CREATE FUNCTION ct_catch(at int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  RETURN ct_fail(at);
EXCEPTION WHEN others THEN
  RETURN -1;
END $$;
CREATE FUNCTION ct_outer_catch() RETURNS text LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT id FROM ct ORDER BY id", &.{});
    var p = try plzig.spi.prepare("SELECT ct_catch($1)", &.{.int4});
    var n: i64 = 0;
    var caught: i64 = 0;
    while (try c.next()) |row| {
        const id = try row.get(i32, 0);
        n += id;
        if (@rem(id, 40) == 0) {
            const r = try p.execute(.{@as(i32, 5)});
            if (try (try r.row(0)).get(i32, 0) == -1) caught += 1;
            // only our own cursor is left: the nested function's were dropped
            const open = try plzig.spi.execute("SELECT count(*)::int4 FROM pg_cursors", &.{});
            if (try (try open.row(0)).get(i32, 0) != 1) return error.UnexpectedCursorCount;
        }
    }
    return try std.fmt.allocPrint(plzig.allocator, "sum {d}, caught {d}", .{ n, caught });
$$;
SELECT ct_outer_catch();
SELECT count(*) AS open_cursors FROM pg_cursors;
-- the portals are pinned: nested code cannot close them
CREATE FUNCTION ct_closeall() RETURNS void LANGUAGE plpgsql AS $$ BEGIN EXECUTE 'CLOSE ALL'; END $$;
CREATE FUNCTION ct_pinned() RETURNS text LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT id FROM ct", &.{});
    _ = try c.next();
    _ = try plzig.spi.execute("SELECT ct_closeall()", &.{});
    _ = try c.next();
    return "not closed";
$$;
DO $$
BEGIN
  PERFORM ct_pinned();
EXCEPTION WHEN others THEN
  RAISE NOTICE 'refused: %', SQLERRM LIKE 'cannot drop pinned portal "%"';
END $$;
-- the prepared statement may be freed while its cursor is open
CREATE FUNCTION ct_free_plan() RETURNS bigint LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT g FROM generate_series(1, 200) g", &.{});
    var c = try p.open(.{});
    p.free();
    var s: i64 = 0;
    while (try c.next()) |row| s += try row.get(i32, 0);
    return s;
$$;
SELECT ct_free_plan();
-- DDL on a table with an open cursor is refused cleanly
CREATE FUNCTION ct_ddl() RETURNS text LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT id FROM ct", &.{});
    _ = try c.next();
    _ = try plzig.spi.execute("ALTER TABLE ct ADD COLUMN extra int", &.{});
    return "altered";
$$;
SELECT ct_ddl();
SELECT count(*) AS columns FROM pg_attribute WHERE attrelid = 'ct'::regclass AND attnum > 0;

-- query cancel during a long cursor loop
CREATE FUNCTION ct_forever() RETURNS bigint LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT g FROM generate_series(1, 2000000000) g", &.{});
    var s: i64 = 0;
    while (try c.next()) |row| s +%= try row.get(i32, 0);
    return s;
$$;
CREATE FUNCTION ct_slow() RETURNS bigint LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT pg_sleep(0.01) FROM generate_series(1, 1000)", &.{});
    var n: i64 = 0;
    while (try c.next()) |_| n += 1;
    return n;
$$;
SET statement_timeout = '300ms';
SELECT ct_forever();
SELECT ct_slow();
RESET statement_timeout;
SELECT count(*) AS after_cancel FROM pg_cursors;
SELECT ct_sum(120);

-- memory: iterating 100k rows through a cursor and executing a prepared
-- statement 10k times must not grow backend memory (PL/Zig contexts,
-- including the guest's linear memory) or SPI memory
CREATE FUNCTION ct_mem(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    return run(what) catch |e| return e;
}
fn mem() ![2]i64 {
    const r = try plzig.spi.execute(
        "SELECT coalesce(sum(total_bytes) FILTER (WHERE name LIKE 'PL/Zig%'), 0)::int8, " ++
        "coalesce(sum(total_bytes) FILTER (WHERE name LIKE 'SPI%'), 0)::int8 FROM pg_backend_memory_contexts", &.{});
    const row = try r.row(0);
    return .{ try row.get(i64, 0), try row.get(i64, 1) };
}
fn run(what: i32) ![]const u8 {
    var before: [2]i64 = undefined;
    var after: [2]i64 = undefined;
    var n: i64 = 0;
    if (what == 1) {
        var p = try plzig.spi.prepare("SELECT g, 'row ' || g, int4send(g) FROM generate_series(1, $1) g", &.{.int4});
        var c = try p.open(.{@as(i32, 100000)});
        while (try c.next()) |row| {
            n += try row.get(i32, 0) + @as(i64, @intCast((try row.get([]const u8, 1)).len + (try row.get([]const u8, 2)).len));
            if (n == 1 + 5 + 4) before = try mem();
        }
        after = try mem();
    } else {
        var p = try plzig.spi.prepare("SELECT $1 + 1, $2 || 'x'", &.{ .int4, .text });
        var i: i32 = 0;
        while (i < 10000) : (i += 1) {
            const r = try p.execute(.{ i, "abc" });
            const row = try r.row(0);
            n += try row.get(i32, 0) + @as(i64, @intCast((try row.get([]const u8, 1)).len));
            if (i == 1000) before = try mem();
        }
        after = try mem();
    }
    return try std.fmt.allocPrint(plzig.allocator, "checksum {d}, PL/Zig memory grew: {any}, SPI memory grew: {any}",
        .{ n, after[0] > before[0], after[1] > before[1] });
$$;
SELECT ct_mem(1);
SELECT ct_mem(2);
-- and across calls
CREATE FUNCTION ct_mem_call(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT $1 * 2", &.{.int4});
    const r = try S.plan.?.execute(.{i});
    var c = try plzig.spi.open("SELECT 1 UNION ALL SELECT 2", &.{});
    _ = try c.next();                  // left open: closed by the host
    return try (try r.row(0)).get(i32, 0);
$$;
SELECT sum(ct_mem_call(g)) FROM generate_series(1, 200) g;
SELECT sum(total_bytes) AS mem_before FROM pg_backend_memory_contexts WHERE name LIKE 'PL/Zig%' \gset
SELECT sum(ct_mem_call(g)) FROM generate_series(1, 5000) g;
SELECT sum(total_bytes) > :mem_before AS grew_across_calls
  FROM pg_backend_memory_contexts WHERE name LIKE 'PL/Zig%';
