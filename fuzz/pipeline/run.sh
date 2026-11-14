#!/bin/bash
# Target "pipeline": generated and mutated Zig bodies (fuzz/pipeline/gen.pl)
# through CREATE FUNCTION (and some DO blocks) on the running (ASan) server,
# as an unprivileged role with USAGE, with the default sandbox (require),
# then a call of every function that compiled, under statement_timeout.
# Oracles: fz_check after every statement (backend alive, no crash in the
# log, no sanitizer report, no leftover build directory, temp file, zombie
# or compiler process), every SQLSTATE in the expected set (anything else,
# in particular XX000, is a finding), the module cache within
# plzig.cache_size_limit.  Compiler crashes (the compiler killed by a
# signal, SQLSTATE 58000) are counted and reported, not failed: they are
# Zig bugs, contained by the sandbox.
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
# a smaller cache, so that eviction runs
fz_set_conf cache_size_limit 64MB
fz_reload

gen=$fz_out/bodies
declare -A cstates qstates
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
        tag="fz$RANDOM$RANDOM"
        while grep -qF "\$$tag\$" "$f"; do tag="fz$RANDOM$RANDOM"; done
        if [ $((n % 10)) = 0 ]; then
            # a DO block (never cached)
            sql=$(printf 'DO $%s$ %s $%s$ LANGUAGE plzig;' "$tag" "$(cat "$f")" "$tag")
            call=""
        else
            sql=$(printf 'CREATE OR REPLACE FUNCTION fz_p(a int) RETURNS int STRICT LANGUAGE plzig AS $%s$\n%s\n$%s$;' "$tag" "$(cat "$f")" "$tag")
            call="SELECT fz_p(3);"
        fi
        out=$(printf '%s\n' "SET statement_timeout = '30s';" "\\set VERBOSITY verbose" "$sql" |
              psql -X -q -At -U fuzz_pipe 2>&1)
        st=$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"$out" | head -1)
        st=${st:-ok}
        cstates[$st]=$(( ${cstates[$st]:-0} + 1 ))
        case $st in
            ok|42501|42P13|54000|57014|22021|22P05) ;;
            58000) crashes=$((crashes + 1)); cp "$f" "$fz_out/compiler-crash-$seed-$(basename "$f")" ;;
            *) fz_finding "CREATE/DO ended with SQLSTATE $st (batch $seed, $(basename "$f")): $(grep ERROR <<<"$out" | head -2)" \
                   "replay: perl fuzz/pipeline/gen.pl $seed 50 fuzz/validator/corpus <dir>; body $(basename "$f")"
               cp "$f" "$fz_out/finding-body-$seed-$(basename "$f")" ;;
        esac
        if [ "$st" = ok ] && [ -n "$call" ]; then
            out=$(printf '%s\n' "SET statement_timeout = '3s';" "\\set VERBOSITY verbose" "$call" |
                  psql -X -q -At -U fuzz_pipe 2>&1)
            qs=$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"$out" | head -1)
            qs=${qs:-ok}
            qstates[$qs]=$(( ${qstates[$qs]:-0} + 1 ))
            case $qs in
                ok|P0001|38000|57014|22003|22012|53200|54001|54000|42883|42P01|42703|0A000|25006|42501|22P02) ;;
                *) fz_finding "call ended with SQLSTATE $qs (batch $seed, $(basename "$f")): $(grep ERROR <<<"$out" | head -2)" \
                       "replay: perl fuzz/pipeline/gen.pl $seed 50 fuzz/validator/corpus <dir>; body $(basename "$f")"
                   cp "$f" "$fz_out/finding-body-$seed-$(basename "$f")" ;;
            esac
        fi
        fz_check "pipeline batch $seed $(basename "$f")"
    done
    size=$(find "$PGDATA/plzig/cache" -maxdepth 1 -type f -name '*.wasm' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
    if [ "$size" -gt $((64 * 1024 * 1024)) ]; then
        fz_finding "module cache holds $size bytes, over plzig.cache_size_limit (64MB)"
    fi
done
rm -rf "$gen"
fz_psql -c "DROP FUNCTION IF EXISTS fz_p(int); DROP OWNED BY fuzz_pipe; DROP ROLE fuzz_pipe;" >/dev/null
fz_set_conf cache_size_limit ""
fz_reload
fz_check "pipeline cleanup"
summary="$n bodies in $batch batches (seeds $fz_seed..$((fz_seed + batch - 1))); compiler crashes (contained): $crashes; CREATE/DO:"
for k in $(printf '%s\n' "${!cstates[@]}" | sort); do summary+=" $k=${cstates[$k]}"; done
summary+="; calls:"
for k in $(printf '%s\n' "${!qstates[@]}" | sort); do summary+=" $k=${qstates[$k]}"; done
fz_result pipeline "$summary"
