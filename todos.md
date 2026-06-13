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
- **The June 2026 feature roadmap — all 7 items + 4c-E — shipped in one pass**:
  1. **Settings UI for the dark config**: `risk.*` (thresholds; hand-edited `risk.weights`
     survives saves via `SETTINGS_KEEP_SUBKEYS`), `collision.*`, `drain.enabled`,
     `respawn.*` (incl. `auto.staleSeconds`), `insights.maxBlockSeconds` — all in ⚙;
     pattern-syntax hints under the autoAllow/autoDeny textareas.
  2. **Per-session gate decision log** (`core.gateDecisionSummary`): last-N grouped
     decisions ("⛔ deny Bash ×4 (autoDeny: Bash(rm*)) · 2m ago") in the detail panel;
     loads on selection / status change, never on the 1s tick.
  3. **Fleet-wide transcript/ledger search** (🔎, rg-backed, grep fallback):
     `searchArgv`/`parseSearchResults`/`annotateSearchHits` build `-o` context-wrapped
     matches (huge JSONL lines never reach the panel); hits map back to live tiles
     (select/Jump) or dead sessions (audit timeline).
  4. **Spawn presets + fuzzy folder search** (`cc-presets.json`, fd-backed with find
     fallback): one-click ▶ preset chips, "Save as preset", per-project last-used
     editor/mode/provider recall, type-ahead `#n-path` suggestions ranked by pure
     `core.fuzzyFilter` over a once-per-open async folder index.
  5. **Queue upgrades**: click "Queue: N" → reorder/remove rows (▲▼✕, `expect`-guarded
     against the 1s autofeed race), multi-line paste auto-splits into tasks
     (`queueSplitLines`, confirm first), saved task templates (`cc-templates.json`,
     "Tpl ▾" inserts into the input — never auto-sends).
  6. **Notification history** (🔔 + badge): escalation/hung now ledger at fire time;
     `notificationEvents`/`unseenNotificationCount` feed an Alerts tab in the audit
     overlay with a "since you last looked" highlight (`hs.settings` mark).
  7. **SSH status bridge** (pure layer + FX shipped; see hardware checklist below):
     per-host rsync mirror timers, `host:`-namespaced keys/projectKeys, headless-only
     remote tiles (⇄ badge), Approve/Deny routed back over ssh nonce-bound
     (`decisionContent`/`decisionSshArgv`, injection-guarded).
  8. **4c-E project routing**: level-triggered single dispatcher feeds an ARMED project's
     queue to whichever member is free (done-only in v1), double opt-in
     (`queue.routing.enabled` + per-queue `routing:true`), routePending in-flight guard,
     delivery-gated pops, `by:"router"` ledger events, starvation flag. Queue ops now
     carry the arm flag (`qkeep`) so a routed feed can't disarm its own project.
  Suite **1062 core + 167 ui + 167 bash**, all green.
- **Context bar + Auto-Continue + Auto-Remote-Control batch (June 2026)**:
  1. **Context bar — % on the bar + match the editor + color ramp**: the per-tile bar now
     overlays the numeric `NN%`, divides by an **effective** limit (`context.autoCompactFraction`,
     default 0.92 — the output reserve Claude Code holds back, so the bar tracks the editor's
     "% until auto-compact" instead of raw tokens/window; calibrated against a live 1M session,
     hand-tunable, preserved across Settings saves), and colors in **7 bands** — calm `<50`, a new
     color every 10% (50/60/70/80/90), and a distinct **critical** band for the last 5% (95–100,
     gently pulsing). `core.contextBand` (mirrored in the panel `barLevel`) + a taller labeled bar.
  2. **Auto-Continue on a frozen API error** (`autoContinue.{enabled=false,delaySeconds=60,
     maxAttempts=3}`): a tile in the magenta `Error` state (e.g. ECONNRESET) auto-types `continue`
     after the grace delay — the SAME serialized keystroke the manual button uses — capped **per
     folder** with fires spaced ~`delaySeconds` apart; a clean turn completion resets the budget
     (the `working` the continue produces does not), so a dead connection can't loop. Ledgers an
     `auto_continue` event (in the 🔔 Alerts feed). `core.shouldAutoContinue`/`stepAutoContinue`;
     ⚙ Settings toggle.
  3. **Auto-enable Claude Code Remote Control** (`remoteControl.{onSpawn=true,sweepOnStartup=true}`):
     new Shepherd spawns launch with the documented `--remote-control` flag (LOCAL native-Anthropic
     only — RC rejects gateway/ssh providers); on startup Shepherd types `/rc` into already-running
     idle/done LOCAL sessions so a computer restart re-arms RC across the fleet. `core.spawnFlags`
     (rc) + `core.remoteControlSweepTargets`; ⚙ Settings toggles. NOTE: to auto-register RC for
     sessions you start yourself in a terminal, run `/config` → **Enable Remote Control for all
     sessions** (no documented settings.json key exists for that toggle, so Shepherd can't set it).
  Suite **1193 core + 178 ui + 167 bash**, all green.

## TODO

### Needs hardware (runbook ready — see [docs/hardware-verification.md](docs/hardware-verification.md))
- **Verify on a real Kitty box** (the one thing that needs the hardware): the `core.KITTY_KEY`
  send-key tokens (`enter`/`esc`/`down`/`tab` — `kitty @ send-key` fails *silently*) and the
  AskUserQuestion picker nav (`answerKeys` = arrow-down×N + Enter). Retune `KITTY_KEY` /
  `answerKeys` if a token's off.
- **SSH status bridge — hardware verification checklist** (the code ships; the pure layer
  is unit-tested; these need a real remote box):
  1. Remote install: clone + `make install` on the remote; confirm remote
     `~/.claude/cc-status/*.json` appears with `editor:"kitty"` (or terminal) and **no**
     `kitty_window_id` — the assumption the whole "remote = headless-only" design rests on
     (`ssh -t` forwards TERM but not KITTY_WINDOW_ID).
  2. rsync round-trip latency + `--delete` semantics against the remote dir, **including
     openrsync** (Sequoia+ ships openrsync, not stock rsync — flag set `-az --delete
     --timeout -e` should be compatible on both; verify).
  3. Decision round-trip: panel Approve on a mirrored approval tile → remote
     `cc-approve.sh` consumes within its poll, nonce matches, native prompt never fires.
  4. SSH auth non-interactivity: `BatchMode=yes` with the key/agent setup; dead-host
     behavior (task exits nonzero, `running` clears, no timer pile-up, one log line per
     outage).
  5. Clock-skew magnitude between boxes → tune `bridge.staleSlackSeconds`.
  6. `bridge.keystrokes` experiment: does Claude Code's title escape reach the local
     kitty/Terminal window title over `ssh -t`, and does `focusProject` match it? If yes,
     nudge/stop/clear/compact can be un-greyed behind the flag.
  7. Remote SessionEnd → mirror file deleted next sync → tile disappears (no local prune).
  8. Spawn-then-appear: spawn via an ssh provider → tile shows within ~2× intervalSeconds.
### Deferred (needs a UX decision before building)
- **4c-E follow-ups** (routing v1 is done-only by design) — **intentionally not built in the
  June 2026 batch**: each needs a design call before it's worth the code, so building them
  speculatively behind dead flags was declined. Say the word to green-light any:
  - **task→session affinity/tags** — no existing tag source; needs a decision on where a task's
    tag comes from (queue-line syntax? session group? provider?).
  - **auto-spawn on starvation** — clear trigger (the `queueStarved`/`starvedSince` clock exists)
    but "spawn a new session for me" is an aggressive automation; needs a cap + UX on when/where.
  - **idle sessions as routing targets** — idle may be a session you're actively typing into.
  - **remote tiles as routing targets** — pairs with `bridge.keystrokes` (hardware-gated above).

## Tooling stance (from the June 2026 review)

**Principle for any external tool: detect → use → degrade gracefully** — a missing binary
means slower, never broken (`jq` remains the only hard dependency; `rg` and `fd` are
auto-detected accelerators for fleet search and the spawn modal's fuzzy folder search).
Evaluated and **declined**: `gron`/`yq`/`htmlq`/`hexyl` (no YAML/HTML/binary surfaces;
`jq` already covers the JSON), `jc` (a parser framework for ~5 lines of working `pmset`
shell is altitude inversion), `eza`/`bat`/`tv` (terminal-human niceties; the panel's
webview wants embedded JS, not shelled-out TUIs).

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
`make test` green before every `make deploy`. 1062 core + 167 ui + 167 bash side-effect-free checks.
