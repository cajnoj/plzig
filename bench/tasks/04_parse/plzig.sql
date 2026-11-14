CREATE FUNCTION t04_plzig(line text) RETURNS text LANGUAGE plzig IMMUTABLE STRICT AS $$
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(plzig.allocator, line.len);
    var it = std.mem.splitScalar(u8, line, ',');
    var first = true;
    while (it.next()) |raw| {
        if (!first) out.appendAssumeCapacity(',');
        first = false;
        const f = std.mem.trim(u8, raw, " ");
        if (isIdent(f)) {
            for (f) |c| out.appendAssumeCapacity(std.ascii.toLower(c));
        } else {
            out.appendAssumeCapacity('?');
        }
    }
    return out.items;
}

fn isIdent(f: []const u8) bool {
    if (f.len == 0 or f.len > 63) return false;
    for (f, 0..) |c, i| {
        const l = std.ascii.toLower(c);
        const ok = (l >= 'a' and l <= 'z') or l == '_' or (i > 0 and l >= '0' and l <= '9');
        if (!ok) return false;
    }
    return true;
$$;
