# Phase 9.1 — CTest registration + XCTest UI suite for PUTTY_MACOS_GUI builds.
#
# C unit / smoke binaries are registered with add_test(). The XCTest bundle
# exercises AppKit launch, local-echo (mock) connect, and config save/load
# through PuttyMacUI + PuttyBridge (no live SSH).

include(CTest)
if(NOT BUILD_TESTING)
  return()
endif()

# ---------------------------------------------------------------------------
# Portable C / Python unit tests (same set Buildscr runs on Unix)
# ---------------------------------------------------------------------------

# Portable / macOS unit binaries. Omit testzlib (stdin Deflate tool) and
# testsc (DynamoRIO side-channel harness; dry-run exits non-zero).
set(_putty_macos_ctest_binaries
  test_terminal
  test_conf
  cgtest
  test_lineedit
  putty-mac-termwin-smoke-c
  putty-mac-seat-smoke-c
  putty-mac-seat-output-smoke-c
  putty-mac-seat-dialogs-smoke-c
  putty-mac-config-smoke-c
  putty-mac-askpass-smoke-c
  putty-bridge-conf-smoke-c
  putty-bridge-launch-smoke-c
  putty-bridge-termwin-exit-c
  putty-bridge-termwin-input-smoke-c
  putty-bridge-termwin-clipboard-smoke-c
  putty-bridge-termwin-scroll-resize-smoke-c
  putty-bridge-termwin-bell-title-smoke-c
  putty-bridge-termwin-eventlog-smoke-c
  putty-bridge-termwin-seat-output-exit-c
  putty-bridge-termwin-seat-dialogs-exit-c
  putty-bridge-termwin-eventloop-exit-c
  putty-bridge-termwin-window-exit-c
  putty-bridge-termwin-specials-exit-c
)

foreach(_putty_macos_ctest ${_putty_macos_ctest_binaries})
  if(TARGET ${_putty_macos_ctest})
    add_test(NAME macos.${_putty_macos_ctest}
      COMMAND $<TARGET_FILE:${_putty_macos_ctest}>)
    set_tests_properties(macos.${_putty_macos_ctest} PROPERTIES
      LABELS "macos;unit"
      TIMEOUT 120)
  endif()
endforeach()

# fuzzterm: smoke stdin to catch easy crashes (mirrors Buildscr).
if(TARGET fuzzterm)
  add_test(NAME macos.fuzzterm-smoke
    COMMAND ${CMAKE_COMMAND}
      -DPUTTY_FUZZTERM=$<TARGET_FILE:fuzzterm>
      -P ${CMAKE_CURRENT_SOURCE_DIR}/run_fuzzterm_smoke.cmake)
  set_tests_properties(macos.fuzzterm-smoke PROPERTIES
    LABELS "macos;unit"
    TIMEOUT 60)
endif()

# testcrypt via Python cryptsuite (PUTTY_TESTCRYPT points at the binary).
if(TARGET testcrypt)
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME macos.cryptsuite
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/test/cryptsuite.py
      WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/test)
    set_tests_properties(macos.cryptsuite PROPERTIES
      ENVIRONMENT "PUTTY_TESTCRYPT=$<TARGET_FILE:testcrypt>"
      LABELS "macos;unit;crypt"
      TIMEOUT 600)
  else()
    message(STATUS "Python3 not found; skipping macos.cryptsuite (testcrypt)")
  endif()
endif()

# Phase 4 performance gate (assert timing unless PUTTY_BRIDGE_PERF_SKIP=1).
if(TARGET putty-bridge-termwin-perf-c)
  add_test(NAME macos.putty-bridge-termwin-perf-c
    COMMAND $<TARGET_FILE:putty-bridge-termwin-perf-c>)
  set_tests_properties(macos.putty-bridge-termwin-perf-c PROPERTIES
    LABELS "macos;perf"
    TIMEOUT 120)
endif()

if(TARGET PuttyBridgeTermPerfTest)
  add_test(NAME macos.PuttyBridgeTermPerfTest
    COMMAND $<TARGET_FILE:PuttyBridgeTermPerfTest>)
  set_tests_properties(macos.PuttyBridgeTermPerfTest PROPERTIES
    LABELS "macos;perf"
    TIMEOUT 180)
endif()

# Live SSH integration — skipped unless explicitly enabled.
if(TARGET putty-bridge-ssh-exit-c)
  add_test(NAME macos.putty-bridge-ssh-exit-c
    COMMAND $<TARGET_FILE:putty-bridge-ssh-exit-c>)
  set_tests_properties(macos.putty-bridge-ssh-exit-c PROPERTIES
    ENVIRONMENT "PUTTY_BRIDGE_SSH_EXIT_SKIP=1"
    LABELS "macos;integration;ssh"
    TIMEOUT 120)
endif()

# ---------------------------------------------------------------------------
# XCTest UI suite (PuttyMacUI + PuttyBridge; Ninja and Xcode)
# ---------------------------------------------------------------------------

# XCTest lives under the platform Developer tree, not the macOS SDK.
execute_process(
  COMMAND xcrun --sdk macosx --show-sdk-platform-path
  OUTPUT_VARIABLE _putty_macos_platform
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
set(_putty_xctest_dev "${_putty_macos_platform}/Developer")
set(_putty_xctest_fw "${_putty_xctest_dev}/Library/Frameworks")
set(_putty_xctest_lib "${_putty_xctest_dev}/usr/lib")

if(EXISTS "${_putty_xctest_fw}/XCTest.framework")
  list(APPEND CMAKE_FRAMEWORK_PATH "${_putty_xctest_fw}")
  list(APPEND CMAKE_SYSTEM_FRAMEWORK_PATH "${_putty_xctest_fw}")
endif()

# FindXCTest / xctest_add_bundle require CMAKE_OSX_SYSROOT, but forcing it into
# the CMake cache can make Swift pick up a mismatched Command Line Tools SDK.
# Set a directory-scoped value only when the cache entry is empty.
if(NOT CMAKE_OSX_SYSROOT)
  execute_process(
    COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE _putty_macos_sdk
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
  if(_putty_macos_sdk)
    set(CMAKE_OSX_SYSROOT "${_putty_macos_sdk}")
  endif()
endif()

find_package(XCTest)
if(NOT XCTest_FOUND)
  message(STATUS "XCTest not found; skipping PuttyMacUITests")
  return()
endif()

if(NOT CMAKE_OSX_SYSROOT)
  message(STATUS "CMAKE_OSX_SYSROOT unset; skipping PuttyMacUITests")
  return()
endif()

if(NOT EXISTS "${_putty_xctest_fw}/XCTest.framework")
  message(STATUS "XCTest.framework not under ${_putty_xctest_fw}; skipping PuttyMacUITests")
  return()
endif()

xctest_add_bundle(PuttyMacUITests putty-macui
  PuttyMacUITests/LaunchTests.swift
  PuttyMacUITests/ConfigSaveLoadTests.swift
  PuttyMacUITests/MockConnectTests.swift
  PuttyMacUITests/AccessibilityTests.swift
  PuttyMacUITests/IntegrationTests.swift
  PuttyMacUITests/TestSupport.swift)

set_target_properties(PuttyMacUITests PROPERTIES
  Swift_MODULE_NAME PuttyMacUITests
  XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME PuttyMacUITests
  XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE YES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_ENABLE_TESTING_SEARCH_PATHS YES)

# Embed XCTest rpaths once. Xcode uses LD_RUNPATH_SEARCH_PATHS; Ninja uses
# BUILD_RPATH. Do not also pass -Xlinker -rpath (duplicate -rpath warning).
if(CMAKE_GENERATOR STREQUAL "Xcode")
  set_property(TARGET PuttyMacUITests PROPERTY
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS
    "@loader_path/Frameworks ${_putty_xctest_fw} ${_putty_xctest_lib}")
else()
  set_property(TARGET PuttyMacUITests PROPERTY
    BUILD_RPATH "${_putty_xctest_fw};${_putty_xctest_lib}")
endif()

target_compile_options(PuttyMacUITests PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>"
  "$<$<COMPILE_LANGUAGE:Swift>:-F${_putty_xctest_fw}>"
  "$<$<COMPILE_LANGUAGE:Swift>:-I${_putty_xctest_lib}>")

# Swift XCTest needs libXCTestSwiftSupport when not using Xcode's test host.
target_link_options(PuttyMacUITests PRIVATE
  "SHELL:-F ${_putty_xctest_fw}"
  "SHELL:-L ${_putty_xctest_lib}"
  "SHELL:-lXCTestSwiftSupport")

# putty-macui is already linked by xctest_add_bundle(<bundle> putty-macui ...);
# listing it again makes Apple ld warn about a duplicate static archive.
target_link_libraries(PuttyMacUITests PRIVATE
  putty-macos-bridge
  "-framework AppKit"
  "-framework Foundation")

putty_macos_configure_swift_target(PuttyMacUITests)

xctest_add_test(macos.PuttyMacUITests PuttyMacUITests)
set_tests_properties(macos.PuttyMacUITests PROPERTIES
  LABELS "macos;ui;xctest"
  TIMEOUT 180)

# Aggregate build target for Phase 9.1 (does not run tests).
set(_putty_macos_test_gate_deps
  test_terminal
  test_conf
  cgtest
  test_lineedit
  testcrypt
  PuttyMacUITests
  PuttyBridgeTermPerfTest
  putty-bridge-termwin-perf-c
  putty-mac-termwin-gate
  putty-mac-seat-gate
  putty-mac-config-gate
)
if(TARGET putty-mac-askpass-smoke-c)
  list(APPEND _putty_macos_test_gate_deps putty-mac-askpass-smoke-c)
endif()

add_custom_target(putty-mac-test-gate
  DEPENDS ${_putty_macos_test_gate_deps}
  COMMENT "Build Phase 9.1 macOS test binaries (CTest + XCTest)")

# Run-targets (cmake --build <dir> --target putty-test-…). Prefer the root
# Makefile (`make test`, `make test-unit`, …) for day-to-day use.
# Multi-config generators get `-C <CONFIG>` / `--config <CONFIG>` via genex
# (`;` → separate argv).
set(_putty_macos_ctest_config_args
  "$<$<BOOL:${CMAKE_CONFIGURATION_TYPES}>:-C;$<CONFIG>>")
set(_putty_macos_build_config_args
  "$<$<BOOL:${CMAKE_CONFIGURATION_TYPES}>:--config;$<CONFIG>>")

function(putty_macos_add_ctest_run_target name)
  cmake_parse_arguments(ARG "" "LABEL;COMMENT" "" ${ARGN})
  if(NOT ARG_LABEL)
    message(FATAL_ERROR "putty_macos_add_ctest_run_target(${name}) needs LABEL")
  endif()
  add_custom_target(${name}
    COMMAND ${CMAKE_CTEST_COMMAND}
      --test-dir ${CMAKE_BINARY_DIR}
      --output-on-failure
      -L ${ARG_LABEL}
      ${_putty_macos_ctest_config_args}
    DEPENDS putty-mac-test-gate
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    COMMENT "${ARG_COMMENT}"
    USES_TERMINAL
    VERBATIM)
endfunction()

putty_macos_add_ctest_run_target(putty-test-macos
  LABEL macos
  COMMENT "Run all CTest cases labelled macos")
putty_macos_add_ctest_run_target(putty-test-unit
  LABEL unit
  COMMENT "Run CTest cases labelled unit")
putty_macos_add_ctest_run_target(putty-test-crypt
  LABEL crypt
  COMMENT "Run CTest cases labelled crypt (cryptsuite)")
putty_macos_add_ctest_run_target(putty-test-perf
  LABEL perf
  COMMENT "Run CTest cases labelled perf (Phase 4 paint gate)")
putty_macos_add_ctest_run_target(putty-test-ui
  LABEL xctest
  COMMENT "Run CTest cases labelled xctest (PuttyMacUITests)")

# Portable utils self-tests (root CMakeLists) — not registered with add_test.
# Omit test_unicode_norm / bidi_test (need external UCD NormalizationTest /
# BidiTest fixtures that are not shipped in-tree).
set(_putty_macos_utils_tests
  test_host_strfoo
  test_decode_utf8
  test_tree234
  test_wildcard
  test_cert_expr)
set(_putty_macos_utils_commands)
set(_putty_macos_utils_deps)
foreach(_putty_macos_utils ${_putty_macos_utils_tests})
  if(TARGET ${_putty_macos_utils})
    list(APPEND _putty_macos_utils_deps ${_putty_macos_utils})
    list(APPEND _putty_macos_utils_commands
      COMMAND ${CMAKE_COMMAND} -E echo "==> ${_putty_macos_utils}"
      COMMAND $<TARGET_FILE:${_putty_macos_utils}>)
  endif()
endforeach()
if(_putty_macos_utils_deps)
  add_custom_target(putty-test-utils
    ${_putty_macos_utils_commands}
    COMMAND ${CMAKE_COMMAND} -E echo "putty-test-utils: ok"
    DEPENDS ${_putty_macos_utils_deps}
    COMMENT "Run portable utils self-tests (not in CTest)"
    USES_TERMINAL
    VERBATIM)
  # Sequential: full macos CTest, then utils (DEPENDS alone may race).
  add_custom_target(putty-test-all
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
            --target putty-test-macos
            ${_putty_macos_build_config_args}
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
            --target putty-test-utils
            ${_putty_macos_build_config_args}
    COMMENT "Run macos CTest suite then utils self-tests"
    USES_TERMINAL
    VERBATIM)
endif()
