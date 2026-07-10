# Forcibly re-enable assertions, even if we're building in release
# mode. This is a security project - assertions may be enforcing
# security-critical constraints. A backstop #ifdef in defs.h should
# give a #error if this manoeuvre doesn't do what it needs to.
string(REPLACE "/DNDEBUG" "" CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
string(REPLACE "-DNDEBUG" "" CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
string(REPLACE "/DNDEBUG" "" CMAKE_C_FLAGS_RELWITHDEBINFO "${CMAKE_C_FLAGS_RELWITHDEBINFO}")
string(REPLACE "-DNDEBUG" "" CMAKE_C_FLAGS_RELWITHDEBINFO "${CMAKE_C_FLAGS_RELWITHDEBINFO}")
string(REPLACE "/DNDEBUG" "" CMAKE_OBJC_FLAGS_RELEASE "${CMAKE_OBJC_FLAGS_RELEASE}")
string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_RELEASE "${CMAKE_OBJC_FLAGS_RELEASE}")
string(REPLACE "/DNDEBUG" "" CMAKE_OBJC_FLAGS_RELWITHDEBINFO "${CMAKE_OBJC_FLAGS_RELWITHDEBINFO}")
string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_RELWITHDEBINFO "${CMAKE_OBJC_FLAGS_RELWITHDEBINFO}")
string(REPLACE "/DNDEBUG" "" CMAKE_OBJCXX_FLAGS_RELEASE "${CMAKE_OBJCXX_FLAGS_RELEASE}")
string(REPLACE "-DNDEBUG" "" CMAKE_OBJCXX_FLAGS_RELEASE "${CMAKE_OBJCXX_FLAGS_RELEASE}")
string(REPLACE "/DNDEBUG" "" CMAKE_OBJCXX_FLAGS_RELWITHDEBINFO "${CMAKE_OBJCXX_FLAGS_RELWITHDEBINFO}")
string(REPLACE "-DNDEBUG" "" CMAKE_OBJCXX_FLAGS_RELWITHDEBINFO "${CMAKE_OBJCXX_FLAGS_RELWITHDEBINFO}")

set(PUTTY_IPV6 ON
  CACHE BOOL "Build PuTTY with IPv6 support if possible")
set(PUTTY_DEBUG OFF
  CACHE BOOL "Build PuTTY with debug() statements enabled")
set(PUTTY_FUZZING OFF
  CACHE BOOL "Build PuTTY binaries suitable for fuzzing, NOT FOR REAL USE")
set(PUTTY_COVERAGE OFF
  CACHE BOOL "Build PuTTY binaries suitable for code coverage analysis")
set(PUTTY_SWIFT_COVERAGE OFF
  CACHE BOOL "Instrument Swift (PuttyMacUI / XCTest) for LLVM coverage")
set(PUTTY_SANITIZE ""
  CACHE STRING
  "C/ObjC(/Swift) sanitizers: empty, or comma-separated address,undefined,thread. address and thread are mutually exclusive; Debug CI only.")
set_property(CACHE PUTTY_SANITIZE PROPERTY STRINGS
  "" "address" "undefined" "address,undefined" "thread")
set(PUTTY_COMPRESS_SCROLLBACK ON
  # This is always on in production versions of PuTTY, but downstreams
  # of the code have been known to find it a better tradeoff to
  # disable it. So there's a #ifdef in terminal.c, and a cmake option
  # to enable that ifdef just in case it needs testing or debugging.
  CACHE BOOL "Store terminal scrollback in compressed form")

set(STRICT OFF
  CACHE BOOL "Enable extra compiler warnings and make them errors")

include(FindGit)

set(GENERATED_SOURCES_DIR ${CMAKE_CURRENT_BINARY_DIR}${CMAKE_FILES_DIRECTORY})

set(GENERATED_LICENCE_H ${GENERATED_SOURCES_DIR}/licence.h)
set(INTERMEDIATE_LICENCE_H ${GENERATED_LICENCE_H}.tmp)
add_custom_command(OUTPUT ${INTERMEDIATE_LICENCE_H}
  COMMAND ${CMAKE_COMMAND}
    -DLICENCE_FILE=${CMAKE_SOURCE_DIR}/LICENCE
    -DOUTPUT_FILE=${INTERMEDIATE_LICENCE_H}
    -P ${CMAKE_SOURCE_DIR}/cmake/licence.cmake
  DEPENDS ${CMAKE_SOURCE_DIR}/cmake/licence.cmake ${CMAKE_SOURCE_DIR}/LICENCE)
add_custom_target(generated_licence_h
  BYPRODUCTS ${GENERATED_LICENCE_H}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${INTERMEDIATE_LICENCE_H} ${GENERATED_LICENCE_H}
  DEPENDS ${INTERMEDIATE_LICENCE_H}
  COMMENT "Updating licence.h")

set(GENERATED_COMMIT_C ${GENERATED_SOURCES_DIR}/cmake_commit.c)
set(INTERMEDIATE_COMMIT_C ${GENERATED_COMMIT_C}.tmp)
add_custom_target(check_git_commit
  BYPRODUCTS ${INTERMEDIATE_COMMIT_C}
  COMMAND ${CMAKE_COMMAND}
    -DGIT_EXECUTABLE=${GIT_EXECUTABLE}
    -DOUTPUT_FILE=${INTERMEDIATE_COMMIT_C}
    -DOUTPUT_TYPE=header
    -P ${CMAKE_SOURCE_DIR}/cmake/gitcommit.cmake
  DEPENDS ${CMAKE_SOURCE_DIR}/cmake/gitcommit.cmake
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Checking current git commit")
add_custom_target(cmake_commit_c
  BYPRODUCTS ${GENERATED_COMMIT_C}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${INTERMEDIATE_COMMIT_C} ${GENERATED_COMMIT_C}
  DEPENDS check_git_commit ${INTERMEDIATE_COMMIT_C}
  COMMENT "Updating cmake_commit.c")

if(CMAKE_VERSION VERSION_LESS 3.12)
  function(add_compile_definitions)
    foreach(i ${ARGN})
      add_compile_options(-D${i})
    endforeach()
  endfunction()
endif()

function(add_sources_from_current_dir target)
  set(sources)
  foreach(i ${ARGN})
    set(sources ${sources} ${CMAKE_CURRENT_SOURCE_DIR}/${i})
  endforeach()
  target_sources(${target} PRIVATE ${sources})
endfunction()

set(extra_dirs)
if(CMAKE_SYSTEM_NAME MATCHES "Windows" OR WINELIB)
  set(platform windows)
elseif(PUTTY_MACOS_GUI)
  set(platform macos)
else()
  set(platform unix)
endif()

function(be_list TARGET NAME)
  cmake_parse_arguments(OPT "SSH;SERIAL;OTHERBACKENDS" "" "" "${ARGN}")
  add_library(${TARGET}-be-list OBJECT ${CMAKE_SOURCE_DIR}/be_list.c)
  foreach(setting SSH SERIAL OTHERBACKENDS)
    if(OPT_${setting})
      target_compile_definitions(${TARGET}-be-list PRIVATE ${setting}=1)
    else()
      target_compile_definitions(${TARGET}-be-list PRIVATE ${setting}=0)
    endif()
  endforeach()
  target_compile_definitions(${TARGET}-be-list PRIVATE APPNAME=${NAME})
  target_sources(${TARGET} PRIVATE $<TARGET_OBJECTS:${TARGET}-be-list>)
endfunction()

include(cmake/platforms/${platform}.cmake)

include_directories(
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${GENERATED_SOURCES_DIR}
  ${platform}
  ${extra_dirs})

check_c_source_compiles("
#define _ISOC11_SOURCE
#include <stdlib.h>
int main(int argc, char **argv) {
    void *p = aligned_alloc(128, 12345);
    free(p);
}" HAVE_ALIGNED_ALLOC)

check_c_source_compiles("
int main(int argc, char **argv) {
    int a[3];
    return _Countof(a);
}" HAVE_COUNTOF)

# Try to normalise source file pathnames as seen in __FILE__ (e.g.
# assertion failure messages). Partly to avoid bloating the binaries
# with file prefixes like /home/simon/stuff/things/tmp-7x6c5d54/, but
# also to make the builds more deterministic - building from the same
# source should give the same binary even if you do it in a
# differently named temp directory.
function(map_pathname src dst)
  if(CMAKE_C_COMPILER_ID MATCHES "Clang" AND
     CMAKE_C_COMPILER_FRONTEND_VARIANT MATCHES "MSVC")
    # -fmacro-prefix-map isn't available as a clang-cl option, so we
    # prefix it with -Xclang to pass it straight through to the
    # underlying clang -cc1 invocation, which spells the option the
    # same way.
    set(CMAKE_C_FLAGS
      "${CMAKE_C_FLAGS} -Xclang -fmacro-prefix-map=${src}=${dst}"
      PARENT_SCOPE)
  elseif(CMAKE_C_COMPILER_ID MATCHES "GNU" OR
      CMAKE_C_COMPILER_ID MATCHES "Clang")
    set(CMAKE_C_FLAGS
      "${CMAKE_C_FLAGS} -fmacro-prefix-map=${src}=${dst}"
      PARENT_SCOPE)
  endif()
endfunction()
map_pathname(${CMAKE_SOURCE_DIR} /putty)
map_pathname(${CMAKE_BINARY_DIR} /build)

if(PUTTY_DEBUG)
  add_compile_definitions(DEBUG)
endif()
if(PUTTY_FUZZING)
  add_compile_definitions(FUZZING)
endif()
if(NOT PUTTY_COMPRESS_SCROLLBACK)
  set(NO_SCROLLBACK_COMPRESSION ON)
endif()
if(PUTTY_COVERAGE)
  # Match gcc/clang --coverage for C/ObjC only. Do not put these on
  # CMAKE_*_LINKER_FLAGS — Swift rejects -fprofile-arcs as a driver flag.
  add_compile_options(
    "$<$<COMPILE_LANGUAGE:C,OBJC,OBJCXX>:-fprofile-arcs;-ftest-coverage;-g>")
  add_link_options(
    "$<$<LINK_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fprofile-arcs;-ftest-coverage>")
  # Swift links instrumented C archives; pull in clang's profile runtime
  # explicitly (ld does not accept -fprofile-arcs).
  execute_process(
    COMMAND ${CMAKE_C_COMPILER} -print-file-name=libclang_rt.profile_osx.a
    OUTPUT_VARIABLE PUTTY_CLANG_PROFILE_LIB
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
  if(PUTTY_CLANG_PROFILE_LIB AND EXISTS "${PUTTY_CLANG_PROFILE_LIB}")
    add_link_options(
      "$<$<LINK_LANGUAGE:Swift>:${PUTTY_CLANG_PROFILE_LIB}>")
  else()
    message(WARNING
      "PUTTY_COVERAGE: libclang_rt.profile_osx.a not found; "
      "Swift targets that link C may fail to link")
  endif()
endif()

if(PUTTY_SWIFT_COVERAGE)
  if(NOT APPLE)
    message(FATAL_ERROR "PUTTY_SWIFT_COVERAGE is only supported on Darwin")
  endif()
  # LLVM IR-level coverage for Swift modules (profraw → llvm-cov).
  add_compile_options(
    "$<$<COMPILE_LANGUAGE:Swift>:-profile-generate;-profile-coverage-mapping>")
  add_link_options(
    "$<$<LINK_LANGUAGE:Swift>:-profile-generate>")
endif()

# ---------------------------------------------------------------------------
# Sanitizers (Debug / CI). Instrument C/ObjC; Swift gets matching -sanitize=
# for address/thread so mixed link lines pick up the runtime. Do not enable
# on Universal release / notarized builds.
# ---------------------------------------------------------------------------
string(STRIP "${PUTTY_SANITIZE}" _putty_sanitize_raw)
if(_putty_sanitize_raw STREQUAL "")
  set(PUTTY_SANITIZE_ACTIVE OFF)
else()
  set(PUTTY_SANITIZE_ACTIVE ON)
  string(TOLOWER "${_putty_sanitize_raw}" _putty_sanitize_raw)
  string(REPLACE " " "" _putty_sanitize_raw "${_putty_sanitize_raw}")
  string(REPLACE ";" "," _putty_sanitize_raw "${_putty_sanitize_raw}")
  string(REPLACE "," ";" _putty_sanitize_list "${_putty_sanitize_raw}")

  set(_putty_san_has_address OFF)
  set(_putty_san_has_thread OFF)
  set(_putty_san_has_undefined OFF)
  set(_putty_san_clang_flags)
  set(_putty_san_swift_flags)

  foreach(_putty_san ${_putty_sanitize_list})
    if(_putty_san STREQUAL "address")
      set(_putty_san_has_address ON)
      list(APPEND _putty_san_clang_flags "address")
      list(APPEND _putty_san_swift_flags "address")
    elseif(_putty_san STREQUAL "thread")
      set(_putty_san_has_thread ON)
      list(APPEND _putty_san_clang_flags "thread")
      list(APPEND _putty_san_swift_flags "thread")
    elseif(_putty_san STREQUAL "undefined")
      set(_putty_san_has_undefined ON)
      list(APPEND _putty_san_clang_flags "undefined")
      # UBSan is C/ObjC-only; Swift has limited/no matching coverage.
    elseif(NOT _putty_san STREQUAL "")
      message(FATAL_ERROR
        "PUTTY_SANITIZE: unknown sanitizer '${_putty_san}' "
        "(use address, undefined, thread)")
    endif()
  endforeach()

  if(_putty_san_has_address AND _putty_san_has_thread)
    message(FATAL_ERROR
      "PUTTY_SANITIZE: address and thread cannot be combined")
  endif()

  if(PUTTY_COVERAGE OR PUTTY_SWIFT_COVERAGE)
    message(WARNING
      "PUTTY_SANITIZE with coverage is unsupported in many toolchains; "
      "prefer separate build trees")
  endif()

  if(DEFINED PUTTY_MACOS_UNIVERSAL AND PUTTY_MACOS_UNIVERSAL)
    message(WARNING
      "PUTTY_SANITIZE with PUTTY_MACOS_UNIVERSAL=ON is not recommended "
      "(use a host-arch Debug tree)")
  endif()

  list(JOIN _putty_san_clang_flags "," _putty_san_clang_joined)
  add_compile_options(
    "$<$<COMPILE_LANGUAGE:C,OBJC,OBJCXX>:-fsanitize=${_putty_san_clang_joined};-fno-omit-frame-pointer;-g>")
  add_link_options(
    "$<$<LINK_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fsanitize=${_putty_san_clang_joined}>")

  if(_putty_san_swift_flags AND APPLE)
    list(JOIN _putty_san_swift_flags "," _putty_san_swift_joined)
    add_compile_options(
      "$<$<COMPILE_LANGUAGE:Swift>:-sanitize=${_putty_san_swift_joined}>")
    add_link_options(
      "$<$<LINK_LANGUAGE:Swift>:-sanitize=${_putty_san_swift_joined}>")
  endif()

  message(STATUS "PUTTY_SANITIZE=${_putty_sanitize_raw} (C/ObjC + Swift where applicable)")
endif()
