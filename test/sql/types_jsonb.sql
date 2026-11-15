--
-- types_jsonb: jsonb arguments and columns in PostgreSQL's on-disk layout,
-- read in place by the SDK (plzig.Jsonb), and jsonb results/parameters as
-- JSON text through jsonb_in (plzig.JsonText).  Everything is compared with
-- SQL: jsonb_out's text, ->, ->>, jsonb_array_length, jsonb_object_keys.
--
\set VERBOSITY terse

CREATE FUNCTION jb_err(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- the guest's serialisation (jsonb_out's format), and the identity
CREATE FUNCTION jb_text(j jsonb) RETURNS text LANGUAGE plzig AS $$
    return ((try (j orelse return null).toJsonText())).text;
$$;
CREATE FUNCTION jb_id(j jsonb) RETURNS jsonb LANGUAGE plzig AS $$
    return try (j orelse return null).toJsonText();
$$;
-- lookups: a key of an object, an element of an array (JSON text of the value)
CREATE FUNCTION jb_get(j jsonb, k text) RETURNS text STRICT LANGUAGE plzig AS $$
    const r = try j.root();
    if (r != .object) return error.NotAnObject;
    const v = (try r.object.get(k)) orelse return null;
    return (try v.toJsonText()).text;
$$;
CREATE FUNCTION jb_at(j jsonb, i int) RETURNS text STRICT LANGUAGE plzig AS $$
    const r = try j.root();
    if (r != .array) return error.NotAnArray;
    const v = (try r.array.get(@intCast(i))) orelse return null;
    return (try v.toJsonText()).text;
$$;
CREATE FUNCTION jb_len(j jsonb) RETURNS int STRICT LANGUAGE plzig AS $$
    return switch (try j.root()) {
        .array => |a| @intCast(a.len()),
        .object => |o| @intCast(o.len()),
        else => -1,
    };
$$;
CREATE FUNCTION jb_kind(j jsonb) RETURNS text STRICT LANGUAGE plzig AS $$
    return @tagName(try j.root());
$$;

CREATE TABLE jb_docs (id int PRIMARY KEY, j jsonb);
INSERT INTO jb_docs VALUES
  (1, '{}'), (2, '[]'), (3, 'null'), (4, 'true'), (5, 'false'), (6, '0'), (7, '-12.5'), (8, '""'),
  (9, '"héllo wörld € 😀"'), (10, '{"a": 1}'), (11, '[1, "two", null, true, false, {"k": []}, [3.5]]'),
  (12, '{"b": 2, "a": 1, "cc": 3, "aaa": 4, "ab": 5, "ba": 6, "": 7}'),
  (13, '{"é": 1, "e": 2, "è": 3, "z": 4, "€": 5, "aa": 6}'),
  (14, '["", "a\"b\\c\u0001\n\t\r\b\f/", "\u007f", "\u0019"]'),
  (15, '{"x": {"y": {"z": [null, {"w": [[], {}]}]}}}'),
  -- numbers in every on-disk form: short and long numeric headers, negative
  -- weights, large scales
  (16, '[0, 1, -1, 1e100, -1e-100, 1e300, 0.1, 1.000000000000000000000000000000000000000000000000000000000000000000000000000, 123456789.123456789, 9999, 10000, -0.0000001, 1e-1000, 123e4567]'),
  (17, jsonb_build_object('nan', 'NaN'::numeric, 'inf', 'Infinity'::numeric, 'ninf', '-Infinity'::numeric, 'big', repeat('9', 1000)::numeric)),
  -- long keys, many keys of the same length, more than 32 children (offsets
  -- stored every 32 entries)
  (18, jsonb_build_object(repeat('k', 10000), 1, repeat('k', 9999), 2, repeat('j', 10000), 3)),
  (19, (SELECT jsonb_object_agg(lpad(g::text, 4, '0'), g) FROM generate_series(1, 300) g)),
  (20, (SELECT jsonb_agg(g) FROM generate_series(1, 1000) g)),
  (21, (SELECT jsonb_agg(jsonb_build_object('id', g, 'name', 'n' || g, 'tags', jsonb_build_array(g % 3, g % 5))) FROM generate_series(1, 200) g)),
  -- deep nesting
  (22, (repeat('[', 2000) || '1' || repeat(']', 2000))::jsonb),
  (23, (repeat('{"a": ', 1000) || '{}' || repeat('}', 1000))::jsonb),
  -- a large document: compressed and stored out of line
  (24, (SELECT jsonb_object_agg('key' || g, repeat('v', g % 50) || g) FROM generate_series(1, 20000) g)),
  (25, NULL);

SELECT count(*) AS docs,
       count(*) FILTER (WHERE jb_text(j) IS NOT DISTINCT FROM j::text) AS same_text,
       count(*) FILTER (WHERE jb_id(j) IS NOT DISTINCT FROM j) AS same_value
FROM jb_docs;
SELECT id, jb_kind(j), jb_len(j), left(jb_text(j), 60) AS text FROM jb_docs WHERE id <= 17 ORDER BY id;
SELECT pg_column_size(j) < octet_length(j::text) AS compressed FROM jb_docs WHERE id = 24;

-- every key of every object: the guest's lookup equals ->; missing keys
SELECT count(*) AS lookups, count(*) FILTER (WHERE jb_get(j, k) IS DISTINCT FROM (j -> k)::text) AS mismatches
FROM jb_docs, LATERAL jsonb_object_keys(j) k WHERE jsonb_typeof(j) = 'object';
SELECT count(*) AS lookups, count(*) FILTER (WHERE jb_get(j, k) IS NOT NULL) AS found
FROM jb_docs, unnest(ARRAY['', 'nope', 'A', 'aaaa', 'k', repeat('k', 10001), 'key0', 'key20001', '0000', '0301']) k
WHERE jsonb_typeof(j) = 'object' AND NOT j ? k;
-- every element of every array, and one past the end
SELECT count(*) AS lookups, count(*) FILTER (WHERE jb_at(j, i) IS DISTINCT FROM (j -> i)::text) AS mismatches
FROM jb_docs, LATERAL generate_series(0, jsonb_array_length(j)) i WHERE jsonb_typeof(j) = 'array';
SELECT count(*) FILTER (WHERE jb_len(j) <> CASE jsonb_typeof(j) WHEN 'array' THEN jsonb_array_length(j)
                                              WHEN 'object' THEN (SELECT count(*) FROM jsonb_object_keys(j)) ELSE -1 END) AS len_mismatches
FROM jb_docs WHERE j IS NOT NULL;
SELECT jb_err('SELECT jb_get(''[1]'', ''a'')'), jb_err('SELECT jb_at(''{}'', 0)');

-- numbers: the on-disk numeric decoded in the guest equals ->>'s text and
-- ::float8
CREATE FUNCTION jb_num(j jsonb, i int) RETURNS text STRICT LANGUAGE plzig AS $$
    const v = (try (try j.root()).array.get(@intCast(i))).?;
    const n = try v.number.numeric();
    const f = v.number.toF64() catch |err| return try std.fmt.allocPrint(plzig.allocator, "{f} {s}", .{ n, @errorName(err) });
    return try std.fmt.allocPrint(plzig.allocator, "{f} {e}", .{ n, f });
$$;
SELECT i, left(split_part(jb_num(j, i), ' ', 1), 30) AS guest, split_part(jb_num(j, i), ' ', 2) AS guest_f64, left(j ->> i, 30) AS sql,
       split_part(jb_num(j, i), ' ', 1) = j ->> i AS text_same,
       CASE WHEN jb_err(format('SELECT (%L::jsonb ->> %s)::float8', j, i)) = 'ok'
            THEN split_part(jb_num(j, i), ' ', 2)::float8 = (j ->> i)::float8 END AS f64_same
FROM jb_docs, generate_series(0, jsonb_array_length(j) - 1) i WHERE id = 16;
CREATE FUNCTION jb_numkey(j jsonb, k text) RETURNS numeric STRICT LANGUAGE plzig AS $$
    return try (try (try j.root()).object.get(k)).?.number.numeric();
$$;
-- (to_jsonb makes NaN and the infinities strings)
SELECT jb_get(j, 'nan') AS nan, jb_get(j, 'inf') AS inf, jb_get(j, 'ninf') AS ninf,
       jb_numkey(j, 'big') = repeat('9', 1000)::numeric AS big
FROM jb_docs WHERE id = 17;

-- strings: the stored bytes, multibyte characters and escapes included
CREATE FUNCTION jb_str(j jsonb, i int) RETURNS text STRICT LANGUAGE plzig AS $$
    return (try (try j.root()).array.get(@intCast(i))).?.string;
$$;
SELECT count(*) FILTER (WHERE jb_str(j, i) IS DISTINCT FROM j ->> i) AS string_mismatches
FROM jb_docs, generate_series(0, jsonb_array_length(j) - 1) i WHERE id = 14;
CREATE FUNCTION jb_root_str(j jsonb) RETURNS text STRICT LANGUAGE plzig AS $$ return (try j.root()).string; $$;
SELECT jb_root_str(j) = j #>> '{}' AS same, octet_length(jb_root_str(j)) FROM jb_docs WHERE id = 9;

-- iteration over pairs (sorted: by length, then bytes) and elements
CREATE FUNCTION jb_keys(j jsonb) RETURNS text STRICT LANGUAGE plzig AS $$
    var it = (try j.root()).object.iterator();
    var out: std.ArrayList(u8) = .empty;
    while (try it.next()) |e| try out.print(plzig.allocator, "{s}={s} ", .{ e.key, (try e.value.toJsonText()).text });
    return out.items;
$$;
SELECT jb_keys(j), (SELECT string_agg(format('%s=%s', k, j -> k), ' ') || ' ' FROM jsonb_object_keys(j) k) = jb_keys(j) AS same_order
FROM jb_docs WHERE id IN (12, 13) ORDER BY id;
CREATE FUNCTION jb_sum(j jsonb) RETURNS numeric STRICT LANGUAGE plzig AS $$
    var it = (try j.root()).array.iterator();
    var acc = plzig.Numeric.zero;
    while (try it.next()) |v| acc = try acc.add(try v.number.numeric());
    return acc;
$$;
SELECT jb_sum(j) = (SELECT sum(x::numeric) FROM jsonb_array_elements_text(j) x) AS sum_same FROM jb_docs WHERE id = 20;

-- results are JSON text, parsed by jsonb_in: invalid JSON is an SQL error,
-- duplicate keys are resolved as jsonb_in does, NULL is SQL NULL
CREATE FUNCTION jb_ret(t text) RETURNS jsonb LANGUAGE plzig AS $$
    return plzig.jsonText(t orelse return null);
$$;
SELECT jb_ret('{"b": 1, "a": [1, 2.50], "b": 3}'), jb_ret(NULL) IS NULL AS null_ok, jb_ret('  "x"  '), jb_ret('1e3');
SELECT jb_err('SELECT jb_ret(''{bad'')'), jb_err('SELECT jb_ret('''')'), jb_err('SELECT jb_ret(''"\u0000"'')');
-- a function's own value back, unchanged
SELECT count(*) FILTER (WHERE jb_ret(jb_text(j)) IS DISTINCT FROM j) AS roundtrip_mismatches FROM jb_docs;

-- SPI: jsonb columns (Result.row and cursors) read in place; parameters as
-- JSON text
CREATE FUNCTION jb_spi(use_cursor bool) RETURNS text STRICT LANGUAGE plzig AS $$
    const q = "SELECT id, j FROM jb_docs ORDER BY id";
    var check = try plzig.spi.prepare("SELECT j IS NOT DISTINCT FROM $2 AND pg_typeof($2) = 'jsonb'::regtype FROM jb_docs WHERE id = $1", &.{ .int4, .jsonb });
    defer check.free();
    var ids: [64]i32 = undefined;
    var texts: [64]?plzig.JsonText = undefined;
    var n: usize = 0;
    if (use_cursor) {
        var c = try plzig.spi.open(q, &.{});
        while (try c.next()) |r| : (n += 1) {
            ids[n] = try r.get(i32, 0);
            texts[n] = if (try r.get(?plzig.Jsonb, 1)) |j| try j.toJsonText() else null;
        }
    } else {
        const res = try plzig.spi.execute(q, &.{});
        while (n < res.rows) : (n += 1) {
            const r = try res.row(n);
            ids[n] = try r.get(i32, 0);
            texts[n] = if (try r.get(?plzig.Jsonb, 1)) |j| try j.toJsonText() else null;
        }
    }
    var same: usize = 0;
    for (ids[0..n], texts[0..n]) |id, t| {
        const r = try check.execute(.{ id, t });
        if (try (try r.row(0)).get(bool, 0)) same += 1;
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d} rows, {d} identical", .{ n, same });
$$;
SELECT jb_spi(false), jb_spi(true);
CREATE FUNCTION jb_param_err() RETURNS text LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT $1", &.{.jsonb});
    _ = try p.execute(.{plzig.jsonText("[1, 2")});
    return "accepted";
$$;
SELECT jb_err('SELECT jb_param_err()');
-- the column kinds: jsonb is native, json is text
CREATE FUNCTION jb_kinds() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT '{}'::jsonb, '{}'::json, '[1]'::jsonb -> 0", &.{});
    const row = try r.row(0);
    return try std.fmt.allocPrint(plzig.allocator, "{s} {s} {s} {any}", .{
        @tagName(try row.kind(0)), @tagName(try row.kind(1)), @tagName(try row.kind(2)), row.get([]const u8, 0) });
$$;
SELECT jb_kinds();
-- field extraction over many rows, as ->> does
CREATE TABLE jb_rows AS SELECT g AS id, jsonb_build_object('id', g, 'name', 'name ' || g, 'price', g * 1.25, 'tags', jsonb_build_array('a', g % 7)) AS doc
FROM generate_series(1, 5000) g;
CREATE FUNCTION jb_extract() RETURNS text LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT doc FROM jb_rows ORDER BY id", &.{});
    var names: usize = 0;
    var price = plzig.Numeric.zero;
    while (try c.next()) |r| {
        const o = (try (try r.get(plzig.Jsonb, 0)).root()).object;
        names += (try o.get("name")).?.string.len;
        price = try price.add(try (try o.get("price")).?.number.numeric());
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d} {f}", .{ names, price });
$$;
SELECT jb_extract() = (SELECT sum(length(doc ->> 'name')) || ' ' || sum((doc ->> 'price')::numeric) FROM jb_rows) AS extract_same;

-- a domain over jsonb is passed as text, like every domain
CREATE DOMAIN jb_obj AS jsonb CHECK (jsonb_typeof(VALUE) = 'object');
CREATE FUNCTION jb_dom(x jb_obj) RETURNS jb_obj STRICT LANGUAGE plzig AS $$ return x; $$;
SELECT jb_dom('{"b": 1,  "a": 2}'), jb_err('SELECT jb_dom(''[1]'')');

DROP TABLE jb_docs, jb_rows;
