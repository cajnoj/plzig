# Packaging PL/Zig

How PL/Zig is versioned, turned into a source tarball and into RPM and
Debian packages, how those packages are tested, and what is still open
before anything can be published (PLAN.md §13 E/F). Nothing in this
repository publishes anything: no registry push, no upload, no tag, no
release. Publishing is phase F and needs the owner.

| What | Where |
|---|---|
| Versions of a tree, for scripts | `packaging/versions.sh` |
| Reproducible source tarball | `make dist` → `packaging/make-dist.sh` |
| Offline source build, proven without network | `packaging/test-offline-build.sh` |
| Zig toolchain package (both formats) | `packaging/zig-toolchain/` |
| RPM: specs, builder image, build script | `packaging/rpm/` |
| Debian: extension source package | `debian/` |
| Debian: builder image, build script | `packaging/deb/` |
| Target distributions and PostgreSQL majors | `packaging/distros.sh` |
| Build the packages of one distribution | `packaging/build-packages.sh <distro> [release]` |
| Installed-package test | `packaging/test-packages.sh <distro> <major>` |
| The whole matrix | `packaging/test-matrix.sh [distro...]` |
| Extension upgrade-script check | `test/upgrade/check-upgrade-scripts.sh` |
| Evaluation image `plzig/postgres:<major>` | `packaging/image/` |
| Checksums, SBOM, signing | `packaging/release/` |
| PGDG repository keys (pinned fingerprints) | `packaging/keys/` |
| CI | `.github/workflows/ci.yml` (job `packages`), `.github/workflows/packaging.yml` |

Everything runs in Docker; the host needs Docker, GNU make, GNU tar, git,
gzip, curl and Python 3 (the SBOM).

## Versions

There are four version numbers. The compatibility table in the
[README](../README.md#compatibility) is the one place that relates them for
users; this section says where each comes from.

| Version | Example | Source | Changes when |
|---|---|---|---|
| PL/Zig release (semver) | `1.0.0`, now `1.0.0-dev` | `PLZIG_VERSION` in the `Makefile` | every release |
| SQL extension version | `1.0` | `MAJOR.MINOR` of `PLZIG_VERSION` (`EXT_VERSION`) | a minor or major release |
| Host/guest ABI | `5` | `version` in `abi/plzig-abi.table` (generated: `PLZIG_ABI_VERSION`, `plzig.abi_version`) | the ABI changes (independently) |
| Zig pin | `0.17.1` | `ZIG_VERSION` in the `Makefile` | a Zig upgrade (PLAN.md §14) |

* **Release version.** Semantic versioning (PLAN.md §14): a Zig minor
  upgrade is a PL/Zig major, a Zig patch upgrade a PL/Zig minor, PL/Zig's
  own incompatible changes (SDK, SQL surface) a major. A tree that is not a
  release carries a pre-release suffix: this tree is `1.0.0-dev`. Releasing
  means setting `PLZIG_VERSION := 1.0.0`, committing, tagging `v1.0.0`, and
  setting the next `-dev` version right after. It is compiled into
  `plzig.so` as the module version (shown by `pg_get_loaded_modules()` on
  PostgreSQL 18+).
* **SQL extension version.** `default_version` in `plzig.control` is
  generated from `EXT_VERSION`, and the build fails if
  `sql/plzig--<EXT_VERSION>.sql` does not exist. Patch releases never change
  SQL objects, so they keep the extension version and need no script. A
  release that changes SQL objects is at least a minor release and ships
  `sql/plzig--<old>--<new>.sql` from the previous extension version (every
  file `sql/plzig--*.sql` is installed) plus the new full install script.
  `test/upgrade/check-upgrade-scripts.sh` checks, against an installed
  server, that every upgrade path PostgreSQL knows ends in exactly the
  objects of a fresh install (functions with signature, strictness,
  volatility, security, source and ACL; the language with handlers, trust
  and ACL; comments). Its `--selftest` installs two temporary scripts (a
  synthetic version `0.0selftest` and an upgrade from it) and checks that
  the correct upgrade passes and a divergent one -- an upgrade script that
  grants `EXECUTE` on `plzig_cache_clear()` to `PUBLIC` -- is reported. No
  upgrade script exists yet because no release exists; no fake release was
  invented to have one.
* **ABI version** is part of the module cache key and checked when a module
  is loaded; it is independent of the release version (doc/abi.md).
* **Zig pin**: one Zig per release; the server refuses any other compiler.
  It is in the control file's comment, `plzig_sandbox_status()`, the
  package dependency on `plzig-zig-toolchain` and the toolchain package's
  version.

Package versions are the source tarball's version with the semver
pre-release `-` turned into `~` (`1.0.0-dev.20261115.g78ba89028b51` →
`1.0.0~dev.20261115.g78ba89028b51`), which sorts before `1.0.0` in both RPM
and dpkg. The RPM `Release` / Debian revision is the second argument of
`build-packages.sh` (default 1). Semver build metadata (`+zig.0.17.1`,
PLAN.md §14) is not used.

## Source tarball

`make dist` packs the committed tree of `HEAD` (`git archive`, so
`.gitattributes` `export-ignore` applies: `.github/` and `bench/` -- the
benchmark image installs PL/Python and PL/Perl, which must never be
shipped; `make-dist.sh` refuses to pack a tree that still contains either
directory) and re-packs it deterministically: sorted names, owner and group
0, modes 0644/0755, every mtime set to the commit time, pax headers without
atime/ctime, `gzip -n -9`. The same commit gives the same bytes (verified:
the host and a Debian 13 container produce identical tarballs). Output:
`build/dist/plzig-<version>.tar.gz` and `.sha256`; the tarball records its
version in `.dist-version`.

* A release version (no `-`) requires `HEAD` to be tagged `v<version>`.
* A pre-release version gets `.<commit date, UTC>.g<12 hex of the commit>`
  appended.
* `make dist DIST_WORKTREE=1` packs the working tree (tracked plus
  untracked, not ignored files) instead, for testing uncommitted changes;
  if it differs from `HEAD` the version gets `.dirty.<8 hex digest of the
  files>`. Never for a release.

## Offline build

Distribution builders have no network. The build needs exactly three
inputs, each verified against a SHA-256 pinned in the `Makefile`:

```sh
make install-zig ZIG_PREFIX=/opt/zig-0.17.1 ZIG_TARBALL=/path/zig-x86_64-linux-0.17.1.tar.xz
make ZIG=/opt/zig-0.17.1/zig WAMR_TARBALL=/path/WAMR-2.4.5.tar.gz
make install ZIG=/opt/zig-0.17.1/zig WAMR_TARBALL=/path/WAMR-2.4.5.tar.gz
```

* `ZIG_TARBALL`: the official build from
  `https://ziglang.org/download/0.17.1/`.
* `WAMR_TARBALL`: the tag's source archive
  `https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-2.4.5.tar.gz`
  (SHA-256 `1ab09d51…`; its contents were checked to be identical to the
  pinned commit's tree, and the archive's embedded commit id is the pinned
  commit). `WAMR_SRC=<tree>` remains the alternative.

`packaging/test-offline-build.sh` runs exactly this in a container started
with `--network none` (Debian 13 builder image, PostgreSQL 18, `WERROR=1`,
then `make check-zig`) and first checks that the container really has no
network (only the loopback interface; name resolution fails; the image has
no git either). The package builds below also run with `--network none`.

## The Zig toolchain package

PL/Zig needs Zig 0.17.1 exactly, and its default Landlock sandbox needs a
**statically linked** compiler (a dynamically linked one could not start
under the file rules). Distribution `zig` packages are a different version
or link LLVM dynamically, and distribution policies generally do not allow
bundling a compiler inside another package. So, as PLAN.md §13 E planned,
the compiler is a package of its own:

* **Name** `plzig-zig-toolchain`, version = the Zig version (`0.17.1`),
  independent of PostgreSQL. The extension packages depend on it with the
  exact upstream version (`= 0.17.1` in RPM, `>= 0.17.1, << 0.17.2~` in
  Debian) and use it at build time (it builds `plzig-validate`).
* **Contents**: the official ziglang.org build, SHA-256 pinned, repackaged:
  the compiler binary unchanged (so its SHA-256 is upstream's and can be
  used for `plzig.zig_sha256`), plus a pruned `lib/`
  (`packaging/zig-toolchain/install-pruned.sh`): `std`, `compiler_rt`,
  `compiler`, `c` and the top-level files -- all MIT-licensed Zig code. Left
  out: `lib/libc`, `lib/include`, `lib/libcxx`, `lib/libcxxabi`,
  `lib/libunwind`, `lib/libtsan` (C/C++ library sources and headers under
  LGPL, GPL with the syscall note, APSL and more; this was the reason for
  Deviation 19), and `docs`, `build-web`, `init`, `lldb`. The pruned tree
  passes the validator/SDK unit tests (`make check-zig`, run by every RPM
  `%check` and Debian build) and the whole regression suite in every
  package test.
* **Path** `/usr/libexec/plzig-zig-toolchain/<zig version>/zig`, not on the
  `PATH`; it is the compiled-in default of `plzig.zig_path` in the
  extension packages (`make PLZIG_DEFAULT_ZIG_PATH=...`). A source build has
  no default, as before (`docker/security-checks.sh` checks that; the
  package test checks the package's value).
* **License**: `MIT AND Apache-2.0 WITH LLVM-exception AND NCSA AND Zlib AND
  BSD-3-Clause` -- Zig itself plus what the official static binary contains
  (LLVM/Clang/LLD with libc++/libunwind, zlib, zstd, musl), identified from
  the binary (`clang version 22.1.8`, zlib 1.3.1 strings, zstd symbols) and
  the zig-bootstrap component list. `NOTICE` and the license texts in
  `packaging/zig-toolchain/licenses/` (fetched from the projects' own
  repositories) are installed with the package, together with the
  `LICENSE` of the upstream tarball, in
  `/usr/share/licenses/plzig-zig-toolchain/` (RPM and Debian alike).
* **Sources**: RPM `Source0`/`Source1` are both architectures' upstream
  tarballs (checked in `%prep`); the Debian source has them as component
  tarballs `orig-amd64` and `orig-arm64`, plus a small main tarball with
  `NOTICE`, the licenses, the install script and the compiler binaries'
  checksums (checked in `debian/rules`).

Where a repository does not accept a repackaged upstream binary, the
alternative from PLAN.md §13 E stands: depend on a distribution `zig` of
exactly 0.17.x, statically linked, at a path set with
`PLZIG_DEFAULT_ZIG_PATH`. No such distribution package exists today.

## Building the packages

```sh
make dist                                   # or PLZIG_DIST_WORKTREE=1 below
packaging/build-packages.sh el9             # -> build/packages/el9/r1/
packaging/build-packages.sh debian13 2      # release/revision 2 -> build/packages/debian13/r2/
PLZIG_MAJORS=17 packaging/build-packages.sh el9    # one major only (CI)
```

`build-packages.sh` verifies the inputs (both architectures' Zig tarballs,
from `vendor/zig/` or downloaded into `build/dl/`; the WAMR tarball from
`vendor/` or `build/dl/`; the source tarball `$PLZIG_DIST` or a fresh
`make dist`), builds the builder image `plzig-pkgbuild:<distro>` (the
distribution with the PGDG repositories, signature-checked with the keys in
`packaging/keys/`, whose fingerprints are pinned in the setup scripts, and
the `-devel`/`-server-dev` packages of every major), then runs the build in
that image **with `--network none`**, using the packaging scripts from the
source tarball. The output directory holds the packages, source packages,
`build.log` and `rpmlint.txt` or `lintian.txt`.

### Targets

| `<distro>` | Image | PostgreSQL majors (PGDG) |
|---|---|---|
| `el8` | `almalinux:8` | 15 16 17 18 (PGDG has no 19 for EL 8) |
| `el9` | `almalinux:9` | 15–19 |
| `el10` | `almalinux:10` | 15–19 |
| `fedora45` | `fedora:45` | 15–19 |
| `debian12` | `debian:bookworm` | 15–19 |
| `debian13` | `debian:trixie` | 15–19 |
| `ubuntu22.04` | `ubuntu:22.04` | 15–19 |
| `ubuntu24.04` | `ubuntu:24.04` | 15–19 |
| `ubuntu26.04` | `ubuntu:26.04` | 15–19 |

PostgreSQL 19 is 19.0 (GA): PGDG publishes it in the yum tree and in the
apt component `19`. PostgreSQL 14 reached end of life and is dropped from
the packaged majors. Only x86_64 was built and tested; the specs and
`debian/control` also declare aarch64/arm64 (both Zig checksums are pinned),
untested.

### RPM (`packaging/rpm/`)

* `plzig.spec` (from `plzig.spec.in`, versions filled in by `gen-specs.sh`)
  builds `plzig_<major>` with `--define 'pgmajorversion <major>'`, PGDG's
  naming and layout (`/usr/pgsql-<major>/`). `License: PostgreSQL AND
  Apache-2.0 WITH LLVM-exception AND MIT` (plzig.so contains WAMR;
  plzig-validate contains Zig standard library code), `Provides:
  bundled(wamr) = 2.4.5`, `Requires: postgresql<major>-server,
  plzig-zig-toolchain = 0.17.1`, license files as `%license`. The
  generated `debuginfo` and `debugsource` subpackages get their own copies
  (a hook after `find-debuginfo`): they do not depend on the main package
  and hold WAMR's debugging data and sources. `%check` runs the validator
  and SDK unit tests and `make check-licenses`.
* Hardening: PGXS compiles with PostgreSQL's own `CFLAGS` (PGDG builds with
  the distribution's flags); the spec adds `%set_build_flags` as `COPT` and
  `PG_LDFLAGS`, and WAMR's cmake gets the flags from the environment. The
  installed-package test checks RELRO, `BIND_NOW`, a non-executable stack,
  the stack protector and `_FORTIFY_SOURCE` in the installed `plzig.so`, and
  that `plzig-validate` is a static PIE. PGXS's `RUNPATH` to PostgreSQL's
  lib directory is dropped (`rpath=`): `plzig.so` links nothing from there,
  and Fedora's `check-rpaths` rejects it.
* `plzig-zig-toolchain.spec`: no stripping, debuginfo, build-id links or
  other `brp` post-processing, so the files stay byte for byte upstream's.
* Fedora and EL 10's AppStream ship PostgreSQL packages under PGDG's names
  (`postgresql19-server`, ...) with another layout; `setup-pgdg.sh` adds
  `excludepkgs=postgresql*` to the distribution's repositories (PGDG's own
  advice; with dnf5 through `/etc/dnf/repos.override.d`) so that only PGDG
  provides them, and disables the `postgresql`
  module on EL 8/9. Installations next to PGDG need the same.
* Each SRPM carries the spec rendered for its major (`plzig_<major>.spec`),
  so `rpmbuild --rebuild` needs no `--define`.
* rpm 6 (Fedora 45) refuses unsigned packages by default; the builder
  installs its own fresh toolchain package with `--nosignature`; the test
  first installs PGDG's server signature-checked, then only the local
  unsigned test builds with `--nogpgcheck`. Released packages are signed by
  the repository that publishes them.
* `rpmlint` runs in the builder: 2.9 on Fedora 45 with the justified
  filters in `plzig.rpmlintrc` (result: 0 errors; the only warnings are
  `no-url-tag`), 1.10/1.11 unfiltered on EL 8/EL 9 (their findings are the
  same ones the filters explain, plus 1.x's outdated SPDX list and
  `/usr/pgsql-N` as a non-standard directory); EL 10 has no rpmlint
  package.

### Debian (`debian/`, `packaging/deb/`)

* One source package `plzig` builds `postgresql-<major>-plzig` for every
  major in `debian/pgversions` with a `postgresql-server-dev` package
  installed (`pg_buildext`, `dh --with pgxs_loop`: in-tree, one major after
  the other, because the Makefile builds WAMR and the validator below
  `build/`). `debian/control` is generated from `debian/control.in` by
  `pg_buildext updatecontrol`.
* Source format 3.0 (quilt): the main orig tarball is the `make dist`
  tarball, the component `orig-wamr` the WAMR tag tarball (unpacked as
  `wamr/`, used as `WAMR_SRC`). The Zig compiler comes from the
  `plzig-zig-toolchain` build dependency.
* Hardening: `DEB_BUILD_MAINT_OPTIONS = hardening=+all`; `pg_buildext`
  passes `CFLAGS` as `COPT`, `debian/rules` passes `LDFLAGS` as
  `PG_LDFLAGS`.
* The build runs the validator and SDK unit tests; the regression suite
  needs a server with Landlock ABI ≥ 6 and is run by the package test
  instead (`override_dh_pgxs_test`).
* `debian/copyright` is DEP-5; it reproduces `LICENSE`, which names the
  copyright holder. `LICENSE`, `THIRD-PARTY-NOTICES` and the two texts of
  `LICENSES/` are also installed in
  `/usr/share/licenses/postgresql-<major>-plzig/`, outside `/usr/share/doc`
  (see *License material*).
* `lintian --pedantic --info` runs in the builder; overrides are in
  `debian/source/lintian-overrides`,
  `debian/postgresql-plzig.lintian-overrides.in` (copied per major) and
  `packaging/zig-toolchain/debian/`, each with its justification.

### Lint results (2026-11-15, x86_64)

* **lintian** (pedantic, info; trixie 2.122, bookworm 2.116, jammy 2.114,
  noble 2.117, resolute 2.129). Errors left: `bogus-mail-host` (the
  placeholder maintainer address) everywhere; on the older lintian versions
  of Debian 12, Ubuntu 22.04 and 24.04 also `source-is-missing` for the
  toolchain source's prebuilt `zig` and upstream's generated HTML (newer
  lintian reports these as pedantic `source-contains-prebuilt-binary`), and
  `newer-standards-version`. Ubuntu 22.04's lintian does not understand the
  bracketed override syntax, so it shows the overridden tags (and
  `mismatched-override`). Warnings left: `initial-upload-closes-no-bugs`,
  `package-has-long-file-name` (the snapshot version string). Logs:
  `build/packages/<distro>/r1/lintian.txt`.
* **rpmlint**: see the RPM section; logs `build/packages/<distro>/r1/rpmlint.txt`.

## Package tests

```sh
packaging/test-packages.sh el9 17           # one cell
packaging/test-matrix.sh                    # everything (builds r0 and r1 per distro)
packaging/test-matrix.sh debian13 el10      # some distributions
```

Each cell starts a **fresh** container of the distribution and installs
only the built packages plus PGDG's PostgreSQL of that major and test
tooling (`pg_regress`: `postgresql<major>-test` on EL/Fedora,
`postgresql-client-<major>` on Debian/Ubuntu; binutils; util-linux and
diffutils on EL/Fedora, whose minimal images lack `su` and `diff`). The source
tarball is mounted only for its tests. Steps (`STEP` lines in
`build/package-tests/<distro>-<major>.log`):

| Step | Checks |
|---|---|
| `deps` | no built package (binary or source) depends on, recommends, suggests, supplements or enhances PL/Python or PL/Perl; `plzig`'s runtime dependencies are PostgreSQL and the toolchain package (plus libc) |
| `install` | the packages install from local files with PGDG as the only other repository; afterwards nothing of PL/Python or PL/Perl is installed |
| `upgrade` | with the release-0 build installed, a function is created and called; after upgrading to release 1 and restarting the server it still runs and a new function compiles |
| `files` | the compiled-in `plzig.zig_path` is the toolchain's compiler, which exists, is root-owned, mode 0755, and reports the pinned version; hardening of `plzig.so` (above); no exported test helpers |
| `licenses` | `packaging/pkgtest-licenses.sh`: every binary, debug and source package of this major and of the toolchain carries the license files and notices of the source tarball, byte-identical, also as installed (see *License material*) |
| `sandbox` | `CREATE EXTENSION plzig`, a compilation, `plzig_sandbox_status()` = `enforced` |
| `regress` | the full pg_regress suite of the source tarball against the installed package |
| `sqlupgrade` | `test/upgrade/check-upgrade-scripts.sh --selftest` |
| `remove` | the toolchain cannot be removed while `plzig` is installed; removing both leaves no file behind and keeps PostgreSQL installed and running; calling a PL/Zig function then fails cleanly (`could not access file "$libdir/plzig"` on EL/Fedora, `could not load library "plzig"` on Debian/Ubuntu); `DROP EXTENSION plzig CASCADE` still works; `$PGDATA/plzig` is kept |

The upgrade test upgrades between two builds of the same source (release 0
→ 1), because no earlier release exists: it covers the package manager's
upgrade path (file replacement, dependency on the same toolchain, the
server picking up the new library after a restart, cached modules), not
changes between PL/Zig versions.

**Result (2026-11-15, x86_64):** all 53 cells -- EL 8 × 14–18, EL 9, EL 10,
Fedora 45, Debian 12, Debian 13, Ubuntu 22.04, 24.04, 26.04 × 14–19 --
built (releases 0 and 1, offline) and passed every step, including the
26-test regression suite against the installed package. aarch64 was not
built or run.

**Kernel.** The containers share this machine's kernel (Linux 7.2, Landlock
ABI 10), so the default `plzig.compiler_sandbox = require` is satisfied in
every cell, whatever kernel the distribution would ship with. The tests say
nothing about the distributions' own kernels; see the next section.

## The sandbox on older kernels

The default `plzig.compiler_sandbox = require` needs Landlock ABI 6 or later
(Linux 6.12 or newer, with Landlock enabled) and seccomp. On an older
kernel `CREATE FUNCTION ... LANGUAGE plzig` (and every other compilation)
fails with an error naming what is missing, until the administrator
explicitly lowers the setting in `postgresql.conf` (`try`: use what is
available and log what is missing; `off`: no confinement) -- which lets the
compiler run with the rights of the server's OS user, minus whatever the
kernel still enforces. **No package changes the default.** Cached modules
keep running either way. Check a server with `SELECT
plzig_sandbox_status();` after a compilation.

Landlock ABI by kernel: 5.13 → 1, 5.19 → 2, 6.2 → 3, 6.7 → 4, 6.10 → 5,
6.12 → 6. Stock kernels of the targets (as documented by the
distributions; not tested here, the containers ran on Linux 7.2):

| Distribution | Stock kernel | `require` works? |
|---|---|---|
| EL 8 | 4.18 | no (no Landlock) |
| EL 9 | 5.14 | no on the original kernel; later minor releases may carry a Landlock backport (seen in the CentOS Stream 9 kernel tree, not tested on a system) |
| EL 10 | 6.12 | yes: tested on AlmaLinux 10.2 (kernel 6.12.0-211, ABI 6), see the next section |
| Fedora 45 | current mainline | yes |
| Debian 12 | 6.1 | no (backports kernels ≥ 6.12: yes) |
| Debian 13 | 6.12 | yes: tested on Debian 13.7 (kernel 6.12.107, ABI 6), see the next section |
| Ubuntu 22.04 | 5.15 (HWE 6.8) | no |
| Ubuntu 24.04 | 6.8 (HWE 6.11 no; HWE 6.14 and later yes) | GA kernel: no |
| Ubuntu 26.04 | ≥ 6.12 | yes |

The package descriptions say the same.

## SELinux and AppArmor

The package tests run in containers, where the host's security module does
not confine the server the way it does on an installed system. Two virtual
machines were therefore tested by hand (2026-11-18, x86_64, packages built
from the tree, `plzig.compiler_sandbox = require`): a function was created
(which runs the validator and the compiler in the sandbox) and called, and
the audit or kernel log was read. On the AlmaLinux system the regression
suite of the source tree (26 tests) was also run against the installed
package through the system's server, with a `trust` line added to
`pg_hba.conf` for the run: all tests passed with the server in
`postgresql_t`. That system is in FIPS mode, where PostgreSQL's `md5()`
fails; the tests therefore make their test data with SHA-256. The other
steps of the package test were not run there, and on Debian it was one
function only.

| System | Server confined as | Result |
|---|---|---|
| AlmaLinux 10.2, SELinux enforcing, PGDG PostgreSQL 18 as installed | `unconfined_service_t` (PGDG's server binary is labelled `bin_t`) | works; status `enforced (landlock ABI 6, seccomp; ...)` |
| the same, server binary relabelled `postgresql_exec_t` | `postgresql_t` | works since deviation 59 of PLAN.md; before it every compilation failed with "setrlimit failed" |
| Debian 13.7, AppArmor enabled, PGDG PostgreSQL 18 | unconfined (the PostgreSQL packages ship no AppArmor profile) | works; no AppArmor message in the kernel log |

* **SELinux, `postgresql_t`.** The policy does not let this domain change a
  hard resource limit, so the compiler gets soft limits only, which the
  seccomp filter keeps it from raising (doc/security.md). Each compilation
  leaves denials in the audit log: `setrlimit` (the refused hard limits) and
  `map` on files of the build and cache directories (the compiler falls
  back to reading them). They are expected and need no policy change.
* **AppArmor.** Nothing confines the server by default. A site that writes
  its own profile for PostgreSQL has to allow it to execute
  `/usr/libexec/plzig-zig-toolchain/<version>/zig` and
  `plzig-validate` (in the server's library directory, under `plzig/`) and
  to read the toolchain's `lib` directory; this was not tried.
* **Not tested:** the distributions' own PostgreSQL packages, other
  SELinux policies (MLS, a site's modules), Ubuntu, aarch64, and anything
  but the default configuration of each system.

## Removal and the cache directory

Removing the packages removes every installed file, nothing else.
`$PGDATA/plzig/` -- the module cache, the Zig cache and the compile lock --
belongs to the cluster, not to the package, and is kept (it is
re-created on demand; tens of megabytes after the regression suite). With
the extension still created in a database, a PL/Zig function then fails
with an error (`could not access file "$libdir/plzig"`, or `could not load library` on Debian/Ubuntu); `DROP EXTENSION plzig
CASCADE` works without the library. After `DROP EXTENSION` in every
database (or before reinstalling a different PL/Zig major), the
administrator may delete `$PGDATA/plzig/` with the server stopped or with
no PL/Zig compilation running; nothing else refers to it. `DROP EXTENSION`
itself does not delete it.

## Evaluation image

```sh
packaging/build-packages.sh debian12
packaging/image/build-image.sh 18           # plzig/postgres:18, then its test
```

`plzig/postgres:<major>` is the official image `postgres:<version>-bookworm`
plus `postgresql-<major>-plzig` and `plzig-zig-toolchain` from the Debian 12
build: PostgreSQL, PL/Zig, the toolchain -- no other procedural language.
`packaging/image/test-image.sh` starts it through the official entrypoint,
creates the extension and a function with the packaged defaults, checks
`plzig_sandbox_status()` and that `plzig.compiler_sandbox` is still
`require`, and checks that no PL/Python, PL/Perl, PL/Tcl (or other PL)
package, library or extension file is present and that the only languages
are PL/pgSQL and PL/Zig. It also copies the two packages' license
directories and `copyright` files out of the image and compares them with
this tree (*License material*). The image is built locally only and never pushed;
on a host kernel older than 6.12 compilations in it are refused (see
above).

## License material

What must travel with each artifact, and what checks it. The checker is
`packaging/check-licenses.sh`; every comparison is byte for byte against the
source tree (or the unpacked source tarball).

| Artifact | License material it carries | Checked by |
|---|---|---|
| Source tree, `make dist` tarball | `LICENSE`, `THIRD-PARTY-NOTICES`, `LICENSES/` (WAMR's and Zig's license texts), `third_party/wamr-interrupt.patch` (adds the modification notice), `debian/copyright`, `packaging/zig-toolchain/` (`NOTICE`, four license texts, `debian/copyright`) | `packaging/test-licenses.sh` (CI job `licenses`) |
| `make install` | the four PL/Zig files in `<docdir>/extension/plzig/` | `make installcheck-licenses` (test layer `licenses`) |
| `plzig_<major>` RPM, `postgresql-<major>-plzig` deb | the four files in `/usr/share/licenses/<package>/`; deb: also `/usr/share/doc/<package>/copyright` | package test step `licenses` |
| `plzig-zig-toolchain` (RPM, deb) | `NOTICE`, Zig's `LICENSE`, LLVM, musl, zlib and zstd texts in `/usr/share/licenses/plzig-zig-toolchain/`; deb: also `copyright` | package test step `licenses` |
| RPM `debuginfo`, `debugsource` | their own copies of the four files; the patched WAMR file with its modification notice | package test step `licenses` |
| Debian `dbgsym` | none of its own: depends on exactly the main package's version and links its doc directory | package test step `licenses` |
| Source packages (`.src.rpm`; `.orig*.tar.*`, `.debian.tar.xz`) | the source tarball unchanged, the pinned upstream tarballs, the Debian copyright files | package test step `licenses` |
| Evaluation image | both packages' `/usr/share/licenses/<package>/` and `copyright` files; the `org.opencontainers.image.licenses` label | `packaging/image/test-image.sh` |

What the checks establish:

* **The texts are the upstream ones.** `packaging/license-files.sha256` pins
  the six third-party texts. `LICENSES/Apache-2.0-WITH-LLVM-exception.txt`
  and `LICENSES/MIT-Zig.txt` are compared with the `LICENSE` files inside
  the pinned WAMR and Zig tarballs. The four texts of the components linked
  into the official Zig binary are pinned but not compared with an upstream
  download.
* **The attribution list is complete for what is compiled in.** `make
  check-licenses` (run by the test image, by `%check` and by the Debian
  build) takes the list of WAMR files the compiler read from the build's
  dependency files (74 or 75, depending on the platform) and requires their
  copyright lines to be exactly the ones in `THIRD-PARTY-NOTICES`, in both
  directions; a file without a copyright line must be named there. This
  check found the list written by hand to be wrong (two lines missing, two
  that matched no compiled-in file); it is now generated from that output.
  `debian/copyright` must name the same holders.
* **The notices are current.** They must name the pinned WAMR version and
  commit and the pinned Zig version, and contain the statement of changes;
  the patch must add the modification notice to the one file it changes;
  the license expressions of the two specs, the SBOM generator, `NOTICE`
  and the image label must agree.
* **Nothing is lost on the way.** Each package is unpacked and its files
  compared; the RPM files must be marked `%license`; the installed copies
  are compared again.
* **The checker notices failures**: `check-licenses.sh selftest` removes,
  changes and truncates files and adds an unlisted copyright line, and
  requires each to be reported.

Why `/usr/share/licenses` on Debian too: the official `postgres` images
(and other slim images) configure dpkg to drop everything below
`/usr/share/doc` except `copyright` files. The first version of the
packages kept `NOTICE` and the component license texts there, and the
evaluation image therefore lacked them; the image test now covers this.

Limits: the checks compare files and copyright *lines*; they do not judge
whether the license analysis itself is right (which components the official
Zig binary contains was established by hand, see *The Zig toolchain
package*), they do not cover the Zig standard library's own per-file
notices beyond Zig's `LICENSE`, and the release directory of
`make-release.sh` is covered only through the packages it copies. This is
not legal advice.

## Release artefacts

```sh
packaging/release/make-release.sh build/release/<version>
# = copy the source tarball and build/packages/*/r1/*.{rpm,deb} (no debug packages),
#   python3 -I packaging/release/sbom.py <dir> <unpacked source>   -> plzig-<version>.spdx.json
#   packaging/release/checksums.sh <dir>                           -> SHA256SUMS
#   packaging/release/sign.sh <dir>     (PLZIG_SIGNING_KEY)         -> SHA256SUMS.asc
```

* `checksums.sh` writes `SHA256SUMS` over every file (verify with `sha256sum
  -c SHA256SUMS`).
* `sbom.py` writes an SPDX 2.3 JSON document: the source tarball, every
  package file with its checksum and license, WAMR (version, commit,
  tarball checksum, statically linked into every `plzig` binary package)
  and both official Zig builds (pinned checksums; the build tool of the
  binary packages and the origin of the toolchain packages). Deterministic
  (creation time from the source, namespace from the source tarball's
  checksum). It was checked for well-formed JSON and internal consistency
  (every relationship names a package of the document), not with the SPDX
  project's validators.
* `sign.sh` signs `SHA256SUMS` with the OpenPGP key named by
  `PLZIG_SIGNING_KEY`, from the caller's keyring; without the variable it
  prints `signing skipped` and exits 0; a named but missing key is an
  error. It never creates or imports keys. Nothing has been signed.

## CI

* `ci.yml`, job `packages` (every push and pull request): an EL 9 RPM
  (PostgreSQL 17) and a Debian 13 package (PostgreSQL 18), each built
  offline and put through the installed-package test.
* `ci.yml`, job `licenses`: `packaging/test-licenses.sh` (source tree and
  source tarball against the pinned upstream tarballs, and the checker's
  self-test). The test jobs run the layer `licenses`, the package jobs the
  step `licenses` (*License material*).
* `packaging.yml` (manual `workflow_dispatch`): the full matrix, one job per
  distribution, packages and logs as workflow artifacts.

Both on GitHub-hosted runners only. The runners' kernel decides whether the
`require` sandbox is available (as for the existing test jobs); the tests do
not lower it. The workflows pass actionlint 1.7.12 (with shellcheck); they
have not been run on GitHub.

## Open questions

For the owner:

* **Maintainer identity**: every package says `PL/Zig maintainers
  <plzig@invalid>` (lintian reports `bogus-mail-host`); the real name and
  address go into `debian/control.in`, `packaging/zig-toolchain/debian/`,
  the changelogs and the spec changelogs.
* **URL**: no `URL:`/`Homepage:` and no `debian/watch` until the public
  repository exists (rpmlint `no-url-tag`).
* **Signing key** for `SHA256SUMS` (and whoever signs packages in our own
  repositories, if any).
* **Names**: `plzig_<major>` (PGDG convention), `postgresql-<major>-plzig`
  (Debian/PGDG convention), `plzig-zig-toolchain`, image
  `plzig/postgres:<major>` (the `plzig` namespace on a registry is not
  ours yet).
* **Copyright holder in `debian/copyright`**: copied from `LICENSE`.

For repository maintainers (PLAN.md §13 "Open risks for E/F"):

* **Repackaged Zig binary.** `plzig-zig-toolchain` is a repackaged upstream
  binary (static, with embedded LLVM, zlib, zstd, musl). PGDG, Pigsty and
  Debian may refuse that. Alternatives: a source-built Zig toolchain
  package (Zig builds from source with LLVM, but must stay statically
  linked for the sandbox), or a distribution `zig` 0.17.x.
* **Upstream tarball with non-free headers.** The toolchain's source
  package contains upstream's complete tarballs, whose `lib/libc` (not
  installed) includes headers lintian flags (`license-problem-non-free-RFC`).
  Debian main would need a repacked tarball (`+dfsg`).
* **Patched embedded WAMR.** `plzig` statically links WAMR 2.4.5 with
  PL/Zig's interrupt patch (`Provides: bundled(wamr)`). Debian policy
  prefers a separate WAMR package; upstreaming the patch (PLAN.md §13 F)
  would remove the patch objection.
* **Prebuilt test data**: the fuzz corpora in the source tarball are
  `.wasm` files (lintian `source-contains-prebuilt-wasm-binary`, overridden).
* **Kernel requirement**: the default sandbox refuses to compile on the
  stock kernels of several targets (above); whether repositories want a
  different default for those is a policy decision PL/Zig leaves to the
  administrator, not to packages.
