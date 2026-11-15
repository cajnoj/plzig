#!/bin/bash
# Target "marshal": property tests of argument/result marshalling and of the
# source generator, against the running (ASan) server.
#
#  1. round trips: random values of every type class (fuzz/marshal/setup.sql:
#     scalars with their edge values, text with random code points up to
#     U+10FFFF, bytea with NUL bytes, numeric/float specials, arrays,
#     ranges, enums, domains, composites, json, ...) through non-strict
#     identity functions, directly and from a table where they are stored
#     compressed and out of line (detoasting); the text form must come back
#     unchanged, and no call may fail;
#  2. NULL patterns: all 256 NULL patterns of an 8-argument function of
#     mixed classes must be seen exactly by the guest;
#  3. source generator: random signatures -- parameter names from a
#     hostile alphabet (quotes, spaces, '@', '$', backslashes, non-ASCII,
#     keywords, the reserved plzig/std/call, argN clashes, 63-byte names),
#     random parameter and result types including pseudo types, argument
#     modes (OUT/INOUT: struct results), SETOF, up to 100 parameters -- created with
#     check_function_bodies = off: the validator must accept exactly the
#     signatures the rules allow (doc/abi.md), and a sample of the accepted
#     ones must then compile and run (the generated user.zig is well formed
#     for any accepted name).
# Rounds repeat with new seeds until the time budget is used.
#   fuzz/marshal/run.sh <seconds>
set -u
secs=${1:?seconds}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../common/sql-lib.sh"

fz_note "--- marshal: seed $fz_seed, ${secs}s"
fz_psql -c "DROP DATABASE IF EXISTS fuzz_marshal" >/dev/null
fz_psql -c "CREATE DATABASE fuzz_marshal" >/dev/null
export PGDATABASE=fuzz_marshal
out=$(fz_psql -c "CREATE EXTENSION plzig" -f "$here/setup.sql")
if grep -q ERROR <<<"$out"; then
    echo "$out"; fz_finding "setup failed"; fz_result marshal "setup failed"; exit 1
fi
fz_check "marshal setup"

values=0; stored=0; sigs=0; accepted=0; compiled=0; rounds=0
deadline=$(( $(date +%s) + secs ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    seed=$((fz_seed + rounds))
    rounds=$((rounds + 1))
    out=$(fz_psql -v seed="$seed" <<'SQL'
SET statement_timeout = '300s';
SELECT setseed(:seed::float8 / 2147483648 - floor(:seed::float8 / 2147483648));
-- 1. round trips, per type
DO $$
DECLARE
    r record;
    v text;
    total int := 0;
BEGIN
    FOR r IN SELECT t, format_type(t, NULL) AS name,
                    'fz_id_' || regexp_replace(format_type(t, NULL), '[^a-z0-9]+', '_', 'g') AS fn
               FROM fz_types ORDER BY 1 LOOP
        BEGIN
            EXECUTE format('SELECT v FROM (SELECT fz_rand_value(%L) AS v FROM generate_series(1, 40)) s
                             WHERE %I(v::%s)::text IS DISTINCT FROM v::%s::text LIMIT 1',
                           r.t, r.fn, r.name, r.name) INTO v;
            IF v IS NOT NULL THEN
                RAISE NOTICE 'MISMATCH % value %', r.name, left(v, 300);
            END IF;
            total := total + 40;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAILED % %', r.name, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'VALUES %', total;
END $$;
-- 1a. the guest's jsonb serialisation is jsonb_out's text, character for character
DO $$
DECLARE v jsonb; bad text;
BEGIN
    SELECT j::text INTO bad FROM (SELECT fz_rand_jsonb(5) AS j FROM generate_series(1, 60)) s
     WHERE fz_jsonb_text(j) IS DISTINCT FROM j::text LIMIT 1;
    IF bad IS NOT NULL THEN
        RAISE NOTICE 'MISMATCH jsonb text %', left(bad, 300);
    END IF;
END $$;
-- 1b. stored values: compressed and out of line
DROP TABLE IF EXISTS fz_store;
CREATE TABLE fz_store (id int, t text, tc text, b bytea, j jsonb, a text[]);
ALTER TABLE fz_store ALTER t SET STORAGE EXTERNAL, ALTER b SET STORAGE EXTERNAL;
INSERT INTO fz_store
SELECT i, fz_rand_text(3000 + i * 50), repeat(fz_rand_text(20), 500),
       decode(repeat(md5(random()::text), 200 + i), 'hex'), fz_rand_value('jsonb')::jsonb,
       ARRAY[repeat(fz_rand_text(5), 1000), NULL, '']
  FROM generate_series(1, 20) i;
SELECT 'STORED ' || count(*) || ' BAD ' ||
       count(*) FILTER (WHERE fz_id_text(t) IS DISTINCT FROM t OR fz_id_text(tc) IS DISTINCT FROM tc
                           OR fz_id_bytea(b) IS DISTINCT FROM b OR fz_id_jsonb(j) IS DISTINCT FROM j
                           OR fz_jsonb_text(j) IS DISTINCT FROM j::text
                           OR fz_id_text_(a) IS DISTINCT FROM a)
  FROM fz_store;
-- 2. NULL patterns
SELECT 'NULLMASK BAD ' || count(*) FROM generate_series(0, 255) m
 WHERE fz_nullmask(CASE WHEN m & 1 = 0 THEN 1 END, CASE WHEN m & 2 = 0 THEN 'x' END,
                   CASE WHEN m & 4 = 0 THEN 1.5 END, CASE WHEN m & 8 = 0 THEN '\x00'::bytea END,
                   CASE WHEN m & 16 = 0 THEN 2.5 END, CASE WHEN m & 32 = 0 THEN true END,
                   CASE WHEN m & 64 = 0 THEN 7 END, CASE WHEN m & 128 = 0 THEN current_date END)
       IS DISTINCT FROM m;
-- 3. source generator
SET check_function_bodies = off;
DO $$
DECLARE
    alphabet text[] := ARRAY['a', 'Z', '_', '0', '9', 'x', 'é', ' ', '"', '''', '$', '@', '\', '-', '.', 'ß', chr(128512), '{', '}', ';', chr(9)];
    special text[] := ARRAY['plzig', 'std', 'call', 'arg1', 'arg2', 'return', 'fn', 'comptime', 'anyerror',
                            'usingnamespace', '_', 'a_', 'A', 'x' || repeat('y', 62), 'x' || repeat('y', 80), 'pub', 'u8', 'undefined',
                            'Result', 'column1', 'column2'];
    goodtypes text[] := ARRAY['int', 'int2', 'int8', 'bool', 'float4', 'float8', 'text', 'varchar(3)', 'char(2)', 'bytea',
                              'numeric', 'date', 'jsonb', 'int[]', 'fz_mood', 'fz_posint', 'fz_pair', 'uuid', 'name', 'regclass'];
    badtypes text[] := ARRAY['anyelement', 'anyarray', 'internal', 'cstring', 'record', 'anyrange', 'anycompatible', 'trigger', 'void', 'unknown'];
    i int; k int; n int;
    names text[]; types text[]; modes text[];
    sig text; nm text; ty text; md text; ret text; setof bool; proc bool;
    expect_ok bool; got_ok bool; msg text; st text;
    nsig int := 0; nacc int := 0; ncomp int := 0;
    effective text[];
    -- output parameters (doc/abi.md, "Rows"): the fields of the result
    outnames text[]; outexplicit text[]; outbad bool; outtype text; nin int; nout int; rowres bool;
BEGIN
    FOR i IN 1..60 LOOP
        n := CASE WHEN random() < 0.05 THEN 90 + floor(random() * 11)::int ELSE floor(random() * 6)::int END;
        names := '{}'; types := '{}'; modes := '{}'; effective := '{}';
        outnames := '{}'; outexplicit := '{}'; outbad := false; outtype := NULL; nin := 0; nout := 0;
        expect_ok := true;
        sig := '';
        FOR k IN 1..n LOOP
            nm := CASE
                WHEN random() < 0.2 THEN NULL     -- unnamed
                WHEN random() < 0.3 THEN special[1 + floor(random() * array_length(special, 1))::int]
                ELSE (SELECT string_agg(alphabet[1 + floor(random() * (CASE WHEN random() < 0.7 THEN 6 ELSE array_length(alphabet, 1) END))::int], '')
                        FROM generate_series(1, 1 + floor(random() * 8)::int)) END;
            -- PostgreSQL truncates identifiers to 63 bytes
            WHILE octet_length(nm) > 63 LOOP
                nm := left(nm, -1);
            END LOOP;
            IF random() < 0.08 THEN ty := badtypes[1 + floor(random() * array_length(badtypes, 1))::int];
            ELSE ty := goodtypes[1 + floor(random() * array_length(goodtypes, 1))::int]; END IF;
            md := CASE WHEN random() < 0.05 THEN (ARRAY['OUT', 'INOUT', 'VARIADIC'])[1 + floor(random() * 3)::int] ELSE 'IN' END;
            names := names || nm; types := types || ty; modes := modes || md;
            sig := sig || CASE WHEN k > 1 THEN ', ' ELSE '' END || md || ' ' ||
                   CASE WHEN nm IS NULL THEN '' ELSE quote_ident(nm) || ' ' END || ty;
            IF md = 'VARIADIC' OR ty = ANY (badtypes) THEN expect_ok := false; END IF;
            -- inputs (IN, INOUT, VARIADIC) are parameters: argN counts inputs only
            IF md IN ('IN', 'INOUT', 'VARIADIC') THEN
                nin := nin + 1;
                effective := effective || coalesce(nm, 'arg' || nin);
                IF nm IS NOT NULL AND (nm !~ '^[A-Za-z_][A-Za-z0-9_]*$' OR nm IN ('plzig', 'std', 'call')) THEN
                    expect_ok := false;
                END IF;
            END IF;
            -- outputs (OUT, INOUT) are the fields of a row result: columnN counts
            -- outputs; their names matter only when there is a struct (below)
            IF md IN ('OUT', 'INOUT') THEN
                nout := nout + 1;
                outnames := outnames || coalesce(nm, 'column' || nout);
                IF nm IS NOT NULL THEN outexplicit := outexplicit || nm; END IF;
                outtype := ty;
                IF nm IS NOT NULL AND nm !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN outbad := true; END IF;
            END IF;
        END LOOP;
        IF (SELECT count(*) <> count(DISTINCT x) FROM unnest(effective) x) THEN expect_ok := false; END IF;
        -- PostgreSQL refuses duplicate output names itself
        IF (SELECT count(*) <> count(DISTINCT x) FROM unnest(outexplicit) x) THEN expect_ok := false; END IF;
        proc := random() < 0.1;
        setof := NOT proc AND nout = 0 AND random() < 0.05;
        ret := CASE WHEN random() < 0.1 THEN badtypes[1 + floor(random() * array_length(badtypes, 1))::int]
                    ELSE goodtypes[1 + floor(random() * array_length(goodtypes, 1))::int] END;
        -- a function with output parameters gets no RETURNS clause (PostgreSQL derives it)
        IF setof OR (NOT proc AND nout = 0 AND ret = ANY (badtypes) AND ret <> 'void') THEN expect_ok := false; END IF;
        -- a row result (struct) declares Result
        rowres := (proc AND nout > 0) OR (NOT proc AND (nout >= 2 OR (nout = 1 AND outtype = 'fz_pair')
                                                        OR (nout = 0 AND ret = 'fz_pair')));
        IF rowres AND 'Result' = ANY (effective) THEN expect_ok := false; END IF;
        -- a struct made of the outputs: identifiers, unique also with the
        -- made-up columnN names (one composite output: its type's fields)
        IF ((proc AND nout > 0) OR (NOT proc AND nout >= 2)) AND (outbad OR (SELECT count(*) <> count(DISTINCT x) FROM unnest(outnames) x)) THEN
            expect_ok := false;
        END IF;
        nsig := nsig + 1;
        BEGIN
            EXECUTE 'DROP ROUTINE IF EXISTS fz_sig';
            IF proc THEN
                EXECUTE format('CREATE PROCEDURE fz_sig(%s) LANGUAGE plzig AS $b$ %s $b$', sig,
                               CASE WHEN nout > 0 THEN 'return std.mem.zeroes(Result);' ELSE 'return;' END);
            ELSIF nout > 0 THEN
                EXECUTE format('CREATE FUNCTION fz_sig(%s) LANGUAGE plzig AS $b$ return null; $b$', sig);
            ELSE
                EXECUTE format('CREATE FUNCTION fz_sig(%s) RETURNS %s%s LANGUAGE plzig AS $b$ %s $b$',
                               sig, CASE WHEN setof THEN 'SETOF ' ELSE '' END, ret,
                               CASE WHEN ret = 'void' THEN 'return;' ELSE 'return null;' END);
            END IF;
            got_ok := true;
        EXCEPTION WHEN OTHERS THEN
            got_ok := false;
            GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, msg = MESSAGE_TEXT;
        END;
        IF got_ok AND NOT expect_ok THEN
            RAISE NOTICE 'SIGBAD accepted: (%) returns %', sig, ret;
        ELSIF NOT got_ok AND expect_ok THEN
            RAISE NOTICE 'SIGBAD rejected: (%) returns %: % %', sig, ret, st, msg;
        ELSIF NOT got_ok AND st = 'XX000' THEN
            RAISE NOTICE 'SIGBAD internal error: (%) returns %: %', sig, ret, msg;
        END IF;
        IF got_ok THEN
            nacc := nacc + 1;
            -- every 4th accepted signature: compile and call it with NULLs
            IF nacc % 4 = 1 THEN
                BEGIN
                    IF proc THEN
                        EXECUTE format('CALL fz_sig(%s)', (SELECT coalesce(string_agg('NULL', ', '), '') FROM generate_series(1, n)));
                    ELSE
                        -- a function takes its inputs only
                        EXECUTE format('SELECT fz_sig(%s)', (SELECT coalesce(string_agg('NULL', ', '), '') FROM generate_series(1, nin)));
                    END IF;
                    ncomp := ncomp + 1;
                EXCEPTION WHEN OTHERS THEN
                    GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT, st = RETURNED_SQLSTATE;
                    RAISE NOTICE 'SIGBAD accepted but does not compile/run: (%) returns %: % %', sig, ret, st, left(msg, 300);
                END;
            END IF;
        END IF;
    END LOOP;
    RAISE NOTICE 'SIGS % ACCEPTED % COMPILED %', nsig, nacc, ncomp;
END $$;
SQL
)
    v=$(sed -n 's/.*NOTICE:  VALUES //p' <<<"$out" | tail -1); values=$((values + ${v:-0}))
    s=$(sed -n 's/^STORED \([0-9]*\) BAD .*/\1/p' <<<"$out"); stored=$((stored + ${s:-0}))
    read -r a b c < <(sed -n 's/.*NOTICE:  SIGS \([0-9]*\) ACCEPTED \([0-9]*\) COMPILED \([0-9]*\)/\1 \2 \3/p' <<<"$out")
    sigs=$((sigs + ${a:-0})); accepted=$((accepted + ${b:-0})); compiled=$((compiled + ${c:-0}))
    if grep -qE 'NOTICE:  (MISMATCH|FAILED|SIGBAD)' <<<"$out"; then
        fz_finding "round $seed: $(grep -E 'NOTICE:  (MISMATCH|FAILED|SIGBAD)' <<<"$out" | head -3)" \
            "replay: PLZIG_FUZZ_SEED=$seed; $(grep -E 'NOTICE:  (MISMATCH|FAILED|SIGBAD)' <<<"$out")"
    fi
    if ! grep -q "^STORED 20 BAD 0$" <<<"$out"; then
        fz_finding "round $seed: stored values: $(grep -E '^STORED|ERROR' <<<"$out" | head -3)" "replay: PLZIG_FUZZ_SEED=$seed"
    fi
    if ! grep -q "^NULLMASK BAD 0$" <<<"$out"; then
        fz_finding "round $seed: NULL patterns: $(grep -E '^NULLMASK|ERROR' <<<"$out" | head -3)" "replay: PLZIG_FUZZ_SEED=$seed"
    fi
    if grep -q "^ERROR" <<<"$out"; then
        fz_finding "round $seed: $(grep '^ERROR' <<<"$out" | head -3)" "replay: PLZIG_FUZZ_SEED=$seed"
    fi
    fz_check "marshal round $seed"
done
export PGDATABASE=postgres
fz_psql -c "DROP DATABASE fuzz_marshal" >/dev/null
fz_result marshal "$rounds rounds (seeds $fz_seed..$((fz_seed + rounds - 1))): $values random values and $stored stored (toasted) rows round-tripped, 256 NULL patterns per round, $sigs random signatures ($accepted accepted, $compiled compiled and called)"
