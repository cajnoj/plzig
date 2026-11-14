--
-- resources: interrupts, memory cap, compile limits, cleanup
--
\set VERBOSITY terse

-- an infinite loop makes no host calls; statement_timeout still stops it
CREATE FUNCTION spin(seed bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var x: u64 = @bitCast(seed);
    while (x != 0) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
    }
    return 0;
$$;
SET statement_timeout = '300ms';
SELECT spin(1);
RESET statement_timeout;
SELECT spin(0);

-- also inside deep call chains (checked at function entry)
CREATE FUNCTION spin_calls(seed bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var x: u64 = @bitCast(seed);
    while (true) x = step(x);
}
noinline fn step(x: u64) u64 {
    return x *% 6364136223846793005 +% 1442695040888963407;
$$;
SET statement_timeout = '300ms';
SELECT spin_calls(1);
RESET statement_timeout;

-- guest memory is capped by plzig.max_memory (default 64MB): OutOfMemory in the guest
CREATE FUNCTION grab_mb(mb int) RETURNS int STRICT LANGUAGE plzig AS $$
    const n: usize = @intCast(mb);
    const buf = try plzig.allocator.alloc(u8, n << 20);
    @memset(buf, 1);
    return @intCast(buf.len >> 20);
$$;
SELECT grab_mb(16);
SELECT grab_mb(100);
SELECT grab_mb(16);
SET plzig.max_memory = '128MB';
SELECT grab_mb(100);
RESET plzig.max_memory;

-- OutOfMemory can be handled in the guest
CREATE FUNCTION grab_or_fallback() RETURNS text LANGUAGE plzig AS $$
    const buf = plzig.allocator.alloc(u8, 1 << 30) catch return "fallback";
    _ = buf;
    return "got it";
$$;
SELECT grab_or_fallback();

-- a module whose static data exceeds the cap cannot be instantiated
-- (the validator instantiates it too, so create it under a larger cap)
CREATE FUNCTION huge_static(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    const idx: usize = @intCast(i);
    big[idx] +%= 1;
    return big[idx];
}
var big: [96 * 1024 * 1024]u8 = undefined;
fn unused() void {
$$;
SET plzig.max_memory = '256MB';
-- (and keep such a large instance cached, see plzig.instance_cache_max_memory below)
SET plzig.instance_cache_max_memory = '256MB';
CREATE FUNCTION huge_static(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    const idx: usize = @intCast(i);
    big[idx] +%= 1;
    return big[idx];
}
var big: [96 * 1024 * 1024]u8 = undefined;
fn unused() void {
$$;
SELECT huge_static(12345), huge_static(12345);
RESET plzig.max_memory;
-- lowering the cap retires cached instances
SELECT huge_static(12345);
RESET plzig.instance_cache_max_memory;

-- an idle instance whose memory grew beyond plzig.instance_cache_max_memory
-- (default 4MB) is destroyed after the call instead of being kept
CREATE FUNCTION plzig_mem() RETURNS bigint LANGUAGE sql AS $$
  SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts WHERE name LIKE 'PL/Zig%'
$$;
SELECT grab_mb(1);   -- warm up: module loaded, small instance cached
SELECT plzig_mem() AS before_40mb \gset
SELECT grab_mb(40);
SELECT plzig_mem() - :before_40mb < 4 * 1024 * 1024 AS memory_released;
SET plzig.instance_cache_max_memory = '64MB';
SELECT grab_mb(40);
SELECT plzig_mem() - :before_40mb > 30 * 1024 * 1024 AS memory_kept;
RESET plzig.instance_cache_max_memory;
SELECT grab_mb(1);   -- the large cached instance is used once more, then dropped
SELECT plzig_mem() - :before_40mb < 4 * 1024 * 1024 AS memory_released_again;

-- compiled module size limit (plzig.max_module_size, default 2MB): large
-- constant data ends up in the module
CREATE FUNCTION big_const(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    return big[@intCast(i)];
}
const big: [3 << 20]u8 = @splat(7);
fn unused() void {
$$;
SET plzig.max_module_size = '4MB';
CREATE FUNCTION big_const(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    return big[@intCast(i)];
}
const big: [3 << 20]u8 = @splat(7);
fn unused() void {
$$;
SELECT big_const(12345);
RESET plzig.max_module_size;
SELECT name, setting, unit, min_val, max_val FROM pg_settings
 WHERE name IN ('plzig.max_module_size', 'plzig.instance_cache_max_memory', 'plzig.cache_size_limit')
 ORDER BY name;

-- DO blocks are compiled, run and discarded: they never reach the cache
SELECT count(*) AS cache_files_before FROM pg_ls_dir('plzig/cache') \gset
DO $$ plzig.notice("not cached", .{}); $$ LANGUAGE plzig;
DO $$ plzig.notice("not cached either", .{}); $$ LANGUAGE plzig;
SELECT count(*) - :cache_files_before AS new_cache_files FROM pg_ls_dir('plzig/cache');

-- messages shown to an unprivileged user never contain the data directory
SELECT set_config('regress.datadir', current_setting('data_directory'), false) IS NOT NULL AS ok;
SET ROLE regress_plzig_dev;
DO $d$
DECLARE
  dd text := current_setting('regress.datadir');
  m text;
  d text;
  h text;
  s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    -- module too large (used to name the file in the build directory)
    'CREATE FUNCTION leak1(i int) RETURNS int STRICT LANGUAGE plzig AS $z$ return big[@intCast(i)]; } const big: [3 << 20]u8 = @splat(7); fn unused() void { $z$',
    -- compile error, mentioning SDK files of the build directory
    'CREATE FUNCTION leak2() RETURNS int LANGUAGE plzig AS $z$ _ = std.fs; return 1; $z$',
    -- policy violation
    'CREATE FUNCTION leak3() RETURNS int LANGUAGE plzig AS $z$ return @embedFile("x"); $z$']
  LOOP
    BEGIN
      EXECUTE s;
      RAISE NOTICE 'no error';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
      RAISE NOTICE '%: data directory shown: %, build directory shown: %', m,
        strpos(concat(m, d, h), dd) > 0, strpos(concat(m, d, h), 'pgsql_tmp') > 0;
    END;
  END LOOP;
END $d$;
RESET ROLE;

-- source size limit
SET plzig.max_source_size = '1kB';
DO $d$
BEGIN
  EXECUTE 'CREATE FUNCTION too_long() RETURNS int LANGUAGE plzig AS ' ||
          quote_literal(repeat('// padding' || chr(10), 200) || 'return 1;');
END $d$;
RESET plzig.max_source_size;

-- compile timeout (a large, unique body so it is slow and not already cached);
-- the compiler is killed and its build directory removed
SET plzig.compile_timeout = '100ms';
DO $d$
DECLARE body text;
BEGIN
  -- ~12000 chained functions: takes seconds to compile, never cached
  SELECT 'return g1(' || (random() * 1000000)::int || ');' || chr(10) || '}' || chr(10) ||
         string_agg(format('noinline fn g%s(x: i32) i32 { return g%s(x *%% %s +%% 7) +%% 1; }', i, i + 1, i), chr(10)) ||
         chr(10) || 'fn g12001(x: i32) i32 { return x; }' || chr(10) || 'fn unused() void {'
    INTO body FROM generate_series(1, 12000) i;
  EXECUTE format('CREATE FUNCTION slow_compile() RETURNS int LANGUAGE plzig AS %L', body);
END $d$;
RESET plzig.compile_timeout;

-- statement_timeout also cancels a running compilation
SET statement_timeout = '150ms';
DO $d$
DECLARE body text;
BEGIN
  -- ~12000 chained functions: takes seconds to compile, never cached
  SELECT 'return g1(' || (random() * 1000000)::int || ');' || chr(10) || '}' || chr(10) ||
         string_agg(format('noinline fn g%s(x: i32) i32 { return g%s(x *%% %s +%% 7) +%% 1; }', i, i + 1, i), chr(10)) ||
         chr(10) || 'fn g12001(x: i32) i32 { return x; }' || chr(10) || 'fn unused() void {'
    INTO body FROM generate_series(1, 12000) i;
  EXECUTE format('CREATE FUNCTION slow_compile2() RETURNS int LANGUAGE plzig AS %L', body);
END $d$;
RESET statement_timeout;

-- no build directories are left behind
SELECT count(*) AS leftover_build_dirs
  FROM pg_ls_dir('plzig') AS d WHERE d LIKE 'pgsql_tmp.build.%';
SELECT count(*) > 0 AS cached_modules
  FROM pg_ls_dir('plzig/cache') AS d WHERE d LIKE '%.wasm';
SELECT count(*) AS temp_files
  FROM pg_ls_dir('plzig/cache') AS d WHERE d LIKE '%.tmp.%';

-- the backend is still healthy
SELECT spin(0) AS alive;
