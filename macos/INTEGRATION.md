# macOS 15 integration (Phase 9.3)

AppKit HIG alignment for Settings placement, system accent chrome,
trackpad scroll momentum, and the Edit menu responder chain.

## Settings placement

PuTTY remains an **AppKit** app (not SwiftUI `Settings` scenes). The
macOS Settings pattern is applied as:

| Location | Item | Shortcut |
|----------|------|----------|
| Application menu | **Settings…** | ⌘, |
| Application menu | **About …** | — |
| Session menu | Change Settings… | (alias, no shortcut) |

Mid-session config windows are titled `«App» Settings` with a toolbar
label **Settings** (pre-session stays **Session Settings**). The sidebar
+ toolbar layout from Phase 6.2 is unchanged.

## System accent colour

`AccentColor` in `Assets.xcassets` is the empty system-accent placeholder.
Chrome code uses `NSColor.controlAccentColor` via `PuttyChrome`:

- Config / Event Log / session container bezels
- Config toolbar title tint
- Outline selection continues to use the system highlight (accent)

**Not affected:** the terminal OSC4 / Conf colour palette.

## Trackpad scroll momentum

`TerminalScrollInput` converts wheel events to terminal lines:

- **Precise** (trackpad): accumulate points; one line per cell height so
  inertial `momentumPhase` events keep scrolling smoothly.
- **Non-precise** (mouse wheel): fixed 3-point ticks (Phase 4 behaviour).
- Cancelled gestures clear the fractional accumulator.

Phase 4 scrollbar / resize smoke (`putty-bridge-termwin-scroll-resize-smoke-c`)
remains the C-level gate; XCTest `IntegrationTests` covers the delta math.

## Edit menu

**Edit → Copy / Paste / Paste Special / Select All / Copy All** use a nil
target so AppKit sends actions down the responder chain to `TerminalView`
(`copy:`, `paste:`, `pasteSpecial:`, `selectAll:`, `copyAll:`). ⌘C / ⌘V /
⌘A / ⌥⌘V also work via `performKeyEquivalent`.

## Manual checklist

- [ ] App menu **Settings…** (⌘,) opens mid-session settings for the key window
- [ ] System Settings → Appearance → Accent Colour changes config chrome tint
- [ ] Trackpad flick scrolls scrollback with inertia; mouse wheel still ticks
- [ ] Edit → Copy / Paste with a selection and clipboard text
- [ ] Terminal palette unchanged when accent colour changes

## Related

- [`ACCESSIBILITY.md`](ACCESSIBILITY.md) — VoiceOver / Reduce Motion / Increase Contrast
- [`TESTING.md`](TESTING.md) — CTest / XCTest
- `PuttyMacUI/PuttyStandardMenus.swift`, `PuttyChrome.swift`, `TerminalScrollInput.swift`
