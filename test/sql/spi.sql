--
-- spi: queries, parameters, read-only enforcement, permissions, SECURITY DEFINER
--
\set VERBOSITY terse

CREATE TABLE items (id int PRIMARY KEY, name text, price numeric);
INSERT INTO items VALUES (1, 'apple', 0.50), (2, 'pear', 0.75), (3, NULL, 1.25);

CREATE FUNCTION item_report() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT id, name, price FROM items ORDER BY id", &.{});
    var out: std.ArrayList(u8) = .empty;
    try out.print(plzig.allocator, "{d} rows, {d} cols:", .{ r.rows, r.columns });
    var c: u32 = 0;
    while (c < r.columns) : (c += 1) try out.print(plzig.allocator, " {s}", .{try r.columnName(c)});
    var i: u64 = 0;
    while (i < r.rows) : (i += 1) {
        const name = (try r.get(i, 1)) orelse "<null>";
        try out.print(plzig.allocator, "; {s}={s}@{s}", .{ (try r.get(i, 0)).?, name, (try r.get(i, 2)).? });
    }
    return out.items;
$$;
SELECT item_report();

-- parameters are text; cast them in SQL. NULL parameters are supported.
CREATE FUNCTION item_name(id int) RETURNS text STRICT LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{id});
    const r = try plzig.spi.execute("SELECT name FROM items WHERE id = $1::int", &.{s});
    if (r.rows == 0) return error.NotFound;
    return try r.get(0, 0);
$$;
SELECT item_name(2), item_name(3) IS NULL AS null_name;
SELECT item_name(42);

CREATE FUNCTION null_param() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT coalesce($1, 'was null') || '/' || $2", &.{ null, "x" });
    return try r.get(0, 0);
$$;
SELECT null_param();

-- injection-safe: parameters are values, not SQL
CREATE FUNCTION count_named(n text) RETURNS bigint STRICT LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT count(*) FROM items WHERE name = $1", &.{n});
    return try std.fmt.parseInt(i64, (try r.get(0, 0)).?, 10);
$$;
SELECT count_named('apple'), count_named($$' OR '1'='1$$);

-- out-of-range access is an error, not a crash
CREATE FUNCTION bad_row() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT 1", &.{});
    return try r.get(5, 0);
$$;
SELECT bad_row();
CREATE FUNCTION bad_col() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT 1", &.{});
    return try r.columnName(7);
$$;
SELECT bad_col();

-- DML in a VOLATILE function
CREATE FUNCTION add_item(id int, name text) RETURNS bigint STRICT LANGUAGE plzig AS $$
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{id});
    const r = try plzig.spi.execute("INSERT INTO items(id, name, price) VALUES ($1::int, $2, 1)", &.{ s, name });
    return @intCast(r.rows);
$$;
SELECT add_item(10, 'plum');
SELECT count(*) FROM items;

-- STABLE / IMMUTABLE functions get a read-only SPI connection
CREATE FUNCTION sneaky_insert() RETURNS bigint STABLE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("INSERT INTO items(id, name) VALUES (99, 'sneaky')", &.{});
    return @intCast(r.rows);
$$;
SELECT sneaky_insert();
CREATE FUNCTION sneaky_immutable() RETURNS bigint IMMUTABLE LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("DELETE FROM items", &.{});
    return @intCast(r.rows);
$$;
SELECT sneaky_immutable();
SELECT count(*) FROM items WHERE id = 99;

-- SQL errors abort the call; the guest cannot catch them
CREATE FUNCTION sql_error() RETURNS int LANGUAGE plzig AS $$
    _ = plzig.spi.execute("SELECT 1/0", &.{}) catch {};
    plzig.notice("must not get here", .{});
    return 1;
$$;
SELECT sql_error();

-- transaction control is not available
CREATE PROCEDURE try_commit() LANGUAGE plzig AS $$
    _ = try plzig.spi.execute("COMMIT", &.{});
$$;
CALL try_commit();

-- permissions: SPI runs with the privileges of the current user
CREATE TABLE secret (s text);
INSERT INTO secret VALUES ('top secret');
REVOKE ALL ON secret FROM PUBLIC;
CREATE FUNCTION read_secret() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT s FROM secret", &.{});
    return try r.get(0, 0);
$$;
CREATE FUNCTION read_secret_definer() RETURNS text SECURITY DEFINER SET search_path = public
  LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT s FROM secret", &.{});
    return try r.get(0, 0);
$$;
GRANT EXECUTE ON FUNCTION read_secret(), read_secret_definer() TO regress_plzig_nobody;
SELECT read_secret();
SET ROLE regress_plzig_nobody;
SELECT read_secret();
SELECT read_secret_definer();
SELECT current_user;
RESET ROLE;

-- an unprivileged developer's function cannot read the table either
SET ROLE regress_plzig_dev;
CREATE FUNCTION dev_reads_secret() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT s FROM secret", &.{});
    return try r.get(0, 0);
$$;
SELECT dev_reads_secret();
CREATE FUNCTION dev_whoami() RETURNS text SECURITY DEFINER LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT current_user::text", &.{});
    return try r.get(0, 0);
$$;
SELECT dev_whoami();
RESET ROLE;
SELECT dev_reads_secret();
SELECT dev_whoami();
