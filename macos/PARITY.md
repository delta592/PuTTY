# Known parity gaps (Phase 9.6)

Honest inventory of features that exist in Windows/Unix PuTTY but are
**incomplete, unverified, or intentionally deferred** on the native
macOS AppKit port. Nothing in this document is scheduled for
implementation in Phase 9; it is documentation only.

For build/run instructions see [`README.md`](README.md). Agent-related
deferrals (Pageant.app, Keychain key storage) are covered in
[`AGENT.md`](AGENT.md).

## Summary

| Area | Code present? | Verified on macOS 15? | Status |
|------|---------------|----------------------|--------|
| X11 forwarding | Yes (Unix-style) | No | Works only with an external X server; no Quartz integration |
| GSSAPI / Kerberos | Yes (Unix-style `dlopen`) | No | Not wired to Apple `Kerberos.framework` / `GSS.framework` |
| Serial backend | Yes (termios) | No | Likely works with a correct `/dev/cu.*` path; untested |

---

## 1. X11 forwarding

### What works today

- Portable SSH X11 forwarding (`ssh/x11fwd.c`, `x11disp.c`) is linked
  into the macOS GUI client.
- `macos/platform/x11.c` provides local auth lookup (`.Xauthority` /
  `$XAUTHORITY`) and the optional local X11 server helper used by
  sharing, same shape as Unix.
- Connection → SSH → X11 config controls are available via the shared
  `config.c` control box.

### Gaps

- **No native display integration.** macOS has no system X11 server.
  Forwarding only succeeds if the user runs a third-party X server
  (typically [XQuartz](https://www.xquartz.org/)) and points PuTTY at
  it.
- **`$DISPLAY` is not read by the GUI bridge.**
  `platform_get_x_display()` in `macos/bridge/putty-bridge-platform.c`
  returns `NULL`. When the X11 display field is empty, `x11_setup_display`
  therefore falls back to `:0` (see `x11disp.c`). Unix console/GTK paths
  use `getenv("DISPLAY")` instead. Users should set **X display location**
  explicitly in the X11 panel (e.g. the socket path XQuartz prints).
- **No auto-launch / discovery of XQuartz**, no Quartz-to-X bridge, and
  no end-to-end verification on macOS 15 in this tree.

### Workaround (manual)

1. Install and start XQuartz (or another X11 server).
2. Note its display (often a Unix-domain path ending in `:0`, or
   `:0` / `localhost:0`).
3. In PuTTY: enable **X11 forwarding** and set **X display location**
   to that value.
4. Confirm remote clients can open windows on the local X server.

### Future work (not in Phase 9)

- Make `platform_get_x_display()` honour `$DISPLAY` (Windows already
  does).
- Optional XQuartz detection / default display string.
- Documented smoke test against a real X server.

---

## 2. GSSAPI / Kerberos

### What works today

- `macos/platform/gss.c` is the Unix GSS setup (dynamic `dlopen` of
  Heimdal / MIT / Sun library names, plus a user-specified path).
- CMake default is `PUTTY_GSSAPI=DYNAMIC` (`cmake/platforms/macos.cmake`).
  `STATIC` uses `pkg-config` / `krb5-config`; `OFF` defines `NO_GSSAPI`.
- When GSSAPI is compiled in, the Connection → SSH → Auth → GSSAPI
  panel from portable `config.c` is shown.

### Gaps

- **Dynamic library names are Linux-oriented** (`libgssapi.so.2`,
  `libgssapi_krb5.so.2`, `libgss.so.1`). Stock macOS does not ship
  those `.so` files under `/usr/lib`.
- **Apple system frameworks are unused.** macOS provides
  `Kerberos.framework` and `GSS.framework`, plus Ticket Viewer /
  `kinit` for credentials. The port does not link or `dlopen` those
  frameworks, and has not been verified against tickets obtained via
  the system Kerberos stack.
- **STATIC builds** may work if Homebrew (or similar) MIT Kerberos is
  installed and discovered via `krb5-config`, but that path is also
  unverified in this tree.
- Users can try a **custom GSSAPI library path** in the config panel
  if they have a compatible `libgssapi_krb5` dylib; success is not
  guaranteed.

### Workaround (manual / experimental)

```sh
# Optional: build with static MIT Kerberos if available
cmake -B build-macos-gui-dev -G Ninja \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_GSSAPI=STATIC
# or leave DYNAMIC and set “User-supplied GSSAPI library” in the UI
```

Prefer password / public-key / agent auth until this is verified.

### Future work (not in Phase 9)

- Prefer or add Apple `GSS.framework` / `Kerberos.framework` binding.
- Verify GSSAPI userauth and GSSAPI key exchange against a Kerberos
  realm using system tickets (`klist`).
- Document a supported Homebrew vs system-framework matrix.

---

## 3. Serial port backend

### What works today

- `macos/platform/serial.c` is the Unix termios serial backend
  (`open` / `read` / `write` / `tcsetattr` / break), linked into
  `otherbackends`.
- Connection type **Serial** and the Serial settings panel are
  available.
- Default line string is `/dev/tty.usbserial`
  (`platform_default_s("SerialLine")` in the bridge) — a placeholder
  name, not an enumerated device.

### Gaps

- **Not verified** with USB-serial adapters (FTDI, CP210x, etc.) on
  macOS 15 in this tree.
- **No device picker.** macOS exposes ports as `/dev/cu.*` (callout)
  and `/dev/tty.*` (dial-in). Applications that open the port
  themselves should prefer **`/dev/cu.*`**. There is no IOKit
  enumeration UI; the user must type the path.
- Default `/dev/tty.usbserial` often does not exist; real devices look
  like `/dev/cu.usbserial-…` or vendor-specific names.
- Flow-control / baud edge cases on Apple USB-serial drivers are
  unknown.

### Workaround (manual)

```sh
# List candidate ports (plug the adapter in first):
ls /dev/cu.*
```

In PuTTY: set **Connection type** to Serial, set **Serial line** to
the matching `/dev/cu.…` path, and configure baud / data / parity /
stop / flow to match the device.

### Future work (not in Phase 9)

- Hardware smoke test matrix on macOS 15 (Intel + Apple Silicon).
- Optional IOKit-based serial port list in the config UI.
- Prefer `/dev/cu.*` in the default / documentation.

---

## Related deferred items (already documented elsewhere)

| Item | Where |
|------|--------|
| Pageant.app / `NSStatusItem` menu-bar agent | [`AGENT.md`](AGENT.md) |
| Keychain storage for private keys / passphrases | [`AGENT.md`](AGENT.md) |
| App Sandbox (direct distribution first) | `MACOS_GUI_PLAN.md` Phase 8 / risk register |
| Code signing / notarization | Phase 8 (not started) |

These are product/packaging choices, not Windows feature parity bugs,
but they are intentional omissions relative to a “full” desktop PuTTY
suite.

---

## Code boundary markers (`WORKAROUND:`)

Agents and reviewers should find `WORKAROUND:` comments (agents.mdc §1.6)
at macOS-owned boundaries:

| Boundary | Location |
|----------|----------|
| `platform_get_x_display()` → `NULL` | `macos/bridge/putty-bridge-platform.c` |
| ANSI printer via `popen` | `macos/platform/printing.c` |
| `x_get_default` (no X resources) | `macos/platform/stubs.c` |
| Headless TermWin / LogPolicy in `PuttySession` | `macos/bridge/putty-session.c` |
| Optional random-seed read errors | `macos/platform/storage.c` |

**Symlinked Unix sources** (`macos/platform/gss.c` → `unix/gss.c`,
`serial.c`, `x11.c`, …) must **not** grow macOS-only comments in the
Unix tree. Treat this document as the WORKAROUND record for those paths:

- **GSSAPI:** DYNAMIC `dlopen` of Linux `.so` names usually fails on
  stock macOS; Apple frameworks not wired (see §2).
- **X11 auth / display helpers:** Unix `$XAUTHORITY` / socket paths only;
  no Quartz integration (see §1).
- **Serial `provide_ldisc`:** unused stub; local echo/edit stay off
  (same as Unix; see §3).

---

## How to use this document

- Treat rows in the summary table as **known limitations** for release
  notes and support answers.
- Do not assume X11, GSSAPI, or serial “just work” because the source
  files compile.
- When any gap is closed, update this file and the Phase 9.6 notes in
  [`../MACOS_GUI_PLAN.md`](../MACOS_GUI_PLAN.md) in the same change.
