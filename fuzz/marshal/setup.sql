-- fuzz/marshal/setup.sql: identity functions for every supported type class
-- (target "marshal", fuzz/marshal/run.sh).  Non-strict, so NULL goes through
-- the guest as well.
CREATE TYPE fz_mood AS ENUM ('sad', 'ok', 'happy', 'very "happy"');
CREATE DOMAIN fz_posint AS int CHECK (VALUE > -1000000000);
CREATE DOMAIN fz_shorttext AS text CHECK (length(VALUE) < 100000);
CREATE TYPE fz_pair AS (a int, b text);

CREATE TABLE fz_types (t regtype PRIMARY KEY);
INSERT INTO fz_types VALUES
  ('boolean'), ('smallint'), ('integer'), ('bigint'), ('real'), ('double precision'),
  ('text'), ('varchar'), ('character(7)'), ('bytea'), ('numeric'), ('date'),
  ('timestamp'), ('timestamptz'), ('interval'), ('uuid'), ('inet'), ('json'),
  ('jsonb'), ('integer[]'), ('text[]'), ('int4range'), ('fz_mood'), ('fz_posint'),
  ('fz_shorttext'), ('fz_pair'), ('point'), ('"char"'), ('bit varying'), ('time'),
  ('time with time zone'), ('oid');

DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT t, format_type(t, NULL) AS name,
                    'fz_id_' || regexp_replace(format_type(t, NULL), '[^a-z0-9]+', '_', 'g') AS fn
               FROM fz_types LOOP
        -- jsonb arrives in its on-disk layout and leaves as JSON text: the
        -- guest's serialisation (plzig.Jsonb.toJsonText) is the identity
        EXECUTE format('CREATE FUNCTION %I(x %s) RETURNS %s LANGUAGE plzig AS $b$ %s $b$',
                       r.fn, r.name, r.name,
                       CASE WHEN r.t = 'jsonb'::regtype THEN 'return try (x orelse return null).toJsonText();' ELSE 'return x;' END);
    END LOOP;
END $$;

-- the guest's jsonb serialisation as text: must equal jsonb_out's exactly
CREATE FUNCTION fz_jsonb_text(x jsonb) RETURNS text STRICT LANGUAGE plzig AS $$
    return (try x.toJsonText()).text;
$$;

-- the NULL pattern of eight arguments of different classes, as a bit mask
CREATE FUNCTION fz_nullmask(a int, b text, c float8, d bytea, e numeric, f bool, g int8, h date)
RETURNS int LANGUAGE plzig AS $$
    var m: i32 = 0;
    if (a == null) m |= 1;
    if (b == null) m |= 2;
    if (c == null) m |= 4;
    if (d == null) m |= 8;
    if (e == null) m |= 16;
    if (f == null) m |= 32;
    if (g == null) m |= 64;
    if (h == null) m |= 128;
    return m;
$$;

-- a random jsonb document: nested objects and arrays (sometimes more than
-- 32 children, so that offsets are stored), numbers of every on-disk form,
-- strings with escapes and characters of every length, long and
-- same-length keys, scalars at the root
CREATE FUNCTION fz_rand_jsonb(depth int) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    p float8 := random();
    n int;
BEGIN
    IF depth <= 0 OR p < 0.35 THEN
        RETURN CASE floor(random() * 9)::int
            WHEN 0 THEN 'null'::jsonb
            WHEN 1 THEN to_jsonb(random() < 0.5)
            WHEN 2 THEN to_jsonb(fz_rand_text(CASE WHEN random() < 0.05 THEN 3000 ELSE 12 END))
            WHEN 3 THEN to_jsonb(chr(1 + floor(random() * 31)::int) || '"\/' || chr(127))
            WHEN 4 THEN to_jsonb((random() * 10 ^ floor(random() * 40 - 20))::numeric(60, 30))
            WHEN 5 THEN to_jsonb(floor((random() - 0.5) * 1e15)::int8)
            WHEN 6 THEN (CASE WHEN random() < 0.5 THEN '-' ELSE '' END || floor(random() * 1000) || 'e' || floor((random() - 0.5) * 2000))::jsonb
            WHEN 7 THEN to_jsonb(('0.' || repeat('0', floor(random() * 80)::int) || floor(random() * 1e6))::numeric)
            ELSE to_jsonb(random()) END;
    END IF;
    n := CASE WHEN random() < 0.1 THEN 30 + floor(random() * 40)::int ELSE floor(random() * 5)::int END;
    IF p < 0.67 THEN
        RETURN coalesce((SELECT jsonb_agg(fz_rand_jsonb(depth - 1)) FROM generate_series(1, n)), '[]'::jsonb);
    END IF;
    RETURN coalesce((SELECT jsonb_object_agg(CASE floor(random() * 4)::int
                                                 WHEN 0 THEN fz_rand_text(6)
                                                 WHEN 1 THEN lpad(g::text, 3, 'k')
                                                 WHEN 2 THEN repeat(chr(97 + floor(random() * 3)::int), floor(random() * 300)::int)
                                                 ELSE chr(97 + floor(random() * 26)::int) END,
                                             fz_rand_jsonb(depth - 1))
                       FROM generate_series(1, n) g), '{}'::jsonb);
END $$;

-- a random value of type t, as text (NULL sometimes), from random()
CREATE FUNCTION fz_rand_text(maxlen int) RETURNS text LANGUAGE sql VOLATILE AS $$
    SELECT coalesce(string_agg(chr(CASE
        WHEN r < 0.55 THEN 1 + floor(random() * 126)::int
        WHEN r < 0.75 THEN 128 + floor(random() * (2047 - 128))::int
        WHEN r < 0.90 THEN 2048 + floor(random() * (55295 - 2048))::int
        WHEN r < 0.95 THEN 57344 + floor(random() * (65533 - 57344))::int
        ELSE 65536 + floor(random() * (1114111 - 65536))::int END), ''), '')
    FROM (SELECT random() AS r FROM generate_series(1, floor(random() * (maxlen + 1))::int)) s
$$;
CREATE FUNCTION fz_rand_value(t regtype) RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    p float8 := random();
    n int;
    n_text text;
BEGIN
    IF p < 0.05 THEN RETURN NULL; END IF;
    CASE t
    WHEN 'boolean'::regtype THEN RETURN (random() < 0.5)::text;
    WHEN 'smallint'::regtype THEN
        RETURN (ARRAY['-32768', '32767', '0', '-1', (floor(random() * 65536) - 32768)::text])[1 + floor(random() * 5)::int];
    WHEN 'integer'::regtype THEN
        RETURN (ARRAY['2147483647', '-2147483648', '0', (floor(random() * 4294967296) - 2147483648)::bigint::text])[1 + floor(random() * 4)::int];
    WHEN 'fz_posint'::regtype THEN
        RETURN (ARRAY['2147483647', '-999999999', (floor(random() * 3000000000) - 999999999)::bigint::text])[1 + floor(random() * 3)::int];
    WHEN 'bigint'::regtype THEN
        RETURN (ARRAY['-9223372036854775808', '9223372036854775807', '0',
                      ((random() - 0.5) * 18446744073709551615::numeric)::numeric(30, 0)::text])[1 + floor(random() * 4)::int];
    WHEN 'real'::regtype THEN
        RETURN (ARRAY['NaN', 'Infinity', '-Infinity', '-0', '1e-45', '3.4028235e+38',
                      ((random() - 0.5) * 10 ^ (random() * 60 - 30))::float4::text])[1 + floor(random() * 7)::int];
    WHEN 'double precision'::regtype THEN
        RETURN (ARRAY['NaN', 'Infinity', '-Infinity', '-0', '5e-324', '1.7976931348623157e+308',
                      ((random() - 0.5) * 10 ^ (random() * 600 - 300))::text])[1 + floor(random() * 7)::int];
    WHEN 'text'::regtype, 'varchar'::regtype, 'fz_shorttext'::regtype THEN
        RETURN fz_rand_text(CASE WHEN random() < 0.1 THEN 5000 ELSE 40 END);
    WHEN 'character(7)'::regtype THEN RETURN rpad(fz_rand_text(7), floor(random() * 8)::int);
    WHEN 'bytea'::regtype THEN
        SELECT '\x' || coalesce(string_agg(lpad(to_hex(floor(random() * 256)::int), 2, '0'), ''), '') INTO STRICT n_text
          FROM generate_series(1, floor(random() * (CASE WHEN random() < 0.1 THEN 9000 ELSE 40 END))::int);
        RETURN n_text;
    WHEN 'numeric'::regtype THEN
        RETURN (ARRAY['NaN', 'Infinity', '-Infinity', '0', '-0.000000000000000000000000000001',
                      (random() * 10 ^ floor(random() * 200)::int)::numeric(400, 100)::text])[1 + floor(random() * 6)::int];
    WHEN 'date'::regtype THEN
        RETURN (ARRAY['infinity', '-infinity', '4713-01-01 BC', '4714-11-24 BC', '5874897-12-31',
                      ('2000-01-01'::date + floor((random() - 0.5) * 2000000)::int)::text,
                      ('4714-11-24 BC'::date + floor(random() * 2147483494)::int)::text])[1 + floor(random() * 7)::int];
    WHEN 'timestamp'::regtype, 'timestamptz'::regtype THEN
        RETURN (ARRAY['infinity', '-infinity', '4714-11-24 00:00:00 BC', '294276-12-31 23:59:59.999999',
                      '2016-12-31 23:59:60', ('2000-01-01'::timestamp + (random() - 0.5) * interval '500 years')::text,
                      ('4714-11-24 00:00:00 BC'::timestamp + random() * interval '298000 years')::text])[1 + floor(random() * 7)::int];
    WHEN 'time'::regtype THEN
        RETURN (ARRAY['24:00:00', '00:00', ('00:00'::time + random() * interval '24 hours')::text])[1 + floor(random() * 3)::int];
    WHEN 'time with time zone'::regtype THEN
        RETURN (ARRAY['24:00:00+15:59', '00:00-15:59:59',
                      ('00:00'::time + random() * interval '24 hours')::text ||
                      (ARRAY['+', '-'])[1 + floor(random() * 2)::int] ||
                      to_char(make_interval(secs => floor(random() * 57599)), 'HH24:MI:SS')])[1 + floor(random() * 3)::int];
    WHEN 'interval'::regtype THEN
        RETURN (ARRAY['178956970 years 7 months 2147483647 days 596523 hours',
                      '-178956970 years -8 months -2147483648 days -596523 hours',
                      ((random() - 0.5) * interval '7000 days 3 hours')::text])[1 + floor(random() * 3)::int];
    WHEN 'uuid'::regtype THEN RETURN md5(random()::text)::uuid::text;
    WHEN 'oid'::regtype THEN
        RETURN (ARRAY['0', '4294967295', floor(random() * 4294967296)::bigint::text])[1 + floor(random() * 3)::int];
    WHEN 'inet'::regtype THEN
        RETURN CASE WHEN random() < 0.5
               THEN format('%s.%s.%s.%s/%s', floor(random() * 256), floor(random() * 256), floor(random() * 256), floor(random() * 256), 8 + floor(random() * 25))
               ELSE format('%s::%s/%s', to_hex(floor(random() * 65536)::int), to_hex(floor(random() * 65536)::int), 16 + floor(random() * 113)) END::inet::text;
    WHEN 'json'::regtype THEN
        RETURN json_build_object('k', fz_rand_text(10), 'n', random(), 'a', json_build_array(1, NULL, true, fz_rand_text(5)),
                                 fz_rand_text(3), json_build_object('deep', fz_rand_text(20)))::text;
    WHEN 'jsonb'::regtype THEN
        RETURN fz_rand_jsonb(4)::text;
    WHEN 'integer[]'::regtype THEN
        SELECT array_agg(CASE WHEN random() < 0.1 THEN NULL ELSE floor(random() * 1000)::int END)::text INTO STRICT n_text
          FROM generate_series(0, floor(random() * 20)::int);
        RETURN n_text;
    WHEN 'text[]'::regtype THEN
        SELECT array_agg(CASE WHEN random() < 0.1 THEN NULL ELSE fz_rand_text(8) END)::text INTO STRICT n_text
          FROM generate_series(0, floor(random() * 10)::int);
        RETURN n_text;
    WHEN 'int4range'::regtype THEN
        n := floor(random() * 1000)::int;
        RETURN int4range(n, n + floor(random() * 50)::int, (ARRAY['[)', '[]', '()', '(]'])[1 + floor(random() * 4)::int])::text;
    WHEN 'fz_mood'::regtype THEN RETURN (enum_range(NULL::fz_mood))[1 + floor(random() * 4)::int]::text;
    WHEN 'fz_pair'::regtype THEN RETURN ROW(floor(random() * 100)::int, fz_rand_text(6))::fz_pair::text;
    WHEN 'point'::regtype THEN RETURN point(random() * 1e6, (random() - 0.5) * 1e-6)::text;
    WHEN '"char"'::regtype THEN RETURN chr(1 + floor(random() * 126)::int)::"char"::text;
    WHEN 'bit varying'::regtype THEN
        SELECT coalesce(string_agg((random() < 0.5)::int::text, ''), '') INTO STRICT n_text FROM generate_series(1, floor(random() * 70)::int);
        RETURN n_text;
    END CASE;
    RETURN NULL;
END $$;
