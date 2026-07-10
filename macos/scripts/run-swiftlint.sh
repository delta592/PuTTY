#!/usr/bin/env bash
# Run SwiftLint over macos/**/*.swift (config: macos/.swiftlint.yml).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
MACOS=${ROOT}/macos
cd -- "${MACOS}"

if ! command -v swiftlint >/dev/null 2>&1; then
  printf 'error: swiftlint not found; install with: brew install swiftlint\n' >&2
  exit 1
fi

exec swiftlint lint --config .swiftlint.yml --strict
