# Manual QA matrix (Phase 9.1)

Automated coverage lives in CTest (`./macos/build.sh test` or `make test`).
This checklist covers host / display combinations that CI cannot fully
exercise.

## Make / CMake test targets

From the repository root:

| Target | What it runs |
|--------|----------------|
| `make test` | CTest `-L macos` (unit + crypt + perf + ui) |
| `make test-unit` | CTest `-L unit` |
| `make test-crypt` | CTest `-L crypt` |
| `make test-perf` | CTest `-L perf` |
| `make test-ui` | CTest `-L xctest` |
| `make test-utils` | Portable utils binaries not in CTest |
| `make test-all` | `test` then `test-utils` |
| `make help` | List targets |

CMake equivalents: `putty-test-macos`, `putty-test-unit`, `putty-test-crypt`,
`putty-test-perf`, `putty-test-ui`, `putty-test-utils`, `putty-test-all`
(`cmake --build <build-dir> --target …`).

`test-utils` runs self-contained root binaries (`test_host_strfoo`,
`test_decode_utf8`, `test_tree234`, `test_wildcard`, `test_cert_expr`).
`test_unicode_norm` and `bidi_test` need external UCD fixtures and are
not included.

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

On Apple Silicon (required):

```sh
./macos/build.sh build --release
cmake --build build-macos-gui --target PuttyBridgeTermPerfTest putty-bridge-termwin-perf-c
./build-macos-gui/putty-bridge-termwin-perf-c
./build-macos-gui/PuttyBridgeTermPerfTest
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
