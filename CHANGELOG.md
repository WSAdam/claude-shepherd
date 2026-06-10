# Changelog

Notable changes to Claude Shepherd. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal tool with no
versioned releases, so entries are dated. Earlier history is in `git log`.

## 2026-06-10

### Added
- **Fleet insights view.** A new **📊** toolbar button opens a read-only overlay that
  aggregates the audit ledger into fleet stats — turns per session, approval/denial
  rates, decision provenance (autoDeny/autoAllow/autopilot/approveRepeats/human/
  timeout), most-active sessions, and the total time the fleet spent **blocked on you**.
  Pure `core.fleetStats` / `core.fmtDuration` / `core.blockedSeconds`; zero model cost.
  Always available like the audit view (shows zeros until the ledger is enabled).
- **Same-directory collision warning.** When 2+ **active** sessions (working/approval)
  share a working dir, their tiles get an amber ring + "⚠ shared dir" so two agents
  don't silently clobber each other's edits. `collision.useGitRoot` groups by repo root
  (one cached `git rev-parse` per dir). Detection only — it can't lock another process's
  writes. Pure `core.collisions`; cached `FX.gitRoot`. Off by default (`collision.enabled`).
- **Per-session tool gating (least-privilege).** The detail panel's **Gate** dropdown
  (Default / All / None / Custom) overrides the fleet `gate.tools` for one session,
  stored in `~/.claude/cc-gate-tools/<key>`; `cc-approve.sh` consults it on the hot path.
  Lets a risky experiment lock everything down while a trusted session runs free. Pure
  `core.resolveGateTools`. No override → identical to before.
- **Empirical per-session risk score.** An indicator (not a gate) computed from a
  session's ledger history — deny rate, auto-deny hits, timeout-fallbacks, slow
  approvals, tool volume — surfaced as a med/high ⚠/▲ tile badge (low shows nothing).
  No quarantine, no enforcement. Pure `core.sessionRisk`. Off by default (`risk.enabled`);
  `risk.thresholds`/`risk.weights` tunable in config.
- **Graceful drain + one-click respawn.** Right-click **Drain (finish turn, then close)**
  waits for the in-flight turn to finish before closing (closes now if already idle/done;
  wins over auto-feed). **Respawn from cwd** relaunches a dead/stale session from its last
  cwd + matched provider + editor. Pure `core.shouldDrainClose` / `core.respawnSpec` /
  `core.providerByModel`; reuses `FX.spawnSession`. Both off by default
  (`drain.enabled` / `respawn.enabled`).
- **Launch on startup.** ⚙ Settings → **General → "Launch Shepherd on startup"** toggles
  Hammerspoon's real *Open at Login* item (`hs.autoLaunch`). **On by default** the first
  run (one-time, gated by an `hs.settings` flag) so Shepherd returns after a restart.
- **`make dock`.** Pins the existing `Shepherd.app` launcher to the Dock idempotently
  (`app/add-to-dock.sh`; the Dock briefly restarts, reversible by dragging the icon off).

### Changed
- **Settings Save now merges** the managed keys onto the existing `cc-config.json`
  instead of overwriting the whole file, so hand-edited top-level blocks (the new
  risk/collision/drain/respawn/insights blocks, `spawn.kittyBin`, …) survive a Save.

### Fixed
- **Gate-override fails safe.** An empty/half-written `cc-gate-tools/<key>` file was
  lumped with the `-`/`none` sentinels and gated **nothing**; now an empty file falls
  back to the fleet default (only `-`/`none` mean "gate nothing"), matching
  `core.resolveGateTools`. A blank or partial write can no longer silently disable the gate.
- **Accurate "time blocked on you" / risk.** `lastReqTs` was only cleared on a human
  decision, so an auto-allow/deny between a request and a later human decision
  mis-attributed the gap (inflating `approvalBlockedSeconds` / `staleApprovals`). Any
  decision now resolves the pending request; only human/timeout decisions credit the wait.

### Tests
- **~683** side-effect-free checks. New pure coverage for `fleetStats` / `blockedSeconds`
  (incl. the maxBlock-cap drop and auto-decision-clears-pending cases), `sessionRisk`,
  `collisions`, `resolveGateTools` (sentinel + empty-file precedence), `shouldDrainClose`,
  `respawnSpec` / `providerByModel`; new gate cases for per-session overrides (the
  empty-file-still-gates case, polling instead of fixed sleeps).

## 2026-06-09

### Added
- **Audit / event ledger.** Opt-in append-only JSONL record of fleet activity at
  `~/.claude/cc-ledger/YYYY-MM-DD.jsonl` (one event per line), written by the hooks +
  panel: session start/end, prompts, tool requests, gate decisions (with provenance),
  mode/model/effort changes, nudges, clears, compacts, spawns, relabels. **Off by
  default** (`ledger.enabled`), with retention (`retentionDays`, `maxTotalMB`) GC'd ~hourly.
  A **📜 Audit** overlay (Rows + Timeline tabs) filters by session/type/date and supports
  per-row redact, export, and purge. A **Review activity** button sends a slice to the
  selected session as a read-only governance prompt. Pure `core.parseLedger` /
  `filterLedger` / `renderNarrative` / `narrateEvent` / `auditReviewPrompt`.

### Added
- **Providers / multi-model spawn.** A new **Providers** tab in ⚙ Settings defines named
  profiles that launch `claude` against a chosen model: **Claude** tiers (sets
  `ANTHROPIC_MODEL`) or a **Gateway** (sets `ANTHROPIC_BASE_URL` for a LiteLLM-style proxy →
  Gemini/OpenAI, or a local/remote REST server). Pick a provider in the **New session** modal
  or set a **Default provider** (`spawn.provider`); switch a running session's model live from a
  detail-panel **Model** dropdown (`/model`). **No API keys are stored** — a profile names an env
  var (`authTokenEnv`) the spawned login shell expands as `$VAR`. `cc-status.sh` captures
  `ANTHROPIC_MODEL`/`ANTHROPIC_BASE_URL` so tiles show the live backend.
- **SSH remote harness (spawn).** A profile with `ssh:{host,user}` launches
  `ssh -t <dest> '<inner>'` in a local terminal (`core.sshWrap`), so keystroke effects still
  target the local window and `$VAR` secrets expand on the remote. (The status bridge to surface
  remote sessions as tiles is tracked in `todos.md`.)
- **Token-usage bars (local, zero model tokens).** Read from Claude Code's local transcript JSONL.
  Per-tile **context-fullness bar** (model-aware window: Opus 4.x / Sonnet 4.6 = 1M, else 200k,
  with a per-provider `contextLimit` override and a self-healing tier guard). A **fleet-total
  footer** (excludes cache reads) with per-model breakdown in the detail panel, recomputed every
  60s (incremental reads) + an **Update now** button.
- **Official plan-usage window.** The footer's **Session (5h)** / **Weekly** / **Sonnet** %
  comes from Anthropic's `GET /api/oauth/usage` (matches `claude.ai/settings/usage`), using the
  local Claude Code OAuth token. A metadata call — **no model tokens** — polled ≤ every 180s,
  token never logged; falls back to a labeled local approximation if unavailable.
- **Clear / Compact in the tile right-click menu.** Both added next to Relabel / Close, each with
  a native confirm-submenu, reusing the detail-panel effect (`/clear` / `/compact`).
- **Improve button (review-first).** A detail-panel **Improve** button pulls this repo's
  un-applied improvement cards from the AI Monsters leaderboard (`POST /api/grade/claim-cards`)
  and, instead of applying them wholesale like `/improve`, injects a **review** prompt into the
  session (assess and suggest where applicable, propose a plan — no blind edits). Toasts "No
  improvements found" when the latest push's cards are already claimed. Reads `LB_URL`/
  `GRADE_PREVIEW_TOKEN` from the shell via an interactive zsh (Hammerspoon doesn't inherit the
  env; the token is never persisted). Pure `core.repoFromRemote` / `core.improvePrompt` helpers.
- **Jump in the tile right-click menu.** Focus a session's window from the context menu
  (double-click isn't always reliable).

### Fixed
- **Relabels now stick.** Labels were keyed by the session's live `cwd`, which drifts as the
  agent `cd`s around, so the override silently fell off (it would "relabel itself" back). Now
  keyed by a **stable project identity** derived from `transcript_path` (the launch folder),
  with a legacy-`cwd` fallback — a relabel survives directory changes, reloads, and new sessions
  in the same folder. (`core.projectKey`; `applyLabelsByCwd` resolves projectKey then cwd.)
- **Reliable keystroke injection** (nudge / clear / compact / feed / effort / model / answer /
  spawn). Nested `hs.timer.doAfter` chains used anonymous timers that could be garbage-collected
  before firing, silently aborting the sequence mid-way — the chronic "flaky nudge" and the dead
  right-click `/clear` `/compact`. A new `after()` wrapper holds a strong reference to every
  pending timer until it fires. Chat-input focus is also made deterministic (focus the editor
  group, then ⌘Esc, so the toggle always lands on *focused*) and slash commands get a second
  Return past the autocomplete popup.

### Changed
- **Reset countdown shows days/hours/min.** The usage footer renders reset times as `6d 16h 0m`
  instead of `160h 0m` (days only appear past 24h; short windows still read `1h 0m` / `45m`).

### Tests
- ~320 → **~517** side-effect-free checks. New pure-logic coverage for provider env-injection
  (`providerEnv`/`envPrefix`/`spawnSpec` with no real keys), `sshWrap`, and the usage helpers
  (`parseUsageLine`/`sumUsage`/`usageInWindow`/`contextFractionFor`/`isoToEpoch`) — no real keys,
  spawns, or network. The no-provider spawn output is asserted byte-identical to before.
- Added `repoFromRemote` (ssh/https → `owner/repo`), `improvePrompt` (review framing + each card,
  never wholesale), and `projectKey`-keyed relabel tests (projectKey beats a drifted `cwd`).

## 2026-06-04

### Added
- **Persistent relabels.** Tile relabels now survive a reload, a new instance, and
  close/reopen — keyed by **project path** in `~/.claude/cc-labels.json` (was
  in-memory/ephemeral). Relabel to blank or the folder name to clear.
- **Caffeinate toggle.** A **☕ keep-awake** button in the header runs
  `pmset -a disablesleep 1/0` (holds with the lid closed) via a per-toggle admin
  prompt; reads true state with `pmset -g` and reflects it.
- **In-panel "New session" modal** (replaces the two native prompts): folder browser
  (drill in / breadcrumb / "use this folder"), **recent directories**
  (`~/.claude/cc-recent-dirs.json`), **new-project** creation, an editor picker, and
  a permission-mode picker.
- **Editor-aware spawn.** + New opens in Terminal / Kitty / VS Code / Cursor per the
  picker (default `spawn.editor`). Gated by `spawn.live` (default off = dry-run);
  Kitty/Terminal spawn reliably, VS Code/Cursor are best-effort.
- **Shepherd.app Dock launcher.** `make app` / `make setup` builds
  `~/Applications/Shepherd.app` (sheep icon); clicking toggles the panel via the
  `hammerspoon://` URL scheme.
- **Headless approvals.** One-click ⚙ Settings toggle: arms the gate + turns off all
  auto-policies, so Approve/Deny go through the panel headlessly while Claude stays
  fully gated. **Editable gated-tools** list (`gate.tools`) and per-control
  explanations in Settings.
- **Kitty effect routing (Part A).** Per-session effects (focus / approve / deny /
  nudge / close / answer / mode-switch) run headlessly via `kitty @` for Kitty
  sessions — no window focus. Kitty remote control is auto-enabled in `kitty.conf`
  (backed up first) when Kitty is in use; spawned Kitty windows get it via flags.
- **Permission-mode dropdown (Part C).** Switch Default / Accept edits / Plan live via
  Shift+Tab from the detail panel (reliable on Kitty, best-effort in VS Code).
- **Installer (Part E).** `make setup` / `install.sh` — idempotent: copies scripts +
  logic, merges hooks into `settings.json` (backup first, preserving your hooks),
  ensures the `init.lua` dofile, and builds Shepherd.app.

### Changed
- **Editor-window pop split** into `focus.popOnComplete` / `focus.popOnApproval`
  (was a single `focus.popEditor`, still honored as a fallback). `cc-popup.sh` is now
  event-aware and **editor-aware** (routes to the detected editor; leaves Kitty/terminal
  alone instead of hardcoding VS Code).
- `cc_detect_editor` / `cc_editor_app` moved to `cc-lib.sh` (shared by `cc-status.sh`
  + `cc-popup.sh`). Window focus matching (`focusCandidates` / `titleFolderMatch`)
  extracted into `cc-core.lua` and unit-tested.
- `jsString` moved into `cc-core.lua` (escaping now unit-tested).

### Fixed
- **`parseDataUrl`** tolerates extra params (e.g. `data:image/svg+xml;charset=utf-8;base64,`).
- **Multi-select AskUserQuestion** is guarded — Shepherd jumps you to it instead of
  mis-driving the single-select picker keys.

### Tests
- ~188 → **~320** side-effect-free checks, including the config-driven gated-tool
  list and the installer (`tests/install.test.sh`).
