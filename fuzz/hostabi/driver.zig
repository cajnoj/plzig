    // fuzz/hostabi/driver.zig: body of
    //   fuzz_hostabi(script bytea) RETURNS int STRICT VOLATILE LANGUAGE plzig
    // compiled through docker/fake/hostilezig.c (which makes the SDK's host
    // import table public and adds rawPtr/addrOf/memSize helpers), so that
    // it can call every host import directly with whatever the script says:
    // forged pointers, lengths, row/column numbers, handles, kinds, values,
    // memory growth between calls, and re-entry through SQL.  See
    // fuzz/README.md, target "hostabi".  Returns the number of operations run.
    return run(script);
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
};

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
        const kind: u16 = if (sel < 200) 1 + (sel % 8) else if (sel < 230) (sel % 10) else sc.int(u16);
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
        switch (op % 24) {
            0 => h.log(sc.byte() % 6, P([*]const u8, ptrArg(&sc)), lenArg(&sc)),
            1 => if (op == 1) h.raise(P([*]const u8, ptrArg(&sc)), lenArg(&sc)),
            2 => if (op == 2) h.panic(P([*]const u8, ptrArg(&sc)), lenArg(&sc)),
            3, 4 => {
                const q = sqlArg(&sc);
                const n = small(&sc);
                noteResult(h.spi_execute(P([*]const u8, q[0]), q[1], P([*]const Slot, textParams(&sc, n)), n));
            },
            5 => _ = h.spi_ncols(),
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
                for (0..@min(n, 64)) |k| kinds[k] = if (sc.byte() < 235) 1 + sc.byte() % 8 else sc.int(u32);
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
