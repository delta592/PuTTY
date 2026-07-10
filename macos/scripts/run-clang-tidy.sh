#!/usr/bin/env bash
# clang-tidy on macos/bridge + macos/platform C/ObjC only (config: macos/.clang-tidy).
# Does not touch upstream root *.c. Prefer Homebrew LLVM clang-tidy when
# Xcode's toolchain does not ship it.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd -- "${ROOT}"

find_tidy() {
  local c
  for c in \
    "${CLANG_TIDY:-}" \
    clang-tidy \
    /opt/homebrew/opt/llvm/bin/clang-tidy \
    /usr/local/opt/llvm/bin/clang-tidy
  do
    [[ -n ${c} ]] || continue
    if command -v -- "${c}" >/dev/null 2>&1 || [[ -x ${c} ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}

TIDY=$(find_tidy) || {
  printf 'error: clang-tidy not found; install with: brew install llvm\n' >&2
  exit 1
}

SDK=$(xcrun --sdk macosx --show-sdk-path)
DEPLOY=${PUTTY_MACOS_DEPLOYMENT_TARGET:-15.0}
CONFIG=${ROOT}/macos/.clang-tidy

mapfile -t sources < <(
  find macos/bridge macos/platform \( -name '*.c' -o -name '*.m' \) \
    ! -name '*-smoke*.c' \
    ! -name '*-smoke-main.c' \
    ! -name '*-perf-main.c' \
    ! -name '*-exit.c' \
    ! -name '*-exit-c.c' \
    | LC_ALL=C sort
)

if ((${#sources[@]} == 0)); then
  printf 'error: no macos bridge/platform C/ObjC sources found\n' >&2
  exit 1
fi

printf '==> clang-tidy (%s) on %d macos bridge/platform sources\n' \
  "${TIDY}" "${#sources[@]}"

# Always pass the macOS SDK explicitly: Homebrew clang-tidy does not inherit
# Xcode's default sysroot the way Apple clang does.
extra=(
  --config-file="${CONFIG}"
  --quiet
  -extra-arg=-isysroot
  -extra-arg="${SDK}"
  -extra-arg=-mmacosx-version-min="${DEPLOY}"
  -extra-arg=-std=c99
  -extra-arg=-fobjc-arc
  -extra-arg=-I"${ROOT}"
  -extra-arg=-I"${ROOT}/macos"
  -extra-arg=-I"${ROOT}/macos/platform"
  -extra-arg=-I"${ROOT}/macos/bridge"
  -extra-arg=-I"${ROOT}/terminal"
  -extra-arg=-I"${ROOT}/charset"
  -extra-arg=-DHAVE_CMAKE_H
  -extra-arg=-DHAVE_CMAKE_H=1
)

# Prefer a build tree that provides cmake.h + compile_commands.json.
compile_db=
cmake_h_dir=
for build in \
  "${PUTTY_CLANG_TIDY_BUILD_DIR:-}" \
  build-macos-gui-dev \
  build-macos-gui \
  build-macos-gui-asan \
  build-macos-gui-tsan
do
  [[ -n ${build} ]] || continue
  local_root=
  if [[ ${build} == /* && -d ${build} ]]; then
    local_root=${build}
  elif [[ -d ${ROOT}/${build} ]]; then
    local_root=${ROOT}/${build}
  fi
  [[ -n ${local_root} ]] || continue
  if [[ -z ${cmake_h_dir} && -f ${local_root}/CMakeFiles/cmake.h ]]; then
    cmake_h_dir=${local_root}/CMakeFiles
  fi
  if [[ -z ${compile_db} && -f ${local_root}/compile_commands.json ]]; then
    compile_db=${local_root}
  fi
done

if [[ -n ${cmake_h_dir} ]]; then
  extra+=(-extra-arg=-I"${cmake_h_dir}")
fi

ec=0
if [[ -n ${compile_db} ]]; then
  printf '    using compile_commands.json from %s (+ SDK extra-args)\n' "${compile_db}"
  for src in "${sources[@]}"; do
    if ! "${TIDY}" "${extra[@]}" -p "${compile_db}" "${ROOT}/${src}"; then
      ec=1
    fi
  done
else
  printf '    no compile_commands.json; using explicit -extra-arg flags\n'
  for src in "${sources[@]}"; do
    if ! "${TIDY}" "${extra[@]}" "${src}" --; then
      ec=1
    fi
  done
fi

if ((ec != 0)); then
  printf 'clang-tidy: findings (exit %d)\n' "${ec}" >&2
fi
exit "${ec}"
