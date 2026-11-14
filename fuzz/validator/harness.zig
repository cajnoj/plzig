//! libFuzzer target for plzig-validate (fuzz/README.md, target "validator").
//!
//! Built with `zig build-obj -ffuzz` (SanitizerCoverage inline 8-bit counters
//! and PC tables, which libFuzzer understands) and linked by clang with
//! -fsanitize=fuzzer; see fuzz/build.sh.  It links the production validator
//! (zig/validate/main.zig, module "validate") unchanged.
//!
//! For every input, raw and wrapped the way the backend wraps a function
//! body (src/plzig_source.c):
//!   1. the validator must not crash (Zig ReleaseSafe: any safety-check
//!      failure aborts, which libFuzzer reports);
//!   2. differential property: if the validator accepts the source, then
//!        a. an independent, hand-written lexer (`Naive` below, which shares
//!           no code with std.zig.Tokenizer) finds no denied builtin, no
//!           denied keyword and no @import other than @import("plzig"), and
//!        b. if the real parser (std.zig.Ast, what the compiler parses)
//!           accepts it, no builtin_call node names a builtin outside the
//!           allowlist, every @import argument is the literal "plzig", and
//!           no token of the parser's token list is a denied keyword.
//!      Any violation panics (a finding).
const std = @import("std");
const v = @import("validate");

const prelude = "const plzig = @import(\"plzig\"); const std = plzig.std; pub fn call() anyerror!void {\n";
const epilogue = "\n}\n";

/// fuzz/validator/selftest.c: PLZIG_FUZZ_SELFTEST=1 ignores the validator's
/// verdict, to show that the differential checks fire (fuzz/build.sh)
extern var plzig_fuzz_selftest: c_int;

var src_buf: [v.max_source + 1]u8 = undefined;
var heap_buf: [256 * 1024 * 1024]u8 = undefined;

const denied_keyword_names = [_][]const u8{
    "extern", "export", "asm", "linksection", "callconv", "threadlocal", "addrspace", "volatile",
};

fn isAllowed(name: []const u8) bool {
    for (v.allowed_builtins) |b| if (std.mem.eql(u8, b, name)) return true;
    return false;
}

fn isDeniedKeyword(name: []const u8) bool {
    for (denied_keyword_names) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn finding(comptime what: []const u8, detail: []const u8) noreturn {
    std.debug.panic("validator differential finding: " ++ what ++ ": '{s}'", .{detail[0..@min(detail.len, 80)]});
}

/// An independent lexer for the parts of Zig's lexical grammar that matter
/// here: line comments, string/char literals, multiline string lines,
/// quoted identifiers, number literals, identifiers and builtins.  It only
/// has to be right for inputs the validator accepted (which contain no
/// invalid tokens), so it can be simple.
const Naive = struct {
    s: []const u8,
    i: usize = 0,

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }
    fn isIdent(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn skipQuoted(self: *Naive, q: u8) void {
        // at the opening quote
        self.i += 1;
        while (self.i < self.s.len and self.s[self.i] != '\n') : (self.i += 1) {
            if (self.s[self.i] == '\\') {
                self.i += 1;
                continue;
            }
            if (self.s[self.i] == q) {
                self.i += 1;
                return;
            }
        }
    }

    fn skipToEol(self: *Naive) void {
        while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
    }

    /// skip whitespace and line comments
    fn skipTrivia(self: *Naive) void {
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.i += 1;
            } else if (c == '/' and self.i + 1 < self.s.len and self.s[self.i + 1] == '/') {
                self.skipToEol();
            } else break;
        }
    }

    fn check(self: *Naive) void {
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == '/' and self.i + 1 < self.s.len and self.s[self.i + 1] == '/') {
                self.skipToEol();
            } else if (c == '\\' and self.i + 1 < self.s.len and self.s[self.i + 1] == '\\') {
                self.skipToEol();
            } else if (c == '"' or c == '\'') {
                self.skipQuoted(c);
            } else if (c == '@') {
                if (self.i + 1 < self.s.len and self.s[self.i + 1] == '"') {
                    self.i += 1;
                    self.skipQuoted('"');
                    continue;
                }
                const start = self.i;
                self.i += 1;
                while (self.i < self.s.len and isIdent(self.s[self.i])) self.i += 1;
                const name = self.s[start..self.i];
                if (!isAllowed(name)) finding("denied builtin", name);
                if (std.mem.eql(u8, name, "@import")) {
                    self.skipTrivia();
                    if (self.i >= self.s.len or self.s[self.i] != '(') finding("@import without (", name);
                    self.i += 1;
                    self.skipTrivia();
                    if (!std.mem.startsWith(u8, self.s[self.i..], "\"plzig\"")) finding("@import of something else", self.s[self.i..]);
                    self.i += "\"plzig\"".len;
                    self.skipTrivia();
                    if (self.i >= self.s.len or self.s[self.i] != ')') finding("@import without )", self.s[self.i..]);
                    self.i += 1;
                }
            } else if (std.ascii.isDigit(c)) {
                // number literal: digits, letters, '_', '.', and a sign after an exponent
                self.i += 1;
                while (self.i < self.s.len) {
                    const d = self.s[self.i];
                    if (isIdent(d) or d == '.') {
                        self.i += 1;
                    } else if ((d == '+' or d == '-') and
                        (self.s[self.i - 1] | 0x20 == 'e' or self.s[self.i - 1] | 0x20 == 'p'))
                    {
                        self.i += 1;
                    } else break;
                }
            } else if (isIdentStart(c)) {
                const start = self.i;
                while (self.i < self.s.len and isIdent(self.s[self.i])) self.i += 1;
                if (isDeniedKeyword(self.s[start..self.i])) finding("denied keyword", self.s[start..self.i]);
            } else {
                self.i += 1;
            }
        }
    }
};

fn parserCheck(gpa: std.mem.Allocator, src: [:0]const u8) void {
    var tree = std.zig.Ast.parse(gpa, src, .{}) catch return; // out of memory: skip
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return; // the compiler rejects it as well

    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |t, ti| {
        for (v.denied_keywords) |k| {
            if (t == k) finding("denied keyword in the parser's tokens", tree.tokenSlice(@intCast(ti)));
        }
    }
    var n: u32 = 0;
    while (n < tree.nodes.len) : (n += 1) {
        const node: std.zig.Ast.Node.Index = @enumFromInt(n);
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        if (!isAllowed(name)) finding("denied builtin call in the AST", name);
        if (std.mem.eql(u8, name, "@import")) {
            var b: [2]std.zig.Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&b, node) orelse finding("@import without parameters", name);
            if (params.len != 1) finding("@import with a parameter count other than 1", name);
            const p = params[0];
            if (tree.nodeTag(p) != .string_literal) finding("@import of a non-literal", tree.tokenSlice(tree.nodeMainToken(p)));
            const lit = tree.tokenSlice(tree.nodeMainToken(p));
            if (!std.mem.eql(u8, lit, "\"plzig\"")) finding("@import of another module", lit);
        }
    }
}

fn checkOne(src: [:0]const u8) void {
    v.reset();
    if (v.validate(src) != 0 and plzig_fuzz_selftest == 0) return;
    var naive: Naive = .{ .s = src };
    naive.check();
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    parserCheck(fba.allocator(), src);
}

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size + prelude.len + epilogue.len > v.max_source) return -1;
    // raw
    @memcpy(src_buf[0..size], data[0..size]);
    src_buf[size] = 0;
    checkOne(src_buf[0..size :0]);
    // wrapped like a DO block body (src/plzig_source.c)
    @memcpy(src_buf[0..prelude.len], prelude);
    @memcpy(src_buf[prelude.len..][0..size], data[0..size]);
    @memcpy(src_buf[prelude.len + size ..][0..epilogue.len], epilogue);
    const n = prelude.len + size + epilogue.len;
    src_buf[n] = 0;
    checkOne(src_buf[0..n :0]);
    return 0;
}
