# Quality tooling targets for the macOS GUI tree (lint / format / tidy / CSA).
#
# These do not require a special sanitizer or coverage build. They operate on
# sources under macos/ only — never reformat or tidy upstream root *.c.

set(PUTTY_MACOS_QUALITY_DIR ${CMAKE_SOURCE_DIR}/macos)
set(PUTTY_MACOS_SCRIPTS_DIR ${PUTTY_MACOS_QUALITY_DIR}/scripts)

add_custom_target(putty-macos-swiftlint
  COMMAND ${PUTTY_MACOS_SCRIPTS_DIR}/run-swiftlint.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "SwiftLint on macos/**/*.swift"
  USES_TERMINAL
  VERBATIM)

add_custom_target(putty-macos-swiftformat
  COMMAND ${PUTTY_MACOS_SCRIPTS_DIR}/run-swiftformat.sh --lint
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "SwiftFormat --lint on macos/**/*.swift"
  USES_TERMINAL
  VERBATIM)

add_custom_target(putty-macos-swiftformat-apply
  COMMAND ${PUTTY_MACOS_SCRIPTS_DIR}/run-swiftformat.sh --apply
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "SwiftFormat --apply on macos/**/*.swift"
  USES_TERMINAL
  VERBATIM)

add_custom_target(putty-macos-clang-tidy
  COMMAND ${PUTTY_MACOS_SCRIPTS_DIR}/run-clang-tidy.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "clang-tidy on macos/ C and ObjC (narrow checks)"
  USES_TERMINAL
  VERBATIM)

add_custom_target(putty-macos-clang-analyze
  COMMAND ${PUTTY_MACOS_SCRIPTS_DIR}/run-clang-analyze.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Clang Static Analyzer on macos/ C and ObjC"
  USES_TERMINAL
  VERBATIM)

add_custom_target(putty-macos-quality
  DEPENDS
    putty-macos-swiftlint
    putty-macos-swiftformat
    putty-macos-clang-tidy
  COMMENT "Run SwiftLint + SwiftFormat --lint + clang-tidy (macos/ only)")
