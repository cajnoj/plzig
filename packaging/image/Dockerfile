# Evaluation image plzig/postgres:<major> (doc/packaging.md "Evaluation
# image"): the official PostgreSQL image plus the PL/Zig packages for its
# distribution (postgresql-<major>-plzig and plzig-zig-toolchain, built by
# packaging/build-packages.sh) -- and no other procedural language than
# PostgreSQL's built-in PL/pgSQL.  Built locally by
# packaging/image/build-image.sh; never pushed by this repository.
#
# Build context: a directory holding exactly the two .deb files.
ARG PG_IMAGE=postgres:18.7-bookworm
FROM ${PG_IMAGE}
ARG PLZIG_VERSION=unknown
COPY *.deb /tmp/plzig-debs/
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/plzig-debs/*.deb; \
    rm -rf /tmp/plzig-debs /var/lib/apt/lists/*
LABEL org.opencontainers.image.title="PostgreSQL with PL/Zig (evaluation)" \
      org.opencontainers.image.description="PostgreSQL with the PL/Zig procedural language and its Zig toolchain package; for evaluation. The compiler sandbox's default (plzig.compiler_sandbox = require) needs a host kernel with Landlock ABI >= 6 (Linux 6.12+) and seccomp." \
      org.opencontainers.image.version="${PLZIG_VERSION}" \
      org.opencontainers.image.licenses="PostgreSQL AND Apache-2.0 WITH LLVM-exception AND MIT AND NCSA AND Zlib AND BSD-3-Clause"
