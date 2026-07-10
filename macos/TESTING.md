# Manual QA matrix (Phase 9.1)

Automated coverage lives in CTest (`./macos/build.sh test`). This checklist
covers host / display combinations that CI cannot fully exercise.

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
