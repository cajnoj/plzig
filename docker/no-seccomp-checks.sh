#!/bin/bash
# Checks for a system where the seccomp filter cannot be installed but
# Landlock works (run by test-in-container.sh when the container's seccomp
# profile makes prctl(PR_SET_SECCOMP) fail):
#   - default plzig.compiler_sandbox = require refuses every compile, naming
#     the missing seccomp filter;
#   - try compiles under Landlock alone and logs what is missing;
#   - the fake-compiler probe then shows what Landlock by itself enforces
#     (pathname UNIX sockets from ABI 9, UDP from ABI 10, TCP from ABI 4,
#     signals and ptrace) and what only the seccomp filter blocks (creating
#     sockets, setsid, SysV IPC).
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }
psqlq() { psql -X -q -At -v VERBOSITY=default "$@" 2>&1; }
set_conf() {   # set_conf <name> <value or empty to remove>
    sed -i "/^plzig.$1 /d" "$PGDATA/postgresql.conf"
    [ -n "$2" ] && echo "plzig.$1 = '$2'" >> "$PGDATA/postgresql.conf"
    pg_ctl -D "$PGDATA" reload >/dev/null
    sleep 0.5
}

echo "--- no-seccomp checks"
psqlq -c "CREATE EXTENSION plzig;" >/dev/null
out=$(psqlq -c "CREATE FUNCTION ns1() RETURNS int LANGUAGE plzig AS \$\$ return 1; \$\$;")
if grep -qF "the seccomp filter is not available, and plzig.compiler_sandbox = require" <<<"$out" &&
   grep -qF "no seccomp filter (the kernel refused filter mode: Invalid argument)" <<<"$out" &&
   grep -qF "plzig.compiler_sandbox = try" <<<"$out"; then
    pass "require refuses to compile without the seccomp filter"
else
    fail "require refuses to compile without the seccomp filter"; echo "$out" | sed 's/^/         /'
fi

set_conf compiler_sandbox try
logpos=$(wc -c </tmp/server.log)
out=$(psqlq <<'SQL'
CREATE FUNCTION ns2() RETURNS int LANGUAGE plzig AS $$ return 4712; $$;
SELECT ns2();
SELECT 'status: ' || plzig_sandbox_status();
SQL
)
status=$(sed -n 's/^status: //p' <<<"$out")
abi=$(sed -n 's/.*landlock ABI \([0-9]*\).*/\1/p' <<<"$status")
if grep -qx "4712" <<<"$out"; then pass "try compiles under Landlock alone"; else fail "try compiles under Landlock alone"; echo "$out" | sed 's/^/         /'; fi
if [[ "$status" == "partial (landlock ABI $abi, no seccomp; missing: "*"no seccomp filter (the kernel refused filter mode: Invalid argument)); Zig $(sh /src/third_party/zig-version.sh /src/Makefile)" ]]; then
    pass "status: Landlock only, seccomp missing ($status)"
else
    fail "status: Landlock only, seccomp missing ($status)"
fi
if tail -c +"$((logpos + 1))" /tmp/server.log | grep -qF "compiling anyway because plzig.compiler_sandbox = try; missing: " ; then
    pass "try logs what is missing"
else
    fail "try logs what is missing"
fi

# the probe under Landlock alone
fakedir=/tmp/plzig-fake
mkdir -p "$fakedir/m5" "$fakedir/lib/std"
echo "// fake" > "$fakedir/lib/std/std.zig"
gcc -O2 -static -DMODE=5 -DFAKE_VERSION="\"$(sh /src/third_party/zig-version.sh /src/Makefile)\"" \
    -DPGDATA="\"$PGDATA\"" -DPGSOCK="\"$PGHOST/.s.PGSQL.5432\"" \
    -o "$fakedir/m5/zig" /src/docker/fake/fakezig.c || exit 1
set_conf zig_path "$fakedir/m5/zig"
set_conf zig_lib_dir "$fakedir/lib"
out=$(psqlq -c "CREATE FUNCTION ns_probe() RETURNS int LANGUAGE plzig AS \$\$ return $RANDOM; \$\$;")
echo "$out" | grep -E "tcp|udp|unix|socket|signal|ptrace|shmget|setsid|setpgid|symlink|passwd" | sed 's/^/         /'
check() { if grep -qF "$1" <<<"$out"; then pass "landlock only: $1"; else fail "landlock only: $1"; fi; }
check "open /etc/passwd: Permission denied"
check "symlink in build dir: Permission denied"
check "signal parent: Operation not permitted"
check "ptrace attach parent: Operation not permitted"
check "inet socket: ALLOWED"
check "unix socket: ALLOWED"
# what only the seccomp filter prevents
check "setsid in child: ALLOWED"
check "shmget: ALLOWED"
if [ "${abi:-0}" -ge 4 ]; then check "tcp connect 127.0.0.1:5432: Permission denied"; fi
if [ "${abi:-0}" -ge 9 ]; then check "unix connect server socket: Permission denied"; fi
if [ "${abi:-0}" -ge 10 ]; then check "udp send 127.0.0.1:5432: Permission denied"; fi
set_conf zig_path "$PLZIG_TEST_ZIG"
set_conf zig_lib_dir ""
set_conf compiler_sandbox ""

echo "--- no-seccomp checks: $fails failure(s)"
exit $fails
