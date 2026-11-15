#!/bin/bash
# Installed-package test for one distribution and PostgreSQL major
# (doc/packaging.md "Package tests"): a fresh container of the distribution,
# only the built packages (plus PGDG's PostgreSQL and test tooling), then
# packaging/pkgtest-in-container.sh: dependency check, install, compiled-in
# toolchain path and hardening, upgrade from an earlier build, sandbox,
# the regression suite, extension upgrade scripts, removal.
#
#   packaging/test-packages.sh <distro> <major>
#
# Environment:
#   PLZIG_PKG_DIR    packages under test (default build/packages/<distro>/r1)
#   PLZIG_PREV_DIR   earlier build for the upgrade test (default
#                    build/packages/<distro>/r0 if it exists; "" = none)
#   PLZIG_DIST       the source tarball the packages were built from (only
#                    its tests are used; default: the one named by the
#                    packages' version in build/dist/)
#   PLZIG_TEST_LOGDIR  logs (default build/package-tests); the log is
#                    <logdir>/<distro>-<major>.log
#
# The containers share this machine's kernel, so the compiler sandbox's
# default (require: Landlock ABI >= 6, seccomp) is satisfied whatever the
# distribution's own kernel would offer.  Exit status non-zero on failure.
set -uo pipefail
cd "$(dirname "$0")/.."
. packaging/distros.sh
distro=${1:?usage: test-packages.sh <distro> <major>}
major=${2:?usage: test-packages.sh <distro> <major>}
distro_info "$distro" || exit 2
case " $MAJORS " in *" $major "*) ;; *) echo "PostgreSQL $major is not built for $distro (PGDG: $MAJORS)" >&2; exit 2 ;; esac
pkgdir=${PLZIG_PKG_DIR:-build/packages/$distro/r1}
prevdir=${PLZIG_PREV_DIR-build/packages/$distro/r0}
logdir=${PLZIG_TEST_LOGDIR:-build/package-tests}
mkdir -p "$logdir"
log=$logdir/$distro-$major.log
[ -d "$pkgdir" ] || { echo "no packages in $pkgdir (packaging/build-packages.sh $distro)" >&2; exit 2; }
pkgdir=$(cd "$pkgdir" && pwd)

dist=${PLZIG_DIST:-}
if [ -z "$dist" ]; then
    # the source tarball whose version the packages carry
    v=$(ls "$pkgdir" | sed -n 's/^plzig-zig-toolchain.*//; s/^plzig_[0-9]*-\(.*\)-[^-]*\.src\.rpm$/\1/p; s/^plzig_\(.*\)\.orig\.tar\.gz$/\1/p' | head -1)
    dist=build/dist/plzig-${v/\~/-}.tar.gz
fi
[ -f "$dist" ] || { echo "source tarball $dist not found (PLZIG_DIST)" >&2; exit 2; }

mounts=(-v "$pkgdir:/pkgs:ro" -v "$(cd "$(dirname "$dist")" && pwd)/$(basename "$dist"):/in/plzig.tar.gz:ro"
        -v "$PWD/packaging:/packaging:ro")
if [ -n "$prevdir" ] && [ -d "$prevdir" ]; then
    mounts+=(-v "$(cd "$prevdir" && pwd):/prev:ro")
fi

echo "testing $distro ($BASE) PostgreSQL $major: $pkgdir${prevdir:+ (upgrade from $prevdir)} -> $log"
docker run --rm --init --security-opt label=disable "${mounts[@]}" "$BASE" \
    bash /packaging/pkgtest-in-container.sh "$FAMILY" "$major" >"$log" 2>&1
rc=$?
grep -E '^(STEP|RESULT)' "$log"
[ $rc -eq 0 ] && grep -q '^RESULT: PASS' "$log"
