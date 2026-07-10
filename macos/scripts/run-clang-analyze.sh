#!/usr/bin/env bash
# Clang Static Analyzer on macos/bridge + macos/platform C/ObjC.
# Requires a configured GUI build tree for cmake.h (GENERATED_SOURCES_DIR).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd -- "${ROOT}"

CLANG=${CLANG:-$(xcrun --find clang)}
SDK=$(xcrun --sdk macosx --show-sdk-path)
DEPLOY=${PUTTY_MACOS_DEPLOYMENT_TARGET:-15.0}
OUT_DIR=${PUTTY_CLANG_ANALYZE_OUT:-${ROOT}/build-macos-gui-analyze}
mkdir -p -- "${OUT_DIR}"

find_cmake_h_dir() {
  local build
  for build in \
    "${PUTTY_CLANG_ANALYZE_BUILD_DIR:-}" \
    "${PUTTY_CLANG_TIDY_BUILD_DIR:-}" \
    build-macos-gui-dev \
    build-macos-gui-asan \
    build-macos-gui-tsan \
    build-macos-gui
  do
    [[ -n ${build} ]] || continue
    local dir
    if [[ ${build} == /* ]]; then
      dir=${build}/CMakeFiles
    else
      dir=${ROOT}/${build}/CMakeFiles
    fi
    if [[ -f ${dir}/cmake.h ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
  done
  return 1
}

CMAKE_H_DIR=$(find_cmake_h_dir) || {
  printf 'error: cmake.h not found; configure a GUI build first\n' >&2
  printf '  e.g. ./macos/build.sh configure --dev\n' >&2
  printf '  or:  make asan   # creates build-macos-gui-asan\n' >&2
  exit 1
}

mapfile -t sources < <(
  find macos/bridge macos/platform \( -name '*.c' -o -name '*.m' \) \
    ! -name '*-smoke*.c' \
    ! -name '*-smoke-main.c' \
    ! -name '*-perf-main.c' \
    ! -name '*-exit.c' \
    | LC_ALL=C sort
)

if ((${#sources[@]} == 0)); then
  printf 'error: no macos bridge/platform C/ObjC sources found\n' >&2
  exit 1
fi

printf '==> clang --analyze (%s) on %d sources -> %s\n' \
  "${CLANG}" "${#sources[@]}" "${OUT_DIR}"
printf '    cmake.h from %s\n' "${CMAKE_H_DIR}"

flags=(
  --analyze
  -isysroot "${SDK}"
  -mmacosx-version-min="${DEPLOY}"
  -std=c99
  -fobjc-arc
  -I"${ROOT}"
  -I"${ROOT}/macos"
  -I"${ROOT}/macos/platform"
  -I"${ROOT}/macos/bridge"
  -I"${ROOT}/terminal"
  -I"${ROOT}/charset"
  -I"${CMAKE_H_DIR}"
  -DHAVE_CMAKE_H
  -Xclang -analyzer-output=text
)

ec=0
for src in "${sources[@]}"; do
  base=$(basename -- "${src}")
  plist=${OUT_DIR}/${base}.plist
  printf '  analyze %s\n' "${src}"
  if ! "${CLANG}" "${flags[@]}" -o "${plist}" "${src}" \
    >"${OUT_DIR}/${base}.log" 2>&1; then
    ec=1
    printf '    FAIL (see %s)\n' "${OUT_DIR}/${base}.log" >&2
    # Show a short excerpt; full log stays on disk.
    tail -n 20 -- "${OUT_DIR}/${base}.log" >&2 || true
  fi
done

if ((ec == 0)); then
  printf 'clang-analyze: ok (artifacts under %s)\n' "${OUT_DIR}"
else
  printf 'clang-analyze: findings or errors (see %s)\n' "${OUT_DIR}" >&2
fi
exit "${ec}"
