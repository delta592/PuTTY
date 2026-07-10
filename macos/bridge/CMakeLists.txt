# putty-macos-bridge — stable C API consumed by Swift (Phase 3.1+).
#
# Swift imports the PuttyBridge clang module (module.modulemap). Production
# code should call C functions from putty-bridge.h; reserve @_cdecl for
# test hooks such as PuttyBridgeSwiftSmoke below.

add_library(putty-macos-bridge STATIC
  putty-bridge.c
  putty-session.c
  putty-conf.c
  putty-bridge-cmdline.c
  putty-bridge-launch.c
  putty-eventloop.c
  putty-bridge-thread.c
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

# Shared main() for C smoke / exit harnesses (one source, many executables).
function(putty_add_bridge_smoke target)
  cmake_parse_arguments(ARG "" "FUNC;OK_MSG" "EXTRA_SOURCES" ${ARGN})
  if(NOT ARG_FUNC OR NOT ARG_OK_MSG)
    message(FATAL_ERROR "putty_add_bridge_smoke requires FUNC and OK_MSG")
  endif()
  add_executable(${target} putty-bridge-smoke-main.c ${ARG_EXTRA_SOURCES})
  target_compile_definitions(${target} PRIVATE
    PUTTY_BRIDGE_SMOKE_FUNC=${ARG_FUNC}
    PUTTY_SMOKE_LABEL="${ARG_FUNC}"
    PUTTY_SMOKE_OK_MSG="${ARG_OK_MSG}")
  target_include_directories(${target} PRIVATE
    ${CMAKE_SOURCE_DIR}/macos/platform)
  target_link_libraries(${target} PRIVATE putty-macos-bridge)
endfunction()

# Compile-time check that Swift can import the PuttyBridge clang module.
add_library(PuttyBridgeSwiftSmoke STATIC
  PuttyBridgeSmoke.swift)

target_link_libraries(PuttyBridgeSwiftSmoke PRIVATE
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeSwiftSmoke)

putty_add_bridge_smoke(putty-bridge-conf-smoke-c
  FUNC putty_bridge_conf_smoke
  OK_MSG "putty-bridge-conf-smoke: ok")

# Phase 4.4 terminal paint performance gate (custom driver with noop callbacks).
add_executable(putty-bridge-termwin-perf-c
  putty-bridge-termwin-perf-main.c)

target_link_libraries(putty-bridge-termwin-perf-c PRIVATE
  putty-macos-bridge)

# PuttyBridgeTermPerfTest (Swift Core Text paint) is defined in PuttyMacUI/
# after putty-macui exists; see macos/PuttyMacUI/CMakeLists.txt.

putty_add_bridge_smoke(putty-bridge-termwin-input-smoke-c
  FUNC putty_bridge_termwin_input_smoke
  OK_MSG "putty-bridge-termwin-input-smoke: ok")

putty_add_bridge_smoke(putty-bridge-termwin-clipboard-smoke-c
  FUNC putty_bridge_termwin_clipboard_smoke
  OK_MSG "putty-bridge-termwin-clipboard-smoke: ok")

putty_add_bridge_smoke(putty-bridge-termwin-scroll-resize-smoke-c
  FUNC putty_bridge_termwin_scroll_resize_smoke
  OK_MSG "putty-bridge-termwin-scroll-resize-smoke: ok")

putty_add_bridge_smoke(putty-bridge-termwin-bell-title-smoke-c
  FUNC putty_bridge_termwin_bell_title_smoke
  OK_MSG "putty-bridge-termwin-bell-title-smoke: ok")

putty_add_bridge_smoke(putty-bridge-termwin-exit-c
  FUNC putty_bridge_termwin_exit_smoke
  OK_MSG "putty-bridge-termwin-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-seat-output-exit-c
  FUNC putty_bridge_termwin_seat_output_exit_smoke
  OK_MSG "putty-bridge-termwin-seat-output-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-seat-dialogs-exit-c
  FUNC putty_bridge_termwin_seat_dialogs_exit_smoke
  OK_MSG "putty-bridge-termwin-seat-dialogs-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-eventloop-exit-c
  FUNC putty_bridge_termwin_eventloop_exit_smoke
  OK_MSG "putty-bridge-termwin-eventloop-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-window-exit-c
  FUNC putty_bridge_termwin_window_exit_smoke
  OK_MSG "putty-bridge-termwin-window-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-specials-exit-c
  FUNC putty_bridge_termwin_specials_exit_smoke
  OK_MSG "putty-bridge-termwin-specials-exit: ok")

putty_add_bridge_smoke(putty-bridge-termwin-eventlog-smoke-c
  FUNC putty_bridge_termwin_eventlog_smoke
  OK_MSG "putty-bridge-termwin-eventlog-smoke: ok")

putty_add_bridge_smoke(putty-bridge-ssh-exit-c
  FUNC putty_bridge_ssh_exit_test
  OK_MSG "putty-bridge-ssh-exit: ok"
  EXTRA_SOURCES putty-bridge-ssh-exit.c)

# Aggregate build targets for phase exit gates (see MACOS_GUI_PLAN.md).
add_custom_target(putty-mac-termwin-gate
  DEPENDS
    putty-mac-termwin-smoke-c
    putty-bridge-termwin-exit-c
    putty-bridge-termwin-perf-c
    putty-bridge-termwin-input-smoke-c
    putty-bridge-termwin-clipboard-smoke-c
    putty-bridge-termwin-scroll-resize-smoke-c
    putty-bridge-termwin-bell-title-smoke-c
    test_terminal
    PuTTY
  COMMENT "Build TermWin gate binaries")

add_custom_target(putty-mac-seat-gate
  DEPENDS
    putty-mac-seat-smoke-c
    putty-mac-seat-output-smoke-c
    putty-mac-seat-dialogs-smoke-c
    putty-bridge-termwin-seat-output-exit-c
    putty-bridge-termwin-seat-dialogs-exit-c
    putty-bridge-termwin-eventloop-exit-c
    putty-bridge-termwin-window-exit-c
    putty-bridge-termwin-specials-exit-c
    putty-bridge-ssh-exit-c
  COMMENT "Build MacGuiSeat gate binaries")

putty_add_bridge_smoke(putty-bridge-launch-smoke-c
  FUNC putty_bridge_launch_smoke
  OK_MSG "putty-bridge-launch-smoke: ok")

add_custom_target(putty-mac-config-gate
  DEPENDS
    putty-mac-config-smoke-c
    putty-bridge-launch-smoke-c
    putty-bridge-termwin-eventlog-smoke-c
  COMMENT "Build config / launch / event-log / CA gate binaries (Phase 6.1–6.5)")
