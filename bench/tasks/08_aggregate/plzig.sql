CREATE FUNCTION t08_plzig() RETURNS text LANGUAGE plzig STABLE AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
    };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT k, v FROM bench_big", &.{});
    var cur = try S.plan.?.open(.{});
    defer cur.close();
    var s: i64 = 0;
    var c: i64 = 0;
    while (try cur.next()) |row| {
        if (@rem(try row.get(i32, 0), 3) == 0) s += try row.get(i32, 1);
        c += 1;
    }
    return try std.fmt.allocPrint(plzig.allocator, "{d}/{d}", .{ s, c });
$$;
