//! PL/Zig SDK root module: the wasm entry points the host calls.
//! The user's function lives in module "user" as `pub fn call(...)`.

const s = @import("std");
const plzig = @import("plzig");
const user = @import("user");

const Slot = plzig.Slot;

pub const panic = s.debug.FullPanic(plzig.panicHandler);

/// Status codes returned by plzig_call (abi/plzig-abi.table, doc/abi.md).
const STATUS_OK: u32 = @intFromEnum(plzig.CallStatus.ok);
const STATUS_ERROR: u32 = @intFromEnum(plzig.CallStatus.user_error);

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
    if (T == plzig.Jsonb) {
        // the detoasted jsonb's on-disk layout, read in place
        if (slot.len == 0) return .{ .bytes = &.{} };
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return .{ .bytes = p[0..slot.len] };
    }
    if (T == plzig.Interval or T == plzig.Uuid) {
        if (slot.len != 16) plzig.raiseMsg("plzig: invalid fixed-width argument");
        const p: *align(1) const T = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return p.*;
    }
    if (@typeInfo(T) == .@"struct") {
        // a composite argument: val = its values, len = their number
        const n = plzig.rowFieldCount(T);
        if (slot.len != n) plzig.raiseMsg("plzig: composite argument has the wrong number of fields");
        if (n == 0) return plzig.decodeRow(T, &.{}) catch unreachable;
        const p: [*]const plzig.Value = @ptrFromInt(@as(usize, @intCast(slot.val)));
        return plzig.decodeRow(T, p[0..n]) catch plzig.raiseMsg("plzig: composite argument does not match its struct");
    }
    @compileError("plzig: unsupported parameter type " ++ @typeName(T));
}

/// Where a row result is placed for the host to read after plzig_call has
/// returned (outside the stack and the arena): one set of buffers per row
/// type.  Static, so `undefined` costs nothing at run time.
fn RowResult(comptime T: type) type {
    return struct {
        var values: [plzig.rowFieldCount(T)]plzig.Value = undefined;
        var fixed: [plzig.rowFixedCount(T)][16]u8 align(8) = undefined;
    };
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
    } else if (T == plzig.JsonText) {
        // JSON text, parsed by the host with jsonb_in
        out.val = @intFromPtr(v.text.ptr);
        out.len = @intCast(@min(v.text.len, 0xffff_ffff));
    } else if (T == plzig.Numeric) {
        // checked by the host with numeric_recv
        out.val = @intFromPtr(v.wire.ptr);
        out.len = @intCast(@min(v.wire.len, 0xffff_ffff));
    } else if (T == plzig.Interval or T == plzig.Uuid) {
        @memcpy(&fixed_result, s.mem.asBytes(&v));
        out.val = @intFromPtr(&fixed_result);
        out.len = 16;
    } else if (comptime plzig.isRowType(T)) {
        // a row: val = its values, len = their number (doc/abi.md, "Rows")
        const B = RowResult(T);
        plzig.encodeRow(T, v, &B.values, &B.fixed) catch |err| plzig.raise("plzig: could not encode the result row: {s}", .{@errorName(err)});
        out.val = @intFromPtr(&B.values);
        out.len = @intCast(B.values.len);
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
/// a trigger function: `call(tg: plzig.Trigger)`, three slots from the host
const is_trigger = fn_info.param_types.len == 1 and fn_info.param_types[0].? == plzig.Trigger;

export fn plzig_call(args: [*]const Slot, nargs: u32, result: *Slot, begin: u32) u32 {
    if (begin != 0) plzig.resetArena();
    if (comptime is_trigger) return callTrigger(args, nargs, result) else return callFunction(args, nargs, result);
}

/// A trigger call: the trigger's information, NEW and OLD (doc/abi.md,
/// "Triggers"); the result's action goes into is_null, a modified row's
/// values into val/len.
fn callTrigger(args: [*]const Slot, nargs: u32, result: *Slot) u32 {
    if (nargs != 3) plzig.raiseMsg("plzig: trigger argument count mismatch");
    const r = user.call(plzig.Trigger.fromSlots(args)) catch |err| return setError(result, err);
    result.* = .{ .val = @intFromPtr(r.values.ptr), .len = @intCast(r.values.len), .is_null = r.action };
    return STATUS_OK;
}

fn callFunction(args: [*]const Slot, nargs: u32, result: *Slot) u32 {
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

/// memset and memcpy for the module.  The compiler calls these for every
/// fill and copy whose size it does not know: `@memset`, `@memcpy`, slice
/// copies, and the 0xAA fill of `undefined` memory that ReleaseSafe does
/// (stack variables, and `std.mem.Allocator`'s alloc, realloc and free).
/// Zig's own versions (compiler-rt, weak symbols these replace) move one
/// 32-bit word per loop iteration on wasm32; the interpreter pays per
/// instruction, so these move 32 bytes per iteration with 64-bit loads and
/// stores (unaligned ones are valid in WebAssembly).  Same results byte for
/// byte; zig/sdk/test.zig compares them with a byte loop for every length
/// and alignment.  `@disableIntrinsics` keeps the compiler from turning the
/// loops back into calls of memset/memcpy (that is, of themselves).
pub fn memsetImpl(dest: ?[*]u8, c: u8, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();
    @setRuntimeSafety(false);
    const d = dest orelse return dest;
    if (len < 8) {
        var i: usize = 0;
        while (i < len) : (i += 1) d[i] = c;
        return dest;
    }
    const v: u64 = @as(u64, c) *% 0x0101010101010101;
    var i: usize = 0;
    while (len - i >= 32) : (i += 32) {
        @as(*align(1) u64, @ptrCast(d + i)).* = v;
        @as(*align(1) u64, @ptrCast(d + i + 8)).* = v;
        @as(*align(1) u64, @ptrCast(d + i + 16)).* = v;
        @as(*align(1) u64, @ptrCast(d + i + 24)).* = v;
    }
    while (len - i >= 8) : (i += 8) {
        @as(*align(1) u64, @ptrCast(d + i)).* = v;
    }
    // the last 8 bytes, overlapping what is already set (len >= 8)
    @as(*align(1) u64, @ptrCast(d + len - 8)).* = v;
    return dest;
}

/// See memsetImpl.  The ranges do not overlap (memcpy's contract), so
/// copying the last 8 bytes again at the end is harmless.
pub fn memcpyImpl(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();
    @setRuntimeSafety(false);
    const d = dest orelse return dest;
    const f = src orelse return dest;
    if (len < 8) {
        var i: usize = 0;
        while (i < len) : (i += 1) d[i] = f[i];
        return dest;
    }
    var i: usize = 0;
    while (len - i >= 32) : (i += 32) {
        const a = @as(*align(1) const u64, @ptrCast(f + i)).*;
        const b = @as(*align(1) const u64, @ptrCast(f + i + 8)).*;
        const e = @as(*align(1) const u64, @ptrCast(f + i + 16)).*;
        const g = @as(*align(1) const u64, @ptrCast(f + i + 24)).*;
        @as(*align(1) u64, @ptrCast(d + i)).* = a;
        @as(*align(1) u64, @ptrCast(d + i + 8)).* = b;
        @as(*align(1) u64, @ptrCast(d + i + 16)).* = e;
        @as(*align(1) u64, @ptrCast(d + i + 24)).* = g;
    }
    while (len - i >= 8) : (i += 8) {
        @as(*align(1) u64, @ptrCast(d + i)).* = @as(*align(1) const u64, @ptrCast(f + i)).*;
    }
    @as(*align(1) u64, @ptrCast(d + len - 8)).* = @as(*align(1) const u64, @ptrCast(f + len - 8)).*;
    return dest;
}

comptime {
    // only in a compiled module: the native SDK tests keep their libc's
    if (@import("builtin").cpu.arch == .wasm32) {
        @export(&memsetImpl, .{ .name = "memset", .linkage = .strong, .visibility = .hidden });
        @export(&memcpyImpl, .{ .name = "memcpy", .linkage = .strong, .visibility = .hidden });
    }
}

// The entry points (plzig_abi_version, plzig_init, plzig_alloc_args,
// plzig_call) are those of abi/plzig-abi.table, with exactly its types.
// The host links with an --export flag per table entry, so an entry point
// the table lacks is not exported.  (@field: a missing one does not
// compile either; @hasDecl does not see these, they are not pub.)
comptime {
    for (plzig.guest_export_types) |t| {
        if (@TypeOf(@field(@This(), t[0])) != t[1])
            @compileError("guest export " ++ t[0] ++ ": its type is not the one of abi/plzig-abi.table");
    }
}
