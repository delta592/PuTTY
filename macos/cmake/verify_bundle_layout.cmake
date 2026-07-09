# Verify a macOS GUI .app has the Phase 8.1 Contents layout.
#
# Usage:
#   cmake -DAPP=/path/to/PuTTY.app [-DREQUIRE_UNIVERSAL=ON] -P verify_bundle_layout.cmake

if(NOT APP)
  message(FATAL_ERROR "verify_bundle_layout.cmake requires -DAPP=<path to .app>")
endif()

if(NOT IS_DIRECTORY "${APP}")
  message(FATAL_ERROR "verify_bundle_layout.cmake: not a directory: ${APP}")
endif()

get_filename_component(_app_name "${APP}" NAME)
string(REGEX REPLACE "\\.app$" "" _app_base "${_app_name}")

set(_contents "${APP}/Contents")
set(_macos_dir "${_contents}/MacOS")
set(_resources "${_contents}/Resources")
set(_info_plist "${_contents}/Info.plist")

foreach(_required_path ${_contents} ${_macos_dir} ${_resources} ${_info_plist})
  if(NOT EXISTS "${_required_path}")
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: missing ${_required_path}")
  endif()
endforeach()

# Prefer the CFBundleExecutable name; fall back to the .app basename.
set(_exe_name "${_app_base}")
execute_process(
  COMMAND /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${_info_plist}"
  OUTPUT_VARIABLE _plist_exe
  ERROR_QUIET
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _plist_exe_status)
if(_plist_exe_status EQUAL 0 AND NOT _plist_exe STREQUAL "")
  set(_exe_name "${_plist_exe}")
endif()

set(_exe "${_macos_dir}/${_exe_name}")
if(NOT EXISTS "${_exe}")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: missing executable ${_exe}")
endif()

# Required Info.plist keys for AppKit GUI apps.
foreach(_key CFBundleIdentifier CFBundleExecutable CFBundleName
             CFBundleShortVersionString CFBundleVersion NSPrincipalClass
             LSMinimumSystemVersion)
  execute_process(
    COMMAND /usr/libexec/PlistBuddy -c "Print :${_key}" "${_info_plist}"
    OUTPUT_VARIABLE _key_value
    ERROR_VARIABLE _key_err
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _key_status)
  if(NOT _key_status EQUAL 0 OR _key_value STREQUAL "")
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: Info.plist missing or empty ${_key} "
      "in ${_info_plist}: ${_key_err}")
  endif()
endforeach()

execute_process(
  COMMAND /usr/libexec/PlistBuddy -c "Print :NSPrincipalClass" "${_info_plist}"
  OUTPUT_VARIABLE _principal
  OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _principal STREQUAL "NSApplication")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: NSPrincipalClass must be NSApplication "
    "(got '${_principal}')")
endif()

# Architecture-neutral Resources: .icns, Assets.car, en.lproj.
file(GLOB _icns_files "${_resources}/*.icns")
if(NOT _icns_files)
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: no .icns in ${_resources}")
endif()

if(NOT EXISTS "${_resources}/Assets.car")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: missing Assets.car in ${_resources}")
endif()

if(NOT IS_DIRECTORY "${_resources}/en.lproj")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: missing en.lproj in ${_resources}")
endif()

if(NOT EXISTS "${_resources}/en.lproj/InfoPlist.strings")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: missing en.lproj/InfoPlist.strings "
    "(nested en.lproj/en.lproj is incorrect)")
endif()

if(IS_DIRECTORY "${_resources}/en.lproj/en.lproj")
  message(FATAL_ERROR
    "verify_bundle_layout.cmake: nested en.lproj/en.lproj in ${_resources}")
endif()

# Resources must not contain Mach-O binaries (architecture-neutral check).
file(GLOB_RECURSE _resource_files LIST_DIRECTORIES false "${_resources}/*")
foreach(_res ${_resource_files})
  execute_process(
    COMMAND /usr/bin/file -b "${_res}"
    OUTPUT_VARIABLE _file_type
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(_file_type MATCHES "Mach-O")
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: Resources must be architecture-neutral; "
      "found Mach-O at ${_res} (${_file_type})")
  endif()
endforeach()

# Optional Universal 2 check (same rules as verify_universal.cmake).
if(REQUIRE_UNIVERSAL)
  execute_process(
    COMMAND lipo -info "${_exe}"
    OUTPUT_VARIABLE _lipo_out
    ERROR_VARIABLE _lipo_err
    RESULT_VARIABLE _lipo_result
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE)
  if(NOT _lipo_result EQUAL 0)
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: lipo -info failed for ${_exe}: ${_lipo_err}")
  endif()
  if(NOT _lipo_out MATCHES "arm64")
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: ${_exe} missing arm64 (${_lipo_out})")
  endif()
  if(NOT _lipo_out MATCHES "x86_64")
    message(FATAL_ERROR
      "verify_bundle_layout.cmake: ${_exe} missing x86_64 (${_lipo_out})")
  endif()
  message(STATUS "Universal 2 OK: ${_exe} (${_lipo_out})")
endif()

message(STATUS "Verified bundle layout: ${APP}")
