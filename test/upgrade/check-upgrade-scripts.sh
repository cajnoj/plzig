#!/bin/bash
# Extension upgrade scripts (doc/packaging.md "Versions"): every upgrade
# path PostgreSQL knows for the installed plzig scripts must end in exactly
# the objects a fresh CREATE EXTENSION of the default version creates --
# functions with their signatures, strictness, volatility, security, source
# and ACLs, the language with its handlers, trust and ACL, and comments.
#
#   check-upgrade-scripts.sh [--selftest] <PostgreSQL bindir>
#
# Runs as root against a running server (psql as the postgres OS user, the
# environment's PGHOST/PGPORT), in a scratch database it creates and drops.
# --selftest first installs two temporary scripts next to the real ones
# (plzig--0.0selftest.sql = the default version's script plus one extra
# function, plzig--0.0selftest--<default>.sql dropping it) and checks that
# the correct path passes and a divergent one (an upgrade script that also
# grants EXECUTE on plzig_cache_clear() to PUBLIC) is reported; the
# temporary scripts are removed again.  Needs write access to the
# extension directory, so it is meant for test containers.
set -uo pipefail
selftest=0
[ "${1:-}" = --selftest ] && { selftest=1; shift; }
bindir=${1:?usage: check-upgrade-scripts.sh [--selftest] <bindir>}
share=$("$bindir/pg_config" --sharedir)/extension
db=plzig_upgrade_check

q() {   # q <database> <sql>
    su postgres -c "\"$bindir/psql\" -X -At -q -v ON_ERROR_STOP=1 -d \"\$0\" -c \"\$1\"" "$1" "$2" 2>&1
}
default=$(sed -n "s/^default_version = '\(.*\)'$/\1/p" "$share/plzig.control")
[ -n "$default" ] || { echo "no default_version in $share/plzig.control"; exit 1; }

# the extension's member objects and everything about them that matters
snapshot_sql="
WITH ext AS (SELECT oid FROM pg_extension WHERE extname = 'plzig'),
members AS (
    SELECT d.classid, d.objid FROM pg_depend d, ext
     WHERE d.refclassid = 'pg_extension'::regclass AND d.refobjid = ext.oid AND d.deptype = 'e')
SELECT 'function ' || p.oid::regprocedure || ' returns ' || p.prorettype::regtype
       || ' strict=' || p.proisstrict || ' volatile=' || p.provolatile::text
       || ' secdef=' || p.prosecdef || ' parallel=' || p.proparallel::text
       || ' lang=' || l.lanname || ' src=' || p.prosrc || ' bin=' || coalesce(p.probin, '')
       || ' acl=' || coalesce(p.proacl::text, 'default') || ' config=' || coalesce(p.proconfig::text, '')
       || ' comment=' || coalesce(obj_description(p.oid, 'pg_proc'), '')
  FROM members m JOIN pg_proc p ON m.classid = 'pg_proc'::regclass AND p.oid = m.objid
  JOIN pg_language l ON l.oid = p.prolang
UNION ALL
SELECT 'language ' || l.lanname || ' trusted=' || l.lanpltrusted || ' pl=' || l.lanispl
       || ' handler=' || l.lanplcallfoid::regproc || ' inline=' || l.laninline::regproc
       || ' validator=' || l.lanvalidator::regproc || ' acl=' || coalesce(l.lanacl::text, 'default')
       || ' comment=' || coalesce(obj_description(l.oid, 'pg_language'), '')
  FROM members m JOIN pg_language l ON m.classid = 'pg_language'::regclass AND l.oid = m.objid
UNION ALL
SELECT 'other ' || pg_describe_object(m.classid, m.objid, 0)
  FROM members m WHERE m.classid NOT IN ('pg_proc'::regclass, 'pg_language'::regclass)
UNION ALL
SELECT 'extension schema=' || e.extnamespace::regnamespace || ' relocatable=' || e.extrelocatable
       || ' config=' || coalesce(e.extconfig::text, '') || ' comment=' || coalesce(obj_description(e.oid, 'pg_extension'), '')
  FROM pg_extension e WHERE e.extname = 'plzig'
ORDER BY 1"

fresh_db() { q postgres "DROP DATABASE IF EXISTS $db" >/dev/null; q postgres "CREATE DATABASE $db" >/dev/null; }

check_all() {   # prints one line per path; returns the number of divergent paths
    local fresh paths bad=0 src got
    fresh_db
    q "$db" "CREATE EXTENSION plzig" >/dev/null || { echo "CREATE EXTENSION plzig failed"; return 99; }
    fresh=$(q "$db" "$snapshot_sql") || { echo "catalog query failed: $fresh"; return 99; }
    paths=$(q "$db" "SELECT source || ' ' || path FROM pg_extension_update_paths('plzig') WHERE target = '$default' AND path IS NOT NULL ORDER BY 1")
    if [ -z "$paths" ]; then
        echo "no upgrade path to $default"
        return 0
    fi
    while read -r src path; do
        fresh_db
        if ! out=$(q "$db" "CREATE EXTENSION plzig VERSION '$src'; ALTER EXTENSION plzig UPDATE TO '$default'"); then
            echo "FAIL $path: $out"; bad=$((bad + 1)); continue
        fi
        got=$(q "$db" "$snapshot_sql") || { echo "FAIL $path: catalog query failed: $got"; bad=$((bad + 1)); continue; }
        if [ "$got" = "$fresh" ]; then
            echo "ok   $path"
        else
            echo "FAIL $path differs from a fresh install of $default:"
            diff <(echo "$fresh") <(echo "$got") | sed 's/^/       /'
            bad=$((bad + 1))
        fi
    done <<<"$paths"
    return $bad
}

if [ $selftest = 1 ]; then
    fx_base=$share/plzig--0.0selftest.sql
    fx_up=$share/plzig--0.0selftest--$default.sql
    [ ! -e "$fx_base" ] && [ ! -e "$fx_up" ] || { echo "self-test scripts already exist in $share"; exit 1; }
    trap 'rm -f "$fx_base" "$fx_up"' EXIT
    { cat "$share/plzig--$default.sql"
      echo "CREATE FUNCTION plzig_selftest_obsolete() RETURNS int LANGUAGE sql AS 'SELECT 1';"
    } >"$fx_base"
    echo "DROP FUNCTION plzig_selftest_obsolete();" >"$fx_up"
    chmod 0644 "$fx_base" "$fx_up"
    out=$(check_all); rc=$?
    echo "$out" | sed 's/^/selftest (correct script): /'
    if [ $rc -ne 0 ] || ! grep -q "^ok   0.0selftest--$default" <<<"$out"; then
        echo "self-test failed: a correct upgrade script was reported"; exit 1
    fi
    { echo "DROP FUNCTION plzig_selftest_obsolete();"
      echo "GRANT EXECUTE ON FUNCTION plzig_cache_clear() TO PUBLIC;"
    } >"$fx_up"
    out=$(check_all); rc=$?
    echo "$out" | sed 's/^/selftest (divergent script): /'
    if [ $rc -eq 0 ] || ! grep -q "plzig_cache_clear" <<<"$out"; then
        echo "self-test failed: a divergent upgrade script was not reported"; exit 1
    fi
    rm -f "$fx_base" "$fx_up"
    trap - EXIT
fi

out=$(check_all); rc=$?
echo "$out"
q postgres "DROP DATABASE IF EXISTS $db" >/dev/null
nscripts=$(ls "$share"/plzig--*--*.sql 2>/dev/null | wc -l)
note=""; [ $selftest = 1 ] && note="; self-test passed"
if [ $rc -eq 0 ]; then
    echo "upgrade scripts: $nscripts, every path to $default equals a fresh install$note"
    exit 0
fi
echo "upgrade scripts: $rc path(s) diverge from a fresh install of $default"
exit 1
