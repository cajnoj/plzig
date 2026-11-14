#!/bin/sh
# Test-only stand-in for the Zig compiler (isolation and TAP tests; never
# installed by the extension).  Installed by the test image as
# /opt/plzig-test/gatezig/zig, with REAL_ZIG and GATE_DIR substituted, and
# used with plzig.compiler_sandbox = off (it is a script and runs other
# programs, which the Landlock sandbox forbids).
#
# A compile whose source contains the marker  plzig-test-gate:<name>  pauses:
# the wrapper creates <GATE_DIR>/<name>.waiting, waits until a test creates
# <GATE_DIR>/<name>, then runs the real compiler.  Everything else (zig
# version, unmarked compiles) goes straight to the real compiler.  So a test
# can hold a compilation, and with it the compile lock, for exactly as long
# as it needs, without timing assumptions.
REAL_ZIG=@REAL_ZIG@
GATE_DIR=@GATE_DIR@
if [ "$1" = build-exe ] && [ -f src/user.zig ]; then
    gate=$(sed -n 's/.*plzig-test-gate:\([A-Za-z0-9_]*\).*/\1/p' src/user.zig | head -n 1)
    if [ -n "$gate" ]; then
        : > "$GATE_DIR/$gate.waiting"
        echo $$ > "$GATE_DIR/$gate.pid"
        while [ ! -e "$GATE_DIR/$gate" ]; do
            sleep 0.01
        done
    fi
fi
exec "$REAL_ZIG" "$@"
