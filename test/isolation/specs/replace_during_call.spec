# CREATE OR REPLACE and DROP FUNCTION while another session is in the middle
# of a call (blocked inside the guest on an advisory lock taken through SPI):
# the running call finishes with the old code, the next call sees the change.

setup
{
  CREATE FUNCTION iso_r() RETURNS text VOLATILE LANGUAGE plzig AS $$
    // (no braces: an isolation spec cannot contain them)
    _ = try plzig.spi.execute("SELECT pg_advisory_xact_lock(4711)", &std.mem.zeroes([0]?[]const u8));
    return "old code";
  $$;
}

teardown
{
  DROP FUNCTION IF EXISTS iso_r();
}

session s1
step s1_call   { SELECT iso_r(); }

session s2
step s2_replace { CREATE OR REPLACE FUNCTION iso_r() RETURNS text VOLATILE LANGUAGE plzig AS $$ return "new code"; $$; }
step s2_drop    { DROP FUNCTION iso_r(); }
step s2_call    { SELECT iso_r(); }

session s3
step s3_lock   { SELECT pg_advisory_lock(4711); }
step s3_unlock { SELECT pg_advisory_unlock(4711); }

permutation s3_lock s1_call s2_replace s2_call s3_unlock s1_call
permutation s3_lock s1_call s2_drop s3_unlock s1_call
