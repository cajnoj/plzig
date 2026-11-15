#!/bin/sh
# Write plzig.spec and plzig-zig-toolchain.spec from their templates, with
# the versions and pins of a source tree (packaging/versions.sh).
#
#   gen-specs.sh <source tree> <outdir> <release> "<changelog date>"
#
# <release> is the RPM Release of plzig_<major> (the toolchain package's is
# always 1: it changes only with the Zig version).  The date is in RPM
# changelog format ("Sun Nov 15 2026").
set -eu
tree=$1; out=$2; release=$3; cldate=$4
eval "$(sh "$tree/packaging/versions.sh" "$tree")"
case $release in *[!0-9A-Za-z.]* | "") echo "gen-specs.sh: bad release '$release'" >&2; exit 1 ;; esac
mkdir -p "$out"
for s in plzig plzig-zig-toolchain; do
    sed -e "s/@ZIG_VERSION@/$ZIG_VERSION/g" \
        -e "s/@ZIG_SHA256_x86_64@/$ZIG_SHA256_x86_64/g" \
        -e "s/@ZIG_SHA256_aarch64@/$ZIG_SHA256_aarch64/g" \
        -e "s/@PLZIG_VERSION@/$PLZIG_VERSION/g" \
        -e "s/@DIST_VERSION@/$DIST_VERSION/g" \
        -e "s/@RPM_VERSION@/$PKG_VERSION/g" \
        -e "s/@RPM_RELEASE@/$release/g" \
        -e "s/@TC_RELEASE@/1/g" \
        -e "s/@CHANGELOG_DATE@/$cldate/g" \
        "$tree/packaging/rpm/$s.spec.in" >"$out/$s.spec"
    if grep -n '@[A-Z_0-9]*@' "$out/$s.spec"; then
        echo "gen-specs.sh: unreplaced placeholder in $s.spec" >&2; exit 1
    fi
done
