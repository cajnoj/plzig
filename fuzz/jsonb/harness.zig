//! libFuzzer target for the guest SDK's jsonb reader and numeric decoders
//! (fuzz/README.md, target "jsonb").
//!
//! Built like the validator target (zig build-obj -ffuzz, linked by clang
//! with -fsanitize=fuzzer; see fuzz/build.sh), with the production SDK
//! (zig/sdk/plzig.zig, module "plzig") compiled natively and unchanged.  Only
//! the SDK functions that take an explicit allocator are used, so nothing
//! here needs the wasm environment (host imports, linear memory).
//!
//! The first input byte selects what the rest is:
//!   0..127   a jsonb value in PostgreSQL's on-disk layout (the root
//!            JsonbContainer, as the host passes it to a function)
//!   128..191 a numeric in the binary wire format (numeric_send)
//!   192..255 a numeric in the on-disk format, as stored inside a jsonb
//!            (varlena with a short or long numeric header)
//!
//! Oracles (any violation panics, which libFuzzer reports; ReleaseSafe, so
//! every out-of-bounds read or overflow is a panic too):
//!   * jsonb: reading every value reachable from the root (iteration,
//!     indexing, key lookup, number decoding) and serialising it never
//!     panics, whatever the bytes; a serialisation that succeeds is valid
//!     JSON (std.json); every number the decoder produces is valid wire
//!     format (Numeric.fromWire); in an object whose keys are in jsonb's
//!     order (length, then bytes, strictly increasing), the binary search
//!     finds every key at its own position;
//!   * wire numerics: what fromWire accepts formats without panicking, and
//!     parsing its text gives back an equal value with the same text
//!     (parse(toText(x)) == x); conversions and ordering never panic, and
//!     order(x, x) == .eq;
//!   * on-disk numerics: the decoder either refuses the bytes or produces
//!     valid wire format.
const std = @import("std");
const plzig = @import("plzig");

var heap_buf: [128 * 1024 * 1024]u8 = undefined;

fn finding(comptime what: []const u8, args: anytype) noreturn {
    std.debug.panic("jsonb/numeric finding: " ++ what, args);
}

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size < 1) return 0;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const gpa = fba.allocator();
    const sel = data[0];
    // an 8-byte aligned copy, as the host places values in guest memory
    const copy = gpa.alignedAlloc(u8, .@"8", size - 1) catch return 0;
    @memcpy(copy, data[1..size]);
    if (sel < 128) {
        checkJsonb(gpa, copy);
    } else if (sel < 192) {
        checkWire(gpa, copy);
    } else {
        checkDisk(gpa, copy);
    }
    return 0;
}

/// set by walk: the value holds something that is not JSON although its
/// layout is fine (a NaN, infinite or unnormalised numeric, which jsonb_out
/// would print bare or with leading zeros; a string that is not UTF-8): no
/// JSON validity check then
var not_json = false;

fn checkJsonb(gpa: std.mem.Allocator, bytes: []const u8) void {
    const j: plzig.Jsonb = .{ .bytes = bytes };
    not_json = false;
    if (j.root()) |r| walk(gpa, r, 0) else |_| {}
    if (j.toJsonAlloc(gpa)) |text| {
        // what serialises is valid JSON
        if (not_json) return;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{ .duplicate_field_behavior = .use_last, .max_value_len = text.len + 1 }) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => finding("serialisation is not valid JSON ({s}): {s}", .{ @errorName(err), text[0..@min(text.len, 200)] }),
        };
        parsed.deinit();
    } else |_| {}
}

fn walk(gpa: std.mem.Allocator, v: plzig.JsonValue, depth: usize) void {
    if (depth > 4096) return;
    switch (v) {
        .number => |n| {
            const w = n.numericAlloc(gpa) catch return;
            const x = plzig.Numeric.fromWire(w.wire) catch finding("decoded jsonb number is not valid wire format", .{});
            // (an unnormalised numeric prints leading zeros; PostgreSQL's
            // numerics are always normalised)
            if (!x.isFinite() or !isNormalised(x)) not_json = true;
        },
        .string => |str| if (!std.unicode.utf8ValidateSlice(str)) {
            not_json = true;
        },
        .array => |a| {
            var it = a.iterator();
            var i: usize = 0;
            while (it.next() catch return) |x| : (i += 1) walk(gpa, x, depth + 1);
            _ = a.get(a.len()) catch {};
            _ = a.get(std.math.maxInt(usize)) catch {};
        },
        .object => |o| {
            var it = o.iterator();
            var prev: ?[]const u8 = null;
            var sorted = true;
            while (it.next() catch return) |e| {
                if (!std.unicode.utf8ValidateSlice(e.key)) not_json = true;
                if (prev) |p| {
                    if (p.len > e.key.len or (p.len == e.key.len and std.mem.order(u8, p, e.key) != .lt)) sorted = false;
                }
                prev = e.key;
                walk(gpa, e.value, depth + 1);
            }
            // binary search consistency, for keys in jsonb's order
            for (0..o.len()) |i| {
                const e = (o.entry(i) catch return) orelse finding("entry {d} missing", .{i});
                const found = o.get(e.key) catch return;
                if (sorted) {
                    const f = found orelse finding("key {d} not found by binary search", .{i});
                    if (!std.meta.eql(f, e.value)) finding("key {d} found with another value", .{i});
                }
            }
            _ = o.get("") catch {};
            _ = o.get("\xff\xff\xff\xff\xff\xff\xff\xff") catch {};
        },
        else => {},
    }
}

fn checkWire(gpa: std.mem.Allocator, bytes: []const u8) void {
    const N = plzig.Numeric;
    const n = N.fromWire(bytes) catch return;
    if (N.order(n, n) != .eq) finding("order(x, x) is not .eq", .{});
    _ = N.order(n, N.zero);
    _ = N.order(N.nan, n);
    _ = n.toI64() catch {};
    _ = n.toF64() catch {};
    _ = n.isZero();
    _ = n.isNegative();
    const text = n.toTextAlloc(gpa) catch return;
    if (text.len != n.textLen()) finding("textLen differs from the text", .{});
    const back = N.parseAlloc(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => finding("own text does not parse ({s}): {s}", .{ @errorName(err), text[0..@min(text.len, 200)] }),
    };
    _ = N.fromWire(back.wire) catch finding("parse built invalid wire format", .{});
    // equal values; the text is equal too, unless digits beyond the scale
    // were cut (numeric_out does not print them, numeric_recv truncates them)
    // PostgreSQL only ever has normalised values (numeric_recv normalises),
    // and for those the text and value round trips are exact
    // (numeric_recv also truncates digits beyond the scale: a value with
    // such digits never exists in PostgreSQL either)
    if (!isNormalised(n) or hasHiddenDigits(n)) return;
    const back_text = back.toTextAlloc(gpa) catch return;
    if (!std.mem.eql(u8, text, back_text)) finding("text round trip: {s} -> {s}", .{ text[0..@min(text.len, 100)], back_text[0..@min(back_text.len, 100)] });
    if (N.order(n, back) != .eq) finding("parse(toText(x)) != x: {s}", .{text[0..@min(text.len, 200)]});
}

/// no leading or trailing zero digits; zero is positive with weight 0
fn isNormalised(n: plzig.Numeric) bool {
    if (!n.isFinite()) return true;
    const nd = (n.wire.len - 8) / 2;
    if (nd == 0) return n.signField() == plzig.Numeric.sign_pos and n.weight() == 0;
    const first = (@as(u16, n.wire[8]) << 8) | n.wire[9];
    const last = (@as(u16, n.wire[n.wire.len - 2]) << 8) | n.wire[n.wire.len - 1];
    return first != 0 and last != 0;
}

/// digits beyond the display scale (allowed by the wire format; not printed)
fn hasHiddenDigits(n: plzig.Numeric) bool {
    if (!n.isFinite()) return false;
    const nd = (n.wire.len - 8) / 2;
    const w: i64 = n.weight();
    for (0..nd) |i| {
        const d = (@as(u16, n.wire[8 + 2 * i]) << 8) | n.wire[9 + 2 * i];
        if (d == 0) continue;
        // digit i covers decimal places (i - w) * 4 - 3 .. (i - w) * 4 after the point
        const last_place = (@as(i64, @intCast(i)) - w) * 4;
        if (last_place > n.scale()) {
            // the low-order decimal digits of this base digit must be zero
            const keep = n.scale() - (last_place - 4);
            if (keep <= 0) return true;
            var div: u16 = 1;
            var k: i64 = 0;
            while (k < 4 - keep) : (k += 1) div *= 10;
            if (d % div != 0) return true;
        }
    }
    return false;
}

fn checkDisk(gpa: std.mem.Allocator, bytes: []const u8) void {
    const jn: plzig.JsonNumber = .{ .raw = bytes };
    const w = jn.numericAlloc(gpa) catch return;
    const n = plzig.Numeric.fromWire(w.wire) catch finding("decoded on-disk numeric is not valid wire format", .{});
    checkWire(gpa, n.wire);
}
