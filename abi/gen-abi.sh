#!/bin/sh
# Generate the host/guest ABI definitions from abi/plzig-abi.table (the
# single source; its header describes the format and what is generated).
#
#   sh abi/gen-abi.sh update <source tree>   rewrite src/plzig_abi.h and the
#                                            marked regions of zig/sdk/plzig.zig
#   sh abi/gen-abi.sh check <source tree>    exit 1 (with a diff) if either is
#                                            not exactly what the table
#                                            generates, or if doc/abi.md lacks
#                                            an import's row or signature
#
# Needs only POSIX sh and awk, cmp and diff (no build of anything): the
# Makefile runs `check` in every build (`make check-abi`) and `update` as
# `make abi`.  That the C host functions and the SDK's test stand-in have the
# table's types is checked by the compilers (src/plzig_host.c,
# fuzz/loader/hoststubs.c, the generated Zig region "import-types").
set -eu
mode=${1:-}
tree=${2:-}
case $mode in update|check) ;; *) echo "usage: sh abi/gen-abi.sh update|check <source tree>" >&2; exit 2 ;; esac
[ -n "$tree" ] && [ -f "$tree/abi/plzig-abi.table" ] || { echo "gen-abi.sh: $tree is not a PL/Zig source tree" >&2; exit 2; }
awk=${AWK:-awk}
table=$tree/abi/plzig-abi.table
gen=$tree/abi/gen-abi.awk
work=$(mktemp -d "${TMPDIR:-/tmp}/plzig-abi.XXXXXX")
trap 'rm -rf "$work"' EXIT
LC_ALL=C
export LC_ALL

"$awk" -v table="$table" -v mode=c -f "$gen" >"$work/plzig_abi.h"
"$awk" -v table="$table" -v mode=zig -f "$gen" "$tree/zig/sdk/plzig.zig" >"$work/plzig.zig"

stale=0
for f in src/plzig_abi.h zig/sdk/plzig.zig; do
    new=$work/$(basename "$f")
    if [ -f "$tree/$f" ] && cmp -s "$new" "$tree/$f"; then
        continue
    fi
    if [ "$mode" = update ]; then
        cp "$new" "$tree/$f.abi-tmp" && mv "$tree/$f.abi-tmp" "$tree/$f"
        echo "gen-abi.sh: updated $f"
    else
        diff -u "$tree/$f" "$new" | sed 's/^/    /' | head -60 || true
        echo "gen-abi.sh: $f is not what abi/plzig-abi.table generates (run: make abi)" >&2
        stale=1
    fi
done

# doc/abi.md lists every import with its signature string (prose: checked
# for presence only, never rewritten)
if ! "$awk" -v table="$table" -v mode=doc -f "$gen" "$tree/doc/abi.md" >"$work/doc.txt"; then
    cat "$work/doc.txt" >&2
    echo "gen-abi.sh: doc/abi.md does not describe the imports of abi/plzig-abi.table" >&2
    stale=1
fi
[ $stale = 0 ] || exit 1
[ "$mode" = check ] && echo "gen-abi.sh: src/plzig_abi.h, zig/sdk/plzig.zig and doc/abi.md agree with abi/plzig-abi.table"
exit 0
