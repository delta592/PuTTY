# PuTTYgen.app — SSH key generator / converter (Phase 7.3).

set(_puttygen_app_version "0.0.0")

set(MACOSX_BUNDLE_EXECUTABLE_NAME puttygen)
set(MACOSX_BUNDLE_BUNDLE_NAME PuTTYgen)
set(MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.puttygen)
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${_puttygen_app_version})
set(MACOSX_BUNDLE_BUNDLE_VERSION ${_puttygen_app_version})

configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
  ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  NEWLINE_STYLE UNIX)

# ---------------------------------------------------------------------------
# puttygen-macos-bridge — keygen C API for Swift
# ---------------------------------------------------------------------------

set(PUTTY_MACOS_PUTTYGENBRIDGE_MODULE_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}
  CACHE INTERNAL "PuttygenBridge module.modulemap directory")

add_library(puttygen-macos-bridge STATIC
  puttygen-bridge.c
  puttygen-app.c
  $<TARGET_OBJECTS:puttygen-common>
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c)

target_include_directories(puttygen-macos-bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})

target_include_directories(puttygen-macos-bridge PRIVATE
  ${CMAKE_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}/macos
  ${CMAKE_SOURCE_DIR}/macos/platform)

target_link_libraries(puttygen-macos-bridge PUBLIC
  keygen
  crypto
  utils
  ${platform_libraries})

# ---------------------------------------------------------------------------
# puttygen.app
# ---------------------------------------------------------------------------

add_executable(puttygen-app MACOSX_BUNDLE
  PuttygenApp.swift
  PuttygenWindowController.swift)

set_target_properties(puttygen-app PROPERTIES
  OUTPUT_NAME puttygen
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.puttygen
  MACOSX_BUNDLE_BUNDLE_NAME PuTTYgen
  MACOSX_BUNDLE_BUNDLE_VERSION ${_puttygen_app_version}
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${_puttygen_app_version}
  Swift_MODULE_NAME PuttygenApp
  Swift_LANGUAGE_VERSION 6
  Swift_MODULE_SEARCH_PATHS "${PUTTY_MACOS_PUTTYGENBRIDGE_MODULE_DIR}")

target_compile_options(puttygen-app PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(puttygen-app PRIVATE
  "-framework AppKit"
  "-framework UniformTypeIdentifiers"
  puttygen-macos-bridge)

putty_macos_add_app_resources(puttygen-app Puttygen.icns)
putty_macos_register_gui_app(puttygen-app)
installed_program(puttygen-app)

# Headless smoke
add_executable(putty-mac-puttygen-smoke-c
  puttygen-smoke-main.c)
target_link_libraries(putty-mac-puttygen-smoke-c PRIVATE puttygen-macos-bridge)
