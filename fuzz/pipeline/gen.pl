#!/usr/bin/perl
# fuzz/pipeline/gen.pl: generate PL/Zig function bodies for the "pipeline"
# fuzz target.  Each body is the body of fz_p(a int) RETURNS int STRICT.
#
#   gen.pl <seed> <count> <corpus dir> <out dir>
#
# Writes <out dir>/<n>.zig.  Half of the bodies are seeds from the corpus
# (fuzz/validator/corpus: the bodies of the regression suite plus tricky
# lexical cases) mutated at the token level; the other half are generated
# from fragments that stress the compiler and the limits: comptime loops
# and exponential comptime types, huge arrays and constant data,
# @compileLog floods, deep nesting, endless and deeply recursive runtime
# code, memory growth, top-level declarations after a closing brace,
# reflection on the SDK and the curated std, denied builtins/keywords and
# imports, odd bytes.  Deterministic for a given seed.
use strict;
use warnings;

my ($seed, $count, $corpus, $out) = @ARGV;
die "usage: gen.pl <seed> <count> <corpus dir> <out dir>\n" unless defined $out;
srand($seed);

opendir(my $dh, $corpus) or die "$corpus: $!";
my @seeds;
for my $f (sort grep { !/^\./ } readdir($dh)) {
    open(my $fh, '<:raw', "$corpus/$f") or next;
    local $/;
    my $s = <$fh>;
    close $fh;
    push @seeds, $s if length($s) < 8000;
}
closedir $dh;

my @tokens = (
    qw(const var fn pub return if else while for switch break continue comptime inline try catch orelse
       defer errdefer unreachable undefined null true false struct enum union error anytype anyerror
       noreturn void bool u8 i32 i64 usize u64 f64 type and or packed opaque test),
    qw(extern export asm callconv linksection threadlocal addrspace volatile),
    qw(@as @intCast @truncate @bitCast @import @embedFile @extern @export @ptrFromInt @intFromPtr @ptrCast
       @setEvalBranchQuota @wasmMemoryGrow @wasmMemorySize @compileError @compileLog @typeInfo @This @field
       @TypeOf @hasDecl @Struct @Int @splat @memcpy @memset @panic @trap @src @tagName @errorName @call),
    '(', ')', '{', '}', '[', ']', ';', ',', '.', '=', '==', '+', '+%', '-', '*', '/', '%', '<<', '>>',
    '&', '|', '^', '!', '?', ':', '=>', '..', '...', '.*', '.?', '|x|',
    '0', '1', '255', '0xffffffff', '1 << 62', '-1', '1e308', '"plzig"', '"std"', '"builtin"', '"x"',
    'a', 'plzig', 'std', 'plzig.allocator', 'plzig.spi', 'plzig.notice', 'std.mem', 'std.fmt', 'std.math',
    '\\\\ml', '// c', "\n",
);

my @fragments = (
    # comptime work
    'comptime { var i: u64 = 0; while (i < 1 << 40) : (i += 1) {} }',
    'const N = comptime blk: { var x: u64 = 1; for (0..900) |k| x +%= k; break :blk x; }; _ = N;',
    "}\nfn T(comptime n: usize) type { return if (n == 0) u8 else struct { a: T(n - 1), b: T(n - 1) }; }\nfn unused() void { _ = \@sizeOf(T(40));",
    "}\nfn F(comptime n: u64) u64 { return if (n < 2) n else F(n - 1) + F(n - 2); }\nfn unused() void { _ = comptime F(40);",
    'const S = comptime std.fmt.comptimePrint("{d}", .{1 << 60}); _ = S;',
    # big constant data / big types
    "}\nconst big: [1 << 26]u8 = \@splat(7);\nfn unused() u8 { return big[3];",
    "}\nconst big: [1 << 31]u8 = \@splat(1);\nfn unused() u8 { return big[3];",
    "}\nconst big: [1 << 20]u64 = \@splat(0xdeadbeef);\nfn unused() u64 { return big[\@intCast(\@as(u32, 0))];",
    'var arr: [1 << 22]u8 = undefined; arr[@intCast(@mod(a, 4))] = 1; return arr[1];',
    'const W = @Int(.unsigned, 65535); var w: W = 1; w <<= 100; _ = &w;',
    # compiler output floods
    'comptime { for (0..5000) |k| @compileLog(k); }',
    '@compileError("' . ('x' x 70000) . '");',
    '@compileError("\x1b[2J\nERROR:  forged\r\n");',
    # nesting
    ('(' x 3000) . '1' . (')' x 3000) . ';',
    ('{' x 2000) . ('}' x 2000),
    'return ' . join(' + ', ('a') x 5000) . ';',
    # runtime
    'while (true) {}',
    'var i: i32 = 0; while (true) : (i +%= 1) { if (i == -1) break; } return i;',
    "return f(a);\n}\nfn f(n: i32) i32 { return f(n +% 1) +% 1;",
    'const b = try plzig.allocator.alloc(u8, 1 << 30); return b[0];',
    'var l: std.ArrayList(u8) = .empty; while (true) try l.appendNTimes(plzig.allocator, 1, 1 << 20);',
    'const r = try plzig.spi.execute("SELECT repeat(\'x\', 100000000)", &.{}); return @intCast(r.rows);',
    'const r = try plzig.spi.execute("SELECT fz_p($1::int)", &.{"1"}); return @intCast(r.rows);',
    'plzig.raise("{s}", .{"boom"});',
    '@panic("p");',
    'return @intCast(@as(i64, a) * 1000000000000);',
    # structure
    "return 1;\n}\npub fn evil() void {",
    "return 1;\n}\ncomptime { \@compileError(\"top level\"); }\nfn z() void {",
    "return 1;\n}\nexport fn plzig_call() u32 { return 0; }\nfn z() void {",
    "return 1;\n}\npub const panic = \@import(\"std\").debug.FullPanic(f);\nfn f(m: []const u8, r: ?usize) noreturn { _ = m; _ = r; while (true) {} }\nfn z() void {",
    "}\n}\n}\n",
    '/* not a comment */',
    # reflection
    '_ = @typeInfo(@TypeOf(plzig)); return 1;',
    'inline for (@typeInfo(plzig).@"struct".decls) |d| { _ = d.name; } return 1;',
    '_ = @field(plzig, "host"); return 1;',
    '_ = @field(std, "fs"); return 1;',
    '_ = @FieldType(std.Io.File.Reader, "io"); return 1;',
    'const T = @typeInfo(@TypeOf(std.fmt.format)).@"fn".params[0].type.?; _ = T; return 1;',
    '_ = @hasDecl(std.mem, "std"); _ = @import("plzig").std; return 1;',
    '_ = @import("root"); return 1;',
    '_ = @This(); return @intCast(@src().line);',
    # odd bytes
    "return 1; // \xff\xfe invalid utf-8",
    "return 1;\x00",
    "\xef\xbb\xbfreturn 1;",
    "return 1;\r\n\r\n",
);

sub tokenize {
    my ($s) = @_;
    my @t;
    while ($s =~ /\G(\s+|\/\/[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|\\\\[^\n]*|@"(?:\\.|[^"\\\n])*"|@?[A-Za-z_][A-Za-z0-9_]*|0x[0-9a-fA-F_]+|[0-9][0-9_.eE]*|.)/gcs) {
        push @t, $1;
    }
    return @t;
}

sub pick { return $_[int(rand(@_))]; }

sub mutate {
    my ($s) = @_;
    my @t = tokenize($s);
    my $n = 1 + int(rand(6));
    for (1 .. $n) {
        my $op = int(rand(6));
        my $i = @t ? int(rand(@t)) : 0;
        if ($op == 0) { splice(@t, $i, 0, ' ', pick(@tokens), ' ') }
        elsif ($op == 1 && @t) { splice(@t, $i, 1) }
        elsif ($op == 2 && @t) { $t[$i] = pick(@tokens) }
        elsif ($op == 3 && @t) { my $j = int(rand(@t)); @t[$i, $j] = @t[$j, $i] }
        elsif ($op == 4) { splice(@t, $i, 0, "\n", pick(@fragments), "\n") }
        elsif (@t) { my $k = int(rand(20)); splice(@t, $i, 0, @t[$i .. ($i + $k < $#t ? $i + $k : $#t)]) }
    }
    return join('', @t);
}

sub generate {
    my @parts;
    my $n = 1 + int(rand(3));
    push @parts, pick(@fragments) for 1 .. $n;
    push @parts, 'return a;' if rand() < 0.7;
    return join("\n", @parts);
}

mkdir $out unless -d $out;
for my $k (1 .. $count) {
    my $body = (rand() < 0.5 && @seeds) ? mutate(pick(@seeds)) : generate();
    $body = mutate($body) if rand() < 0.2;
    open(my $fh, '>:raw', sprintf('%s/%05d.zig', $out, $k)) or die;
    print $fh $body;
    close $fh;
}
