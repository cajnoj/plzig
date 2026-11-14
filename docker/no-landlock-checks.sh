#!/bin/bash
# Checks for a system without Landlock (run by test-in-container.sh when the
# container's seccomp profile blocks the Landlock syscalls):
#   - default plzig.compiler_sandbox = require refuses every compile with an
#     actionable error, while functions with cached modules keep running;
#   - try compiles unconfined and logs that once.
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }
psqlq() { psql -X -q -At -v VERBOSITY=default "$@" 2>&1; }
set_sandbox() {
    sed -i '/^plzig.compiler_sandbox/d' "$PGDATA/postgresql.conf"
    [ -n "$1" ] && echo "plzig.compiler_sandbox = '$1'" >> "$PGDATA/postgresql.conf"
    pg_ctl -D "$PGDATA" reload >/dev/null
    sleep 0.5
}
expect() {   # expect <description> <needle> <sql>
    local out
    out=$(psqlq -c "$3")
    if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1"; echo "$out" | sed 's/^/         /'; fi
}

echo "--- no-Landlock checks"
psqlq -c "CREATE EXTENSION plzig;" >/dev/null
expect "default is require" "require" "LOAD 'plzig'; SHOW plzig.compiler_sandbox;"

out=$(psqlq -c "CREATE FUNCTION nl1() RETURNS int LANGUAGE plzig AS \$\$ return 1; \$\$;")
if grep -qF "Landlock is not available, and plzig.compiler_sandbox = require" <<<"$out" &&
   grep -qF "landlock_create_ruleset returned -38" <<<"$out" &&
   grep -qF "plzig.compiler_sandbox = try" <<<"$out" &&
   grep -qF "full rights of the server's operating-system user" <<<"$out"; then
    pass "require refuses to compile without Landlock, with reason and hint"
else
    fail "require refuses to compile without Landlock, with reason and hint"; echo "$out" | sed 's/^/         /'
fi

set_sandbox try
logpos=$(wc -c </tmp/server.log)
out=$(psqlq <<'SQL'
CREATE FUNCTION nl2() RETURNS int LANGUAGE plzig AS $$ return 4711; $$;
SELECT nl2();
SELECT 'status: ' || plzig_sandbox_status();
SQL
)
if grep -qx "4711" <<<"$out"; then pass "try compiles without Landlock"; else fail "try compiles without Landlock"; echo "$out" | sed 's/^/         /'; fi
if grep -qF "status: unavailable (landlock_create_ruleset returned -38)" <<<"$out"; then pass "status reports unavailable"; else fail "status reports unavailable"; fi
if tail -c +"$((logpos + 1))" /tmp/server.log | grep -qF "Landlock is not available (landlock_create_ruleset returned -38); the compiler runs without filesystem confinement"; then
    pass "try logs the unconfined compile"
else
    fail "try logs the unconfined compile"
fi

set_sandbox ""
expect "back to require: cached module still runs" "4711" "SELECT nl2();"
expect "back to require: new compile refused" "Landlock is not available" \
    "CREATE FUNCTION nl3() RETURNS int LANGUAGE plzig AS \$\$ return 3; \$\$;"

echo "--- no-Landlock checks: $fails failure(s)"
exit $fails
