--
-- types_more: domains, arrays, composites, enums, ranges, "char", name,
-- numeric, json(b), uuid, special floats, large and TOASTed values
--
\set VERBOSITY terse
SET extra_float_digits = 0;

-- domains over text-I/O types: constraints apply to results, including NULL
CREATE DOMAIN tm_even AS int CHECK (VALUE % 2 = 0);
CREATE DOMAIN tm_nn_text AS text NOT NULL;
CREATE DOMAIN tm_nn_int AS int NOT NULL CHECK (VALUE > 0);
CREATE DOMAIN tm_short AS varchar(3);
CREATE FUNCTION tm_even_of(x int) RETURNS tm_even STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{d}", .{x});
$$;
SELECT tm_even_of(2), tm_even_of(-4);
SELECT tm_even_of(3);
CREATE FUNCTION tm_nn(x text) RETURNS tm_nn_text LANGUAGE plzig AS $$
    return x;
$$;
SELECT tm_nn('a'), tm_nn('');
SELECT tm_nn(NULL);
CREATE FUNCTION tm_nn_int_of(x int) RETURNS tm_nn_int LANGUAGE plzig AS $$
    const v = x orelse return null;
    return try std.fmt.allocPrint(plzig.allocator, "{d}", .{v});
$$;
SELECT tm_nn_int_of(5);
SELECT tm_nn_int_of(0);
SELECT tm_nn_int_of(NULL);
-- a domain over int arrives as text (its type is not int)
CREATE FUNCTION tm_dom_arg(x tm_even) RETURNS text STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "[{s}]", .{x});
$$;
SELECT tm_dom_arg(8);
-- a domain over varchar: the typmod of the domain applies to the result
CREATE FUNCTION tm_short_of(x text) RETURNS tm_short STRICT LANGUAGE plzig AS $$
    return x;
$$;
SELECT tm_short_of('abc');
SELECT tm_short_of('abcd');
-- the declared typmod of a result is not kept by PostgreSQL (as for every language)
CREATE FUNCTION tm_numeric52(x numeric) RETURNS numeric(5,2) STRICT LANGUAGE plzig AS $$
    return x;
$$;
SELECT tm_numeric52(123.456);

-- arrays
CREATE FUNCTION tm_arr(a text[]) RETURNS text[] STRICT LANGUAGE plzig AS $$
    return a;
$$;
SELECT tm_arr(ARRAY['a b', NULL, '"q"', '', 'NULL']), tm_arr('{}'), tm_arr('[0:1]={x,y}');
CREATE FUNCTION tm_arr2(a int[]) RETURNS int[] STRICT LANGUAGE plzig AS $$
    return a;
$$;
SELECT tm_arr2('{{1,2},{3,4}}');
CREATE FUNCTION tm_badarr() RETURNS int[] LANGUAGE plzig AS $$
    return "{1,two}";
$$;
SELECT tm_badarr();

-- composites, arrays of composites, enums
CREATE TYPE tm_point AS (x float8, y float8, tag text);
CREATE FUNCTION tm_comp(p tm_point) RETURNS tm_point STRICT LANGUAGE plzig AS $$
    return p;
$$;
SELECT tm_comp(ROW(1.5, NULL, 'a,b "c"')::tm_point);
SELECT (tm_comp(ROW(1, 2, NULL)::tm_point)).*;
CREATE FUNCTION tm_comp_arr(a tm_point[]) RETURNS tm_point[] STRICT LANGUAGE plzig AS $$
    return a;
$$;
SELECT tm_comp_arr(ARRAY[ROW(1, 2, 'x')::tm_point, NULL]);
CREATE FUNCTION tm_badcomp() RETURNS tm_point LANGUAGE plzig AS $$
    return "(1,2,3,4)";
$$;
SELECT tm_badcomp();
CREATE TYPE tm_color AS ENUM ('red', 'green', 'blue');
CREATE FUNCTION tm_next_color(c tm_color) RETURNS tm_color STRICT LANGUAGE plzig AS $$
    if (std.mem.eql(u8, c, "red")) return "green";
    if (std.mem.eql(u8, c, "green")) return "blue";
    return "purple";
$$;
SELECT tm_next_color('red'), tm_next_color('green');
SELECT tm_next_color('blue');

-- ranges
CREATE FUNCTION tm_range(r int4range) RETURNS int4range STRICT LANGUAGE plzig AS $$
    return r;
$$;
SELECT tm_range('[1,10)'), tm_range('empty'), tm_range('(,5]'), tm_range('(1,2)');
CREATE FUNCTION tm_tsrange(r tstzrange) RETURNS text STRICT LANGUAGE plzig AS $$
    return r;
$$;
SET timezone = 'UTC';
SET datestyle = 'ISO, YMD';
SELECT tm_tsrange('[2024-01-01, 2024-02-01)');
CREATE FUNCTION tm_badrange() RETURNS int4range LANGUAGE plzig AS $$
    return "[5,1)";
$$;
SELECT tm_badrange();

-- "char" and name
CREATE FUNCTION tm_char(c "char", n name) RETURNS "char" STRICT LANGUAGE plzig AS $$
    plzig.notice("char [{s}] ({d} bytes), name [{s}] ({d} bytes)", .{ c, c.len, n, n.len });
    return n[n.len - 1 ..];
$$;
SELECT tm_char('x', 'pg_class');
CREATE FUNCTION tm_name(n text) RETURNS name STRICT LANGUAGE plzig AS $$
    return n;
$$;
SELECT tm_name(repeat('n', 70)) = repeat('n', 63) AS truncated_to_63;

-- numeric: arbitrary precision, NaN and infinities (14+) through text
CREATE FUNCTION tm_num(n numeric) RETURNS numeric STRICT LANGUAGE plzig AS $$
    return n;
$$;
SELECT tm_num('NaN') AS nan, tm_num(12345678901234567890.123456789) AS big,
       tm_num(-0.000000000000000000001) AS small, tm_num(1e-300) = 1e-300 AS tiny;
SELECT tm_num('Infinity') AS inf, tm_num('-Infinity') AS minf;

-- json and jsonb: json keeps the text, jsonb is normalised (a jsonb
-- argument is read in place, a jsonb result is JSON text; more in types_jsonb)
CREATE FUNCTION tm_json(j json, b jsonb) RETURNS jsonb STRICT LANGUAGE plzig AS $$
    return plzig.jsonText(try std.fmt.allocPrint(plzig.allocator, "[{s}, {s}]", .{ j, (try b.toJsonText()).text }));
$$;
SELECT tm_json('{"a": 1,  "a": 2}', '{"b": [1, 2.50],  "a": null}');
CREATE FUNCTION tm_json_text(j json) RETURNS json STRICT LANGUAGE plzig AS $$
    return j;
$$;
SELECT tm_json_text('{"a": 1,  "a": 2}');
CREATE FUNCTION tm_badjson() RETURNS jsonb LANGUAGE plzig AS $$
    return plzig.jsonText("{bad");
$$;
SELECT tm_badjson();

-- uuid (native: plzig.Uuid; more in types_fixed)
CREATE FUNCTION tm_uuid(u uuid) RETURNS uuid STRICT LANGUAGE plzig AS $$
    var buf: [36]u8 = undefined;
    _ = u.format(&buf);
    for (&buf) |*c| c.* = std.ascii.toUpper(c.*);
    return try plzig.Uuid.parse(&buf);
$$;
SELECT tm_uuid('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
CREATE FUNCTION tm_baduuid() RETURNS uuid LANGUAGE plzig AS $$
    return try plzig.Uuid.parse("not-a-uuid");
$$;
SELECT tm_baduuid();

-- NaN and infinities in both directions, signed zero
CREATE FUNCTION tm_f8(x float8, y float4) RETURNS float8 STRICT LANGUAGE plzig AS $$
    return x + y;
$$;
SELECT tm_f8('NaN', 1), tm_f8('Infinity', '-Infinity'), tm_f8('-Infinity', 0), tm_f8('Infinity', 1);
CREATE FUNCTION tm_special(k int) RETURNS float4 STRICT LANGUAGE plzig AS $$
    return switch (k) {
        0 => std.math.inf(f32),
        1 => -std.math.inf(f32),
        2 => std.math.nan(f32),
        3 => -0.0,
        else => std.math.floatMax(f32),
    };
$$;
SELECT tm_special(0), tm_special(1), tm_special(2), tm_special(3)::text, tm_special(4);
CREATE FUNCTION tm_classify(x float8) RETURNS text STRICT LANGUAGE plzig AS $$
    if (std.math.isNan(x)) return "nan";
    if (std.math.isPositiveInf(x)) return "+inf";
    if (std.math.isNegativeInf(x)) return "-inf";
    if (x == 0 and std.math.signbit(x)) return "-0";
    return "finite";
$$;
SELECT tm_classify('NaN'), tm_classify('Infinity'), tm_classify('-Infinity'), tm_classify('-0'), tm_classify(1);

--
-- large values: multi-MB text and bytea in and out, TOASTed and compressed
--
CREATE FUNCTION tm_echo(t text) RETURNS text STRICT LANGUAGE plzig AS $$
    return t;
$$;
CREATE FUNCTION tm_bytes_len(b bytea) RETURNS bigint STRICT LANGUAGE plzig AS $$
    return @intCast(b.len);
$$;
CREATE FUNCTION tm_bytes_sum(b bytea) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var s: u64 = 0;
    for (b) |c| s += c;
    return @intCast(s);
$$;
CREATE FUNCTION tm_make(mb int) RETURNS bytea STRICT LANGUAGE plzig AS $$
    const n: usize = @as(usize, @intCast(mb)) << 20;
    const out = try plzig.allocator.alloc(u8, n);
    for (out, 0..) |*c, i| c.* = @truncate(i *% 7);
    return out;
$$;
CREATE TABLE tm_big (id int, t text, b bytea);
-- compressible (stored compressed), and incompressible (stored out of line)
INSERT INTO tm_big VALUES (1, repeat('x', 5 * 1024 * 1024), tm_make(5));
INSERT INTO tm_big SELECT 2, string_agg(left(encode(sha256(i::text::bytea), 'hex'), 32), ''), NULL FROM generate_series(1, 100000) i;
SELECT id, pg_column_size(t) < octet_length(t) AS compressed,
       octet_length(tm_echo(t)) AS len, sha256(convert_to(tm_echo(t), 'UTF8')) = sha256(convert_to(t, 'UTF8')) AS same,
       tm_bytes_len(b) AS blen, tm_bytes_sum(b) AS bsum, sha256(b) = sha256(tm_make(5)) AS bsame
  FROM tm_big ORDER BY id;
SELECT octet_length(tm_echo(repeat('abcdefgh', 1024 * 1024))) AS len_8mb;
SELECT tm_bytes_len(tm_make(20)) AS len_20mb;
-- arguments larger than the guest memory cap (64MB by default)
SELECT octet_length(tm_echo(repeat('x', 70 * 1024 * 1024)));
SELECT 1 AS alive;
SET plzig.max_memory = '200MB';
SELECT octet_length(tm_echo(repeat('x', 70 * 1024 * 1024))) AS len_70mb;
RESET plzig.max_memory;
-- a large text-I/O value: an array of 100000 elements
CREATE FUNCTION tm_arr_len(a int[]) RETURNS int STRICT LANGUAGE plzig AS $$
    var n: i32 = 1;
    for (a) |c| {
        if (c == ',') n += 1;
    }
    return n;
$$;
SELECT tm_arr_len(array_agg(g)) FROM generate_series(1, 100000) g;
DROP TABLE tm_big;
RESET timezone;
RESET datestyle;
