# Platform configuration for the native macOS (AppKit) GUI build.
#
# Selected when PUTTY_MACOS_GUI=ON on Darwin (see cmake/setup.cmake).
# Universal 2 / CMAKE_OSX_ARCHITECTURES is configured in cmake/macos_early.cmake
# before project() (Phase 1.7).

set(PUTTY_MACOS_APPKIT 1)

if(PUTTY_MACOS_UNIVERSAL_ACTIVE)
  set(PUTTY_MACOS_UNIVERSAL_BUILD 1)
else()
  set(PUTTY_MACOS_UNIVERSAL_BUILD 0)
endif()

set(PUTTY_MACOS_DEPLOYMENT_TARGET "15.0"
  CACHE STRING "Minimum macOS version for GUI targets")
set(PUTTY_MACOS_SIGN_IDENTITY ""
  CACHE STRING "Code signing identity (Developer ID or ad-hoc '-' for local dev)")
set(PUTTY_MACOS_NOTARIZE OFF
  CACHE BOOL "Run notarization post-build (requires Apple credentials)")

set(PUTTY_GSSAPI DYNAMIC
  CACHE STRING "Build PuTTY with dynamically or statically linked \
Kerberos / GSSAPI support, if possible")
set_property(CACHE PUTTY_GSSAPI
  PROPERTY STRINGS DYNAMIC STATIC OFF)

include(CheckIncludeFile)
include(CheckLibraryExists)
include(CheckSymbolExists)
include(CheckCSourceCompiles)
include(GNUInstallDirs)

set(CMAKE_REQUIRED_DEFINITIONS ${CMAKE_REQUIRED_DEFINITIONS}
  -D_DEFAULT_SOURCE -D_GNU_SOURCE)

# macOS has no X11 integration in the AppKit GUI build.
set(NOT_X_WINDOWS ON)

# Unix feature probes (expanded in Phase 2.6; shared with macos/platform/).
check_include_file(sys/sysctl.h HAVE_SYS_SYSCTL_H)
check_include_file(sys/types.h HAVE_SYS_TYPES_H)
check_include_file(glob.h HAVE_GLOB_H)
check_include_file(utmp.h HAVE_UTMP_H)
check_include_file(utmpx.h HAVE_UTMPX_H)

check_symbol_exists(futimes "sys/time.h" HAVE_FUTIMES)
check_symbol_exists(getaddrinfo "sys/types.h;sys/socket.h;netdb.h"
  HAVE_GETADDRINFO)
check_symbol_exists(posix_openpt "stdlib.h;fcntl.h" HAVE_POSIX_OPENPT)
check_symbol_exists(ptsname "stdlib.h" HAVE_PTSNAME)
check_symbol_exists(strsignal "string.h" HAVE_STRSIGNAL)
check_symbol_exists(updwtmpx "utmpx.h" HAVE_UPDWTMPX)
check_symbol_exists(fstatat "sys/types.h;sys/stat.h;unistd.h" HAVE_FSTATAT)
check_symbol_exists(dirfd "sys/types.h;dirent.h" HAVE_DIRFD)
check_symbol_exists(setpwent "sys/types.h;pwd.h" HAVE_SETPWENT)
check_symbol_exists(endpwent "sys/types.h;pwd.h" HAVE_ENDPWENT)
check_symbol_exists(sysctlbyname "sys/types.h;sys/sysctl.h" HAVE_SYSCTLBYNAME)
check_symbol_exists(CLOCK_MONOTONIC "time.h" HAVE_CLOCK_MONOTONIC)
check_symbol_exists(clock_gettime "time.h" HAVE_CLOCK_GETTIME)

check_c_source_compiles("
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    setpgrp();
}" HAVE_NULLARY_SETPGRP)
check_c_source_compiles("
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    setpgrp(0, 0);
}" HAVE_BINARY_SETPGRP)

if(HAVE_GETADDRINFO AND PUTTY_IPV6)
  set(NO_IPV6 OFF)
else()
  set(NO_IPV6 ON)
endif()

if(HAVE_UTMPX_H)
  set(OMIT_UTMP OFF)
else()
  set(OMIT_UTMP ON)
endif()

include_directories(${CMAKE_SOURCE_DIR}/charset)
include_directories(${CMAKE_SOURCE_DIR}/macos)
# Platform util headers (e.g. utils/arm_arch_queries.h) remain under unix/
# until Phase 2.5 migrates macos/utils/ fully.
include_directories(${CMAKE_SOURCE_DIR}/unix)

set(extra_dirs charset)

function(add_optional_system_lib library testfn)
  check_library_exists(${library} ${testfn} "" HAVE_LIB${library})
  if (HAVE_LIB${library})
    set(CMAKE_REQUIRED_LIBRARIES ${CMAKE_REQUIRED_LIBRARIES};-l${library})
    link_libraries(-l${library})
  endif()
endfunction()

add_optional_system_lib(m pow)
add_optional_system_lib(rt clock_gettime)

if(PUTTY_GSSAPI STREQUAL DYNAMIC)
  add_optional_system_lib(dl dlopen)
  if(HAVE_NO_LIBdl)
    message(WARNING
      "Could not find libdl -- cannot provide dynamic GSSAPI support")
    set(NO_GSSAPI ON)
  endif()
endif()

if(PUTTY_GSSAPI STREQUAL STATIC)
  find_package(PkgConfig)
  pkg_check_modules(KRB5 krb5-gssapi)
  if(KRB5_FOUND)
    include_directories(${KRB5_INCLUDE_DIRS})
    link_directories(${KRB5_LIBRARY_DIRS})
    link_libraries(${KRB5_LIBRARIES})
    add_compile_options(${KRB5_CFLAGS})
    set(STATIC_GSSAPI ON)
  else()
    message(WARNING
      "Could not find krb5 via pkg-config -- \
cannot provide static GSSAPI support")
    set(NO_GSSAPI ON)
  endif()
endif()

if(PUTTY_GSSAPI STREQUAL OFF)
  set(NO_GSSAPI ON)
endif()

# Apple system frameworks (used by macos/platform/ and Swift targets).
find_library(MACOS_SECURITY_FRAMEWORK Security)
find_library(MACOS_COREFOUNDATION_FRAMEWORK CoreFoundation)
find_library(MACOS_IOKIT_FRAMEWORK IOKit)
find_library(MACOS_SYSTEMCONFIGURATION_FRAMEWORK SystemConfiguration)

if(CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "")
  set(CMAKE_OSX_DEPLOYMENT_TARGET ${PUTTY_MACOS_DEPLOYMENT_TARGET}
    CACHE STRING "Minimum macOS version" FORCE)
endif()

if(STRICT AND (CMAKE_C_COMPILER_ID MATCHES "GNU" OR
               CMAKE_C_COMPILER_ID MATCHES "Clang"))
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Werror -Wpointer-arith -Wvla")
endif()

# Install helper for CLI tools; .app bundle install rules added in Phase 8.
function(installed_program target)
  if(CMAKE_VERSION VERSION_LESS 3.14)
    install(TARGETS ${target} RUNTIME DESTINATION bin)
  else()
    install(TARGETS ${target})
  endif()

  if(HAVE_MANPAGE_${target}_1)
    install(FILES ${CMAKE_BINARY_DIR}/doc/${target}.1
      DESTINATION ${CMAKE_INSTALL_MANDIR}/man1)
  else()
    message(WARNING "Could not build man page ${target}.1")
  endif()
endfunction()
