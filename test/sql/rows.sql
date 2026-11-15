--
-- rows: OUT/INOUT parameters, composite results (structs), composite
-- arguments (doc/abi.md, "Rows").  The host checks every field a function
-- returns (kind, range, typmod, domain constraints) and builds the tuple;
-- a row type changed after compilation is detected, never trusted.
--
\set VERBOSITY terse
SET datestyle = 'ISO, YMD';
SET IntervalStyle = 'postgres';
SET TimeZone = 'UTC';

-- the SQLSTATE and message of a statement, or 'ok'
CREATE FUNCTION rw_err(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

--
-- OUT and INOUT parameters
--
-- two outputs: a struct named Result
CREATE FUNCTION rw_divmod(a int, b int, OUT q int, OUT r int) STRICT LANGUAGE plzig AS $$
    if (b == 0) return null;
    return .{ .q = @divTrunc(a, b), .r = @rem(a, b) };
$$;
SELECT * FROM rw_divmod(17, 5);
SELECT rw_divmod(-17, 5), (rw_divmod(17, 0)).q IS NULL AS null_row;
SELECT * FROM rw_divmod(1, 0);
-- one output: the function returns that type
CREATE FUNCTION rw_twice(x int, OUT y int) LANGUAGE plzig AS $$
    return if (x) |v| v * 2 else null;
$$;
SELECT rw_twice(21), rw_twice(NULL);
-- INOUT: an argument and a field of the result
CREATE FUNCTION rw_inout(INOUT a text, INOUT n int, OUT len int) LANGUAGE plzig AS $$
    const s = a orelse "";
    return .{ .a = try std.fmt.allocPrint(plzig.allocator, "<{s}>", .{s}),
              .n = (n orelse 0) + 1, .len = @as(i32, @intCast(s.len)) };
$$;
SELECT * FROM rw_inout('abc', 41);
SELECT * FROM rw_inout(NULL, NULL);
-- unnamed outputs are column1, column2, ... (as PostgreSQL names them)
CREATE FUNCTION rw_unnamed(OUT int, OUT text) LANGUAGE plzig AS $$
    return .{ .column1 = 7, .column2 = "seven" };
$$;
SELECT * FROM rw_unnamed();
-- NULL fields
CREATE FUNCTION rw_nulls(OUT a int, OUT b text, OUT c float8) LANGUAGE plzig AS $$
    return .{ .a = null, .b = "only b", .c = null };
$$;
SELECT * FROM rw_nulls();
-- every field must be given (no silent NULL): a compile error
CREATE FUNCTION rw_missing(OUT a int, OUT b int) LANGUAGE plzig AS $$
    return .{ .a = 1 };
$$;
-- procedures: CALL returns the output row; it cannot be NULL
CREATE PROCEDURE rw_proc(INOUT x int, OUT doubled int) LANGUAGE plzig AS $$
    return .{ .x = (x orelse 0) + 1, .doubled = (x orelse 0) * 2 };
$$;
CALL rw_proc(5, NULL);
CREATE PROCEDURE rw_proc1(INOUT x text) LANGUAGE plzig AS $$
    return .{ .x = if (x) |v| v else "was null" };
$$;
CALL rw_proc1('kept');
CALL rw_proc1(NULL);
-- a parameter named Result would collide with the generated row type
CREATE FUNCTION rw_badname("Result" int, OUT a int, OUT b int) LANGUAGE plzig AS $$
    return .{ .a = 1, .b = 2 };
$$;

--
-- composite results and arguments
--
CREATE TYPE rw_pair AS (a int, b text);
CREATE FUNCTION rw_mkpair(a int, b text) RETURNS rw_pair LANGUAGE plzig AS $$
    return .{ .a = a, .b = b };
$$;
SELECT rw_mkpair(1, 'x'), rw_mkpair(NULL, NULL), (rw_mkpair(2, 'y')).b;
SELECT * FROM rw_mkpair(3, 'three');
-- a NULL result is a NULL row, not a row of NULLs
CREATE FUNCTION rw_nullpair() RETURNS rw_pair LANGUAGE plzig AS $$
    return null;
$$;
SELECT rw_nullpair() IS NULL AS is_null, (rw_nullpair()).a;
-- an argument: optional fields; the same struct type as the result
CREATE FUNCTION rw_swap(p rw_pair) RETURNS rw_pair STRICT LANGUAGE plzig AS $$
    var q = p;
    q.a = if (p.a) |v| -v else null;
    if (p.b) |b| {
        const out = try plzig.allocator.alloc(u8, b.len);
        for (b, 0..) |ch, i| out[b.len - 1 - i] = ch;
        q.b = out;
    }
    return q;
$$;
SELECT rw_swap(ROW(5, 'hello')), rw_swap(ROW(NULL, NULL)::rw_pair), rw_swap(NULL);
-- a table's row type
CREATE TABLE rw_t (id int PRIMARY KEY, name text, score numeric(5,2), seen date);
INSERT INTO rw_t VALUES (1, 'one', 1.5, '2024-01-01'), (2, NULL, NULL, NULL);
CREATE FUNCTION rw_describe(r rw_t) RETURNS text LANGUAGE plzig AS $$
    const row = r orelse return "no row";
    var buf: [64]u8 = undefined;
    const sc = if (row.score) |s| try s.toText() else "-";
    const day = if (row.seen) |d| (try d.ymd()).day else 0;
    _ = &buf;
    return try std.fmt.allocPrint(plzig.allocator, "{d}:{s}:{s}:{d}",
        .{ row.id.?, row.name orelse "?", sc, day });
$$;
SELECT id, rw_describe(rw_t) FROM rw_t ORDER BY id;
SELECT rw_describe(NULL);
CREATE FUNCTION rw_bump(r rw_t) RETURNS rw_t STRICT LANGUAGE plzig AS $$
    var out = r;
    out.id = r.id.? + 100;
    out.score = if (r.score) |s| try s.add(try plzig.Numeric.parse("0.255")) else null;
    return out;
$$;
SELECT (rw_bump(t)).* FROM rw_t t ORDER BY id;

-- every natively mapped type as a field, NULL and not NULL
CREATE TYPE rw_all AS (b bool, i2 int2, i4 int4, i8 int8, f4 float4, f8 float8,
    t text, vc varchar(5), bc char(3), by bytea, d date, tm time, ttz timetz,
    ts timestamp, tstz timestamptz, iv interval, u uuid, o oid, n numeric,
    j jsonb, arr int[], inner_row rw_pair, rng int4range);
CREATE FUNCTION rw_echo(x rw_all) RETURNS rw_all LANGUAGE plzig AS $$
    const v = x orelse return null;
    return .{ .b = v.b, .i2 = v.i2, .i4 = v.i4, .i8 = v.i8, .f4 = v.f4, .f8 = v.f8,
              .t = v.t, .vc = v.vc, .bc = v.bc, .by = v.by, .d = v.d, .tm = v.tm,
              .ttz = v.ttz, .ts = v.ts, .tstz = v.tstz, .iv = v.iv, .u = v.u, .o = v.o,
              .n = v.n, .j = if (v.j) |j| try j.toJsonText() else null,
              .arr = v.arr, .inner_row = v.inner_row, .rng = v.rng };
$$;
SELECT (rw_echo(ROW(true, 1, 2, 3, 1.5, 2.5, 'text', 'vc', 'b', '\x0102', '2024-02-29',
                    '12:34:56', '12:34:56+02', '2024-02-29 12:34:56.5', '2024-02-29 12:34:56+00',
                    '1 mon 2 days 3 hours', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 42,
                    '123.456', '{"k": [1, 2, {"x": null}]}', '{1,2,3}', ROW(9, 'in'), '[1,5)')::rw_all)).*;
SELECT rw_echo(ROW(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::rw_all);
-- the generated struct: jsonb is read in place as an argument (plzig.Jsonb)
-- and JSON text as a result (plzig.JsonText), so `return x` does not compile
CREATE FUNCTION rw_echo_bad(x rw_all) RETURNS rw_all LANGUAGE plzig AS $$
    return x;
$$;

--
-- the host checks every field: typmods, domains, input functions
--
CREATE DOMAIN rw_pos AS int CHECK (VALUE > 0);
CREATE DOMAIN rw_nn AS text NOT NULL;
CREATE TYPE rw_strict AS (vc varchar(3), bc char(4), n numeric(5,2), ts timestamp(0),
                          iv interval hour to minute, p rw_pos, nn rw_nn, j jsonb);
-- one function, the field to break chosen by the argument
CREATE FUNCTION rw_mk(what int) RETURNS rw_strict STRICT LANGUAGE plzig AS $$
    var r: Result = .{ .vc = "abc", .bc = "x", .n = try plzig.Numeric.parse("123.456"),
                       .ts = .{ .usecs = 1_500_000 }, .iv = .{ .usecs = 3_723_456_789, .days = 0, .months = 0 },
                       .p = "5", .nn = "ok", .j = plzig.jsonText("[1, 2]") };
    switch (what) {
        1 => r.vc = "abcd",
        2 => r.n = try plzig.Numeric.parse("1234.5"),
        3 => r.p = "0",
        4 => r.nn = null,
        5 => r.p = "five",
        6 => r.j = plzig.jsonText("{bad"),
        7 => r.bc = "abcde",
        8 => r.vc = "\xff",
        9 => r.ts = .{ .usecs = std.math.maxInt(i64) - 1 },
        else => {},
    }
    return r;
$$;
SELECT (rw_mk(0)).*;
SELECT w, rw_err(format('SELECT rw_mk(%s)', w)) FROM generate_series(1, 9) w;

-- a domain over a composite type stays a text-I/O type: record_in and the
-- domain's constraints check the text (as for arrays of composites)
CREATE DOMAIN rw_pairdom AS rw_pair CHECK ((VALUE).a > 0);
CREATE FUNCTION rw_dom(t text) RETURNS rw_pairdom STRICT LANGUAGE plzig AS $$
    return t;
$$;
SELECT rw_dom('(1,x)'), rw_err($$SELECT rw_dom('(0,x)')$$), rw_err($$SELECT rw_dom('(1,2,3)')$$);

--
-- field names: emitted as @"name" into the generated source, so they must
-- be plain identifiers
--
CREATE TYPE rw_oddnames AS ("first name" text, "x""y" int);
CREATE FUNCTION rw_odd() RETURNS rw_oddnames LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION rw_odd_arg(x rw_oddnames) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION rw_odd_out(OUT "a b" int, OUT c int) LANGUAGE plzig AS $$ return null; $$;
-- Zig keywords are fine as field names
CREATE TYPE rw_kw AS ("return" int, "fn" text, "type" bool);
CREATE FUNCTION rw_kwf() RETURNS rw_kw LANGUAGE plzig AS $$
    return .{ .@"return" = 1, .@"fn" = "f", .@"type" = true };
$$;
SELECT * FROM rw_kwf();

--
-- dropped attributes: not in the struct; NULL in the tuple
--
CREATE TABLE rw_drop (a int, gone text, b text, alsogone int, c int);
ALTER TABLE rw_drop DROP COLUMN gone, DROP COLUMN alsogone;
INSERT INTO rw_drop VALUES (1, 'b', 3);
CREATE FUNCTION rw_dropf(r rw_drop) RETURNS rw_drop STRICT LANGUAGE plzig AS $$
    return .{ .a = (r.a orelse 0) * 10, .b = r.b, .c = (r.c orelse 0) * 10 };
$$;
SELECT (rw_dropf(d)).* FROM rw_drop d;

--
-- a row type changed after compilation: the function is rebuilt from the
-- new type (and may then fail to compile); never run with the old struct
--
CREATE TYPE rw_ev AS (a int, b text);
CREATE FUNCTION rw_evf(x int) RETURNS rw_ev LANGUAGE plzig AS $$
    return .{ .a = x, .b = "b" };
$$;
CREATE FUNCTION rw_evarg(r rw_ev) RETURNS text LANGUAGE plzig AS $$
    const v = r orelse return null;
    return try std.fmt.allocPrint(plzig.allocator, "{d} fields, a={?d}",
        .{ @typeInfo(@TypeOf(v)).@"struct".field_names.len, v.a });
$$;
SELECT * FROM rw_evf(1);
SELECT rw_evarg(ROW(1, 'b'));
ALTER TYPE rw_ev ADD ATTRIBUTE c int;
\set VERBOSITY default
SELECT * FROM rw_evf(2);
\set VERBOSITY terse
SELECT rw_evarg(ROW(1, 'b', 3));
ALTER TYPE rw_ev DROP ATTRIBUTE c;
SELECT * FROM rw_evf(3);
ALTER TYPE rw_ev ALTER ATTRIBUTE a TYPE text;
SELECT * FROM rw_evf(4);
ALTER TYPE rw_ev ALTER ATTRIBUTE a TYPE int;
SELECT * FROM rw_evf(5);
-- ... also in another way: a table altered after the function was loaded
CREATE TABLE rw_tt (a int, b int);
CREATE FUNCTION rw_ttf() RETURNS rw_tt LANGUAGE plzig AS $$
    return .{ .a = 1, .b = 2 };
$$;
SELECT * FROM rw_ttf();
ALTER TABLE rw_tt ADD COLUMN c int;
SELECT * FROM rw_ttf();
ALTER TABLE rw_tt DROP COLUMN c;
SELECT * FROM rw_ttf();
-- ... and changed during the call (through SPI): the result is refused
CREATE TYPE rw_live AS (a int);
CREATE FUNCTION rw_livef() RETURNS rw_live LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("ALTER TYPE rw_live ADD ATTRIBUTE z int", &.{});
    return .{ .a = 1 };
$$;
SELECT * FROM rw_livef();
SELECT attname FROM pg_attribute WHERE attrelid = 'rw_live'::regclass AND attnum > 0 ORDER BY attnum;

-- many fields (the generated struct and the value array scale)
DO $d$
BEGIN
  EXECUTE (SELECT format('CREATE TYPE rw_wide AS (%s)', string_agg(format('f%s int', i), ', ' ORDER BY i))
             FROM generate_series(1, 500) i);
  EXECUTE (SELECT format('CREATE FUNCTION rw_widef() RETURNS rw_wide LANGUAGE plzig AS $z$
    return .{ %s };
$z$', string_agg(format('.f%s = %s', i, i), ', ' ORDER BY i)) FROM generate_series(1, 500) i);
END $d$;
SELECT f1, f250, f500 FROM rw_widef();
CREATE FUNCTION rw_widesum(r rw_wide) RETURNS bigint STRICT LANGUAGE plzig AS $$
    return @as(i64, r.f1.?) + r.f250.? + r.f500.?;
$$;
SELECT rw_widesum(rw_widef());

-- composite results in SPI rows of other PL/Zig functions: text (kind other)
CREATE FUNCTION rw_spi() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT rw_mkpair(7, 'via spi')", &.{});
    const row = try r.row(0);
    return try std.fmt.allocPrint(plzig.allocator, "{s} kind={s}", .{ (try row.get(?[]const u8, 0)).?, @tagName(try row.kind(0)) });
$$;
SELECT rw_spi();

DROP FUNCTION rw_err(text);
