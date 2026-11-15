--
-- types_numeric: numeric in PostgreSQL's binary wire format (doc/abi.md,
-- "numeric"): arguments, results, NULL, NaN and the infinities, very large
-- and very small values, typmods, malformed values from the function, SPI
-- parameters and columns, and the SDK's inspection, comparison,
-- conversions, text and arithmetic, each compared with SQL.
--
\set VERBOSITY terse

CREATE FUNCTION nm_err(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

CREATE TABLE nm_vals (id int PRIMARY KEY, n numeric);
INSERT INTO nm_vals VALUES
  (1, 0), (2, '0.000'), (3, '-0.000'), (4, 1), (5, -1), (6, 1.5), (7, '-1.50'),
  (8, 'NaN'), (9, 'Infinity'), (10, '-Infinity'), (11, 0.0001), (12, '-0.00012'),
  (13, 12345678901234567890.123456789), (14, 9223372036854775807), (15, -9223372036854775808),
  (16, 9223372036854775808), (17, '1e100'), (18, '-1e-100'), (19, 99999999.9999),
  (20, 10000), (21, 3.14159265358979323846264338327950288),
  (22, '1e131071'), (23, '1e-16383'), (24, repeat('9', 1000)::numeric),
  (25, ('0.' || repeat('3', 16383))::numeric), (26, NULL);

-- identity (non-strict: NULL arrives as null)
CREATE FUNCTION nm_id(x numeric) RETURNS numeric LANGUAGE plzig AS $$ return x; $$;
SELECT count(*) AS rows, count(*) FILTER (WHERE nm_id(n)::text IS NOT DISTINCT FROM n::text) AS identical
FROM nm_vals;
SELECT nm_id(NULL) IS NULL AS null_ok;

-- what the function sees: text (numeric_out's), scale, weight, predicates
CREATE FUNCTION nm_view(x numeric) RETURNS text STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{d} {d} {s}{s}{s}{s}{s}", .{
        if (x.isFinite()) x.scale() else 0, if (x.isFinite()) x.weight() else 0,
        if (x.isNaN()) "N" else "-", if (x.isInf()) "I" else "-", if (x.isFinite()) "F" else "-",
        if (x.isZero()) "Z" else "-", if (x.isNegative()) "M" else "-" });
$$;
CREATE FUNCTION nm_text(x numeric) RETURNS text STRICT LANGUAGE plzig AS $$ return try x.toText(); $$;
SELECT id, left(n::text, 40) AS n, nm_view(n), nm_text(n) = n::text AS text_same
FROM nm_vals WHERE n IS NOT NULL ORDER BY id;
SELECT count(*) FILTER (WHERE split_part(nm_view(n), ' ', 1)::int IS DISTINCT FROM scale(n)) AS scale_mismatches
FROM nm_vals WHERE n IS NOT NULL AND n <> 'NaN' AND abs(n) <> 'Infinity';

-- ordering: every pair, against SQL's comparison operators
CREATE FUNCTION nm_cmp(a numeric, b numeric) RETURNS int STRICT LANGUAGE plzig AS $$
    return switch (plzig.Numeric.order(a, b)) { .lt => -1, .eq => 0, .gt => 1 };
$$;
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE nm_cmp(x.n, y.n) <> CASE WHEN x.n < y.n THEN -1 WHEN x.n = y.n THEN 0 ELSE 1 END) AS mismatches
FROM nm_vals x, nm_vals y WHERE x.n IS NOT NULL AND y.n IS NOT NULL;

-- conversions to i64 and f64
CREATE FUNCTION nm_i64(x numeric) RETURNS int8 STRICT LANGUAGE plzig AS $$ return try x.toI64(); $$;
CREATE FUNCTION nm_f64(x numeric) RETURNS float8 STRICT LANGUAGE plzig AS $$ return try x.toF64(); $$;
SELECT id, nm_err(format('SELECT nm_i64(%L)', n)) AS i64, nm_err(format('SELECT nm_f64(%L)', n)) AS f64,
       left(nm_err(format('SELECT %L::numeric::float8', n)), 40) AS sql_f64
FROM nm_vals WHERE n IS NOT NULL ORDER BY id;
SELECT count(*) FILTER (WHERE nm_i64(n) <> n::int8) AS i64_mismatches,
       count(*) FILTER (WHERE nm_f64(n) IS DISTINCT FROM n::float8) AS f64_mismatches
FROM nm_vals WHERE n IS NOT NULL AND n = trunc(n) AND abs(n) < 9e18 AND abs(n) <> 'Infinity';
-- random values: toF64 is correctly rounded, as numeric::float8 is
SELECT count(*) > 1990 AS enough, count(*) FILTER (WHERE nm_f64(v) IS DISTINCT FROM v::float8) AS f64_mismatches
FROM (SELECT (random() * 10 ^ (floor(random() * 600) - 300))::numeric(1000, 400) * (CASE WHEN random() < 0.5 THEN -1 ELSE 1 END) AS v
        FROM generate_series(1, 2000)) s
WHERE v <> 0 AND abs(v) BETWEEN 1e-307 AND 1e308;
SELECT count(*) FILTER (WHERE nm_f64(v) IS DISTINCT FROM v::float8) AS f64_mismatches_17_digits
FROM (SELECT ('0.' || lpad(floor(random() * 1e17)::int8::text, 17, '0') || 'e' || (floor(random() * 600) - 300))::numeric AS v
        FROM generate_series(1, 2000)) s
WHERE v <> 0;

-- conversions from i64 and f64, and parsing, built by the function
CREATE FUNCTION nm_from_i64(x int8) RETURNS numeric STRICT LANGUAGE plzig AS $$ return try plzig.Numeric.fromI64(x); $$;
CREATE FUNCTION nm_from_f64(x float8) RETURNS numeric STRICT LANGUAGE plzig AS $$ return try plzig.Numeric.fromF64(x); $$;
CREATE FUNCTION nm_parse(t text) RETURNS numeric STRICT LANGUAGE plzig AS $$ return try plzig.Numeric.parse(t); $$;
SELECT x, nm_from_i64(x)::text = x::numeric::text AS same
FROM unnest(ARRAY[0, 1, -1, 9999, 10000, -10001, 100000000, 9223372036854775807, -9223372036854775808]::int8[]) x;
SELECT count(*) FILTER (WHERE nm_from_i64(x)::text <> x::numeric::text) AS i64_mismatches
FROM (SELECT ((random() - 0.5) * 18446744073709551615::numeric)::numeric(30, 0)::int8 AS x FROM generate_series(1, 2000)) s;
SELECT x, left(nm_from_f64(x)::text, 30) AS guest, nm_from_f64(x)::text = x::numeric::text AS same
FROM unnest(ARRAY['0', '-0', '0.1', '1e20', '123456789012345678', '-1.5', '1e-5', '2.384185791015625e-07',
                  '7.152557373046875e-07', '1.7976931348623157e308', '5e-324', 'NaN', 'Infinity', '-Infinity']::float8[]) x;
-- random doubles from random bit patterns, all magnitudes
CREATE FUNCTION nm_bits_to_f64(b int8) RETURNS float8 STRICT LANGUAGE plzig AS $$ return @bitCast(b); $$;
SELECT count(*) > 2900 AS enough, count(*) FILTER (WHERE nm_from_f64(x)::text <> x::numeric::text) AS f64_mismatches
FROM (SELECT nm_bits_to_f64((floor(random() * 2147483648)::int8 << 32) | floor(random() * 4294967296)::int8) AS x
        FROM generate_series(1, 3000)) s
WHERE x = x AND abs(x) <> 'Infinity';
-- parsing: numeric_in's result for the same text
SELECT t, nm_err(format('SELECT nm_parse(%L)', t)) AS guest, nm_err(format('SELECT %L::numeric', t)) AS sql,
       CASE WHEN nm_err(format('SELECT %L::numeric', t)) = 'ok' THEN nm_parse(t)::text = t::numeric::text END AS same
FROM unnest(ARRAY['0', '-0', '00.0100', '  1.5  ', '+.5', '5.', '-0.001e3', '1e-5', '1.5E+3', 'NaN', ' nan ',
                  'Infinity', '-inf', '+INF', '1e131071', '1e-16383', '12345678901234567890.123456789',
                  '', ' ', 'abc', '1.2.3', '1e', '--1', '1 000', '1e131072', '1e-16384']) t;
SELECT count(*) AS n, count(*) FILTER (WHERE nm_parse(t)::text <> t::numeric::text) AS parse_mismatches
FROM (SELECT (CASE WHEN random() < 0.5 THEN '-' ELSE '' END) ||
             lpad((random() * 1e15)::int8::text, 1 + floor(random() * 18)::int, '0') ||
             CASE WHEN random() < 0.7 THEN '.' || (random() * 1e10)::int8::text ELSE '' END ||
             CASE WHEN random() < 0.3 THEN 'e' || (floor(random() * 80) - 40)::text ELSE '' END AS t
        FROM generate_series(1, 3000)) s;

-- arithmetic by the host: PostgreSQL's results exactly
CREATE FUNCTION nm_op(op text, a numeric, b numeric, k int) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const N = plzig.Numeric;
    if (std.mem.eql(u8, op, "+")) return try a.add(b);
    if (std.mem.eql(u8, op, "-")) return try a.sub(b);
    if (std.mem.eql(u8, op, "*")) return try a.mul(b);
    if (std.mem.eql(u8, op, "/")) return try a.div(b);
    if (std.mem.eql(u8, op, "div")) return try N.divTrunc(a, b);
    if (std.mem.eql(u8, op, "%")) return try a.mod(b);
    if (std.mem.eql(u8, op, "round")) return try a.round(k);
    if (std.mem.eql(u8, op, "trunc")) return try a.trunc(k);
    if (std.mem.eql(u8, op, "abs")) return try a.abs();
    if (std.mem.eql(u8, op, "neg")) return try a.neg();
    return error.UnknownOp;
$$;
CREATE FUNCTION nm_sql(op text, a numeric, b numeric, k int) RETURNS numeric LANGUAGE sql AS $$
    SELECT CASE op WHEN '+' THEN a + b WHEN '-' THEN a - b WHEN '*' THEN a * b WHEN '/' THEN a / b
                   WHEN 'div' THEN div(a, b) WHEN '%' THEN a % b WHEN 'round' THEN round(a, k)
                   WHEN 'trunc' THEN trunc(a, k) WHEN 'abs' THEN abs(a) WHEN 'neg' THEN -a END
$$;
SELECT op, count(*) AS cases,
       count(*) FILTER (WHERE nm_err(format('SELECT nm_op(%L, %L, %L, %s)', op, x.n, y.n, k))
                              IS DISTINCT FROM nm_err(format('SELECT nm_sql(%L, %L, %L, %s)', op, x.n, y.n, k))) AS error_mismatches,
       count(*) FILTER (WHERE nm_err(format('SELECT nm_sql(%L, %L, %L, %s)', op, x.n, y.n, k)) = 'ok'
                          AND nm_op(op, x.n, y.n, k)::text <> nm_sql(op, x.n, y.n, k)::text) AS value_mismatches
FROM unnest(ARRAY['+', '-', '*', '/', 'div', '%', 'round', 'trunc', 'abs', 'neg']) op,
     (SELECT n FROM nm_vals WHERE n IS NOT NULL AND id NOT IN (22, 23, 24, 25)) x,
     (SELECT n FROM nm_vals WHERE n IS NOT NULL AND id NOT IN (22, 23, 24, 25)) y,
     unnest(ARRAY[-2, 0, 3]) k
WHERE k = 0 OR op IN ('round', 'trunc')
GROUP BY op ORDER BY op;
-- SQL errors surface as such
SELECT nm_err('SELECT nm_op(''/'', 1, 0, 0)'), nm_err('SELECT nm_op(''%'', 1, 0, 0)'),
       nm_err('SELECT nm_op(''*'', ''1e131071'', 10, 0)'), nm_err('SELECT nm_op(''+'', ''NaN'', 1, 0)');
-- results larger than the SDK's stack buffer, and huge operands
SELECT nm_op('*', repeat('9', 1000)::numeric, repeat('9', 1000)::numeric, 0) = repeat('9', 1000)::numeric ^ 2 AS big_product,
       nm_op('+', '1e131071', '1e-16383', 0) = '1e131071'::numeric + '1e-16383'::numeric AS widest_sum;

-- a loop of arithmetic in one call
CREATE FUNCTION nm_series(n int) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const N = plzig.Numeric;
    var acc = N.zero;
    const third = try N.parse("0.333");
    var i: i64 = 1;
    while (i <= n) : (i += 1) acc = try acc.add(try (try N.fromI64(i)).mul(third));
    return acc;
$$;
SELECT nm_series(1000) = (SELECT sum(i * 0.333) FROM generate_series(1, 1000) i) AS series_same;

-- typmods: none on function results (as for every language), a domain's
-- typmod applies through its input function, a column's at INSERT
CREATE DOMAIN nm_money AS numeric(7, 2) CHECK (VALUE >= 0);
CREATE FUNCTION nm_dom(x numeric) RETURNS nm_money STRICT LANGUAGE plzig AS $$ return try x.toText(); $$;
CREATE FUNCTION nm_ret52(x numeric) RETURNS numeric(5, 2) STRICT LANGUAGE plzig AS $$ return x; $$;
SELECT nm_dom(12.345), nm_dom(12.344), nm_ret52(123.456),
       nm_err('SELECT nm_dom(123456.7)'), nm_err('SELECT nm_dom(-1)');
CREATE TABLE nm_typmod (v numeric(5, 2));
CREATE FUNCTION nm_insert(x numeric) RETURNS void STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("INSERT INTO nm_typmod VALUES ($1)", &.{.numeric});
    defer p.free();
    _ = try p.execute(.{x});
$$;
SELECT nm_insert(1.005), nm_insert(-999.994);
SELECT nm_err('SELECT nm_insert(1000)');
SELECT v FROM nm_typmod ORDER BY v;

-- malformed numerics from the function: rejected by the host (numeric_recv),
-- as a result and as an SPI parameter
CREATE FUNCTION nm_bad(which int) RETURNS numeric STRICT LANGUAGE plzig AS $$
    const bad = [_][]const u8{
        "",                                              // too short
        "\x00\x01\x00\x00\x00\x00\x00",                  // 7 bytes
        "\x00\x01\x00\x00\x00\x00\x00\x00",              // 1 digit announced, none there
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",      // a digit that was not announced
        "\x00\x01\x00\x00\x00\x00\x00\x00\x27\x10",      // digit 10000
        "\x00\x01\x00\x00\x00\x00\x00\x00\xff\xff",      // digit -1
        "\x00\x00\x00\x00\x80\x00\x00\x00",              // sign 0x8000
        "\x00\x00\x00\x00\xe0\x00\x00\x00",              // sign 0xE000
        "\x00\x00\x00\x00\x00\x00\x40\x00",              // dscale 0x4000
        "\x00\x01\x80\x00\x00\x00\x00\x00\x00\x01",      // weight -32768: 1e-131072, dscale 0: truncated to 0
        "\x00\x01\x7f\xff\x00\x00\x00\x00\x00\x01",      // weight 32767: 1e131068, fine
        "\x00\x02\x00\x00\x00\x00\x00\x04\x00\x00\x00\x01", // 0.0001 with a leading zero digit: normalised
        "\x00\x00\x00\x05\xc0\x00\x00\x07",              // NaN with odd weight and scale: NaN
    };
    const i: usize = @intCast(which);
    return plzig.Numeric{ .wire = bad[i] };
$$;
SELECT w, left(nm_err(format('SELECT nm_bad(%s)', w)), 90) AS result FROM generate_series(0, 12) w;
SELECT nm_bad(9) AS truncated, length(nm_bad(10)::text) AS digits, nm_bad(11)::text = '0.0001' AS normalised, nm_bad(12) AS nan;
CREATE FUNCTION nm_bad_param(which int) RETURNS text STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT $1::text", &.{.numeric});
    defer p.free();
    const bad = [_][]const u8{ "\x00\x01\x00\x00\x00\x00\x00\x00\x27\x10", "\x00\x00\x00\x00\x80\x00\x00\x00", "\x00\x05" };
    const r = try p.execute(.{plzig.Numeric{ .wire = bad[@intCast(which)] }});
    return try (try r.row(0)).get([]const u8, 0);
$$;
SELECT w, nm_err(format('SELECT nm_bad_param(%s)', w)) FROM generate_series(0, 2) w;
CREATE FUNCTION nm_bad_op() RETURNS numeric LANGUAGE plzig AS $$
    const bad = plzig.Numeric{ .wire = "\x00\x01\x00\x00\x00\x00\x00\x00\x27\x10" };
    return try plzig.Numeric.add(bad, plzig.Numeric.zero);
$$;
SELECT nm_err('SELECT nm_bad_op()');
-- fromWire refuses what numeric_recv refuses, before the host sees it
CREATE FUNCTION nm_from_wire(b bytea) RETURNS text STRICT LANGUAGE plzig AS $$
    const n = plzig.Numeric.fromWire(b) catch |err| return @errorName(err);
    return try n.toText();
$$;
SELECT nm_from_wire(numeric_send(n)) = n::text AS from_numeric_send FROM nm_vals WHERE id = 13;
SELECT nm_from_wire('\x00010000000000002710'), nm_from_wire('\x0000'), nm_from_wire('\x0000000080000000');

-- SPI: numeric columns (Result.row, cursor) back as prepared parameters
CREATE FUNCTION nm_spi(use_cursor bool) RETURNS text STRICT LANGUAGE plzig AS $$
    const q = "SELECT id, n FROM nm_vals ORDER BY id";
    var check = try plzig.spi.prepare("SELECT n::text IS NOT DISTINCT FROM $2::text AND pg_typeof($2) = 'numeric'::regtype FROM nm_vals WHERE id = $1", &.{ .int4, .numeric });
    defer check.free();
    var same: usize = 0;
    var n: usize = 0;
    if (use_cursor) {
        var c = try plzig.spi.open(q, &.{});
        while (try c.next()) |r| {
            const id = try r.get(i32, 0);
            const v = try r.get(?plzig.Numeric, 1);
            // the row is reused by the next fetch: copy the value first
            const copy: ?plzig.Numeric = if (v) |x| .{ .wire = try plzig.allocator.dupe(u8, x.wire) } else null;
            n += 1;
            const res = try check.execute(.{ id, copy });
            if (try (try res.row(0)).get(bool, 0)) same += 1;
        }
    } else {
        var p = try plzig.spi.prepare(q, &.{});
        defer p.free();
        const res = try p.execute(.{});
        var ids: [64]i32 = undefined;
        var vals: [64]?plzig.Numeric = undefined;
        while (n < res.rows) : (n += 1) {
            const r = try res.row(n);
            ids[n] = try r.get(i32, 0);
            vals[n] = if (try r.get(?plzig.Numeric, 1)) |x| .{ .wire = try plzig.allocator.dupe(u8, x.wire) } else null;
        }
        for (ids[0..n], vals[0..n]) |id, v| {
            const r2 = try check.execute(.{ id, v });
            if (try (try r2.row(0)).get(bool, 0)) same += 1;
        }
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d} rows, {d} identical", .{ n, same });
$$;
SELECT nm_spi(false), nm_spi(true);
-- the column kind, and a numeric column read as text is a mismatch
CREATE FUNCTION nm_kind() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT 1.5::numeric, 1.5::numeric(5,1), 1.5::numeric::text", &.{});
    const row = try r.row(0);
    const t = row.get([]const u8, 0);
    return try std.fmt.allocPrint(plzig.allocator, "{s} {s} {s} {any}", .{
        @tagName(try row.kind(0)), @tagName(try row.kind(1)), @tagName(try row.kind(2)), t });
$$;
SELECT nm_kind();
-- many rows through a cursor: the sum equals SQL's
CREATE FUNCTION nm_sum() RETURNS numeric LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT g * 1.25 FROM generate_series(1, 5000) g", &.{});
    var acc = plzig.Numeric.zero;
    while (try c.next()) |r| acc = try acc.add(try r.get(plzig.Numeric, 0));
    return acc;
$$;
SELECT nm_sum() = (SELECT sum(g * 1.25) FROM generate_series(1, 5000) g) AS sum_same;

DROP TABLE nm_vals, nm_typmod;
