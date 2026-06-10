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
- **Adversarial bug sweep** (multi-agent: per-flow finders → verifiers that re-ran each
  repro): fixed a sessionRisk string-threshold crash (froze refresh), a `pending.ask`
  merge leak, a `staleDuplicateKeys` cross-project prune, a `mergeHooks` over-broad
  `cc-` match, a watchdog re-alert miss, and a session-blind blocked sparkline. Suite
  now **641 core + 103 ui + bash**, all green.

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
`make test` green before every `make deploy`. 641 core + 103 ui + 121 bash side-effect-free checks.
