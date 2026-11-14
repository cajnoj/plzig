--
-- spi_prepared: prepared statements, typed (binary) parameters and results
--
\set VERBOSITY terse

CREATE TABLE pt (id int PRIMARY KEY, name text, price float8, small int2, big int8,
                 flag bool, f4 real, data bytea, vc varchar(10), bp char(4),
                 num numeric, d date);
INSERT INTO pt VALUES
  (1, 'one', 1.5, 7, 9000000000, true, 2.5, '\x0001ff', 'vc', 'ab', 12.34, '2026-01-02'),
  (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- typed results: every kind, with and without NULLs; kinds come from the
-- tuple descriptor
CREATE FUNCTION pt_row(i int) RETURNS text STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare(
        "SELECT id, name, price, small, big, flag, f4, data, vc, bp, num, d FROM pt WHERE id = $1",
        &.{.int4});
    defer p.free();
    const r = try p.execute(.{i});
    if (r.rows != 1) return error.NotFound;
    const row = try r.row(0);
    const a = plzig.allocator;
    var out: std.ArrayList(u8) = .empty;
    var c: usize = 0;
    while (c < row.len()) : (c += 1) try out.print(a, "{s} ", .{@tagName(try row.kind(c))});
    try out.print(a, "| {d} {?s} {?d} {?d} {?d} {any} {?d} ", .{
        try row.get(i32, 0),     try row.get(?[]const u8, 1), try row.get(?f64, 2),
        try row.get(?i16, 3),    try row.get(?i64, 4),        try row.get(?bool, 5),
        try row.get(?f32, 6),
    });
    if (try row.get(?[]const u8, 7)) |b| {
        for (b) |x| try out.print(a, "{x:0>2}", .{x});
    } else try out.appendSlice(a, "null");
    try out.print(a, " [{?s}] [{?s}] {?s} {?s}", .{
        try row.get(?[]const u8, 8), try row.get(?[]const u8, 9),
        try row.get(?[]const u8, 10), try row.get(?[]const u8, 11),
    });
    return out.items;
$$;
SELECT pt_row(1);
SELECT pt_row(2);

-- typed parameters of every kind, passed in binary and returned typed
CREATE FUNCTION pt_params() RETURNS text LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare(
        "SELECT $1, $2, $3, $4, $5, $6, $7, $8, " ++
        "pg_typeof($1)::text || ',' || pg_typeof($2) || ',' || pg_typeof($3) || ',' || pg_typeof($4) || ',' || " ++
        "pg_typeof($5) || ',' || pg_typeof($6) || ',' || pg_typeof($7) || ',' || pg_typeof($8)",
        &.{ .boolean, .int2, .int4, .int8, .float4, .float8, .text, .bytea });
    const a = plzig.allocator;
    var out: std.ArrayList(u8) = .empty;
    const r = try p.execute(.{ true, @as(i16, -32768), @as(i32, 2147483647), @as(i64, -9223372036854775808),
                               @as(f32, -1.25), @as(f64, 0.1), "h\xc3\xa9", plzig.bytea("\x00\x01") });
    var row = try r.row(0);
    try out.print(a, "{any} {d} {d} {d} {d} {d} {s} {d} {s}", .{
        try row.get(bool, 0), try row.get(i16, 1), try row.get(i32, 2), try row.get(i64, 3),
        try row.get(f32, 4),  try row.get(f64, 5), try row.get([]const u8, 6),
        (try row.get([]const u8, 7)).len, try row.get([]const u8, 8) });
    // NULLs: the literal null, and typed optionals
    const r2 = try p.execute(.{ null, @as(?i16, null), @as(?i32, null), null, null, @as(?f64, null),
                                @as(?[]const u8, null), @as(?plzig.Bytea, null) });
    row = try r2.row(0);
    var c: usize = 0;
    while (c < 8) : (c += 1) try out.print(a, " {any}", .{try row.isNull(c)});
    // float specials
    const r3 = try p.execute(.{ false, @as(i16, 0), @as(i32, 0), @as(i64, 0), std.math.nan(f32),
                                -std.math.inf(f64), "", plzig.bytea("") });
    row = try r3.row(0);
    try out.print(a, " | {d} {d} [{s}] {d}", .{ try row.get(f32, 4), try row.get(f64, 5),
                                               try row.get([]const u8, 6), (try row.get([]const u8, 7)).len });
    return out.items;
$$;
SELECT pt_params();

-- typed rows from an ad-hoc execute; zero-column rows; domains are "other"
CREATE DOMAIN posint AS int CHECK (VALUE > 0);
CREATE FUNCTION pt_adhoc() RETURNS text LANGUAGE plzig AS $$
    const a = plzig.allocator;
    var out: std.ArrayList(u8) = .empty;
    const r = try plzig.spi.execute("SELECT 5::int2, 6::posint, NULL::int8, 'x'::name", &.{});
    const row = try r.row(0);
    try out.print(a, "{d} {s} {s} {?d} {s}/{s} {s}", .{ try row.get(i16, 0), @tagName(try row.kind(1)),
        try row.get([]const u8, 1), try row.get(?i64, 2), @tagName(try row.kind(3)),
        try row.get([]const u8, 3), @tagName(try row.kind(2)) });
    const z = try plzig.spi.execute("SELECT FROM pt", &.{});
    try out.print(a, "; {d} rows of {d} columns", .{ z.rows, (try z.row(1)).len() });
    return out.items;
$$;
SELECT pt_adhoc();

-- getters never convert: kind mismatch, NULL into non-optional, bad column
CREATE FUNCTION pt_get(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT 1::int4, NULL::int4, 'x'::text, 2::int8", &.{});
    const row = try r.row(0);
    switch (what) {
        1 => _ = try row.get(i64, 0),
        2 => _ = try row.get(i16, 0),
        3 => _ = try row.get(i32, 1),
        4 => _ = try row.get(i32, 2),
        5 => _ = try row.get([]const u8, 0),
        6 => _ = try row.get(?i32, 3),
        7 => _ = try row.get(i32, 4),
        8 => _ = try row.get(f64, 0),
        9 => _ = try r.row(1),
        else => return "ok",
    }
    return "unreachable";
$$;
SELECT pt_get(1);
SELECT pt_get(2);
SELECT pt_get(3);
SELECT pt_get(4);
SELECT pt_get(5);
SELECT pt_get(6);
SELECT pt_get(7);
SELECT pt_get(8);
SELECT pt_get(9);
SELECT pt_get(0);

-- parameter count and type are checked by the host against the statement
CREATE FUNCTION pt_param_err(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    const p = try plzig.spi.prepare("SELECT $1::text || $2", &.{ .int4, .text });
    switch (what) {
        1 => _ = try p.execute(.{@as(i32, 1)}),
        2 => _ = try p.execute(.{ @as(i32, 1), "a", "b" }),
        3 => _ = try p.execute(.{ @as(i64, 1), "a" }),
        4 => _ = try p.execute(.{ @as(i32, 1), plzig.bytea("a") }),
        5 => _ = try p.execute(.{ @as(?i16, null), "a" }),
        6 => _ = try plzig.spi.prepare("SELECT $1", &.{@as(plzig.spi.Type, @enumFromInt(42))}),
        7 => _ = try plzig.spi.prepare("SELECT $1", &.{@as(plzig.spi.Type, @enumFromInt(0))}),
        8 => _ = try plzig.spi.prepare("SELECT $3::int", &.{.int4}),
        9 => _ = try plzig.spi.prepare("SELECT $1 + 1", &.{.text}),
        else => {
            const r = try p.execute(.{ @as(i32, 1), null });
            return (try (try r.row(0)).get(?[]const u8, 0)) orelse "null";
        },
    }
    return "unreachable";
$$;
SELECT pt_param_err(1);
SELECT pt_param_err(2);
SELECT pt_param_err(3);
SELECT pt_param_err(4);
SELECT pt_param_err(5);
SELECT pt_param_err(6);
SELECT pt_param_err(7);
SELECT pt_param_err(8);
SELECT pt_param_err(9);
SELECT pt_param_err(0);

-- untyped numeric literals are a compile error with a hint
DO $do$
DECLARE d text;
BEGIN
  EXECUTE $f$CREATE FUNCTION pt_literal() RETURNS int LANGUAGE plzig AS $b$
    const p = try plzig.spi.prepare("SELECT $1", &.{.int4});
    _ = try p.execute(.{5});
    return 1;
$b$$f$;
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  RAISE NOTICE 'compile error, hint shown: %', d LIKE '%give numeric parameter literals a type%';
END $do$;

-- a prepared statement lives as long as its instance: kept in a global, it
-- is prepared once per session and reused
CREATE FUNCTION pt_cached(i int) RETURNS text STRICT LANGUAGE plzig AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
        var prepares: i32 = 0;
    };
    if (S.plan == null) {
        S.plan = try plzig.spi.prepare("SELECT name FROM pt WHERE id = $1", &.{.int4});
        S.prepares += 1;
    }
    const r = try S.plan.?.execute(.{i});
    const name = if (r.rows > 0) try (try r.row(0)).get(?[]const u8, 0) else null;
    return try std.fmt.allocPrint(plzig.allocator, "{?s} (prepared {d}x)", .{ name, S.prepares });
$$;
SELECT count(*) AS spi_plans FROM pg_backend_memory_contexts WHERE name = 'SPI Plan' \gset base_
SELECT pt_cached(1), pt_cached(2), pt_cached(3);
SELECT pt_cached(1);
SELECT count(*) - :base_spi_plans AS new_plans FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';

-- prepared DML (VOLATILE) with typed parameters
CREATE FUNCTION pt_insert(id int, name text) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("INSERT INTO pt(id, name, flag) VALUES ($1, $2, $3)", &.{ .int4, .text, .boolean });
    defer p.free();
    const r = try p.execute(.{ id, name, true });
    return @intCast(r.rows);
$$;
SELECT pt_insert(10, 'ten');
SELECT id, name, flag FROM pt WHERE id = 10;

-- read-only is decided per execution from the function's volatility
CREATE FUNCTION pt_ro() RETURNS bigint STABLE LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("INSERT INTO pt(id) VALUES ($1)", &.{.int4});
    defer p.free();
    return @intCast((try p.execute(.{@as(i32, 99)})).rows);
$$;
SELECT pt_ro();
CREATE FUNCTION pt_vol_cached(i int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("INSERT INTO pt(id) VALUES ($1)", &.{.int4});
    return @intCast((try S.plan.?.execute(.{i})).rows);
$$;
SELECT pt_vol_cached(20);
ALTER FUNCTION pt_vol_cached(int) STABLE;
SELECT pt_vol_cached(21);
SELECT count(*) FROM pt WHERE id IN (20, 21, 99);

-- handles: forged, stale, out of range, from another function or instance
CREATE FUNCTION pt_handle(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    var p = try plzig.spi.prepare("SELECT 1", &.{});
    const h = p.handle;
    var forged: plzig.spi.Plan = .{ .handle = 0 };
    switch (what) {
        1 => forged.handle = 0,
        2 => forged.handle = 12345,
        3 => forged.handle = h + (1 << 16),                  // right index, wrong serial
        4 => forged.handle = (h & ~@as(u64, 0xffff)) | 999,  // right serial, bad index
        5 => forged.handle = h | 0xffff,
        6 => {                                               // freed
            p.free();
            forged.handle = h;
        },
        7 => {                                               // freed twice
            forged.handle = h;
            p.free();
            forged.free();
        },
        else => forged.handle = h,
    }
    _ = try forged.execute(.{});
    return "valid";
$$;
SELECT pt_handle(1);
SELECT pt_handle(2);
SELECT pt_handle(3);
SELECT pt_handle(4);
SELECT pt_handle(5);
SELECT pt_handle(6);
SELECT pt_handle(7);
SELECT pt_handle(0);

-- a handle is only valid in the instance that created it
CREATE TABLE pt_handles (fn text PRIMARY KEY, h bigint);
CREATE FUNCTION pt_make_handle() RETURNS bigint LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT 'secret plan'", &.{});
    var buf: [32]u8 = undefined;
    _ = try plzig.spi.execute("INSERT INTO pt_handles VALUES ('maker', $1::bigint) ON CONFLICT (fn) DO UPDATE SET h = excluded.h",
                              &.{try std.fmt.bufPrint(&buf, "{d}", .{S.plan.?.handle})});
    _ = try S.plan.?.execute(.{});
    return @intCast(S.plan.?.handle & 0xffff);
$$;
CREATE FUNCTION pt_use_handle(h bigint) RETURNS text STRICT LANGUAGE plzig AS $$
    const p: plzig.spi.Plan = .{ .handle = @bitCast(h) };
    const r = try p.execute(.{});
    return try r.get(0, 0);
$$;
SELECT pt_make_handle();
SELECT pt_use_handle((SELECT h FROM pt_handles WHERE fn = 'maker'));
-- the maker itself still owns it (same instance)
SELECT pt_make_handle();
-- recursion runs in a temporary second instance: the outer handle is invalid there
CREATE FUNCTION pt_recurse(depth int, h bigint) RETURNS text STRICT LANGUAGE plzig AS $$
    if (depth == 0) {
        const p: plzig.spi.Plan = .{ .handle = @bitCast(h) };
        _ = try p.execute(.{});
        return "inner used the outer handle";
    }
    var p = try plzig.spi.prepare("SELECT pt_recurse($1, $2)", &.{ .int4, .int8 });
    const r = try p.execute(.{ depth - 1, @as(i64, @bitCast(p.handle)) });
    return try r.get(0, 0);
$$;
SELECT pt_recurse(1, 0);

-- the plan cap (plzig.max_prepared_plans) is an error, not an eviction;
-- after it, the instance and all its plans are gone
SET plzig.max_prepared_plans = 3;
CREATE FUNCTION pt_cap(n int) RETURNS int STRICT LANGUAGE plzig AS $$
    const S = struct { var plans: [10]plzig.spi.Plan = undefined; var count: usize = 0; };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        S.plans[S.count] = try plzig.spi.prepare("SELECT 1", &.{});
        S.count += 1;
        var buf: [32]u8 = undefined;
        _ = try plzig.spi.execute("INSERT INTO pt_handles VALUES ('cap', $1::bigint) ON CONFLICT (fn) DO UPDATE SET h = excluded.h",
                                  &.{try std.fmt.bufPrint(&buf, "{d}", .{S.plans[S.count - 1].handle})});
    }
    return @intCast(S.count);
$$;
SELECT pt_cap(2);
SELECT count(*) - :base_spi_plans AS new_plans FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';
SELECT pt_cap(2);
SELECT count(*) - :base_spi_plans AS new_plans FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';
-- freeing makes room again
CREATE FUNCTION pt_cap_free() RETURNS int LANGUAGE plzig AS $$
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        var p = try plzig.spi.prepare("SELECT 1", &.{});
        p.free();
    }
    return i;
$$;
SELECT pt_cap_free();
-- the handle stored before the cap error is stale: in another function ...
SELECT pt_use_handle(h) FROM pt_handles WHERE fn = 'cap';
-- ... and in the new instance of the same function
CREATE FUNCTION pt_cap_use(n int, h bigint) RETURNS text STRICT LANGUAGE plzig AS $$
    if (n == 0) {
        const p: plzig.spi.Plan = .{ .handle = @bitCast(h) };
        _ = try p.execute(.{});
        return "valid";
    }
    var buf: [32]u8 = undefined;
    const S = struct { var plans: [10]plzig.spi.Plan = undefined; var count: usize = 0; };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        S.plans[S.count] = try plzig.spi.prepare("SELECT 1", &.{});
        _ = try plzig.spi.execute("INSERT INTO pt_handles VALUES ('cap2', $1::bigint) ON CONFLICT (fn) DO UPDATE SET h = excluded.h",
                                  &.{try std.fmt.bufPrint(&buf, "{d}", .{S.plans[S.count].handle})});
        S.count += 1;
    }
    return "prepared";
$$;
SET plzig.max_prepared_plans = 3;
SELECT pt_cap_use(2, 0);
SELECT pt_cap_use(0, h) FROM pt_handles WHERE fn = 'cap2';
SELECT pt_cap_use(2, 0);
SELECT pt_cap_use(0, h) FROM pt_handles WHERE fn = 'cap2';
RESET plzig.max_prepared_plans;

-- plans are freed whenever their instance is destroyed
CREATE FUNCTION pt_hold(n int, fail bool) RETURNS int STRICT LANGUAGE plzig AS $$
    const S = struct { var plans: [8]plzig.spi.Plan = undefined; var count: usize = 0; };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        S.plans[S.count] = try plzig.spi.prepare("SELECT 1", &.{});
        S.count += 1;
    }
    if (fail) plzig.raise("failing with {d} plans", .{S.count});
    return @intCast(S.count);
$$;
CREATE FUNCTION pt_plans() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) - current_setting('pt.base')::bigint FROM pg_backend_memory_contexts WHERE name = 'SPI Plan'
$$;
SELECT set_config('pt.base', count(*)::text, false) IS NOT NULL AS ok
  FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';
SELECT pt_plans() AS before;
-- error
SELECT pt_hold(2, false), pt_plans();
SELECT pt_hold(1, true);
SELECT pt_plans() AS after_error;
-- function replaced (freed at the next PL/Zig call in the session)
SELECT pt_hold(3, false), pt_plans();
CREATE OR REPLACE FUNCTION pt_hold(n int, fail bool) RETURNS int STRICT LANGUAGE plzig AS $$
    const S = struct { var plans: [8]plzig.spi.Plan = undefined; var count: usize = 0; };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        S.plans[S.count] = try plzig.spi.prepare("SELECT 1", &.{});
        S.count += 1;
    }
    if (fail) plzig.raise("failing with {d} plans", .{S.count});
    return @as(i32, @intCast(S.count)) + 100;
$$;
SELECT pt_cached(1);
SELECT pt_plans() AS after_replace;
-- dropped (pt_cached holds one plan)
SELECT pt_hold(2, false), pt_plans();
DROP FUNCTION pt_cached(int);
SELECT pt_hold(0, false), pt_plans();
-- from here on, count only pt_hold's plans (it holds 2 now)
SELECT set_config('pt.base', (count(*) - 2)::text, false) IS NOT NULL AS rebased
  FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';
-- LRU eviction (no idle instances kept): lowering plzig.instance_cache_size
-- destroys the idle instances, with their plans, at the next PL/Zig call
SET plzig.instance_cache_size = 0;
SELECT pt_hold(0, false) AS from_a_fresh_instance;
SELECT pt_plans() <= -2 AS its_two_plans_freed;
-- (that also freed the plans of other functions' idle instances: rebase)
SELECT set_config('pt.base', count(*)::text, false) IS NOT NULL AS rebased
  FROM pg_backend_memory_contexts WHERE name = 'SPI Plan';
SELECT pt_hold(2, false);
SELECT pt_plans() AS after_lru;
RESET plzig.instance_cache_size;
-- instance grew beyond plzig.instance_cache_max_memory
SET plzig.instance_cache_max_memory = 0;
SELECT pt_hold(2, false);
SELECT pt_plans() AS after_max_memory;
RESET plzig.instance_cache_max_memory;
-- plzig.max_memory changed: the old instance is retired at the next call
SELECT pt_hold(2, false) - 100 AS plans, pt_plans();
SET plzig.max_memory = '32MB';
SELECT pt_hold(0, false) - 100 AS plans, pt_plans();
RESET plzig.max_memory;
SELECT pt_hold(0, false) - 100 AS plans, pt_plans();
-- DO blocks
DO $$ _ = try plzig.spi.prepare("SELECT 1", &.{}); _ = try plzig.spi.prepare("SELECT 2", &.{}); $$ LANGUAGE plzig;
SELECT pt_plans() AS after_do;

-- permissions are checked at every execution, as the current user
CREATE TABLE pt_secret (s text);
INSERT INTO pt_secret VALUES ('prepared secret');
REVOKE ALL ON pt_secret FROM PUBLIC;
CREATE FUNCTION pt_read_secret() RETURNS text LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT s FROM pt_secret", &.{});
    const r = try S.plan.?.execute(.{});
    return try (try r.row(0)).get(?[]const u8, 0);
$$;
CREATE FUNCTION pt_read_secret_definer() RETURNS text SECURITY DEFINER SET search_path = public
  LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT s FROM pt_secret", &.{});
    const r = try S.plan.?.execute(.{});
    return try (try r.row(0)).get(?[]const u8, 0);
$$;
GRANT EXECUTE ON FUNCTION pt_read_secret(), pt_read_secret_definer() TO regress_plzig_nobody;
-- prepared (and cached) by the superuser ...
SELECT pt_read_secret(), pt_read_secret_definer();
-- ... still checked for the unprivileged caller
SET ROLE regress_plzig_nobody;
SELECT pt_read_secret();
SELECT pt_read_secret_definer();
RESET ROLE;
SELECT pt_read_secret();

-- plan invalidation after DDL: replanned, or a clean error
CREATE TABLE pt_inv (a int, b int);
INSERT INTO pt_inv VALUES (1, 2);
CREATE FUNCTION pt_inv_star() RETURNS text LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT * FROM pt_inv", &.{});
    const r = try S.plan.?.execute(.{});
    const row = try r.row(0);
    var out: std.ArrayList(u8) = .empty;
    var c: usize = 0;
    while (c < row.len()) : (c += 1) try out.print(plzig.allocator, "{s} ", .{@tagName(try row.kind(c))});
    return out.items;
$$;
CREATE FUNCTION pt_inv_b() RETURNS int LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT b FROM pt_inv", &.{});
    const r = try S.plan.?.execute(.{});
    return try (try r.row(0)).get(i32, 0);
$$;
SELECT pt_inv_star(), pt_inv_b();
ALTER TABLE pt_inv ADD COLUMN c text;
SELECT pt_inv_star(), pt_inv_b();
ALTER TABLE pt_inv ALTER COLUMN b TYPE bigint;
SELECT pt_inv_star();
SELECT pt_inv_b();
ALTER TABLE pt_inv DROP COLUMN b;
SELECT pt_inv_star();
SELECT pt_inv_b();
DROP TABLE pt_inv;
SELECT pt_inv_star();
CREATE TABLE pt_inv (b int);
INSERT INTO pt_inv VALUES (42);
SELECT pt_inv_b();

-- cursor commands are not allowed in SQL run by PL/Zig (cursors must not
-- outlive the call or reach portals the function did not open)
CREATE FUNCTION pt_cursor_sql(what int) RETURNS text STRICT LANGUAGE plzig AS $$
    switch (what) {
        1 => _ = try plzig.spi.execute("DECLARE c CURSOR WITH HOLD FOR SELECT 1", &.{}),
        2 => _ = try plzig.spi.execute("SELECT 1; FETCH ALL FROM c", &.{}),
        3 => _ = try plzig.spi.execute("MOVE c", &.{}),
        4 => _ = try plzig.spi.execute("CLOSE ALL", &.{}),
        5 => _ = try plzig.spi.prepare("CLOSE c", &.{}),
        6 => _ = try plzig.spi.open("FETCH ALL FROM c", &.{}),
        7 => _ = try plzig.spi.execute("SELEC 1", &.{}),
        else => {},
    }
    return "ok";
$$;
SELECT pt_cursor_sql(1);
SELECT pt_cursor_sql(2);
SELECT pt_cursor_sql(3);
SELECT pt_cursor_sql(4);
SELECT pt_cursor_sql(5);
SELECT pt_cursor_sql(6);
SELECT pt_cursor_sql(7);
SELECT pt_cursor_sql(0);
SELECT count(*) FROM pg_cursors;

-- large values in both directions
CREATE FUNCTION pt_large() RETURNS text LANGUAGE plzig AS $$
    const big = try plzig.allocator.alloc(u8, 3 * 1024 * 1024);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);
    var p = try plzig.spi.prepare("SELECT length($1), md5($1), repeat('x', 2000000)", &.{.bytea});
    defer p.free();
    const r = try p.execute(.{plzig.bytea(big)});
    const row = try r.row(0);
    return try std.fmt.allocPrint(plzig.allocator, "{d} {s} {d}", .{ try row.get(i32, 0),
        try row.get([]const u8, 1), (try row.get([]const u8, 2)).len });
$$;
SELECT pt_large();
SELECT md5(decode(string_agg(lpad(to_hex(i % 251), 2, '0'), '' ORDER BY i), 'hex'))
  FROM generate_series(0, 3 * 1024 * 1024 - 1) i;
