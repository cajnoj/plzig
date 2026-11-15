#!/bin/sh
# Print the pinned Zig version: ZIG_VERSION in the Makefile, the single
# source of the pin.  Scripts and Dockerfiles that need the version (test
# images, fuzz and static-analysis builds, CI) take it from here.
#   third_party/zig-version.sh [path/to/Makefile]
set -eu
mk=${1:-$(dirname "$0")/../Makefile}
v=$(sed -n 's/^ZIG_VERSION := \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$mk")
case $v in
    *[!0-9.]* | "") echo "zig-version.sh: no single ZIG_VERSION := X.Y.Z line in $mk" >&2; exit 1 ;;
esac
echo "$v"
