# Early macOS GUI toolchain setup — must run before project() so Swift
# sees CMAKE_OSX_ARCHITECTURES (Phase 1.7).

set(PUTTY_MACOS_UNIVERSAL ON
  CACHE BOOL "Build Universal 2 GUI binaries (arm64 + x86_64 slices)")

if(PUTTY_MACOS_UNIVERSAL)
  if(CMAKE_GENERATOR MATCHES "Xcode")
    set(_putty_macos_architectures "arm64;x86_64")
    set(PUTTY_MACOS_UNIVERSAL_ACTIVE TRUE)
  else()
    # Swift does not support multi-value CMAKE_OSX_ARCHITECTURES with the
    # Ninja (or Makefile) generators; Universal 2 release builds use Xcode.
    message(WARNING
      "PUTTY_MACOS_UNIVERSAL=ON requires the Xcode generator (-G Xcode) "
      "for a Universal 2 Swift build. With ${CMAKE_GENERATOR}, building "
      "${CMAKE_HOST_SYSTEM_PROCESSOR} only. Use -DPUTTY_MACOS_UNIVERSAL=OFF "
      "for intentional single-arch Ninja builds.")
    set(_putty_macos_architectures "${CMAKE_HOST_SYSTEM_PROCESSOR}")
    set(PUTTY_MACOS_UNIVERSAL_ACTIVE FALSE)
  endif()
else()
  # Prefer an explicit -DCMAKE_OSX_ARCHITECTURES=... (CodeQL CI forces
  # arm64). Otherwise use the host arch; fall back to uname -m if the host
  # processor is not set yet (seen with some generators before project()).
  if(CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "")
    set(_putty_macos_architectures "${CMAKE_OSX_ARCHITECTURES}")
  elseif(CMAKE_HOST_SYSTEM_PROCESSOR AND
         NOT CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "")
    set(_putty_macos_architectures "${CMAKE_HOST_SYSTEM_PROCESSOR}")
  else()
    execute_process(
      COMMAND uname -m
      OUTPUT_VARIABLE _putty_macos_architectures
      OUTPUT_STRIP_TRAILING_WHITESPACE)
  endif()
  set(PUTTY_MACOS_UNIVERSAL_ACTIVE FALSE)
endif()

set(CMAKE_OSX_ARCHITECTURES "${_putty_macos_architectures}"
  CACHE STRING "Build architectures for macOS binaries" FORCE)
message(STATUS
  "macOS architectures: ${CMAKE_OSX_ARCHITECTURES}"
  " (universal=${PUTTY_MACOS_UNIVERSAL_ACTIVE})")

if(CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0"
    CACHE STRING "Minimum macOS version" FORCE)
endif()
