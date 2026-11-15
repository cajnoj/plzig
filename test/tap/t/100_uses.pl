# //#use: a function compiled into another.  A session that has the using
# function loaded must notice every change of a used function made by
# another session (body, owner, EXECUTE, SECURITY DEFINER, SET, rename,
# drop, a role membership that carried EXECUTE), re-run the checks at the
# next call and fail cleanly when they fail; and must never find a stale
# module in the cache.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = plzig_node('uses');
$node->safe_psql('postgres', q{
CREATE ROLE dev LOGIN;
CREATE ROLE other;
CREATE ROLE exec_group;
GRANT USAGE ON LANGUAGE plzig TO dev;
CREATE SCHEMA s AUTHORIZATION dev;
GRANT USAGE ON SCHEMA s TO other;
SET ROLE dev;
CREATE FUNCTION s.helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 1; $$;
CREATE FUNCTION s.user_fn(x int) RETURNS int STRICT LANGUAGE plzig AS $$
//#use s.helper(integer) as helper
    return (try helper.call(x)).? * 10;
$$;
});

# a query in the long-lived session: (stdout, stderr)
sub sq
{
	my ($s, $sql) = @_;
	$s->{stderr} = '';
	my $out = $s->query($sql);
	my $err = $s->{stderr};
	$s->{stderr} = '';
	return ($out, $err);
}

my $s = $node->background_psql('postgres', on_error_stop => 0);
sq($s, 'SET ROLE dev');
my ($out, $err) = sq($s, 'SELECT s.user_fn(1)');
is($out, '20', 'loaded in the long-lived session');

# each change, made by another session, then reverted
my @cases = (
	[ 'new body', q{CREATE OR REPLACE FUNCTION s.helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 2; $$},
	  undef, '30', q{CREATE OR REPLACE FUNCTION s.helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 1; $$} ],
	[ 'other owner', 'ALTER FUNCTION s.helper(int) OWNER TO other',
	  qr/cannot use s\.helper\(integer\): it has a different owner/, undef,
	  'ALTER FUNCTION s.helper(int) OWNER TO dev' ],
	[ 'EXECUTE revoked', 'REVOKE EXECUTE ON FUNCTION s.helper(int) FROM PUBLIC, dev',
	  qr/permission denied for function s\.helper\(integer\)/, undef,
	  'GRANT EXECUTE ON FUNCTION s.helper(int) TO dev' ],
	[ 'SECURITY DEFINER', 'ALTER FUNCTION s.helper(int) SECURITY DEFINER',
	  qr/it is SECURITY DEFINER/, undef, 'ALTER FUNCTION s.helper(int) SECURITY INVOKER' ],
	[ 'SET clause', q{ALTER FUNCTION s.helper(int) SET search_path = s},
	  qr/it has SET clauses/, undef, 'ALTER FUNCTION s.helper(int) RESET ALL' ],
	[ 'renamed', 'ALTER FUNCTION s.helper(int) RENAME TO helper2',
	  qr/function "s\.helper\(integer\)" does not exist/, undef,
	  'ALTER FUNCTION s.helper2(int) RENAME TO helper' ],
	[ 'the user itself given to another owner', 'ALTER FUNCTION s.user_fn(int) OWNER TO other',
	  qr/cannot use s\.helper\(integer\): it has a different owner/, undef,
	  'ALTER FUNCTION s.user_fn(int) OWNER TO dev' ],
);
for my $c (@cases)
{
	my ($name, $change, $fails, $result, $revert) = @$c;
	$node->safe_psql('postgres', $change);
	($out, $err) = sq($s, 'SELECT s.user_fn(1)');
	if ($fails)
	{
		like($err, $fails, "$name: the next call fails with a clear error");
	}
	else
	{
		is($out, $result, "$name: the next call runs the new code");
		is($err, '', "$name: without an error");
	}
	$node->safe_psql('postgres', $revert);
	($out, $err) = sq($s, 'SELECT s.user_fn(1)');
	is($out, '20', "$name reverted: works again");
	is($err, '', "$name reverted: no error");
}

# EXECUTE only through a role membership; the membership is revoked
$node->safe_psql('postgres', q{
REVOKE EXECUTE ON FUNCTION s.helper(int) FROM PUBLIC, dev;
GRANT EXECUTE ON FUNCTION s.helper(int) TO exec_group;
GRANT exec_group TO dev;
});
($out, $err) = sq($s, 'SELECT s.user_fn(1)');
is($out, '20', 'EXECUTE through a membership');
$node->safe_psql('postgres', 'REVOKE exec_group FROM dev');
($out, $err) = sq($s, 'SELECT s.user_fn(1)');
like($err, qr/permission denied for function s\.helper\(integer\)/,
	'membership revoked in another session: noticed at the next call');
$node->safe_psql('postgres', 'GRANT EXECUTE ON FUNCTION s.helper(int) TO dev');
($out, $err) = sq($s, 'SELECT s.user_fn(1)');
is($out, '20', 'EXECUTE granted again');

# dropped: refused while the dependency exists; a user created without
# the dependency (check_function_bodies = off before the helper existed)
# notices the drop
my ($rc, $o, $e) = $node->psql('postgres', 'DROP FUNCTION s.helper(int)');
like($e, qr/other objects depend on it/, 'DROP of a used function needs CASCADE');
$node->safe_psql('postgres', q{
SET ROLE dev;
SET check_function_bodies = off;
CREATE FUNCTION s.lazy_user(x int) RETURNS int STRICT LANGUAGE plzig AS $$
//#use s.helper2(integer) as h
    return (try h.call(x)).?;
$$;
RESET check_function_bodies;
CREATE FUNCTION s.helper2(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 5; $$;
});
is($node->safe_psql('postgres',
		"SELECT count(*) FROM pg_depend WHERE objid = 's.lazy_user(int)'::regprocedure AND refclassid = 'pg_proc'::regclass"),
	'0', 'no dependency recorded for a function that did not exist yet');
($out, $err) = sq($s, 'SELECT s.lazy_user(1)');
is($out, '6', 'the late helper is compiled in at the first call');
$node->safe_psql('postgres', 'DROP FUNCTION s.helper2(int)');
($out, $err) = sq($s, 'SELECT s.lazy_user(1)');
like($err, qr/function "s\.helper2\(integer\)" does not exist/, 'dropped in another session: noticed');

# the module cache: a session that never loaded the user must not get the
# module built with the old helper
my $before = $node->safe_psql('postgres',
	"SELECT string_agg(d, ',' ORDER BY d) FROM pg_ls_dir('plzig/cache') d");
$node->safe_psql('postgres',
	q{CREATE OR REPLACE FUNCTION s.helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 7; $$});
is($node->safe_psql('postgres', 'SET ROLE dev; SELECT s.user_fn(1)'), '80',
	'a fresh session compiles the user with the new helper');
my $after = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_ls_dir('plzig/cache') d WHERE d <> ALL (string_to_array('$before', ','))");
is($after, '2', 'new modules: the helper and the user built with it');
($out, $err) = sq($s, 'SELECT s.user_fn(1)');
is($out, '80', 'the long-lived session runs the new code as well');

$s->quit;
done_testing();
