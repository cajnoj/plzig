CREATE FUNCTION t09_plzig(n int) RETURNS int LANGUAGE plzig VOLATILE STRICT AS $$
    const S = struct {
        var ins: ?plzig.spi.Plan = null;
        var upd: ?plzig.spi.Plan = null;
    };
    if (S.ins == null) {
        S.ins = try plzig.spi.prepare("INSERT INTO bench_t9 VALUES ($1, $2)", &.{ .int4, .int4 });
        S.upd = try plzig.spi.prepare("UPDATE bench_t9 SET v = v + 1 WHERE id = $1", &.{.int4});
    }
    var i: i32 = 1;
    while (i <= n) : (i += 1) _ = try S.ins.?.execute(.{ i, i });
    i = 1;
    while (i <= n) : (i += 1) _ = try S.upd.?.execute(.{i});
    return n;
$$;
