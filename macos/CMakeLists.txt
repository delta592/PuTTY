# macOS platform build (AppKit GUI).
#
# Phase 2.2: non-GTK platform C modules (mirrors unix/CMakeLists.txt).

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/icons.cmake)

# Swift / Objective-C toolchain (Phase 1.3; languages enabled at project()).
set(CMAKE_Swift_LANGUAGE_VERSION 6)

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
  platform/stubs.c
  platform/gui-seat-list.c)

add_library(macguifrontend STATIC
  platform/termwin.c
  platform/osxkeys.c)
be_list(macguifrontend PuTTY)
target_link_libraries(macguifrontend PUBLIC
  guiterminal eventloop settings utils charset)
target_include_directories(macguifrontend PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/platform)

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
  platform/unicode.c
  platform/no-gtk.c)
target_link_libraries(putty-mac-termwin-smoke-c
  macguifrontend eventloop charset settings utils)

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
  platform/noaskpass.c
  platform/no-gtk.c)
be_list(pageant Pageant)
target_link_libraries(pageant
  eventloop console agent settings network crypto utils)
installed_program(pageant)

# ---------------------------------------------------------------------------
# Swift / AppKit GUI (Phase 1+)
# ---------------------------------------------------------------------------

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
