set(_putty_app_version "0.0.0")

# Generate Info.plist at configure time. Ninja does not expand Xcode-style
# $(EXECUTABLE_NAME) placeholders; CMake configure_file uses ${VAR} syntax
# (see Modules/MacOSXBundleInfo.plist.in).
set(MACOSX_BUNDLE_EXECUTABLE_NAME PuTTY)
set(MACOSX_BUNDLE_BUNDLE_NAME PuTTY)
set(MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.macputty)
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${_putty_app_version})
set(MACOSX_BUNDLE_BUNDLE_VERSION ${_putty_app_version})

configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
  ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  NEWLINE_STYLE UNIX)

add_executable(PuTTY MACOSX_BUNDLE
  PuTTYApp.swift
  TerminalView.swift)

set_target_properties(PuTTY PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.macputty
  MACOSX_BUNDLE_BUNDLE_NAME PuTTY
  MACOSX_BUNDLE_BUNDLE_VERSION ${_putty_app_version}
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${_putty_app_version})

target_compile_options(PuTTY PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(PuTTY PRIVATE
  "-framework AppKit"
  putty-macos-bridge
  macguifrontend
  guiterminal eventloop sshclient otherbackends settings network crypto utils)

putty_macos_configure_swift_target(PuTTY)
putty_macos_add_app_resources(PuTTY PuTTY.icns)
putty_macos_register_gui_app(PuTTY)
installed_program(PuTTY)
