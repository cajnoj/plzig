# RPM builder image (packaging/build-packages.sh): an EL or Fedora base with
# the PGDG repositories (signature-checked, packaging/rpm/setup-pgdg.sh) and
# the build dependencies of every PostgreSQL major built there.  The package
# build itself runs from this image with --network none.
# Build context: packaging/.
ARG BASE=almalinux:9
FROM ${BASE}
ARG PG_MAJORS="14 15 16 17 18 19"
COPY keys/PGDG-RPM-GPG-KEY rpm/setup-pgdg.sh /tmp/plzig-setup/
RUN set -eux; \
    sh /tmp/plzig-setup/setup-pgdg.sh /tmp/plzig-setup/PGDG-RPM-GPG-KEY $PG_MAJORS; \
    devel=""; for v in $PG_MAJORS; do devel="$devel postgresql$v-devel"; done; \
    dnf -y install --setopt=install_weak_deps=False \
        rpm-build redhat-rpm-config gcc make cmake patch tar gzip xz \
        findutils diffutils which $devel; \
    (dnf -y install --setopt=install_weak_deps=False rpmlint || true); \
    dnf clean all; rm -rf /tmp/plzig-setup
