#!/bin/bash
# Regenerate the seed modules of the loader fuzz target (fuzz/loader/corpus)
# from the bodies in fuzz/loader/seeds-src, with exactly the backend's
# compiler flags (plzig_zig_flags in src/plzig_build.c) and the SDK.  Every
# body is the body of `fn(a int) RETURNS int STRICT`, the signature the
# harness calls.
#   fuzz/loader/make-seeds.sh /abs/path/to/zig-0.17.1/zig
set -eu
zig=$1
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src" "$tmp/sdk"
cp "$root/zig/sdk/plzig.zig" "$root/zig/sdk/root.zig" "$tmp/sdk/"
for f in "$here"/seeds-src/*.zig; do
    name=$(basename "$f" .zig)
    {
        printf 'const plzig = @import("plzig"); const std = plzig.std; pub fn call(@"a": i32) anyerror!?i32 { _ = &@"a";\n'
        cat "$f"
        printf '\n}\n'
    } > "$tmp/src/user.zig"
    (cd "$tmp" && "$zig" build-exe --global-cache-dir "$tmp/gc" --cache-dir .zig-cache \
        --color off -fno-reference-trace -target wasm32-freestanding -mcpu mvp \
        -O ReleaseSafe -fstrip -fno-entry -fsingle-threaded --stack 262144 \
        --export=plzig_abi_version --export=plzig_begin --export=plzig_alloc --export=plzig_call \
        --dep plzig --dep user -Mroot=sdk/root.zig --dep plzig -Muser=src/user.zig \
        -Mplzig=sdk/plzig.zig --name plzig_module -femit-bin=out.wasm)
    cp "$tmp/out.wasm" "$here/corpus/$name.wasm"
    echo "$name.wasm: $(stat -c %s "$here/corpus/$name.wasm") bytes"
done
