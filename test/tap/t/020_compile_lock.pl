# The compile lock between sessions (cases isolationtester cannot observe,
# because a session waiting for the lock is not waiting for a heavyweight
# lock): two different functions compiled concurrently (one waits, both
# finish), plzig_cache_clear() while another session compiles, and the same
# function created concurrently in two databases (compiled once).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = plzig_node('compile_lock');
use_gated_compiler($node);
$node->safe_psql('postgres', 'SELECT plzig_cache_clear()');

my $cached = sub {
	$node->safe_psql('postgres',
		"SELECT count(*) FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm'");
};

# --- two different functions: the second compilation waits for the first
{
	my $gate = new_gate();
	my $s1 = $node->background_psql('postgres', on_error_stop => 0);
	my $s2 = $node->background_psql('postgres', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');

	$s1->query_until(qr/launched/,
		"\\echo launched\nCREATE FUNCTION a1() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate\n return 1; \$\$;\n\\echo s1-done\n");
	wait_gate($gate);
	my $before = $cached->();
	$s2->query_until(qr/launched/,
		"\\echo launched\nCREATE FUNCTION b1() RETURNS int LANGUAGE plzig AS \$\$ return 2; \$\$;\n\\echo s2-done\n");
	ok(wait_for_lock_wait($node, $pid2), 'second compilation waits for the compile lock');
	is($cached->(), $before, 'nothing was compiled while the lock was held');
	is(scalar(build_dirs($node)), 1, 'one build directory while waiting');

	open_gate($gate);
	$s1->query_until(qr/s1-done/, '');
	$s2->query_until(qr/s2-done/, '');
	is($s1->{stderr} . $s2->{stderr}, '', 'both compilations succeeded');
	is($s1->query_safe('SELECT a1() + b1()'), '3', 'both functions work');
	is($cached->(), $before + 2, 'two modules cached');
	is(join(',', build_dirs($node)), '', 'no build directory left');
	$s1->quit;
	$s2->quit;
}

# --- plzig_cache_clear() while another session compiles: it waits for the
# lock, then removes everything, including the module just compiled
{
	my $gate = new_gate();
	my $s1 = $node->background_psql('postgres', on_error_stop => 0);
	my $s2 = $node->background_psql('postgres', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');

	$s1->query_until(qr/launched/,
		"\\echo launched\nCREATE FUNCTION a2() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate\n return 10; \$\$;\n\\echo s1-done\n");
	wait_gate($gate);
	$s2->query_until(qr/launched/, "\\echo launched\nSELECT plzig_cache_clear();\n\\echo s2-done\n");
	ok(wait_for_lock_wait($node, $pid2), 'plzig_cache_clear() waits for the compile lock');
	open_gate($gate);
	$s1->query_until(qr/s1-done/, '');
	my $out = $s2->query_until(qr/s2-done/, '');
	is($s1->{stderr} . $s2->{stderr}, '', 'no errors');
	like($out, qr/^\d+$/m, 'plzig_cache_clear() returned a count');
	my ($n) = $out =~ /^(\d+)$/m;
	cmp_ok($n, '>=', 3, 'it removed the module compiled meanwhile too');
	is($cached->(), '0', 'cache empty');
	# the function is simply compiled again on next use
	is($s2->query_safe('SELECT a2()'), '10', 'function recompiled on next use');
	$s1->quit;
	$s2->quit;
}

# --- the same function body in two databases at the same time: one
# compilation, the other session finds the module in the cache
{
	$node->safe_psql('postgres', 'CREATE DATABASE other');
	$node->safe_psql('other', 'CREATE EXTENSION plzig');
	my $gate = new_gate();
	my $body = "\$\$ // plzig-test-gate:$gate\n return 42; \$\$";
	my $s1 = $node->background_psql('postgres', on_error_stop => 0);
	my $s2 = $node->background_psql('other', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');
	my $before = $cached->();
	$s1->query_until(qr/launched/, "\\echo launched\nCREATE FUNCTION same() RETURNS int LANGUAGE plzig AS $body;\n\\echo s1-done\n");
	wait_gate($gate);
	$s2->query_until(qr/launched/, "\\echo launched\nCREATE FUNCTION same() RETURNS int LANGUAGE plzig AS $body;\n\\echo s2-done\n");
	ok(wait_for_lock_wait($node, $pid2), 'same body in another database waits for the lock');
	open_gate($gate);
	$s1->query_until(qr/s1-done/, '');
	$s2->query_until(qr/s2-done/, '');
	is($s1->{stderr} . $s2->{stderr}, '', 'both created');
	is($cached->(), $before + 1, 'compiled once, one module');
	is($s2->query_safe('SELECT same()'), '42', 'works in the other database');
	$s1->quit;
	$s2->quit;
}

wait_no_compiler_processes('compile lock tests');
use_real_compiler($node);
$node->stop;
done_testing();
