# Merge policy (delta592/PuTTY ↔ upstream PuTTY)

This document records **how to merge upstream** into this fork without
wholesale “take theirs” or “take ours”. It is the checklist to run
**before** committing a merge, and the backlog of post-merge work by
priority (P0–P3).

**Remotes**

| Remote | URL | Default branch |
| --- | --- | --- |
| `origin` | `git@github.com:delta592/PuTTY.git` | `main` |
| `upstream` | `https://git.tartarus.org/simon/putty.git` | `main` |

```bash
git fetch upstream
git merge-base HEAD upstream/main   # → $BASE
```

Architecture context: [`MACOS_GUI_PLAN.md`](MACOS_GUI_PLAN.md),
[`macos/README.md`](macos/README.md), [`macos/PARITY.md`](macos/PARITY.md),
[`.cursor/rules/agents.mdc`](.cursor/rules/agents.mdc).

## Goals

1. **Intent-preserving merge** — every upstream merge should **add**
   upstream improvements while **keeping** fork intent (see
   [Fork intent catalog](#fork-intent-catalog)). Neither wholesale
   “take ours” nor wholesale “take theirs”.
2. **Commit messages are the intent spec** — this fork’s detailed local
   commit messages describe *why* each change exists; those intents must
   be evaluated against upstream code changes and merged deliberately
   (see [Commit-driven merge](#commit-driven-merge)).
3. **Absorb upstream** — upstream commit messages and diffs describe
   their intent; combine with fork intent when both touch the same area.
4. **Keep two build worlds explicit** — GUI (`PUTTY_MACOS_GUI=ON`,
   `./macos/build.sh`) vs CLI/unix on Darwin (`PUTTY_MACOS_GUI=OFF`,
   separate build dir). Do not flip the flag inside an existing tree.
5. **Research before resolution** — every non-trivial hunk gets a written
   verdict (Independent / Absorbed / Superseded / Layer / Conflict)
   *before* choosing ours or theirs. “Clean merge” or “already on main”
   is not proof intent survived.

---

## Branch roles (`main` vs `from_parent`)

Use two long-lived branches with different jobs. Confusing them makes
upstream merges look like work was “lost” when it was only **promoted on
a different branch** or **already present under another commit SHA**.

| Branch | Role | When to use |
| --- | --- | --- |
| **`from_parent`** | Integration branch for **upstream merges** and fork fix-ups immediately after | `git fetch upstream && git merge upstream/main` here first; resolve conflicts; run post-merge checklist |
| **`main`** | **Release / default** branch for the fork | Promote tested work from `from_parent` via PR after post-merge verification |

If `from_parent` does not exist yet, create it from `main` before the
first upstream merge:

```bash
git checkout main && git pull origin main
git checkout -b from_parent
git push -u origin from_parent
```

**Promotion flow (required after upstream work on `from_parent`):**

```bash
git fetch origin
git checkout main && git pull origin main
git merge --no-commit --no-ff from_parent   # dry-run: resolve nothing if auto-merge ok
# merged tree should match from_parent tip:
git diff --stat from_parent                 # expect empty
git merge --abort                           # if only testing

# When satisfied: open PR from_parent → main (or merge locally and push)
```

**Do not assume** `main` and `from_parent` tips differ only by “missing
fork work”. They may share the same **tree** for most paths while
histories diverged. Always compare **trees**, not only commit lists:

```bash
git merge-base main from_parent    # note $BASE
git diff --stat main from_parent   # net file delta at tips
git diff --stat $BASE main         # what main added since fork point
git diff --stat $BASE from_parent  # what from_parent added since fork point
```

If `git diff main from_parent` is small but GitHub shows dozens of
commits, the PR is mostly **history reconciliation** — verify the
**Files changed** tab matches the tree diff above.

---

## Commit-driven merge

**Primary rule:** Do not infer fork intent only from the current diff or
[Fork intent catalog](#fork-intent-catalog). Read **local commit messages**
(subject + body) for every commit on the fork that upstream does not
have, then reconcile each intent with what upstream changed in the same
files or problem domain.

### 1. Collect fork intents (before / during merge)

```bash
# Commits on this branch since last shared ancestor with upstream
git fetch upstream
git merge-base HEAD upstream/main    # note the SHA → $BASE
git log --reverse --no-merges ${BASE}..HEAD

# Full messages (subject + body) — the intent spec
git log --reverse --no-merges --format='%H%n%s%n%b---' ${BASE}..HEAD

# Commits touching a conflicted file
git log --no-merges --format='%h %s%n%b' ${BASE}..HEAD -- cmake/setup.cmake
```

For **each local commit**, extract in writing:

| Field | From commit message |
| --- | --- |
| **Problem** | What bug, UX gap, or build pain? (often first paragraph) |
| **Intent** | What must be true after the fix? (invariants, user-visible behavior) |
| **Mechanism** | How this commit achieved it (symbols, flags, files — may be obsolete after merge) |
| **Scope** | Paths / subsystems listed in the message or `git show --stat` |

Example — `a8c6c7d3` *fix(macos): make config Apply/Save honor pending field edits*:

- **Intent:** Apply/Save must persist the values currently visible in
  AppKit fields, including pending `NSTextField` edits and Save with a
  newly typed session name.
- **Mechanism (this commit):** commit pending edits before actions;
  `controlTextDidChange`; radio `mac_uctrl` wiring; Enter-as-Save.
- **After upstream merge:** upstream may change `config.c` / dialog
  control model; **keep intent**, re-port pending-edit commit on the
  macOS control path — not a blind revert of upstream `config.c`.

### 2. Collect upstream intents (same area)

For each fork commit whose `git show --stat` overlaps upstream changes
since `$BASE`:

```bash
git log --oneline ${BASE}..upstream/main -- <paths from fork commit>
git log -1 --format='%B' <upstream-sha>    # read their why, not only the diff
git diff ${BASE}..upstream/main -- <path>  # what actually changed
```

### 3. Reconcile (per fork commit or per theme)

| Verdict | Meaning | Action |
| --- | --- | --- |
| **Independent** | Upstream did not touch this concern | Keep fork change as-is |
| **Absorbed** | Upstream fix satisfies the same intent | Drop fork mechanism; verify with upstream’s tests/checks |
| **Superseded** | Upstream chose a better architecture for the same goal | Take upstream code; confirm intent via behavior ([P0](#priority-backlog-p0p3) checklist) |
| **Layer** | Both intents apply (upstream feature + fork guard) | Merge hunks: upstream structure + fork invariant from message |
| **Conflict** | Same lines, incompatible goals | Human decision; document in merge commit body |

**Never** drop a fork commit’s intent because the merge conflicted or
because upstream refactored the file — only because upstream **fully
satisfies the stated intent** (verify).

### 4. Record in pre-merge matrix

The [pre-merge matrix](#pre-merge-matrix-required) row for each theme
should cite **local commit SHA + one-line intent from the message**,
upstream commit(s), verdict from the table above, and how you verified.

### 5. Research workflow (step-by-step)

Run this for **every upstream merge** on `from_parent` (and again when
promoting to `main` if the tree diff is non-empty).

| Phase | Action | Output |
| --- | --- | --- |
| **A. Baseline** | Tag fork HEAD; `git fetch upstream`; note `$BASE=$(git merge-base HEAD upstream/main)` | Tag name, `$BASE` SHA |
| **B. Fork inventory** | `git log --reverse --no-merges ${BASE}..HEAD` — read **full bodies** | List of local intents (problem → must remain true) |
| **C. Upstream inventory** | `git log --oneline ${BASE}..upstream/main` — group by subsystem | Upstream themes touching same paths as fork |
| **D. Overlap map** | For each fork theme, `git log ${BASE}..upstream/main -- <paths>` | Per-theme upstream SHAs + stated intent |
| **E. Verdict** | Apply [verdict table](#3-reconcile-per-fork-commit-or-per-theme) to each theme | Written decision **before** resolving conflicts |
| **F. Resolve** | Hunk-by-hunk merge; [forbidden shortcuts](#conflict-resolution-rules) off limits | Working tree with combined intents |
| **G. Tree audit** | `git diff --stat $BASE HEAD` vs expectations; [grep checks](#post-merge-verification-required) | Confirm catalog intents still grep-true |
| **H. Dry-run promote** | `git merge-tree $BASE main from_parent` or `--no-commit` merge to `main` | No conflicts; tip tree equals `from_parent` |
| **I. Record** | Merge commit + [decision log](#decision-log-template); update P0–P3 rows | Traceable audit trail |

**Minimum time boxes:** spend at least one pass on each of these even
when Git reports no conflict (upstream may have edited adjacent hunks
only):

| Area | Paths |
| --- | --- |
| CMake / platform select | `CMakeLists.txt`, `cmake/setup.cmake`, `cmake/macos_early.cmake`, `cmake/platforms/macos.cmake` |
| Portable core touchpoints | `putty.h`, `config.c`, `settings.c`, `terminal/`, `ssh/`, `crypto/` (only where fork already touched) |
| Unix shims shared with macOS | `unix/**` files adapted or symlinked into `macos/` |
| macOS platform + bridge | `macos/platform/`, `macos/bridge/` |
| Swift / AppKit UI | `macos/PuttyMacUI/`, `macos/PuTTY/`, `macos/pterm/`, `macos/puttygen/` |
| Build / test entrypoints | `macos/build.sh`, root `Makefile` (convenience only), `macos/tests/` |
| CI | `.github/workflows/`, `.github/codeql/` |
| Docs that encode intent | `README`, `MACOS_GUI_PLAN.md`, `macos/{README,PARITY,AGENT,TESTING,INTEGRATION}.md` |

### 6. Decision log template

Copy into the merge commit body or a PR description. One block per theme.

```markdown
### Theme: CMake Darwin platform selection
- **Fork commit(s):** de1b7abc — Darwin + PUTTY_MACOS_GUI=ON selects platform=macos
- **Upstream:** <sha> — cmake/setup.cmake platform probe changes
- **Verdict:** Layer
- **Resolution:** Keep PUTTY_MACOS_GUI branch; take upstream Windows/unix probe fixes
- **Dropped mechanism:** (none)
- **Verify:** cmake -B /tmp/putty-gui -G Ninja -DPUTTY_MACOS_GUI=ON && test -d …; rg 'PUTTY_MACOS_GUI' cmake/setup.cmake
```

Required fields: **fork SHA + intent sentence**, **upstream SHA + intent**,
**verdict**, **what we kept**, **what we deliberately dropped**,
**verification command**.

### 7. Agent / reviewer obligation

When resolving an upstream merge in this repo:

1. Run `git log ${BASE}..HEAD` and read **bodies**, not only subjects.
2. For each conflicted or high-risk file, list fork commits touching it
   and upstream commits touching it; reconcile before choosing hunks.
3. **Never** resolve by directory (`checkout --theirs macos/`,
   `checkout --ours cmake/`) or by “fewer conflicts”.
4. Produce a [decision log](#decision-log-template) entry for every
   catalog intent and every conflicted file.
5. After resolution, run `git diff --stat main from_parent` (or
   `$BASE..HEAD`) and explain any unexpected file list — “missing” on
   GitHub often means **already merged**.
6. Merge commit message should reference fork SHAs whose intent was
   **layered** or **re-ported** (e.g. `Re-port pending-edit Apply/Save
   from a8c6c7d3 on upstream config.c`).
7. Do not mark the merge complete until **`./macos/build.sh --dev`**
   (or documented equivalent) builds and [post-merge verification](#post-merge-verification-required)
   passes — configure-only success is insufficient.

---

## Core principle: intent-preserving merge

**Do not use blind strategies:**

| Strategy | Problem |
| --- | --- |
| `git checkout --ours` / `merge=ours` on whole trees | Drops upstream fixes and new features in those paths |
| `git checkout --theirs` on `cmake/`, `unix/`, or portable core | Drops GUI platform wiring, bridge hooks, and macOS-required core fixes |
| `git checkout --theirs macos/` | Erases the native AppKit front end |
| Auto-resolving conflicts without reading both sides | Handlers/bridge survive but CMake platform select or Swift call sites break |
| Merging upstream on `main` while fix-ups live only on `from_parent` | `main` looks complete in commit list but lacks latest re-ports until PR |
| Judging by **Commits** tab count on GitHub | Same patch under different SHAs looks like duplicate or missing work |
| Judging by **commit list** instead of **tree diff** | Shared content hides in history; only net file delta matters at tips |

**Do use this loop for every conflicting or high-risk file:**

1. **Fork intent from commits** — quote or paraphrase the local commit
   message(s) for this file ([§1](#1-collect-fork-intents-before--during-merge));
   separate *intent* from *mechanism*.
2. **Upstream intent from commits** — same for upstream SHAs touching
   the file ([§2](#2-collect-upstream-intents-same-area)).
3. **Reconcile** — use the [verdict table](#3-reconcile-per-fork-commit-or-per-theme);
   combine unless **Conflict**; then upstream *mechanism* + re-port fork
   *goal* from the message.
4. **Verify** — behavior the commit message promised, not “our diff still
   applies verbatim”.

### Detecting silent loss (tree audit)

A merge can be “successful” while fork intent is gone. After resolving,
check **outcomes**, not **whether our old diff still applies**:

```bash
# 1. Net change at tip vs pre-merge tag
git diff merge-base/pre-upstream-YYYYMMDD..HEAD --stat

# 2. Catalog intents still present (adjust patterns as catalog grows)
rg 'PUTTY_MACOS_GUI' cmake/setup.cmake CMakeLists.txt
rg 'platform macos|PUTTY_MACOS_GUI' cmake/setup.cmake
test -f macos/bridge/putty-bridge.h
test -f macos/build.sh
rg 'PuttyMainHop' macos/PuttyMacUI -g '*.swift' | head
rg 'SSH_AUTH_SOCK' macos/AGENT.md macos/platform/agent-client.c

# 3. Abandoned GTK/macOS path stays unused for the native GUI
rg 'OSX_GTK|osxlaunch' macos/ CMakeLists.txt cmake/ || true
# expect: no revival of GTK-on-Quartz as the GUI path

# 4. Root convenience Makefile still documents build.sh (if kept)
rg 'macos/build.sh' Makefile README macos/README.md

# 5. Fork-only symbols / entrypoints from recent local commits still exist
git log --no-merges -10 --format='%s' ${BASE}..HEAD
```

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| GUI configure picks `unix/` on Darwin | `PUTTY_MACOS_GUI` branch dropped from `cmake/setup.cmake` | Re-layer platform select; keep `cmake/platforms/macos.cmake` |
| `macos/` builds but Swift cannot call C | Bridge header / module map lost or renamed without Swift update | Restore `macos/bridge/` API; update `PuttyBridge` consumers |
| App launches; first TCP connect fails oddly | Main-thread / `PuttyMainHop` / `dlg_end` deferral dropped | Re-port bridge↔UI hop commits; see agents / bridge-and-ui rules |
| Config Apply/Save writes stale values | Pending-edit macOS path lost while `config.c` took upstream | Re-port Apply/Save pending-edit intent on new dialog code |
| Agent auth broken on macOS | Agent client no longer uses `$SSH_AUTH_SOCK` | Restore OpenSSH-agent default ([`macos/AGENT.md`](macos/AGENT.md)) |
| CodeQL Swift job missing / always skipped | Workflow took upstream-only or lost path filters | Re-layer fork CodeQL manual Swift build |
| `build.sh check` no longer requires CMake ≥ 3.28 | Script / CMake floor dropped | Restore GUI CMake floor in `macos/CMakeLists.txt` + `build.sh` |
| GitHub PR shows huge file count but tips match | History divergence, same tree region | Read **Files changed**; use `git diff main from_parent` locally |

### Before merging

```bash
git tag merge-base/pre-upstream-$(date +%Y%m%d)   # fork HEAD; for diff during resolution
git fetch upstream
git merge upstream/main   # resolve file-by-file, not directory-by-directory
```

During resolution, keep three versions visible (`git show :1/:2/:3` or a
merge tool) plus `git show merge-base/pre-upstream-…:path` for pre-merge
fork content.

### Per-file decision guide

| Situation | Resolution |
| --- | --- |
| Upstream only changed unrelated hunks | Accept upstream; confirm fork intent markers still present (grep) |
| Fork only changed; upstream untouched | Keep fork change |
| Both changed same region | **Manual merge** — combine intents; do not pick a whole side |
| Upstream replaced architecture (e.g. seat/dialog internals) | **Upstream code** + re-apply fork **goals** ([P0](#priority-backlog-p0p3), [P1](#priority-backlog-p0p3)) |
| Upstream added portable Conf keys / dialog controls | Take upstream; ensure macOS config UI still renders and saves them |
| Upstream changed `unix/` module also copied/adapted under `macos/platform/` | Update **both** or document intentional skew; prefer shared intent |
| Upstream added CI / Buildscr steps | Take if useful; keep fork CodeQL Swift manual build intact |

### Examples (fork-shaped)

| File / theme | Wrong | Right |
| --- | --- | --- |
| `cmake/setup.cmake` | Take theirs → Darwin always `unix` | Theirs **plus** `elseif(PUTTY_MACOS_GUI) set(platform macos)` |
| `macos/**` | Take theirs (often “deleted by them”) | **Keep** entire native GUI tree; only merge if upstream adds overlapping paths |
| `config.c` | Take ours → lose upstream dialog fixes | Theirs **plus** re-port pending-edit / macOS control intents |
| `terminal/terminal.c` | Take ours wholesale for snprintf hardening | Prefer upstream if absorbed; else layer snprintf (or equivalent) on upstream |
| `unix/pageant.c` | Drop fork `readlink` before symlink replace | Layer safety fix on upstream pageant path |
| `.github/workflows/codeql.yml` | Take theirs → lose Swift manual build | Combine upstream hygiene with fork manual Swift / path filters |
| `README` | Take theirs → lose macOS GUI quick start | Upstream text **plus** “Building on macOS (native GUI)” section |

---

## Fork intent catalog

Permanent fork choices upstream is unlikely to adopt as-is. After every
merge, these **behaviors** must still hold — implementation may change if
upstream refactors.

| Intent | Must remain true | Where to check |
| --- | --- | --- |
| Native AppKit GUI | `macos/` is the Darwin GUI platform; GTK-on-Quartz / `osxlaunch` is **not** the product path | `cmake/setup.cmake`, `macos/`, `MACOS_GUI_PLAN.md` |
| CMake platform select | `PUTTY_MACOS_GUI=ON` on Darwin → `platform=macos` | `cmake/setup.cmake`, `cmake/platforms/macos.cmake` |
| Stable C bridge | Swift talks to PuTTY via `macos/bridge/` opaque API, not ad hoc struct poking | `macos/bridge/putty-bridge.h`, `PuttyBridge` module |
| Main-thread discipline | PuTTY C / bridge calls and AppKit UI mutations stay on the main thread (`PuttyMainHop`) | `macos/PuttyMacUI/`, bridge asserts |
| Universal 2 releases | GUI release profile can produce arm64+x86_64 apps via Xcode generator | `./macos/build.sh --universal`, `PUTTY_MACOS_UNIVERSAL` |
| OpenSSH agent default | GUI uses `$SSH_AUTH_SOCK`; no required Pageant.app | `macos/AGENT.md`, `macos/platform/agent-client.c` |
| Documented parity gaps | X11 / GSSAPI / serial gaps stay honest; no silent fake substitutes | `macos/PARITY.md` |
| GUI CMake floor | GUI configures require CMake ≥ 3.28; root minimum stays compatible with upstream non-GUI | `macos/CMakeLists.txt`, `macos/build.sh check`, root `CMakeLists.txt` |
| Separate GUI vs CLI trees | Never flip `PUTTY_MACOS_GUI` in an existing build dir | `macos/README.md` |
| Build entrypoint | `./macos/build.sh` remains the supported local GUI workflow | `README`, `macos/README.md`, `Makefile` |
| CodeQL covers Swift | Advanced CodeQL keeps a **manual** Swift build for AppKit sources | `.github/workflows/codeql.yml` |
| Minimal core diffs | Portable / `unix/` / `windows/` changes stay reviewable and tied to a stated intent | `git diff upstream/main -- . ':!macos'` |

**Acceptable:** upstream edits the same files if fork intent still passes
verification.

**Not acceptable:** intent gone but “merge was clean” — e.g. `macos/`
present but CMake always selects `unix/`, bridge compiles but UI hops
dropped, or README no longer documents the native GUI.

---

## Pre-merge matrix (required)

For each **theme** below, fill in from [commit-driven merge](#commit-driven-merge):

- *Local commit(s)* — SHA + **intent sentence from message body** (not just subject)
- *Upstream commit(s)* — SHA + their stated intent
- *Verdict* — Independent / Absorbed / Superseded / Layer / Conflict
- *Verification* — command or manual step proving intent still holds

| Theme | Local | Upstream | Decision rule |
| --- | --- | --- | --- |
| CMake / Darwin platform | `PUTTY_MACOS_GUI`, `cmake/platforms/macos.cmake`, `cmake/macos_early.cmake` | `cmake/setup.cmake`, root `CMakeLists.txt` | **Layer** — upstream structure + macOS GUI platform branch |
| `macos/` tree | platform, bridge, PuttyMacUI, apps, `build.sh`, tests | usually absent upstream | **Keep local**; treat upstream adds under same paths as Layer |
| Portable core touchpoints | `putty.h` SPR init, `config.c` Apply/Save, snprintf hardening, etc. | same files | **Reconcile per commit**; prefer Absorbed when upstream has equivalent hardening |
| `unix/` shims | pageant symlink safety, network/pty/serial tweaks | `unix/**` | **Layer** fork fixes; update `macos/platform/` copies when they diverge |
| SSH / crypto / terminal | only fork-touched hunks | frequent upstream churn | Take upstream unless fork intent still required; re-port narrowly |
| CI (CodeQL) | manual Swift build, path filters, schedule | none or different | **Keep fork workflow**; absorb upstream Actions hygiene if any |
| Docs / plan | `MACOS_GUI_PLAN.md`, `macos/*.md`, README macOS section | README / faq | **Keep fork docs**; merge upstream README/faq text around them |
| Tooling / ignore | `.gitignore`, `renovate.json`, `.cursor/rules/` | upstream `.gitignore` | **Layer** — do not lose fork ignore / agent rules |

## Conflict resolution rules

When Git reports a conflict, follow
[intent-preserving merge](#core-principle-intent-preserving-merge):

1. **Identify file role** — cmake, portable core, unix shim, macos
   platform/bridge, Swift UI, workflow, docs.
2. **Look up fork intent** in the [catalog](#fork-intent-catalog) (if any).
3. **Read all three versions** — base, ours, theirs; use pre-merge tag
   for fork reference.
4. **Resolve the conflict hunk**, not the file — combine upstream
   additions with fork intent.
5. **Forbidden shortcuts** — `checkout --ours` / `--theirs` on whole
   files under `macos/`, `cmake/`, portable core, `unix/`, or `.github/`
   except as a temporary step before manually re-applying the other
   side’s needed hunks.
6. **Role-specific hints** (still manual):
   - **`cmake/setup.cmake`** — upstream probes + `PUTTY_MACOS_GUI` → `macos`.
   - **Portable core** — upstream structure + narrow fork invariants.
   - **`macos/platform/`** — stay aligned with `unix/` where code was
     adapted; no GTK.
   - **Bridge / Swift** — preserve ownership comments and main-thread
     asserts; re-port UI hops after API renames.
   - **Workflows** — keep manual Swift CodeQL build.
7. **When stuck** — prefer **Layer** (upstream mechanism + fork
   invariant) over picking a whole side. If verdict is **Conflict**,
   stop and document both intents in the merge commit / PR; do not
   silently take one side.

### Temporary `--ours` / `--theirs` (allowed only with immediate re-application)

Whole-file checkout is permitted **only** as a scratch step when
immediately followed by manually re-applying the other side’s required
hunks:

```bash
# BAD (final state): git checkout --theirs cmake/setup.cmake
# OK (intermediate):
git checkout --theirs cmake/setup.cmake
# then manually re-apply from pre-merge tag / fork commit:
git show merge-base/pre-upstream-YYYYMMDD:cmake/setup.cmake | …
# or cherry-pick hunks from de1b7abc onto upstream structure
```

The **final** file must satisfy both upstream architecture and fork
intent verification. Never commit immediately after a whole-file
checkout without the re-application step.

## Post-merge verification (required)

Run in order after every upstream merge:

### Build

- [ ] `./macos/build.sh check` succeeds on the merge machine
- [ ] `./macos/build.sh --dev` configures and builds
- [ ] Optional: `./macos/build.sh --cli` still configures (unix platform tree)
- [ ] Optional release gate: `./macos/build.sh verify --universal` when
      touching arch / bundle / link flags

### Intent greps

```bash
rg 'PUTTY_MACOS_GUI' cmake/setup.cmake
rg 'elseif\(PUTTY_MACOS_GUI\)|set\(platform macos\)' cmake/setup.cmake
test -f macos/bridge/putty-bridge.h && test -x macos/build.sh
rg 'PuttyMainHop' macos -g '*.swift' | head
rg 'SSH_AUTH_SOCK' macos/AGENT.md
```

### Tests

- [ ] `./macos/build.sh test --dev` (or `make test` in the GUI build dir)
- [ ] If terminal rendering / TermWin changed: keep paint-budget /
      `test-perf` green ([`macos/TESTING.md`](macos/TESTING.md))
- [ ] If bridge lifetime / concurrency touched: consider sanitizer smoke

### Manual UI smoke (macOS GUI)

- [ ] Launch PuTTY.app; open a saved session (selection → Open without
      extra Load if that intent is still catalogued)
- [ ] First LAN/SSH connect still works (Local Network / `dlg_end` deferral)
- [ ] Config Apply/Save persists visible field edits
- [ ] App menu Hide (⌘H); Settings… still present
- [ ] Agent auth still follows `$SSH_AUTH_SOCK` when keys are loaded

### Docs sanity

- [ ] Root `README` still has the native macOS GUI section
- [ ] `macos/PARITY.md` / `AGENT.md` still match behavior after merge

---

## Priority backlog (P0–P3)

Update status rows when a merge creates new re-port work. IDs are
stable references for merge commit messages (`MERGE_POLICY P0-1`).

### P0 — Correctness / crash / security boundary (must fix before trusting the merge)

| ID | Issue | Local theme | Status | Implementation / verify |
| --- | --- | --- | --- | --- |
| **P0-1** | Bridge / session lifetime (UAF on fatal, TermWin free on main, null after `sfree`) | `fix(macos)` / `fix(bridge)` lifetime commits | **Ongoing** | Grep bridge free paths; run session open/close + fatal disconnect |
| **P0-2** | Main-thread hops for C→Swift UI and first-connect `dlg_end` deferral | `PuttyMainHop`, session present async | **Ongoing** | First connect must not break; no UI mutations off main |
| **P0-3** | Config Apply/Save honors pending AppKit edits | `a8c6c7d3` and follow-ups | **Ongoing** | Edit field → Apply/Save without blur; Saved Sessions Enter-to-Save |

**Do not** “simplify” by deleting bridge asserts or hopping UI work onto
background queues to clear a merge conflict.

---

### P1 — Performance / UX (measure; keep gates)

| ID | Issue | Status | Action |
| --- | --- | --- | --- |
| **P1-1** | Terminal paint budget / TermWin scroll-resize smokes | **Ongoing** | Keep Phase 4 perf gates green when touching terminal draw path |
| **P1-2** | Selection drag auto-scroll, mouse modes, saved window size/colours | **Ongoing** | Re-port UI intents if upstream/termwin churn conflicts |
| **P1-3** | Local Network privacy on first LAN connect | **Ongoing** | Behavior documented in `macos/PARITY.md` / related fixes must survive |

---

### P2 — Build / CI hygiene

| ID | Issue | Status | Action |
| --- | --- | --- | --- |
| **P2-1** | GUI CMake ≥ 3.28 floor | **Ongoing** | `macos/CMakeLists.txt` + `build.sh check`; do not raise root minimum without cause |
| **P2-2** | CodeQL manual Swift build + path filters | **Ongoing** | Preserve `.github/workflows/codeql.yml` intent after Actions bumps |
| **P2-3** | Separate GUI / CLI / universal build directories | **Ongoing** | Documented in `macos/README.md`; merge must not collapse them |
| **P2-4** | Coverage / sanitizer / quality targets in root `Makefile` | **Ongoing** | Convenience only — not a second build system; keep `build.sh` canonical |

---

### P3 — Structural clarity (docs / skew; no forced unification)

| ID | Issue | Status | Action |
| --- | --- | --- | --- |
| **P3-1** | Parity gaps (X11, GSSAPI, serial) | **Documented** | Keep [`macos/PARITY.md`](macos/PARITY.md) honest; do not invent incomplete substitutes |
| **P3-2** | Agent strategy (OpenSSH default; Pageant.app deferred) | **Documented** | [`macos/AGENT.md`](macos/AGENT.md) |
| **P3-3** | Signing / notarization / upstream `Buildscr` alignment | **Deferred** | See `MACOS_GUI_PLAN.md` Phase 8 / 10 notes |
| **P3-4** | Next merge uses this policy | **Ongoing** | Run research workflow + matrix + post-merge checklist; promote `from_parent` → `main` via PR |

---

## CI policy

- **Keep** the fork’s Advanced CodeQL workflow: C/Python cheap path +
  **manual** Swift build for AppKit sources (default setup cannot build
  this tree).
- **Absorb** useful upstream CI if upstream ever adds GitHub Actions;
  do not delete Swift tracing to “simplify”.
- Path filters should continue to skip Swift analysis on PRs that do not
  touch `macos/**` (and related cmake/workflow paths). Push to `main`
  runs the cheap C/Python jobs (Security tab default-branch alerts);
  schedule runs stay full-coverage including Swift. Do not enable Swift
  on every push.

```bash
# Post-merge: Swift manual build still present
rg -n 'build-mode:\s*manual|PUTTY_MACOS_GUI|macos/build' .github/workflows/codeql.yml
```

## Version / tool skew (document; do not “fix” blindly)

| Component | Fork GUI expectation | Upstream / CLI note |
| --- | --- | --- |
| CMake | ≥ **3.28** when `PUTTY_MACOS_GUI=ON` | Root `cmake_minimum_required` stays broader for non-GUI |
| Xcode / Swift | Xcode **16+**, Swift **6**, macOS **15+** deploy | N/A upstream |
| Generators | Ninja (dev/host), Xcode (Universal 2) | Upstream flexible |
| Agent | `$SSH_AUTH_SOCK` OpenSSH | Unix Pageant / Windows Pageant differ by platform |
| Frontend | AppKit `macos/` | Win32 `windows/`, GTK `unix/` |

Align pins only when deliberately shipping a **release channel** (e.g.
notarized Universal 2) that needs a frozen Xcode/CMake combo.

## Promoting `from_parent` → `main` (after upstream merge)

When `from_parent` has passed
[post-merge verification](#post-merge-verification-required):

1. **Confirm tree delta** — `git diff --stat main from_parent` lists only
   expected follow-up commits (e.g. P0 re-ports), not accidental churn.
2. **Open PR** — base `main`, compare `from_parent`; title/body use
   [conventional commit](#commit-message-convention) style; include
   [decision log](#decision-log-template) themes for anything re-ported.
3. **Merge strategy** — merge commit (preserve history) unless you
   deliberately squash; either way, **merged `main` tree must equal
   `from_parent` tip** (`git diff` empty).
4. **Do not** merge upstream directly into `main` while `from_parent` is
   the active integration branch — you will fork history and duplicate
   “missing work” confusion.

---

## Local-only commit themes (audit reference)

Quick map of fork-only work vs typical merge outcome. Refresh after large
merges with `git log --reverse --no-merges $(git merge-base HEAD upstream/main)..HEAD`.

| Theme | Typical verdict |
| --- | --- |
| Entire `macos/` AppKit GUI, bridge, `build.sh`, tests | **Independent** / keep — upstream has no equivalent tree |
| CMake `PUTTY_MACOS_GUI` platform selection + Universal 2 | **Layer** on upstream cmake |
| OpenSSH agent default + AppKit askpass | **Independent** (macOS policy) |
| Config pending-edit Apply/Save | **Layer** on upstream `config.c` / dialog changes |
| Bridge lifetime / main-thread hops / first-connect deferral | **Layer** — re-port if APIs move |
| snprintf / stream hardening in portable files | **Absorbed** if upstream equivalent appears; else **Layer** |
| `unix/pageant` symlink `readlink` safety | **Layer** unless upstream lands equivalent |
| CodeQL Swift manual workflow | **Independent** / keep |
| `MACOS_GUI_PLAN.md`, `macos/*.md`, `WIN_BUILD_ENV.md`, `AUDIT.md` | **Independent** |
| `.cursor/rules/` agent guidance | **Independent** |
| Abandoned GTK/osxlaunch not used for product GUI | **Keep** — do not revive as substitute for AppKit |

## Commit message convention

### Local (fork) commits

Detailed messages are **required intent documentation**. Prefer:

- **Subject:** `type(scope): imperative summary` (≤72 chars)
- **Body:** problem → root cause → what changed (bullet symbols/files) →
  user-visible outcome
- **Footer:** `Fixes …` / crash signature when applicable

Future merges depend on this body; a subject-only commit is harder to
reconcile safely.

### After merge fix-ups

Use one commit per priority band when practical. Reference **source fork
SHA** and intent:

```
fix(merge): re-port config Apply/Save pending edits from a8c6c7d3 (MERGE_POLICY P0-3)

Upstream dialog/control changes replaced adjacent hunks in config.c.
Keep a8c6c7d3 intent: Apply/Save must commit visible AppKit field values.
```

Also reference `P#-#` from this file when applicable.

### PR title/body (promotion `from_parent` → `main`)

**Title:** one line, highest-risk theme first — e.g.
`fix(merge): re-port macOS bridge lifetime and CMake platform select after upstream`

**Body:** Summary bullets grouped by `fix(merge)` / `feat(macos)` /
`build(...)` commits; **Test plan** checklist from
[post-merge verification](#post-merge-verification-required); note if
GitHub file count exceeds net tree diff (history artifact).
