//! plzig-validate: lexical policy check for PL/Zig source (defence in depth).
//!
//! Reads one Zig source file on stdin, tokenizes it with the compiler's own
//! tokenizer (std.zig.Tokenizer) and rejects:
//!   * any builtin not on the allowlist,
//!   * @import with anything but the literal "plzig",
//!   * the keywords extern, export, asm, linksection, callconv, threadlocal,
//!     addrspace, volatile,
//!   * invalid tokens and NUL bytes.
//! Diagnostics go to stderr as "<line>:<col>: <message>"; exit status 0 = ok,
//! 1 = rejected, 2 = usage/internal error.
//!
//! Uses raw Linux syscalls only (no std.Io) so it has no runtime dependencies.

const std = @import("std");
const linux = std.os.linux;
const Tokenizer = std.zig.Tokenizer;
const Token = std.zig.Token;

/// Builtins that only compute. Everything else is denied (allowlist).
/// Derived from lib/std/zig/BuiltinFn.zig of Zig 0.17.1.
const allowed_builtins = [_][]const u8{
    "@addWithOverflow", "@alignOf",      "@as",            "@bitCast",
    "@bitOffsetOf",     "@intFromBool",  "@bitSizeOf",     "@branchHint",
    "@mulAdd",          "@byteSwap",     "@bitReverse",    "@offsetOf",
    "@call",            "@clz",          "@compileError",  "@compileLog",
    "@ctz",             "@divExact",     "@divFloor",      "@divCeil",
    "@divTrunc",        "@intFromEnum",  "@errorName",     "@intFromError",
    "@errorCast",       "@field",        "@FieldType",     "@floatCast",
    "@intFromFloat",    "@hasDecl",      "@hasField",      "@import",
    "@inComptime",      "@intCast",      "@backingInt",    "@fromBackingInt",
    "@enumFromInt",     "@errorFromInt", "@floatFromInt",  "@max",
    "@memcpy",          "@memset",       "@memmove",       "@min",
    "@mod",             "@mulWithOverflow", "@panic",      "@popCount",
    "@rem",             "@select",       "@shlExact",      "@shlWithOverflow",
    "@shrExact",        "@shuffle",      "@sizeOf",        "@splat",
    "@reduce",          "@src",          "@sqrt",          "@sin",
    "@cos",             "@tan",          "@exp",           "@exp2",
    "@log",             "@log2",         "@log10",         "@abs",
    "@floor",           "@ceil",         "@trunc",         "@round",
    "@subWithOverflow", "@tagName",      "@This",          "@trap",
    "@truncate",        "@EnumLiteral",  "@Int",           "@Tuple",
    "@Struct",          "@Union",        "@Enum",          "@typeInfo",
    "@typeName",        "@TypeOf",       "@unionInit",     "@Vector",
};

const denied_keywords = [_]Token.Tag{
    .keyword_extern,
    .keyword_export,
    .keyword_asm,
    .keyword_linksection,
    .keyword_callconv,
    .keyword_threadlocal,
    .keyword_addrspace,
    .keyword_volatile,
};

const max_source = 4 * 1024 * 1024;
var source_buf: [max_source + 1]u8 = undefined;

var out_buf: [16 * 1024]u8 = undefined;
var out_len: usize = 0;
var n_errors: usize = 0;

fn emit(bytes: []const u8) void {
    const n = @min(bytes.len, out_buf.len - out_len);
    @memcpy(out_buf[out_len..][0..n], bytes[0..n]);
    out_len += n;
}

fn flush() void {
    var off: usize = 0;
    while (off < out_len) {
        const rc = linux.write(2, out_buf[off..].ptr, out_len - off);
        if (linux.errno(rc) != .SUCCESS) {
            if (linux.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) return;
        off += rc;
    }
    out_len = 0;
}

fn lineCol(src: []const u8, pos: usize) struct { usize, usize } {
    var line: usize = 1;
    var col: usize = 1;
    for (src[0..pos]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ line, col };
}

fn report(src: []const u8, pos: usize, msg: []const u8, what: []const u8) void {
    n_errors += 1;
    if (n_errors > 20) return;
    const lc = lineCol(src, pos);
    var tmp: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&tmp, "{d}:{d}: ", .{ lc[0], lc[1] }) catch "";
    emit(prefix);
    emit(msg);
    if (what.len > 0) {
        emit(" '");
        emit(what[0..@min(what.len, 64)]);
        emit("'");
    }
    emit("\n");
}

fn isAllowedBuiltin(name: []const u8) bool {
    for (allowed_builtins) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

fn validate(src: [:0]const u8) void {
    if (std.mem.indexOfScalar(u8, src, 0)) |pos| {
        report(src, pos, "NUL byte in source", "");
        return;
    }
    var tok = Tokenizer.init(src);
    while (true) {
        const t = tok.next();
        const text = src[t.loc.start..t.loc.end];
        switch (t.tag) {
            .eof => break,
            .invalid => report(src, t.loc.start, "invalid token", text),
            .builtin => {
                if (!isAllowedBuiltin(text)) {
                    report(src, t.loc.start, "builtin not allowed in PL/Zig", text);
                } else if (std.mem.eql(u8, text, "@import")) {
                    // Must be exactly: @import ( "plzig" )
                    const a = tok.next();
                    const b = tok.next();
                    const c = tok.next();
                    const ok = a.tag == .l_paren and b.tag == .string_literal and
                        std.mem.eql(u8, src[b.loc.start..b.loc.end], "\"plzig\"") and
                        c.tag == .r_paren;
                    if (!ok) report(src, t.loc.start, "only @import(\"plzig\") is allowed; use plzig.std", "");
                }
            },
            else => {
                for (denied_keywords) |k| {
                    if (t.tag == k) {
                        report(src, t.loc.start, "keyword not allowed in PL/Zig", text);
                        break;
                    }
                }
            },
        }
    }
}

pub fn main() u8 {
    var len: usize = 0;
    while (true) {
        if (len >= max_source) {
            emit("source too large\n");
            flush();
            return 2;
        }
        const rc = linux.read(0, source_buf[len..].ptr, max_source - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => {
                emit("read error\n");
                flush();
                return 2;
            },
        }
        if (rc == 0) break;
        len += rc;
    }
    source_buf[len] = 0;
    const src: [:0]const u8 = source_buf[0..len :0];
    validate(src);
    if (n_errors > 20) emit("too many errors\n");
    flush();
    return if (n_errors == 0) 0 else 1;
}
