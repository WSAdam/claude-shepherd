# Changelog

Notable changes to Claude Shepherd. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal tool with no
versioned releases, so entries are dated. Earlier history is in `git log`.

## 2026-06-13 — Context bar (% + match-editor + ramp), Auto-Continue, Auto-Remote-Control

A single batch: make the per-tile context bar legible and accurate, auto-recover sessions
frozen on an API error, and auto-enable Claude Code's Remote Control across the fleet.

### Added — context-fullness bar
- **The numeric `% lives ON the bar`** (right-aligned, shadowed for legibility over every
  color), the bar is taller (3px → 12px) to fit it, and the fill is still `width:N%`.
- **It tracks the editor, not the raw window.** `core.contextFractionFor` now divides by
  `window * context.autoCompactFraction` (default **0.92**), modeling the output reserve Claude
  Code holds back — so the tile matches the editor's "% until auto-compact" instead of reading
  ~8% low. The auto-compact threshold is **undocumented** (confirmed against the live transcript,
  which carries no context field, and the official docs, which don't expose the formula); the
  fraction is therefore an approximation, hand-tunable, and preserved across Settings saves
  (`SETTINGS_KEEP_SUBKEYS.context`). The observed-size tier self-heal still floors the denominator.
- **7-color ramp** (`core.contextBand`, mirrored in the panel `barLevel` twin): calm `<50`, a new
  color every 10% (50/60/70/80/90), and a distinct **critical** band for the last 5% (95–100,
  gently pulsing). Replaces the old 3-level bar (the fleet-footer usage bars keep their scheme).

### Added — Auto-Continue on a frozen API error (opt-in, off by default)
- A tile in the magenta `Error` state (e.g. ECONNRESET, no Stop hook) **auto-types `continue`**
  after `autoContinue.delaySeconds` (default 60) — the SAME serialized keystroke the manual
  Continue button uses. Capped at `autoContinue.maxAttempts` (default 3) **per launch folder**,
  with fires spaced ~delaySeconds apart; the budget resets only on a clean `done`/`idle`, never on
  the `working` the continue itself produces, so a persistently dead connection can't loop. Emits
  an `auto_continue` ledger event (surfaced in the 🔔 Alerts feed). `core.shouldAutoContinue` /
  `core.stepAutoContinue` (pure, unit-tested); ⚙ Settings toggle + delay/cap.

### Added — Auto-enable Claude Code Remote Control (on by default)
- **New spawns launch with `--remote-control`** (`remoteControl.onSpawn`) — the documented,
  keystroke-free way to register RC — but only for a **LOCAL native-Anthropic** session (RC needs
  claude.ai auth and rejects gateway/ssh providers; the flag is also dropped for ssh in spawnSpec).
- **Startup sweep** (`remoteControl.sweepOnStartup`): types `/rc` into already-running idle/done
  LOCAL sessions on Shepherd boot, so a computer restart re-arms RC across sessions started outside
  Shepherd. `core.remoteControlSweepTargets` picks safe targets (never mid-turn / mid-approval);
  the keystroke rides the serialized chokepoint; `/rc` is idempotent.
- ⚙ Settings section (kept **distinct** from the existing Kitty `kitty @` remote control, which is
  Shepherd-drives-the-window, not claude.ai-drives-the-session). NOTE: the "Enable Remote Control
  for all sessions" Claude Code setting has **no documented settings.json key**, so Shepherd can't
  set it — to auto-register RC for sessions you start yourself in a terminal, run `/config` and
  toggle it once (documented in the ⚙ help, the README, and cc-config.example.json).

### Deferred
- The **4c-E routing follow-ups** (task→session tags, auto-spawn on starvation, idle/remote
  routing targets) were intentionally **not** built — each needs a UX decision first, and shipping
  speculative automation behind dead flags wasn't worth it. Documented in todos.md for a later
  green-light. A **hardware-verification runbook** ([docs/hardware-verification.md]) now captures
  the Kitty-token + SSH-bridge checks for when the real boxes are available.

### Tests
- Suite **1193 core + 178 ui + 167 bash**, all green (was 1062 + 167 + 167). New core coverage:
  `contextBand` boundaries, the effective-limit fraction + `autoCompactFraction` clamp,
  `shouldAutoContinue`/`stepAutoContinue` (grace clock, per-folder cap, loop-guard), `spawnFlags`
  rc + `spawnSpec` ssh-drop, `remoteControlSweepTargets`. New UI source-pins: the `%`/band classes,
  and the auto-continue + RC-sweep dispatches routing through the serialized chokepoint.

## 2026-06-12 (later) — Review hardening: gate lost-decision fix + coverage

Applied the leaderboard reviews against `c023468`/`d4aebc6`/`0f31c42` (every
claim verified against the code first).

### Fixed
- **Approval gate could silently destroy a held sibling decision**: when a
  waiter claimed a not-ours answer and the panel wrote a *fresh* decision
  before the hardlink restore ran, the restore failed EEXIST (correctly
  protecting the fresh write) — but the unconditional `rm` then deleted the
  held answer, and that sibling timed out to the native prompt with no trace.
  The claim is now restored on success or **parked** under a unique
  `.claim.<pid>.parked` name on collision (loud stderr note; swept by
  `cc_remove` on SessionEnd) — a claimed-but-not-ours decision is never rm'd.
  The poll-loop comment is condensed to the four load-bearing invariants, with
  the long-form rationale moved to the top of tests/gate.test.sh next to the
  cases that pin each one.

### Added — tests & refactors
- gate.test.sh: **concurrent same-key case** documenting the known
  one-pending-block-per-session-key limitation (the panel can only answer the
  most-recent request; earlier waiters degrade to the native prompt). The
  review's "same-second bare-allow reject is unpinned" claim was outdated —
  case `ss1` already pins it.
- `core.runSequence(steps, schedule)`: the spawn keystroke ladder's scheduler
  moved to cc-core with the scheduler injected — unit-tested (cumulative
  offsets, per-beat pcall isolation, handles) — and it now **returns the timer
  handles**; spawnEditorWindow cancels a superseded ladder so rapid
  double-spawns can't interleave keystrokes into one window.
- handleAction's strict `== false` delivery contract defined once (`delivered`
  helper) and pinned by tests: paste/sendKeys returning false → nil + no
  ledger/re-base; returning nil → success (fakes stay on the success path).
  fx_recorder gained `_pasteResult`/`_sendKeysResult` knobs and a recording
  `log`.
- `core.staggerSlot` pinned (cold start, queued-behind-tail, stale-tail
  rebase, nil/garbage coercion).
- install.sh's timeout-migration jq hoisted into named defs
  (`patch_approve` / `migrate_timeout`) with the shape-preservation invariant
  documented inline, keyed to install.test.sh's "shape:" checks.
- make-icon.sh is now a pure "PNG → Resources/<CFBundleIconFile>.icns" step:
  the dead legacy-applet cleanup (Assets.car/IconName/Identifier — no-ops
  since the hand-rolled bundle) and its redundant `touch` removed;
  build-app.sh owns the closing codesign + touch.

## 2026-06-12 — Feature roadmap shipped: all 7 items + 4c-E project routing

The June 2026 scan's whole gap-analysis roadmap, in one pass. External-tool stance
throughout: detect → use → degrade gracefully (`rg`/`fd` are auto-detected accelerators;
`jq` stays the only hard dependency). Suite grew 795 → **1062 core** checks (+167 ui,
+167 bash), all green.

### Added — visibility (pure reads of data we already had)
- **Per-session gate decision log** in the detail panel: the last N gate decisions,
  grouped ("⛔ deny Bash ×4 (autoDeny: Bash(rm*)) · 2m ago") via `core.gateDecisionSummary`.
  Loads on tile selection and on the selected tile's status transitions — never on the
  1s tick. Config: `decisions.limit`/`decisions.hours`.
- **Notification history** (🔔 top-bar button + unseen badge): escalation and
  stuck-session alerts now write ledger events at fire time (`escalation`/`hung` — add
  them to `ledger.captureTypes` if you've customized it); together with `auto_respawn`
  and non-human `decision` events they feed a new **Alerts** tab in the audit overlay,
  with a "since you last looked" highlight (`hs.settings` last-seen mark). The badge
  recomputes only when the cached ledger snapshot actually changed.
- **Fleet-wide transcript/ledger search** (🔎): "which session touched auth.ts?" across
  every session's transcript JSONL (live and dead) + the ledger. ripgrep when installed,
  BSD-grep fallback — both built as `-o` context-wrapped literal matches so multi-KB
  JSONL lines never reach the panel. Async `hs.task` with terminate-on-new-query + a
  generation guard; hits select live tiles (with Jump) or open a dead session's audit
  timeline.

### Added — operator ergonomics
- **Settings UI for the dark config**: risk (enabled + thresholds; a hand-edited
  `risk.weights` now survives Settings saves via `SETTINGS_KEEP_SUBKEYS`), collision,
  drain, respawn (manual + auto incl. `staleSeconds`), and `insights.maxBlockSeconds`
  are all editable in ⚙. Pattern-syntax hints under the auto-allow/deny textareas.
- **Queue upgrades**: "Queue: N" opens an inline editor — reorder (▲▼) and remove (✕),
  every edit guarded by the clicked task text (`expect`) so the 1s autofeed race can
  never move/delete the wrong task, and every reply pushes the fresh list. Multi-line
  paste into Queue auto-splits into one task per line (`core.queueSplitLines`: CRLF,
  bullets, blanks — confirm first). Saved task templates ("Tpl ▾", `cc-templates.json`)
  insert into the input, never auto-send.
- **Spawn presets + fuzzy folder search** in the New Session modal: ▶ preset chips
  (one-click spawn of folder+editor+mode+provider, `cc-presets.json`), "Save as preset",
  per-project last-used recall, and type-ahead folder suggestions — the project roots
  (`spawn.searchRoots`, default ~/Programming) are scanned once per modal open (fd when
  installed: gitignore-aware; else find) and ranked by pure `core.fuzzyFilter`.

### Added — orchestration
- **4c-E project routing** (the orchestrator doc's last deferred piece): arm a project
  (detail-panel "route" toggle writes `routing:true` into its queue file) AND enable
  `queue.routing.enabled`, and queued tasks feed **whichever session of that project is
  free** — done-only in v1 (an idle session may be one you're typing into). Level-
  triggered single dispatcher (one feed per project per tick), `routePending` in-flight
  guard with timeout, delivery-gated pops, `by:"router"` ledger events, dry-run honored,
  optional starvation flag (`queue.routing.starveMinutes` → ⌛ + one ledger event).
  Every queue rebuild now carries the arm flag (`qkeep`) — a routed feed popping the
  queue can't disarm its own project.
- **SSH status bridge** (Phase 2): with `bridge.enabled` and an ssh provider, a per-host
  timer rsync-pulls the remote `~/.claude/cc-status/` into `~/.claude/cc-status-mirror/
  <host>/` and merges those sessions as **⇄ remote tiles** with `host:`-namespaced keys
  (projectKey namespaced too, so a same-path clone can't share queues/labels/budgets).
  Remote tiles are **headless-only**: Approve/Deny route back over ssh as nonce-bound,
  injection-guarded decision files (`core.decisionSshArgv`); keystroke actions are
  disabled (loud refusal, reduced right-click menu), and autofeed/watchdog/auto-respawn/
  collision all skip remote tiles while stale-approval escalation stays on. Staleness is
  widened by `bridge.staleSlackSeconds`; a stalled sync shows "bridge offline" distinctly.
  End-to-end verification needs a real remote box — checklist in todos.md.

### Changed
- `riskLedgerEvents()` generalized to `ledgerSnapshot()` (returns `events, changed`) and
  shared by risk scoring, the decision log, and the 🔔 badge — still one cached parse.
- `core.selectActionable` now takes remote tiles into account: bulk Approve reaches a
  waiting remote gate; bulk Stop/Nudge never target remote tiles. `core.actionIsHeadless`
  returns true for remote tiles (they never focus a local window).
- `core.sshDest` extracted as the single user@host formatter (sshWrap/spawnSpec/bridge).

## 2026-06-11 — Three-round full-project scan: 46 verified bugs fixed

Three rounds of flow-by-flow multi-agent auditing (8 finders per round, every finding
adversarially verified against the code before being fixed, a regression test per fix,
`make test` gating each round). Majors went 13 → 3 → 1 → 0. Commit `d46c215` has the
full per-bug detail; highlights:

### Fixed — approval gate & decision IPC
- **Decisions are now request-bound.** The gate publishes a per-request `pending.nonce`;
  the panel echoes it in the decision file (written atomically, tmp+rename); the gate
  consumes only a matching nonce via an atomic PID-owned claim and restores non-matching
  answers (no-clobber hardlink). Closes a concurrent-request decision steal AND a
  same-second leftover that could silently allow the wrong tool call.
- **The gate actually gets its 2 minutes.** Claude Code's 60s default hook timeout was
  killing `cc-approve.sh` mid-poll; the shipped registration now carries `timeout: 130`
  and `install.sh` migrates existing installs (idempotently, shape-preserving jq).
- NotebookEdit-style tools (no command/file_path) got digest signatures — one
  approveRepeats approval no longer blanket-approves the whole tool. SessionEnd now also
  cleans approveRepeats memos, autopilot expiries, and stray claim files.

### Fixed — autonomy loops
- **Auto-respawn can no longer duplicate live sessions.** It fires only on a `working`
  status file frozen past `respawn.auto.staleSeconds` (default 600s — above the longest
  tool call; display staleness is 90s and was the old, wrong trigger), never on pending
  approvals (escalation owns those), and its per-folder budget resets only after
  sustained health. Ghost-prune now needs positive terminal-identity evidence.
- **Queue feeds are delivery-safe.** No feed on the first refresh after a reload (nil
  prev is not a transition), never to a stale tile, the pop persists only when the paste
  actually delivered (`task_feed_skipped` otherwise), and queues are keyed by projectKey
  so respawn//clear can't strand them.

### Fixed — keystroke delivery
- **No more typing into the wrong window.** Window targeting threads cwd+editor through
  every injection path; an unmatched window means skip+log, not fire-at-frontmost.
  Cursor no longer falls through to VS Code; Terminal.app sessions are targetable.
- **One dispatch chokepoint.** All window-keystroke sends serialize through
  `dispatchSerialized` (shared stagger tail): bulk actions, drain-close, auto-feed,
  hotkeys, Stream Deck — chains can't interleave. Kitty answer/mode keys go in a single
  ordered `kitty @ send-key`. Callers gate their side effects (mode patch, ledger,
  alerts) on the delivery status.

### Fixed — ledger, spawn & settings
- Audit purge honors the exact confirmed filter (was deleting a superset); redact
  refuses the hot day-file; size-cap GC spares today; export bypasses the 2000-event
  cap; risk scoring caches ledger reads. Settings Save merges provider cards (was
  regenerating ids and stripping `ssh`/`contextLimit`); kind-switch clears gateway
  fields; explicit "(none — bare claude)" is honored. Kitty spawns use `zsh -lic` so
  `~/.zshrc`-exported gateway secrets resolve. Heartbeat writes no longer self-trigger
  the pathwatcher refresh loop; malformed `cc-config.json` warns loudly instead of
  silently disabling features.

### Tests
- **795 core + 167 ui + 167 bash = 1,129 checks** (from ~895), all green. Every fix
  carries a regression test; gate tests now exercise the nonce protocol end-to-end.

## 2026-06-11 — Frozen-on-API-error state + Continue button

### Added
- **"Error" session state.** When a turn aborts on an API error (e.g. `Unable to connect to
  API (ECONNRESET)`) WITHOUT firing a Stop hook, the session sits frozen in "working" — the
  dashboard now detects this (the latest transcript line is a `system`/`api_error` entry with
  no recovery after it) and shows a distinct **magenta "Error"** tile: pulsing, sorted up near
  approvals, with the error message in the meta. The detail **Approve button becomes Continue**
  — one click types `continue` + Enter to resume the aborted turn. Pure `core.transcriptError`
  + a `continue` action (`handleAction`); auto-respawn is suppressed for errored tiles so you
  resume the SAME session rather than relaunching it. Detection is client-side, no Claude Code
  or hook changes: the error IS recorded in the local transcript, so the tail read each refresh
  already does is enough.

### Fixed
- **`make deploy` reloads cleanly.** `hs -c "hs.reload()"` tore down the IPC message port
  mid-command, so the CLI exited non-zero and deploy printed a false "'hs' CLI not available"
  even though the reload worked. The reload is now scheduled 0.4s out (`hs.timer.doAfter`) so
  the command disconnects first — deploys auto-reload and report success accurately.
- **Approval hooks run the status update FIRST.** A session sitting at a live permission prompt
  could show "Working" instead of "Needs you" when `cc-status.sh` (the status write) ran *after*
  a slower popup / desktop-notification / network-push command in the PermissionRequest /
  Notification hooks. The shipped template already orders `cc-status.sh` first; added install
  assertions that lock it in so the order can't regress.

### Tests
- **659 core + 104 ui + 132 bash**, all green. `transcriptError` coverage (stuck vs recovered
  vs clean vs garbled, plus a check against a real ECONNRESET line), the `continue` action, and
  error sort priority. Round-4 leaderboard review of the prior commit folded in: a **positive
  control** in escaping.test.sh (plants a known raw `'+it.group+'` sink and asserts the grep
  FIRES, so the absence-assertion can't silently rot into a no-op), a `\bg\b` anchor fix, a
  `TODO(headless-js)`, and a `pts`-provenance note in make-icon.sh. The review's "derive the
  field list" idea was deliberately NOT applied -- it false-positives on numeric fields like
  `it.queue` that are concatenated raw-but-safe into the meta string.


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
