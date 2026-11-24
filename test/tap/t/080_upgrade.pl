# pg_upgrade from an older major version with PL/Zig installed in both:
# functions, the language ACL and dependent objects survive; modules are
# compiled lazily in the new cluster (its own $PGDATA/plzig).
#
# Needs a second PostgreSQL installation with PL/Zig built for it:
#   PLZIG_UPGRADE_OLD_PREFIX   e.g. /usr/lib/postgresql/15 (bin/ below it)
# Run by docker/run-all.sh in the upgrade image (docker/Dockerfile.upgrade);
# skipped otherwise.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $oldprefix = $ENV{PLZIG_UPGRADE_OLD_PREFIX};
plan skip_all => 'PLZIG_UPGRADE_OLD_PREFIX is not set (no second installation)'
  unless $oldprefix && -x "$oldprefix/bin/postgres";

# data checksums on both sides: initdb enables them by default from 18 on
my $old = PostgreSQL::Test::Cluster->new('old', install_path => $oldprefix);
$old->init(extra => ['--data-checksums']);
$old->append_conf('postgresql.conf', "plzig.zig_path = '$ENV{PLZIG_TEST_ZIG}'\n");
$old->start;
my $oldver = $old->safe_psql('postgres', 'SHOW server_version_num');
$old->safe_psql('postgres', q{
CREATE ROLE dev LOGIN;
CREATE EXTENSION plzig;
GRANT USAGE ON LANGUAGE plzig TO dev;
GRANT CREATE ON SCHEMA public TO dev;
CREATE FUNCTION double_it(x int) RETURNS int STRICT IMMUTABLE LANGUAGE plzig AS $$ return x * 2; $$;
CREATE TABLE t (x int);
INSERT INTO t SELECT generate_series(1, 100);
CREATE INDEX t_idx ON t (double_it(x));
CREATE FUNCTION greet(n text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "hello {s}", .{n});
$$;
-- a function compiled into another (//#use), owned by dev; the user's name
-- sorts before the helper's, so only the dependency orders the restore
SET ROLE dev;
CREATE FUNCTION zzz_helper(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 1; $$;
CREATE FUNCTION aaa_user(x int) RETURNS int STRICT LANGUAGE plzig AS $$
//#use public.zzz_helper(integer) as helper
    return (try helper.call(x)).? * 10;
$$;
RESET ROLE;
});
is($old->safe_psql('postgres', 'SELECT aaa_user(1)'), '20', 'a function using another, in the old cluster');
is($old->safe_psql('postgres', "SELECT greet('old')"), 'hello old', 'works in the old cluster');
$old->stop;

my $new = PostgreSQL::Test::Cluster->new('new');
$new->init(extra => ['--data-checksums']);
$new->append_conf('postgresql.conf', "plzig.zig_path = '$ENV{PLZIG_TEST_ZIG}'\n");
my $newbindir = `pg_config --bindir`;
chomp $newbindir;

command_ok(
	[
		'pg_upgrade', '--no-sync',
		'-d', $old->data_dir, '-D', $new->data_dir,
		'-b', "$oldprefix/bin", '-B', $newbindir,
		'-s', $new->host, '-p', $old->port, '-P', $new->port
	],
	"pg_upgrade from $oldver");
$new->start;
cmp_ok($new->safe_psql('postgres', 'SHOW server_version_num'), '>', $oldver, 'new cluster is newer');
is($new->safe_psql('postgres', "SELECT extversion FROM pg_extension WHERE extname = 'plzig'"),
	'1.0', 'extension present');
ok(!-e $new->data_dir . '/plzig/cache', 'no module cache carried over');
is($new->safe_psql('postgres', "SELECT greet('new'), double_it(21)"), 'hello new|42',
	'functions compile lazily and work after the upgrade');
is($new->safe_psql('postgres', 'SET enable_seqscan = off; SELECT count(*) FROM t WHERE double_it(x) = 84'),
	'1', 'expression index usable');
is($new->safe_psql('postgres', "SELECT has_language_privilege('dev', 'plzig', 'USAGE'), has_language_privilege('public', 'plzig', 'USAGE')"),
	't|f', 'language ACL preserved');
is($new->safe_psql('postgres', 'SET ROLE dev; SELECT aaa_user(4)'), '50',
	'the function using another compiles and works after the upgrade');
is($new->safe_psql('postgres', q{SELECT count(*) FROM pg_depend
	WHERE objid = 'aaa_user(int)'::regprocedure AND refobjid = 'zzz_helper(int)'::regprocedure
	  AND deptype = 'n'}), '1', 'its dependency on the used function is in the new cluster');
my ($rc, $out, $err) = $new->psql('postgres', 'DROP FUNCTION zzz_helper(int)');
like($err, qr/other objects depend on it/, 'the used function cannot be dropped alone');
$new->stop;
done_testing();
