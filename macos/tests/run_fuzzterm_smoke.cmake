# Run fuzzterm with short stdin plus in-tree terminal corpora (Buildscr smoke).
if(NOT PUTTY_FUZZTERM)
  message(FATAL_ERROR "PUTTY_FUZZTERM not set")
endif()
if(NOT PUTTY_TEST_DATA_DIR)
  message(FATAL_ERROR "PUTTY_TEST_DATA_DIR not set")
endif()

function(putty_run_fuzzterm_input label)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E echo "${label}"
    COMMAND ${PUTTY_FUZZTERM}
    OUTPUT_QUIET
    ERROR_VARIABLE _fuzz_err
    RESULT_VARIABLE _fuzz_rc)
  if(NOT _fuzz_rc EQUAL 0)
    message(FATAL_ERROR
      "fuzzterm smoke failed on '${label}' (${_fuzz_rc}): ${_fuzz_err}")
  endif()
endfunction()

function(putty_run_fuzzterm_file filepath)
  if(NOT EXISTS "${filepath}")
    message(FATAL_ERROR "fuzzterm corpus missing: ${filepath}")
  endif()
  execute_process(
    COMMAND ${PUTTY_FUZZTERM}
    INPUT_FILE "${filepath}"
    OUTPUT_QUIET
    ERROR_VARIABLE _fuzz_err
    RESULT_VARIABLE _fuzz_rc)
  if(NOT _fuzz_rc EQUAL 0)
    message(FATAL_ERROR
      "fuzzterm smoke failed on ${filepath} (${_fuzz_rc}): ${_fuzz_err}")
  endif()
endfunction()

putty_run_fuzzterm_input("smoke test to catch easy crashes")
foreach(_putty_fuzz_corpus
    vt100.txt lattrs.txt scocols.txt colours.txt utf8.txt
    coverage_escapes.txt)
  putty_run_fuzzterm_file("${PUTTY_TEST_DATA_DIR}/${_putty_fuzz_corpus}")
endforeach()
