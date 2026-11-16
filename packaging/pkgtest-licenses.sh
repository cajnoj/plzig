#!/bin/bash
# License material of every built package (step "licenses" of
# packaging/pkgtest-in-container.sh; doc/packaging.md "License material").
#
#   pkgtest-licenses.sh <rpm|deb> <major> <unpacked source tarball> <pkgdir> <source tarball>
#
# Each package file of <pkgdir> that belongs to PostgreSQL <major> or to the
# toolchain is unpacked (not installed) and compared with the source tree by
# packaging/check-licenses.sh:
#   binary packages   the license files, byte-identical, in
#                     /usr/share/licenses/<package>/ (RPM: marked %license);
#                     Debian: also /usr/share/doc/<package>/copyright
#   debug packages    RPM debuginfo and debugsource carry their own copies,
#                     and the debugsource's WAMR files have no unlisted
#                     copyright line; Debian dbgsym depends on exactly the
#                     main package's version and links its doc directory
#   source packages   contain the source tarball unchanged and the pinned
#                     upstream tarballs (which hold upstream's license files)
# Then the same for the files as installed in this container.
set -uo pipefail
family=$1; major=$2; src=$3; pkgs=$4; dist=$5
here=$(cd "$(dirname "$0")" && pwd)
check="bash $here/check-licenses.sh"
eval "$(sh "$src/packaging/versions.sh" "$src")"
arch=$(uname -m)
work=$(mktemp -d)
fails=0
ok() { echo "  ok   - $1"; }
no() { echo "  FAIL - $1${2:+: $2}"; fails=$((fails + 1)); }
run() {   # run <label> <check-licenses arguments...>
    local label=$1 out; shift
    if out=$($check "$@" 2>&1); then ok "$label: $(grep -c '^  ok ' <<<"$out") checks"
    else echo "$out" | grep -v '^  ok '; no "$label"; fi
}
one() {   # one <description> <glob>: prints the first file matching (empty if none)
    compgen -G "$2" | head -1
}
need() {   # need <file or empty>... : every expected package file was found
    local f
    for f; do [ -n "$f" ] || { no "every expected package file is in $pkgs" "$(ls "$pkgs" | tr '\n' ' ')"; return; }; done
}
unpack() {   # unpack <package file>: prints the directory it was unpacked into
    local d
    d=$work/$(basename "$1").d
    mkdir -p "$d"
    case $1 in
        *.rpm) (cd "$d" && rpm2cpio "$1" | cpio -idm --quiet 2>/dev/null) ;;
        *.deb|*.ddeb) dpkg-deb -x "$1" "$d" ;;
        *.tar.xz) tar -xJf "$1" -C "$d" ;;
        *.tar.gz) tar -xzf "$1" -C "$d" ;;
    esac || no "unpack $(basename "$1")"
    printf '%s' "$d"
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
pinned() {   # pinned <file> <sha256> <label>
    [ -f "$1" ] && [ "$(sha "$1")" = "$2" ] && ok "$3 has its pinned SHA-256" || no "$3 has its pinned SHA-256" "$1"
}

case $family in
rpm)
    command -v cpio >/dev/null || { echo "cpio is not installed"; exit 1; }
    main=$(one "plzig_$major" "$pkgs/plzig_$major-[0-9]*.$arch.rpm")
    tc=$(one plzig-zig-toolchain "$pkgs/plzig-zig-toolchain-[0-9]*.$arch.rpm")
    dbg=$(one "plzig_$major-debuginfo" "$pkgs/plzig_$major-debuginfo-[0-9]*.$arch.rpm")
    dbs=$(one "plzig_$major-debugsource" "$pkgs/plzig_$major-debugsource-[0-9]*.$arch.rpm")
    srpm=$(one "plzig_$major source package" "$pkgs/plzig_$major-[0-9]*.src.rpm")
    tcsrpm=$(one "plzig-zig-toolchain source package" "$pkgs/plzig-zig-toolchain-[0-9]*.src.rpm")
    need "$main" "$tc" "$dbg" "$dbs" "$srpm" "$tcsrpm"
    [ $fails -eq 0 ] || { echo "LICENSES packages: FAIL ($fails)"; exit 1; }

    for p in "$main:plzig_$major:plzig" "$dbg:plzig_$major-debuginfo:plzig" "$dbs:plzig_$major-debugsource:plzig" \
             "$tc:plzig-zig-toolchain:toolchain"; do
        f=${p%%:*}; rest=${p#*:}; name=${rest%%:*}; kind=${rest#*:}
        d=$(unpack "$f")
        run "$name" "$kind" "$d/usr/share/licenses/$name" "$src"
        # marked as license files, so that rpm keeps them under --excludedocs
        n=$(rpm -qp --licensefiles "$f" 2>/dev/null | grep -c "^/usr/share/licenses/$name/")
        want=4; [ "$kind" = toolchain ] && want=6
        [ "$n" -eq $want ] && ok "$name: $n files marked %license" || no "$name: $want files marked %license" "$n"
    done
    run "plzig_$major-debugsource sources" debugsource "$(unpack "$dbs")/usr/src/debug" "$src"

    d=$(unpack "$srpm")
    cmp -s "$d/$(basename "$(compgen -G "$d/plzig-*.tar.gz" | head -1)")" "$dist" &&
        ok "plzig_$major source package holds the source tarball unchanged" ||
        no "plzig_$major source package holds the source tarball unchanged"
    pinned "$d/WAMR-$WAMR_VERSION.tar.gz" "$WAMR_TARBALL_SHA256" "its WAMR tarball"
    d=$(unpack "$tcsrpm")
    mkdir "$d/lic"; cp "$d"/NOTICE "$d"/*LICENSE* "$d"/musl-COPYRIGHT.txt "$d/lic/" 2>/dev/null
    cp "$src/LICENSES/MIT-Zig.txt" "$d/lic/LICENSE"   # Zig's LICENSE is inside the pinned tarballs
    run "plzig-zig-toolchain source package" toolchain "$d/lic" "$src"
    pinned "$d/zig-x86_64-linux-$ZIG_VERSION.tar.xz" "$ZIG_SHA256_x86_64" "its Zig tarball (x86_64)"
    pinned "$d/zig-aarch64-linux-$ZIG_VERSION.tar.xz" "$ZIG_SHA256_aarch64" "its Zig tarball (aarch64)"
    mainname=plzig_$major
    ;;
deb)
    main=$(one "postgresql-$major-plzig" "$pkgs/postgresql-$major-plzig_*.deb")
    tc=$(one plzig-zig-toolchain "$pkgs/plzig-zig-toolchain_*.deb")
    # Debian names it .deb, Ubuntu .ddeb
    dbg=$(one "postgresql-$major-plzig-dbgsym" "$pkgs/postgresql-$major-plzig-dbgsym_*.deb")
    [ -n "$dbg" ] || dbg=$(one "postgresql-$major-plzig-dbgsym" "$pkgs/postgresql-$major-plzig-dbgsym_*.ddeb")
    orig=$(one "plzig orig tarball" "$pkgs/plzig_*.orig.tar.gz")
    origw=$(one "plzig orig-wamr tarball" "$pkgs/plzig_*.orig-wamr.tar.gz")
    debt=$(one "plzig debian tarball" "$pkgs/plzig_*.debian.tar.xz")
    tcorig=$(one "toolchain orig tarball" "$pkgs/plzig-zig-toolchain_*.orig.tar.xz")
    tcdebt=$(one "toolchain debian tarball" "$pkgs/plzig-zig-toolchain_*.debian.tar.xz")
    need "$main" "$tc" "$dbg" "$orig" "$origw" "$debt" "$tcorig" "$tcdebt"
    [ $fails -eq 0 ] || { echo "LICENSES packages: FAIL ($fails)"; exit 1; }

    mainname=postgresql-$major-plzig
    d=$(unpack "$main")
    run "$mainname" plzig "$d/usr/share/licenses/$mainname" "$src"
    run "$mainname copyright" copyright "$d/usr/share/doc/$mainname/copyright" "$src" plzig
    d=$(unpack "$tc")
    run plzig-zig-toolchain toolchain "$d/usr/share/licenses/plzig-zig-toolchain" "$src"
    run "plzig-zig-toolchain copyright" copyright "$d/usr/share/doc/plzig-zig-toolchain/copyright" "$src" toolchain

    # the debug symbols: installable only with the main package of the same
    # version, whose documentation directory theirs links to
    d=$(unpack "$dbg")
    ver=$(dpkg-deb -f "$main" Version)
    dep=$(dpkg-deb -f "$dbg" Depends)
    link=$(readlink "$d/usr/share/doc/$mainname-dbgsym" 2>/dev/null)
    if [ "$dep" = "$mainname (= $ver)" ] && [ "$link" = "$mainname" ]; then
        ok "$mainname-dbgsym depends on $mainname (= $ver) and links its doc directory"
    else no "$mainname-dbgsym is tied to the main package" "Depends: $dep; doc: $link"; fi

    cmp -s "$orig" "$dist" && ok "plzig orig tarball is the source tarball unchanged" ||
        no "plzig orig tarball is the source tarball unchanged"
    pinned "$origw" "$WAMR_TARBALL_SHA256" "the orig-wamr tarball"
    d=$(unpack "$debt")
    run "plzig source package: debian/copyright" copyright "$d/debian/copyright" "$src" plzig
    d=$(unpack "$tcorig"); t=$(echo "$d"/plzig-zig-toolchain-*)
    mkdir "$d/lic"; cp "$t/NOTICE" "$t"/licenses/* "$d/lic/" 2>/dev/null
    cp "$src/LICENSES/MIT-Zig.txt" "$d/lic/LICENSE"   # Zig's LICENSE is inside the pinned tarballs
    run "plzig-zig-toolchain source package" toolchain "$d/lic" "$src"
    d=$(unpack "$tcdebt")
    run "plzig-zig-toolchain source package: debian/copyright" copyright "$d/debian/copyright" "$src" toolchain
    pinned "$(compgen -G "$pkgs/plzig-zig-toolchain_*.orig-amd64.tar.xz" | head -1)" "$ZIG_SHA256_x86_64" "the orig-amd64 tarball (Zig)"
    pinned "$(compgen -G "$pkgs/plzig-zig-toolchain_*.orig-arm64.tar.xz" | head -1)" "$ZIG_SHA256_aarch64" "the orig-arm64 tarball (Zig)"

    run "installed: /usr/share/doc/$mainname/copyright" copyright "/usr/share/doc/$mainname/copyright" "$src" plzig
    run "installed: /usr/share/doc/plzig-zig-toolchain/copyright" copyright /usr/share/doc/plzig-zig-toolchain/copyright "$src" toolchain
    ;;
*) echo "usage: pkgtest-licenses.sh <rpm|deb> <major> <source tree> <pkgdir> <source tarball>" >&2; exit 2 ;;
esac

# as installed here
run "installed: /usr/share/licenses/$mainname" plzig "/usr/share/licenses/$mainname" "$src"
run "installed: /usr/share/licenses/plzig-zig-toolchain" toolchain /usr/share/licenses/plzig-zig-toolchain "$src"
# Zig's LICENSE in the package is the one of the tarball the compiler came from
zt=$(compgen -G "$work/*/zig-$arch-linux-$ZIG_VERSION.tar.xz" | head -1)
[ -n "$zt" ] || zt=$(compgen -G "$pkgs/plzig-zig-toolchain_*.orig-$(dpkg --print-architecture 2>/dev/null).tar.xz" | head -1)
if [ -n "$zt" ] && tar -xJf "$zt" -C "$work" --strip-components=1 "zig-$arch-linux-$ZIG_VERSION/LICENSE" 2>/dev/null &&
   cmp -s "$work/LICENSE" /usr/share/licenses/plzig-zig-toolchain/LICENSE; then
    ok "the toolchain's LICENSE is the one in the official Zig tarball"
else no "the toolchain's LICENSE is the one in the official Zig tarball" "${zt:-no tarball}"; fi

rm -rf "$work"
if [ $fails -eq 0 ]; then echo "LICENSES packages: PASS"; exit 0; fi
echo "LICENSES packages: FAIL ($fails)"; exit 1
