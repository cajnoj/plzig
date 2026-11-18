//! Stand-in for the wasm environment of the guest SDK, for the native unit
//! tests only (zig/sdk/test.zig).  plzig.zig uses this module instead of the
//! real host imports and wasm memory builtins when built by `zig test`; it
//! is never copied into a function build and never installed.
//!
//! Linear memory is simulated by a mapping at a fixed address below 4 GB,
//! so that guest addresses fit in 32 bits exactly as in wasm32 (root.zig
//! converts pointers to u32).  The SPI imports serve rows from an in-memory
//! table and encode them as described in doc/abi.md ("Value", rows), the
//! format src/plzig_host.c (rowbuf_write) produces.

const std = @import("std");
const plzig = @import("plzig");
const linux = std.os.linux;

const Slot = plzig.Slot;
const Value = plzig.Value;

pub const page: usize = 65536;

/// Where the simulated linear memory starts, and how far it may grow.
pub var memory_base: usize = 0;
var pages: usize = 0;
var max_pages: usize = 0;
var reserved_pages: usize = 0;
pub var grow_calls: usize = 0;

/// Map `reserve` pages at a fixed low address; `initial` of them count as
/// the module's initial memory, growth stops at `limit` (plzig.max_memory).
pub fn initMemory(initial: usize, limit: usize, reserve: usize) !void {
    if (memory_base == 0) {
        const want: usize = 0x4000_0000;
        const rc = linux.mmap(@ptrFromInt(want), reserve * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS or rc != want) return error.MapFailed;
        memory_base = want;
        reserved_pages = reserve;
    }
    std.debug.assert(limit <= reserved_pages);
    pages = initial;
    max_pages = limit;
    grow_calls = 0;
}

pub fn setLimit(limit: usize) void {
    std.debug.assert(limit <= reserved_pages);
    max_pages = limit;
}

pub fn memoryPages() usize {
    return pages;
}

pub fn memoryGrow(n: usize) isize {
    grow_calls += 1;
    if (n > max_pages or pages + n > max_pages) return -1;
    const old = pages;
    pages += n;
    return @intCast(old);
}

// ---------------------------------------------------------------------------
// SPI: rows served by the simulated host

pub const Col = union(enum) {
    null_of: plzig.Kind,
    boolean: bool,
    int2: i16,
    int4: i32,
    int8: i64,
    float4: f32,
    float8: f64,
    text: []const u8,
    bytea: []const u8,
    other: []const u8,
    /// any other kind, as the host would write it: `bytes` (if not null)
    /// after the values, else `val`/`len` in the Value itself
    raw: struct { kind: plzig.Kind, val: u64 = 0, len: u32 = 0, bytes: ?[]const u8 = null },

    fn kind(c: Col) u16 {
        return switch (c) {
            .null_of => |k| @intFromEnum(k),
            .boolean => 1,
            .int2 => 2,
            .int4 => 3,
            .int8 => 4,
            .float4 => 5,
            .float8 => 6,
            .text => 7,
            .bytea => 8,
            .other => 9,
            .raw => |r| @intFromEnum(r.kind),
        };
    }

    fn bytes(c: Col) ?[]const u8 {
        return switch (c) {
            .text, .bytea, .other => |b| b,
            .raw => |r| r.bytes,
            else => null,
        };
    }
};

pub var rows: []const []const Col = &.{};
pub var column_names: []const []const u8 = &.{};
pub var last_sql: [256]u8 = undefined;
pub var last_sql_len: usize = 0;
pub var last_slots: [16]Slot = undefined;
pub var last_nslots: usize = 0;
pub var last_values: [16]Value = undefined;
pub var last_nvalues: usize = 0;
pub var last_kinds: [16]u32 = undefined;
pub var last_nkinds: usize = 0;
pub var last_log: [256]u8 = undefined;
pub var last_log_len: usize = 0;
pub var last_log_level: u32 = 0;
pub var cursor_pos: usize = 0;
pub var cursor_pending: bool = false;
pub var cursor_closes: usize = 0;
/// spi_cursor_fetch calls, and rows taken from the (simulated) portal
pub var fetch_calls: usize = 0;
pub var rows_taken: usize = 0;
pub var plans_freed: usize = 0;
pub var srf_rows: usize = 0;
pub var xact_ends: usize = 0;

pub fn reset() void {
    rows = &.{};
    column_names = &.{};
    last_sql_len = 0;
    last_nslots = 0;
    last_nvalues = 0;
    last_nkinds = 0;
    last_log_len = 0;
    cursor_pos = 0;
    cursor_pending = false;
    cursor_closes = 0;
    fetch_calls = 0;
    rows_taken = 0;
    plans_freed = 0;
    srf_rows = 0;
    xact_ends = 0;
}

fn align8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

fn rowSize(row: []const Col) usize {
    var size: usize = row.len * @sizeOf(Value);
    for (row) |c| {
        if (c.bytes()) |b| size += align8(b.len);
    }
    return size;
}

/// The encoding of src/plzig_host.c rowbuf_write: one Value per column, then
/// the bytes of the byte-kind columns, 8-byte aligned, addressed by val.
fn writeRow(row: []const Col, buf: [*]u8, buf_len: u32) i32 {
    const size = rowSize(row);
    std.debug.assert(buf_len >= size);
    if (size == 0) return 0;
    const base = @intFromPtr(buf);
    var off: usize = row.len * @sizeOf(Value);
    for (row, 0..) |c, i| {
        var val: Value = .{ .val = 0, .len = 0, .kind = c.kind(), .is_null = 0 };
        switch (c) {
            .null_of => val.is_null = 1,
            .boolean => |b| val.val = @intFromBool(b),
            .int2 => |x| val.val = @bitCast(@as(i64, x)),
            .int4 => |x| val.val = @bitCast(@as(i64, x)),
            .int8 => |x| val.val = @bitCast(x),
            .float4 => |x| val.val = @as(u32, @bitCast(x)),
            .float8 => |x| val.val = @bitCast(x),
            .text, .bytea, .other => |b| {
                val.len = @intCast(b.len);
                val.val = base + off;
                @memcpy(buf[off..][0..b.len], b);
                off += align8(b.len);
            },
            .raw => |r| if (r.bytes) |b| {
                val.len = @intCast(b.len);
                val.val = base + off;
                @memcpy(buf[off..][0..b.len], b);
                off += align8(b.len);
            } else {
                val.val = r.val;
                val.len = r.len;
            },
        }
        @memcpy(buf[i * @sizeOf(Value) ..][0..@sizeOf(Value)], std.mem.asBytes(&val));
    }
    return @intCast(row.len);
}

fn textOf(c: Col, out: []u8) ?[]const u8 {
    return switch (c) {
        .null_of => null,
        .boolean => |b| if (b) "t" else "f",
        .int2 => |x| std.fmt.bufPrint(out, "{d}", .{x}) catch unreachable,
        .int4 => |x| std.fmt.bufPrint(out, "{d}", .{x}) catch unreachable,
        .int8 => |x| std.fmt.bufPrint(out, "{d}", .{x}) catch unreachable,
        .float4 => |x| std.fmt.bufPrint(out, "{d}", .{x}) catch unreachable,
        .float8 => |x| std.fmt.bufPrint(out, "{d}", .{x}) catch unreachable,
        .text, .bytea, .other => |b| b,
        .raw => "raw",
    };
}

/// The host imports.  Each must have the type abi/plzig-abi.table gives it
/// (a compile-time check in plzig.zig, region "import-types").
pub const host = struct {
    pub fn log(level: u32, ptr: [*]const u8, len: u32) void {
        last_log_level = level;
        last_log_len = @min(len, last_log.len);
        @memcpy(last_log[0..last_log_len], ptr[0..last_log_len]);
    }

    pub fn raise(ptr: [*]const u8, len: u32) void {
        std.debug.panic("plzig.raise in a unit test: {s}", .{ptr[0..len]});
    }

    pub fn raise_error(code_ptr: [*]const u8, code_len: u32, msg_ptr: [*]const u8, msg_len: u32, detail_ptr: [*]const u8, detail_len: u32, hint_ptr: [*]const u8, hint_len: u32) void {
        std.debug.panic("plzig.raiseError in a unit test: {s} {s} ({s}; {s})", .{ code_ptr[0..code_len], msg_ptr[0..msg_len], detail_ptr[0..detail_len], hint_ptr[0..hint_len] });
    }

    pub fn panic(ptr: [*]const u8, len: u32) void {
        std.debug.panic("plzig panic in a unit test: {s}", .{ptr[0..len]});
    }

    fn recordSql(sql_ptr: [*]const u8, sql_len: u32) void {
        last_sql_len = @min(sql_len, last_sql.len);
        @memcpy(last_sql[0..last_sql_len], sql_ptr[0..last_sql_len]);
    }

    fn recordSlots(params_ptr: [*]const Slot, n: u32) void {
        last_nslots = n;
        for (0..@min(n, last_slots.len)) |i| last_slots[i] = params_ptr[i];
    }

    fn recordValues(params_ptr: [*]const Value, n: u32) void {
        last_nvalues = n;
        for (0..@min(n, last_values.len)) |i| last_values[i] = params_ptr[i];
    }

    pub fn spi_execute(sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const Slot, nparams: u32) i64 {
        recordSql(sql_ptr, sql_len);
        recordSlots(params_ptr, nparams);
        return @intCast(rows.len);
    }

    pub fn commit() void {
        xact_ends += 1;
    }

    pub fn rollback() void {
        xact_ends += 1;
    }

    /// srf_return_next: records the row (like a prepared statement's values)
    pub fn srf_return_next(values_ptr: [*]const Value, n: u32) void {
        recordValues(values_ptr, n);
        srf_rows += 1;
    }

    pub fn spi_ncols() u32 {
        return if (rows.len > 0) @intCast(rows[0].len) else @intCast(column_names.len);
    }

    pub fn spi_value_len(row: u32, col: u32) i32 {
        var tmp: [64]u8 = undefined;
        const t = textOf(rows[row][col], &tmp) orelse return -1;
        return @intCast(t.len);
    }

    pub fn spi_value_copy(row: u32, col: u32, buf: [*]u8, buf_len: u32) i32 {
        var tmp: [64]u8 = undefined;
        const t = textOf(rows[row][col], &tmp) orelse return -1;
        const n = @min(t.len, buf_len);
        @memcpy(buf[0..n], t[0..n]);
        return @intCast(n);
    }

    pub fn spi_colname_len(col: u32) i32 {
        if (col >= column_names.len) return -1;
        return @intCast(column_names[col].len);
    }

    pub fn spi_colname_copy(col: u32, buf: [*]u8, buf_len: u32) i32 {
        const n = @min(column_names[col].len, buf_len);
        @memcpy(buf[0..n], column_names[col][0..n]);
        return @intCast(n);
    }

    pub fn spi_row_size(row: u32) i64 {
        return @intCast(rowSize(rows[row]));
    }

    pub fn spi_row_read(row: u32, buf: [*]u8, buf_len: u32) i32 {
        return writeRow(rows[row], buf, buf_len);
    }

    pub fn spi_prepare(sql_ptr: [*]const u8, sql_len: u32, kinds_ptr: [*]const u32, nkinds: u32) u64 {
        recordSql(sql_ptr, sql_len);
        last_nkinds = nkinds;
        for (0..@min(nkinds, last_kinds.len)) |i| last_kinds[i] = kinds_ptr[i];
        return 0x1234_0001;
    }

    pub fn spi_plan_free(handle: u64) void {
        std.debug.assert(handle == 0x1234_0001);
        plans_freed += 1;
    }

    pub fn spi_execute_plan(handle: u64, params_ptr: [*]const Value, nparams: u32) i64 {
        std.debug.assert(handle == 0x1234_0001);
        recordValues(params_ptr, nparams);
        return @intCast(rows.len);
    }

    pub fn spi_cursor_open(sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const Slot, nparams: u32) u64 {
        recordSql(sql_ptr, sql_len);
        recordSlots(params_ptr, nparams);
        cursor_pos = 0;
        cursor_pending = false;
        return 0x77_0003;
    }

    pub fn spi_cursor_open_plan(handle: u64, params_ptr: [*]const Value, nparams: u32) u64 {
        std.debug.assert(handle == 0x1234_0001);
        recordValues(params_ptr, nparams);
        cursor_pos = 0;
        cursor_pending = false;
        return 0x77_0003;
    }

    /// as src/plzig_host.c host_spi_cursor_fetch: the next row (or the
    /// current one, if it did not fit last time) is written if it fits;
    /// returns ncols << 32 | size, or -1 at the end
    pub fn spi_cursor_fetch(cursor: u64, buf: [*]u8, buf_len: u32) i64 {
        std.debug.assert(cursor == 0x77_0003);
        fetch_calls += 1;
        if (!cursor_pending) {
            if (cursor_pos >= rows.len) return -1;
            cursor_pos += 1;
            rows_taken += 1;
            cursor_pending = true;
        }
        const row = rows[cursor_pos - 1];
        const size = rowSize(row);
        if (size <= buf_len) {
            _ = writeRow(row, buf, buf_len);
            cursor_pending = false;
        }
        return @intCast((@as(u64, row.len) << 32) | size);
    }

    pub fn spi_cursor_close(cursor: u64) void {
        std.debug.assert(cursor == 0x77_0003);
        cursor_closes += 1;
    }

    /// as src/plzig_host.c host_tz_convert, with a fake zone: one hour
    /// east of UTC, whatever the name (infinities stay infinities)
    pub fn tz_convert(op: u32, value: i64, zone_ptr: [*]const u8, zone_len: u32) i64 {
        last_tz_op = op;
        last_tz_zone_len = @min(zone_len, last_tz_zone.len);
        @memcpy(last_tz_zone[0..last_tz_zone_len], zone_ptr[0..last_tz_zone_len]);
        if (value == std.math.maxInt(i64) or value == std.math.minInt(i64)) return value;
        return if (op == 1) value + 3_600_000_000 else value - 3_600_000_000;
    }

    /// as src/plzig_host.c host_numeric_op, with a fake operation: the
    /// result is operand a (or b for op 2) unchanged; -len if it does not fit
    pub fn numeric_op(op: u32, a_ptr: [*]const u8, a_len: u32, b_ptr: [*]const u8, b_len: u32, arg: i32, out_ptr: [*]u8, out_cap: u32) i32 {
        numeric_calls += 1;
        last_numeric_op = op;
        last_numeric_arg = arg;
        const r = if (op == 2) b_ptr[0..b_len] else a_ptr[0..a_len];
        if (r.len > out_cap) return -@as(i32, @intCast(r.len));
        @memcpy(out_ptr[0..r.len], r);
        return @intCast(r.len);
    }
};

pub var numeric_calls: usize = 0;
pub var last_tz_op: u32 = 0;
pub var last_tz_zone: [64]u8 = undefined;
pub var last_tz_zone_len: usize = 0;
pub var last_numeric_op: u32 = 0;
pub var last_numeric_arg: i32 = 0;
