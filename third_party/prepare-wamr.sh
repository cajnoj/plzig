#!/bin/sh
# Make a patched build copy of WAMR (the vendored tree stays pristine).
#   prepare-wamr.sh <wamr-src-or-empty> <destdir> <patch> [<tarball-or-empty> <sha256>]
# With a tarball (the tag's GitHub source archive), verify its pinned SHA-256
# and unpack it; without a source tree or tarball, clone the pinned tag and
# verify the pinned commit.
set -eu
src=$1; dest=$2; patch=$3; tarball=${4:-}; tarsha=${5:-}
tag=WAMR-2.4.5
commit=25bd7eb63e828e4bd242cc9b38d260b4b31c6605
repo=https://github.com/bytecodealliance/wasm-micro-runtime.git

case $dest in
    /*/*) ;;
    *) echo "prepare-wamr.sh: destination must be an absolute path below / (got '$dest')" >&2; exit 1 ;;
esac
if [ -n "$tarball" ]; then
    [ -z "$src" ] || { echo "give WAMR_SRC or WAMR_TARBALL, not both" >&2; exit 1; }
    [ -f "$tarball" ] || { echo "WAMR tarball $tarball not found" >&2; exit 1; }
    got=$(sha256sum "$tarball" | cut -d' ' -f1)
    if [ "$got" != "$tarsha" ]; then
        echo "SHA-256 mismatch for $tarball: expected $tarsha, got $got" >&2
        exit 1
    fi
    echo "verified $tarball (sha256 $tarsha)"
fi

rm -rf "$dest"
if [ -n "$tarball" ]; then
    mkdir -p "$dest"
    tar -xzf "$tarball" -C "$dest" --strip-components=1 --no-same-owner --no-same-permissions
elif [ -z "$src" ]; then
    git clone --quiet --depth 1 --branch "$tag" "$repo" "$dest"
    got=$(git -C "$dest" rev-parse HEAD)
    if [ "$got" != "$commit" ]; then
        echo "WAMR commit mismatch: expected $commit, got $got" >&2
        exit 1
    fi
    rm -rf "$dest/.git"
else
    [ -f "$src/core/version.h" ] || { echo "$src is not a WAMR tree" >&2; exit 1; }
    if [ -d "$src/.git" ] && command -v git >/dev/null 2>&1; then
        got=$(git -c safe.directory="*" -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)
        if [ "$got" != "$commit" ]; then
            echo "WAMR checkout $src is at $got, expected $commit" >&2
            exit 1
        fi
    fi
    mkdir -p "$dest"
    (cd "$src" && tar --exclude=.git -cf - .) | (cd "$dest" && tar -xf -)
fi
grep -q 'WAMR_VERSION_MAJOR 2' "$dest/core/version.h" &&
grep -q 'WAMR_VERSION_MINOR 4' "$dest/core/version.h" &&
grep -q 'WAMR_VERSION_PATCH 5' "$dest/core/version.h" || {
    echo "WAMR source is not version 2.4.5" >&2; exit 1; }
# --fuzz=0: fail loudly if upstream moved
(cd "$dest" && patch -p1 --fuzz=0 --no-backup-if-mismatch < "$patch")
