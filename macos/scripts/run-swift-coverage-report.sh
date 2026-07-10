#!/usr/bin/env bash
# Merge Swift/C LLVM profile data and print a PuttyMacUI-focused report.
#
# Expects a coverage build tree configured with:
#   -DPUTTY_COVERAGE=ON -DPUTTY_SWIFT_COVERAGE=ON
# and CTest (unit + xctest) already run so .gcda / default.profraw exist.
#
# Usage:
#   run-swift-coverage-report.sh <build-dir>
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
BUILD=${1:-${ROOT}/build-macos-gui-coverage-swift}

if [[ ! -d ${BUILD} ]]; then
  printf 'error: build dir missing: %s\n' "${BUILD}" >&2
  exit 1
fi

PROFDATA=${BUILD}/putty-macos.profdata
REPORT_DIR=${BUILD}/coverage-report
mkdir -p -- "${REPORT_DIR}"

mapfile -t profraw < <(find "${BUILD}" -name '*.profraw' 2>/dev/null | LC_ALL=C sort)
if ((${#profraw[@]} == 0)); then
  # XCTest / Swift may write under $PWD or LLVM_PROFILE_FILE.
  mapfile -t profraw < <(find "${ROOT}" -maxdepth 2 -name '*.profraw' 2>/dev/null | LC_ALL=C sort)
fi

if ((${#profraw[@]} == 0)); then
  printf 'error: no .profraw files found under %s (run XCTest with PUTTY_SWIFT_COVERAGE=ON)\n' \
    "${BUILD}" >&2
  exit 1
fi

printf '==> merging %d profraw -> %s\n' "${#profraw[@]}" "${PROFDATA}"
xcrun llvm-profdata merge -sparse "${profraw[@]}" -o "${PROFDATA}"

# Prefer the XCTest bundle binary; fall back to any PuttyMacUITests product.
mapfile -t bins < <(
  find "${BUILD}" \( -name 'PuttyMacUITests' -o -name 'PuttyMacUITests.xctest' \) \
    2>/dev/null | LC_ALL=C sort
)

bin=
for cand in "${bins[@]}"; do
  if [[ -d ${cand} && -f ${cand}/Contents/MacOS/PuttyMacUITests ]]; then
    bin=${cand}/Contents/MacOS/PuttyMacUITests
    break
  elif [[ -x ${cand} && -f ${cand} ]]; then
    bin=${cand}
    break
  fi
done

if [[ -z ${bin} ]]; then
  printf 'error: PuttyMacUITests binary not found under %s\n' "${BUILD}" >&2
  exit 1
fi

printf '==> llvm-cov report (%s)\n' "${bin}"
xcrun llvm-cov report \
  "${bin}" \
  -instr-profile="${PROFDATA}" \
  -ignore-filename-regex='/.build/|DerivedData|XCTest|swift/stdlib' \
  | tee "${REPORT_DIR}/summary.txt"

xcrun llvm-cov show \
  "${bin}" \
  -instr-profile="${PROFDATA}" \
  -ignore-filename-regex='/.build/|DerivedData|XCTest|swift/stdlib' \
  -format=html \
  -output-dir="${REPORT_DIR}/html" \
  >/dev/null

printf 'coverage-swift: summary %s\n' "${REPORT_DIR}/summary.txt"
printf 'coverage-swift: html    %s/html/index.html\n' "${REPORT_DIR}"
