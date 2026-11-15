#!/bin/sh
# Reproducible source tarball (make dist; doc/packaging.md "Source tarball").
#
#   packaging/make-dist.sh <outdir> head|worktree
#
# head:     the committed tree of HEAD (git archive, so .gitattributes
#           export-ignore applies).
# worktree: the working tree's tracked and untracked, not ignored, files
#           (export-ignore applied the same way).  For testing uncommitted
#           changes; never for a release.
#
# The version is PLZIG_VERSION of the packed tree's own Makefile.  A release
# version (no "-" pre-release part) requires mode head and HEAD tagged
# v<version>.  A pre-release version gets ".<commit date, UTC, YYYYMMDD>.g<12
# hex of the commit>" appended (1.0.0-dev.20261115.g78ba89028b51), and in
# worktree mode ".dirty.<8 hex digest of the files>" if they differ from HEAD's.
#
# Both modes pack the same way: GNU tar with sorted names, owner/group 0,
# modes 0644/0755 (executable bit from git or the file), every mtime set to
# HEAD's commit time, pax headers without atime/ctime, then gzip -n -9.  The
# same tree therefore gives the same bytes (for the same tar and gzip
# implementations).  The tarball carries its version in .dist-version.
# Writes <outdir>/plzig-<version>.tar.gz and <outdir>/plzig-<version>.tar.gz.sha256
# and prints the tarball's path last.
set -eu
outdir=$1; mode=$2
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

command -v git >/dev/null || { echo "make dist needs git" >&2; exit 1; }
git rev-parse --verify -q HEAD >/dev/null || { echo "make dist: not a git checkout with commits" >&2; exit 1; }
tar --version 2>/dev/null | grep -q 'GNU tar' || { echo "make dist needs GNU tar" >&2; exit 1; }
commit=$(git rev-parse HEAD)
epoch=$(git log -1 --format=%ct HEAD)
day=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d HEAD)

case $outdir in /*) ;; *) outdir=$here/$outdir ;; esac
mkdir -p "$outdir"
work=$(mktemp -d "$outdir/.dist.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
mkdir "$work/tree" "$work/head"
git archive --format=tar HEAD | tar -xf - -C "$work/head"

case $mode in
    head)
        mv "$work/head" "$work/tree.tmp" && rmdir "$work/tree" && mv "$work/tree.tmp" "$work/tree"
        ;;
    worktree)
        # tracked files that still exist, plus untracked files that are not ignored
        git ls-files -z --cached --others --exclude-standard |
            xargs -0 -r sh -c 'for f; do [ -f "$f" ] && [ ! -L "$f" ] && printf "%s\n" "$f"; done' sh |
            LC_ALL=C sort -u >"$work/files.all"
        # export-ignore as git archive applies it
        git check-attr --stdin export-ignore <"$work/files.all" |
            awk -F': export-ignore: ' '$2 != "set" { print $1 }' >"$work/files"
        tar -cf - -T "$work/files" | tar -xf - -C "$work/tree"
        ;;
    *) echo "make dist: mode must be head or worktree" >&2; exit 1 ;;
esac

# the benchmark suite installs PL/Python and PL/Perl and must never be shipped
if [ -e "$work/tree/bench" ] || [ -e "$work/tree/.github" ]; then
    echo "make dist: bench/ or .github/ would be packed (.gitattributes export-ignore)" >&2
    exit 1
fi
version=$(sed -n 's/^PLZIG_VERSION := \(.*\)$/\1/p' "$work/tree/Makefile")
case $version in
    *[!0-9A-Za-z.-]* | "") echo "make dist: no valid PLZIG_VERSION line in the Makefile of the packed tree ('$version')" >&2; exit 1 ;;
esac
case $version in
    *-*) distver="$version.$day.g$(printf %.12s "$commit")" ;;
    *)
        if [ "$mode" != head ] || [ "$(git tag --points-at HEAD | grep -cx "v$version")" != 1 ]; then
            echo "make dist: PLZIG_VERSION $version is a release version: needs mode head and HEAD tagged v$version" >&2
            echo "(a tree after a release carries the next version with a -dev suffix)" >&2
            exit 1
        fi
        distver=$version
        ;;
esac
if [ "$mode" = worktree ] && ! diff -r "$work/head" "$work/tree" >/dev/null 2>&1; then
    # a short digest of the files, so that different uncommitted states get
    # different names
    h=$(cd "$work/tree" && find . -type f | LC_ALL=C sort | xargs -d '\n' sha256sum | sha256sum | cut -c1-8)
    distver=$distver.dirty.$h
fi
rm -rf "$work/head"
name=plzig-$distver
mv "$work/tree" "$work/$name"

# the version the tarball was made as, for packaging scripts
printf '%s\n' "$distver" >"$work/$name/.dist-version"

# normalise modes: 0755 for executables and directories, 0644 otherwise
find "$work/$name" -type d -exec chmod 0755 {} +
find "$work/$name" -type f -perm -u+x -exec chmod 0755 {} +
find "$work/$name" -type f ! -perm -u+x -exec chmod 0644 {} +

tarball=$outdir/$name.tar.gz
(cd "$work" &&
 LC_ALL=C tar --sort=name --format=pax \
     --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
     --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
     -cf - "$name") | gzip -n -9 >"$tarball.tmp"
mv "$tarball.tmp" "$tarball"
(cd "$outdir" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "commit $commit, mode $mode, version $distver"
cat "$outdir/$name.tar.gz.sha256"
echo "$tarball"
