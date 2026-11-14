#!/bin/bash
# Runs inside the test image (as user postgres): start a throw-away cluster,
# point it at the Zig compiler (an external dependency, installed in the
# image under $PLZIG_TEST_ZIG), warm the Zig cache, run the selected test
# layers, print one line per layer and a result line.
#
# PLZIG_LAYERS (space separated; default "unit regress security leaks"):
#   unit       Zig unit tests of the validator and the SDK (make check-zig)
#   regress    the pg_regress suite (make installcheck)
#   security   docker/security-checks.sh (needs postgresql.conf changes)
#   leaks      docker/leak-checks.sh, then the contents of $PGDATA/plzig
#   isolation  pg_isolation_regress (make installcheck-isolation)
#   tap        the TAP tests in test/tap/t (prove; PLZIG_TAP_TESTS selects)
#   testing    C unit checks (make installcheck-testing); needs the
#              PLZIG_TESTING=1 build installed (docker/run-all.sh does that)
#   diskfull   docker/diskfull-checks.sh: compilations on a full file system;
#              needs $PGDATA on a small tmpfs (docker/run-all.sh, "diskfull")
#   fuzz       one SQL-driven fuzz target, fuzz/$PLZIG_FUZZ_TARGET/run.sh
#              (hostabi, marshal, pipeline) for $PLZIG_FUZZ_SECONDS seconds,
#              output to $PLZIG_FUZZ_OUT (docker/run-fuzz.sh)
# PLZIG_NO_LANDLOCK=1 / PLZIG_NO_SECCOMP=1: the container was started with a
# seccomp profile that blocks Landlock / seccomp filters; run only the checks
# for that situation.
# PLZIG_VALGRIND=1: run the server under Valgrind (docker/Dockerfile.hardened
# with VALGRIND=1), and fail on any Valgrind error.
# PLZIG_ASAN=1: the installed plzig.so is a sanitizer build (docker/
# Dockerfile.variant VARIANT=asan); the server runs with the sanitizer runtime
# preloaded, and any sanitizer report fails the run.
# PLZIG_COVERAGE=1: the installed plzig.so is a gcov build with the test
# helpers (VARIANT=coverage); write the report (docker/coverage-report.sh).
set -u

export PGDATA=/tmp/pgdata
export PGHOST=/tmp
export PGUSER=postgres
export PGDATABASE=postgres
layers=" ${PLZIG_LAYERS:-unit regress security leaks} "
# the no-Landlock/no-seccomp containers run only their own checks
[ "${PLZIG_NO_LANDLOCK:-0}" = 1 ] || [ "${PLZIG_NO_SECCOMP:-0}" = 1 ] && layers=" "
has() { [[ "$layers" == *" $1 "* ]]; }

ver=$(pg_config --version)
echo "=== $ver ($(uname -m)); layers:$layers"

declare -a summary
failed=0
layer() {   # layer <name> <PASS|FAIL> <detail>
    summary+=("LAYER $1: $2${3:+ ($3)}")
    echo "LAYER $1: $2${3:+ ($3)}"
    [ "$2" = PASS ] || failed=1
}

# the Zig unit tests need no server
if has unit; then
    echo "--- Zig unit tests"
    if make -s -C /src check-zig ZIG="$PLZIG_TEST_ZIG" >/tmp/check-zig.log 2>&1; then
        layer unit PASS "$(grep -aE '^All [0-9]+ tests passed' /tmp/check-zig.log | awk '{ s += $2 } END { print s " tests" }')"
    else
        tail -40 /tmp/check-zig.log
        layer unit FAIL "see log"
    fi
fi
needs_server=0
for l in regress security leaks isolation tap testing fuzz diskfull; do has $l && needs_server=1; done
if [ $needs_server = 0 ] && [ "${PLZIG_NO_LANDLOCK:-0}" != 1 ] && [ "${PLZIG_NO_SECCOMP:-0}" != 1 ]; then
    [ $failed = 0 ] && { echo "RESULT: PASS"; exit 0; }
    echo "RESULT: FAIL"; exit 1
fi

initdb -U postgres --no-locale -E UTF8 -A trust >/tmp/initdb.log 2>&1 || {
    cat /tmp/initdb.log; echo "RESULT: FAIL (initdb)"; exit 1; }
# the administrator's step: plzig.zig_path has no default
echo "plzig.zig_path = '$PLZIG_TEST_ZIG'" >> "$PGDATA/postgresql.conf"

pgctl_opts=()
if [ "${PLZIG_VALGRIND:-0}" = 1 ]; then
    # every server process runs under Valgrind; the compiler and the
    # validator (children of a backend) do not
    mkdir -p /tmp/valgrind
    cat > /tmp/postgres-valgrind <<EOF
#!/bin/sh
exec valgrind --quiet --error-exitcode=0 --trace-children=yes \\
    --trace-children-skip='*/zig,*/plzig-validate,/bin/*,/usr/bin/*' \\
    --track-origins=yes --read-var-info=yes --num-callers=40 \\
    --suppressions=/usr/local/pgsql/valgrind.supp \\
    --log-file=/tmp/valgrind/%p.log \\
    $(pg_config --bindir)/postgres "\$@"
EOF
    chmod 755 /tmp/postgres-valgrind
    pgctl_opts=(-p /tmp/postgres-valgrind -t 600)
    # Valgrind (3.19) does not know the Landlock system calls: the backend's
    # probe gets ENOSYS, so require would refuse every compilation.  The
    # sandbox itself is exercised by all other runs; here compile with what
    # is available (test/expected/setup_1.out is the matching variant of the
    # setup test's output; the other runs check "enforced" explicitly).
    echo "plzig.compiler_sandbox = 'try'" >> "$PGDATA/postgresql.conf"
fi
pgctl_env=()
if [ "${PLZIG_COVERAGE:-0}" = 1 ]; then
    # gcov counters go to $GCOV_PREFIX/src/src/*.gcda.  The code that runs
    # in the forked child (sandbox set-up) is dumped by libgcov just before
    # execve, under Landlock: the only writable places are the build
    # directory and the Zig cache, so the prefix is relative to the
    # process's working directory, which is <cluster>/plzig/<build dir> for
    # the child (-> the cluster's Zig cache) and the data directory for
    # backends (-> next to it).  docker/coverage-report.sh collects them all
    # (the TAP layer keeps its clusters for that: PG_TEST_NOCLEAN).
    export GCOV_PREFIX=/proc/self/cwd/../pgsql_tmp.zig-cache/gcov
fi
if [ "${PLZIG_ASAN:-0}" = 1 ]; then
    # The sanitizer runtime must be loaded first in every server process, also
    # after the security checks restart the server: export it for the whole
    # run (the compiler's environment is built from scratch by PL/Zig, so it
    # never inherits LD_PRELOAD).  Only for a server without NLS, see
    # docker/run-all.sh.
    mkdir -p /tmp/asan
    export LD_PRELOAD="$(gcc -print-file-name=libasan.so)"
    export ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=0:log_path=/tmp/asan/asan
    export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1:log_path=/tmp/asan/ubsan
fi
"${pgctl_env[@]}" pg_ctl -D "$PGDATA" -l /tmp/server.log -w "${pgctl_opts[@]}" \
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

if has regress; then
    echo "--- pg_regress"
    make installcheck ${PLZIG_REGRESS:+REGRESS="$PLZIG_REGRESS"} >/tmp/installcheck.log 2>&1
    rc=$?
    grep -E "^(ok|not ok|test |     [a-z_]+ +\.\.\.)|tests (passed|failed)|# " /tmp/installcheck.log
    counts=$(grep -aoE '(All [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' /tmp/installcheck.log | tail -1)
    if [ $rc -ne 0 ]; then
        echo "--- regression.diffs"
        head -400 regression.diffs 2>/dev/null
        echo "--- server log (tail)"
        tail -40 /tmp/server.log
        layer regress FAIL "$counts"
    elif [[ "$sandbox" != enforced* ]] && [ "${PLZIG_VALGRIND:-0}" != 1 ]; then
        # plzig.compiler_sandbox defaults to require, so a passing suite
        # implies Landlock was enforced; check it explicitly anyway
        layer regress FAIL "compiler not confined: $sandbox"
    else
        layer regress PASS "$counts"
    fi
fi

if has security; then
    # shell-driven security checks (fake compilers, Landlock probe, tampering)
    bash /src/docker/security-checks.sh
    sec=$?
    # the release build carries no test helpers (the coverage build is a
    # PLZIG_TESTING build on purpose)
    so="$(pg_config --pkglibdir)/plzig.so"
    ntest=$(nm -D --defined-only "$so" | grep -c ' plzig_test_')
    if [ "${PLZIG_COVERAGE:-0}" = 1 ]; then echo "  skip - test helper symbols (coverage build)";
    elif [ "$ntest" -eq 0 ]; then echo "  ok   - installed plzig.so exports no plzig_test_* symbols";
    else echo "  FAIL - installed plzig.so exports $ntest plzig_test_* symbols"; sec=$((sec + 1)); fi
    staged=/opt/plzig-testing$so
    if [ -f "$staged" ]; then
        nstaged=$(nm -D --defined-only "$staged" | grep -c ' plzig_test_')
        if [ "$nstaged" -gt 0 ]; then echo "  ok   - the staged test build has them ($nstaged)";
        else echo "  FAIL - the staged test build has no plzig_test_* symbols"; sec=$((sec + 1)); fi
    fi
    if [ $sec -eq 0 ]; then layer security PASS; else layer security FAIL "$sec failure(s)"; fi
fi

if has isolation; then
    echo "--- isolation"
    make installcheck-isolation >/tmp/isolation.log 2>&1
    rc=$?
    grep -E "^(ok|not ok)|tests (passed|failed)" /tmp/isolation.log
    counts=$(grep -aoE '(All [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' /tmp/isolation.log | tail -1)
    if [ $rc -eq 0 ]; then layer isolation PASS "$counts"; else
        head -300 output_iso/regression.diffs 2>/dev/null
        layer isolation FAIL "$counts"; fi
fi

if has testing; then
    echo "--- C unit checks (PLZIG_TESTING build)"
    so="$(pg_config --pkglibdir)/plzig.so"
    if [ "$(nm -D --defined-only "$so" | grep -c ' plzig_test_')" -eq 0 ]; then
        layer testing FAIL "the installed plzig.so is not a PLZIG_TESTING build"
    else
        make installcheck-testing >/tmp/testing.log 2>&1
        rc=$?
        grep -E "^(ok|not ok)|tests (passed|failed)" /tmp/testing.log
        if [ $rc -eq 0 ]; then layer testing PASS; else
            head -300 regression.diffs 2>/dev/null
            layer testing FAIL; fi
    fi
fi

if has tap; then
    echo "--- TAP"
    pgxs=$(dirname "$(pg_config --pgxs)")/../..   # <pkglibdir>/pgxs
    mkdir -p /tmp/plzig-gates /tmp/tap
    (
        cd /src/test/tap &&
        PATH="$(pg_config --bindir):$PATH" \
        PERL5LIB="$pgxs/src/test/perl:/src/test/tap" \
        TESTDIR=/tmp/tap TESTDATADIR=/tmp/tap/data \
        PG_REGRESS="$pgxs/src/test/regress/pg_regress" \
        PLZIG_TEST_GATEZIG=/opt/plzig-test/gatezig/zig PLZIG_TEST_GATE_DIR=/tmp/plzig-gates \
        PLZIG_TEST_ZIG_CACHE="$PGDATA/plzig/pgsql_tmp.zig-cache" \
        env $([ "${PLZIG_COVERAGE:-0}" = 1 ] && echo PG_TEST_NOCLEAN=1) \
        prove ${PLZIG_PROVE_FLAGS:-} ${PLZIG_TAP_TESTS:-t/*.pl}
    ) >/tmp/tap.log 2>&1
    rc=$?
    cat /tmp/tap.log
    tests=$(grep -aoE 'Files=[0-9]+, Tests=[0-9]+' /tmp/tap.log | tail -1)
    if [ $rc -eq 0 ]; then layer tap PASS "$tests"; else
        for f in /src/test/tap/log/regress_log_*; do
            grep -q 'not ok' "$f" && { echo "=== $f"; grep -B5 -A20 'not ok' "$f" | head -80; }
        done
        layer tap FAIL "$tests"; fi
fi

if has diskfull; then
    bash /src/docker/diskfull-checks.sh
    df=$?
    if [ $df -eq 0 ]; then layer diskfull PASS; else layer diskfull FAIL "$df failure(s)"; fi
fi

if has fuzz; then
    t=${PLZIG_FUZZ_TARGET:-}
    echo "--- fuzz target $t"
    if [ -f "/src/fuzz/$t/run.sh" ]; then
        PLZIG_FUZZ_OUT=${PLZIG_FUZZ_OUT:-/tmp/fuzz-out} bash "/src/fuzz/$t/run.sh" "${PLZIG_FUZZ_SECONDS:-60}" >/tmp/fuzz-run.log 2>&1
        rc=$?
        mkdir -p "${PLZIG_FUZZ_OUT:-/tmp/fuzz-out}"
        cp /tmp/fuzz-run.log "${PLZIG_FUZZ_OUT:-/tmp/fuzz-out}/run.log"
        grep -aE '^(FUZZ |FINDING|--- )' /tmp/fuzz-run.log
        line=$(grep -a '^FUZZ ' /tmp/fuzz-run.log | tail -1)
        if [ $rc -eq 0 ] && [[ "$line" == *": PASS"* ]]; then layer fuzz PASS "$t"; else
            tail -30 /tmp/fuzz-run.log; layer fuzz FAIL "$t"; fi
    else
        layer fuzz FAIL "unknown target '$t'"
    fi
fi

if has leaks; then
    bash /src/docker/leak-checks.sh
    lk=$?
    # after everything that ran against this cluster: only the module cache,
    # the lock file and the Zig cache are in $PGDATA/plzig; no build
    # directories, no temporary files
    extra=$(cd "$PGDATA/plzig" && ls -A | grep -vxE 'cache|compile\.lock|pgsql_tmp\.zig-cache')
    odd=$(cd "$PGDATA/plzig/cache" && ls -A | grep -vxE '[0-9a-f]{64}\.wasm')
    if [ -z "$extra" ] && [ -z "$odd" ]; then
        echo "  ok   - \$PGDATA/plzig holds only the cache, the lock file and the Zig cache"
    else
        echo "  FAIL - unexpected entries in \$PGDATA/plzig: $extra $odd"; lk=$((lk + 1))
    fi
    if [ $lk -eq 0 ]; then layer leaks PASS; else layer leaks FAIL "$lk failure(s)"; fi
fi

pg_ctl -D "$PGDATA" -m fast stop -t 600 >/dev/null

if [ "${PLZIG_VALGRIND:-0}" = 1 ]; then
    # Valgrind logs of processes that reported errors (definite leaks of
    # short-lived processes are not errors here: --error-exitcode=0 and no
    # --leak-check)
    bad=$(grep -l 'ERROR SUMMARY: [1-9]' /tmp/valgrind/*.log 2>/dev/null)
    nlogs=$(ls /tmp/valgrind/*.log 2>/dev/null | wc -l)
    if [ -z "$bad" ]; then
        layer valgrind PASS "$nlogs processes, no errors"
    else
        for f in $bad; do echo "=== $f"; head -150 "$f"; done
        layer valgrind FAIL "$(echo "$bad" | wc -l) of $nlogs processes reported errors"
    fi
fi

if [ "${PLZIG_ASAN:-0}" = 1 ]; then
    reports=$(ls /tmp/asan/ 2>/dev/null)
    if [ -z "$reports" ]; then
        layer sanitizers PASS "no AddressSanitizer/UBSan reports"
    else
        for f in /tmp/asan/*; do echo "=== $f"; head -100 "$f"; done
        layer sanitizers FAIL "$(echo "$reports" | wc -l) report(s)"
    fi
fi

if [ "${PLZIG_COVERAGE:-0}" = 1 ]; then
    bash /src/docker/coverage-report.sh > /tmp/coverage-report.log 2>&1
    cat /tmp/coverage-report.log
    line=$(grep '^LAYER coverage:' /tmp/coverage-report.log)
    if [[ "$line" == "LAYER coverage: PASS"* ]]; then layer coverage PASS "$(sed -n 's/.*(\(.*\))$/\1/p' <<<"$line")";
    else layer coverage FAIL "report failed"; fi
fi

echo "=== summary"
printf '%s\n' "${summary[@]}"
if [ $failed = 0 ]; then
    echo "RESULT: PASS (sandbox: $sandbox)"
    exit 0
fi
echo "RESULT: FAIL (sandbox: $sandbox)"
exit 1
