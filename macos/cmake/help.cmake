# Bundle Halibut HTML help into macOS GUI .app Resources (Phase 9.5).
#
# Requires the top-level `doc/` subdirectory to have built HTML
# (`PUTTY_DOC_HAS_HTML` / `PUTTY_DOC_HTML_DIR` from doc/CMakeLists.txt).
# When Halibut is unavailable, apps still build; Help → … shows a fallback.

if(PUTTY_DOC_HAS_HTML AND PUTTY_DOC_HTML_DIR)
  set(PUTTY_MACOS_HELP_HTML_DIR ${PUTTY_DOC_HTML_DIR})
  add_custom_target(putty-macos-help-html
    DEPENDS ${PUTTY_MACOS_HELP_HTML_DIR}/index.html
    COMMENT "Halibut HTML help ready for .app bundling")
  message(STATUS "macOS help: bundling Halibut HTML from ${PUTTY_MACOS_HELP_HTML_DIR}")
else()
  set(PUTTY_MACOS_HELP_HTML_DIR "")
  message(STATUS
    "macOS help: Halibut HTML not available (install halibut + perl); "
    "Help menu will use online fallback")
endif()

# Copy staged HTML into Contents/Resources/Help after the .app is linked.
function(putty_macos_add_help app_target)
  if(NOT PUTTY_MACOS_HELP_HTML_DIR)
    return()
  endif()
  add_dependencies(${app_target} putty-macos-help-html)
  add_custom_command(TARGET ${app_target} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf
      "$<TARGET_BUNDLE_CONTENT_DIR:${app_target}>/Resources/Help"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${PUTTY_MACOS_HELP_HTML_DIR}"
      "$<TARGET_BUNDLE_CONTENT_DIR:${app_target}>/Resources/Help"
    COMMENT "Bundling Halibut HTML help into ${app_target}"
    VERBATIM)
endfunction()
