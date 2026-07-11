# Rules compliance audit

**Date:** 2026-07-10  
**Scope:** Codebase vs `.cursor/rules/` (`agents.mdc`, `bridge-and-ui.mdc`, `pure-c.mdc`, `general.mdc`)  
**Focus:** `macos/` (native GUI), plus docs/tooling that agents.mdc references  

This audit does **not** demand reformatting upstream `unix/` / `windows/` / portable core to macos-only style (`pure-c.mdc` / agents §4). Findings below are gaps relative to the new rules, not a full product backlog.

### Severity key

| Priority | Meaning |
|----------|---------|
| **P0** | Safety / correctness risk; fix before relying on the path in production |
| **P1** | Clear rule violation or high-impact compliance gap |
| **P2** | Important hygiene, docs drift, or incomplete rule adoption |
| **P3** | Nice-to-have consistency / rule-file polish |

### Progress

- [x] P0.1 PuTTYgen key free during background generate
- [x] P0.2 TermWin null guards
- [x] P1.3 TerminalView main-thread TermWin teardown
- [x] P1.4 C→Swift UI callbacks main hop
- [x] P1.5 Stale termWin in specials menu
- [x] P1.6 Remove macos/ osxlaunch target
- [x] P1.7 Replace strcpy in ssh-exit test
- [x] P1.8 Main-thread asserts on TermWin/launch APIs
- [x] P1.9 Opaque backend API (no struct Backend * in Swift header)
- [~] P1.10 Skipped — deferred (see note below)
- [ ] P2.11–P2.23 (see below)
- [ ] P3.24–P3.30 (see below)

### Already in good shape

- [x] Opaque bridge handles + ownership/threading notes in `putty-bridge.h`
- [x] PuTTY allocators in `macos/` C (no raw `malloc`/`free` in bridge/platform/utils)
- [x] Pure AppKit UI; `@MainActor`; `Unmanaged.passUnretained` context pattern
- [x] Scoped buffer APIs on hot Swift paths; clipboard off-main → bridge on main
- [x] `PARITY.md` / `AGENT.md` (X11, GSSAPI, serial, `$SSH_AUTH_SOCK` / no Pageant.app)
- [x] `build.sh`, quality configs, separate build dirs, core `macos/` layout

---

## P0 — Safety / correctness

- [x] **P0.1** PuTTYgen: free key while background generate may still run  
  - **Done:** 2026-07-10  
  - **Rules:** `bridge-and-ui.mdc` (lifecycle), `agents.mdc` §3  
  - **Where:** `macos/puttygen/PuttygenWindowController.swift`, `PuttygenApp.swift`, `puttygen-bridge.h`  
  - **Was:** `puttygen_key_generate` on a background queue could race with `puttygen_key_free` on close/deinit; completion held `self` with no torn-down guard.  
  - **Fix:** Serial `keyQueue` for all `puttygen_key_*` (including free); generation epoch + weak `PuttygenGenerateContext`; refuse window close / app terminate while generating; free only via `keyQueue.sync` after work drains; progress/completion skip stale epochs / torn-down UI.

- [x] **P0.2** TermWin bridge getters: null `btw` before `btw->term` / `btw->mtw`  
  - **Done:** 2026-07-10  
  - **Rules:** `pure-c.mdc` (check fallible / defensive API results)  
  - **Where:** `macos/bridge/putty-bridge-termwin.c`  
  - **Was:** Many public entry points used `if (!btw->term)` / `!btw->conf` (or dereferenced `mtw`) without checking `btw` first — e.g. `cols`/`rows`, `palette_colour`, `view_size_for_grid`, `scrollbar_state`, `feed`, `pointer_indicates_raw_mouse`.  
  - **Fix:** Standardized public TermWin guards on `if (!btw || !btw->term)` (and `mtw` / `conf` / output pointers where needed); added missing guards on `init_demo`, `set_callbacks`, `eventlog_append_test`, `palette_colour`, `compute_dirty_rect`, `view_size_for_grid`, `scrollbar_state`, `pointer_indicates_raw_mouse`, `feed`, `resize_grid`, `resize_to_view`, `apply_live_resize`.

---

## P1 — Important rule compliance

- [x] **P1.3** `TerminalView.deinit` calls PuttyBridge off the main thread  
  - **Done:** 2026-07-10  
  - **Rules:** `agents.mdc` §3, `bridge-and-ui.mdc`  
  - **Where:** `macos/PuttyMacUI/TerminalView.swift`, `SessionWindowController.swift`, `TerminalClipboard.swift`  
  - **Was:** `@MainActor` `deinit` is nonisolated and freed the TermWin (and cleared callbacks) on whatever thread released the view.  
  - **Fix:** Added `destroyTermWin()` for main-thread callback clear + `putty_bridge_termwin_free`; `SessionWindowController.windowWillClose` calls it while the view is still alive. `deinit` only runs a main-queue safety-net free if teardown was skipped. Clipboard `detach()` + paste Task re-checks `termWin` after async read.

- [x] **P1.4** C→Swift UI callbacks use `MainActor.assumeIsolated` without an explicit main hop  
  - **Done:** 2026-07-10  
  - **Rules:** `bridge-and-ui.mdc` (`DispatchQueue.main.async`)  
  - **Where:** `PuttyMainHop.swift`; `TerminalView` trampolines; `SessionSpecialsMenu` / `SessionEventLog` / `SessionWindowController`; open-session callbacks in `PuTTYApp` / `PtermApp`; `TerminalClipboard`  
  - **Was:** UI-mutating C trampolines used bare `MainActor.assumeIsolated` (UB if C ever called off-main); open-session handlers called `@MainActor` methods with no hop.  
  - **Fix:** Added `PuttyMainHop.run` (main-thread sync, else `DispatchQueue.main.async`). UI callbacks (scrollbar, title, bell, clipboard, specials, event log, remote exit, open-session, settings) use it with weak captures. Paint-path trampolines under `draw(_:)` keep synchronous `assumeIsolated` (documented). NSTextInputClient still uses `assumeIsolated` (AppKit main-thread API).

- [x] **P1.5** Stale `termWin` in session specials menu  
  - **Done:** 2026-07-10  
  - **Rules:** `bridge-and-ui.mdc` (lifecycle), `agents.mdc` §8  
  - **Where:** `SessionSpecialsMenu.swift`, `SessionWindowController.swift`  
  - **Was:** `SpecialCommandPayload` stored a raw `OpaquePointer`; a deferred menu action after teardown could call `putty_bridge_termwin_send_special` on a freed handle.  
  - **Fix:** Payload holds a weak `SessionWindowController`; `sendSpecial` requires `isOpen` + live `activeTermWin`. `hideSpecials` clears `representedObject`/`target` recursively. `sessionWillClose` clears the menu before `destroyTermWin()`.

- [x] **P1.6** GTK-era `osxlaunch` still built under `macos/`  
  - **Done:** 2026-07-10  
  - **Rules:** `agents.mdc` §3, §11  
  - **Where:** `macos/CMakeLists.txt`  
  - **Was:** `add_executable(osxlaunch platform/osxlaunch.c)` compiled the GTK-mac-bundler launcher into the native GUI tree.  
  - **Fix:** Removed the target; left a comment that `unix/` still builds it when `PUTTY_MACOS_GUI` is OFF. Symlink `macos/platform/osxlaunch.c` unused by the GUI build.

- [x] **P1.7** Banned `strcpy` in macos C  
  - **Done:** 2026-07-10  
  - **Rules:** `pure-c.mdc`  
  - **Where:** `macos/bridge/putty-bridge-ssh-exit.c`  
  - **Was:** Length-checked `strcpy` into a fixed `hostkey` buffer.  
  - **Fix:** `snprintf(hostkey, sizeof(hostkey), "%s", configured)` with truncate/error check. No remaining `strcpy`/`strcat`/`sprintf` under `macos/`.

- [x] **P1.8** Incomplete main-thread asserts on Swift-facing bridge APIs  
  - **Done:** 2026-07-10  
  - **Rules:** `agents.mdc` §7  
  - **Where:** `putty-bridge-termwin.c`, `putty-bridge-launch.c`  
  - **Was:** Lifecycle/query APIs (`termwin_new`/`free`, eventlog/close-warn getters, cols/rows/conf getters, scrollbar state, `set_parent_window`, `open_session_window_count`) lacked `PUTTY_BRIDGE_ASSERT_MAIN_THREAD()` while mutators already had it.  
  - **Fix:** Added asserts to those 24 TermWin APIs + `putty_bridge_open_session_window_count`. Left thread-agnostic helpers alone (`free_string`, `apply_ctrl`, `special_code_*`, `free_close_warn_text`).

- [x] **P1.9** Public bridge exposes `struct Backend *` to Swift  
  - **Done:** 2026-07-10  
  - **Rules:** `agents.mdc` §3, §7  
  - **Where:** `putty-bridge.h`, `putty-session.c`, `putty-bridge.c`, `MACOS_GUI_PLAN.md`  
  - **Was:** Swift-facing header forward-declared `struct Backend` and exported `putty_session_get_backend()`.  
  - **Fix:** Removed `struct Backend` from the public header; added `putty_session_has_backend` + `putty_session_backend_unthrottle`. Bumped `PUTTY_BRIDGE_API_VERSION` to 2.

- [~] **P1.10** Plan claims “macOS CI” for unit tests without a test workflow — **SKIPPED**  
  - **Skipped:** 2026-07-10 (explicitly deferred; not fixing in this audit pass)  
  - **Rules:** `agents.mdc` §1 (truth), §10  
  - **Where:** `MACOS_GUI_PLAN.md` §9.1; `.github/workflows/` (CodeQL only)  
  - **Issue:** Checkbox marked done for CI; reality is local-only testing.  
  - **Deferred fix:** Uncheck / qualify as local, or add Phase 10 CI that runs `./macos/build.sh test`. Remains open for a later docs/CI pass (related: P2.22).

---

## P2 — Hygiene, docs, incomplete adoption

### Bridge / C

- [x] **P2.11** Ownership docs for `PuttyBridgeSessionSpecial.name` and puttygen `error_out` / fingerprint NULL cases  
  - **Fix:** Document borrow vs free (`puttygen_free_string`) at each API.

- [x] **P2.12** Direct `conf->conf` / `Terminal` field access outside wrappers  
  - **Where:** launch, pterm cmdline, ssh-exit test, termwin smoke  
  - **Fix:** Route through `putty_conf_*` / terminal helpers; keep internals in `putty-conf.c` / bridge-only with comments.

- [x] **P2.13** Fallible I/O unchecked  
  - **Where:** `storage.c` `fprintf`/`fclose`; `read_random_seed`; `printing.c` short `fwrite` / `pclose`; puttygen public save `ferror`  
  - **Fix:** Propagate or log errors; mark intentional ignore with `WORKAROUND:` if kept.

- [x] **P2.14** Dead NULL checks after `snew`  
  - **Where:** cmdline / ssh-exit / eventloop after `putty_*_new`  
  - **Fix:** Remove impossible checks (`pure-c.mdc`).

- [x] **P2.15** Missing `WORKAROUND:` markers at known parity boundaries  
  - **Where:** `platform_get_x_display` NULL, GSSAPI dlopen names, printing `popen`, stubs  
  - **Fix:** Add agents §1.6 comments at code boundaries.

### Swift / AppKit

- [x] **P2.16** No shared `PuttyBridgeError` at bridge boundary  
  - **Issue:** Failures → `fputs` / beep / ad hoc strings; Puttygen has a local good pattern.  
  - **Fix:** Map C codes to a Swift `Error` enum at first Swift touch.

- [x] **P2.17** Sparse ownership comments on `OpaquePointer` fields  
  - **Fix:** Comment each handle (borrowed vs owned) and free site.

- [x] **P2.18** Keyboard shim in Swift (`OsxKeys.swift` US-QWERTY control-letter fallback)  
  - **Fix:** Prefer bridge helper or document as intentional macOS UI shim.

### Docs / tooling / structure

- [x] **P2.19** CMake ≥ 3.28 docs vs root `CMakeLists.txt` `3.7...3.28`  
  - **Fix:** Raise floor for GUI builds or document upstream exception.

- [x] **P2.20** Plan file inventory drift (`PuTTY/` vs `PuttyMacUI/`; entitlements listed but absent)  
  - **Fix:** Update inventory + Phase 8 status banner.

- [x] **P2.21** Phase 8 release path open (signing / notarization / DMG)  
  - **Fix:** Execute or explicitly defer 8.2–8.4 in plan.

- [ ] **P2.22** Phase 10 CI missing (`build.sh test` / Universal verify on main)  
  - **Fix:** Add workflow or keep plan honest.

- [ ] **P2.23** Root README further reading omits `TESTING.md`, `PARITY.md`, `HELP.md`, `INTEGRATION.md`  
  - **Fix:** Point at `macos/README.md` related-docs table.

---

## P3 — Nice-to-have

- [ ] **P3.24** Standardize C→Swift callback dispatch style (`assumeIsolated` vs `Task` vs `DispatchQueue.main.async`)
- [ ] **P3.25** `build.sh check` enforce CMake ≥ 3.28
- [ ] **P3.26** Rule frontmatter hygiene (`alwaysApply` + redundant globs; note pure-c trigger in agents)
- [ ] **P3.27** `sfree` → `NULL` where pointer can be reused
- [ ] **P3.28** Prefer `mkstemp` over hard-coded `/tmp` in smokes
- [ ] **P3.29** Replace `storage.c` `/* XXX */` on `FNLEN` with rationale
- [ ] **P3.30** Align default serial / log paths with `PARITY.md` / paths helpers

---

## Suggested remediation order

1. **P0:** [x] P0.1 PuTTYgen lifecycle → [x] P0.2 TermWin null guards
2. **P1:** [x] P1.3–P1.9 → [~] P1.10 skipped (CI honesty deferred)
3. **P2:** Ownership / `Error` enum / I/O / `WORKAROUND:` / conf wrappers / docs / Phase 8–10
4. **P3:** Style consistency and rule-file polish

---

## Out of scope / non-findings

- [x] **`general.mdc`** — agent workflow only (no auto-commit/push); no codebase change required
- [x] **Upstream `unix/` / `windows/` / portable core** — do not mass-apply macos style tools
- [x] **GTK under `unix/`** — expected for non-`PUTTY_MACOS_GUI` builds; only `macos/` `osxlaunch` conflicts

---

## How this audit was produced

Cross-checked against:

- `.cursor/rules/agents.mdc`, `bridge-and-ui.mdc`, `pure-c.mdc`, `general.mdc`
- `macos/bridge/`, `macos/platform/`, `macos/PuttyMacUI/`, app targets, tests, docs, CMake/`build.sh`
- Spot verification of P0/P1 items (PuTTYgen race, TermWin null guards, `strcpy`, `osxlaunch`, `struct Backend *`, missing `WORKAROUND` markers)

Re-run after a remediation batch and tick items here so status does not drift from the rules.
