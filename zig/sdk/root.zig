//! PL/Zig SDK root module: the wasm entry points the host calls.
//! The user's function lives in module "user" as `pub fn call(...)`.

const s = @import("std");
const plzig = @import("plzig");
const user = @import("user");

const Slot = plzig.Slot;

pub const panic = s.debug.FullPanic(plzig.panicHandler);

/// Status codes returned by plzig_call (see doc/abi.md).
const STATUS_OK: u32 = 0;
const STATUS_ERROR: u32 = 1;

export fn plzig_abi_version() u32 {
    return plzig.abi_version;
}

/// Start a new call: releases everything allocated by the previous call.
export fn plzig_begin() void {
    plzig.resetArena();
}

/// Allocate `len` bytes (8-byte aligned) in the per-call arena; 0 on failure.
export fn plzig_alloc(len: u32) u32 {
    const mem = plzig.allocator.alignedAlloc(u8, .@"8", len) catch return 0;
    return @intCast(@intFromPtr(mem.ptr));
}

const Fn = @TypeOf(user.call);
const fn_info = @typeInfo(Fn).@"fn";

fn decode(comptime T: type, slot: *const Slot) T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (slot.is_null != 0) return null;
            return decode(o.child, slot);
        },
        else => {},
    }
    if (slot.is_null != 0) plzig.raiseMsg("plzig: NULL passed for non-optional parameter");
    if (T == bool) return slot.val != 0;
    if (T == i16) return @truncate(@as(i64, @bitCast(slot.val)));
    if (T == i32) return @truncate(@as(i64, @bitCast(slot.val)));
    if (T == i64) return @bitCast(slot.val);
    if (T == f32) return @bitCast(@as(u32, @truncate(slot.val)));
    if (T == f64) return @bitCast(slot.val);
    if (T == []const u8) {
        if (slot.len == 0) return &.{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return p[0..slot.len];
    }
    @compileError("plzig: unsupported parameter type " ++ @typeName(T));
}

fn encode(comptime T: type, v: T, out: *Slot) void {
    out.* = .{ .val = 0, .len = 0, .is_null = 0 };
    if (T == bool) {
        out.val = @intFromBool(v);
    } else if (T == i16 or T == i32 or T == i64) {
        out.val = @bitCast(@as(i64, v));
    } else if (T == f32) {
        out.val = @as(u32, @bitCast(v));
    } else if (T == f64) {
        out.val = @bitCast(v);
    } else if (T == []const u8 or T == []u8) {
        out.val = @intFromPtr(v.ptr);
        out.len = @intCast(v.len);
    } else {
        @compileError("plzig: unsupported return type " ++ @typeName(T));
    }
}

fn setError(out: *Slot, err: anyerror) u32 {
    const name = @errorName(err);
    out.* = .{ .val = @intFromPtr(name.ptr), .len = @intCast(name.len), .is_null = 0 };
    return STATUS_ERROR;
}

/// Call the user function. `args` points to `nargs` slots, `result` to one slot.
export fn plzig_call(args: [*]const Slot, nargs: u32, result: *Slot) u32 {
    if (nargs != fn_info.param_types.len) plzig.raiseMsg("plzig: argument count mismatch");
    var tuple: s.meta.ArgsTuple(Fn) = undefined;
    inline for (fn_info.param_types, 0..) |PT, i| {
        tuple[i] = decode(PT.?, &args[i]);
    }
    const Ret = fn_info.return_type.?;
    const Payload = @typeInfo(Ret).error_union.payload;
    const value = @call(.auto, user.call, tuple) catch |err| return setError(result, err);
    if (Payload == void) {
        result.* = .{ .val = 0, .len = 0, .is_null = 1 };
        return STATUS_OK;
    }
    switch (@typeInfo(Payload)) {
        .optional => |o| {
            if (value) |v| {
                encode(o.child, v, result);
            } else {
                result.* = .{ .val = 0, .len = 0, .is_null = 1 };
            }
        },
        else => encode(Payload, value, result),
    }
    return STATUS_OK;
}
