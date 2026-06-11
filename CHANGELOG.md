# Changelog

Notable changes to Claude Shepherd. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal tool with no
versioned releases, so entries are dated. Earlier history is in `git log`.

## 2026-06-10 — Dock UX fixes + round-3 review

### Fixed
- **Right-click "Reload" blanked the panel.** On macOS 26, WebKit's native context menu (a
  dark "↻ Reload" pill) popped wherever no tile handler caught the right-click — e.g. the
  header. Reloading the webview loads an empty URL (the HTML is injected once via `wv:html`),
  so the panel went white and the app was dead. A global `contextmenu` suppressor in the
  panel JS kills the native menu everywhere; tiles keep their own menu and ⌘V still pastes.
- **Dock icon never lit its running indicator.** The Shepherd.app launcher quit the instant
  it toggled the panel, so macOS never showed the running dot. An `on idle` handler makes
  `osacompile` produce a stay-open applet that keeps running (dot lit) until you quit it.

### Changed
- **App/Dock icon is now a black German shepherd** (`docs/assets/shepherd.png`).
  `make-icon.sh` prefers that committed image and otherwise draws a black GSD-head silhouette
  (was the 🐑 glyph). The menubar icon stays 🐑 (the flock the shepherd watches).

### Tests
- Round-3 leaderboard review of the prior commit folded in: a one-line rationale for the
  `nowEsc` carry-forward accumulator (why a local, not a mutation of the read-only `pv`
  snapshot), and a **deny-list** assertion in `escaping.test.sh` that fails if ANY user field
  is concatenated into panel HTML without `esc()` — the prior allow-list only caught the three
  KNOWN sinks. Confirmed no deleted-table (`prevStatus`/`prevStale`/`escalated`) references
  linger. **648 core + 104 ui + 129 bash**, all green.


## 2026-06-10 — Round-2 review hardening

A second pass over the bug-sweep commits, driven by leaderboard review. Each suggestion was
verified against the code before applying — one flagged "XSS vulnerability" was already
mitigated, and one proposed test was too weak to catch its own regression; both were
corrected rather than taken at face value.

### Fixed
- **`applyGroups` / `applyLabelsByCwd` cwd-fallback (latent).** The `projectKey`-then-`cwd`
  lookup short-circuited a missing projectKey entry and fell through to the live `cwd`, so a
  session *with* a projectKey but no group/label could inherit a stale legacy cwd-keyed entry
  — re-introducing the cd-drift sensitivity projectKey exists to prevent. The cwd fallback is
  now gated on the absence of a projectKey (genuinely keyless legacy sessions still resolve).
  Both mirror functions fixed, each with a regression test.

### Changed
- **Per-tile refresh snapshot consolidated.** Three parallel module tables —
  `prevStatus` / `prevStale` / `escalated`, all keyed by tile key and touched on the same
  refresh transition — collapsed into one `prev[key] = { status, stale, escalated }` row
  (mirroring the earlier watchdog consolidation), so one delete clears the whole per-tile
  snapshot and the fields can't desync. `respawnAttempts` stays standalone (projectKey-keyed
  per-folder budget). `escalated` now GCs with the row, so a vanished-then-returning stuck
  approval re-nags once.
- **Trimmed four restated header comments** (`filterTiles` / `applyGroups` / `BULK_RULES` /
  `bucketEvents`) to the non-obvious "why", keeping the cross-file "stays in sync with the
  panel JS" warnings.

### Tests
- **648 core + 104 ui + 128 bash** checks, all green. New regression coverage: blocked-
  sparkline per-bucket placement (a wait that crosses an hour boundary) and cross-session
  mis-pairing (a never-resolving dangling request); an `applyGroups` case for the cwd-fallback
  bug; a new `sessionRisk.rawScore` field so the F-002 boundary asserts the raw `(33.5, 34)`
  window directly instead of only the rounded score; and a new **XSS escaping tripwire**
  ([tests/escaping.test.sh](tests/escaping.test.sh)) that fails if a user-text sink drops its
  `esc()` wrapper or `esc()` stops entity-encoding. Each new regression test was confirmed to
  fail against the reverted fix. Adds [context.md](context.md) (architecture/workflow
  orientation for new sessions).


## 2026-06-10 — Fleet-scale console + adversarial bug sweep

### Added
- **Tile search (🔍).** A magnifying-glass header button reveals a filter bar that
  scopes the live grid by free-text, token-AND over each session's display label, name,
  cwd, projectKey, status, and group. Empty query shows all. Pure `core.filterTiles`,
  mirrored in the panel JS so typing stays instant (the same untested-mirror idiom as
  `fmtDur`/`barLevel`).
- **Session groups.** Right-click → **Set group…** tags a session into a named cohort
  (e.g. "backend", "refactor"), keyed by the stable projectKey like relabels so it
  survives close/reopen and a new session in the same folder inherits it. Persisted to
  `~/.claude/cc-groups.json`. A filter-chip row appears only when groups exist; clicking
  a chip scopes the grid (composing with search). Pure `core.applyGroups`/`groupNames`/
  `setGroup`.
- **Bulk fleet actions.** A "Fleet" bar acts on the **visible** (post search/group) set
  at once — approve every waiting session, stop every working one (confirm), or broadcast
  a nudge (prompt). Counts shown live; buttons appear only when relevant. Targets are
  re-derived server-side from the keys the panel shows (WYSIWYG). Pure `core.selectActionable`
  driven by a single-source `core.BULK_RULES` injected into the panel so the count can't
  drift from what Lua acts on. nudge excludes `approval` (it submits — would corrupt a y/n).
- **Per-session timeline (📜).** A detail-panel button opens the audit overlay scoped to
  the selected session's chronological history (timeline view), reusing the overlay +
  `filterLedger`/`renderNarrative`. Pure `core.sessionTimeline`. Needs the ledger enabled.
- **Auto-respawn (opt-in, bounded).** When `respawn.auto.enabled` is on, a session that
  wasn't intentionally closed/drained and goes stale (crash, kill, lost terminal) is
  relaunched from its cwd once per stale edge, capped by `maxRetries` **per launch
  folder**; the budget resets when a session there runs healthy again (the ~90s stale
  latency is the backoff). Pure `core.shouldAutoRespawn` + `core.stepAutoRespawn` (the
  per-folder bookkeeping, charged only on a real relaunch). Off by default.
- **Insights sparklines.** The 📊 overlay gains a "Trends — last 24h (hourly)" section
  with four inline-SVG trend lines: time blocked on you, fleet activity (prompts +
  tool-requests), active sessions, and denial rate. Pure `core.bucketEvents` (a per-metric
  handler table); the blocked metric pairs request→decision **per session** and uses a
  maxBlock window lookback. Ledger-gated.
- **Stuck-session watchdog.** When `escalation.hung.enabled` is on, a session that stays
  `working` with no transcript growth past `minutes` is flagged (⏳ + a purple ring) and
  nags once per stall via the existing escalation sound/push prefs — complementing the
  approval-wait escalation. Pure `core.isHung`/`trackProgress`/`applyProgress`/
  `watchdogShouldReset` (re-armed on progress so it nags once **per stall**, not per
  stint); growth tracked via a cheap `FX.fileSize` seek. Off by default.

### Fixed
Most of these came from an adversarial multi-agent bug sweep (per-flow finders →
adversarial verifiers that re-ran each repro), the rest from leaderboard review of the
feature commits:
- **sessionRisk crash on string thresholds (major).** A quoted-number `risk.thresholds`
  from config hit a Lua number↔string compare and threw inside the 1s refresh loop,
  freezing the whole panel. Thresholds are now coerced via `tonumber` like the weights;
  the risk band is also derived from the **rounded** score so the number and its color
  always agree.
- **Stale `pending.ask` leak.** A new pending without an `ask` (a Write PermissionRequest
  after an AskUserQuestion) inherited the old `pending.ask` via jq's recursive merge,
  leaking dead option buttons onto an unrelated approval tile. cc-status.sh now clears the
  old pending before the merge (a replacement is authoritative).
- **`staleDuplicateKeys` cross-prune.** /clear-ghost detection grouped by the basename
  `name`, so two sessions in different folders sharing a basename cross-pruned — silently
  swallowing the dead one's auto-respawn. Now keyed by the stable projectKey (cwd fallback).
- **`mergeHooks` over-broad match.** A bare `cc-` substring made any user hook containing
  "cc-" (e.g. their own `cc-notify.sh`) suppress wiring Shepherd's hooks for that event.
  Now matches the exact `core.OUR_HOOK_SCRIPTS` basenames; `install.sh`'s jq mirrors it.
- **Watchdog re-alert lost after a resume.** "Nag once per stall" had degraded to "once
  per working stint" — `applyProgress` now clears the alert flag on progress (re-arm) and
  preserves it on a held tick.
- **Blocked sparkline session-blindness.** It tracked one pending request across the
  fleet-wide stream, so concurrent sessions mis-paired and under-reported blocked time
  (disagreeing with the per-session headline). Now keyed per session_id.

### Tests
- Suite grew from ~475 to **641 core + 103 ui + bash** checks, all green. Every new pure
  function and every bug fix landed with regression tests (including a two-session
  blocked-pairing case, an install.sh jq-mirror case, and a watchdog stall→resume→stall
  re-alert replay).

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
