#!/bin/sh
# Write SHA256SUMS for every release artefact in a directory
# (doc/packaging.md "Release artefacts").
#
#   packaging/release/checksums.sh <dir>
#
# Covers every regular file in <dir> and its subdirectories except SHA256SUMS
# itself and signatures (*.asc, *.sig); sorted by path, sha256sum format
# (verify with: cd <dir> && sha256sum -c SHA256SUMS).
set -eu
dir=${1:?usage: checksums.sh <dir>}
cd "$dir"
find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp ! -name '*.asc' ! -name '*.sig' ! -name '.*' |
    sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r f; do sha256sum -- "$f"; done >SHA256SUMS.tmp
mv SHA256SUMS.tmp SHA256SUMS
echo "$(wc -l <SHA256SUMS) files in $dir/SHA256SUMS"
