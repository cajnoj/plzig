--
-- uses: one PL/Zig function compiled into another (//#use directives)
--
\set VERBOSITY terse
CREATE SCHEMA uz;
GRANT USAGE, CREATE ON SCHEMA uz TO regress_plzig_dev;
SET ROLE regress_plzig_dev;

-- helpers: a strict one, a non-strict one, one with a private helper of its own
CREATE FUNCTION uz.twice(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    return x * 2;
$$;
CREATE FUNCTION uz.greet(name text) RETURNS text LANGUAGE plzig AS $f$
    const n = name orelse return null;
    return try std.fmt.allocPrint(plzig.allocator, "hello {s}{s}", .{ n, helper() });
}
fn helper() []const u8 {
    return "!";
$f$;

-- happy path: the alias is the used function's call, with its own Zig signature
CREATE FUNCTION uz.user1(x int) RETURNS text STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
//#use uz.greet(text) as greet
    const t = (try twice.call(x)).?;
    const g = (try greet.call("zig")) orelse "null";
    const n = try greet.call(null);
    return try std.fmt.allocPrint(plzig.allocator, "{d} {s} {s} {s}", .{ t, g, if (n == null) "null" else "?", helper() });
}
// a private helper of the same name as the used function's: no clash
fn helper() []const u8 {
    return "own";
$f$;
SELECT uz.user1(21);

-- comments and blank lines may precede and separate directives; spacing is free
CREATE FUNCTION uz.user2(x int) RETURNS int STRICT LANGUAGE plzig AS $f$

// doubles twice
	//#use   "uz".twice( int4 )   as   tw

    return (try tw.call((try tw.call(x)).?)).?;
$f$;
SELECT uz.user2(5);

-- directives are comments: line numbers in compiler messages do not move
\set VERBOSITY default
CREATE FUNCTION uz.lines(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
    return no_such_name;
$f$;
\set VERBOSITY terse

-- transitive uses, and one function reached twice (compiled in once)
CREATE FUNCTION uz.quad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as t
    return (try t.call((try t.call(x)).?)).?;
$f$;
CREATE FUNCTION uz.oct(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.quad(integer) as q
//#use uz.twice(integer) as t2
    return (try t2.call((try q.call(x)).?)).?;
$f$;
SELECT uz.oct(3);

-- errors and panics of the used function behave as the caller's own
CREATE FUNCTION uz.fails(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    if (x == 0) return error.ZeroNotAllowed;
    if (x < 0) plzig.raise("negative: {d}", .{x});
    return x;
$f$;
CREATE FUNCTION uz.calls_fails(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.fails(integer) as f
    return try f.call(x);
$f$;
SELECT uz.calls_fails(1);
SELECT uz.calls_fails(0);
SELECT uz.calls_fails(-1);
CREATE FUNCTION uz.catches(x int) RETURNS text STRICT LANGUAGE plzig AS $f$
//#use uz.fails(integer) as f
    _ = f.call(x) catch |err| return @errorName(err);
    return "ok";
$f$;
SELECT uz.catches(0), uz.catches(5);

-- native types, SPI, and a used function's SPI runs as part of the caller
CREATE TABLE uz.log (msg text);
CREATE FUNCTION uz.add_n(a numeric, b numeric) RETURNS numeric STRICT LANGUAGE plzig AS $f$
    return try a.add(b);
$f$;
CREATE FUNCTION uz.field(j jsonb, k text) RETURNS text STRICT LANGUAGE plzig AS $f$
    const r = try j.root();
    if (r != .object) return error.NotAnObject;
    const v = (try r.object.get(k)) orelse return null;
    return (try v.toJsonText()).text;
$f$;
CREATE FUNCTION uz.note(m text) RETURNS void STRICT LANGUAGE plzig AS $f$
    _ = try plzig.spi.execute("INSERT INTO uz.log VALUES ($1 || ' as ' || current_user)", &.{m});
$f$;
CREATE FUNCTION uz.native(a numeric, j jsonb) RETURNS text STRICT LANGUAGE plzig AS $f$
//#use uz.add_n(numeric, numeric) as add
//#use uz.field(jsonb, text) as field
//#use uz.note(text) as note
    const s = (try add.call(a, a)).?;
    try note.call("native");
    return try std.fmt.allocPrint(plzig.allocator, "{s} {s}", .{ try s.toText(), (try field.call(j, "k")).? });
$f$;
SELECT uz.native(1.25, '{"k": [1, "x"]}');
SELECT * FROM uz.log;

-- any kind of function may use one: set-returning, trigger, procedure, rows
CREATE FUNCTION uz.srf(n int) RETURNS SETOF int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
    var i: i32 = 1;
    while (i <= n) : (i += 1) returnNext((try twice.call(i)).?);
$f$;
SELECT * FROM uz.srf(3);
CREATE TABLE uz.t (v int);
CREATE FUNCTION uz.trg() RETURNS trigger LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
    const r = (try tg.new(struct { v: ?i32 })) orelse return .skip;
    return try tg.modify(.{ .v = try twice.call(r.v orelse 0) });
$f$;
CREATE TRIGGER uz_t BEFORE INSERT ON uz.t FOR EACH ROW EXECUTE FUNCTION uz.trg();
INSERT INTO uz.t VALUES (4) RETURNING v;
CREATE PROCEDURE uz.proc(INOUT r int) LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
    return .{ .r = try twice.call(r orelse 1) };
$f$;
CALL uz.proc(8);
CREATE FUNCTION uz.pair(x int, OUT a int, OUT b text) STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice
//#use uz.greet(text) as greet
    return .{ .a = try twice.call(x), .b = try greet.call("row") };
$f$;
SELECT * FROM uz.pair(2);

-- pg_depend: a normal dependency on each directly used function
SELECT pg_describe_object(classid, objid, objsubid) AS dependent,
       pg_describe_object(refclassid, refobjid, refobjsubid) AS referenced, deptype
  FROM pg_depend
 WHERE classid = 'pg_proc'::regclass AND refclassid = 'pg_proc'::regclass
   AND objid IN (SELECT oid FROM pg_proc WHERE pronamespace = 'uz'::regnamespace)
 ORDER BY 1, 2;
-- so DROP needs CASCADE
DROP FUNCTION uz.quad(int);

-- ---------------------------------------------------------------------
-- refusals
-- ---------------------------------------------------------------------
\set VERBOSITY default
-- not schema-qualified (the search_path is never used)
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use twice(integer) as twice
    return x;
$f$;
-- no such function, no such type, no such schema
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(bigint) as twice
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(no_such_type) as twice
    return x;
$f$;
\set VERBOSITY terse
-- (PostgreSQL 14 and 15 report a missing schema, later versions a missing function)
DO $do$
BEGIN
  CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use nowhere.twice(integer) as twice
    return x;
$f$;
EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
  RAISE NOTICE 'refused: no such schema or function';
END $do$;
-- malformed directives
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer)
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice as twice
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as twice // a comment
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) AS twice
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#useuz.twice(integer) as twice
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#include uz.twice(integer) as twice
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use 12345 as twice
    return x;
$f$;
-- a directive after the first line of code is an error, not a comment
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    const y = x;
//#use uz.twice(integer) as twice
    return y;
$f$;
-- aliases
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as 2x
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as std
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as call
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as x
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as t
//#use uz.quad(integer) as t
    return x;
$f$;
CREATE FUNCTION uz.bad(n int) RETURNS SETOF int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as returnNext
    _ = n;
$f$;
CREATE FUNCTION uz.bad() RETURNS trigger LANGUAGE plzig AS $f$
//#use uz.twice(integer) as tg
    return .new;
$f$;
-- an alias that clashes with the function's own declarations: Zig says so
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as helper
    return x;
}
fn helper() i32 {
    return 1;
$f$;
-- the same function twice
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as t1
//#use uz.twice(int4) as t2
    return x;
$f$;
-- a function cannot use itself, nor be part of a cycle
CREATE FUNCTION uz.selfish(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    if (x <= 0) return 0;
    return 1 + (try call(x - 1)).?;  // direct recursion needs no directive
$f$;
SELECT uz.selfish(5);
CREATE OR REPLACE FUNCTION uz.selfish(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.selfish(integer) as me
    return x;
$f$;
CREATE FUNCTION uz.cyc_a(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    return x;
$f$;
CREATE FUNCTION uz.cyc_b(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.cyc_a(integer) as a
    return try a.call(x);
$f$;
CREATE OR REPLACE FUNCTION uz.cyc_a(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.cyc_b(integer) as b
    return try b.call(x);
$f$;
\set VERBOSITY default
CREATE OR REPLACE FUNCTION uz.cyc_a(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.cyc_b(integer) as b
    return try b.call(x);
$f$;
\set VERBOSITY terse
-- a cycle created behind the validator's back is found at the call
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION uz.cyc_a(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.cyc_b(integer) as b
    return try b.call(x);
$f$;
RESET check_function_bodies;
SELECT uz.cyc_a(1);
SELECT uz.cyc_b(1);

-- what may be used: PL/Zig functions only
CREATE FUNCTION uz.sqlfn(x int) RETURNS int LANGUAGE sql AS $$ SELECT x $$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.sqlfn(integer) as s
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use pg_catalog.int4abs(integer) as s
    return x;
$f$;
-- plain functions only
CREATE PROCEDURE uz.aproc(x int) LANGUAGE plzig AS $f$ $f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.aproc(integer) as p
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.srf(integer) as s
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.trg() as t
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.pair(integer) as p
    return x;
$f$;
CREATE FUNCTION uz.inout(INOUT x int) STRICT LANGUAGE plzig AS $f$ return x; $f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.inout(integer) as p
    return x;
$f$;
-- scalar types without domains
CREATE TYPE uz.comp AS (a int);
CREATE DOMAIN uz.posint AS int CHECK (VALUE > 0);
CREATE FUNCTION uz.takes_comp(c uz.comp) RETURNS int LANGUAGE plzig AS $f$ return (c orelse return null).a; $f$;
CREATE FUNCTION uz.gives_comp(x int) RETURNS uz.comp LANGUAGE plzig AS $f$ return .{ .a = x }; $f$;
CREATE FUNCTION uz.takes_dom(d uz.posint) RETURNS int LANGUAGE plzig AS $f$ return 1; $f$;
CREATE FUNCTION uz.gives_dom(x int) RETURNS uz.posint STRICT LANGUAGE plzig AS $f$
    return try std.fmt.allocPrint(plzig.allocator, "{d}", .{x});
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.takes_comp(uz.comp) as f
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.gives_comp(integer) as f
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.takes_dom(uz.posint) as f
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.gives_dom(integer) as f
    return x;
$f$;
-- text I/O types are fine (as text, without the input function's check)
CREATE FUNCTION uz.mask(a inet) RETURNS text STRICT LANGUAGE plzig AS $f$ return a; $f$;
CREATE FUNCTION uz.user_inet(x text) RETURNS text STRICT LANGUAGE plzig AS $f$
//#use uz.mask(inet) as mask
    return (try mask.call(x)).?;
$f$;
SELECT uz.user_inet('10.0.0.1/8');
-- no SECURITY DEFINER, no SET clauses
CREATE FUNCTION uz.definer(x int) RETURNS int STRICT SECURITY DEFINER LANGUAGE plzig AS $f$ return x; $f$;
CREATE FUNCTION uz.withset(x int) RETURNS int STRICT SET work_mem = '1MB' LANGUAGE plzig AS $f$ return x; $f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.definer(integer) as d
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.withset(integer) as d
    return x;
$f$;
-- temporary functions
CREATE FUNCTION pg_temp.tmpfn(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x; $f$;
DO $do$
BEGIN
  CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use pg_temp.tmpfn(integer) as d
    return x;
$f$;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '% %', SQLSTATE, regexp_replace(SQLERRM, 'pg_temp_[0-9]+', 'pg_temp_N');
END $do$;
-- same owner only, and the owner needs EXECUTE
RESET ROLE;
CREATE FUNCTION uz.other_owned(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x; $f$;
ALTER FUNCTION uz.other_owned(int) OWNER TO regress_plzig_nobody;
SET ROLE regress_plzig_dev;
\set VERBOSITY default
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.other_owned(integer) as d
    return x;
$f$;
CREATE FUNCTION uz.private(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x + 100; $f$;
REVOKE EXECUTE ON FUNCTION uz.private(int) FROM PUBLIC, regress_plzig_dev;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.private(integer) as d
    return x;
$f$;
\set VERBOSITY terse
-- (EXECUTE for the owner is enough: callers of the using function need none)
GRANT EXECUTE ON FUNCTION uz.private(int) TO regress_plzig_dev;
CREATE FUNCTION uz.uses_private(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.private(integer) as p
    return (try p.call(x)).?;
$f$;
RESET ROLE;
CREATE ROLE regress_plzig_caller;
GRANT USAGE ON SCHEMA uz TO regress_plzig_caller;
SET ROLE regress_plzig_caller;
SELECT has_function_privilege('uz.private(int)', 'EXECUTE') AS may_call_private;
SELECT uz.private(1);
SELECT uz.uses_private(1);
RESET ROLE;
SET ROLE regress_plzig_dev;
-- DO blocks cannot use functions
DO $f$
//#use uz.twice(integer) as twice
    _ = try twice.call(1);
$f$ LANGUAGE plzig;
-- the used function's code is validated like a standalone function's
SET check_function_bodies = off;
CREATE FUNCTION uz.sneaky(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    _ = @embedFile("/etc/passwd");
    return x;
$f$;
CREATE FUNCTION uz.broken(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    const y: bool = x;
    return y;
$f$;
CREATE FUNCTION uz.sneaky_import(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.twice(integer) as t
    return @import("plzig.use.t").call(x);
$f$;
CREATE FUNCTION uz.sneaky_import2(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    return @import("plzig.use.t").call(x);
$f$;
RESET check_function_bodies;
\set VERBOSITY default
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.sneaky(integer) as s
    return x;
$f$;
CREATE FUNCTION uz.bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.broken(integer) as b
    return (try b.call(x)).?;
$f$;
\set VERBOSITY terse
-- an import name of a function the file does use is just that function;
-- any other is refused by the validator
SELECT uz.sneaky_import(4);
SELECT uz.sneaky_import2(4);

-- depth and count limits (functions created without compiling them)
SET check_function_bodies = off;
CREATE FUNCTION uz.d0(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x; $f$;
DO $do$
BEGIN
  FOR i IN 1..9 LOOP
    EXECUTE format($q$CREATE FUNCTION uz.d%s(x int) RETURNS int STRICT LANGUAGE plzig AS $b$
//#use uz.d%s(integer) as prev
    return (try prev.call(x)).? + 1;
$b$$q$, i, i - 1);
  END LOOP;
  FOR i IN 1..33 LOOP
    EXECUTE format($q$CREATE FUNCTION uz.w%s(x int) RETURNS int STRICT LANGUAGE plzig AS $b$ return x + %s; $b$$q$, i, i);
  END LOOP;
END $do$;
RESET check_function_bodies;
SELECT uz.d8(0);
SELECT uz.d9(0);
CREATE FUNCTION uz.wide_src(n int) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(format('//#use uz.w%s(integer) as w%s', i, i), E'\n') || E'\n    var s = x;\n' ||
         string_agg(format('    s += (try w%s.call(0)).?;', i), E'\n') || E'\n    return s;'
    FROM generate_series(1, n) i
$$;
DO $$ BEGIN EXECUTE format('CREATE FUNCTION uz.wide32(x int) RETURNS int STRICT LANGUAGE plzig AS %L', uz.wide_src(32)); END $$;
DO $$ BEGIN EXECUTE format('CREATE FUNCTION uz.wide33(x int) RETURNS int STRICT LANGUAGE plzig AS %L', uz.wide_src(33)); END $$;
SELECT uz.wide32(0);

-- ---------------------------------------------------------------------
-- changes of a used function after the user exists
-- ---------------------------------------------------------------------
CREATE FUNCTION uz.base(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x + 1; $f$;
CREATE FUNCTION uz.top(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.base(integer) as base
    return (try base.call(x)).? * 10;
$f$;
SELECT uz.top(1);
-- a new body of the used function makes a new module for the user: a
-- session that has not loaded it yet must not find the old one in the cache
RESET ROLE;
SELECT plzig_cache_clear() >= 0 AS cleared;
\c
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
CREATE OR REPLACE FUNCTION uz.base(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x + 2; $f$;
\c
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
RESET ROLE;
-- top (with the old base), base (new), top (with the new base)
SELECT count(*) AS modules FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm';
\set VERBOSITY terse
SET ROLE regress_plzig_dev;
-- renamed: the directive no longer resolves
ALTER FUNCTION uz.base(int) RENAME TO base_renamed;
SELECT uz.top(1);
ALTER FUNCTION uz.base_renamed(int) RENAME TO base;
SELECT uz.top(1);
-- SECURITY DEFINER, SET
ALTER FUNCTION uz.base(int) SECURITY DEFINER;
SELECT uz.top(1);
ALTER FUNCTION uz.base(int) SECURITY INVOKER;
SELECT uz.top(1);
ALTER FUNCTION uz.base(int) SET work_mem = '2MB';
SELECT uz.top(1);
ALTER FUNCTION uz.base(int) RESET ALL;
SELECT uz.top(1);
-- EXECUTE revoked from the owner (and PUBLIC), then granted again
REVOKE EXECUTE ON FUNCTION uz.base(int) FROM PUBLIC, regress_plzig_dev;
SELECT uz.top(1);
GRANT EXECUTE ON FUNCTION uz.base(int) TO regress_plzig_dev;
SELECT uz.top(1);
-- EXECUTE through a role membership: revoking the membership is noticed
REVOKE EXECUTE ON FUNCTION uz.base(int) FROM regress_plzig_dev;
RESET ROLE;
CREATE ROLE regress_plzig_exec;
GRANT EXECUTE ON FUNCTION uz.base(int) TO regress_plzig_exec;
GRANT regress_plzig_exec TO regress_plzig_dev;
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
RESET ROLE;
REVOKE regress_plzig_exec FROM regress_plzig_dev;
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
GRANT EXECUTE ON FUNCTION uz.base(int) TO regress_plzig_dev;
-- another owner, and back
RESET ROLE;
ALTER FUNCTION uz.base(int) OWNER TO regress_plzig_nobody;
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
RESET ROLE;
ALTER FUNCTION uz.base(int) OWNER TO regress_plzig_dev;
SET ROLE regress_plzig_dev;
SELECT uz.top(1);
-- the user's own owner changes: names are resolved as the owner (who
-- needs USAGE on the schema), then the same owner check from the other side
RESET ROLE;
ALTER FUNCTION uz.top(int) OWNER TO regress_plzig_nobody;
SELECT uz.top(1);
GRANT USAGE ON SCHEMA uz TO regress_plzig_nobody;
SELECT uz.top(1);
REVOKE USAGE ON SCHEMA uz FROM regress_plzig_nobody;
ALTER FUNCTION uz.top(int) OWNER TO regress_plzig_dev;
SELECT uz.top(1);
SET ROLE regress_plzig_dev;
-- dropped: refused while the dependency exists
DROP FUNCTION uz.base(int);
-- replaced without the directive: the dependency goes
CREATE OR REPLACE FUNCTION uz.top(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x; $f$;
SELECT count(*) AS deps FROM pg_depend
 WHERE objid = 'uz.top(int)'::regprocedure AND refobjid = 'uz.base(int)'::regprocedure;
DROP FUNCTION uz.base(int);
-- with check_function_bodies = off nothing is refused and a missing function
-- records no dependency; the checks run at the first call
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION uz.top(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.base(integer) as base
    return (try base.call(x)).?;
$f$;
CREATE FUNCTION uz.lazy_bad(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.other_owned(integer) as other
//#use this is not a directive
    return x;
$f$;
RESET check_function_bodies;
SELECT count(*) AS deps FROM pg_depend
 WHERE objid IN ('uz.top(int)'::regprocedure, 'uz.lazy_bad(int)'::regprocedure)
   AND refclassid = 'pg_proc'::regclass;
SELECT uz.top(1);
SELECT uz.lazy_bad(1);
CREATE FUNCTION uz.base(x int) RETURNS int STRICT LANGUAGE plzig AS $f$ return x + 3; $f$;
SELECT uz.top(1);
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION uz.top(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.base(integer) as base
    return (try base.call(x)).?;
$f$;
RESET check_function_bodies;
SELECT uz.top(1);
-- the dependency was recorded for the function that exists
SELECT count(*) AS deps FROM pg_depend
 WHERE objid = 'uz.top(int)'::regprocedure AND refobjid = 'uz.base(int)'::regprocedure;
DROP FUNCTION uz.base(int);
DROP FUNCTION uz.base(int) CASCADE;
SELECT count(*) AS top_left FROM pg_proc WHERE oid = to_regprocedure('uz.top(int)');

-- pub declarations of a used function (functions, constants, types) are
-- reachable through the alias, with their Zig types; the rest is private
CREATE FUNCTION uz.lib(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    return clampTo(i32, x, 0, limit) + hidden();
}
pub const limit = 100;
pub const Pair = struct { a: i64, b: []const u8 };
pub fn clampTo(comptime T: type, v: T, lo: T, hi: T) T {
    return @max(lo, @min(hi, v));
}
pub fn describe(p: Pair) anyerror![]const u8 {
    return try std.fmt.allocPrint(plzig.allocator, "{d}:{s}", .{ p.a, p.b });
}
fn hidden() i32 {
    return 0;
$f$;
CREATE FUNCTION uz.lib_user(x bigint) RETURNS text STRICT LANGUAGE plzig AS $f$
//#use uz.lib(integer) as lib
    const c = lib.clampTo(i64, x, -lib.limit, lib.limit);
    const p: lib.Pair = .{ .a = c + (try lib.call(250)).?, .b = "pub" };
    return try lib.describe(p);
$f$;
SELECT uz.lib_user(-5000), uz.lib_user(7);
-- not pub: a private helper, the generated declarations, the used function's own uses
\set VERBOSITY default
CREATE FUNCTION uz.lib_bad1() RETURNS int LANGUAGE plzig AS $f$
//#use uz.lib(integer) as lib
    return lib.hidden();
$f$;
CREATE FUNCTION uz.lib_bad2() RETURNS int LANGUAGE plzig AS $f$
//#use uz.lib(integer) as lib
    return @intCast(lib.std.math.maxInt(u8));
$f$;
CREATE FUNCTION uz.lib_mid(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
//#use uz.lib(integer) as inner
    return try inner.call(x);
$f$;
CREATE FUNCTION uz.lib_bad3() RETURNS int LANGUAGE plzig AS $f$
//#use uz.lib_mid(integer) as mid
    return try mid.inner.call(1);
$f$;
-- the alias itself is a namespace, not a function
CREATE FUNCTION uz.lib_bad4() RETURNS int LANGUAGE plzig AS $f$
//#use uz.lib(integer) as lib
    return try lib(1);
$f$;
\set VERBOSITY terse
-- a changed pub declaration reaches the user at its next call
CREATE OR REPLACE FUNCTION uz.lib(x int) RETURNS int STRICT LANGUAGE plzig AS $f$
    return clampTo(i32, x, 0, limit);
}
pub const limit = 10;
pub const Pair = struct { a: i64, b: []const u8 };
pub fn clampTo(comptime T: type, v: T, lo: T, hi: T) T {
    return @max(lo, @min(hi, v));
}
pub fn describe(p: Pair) anyerror![]const u8 {
    return try std.fmt.allocPrint(plzig.allocator, "{d}/{s}", .{ p.a, p.b });
$f$;
SELECT uz.lib_user(-5000), uz.lib_user(7);

-- a SECURITY DEFINER user: the used function runs as part of it (as its owner)
CREATE FUNCTION uz.whoami() RETURNS text LANGUAGE plzig AS $f$
    const r = try plzig.spi.execute("SELECT current_user::text", &.{});
    return r.get(0, 0);
$f$;
CREATE FUNCTION uz.definer_user() RETURNS text SECURITY DEFINER LANGUAGE plzig AS $f$
//#use uz.whoami() as whoami
    return try whoami.call();
$f$;
RESET ROLE;
SET ROLE regress_plzig_caller;
SELECT uz.definer_user();
RESET ROLE;

-- clean up
DROP SCHEMA uz CASCADE;
DROP ROLE regress_plzig_caller;
DROP ROLE regress_plzig_exec;
