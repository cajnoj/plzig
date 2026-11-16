#!/bin/bash
# License material of the source tree and of the source tarball
# (doc/packaging.md "License material"; CI job "licenses").
#
#   packaging/test-licenses.sh
#
# 1. packaging/check-licenses.sh source on this tree, with upstream's own
#    files: the WAMR tag tarball and both official Zig tarballs (vendor/ or
#    build/dl/, downloaded if missing; each must have its pinned SHA-256).
# 2. `make dist` (DIST_WORKTREE=1 with PLZIG_DIST_WORKTREE=1), and the same
#    check on the unpacked tarball: nothing was lost on the way.
# 3. The checker's self-test: it notices missing and changed files.
# The checks that need a build or built packages are elsewhere: `make
# check-licenses` (run by the package builds and docker/run-all.sh) and
# packaging/pkgtest-licenses.sh (packaging/test-packages.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
eval "$(sh packaging/versions.sh)"
mkdir -p build/dl "build/dl/zig-$ZIG_VERSION"
fetch() {   # fetch <vendored path> <download path> <url>: prints the file to use
    if [ -f "$1" ]; then echo "$1"; return; fi
    if [ ! -f "$2" ]; then
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o "$2.part" "$3" && mv "$2.part" "$2" || return 1
    fi
    echo "$2"
}
wamr=$(fetch "vendor/WAMR-$WAMR_VERSION.tar.gz" "build/dl/WAMR-$WAMR_VERSION.tar.gz" \
    "https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-$WAMR_VERSION.tar.gz") || exit 1
zigs=()
for a in x86_64 aarch64; do
    f=zig-$a-linux-$ZIG_VERSION.tar.xz
    z=$(fetch "vendor/zig/$f" "build/dl/zig-$ZIG_VERSION/$f" "https://ziglang.org/download/$ZIG_VERSION/$f") || exit 1
    zigs+=(--zig "$z")
done
rc=0
echo "--- source tree"
bash packaging/check-licenses.sh source . --wamr "$wamr" "${zigs[@]}" || rc=1

echo "--- source tarball"
dist=$(make -s dist PG_CONFIG=/bin/false DIST_WORKTREE="${PLZIG_DIST_WORKTREE:-0}" | tail -1)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -f "$dist" ] && tar -xzf "$dist" -C "$tmp"; then
    echo "$(basename "$dist")"
    bash packaging/check-licenses.sh source "$(echo "$tmp"/plzig-*)" --wamr "$wamr" "${zigs[@]}" || rc=1
else
    echo "  FAIL - make dist"; rc=1
fi

echo "--- self-test"
bash packaging/check-licenses.sh selftest . || rc=1
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
