# plzig_cache_clear() while another session executes a function: the clear
# does not wait, the running call is not disturbed, the module is recompiled
# on next use in a new session.  (plzig_cache_clear() while another session
# compiles waits for the compile lock, which isolationtester cannot observe;
# that case is in test/tap/t/020_compile_lock.pl.)

setup
{
  SELECT plzig_cache_clear() >= 0 AS cleared;
  CREATE FUNCTION iso_r() RETURNS text VOLATILE LANGUAGE plzig AS $$
    // (no braces: an isolation spec cannot contain them)
    _ = try plzig.spi.execute("SELECT pg_advisory_xact_lock(4712)", &std.mem.zeroes([0]?[]const u8));
    return "ran";
  $$;
  CREATE FUNCTION iso_cached() RETURNS int LANGUAGE sql AS $f$
    SELECT count(*)::int FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm'
  $f$;
}

teardown
{
  DROP FUNCTION IF EXISTS iso_r(), iso_cached();
}

session s1
step s1_call_r { SELECT iso_r(); }

session s2
step s2_clear  { SELECT plzig_cache_clear() >= 1 AS removed_some; }
step s2_cached { SELECT iso_cached() AS cached_modules; }

session s3
step s3_lock     { SELECT pg_advisory_lock(4712); }
step s3_unlock   { SELECT pg_advisory_unlock(4712); }
step s3_call_r   { SELECT iso_r(); }

permutation s1_call_r s2_cached s3_lock s1_call_r s2_clear s2_cached s3_unlock s1_call_r s2_cached s3_call_r s2_cached
