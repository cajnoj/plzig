#!/bin/bash
# The documented fully offline source build (doc/packaging.md "Offline
# build"), proven in a container without network (--network none):
#
#   make install-zig ZIG_PREFIX=/opt/zig ZIG_TARBALL=<zig tarball>
#   make ZIG=/opt/zig/zig WAMR_TARBALL=<WAMR tarball>
#   make install; make check-zig
#
# from the source tarball, on the Debian 13 builder image
# (plzig-pkgbuild:debian13, from packaging/build-packages.sh debian13; it
# has the compilers and PostgreSQL server headers but no Zig and no git).
# Also checks that the container really has no network: only the loopback
# interface, and name resolution fails.
#
#   packaging/test-offline-build.sh [major]          (default 18)
#
# Inputs as for packaging/build-packages.sh (PLZIG_DIST or make dist; the
# Zig and WAMR tarballs, verified against their pins).
set -euo pipefail
cd "$(dirname "$0")/.."
major=${1:-18}
eval "$(sh packaging/versions.sh)"
arch=$(uname -m)
img=plzig-pkgbuild:debian13
docker image inspect "$img" >/dev/null 2>&1 || { echo "no $img: run packaging/build-packages.sh debian13 first" >&2; exit 2; }
zigtb=build/dl/zig-$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz
[ -f "$zigtb" ] || zigtb=vendor/zig/zig-$arch-linux-$ZIG_VERSION.tar.xz
wamrtb=vendor/WAMR-$WAMR_VERSION.tar.gz
[ -f "$wamrtb" ] || wamrtb=build/dl/WAMR-$WAMR_VERSION.tar.gz
sumvar=ZIG_SHA256_$arch
echo "${!sumvar}  $zigtb" | sha256sum -c - >/dev/null
echo "$WAMR_TARBALL_SHA256  $wamrtb" | sha256sum -c - >/dev/null
dist=${PLZIG_DIST:-$(make -s dist PG_CONFIG=/bin/false DIST_WORKTREE="${PLZIG_DIST_WORKTREE:-0}" | tail -1)}
log=build/package-tests/offline-build.log
mkdir -p build/package-tests

docker run --rm --network none --security-opt label=disable \
    -v "$(cd "$(dirname "$dist")" && pwd)/$(basename "$dist"):/in/plzig.tar.gz:ro" \
    -v "$PWD/$zigtb:/in/zig.tar.xz:ro" -v "$PWD/$wamrtb:/in/wamr.tar.gz:ro" \
    "$img" bash -c '
        set -eu
        pgc=/usr/lib/postgresql/'"$major"'/bin/pg_config
        echo "--- network interfaces in the container: $(ls /sys/class/net | tr "\n" " ")"
        [ "$(ls /sys/class/net)" = lo ] || { echo "UNEXPECTED: a network interface besides lo"; exit 1; }
        if getent hosts ziglang.org >/dev/null 2>&1; then echo "UNEXPECTED: name resolution works"; exit 1; fi
        echo "--- name resolution fails (no network)"
        mkdir /tmp/a /tmp/b
        tar -xzf /in/plzig.tar.gz -C /tmp/a; tar -xzf /in/plzig.tar.gz -C /tmp/b
        cd /tmp/a/plzig-*
        command -v git >/dev/null 2>&1 && echo "--- git is installed (unused)" || echo "--- git is not installed: WAMR cannot be cloned either"
        echo "--- offline build"
        make install-zig ZIG_PREFIX=/opt/zig ZIG_TARBALL=/in/zig.tar.xz
        make -j"$(nproc)" PG_CONFIG=$pgc ZIG=/opt/zig/zig WAMR_TARBALL=/in/wamr.tar.gz WERROR=1
        make install PG_CONFIG=$pgc ZIG=/opt/zig/zig WAMR_TARBALL=/in/wamr.tar.gz
        make check-zig PG_CONFIG=$pgc ZIG=/opt/zig/zig | tail -1
        ls -l "$($pgc --pkglibdir)/plzig.so" "$($pgc --pkglibdir)/plzig/plzig-validate"
        echo "OFFLINE BUILD: PASS"' >"$log" 2>&1 || { tail -30 "$log"; echo "OFFLINE BUILD: FAIL (log: $log)"; exit 1; }
grep -E '^(---|OFFLINE|All [0-9]+ tests)' "$log"
echo "log: $log"
