#!/bin/bash
# Disk-full checks (layer "diskfull" of docker/test-in-container.sh).  The
# container runs with the data directory on a small tmpfs
# (docker/run-all.sh, job "diskfull": --tmpfs /tmp/pgdata:size=...), so the
# file system holding $PGDATA/plzig can be filled up: a compilation that
# runs out of space must fail with an ordinary ERROR, leave no build
# directory and no temporary cache file behind, not disturb functions that
# are already compiled, and work again once space is available.  (The
# server's own files share the file system; the filler leaves enough room
# for the little WAL these statements write.)
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }
psqlq() { psql -X -q -At -v VERBOSITY=default "$@" 2>&1; }

echo "--- disk full"
fstype=$(stat -f -c %T "$PGDATA")
echo "         data directory on $fstype, $(df -h --output=size,avail "$PGDATA" | tail -1)"
if [ "$fstype" != tmpfs ]; then
    fail "the data directory is not on a tmpfs (start the container with --tmpfs $PGDATA:...)"
    exit $fails
fi

psqlq -c "CREATE FUNCTION df_before() RETURNS int LANGUAGE plzig AS \$\$ return 4711; \$\$;" >/dev/null
filler=$PGDATA/plzig-diskfull-filler
fill_to() {   # leave about $1 kB free
    rm -f "$filler"
    local avail
    avail=$(df --output=avail -k "$PGDATA" | tail -1)
    if [ "$avail" -gt "$1" ]; then
        fallocate -l $(( (avail - $1) * 1024 )) "$filler" 2>/dev/null ||
            dd if=/dev/zero of="$filler" bs=1k count=$((avail - $1)) status=none 2>/dev/null
    fi
    echo "         $(df -k --output=avail "$PGDATA" | tail -1) kB free"
}
clean_state() {   # clean_state <context>
    if [ -z "$(find "$PGDATA/plzig" -maxdepth 1 -name 'pgsql_tmp.build.*')" ]; then pass "$1: no build directory left"; else fail "$1: no build directory left"; fi
    if [ -z "$(find "$PGDATA/plzig/cache" -maxdepth 1 -name '*.tmp.*')" ]; then pass "$1: no temporary cache file left"; else fail "$1: no temporary cache file left"; fi
    if [ "$(psqlq -c 'SELECT df_before()')" = 4711 ]; then pass "$1: compiled function still runs"; else fail "$1: compiled function still runs"; fi
}

# a module with 8 MB of constant data: the compiler's output does not fit
body='return @as(i32, big[@intCast(@mod(a, 8))]); } const big: [8 << 20]u8 = @splat(3); fn unused() void {'
fill_to 4096
out=$(psqlq -c "SET plzig.max_module_size = '16MB'" \
            -c "CREATE FUNCTION df_big(a int) RETURNS int STRICT LANGUAGE plzig AS \$\$ $body \$\$;")
echo "$out" | head -4 | sed 's/^/         /'
if grep -qE "ERROR: .*(compilation failed|could not write|could not create|No space left|NoSpaceLeft)" <<<"$out"; then
    pass "large compilation on a full disk: clean ERROR"
else
    fail "large compilation on a full disk: clean ERROR"
fi
if grep -qF "$PGDATA" <<<"$out"; then fail "error shows the data directory"; else pass "error does not show the data directory"; fi
clean_state "after the large compilation"

# almost nothing left: even a small compilation fails cleanly
fill_to 256
out=$(psqlq -c "CREATE FUNCTION df_small() RETURNS int LANGUAGE plzig AS \$\$ return $RANDOM$RANDOM; \$\$;")
echo "$out" | head -3 | sed 's/^/         /'
# (psql -q prints nothing on success)
if ! grep -qE "FATAL|PANIC|server closed|connection" <<<"$out" && { [ -z "$out" ] || grep -q "^ERROR" <<<"$out"; }; then
    pass "small compilation on a full disk: ERROR or success, nothing else"
else
    fail "small compilation on a full disk: ERROR or success, nothing else"
fi
clean_state "after the small compilation"
out=$(psqlq -c "DO \$\$ plzig.notice(\"x{d}\", .{$RANDOM}); \$\$ LANGUAGE plzig;")
clean_state "after a DO block"

# space again: everything works
rm -f "$filler"
out=$(psqlq -c "SET plzig.max_module_size = '16MB'" \
            -c "CREATE OR REPLACE FUNCTION df_big(a int) RETURNS int STRICT LANGUAGE plzig AS \$\$ $body \$\$;" \
            -c "SELECT df_big(5);")
if grep -qx 3 <<<"$out"; then pass "compiles and runs once space is free again"; else fail "compiles and runs once space is free again"; echo "$out" | sed 's/^/         /'; fi
clean_state "after recovery"
if grep -qE "PANIC|terminated by signal" /tmp/server.log; then fail "no PANIC or crash in the server log"; else pass "no PANIC or crash in the server log"; fi
psqlq -c "DROP FUNCTION IF EXISTS df_big(int); DROP FUNCTION IF EXISTS df_small(); DROP FUNCTION df_before();" >/dev/null
echo "--- disk full: $fails failure(s)"
exit $fails
