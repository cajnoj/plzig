#!/bin/sh
# Install the pruned Zig toolchain of the plzig-zig-toolchain package
# (doc/packaging.md "The Zig toolchain package").
#
#   install-pruned.sh <unpacked official Zig tarball> <destination directory>
#
# Copies, unmodified, the compiler binary and the parts of lib/ that PL/Zig
# needs (wasm32-freestanding modules, the native source validator, the
# validator/SDK unit tests): lib/std, lib/compiler_rt, lib/compiler, lib/c and
# the top-level files of lib/ -- all MIT-licensed Zig code (some ported from
# musl, also MIT).  Left out: lib/libc, lib/include, lib/libcxx,
# lib/libcxxabi, lib/libunwind, lib/libtsan (C/C++ library sources and headers
# under LGPL, GPL with syscall note, APSL and other licenses, needed only to
# compile C or to link a libc), lib/docs, lib/build-web, lib/init, lib/lldb.
# The compiler binary is not stripped or otherwise changed, so its SHA-256
# is that of the official build (usable for plzig.zig_sha256).
set -eu
src=$1; dest=$2
[ -f "$src/zig" ] && [ -f "$src/lib/std/std.zig" ] && [ -f "$src/LICENSE" ] || {
    echo "install-pruned.sh: $src is not an unpacked Zig tarball" >&2; exit 1; }
case $dest in /*/*) ;; *) echo "install-pruned.sh: destination must be absolute ($dest)" >&2; exit 1 ;; esac
[ ! -e "$dest" ] || { echo "install-pruned.sh: $dest exists" >&2; exit 1; }

mkdir -p "$dest/lib"
cp -p "$src/zig" "$dest/zig"
for d in std compiler_rt compiler c; do
    cp -R "$src/lib/$d" "$dest/lib/$d"
done
for f in "$src"/lib/*; do
    [ -f "$f" ] && cp -p "$f" "$dest/lib/"
done
# PL/Zig refuses a compiler or lib directory writable by group or others
chmod -R u+rwX,go+rX,go-w "$dest"
chmod 0755 "$dest/zig"
find "$dest/lib" -type f -exec chmod 0644 {} +
# Upstream's empty test-data directories carry nothing
find "$dest/lib" -depth -type d -empty -delete
