# Windows build / test environment (macOS host)

Guide for validating the **Windows (`windows/`) platform** of this PuTTY tree from a Mac, without a dedicated Windows PC.

**Recommended host for typical Windows users (x86_64):** a **2019 Intel iMac** (or any Intel Mac) with a **Windows 10/11 x64** guest.

Two supported strategies (use either or both):

| Strategy | Hypervisor | Best for |
|----------|------------|----------|
| **A. Manual VMware Fusion** | Fusion | Interactive GUI smoke, long-lived desktop VM |
| **B. Vagrant + VirtualBox** (+ **Ansible**) | VirtualBox | Reproducible VM; Ansible for tools/build/console tests |
| **B one-shot** (§3.5) | same stack | Single command: bring up VM → provision → build → test |

The Apple Silicon Mac Studio can run **Windows 11 ARM** in Fusion; that is useful for WoA smoke checks but is **not** a substitute for native x64 Windows QA. Prefer the Intel iMac for x64.

Related docs: root `README` (CMake / MSVC), `macos/README.md` (native macOS GUI — separate from this guide).

---

## 1. Goals

| Goal | How this env helps |
|------|--------------------|
| Compile as `platform = windows` | MSVC (or MinGW) inside the guest |
| Run portable tests | `test_terminal`, `testcrypt` + `cryptsuite.py`, `cgtest`, utils binaries |
| Smoke Win32 GUI | Launch `putty.exe`, exercise Saved Sessions / config dialog |
| Match most users | Real **x86_64** Windows, not ARM64-with-emulation |

This tree’s macOS AppKit work lives under `macos/` and does not replace Windows testing. Shared C changes (e.g. `config.c`, crypto, `terminal/`) **do** affect Windows and should be verified here.

---

## 2. Which strategy to use

| Need | Prefer |
|------|--------|
| Click through PuTTY dialogs often; keep one tuned desktop | **A — Fusion** (manual) |
| Recreate the guest cleanly; automate install/build/test | **B — Vagrant + VirtualBox**, with **Ansible** (§3.4) |
| One command for “VM up + build + console tests” | **B one-shot** (§3.5) |
| Both: daily GUI on Fusion, CI-like reset on Vagrant | **A + B** on the same iMac (separate VMs; watch disk/RAM) |

Guest tooling (§4), source layout (§5), build (§6), and tests (§7) are the same once Windows is up. Strategy A installs them by hand; Strategy B should prefer Ansible (§3.4). Day-to-day Strategy B should converge on the one-shot entrypoint (§3.5).

**Note:** Vagrant can also drive Fusion via the VMware provider plugin. This guide standardizes on **VirtualBox** for Vagrant to avoid Fusion license/plugin coupling and to keep Strategy A and B independent.

---

## 3. Host bring-up

### 3.1 Shared host requirements (Intel Mac)

| Item | Recommendation |
|------|----------------|
| Machine | **Intel Mac** (e.g. 2019 iMac) for x64 Windows guests |
| Host OS | macOS 15 (Sequoia) is fine on supported Intel Macs |
| Guest arch | **Windows 10 or 11, 64-bit (x86_64)** |
| Disk budget | Plan **80 GB+** per Windows VM (VS + SDKs + build trees) |
| RAM budget | **8 GB** guest minimum; **16 GB** preferred for VS 2022 — leave headroom for macOS |

### 3.2 Strategy A — Manual VMware Fusion

1. Install **VMware Fusion** (Pro/Player as licensed).
2. Create a new VM from a legitimate Windows 10/11 **x64** ISO.
3. Suggested VM settings:

| Setting | Suggestion |
|---------|------------|
| CPUs | 4+ |
| RAM | 8–16 GB |
| Disk | 80 GB+ thin-provisioned |
| Display | 1920×1080+; 3D acceleration if offered |
| Network | NAT |
| Shared folders | Optional (see §5) |
| Snapshots | After Windows Update + tooling (§4), before first build |

4. Install **VMware Tools** in the guest.
5. Apply Windows Update once, then snapshot “clean OS” (and again after §4 tooling).

### 3.3 Strategy B — Vagrant + VirtualBox

#### Host packages

On the Intel iMac:

```bash
brew install --cask virtualbox vagrant
# Optional: Extension Pack if required by your VirtualBox version / features
brew install --cask virtualbox-extension-pack
# Ansible control node (Mac → Windows guest over WinRM); see §3.4
brew install ansible
```

Confirm:

```bash
VBoxManage --version
vagrant --version
ansible --version
```

Apple Silicon note: VirtualBox x64 Windows guests belong on the **Intel** iMac. Do not expect this path on the Mac Studio.

#### Windows box and licensing

You need a **Vagrant box** that boots Windows x64 (e.g. a box you build yourself from an ISO, or a trusted published box). Windows licensing still applies — use an ISO/key you are entitled to.

Typical layout next to or inside this repo (example only; not committed unless you add it):

```text
vagrant-windows-putty/
  Vagrantfile
  windows-test                    # one-shot entrypoint (§3.5) — intent; not in-repo yet
  ansible/                        # preferred automation (§3.4)
    inventory/
    playbooks/
    roles/
  scripts/                        # optional thin helpers; avoid duplicating Ansible
```

#### Vagrantfile intent (VirtualBox, Windows x64)

Keep the `Vagrantfile` focused on **VM lifecycle**, not package installs:

- Box name, WinRM communicator, forwarded ports as needed  
- VirtualBox provider: CPUs, RAM (8–16 GB), `gui = true` when you need dialog smoke  
- Synced folder: host PuTTY tree → e.g. `C:\src\PuTTY` (build under `C:\build\...`)  
- Provisioning: either call Ansible from Vagrant, or stop at `vagrant up` and run Ansible separately (§3.4)

Bring-up:

```bash
cd vagrant-windows-putty
vagrant up --provider=virtualbox
# then Ansible (§3.4), or open VirtualBox GUI / RDP for manual smoke
```

Useful commands:

```bash
vagrant halt
vagrant snapshot save clean-tools    # after tooling (§4 / Ansible) succeeds
vagrant snapshot restore clean-tools
vagrant destroy -f                   # full rebuild from box + provision
```

WinRM must be enabled on the box for Vagrant and Ansible; public Windows boxes usually ship that way. Homegrown boxes need WinRM configured before automation can finish.

**Reality check:** VS Build Tools dominate first-boot time. Snapshot (or bake a custom box) after the first successful tooling run.

### 3.4 Ansible — high-level intent (Strategy B)

Ansible is the preferred way to **leverage** Vagrant + VirtualBox for repeatable Windows validation. Vagrant creates the machine; Ansible configures it and runs the non-interactive test loop. This section is **intent only** — no playbooks or task lists in-repo yet.

#### Layering

```text
Intel iMac (Ansible control node)
        │
        ├─ Vagrant + VirtualBox  →  Windows x64 VM, disks, synced folders, WinRM
        │
        └─ Ansible (WinRM)       →  tools → build → console tests
                 │
                 └─ Human / GUI session  →  putty.exe config-dialog smoke (§7.2)
```

| Layer | Owns | Does not own |
|-------|------|----------------|
| VirtualBox | Hypervisor | Packages, builds |
| Vagrant | VM define/up/halt/destroy, synced folders, WinRM reachability | Idempotent software policy |
| Ansible | Guest tooling (§4), MSVC build (§6), console tests (§7.1) | Interactive Win32 GUI QA; Windows licensing / box creation |
| Human | Config-dialog smoke; judgment on UI regressions | — |

#### Control node and connection

- Run Ansible on the **Intel iMac** against the guest over **WinRM** (not SSH).  
- Inventory points at the Vagrant guest (static host + forwarded WinRM port, or dynamic inventory from Vagrant).  
- Expect Windows-oriented collections conceptually (`ansible.windows`, package helpers such as Chocolatey) — exact collection pins left to a future implementation.  
- Two viable trigger styles (pick one and stick to it):  
  - **Vagrant ansible provisioner** — playbook runs as part of `vagrant up` / `vagrant provision`  
  - **Decoupled** — `vagrant up`, then `ansible-playbook` for day-to-day rebuild/test without recreating the VM  

#### Playbook intent (roles / phases)

Organize around phases, not a single monolith:

1. **Bootstrap tooling** — ensure Git, Python 3, CMake, Ninja, and VS 2022 **Build Tools** (MSVC + Windows SDK) are present; long timeouts; prefer Build Tools over full VS.  
2. **Verify toolchain** — fail fast if `cl` / `cmake` / `python` are missing in an x64 developer context.  
3. **Sync or locate source** — use the Vagrant synced tree or clone the same commit validated on macOS/unix; never build object files on the synced folder.  
4. **Configure + build** — out-of-tree build under e.g. `C:\build\putty-win`, Ninja + MSVC Release (or VS generator); `PUTTY_MACOS_GUI` must stay off.  
5. **Console test gate** — run `test_terminal`, `test_conf`, `cgtest`, and `cryptsuite` with `PUTTY_TESTCRYPT` set; **fail the play** on any non-zero exit.  
6. **Report** — emit a short summary (commit SHA, build dir, pass/fail) for copy/paste into PR notes.  

Optional later phases (not required for contribution-risk checks): ASan builds, packaging, artifact copy back to the Mac.

#### Explicitly out of Ansible’s job

- Creating or licensing the Windows Vagrant box  
- Replacing Fusion for day-to-day clicking (§3.2 / §7.2)  
- Automating flaky GUI drivers for the Saved Sessions dialog (keep manual)  
- Apple Silicon / Windows 11 ARM as a stand-in for x64  

#### Lightweight alternative

If Ansible is not installed yet, a one-shot guest PowerShell bootstrap for §4 only is acceptable — but prefer converging on Ansible so build/test are not a second ad-hoc script language.

### 3.5 One-shot entrypoint (Strategy B)

Goal: **one execution** on the Intel iMac that brings up the Windows 11 (or 10) x64 guest, ensures tooling, builds PuTTY as the Windows platform, and runs the console test gate — then exits non-zero on failure.

This is intent only; no wrapper script is checked into this repo yet.

#### Stack (do not replace with something else for local VirtualBox)

```text
windows-test / make windows-test / just windows-test
        │
        ├─ 1. vagrant up --provider=virtualbox
        │       create or start Win11 x64 VM, synced folders, WinRM
        │
        ├─ 2. Ansible (§3.4 phases)
        │       tools (idempotent) → verify → configure/build → console tests
        │
        └─ 3. exit non-zero if any console test fails
```

| Piece | Role in the one-shot |
|-------|----------------------|
| **Wrapper** (shell, Make, or Just) | Single human-facing command; stable name even when internals change |
| **Vagrant** | Orchestrates VirtualBox VM lifecycle |
| **VirtualBox** | Runs the Windows guest |
| **Ansible** | Guest tooling, MSVC build, §7.1 tests |

That trio **is** the local one-shot stack. Ansible alone is a weak VM lifecycle tool; Terraform/Docker/GHA do not replace this path on the iMac.

#### Two shapes (pick one)

1. **Vagrant-provision driven** — `vagrant up --provision` runs the Ansible provisioner through build/test (or `vagrant provision` when the VM already exists).  
2. **Wrapper driven (preferred UX)** — script always does `vagrant up`, then `ansible-playbook …` with tags/phases for build+test so daily runs do not depend on remembering provision flags.

Conceptual daily command (name illustrative):

```bash
./windows-test
# equivalent intent:
#   vagrant up --provider=virtualbox
#   ansible-playbook …   # phases 2–6, or --tags build,test when tools exist
```

#### Cold start vs daily run

| Run | What happens | Expectation |
|-----|----------------|-------------|
| **First cold start** | Box download/import + VS Build Tools + first build | Slow (can be a long wall-clock); not a “quick” one-shot |
| **After tools snapshot / pre-tooled box** | VM start + incremental or clean build + tests | Practical daily one-shot (minutes-scale, hardware-dependent) |
| **VM already up** | Skip create; Ansible build/test only | Fastest iterate |

Bake a **`clean-tools` snapshot** (or a custom box with Build Tools preinstalled) after the first successful tooling phase so `./windows-test` stays usable.

Optional rare phase: **Packer** (or manual) to produce the Windows 11 Vagrant box from an ISO you license. That is **not** part of the daily one-shot; it feeds Strategy B once.

#### What the one-shot must and must not do

**Must**

- Start or create the VirtualBox guest via Vagrant  
- Ensure §4 toolchain (or no-op if already present)  
- Out-of-tree MSVC build (§6)  
- Run §7.1 console tests and **fail the process** on error  
- Print a short pass/fail summary (commit / build dir)

**Must not**

- Claim to automate §7.2 GUI dialog smoke (still human / Fusion / VirtualBox GUI)  
- Build with `PUTTY_MACOS_GUI=ON`  
- Write build trees onto the synced folder  
- Require Apple Silicon / Win11 ARM for “x64 coverage”

#### Relation to Strategy A and CI

- **Fusion (A):** still best for frequent clicking; one-shot does not replace it.  
- **GitHub Actions `windows-latest`:** a *remote* one-shot; complementary, not the same as this VirtualBox stack.  
- On the iMac, treat `./windows-test` as the local equivalent of “push and wait for Windows CI,” plus optional manual GUI smoke.

Same checklist for Fusion-manual and Vagrant guests. Prefer **64-bit** editions.

### 4.1 Required

| Tool | Why | Notes |
|------|-----|--------|
| **Git for Windows** | Clone / update this repo | Include Git Bash; default line endings usually fine for this tree |
| **Visual Studio 2022** | Official Windows toolchain for PuTTY | Workload: **Desktop development with C++**. Include MSVC v143, Windows 10/11 SDK, C++ CMake tools if offered |
| **CMake** ≥ 3.7 (3.20+ fine) | Upstream build system | From [cmake.org](https://cmake.org/), VS bundle, or Chocolatey/`winget`. Must be on `PATH` in the VS Developer environment |
| **Python 3** | `test/cryptsuite.py` and some test helpers | Add `python` / `py` to `PATH`; `pip` not required for cryptsuite |

Visual Studio **Build Tools 2022** (without the full IDE) is enough for CLI builds: same C++ / MSVC / Windows SDK components. Prefer Build Tools under Ansible / Vagrant automation to save disk.

### 4.2 Strongly recommended

| Tool | Why |
|------|-----|
| **Ninja** | Faster incremental builds (`winget`, Chocolatey, or scoop) |
| **Windows Terminal** or **x64 Native Tools Command Prompt for VS 2022** | Consistent `cl.exe` / `link.exe` on `PATH` |

### 4.3 Optional

| Tool | Why |
|------|-----|
| **Halibut** | Rebuild docs / `.chm` from `doc/*.but` |
| **Address Sanitizer** | VS 2022 ASan (`CHECKLST.txt`) |
| **MinGW-w64** | Alternate toolchain; prefer **MSVC** for shipping fidelity |
| **Chocolatey / winget** | Useful under Ansible package tasks or a thin bootstrap |

### 4.4 Verify the toolchain

Open **x64 Native Tools Command Prompt for VS 2022** (or `vcvarsall.bat amd64`) and check:

```bat
where cl
where cmake
where git
python --version
ninja --version
```

`cl` and `cmake` must succeed before configuring the tree.

Under Vagrant / Ansible: prefer the toolchain verify phase in §3.4 (or open `vagrant powershell` and run the same checks by hand).
---

## 5. Getting the source into the guest

### A. Synced / shared folder (Fusion or Vagrant)

- **Fusion:** share the host PuTTY tree; access via `\\vmware-host\Shared Folders\...` or a drive letter.
- **Vagrant:** `config.vm.synced_folder` as in §3.3 (e.g. host repo → `C:\src\PuTTY`).

Always build into a **guest-local** directory (e.g. `C:\build\putty-win`) so object files are not on a slow or locked shared FS.

### B. Clone inside the guest

```bat
cd C:\src
git clone <your-fork-url> PuTTY
cd PuTTY
git checkout main
```

Use the same commit you validated on macOS/unix.

---

## 6. Configure and build (MSVC, x64)

Always use an **x64** (AMD64) developer shell — not x86 — unless you intentionally test 32-bit.

### 6.1 Ninja + MSVC (recommended day-to-day)

```bat
cmake -B C:\build\putty-win -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build C:\build\putty-win
```

Do **not** pass `-DPUTTY_MACOS_GUI=ON` on Windows (Darwin-only).

### 6.2 Visual Studio generator

```bat
cmake -B C:\build\putty-win -G "Visual Studio 17 2022" -A x64
cmake --build C:\build\putty-win --config Release
```

Expect among others: `putty.exe`, `puttytel.exe`, `puttygen.exe`, `pageant.exe`, `plink.exe`, `pscp.exe`, `psftp.exe`, `pterm.exe`, plus `test_terminal.exe`, `testcrypt.exe`, `cgtest.exe`, etc.

### 6.3 Scripted build from the Mac (Strategy B)

Prefer **Ansible** (§3.4 phases 4–5) so configure/build/test share one entry point. A small guest-side wrapper invoked by Ansible is fine; avoid maintaining a parallel ad-hoc `vagrant powershell` one-liner as the primary path.

---

## 7. Tests to run in the guest

From `C:\build\putty-win` (adjust for multi-config `Release\` if needed).

### 7.1 Automated / console

```bat
test_terminal.exe
test_conf.exe
cgtest.exe

set PUTTY_TESTCRYPT=%CD%\testcrypt.exe
python C:\src\PuTTY\test\cryptsuite.py
```

### 7.2 Manual GUI smoke (contribution-risk hotspot)

Requires a **GUI session** (Fusion console, VirtualBox window with GUI enabled, or RDP). Ansible / headless Vagrant cover compile + console tests only — do **not** expect the playbook to replace this smoke.

Shared `config.c` Saved Sessions behavior changed for AppKit; it also affects Windows:

1. Launch `putty.exe`.
2. Select sessions, edit saved-session name, Load / Save / double-click open.
3. Mid-session: Change Settings; confirm Save-as still behaves (no freeze).
4. Optional trivial SSH/raw session; confirm paint and clean exit.

### 7.3 Out of scope unless you invest more

| Item | Notes |
|------|--------|
| `testsc` | Needs DynamoRIO + `test/sclog` — see `test/testsc.c` |
| Installer / Store | `CHECKLST.txt` release items |
| Win95 / old-Windows | Upstream archaeology only |

---

## 8. Suggested workflow (Studio + iMac)

```text
Mac Studio (arm64)              2019 iMac (Intel)
─────────────────              ────────────────────────────────
macos/ AppKit GUI              Strategy A: Fusion — GUI smoke
unix/CLI + Linux Docker   ──►  Strategy B one-shot (§3.5):
                               Vagrant+VirtualBox+Ansible
                               → tools/build/console tests
                               (+ human GUI smoke if not using A)
```

1. Develop and test macOS/unix on the Studio.  
2. On the same commit, on the iMac run the Strategy B **one-shot** (§3.5), or use A/B manually.  
3. Keep §7.2 GUI smoke manual when dialog/`config.c` code changed.  
4. Optionally add GitHub Actions `windows-latest` as a remote one-shot (does not replace local GUI smoke).

---

## 9. Troubleshooting

| Symptom | Likely fix |
|---------|------------|
| `cmake` cannot find a C compiler | x64 Native Tools prompt / `vcvarsall.bat amd64` |
| Wrong arch binaries | `-A x64` / AMD64 environment, not x86 |
| Slow builds on synced folders | Build under `C:\build\...` |
| `cryptsuite` cannot find testcrypt | Set `PUTTY_TESTCRYPT` to full path of `testcrypt.exe` |
| `PUTTY_MACOS_GUI` | Leave off on Windows |
| Guest OOM | Raise VM RAM to 16 GB |
| Vagrant cannot WinRM | Box must enable WinRM; check firewall/creds; enable VirtualBox GUI and fix inside guest |
| Ansible cannot reach guest | Same WinRM path as Vagrant; confirm inventory host/port/creds; install `pywinrm` on the Mac control node if needed |
| VirtualBox + Fusion both installed | Fine as separate strategies; avoid two heavy Windows VMs at once without enough RAM |
| First tooling provision times out | Install VS Build Tools in stages; raise WinRM/Ansible timeouts; snapshot a pre-tooled box |
| One-shot too slow every time | Missing `clean-tools` snapshot / pre-tooled box; cold VS install is re-running — fix bake phase (§3.5) |
| One-shot passes but GUI untested | Expected — run §7.2 manually; do not treat console gate as full Windows QA |

---

## 10. Checklists

### Strategy A — Fusion (first time)

- [ ] Fusion installed  
- [ ] Windows 10/11 **x64** VM (4+ CPU, 8–16 GB RAM, 80 GB+ disk)  
- [ ] VMware Tools; snapshots after OS and after tooling  
- [ ] Guest tools §4  
- [ ] Build + `test_terminal` / cryptsuite + `putty.exe` GUI smoke  

### Strategy B — Vagrant + VirtualBox (+ Ansible)

- [ ] VirtualBox + Vagrant on the Intel iMac  
- [ ] Ansible on the Mac control node (WinRM-capable)  
- [ ] Windows x64 Vagrant box (licensed) with WinRM  
- [ ] `Vagrantfile` focused on VM lifecycle + synced folder; GUI enabled when needed for smoke  
- [ ] Ansible intent implemented later as playbooks/roles covering §3.4 phases (tools → verify → build → console tests)  
- [ ] One-shot entrypoint (§3.5) — e.g. `windows-test` / Make / Just — wraps `vagrant up` + Ansible build/test  
- [ ] Snapshot (or custom box) after first successful tooling install so one-shot stays fast  
- [ ] Console test gate green via one-shot; GUI smoke via VirtualBox/RDP or Strategy A  

### Both

- [ ] Do not treat Windows 11 ARM on Apple Silicon as x64 coverage  
- [ ] Same git commit validated on macOS/unix and Windows  
- [ ] GUI smoke (§7.2) not skipped when `config.c` / dialog code changed  

---

## 11. References

- Root `README` — CMake / MSVC path setup  
- `cmake/toolchain-mingw.cmake` — Linux MinGW cross-compile (compile-check only)  
- `CHECKLST.txt` — upstream release / ASan / old-platform notes  
- `macos/README.md` — native macOS GUI (not used inside the Windows guest)  
- [Vagrant](https://www.vagrantup.com/) / [VirtualBox](https://www.virtualbox.org/) — Strategy B VM layer  
- [Ansible](https://docs.ansible.com/) — Strategy B guest automation (WinRM; see §3.4 intent)  
- §3.5 — local one-shot entrypoint (Vagrant + Ansible wrapper; intent only)  
