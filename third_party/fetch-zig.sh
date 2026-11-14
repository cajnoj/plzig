#!/bin/sh
# Optional helper (make fetch-zig / make install-zig): obtain the pinned Zig
# tarball, verify its SHA-256 and, if a prefix is given, unpack it there.
#   fetch-zig.sh <tarball-or-empty> <url> <sha256> <download-path> <prefix-or-empty> <dirname>
# Never part of `make` or `make install`; the PostgreSQL server never
# downloads anything.
set -eu
tarball=$1; url=$2; sha=$3; dl=$4; prefix=$5; dirname=$6

if [ -z "$sha" ]; then
    echo "no pinned Zig checksum for architecture $(uname -m) (x86_64 and aarch64 only)" >&2
    exit 1
fi

if [ -z "$tarball" ]; then
    tarball=$dl
    if [ ! -f "$tarball" ]; then
        mkdir -p "$(dirname "$tarball")"
        echo "downloading $url"
        curl --fail --location --proto '=https' --tlsv1.2 -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    fi
fi
[ -f "$tarball" ] || { echo "Zig tarball $tarball not found" >&2; exit 1; }

got=$(sha256sum "$tarball" | cut -d' ' -f1)
if [ "$got" != "$sha" ]; then
    echo "SHA-256 mismatch for $tarball: expected $sha, got $got" >&2
    exit 1
fi
echo "verified $tarball (sha256 $sha)"

[ -n "$prefix" ] || exit 0

case $prefix in
    /*) ;;
    *) echo "ZIG_PREFIX must be an absolute path (got '$prefix')" >&2; exit 1 ;;
esac
prefix=${prefix%/}
# never overwrite or delete anything at a user-chosen location
if [ -e "$prefix" ] || [ -L "$prefix" ]; then
    if [ -d "$prefix" ] && [ ! -L "$prefix" ] && [ -z "$(ls -A "$prefix")" ]; then
        rmdir "$prefix"
    else
        echo "$prefix already exists; refusing to overwrite it" >&2
        exit 1
    fi
fi
parent=$(dirname "$prefix")
mkdir -p "$parent"
tmp=$(mktemp -d "$parent/.plzig-zig-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
tar -xJf "$tarball" -C "$tmp" --no-same-owner --no-same-permissions
[ -f "$tmp/$dirname/zig" ] && [ -f "$tmp/$dirname/lib/std/std.zig" ] || {
    echo "unexpected tarball layout (no $dirname/zig or $dirname/lib/std/std.zig)" >&2
    exit 1
}
# PL/Zig refuses a compiler or lib directory writable by group or others
chmod -R u+rwX,go+rX,go-w "$tmp/$dirname"
mv "$tmp/$dirname" "$prefix"
echo "installed Zig to $prefix"
echo "set in postgresql.conf:  plzig.zig_path = '$prefix/zig'   (then reload)"
