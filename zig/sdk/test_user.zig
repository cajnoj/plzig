//! Stand-in for the generated user.zig, for the native unit tests of the
//! SDK root (zig/sdk/test.zig).  Same shape as plzig_generate_source()
//! output: `pub fn call(...) anyerror!?T`, non-strict parameters optional.

const plzig = @import("plzig");
const std = plzig.std;

/// what the last call received, rendered as text
pub var seen: [512]u8 = undefined;
pub var seen_len: usize = 0;

pub fn call(b: ?bool, s2: ?i16, s4: ?i32, s8: ?i64, f4: ?f32, f8: ?f64, t: ?[]const u8, strict_t: []const u8, mode: i32) anyerror!?[]const u8 {
    const out = std.fmt.bufPrint(&seen, "{?}|{?d}|{?d}|{?d}|{?d}|{?d}|{?s}|{s}|{d}", .{ b, s2, s4, s8, f4, f8, t, strict_t, mode }) catch unreachable;
    seen_len = out.len;
    return switch (mode) {
        0 => null,
        1 => error.SomethingFailed,
        2 => "",
        else => try std.fmt.allocPrint(plzig.allocator, "got {d} bytes", .{strict_t.len}),
    };
}
