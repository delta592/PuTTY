# Printing (Phase 9.4)

Two printing paths on macOS:

1. **Remote-controlled ANSI printing** — same Conf / escape-sequence model
   as Unix GTK (`CONF_printer`).
2. **Session transcript** — **File → Print…** (⌘P) via `NSPrintOperation`.

## Remote-controlled printing

When the remote host sends ANSI printer sequences, PuTTY pipes the data to
the command configured under **Terminal → Remote-controlled printing**.

| Platform | `CONF_printer` meaning |
|----------|------------------------|
| Unix GTK | Shell command (e.g. `lpr`) |
| macOS | Same: shell command via `popen` (typically `lpr` under CUPS) |
| Windows | Named Windows printer |

There is **no printer drop-down** on macOS (same as Unix). Enter a command
such as `lpr` or `lpr -P MyPrinter`. Leave empty / “None” to disable.

Implementation: [`macos/platform/printing.c`](platform/printing.c).

## Session transcript (File → Print)

**File → Print…** extracts scrollback + screen text (same extent as
**Edit → Copy All**) and runs `NSPrintOperation` on a monospaced
`NSTextView`. **Page Setup…** (⇧⌘P) opens the system page layout panel.

This does **not** use `CONF_printer`; it always uses the macOS print
panel (PDF, AirPrint, etc.).

| Piece | Role |
|-------|------|
| `putty_bridge_termwin_get_all_text` | UTF-8 transcript (free with `putty_bridge_free_string`) |
| `TerminalView.printView(_:)` (ObjC `print:`) | Responder-chain handler for File → Print |
| `TerminalPrint` | Builds the printable view / runs `NSPrintOperation` |

## Smoke / tests

```bash
./macos/build.sh test   # includes putty-mac-printing-smoke-c
# or:
ctest --test-dir <build> -R printing -V
```

XCTest `PrintingTests` covers File menu wiring, transcript extraction, and
printable-view construction (no print panel).

## Manual checklist

- [ ] Settings → Terminal → set printer command to `lpr` (or leave disabled)
- [ ] File → Print… (⌘P) opens the print panel with session text
- [ ] Page Setup… (⇧⌘P) opens page layout
- [ ] Print to PDF produces readable monospaced transcript

## Related

- [`INTEGRATION.md`](INTEGRATION.md) — menus / Edit chain
- `PuttyMacUI/TerminalPrint.swift`, `PuttyStandardMenus.swift`
