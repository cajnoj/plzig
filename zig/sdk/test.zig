//! Native unit tests of the guest SDK: the production zig/sdk/plzig.zig and
//! zig/sdk/root.zig, with the host imports and wasm memory replaced by
//! zig/sdk/test_env.zig and the user function by zig/sdk/test_user.zig.
//!
//!   make check-zig

const std = @import("std");
const plzig = @import("plzig");
const sdk_root = @import("sdk_root");
const env = @import("plzig_test_env");
const user = @import("user");
const testing = std.testing;

const Value = plzig.Value;
const Slot = plzig.Slot;
const Col = env.Col;
const page = env.page;
const a = plzig.allocator;

// the exports of root.zig, linked into this test binary
extern fn plzig_abi_version() u32;
extern fn plzig_init() u64;
extern fn plzig_alloc_args(len: u32) u32;
extern fn plzig_call(args: [*]const Slot, nargs: u32, result: *Slot, begin: u32) u32;

/// what the start of a call does to the arena (plzig_call with begin = 1,
/// or plzig_alloc_args)
fn plzig_begin() void {
    plzig.resetArena();
}

/// Fresh simulated instance memory: 2 initial pages, growth up to `limit`
/// pages (plzig.max_memory), and an empty arena.
fn setup(limit: usize) !void {
    try env.initMemory(2, limit, 4096);
    env.reset();
    plzig_begin();
}

fn heapStart() usize {
    return env.memory_base + 2 * page;
}

/// address the next small 1-aligned allocation would get
fn top() usize {
    const p = a.rawAlloc(1, .@"1", 0).?;
    a.rawFree(p[0..1], .@"1", 0);
    return @intFromPtr(p);
}

// ---------------------------------------------------------------------------
// Arena allocator

test "abi version" {
    try testing.expectEqual(@as(u32, 4), plzig_abi_version());
    try testing.expectEqual(plzig.abi_version, plzig_abi_version());
}

test "arena: the heap starts above the initial memory" {
    try setup(64);
    try testing.expectEqual(heapStart(), top());
}

test "arena: every alignment up to the page size" {
    try setup(64);
    var shift: u6 = 0;
    while (shift <= 16) : (shift += 1) {
        const al: usize = @as(usize, 1) << shift;
        // misalign the top first
        _ = a.rawAlloc(1, .@"1", 0).?;
        const p = a.rawAlloc(24, std.mem.Alignment.fromByteUnits(al), 0) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(p) % al);
        @memset(p[0..24], 0xAA);
    }
    // typed allocations honour their natural alignment too
    const x = try a.alloc(u64, 3);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(x.ptr) % 8);
    const y = try a.alignedAlloc(u8, .fromByteUnits(4096), 1);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(y.ptr) % 4096);
}

test "arena: growth asks the host for exactly the pages needed" {
    try setup(64);
    try testing.expectEqual(@as(usize, 2), env.memoryPages());
    const buf = try a.alloc(u8, 3 * page + 1);
    @memset(buf, 1);
    try testing.expectEqual(@as(usize, 2 + 4), env.memoryPages());
    try testing.expectEqual(@as(usize, 1), env.grow_calls);
    // memory that is already there is used without growing
    plzig_begin();
    const again = try a.alloc(u8, 3 * page);
    @memset(again, 2);
    try testing.expectEqual(@as(usize, 1), env.grow_calls);
}

test "arena: resize in place vs. move" {
    try setup(64);
    const first = try a.alloc(u8, 100);
    @memset(first, 7);
    // the most recent allocation grows and shrinks in place
    try testing.expect(a.resize(first, 1000));
    try testing.expect(a.resize(first.ptr[0..1000], 50));
    const second = try a.alloc(u8, 10);
    // an older allocation cannot grow in place ...
    try testing.expect(!a.resize(first.ptr[0..50], 51));
    // ... but can shrink (the space is not reclaimed)
    try testing.expect(a.resize(first.ptr[0..50], 20));
    try testing.expectEqual(@intFromPtr(second.ptr) + 10, top());
    // realloc of an older allocation moves it and keeps the contents
    const moved = try a.realloc(first.ptr[0..20], 4000);
    try testing.expect(moved.ptr != first.ptr);
    for (moved[0..20]) |c| try testing.expectEqual(@as(u8, 7), c);
    // realloc of the newest one stays put
    const same = try a.realloc(moved, 8000);
    try testing.expectEqual(moved.ptr, same.ptr);
    // remap follows resize
    try testing.expect(a.remap(same, 9000) != null);
    try testing.expect(a.remap(second, 11) == null);
}

test "arena: free reclaims only the most recent allocation" {
    try setup(64);
    const x = try a.alloc(u8, 64);
    const y = try a.alloc(u8, 64);
    a.free(x); // not the newest: nothing happens
    const z = try a.alloc(u8, 1);
    try testing.expect(@intFromPtr(z.ptr) >= @intFromPtr(y.ptr) + 64);
    a.free(z);
    a.free(y);
    // y and z were reclaimed, x was not
    try testing.expectEqual(@intFromPtr(y.ptr), top());
}

test "arena: zero-size allocations take no space" {
    try setup(64);
    const before = top();
    const e = try a.alloc(u8, 0);
    try testing.expectEqual(@as(usize, 0), e.len);
    const e2 = try a.alloc(u64, 0);
    try testing.expectEqual(@as(usize, 0), e2.len);
    a.free(e);
    a.free(e2);
    try testing.expectEqual(before, top());
    // a zero-length raw allocation is a valid (empty) pointer at the top
    const p = a.rawAlloc(0, .@"8", 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 8);
}

test "arena: reset at the start of every call releases everything" {
    try setup(64);
    const first = try a.alloc(u8, 10);
    _ = try a.alloc(u8, 2 * page);
    plzig_begin();
    const again = try a.alloc(u8, 10);
    try testing.expectEqual(first.ptr, again.ptr);
    try testing.expectEqual(heapStart(), @intFromPtr(again.ptr));
    // and memory, once grown, stays (it belongs to the instance)
    try testing.expect(env.memoryPages() > 2);
}

test "arena: exhaustion at the memory cap is error.OutOfMemory, and the arena stays usable" {
    try setup(8); // 512 kB cap, 2 pages initial
    const before = top();
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 8 * page));
    try testing.expectEqual(before, top());
    // exactly what fits
    const fit = try a.alloc(u8, 6 * page);
    @memset(fit, 3);
    try testing.expectEqual(@as(usize, 8), env.memoryPages());
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    // resize beyond the cap fails, the allocation is unchanged
    try testing.expect(!a.resize(fit, 6 * page + 1));
    plzig_begin();
    _ = try a.alloc(u8, 100);
}

test "arena: size arithmetic cannot overflow" {
    try setup(64);
    const before = top();
    const grows = env.grow_calls;
    try testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize)));
    try testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize) - 4096));
    try testing.expectError(error.OutOfMemory, a.alloc(u64, std.math.maxInt(usize) / 8));
    try testing.expect(a.rawAlloc(std.math.maxInt(usize) - 3, .@"8", 0) == null);
    try testing.expect(a.rawAlloc(std.math.maxInt(usize), .fromByteUnits(65536), 0) == null);
    // more than the 4 GB a wasm32 memory can have: refused without asking the host
    try testing.expect(a.rawAlloc(1 << 32, .@"1", 0) == null);
    try testing.expect(a.rawAlloc((1 << 32) - 1, .@"1", 0) == null);
    try testing.expectEqual(grows, env.grow_calls);
    // resize of the newest allocation to an impossible size
    const x = try a.alloc(u8, 16);
    try testing.expect(!a.resize(x, std.math.maxInt(usize)));
    try testing.expect(!a.resize(x, 1 << 32));
    a.free(x);
    try testing.expectEqual(before, top());
}

test "plzig_alloc_args: resets the arena, 8-byte aligned guest addresses, 0 on failure" {
    try setup(8);
    _ = a.rawAlloc(3, .@"1", 0);
    const p = plzig_alloc_args(100);
    try testing.expect(p != 0);
    try testing.expectEqual(@as(u32, 0), p % 8);
    // the block is the first thing in the freshly reset arena
    try testing.expectEqual(heapStart(), @as(usize, p));
    try testing.expectEqual(heapStart() + 100, top());
    try testing.expectEqual(@as(u32, 0), plzig_alloc_args(std.math.maxInt(u32)));
    try testing.expectEqual(@as(u32, 0), plzig_alloc_args(8 * page));
    // a failed allocation still started the call: the arena is empty
    try testing.expectEqual(heapStart(), top());
}

test "plzig_init: the argument buffer, outside the arena" {
    try setup(64);
    const v = plzig_init();
    const addr: usize = @intCast(v & 0xffff_ffff);
    const cap: usize = @intCast(v >> 32);
    try testing.expectEqual(@as(usize, plzig.arg_buffer_size), cap);
    try testing.expectEqual(@as(usize, 0), addr % 8);
    try testing.expect(addr != 0);
    // not in the arena: arena allocations never overlap it
    const x = try a.alloc(u8, 2 * page);
    try testing.expect(addr + cap <= @intFromPtr(x.ptr) or addr >= @intFromPtr(x.ptr) + x.len);
    // the same buffer every time
    try testing.expectEqual(v, plzig_init());
}

// ---------------------------------------------------------------------------
// Typed rows (Row.get) for every kind

fn row(cols: []const Col) !plzig.Row {
    env.rows = &.{cols};
    const r: plzig.spi.Result = .{ .rows = 1, .columns = @intCast(cols.len) };
    return r.row(0);
}

test "Row.get: every kind, NULLs and empty values" {
    try setup(64);
    const cols = [_]Col{
        .{ .boolean = true },          .{ .boolean = false },
        .{ .int2 = -32768 },           .{ .int2 = 32767 },
        .{ .int4 = std.math.minInt(i32) }, .{ .int4 = -1 },
        .{ .int8 = std.math.minInt(i64) }, .{ .int8 = std.math.maxInt(i64) },
        .{ .float4 = -0.0 },           .{ .float4 = std.math.inf(f32) },
        .{ .float8 = std.math.nan(f64) }, .{ .float8 = -std.math.inf(f64) },
        .{ .text = "héllo" },          .{ .text = "" },
        .{ .bytea = "\x00\xff\x01" },  .{ .bytea = "" },
        .{ .other = "{1,2,3}" },       .{ .other = "" },
        .{ .null_of = .int4 },         .{ .null_of = .text },
        .{ .text = "abcdefghi" },
    };
    const r = try row(&cols);
    try testing.expectEqual(cols.len, r.len());
    try testing.expectEqual(true, try r.get(bool, 0));
    try testing.expectEqual(false, try r.get(bool, 1));
    try testing.expectEqual(@as(i16, -32768), try r.get(i16, 2));
    try testing.expectEqual(@as(i16, 32767), try r.get(i16, 3));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), try r.get(i32, 4));
    try testing.expectEqual(@as(i32, -1), try r.get(i32, 5));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try r.get(i64, 6));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try r.get(i64, 7));
    const nz = try r.get(f32, 8);
    try testing.expect(nz == 0 and std.math.signbit(nz));
    try testing.expect(std.math.isPositiveInf(try r.get(f32, 9)));
    try testing.expect(std.math.isNan(try r.get(f64, 10)));
    try testing.expect(std.math.isNegativeInf(try r.get(f64, 11)));
    try testing.expectEqualStrings("héllo", try r.get([]const u8, 12));
    try testing.expectEqual(@as(usize, 0), (try r.get([]const u8, 13)).len);
    try testing.expectEqualSlices(u8, "\x00\xff\x01", try r.get([]const u8, 14));
    try testing.expectEqual(@as(usize, 0), (try r.get([]const u8, 15)).len);
    try testing.expectEqualStrings("{1,2,3}", try r.get([]const u8, 16));
    try testing.expectEqual(@as(usize, 0), (try r.get([]const u8, 17)).len);
    // NULL: null through an optional, an error otherwise
    try testing.expectEqual(@as(?i32, null), try r.get(?i32, 18));
    try testing.expectError(error.UnexpectedNull, r.get(i32, 18));
    try testing.expectEqual(@as(?[]const u8, null), try r.get(?[]const u8, 19));
    try testing.expectError(error.UnexpectedNull, r.get([]const u8, 19));
    try testing.expect(try r.isNull(18));
    try testing.expect(!try r.isNull(17));
    try testing.expectEqual(plzig.Kind.int4, try r.kind(18));
    // optionals of non-NULL values
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), try r.get(?i64, 7));
    try testing.expectEqualStrings("abcdefghi", (try r.get(?[]const u8, 20)).?);
    // out of range
    try testing.expectError(error.ColumnOutOfRange, r.get(i32, cols.len));
    try testing.expectError(error.ColumnOutOfRange, r.get(?i32, 1000));
    try testing.expectError(error.ColumnOutOfRange, r.kind(cols.len));
    try testing.expectError(error.ColumnOutOfRange, r.isNull(cols.len));
}

test "Row.get never converts: every (type, kind) combination" {
    try setup(64);
    const samples = [_]Col{
        .{ .boolean = true }, .{ .int2 = 1 },      .{ .int4 = 1 },     .{ .int8 = 1 },
        .{ .float4 = 1 },     .{ .float8 = 1 },    .{ .text = "1" },   .{ .bytea = "1" },
        .{ .other = "1" },
    };
    const r = try row(&samples);
    const Types = .{ bool, i16, i32, i64, f32, f64, []const u8 };
    // which kinds (1..9) each type accepts
    const ok = [_][]const u16{ &.{1}, &.{2}, &.{3}, &.{4}, &.{5}, &.{6}, &.{ 7, 8, 9 } };
    try everyCombination(r, &samples, Types, &ok);
    // a NULL of a mismatching kind is a mismatch, not null
    const n = try row(&.{.{ .null_of = .text }});
    try testing.expectError(error.TypeMismatch, n.get(?i32, 0));
    try testing.expectEqual(@as(?[]const u8, null), try n.get(?[]const u8, 0));
}

test "Row.get never converts: the fixed-width SDK types against every kind" {
    try setup(64);
    const sixteen = "0123456789abcdef";
    const samples = [_]Col{
        .{ .boolean = true },                         .{ .int2 = 1 },
        .{ .int4 = 1 },                               .{ .int8 = 1 },
        .{ .float4 = 1 },                             .{ .float8 = 1 },
        .{ .text = "1" },                             .{ .bytea = "1" },
        .{ .other = "1" },                            .{ .raw = .{ .kind = .date, .val = 1 } },
        .{ .raw = .{ .kind = .time, .val = 1 } },     .{ .raw = .{ .kind = .timetz, .val = 1, .len = 3600 } },
        .{ .raw = .{ .kind = .timestamp, .val = 1 } }, .{ .raw = .{ .kind = .timestamptz, .val = 1 } },
        .{ .raw = .{ .kind = .interval, .bytes = sixteen } }, .{ .raw = .{ .kind = .uuid, .bytes = sixteen } },
        .{ .raw = .{ .kind = .oid, .val = 1 } },
    };
    const r = try row(&samples);
    const Types = .{ bool, i64, []const u8, plzig.Date, plzig.Time, plzig.TimeTz, plzig.Timestamp, plzig.TimestampTz, plzig.Interval, plzig.Uuid, plzig.Oid };
    const ok = [_][]const u16{ &.{1}, &.{4}, &.{ 7, 8, 9 }, &.{10}, &.{11}, &.{12}, &.{13}, &.{14}, &.{15}, &.{16}, &.{17} };
    try everyCombination(r, &samples, Types, &ok);
}

/// Every (type, column) pair of a row whose column i has kind i + 1: a type
/// gets a value exactly for the kinds listed for it, error.TypeMismatch
/// otherwise; the optional variant agrees.
fn everyCombination(r: plzig.Row, samples: []const Col, comptime Types: anytype, ok: []const []const u16) !void {
    inline for (Types, 0..) |T, ti| {
        for (samples, 0..) |_, col| {
            const kind: u16 = @intCast(col + 1);
            const want = std.mem.indexOfScalar(u16, ok[ti], kind) != null;
            if (r.get(T, col)) |_| {
                try testing.expect(want);
            } else |err| {
                try testing.expect(!want);
                try testing.expectEqual(error.TypeMismatch, err);
            }
            // the optional variant agrees, also for NULL of that kind
            if (r.get(?T, col)) |_| try testing.expect(want) else |_| try testing.expect(!want);
        }
    }
}

test "Row.get: the fixed-width types decode PostgreSQL's representation" {
    try setup(64);
    // an interval of 1 month 2 days 3 us, as PostgreSQL lays it out
    const iv_bytes = [16]u8{ 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0 };
    const uuid_bytes = [16]u8{ 0xa0, 0xee, 0xbc, 0x99, 0x9c, 0x0b, 0x4e, 0xf8, 0xbb, 0x6d, 0x6b, 0xb9, 0xbd, 0x38, 0x0a, 0x11 };
    const cols = [_]Col{
        .{ .raw = .{ .kind = .date, .val = @bitCast(@as(i64, -1)) } },
        .{ .raw = .{ .kind = .date, .val = @bitCast(@as(i64, std.math.minInt(i32))) } },
        .{ .raw = .{ .kind = .time, .val = 86_400_000_000 } },
        .{ .raw = .{ .kind = .timetz, .val = 5, .len = @bitCast(@as(i32, -7200)) } },
        .{ .raw = .{ .kind = .timestamp, .val = @bitCast(@as(i64, std.math.maxInt(i64))) } },
        .{ .raw = .{ .kind = .timestamptz, .val = @bitCast(@as(i64, -123)) } },
        .{ .raw = .{ .kind = .interval, .bytes = &iv_bytes } },
        .{ .raw = .{ .kind = .uuid, .bytes = &uuid_bytes } },
        .{ .raw = .{ .kind = .oid, .val = 0xffff_ffff } },
        .{ .null_of = .timestamptz },
    };
    const r = try row(&cols);
    try testing.expectEqual(@as(i32, -1), (try r.get(plzig.Date, 0)).days);
    try testing.expect(!(try r.get(plzig.Date, 1)).isFinite());
    try testing.expectEqual(plzig.Date.neg_infinity, try r.get(plzig.Date, 1));
    try testing.expectEqual(@as(i64, 86_400_000_000), (try r.get(plzig.Time, 2)).usecs);
    try testing.expectEqual(plzig.TimeTz{ .usecs = 5, .zone = -7200 }, try r.get(plzig.TimeTz, 3));
    try testing.expectEqual(plzig.Timestamp.infinity, try r.get(plzig.Timestamp, 4));
    try testing.expectEqual(@as(i64, -123), (try r.get(plzig.TimestampTz, 5)).usecs);
    try testing.expectEqual(plzig.Interval{ .usecs = 3, .days = 2, .months = 1 }, try r.get(plzig.Interval, 6));
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", (try r.get(plzig.Uuid, 7)).format(&buf));
    try testing.expectEqual(@as(u32, 0xffff_ffff), (try r.get(plzig.Oid, 8)).value);
    try testing.expectEqual(@as(?plzig.TimestampTz, null), try r.get(?plzig.TimestampTz, 9));
    try testing.expectError(error.UnexpectedNull, r.get(plzig.TimestampTz, 9));
}

test "Uuid: parse the forms uuid_in accepts, refuse the others" {
    var buf: [36]u8 = undefined;
    const canon = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11";
    for ([_][]const u8{
        canon,
        "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11",
        "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}",
        "a0eebc999c0b4ef8bb6d6bb9bd380a11",
        "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
        "{a0eebc999c0b4ef8bb6d6bb9bd380a11}",
    }) |t| {
        try testing.expectEqualStrings(canon, (try plzig.Uuid.parse(t)).format(&buf));
    }
    for ([_][]const u8{
        "",                                      "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a111", "a0eebc99--9c0b-4ef8-bb6d-6bb9bd380a11",
        "-a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11-",
        "a0eeb-c99-9c0b-4ef8-bb6d-6bb9bd380a11", "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",  "a0eebc99 9c0b-4ef8-bb6d-6bb9bd380a11",
    }) |t| {
        try testing.expectError(error.InvalidUuid, plzig.Uuid.parse(t));
    }
}

test "prepared statements: fixed-width parameters, 16-byte values by address" {
    try setup(64);
    var plan = try plzig.spi.prepare("SELECT $1", &.{ .date, .time, .timetz, .timestamp, .timestamptz, .interval, .uuid, .oid });
    for (0..8) |i| try testing.expectEqual(@as(u32, @intCast(i + 10)), env.last_kinds[i]);
    const iv: plzig.Interval = .{ .usecs = -1, .days = 2, .months = -3 };
    const u = try plzig.Uuid.parse("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11");
    const t0 = top();
    _ = try plan.execute(.{
        plzig.Date{ .days = -5 },                plzig.Time{ .usecs = 86_400_000_000 },
        plzig.TimeTz{ .usecs = 7, .zone = -3600 }, plzig.Timestamp.neg_infinity,
        plzig.TimestampTz{ .usecs = 42 },        iv,
        u,                                       plzig.Oid{ .value = 0xffff_fffe },
        @as(?plzig.Interval, iv),                @as(?plzig.Date, null),
    });
    try testing.expectEqual(t0, top());
    const vs = env.last_values[0..env.last_nvalues];
    try testing.expectEqual(@as(usize, 10), vs.len);
    try testing.expectEqual(Value{ .val = @bitCast(@as(i64, -5)), .len = 0, .kind = 10, .is_null = 0 }, vs[0]);
    try testing.expectEqual(Value{ .val = 86_400_000_000, .len = 0, .kind = 11, .is_null = 0 }, vs[1]);
    try testing.expectEqual(Value{ .val = 7, .len = @bitCast(@as(i32, -3600)), .kind = 12, .is_null = 0 }, vs[2]);
    try testing.expectEqual(Value{ .val = @bitCast(@as(i64, std.math.minInt(i64))), .len = 0, .kind = 13, .is_null = 0 }, vs[3]);
    try testing.expectEqual(Value{ .val = 42, .len = 0, .kind = 14, .is_null = 0 }, vs[4]);
    try testing.expectEqual(Value{ .val = 0xffff_fffe, .len = 0, .kind = 17, .is_null = 0 }, vs[7]);
    // 16-byte values: address and length of the bytes in PostgreSQL's layout
    // (the host reads them during the call)
    for ([_]usize{ 5, 8 }) |i| {
        try testing.expectEqual(@as(u16, 15), vs[i].kind);
        try testing.expectEqual(@as(u32, 16), vs[i].len);
    }
    try testing.expectEqual(@as(u16, 16), vs[6].kind);
    try testing.expectEqual(@as(u32, 16), vs[6].len);
    try testing.expectEqual(Value{ .val = 0, .len = 0, .kind = 10, .is_null = 1 }, vs[9]);
}

test "rows without columns, and an unknown kind" {
    try setup(64);
    const r = try row(&.{});
    try testing.expectEqual(@as(usize, 0), r.len());
    try testing.expectError(error.ColumnOutOfRange, r.get(i32, 0));
    // a kind this SDK does not know is a mismatch for every type
    const v = [_]Value{.{ .val = 1, .len = 0, .kind = 42, .is_null = 0 }};
    const odd: plzig.Row = .{ .values = &v };
    try testing.expectError(error.TypeMismatch, odd.get(i64, 0));
    try testing.expectError(error.TypeMismatch, odd.get([]const u8, 0));
}

test "Result.row reuses one buffer: no growth over many rows" {
    try setup(64);
    const xs: [300]u8 = @splat('x');
    const big = [_]Col{ .{ .text = &xs }, .{ .int4 = 5 } };
    const small = [_]Col{ .{ .text = "y" }, .{ .int4 = 6 } };
    env.rows = &.{ &big, &small };
    const res: plzig.spi.Result = .{ .rows = 2, .columns = 2 };
    _ = try res.row(0);
    const t0 = top();
    for (0..1000) |i| {
        const r = try res.row(i % 2);
        try testing.expectEqual(@as(i32, @intCast(5 + i % 2)), try r.get(i32, 1));
    }
    try testing.expectEqual(t0, top());
}

// ---------------------------------------------------------------------------
// Text results, column names

test "Result.get and columnName" {
    try setup(64);
    const cols = [_]Col{ .{ .text = "abc" }, .{ .null_of = .text }, .{ .text = "" }, .{ .int8 = -42 } };
    env.rows = &.{&cols};
    env.column_names = &.{ "a", "b", "", "d" };
    const res = try plzig.spi.execute("SELECT 1", &.{});
    try testing.expectEqual(@as(u64, 1), res.rows);
    try testing.expectEqual(@as(u32, 4), res.columns);
    try testing.expectEqualStrings("abc", (try res.get(0, 0)).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.get(0, 1));
    try testing.expectEqualStrings("", (try res.get(0, 2)).?);
    try testing.expectEqualStrings("-42", (try res.get(0, 3)).?);
    try testing.expectEqualStrings("a", try res.columnName(0));
    try testing.expectEqualStrings("", try res.columnName(2));
}

// ---------------------------------------------------------------------------
// Parameters

test "spi.execute: text parameters become slots, NULL included; the slot array is reclaimed" {
    try setup(64);
    const t0 = top();
    _ = try plzig.spi.execute("SELECT $1, $2, $3", &.{ "one", null, "" });
    try testing.expectEqualStrings("SELECT $1, $2, $3", env.last_sql[0..env.last_sql_len]);
    try testing.expectEqual(@as(usize, 3), env.last_nslots);
    const s0 = env.last_slots[0];
    try testing.expectEqual(@as(u32, 0), s0.is_null);
    try testing.expectEqual(@as(u32, 3), s0.len);
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(s0.val)));
    try testing.expectEqualStrings("one", p[0..3]);
    try testing.expectEqual(@as(u32, 1), env.last_slots[1].is_null);
    try testing.expectEqual(@as(u32, 0), env.last_slots[2].is_null);
    try testing.expectEqual(@as(u32, 0), env.last_slots[2].len);
    try testing.expectEqual(t0, top());
    for (0..1000) |_| _ = try plzig.spi.execute("SELECT $1", &.{"x"});
    try testing.expectEqual(t0, top());
}

test "prepared statements: declared kinds and typed parameter encoding" {
    try setup(64);
    var plan = try plzig.spi.prepare("SELECT $1", &.{ .boolean, .int2, .int4, .int8, .float4, .float8, .text, .bytea });
    try testing.expectEqual(@as(usize, 8), env.last_nkinds);
    for (0..8) |i| try testing.expectEqual(@as(u32, @intCast(i + 1)), env.last_kinds[i]);

    const owned: []const u8 = "slice";
    const empty: []const u8 = "";
    const t0 = top();
    _ = try plan.execute(.{
        true,                   @as(i16, -2),         @as(i32, std.math.minInt(i32)),
        @as(i64, -1),           @as(f32, -0.0),       @as(f64, std.math.inf(f64)),
        "literal",              plzig.bytea("\x00\x01"), owned,
        empty,                  null,                 @as(?i32, null),
        @as(?[]const u8, "opt"),
    });
    try testing.expectEqual(t0, top()); // parameters live on the stack, not in the arena
    const vs = env.last_values[0..env.last_nvalues];
    try testing.expectEqual(@as(usize, 13), vs.len);
    const expect = struct {
        fn scalar(val: Value, kind: u16, bits: u64) !void {
            try testing.expectEqual(kind, val.kind);
            try testing.expectEqual(@as(u16, 0), val.is_null);
            try testing.expectEqual(bits, val.val);
        }
        fn bytes(val: Value, kind: u16, want: []const u8) !void {
            try testing.expectEqual(kind, val.kind);
            try testing.expectEqual(@as(u16, 0), val.is_null);
            try testing.expectEqual(@as(u32, @intCast(want.len)), val.len);
            if (want.len > 0) {
                const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(val.val)));
                try testing.expectEqualSlices(u8, want, p[0..want.len]);
            }
        }
    };
    try expect.scalar(vs[0], 1, 1);
    try expect.scalar(vs[1], 2, @bitCast(@as(i64, -2)));
    try expect.scalar(vs[2], 3, @bitCast(@as(i64, std.math.minInt(i32))));
    try expect.scalar(vs[3], 4, @bitCast(@as(i64, -1)));
    try expect.scalar(vs[4], 5, @as(u32, @bitCast(@as(f32, -0.0))));
    try expect.scalar(vs[5], 6, @bitCast(std.math.inf(f64)));
    try expect.bytes(vs[6], 7, "literal");
    try expect.bytes(vs[7], 8, "\x00\x01");
    try expect.bytes(vs[8], 7, "slice");
    try expect.bytes(vs[9], 7, "");
    // untyped null: kind 0; typed null: the type's kind
    try testing.expectEqual(@as(u16, 1), vs[10].is_null);
    try testing.expectEqual(@as(u16, 0), vs[10].kind);
    try testing.expectEqual(@as(u16, 1), vs[11].is_null);
    try testing.expectEqual(@as(u16, 3), vs[11].kind);
    try expect.bytes(vs[12], 7, "opt");

    _ = try plan.execute(.{});
    try testing.expectEqual(@as(usize, 0), env.last_nvalues);

    plan.free();
    try testing.expectEqual(@as(u64, 0), plan.handle);
    plan.free(); // idempotent: the host is not called again
    try testing.expectEqual(@as(usize, 1), env.plans_freed);
}

// ---------------------------------------------------------------------------
// Cursors

test "cursor: rows in order, end closes once, close is idempotent, scratch is bounded" {
    try setup(64);
    const as: [100]u8 = @splat('a');
    const r1 = [_]Col{ .{ .int4 = 1 }, .{ .text = &as } };
    const r2 = [_]Col{ .{ .int4 = 2 }, .{ .null_of = .text } };
    const r3 = [_]Col{ .{ .int4 = 3 }, .{ .text = "" } };
    env.rows = &.{ &r1, &r2, &r3 };
    var c = try plzig.spi.open("SELECT * FROM t WHERE x = $1", &.{"7"});
    try testing.expectEqual(@as(usize, 1), env.last_nslots);
    var want: i32 = 1;
    var t_after_first: usize = 0;
    while (try c.next()) |r| : (want += 1) {
        try testing.expectEqual(want, try r.get(i32, 0));
        if (want == 1) t_after_first = top();
    }
    try testing.expectEqual(@as(i32, 4), want);
    try testing.expectEqual(t_after_first, top()); // smaller rows reuse the buffer
    try testing.expectEqual(@as(usize, 1), env.cursor_closes); // the end closes it
    try testing.expectEqual(@as(?plzig.Row, null), try c.next()); // stays at the end
    c.close(); // already closed by the host: not closed again
    c.close();
    try testing.expectEqual(@as(usize, 1), env.cursor_closes);
    try testing.expectError(error.CursorClosed, c.next());

    // closing an open cursor early calls the host once
    env.reset();
    env.rows = &.{ &r1, &r2 };
    var plan = try plzig.spi.prepare("SELECT $1", &.{.int4});
    var c2 = try plan.open(.{@as(i32, 5)});
    try testing.expectEqual(@as(usize, 1), env.last_nvalues);
    _ = try c2.next();
    c2.close();
    c2.close();
    try testing.expectEqual(@as(usize, 1), env.cursor_closes);
    try testing.expectError(error.CursorClosed, c2.next());
}

test "cursor: one host call per row, two when the buffer must grow; every row taken once" {
    try setup(64);
    const big: [1000]u8 = @splat('z');
    const r1 = [_]Col{ .{ .int4 = 1 }, .{ .text = "a" } }; // 40 bytes: grows the empty buffer to 256
    const r2 = [_]Col{ .{ .int4 = 2 }, .{ .text = "b" } };
    const r3 = [_]Col{ .{ .int4 = 3 }, .{ .text = &big } }; // larger than 256: grows again
    const r4 = [_]Col{ .{ .int4 = 4 }, .{ .null_of = .text } };
    env.rows = &.{ &r1, &r2, &r3, &r4 };
    var c = try plzig.spi.open("SELECT 1", &.{});
    var calls = env.fetch_calls;
    const expect_calls = [_]usize{ 2, 1, 2, 1 };
    var i: usize = 0;
    while (try c.next()) |r| : (i += 1) {
        try testing.expectEqual(expect_calls[i], env.fetch_calls - calls);
        calls = env.fetch_calls;
        try testing.expectEqual(@as(i32, @intCast(i + 1)), try r.get(i32, 0));
        if (i == 2) try testing.expectEqualSlices(u8, &big, try r.get([]const u8, 1));
        if (i == 3) try testing.expectEqual(@as(?[]const u8, null), try r.get(?[]const u8, 1));
    }
    try testing.expectEqual(@as(usize, 4), i);
    try testing.expectEqual(@as(usize, 4), env.rows_taken);
    try testing.expectEqual(@as(usize, 1), env.cursor_closes);
}

test "cursor: out of memory while growing keeps the row for the next call" {
    try setup(3); // 1 page of heap
    const big: [40000]u8 = @splat('q');
    const huge: [70000]u8 = @splat('h');
    const r1 = [_]Col{.{ .text = &huge }};
    const r2 = [_]Col{.{ .text = &big }};
    env.rows = &.{ &r1, &r2 };
    var c = try plzig.spi.open("SELECT 1", &.{});
    try testing.expectError(error.OutOfMemory, c.next());
    try testing.expectEqual(@as(usize, 1), env.rows_taken);
    // more memory: the same row comes, not the next one
    env.setLimit(64);
    const r = (try c.next()).?;
    try testing.expectEqualSlices(u8, &huge, try r.get([]const u8, 0));
    try testing.expectEqual(@as(usize, 1), env.rows_taken);
    const n = (try c.next()).?;
    try testing.expectEqual(@as(usize, 40000), (try n.get([]const u8, 0)).len);
    try testing.expectEqual(@as(?plzig.Row, null), try c.next());
}

test "cursor: an empty result" {
    try setup(64);
    env.rows = &.{};
    var c = try plzig.spi.open("SELECT 1 WHERE false", &.{});
    try testing.expectEqual(@as(?plzig.Row, null), try c.next());
    try testing.expectEqual(@as(usize, 1), env.cursor_closes);
}

// ---------------------------------------------------------------------------
// Logging

test "print formats into the arena and passes the level" {
    try setup(64);
    plzig.notice("{d} rows in {s}", .{ 42, "t" });
    try testing.expectEqualStrings("42 rows in t", env.last_log[0..env.last_log_len]);
    try testing.expectEqual(@as(u32, 3), env.last_log_level);
    plzig.debug("d", .{});
    try testing.expectEqual(@as(u32, 0), env.last_log_level);
    plzig.info("i", .{});
    try testing.expectEqual(@as(u32, 2), env.last_log_level);
    plzig.warning("w", .{});
    try testing.expectEqual(@as(u32, 4), env.last_log_level);
    plzig.print(.log, "l", .{});
    try testing.expectEqual(@as(u32, 1), env.last_log_level);
    // out of guest memory while formatting: a warning, not a trap
    try setup(3);
    _ = a.rawAlloc(page - 8, .@"1", 0) orelse return error.TestUnexpectedResult;
    const xs: [64]u8 = @splat('x');
    plzig.notice("{s}", .{&xs});
    try testing.expectEqual(@as(u32, 4), env.last_log_level);
    try testing.expect(std.mem.indexOf(u8, env.last_log[0..env.last_log_len], "out of memory") != null);
}

test "raiseError: the API shape (behaviour: test/sql/errors.sql)" {
    // noreturn: it cannot run in a unit test; check what user code can write
    const R = @typeInfo(@TypeOf(plzig.raiseError)).@"fn";
    try testing.expect(R.return_type.? == noreturn);
    const r: plzig.ErrorReport = .{ .message = "m" };
    try testing.expectEqualStrings("P0001", r.sqlstate);
    try testing.expect(r.detail == null and r.hint == null);
    const f: plzig.ErrorFields = .{ .sqlstate = "23514", .hint = "h" };
    try testing.expectEqualStrings("h", f.hint.?);
}

// ---------------------------------------------------------------------------
// The SDK root: argument decoding, result encoding, plzig_call

test "root.decode: every parameter type, NULL and empty slices" {
    try setup(64);
    const s = struct {
        fn slot(val: u64, len: u32, is_null: u32) Slot {
            return .{ .val = val, .len = len, .is_null = is_null };
        }
    };
    try testing.expectEqual(true, sdk_root.decode(bool, &s.slot(1, 0, 0)));
    try testing.expectEqual(false, sdk_root.decode(bool, &s.slot(0, 0, 0)));
    try testing.expectEqual(@as(i16, -5), sdk_root.decode(i16, &s.slot(@bitCast(@as(i64, -5)), 0, 0)));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), sdk_root.decode(i32, &s.slot(@bitCast(@as(i64, std.math.minInt(i32))), 0, 0)));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), sdk_root.decode(i64, &s.slot(@bitCast(@as(i64, std.math.minInt(i64))), 0, 0)));
    try testing.expectEqual(@as(f32, 1.5), sdk_root.decode(f32, &s.slot(@as(u32, @bitCast(@as(f32, 1.5))), 0, 0)));
    try testing.expect(std.math.isNan(sdk_root.decode(f64, &s.slot(@bitCast(std.math.nan(f64)), 0, 0))));
    const text = "bytes";
    try testing.expectEqualStrings(text, sdk_root.decode([]const u8, &s.slot(@intFromPtr(text.ptr), 5, 0)));
    // empty slices: the pointer is not looked at (the host passes anything)
    try testing.expectEqual(@as(usize, 0), sdk_root.decode([]const u8, &s.slot(0, 0, 0)).len);
    try testing.expectEqual(@as(usize, 0), sdk_root.decode([]const u8, &s.slot(0xdead_beef, 0, 0)).len);
    // optionals
    try testing.expectEqual(@as(?i32, null), sdk_root.decode(?i32, &s.slot(7, 0, 1)));
    try testing.expectEqual(@as(?i32, 7), sdk_root.decode(?i32, &s.slot(7, 0, 0)));
    try testing.expectEqual(@as(?[]const u8, null), sdk_root.decode(?[]const u8, &s.slot(0, 0, 1)));
    try testing.expectEqual(@as(?bool, null), sdk_root.decode(?bool, &s.slot(1, 0, 1)));
    // fixed-width types
    try testing.expectEqual(plzig.Date{ .days = -730 }, sdk_root.decode(plzig.Date, &s.slot(@bitCast(@as(i64, -730)), 0, 0)));
    try testing.expectEqual(plzig.Time{ .usecs = 1 }, sdk_root.decode(plzig.Time, &s.slot(1, 0, 0)));
    try testing.expectEqual(plzig.TimeTz{ .usecs = 2, .zone = -50400 }, sdk_root.decode(plzig.TimeTz, &s.slot(2, @bitCast(@as(i32, -50400)), 0)));
    try testing.expectEqual(plzig.Timestamp.neg_infinity, sdk_root.decode(plzig.Timestamp, &s.slot(@bitCast(@as(i64, std.math.minInt(i64))), 0, 0)));
    try testing.expectEqual(plzig.TimestampTz{ .usecs = 9 }, sdk_root.decode(plzig.TimestampTz, &s.slot(9, 0, 0)));
    try testing.expectEqual(plzig.Oid{ .value = 4294967295 }, sdk_root.decode(plzig.Oid, &s.slot(4294967295, 0, 0)));
    const iv = [16]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff };
    try testing.expectEqual(plzig.Interval{ .usecs = -1, .days = 1, .months = -2 }, sdk_root.decode(plzig.Interval, &s.slot(@intFromPtr(&iv), 16, 0)));
    try testing.expectEqualSlices(u8, &iv, &sdk_root.decode(plzig.Uuid, &s.slot(@intFromPtr(&iv), 16, 0)).bytes);
    try testing.expectEqual(@as(?plzig.Uuid, null), sdk_root.decode(?plzig.Uuid, &s.slot(0, 0, 1)));
}

test "root.encode: every result type" {
    var out: Slot = undefined;
    sdk_root.encode(bool, true, &out);
    try testing.expectEqual(Slot{ .val = 1, .len = 0, .is_null = 0 }, out);
    sdk_root.encode(i16, -1, &out);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), out.val);
    sdk_root.encode(i32, std.math.minInt(i32), &out);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, std.math.minInt(i32)))), out.val);
    sdk_root.encode(i64, std.math.maxInt(i64), &out);
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), out.val);
    sdk_root.encode(f32, -std.math.inf(f32), &out);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(-std.math.inf(f32)))), out.val);
    sdk_root.encode(f64, -0.0, &out);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), out.val);
    const t: []const u8 = "res";
    sdk_root.encode([]const u8, t, &out);
    try testing.expectEqual(@as(u64, @intFromPtr(t.ptr)), out.val);
    try testing.expectEqual(@as(u32, 3), out.len);
    try testing.expectEqual(@as(u32, 0), out.is_null);
    var m = [_]u8{ 1, 2 };
    sdk_root.encode([]u8, &m, &out);
    try testing.expectEqual(@as(u32, 2), out.len);
    // fixed-width types
    sdk_root.encode(plzig.Date, plzig.Date.infinity, &out);
    try testing.expectEqual(Slot{ .val = std.math.maxInt(i32), .len = 0, .is_null = 0 }, out);
    sdk_root.encode(plzig.Date, .{ .days = -1 }, &out);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), out.val);
    sdk_root.encode(plzig.TimeTz, .{ .usecs = 3, .zone = -1 }, &out);
    try testing.expectEqual(Slot{ .val = 3, .len = 0xffff_ffff, .is_null = 0 }, out);
    sdk_root.encode(plzig.TimestampTz, .{ .usecs = -2 }, &out);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -2))), out.val);
    sdk_root.encode(plzig.Oid, .{ .value = 7 }, &out);
    try testing.expectEqual(Slot{ .val = 7, .len = 0, .is_null = 0 }, out);
    // 16-byte values: copied out of the stack frame, PostgreSQL's layout
    sdk_root.encode(plzig.Interval, .{ .usecs = 1, .days = 2, .months = 3 }, &out);
    try testing.expectEqual(@as(u32, 16), out.len);
    const p: *const [16]u8 = @ptrFromInt(@as(usize, @intCast(out.val)));
    try testing.expectEqualSlices(u8, &[16]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 }, p);
}

const Arg = ?union(enum) { int: u64, bytes: []const u8 };

/// Lay out argument slots in guest memory like the host does
/// (plzig_instance_call): slots, then the bytes, 8-byte aligned; in the
/// argument buffer if the block fits (plzig_call with begin = 1), else in a
/// block from plzig_alloc_args (begin = 0).  `force_alloc` takes the second
/// path even for small blocks.
fn callUserHow(args: []const Arg, result: *Slot, force_alloc: bool) !u32 {
    var total: usize = (args.len + 1) * @sizeOf(Slot);
    for (args) |arg| {
        if (arg) |x| switch (x) {
            .bytes => |b| total += (b.len + 7) & ~@as(usize, 7),
            else => {},
        };
    }
    const info = plzig_init();
    const cap: usize = @intCast(info >> 32);
    var base: usize = undefined;
    var begin: u32 = undefined;
    if (total <= cap and !force_alloc) {
        base = @intCast(info & 0xffff_ffff);
        begin = 1;
    } else {
        base = plzig_alloc_args(@intCast(total));
        try testing.expect(base != 0);
        begin = 0;
    }
    const mem: [*]u8 = @ptrFromInt(base);
    const slots: [*]Slot = @ptrFromInt(base);
    var off: usize = (args.len + 1) * @sizeOf(Slot);
    for (args, 0..) |arg, i| {
        slots[i] = .{ .val = 0, .len = 0, .is_null = 1 };
        if (arg) |x| switch (x) {
            .int => |n| slots[i] = .{ .val = n, .len = 0, .is_null = 0 },
            .bytes => |b| {
                @memcpy(mem[off..][0..b.len], b);
                slots[i] = .{ .val = base + off, .len = @intCast(b.len), .is_null = 0 };
                off += (b.len + 7) & ~@as(usize, 7);
            },
        };
    }
    return plzig_call(slots, @intCast(args.len), result, begin);
}

fn callUser(args: []const Arg, result: *Slot) !u32 {
    return callUserHow(args, result, false);
}

test "plzig_call: begin = 1 resets the arena, begin = 0 does not" {
    try setup(64);
    var res: Slot = undefined;
    const old = try a.alloc(u8, 100);
    // mode 3 allocates its result string at the start of the fresh arena
    const args = [_]Arg{ null, null, null, null, null, null, null, .{ .bytes = "x" }, .{ .int = 3 } };
    try testing.expectEqual(@as(u32, 0), try callUser(&args, &res));
    try testing.expectEqual(@as(usize, @intFromPtr(old.ptr)), @as(usize, @intCast(res.val)));
    // through plzig_alloc_args: the block comes first, the result after it
    try testing.expectEqual(@as(u32, 0), try callUserHow(&args, &res, true));
    try testing.expect(@as(usize, @intCast(res.val)) > heapStart());
    try testing.expectEqualStrings("x", user.seen[user.seen_len - 3 ..][0..1]);
}

test "plzig_call: arguments larger than the argument buffer" {
    try setup(64);
    var res: Slot = undefined;
    const big: [plzig.arg_buffer_size]u8 = @splat('b');
    try testing.expectEqual(@as(u32, 0), try callUser(&.{ null, null, null, null, null, null, .{ .bytes = "y" }, .{ .bytes = &big }, .{ .int = 3 } }, &res));
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(res.val)));
    try testing.expectEqualStrings("got 4096 bytes", p[0..res.len]);
}

test "plzig_call: arguments in, result or error out" {
    try setup(64);
    var res: Slot = undefined;
    const f4: u64 = @as(u32, @bitCast(@as(f32, 2.5)));
    const f8: u64 = @bitCast(@as(f64, -1.25));

    // mode 3: returns a fresh string in the arena
    try testing.expectEqual(@as(u32, 0), try callUser(&.{
        .{ .int = 1 },                    .{ .int = @bitCast(@as(i64, -7)) },
        .{ .int = @bitCast(@as(i64, 70000)) }, .{ .int = @bitCast(@as(i64, -1)) },
        .{ .int = f4 },                   .{ .int = f8 },
        .{ .bytes = "héllo" },            .{ .bytes = "strict" },
        .{ .int = 3 },
    }, &res));
    try testing.expectEqualStrings("true|-7|70000|-1|2.5|-1.25|héllo|strict|3", user.seen[0..user.seen_len]);
    try testing.expectEqual(@as(u32, 0), res.is_null);
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(res.val)));
    try testing.expectEqualStrings("got 6 bytes", p[0..res.len]);

    // NULLs for every optional parameter, empty strict text; mode 0 returns null
    try testing.expectEqual(@as(u32, 0), try callUser(&.{ null, null, null, null, null, null, null, .{ .bytes = "" }, .{ .int = 0 } }, &res));
    try testing.expectEqualStrings("null|null|null|null|null|null|null||0", user.seen[0..user.seen_len]);
    try testing.expectEqual(@as(u32, 1), res.is_null);

    // mode 2: an empty (non-NULL) string
    try testing.expectEqual(@as(u32, 0), try callUser(&.{ null, null, null, null, null, null, .{ .bytes = "" }, .{ .bytes = "x" }, .{ .int = 2 } }, &res));
    try testing.expectEqual(@as(u32, 0), res.is_null);
    try testing.expectEqual(@as(u32, 0), res.len);

    // mode 1: a returned Zig error is status 1 with the error name
    try testing.expectEqual(@as(u32, 1), try callUser(&.{ null, null, null, null, null, null, null, .{ .bytes = "x" }, .{ .int = 1 } }, &res));
    const e: [*]const u8 = @ptrFromInt(@as(usize, @intCast(res.val)));
    try testing.expectEqualStrings("SomethingFailed", e[0..res.len]);
}

// ---------------------------------------------------------------------------
// numeric

const Numeric = plzig.Numeric;

/// free a Numeric made with testing.allocator (the constants are static)
fn freeNum(n: Numeric) void {
    for ([_]Numeric{ Numeric.nan, Numeric.infinity, Numeric.neg_infinity, Numeric.zero }) |c| {
        if (n.wire.ptr == c.wire.ptr) return;
    }
    testing.allocator.free(n.wire);
}

/// n '0' characters, at comptime
fn zeros(comptime n: usize) *const [n]u8 {
    const z: [n]u8 = @splat('0');
    return &z;
}

/// wire bytes from header fields and digits
fn wire(buf: []u8, w: i16, sign: u16, dscale: u16, digits: []const u16) []const u8 {
    const put = struct {
        fn f(b: []u8, off: usize, v: u16) void {
            b[off] = @intCast(v >> 8);
            b[off + 1] = @truncate(v);
        }
    }.f;
    put(buf, 0, @intCast(digits.len));
    put(buf, 2, @bitCast(w));
    put(buf, 4, sign);
    put(buf, 6, dscale);
    for (digits, 0..) |d, i| put(buf, 8 + 2 * i, d);
    return buf[0 .. 8 + 2 * digits.len];
}

fn numText(n: Numeric) ![]u8 {
    return n.toTextAlloc(testing.allocator);
}

fn expectParsesTo(text: []const u8, want: []const u8) !void {
    const n = try Numeric.parseAlloc(testing.allocator, text);
    defer freeNum(n);
    _ = try Numeric.fromWire(n.wire); // what parse builds is valid wire format
    const got = try numText(n);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("parse({s})\n", .{text});
        return err;
    };
}

test "Numeric.fromWire: the layout numeric_recv accepts" {
    var b: [64]u8 = undefined;
    _ = try Numeric.fromWire(wire(&b, 0, 0, 0, &.{}));
    _ = try Numeric.fromWire(wire(&b, -32768, 0x4000, 0x3fff, &.{ 9999, 0, 1 }));
    _ = try Numeric.fromWire(wire(&b, 0, 0xC000, 0, &.{}));
    _ = try Numeric.fromWire(wire(&b, 5, 0xD000, 0, &.{7})); // digits of specials are ignored
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(""));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(b[0..7]));
    const ok = wire(&b, 0, 0, 0, &.{1});
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(ok[0 .. ok.len - 1]));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(b[0 .. ok.len + 1]));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(wire(&b, 0, 0, 0, &.{10000})));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(wire(&b, 0, 0x8000, 0, &.{})));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(wire(&b, 0, 0xE000, 0, &.{})));
    try testing.expectError(error.InvalidNumeric, Numeric.fromWire(wire(&b, 0, 0, 0x4000, &.{})));
}

test "Numeric: text exactly as numeric_out writes it" {
    var b: [64]u8 = undefined;
    const cases = [_]struct { []const u8, i16, u16, u16, []const u16 }{
        .{ "0", 0, 0, 0, &.{} },
        .{ "0.000", 0, 0, 3, &.{} },
        .{ "-0", 0, 0x4000, 0, &.{} }, // unnormalised: numeric_out prints the sign
        .{ "1", 0, 0, 0, &.{1} },
        .{ "12345678", 1, 0, 0, &.{ 1234, 5678 } },
        .{ "10000", 1, 0, 0, &.{1} },
        .{ "-0.0001", -1, 0x4000, 4, &.{1} },
        .{ "0.00012", -1, 0, 5, &.{ 1, 2000 } },
        .{ "0.0001", -1, 0, 3 + 1, &.{1} },
        .{ "0.000", -1, 0, 3, &.{1} }, // dscale hides digits: cut, as numeric_out does
        .{ "3.14159265", 0, 0, 8, &.{ 3, 1415, 9265 } },
        .{ "100000000.0000", 2, 0, 4, &.{1} },
        .{ "NaN", 0, 0xC000, 0, &.{} },
        .{ "Infinity", 0, 0xD000, 0, &.{} },
        .{ "-Infinity", 0, 0xF000, 0, &.{} },
    };
    for (cases) |c| {
        const n = try Numeric.fromWire(wire(&b, c[1], c[2], c[3], c[4]));
        const t = try numText(n);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings(c[0], t);
        try testing.expectEqual(c[0].len, n.textLen());
        var fb: [64]u8 = undefined;
        try testing.expectEqualStrings(c[0], try std.fmt.bufPrint(&fb, "{f}", .{n}));
    }
}

test "Numeric.parse: numeric_in's syntax, scale and normalisation" {
    try expectParsesTo("0", "0");
    try expectParsesTo("-0", "0");
    try expectParsesTo("0.000", "0.000");
    try expectParsesTo("  1.50  ", "1.50");
    try expectParsesTo("+7", "7");
    try expectParsesTo(".5", "0.5");
    try expectParsesTo("5.", "5");
    try expectParsesTo("-0.001e3", "-1");
    try expectParsesTo("1e-5", "0.00001");
    try expectParsesTo("1.5E+3", "1500");
    try expectParsesTo("1.23456e2", "123.456");
    try expectParsesTo("000123.4500", "123.4500");
    try expectParsesTo("12345678901234567890.123456789", "12345678901234567890.123456789");
    try expectParsesTo("\t\n-999999999999.99990000\r", "-999999999999.99990000");
    try expectParsesTo("NaN", "NaN");
    try expectParsesTo(" nan ", "NaN");
    try expectParsesTo("Infinity", "Infinity");
    try expectParsesTo("+inf", "Infinity");
    try expectParsesTo("-INFINITY", "-Infinity");
    try expectParsesTo("-inf", "-Infinity");
    for ([_][]const u8{ "", " ", "-", ".", "e5", "1e", "1e+", "1.2.3", "1 2", "1_000", "0x1F", "abc", "--1", "+-1", "1e5x", "- 1", "Infinityx", "nana" }) |t| {
        try testing.expectError(error.InvalidCharacter, Numeric.parseAlloc(testing.allocator, t));
    }
    // the limits of the format: weight and scale
    const big = try Numeric.parseAlloc(testing.allocator, "1e131071");
    defer freeNum(big);
    try testing.expectEqual(@as(i16, 32767), big.weight());
    try testing.expectError(error.Overflow, Numeric.parseAlloc(testing.allocator, "1e131072"));
    const small = try Numeric.parseAlloc(testing.allocator, "1e-16383");
    defer freeNum(small);
    try testing.expectEqual(@as(u16, 16383), small.scale());
    try testing.expectError(error.Overflow, Numeric.parseAlloc(testing.allocator, "1e-16384"));
    try testing.expectError(error.Overflow, Numeric.parseAlloc(testing.allocator, "1e9999999999"));
    // long input, normalised (leading/trailing zero digits not stored)
    var long: [26000]u8 = undefined;
    @memset(&long, '0');
    long[10000] = '7';
    long[10001] = '.';
    const l = try Numeric.parseAlloc(testing.allocator, &long);
    defer freeNum(l);
    try testing.expectEqual(@as(usize, 10), l.wire.len); // one digit
    try testing.expectEqual(@as(u16, 26000 - 10002), l.scale());
    long[10001] = '0';
    long[3] = '.'; // more than 16383 digits after the point
    try testing.expectError(error.Overflow, Numeric.parseAlloc(testing.allocator, &long));
}

test "Numeric.order and eql: PostgreSQL's ordering" {
    const vals = [_][]const u8{ "-Infinity", "-1e100", "-1.5", "-1", "-0.0001", "0", "0.00", "1e-1000", "0.1", "1", "1.000", "1.0000001", "99999999", "1e100", "Infinity", "NaN", "nan" };
    // the order of each value in that list: equal ones share a rank
    const rank = [_]u8{ 0, 1, 2, 3, 4, 5, 5, 6, 7, 8, 8, 9, 10, 11, 12, 13, 13 };
    for (vals, 0..) |x, i| {
        const na = try Numeric.parseAlloc(testing.allocator, x);
        defer freeNum(na);
        for (vals, 0..) |y, j| {
            const nb = try Numeric.parseAlloc(testing.allocator, y);
            defer freeNum(nb);
            try testing.expectEqual(std.math.order(rank[i], rank[j]), Numeric.order(na, nb));
            try testing.expectEqual(rank[i] == rank[j], Numeric.eql(na, nb));
        }
    }
    // unnormalised digits compare by value too
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const u = try Numeric.fromWire(wire(&b1, 1, 0, 0, &.{ 0, 5, 0 })); // 0005.0000 = 5
    const five = try Numeric.fromWire(wire(&b2, 0, 0, 0, &.{5}));
    try testing.expect(Numeric.eql(u, five));
    try testing.expect(Numeric.eql(Numeric.zero, try Numeric.fromWire(wire(&b1, 3, 0x4000, 2, &.{ 0, 0 }))));
}

test "Numeric predicates" {
    try testing.expect(Numeric.nan.isNaN() and !Numeric.nan.isFinite() and !Numeric.nan.isNegative() and !Numeric.nan.isZero());
    try testing.expect(Numeric.infinity.isInf() and Numeric.infinity.isPosInf() and !Numeric.infinity.isNegative());
    try testing.expect(Numeric.neg_infinity.isNegInf() and Numeric.neg_infinity.isNegative());
    try testing.expect(Numeric.zero.isZero() and Numeric.zero.isFinite() and !Numeric.zero.isNegative());
    const m = try Numeric.parseAlloc(testing.allocator, "-0.5");
    defer freeNum(m);
    try testing.expect(m.isNegative() and !m.isZero() and m.scale() == 1 and m.weight() == -1);
}

test "Numeric.toI64 / fromI64" {
    const cases = [_]struct { []const u8, ?i64 }{
        .{ "0", 0 },                       .{ "-0.000", 0 },                .{ "1.000", 1 },
        .{ "9223372036854775807", std.math.maxInt(i64) }, .{ "-9223372036854775808", std.math.minInt(i64) },
        .{ "123456789012", 123456789012 }, .{ "-10000", -10000 },           .{ "1e18", 1_000_000_000_000_000_000 },
    };
    for (cases) |c| {
        const n = try Numeric.parseAlloc(testing.allocator, c[0]);
        defer freeNum(n);
        try testing.expectEqual(c[1].?, try n.toI64());
        // and back: the same value, scale 0
        const back = try Numeric.fromI64Alloc(testing.allocator, c[1].?);
        defer freeNum(back);
        try testing.expect(Numeric.eql(n, back));
        try testing.expectEqual(@as(u16, 0), back.scale());
        _ = try Numeric.fromWire(back.wire);
        const t = try numText(back);
        defer testing.allocator.free(t);
        var fb: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&fb, "{d}", .{c[1].?}), t);
    }
    const errs = [_]struct { []const u8, anyerror }{
        .{ "9223372036854775808", error.Overflow }, .{ "-9223372036854775809", error.Overflow },
        .{ "1e100", error.Overflow },               .{ "0.5", error.NotIntegral },
        .{ "-1.0000001", error.NotIntegral },       .{ "1e-1000", error.NotIntegral },
        .{ "NaN", error.NotFinite },                .{ "-Infinity", error.NotFinite },
    };
    for (errs) |c| {
        const n = try Numeric.parseAlloc(testing.allocator, c[0]);
        defer freeNum(n);
        try testing.expectError(c[1], n.toI64());
    }
}

test "Numeric.toF64: correctly rounded, out of range is an error" {
    const cases = [_][]const u8{ "0.1", "1", "-2.5", "3.141592653589793238462643383279", "1e308", "1.7976931348623157e308", "4.9406564584124654e-324", "2.2250738585072014e-308", "123456789012345678901234567890", "-0.000000000000000000000001" };
    for (cases) |c| {
        const n = try Numeric.parseAlloc(testing.allocator, c);
        defer freeNum(n);
        try testing.expectEqual(try std.fmt.parseFloat(f64, c), try n.toF64());
    }
    const z = try Numeric.parseAlloc(testing.allocator, "0.000");
    defer freeNum(z);
    try testing.expectEqual(@as(f64, 0), try z.toF64());
    try testing.expect(std.math.isNan(try Numeric.nan.toF64()));
    try testing.expect(std.math.isPositiveInf(try Numeric.infinity.toF64()));
    try testing.expect(std.math.isNegativeInf(try Numeric.neg_infinity.toF64()));
    const big = try Numeric.parseAlloc(testing.allocator, "1e309");
    defer freeNum(big);
    try testing.expectError(error.Overflow, big.toF64());
    const tiny = try Numeric.parseAlloc(testing.allocator, "-1e-400");
    defer freeNum(tiny);
    try testing.expectError(error.Underflow, tiny.toF64());
    // more than 800 significant digits: the cut digits still round correctly
    // (0.5 + 2^-53 + tiny rounds up; without the tiny part it is a tie)
    var long: [1300]u8 = undefined;
    const half_ulp = "0.500000000000000055511151231257827021181583404541015625"; // 0.5 + 2^-54 exactly
    @memcpy(long[0..half_ulp.len], half_ulp);
    @memset(long[half_ulp.len..], '0');
    long[long.len - 1] = '1';
    const ln = try Numeric.parseAlloc(testing.allocator, &long);
    defer freeNum(ln);
    try testing.expectEqual(@as(f64, 0.5) + std.math.pow(f64, 2, -53), try ln.toF64());
    const tie = try Numeric.parseAlloc(testing.allocator, half_ulp);
    defer freeNum(tie);
    try testing.expectEqual(@as(f64, 0.5), try tie.toF64());
}

test "Numeric.fromF64: 15 significant digits of the exact value, as %.15g" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.1, "0.1" },
        .{ 1.0 / 3.0, "0.333333333333333" },
        .{ 2.0 / 3.0, "0.666666666666667" },
        .{ -1.5, "-1.5" },
        .{ 1e20, "100000000000000000000" },
        .{ 1.23456789012345678e17, "123456789012346000" },
        .{ 1e-5, "0.00001" },
        .{ 0.0, "0" },
        .{ -0.0, "0" },
        .{ 100, "100" },
        // exact ties at the 16th digit: half to even, from the exact binary value
        .{ std.math.pow(f64, 2, -22), "0.000000238418579101562" }, // 2.384185791015625e-07
        .{ 3 * std.math.pow(f64, 2, -22), "0.000000715255737304688" }, // 7.152557373046875e-07
        .{ std.math.pow(f64, 2, -21), "0.000000476837158203125" },
        .{ 9.999999999999999e22, "100000000000000000000000" }, // rounds up to a new power of ten
        .{ 1.7976931348623157e308, "179769313486232" ++ zeros(294) },
    };
    for (cases) |c| {
        const n = try Numeric.fromF64Alloc(testing.allocator, c[0]);
        defer freeNum(n);
        _ = try Numeric.fromWire(n.wire);
        const t = try numText(n);
        defer testing.allocator.free(t);
        testing.expectEqualStrings(c[1], t) catch |err| {
            std.debug.print("fromF64({e})\n", .{c[0]});
            return err;
        };
    }
    const sub = try Numeric.fromF64Alloc(testing.allocator, 5e-324);
    defer freeNum(sub);
    const st = try numText(sub);
    defer testing.allocator.free(st);
    try testing.expectEqualStrings("0." ++ zeros(323) ++ "494065645841247", st);
    try testing.expect((try Numeric.fromF64Alloc(testing.allocator, std.math.nan(f64))).isNaN());
    try testing.expect((try Numeric.fromF64Alloc(testing.allocator, -std.math.inf(f64))).isNegInf());
}

test "Numeric arithmetic: one host call, a second one for a result larger than the stack buffer" {
    try setup(64);
    const na = try Numeric.parse("1.5");
    const nb = try Numeric.parse("-2");
    env.numeric_calls = 0;
    const r = try na.add(nb);
    try testing.expectEqual(@as(usize, 1), env.numeric_calls);
    try testing.expectEqual(@as(u32, 1), env.last_numeric_op);
    try testing.expect(Numeric.eql(r, na)); // the stand-in returns operand a
    _ = try nb.sub(na);
    try testing.expectEqual(@as(u32, 2), env.last_numeric_op);
    _ = try na.round(-3);
    try testing.expectEqual(@as(u32, 7), env.last_numeric_op);
    try testing.expectEqual(@as(i32, -3), env.last_numeric_arg);
    inline for (.{ .{ "mul", 3 }, .{ "div", 4 }, .{ "divTrunc", 5 }, .{ "mod", 6 } }) |op| {
        _ = try @field(Numeric, op[0])(na, nb);
        try testing.expectEqual(@as(u32, op[1]), env.last_numeric_op);
    }
    _ = try na.trunc(2);
    try testing.expectEqual(@as(u32, 8), env.last_numeric_op);
    _ = try na.abs();
    try testing.expectEqual(@as(u32, 9), env.last_numeric_op);
    _ = try na.neg();
    try testing.expectEqual(@as(u32, 10), env.last_numeric_op);
    const big = try Numeric.parse("1" ++ zeros(2000) ++ ".5");
    env.numeric_calls = 0;
    const rb = try big.abs();
    try testing.expectEqual(@as(usize, 2), env.numeric_calls);
    try testing.expect(Numeric.eql(rb, big));
}

test "Numeric as typed column, parameter, argument and result" {
    try setup(64);
    const n = try Numeric.parse("-12.5");
    const r = try row(&.{ .{ .raw = .{ .kind = .numeric, .bytes = n.wire } }, .{ .null_of = .numeric }, .{ .other = "1" } });
    try testing.expect(Numeric.eql(n, try r.get(Numeric, 0)));
    try testing.expectEqual(@as(?Numeric, null), try r.get(?Numeric, 1));
    try testing.expectError(error.TypeMismatch, r.get(Numeric, 2));
    try testing.expectError(error.TypeMismatch, r.get([]const u8, 0));
    var plan = try plzig.spi.prepare("SELECT $1", &.{.numeric});
    try testing.expectEqual(@as(u32, 18), env.last_kinds[0]);
    _ = try plan.execute(.{n});
    try testing.expectEqual(@as(u16, 18), env.last_values[0].kind);
    try testing.expectEqual(@as(u32, @intCast(n.wire.len)), env.last_values[0].len);
    try testing.expectEqual(@as(u64, @intFromPtr(n.wire.ptr)), env.last_values[0].val);
    const d = sdk_root.decode(Numeric, &.{ .val = @intFromPtr(n.wire.ptr), .len = @intCast(n.wire.len), .is_null = 0 });
    try testing.expect(Numeric.eql(n, d));
    var out: Slot = undefined;
    sdk_root.encode(Numeric, n, &out);
    try testing.expectEqual(@as(u64, @intFromPtr(n.wire.ptr)), out.val);
    try testing.expectEqual(@as(u32, @intCast(n.wire.len)), out.len);
}

// ---------------------------------------------------------------------------
// calendar and time zones

test "Date.fromYmd: make_date's rules and PostgreSQL's range" {
    const D = plzig.Date;
    try testing.expectEqual(@as(i32, 0), (try D.fromYmd(2000, 1, 1)).days);
    try testing.expectEqual(@as(i32, -10957), (try D.fromYmd(1970, 1, 1)).days);
    try testing.expectEqual(@as(i32, 8825), (try D.fromYmd(2024, 2, 29)).days);
    try testing.expectEqual(@as(i32, -2451545), (try D.fromYmd(-4714, 11, 24)).days); // first day: 4714-11-24 BC
    try testing.expectEqual(@as(i32, 2145031948), (try D.fromYmd(5874897, 12, 31)).days); // last day
    try testing.expectEqual(@as(i32, -730120), (try D.fromYmd(-1, 12, 31)).days); // 1 BC
    try testing.expectEqual(@as(i32, -730119), (try D.fromYmd(1, 1, 1)).days);
    _ = try D.fromYmd(-1, 2, 29); // 1 BC is a leap year (astronomical 0)
    _ = try D.fromYmd(-5, 2, 29); // 5 BC = astronomical -4
    _ = try D.fromYmd(2000, 2, 29);
    for ([_][3]i32{ .{ 0, 1, 1 }, .{ 2023, 2, 29 }, .{ 1900, 2, 29 }, .{ -2, 2, 29 }, .{ 2024, 13, 1 }, .{ 2024, 0, 1 }, .{ 2024, 4, 31 }, .{ 2024, 1, 0 }, .{ 2024, 1, 32 }, .{ std.math.minInt(i32), 1, 1 } }) |f| {
        try testing.expectError(error.InvalidDate, D.fromYmd(f[0], @intCast(f[1]), @intCast(f[2])));
    }
    for ([_][3]i32{ .{ -4714, 11, 23 }, .{ -4714, 10, 31 }, .{ -5000, 1, 1 }, .{ 5874898, 1, 1 }, .{ 5874898, 6, 3 }, .{ std.math.maxInt(i32), 1, 1 }, .{ std.math.minInt(i32) + 1, 1, 1 } }) |f| {
        try testing.expectError(error.OutOfRange, D.fromYmd(f[0], @intCast(f[1]), @intCast(f[2])));
    }
}

test "Date.ymd, dayOfWeek, dayOfYear, toTimestamp: round trips over the whole range" {
    const D = plzig.Date;
    var d: i64 = -2451545;
    while (d <= 2145031948) : (d += 104729) {
        const x: D = .{ .days = @intCast(d) };
        const f = try x.ymd();
        try testing.expectEqual(x, try D.fromYmd(f.year, f.month, f.day));
        const doy = try x.dayOfYear();
        try testing.expect(doy >= 1 and doy <= 366);
        try testing.expectEqual(@as(u8, @intCast(@mod(d + 6, 7))), try x.dayOfWeek()); // 2000-01-01 was a Saturday
    }
    try testing.expectEqual(plzig.Ymd{ .year = -4714, .month = 11, .day = 24 }, try (D{ .days = -2451545 }).ymd());
    try testing.expectEqual(plzig.Ymd{ .year = -1, .month = 12, .day = 31 }, try (D{ .days = -730120 }).ymd());
    try testing.expectEqual(@as(u16, 366), try (try D.fromYmd(2024, 12, 31)).dayOfYear());
    try testing.expectEqual(@as(u8, 6), try (D{ .days = 0 }).dayOfWeek());
    try testing.expectError(error.NotFinite, D.infinity.ymd());
    try testing.expectError(error.NotFinite, D.neg_infinity.dayOfWeek());
    try testing.expectEqual(plzig.Timestamp{ .usecs = -86_400_000_000 }, try (D{ .days = -1 }).toTimestamp());
    try testing.expectEqual(plzig.Timestamp.infinity, try D.infinity.toTimestamp());
    try testing.expectError(error.OutOfRange, (D{ .days = 2145031948 }).toTimestamp());
}

test "Time and Timestamp fields: make_time/make_timestamp rules, leap seconds, the range" {
    const T = plzig.Time;
    const TS = plzig.Timestamp;
    try testing.expectEqual(@as(i64, 86_400_000_000), (try T.fromHms(24, 0, 0, 0)).usecs);
    try testing.expectEqual(@as(i64, 86_400_000_000), (try T.fromHms(23, 59, 60, 0)).usecs);
    try testing.expectEqual(@as(i64, 45_296_000_007), (try T.fromHms(12, 34, 56, 7)).usecs);
    for ([_][4]u32{ .{ 24, 0, 0, 1 }, .{ 25, 0, 0, 0 }, .{ 0, 60, 0, 0 }, .{ 0, 0, 61, 0 }, .{ 0, 0, 60, 1 }, .{ 0, 0, 0, 1_000_000 }, .{ 23, 59, 60, 1 } }) |f| {
        try testing.expectError(error.InvalidTime, T.fromHms(@intCast(f[0]), @intCast(f[1]), @intCast(f[2]), f[3]));
    }
    try testing.expectEqual(plzig.Hms{ .hour = 24, .minute = 0, .second = 0 }, (T{ .usecs = 86_400_000_000 }).hms());
    try testing.expectEqual(plzig.Hms{ .hour = 12, .minute = 34, .second = 56, .microsecond = 7 }, (T{ .usecs = 45_296_000_007 }).hms());

    try testing.expectEqual(TS{ .usecs = 0 }, try TS.fromFields(.{ .year = 2000, .month = 1, .day = 1 }));
    // leap second: carried into the next minute (here: the next year)
    try testing.expectEqual(try TS.fromFields(.{ .year = 2017, .month = 1, .day = 1 }), try TS.fromFields(.{ .year = 2016, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 60 }));
    try testing.expectEqual(TS{ .usecs = -211813488000000000 }, try TS.fromFields(.{ .year = -4714, .month = 11, .day = 24 }));
    try testing.expectEqual(TS{ .usecs = 9223371331199999999 }, try TS.fromFields(.{ .year = 294276, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .microsecond = 999_999 }));
    try testing.expectError(error.OutOfRange, TS.fromFields(.{ .year = 294277, .month = 1, .day = 1 }));
    // far beyond the timestamp range, but still a valid Julian day: no overflow
    try testing.expectError(error.OutOfRange, TS.fromFields(.{ .year = 5874897, .month = 12, .day = 31, .hour = 23 }));
    try testing.expectError(error.OutOfRange, TS.fromFields(.{ .year = 294277, .month = 12, .day = 1 }));
    try testing.expectError(error.OutOfRange, TS.fromFields(.{ .year = 294276, .month = 12, .day = 31, .hour = 24 }));
    try testing.expectError(error.InvalidDate, TS.fromFields(.{ .year = 0, .month = 1, .day = 1 }));
    try testing.expectError(error.InvalidTime, TS.fromFields(.{ .year = 2000, .month = 1, .day = 1, .hour = 24, .second = 1 }));
    // fields round trip, including before 2000 and BC (floor division)
    var t: i64 = -211813488000000000;
    while (t < 9223371331200000000 - 7_654_321_987_654_321) : (t += 7_654_321_987_654_321) {
        const x: TS = .{ .usecs = t };
        try testing.expectEqual(x, try TS.fromFields(try x.fields()));
        try testing.expectEqual(x.usecs, @as(i64, x.date().days) * 86_400_000_000 + (try x.time()).usecs);
    }
    try testing.expectEqual(plzig.DateTime{ .year = 1999, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .microsecond = 999_999 }, try (TS{ .usecs = -1 }).fields());
    try testing.expectEqual(plzig.Date{ .days = -1 }, (TS{ .usecs = -1 }).date());
    try testing.expectEqual(plzig.Date.infinity, TS.infinity.date());
    try testing.expectError(error.NotFinite, TS.neg_infinity.fields());
    try testing.expectError(error.NotFinite, TS.infinity.time());
}

test "TimestampTz: local time by the host (zone name passed through, null = session)" {
    try setup(64);
    const tz: plzig.TimestampTz = .{ .usecs = 0 };
    try testing.expectEqual(plzig.Timestamp{ .usecs = 3_600_000_000 }, tz.toLocal("Europe/Berlin"));
    try testing.expectEqual(@as(u32, 1), env.last_tz_op);
    try testing.expectEqualStrings("Europe/Berlin", env.last_tz_zone[0..env.last_tz_zone_len]);
    _ = tz.toLocal(null);
    try testing.expectEqual(@as(usize, 0), env.last_tz_zone_len);
    try testing.expectEqual(tz, plzig.TimestampTz.fromLocal(.{ .usecs = 3_600_000_000 }, "x"));
    try testing.expectEqual(@as(u32, 2), env.last_tz_op);
    const f = try tz.fields("UTC+1");
    try testing.expectEqual(@as(u8, 1), f.hour);
    try testing.expectEqual(tz, try plzig.TimestampTz.fromFields(f, "UTC+1"));
    try testing.expectError(error.NotFinite, plzig.TimestampTz.infinity.fields(null));
}

// ---------------------------------------------------------------------------
// jsonb: the on-disk layout, from byte fixtures that PostgreSQL produced
// (the JsonbContainer of each value, as the host passes it)

const JsonbFixture = struct { text: []const u8, hex: []const u8 };
const jsonb_fixtures = [_]JsonbFixture{
    .{ .text = "{\"a\": 1}", .hex = "01000020010000800b000010610000002000000000800100" },
    .{ .text = "[1, \"two\", null, true, false, {\"k\": []}, [3.5]]", .hex = "0700004008000090030000000000004000000030000000201500005012000050200000000080010074776f000100002001000080070000506b00000000000040010000400a00009028000000808003008813" },
    .{ .text = "\"h\xc3\xa9llo\"", .hex = "010000500600008068c3a96c6c6f" },
    .{ .text = "-12.5", .hex = "010000500a0000902800000080a00c008813" },
    .{ .text = "true", .hex = "01000050000000b0" },
    .{ .text = "{\"a\": 1, \"b\": 2, \"ab\": 5, \"cc\": 3, \"aaa\": 4}", .hex = "0500002001000080010000000200000002000000030000000b0000100800001008000010080000100800001061626162636361616100000020000000008001002000000000800200200000000080050020000000008003002000000000800400" },
    .{ .text = "[0, 1, -1, 1" ++ zeros(100) ++ ", -0." ++ zeros(99) ++ "1, 1" ++ zeros(300) ++ ", 0.1, 1." ++ zeros(73) ++ ", 123456789.123456789]", .hex = "09000040060000900a00001008000010080000100a0000100c0000100a0000100a00001014000010180000000080000020000000008001002000000000a001002000000019800100280000006440e7ff010000002800000000004b000100000020000000ff80e80328000000490000000100000048000000828401002909851ad2042e162823" },
    .{ .text = "[\"\", \"a\\\"b\\\\c\\u0001\\n\", {\"x\": {\"y\": {\"z\": [null]}}}]", .hex = "030000400000008007000000390000506122625c63010a0001000020010000802b0000507800000001000020010000801b0000507900000001000020010000800b0000507a00000001000040000000c0" },
    .{ .text = "[\"s0\", \"s1\", \"s2\", \"s3\", \"s4\", \"s5\", \"s6\", \"s7\", \"s8\", \"s9\", \"s10\", \"s11\", \"s12\", \"s13\", \"s14\", \"s15\", \"s16\", \"s17\", \"s18\", \"s19\", \"s20\", \"s21\", \"s22\", \"s23\", \"s24\", \"s25\", \"s26\", \"s27\", \"s28\", \"s29\", \"s30\", \"s31\", \"s32\", \"s33\", \"s34\", \"s35\", \"s36\", \"s37\", \"s38\", \"s39\"]", .hex = "28000040020000800200000002000000020000000200000002000000020000000200000002000000020000000300000003000000030000000300000003000000030000000300000003000000030000000300000003000000030000000300000003000000030000000300000003000000030000000300000003000000030000000300000059000080030000000300000003000000030000000300000003000000030000007330733173327333733473357336733773387339733130733131733132733133733134733135733136733137733138733139733230733231733232733233733234733235733236733237733238733239733330733331733332733333733334733335733336733337733338733339" },
};

fn hexBytes(buf: []u8, hex: []const u8) []u8 {
    for (0..hex.len / 2) |i| buf[i] = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch unreachable;
    return buf[0 .. hex.len / 2];
}

test "Jsonb: every fixture serialises exactly as jsonb_out" {
    var buf: [1024]u8 align(8) = undefined;
    for (jsonb_fixtures) |f| {
        const j: plzig.Jsonb = .{ .bytes = hexBytes(&buf, f.hex) };
        const t = try j.toJsonAlloc(testing.allocator);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings(f.text, t);
    }
}

test "Jsonb: object lookup by binary search (keys sorted by length, then bytes)" {
    var buf: [1024]u8 align(8) = undefined;
    const j: plzig.Jsonb = .{ .bytes = hexBytes(&buf, jsonb_fixtures[5].hex) };
    const o = (try j.root()).object;
    try testing.expectEqual(@as(usize, 5), o.len());
    const want = [_]struct { []const u8, i64 }{ .{ "a", 1 }, .{ "b", 2 }, .{ "ab", 5 }, .{ "cc", 3 }, .{ "aaa", 4 } };
    for (want, 0..) |w, i| {
        const v = (try o.get(w[0])).?;
        try testing.expectEqual(w[1], try v.number.toI64());
        const e = (try o.entry(i)).?; // storage order is the sort order
        try testing.expectEqualStrings(w[0], e.key);
    }
    for ([_][]const u8{ "", "c", "aa", "ba", "abc", "aaaa", "A" }) |k| try testing.expectEqual(@as(?plzig.JsonValue, null), try o.get(k));
    var it = o.iterator();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(?plzig.JsonObject.Entry, null), try o.entry(5));
}

test "Jsonb: arrays, nesting, scalars, strings with escapes and multibyte characters" {
    var buf: [1024]u8 align(8) = undefined;
    const arr = (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[1].hex) }).root()).array;
    try testing.expectEqual(@as(usize, 7), arr.len());
    try testing.expectEqual(@as(i64, 1), try (try arr.get(0)).?.number.toI64());
    try testing.expectEqualStrings("two", (try arr.get(1)).?.string);
    try testing.expect((try arr.get(2)).? == .null);
    try testing.expect((try arr.get(3)).?.bool and !(try arr.get(4)).?.bool);
    const inner = (try (try arr.get(5)).?.object.get("k")).?.array;
    try testing.expectEqual(@as(usize, 0), inner.len());
    try testing.expectEqual(@as(f64, 3.5), try (try (try arr.get(6)).?.array.get(0)).?.number.toF64());
    try testing.expectEqual(@as(?plzig.JsonValue, null), try arr.get(7));
    var it = arr.iterator();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 7), n);
    // a scalar at the root
    try testing.expectEqualStrings("h\xc3\xa9llo", (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[2].hex) }).root()).string);
    try testing.expectEqual(@as(f64, -12.5), try (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[3].hex) }).root()).number.toF64());
    try testing.expect((try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[4].hex) }).root()).bool);
    // escapes are not stored: the string's own bytes
    const e = (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[7].hex) }).root()).array;
    try testing.expectEqualStrings("a\"b\\c\x01\n", (try e.get(1)).?.string);
    // more than 32 elements: every 32nd JEntry stores an offset
    const big = (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[8].hex) }).root()).array;
    for (0..40) |i| {
        var nb: [8]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&nb, "s{d}", .{i}), (try big.get(i)).?.string);
    }
}

test "Jsonb: numbers in every on-disk numeric form" {
    var buf: [1024]u8 align(8) = undefined;
    const arr = (try (plzig.Jsonb{ .bytes = hexBytes(&buf, jsonb_fixtures[6].hex) }).root()).array;
    const texts = [_][]const u8{ "0", "1", "-1", "1" ++ zeros(100), "-0." ++ zeros(99) ++ "1", "1" ++ zeros(300), "0.1", "1." ++ zeros(73), "123456789.123456789" };
    for (texts, 0..) |t, i| {
        const n = try (try arr.get(i)).?.number.numericAlloc(testing.allocator);
        defer testing.allocator.free(n.wire);
        _ = try Numeric.fromWire(n.wire);
        const got = try numText(n);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(t, got);
    }
    try testing.expectEqual(@as(i64, -1), try (try arr.get(2)).?.number.toI64());
    try testing.expectError(error.NotIntegral, (try arr.get(6)).?.number.toI64());
    // NaN and the infinities (from to_jsonb of a numeric: not JSON numbers,
    // but valid on-disk numerics) and a 1-byte varlena header
    for ([_]struct { []const u8, []const u8 }{
        .{ "\x18\x00\x00\x00\x00\xc0", "NaN" }, .{ "\x18\x00\x00\x00\x00\xd0", "Infinity" }, .{ "\x18\x00\x00\x00\x00\xf0", "-Infinity" },
        .{ "\x0b\x00\x80\x07\x00", "7" }, // 1-byte header (size 5): short numeric 7
    }) |c| {
        const n = try (plzig.JsonNumber{ .raw = c[0][0..] }).numericAlloc(testing.allocator);
        defer testing.allocator.free(n.wire);
        const got = try numText(n);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "Jsonb: malformed bytes are error.InvalidJsonb, never a read outside the value" {
    var buf: [1024]u8 align(8) = undefined;
    var copy: [1024]u8 align(8) = undefined;
    for (jsonb_fixtures) |f| {
        const full = hexBytes(&buf, f.hex);
        // every prefix: a valid prefix of the root is fine, anything else an error
        for (0..full.len) |n| {
            @memcpy(copy[0..n], full[0..n]);
            walkAll(copy[0..n]);
        }
        // every byte, flipped in a few ways
        for (0..full.len) |i| {
            for ([_]u8{ 0x00, 0xff, 0x80, 0x01, 0x10, 0x50 }) |x| {
                @memcpy(copy[0..full.len], full);
                copy[i] ^= x;
                walkAll(copy[0..full.len]);
            }
        }
    }
    // specific shapes
    try testing.expectError(error.InvalidJsonb, (plzig.Jsonb{ .bytes = "" }).root());
    try testing.expectError(error.InvalidJsonb, (plzig.Jsonb{ .bytes = "\x01\x00\x00\x00" }).root()); // no flags
    try testing.expectError(error.InvalidJsonb, (plzig.Jsonb{ .bytes = "\x02\x00\x00\x50" }).root()); // scalar of 2
    try testing.expectError(error.InvalidJsonb, (plzig.Jsonb{ .bytes = "\xff\xff\xff\x4f" }).root()); // JEntries beyond the value
    try testing.expectError(error.InvalidJsonb, (plzig.Jsonb{ .bytes = "\x00\x00\x00\x60" }).root()); // array and object
    // a scalar container below the root
    const nested_scalar = "\x01\x00\x00\x40\x0c\x00\x00\x50\x01\x00\x00\x50\x00\x00\x00\x40";
    try testing.expectError(error.InvalidJsonb, (try (plzig.Jsonb{ .bytes = nested_scalar }).root()).array.get(0));
}

/// Read everything reachable in `bytes` (each value, each key looked up),
/// accepting any error: the property is only that nothing panics.
fn walkAll(bytes: []const u8) void {
    const j: plzig.Jsonb = .{ .bytes = bytes };
    const t = j.toJsonAlloc(testing.allocator) catch null;
    if (t) |x| testing.allocator.free(x);
    const r = j.root() catch return;
    walkValue(r, 0);
}

fn walkValue(v: plzig.JsonValue, depth: usize) void {
    if (depth > 64) return;
    switch (v) {
        .number => |n| {
            const w = n.numericAlloc(testing.allocator) catch return;
            defer testing.allocator.free(w.wire);
            _ = Numeric.fromWire(w.wire) catch unreachable; // what the decoder builds is valid
        },
        .array => |ar| {
            var it = ar.iterator();
            while (it.next() catch return) |x| walkValue(x, depth + 1);
            _ = ar.get(ar.len()) catch {};
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next() catch return) |e| {
                walkValue(e.value, depth + 1);
                _ = o.get(e.key) catch {};
            }
        },
        else => {},
    }
}

test "Jsonb as an argument, a typed column, and JsonText as result and parameter" {
    try setup(64);
    var buf: [64]u8 align(8) = undefined;
    const bytes = hexBytes(&buf, jsonb_fixtures[0].hex);
    const r = try row(&.{ .{ .raw = .{ .kind = .jsonb, .bytes = bytes } }, .{ .null_of = .jsonb }, .{ .text = "{}" } });
    const j = try r.get(plzig.Jsonb, 0);
    try testing.expectEqual(@as(i64, 1), try (try (try j.root()).object.get("a")).?.number.toI64());
    try testing.expectEqual(@as(?plzig.Jsonb, null), try r.get(?plzig.Jsonb, 1));
    try testing.expectError(error.TypeMismatch, r.get(plzig.Jsonb, 2));
    try testing.expectError(error.TypeMismatch, r.get([]const u8, 0));
    var plan = try plzig.spi.prepare("SELECT $1", &.{.jsonb});
    try testing.expectEqual(@as(u32, 19), env.last_kinds[0]);
    const jt = plzig.jsonText("[1]");
    _ = try plan.execute(.{jt});
    try testing.expectEqual(Value{ .val = @intFromPtr(jt.text.ptr), .len = 3, .kind = 19, .is_null = 0 }, env.last_values[0]);
    const d = sdk_root.decode(plzig.Jsonb, &.{ .val = @intFromPtr(bytes.ptr), .len = @intCast(bytes.len), .is_null = 0 });
    try testing.expectEqual(bytes.len, d.bytes.len);
    var out: Slot = undefined;
    sdk_root.encode(plzig.JsonText, jt, &out);
    try testing.expectEqual(Slot{ .val = @intFromPtr(jt.text.ptr), .len = 3, .is_null = 0 }, out);
}
