--
-- signatures: every rejected signature category, argument counts and names,
-- defaults, SET clauses, use as an aggregate support function
--
\set VERBOSITY terse

-- sets
CREATE FUNCTION sg_setof() RETURNS SETOF int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_setof_rec(x int) RETURNS SETOF record LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_table() RETURNS TABLE (a int, b text) LANGUAGE plzig AS $$ return null; $$;
-- parameter modes
CREATE FUNCTION sg_out(x int, OUT y int) LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sg_out2(x int, OUT a int, OUT b int) LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sg_inout(INOUT x int) LANGUAGE plzig AS $$ return; $$;
CREATE PROCEDURE sg_proc_inout(INOUT x int) LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sg_variadic(VARIADIC x int[]) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_variadic2(a text, VARIADIC x text[]) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
-- polymorphic types, as arguments and as result
CREATE FUNCTION sg_poly1(x anyelement) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly2(x anyarray) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly3(x anynonarray) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly4(x anyenum) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly5(x anyrange) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly6(x anycompatible) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_poly7(x anyelement) RETURNS anyelement LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_poly8() RETURNS anyelement LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_poly9(x "any") RETURNS int LANGUAGE plzig AS $$ return 1; $$;
-- other pseudo-types
CREATE FUNCTION sg_rec_arg(x record) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_rec_ret() RETURNS record LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_cstring_arg(x cstring) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_cstring_ret() RETURNS cstring LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_internal_arg(x internal) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_internal_both(x internal) RETURNS internal LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_handler() RETURNS language_handler LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_fdw() RETURNS fdw_handler LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_tsm(x internal) RETURNS tsm_handler LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_ddl(x pg_ddl_command) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
-- triggers and event triggers (as result and as argument type)
CREATE FUNCTION sg_trigger() RETURNS trigger LANGUAGE plzig AS $$ return null; $$;
CREATE FUNCTION sg_evt() RETURNS event_trigger LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sg_trigger_arg(x trigger) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
-- shell types (PostgreSQL's NOTICE about them has a version-dependent position)
CREATE TYPE sg_shell;
SET client_min_messages = warning;
CREATE FUNCTION sg_shell_arg(x sg_shell) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_shell_ret() RETURNS sg_shell LANGUAGE plzig AS $$ return null; $$;
RESET client_min_messages;
DROP TYPE sg_shell;
-- window functions
CREATE FUNCTION sg_window(x int) RETURNS int WINDOW LANGUAGE plzig AS $$ return x; $$;
-- with check_function_bodies = off the signature is still checked
SET check_function_bodies = off;
CREATE FUNCTION sg_lazy_setof() RETURNS SETOF record LANGUAGE plzig AS $$ return; $$;
CREATE FUNCTION sg_lazy_poly(x anyelement) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_lazy_name("bad name" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
RESET check_function_bodies;
-- nothing was created
SELECT count(*) AS created FROM pg_proc WHERE proname LIKE 'sg\_%';

-- an ordinary PL/Zig function can serve an aggregate and a window aggregate
CREATE FUNCTION sg_step(s bigint, x int) RETURNS bigint LANGUAGE plzig AS $$
    return (s orelse 0) + (x orelse 0);
$$;
CREATE FUNCTION sg_final(s bigint) RETURNS text LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "total={?d}", .{s});
$$;
CREATE AGGREGATE sg_sum(int) (SFUNC = sg_step, STYPE = bigint, FINALFUNC = sg_final);
SELECT sg_sum(g) FROM generate_series(1, 1000) g;
SELECT sg_sum(g) FILTER (WHERE false) FROM generate_series(1, 10) g;
SELECT g, sg_sum(g) OVER (ORDER BY g) FROM generate_series(1, 4) g;
DROP AGGREGATE sg_sum(int);

--
-- argument counts: the maximum (100), one more, none
--
-- (built with EXECUTE so that the long statements are not echoed)
DO $d$
DECLARE r text;
BEGIN
  EXECUTE (SELECT format('CREATE FUNCTION sg_args100(%s) RETURNS bigint STRICT LANGUAGE plzig AS $z$ return %s; $z$',
                         string_agg(format('a%s int', i), ', ' ORDER BY i),
                         string_agg(format('@as(i64, a%s) * %s', i, i), ' + ' ORDER BY i))
             FROM generate_series(1, 100) i);
  EXECUTE (SELECT format('SELECT sg_args100(%s)', string_agg(i::text, ', ' ORDER BY i))
             FROM generate_series(1, 100) i) INTO r;
  RAISE NOTICE 'sum of squares 1..100: %', r;
  -- 100 text arguments of different sizes, one of them NULL (non-strict)
  EXECUTE (SELECT format('CREATE FUNCTION sg_text100(%s) RETURNS text LANGUAGE plzig AS $z$
    var total: usize = 0;
    var nulls: usize = 0;
    inline for (.{ %s }) |a| {
        if (a) |s| total += s.len else nulls += 1;
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d} bytes, {d} null", .{ total, nulls });
$z$', string_agg(format('a%s text', i), ', ' ORDER BY i), string_agg(format('a%s', i), ', ' ORDER BY i))
             FROM generate_series(1, 100) i);
  EXECUTE (SELECT format('SELECT sg_text100(%s)',
                         string_agg(CASE WHEN i = 50 THEN 'NULL' ELSE quote_literal(repeat('x', i)) END, ', ' ORDER BY i))
             FROM generate_series(1, 100) i) INTO r;
  RAISE NOTICE '100 text arguments: %', r;
  -- PostgreSQL's own limit
  BEGIN
    EXECUTE (SELECT format('CREATE FUNCTION sg_args101(%s) RETURNS int LANGUAGE plzig AS $z$ return 1; $z$',
                           string_agg(format('a%s int', i), ', ')) FROM generate_series(1, 101) i);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '101 arguments: %', SQLERRM;
  END;
END $d$;
SELECT proname, pronargs FROM pg_proc WHERE proname IN ('sg_args100', 'sg_text100') ORDER BY proname;
-- no arguments at all
CREATE FUNCTION sg_args0() RETURNS int LANGUAGE plzig AS $$ return 0; $$;
SELECT sg_args0();

--
-- argument names
--
-- Zig keywords, primitive type names and other special identifiers are fine
-- (they are emitted as @"name")
CREATE FUNCTION sg_kw("return" int, "fn" int, "extern" int, "asm" int, "volatile" int,
                      "i32" int, "u8" int, "true" int, "null" int, "undefined" int,
                      "type" int, "anyerror" int, "_" int, "Foo" int)
  RETURNS int STRICT LANGUAGE plzig AS $$
    return @"return" + @"fn" + @"extern" + @"asm" + @"volatile" + @"i32" + @"u8" +
        @"true" + @"null" + @"undefined" + @"type" + @"anyerror" + Foo;
$$;
SELECT sg_kw(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14);
-- named arguments in calls
SELECT sg_kw("Foo" => 1000, "return" => 1, "fn" => 0, "extern" => 0, "asm" => 0, "volatile" => 0,
             "i32" => 0, "u8" => 0, "true" => 0, "null" => 0, "undefined" => 0, "type" => 0,
             "anyerror" => 0, "_" => 0);
-- names that cannot be Zig identifiers, or would shadow the generated declarations
CREATE FUNCTION sg_bad1("with space" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad2("größe" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad3("1st" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad4("a-b" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad5("a""b" int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad6(plzig int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad7(std int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION sg_bad8(call int) RETURNS int LANGUAGE plzig AS $$ return call; $$;
-- duplicates: by PostgreSQL, and between an explicit name and a generated argN
DO $d$
BEGIN
  CREATE FUNCTION sg_dup1(a int, a int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '%', SQLERRM;   -- (without the version-dependent position)
END $d$;
CREATE FUNCTION sg_dup2(int, arg1 int) RETURNS int LANGUAGE plzig AS $$ return 1; $$;
-- a mix of named and unnamed arguments
CREATE FUNCTION sg_mixed(int, b int, int) RETURNS int STRICT LANGUAGE plzig AS $$
    return arg1 * 100 + b * 10 + arg3;
$$;
SELECT sg_mixed(1, 2, 3);
-- case matters: "A" and a are different Zig identifiers
CREATE FUNCTION sg_case("A" int, a int) RETURNS int STRICT LANGUAGE plzig AS $$ return A - a; $$;
SELECT sg_case(10, 3);

--
-- default arguments
--
CREATE FUNCTION sg_def(a int, b int DEFAULT 10, c text DEFAULT 'dflt') RETURNS text LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{?d} {?d} {?s}", .{ a, b, c });
$$;
SELECT sg_def(1), sg_def(1, 2), sg_def(1, c => 'named'), sg_def(a => 5, b => NULL), sg_def(NULL, NULL, NULL);

--
-- SET clauses: in effect during the call (also for SPI), restored afterwards
--
CREATE FUNCTION sg_set() RETURNS text LANGUAGE plzig
  SET search_path = pg_catalog SET work_mem = '1234kB' AS $$
    const r = try plzig.spi.execute("SELECT current_setting('work_mem') || ' ' || current_setting('search_path')", &.{});
    return (try r.get(0, 0)).?;
$$;
SET work_mem = '4MB';
SELECT sg_set(), current_setting('work_mem') AS after;
RESET work_mem;
-- PL/Zig's own settings can be set per function by a superuser
CREATE FUNCTION sg_set_mem(mb int) RETURNS text STRICT LANGUAGE plzig SET plzig.max_memory = '2MB' AS $$
    const b = plzig.allocator.alloc(u8, @as(usize, @intCast(mb)) << 20) catch return "out of memory";
    return try std.fmt.allocPrint(plzig.allocator, "got {d} MB", .{b.len >> 20});
$$;
SELECT sg_set_mem(1), sg_set_mem(4), current_setting('plzig.max_memory') AS after;
-- a SET clause that fails aborts the call before the guest runs
CREATE FUNCTION sg_set_bad() RETURNS int LANGUAGE plzig SET plzig.max_memory = '1MB' AS $$ return 1; $$;
SET ROLE regress_plzig_dev;
CREATE FUNCTION sg_set_dev() RETURNS int LANGUAGE plzig SET plzig.max_memory = '1MB' AS $$ return 1; $$;
SELECT sg_set_bad();
RESET ROLE;
DROP FUNCTION sg_set_bad();
