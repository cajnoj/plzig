#!/bin/sh
# Print the versions and pins of a PL/Zig source tree, one NAME=value per
# line, for packaging scripts (doc/packaging.md "Versions").  Everything is
# read from its single source: the Makefile (PLZIG_VERSION, ZIG_VERSION, the
# checksums), src/plzig.h (the host/guest ABI version) and, in a tarball made
# by `make dist`, .dist-version.
#
#   packaging/versions.sh [source tree]       (default: this script's tree)
#
# DIST_VERSION is the tarball's version (.dist-version) or PLZIG_VERSION;
# PKG_VERSION is DIST_VERSION with the semver pre-release "-" turned into
# "~", which sorts before the release in both RPM and Debian versions.
set -eu
top=${1:-$(dirname "$0")/..}
mk=$top/Makefile
get() {
    v=$(sed -n "s/^$1 := \\(.*\\)\$/\\1/p" "$mk")
    case $v in
        "" | *[!0-9A-Za-z.-]*) echo "versions.sh: no valid '$1 := ...' line in $mk" >&2; exit 1 ;;
    esac
    printf '%s\n' "$v"
}
plzig=$(get PLZIG_VERSION)
zig=$(get ZIG_VERSION)
core=${plzig%%-*}
ext=$(printf '%s\n' "$core" | cut -d. -f1-2)
abi=$(sed -n 's/^#define PLZIG_ABI_VERSION[[:space:]]*\([0-9][0-9]*\)$/\1/p' "$top/src/plzig.h")
dist=$plzig
[ -f "$top/.dist-version" ] && dist=$(cat "$top/.dist-version")
pkg=$(printf '%s\n' "$dist" | sed 's/-/~/')
wamr=$(sed -n 's/^tag=WAMR-\([0-9.]*\)$/\1/p' "$top/third_party/prepare-wamr.sh")
wamr_commit=$(sed -n 's/^commit=\([0-9a-f]*\)$/\1/p' "$top/third_party/prepare-wamr.sh")
echo "PLZIG_VERSION=$plzig"
echo "EXT_VERSION=$ext"
echo "DIST_VERSION=$dist"
echo "PKG_VERSION=$pkg"
echo "ZIG_VERSION=$zig"
echo "ABI_VERSION=$abi"
echo "WAMR_VERSION=$wamr"
echo "WAMR_COMMIT=$wamr_commit"
echo "WAMR_TARBALL_SHA256=$(get WAMR_TARBALL_SHA256)"
echo "ZIG_SHA256_x86_64=$(get ZIG_SHA256_x86_64)"
echo "ZIG_SHA256_aarch64=$(get ZIG_SHA256_aarch64)"
