-- numeric arithmetic in a loop: every + and * is a host call into
-- PostgreSQL's numeric code (plzig.Numeric, numeric_op)
CREATE FUNCTION t13a_plzig(n int) RETURNS numeric LANGUAGE plzig IMMUTABLE STRICT AS $$
    const N = plzig.Numeric;
    const c = try N.parse("1.25");
    var s = N.zero;
    var i: i64 = 1;
    while (i <= n) : (i += 1) s = try s.add(try (try N.fromI64(i)).mul(c));
    return s;
$$;
-- one field of a jsonb document, per row: the on-disk layout read in place
-- (binary search over the keys, the number decoded in the guest)
CREATE FUNCTION t13b_plzig(doc jsonb) RETURNS int LANGUAGE plzig IMMUTABLE STRICT AS $$
    const v = (try (try doc.root()).object.get("qty")) orelse return null;
    return @intCast(try v.number.toI64());
$$;
-- the same through the text representation, as before jsonb was mapped
-- natively: a domain over jsonb is passed as jsonb_out's text, scanned for
-- the top-level key (enough for these documents: no escapes, no nesting
-- before "qty")
CREATE DOMAIN bench_jsonb_text AS jsonb;
CREATE FUNCTION t13b_plzig_text(doc bench_jsonb_text) RETURNS int LANGUAGE plzig IMMUTABLE STRICT AS $$
    const key = "\"qty\": ";
    const at = std.mem.indexOf(u8, doc, key) orelse return null;
    var i = at + key.len;
    var v: i32 = 0;
    while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') : (i += 1) v = v * 10 + (doc[i] - '0');
    return v;
$$;
-- a timestamp column summed over a cursor: the raw value (plzig.Timestamp)
CREATE FUNCTION t13c_plzig() RETURNS bigint LANGUAGE plzig STABLE AS $$
    const S = struct {
        var plan: ?plzig.spi.Plan = null;
    };
    if (S.plan == null) S.plan = try plzig.spi.prepare("SELECT ts FROM bench_ts", &.{});
    var cur = try S.plan.?.open(.{});
    defer cur.close();
    var s: i64 = 0;
    while (try cur.next()) |row| s += @divFloor((try row.get(plzig.Timestamp, 0)).usecs, 1_000_000) + 946_684_800;
    return s;
$$;
