# Help (Phase 9.5)

Bundled **PuTTY User Manual** (Halibut HTML from `doc/`) and the
**Help → … Help** menu.

## Bundled HTML

When Halibut and Perl are available at configure time, CMake builds the
same HTML manual as `make doc` (`doc/html/index.html` and chapter pages)
and copies it into each GUI `.app`:

```
PuTTY.app/Contents/Resources/Help/
  index.html
  Chapter1.html
  …
```

| Piece | Role |
|-------|------|
| `doc/CMakeLists.txt` | Exports `PUTTY_DOC_HAS_HTML` / `PUTTY_DOC_HTML_DIR` |
| `macos/cmake/help.cmake` | `putty_macos_add_help()` POST_BUILD copy into Resources |
| `verify-bundle-layout` | Requires `Help/index.html` when Halibut HTML was built |

Without Halibut, apps still build; **Help → … Help** opens the [online
manual](https://the.earth.li/~sgtatham/putty/latest/htmldoc/).

Install Halibut for local help:

```sh
brew install halibut
```

## Help menu / WebKit viewer

| App | Menu item |
|-----|-----------|
| PuTTY | **Help → PuTTY Help** (`?`) |
| pterm | **Help → pterm Help** |
| PuTTYgen | **Help → PuTTYgen Help** |

Opening the item shows an embedded `WKWebView` window
(`HelpWindowController`) loading `Resources/Help/index.html`. Local
chapter links stay in-app; `http(s)` links open in the default browser.

Alert **Help** buttons (`seat-dialogs.m`) post `PuTTYOpenBundledHelp`,
which `PuttyHelp` observes and routes to the same window.

| Piece | Role |
|-------|------|
| `PuttyMacUI/PuttyHelp.swift` | Locate bundle HTML / open / notification |
| `PuttyMacUI/HelpWindowController.swift` | `WKWebView` window |
| `PuttyStandardMenus.installHelpMenu` | Menu wiring (PuTTY / pterm) |

## Tests

```bash
./macos/build.sh test --dev
# or:
ctest --test-dir build-macos-gui-dev -R 'Help|bundle' -V
cmake --build build-macos-gui-dev --target verify-bundle-layout
```

XCTest `HelpTests` covers menu wiring and help-window construction.

## Manual checklist

- [ ] **Help → PuTTY Help** opens a window with the manual contents
- [ ] Chapter links navigate inside the window
- [ ] External `https://` links open in the browser
- [ ] Alert Help button opens the same help window
- [ ] `PuTTY.app/Contents/Resources/Help/index.html` exists after build
- [ ] Same for pterm.app and puttygen.app

## Related

- [`INTEGRATION.md`](INTEGRATION.md) — menus
- [`TESTING.md`](TESTING.md) — CTest / XCTest
- `doc/` — Halibut sources
