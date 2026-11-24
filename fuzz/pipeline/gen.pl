#!/usr/bin/perl
# fuzz/pipeline/gen.pl: generate PL/Zig functions for the "pipeline" fuzz
# target.
#
#   gen.pl <seed> <count> <corpus dir> <out dir>
#
# Writes, for n = 00001 .. <count>, <out dir>/<n>.zig (the body) and
# <out dir>/<n>.meta (how fuzz/pipeline/run.sh uses it):
#   family=<name>
#   create=<statement head the body follows>    ("DO" for a DO block)
#   call=<SQL that runs it>                     (empty for a DO block)
# Deterministic for a given seed.
#
# The functions come from families with fixed signatures (run.sh creates the
# types and tables they use): int, text, opt (non-strict), the native types
# (date, numeric, jsonb, timestamptz, interval, uuid, bytea, float8 as
# arguments, four result types), OUT parameters, a composite argument and
# result, SETOF/TABLE, a row trigger, a procedure with transaction control,
# DO blocks, and a function that compiles two others into itself (//#use:
# a strict and a non-strict helper, created by run.sh).  The mix:
#   ~50%  valid:      a body assembled from statements that type-check in
#                     the family (SPI, cursors, prepared statements, std,
#                     native-type operations, logging), some of which fail
#                     at run time on purpose (raise, panics, returned errors,
#                     SQL errors, memory, result values the host must refuse:
#                     out-of-range dates, invalid JSON, typmod and NOT NULL
#                     violations, invalid encoding), and a return statement
#   ~15%  near-valid: a valid body with one token-level mutation
#   ~35%  invalid:    bodies of fz_p(a int) RETURNS int STRICT: seeds from
#                     the corpus (fuzz/validator/corpus: the regression
#                     suite's bodies plus lexical corner cases) mutated at
#                     the token level, and stress fragments for the compiler
#                     and the limits (comptime loops and exponential types,
#                     huge constant data, @compileLog floods, deep nesting,
#                     endless and deeply recursive code, memory growth,
#                     top-level declarations after a closing brace,
#                     reflection on the SDK and std, denied constructs, odd
#                     bytes)
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

sub pick { return $_[int(rand(@_))]; }

# ---------------------------------------------------------------------
# invalid bodies (int family): token mutations and stress fragments
# ---------------------------------------------------------------------
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
    "return 1;\n}\nexport fn plzig_init() u64 { return 1 << 40; }\nfn z() void {",
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
    # *+ (possessive) on the string-literal groups: a very long literal
    # otherwise exceeds Perl's regex recursion limit ("Complex regular
    # subexpression recursion limit exceeded").  No backtracking is wanted
    # here anyway -- the closing quote is never in the character class -- so
    # possessive is equivalent and recursion-free.
    while ($s =~ /\G(\s+|\/\/[^\n]*|"(?:\\.|[^"\\\n])*+"|'(?:\\.|[^'\\\n])*+'|\\\\[^\n]*|@"(?:\\.|[^"\\\n])*+"|@?[A-Za-z_][A-Za-z0-9_]*|0x[0-9a-fA-F_]+|[0-9][0-9_.eE]*|.)/gcs) {
        push @t, $1;
    }
    return @t;
}

# $small: only one operation, and no fragment insertion (near-valid bodies)
sub mutate {
    my ($s, $small) = @_;
    my @t = tokenize($s);
    my $n = $small ? 1 : 1 + int(rand(6));
    for (1 .. $n) {
        my $op = int(rand($small ? 4 : 6));
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

sub stress {
    my @parts;
    my $n = 1 + int(rand(3));
    push @parts, pick(@fragments) for 1 .. $n;
    push @parts, 'return a;' if rand() < 0.7;
    return join("\n", @parts);
}

# ---------------------------------------------------------------------
# valid bodies, by family
# ---------------------------------------------------------------------
# Placeholders in the templates: N a small number (0..9), M a larger one
# (0..2000), W a word.  Statements are blocks, so their names never clash
# and every local is used.
my @words = ('x', 'abc', 'héllo', 'ümlaut€', 'tab\\there', 'quote\\"d', '');

sub fill {
    my ($s) = @_;
    $s =~ s/\bN\b/int(rand(10))/ge;
    $s =~ s/\bM\b/int(rand(2001))/ge;
    $s =~ s/\bW\b/pick(@words)/ge;
    return $s;
}

# valid in any function, procedure or DO block
my @common = (
    '{ var vs: u64 = 0; for (0..M) |k| vs +%= k * k; plzig.debug("sum {d}", .{vs}); }',
    '{ const r = try plzig.spi.execute("SELECT generate_series(1, M)", &.{}); plzig.debug("rows {d}", .{r.rows}); }',
    '{ var vl: std.ArrayList(u8) = .empty; try vl.appendNTimes(plzig.allocator, \'x\', M); plzig.debug("len {d}", .{vl.items.len}); }',
    '{ const vp = try std.fmt.allocPrint(plzig.allocator, "{d}-{s}", .{ M, "W" }); plzig.notice("{s}", .{vp}); }',
    '{ var vc = try plzig.spi.open("SELECT g FROM generate_series(1, M) g", &.{}); var vt: i64 = 0; while (try vc.next()) |row| vt += try row.get(i32, 0); plzig.debug("total {d}", .{vt}); }',
    '{ const st = try plzig.spi.prepare("SELECT $1::int * 2", &.{.int4}); const r = try st.execute(.{@as(i32, M)}); plzig.debug("{?s}", .{try r.get(0, 0)}); }',
    '{ var vm = std.AutoHashMap(u32, u32).init(plzig.allocator); for (0..M) |k| try vm.put(@intCast(k % 17), @intCast(k)); plzig.debug("{d}", .{vm.count()}); }',
    '{ var arr = [_]i32{ 5, 3, 9, 1, M }; std.mem.sort(i32, &arr, {}, std.sort.asc(i32)); plzig.debug("{any}", .{arr}); }',
    '{ const r = try plzig.spi.execute("SELECT $1::text || \'W\'", &.{"M"}); plzig.debug("{?s}", .{try r.get(0, 0)}); }',
    '{ const vx = try plzig.Numeric.parse("M.25"); const vy = try vx.mul(try plzig.Numeric.parse("-3")); plzig.debug("{f}", .{vy}); }',
    '{ const vd = try plzig.Date.fromYmd(1900 + M, 2, 28); const vf = try vd.ymd(); plzig.debug("{d} {d}", .{ vd.days, vf.year }); }',
    '{ const r = try plzig.spi.execute("SELECT now()::text, $1::int", &.{"N"}); plzig.debug("{d}", .{r.rows}); }',
    '{ var vbuf: [64]u8 = undefined; const ve = std.base64.standard.Encoder.encode(&vbuf, "W"); plzig.debug("{s}", .{ve}); }',
    '{ const vup = try plzig.allocator.alloc(u8, 3); _ = std.ascii.upperString(vup, "abc"); plzig.debug("{s}", .{vup}); }',
    '{ const r = try plzig.spi.execute("SELECT g, g::text, g * 0.5 FROM generate_series(1, N) g", &.{}); var vk: u64 = 0; while (vk < r.rows) : (vk += 1) { const row = try r.row(vk); plzig.debug("{d} {?s}", .{ try row.get(i32, 0), try row.get(?[]const u8, 1) }); } }',
    '{ const vj = plzig.jsonText("{\"k\": [M, true, null]}"); plzig.debug("{s}", .{vj.text}); }',
    '{ const vu = try plzig.Uuid.parse("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1N"); var vb: [36]u8 = undefined; plzig.debug("{s}", .{vu.format(&vb)}); }',
    '{ var it = std.mem.tokenizeScalar(u8, "a b  c W", \' \'); var vn: usize = 0; while (it.next()) |_| vn += 1; plzig.debug("{d}", .{vn}); }',
    '{ const vq = std.math.sqrt(@as(f64, M)); plzig.debug("{d}", .{vq}); }',
    '{ plzig.warning("warn W {d}", .{M}); }',
);

# fail at run time (on purpose); rv is runtime-known, so no "unreachable code"
my @failing = (
    '{ var rv: i32 = N; _ = &rv; if (rv < 3) plzig.raise("raised {d}", .{rv}); }',
    '{ var rv: i32 = N; _ = &rv; if (rv < 3) return error.Fuzzed; }',
    '{ var rv: i32 = N; _ = &rv; const z: i32 = @divTrunc(100, rv); plzig.debug("{d}", .{z}); }',
    '{ var rv: u8 = 250; rv += N; plzig.debug("{d}", .{rv}); }',
    '{ var rv: usize = N; _ = &rv; const arr = [_]u8{ 1, 2, 3 }; plzig.debug("{d}", .{arr[rv]}); }',
    '{ var rv: ?i32 = null; if (N > 5) rv = 1; plzig.debug("{d}", .{rv.?}); }',
    '{ _ = try plzig.spi.execute("SELECT 1 / (N - N)", &.{}); }',
    '{ _ = try plzig.spi.execute("SELECT * FROM fz_missing", &.{}); }',
    '{ _ = try plzig.spi.execute("SELECT \'x\'::int", &.{}); }',
    '{ const vb = try plzig.allocator.alloc(u8, 1 << 27); plzig.debug("{d}", .{vb.len}); }',
    '{ var vl: std.ArrayList(u64) = .empty; while (vl.items.len < 1 << 26) try vl.append(plzig.allocator, vl.items.len); }',
    '{ var vc = try plzig.spi.open("SELECT g FROM generate_series(1, 1000000000) g", &.{}); while (try vc.next()) |_| {} }',
    '{ const r = try plzig.spi.execute("SELECT pg_sleep(10)", &.{}); _ = r; }',
    '{ _ = try plzig.spi.execute("DROP TABLE fz_nope", &.{}); }',
    '{ _ = try plzig.Numeric.parse("1e"); }',
    '{ _ = try (try plzig.Numeric.parse("1")).div(plzig.Numeric.zero); }',
    '{ plzig.raiseError(.{ .sqlstate = "22023", .message = "W", .detail = "d", .hint = "h" }); }',
    '{ plzig.raiseError(.{ .sqlstate = "XX000", .message = "refused class" }); }',
);

my %fam = (
    int => {
        weight => 3,
        create => 'CREATE OR REPLACE FUNCTION fz_p(a int) RETURNS int STRICT LANGUAGE plzig AS',
        call => 'SELECT fz_p(3);',
        stmts => [
            '{ const x = a *% M; plzig.debug("{d}", .{x}); }',
            '{ var acc: i64 = 0; var k: i32 = 0; while (k < a) : (k += 1) acc += k; plzig.debug("{d}", .{acc}); }',
            '{ const r = try plzig.spi.execute("SELECT $1::int + N", &.{try std.fmt.allocPrint(plzig.allocator, "{d}", .{a})}); plzig.debug("{?s}", .{try r.get(0, 0)}); }',
        ],
        ret => ['return a +% M;', 'return @intCast(@mod(a, N + 1));', 'return a;', 'return -a;',
                'return @intCast(@as(i64, a) * M);', 'return std.math.maxInt(i32);'],
    },
    text => {
        weight => 2,
        create => 'CREATE OR REPLACE FUNCTION fz_text(t text, n int) RETURNS text STRICT LANGUAGE plzig AS',
        call => "SELECT fz_text('héllo wörld', 4);",
        stmts => [
            '{ const up = try plzig.allocator.alloc(u8, t.len); _ = std.ascii.upperString(up, t); plzig.debug("{s}", .{up}); }',
            '{ var it = std.unicode.Utf8View.initUnchecked(t).iterator(); var k: usize = 0; while (it.nextCodepoint()) |_| k += 1; plzig.debug("{d}", .{k}); }',
            '{ plzig.debug("{s} {d}", .{ t, n }); }',
        ],
        ret => ['return t;', 'return try std.fmt.allocPrint(plzig.allocator, "{s}:{d}", .{ t, n });',
                'return t[0..@min(t.len, @as(usize, @intCast(@max(n, 0))))];',
                'return t[@min(t.len, N)..];', 'return "W";', 'return try std.mem.concat(plzig.allocator, u8, &.{ t, "W", t });',
                'return try std.mem.replaceOwned(u8, plzig.allocator, t, "l", "LL");'],
    },
    opt => {
        weight => 1,
        create => 'CREATE OR REPLACE FUNCTION fz_opt(a int, t text) RETURNS text LANGUAGE plzig AS',
        call => "SELECT fz_opt(NULL, 'x'), fz_opt(5, NULL), fz_opt(NULL, NULL);",
        stmts => [
            '{ if (a) |v| plzig.debug("{d}", .{v}); }',
            '{ const s = t orelse "none"; plzig.debug("{s}", .{s}); }',
        ],
        ret => ['return t;', 'return if (a) |v| try std.fmt.allocPrint(plzig.allocator, "{d}", .{v}) else null;',
                'const s = t orelse return null; return s;', 'return t.?;', 'return null;',
                'return try std.fmt.allocPrint(plzig.allocator, "{?d} {?s}", .{ a, t });'],
    },
);

my $natargs = '(d date, n numeric, j jsonb, ts timestamptz, iv interval, u uuid, b bytea, f float8)';
my $natcall = "('2024-02-29', 12.5, '{\"a\": [1, 2, {\"b\": null}], \"c\": \"x\", \"n\": 1e-3}', '2024-01-01 12:00+00', "
            . "'1 mon 2 days 03:04:05', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '\\xdeadbeef', 2.5)";
my @natstmts = (
    '{ const y = try d.ymd(); plzig.debug("{d}-{d}-{d}", .{ y.year, y.month, y.day }); }',
    '{ const r = try j.root(); plzig.debug("{s}", .{@tagName(r)}); }',
    '{ const r = try j.root(); if (r == .object) { var it = r.object.iterator(); while (try it.next()) |e| plzig.debug("{s}={s}", .{ e.key, (try e.value.toJsonText()).text }); } }',
    '{ plzig.debug("{d} {d} {d}", .{ iv.usecs, iv.days, iv.months }); }',
    '{ var buf: [36]u8 = undefined; plzig.debug("{s} {any}", .{ u.format(&buf), b }); }',
    '{ plzig.debug("{d} {f}", .{ f * M, n }); }',
    '{ const t = try n.toText(); plzig.debug("{s}", .{t}); }',
    '{ const f2 = try ts.fields("UTC"); plzig.debug("{d}", .{f2.year}); }',
    '{ const loc = ts.toLocal("Europe/Prague"); plzig.debug("{d}", .{loc.usecs}); }',
);
$fam{nat_date} = { weight => 1, create => "CREATE OR REPLACE FUNCTION fz_nat_date$natargs RETURNS date STRICT LANGUAGE plzig AS",
    call => "SELECT fz_nat_date$natcall;", stmts => \@natstmts,
    ret => ['return d;', 'return try plzig.Date.fromYmd(2024, 1, N + 1);', 'return .{ .days = d.days +% M };',
            'return .{ .days = d.days +% 2000000000 };', 'return plzig.Date.infinity;', 'return ts.toLocal(null).date();'] };
$fam{nat_num} = { weight => 1, create => "CREATE OR REPLACE FUNCTION fz_nat_num$natargs RETURNS numeric STRICT LANGUAGE plzig AS",
    call => "SELECT fz_nat_num$natcall;", stmts => \@natstmts,
    ret => ['return n;', 'return try n.add(try plzig.Numeric.parse("1.5"));', 'return try n.mul(n);',
            'return try n.div(try plzig.Numeric.parse("N"));', 'return try plzig.Numeric.parse("NaN");',
            'return try (try (try j.root()).object.get("n")).?.number.numeric();'] };
$fam{nat_json} = { weight => 1, create => "CREATE OR REPLACE FUNCTION fz_nat_json$natargs RETURNS jsonb STRICT LANGUAGE plzig AS",
    call => "SELECT fz_nat_json$natcall;", stmts => \@natstmts,
    ret => ['return try j.toJsonText();', 'return plzig.jsonText("{\"k\": M}");', 'return plzig.jsonText("{bad");',
            'return plzig.jsonText(try std.fmt.allocPrint(plzig.allocator, "[{d}, {d}]", .{ M, N }));', 'return plzig.jsonText("\"\\\\u0000\"");'] };
$fam{nat_ts} = { weight => 1, create => "CREATE OR REPLACE FUNCTION fz_nat_ts$natargs RETURNS timestamptz STRICT LANGUAGE plzig AS",
    call => "SELECT fz_nat_ts$natcall;", stmts => \@natstmts,
    ret => ['return ts;', 'return .{ .usecs = ts.usecs +% M };', 'return plzig.TimestampTz.infinity;',
            'return .{ .usecs = 9223371331200000000 };', 'return plzig.TimestampTz.fromLocal(ts.toLocal("UTC"), "Asia/Tokyo");'] };
$fam{row} = { weight => 1,
    create => 'CREATE OR REPLACE FUNCTION fz_row(a int, t text, OUT q int, OUT s varchar(5), OUT d date) STRICT LANGUAGE plzig AS',
    call => "SELECT * FROM fz_row(7, 'xyz');",
    stmts => ['{ plzig.debug("{d} {s}", .{ a, t }); }'],
    ret => ['return .{ .q = a, .s = t, .d = null };', 'return .{ .q = a *% M, .s = "W", .d = .{ .days = M } };',
            'return null;', 'return .{ .q = null, .s = null, .d = null };',
            'return .{ .q = a, .s = "toolong", .d = null };'] };
$fam{cmp} = { weight => 1,
    create => 'CREATE OR REPLACE FUNCTION fz_cmp(p fz_pair) RETURNS fz_pair LANGUAGE plzig AS',
    call => "SELECT * FROM fz_cmp(ROW(3, 'abc')::fz_pair); SELECT fz_cmp(NULL);",
    stmts => ['{ if (p) |v| plzig.debug("{?d} {?s}", .{ v.a, v.b }); }'],
    ret => ['const v = p orelse return null; return .{ .a = v.a, .b = v.b };', 'return p;',
            'const v = p orelse return null; return .{ .a = (v.a orelse 0) +% M, .b = "W" };',
            'return .{ .a = null, .b = null };'] };
$fam{srf} = { weight => 1,
    create => 'CREATE OR REPLACE FUNCTION fz_srf(n int) RETURNS TABLE (i int, s text) STRICT LANGUAGE plzig AS',
    call => 'SELECT count(*) FROM fz_srf(5); SELECT * FROM fz_srf(2);',
    stmts => ['{ var k: i32 = 0; while (k < n) : (k += 1) returnNext(.{ .i = k, .s = "W" }); }',
              '{ returnNext(null); }',
              '{ var c = try plzig.spi.open("SELECT g, g::text FROM generate_series(1, M) g", &.{}); while (try c.next()) |r| returnNext(.{ .i = try r.get(?i32, 0), .s = try r.get(?[]const u8, 1) }); }'],
    ret => [''] };
$fam{srfs} = { weight => 1,
    create => 'CREATE OR REPLACE FUNCTION fz_srfs(n int) RETURNS SETOF bigint STRICT LANGUAGE plzig AS',
    call => 'SELECT sum(x) FROM fz_srfs(10) x;',
    stmts => ['{ var k: i64 = 0; while (k < n) : (k += 1) returnNext(k * M); }', '{ returnNext(null); }',
              '{ for (0..M) |k| returnNext(@intCast(k)); }'],
    ret => [''] };
$fam{tg} = { weight => 2,
    create => 'CREATE OR REPLACE FUNCTION fz_tg() RETURNS trigger LANGUAGE plzig AS',
    call => "INSERT INTO fz_t VALUES (1, 'apple', 3, 1.5, 'ab'); UPDATE fz_t SET qty = qty + 1; SELECT count(*) FROM fz_t; DELETE FROM fz_t;",
    stmts => ['{ plzig.debug("{s} {s} {s}", .{ tg.name(), @tagName(tg.when()), @tagName(tg.op()) }); }',
              '{ const Row = struct { id: ?i32, name: ?[]const u8, qty: ?i32 }; if (try tg.new(Row)) |r| plzig.debug("{?d} {?s}", .{ r.id, r.name }); }',
              '{ const r = try plzig.spi.execute("SELECT count(*) FROM fz_t", &.{}); plzig.debug("{d}", .{r.rows}); }',
              '{ if (tg.newRow()) |r| plzig.debug("{d}", .{r.len()}); }'],
    ret => ['return .new;', 'return .skip;', 'return try tg.modify(.{ .name = "W" });', 'return try tg.modify(.{ .qty = @as(i32, M) });',
            'return try tg.modify(.{ .qty = null });', 'return try tg.modify(.{ .code = "toolong" });',
            'return try tg.modify(.{ .nope = @as(i32, 1) });', 'return .old;',
            'const Row = struct { id: ?i32, name: ?[]const u8 }; const r = (try tg.new(Row)) orelse return .skip; return try tg.modify(.{ .name = r.name });',
            'return try tg.modify(.{ .price = try plzig.Numeric.parse("123456789.5") });'] };
$fam{proc} = { weight => 2,
    create => 'CREATE OR REPLACE PROCEDURE fz_proc(INOUT n int) LANGUAGE plzig AS',
    call => 'CALL fz_proc(1);',
    stmts => ['{ _ = try plzig.spi.execute("INSERT INTO fz_log VALUES (M)", &.{}); }', '{ plzig.commit(); }', '{ plzig.rollback(); }',
              '{ var c = try plzig.spi.open("SELECT g FROM generate_series(1, 5) g", &.{}); _ = try c.next(); plzig.commit(); _ = c.next() catch |e| plzig.debug("{s}", .{@errorName(e)}); }',
              '{ const st = try plzig.spi.prepare("INSERT INTO fz_log VALUES ($1)", &.{.int4}); for (0..N) |k| { _ = try st.execute(.{@as(i32, @intCast(k))}); plzig.commit(); } }'],
    ret => ['return .{ .n = (n orelse 0) + M };', 'return .{ .n = null };'] };
$fam{use} = { weight => 2,
    create => 'CREATE OR REPLACE FUNCTION fz_use(a int) RETURNS int STRICT LANGUAGE plzig AS',
    call => 'SELECT fz_use(3);',
    prefix => "//#use public.fz_h_int(integer) as hi\n//#use public.fz_h_text(text) as ht",
    stmts => ['{ const v = (try hi.call(a)).?; plzig.debug("{d}", .{v}); }',
              '{ const t = try ht.call("W"); plzig.debug("{?s}", .{t}); }',
              '{ const t = try ht.call(null); plzig.debug("{?s}", .{t}); }',
              '{ var k: i32 = 0; var vs: i32 = 0; while (k < M) : (k += 1) vs +%= (try hi.call(k)).?; plzig.debug("{d}", .{vs}); }',
              '{ _ = hi.call(-N) catch |e| plzig.debug("{s}", .{@errorName(e)}); }',
              '{ const v = try hi.call(-N); plzig.debug("{?d}", .{v}); }'],
    ret => ['return (try hi.call(a)).?;', 'return try hi.call(a -% M);', 'return @intCast((try ht.call("W")).?.len);',
            'return (try hi.call(std.math.maxInt(i32))).?;'] };
$fam{do} = { weight => 3, create => 'DO', call => '',
    stmts => ['{ plzig.commit(); }', '{ _ = try plzig.spi.execute("INSERT INTO fz_log VALUES (M)", &.{}); plzig.rollback(); }'],
    ret => [''] };

my @famnames = sort keys %fam;
my @weighted = map { ($_) x $fam{$_}{weight} } @famnames;

sub valid_body {
    my ($f) = @_;
    my $F = $fam{$f};
    my @parts;
    my $n = int(rand(4));
    for (1 .. $n) {
        my $r = rand();
        my $s = $r < 0.4 ? pick(@{$F->{stmts}}) : $r < 0.85 ? pick(@common) : pick(@failing);
        push @parts, fill($s);
    }
    # set-returning families need at least one row-producing statement sometimes
    push @parts, fill($F->{stmts}[0]) if ($f eq 'srf' || $f eq 'srfs') && rand() < 0.7;
    my $ret = fill(pick(@{$F->{ret}}));
    push @parts, $ret if $ret ne '';
    # directives (//#use) come first
    unshift @parts, $F->{prefix} if $F->{prefix};
    return join("\n", @parts);
}

mkdir $out unless -d $out;
for my $k (1 .. $count) {
    my $r = rand();
    my ($f, $body, $kind);
    if ($r < 0.5) {
        $f = pick(@weighted);
        $body = valid_body($f);
        $kind = 'valid';
    } elsif ($r < 0.65) {
        $f = pick(@weighted);
        $body = mutate(valid_body($f), 1);
        $kind = 'near';
    } else {
        $f = 'int';
        $body = (rand() < 0.5 && @seeds) ? mutate(pick(@seeds)) : stress();
        $body = mutate($body) if rand() < 0.2;
        $kind = 'invalid';
    }
    my $base = sprintf('%s/%05d', $out, $k);
    open(my $fh, '>:raw', "$base.zig") or die;
    print $fh $body;
    close $fh;
    open($fh, '>:raw', "$base.meta") or die;
    print $fh "family=$f\nkind=$kind\ncreate=$fam{$f}{create}\ncall=$fam{$f}{call}\n";
    close $fh;
}
