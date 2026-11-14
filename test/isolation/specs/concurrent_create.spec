# Two sessions create (or replace) the same new function concurrently: the
# second waits for the first transaction on the catalog, then fails or
# succeeds as for any other language; the module is compiled once.

setup
{
  SELECT plzig_cache_clear() >= 0 AS cleared;
}

teardown
{
  DROP FUNCTION IF EXISTS iso_same();
}

session s1
step s1_begin  { BEGIN; }
step s1_create { CREATE FUNCTION iso_same() RETURNS text LANGUAGE plzig AS $$ return "from s1"; $$; }
step s1_replace { CREATE OR REPLACE FUNCTION iso_same() RETURNS text LANGUAGE plzig AS $$ return "replaced by s1"; $$; }
step s1_commit { COMMIT; }
step s1_rollback { ROLLBACK; }
step s1_call   { SELECT iso_same(); }

session s2
step s2_create { CREATE FUNCTION iso_same() RETURNS text LANGUAGE plzig AS $$ return "from s2"; $$; }
step s2_replace { CREATE OR REPLACE FUNCTION iso_same() RETURNS text LANGUAGE plzig AS $$ return "replaced by s2"; $$; }
step s2_call   { SELECT iso_same(); }

# s2 waits for s1's insert into pg_proc; s1 commits, s2 fails
permutation s1_begin s1_create s2_create s1_commit s2_call s1_call
# s1 rolls back: s2's function is created
permutation s1_begin s1_create s2_create s1_rollback s2_call s1_call
# both replace an existing function: the second waits, then sees a concurrent update
permutation s2_create s1_begin s1_replace s2_replace s1_commit s2_call s1_call
