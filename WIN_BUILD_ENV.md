# Windows build / test environment (macOS host)

Guide for validating the **Windows (`windows/`) platform** of this PuTTY tree from a Mac, without a dedicated Windows PC.

**Supported stack:** **Vagrant + VirtualBox + Ansible** on an **Intel Mac** (e.g. 2019 iMac) with a **Windows 10/11 x64** guest.

| Layer | Role |
|-------|------|
| **VirtualBox** | Hypervisor for the Windows x64 guest |
| **Vagrant** | VM lifecycle, synced folders, WinRM |
| **Ansible** | Guest tooling, MSVC build, console tests |
| **One-shot wrapper** (§3.4) | Single command: up → provision → build → test |

Prefer the Intel iMac for this path. Apple Silicon is **not** a substitute for native x64 Windows QA (VirtualBox x64 Windows guests belong on Intel).

Related docs: root `README` (CMake / MSVC), `macos/README.md` (native macOS GUI — separate from this guide).

---

## 1. Goals

| Goal | How this env helps |
|------|--------------------|
| Compile as `platform = windows` | MSVC (or MinGW) inside the guest |
| Run portable tests | `test_terminal`, `testcrypt` + `cryptsuite.py`, `cgtest`, utils binaries |
| Smoke Win32 GUI | Launch `putty.exe` via VirtualBox GUI or RDP; exercise Saved Sessions / config dialog |
| Match most users | Real **x86_64** Windows, not ARM64-with-emulation |

This tree’s macOS AppKit work lives under `macos/` and does not replace Windows testing. Shared C changes (e.g. `config.c`, crypto, `terminal/`) **do** affect Windows and should be verified here.

---

## 2. How to use the stack

| Need | Use |
|------|-----|
| Day-to-day “VM up + build + console tests” | **One-shot** (§3.4) |
| Iterate tools / playbooks without destroying the VM | `vagrant up`, then Ansible with build/test tags (§3.3) |
| Config-dialog / Win32 GUI smoke | VirtualBox window (`gui = true`) or RDP (§7.2) — manual |
| Remote unattended MSVC (optional) | GitHub Actions `windows-latest` — complementary, not this stack |

Guest tooling (§4), source layout (§5), build (§6), and tests (§7) apply once Windows is up. Prefer Ansible (§3.3) over one-off guest scripts. Converge day-to-day work on the one-shot entrypoint (§3.4).

This guide does **not** cover other hypervisors or Vagrant providers. Stick to **VirtualBox**.

---

## 3. Host bring-up (Intel Mac)

### 3.1 Host requirements

| Item | Recommendation |
|------|----------------|
| Machine | **Intel Mac** (e.g. 2019 iMac) for x64 Windows guests |
| Host OS | macOS 15 (Sequoia) is fine on supported Intel Macs |
| Guest arch | **Windows 10 or 11, 64-bit (x86_64)** |
| Disk budget | Plan **80 GB+** for the VM (VS + SDKs + build trees) |
| RAM budget | **8 GB** guest minimum; **16 GB** preferred for VS 2022 — leave headroom for macOS |

Suggested VirtualBox VM shape (set via Vagrant provider):

| Setting | Suggestion |
|---------|------------|
| CPUs | 4+ |
| RAM | 8–16 GB |
| Disk | 80 GB+ |
| Display | Enable GUI when you need §7.2 smoke |
| Network | NAT + WinRM port forward (Vagrant default pattern) |
| Snapshots | `clean-tools` after first successful tooling install |

### 3.2 Vagrant + VirtualBox

#### Host packages

```bash
brew install --cask virtualbox vagrant
# Optional: Extension Pack if required by your VirtualBox version / features
brew install --cask virtualbox-extension-pack
# Ansible control node (Mac → Windows guest over WinRM); see §3.3
brew install ansible
```

Confirm:

```bash
VBoxManage --version
vagrant --version
ansible --version
```

#### Windows box and licensing

You need a **Vagrant box** that boots Windows x64 (build one from an ISO, or use a trusted published box). Windows licensing still applies — use an ISO/key you are entitled to.

Typical layout next to or inside this repo (example only; not committed unless you add it):

```text
vagrant-windows-putty/
  Vagrantfile
  windows-test                    # one-shot entrypoint (§3.4) — intent; not in-repo yet
  ansible/
    inventory/
    playbooks/
    roles/
  scripts/                        # optional thin helpers; avoid duplicating Ansible
```

#### Vagrantfile intent

Keep the `Vagrantfile` focused on **VM lifecycle**, not package installs:

- Box name, WinRM communicator, forwarded ports as needed  
- VirtualBox provider: CPUs, RAM (8–16 GB), `gui = true` when you need dialog smoke  
- Synced folder: host PuTTY tree → e.g. `C:\src\PuTTY` (build under `C:\build\...`)  
- Provisioning: Ansible from Vagrant, or `vagrant up` then Ansible separately (§3.3)

Bring-up:

```bash
cd vagrant-windows-putty
vagrant up --provider=virtualbox
# then Ansible (§3.3), or open VirtualBox GUI / RDP for manual smoke
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

Optional rare bake: **Packer** (or manual) to produce the Windows 11 Vagrant box from a licensed ISO. That feeds this stack once; it is not part of the daily one-shot.

### 3.3 Ansible — high-level intent

Ansible configures the guest and runs the non-interactive test loop. **Intent only** — no playbooks in-repo yet.

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
- Expect Windows-oriented collections conceptually (`ansible.windows`, package helpers such as Chocolatey) — exact pins left to a future implementation.  
- Two viable trigger styles (pick one and stick to it):  
  - **Vagrant ansible provisioner** — playbook runs as part of `vagrant up` / `vagrant provision`  
  - **Decoupled** — `vagrant up`, then `ansible-playbook` for day-to-day rebuild/test without recreating the VM  

#### Playbook intent (roles / phases)

1. **Bootstrap tooling** — Git, Python 3, CMake, Ninja, VS 2022 **Build Tools** (MSVC + Windows SDK); long timeouts; prefer Build Tools over full VS.  
2. **Verify toolchain** — fail fast if `cl` / `cmake` / `python` are missing in an x64 developer context.  
3. **Sync or locate source** — Vagrant synced tree or clone the same commit validated on macOS/unix; never build object files on the synced folder.  
4. **Configure + build** — out-of-tree under e.g. `C:\build\putty-win`, Ninja + MSVC Release; `PUTTY_MACOS_GUI` must stay off.  
5. **Console test gate** — `test_terminal`, `test_conf`, `cgtest`, `cryptsuite` with `PUTTY_TESTCRYPT` set; **fail the play** on any non-zero exit.  
6. **Report** — short summary (commit SHA, build dir, pass/fail) for PR notes.  

Optional later: ASan builds, packaging, artifact copy back to the Mac.

#### Explicitly out of Ansible’s job

- Creating or licensing the Windows Vagrant box  
- Automating flaky GUI drivers for the Saved Sessions dialog (keep manual — §7.2)  
- Treating Apple Silicon / Windows 11 ARM as x64 coverage  

#### Lightweight alternative

If Ansible is not installed yet, a one-shot guest PowerShell bootstrap for §4 only is acceptable — but prefer converging on Ansible so build/test are not a second ad-hoc script language.

### 3.4 One-shot entrypoint

Goal: **one execution** on the Intel iMac that brings up the Windows x64 guest, ensures tooling, builds PuTTY as the Windows platform, and runs the console test gate — then exits non-zero on failure.

Intent only; no wrapper script is checked into this repo yet.

#### Stack

```text
windows-test / make windows-test / just windows-test
        │
        ├─ 1. vagrant up --provider=virtualbox
        │       create or start Win11 x64 VM, synced folders, WinRM
        │
        ├─ 2. Ansible (§3.3 phases)
        │       tools (idempotent) → verify → configure/build → console tests
        │
        └─ 3. exit non-zero if any console test fails
```

| Piece | Role |
|-------|------|
| **Wrapper** (shell, Make, or Just) | Single human-facing command |
| **Vagrant** | VirtualBox VM lifecycle |
| **VirtualBox** | Windows guest |
| **Ansible** | Tooling, MSVC build, §7.1 tests |

That trio **is** the local one-shot stack. Ansible alone is a weak VM lifecycle tool; Docker/GHA do not replace this path on the iMac.

#### Two shapes (pick one)

1. **Vagrant-provision driven** — `vagrant up --provision` runs Ansible through build/test (or `vagrant provision` when the VM already exists).  
2. **Wrapper driven (preferred UX)** — always `vagrant up`, then `ansible-playbook …` with tags/phases for build+test.

Conceptual daily command:

```bash
./windows-test
# equivalent intent:
#   vagrant up --provider=virtualbox
#   ansible-playbook …   # phases 2–6, or --tags build,test when tools exist
```

#### Cold start vs daily run

| Run | What happens | Expectation |
|-----|----------------|-------------|
| **First cold start** | Box download/import + VS Build Tools + first build | Slow (long wall-clock) |
| **After tools snapshot / pre-tooled box** | VM start + build + tests | Practical daily one-shot |
| **VM already up** | Ansible build/test only | Fastest iterate |

Bake a **`clean-tools` snapshot** (or a custom box with Build Tools preinstalled) after the first successful tooling phase.

#### What the one-shot must and must not do

**Must**

- Start or create the VirtualBox guest via Vagrant  
- Ensure §4 toolchain (or no-op if already present)  
- Out-of-tree MSVC build (§6)  
- Run §7.1 console tests and **fail the process** on error  
- Print a short pass/fail summary (commit / build dir)

**Must not**

- Claim to automate §7.2 GUI dialog smoke (VirtualBox GUI or RDP — human)  
- Build with `PUTTY_MACOS_GUI=ON`  
- Write build trees onto the synced folder  
- Require Apple Silicon / Win11 ARM for “x64 coverage”

#### Relation to CI

GitHub Actions `windows-latest` is a *remote* one-shot — complementary. On the iMac, `./windows-test` is the local equivalent, plus optional manual GUI smoke.

---

## 4. Guest: tools to install

Prefer **64-bit** editions. Ansible should converge the guest on this set (§3.3).

### 4.1 Required

| Tool | Why | Notes |
|------|-----|--------|
| **Git for Windows** | Clone / update this repo | Include Git Bash |
| **Visual Studio 2022** | Official Windows toolchain | Or **Build Tools 2022** with Desktop C++ / MSVC / Windows SDK |
| **CMake** ≥ 3.7 (3.20+ fine) | Upstream build system | cmake.org, VS bundle, Chocolatey, or `winget`; on `PATH` in VS developer env |
| **Python 3** | `test/cryptsuite.py` | On `PATH`; `pip` not required for cryptsuite |

Prefer **Build Tools** under Ansible to save disk versus the full IDE.

### 4.2 Strongly recommended

| Tool | Why |
|------|-----|
| **Ninja** | Faster incremental builds |
| **Windows Terminal** or **x64 Native Tools Command Prompt for VS 2022** | Consistent `cl.exe` / `link.exe` on `PATH` |

### 4.3 Optional

| Tool | Why |
|------|-----|
| **Halibut** | Rebuild docs / `.chm` from `doc/*.but` |
| **Address Sanitizer** | VS 2022 ASan (`CHECKLST.txt`) |
| **MinGW-w64** | Alternate toolchain; prefer **MSVC** for shipping fidelity |
| **Chocolatey / winget** | Useful under Ansible package tasks |

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

Prefer the Ansible toolchain verify phase (§3.3), or `vagrant powershell` for the same checks by hand.

---

## 5. Getting the source into the guest

### A. Vagrant synced folder

`config.vm.synced_folder` → e.g. host repo to `C:\src\PuTTY`.

Always build into a **guest-local** directory (e.g. `C:\build\putty-win`) so object files are not on a slow or locked synced FS.

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

### 6.3 Scripted build from the Mac

Prefer **Ansible** (§3.3 phases 4–5) or the one-shot (§3.4) so configure/build/test share one entry point.

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

Normally driven by Ansible / the one-shot, not by hand.

### 7.2 Manual GUI smoke (contribution-risk hotspot)

Requires a **GUI session** (VirtualBox window with GUI enabled, or RDP). Headless one-shot covers compile + console tests only.

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
macos/ AppKit GUI              Vagrant + VirtualBox + Ansible
unix/CLI + Linux Docker   ──►  one-shot (§3.4)
                               → tools / build / console tests
                               + manual GUI smoke (§7.2) as needed
```

1. Develop and test macOS/unix on the Studio.  
2. On the same commit, on the iMac run `./windows-test` (or equivalent).  
3. Keep §7.2 manual when dialog / `config.c` code changed.  
4. Optionally add GitHub Actions `windows-latest` as a remote one-shot.

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
| Ansible cannot reach guest | Same WinRM path as Vagrant; confirm inventory host/port/creds; install `pywinrm` on the Mac if needed |
| First tooling provision times out | Install VS Build Tools in stages; raise WinRM/Ansible timeouts; snapshot a pre-tooled box |
| One-shot too slow every time | Missing `clean-tools` snapshot / pre-tooled box; cold VS install is re-running |
| One-shot passes but GUI untested | Expected — run §7.2 manually |

---

## 10. Checklist (first time)

- [ ] Intel iMac with VirtualBox + Vagrant + Ansible  
- [ ] Windows x64 Vagrant box (licensed) with WinRM  
- [ ] `Vagrantfile`: VirtualBox provider, synced folder, GUI when needed for smoke  
- [ ] Ansible phases (§3.3): tools → verify → build → console tests  
- [ ] One-shot entrypoint (§3.4) wrapping `vagrant up` + Ansible  
- [ ] `clean-tools` snapshot (or pre-tooled box) after first tooling install  
- [ ] One-shot console gate green  
- [ ] §7.2 GUI smoke when dialog/`config.c` changed  
- [ ] Same git commit validated on macOS/unix and Windows  
- [ ] Do not treat Apple Silicon / Win11 ARM as x64 coverage  

---

## 11. References

- Root `README` — CMake / MSVC path setup  
- `cmake/toolchain-mingw.cmake` — Linux MinGW cross-compile (compile-check only)  
- `CHECKLST.txt` — upstream release / ASan / old-platform notes  
- `macos/README.md` — native macOS GUI (not used inside the Windows guest)  
- [Vagrant](https://www.vagrantup.com/) / [VirtualBox](https://www.virtualbox.org/) — VM layer  
- [Ansible](https://docs.ansible.com/) — guest automation (WinRM; see §3.3)  
- §3.4 — local one-shot entrypoint (intent only)  
