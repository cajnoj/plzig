#!/bin/bash
# Leak accounting from outside one backend (run by test-in-container.sh
# against the running cluster):
#   - file descriptors of the backend (/proc/<pid>/fd) and its child
#     processes, before and after a batch of compilations (successful and
#     failing, functions and DO blocks) and of calls of several shapes;
#   - zombie processes in the container.
# PL/Zig memory contexts across many calls are checked by the pg_regress
# test test/sql/leaks.sql; the contents of $PGDATA/plzig after the whole
# suite by test-in-container.sh.
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }

echo "--- leak checks"

# one psql session driven through a coprocess; q <sql> runs it and waits
coproc PSQL { psql -X -q -At -v ON_ERROR_STOP=0 2>&1; }
q() {
    local line out=""
    printf '%s\n\\echo __done__\n' "$1" >&"${PSQL[1]}"
    while IFS= read -r line <&"${PSQL[0]}"; do
        [ "$line" = "__done__" ] && break
        out+="$line"$'\n'
    done
    printf '%s' "$out"
}

pid=$(q "SELECT pg_backend_pid();")
# Descriptors of the backend, without relation files: PostgreSQL's smgr
# opens catalog files lazily and keeps them open in its VFD cache (bounded by
# max_files_per_process), so which ones are open depends on the catalog
# access paths taken, not on PL/Zig.  Everything else (pipes, transient
# files, directories, /dev/null, the lock file) must not accumulate.
fdlist() {
    ls -l "/proc/$pid/fd" 2>/dev/null | awk 'NR > 1 { print $NF }' |
        grep -vE "^$PGDATA/(base|global)/[0-9]+/?[0-9_a-z.]*$" | sort
}
fds() { fdlist | wc -l; }
# (processes may vanish while /proc is read: cat skips them, awk must not)
allstat() { cat /proc/[0-9]*/stat 2>/dev/null; }
kids() { allstat | awk -v p="$pid" '{ sub(/^.*\) /, ""); if ($2 == p) n++ } END { print n + 0 }'; }

batch() {   # one round of everything; $1 makes the bodies unique
    local u=$1
    q "CREATE OR REPLACE FUNCTION lk_ok() RETURNS int LANGUAGE plzig AS \$\$ return $u; \$\$;" >/dev/null
    q "CREATE OR REPLACE FUNCTION lk_policy() RETURNS int LANGUAGE plzig AS \$\$ return @embedFile(\"x$u\"); \$\$;" >/dev/null
    q "CREATE OR REPLACE FUNCTION lk_error() RETURNS int LANGUAGE plzig AS \$\$ return nope$u; \$\$;" >/dev/null
    q "DO \$\$ plzig.notice(\"do $u\", .{}); \$\$ LANGUAGE plzig;" >/dev/null
    q "DO \$\$ return error.Fail$u; \$\$ LANGUAGE plzig;" >/dev/null
    q "SET plzig.compile_timeout = '100ms'; DO \$d\$ BEGIN EXECUTE (SELECT 'CREATE OR REPLACE FUNCTION lk_slow() RETURNS int LANGUAGE plzig AS ' || quote_literal('return g1($u); } ' || string_agg(format('noinline fn g%s(x: i32) i32 { return g%s(x *%% %s +%% 7) +%% 1; }', i, i + 1, i), ' ') || ' fn g8001(x: i32) i32 { return x; } fn unused() void {') FROM generate_series(1, 8000) i); END \$d\$; RESET plzig.compile_timeout;" >/dev/null
    q "SELECT lk_ok(), lk_shape_text('x'), lk_shape_spi(), lk_shape_cursor();" >/dev/null
    q "SELECT sum(lk_ok()) FROM generate_series(1, 2000);" >/dev/null
    q "SELECT lk_trap();" >/dev/null
}

q "CREATE OR REPLACE FUNCTION lk_shape_text(t text) RETURNS text LANGUAGE plzig AS \$\$ return t; \$\$;
   CREATE OR REPLACE FUNCTION lk_shape_spi() RETURNS bigint LANGUAGE plzig AS \$\$ const r = try plzig.spi.execute(\"SELECT count(*) FROM pg_class\", &.{}); return @intCast(r.rows); \$\$;
   CREATE OR REPLACE FUNCTION lk_shape_cursor() RETURNS bigint LANGUAGE plzig AS \$\$ var c = try plzig.spi.open(\"SELECT oid FROM pg_class\", &.{}); var n: i64 = 0; while (try c.next()) |_| n += 1; return n; \$\$;
   CREATE OR REPLACE FUNCTION lk_trap() RETURNS int LANGUAGE plzig AS \$\$ @panic(\"trap\"); \$\$;" >/dev/null

# warm up: catalogs opened, Zig version checked, everything loaded once
batch "1$RANDOM"
batch "2$RANDOM"
fd0=$(fds); list0=$(fdlist); kids0=$(kids)
for i in $(seq 1 10); do batch "$i$RANDOM$RANDOM"; done
fd1=$(fds); list1=$(fdlist); kids1=$(kids)

if [ "$fd0" -eq "$fd1" ]; then
    pass "backend descriptors (other than relation files) unchanged after 10 rounds of compilations and calls ($fd0)"
else
    fail "backend descriptors unchanged ($fd0 -> $fd1)"
    diff <(echo "$list0") <(echo "$list1") | sed 's/^/         /'
fi
if [ "$kids0" -eq 0 ] && [ "$kids1" -eq 0 ]; then
    pass "no child processes of the backend between statements"
else
    fail "no child processes of the backend ($kids0 -> $kids1)"
fi
# no descriptor of the backend points into the build directories
if grep -q 'pgsql_tmp.build' <<<"$list1"; then
    fail "no descriptor into a build directory"; grep 'pgsql_tmp.build' <<<"$list1" | sed 's/^/         /'
else
    pass "no descriptor into a build directory"
fi

q "DROP FUNCTION IF EXISTS lk_ok(), lk_policy(), lk_error(), lk_slow(), lk_shape_text(text), lk_shape_spi(), lk_shape_cursor(), lk_trap();" >/dev/null
exec {PSQL[1]}>&-
wait "$PSQL_PID" 2>/dev/null

# a process that has just exited is a zombie until its parent reaps it:
# poll (up to 10 s) for the count to reach 0, then show what is left
zombies() { allstat | awk '{ c = $0; sub(/^.*\) /, ""); if ($1 == "Z") print c }'; }
for i in $(seq 1 100); do [ -z "$(zombies)" ] && break; sleep 0.1; done
z=$(zombies)
if [ -z "$z" ]; then pass "no zombie processes"; else fail "no zombie processes"; echo "$z" | sed 's/^/         /'; fi

echo "--- leak checks: $fails failure(s)"
exit $fails
