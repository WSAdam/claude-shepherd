# Context — Claude Shepherd

Orientation for working in this repo: architecture, invariants, and workflow. Other docs:
user-facing [README.md](README.md), dated history [CHANGELOG.md](CHANGELOG.md), what's left
[todos.md](todos.md), design rationale [docs/orchestrator-next.md](docs/orchestrator-next.md).

## What it is

A local, single-user macOS control panel for a fleet of Claude Code sessions (renamed from
"babysitter"). A Hammerspoon webview dashboard surfaces every session's live status, lets you
approve / stop / nudge them, and automates routine babysitting: task auto-feed, graceful
drain, stale-approval escalation, opt-in auto-respawn, and a stuck-session watchdog. No
network, no multi-user, no secrets — it reads session status off the local filesystem.

## Architecture — the load-bearing split

- **[cc-core.lua](cc-core.lua) — pure logic, zero `hs.*`.** Every decision (status
  parse/sort/staleness, action selection, spawn specs, ledger parse/cache/assembly +
  fleet-insights aggregation, per-session risk, grouping/filtering, sparkline bucketing,
  installed-MCP/skills/CLI-tools inventory, worklist CRUD) is a pure, deterministic
  function unit-tested directly in plain `lua`. **New logic goes here.**
- **[claude-dashboard.lua](claude-dashboard.lua) — Hammerspoon glue (~5,900 lines).** The
  webview, the ~1s refresh loop, module-level state, and all side effects. Effects funnel
  through one `fx` table (focus / keys / paste / file writes / spawn) so tests pass a
  **recorder double** instead of acting. This file is NOT unit-tested directly — put logic in
  cc-core, or smoke-test after `make install`.
- **Panel JS** (embedded in claude-dashboard.lua as an HTML string) renders the grid
  client-side. A few pure cc-core helpers are **hand-mirrored** in this JS for instant
  interactivity (`filterTiles`, `applyGroups`, `fmtDuration`, and `contextBand` → the JS
  `barLevel`); these twins must stay in sync — comments mark them. `BULK_RULES` is single-sourced (injected as
  `__BULK_RULES__`) so the bulk-bar count can't drift from what Lua acts on; likewise the ⌨ hotkey
  legend is injected as `__HOTKEY_LEGEND__`, built from the real `HOTKEY_*` bindings so the displayed
  combos can't drift from what's bound — and those `HOTKEY_*` are themselves resolved from
  `cc-config.json`'s `hotkeys` block via pure `core.resolveHotkeys` (read early via `readConfigEarly`,
  before `loadConfig`/FX exist), so config → binds → legend are one source.
- **Shell hooks** — [cc-status.sh](cc-status.sh) / [cc-approve.sh](cc-approve.sh) /
  [cc-popup.sh](cc-popup.sh) + [cc-lib.sh](cc-lib.sh). Claude Code hooks write session status
  JSON into `~/.claude/cc-status/`; the dashboard reads it.

## Invariants worth knowing

- **projectKey is the stable identity** — the encoded launch folder from `transcript_path`
  (cwd fallback when there's no transcript). Labels, groups, and respawn budgets key by it so
  they survive cd-drift and close/reopen. A live `cwd` can drift, so **never resolve
  persistent per-project state by cwd when a projectKey exists** (the cwd-keyed fallback fires
  only for genuinely keyless sessions — see `applyGroups` / `applyLabelsByCwd`).
- **cc-core stays pure + deterministic** — no `hs.*`, no wall-clock except via an injected
  `now`. Need a side effect? Route it through `fx`.
- **Webview XSS defense is render-time `esc()`**, not input sanitization — every
  user-controlled string (label / relabel / group) passes through `esc()` at the sink.
  [tests/escaping.test.sh](tests/escaping.test.sh) is a source-level tripwire for it.
- **Per-tile refresh state is one row**: `prev[key] = { status, stale, escalated }`, rebuilt
  and swapped each refresh so a vanished tile drops out. `respawnAttempts` is separate
  (keyed by projectKey — a per-folder budget, different lifecycle). **Autonomous actions
  (feed / prune / respawn) never fire from a missing prev** — the first refresh after a
  reload is an observation, not a transition edge — and never target a stale tile.
- **A large `hs.task` capture deadlocks — redirect to a file.** `hs.task` direct-exec waits for
  the child to exit while reading its stdout pipe; once the child's output exceeds the OS pipe
  buffer (~64KB) it blocks on write and neither side advances (this silently wedged the
  folder-scan index over `~/Programming`). For any scan that can emit a lot, run it via
  `/bin/sh -c "<cmd> > <tmpfile>"` (keeps the task's own pipe empty) and read the file on exit,
  with a retained-timer timeout backstop. `core.folderScanShellCommand` builds the quoted command.
  The accelerators it runs (`rg`/`fd`) are resolved by `resolveBin` (PATH + `/opt/homebrew/bin`
  + `/usr/local/bin`) and **degrade gracefully** to grep/find; `make doctor` reports what's live.
- **Keystroke delivery is a contract.** `FX.pasteIntoWindow` / `FX.sendKeys` / `feedTask`
  return delivery status; when no window positively matches, they **skip** (never type into
  whatever is frontmost) and the caller must gate its side effects (queue pop, mode patch,
  ledger event, success alert) on that return. Every window-keystroke dispatch goes through
  the single `dispatchSerialized` chokepoint (shared `core.staggerSlot` tail) so chains
  can't interleave; headless paths (kitty `@`, armed-gate decision files) stay immediate.
- **Gate decisions are nonce-bound.** `cc-approve.sh` publishes `pending.nonce` per request;
  `FX.writeDecision` echoes it (`allow <nonce>`, written tmp+rename); the gate consumes only
  a matching nonce (legacy bare verbs need a strictly-newer mtime) via an atomic PID-owned
  claim, restoring non-matching answers for their owner.
- **The context bar tracks the editor, not the raw window.** `core.contextFractionFor` divides
  context tokens by `window * context.autoCompactFraction` (default 0.92) so the per-tile bar
  matches Claude Code's "% until auto-compact" (the editor measures against the window minus an
  output reserve). The threshold is **undocumented** — the fraction is an approximation, hand-
  tunable, and preserved across Settings saves (`SETTINGS_KEEP_SUBKEYS.context`). Color comes
  from `core.contextBand` (7 bands, mirrored in the panel `barLevel` twin — keep them in sync).
- **Two different "remote controls" — don't conflate them.** `spawn.kittyRemote` /
  `kittyAutoRemote` is **Kitty's** `kitty @` control (so *Shepherd* can drive the window
  headlessly). `remoteControl.*` is **Claude Code's own** Remote Control (so *you* drive a local
  session from claude.ai / mobile): `onSpawn` adds the `--remote-control` launch flag (LOCAL
  native-Anthropic only — it rejects gateway/ssh and needs claude.ai auth), `sweepOnStartup`
  types `/rc` into already-running idle/done local sessions. The "enable for all sessions"
  Claude Code setting has **no documented settings.json key**, so Shepherd can't set it — it's a
  manual `/config` toggle (noted in the ⚙ help + README).
- **Auto-Continue is a bounded loop-guard.** `core.stepAutoContinue` resumes an `error` tile by
  typing `continue` after a grace delay, but charges a **per-folder** budget that resets ONLY on
  a clean `done`/`idle` — never on the `working` the continue itself produces — so a persistently
  dead connection can't loop. Same edge discipline as auto-respawn (off by default, ledgered).
- **L1 Agent Profiles + L2 policy bundles (shipped 2026-06-14) — the operator-data files + sync
  contracts a refactor must not break:**
  - **Operator-data registries** (same posture as `cc-presets.json`, never store secrets — env-var
    NAMES only): `cc-agents.json` (saved agent profiles; `core.agentList/agentPush/.../agentFork`),
    `cc-mcp.json` (MCP servers; `core.mcpList/.../mcpConfig`). Skills are read-only from
    `~/.claude/skills/*/SKILL.md` (`core.parseSkillFrontmatter`, `FX.listSkills`).
  - **"Spawn from a saved agent"** = `core.resolveAgent` → `core.spawnExtraFlags` appends
    `--mcp-config`/`--append-system-prompt`/`--agent`/`--add-dir`/`--plugin-dir` inside `spawnSpec`.
    New `shArg` quotes value-bearing flags in the shell sinks only (kitty argv stays raw; existing
    no-space flags byte-identical — don't regress that).
  - **L2 gate KEEP-IN-SYNC (load-bearing):** the panel resolves each session's policy with
    `core.resolvePolicy` (precedence per-session override > attachment > fleet) and writes
    `~/.claude/cc-policy/<key>` = `{autoAllow, autoDeny, bundle}`; `cc-approve.sh` `match_patterns`
    reads that file as **authoritative + opt-in** (applies regardless of `policies.patterns.enabled`),
    falling back to the flat fleet `policies.patterns.*` only when the file is absent. Three rules a
    change must preserve: (1) the per-session **orphan sweep** in `refresh()` (readDir `POLICY_DIR`,
    clear any key not re-written this tick) is **decoupled** from the `hasAtt/hasOvr` fast-path — a
    removed attachment must never leave an enforcing orphan; (2) `FX.writeResolvedPolicy` is **atomic**
    (temp+rename) — the gate reads it on the hot path; (3) `cc_remove` (SessionEnd, `cc-lib.sh`) reaps
    `cc-policy`/`cc-policy-override`. The `POLICY_DIR` default must match across `cc-lib.sh`,
    `cc-approve.sh`, and the dashboard (`~/.claude/cc-policy`).

## Workflow

- **`make test`** runs the whole suite ([tests/run.sh](tests/run.sh)): bash + standalone lua,
  all side-effect-free (temp dirs + recorder doubles, never touches real `~/.claude`). Keep it
  green before every deploy.
- **Dashboard smoke test** ([tests/smoke.test.lua](tests/smoke.test.lua), in `make test`): loads
  claude-dashboard.lua under a **stubbed `hs`** and runs the load-time `refresh()` once. This is
  the only thing that exercises the Hammerspoon glue — `luac` + the pure unit tests can't catch a
  runtime error there. It exists because a refresh-loop **`pairs(nil)`** (a reap over an
  uninitialized state table) once crashed the whole panel at load and shipped. **Invariant: every
  module-level per-key state table must be initialized `{}` up front** — the end-of-refresh reaps
  iterate them even when their feature is off. When you add an `hs.<ns>` the dashboard touches in a
  new way, the smoke may need a matching stub (numeric value-tables for anything bit-OR-ed, e.g.
  `windowMasks`/`windowLevels`).
- **`make install`** copies files into `~/.claude` + `~/.hammerspoon`; **`make deploy`** =
  test + install + reload. **Edits are not live until installed/deployed.** `make deploy`'s `hs -c`
  reload can hang — if it stalls after the copy, `make install` then reload separately with a
  timeout backstop.
- Typical change: add a pure cc-core function + its regression test → wire it into the
  dashboard → mirror in the panel JS if it affects rendering (and note the twin) → `make test`
  (smoke included) → deploy.

## State (2026-06-18) — DR7 A/B fork-to-compare (deep-research backlog COMPLETE)

DR7 shipped — **the deep-research backlog DR1–DR7 is now fully done + deployed + committed.** An
operator-invoked **⚖ A/B** panel flow (header button): run the SAME task as 2+ variants (model and/or
prompt), each isolated in its own **git worktree** (branch `ab/<cohort>/<label>`), then compare
side-by-side (DR4 scores + optional LLM-judge) and **keep the winner** (closes losers + removes their
worktrees/branches, behind a confirm).

- **Pure core:** `core.abCohortPlan` (validate + plan), `abSlug`/`abBranchName`/`abWorktreePath`
  (deterministic names; worktrees in a sibling `.cc-ab/` dir), `abCompare` (rank by DR4 run score, stable
  ties, winner), `abJudgePrompt`, and quoted `gitWorktreeAddCmd`/`gitWorktreeRemoveCmd`/`gitBranchDeleteCmd`.
- **Spawn integration:** `FX.spawnSession` gained a **`modelOverride`** (8th param) → a raw
  `ANTHROPIC_MODEL` for a native model-axis variant (no provider profile needed). A non-empty env forces
  the VS Code **terminal flavor**, so `spawnSpec`'s terminal-flavor spec now ALSO carries `coldStart` →
  `vscodeOpenArgs` adds `--disable-workspace-trust` (else a fresh worktree's trust modal blocks the launch).
  KEEP-IN-SYNC: that terminal-flavor `coldStart` line is load-bearing for A/B worktree spawns.
- **FX (all members / do-block — no main-chunk locals, the file is at the 200-cap):** `abLaunch` (worktree
  per variant, rolls back worktrees+branches on any add failure, then spawns; ms cohort id so same-second
  launches can't collide), `abData` (variants↔live tiles + DR4 scores + winner), `abKeep` (close losers +
  remove their worktrees+branches, winner stays; modal-confirm in the handler), `abJudge` (paste the rubric
  into the first live variant, serialized + delivery-gated). Registry: `cc-ab.json`.
- **Panel:** `#abmodal` (active cohorts compare/Judge/Keep over a new-run form). Cohort/label keys ride
  esc()'d `data-` attrs read back RAW via getAttribute (esc is HTML-entity, wrong for JS-string context).
- Adversarial review: worktree lifecycle / destructive-keep targeting / spawn env+trust / XSS / delivery
  gating / registry / cap — all clean (0 majors); fixed the orphaned-branch + same-second-cohort minors.
- **Known follow-ons:** a variant with BOTH provider+model uses the provider's model (documented
  precedence); model-axis variants run in the VS Code integrated terminal (CLI), prompt-only in the
  extension panel; an abandoned (never-kept) cohort's worktrees are cleaned via keep or `git worktree prune`.

## State (2026-06-18) — DR6 per-session model auto-routing (opt-in, off by default)

DR6 shipped (deep-research backlog now DR1–DR6 done; only DR7 left). Per-session, opt-in, OFF by default,
NEVER fleet-wide. When a session opts in (detail-panel **Auto-model** checkbox), each queued/routed feed
picks a model by task difficulty and switches via `/model` just before the task: cheap→Haiku, standard→
Sonnet, hard→Opus.

- **Pure `core.suggestModel(task, cfg)`** — tier pick: hard keyword > cheap keyword > word-count buckets;
  maps tier→model id. Everything config-overridable (`automodel.models/.cheapMax/.hardMin/.cheapWords/
  .hardWords`) EXCEPT the enable, which is per-session only.
- **Per-session opt-in file** `cc-automodel/<key>` (presence = on), same posture as gate-tools:
  `FX.autoModelOn`/`setAutoModel`; reaped on SessionEnd (`cc_remove` in cc-lib.sh; `CC_AUTOMODEL_DIR` default
  MUST match the dashboard's). `set-automodel` + the detail checkbox both REJECT remote/gateway sessions.
- **`FX.autoModelPreface(item, task)`** is the single switch chokepoint: returns a `/model <id>` preface ONLY
  when opted-in + a **chat-input editor** (VS Code/Cursor — a terminal/kitty `/model` is an interactive
  picker, and kitty's two `@ send-text` would race) + `core.isAnthropicSession` (gateway/remote excluded) +
  a **different tier** (nil-family-safe skip). NO side effects — the 3 feed sites ledger `model_change`
  (by="auto") + re-base `item.model` ONLY inside `if commit.persist` (delivered), so a skipped paste never
  logs a phantom switch.
- **Atomic delivery:** `pasteIntoWindow` gained an optional `preface` slash command submitted first in the
  SAME focus session (one window match, one SYNCHRONOUS return), so the switch + the task land together and
  the pop/commit can't race the 1s tick. kitty preface is concatenated into ONE `send-text` (ordered). The
  no-preface path is byte-identical. `dispatchSerialized` gained an `extraStagger` arg; a preface feed
  reserves +0.8s so the longer ladder can't run past `BULK_STAGGER` and interleave with the next target.
- **Cap discipline:** both new helpers avoid main-chunk locals (AUTOMODEL_DIR lives in the FX do-block;
  `autoModelPreface` is an FX member) — the file is at Lua's 200-local ceiling (smoke enforces it).
- Adversarial review: queue-pop/ledger gating clean; fixed kitty socket-race, stagger interleave, nil-family
  false-skip. +13 core / +13 ui pins.

## State (2026-06-18) — DR3 Rewind tab (checkpoint/rewind timeline)

DR3 shipped (deep-research backlog now DR1–DR5 done; next DR6 → DR7). The detail-panel **Timeline tab was
folded into a richer "Rewind" tab** (`core.DETAIL_TABS` `timeline`→`rewind`; Decisions kept). It lists
newest-first **restore points** (prompt label · age · ±N files changed + the changed basenames) above the
folded-in activity timeline, and a **↶ Rewind…** action.

- **Data source = the transcript's `file-history-snapshot` lines** (NOT the ledger). An ESTABLISHING
  snapshot per user-prompt turn (`isSnapshotUpdate` falsy; `snapshot.messageId` == that user line's
  `uuid`, verified live) carries the CUMULATIVE `snapshot.trackedFileBackups = {<absPath>={backupFileName,
  version,backupTime}}`, plus 0+ UPDATE lines (same messageId) as files change. Pure
  `core.checkpointTimeline(snapText, opts)` → `{messageId, ts, iso, fileCount, filesChanged, changed[]}`,
  newest-first, `opts.limit`. **Per-turn "changed" = this turn's establishing baseline diffed against the
  NEXT turn's establishing baseline** (its committed end state), falling back to the turn's own last
  cumulative map for the uncommitted latest turn. `core.userPromptSnippet(line, maxLen)` labels each point.
- **Thin FX, two streaming passes, on-demand only (never the tick), local-only:** `FX.snapshotLines` pulls
  only the small snapshot lines (~hundreds of KB of a multi-MB transcript); `FX.attachCheckpointPrompts`
  decodes ONLY the few user lines whose uuid is a restore point (cheap uuid substring pre-filter), calling
  the pure snippet extractor per line — never holds the whole transcript.
- **The ↶ Rewind… action types `/rewind`** (opens Claude Code's OWN restore-point picker — there's no arg
  form, so Shepherd can't target a specific checkpoint) behind a **mandatory `hs.dialog.blockAlert`
  confirm** that surfaces the caveat (**rewind reverts Write/Edit/NotebookEdit only — bash-made changes are
  NOT undone**). Serialized + delivery-gated (a skipped send is never announced) + ledgered (`rewind_open`)
  only on a real send. Same keystroke contract as `/clear`/`/compact`/`/rc`.
- **Panel state machine:** the Rewind tab lazy-loads BOTH checkpoints (`detail-rewind`→`ccCheckpoints`) and
  the folded timeline (`detail-timeline`→`ccDetailTimeline`); `renderCheckpoints` has pending/loaded/remote/
  empty branches, stale-guarded on `selectedKey`, `esc()` at every sink. The handler ALWAYS replies a
  non-null object so the tab can't spin "Loading…" forever. Old localStorage `selectedTab:"timeline"` is
  clamped to `activity` by `normalizeTabState`. (Independent adversarial review: 0 majors.)

## State (2026-06-18) — deep-research adds (DR1/DR2/DR4/DR5) + lock + two bug fixes

A forward-looking deep-research pass (Claude Code's newest native features + AgentOps/Langfuse
patterns) produced a 7-item backlog DR1–DR7 in todos.md; this batch shipped four of them plus a
custom lock and two field bug fixes. All pure logic + tests in cc-core; all deployed + live-verified.

- **🐞 Stale-"done" self-heal** — status is hook-driven, so in Auto mode a tile could sit on "done"
  while actually working (a text-only reply fires no tool hooks; an auto-continued prompt skipped
  UserPromptSubmit — confirmed live: `since` never advanced through a whole turn). `core.transcriptResumed
  (tail, updatedEpoch, slack)` flips done→working when the NEWEST `assistant` transcript line is newer
  than `it.updated` (keyed on assistant lines so IDE file-open *user* lines + snapshots never false-trip;
  a done turn's own final line is ≤ updated since Stop fires after it). Wired in refresh BEFORE the
  working→error override (symmetric self-heal). `status.resumeSlack` (default 2s).
- **🐞 New-project spawn delivers the initial prompt** — a brand-new folder cold-starts on the Welcome
  tab behind the Workspace-Trust modal, so the old ladder typed the task into the void (no session).
  Threaded `isNew` (modal `mode=="new"` → `FX.spawnSession` → `opts.isNew` → `spec.coldStart`);
  `core.vscodeOpenArgs(spec)` adds `--disable-workspace-trust`; the extension ladder, on cold start,
  waits longer (5/1.5/2.5s), re-asserts focus + the deterministic ⌘1→⌘Esc chat dance, and **pastes** the
  task (reliable vs char-typing). Existing-folder spawns unchanged.
- **🔒 Custom in-app lock** (header 🔒, right of ☕) — full-screen `hs.canvas` overlay (all screens,
  screenSaver level) + an `hs.eventtap` that swallows ALL keyboard/mouse and captures the typed password;
  ⏎ verifies a salted SHA-256 hash in cc-lock.json (pure `core.lockSaltedInput`/`lockRecord`/`lockVerify`;
  FX uses `hs.hash.SHA256`). NOT the macOS loginwindow (that blocks Shepherd's keystroke control). Soft
  lock: `⌘⌥⌃⇧U` chord + `_G.__ccLockRelease()` (SSH) + reload all release it. **The whole lock block is
  wrapped in a `do … end`** — its locals (LOCK_FILE/lockHasher/lockState/lockRelease) would otherwise
  blow the main chunk's 200-local cap; only `FX.lockEngage` (table member) is reachable from the handler.
- **DR1 — Subagent fan-out (Agents tab)** — Adam's sessions write `…/<sessionUuid>/subagents/agent-*.jsonl`
  (first line carries `agentId`+`slug`) + `subagents/workflows/wf_*/`, NOT in-transcript `Task`/`isSidechain`
  lines (0 of those exist locally — verified). `core.subagentsDir`/`subagentTree`/`subagentMeta`/
  `subagentLabel` + `FX.subagentScan(dir, withContent)`; detail `Agents` tab (in `core.DETAIL_TABS`) lists
  agents grouped by run, click to drill (`detail-subagent` → `core.transcriptRecent`, path-validated by
  `core.subagentNameOk`).
- **DR2 — Background-work badge** — green `⚙ N` tile pill via `core.backgroundActivity` over the same
  `subagents/` mtimes (`subagents.activeWindow` default 45s); cheap mtime-only scan on the refresh tick.
- **DR4 — Run score** — detail **Score** button → `core.runScore` (100 minus error 18 / deny 6 / loop 12 /
  respawn 14; `score.weights`) + `core.scoreTrend` (regression = last `window` non-increasing AND drop ≥
  `drop`); logs a `run_score` ledger event; `#d-score` readout cleared on selection change.
- **DR5 — Dollars** — `~$X est.` in the fleet footer via `core.PRICING` + `priceFamily`/`priceFor`/
  `estimateCost` (Anthropic families only; gateway/local unpriced). `fleet.costUsd`/`costPriced` in the
  usage payload; `pricing.<family>` override.
- **Review-triage of a4bef0c** (CLI-tools inventory): extracted `core.isInstalledPath` as the single
  absolute-path install rule; `FX.cliToolStatus` calls it + keeps `hs.fs.attributes` (the existence check
  core can't do). Skipped the injectable-stat + node-headless-test asks (against the codebase's
  thin-FX/grep-pin idiom) — documented the `mkToolRow` fallback-before-required edge instead.

Invariant reaffirmed: **every new module-level group of locals in claude-dashboard.lua risks the 200-local
main-chunk cap** — wrap helper clusters in a `do … end` and expose only table members (see the lock block).

## State (2026-06-16) — Stream Deck glance: context bar + caffeine key

- **Context-fill bar** on each session key: `sdButtonImage` reads `item.context_frac` (per tick),
  else `lastUsagePayload.perSession[key].context_frac` (60s aggregate) — same precedence as the
  panel. The fill bucket (`floor(cf*40)`) is in the repaint signature so it updates without churn.
- **Caffeine key** on the bottom-right corner (`sd.count`), reserved next to the bottom-left action
  row. Toggling calls `FX.setCaffeinate` (admin-password prompt, like the panel ☕). State is cached
  in **`sd.caffeine`** (updated on the existing 10-tick pmset cadence) — the deck NEVER shells
  `pmset` per render. `sd.actionActive(name)` is the generic on/off check (voice/caffeine).
- Both `sd.actionActive` and the caffeine state live on the `sd` table, NOT as main-chunk locals —
  the file is at Lua's 200-local ceiling, so new deck state goes on `sd` (or in the handler `do`
  block) from here on.

## State (2026-06-16) — Stream Deck efficiency + safety pass

Measured Shepherd at ~250 MB / ~6% of one core (Hammerspoon 151 MB + the WebKit panel webview
~71 MB); it is NOT the cause of the user's typing lag (that's ~9.5 GB of Electron on a 16 GB Mac →
9 GB swap). Footprint wins + one bug:

- **Deck repaint is now diffed:** `sdRender` keeps `sd.sig[i]` (a content signature: status + display
  name, + `sd.blink` only for approval keys) and re-renders/USB-writes a key ONLY when its signature
  changes — was repainting all 32 keys every tick. Cache cleared on (re)connect/disconnect.
- **Panel push gated on `panelVisible`:** the per-tick `hs.json.encode(list)` + `window.ccUpdate` only
  runs when shown (NOT `panelIsOnScreen()` — that consults the window and broke the headless smoke
  path; `panelVisible` is our own reliable flag). Deck + rest of the tick still run.
- **Voice anti-runaway:** ffmpeg records with `-t voice.maxSeconds` (default 120) AND the task exit
  callback resets `sd.recording`/repaints if it exits while still "recording" (cap/mic-deny/device
  error) — fixes a 21-min orphaned recording found in the wild.
- **Forget tile:** right-click "Forget tile (no close)" = `FX.removeStatus(item.key)` only, NO
  `closeWindow` — the orphan-safe counterpart to "Close instance" (which title-matches the window and
  can close a live same-named twin).

## State (2026-06-16) — Stream Deck action row + local voice

- **Deck label fix:** keys now use `item.label or item.autoTitle or item.name` (panel parity), and
  `sdRender` moved to AFTER the per-tick label/auto-title decoration (was before → raw names).
- **Global action row** (bottom-left N keys, reserved only when `STREAMDECK_ACTIONS` and the deck is
  >= 4 cols x 2 rows): pure `core.deckActionKeys(cols, rows, n)` picks the indices (XL → 25–28),
  `core.deckLayout(count, list, reserved)` lays sessions around them. Order = `SD_ACTION_ORDER`
  (jump, approve, spawn, voice); each renders via `sdActionImage`. Handlers live in a **`do` block**
  near the `sdStart()` call (so they can reach showPanel/spawnPrompt/refreshList AND to dodge Lua's
  200-local main-chunk cap); `sdRunAction` is the forward-declared bridge from `sdOnButton`.
- **Voice = local, no cloud:** ffmpeg (avfoundation `:0`, 16k mono) records to a temp wav on the
  first tap; the second tap SIGTERMs it and `whisper-cli` transcribes on-device. Target = the session
  owning the **focused window** via pure `core.sessionForTitle` (reverse of focusProject's title
  match); auto-submit via `FX.typeIntoWindow`. Config: `voice.{model,micDevice,autoSend,whisperBin,
  ffmpegBin}`. Hammerspoon needs Microphone TCC permission; whisper non-speech `[BLANK_AUDIO]`/`(...)`
  results are filtered out.
- **Gotcha documented:** the tile "Close instance" matches the editor window by TITLE, so closing a
  stale tile whose live twin shares the name closes the REAL window — clear an orphan by deleting its
  `cc-status/<id>.json` instead (no window match). A no-window "Forget tile" action is the follow-up.

## State (2026-06-15) — QoL batch

Seven QoL items from real panel use → four code fixes (the other three — Gate/Autopilot/Policy —
work, they're just inert until the gate/ledger are armed). New invariants:

- **Panel visibility is state-robust, not flag-based.** The native yellow **minimize** parks the
  webview in the Dock WITHOUT a `windowCallback` action we can hook (`hs.webview` emits only
  closing/focusChange/frameChange), so the old `panelVisible` boolean desynced and `togglePanel`
  fired the wrong way. `panelIsOnScreen()` (visible AND not `hswindow():isMinimized()`) is the
  source of truth for `togglePanel` + the 🐑 menu-bar label; `showPanel` **un-minimizes** before
  showing. The menu-bar "Show panel" is the guaranteed restore; the Dock launcher is best-effort.
- **Dock launcher** (`app/build-app.sh`): the stub drops `exec` + uses `open -g` (clean lifecycle,
  no activation handshake), and build/pin strip the quarantine bit + `lsregister -f` (app
  translocation is the "Shepherd is not responding" trigger). Hand-rolled fake-`.app`-in-Dock is
  inherently finicky — the menu-bar + ⌘⌥B paths are the reliable ones.
- **Live model on the tile:** `FX.computeUsage` already parses each turn's `message.model` from the
  transcript tail (`st.lastModel`) for token accounting; it now syncs that onto `it.model` (only
  when non-empty) so the detail **Model** dropdown shows + follows the live model. The status-file
  `model` from `$ANTHROPIC_MODEL` is a spawn-time snapshot and goes stale after a `/model` switch.
- **Configurable hotkeys:** `core.resolveHotkeys(cfg)` (pure, tested) maps `cfg.hotkeys.*` →
  `{mods,key}` with the ⌘⌥ defaults + validation (known mods only; empty mods allowed ONLY for
  F-keys since macOS can't bind a bare key globally; any malformed entry reverts to default). The
  `hotkeys` block is **wholly form-unmanaged**, so `overlayConfig`'s pairs-merge preserves it across
  a Settings Save with **no `SETTINGS_KEEP_SUBKEYS` entry needed** (that table is only for blocks
  the form partially writes).
- **Decisions empty-state** branches on the JS `LEDGER_ON` global: ledger off → "turn on the audit
  ledger + arm the gate"; ledger on → the plain "none yet".

## State (2026-06-15)

**L5 build-ready batch — ALL 7 shipped + deployed (batch COMPLETE).** The heavier L5 detail/observability
sub-items: #1 detail-panel **tab strip**, #2 git **Changes** tab, #3 **Export** session archive, #4 post-run
**self-summary** + **onAutoApproved** banner, #5 **PR/MR status** badge, #6 **host stats + fleet idle-since**,
#7 **session-history browser + bulk history management**. Plus a **review-fix hardening** pass (Phase A) folding
in the AI-leaderboard reviews of the #4/#5 commits. New KEEP-IN-SYNC + invariants from this batch:

- **Detail tab strip:** `core.DETAIL_TABS` is the single source (injected as `__DETAIL_TABS__`). Adding a tab
  needs a manual `<div class="d-panel" data-tab="ID">` in the HTML, and for a lazy tab a `detail-ID` bridge
  action + a `maybeLoadActiveTab` case (see the checklist comment on `M.DETAIL_TABS`). `normalizeTabStateJS`
  in the panel mirrors `core.normalizeTabState` (canonical `{id:true}` unpinned map only).
- **localStorage** is used in the panel — detail **tab state** keyed by the **stable projectKey**, and #7
  **history pins** under `cc-historyPins` (a `{projectKey:true}` set). Hammerspoon's default WebKit data store
  is persistent, so both survive reloads.
- **gh / git reads** run async (`hs.task`) or capped/sync from the **repo root**; bridge-supplied diff paths are
  validated against the session's status set; url opens are `http(s)`-with-a-host only (`core.isOpenableUrl`,
  case-insensitive scheme).
- **PR-status poll is hung-task aware (review-hardened):** `core.prPollPlan(cached, inflight, now, opts)` decides
  skip/start + whether to **terminate a stale (hung) in-flight task** before re-polling — a hung `gh` whose
  callback never fires no longer latches the slot forever (the bug two reviews caught). The latch is timestamped
  `{task, ts}`; the hung deadline is **data-aware** (cold poll ~`PR_RETRY_TTL` 20s, had-data refresh `PR_HUNG_TTL`
  60s, checked BEFORE the cache-freshness skip). The task callback paints ONLY if `core.prCallbackOwns(latch, t)`
  (it still owns the slot) — a superseded/reaped task's late SIGTERM'd result is **dropped**, never clobbers fresh
  data or re-populates a reaped root (the searchGen supersede pattern). Vanished-root latches are reaped + terminated.
- **`core.reapUnbacked(cache, liveKeys)` single-sources the per-key refresh reaps** (taskStart / loopAlerted /
  autoApproveFired / summaryState.* / gitChangeFiles / prStatusByRoot). `ruleFired` stays bespoke (its `\1` key
  transform). **Every module-level per-key state table is still initialized `{}` up front** (the reaps iterate
  them even when their feature is off — the smoke-test invariant).
- **Off-by-default automations** (self-summary, onAutoApproved, PR status, host stats) follow the established edge
  rules: never fire from a missing `prev`, exclude remote/stale, delivery-gate any keystroke, clear their guard
  when toggled off. **#6 host stats** is read-only: `FX.pollHostStats(force, cfg)` self-gates on `insights.hostStats`
  + is 30s-throttled, gathers raw readings (each pcall-guarded) and derives via pure `core.hostHealth(raw, opts)`
  (CPU/mem/disk %, uptime, a `pressured` flag + reason string; hand-editable `insights.hostPressure.{cpu,mem,disk}`
  thresholds preserved across Save via `SETTINGS_KEEP_SUBKEYS.insights`). `core.fleetIdleSince(tiles, now)` is pure;
  the off-by-default OMISSION of the strip is routed through pure `core.insightsHostAttach` (returns `{}` when off)
  so it's behavior-tested, not just source-pinned. **The disk read uses `df -kP /` (POSIX one-line-per-fs)** — plain
  `df -k` wraps a long device name onto a 2nd line and the anchored parse silently returns nil (don't regress it).
- **#7 history browser is ledger-DERIVED, not a parallel store:** `core.sessionHistory(events, opts)` aggregates
  per-session records over the FULL ledger (`readLedger({limit=0})`). **Bulk delete is over-delete-safe:**
  `filterLedger` gained a `sessions` SET and `core.purgeFilterIsScoped` treats a non-empty `sessions` list as
  scoped — but an **empty list is NOT scoped**, and `history-delete` early-returns on an empty selection, so a
  no-selection bulk delete can never escalate to delete-all. It routes through the same `splitLedgerEvents` purge
  path the Purge button uses and refreshes BOTH the History view and the shared audit-rows cache. **`FX.sendHistory`
  single-sources the uncapped read + aggregate + `ccHistory` push** (so the tab and its post-delete refresh can't
  diverge on the load-bearing `limit=0`). The ⚙ storage readout's count/skip + `cc-*.json` filter are pure
  (`core.sumDirBytes` skips `.`/`..`, `core.matchStateFiles`); `FX.storageEntries` is a thin readDir+attributes
  adapter (nil-guarded) — never touches Claude Code's own transcripts.
- **Panel anti-XSS for keyed rows:** PR badge clicks (`data-key`) and #7 history rows (`data-pk`/`data-sid`) write
  the key as an **`esc()`'d data- attribute and read it back RAW via `getAttribute`** — never interpolate a
  project/session key into an inline JS handler (`esc()` is HTML-entity escaping, wrong for a JS-string context).
- **`core.officialUsageStep(prev, status, bodyOk)`** (replaced `officialLogDecision`) owns the official-usage poll's
  log-once + recovery decision; a 200 with an undecodable/empty body is a no-op so a later good 200 still logs
  "recovered". `core.localStorageReport` formats the ⚙ storage readout (ledger/queue/status/state bytes — never
  Claude Code's own transcripts).

## State (2026-06-14)

**Feature-mining → build:** 5 top AI apps (LiteLLM/crewAI/OpenHands/cline/AutoGPT) were adversarially
mined into a backlog L1–L7 (see [todos.md](todos.md); per-project reports in `docs/feature-mining/`).
**L1 — Agent Profiles ("spawn from a saved agent")** is the first shipped (see [CHANGELOG.md](CHANGELOG.md)):
a pure-`cc-core` registry layer (`cc-agents.json` + `cc-mcp.json`, validator, `resolveAgent`, `mcpConfig`,
`personaPrompt`, `spawnExtraFlags`, skills parser) plus the New-Session modal's Agents chip row, Save-as-agent,
and a read-only Skills card. The richer registry-management UI (folders/favorites/fork/sort, in-panel
skills/MCP/knowledge attach editor) is the deferred L1 follow-up.

**L2 — named policy/guardrail bundles** is shipped too: `policies.bundles` + `policies.attachments` resolved
per session (`core.resolvePolicy`, precedence override > attachment > fleet) into a `cc-policy/<key>` file the
gate (`cc-approve.sh`) reads authoritatively, with a detail-panel Policy dropdown, an orphan sweep, atomic
writes, and SessionEnd cleanup — built with an adversarial-review pass that caught + fixed an orphaned-policy
enforcement bug. Deferred: the bundle/attachment editor UI.

**L3 — parameterized + versioned prompt templates** is shipped: saved templates (`cc-templates.json`) grew from
flat `{name, text}` into structured/versioned records with `{{var}}` interpolation, all back-compat. The
load-bearing facts a refactor must keep:
- **cc-core is the authoritative renderer — no JS render twin.** `core.renderTemplate` does the substitution;
  the panel round-trips through the `template-render` handler (which composes + interpolates and echoes back via
  `ccTemplateRendered`). The only JS twin is the trivial `{{`-detection. Built-ins: `date`/`today`/`now` come
  from an **injected `os.time()`** (cc-core stays clock-pure — `opts.now`); `{{prev_output}}` = the relevant
  tile's `it.activity` (transcript snippet).
- **Two render modes.** Interactive (Tpl menu, modal picker) REFUSES on a missing required var. Autonomous feed
  (`renderFeed` at the three queue feed sites) uses `keepMissing=true`: built-ins + `{{prev_output}}` resolve,
  unfillable user vars are left VERBATIM, it never refuses, and a placeholder-free task is byte-identical — so
  existing queues are unaffected. The **raw** queued task is still what's popped/persisted/ledgered; only the
  typed text is rendered. Delivery gating (`queueFeedCommit`) is untouched.
- **Validator family mirrors L1.** `validateTemplate → templateLoad (keep-valid/drop-bad/return errors) →
  templateList`. Versioning (`templatePushVersioned`) is duplicate-on-edit; its change detector signs on the
  **composed body** (so an edit to a `composeTemplate`-shadowed field doesn't spuriously bump). Definition source:
  `parsePromptFile`/`promptImport` import `*.prompt`/`*.md` from `templates.sourceDir` (default
  `~/.claude/cc-prompts`), strictly local. Deferred: the structured-template authoring + version/revert editor UI.

**L4 — declarative routing & orchestration** is shipped (the non-UX-gated parts): conditional routing,
process modes, join barriers, per-task timing — all queue-line syntax on top of the shipped Project Routing
v1 dispatcher, stripped before the task is typed. Load-bearing facts:
- **`@role:` affinity matches a member's GROUP** (`core.memberRole` = the tile's group; `core.taskRoute` parses
  the prefix). `routePick` gained a `role` filter; `routeTask`/`queueStarved` derive the FIFO head's role. The
  member-role axis being GROUP (not agent name) is a deliberate reuse of the shipped groups feature.
- **ORDERING (review-caught):** `core.applyGroups(list, groups)` MUST run before the routing dispatcher in the
  refresh tick (it's now right after `refreshList()`), or every tile's `.group` is nil at route time and labeled
  tasks starve. A ui pin guards this. `routeGroups` holds references to the same tiles, so setting `.group`
  before the dispatcher propagates.
- **Process mode + join barrier ride the queue file** like the `routing` arm flag — `qkeep` carries `mode`
  through every rebuild; `queueSetRouted`/`queueSetMode` preserve each other; a legacy queue round-trips
  byte-identically. Sequential = `core.projectBusy` holds while a routed task is in flight. Barriers =
  `core.taskBarrier` (`@all:`/`@any:`, reserved keywords) + `core.routeBarrierMet` (all/any settled).
- **Per-task timing:** `core.stepTaskDone` (pure, injected clock) fires a `task_done` on the first done edge
  after a feed; the dashboard `taskStart` map is stamped only on a DELIVERED feed at the 3 feed sites and is
  **abandoned on stale + reaped when a key vanishes** (review-caught: it has no self-expiry otherwise). The RAW
  queued task is still what's popped/persisted; only the typed text is stripped/rendered. `fleetStandup` rolls
  `task_done` into the Shift report.
- **Deferred (UX-gated):** routing topology view, role-addressed delegation, idle-as-target, auto-spawn on
  starvation.

**L5 — richer session observability** is shipped (the high-value pure-core derivations): all read off
the transcript Shepherd already tails + local state, all off-by-default where they automate.
- **Error-reason taxonomy:** `core.classifyError` (keyword match, most-specific first) → `transcriptError`
  returns `{message, reason}`; the tile shows a cause badge + a fresh-edge `error` ledger event.
- **Plan/TODO:** `core.planFromTranscript` (latest TodoWrite/ExitPlanMode), loaded ON SELECTION via the
  `plan` bridge action (never the 1s tick — it parses the whole tail), `esc()` at the `#d-plan` sink.
- **Auto-title** (`autoTitle.enabled`, off): `core.deriveAutoTitle` from `it.last_prompt`, cached once per
  projectKey in `cc-autotitles.json`; the refresh pass runs AFTER `applyLabelsByCwd` (so it.label is known)
  and only for unlabeled tiles; panel precedence `it.label || it.autoTitle || it.name`.
- **Loop watchdog** (`escalation.loop.enabled`, off): `core.toolCallSig`/`transcriptToolSigs`/`isLooping`
  reuse the working-tile tail; ⟳ badge + one `loop` event/episode; `loopAlerted` is REAPED on vanish (same
  L4 lesson as `taskStart`).
- **OS banners** (`notifications.banner.*`, off): `core.notifyDecision` fires on a rising approval/done edge;
  `FX.notify` wraps `hs.notify` (click → `focusProject`).
- **Deferred L5 sub-items:** detail-panel tabs, export archive, host stats, PR status, post-run self-summary,
  hooks inspector, session-history browser, and a Settings UI for the auto-title/loop/banner toggles
  (config-only for now).

**L6 — event-callback rule engine** is shipped: opt-in `cc-rules.json` rules react to a session edge with a
safe effect, layered on the existing level-triggered dispatcher (NOT a new bus). Off unless `rules.enabled`.
- **Pure layer:** `validateRule`/`ruleLoad`(fail-safe)/`ruleList`; `ruleScopeMatch` (globEq on
  project/group/sessionKey/provider); `ruleFires`/`rulesForEdge`. v1 `RULE_TRIGGERS = {done, error, approval}`
  (status edges); `RULE_PROCESSORS = {log, relabel, nudge}`.
- **Engine:** `ruleSet` loaded ONCE per refresh; `runRules(ruleSet, it, edgeKind)` fires on the FRESH status
  edge (pv~=nil and it.status~=pv.status). Processors → existing SAFE effects (log→ledger by:"rule",
  relabel→setLabel, nudge→delivery-gated `handleAction`). `once` via a module `ruleFired["name\1key"]` map,
  REAPED on vanish (same L4/L5 lesson).
- **Automation result ledger:** `auto_respawn` carries `outcome="ok"`; the once-silent can't-respawn branch now
  ledgers `auto_respawn_blocked`; `auto_continue` ledgers inside the serialized closure with the delivery
  outcome. **`handleAction("continue")` is now delivery-gated** (returns nil on no-window-match) — and BOTH the
  auto and the **manual** Continue paths ledger post-dispatch gated on that (review-caught the manual eager log).
- **Deferred:** hung/loop/starved triggers, feed/continue processors, per-rule status lifecycle, a rules editor UI.

**L7 — scheduled spawns / routines** is shipped (the LAST mined-backlog phase): routines fire the NORMAL
spawn/nudge effects on a schedule (NOT a second executor). Triple opt-in: `schedules.enabled` + per-routine
`enabled` + `spawn.live` (scheduled spawns still dry-run by default).
- **Pure layer:** `cronMatches` (5-field; `*`/`N`/`A-B`/`A,B,C`/`*/S`; dom-OR-dow when both set; 0/7=Sun),
  `nextRunAt`, `dueSchedules` (once/minute via `lastFiredAt`; oneShot when `at` passes), `humanizeCron`,
  `validateSchedule`/`scheduleLoad`/`scheduleMarkFired` (stamp cron / self-delete oneShot),
  `scheduleBackpressure`. All deterministic on injected `now` (os.date is plain-lua safe).
- **Engine:** `cc-schedules.json`; a guarded refresh pass fires due routines via `FX.spawnSession` (respects
  `spawn.live`), stamps `lastFiredAt`, self-deletes one-shots, defers under `schedules.maxConcurrent`. Missed
  crons don't flood (current-minute match only); a missed oneShot fires next startup. `action: "digest"` pushes
  a `fleetStandup` report via `FX.push` (needs no folder) — the first consumer of the primitive.
- **Deferred:** the routine **board UI** (Add/run-now/pause/resume/cron-preview — hand-edited JSON today),
  import/export, overlap control, a launchd asleep-while-due backstop.

## ▶ BACKLOG COMPLETE (2026-06-14)

**All 7 mined-backlog phases (L1–L7) are shipped + committed + deployed + pushed.** Suite ~1599 core + 355 ui
+ 183 bash, green. Each phase was built via the loop: pure cc-core + unit tests → wire dashboard + ui pins →
`make test` → adversarial-review Workflow → fix → `make deploy` → commit + push. Reviews caught real bugs every
phase (L2 ×3; L3 r1 ×3 / r2 ×0; L4 the applyGroups-before-dispatcher ordering bug + the taskStart GC leak; L5 ×0;
L6 the manual-continue audit-fidelity gap; plus a leaderboard-review pass: classifyError mis-bucketing +
isLooping arg-less false-positive).

**Deferred polish queue** (all noted in todos.md; none required for backlog completion): editor UIs for
L1/L2/L3/L6/L7 (all operator-data JSON is hand-edited today); L4 UX-gated routing (topology view, delegation,
idle/auto-spawn targets); L5 heavier sub-items (detail-panel tabs, export archive, host stats, PR status, hooks
inspector, session-history browser) + Settings toggles for L5/L7 flags; L6 hung/loop/starved triggers +
feed/continue processors. Also still pending: the hardware-verification runbook (Kitty tokens + SSH bridge).

**Deploy note (learned the hard way):** `make deploy`'s `reload` step can HANG on the `hs -c` IPC. If a deploy
stalls after "copied … -> ~/.hammerspoon", run `make test && make install` (copies, no reload), then push, then
reload separately in the background: `pkill -f 'hs -c'; hs -c "hs.reload()"`. The copy = files live; the reload
just re-reads them.

## State (2026-06-13)

Cross-machine / controls roadmap done. Fleet-scale console shipped (tile search, session
groups, bulk fleet actions, per-session timeline, auto-respawn, insights sparklines,
stuck-session watchdog). A distinct **"Error" state** (magenta) flags sessions frozen on an
API error and offers a one-click **Continue** to resume them — derived client-side from the
transcript tail (`core.transcriptError`), no hooks. A **three-round multi-agent scan**
(per-flow finders → adversarial verifiers → engineer fixes, June 2026) fixed 46 verified
bugs and hardened the gate IPC (nonce-bound decisions), autonomy loops (600s frozen
threshold), and keystroke delivery (skip-on-no-match + serialized dispatch). The scan's
**feature roadmap then shipped in full** (June 12): Settings UI for the dark config,
per-session gate decision log, 🔔 notification history, queue editing/bulk-paste/templates,
spawn presets + fd fuzzy folder search, 🔎 rg-backed fleet-wide transcript/ledger search,
**4c-E project routing** (level-triggered dispatcher, double opt-in), and the **SSH status
bridge** (rsync-mirrored ⇄ remote tiles, headless approve/deny over ssh — hardware
verification checklist pending).

**June 13 batch** (this session): (1) the **context bar** now shows the `NN%` on the bar,
tracks the editor's "% until auto-compact" via `context.autoCompactFraction`, and colors in 7
bands (calm <50, every 10% to 90, critical last-5%); (2) **Auto-Continue** auto-resumes an
API-error tile after a grace delay (bounded per-folder, off by default); (3) **Auto-Remote-
Control** launches new spawns with `--remote-control` and sweeps `/rc` into running sessions on
startup. Routing follow-ups were **deliberately deferred** (UX-blocked — see todos.md). Suite:
**1260 core + 210 ui + 177 bash** checks, all green. Remaining work is in [todos.md](todos.md):
the **needs-hardware** runbook ([docs/hardware-verification.md](docs/hardware-verification.md))
for the Kitty tokens + the SSH bridge, and the deferred routing follow-ups.
