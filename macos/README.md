# Building the macOS GUI locally

This directory is the native **AppKit + Swift** front end for PuTTY on
macOS 15+: **PuTTY.app**, **pterm.app**, and **PuTTYgen.app**.

For a short overview from the repository root, see the “Building on
macOS (native GUI)” section of [`../README`](../README). Architecture
and phase status live in [`../MACOS_GUI_PLAN.md`](../MACOS_GUI_PLAN.md).
SSH agent behaviour is documented in [`AGENT.md`](AGENT.md).

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| macOS 15+ | Deployment target (`PUTTY_MACOS_DEPLOYMENT_TARGET`, default `15.0`) |
| Xcode 16+ | Full app, not Command Line Tools alone; includes Swift 6 |
| CMake ≥ 3.28 | |
| Ninja | Dev / host-arch Release profiles |
| Xcode generator | Universal 2 (`arm64` + `x86_64`) only |
| Python 3 | Icon generation at configure/build time |
| Bash 5.x | Required by `build.sh` (`brew install bash`) |

Point `xcode-select` at Xcode:

```sh
xcode-select --install   # if needed
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Put Homebrew ahead of `/bin` so `./macos/build.sh` finds Bash 5:

```sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
brew install cmake ninja python bash
```

Check the toolchain:

```sh
./macos/build.sh check
# or manually:
xcode-select -p
xcrun --find swiftc && swiftc --version
cmake --version
ninja --version
```

## Quick start (helper script)

From the **repository root**:

```sh
./macos/build.sh --dev              # Debug, host arch → build-macos-gui-dev/
./macos/build.sh open --dev         # launch PuTTY.app
```

| Profile | Build dir | Generator | What you get |
|---------|-----------|-----------|--------------|
| `--dev` (default) | `build-macos-gui-dev` | Ninja Debug | Fast host-arch GUI |
| `--release` | `build-macos-gui` | Ninja Release | Host-arch GUI |
| `--universal` | `build-macos-gui-universal` | Xcode Release | Universal 2 GUI |
| `--cli` | `build-macos-cli` | Ninja | Unix/CLI platform (`PUTTY_MACOS_GUI=OFF`) |

Useful commands:

```sh
./macos/build.sh build --release --open
./macos/build.sh open --dev --app pterm
./macos/build.sh open --dev --app puttygen
./macos/build.sh verify --universal
./macos/build.sh install --release --prefix /Applications
./macos/build.sh clean --dev
./macos/build.sh --help
```

Configure / build / verify / install append to
`<build-dir>/build.log`. Use `--no-log` to skip that.

## CMake directly

Use a **separate** build directory for GUI vs CLI. Do not flip
`PUTTY_MACOS_GUI` in an existing tree.

### Debug (host architecture)

```sh
cmake -B build-macos-gui-dev -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_MACOS_UNIVERSAL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build-macos-gui-dev
open build-macos-gui-dev/PuTTY.app
```

### Release (host architecture)

```sh
cmake -B build-macos-gui -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_MACOS_UNIVERSAL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build-macos-gui
open build-macos-gui/PuTTY.app
```

### Universal 2 (arm64 + x86_64)

Swift fat binaries need the **Xcode** generator:

```sh
cmake -B build-macos-gui-universal -G Xcode \
  -DPUTTY_MACOS_GUI=ON \
  -DPUTTY_MACOS_UNIVERSAL=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build-macos-gui-universal --config Release
lipo -info \
  build-macos-gui-universal/Release/PuTTY.app/Contents/MacOS/PuTTY
# Expected: Architectures in the fat file: … x86_64 … arm64 …
```

With Ninja, `PUTTY_MACOS_UNIVERSAL=ON` only warns and builds the host
arch; it does not produce a fat Swift binary.

### Verify and install

```sh
cmake --build build-macos-gui --target verify-bundle-layout
cmake --build build-macos-gui-universal --config Release --target verify-universal
cmake --install build-macos-gui --prefix /Applications
```

Bundle version strings come from `version.h` / `LATEST.VER` /
`git describe` via [`cmake/bundle_version.cmake`](cmake/bundle_version.cmake).

## Outputs

After a successful GUI build you should have (paths vary slightly for
the Xcode generator’s `Release/` prefix):

- `PuTTY.app` — SSH / Telnet session client  
- `pterm.app` — local terminal  
- `puttygen.app` — key generator  

Plus CLI tools (`plink`, `pscp`, `psftp`, `pageant`, …) linked against
the `macos/` platform when `PUTTY_MACOS_GUI=ON`.

## GUI vs CLI / GTK

| CMake option | Platform | Result |
|--------------|----------|--------|
| `PUTTY_MACOS_GUI=OFF` (default) | `unix/` | CLI tools; GTK `putty`/`pterm` if GTK is found |
| `PUTTY_MACOS_GUI=ON` | `macos/` | Native `.app` bundles + CLI; no GTK |

## Smoke / unit tests (Phase 9.1)

From the repository root (after a GUI configure/build):

```sh
make test              # full CTest suite (label macos)
make test-all          # CTest + portable utils self-tests
make test-unit         # label unit
make test-crypt        # cryptsuite / testcrypt
make test-perf         # Phase 4 paint budget
make test-ui           # PuttyMacUITests (XCTest)
make test-utils        # root utils binaries not in CTest
make help              # list targets
```

Defaults to `PROFILE=dev` → `build-macos-gui-dev`. Override with
`make test PROFILE=release` or `make test BUILD_DIR=…`.

Or via the helper / CMake:

```sh
./macos/build.sh test --dev
cmake --build build-macos-gui-dev --target putty-test-macos
cmake --build build-macos-gui-dev --target putty-test-all
```

CTest covers portable C tests (`test_terminal`, `test_lineedit`, `test_conf`,
`cryptsuite`/`testcrypt`, …), macOS smoke binaries, the Phase 4 perf gate,
and the `PuttyMacUITests` XCTest bundle (launch, local-echo connect, config
save/load). `testzlib` (stdin tool) and `testsc` (DynamoRIO dry-run) are
built but not registered as CTest cases. Manual matrix: [`TESTING.md`](TESTING.md).

Single smoke binary:

```sh
cmake --build build-macos-gui-dev --target putty-bridge-termwin-input-smoke-c
./build-macos-gui-dev/putty-bridge-termwin-input-smoke-c
```

Other `putty-*-smoke-c` / `putty-mac-*-smoke-c` targets exercise config,
seat, clipboard, and related paths. See `macos/CMakeLists.txt` and
`macos/bridge/CMakeLists.txt`.

## Troubleshooting

- **`build.sh` says Bash 5.x required** — install Homebrew bash and put
  it first on `PATH` (see Prerequisites).
- **Swift / SDK not found** — ensure `xcode-select -p` points at
  `Xcode.app/Contents/Developer`, then open Xcode once to accept the
  license.
- **Blank or black terminal** — rebuild after pulling; selection and
  paint fixes landed in the v2.0.0 line. Prefer a clean
  `./macos/build.sh clean --dev` then rebuild if the tree is stale.
- **Agent keys not offered** — load keys into the system agent
  (`ssh-add --apple-use-keychain …`); see [`AGENT.md`](AGENT.md).

## Related docs

| Doc | Role |
|-----|------|
| [`../README`](../README) | Root build overview (all platforms) |
| [`../MACOS_GUI_PLAN.md`](../MACOS_GUI_PLAN.md) | Phased design / remaining packaging |
| [`AGENT.md`](AGENT.md) | OpenSSH agent + askpass |
| [`ACCESSIBILITY.md`](ACCESSIBILITY.md) | Phase 9.2 VoiceOver / keyboard / Reduce Motion |
| [`TESTING.md`](TESTING.md) | Phase 9.1 CTest / XCTest / manual matrix |
| [`PuTTY/TERMINAL_PERFORMANCE.md`](PuTTY/TERMINAL_PERFORMANCE.md) | Terminal paint performance notes |
