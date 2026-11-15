//! PL/Zig guest SDK.
//!
//! This module is available to every PL/Zig function body as `plzig`
//! (and its curated standard-library subset as `std`).  It is compiled for
//! wasm32-freestanding and runs inside the WebAssembly sandbox embedded in
//! the PostgreSQL backend.  The only way to reach the outside world is the
//! set of host imports declared in `host` below; see doc/abi.md.

const s = @import("std");

/// ABI version implemented by this SDK. Checked by the host at load time.
pub const abi_version: u32 = 4;

/// Size of the argument buffer (root.zig, plzig_init): argument blocks up to
/// this size need no allocation and no extra guest entry.
pub const arg_buffer_size: u32 = 4096;

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
        extern "plzig" fn raise_error(code_ptr: [*]const u8, code_len: u32, msg_ptr: [*]const u8, msg_len: u32, detail_ptr: [*]const u8, detail_len: u32, hint_ptr: [*]const u8, hint_len: u32) void;
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
        extern "plzig" fn spi_cursor_fetch(cursor: u64, buf: [*]u8, buf_len: u32) i64;
        extern "plzig" fn spi_cursor_close(cursor: u64) void;
        extern "plzig" fn tz_convert(op: u32, value: i64, zone_ptr: [*]const u8, zone_len: u32) i64;
        extern "plzig" fn numeric_op(op: u32, a_ptr: [*]const u8, a_len: u32, b_ptr: [*]const u8, b_len: u32, arg: i32, out_ptr: [*]u8, out_cap: u32) i32;
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
// Natively mapped fixed-width SQL types (doc/abi.md, "Kinds").
//
// Each is a distinct type, so a function signature maps to exactly one SQL
// type and a body that mixes them up does not compile.  The fields hold
// PostgreSQL's own representation; the host range-checks every value that
// comes back (a function result or an SPI parameter) exactly as the type's
// binary input function would, and raises an SQL error for an invalid one.

/// SQL `date`: days since 2000-01-01 (PostgreSQL's DateADT).  `infinity` and
/// `neg_infinity` are the SQL values 'infinity' and '-infinity'.
pub const Date = extern struct {
    days: i32,

    pub const infinity: Date = .{ .days = s.math.maxInt(i32) };
    pub const neg_infinity: Date = .{ .days = s.math.minInt(i32) };

    pub fn isFinite(self: Date) bool {
        return self.days != infinity.days and self.days != neg_infinity.days;
    }

    /// The date of a calendar day, as SQL make_date(year, month, day): the
    /// proleptic Gregorian calendar, a negative year is BC (-1 = 1 BC;
    /// there is no year 0).  error.InvalidDate for fields that are no day
    /// (year 0, month 13, February 30, ...), error.OutOfRange beyond
    /// PostgreSQL's date range (4714-11-24 BC .. 5874897-12-31).
    pub fn fromYmd(year: i32, month: u8, day: u8) CalendarError!Date {
        const y = try astronomicalYear(year, month, day);
        if (!isValidJulian(y, month)) return error.OutOfRange;
        const d = @as(i64, date2j(y, month, day)) - postgres_epoch_jdate;
        if (d < min_date_days or d > max_date_days) return error.OutOfRange;
        return .{ .days = @intCast(d) };
    }

    /// Year, month and day (as EXTRACT gives them: a negative year is BC).
    /// error.NotFinite for the infinities.
    pub fn ymd(self: Date) error{NotFinite}!Ymd {
        if (!self.isFinite()) return error.NotFinite;
        return j2date(@as(i64, self.days) + postgres_epoch_jdate);
    }

    /// Day of the week, 0 = Sunday .. 6 = Saturday (EXTRACT(dow)).
    pub fn dayOfWeek(self: Date) error{NotFinite}!u8 {
        if (!self.isFinite()) return error.NotFinite;
        return @intCast(@mod(@as(i64, self.days) + postgres_epoch_jdate + 1, 7));
    }

    /// Day of the year, 1 .. 366 (EXTRACT(doy)).
    pub fn dayOfYear(self: Date) error{NotFinite}!u16 {
        const d = try self.ymd();
        const y = astronomical(d.year);
        return @intCast(@as(i64, self.days) + postgres_epoch_jdate - date2j(y, 1, 1) + 1);
    }

    /// Midnight of this day (date::timestamp): the infinities stay
    /// infinities; error.OutOfRange past the end of the timestamp range.
    pub fn toTimestamp(self: Date) error{OutOfRange}!Timestamp {
        if (self.days == infinity.days) return Timestamp.infinity;
        if (self.days == neg_infinity.days) return Timestamp.neg_infinity;
        // date2timestamp: TIMESTAMP_END_JULIAN; earlier days all fit
        if (self.days >= 109203528 - postgres_epoch_jdate) return error.OutOfRange;
        return .{ .usecs = @as(i64, self.days) * usecs_per_day };
    }
};

/// A calendar day; `year` < 0 is BC (-1 = 1 BC), as EXTRACT(year) gives it.
pub const Ymd = struct { year: i32, month: u8, day: u8 };

/// A time of day; 24:00:00 is a valid time.
pub const Hms = struct { hour: u8, minute: u8, second: u8, microsecond: u32 = 0 };

/// A calendar day and a time of day (`year` < 0 is BC).
pub const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    microsecond: u32 = 0,
};

pub const CalendarError = error{ InvalidDate, InvalidTime, OutOfRange };

const postgres_epoch_jdate: i64 = 2451545; // date2j(2000, 1, 1)
const usecs_per_day: i64 = 86_400_000_000;
const min_date_days: i64 = 0 - postgres_epoch_jdate; // DATETIME_MIN_JULIAN
const max_date_days: i64 = 2147483494 - postgres_epoch_jdate - 1; // DATE_END_JULIAN
const min_timestamp: i64 = -211813488000000000; // MIN_TIMESTAMP
const end_timestamp: i64 = 9223371331200000000; // END_TIMESTAMP

/// PostgreSQL's date2j (proleptic Gregorian, astronomical year numbering).
fn date2j(year: i32, month: u8, day: u8) i32 {
    var y: i32 = year;
    var m: i32 = month;
    if (m > 2) {
        m += 1;
        y += 4800;
    } else {
        m += 13;
        y += 4799;
    }
    const century = @divTrunc(y, 100);
    var julian = y * 365 - 32167;
    julian += @divTrunc(y, 4) - century + @divTrunc(century, 4);
    julian += @divTrunc(7834 * m, 256) + day;
    return julian;
}

/// PostgreSQL's j2date; the year as EXTRACT gives it (BC negative).
fn j2date(jd: i64) Ymd {
    var julian: u32 = @intCast(jd + 32044);
    var quad: u32 = julian / 146097;
    const extra: u32 = (julian - quad * 146097) * 4 + 3;
    julian += 60 + quad * 3 + extra / 146097;
    quad = julian / 1461;
    julian -= quad * 1461;
    var y: i32 = @intCast(julian * 4 / 1461);
    julian = (if (y != 0) (julian + 305) % 365 else (julian + 306) % 366) + 123;
    y += @intCast(quad * 4);
    const year = y - 4800;
    const q2 = julian * 2141 / 65536;
    return .{
        .year = if (year > 0) year else year - 1,
        .month = @intCast((q2 + 10) % 12 + 1),
        .day = @intCast(julian - 7834 * q2 / 256),
    };
}

fn isLeap(y: i32) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// BC year (-1 = 1 BC) to astronomical numbering (1 BC = 0)
fn astronomical(year: i32) i32 {
    return if (year < 0) year + 1 else year;
}

/// ValidateDate for make_date's fields: no year 0, month 1..12, a day of
/// that month; the astronomical year
fn astronomicalYear(year: i32, month: u8, day: u8) CalendarError!i32 {
    if (year == 0 or year == s.math.minInt(i32)) return error.InvalidDate;
    const y = astronomical(year);
    if (month < 1 or month > 12 or day < 1) return error.InvalidDate;
    const days = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const last: u8 = if (month == 2 and isLeap(y)) 29 else days[month - 1];
    if (day > last) return error.InvalidDate;
    return y;
}

/// IS_VALID_JULIAN (4713-11-01 BC .. 5874898-06-xx, by month)
fn isValidJulian(y: i32, m: u8) bool {
    return (y > -4713 or (y == -4713 and m >= 11)) and (y < 5874898 or (y == 5874898 and m < 6));
}

/// float_time_overflows + tm2time: hour 0..24, minute 0..59, second 0..60
/// (60 only with microsecond 0: a leap second, carried into the next
/// minute), the total at most 24:00:00
fn timeFromFields(hour: u8, minute: u8, second: u8, microsecond: u32) CalendarError!i64 {
    if (hour > 24 or minute > 59 or microsecond > 999_999) return error.InvalidTime;
    const sec_us = @as(i64, second) * 1_000_000 + microsecond;
    if (sec_us > 60_000_000) return error.InvalidTime;
    const t = (@as(i64, hour) * 60 + minute) * 60_000_000 + sec_us;
    if (t > usecs_per_day) return error.InvalidTime;
    return t;
}

fn hmsOf(t: i64) Hms {
    var x = t;
    const hour = @divTrunc(x, 3_600_000_000);
    x -= hour * 3_600_000_000;
    const minute = @divTrunc(x, 60_000_000);
    x -= minute * 60_000_000;
    const second = @divTrunc(x, 1_000_000);
    return .{ .hour = @intCast(hour), .minute = @intCast(minute), .second = @intCast(second), .microsecond = @intCast(x - second * 1_000_000) };
}

/// SQL `time` (without time zone): microseconds since midnight,
/// 0 ..= 86_400_000_000 ('24:00:00' is a valid time).
pub const Time = extern struct {
    usecs: i64,

    /// The time of hour, minute, second and microsecond, as SQL make_time:
    /// hour 0..24, minute 0..59, second 0..60 (a leap second: 60 only with
    /// microsecond 0), at most 24:00:00; error.InvalidTime otherwise.
    pub fn fromHms(hour: u8, minute: u8, second: u8, microsecond: u32) CalendarError!Time {
        return .{ .usecs = try timeFromFields(hour, minute, second, microsecond) };
    }

    /// Hour, minute, second and microsecond (24:00:00 for the end of day).
    /// Assumes a valid time (0 ..= 86_400_000_000), as the host passes it.
    pub fn hms(self: Time) Hms {
        return hmsOf(s.math.clamp(self.usecs, 0, usecs_per_day));
    }
};

/// SQL `time with time zone`: microseconds since midnight and the zone
/// offset in seconds **west** of UTC, as PostgreSQL stores it ('12:00+02'
/// has `zone = -7200`); |zone| < 16 hours.
pub const TimeTz = extern struct {
    usecs: i64,
    zone: i32,
};

/// SQL `timestamp` (without time zone): microseconds since
/// 2000-01-01 00:00:00.
pub const Timestamp = extern struct {
    usecs: i64,

    pub const infinity: Timestamp = .{ .usecs = s.math.maxInt(i64) };
    pub const neg_infinity: Timestamp = .{ .usecs = s.math.minInt(i64) };

    pub fn isFinite(self: Timestamp) bool {
        return self.usecs != infinity.usecs and self.usecs != neg_infinity.usecs;
    }

    /// The timestamp of a calendar day and time of day, as SQL
    /// make_timestamp (a negative year is BC, second 60 a leap second).
    /// error.InvalidDate / error.InvalidTime for impossible fields,
    /// error.OutOfRange outside PostgreSQL's timestamp range.
    pub fn fromFields(f: DateTime) CalendarError!Timestamp {
        // the order of make_timestamp's checks: date fields, Julian range,
        // time fields, timestamp range
        const y = try astronomicalYear(f.year, f.month, f.day);
        if (!isValidJulian(y, f.month)) return error.OutOfRange;
        const t = try timeFromFields(f.hour, f.minute, f.second, f.microsecond);
        const d = @as(i64, date2j(y, f.month, f.day)) - postgres_epoch_jdate;
        const r = s.math.add(i64, s.math.mul(i64, d, usecs_per_day) catch return error.OutOfRange, t) catch return error.OutOfRange;
        if (r < min_timestamp or r >= end_timestamp) return error.OutOfRange;
        return .{ .usecs = r };
    }

    /// The calendar fields (timestamp2tm; a negative year is BC).
    /// error.NotFinite for the infinities.
    pub fn fields(self: Timestamp) error{NotFinite}!DateTime {
        if (!self.isFinite()) return error.NotFinite;
        const days = @divFloor(self.usecs, usecs_per_day);
        const d = j2date(days + postgres_epoch_jdate);
        const t = hmsOf(self.usecs - days * usecs_per_day);
        return .{ .year = d.year, .month = d.month, .day = d.day, .hour = t.hour, .minute = t.minute, .second = t.second, .microsecond = t.microsecond };
    }

    /// The day (timestamp::date); the infinities map to the date infinities.
    pub fn date(self: Timestamp) Date {
        if (self.usecs == infinity.usecs) return Date.infinity;
        if (self.usecs == neg_infinity.usecs) return Date.neg_infinity;
        return .{ .days = @intCast(@divFloor(self.usecs, usecs_per_day)) };
    }

    /// The time of day (timestamp::time); error.NotFinite for the infinities.
    pub fn time(self: Timestamp) error{NotFinite}!Time {
        if (!self.isFinite()) return error.NotFinite;
        return .{ .usecs = @mod(self.usecs, usecs_per_day) };
    }
};

/// SQL `timestamp with time zone`: microseconds since 2000-01-01 00:00:00 UTC.
pub const TimestampTz = extern struct {
    usecs: i64,

    pub const infinity: TimestampTz = .{ .usecs = s.math.maxInt(i64) };
    pub const neg_infinity: TimestampTz = .{ .usecs = s.math.minInt(i64) };

    pub fn isFinite(self: TimestampTz) bool {
        return self.usecs != infinity.usecs and self.usecs != neg_infinity.usecs;
    }

    /// The local time in time zone `zone` (`ts AT TIME ZONE zone`), or in
    /// the session's TimeZone if `zone` is null (`ts::timestamp`).  Done by
    /// the host with PostgreSQL's own time zone code; an unknown zone is an
    /// SQL error.  The infinities stay infinities.
    pub fn toLocal(self: TimestampTz, zone: ?[]const u8) Timestamp {
        return .{ .usecs = tzConvert(.to_local, self.usecs, zone) };
    }

    /// The moment at which the local time `local` occurs in time zone
    /// `zone` (`local AT TIME ZONE zone`), or in the session's TimeZone if
    /// `zone` is null (`local::timestamptz`); PostgreSQL's rules for
    /// skipped and repeated local times apply.
    pub fn fromLocal(local: Timestamp, zone: ?[]const u8) TimestampTz {
        return .{ .usecs = tzConvert(.from_local, local.usecs, zone) };
    }

    /// The calendar fields of the local time in `zone` (null: the session's
    /// TimeZone).  error.NotFinite for the infinities.
    pub fn fields(self: TimestampTz, zone: ?[]const u8) error{NotFinite}!DateTime {
        return self.toLocal(zone).fields();
    }

    /// The moment of a local calendar time in `zone` (null: the session's
    /// TimeZone), as SQL make_timestamptz.
    pub fn fromFields(f: DateTime, zone: ?[]const u8) CalendarError!TimestampTz {
        return fromLocal(try Timestamp.fromFields(f), zone);
    }
};

const TzOp = enum(u32) { to_local = 1, from_local = 2 };

fn tzConvert(op: TzOp, usecs: i64, zone: ?[]const u8) i64 {
    const z: []const u8 = zone orelse "";
    return host.tz_convert(@intFromEnum(op), usecs, z.ptr, hostLen(z));
}

/// SQL `interval`: PostgreSQL's three independent fields (an interval of
/// 1 month is not 30 days).  Same layout as PostgreSQL's Interval.
pub const Interval = extern struct {
    usecs: i64,
    days: i32,
    months: i32,
};

/// SQL `uuid`: the 16 bytes in network order.
pub const Uuid = extern struct {
    bytes: [16]u8,

    /// The canonical text form (lower case, as uuid_out writes it).
    pub fn format(self: Uuid, buf: *[36]u8) []const u8 {
        const hex = "0123456789abcdef";
        var o: usize = 0;
        for (self.bytes, 0..) |b, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[o] = '-';
                o += 1;
            }
            buf[o] = hex[b >> 4];
            buf[o + 1] = hex[b & 15];
            o += 2;
        }
        return buf[0..36];
    }

    /// Parse the forms uuid_in accepts: 32 hex digits (either case), a
    /// hyphen allowed after any group of four digits, optionally in braces.
    pub fn parse(text: []const u8) error{InvalidUuid}!Uuid {
        var t = text;
        if (t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}') t = t[1 .. t.len - 1];
        var out: Uuid = .{ .bytes = undefined };
        var n: usize = 0; // hex digits seen
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (c == '-' and n > 0 and n < 32 and n % 4 == 0 and i + 1 < t.len and t[i + 1] != '-') continue;
            const d: u8 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidUuid,
            };
            if (n >= 32) return error.InvalidUuid;
            if (n % 2 == 0) out.bytes[n / 2] = d << 4 else out.bytes[n / 2] |= d;
            n += 1;
        }
        if (n != 32) return error.InvalidUuid;
        return out;
    }
};

/// SQL `oid`.
pub const Oid = extern struct {
    value: u32,
};

// ---------------------------------------------------------------------------
// numeric (doc/abi.md, "numeric").
//
// A Numeric holds PostgreSQL's binary wire format (numeric_send), which is
// what the host passes in and what numeric_recv, the server's validating
// input path, reads back: so a value a function builds is always checked by
// PostgreSQL itself before it is used.  Inspection, comparison, conversion
// to and from i64/f64 and decimal text run in the guest; arithmetic is done
// by the host with PostgreSQL's own functions, so results are PostgreSQL's
// exactly.

/// SQL `numeric`: PostgreSQL's binary wire format (numeric_send), big
/// endian: u16 ndigits, i16 weight, u16 sign, u16 dscale, then ndigits
/// base-10000 digits; the value is the sum of digit[i] * 10000^(weight - i).
///
/// Values from the host (arguments, columns, results of arithmetic) and
/// from `fromWire`, `parse`, `fromI64` and `fromF64` are valid; the other
/// functions assume a valid value.  Build one from raw bytes only with
/// `fromWire`.  Results and SPI parameters are validated by the host with
/// numeric_recv either way.
pub const Numeric = struct {
    wire: []const u8,

    pub const sign_pos: u16 = 0x0000;
    pub const sign_neg: u16 = 0x4000;
    pub const sign_nan: u16 = 0xC000;
    pub const sign_pinf: u16 = 0xD000;
    pub const sign_ninf: u16 = 0xF000;
    /// largest dscale (NUMERIC_DSCALE_MAX) and number of digits of a value
    pub const max_dscale: u16 = 0x3FFF;
    pub const max_ndigits: usize = 0xFFFF;

    pub const nan: Numeric = .{ .wire = &[8]u8{ 0, 0, 0, 0, 0xC0, 0, 0, 0 } };
    pub const infinity: Numeric = .{ .wire = &[8]u8{ 0, 0, 0, 0, 0xD0, 0, 0, 0 } };
    pub const neg_infinity: Numeric = .{ .wire = &[8]u8{ 0, 0, 0, 0, 0xF0, 0, 0, 0 } };
    pub const zero: Numeric = .{ .wire = &[8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } };

    fn be16(self: Numeric, off: usize) u16 {
        return (@as(u16, self.wire[off]) << 8) | self.wire[off + 1];
    }
    fn ndigits(self: Numeric) usize {
        return self.be16(0);
    }
    /// Weight of the first digit (power of 10000).
    pub fn weight(self: Numeric) i16 {
        return @bitCast(self.be16(2));
    }
    /// The sign field: sign_pos, sign_neg, sign_nan, sign_pinf or sign_ninf.
    pub fn signField(self: Numeric) u16 {
        return self.be16(4);
    }
    /// Display scale: the number of digits after the decimal point.
    pub fn scale(self: Numeric) u16 {
        return self.be16(6);
    }
    /// Base-10000 digit `i` (0 <= i < number of digits).
    fn digit(self: Numeric, i: usize) u16 {
        return self.be16(8 + 2 * i);
    }
    /// digit i, or 0 outside the stored digits (signed index)
    fn digitAt(self: Numeric, i: i64) u16 {
        if (i < 0 or i >= self.ndigits()) return 0;
        return self.digit(@intCast(i));
    }

    /// A Numeric over `bytes` (not copied) after checking the layout as
    /// numeric_recv would: the length matches ndigits, a known sign, a
    /// dscale that fits, every digit below 10000.
    pub fn fromWire(bytes: []const u8) error{InvalidNumeric}!Numeric {
        const n: Numeric = .{ .wire = bytes };
        if (bytes.len < 8) return error.InvalidNumeric;
        const nd = n.be16(0);
        if (bytes.len != 8 + 2 * @as(usize, nd)) return error.InvalidNumeric;
        const sg = n.be16(4);
        if (sg != sign_pos and sg != sign_neg and sg != sign_nan and sg != sign_pinf and sg != sign_ninf)
            return error.InvalidNumeric;
        if (n.be16(6) & ~max_dscale != 0) return error.InvalidNumeric;
        for (0..nd) |i| {
            if (n.digit(i) >= 10000) return error.InvalidNumeric;
        }
        return n;
    }

    pub fn isNaN(self: Numeric) bool {
        return self.signField() == sign_nan;
    }
    pub fn isPosInf(self: Numeric) bool {
        return self.signField() == sign_pinf;
    }
    pub fn isNegInf(self: Numeric) bool {
        return self.signField() == sign_ninf;
    }
    /// +Infinity or -Infinity.
    pub fn isInf(self: Numeric) bool {
        return self.isPosInf() or self.isNegInf();
    }
    /// Neither NaN nor an infinity.
    pub fn isFinite(self: Numeric) bool {
        const sg = self.signField();
        return sg == sign_pos or sg == sign_neg;
    }
    /// A finite zero (of any scale).
    pub fn isZero(self: Numeric) bool {
        if (!self.isFinite()) return false;
        for (0..self.ndigits()) |i| {
            if (self.digit(i) != 0) return false;
        }
        return true;
    }
    /// Below zero: -Infinity or a negative finite value (not NaN, not zero).
    pub fn isNegative(self: Numeric) bool {
        if (self.isNegInf()) return true;
        return self.signField() == sign_neg and !self.isZero();
    }

    /// PostgreSQL's ordering (cmp_numerics): NaN equals NaN and is greater
    /// than everything else; -Infinity < every finite value < +Infinity;
    /// finite values by value, whatever their scale (1.0 = 1.00).
    pub fn order(a: Numeric, b: Numeric) s.math.Order {
        if (a.isNaN()) return if (b.isNaN()) .eq else .gt;
        if (b.isNaN()) return .lt;
        if (a.isPosInf()) return if (b.isPosInf()) .eq else .gt;
        if (a.isNegInf()) return if (b.isNegInf()) .eq else .lt;
        if (b.isPosInf()) return .lt;
        if (b.isNegInf()) return .gt;
        return cmpVarCommon(a, b);
    }

    /// `order(a, b) == .eq`.
    pub fn eql(a: Numeric, b: Numeric) bool {
        return order(a, b) == .eq;
    }

    // cmp_var_common of numeric.c; a value whose digits are all zero counts
    // as zero (numeric_recv never produces one, fromWire accepts it)
    fn cmpVarCommon(a: Numeric, b: Numeric) s.math.Order {
        const na: usize = if (a.isZero()) 0 else a.ndigits();
        const nb: usize = if (b.isZero()) 0 else b.ndigits();
        const a_neg = a.signField() == sign_neg;
        const b_neg = b.signField() == sign_neg;
        if (na == 0) {
            if (nb == 0) return .eq;
            return if (b_neg) .gt else .lt;
        }
        if (nb == 0) return if (!a_neg) .gt else .lt;
        if (!a_neg) {
            if (b_neg) return .gt;
            return cmpAbsCommon(a, b);
        }
        if (!b_neg) return .lt;
        return cmpAbsCommon(b, a);
    }

    // cmp_abs_common of numeric.c (also correct for unnormalised digits)
    fn cmpAbsCommon(a: Numeric, b: Numeric) s.math.Order {
        const n1 = a.ndigits();
        const n2 = b.ndigits();
        var w1: i32 = a.weight();
        var w2: i32 = b.weight();
        var k1: usize = 0;
        var k2: usize = 0;
        while (w1 > w2 and k1 < n1) {
            if (a.digit(k1) != 0) return .gt;
            k1 += 1;
            w1 -= 1;
        }
        while (w2 > w1 and k2 < n2) {
            if (b.digit(k2) != 0) return .lt;
            k2 += 1;
            w2 -= 1;
        }
        if (w1 == w2) {
            while (k1 < n1 and k2 < n2) {
                const d1 = a.digit(k1);
                const d2 = b.digit(k2);
                k1 += 1;
                k2 += 1;
                if (d1 != d2) return if (d1 > d2) .gt else .lt;
            }
        }
        while (k1 < n1) : (k1 += 1) {
            if (a.digit(k1) != 0) return .gt;
        }
        while (k2 < n2) : (k2 += 1) {
            if (b.digit(k2) != 0) return .lt;
        }
        return .eq;
    }

    pub const ToIntError = error{ NotFinite, NotIntegral, Overflow };

    /// The value as an i64.  NaN and infinities are error.NotFinite, a
    /// value with a nonzero fractional part error.NotIntegral (never
    /// rounded; round first with `round(0)` for PostgreSQL's numeric::bigint
    /// behaviour), one outside the i64 range error.Overflow.
    pub fn toI64(self: Numeric) ToIntError!i64 {
        return self.view().toI64();
    }

    pub const ToFloatError = error{ Overflow, Underflow };

    /// The nearest f64, as PostgreSQL's numeric::double precision computes
    /// it (correctly rounded); NaN and the infinities map to theirs.  A
    /// finite value beyond the f64 range is error.Overflow, a nonzero value
    /// that rounds to zero error.Underflow (PostgreSQL raises "out of range"
    /// for both).
    pub fn toF64(self: Numeric) ToFloatError!f64 {
        return self.view().toF64();
    }

    fn view(self: Numeric) DigitView {
        return .{ .sign = self.signField(), .weight = self.weight(), .digits = self.wire[8..], .le = false };
    }

    /// The value of an i64 (scale 0), in the per-call arena.
    pub fn fromI64(v: i64) error{OutOfMemory}!Numeric {
        return fromI64Alloc(allocator, v);
    }

    /// `fromI64` with a given allocator.
    pub fn fromI64Alloc(gpa: s.mem.Allocator, v: i64) error{OutOfMemory}!Numeric {
        var mag: u64 = @abs(v);
        var rev: [5]u16 = undefined; // least significant first
        var n: usize = 0;
        while (mag != 0) : (mag /= 10000) {
            rev[n] = @intCast(mag % 10000);
            n += 1;
        }
        if (n == 0) return zero;
        const w: i16 = @intCast(n - 1);
        var lo: usize = 0; // trailing zero digits are not stored
        while (rev[lo] == 0) lo += 1;
        const nd = n - lo;
        const out = try allocBytes(gpa, 8 + 2 * nd);
        put16(out, 0, @intCast(nd));
        put16(out, 2, @bitCast(w));
        put16(out, 4, if (v < 0) sign_neg else sign_pos);
        put16(out, 6, 0);
        for (0..nd) |i| put16(out, 8 + 2 * i, rev[n - 1 - i]);
        return .{ .wire = out };
    }

    /// The value PostgreSQL's double precision::numeric gives: the f64
    /// rounded to 15 significant decimal digits (as `%.15g` does, from the
    /// exact binary value), NaN and the infinities to theirs.  In the
    /// per-call arena.
    pub fn fromF64(v: f64) error{OutOfMemory}!Numeric {
        return fromF64Alloc(allocator, v);
    }

    /// `fromF64` with a given allocator.
    pub fn fromF64Alloc(gpa: s.mem.Allocator, v: f64) error{OutOfMemory}!Numeric {
        if (s.math.isNan(v)) return nan;
        if (s.math.isInf(v)) return if (v > 0) infinity else neg_infinity;
        if (v == 0) return zero;
        var d: [15]u8 = undefined;
        const e10 = decimalDigits15(@abs(v), &d);
        var n: usize = 15;
        while (d[n - 1] == 0) n -= 1;
        const src: DigitArray = .{ .d = d[0..n] };
        // value = 0.d1d2...dn * 10^(e10 + 1); dscale as numeric_in derives it
        return buildDecimal(gpa, v < 0, src, e10, @max(0, @as(i64, @intCast(n)) - 1 - e10)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // 15 digits and |exponent| < 330 always fit
        };
    }

    pub const ParseError = error{ InvalidCharacter, Overflow, OutOfMemory };

    /// Parse decimal text the way numeric_in does: optional surrounding
    /// white space, an optional sign, digits with an optional decimal point,
    /// an optional exponent (`1.5e-3`), or NaN, Infinity, -Infinity, inf,
    /// -inf (any case).  Underscores and the 0x/0o/0b forms (PostgreSQL 16+)
    /// are refused.  The scale is the one numeric_in gives (digits after the
    /// point minus the exponent, at least 0).  A value beyond the numeric
    /// format (weight, scale or number of digits) is error.Overflow.  In the
    /// per-call arena.
    pub fn parse(text: []const u8) ParseError!Numeric {
        return parseAlloc(allocator, text);
    }

    /// `parse` with a given allocator.
    pub fn parseAlloc(gpa: s.mem.Allocator, text: []const u8) ParseError!Numeric {
        const ws = " \t\n\r\x0b\x0c";
        const t = s.mem.trim(u8, text, ws);
        const specials = [_]struct { []const u8, Numeric }{
            .{ "nan", nan },            .{ "infinity", infinity }, .{ "+infinity", infinity },
            .{ "-infinity", neg_infinity }, .{ "inf", infinity },  .{ "+inf", infinity },
            .{ "-inf", neg_infinity },
        };
        for (specials) |sp| {
            if (s.ascii.eqlIgnoreCase(t, sp[0])) return sp[1];
        }
        var i: usize = 0;
        var negative = false;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) {
            negative = t[i] == '-';
            i += 1;
        }
        const first = i; // first digit or the point
        var dot: ?usize = null;
        var ddigits: usize = 0;
        var before: usize = 0; // digits before the point
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (c >= '0' and c <= '9') {
                ddigits += 1;
                if (dot == null) before += 1;
            } else if (c == '.' and dot == null) {
                dot = i;
            } else break;
        }
        if (ddigits == 0) return error.InvalidCharacter;
        const end = i;
        var exponent: i64 = 0;
        if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
            i += 1;
            var eneg = false;
            if (i < t.len and (t[i] == '+' or t[i] == '-')) {
                eneg = t[i] == '-';
                i += 1;
            }
            if (i >= t.len or t[i] < '0' or t[i] > '9') return error.InvalidCharacter;
            while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
                exponent = exponent * 10 + (t[i] - '0');
                if (exponent > s.math.maxInt(i32) / 2) return error.Overflow;
            }
            if (eneg) exponent = -exponent;
        }
        if (i != t.len) return error.InvalidCharacter;
        const src: DigitText = .{ .t = t[first..end], .dot = if (dot) |d| d - first else null, .n = ddigits };
        const dweight = @as(i64, @intCast(before)) - 1 + exponent;
        const dscale = @max(0, @as(i64, @intCast(ddigits - before)) - exponent);
        return buildDecimal(gpa, negative, src, dweight, dscale);
    }

    const DigitArray = struct {
        d: []const u8,
        fn len(self: DigitArray) usize {
            return self.d.len;
        }
        fn get(self: DigitArray, i: usize) u8 {
            return self.d[i];
        }
    };

    const DigitText = struct {
        t: []const u8,
        dot: ?usize,
        n: usize,
        fn len(self: DigitText) usize {
            return self.n;
        }
        fn get(self: DigitText, i: usize) u8 {
            const pos = if (self.dot) |d| (if (i >= d) i + 1 else i) else i;
            return self.t[pos] - '0';
        }
    };

    /// set_var_from_str's conversion of decimal digits (src, whose first
    /// digit has decimal weight dweight) to base 10000, then strip_var and
    /// make_result's limits.
    fn buildDecimal(gpa: s.mem.Allocator, negative: bool, src: anytype, dweight: i64, dscale: i64) ParseError!Numeric {
        if (dscale > max_dscale) return error.Overflow;
        const ddigits: i64 = @intCast(src.len());
        const w: i64 = if (dweight >= 0) @divTrunc(dweight + 4, 4) - 1 else -(@divTrunc(-dweight - 1, 4) + 1);
        const offset: i64 = (w + 1) * 4 - (dweight + 1);
        const total: i64 = @divTrunc(ddigits + offset + 3, 4);
        var j0: i64 = 0;
        while (j0 < total and baseDigit(src, offset, ddigits, j0) == 0) j0 += 1;
        if (j0 == total) {
            // zero: weight 0, positive (make_result)
            const out = try allocBytes(gpa, 8);
            @memset(out, 0);
            put16(out, 6, @intCast(dscale));
            return .{ .wire = out };
        }
        var j1: i64 = total - 1;
        while (baseDigit(src, offset, ddigits, j1) == 0) j1 -= 1;
        const nd = j1 - j0 + 1;
        const fw = w - j0;
        if (nd > max_ndigits or fw > s.math.maxInt(i16) or fw < s.math.minInt(i16)) return error.Overflow;
        const out = try allocBytes(gpa, 8 + 2 * @as(usize, @intCast(nd)));
        put16(out, 0, @intCast(nd));
        put16(out, 2, @bitCast(@as(i16, @intCast(fw))));
        put16(out, 4, if (negative) sign_neg else sign_pos);
        put16(out, 6, @intCast(dscale));
        var j = j0;
        while (j <= j1) : (j += 1) put16(out, 8 + 2 * @as(usize, @intCast(j - j0)), baseDigit(src, offset, ddigits, j));
        return .{ .wire = out };
    }

    /// base-10000 digit j of decimal digits src aligned by offset
    fn baseDigit(src: anytype, offset: i64, nd: i64, j: i64) u16 {
        var v: u16 = 0;
        var k: i64 = 0;
        while (k < 4) : (k += 1) {
            const p = j * 4 - offset + k;
            v = v * 10 + (if (p >= 0 and p < nd) src.get(@intCast(p)) else 0);
        }
        return v;
    }

    fn put16(out: []u8, off: usize, v: u16) void {
        out[off] = @intCast(v >> 8);
        out[off + 1] = @truncate(v);
    }

    /// numeric_out's text (get_str_from_var), written to `sink`
    fn emit(self: Numeric, sink: anytype) !void {
        switch (self.signField()) {
            sign_nan => return sink.puts("NaN"),
            sign_pinf => return sink.puts("Infinity"),
            sign_ninf => return sink.puts("-Infinity"),
            else => {},
        }
        const w: i64 = self.weight();
        const dscale = self.scale();
        if (self.signField() == sign_neg) try sink.put('-');
        var d: i64 = undefined;
        if (w < 0) {
            d = w + 1;
            try sink.put('0');
        } else {
            d = 0;
            while (d <= w) : (d += 1) {
                var dig = self.digitAt(d);
                var putit = d > 0;
                inline for ([_]u16{ 1000, 100, 10 }) |p| {
                    const q = dig / p;
                    dig -= q * p;
                    putit = putit or q > 0;
                    if (putit) try sink.put('0' + @as(u8, @intCast(q)));
                }
                try sink.put('0' + @as(u8, @intCast(dig)));
            }
        }
        if (dscale > 0) {
            try sink.put('.');
            var left: usize = dscale;
            while (left > 0) : (d += 1) {
                const dig = self.digitAt(d);
                const four = [4]u8{
                    @intCast(dig / 1000), @intCast(dig / 100 % 10), @intCast(dig / 10 % 10), @intCast(dig % 10),
                };
                for (four[0..@min(4, left)]) |c| try sink.put('0' + c);
                left -= @min(4, left);
            }
        }
    }

    const CountSink = struct {
        n: usize = 0,
        fn put(self: *CountSink, c: u8) error{}!void {
            _ = c;
            self.n += 1;
        }
        fn puts(self: *CountSink, t: []const u8) error{}!void {
            self.n += t.len;
        }
    };
    const BufSink = struct {
        buf: []u8,
        n: usize = 0,
        fn put(self: *BufSink, c: u8) error{}!void {
            self.buf[self.n] = c;
            self.n += 1;
        }
        fn puts(self: *BufSink, t: []const u8) error{}!void {
            @memcpy(self.buf[self.n..][0..t.len], t);
            self.n += t.len;
        }
    };
    const WriterSink = struct {
        w: *s.Io.Writer,
        fn put(self: *WriterSink, c: u8) s.Io.Writer.Error!void {
            return self.w.writeByte(c);
        }
        fn puts(self: *WriterSink, t: []const u8) s.Io.Writer.Error!void {
            return self.w.writeAll(t);
        }
    };

    /// Length of the decimal text (numeric_out's).
    pub fn textLen(self: Numeric) usize {
        var c: CountSink = .{};
        self.emit(&c) catch unreachable;
        return c.n;
    }

    /// The decimal text exactly as numeric_out writes it (`NaN`,
    /// `Infinity`, `-Infinity`, or digits with the value's scale), in the
    /// per-call arena.
    pub fn toText(self: Numeric) error{OutOfMemory}![]u8 {
        return self.toTextAlloc(allocator);
    }

    /// `toText` with a given allocator.
    pub fn toTextAlloc(self: Numeric, gpa: s.mem.Allocator) error{OutOfMemory}![]u8 {
        const out = try gpa.alloc(u8, self.textLen());
        var b: BufSink = .{ .buf = out };
        self.emit(&b) catch unreachable;
        return out;
    }

    /// For `{f}` in format strings: the text of `toText`.
    pub fn format(self: Numeric, w: *s.Io.Writer) s.Io.Writer.Error!void {
        var ws: WriterSink = .{ .w = w };
        return self.emit(&ws);
    }

    // -- arithmetic, by the host (PostgreSQL's numeric functions) ----------

    const Op = enum(u32) { add = 1, sub = 2, mul = 3, div = 4, div_trunc = 5, mod = 6, round = 7, trunc = 8, abs = 9, neg = 10 };

    /// The host writes the result straight into arena memory taken without
    /// the 0xAA fill (64 bytes: up to 28 base-10000 digits), whose unused
    /// tail is given back at once; a larger result is computed again into a
    /// block of the size the host reported.
    fn hostOp(op: Op, a: Numeric, b: Numeric, arg: i32) error{OutOfMemory}!Numeric {
        const first = 64;
        const p = allocator.rawAlloc(first, .@"1", @returnAddress()) orelse return error.OutOfMemory;
        const n = host.numeric_op(@intFromEnum(op), a.wire.ptr, hostLen(a.wire), b.wire.ptr, hostLen(b.wire), arg, p, first);
        if (n >= 0) {
            const len: usize = @intCast(n);
            // the most recent arena allocation: shrinks in place
            _ = allocator.rawResize(p[0..first], .@"1", len, @returnAddress());
            return .{ .wire = p[0..len] };
        }
        allocator.rawFree(p[0..first], .@"1", @returnAddress());
        const out = try allocBytes(allocator, @intCast(-@as(i64, n)));
        if (host.numeric_op(@intFromEnum(op), a.wire.ptr, hostLen(a.wire), b.wire.ptr, hostLen(b.wire), arg, out.ptr, hostLen(out)) != out.len)
            raiseMsg("plzig: numeric result changed size");
        return .{ .wire = out };
    }

    /// a + b (PostgreSQL's numeric +).  Results are in the per-call arena.
    pub fn add(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.add, a, b, 0);
    }
    /// a - b
    pub fn sub(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.sub, a, b, 0);
    }
    /// a * b
    pub fn mul(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.mul, a, b, 0);
    }
    /// a / b, with PostgreSQL's choice of result scale; division by zero
    /// is an SQL error (22012), as in SQL.
    pub fn div(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.div, a, b, 0);
    }
    /// a / b truncated towards zero (SQL div(a, b)).
    pub fn divTrunc(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.div_trunc, a, b, 0);
    }
    /// Remainder with the sign of a (SQL a % b, mod(a, b)).
    pub fn mod(a: Numeric, b: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.mod, a, b, 0);
    }
    /// Round half away from zero to `digits` decimal places (negative:
    /// to the left of the point), SQL round(a, digits).
    pub fn round(a: Numeric, digits: i32) error{OutOfMemory}!Numeric {
        return hostOp(.round, a, zero, digits);
    }
    /// Truncate towards zero to `digits` decimal places, SQL trunc(a, digits).
    pub fn trunc(a: Numeric, digits: i32) error{OutOfMemory}!Numeric {
        return hostOp(.trunc, a, zero, digits);
    }
    /// |a|
    pub fn abs(a: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.abs, a, zero, 0);
    }
    /// -a
    pub fn neg(a: Numeric) error{OutOfMemory}!Numeric {
        return hostOp(.neg, a, zero, 0);
    }
};

/// The sign, weight and base-10000 digits of a numeric, read in place from
/// the wire format (big endian) or from the on-disk format inside a jsonb
/// (little endian): the conversions to i64/f64 work on either without
/// copying the digits first.
const DigitView = struct {
    sign: u16,
    weight: i16,
    digits: []const u8,
    le: bool,

    fn len(self: DigitView) usize {
        return self.digits.len / 2;
    }
    fn at(self: DigitView, i: usize) u16 {
        const b0: u16 = self.digits[2 * i];
        const b1: u16 = self.digits[2 * i + 1];
        return if (self.le) b0 | (b1 << 8) else (b0 << 8) | b1;
    }
    fn fastF64(self: DigitView) ?f64 {
        return fastF64Impl(self);
    }
    fn atSigned(self: DigitView, i: i64) u16 {
        if (i < 0 or i >= self.len()) return 0;
        return self.at(@intCast(i));
    }

    /// Numeric.toI64
    fn toI64(self: DigitView) Numeric.ToIntError!i64 {
        if (self.sign != Numeric.sign_pos and self.sign != Numeric.sign_neg) return error.NotFinite;
        const nd = self.len();
        const w: i64 = self.weight;
        // digits at index > weight are fractional
        var i: i64 = @max(w + 1, 0);
        while (i < nd) : (i += 1) {
            if (self.at(@intCast(i)) != 0) return error.NotIntegral;
        }
        var mag: u64 = 0;
        i = 0;
        while (i <= w) : (i += 1) {
            // mag * 10000 + d without overflow; a plain comparison instead of
            // std.math.mul, which needs a 128-bit multiply (__multi3) on wasm32
            const d: u64 = self.atSigned(i);
            if (mag > (s.math.maxInt(u64) - d) / 10000) return error.Overflow;
            mag = mag * 10000 + d;
        }
        if (self.sign == Numeric.sign_neg) {
            if (mag > @as(u64, 1) << 63) return error.Overflow;
            return @bitCast(0 -% mag);
        }
        if (mag > s.math.maxInt(i64)) return error.Overflow;
        return @intCast(mag);
    }

    /// Numeric.toF64: "[-]0.<digits>e<exp>" parsed by std.fmt.parseFloat;
    /// at most 800 significant digits, followed by a sticky 1 if anything
    /// nonzero was cut (enough for correct rounding: f64 needs at most 767
    /// significant digits).  The text goes to a static buffer: no per-call
    /// fill of a large stack array (the guest is single-threaded and nothing
    /// here calls out).
    fn toF64(self: DigitView) Numeric.ToFloatError!f64 {
        switch (self.sign) {
            Numeric.sign_nan => return s.math.nan(f64),
            Numeric.sign_pinf => return s.math.inf(f64),
            Numeric.sign_ninf => return -s.math.inf(f64),
            else => {},
        }
        if (self.fastF64()) |v| return v;
        const buf = &f64_text;
        var n: usize = 0;
        if (self.sign == Numeric.sign_neg) {
            buf[n] = '-';
            n += 1;
        }
        buf[n] = '0';
        buf[n + 1] = '.';
        n += 2;
        const start = n;
        var nonzero = false;
        var sticky = false;
        for (0..self.len()) |i| {
            const d = self.at(i);
            if (d != 0) nonzero = true;
            if (n - start >= 800) {
                if (d != 0) sticky = true;
                continue;
            }
            buf[n] = '0' + @as(u8, @intCast(d / 1000));
            buf[n + 1] = '0' + @as(u8, @intCast(d / 100 % 10));
            buf[n + 2] = '0' + @as(u8, @intCast(d / 10 % 10));
            buf[n + 3] = '0' + @as(u8, @intCast(d % 10));
            n += 4;
        }
        if (!nonzero) return 0;
        if (sticky) {
            buf[n] = '1';
            n += 1;
        }
        const e = s.fmt.bufPrint(buf[n..], "e{d}", .{(@as(i32, self.weight) + 1) * 4}) catch unreachable;
        n += e.len;
        const v = s.fmt.parseFloat(f64, buf[0..n]) catch unreachable;
        if (s.math.isInf(v)) return error.Overflow;
        if (v == 0) return error.Underflow;
        return v;
    }
};

/// Exact fast path for the common case (Clinger): the significant digits
/// form an integer m <= 2^53 and the decimal exponent e has |e| <= 22, so m
/// and 10^|e| are exact doubles and one multiplication or division rounds
/// correctly.  null when it does not apply (then the text path decides).
fn fastF64Impl(self: DigitView) ?f64 {
    var lo: usize = 0;
    var hi: usize = self.len();
    while (lo < hi and self.at(lo) == 0) lo += 1;
    while (hi > lo and self.at(hi - 1) == 0) hi -= 1;
    if (lo == hi) return null; // zero: the text path returns 0
    if (hi - lo > 4) return null; // more than 16 digits
    var m: u64 = 0;
    for (lo..hi) |i| m = m * 10000 + self.at(i);
    if (m > (1 << 53)) return null;
    const e: i64 = 4 * (@as(i64, self.weight) - @as(i64, @intCast(hi - 1)));
    if (e < -22 or e > 22) return null;
    const pow10 = [_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };
    const fm: f64 = @floatFromInt(m);
    const v = if (e >= 0) fm * pow10[@intCast(e)] else fm / pow10[@intCast(-e)];
    return if (self.sign == Numeric.sign_neg) -v else v;
}

/// the text DigitView.toF64 builds (840 bytes: 800 digits, sticky, sign, "0.", exponent)
var f64_text: [840]u8 = undefined;

/// `n` bytes from `gpa` without the ReleaseSafe 0xAA fill of
/// Allocator.alloc (done byte by byte by the interpreter): for buffers that
/// are written completely right away.  Freed like any slice of `gpa`.
fn allocBytes(gpa: s.mem.Allocator, n: usize) error{OutOfMemory}![]u8 {
    if (n == 0) return &.{};
    const p = gpa.rawAlloc(n, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    return p[0..n];
}

/// The 15 significant decimal digits of `v` (> 0, finite), rounded half to
/// even from its exact binary value, as glibc's printf("%.15e") does; `d`
/// gets the digits (d[0] in 1..9), the result is the decimal exponent of
/// d[0].  Exact arithmetic on a small fixed-size big integer.
fn decimalDigits15(v: f64, d: *[15]u8) i64 {
    const bits: u64 = @bitCast(v);
    const exp_field: u64 = (bits >> 52) & 0x7ff;
    const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
    const m: u64 = if (exp_field == 0) frac else frac | (@as(u64, 1) << 52);
    const e2: i64 = if (exp_field == 0) -1074 else @as(i64, @intCast(exp_field)) - 1075;
    // v = r / sc
    var r = Big.fromU64(m);
    var sc = Big.fromU64(1);
    if (e2 >= 0) r.shl(@intCast(e2)) else sc.shl(@intCast(-e2));
    var k: i64 = @intFromFloat(@floor(@log10(v)));
    if (k >= 0) sc.mulPow10(@intCast(k)) else r.mulPow10(@intCast(-k));
    // make sc <= r < 10 sc (the estimate can be off by one)
    while (true) {
        var ten = sc;
        ten.mulSmall(10);
        if (r.cmp(&ten) != .lt) {
            sc = ten;
            k += 1;
        } else break;
    }
    while (r.cmp(&sc) == .lt) {
        r.mulSmall(10);
        k -= 1;
    }
    for (0..15) |i| {
        if (i > 0) r.mulSmall(10);
        var q: u8 = 0;
        while (r.cmp(&sc) != .lt) {
            r.sub(&sc);
            q += 1;
        }
        d[i] = q;
    }
    // round half to even on the exact remainder r / sc
    var r2 = r;
    r2.shl(1);
    const c = r2.cmp(&sc);
    if (c == .gt or (c == .eq and d[14] % 2 == 1)) {
        var i: usize = 15;
        while (i > 0) {
            i -= 1;
            if (d[i] < 9) {
                d[i] += 1;
                break;
            }
            d[i] = 0;
            if (i == 0) {
                d[0] = 1;
                k += 1;
            }
        }
    }
    return k;
}

/// Unsigned big integer for decimalDigits15: little-endian u32 limbs.
/// 2^1074 * 10^340 < 2^2224 = 70 limbs; 80 is plenty.
const Big = struct {
    limbs: [80]u32 = @splat(0),
    len: usize = 0,

    fn fromU64(x: u64) Big {
        var b: Big = .{};
        b.limbs[0] = @truncate(x);
        b.limbs[1] = @truncate(x >> 32);
        b.len = if (b.limbs[1] != 0) 2 else if (b.limbs[0] != 0) 1 else 0;
        return b;
    }

    fn mulSmall(self: *Big, f: u32) void {
        var carry: u64 = 0;
        for (self.limbs[0..self.len]) |*l| {
            const p = @as(u64, l.*) * f + carry;
            l.* = @truncate(p);
            carry = p >> 32;
        }
        if (carry != 0) {
            self.limbs[self.len] = @intCast(carry);
            self.len += 1;
        }
    }

    fn mulPow10(self: *Big, n: u32) void {
        var left = n;
        while (left >= 9) : (left -= 9) self.mulSmall(1_000_000_000);
        var f: u32 = 1;
        while (left > 0) : (left -= 1) f *= 10;
        if (f > 1) self.mulSmall(f);
    }

    fn shl(self: *Big, n: u32) void {
        if (self.len == 0) return;
        const words = n / 32;
        const bitsn: u5 = @intCast(n % 32);
        if (bitsn != 0) {
            var carry: u32 = 0;
            for (self.limbs[0..self.len]) |*l| {
                const nl = (l.* << bitsn) | carry;
                carry = l.* >> @intCast(32 - @as(u6, bitsn));
                l.* = nl;
            }
            if (carry != 0) {
                self.limbs[self.len] = carry;
                self.len += 1;
            }
        }
        if (words != 0) {
            var i: usize = self.len;
            while (i > 0) {
                i -= 1;
                self.limbs[i + words] = self.limbs[i];
            }
            @memset(self.limbs[0..words], 0);
            self.len += words;
        }
    }

    fn cmp(a: *const Big, b: *const Big) s.math.Order {
        if (a.len != b.len) return if (a.len > b.len) .gt else .lt;
        var i = a.len;
        while (i > 0) {
            i -= 1;
            if (a.limbs[i] != b.limbs[i]) return if (a.limbs[i] > b.limbs[i]) .gt else .lt;
        }
        return .eq;
    }

    /// self -= b (self >= b)
    fn sub(self: *Big, b: *const Big) void {
        var borrow: u64 = 0;
        for (0..self.len) |i| {
            const bl: u64 = if (i < b.len) b.limbs[i] else 0;
            const x = @as(u64, self.limbs[i]) -% bl -% borrow;
            self.limbs[i] = @truncate(x);
            borrow = (x >> 63) & 1;
        }
        while (self.len > 0 and self.limbs[self.len - 1] == 0) self.len -= 1;
    }
};

// ---------------------------------------------------------------------------
// jsonb (doc/abi.md, "jsonb").
//
// A jsonb argument or column arrives in PostgreSQL's on-disk layout (the
// JsonbContainer of the detoasted value, as jsonb_util.c reads it), copied
// once into guest memory, and is read in place: nothing is parsed or
// converted up front.  Every read is bounds-checked against the value, so
// malformed bytes give error.InvalidJsonb, never a read outside the value.
// Results and SPI parameters of type jsonb are JSON text (`JsonText`), which
// the host parses with jsonb_in: a function cannot store a binary jsonb.

/// JSON text for a `jsonb` result or a `.jsonb` prepared-statement
/// parameter; the host parses it with jsonb_in (so invalid JSON is an SQL
/// error, and the stored value is whatever jsonb_in makes of it).
pub const JsonText = struct {
    text: []const u8,
};

/// `JsonText` from a byte slice: `return plzig.jsonText("{\"a\": 1}");`
pub fn jsonText(text: []const u8) JsonText {
    return .{ .text = text };
}

pub const JsonbError = error{InvalidJsonb};

/// A jsonb argument or column value: the root container, read in place.
/// Valid as long as the bytes are (an argument: the call; a row value:
/// until the next row is fetched).
pub const Jsonb = struct {
    bytes: []const u8,

    /// The root value: an object, an array, or a scalar (a jsonb holding a
    /// bare string, number, boolean or null).
    pub fn root(self: Jsonb) JsonbError!JsonValue {
        const c = try Container.open(self.bytes, true);
        if (c.scalar) return c.child(0);
        return c.value();
    }

    /// The JSON text of the whole value, formatted exactly as jsonb_out
    /// does (", " and ": " separators), in the per-call arena; returning it
    /// from a function with a jsonb result stores the same value.
    pub fn toJsonText(self: Jsonb) (JsonbError || error{OutOfMemory})!JsonText {
        return (try self.root()).toJsonText();
    }

    /// The JSON text, allocated with `gpa`.
    pub fn toJsonAlloc(self: Jsonb, gpa: s.mem.Allocator) (JsonbError || error{OutOfMemory})![]u8 {
        return (try self.root()).toJsonAlloc(gpa);
    }
};

/// One JSON value inside a jsonb.
pub const JsonValue = union(enum) {
    null,
    bool: bool,
    /// the string's bytes (database encoding, no escapes)
    string: []const u8,
    number: JsonNumber,
    array: JsonArray,
    object: JsonObject,

    /// This value as JSON text (jsonb_out's format), in the per-call arena.
    pub fn toJsonText(self: JsonValue) (JsonbError || error{OutOfMemory})!JsonText {
        return .{ .text = try self.toJsonAlloc(allocator) };
    }

    /// This value as JSON text, allocated with `gpa`.
    pub fn toJsonAlloc(self: JsonValue, gpa: s.mem.Allocator) (JsonbError || error{OutOfMemory})![]u8 {
        var out: s.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try writeJsonValue(gpa, &out, self);
        return out.toOwnedSlice(gpa);
    }
};

/// A number inside a jsonb: PostgreSQL's on-disk numeric (a varlena with a
/// short or long numeric header, or NaN/±Infinity), decoded on use.
pub const JsonNumber = struct {
    raw: []const u8,

    /// The number as a `Numeric` (wire format), in the per-call arena.
    pub fn numeric(self: JsonNumber) (JsonbError || error{OutOfMemory})!Numeric {
        return self.numericAlloc(allocator);
    }

    /// The number as a `Numeric`, allocated with `gpa`.
    pub fn numericAlloc(self: JsonNumber, gpa: s.mem.Allocator) (JsonbError || error{OutOfMemory})!Numeric {
        const d = try self.decode();
        const out = try allocBytes(gpa, 8 + 2 * d.ndigits);
        d.toWire(out);
        return .{ .wire = out };
    }

    /// The number as an i64 (see `Numeric.toI64`).
    pub fn toI64(self: JsonNumber) (JsonbError || Numeric.ToIntError)!i64 {
        return (try self.decode()).view().toI64();
    }

    /// The number as an f64 (see `Numeric.toF64`).
    pub fn toF64(self: JsonNumber) (JsonbError || Numeric.ToFloatError)!f64 {
        return (try self.decode()).view().toF64();
    }

    const Decoded = struct {
        sign: u16,
        weight: i16,
        dscale: u16,
        ndigits: usize,
        digits: []const u8, // little-endian i16, as stored

        fn view(d: Decoded) DigitView {
            return .{ .sign = d.sign, .weight = d.weight, .digits = d.digits, .le = true };
        }

        fn toWire(d: Decoded, out: []u8) void {
            Numeric.put16(out, 0, @intCast(d.ndigits));
            Numeric.put16(out, 2, @bitCast(d.weight));
            Numeric.put16(out, 4, d.sign);
            Numeric.put16(out, 6, d.dscale);
            for (0..d.ndigits) |i| {
                Numeric.put16(out, 8 + 2 * i, s.mem.readInt(u16, d.digits[2 * i ..][0..2], .little));
            }
        }
    };

    /// numeric.c's on-disk format: varlena header (1 or 4 bytes), then
    /// n_header (u16): NaN/±Infinity, a short header (sign, dscale,
    /// weight in 16 bits), or a long one (sign + dscale, then i16 weight),
    /// then the base-10000 digits (i16, host byte order = little endian)
    fn decode(self: JsonNumber) JsonbError!Decoded {
        const v = try varlenaData(self.raw);
        if (v.len < 2) return error.InvalidJsonb;
        const h = s.mem.readInt(u16, v[0..2], .little);
        var d: Decoded = undefined;
        var digits: []const u8 = undefined;
        if (h & 0x8000 != 0) {
            if (h & 0xC000 == 0xC000) {
                // special: the whole header word is the value
                if (h != Numeric.sign_nan and h != Numeric.sign_pinf and h != Numeric.sign_ninf) return error.InvalidJsonb;
                return .{ .sign = h, .weight = 0, .dscale = 0, .ndigits = 0, .digits = &.{} };
            }
            // short: 0x8000 | sign 0x2000 | dscale (6 bits) << 7 | weight sign 0x40 | weight (6 bits)
            d.sign = if (h & 0x2000 != 0) Numeric.sign_neg else Numeric.sign_pos;
            d.dscale = (h & 0x1F80) >> 7;
            const w: u16 = if (h & 0x0040 != 0) (h & 0x003F) | 0xFFC0 else h & 0x003F;
            d.weight = @bitCast(w);
            digits = v[2..];
        } else {
            if (v.len < 4) return error.InvalidJsonb;
            d.sign = h & 0xC000; // 0x0000 or 0x4000 (0x8000/0xC000 are short/special)
            d.dscale = h & 0x3FFF;
            d.weight = s.mem.readInt(i16, v[2..4], .little);
            digits = v[4..];
        }
        if (digits.len % 2 != 0) return error.InvalidJsonb;
        d.ndigits = digits.len / 2;
        if (d.ndigits > Numeric.max_ndigits) return error.InvalidJsonb;
        for (0..d.ndigits) |i| {
            if (s.mem.readInt(u16, digits[2 * i ..][0..2], .little) >= 10000) return error.InvalidJsonb;
        }
        d.digits = digits;
        return d;
    }
};

/// The whole of a varlena that is stored inline (1-byte or 4-byte header,
/// uncompressed; anything else does not occur inside a jsonb): `raw` cut to
/// the varlena's own size, and the header size
fn varlenaSpan(raw: []const u8) JsonbError!struct { []const u8, usize } {
    if (raw.len < 1) return error.InvalidJsonb;
    const b0 = raw[0];
    if (b0 & 0x01 != 0) {
        // VARATT_IS_1B (little endian); 0x01 alone is an external pointer
        if (b0 == 0x01) return error.InvalidJsonb;
        const size: usize = b0 >> 1;
        if (size < 1 or size > raw.len) return error.InvalidJsonb;
        return .{ raw[0..size], 1 };
    }
    if (raw.len < 4) return error.InvalidJsonb;
    const h = s.mem.readInt(u32, raw[0..4], .little);
    if (h & 0x03 != 0) return error.InvalidJsonb; // compressed (4B_C)
    const size: usize = h >> 2;
    if (size < 4 or size > raw.len) return error.InvalidJsonb;
    return .{ raw[0..size], 4 };
}

/// The payload of an inline varlena (see varlenaSpan)
fn varlenaData(raw: []const u8) JsonbError![]const u8 {
    const v = try varlenaSpan(raw);
    return v[0][v[1]..];
}

/// A JSON array inside a jsonb.
pub const JsonArray = struct {
    c: Container,

    /// Number of elements.
    pub fn len(self: JsonArray) usize {
        return self.c.count;
    }

    /// Element `i`, or null past the end.
    pub fn get(self: JsonArray, i: usize) JsonbError!?JsonValue {
        if (i >= self.c.count) return null;
        return try self.c.child(i);
    }

    pub fn iterator(self: JsonArray) Iterator {
        return .{ .c = self.c };
    }

    pub const Iterator = struct {
        c: Container,
        i: usize = 0,

        /// The next element, or null at the end.
        pub fn next(self: *Iterator) JsonbError!?JsonValue {
            if (self.i >= self.c.count) return null;
            defer self.i += 1;
            return try self.c.child(self.i);
        }
    };
};

/// A JSON object inside a jsonb.  Keys are unique and sorted as jsonb sorts
/// them (by length, then bytes), which is also the iteration order.
pub const JsonObject = struct {
    c: Container,

    pub const Entry = struct { key: []const u8, value: JsonValue };

    /// Number of key/value pairs.
    pub fn len(self: JsonObject) usize {
        return self.c.count;
    }

    /// The value of `key`, or null if there is none: a binary search over
    /// the keys, exactly as jsonb_util.c's getKeyJsonValueFromContainer.
    pub fn get(self: JsonObject, key: []const u8) JsonbError!?JsonValue {
        // up to 16 keys: one forward pass over the key entries (their
        // offsets accumulate, lengths are compared first); the same result
        // as the binary search for the unique keys PostgreSQL stores
        if (self.c.count <= 16) return self.c.findKeyLinear(key);
        var lo: usize = 0;
        var hi: usize = self.c.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = try self.c.keyAt(mid);
            switch (lengthCompare(k, key)) {
                .eq => return try self.c.child(mid + self.c.count),
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Pair `i` in storage order (0 <= i < len()).
    pub fn entry(self: JsonObject, i: usize) JsonbError!?Entry {
        if (i >= self.c.count) return null;
        return .{ .key = try self.c.keyAt(i), .value = try self.c.child(i + self.c.count) };
    }

    pub fn iterator(self: JsonObject) Iterator {
        return .{ .o = self };
    }

    pub const Iterator = struct {
        o: JsonObject,
        i: usize = 0,

        /// The next key/value pair, or null at the end.
        pub fn next(self: *Iterator) JsonbError!?Entry {
            const e = try self.o.entry(self.i);
            if (e != null) self.i += 1;
            return e;
        }
    };
};

/// lengthCompareJsonbStringValue: shorter first, then memcmp
fn lengthCompare(a: []const u8, b: []const u8) s.math.Order {
    if (a.len != b.len) return if (a.len > b.len) .gt else .lt;
    return s.mem.order(u8, a, b);
}

/// A JsonbContainer: u32 header (count | flags), then the JEntries (one per
/// element, or keys then values for an object), then the children's data.
const Container = struct {
    data: []const u8,
    count: usize,
    object: bool,
    scalar: bool,
    base: usize, // offset of the data area in `data`

    const JB_CMASK: u32 = 0x0FFFFFFF;
    const JB_FSCALAR: u32 = 0x10000000;
    const JB_FOBJECT: u32 = 0x20000000;
    const JB_FARRAY: u32 = 0x40000000;
    const JENTRY_OFFLENMASK: u32 = 0x0FFFFFFF;
    const JENTRY_TYPEMASK: u32 = 0x70000000;
    const JENTRY_HAS_OFF: u32 = 0x80000000;
    const T_STRING: u32 = 0x00000000;
    const T_NUMERIC: u32 = 0x10000000;
    const T_FALSE: u32 = 0x20000000;
    const T_TRUE: u32 = 0x30000000;
    const T_NULL: u32 = 0x40000000;
    const T_CONTAINER: u32 = 0x50000000;

    fn open(data: []const u8, is_root: bool) JsonbError!Container {
        if (data.len < 4) return error.InvalidJsonb;
        const header = s.mem.readInt(u32, data[0..4], .little);
        const count: usize = header & JB_CMASK;
        const flags = header & ~JB_CMASK;
        const object = flags == JB_FOBJECT;
        const scalar = flags == JB_FARRAY | JB_FSCALAR;
        if (!object and !scalar and flags != JB_FARRAY) return error.InvalidJsonb;
        // a scalar is a one-element array, and only ever the root
        if (scalar and (count != 1 or !is_root)) return error.InvalidJsonb;
        const nentries: u64 = if (object) 2 * @as(u64, count) else count;
        const base: u64 = 4 + 4 * nentries;
        if (base > data.len) return error.InvalidJsonb;
        return .{ .data = data, .count = count, .object = object, .scalar = scalar, .base = @intCast(base) };
    }

    fn value(self: Container) JsonValue {
        return if (self.object) .{ .object = .{ .c = self } } else .{ .array = .{ .c = self } };
    }

    fn jentry(self: Container, i: usize) u32 {
        return s.mem.readInt(u32, self.data[4 + 4 * i ..][0..4], .little);
    }

    /// getJsonbOffset: lengths of the preceding children back to the
    /// nearest one that stores its end offset (every JB_OFFSET_STRIDE-th)
    fn offsetOf(self: Container, i: usize) u64 {
        var off: u64 = 0;
        var k = i;
        while (k > 0) {
            k -= 1;
            const je = self.jentry(k);
            off += je & JENTRY_OFFLENMASK;
            if (je & JENTRY_HAS_OFF != 0) break;
        }
        return off;
    }

    /// [start, end) of child i in the data area, checked against the value
    fn span(self: Container, i: usize) JsonbError!struct { u64, u64 } {
        const je = self.jentry(i);
        const off = self.offsetOf(i);
        const end: u64 = if (je & JENTRY_HAS_OFF != 0) je & JENTRY_OFFLENMASK else off + (je & JENTRY_OFFLENMASK);
        if (end < off or self.base + end > self.data.len) return error.InvalidJsonb;
        return .{ off, end };
    }

    fn findKeyLinear(self: Container, key: []const u8) JsonbError!?JsonValue {
        var off: u64 = 0;
        for (0..self.count) |i| {
            const je = self.jentry(i);
            if (je & JENTRY_TYPEMASK != T_STRING) return error.InvalidJsonb;
            const end: u64 = if (je & JENTRY_HAS_OFF != 0) je & JENTRY_OFFLENMASK else off + (je & JENTRY_OFFLENMASK);
            if (end < off or self.base + end > self.data.len) return error.InvalidJsonb;
            if (end - off == key.len) {
                const k = self.data[self.base + @as(usize, @intCast(off)) .. self.base + @as(usize, @intCast(end))];
                if (s.mem.eql(u8, k, key)) return try self.child(i + self.count);
            }
            off = end;
        }
        return null;
    }

    fn keyAt(self: Container, i: usize) JsonbError![]const u8 {
        if (self.jentry(i) & JENTRY_TYPEMASK != T_STRING) return error.InvalidJsonb;
        const sp = try self.span(i);
        return self.data[self.base + @as(usize, @intCast(sp[0])) .. self.base + @as(usize, @intCast(sp[1]))];
    }

    /// fillJsonbValue: child i (an element, a key or a value)
    fn child(self: Container, i: usize) JsonbError!JsonValue {
        const nentries: usize = if (self.object) 2 * self.count else self.count;
        if (i >= nentries) return error.InvalidJsonb;
        const je = self.jentry(i);
        const sp = try self.span(i);
        const off: usize = @intCast(sp[0]);
        const end: usize = @intCast(sp[1]);
        switch (je & JENTRY_TYPEMASK) {
            T_STRING => return .{ .string = self.data[self.base + off .. self.base + end] },
            T_NUMERIC, T_CONTAINER => {
                // numerics and containers start at a 4-byte boundary (INTALIGN)
                const start = (off + 3) & ~@as(usize, 3);
                if (start > end) return error.InvalidJsonb;
                const bytes = self.data[self.base + start .. self.base + end];
                if (je & JENTRY_TYPEMASK == T_NUMERIC) {
                    // the varlena's own size bounds the number
                    return .{ .number = .{ .raw = (try varlenaSpan(bytes))[0] } };
                }
                return (try Container.open(bytes, false)).value();
            },
            T_FALSE => return .{ .bool = false },
            T_TRUE => return .{ .bool = true },
            T_NULL => return .null,
            else => return error.InvalidJsonb,
        }
    }
};

/// jsonb_out (JsonbToCStringWorker without indentation), iteratively: an
/// explicit stack in `gpa`, so nesting depth never meets the guest stack
fn writeJsonValue(gpa: s.mem.Allocator, out: *s.ArrayList(u8), root: JsonValue) (JsonbError || error{OutOfMemory})!void {
    const Frame = struct { c: Container, i: usize };
    var stack: s.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var v = root;
    while (true) {
        // write v; containers are opened and their children visited below
        switch (v) {
            .null => try out.appendSlice(gpa, "null"),
            .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
            .string => |str| try writeJsonString(gpa, out, str),
            .number => |n| try writeJsonNumber(gpa, out, n),
            .array => |a| {
                try out.append(gpa, '[');
                try stack.append(gpa, .{ .c = a.c, .i = 0 });
            },
            .object => |o| {
                try out.append(gpa, '{');
                try stack.append(gpa, .{ .c = o.c, .i = 0 });
            },
        }
        // find the next value to write, closing finished containers
        while (true) {
            if (stack.items.len == 0) return;
            const top = &stack.items[stack.items.len - 1];
            if (top.i < top.c.count) {
                if (top.i > 0) try out.appendSlice(gpa, ", ");
                if (top.c.object) {
                    try writeJsonString(gpa, out, try top.c.keyAt(top.i));
                    try out.appendSlice(gpa, ": ");
                    v = try top.c.child(top.i + top.c.count);
                } else v = try top.c.child(top.i);
                top.i += 1;
                break;
            }
            try out.append(gpa, if (top.c.object) '}' else ']');
            _ = stack.pop();
        }
    }
}

/// wire-format scratch of writeJsonNumber: static, so that serialising a
/// document does not fill a stack buffer per number
var json_num_wire: [512]u8 = undefined;

/// escape_json
fn writeJsonString(gpa: s.mem.Allocator, out: *s.ArrayList(u8), str: []const u8) error{OutOfMemory}!void {
    try out.append(gpa, '"');
    for (str) |c| {
        switch (c) {
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                try out.appendSlice(gpa, &[6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
            } else try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

/// numeric_out of a jsonb number
fn writeJsonNumber(gpa: s.mem.Allocator, out: *s.ArrayList(u8), n: JsonNumber) (JsonbError || error{OutOfMemory})!void {
    const d = try n.decode();
    const buf = &json_num_wire;
    const wire_len = 8 + 2 * d.ndigits;
    const wire = if (wire_len <= buf.len) buf[0..wire_len] else try allocBytes(gpa, wire_len);
    defer if (wire_len > buf.len) gpa.free(wire);
    d.toWire(wire);
    const num: Numeric = .{ .wire = wire };
    const dst = try out.addManyAsSlice(gpa, num.textLen());
    var b: Numeric.BufSink = .{ .buf = dst };
    num.emit(&b) catch unreachable;
}

fn isFixed16(comptime T: type) bool {
    return T == Interval or T == Uuid;
}

/// Read a 16-byte value the host placed at `addr` (no alignment assumed).
fn readFixed16(comptime T: type, addr: u64) T {
    const p: *align(1) const T = @ptrFromInt(@as(usize, @intCast(addr)));
    return p.*;
}

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

/// An SQL error with a chosen SQLSTATE, for `raiseError`.
pub const ErrorReport = struct {
    /// Five characters, each a digit or an upper-case letter (e.g. "23514",
    /// check_violation). Refused, with an error of its own: classes 00, 01,
    /// 02 (not errors), 08, 53, 57, 58, F0 and XX (conditions of the server
    /// itself), and anything malformed.
    sqlstate: []const u8 = "P0001",
    message: []const u8,
    /// Omitted when null or empty.
    detail: ?[]const u8 = null,
    /// Omitted when null or empty.
    hint: ?[]const u8 = null,
};

/// The fields of `ErrorReport` other than the message, for `raiseErrorFmt`.
pub const ErrorFields = struct {
    sqlstate: []const u8 = "P0001",
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

fn hostLen(b: []const u8) u32 {
    return @intCast(@min(b.len, 0xffff_ffff));
}

/// Raise an SQL ERROR with the given SQLSTATE, message, detail and hint;
/// it can be caught by condition name or SQLSTATE in a calling PL/pgSQL
/// function (`EXCEPTION WHEN check_violation`). Never returns. Severity is
/// always ERROR. Message, detail and hint must be valid in the database
/// encoding (no NUL bytes); each is cut at 64 kB.
pub fn raiseError(report: ErrorReport) noreturn {
    const none: []const u8 = "";
    const detail = report.detail orelse none;
    const hint = report.hint orelse none;
    host.raise_error(report.sqlstate.ptr, hostLen(report.sqlstate), report.message.ptr, hostLen(report.message), detail.ptr, hostLen(detail), hint.ptr, hostLen(hint));
    @trap();
}

/// `raiseError` with a formatted message:
/// `plzig.raiseErrorFmt(.{ .sqlstate = "22023", .hint = "Use a positive value." }, "bad value {d}", .{x})`.
pub fn raiseErrorFmt(fields: ErrorFields, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = s.fmt.allocPrint(allocator, fmt, args) catch "plzig: out of memory while formatting error message";
    raiseError(.{ .sqlstate = fields.sqlstate, .message = msg, .detail = fields.detail, .hint = fields.hint });
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
    date = 10,
    time = 11,
    timetz = 12,
    timestamp = 13,
    timestamptz = 14,
    interval = 15,
    uuid = 16,
    oid = 17,
    numeric = 18,
    /// the value's on-disk layout (plzig.Jsonb); as a parameter: JSON text
    jsonb = 19,
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
    date = 10,
    time = 11,
    timetz = 12,
    timestamp = 13,
    timestamptz = 14,
    interval = 15,
    uuid = 16,
    oid = 17,
    numeric = 18,
    /// the value is JSON text (plzig.JsonText), parsed by jsonb_in
    jsonb = 19,
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
    /// bigint, real, double precision), `plzig.Date`, `Time`, `TimeTz`,
    /// `Timestamp`, `TimestampTz`, `Interval`, `Uuid`, `Oid`, `Numeric`, `Jsonb` (exactly that
    /// SQL type), or `[]const u8` (text-like, bytea, or the text
    /// representation of any type without a native mapping); `?T` accepts
    /// SQL NULL.
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
        Date => k == @intFromEnum(Kind.date),
        Time => k == @intFromEnum(Kind.time),
        TimeTz => k == @intFromEnum(Kind.timetz),
        Timestamp => k == @intFromEnum(Kind.timestamp),
        TimestampTz => k == @intFromEnum(Kind.timestamptz),
        Interval => k == @intFromEnum(Kind.interval),
        Uuid => k == @intFromEnum(Kind.uuid),
        Oid => k == @intFromEnum(Kind.oid),
        Numeric => k == @intFromEnum(Kind.numeric),
        Jsonb => k == @intFromEnum(Kind.jsonb),
        else => @compileError("plzig: unsupported column type " ++ @typeName(T) ++
            " (use bool, i16, i32, i64, f32, f64, []const u8 or a plzig type such as plzig.Date, or an optional of one)"),
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
    if (T == Date) return .{ .days = @truncate(@as(i64, @bitCast(v.val))) };
    if (T == Time) return .{ .usecs = @bitCast(v.val) };
    if (T == TimeTz) return .{ .usecs = @bitCast(v.val), .zone = @bitCast(v.len) };
    if (T == Timestamp) return .{ .usecs = @bitCast(v.val) };
    if (T == TimestampTz) return .{ .usecs = @bitCast(v.val) };
    if (T == Oid) return .{ .value = @truncate(v.val) };
    if (T == Numeric) {
        // written by the host from numeric_send: valid
        if (v.len == 0) return Numeric.zero;
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v.val)));
        return .{ .wire = p[0..v.len] };
    }
    if (T == Jsonb) {
        if (v.len == 0) return .{ .bytes = &.{} };
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v.val)));
        return .{ .bytes = p[0..v.len] };
    }
    if (comptime isFixed16(T)) {
        if (v.len != 16) raiseMsg("plzig: invalid fixed-width column value");
        return readFixed16(T, v.val);
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
            // written by the host before it is read: no 0xAA fill
            const p = allocator.rawAlloc(want, .@"8", @returnAddress()) orelse return error.OutOfMemory;
            self.buf = @alignCast(p[0..want]);
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
        const buf = try allocBytes(allocator, @intCast(n));
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
        const buf = try allocBytes(allocator, @intCast(n));
        if (buf.len > 0) _ = host.spi_colname_copy(col, buf.ptr, @intCast(buf.len));
        return buf;
    }
};

/// size part of a spi_cursor_fetch result (ncols << 32 | size)
fn fetchedSize(r: i64) u32 {
    return @truncate(@as(u64, @bitCast(r)));
}

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
    /// from it are invalid after the next call of `next`. One host call per
    /// row; two when the row is larger than the scratch buffer, which then
    /// grows (on `error.OutOfMemory` the row is not lost: the next call of
    /// `next` returns it).
    pub fn next(self: *Cursor) error{ OutOfMemory, CursorClosed }!?Row {
        switch (self.state) {
            .open => {},
            .finished => return null,
            .closed => return error.CursorClosed,
        }
        var r = host.spi_cursor_fetch(self.handle, self.scratch.buf.ptr, @intCast(self.scratch.buf.len));
        if (r >= 0 and fetchedSize(r) > self.scratch.buf.len) {
            // not written: the host keeps the row for the second call
            _ = try self.scratch.ensure(fetchedSize(r));
            const want = fetchedSize(r);
            r = host.spi_cursor_fetch(self.handle, self.scratch.buf.ptr, @intCast(self.scratch.buf.len));
            if (r < 0 or fetchedSize(r) != want) raiseMsg("plzig: cursor row changed size");
        }
        if (r < 0) {
            host.spi_cursor_close(self.handle);
            self.state = .finished;
            return null;
        }
        return rowFrom(self.scratch.buf, @intCast(@as(u64, @bitCast(r)) >> 32));
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
    /// `plzig.Date`, `Time`, `TimeTz`, `Timestamp`, `TimestampTz`,
    /// `Interval`, `Uuid`, `Oid`, `Numeric`, `JsonText` (jsonb), an
    /// optional of one of these, or `null`.
    pub fn execute(self: Plan, args: anytype) error{OutOfMemory}!Result {
        // initialised word by word, not with the byte-wise 0xAA fill of
        // `undefined`; `fixed` only has room for the 16-byte parameters
        var vals: [paramCount(@TypeOf(args))]Value = @splat(null_value);
        var fixed: [fixedCount(@TypeOf(args))][16]u8 align(8) = @splat(@splat(0));
        encodeParams(args, &vals, &fixed);
        const n = host.spi_execute_plan(self.handle, &vals, vals.len);
        return .{ .rows = @intCast(n), .columns = host.spi_ncols() };
    }

    /// Open a cursor over the prepared statement (see `execute` for `args`).
    pub fn open(self: Plan, args: anytype) error{OutOfMemory}!Cursor {
        // initialised word by word, not with the byte-wise 0xAA fill of
        // `undefined`; `fixed` only has room for the 16-byte parameters
        var vals: [paramCount(@TypeOf(args))]Value = @splat(null_value);
        var fixed: [fixedCount(@TypeOf(args))][16]u8 align(8) = @splat(@splat(0));
        encodeParams(args, &vals, &fixed);
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

const null_value: Value = .{ .val = 0, .len = 0, .kind = 0, .is_null = 1 };

/// whether a parameter type (or its optional) is a 16-byte value
fn isFixed16Param(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| isFixed16(o.child),
        else => isFixed16(T),
    };
}

/// number of 16-byte parameters (interval, uuid) in the tuple type
fn fixedCount(comptime Args: type) usize {
    var n: usize = 0;
    for (@typeInfo(Args).@"struct".field_types) |T| {
        if (isFixed16Param(T)) n += 1;
    }
    return n;
}

/// 16-byte values (interval, uuid) are copied to the next entry of `fixed`
/// and passed by that address: the caller keeps `fixed` until the host has
/// read them.
fn encodeParams(args: anytype, out: []Value, fixed: [][16]u8) void {
    comptime var k: usize = 0;
    inline for (0..comptime paramCount(@TypeOf(args))) |i| {
        if (comptime isFixed16Param(@TypeOf(args[i]))) {
            out[i] = encodeParam(args[i], &fixed[k]);
            k += 1;
        } else {
            out[i] = encodeParam(args[i], undefined);
        }
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
    if (T == Date) return @intFromEnum(Type.date);
    if (T == Time) return @intFromEnum(Type.time);
    if (T == TimeTz) return @intFromEnum(Type.timetz);
    if (T == Timestamp) return @intFromEnum(Type.timestamp);
    if (T == TimestampTz) return @intFromEnum(Type.timestamptz);
    if (T == Interval) return @intFromEnum(Type.interval);
    if (T == Uuid) return @intFromEnum(Type.uuid);
    if (T == Oid) return @intFromEnum(Type.oid);
    if (T == Numeric) return @intFromEnum(Type.numeric);
    if (T == JsonText) return @intFromEnum(Type.jsonb);
    if (comptime isBytes(T)) return @intFromEnum(Type.text);
    if (T == comptime_int or T == comptime_float)
        @compileError("plzig: give numeric parameter literals a type, e.g. @as(i32, 5)");
    @compileError("plzig: unsupported parameter type " ++ @typeName(T));
}

fn encodeParam(v: anytype, fixed: *[16]u8) Value {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .null => return .{ .val = 0, .len = 0, .kind = 0, .is_null = 1 },
        .optional => |o| {
            if (v) |x| return encodeParam(@as(o.child, x), fixed);
            return .{ .val = 0, .len = 0, .kind = paramKind(o.child), .is_null = 1 };
        },
        else => {},
    }
    const k = paramKind(T);
    if (T == Date) return .{ .val = @bitCast(@as(i64, v.days)), .len = 0, .kind = k, .is_null = 0 };
    if (T == Time or T == Timestamp or T == TimestampTz)
        return .{ .val = @bitCast(v.usecs), .len = 0, .kind = k, .is_null = 0 };
    if (T == TimeTz) return .{ .val = @bitCast(v.usecs), .len = @bitCast(v.zone), .kind = k, .is_null = 0 };
    if (T == Oid) return .{ .val = v.value, .len = 0, .kind = k, .is_null = 0 };
    if (T == Numeric) return .{ .val = @intFromPtr(v.wire.ptr), .len = hostLen(v.wire), .kind = k, .is_null = 0 };
    if (T == JsonText) return .{ .val = @intFromPtr(v.text.ptr), .len = hostLen(v.text), .kind = k, .is_null = 0 };
    if (comptime isFixed16(T)) {
        @memcpy(fixed, s.mem.asBytes(&v));
        return .{ .val = @intFromPtr(fixed), .len = 16, .kind = k, .is_null = 0 };
    }
    if (T == bool) return .{ .val = @intFromBool(v), .len = 0, .kind = k, .is_null = 0 };
    if (T == i16 or T == i32 or T == i64)
        return .{ .val = @bitCast(@as(i64, v)), .len = 0, .kind = k, .is_null = 0 };
    if (T == f32) return .{ .val = @as(u32, @bitCast(v)), .len = 0, .kind = k, .is_null = 0 };
    if (T == f64) return .{ .val = @bitCast(v), .len = 0, .kind = k, .is_null = 0 };
    const b: []const u8 = if (T == Bytea) v.bytes else v;
    return .{ .val = @intFromPtr(b.ptr), .len = @intCast(b.len), .kind = k, .is_null = 0 };
}

fn textSlots(params: []const ?[]const u8) error{OutOfMemory}![]Slot {
    // every slot is written below: no 0xAA fill
    const slots: []Slot = if (params.len == 0) &.{} else @as([*]Slot, @ptrCast(@alignCast(allocator.rawAlloc(params.len * @sizeOf(Slot), .of(Slot), @returnAddress()) orelse return error.OutOfMemory)))[0..params.len];
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
