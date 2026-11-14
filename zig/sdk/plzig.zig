//! PL/Zig guest SDK.
//!
//! This module is available to every PL/Zig function body as `plzig`
//! (and its curated standard-library subset as `std`).  It is compiled for
//! wasm32-freestanding and runs inside the WebAssembly sandbox embedded in
//! the PostgreSQL backend.  The only way to reach the outside world is the
//! set of host imports declared in `host` below; see doc/abi.md.

const s = @import("std");

/// ABI version implemented by this SDK. Checked by the host at load time.
pub const abi_version: u32 = 1;

/// Curated subset of the Zig standard library: pure computation only.
/// This is a convenience policy, not the security boundary (the wasm sandbox is).
pub const std = struct {
    pub const mem = s.mem;
    pub const fmt = s.fmt;
    pub const math = s.math;
    pub const ascii = s.ascii;
    pub const unicode = s.unicode;
    pub const sort = s.sort;
    pub const hash = s.hash;
    pub const hash_map = s.hash_map;
    pub const meta = s.meta;
    pub const base64 = s.base64;
    pub const enums = s.enums;
    pub const bit_set = s.bit_set;
    pub const ArrayList = s.ArrayList;
    pub const AutoHashMap = s.AutoHashMap;
    pub const AutoHashMapUnmanaged = s.AutoHashMapUnmanaged;
    pub const StringHashMap = s.StringHashMap;
    pub const StringHashMapUnmanaged = s.StringHashMapUnmanaged;
    pub const AutoArrayHashMapUnmanaged = s.AutoArrayHashMapUnmanaged;
    pub const StringArrayHashMapUnmanaged = s.StringArrayHashMapUnmanaged;
    pub const StaticStringMap = s.StaticStringMap;
    pub const MultiArrayList = s.MultiArrayList;
    pub const PriorityQueue = s.PriorityQueue;
    pub const EnumMap = s.EnumMap;
    pub const EnumSet = s.EnumSet;
    pub const Allocator = s.mem.Allocator;
};

/// Host imports (module "plzig"). Keep in sync with src/plzig_host.c and doc/abi.md.
const host = struct {
    extern "plzig" fn log(level: u32, ptr: [*]const u8, len: u32) void;
    extern "plzig" fn raise(ptr: [*]const u8, len: u32) void;
    extern "plzig" fn panic(ptr: [*]const u8, len: u32) void;
    extern "plzig" fn spi_execute(sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const Slot, nparams: u32) i64;
    extern "plzig" fn spi_ncols() u32;
    extern "plzig" fn spi_value_len(row: u32, col: u32) i32;
    extern "plzig" fn spi_value_copy(row: u32, col: u32, buf: [*]u8, buf_len: u32) i32;
    extern "plzig" fn spi_colname_len(col: u32) i32;
    extern "plzig" fn spi_colname_copy(col: u32, buf: [*]u8, buf_len: u32) i32;
};

/// 16-byte argument/result slot shared with the host (see doc/abi.md).
pub const Slot = extern struct {
    val: u64,
    len: u32,
    is_null: u32,
};

// ---------------------------------------------------------------------------
// Allocator: one per-call bump arena over the guest linear memory.
//
// The heap is everything above the module's initial memory; it grows with
// memory.grow (bounded by plzig.max_memory on the host) and is reset to empty
// at the start of every call, like a per-call PostgreSQL memory context.

const wasm_page: u64 = 65536;
var heap_start: usize = 0;
var heap_top: usize = 0;

fn heapInit() void {
    if (heap_start == 0) {
        heap_start = @intCast(@as(u64, @wasmMemorySize(0)) * wasm_page);
        heap_top = heap_start;
    }
}

/// Make sure linear memory extends to at least `end` bytes.
fn ensureMemory(end: u64) bool {
    const have: u64 = @as(u64, @wasmMemorySize(0)) * wasm_page;
    if (end <= have) return true;
    if (end > (1 << 32)) return false;
    const pages = (end - have + wasm_page - 1) / wasm_page;
    return @wasmMemoryGrow(0, @intCast(pages)) >= 0;
}

fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: s.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    heapInit();
    const start: u64 = s.mem.alignForward(u64, heap_top, alignment.toByteUnits());
    const end: u64 = start + len;
    if (!ensureMemory(end)) return null;
    heap_top = @intCast(end);
    return @ptrFromInt(@as(usize, @intCast(start)));
}

fn arenaResize(ctx: *anyopaque, memory: []u8, alignment: s.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    const start = @intFromPtr(memory.ptr);
    if (start + memory.len == heap_top) {
        // the most recent allocation can grow or shrink in place
        const end: u64 = @as(u64, start) + new_len;
        if (!ensureMemory(end)) return false;
        heap_top = @intCast(end);
        return true;
    }
    return new_len <= memory.len;
}

fn arenaRemap(ctx: *anyopaque, memory: []u8, alignment: s.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (arenaResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn arenaFree(ctx: *anyopaque, memory: []u8, alignment: s.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    const start = @intFromPtr(memory.ptr);
    if (start + memory.len == heap_top) heap_top = start;
}

const arena_vtable: s.mem.Allocator.VTable = .{
    .alloc = arenaAlloc,
    .resize = arenaResize,
    .remap = arenaRemap,
    .free = arenaFree,
};

/// The only allocator available to PL/Zig code. Everything allocated from it
/// is released when the current function call finishes (like a per-call
/// PostgreSQL memory context); calling `free` is optional.
pub const allocator: s.mem.Allocator = .{ .ptr = undefined, .vtable = &arena_vtable };

/// Called by the SDK root at the start of every call. Not for user code.
pub fn resetArena() void {
    heapInit();
    heap_top = heap_start;
}

// ---------------------------------------------------------------------------
// Logging and errors.

pub const Level = enum(u32) {
    debug = 0,
    log = 1,
    info = 2,
    notice = 3,
    warning = 4,
};

/// Emit a message at the given level (as `elog` would). Messages longer than
/// the host limit are truncated by the host.
pub fn print(level: Level, comptime fmt: []const u8, args: anytype) void {
    const msg = s.fmt.allocPrint(allocator, fmt, args) catch {
        const oom = "plzig: out of memory while formatting log message";
        host.log(@intFromEnum(Level.warning), oom.ptr, oom.len);
        return;
    };
    host.log(@intFromEnum(level), msg.ptr, @intCast(msg.len));
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    print(.debug, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    print(.info, fmt, args);
}
pub fn notice(comptime fmt: []const u8, args: anytype) void {
    print(.notice, fmt, args);
}
pub fn warning(comptime fmt: []const u8, args: anytype) void {
    print(.warning, fmt, args);
}

/// Raise an SQL ERROR (SQLSTATE P0001). Never returns; the function call is aborted.
pub fn raise(comptime fmt: []const u8, args: anytype) noreturn {
    const msg = s.fmt.allocPrint(allocator, fmt, args) catch "plzig: out of memory while formatting error message";
    raiseMsg(msg);
}

/// Raise an SQL ERROR with a preformatted message. Never returns.
pub fn raiseMsg(msg: []const u8) noreturn {
    host.raise(msg.ptr, @intCast(@min(msg.len, 0xffff_ffff)));
    @trap();
}

/// Panic handler used by the SDK root (Zig safety-check failures).
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    host.panic(msg.ptr, @intCast(@min(msg.len, 0xffff_ffff)));
    @trap();
}

// ---------------------------------------------------------------------------
// SPI.

/// Result of `spi.execute`. Values are returned in their text representation,
/// copied into the per-call arena. Only the most recent result is accessible:
/// executing another statement invalidates earlier `Result`s.
pub const Result = struct {
    /// Number of rows processed (rows returned for SELECT, affected for DML).
    rows: u64,
    /// Number of columns in the returned rows (0 for statements without result rows).
    columns: u32,

    /// Text value of column `col` in row `row` (both 0-based), or null for SQL NULL.
    pub fn get(self: Result, row: u64, col: u32) error{OutOfMemory}!?[]const u8 {
        _ = self;
        const r: u32 = @intCast(@min(row, 0xffff_ffff));
        const n = host.spi_value_len(r, col);
        if (n < 0) return null;
        const buf = try allocator.alloc(u8, @intCast(n));
        if (buf.len > 0) {
            const got = host.spi_value_copy(r, col, buf.ptr, @intCast(buf.len));
            if (got != n) raiseMsg("plzig: SPI value changed size during copy");
        }
        return buf;
    }

    /// Name of column `col` (0-based).
    pub fn columnName(self: Result, col: u32) error{OutOfMemory}![]const u8 {
        _ = self;
        const n = host.spi_colname_len(col);
        if (n < 0) raiseMsg("plzig: invalid column number");
        const buf = try allocator.alloc(u8, @intCast(n));
        if (buf.len > 0) _ = host.spi_colname_copy(col, buf.ptr, @intCast(buf.len));
        return buf;
    }
};

pub const spi = struct {
    /// Execute an SQL statement with text parameters `$1..$n` (pass `null` for
    /// SQL NULL; cast in SQL, e.g. `$1::int`). Runs with the privileges of the
    /// current user, read-only unless the function is VOLATILE. Any SQL error
    /// aborts the whole function call; it cannot be caught.
    pub fn execute(sql: []const u8, params: []const ?[]const u8) error{OutOfMemory}!Result {
        const slots = try allocator.alloc(Slot, params.len);
        for (params, slots) |p, *slot| {
            if (p) |v| {
                slot.* = .{ .val = @intFromPtr(v.ptr), .len = @intCast(v.len), .is_null = 0 };
            } else {
                slot.* = .{ .val = 0, .len = 0, .is_null = 1 };
            }
        }
        const n = host.spi_execute(sql.ptr, @intCast(sql.len), slots.ptr, @intCast(slots.len));
        return .{ .rows = @intCast(n), .columns = host.spi_ncols() };
    }
};
