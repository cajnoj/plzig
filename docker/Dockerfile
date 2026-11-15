# Build and test image for PL/Zig.
#   docker build -f docker/Dockerfile --build-arg PG_IMAGE=postgres:18.7-bookworm -t plzig-test:18 .
# Zig is an external dependency of PL/Zig: it is installed here with the
# opt-in helper (`make install-zig`, pinned SHA-256) from vendor/ when present
# (download otherwise), into /opt/zig (the pinned version, from the Makefile's
# ZIG_VERSION via third_party/zig-version.sh), and the server is pointed at it
# by docker/test-in-container.sh.  WAMR is taken from vendor/ when present.
#
# Besides the release build (installed), the image holds test-only material
# outside the installed tree:
#   /opt/plzig-testing   a PLZIG_TESTING=1 build staged with DESTDIR (the
#                        C unit-test helpers); docker/run-all.sh copies it over
#                        the installation in a throw-away container only
#   /opt/plzig-test      fake/gated compilers for the security, isolation
#                        and TAP tests
ARG PG_IMAGE=postgres:18.7-bookworm
FROM ${PG_IMAGE} AS base

# PG_MAJOR and PG_VERSION are set by the official postgres image.
# libipc-run-perl: the TAP tests (PostgreSQL::Test::Cluster).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake patch xz-utils ca-certificates curl git \
        libipc-run-perl \
        "postgresql-server-dev-${PG_MAJOR}=${PG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

FROM base
ENV PLZIG_TEST_ZIG=/opt/zig/zig
COPY . /src
WORKDIR /src
RUN set -eux; \
    arch=$(uname -m); \
    zv=$(sh third_party/zig-version.sh); \
    zt=""; [ -f "vendor/zig/zig-$arch-linux-$zv.tar.xz" ] && zt="ZIG_TARBALL=$PWD/vendor/zig/zig-$arch-linux-$zv.tar.xz"; \
    ws=""; [ -d vendor/wamr/core ] && ws="WAMR_SRC=$PWD/vendor/wamr"; \
    make install-zig ZIG_PREFIX=/opt/zig $zt; \
    make -j"$(nproc)" WERROR=1 ZIG="$PLZIG_TEST_ZIG" $ws; \
    make install $ws; \
    # the C unit-test build, from a copy, staged (never installed here)
    cp -a /src /tmp/plzig-testing-src; \
    make -C /tmp/plzig-testing-src clean; \
    # ... and through the `zig build` front end (build.zig), so that it is tested too
    zws=""; [ -d vendor/wamr/core ] && zws="-Dwamr-src=$PWD/vendor/wamr"; \
    (cd /tmp/plzig-testing-src && \
     "$PLZIG_TEST_ZIG" build -Dwerror=true -Dtesting=true -Djobs="$(nproc)" $zws && \
     "$PLZIG_TEST_ZIG" build pg-install -Dtesting=true -Ddestdir=/opt/plzig-testing $zws); \
    rm -rf /root/.cache/zig; \
    rm -rf /tmp/plzig-testing-src build/dl; \
    chown -R postgres:postgres /src

# fixtures for the ownership checks (docker/security-checks.sh): a compiler
# owned by another user, and one in a directory owned by another user; and
# the gated test compiler (test/gatezig.sh) for the isolation and TAP tests
RUN set -eux; \
    install -d -m 755 /opt/plzig-test/badowner /opt/plzig-test/baddir /opt/plzig-test/gatezig; \
    install -m 755 -o nobody /bin/true /opt/plzig-test/badowner/zig; \
    chown nobody /opt/plzig-test/baddir; \
    install -m 755 /bin/true /opt/plzig-test/baddir/zig; \
    sed -e "s|@REAL_ZIG@|$PLZIG_TEST_ZIG|" -e "s|@GATE_DIR@|/tmp/plzig-gates|" \
        /src/test/gatezig.sh > /opt/plzig-test/gatezig/zig; \
    chmod 755 /opt/plzig-test/gatezig/zig

USER postgres
CMD ["bash", "/src/docker/test-in-container.sh"]
