#!/bin/bash
# Target "hostabi": random host-import call sequences against the running
# (ASan) server.  fuzz/hostabi/driver.zig, compiled through the hostile
# compiler wrapper (docker/fake/hostilezig.c, unconfined, like the hostile
# guest of docker/security-checks.sh), interprets a bytea "script" as a
# sequence of host-import calls with forged pointers, lengths, row/column
# numbers, handles, kinds and values, memory growth and nested calls.
# Batches of random scripts (from setseed, so a batch can be replayed) run
# in PL/pgSQL loops, one subtransaction per call, as an unprivileged role.
# Oracles (fuzz/common/sql-lib.sh, fz_check): no backend crash, no
# sanitizer report, no zombie; plus no internal error (XX000), no prepared
# statement surviving its instance, and bounded backend memory.
#   fuzz/hostabi/run.sh <seconds>
set -u
secs=${1:?seconds}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../common/sql-lib.sh"

fz_note "--- hostabi: seed $fz_seed, ${secs}s"
hostile=/tmp/plzig-fuzz-hostile
mkdir -p "$hostile"
gcc -O2 -static -DREAL_ZIG="\"$PLZIG_TEST_ZIG\"" -o "$hostile/zig" /src/docker/fake/hostilezig.c || exit 1

fz_psql <<'SQL' >/dev/null
DROP ROLE IF EXISTS fuzz_hostabi_user;
CREATE ROLE fuzz_hostabi_user;
CREATE TABLE IF NOT EXISTS fuzz_hostabi_t (n int);
CREATE TABLE IF NOT EXISTS fuzz_hostabi_secret (s text);
GRANT SELECT, INSERT, UPDATE, DELETE ON fuzz_hostabi_t TO fuzz_hostabi_user;
REVOKE ALL ON fuzz_hostabi_secret FROM PUBLIC;
SQL

# compile the driver with the hostile wrapper (sandbox off for this only)
fz_set_conf compiler_sandbox off
fz_set_conf zig_path "$hostile/zig"
fz_set_conf zig_lib_dir "$(dirname "$PLZIG_TEST_ZIG")/lib"
fz_reload
{
    echo 'CREATE OR REPLACE FUNCTION fuzz_hostabi(script bytea) RETURNS int STRICT VOLATILE LANGUAGE plzig AS $fzdriver$'
    cat "$here/driver.zig"
    echo '$fzdriver$;'
    echo 'GRANT EXECUTE ON FUNCTION fuzz_hostabi(bytea) TO fuzz_hostabi_user;'
} >/tmp/fuzz-hostabi-create.sql
out=$(fz_psql -f /tmp/fuzz-hostabi-create.sql)
fz_set_conf compiler_sandbox ""
fz_set_conf zig_path "$PLZIG_TEST_ZIG"
fz_set_conf zig_lib_dir ""
fz_reload
if grep -q ERROR <<<"$out"; then
    echo "$out"
    fz_finding "could not create the driver function"
    fz_result hostabi "setup failed"
    exit 1
fi

declare -A states
calls=0
batches=0
deadline=$(( $(date +%s) + secs ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    seed=$((fz_seed + batches))
    batches=$((batches + 1))
    # 300 random scripts of 1..400 bytes; outcome per SQLSTATE; then, as
    # superuser in the same session: drop the idle instance and check that
    # none of its prepared statements and no unbounded memory remain
    out=$(fz_psql -v seed="$seed" <<'SQL'
SET statement_timeout = '120s';
SET ROLE fuzz_hostabi_user;
SELECT setseed(:seed::float8 / 2147483648 - floor(:seed::float8 / 2147483648));
DO $$
DECLARE
    s bytea;
    st text;
    m text;
    i int;
    res jsonb := '{}';
    msgs jsonb := '{}';
BEGIN
    FOR i IN 1..300 LOOP
        SELECT decode(string_agg(lpad(to_hex(least(255, floor(random() * 256)::int)), 2, '0'), ''), 'hex')
          INTO s FROM generate_series(1, 1 + floor(random() * 400)::int);
        BEGIN
            PERFORM fuzz_hostabi(s);
            st := 'ok';
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE;
            IF st = 'XX000' THEN
                RAISE NOTICE 'XX000 % script %', SQLERRM, encode(s, 'hex');
            END IF;
            m := st || ' ' || regexp_replace(left(SQLERRM, 70), '[0-9]+', 'N', 'g');
            msgs := jsonb_set(msgs, ARRAY[m], to_jsonb(coalesce((msgs ->> m)::int, 0) + 1));
        END;
        res := jsonb_set(res, ARRAY[st], to_jsonb(coalesce((res ->> st)::int, 0) + 1));
    END LOOP;
    RAISE NOTICE 'STATES %', res;
    RAISE NOTICE 'MESSAGES %', msgs;
END $$;
RESET ROLE;
SET plzig.instance_cache_size = 0;
SELECT fuzz_hostabi(''::bytea);
SELECT 'PLANS ' || count(*) FROM pg_backend_memory_contexts WHERE ident LIKE '%fuzzq%';
SELECT 'MEM ' || coalesce(sum(total_bytes), 0) FROM pg_backend_memory_contexts WHERE name LIKE 'PL/Zig%';
SQL
)
    states_json=$(sed -n 's/.*NOTICE:  STATES //p' <<<"$out" | tail -1)
    n=$(grep -oE '"[0-9A-Za-z]+": [0-9]+' <<<"$states_json" | awk -F': ' '{ s += $2 } END { print s + 0 }')
    calls=$((calls + n))
    while read -r kv; do
        k=$(sed -E 's/"([^"]+)": .*/\1/' <<<"$kv"); c=${kv##*: }
        states[$k]=$(( ${states[$k]:-0} + c ))
    done < <(grep -oE '"[0-9A-Za-z]+": [0-9]+' <<<"$states_json")
    sed -n 's/.*NOTICE:  MESSAGES //p' <<<"$out" | tail -1 >>"$fz_out/messages.jsonl"
    if [ "$n" -lt 300 ]; then
        fz_finding "batch $seed did not complete ($n of 300 calls): $(grep -E 'ERROR|FATAL|terminated' <<<"$out" | head -3)" "replay: PLZIG_FUZZ_SEED=$seed, first batch"
    fi
    if grep -q "NOTICE:  XX000" <<<"$out"; then
        fz_finding "internal error (XX000) in batch $seed" "$(grep 'NOTICE:  XX000' <<<"$out" | head -3)"
    fi
    plans=$(sed -n 's/^PLANS //p' <<<"$out")
    if [ "${plans:-x}" != 0 ]; then
        fz_finding "prepared statements survived their instance in batch $seed (${plans:-?})" "replay: PLZIG_FUZZ_SEED=$seed"
    fi
    mem=$(sed -n 's/^MEM //p' <<<"$out")
    if [ "${mem:-0}" -gt $((256 * 1024 * 1024)) ]; then
        fz_finding "PL/Zig memory contexts hold $mem bytes after batch $seed" "replay: PLZIG_FUZZ_SEED=$seed"
    fi
    fz_check "hostabi batch $seed"
done

# the most frequent error messages (digits replaced by N)
if [ -s "$fz_out/messages.jsonl" ]; then
    grep -oE '"[^"]+": [0-9]+' "$fz_out/messages.jsonl" |
        awk -F'": ' '{ c[$1] += $2 } END { for (k in c) printf "%8d %s\n", c[k], substr(k, 2) }' |
        sort -rn | head -40 >"$fz_out/messages-top.txt"
    fz_note "most frequent errors:"
    sed 's/^/    /' "$fz_out/messages-top.txt" | head -15 | tee -a "$fz_log"
fi
summary="$calls calls in $batches batches of 300 random scripts, seeds $fz_seed..$((fz_seed + batches - 1)); outcomes:"
for k in $(printf '%s\n' "${!states[@]}" | sort); do summary+=" $k=${states[$k]}"; done
fz_psql -c "DROP FUNCTION fuzz_hostabi(bytea); DROP TABLE fuzz_hostabi_t, fuzz_hostabi_secret; DROP ROLE fuzz_hostabi_user;" >/dev/null
fz_check "hostabi cleanup"
fz_result hostabi "$summary"
