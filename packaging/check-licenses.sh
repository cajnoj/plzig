#!/bin/bash
# License and attribution checks (doc/packaging.md "License material").
# Every check compares against a reference: the PL/Zig source tree (or an
# unpacked `make dist` tarball), whose own license files are in turn pinned
# by packaging/license-files.sha256 and compared with the upstream files.
#
#   check-licenses.sh source <tree> [--wamr <WAMR tarball>] [--zig <Zig tarball>]...
#       The tree carries every license file; the third-party texts have
#       their pinned checksums; the notices name the pinned WAMR and Zig
#       versions; the license expressions of the packaging files agree.
#       With the upstream tarballs: LICENSES/ is byte-identical to the
#       LICENSE files of WAMR and of Zig.
#   check-licenses.sh wamr-build <cmake build dir> <prepared WAMR tree> <tree>
#       After a build: the copyright lines of every WAMR file the compiler
#       read (from its dependency files) are exactly the ones listed in
#       THIRD-PARTY-NOTICES and debian/copyright, and the patched file
#       carries the modification notice.
#   check-licenses.sh plzig <dir> <tree>
#       <dir> holds what a PL/Zig binary artifact must carry: LICENSE,
#       THIRD-PARTY-NOTICES and the two texts of LICENSES/ (in <dir> or in
#       <dir>/LICENSES), byte-identical to the tree's.
#   check-licenses.sh toolchain <dir> <tree>
#       <dir> holds what the Zig toolchain package must carry: NOTICE, Zig's
#       LICENSE and the four component license texts, byte-identical.
#   check-licenses.sh copyright <file> <tree> plzig|toolchain
#       A Debian copyright file is the tree's.
#   check-licenses.sh debugsource <dir> <tree>
#       The WAMR sources of a debugsource package: the patched file carries
#       the modification notice and no file has a copyright line that
#       THIRD-PARTY-NOTICES does not list.
#   check-licenses.sh selftest <tree>
#       Proves that the checks above notice a missing, changed or truncated
#       license file and an unlisted copyright line.
#
# Files compressed by the packaging tools (name.gz) are compared
# uncompressed.  Prints one line per check; exit status 1 if any failed.
set -uo pipefail
fails=0
ok() { echo "  ok   - $1"; }
no() { echo "  FAIL - $1${2:+: $2}"; fails=$((fails + 1)); }
finish() {
    if [ $fails -eq 0 ]; then echo "LICENSES $1: PASS"; exit 0; fi
    echo "LICENSES $1: FAIL ($fails)"; exit 1
}
for tool in cmp diff sha256sum gzip tar find sed grep; do
    command -v "$tool" >/dev/null || { echo "check-licenses.sh: $tool is not installed" >&2; exit 2; }
done
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

PLZIG_FILES="LICENSE THIRD-PARTY-NOTICES"
PLZIG_TEXTS="Apache-2.0-WITH-LLVM-exception.txt MIT-Zig.txt"
TC_TEXTS="LLVM-LICENSE.TXT musl-COPYRIGHT.txt zlib-LICENSE.txt zstd-LICENSE.txt"

# same <installed file, possibly .gz> <reference file> <label>
same() {
    local f=$1 ref=$2 label=$3
    if [ ! -f "$ref" ]; then no "$label" "no reference file $ref"; return; fi
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        if [ ! -s "$f" ]; then no "$label" "$f is empty"
        elif cmp -s "$f" "$ref"; then ok "$label"
        else no "$label" "$f differs from $(basename "$ref") of the source"; fi
    elif [ -f "$f.gz" ] && [ ! -L "$f.gz" ]; then
        if gzip -dc "$f.gz" 2>/dev/null | cmp -s - "$ref"; then ok "$label (gzip)"
        else no "$label" "$f.gz differs from $(basename "$ref") of the source"; fi
    else
        no "$label" "$f is missing"
    fi
}

# the copyright lines of the files named on stdin, normalised, sorted, unique
copyright_lines() {
    xargs -r -d '\n' grep -hi 'copyright' -- |
        sed 's/^[[:space:]/*#;-]*//; s/[[:space:]]\{1,\}/ /g; s/ *$//' |
        grep '^Copyright ' | LC_ALL=C sort -u
}
# the copyright lines THIRD-PARTY-NOTICES lists for WAMR's compiled-in files
notice_lines() {
    sed -n '/^Copyright notices of the compiled-in files:/,/^$/p' "$1/THIRD-PARTY-NOTICES" |
        sed -n 's/^    \(Copyright .*\)$/\1/p' | sed 's/[[:space:]]\{1,\}/ /g; s/ *$//' | LC_ALL=C sort -u
}
MODNOTICE='NOTICE: this file was modified by the PL/Zig project'

check_source() {
    local tree=$1; shift
    local wamr="" zigs=() f v
    while [ $# -gt 0 ]; do
        case $1 in
            --wamr) wamr=$2; shift 2 ;;
            --zig) zigs+=("$2"); shift 2 ;;
            *) usage ;;
        esac
    done
    [ -f "$tree/Makefile" ] && [ -f "$tree/packaging/versions.sh" ] || { echo "$tree is not a PL/Zig source tree" >&2; exit 2; }
    eval "$(sh "$tree/packaging/versions.sh" "$tree")" || exit 2

    local missing=""
    for f in LICENSE THIRD-PARTY-NOTICES LICENSES/Apache-2.0-WITH-LLVM-exception.txt LICENSES/MIT-Zig.txt \
             third_party/wamr-interrupt.patch debian/copyright packaging/license-files.sha256 \
             packaging/zig-toolchain/NOTICE packaging/zig-toolchain/debian/copyright \
             packaging/zig-toolchain/licenses/LLVM-LICENSE.TXT packaging/zig-toolchain/licenses/musl-COPYRIGHT.txt \
             packaging/zig-toolchain/licenses/zlib-LICENSE.txt packaging/zig-toolchain/licenses/zstd-LICENSE.txt; do
        [ -s "$tree/$f" ] || missing+=" $f"
    done
    [ -z "$missing" ] && ok "every license and notice file is present" || no "license and notice files present" "missing or empty:$missing"

    # the third-party texts are the pinned ones, and nothing below the two
    # directories is unpinned
    if out=$(cd "$tree" && sha256sum -c --quiet packaging/license-files.sha256 2>&1); then
        ok "third-party license texts have their pinned SHA-256"
    else
        no "third-party license texts have their pinned SHA-256" "$(tr '\n' ' ' <<<"$out")"
    fi
    local pinned listed
    pinned=$(sed 's/^[0-9a-f]*  //' "$tree/packaging/license-files.sha256" 2>/dev/null | LC_ALL=C sort)
    listed=$(cd "$tree" && find LICENSES packaging/zig-toolchain/licenses -type f 2>/dev/null | LC_ALL=C sort)
    [ "$pinned" = "$listed" ] && ok "every file of LICENSES/ and packaging/zig-toolchain/licenses/ is pinned" ||
        no "pinned files = files of the two license directories" "$(diff <(echo "$pinned") <(echo "$listed") | tr '\n' ' ')"

    # PL/Zig's own license: The PostgreSQL License with a copyright line
    if grep -q '^Copyright (c) [0-9]' "$tree/LICENSE" &&
       grep -q 'Permission to use, copy, modify, and distribute this software' "$tree/LICENSE" &&
       grep -q 'SPECIFICALLY DISCLAIMS ANY WARRANTIES' "$tree/LICENSE"; then
        ok "LICENSE: The PostgreSQL License with its copyright line"
    else no "LICENSE: The PostgreSQL License with its copyright line"; fi
    # debian/copyright reproduces it (paragraph text, DEP-5 formatting aside)
    local lic deb
    lic=$(sed -n '/^Permission to use/,/MODIFICATIONS\.$/p' "$tree/LICENSE" | tr -s ' \n' ' ' | sed 's/ *$//')
    deb=$(sed 's/^ \.$//; s/^ //' "$tree/debian/copyright" | tr -s ' \n' ' ')
    case $lic in *"OR MODIFICATIONS.") ;; *) lic="(license text not found in LICENSE)" ;; esac
    case $deb in *"$lic"*) ok "debian/copyright reproduces LICENSE" ;; *) no "debian/copyright reproduces LICENSE" ;; esac
    local holder
    holder=$(sed -n 's/^Copyright (c) \([0-9][0-9, -]*[0-9]\),* \(.*\)$/\1 \2/p' "$tree/LICENSE" | head -1)
    grep -qF "Copyright: $holder" "$tree/debian/copyright" && ok "debian/copyright names LICENSE's copyright holder ($holder)" ||
        no "debian/copyright names LICENSE's copyright holder" "$holder"

    # the notices describe the pinned versions
    local n=$tree/THIRD-PARTY-NOTICES bad=""
    grep -qF "$WAMR_VERSION (tag WAMR-$WAMR_VERSION," "$n" || bad+=" WAMR version $WAMR_VERSION;"
    grep -qF "commit $WAMR_COMMIT" "$n" || bad+=" WAMR commit;"
    grep -q "^Version:  $ZIG_VERSION\$" "$n" || bad+=" Zig version $ZIG_VERSION;"
    grep -qF "Zig $ZIG_VERSION" "$n" || bad+=" 'Zig $ZIG_VERSION';"
    grep -qF "Statement of changes (Apache License 2.0, section 4(b))" "$n" || bad+=" statement of changes;"
    grep -qF "third_party/wamr-interrupt.patch" "$n" || bad+=" the patch's path;"
    grep -qF "LICENSES/Apache-2.0-WITH-LLVM-exception.txt" "$n" && grep -qF "LICENSES/MIT-Zig.txt" "$n" || bad+=" the license texts' paths;"
    [ -n "$(notice_lines "$tree")" ] || bad+=" WAMR copyright lines;"
    grep -qF "WAMR $WAMR_VERSION" "$tree/debian/copyright" || bad+=" debian/copyright: WAMR $WAMR_VERSION;"
    grep -qF "commit $WAMR_COMMIT" "$tree/third_party/wamr-interrupt.patch" || bad+=" patch header: WAMR commit;"
    [ -z "$bad" ] && ok "notices name WAMR $WAMR_VERSION ($WAMR_COMMIT), Zig $ZIG_VERSION and the statement of changes" ||
        no "notices are current" "missing:$bad"

    # the patch adds the modification notice to the file it changes
    if grep -q "^+ \* $MODNOTICE" "$tree/third_party/wamr-interrupt.patch" &&
       [ "$(grep -c '^+++ ' "$tree/third_party/wamr-interrupt.patch")" = 1 ]; then
        ok "the WAMR patch changes one file and adds the modification notice to it"
    else no "the WAMR patch changes one file and adds the modification notice to it"; fi

    # every WAMR copyright line of THIRD-PARTY-NOTICES is in debian/copyright
    bad=""
    while IFS= read -r line; do
        v=$(sed 's/^Copyright ([Cc]) //; s/\. All [Rr]ights [Rr]eserved\.$//; s/,* All [Rr]ights [Rr]eserved\.$//' <<<"$line")
        grep -qF "$v" "$tree/debian/copyright" || bad+=" [$v]"
    done < <(notice_lines "$tree")
    [ -z "$bad" ] && ok "debian/copyright lists every WAMR copyright holder of THIRD-PARTY-NOTICES" ||
        no "debian/copyright lists every WAMR copyright holder" "missing:$bad"

    # one license expression per package, wherever it is written
    local pl tc e
    pl=$(sed -n 's/^License: *//p' "$tree/packaging/rpm/plzig.spec.in")
    tc=$(sed -n 's/^License: *//p' "$tree/packaging/rpm/plzig-zig-toolchain.spec.in")
    bad=""
    [ -n "$pl" ] && [ -n "$tc" ] || bad+=" no License: in a spec;"
    grep -qF "PLZIG_LICENSE = \"$pl\"" "$tree/packaging/release/sbom.py" || bad+=" sbom.py PLZIG_LICENSE;"
    grep -qF "ZIG_LICENSE = \"$tc\"" "$tree/packaging/release/sbom.py" || bad+=" sbom.py ZIG_LICENSE;"
    grep -qF "  $tc" "$tree/packaging/zig-toolchain/NOTICE" || bad+=" NOTICE;"
    # the image holds both packages: its label names every license of either
    e=$(sed -n 's/.*org.opencontainers.image.licenses="\([^"]*\)".*/\1/p' "$tree/packaging/image/Dockerfile")
    for v in $(printf '%s AND %s\n' "$pl" "$tc" | sed 's/ AND /\n/g' | tr ' ' '_' | sort -u); do
        case " AND $e AND " in *" AND ${v//_/ } AND "*) ;; *) bad+=" image label lacks ${v//_/ };" ;; esac
    done
    [ -z "$bad" ] && ok "license expressions agree (specs, SBOM generator, NOTICE, image label)" ||
        no "license expressions agree" "$bad"

    # upstream's own files
    local tmp
    tmp=$(mktemp -d)
    if [ -n "$wamr" ]; then
        if [ "$(sha256sum "$wamr" | cut -d' ' -f1)" != "$WAMR_TARBALL_SHA256" ]; then
            no "WAMR tarball has the pinned SHA-256" "$wamr"
        elif tar -xzf "$wamr" -C "$tmp" --wildcards --no-anchored --strip-components=1 '*/LICENSE' '*/core/version.h' 2>/dev/null &&
             cmp -s "$tmp/LICENSE" "$tree/LICENSES/Apache-2.0-WITH-LLVM-exception.txt"; then
            ok "LICENSES/Apache-2.0-WITH-LLVM-exception.txt is WAMR $WAMR_VERSION's LICENSE, byte for byte"
        else no "LICENSES/Apache-2.0-WITH-LLVM-exception.txt is WAMR's LICENSE"; fi
    else
        echo "  skip - WAMR's LICENSE not compared (no --wamr tarball)"
    fi
    for f in ${zigs[@]+"${zigs[@]}"}; do
        v=""
        case $(basename "$f") in
            zig-x86_64-linux-*) v=$ZIG_SHA256_x86_64 ;;
            zig-aarch64-linux-*) v=$ZIG_SHA256_aarch64 ;;
        esac
        rm -rf "$tmp/zig"; mkdir "$tmp/zig"
        if [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$v" ]; then
            no "Zig tarball has the pinned SHA-256" "$f"
        elif tar -xJf "$f" -C "$tmp/zig" --strip-components=1 "$(basename "$f" .tar.xz)/LICENSE" 2>/dev/null &&
             cmp -s "$tmp/zig/LICENSE" "$tree/LICENSES/MIT-Zig.txt"; then
            ok "LICENSES/MIT-Zig.txt is the LICENSE of $(basename "$f"), byte for byte"
        else no "LICENSES/MIT-Zig.txt is the LICENSE of $(basename "$f")"; fi
    done
    [ ${#zigs[@]} -gt 0 ] || echo "  skip - Zig's LICENSE not compared (no --zig tarball)"
    rm -rf "$tmp"
}

check_wamr_build() {
    local build=$1 src=$2 tree=$3 files got want
    src=$(realpath "$src")
    files=$(mktemp)
    # the compiler's own dependency files: every source and header it read
    find "$build" -type f \( -name '*.o.d' -o -name 'depend.make' -o -name 'compiler_depend.make' \) -exec cat {} + 2>/dev/null |
        tr ' \\' '\n\n' | sed 's/:$//' | grep '^/' | xargs -r -d '\n' realpath -q 2>/dev/null |
        grep -F "$src/" | LC_ALL=C sort -u >"$files"
    local n
    n=$(wc -l <"$files")
    if [ "$n" -lt 20 ] || ! grep -q '/wasm_interp_classic\.c$' "$files"; then
        no "compiled-in WAMR files found from the build's dependency files" "$n files below $src in $build"
        rm -f "$files"; return
    fi
    ok "$n WAMR files were read by the compiler (dependency files of the build)"
    got=$(copyright_lines <"$files")
    want=$(notice_lines "$tree")
    if [ "$got" = "$want" ]; then
        ok "their copyright lines are exactly the $(wc -l <<<"$want") listed in THIRD-PARTY-NOTICES"
    else
        no "compiled-in copyright lines = THIRD-PARTY-NOTICES" "$(diff <(echo "$want") <(echo "$got") | grep '^[<>]' | sed 's/^</listed, not compiled in:/; s/^>/compiled in, not listed:/' | tr '\n' ';')"
    fi
    # files without a copyright line must be accounted for by name
    local bad="" f
    while IFS= read -r f; do
        grep -qi 'copyright' "$f" || grep -qF "${f#"$src"/}" "$tree/THIRD-PARTY-NOTICES" || bad+=" ${f#"$src"/}"
    done <"$files"
    [ -z "$bad" ] && ok "files without a copyright line are named in THIRD-PARTY-NOTICES" ||
        no "files without a copyright line are named in THIRD-PARTY-NOTICES" "$bad"
    grep -qF "$MODNOTICE" "$src/core/iwasm/interpreter/wasm_interp_classic.c" &&
        ok "the patched file carries the modification notice" || no "the patched file carries the modification notice"
    if cmp -s "$src/LICENSE" "$tree/LICENSES/Apache-2.0-WITH-LLVM-exception.txt"; then
        ok "LICENSES/Apache-2.0-WITH-LLVM-exception.txt is the built WAMR's LICENSE"
    else no "LICENSES/Apache-2.0-WITH-LLVM-exception.txt is the built WAMR's LICENSE"; fi
    rm -f "$files"
}

check_plzig() {
    local dir=$1 tree=$2 f sub
    [ -d "$dir" ] || { no "license directory" "$dir is missing"; return; }
    for f in $PLZIG_FILES; do same "$dir/$f" "$tree/$f" "$f"; done
    sub=$dir; [ -d "$dir/LICENSES" ] && sub=$dir/LICENSES
    for f in $PLZIG_TEXTS; do same "$sub/$f" "$tree/LICENSES/$f" "$f"; done
}

check_toolchain() {
    local dir=$1 tree=$2 f
    [ -d "$dir" ] || { no "license directory" "$dir is missing"; return; }
    same "$dir/NOTICE" "$tree/packaging/zig-toolchain/NOTICE" "NOTICE"
    # Zig's own LICENSE: the source check ties LICENSES/MIT-Zig.txt to upstream's
    same "$dir/LICENSE" "$tree/LICENSES/MIT-Zig.txt" "LICENSE (Zig)"
    for f in $TC_TEXTS; do same "$dir/$f" "$tree/packaging/zig-toolchain/licenses/$f" "$f"; done
}

check_copyright() {
    case $3 in
        plzig) same "$1" "$2/debian/copyright" "Debian copyright file" ;;
        toolchain) same "$1" "$2/packaging/zig-toolchain/debian/copyright" "Debian copyright file" ;;
        *) usage ;;
    esac
}

check_debugsource() {
    local dir=$1 tree=$2 f n extra
    f=$(find "$dir" -type f -name wasm_interp_classic.c | head -1)
    if [ -z "$f" ]; then no "debug sources contain WAMR's interpreter" "no wasm_interp_classic.c below $dir"; return; fi
    grep -qF "$MODNOTICE" "$f" && ok "the patched WAMR file carries the modification notice" ||
        no "the patched WAMR file carries the modification notice"
    n=$(find "$dir" -type f -path '*/wamr-src/*' | wc -l)
    extra=$(LC_ALL=C comm -23 <(find "$dir" -type f -path '*/wamr-src/*' | copyright_lines) <(notice_lines "$tree"))
    [ -z "$extra" ] && ok "no copyright line in the $n WAMR source files that THIRD-PARTY-NOTICES does not list" ||
        no "WAMR source files' copyright lines are listed in THIRD-PARTY-NOTICES" "$(tr '\n' ';' <<<"$extra")"
}

# expect_fail <description> <command...>: the command must report a failure
expect_fail() {
    local what=$1; shift
    if "$@" >/dev/null 2>&1; then no "selftest: $what goes unnoticed"; else ok "selftest: $what is noticed"; fi
}
selftest() {
    local tree=$1 tmp me=$0
    tmp=$(mktemp -d)
    # a correct copy first: the checks must pass on it
    mkdir -p "$tmp/pl/LICENSES" "$tmp/tc" "$tmp/t"
    (cd "$tree" && tar -cf - LICENSE THIRD-PARTY-NOTICES LICENSES Makefile debian packaging third_party abi/plzig-abi.table $( [ -f .dist-version ] && echo .dist-version)) | tar -xf - -C "$tmp/t"
    cp "$tree/LICENSE" "$tree/THIRD-PARTY-NOTICES" "$tmp/pl/"
    cp "$tree"/LICENSES/* "$tmp/pl/LICENSES/"
    cp "$tree/packaging/zig-toolchain/NOTICE" "$tree"/packaging/zig-toolchain/licenses/* "$tmp/tc/"
    cp "$tree/LICENSES/MIT-Zig.txt" "$tmp/tc/LICENSE"
    bash "$me" plzig "$tmp/pl" "$tree" >/dev/null && bash "$me" toolchain "$tmp/tc" "$tree" >/dev/null &&
        bash "$me" source "$tmp/t" >/dev/null && ok "selftest: intact copies pass" || no "selftest: intact copies pass"

    rm "$tmp/pl/THIRD-PARTY-NOTICES"
    expect_fail "a missing THIRD-PARTY-NOTICES" bash "$me" plzig "$tmp/pl" "$tree"
    cp "$tree/THIRD-PARTY-NOTICES" "$tmp/pl/"; echo >>"$tmp/pl/LICENSES/MIT-Zig.txt"
    expect_fail "a changed license text" bash "$me" plzig "$tmp/pl" "$tree"
    : >"$tmp/tc/LLVM-LICENSE.TXT"
    expect_fail "an empty license text" bash "$me" toolchain "$tmp/tc" "$tree"
    cp "$tree/packaging/zig-toolchain/licenses/LLVM-LICENSE.TXT" "$tmp/tc/"; rm "$tmp/tc/NOTICE"
    expect_fail "a missing NOTICE" bash "$me" toolchain "$tmp/tc" "$tree"
    head -c 200 "$tree/debian/copyright" >"$tmp/copyright"
    expect_fail "a truncated Debian copyright file" bash "$me" copyright "$tmp/copyright" "$tree" plzig

    echo >>"$tmp/t/packaging/zig-toolchain/licenses/zlib-LICENSE.txt"
    expect_fail "an edited third-party text in the source" bash "$me" source "$tmp/t"
    cp "$tree/packaging/zig-toolchain/licenses/zlib-LICENSE.txt" "$tmp/t/packaging/zig-toolchain/licenses/"
    sed -i "s/^commit [0-9a-f]*/commit 0000/; s/commit [0-9a-f]\{40\})/commit 0000)/" "$tmp/t/THIRD-PARTY-NOTICES"
    expect_fail "a stale WAMR commit in THIRD-PARTY-NOTICES" bash "$me" source "$tmp/t"
    cp "$tree/THIRD-PARTY-NOTICES" "$tmp/t/"
    sed -i 's/^License: .*/License:        PostgreSQL/' "$tmp/t/packaging/rpm/plzig.spec.in"
    expect_fail "a license expression that differs between spec and SBOM" bash "$me" source "$tmp/t"

    # an unlisted copyright line in a compiled-in file, and a lost notice
    mkdir -p "$tmp/d/build/wamr-src/core/iwasm/interpreter"
    printf '/*\n * Copyright (C) 2019 Intel Corporation.  All rights reserved.\n */\n/* %s */\n' "$MODNOTICE" \
        >"$tmp/d/build/wamr-src/core/iwasm/interpreter/wasm_interp_classic.c"
    bash "$me" debugsource "$tmp/d" "$tree" >/dev/null && ok "selftest: listed copyright lines pass" ||
        no "selftest: listed copyright lines pass"
    printf '/* Copyright (C) 2031 Somebody Else. All rights reserved. */\n' >"$tmp/d/build/wamr-src/core/iwasm/interpreter/x.h"
    expect_fail "a copyright line that THIRD-PARTY-NOTICES does not list" bash "$me" debugsource "$tmp/d" "$tree"
    rm "$tmp/d/build/wamr-src/core/iwasm/interpreter/x.h"
    sed -i '$d' "$tmp/d/build/wamr-src/core/iwasm/interpreter/wasm_interp_classic.c"
    expect_fail "a patched file without the modification notice" bash "$me" debugsource "$tmp/d" "$tree"
    rm -rf "$tmp"
}

mode=${1:-}; [ $# -gt 0 ] && shift
case $mode in
    source)      [ $# -ge 1 ] || usage; check_source "$@" ;;
    wamr-build)  [ $# -eq 3 ] || usage; check_wamr_build "$@" ;;
    plzig)       [ $# -eq 2 ] || usage; check_plzig "$@" ;;
    toolchain)   [ $# -eq 2 ] || usage; check_toolchain "$@" ;;
    copyright)   [ $# -eq 3 ] || usage; check_copyright "$@" ;;
    debugsource) [ $# -eq 2 ] || usage; check_debugsource "$@" ;;
    selftest)    [ $# -eq 1 ] || usage; selftest "$@" ;;
    *) usage ;;
esac
finish "$mode"
