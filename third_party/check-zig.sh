#!/bin/sh
# Check the build-time Zig compiler: absolute path, exactly the pinned version.
#   check-zig.sh <zig> <version>
set -eu
zig=$1; want=$2

if [ -z "$zig" ]; then
    cat >&2 <<EOF
ZIG is not set. PL/Zig needs Zig $want to build its source validator:

    make ZIG=/absolute/path/to/zig

The extension does not download or install Zig. To fetch and verify the
pinned official build into a directory of your choice:

    make install-zig ZIG_PREFIX=/opt/zig-$want
EOF
    exit 1
fi
case $zig in
    /*) ;;
    *) echo "ZIG must be an absolute path (got '$zig')" >&2; exit 1 ;;
esac
if [ ! -f "$zig" ] || [ ! -x "$zig" ]; then
    echo "ZIG=$zig is not an executable file" >&2
    exit 1
fi
got=$("$zig" version) || { echo "'$zig version' failed" >&2; exit 1; }
if [ "$got" != "$want" ]; then
    echo "ZIG=$zig is Zig $got; PL/Zig requires exactly Zig $want" >&2
    exit 1
fi
