--
-- adversarial: comptime reflection, PostgreSQL privileges through every SPI
-- path (row-level security, column privileges, SECURITY DEFINER/INVOKER,
-- role changes), read-only enforcement, and what error messages show to an
-- unprivileged user (doc/security.md)
--
\set VERBOSITY terse
SELECT current_user AS adv_superuser \gset

--
-- 1. Comptime reflection.  plzig.std is a curated convenience, not the
-- security boundary: reflection reaches far into std (here: std.Io, through
-- a parameter type of a curated function), but nothing that needs an
-- operating system compiles for wasm32-freestanding, and the loader would
-- refuse any import outside "plzig" (docker/security-checks.sh).
--
-- what plzig.std and plzig expose (public declarations only: the host
-- import table and the wasm environment are private)
CREATE FUNCTION adv_std_decls() RETURNS text LANGUAGE plzig AS $$
    const names = comptime blk: {
        var s: []const u8 = "";
        for (@typeInfo(std).@"struct".decl_names) |n| s = s ++ " " ++ n;
        break :blk s;
    };
    return names;
$$;
SELECT adv_std_decls();
CREATE FUNCTION adv_sdk_decls() RETURNS text LANGUAGE plzig AS $$
    const names = comptime blk: {
        var s: []const u8 = "";
        for (@typeInfo(plzig).@"struct".decl_names) |n| s = s ++ " " ++ n;
        break :blk s;
    };
    return names;
$$;
SELECT adv_sdk_decls();
-- private SDK declarations cannot be named
CREATE FUNCTION adv_host() RETURNS int LANGUAGE plzig AS $$
    _ = @field(plzig, "host");
    return 1;
$$;
CREATE FUNCTION adv_env() RETURNS int LANGUAGE plzig AS $$
    _ = plzig.wasm_env;
    return 1;
$$;
CREATE FUNCTION adv_hasdecl() RETURNS text LANGUAGE plzig AS $$
    return if (@hasDecl(plzig, "host") or @hasDecl(plzig, "env") or @hasDecl(std, "fs") or
        @hasDecl(std, "posix") or @hasDecl(std, "os") or @hasDecl(std, "heap") or @hasDecl(std, "c"))
        "visible" else "hidden";
$$;
SELECT adv_hasdecl();
-- reflection reaches std.Io ...
CREATE FUNCTION adv_reach_io() RETURNS text LANGUAGE plzig AS $$
    const Wp = @typeInfo(@TypeOf(std.math.big.int.Const.format)).@"fn".param_types[1].?;
    const Writer = @typeInfo(Wp).pointer.child;
    const SendFile = @typeInfo(@FieldType(Writer.VTable, "sendFile")).pointer.child;
    const FileReader = @typeInfo(@typeInfo(SendFile).@"fn".param_types[1].?).pointer.child;
    const Io = @FieldType(FileReader, "io");
    return if (@hasDecl(Io, "Threaded") and @hasDecl(Io, "Dir") and @hasDecl(Io, "net")) "reached std.Io" else "no";
$$;
SELECT adv_reach_io();
-- ... but using it to open a file, or a socket, does not compile
CREATE FUNCTION adv_io_file() RETURNS int LANGUAGE plzig AS $$
    const Wp = @typeInfo(@TypeOf(std.math.big.int.Const.format)).@"fn".param_types[1].?;
    const Writer = @typeInfo(Wp).pointer.child;
    const SendFile = @typeInfo(@FieldType(Writer.VTable, "sendFile")).pointer.child;
    const FileReader = @typeInfo(@typeInfo(SendFile).@"fn".param_types[1].?).pointer.child;
    const Io = @FieldType(FileReader, "io");
    var t: Io.Threaded = .init_single_threaded;
    const f = try Io.Dir.cwd().openFile(t.io(), "/etc/passwd", .{});
    _ = f;
    return 1;
$$;
CREATE FUNCTION adv_io_net() RETURNS int LANGUAGE plzig AS $$
    const Wp = @typeInfo(@TypeOf(std.math.big.int.Const.format)).@"fn".param_types[1].?;
    const Writer = @typeInfo(Wp).pointer.child;
    const SendFile = @typeInfo(@FieldType(Writer.VTable, "sendFile")).pointer.child;
    const FileReader = @typeInfo(@typeInfo(SendFile).@"fn".param_types[1].?).pointer.child;
    const Io = @FieldType(FileReader, "io");
    const io = Io.Threaded.global_single_threaded.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(5432) };
    const s = try addr.connect(io, .{ .mode = .stream });
    _ = s;
    return 1;
$$;
-- nor do the import tricks
CREATE FUNCTION adv_import_space() RETURNS int LANGUAGE plzig AS $$
    const s = @import ("std");
    _ = s;
    return 1;
$$;
CREATE FUNCTION adv_import_concat() RETURNS int LANGUAGE plzig AS $$
    const s = @import("pl" ++ "zig");
    _ = s;
    return 1;
$$;
CREATE FUNCTION adv_import_paren() RETURNS int LANGUAGE plzig AS $$
    const s = @import(("plzig"));
    _ = s;
    return 1;
$$;
-- comptime bombs stop at the default evaluation quota (@setEvalBranchQuota
-- is denied); slower ones at plzig.compile_timeout (resources.sql)
CREATE FUNCTION adv_comptime_loop() RETURNS int LANGUAGE plzig AS $$
    comptime {
        var i: u64 = 0;
        while (i < 1 << 40) : (i += 1) {}
    }
    return 1;
$$;
-- user code cannot replace the SDK's entry points or panic handler
CREATE FUNCTION adv_override() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
pub fn plzig_call(a: u32, b: u32, c: u32) u32 { _ = .{ a, b, c }; return 0; }
pub const panic = struct {};
fn unused() void {
$$;
SELECT adv_override();
SELECT count(*) AS adv_functions_created FROM pg_proc WHERE proname LIKE 'adv\_%';

--
-- 2. Row-level security, through spi.execute, prepared statements and cursors
--
CREATE TABLE adv_docs (owner name, body text);
INSERT INTO adv_docs VALUES ('regress_plzig_dev', 'dev doc'), ('regress_plzig_nobody', 'nobody doc'),
                            ('someone_else', 'other doc');
ALTER TABLE adv_docs ENABLE ROW LEVEL SECURITY;
CREATE POLICY adv_own ON adv_docs USING (owner = current_user);
GRANT SELECT ON adv_docs TO regress_plzig_dev, regress_plzig_nobody;
-- SECURITY INVOKER (the default); the prepared statement is kept in a global
-- across calls, so it must be re-checked when the role changes
CREATE FUNCTION adv_docs_seen() RETURNS text SECURITY INVOKER LANGUAGE plzig AS $$
    const S = struct { var plan: ?plzig.spi.Plan = null; };
    var out: std.ArrayList(u8) = .empty;
    const r = try plzig.spi.execute("SELECT string_agg(body, ',' ORDER BY body) FROM adv_docs", &.{});
    try out.print(plzig.allocator, "execute: {s}", .{(try r.get(0, 0)) orelse "-"});
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT body FROM adv_docs ORDER BY body", &.{});
    const p = try S.plan.?.execute(.{});
    try out.print(plzig.allocator, "; prepared: {d} row(s)", .{p.rows});
    if (p.rows > 0) try out.print(plzig.allocator, " {s}", .{(try p.get(0, 0)).?});
    var cur = try plzig.spi.open("SELECT body FROM adv_docs ORDER BY body", &.{});
    defer cur.close();
    try out.appendSlice(plzig.allocator, "; cursor:");
    while (try cur.next()) |row| try out.print(plzig.allocator, " {s}", .{try row.get([]const u8, 0)});
    return out.items;
$$;
GRANT EXECUTE ON FUNCTION adv_docs_seen() TO regress_plzig_dev, regress_plzig_nobody;
SELECT adv_docs_seen();   -- superuser: RLS does not apply
SET ROLE regress_plzig_dev;
SELECT adv_docs_seen();
SET ROLE regress_plzig_nobody;
SELECT adv_docs_seen();   -- same backend, same instance and plan, other role
RESET ROLE;
-- SECURITY DEFINER (owned by regress_plzig_dev): the owner's rows
SET ROLE regress_plzig_dev;
CREATE FUNCTION adv_docs_definer() RETURNS text SECURITY DEFINER LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT current_user || ': ' || string_agg(body, ',') FROM adv_docs", &.{});
    return try r.get(0, 0);
$$;
GRANT EXECUTE ON FUNCTION adv_docs_definer() TO regress_plzig_nobody;
RESET ROLE;
SET ROLE regress_plzig_nobody;
SELECT adv_docs_definer();
SELECT current_user;
RESET ROLE;

--
-- 3. Column privileges
--
CREATE TABLE adv_emp (name text, salary int);
INSERT INTO adv_emp VALUES ('ann', 100);
GRANT SELECT (name) ON adv_emp TO regress_plzig_nobody;
CREATE FUNCTION adv_col(how int, col text) RETURNS text STRICT LANGUAGE plzig AS $$
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT {s}::text FROM adv_emp", .{col});
    switch (how) {
        0 => {
            const r = try plzig.spi.execute(sql, &.{});
            return try r.get(0, 0);
        },
        1 => {
            const p = try plzig.spi.prepare(sql, &.{});
            const r = try p.execute(.{});
            return try r.get(0, 0);
        },
        else => {
            var c = try plzig.spi.open(sql, &.{});
            defer c.close();
            const row = (try c.next()) orelse return null;
            return try plzig.allocator.dupe(u8, try row.get([]const u8, 0));
        },
    }
$$;
GRANT EXECUTE ON FUNCTION adv_col(int, text) TO regress_plzig_nobody;
SET ROLE regress_plzig_nobody;
SELECT adv_col(0, 'name'), adv_col(1, 'name'), adv_col(2, 'name');
SELECT adv_col(0, 'salary');
SELECT adv_col(1, 'salary');
SELECT adv_col(2, 'salary');
SELECT adv_col(0, 'adv_emp');
RESET ROLE;

--
-- 4. SECURITY DEFINER / INVOKER nesting, and no way to change identity
--
SET ROLE regress_plzig_dev;
CREATE FUNCTION adv_whoami() RETURNS text SECURITY INVOKER LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT current_user::text", &.{});
    return try r.get(0, 0);
$$;
CREATE FUNCTION adv_dev_definer() RETURNS text SECURITY DEFINER LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT adv_whoami()", &.{});
    return try r.get(0, 0);
$$;
CREATE FUNCTION adv_setrole(sql text) RETURNS text STRICT SECURITY DEFINER LANGUAGE plzig AS $$
    _ = try plzig.spi.execute(sql, &.{});
    const r = try plzig.spi.execute("SELECT current_user::text", &.{});
    return try r.get(0, 0);
$$;
GRANT EXECUTE ON FUNCTION adv_whoami(), adv_dev_definer(), adv_setrole(text) TO regress_plzig_nobody;
RESET ROLE;
SET ROLE regress_plzig_nobody;
SELECT adv_whoami();          -- invoker: the caller
SELECT adv_dev_definer();     -- an invoker function called from a definer one: the definer
SELECT adv_setrole('SET ROLE regress_plzig_nobody');
SELECT adv_setrole('SET SESSION AUTHORIZATION regress_plzig_dev');
SELECT adv_setrole('RESET ROLE');
SELECT current_user;
RESET ROLE;
CREATE FUNCTION adv_invoker_setrole(sql text) RETURNS text STRICT LANGUAGE plzig AS $$
    _ = try plzig.spi.execute(sql, &.{});
    const r = try plzig.spi.execute("SELECT current_user::text", &.{});
    return try r.get(0, 0);
$$;
GRANT EXECUTE ON FUNCTION adv_invoker_setrole(text) TO regress_plzig_dev;
-- in a session of an unprivileged login role (SET ROLE is checked against
-- the session user, who is the superuser above)
\c - regress_plzig_dev
SELECT adv_invoker_setrole('SET ROLE regress_plzig_nobody');
SELECT adv_invoker_setrole('SET SESSION AUTHORIZATION regress_plzig_nobody');
SELECT adv_invoker_setrole('SET ROLE NONE');
SELECT current_user, session_user;
\c - :adv_superuser

--
-- 5. Read-only enforcement beyond STABLE/IMMUTABLE (spi.sql, spi_prepared.sql,
-- spi_cursor.sql): read-only transactions, data-modifying CTEs, and what a
-- read-only function may still call
--
CREATE TABLE adv_t (n int);
CREATE FUNCTION adv_write(how int) RETURNS bigint STRICT LANGUAGE plzig AS $$
    switch (how) {
        0 => return @intCast((try plzig.spi.execute("INSERT INTO adv_t VALUES (1)", &.{})).rows),
        1 => {
            const p = try plzig.spi.prepare("INSERT INTO adv_t VALUES ($1)", &.{.int4});
            return @intCast((try p.execute(.{@as(i32, 2)})).rows);
        },
        else => {
            var c = try plzig.spi.open("WITH w AS (INSERT INTO adv_t VALUES (3) RETURNING n) SELECT n FROM w", &.{});
            defer c.close();
            _ = try c.next();
            return 1;
        },
    }
$$;
BEGIN READ ONLY;
SELECT adv_write(0);
ROLLBACK;
BEGIN READ ONLY;
SELECT adv_write(1);
ROLLBACK;
BEGIN READ ONLY;
SELECT adv_write(2);
ROLLBACK;
SET default_transaction_read_only = on;
SELECT adv_write(0);
RESET default_transaction_read_only;
CREATE FUNCTION adv_stable_cte() RETURNS bigint STABLE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("WITH w AS (INSERT INTO adv_t VALUES (4) RETURNING n) SELECT count(*) FROM w", &.{});
    return @intCast(r.rows);
$$;
SELECT adv_stable_cte();
-- as in PL/pgSQL: a read-only function may call a VOLATILE function, which
-- runs with its own (writable) SPI connection
CREATE FUNCTION adv_stable_calls_volatile() RETURNS bigint STABLE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT adv_write(0)", &.{});
    return @intCast(r.rows);
$$;
SELECT adv_stable_calls_volatile();
SELECT count(*) AS adv_rows FROM adv_t;

--
-- 6. What an unprivileged user sees in error messages: never the data
-- directory, the build directory or the Zig installation path (compiler
-- paths become "<zig lib>/"; doc/security.md)
--
CREATE TEMP TABLE adv_msgs (what text, msg text);
GRANT INSERT ON adv_msgs TO regress_plzig_dev;
SET ROLE regress_plzig_dev;
DO $do$
DECLARE
    m text; d text; h text;
    cases text[][] := ARRAY[
        ['compile error inside std', $b$ return @intCast(std.fmt.comptimePrint("{d}", .{"x"}).len); $b$],
        ['compile error naming the source file', $b$ @compileError(@src().file ++ " " ++ @src().module); $b$],
        ['policy rejection', $b$ return @embedFile("/etc/passwd").len; $b$],
        ['compile error inside the SDK', $b$ _ = try (try plzig.spi.prepare("SELECT $1", &.{.int4})).execute(.{5}); return 1; $b$],
        ['panic', $b$ @panic("boom"); $b$],
        ['trap', $b$ @trap(); $b$],
        ['out of bounds', $b$ const a = [_]i32{1}; var i: usize = 5; _ = &i; return a[i]; $b$]];
    i int;
BEGIN
    FOR i IN 1..array_length(cases, 1) LOOP
        BEGIN
            EXECUTE format('CREATE OR REPLACE FUNCTION adv_msg() RETURNS int LANGUAGE plzig AS %L', cases[i][2]);
            PERFORM adv_msg();
            INSERT INTO adv_msgs VALUES (cases[i][1], '(no error)');
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
            INSERT INTO adv_msgs VALUES (cases[i][1], concat_ws(' | ', m, d, h));
        END;
    END LOOP;
END
$do$;
RESET ROLE;
SELECT what,
       left(msg, strpos(msg || ' |', ' |') - 1) AS message,
       strpos(msg, current_setting('data_directory')) = 0 AS no_data_dir,
       strpos(msg, regexp_replace(current_setting('plzig.zig_path'), '/[^/]*$', '')) = 0 AS no_zig_dir,
       strpos(msg, 'pgsql_tmp') = 0 AS no_build_dir
  FROM adv_msgs ORDER BY what;
SELECT msg LIKE '%<zig lib>/std/%' AS std_location_shown_relative FROM adv_msgs WHERE what = 'compile error inside std';
DROP FUNCTION IF EXISTS adv_msg();
