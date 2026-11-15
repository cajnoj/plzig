# Debian/Ubuntu builder image (packaging/build-packages.sh): the base with
# apt.postgresql.org (signature-checked, packaging/deb/setup-pgdg.sh) and the
# build dependencies of every PostgreSQL major built there, plus lintian.
# The package build itself runs from this image with --network none.
# Build context: packaging/.
ARG BASE=debian:trixie
FROM ${BASE}
ARG PG_MAJORS="14 15 16 17 18 19"
ENV DEBIAN_FRONTEND=noninteractive
COPY keys/apt.postgresql.org.asc deb/setup-pgdg.sh /tmp/plzig-setup/
RUN set -eux; \
    sh /tmp/plzig-setup/setup-pgdg.sh /tmp/plzig-setup/apt.postgresql.org.asc $PG_MAJORS; \
    dev=""; for v in $PG_MAJORS; do dev="$dev postgresql-server-dev-$v"; done; \
    apt-get install -y --no-install-recommends \
        build-essential debhelper devscripts lintian fakeroot cmake patch \
        xz-utils postgresql-common postgresql-server-dev-all $dev; \
    rm -rf /var/lib/apt/lists/* /tmp/plzig-setup
