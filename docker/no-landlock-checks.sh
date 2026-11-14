#!/bin/bash
# Checks for a system without Landlock (run by test-in-container.sh when the
# container's seccomp profile blocks the Landlock syscalls):
#   - default plzig.compiler_sandbox = require refuses every compile with an
#     actionable error naming what is missing, while functions with cached
#     modules keep running;
#   - try compiles with what is available (the seccomp filter) and logs once
#     exactly what is missing.
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
   grep -qF "Missing: Landlock is not available (landlock_create_ruleset returned -38): no filesystem confinement." <<<"$out" &&
   grep -qF "plzig.compiler_sandbox = try" <<<"$out" &&
   grep -qF "every file the server's operating-system user can" <<<"$out"; then
    pass "require refuses to compile without Landlock, with what is missing and a hint"
else
    fail "require refuses to compile without Landlock, with what is missing and a hint"; echo "$out" | sed 's/^/         /'
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
if grep -qF "status: partial (no landlock, seccomp; missing: Landlock is not available (landlock_create_ruleset returned -38)" <<<"$out"; then
    pass "status: seccomp only, Landlock missing"
else
    fail "status: seccomp only, Landlock missing"; echo "$out" | sed 's/^/         /'
fi
log=$(tail -c +"$((logpos + 1))" /tmp/server.log)
if grep -qF "the compiler sandbox is incomplete, compiling anyway because plzig.compiler_sandbox = try; missing: Landlock is not available (landlock_create_ruleset returned -38): no filesystem confinement" <<<"$log"; then
    pass "try logs what is missing"
else
    fail "try logs what is missing"; grep -F "PL/Zig" <<<"$log" | sed 's/^/         /'
fi
psqlq -c "CREATE FUNCTION nl4() RETURNS int LANGUAGE plzig AS \$\$ return 4; \$\$;" >/dev/null
n=$(tail -c +"$((logpos + 1))" /tmp/server.log | grep -c "the compiler sandbox is incomplete")
if [ "$n" -eq 2 ]; then pass "logged once per backend (two sessions, two lines)"; else fail "logged once per backend ($n lines)"; fi

set_sandbox ""
expect "back to require: cached module still runs" "4711" "SELECT nl2();"
expect "back to require: new compile refused" "Landlock is not available" \
    "CREATE FUNCTION nl3() RETURNS int LANGUAGE plzig AS \$\$ return 3; \$\$;"

echo "--- no-Landlock checks: $fails failure(s)"
exit $fails
