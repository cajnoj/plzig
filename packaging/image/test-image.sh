#!/bin/bash
# Test an evaluation image plzig/postgres:<major>: the official entrypoint
# initialises and starts a server; PL/Zig works with the packaged defaults
# (compiler path, sandbox "require", satisfied here because containers share
# the host's kernel); and the image contains no procedural language besides
# PL/pgSQL and PL/Zig -- in particular no PL/Python and no PL/Perl, neither
# as packages nor as files nor as available extensions.
#
#   packaging/image/test-image.sh <major>
set -uo pipefail
m=${1:?usage: test-image.sh <major>}
img=plzig/postgres:$m
name=plzig-image-test-$m-$$
fails=0
ok() { echo "  ok   - $1"; }
no() { echo "  FAIL - $1${2:+: $2}"; fails=$((fails + 1)); }

docker run -d --name "$name" -e POSTGRES_PASSWORD=evaluation -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 "$img" >/dev/null || { echo "cannot start $img"; exit 1; }
trap 'docker rm -f "$name" >/dev/null 2>&1' EXIT
for _ in $(seq 1 60); do
    docker exec "$name" pg_isready -q -U postgres 2>/dev/null &&
        docker exec "$name" psql -U postgres -XAtc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done
psql_() { docker exec -i "$name" psql -U postgres -X -At -v ON_ERROR_STOP=1 "$@" 2>&1; }

echo "--- $img"
out=$(psql_ <<'SQL'
CREATE EXTENSION plzig;
CREATE FUNCTION image_add(a int, b int) RETURNS int STRICT LANGUAGE plzig AS $$ return a + b; $$;
SELECT image_add(40, 2);
SELECT plzig_sandbox_status();
SQL
)
grep -qx 42 <<<"$out" && ok "CREATE EXTENSION, compile and call with the packaged defaults" || no "compile and call" "$out"
grep -q '^enforced' <<<"$out" && ok "compiler sandbox: $(grep '^enforced' <<<"$out")" || no "compiler sandbox enforced" "$out"
s=$(psql_ -c "LOAD 'plzig'" -c "SELECT setting FROM pg_settings WHERE name = 'plzig.compiler_sandbox'" | tail -1)
[ "$s" = require ] && ok "plzig.compiler_sandbox = require (unchanged default)" || no "plzig.compiler_sandbox" "$s"

pls=$(docker exec "$name" sh -c 'dpkg-query -W -f "\${Package}\n" | grep -Ei "plpython|plperl|pltcl|plr|plv8|pljava|plsh"; ls /usr/lib/postgresql/*/lib | grep -Ei "^pl(python|perl|tcl|r|v8|java|sh)"; ls /usr/share/postgresql/*/extension | grep -Ei "^pl(python|perl|tcl|r|v8|java|sh)"')
[ -z "$pls" ] && ok "no other procedural language packages or files" || no "other procedural languages present" "$pls"
avail=$(psql_ -c "SELECT string_agg(name, ',' ORDER BY name) FROM pg_available_extensions WHERE name LIKE 'pl%'")
[ "$avail" = "plpgsql,plzig" ] && ok "available pl* extensions: $avail" || no "available pl* extensions" "$avail"
langs=$(psql_ -c "SELECT string_agg(lanname, ',' ORDER BY lanname) FROM pg_language WHERE lanispl")
[ "$langs" = "plpgsql,plzig" ] && ok "installed languages: $langs" || no "installed languages" "$langs"

if [ $fails -eq 0 ]; then echo "IMAGE $img: PASS"; exit 0; fi
docker logs "$name" 2>&1 | tail -20
echo "IMAGE $img: FAIL ($fails)"
exit 1
