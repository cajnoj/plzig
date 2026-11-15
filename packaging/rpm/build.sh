#!/bin/bash
# Build the RPMs inside a builder container (packaging/rpm/Dockerfile),
# normally started by packaging/build-packages.sh with --network none: the
# build needs nothing but its three inputs.
#
#   build.sh <plzig dist tarball> <dir with both Zig tarballs> <WAMR tarball> <outdir> <release> <major>...
#
# Builds plzig-zig-toolchain, installs it (it is the build's Zig), then
# plzig_<major> for every given PostgreSQL major, and runs rpmlint on the
# results where rpmlint is installed.  RPMs and SRPMs go to <outdir>.
set -euo pipefail
dist=$1; zigdir=$2; wamrtb=$3; out=$4; release=$5; shift 5
majors=("$@")
here=$(cd "$(dirname "$0")" && pwd)

top=$HOME/rpmbuild
mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS} "$out"
src=$(mktemp -d)
tar -xzf "$dist" -C "$src"
tree=$(echo "$src"/plzig-*)
eval "$(sh "$tree/packaging/versions.sh" "$tree")"
# reproducible: every timestamp from the source tarball (HEAD's commit time)
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(stat -c %Y "$tree/Makefile")
cldate=$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH" '+%a %b %d %Y')

sh "$tree/packaging/rpm/gen-specs.sh" "$tree" "$top/SPECS" "$release" "$cldate"
cp "$dist" "$wamrtb" "$top/SOURCES/"
cp "$zigdir"/zig-x86_64-linux-"$ZIG_VERSION".tar.xz "$zigdir"/zig-aarch64-linux-"$ZIG_VERSION".tar.xz "$top/SOURCES/"
cp "$tree"/packaging/zig-toolchain/{NOTICE,install-pruned.sh} "$top/SOURCES/"
cp "$tree"/packaging/zig-toolchain/licenses/* "$top/SOURCES/"

rpmopts=(--define "_topdir $top" --define "use_source_date_epoch_as_buildtime 1"
         --define "clamp_mtime_to_source_date_epoch 1")

echo "=== plzig-zig-toolchain $ZIG_VERSION"
rpmbuild "${rpmopts[@]}" -ba "$top/SPECS/plzig-zig-toolchain.spec"
tc=$(ls "$top"/RPMS/*/plzig-zig-toolchain-"$ZIG_VERSION"-*.rpm)
# our own unsigned build (rpm 6, Fedora 45, refuses unsigned packages by default)
rpm -i --nosignature "$tc"

for v in "${majors[@]}"; do
    echo "=== plzig_$v $PKG_VERSION-$release"
    # the SRPM carries the spec rendered for its major (plzig_<major>.spec),
    # so that `rpmbuild --rebuild` needs no --define
    { echo "%{!?pgmajorversion:%global pgmajorversion $v}"; cat "$top/SPECS/plzig.spec"; } >"$top/SPECS/plzig_$v.spec"
    rpmbuild "${rpmopts[@]}" --define "pgmajorversion $v" -ba "$top/SPECS/plzig_$v.spec"
done

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp {} "$out/" \;
if [ "${PLZIG_LINT:-1}" = 0 ]; then
    echo "=== rpmlint: skipped (PLZIG_LINT=0)" | tee "$out/rpmlint.txt"
elif command -v rpmlint >/dev/null 2>&1; then
    echo "=== rpmlint"
    # rpmlint 2 (Fedora) takes the filters of plzig.rpmlintrc, whose every
    # entry is justified there; rpmlint 1 (EL 8, EL 9) runs unfiltered
    lintopts=()
    case $(rpmlint --version 2>/dev/null) in
        2.*|*" 2."*) lintopts=(-r "$here/plzig.rpmlintrc") ;;
    esac
    # the per-major specs (plzig.spec itself needs --define pgmajorversion)
    lint=$(mktemp -d)
    cp "$top/SPECS/plzig-zig-toolchain.spec" "$top/SPECS/plzig_${majors[0]}.spec" "$lint/"
    { rpmlint --version; rpmlint "${lintopts[@]}" "$out"/*.rpm "$lint"/*.spec; } 2>&1 | tee "$out/rpmlint.txt" || true
else
    echo "=== rpmlint: not installed on this distribution" | tee "$out/rpmlint.txt"
fi
ls -l "$out"
