# macOS platform build (AppKit GUI).
#
# Phase 1.2: CMake integration stub. Platform C sources are wired in
# Phase 2; Swift/AppKit application targets are added in Phase 1.4+.

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

include(${CMAKE_CURRENT_SOURCE_DIR}/platform_sources.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/icons.cmake)

# Swift / Objective-C toolchain (Phase 1.3; languages enabled at project()).
set(CMAKE_Swift_LANGUAGE_VERSION 6)

# Directory containing module.modulemap for the PuttyBridge clang module.
set(PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/bridge
  CACHE INTERNAL "PuttyBridge module.modulemap directory")

function(putty_macos_configure_swift_target target)
  set_target_properties(${target} PROPERTIES
    Swift_LANGUAGE_VERSION 6
    Swift_MODULE_SEARCH_PATHS "${PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR}")
endfunction()

function(putty_macos_register_gui_app target)
  set_property(GLOBAL APPEND PROPERTY PUTTY_MACOS_GUI_APP_TARGETS ${target})
endfunction()

add_subdirectory(bridge)
add_subdirectory(PuTTY)

if(PUTTY_MACOS_UNIVERSAL AND PUTTY_MACOS_UNIVERSAL_ACTIVE)
  get_property(_putty_macos_gui_apps GLOBAL PROPERTY PUTTY_MACOS_GUI_APP_TARGETS)
  if(_putty_macos_gui_apps)
    set(_putty_macos_verify_commands)
    foreach(_putty_macos_gui_app ${_putty_macos_gui_apps})
      list(APPEND _putty_macos_verify_commands
        COMMAND ${CMAKE_COMMAND}
          -DEXE=$<TARGET_FILE:${_putty_macos_gui_app}>
          -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/verify_universal.cmake)
    endforeach()
    add_custom_target(verify-universal
      ${_putty_macos_verify_commands}
      DEPENDS ${_putty_macos_gui_apps}
      COMMENT "Verifying Universal 2 GUI app binaries"
      VERBATIM)
  endif()
endif()
