#!/bin/bash
# Assemble a local release directory (doc/packaging.md "Release
# artefacts"): the source tarball, the built packages, an SPDX SBOM, a
# SHA256SUMS file and, if PLZIG_SIGNING_KEY is set, its signature.  Nothing
# is uploaded or published.
#
#   packaging/release/make-release.sh <outdir>
#
# Environment: PLZIG_DIST (the source tarball; default the newest in
# build/dist/), PLZIG_PKG_GLOB (default build/packages/*/r1: the
# directories whose .rpm/.deb files are included, debug packages left out),
# PLZIG_SIGNING_KEY (see sign.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: make-release.sh <outdir>}
cd "$here/../.."
dist=${PLZIG_DIST:-$(ls -t build/dist/plzig-*.tar.gz | head -1)}
[ -f "$dist" ] || { echo "no source tarball" >&2; exit 1; }
mkdir -p "$out"
cp "$dist" "$out/"
n=0
for d in ${PLZIG_PKG_GLOB:-build/packages/*/r1}; do
    [ -d "$d" ] || continue
    distro=$(basename "$(dirname "$d")")
    mkdir -p "$out/$distro"
    for f in "$d"/*.rpm "$d"/*.deb; do
        [ -f "$f" ] || continue
        case $(basename "$f") in *debuginfo*|*debugsource*|*-dbgsym_*) continue ;; esac
        cp "$f" "$out/$distro/"; n=$((n + 1))
    done
done
echo "$n packages"
tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
tar -xzf "$dist" -C "$tree"
python3 -I "$here/sbom.py" "$out" "$(echo "$tree"/plzig-*)"
sh "$here/checksums.sh" "$out"
sh "$here/sign.sh" "$out"
