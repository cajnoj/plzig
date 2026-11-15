--
-- encoding: databases whose encoding is not UTF-8.  Text reaches the guest
-- as bytes in the database encoding; everything the guest returns or logs
-- must be valid in it (NUL bytes never are) or the call fails.
--
\set VERBOSITY terse
SELECT current_database() AS regress_db \gset
SET client_min_messages = warning;
DROP DATABASE IF EXISTS regress_plzig_latin1;
DROP DATABASE IF EXISTS regress_plzig_eucjp;
RESET client_min_messages;
CREATE DATABASE regress_plzig_latin1 ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
CREATE DATABASE regress_plzig_eucjp ENCODING 'EUC_JP' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;

\c regress_plzig_latin1
\set VERBOSITY terse
SET client_encoding = 'UTF8';
CREATE EXTENSION plzig;
SELECT getdatabaseencoding();
CREATE FUNCTION l_len(t text) RETURNS int STRICT LANGUAGE plzig AS $$
    return @intCast(t.len);
$$;
CREATE FUNCTION l_hex(t text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{x}", .{t});
$$;
CREATE FUNCTION l_echo(t text) RETURNS text STRICT LANGUAGE plzig AS $$
    return t;
$$;
-- é is one byte (0xe9) in LATIN1; the client sees UTF-8
SELECT l_len('café'), l_hex('café'), l_echo('café'), l_echo('café') = 'café' AS same;
-- every byte but NUL is a valid LATIN1 character
CREATE FUNCTION l_bytes(which int) RETURNS text STRICT LANGUAGE plzig AS $$
    return switch (which) {
        0 => "caf\xe9",
        1 => "caf\xc3\xa9", // UTF-8 bytes: two LATIN1 characters
        2 => "\xff",
        3 => "nul\x00byte",
        else => "\x00",
    };
$$;
SELECT l_bytes(0), l_bytes(1), l_bytes(2);
SELECT l_bytes(3);
SELECT l_bytes(4);
-- also through input functions and SPI
CREATE FUNCTION l_vc(v varchar) RETURNS varchar STRICT LANGUAGE plzig AS $$
    return if (v.len > 1000) v else "x\x00";
$$;
SELECT l_vc('a');
CREATE FUNCTION l_spi() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT 'caf\xe9'::text || $1", &.{"\xe9"});
    return (try r.get(0, 0)).?;
$$;
SELECT l_spi(), l_hex(l_spi());
CREATE FUNCTION l_badspi() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT $1", &.{"a\x00"});
    return (try r.get(0, 0)).?;
$$;
SELECT l_badspi();
CREATE FUNCTION l_msg() RETURNS void LANGUAGE plzig AS $$
    plzig.notice("caf\xe9", .{});
    plzig.raise("{s}", .{"\xe9t\xe9"});
$$;
SELECT l_msg();
-- a body with non-ASCII text is compiled as is (bytes in the database encoding)
CREATE FUNCTION l_literal() RETURNS text LANGUAGE plzig AS $$
    // Grüße
    return "é";
$$;
SELECT l_literal(), l_hex(l_literal());

\c regress_plzig_eucjp
\set VERBOSITY terse
SET client_encoding = 'UTF8';
CREATE EXTENSION plzig;
SELECT getdatabaseencoding();
CREATE FUNCTION e_hex(t text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try std.fmt.allocPrint(plzig.allocator, "{x}", .{t});
$$;
SELECT e_hex('あい');
CREATE FUNCTION e_bytes(which int) RETURNS text STRICT LANGUAGE plzig AS $$
    return switch (which) {
        0 => "\xa4\xa2",   // あ
        1 => "\xff\xfe",   // invalid
        2 => "\xa4",       // truncated character
        else => "ok",
    };
$$;
SELECT e_bytes(0), e_bytes(3);
SELECT e_bytes(1);
SELECT e_bytes(2);
-- through input functions (json), log messages, raise, SPI parameters
CREATE FUNCTION e_json(which int) RETURNS jsonb STRICT LANGUAGE plzig AS $$
    return plzig.jsonText(if (which == 0) "\"\xa4\xa2\"" else "\"\xff\"");
$$;
SELECT e_json(0);
SELECT e_json(1);
CREATE FUNCTION e_log(bad boolean) RETURNS void STRICT LANGUAGE plzig AS $$
    if (bad) plzig.notice("bad \xff", .{}) else plzig.notice("good \xa4\xa2", .{});
$$;
SELECT e_log(false);
SELECT e_log(true);
CREATE FUNCTION e_raise() RETURNS void LANGUAGE plzig AS $$
    plzig.raise("bad \xa4", .{});
$$;
SELECT e_raise();
CREATE FUNCTION e_spi() RETURNS text LANGUAGE plzig AS $$
    const r = try plzig.spi.execute("SELECT $1", &.{"\xa4"});
    return (try r.get(0, 0)).?;
$$;
SELECT e_spi();
-- a long log message is truncated at a character boundary, never inside one
CREATE FUNCTION e_long() RETURNS void LANGUAGE plzig AS $$
    // 65535 ASCII bytes, then a two-byte character across the 64 kB limit
    var buf: [65537]u8 = undefined;
    @memset(buf[0..65535], 'a');
    buf[65535] = 0xa4;
    buf[65536] = 0xa2;
    plzig.notice("{s}", .{buf[0..]});
$$;
DO $$
BEGIN
  PERFORM set_config('client_min_messages', 'warning', true);
  PERFORM e_long();
  PERFORM set_config('client_min_messages', 'notice', true);
  RAISE NOTICE 'e_long: no error';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('client_min_messages', 'notice', true);
  RAISE NOTICE 'e_long failed: %', SQLERRM;
END $$;
-- error names are shown as printable ASCII only
CREATE FUNCTION e_errname() RETURNS void LANGUAGE plzig AS $$
    return error.@"Bad\xffName";
$$;
SELECT e_errname();

\c :regress_db
DROP DATABASE regress_plzig_latin1;
DROP DATABASE regress_plzig_eucjp;
