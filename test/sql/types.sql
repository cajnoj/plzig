--
-- types: every natively mapped type, text-I/O types, NULLs, encoding checks
--
\set VERBOSITY terse

CREATE FUNCTION t_bool(x boolean) RETURNS boolean LANGUAGE plzig AS $$
    const v = x orelse return null;
    return !v;
$$;
SELECT t_bool(true), t_bool(false), t_bool(NULL) IS NULL AS n;

CREATE FUNCTION t_int2(x smallint) RETURNS smallint STRICT LANGUAGE plzig AS $$
    return x -% 1;
$$;
SELECT t_int2(32767::smallint), t_int2((-32768)::smallint);

CREATE FUNCTION t_int4(x integer) RETURNS integer STRICT LANGUAGE plzig AS $$
    return x * 2;
$$;
SELECT t_int4(-21), t_int4(1073741823);

CREATE FUNCTION t_int8(x bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
    return x + 1;
$$;
SELECT t_int8(9223372036854775806), t_int8(-9223372036854775808);

CREATE FUNCTION t_float4(x real) RETURNS real STRICT LANGUAGE plzig AS $$
    return x * 2.5;
$$;
SELECT t_float4(1.5), t_float4('-inf'), t_float4('NaN');

CREATE FUNCTION t_float8(x double precision) RETURNS double precision STRICT LANGUAGE plzig AS $$
    return @sqrt(x);
$$;
SELECT t_float8(2.0), t_float8(1e300), t_float8(-1);

CREATE FUNCTION t_text(x text) RETURNS text STRICT LANGUAGE plzig AS $$
    const out = try plzig.allocator.alloc(u8, x.len);
    for (x, 0..) |c, i| out[x.len - 1 - i] = c;
    return out;
$$;
SELECT t_text('abc'), t_text(''), length(t_text(repeat('x', 100000)));

-- multibyte text arrives as raw bytes in the database encoding (UTF8 here)
CREATE FUNCTION t_len(x text) RETURNS int STRICT LANGUAGE plzig AS $$
    return @intCast(x.len);
$$;
SELECT t_len('héllo'), t_len('日本');

-- returned text must be valid in the database encoding
CREATE FUNCTION t_badtext(which int) RETURNS text STRICT LANGUAGE plzig AS $$
    return switch (which) {
        0 => "ok",
        1 => "\xff\xfe",
        else => "nul\x00byte",
    };
$$;
SELECT t_badtext(0);
SELECT t_badtext(1);
SELECT t_badtext(2);

-- text and bytea results are copied once, straight into the result value,
-- and checked there: the edges of that check, large values, and values that
-- must not alias guest memory (the next call reuses the guest's arena)
CREATE FUNCTION t_textedge(which int) RETURNS text STRICT LANGUAGE plzig AS $$
    return switch (which) {
        0 => "",
        1 => "\xc3\xa9t\xc3\xa9",
        2 => "x\x00",          // NUL as the last byte
        3 => "\x00",           // nothing but a NUL
        4 => "ab\xc3",         // two-byte character cut at the end
        else => "\xe2\x82",    // three-byte character cut at the end
    };
$$;
SELECT t_textedge(0) = '' AS empty, t_textedge(1);
SELECT t_textedge(2);
SELECT t_textedge(3);
SELECT t_textedge(4);
SELECT t_textedge(5);
CREATE FUNCTION t_bigtext(n int, bad boolean) RETURNS text STRICT LANGUAGE plzig AS $$
    const out = try plzig.allocator.alloc(u8, @as(usize, @intCast(n)) * 2);
    var i: usize = 0;
    while (i < out.len) : (i += 2) {
        out[i] = 0xc3;
        out[i + 1] = 0xa9;
    }
    if (bad) out[out.len - 1] = 0x00;
    return out;
$$;
SELECT length(t_bigtext(524288, false)), t_bigtext(524288, false) = repeat('é', 524288) AS same;
SELECT t_bigtext(524288, true);
CREATE FUNCTION t_echo(x text) RETURNS text STRICT LANGUAGE plzig AS $$
    return x;
$$;
CREATE FUNCTION t_becho(x bytea) RETURNS bytea STRICT LANGUAGE plzig AS $$
    return x;
$$;
SELECT array_agg(t_echo(x) ORDER BY x) AS texts, array_agg(t_becho(convert_to(x, 'UTF8')) ORDER BY x) AS byteas
FROM (VALUES ('a'), ('bb'), ('ccc'), ('dé')) AS v(x);
SELECT t_echo(repeat('ü', 300000)) = repeat('ü', 300000) AS same_text,
       t_becho(decode(repeat('00ff', 300000), 'hex')) = decode(repeat('00ff', 300000), 'hex') AS same_bytea;
-- text parameters of prepared statements, spi.execute and spi.open: same rules
CREATE FUNCTION t_spitext(path int, which int) RETURNS text STRICT LANGUAGE plzig AS $$
    const v: []const u8 = switch (which) {
        0 => "h\xc3\xa9",
        1 => "",
        2 => "a\x00",
        3 => "\xff",
        else => "ab\xc3",
    };
    const q = "SELECT $1 || '|' || octet_length($1)";
    switch (path) {
        0 => {
            var p = try plzig.spi.prepare(q, &.{.text});
            defer p.free();
            const r = try p.execute(.{v});
            return try (try r.row(0)).get([]const u8, 0);
        },
        1 => {
            const r = try plzig.spi.execute(q, &.{v});
            return (try r.get(0, 0)).?;
        },
        else => {
            var c = try plzig.spi.open(q, &.{v});
            defer c.close();
            return try plzig.allocator.dupe(u8, try (try c.next()).?.get([]const u8, 0));
        },
    }
$$;
SELECT p, t_spitext(p, 0) AS valid, t_spitext(p, 1) AS empty FROM generate_series(0, 2) AS p;
SELECT t_spitext(0, 2);
SELECT t_spitext(0, 3);
SELECT t_spitext(0, 4);
SELECT t_spitext(1, 3);
SELECT t_spitext(2, 2);
SELECT t_spitext(2, 4);

CREATE FUNCTION t_varchar(x varchar, y char(5)) RETURNS varchar LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "[{s}|{s}]", .{ x orelse "-", y orelse "-" });
$$;
SELECT t_varchar('ab', 'cd'), t_varchar(NULL, NULL);

-- bytea is raw bytes both ways; any byte value is fine
CREATE FUNCTION t_bytea(x bytea) RETURNS bytea STRICT LANGUAGE plzig AS $$
    const out = try plzig.allocator.alloc(u8, x.len + 2);
    @memcpy(out[0..x.len], x);
    out[x.len] = 0x00;
    out[x.len + 1] = 0xff;
    return out;
$$;
SELECT t_bytea('\x0102'::bytea), t_bytea(''::bytea);

-- everything else travels as its text representation
CREATE FUNCTION t_io(n numeric, d date, a int[], j jsonb) RETURNS text LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{s} {s} {s} {s}",
        .{ n orelse "null", d orelse "null", a orelse "null", j orelse "null" });
$$;
SET datestyle = 'ISO, YMD';
SELECT t_io(3.14159, '2024-02-29', ARRAY[1,NULL,3], '{"b": 1, "a": [true]}');
SELECT t_io(NULL, NULL, NULL, NULL);

CREATE FUNCTION t_numeric(x numeric) RETURNS numeric STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{s}0", .{x});
$$;
SELECT t_numeric(1.5);

-- results go through the type's input function: invalid values are rejected
CREATE FUNCTION t_date(s text) RETURNS date STRICT LANGUAGE plzig AS $$
    return s;
$$;
SELECT t_date('2024-01-31');
SELECT t_date('2024-02-30');

-- domains: constraints are enforced by PostgreSQL on the result
CREATE DOMAIN small_pos AS int CHECK (VALUE BETWEEN 1 AND 10);
CREATE FUNCTION t_domain(x small_pos) RETURNS small_pos STRICT LANGUAGE plzig AS $$
    const v = try std.fmt.parseInt(i32, x, 10);
    return try std.fmt.allocPrint(plzig.allocator, "{d}", .{v * 3});
$$;
SELECT t_domain(3);
SELECT t_domain(4);

-- enums and composites
CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
CREATE FUNCTION t_enum(m mood) RETURNS mood STRICT LANGUAGE plzig AS $$
    if (std.mem.eql(u8, m, "sad")) return "ok";
    return "happy";
$$;
SELECT t_enum('sad'), t_enum('ok');
SELECT t_enum('ok') = 'happy'::mood AS eq;

CREATE TYPE pair AS (a int, b text);
CREATE FUNCTION t_comp(p pair) RETURNS pair STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "(99,\"was {s}\")", .{p});
$$;
SELECT * FROM t_comp(ROW(1, 'x')::pair);

-- arrays come back through array_in
CREATE FUNCTION t_array(n int) RETURNS int[] STRICT LANGUAGE plzig AS $$
    var list: std.ArrayList(u8) = .empty;
    try list.append(plzig.allocator, '{');
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try list.append(plzig.allocator, ',');
        try list.print(plzig.allocator, "{d}", .{i * i});
    }
    try list.append(plzig.allocator, '}');
    return list.items;
$$;
SELECT t_array(5), t_array(0);

-- void result
CREATE FUNCTION t_void() RETURNS void LANGUAGE plzig AS $$ $$;
SELECT t_void();

-- unsupported signatures are rejected at CREATE time
CREATE FUNCTION t_setof() RETURNS SETOF int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION t_out(x int, OUT y int) LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION t_inout(INOUT x int) LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION t_poly(x anyelement) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION t_variadic(VARIADIC x int[]) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION t_record() RETURNS record LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION t_table() RETURNS TABLE (a int) LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION t_internal(x internal) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION "t_badname"("bad name" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION t_shadow(std int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
