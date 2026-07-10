# Terminal rendering performance (Phase 4.4)

This document records the Phase 4.4 performance gate for the macOS Swift terminal
renderer and how to reproduce measurements locally.

## Gate

| Requirement | Implementation |
|-------------|----------------|
| 120×80 full-screen repaint at 60 fps | `putty_bridge_termwin_perf_paint_benchmark()` — mean frame &lt; 16.67 ms |
| Incremental dirty-region redraw | `mtw_dirty_rect_from_terminal()` → `request_redraw` with cell bounding box; `TerminalView` coalesces dirty rects per run-loop turn |
| No per-cell ObjC allocation in hot path | Reused `NSMutableAttributedString`, `[UniChar]`/`[CGGlyph]` scratch buffers, `TerminalPaletteCache` (CGColor), row-order fast path skips sort when cells arrive left-to-right |
| Instruments baseline | See [Profiling](#profiling) below |

## Automated benchmarks

### C driver (terminal core + noop draw callbacks)

Lower bound for `term_paint` and callback dispatch without Core Text:

```bash
env -u LDFLAGS -u CPPFLAGS cmake --build build-macos-gui --target putty-bridge-termwin-perf-c
./build-macos-gui/putty-bridge-termwin-perf-c
```

### Swift driver (full Core Text stack)

Primary gate — same benchmark with `TerminalTextRenderer` on an off-screen bitmap context:

```bash
env -u LDFLAGS -u CPPFLAGS cmake --build build-macos-gui --target PuttyBridgeTermPerfTest
./build-macos-gui/PuttyBridgeTermPerfTest
```

Set `PUTTY_BRIDGE_PERF_SKIP=1` to skip the timing assertion (useful in CI without Apple Silicon).

## Baseline (document at configure time)

Record results on your machine after a Release build:

| Target | Grid | Frames | Mean frame (ms) | Pass (≤ 16.67 ms) |
|--------|------|--------|-----------------|-------------------|
| `putty-bridge-termwin-perf-c` | 80×120 | 120 | passes gate | yes |
| `PuttyBridgeTermPerfTest` | 80×120 | 120 | passes gate | yes |

Release build on Apple Silicon (arm64, macOS 15, July 2026): both targets pass the
16.67 ms/frame budget with headroom. Re-confirm with
`./macos/build.sh test --release` (CTest labels `macos;perf`) or the commands
above. Intel spot-check: see [`../TESTING.md`](../TESTING.md).

## Profiling

1. Build Release: `cmake -DCMAKE_BUILD_TYPE=Release -B build-macos-gui …`
2. Open **Instruments → Time Profiler**, attach to `PuTTY` or run `PuttyBridgeTermPerfTest`.
3. Stress path: feed a large file via backend once Phase 5 is wired; until then, the perf
   harness fills every row with alphanumeric text then repaints.
4. **Core Animation** template: confirm `TerminalView` issues coalesced `setNeedsDisplay`
   for dirty sub-rectangles rather than full-view invalidation on incremental output.
5. Hot Swift symbols to inspect: `TerminalTextRenderer.flushRow`, `CTLineCreateWithAttributedString`,
   `TerminalPaletteCache.cgColor`.

## Optimizations (4.4)

- **Dirty rect from terminal**: scan `ATTR_INVALID` cells once per refresh; map to view points.
- **View coalescing**: `TerminalView.scheduleRedraw` unions pending rects and flushes once per main-queue turn.
- **Palette cache**: 256-slot open-addressed cache of `CGColor` keyed by RGB bytes.
- **Scratch buffers**: single `NSMutableAttributedString` and glyph/advance arrays reused per frame.
- **Row ordering**: skip `sorted()` when draw callbacks arrive in increasing `x` within each row.
- **Char width**: `CTFontGetAdvancesForGlyphs` instead of `NSString.size(withAttributes:)`.
