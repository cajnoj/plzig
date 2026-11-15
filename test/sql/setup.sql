--
-- setup: extension objects, privileges, roles used by the other tests
--
\set VERBOSITY terse
LOAD 'plzig';
SELECT current_user AS regress_superuser \gset

-- the language is trusted, but USAGE is not granted to PUBLIC
SELECT lanname, lanpltrusted, lanplcallfoid::regproc, laninline::regproc, lanvalidator::regproc
  FROM pg_language WHERE lanname = 'plzig';
SELECT has_language_privilege('public', 'plzig', 'USAGE') AS public_usage;
SELECT extname, extversion, extnamespace::regnamespace FROM pg_extension WHERE extname = 'plzig';

-- roles (cluster-wide; dropped again at the end of the lifecycle test)
DROP ROLE IF EXISTS regress_plzig_dev;
DROP ROLE IF EXISTS regress_plzig_nobody;
CREATE ROLE regress_plzig_dev LOGIN;
CREATE ROLE regress_plzig_nobody;
GRANT USAGE ON LANGUAGE plzig TO regress_plzig_dev;
GRANT CREATE ON SCHEMA public TO regress_plzig_dev;
CREATE SCHEMA regress_plzig_open;
GRANT USAGE, CREATE ON SCHEMA regress_plzig_open TO regress_plzig_nobody;
SELECT has_language_privilege('regress_plzig_dev', 'plzig', 'USAGE') AS dev_usage,
       has_language_privilege('regress_plzig_nobody', 'plzig', 'USAGE') AS nobody_usage;

-- without USAGE, CREATE FUNCTION ... LANGUAGE plzig is refused
SET ROLE regress_plzig_nobody;
CREATE FUNCTION regress_plzig_open.nope() RETURNS int LANGUAGE plzig AS $$ return 1; $$;
CREATE FUNCTION regress_plzig_open.ok() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;
DROP FUNCTION regress_plzig_open.ok();
DO $$ $$ LANGUAGE plzig;
RESET ROLE;

-- the diagnostics and cache functions are not executable by PUBLIC
SET ROLE regress_plzig_nobody;
SELECT plzig_sandbox_status();
SELECT plzig_cache_clear();
RESET ROLE;
SET ROLE regress_plzig_dev;
SELECT plzig_cache_clear();
RESET ROLE;

-- GUCs exist, and the security-relevant ones cannot be changed by ordinary users
-- (the toolchain paths are site-specific; zig_path must be set for this suite.
-- A package compiles in its toolchain's compiler as zig_path's default, which
-- is then also the setting: docker/security-checks.sh checks that a source
-- build has no default, packaging/test-packages.sh that a package has its own)
SELECT name,
       CASE WHEN name IN ('plzig.zig_path', 'plzig.zig_lib_dir', 'plzig.zig_sha256')
            THEN CASE WHEN setting = '' THEN '(empty)' ELSE '(set)' END
            ELSE setting END AS setting,
       unit, context,
       CASE WHEN name IN ('plzig.zig_path', 'plzig.zig_lib_dir', 'plzig.zig_sha256')
            THEN CASE WHEN boot_val IN ('', setting) THEN '' ELSE '(other)' END
            ELSE boot_val END AS boot_val
  FROM pg_settings WHERE name LIKE 'plzig.%' ORDER BY name;
SET ROLE regress_plzig_dev;
SET plzig.max_memory = '512MB';
SET plzig.compile_timeout = '1h';
SET plzig.compiler_sandbox = off;
SET plzig.zig_path = '/bin/sh';
SET plzig.zig_lib_dir = '/';
SET plzig.zig_sha256 = '';
SET plzig.compile_memory_limit = 0;
SET plzig.instance_cache_size = 1000;
SET plzig.max_source_size = '3MB';
SET plzig.max_module_size = '16MB';
SET plzig.instance_cache_max_memory = '1GB';
SET plzig.cache_size_limit = '1TB';
SET plzig.max_prepared_plans = 10000;
SET plzig.max_open_cursors = 1000;
RESET ROLE;

-- the toolchain and sandbox settings are config-file only, even for superusers:
-- not per session, role or database, not ALTER SYSTEM
SET plzig.zig_path = '/bin/sh';
SET plzig.zig_lib_dir = '/';
SET plzig.zig_sha256 = '';
SET plzig.compiler_sandbox = try;
SET plzig.cache_size_limit = '1TB';
SELECT set_config('plzig.zig_path', '/bin/sh', false);
ALTER ROLE regress_plzig_dev SET plzig.zig_path = '/bin/sh';
ALTER ROLE regress_plzig_dev SET plzig.zig_lib_dir = '/';
ALTER ROLE regress_plzig_dev SET plzig.compiler_sandbox = off;
SELECT current_database() AS regress_db \gset
ALTER DATABASE :"regress_db" SET plzig.zig_path = '/bin/sh';
ALTER DATABASE :"regress_db" SET plzig.zig_sha256 = '';
ALTER ROLE regress_plzig_dev IN DATABASE :"regress_db" SET plzig.zig_path = '/bin/sh';
ALTER SYSTEM SET plzig.zig_path = '/bin/sh';
ALTER SYSTEM SET plzig.zig_lib_dir = '/';
ALTER SYSTEM SET plzig.zig_sha256 = '';
ALTER SYSTEM SET plzig.compiler_sandbox = off;
ALTER SYSTEM SET plzig.cache_size_limit = '1TB';
ALTER ROLE regress_plzig_dev SET plzig.cache_size_limit = '1TB';
SELECT count(*) AS role_db_settings FROM pg_db_role_setting
 WHERE array_to_string(setconfig, ',') LIKE '%plzig.%';

-- placeholders set by an ordinary user before the library is loaded are not
-- applied when it loads (fresh session as regress_plzig_dev)
\c - regress_plzig_dev
SET plzig.max_memory = '512MB';
SET plzig.compiler_sandbox = off;
DO $$ $$ LANGUAGE plzig;
SHOW plzig.max_memory;
SHOW plzig.compiler_sandbox;
\c - :regress_superuser
