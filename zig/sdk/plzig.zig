//! PL/Zig guest SDK.
//!
//! This module is available to every PL/Zig function body as `plzig`
//! (and its curated standard-library subset as `std`).  It is compiled for
//! wasm32-freestanding and runs inside the WebAssembly sandbox embedded in
//! the PostgreSQL backend.  The only way to reach the outside world is the
//! set of host imports declared in `host` below; see doc/abi.md.

const s = @import("std");

/// ABI version implemented by this SDK. Checked by the host at load time.
pub const abi_version: u32 = 2;

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

/// Host imports and linear memory.  In the wasm module these are the real
/// imports (module "plzig"; keep in sync with src/plzig_host.c and
/// doc/abi.md) and the wasm memory builtins.  Only the native unit tests
/// (zig/sdk/test.zig, `zig test` sets builtin.is_test) supply a stand-in
/// module "plzig_test_env" instead; it is never part of a function build.
const env = if (@import("builtin").is_test) @import("plzig_test_env") else wasm_env;
const host = env.host;

const wasm_env = struct {
    /// linear memory starts at address 0
    const memory_base: usize = 0;

    fn memoryPages() usize {
        return @wasmMemorySize(0);
    }

    fn memoryGrow(pages: usize) isize {
        return @wasmMemoryGrow(0, pages);
    }

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
        extern "plzig" fn spi_row_size(row: u32) i64;
        extern "plzig" fn spi_row_read(row: u32, buf: [*]u8, buf_len: u32) i32;
        extern "plzig" fn spi_prepare(sql_ptr: [*]const u8, sql_len: u32, kinds_ptr: [*]const u32, nkinds: u32) u64;
        extern "plzig" fn spi_plan_free(handle: u64) void;
        extern "plzig" fn spi_execute_plan(handle: u64, params_ptr: [*]const Value, nparams: u32) i64;
        extern "plzig" fn spi_cursor_open(sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const Slot, nparams: u32) u64;
        extern "plzig" fn spi_cursor_open_plan(handle: u64, params_ptr: [*]const Value, nparams: u32) u64;
        extern "plzig" fn spi_cursor_next(cursor: u64) i64;
        extern "plzig" fn spi_cursor_read(cursor: u64, buf: [*]u8, buf_len: u32) i32;
        extern "plzig" fn spi_cursor_close(cursor: u64) void;
    };
};

/// 16-byte argument/result slot shared with the host (see doc/abi.md).
pub const Slot = extern struct {
    val: u64,
    len: u32,
    is_null: u32,
};

/// 16-byte typed value shared with the host: parameters of prepared
/// statements and columns of result rows (see doc/abi.md, "Value").
pub const Value = extern struct {
    val: u64,
    len: u32,
    kind: u16,
    is_null: u16,
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
        heap_start = env.memory_base + @as(usize, @intCast(@as(u64, env.memoryPages()) * wasm_page));
        heap_top = heap_start;
    }
}

/// Make sure linear memory extends to at least address `end`.
fn ensureMemory(end: u64) bool {
    const have: u64 = env.memory_base + @as(u64, env.memoryPages()) * wasm_page;
    if (end <= have) return true;
    // wasm32: at most 4 GB of linear memory (the host caps it far lower)
    if (end - env.memory_base > (1 << 32)) return false;
    const pages = (end - have + wasm_page - 1) / wasm_page;
    return env.memoryGrow(@intCast(pages)) >= 0;
}

fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: s.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    heapInit();
    const start: u64 = s.mem.alignForward(u64, heap_top, alignment.toByteUnits());
    const end: u64 = s.math.add(u64, start, len) catch return null;
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
        const end: u64 = s.math.add(u64, start, new_len) catch return false;
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
    result_scratch = .{};
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
//
// Three ways to run SQL, all with the privileges of the current user and
// read-only unless the function is VOLATILE; any SQL error aborts the whole
// function call (it cannot be caught):
//
//   * spi.execute(sql, text_params): one statement, text parameters, the
//     whole result materialised;
//   * spi.prepare(sql, types) -> Plan: a prepared statement kept for the
//     lifetime of the function instance, executed with typed parameters;
//   * spi.open(sql, text_params) / plan.open(args) -> Cursor: rows fetched
//     one at a time.

/// Kind of a result column, derived by the host from the column's type.
pub const Kind = enum(u16) {
    boolean = 1,
    int2 = 2,
    int4 = 3,
    int8 = 4,
    float4 = 5,
    float8 = 6,
    /// text, varchar, char(n): the value's bytes
    text = 7,
    bytea = 8,
    /// any other type: its text representation
    other = 9,
    _,
};

/// Parameter types of prepared statements.
pub const Type = enum(u32) {
    boolean = 1,
    int2 = 2,
    int4 = 3,
    int8 = 4,
    float4 = 5,
    float8 = 6,
    text = 7,
    bytea = 8,
    /// other values are rejected by the host
    _,
};

/// Marks a byte slice as a `bytea` parameter (plain slices are `text`).
pub const Bytea = struct { bytes: []const u8 };

pub fn bytea(bytes: []const u8) Bytea {
    return .{ .bytes = bytes };
}

pub const GetError = error{ ColumnOutOfRange, TypeMismatch, UnexpectedNull };

/// One result row with typed access. A Row (and every slice obtained from
/// it) points into a scratch buffer that is reused: for cursor rows it is
/// invalid after the next `Cursor.next()`, for `Result.row` rows after the
/// next `Result.row`. Copy what you need to keep.
pub const Row = struct {
    values: []const Value,

    /// Number of columns.
    pub fn len(self: Row) usize {
        return self.values.len;
    }

    pub fn kind(self: Row, col: usize) error{ColumnOutOfRange}!Kind {
        if (col >= self.values.len) return error.ColumnOutOfRange;
        return @enumFromInt(self.values[col].kind);
    }

    pub fn isNull(self: Row, col: usize) error{ColumnOutOfRange}!bool {
        if (col >= self.values.len) return error.ColumnOutOfRange;
        return self.values[col].is_null != 0;
    }

    /// Value of column `col` (0-based) as `T`: `bool`, `i16`, `i32`, `i64`,
    /// `f32`, `f64` (the column must be exactly boolean, smallint, integer,
    /// bigint, real, double precision) or `[]const u8` (text-like, bytea, or
    /// the text representation of any other type); `?T` accepts SQL NULL.
    /// Never converts: a kind mismatch is `error.TypeMismatch`, NULL into a
    /// non-optional `error.UnexpectedNull`.
    pub fn get(self: Row, comptime T: type, col: usize) GetError!T {
        if (col >= self.values.len) return error.ColumnOutOfRange;
        const v = self.values[col];
        switch (@typeInfo(T)) {
            .optional => |o| {
                try checkKind(o.child, v.kind);
                if (v.is_null != 0) return null;
                return decodeValue(o.child, v);
            },
            else => {
                try checkKind(T, v.kind);
                if (v.is_null != 0) return error.UnexpectedNull;
                return decodeValue(T, v);
            },
        }
    }
};

fn checkKind(comptime T: type, k: u16) error{TypeMismatch}!void {
    const ok = switch (T) {
        bool => k == @intFromEnum(Kind.boolean),
        i16 => k == @intFromEnum(Kind.int2),
        i32 => k == @intFromEnum(Kind.int4),
        i64 => k == @intFromEnum(Kind.int8),
        f32 => k == @intFromEnum(Kind.float4),
        f64 => k == @intFromEnum(Kind.float8),
        []const u8 => k == @intFromEnum(Kind.text) or k == @intFromEnum(Kind.bytea) or
            k == @intFromEnum(Kind.other),
        else => @compileError("plzig: unsupported column type " ++ @typeName(T) ++
            " (use bool, i16, i32, i64, f32, f64 or []const u8, or an optional of one)"),
    };
    if (!ok) return error.TypeMismatch;
}

fn decodeValue(comptime T: type, v: Value) T {
    if (T == bool) return v.val != 0;
    if (T == i16) return @truncate(@as(i64, @bitCast(v.val)));
    if (T == i32) return @truncate(@as(i64, @bitCast(v.val)));
    if (T == i64) return @bitCast(v.val);
    if (T == f32) return @bitCast(@as(u32, @truncate(v.val)));
    if (T == f64) return @bitCast(v.val);
    if (T == []const u8) {
        if (v.len == 0) return &.{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v.val)));
        return p[0..v.len];
    }
    unreachable;
}

/// A reusable buffer in the arena: grows to the largest row seen, so
/// iterating any number of rows does not grow guest memory beyond that.
const Scratch = struct {
    buf: []align(8) u8 = &.{},

    fn ensure(self: *Scratch, n: usize) error{OutOfMemory}![]align(8) u8 {
        if (self.buf.len < n) {
            const want = @max(n, self.buf.len * 2, 256);
            // the arena reclaims the old buffer if nothing was allocated after it
            if (self.buf.len > 0) allocator.free(self.buf);
            self.buf = &.{};
            self.buf = try allocator.alignedAlloc(u8, .@"8", want);
        }
        return self.buf[0..n];
    }
};

/// scratch of Result.row; reset with the arena at the start of every call
var result_scratch: Scratch = .{};

fn rowFrom(buf: []align(8) u8, ncols: i32) Row {
    const n: usize = @intCast(ncols);
    if (n == 0) return .{ .values = &.{} };
    const vals: [*]const Value = @ptrCast(buf.ptr);
    return .{ .values = vals[0..n] };
}

/// Result of `spi.execute` and `Plan.execute`. Only the most recent result
/// is accessible: executing another statement invalidates earlier `Result`s.
pub const Result = struct {
    /// Number of rows processed (rows returned for SELECT, affected for DML).
    rows: u64,
    /// Number of columns in the returned rows (0 for statements without result rows).
    columns: u32,

    /// Text value of column `col` in row `row` (both 0-based), or null for
    /// SQL NULL, copied into the per-call arena.
    pub fn get(self: Result, row_index: u64, col: u32) error{OutOfMemory}!?[]const u8 {
        _ = self;
        const r: u32 = @intCast(@min(row_index, 0xffff_ffff));
        const n = host.spi_value_len(r, col);
        if (n < 0) return null;
        const buf = try allocator.alloc(u8, @intCast(n));
        if (buf.len > 0) {
            const got = host.spi_value_copy(r, col, buf.ptr, @intCast(buf.len));
            if (got != n) raiseMsg("plzig: SPI value changed size during copy");
        }
        return buf;
    }

    /// Row `row_index` (0-based) with typed access (`row.get(i32, 0)`).
    /// The Row is valid until the next call of `row` on any Result.
    pub fn row(self: Result, row_index: u64) error{OutOfMemory}!Row {
        _ = self;
        const r: u32 = @intCast(@min(row_index, 0xffff_ffff));
        const n = host.spi_row_size(r);
        const buf = try result_scratch.ensure(@intCast(n));
        const ncols = host.spi_row_read(r, buf.ptr, @intCast(buf.len));
        return rowFrom(buf, ncols);
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

/// A cursor: rows are fetched one at a time (the host fetches them from the
/// portal in small batches). Forward only. Cursors never outlive the
/// function call: the host closes every cursor still open when the call
/// returns or fails. Reaching the end closes the cursor; `close` may be
/// called any number of times.
pub const Cursor = struct {
    handle: u64,
    state: enum { open, finished, closed } = .open,
    scratch: Scratch = .{},

    /// The next row, or null at the end. The Row and every slice obtained
    /// from it are invalid after the next call of `next`.
    pub fn next(self: *Cursor) error{ OutOfMemory, CursorClosed }!?Row {
        switch (self.state) {
            .open => {},
            .finished => return null,
            .closed => return error.CursorClosed,
        }
        const n = host.spi_cursor_next(self.handle);
        if (n < 0) {
            host.spi_cursor_close(self.handle);
            self.state = .finished;
            return null;
        }
        const buf = try self.scratch.ensure(@intCast(n));
        const ncols = host.spi_cursor_read(self.handle, buf.ptr, @intCast(buf.len));
        return rowFrom(buf, ncols);
    }

    pub fn close(self: *Cursor) void {
        if (self.state == .open) host.spi_cursor_close(self.handle);
        self.state = .closed;
    }
};

/// A prepared statement. It belongs to the function instance that prepared
/// it and may be kept in a global for later calls (globals persist per
/// function per session; an instance that raised an error starts over, and
/// its prepared statements are freed). At most `plzig.max_prepared_plans`
/// may exist per instance; `free` releases one.
pub const Plan = struct {
    handle: u64,

    /// Execute with parameters `args`, a tuple whose element types must
    /// match the declared parameter types: bool, i16, i32, i64, f32, f64,
    /// a byte slice or string literal (text), `plzig.bytea(...)` (bytea),
    /// an optional of one of these, or `null`.
    pub fn execute(self: Plan, args: anytype) error{OutOfMemory}!Result {
        var vals: [paramCount(@TypeOf(args))]Value = undefined;
        encodeParams(args, &vals);
        const n = host.spi_execute_plan(self.handle, &vals, vals.len);
        return .{ .rows = @intCast(n), .columns = host.spi_ncols() };
    }

    /// Open a cursor over the prepared statement (see `execute` for `args`).
    pub fn open(self: Plan, args: anytype) error{OutOfMemory}!Cursor {
        var vals: [paramCount(@TypeOf(args))]Value = undefined;
        encodeParams(args, &vals);
        return .{ .handle = host.spi_cursor_open_plan(self.handle, &vals, vals.len) };
    }

    /// Free the prepared statement; the handle is invalid afterwards.
    pub fn free(self: *Plan) void {
        if (self.handle != 0) host.spi_plan_free(self.handle);
        self.handle = 0;
    }
};

fn paramCount(comptime Args: type) usize {
    const ti = @typeInfo(Args);
    if (ti != .@"struct" or !ti.@"struct".is_tuple)
        @compileError("plzig: parameters must be a tuple, e.g. .{ @as(i32, 1), \"text\" }");
    return ti.@"struct".field_names.len;
}

fn encodeParams(args: anytype, out: []Value) void {
    inline for (0..comptime paramCount(@TypeOf(args))) |i| {
        out[i] = encodeParam(args[i]);
    }
}

fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn paramKind(comptime T: type) u16 {
    if (T == bool) return @intFromEnum(Type.boolean);
    if (T == i16) return @intFromEnum(Type.int2);
    if (T == i32) return @intFromEnum(Type.int4);
    if (T == i64) return @intFromEnum(Type.int8);
    if (T == f32) return @intFromEnum(Type.float4);
    if (T == f64) return @intFromEnum(Type.float8);
    if (T == Bytea) return @intFromEnum(Type.bytea);
    if (comptime isBytes(T)) return @intFromEnum(Type.text);
    if (T == comptime_int or T == comptime_float)
        @compileError("plzig: give numeric parameter literals a type, e.g. @as(i32, 5)");
    @compileError("plzig: unsupported parameter type " ++ @typeName(T));
}

fn encodeParam(v: anytype) Value {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .null => return .{ .val = 0, .len = 0, .kind = 0, .is_null = 1 },
        .optional => |o| {
            if (v) |x| return encodeParam(@as(o.child, x));
            return .{ .val = 0, .len = 0, .kind = paramKind(o.child), .is_null = 1 };
        },
        else => {},
    }
    const k = paramKind(T);
    if (T == bool) return .{ .val = @intFromBool(v), .len = 0, .kind = k, .is_null = 0 };
    if (T == i16 or T == i32 or T == i64)
        return .{ .val = @bitCast(@as(i64, v)), .len = 0, .kind = k, .is_null = 0 };
    if (T == f32) return .{ .val = @as(u32, @bitCast(v)), .len = 0, .kind = k, .is_null = 0 };
    if (T == f64) return .{ .val = @bitCast(v), .len = 0, .kind = k, .is_null = 0 };
    const b: []const u8 = if (T == Bytea) v.bytes else v;
    return .{ .val = @intFromPtr(b.ptr), .len = @intCast(b.len), .kind = k, .is_null = 0 };
}

fn textSlots(params: []const ?[]const u8) error{OutOfMemory}![]Slot {
    const slots = try allocator.alloc(Slot, params.len);
    for (params, slots) |p, *slot| {
        if (p) |v| {
            slot.* = .{ .val = @intFromPtr(v.ptr), .len = @intCast(v.len), .is_null = 0 };
        } else {
            slot.* = .{ .val = 0, .len = 0, .is_null = 1 };
        }
    }
    return slots;
}

pub const spi = struct {
    pub const Plan = plzig_root.Plan;
    pub const Cursor = plzig_root.Cursor;
    pub const Result = plzig_root.Result;
    pub const Row = plzig_root.Row;
    pub const Type = plzig_root.Type;
    pub const Kind = plzig_root.Kind;

    /// Execute an SQL statement with text parameters `$1..$n` (pass `null` for
    /// SQL NULL; cast in SQL, e.g. `$1::int`). Runs with the privileges of the
    /// current user, read-only unless the function is VOLATILE. Any SQL error
    /// aborts the whole function call; it cannot be caught.
    pub fn execute(sql: []const u8, params: []const ?[]const u8) error{OutOfMemory}!plzig_root.Result {
        const slots = try textSlots(params);
        defer allocator.free(slots);
        const n = host.spi_execute(sql.ptr, @intCast(sql.len), slots.ptr, @intCast(slots.len));
        return .{ .rows = @intCast(n), .columns = host.spi_ncols() };
    }

    /// Prepare a statement with parameters `$1..$n` of the given types
    /// (`.int4`, `.text`, ...). See `Plan`.
    pub fn prepare(sql: []const u8, types: []const plzig_root.Type) error{OutOfMemory}!plzig_root.Plan {
        const h = host.spi_prepare(sql.ptr, @intCast(sql.len), @ptrCast(types.ptr), @intCast(types.len));
        return .{ .handle = h };
    }

    /// Open a cursor over an SQL query with text parameters (as `execute`).
    pub fn open(sql: []const u8, params: []const ?[]const u8) error{OutOfMemory}!plzig_root.Cursor {
        const slots = try textSlots(params);
        defer allocator.free(slots);
        return .{ .handle = host.spi_cursor_open(sql.ptr, @intCast(sql.len), slots.ptr, @intCast(slots.len)) };
    }
};

const plzig_root = @This();
