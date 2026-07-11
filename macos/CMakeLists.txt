# macOS platform build (AppKit GUI).
#
# Phase 2.2: non-GTK platform C modules (mirrors unix/CMakeLists.txt).

if(CMAKE_VERSION VERSION_LESS "3.28")
  message(FATAL_ERROR
    "PUTTY_MACOS_GUI requires CMake ≥ 3.28 (found ${CMAKE_VERSION}). "
    "Root cmake_minimum_required remains 3.7...3.28 for non-GUI builds.")
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/icons.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/bundle_version.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/help.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/quality.cmake)

# Swift language version is set once in the root CMakeLists.txt (Ninja:
# CMAKE_Swift_LANGUAGE_VERSION; Xcode: CMAKE_XCODE_ATTRIBUTE_SWIFT_VERSION).
# Do not also set the per-target Swift_LANGUAGE_VERSION property.

set(PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/bridge
  CACHE INTERNAL "PuttyBridge module.modulemap directory")

function(putty_macos_configure_swift_target target)
  # Clang module PuttyBridge (module.modulemap under macos/bridge/).
  target_include_directories(${target} PRIVATE
    ${PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR})
  # Swift module PuttyMacUI (when the static library has been defined).
  if(DEFINED PUTTY_MACOS_PUTTYMACUI_MODULE_DIR)
    target_include_directories(${target} PRIVATE
      ${PUTTY_MACOS_PUTTYMACUI_MODULE_DIR})
  endif()
  if(CMAKE_GENERATOR STREQUAL "Xcode")
    # Xcode always schedules ExtractAppIntentsMetadata for Swift targets.
    # --force makes the tool skip the "no AppIntents.framework" warning when
    # the target does not use App Intents (same path as static Swift libs).
    set_property(TARGET ${target} PROPERTY
      XCODE_ATTRIBUTE_ENABLE_APP_INTENTS_METADATA_GENERATION NO)
    set_property(TARGET ${target} PROPERTY
      XCODE_ATTRIBUTE_LM_FORCE_LINK_GENERATION YES)
    target_compile_options(${target} PRIVATE
      "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-framework -Xfrontend AppIntents>")
  endif()
endfunction()

function(putty_macos_register_gui_app target)
  set_property(GLOBAL APPEND PROPERTY PUTTY_MACOS_GUI_APP_TARGETS ${target})
  # Keep PRODUCT_BUNDLE_IDENTIFIER in sync with the Info.plist CFBundleIdentifier
  # (MACOSX_BUNDLE_GUI_IDENTIFIER). Xcode warns when the build setting is empty.
  get_target_property(_putty_bundle_id ${target} MACOSX_BUNDLE_GUI_IDENTIFIER)
  if(_putty_bundle_id AND NOT _putty_bundle_id STREQUAL "_putty_bundle_id-NOTFOUND")
    set_property(TARGET ${target} PROPERTY
      XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${_putty_bundle_id}")
  endif()
  if(CMAKE_GENERATOR STREQUAL "Xcode")
    set_property(TARGET ${target} PROPERTY
      XCODE_ATTRIBUTE_ENABLE_APP_INTENTS_METADATA_GENERATION NO)
    set_property(TARGET ${target} PROPERTY
      XCODE_ATTRIBUTE_LM_FORCE_LINK_GENERATION YES)
  endif()
endfunction()

# ---------------------------------------------------------------------------
# Platform C libraries (non-GTK; paths under macos/platform/ and macos/utils/)
# ---------------------------------------------------------------------------

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/utils_sources.cmake)
add_sources_from_current_dir(utils ${PUTTY_MACOS_UTILS_SOURCES})

add_sources_from_current_dir(eventloop
  platform/cliloop.c
  platform/uxsel.c)

add_sources_from_current_dir(console
  platform/console.c)

add_sources_from_current_dir(settings
  platform/storage.c
  platform/paths.c
  platform/stubs.c)

add_library(macguifrontend STATIC
  platform/termwin.c
  platform/seat.c
  platform/seat-dialogs.m
  platform/eventloop-appkit.m
  platform/osxkeys.c
  platform/config-macos.c
  platform/config-appkit.m)
# Force ARC on .m sources. CMAKE_XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC alone
# does not always reach the clang command line for mixed C/OBJC static libs
# (see macos/app_crash_002.txt: dangling listItems without retain).
foreach(_putty_macos_objc_src
    platform/seat-dialogs.m
    platform/eventloop-appkit.m
    platform/config-appkit.m)
  set_source_files_properties(${_putty_macos_objc_src} PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
    XCODE_EXPLICIT_ENABLE_OBJC_ARC YES)
endforeach()
# be_list lives on the final app/bridge target (PuTTY vs pterm), not here.
target_link_libraries(macguifrontend PUBLIC
  guiterminal eventloop settings utils charset
  "-framework AppKit" "-framework Foundation"
  "-framework UniformTypeIdentifiers")
target_include_directories(macguifrontend PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/platform)
# config.c / dialog.c live in guiterminal; ensure licence.h is available.
add_dependencies(macguifrontend generated_licence_h)
set_target_properties(macguifrontend PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)

add_sources_from_current_dir(network
  platform/network.c
  platform/fd-socket.c
  platform/agent-socket.c
  platform/peerinfo.c
  platform/local-proxy.c
  platform/x11.c)

add_sources_from_current_dir(sshcommon
  platform/noise.c)

add_sources_from_current_dir(sshclient
  platform/gss.c
  platform/agent-client.c
  platform/sharing.c)

add_sources_from_current_dir(sshserver
  platform/sftpserver.c
  platform/procnet.c)

add_sources_from_current_dir(sftpclient
  platform/sftp.c)

add_sources_from_current_dir(otherbackends
  platform/serial.c)

add_sources_from_current_dir(agent
  platform/agent-client.c)

add_sources_from_current_dir(plink
  platform/unicode.c
  platform/no-gtk.c)

add_sources_from_current_dir(pscp
  platform/unicode.c
  platform/no-gtk.c)

add_sources_from_current_dir(psftp
  platform/unicode.c
  platform/no-gtk.c)

add_sources_from_current_dir(psocks
  platform/no-gtk.c)

add_sources_from_current_dir(test_conf
  platform/unicode.c
  platform/stubs/no-uxsel.c)

# ---------------------------------------------------------------------------
# CLI tools and helpers (non-GTK unix targets, adapted for macos/platform/)
# ---------------------------------------------------------------------------

add_executable(putty-mac-termwin-smoke-c
  platform/termwin-smoke-main.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  # eventloop/uxsel calls noise_ultralight; this smoke has no RNG/sshcommon.
  ${CMAKE_SOURCE_DIR}/stubs/no-rand.c
  platform/unicode.c
  platform/no-gtk.c)
be_list(putty-mac-termwin-smoke-c PuTTY)
# charset comes via macguifrontend; listing it again makes Apple ld warn.
target_link_libraries(putty-mac-termwin-smoke-c
  macguifrontend eventloop settings utils ${platform_libraries})

add_executable(putty-mac-seat-smoke-c
  platform/seat-smoke-main.c
  platform/seat-smoke-platform.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  platform/unicode.c
  platform/no-gtk.c)
be_list(putty-mac-seat-smoke-c PuTTY SSH SERIAL OTHERBACKENDS)
target_link_libraries(putty-mac-seat-smoke-c
  macguifrontend eventloop settings utils network crypto sshclient otherbackends
  ${platform_libraries})

add_executable(putty-mac-seat-output-smoke-c
  platform/seat-output-smoke-main.c
  platform/seat-smoke-platform.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  platform/unicode.c
  platform/no-gtk.c)
be_list(putty-mac-seat-output-smoke-c PuTTY SSH SERIAL OTHERBACKENDS)
target_link_libraries(putty-mac-seat-output-smoke-c
  macguifrontend eventloop settings utils network crypto sshclient otherbackends
  ${platform_libraries})

add_executable(putty-mac-seat-dialogs-smoke-c
  platform/seat-dialogs-smoke-main.c
  platform/seat-smoke-platform.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  platform/unicode.c
  platform/no-gtk.c)
be_list(putty-mac-seat-dialogs-smoke-c PuTTY SSH SERIAL OTHERBACKENDS)
target_link_libraries(putty-mac-seat-dialogs-smoke-c
  macguifrontend eventloop settings utils network crypto sshclient otherbackends
  ${platform_libraries})

add_executable(putty-mac-config-smoke-c
  platform/config-smoke-main.c
  platform/seat-smoke-platform.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  platform/unicode.c
  platform/no-gtk.c)
be_list(putty-mac-config-smoke-c PuTTY SSH SERIAL OTHERBACKENDS)
target_link_libraries(putty-mac-config-smoke-c
  macguifrontend eventloop settings utils network crypto sshclient otherbackends
  ${platform_libraries})

add_executable(test_lineedit
  ${CMAKE_SOURCE_DIR}/test/test_lineedit.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-logging.c
  ${CMAKE_SOURCE_DIR}/stubs/no-printing.c
  ${CMAKE_SOURCE_DIR}/stubs/no-storage.c
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  platform/unicode.c
  platform/no-gtk.c)
target_link_libraries(test_lineedit
  guiterminal settings eventloop utils ${platform_libraries})

add_executable(test_terminal
  ${CMAKE_SOURCE_DIR}/test/test_terminal.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-storage.c
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  ${CMAKE_SOURCE_DIR}/stubs/no-printing.c
  platform/unicode.c
  platform/no-gtk.c)
target_compile_definitions(test_terminal PRIVATE
  PUTTY_TEST_DATA_DIR="${CMAKE_SOURCE_DIR}/test")
target_link_libraries(test_terminal
  guiterminal settings eventloop utils ${platform_libraries})

add_executable(fuzzterm
  ${CMAKE_SOURCE_DIR}/test/fuzzterm.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  platform/unicode.c
  platform/no-gtk.c
  $<TARGET_OBJECTS:logging>)
be_list(fuzzterm FuZZterm)
add_dependencies(fuzzterm generated_licence_h)
# charset comes via utils; listing it again makes Apple ld warn.
target_link_libraries(fuzzterm
  guiterminal eventloop settings utils ${platform_libraries})

# Do not build unix/osxlaunch.c here. That helper is for GTK-on-Quartz /
# gtk-mac-bundler (unix/*.bundle) and must not be revived under
# PUTTY_MACOS_GUI (agents.mdc §3 / §11, AUDIT P1.6). The unix/ platform
# still builds osxlaunch when PUTTY_MACOS_GUI is OFF.

add_library(puttygen-common OBJECT
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  platform/keygen-noise.c
  platform/no-gtk.c
  platform/noise.c
  platform/paths.c
  platform/storage.c
  ${CMAKE_SOURCE_DIR}/sshpubk.c
  ${CMAKE_SOURCE_DIR}/sshrand.c)

add_executable(puttygen
  ${CMAKE_SOURCE_DIR}/cmdgen.c
  $<TARGET_OBJECTS:puttygen-common>)
target_link_libraries(puttygen keygen console crypto utils ${platform_libraries})
installed_program(puttygen)

add_executable(cgtest
  ${CMAKE_SOURCE_DIR}/cgtest.c
  $<TARGET_OBJECTS:puttygen-common>)
target_link_libraries(cgtest keygen console crypto utils ${platform_libraries})

if(HAVE_ALIGNED_ALLOC)
  add_library(overaligned_alloc OBJECT
    ${CMAKE_SOURCE_DIR}/utils/memory.c)
  target_compile_definitions(overaligned_alloc PRIVATE ALLOCATION_ALIGNMENT=128)
  add_executable(testsc
    ${CMAKE_SOURCE_DIR}/test/testsc.c
    $<TARGET_OBJECTS:overaligned_alloc>)
  target_link_libraries(testsc keygen crypto utils ${platform_libraries})
endif()

add_executable(testzlib
  ${CMAKE_SOURCE_DIR}/test/testzlib.c
  ${CMAKE_SOURCE_DIR}/ssh/zlib.c)
target_link_libraries(testzlib utils ${platform_libraries})

add_executable(psusan
  platform/psusan.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/ssh/scpserver.c
  platform/unicode.c
  platform/no-gtk.c
  platform/pty.c)
be_list(psusan psusan)
target_link_libraries(psusan
  eventloop sshserver keygen settings network crypto utils ${platform_libraries})
installed_program(psusan)

add_executable(uppity
  platform/uppity.c
  ${CMAKE_SOURCE_DIR}/ssh/scpserver.c
  platform/no-gtk.c
  platform/pty.c
  platform/unicode.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c)
be_list(uppity Uppity)
target_link_libraries(uppity
  eventloop sshserver keygen settings network crypto utils ${platform_libraries})

add_executable(pageant
  platform/pageant.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  platform/x11.c
  platform/noise.c
  ${CMAKE_SOURCE_DIR}/ssh/x11fwd.c
  ${CMAKE_SOURCE_DIR}/proxy/nosshproxy.c
  platform/askpass-appkit.m
  platform/no-gtk.c)
be_list(pageant Pageant)
target_link_libraries(pageant
  eventloop console agent settings network crypto utils
  "-framework AppKit" "-framework Foundation"
  ${platform_libraries})
set_source_files_properties(platform/askpass-appkit.m PROPERTIES
  COMPILE_FLAGS "-fobjc-arc"
  XCODE_EXPLICIT_ENABLE_OBJC_ARC YES)
set_target_properties(pageant PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)
installed_program(pageant)

# Phase 7.4: headless askpass smoke (PUTTY_ASKPASS_RESPONSE).
add_executable(putty-mac-askpass-smoke-c
  platform/askpass-smoke-main.c
  platform/askpass-appkit.m
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  platform/no-gtk.c)
target_link_libraries(putty-mac-askpass-smoke-c
  utils
  "-framework AppKit" "-framework Foundation"
  ${platform_libraries})
set_target_properties(putty-mac-askpass-smoke-c PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)

# Phase 9.4: remote-controlled printing pipe (CONF_printer → popen).
add_executable(putty-mac-printing-smoke-c
  platform/printing-smoke-main.c
  platform/printing.c
  platform/no-gtk.c)
target_link_libraries(putty-mac-printing-smoke-c
  utils
  ${platform_libraries})

# ---------------------------------------------------------------------------
# Swift / AppKit GUI (Phase 1+)
# ---------------------------------------------------------------------------

add_subdirectory(bridge)
add_subdirectory(PuttyMacUI)
add_subdirectory(PuTTY)
add_subdirectory(pterm)
add_subdirectory(puttygen)

# Phase 9.1: CTest + XCTest (after apps / PuttyMacUI exist).
add_subdirectory(tests)

get_property(_putty_macos_gui_apps GLOBAL PROPERTY PUTTY_MACOS_GUI_APP_TARGETS)
if(_putty_macos_gui_apps)
  # Phase 8.1: Contents/ layout, Info.plist keys, architecture-neutral Resources.
  set(_putty_macos_layout_commands)
  foreach(_putty_macos_gui_app ${_putty_macos_gui_apps})
    if(PUTTY_MACOS_UNIVERSAL AND PUTTY_MACOS_UNIVERSAL_ACTIVE)
      set(_putty_macos_layout_universal ON)
    else()
      set(_putty_macos_layout_universal OFF)
    endif()
    if(PUTTY_DOC_HAS_HTML)
      set(_putty_macos_layout_help ON)
    else()
      set(_putty_macos_layout_help OFF)
    endif()
    list(APPEND _putty_macos_layout_commands
      COMMAND ${CMAKE_COMMAND}
        -DAPP=$<TARGET_BUNDLE_DIR:${_putty_macos_gui_app}>
        -DREQUIRE_UNIVERSAL=${_putty_macos_layout_universal}
        -DREQUIRE_HELP=${_putty_macos_layout_help}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/verify_bundle_layout.cmake)
  endforeach()
  add_custom_target(verify-bundle-layout
    ${_putty_macos_layout_commands}
    DEPENDS ${_putty_macos_gui_apps}
    COMMENT "Verifying macOS GUI .app bundle layout"
    VERBATIM)

  if(PUTTY_MACOS_UNIVERSAL AND PUTTY_MACOS_UNIVERSAL_ACTIVE)
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
