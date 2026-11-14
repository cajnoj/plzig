--
-- errors: plzig.raiseError / raiseErrorFmt, an SQL ERROR with a SQLSTATE,
-- message, detail and hint chosen by the function (PLAN.md section 12,
-- item 7); refused classes and malformed codes are errors of their own.
--

-- non-strict: NULL detail/hint are omitted
CREATE FUNCTION err_raise(code text, msg text, detail text, hint text) RETURNS int LANGUAGE plzig AS $$
    plzig.raiseError(.{ .sqlstate = code orelse "P0001", .message = msg orelse "", .detail = detail, .hint = hint });
$$;
-- the same with raw bytes (NUL, invalid sequences)
CREATE FUNCTION err_raise_b(code bytea, msg bytea, detail bytea, hint bytea) RETURNS int LANGUAGE plzig AS $$
    plzig.raiseError(.{ .sqlstate = code orelse "P0001", .message = msg orelse "", .detail = detail, .hint = hint });
$$;
CREATE FUNCTION err_fmt(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    if (x > 10) plzig.raiseErrorFmt(.{ .sqlstate = "22003", .detail = "The limit is 10.", .hint = "Pass a smaller value." },
                                    "value {d} is out of range", .{x});
    return x;
$$;
-- what a PL/pgSQL caller sees
CREATE FUNCTION err_show(q text) RETURNS text LANGUAGE plpgsql AS $d$
DECLARE s text; m text; d text; h text;
BEGIN
  EXECUTE q;
  RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN format('%s | %s | %s | %s', s, m, nullif(d, ''), nullif(h, ''));
END $d$;
CREATE FUNCTION err_lens(q text) RETURNS text LANGUAGE plpgsql AS $d$
DECLARE s text; m text; d text; h text;
BEGIN
  EXECUTE q;
  RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN format('%s | message %s bytes, %s chars | detail %s bytes | hint %s bytes', s,
                octet_length(m), char_length(m), octet_length(d), octet_length(h));
END $d$;

-- every field arrives
SELECT err_show($$SELECT err_raise('23514', 'value too large', 'The limit is 10.', 'Use a smaller value.')$$);
SELECT err_show($$SELECT err_raise('P0001', 'only a message', NULL, NULL)$$);
SELECT err_show($$SELECT err_raise('22012', 'detail only', 'some detail', NULL)$$);
SELECT err_show($$SELECT err_raise('2201B', 'hint only', NULL, 'some hint')$$);
-- empty detail and hint are omitted, an empty message is allowed
SELECT err_show($$SELECT err_raise('P0001', '', '', '')$$);
-- the default SQLSTATE is P0001, like plzig.raise
SELECT err_show($$SELECT err_raise(NULL, 'default code', NULL, NULL)$$);
SELECT err_show($$SELECT err_fmt(5)$$), err_show($$SELECT err_fmt(11)$$);
-- plzig.raise is unchanged
CREATE FUNCTION err_plain() RETURNS int LANGUAGE plzig AS $$
    plzig.raise("plain {s}", .{"raise"});
$$;
SELECT err_show('SELECT err_plain()');
-- as the client sees it
SELECT err_raise('23514', 'value too large', 'The limit is 10.', 'Use a smaller value.');
SELECT err_fmt(12);

-- a calling PL/pgSQL function catches it by condition name or SQLSTATE
CREATE FUNCTION err_catch(code text) RETURNS text LANGUAGE plpgsql AS $d$
BEGIN
  PERFORM err_raise(code, 'raised ' || code, NULL, NULL);
  RETURN 'not raised';
EXCEPTION
  WHEN unique_violation THEN RETURN 'unique_violation: ' || SQLERRM;
  WHEN check_violation THEN RETURN 'check_violation: ' || SQLERRM;
  WHEN division_by_zero THEN RETURN 'division_by_zero: ' || SQLERRM;
  WHEN SQLSTATE 'Z9999' THEN RETURN 'SQLSTATE Z9999: ' || SQLERRM;
  WHEN raise_exception THEN RETURN 'raise_exception: ' || SQLERRM;
END $d$;
SELECT err_catch('23514'), err_catch('23505'), err_catch('22012'), err_catch('Z9999'), err_catch('P0001');
-- not caught by a handler for another condition
SELECT err_catch('42P01');

-- refused classes: an error of its own, naming the code, never a substitution
SELECT c, err_show(format('SELECT err_raise(%L, %L, NULL, NULL)', c, 'm'))
  FROM unnest(ARRAY['00000', '01000', '02000', '08006', '53100', '57014', '57P01', '58030', 'F0000', 'XX000', 'XX001']) c;
-- their neighbours are allowed (not P0004, assert_failure: WHEN OTHERS does not catch it)
SELECT c, err_show(format('SELECT err_raise(%L, %L, NULL, NULL)', c, 'ok'))
  FROM unnest(ARRAY['03000', '09000', '0A000', '22000', '54000', '55000', '59000', 'F1000', 'XY000', 'P0003', 'ZZZZZ', '99999']) c;
-- malformed codes: length, case, other characters, non-ASCII (5 bytes)
SELECT c, err_show(format('SELECT err_raise(%L, %L, NULL, NULL)', c, 'm'))
  FROM unnest(ARRAY['', '2351', '235140', 'p0001', '2351a', '23 14', '23-14', '235é', 'é2351', 'P0001 ', ' P0001', '23514235142351423514']) c;
-- NUL and control bytes in the code (shown as ?)
SELECT err_show($$SELECT err_raise_b('\x3233003134'::bytea, 'm'::bytea, NULL, NULL)$$);
SELECT err_show($$SELECT err_raise_b('\x0a1b5b3331'::bytea, 'm'::bytea, NULL, NULL)$$);
-- the code is checked before anything else
SELECT err_show($$SELECT err_raise_b('XX000'::bytea, '\xff'::bytea, NULL, NULL)$$);

-- message, detail and hint: valid in the database encoding, no NUL
SELECT err_show($$SELECT err_raise_b('23514'::bytea, '\x61ff62'::bytea, NULL, NULL)$$);
SELECT err_show($$SELECT err_raise_b('23514'::bytea, 'm'::bytea, '\x6100'::bytea, NULL)$$);
SELECT err_show($$SELECT err_raise_b('23514'::bytea, 'm'::bytea, NULL, '\xc3'::bytea)$$);
SELECT err_show($$SELECT err_raise_b('23514'::bytea, '\x00'::bytea, NULL, NULL)$$);
-- multibyte text is fine
SELECT err_show($$SELECT err_raise('23514', 'grüße', 'détail', 'ヒント')$$);
-- control characters become ?, except newline and tab
SELECT err_show(format('SELECT err_raise(%L, %L, %L, %L)', '23514', E'a\x1b[31mb\rc\x7fd', E'line1\nline2\tx', E'h\x07'));

-- over-long strings are cut at 64 kB, on a character boundary
SELECT err_lens($$SELECT err_raise('23514', repeat('m', 70000), repeat('d', 65536), repeat('h', 65537))$$);
SELECT err_lens($$SELECT err_raise('23514', 'a' || repeat('é', 40000), 'a' || repeat('é', 40000), repeat('é', 40000))$$);
SELECT err_lens($$SELECT err_raise('23514', repeat('€', 30000), 'x', 'y')$$);

-- the function's instance is discarded like after any error, and the
-- backend is fine
SELECT err_fmt(3);

DROP FUNCTION err_raise(text, text, text, text), err_raise_b(bytea, bytea, bytea, bytea), err_fmt(int),
  err_show(text), err_lens(text), err_plain(), err_catch(text);
