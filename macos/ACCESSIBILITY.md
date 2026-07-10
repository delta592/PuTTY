# macOS accessibility (Phase 9.2)

How the native AppKit GUI exposes itself to VoiceOver, keyboard navigation,
and System Settings display options.

## VoiceOver and the terminal

`TerminalView` is a custom character-grid surface, not an `NSTextView`.
VoiceOver therefore receives a **limited** description:

| Property | Value |
|----------|--------|
| Role | text area (`terminal`) |
| Label | `Terminal` |
| Value | Session window title |
| Help | Explains that session output is not a navigable document |

**Limitation (by design):** VoiceOver cannot read remote/local session
output line-by-line the way it can read a text document. Practical
alternatives:

1. Select text in the terminal and **Copy** (clipboard is accessible).
2. Open **Session → Event Log** for a searchable, selectable history.
3. Use a screen reader–friendly editor or pager on the remote host when
   reviewing large amounts of text.

The scrollback scroller is labelled `Terminal scrollback`.

## Keyboard navigation

Dialogs set `initialFirstResponder`, enable
`autorecalculatesKeyViewLoop`, and recalculate the loop after layout:

| Surface | First focus | Notes |
|---------|-------------|--------|
| Configuration / Change Settings | Category outline | Tab moves through sidebar and controls; Return/Escape map to default/cancel |
| Host CA box | Content stack | Same control labelling as config |
| Username / password prompts | First field | Labels linked via `accessibilityTitleUIElement` |
| Askpass | Secure field | Already focused before `runModal` |
| Event Log | Filter field | Then Tab into the log text |
| PuTTYgen | Key type popup | All primary controls have accessibility labels |

Static labels refuse first responder so Tab skips them. macOS **Full
Keyboard Access** (System Settings → Keyboard) is still required to Tab
to every control type; text fields and buttons work with the default
keyboard settings.

## Reduce Motion

When **Reduce Motion** is enabled:

- Session and config windows keep `animationBehavior = .none` (also
  required to avoid AppKit window-transform crashes on open).
- Window frame changes use `animate: false`.
- **Visual bell** (`BELL_VISUAL`) still triggers the terminal engine’s
  reverse-video flash (implemented in portable `terminal.c`), but the
  front end also plays a system beep so the cue is not solely visual.

## Increase Contrast

When **Increase Contrast** is enabled, **chrome** borders are
strengthened (config split/scroll views, session container, Event Log
scroll view). The **terminal colour palette is not altered** — palette
contrast remains a Conf / Colour panel concern (see Phase 9.3 for system
accent colour on chrome).

`TerminalScrollContainer` observes
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and
refreshes chrome when the user toggles these settings while a session is
open.

## Manual audit checklist

- [ ] VoiceOver: open a session; rotor / VO focus announces “Terminal”.
- [ ] VoiceOver: Event Log filter and entries are reachable.
- [ ] Keyboard: Tab through Configuration categories and a settings panel;
      Open / Cancel via Return / Escape.
- [ ] Keyboard: password prompt — Tab between fields, Return submits.
- [ ] Reduce Motion on: open session from config (no zoom animation);
      visual bell produces a beep.
- [ ] Increase Contrast on: config sidebar/content bezels visibly stronger;
      terminal colours unchanged.

## Related

- [`TESTING.md`](TESTING.md) — automated + manual QA matrix
- [`../MACOS_GUI_PLAN.md`](../MACOS_GUI_PLAN.md) — Phase 9.2
- `PuttyMacUI/PuttyAccessibility.swift` — shared prefs helpers
