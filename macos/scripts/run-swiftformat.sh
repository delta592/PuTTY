#!/usr/bin/env bash
# Run SwiftFormat over macos/**/*.swift (config: macos/.swiftformat).
# Usage: run-swiftformat.sh --lint | --apply
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd -- "${ROOT}"

mode=${1:---lint}

if ! command -v swiftformat >/dev/null 2>&1; then
  printf 'error: swiftformat not found; install with: brew install swiftformat\n' >&2
  exit 1
fi

case ${mode} in
  --lint)
    exec swiftformat macos --config macos/.swiftformat --lint
    ;;
  --apply)
    exec swiftformat macos --config macos/.swiftformat
    ;;
  *)
    printf 'usage: %s --lint | --apply\n' "$0" >&2
    exit 2
    ;;
esac
