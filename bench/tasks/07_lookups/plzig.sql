-- Prepared statement kept in a global, typed parameter and result.
CREATE FUNCTION t07_plzig(n int) RETURNS bigint LANGUAGE plzig STABLE STRICT AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
    };
    if (S.plan == null)
        S.plan = try plzig.spi.prepare("SELECT v FROM bench_kv WHERE k = $1", &.{.int4});
    var s: i64 = 0;
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        const r = try S.plan.?.execute(.{@rem(i * 7919, 100000) + 1});
        s += try (try r.row(0)).get(i32, 0);
    }
    return s;
$$;

-- The same without a prepared statement: spi.execute (parsed and planned on
-- every call, text parameter and text result).
CREATE FUNCTION t07_plzig_exec(n int) RETURNS bigint LANGUAGE plzig STABLE STRICT AS $$
    var s: i64 = 0;
    var i: i32 = 1;
    var buf: [16]u8 = undefined;
    while (i <= n) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "{d}", .{@rem(i * 7919, 100000) + 1});
        const r = try plzig.spi.execute("SELECT v FROM bench_kv WHERE k = $1::int4", &.{key});
        const v = (try r.get(0, 0)) orelse return error.NotFound;
        s += try std.fmt.parseInt(i64, v, 10);
    }
    return s;
$$;
