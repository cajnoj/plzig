--
-- srf: set-returning functions, materialize mode (doc/abi.md, "Sets").  The
-- guest pushes rows with returnNext (one host call each); the host checks
-- every row like a row result and appends it to a tuplestore bounded by
-- work_mem.  An instance never stays suspended between calls.
--
\set VERBOSITY terse

-- the SQLSTATE and message of a statement, or 'ok'
CREATE FUNCTION sr_err(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- SETOF a scalar type: Result is the element type, null a NULL element
CREATE FUNCTION sr_range(n int) RETURNS SETOF int STRICT LANGUAGE plzig AS $$
    var i: i32 = 1;
    while (i <= n) : (i += 1) returnNext(if (@mod(i, 4) == 0) null else i);
$$;
SELECT * FROM sr_range(6);
SELECT sr_range(3);                          -- in the target list
SELECT count(*) FROM sr_range(0);            -- an empty set
SELECT x, y FROM sr_range(3) x, LATERAL sr_range(x) y ORDER BY x, y;
CREATE FUNCTION sr_words(t text) RETURNS SETOF text STRICT LANGUAGE plzig AS $$
    var it = std.mem.tokenizeScalar(u8, t, ' ');
    while (it.next()) |w| returnNext(w);
$$;
SELECT * FROM sr_words('the quick  brown fox') WITH ORDINALITY;
-- native types as elements
CREATE FUNCTION sr_nums(n int) RETURNS SETOF numeric STRICT LANGUAGE plzig AS $$
    var x = try plzig.Numeric.parse("0.5");
    for (0..@intCast(n)) |_| {
        returnNext(x);
        x = try x.mul(try plzig.Numeric.parse("3"));
    }
$$;
SELECT * FROM sr_nums(4);
CREATE FUNCTION sr_days(d date, n int) RETURNS SETOF date STRICT LANGUAGE plzig AS $$
    for (0..@intCast(n)) |k| returnNext(.{ .days = d.days + @as(i32, @intCast(k)) * 7 });
$$;
SELECT * FROM sr_days('2024-02-26', 3);
CREATE FUNCTION sr_json(n int) RETURNS SETOF jsonb STRICT LANGUAGE plzig AS $$
    for (0..@intCast(n)) |k| returnNext(plzig.jsonText(try std.fmt.allocPrint(plzig.allocator, "{{\"k\": {d}}}", .{k})));
$$;
SELECT * FROM sr_json(2);

-- SETOF a composite type, RETURNS TABLE, SETOF record with OUT parameters
CREATE TYPE sr_pair AS (a int, b text);
CREATE FUNCTION sr_pairs(n int) RETURNS SETOF sr_pair STRICT LANGUAGE plzig AS $$
    for (1..@as(usize, @intCast(n)) + 1) |k| {
        const i: i32 = @intCast(k);
        returnNext(.{ .a = i, .b = try std.fmt.allocPrint(plzig.allocator, "#{d}", .{i * i}) });
    }
    returnNext(null); // a row of NULLs
$$;
SELECT * FROM sr_pairs(3);
SELECT (sr_pairs(2)).b;
CREATE FUNCTION sr_table(n int) RETURNS TABLE (i int, sq bigint, label text) STRICT LANGUAGE plzig AS $$
    var k: i32 = 0;
    while (k < n) : (k += 1)
        returnNext(.{ .i = k, .sq = @as(i64, k) * k, .label = if (@mod(k, 2) == 0) "even" else null });
$$;
SELECT * FROM sr_table(4);
SELECT label, count(*) FROM sr_table(10) GROUP BY label ORDER BY label;
-- one TABLE column: SETOF that type
CREATE FUNCTION sr_table1(n int) RETURNS TABLE (v text) STRICT LANGUAGE plzig AS $$
    for (0..@intCast(n)) |_| returnNext("v");
$$;
SELECT * FROM sr_table1(2);
CREATE FUNCTION sr_outset(n int, OUT x int, OUT y int) RETURNS SETOF record STRICT LANGUAGE plzig AS $$
    var k: i32 = 0;
    while (k < n) : (k += 1) returnNext(.{ .x = k, .y = -k });
$$;
SELECT * FROM sr_outset(3);
-- SETOF void, and record without a description, are refused
CREATE FUNCTION sr_void() RETURNS SETOF void LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sr_rec() RETURNS SETOF record LANGUAGE plzig AS $$ return; $$;
-- reserved names
CREATE FUNCTION sr_bad1("returnNext" int) RETURNS SETOF int LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sr_bad2("Result" int) RETURNS SETOF int LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sr_ok3("returnNext" int) RETURNS int LANGUAGE plzig AS $$ return @"returnNext"; $$;
SELECT sr_ok3(5);

-- every pushed row is checked by the host: domains, typmods, NULLs
CREATE DOMAIN sr_pos AS int CHECK (VALUE > 0);
CREATE TYPE sr_strict AS (p sr_pos, v varchar(3));
CREATE FUNCTION sr_check(what int) RETURNS SETOF sr_strict STRICT LANGUAGE plzig AS $$
    returnNext(.{ .p = "1", .v = "ok" });
    switch (what) {
        1 => returnNext(.{ .p = "0", .v = "ok" }),
        2 => returnNext(.{ .p = "2", .v = "long" }),
        3 => returnNext(.{ .p = "x", .v = null }),
        else => returnNext(.{ .p = null, .v = null }),
    }
$$;
SELECT * FROM sr_check(0);
SELECT w, sr_err(format('SELECT * FROM sr_check(%s)', w)) FROM generate_series(1, 3) w;
CREATE DOMAIN sr_nn AS int NOT NULL;
CREATE FUNCTION sr_dom(n int) RETURNS SETOF sr_nn STRICT LANGUAGE plzig AS $$
    returnNext("5");
    if (n > 0) returnNext(null);
$$;
SELECT * FROM sr_dom(0);
SELECT sr_err('SELECT * FROM sr_dom(1)');
-- an error after some rows: nothing is returned
CREATE FUNCTION sr_fail(n int) RETURNS SETOF int STRICT LANGUAGE plzig AS $$
    returnNext(1);
    returnNext(2);
    if (n > 0) return error.Halfway;
$$;
SELECT sr_err('SELECT * FROM sr_fail(1)');
SELECT * FROM sr_fail(0);

-- rows can only be pushed by a set-returning function
CREATE FUNCTION sr_outside() RETURNS int LANGUAGE plzig AS $$
    plzig.returnNext(i32, 1);
    return 1;
$$;
SELECT sr_outside();
CREATE PROCEDURE sr_outside_proc() LANGUAGE plzig AS $$
    plzig.returnNext(i32, 1);
$$;
CALL sr_outside_proc();
DO $$ plzig.returnNext(i32, 1); $$ LANGUAGE plzig;
-- ... a nested set-returning call (through SPI) has its own result set
CREATE FUNCTION sr_nested(n int) RETURNS SETOF text STRICT LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    returnNext(try std.fmt.bufPrint(&buf, "level {d}", .{n}));
    if (n > 0) {
        const r = try plzig.spi.execute("SELECT x FROM sr_nested($1::int - 1) x", &.{try std.fmt.bufPrint(&buf, "{d}", .{n})});
        var k: u64 = 0;
        while (k < r.rows) : (k += 1) returnNext((try r.get(k, 0)).?);
    }
$$;
SELECT * FROM sr_nested(3);
-- ... and rows streamed from a cursor
CREATE TABLE sr_src AS SELECT g AS id, left(encode(sha256(g::text::bytea), 'hex'), 32) AS h FROM generate_series(1, 1000) g;
CREATE FUNCTION sr_stream(m int) RETURNS TABLE (id int, h text) STRICT LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT id, h FROM sr_src ORDER BY id", &.{});
    while (try c.next()) |row| {
        const id = try row.get(i32, 0);
        if (@mod(id, m) == 0) returnNext(.{ .id = id, .h = try row.get([]const u8, 1) });
    }
$$;
SELECT count(*), min(id), max(id), bool_and(h = left(encode(sha256(id::text::bytea), 'hex'), 32)) FROM sr_stream(7);

-- large sets: the tuplestore spills to a temporary file beyond work_mem ...
CREATE FUNCTION sr_many(n int) RETURNS SETOF text STRICT LANGUAGE plzig AS $$
    var buf: [64]u8 = undefined;
    var i: i32 = 0;
    while (i < n) : (i += 1) returnNext(try std.fmt.bufPrint(&buf, "row {d} xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .{i}));
$$;
SET work_mem = '64kB';
SELECT count(*), count(DISTINCT x) FROM sr_many(100000) x;
-- ... which temp_file_limit bounds
SET temp_file_limit = '1MB';
SELECT replace(sr_err('SELECT count(*) FROM sr_many(100000)'), '"', '') AS err;  -- (18+ quotes the name)
RESET temp_file_limit;
RESET work_mem;
-- random access (a scrollable cursor over the function)
BEGIN;
DECLARE sr_cur SCROLL CURSOR FOR SELECT * FROM sr_range(5);
FETCH LAST FROM sr_cur;
FETCH ABSOLUTE 2 FROM sr_cur;
FETCH PRIOR FROM sr_cur;
COMMIT;
-- a statement timeout ends a function that pushes forever
CREATE FUNCTION sr_forever() RETURNS SETOF int LANGUAGE plzig AS $$
    var i: i32 = 0;
    while (true) : (i +%= 1) returnNext(i);
$$;
SET statement_timeout = '200ms';
SELECT sr_err('SELECT count(*) FROM sr_forever()');
RESET statement_timeout;

-- the element row type changed during the call is refused
CREATE TYPE sr_live AS (a int);
CREATE FUNCTION sr_livef() RETURNS SETOF sr_live LANGUAGE plzig AS $$
    returnNext(.{ .a = 1 });
    _ = try plzig.spi.execute("ALTER TYPE sr_live ADD ATTRIBUTE z int", &.{});
    returnNext(.{ .a = 2 });
$$;
SELECT * FROM sr_livef();

DROP FUNCTION sr_err(text);
