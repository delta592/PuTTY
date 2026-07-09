# putty-macos-bridge — stable C API consumed by Swift (Phase 3.1+).
#
# Swift imports the PuttyBridge clang module (module.modulemap). Production
# code should call C functions from putty-bridge.h; reserve @_cdecl for
# test hooks such as PuttyBridgeSwiftSmoke below.

add_library(putty-macos-bridge STATIC
  putty-bridge.c
  putty-session.c
  putty-conf.c
  putty-eventloop.c
  putty-bridge-thread.c
  putty-bridge-phase3-exit.c
  putty-bridge-platform.c
  putty-bridge-app.c
  putty-bridge-termwin.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/no-gtk.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/unicode.c)

target_include_directories(putty-macos-bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})

target_include_directories(putty-macos-bridge PRIVATE
  ${CMAKE_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}/macos
  ${CMAKE_SOURCE_DIR}/macos/platform)

be_list(putty-macos-bridge PuTTY SSH SERIAL OTHERBACKENDS)

target_link_libraries(putty-macos-bridge PRIVATE
  macguifrontend
  guiterminal
  eventloop
  sshclient
  otherbackends
  settings
  network
  crypto
  utils
  charset
  ${platform_libraries})

# Compile-time check that Swift can import the PuttyBridge clang module.
add_library(PuttyBridgeSwiftSmoke STATIC
  PuttyBridgeSmoke.swift)

target_link_libraries(PuttyBridgeSwiftSmoke PRIVATE
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeSwiftSmoke)

# Phase 3 exit-criteria harness: SSH session + output callback (Swift driver).
add_executable(PuttyBridgePhase3ExitTest
  PuttyBridgePhase3ExitTest.swift)

target_compile_options(PuttyBridgePhase3ExitTest PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(PuttyBridgePhase3ExitTest PRIVATE
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgePhase3ExitTest)

add_executable(putty-bridge-phase3-exit-c
  putty-bridge-phase3-exit-main.c)

target_link_libraries(putty-bridge-phase3-exit-c PRIVATE
  putty-macos-bridge)

add_executable(putty-bridge-conf-smoke-c
  putty-bridge-conf-smoke-main.c)

target_link_libraries(putty-bridge-conf-smoke-c PRIVATE
  putty-macos-bridge)

# Phase 4.4 terminal paint performance gate (C noop-callback driver).
add_executable(putty-bridge-termwin-perf-c
  putty-bridge-termwin-perf-main.c)

target_link_libraries(putty-bridge-termwin-perf-c PRIVATE
  putty-macos-bridge)

# Phase 4.4 full Swift Core Text paint benchmark.
add_executable(PuttyBridgeTermPerfTest
  PuttyBridgeTermPerfTest.swift
  ${CMAKE_CURRENT_SOURCE_DIR}/../PuTTY/TerminalTextRenderer.swift
  ${CMAKE_CURRENT_SOURCE_DIR}/../PuTTY/TerminalFontCache.swift
  ${CMAKE_CURRENT_SOURCE_DIR}/../PuTTY/TerminalPaletteCache.swift)

target_compile_options(PuttyBridgeTermPerfTest PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(PuttyBridgeTermPerfTest PRIVATE
  "-framework AppKit"
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeTermPerfTest)

add_executable(putty-bridge-termwin-input-smoke-c
  putty-bridge-termwin-input-smoke-main.c)

target_link_libraries(putty-bridge-termwin-input-smoke-c PRIVATE
  putty-macos-bridge)

add_executable(putty-bridge-termwin-clipboard-smoke-c
  putty-bridge-termwin-clipboard-smoke-main.c)

target_link_libraries(putty-bridge-termwin-clipboard-smoke-c PRIVATE
  putty-macos-bridge)
