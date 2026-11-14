# statement_timeout, pg_cancel_backend and pg_terminate_backend while a
# backend is (a) in a guest loop, (b) in a cursor loop, (c) compiling and
# (d) waiting for the compile lock.  In each case the query is cancelled or
# the backend is gone promptly, no child process and no build directory is
# left behind, and the cluster stays healthy.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time);

my $node = plzig_node('interrupts');
$node->safe_psql('postgres', q{
CREATE FUNCTION spin(seed bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var x: u64 = @bitCast(seed);
    while (x != 0) x = x *% 6364136223846793005 +% 1442695040888963407;
    return 0;
$$;
CREATE FUNCTION cursor_loop() RETURNS bigint LANGUAGE plzig AS $$
    var c = try plzig.spi.open("SELECT g FROM generate_series(1, 1000000000) g", &.{});
    var n: i64 = 0;
    while (try c.next()) |row| n += try row.get(i32, 0);
    return n;
$$;
CREATE FUNCTION healthy() RETURNS text LANGUAGE plzig AS $$ return "healthy"; $$;
});
use_gated_compiler($node);

# How an interrupt is delivered to session $s (backend $pid).
my %interrupt = (
	statement_timeout => {
		prepare => sub { $_[0]->query_safe("SET statement_timeout = '1s'") },
		deliver => sub { },
		expect  => qr/canceling statement due to statement timeout/,
		fatal   => 0,
	},
	cancel => {
		prepare => sub { },
		deliver => sub { $node->safe_psql('postgres', "SELECT pg_cancel_backend($_[0])") },
		expect  => qr/canceling statement due to user request/,
		fatal   => 0,
	},
	terminate => {
		prepare => sub { },
		deliver => sub { $node->safe_psql('postgres', "SELECT pg_terminate_backend($_[0])") },
		expect  => qr/terminating connection due to administrator command/,
		fatal   => 1,
	},
);

# What the session is doing when interrupted.  setup returns the SQL to run
# in the session and a sub that waits until it is in the interesting state.
my %activity = (
	guest_loop => sub {
		my ($pid) = @_;
		return ('SELECT spin(1);',
			sub { poll_state($node, $pid, "state = 'active' AND query LIKE 'SELECT spin%'") });
	},
	cursor_loop => sub {
		my ($pid) = @_;
		return ('SELECT cursor_loop();',
			sub { poll_state($node, $pid, "state = 'active' AND query LIKE 'SELECT cursor_loop%'") });
	},
	compile => sub {
		my ($pid) = @_;
		my $gate = new_gate();
		return ("CREATE FUNCTION f_$gate() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate\n return 1; \$\$;",
			sub { wait_gate($gate); 1 });
	},
	lock_wait => sub {
		my ($pid, $holder) = @_;
		return ("CREATE FUNCTION w_$$" . "_" . int(rand(1e9)) . "() RETURNS int LANGUAGE plzig AS \$\$ " . unique_body(2) . " \$\$;",
			sub { wait_for_lock_wait($node, $pid) });
	},
);

for my $what (qw(guest_loop cursor_loop compile lock_wait))
{
	for my $how (qw(statement_timeout cancel terminate))
	{
		my $case = "$how during $what";
		my $I = $interrupt{$how};

		# for lock_wait, another session holds the compile lock (gated compile)
		my ($holder, $hgate);
		if ($what eq 'lock_wait')
		{
			$holder = $node->background_psql('postgres', on_error_stop => 0);
			$hgate = new_gate();
			$holder->query_until(qr/launched/,
				"\\echo launched\nCREATE FUNCTION h_$hgate() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$hgate\n return 7; \$\$;\n\\echo holder-done\n");
			wait_gate($hgate);
		}

		my $s = $node->background_psql('postgres', on_error_stop => 0);
		my $pid = $s->query_safe('SELECT pg_backend_pid()');
		$I->{prepare}->($s);
		my ($sql, $ready) = $activity{$what}->($pid, $holder);
		$s->query_until(qr/launched/, "\\echo launched\n$sql\n\\echo stmt-done\n");
		ok($ready->(), "$case: session reached the state");
		my @kids_before = children_of($pid);
		ok(@kids_before > 0, "$case: the backend has a child process")
		  if $what eq 'compile';

		my $t0 = time();
		$I->{deliver}->($pid);
		if ($I->{fatal})
		{
			my $gone = eval { wait_until("backend $pid to exit", sub { !pid_alive($pid) }, 30) };
			ok(defined $gone, "$case: backend exited");
			cmp_ok(time() - $t0, '<', 10, "$case: promptly");
			eval { $s->quit };
		}
		else
		{
			$s->query_until(qr/stmt-done/, '');
			cmp_ok(time() - $t0, '<', 10, "$case: promptly");
			like($s->{stderr}, $I->{expect}, "$case: expected error");
			$s->{stderr} = '';
			# the session is still usable
			is($s->query_safe('SELECT healthy()'), 'healthy', "$case: session still works");
			is(scalar(children_of($pid)), 0, "$case: no child process of the backend");
			$s->quit;
		}

		if ($holder)
		{
			open_gate($hgate);
			$holder->query_until(qr/holder-done/, '');
			is($holder->{stderr}, '', "$case: the lock holder finished undisturbed");
			$holder->quit;
		}

		wait_no_compiler_processes($case);
		is(join(',', build_dirs($node)), '', "$case: no build directory left");
		is($node->safe_psql('postgres', 'SELECT healthy()'), 'healthy', "$case: cluster healthy");
	}
}

# the terminated backends did not crash anything
ok(!$node->log_contains('terminated by signal'), 'no backend crashed');
ok(!$node->log_contains('server process .* was terminated'), 'no crash recovery');

use_real_compiler($node);
$node->stop;
done_testing();
