# Helpers for the SQL-driven fuzz targets (sourced by fuzz/*/run.sh).
# They run inside docker/test-in-container.sh's cluster (layer "fuzz"),
# usually the ASan build of PL/Zig (PLZIG_ASAN=1), as the cluster's
# superuser; $PGDATA, $PGHOST etc. are set by that script.

fz_out=${PLZIG_FUZZ_OUT:-/tmp/fuzz-out}
mkdir -p "$fz_out"
fz_log=$fz_out/fuzz.log
fz_findings=0

fz_note() { echo "$*" | tee -a "$fz_log"; }

# a finding: description, then a reproducer note (seed, input)
fz_finding() {
    fz_findings=$((fz_findings + 1))
    fz_note "FINDING: $1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" >>"$fz_out/finding-$fz_findings.txt"
}

fz_psql() { psql -X -q -At -v ON_ERROR_STOP=0 "$@" 2>&1; }

fz_reload() {
    pg_ctl -D "$PGDATA" reload >/dev/null
    sleep 0.5
}

fz_set_conf() {   # fz_set_conf <name> <value or empty to remove>
    sed -i "/^plzig.$1 /d" "$PGDATA/postgresql.conf"
    [ -n "$2" ] && echo "plzig.$1 = '$2'" >>"$PGDATA/postgresql.conf"
    return 0
}

fz_asan_seen=0

# server log lines seen so far (only new lines are checked)
fz_log_pos=$(wc -l </tmp/server.log 2>/dev/null || echo 0)

# Is the server healthy?  Checks: it answers, no backend was terminated by
# a signal or crashed (new server log lines), no sanitizer report, no
# leftover build directory or temp file, no zombie or compiler process.
# fz_check <context for the finding report>
fz_check() {
    local ctx=$1 out new
    out=$(psql -X -At -c "SELECT 4242" 2>&1)
    if [ "$out" != 4242 ]; then
        fz_finding "server not answering after $ctx: $out" "$ctx"
        sleep 5
    fi
    new=$(tail -n +"$((fz_log_pos + 1))" /tmp/server.log 2>/dev/null)
    fz_log_pos=$(wc -l </tmp/server.log)
    # The Zig compiler itself crashing (SIGSEGV) in its sandboxed child is
    # not a server problem: the backend reports it as an ordinary error
    # (58000), which the SQL oracles count.  Only that exact message is
    # exempt; a backend killed by a signal is reported by the postmaster
    # with a different line ("server process ... was terminated by signal").
    new=$(grep -vE 'ERROR:  PL/Zig compiler terminated by signal 11$' <<<"$new" || true)
    if grep -qE "terminated by signal|was terminated|server process .* exited with exit code [^0]|TRAP:|PANIC:|could not remove|stuck" <<<"$new"; then
        fz_finding "server log after $ctx: $(grep -E 'terminated by signal|was terminated|exited with exit code|TRAP:|PANIC:|could not remove|stuck' <<<"$new" | head -5)" "$ctx"
    fi
    # new sanitizer reports (kept in /tmp/asan, so that the container's
    # "sanitizers" layer fails too; copies go to the output directory)
    if [ -d /tmp/asan ] && [ "$(ls -A /tmp/asan 2>/dev/null | wc -l)" -gt "$fz_asan_seen" ]; then
        fz_asan_seen=$(ls -A /tmp/asan | wc -l)
        fz_finding "sanitizer report after $ctx: $(ls /tmp/asan | tail -3)" "$ctx"
        mkdir -p "$fz_out/sanitizer"
        cp -n /tmp/asan/* "$fz_out/sanitizer/" 2>/dev/null
    fi
    if [ -n "$(find "$PGDATA/plzig" -maxdepth 1 -name 'pgsql_tmp.build.*' 2>/dev/null)" ]; then
        # (the next compilation sweeps it)
        fz_finding "build directory left behind after $ctx" "$ctx"
    fi
    if [ -n "$(find "$PGDATA/plzig/cache" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)" ]; then
        fz_finding "temporary cache file left behind after $ctx" "$ctx"
    fi
    if [ "$(awk '{ if ($3 == "Z") print }' /proc/[0-9]*/stat 2>/dev/null | wc -l)" -gt 0 ]; then
        fz_finding "zombie process after $ctx" "$ctx"
    fi
    if [ "$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | grep -cE '/zig$|plzig-validate$')" -gt 0 ]; then
        fz_finding "compiler process left running after $ctx" "$ctx"
    fi
}

# a random seed for this run (printed, so a run can be repeated:
# PLZIG_FUZZ_SEED=<n>)
fz_seed=${PLZIG_FUZZ_SEED:-$(( (RANDOM << 15) | RANDOM ))}

fz_result() {   # fz_result <target> <summary>
    if [ "$fz_findings" -eq 0 ]; then
        fz_note "FUZZ $1: PASS ($2)"
        return 0
    fi
    fz_note "FUZZ $1: FAIL ($fz_findings finding(s); $2; see $fz_out)"
    return 1
}
