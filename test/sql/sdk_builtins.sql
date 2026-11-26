--
-- sdk_builtins: the Tier A guest-SDK helpers (crypto digests, hex, UUID v3/v5,
-- Unix-epoch conversions, string functions) checked for *exact parity* with
-- PostgreSQL's own built-in functions.  Each parity query selects the rows
-- where the SDK result differs from the builtin: every one must return no
-- rows.  The point of these helpers is to save a round trip by matching the
-- builtin, so any divergence is a bug.
--
\set VERBOSITY terse

-- digests -------------------------------------------------------------------
CREATE FUNCTION sdk_md5(x text) RETURNS text STRICT LANGUAGE plzig AS $$
    const h = plzig.crypto.md5Hex(x);
    return try plzig.allocator.dupe(u8, &h);
$$;
CREATE FUNCTION sdk_sha256(x text) RETURNS text STRICT LANGUAGE plzig AS $$
    const h = plzig.crypto.sha256Hex(x);
    return try plzig.allocator.dupe(u8, &h);
$$;

SELECT x FROM unnest(ARRAY['', 'a', 'abc', 'héllo wörld', E'tab\tnl\n', '日本語',
                           repeat('x', 1000)]) AS x
 WHERE sdk_md5(x) IS DISTINCT FROM md5(x)
    OR sdk_sha256(x) IS DISTINCT FROM encode(sha256(convert_to(x, 'UTF8')), 'hex');

-- hex -----------------------------------------------------------------------
CREATE FUNCTION sdk_hexenc(x bytea) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.hex.encode(plzig.allocator, x);
$$;
CREATE FUNCTION sdk_hexdec(x text) RETURNS bytea STRICT LANGUAGE plzig AS $$
    return try plzig.hex.decode(plzig.allocator, x);
$$;

SELECT x FROM (VALUES (''::bytea), ('\x00'::bytea), ('\xdeadbeef00ff'::bytea),
                      (convert_to('héllo', 'UTF8'))) AS v(x)
 WHERE sdk_hexenc(x) IS DISTINCT FROM encode(x, 'hex')
    OR sdk_hexdec(encode(x, 'hex')) IS DISTINCT FROM x;

-- UUID v3/v5 (RFC 4122 §4.3; vectors from the Python uuid documentation) -----
CREATE FUNCTION sdk_uuid3(name text) RETURNS uuid STRICT LANGUAGE plzig AS $$
    return plzig.Uuid.v3(plzig.Uuid.namespace.dns, name);
$$;
CREATE FUNCTION sdk_uuid5(name text) RETURNS uuid STRICT LANGUAGE plzig AS $$
    return plzig.Uuid.v5(plzig.Uuid.namespace.dns, name);
$$;

SELECT sdk_uuid3('python.org') = '6fa459ea-ee8a-3ca4-894e-db77e160355e'::uuid AS v3_ok,
       sdk_uuid5('python.org') = '886313e1-3b8a-5372-9b90-0c9aee199e5d'::uuid AS v5_ok;

-- Unix epoch ----------------------------------------------------------------
CREATE FUNCTION sdk_epoch(ts timestamptz) RETURNS bigint STRICT LANGUAGE plzig AS $$
    return try ts.toUnixSeconds();
$$;
CREATE FUNCTION sdk_fromepoch(s bigint) RETURNS timestamptz STRICT LANGUAGE plzig AS $$
    return try plzig.TimestampTz.fromUnixSeconds(s);
$$;

SELECT t FROM unnest(ARRAY['2000-01-01 00:00:00+00', '1970-01-01 00:00:00+00',
                           '2021-06-15 12:00:00+00', '1999-12-31 23:59:59+00',
                           '2038-01-19 03:14:07+00']::timestamptz[]) AS t
 WHERE sdk_epoch(t) IS DISTINCT FROM floor(extract(epoch FROM t))::bigint;
SELECT s FROM unnest(ARRAY[0, 946684800, 1609459200, -100, 2147483647]::bigint[]) AS s
 WHERE sdk_fromepoch(s) IS DISTINCT FROM to_timestamp(s);

-- strings -------------------------------------------------------------------
CREATE FUNCTION sdk_split(s text, d text, n int) RETURNS text STRICT LANGUAGE plzig AS $$
    return plzig.strings.splitPart(s, d, n);
$$;
CREATE FUNCTION sdk_repeat(s text, n int) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.strings.repeat(plzig.allocator, s, n);
$$;
CREATE FUNCTION sdk_reverse(s text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.strings.reverse(plzig.allocator, s);
$$;
CREATE FUNCTION sdk_lpad(s text, len int, f text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.strings.lpad(plzig.allocator, s, len, f);
$$;
CREATE FUNCTION sdk_rpad(s text, len int, f text) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.strings.rpad(plzig.allocator, s, len, f);
$$;
CREATE FUNCTION sdk_chr(n int) RETURNS text STRICT LANGUAGE plzig AS $$
    return try plzig.strings.chr(plzig.allocator, n);
$$;
CREATE FUNCTION sdk_ascii(s text) RETURNS int STRICT LANGUAGE plzig AS $$
    return plzig.strings.ascii(s);
$$;

-- split_part: 1-based, negative from the end (PG 14+), out of range -> ''
SELECT s, d, n FROM (VALUES
        ('a~b~c', '~', 1), ('a~b~c', '~', 2), ('a~b~c', '~', 3), ('a~b~c', '~', 4),
        ('a~b~c', '~', -1), ('a~b~c', '~', -2), ('a~b~c', '~', -4),
        ('a,,c', ',', 2), ('a::b::c', '::', 2), ('', 'x', 1),
        ('abc', '', 1), ('abc', '', 2)) AS v(s, d, n)
 WHERE sdk_split(s, d, n) IS DISTINCT FROM split_part(s, d, n);

-- repeat
SELECT s, n FROM (VALUES ('ab', 3), ('x', 0), ('', 5), ('héllo', 2), ('q', -1)) AS v(s, n)
 WHERE sdk_repeat(s, n) IS DISTINCT FROM repeat(s, n);

-- reverse (by character)
SELECT s FROM unnest(ARRAY['', 'abc', 'héllo', '日本語', 'a😀b']) AS s
 WHERE sdk_reverse(s) IS DISTINCT FROM reverse(s);

-- lpad / rpad: pad cycling, truncation to the first len characters, empty fill
SELECT s, len, f FROM (VALUES
        ('hi', 5, ' '), ('hi', 5, 'xy'), ('hello', 3, 'x'), ('hi', 0, 'x'),
        ('hi', -1, 'x'), ('héllo', 8, '·'), ('é', 3, 'x'), ('hi', 5, '')) AS v(s, len, f)
 WHERE sdk_lpad(s, len, f) IS DISTINCT FROM lpad(s, len, f)
    OR sdk_rpad(s, len, f) IS DISTINCT FROM rpad(s, len, f);

-- chr (Unicode code point) and ascii (code point of the first character)
SELECT n FROM unnest(ARRAY[65, 97, 9786, 233, 128512]) AS n
 WHERE sdk_chr(n) IS DISTINCT FROM chr(n);
SELECT s FROM unnest(ARRAY['A', 'abc', '☺!', 'é', '日本', '😀x', '']) AS s
 WHERE sdk_ascii(s) IS DISTINCT FROM ascii(s);
