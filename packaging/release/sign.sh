#!/bin/sh
# Sign a release directory's SHA256SUMS (doc/packaging.md "Release
# artefacts"): a detached, ASCII-armoured OpenPGP signature SHA256SUMS.asc,
# which covers every artefact through its checksum.
#
#   PLZIG_SIGNING_KEY=<key id or fingerprint> packaging/release/sign.sh <dir>
#
# The key comes from the environment only: PLZIG_SIGNING_KEY names a secret
# key in the caller's GnuPG keyring (GNUPGHOME may point to another one).
# Without PLZIG_SIGNING_KEY nothing is signed and the script says so and
# exits 0; with it, a missing key or a failed signature is an error.  This
# script never creates, imports or exports keys.  Packages themselves (RPM,
# Debian) are signed by the repositories that publish them (phase F).
set -eu
dir=${1:?usage: sign.sh <dir>}
[ -f "$dir/SHA256SUMS" ] || { echo "sign.sh: $dir/SHA256SUMS missing (run checksums.sh first)" >&2; exit 1; }
if [ -z "${PLZIG_SIGNING_KEY:-}" ]; then
    echo "signing skipped: PLZIG_SIGNING_KEY is not set (no signature written; the artefacts are unsigned)"
    exit 0
fi
command -v gpg >/dev/null 2>&1 || { echo "sign.sh: gpg not found" >&2; exit 1; }
if ! gpg --batch --list-secret-keys -- "$PLZIG_SIGNING_KEY" >/dev/null 2>&1; then
    echo "sign.sh: no secret key '$PLZIG_SIGNING_KEY' in the keyring" >&2
    exit 1
fi
rm -f "$dir/SHA256SUMS.asc"
gpg --batch --yes --armor --local-user "$PLZIG_SIGNING_KEY" \
    --output "$dir/SHA256SUMS.asc" --detach-sign "$dir/SHA256SUMS"
gpg --batch --verify "$dir/SHA256SUMS.asc" "$dir/SHA256SUMS"
echo "signed: $dir/SHA256SUMS.asc"
