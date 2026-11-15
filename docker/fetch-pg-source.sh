#!/bin/sh
# Fetch the PostgreSQL source tree of a tested version into the vendor/
# directory the Docker scripts expect (docker/run-all.sh, run-fuzz.sh:
# pgsrc()), for machines without the vendored trees, e.g. CI runners.
# Clones the release tag and verifies the pinned commit.
#   docker/fetch-pg-source.sh <version>       (14.25 15.20 16.16 17.12 18.7 19rc2)
# Does nothing if the directory already exists.
set -eu
cd "$(dirname "$0")/.."
v=${1:?usage: docker/fetch-pg-source.sh <version>}
case $v in
    14.25) dir=vendor/pg-REL_14_25; tag=REL_14_25; commit=9adcf5f8847e0f485a390b1d3ea40688068d71bd ;;
    15.20) dir=vendor/pg-REL_15_20; tag=REL_15_20; commit=6a84c5137e820f46f0123276f546eec5b9a56e70 ;;
    16.16) dir=vendor/pg-REL_16_16; tag=REL_16_16; commit=c0534eb02de050ac1035ad7b3ad7c3f02980f153 ;;
    17.12) dir=vendor/pg-REL_17_12; tag=REL_17_12; commit=702b3dc86d35bcc08c8e23cffa3c4d9fe9d32c85 ;;
    18.7) dir=vendor/postgres; tag=REL_18_7; commit=f5c41f6681c910b3f69951bf6fb97c6d74605d25 ;;
    19rc2) dir=vendor/pg-REL_19_RC2; tag=REL_19_RC2; commit=dffcca2e3c81178c64d4c1f44543a3507d0b7508 ;;
    *) echo "fetch-pg-source.sh: unknown version $v" >&2; exit 1 ;;
esac
repo=https://github.com/postgres/postgres.git
if [ -e "$dir" ]; then
    echo "$dir exists, not fetched"
    exit 0
fi
mkdir -p vendor
tmp=$dir.tmp.$$
rm -rf "$tmp"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$repo" "$tmp"
got=$(git -C "$tmp" rev-parse HEAD)
if [ "$got" != "$commit" ]; then
    echo "PostgreSQL $tag: expected commit $commit, got $got" >&2
    rm -rf "$tmp"
    exit 1
fi
mv "$tmp" "$dir"
echo "$dir: PostgreSQL $tag at $commit"
