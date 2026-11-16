#!/bin/bash
# The installed-package test, inside a fresh container of the target
# distribution (started by packaging/test-packages.sh, as root).
#
#   pkgtest-in-container.sh <rpm|deb> <major>
#
# Mounted: /pkgs (the packages under test), /prev (optional: an earlier
# build of the same packages, for the upgrade test), /in/plzig.tar.gz (the
# source tarball: only the regression tests, the upgrade-script check and the
# versions are taken from it, nothing is built), /packaging (setup scripts and
# keys).  Environment: PLZIG_NO_PREV=1 skips the upgrade test.
#
# Steps, each printing "STEP <name>: PASS|FAIL|SKIP (detail)":
#   deps       no built package depends on, recommends, suggests, supplements
#              or enhances PL/Python or PL/Perl; plzig's dependencies are
#              PostgreSQL and the toolchain package (plus libc)
#   install    PGDG for this major only, then the packages (from /prev first
#              if given); nothing of PL/Python or PL/Perl got installed
#   files      compiled-in plzig.zig_path = the toolchain package's compiler,
#              root-owned and not writable by others; hardening of plzig.so
#   licenses   packaging/pkgtest-licenses.sh: every binary, debug and source
#              package carries the license files and attributions of the
#              source tarball, byte-identical, also as installed
#   upgrade    a function created with the /prev packages still runs after
#              upgrading to /pkgs and a server restart; a new one compiles
#   sandbox    CREATE EXTENSION, a compilation, plzig_sandbox_status()
#              "enforced" (the container shares the host's kernel)
#   regress    the pg_regress suite of the source tarball against the
#              installed package (the list in the tarball's Makefile)
#   sqlupgrade test/upgrade/check-upgrade-scripts.sh: every upgrade path
#              of the installed scripts ends in the same objects as a fresh
#              install; its self-test proves it notices a divergent script
#   remove     the toolchain cannot be removed while plzig is installed; then
#              both are removed: no file left, server still running, a call
#              fails cleanly ("could not access file" / "could not load
#              library"), DROP EXTENSION works, $PGDATA/plzig is kept
set -uo pipefail
family=$1; major=$2
failed=0
step() {   # step <name> <PASS|FAIL|SKIP> [detail]
    echo "STEP $1: $2${3:+ ($3)}"
    [ "$2" = FAIL ] && failed=1
    return 0
}
die() { step "$1" FAIL "$2"; echo "RESULT: FAIL"; exit 1; }

mkdir -p /tmp/src
tar -xzf /in/plzig.tar.gz -C /tmp/src
src=$(echo /tmp/src/plzig-*)
eval "$(sh "$src/packaging/versions.sh" "$src")"
zig_path=/usr/libexec/plzig-zig-toolchain/$ZIG_VERSION/zig
echo "=== $(. /etc/os-release; echo "$PRETTY_NAME"), PostgreSQL $major, PL/Zig $DIST_VERSION, kernel $(uname -r)"

pkgfiles() {   # pkgfiles <dir>: the binary packages of plzig_<major> and the toolchain
    case $family in
        rpm) ls "$1"/plzig_"$major"-[0-9]*."$(uname -m)".rpm "$1"/plzig-zig-toolchain-[0-9]*."$(uname -m)".rpm ;;
        deb) ls "$1"/postgresql-"$major"-plzig_*.deb "$1"/plzig-zig-toolchain_*.deb ;;
    esac
}

# ------------------------------------------------------------------ deps
pl_re='pl(python|perl)|python[0-9.]*-|perl-|libperl|libpython|postgresql[0-9]*-(plperl|plpython)|postgresql-(plperl|plpython)'
bad=""
deplog=/tmp/deps.txt
: >"$deplog"
case $family in
    rpm)
        command -v rpm >/dev/null || dnf -q -y install rpm >/dev/null
        for f in /pkgs/*.rpm; do
            {
                echo "--- $(basename "$f")"
                for k in requires recommends suggests supplements enhances; do
                    rpm -qp --"$k" "$f" 2>/dev/null | sed "s/^/$k: /"
                done
            } >>"$deplog"
        done
        ;;
    deb)
        for f in /pkgs/*.deb; do
            {
                echo "--- $(basename "$f")"
                for k in Pre-Depends Depends Recommends Suggests Enhances; do
                    v=$(dpkg-deb -f "$f" "$k")
                    [ -n "$v" ] && echo "$k: $v"
                done
            } >>"$deplog"
        done
        ;;
esac
cat "$deplog"
bad=$(grep -v '^---' "$deplog" | grep -Ei "$pl_re" || true)
case $family in
    rpm) mine=$(rpm -qp --requires "$(pkgfiles /pkgs | grep "/plzig_$major-")" | grep -vE '^(rpmlib\(|rtld\(|lib[a-z0-9_.+-]*\.so|/bin/sh|ld-linux)' | sed 's/ *$//' | sort | tr '\n' ';') ;;
    deb) mine=$(dpkg-deb -f "$(pkgfiles /pkgs | grep "/postgresql-$major-plzig_")" Depends) ;;
esac
if [ -n "$bad" ]; then
    step deps FAIL "PL/Python or PL/Perl in package metadata: $bad"
elif ! grep -q "plzig-zig-toolchain" <<<"$mine" || ! grep -q "postgresql" <<<"$mine"; then
    step deps FAIL "plzig does not depend on PostgreSQL and the toolchain: $mine"
else
    step deps PASS "plzig needs: $mine"
fi

# ------------------------------------------------------------------ install
case $family in
    rpm)
        sh /packaging/rpm/setup-pgdg.sh /packaging/keys/PGDG-RPM-GPG-KEY "$major" >/tmp/setup.log 2>&1 ||
            { cat /tmp/setup.log; die install "PGDG setup"; }
        bindir=/usr/pgsql-$major/bin
        libdir=/usr/pgsql-$major/lib
        PGDATA=/var/lib/pgsql/$major/data
        # PostgreSQL from PGDG first, signature-checked; then only our local,
        # unsigned test builds, without signature check (rpm 6 on Fedora 45
        # refuses unsigned packages otherwise)
        install_pkgs() {
            { dnf -q -y install "postgresql$major-server" &&
              dnf -q -y install --nogpgcheck "$@"; } >/tmp/install.log 2>&1 || { tail -30 /tmp/install.log; return 1; }
        }
        # test tooling: pg_regress (postgresqlNN-test), readelf, procps, su, diff
        # (the Fedora 45 and AlmaLinux 10 images have no su and no diff); cpio
        # unpacks the packages for the license check
        tooling() { dnf -q -y install "postgresql$major-test" binutils procps-ng util-linux diffutils cpio >/tmp/tooling.log 2>&1; }
        pg_regress=/usr/pgsql-$major/lib/test/regress/pg_regress
        installed_pls() { rpm -qa | grep -Ei 'plpython|plperl' || true; }
        ;;
    deb)
        sh /packaging/deb/setup-pgdg.sh /packaging/keys/apt.postgresql.org.asc "$major" >/tmp/setup.log 2>&1 ||
            { cat /tmp/setup.log; die install "PGDG setup"; }
        export DEBIAN_FRONTEND=noninteractive
        bindir=/usr/lib/postgresql/$major/bin
        libdir=/usr/lib/postgresql/$major/lib
        PGDATA=/var/lib/postgresql/$major/main
        install_pkgs() { apt-get install -y "$@" >/tmp/install.log 2>&1 || { tail -30 /tmp/install.log; return 1; }; }
        tooling() { apt-get install -y --no-install-recommends binutils procps >/tmp/tooling.log 2>&1; }
        pg_regress=/usr/lib/postgresql/$major/lib/pgxs/src/test/regress/pg_regress
        installed_pls() { dpkg-query -W -f '${Package}\n' 2>/dev/null | grep -Ei 'plpython|plperl' || true; }
        ;;
esac
export PGDATA PGHOST=/tmp PGUSER=postgres PGPORT=5432
q() { su postgres -c "PGHOST=/tmp $bindir/psql -X -At -v ON_ERROR_STOP=1 -d ${2:-postgres} -c \"\$0\"" "$1" 2>&1; }
# the server log is /tmp/server.log in both cases
start_server() {
    case $family in
        rpm) su postgres -c "$bindir/pg_ctl -D $PGDATA -l /tmp/server.log -w -o \"-c listen_addresses='' -c unix_socket_directories=/tmp\" start" >/dev/null ;;
        # postgresql-common: configuration in /etc/postgresql/<major>/main
        deb) pg_ctlcluster "$major" main start -- -l /tmp/server.log >/dev/null ;;
    esac
}
stop_server() {
    case $family in
        rpm) su postgres -c "$bindir/pg_ctl -D $PGDATA -m fast -w stop" >/dev/null ;;
        deb) pg_ctlcluster "$major" main stop -m fast >/dev/null ;;
    esac
}
make_cluster() {
    case $family in
        rpm) install -d -o postgres -g postgres -m 0700 "$PGDATA"
             su postgres -c "$bindir/initdb -D $PGDATA -A trust --no-locale -E UTF8" >/tmp/initdb.log 2>&1 ;;
        deb) # the package created a cluster "main" with the container's (C, SQL_ASCII)
             # defaults; the suite needs UTF8 and trust for local connections
             pg_dropcluster "$major" main >/dev/null 2>&1 || true
             pg_createcluster "$major" main --locale=C -e UTF8 -- -A trust >/tmp/initdb.log 2>&1 &&
             pg_conftool "$major" main set unix_socket_directories /tmp ;;
    esac
}

first=/pkgs
upgrade=0
if [ "${PLZIG_NO_PREV:-0}" != 1 ] && [ -d /prev ] && pkgfiles /prev >/dev/null 2>&1; then
    first=/prev; upgrade=1
fi
mapfile -t firstpkgs < <(pkgfiles "$first")
if ! install_pkgs "${firstpkgs[@]}"; then die install "installing $(basename -a "${firstpkgs[@]}" | tr '\n' ' ')"; fi
tooling || { cat /tmp/tooling.log; die install "test tooling"; }
make_cluster || { cat /tmp/initdb.log; die install "initdb"; }
start_server || { cat /tmp/server.log; die install "server start"; }
pls=$(installed_pls)
if [ -n "$pls" ]; then step install FAIL "PL/Python or PL/Perl installed: $pls"
else step install PASS "$(basename -a "${firstpkgs[@]}" | tr '\n' ' ')"; fi

# ------------------------------------------------------------------ upgrade
if [ $upgrade = 1 ]; then
    up_ok=1
    out=$(q "CREATE DATABASE plzig_upgrade" 2>&1) || up_ok=0
    out+=$(q "CREATE EXTENSION plzig; CREATE FUNCTION up_f(i int) RETURNS int STRICT LANGUAGE plzig AS \$\$ return i * 7; \$\$; SELECT up_f(6);" plzig_upgrade) || up_ok=0
    before=$(ls "$PGDATA/plzig/cache" 2>/dev/null | wc -l)
    mapfile -t newpkgs < <(pkgfiles /pkgs)
    case $family in
        rpm) dnf -q -y upgrade --nogpgcheck "${newpkgs[@]}" >/tmp/upgrade.log 2>&1 || up_ok=0 ;;
        deb) apt-get install -y "${newpkgs[@]}" >/tmp/upgrade.log 2>&1 || up_ok=0 ;;
    esac
    stop_server && start_server || up_ok=0
    r1=$(q "SELECT up_f(6)" plzig_upgrade | tail -1)
    after=$(ls "$PGDATA/plzig/cache" 2>/dev/null | wc -l)
    # psql 15+ prints the command tags of the earlier statements of -c
    r2=$(q "CREATE FUNCTION up_g() RETURNS text LANGUAGE plzig AS \$\$ return \"new\"; \$\$; SELECT up_g();" plzig_upgrade | tail -1)
    vers=$(case $family in rpm) rpm -q "plzig_$major" ;; deb) dpkg-query -W -f '${Version}' "postgresql-$major-plzig" ;; esac)
    if [ $up_ok = 1 ] && [ "$r1" = 42 ] && [ "$r2" = new ]; then
        step upgrade PASS "$(basename -a "${firstpkgs[@]}" | grep -v zig-toolchain) -> $vers; cached modules before/after: $before/$after"
    else
        echo "$out"; cat /tmp/upgrade.log; echo "up_f: $r1"; echo "up_g: $r2"
        step upgrade FAIL "$vers"
    fi
else
    step upgrade SKIP "no earlier build given"
fi

# ------------------------------------------------------------------ files
fdetail=""
fok=1
boot=$(q "LOAD 'plzig'; SELECT boot_val FROM pg_settings WHERE name = 'plzig.zig_path'" | tail -1)
[ "$boot" = "$zig_path" ] || { fok=0; fdetail="boot_val of plzig.zig_path is '$boot', expected $zig_path; "; }
if [ -x "$zig_path" ] && [ "$(stat -c '%U %a' "$zig_path")" = "root 755" ] &&
   [ "$("$zig_path" version)" = "$ZIG_VERSION" ]; then :; else
    fok=0; fdetail+="toolchain compiler missing, wrongly owned or wrong version; "
fi
so=$libdir/plzig.so
# outputs captured first: grep -q on a pipe would make the producer fail
# with SIGPIPE under pipefail
phdr=$(readelf -lW "$so"); dyn=$(readelf -dW "$so"); syms=$(nm -D "$so"); defs=$(nm -D --defined-only "$so")
vhdr=$(readelf -hW "$libdir/plzig/plzig-validate"); vph=$(readelf -lW "$libdir/plzig/plzig-validate")
grep -q 'GNU_RELRO' <<<"$phdr" || { fok=0; fdetail+="no RELRO; "; }
grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$dyn" || { fok=0; fdetail+="no BIND_NOW; "; }
grep GNU_STACK <<<"$phdr" | grep -q 'RWE' && { fok=0; fdetail+="executable stack; "; }
grep -q __stack_chk_fail <<<"$syms" || { fok=0; fdetail+="no stack protector; "; }
# (nm before binutils 2.35 prints no symbol versions)
grep -qE ' __[a-z]+_chk(@|$)' <<<"$syms" || { fok=0; fdetail+="no _FORTIFY_SOURCE; "; }
grep -q ' plzig_test_' <<<"$defs" && { fok=0; fdetail+="test helpers exported; "; }
grep -qE 'RPATH|RUNPATH' <<<"$dyn" && { fok=0; fdetail+="RPATH/RUNPATH set; "; }
{ grep -q 'DYN' <<<"$vhdr" && ! grep -q INTERP <<<"$vph"; } ||
    { fok=0; fdetail+="plzig-validate is not a static PIE; "; }
if [ $fok = 1 ]; then step files PASS "zig_path default $zig_path; plzig.so RELRO, BIND_NOW, NX stack, SSP, FORTIFY, no RUNPATH"
else step files FAIL "$fdetail"; fi

# ------------------------------------------------------------------ licenses
if bash /packaging/pkgtest-licenses.sh "$family" "$major" "$src" /pkgs /in/plzig.tar.gz >/tmp/licenses.log 2>&1; then
    step licenses PASS "$(grep -c '^  ok ' /tmp/licenses.log) checks: binary, debug and source packages, and as installed"
else
    cat /tmp/licenses.log; step licenses FAIL "$(grep '^  FAIL' /tmp/licenses.log | head -3 | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ sandbox
st=$(q "CREATE EXTENSION IF NOT EXISTS plzig; DO \$\$ plzig.notice(\"compiled $RANDOM\", .{}); \$\$ LANGUAGE plzig; SELECT plzig_sandbox_status();")
st=$(tail -1 <<<"$st")
if [[ "$st" == enforced* ]]; then step sandbox PASS "$st"
else step sandbox FAIL "$st"; tail -20 /tmp/server.log; fi

# ------------------------------------------------------------------ regress
regress=$(sed -n '/^REGRESS = /,/[^\\]$/p' "$src/Makefile" | sed 's/^REGRESS = //; s/\\$//' | tr -s ' \n' ' ')
chown -R postgres:postgres "$src"
if [ ! -x "$pg_regress" ]; then
    step regress FAIL "no pg_regress at $pg_regress"
else
    su postgres -c "cd $src && $pg_regress --inputdir=test --bindir=$bindir --load-extension=plzig --host=/tmp --port=$PGPORT --user=postgres --dbname=contrib_regression $regress" >/tmp/regress.log 2>&1
    rc=$?
    grep -E '^(ok|not ok|test |     [a-z_]+ +\.\.\.)|tests (passed|failed)|^# ' /tmp/regress.log
    counts=$(grep -aoE '(All [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' /tmp/regress.log | tail -1)
    if [ $rc -eq 0 ]; then step regress PASS "$counts"
    else head -300 "$src/regression.diffs" 2>/dev/null; tail -30 /tmp/server.log; step regress FAIL "$counts"; fi
fi

# ------------------------------------------------------------------ sqlupgrade
if bash "$src/test/upgrade/check-upgrade-scripts.sh" --selftest "$bindir" >/tmp/sqlupgrade.log 2>&1; then
    step sqlupgrade PASS "$(tail -1 /tmp/sqlupgrade.log)"
else
    cat /tmp/sqlupgrade.log; step sqlupgrade FAIL "$(tail -1 /tmp/sqlupgrade.log)"
fi

# ------------------------------------------------------------------ remove
rok=1; rdetail=""
q "DROP DATABASE IF EXISTS plzig_remove" >/dev/null
q "CREATE DATABASE plzig_remove" >/dev/null
q "CREATE EXTENSION plzig; CREATE FUNCTION rm_f() RETURNS int LANGUAGE plzig AS \$\$ return 5; \$\$; SELECT rm_f();" plzig_remove >/dev/null
case $family in
    rpm) files=$(rpm -ql "plzig_$major" plzig-zig-toolchain)
         rpm -e plzig-zig-toolchain >/tmp/rm1.log 2>&1 && { rok=0; rdetail+="toolchain removable while plzig is installed; "; }
         dnf -q -y remove "plzig_$major" plzig-zig-toolchain >/tmp/rm.log 2>&1 || { rok=0; rdetail+="dnf remove failed; "; cat /tmp/rm.log; }
         rpm -q "postgresql$major-server" >/dev/null || { rok=0; rdetail+="PostgreSQL was removed too; "; } ;;
    deb) files=$(dpkg -L "postgresql-$major-plzig" plzig-zig-toolchain)
         dpkg --remove plzig-zig-toolchain >/tmp/rm1.log 2>&1 && { rok=0; rdetail+="toolchain removable while plzig is installed; "; }
         apt-get purge -y "postgresql-$major-plzig" plzig-zig-toolchain >/tmp/rm.log 2>&1 || { rok=0; rdetail+="apt-get purge failed; "; cat /tmp/rm.log; }
         dpkg-query -W -f '${Status}' "postgresql-$major" 2>/dev/null | grep -q 'install ok installed' || { rok=0; rdetail+="PostgreSQL was removed too; "; } ;;
esac
left=$(for f in $files; do [ -e "$f" ] && [ ! -d "$f" ] && echo "$f"; done)
[ -d /usr/libexec/plzig-zig-toolchain ] && left+=" /usr/libexec/plzig-zig-toolchain"
[ -d "$libdir/plzig" ] && left+=" $libdir/plzig"
[ -n "${left// /}" ] && { rok=0; rdetail+="left behind: $left; "; }
su postgres -c "$bindir/pg_ctl status -D $PGDATA" >/dev/null || { rok=0; rdetail+="server not running; "; }
call=$(q "SELECT rm_f()" plzig_remove)
grep -qE 'could not (access file|load library)' <<<"$call" || { rok=0; rdetail+="call after removal: $call; "; }
drop=$(q "DROP EXTENSION plzig CASCADE" plzig_remove)
grep -q 'DROP EXTENSION' <<<"$drop" || { rok=0; rdetail+="DROP EXTENSION after removal: $drop; "; }
q "SELECT 1" >/dev/null || { rok=0; rdetail+="server unusable; "; }
cachedir=no; [ -d "$PGDATA/plzig" ] && cachedir="kept ($(du -sh "$PGDATA/plzig" | cut -f1))"
if [ $rok = 1 ]; then step remove PASS "no files left; call: $(head -1 <<<"$call" | cut -c1-80); \$PGDATA/plzig $cachedir"
else step remove FAIL "$rdetail"; fi

stop_server
if [ $failed = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $failed
