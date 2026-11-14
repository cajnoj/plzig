CREATE FUNCTION t03_plzig(n int) RETURNS text LANGUAGE plzig IMMUTABLE STRICT AS $$
    var out: std.ArrayList(u8) = .empty;
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        try out.print(plzig.allocator, "item{d};", .{i});
    }
    return out.items;
$$;
