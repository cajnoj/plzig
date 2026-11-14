# Streaming hot standby: functions created on the primary run on the
# read-only standby, which compiles them lazily into its own cache; a
# function that writes fails cleanly there.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $primary = plzig_node('primary', allows_streaming => 1);
$primary->safe_psql('postgres', q{
CREATE TABLE t (x int);
INSERT INTO t SELECT generate_series(1, 10);
CREATE FUNCTION before_backup() RETURNS int LANGUAGE plzig AS $$ return 1; $$;
});
$primary->backup('bk');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'bk', has_streaming => 1);
# The test framework copies the backup with RecursiveCopy, which does not
# keep modes; PL/Zig insists on private directories and files, so restore
# the modes the base backup has (pg_basebackup keeps 0700/0600).
copy_modes($primary->backup_dir . '/bk', $standby->data_dir, 'plzig');
$standby->start;

my $cached = sub {
	my ($n) = @_;
	return $n->safe_psql('postgres',
		"SELECT count(*) FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm'");
};

# the Zig cache and build directories are not part of a base backup
ok(!-e $standby->data_dir . '/plzig/pgsql_tmp.zig-cache', 'base backup skipped the Zig cache');

$primary->safe_psql('postgres', q{
CREATE FUNCTION sum_t() RETURNS bigint STABLE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT sum(x) FROM t", &.{});
    return try std.fmt.parseInt(i64, (try r.get(0, 0)).?, 10);
$$;
CREATE FUNCTION add_row(v int) RETURNS bigint STRICT VOLATILE LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    const r = try plzig.spi.execute("INSERT INTO t VALUES ($1::int)", &.{try std.fmt.bufPrint(&buf, "{d}", .{v})});
    return @intCast(r.rows);
$$;
});
$primary->wait_for_catchup($standby);

is($standby->safe_psql('postgres', 'SELECT pg_is_in_recovery()'), 't', 'standby is in recovery');
my $before = $cached->($standby);
is($standby->safe_psql('postgres', 'SELECT sum_t()'), '55', 'function runs on the standby');
is($cached->($standby), $before + 1, 'compiled lazily into the standby\'s own cache');
is($standby->safe_psql('postgres', 'SELECT before_backup()'), '1', 'function from before the backup runs');

my ($rc, $out, $err) = $standby->psql('postgres', 'SELECT add_row(5)');
isnt($rc, 0, 'writing function fails on the standby');
like($err, qr/cannot execute INSERT in a read-only transaction/, 'with the read-only error');
is($standby->safe_psql('postgres', 'SELECT sum_t()'), '55', 'standby still healthy');

# a replaced function is picked up on the standby after replay
$primary->safe_psql('postgres',
	q{CREATE OR REPLACE FUNCTION before_backup() RETURNS int LANGUAGE plzig AS $$ return 2; $$});
$primary->wait_for_catchup($standby);
is($standby->safe_psql('postgres', 'SELECT before_backup()'), '2', 'replacement visible on the standby');
# a long-lived standby session sees it too (invalidation through replay)
my $s = $standby->background_psql('postgres');
is($s->query_safe('SELECT before_backup()'), '2', 'session on the standby');
$primary->safe_psql('postgres',
	q{CREATE OR REPLACE FUNCTION before_backup() RETURNS int LANGUAGE plzig AS $$ return 3; $$});
$primary->wait_for_catchup($standby);
is($s->query_safe('SELECT before_backup()'), '3', 'same session sees the replayed replacement');
$s->quit;

# DO blocks work on the standby as well (never cached)
my $dobefore = $cached->($standby);
$standby->safe_psql('postgres', q{DO $$ plzig.notice("on the standby", .{}); $$ LANGUAGE plzig});
is($cached->($standby), $dobefore, 'DO block on the standby left no module');

# promotion: the function can write afterwards
$standby->promote;
$standby->poll_query_until('postgres', 'SELECT NOT pg_is_in_recovery()');
is($standby->safe_psql('postgres', 'SELECT add_row(45)'), '1', 'writes after promotion');
is($standby->safe_psql('postgres', 'SELECT sum_t()'), '100', 'and reads its write');

$standby->stop;
$primary->stop;
done_testing();
