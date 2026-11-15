# Benchmark image for PL/Zig (bench/run.sh).  BENCHMARK ONLY.
#
#   docker build -f bench/Dockerfile --build-arg BASE=plzig-test:18.7 -t plzig-bench:18.7 bench
#
# Starts from the PL/Zig test image (docker/Dockerfile: PostgreSQL from PGDG
# with PL/Zig installed and the pinned Zig in /opt/zig) and adds the
# comparison languages PL/Python (plpython3u) and PL/Perl (plperl) from the
# same PGDG repository, pinned to the server's exact version, plus the
# Python driver used by the benchmark runner, and perf for bench/profile.sh.
#
# PL/Python and PL/Perl are installed ONLY here.  They are not a build, test
# or runtime dependency of PL/Zig and must never be added to docker/Dockerfile*
# or to any package metadata (docker/security-checks.sh checks the test image).
ARG BASE=plzig-test:18.7
FROM ${BASE}
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-plpython3-${PG_MAJOR}=${PG_VERSION}" \
        "postgresql-plperl-${PG_MAJOR}=${PG_VERSION}" \
        python3-psycopg2 procps linux-perf; \
    rm -rf /var/lib/apt/lists/*
USER postgres
WORKDIR /tmp
CMD ["python3", "/bench/driver.py", "--help"]
