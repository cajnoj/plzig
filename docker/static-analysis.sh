#!/bin/bash
# Static analysis of PL/Zig's own C code (src/, not WAMR) and a check of the
# hardening of the installed binaries.  Runs inside a test image:
#
#   docker/static-analysis.sh analyze     clang static analyzer (scan-build)
#                                         and cppcheck over src/*.c; needs the
#                                         docker/Dockerfile.fuzz image
#   docker/static-analysis.sh hardening   plzig.so and plzig-validate as
#                                         installed: RELRO/BIND_NOW, no
#                                         executable stack, no text
#                                         relocations, PIE, and the stack
#                                         protector and _FORTIFY_SOURCE when
#                                         pg_config's flags ask for them
#
# docker/run-all.sh runs both (variant "static").  Prints one "ok"/"FAIL"
# line per check and "LAYER static-<mode>: PASS|FAIL"; exits non-zero on any
# finding.  Every suppression below is listed with its justification.
set -u
mode=${1:?usage: static-analysis.sh analyze|hardening}
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }
src=/src

analyze() {
    local work inc defs objs n
    work=$(mktemp -d /tmp/plzig-sa.XXXXXX)
    inc="-I$(pg_config --includedir-server) -I$src/build/wamr-src/core/iwasm/include"
    defs='-DPLZIG_ZIG_VERSION="0.17.1"'

    echo "--- scan-build (clang static analyzer, $(clang --version | head -1))"
    # Our sources only: each file is analyzed on its own with the flags of
    # the real build (PostgreSQL's CPPFLAGS, PL/Zig's defines), once as the
    # release build and once with the test helpers (-DPLZIG_TESTING).
    objs=""
    for testing in "" "-DPLZIG_TESTING"; do
        for f in "$src"/src/*.c; do
            # shellcheck disable=SC2086
            scan-build --status-bugs -o "$work/report" --use-cc=clang \
                -disable-checker deadcode.DeadStores \
                clang -c -O1 -std=gnu99 $(pg_config --cppflags) $inc $defs $testing \
                -Wno-ignored-attributes -Wno-unknown-warning-option \
                "$f" -o "$work/$(basename "$f" .c).o" >"$work/sb.log" 2>&1
            rc=$?
            n=$(grep -oE '[0-9]+ bugs? found' "$work/sb.log" | grep -oE '^[0-9]+')
            if [ $rc -eq 0 ] && [ -z "$n" ]; then
                [ -z "$testing" ] && objs="$objs $(basename "$f")"
            else
                fail "scan-build: $(basename "$f")${testing:+ ($testing)}: ${n:-?} report(s)"
                grep -E "warning:|error:" "$work/sb.log" | grep -v "ignored-attributes" | head -20 | sed 's/^/         /'
            fi
        done
    done
    [ -n "$objs" ] && pass "scan-build: no reports in$objs (release and PLZIG_TESTING builds)"
    # Disabled checker, with the reason:
    #   deadcode.DeadStores  stores kept on purpose for readability
    #                        ("elevel = LOG; /* keep compiler quiet */" after
    #                        ereport(ERROR), which the analyzer flags); not a
    #                        correctness check

    echo "--- cppcheck ($(cppcheck --version))"
    # Suppressions, with the reasons (each one was triaged against the code):
    #   missingIncludeSystem  system headers are not analysed
    #   unusedFunction        PG_FUNCTION_INFO_V1 entry points and WAMR
    #                         callbacks are called from outside
    #   readdirCalled         readdir_r is deprecated; the backend is
    #                         single-threaded (plzig_runtime.c checks that
    #                         WAMR starts no threads)
    #   shadowFunction        local variables named like functions declared
    #                         in PostgreSQL's headers ("now"); harmless
    #   *:*/include/server/*  reports inside PostgreSQL's own headers
    #   variableScope         style: declarations at the top of a block are
    #                         the PostgreSQL convention
    #   knownConditionTrueFalse
    #                         two reports, both false positives of cppcheck
    #                         2.10's value flow: plzig_sandbox_missing()
    #                         "n > 0 is always true" (n is 0 for Landlock
    #                         ABI >= 10, which docker/security-checks.sh
    #                         exercises), and plzig_instance_call() "j < nlen
    #                         is always false" (nlen comes from guest memory
    #                         copied with memcpy, which cppcheck takes for 0)
    #   inline: src/plzig.c "cppcheck-suppress nullPointer" on
    #                         dlist_tail_element(): cppcheck evaluates the
    #                         container_of arithmetic of PostgreSQL's dlist
    #                         macros on a NULL pointer; the loop condition
    #                         (!dlist_is_empty) guarantees an element
    # Fixed instead of suppressed: unreadVariable in plzig_format_output
    # (src/plzig_build.c, a dead initialisation).
    # shellcheck disable=SC2086
    cppcheck --quiet --std=c99 --enable=warning,style,performance,portability \
        --inline-suppr --library=posix --error-exitcode=1 \
        --suppress=missingIncludeSystem --suppress=unusedFunction \
        --suppress=readdirCalled --suppress=shadowFunction \
        --suppress=variableScope \
        --suppress='knownConditionTrueFalse:*/plzig_build.c' --suppress='knownConditionTrueFalse:*/plzig_runtime.c' \
        --suppress='*:*/include/server/*' \
        -D__linux__ -D__x86_64__ -D__GNUC__ -DPLZIG_ZIG_VERSION='"0.17.1"' \
        $inc \
        "$src"/src/*.c >"$work/cppcheck.log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && ! grep -qE "(error|warning|style|performance|portability):" "$work/cppcheck.log"; then
        pass "cppcheck: no reports in src/*.c"
    else
        fail "cppcheck: reports"
        cat "$work/cppcheck.log" | sed 's/^/         /'
    fi
    rm -rf "$work"
}

hardening() {
    local so val cflags cppflags ldflags
    so=$(pg_config --pkglibdir)/plzig.so
    val=$(pg_config --pkglibdir)/plzig/plzig-validate
    cflags=$(pg_config --cflags)
    cppflags=$(pg_config --cppflags)
    ldflags=$(pg_config --ldflags)
    echo "--- hardening of $so and $val"
    echo "         pg_config: CFLAGS has$([[ "$cflags" == *-fstack-protector* ]] || echo ' no') stack protector;" \
         "CPPFLAGS has$([[ "$cppflags" == *_FORTIFY_SOURCE* ]] || echo ' no') _FORTIFY_SOURCE;" \
         "LDFLAGS: $ldflags"
    for f in "$so" "$val"; do
        local b
        b=$(basename "$f")
        if readelf -lW "$f" | grep -q GNU_RELRO; then pass "$b: RELRO"; else fail "$b: RELRO"; fi
        if readelf -lW "$f" | awk '$1 == "GNU_STACK" { print $7 }' | grep -qx RW; then
            pass "$b: non-executable stack (GNU_STACK RW)"
        else
            fail "$b: non-executable stack: $(readelf -lW "$f" | grep GNU_STACK)"
        fi
        if readelf -dW "$f" | grep -q TEXTREL; then fail "$b: text relocations"; else pass "$b: no text relocations"; fi
        if readelf -lW "$f" | awk '$1 == "LOAD" && $7 ~ /W/ && $7 ~ /E/' | grep -q .; then
            fail "$b: a segment is writable and executable"
        else
            pass "$b: no writable and executable segment"
        fi
    done
    # BIND_NOW (full RELRO) wherever the linker flags ask for it, and always
    # for plzig-validate (Zig links it with -z now)
    if [[ "$ldflags" == *"-z,now"* ]] || [[ "$ldflags" == *"-znow"* ]]; then
        if readelf -dW "$so" | grep -qE 'BIND_NOW|FLAGS_1.*NOW'; then pass "plzig.so: BIND_NOW (full RELRO), as pg_config asks"; else fail "plzig.so: BIND_NOW, as pg_config asks"; fi
    else
        echo "  skip - plzig.so: BIND_NOW (pg_config's LDFLAGS do not ask for it)"
    fi
    if readelf -dW "$val" | grep -qE 'BIND_NOW|FLAGS_1.*NOW'; then pass "plzig-validate: BIND_NOW (full RELRO)"; else fail "plzig-validate: BIND_NOW"; fi
    # PIE and static: the validator runs under Landlock with execute
    # permission on itself only
    if readelf -hW "$val" | grep -q 'DYN (Position-Independent'; then pass "plzig-validate: position independent (static PIE)"; else fail "plzig-validate: position independent: $(readelf -hW "$val" | grep Type:)"; fi
    if readelf -lW "$val" | grep -q INTERP; then fail "plzig-validate: needs a program interpreter"; else pass "plzig-validate: no program interpreter (static)"; fi
    # inherited from pg_config: stack protector and fortified libc calls
    if [[ "$cflags" == *-fstack-protector* ]]; then
        if nm -D "$so" | grep -q '__stack_chk_fail'; then pass "plzig.so: stack protector (from pg_config CFLAGS)"; else fail "plzig.so: stack protector (pg_config CFLAGS has it)"; fi
    else
        echo "  skip - plzig.so: stack protector (pg_config's CFLAGS do not ask for it)"
    fi
    if [[ "$cppflags" == *_FORTIFY_SOURCE* ]]; then
        if nm -D "$so" | grep -qE '__[a-z_]+_chk@'; then pass "plzig.so: _FORTIFY_SOURCE checks present ($(nm -D "$so" | grep -oE '__[a-z_]+_chk@' | tr -d @ | sort -u | tr '\n' ' '))"; else fail "plzig.so: _FORTIFY_SOURCE (pg_config CPPFLAGS has it)"; fi
    else
        echo "  skip - plzig.so: _FORTIFY_SOURCE (pg_config's CPPFLAGS do not ask for it)"
    fi
    # the WAMR objects are inside plzig.so with hidden visibility: only the
    # PostgreSQL entry points are exported
    local exported
    exported=$(nm -D --defined-only "$so" | awk '{ print $3 }' | grep -vE '^(_init|_fini|Pg_magic_func|_PG_init|pg_finfo_plzig_.*|plzig_(call_handler|inline_handler|validator|sandbox_status|cache_clear|check_all))$')
    if [ -z "$exported" ]; then pass "plzig.so: exports only the PostgreSQL entry points"; else fail "plzig.so: exports more: $(echo $exported | head -c 300)"; fi
}

case $mode in
    analyze) analyze ;;
    hardening) hardening ;;
    *) echo "unknown mode $mode"; exit 2 ;;
esac
if [ $fails -eq 0 ]; then echo "LAYER static-$mode: PASS"; else echo "LAYER static-$mode: FAIL ($fails failure(s))"; fi
exit $fails
