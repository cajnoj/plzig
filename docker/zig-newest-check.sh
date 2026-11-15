#!/bin/sh
# Early warning for the next Zig upgrade (PLAN.md §14, "CI"): the unit tests
# of the source validator and of the guest SDK (`make check-zig`) with the
# newest Zig release instead of the pinned one.  Test-only: it overrides
# ZIG_VERSION for this one make invocation, in a scratch copy of the source;
# nothing is installed, and the product build (plzig.so refuses any compiler
# but the pinned one) is not touched.  A failure means work for the next
# upgrade (e.g. a new builtin the validator does not classify), not a bug.
#
#   docker/zig-newest-check.sh
#
# Needs make, a C toolchain, pg_config (PGXS), curl, xz, perl, sha256sum.
# Environment:
#   ZIG_NEWEST_VERSION   test this version instead of the newest release
#   ZIG_NEWEST_TARBALL   use this local tarball (with ZIG_NEWEST_VERSION),
#                        no download
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
pin=$(sh "$src/third_party/zig-version.sh" "$src/Makefile")
arch=$(uname -m)
work=$(mktemp -d /tmp/zig-newest.XXXXXX)
trap 'rm -rf "$work"' EXIT

if [ -n "${ZIG_NEWEST_TARBALL:-}" ]; then
    v=${ZIG_NEWEST_VERSION:?ZIG_NEWEST_VERSION is needed with ZIG_NEWEST_TARBALL}
    cp "$ZIG_NEWEST_TARBALL" "$work/zig.tar.xz"
else
    curl -fsSL --proto '=https' --tlsv1.2 -o "$work/index.json" https://ziglang.org/download/index.json
    # newest X.Y.Z release (not "master"), its tarball and SHA-256 for this arch
    set -- $(perl -MJSON::PP -e '
        my ($file, $arch, $want) = @ARGV;
        open(my $fh, "<", $file) or die "$file: $!";
        my $idx = decode_json(do { local $/; <$fh> });
        my @v = grep { /^\d+\.\d+\.\d+$/ } keys %$idx;
        @v = sort { my @a = split /\./, $a; my @b = split /\./, $b;
                    $a[0] <=> $b[0] || $a[1] <=> $b[1] || $a[2] <=> $b[2] } @v;
        my $v = $want ne "" ? $want : $v[-1];
        my $e = $idx->{$v}{"$arch-linux"} or die "no $arch-linux build of Zig $v\n";
        print "$v $e->{tarball} $e->{shasum}\n";
    ' "$work/index.json" "$arch" "${ZIG_NEWEST_VERSION:-}")
    v=$1; url=$2; sha=$3
    case $url in https://ziglang.org/*) ;; *) echo "unexpected tarball URL $url" >&2; exit 1 ;; esac
    curl -fsSL --proto '=https' --tlsv1.2 -o "$work/zig.tar.xz" "$url"
    echo "$sha  $work/zig.tar.xz" | sha256sum -c - >/dev/null || { echo "SHA-256 mismatch for $url" >&2; exit 1; }
fi
echo "--- newest Zig release: $v (pinned: $pin)"
mkdir "$work/zig"
tar -xJf "$work/zig.tar.xz" -C "$work/zig" --strip-components=1
zig=$work/zig/zig
got=$("$zig" version)
[ "$got" = "$v" ] || { echo "the tarball's zig reports $got, expected $v" >&2; exit 1; }

# a scratch copy: no build output of this run lands in the source tree
mkdir "$work/src"
(cd "$src" && tar --exclude=./build --exclude=./vendor --exclude=./.git -cf - .) | (cd "$work/src" && tar -xf -)
if make -C "$work/src" check-zig ZIG="$zig" ZIG_VERSION="$v"; then
    echo "RESULT: PASS (validator and SDK unit tests with Zig $v; pinned $pin)"
else
    echo "RESULT: FAIL (validator and SDK unit tests with Zig $v; pinned $pin) -- work for the next Zig upgrade"
    exit 1
fi
