# PL/Zig -- PGXS build.
#
#   make ZIG=/abs/path/to/zig [WAMR_SRC=/path/wamr]
#   make install
#   make installcheck
#
# Zig 0.17.1 is an external, mandatory dependency.  It is needed at build
# time (ZIG=, to build the source validator; its version must match exactly)
# and at run time (plzig.zig_path in postgresql.conf).  The extension does
# not ship or install it, and plain `make` / `make install` never download it.
#
# Optional helper to obtain the pinned official build (downloads, or takes
# ZIG_TARBALL=, verifies the pinned SHA-256, unpacks to a prefix you choose):
#
#   make install-zig ZIG_PREFIX=/opt/zig-0.17.1 [ZIG_TARBALL=/path/zig-<arch>-linux-0.17.1.tar.xz]
#   make fetch-zig [ZIG_TARBALL=...]          (download + verify only)
#
# WAMR is fetched at build time (git, pinned commit) unless WAMR_SRC (a source
# tree) or WAMR_TARBALL (the tag's source tarball, pinned SHA-256) is given;
# the database server never downloads anything.  Fully offline build:
#
#   make ZIG=/opt/zig-0.17.1/zig WAMR_TARBALL=/path/WAMR-2.4.5.tar.gz
#
# Packaging (doc/packaging.md):
#   make dist                                 reproducible source tarball (build/dist/)
#   make PLZIG_DEFAULT_ZIG_PATH=/abs/zig ...  compiled-in default of plzig.zig_path
#   sh packaging/versions.sh                  the versions, for scripts
#
# Host/guest ABI (abi/plzig-abi.table, see below):
#   make abi                                  regenerate src/plzig_abi.h and zig/sdk/plzig.zig's regions
#   make check-abi                            fail if they are stale (also part of every build)

EXTENSION = plzig
MODULE_big = plzig
OBJS = src/plzig.o src/plzig_source.o src/plzig_build.o src/plzig_spawn.o \
       src/plzig_sandbox.o src/plzig_runtime.o src/plzig_host.o src/plzig_types.o \
       src/plzig_row.o src/plzig_use.o
# every install and upgrade script (plzig--<v>.sql, plzig--<from>--<to>.sql)
DATA = $(wildcard sql/plzig--*.sql)
PGFILEDESC = "PL/Zig - procedural language"

REGRESS = setup basics types types_more types_fixed types_numeric types_calendar types_jsonb rows srf triggers xact signatures usage encoding errors spi spi_prepared spi_cursor uses \
          sandbox sdk_builtins adversarial resources leaks check_all lifecycle
REGRESS_OPTS = --inputdir=test --load-extension=plzig
# only against a PLZIG_TESTING=1 build: make installcheck-testing
REGRESS_TESTING = testing

PG_CONFIG ?= pg_config

# ---- versions (PLAN.md section 14, doc/packaging.md "Versions") -----------
# PL/Zig's own semantic version, the single source of the release version
# (plzig.so's module magic, make dist, the packages).  A pre-release suffix
# ("-dev") marks a tree that is not a release; make dist then names its
# tarball <version>.<commit date>.g<commit>.
PLZIG_VERSION := 1.0.0-dev
# The SQL-level extension version (default_version in plzig.control, the
# install script sql/plzig--<EXT_VERSION>.sql) is MAJOR.MINOR: patch
# releases never change the SQL objects, so they need no upgrade script.
plzig_semver := $(subst ., ,$(firstword $(subst -, ,$(subst +, ,$(PLZIG_VERSION)))))
EXT_VERSION := $(word 1,$(plzig_semver)).$(word 2,$(plzig_semver))

# Compiled-in default of plzig.zig_path (empty: no default, the administrator
# sets it).  For packages whose Zig toolchain package installs the compiler at
# a fixed place: an absolute path of [A-Za-z0-9._+/-] characters.
PLZIG_DEFAULT_ZIG_PATH ?=

# ---- pinned third-party inputs -------------------------------------------
# The Zig pin.  This line is its single source: plzig.so (PLZIG_ZIG_VERSION),
# the control file's comment (plzig.control from plzig.control.in), build.zig
# and the test/CI scripts (third_party/zig-version.sh) all derive it from here.
ZIG_VERSION := 0.17.1
ZIG_ARCH := $(shell uname -m)
ZIG_SHA256_x86_64 := 3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ZIG_SHA256_aarch64 := a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ZIG_SHA256 := $(ZIG_SHA256_$(ZIG_ARCH))
ZIG_DIRNAME := zig-$(ZIG_ARCH)-linux-$(ZIG_VERSION)
ZIG_URL := https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_DIRNAME).tar.xz
ZIG_TARBALL ?=
ZIG_PREFIX ?=
WAMR_SRC ?=
# offline alternative to WAMR_SRC: the tag's source tarball from GitHub
# (https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-2.4.5.tar.gz),
# verified against this SHA-256 (its contents are the pinned commit's tree)
WAMR_TARBALL ?=
WAMR_TARBALL_SHA256 := 1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b

# the Zig compiler used to build the validator (absolute path, exactly ZIG_VERSION)
ZIG ?=

BUILD_DIR := $(CURDIR)/build
ZIG_DL := $(BUILD_DIR)/dl/$(ZIG_DIRNAME).tar.xz
WAMR_BUILD_SRC := $(BUILD_DIR)/wamr-src
WAMR_LIB := $(BUILD_DIR)/wamr/libiwasm.a
VALIDATOR := $(BUILD_DIR)/plzig-validate

# The backend refuses any compiler whose `zig version` differs from the one
# the validator was built with (the validator uses that version's tokenizer).
PG_CPPFLAGS = -I$(WAMR_BUILD_SRC)/core/iwasm/include -DPLZIG_ZIG_VERSION='"$(ZIG_VERSION)"' \
    -DPLZIG_VERSION_STR='"$(PLZIG_VERSION)"'
ifneq ($(PLZIG_DEFAULT_ZIG_PATH),)
ifneq ($(shell printf '%s\n' '$(PLZIG_DEFAULT_ZIG_PATH)' | grep -cxE '/[A-Za-z0-9._+/-]+'),1)
$(error PLZIG_DEFAULT_ZIG_PATH must be an absolute path of [A-Za-z0-9._+/-] characters)
endif
PG_CPPFLAGS += -DPLZIG_DEFAULT_ZIG_PATH='"$(PLZIG_DEFAULT_ZIG_PATH)"'
endif
PG_CFLAGS = -Wall -Wmissing-prototypes -Wdeclaration-after-statement
ifeq ($(WERROR),1)
PG_CFLAGS += -Werror
endif
# Test build only (`make PLZIG_TESTING=1`): adds the SQL-callable unit-test
# helpers (plzig_test_*) used by test/sql/testing.sql.  Never for a release:
# docker/security-checks.sh fails if an installed plzig.so exports them.
ifeq ($(PLZIG_TESTING),1)
PG_CPPFLAGS += -DPLZIG_TESTING
endif
SHLIB_LINK = $(WAMR_LIB) -lm -Wl,--exclude-libs,ALL -Wl,-z,noexecstack

# no LLVM bitcode for JIT inlining: nothing to gain, and keeps the build simple
override with_llvm = no

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ---- third-party build steps ---------------------------------------------
$(WAMR_BUILD_SRC)/.stamp: third_party/prepare-wamr.sh third_party/wamr-interrupt.patch
	sh third_party/prepare-wamr.sh "$(WAMR_SRC)" "$(WAMR_BUILD_SRC)" \
	    "$(CURDIR)/third_party/wamr-interrupt.patch" "$(WAMR_TARBALL)" "$(WAMR_TARBALL_SHA256)"
	touch $@

$(WAMR_LIB): $(WAMR_BUILD_SRC)/.stamp third_party/wamr/CMakeLists.txt
	cmake -S third_party/wamr -B $(BUILD_DIR)/wamr \
	    -DWAMR_ROOT_DIR=$(WAMR_BUILD_SRC) -DCMAKE_BUILD_TYPE=Release \
	    -DCMAKE_C_COMPILER="$(CC)" >/dev/null
	+cmake --build $(BUILD_DIR)/wamr

# static PIE (full RELRO, ASLR for the code too); it needs no program
# interpreter, so it starts under Landlock like a plain static binary
$(VALIDATOR): zig/validate/main.zig third_party/check-zig.sh
	sh third_party/check-zig.sh "$(ZIG)" "$(ZIG_VERSION)"
	"$(ZIG)" build-exe -O ReleaseSafe -fstrip -mcpu baseline -fPIE \
	    --global-cache-dir $(BUILD_DIR)/zig-cache-host \
	    --cache-dir $(BUILD_DIR)/zig-cache-local \
	    zig/validate/main.zig --name plzig-validate -femit-bin=$@

$(OBJS): $(WAMR_LIB) src/plzig.h src/plzig_abi.h
$(shlib): $(WAMR_LIB)

# The control file, with the pinned Zig version in its comment (which becomes
# the extension's comment); PGXS installs it (installcontrol depends on it).
# default_version is EXT_VERSION, whose install script must exist.
plzig.control: plzig.control.in Makefile
	@test -f sql/plzig--$(EXT_VERSION).sql || { echo "sql/plzig--$(EXT_VERSION).sql (EXT_VERSION of PLZIG_VERSION $(PLZIG_VERSION)) does not exist" >&2; exit 1; }
	sed -e 's/@ZIG_VERSION@/$(ZIG_VERSION)/g' -e 's/@EXT_VERSION@/$(EXT_VERSION)/g' plzig.control.in > $@.tmp
	mv $@.tmp $@

all: $(VALIDATOR) plzig.control $(BUILD_DIR)/abi-check.stamp

# ---- host/guest ABI: one table, generated C and Zig (doc/abi.md) ----------
# abi/plzig-abi.table is the single source of the ABI definitions shared by
# host and guest; src/plzig_abi.h and the marked regions of zig/sdk/plzig.zig
# are generated from it and committed (so the build, `make dist`, the
# packages and the fuzz build need no generator step).  `make abi`
# regenerates them; `make check-abi` (and every build, through the stamp)
# fails if they are not what the table generates, or if doc/abi.md lacks a
# row for an import or export, or has one for a name the table does not
# have.  POSIX sh and awk only.
ABI_GEN := abi/plzig-abi.table abi/gen-abi.awk abi/gen-abi.sh
abi:
	sh abi/gen-abi.sh update .

check-abi:
	sh abi/gen-abi.sh check .

$(BUILD_DIR)/abi-check.stamp: $(ABI_GEN) src/plzig_abi.h zig/sdk/plzig.zig doc/abi.md
	sh abi/gen-abi.sh check .
	@mkdir -p $(BUILD_DIR)
	touch $@

# ---- isolation tests (test/isolation) -------------------------------
PLZIG_ISOLATION = concurrent_create replace_during_call cache_clear
installcheck-isolation:
	$(pg_isolation_regress_installcheck) --inputdir=test/isolation \
	    --outputdir=output_iso --load-extension=plzig $(PLZIG_ISOLATION)

# ---- C unit tests: pg_regress against a PLZIG_TESTING=1 build ----------
installcheck-testing:
	$(pg_regress_installcheck) $(REGRESS_OPTS) $(REGRESS_TESTING)

# ---- unit tests of the validator and the guest SDK (native `zig test`) ----
# Nothing here is built by `make` or installed by `make install`.
ZIG_TEST_CACHE = --global-cache-dir $(BUILD_DIR)/zig-cache-host --cache-dir $(BUILD_DIR)/zig-cache-test
check-zig:
	sh third_party/check-zig.sh "$(ZIG)" "$(ZIG_VERSION)"
	"$(ZIG)" test $(ZIG_TEST_CACHE) zig/validate/test.zig
	"$(ZIG)" test $(ZIG_TEST_CACHE) \
	    --dep plzig --dep sdk_root --dep plzig_test_env --dep user -Mroot=zig/sdk/test.zig \
	    --dep plzig_test_env -Mplzig=zig/sdk/plzig.zig \
	    --dep plzig -Mplzig_test_env=zig/sdk/test_env.zig \
	    --dep plzig --dep user -Msdk_root=zig/sdk/root.zig \
	    --dep plzig -Muser=zig/sdk/test_user.zig
# private SDK internals: the SDK's own `test` blocks, with it as the root
	"$(ZIG)" test $(ZIG_TEST_CACHE) \
	    --dep plzig_test_env -Mroot=zig/sdk/plzig.zig \
	    --dep plzig=root -Mplzig_test_env=zig/sdk/test_env.zig

# ---- optional: obtain the pinned Zig (never part of build or install) ----
fetch-zig:
	sh third_party/fetch-zig.sh "$(ZIG_TARBALL)" "$(ZIG_URL)" "$(ZIG_SHA256)" \
	    "$(ZIG_DL)" "" "$(ZIG_DIRNAME)"

install-zig:
	@test -n "$(ZIG_PREFIX)" || { echo "usage: make install-zig ZIG_PREFIX=/opt/zig-$(ZIG_VERSION) [ZIG_TARBALL=...]" >&2; exit 1; }
	sh third_party/fetch-zig.sh "$(ZIG_TARBALL)" "$(ZIG_URL)" "$(ZIG_SHA256)" \
	    "$(ZIG_DL)" "$(ZIG_PREFIX)" "$(ZIG_DIRNAME)"

# ---- source distribution (doc/packaging.md) ------------------------------
# Reproducible tarball of the committed tree (git archive of HEAD, honouring
# .gitattributes export-ignore, re-packed with fixed order, owners, modes and
# mtime).  DIST_WORKTREE=1 takes the working tree instead (tracked and
# untracked files that are not ignored) and appends ".dirty.<digest>" to the version
# if it differs from HEAD.  Output: build/dist/plzig-<version>.tar.gz, .sha256.
# The versions for scripts: packaging/versions.sh.
DIST_DIR ?= $(BUILD_DIR)/dist
dist:
	sh packaging/make-dist.sh "$(DIST_DIR)" "$(if $(filter 1,$(DIST_WORKTREE)),worktree,head)"

# ---- license material (doc/packaging.md "License material") --------------
# check-licenses: the source tree's license files, and the copyright lines
# of every WAMR file this build's compiler read against THIRD-PARTY-NOTICES.
# installcheck-licenses: what `make install` put into the documentation
# directory is the source's.
check-licenses: $(WAMR_LIB)
	bash packaging/check-licenses.sh source .
	bash packaging/check-licenses.sh wamr-build '$(BUILD_DIR)/wamr' '$(WAMR_BUILD_SRC)' .

installcheck-licenses:
	bash packaging/check-licenses.sh plzig '$(DESTDIR)$(docdir)/$(docmoduledir)/plzig' .

# ---- install: validator, SDK (no compiler) -------------------------------
install: install-plzig

install-plzig: $(VALIDATOR)
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)/plzig'
	$(INSTALL_PROGRAM) $(VALIDATOR) '$(DESTDIR)$(pkglibdir)/plzig/plzig-validate'
	$(MKDIR_P) '$(DESTDIR)$(datadir)/plzig/sdk'
	$(INSTALL_DATA) zig/sdk/plzig.zig zig/sdk/root.zig '$(DESTDIR)$(datadir)/plzig/sdk/'
	$(MKDIR_P) '$(DESTDIR)$(docdir)/$(docmoduledir)/plzig/LICENSES'
	$(INSTALL_DATA) LICENSE THIRD-PARTY-NOTICES '$(DESTDIR)$(docdir)/$(docmoduledir)/plzig/'
	$(INSTALL_DATA) LICENSES/Apache-2.0-WITH-LLVM-exception.txt LICENSES/MIT-Zig.txt \
	    '$(DESTDIR)$(docdir)/$(docmoduledir)/plzig/LICENSES/'

uninstall: uninstall-plzig

uninstall-plzig:
	rm -rf '$(DESTDIR)$(pkglibdir)/plzig' '$(DESTDIR)$(datadir)/plzig' \
	    '$(DESTDIR)$(docdir)/$(docmoduledir)/plzig'

clean: clean-plzig

clean-plzig:
	rm -rf results regression.diffs regression.out output_iso tmp_check plzig.control plzig.control.tmp

distclean-plzig: clean-plzig
	rm -rf $(BUILD_DIR)

.PHONY: install-plzig uninstall-plzig clean-plzig distclean-plzig fetch-zig install-zig check-zig abi check-abi installcheck-testing installcheck-isolation dist check-licenses installcheck-licenses
