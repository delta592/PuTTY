# PuttyMacUI — shared Swift terminal / session UI (Phase 7.5).
#
# Linked by PuTTY.app and pterm.app. Inherits CMAKE_OSX_ARCHITECTURES
# (Universal 2 when PUTTY_MACOS_UNIVERSAL_ACTIVE). puttygen stays separate.

add_library(putty-macui STATIC
  PuttyAccessibility.swift
  PuttyChrome.swift
  PuttyStandardMenus.swift
  PuttyConfHandle.swift
  PuttyEventLoop.swift
  PuttyHelp.swift
  HelpWindowController.swift
  SessionWindowController.swift
  SessionSpecialsMenu.swift
  SessionEventLog.swift
  EventLogWindowController.swift
  TerminalView.swift
  TerminalTextRenderer.swift
  TerminalFontCache.swift
  TerminalPaletteCache.swift
  OsxKeys.swift
  TerminalClipboard.swift
  TerminalScrollContainer.swift
  TerminalScrollInput.swift
  TerminalWindowChrome.swift
  TerminalPrint.swift)

set_target_properties(putty-macui PROPERTIES
  Swift_MODULE_NAME PuttyMacUI
  Swift_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
  # Xcode derives PRODUCT_MODULE_NAME from the target name (putty_macui)
  # unless overridden; consumers import PuttyMacUI.
  XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME PuttyMacUI)

target_compile_options(putty-macui PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(putty-macui PUBLIC
  "-framework AppKit"
  "-framework CoreText"
  "-framework CoreGraphics"
  "-framework Foundation"
  "-framework WebKit")

# Clang module map for import PuttyBridge (implementation linked by apps).
target_include_directories(putty-macui PUBLIC
  ${PUTTY_MACOS_PUTTYBRIDGE_MODULE_DIR})

# Consumers need the PuttyMacUI .swiftmodule next to the static archive.
set(PUTTY_MACOS_PUTTYMACUI_MODULE_DIR
  ${CMAKE_CURRENT_BINARY_DIR}
  CACHE INTERNAL "PuttyMacUI Swift module directory")

# PuttyBridge is a clang module; the concrete C bridge (putty-macos-bridge or
# pterm-macos-bridge) is linked by each app target.
putty_macos_configure_swift_target(putty-macui)

# Phase 4.4 full Swift CoreText paint benchmark (links PuttyMacUI renderer).
add_executable(PuttyBridgeTermPerfTest
  ${CMAKE_CURRENT_SOURCE_DIR}/../bridge/PuttyBridgeTermPerfTest.swift)

# Required for @main with a single-file executable under Ninja; harmless on Xcode.
target_compile_options(PuttyBridgeTermPerfTest PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")

target_link_libraries(PuttyBridgeTermPerfTest PRIVATE
  "-framework AppKit"
  putty-macui
  putty-macos-bridge)

putty_macos_configure_swift_target(PuttyBridgeTermPerfTest)

if(TARGET putty-mac-termwin-gate)
  add_dependencies(putty-mac-termwin-gate PuttyBridgeTermPerfTest)
endif()
