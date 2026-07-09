# macOS platform build (AppKit GUI).
#
# Phase 2.2: non-GTK platform C modules (mirrors unix/CMakeLists.txt).

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/icons.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/bundle_version.cmake)

# Swift language version is set once in the root CMakeLists.txt via
# CMAKE_Swift_LANGUAGE_VERSION (before/at project()). Do not also set the
# per-target Swift_LANGUAGE_VERSION property: with the Xcode generator that
# injects a redundant -swift-version into OTHER_SWIFT_FLAGS and triggers
# "language mode was overridden by extra Swift flags".

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
endfunction()

function(putty_macos_register_gui_app target)
  set_property(GLOBAL APPEND PROPERTY PUTTY_MACOS_GUI_APP_TARGETS ${target})
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
# be_list lives on the final app/bridge target (PuTTY vs pterm), not here.
target_link_libraries(macguifrontend PUBLIC
  guiterminal eventloop settings utils charset
  "-framework AppKit" "-framework Foundation"
  "-framework UniformTypeIdentifiers")
target_include_directories(macguifrontend PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/platform)
# config.c / dialog.c live in guiterminal; ensure licence.h is available.
add_dependencies(macguifrontend generated_licence_h)

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
target_link_libraries(putty-mac-termwin-smoke-c
  macguifrontend eventloop charset settings utils)

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
  macguifrontend eventloop charset settings utils network crypto sshclient otherbackends)

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
  macguifrontend eventloop charset settings utils network crypto sshclient otherbackends)

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
  macguifrontend eventloop charset settings utils network crypto sshclient otherbackends)

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
  macguifrontend eventloop charset settings utils network crypto sshclient otherbackends)

add_executable(test_terminal
  ${CMAKE_SOURCE_DIR}/test/test_terminal.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/stubs/no-storage.c
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  ${CMAKE_SOURCE_DIR}/stubs/no-printing.c
  platform/unicode.c
  platform/no-gtk.c)
target_link_libraries(test_terminal
  guiterminal settings eventloop utils)

add_executable(fuzzterm
  ${CMAKE_SOURCE_DIR}/test/fuzzterm.c
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c
  platform/unicode.c
  platform/no-gtk.c
  $<TARGET_OBJECTS:logging>)
be_list(fuzzterm FuZZterm)
add_dependencies(fuzzterm generated_licence_h)
target_link_libraries(fuzzterm
  guiterminal eventloop charset settings utils)

add_executable(osxlaunch
  platform/osxlaunch.c)

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
target_link_libraries(puttygen keygen console crypto utils)
installed_program(puttygen)

add_executable(cgtest
  ${CMAKE_SOURCE_DIR}/cgtest.c
  $<TARGET_OBJECTS:puttygen-common>)
target_link_libraries(cgtest keygen console crypto utils)

if(HAVE_ALIGNED_ALLOC)
  add_library(overaligned_alloc OBJECT
    ${CMAKE_SOURCE_DIR}/utils/memory.c)
  target_compile_definitions(overaligned_alloc PRIVATE ALLOCATION_ALIGNMENT=128)
  add_executable(testsc
    ${CMAKE_SOURCE_DIR}/test/testsc.c
    $<TARGET_OBJECTS:overaligned_alloc>)
  target_link_libraries(testsc keygen crypto utils)
endif()

add_executable(testzlib
  ${CMAKE_SOURCE_DIR}/test/testzlib.c
  ${CMAKE_SOURCE_DIR}/ssh/zlib.c)
target_link_libraries(testzlib utils)

add_executable(psusan
  platform/psusan.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/ssh/scpserver.c
  platform/unicode.c
  platform/no-gtk.c
  platform/pty.c)
be_list(psusan psusan)
target_link_libraries(psusan
  eventloop sshserver keygen settings network crypto utils)
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
  eventloop sshserver keygen settings network crypto utils)

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
  "-framework AppKit" "-framework Foundation")
installed_program(pageant)

# Phase 7.4: headless askpass smoke (PUTTY_ASKPASS_RESPONSE).
add_executable(putty-mac-askpass-smoke-c
  platform/askpass-smoke-main.c
  platform/askpass-appkit.m
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  platform/no-gtk.c)
target_link_libraries(putty-mac-askpass-smoke-c
  utils
  "-framework AppKit" "-framework Foundation")

# ---------------------------------------------------------------------------
# Swift / AppKit GUI (Phase 1+)
# ---------------------------------------------------------------------------

add_subdirectory(bridge)
add_subdirectory(PuttyMacUI)
add_subdirectory(PuTTY)
add_subdirectory(pterm)
add_subdirectory(puttygen)

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
    list(APPEND _putty_macos_layout_commands
      COMMAND ${CMAKE_COMMAND}
        -DAPP=$<TARGET_BUNDLE_DIR:${_putty_macos_gui_app}>
        -DREQUIRE_UNIVERSAL=${_putty_macos_layout_universal}
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
