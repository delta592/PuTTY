add_executable(PuTTY MACOSX_BUNDLE
  PuTTYApp.swift)

set_target_properties(PuTTY PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
  MACOSX_BUNDLE_GUI_IDENTIFIER org.tartarus.projects.putty.macputty
  MACOSX_BUNDLE_BUNDLE_NAME PuTTY
  MACOSX_BUNDLE_BUNDLE_VERSION "0.0.0"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "0.0.0")

target_link_libraries(PuTTY PRIVATE
  "-framework AppKit"
  putty-macos-bridge
  guiterminal eventloop sshclient otherbackends settings network crypto utils)

putty_macos_configure_swift_target(PuTTY)
putty_macos_add_app_resources(PuTTY PuTTY.icns)
