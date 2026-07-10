# Run fuzzterm with a short stdin payload (Buildscr smoke).
if(NOT PUTTY_FUZZTERM)
  message(FATAL_ERROR "PUTTY_FUZZTERM not set")
endif()
execute_process(
  COMMAND ${CMAKE_COMMAND} -E echo "smoke test to catch easy crashes"
  COMMAND ${PUTTY_FUZZTERM}
  OUTPUT_QUIET
  ERROR_VARIABLE _fuzz_err
  RESULT_VARIABLE _fuzz_rc)
if(NOT _fuzz_rc EQUAL 0)
  message(FATAL_ERROR "fuzzterm smoke failed (${_fuzz_rc}): ${_fuzz_err}")
endif()
