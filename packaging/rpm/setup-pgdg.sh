#!/bin/sh
# Configure the PGDG yum repositories (https://yum.postgresql.org) for the
# given PostgreSQL majors on an EL or Fedora container, with signature checks
# of packages and repository metadata.  The repository key is the one in
# packaging/keys/PGDG-RPM-GPG-KEY (copied next to this script); its
# fingerprint is checked against the pin below before it is trusted.
#
#   setup-pgdg.sh <key file> <major>...
#
# PostgreSQL 19 is a release candidate: PGDG publishes it in the "testing"
# tree (/pub/repos/yum/testing/19), not on EL 8.
set -eu
key=$1; shift
pin=D4BF08AE67A0B4C7A1DBCCD240BCA2B408B40D20

. /etc/os-release
case $ID in
    fedora) tree=fedora/fedora-$VERSION_ID-\$basearch; el= ;;
    almalinux|rocky|rhel|centos|ol)
        el=${VERSION_ID%%.*}; tree=redhat/rhel-$el-\$basearch ;;
    *) echo "setup-pgdg.sh: unsupported distribution $ID" >&2; exit 1 ;;
esac

command -v gpg >/dev/null 2>&1 || dnf -q -y install gnupg2 >/dev/null
fpr=$(gpg --batch --with-colons --show-keys "$key" | awk -F: '$1 == "fpr" { print $10; exit }')
if [ "$fpr" != "$pin" ]; then
    echo "setup-pgdg.sh: $key has fingerprint '$fpr', expected $pin" >&2
    exit 1
fi
install -m 0644 "$key" /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY
rpm --import /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY

case $el in
    8|9)
        # the distribution's own PostgreSQL module would shadow PGDG's packages
        dnf -q -y module disable postgresql >/dev/null 2>&1 || true ;;
esac
# postgresqlNN-devel needs perl(IPC::Run) & co. from PowerTools/CRB
case $el in
    8) dnf -q -y install dnf-plugins-core >/dev/null; dnf config-manager --set-enabled powertools ;;
    9|10) dnf -q -y install dnf-plugins-core >/dev/null; dnf config-manager --set-enabled crb ;;
esac

# Fedora (and EL 10's AppStream) ship PostgreSQL packages under the same
# names as PGDG's (postgresql19-server, ...) but with another layout; keep
# them out, as PGDG's instructions say, so that only PGDG provides them.
# dnf5 (Fedora 41+) keeps the distribution's repository files in
# /usr/share/dnf5/repos.d and takes local changes from repos.override.d.
if [ -d /etc/dnf/repos.override.d ] || [ -d /usr/share/dnf5/repos.d ]; then
    mkdir -p /etc/dnf/repos.override.d
    dnf -q repolist --enabled 2>/dev/null | awk '$1 != "repo" { print $1 }' |
        while read -r id; do printf '[%s]\nexcludepkgs=postgresql*\n\n' "$id"; done \
        >/etc/dnf/repos.override.d/50-plzig-pgdg.repo
fi
for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    grep -q '^excludepkgs=postgresql\*$' "$f" || sed -i '/^\[.*\]$/a excludepkgs=postgresql*' "$f"
done

repo=/etc/yum.repos.d/pgdg-plzig.repo
: >"$repo"
for v in "$@"; do
    case $v in
        19) path=testing/19/$tree ;;
        *) path=$v/$tree ;;
    esac
    cat >>"$repo" <<EOF
[pgdg$v]
name=PostgreSQL $v (PGDG)
baseurl=https://download.postgresql.org/pub/repos/yum/$path
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY

EOF
done
echo "PGDG repositories for PostgreSQL $* configured (key $pin)"
