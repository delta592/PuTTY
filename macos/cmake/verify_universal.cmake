# Verify that a GUI .app executable contains Universal 2 slices.
#
# Usage: cmake -DEXE=/path/to/PuTTY.app/Contents/MacOS/PuTTY -P verify_universal.cmake

if(NOT EXE)
  message(FATAL_ERROR "verify_universal.cmake requires -DEXE=<path to Mach-O>")
endif()

if(NOT EXISTS "${EXE}")
  message(FATAL_ERROR "verify_universal.cmake: executable not found: ${EXE}")
endif()

execute_process(
  COMMAND lipo -info "${EXE}"
  OUTPUT_VARIABLE lipo_out
  ERROR_VARIABLE lipo_err
  RESULT_VARIABLE lipo_result
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_STRIP_TRAILING_WHITESPACE)

if(NOT lipo_result EQUAL 0)
  message(FATAL_ERROR
    "lipo -info failed for ${EXE}: ${lipo_err}")
endif()

if(NOT lipo_out MATCHES "arm64")
  message(FATAL_ERROR
    "${EXE} is not Universal 2: missing arm64 slice (lipo: ${lipo_out})")
endif()

if(NOT lipo_out MATCHES "x86_64")
  message(FATAL_ERROR
    "${EXE} is not Universal 2: missing x86_64 slice (lipo: ${lipo_out})")
endif()

message(STATUS "Verified Universal 2 binary: ${EXE} (${lipo_out})")
