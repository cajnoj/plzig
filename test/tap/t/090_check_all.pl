# plzig_check_all() against other sessions (cases pg_regress cannot set up):
# it waits for the compile lock like any compilation; functions dropped or
# replaced during the run (also while it waits for the function's lock) are
# skipped or checked as they are now; a cancel while it compiles or waits
# ends the run with the cancel (not recorded as a failure), leaving no child
# process, build directory or cache entry behind.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = plzig_node('check_all');
use_gated_compiler($node);

my $cached = sub {
	$node->safe_psql('postgres',
		"SELECT count(*) FROM pg_ls_dir('plzig/cache') d WHERE d LIKE '%.wasm'");
};
my $check_sql = "SELECT 'row: ' || function || ' ' || sqlstate FROM plzig_check_all() ORDER BY 1;";

# --- waits for the compile lock; meanwhile a function is dropped and another
# replaced by one that does not compile
{
	my ($b1, $b2, $b3) = (unique_body(1), unique_body(2), unique_body(3));
	$node->safe_psql('postgres', qq{
SET check_function_bodies = off;
CREATE FUNCTION a_first() RETURNS int LANGUAGE plzig AS \$\$ $b1 \$\$;
CREATE FUNCTION a_dropped() RETURNS int LANGUAGE plzig AS \$\$ $b2 \$\$;
CREATE FUNCTION a_replaced() RETURNS int LANGUAGE plzig AS \$\$ $b3 \$\$;
});
	my $gate = new_gate();
	my $s1 = $node->background_psql('postgres', on_error_stop => 0);
	my $s2 = $node->background_psql('postgres', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');

	$s1->query_until(qr/launched/,
		"\\echo launched\nCREATE FUNCTION holder() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate\n return 0; \$\$;\n\\echo s1-done\n");
	wait_gate($gate);
	my $before = $cached->();
	$s2->query_until(qr/launched/, "\\echo launched\n$check_sql\n\\echo s2-done\n");
	ok(wait_for_lock_wait($node, $pid2), 'plzig_check_all() waits for the compile lock');
	is($cached->(), $before, 'nothing compiled while the lock is held');
	$node->safe_psql('postgres', q{
SET check_function_bodies = off;
DROP FUNCTION a_dropped();
CREATE OR REPLACE FUNCTION a_replaced() RETURNS int LANGUAGE plzig AS $$ return "broken"; $$;
});
	open_gate($gate);
	$s1->query_until(qr/s1-done/, '');
	my $out = $s2->query_until(qr/s2-done/, '');
	is($s1->{stderr} . $s2->{stderr}, '', 'no errors');
	my @rows = $out =~ /^row: (.*)$/mg;
	is(join(',', @rows), 'a_replaced() 42P13',
		'the replaced function is checked as it is now, the dropped one skipped');
	is($cached->(), $before + 2, 'the lock holder and a_first were cached, the broken one not');
	is(join(',', build_dirs($node)), '', 'no build directory left');
	$s1->quit;
	$s2->quit;
	$node->safe_psql('postgres', 'DROP FUNCTION a_replaced()');
}

# --- a function whose DROP is in progress: plzig_check_all() waits for the
# function's lock, then skips it when the DROP commits
{
	my ($b1, $b2) = (unique_body(4), unique_body(5));
	$node->safe_psql('postgres', qq{
SET check_function_bodies = off;
CREATE FUNCTION b_first() RETURNS int LANGUAGE plzig AS \$\$ $b1 \$\$;
CREATE FUNCTION b_late() RETURNS int LANGUAGE plzig AS \$\$ $b2 \$\$;
});
	my $s2 = $node->background_psql('postgres', on_error_stop => 0);
	my $s3 = $node->background_psql('postgres', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');
	$s3->query_safe('BEGIN');
	$s3->query_safe('DROP FUNCTION b_late()');
	$s2->query_until(qr/launched/, "\\echo launched\n$check_sql\n\\echo s2-done\n");
	ok(poll_state($node, $pid2, "state = 'active' AND wait_event_type = 'Lock'"),
		'plzig_check_all() waits for the lock of the function being dropped');
	$s3->query_safe('COMMIT');
	my $out = $s2->query_until(qr/s2-done/, '');
	is($s2->{stderr}, '', 'no error');
	unlike($out, qr/^row: /m, 'nothing reported: b_late was skipped');
	$s2->quit;
	$s3->quit;
}

# --- cancel while plzig_check_all() compiles, and while it waits for the
# compile lock: the run ends with the cancel
{
	my $gate = new_gate();
	$node->safe_psql('postgres', qq{
SET check_function_bodies = off;
CREATE FUNCTION c_gated() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate
 return 1; \$\$;
});
	my $before = $cached->();
	my $s2 = $node->background_psql('postgres', on_error_stop => 0);
	my $pid2 = $s2->query_safe('SELECT pg_backend_pid()');
	$s2->query_until(qr/launched/, "\\echo launched\n$check_sql\n\\echo s2-done\n");
	wait_gate($gate);
	ok(scalar(children_of($pid2)) > 0, 'compiling: the backend has a child process');
	$node->safe_psql('postgres', "SELECT pg_cancel_backend($pid2)");
	my $out = $s2->query_until(qr/s2-done/, '');
	like($s2->{stderr}, qr/canceling statement due to user request/, 'cancelled while compiling');
	unlike($out, qr/^row: /m, 'the cancel is not reported as a failing function');
	$s2->{stderr} = '';
	is(scalar(children_of($pid2)), 0, 'no child process of the backend');
	wait_no_compiler_processes('cancel while compiling');
	is(join(',', build_dirs($node)), '', 'no build directory left');
	is($cached->(), $before, 'nothing cached');
	is($s2->query_safe('SELECT 1'), '1', 'the session still works');
	$node->safe_psql('postgres', 'DROP FUNCTION c_gated()');

	# waiting for the compile lock
	my $hgate = new_gate();
	my $s1 = $node->background_psql('postgres', on_error_stop => 0);
	my $b = unique_body(6);
	$node->safe_psql('postgres', qq{
SET check_function_bodies = off;
CREATE FUNCTION d_uncached() RETURNS int LANGUAGE plzig AS \$\$ $b \$\$;
});
	$s1->query_until(qr/launched/,
		"\\echo launched\nCREATE FUNCTION d_holder() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$hgate\n return 0; \$\$;\n\\echo s1-done\n");
	wait_gate($hgate);
	$s2->query_until(qr/launched/, "\\echo launched\n$check_sql\n\\echo s2-done\n");
	ok(wait_for_lock_wait($node, $pid2), 'waiting for the compile lock');
	$node->safe_psql('postgres', "SELECT pg_cancel_backend($pid2)");
	$out = $s2->query_until(qr/s2-done/, '');
	like($s2->{stderr}, qr/canceling statement due to user request/, 'cancelled while waiting');
	unlike($out, qr/^row: /m, 'nothing reported');
	open_gate($hgate);
	$s1->query_until(qr/s1-done/, '');
	is($s1->{stderr}, '', 'the lock holder finished undisturbed');
	$s1->quit;
	$s2->quit;
}

# --- a run without interference afterwards reports nothing and runs nothing
is($node->safe_psql('postgres', $check_sql), '', 'all remaining functions compile');
wait_no_compiler_processes('check_all tests');
is(join(',', build_dirs($node)), '', 'no build directory left');
ok(!$node->log_contains('terminated by signal'), 'no backend crashed');

use_real_compiler($node);
$node->stop;
done_testing();
