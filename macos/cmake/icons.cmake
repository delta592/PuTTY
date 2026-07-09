# Icon and asset generation for macOS GUI .app bundles (Phase 1.5).

find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(PUTTY_MACOS_ICON_GEN_DIR ${CMAKE_BINARY_DIR}/macos-icons)
file(MAKE_DIRECTORY ${PUTTY_MACOS_ICON_GEN_DIR})

function(putty_macos_generate_pam icon_base size output_pam mono)
  if(mono)
    set(mkicon_flags -2)
  else()
    set(mkicon_flags)
  endif()

  add_custom_command(
    OUTPUT ${output_pam}
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_SOURCE_DIR}/icons/mkicon.py
      ${mkicon_flags}
      ${icon_base}_icon
      ${size}
      ${output_pam}
    DEPENDS
      ${CMAKE_SOURCE_DIR}/icons/mkicon.py
    COMMENT "Generating ${output_pam}"
    VERBATIM)
endfunction()

function(putty_macos_generate_icns icns_filename icon_base)
  set(icon_dir ${PUTTY_MACOS_ICON_GEN_DIR})
  set(pam_mono_16 ${icon_dir}/${icon_base}-16-mono.pam)
  set(pam_colour_16 ${icon_dir}/${icon_base}-16.pam)
  set(pam_mono_32 ${icon_dir}/${icon_base}-32-mono.pam)
  set(pam_colour_32 ${icon_dir}/${icon_base}-32.pam)
  set(pam_mono_48 ${icon_dir}/${icon_base}-48-mono.pam)
  set(pam_colour_48 ${icon_dir}/${icon_base}-48.pam)
  set(pam_colour_128 ${icon_dir}/${icon_base}-128.pam)
  set(icns_path ${icon_dir}/${icns_filename})

  putty_macos_generate_pam(${icon_base} 16 ${pam_mono_16} MONO)
  putty_macos_generate_pam(${icon_base} 16 ${pam_colour_16} OFF)
  putty_macos_generate_pam(${icon_base} 32 ${pam_mono_32} MONO)
  putty_macos_generate_pam(${icon_base} 32 ${pam_colour_32} OFF)
  putty_macos_generate_pam(${icon_base} 48 ${pam_mono_48} MONO)
  putty_macos_generate_pam(${icon_base} 48 ${pam_colour_48} OFF)
  putty_macos_generate_pam(${icon_base} 128 ${pam_colour_128} OFF)

  add_custom_command(
    OUTPUT ${icns_path}
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_SOURCE_DIR}/icons/macicon.py
      mono:${pam_mono_16}
      colour:${pam_colour_16}
      mono:${pam_mono_32}
      colour:${pam_colour_32}
      mono:${pam_mono_48}
      colour:${pam_colour_48}
      colour:${pam_colour_128}
      output:${icns_path}
    DEPENDS
      ${pam_mono_16}
      ${pam_colour_16}
      ${pam_mono_32}
      ${pam_colour_32}
      ${pam_mono_48}
      ${pam_colour_48}
      ${pam_colour_128}
      ${CMAKE_SOURCE_DIR}/icons/macicon.py
    COMMENT "Generating ${icns_filename}"
    VERBATIM)
endfunction()

putty_macos_generate_icns(PuTTY.icns putty)
putty_macos_generate_icns(Pterm.icns pterm)
putty_macos_generate_icns(Puttygen.icns puttygen)

set(PUTTY_MACOS_PUTTY_ICNS ${PUTTY_MACOS_ICON_GEN_DIR}/PuTTY.icns)
set(PUTTY_MACOS_PTERM_ICNS ${PUTTY_MACOS_ICON_GEN_DIR}/Pterm.icns)
set(PUTTY_MACOS_PUTTYGEN_ICNS ${PUTTY_MACOS_ICON_GEN_DIR}/Puttygen.icns)

# Toolbar template PNG for Assets.xcassets (derived from the mono 32px icon).
set(PUTTY_MACOS_TOOLBAR_PNG ${PUTTY_MACOS_ICON_GEN_DIR}/putty-toolbar-template.png)
add_custom_command(
  OUTPUT ${PUTTY_MACOS_TOOLBAR_PNG}
  COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/pam_to_png.py
    ${PUTTY_MACOS_ICON_GEN_DIR}/putty-32-mono.pam
    ${PUTTY_MACOS_TOOLBAR_PNG}
  DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/pam_to_png.py
    ${PUTTY_MACOS_ICON_GEN_DIR}/putty-32-mono.pam
  COMMENT "Generating toolbar template PNG"
  VERBATIM)

add_custom_target(putty-macos-icons
  DEPENDS
    ${PUTTY_MACOS_PUTTY_ICNS}
    ${PUTTY_MACOS_PTERM_ICNS}
    ${PUTTY_MACOS_PUTTYGEN_ICNS}
    ${PUTTY_MACOS_TOOLBAR_PNG})

# Compile shared Assets.xcassets (accent colours + toolbar template) into the
# build tree so app targets can bundle Assets.car.
set(PUTTY_MACOS_ASSETS_CAR ${CMAKE_BINARY_DIR}/macos-assets/Assets.car)
set(PUTTY_MACOS_ASSETS_XCASSETS
  ${CMAKE_CURRENT_SOURCE_DIR}/Resources/Assets.xcassets)

add_custom_command(
  OUTPUT ${PUTTY_MACOS_ASSETS_CAR}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/macos-assets
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${PUTTY_MACOS_ASSETS_XCASSETS}
    ${CMAKE_BINARY_DIR}/macos-assets/Assets.xcassets
  COMMAND ${CMAKE_COMMAND} -E copy
    ${PUTTY_MACOS_TOOLBAR_PNG}
    ${CMAKE_BINARY_DIR}/macos-assets/Assets.xcassets/ToolbarTemplate.imageset/toolbar-template.png
  COMMAND xcrun actool
    ${CMAKE_BINARY_DIR}/macos-assets/Assets.xcassets
    --compile ${CMAKE_BINARY_DIR}/macos-assets
    --platform macosx
    --minimum-deployment-target ${CMAKE_OSX_DEPLOYMENT_TARGET}
    --output-partial-info-plist ${CMAKE_BINARY_DIR}/macos-assets/partial-info.plist
  DEPENDS
    putty-macos-icons
    ${PUTTY_MACOS_ASSETS_XCASSETS}/Contents.json
    ${PUTTY_MACOS_ASSETS_XCASSETS}/AccentColor.colorset/Contents.json
    ${PUTTY_MACOS_ASSETS_XCASSETS}/ChromeBackground.colorset/Contents.json
    ${PUTTY_MACOS_ASSETS_XCASSETS}/ToolbarTemplate.imageset/Contents.json
  COMMENT "Compiling Assets.xcassets"
  VERBATIM)

add_custom_target(putty-macos-assets DEPENDS ${PUTTY_MACOS_ASSETS_CAR})

# Architecture-neutral localization stub (Phase 8.1). Stage a copy whose
# path does *not* contain "en.lproj" — Xcode's CpResource nests
# Resources/en.lproj/en.lproj when the source path already ends in en.lproj.
set(PUTTY_MACOS_EN_LPROJ_STRINGS_SRC
  ${CMAKE_CURRENT_SOURCE_DIR}/Resources/en.lproj/InfoPlist.strings)
set(PUTTY_MACOS_EN_LPROJ_STRINGS
  ${CMAKE_BINARY_DIR}/macos-bundle-resources/InfoPlist.strings)

add_custom_command(
  OUTPUT ${PUTTY_MACOS_EN_LPROJ_STRINGS}
  COMMAND ${CMAKE_COMMAND} -E make_directory
    ${CMAKE_BINARY_DIR}/macos-bundle-resources
  COMMAND ${CMAKE_COMMAND} -E copy
    ${PUTTY_MACOS_EN_LPROJ_STRINGS_SRC}
    ${PUTTY_MACOS_EN_LPROJ_STRINGS}
  DEPENDS ${PUTTY_MACOS_EN_LPROJ_STRINGS_SRC}
  COMMENT "Staging en.lproj InfoPlist.strings for app bundles"
  VERBATIM)

add_custom_target(putty-macos-lproj DEPENDS ${PUTTY_MACOS_EN_LPROJ_STRINGS})

function(putty_macos_add_app_resources app_target icns_filename)
  if(icns_filename STREQUAL "PuTTY.icns")
    set(icns_path ${PUTTY_MACOS_PUTTY_ICNS})
  elseif(icns_filename STREQUAL "Pterm.icns")
    set(icns_path ${PUTTY_MACOS_PTERM_ICNS})
  elseif(icns_filename STREQUAL "Puttygen.icns")
    set(icns_path ${PUTTY_MACOS_PUTTYGEN_ICNS})
  else()
    message(FATAL_ERROR "Unknown macOS icns filename: ${icns_filename}")
  endif()

  target_sources(${app_target} PRIVATE
    ${icns_path}
    ${PUTTY_MACOS_ASSETS_CAR}
    ${PUTTY_MACOS_EN_LPROJ_STRINGS})

  set_source_files_properties(${icns_path} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources
    GENERATED TRUE)

  set_source_files_properties(${PUTTY_MACOS_ASSETS_CAR} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources
    GENERATED TRUE)

  set_source_files_properties(${PUTTY_MACOS_EN_LPROJ_STRINGS} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources/en.lproj
    GENERATED TRUE)

  add_dependencies(${app_target}
    putty-macos-icons putty-macos-assets putty-macos-lproj)
endfunction()
