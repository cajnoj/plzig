#!/bin/sh
# Configure apt.postgresql.org (PGDG) on a Debian or Ubuntu container for
# the given PostgreSQL majors.  apt checks the repository's signatures with
# the key in packaging/keys/apt.postgresql.org.asc, whose fingerprint is
# checked against the pin below first.
#
#   setup-pgdg.sh <key file> <major>...
#
# PostgreSQL 19 is a release candidate, published in the component "19".
# Needs gnupg and ca-certificates (installed from the distribution if missing).
set -eu
key=$1; shift
pin=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8
export DEBIAN_FRONTEND=noninteractive

if ! command -v gpg >/dev/null 2>&1 || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends gnupg ca-certificates >/dev/null
fi
fpr=$(gpg --batch --with-colons --show-keys "$key" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
if [ "$fpr" != "$pin" ]; then
    echo "setup-pgdg.sh: $key has fingerprint '$fpr', expected $pin" >&2
    exit 1
fi
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$key" /etc/apt/keyrings/apt.postgresql.org.asc

. /etc/os-release
components=main
for v in "$@"; do
    [ "$v" = 19 ] && components="$components 19"
done
echo "deb [signed-by=/etc/apt/keyrings/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg $components" \
    >/etc/apt/sources.list.d/pgdg-plzig.list
apt-get update -qq
echo "apt.postgresql.org configured for PostgreSQL $* ($VERSION_CODENAME, key $pin)"
