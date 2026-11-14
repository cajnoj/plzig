#!/bin/bash
# Shell-driven security checks that cannot be expressed in pg_regress
# (they need plzig.zig_path & co., which are settable only in postgresql.conf).
# Runs inside the test container against the running cluster in $PGDATA.
# $PLZIG_TEST_ZIG is the real Zig compiler the cluster is configured with.
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }

psqlq() { psql -X -q -At -v VERBOSITY=default "$@" 2>&1; }

reload() {
    pg_ctl -D "$PGDATA" reload >/dev/null
    sleep 0.5
}

set_conf() {   # set_conf <name> <value or empty to remove>; no reload
    sed -i "/^plzig.$1 /d" "$PGDATA/postgresql.conf"
    [ -n "$2" ] && echo "plzig.$1 = '$2'" >> "$PGDATA/postgresql.conf"
    return 0
}

set_zig_path() {
    set_conf zig_path "$1"
    reload
}

# compiler + lib dir for the fake compilers
set_fake() {
    set_conf zig_path "$1"
    set_conf zig_lib_dir "$fakedir/lib"
    reload
}

# back to the real compiler, lib dir auto-detected, no checksum pin
set_real() {
    set_conf zig_path "$PLZIG_TEST_ZIG"
    set_conf zig_lib_dir ""
    set_conf zig_sha256 ""
    reload
}

expect() {   # expect <description> <needle> <sql>
    local out
    out=$(psqlq -c "$3")
    if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1"; echo "$out" | sed 's/^/         /'; fi
}

compile_sql() {   # a function body that is certainly not cached yet
    echo "CREATE OR REPLACE FUNCTION tc_probe() RETURNS int LANGUAGE plzig AS \$\$ return $((RANDOM * 10000 + RANDOM % 10000)); \$\$;"
}

echo "--- security checks"
fakedir=/tmp/plzig-fake
mkdir -p "$fakedir"
for m in 1 2 3 4 5; do
    mkdir -p "$fakedir/m$m"
    gcc -O2 -static -DMODE=$m -DPGDATA="\"$PGDATA\"" -o "$fakedir/m$m/zig" /src/docker/fake/fakezig.c || exit 1
done
# m6: a compiler reporting another version
mkdir -p "$fakedir/m6"
gcc -O2 -static -DMODE=1 -DFAKE_VERSION='"0.16.0"' -DPGDATA="\"$PGDATA\"" -o "$fakedir/m6/zig" /src/docker/fake/fakezig.c || exit 1
mkdir -p "$fakedir/lib/std"
echo "// fake" > "$fakedir/lib/std/std.zig"

# 1-4: the loader's import allowlist (defence in depth behind the validator)
n=0
for case in "1|import from a module other than \"plzig\"" \
            "2|unknown host function" \
            "3|host function signature mismatch" \
            "4|non-function import"; do
    m=${case%%|*}; needle=${case#*|}; n=$((n + 1))
    set_fake "$fakedir/m$m/zig"
    expect "forbidden import rejected ($needle)" "$needle" \
        "CREATE FUNCTION imp_$m() RETURNS int LANGUAGE plzig AS \$\$ return $m$RANDOM; \$\$;"
done

# 5: what the compiler process can reach
set_fake "$fakedir/m5/zig"
out=$(psqlq <<SQL
CREATE FUNCTION probe() RETURNS int LANGUAGE plzig AS \$\$ return $RANDOM; \$\$;
SELECT 'status: ' || plzig_sandbox_status();
SQL
)
status=$(sed -n 's/^status: //p' <<<"$out")
echo "$out" | sed -n 's/^/         /p' | grep -E "open|tcp|signal|zig lib|compiler|exec"
if grep -qF "zig-lib-dir=$fakedir/lib" <<<"$out"; then pass "--zig-lib-dir passed to the compiler"; else fail "--zig-lib-dir passed to the compiler"; fi
if [[ "$status" == enforced* ]]; then
    for needle in "open /etc/passwd: Permission denied" \
                  "postgresql.conf: Permission denied" \
                  "planted.wasm: Permission denied" \
                  "open /tmp/planted: Permission denied" \
                  "open src/user.zig: ALLOWED" \
                  "read zig lib: ALLOWED" \
                  "write zig lib: Permission denied" \
                  "write compiler dir: Permission denied" \
                  "read other file near compiler: Permission denied" \
                  "exec /bin/true: Permission denied" \
                  "signal parent: Operation not permitted"; do
        if grep -qF "$needle" <<<"$out"; then pass "landlock: $needle"; else fail "landlock: $needle"; fi
    done
    abi=$(sed -n 's/.*ABI \([0-9]*\).*/\1/p' <<<"$status")
    if [ "${abi:-0}" -ge 4 ]; then
        if grep -qF "tcp connect 127.0.0.1:5432: Permission denied" <<<"$out"; then pass "landlock: TCP connect denied"; else fail "landlock: TCP connect denied"; fi
    fi
else
    fail "Landlock not enforced ($status)"
fi
set_real

# ---- the external toolchain (plzig.zig_path, zig_lib_dir, zig_sha256) ----
echo "--- toolchain checks"

# a function compiled while the compiler is configured ...
expect "compile with the configured compiler" "CREATE FUNCTION" \
    "CREATE FUNCTION tc_cached() RETURNS int LANGUAGE plzig AS \$\$ return 777; \$\$; SELECT 'CREATE FUNCTION';"

# unset: compiles fail with a hint, cached modules still run, CREATE EXTENSION works
set_zig_path ""
out=$(psqlq -c "$(compile_sql)")
if grep -qF "no Zig compiler is configured" <<<"$out" && grep -qF "HINT:" <<<"$out" &&
   grep -qF "plzig.zig_path" <<<"$out"; then
    pass "unset plzig.zig_path: compile refused with hint"
else
    fail "unset plzig.zig_path: compile refused with hint"; echo "$out" | sed 's/^/         /'
fi
expect "unset plzig.zig_path: cached function still runs (new session)" "777" "SELECT tc_cached();"
expect "unset plzig.zig_path: DO block refused" "no Zig compiler is configured" \
    "DO \$\$ // $RANDOM$RANDOM
\$\$ LANGUAGE plzig;"
psqlq -c "DROP DATABASE IF EXISTS plzig_noconf;" >/dev/null
psqlq -c "CREATE DATABASE plzig_noconf;" >/dev/null
out=$(psqlq -d plzig_noconf -c "CREATE EXTENSION plzig; SELECT 'CREATE EXTENSION';")
if grep -qx "CREATE EXTENSION" <<<"$out"; then pass "unset plzig.zig_path: CREATE EXTENSION succeeds"; else fail "unset plzig.zig_path: CREATE EXTENSION succeeds"; echo "$out" | sed 's/^/         /'; fi
psqlq -c "DROP DATABASE plzig_noconf;" >/dev/null

# relative paths are refused; PATH is never searched
set_zig_path "zig"
expect "relative plzig.zig_path refused" "plzig.zig_path must be an absolute path" "$(compile_sql)"
set_zig_path "/nonexistent/zig"
expect "missing compiler refused" "could not resolve plzig.zig_path" "$(compile_sql)"

# a decoy "zig" first on the server's PATH is never executed
decoy=/tmp/plzig-decoy
mkdir -p "$decoy"; rm -f "$decoy/ran"
printf '#!/bin/sh\ntouch %s/ran\necho 0.17.1\n' "$decoy" > "$decoy/zig"
chmod 755 "$decoy/zig"
PATH="$decoy:$PATH" pg_ctl -D "$PGDATA" -l /tmp/server.log -w restart >/dev/null
pm=$(head -1 "$PGDATA/postmaster.pid")
if tr '\0' '\n' <"/proc/$pm/environ" | grep -q "^PATH=$decoy:"; then pass "decoy: server PATH starts with the decoy directory"; else fail "decoy: server PATH starts with the decoy directory"; fi
set_zig_path ""
psqlq -c "$(compile_sql)" >/dev/null
set_zig_path "zig"
psqlq -c "$(compile_sql)" >/dev/null
set_real
expect "decoy: real compiler used" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
if [ ! -e "$decoy/ran" ]; then pass "decoy zig on PATH never executed"; else fail "decoy zig on PATH never executed"; fi
pg_ctl -D "$PGDATA" -l /tmp/server.log -w restart >/dev/null

# exact version match
set_fake "$fakedir/m6/zig"
out=$(psqlq -c "$(compile_sql)")
if grep -qF 'reports version "0.16.0", but PL/Zig requires exactly 0.17.1' <<<"$out"; then
    pass "compiler with another version refused (both versions in the error)"
else
    fail "compiler with another version refused"; echo "$out" | sed 's/^/         /'
fi

# ownership and modes of the binary, its directory, the lib directory
set_fake "$fakedir/m1/zig"
expect "fake compiler with correct version accepted" "import from a module other than" "$(compile_sql)"
chmod o+w "$fakedir/m1/zig"
expect "compiler writable by others refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1/zig"; chmod g+w "$fakedir/m1/zig"
expect "compiler writable by group refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod g-w "$fakedir/m1/zig"; chmod o+w "$fakedir/m1"
expect "compiler directory writable by others refused" "the directory containing the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1"; chmod 1777 "$fakedir/m1"
expect "sticky world-writable compiler directory refused" "the directory containing the Zig compiler is writable by group or others" "$(compile_sql)"
chmod 755 "$fakedir/m1"; chmod o+w "$fakedir/lib"
expect "lib directory writable by others refused" "the Zig lib directory is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/lib"
set_fake /opt/plzig-test/badowner/zig
expect "compiler owned by another user refused" "the Zig compiler is not owned by root or by the server user" "$(compile_sql)"
set_fake /opt/plzig-test/baddir/zig
expect "compiler in a directory owned by another user refused" "the directory containing the Zig compiler is not owned by root or by the server user" "$(compile_sql)"
ln -sf "$fakedir/m1/zig" "$fakedir/zig-link"
chmod o+w "$fakedir/m1/zig"
set_fake "$fakedir/zig-link"
expect "symlink resolved: target writable by others refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1/zig"
mkdir -p "$PGDATA/zigbin"; cp "$fakedir/m1/zig" "$PGDATA/zigbin/zig"
set_fake "$PGDATA/zigbin/zig"
expect "compiler inside the data directory refused" "must not be inside or contain the data directory" "$(compile_sql)"
rm -rf "$PGDATA/zigbin"

# lib directory selection
set_conf zig_path "$fakedir/m1/zig"; set_conf zig_lib_dir "lib"; reload
expect "relative plzig.zig_lib_dir refused" "plzig.zig_lib_dir must be an absolute path" "$(compile_sql)"
set_conf zig_lib_dir "$fakedir/m1"; reload
expect "lib dir without std/std.zig refused" "is not a Zig lib directory" "$(compile_sql)"
set_conf zig_lib_dir ""; reload
expect "no lib dir next to the compiler: refused with hint" "could not find the Zig lib directory" "$(compile_sql)"
# FHS layout <prefix>/bin/zig + <prefix>/lib/zig is auto-detected
mkdir -p /tmp/plzig-fhs/bin /tmp/plzig-fhs/lib/zig/std
cp "$fakedir/m5/zig" /tmp/plzig-fhs/bin/zig
echo "// fake" > /tmp/plzig-fhs/lib/zig/std/std.zig
set_zig_path /tmp/plzig-fhs/bin/zig
expect "FHS layout: <dir>/../lib/zig auto-detected" "zig-lib-dir=/tmp/plzig-fhs/lib/zig" "$(compile_sql)"
# a dynamically linked compiler cannot run under Landlock: refused up front
mkdir -p /tmp/plzig-dyn/lib/std
gcc -O2 -DMODE=1 -DPGDATA="\"$PGDATA\"" -o /tmp/plzig-dyn/zig /src/docker/fake/fakezig.c
echo "// fake" > /tmp/plzig-dyn/lib/std/std.zig
set_zig_path /tmp/plzig-dyn/zig
expect "dynamically linked compiler refused under Landlock" "is dynamically linked" "$(compile_sql)"

# checksum pin
set_real
real=$(readlink -f "$PLZIG_TEST_ZIG")
sum=$(sha256sum "$real" | cut -d' ' -f1)
set_conf zig_sha256 "0000000000000000000000000000000000000000000000000000000000000000"; reload
expect "wrong plzig.zig_sha256 refused" "does not match plzig.zig_sha256" "$(compile_sql)"
set_conf zig_sha256 "not-a-digest"; reload
expect "malformed plzig.zig_sha256 refused" "plzig.zig_sha256 is not a SHA-256 digest" "$(compile_sql)"
set_conf zig_sha256 "$sum"; reload
expect "correct plzig.zig_sha256 accepted" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
set_conf zig_sha256 "$(tr a-f A-F <<<"$sum")"; reload
expect "correct plzig.zig_sha256 accepted (upper case)" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
set_real

# only require, try and off are valid for plzig.compiler_sandbox; anything
# else (the old "on", boolean spellings, other case) makes every compile fail
# rather than falling back to some other mode
for v in on true 1 REQUIRE Try; do
    set_conf compiler_sandbox "$v"; reload
    expect "plzig.compiler_sandbox = $v refuses to compile" \
           "invalid value for plzig.compiler_sandbox: \"$v\"" "$(compile_sql)"
done
set_conf compiler_sandbox ""; reload
expect "plzig.compiler_sandbox default is require" "require" "LOAD 'plzig'; SHOW plzig.compiler_sandbox;"

# make install puts no Zig files anywhere
dest=/tmp/plzig-destdir
rm -rf "$dest"
if make -s -C /src install DESTDIR="$dest" >/tmp/plzig-install.log 2>&1; then
    files=$(cd "$dest" && find . -type f -o -type l | sort)
    # 6 program/data files plus 4 license files (ours, the notices, and the
    # Apache and Zig-MIT texts for the code linked into the binaries)
    zigfiles=$(grep -E '(^|/)zig$|/zig-[0-9]|/lib/std/|std\.zig$|compiler_rt|/lib/libc/' <<<"$files")
    n=$(wc -l <<<"$files")
    nlic=$(grep -cE '/extension/plzig/(LICENSE|THIRD-PARTY-NOTICES|LICENSES/[^/]+)$' <<<"$files")
    if [ -z "$zigfiles" ] && [ "$n" -eq 10 ] && [ "$nlic" -eq 4 ] && grep -q 'plzig-validate$' <<<"$files"; then
        pass "make install tree contains no Zig files ($n files)"
    else
        fail "make install tree contains no Zig files"; echo "$files" | sed 's/^/         /'
    fi
else
    fail "make install into DESTDIR"; sed 's/^/         /' /tmp/plzig-install.log
fi
rm -rf "$dest"

# 6: on-disk state: private directories and files
perm=$(stat -c '%a %U' "$PGDATA/plzig" "$PGDATA/plzig/cache" "$PGDATA/plzig/pgsql_tmp.zig-cache" | sort -u)
if [ "$perm" = "700 postgres" ]; then pass "plzig directories are 0700"; else fail "plzig directories are 0700 ($perm)"; fi
bad=$(find "$PGDATA/plzig/cache" -type f ! -perm 600 | wc -l)
cnt=$(find "$PGDATA/plzig/cache" -type f -name '*.wasm' | wc -l)
if [ "$bad" -eq 0 ] && [ "$cnt" -gt 0 ]; then pass "cache files are 0600 ($cnt modules)"; else fail "cache files are 0600 (bad=$bad)"; fi

# 7: tampering is refused, not followed
psqlq -c "CREATE FUNCTION tamper() RETURNS int LANGUAGE plzig AS \$\$ return 4242; \$\$;" >/dev/null
f=$(ls -t "$PGDATA"/plzig/cache/*.wasm | head -1)
mv "$f" "$f.orig"; ln -s /etc/passwd "$f"
expect "symlinked cache file is refused" "could not open file" "SELECT tamper();"
rm -f "$f"; mv "$f.orig" "$f"
chmod 0644 "$f"
expect "cache file with wrong permissions is refused" "wrong owner or permissions" "SELECT tamper();"
chmod 0600 "$f"
chmod 0750 "$PGDATA/plzig"
expect "plzig directory with group permissions is refused" "has group or other permissions" "SELECT tamper();"
chmod 0700 "$PGDATA/plzig"
expect "works again after repair" "4242" "SELECT tamper();"

# 8: no zombie or leftover compiler processes
z=$(awk '{ if ($3 == "Z") print }' /proc/[0-9]*/stat 2>/dev/null | wc -l)
c=$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | grep -cE '/zig$|plzig-validate$')
if [ "$z" -eq 0 ]; then pass "no zombie processes"; else fail "no zombie processes ($z)"; fi
if [ "$c" -eq 0 ]; then pass "no leftover compiler processes"; else fail "no leftover compiler processes ($c)"; fi

echo "--- security checks: $fails failure(s)"
exit $fails
