#!/bin/bash
# Build the Debian/Ubuntu packages inside a builder container
# (packaging/deb/Dockerfile), normally started by packaging/build-packages.sh
# with --network none: the build needs nothing but its inputs.
#
#   build.sh <plzig dist tarball> <dir with both Zig tarballs> <WAMR tarball> <outdir> <revision> <major>...
#
# 1. Source package plzig-zig-toolchain (orig: NOTICE, licenses,
#    install-pruned.sh, the compiler checksums; components orig-amd64 and
#    orig-arm64: the unmodified upstream tarballs), built and installed (it is
#    the build's Zig).
# 2. Source package plzig (orig: the dist tarball; component orig-wamr: the
#    WAMR tag tarball), postgresql-<major>-plzig for each given major.
# 3. lintian (pedantic, info tags) on both .changes files: lintian.txt.
set -euo pipefail
dist=$1; zigdir=$2; wamrtb=$3; out=$4; rev=$5; shift 5
majors=("$@")
export DEB_BUILD_OPTIONS="parallel=$(nproc)"
mkdir -p "$out"
work=$(mktemp -d)
src=$work/src
mkdir "$src"
tar -xzf "$dist" -C "$src"
tree=$(echo "$src"/plzig-*)
eval "$(sh "$tree/packaging/versions.sh" "$tree")"
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(stat -c %Y "$tree/Makefile")
chdate=$(LC_ALL=C date -u -R -d "@$SOURCE_DATE_EPOCH")
. /etc/os-release

changelog() {   # changelog <file> <source> <version> <text>
    printf '%s (%s) UNRELEASED; urgency=medium\n\n  * %s\n\n -- PL/Zig maintainers <plzig@invalid>  %s\n' \
        "$2" "$3" "$4" "$chdate" >"$1"
}
dtar() {   # deterministic tarball: dtar <output> <dir> <name in tarball> <compressor>
    (cd "$2/.." && LC_ALL=C tar --sort=name --format=pax \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
        --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
        --transform "s,^$(basename "$2"),$3," -cf - "$(basename "$2")") | $4 >"$1"
}

# ---------------------------------------------------------------- toolchain
tcv=$ZIG_VERSION
tcw=$work/tc
mkdir -p "$tcw/plzig-zig-toolchain-$tcv"
o=$tcw/plzig-zig-toolchain-$tcv
cp "$tree/packaging/zig-toolchain/NOTICE" "$tree/packaging/zig-toolchain/install-pruned.sh" "$o/"
cp -r "$tree/packaging/zig-toolchain/licenses" "$o/"
: >"$o/zig.sha256sums"
for pair in amd64:x86_64 arm64:aarch64; do
    darch=${pair%%:*}; zarch=${pair#*:}
    tb=$zigdir/zig-$zarch-linux-$tcv.tar.xz
    sumvar=ZIG_SHA256_$zarch
    echo "${!sumvar}  $tb" | sha256sum -c -
    cp "$tb" "$tcw/plzig-zig-toolchain_$tcv.orig-$darch.tar.xz"
    mkdir "$tcw/x-$darch"
    tar -xJf "$tb" -C "$tcw/x-$darch" --strip-components=1 "zig-$zarch-linux-$tcv/zig"
    (cd "$tcw/x-$darch" && printf '%s  %s/zig\n' "$(sha256sum zig | cut -d' ' -f1)" "$darch") >>"$o/zig.sha256sums"
    rm -rf "$tcw/x-$darch"
done
dtar "$tcw/plzig-zig-toolchain_$tcv.orig.tar.xz" "$o" "plzig-zig-toolchain-$tcv" "xz -9"
for darch in amd64 arm64; do
    mkdir "$o/$darch"
    tar -xJf "$tcw/plzig-zig-toolchain_$tcv.orig-$darch.tar.xz" -C "$o/$darch" --strip-components=1
done
cp -r "$tree/packaging/zig-toolchain/debian" "$o/debian"
changelog "$o/debian/changelog" plzig-zig-toolchain "$tcv-1" \
    "Zig $tcv for PL/Zig $PLZIG_VERSION (generated, not a release)."
echo "=== plzig-zig-toolchain $tcv-1"
(cd "$o" && dpkg-buildpackage -us -uc -sa)
apt-get install -y --no-install-recommends "$tcw"/plzig-zig-toolchain_"$tcv"-1_*.deb >/dev/null

# ---------------------------------------------------------------- plzig
pw=$work/plzig
mkdir -p "$pw"
cp "$dist" "$pw/plzig_$PKG_VERSION.orig.tar.gz"
cp "$wamrtb" "$pw/plzig_$PKG_VERSION.orig-wamr.tar.gz"
tar -xzf "$dist" -C "$pw"
p=$pw/plzig-$DIST_VERSION
mkdir "$p/wamr"
tar -xzf "$wamrtb" -C "$p/wamr" --strip-components=1
changelog "$p/debian/changelog" plzig "$PKG_VERSION-$rev" \
    "Snapshot of PL/Zig $PLZIG_VERSION (generated, not a release)."
printf '%s\n' "${majors[@]}" >/etc/postgresql-common/supported_versions
(cd "$p" && pg_buildext updatecontrol)
echo "=== plzig $PKG_VERSION-$rev for PostgreSQL $(cd "$p" && pg_buildext supported-versions | tr '\n' ' ')"
(cd "$p" && dpkg-buildpackage -us -uc -sa)

# ---------------------------------------------------------------- results
for d in "$tcw" "$pw"; do
    find "$d" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.ddeb' -o -name '*.dsc' \
        -o -name '*.tar.*' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp {} "$out/" \;
done
if [ "${PLZIG_LINT:-1}" = 0 ]; then
    echo "=== lintian: skipped (PLZIG_LINT=0)" | tee "$out/lintian.txt"
    ls -l "$out"
    exit 0
fi
echo "=== lintian $(lintian --version)"
{
    for c in "$out"/plzig-zig-toolchain_*.changes "$out"/plzig_*.changes; do
        echo "--- $(basename "$c")"
        lintian --pedantic --info --display-info --display-experimental "$c" 2>&1 || true
    done
} | tee "$out/lintian.txt"
ls -l "$out"
