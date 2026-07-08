# macOS Native GUI Plan (Swift / AppKit)

This document describes a phased plan to add a **fully native macOS GUI** to PuTTY using **Swift and AppKit**, integrated with the project's existing **CMake** build system. It assumes a **minimum deployment target of macOS 15.x** (Sequoia).

The plan treats macOS as a **third front-end platform** alongside the existing **Win32** (`windows/`) and **GTK/Unix** (`unix/`) implementations, reusing the portable C core and the `Seat` / `TermWin` / `LogPolicy` vtable boundaries defined in `putty.h`.

---

## Background and design rationale

### What already exists

| Layer | Location | Reusable for macOS GUI? |
|-------|----------|-------------------------|
| Terminal emulator | `terminal/`, `ldisc.c` | Yes — platform-agnostic |
| SSH / network / crypto | `ssh/`, `network.c`, `crypto/` | Yes |
| Settings & session files | `settings.c`, `config.c` | Yes |
| Abstract config UI model | `dialog.c`, `dialog.h`, `config.c` | Yes — render in AppKit |
| Windows GUI | `windows/window.c` (~6K lines) | Reference only |
| Unix/GTK GUI | `unix/window.c` (~5.7K lines) | Reference only — not linked |
| Unix platform C code | `unix/storage.c`, `network.c`, `pty.c`, … | Mostly — adapt into `macos/` |
| Incomplete GTK/macOS path | `unix/osxlaunch.c`, `*.bundle` | **Not used** — superseded by this plan |

### Architectural choice: new `macos/` platform

On Darwin, CMake currently selects `platform = unix`. This plan introduces:

```
cmake/setup.cmake
  ├─ Windows  → platform = windows
  ├─ Darwin + PUTTY_MACOS_GUI=ON  → platform = macos   (GUI build)
  └─ otherwise                    → platform = unix    (CLI / GTK fallback)
```

The `macos/` tree contains:

- **C platform layer** — `platform.h`, storage, network, PTY, noise, etc. (largely adapted from `unix/`, without GTK).
- **C bridge layer** — stable C API consumed by Swift (`macos/bridge/`).
- **Swift / AppKit application** — windows, menus, settings UI, terminal view (`macos/PuTTY.app/` sources).

CLI tools (`plink`, `pscp`, `psftp`, …) continue to build via the existing `unix/` platform on macOS unless/until they are moved to share the `macos/` C shims.

Release GUI builds produce **Universal 2** `.app` bundles: one fat Mach-O executable per application containing both `arm64` and `x86_64` slices, configured via `PUTTY_MACOS_UNIVERSAL` and `CMAKE_OSX_ARCHITECTURES` (see Phase 1.7 and Build system integration).

### Why not extend the GTK/macOS path?

The repository already contains an unfinished **GTK-on-Quartz** approach (`OSX_GTK`, `puttyapp`, `gtk-mac-bundler`). That path is intentionally **not** part of this plan. A native AppKit front end provides better macOS integration (menus, sandboxing, Keychain, VoiceOver, system clipboard conventions) and avoids bundling GTK.

### Lessons from the abandoned Cocoa attempt (~2005)

The project FAQ records that an earlier native Cocoa port failed due to **slow terminal redraw**. This plan explicitly addresses rendering in **Phase 4** using:

- `NSView` layer-backed drawing or `CALayer` tile cache
- **Core Text** / `CTLine` for glyph layout (with a fast path for monospace bulk redraw)
- Dirty-region tracking driven by `Terminal` refresh callbacks
- Performance gates before Phase 5 proceeds

---

## Target deliverables

At completion, a macOS GUI build should produce signed, notarized **Universal 2** `.app` bundles — each containing a single Mach-O executable with both **arm64** (Apple Silicon) and **x86_64** (Intel) slices, so one build artifact runs natively on either architecture.

| Application | Role | Priority |
|-------------|------|----------|
| **PuTTY.app** | SSH/telnet/serial GUI client | P0 |
| **pterm.app** | Local terminal emulator | P1 |
| **PuTTYgen.app** | Key generation / conversion | P2 |
| **Pageant.app** or system-agent integration | SSH agent / askpass | P2 |

CLI binaries remain available via the existing Unix platform build (single-arch per host is acceptable for CLI; GUI release artifacts must be Universal 2).

---

## Build system integration (overview)

### CMake options (new)

| Option | Default | Purpose |
|--------|---------|---------|
| `PUTTY_MACOS_GUI` | `OFF` | Enable Swift/AppKit front end on Darwin |
| `PUTTY_MACOS_DEPLOYMENT_TARGET` | `15.0` | Minimum macOS version |
| `PUTTY_MACOS_UNIVERSAL` | `ON` | Build Universal 2 binaries (`arm64` + `x86_64`) for GUI `.app` targets |
| `PUTTY_MACOS_SIGN_IDENTITY` | empty | Developer ID or ad-hoc signing identity |
| `PUTTY_MACOS_NOTarize` | `OFF` | Run notarization post-build (requires credentials) |

When `PUTTY_MACOS_UNIVERSAL=ON`, CMake sets `CMAKE_OSX_ARCHITECTURES` to `arm64;x86_64` for the GUI build, producing a **single fat Mach-O** inside each `.app` bundle (`Contents/MacOS/<executable>`). When `OFF`, only the host's native architecture is built (faster local iteration).

### Toolchain requirements

- **macOS 15+** SDK (Xcode 16 or later recommended)
- **CMake 3.28+** (matches project minimum; Swift support requires 3.15+ but recent CMake is strongly preferred)
- **Ninja** or **Xcode** generator
- **Swift 6** toolchain (bundled with Xcode 16)
- **Universal 2 builds** require an Xcode installation whose macOS SDK supports both `arm64` and `x86_64` (standard on Apple Silicon and Intel Macs with current Xcode)

### Typical build commands

```bash
# Configure GUI build — Universal 2 (default: arm64 + x86_64 in one .app)
cmake -B build-macos-gui -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_MACOS_UNIVERSAL=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

cmake --build build-macos-gui

# Verify the app executable is Universal 2
lipo -info build-macos-gui/PuTTY.app/Contents/MacOS/PuTTY
# Expected: Architectures in the fat file: x86_64 arm64

# Fast local dev build — native architecture only
cmake -B build-macos-gui-dev -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_MACOS_UNIVERSAL=OFF

cmake --build build-macos-gui-dev

# Install .app bundles to CMAKE_INSTALL_PREFIX (default /usr/local)
cmake --build build-macos-gui --target install

# CLI-only build (unchanged)
cmake -B build-macos-cli -G Ninja
cmake --build build-macos-cli
```

### High-level CMake structure (to be added)

```
cmake/platforms/macos.cmake          # Platform probes, frameworks, Swift flags
macos/CMakeLists.txt                 # C platform libs, bridge, Swift targets
macos/bridge/CMakeLists.txt          # putty-macos-bridge static library
macos/PuTTY/CMakeLists.txt           # PuTTY.app Swift target
macos/pterm/CMakeLists.txt           # pterm.app (Phase 7)
macos/puttygen/CMakeLists.txt        # PuTTYgen.app (Phase 7)
```

Key CMake settings for all GUI targets:

```cmake
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS version")
set(CMAKE_Swift_LANGUAGE_VERSION "6")

# Universal 2: one fat Mach-O with arm64 + x86_64 slices (release default)
if(PUTTY_MACOS_UNIVERSAL)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
else()
  set(CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}" CACHE STRING "" FORCE)
endif()

# Example framework linkage
target_link_libraries(putty-app PRIVATE
  "-framework AppKit"
  "-framework CoreText"
  "-framework CoreGraphics"
  "-framework Security"
  "-framework ServiceManagement"
  putty-macos-bridge
  guiterminal eventloop sshclient otherbackends settings network crypto utils charset
)
```

All static libraries linked into GUI `.app` targets inherit `CMAKE_OSX_ARCHITECTURES`, so the final bundle executable contains matching slices for C, Objective-C, and Swift object code without a separate `lipo` merge step.

---

## Phase 1 — Project scaffolding and build plumbing

**Goal:** A macOS 15-targeting CMake configuration that compiles and links the existing C core against a stub AppKit application shell.

### 1.1 Repository layout

- [x] Create `macos/` top-level platform directory.
- [x] Create subdirectories:
  - `macos/bridge/` — C headers and glue for Swift
  - `macos/platform/` — C files adapted from `unix/` (non-GTK)
  - `macos/PuTTY/` — PuTTY.app Swift sources, assets, `Info.plist`
  - `macos/pterm/` — placeholder for Phase 7
  - `macos/puttygen/` — placeholder for Phase 7
  - `macos/Resources/` — shared `.xcassets`, localizable strings
- [x] Add `cmake/platforms/macos.cmake` parallel to `unix.cmake` / `windows.cmake`.

### 1.2 CMake platform selection

- [x] Extend `cmake/setup.cmake` to set `platform` to `macos` when `PUTTY_MACOS_GUI` is `ON` and `CMAKE_SYSTEM_NAME` matches `Darwin`.
- [x] Add `add_subdirectory(macos)` from root `CMakeLists.txt` when `platform STREQUAL macos`.
- [x] Guard GUI targets so Linux/Windows configures remain unaffected.
- [x] Set `CMAKE_OSX_DEPLOYMENT_TARGET` to **15.0** by default via `PUTTY_MACOS_DEPLOYMENT_TARGET`.

### 1.3 Swift toolchain activation

- [x] Call `enable_language(OBJC OBJCXX Swift)` from `macos/CMakeLists.txt`.
- [x] Set `CMAKE_Swift_LANGUAGE_VERSION` to 6.
- [x] Configure Swift module search paths to find `PuttyBridge` module.
- [ ] Verify both **Ninja** and **Xcode** generators with a CI matrix entry (Phase 10). _(Verified locally with Ninja and Xcode; CI matrix deferred to Phase 10.)_

### 1.4 Stub application target

- [x] Add `PuTTY.app` CMake target producing a minimal `NSApplication` that launches an empty `NSWindow`.
- [x] Embed `Info.plist` with:
  - `LSMinimumSystemVersion` = `15.0`
  - Bundle identifier e.g. `org.tartarus.projects.putty.macputty`
  - Application category `public.app-category.developer-tools`
- [x] Link stub app against core static libraries (`utils`, `eventloop`, …) to validate the link graph early.
- [x] Add `BUILDINFO_PLATFORM "macOS (AppKit)"` define in `macos/platform.h`.

### 1.5 Icon and asset pipeline

- [ ] Integrate `icons/macicon.py` into CMake custom commands to generate `PuTTY.icns` / `Pterm.icns`.
- [ ] Add generated `.icns` files to app bundle `Resources/`.
- [ ] Create `Assets.xcassets` for accent colours / dark-mode toolbar icons (macOS 15 appearance).

### 1.6 Documentation and developer setup

- [ ] Add a **Building on macOS (GUI)** section to `README` referencing this plan.
- [ ] Document required Xcode version, command-line tools, and `xcode-select` setup.
- [ ] Document coexistence: GUI build (`PUTTY_MACOS_GUI=ON`) vs CLI/GTK build (default `unix`).
- [ ] Document Universal 2 vs single-arch dev builds (`PUTTY_MACOS_UNIVERSAL=ON/OFF`) and the `lipo -info` verification step.

### 1.7 Universal Binary (Universal 2) configuration

- [ ] Add `PUTTY_MACOS_UNIVERSAL` cache option (default `ON`) to `cmake/platforms/macos.cmake`.
- [ ] When `PUTTY_MACOS_UNIVERSAL=ON`, set `CMAKE_OSX_ARCHITECTURES` to `arm64;x86_64` for the GUI build tree.
- [ ] When `PUTTY_MACOS_UNIVERSAL=OFF`, default to the host native architecture only (fast iteration).
- [ ] Ensure `CMAKE_OSX_ARCHITECTURES` is applied before any target is defined so all C/Swift static libraries and `.app` executables share the same slice set.
- [ ] Add a CMake custom target (e.g. `verify-universal`) that runs `lipo -info` on each GUI `.app` executable and fails if either `arm64` or `x86_64` is missing.

**Phase 1 exit criteria:** `cmake --build` produces `PuTTY.app` that launches on macOS 15+, links the PuTTY C libraries, and displays an empty window. With `PUTTY_MACOS_UNIVERSAL=ON`, `lipo -info` reports both `arm64` and `x86_64` slices in `PuTTY.app/Contents/MacOS/PuTTY`.

---

## Phase 2 — C platform layer (`macos/platform/`)

**Goal:** Implement everything `putty.h` expects from `platform.h` and the platform-specific modules, without any UI toolkit.

### 2.1 `macos/platform.h`

- [ ] Define macOS types: `Filename`, `FontSpec`, clipboard constants, `BUILDINFO_PLATFORM`.
- [ ] Set macOS-appropriate defaults (system clipboard only — no X11 PRIMARY selection).
- [ ] Declare front-end entry points: `setup()`, `cleanup_exit()`, `initial_config_box()`, session launch helpers.
- [ ] Declare `MacGuiSeat` / `MacTermWin` opaque structs (mirroring `WinGuiSeat` in `windows/win-gui-seat.h`).
- [ ] Add `PLATFORM_CLIPBOARDS` mapping to NSPasteboard general / find pasteboards.
- [ ] Extend `cmake/cmake.h.in` with any macOS-specific `#cmakedefine` symbols.

### 2.2 Port Unix platform C modules (non-GTK)

Adapt from `unix/` with minimal changes:

| Source (unix/) | macos/platform/ | Notes |
|----------------|-----------------|-------|
| `storage.c` | `storage.c` | Use `~/Library/Application Support/PuTTY/` for sessions |
| `network.c`, `fd-socket.c` | same | Reuse directly |
| `agent-socket.c`, `agent-client.c` | same | Unix domain sockets — reuse |
| `peerinfo.c`, `local-proxy.c` | same | Reuse |
| `noise.c`, `keygen-noise.c` | same | Reuse |
| `unicode.c` | same | Reuse |
| `pty.c` | `pty.c` | Use `posix_openpt`; **no** setuid (macOS restriction, cf. `NO_PTY_PRE_INIT`) |
| `serial.c` | same | Reuse if IOKit serial APIs match; verify `/dev/cu.*` paths |
| `gss.c` | same | Optional Kerberos via Heim/MIT frameworks |
| `sharing.c`, `x11.c` | `x11.c` optional | X11 forwarding via `$DISPLAY`; lower priority on macOS |
| `console.c` | `console.c` | For any CLI fallbacks |
| `cliloop.c`, `uxsel.c` | same | Reuse — GUI integrates via Phase 5 event loop |

- [ ] Add `macos/CMakeLists.txt` `add_sources_from_current_dir` blocks mirroring `unix/CMakeLists.txt` but **excluding** all GTK files.
- [ ] Link `charset` into `utils` the same way root `CMakeLists.txt` does for `unix`.

### 2.3 Storage paths and sandboxing

- [ ] Define canonical paths:
  - Sessions: `~/Library/Application Support/PuTTY/sessions/`
  - Host keys: `~/Library/Application Support/PuTTY/sshhostkeys`
  - Random seed: `~/Library/Application Support/PuTTY/putty.rnd`
  - Logs: user-configured; default under `~/Documents/` or app container if sandboxed
- [ ] Document entitlements required if App Sandbox is enabled (Phase 9).
- [ ] Implement `cleanup_all()` for macOS (registry equivalent: remove Application Support tree).

### 2.4 Font and filename helpers

- [ ] Implement `FontSpec` using PostScript / SF Mono family names.
- [ ] Implement `filename_from_str` / `filename_to_str` using UTF-8 paths.
- [ ] Wire `f_open()` with `fopen` and appropriate privacy flags.

### 2.5 Utility sources

- [ ] Reuse applicable `unix/utils/*.c` files via shared lists or symlinks (prefer explicit list in `macos/CMakeLists.txt` to avoid pulling GTK-only utils).
- [ ] Include `unix/utils/arm_arch_queries.c` for Apple Silicon feature detection (AES/NEON paths in crypto).

### 2.6 Platform CMake probes

In `cmake/platforms/macos.cmake`:

- [ ] Run standard Unix feature checks from `unix.cmake` (poll, `posix_openpt`, `getaddrinfo`, …).
- [ ] Add `find_library` for Security, CoreFoundation, IOKit, SystemConfiguration.
- [ ] Set `NOT_X_WINDOWS` ON unconditionally.
- [ ] Wire `PUTTY_MACOS_UNIVERSAL` → `CMAKE_OSX_ARCHITECTURES` (see Phase 1.7).
- [ ] Implement `installed_program()` equivalent that installs `.app` bundles on macOS.

**Phase 2 exit criteria:** All C platform modules compile; CLI tools (`plink`, `pscp`, …) link against `macos/` platform when `PUTTY_MACOS_GUI=ON`; session files read/write under Application Support.

---

## Phase 3 — C ↔ Swift bridge

**Goal:** A stable, documented C API that lets Swift construct and drive PuTTY sessions without exposing internal struct layouts.

### 3.1 Bridge library (`putty-macos-bridge`)

- [ ] Create `macos/bridge/putty-bridge.h` — public C API for Swift.
- [ ] Create `module.modulemap` exposing `PuttyBridge` to Swift.
- [ ] Use `@_cdecl` / `SWIFT_NAME` sparingly; prefer C wrapper functions over direct vtable manipulation from Swift.

### 3.2 Session object

- [ ] `PuttySession *putty_session_new(const Conf *conf)` — allocate seat, terminal, backend.
- [ ] `void putty_session_free(PuttySession *)`.
- [ ] `void putty_session_start(PuttySession *)` / `putty_session_reconfigure(PuttySession *, Conf *)`.
- [ ] `Backend *putty_session_get_backend(PuttySession *)` for throttle/unthrottle.
- [ ] Callback registration struct:

  ```c
  typedef struct PuttySessionCallbacks {
      void (*on_title_changed)(void *ctx, const char *title);
      void (*on_bell)(void *ctx, int mode);
      void (*on_exit)(void *ctx);
      void (*on_request_redraw)(void *ctx, NSRect dirtyPixels); /* bridged to Swift */
      /* … */
  } PuttySessionCallbacks;
  ```

### 3.3 Configuration access

- [ ] `Conf *putty_conf_new(void)` / `putty_conf_free`.
- [ ] `bool putty_conf_load_session(Conf *, const char *session_name)`.
- [ ] `bool putty_conf_save_session(Conf *, const char *session_name)`.
- [ ] Expose `conf_get_*` / `conf_set_*` wrappers only where Swift settings UI needs them; bulk editing goes through the abstract `controlbox` (Phase 6).

### 3.4 Event loop integration hooks

- [ ] `size_t putty_session_output(PuttySession *, const void *data, size_t len)` — feed keyboard to ldisc.
- [ ] `void putty_run_timers(uint64_t now_ms)` — call existing `run_timers()`.
- [ ] `bool putty_toplevel_callback_pending(void)`.
- [ ] `void putty_run_toplevel_callbacks(void)`.
- [ ] FD registration: `putty_uxsel_fill_pollfds(...)` wrapping `uxsel` + `pollwrap` for `DispatchSource` integration.

### 3.5 Memory and threading rules

- [ ] Document: **all PuTTY C calls on main thread** (matching AppKit).
- [ ] Document: Swift owns `PuttySession` lifetime; bridge does not retain Swift objects.
- [ ] Add debug-build assertions for thread correctness.

**Phase 3 exit criteria:** Swift test harness can create a `PuttySession`, start an SSH connection to a test server, and receive output bytes via callback — with no AppKit terminal view yet (output may go to `stdout` or a simple `NSTextView`).

---

## Phase 4 — Terminal view and `TermWin` implementation

**Goal:** High-performance terminal rendering and input, implementing the full `TermWinVtable`.

### 4.1 `MacTermWin` C struct

- [ ] Define `MacTermWin` holding:
  - `TermWin termwin` (vtable pointer)
  - Weak reference to Swift `TerminalView` (via `void *context` + callbacks)
  - Font metrics cache, palette (`rgb colours[OSC4_NCOLOURS]`)
  - Cell size in points, backing scale factor
- [ ] Implement all `TermWinVtable` methods in `macos/platform/termwin.c`.

### 4.2 Swift `TerminalView` (`NSView` subclass)

- [ ] Create `TerminalView.swift` hosted in the main window content view.
- [ ] Enable layer-backed rendering (`wantsLayer = true`).
- [ ] Implement `draw(_:)` or `CALayer` delegate drawing calling into C `TermWin` draw callbacks.
- [ ] Handle `viewDidChangeBackingProperties` for Retina scale changes → `term_size()`.

### 4.3 Text rendering strategy

- [ ] Primary: **Core Text** — one `CTLine` per terminal row for monospace bulk draw.
- [ ] Fallback: individual glyph draw for double-width, combining characters, and `trust_sigil`.
- [ ] Cache `CTFont` instances per `(FontSpec, bold, wide)` tuple.
- [ ] Implement `char_width()` using Core Text measurement aligned with draw path.
- [ ] Support true-colour (`truecolour` struct) and 256-colour palette from `palette_set()`.
- [ ] Implement cursor draw: block, underline, vertical bar per `Conf` settings.
- [ ] Implement `draw_trust_sigil` for anti-spoofing indicator.

### 4.4 Performance requirements (gate for Phase 5)

- [ ] Full-screen repaint (120×80) at 60 fps on Apple Silicon Mac during `cat large_file.txt`.
- [ ] Incremental dirty-region redraw for incremental output.
- [ ] Profile with Instruments (Time Profiler, Core Animation) — document baseline.
- [ ] Avoid allocating Objective-C objects per cell in hot paths.

### 4.5 Input handling

- [ ] Keyboard: `keyDown(with:)` → translate to bytes via `osxkeys` module (Option as Meta, Cmd shortcuts).
- [ ] Implement dead keys and IME via `NSTextInputClient` on macOS 15.
- [ ] Mouse: click, drag selection, wheel/trackpad scroll → mouse protocol encodings.
- [ ] Handle `set_raw_mouse_mode` / pointer shape changes (`NSCursor`).
- [ ] Context menu: Copy, Paste, Paste Special, Select All, Copy All.

### 4.6 Clipboard

- [ ] `clip_write` → `NSPasteboard.general` (UTF-8 plain text; optional styled text later).
- [ ] `clip_request_paste` → async pasteboard read, then inject via ldisc.
- [ ] Match HIG: no implicit copy-on-select unless configured in `Conf`.

### 4.7 Scrollbar and resize

- [ ] `set_scrollbar` → `NSScrollView`/`NSScroller` or overlay scroll indicator.
- [ ] `request_resize` → resize window or notify `term_size()` after live resize.
- [ ] Preserve grid of character cells on window resize (with user-configurable policy from `Conf`).

### 4.8 Bell and title

- [ ] `bell()` → `NSBeep()` or play configured sound file.
- [ ] `set_title` / `set_icon_title` → update `NSWindow.title` and Dock tile.

**Phase 4 exit criteria:** Local echo test session displays correctly; `test_terminal`-equivalent manual QA passes; performance gate met.

---

## Phase 5 — `Seat`, `LogPolicy`, and event loop

**Goal:** Wire the terminal view into a complete per-window session matching `WinGuiSeat` responsibilities.

### 5.1 `MacGuiSeat` and vtables

- [ ] Implement `SeatVtable` in `macos/platform/seat.c` (reference: `windows/win-gui-seat.h`, `unix/window.c` gtk seat).
- [ ] Implement `LogPolicyVtable` for event log and log-file prompts.
- [ ] Link `MacGuiSeat` ↔ `MacTermWin` ↔ `Terminal` ↔ `Backend` ↔ `Ldisc`.

### 5.2 Output path

- [ ] `seat.output` → decode → `term_data()` → schedule redraw on `TerminalView`.
- [ ] `seat.banner`, `seat.eof`, `seat.sent`, `seat.unthrottle` — match GTK semantics.
- [ ] `echoedit_update` → reflect local echo state in view if needed.

### 5.3 Security prompts (modal sheets)

- [ ] `confirm_ssh_host_key` — `NSAlert` sheet with fingerprint, trust-on-first-use, cache update.
- [ ] `confirm_weak_crypto_primitive` / `confirm_weak_cached_hostkey`.
- [ ] `get_userpass_input` — secure `NSSecureTextField` dialog; support keyboard-interactive auth.
- [ ] `connection_fatal` / `nonfatal` — alert panels with Help buttons where applicable.
- [ ] Implement `SeatDialogPromptDescriptions` strings matching macOS HIG tone.

### 5.4 Event loop: CFRunLoop + PuTTY timers

- [ ] Replace GTK main loop with:
  - `CFRunLoopRun()` / `@MainActor` app lifecycle
  - `DispatchSource` on FDs registered through `uxsel`
  - `Timer` or display-link-driven timer tick calling `run_timers()` and `run_toplevel_callbacks()`
- [ ] Ensure `select_result()` fires on socket readiness without blocking UI.
- [ ] Handle `backend_send()` backpressure via `seat.sent`.

### 5.5 Window controller

- [ ] `SessionWindowController: NSWindowController` owns `PuttySession`, `TerminalView`, menus.
- [ ] Implement close-with-confirmation when session active (`WarnOnClose` setting).
- [ ] Support `-load` session argument and `--help` parity with Unix PuTTY.

### 5.6 Special commands menu

- [ ] `update_specials_menu` → rebuild **Session → Special Commands** submenu from `backend_get_specials()`.

**Phase 5 exit criteria:** Full SSH login to remote host, interactive shell, file transfer not required yet; host key prompt works; window closes cleanly.

---

## Phase 6 — Configuration UI

**Goal:** Feature-complete settings editor equivalent to Windows/GTK PuTTY configuration.

### 6.1 Strategy: render the abstract `controlbox`

PuTTY's settings are defined once in portable `config.c` using `ctrl_*` helpers and rendered per-platform. The macOS port should **reuse this model** rather than duplicating hundreds of settings by hand.

- [ ] Implement `macos/platform/config-appkit.m` (Objective-C++) or Swift renderer that walks `struct controlbox`.
- [ ] Map control types (`dialog.h`) to AppKit widgets:

  | `CTRL_*` | AppKit widget |
  |----------|---------------|
  | `CTRL_EDITBOX` | `NSTextField` |
  | `CTRL_RADIO` | `NSButton` radio group |
  | `CTRL_CHECKBOX` | `NSButton` checkbox |
  | `CTRL_LISTBOX` | `NSComboBox` / `NSPopUpButton` |
  | `CTRL_FILESELECT` | `NSOpenPanel` |
  | `CTRL_FONTSELECT` | `NSFontPanel` / custom font picker |
  | `CTRL_COLUMNS` | `NSStackView` horizontal split |
  | `CTRL_TABDELAY` | hidden tab-order metadata |

- [ ] Implement `macos/platform/config-macos.c` for macOS-only control additions (mirror `unix/config-gtk.c`, `windows/config.c`).

### 6.2 Settings window UX

- [ ] `NSWindow` with `NSToolbar` + sidebar mirroring config tree paths (`"Connection/Proxy"`, …).
- [ ] **Apply**, **Cancel**, **Restore defaults** buttons wired to `Conf` copy/compare.
- [ ] Pre-session vs mid-session reconfiguration (`midsession` flag).
- [ ] Saved Sessions panel: list, load, save, delete, duplicate.

### 6.3 Initial connection flow

- [ ] On launch without `-load`, show connection dialog (host, port, protocol, saved session list).
- [ ] Implement `initial_config_box()` → modal or non-modal config → `new_session_window()`.

### 6.4 Event log window

- [ ] Implement event log viewer (`LogPolicy.eventlog`) as separate `NSWindow` with searchable `NSTextView`.
- [ ] **Window → Event Log** menu item (PuTTY only, not pterm).

### 6.5 Host CA configuration

- [ ] Port CA config box (`show_ca_config_box_synchronously`) if `has_ca_config_box` applies.

**Phase 6 exit criteria:** All settings panels functional; sessions save/load; mid-session reconfiguration works; parity spot-check against GTK config for representative options.

---

## Phase 7 — Additional applications

**Goal:** Parity with the Unix/Windows application suite.

### 7.1 PuTTY.app completion

- [ ] Multi-window **File → New Session**, **Duplicate Session**, **Restart Session**.
- [ ] Saved sessions submenu on menu bar.
- [ ] `-pgpfp`, `-cleanup` command-line switches.
- [ ] URL scheme handler (`putty://` or `ssh://` registration in `Info.plist`) — optional stretch.

### 7.2 pterm.app

- [ ] Swift target sharing `TerminalView` + `MacTermWin` + `MacGuiSeat`.
- [ ] `select_backend()` → `pty_backend`; `use_pty_argv = true`.
- [ ] No connection panels; `initial_config_box` no-op with immediate window (mirror `unix/pterm.c`).
- [ ] Subprocess environment: inherit clean environment (no GTK-style `osxlaunch` wrapper needed).
- [ ] Separate bundle ID `org.tartarus.projects.putty.pterm`.

### 7.3 PuTTYgen.app

- [ ] Wrap existing `cmdgen.c` + keygen UI in AppKit, or port `windows/puttygen.c` patterns.
- [ ] Link `keygen`, `crypto`, `utils` libraries.
- [ ] Key export/import, passphrase generation, randomness via `noise.c`.

### 7.4 Pageant / agent integration

- [ ] Evaluate **macOS OpenSSH agent** (`$SSH_AUTH_SOCK`) as default vs embedded agent.
- [ ] If embedded: port `pageant.c` logic with `NSStatusItem` menu (optional).
- [ ] Implement `askpass` helper for GUI passphrase prompts via Keychain or secure dialog.
- [ ] Document Keychain storage for keys as future enhancement.

### 7.5 Shared code between apps

- [ ] Extract shared Swift package / static framework `PuttyMacUI` for `TerminalView`, config UI, bridge wrappers.
- [ ] Per-app targets only differ in `Info.plist`, icons, and app constants (`use_event_log`, etc.).
- [ ] All release `.app` bundles (PuTTY, pterm, PuTTYgen) must be Universal 2 when `PUTTY_MACOS_UNIVERSAL=ON`; shared libraries must not hard-code a single architecture.

**Phase 7 exit criteria:** PuTTY, pterm, and PuTTYgen run as independent `.app` bundles; agent strategy documented and minimally functional.

---

## Phase 8 — Packaging, signing, and distribution

**Goal:** Ship installable, Gatekeeper-approved application bundles.

### 8.1 Bundle layout

Standard structure for each `.app`:

```
PuTTY.app/
  Contents/
    Info.plist
    MacOS/PuTTY          # Universal 2 Mach-O (arm64 + x86_64 slices)
    Resources/
      PuTTY.icns
      Assets.car
      en.lproj/
    _CodeSignature/
    Frameworks/          # if dynamically linking Swift runtime (usually not for recent macOS)
```

- [ ] CMake `install(TARGETS putty-app BUNDLE …)` with `MACOSX_BUNDLE_INFO_PLIST`.
- [ ] Set `CFBundleShortVersionString` from PuTTY version macros / git describe.
- [ ] Add `NSPrincipalClass = NSApplication`.
- [ ] Post-build / install verification: `lipo -info` on each `.app` executable confirms Universal 2 (`x86_64` and `arm64` present).
- [ ] Bundle `Resources/` assets (`.icns`, `Assets.car`, localizations) are architecture-neutral; no per-arch resource forks required.

### 8.2 Code signing

- [ ] Ad-hoc sign for local dev: `codesign --force --deep --sign -`.
- [ ] Release: sign with **Developer ID Application** certificate (`PUTTY_MACOS_SIGN_IDENTITY`).
- [ ] Enable **Hardened Runtime** (`-o runtime`).
- [ ] Verify `codesign --display --verbose` reports both architectures for Universal 2 bundles (`Authority=…`, `Format=app bundle with Mach-O universal (x86_64 arm64)`).
- [ ] Create entitlements plists:
  - `PuTTY.entitlements` — network client, optional user-selected file access
  - Avoid sandbox initially unless requirements demand it

### 8.3 Notarization

- [ ] Post-build target: `notarytool submit` + `stapler staple` when `PUTTY_MACOS_NOTarize=ON`.
- [ ] Store notary credentials in CI secrets (Phase 10).
- [ ] Verify stapled apps on clean macOS 15 VM.

### 8.4 DMG / distribution (optional)

- [ ] CMake custom target to assemble `.dmg` with Applications symlink.
- [ ] Ship a **single Universal 2** `.app` per application in the DMG (not separate Intel/ARM downloads).
- [ ] Align with existing upstream release process (`Buildscr` integration or separate `release-macos.sh`).

**Phase 8 exit criteria:** Signed Universal 2 PuTTY.app passes `spctl -a -vv`; `lipo -info` and `codesign --display --verbose` confirm both slices; notarized build installs on macOS 15 on Intel and Apple Silicon without security warnings.

---

## Phase 9 — Quality, accessibility, and polish

**Goal:** Production-grade user experience on macOS 15.

### 9.1 Testing

- [ ] Run existing C unit tests (`testcrypt`, `test_terminal`, …) on macOS CI with `PUTTY_MACOS_GUI=ON`.
- [ ] Add macOS-specific UI tests (XCTest) for launch, connect (mock server), config save/load.
- [ ] Manual matrix on **native Intel** (x86_64 slice), **native Apple Silicon** (arm64 slice), and cross-arch smoke (Universal 2 `.app` copied between machine types); light/dark mode, multiple monitors, Spaces.
- [ ] Confirm performance gate (Phase 4) on Apple Silicon; spot-check on Intel.

### 9.2 Accessibility

- [ ] VoiceOver labels for terminal view (limited — document as terminal emulator).
- [ ] Keyboard navigation for all dialogs.
- [ ] Respect **Reduce Motion** and **Increase Contrast** settings.

### 9.3 macOS 15 integration

- [ ] Adopt standard **Settings** scene patterns where appropriate.
- [ ] Support system accent colour in chrome (not terminal palette).
- [ ] Trackpad scroll momentum and Phase 4 scroll fix validation.
- [ ] Menu bar **Edit → Copy/Paste** wired to responder chain.

### 9.4 Printing

- [ ] Port `unix/printing.c` or implement via `NSPrintOperation` for session transcript printing.

### 9.5 Help

- [ ] Bundle HTML or PDF help generated from `doc/` Halibut sources.
- [ ] **Help → PuTTY Help** menu opens Help Viewer or embedded WebKit view.

### 9.6 Known parity gaps (document honestly)

- [ ] X11 forwarding display integration (optional; `$DISPLAY` only initially).
- [ ] GSSAPI/Kerberos — verify with macOS Kerberos.framework.
- [ ] Serial port backend — verify USB serial on macOS 15.

**Phase 9 exit criteria:** No P0/P1 open bugs; accessibility audit complete; FAQ updated to reflect native macOS availability.

---

## Phase 10 — CI and ongoing maintenance

**Goal:** Prevent macOS GUI regressions in automated builds.

### 10.1 Continuous integration

- [ ] Add macOS runner job: configure with `-DPUTTY_MACOS_GUI=ON`, build all app targets.
- [ ] Release / mainline artifact job: `-DPUTTY_MACOS_UNIVERSAL=ON`; verify with `lipo -info` on each `.app`.
- [ ] Optional fast PR job: `-DPUTTY_MACOS_UNIVERSAL=OFF` (native arch only) for shorter compile times; full Universal 2 gate on merge to main.
- [ ] Fallback if single-runner universal cross-compile is impractical: build `arm64` and `x86_64` separately on matching runners, then `lipo -create` into one `.app` executable before signing (document in `Buildscr.macos`).
- [ ] Run C test suite.
- [ ] Artifact-upload unsigned Universal 2 `.app` bundles for QA.

### 10.2 Release integration

- [ ] Extend `Buildscr` or add `Buildscr.macos` for official release binaries.
- [ ] Release builds always produce Universal 2 `.app` bundles (`PUTTY_MACOS_UNIVERSAL=ON`).
- [ ] Version stamping in `Info.plist` synchronized with `cmake_commit.c` / version headers.

### 10.3 Contribution guidelines

- [ ] Document Swift style, `@MainActor` requirements, and C bridge change process.
- [ ] Require ObjC/Swift changes to keep C core free of Apple framework dependencies.

**Phase 10 exit criteria:** macOS GUI build is a required CI check on every push to main.

---

## Dependency graph between phases

```
Phase 1 (scaffolding)
    ↓
Phase 2 (C platform) ─────────────────────────┐
    ↓                                           │
Phase 3 (bridge)                                │
    ↓                                           │
Phase 4 (TermWin / TerminalView)                │
    ↓                                           │
Phase 5 (Seat / event loop) ←───────────────────┘
    ↓
Phase 6 (config UI)
    ↓
Phase 7 (pterm, puttygen, pageant)
    ↓
Phase 8 (signing / notarization)
    ↓
Phase 9 (polish)  ←  Phase 10 (CI) can start after Phase 1, expand through Phase 9
```

Phases 4 and 2 can partially overlap once Phase 1 completes, but **Phase 5 must not start until Phase 4 performance gate passes**.

---

## File inventory (expected final state)

```
macos/
  CMakeLists.txt
  platform.h
  platform/
    storage.c
    network.c
    fd-socket.c
    pty.c
    noise.c
    unicode.c
    seat.c
    termwin.c
    config-macos.c
    config-appkit.mm
    cliloop.c
    uxsel.c
    …
  bridge/
    CMakeLists.txt
    putty-bridge.h
    putty-bridge.c
    module.modulemap
  PuTTY/
    CMakeLists.txt
    PuTTYApp.swift
    AppDelegate.swift
    SessionWindowController.swift
    TerminalView.swift
    Info.plist
    PuTTY.entitlements
  pterm/
    …
  puttygen/
    …
  Resources/
    Assets.xcassets/
cmake/
  platforms/
    macos.cmake
MACOS_GUI_PLAN.md          ← this document
```

---

## Risk register

| Risk | Mitigation |
|------|------------|
| Terminal redraw performance (historical Cocoa failure) | Phase 4 performance gate; Core Text row cache; Instruments profiling |
| Swift / C threading bugs | Main-thread-only rule; assertions; stress tests |
| Config UI complexity (~3K lines abstract + platform) | Reuse `controlbox` renderer; do not hand-build all panels |
| GTK/unix divergence | Separate `macos/` platform; no `OSX_GTK` dependency |
| Code signing / notarization friction | Phase 8 early prototyping on Developer ID; document ad-hoc dev workflow |
| App Sandbox requirements for App Store | Defer; direct distribution first with Hardened Runtime only |
| CMake Swift support gaps | Pin CMake 3.28+; test Ninja and Xcode generators |
| Universal 2 build time / CI complexity | Default `PUTTY_MACOS_UNIVERSAL=OFF` for local dev; single-config fat binary via `CMAKE_OSX_ARCHITECTURES`; optional per-arch CI + `lipo -create` fallback |
| Universal binary signing / notarization | Sign once after fat binary is assembled; verify both slices with `lipo -info` and `codesign --display --verbose` before notarization |

---

## References within this repository

| Topic | Location |
|-------|----------|
| Seat / TermWin vtables | `putty.h` |
| Windows GUI reference | `windows/window.c`, `windows/win-gui-seat.h`, `windows/controls.c` |
| Unix platform C code | `unix/*.c` (exclude GTK files) |
| Abstract configuration | `config.c`, `dialog.c`, `dialog.h` |
| macOS FAQ / history | `doc/faq.but` (`faq-mac-port`) |
| Icon generation | `icons/macicon.py`, `icons/Makefile` |
| Existing CMake platform split | `cmake/setup.cmake`, `cmake/platforms/unix.cmake` |
| GtkApplication TODO (superseded) | `unix/main-gtk-application.c` |

---

## Summary

Adding a native macOS GUI is **large but structurally straightforward**: PuTTY already isolates platform UI behind vtables and a portable configuration model. The work splits naturally into a **C platform port** (mostly recycled from `unix/`), a **Swift/AppKit terminal view** (the critical path), and **CMake integration** for macOS 15 targeting with **Universal 2** release binaries (`arm64` + `x86_64` in one `.app`). Following the phases above keeps CLI builds working, avoids the abandoned GTK-on-Quartz path, and front-loads the rendering performance risk that blocked the original Cocoa attempt.
