# Helpers for the PL/Zig TAP tests (test/tap/t/*.pl).
#
# Environment (set by docker/test-in-container.sh):
#   PLZIG_TEST_ZIG          the real Zig 0.17.1 compiler
#   PLZIG_TEST_GATEZIG      the gated test compiler (test/gatezig.sh installed
#                           with REAL_ZIG/GATE_DIR filled in)
#   PLZIG_TEST_GATE_DIR     its gate directory (writable)
#   PLZIG_TEST_ZIG_CACHE    optional: a warm Zig cache to seed new clusters with
#
# Uses only what PostgreSQL::Test::Cluster offers on 14 (where it is an alias
# of PostgresNode, back-patched) up to 19.

package PlzigTest;

use strict;
use warnings;
use Exporter 'import';
use File::Path qw(make_path);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

our @EXPORT = qw(
  plzig_node use_gated_compiler use_real_compiler set_plzig_conf
  new_gate wait_gate open_gate gate_pid
  wait_until poll_state wait_for_lock_wait
  build_dirs compiler_processes children_of pid_alive
  wait_no_compiler_processes plzig_dir_listing unique_body copy_modes
);

my $gate_seq = 0;
my $body_seq = 0;

sub zig     { $ENV{PLZIG_TEST_ZIG}      or die "PLZIG_TEST_ZIG is not set" }
sub gatezig { $ENV{PLZIG_TEST_GATEZIG}  or die "PLZIG_TEST_GATEZIG is not set" }
sub gatedir { $ENV{PLZIG_TEST_GATE_DIR} or die "PLZIG_TEST_GATE_DIR is not set" }

sub zig_lib
{
	my $z = zig();
	$z =~ s{/[^/]+$}{};
	return "$z/lib";
}

# A started cluster with the extension created.  %opts: conf => extra
# postgresql.conf text, allows_streaming => as for init, no_extension => 1.
sub plzig_node
{
	my ($name, %opts) = @_;
	my $node = PostgreSQL::Test::Cluster->new($name);
	$node->init(
		$opts{allows_streaming} ? (allows_streaming => $opts{allows_streaming}) : ());
	$node->append_conf('postgresql.conf', "plzig.zig_path = '" . zig() . "'\n");
	$node->append_conf('postgresql.conf', $opts{conf}) if $opts{conf};
	seed_zig_cache($node);
	$node->start;
	$node->safe_psql('postgres', 'CREATE EXTENSION plzig')
	  unless $opts{no_extension};
	return $node;
}

# The first compilation in a cluster builds Zig's compiler_rt for wasm32;
# seed the Zig cache from a warm one when available (speed only).
sub seed_zig_cache
{
	my ($node) = @_;
	my $seed = $ENV{PLZIG_TEST_ZIG_CACHE};
	return unless $seed && -d $seed;
	my $dir = $node->data_dir . '/plzig';
	make_path($dir, { mode => 0700 });
	chmod 0700, $dir;
	system('cp', '-a', $seed, "$dir/pgsql_tmp.zig-cache") == 0
	  or die "could not seed the Zig cache";
	chmod 0700, "$dir/pgsql_tmp.zig-cache";
	return;
}

# Replace (or remove, with undef) plzig.* settings in postgresql.conf and reload.
sub set_plzig_conf
{
	my ($node, %settings) = @_;
	my $conf = $node->data_dir . '/postgresql.conf';
	open(my $fh, '<', $conf) or die "$conf: $!";
	my @lines = <$fh>;
	close $fh;
	for my $k (keys %settings)
	{
		@lines = grep { !/^\s*\Q$k\E\s*=/ } @lines;
		push @lines, "$k = '$settings{$k}'\n" if defined $settings{$k};
	}
	# reload is asynchronous: wait until new sessions run with the new file
	my $t0 = $node->safe_psql('postgres', 'SELECT pg_conf_load_time()');
	open($fh, '>', $conf) or die "$conf: $!";
	print $fh @lines;
	close $fh;
	$node->reload;
	$node->poll_query_until('postgres', "SELECT pg_conf_load_time() > '$t0'")
	  or die "configuration reload did not happen";
	return;
}

# The gated compiler (test/gatezig.sh): unconfined, so compiler_sandbox = off.
sub use_gated_compiler
{
	my ($node) = @_;
	set_plzig_conf(
		$node,
		'plzig.zig_path' => gatezig(),
		'plzig.zig_lib_dir' => zig_lib(),
		'plzig.compiler_sandbox' => 'off');
	return;
}

sub use_real_compiler
{
	my ($node) = @_;
	set_plzig_conf(
		$node,
		'plzig.zig_path' => zig(),
		'plzig.zig_lib_dir' => undef,
		'plzig.compiler_sandbox' => undef);
	return;
}

# A fresh gate name; a body containing "// plzig-test-gate:<name>" pauses
# in the gated compiler until open_gate(<name>).
sub new_gate
{
	$gate_seq++;
	return "g${$}_$gate_seq";
}

# A function body that is certainly not in the module cache yet.
sub unique_body
{
	my ($ret) = @_;
	$body_seq++;
	return "// unique $$ $body_seq " . time() . "\n    return $ret;";
}

# Poll until $cond->() is true (at most $secs seconds, default 60); returns
# the time it took, dies on timeout.
sub wait_until
{
	my ($what, $cond, $secs) = @_;
	$secs //= 60;
	my $start = time();
	while (!$cond->())
	{
		die "timed out waiting for $what" if time() - $start > $secs;
		usleep(10_000);
	}
	return time() - $start;
}

sub wait_gate
{
	my ($gate) = @_;
	return wait_until("compiler at gate $gate", sub { -e gatedir() . "/$gate.waiting" });
}

sub open_gate
{
	my ($gate) = @_;
	open(my $fh, '>', gatedir() . "/$gate") or die "open gate $gate: $!";
	close $fh;
	return;
}

# pid of the (wrapper) compiler process sitting at the gate
sub gate_pid
{
	my ($gate) = @_;
	my $f = gatedir() . "/$gate.pid";
	wait_until("pid file of gate $gate", sub { -s $f });
	open(my $fh, '<', $f) or die "$f: $!";
	my $pid = <$fh>;
	close $fh;
	chomp $pid;
	return $pid;
}

# Wait until backend $pid matches the condition on pg_stat_activity.
sub poll_state
{
	my ($node, $pid, $cond) = @_;
	return $node->poll_query_until('postgres',
		"SELECT EXISTS (SELECT FROM pg_stat_activity WHERE pid = $pid AND $cond)");
}

# Wait until backend $pid waits for the compile lock (wait event Extension)
sub wait_for_lock_wait
{
	my ($node, $pid) = @_;
	return poll_state($node, $pid,
		"state = 'active' AND wait_event_type = 'Extension'");
}

sub pid_alive
{
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/;
	return 0 unless -e "/proc/$pid";
	# a zombie is not alive for our purposes
	open(my $fh, '<', "/proc/$pid/stat") or return 0;
	my $stat = <$fh>;
	close $fh;
	return 0 unless defined $stat;
	return ($stat =~ /\)\s+Z\s/) ? 0 : 1;
}

# pids of the direct children of $pid (zombies included)
sub children_of
{
	my ($pid) = @_;
	my @kids;
	opendir(my $d, '/proc') or die "/proc: $!";
	for my $p (grep { /^\d+$/ } readdir $d)
	{
		open(my $fh, '<', "/proc/$p/stat") or next;
		my $stat = <$fh>;
		close $fh;
		next unless defined $stat && $stat =~ /\)\s+\S+\s+(\d+)/;
		push @kids, $p if $1 == $pid;
	}
	closedir $d;
	return @kids;
}

# Processes that are a compiler, validator or gated compiler (or its sleep).
sub compiler_processes
{
	my @found;
	my $z = zig();
	my $g = gatezig();
	opendir(my $d, '/proc') or die "/proc: $!";
	for my $p (grep { /^\d+$/ } readdir $d)
	{
		next if $p == $$;
		next unless pid_alive($p);    # zombies are not running
		open(my $fh, '<', "/proc/$p/cmdline") or next;
		my $cmd = do { local $/; <$fh> };
		close $fh;
		next unless defined $cmd && $cmd ne '';
		my @argv = split /\0/, $cmd;
		push @found, "$p: " . join(' ', @argv)
		  if $argv[0] eq $z
		  || $argv[0] eq $g
		  || (@argv > 1 && $argv[1] eq $g)
		  || $argv[0] =~ m{(^|/)plzig-validate$}
		  || (@argv == 2 && $argv[0] eq 'sleep' && $argv[1] eq '0.01');
	}
	closedir $d;
	return @found;
}

sub wait_no_compiler_processes
{
	my ($what) = @_;
	my $t = eval { wait_until("no compiler processes", sub { !compiler_processes() }, 30) };
	ok(defined $t, "$what: no compiler process left")
	  or diag("$@: " . join("\n", compiler_processes()));
	return;
}

# names of build directories in $PGDATA/plzig
sub build_dirs
{
	my ($node) = @_;
	my $dir = $node->data_dir . '/plzig';
	opendir(my $d, $dir) or return ();
	my @b = grep { /^pgsql_tmp\.build\./ } readdir $d;
	closedir $d;
	return @b;
}

# Give $to/$rel and everything below it the modes of $from/$rel (the test
# framework's RecursiveCopy does not keep modes, pg_basebackup does).
sub copy_modes
{
	my ($from, $to, $rel) = @_;
	my $mode = (lstat("$from/$rel"))[2] & 07777;
	chmod $mode, "$to/$rel" if -e "$to/$rel";
	if (-d "$from/$rel" && !-l "$from/$rel")
	{
		opendir(my $d, "$from/$rel") or die "$from/$rel: $!";
		my @e = grep { !/^\.\.?$/ } readdir $d;
		closedir $d;
		copy_modes($from, $to, "$rel/$_") for @e;
	}
	return;
}

# Contents of $PGDATA/plzig: top level entries, and anything in cache/ that
# is not a module.
sub plzig_dir_listing
{
	my ($node) = @_;
	my $dir = $node->data_dir . '/plzig';
	opendir(my $d, $dir) or return ();
	my @top = sort grep { !/^\.\.?$/ } readdir $d;
	closedir $d;
	my @odd;
	if (opendir(my $c, "$dir/cache"))
	{
		@odd = grep { !/^\.\.?$/ && !/^[0-9a-f]{64}\.wasm$/ } readdir $c;
		closedir $c;
	}
	return (\@top, \@odd);
}

1;
