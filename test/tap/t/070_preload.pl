# shared_preload_libraries = 'plzig' and session_preload_libraries = 'plzig'
# both work; with shared_preload_libraries the library is loaded into the
# postmaster, which must not initialise the WebAssembly runtime there.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

sub postmaster_status
{
	my ($node) = @_;
	my $pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'checkpointer'");
	# the checkpointer's parent is the postmaster
	open(my $fh, '<', "/proc/$pid/stat") or die;
	my $stat = <$fh>;
	close $fh;
	my ($ppid) = $stat =~ /\)\s+\S+\s+(\d+)/;
	open($fh, '<', "/proc/$ppid/status") or die;
	my %st = map { /^(\w+):\s*(.*)$/ ? ($1, $2) : () } <$fh>;
	close $fh;
	return ($ppid, \%st);
}

for my $setting (qw(shared_preload_libraries session_preload_libraries))
{
	my $node = plzig_node("preload_$setting", conf => "$setting = 'plzig'\n");
	$node->safe_psql('postgres',
		q{CREATE FUNCTION f(x int) RETURNS int STRICT LANGUAGE plzig AS $$ return x + 1; $$;});
	is($node->safe_psql('postgres', 'SELECT f(1)'), '2', "$setting: functions work");
	is($node->safe_psql('postgres', "SHOW plzig.max_memory"), '64MB',
		"$setting: settings defined before first use");
	my ($pm, $st) = postmaster_status($node);
	is($st->{Threads}, '1', "$setting: postmaster is single-threaded");
	# the runtime and its memory context only exist in backends that used it
	is($node->safe_psql('postgres',
			"SELECT count(*) FROM pg_backend_memory_contexts WHERE name = 'PL/Zig runtime'"),
		'0', "$setting: a fresh backend has no PL/Zig runtime yet");
	is($node->safe_psql('postgres',
			"SELECT f(1), (SELECT count(*) FROM pg_backend_memory_contexts WHERE name = 'PL/Zig runtime')"),
		'2|1', "$setting: the runtime is created on first use in the backend");
	# parallel workers, autovacuum etc. come from the same postmaster
	$node->safe_psql('postgres', 'CREATE TABLE p AS SELECT generate_series(1, 10000) g');
	is($node->safe_psql('postgres', q{
		ALTER FUNCTION f(int) PARALLEL SAFE;
		SET max_parallel_workers_per_gather = 2; SET parallel_setup_cost = 0;
		SET parallel_tuple_cost = 0; SET min_parallel_table_scan_size = 0;
		SELECT sum(f(g)) FROM p}), '50015000', "$setting: works in parallel workers");
	# a restart (the postmaster loads the library again) is fine too
	$node->restart;
	is($node->safe_psql('postgres', 'SELECT f(41)'), '42', "$setting: works after restart");
	ok(!$node->log_contains('PL/Zig runtime cannot be used in the postmaster'),
		"$setting: nothing tried to use the runtime in the postmaster");
	ok(!$node->log_contains('(PANIC|terminated by signal)'), "$setting: no crash in the log");
	$node->stop;
}

done_testing();
