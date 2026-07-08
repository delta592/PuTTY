# macOS platform build (AppKit GUI).
#
# Phase 1.2: CMake integration stub. Platform C sources are wired in
# Phase 2; Swift/AppKit application targets are added in Phase 1.4+.

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

# Swift / Objective-C toolchain (Phase 1.3).
cmake_policy(SET CMP0157 NEW)
set(CMAKE_Swift_LANGUAGE_VERSION 6)
enable_language(OBJC OBJCXX Swift)

# Directory containing module.modulemap for the PuttyBridge clang module.
set(PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/bridge
  CACHE INTERNAL "PuttyBridge module.modulemap directory")

function(putty_macos_configure_swift_target target)
  set_target_properties(${target} PROPERTIES
    Swift_LANGUAGE_VERSION 6
    Swift_MODULE_SEARCH_PATHS "${PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR}")
endfunction()

add_subdirectory(bridge)

# GUI application targets (PuTTY.app, etc.) are added under macos/PuTTY/
# in Phase 1.4, guarded by the macos platform selection in setup.cmake.
