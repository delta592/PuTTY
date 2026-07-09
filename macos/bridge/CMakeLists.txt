# putty-macos-bridge — stable C API consumed by Swift (Phase 3.1+).
#
# Swift imports the PuttyBridge clang module (module.modulemap). Production
# code should call C functions from putty-bridge.h; reserve @_cdecl for
# test hooks such as PuttyBridgeSwiftSmoke below.

add_library(putty-macos-bridge STATIC
  putty-bridge.c
  putty-session.c
  putty-bridge-app.c
  ${CMAKE_CURRENT_SOURCE_DIR}/../platform/no-gtk.c)

target_include_directories(putty-macos-bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})

target_include_directories(putty-macos-bridge PRIVATE
  ${CMAKE_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}/macos)

be_list(putty-macos-bridge PuTTY SSH SERIAL OTHERBACKENDS)

target_link_libraries(putty-macos-bridge PRIVATE
  guiterminal
  eventloop
  sshclient
  otherbackends
  settings
  network
  crypto
  utils
  ${platform_libraries})

# Compile-time check that Swift can import the PuttyBridge clang module.
add_library(PuttyBridgeSwiftSmoke STATIC
  PuttyBridgeSmoke.swift)

target_link_libraries(PuttyBridgeSwiftSmoke PRIVATE
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeSwiftSmoke)
