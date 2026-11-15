    // fuzz/hostabi/driver.zig: body of
    //   fuzz_hostabi(script bytea) RETURNS int STRICT VOLATILE LANGUAGE plzig
    //   fuzz_hostabi_row(script bytea) RETURNS fuzz_hostabi_rt ...
    //   fuzz_hostabi_set(script bytea) RETURNS SETOF fuzz_hostabi_rt ...
    //   fuzz_hostabi_trg() RETURNS trigger (the script: NEW's first column)
    //   fuzz_hostabi_proc(script bytea) (a procedure; top-level CALLs)
    // compiled through docker/fake/hostilezig.c (which makes the SDK's host
    // import table public, adds rawPtr/addrOf/memSize helpers and lets
    // hostileCall below replace the SDK's plzig_call), so that it can call
    // every host import directly with whatever the script says: forged
    // pointers, lengths, row/column numbers, handles, kinds, values, memory
    // growth between calls, and re-entry through SQL; and then hand back a
    // result forged from the script (an int: the number of operations run;
    // a row: values with forged kinds, NULL flags, pointers and lengths).
    // See fuzz/README.md, target "hostabi".
    unreachable; // never called: hostileCall replaces plzig_call
}

const Fn = @TypeOf(call);
const Ret = @typeInfo(@typeInfo(Fn).@"fn".return_type.?).error_union.payload;
const is_trigger = @typeInfo(Fn).@"fn".param_types.len == 1 and @typeInfo(Fn).@"fn".param_types[0].? == plzig.Trigger;

/// plzig_call, as the hostile wrapper lets a function replace it: run the
/// script, then write the result slot (doc/abi.md, "Call sequence").
pub fn hostileCall(args: [*]const Slot, nargs: u32, result: *Slot, begin: u32) u32 {
    if (begin != 0) plzig.resetArena();
    if (comptime is_trigger) return triggerCall(args, nargs, result);
    if (nargs != 1 or args[0].is_null != 0) plzig.raiseMsg("fuzz: one script argument expected");
    const p = plzig.rawPtr([*]const u8, if (args[0].len == 0) gbase() else @as(usize, @intCast(args[0].val)));
    const script = p[0..args[0].len];
    const ops = run(script);
    if (Ret == ?i32) {
        result.* = .{ .val = @bitCast(@as(i64, ops)), .len = 0, .is_null = 0 };
    } else if (Ret == void) {
        // a set (the script pushed its rows with srf_return_next)
        result.* = .{ .val = 0, .len = 0, .is_null = 1 };
    } else {
        // a row (struct): forged from the script again
        var sc: Script = .{ .s = script };
        if (sc.byte() < 10) {
            result.* = .{ .val = 0, .len = 0, .is_null = 1 };
        } else {
            const f = forgeRow(@typeInfo(Ret).optional.child, &sc);
            result.* = .{ .val = f[0], .len = f[1], .is_null = 0 };
        }
    }
    return 0;
}

/// A trigger (fuzz_hostabi_trg on fuzz_hostabi_tt): the script is the first
/// column of NEW (or OLD); then a trigger result forged from it: the
/// action, the column count, the pointer, and per column keep / NULL / a
/// value for the column's kind / a value forged throughout.
fn triggerCall(args: [*]const Slot, nargs: u32, result: *Slot) u32 {
    if (nargs != 3) plzig.raiseMsg("fuzz: three trigger slots expected");
    const tg = plzig.Trigger.fromSlots(args);
    const row = tg.newRow() orelse tg.oldRow() orelse {
        result.* = .{ .val = 0, .len = 0, .is_null = 1 };
        return 0;
    };
    const script: []const u8 = (row.get(?[]const u8, 0) catch null) orelse "";
    _ = run(script);
    var sc: Script = .{ .s = script };
    const n = @min(tg.columnCount(), row_vals.len);
    for (row_vals[0..n], 0..) |*v, k| {
        const how = sc.byte();
        if (how < 120) {
            v.* = .{ .val = 0, .len = 0, .kind = 0, .is_null = 0 }; // keep
        } else if (how < 160) {
            v.* = .{ .val = 0, .len = 0, .kind = 0, .is_null = 1 };
        } else if (how < 230) {
            v.* = .{ .val = 0, .len = 0, .kind = @intFromEnum(tg.columnKind(k) catch .other), .is_null = 0 };
            forgeValue(v, k, &sc);
        } else {
            forgeThroughout(v, &sc);
        }
    }
    const sel = sc.byte();
    const action: u32 = if (sel < 180) 4 else if (sel < 245) 1 + sel % 3 else sc.int(u32);
    const count: u32 = if (sc.byte() < 235) @intCast(tg.columnCount()) else sc.int(u32) % 8;
    const where: u64 = if (sc.byte() < 240) plzig.addrOf(&row_vals) else ptrArg(&sc);
    result.* = .{ .val = where, .len = count, .is_null = action };
    return 0;
}

/// a plausible value for v.kind (set by the caller), like an SPI parameter
fn forgeValue(v: *Value, k: usize, sc: *Script) void {
    v.is_null = 0;
    v.val = switch (v.kind) {
        1 => sc.byte() % 2,
        2, 3, 4 => @bitCast(@as(i64, sc.int(i16))),
        5, 6 => sc.int(u32),
        10 => @bitCast(@as(i64, sc.int(i32) >> 8)),
        11, 13, 14 => @bitCast(@as(i64, sc.int(i32)) * 1000),
        12 => sc.int(u64) % 86_400_000_000,
        15, 16 => blk: {
            for (&row_fixed[k]) |*b| b.* = sc.byte();
            break :blk plzig.addrOf(&row_fixed[k]);
        },
        18 => blk: {
            const num = numerics[sc.byte() % numerics.len];
            v.len = @intCast(num.len);
            break :blk plzig.addrOf(num.ptr);
        },
        else => blk: {
            const strs = [_][]const u8{ "1", "abc", "{1,2}", "[1, {\"a\": null}]", "(1,x)", "", "\u{e9}", "toolongvalue", "\xff", "a\x00b" };
            const str = strs[sc.byte() % strs.len];
            v.len = @intCast(str.len);
            break :blk plzig.addrOf(str.ptr);
        },
    };
    if (v.kind == 15 or v.kind == 16) v.len = 16;
    if (v.kind == 12) v.len = sc.int(u16) % 50000;
}

/// kind, value, length and NULL flag forged
fn forgeThroughout(v: *Value, sc: *Script) void {
    const how = sc.byte();
    v.kind = if (how < 230) sc.byte() % 21 else sc.int(u16);
    v.val = if (sc.byte() < 128) ptrArg(sc) else sc.int(u64);
    v.len = lenArg(sc);
    v.is_null = if (sc.byte() < 240) sc.byte() % 2 else sc.int(u16);
}

/// the row type of a row or set result (the generated Result), if any
const RowType: ?type = blk: {
    if (!@hasDecl(@This(), "Result")) break :blk null;
    const R = @field(@This(), "Result");
    break :blk if (plzig.isRowType(R)) R else null;
};

/// srf_return_next with a row forged like a row result (kinds of the real
/// row type when there is one), or with forged values throughout; outside a
/// set-returning call the host must refuse it
fn pushRow(sc: *Script) void {
    if (RowType) |R| {
        if (sc.byte() < 220) {
            const f = forgeRow(R, sc);
            h.srf_return_next(P([*]const Value, @intCast(f[0] & 0xffff_ffff)), f[1]);
            return;
        }
    }
    const n = small(sc);
    h.srf_return_next(P([*]const Value, typedParams(sc, n)), n);
}

/// the values of a forged row, and the 16-byte payloads they may point to
var row_vals: [64]Value align(8) = undefined;
var row_fixed: [64][16]u8 align(8) = undefined;

/// a row result: mostly the right number of values with the right kinds
/// (taken from encoding an all-NULL row of the real struct), with values
/// chosen like SPI parameters (typedParams), sometimes forged throughout
fn forgeRow(comptime R: type, sc: *Script) struct { u64, u32 } {
    const n = comptime plzig.rowFieldCount(R);
    const nulls: R = plzig.std.mem.zeroes(R);
    plzig.encodeRow(R, nulls, row_vals[0..n], row_fixed[0..plzig.rowFixedCount(R)]) catch unreachable;
    for (row_vals[0..n], 0..) |*v, k| {
        const how = sc.byte();
        if (how < 60) continue; // NULL of the right kind
        if (how < 200) forgeValue(v, k, sc) else forgeThroughout(v, sc);
    }
    const count: u32 = if (sc.byte() < 230) @intCast(n) else switch (sc.byte() % 4) {
        0 => @intCast(n -| 1),
        1 => @intCast(n + 1),
        2 => 0,
        else => sc.int(u32),
    };
    const where: u64 = if (sc.byte() < 240) plzig.addrOf(&row_vals) else switch (sc.byte() % 3) {
        0 => ptrArg(sc),
        1 => sc.int(u64),
        else => plzig.addrOf(&row_vals) + 1 + sc.byte() % 7,
    };
    return .{ where, count };
}

const h = plzig.host;
const Slot = plzig.Slot;
const Value = plzig.Value;

/// scratch memory the script points the host at (and fills)
var gbuf: [65536]u8 align(8) = undefined;
/// handles kept across operations and across calls (globals persist per
/// instance): stale cursor handles from earlier calls must be rejected
var plans: [8]u64 = @splat(0);
var cursors: [8]u64 = @splat(0);
var last_size: u32 = 0;
/// shape of the last result the host reported, to aim row/column numbers
var last_rows: u64 = 0;
var last_cols: u32 = 0;

const pool = [_][]const u8{
    "SELECT 1 /*fuzzq*/",
    "SELECT $1::text /*fuzzq*/",
    "SELECT $1::text, $2::text /*fuzzq*/",
    "SELECT n, n::text AS t, n::float8 AS f, n::float4 AS r, (n % 2 = 0) AS b, n::int2 AS s, n::int8 AS l, repeat('x', n) AS rep, decode(repeat('ab', n), 'hex') AS by, NULL::int AS nul, (n || ' days')::interval AS iv, ARRAY[n, n] AS arr, ROW(n, 'x') AS rec FROM generate_series(1, 120) n /*fuzzq*/",
    "SELECT $1::int + 1 /*fuzzq*/",
    "SELECT $1 /*fuzzq*/",
    "SELECT $1::bytea, $2::int2, $3::float4 /*fuzzq*/",
    "INSERT INTO fuzz_hostabi_t VALUES (1) RETURNING n /*fuzzq*/",
    "UPDATE fuzz_hostabi_t SET n = n + 1 /*fuzzq*/",
    "DELETE FROM fuzz_hostabi_t WHERE n > 10 /*fuzzq*/",
    "SELECT * FROM fuzz_hostabi_secret /*fuzzq*/",
    "DECLARE c CURSOR WITH HOLD FOR SELECT 1 /*fuzzq*/",
    "FETCH 1 FROM c /*fuzzq*/",
    "CLOSE ALL /*fuzzq*/",
    "COMMIT /*fuzzq*/",
    "SELECT 1/0 /*fuzzq*/",
    "",
    "SELECT /*fuzzq*/",
    "SELECT repeat('\u{e9}', 3000) /*fuzzq*/",
    "SELECT ''::bytea, ''::text /*fuzzq*/",
    "SELECT fuzz_hostabi('\\x0b00'::bytea) /*fuzzq*/",
    "SELECT count(*) FROM fuzz_hostabi_t /*fuzzq*/",
    "SELECT 1 WHERE false /*fuzzq*/",
    "SELECT 'a', 'b', 'c', 'd' /*fuzzq*/",
    "SELECT pg_sleep(0) /*fuzzq*/",
    "SELECT $1::text FROM generate_series(1, 60) /*fuzzq*/",
    "SET LOCAL work_mem = '64kB' /*fuzzq*/",
    "SELECT 1; SELECT 2 /*fuzzq*/",
    "SELECT n FROM generate_series(1, 100000) n /*fuzzq*/",
    "SELECT (n / 7.0)::numeric AS num, date '2000-01-01' + n AS d, timestamp '2000-01-01' + n * interval '1 hour' AS ts, (timestamptz '2000-01-01 00:00+00' + n * interval '1 day') AS tz, n::oid AS o, md5(n::text)::uuid AS u, (n || ' days')::interval AS iv, '12:00+02'::timetz AS ttz, ('00:00'::time + n * interval '1 minute') AS t, 'NaN'::numeric AS nan FROM generate_series(1, 60) n /*fuzzq*/",
    "SELECT $1::numeric, $2::date, $3::timestamptz /*fuzzq*/",
};

/// parameter kinds the host accepts (doc/abi.md, "Kinds"), and some it does not
const param_kinds = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18 };

/// numeric operands in the wire format: valid ones, and a few the host must refuse
const numerics = [_][]const u8{
    "\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01", // 1
    "\x00\x00\x00\x00\x00\x00\x00\x00", // 0
    "\x00\x02\x00\x00\x40\x00\x00\x02\x00\x07\x13\x88", // -7.50
    "\x00\x00\x00\x00\xc0\x00\x00\x00", // NaN
    "\x00\x00\x00\x00\xd0\x00\x00\x00", // Infinity
    "\x00\x01\x7f\xff\x00\x00\x00\x00\x00\x09", // 9e131068
    "\x00\x01\x80\x00\x00\x00\x3f\xff\x00\x01", // 1e-131072, scale 16383
    "\x00\x01\x00\x00\x00\x00\x00\x00\x27\x10", // digit 10000
    "\x00\x00\x00\x00\x80\x00\x00\x00", // bad sign
    "\x00\x05\x00\x00", // short
};

/// a numeric operand: from the pool, or forged pointer/length
fn numArg(sc: *Script) struct { u32, u32 } {
    const sel = sc.byte();
    if (sel < 220) {
        const n = numerics[sel % numerics.len];
        return .{ @intCast(plzig.addrOf(n.ptr)), @intCast(n.len) };
    }
    return .{ ptrArg(sc), lenArg(sc) };
}

const Script = struct {
    s: []const u8,
    i: usize = 0,

    fn done(self: *Script) bool {
        return self.i >= self.s.len;
    }
    fn byte(self: *Script) u8 {
        if (self.i >= self.s.len) return 0;
        defer self.i += 1;
        return self.s[self.i];
    }
    fn int(self: *Script, comptime T: type) T {
        var v: T = 0;
        inline for (0..@sizeOf(T)) |k| v |= @as(T, self.byte()) << @intCast(8 * k);
        return v;
    }
};

fn gbase() u32 {
    return @intCast(plzig.addrOf(&gbuf));
}

/// a pointer argument: mostly sensible (inside gbuf, with room for a few
/// kB after it), sometimes hostile
fn ptrArg(sc: *Script) u32 {
    const mem: u32 = @intCast(@min(plzig.memSize(), 0xffff_ffff));
    const sel = sc.byte();
    if (sel < 200) return gbase() + (sc.int(u16) % @as(u32, gbuf.len - 4096));
    return switch (sel % 7) {
        0 => 0,
        1 => gbase() + @as(u32, gbuf.len) - @as(u32, sc.byte() % 64),
        2 => mem -% (sc.int(u16) % 256),
        3 => sc.int(u32),
        4 => 0xffff_ffff - @as(u32, sc.byte()),
        5 => mem +% sc.int(u16),
        else => gbase() + sc.int(u16),
    };
}

/// a length argument: mostly small, sometimes the size the host reported
/// (or one less), sometimes hostile
fn lenArg(sc: *Script) u32 {
    const sel = sc.byte();
    if (sel < 150) return sc.byte();
    if (sel < 190) return sc.int(u16) % 4096;
    if (sel < 215) return last_size;
    return switch (sel % 5) {
        0 => 0,
        1 => last_size -% 1,
        2 => 0xffff_ffff - @as(u32, sc.byte()),
        3 => sc.int(u16),
        else => sc.int(u32),
    };
}

fn small(sc: *Script) u32 {
    const sel = sc.byte();
    if (sel < 220) return sc.byte() % 8;
    return switch (sel % 3) {
        0 => sc.int(u16),
        1 => 0xffff_ffff - @as(u32, sc.byte()),
        else => sc.int(u32),
    };
}

/// a row or column number: mostly inside the last result, sometimes not
fn rowArg(sc: *Script) u32 {
    const sel = sc.byte();
    if (sel < 200 and last_rows > 0) return @intCast(sc.int(u32) % @min(last_rows, 0xffff_ffff));
    return small(sc);
}
fn colArg(sc: *Script) u32 {
    const sel = sc.byte();
    if (sel < 200 and last_cols > 0) return sc.byte() % last_cols;
    return small(sc);
}

fn noteResult(n: i64) void {
    last_rows = if (n > 0) @intCast(n) else 0;
    last_cols = h.spi_ncols();
}

fn anyHandle(arr: *const [8]u64) bool {
    for (arr) |x| if (x != 0) return true;
    return false;
}

fn keep(arr: *[8]u64, v: u64) void {
    for (arr) |*slot| {
        if (slot.* == 0) {
            slot.* = v;
            return;
        }
    }
    arr[@intCast(v % 8)] = v;
}

fn handleArg(sc: *Script, arr: *[8]u64) u64 {
    const sel = sc.byte();
    const k = arr[sel % 8];
    if (sel < 216) return k;
    return switch (sel % 4) {
        0 => k ^ (@as(u64, 1) << @intCast(sc.byte() % 64)),
        1 => sc.int(u64),
        2 => 0,
        else => k +% 1,
    };
}

/// SQL text: from the pool, or forged pointer/length
fn sqlArg(sc: *Script) struct { u32, u32 } {
    const sel = sc.byte();
    if (sel < 230) {
        const q = pool[sel % pool.len];
        return .{ @intCast(plzig.addrOf(q.ptr)), @intCast(q.len) };
    }
    return .{ ptrArg(sc), lenArg(sc) };
}

const codes = [_][]const u8{ "P0001", "23514", "22012", "Z9999", "XX000", "57014", "00000", "08006", "53100", "F0000", "58030", "01000", "02000", "p0001", "2351", "235140", "23\x0014", "\u{e9}235" };

/// a SQLSTATE: from the pool (valid, refused, malformed) or forged
fn codeArg(sc: *Script) struct { u32, u32 } {
    const sel = sc.byte();
    if (sel < 220) {
        const c = codes[sel % codes.len];
        return .{ @intCast(plzig.addrOf(c.ptr)), @intCast(c.len) };
    }
    return .{ ptrArg(sc), lenArg(sc) };
}

/// fill n parameter slots in gbuf (text parameters); returns their address
fn textParams(sc: *Script, n: u32) u32 {
    const max = @min(n, 64);
    const slots = plzig.rawPtr([*]Slot, gbase());
    for (0..max) |k| {
        const strs = [_][]const u8{ "1", "abc", "\\x00ff", "-32768", "1e400", "", "\u{e9}", "NaN" };
        const sel = sc.byte();
        slots[k] = if (sel < 40)
            .{ .val = 0, .len = 0, .is_null = 1 }
        else if (sel < 220)
            .{ .val = plzig.addrOf(strs[sel % strs.len].ptr), .len = @intCast(strs[sel % strs.len].len), .is_null = 0 }
        else if (sel < 245)
            .{ .val = ptrArg(sc), .len = lenArg(sc), .is_null = 0 }
        else
            .{ .val = sc.int(u64), .len = sc.int(u32), .is_null = sc.int(u32) };
    }
    return if (sc.byte() < 240) gbase() else ptrArg(sc);
}

/// fill n typed values in gbuf (prepared statements); returns their address
fn typedParams(sc: *Script, n: u32) u32 {
    const max = @min(n, 64);
    const vals = plzig.rawPtr([*]Value, gbase());
    for (0..max) |k| {
        const sel = sc.byte();
        const kind: u16 = if (sel < 200) param_kinds[sel % param_kinds.len] else if (sel < 230) (sel % 21) else sc.int(u16);
        const how = sc.byte();
        vals[k] = if (how < 40)
            .{ .val = 0, .len = 0, .kind = kind, .is_null = 1 }
        else if (how < 140)
            .{ .val = sc.int(u8), .len = 0, .kind = kind, .is_null = 0 }
        else if (how < 230)
            .{ .val = ptrArg(sc), .len = lenArg(sc), .kind = kind, .is_null = 0 }
        else
            .{ .val = sc.int(u64), .len = sc.int(u32), .kind = kind, .is_null = sc.int(u16) };
    }
    return if (sc.byte() < 240) gbase() else ptrArg(sc);
}

fn run(script: []const u8) i32 {
    var sc: Script = .{ .s = script };
    var ops: i32 = 0;
    // the last result belongs to the previous call
    last_rows = 0;
    last_cols = 0;
    while (!sc.done()) : (ops += 1) {
        const op = sc.byte();
        switch (op % 26) {
            0 => h.log(sc.byte() % 6, P([*]const u8, ptrArg(&sc)), lenArg(&sc)),
            1 => if (op == 1) {
                h.raise(P([*]const u8, ptrArg(&sc)), lenArg(&sc));
            } else if (op == 25) {
                // raise_error: SQLSTATE from the pool or forged, strings forged
                const code = codeArg(&sc);
                h.raise_error(P([*]const u8, code[0]), code[1], P([*]const u8, ptrArg(&sc)), lenArg(&sc),
                    P([*]const u8, ptrArg(&sc)), lenArg(&sc), P([*]const u8, ptrArg(&sc)), lenArg(&sc));
            },
            2 => if (op == 2) h.panic(P([*]const u8, ptrArg(&sc)), lenArg(&sc)),
            3, 4 => {
                const q = sqlArg(&sc);
                const n = small(&sc);
                noteResult(h.spi_execute(P([*]const u8, q[0]), q[1], P([*]const Slot, textParams(&sc, n)), n));
            },
            5 => if (op < 128) {
                _ = h.spi_ncols();
            } else if (op < 192) {
                // tz_convert: operation (sometimes invalid), a timestamp
                // (sometimes out of range), a zone from the pool or forged
                const zones = [_][]const u8{ "", "UTC", "Europe/Berlin", "America/New_York", "+05:30", "Mars/Base", "\xff", "PST8PDT" };
                const zsel = sc.byte();
                const z: struct { u32, u32 } = if (zsel < 220) .{ @intCast(plzig.addrOf(zones[zsel % zones.len].ptr)), @intCast(zones[zsel % zones.len].len) } else .{ ptrArg(&sc), lenArg(&sc) };
                const tops = if (sc.byte() < 230) 1 + sc.byte() % 2 else sc.int(u32);
                const v: i64 = if (sc.byte() < 200) @as(i64, sc.int(i32)) * 1_000_000_000 else @bitCast(sc.int(u64));
                _ = h.tz_convert(tops, v, P([*]const u8, z[0]), z[1]);
            } else {
                // numeric_op: operation (sometimes invalid), operands from the
                // pool or forged, a result buffer that may be too small or forged
                const a = numArg(&sc);
                const b = numArg(&sc);
                const nop = if (sc.byte() < 230) 1 + sc.byte() % 10 else sc.int(u32);
                const arg: i32 = @bitCast(small(&sc));
                last_size = @bitCast(h.numeric_op(nop, P([*]const u8, a[0]), a[1], P([*]const u8, b[0]), b[1], arg, P([*]u8, ptrArg(&sc)), lenArg(&sc)));
            },
            6 => if (last_cols > 0 or sc.byte() > 220) {
                last_size = @bitCast(h.spi_value_len(rowArg(&sc), colArg(&sc)));
            },
            7 => if (last_cols > 0 or sc.byte() > 220) {
                _ = h.spi_value_copy(rowArg(&sc), colArg(&sc), P([*]u8, ptrArg(&sc)), lenArg(&sc));
            },
            8 => if (last_cols > 0 or sc.byte() > 220) {
                last_size = @bitCast(h.spi_colname_len(colArg(&sc)));
            },
            9 => if (last_cols > 0 or sc.byte() > 220) {
                _ = h.spi_colname_copy(colArg(&sc), P([*]u8, ptrArg(&sc)), lenArg(&sc));
            },
            10 => if (last_cols > 0 or sc.byte() > 220) {
                last_size = @truncate(@as(u64, @bitCast(h.spi_row_size(rowArg(&sc)))));
            },
            11 => if (last_cols > 0 or sc.byte() > 220) {
                _ = h.spi_row_read(rowArg(&sc), P([*]u8, ptrArg(&sc)), lenArg(&sc));
            },
            12 => {
                const q = sqlArg(&sc);
                const n = small(&sc);
                const kinds = plzig.rawPtr([*]u32, gbase());
                for (0..@min(n, 64)) |k| kinds[k] = if (sc.byte() < 235) param_kinds[sc.byte() % param_kinds.len] else sc.int(u32);
                const p = if (sc.byte() < 240) gbase() else ptrArg(&sc);
                keep(&plans, h.spi_prepare(P([*]const u8, q[0]), q[1], P([*]const u32, p), n));
            },
            13 => if (anyHandle(&plans) or sc.byte() > 220) h.spi_plan_free(handleArg(&sc, &plans)),
            14 => if (anyHandle(&plans) or sc.byte() > 220) {
                const hd = handleArg(&sc, &plans);
                const n = small(&sc);
                noteResult(h.spi_execute_plan(hd, P([*]const Value, typedParams(&sc, n)), n));
            },
            15 => {
                const q = sqlArg(&sc);
                const n = small(&sc);
                keep(&cursors, h.spi_cursor_open(P([*]const u8, q[0]), q[1], P([*]const Slot, textParams(&sc, n)), n));
            },
            16 => if (anyHandle(&plans) or sc.byte() > 220) {
                const hd = handleArg(&sc, &plans);
                const n = small(&sc);
                keep(&cursors, h.spi_cursor_open_plan(hd, P([*]const Value, typedParams(&sc, n)), n));
            },
            17, 18 => if (anyHandle(&cursors) or sc.byte() > 220) {
                // forged buffer: written only if the row fits, else the row
                // stays current and its size is reported
                last_size = @truncate(@as(u64, @bitCast(h.spi_cursor_fetch(handleArg(&sc, &cursors), P([*]u8, ptrArg(&sc)), lenArg(&sc)))));
            },
            19 => if (anyHandle(&cursors) or sc.byte() > 220) {
                // a buffer that usually fits (the retry after a too-small one)
                _ = h.spi_cursor_fetch(handleArg(&sc, &cursors), P([*]u8, gbase()), @intCast(gbuf.len));
            },
            20 => if (anyHandle(&cursors) or sc.byte() > 220) h.spi_cursor_close(handleArg(&sc, &cursors)),
            21 => {
                // grow linear memory between host calls (any native pointer
                // the host kept would now be stale)
                const pages = sc.byte() % 16;
                _ = plzig.allocator.alloc(u8, @as(usize, pages) * 65536 + 1) catch {};
            },
            23 => pushRow(&sc),
            // transaction control: allowed only in the procedure variant
            // called by a top-level CALL; anywhere else PostgreSQL's error
            24 => if (sc.byte() < 128) h.commit() else h.rollback(),
            22 => {
                // scribble on the scratch buffer the host reads from
                const off = sc.int(u16) % gbuf.len;
                const n = @min(sc.byte(), gbuf.len - off);
                for (gbuf[off..][0..n]) |*b| b.* = sc.byte();
            },
            else => {
                // re-enter: run the next bytes of the script in a nested call
                // through SQL (a temporary second instance)
                const n = @min(sc.byte() % 32, sc.s.len - @min(sc.i, sc.s.len));
                var hex: [2 + 64]u8 = undefined;
                hex[0] = '\\';
                hex[1] = 'x';
                for (sc.s[sc.i..][0..n], 0..) |b, k| {
                    hex[2 + 2 * k] = "0123456789abcdef"[b >> 4];
                    hex[3 + 2 * k] = "0123456789abcdef"[b & 15];
                }
                sc.i += n;
                const q = "SELECT fuzz_hostabi($1::bytea) /*fuzzq*/";
                const p = [1]?[]const u8{hex[0 .. 2 + 2 * n]};
                _ = plzig.spi.execute(q, &p) catch {};
            },
        }
    }
    return ops;
}

/// a guest address as the pointer type an import declares.  Zig's safety
/// checks forbid null and misaligned pointers, so 0 becomes the alignment
/// and the address is aligned down.  (Not exercised here, therefore: guest
/// address 0 and misaligned slot/value arrays.  The host copies such arrays
/// with memcpy into its own memory before reading them, see plzig_host.c.)
fn P(comptime T: type, a: u32) T {
    const al: u32 = @alignOf(@typeInfo(T).pointer.child);
    var x = a - a % al;
    if (x == 0) x = al;
    return plzig.rawPtr(T, x);
