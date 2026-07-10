# Convenience targets for PuTTY macOS GUI testing (Phase 9.1) and quality
# tooling (sanitizers, coverage, lint, static analysis).
#
# This is not the CMake-generated build system. Prefer:
#   ./macos/build.sh --dev
# then:
#   make test
#   make test-all
#   make coverage
#   make asan
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
COVERAGE_SWIFT_BUILD_DIR ?= build-macos-gui-coverage-swift
ASAN_BUILD_DIR ?= build-macos-gui-asan
TSAN_BUILD_DIR ?= build-macos-gui-tsan
ANALYZE_OUT_DIR ?= build-macos-gui-analyze

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
SCRIPTS  := ./macos/scripts

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
	  'Tests:' \
	  '  make test            Full CTest suite labelled macos (unit+crypt+perf+ui)' \
	  '  make test-unit       CTest -L unit (portable + macOS smokes)' \
	  '  make test-crypt      CTest -L crypt (Python cryptsuite / testcrypt)' \
	  '  make test-perf       CTest -L perf (Phase 4 paint budget; keep this gate)' \
	  '  make test-ui         CTest -L xctest (PuttyMacUITests)' \
	  '  make test-thread     CTest -L thread (TSan-oriented smokes)' \
	  '  make test-utils      Root utils binaries not registered in CTest' \
	  '  make test-all        Every test process (see below)' \
	  '  make test-list       List CTest cases (ctest -N -L macos)' \
	  '  make test-gate       Build putty-mac-test-gate only (do not run)' \
	  '' \
	  '  make test-all runs, in order:' \
	  '    test, test-utils, asan, tsan, coverage, coverage-swift,' \
	  '    quality, analyze-c' \
	  '' \
	  'Coverage / sanitizers (separate Debug trees; not Universal release):' \
	  '  make coverage        C/ObjC LLVM coverage; CTest unit|crypt' \
	  '  make coverage-swift  C + Swift coverage; unit|crypt|xctest + report' \
	  '  make asan            ASan+UBSan Debug; CTest -L unit' \
	  '  make ubsan           Alias for asan (undefined included)' \
	  '  make tsan            TSan Debug; CTest -L thread' \
	  '' \
	  'Lint / static analysis (macos/ only; never reformats upstream *.c):' \
	  '  make lint-swift      SwiftLint' \
	  '  make format-swift    SwiftFormat --lint' \
	  '  make format-swift-apply  SwiftFormat --apply' \
	  '  make tidy-c          clang-tidy on macos/ C+ObjC' \
	  '  make analyze-c       Clang Static Analyzer on macos/ C+ObjC' \
	  '  make quality         lint-swift + format-swift + tidy-c' \
	  '' \
	  'Examples:' \
	  '  make test' \
	  '  make test-all PROFILE=release' \
	  '  make test-perf BUILD_DIR=build-macos-gui' \
	  '  make asan' \
	  '  make coverage-swift' \
	  '' \
	  'Equivalent: ./macos/build.sh test --$(PROFILE)' \
	  'Docs: macos/TESTING.md'

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

.PHONY: test-thread
test-thread: test-gate
	$(CTEST) --test-dir "$(BUILD_DIR)" --output-on-failure $(CTEST_CONFIG) -L thread

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
# Full battery: PROFILE CTest + utils, then sanitizer/coverage trees, then
# macos/-scoped lint and static analysis. Sequential so `make -j test-all`
# still finishes each stage before starting the next.
test-all:
	$(MAKE) test
	$(MAKE) test-utils
	$(MAKE) asan
	$(MAKE) tsan
	$(MAKE) coverage
	$(MAKE) coverage-swift
	$(MAKE) quality
	$(MAKE) analyze-c
	@echo 'test-all: ok'

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
# C/ObjC via -DPUTTY_COVERAGE=ON. Expect ~50–60% on
# bridge+platform+terminal+utils+settings without live SSH/serial.
.PHONY: coverage
coverage:
	@echo "==> configuring coverage -> $(COVERAGE_BUILD_DIR)"
	$(CMAKE) -S . -B "$(COVERAGE_BUILD_DIR)" -G Ninja \
	  -DCMAKE_BUILD_TYPE=Debug \
	  -DPUTTY_MACOS_GUI=ON \
	  -DPUTTY_MACOS_UNIVERSAL=OFF \
	  -DPUTTY_COVERAGE=ON
	@find "$(COVERAGE_BUILD_DIR)" -name '*.gcda' -delete 2>/dev/null || true
	$(CMAKE) --build "$(COVERAGE_BUILD_DIR)" $(PARALLEL) --target putty-mac-test-gate
	$(CTEST) --test-dir "$(COVERAGE_BUILD_DIR)" --output-on-failure -L 'unit|crypt'
	@printf '%s\n' \
	  "coverage: unit|crypt finished under $(COVERAGE_BUILD_DIR)" \
	  "  .gcda:  find $(COVERAGE_BUILD_DIR) -name '*.gcda'" \
	  "  report: xcrun llvm-cov gcov -n path/to/foo.c.gcda"

# C + Swift LLVM coverage (PuttyMacUI / XCTest). Separate tree from `coverage`.
.PHONY: coverage-swift
coverage-swift:
	@echo "==> configuring Swift coverage -> $(COVERAGE_SWIFT_BUILD_DIR)"
	$(CMAKE) -S . -B "$(COVERAGE_SWIFT_BUILD_DIR)" -G Ninja \
	  -DCMAKE_BUILD_TYPE=Debug \
	  -DPUTTY_MACOS_GUI=ON \
	  -DPUTTY_MACOS_UNIVERSAL=OFF \
	  -DPUTTY_COVERAGE=ON \
	  -DPUTTY_SWIFT_COVERAGE=ON \
	  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
	@find "$(COVERAGE_SWIFT_BUILD_DIR)" \( -name '*.gcda' -o -name '*.profraw' \) \
	  -delete 2>/dev/null || true
	@rm -f default.profraw 2>/dev/null || true
	$(CMAKE) --build "$(COVERAGE_SWIFT_BUILD_DIR)" $(PARALLEL) --target putty-mac-test-gate
	@# Write profraw under the build tree for the report script.
	LLVM_PROFILE_FILE="$(COVERAGE_SWIFT_BUILD_DIR)/default-%p.profraw" \
	  $(CTEST) --test-dir "$(COVERAGE_SWIFT_BUILD_DIR)" --output-on-failure \
	  -L 'unit|crypt|xctest'
	$(SCRIPTS)/run-swift-coverage-report.sh "$(COVERAGE_SWIFT_BUILD_DIR)"

# ASan + UBSan Debug tree; run unit labels (skip UI/perf noise).
.PHONY: asan ubsan
asan ubsan:
	@echo "==> configuring ASan+UBSan -> $(ASAN_BUILD_DIR)"
	$(CMAKE) -S . -B "$(ASAN_BUILD_DIR)" -G Ninja \
	  -DCMAKE_BUILD_TYPE=Debug \
	  -DPUTTY_MACOS_GUI=ON \
	  -DPUTTY_MACOS_UNIVERSAL=OFF \
	  -DPUTTY_SANITIZE=address,undefined \
	  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
	$(CMAKE) --build "$(ASAN_BUILD_DIR)" $(PARALLEL) --target putty-mac-test-gate
	$(CTEST) --test-dir "$(ASAN_BUILD_DIR)" --output-on-failure -L unit
	@echo "asan: unit suite finished under $(ASAN_BUILD_DIR)"

# TSan Debug tree; thread-labelled smokes (event loop / bridge).
.PHONY: tsan
tsan:
	@echo "==> configuring TSan -> $(TSAN_BUILD_DIR)"
	$(CMAKE) -S . -B "$(TSAN_BUILD_DIR)" -G Ninja \
	  -DCMAKE_BUILD_TYPE=Debug \
	  -DPUTTY_MACOS_GUI=ON \
	  -DPUTTY_MACOS_UNIVERSAL=OFF \
	  -DPUTTY_SANITIZE=thread \
	  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
	$(CMAKE) --build "$(TSAN_BUILD_DIR)" $(PARALLEL) --target putty-mac-test-gate
	$(CTEST) --test-dir "$(TSAN_BUILD_DIR)" --output-on-failure -L thread
	@echo "tsan: thread suite finished under $(TSAN_BUILD_DIR)"

.PHONY: lint-swift
lint-swift:
	$(SCRIPTS)/run-swiftlint.sh

.PHONY: format-swift
format-swift:
	$(SCRIPTS)/run-swiftformat.sh --lint

.PHONY: format-swift-apply
format-swift-apply:
	$(SCRIPTS)/run-swiftformat.sh --apply

.PHONY: tidy-c
tidy-c:
	PUTTY_CLANG_TIDY_BUILD_DIR="$(BUILD_DIR)" $(SCRIPTS)/run-clang-tidy.sh

.PHONY: analyze-c
analyze-c:
	PUTTY_CLANG_ANALYZE_OUT="$(ANALYZE_OUT_DIR)" \
	PUTTY_CLANG_ANALYZE_BUILD_DIR="$(BUILD_DIR)" \
	  $(SCRIPTS)/run-clang-analyze.sh

.PHONY: quality
quality: lint-swift format-swift tidy-c
	@echo "quality: swiftlint + swiftformat --lint + clang-tidy ok"
