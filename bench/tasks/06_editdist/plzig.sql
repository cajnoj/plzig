CREATE FUNCTION t06_plzig(target text) RETURNS bigint LANGUAGE plzig STABLE STRICT AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
    };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT w FROM bench_words", &.{});
    var cur = try S.plan.?.open(.{});
    defer cur.close();
    var total: i64 = 0;
    while (try cur.next()) |row| {
        total += try levenshtein(target, try row.get([]const u8, 0));
    }
    return total;
}

fn levenshtein(a: []const u8, b: []const u8) !i64 {
    const prev = try plzig.allocator.alloc(u32, b.len + 1);
    defer plzig.allocator.free(prev);
    const cur = try plzig.allocator.alloc(u32, b.len + 1);
    defer plzig.allocator.free(cur);
    for (prev, 0..) |*p, j| p.* = @intCast(j);
    for (a, 1..) |ca, i| {
        cur[0] = @intCast(i);
        for (b, 1..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            cur[j] = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
        }
        @memcpy(prev, cur);
    }
    return prev[b.len];
$$;
