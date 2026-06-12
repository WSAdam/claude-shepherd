# Claude Shepherd — TODO (what's left)

The cross-machine / controls roadmap (Parts A/C/E) is **done**. This tracks the small
remaining items. Full per-round detail is in CHANGELOG.md and git history.

## Shipped ✅
- **Per-session editor detection** + **AskUserQuestion surfacing** + **effort dropdown** +
  **click-to-answer** + nudge focus-race fix.
- **Persistent relabels** (keyed by **stable project identity** from `transcript_path` —
  survives `cwd` drift — `cc-labels.json`), **caffeinate toggle** (top-bar `pmset disablesleep`),
  **in-panel New-session modal** (folder browser + recent dirs + new-project), **editor-aware
  spawn** (Terminal/Kitty/VS Code/Cursor), **Shepherd.app Dock launcher**.
- **Improve button** (review-first): claims this repo's leaderboard improvement cards and injects
  a *suggest, don't apply* prompt; "No improvements found" when none. **Jump** added to the tile
  right-click menu. **Keystroke-injection reliability fix**: `after()` retains pending timers so
  nested `doAfter` chains (nudge/clear/compact/…) can't be GC'd mid-sequence.
- **Headless approvals** — one-click Settings toggle (arm gate + all policies off); editable
  `gate.tools`; per-control explanations. **Editor-window pop split** (`popOnComplete` /
  `popOnApproval`) with an editor-aware `cc-popup.sh`.
- **Part A — Kitty effect routing**: `core.kittyCmd`/`kittyKeyToken`; per-session effects run
  headlessly via `kitty @` (focus/approve/deny/nudge/close/answer/mode); spawned Kitty +
  global `kitty.conf` get remote control auto-enabled.
- **Part C — Permission-mode dropdown**: `core.modeCycleSteps` (Shift+Tab); detail-panel Mode
  select + New-session permission-mode picker.
- **Part E — Installer**: `make setup` / `install.sh` (idempotent: copy, jq-merge hooks with
  backup, ensure init.lua dofile, build Shepherd.app); `core.mergeHooks`; `tests/install.test.sh`.
- **Providers / multi-model**: Settings Providers tab + New-session picker + default
  (`spawn.provider`); `core.providerById`/`providerEnv`/`envPrefix` inject `ANTHROPIC_MODEL`/
  `ANTHROPIC_BASE_URL` (no keys stored — `$VAR` resolved by the spawned shell); live `/model`
  switch; `cc-status.sh` captures the live model/base_url. **SSH spawn** (`core.sshWrap`).
- **Token usage** (local, zero model tokens): per-tile **context-fullness bar** (model-aware
  window + tier self-heal), **fleet footer** (excl. cache reads) + per-model detail, 60s
  incremental recompute + Update now. **Official plan window** via `/api/oauth/usage`
  (5h/weekly/Sonnet %, ≤180s poll, token never logged, local-approx fallback).
- **Right-click Clear / Compact** on each tile (native confirm-submenu).
- **Audit / event ledger** (opt-in, off by default): append-only JSONL at
  `cc-ledger/`, the 📜 Audit overlay (Rows/Timeline, filter, redact/export/purge), and a
  read-only **Review activity** prompt. Pure `parseLedger`/`filterLedger`/`renderNarrative`.
- **Fleet insights** (📊 overlay): `core.fleetStats`/`blockedSeconds`/`fmtDuration` —
  turns, approval/denial rates, provenance, most-active, time blocked on you. Read-only.
- **Same-directory collision warning** (`core.collisions`, cached `FX.gitRoot`): amber
  tiles when 2+ active sessions share a dir/repo. Off by default.
- **Per-session tool gating** (`core.resolveGateTools`, `cc-gate-tools/<key>`): detail-panel
  Gate dropdown (Default/All/None/Custom) overrides the fleet `gate.tools` per session.
- **Per-session risk score** (`core.sessionRisk`): med/high tile badge from ledger history.
  Indicator only — no quarantine. Off by default.
- **Graceful drain + respawn** (`core.shouldDrainClose`/`respawnSpec`/`providerByModel`):
  right-click "finish turn then close" and "relaunch a dead session from cwd". Off by default.
- **Launch on startup** (`hs.autoLaunch`, on by default first run) + **`make dock`**
  (`app/add-to-dock.sh`) to pin Shepherd.app to the Dock.
- **Fleet-scale console**: **tile search** (🔍, `core.filterTiles`), **session groups**
  (`core.applyGroups`/`groupNames`/`setGroup`, `cc-groups.json`), **bulk actions**
  (approve-all/stop-all/nudge-all over the visible set; `core.selectActionable` +
  single-source `core.BULK_RULES`), **per-session timeline** (`core.sessionTimeline`,
  reuses the audit overlay), **auto-respawn** (`core.shouldAutoRespawn`/`stepAutoRespawn`,
  per-folder budget; `respawn.auto.enabled`), **insights sparklines** (`core.bucketEvents`,
  4 metrics), **stuck-session watchdog** (`core.isHung`/`trackProgress`/`applyProgress`;
  `escalation.hung`). All off-by-default where they automate.
- **API-error "Error" state + Continue recovery**: a session frozen on an API error (e.g.
  ECONNRESET, no Stop hook) shows a distinct **magenta "Error"** tile and the Approve button
  becomes **Continue** (types `continue` + Enter to resume). Pure `core.transcriptError` from
  the transcript tail; auto-respawn suppressed for errored tiles. Also fixed: the approval
  status hook now runs FIRST so a live permission prompt flips to "Needs you" promptly (was
  occasionally stuck showing "Working" behind a slower notification command).
- **Adversarial bug sweep** (multi-agent: per-flow finders → verifiers that re-ran each
  repro): fixed a sessionRisk string-threshold crash (froze refresh), a `pending.ask`
  merge leak, a `staleDuplicateKeys` cross-project prune, a `mergeHooks` over-broad
  `cc-` match, a watchdog re-alert miss, and a session-blind blocked sparkline.
- **Three-round full-project scan (June 2026, commit `d46c215`)**: 46 verified bugs fixed
  (majors 13 → 3 → 1 → 0 across rounds). Gate decisions now **nonce-bound** (atomic
  claim/restore, 130s hook timeout + installer migration); auto-respawn fires only on a
  ≥600s **frozen** `working` file (never approvals, sustained-health budget reset); queue
  feeds are delivery-gated and projectKey-keyed; every window keystroke goes through the
  `dispatchSerialized` chokepoint and **skips when no window matches**; ledger purge/export
  honor exact filters; provider cards survive Settings Save; kitty spawns resolve
  `~/.zshrc` secrets (`zsh -lic`). Suite **795 core + 167 ui + 167 bash**, all green.

## TODO
- **Verify on a real Kitty box** (the one thing that needs the hardware): the `core.KITTY_KEY`
  send-key tokens (`enter`/`esc`/`down`/`tab` — `kitty @ send-key` fails *silently*) and the
  AskUserQuestion picker nav (`answerKeys` = arrow-down×N + Enter). Retune `KITTY_KEY` /
  `answerKeys` if a token's off.
- **Providers — SSH status bridge** (Phase 2, needs a real remote box to build + verify).
  The SSH *spawn* ships: a provider with `ssh:{host,user}` launches `ssh -t <dest> '<inner>'`
  in a local Kitty/Terminal (`core.sshWrap`, tested), so keystroke effects still target the
  local window. **Missing:** remote sessions write status JSON in the *remote* `~/.claude/
  cc-status/`, so they don't show as tiles yet. Build the **controller-side pull**: an
  `hs.timer` that `rsync -az <dest>:~/.claude/cc-status/ <mirror>/<host>/` (~2s, via `hs.task`)
  for each ssh host, and have `refreshList` read those mirror dirs too, namespacing keys by
  host so they don't collide. Then route headless Approve/Deny back via `ssh <dest> 'cat >
  …/<sid>.decision'` (keystroke nudge/stop already reach the local TTY → remote). Keep the
  pure bits (rsync argv, key-namespacing/merge) in `cc-core` + unit-tested; the rsync/ssh are
  `fx` effects. Off unless a provider declares `ssh`.
- **4c-E — project routing / orchestrator** (deferred): per-project task routing + richer
  autopilot. Design notes in [docs/orchestrator-next.md](docs/orchestrator-next.md).

## Feature roadmap (from the June 2026 full scan)

Prioritized by value-for-effort. Items 1–7 came out of the scan's gap analysis; the two
tool-backed items fold in `rg`/`fd`. **Principle for any external tool: detect → use →
degrade gracefully** — a missing binary means slower, never broken (the install story
stays "clone, `make install`, done"; `jq` remains the only hard dependency).

1. **Settings UI for the dark config.** `risk.*`, `collision.*`, `drain.enabled`,
   `respawn.*` (incl. the new `auto.staleSeconds`), `insights.maxBlockSeconds`, and
   `ledger.captureTypes` all work today but require hand-editing `cc-config.json`. The
   ⚙ form pattern already exists — cheapest win on the list. Add inline syntax examples
   next to the `patterns.autoAllow`/`autoDeny` textareas while in there.
2. **Per-session gate decision log in the detail panel.** Decisions land in the ledger
   with full provenance but aren't visible where you act on the session — surface the
   last N (e.g. "policy denied Bash ×4", with the matching pattern). Pure read of
   existing ledger data.
3. **Fleet-wide transcript/ledger search** *(ripgrep-backed)*. A search box answering
   "which session touched `auth.ts`?" / "who ran that migration?" across every session's
   transcript JSONL + the ledger. `rg` (detected at runtime) makes it instant across
   hundreds of MB; fall back to `grep -r` when absent. Same theme as #2: data we already
   have, invisible today.
4. **Spawn presets + fuzzy folder search** *(fd-backed)*. "Save this setup" (folder +
   editor + mode + provider) as one-click presets, per-project last-used recall, and
   type-ahead fuzzy folder matching over the project roots in the New Session modal —
   `fd` is fast and respects `.gitignore`/skips `node_modules`; fall back to
   `find -maxdepth`. Builds on the existing recent-dirs plumbing.
5. **Queue upgrades.** Reorder/priority in the detail panel, bulk-paste a multi-line
   list auto-split into tasks, saved task templates. The queue rework from the scan
   (projectKey keying, delivery-gated pops) is the clean base for this.
6. **Notification history.** Escalation/watchdog alerts fire once; a "what fired while
   you were away" view (read from the ledger's escalation events) closes the
   missed-alert hole.
7. **SSH status bridge** (Phase 2 above — promoted from "needs hardware" to roadmap
   item): rsync-pull remote `cc-status/` with host-namespaced keys so remote sessions
   become real tiles. Biggest unlock of the deferred items; then 4c-E project routing
   extends the queue model across them.

Evaluated and **declined** from the same tool review: `gron`/`yq`/`htmlq`/`hexyl` (no
YAML/HTML/binary surfaces; `jq` already covers the JSON), `jc` (a parser framework for
~5 lines of working `pmset` shell is altitude inversion), `eza`/`bat`/`tv` (terminal-human
niceties; the panel's webview wants embedded JS, not shelled-out TUIs).

## Known platform limits (not bugs)
- **VS Code extension** UI widgets (AskUserQuestion picker, permission-mode switcher) are
  **mouse-only** — no keyboard path. So click-to-answer, live mode-switch, and non-gate approve
  are **best-effort/jump-only** in the extension and **reliable only on Kitty** (`kitty @`) or via
  the **headless gate** (decision file). VS Code spawn ("run claude in a new terminal") is likewise
  best-effort keystrokes; Kitty/Terminal spawn reliably.
- A pop on *completion* with both `popOn*` flags off is the **VS Code extension** raising its own
  window, not Shepherd (arming the gate stops the *approval* pop).

## Testing discipline (keep it)
Pure decisions → `cc-core.lua` + unit tests; effects → `fx` recorder; shell hooks → bash suites
with temp dirs. No live `kitty @` / keystrokes / network in tests (provider env-injection, usage
parse/sum/window, and ssh-wrap are all asserted as pure strings — no real keys, no real spawns).
`make test` green before every `make deploy`. 795 core + 167 ui + 167 bash side-effect-free checks.
