# Crash recovery: immediate shutdown, and kill -9 of a backend in the middle
# of a compilation and of a call.  The cluster recovers, cached modules keep
# working, a build directory left behind is swept by the next compilation,
# and no compiler process survives.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# TAP clusters default to restart_after_crash = off
my $node = plzig_node('crash', conf => "restart_after_crash = on\n");
$node->safe_psql('postgres', q{
CREATE FUNCTION answer() RETURNS int LANGUAGE plzig AS $$ return 42; $$;
CREATE FUNCTION spin(seed bigint) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var x: u64 = @bitCast(seed);
    while (x != 0) x = x *% 6364136223846793005 +% 1442695040888963407;
    return 0;
$$;
});
is($node->safe_psql('postgres', 'SELECT answer()'), '42', 'function works');

# --- immediate shutdown (no shutdown checkpoint), then crash recovery
$node->stop('immediate');
$node->start;
is($node->safe_psql('postgres', 'SELECT answer()'), '42', 'works after immediate shutdown');
$node->safe_psql('postgres',
	"CREATE FUNCTION after_restart() RETURNS int LANGUAGE plzig AS \$\$ " . unique_body(7) . " \$\$");
is($node->safe_psql('postgres', 'SELECT after_restart()'), '7', 'compiles after immediate shutdown');

# --- kill -9 of a backend in the middle of a compilation
use_gated_compiler($node);
my $gate = new_gate();
my $s = $node->background_psql('postgres', on_error_stop => 0);
my $pid = $s->query_safe('SELECT pg_backend_pid()');
$s->query_until(qr/launched/,
	"\\echo launched\nCREATE FUNCTION crashing() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate\n return 1; \$\$;\n");
wait_gate($gate);
my $compiler = gate_pid($gate);
ok(pid_alive($compiler), 'compiler running');
my @stale = build_dirs($node);
is(scalar(@stale), 1, 'one build directory during the compilation');
kill 'KILL', $pid;
eval { $s->quit };
# the postmaster notices, resets every backend and recovers
$node->poll_query_until('postgres', 'SELECT true') or die 'cluster did not recover';
ok($node->log_contains("\\(PID $pid\\) was terminated by signal 9"),
	'postmaster ran crash recovery');
my $t = eval { wait_until('the compiler to die', sub { !pid_alive($compiler) }, 30) };
ok(defined $t, 'the compiler died with its backend (parent-death signal)');
wait_no_compiler_processes('kill -9 during compilation');
is(join(',', build_dirs($node)), join(',', @stale), 'the dead backend\'s build directory is still there');
is($node->safe_psql('postgres', "SELECT count(*) FROM pg_proc WHERE proname = 'crashing'"),
	'0', 'the function was not created');

# the next compilation (in any backend) sweeps it
my $gate2 = new_gate();
open_gate($gate2);
$node->safe_psql('postgres',
	"CREATE FUNCTION sweeper() RETURNS int LANGUAGE plzig AS \$\$ // plzig-test-gate:$gate2\n return 9; \$\$");
is(join(',', build_dirs($node)), '', 'stale build directory swept by the next compilation');
is($node->safe_psql('postgres', 'SELECT sweeper() + answer()'), '51', 'functions work after recovery');

# --- kill -9 of a backend in the middle of a call (guest loop)
$s = $node->background_psql('postgres', on_error_stop => 0);
$pid = $s->query_safe('SELECT pg_backend_pid()');
$s->query_until(qr/launched/, "\\echo launched\nSELECT spin(1);\n");
poll_state($node, $pid, "state = 'active' AND query LIKE 'SELECT spin%'");
kill 'KILL', $pid;
eval { $s->quit };
$node->poll_query_until('postgres', 'SELECT true') or die 'cluster did not recover';
ok($node->log_contains("\\(PID $pid\\) was terminated by signal 9"),
	'crash recovery after kill -9 during a call');
is($node->safe_psql('postgres', 'SELECT spin(0), answer()'), '0|42', 'functions work after recovery');

# the module cache survived both crashes intact (no temp files left)
my ($top, $odd) = plzig_dir_listing($node);
is(join(',', @$odd), '', 'no temporary files in the module cache');
is(join(',', grep { !/^(cache|compile\.lock|pgsql_tmp\.zig-cache)$/ } @$top), '',
	'only cache, lock file and Zig cache in $PGDATA/plzig');

use_real_compiler($node);
$node->stop;
done_testing();
