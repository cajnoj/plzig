# The server environment changing under a running cluster: DROP EXTENSION
# (CASCADE) and re-create; the module cache directory deleted, made
# read-only, given group permissions or replaced by a file; plzig.zig_path
# removed while functions are cached.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";
use PlzigTest;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Path qw(remove_tree);

my $node = plzig_node('env');
my $cache = $node->data_dir . '/plzig/cache';
$node->safe_psql('postgres', q{CREATE FUNCTION f() RETURNS int LANGUAGE plzig AS $$ return 1; $$;});

# --- DROP EXTENSION
my ($rc, $out, $err) = $node->psql('postgres', 'DROP EXTENSION plzig');
like($err, qr/cannot drop extension plzig because other objects depend on it/,
	'DROP EXTENSION refused while functions exist');
my $s = $node->background_psql('postgres', on_error_stop => 0);
is($s->query_safe('SELECT f()'), '1', 'function cached in a long-lived session');
$node->safe_psql('postgres', 'DROP EXTENSION plzig CASCADE');
is($node->safe_psql('postgres', "SELECT count(*) FROM pg_language WHERE lanname = 'plzig'"),
	'0', 'language gone');
$s->query_until(qr/done/, "SELECT f();\n\\echo done\n");
like($s->{stderr}, qr/function f\(\) does not exist/, 'the cached function is gone for that session too');
$s->{stderr} = '';
$node->safe_psql('postgres', 'CREATE EXTENSION plzig');
$node->safe_psql('postgres', q{CREATE FUNCTION f() RETURNS int LANGUAGE plzig AS $$ return 2; $$;});
is($s->query_safe('SELECT f()'), '2', 'recreated extension and function work in the same session');
is($node->safe_psql('postgres', "SELECT has_language_privilege('public', 'plzig', 'USAGE')"),
	'f', 'recreated language has USAGE revoked from PUBLIC again');

my $new_fn = sub {
	my ($name) = @_;
	return $node->psql('postgres',
		"CREATE FUNCTION $name() RETURNS int LANGUAGE plzig AS \$\$ " . unique_body(5) . " \$\$");
};

# --- cache directory deleted: recreated on the next compilation
remove_tree($cache);
($rc, $out, $err) = $new_fn->('after_rm');
is($rc, 0, 'compiles after the cache directory was deleted') or diag($err);
ok(-d $cache, 'cache directory recreated');
is((stat($cache))[2] & 07777, 0700, 'with mode 0700');
is($s->query_safe('SELECT f()'), '2', 'loaded function unaffected');

# --- cache directory not writable: compiling fails cleanly, cached modules still load
chmod 0500, $cache;
($rc, $out, $err) = $new_fn->('readonly');
isnt($rc, 0, 'compiling into a read-only cache fails');
like($err, qr/could not create file "plzig\/cache\/[0-9a-f]{64}\.wasm\.tmp\.\d+": Permission denied/,
	'with a clear error and a data-directory-relative path');
unlike($err, qr/\Q${\ $node->data_dir }\E/, 'the data directory is not shown');
is($node->safe_psql('postgres', 'SELECT after_rm()'), '5', 'cached module loads from the read-only cache');
chmod 0700, $cache;
opendir(my $d, $cache);
is(scalar(grep { /\.tmp\./ } readdir $d), 0, 'no temporary file left');
closedir $d;

# --- group/other permissions on the cache directory: refused
chmod 0750, $cache;
($rc, $out, $err) = $node->psql('postgres', 'SELECT after_rm()');
like($err, qr/directory "plzig\/cache" has group or other permissions/, 'group permissions refused');
chmod 0700, $cache;

# --- cache directory replaced by a file
rename($cache, "$cache.moved") or die;
open(my $fh, '>', $cache) or die;
close $fh;
($rc, $out, $err) = $node->psql('postgres', 'SELECT after_rm()');
like($err, qr/"plzig\/cache" is not a directory \(or is a symbolic link\)/, 'a file instead of the directory is refused');
unlink $cache;
symlink("$cache.moved", $cache) or die;
($rc, $out, $err) = $node->psql('postgres', 'SELECT after_rm()');
like($err, qr/"plzig\/cache" is not a directory \(or is a symbolic link\)/, 'a symbolic link is refused');
unlink $cache;
rename("$cache.moved", $cache) or die;
is($node->safe_psql('postgres', 'SELECT after_rm()'), '5', 'works again once restored');

# --- the plzig directory itself unreadable or read-only
my $plzigdir = $node->data_dir . '/plzig';
chmod 0000, $plzigdir;
($rc, $out, $err) = $new_fn->('dir_unreadable');
like($err, qr/could not stat directory "plzig\/cache": Permission denied/, 'unreadable plzig directory reported');
chmod 0700, $plzigdir;
rename($cache, "$cache.moved") or die;
chmod 0500, $plzigdir;
($rc, $out, $err) = $new_fn->('dir_readonly');
like($err, qr/could not create directory "plzig\/cache": Permission denied/, 'cache directory cannot be created');
chmod 0700, $plzigdir;
rename("$cache.moved", $cache) or die;
is($node->safe_psql('postgres', 'SELECT after_rm()'), '5', 'works again once repaired');

# --- a "compiler" that is not an executable format: execve fails in the child
my $tmp = PostgreSQL::Test::Utils::tempdir;
mkdir "$tmp/notzig" or die;
chmod 0755, $tmp, "$tmp/notzig";
open($fh, '>', "$tmp/notzig/zig") or die;
print $fh "\x00\x01 not a program\n";
close $fh;
chmod 0755, "$tmp/notzig/zig";
set_plzig_conf($node, 'plzig.zig_path' => "$tmp/notzig/zig",
	'plzig.zig_lib_dir' => PlzigTest::zig_lib());
($rc, $out, $err) = $new_fn->('not_a_program');
like($err, qr/could not start helper program/, 'execve failure in the child reported');
like($err, qr/execve failed/, '... with the reason');
use_real_compiler($node);

# --- no address-space limit for the compiler (plzig.compile_memory_limit = 0)
($rc, $out, $err) = $node->psql('postgres', 'SET plzig.compile_memory_limit = 0; ' .
	"CREATE FUNCTION no_rlimit_as() RETURNS int LANGUAGE plzig AS \$\$ " . unique_body(8) . " \$\$");
is($rc, 0, 'compiles without an address-space limit') or diag($err);

# --- plzig.zig_path removed while functions are cached
my $s2 = $node->background_psql('postgres', on_error_stop => 0);
is($s2->query_safe('SELECT after_rm()'), '5', 'loaded in a session');
set_plzig_conf($node, 'plzig.zig_path' => undef);
is($s2->query_safe('SELECT after_rm()'), '5', 'loaded function keeps running');
is($node->safe_psql('postgres', 'SELECT after_rm()'), '5', 'cached module still loads in a new session');
($rc, $out, $err) = $new_fn->('no_compiler');
like($err, qr/no Zig compiler is configured/, 'new compilations fail with a clear error');
$node->safe_psql('postgres', 'SET check_function_bodies = off; ' .
	"CREATE FUNCTION lazy() RETURNS int LANGUAGE plzig AS \$\$ " . unique_body(6) . " \$\$");
($rc, $out, $err) = $node->psql('postgres', 'SELECT lazy()');
like($err, qr/no Zig compiler is configured/, 'lazy compilation fails the same way');
# a compiler path that disappears
set_plzig_conf($node, 'plzig.zig_path' => '/nonexistent/zig');
($rc, $out, $err) = $node->psql('postgres', 'SELECT lazy()');
like($err, qr/could not resolve plzig.zig_path: No such file or directory/, 'missing compiler binary reported');
use_real_compiler($node);
is($node->safe_psql('postgres', 'SELECT lazy()'), '6', 'compiles again once the setting is restored');
$s->quit;
$s2->quit;

my ($top, $odd) = plzig_dir_listing($node);
is(join(',', @$odd), '', 'nothing but modules in the cache');
is(join(',', grep { !/^(cache|compile\.lock|pgsql_tmp\.zig-cache)$/ } @$top), '',
	'only cache, lock file and Zig cache in $PGDATA/plzig');

$node->stop;
done_testing();
