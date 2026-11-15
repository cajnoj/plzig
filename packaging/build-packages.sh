#!/bin/bash
# Build the binary packages for one target distribution, in Docker
# (doc/packaging.md).
#
#   packaging/build-packages.sh <distro> [release]
#
# <distro>: see packaging/distros.sh (el8 el9 el10 fedora45 debian12
# debian13 ubuntu22.04 ubuntu24.04 ubuntu26.04).  [release]: the package
# release (RPM Release / Debian revision), default 1.
#
# 1. Inputs, each verified against its pinned SHA-256 (Makefile): the Zig
#    tarball (vendor/zig/ or build/dl/, downloaded by `make fetch-zig` if
#    missing) and the WAMR tag tarball (vendor/ or build/dl/, downloaded if
#    missing); the PL/Zig source tarball is $PLZIG_DIST, or made by
#    `make dist` (DIST_WORKTREE=1 with PLZIG_DIST_WORKTREE=1).
# 2. Builder image plzig-pkgbuild:<distro> (network: PGDG repositories,
#    signature-checked).
# 3. The build itself in that image with --network none, using the
#    packaging scripts from the source tarball.
#
# Output: build/packages/<distro>/r<release>/ (packages, build.log,
# rpmlint.txt or lintian.txt); override with PLZIG_PKG_OUT.  PLZIG_MAJORS
# restricts the build to some of the distribution's PostgreSQL majors;
# PLZIG_LINT=0 skips rpmlint/lintian (the matrix's release-0 builds).
set -euo pipefail
cd "$(dirname "$0")/.."
. packaging/distros.sh
distro=${1:?usage: build-packages.sh <distro> [release]}
release=${2:-1}
distro_info "$distro"
# PLZIG_MAJORS: build only these majors (a subset of the distribution's)
if [ -n "${PLZIG_MAJORS:-}" ]; then
    for m in $PLZIG_MAJORS; do
        case " $MAJORS " in *" $m "*) ;; *) echo "PostgreSQL $m is not available for $distro" >&2; exit 2 ;; esac
    done
    MAJORS=$PLZIG_MAJORS
fi
eval "$(sh packaging/versions.sh)"
arch=$(uname -m)
out=${PLZIG_PKG_OUT:-build/packages/$distro/r$release}
mkdir -p build/dl "$out"
out=$(cd "$out" && pwd)

verify() {   # verify <file> <sha256>
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$got" = "$2" ] || { echo "SHA-256 mismatch for $1: expected $2, got $got" >&2; exit 1; }
}

# --- inputs
# both architectures' Zig tarballs: the source packages carry both
zigdir=build/dl/zig-$ZIG_VERSION
mkdir -p "$zigdir"
for a in x86_64 aarch64; do
    f=zig-$a-linux-$ZIG_VERSION.tar.xz
    if [ ! -f "$zigdir/$f" ]; then
        if [ -f "vendor/zig/$f" ]; then
            cp "vendor/zig/$f" "$zigdir/$f.part.$$" && mv -f "$zigdir/$f.part.$$" "$zigdir/$f"
        else
            curl --fail --location --proto '=https' --tlsv1.2 -o "$zigdir/$f.part" \
                "https://ziglang.org/download/$ZIG_VERSION/$f"
            mv "$zigdir/$f.part" "$zigdir/$f"
        fi
    fi
    sumvar=ZIG_SHA256_$a
    verify "$zigdir/$f" "${!sumvar}"
done
[ -n "$(eval echo "\${ZIG_SHA256_$arch:-}")" ] || { echo "no pinned Zig build for $arch" >&2; exit 1; }

wamrtb=vendor/WAMR-$WAMR_VERSION.tar.gz
if [ ! -f "$wamrtb" ]; then
    wamrtb=build/dl/WAMR-$WAMR_VERSION.tar.gz
    if [ ! -f "$wamrtb" ]; then
        curl --fail --location --proto '=https' --tlsv1.2 -o "$wamrtb.part" \
            "https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-$WAMR_VERSION.tar.gz"
        mv "$wamrtb.part" "$wamrtb"
    fi
fi
verify "$wamrtb" "$WAMR_TARBALL_SHA256"

dist=${PLZIG_DIST:-}
if [ -z "$dist" ]; then
    dist=$(make -s dist PG_CONFIG=/bin/false DIST_WORKTREE="${PLZIG_DIST_WORKTREE:-0}" | tail -1)
fi
[ -f "$dist" ] || { echo "no source tarball ($dist)" >&2; exit 1; }

# --- builder image
img=plzig-pkgbuild:$distro${PLZIG_MAJORS:+-$(echo "$MAJORS" | tr ' ' '-')}
docker build -q -f "packaging/$FAMILY/Dockerfile" --build-arg "BASE=$BASE" \
    --build-arg "PG_MAJORS=$MAJORS" -t "$img" packaging >/dev/null

# --- the build, offline
log=$out/build.log
echo "building $(basename "$dist") for $distro ($BASE), PostgreSQL $MAJORS, release $release -> $out"
rm -f "$out"/*.rpm "$out"/*.deb "$out"/*.ddeb "$out"/*.dsc "$out"/*.tar.* "$out"/*.changes "$out"/*.buildinfo
set +e
docker run --rm --network none --security-opt label=disable \
    -v "$(cd "$(dirname "$dist")" && pwd)/$(basename "$dist"):/in/$(basename "$dist"):ro" \
    -v "$PWD/$zigdir:/in/zig:ro" \
    -v "$PWD/$wamrtb:/in/$(basename "$wamrtb"):ro" \
    -v "$out:/out" \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "PLZIG_LINT=${PLZIG_LINT:-1}" \
    "$img" bash -c '
        set -e
        mkdir /tmp/plzig-src
        tar -xzf "$1" -C /tmp/plzig-src
        rc=0
        bash /tmp/plzig-src/plzig-*/packaging/'"$FAMILY"'/build.sh "$@" || rc=$?
        chown -R "$HOST_UID:$HOST_GID" /out
        exit $rc' sh \
    "/in/$(basename "$dist")" /in/zig "/in/$(basename "$wamrtb")" \
    /out "$release" $MAJORS >"$log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
    tail -40 "$log"
    echo "BUILD FAILED for $distro (log: $log)"
    exit 1
fi
echo "built for $distro: $(cd "$out" && ls *.rpm *.deb 2>/dev/null | tr '\n' ' ')"
