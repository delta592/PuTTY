# Manual QA matrix (Phase 9.1) and quality tooling

Automated tests live in CTest (`./macos/build.sh test` or `make test`).
This checklist covers host / display combinations that CI cannot fully
exercise, plus sanitizers, coverage, and macos/-scoped lint/analysis.

## Make / CMake test targets

From the repository root:

| Target | What it runs |
|--------|----------------|
| `make test` | CTest `-L macos` (unit + crypt + perf + ui) |
| `make test-unit` | CTest `-L unit` |
| `make test-crypt` | CTest `-L crypt` |
| `make test-perf` | CTest `-L perf` (Phase 4 paint budget — keep this gate) |
| `make test-ui` | CTest `-L xctest` |
| `make test-thread` | CTest `-L thread` (TSan-oriented smokes) |
| `make test-utils` | Portable utils binaries not in CTest |
| `make test-all` | Every test process, in order: `test`, `test-utils`, `asan`, `tsan`, `coverage`, `coverage-swift`, `quality`, `analyze-c` |
| `make help` | List targets |

CMake equivalents: `putty-test-macos`, `putty-test-unit`, `putty-test-crypt`,
`putty-test-perf`, `putty-test-ui`, `putty-test-thread`, `putty-test-utils`,
`putty-test-all` (`cmake --build <build-dir> --target …`).

`test-utils` runs self-contained root binaries (`test_host_strfoo`,
`test_decode_utf8`, `test_tree234`, `test_wildcard`, `test_cert_expr`).
`test_unicode_norm` and `bidi_test` need external UCD fixtures and are
not included.

## Coverage and sanitizers

Use **separate Debug, host-arch** trees. Do not enable sanitizers on
Universal release / notarized builds. Do not combine sanitizers with
coverage in one tree.

| Target | CMake options | Runs |
|--------|---------------|------|
| `make coverage` | `PUTTY_COVERAGE=ON` | CTest `unit\|crypt` (C/ObjC `.gcda`) |
| `make coverage-swift` | `PUTTY_COVERAGE` + `PUTTY_SWIFT_COVERAGE` | `unit\|crypt\|xctest` + `llvm-cov` report for PuttyMacUI |
| `make asan` / `make ubsan` | `PUTTY_SANITIZE=address,undefined` | CTest `-L unit` |
| `make tsan` | `PUTTY_SANITIZE=thread` | CTest `-L thread` |

CMake cache knobs (also passable as `-D` to `./macos/build.sh`):

- `PUTTY_SANITIZE` — empty, `address`, `undefined`, `address,undefined`, or `thread`
- `PUTTY_COVERAGE` — C/ObjC `--coverage`
- `PUTTY_SWIFT_COVERAGE` — Swift `-profile-generate` / `-profile-coverage-mapping`

Default build dirs: `build-macos-gui-coverage`,
`build-macos-gui-coverage-swift`, `build-macos-gui-asan`,
`build-macos-gui-tsan`.

## Lint and static analysis (macos/ only)

These tools **must not** reformat or tidy upstream root `*.c` / `unix/` /
`windows/`. Optional `macos/.clang-format` exists for *new* macos C only
and is not wired to a default `make` target.

| Target | Tool | Config |
|--------|------|--------|
| `make lint-swift` | SwiftLint | `macos/.swiftlint.yml` |
| `make format-swift` | SwiftFormat `--lint` | `macos/.swiftformat` |
| `make format-swift-apply` | SwiftFormat `--apply` | same |
| `make tidy-c` | clang-tidy | `macos/.clang-tidy` (narrow checks; no sizeof/macro FP noise) |
| `make analyze-c` | `clang --analyze` | artifacts under `build-macos-gui-analyze/` |
| `make quality` | lint + format-lint + tidy | |

Install helpers (Homebrew):

```sh
brew install swiftlint swiftformat llvm
```

CMake custom targets (same scripts): `putty-macos-swiftlint`,
`putty-macos-swiftformat`, `putty-macos-clang-tidy`,
`putty-macos-clang-analyze`, `putty-macos-quality`.

## Architectures

| Scenario | How | Pass criteria |
|----------|-----|---------------|
| Native Apple Silicon | Host-arch Release or Debug build; run `./macos/build.sh test --release` | All `macos` CTest labels green; `PuttyBridgeTermPerfTest` passes without `PUTTY_BRIDGE_PERF_SKIP` |
| Native Intel | Same on an Intel Mac (x86_64 slice) | Same; perf may be spot-checked with `PUTTY_BRIDGE_PERF_SKIP=0` |
| Cross-arch Universal 2 | Build `--universal`; copy `PuTTY.app` to the other arch; open and connect | App launches under Rosetta or native slice; `lipo -info` shows `x86_64` and `arm64` |

## Display / Spaces

- [ ] Light Appearance — terminal palette and chrome readable
- [ ] Dark Appearance — same; system chrome follows appearance
- [ ] Multiple monitors — drag session window; font metrics / backing scale OK on each display
- [ ] Mission Control Spaces — move window between Spaces; session stays connected

## Performance gate (Phase 4)

Keep the existing paint-budget gate; do not replace it with generic
`swift-benchmark` / XCTest `measure {}` unless measuring a specific
Swift helper. On Apple Silicon (required):

```sh
./macos/build.sh build --release
cmake --build build-macos-gui --target PuttyBridgeTermPerfTest putty-bridge-termwin-perf-c
./build-macos-gui/putty-bridge-termwin-perf-c
./build-macos-gui/PuttyBridgeTermPerfTest
# or: make test-perf PROFILE=release
```

Mean frame must stay ≤ 16.67 ms (see [`PuTTY/TERMINAL_PERFORMANCE.md`](PuTTY/TERMINAL_PERFORMANCE.md)).

On Intel: run the same binaries once as a spot-check; set
`PUTTY_BRIDGE_PERF_SKIP=1` only if the machine is too slow for the budget
(document the measured mean if skipped).

## Sign-off

| Date | Machine | Arch | Tester | Notes |
|------|---------|------|--------|-------|
| 2026-07-09 | intrepid (this tree) | arm64 | automated | `./macos/build.sh test --dev`: 29/29 CTest (incl. XCTest + perf) |
| | | x86_64 native | | Pending physical Intel Mac |
| | | Universal cross-copy | | Pending second machine |

## Accessibility (Phase 9.2)

Automated: `AccessibilityTests` in `PuttyMacUITests` (VoiceOver identity on
`TerminalView`, Event Log first responder). Manual VoiceOver / Reduce
Motion / Increase Contrast checklist: [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

## macOS 15 integration (Phase 9.3)

Automated: `IntegrationTests` (scroll delta math, Edit menu selectors,
Settings menu placement, accent colour). Manual Settings / accent /
trackpad / Edit checklist: [`INTEGRATION.md`](INTEGRATION.md).
