# Derive CFBundleShortVersionString / CFBundleVersion for macOS .app bundles
# (Phase 8.1).
#
# Preference order for the marketing version (CFBundleShortVersionString):
#   1. #define RELEASE / PRERELEASE in version.h (official Buildscr stamps)
#   2. BINARY_VERSION from version.h when not the local-dev placeholder 0,0,0,0
#   3. LATEST.VER in the source tree
#   4. Leading X.Y from `git describe --tags`
#   5. Fallback "0.0.0"
#
# CFBundleVersion prefers git describe (when available) so successive local
# builds remain distinguishable; release/prerelease stamps use the marketing
# version alone.

set(_putty_macos_version_h "${CMAKE_SOURCE_DIR}/version.h")
set(_putty_macos_latest_ver "${CMAKE_SOURCE_DIR}/LATEST.VER")

set(_putty_macos_short_version "")
set(_putty_macos_bundle_version "")

if(EXISTS "${_putty_macos_version_h}")
  file(READ "${_putty_macos_version_h}" _putty_macos_version_h_contents)

  if(_putty_macos_version_h_contents MATCHES
      "#define[ \t]+RELEASE[ \t]+([0-9]+\\.[0-9]+)")
    set(_putty_macos_short_version "${CMAKE_MATCH_1}")
  elseif(_putty_macos_version_h_contents MATCHES
      "#define[ \t]+PRERELEASE[ \t]+([0-9]+\\.[0-9]+)")
    set(_putty_macos_short_version "${CMAKE_MATCH_1}")
  elseif(_putty_macos_version_h_contents MATCHES
      "#define[ \t]+BINARY_VERSION[ \t]+([0-9]+),([0-9]+),([0-9]+),([0-9]+)")
    set(_bv_a "${CMAKE_MATCH_1}")
    set(_bv_b "${CMAKE_MATCH_2}")
    set(_bv_c "${CMAKE_MATCH_3}")
    set(_bv_d "${CMAKE_MATCH_4}")
    if(NOT ("${_bv_a},${_bv_b},${_bv_c},${_bv_d}" STREQUAL "0,0,0,0"))
      if(_bv_c STREQUAL "0" AND _bv_d STREQUAL "0")
        set(_putty_macos_short_version "${_bv_a}.${_bv_b}")
      else()
        set(_putty_macos_short_version "${_bv_a}.${_bv_b}.${_bv_c}")
      endif()
    endif()
  endif()
endif()

if(_putty_macos_short_version STREQUAL "" AND EXISTS "${_putty_macos_latest_ver}")
  file(READ "${_putty_macos_latest_ver}" _putty_macos_latest_ver_contents)
  string(STRIP "${_putty_macos_latest_ver_contents}" _putty_macos_latest_ver_contents)
  if(_putty_macos_latest_ver_contents MATCHES "^[0-9]+\\.[0-9]+")
    set(_putty_macos_short_version "${_putty_macos_latest_ver_contents}")
  endif()
endif()

set(_putty_macos_git_describe "")
if(GIT_EXECUTABLE)
  execute_process(
    COMMAND ${GIT_EXECUTABLE} describe --tags --always --dirty
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE _putty_macos_git_describe
    ERROR_QUIET
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _putty_macos_git_describe_status)
  if(NOT _putty_macos_git_describe_status EQUAL 0)
    set(_putty_macos_git_describe "")
  endif()
endif()

if(_putty_macos_short_version STREQUAL "" AND
   NOT _putty_macos_git_describe STREQUAL "")
  if(_putty_macos_git_describe MATCHES "^([0-9]+\\.[0-9]+)")
    set(_putty_macos_short_version "${CMAKE_MATCH_1}")
  endif()
endif()

if(_putty_macos_short_version STREQUAL "")
  set(_putty_macos_short_version "0.0.0")
endif()

if(NOT _putty_macos_git_describe STREQUAL "")
  # CFBundleVersion must be a period-separated integer string on the App Store;
  # for Developer ID / local builds Apple accepts broader strings. Prefer the
  # git describe form so Info.plist tracks the exact source revision.
  set(_putty_macos_bundle_version "${_putty_macos_git_describe}")
else()
  set(_putty_macos_bundle_version "${_putty_macos_short_version}")
endif()

set(PUTTY_MACOS_BUNDLE_SHORT_VERSION "${_putty_macos_short_version}"
  CACHE INTERNAL "CFBundleShortVersionString for macOS GUI apps" FORCE)
set(PUTTY_MACOS_BUNDLE_VERSION "${_putty_macos_bundle_version}"
  CACHE INTERNAL "CFBundleVersion for macOS GUI apps" FORCE)

message(STATUS
  "macOS app bundle version: "
  "CFBundleShortVersionString=${PUTTY_MACOS_BUNDLE_SHORT_VERSION} "
  "CFBundleVersion=${PUTTY_MACOS_BUNDLE_VERSION}")
