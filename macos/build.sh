#!/usr/bin/env bash
# Manage macOS GUI (and optional CLI) CMake builds for PuTTY.
#
# Requires Bash 5.x (Homebrew: brew install bash). Ensure that bash is
# ahead of /bin/bash on PATH so this shebang resolves to 5.x — for example:
#   export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
#
# Usage:
#   ./macos/build.sh [command] [options]
#
# Commands:
#   build       Configure if needed, then build (default)
#   configure   Configure the build tree only
#   open        Launch an .app from the build tree
#   verify      Run verify-bundle-layout (and verify-universal when applicable)
#   test        Build putty-mac-test-gate then run CTest (Phase 9.1)
#   install     Install .app bundles to a prefix
#   clean       Remove the selected build directory
#   check       Verify toolchain prerequisites
#   help        Show this help
#
# Profiles:
#   --dev         Debug, Ninja, host arch only  (build-macos-gui-dev)  [default]
#   --release     Release, Ninja                 (build-macos-gui)
#   --universal   Release, Xcode, Universal 2   (build-macos-gui-universal)
#   --cli         CLI/unix platform, Ninja      (build-macos-cli)
#
# Logs:
#   configure / build / verify / install append to <build-dir>/build.log
#   (e.g. build-macos-gui-dev/build.log). Terminal output is still shown.

# Bash 5+ only (EPOCHREALTIME, ${arr[*]@Q}, inherit_errexit, …).
if ((BASH_VERSINFO[0] < 5)); then
  printf 'error: Bash 5.x required (found %s); install with: brew install bash\n' \
    "${BASH_VERSION}" >&2
  printf 'error: put Homebrew bash on PATH before /bin/bash, then re-run.\n' >&2
  exit 1
fi

set -euo pipefail
shopt -s inherit_errexit lastpipe nullglob extglob
shopt -s varredir_close 2>/dev/null || true # Bash 5.2+

# ---------------------------------------------------------------------------
# Paths & defaults
# ---------------------------------------------------------------------------

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_PATH SCRIPT_DIR ROOT_DIR

declare -g DEPLOYMENT_TARGET=${PUTTY_MACOS_DEPLOYMENT_TARGET:-15.0}
declare -g PROFILE=dev
declare -g COMMAND=build
declare -g APP_NAME=putty
declare -g INSTALL_PREFIX=/Applications
declare -g BUILD_DIR_OVERRIDE=
declare -g JOBS=
declare -g BUILD_LOG=
declare -gi DO_OPEN=0
declare -gi DO_RECONFIGURE=0
declare -gi DO_LOG=1
declare -ga EXTRA_CMAKE_ARGS=()
declare -ga EXTRA_CTEST_ARGS=()
declare -ga ORIG_ARGV=("$@")

# Resolved by resolve_profile.
declare -g BUILD_DIR GENERATOR BUILD_TYPE UNIVERSAL GUI XCODE_CONFIG

# profile -> build_dir_basename|generator|build_type|universal|gui|xcode_config
declare -gA PROFILE_SPEC=(
  [dev]='build-macos-gui-dev|Ninja|Debug|OFF|ON|'
  [release]='build-macos-gui|Ninja|Release|OFF|ON|'
  [universal]='build-macos-gui-universal|Xcode|Release|ON|ON|Release'
  [cli]='build-macos-cli|Ninja|Release|OFF|OFF|'
)

declare -gA APP_BUNDLE=(
  [putty]=PuTTY.app
  [pterm]=pterm.app
  [puttygen]=puttygen.app
)

declare -gA COMMANDS=(
  [build]=run_build
  [configure]=run_configure
  [open]=run_open
  [verify]=run_verify
  [test]=run_test
  [install]=run_install
  [clean]=run_clean
  [check]=run_check
  [help]=usage
)

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

die() {
  local fmt=$1
  shift || true
  local msg
  # shellcheck disable=SC2059
  printf -v msg "error: ${fmt}" "$@"
  printf '%s\n' "${msg}" >&2
  if [[ -n ${BUILD_LOG} && -f ${BUILD_LOG} ]]; then
    printf '%s\n' "${msg}" >>"${BUILD_LOG}"
    printf 'error: see also %s\n' "${BUILD_LOG}" >&2
  fi
  exit 1
}

log() {
  local line="==> $*"
  printf '%s\n' "${line}"
  if [[ -n ${BUILD_LOG} ]]; then
    printf '%s\n' "${line}" >>"${BUILD_LOG}"
  fi
}

log_detail() {
  local line="    $*"
  printf '%s\n' "${line}"
  if [[ -n ${BUILD_LOG} ]]; then
    printf '%s\n' "${line}" >>"${BUILD_LOG}"
  fi
}

on_err() {
  local ec=$?
  local msg
  printf -v msg 'error: command failed (exit %d) at %s:%s: %s' \
    "${ec}" "${BASH_SOURCE[1]-${BASH_SOURCE[0]}}" "${BASH_LINENO[0]-?}" "${BASH_COMMAND-}"
  printf '%s\n' "${msg}" >&2
  if [[ -n ${BUILD_LOG} && -f ${BUILD_LOG} ]]; then
    printf '%s\n' "${msg}" >>"${BUILD_LOG}"
    printf 'error: see also %s\n' "${BUILD_LOG}" >&2
  fi
}
trap on_err ERR

# Append a session header and enable BUILD_LOG under the profile build dir.
# Idempotent within a single script invocation for the same BUILD_DIR.
start_build_log() {
  ((DO_LOG)) || {
    BUILD_LOG=
    return 0
  }

  mkdir -p -- "${BUILD_DIR}"
  local path=${BUILD_DIR}/build.log
  if [[ ${BUILD_LOG} == "${path}" ]]; then
    return 0
  fi
  BUILD_LOG=${path}

  {
    printf '\n'
    printf '======== %(%Y-%m-%dT%H:%M:%S%z)T ========\n' -1
    printf 'command: %s\n' "${COMMAND}"
    printf 'profile: %s\n' "${PROFILE}"
    printf 'build_dir: %s\n' "${BUILD_DIR}"
    printf 'generator: %s\n' "${GENERATOR}"
    printf 'build_type: %s\n' "${BUILD_TYPE}"
    printf 'universal: %s\n' "${UNIVERSAL}"
    printf 'argv: %s\n' "${ORIG_ARGV[*]@Q}"
    printf 'cwd: %s\n' "${PWD}"
    printf 'bash: %s\n' "${BASH_VERSION}"
    printf '========\n'
  } >>"${BUILD_LOG}"

  log_detail "log: ${BUILD_LOG}"
}

# Preserve build.log across an rm -rf of BUILD_DIR (generator switches).
preserve_build_log_across() {
  local -a wipe_cmd=("$@")
  local saved=

  if [[ -n ${BUILD_LOG} && -f ${BUILD_LOG} ]]; then
    saved=$(mktemp "${TMPDIR:-/tmp}/putty-macos-build-log.XXXXXX")
    cp "${BUILD_LOG}" "${saved}"
  fi

  "${wipe_cmd[@]}"

  if [[ -n ${saved} ]]; then
    mkdir -p -- "${BUILD_DIR}"
    mv "${saved}" "${BUILD_LOG}"
  fi
}

# Run a command, tee combined stdout/stderr to BUILD_LOG (and the terminal).
run_logged() {
  if [[ -z ${BUILD_LOG} ]]; then
    "$@"
    return
  fi

  local -i ec=0
  set +e
  set +o pipefail
  "$@" 2>&1 | tee -a -- "${BUILD_LOG}"
  ec=${PIPESTATUS[0]}
  set -o pipefail
  set -e
  return "${ec}"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
  local rel=${SCRIPT_PATH#"${ROOT_DIR}/"}
  cat <<EOF
Manage macOS GUI (and optional CLI) CMake builds for PuTTY.

Requires: Bash 5.x (this shell: ${BASH_VERSION})

Usage:
  ${rel} [command] [options]

Commands:
  build       Configure if needed, then build (default)
  configure   Configure the build tree only
  open        Launch an .app from the build tree
  verify      Run verify-bundle-layout (and verify-universal when applicable)
  test        Build putty-mac-test-gate, then ctest -L macos (Phase 9.1)
  install     Install .app bundles to a prefix
  clean       Remove the selected build directory
  check       Verify toolchain prerequisites
  help        Show this help

Profiles:
  --dev         Debug, Ninja, host arch only  (build-macos-gui-dev)  [default]
  --release     Release, Ninja                 (build-macos-gui)
  --universal   Release, Xcode, Universal 2   (build-macos-gui-universal)
  --cli         CLI/unix platform, Ninja      (build-macos-cli)

Options:
  --open                    After build, open the selected .app
  --reconfigure             Force CMake reconfigure
  --app NAME                App to open: putty | pterm | puttygen  (default: putty)
  --prefix PATH             Install prefix (default: /Applications)
  --build-dir PATH          Override build directory
  --jobs N, -j N            Parallel build jobs
  --deployment-target VER   macOS deployment target (default: 15.0)
  --no-log                  Do not write <build-dir>/build.log
  --ctest-args ARGS         Extra arguments for ctest (quote as one value)
  -DVAR=VALUE               Extra CMake cache entry (repeatable)

Logs:
  configure / build / verify / install append a full transcript to
  <build-dir>/build.log (for example build-macos-gui-dev/build.log).
  Output is still printed to the terminal. clean removes the log with
  the build directory.

Examples:
  ./macos/build.sh --dev
  ./macos/build.sh build --release --open
  ./macos/build.sh open --dev --app pterm
  ./macos/build.sh verify --universal
  ./macos/build.sh test --dev
  ./macos/build.sh test --release --ctest-args '-L unit'
  ./macos/build.sh install --release --prefix /Applications
  ./macos/build.sh clean --dev
EOF
}

# ---------------------------------------------------------------------------
# Profile / app resolution
# ---------------------------------------------------------------------------

require_darwin() {
  [[ $(uname -s) == Darwin ]] || die 'this script only runs on macOS'
  # Homebrew often exports LDFLAGS/CPPFLAGS that pull Command Line Tools
  # Swift overlays and break Xcode SDK module builds.
  unset LDFLAGS CPPFLAGS SDKROOT || true
}

resolve_profile() {
  [[ -v PROFILE_SPEC[${PROFILE}] ]] || die 'unknown profile: %s' "${PROFILE}"

  local IFS='|'
  local -a fields
  read -ra fields <<< "${PROFILE_SPEC[${PROFILE}]}"

  local dir_name=${fields[0]}
  GENERATOR=${fields[1]}
  BUILD_TYPE=${fields[2]}
  UNIVERSAL=${fields[3]}
  GUI=${fields[4]}
  XCODE_CONFIG=${fields[5]-}

  if [[ -n ${BUILD_DIR_OVERRIDE} ]]; then
    BUILD_DIR=${BUILD_DIR_OVERRIDE}
  else
    BUILD_DIR=${ROOT_DIR}/${dir_name}
  fi
}

normalize_app_name() {
  # ${var,,} — lowercase for case-insensitive lookup (Bash 4+).
  local key=${1,,}
  key=${key%.app}
  [[ -v APP_BUNDLE[${key}] ]] || die 'unknown app: %s (use putty, pterm, or puttygen)' "$1"
  printf '%s\n' "${APP_BUNDLE[${key}]}"
}

find_app_bundle() {
  local name
  name=$(normalize_app_name "${APP_NAME}")

  local -a candidates=()
  if [[ -n ${XCODE_CONFIG} ]]; then
    candidates=(
      "${BUILD_DIR}/${XCODE_CONFIG}/${name}"
      "${BUILD_DIR}/${name}"
    )
  else
    candidates=(
      "${BUILD_DIR}/${name}"
      "${BUILD_DIR}/Debug/${name}"
      "${BUILD_DIR}/Release/${name}"
    )
  fi

  local path
  for path in "${candidates[@]}"; do
    [[ -d ${path} ]] || continue
    printf '%s\n' "${path}"
    return 0
  done

  die 'could not find %s under %s (build first?)' "${name}" "${BUILD_DIR}"
}

cmake_configured() {
  [[ -f ${BUILD_DIR}/CMakeCache.txt ]]
}

# Read a CMakeCache.txt entry (TYPE:value). Prints empty if missing.
cmake_cache_get() {
  local key=$1
  local cache=${BUILD_DIR}/CMakeCache.txt
  [[ -f ${cache} ]] || return 0
  local line
  line=$(grep -E "^${key}:" "${cache}" | head -n1) || true
  printf '%s\n' "${line#*:}"
}

# Force reconfigure when generator / GUI / universal settings disagree.
profile_matches_cache() {
  cmake_configured || return 1

  local gen universal gui
  gen=$(cmake_cache_get CMAKE_GENERATOR)
  # INTERNAL entries look like "INTERNAL=Ninja"; BOOL like "BOOL=ON".
  gen=${gen#*=}
  universal=$(cmake_cache_get PUTTY_MACOS_UNIVERSAL)
  universal=${universal#*=}
  gui=$(cmake_cache_get PUTTY_MACOS_GUI)
  gui=${gui#*=}

  [[ ${gen} == "${GENERATOR}" ]] || return 1

  if [[ ${GUI} == ON ]]; then
    [[ ${gui} == ON ]] || return 1
    [[ ${universal} == "${UNIVERSAL}" ]] || return 1
  else
    [[ ${gui} != ON ]] || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

have_cmd() {
  command -v -- "$1" &>/dev/null
}

# Nameref updates caller's integer success flag (0 = failure seen).
check_tool() {
  local -n _ok=$1
  local label=$2
  shift 2

  if ! have_cmd "$1"; then
    log_detail "missing: ${label}"
    _ok=0
    return 1
  fi
  return 0
}

run_check() {
  require_darwin
  local -i ok=1
  local -a swift_ver=()

  log 'Checking toolchain'
  log_detail "bash: ${BASH_VERSION} ($(command -v -- bash))"

  if check_tool ok cmake cmake; then
    log_detail "cmake: $(cmake --version | head -n1)"
  fi

  if check_tool ok 'ninja (needed for --dev / --release / --cli)' ninja; then
    log_detail "ninja: $(ninja --version)"
  fi

  if check_tool ok 'python3 (icon generation)' python3; then
    log_detail "python3: $(python3 --version 2>&1)"
  fi

  if xcode-select -p &>/dev/null; then
    log_detail "xcode-select: $(xcode-select -p)"
  else
    log_detail 'missing: Xcode developer directory (xcode-select --install)'
    ok=0
  fi

  if xcrun --find swiftc &>/dev/null; then
    log_detail "swiftc: $(xcrun --find swiftc)"
    mapfile -t -n 1 swift_ver < <(swiftc --version 2>&1)
    [[ -n ${swift_ver[0]-} ]] && log_detail "  ${swift_ver[0]}"
  else
    log_detail 'missing: swiftc (point xcode-select at full Xcode, not CLT alone)'
    ok=0
  fi

  if ((ok == 0)); then
    die 'toolchain check failed'
  fi
  log 'OK'
}

run_configure() {
  require_darwin
  resolve_profile
  start_build_log

  if cmake_configured && ((!DO_RECONFIGURE)) && profile_matches_cache; then
    log "Already configured: ${BUILD_DIR}"
    log_detail '(pass --reconfigure to force)'
    return 0
  fi

  if cmake_configured && ((!DO_RECONFIGURE)) && ! profile_matches_cache; then
    log "Build tree settings differ from profile ${PROFILE}; reconfiguring"
    log_detail "${BUILD_DIR}"
  fi

  log "Configuring ${PROFILE} -> ${BUILD_DIR}"

  local -a args=(
    -S "${ROOT_DIR}"
    -B "${BUILD_DIR}"
    -G "${GENERATOR}"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
  )

  # CMAKE_BUILD_TYPE is for single-config generators (Ninja). Xcode is
  # multi-config and selects Release/Debug via --config / XCODE_CONFIG;
  # passing CMAKE_BUILD_TYPE there only triggers an unused-variable warning.
  if [[ ${GENERATOR} != Xcode ]]; then
    args+=(-DCMAKE_BUILD_TYPE="${BUILD_TYPE}")
  fi

  if [[ ${GUI} == ON ]]; then
    args+=(-DPUTTY_MACOS_GUI=ON -DPUTTY_MACOS_UNIVERSAL="${UNIVERSAL}")
  else
    args+=(-DPUTTY_MACOS_GUI=OFF)
  fi

  if ((${#EXTRA_CMAKE_ARGS[@]} > 0)); then
    args+=("${EXTRA_CMAKE_ARGS[@]}")
  fi

  # Switching generators (Ninja <-> Xcode) requires a clean build tree.
  if cmake_configured; then
    local existing_gen
    existing_gen=$(cmake_cache_get CMAKE_GENERATOR)
    existing_gen=${existing_gen#*=}
    if [[ -n ${existing_gen} && ${existing_gen} != "${GENERATOR}" ]]; then
      log "Generator change (${existing_gen} -> ${GENERATOR}); removing ${BUILD_DIR}"
      preserve_build_log_across rm -rf -- "${BUILD_DIR}"
    fi
  fi

  run_logged cmake "${args[@]}"
}

run_cmake_build() {
  local target=${1-}
  local -a args=(--build "${BUILD_DIR}")

  [[ -n ${XCODE_CONFIG} ]] && args+=(--config "${XCODE_CONFIG}")

  if [[ -n ${JOBS} ]]; then
    args+=(--parallel "${JOBS}")
  else
    args+=(--parallel)
  fi

  [[ -n ${target} ]] && args+=(--target "${target}")

  run_logged cmake "${args[@]}"
}

# EPOCHREALTIME — Bash 5.0+ sub-second wall clock (no date(1)).
elapsed_since() {
  local start=$1
  awk -v s="${start}" -v n="${EPOCHREALTIME}" 'BEGIN { printf "%.1fs", n - s }'
}

# Bump mtime on each built .app directory (not contents). Rebuilds often
# update files inside the bundle without refreshing the bundle itself, so
# Finder / Launch Services can keep a stale date.
touch_app_bundles() {
  [[ ${GUI} == ON ]] || return 0

  local name path
  local -a candidates=()
  local -i touched=0

  for name in "${APP_BUNDLE[@]}"; do
    candidates=()
    if [[ -n ${XCODE_CONFIG} ]]; then
      candidates=(
        "${BUILD_DIR}/${XCODE_CONFIG}/${name}"
        "${BUILD_DIR}/${name}"
      )
    else
      candidates=(
        "${BUILD_DIR}/${name}"
        "${BUILD_DIR}/Debug/${name}"
        "${BUILD_DIR}/Release/${name}"
      )
    fi
    for path in "${candidates[@]}"; do
      [[ -d ${path} ]] || continue
      touch -- "${path}"
      log_detail "touched ${path}"
      touched=1
      break
    done
  done

  ((touched)) || log_detail 'no .app bundles found to touch'
}

run_build() {
  require_darwin
  resolve_profile
  start_build_log

  if ! cmake_configured || ((DO_RECONFIGURE)) || ! profile_matches_cache; then
    run_configure
  fi

  local start=${EPOCHREALTIME}
  log "Building ${PROFILE} (${BUILD_DIR})"
  run_cmake_build
  touch_app_bundles
  log "Build finished in $(elapsed_since "${start}")"
  log_detail "log: ${BUILD_LOG:-"(disabled)"}"

  if ((DO_OPEN)); then
    run_open
  fi
}

run_open() {
  require_darwin
  resolve_profile
  [[ ${GUI} == ON ]] || die '--open is only for GUI profiles'

  local bundle
  bundle=$(find_app_bundle)
  log "Opening ${bundle}"
  open -- "${bundle}"
}

run_verify() {
  require_darwin
  resolve_profile
  [[ ${GUI} == ON ]] || die 'verify is only for GUI profiles'
  cmake_configured || die 'not configured: %s' "${BUILD_DIR}"
  start_build_log

  log 'Verifying bundle layout'
  run_cmake_build verify-bundle-layout

  if [[ ${UNIVERSAL} == ON ]]; then
    log 'Verifying Universal 2 slices'
    run_cmake_build verify-universal
  fi
}

run_test() {
  require_darwin
  resolve_profile
  [[ ${GUI} == ON ]] || die 'test is only for GUI profiles (PUTTY_MACOS_GUI=ON)'
  start_build_log

  if ! cmake_configured || ((DO_RECONFIGURE)) || ! profile_matches_cache; then
    run_configure
  fi

  local start=${EPOCHREALTIME}
  log "Building putty-mac-test-gate (${BUILD_DIR})"
  run_cmake_build putty-mac-test-gate

  # Prefer the build-root CTestTestfile (includes macos/tests via subdirs).
  # Fall back to the tests subdir if an older tree lacks the root file.
  local ctest_dir=${BUILD_DIR}
  if [[ ! -f ${BUILD_DIR}/CTestTestfile.cmake ]]; then
    if [[ -f ${BUILD_DIR}/macos/tests/CTestTestfile.cmake ]]; then
      ctest_dir=${BUILD_DIR}/macos/tests
    else
      die 'no CTestTestfile.cmake; reconfigure with BUILD_TESTING=ON'
    fi
  fi

  local -a ctest_args=(
    --test-dir "${ctest_dir}"
    --output-on-failure
    -L macos
  )
  if [[ -n ${XCODE_CONFIG} ]]; then
    ctest_args+=(-C "${XCODE_CONFIG}")
  fi
  if ((${#EXTRA_CTEST_ARGS[@]} > 0)); then
    ctest_args+=("${EXTRA_CTEST_ARGS[@]}")
  fi

  log "Running ctest ${ctest_args[*]@Q}"
  run_logged ctest "${ctest_args[@]}"
  log "Tests finished in $(elapsed_since "${start}")"
}

run_install() {
  require_darwin
  resolve_profile
  cmake_configured || die 'not configured: %s' "${BUILD_DIR}"
  start_build_log

  log "Installing to ${INSTALL_PREFIX}"
  local -a args=(--install "${BUILD_DIR}" --prefix "${INSTALL_PREFIX}")
  [[ -n ${XCODE_CONFIG} ]] && args+=(--config "${XCODE_CONFIG}")
  run_logged cmake "${args[@]}"
}

run_clean() {
  resolve_profile
  # Do not start_build_log — clean deletes the directory (and any log).
  if [[ -d ${BUILD_DIR} ]]; then
    log "Removing ${BUILD_DIR}"
    rm -rf -- "${BUILD_DIR}"
  else
    log "Nothing to clean (${BUILD_DIR} does not exist)"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

require_value() {
  local opt=$1
  if (($# < 2)); then
    die '%s requires a value' "${opt}"
  fi
}

parse_args() {
  local -a positional=()
  local -i command_set=0

  while (($# > 0)); do
    case $1 in
      build | configure | open | verify | test | install | clean | check | help)
        if ((command_set)); then
          die 'multiple commands: %s and %s' "${COMMAND}" "$1"
        fi
        COMMAND=$1
        command_set=1
        shift
        ;;
      -h | --help)
        if ((command_set)); then
          die 'multiple commands: %s and help' "${COMMAND}"
        fi
        COMMAND=help
        command_set=1
        shift
        ;;
      --dev | --release | --universal | --cli)
        PROFILE=${1#--}
        shift
        ;;
      --open)
        DO_OPEN=1
        shift
        ;;
      --reconfigure)
        DO_RECONFIGURE=1
        shift
        ;;
      --app)
        require_value "$@"
        APP_NAME=$2
        shift 2
        ;;
      --prefix)
        require_value "$@"
        INSTALL_PREFIX=$2
        shift 2
        ;;
      --build-dir)
        require_value "$@"
        BUILD_DIR_OVERRIDE=$2
        shift 2
        ;;
      --jobs | -j)
        require_value "$@"
        if [[ $2 != +([0-9]) ]]; then
          die '--jobs must be a positive integer (got %s)' "$2"
        fi
        JOBS=$2
        shift 2
        ;;
      --deployment-target)
        require_value "$@"
        DEPLOYMENT_TARGET=$2
        shift 2
        ;;
      --no-log)
        DO_LOG=0
        shift
        ;;
      --ctest-args)
        require_value "$@"
        # shellcheck disable=SC2206
        EXTRA_CTEST_ARGS+=($2)
        shift 2
        ;;
      -D*)
        EXTRA_CMAKE_ARGS+=("$1")
        shift
        ;;
      --)
        shift
        EXTRA_CMAKE_ARGS+=("$@")
        break
        ;;
      -*)
        die 'unknown option: %s (try --help)' "$1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  # ${arr[*]@Q} — Bash 5.0+ shell-quoted join for clear error output.
  if ((${#positional[@]} > 0)); then
    die 'unexpected arguments: %s' "${positional[*]@Q}"
  fi
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  [[ -v COMMANDS[${COMMAND}] ]] || die 'unknown command: %s' "${COMMAND}"
  "${COMMANDS[${COMMAND}]}"
}

main "$@"
