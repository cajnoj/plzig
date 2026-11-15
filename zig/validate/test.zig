//! Unit tests for plzig-validate (zig/validate/main.zig).
//!
//!   make check-zig            (or: zig test zig/validate/test.zig)
//!
//! The accept/reject cases for builtins and keywords are generated from the
//! validator's own tables and from the compiler's builtin and keyword lists
//! (std.zig.BuiltinFn, std.zig.Token), so they cannot drift from either.

const std = @import("std");
const v = @import("main.zig");
const linux = std.os.linux;
const testing = std.testing;
const gpa = testing.allocator;

const BuiltinFn = std.zig.BuiltinFn;
const Token = std.zig.Token;

/// Run the validator on `src`; returns the number of problems.
fn check(src: []const u8) !usize {
    const z = try gpa.allocSentinel(u8, src.len, 0);
    defer gpa.free(z);
    @memcpy(z, src);
    v.reset();
    return v.validate(z);
}

fn expectAccepted(src: []const u8) !void {
    const n = try check(src);
    if (n != 0) {
        std.debug.print("expected accept, got {d} problem(s) for:\n{s}\n---\n{s}\n", .{ n, src, v.diagnostics() });
        return error.TestUnexpectedResult;
    }
}

fn expectRejected(src: []const u8, needle: []const u8) !void {
    const n = try check(src);
    if (n == 0 or std.mem.indexOf(u8, v.diagnostics(), needle) == null) {
        std.debug.print("expected reject with \"{s}\", got {d} problem(s) for:\n{s}\n---\n{s}\n", .{ needle, n, src, v.diagnostics() });
        return error.TestUnexpectedResult;
    }
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn isDeniedKeyword(tag: Token.Tag) bool {
    for (v.denied_keywords) |k| if (k == tag) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Classification of the compiler's builtins

test "every builtin of this Zig is explicitly allowed or denied, and no table entry is stale" {
    for (BuiltinFn.list.keys()) |name| {
        const a = inList(&v.allowed_builtins, name);
        const d = inList(&v.denied_builtins, name);
        if (a == d) {
            std.debug.print("builtin {s}: allowed={} denied={} (must be exactly one)\n", .{ name, a, d });
            return error.TestUnexpectedResult;
        }
    }
    for (v.allowed_builtins ++ v.denied_builtins) |name| {
        if (BuiltinFn.list.get(name) == null) {
            std.debug.print("{s} is in a validator table but is not a builtin of this Zig\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(BuiltinFn.list.keys().len, v.allowed_builtins.len + v.denied_builtins.len);
}

test "every denied keyword is a keyword of this Zig" {
    for (v.denied_keywords) |k| {
        var found = false;
        for (Token.keywords.values()) |t| found = found or t == k;
        try testing.expect(found);
    }
}

// ---------------------------------------------------------------------------
// Builtins

test "allowed builtins: accepted when used, an unknown near miss is rejected" {
    for (v.allowed_builtins) |name| {
        const ok = if (std.mem.eql(u8, name, "@import"))
            try gpa.dupe(u8, "const p = @import(\"plzig\");\n")
        else
            try std.fmt.allocPrint(gpa, "const x = {s}(1, 2);\n", .{name});
        defer gpa.free(ok);
        try expectAccepted(ok);

        // the allowlist matches exactly: an unknown builtin is denied
        const bad = try std.fmt.allocPrint(gpa, "const x = {s}Zq(1);\n", .{name});
        defer gpa.free(bad);
        try expectRejected(bad, "builtin not allowed in PL/Zig");
    }
}

test "denied builtins: rejected when used, accepted inside literals, comments and @\"\" identifiers" {
    for (v.denied_builtins) |name| {
        const bad = try std.fmt.allocPrint(gpa, "const x = {s}(1);\n", .{name});
        defer gpa.free(bad);
        try expectRejected(bad, "builtin not allowed in PL/Zig");
        // the diagnostic names the builtin
        try testing.expect(std.mem.indexOf(u8, v.diagnostics(), name) != null);

        const bare = name[1..]; // without '@'
        const ok = try std.fmt.allocPrint(gpa,
            \\const a = "{s}(1)";
            \\// {s}("x")
            \\/// {s}
            \\//! {s}
            \\const b =
            \\    \\{s}("/etc/passwd")
            \\;
            \\const @"{s}" = 1;
            \\const c = @"{s}";
            \\
        , .{ name, name, name, name, name, name, bare });
        defer gpa.free(ok);
        try expectAccepted(ok);
    }
}

test "builtins are case sensitive and not split by whitespace" {
    try expectRejected("const x = @EmbedFile(\"a\");", "builtin not allowed");
    try expectRejected("const x = @ embedFile(\"a\");", "invalid token");
    try expectRejected("const x = @\"embedFile\"(\"a\");\n@embedFile(\"b\");", "builtin not allowed");
}

// ---------------------------------------------------------------------------
// Keywords

test "denied keywords: rejected as tokens, accepted in literals, comments and as @\"\" identifiers" {
    for (Token.keywords.keys(), Token.keywords.values()) |word, tag| {
        if (!isDeniedKeyword(tag)) continue;
        const bad = try std.fmt.allocPrint(gpa, "const x = 1;\n{s} fn f() void {{}}\n", .{word});
        defer gpa.free(bad);
        try expectRejected(bad, "keyword not allowed in PL/Zig");
        try testing.expect(std.mem.indexOf(u8, v.diagnostics(), word) != null);
        // reported at the right place (line 2, column 1)
        try testing.expect(std.mem.startsWith(u8, v.diagnostics(), "2:1: "));

        const ok = try std.fmt.allocPrint(gpa,
            \\const a = "{s}";
            \\// {s}
            \\const b =
            \\    \\{s}
            \\;
            \\const @"{s}" = 1;
            \\const c = @"{s}" + 1;
            \\
        , .{ word, word, word, word, word });
        defer gpa.free(ok);
        try expectAccepted(ok);
    }
}

test "allowed keywords are accepted" {
    var n_allowed: usize = 0;
    for (Token.keywords.keys(), Token.keywords.values()) |word, tag| {
        if (isDeniedKeyword(tag)) continue;
        n_allowed += 1;
        const ok = try std.fmt.allocPrint(gpa, "{s}\n", .{word});
        defer gpa.free(ok);
        try expectAccepted(ok);
    }
    try testing.expectEqual(Token.keywords.keys().len, n_allowed + v.denied_keywords.len);
}

test "a mix reports exactly the denied constructs" {
    const src =
        \\const plzig = @import("plzig"); const std = plzig.std; pub fn call() anyerror!void {
        \\    var x: i32 = @intCast(1);
        \\    asm volatile ("nop");
        \\    const y = @embedFile("x");
        \\    _ = .{ x, y, "extern export asm" };
        \\}
    ;
    try testing.expectEqual(@as(usize, 3), try check(src));
    const d = v.diagnostics();
    try testing.expect(std.mem.indexOf(u8, d, "3:5: keyword not allowed in PL/Zig 'asm'") != null);
    try testing.expect(std.mem.indexOf(u8, d, "3:9: keyword not allowed in PL/Zig 'volatile'") != null);
    try testing.expect(std.mem.indexOf(u8, d, "4:15: builtin not allowed in PL/Zig '@embedFile'") != null);
}

// ---------------------------------------------------------------------------
// @import

test "@import forms" {
    try expectAccepted("const p = @import(\"plzig\");");
    try expectAccepted("const p = @import ( \"plzig\" ) ;");
    try expectAccepted("const p = @import(\n// a comment\n\"plzig\"\n);");

    const msg = "only @import(\"plzig\") is allowed";
    try expectRejected("const s = @import(\"std\");", msg);
    try expectRejected("const s = @import(\"builtin\");", msg);
    try expectRejected("const s = @import(\"root\");", msg);
    try expectRejected("const s = @import(\"user\");", msg);
    try expectRejected("const s = @import(\"plzig.zig\");", msg);
    try expectRejected("const s = @import(\"../sdk/plzig.zig\");", msg);
    try expectRejected("const s = @import(\"PLZIG\");", msg);
    try expectRejected("const s = @import(\"plzig \");", msg);
    try expectRejected("const s = @import(\"pl\\x7aig\");", msg);
    try expectRejected("const s = @import(\"pl\\u{7a}ig\");", msg);
    try expectRejected("const s = @import(\n    \\\\plzig\n);", msg);
    try expectRejected("const s = @import(\"plzig\", \"x\");", msg);
    try expectRejected("const s = @import(\"plzig\",);", msg);
    try expectRejected("const s = @import(name);", msg);
    try expectRejected("const s = @import(\"pl\" ++ \"zig\");", msg);
    try expectRejected("const s = @import;", msg);
    try expectRejected("const s = @import(///doc\n\"plzig\");", msg);
    try expectRejected("const s = @import(", msg);
    // the validator does not stop at the first problem
    try testing.expectEqual(@as(usize, 2), try check("const a = @import(\"std\");\nconst b = @import(\"builtin\");"));
    // without --allow-import, the names of used functions are refused too
    try expectRejected("const t = @import(\"plzig.use.t\");", msg);
}

/// validateWithImports (the --allow-import names of the functions a file uses)
fn checkWith(src: []const u8, extra: []const []const u8) !usize {
    const z = try gpa.allocSentinel(u8, src.len, 0);
    defer gpa.free(z);
    @memcpy(z, src);
    v.reset();
    return v.validateWithImports(z, extra);
}

test "@import of the functions a file uses (--allow-import)" {
    const extra = [_][]const u8{ "plzig.use.t", "plzig.use.enc" };
    try testing.expectEqual(@as(usize, 0), try checkWith("const t = @import(\"plzig.use.t\").call;", &extra));
    try testing.expectEqual(@as(usize, 0), try checkWith("const p = @import(\"plzig\"); const e = @import ( \"plzig.use.enc\" ) .call;", &extra));
    // exactly the given names, byte for byte: no prefix, suffix, case or escape tricks
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"plzig.use.u\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"plzig.use.\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"plzig.use.tt\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"PLZIG.USE.T\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"plzig.use.\\x74\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\n    \\\\plzig.use.t\n);", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"std\");", &extra));
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @import(\"\");", &[_][]const u8{""}));
    // and nothing else changes: builtins and keywords are still checked
    try testing.expectEqual(@as(usize, 1), try checkWith("const t = @embedFile(\"x\");", &extra));
}

// ---------------------------------------------------------------------------
// Lexing corner cases

test "empty and trivial input" {
    try expectAccepted("");
    try expectAccepted("\n");
    try expectAccepted("// only a comment");
    try expectAccepted("// only a comment\n");
}

test "NUL bytes are rejected wherever they are" {
    try expectRejected("const a = 1;\x00", "NUL byte in source");
    try expectRejected("const a = \"\x00\";", "NUL byte in source");
    try expectRejected("// \x00", "NUL byte in source");
    try expectRejected("\x00", "NUL byte in source");
}

test "invalid bytes outside literals are rejected" {
    try expectRejected("const a = 1; \xff", "invalid token");
    try expectRejected("const a = 1; \x80", "invalid token");
    try expectRejected("const a = 1; \x01", "invalid token");
    try expectRejected("const a = 1; \x1b[31m", "invalid token");
    try expectRejected("const a = 1; $", "invalid token");
    try expectRejected("const a = 1; `", "invalid token");
    // control characters in comments and string literals
    try expectRejected("// \x07 bell", "invalid token");
    try expectRejected("const a = \"\x07\";", "invalid token");
    try expectRejected("const a = \"\x7f\";", "invalid token");
}

test "UTF-8 in comments and literals is fine" {
    try expectAccepted("// grüße, 日本語\nconst a = \"héllo\";\nconst b = '\u{e9}';\n");
}

test "carriage returns" {
    // CRLF line endings are accepted
    try expectAccepted("const a = 1;\r\n// comment\r\nconst b = 2;\r\n");
    // a lone CR is not (the compiler rejects it too)
    try expectRejected("// comment\r more", "invalid token");
    try expectRejected("const a =\n    \\\\x\r", "invalid token");
}

test "byte order mark" {
    // a leading UTF-8 BOM is skipped by the tokenizer
    try expectAccepted("\xef\xbb\xbfconst a = 1;");
    // ... but not elsewhere
    try expectRejected("const a = 1;\xef\xbb\xbf", "invalid token");
    // and it does not hide what follows
    try expectRejected("\xef\xbb\xbf@embedFile(\"x\")", "builtin not allowed");
}

test "unterminated literals" {
    try expectRejected("const a = \"abc", "invalid token");
    try expectRejected("const a = \"abc\nconst b = 1;", "invalid token");
    try expectRejected("const a = 'x", "invalid token");
    try expectRejected("const a = @\"abc", "invalid token");
    // an unterminated string does not swallow a later denied builtin silently:
    // it is rejected either way
    try testing.expect(try check("const a = \"abc\n@embedFile(\"x\");") > 0);
}

test "denied names cannot hide in escapes or identifiers" {
    // a string with escapes is a single literal token
    try expectAccepted("const a = \"\\\"@embedFile(\\\"x\\\")\";");
    // @"..." with escapes is an identifier, never a builtin or keyword
    try expectAccepted("const @\"\\x65xtern\" = 1;");
    try expectAccepted("const @\"@embedFile\" = 1;");
    // char literal containing a quote does not end a string early
    try expectRejected("const a = '\"'; @embedFile(\"x\");", "builtin not allowed");
}

fn repeated(prefix: []const u8, c: u8, n: usize, suffix: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, prefix.len + n + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    @memset(out[prefix.len..][0..n], c);
    @memcpy(out[prefix.len + n ..], suffix);
    return out;
}

test "very long tokens" {
    const n = 1 << 20;
    // a 1 MB identifier is fine
    const ident = try repeated("const a", 'a', n, " = 1;\n");
    defer gpa.free(ident);
    try expectAccepted(ident);

    // a 1 MB unknown builtin name is rejected, and the diagnostic is bounded
    const b = try repeated("const x = @", 'z', n, "(1);\n");
    defer gpa.free(b);
    try expectRejected(b, "builtin not allowed");
    try testing.expect(v.diagnostics().len < 200);

    // a 1 MB string literal hiding a denied name is fine
    const s = try repeated("const x = \"", 'q', n, "@embedFile(\\\"x\\\")\";\n");
    defer gpa.free(s);
    try expectAccepted(s);

    // as is a 1 MB comment
    const c = try repeated("// ", 'q', n, " @embedFile(\"x\") asm\n");
    defer gpa.free(c);
    try expectAccepted(c);
}

test "diagnostics are bounded: at most 20 reported" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (0..100) |_| try list.appendSlice(gpa, "asm\n");
    try testing.expectEqual(@as(usize, 100), try check(list.items));
    var lines: usize = 0;
    for (v.diagnostics()) |c| lines += @intFromBool(c == '\n');
    try testing.expectEqual(@as(usize, 20), lines);
}

// ---------------------------------------------------------------------------
// Reading the input: size limit

fn memfdWith(len: usize, fill: u8) !i32 {
    const rc = linux.memfd_create("plzig-validate-test", 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const fd: i32 = @intCast(rc);
    const chunk = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(chunk);
    @memset(chunk, fill);
    var left = len;
    while (left > 0) {
        const k = @min(left, chunk.len);
        const w = linux.write(fd, chunk.ptr, k);
        if (linux.errno(w) != .SUCCESS) return error.WriteFailed;
        left -= w;
    }
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    return fd;
}

test "input size limit: exactly max_source is read, one byte more is too large" {
    const buf = try gpa.alloc(u8, v.max_source + 1);
    defer gpa.free(buf);

    const fd_ok = try memfdWith(v.max_source, ' ');
    defer _ = linux.close(fd_ok);
    try testing.expectEqual(@as(usize, v.max_source), try v.readSource(fd_ok, buf));

    const fd_big = try memfdWith(v.max_source + 1, ' ');
    defer _ = linux.close(fd_big);
    try testing.expectError(error.TooLarge, v.readSource(fd_big, buf));

    const fd_empty = try memfdWith(0, ' ');
    defer _ = linux.close(fd_empty);
    try testing.expectEqual(@as(usize, 0), try v.readSource(fd_empty, buf));

    // a closed descriptor is a read error, not an empty input
    try testing.expectError(error.ReadFailed, v.readSource(-1, buf));
}

test "input at the size limit is validated as a whole" {
    // max_source bytes: spaces, then a denied builtin in the very last bytes
    const src = try gpa.alloc(u8, v.max_source);
    defer gpa.free(src);
    @memset(src, ' ');
    const tail = "@embedFile(\"x\")";
    @memcpy(src[src.len - tail.len ..], tail);
    try expectRejected(src, "builtin not allowed");
}
