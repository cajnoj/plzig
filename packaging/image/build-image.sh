#!/bin/bash
# Build the evaluation images plzig/postgres:<major> locally (never pushed).
#
#   packaging/image/build-image.sh [major...]      (default: 14 15 16 17 18 19)
#
# Base: the official image postgres:<version>-bookworm (Debian 12, PGDG
# packages; the versions the test matrix uses).  Packages: the Debian 12
# build in $PLZIG_PKG_DIR (default build/packages/debian12/r1, made by
# packaging/build-packages.sh debian12).  Then packaging/image/test-image.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
pkgdir=${PLZIG_PKG_DIR:-build/packages/debian12/r1}
majors=("$@")
[ ${#majors[@]} -gt 0 ] || majors=(14 15 16 17 18 19)
eval "$(sh packaging/versions.sh)"
fail=0
for m in "${majors[@]}"; do
    case $m in
        14) v=14.25 ;; 15) v=15.20 ;; 16) v=16.16 ;; 17) v=17.12 ;; 18) v=18.7 ;; 19) v=19rc2 ;;
        *) echo "unknown major $m" >&2; exit 2 ;;
    esac
    ctx=$(mktemp -d build/image-ctx.XXXXXX)
    cp "$pkgdir"/postgresql-"$m"-plzig_*_amd64.deb "$pkgdir"/plzig-zig-toolchain_*_amd64.deb "$ctx/"
    pkgver=$(dpkg-deb -f "$ctx"/postgresql-"$m"-plzig_*_amd64.deb Version 2>/dev/null ||
             basename "$ctx"/postgresql-"$m"-plzig_*_amd64.deb | cut -d_ -f2)
    echo "=== plzig/postgres:$m (postgres:$v-bookworm, postgresql-$m-plzig $pkgver)"
    if docker build -q -f packaging/image/Dockerfile --build-arg "PG_IMAGE=postgres:$v-bookworm" \
            --build-arg "PLZIG_VERSION=$pkgver" -t "plzig/postgres:$m" "$ctx" >/dev/null; then
        packaging/image/test-image.sh "$m" || fail=1
    else
        echo "build of plzig/postgres:$m failed"; fail=1
    fi
    rm -rf "$ctx"
done
exit $fail
