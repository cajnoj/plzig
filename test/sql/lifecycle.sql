--
-- lifecycle: replace, lazy compilation, validator behaviour, instance cache
--
\set VERBOSITY terse

-- CREATE OR REPLACE picks up the new code in the same session
CREATE FUNCTION version_fn() RETURNS int LANGUAGE plzig AS $$ return 1; $$;
SELECT version_fn();
CREATE OR REPLACE FUNCTION version_fn() RETURNS int LANGUAGE plzig AS $$ return 2; $$;
SELECT version_fn();

-- rolled-back replacement: the old code is used again
BEGIN;
CREATE OR REPLACE FUNCTION version_fn() RETURNS int LANGUAGE plzig AS $$ return 3; $$;
SELECT version_fn();
ROLLBACK;
SELECT version_fn();

-- check_function_bodies = off (pg_dump restore): no compilation at CREATE ...
SET check_function_bodies = off;
CREATE FUNCTION lazy_ok() RETURNS text LANGUAGE plzig AS $$ return "compiled lazily"; $$;
CREATE FUNCTION lazy_bad() RETURNS int LANGUAGE plzig AS $$ return @embedFile("/etc/passwd"); $$;
CREATE FUNCTION lazy_broken() RETURNS int LANGUAGE plzig AS $$ return nope; $$;
-- ... but signature checks still apply
CREATE FUNCTION lazy_setof() RETURNS SETOF record LANGUAGE plzig AS $$ return; $$;
RESET check_function_bodies;
-- ... compiled (and policy-checked) at first call
SELECT lazy_ok();
SELECT lazy_bad();
SELECT lazy_broken();

-- validator access checks: cannot validate someone else's function by calling it directly
SET ROLE regress_plzig_nobody;
SELECT plzig_validator('lazy_ok()'::regprocedure);
RESET ROLE;

-- instance cache: with size 0 every call gets a fresh instance (globals reset)
CREATE FUNCTION tick() RETURNS int LANGUAGE plzig AS $$
    n += 1;
    return n;
}
var n: i32 = 0;
fn unused() void {
$$;
SELECT tick(), tick(), tick();
SET plzig.instance_cache_size = 0;
SELECT tick(), tick();
RESET plzig.instance_cache_size;
SELECT tick(), tick();
-- lowering plzig.instance_cache_size releases the idle instances of every
-- function at the next call of any PL/Zig function
SELECT tick();
SET plzig.instance_cache_size = 0;
SELECT version_fn();
RESET plzig.instance_cache_size;
SELECT tick() AS from_a_fresh_instance;

-- dropping a function while its module is cached is harmless
CREATE FUNCTION dropme() RETURNS int LANGUAGE plzig AS $$ return 5; $$;
SELECT dropme();
DROP FUNCTION dropme();
SELECT dropme();

-- functions are never shared: identical bodies keep separate globals
CREATE FUNCTION tick2() RETURNS int LANGUAGE plzig AS $$
    n += 1;
    return n;
}
var n: i32 = 0;
fn unused() void {
$$;
SELECT tick2(), tick2();

-- ALTER FUNCTION ... STABLE changes SPI to read-only on next call
CREATE TABLE lc (x int);
CREATE FUNCTION lc_ins() RETURNS bigint LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("INSERT INTO lc VALUES (1)", &.{});
    return @intCast(r.rows);
$$;
SELECT lc_ins();
ALTER FUNCTION lc_ins() STABLE;
SELECT lc_ins();

-- the compiler sandbox status is visible to superusers (value depends on the host kernel)
SELECT plzig_sandbox_status() ~ '^(enforced|partial|none) \((landlock ABI [0-9]+|no landlock), (seccomp|no seccomp)[;)]' AS status_known;

-- cleanup of cluster-wide objects
DROP OWNED BY regress_plzig_dev;
DROP OWNED BY regress_plzig_nobody;
DROP ROLE regress_plzig_dev;
DROP ROLE regress_plzig_nobody;
