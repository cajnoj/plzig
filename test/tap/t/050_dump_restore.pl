# pg_dump/pg_restore and pg_dumpall round trips: functions are restored
# without compiling (check_function_bodies = off), compile lazily on first
# call, and the language ACL (USAGE granted to a role) is preserved.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $src = plzig_node('dump_src');
$src->safe_psql('postgres', q{
CREATE ROLE dev LOGIN;
CREATE DATABASE app;
});
$src->safe_psql('app', q{
CREATE EXTENSION plzig;
GRANT USAGE ON LANGUAGE plzig TO dev;
GRANT CREATE ON SCHEMA public TO dev;
CREATE DOMAIN even AS int CHECK (VALUE % 2 = 0);
CREATE FUNCTION double_it(x int) RETURNS int STRICT IMMUTABLE LANGUAGE plzig AS $$ return x * 2; $$;
CREATE FUNCTION to_even(x int) RETURNS even STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{d}", .{x * 2});
$$;
CREATE TABLE t (x int, d int GENERATED ALWAYS AS (double_it(x)) STORED);
CREATE INDEX t_idx ON t (double_it(x));
INSERT INTO t VALUES (1), (2), (3);
CREATE PROCEDURE p() LANGUAGE plzig AS $$ plzig.notice("proc", .{}); $$;
-- created without a body check: a policy violation that only shows when called
SET check_function_bodies = off;
CREATE FUNCTION lazy_bad() RETURNS int LANGUAGE plzig AS $$ return @embedFile("/etc/passwd"); $$;
RESET check_function_bodies;
SET ROLE dev;
CREATE FUNCTION owned_by_dev() RETURNS text LANGUAGE plzig AS $$ return "dev"; $$;
-- a function compiled into another (//#use).  The user's name sorts before
-- the helper's, so only the recorded dependency makes pg_dump restore the
-- helper first; the restore (check_function_bodies = off) must record the
-- dependency again, and the owner checks pass after ALTER ... OWNER.
CREATE FUNCTION zzz_helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 1; $$;
CREATE FUNCTION aaa_user(x int) RETURNS int STRICT LANGUAGE plzig AS $$
//#use public.zzz_helper(integer) as helper
    return (try helper.call(x)).? * 10;
$$;
RESET ROLE;
});
is($src->safe_psql('app', 'SELECT aaa_user(1)'), '20', 'a function using another');

# the dependency of a function on the functions it uses, and that it blocks DROP
sub check_uses
{
	my ($node, $db, $what) = @_;
	is($node->safe_psql($db, 'SET ROLE dev; SELECT aaa_user(4)'), '50',
		"$what: the function using another compiles and works");
	is($node->safe_psql($db, q{SELECT count(*) FROM pg_depend
		WHERE objid = 'aaa_user(int)'::regprocedure AND refobjid = 'zzz_helper(int)'::regprocedure
		  AND deptype = 'n'}), '1', "$what: its dependency on the used function is restored");
	my ($rc, $out, $err) = $node->psql($db, 'DROP FUNCTION zzz_helper(int)');
	like($err, qr/other objects depend on it/, "$what: the used function cannot be dropped alone");
	return;
}

my $tmp = PostgreSQL::Test::Utils::tempdir;

# --- pg_dump -Fc / pg_restore into a new database of the same cluster
$src->command_ok([ 'pg_dump', '-Fc', '-f', "$tmp/app.dump", '-d', $src->connstr('app') ],
	'pg_dump');
$src->safe_psql('postgres', 'CREATE DATABASE app2');
$src->safe_psql('postgres', 'SELECT plzig_cache_clear()');
# (lazy_bad would be refused if it were compiled; the index and the stored
# generated column do call double_it during the restore)
$src->command_ok([ 'pg_restore', '--exit-on-error', '-d', $src->connstr('app2'), "$tmp/app.dump" ],
	'pg_restore, with check_function_bodies = off');
is($src->safe_psql('app2', 'SELECT sum(d) FROM t'), '12', 'generated column data restored');
is($src->safe_psql('app2', 'SELECT double_it(21), to_even(4)'), '42|8', 'functions compile lazily and work');
cmp_ok($src->safe_psql('app2',
		"SELECT count(*) FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm'"),
	'>=', 1, 'modules compiled on first call');
my ($rc, $out, $err) = $src->psql('app2', 'SELECT lazy_bad()');
like($err, qr/builtin not allowed in PL\/Zig/, 'the policy still applies at the first call');
is($src->safe_psql('app2',
		"SELECT proowner::regrole FROM pg_proc WHERE proname = 'owned_by_dev'"),
	'dev', 'ownership restored');
is($src->safe_psql('app2', 'SET ROLE dev; SELECT owned_by_dev()'), 'dev', 'dev can call it');
is($src->safe_psql('app2', "SELECT has_language_privilege('dev', 'plzig', 'USAGE')"),
	't', 'language ACL preserved by pg_dump');
is($src->safe_psql('app2', "SELECT has_language_privilege('public', 'plzig', 'USAGE')"),
	'f', 'USAGE still not granted to PUBLIC');
check_uses($src, 'app2', 'pg_restore');

# --- pg_dumpall into another cluster
$src->command_ok([ 'pg_dumpall', '-f', "$tmp/all.sql", '-d', $src->connstr('postgres') ],
	'pg_dumpall');
my $dst = plzig_node('dump_dst', no_extension => 1);
my ($stdout, $stderr) = run_command([ 'psql', '-X', '-q', '-f', "$tmp/all.sql", '-d', $dst->connstr('postgres') ]);
# the only expected complaint: the bootstrap superuser exists already
my @errors = grep { /ERROR/ && !/role "[^"]+" already exists/ } split /\n/, $stderr;
is(join("\n", @errors), '', 'pg_dumpall output restored without errors');
is($dst->safe_psql('app', 'SELECT double_it(5), to_even(3)'), '10|6', 'functions work in the new cluster');
is($dst->safe_psql('app', 'SELECT count(*) FROM t WHERE double_it(x) = d'), '3', 'index/generated column consistent');
is($dst->safe_psql('app', "SELECT has_language_privilege('dev', 'plzig', 'USAGE')"),
	't', 'language ACL preserved by pg_dumpall');
is($dst->safe_psql('app', "SELECT has_language_privilege('public', 'plzig', 'USAGE')"),
	'f', 'PUBLIC still has no USAGE');
($rc, $out, $err) = $dst->psql('app', 'CALL p()');
like($err, qr/NOTICE:  proc/, 'procedure works');
check_uses($dst, 'app', 'pg_dumpall');

$src->stop;
$dst->stop;
done_testing();
