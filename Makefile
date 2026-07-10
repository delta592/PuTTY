# Convenience targets for PuTTY macOS GUI testing (Phase 9.1).
#
# This is not the CMake-generated build system. Prefer:
#   ./macos/build.sh --dev
# then:
#   make test
#   make test-all
#   make coverage
#   make help
#
# Override the build profile / tree:
#   make test PROFILE=release
#   make test BUILD_DIR=/path/to/build-macos-gui
#   make coverage COVERAGE_BUILD_DIR=/path/to/build-macos-gui-coverage

PROFILE   ?= dev
BUILD_DIR ?=
JOBS      ?=
COVERAGE_BUILD_DIR ?= build-macos-gui-coverage

# profile -> default build directory (must match macos/build.sh)
ifeq ($(PROFILE),dev)
  _default_build := build-macos-gui-dev
else ifeq ($(PROFILE),release)
  _default_build := build-macos-gui
else ifeq ($(PROFILE),universal)
  _default_build := build-macos-gui-universal
else
  $(error unknown PROFILE='$(PROFILE)'; use dev, release, or universal)
endif

ifeq ($(BUILD_DIR),)
  BUILD_DIR := $(_default_build)
endif

BUILD_SH := ./macos/build.sh
CTEST    := ctest
CMAKE    := cmake

# Homebrew LDFLAGS/CPPFLAGS can break Xcode Swift SDK modules.
export LDFLAGS :=
export CPPFLAGS :=
unexport SDKROOT

# Xcode generator places configs under Release/ (universal profile).
ifeq ($(PROFILE),universal)
  CTEST_CONFIG := -C Release
  CMAKE_CONFIG := --config Release
else
  CTEST_CONFIG :=
  CMAKE_CONFIG :=
endif

ifdef JOBS
  PARALLEL := --parallel $(JOBS)
else
  PARALLEL := --parallel
endif

# Portable utils self-tests built by the root CMakeLists but not in CTest.
# Omit test_unicode_norm / bidi_test: they need external UCD fixtures.
UTILS_TESTS := \
  test_host_strfoo \
  test_decode_utf8 \
  test_tree234 \
  test_wildcard \
  test_cert_expr \
  test_stripctrl

.PHONY: help
help:
	@printf '%s\n' \
	  'PuTTY macOS test targets (PROFILE=$(PROFILE), BUILD_DIR=$(BUILD_DIR))' \
	  '' \
	  '  make test            Full CTest suite labelled macos (unit+crypt+perf+ui)' \
	  '  make test-unit       CTest -L unit (portable + macOS smokes)' \
	  '  make test-crypt      CTest -L crypt (Python cryptsuite / testcrypt)' \
	  '  make test-perf       CTest -L perf (Phase 4 paint budget)' \
	  '  make test-ui         CTest -L xctest (PuttyMacUITests)' \
	  '  make test-utils      Root utils binaries not registered in CTest' \
	  '  make test-all        test + test-utils' \
	  '  make test-list       List CTest cases (ctest -N -L macos)' \
	  '  make test-gate       Build putty-mac-test-gate only (do not run)' \
	  '  make coverage        Debug + PUTTY_COVERAGE; CTest unit|crypt' \
	  '' \
	  'Examples:' \
	  '  make test' \
	  '  make test-all PROFILE=release' \
	  '  make test-perf BUILD_DIR=build-macos-gui' \
	  '  make coverage' \
	  '' \
	  'Equivalent: ./macos/build.sh test --$(PROFILE)'

.PHONY: test test-macos
test test-macos: test-gate
	@test -f "$(BUILD_DIR)/CTestTestfile.cmake" || \
	  { echo "error: $(BUILD_DIR)/CTestTestfile.cmake missing; run: $(BUILD_SH) configure --$(PROFILE)"; exit 1; }
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L macos

.PHONY: test-unit
test-unit: test-gate
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L unit

.PHONY: test-crypt
test-crypt: test-gate
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L crypt

.PHONY: test-perf
test-perf: test-gate
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L perf

.PHONY: test-ui
test-ui: test-gate
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L xctest

.PHONY: test-utils
test-utils: test-gate
	@set -e; \
	missing=0; \
	for t in $(UTILS_TESTS); do \
	  if [ ! -x "$(BUILD_DIR)/$$t" ]; then \
	    echo "error: missing $(BUILD_DIR)/$$t"; missing=1; \
	  fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
	  echo "error: build utils tests first (make test-gate)"; exit 1; \
	fi; \
	for t in $(UTILS_TESTS); do \
	  echo "==> $$t"; \
	  "$(BUILD_DIR)/$$t"; \
	done; \
	echo 'test-utils: ok'

.PHONY: test-all
test-all: test test-utils

.PHONY: test-list
test-list:
	@test -f "$(BUILD_DIR)/CTestTestfile.cmake" || \
	  { echo "error: $(BUILD_DIR) not configured"; exit 1; }
	$(CTEST) --test-dir "$(BUILD_DIR)" -N -L macos

.PHONY: test-gate
test-gate:
	@if [ ! -f "$(BUILD_DIR)/CMakeCache.txt" ]; then \
	  echo "==> configuring $(PROFILE) -> $(BUILD_DIR)"; \
	  $(BUILD_SH) configure --$(PROFILE) --build-dir "$(BUILD_DIR)"; \
	fi
	$(CMAKE) --build "$(BUILD_DIR)" $(CMAKE_CONFIG) $(PARALLEL) --target putty-mac-test-gate
	@# Ensure root utils self-tests exist for test-utils / test-all.
	$(CMAKE) --build "$(BUILD_DIR)" $(CMAKE_CONFIG) $(PARALLEL) --target \
	  test_host_strfoo test_decode_utf8 \
	  test_tree234 test_wildcard test_cert_expr test_stripctrl

# Instrumented C coverage tree (separate from PROFILE builds). Instruments
# C/ObjC via -DPUTTY_COVERAGE=ON; does not cover Swift sources. Expect ~50–60%
# on bridge+platform+terminal+utils+settings without live SSH/serial.
.PHONY: coverage
coverage:
	@echo "==> configuring coverage -> $(COVERAGE_BUILD_DIR)"
	$(CMAKE) -S . -B "$(COVERAGE_BUILD_DIR)" -G Ninja \
	  -DCMAKE_BUILD_TYPE=Debug \
	  -DPUTTY_MACOS_GUI=ON \
	  -DPUTTY_COVERAGE=ON
	@find "$(COVERAGE_BUILD_DIR)" -name '*.gcda' -delete 2>/dev/null || true
	$(CMAKE) --build "$(COVERAGE_BUILD_DIR)" $(PARALLEL) --target putty-mac-test-gate
	$(CTEST) --test-dir "$(COVERAGE_BUILD_DIR)" --output-on-failure -L 'unit|crypt'
	@printf '%s\n' \
	  "coverage: unit|crypt finished under $(COVERAGE_BUILD_DIR)" \
	  "  .gcda:  find $(COVERAGE_BUILD_DIR) -name '*.gcda'" \
	  "  report: xcrun llvm-cov gcov -n path/to/foo.c.gcda"
