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
# WAMR is fetched at build time if WAMR_SRC is not given (pinned commit);
# the database server never downloads anything.

EXTENSION = plzig
MODULE_big = plzig
OBJS = src/plzig.o src/plzig_source.o src/plzig_build.o src/plzig_spawn.o \
       src/plzig_sandbox.o src/plzig_runtime.o src/plzig_host.o src/plzig_types.o \
       src/plzig_row.o
DATA = sql/plzig--1.0.sql
PGFILEDESC = "PL/Zig - procedural language"

REGRESS = setup basics types types_more types_fixed types_numeric types_calendar types_jsonb rows srf triggers xact signatures usage encoding errors spi spi_prepared spi_cursor \
          sandbox adversarial resources leaks lifecycle
REGRESS_OPTS = --inputdir=test --load-extension=plzig
# only against a PLZIG_TESTING=1 build: make installcheck-testing
REGRESS_TESTING = testing

PG_CONFIG ?= pg_config

# ---- pinned third-party inputs -------------------------------------------
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

# the Zig compiler used to build the validator (absolute path, exactly ZIG_VERSION)
ZIG ?=

BUILD_DIR := $(CURDIR)/build
ZIG_DL := $(BUILD_DIR)/dl/$(ZIG_DIRNAME).tar.xz
WAMR_BUILD_SRC := $(BUILD_DIR)/wamr-src
WAMR_LIB := $(BUILD_DIR)/wamr/libiwasm.a
VALIDATOR := $(BUILD_DIR)/plzig-validate

# The backend refuses any compiler whose `zig version` differs from the one
# the validator was built with (the validator uses that version's tokenizer).
PG_CPPFLAGS = -I$(WAMR_BUILD_SRC)/core/iwasm/include -DPLZIG_ZIG_VERSION='"$(ZIG_VERSION)"'
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
	    "$(CURDIR)/third_party/wamr-interrupt.patch"
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

$(OBJS): $(WAMR_LIB) src/plzig.h
$(shlib): $(WAMR_LIB)

all: $(VALIDATOR)

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

# ---- optional: obtain the pinned Zig (never part of build or install) ----
fetch-zig:
	sh third_party/fetch-zig.sh "$(ZIG_TARBALL)" "$(ZIG_URL)" "$(ZIG_SHA256)" \
	    "$(ZIG_DL)" "" "$(ZIG_DIRNAME)"

install-zig:
	@test -n "$(ZIG_PREFIX)" || { echo "usage: make install-zig ZIG_PREFIX=/opt/zig-$(ZIG_VERSION) [ZIG_TARBALL=...]" >&2; exit 1; }
	sh third_party/fetch-zig.sh "$(ZIG_TARBALL)" "$(ZIG_URL)" "$(ZIG_SHA256)" \
	    "$(ZIG_DL)" "$(ZIG_PREFIX)" "$(ZIG_DIRNAME)"

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
	rm -rf results regression.diffs regression.out output_iso tmp_check

distclean-plzig: clean-plzig
	rm -rf $(BUILD_DIR)

.PHONY: install-plzig uninstall-plzig clean-plzig distclean-plzig fetch-zig install-zig check-zig installcheck-testing installcheck-isolation
