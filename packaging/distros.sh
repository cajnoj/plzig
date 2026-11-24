# Target distributions of the packages (sourced by the packaging scripts).
#
#   distro_info <name>   sets FAMILY (rpm|deb), BASE (container image) and
#                        MAJORS (the PostgreSQL majors PGDG provides there)
#
# PostgreSQL 14 is end-of-life and no longer a supported/tested target; it
# is dropped from the packaged majors (the pg_upgrade test still upgrades
# off it).  PostgreSQL 19 is 19.0 (GA): PGDG publishes it in the apt
# component "19" and the yum tree.  PGDG has no PostgreSQL 19 for EL 8
# (checked 2026-11-15), so el8 builds 15-18.
ALL_DISTROS="el8 el9 el10 fedora45 debian12 debian13 ubuntu22.04 ubuntu24.04 ubuntu26.04"

distro_info() {
    MAJORS="15 16 17 18 19"
    case $1 in
        el8)         FAMILY=rpm; BASE=almalinux:8; MAJORS="15 16 17 18" ;;
        el9)         FAMILY=rpm; BASE=almalinux:9 ;;
        el10)        FAMILY=rpm; BASE=almalinux:10 ;;
        fedora45)    FAMILY=rpm; BASE=fedora:45 ;;
        debian12)    FAMILY=deb; BASE=debian:bookworm ;;
        debian13)    FAMILY=deb; BASE=debian:trixie ;;
        ubuntu22.04) FAMILY=deb; BASE=ubuntu:22.04 ;;
        ubuntu24.04) FAMILY=deb; BASE=ubuntu:24.04 ;;
        ubuntu26.04) FAMILY=deb; BASE=ubuntu:26.04 ;;
        *) echo "unknown distribution '$1' (known: $ALL_DISTROS)" >&2; return 1 ;;
    esac
}
