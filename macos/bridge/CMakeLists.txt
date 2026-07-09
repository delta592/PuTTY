# putty-macos-bridge — stable C API consumed by Swift (Phase 3.1+).
#
# Swift imports the PuttyBridge clang module (module.modulemap). Production
# code should call C functions from putty-bridge.h; reserve @_cdecl for
# test hooks such as PuttyBridgeSwiftSmoke below.

add_library(putty-macos-bridge STATIC
  putty-bridge.c)

target_include_directories(putty-macos-bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})

# Compile-time check that Swift can import the PuttyBridge clang module.
add_library(PuttyBridgeSwiftSmoke STATIC
  PuttyBridgeSmoke.swift)

target_link_libraries(PuttyBridgeSwiftSmoke PRIVATE
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeSwiftSmoke)
