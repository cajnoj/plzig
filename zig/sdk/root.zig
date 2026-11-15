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

/// The argument buffer: the host writes the argument block of a call here
/// when it fits, so that a call enters the guest once (plzig_call with
/// begin = 1).  Outside the arena, so the arena reset at the start of the
/// call does not touch it; argument slices point into it and are valid
/// until the call returns, like everything in the arena.
var arg_buffer: [plzig.arg_buffer_size]u8 align(8) = undefined;

/// Called once per instance: where the argument buffer is and how large,
/// as `capacity << 32 | address`.
export fn plzig_init() u64 {
    return (@as(u64, arg_buffer.len) << 32) | @as(u64, @intCast(@intFromPtr(&arg_buffer)));
}

/// Fallback for argument blocks larger than the argument buffer: start a
/// call (release everything allocated by the previous call) and allocate
/// `len` bytes (8-byte aligned) in the arena for the block; 0 on failure.
/// The host then calls plzig_call with begin = 0.
/// rawAlloc, not alignedAlloc: in ReleaseSafe the latter first fills the
/// block with 0xAA (@memset undefined), byte by byte in the interpreter, ~10
/// ns per byte; the host writes every slot and payload (alignment padding
/// keeps this instance's old bytes: guest memory, never host data).
export fn plzig_alloc_args(len: u32) u32 {
    plzig.resetArena();
    const p = plzig.allocator.rawAlloc(len, .@"8", 0) orelse return 0;
    return @intCast(@intFromPtr(p));
}

const Fn = @TypeOf(user.call); // decode/encode below are pub for zig/sdk/test.zig
const fn_info = @typeInfo(Fn).@"fn";

pub fn decode(comptime T: type, slot: *const Slot) T {
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
    if (T == plzig.Date) return .{ .days = @truncate(@as(i64, @bitCast(slot.val))) };
    if (T == plzig.Time or T == plzig.Timestamp or T == plzig.TimestampTz) return .{ .usecs = @bitCast(slot.val) };
    if (T == plzig.TimeTz) return .{ .usecs = @bitCast(slot.val), .zone = @bitCast(slot.len) };
    if (T == plzig.Oid) return .{ .value = @truncate(slot.val) };
    if (T == plzig.Numeric) {
        // numeric_send of the argument: valid
        if (slot.len == 0) return plzig.Numeric.zero;
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return .{ .wire = p[0..slot.len] };
    }
    if (T == plzig.Interval or T == plzig.Uuid) {
        if (slot.len != 16) plzig.raiseMsg("plzig: invalid fixed-width argument");
        const p: *align(1) const T = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return p.*;
    }
    @compileError("plzig: unsupported parameter type " ++ @typeName(T));
}

/// Where a 16-byte result (interval, uuid) is placed for the host to copy
/// after plzig_call has returned: outside the stack and the arena.
var fixed_result: [16]u8 align(8) = undefined;

pub fn encode(comptime T: type, v: T, out: *Slot) void {
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
    } else if (T == plzig.Date) {
        out.val = @bitCast(@as(i64, v.days));
    } else if (T == plzig.Time or T == plzig.Timestamp or T == plzig.TimestampTz) {
        out.val = @bitCast(v.usecs);
    } else if (T == plzig.TimeTz) {
        out.val = @bitCast(v.usecs);
        out.len = @bitCast(v.zone);
    } else if (T == plzig.Oid) {
        out.val = v.value;
    } else if (T == plzig.Numeric) {
        // checked by the host with numeric_recv
        out.val = @intFromPtr(v.wire.ptr);
        out.len = @intCast(@min(v.wire.len, 0xffff_ffff));
    } else if (T == plzig.Interval or T == plzig.Uuid) {
        @memcpy(&fixed_result, s.mem.asBytes(&v));
        out.val = @intFromPtr(&fixed_result);
        out.len = 16;
    } else {
        @compileError("plzig: unsupported return type " ++ @typeName(T));
    }
}

fn setError(out: *Slot, err: anyerror) u32 {
    const name = @errorName(err);
    out.* = .{ .val = @intFromPtr(name.ptr), .len = @intCast(name.len), .is_null = 0 };
    return STATUS_ERROR;
}

/// Call the user function. `args` points to `nargs` slots, `result` to one
/// slot. `begin` != 0 starts the call by releasing everything allocated by
/// the previous call (the arguments are in the argument buffer); 0 means
/// plzig_alloc_args has already done that (the arguments are in the arena).
export fn plzig_call(args: [*]const Slot, nargs: u32, result: *Slot, begin: u32) u32 {
    if (begin != 0) plzig.resetArena();
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
