# Build and test image for PL/Zig.
#   docker build -f docker/Dockerfile --build-arg PG_IMAGE=postgres:18.7-bookworm -t plzig-test:18 .
# Zig is an external dependency of PL/Zig: it is installed here with the
# opt-in helper (`make install-zig`, pinned SHA-256) from vendor/ when present
# (download otherwise), into /opt/zig-0.17.1, and the server is pointed at it
# by docker/test-in-container.sh.  WAMR is taken from vendor/ when present.
ARG PG_IMAGE=postgres:18.7-bookworm
FROM ${PG_IMAGE} AS base

# PG_MAJOR and PG_VERSION are set by the official postgres image.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake patch xz-utils ca-certificates curl git \
        "postgresql-server-dev-${PG_MAJOR}=${PG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

FROM base
ENV PLZIG_TEST_ZIG=/opt/zig-0.17.1/zig
COPY . /src
WORKDIR /src
RUN set -eux; \
    zt=""; [ -f vendor/zig/zig-x86_64-linux-0.17.1.tar.xz ] && [ "$(uname -m)" = x86_64 ] && zt="ZIG_TARBALL=$PWD/vendor/zig/zig-x86_64-linux-0.17.1.tar.xz"; \
    ws=""; [ -d vendor/wamr/core ] && ws="WAMR_SRC=$PWD/vendor/wamr"; \
    make install-zig ZIG_PREFIX=/opt/zig-0.17.1 $zt; \
    make -j"$(nproc)" WERROR=1 ZIG="$PLZIG_TEST_ZIG" $ws; \
    make install $ws; \
    rm -rf build/dl; \
    chown -R postgres:postgres /src

# fixtures for the ownership checks (docker/security-checks.sh): a compiler
# owned by another user, and one in a directory owned by another user
RUN set -eux; \
    install -d -m 755 /opt/plzig-test/badowner /opt/plzig-test/baddir; \
    install -m 755 -o nobody /bin/true /opt/plzig-test/badowner/zig; \
    chown nobody /opt/plzig-test/baddir; \
    install -m 755 /bin/true /opt/plzig-test/baddir/zig

USER postgres
CMD ["bash", "/src/docker/test-in-container.sh"]
