#!/bin/bash
# Runs inside the test image (as user postgres): start a throw-away cluster,
# point it at the Zig compiler (an external dependency, installed in the
# image under $PLZIG_TEST_ZIG), warm the Zig cache, run the pg_regress suite
# and the security checks, print a result line.
#
# PLZIG_NO_LANDLOCK=1: the container was started with a seccomp profile that
# blocks the Landlock syscalls; run only the checks for that situation.
# PLZIG_NO_SECCOMP=1: likewise, with a profile that makes installing a
# seccomp filter fail.
set -u

export PGDATA=/tmp/pgdata
export PGHOST=/tmp
export PGUSER=postgres
export PGDATABASE=postgres

ver=$(pg_config --version)
echo "=== $ver"

initdb -U postgres --no-locale -E UTF8 -A trust >/tmp/initdb.log 2>&1 || {
    cat /tmp/initdb.log; echo "RESULT: FAIL (initdb)"; exit 1; }
# the administrator's step: plzig.zig_path has no default
echo "plzig.zig_path = '$PLZIG_TEST_ZIG'" >> "$PGDATA/postgresql.conf"
pg_ctl -D "$PGDATA" -l /tmp/server.log -w \
    -o "-c listen_addresses='' -c unix_socket_directories=/tmp" start >/dev/null || {
    cat /tmp/server.log; echo "RESULT: FAIL (server start)"; exit 1; }

if [ "${PLZIG_NO_LANDLOCK:-0}" = 1 ]; then
    bash /src/docker/no-landlock-checks.sh
    rc=$?
    pg_ctl -D "$PGDATA" -m fast stop >/dev/null
    if [ $rc -eq 0 ]; then echo "RESULT: PASS (Landlock blocked by seccomp)"; exit 0; fi
    echo "RESULT: FAIL (no-Landlock checks: $rc failure(s))"
    exit 1
fi
if [ "${PLZIG_NO_SECCOMP:-0}" = 1 ]; then
    bash /src/docker/no-seccomp-checks.sh
    rc=$?
    pg_ctl -D "$PGDATA" -m fast stop >/dev/null
    if [ $rc -eq 0 ]; then echo "RESULT: PASS (seccomp filters blocked)"; exit 0; fi
    echo "RESULT: FAIL (no-seccomp checks: $rc failure(s))"
    exit 1
fi

# The first compile on a fresh cluster builds Zig's compiler_rt etc.
echo "--- warming the Zig cache"
start=$(date +%s)
psql -X -q -v ON_ERROR_STOP=1 <<'EOF' || { tail -50 /tmp/server.log; echo "RESULT: FAIL (warm-up)"; exit 1; }
CREATE EXTENSION plzig;
DO $$ plzig.notice("warm-up", .{}); $$ LANGUAGE plzig;
EOF
echo "--- warm-up took $(( $(date +%s) - start )) s"

sandbox=$(psql -X -At 2>&1 <<SQL | tail -1
DO \$\$ // unique body, so it is really compiled: $RANDOM$RANDOM
\$\$ LANGUAGE plzig;
SELECT plzig_sandbox_status();
SQL
)
echo "--- compiler sandbox: $sandbox"

cd /src
make installcheck >/tmp/installcheck.log 2>&1
rc=$?
grep -E "^(ok|not ok|test |     [a-z_]+ +\.\.\.)|tests (passed|failed)|# " /tmp/installcheck.log
if [ $rc -ne 0 ]; then
    echo "--- regression.diffs"
    cat regression.diffs 2>/dev/null | head -400
    echo "--- server log (tail)"
    tail -40 /tmp/server.log
fi

# shell-driven security checks (fake compilers, Landlock probe, tampering)
bash /src/docker/security-checks.sh
sec=$?

# no leftover build directories
left=$(find "$PGDATA/plzig" -maxdepth 1 -name 'pgsql_tmp.build.*' | wc -l)
echo "--- leftover build dirs: $left"

pg_ctl -D "$PGDATA" -m fast stop >/dev/null

# plzig.compiler_sandbox defaults to require, so a passing suite implies
# Landlock was enforced; check it explicitly anyway
if [[ "$sandbox" != enforced* ]]; then
    echo "RESULT: FAIL (compiler not confined: $sandbox)"
    exit 1
fi
if [ $rc -eq 0 ] && [ "$left" -eq 0 ] && [ "$sec" -eq 0 ]; then
    echo "RESULT: PASS (sandbox: $sandbox)"
    exit 0
fi
echo "RESULT: FAIL (regress rc=$rc, security check failures=$sec, leftover dirs=$left; sandbox: $sandbox)"
exit 1
