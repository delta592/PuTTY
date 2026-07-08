# macOS platform build (AppKit GUI).
#
# Phase 1.2: CMake integration stub. Platform C sources are wired in
# Phase 2; Swift/AppKit application targets are added in Phase 1.3+.

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

# GUI application targets (PuTTY.app, etc.) are added under macos/PuTTY/
# in Phase 1.4, guarded by the macos platform selection in setup.cmake.
