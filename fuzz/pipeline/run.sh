#!/bin/bash
# Target "pipeline": generated and mutated PL/Zig functions
# (fuzz/pipeline/gen.pl: valid, near-valid and invalid bodies of functions
# of several families -- scalar, text, non-strict, native types, OUT
# parameters, composite argument and result, SETOF/TABLE, a row trigger, a
# procedure with transaction control, DO blocks, a function using two others
# with //#use) through CREATE FUNCTION /
# CREATE PROCEDURE / DO on the running (ASan) server, as an unprivileged
# role with USAGE, with the default sandbox (require), then a call of every
# function that compiled (the trigger through INSERT/UPDATE on its table),
# under statement_timeout.
# Oracles: fz_check after every statement (backend alive, no crash in the
# log, no sanitizer report, no leftover build directory, temp file, zombie
# or compiler process), every SQLSTATE in the expected set (anything else,
# in particular XX000, is a finding), the module cache within
# plzig.cache_size_limit.  Compiler crashes (the compiler killed by a
# signal, SQLSTATE 58000) are counted and reported, not failed: they are
# Zig bugs, contained by the sandbox.
#
# Expected SQLSTATEs.  CREATE: success, policy (42501), compile error
# (42P13), limits (54000), compile timeout (57014), encoding (22021,
# 22P05).  A call: the function's own errors (P0001 raise, 38000 panic /
# trap / returned Zig error, raise_error's 22023), statement_timeout
# (57014), an unbound $n in SQL it builds (42P02), non-UTF-8 bytes in a
# message or query it builds (22021), SQL errors of its queries and of the
# arguments it passes them (22003, 22012, 42883, 42P01, 42703, 0A000,
# 25006, 42501, 22P02), memory
# (53200, 54000, 54001) -- plus, for the families that return values the
# host checks, the errors of those checks (call_extra below), and for the
# family with //#use directives a directive moved after code by a mutation
# (42601, create_extra below).  A DO
# block compiles *and runs* its body in one statement, so its expected set
# is the union of the CREATE set and the call set: a panic in a DO block is
# a clean 38000, exactly as in a called function.
#   fuzz/pipeline/run.sh <seconds>
set -u
secs=${1:?seconds}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../common/sql-lib.sh"

fz_note "--- pipeline: seed $fz_seed, ${secs}s"
fz_psql <<'SQL' >/dev/null
DROP ROLE IF EXISTS fuzz_pipe;
CREATE ROLE fuzz_pipe LOGIN;
GRANT USAGE ON LANGUAGE plzig TO fuzz_pipe;
GRANT CREATE ON SCHEMA public TO fuzz_pipe;
ALTER ROLE fuzz_pipe SET plzig.compile_timeout = '10s';
SQL
# the objects the families use, owned by the fuzzing role (gen.pl)
out=$(psql -X -q -At -U fuzz_pipe -v ON_ERROR_STOP=1 2>&1 <<'SQL'
CREATE TYPE fz_pair AS (a int, b text);
CREATE TABLE fz_t (id int, name text, qty int NOT NULL DEFAULT 0, price numeric(8,2), code varchar(4));
CREATE TABLE fz_log (n int);
CREATE FUNCTION fz_tg() RETURNS trigger LANGUAGE plzig AS $$ return .new; $$;
CREATE TRIGGER fz_t_trg BEFORE INSERT OR UPDATE ON fz_t FOR EACH ROW EXECUTE FUNCTION fz_tg();
CREATE FUNCTION fz_h_int(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    if (x < 0) return error.Negative;
    return x +% 1;
$$;
CREATE FUNCTION fz_h_text(t text) RETURNS text LANGUAGE plzig AS $$
    const v = t orelse return null;
    return try std.fmt.allocPrint(plzig.allocator, "<{s}>", .{v});
$$;
SQL
) || { fz_finding "pipeline setup failed: $out"; }
# a smaller cache, so that eviction runs
fz_set_conf cache_size_limit 64MB
fz_reload

create_ok=" ok 42501 42P13 54000 57014 22021 22P05 "
# 42P02: an unbound $n in SQL the body builds; 22021: non-UTF-8 bytes in a
# message or query string the body builds (raise/notice/debug or SPI).  Both
# are reachable from any family, so they are global, not per-family.
call_ok=" ok P0001 38000 22023 57014 22003 22012 53200 54001 54000 42883 42P01 42703 0A000 25006 42501 22P02 22021 42P02 "
declare -A create_extra=(
    # a //#use directive moved after the first line of code
    [use]=" 42601 "
)
declare -A call_extra=(
    # results the host checks: date/timestamp range, numeric, JSON text
    # (22P05: a \u0000 escape jsonb_in does not support)
    [nat_date]=" 22008 "
    [nat_num]=" 22008 "
    [nat_json]=" 22008 22P05 "
    [nat_ts]=" 22008 "
    # OUT varchar(5): too long for the typmod
    [row]=" 22001 "
    # (22021, invalid UTF-8 from slicing a multibyte character, is in call_ok)
    # modified rows: NOT NULL (executor), varchar(4), numeric(8,2); OLD
    # returned for an INSERT (39P01, trigger protocol violated)
    [tg]=" 23502 22001 39P01 "
    # a cursor used after commit()/rollback() closed it
    [proc]=" 24000 "
)

gen=$fz_out/bodies
declare -A cstates qstates kinds_n kinds_ok fam_n fam_ok
n=0; batch=0; crashes=0
deadline=$(( $(date +%s) + secs ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    seed=$((fz_seed + batch))
    batch=$((batch + 1))
    rm -rf "$gen"; mkdir -p "$gen"
    perl "$here/gen.pl" "$seed" 50 "$here/../validator/corpus" "$gen" || { fz_finding "generator failed"; break; }
    for f in "$gen"/*.zig; do
        [ "$(date +%s)" -lt "$deadline" ] || break
        n=$((n + 1))
        meta=${f%.zig}.meta
        family=$(sed -n 's/^family=//p' "$meta")
        kind=$(sed -n 's/^kind=//p' "$meta")
        create=$(sed -n 's/^create=//p' "$meta")
        call=$(sed -n 's/^call=//p' "$meta")
        tag="fz$RANDOM$RANDOM"
        while grep -qF "\$$tag\$" "$f"; do tag="fz$RANDOM$RANDOM"; done
        if [ "$create" = DO ]; then
            sql=$(printf 'DO $%s$\n%s\n$%s$ LANGUAGE plzig;' "$tag" "$(cat "$f")" "$tag")
            ok="$create_ok${call_ok# }"
        else
            sql=$(printf '%s $%s$\n%s\n$%s$;' "$create" "$tag" "$(cat "$f")" "$tag")
            ok="$create_ok${create_extra[$family]:-}"
        fi
        out=$(printf '%s\n' "SET statement_timeout = '30s';" "\\set VERBOSITY verbose" "$sql" |
              psql -X -q -At -U fuzz_pipe 2>&1)
        st=$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"$out" | head -1)
        st=${st:-ok}
        cstates[$st]=$(( ${cstates[$st]:-0} + 1 ))
        kinds_n[$kind]=$(( ${kinds_n[$kind]:-0} + 1 ))
        fam_n[$family]=$(( ${fam_n[$family]:-0} + 1 ))
        if [ "$st" = ok ]; then
            kinds_ok[$kind]=$(( ${kinds_ok[$kind]:-0} + 1 ))
            fam_ok[$family]=$(( ${fam_ok[$family]:-0} + 1 ))
        fi
        if [ "$st" = 58000 ]; then
            crashes=$((crashes + 1)); cp "$f" "$fz_out/compiler-crash-$seed-$(basename "$f")"
        elif [[ "$ok" != *" $st "* ]]; then
            fz_finding "$create ... ended with SQLSTATE $st (batch $seed, $(basename "$f")): $(grep ERROR <<<"$out" | head -2)" \
                "replay: perl fuzz/pipeline/gen.pl $seed 50 fuzz/validator/corpus <dir>; body $(basename "$f")"
            cp "$f" "$fz_out/finding-body-$seed-$(basename "$f")"
        fi
        if [ "$st" = ok ] && [ -n "$call" ]; then
            out=$(printf '%s\n' "SET statement_timeout = '3s';" "\\set VERBOSITY verbose" "$call" |
                  psql -X -q -At -U fuzz_pipe 2>&1)
            qs=$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"$out" | head -1)
            qs=${qs:-ok}
            qstates[$qs]=$(( ${qstates[$qs]:-0} + 1 ))
            if [[ "$call_ok${call_extra[$family]:-}" != *" $qs "* ]]; then
                fz_finding "call of $family ended with SQLSTATE $qs (batch $seed, $(basename "$f")): $(grep ERROR <<<"$out" | head -2)" \
                    "replay: perl fuzz/pipeline/gen.pl $seed 50 fuzz/validator/corpus <dir>; body $(basename "$f")"
                cp "$f" "$fz_out/finding-body-$seed-$(basename "$f")"
            fi
        fi
        fz_check "pipeline batch $seed $(basename "$f")"
    done
    size=$(find "$PGDATA/plzig/cache" -maxdepth 1 -type f -name '*.wasm' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
    if [ "$size" -gt $((64 * 1024 * 1024)) ]; then
        fz_finding "module cache holds $size bytes, over plzig.cache_size_limit (64MB)"
    fi
done
rm -rf "$gen"
fz_psql -c "DROP OWNED BY fuzz_pipe; DROP ROLE fuzz_pipe;" >/dev/null
fz_set_conf cache_size_limit ""
fz_reload
fz_check "pipeline cleanup"
summary="$n bodies in $batch batches (seeds $fz_seed..$((fz_seed + batch - 1))); compiler crashes (contained): $crashes; accepted:"
for k in valid near invalid; do summary+=" $k ${kinds_ok[$k]:-0}/${kinds_n[$k]:-0}"; done
summary+="; CREATE/DO:"
for k in $(printf '%s\n' "${!cstates[@]}" | sort); do summary+=" $k=${cstates[$k]}"; done
summary+="; calls:"
for k in $(printf '%s\n' "${!qstates[@]}" | sort); do summary+=" $k=${qstates[$k]}"; done
fz_note "accepted per family:$(for k in $(printf '%s\n' "${!fam_n[@]}" | sort); do printf ' %s %s/%s' "$k" "${fam_ok[$k]:-0}" "${fam_n[$k]}"; done)"
fz_result pipeline "$summary"
