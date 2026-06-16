# Changelog

Notable changes to Claude Shepherd. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal tool with no
versioned releases, so entries are dated. Earlier history is in `git log`.

## 2026-06-16 (deck glance) — context-fill bar on session keys + ☕ caffeine key

Two Stream Deck additions from real use:

- **Context-fill bar:** every session key now draws a thin bar along its bottom edge showing how
  full that session's context window is (green < 60% < amber < 85% < red). Sourced exactly like the
  panel — the per-tick `it.context_frac`, falling back to the 60s usage aggregate
  `lastUsagePayload.perSession[key].context_frac`. The fill bucket is folded into the key's repaint
  signature, so it updates as context grows but doesn't churn the diff.
- **☕ Caffeine key (bottom-right corner):** toggles keep-awake (same `pmset` path as the panel ☕,
  so it asks for the admin password). Reserved on `sd.count` (key 32 on the XL) alongside the
  bottom-left action row. State is cached in `sd.caffeine` (read on the existing 10-tick `pmset`
  cadence) so the key never shells out per render; the key shows amber AWAKE vs dim SLEEP OK.
- Internals: a generic `sd.actionActive(name)` drives the on/off look (Voice=recording,
  Caffeine=keep-awake); kept on the `sd` table (not main-chunk locals) to stay under Lua's 200-local
  cap. Suite **2005 core + 532 ui + 183 bash + smoke**, green.

## 2026-06-16 (efficiency + safety) — voice cap, deck repaint diff, hidden-panel skip, Forget tile

A footprint pass after measuring Shepherd at ~250 MB / ~6% of one core (vs ~9.5 GB for the user's
Electron apps — Shepherd is not the cause of their typing lag, but these are real efficiency wins),
plus the promised orphan-safe tile dismiss.

- **Voice recorder safety cap (bug):** a tested recording left `ffmpeg` running **21 minutes** into a
  34 MB wav — it records with no time limit, so a missed second-tap = infinite capture. Added a hard
  `-t voice.maxSeconds` cap (default 120s) AND a reset in the task's exit callback: if ffmpeg exits
  while `sd.recording` is still true (cap hit / mic-permission denied / device error), the REC state
  is cleared and the key repainted, so it can't get stuck or run unbounded.
- **Deck repaint diffing:** `sdRender` was repainting all 32 keys every second (canvas encode + USB
  write) regardless of change. Now it computes a cheap per-key content signature (status + display
  name, plus `sd.blink` for the pulsing approval keys) and only re-renders the keys that actually
  changed — 32 repaints/sec down to ~0 at steady state. Signature cache cleared on (re)connect.
- **Hidden-panel skip:** the per-tick full-list JSON encode + `window.ccUpdate` push now only runs
  when `panelVisible`; encoding into a hidden webview was wasted work. The deck + the rest of the tick
  still run, and re-showing repopulates within a tick.
- **Forget tile (orphan-safe dismiss):** new right-click **"Forget tile (no close)"** that just
  `removeStatus`es the tile — NO window keystroke, so (unlike "Close instance", which title-matches
  the window) it can't close a live twin that shares the name. The fix for the stale-Autobottom
  hazard documented yesterday.
- Suite **2005 core + 530 ui + 183 bash + smoke**, green.

## 2026-06-16 — Stream Deck: label fix, safe "Forget tile", + a global action row (incl. local voice)

Stream Deck work, in three parts.

- **Label fix (bug):** deck keys showed the raw folder name, ignoring relabels/auto-titles. Two
  causes: `sdButtonImage` read only `item.name` (now `item.label or item.autoTitle or item.name`,
  matching the panel tile), and `sdRender` ran in the refresh tick *before* the label/auto-title
  decoration — moved it to right after the `ccUpdate` push so the deck and panel paint the SAME
  fully-decorated list.
- **Global action row (bottom-left 4 keys, on a deck with room):** reserved via pure
  `core.deckActionKeys(cols, rows, n)` (XL 8x4 → keys 25–28); sessions fill the rest via
  `core.deckLayout(count, list, reserved)`. Each key gets a custom "cool" canvas image. Left→right:
  - **🎯 JUMP** — first tap → neediest (`nextAttention`); each further tap `cycleNext`s through all;
    idle-resets to the neediest after `SD_JUMP_RESET`s.
  - **✓ APPROVE** — front-most pending approval (the ⌥⌘A action).
  - **＋ SPAWN** — `showPanel()` + the New-session folder browser.
  - **🎙 VOICE** — local push-to-talk: tap records the mic (ffmpeg avfoundation, 16k mono), tap
    again → `whisper-cli` transcribes on-device → text is routed to the session whose window is
    focused (pure `core.sessionForTitle` reverse-match) and auto-submitted (`voice.autoSend`).
    New `voice` config block (model / micDevice / autoSend / bins). Needs whisper-cpp + ffmpeg +
    a model + Hammerspoon mic permission. (The six handlers live in a `do` block to stay under
    Lua's 200-local main-chunk limit.)
- **Safe orphan cleanup:** a stale "Autobottom" tile (a session whose SessionEnd never fired)
  surfaced that "Close instance" matches the editor window by *title*, so closing a stale tile whose
  live twin shares the name closes the REAL window. Documented; the surgical clear is removing the
  orphan `cc-status/<id>.json` (no window match). (A no-window-match "Forget tile" menu action is
  the proposed follow-up.)
- Suite **2005 core + 526 ui + 183 bash + smoke**, green.

## 2026-06-15 (QoL batch) — panel restore, live model, configurable hotkeys, decisions hint

Seven QoL items from real panel use, triaged into four code fixes + three "working as designed,
just document it" (Gate / Autopilot / Policy are inert only until the gate/ledger are armed). All
behavior-additive; no existing flow changes.

- **Panel restore is state-robust.** The native yellow **minimize** button parks the window in the
  Dock without firing a `windowCallback` we can hook, so the `panelVisible` flag desynced and the
  toggle (⌘⌥B, the 🐑 menu-bar item, the Dock launcher) acted the wrong way. `togglePanel` now
  decides on the **real** window state (`panelIsOnScreen`: visible AND not minimized) and `showPanel`
  **un-minimizes** before showing — so it restores from either hidden or Dock-minimized. The 🐑
  menu-bar "Show panel" is the guaranteed path.
- **Dock launcher hardening (best-effort).** The "Shepherd is not responding" dialog came from the
  stub `.app` (`exec open …` while pinned to the Dock). The stub now drops `exec` + uses `open -g`
  (clean process lifecycle, no activation handshake), and `make app`/`make dock` strip the quarantine
  bit + re-register with LaunchServices (app-translocation is a known "not responding" trigger).
- **Model dropdown shows the live model.** It read a spawn-time `$ANTHROPIC_MODEL` snapshot (often
  empty → `(model…)`). It now syncs the model parsed from the transcript tail (already read for token
  accounting) onto the tile each tick, so the current model shows and follows an in-session `/model`.
- **Configurable global hotkeys.** The five ⌘⌥ shortcuts are now overridable in `cc-config.json`
  under `hotkeys` (`{ "mods": [...], "key": "x" }` each) via pure `core.resolveHotkeys` — which both
  the binder and the ⌨ legend read, so the shown combos can't drift. Malformed entries fall back to
  the default; empty mods are allowed only for F-keys (macOS can't bind a bare key globally). The
  block is wholly form-unmanaged, so `overlayConfig` preserves it across a Settings Save without a
  `SETTINGS_KEEP_SUBKEYS` entry.
- **Decisions empty-state** now tells you *why* it's empty: when the ledger is off it points at
  "turn on the audit ledger (⚙ Settings) + arm the gate" instead of a bare "none yet".
- Suite **1993 core + 519 ui + 183 bash + smoke**, green.

## 2026-06-15 (review rounds) — leaderboard review fixes for #6 + #7

The AI-leaderboard reviews of the #6 (`312c588`) and #7 (`54123fe`/docs `ca66146`) commits came
back; every finding was real and folded in (none discarded). Both rounds: triage → verify against
the code → fix → `make test` → live-verify the hs-integration bits → deploy → commit.

- **#6 review (`312c588`) — one real latent bug + quality/testing:** the disk read parsed
  `df -k / | tail -1`, which silently returns nil when a long filesystem device name wraps onto a
  second physical line (the data row then has no leading filesystem token and the anchored match
  fails) → disk showed "—" and pressure detection never fired. Switched to **`df -kP /`** (POSIX
  `-P` = one physical line per fs). Plus: a `clampPct` helper single-sourcing the 0–100 round+clamp;
  pure `core.insightsHostAttach` so the off-by-default omission of the host strip is behavior-tested,
  not just source-pinned; a `fleetIdleSince` timestampless-tile test; a loosened (reword-proof)
  `hungTtl` pin; trimmed comments.
- **#7 review (`ca66146`) — dedup + pure extraction + tie-break tests:** `FX.sendHistory()`
  single-sources the uncapped read + aggregate + `ccHistory` push (was duplicated across
  open-history-view and the post-delete refresh, risking divergence on the load-bearing `limit=0`);
  pure `core.sumDirBytes` (skip `.`/`..` + sizeless) and `core.matchStateFiles` (the `cc-*.json`
  filter), leaving `FX.storageEntries` a thin nil-guarded adapter, so the count/skip decisions are
  unit-tested in core; documented the deliberate `projectKey` first-write-wins (keeps the pin key
  stable across a workspace move); a `.s-btn` class for the Measure-storage button; and
  `sessionHistory` tie-break tests (the `>=` lastType rule + the active-sort secondary `lastTs` key).
- Suite **1973 core + 512 ui + 183 bash + smoke**, green.

## 2026-06-15 — L5 build-ready batch COMPLETE (#1–#7) + review-fix hardening

The seven heavier L5 detail/observability sub-items, all shipped + deployed (read-only, or
off-by-default where they automate). Each built via the loop: pure `cc-core` + unit tests → wire the
dashboard + source pins → `make test` (incl. the load-time smoke test) → an adversarial multi-agent
review → fix confirmed findings → live-verify → deploy. The AI-leaderboard reviews of the earlier #4/#5
commits were folded in as a hardening pass.

- **#1 Detail-panel tab strip** — the flat `#detail` stack became a tab strip (Activity / Timeline /
  Decisions / Usage / Changes / Queue), pin/unpin per tab, `{selectedTab, unpinned}` persisted to
  webview `localStorage` by stable projectKey; lazy inline Timeline. `core.DETAIL_TABS` single source.
- **#2 git Changes tab** — per-session `git status -z` + per-file colorized diff from the repo root,
  rename-aware; bridge-supplied diff paths validated against the session's status set.
- **#3 Export session archive** — ⤓ button + context-menu copies the transcript + a `meta.json`
  (label / provider / model / lineage / activity, no prompt bodies) under `~/.claude/cc-exports`;
  ledgers a `session_export`.
- **#4 Post-run self-summary + onAutoApproved banner** — both opt-in: a self-review prompt typed on a
  fresh `done` edge (delivery-gated; its own done can't re-fire), and a macOS banner when the newest
  automated `allow` advances.
- **#5 PR/MR status badge** — opt-in, gh-backed, status-only: a clickable "PR #N open/merged" tile
  badge; async poll in the repo root; self-gates when `gh` is absent or there's no PR/remote.
- **#6 Host stats + fleet idle-since** (off by default, `insights.hostStats`) — a read-only strip atop
  the 📊 insights overlay (CPU / memory / disk / uptime / load) + how long the fleet has been idle;
  a starvation alert notes host pressure. Pure `core.hostHealth` / `fleetIdleSince` / `fmtBytes` /
  `fmtUptime`; `FX.pollHostStats` self-gates + is 30s-throttled (each raw read pcall-guarded, verified
  live); hand-editable `insights.hostPressure.{cpu,mem,disk}` thresholds preserved across Save.
- **#7 Session-history browser + bulk history management** — a 🗂 History tab in the 📜 audit overlay:
  `core.sessionHistory` per-session records derived over the full ledger (no parallel store), fuzzy
  query, Recent/Oldest/Most-active sort, this-workspace/pinned facets, ★-pin by projectKey
  (`localStorage`). Multi-select **Delete selected** purges those sessions' events through the existing
  confirmed, scoped purge — `filterLedger` gained a `sessions` set and `purgeFilterIsScoped` treats it
  as scoped, but an **empty selection is never scoped** so a bulk delete can't escalate to delete-all.
  A ⚙ **Measure storage** readout (`core.localStorageReport`) shows ledger/queue/status/state bytes —
  never Claude Code's own transcripts.

- **Review-fix hardening (Phase A + the leaderboard reviews of #4/#5):**
  - **Hung gh PR-status poll could never retry** (caught by two independent reviews) — the in-flight
    latch was checked after the TTL, so a hung `gh` (callback never fires) latched the slot forever and
    the short retry was dead code. Extracted pure `core.prPollPlan` (skip/start + terminate-stale-task)
    with a timestamped, **data-aware** hung deadline (cold ~20s, had-data refresh ~60s, checked before
    the cache skip). `core.prCallbackOwns` drops a superseded/reaped task's late (SIGTERM'd) result so it
    can't clobber fresh data or re-populate a reaped root (the searchGen supersede pattern).
  - `core.reapUnbacked` single-sources the per-key refresh reaps; `parsePrStatus` rejects a non-numeric
    `number`; `core.isOpenableUrl` requires an http(s) scheme (case-insensitive) **plus a host**;
    `core.officialUsageStep` (replaced `officialLogDecision`) gates recovery on a decodable body.
  - **Anti-XSS:** PR badge clicks (`data-key`) and #7 history rows (`data-pk`/`data-sid`) write the key
    as an `esc()`'d data- attribute read back raw via `getAttribute` — never interpolated into an inline
    JS handler.
  - A refresh-loop `pairs(nil)` over an uninitialized state table once crashed the whole panel at load →
    **`tests/smoke.test.lua`** now loads the dashboard under a stubbed `hs` and runs the load-time
    `refresh()` in `make test`.
- Suite **~1955 core + 513 ui + 183 bash + smoke**, green.

## 2026-06-15 (deferred polish ⑥) — L5 observability batch (Settings toggles + hooks inspector)

Sixth deferred-polish build: the L5 sub-items that were config-only get UI, and the gate's
hooks become inspectable — both landing in ⚙ Settings.

- **Observability toggles:** `autoTitle.enabled` (auto-title tiles from the first prompt),
  `escalation.loop.{enabled,repeats}` (the ⟳ loop watchdog), and `notifications.banner.
  {onApproval,onDone}` (macOS banners) are now real ⚙ checkboxes (were hand-edited config). The
  written keys were verified to match the engine's read sites exactly (a mismatch = a silent
  no-op). `onAutoApproved` was deliberately NOT exposed — `notifyDecision` doesn't consume it
  (auto-approve banners would need a gate-decision firing site), so a toggle for it would do
  nothing.
- **Hooks inspector:** a read-only ⚙ Hooks section (Inspect button) flattens
  `~/.claude/settings.json` hooks into a per-event inventory (Shepherd's own highlighted) and
  WARNS if the gate hook `cc-approve.sh` is missing its required ≥130s timeout. Pure
  `core.parseHookInventory` + `core.gateHookTimeoutOk` (+13 tests); robust to a missing/malformed
  settings.json.
- **Adversarial review** (2-lens workflow + verifiers): caught a real regression — the new
  `notifications` block made Save wholesale-replace it, silently dropping the hand-edited
  `notifications.days` (the 🔔 history lookback, no UI input). Fixed by adding `notifications`
  to `SETTINGS_KEEP_SUBKEYS` (same protection as `escalation.hung`). A self-review also dropped
  the unconsumed `onAutoApproved` toggle before the review.
- Tests: +13 cc-core (+1 keep-subkey regression test), +9 dashboard pins. Suite green
  (1707 core + 430 ui + 183 bash).
- **L5 still deferred at this point (each warrants its own build):** detail-panel tab strip, export
  session archive, host stats + fleet idle-since, PR/MR status per tile, post-run self-summary, the
  session-history browser + bulk history management, and `notifications.banner.onAutoApproved`.
  *(All of these were then built — including the `onAutoApproved` banner + its Settings toggle, once #4
  wired `core.newestAutoApprove` to consume it. See the **L5 build-ready batch COMPLETE** entry above,
  later the same day.)*

## 2026-06-14 (deferred polish ⑤) — L6 rules editor + hung/loop/starved triggers + feed/continue

Fifth deferred-polish build: an ⚙️ **Automation rules** editor (☰ drawer) for `cc-rules.json`
(was hand-edited), plus the deferred engine work — three new triggers and two new processors.

- **Rules editor:** author a rule's trigger (on edge), scope match
  (project/group/sessionKey/provider globs), processor + its text/label, and the once/enabled
  flags; enable/disable from the list (a clickable dot), edit/rename, delete. A non-armed
  warning when `rules.enabled` is off (rules still list/edit, just don't fire).
- **New triggers (now wired):** `hung` (stalled watchdog), `loop` (repeating-tool watchdog),
  and `starved` (queue has work, no free session) — each fires `runRules` at its OWN detection
  site on the RISING edge (once per episode), alongside the existing done/error/approval status
  edges. (Previously a rule targeting these failed validation since nothing fired them.)
- **New processors:** `feed` (enqueue a task onto the tile's queue — the existing auto-feed
  delivers it; no direct keystroke) and `continue` (resume an errored/stuck session by typing
  `continue`, delivery-gated, same path as the manual Continue button + Auto-Continue).
- **cc-core (pure, +18 tests):** hung/loop/starved added to `RULE_TRIGGERS`, feed/continue to
  `RULE_PROCESSORS` (feed validates needing text); rule CRUD `ruleGet`/`rulePush`/`ruleRemove`/
  `ruleSetEnabled` (mirrors the agent registry). New `FX.writeRules`.
- **Adversarial review** (3-lens workflow + verifiers): caught a real **high-severity** silent
  data-loss bug — the `feed` processor keyed the queue by the RAW `it.projectKey or it.cwd`,
  but every other queue path uses the SANITIZED key (`FX.queueKeyFor`), so a fed task landed in
  a divergent (or slash-broken, silently-dropped) file the auto-feed never read. Fixed to
  resolve the key exactly as the reader does.
- Tests: +18 cc-core, +12 dashboard pins. Suite green (1692 core + 421 ui + 183 bash).
- **Deferred (unchanged):** per-rule status lifecycle (COMPLETED/ERROR) + `retryUntil`.

## 2026-06-14 (deferred polish ④) — L2 policy bundle/attachment editor

Fourth deferred-polish build: a 🛡 **Policy bundles** editor (☰ drawer) so named
`policies.bundles` and `policies.attachments` no longer have to be hand-edited in
`cc-config.json`. Unlike the other editors, these live INSIDE the config file, so the
handler reads the raw config, applies a pure op to the `policies` subtree, and writes the
whole file back — carefully, so unrelated config survives.

- **Bundle authoring:** name, **autoDeny** / **autoAllow** patterns (one per line), per-bundle
  **gateTools** (hold-for-approval list), **lockedPermMode**, soft **toolLimits** (`Tool=N`),
  and **autopilot** / **disableGlobal** toggles. One-click copy of a starter
  (read-only / no-bash / no-network from `DEFAULT_POLICY_BUNDLES`). A non-armed-gate warning
  banner (bundles only ENFORCE while headless approvals are armed).
- **Attachments** (first-match-wins): an ordered list with ▲▼ reorder, edit, delete, and an
  add form (match project/group/providerId/key globs — blank = any — → bundle dropdown).
- **cc-core (pure, +24 tests):** `validatePolicyBundle`/`policyBundleNorm` (keeps only set
  fields; `gateTools` normalized to a string like `gate.tools`; empty lists dropped; toolLimits
  coerced to numbers), `policySetBundle`/`policyRemoveBundle` (bundles is a name→bundle map),
  `validateAttachment`/`attachmentNorm`, and `policyAddAttachment`/`policySetAttachment`/
  `policyRemoveAttachment`/`policyMoveAttachment` (ordered array). Each returns a NEW policies
  subtree; `policies.patterns` + every other config key ride through untouched.
- **Config safety:** the write is gated on an actual change (opening the editor never rewrites
  the file), a malformed config is never clobbered (mutations bail with an alert), and the
  shallow-copy ops don't alias/mutate the original config tables.
- **Adversarial review** (3-lens workflow + verifiers): **0 findings** — the malformed-config
  guard, change-gated write, and 1-based index conversion preempted the config-corruption class.
- Tests: +24 cc-core, +10 dashboard pins. Suite green (1674 core + 408 ui + 183 bash).
- **Deferred (unchanged):** bundle `gateTools` auto-apply at spawn, `toolLimits` shell
  enforcement (it's a soft/ledger indicator), and free-text deny-reason enrichment.

## 2026-06-14 (deferred polish ③) — L1 agents registry editor

Third deferred-polish build (the largest): a ✦ **Agents** editor (☰ drawer + a "Manage
agents…" button in the New-session modal) so agent profiles (`cc-agents.json`) and MCP servers
(`cc-mcp.json`) no longer have to be hand-edited. The old "Save as agent" only saved the basic
fields and told you to hand-edit the JSON for skills/MCP/knowledge — that's now a real editor.

- **Full-field agent authoring:** name, category, folder, provider (dropdown), model, perm
  mode, the persona (role/goal/backstory), seed prompt, **skills** + **MCP servers** as toggle
  chips, **knowledge** / **plugin** dirs + **folder globs** as editable lists, and the L2
  **policy bundle** (dropdown). The attach chips render the UNION of available + currently
  selected, so a selection for a now-missing skill/server is never silently dropped.
- **Management:** favorite (★ toggle), fork (lineage-stamped), archive/unarchive, a sort
  dropdown (name/favorite/last-used), a "show archived" toggle, delete, and a one-click Spawn
  from a profile's saved folder.
- **MCP registry surface:** list/add/edit/delete `cc-mcp.json` servers (transport stdio/sse/
  http, command/args or url, allowed tools, auth-token ENV name) attachable to any agent.
- **cc-core (pure, +8 tests):** `agentSetFlag(state, name, flag, value)` toggles favorite/
  hidden/archived/deleted on RAW state, preserving every other field. The rest of L1
  (validate/push/fork/sort/resolve, MCP registry) was already shipped.
- **No edit data-loss:** an edit rebuilds the record from the form but the handler carries
  forward every field the form doesn't expose (modelByMode/requiredEnv/versions + the
  management flags + lineage) — verified all 26 `AGENT_FIELDS` are covered by (form ∪
  carry-forward). A rename removes the old record first (name-keyed push) and reads the prior
  from the old name; `oldName` is stripped before validate. XSS-safe (textContent throughout).
- **Adversarial review** (4-lens workflow + verifiers): one real issue — the MCP form wiped
  itself after Save without pre-validating the transport requirement, so a server-side reject
  lost the typed input (the agent form pre-checks its reject conditions; the MCP form now does
  too). Fixed.
- Tests: +8 cc-core, +14 dashboard pins. Suite green (1650 core + 398 ui + 183 bash).
- **Deferred (unchanged):** an in-editor `modelByMode` / `requiredEnv` editor (carried forward
  on edit; hand-edited in `cc-agents.json` today), agent folders tree, recently-deleted/restore.

## 2026-06-14 (deferred polish ②) — L3 templates editor (authoring + version/revert)

Second deferred-polish build: a 📝 **Templates** editor (☰ drawer + a "Manage templates…"
row in the Tpl menu) so templates no longer have to be hand-edited in `cc-templates.json`.
You can author with the **structured** fields the inline Tpl menu hides — a description +
optional "Expected output:" block — or raw text, with a live **Variables detected** readout;
view a template's **version history** and **revert** to any prior version (non-destructive);
and rename, all in-panel.

- **cc-core (pure, +10 tests):** `templateRename(state, old, new)` moves a template under a
  new name while PRESERVING its full record incl. version history (an editor rename via
  delete+re-add would have dropped it) and overwrites a same-new-name record (the UI confirms
  first). The rest of L3 (validate/compose/versioned-save/`templateVersions`/`templateRevert`)
  was already shipped — this is mostly UI.
- **dashboard:** `editorTemplates()` sends the structured fields (description/expected_output/
  text + composed body + detected vars + version count); bridge handlers `template-editor-list/
  -save/-delete`, `template-versions`, `template-revert`. A rename is atomic server-side
  (`templateRename` → `templatePushVersioned`), and an edit carries forward a hand-authored
  vars schema so the structured save can't drop it. The `#tpleditor` overlay has a list view, an
  author form (mode toggle, name-collision confirm), and a versions view with per-snapshot
  Revert. XSS-safe (every template field rendered via `textContent`).
- **Adversarial review** (3-lens workflow + verifiers): **0 findings** — the history-preserving
  rename + vars carry-forward preempted the edit/rename data-loss class.
- Tests: +10 cc-core, +11 dashboard pins. Suite green (1642 core + 384 ui + 183 bash).
- **Deferred (unchanged):** an in-editor vars-schema editor (labels/defaults are still
  hand-edited or derived from `{{var}}`).

## 2026-06-14 (deferred polish ①) — L7 routine board UI

First of the deferred-polish-queue builds: routines no longer have to be hand-edited in
`cc-schedules.json` — a ⏰ **Routines** board (☰ drawer) lists every routine with an
enabled dot, schedule/action badges, next-run time, and inline **Run · Pause/Resume · Edit ·
Delete**; an Add/Edit form has a **live cron preview** built from hour/minute/weekday pickers.
The firing ENGINE is untouched — this is purely the editor + a manual trigger.

- **cc-core (pure, +33 tests):** `cronBuild(spec)` assembles a 5-field cron from the picker
  state (minute/hour/day/week/month; clamps + sorts/dedupes weekdays; always emits a cron
  `validateSchedule` accepts) — **hand-mirrored** in the panel JS twin `cronBuildJS`.
  `schedulePush`/`scheduleRemove`/`scheduleGet`/`scheduleSetEnabled` are the board CRUD
  (mirroring the agent registry: validate → replace-in-place → cap; `setEnabled` toggles on
  RAW state to preserve every field). `scheduleBoard(list, now)` annotates each row with a
  human-readable schedule + the next-run epoch (display-only; the firing path still uses
  `dueSchedules`).
- **Run now** fires the spawn/digest effect immediately, bypassing cron/enabled, WITHOUT
  mutating schedule state — and spawns still respect `spawn.live`'s dry-run, so it's safe by
  default. A board warning banner calls out when `schedules.enabled` or `spawn.live` is off.
- **Adversarial review** (4-lens workflow + per-finding verifiers) caught real **edit
  data-loss**: rebuilding the record from form fields dropped a digest's `pushTopic` (and
  `model`/`templateRef`/`agentRef`/`tags`), and a rename dropped `lastFiredAt` (a renamed cron
  could double-fire the same minute). Fixed: an edit now carries those non-form fields forward
  from the prior board row, `pushTopic` got an in-panel input, and a name collision now
  confirms before clobbering. (A self-review also caught + fixed a cron-clobber on Edit:
  opening the form recomputed the raw cron from pickers, destroying a hand-written cron —
  split visibility from picker-driven rebuild so the raw field stays the source of truth.)
- Tests: +33 cc-core, +18 dashboard pins. Suite green (1632 core + 373 ui + 183 bash).
- **Deferred (unchanged):** import/export routines, overlap control, a launchd
  asleep-while-due backstop.

## 2026-06-14 (later still ×4) — L7 scheduled spawns / routines (backlog complete)

Seventh and final backlog build. Routines fire the NORMAL spawn/nudge effects on a schedule
(NOT a second executor). Off unless `schedules.enabled`; each routine is `enabled:false` until
explicitly turned on; scheduled spawns still respect `spawn.live` (dry-run by default) — triple opt-in.

- **Cron/schedule layer** (cc-core, pure on an injected `now`): `cronMatches` (5-field
  min/hour/dom/month/dow with `*`, `N`, `A-B`, `A,B,C`, `*/S`, `A-B/S`; dom-OR-dow when both set;
  0/7 = Sunday), `nextRunAt` (next match for the board's "next run"), `dueSchedules` (fires once per
  matching minute via `lastFiredAt`; oneShots when `at` passes), `humanizeCron`, `validateSchedule` /
  `scheduleLoad` (fail-safe, mirrors the L1 registry), `scheduleMarkFired` (stamp / self-delete a
  oneShot), `scheduleBackpressure`.
- **Firing engine** — `cc-schedules.json` routines `{name, kind: cron|oneShot, cron|at, folder,
  editor?, provider?, model?, permMode?, prompt?, action: spawn|digest, enabled}`. A guarded pass in
  the refresh loop fires due routines through `FX.spawnSession` (respecting `spawn.live`), stamps
  `lastFiredAt`, self-deletes one-shots, and defers under `schedules.maxConcurrent` backpressure.
  Missed crons don't flood (only the current minute matches); a missed oneShot fires on next startup.
- **Periodic digest** (`action: "digest"`) — a cron routine that pushes a `fleetStandup` shift report
  over a window via `FX.push` (the first concrete consumer of the scheduling primitive). Needs no folder.
- Review-fix pass over today's commits (kept only what mattered): `classifyError` no longer mis-buckets
  "insufficient permissions" / "connection aborted"; `isLooping` ignores arg-less signatures (no false
  ⟳ on repeated TodoWrite); L6 header comment corrected (runs ALL matching rules, not the first); +
  locking pins (classifyError precedence, newest-ExitPlanMode, plan-text esc()).
- Tests: +42 cc-core checks, +11 dashboard pins. Suite green (1599 core + 355 ui + 183 bash).
- **Deferred:** the routine **board UI** (Add-Routine modal, run-now, pause/resume, live cron preview —
  routines are hand-edited in `cc-schedules.json` for now), import/export, overlap control, and a launchd
  asleep-while-due backstop.

**Backlog complete:** L1–L7 of the cross-project feature-mining backlog are all shipped. Remaining work
is the deferred polish queue (editor UIs, L4 UX-gated routing pieces, heavier L5 sub-items, L6 extra
triggers, the L7 board UI) — see todos.md.

## 2026-06-14 (later still ×3) — L6 event-callback rule engine

Sixth backlog build. Declarative, OPT-IN rules that react to a session edge with a safe effect —
generalizing the hard-coded auto-respawn/continue/escalation onto the existing level-triggered
dispatcher (not a new event bus). Off unless `rules.enabled`.

- **Rule engine** (`cc-rules.json`) — a rule is `{name, enabled, trigger:{kind, match?}, processor:
  {kind, text?, label?}, once?}`. cc-core: `validateRule` / `ruleLoad` (fail-safe, dedupe, mirrors
  the L1 registry) / `ruleList`; `ruleScopeMatch` (wildcard glob on project/group/sessionKey/provider);
  `ruleFires` / `rulesForEdge`. The dashboard loads the rule set once per refresh and runs matching
  rules on a **fresh status edge** (v1 triggers: `done` / `error` / `approval`). Processors map onto
  existing SAFE effects: `log` → a `by:"rule"` ledger event, `relabel` → `setLabel`, `nudge` → the
  delivery-gated nudge path. `once` rules fire at most once per (rule, tile) via a marker that's reaped
  when the tile vanishes. Edge-triggered (a reload's `pv==nil` never fires).
- **Automation result ledger** — automation events now carry an `outcome`: `auto_respawn` →
  `outcome="ok"`; the previously **silent** would-respawn-but-can't branch now ledgers
  `auto_respawn_blocked {outcome="skipped", reason}`; `auto_continue` ledgers **inside** the serialized
  closure with the outcome from actual delivery. `handleAction("continue")` is now delivery-gated
  (returns nil on a no-window-match skip), and the **manual** Continue path was moved to a
  post-dispatch, delivery-gated ledger to match (review-caught: the eager pre-dispatch log would have
  recorded a skipped resume as a success).
- Reviewed adversarially (5 reported, 3 confirmed — all the one manual-continue audit-fidelity issue,
  fixed). Tests: +33 cc-core checks, +15 dashboard pins. Suite green (1548 core + 344 ui + 183 bash).
- **Deferred:** the `hung` / `loop` / `starved` rule triggers (v1 fires on the three status edges;
  those edges fire at different sites), the `feed` / `continue` processors, per-rule status lifecycle
  (COMPLETED/ERROR), and a rules editor UI (`cc-rules.json` is hand-edited).

## 2026-06-14 (later still ×2) — L5 richer session observability

Fifth build from the feature-mining backlog. Pure-core derivations off the transcript Shepherd
already tails + local reads — no executor, no sandbox, no server. Each automatic piece is off by
default.

- **Error-reason taxonomy** — `core.classifyError(msg)` maps an API error to a coarse cause
  (`budget_exceeded` / `timeout` / `runtime_error` / `model_error` / `user_cancelled` / `unknown`);
  `transcriptError` now returns `{message, reason}`. Error tiles show a cause badge
  (`[budget exceeded] …`), and the cause is ledgered once on the fresh transition into error (an
  errors-by-cause facet in the audit timeline + search).
- **Plan / TODO on the detail panel** — `core.planFromTranscript(tail)` surfaces the agent's latest
  `TodoWrite` todos and/or `ExitPlanMode` plan; loaded **on selection** (a `plan` bridge action,
  never the 1s tick), rendered in a `#d-plan` section with `esc()` at the sink.
- **Auto-title tiles** (config `autoTitle.enabled`, default **off**) — `core.deriveAutoTitle(seed)`
  names an unlabeled tile from its first prompt; cached once per `projectKey` in `cc-autotitles.json`.
  Precedence: manual relabel > auto-title > folder basename.
- **Loop-detection watchdog** (config `escalation.loop.enabled`, default **off**) —
  `core.toolCallSig`/`transcriptToolSigs`/`isLooping` flag a working session repeating the same tool
  call (re-running a failing command, re-reading a file); a ⟳ tile badge + one `loop` ledger event
  per episode. Reuses the tail already read for working tiles; detection only (no auto-nudge).
- **OS-native desktop banners** (config `notifications.banner.{onApproval,onDone}`, default **off**) —
  `core.notifyDecision` fires on a fresh rising edge into approval/done; `FX.notify` wraps `hs.notify`
  and the click jumps to the session. Local-only, no network.
- Reviewed adversarially (2 reported, 0 confirmed). State-lifecycle care from the L4 lesson:
  `loopAlerted` is reaped when a key vanishes; `autoTitles` is written only when a new title is
  computed. Tests: +56 cc-core checks, +21 dashboard pins. Suite green (1528 core + 330 ui + 183 bash).
- **Deferred L5 sub-items** (the phase is large): detail-panel tab strip, export session archive, host
  stats + fleet idle-since, PR/MR status per tile, post-run self-summary, hooks inspector, the
  session-history browser, and a Settings UI toggle for auto-title/loop/banners (config-only for now).

## 2026-06-14 (even later) — L4 declarative routing & orchestration

Fourth build from the feature-mining backlog. Extends the shipped Project Routing v1 dispatcher
with conditional routing, process modes, join barriers, and per-task timing. All off unless
`queue.routing.enabled` + a project is armed; a queue with no routing syntax is byte-unchanged.

- **Conditional routing by `@role:`** (the DECIDED affinity source): a queued task prefixed
  `@review: …` routes only to a free session whose GROUP is `review`. cc-core `taskRoute`
  (parse/strip), `memberRole` (group = the match axis), `routePick` role filter; `routeTask`/
  `queueStarved` derive the FIFO head's role. `renderFeed` strips the prefix so the session never
  sees the scaffolding. (Review-caught + fixed: `applyGroups` must run before the dispatcher or
  `.group` is nil at route time and labeled tasks starve.)
- **Process modes — `seq` toggle** (`queueRouteMode`/`queueSetMode`, rides the queue file like the
  arm flag): *distribute* (default) fans across whichever member is free; *sequential* runs the
  queue ONE routed task at a time (`projectBusy` holds the next until the current finishes).
- **Join barriers `@all:` / `@any:`** (`taskBarrier`/`routeBarrierMet`): a task prefixed `@all:`
  waits until every project member is settled (done, not stale/remote), `@any:` until one is, before
  it routes. Composes with a role (`@all: @review: x`). `queueStarved` treats a waiting barrier as
  waiting, not starved.
- **Per-task timing** (`stepTaskDone` + a `taskStart` map): a fed queue task is timed from feed to
  its first done edge; a `task_done` ledger event records `{durationS, role, by}`, and `fleetStandup`
  rolls it into the Shift report (tasks completed · avg · total). Stamped only on a *delivered* feed;
  the raw queued task is still what's popped/persisted. (Review-caught + fixed: the timer map is
  abandoned when a session goes stale and reaped when a session vanishes, so it can't leak or ledger
  a bogus duration after a long stall.)
- Reviewed adversarially across two passes (round 1 caught the `applyGroups` ordering bug; round 2
  over modes/barriers/timing reported 8, confirmed 5 — all the one `taskStart`-GC issue, fixed).
  Tests: +66 cc-core checks, +13 dashboard pins. Suite green (1481 core + 308 ui + 183 bash).
- **Deferred (still UX-gated, by design):** the routing topology view, role-addressed delegation/
  handoff, idle-as-routing-target, and auto-spawn on starvation — each needs a design call first.

## 2026-06-14 (later still) — L3 parameterized + versioned prompt templates

Third build from the feature-mining backlog. Turns saved task templates from flat `{name, text}`
strings into **parameterized, structured, versioned** records — the local "agent-definition"
layer that feeds the input, the New-Session spawn, and the autonomous queue. Back-compat is
preserved end to end (a legacy `{name, text}` round-trips byte-identically; the old
`templatePush/templateGet/templateRemove` API and the existing Tpl-menu flow are unchanged).

- **cc-core (pure, deterministic — clock injected via `opts.now`; mirrors the L1 validator family):**
  `validateTemplate`/`templateLoad`/`templateList` (fail-safe per-entry load: keep valid, drop bad
  with reasons, dedupe-first-wins; known-fields allowlist), `composeTemplate` (structured body =
  description + an "Expected output:" block, else legacy text), `templateVars`/`renderTemplate`
  (`{{name}}` required / `{{name?}}` optional + the built-ins `date`/`today`/`now`/`prev_output`;
  a missing required var REFUSES the render — or, with `keepMissing`, is left verbatim and never
  refuses), `effectiveVars`/`fillDefaults`, `templatePushVersioned`/`templateVersions`/
  `templateRevert` (duplicate-on-edit: snapshot the prior head into a capped history + bump; the
  change detector signs on the COMPOSED body so a shadowed-field edit doesn't spuriously bump),
  and `parsePromptFile`/`promptImport` (definition source).
- **Variables in the Tpl menu:** picking a template with vars opens an inline fill-in form (required
  vars gate Insert); cc-core renders it — `{{prev_output}}` = the selected tile's latest output —
  and the result drops into the input, **never auto-sent**. cc-core is the authoritative renderer
  (no JS render twin to drift). A `{{ }}` badge + version chip mark templated/edited entries.
- **Render-before-spawn:** a Templates picker in the New-Session modal seeds the Initial-task field;
  a template with vars is filled in first (required vars gate "Use") and rendered into the task — so
  the spawn task is fully resolved BEFORE spawn.
- **Render-before-feed (queue):** every queued task is rendered just before it's typed in (manual,
  autofeed, router) — `{{prev_output}}` (the just-finished turn's output) + date built-ins resolve;
  user `{{vars}}` that can't be auto-filled are left verbatim, and a task with no placeholders is
  byte-unaffected. The raw queued task is still what's popped/persisted/ledgered.
- **Versioned saves:** re-saving a template snapshots the prior body and bumps the version
  (`templatePushVersioned`); an identical save is a no-op.
- **Definition source / import:** `⤓ Import from prompts folder…` imports `*.prompt` / `*.md`
  files (front-matter `name` + body, no YAML/Jinja) from a local dir (`templates.sourceDir`, default
  `~/.claude/cc-prompts`) into the store, versioned. Strictly local-disk — no network.
- **Robustness (from an adversarial-review pass):** the version-change detector signs on the
  composed body (no spurious bumps from shadowed fields); corrupt/hand-edited records are surfaced
  to the console on load instead of being silently reaped on the next save/delete. A second review
  pass over the modal/queue/import surfaces reported 30 candidates, 0 confirmed.
- **Deferred follow-up** (cc-core already supports it): the full structured-template authoring editor
  (description/expected_output fields) + the version/revert VIEW UI — today those structured fields
  are hand-edited in `cc-templates.json` or imported. (Same "defer the editor" posture as L1/L2.)
- Suite: **1425 core + 293 ui + 183 bash**, all green.

## 2026-06-14 (later) — L2 named policy / guardrail bundles + attachments

Second build from the feature-mining backlog. Turns the flat fleet policy
(`policies.patterns.autoAllow/autoDeny`) into NAMED, reusable bundles you attach per-session
or fleet-wide.

- **cc-core (pure, tested):** `resolvePolicy` (precedence session-override > attached bundle >
  fleet; unions bundle+fleet lists, or drops the fleet when `disableGlobal`), `matchAttachment`
  (project/group/provider/key glob matching), `globEq`, `policyBundles`/`policyBundle`,
  `overToolLimit`, and `DEFAULT_POLICY_BUNDLES` (read-only / no-bash / no-network starters).
- **The gate (`cc-approve.sh`):** `match_patterns` reads a per-session `cc-policy/<key>` file when
  present — **authoritative + opt-in** (applies even if `policies.patterns.enabled` is false; the
  bundle name lands in the ledger `by`). Absent file → the old fleet behavior, byte-identical.
- **Dashboard:** resolves each session every tick (attachments fleet-wide, the detail-panel
  **Policy dropdown** override wins) and change-gated-writes the gate's per-session file; a
  **decoupled orphan sweep** tears down any resolved file not re-written that tick, so removing an
  attachment (or a session ending) can never leave a stale, still-enforcing policy.
- **Config:** `policies.bundles` + `policies.attachments` documented in the example.
- **Lifecycle:** `cc_remove` (SessionEnd) now reaps `cc-policy`/`cc-policy-override`;
  `writeResolvedPolicy` is atomic (temp+rename) so the gate never reads a torn file.

Built with an **adversarial review pass** (5 dimensions → skeptic-verify) before deploy, which
caught the orphaned-file enforcement bug, the SessionEnd leak, and the non-atomic write — all
fixed + regression-tested here. Suite **1346 core + 260 ui + 183 bash**, all green; deployed
(`make setup`) + live-verified (the deployed gate denies under a read-only bundle file).
Deferred follow-up: the bundle/attachment EDITOR UI (today they're hand-edited config), bundle
`gateTools` auto-apply, and `toolLimits` enforcement in the shell.

## 2026-06-14 — L1 Agent Profiles ("spawn from a saved agent") + Phase 0 foundation

First build from the cross-project feature-mining backlog (5 sources mined → L1–L7 in todos.md;
reports in `docs/feature-mining/`). Shipped **L1 — Agent Profiles**, the user's #1 stated interest
("pre-configured agents we hand work off to, saved into a directory; same with skills and MCPs").

**Phase 0 foundation (pure `cc-core`, fully unit-tested):**
- **Registries:** `cc-agents.json` (`agentList/agentLoad/agentPush/agentRemove/agentGet/agentFork/agentSort`)
  and `cc-mcp.json` (`mcpList/mcpLoad/mcpPush/mcpRemove/mcpGet`) — with a **fail-safe load** discipline
  (validate each record, keep the valid, drop only the bad, return the dropped names+reasons).
- **Pre-flight validator:** `validateAgent`/`validateMcp` (required fields, absolute-folder shape, array
  types, unknown-field flagging, and cross-ref checks for provider/policyBundle/skill/MCP).
- **Spawn-from-agent plumbing:** `resolveAgent` (profile → concrete spawn intent), `personaPrompt`
  (role/goal/backstory → `--append-system-prompt`), `mcpConfig` (→ `--mcp-config` JSON; secrets as
  `${VAR}` refs, never stored), `spawnExtraFlags` (threads `--mcp-config`/`--append-system-prompt`/
  `--agent`/`--add-dir`/`--plugin-dir` into `spawnSpec`), plus `missingEnv` and `profilesForFolder`
  (folder-scoped auto-attach). New `shArg` helper quotes value-bearing flags in the shell sinks while
  keeping kitty argv raw and existing no-space flags **byte-identical** (no spawn/editor regression).
- **Skills card:** `parseSkillFrontmatter` + `skillCommand` (dual-shape `SKILL.md` / flat `*.md`).

**Dashboard wiring (`claude-dashboard.lua`):**
- FX: `readAgents/writeAgents`, `readMcp/writeMcp`, `listSkills` (enumerates `~/.claude/skills`),
  `writeMcpConfig`.
- `handleAction`: agent CRUD (`agent-save`/`-delete`/`-fork`), MCP CRUD (`mcp-save`/`-delete`), and
  **spawn-from-agent** (resolve profile → write its `--mcp-config` → spawn with the extra flags; selected
  skills ride the appended system prompt; `seedPrompt` seeds the task; `lastSpawnedAt` stamped; a
  `spawn_agent` ledger event). The New-Session modal is fed agents/MCP/skills.
- New-Session modal UI: an **Agents** chip row (one-click "spawn from this agent" + ✕ delete), a
  **Save as agent** button (name/role/folder/editor/mode/provider/seed), and a read-only **Skills card**
  (the `/command` + description for every skill in `~/.claude/skills`).

Real spawning stays gated by `spawn.live` (dry-run by default); secrets are never stored (env-var NAMES
only, expanded by the spawned login shell). **Deferred follow-up** (cc-core already supports it): the
richer registry-management UI — folders/favorites/hide/archive/fork buttons, a sort dropdown, an in-panel
skills/MCP/knowledge attach editor, and an MCP-registry management surface (today: edit `cc-agents.json` /
`cc-mcp.json` arrays by hand). Suite **1322 core + 238 ui + 177 bash**, all green; deployed + live-verified.

## 2026-06-13 (later 3) — pad-mirror batch: priority jump + ⌨ legend + shift report + lineage

Crawled the `pad` project (a local-first agent-era task manager) for ideas worth mirroring,
ran an adversarial pass per candidate, and shipped the four that survived — each a *widening
of an existing Shepherd primitive*, not a new parallel system. (The tempting ones — playbooks,
durable conventions/notes, a task backlog — were declined as domain creep / duplicates of
CLAUDE.md + the gate.)

### Added
- **Jump-to-priority global hotkey (1.1a)**: **⌘⌥J** now targets `core.nextAttention`
  (a pending **approval** › a frozen **error** › a watchdog-**stalled** session) instead of
  approvals-only, and reads the fully-annotated render list (so the error/stalled tiers
  actually fire) — focusing the right window **from any app**, panel open or not. Generalizes
  the old jump-needy key; no new binding. Pure `core.nextAttention`, falls back to the front
  session when nothing's wedged.
- **⌨ Hotkey legend (1.1b)**: a subtle **bottom-right** button whose popup opens **upward**
  with every shortcut + what it does. Built in Lua from the real `HOTKEY_*` bindings via pure
  `core.hotkeyLegend` / `core.fmtHotkey` (macOS-canonical ⌃⌥⇧⌘ order) and injected as
  `__HOTKEY_LEGEND__`, so the displayed combos **can't drift** from what's actually bound.
- **📋 Fleet shift report (1.3)**: a **📋 Shift** tab in the audit overlay (and ☰ drawer) that
  summarizes **what the fleet did** over a window — **Since opened** / **Last 8h** / **Last
  24h** — sessions, prompts, approvals (allow/deny + who decided), auto-actions
  (respawn/continue/drain/routed), escalations/stalls, time blocked on you, and a per-project
  rollup, with a **Copy** button. Pure `core.fleetStandup` + `core.standupMarkdown` (one source
  for the `<pre>` body and the copied text). **Ops only — no "what shipped" changelog** (a
  prompt is an instruction, not an outcome; Shepherd has no git/CI ground truth).
- **♻️ Session lineage (1.6)**: the normally-invisible respawn/`/clear`/continue churn for a
  project (each mints a new session id) is now legible — a detail-panel one-liner ("3rd session
  today · 2 auto-respawns · 1 clear") since local midnight, plus a tile **♻️N** badge once the
  churn adds up. One ledger pass per tick via pure `core.lineageByProject` (cached on ledger
  change / day roll, like the 🔔 badge); `core.lineageSummary` formats it. Pure read — **nothing
  new is stored**, and it degrades to nothing when the ledger is off.

### Changed
- `core.filterLedger` gained a `projectKey` filter (a project's whole lineage spans the session
  ids a respawn/clear mints); `core.projectLineage` now delegates to `core.lineageByProject` so
  the per-tick map and any per-session read can't disagree.

### Tests
- **+47 core** (`nextAttention`, `fmtHotkey`/`hotkeyLegend`, `filterLedger` projectKey,
  `projectLineage`/`lineageByProject`/`lineageSummary`, `fleetStandup`/`standupMarkdown`) and
  **+13 ui** source-pins for the webview wiring (incl. a guard that the `__HOTKEY_LEGEND__`
  placeholder is always substituted — an unsubstituted one would take the panel script down).
  Suite **1260 core + 205 ui + bash**, all green.

## 2026-06-13 (later 2) — CLI accelerators (fd/rg) wired + folder-scan deadlock fix

The "better grep" was set up but looked unused. Audit (verified live): `rg` was already
installed and powering fleet search; `fd` was simply not installed (folder scan silently used
`find`); `jq` (the only hard dep) was fine. Three things came out of it:

### Fixed
- **Folder scan deadlocked over a large tree** (pre-existing; hit `find` too, not fd-specific).
  `FX.scanFolders` direct-exec'd the scanner via `hs.task`, which **stalls once the child's
  stdout exceeds the OS pipe buffer (~64KB)** — the task waits for exit while the child blocks
  on a full pipe nobody drains. Over `~/Programming` (1187 dirs ≈ 71KB) it hung forever, so the
  New-session **fuzzy folder type-ahead silently produced nothing**. Now the scan runs via
  `/bin/sh` with stdout **redirected to a temp file** (the task's own pipe stays empty → no
  deadlock; the login-shell path always worked for the same reason), read back on exit, with a
  **15s timeout backstop** so a wedged scan can never pin the index. New pure
  `core.folderScanShellCommand` (POSIX-quoted argv + redirect, unit-tested); verified live
  (`folder scan: fd … -> 1187 dir(s)`, was 0).

### Added
- **Runtime engine visibility** — the search/scan paths now log which engine actually ran:
  `[cc-search] engine=rg …` and `[cc-spawn] folder scan: fd …` (with an "install for speed" hint
  on the `grep`/`find` fallbacks). Previously neither logged anything, so rg "looked unused."
- **`make doctor`** (alias `tools`) + an install.sh **tooling-check** step: reports jq (required)
  + the rg/fd accelerators (optional), offers to `brew install` a missing one when interactive
  (prints the command otherwise), never hard-fails, and is skipped non-interactively (tests /
  `make setup` never block). README note on the optional accelerators.

### Tests
- Suite **1211 core + 192 ui + 167 bash**, all green. New: `folderScanShellCommand` quoting +
  redirect (incl. spaces and a single-quote injection guard); fscan-pins that the scan runs via
  `/bin/sh` + temp file + timeout and that the direct-exec path is gone; and 8 hermetic
  install.test.sh cases for the non-interactive tooling check.

## 2026-06-13 (later) — Review fixes + collapse the toolbar into a ☰ views drawer

Applied the leaderboard review of `80dddb8` (each claim verified against the code first;
the "loosen the js-pins to patterns" note was declined — the whole ui.test.lua uses exact
source tripwires by design, and the fragility is documented).

### Fixed
- **`context.autoCompactFraction` had no lower bound** — a tiny hand-tuned value (e.g. `0.01`)
  passed the `>0` guard, shrank the denominator to ~0, and pinned every tile to a false 100%
  b6. Clamped to a sane `[0.5, 1]` (output reserve is never half the window), falling back to
  the default otherwise. The `0.5` floor stays valid (the existing tighter-fraction test).

### Added
- **Toolbar collapse**: the five view icons (🔍 filter, 🔎 fleet-search, 📊 insights, 📜 audit,
  🔔 notifications) now live behind a single **☰** button that pops a labeled drawer (icon +
  name per row). The unseen-notification badge rides the ☰ button (and the drawer's
  Notifications row); the drawer closes on pick or outside-click. New / ☕ / ⚙ / theme stay put.
- **Comment cross-refs** between `core.contextBand` and the JS `barLevel` twin (each names the
  other + the guarding test), so the next edit jumps straight to the mirror.
- Tests: explicit `stepAutoContinue` cases for the `working`-doesn't-reset-the-budget anti-loop
  invariant (as a natural fire→working→re-error sequence) and the `nil` clock (elapsed 0, no
  fire); the `autoCompactFraction` floor cases; and a ui-pin that the ☰ drawer still wires all
  five views. Suite **1206 core + 187 ui + 167 bash**, all green.

### Security
- Noted (Settings help + README + example config) that `remoteControl.onSpawn` is **on by
  default** and that `--remote-control` lets anyone with your claude.ai account drive a local
  shell — an informed-choice note, no behavior change.

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
