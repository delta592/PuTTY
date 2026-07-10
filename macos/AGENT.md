# macOS SSH agent strategy (Phase 7.4)

For local GUI build/run instructions, see [`README.md`](README.md).

## Decision: OpenSSH agent is the default

PuTTY for macOS uses the **system OpenSSH agent** via `$SSH_AUTH_SOCK` as
the primary authentication agent. This matches how Terminal, iTerm2, and
other macOS SSH clients work, and avoids running a second long-lived
agent process for typical use.

| Approach | Role |
|----------|------|
| **macOS `ssh-agent` + `ssh-add`** | **Default.** Keys loaded into the login/session agent. |
| **CLI `pageant`** | Optional PuTTY-compatible agent (OpenSSH wire protocol). |
| **Pageant.app (`NSStatusItem`)** | Deferred — not required for Phase 7. |
| **Keychain private-key storage** | Future enhancement — not implemented. |

## How PuTTY.app uses the agent

1. `CONF_tryagent` defaults to **true** (“Attempt authentication using Pageant”
   in Connection → SSH → Auth).
2. `macos/platform/agent-client.c` connects only to `$SSH_AUTH_SOCK` (same as
   Unix PuTTY). There is no separate Pageant IPC path on macOS.
3. If `$SSH_AUTH_SOCK` is unset or the agent has no usable keys, SSH falls
   back to other configured auth methods (password, keyboard-interactive,
   public key files).

**Practical setup**

```sh
# Load a key into the macOS agent (often already done at login):
ssh-add --apple-use-keychain ~/.ssh/id_ed25519

# Confirm the agent is reachable:
echo "$SSH_AUTH_SOCK"
ssh-add -l
```

Launch PuTTY.app from an environment that inherits `$SSH_AUTH_SOCK`
(Dock/Finder usually get the login agent; GUI apps launched from a
custom shell may need the variable exported in the launch environment).

Agent forwarding: enable **Allow agent forwarding** under Connection →
SSH → Auth when the remote session should use your local agent.

## Optional: CLI pageant

The macOS build still installs a Unix-style `pageant` binary
(`macos/platform/pageant.c` → shared `pageant.c` core). Use it when you
want PuTTY-specific agent features (e.g. encrypted-at-rest keys with
runtime unlock, `--askpass`).

```sh
# Start a foreground agent and print shell exports:
eval "$(pageant --foreground)"

# Or run as a one-shot askpass helper (SSH_ASKPASS):
export SSH_ASKPASS="$(which pageant)"
# pageant --askpass "<prompt>"  # used internally / by OpenSSH askpass API
```

Passphrase prompts use **AppKit** (`macos/platform/askpass-appkit.m`), not
GTK. On macOS, pageant does not require `$DISPLAY`; Aqua is treated as
available for GUI prompts. For non-interactive tests, set
`PUTTY_ASKPASS_RESPONSE` to the passphrase string.

## Why not an embedded Pageant.app (yet)

An `NSStatusItem` menu-bar agent (Windows Pageant tray parity) would
duplicate macOS ssh-agent for most users and needs substantial UI work
(key list, add/remove, re-encrypt, single-instance). Phase 7 exit
criteria only require the agent strategy to be **documented and
minimally functional** — OpenSSH agent + working client path already
satisfies that; CLI pageant + AppKit askpass covers the PuTTY-specific
edge cases.

## Future: Keychain storage

Possible later work (not in Phase 7.4):

- Store PuTTY private keys or passphrases in the macOS Keychain under a
  service ID such as `org.tartarus.projects.putty`.
- Optional “remember passphrase” when loading encrypted PPK/OpenSSH keys
  in PuTTYgen or pageant.
- Prefer Keychain over writing unencrypted keys to disk.

Until then, prefer `ssh-add --apple-use-keychain` for OpenSSH-format keys
managed by the system agent.
