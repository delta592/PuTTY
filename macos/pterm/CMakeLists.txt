# pterm.app — local PTY terminal (Phase 7.2 / 7.5).
#
# Links putty-macui (shared TerminalView / session Swift) and
# pterm-macos-bridge (pty_backend + non-network app constants).

set(MACOSX_BUNDLE_EXECUTABLE_NAME pterm)
set(MACOSX_BUNDLE_BUNDLE_NAME pterm)
set(MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.pterm)
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${PUTTY_MACOS_BUNDLE_SHORT_VERSION})
set(MACOSX_BUNDLE_BUNDLE_VERSION ${PUTTY_MACOS_BUNDLE_VERSION})

configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
  ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  NEWLINE_STYLE UNIX)

# ---------------------------------------------------------------------------
# pterm-macos-bridge — same PuttyBridge API, pterm app constants + PTY
# ---------------------------------------------------------------------------

add_library(pterm-macos-bridge STATIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-session.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-conf.c
  ${CMAKE_CURRENT_SOURCE_DIR}/pterm-bridge-cmdline.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge-launch.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-eventloop.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge-thread.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge-platform.c
  ${CMAKE_CURRENT_SOURCE_DIR}/pterm-app.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge-termwin.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/pty.c
  ${CMAKE_SOURCE_DIR}/otherbackends/testback.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/printing.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-ca-config.c
  ${CMAKE_SOURCE_DIR}/proxy/nosshproxy.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/no-gtk.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/unicode.c)
# no-dit.c is empty when HAVE_ARM_DIT is off (enable_dit is a macro); linking
# an empty .o makes Apple libtool warn "has no symbols".
if(HAVE_ARM_DIT)
  target_sources(pterm-macos-bridge PRIVATE
    ${CMAKE_SOURCE_DIR}/stubs/no-dit.c)
endif()

target_include_directories(pterm-macos-bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge)

target_include_directories(pterm-macos-bridge PRIVATE
  ${CMAKE_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}/macos
  ${CMAKE_SOURCE_DIR}/macos/platform)

be_list(pterm-macos-bridge pterm)

target_link_libraries(pterm-macos-bridge PRIVATE
  macguifrontend
  guiterminal
  eventloop
  settings
  network
  utils
  charset)
target_link_libraries(pterm-macos-bridge PUBLIC ${platform_libraries})

# ---------------------------------------------------------------------------
# pterm.app
# ---------------------------------------------------------------------------

add_executable(pterm MACOSX_BUNDLE
  PtermApp.swift)

set_target_properties(pterm PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.pterm
  MACOSX_BUNDLE_BUNDLE_NAME pterm
  MACOSX_BUNDLE_BUNDLE_VERSION ${PUTTY_MACOS_BUNDLE_VERSION}
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${PUTTY_MACOS_BUNDLE_SHORT_VERSION}
  OUTPUT_NAME pterm)

target_compile_options(pterm PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(pterm PRIVATE
  "-framework AppKit"
  putty-macui
  pterm-macos-bridge
  macguifrontend
  guiterminal eventloop settings network utils)

putty_macos_configure_swift_target(pterm)
putty_macos_add_app_resources(pterm Pterm.icns)
putty_macos_register_gui_app(pterm)
installed_program(pterm)

# Headless smoke: pterm constants + immediate launch path.
add_executable(putty-mac-pterm-smoke-c
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/putty-bridge-smoke-main.c
  pterm-smoke.c)
target_compile_definitions(putty-mac-pterm-smoke-c PRIVATE
  PUTTY_BRIDGE_SMOKE_FUNC=putty_mac_pterm_smoke
  PUTTY_SMOKE_LABEL="putty_mac_pterm_smoke"
  PUTTY_SMOKE_OK_MSG="putty-mac-pterm-smoke: ok")
target_include_directories(putty-mac-pterm-smoke-c PRIVATE
  ${CMAKE_SOURCE_DIR}/macos/platform
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge)
target_link_libraries(putty-mac-pterm-smoke-c PRIVATE pterm-macos-bridge)
