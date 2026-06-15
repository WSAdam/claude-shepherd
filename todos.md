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
- **Toolbar collapse + review fixes (June 2026)**: the five view icons (🔍 filter, 🔎 fleet-
  search, 📊 insights, 📜 audit, 🔔 notifications) fold into a single **☰** drawer (icon + name
  per row, badge on the button + Notifications row, closes on pick/outside-click); plus the
  leaderboard review of the prior commit — `context.autoCompactFraction` clamped to `[0.5,1]`
  (a tiny value pinned every tile to a false 100%), `contextBand`↔`barLevel` cross-ref comments,
  explicit `stepAutoContinue` anti-loop + nil-clock tests, and an RC on-by-default security note.
- **CLI accelerators wired + folder-scan deadlock fix (June 2026)**: `fd` installed and
  auto-detected (folder scan was silently using `find`); runtime **engine logs** (`[cc-search]
  engine=rg …`, `[cc-spawn] folder scan: fd …`) so the accelerators are visible; **`make doctor`**
  + an install.sh tooling check (jq required; rg/fd optional, offers brew-install, non-interactive
  under tests). **Fixed a pre-existing folder-scan deadlock**: `hs.task` direct-exec stalled once
  a scan's stdout topped the ~64KB pipe buffer (the New-session fuzzy folder type-ahead had been
  silently empty over a large tree) — now runs via `/bin/sh` with a temp-file redirect + a 15s
  timeout (`core.folderScanShellCommand`). Verified live (`folder scan: fd … -> 1187 dir(s)`, was
  0). Suite **1211 core + 192 ui + 167 bash**, all green.
- **pad-mirror batch (June 2026)**: crawled the `pad` project (a local-first agent-era task
  manager), ran an adversarial pass per candidate, and shipped the four that survived — each a
  *widening of an existing primitive*, not a new system (playbooks / durable conventions+notes /
  a task backlog were **declined** as domain creep or duplicates of CLAUDE.md + the gate):
  1. **Jump-to-priority hotkey** — **⌘⌥J** now targets `core.nextAttention` (approval › error ›
     stalled) over the fully-annotated render list (so the error/stalled tiers fire), not
     approvals-only; focuses the right window from any app. Generalizes the old jump-needy key.
  2. **⌨ hotkey legend** — a bottom-right button whose popup opens upward listing every shortcut,
     built in Lua from the real `HOTKEY_*` bindings (`core.hotkeyLegend`/`fmtHotkey`) and injected
     as `__HOTKEY_LEGEND__` so the combos can't drift.
  3. **📋 Fleet shift report** — a Shift tab in the audit overlay (+ ☰ drawer) summarizing what the
     fleet did over a window (Since opened / 8h / 24h): sessions, prompts, approvals + who decided,
     auto-actions, escalations/stalls, time blocked on you, per-project rollup, with Copy. Pure
     `core.fleetStandup` + `core.standupMarkdown`. Ops only — no "what shipped" line. Tab + drawer
     row only appear while the ledger is on (`setLedgerOn`, live with the toggle).
  4. **♻️ Session lineage** — respawn/`/clear`/continue churn per project (each mints a new session
     id) made legible: a detail one-liner since midnight + a tile **♻️N** badge once churn adds up.
     One cached ledger pass/tick via pure `core.lineageByProject`; self-gates when the ledger's off.
  `core.filterLedger` gained a `projectKey` filter; `core.projectLineage` delegates to
  `lineageByProject`. Suite **1260 core + 210 ui + 177 bash**, all green. Shipped + deployed + pushed.
- **L5 build-ready batch (June 2026) — 5 of 7 shipped.** The heavier L5 detail/observability sub-items, each
  via the loop (pure cc-core + tests → wire + ui pins → adversarial-review Workflow → fix → deploy → commit →
  push):
  1. **Detail-panel tab strip** — the flat `#detail` stack reshaped into Activity/Timeline/Decisions/Usage/
     Changes/Queue tabs from `core.DETAIL_TABS` (injected `__DETAIL_TABS__`); `{selectedTab, unpinned}` persists
     to **webview localStorage keyed by projectKey** (the panel's first localStorage use); inline **Timeline** is
     lazy (a `detail-timeline` action → `core.sessionTimeline`), stale-guarded; a ⋯ menu hides/shows tabs.
  2. **git Changes tab** — per-session `git status --porcelain=v1 -z` (`core.parseGitStatus`, run from the repo
     ROOT) + click-to-expand colorized per-file diff (`FX.gitDiff`, rename-aware via `-M`, capped). Bridge path
     validated against the session's status set (`core.resolveDiffTarget`) so the `--no-index` fallback can't read
     an arbitrary file. Local tiles only.
  3. **Export session archive** — ⤓ Export button + tile right-click → copies the transcript `.jsonl` (verbatim,
     via `cp`) + a `meta.json` (`core.sessionExportMeta`: label/provider/model/lineage/activity, no prompt bodies)
     into `~/.claude/cc-exports/<unique>/`, reveals in Finder; ledgers a `session_export`.
  4. **Post-run self-summary + onAutoApproved banner** — both opt-in, off by default. Self-summary types a brief
     review prompt on a fresh `done` edge (delivery-gated; `core.stepSelfSummary`/`promoteSummary` own the loop
     guard so the summary's own done can't re-fire). onAutoApproved fires a macOS banner when the newest automated
     `allow` decision advances (`core.newestAutoApprove`, ≤30s lag, ledger-gated, remote/stale-excluded).
  5. **PR/MR status badge** — off by default, gh-backed, **status-only**. `core.parsePrStatus`/`prBadge`; async
     `FX.ghPrStatus` (`hs.task` in the repo root, 180s TTL, GC-retained, per-root cache reaped); a clickable
     "PR #N open/merged" tile badge (click reads the tile's `data-key`; Lua opens the url only if `http(s)`).
     Self-gates when `gh` is absent or the repo has no PR/remote.
  **Hardening from per-item adversarial review + the AI-leaderboard feedback** (every round found real issues):
  #2 `--no-index` arbitrary-file read + rename-rendered-as-all-additions; #3 phantom export on a write failure
  (mkdir/io fail by return value, not by throwing) + lying `meta.transcript`; #4 **HIGH** orphaned self-summary
  guard when the paste didn't land (split into pending/fired, promote on delivery); #5 unbounded `prStatusByRoot`
  + `ghBin`-cached-false-forever + gh-task GC + the `esc()`-in-JS-onclick break. Pure helpers extracted for
  behavior tests (`resolveDiffTarget`, `promoteSummary`, `officialLogDecision`). **A refresh-loop `pairs(nil)`
  crash (a reap over an uninitialized state table) shipped + was caught live → `tests/smoke.test.lua`** now loads
  the dashboard under a stubbed `hs` and runs the load-time `refresh()` in `make test`. Suite **~1848 core + 488
  ui + 183 bash + smoke**, green. **#6 host stats + fleet idle-since SHIPPED (read-only, off by default). LEFT:
  #7 session-history browser + bulk history management.**

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

## Candidate features — cross-project mining backlog

> **▶ RESUME HERE (build status, 2026-06-15): BACKLOG + EDITOR-UI POLISH DONE; L5 BUILD-READY BATCH 5/7 SHIPPED.**
> Mining DONE (5 sources → L1–L7); **Phase 0✅ → L1✅…L7✅ — ALL SHIPPED**, then the deferred editor-UI queue (☰
> drawer: ⏰ Routines · 📝 Templates · ✦ Agents · 🛡 Policy bundles · ⚙️ Automation rules + ⚙ observability toggles).
> **NOW: the "L5 build-ready batch" (the heavier L5 detail/observability sub-items).** Sequenced #1→#7; **#1–#5
> SHIPPED + deployed + pushed:** **#1 detail-panel TAB STRIP** (Activity/Timeline/Decisions/Usage/Changes/Queue;
> projectKey-keyed localStorage; lazy inline Timeline) · **#2 git CHANGES tab** (per-session `git status -z` +
> per-file colorized diff, rename-aware, path-validated) · **#3 EXPORT session archive** (⤓ button + ctx-menu →
> transcript + meta.json under `cc-exports`) · **#4 post-run SELF-SUMMARY + onAutoApproved banner** (both opt-in,
> off by default) · **#5 PR/MR STATUS badge** (gh-backed, status-only, off by default) · **#6 HOST STATS +
> FLEET IDLE-SINCE** (read-only, off by default: `core.hostHealth`/`fmtBytes`/`fmtUptime`/`fleetIdleSince`; a host
> strip — CPU/mem/disk/uptime/load + idle-since — atop the 📊 insights overlay; `FX.pollHostStats` self-gating +
> 30s-throttled, verified live; starvation alert notes host pressure; ⚙ toggle + hand-editable
> `insights.hostPressure.{cpu,mem,disk}`). **LEFT in this batch: #7 session-history browser + bulk history mgmt.**
> Each built via the loop (pure cc-core + tests → wire + pins → adversarial-review Workflow → fix → deploy → commit
> → push); the reviews + leaderboard feedback caught real bugs every round (e.g. #2 `--no-index` arbitrary-file read
> + rename-as-add; #4 **HIGH** orphaned self-summary guard on a failed paste; #3 phantom-export on write failure; #5
> prStatusByRoot leak / gh-hang retry; the `7cd6245` review caught the prPollPlan hung-task latch being dead code +
> a callback clobber race → `core.prPollPlan`/`prCallbackOwns` + data-aware hung deadline). **Suite ~1928 core + 500
> ui + 183 bash + smoke, green.**
>
> **▶ PHASE A — REVIEW-FIX HARDENING (in progress 2026-06-15):** before #6/#7, a contained pass folding in the
> two AI-leaderboard reviews of `fbcd609` (isOpenableUrl + hung-gh retry) and `879adc7` (openPr data-key +
> officialLogDecision). Triaged every finding; incorporating all but one cosmetic note (the smoke comment trim —
> the comments earn their keep). Both reviews independently caught the SAME real latent bug: the
> `prStatusTasks[root]` in-flight latch is checked AFTER the TTL, and a HUNG gh never clears it (its callback never
> fires) — so the 20s retry the prior commit added is DEAD CODE for the exact failure it targeted; the PR badge
> freezes forever. Work items: **(A1)** pure `core.prPollPlan` — full TTL once data exists, short retry while
> nil/in-flight, and a stale latch past a deadline is dead → kill the task + re-poll; timestamped latch
> `{task, ts}`; named `PR_RETRY_TTL`; behavior-tested (replaces the brittle grep pin). **(A2)** `parsePrStatus`
> rejects a present-but-non-numeric `number`. **(A3)** `isOpenableUrl` tightened to require a host (`^https?://[^/]`)
> + empty/bare-scheme boundary tests. **(A4)** `core.officialUsageStep(prev,status,bodyOk)` replaces
> officialLogDecision (single call site, 200-with-bad-body is a no-op, uses the returned newPrev) + the
> garbage-200→good-200 recovery test. **(A5)** pure `core.reapUnbacked(cache, liveKeys)` routes the 4 in-line
> refresh reaps (`prStatusByRoot`/`gitChangeFiles`/`summaryState.fired`/`.pending`) + behavior test. **(A6)** ui
> pin on the tile `data-key` write site. THEN #6 host stats + fleet idle-since, THEN #7 session-history + bulk
> history. Each phase via the loop + an adversarial-review Workflow (ultracode on).
>
> **⚠ DEPLOY DISCIPLINE (learned the hard way 2026-06-15):** a refresh-loop `pairs(nil)` (a reap over an
> uninitialized state table) crashed the WHOLE dashboard at load — luac + the unit suite missed it because
> `refresh()` was never exercised. FIX SHIPPED: **`tests/smoke.test.lua`** loads claude-dashboard.lua under a
> stubbed `hs` and runs the load-time `refresh()`; it's in `make test`. **Always `make test` (smoke included)
> before `make install`.** Deploy gotcha unchanged: `make deploy`'s `hs -c` reload can hang — do `make install`
> then reload separately with a timeout backstop. Honor the load-bearing facts (the `claude` CLI is present;
> `gate.tools` is a HOLD-list not an allow-list; secrets are env-var NAMES only), and: **every new module-level
> per-key state table MUST be initialized `{}` up front** (the reaps iterate them even when their feature is off).
> Still also LEFT: **L4 UX-gated routing**; small per-editor deferrals (L1 modelByMode/requiredEnv editor; L2
> gateTools auto-apply; L3 vars-schema editor; L6 per-rule status lifecycle); the **hardware-verification runbook**
> (Kitty tokens + SSH bridge).
> <!-- superseded build-loop note: -->
> **L1–L6 are SHIPPED + committed + deployed**
> (see CHANGELOG 2026-06-14 + their `✅` blocks below; each has a *deferred follow-up* — mostly editor UIs and,
> for L4, the UX-gated topology/delegation/idle-target pieces; for L5, the heavier UI sub-items; for L6, the
> hung/loop/starved triggers + feed/continue processors + a rules editor). **Next: L7** (scheduled spawns /
> routines — `cc-schedules.json` cron/one-shot firing the normal spawn/nudge effects; routine board; periodic
> digest — the LAST mined-backlog phase). Method per feature:
> pure logic in `cc-core.lua` + unit tests → wire the dashboard (FX/handleAction/panel-JS) + ui pins → `make test`
> green → run an **adversarial-review Workflow** (caught real bugs in L2/L3/L4; L5 was clean) → fix → `make deploy`
> → commit + push. Honor the three load-bearing facts below (the `claude` CLI is present; `gate.tools` is a
> hold-list not an allow-list; secrets are env-var NAMES only) and the L1–L5 KEEP-IN-SYNC invariants in context.md.

Built by adversarially mining top AI orchestration/governance apps (12 domains each: finders → dedup →
FOR/AGAINST judge → skeptic verify) for features worth ADAPTing onto Shepherd's primitives. CANDIDATES for
one consolidated "big push" — more projects get mined first, then we build. Not started; off-by-default like
everything that automates. Per-project reports (full FOR/AGAINST/ruling/mapping for every candidate) live in
`docs/feature-mining/`.

- **LiteLLM** (2026-06-14): 236 features → 143 candidates → 46 ADAPT / 97 DON'T-ADD / 0 verbatim-fit (it's a
  proxy; Shepherd isn't). Seeded **L1/L2/L3** below. Report: [docs/feature-mining/litellm.md](docs/feature-mining/litellm.md).
- **crewAI** (2026-06-14): 203 → 82 → 36 ADAPT / 46 DON'T-ADD / 0 verbatim-fit (it's an in-process agent
  *executor*; Shepherd watches/steers/spawns, runs nothing). **33 of 36 ADAPT independently corroborated
  L1/L2/L3** (an independent framework converging on the same design) and enriched them with the
  *crewAI-corroborated* sub-bullets below; the 3 genuinely-new items became **L4**. Report:
  [docs/feature-mining/crewai.md](docs/feature-mining/crewai.md).
- **OpenHands** (2026-06-14): 163 → 91 → 53 ADAPT / 38 DON'T-ADD / 0 verbatim-fit (an in-process agent
  *executor* AND a multi-user web server — double mismatch). **Third independent corroboration of L1** (32
  ADAPT reinforced it). Added **L5** (richer watch-console observability/detail) + **L6** (event-callback rule
  engine) and the *OpenHands-corroborated* enrichments below. Report:
  [docs/feature-mining/openhands.md](docs/feature-mining/openhands.md).
- **cline** (2026-06-14): 177 → 90 → 67 ADAPT / 22 DON'T-ADD / 0 verbatim-fit (VS Code/CLI coding-agent
  platform; executor + partial hub mismatch). **65/67 ADAPT reinforce L1–L6** (L1×28, L5×15, L4×10). New:
  scheduling (→ **L7**) + OS-native notifications. Report: [docs/feature-mining/cline.md](docs/feature-mining/cline.md).
- **AutoGPT** (2026-06-14): 175 → 84 → 59 ADAPT / 25 DON'T-ADD / 0 verbatim-fit (visual agent-builder platform;
  graph/block executor + multi-user web double mismatch). **58/59 ADAPT reinforce L1–L6** (L1×28, L6×8). New:
  scheduling (→ **L7**) + loop-detection watchdog. Report: [docs/feature-mining/autogpt.md](docs/feature-mining/autogpt.md).

> **Cross-source signal:** L1 (Agent Profiles) has now been independently reaffirmed by all **5** mined sources;
> L2–L6 recur across them. The backlog shape is well-validated — the cline+AutoGPT batch added **L7** (scheduling)
> and folded *cline/AutoGPT-corroborated* enrichments into L1/L4/L5; the rest re-confirmed (detail in the reports).

**Build sequence (decided 2026-06-14):** Phase 0 Foundation (spawn-flag emission + config-by-ref resolver +
pre-flight validator + `FX.listSkills` + `cc-agents.json`/`cc-mcp.json` loaders) → **Phase 2 L1 Agent Profiles**
(the headline — building Phase 0 + L1 FIRST per user pick) → Phase 1 L5 quick wins → Phase 3 L2 + L1 polish →
Phase 4 L4 + L7 → Phase 5 L6 + L5 remainder. Each increment keeps `make test` green and ships via `make deploy`.
**L4 routing source DECIDED:** the affinity tag comes from a **queue-line `@role:` prefix** (parsed in
`queueSplitLines`), not session-group or provider — explicit, per-task, no new UI.

**Three load-bearing facts the build must honor** (verified during mining 2026-06-14):
- **The `claude` CLI is present** at `~/.local/bin/claude` (v2.1.175) — corrects the old "no claude CLI on
  this Mac" note. It exposes `--mcp-config <files>` / `--strict-mcp-config`, `--agent` / `--agents`,
  `--plugin-dir`, `--append-system-prompt`, `--add-dir`, and the `claude plugin` / `claude mcp add`
  subcommands, so launch-flag wiring is feasible. BUT native Claude Code already reads project `.mcp.json`
  and keeps its own plugin/MCP registry — Shepherd stays a thin fleet-convenience layer (emit flags/files);
  it does NOT reimplement MCP/skills/plugins. Skills live at `~/.claude/skills/<name>/SKILL.md`
  (frontmatter `name`/`display_title`/`description`).
- **`gate.tools` is a HOLD-FOR-APPROVAL / escalation list, NOT a capability allow-list.** Tools *not* in it
  run freely (`cc-approve.sh` `*) exit 0`). So a "read-only agent" is built by **autoDeny** of the mutating
  set (`Bash Write Edit MultiEdit NotebookEdit` = `DEFAULT_GATE_TOOLS`), never by adding them to `gate.tools`.
  Any mapping phrased as "seed the allow-list to grant a tool" is backwards — fix it at design time.
- **Secrets never stored.** Reuse the `providerEnv` pattern ([cc-core.lua](cc-core.lua) ~2710/2714): records
  store the env-var *NAME* (`authTokenEnv`), expanded by the spawned login shell via `loginShellWrap`. New
  registries (`cc-agents.json`, `cc-mcp.json`) are operator-data JSON like `cc-presets.json`, living OUTSIDE
  the Settings round-trip. Spawn side-effects gate behind `spawn.live` (default dry-run). VS Code/Cursor
  spawn is keystroke-only → flag injection is best-effort; reliable on Kitty/Terminal (same caveat as
  provider-env spawns).

### L1 — Agent Profiles registry (saved agents + skills + MCP, "spawn from a saved agent") — effort **L**
> ✅ **CORE SHIPPED 2026-06-14** (see CHANGELOG): Phase 0 foundation + spawn-from-agent + Save-as-agent + a
> read-only skills card + agent/MCP CRUD, all in `cc-agents.json`/`cc-mcp.json`.
> **Editor ✅ SHIPPED 2026-06-14 (deferred-polish ③):** a ✦ Agents editor (☰ drawer + a "Manage agents…" button in
> the New-session modal) — full-field authoring (name/category/folder/provider/model/permMode/role/goal/backstory/
> seedPrompt/policyBundle) + **skills/MCP attach as toggle chips** (rendered as the union of available+selected so
> nothing's silently dropped) + **knowledge/plugin/folderGlobs editable lists** + favorite★/fork/archive/sort/
> show-archived/delete/Spawn + an **MCP-registry surface** (cc-mcp.json CRUD). New pure `core.agentSetFlag`
> (preserves all fields). No edit data-loss: all 26 AGENT_FIELDS covered by form∪carry-forward; rename removes the
> old record first + reads prior by old name. Adversarial review: 1 fixed (MCP form pre-validates transport before
> the optimistic reset). **Still deferred:** an in-editor `modelByMode`/`requiredEnv` editor (carried forward on
> edit; hand-edited today), an agent-folders tree, recently-deleted/restore.
*Source: ADAPT items 1–9 (Provider-native Agents CRUD, Skills registry, MCP server registry, Named toolsets,
MCP access groups, Public MCP registry/discovery, per-server MCP health, Access groups, Plugin marketplace).
The user's #1 stated interest — "pre-configured agents we hand work off to, saved into a directory; same with
skills and MCPs."* Nine LiteLLM features converge into ONE: extend the spawn-preset primitive into a saved
**agent profile** + a **"Spawn from agent"** action.

- **Registry (preset++ / `cc-agents.json`):** pure cc-core CRUD `agentList/agentPush/agentRemove` mirroring
  `presetPush/presetList` ([cc-core.lua](cc-core.lua) ~3640–3722; validate + cap + replace-in-place, zero
  `hs.*`). Profile = `{name, folder, provider, model, permMode, seedPrompt, policyBundle (see L2), skills[],
  mcpServers[], plugins[], versions[]?}` — a superset of the existing preset, not a parallel system. Optional
  local-only `versions[]` (reuse the session-lineage mindset; no remote object).
- **Spawn from agent:** new action via the New Session modal → `spawnSpec` ([cc-core.lua:3061](cc-core.lua#L3061)),
  seeds the session queue with `seedPrompt`, threads selections into `spawnFlags`
  ([cc-core.lua:3001](cc-core.lua#L3001)) as `--mcp-config`/`--strict-mcp-config`, `--append-system-prompt`
  (skills/system), `--agent`/`--plugin-dir`, and applies the profile's policy bundle.
- **MCP server registry (`cc-mcp.json`):** named records `{id, label, transport(stdio|sse|http), command,
  args, url, allowedTools, authTokenEnv}`, modeled on the `providers` registry. Pure validator +
  mcp-config-file builder. MCP picker in the modal; attachable to a profile.
- **Skills (read-mostly):** pure enumerator over `~/.claude/skills/*/SKILL.md` parsing frontmatter → card view
  via a new `FX.listSkills` file read. Authoring stays "drop a folder in ~/.claude/skills" — no DB.
- **Plugins:** optional per-profile list; apply via `claude plugin install` on spawn (gated by `spawn.live`),
  degrade gracefully if the CLI/subcommand is absent.
- **MCP inventory badge (narrowed from "health check"):** `~/.claude.json` holds only config (no runtime
  status), so true health is NOT locally sourceable. Build a pure derivation reading `~/.claude.json` +
  project `.mcp.json` → per-session configured servers + enabled/disabled state; best-effort last-error from
  `~/.claude/debug/*.txt` ONLY when present, else "unknown". Off-by-default tile/detail badge, sibling to
  `stale`/`hung`.
- **DROP:** all Prisma tables, multi-tenant access-groups/teams/keys + assignment/propagation, make-public,
  A2A agent cards, per-agent billing, the `marketplace.json`/`/discover`/`/registry.json` endpoints +
  submission/approve/reject workflow, the `/v1/skills` proxy + zip/Bytes storage + SkillVersion + ownership,
  server-side health pings/endpoints, live ClientSessions + namespacing/strip-on-call routing, stored auth
  values.
- **crewAI-corroborated enrichments** (independent second source; fold into the profile schema):
  - **Structured identity:** split `seedPrompt` into `{role, goal, backstory}` subfields rendered into the
    `--append-system-prompt` persona block; show role/goal on the profile card for scannability. Drop crewAI's
    md5 identity/cache key (no in-process cache to hash).
  - **`knowledge[]`** = validated local paths → `--add-dir` at spawn (+ small inline refs via
    `--append-system-prompt`); fleet-default vs per-profile scope. Claude Code does the retrieval — NO
    embedder/vector store/chunking.
  - **`requiredEnv: [{name, description, required, default}]`** on profiles + `cc-mcp.json` records; pure
    `core.missingEnv(profile, shellEnv)` checks NAME-presence only (never values, via `loginShellWrap`) →
    New-Session preflight warning + optional tile badge.
  - **Pre-flight validation/lint:** a pure validator family (sibling to `presetList`/`templateList`
    [cc-core.lua](cc-core.lua) ~3590–3722) returns aggregated structured errors (unknown-field,
    missing-required, bad cross-ref: `policyBundle`/`mcpServers[]`/`skills[]` must resolve) and **refuses
    spawn/attach with the full list before emitting any flag**. Per-registry known-fields allowlist so adding
    optional fields (e.g. `versions[]`) doesn't trip it. Shared with L2 attach + L3 render-refuse.
  - **Config-by-reference resolver:** the profile stores NAMES; ONE pure resolver dereferences
    provider/policyBundle/skills[]/mcpServers[]/plugins[] against the providers list, L2 bundles, `cc-mcp.json`,
    `~/.claude/skills` at "Spawn from agent", then `spawnFlags` emits concrete flags. This IS L2's resolver,
    generalized — single-source it (extends `providerById`:2632 / `resolveGateTools`:2537).
  - **Batch fan-out spawn:** pick profile + parameterized template (L3) + paste N input rows → render per row →
    fan out one session per row with its queue seeded; gated by `spawn.live` (dry-run default); `by:"batch"`
    ledger event; aggregate per-session usage into insights. Pure row-split/render in cc-core; effects via `fx`.
  - **Safe-path hardening:** skill/MCP/plugin name resolvers validate against `[A-Za-z0-9._-]` and reject any
    name resolving outside its root BEFORE `FX` writes the config/flag (reuse existing sanitization ~1950/2451/2796).
  - **Per-agent `contextDir`/`memoryFile`** (e.g. `~/.claude/agents/<name>/CONTEXT.md`) → `--add-dir` /
    `--append-system-prompt` at spawn. Static, human/Claude-edited — NO embeddings, NO recall, NO in-loop mutation.
- **OpenHands-corroborated enrichments** (third source; its skills/profile layer matched L1 32×):
  - **Dual-shape skills enumerator:** `FX.listSkills` globs BOTH flat `skills/*.md` (microagent shape) AND
    directory `SKILL.md` + `references/`, skips `README.md`, falls back to the file stem for name, derives a
    `/<name>` command; surface `shape` (flat|agentskills) + `/<name>` + description on the card. (Earlier spec
    assumed only `SKILL.md`.)
  - **Slash-command autocomplete** in the spawn/nudge input: reuse the existing `#n-suggest` keyboard-nav
    (`onPathKey` [claude-dashboard.lua:4083](claude-dashboard.lua#L4083)) + `#tpl-menu` render (~3462) over a
    `/`-typeahead of skill names + Shepherd-known commands (`/model`, `/effort`, clear, compact) — never invent
    an executor-side command list.
  - **Per-session "skills loaded" inspector:** detail-panel view of the effective
    skills[]/mcpServers[]/knowledge[] resolved from the profile the session was spawned from, each row
    expandable to its `SKILL.md` frontmatter — stated honestly as "what Shepherd attached at spawn" with an
    "(human-started; not visible to Shepherd)" note for un-spawned sessions. Optional
    `transcriptSkillActivations` → off-by-default `skill_triggered` ledger event via the existing timeline.
  - **Per-profile skill toggle rows:** the skills card renders each skill as a toggle that adds/removes it from
    the editing profile's `skills[]` (positive selection). Any "hide from picker" flag lives in operator JSON,
    labeled picker-scope only (can't disable native auto-load on a live session).
  - **Schema-drift / fail-safe loading:** generalize `presetList`'s per-entry skip (~3658) to
    `agentList`/`mcpList` — validate each record, **keep the valid, drop only the bad**, and RETURN the dropped
    count+names so the FX glue raises a one-time alert + `by:"config-drift"` ledger event (replaces today's
    silent drop). Whole-file decode stays pcall-guarded.
  - **Authoring front-end (agent-builder / add_agent / onboarding / /remember):** L1's missing CREATE side —
    "Save as agent" pre-seeds defaults (version, structured `{role,goal,backstory}`, empty `skills[]`) + runs
    the pre-flight validator; a curated set of L3 "author-a-spec"/onboarding prompts (the *session* runs the
    interview and writes the `cc-agents.json` profile + a plan/CONTEXT.md); a WRITE-mode `/remember`
    prompt-builder (sibling to `auditReviewPrompt`) that renders the recent ledger/transcript slice and asks
    the session to list durable items **NUMBERED for human confirmation** before appending to the agent's
    `memoryFile`. Authoring done by the session, not Shepherd; off-by-default, dry-run behind `spawn.live`.
- **cline + AutoGPT-corroborated enrichments** (L1 reaffirmed a 4th & 5th time — registry organization + lifecycle):
  - **Registry organization:** per-profile organizing `category` (Phase 1: mirror the session `group` field +
    `filterTiles` chips, [cc-core.lua:341](cc-core.lua#L341); Phase 2 only if it grows: a `cc-agent-folders.json`
    tree + a pure circular-move guard), a `favorite` bool (pure `agentSetFavorite`, favorites-first sort + chip),
    `hidden`/`archived` flags (picker filters them by default — the "hide from picker" flag L1 reserved), a
    `deleted` tombstone + "recently deleted/restore", and a bounded `agentSort` (name/created/updated/lastUsed;
    stamp `lastSpawnedAt` on spawn). **Name the organizing field distinctly from `folder` (launch dir) and from
    session GROUPS** — avoid the three-way collision.
  - **Fork/duplicate with lineage:** pure `agentFork(state, name)` (sibling to `presetPush`) deep-copies →
    unique "<name> (copy)", carries all fields + the L2 policyBundle by value, stamps `forkedFromName/Version`;
    "Duplicate" action + a "forked from" provenance line. Secret-strip is a no-op (only env-var NAMES stored).
  - **Ephemeral git worktree per spawn** `[M]` — spawn-time option: `fx.gitWorktree(repo, key)` runs
    `git worktree add --detach ~/.claude/cc-worktrees/<projectKey>-<n>` (pure `worktreePathFor`/`worktreeAddCmd`,
    deadlock-safe redirect); spawnSpec uses it as cwd + `--add-dir <mainRepo>`; ⑂ tile badge; right-click "remove
    worktree" + startup orphan sweep. **Solves the same-dir collision** (true parallel work on one repo) instead
    of just warning. Off by default; skip the symlinked-node_modules half (executor-only).
  - **Per-mode model binding** `[S]` — extend the profile `model` into an optional per-mode map
    (`{plan, default, acceptEdits}`), default to flat `model`; resolve via the config-by-ref resolver; at
    mode-switch, if the bound model is the SAME backend emit `/model`, else show a "needs a fresh session" hint
    (don't silently fail). Spawn picks the model bound to the initial `permMode`.
  - **Conditional folder-scoped auto-attach** `[S]` — optional `folderGlobs[]` on a profile; pure
    `profilesForFolder(profiles, chosenDir)` pre-selects matching profiles in the New-Session modal so their
    skills[]/knowledge[]/seedPrompt auto-fill (`[]` = never auto-attach; a bad glob fails open). Expose the
    matcher as an L6 scope predicate too. Spawn-time pre-fill only — no runtime engine.
- **Build order:** registry + spawn-from-agent → skills card → MCP registry+attach → plugins → inventory badge.

### L2 — Named policy / guardrail bundles + attachments — effort **M**
> ✅ **SHIPPED 2026-06-14** (see CHANGELOG): `policies.bundles` + `policies.attachments`, resolved per session
> (override > attachment > fleet) into a `cc-policy/<key>` file the gate reads (authoritative + opt-in), with a
> detail-panel Policy dropdown, an orphan sweep, atomic writes, and SessionEnd cleanup. Built with an adversarial
> review pass.
> **Editor ✅ SHIPPED 2026-06-14 (deferred-polish ④):** a 🛡 Policy bundles editor (☰ drawer) — bundle authoring
> (autoDeny/autoAllow/gateTools/lockedPermMode/toolLimits/autopilot/disableGlobal + starter copy) + ordered
> attachment CRUD (▲▼ reorder, match globs → bundle). New pure cc-core: `validate/normPolicyBundle`,
> `policySet/RemoveBundle`, `validate/normAttachment`, `policyAdd/Set/Remove/MoveAttachment` — each returns a new
> `policies` subtree (patterns + other config keys ride through). Writes into cc-config.json: change-gated,
> malformed-config-safe (never clobbers an unparseable file), non-aliasing. Adversarial review: 0 findings.
> **Still deferred:** bundle `gateTools` auto-apply at spawn, `toolLimits` shell enforcement (soft/ledger
> indicator today), free-text deny-reason enrichment.
*Source: ADAPT items 11, 12, 14, 15 (key-scoped access lists + key_type, per-key policy attachment + enforced
params + disable-global, guardrail lifecycle CRUD + timing + transparency, named/scoped versioned bundles).*
Today `policies.patterns` is a single flat anonymous `{autoAllow[], autoDeny[]}` + a per-session `gate.tools`
override. Turn it into named, attachable bundles.

- **Named bundles:** `policies.bundles = { name -> {autoAllow[], autoDeny[], gateTools, autopilot,
  lockedPermMode?} }`, optionally per-rule `{name, action: deny|allow|flag, tier: pre|observe, enabled}`.
- **Attachments:** `policies.attachments = [{ match: {project|group|providerId|sessionKey (wildcards ok)},
  bundle }]` — matched against the project/group/provider context the dashboard already tracks per tile.
- **Resolver:** ONE new pure cc-core fn mirroring `resolveGateTools` precedence — **session override >
  attached bundle > fleet default**. The ordered pipeline in `cc-approve.sh` (autoDeny→autopilot→autoAllow→
  approveRepeats, ~166–196) stays put; it just reads the resolved bundle instead of the flat lists. **Honor
  the [cc-core.lua](cc-core.lua) ↔ [cc-approve.sh](cc-approve.sh) KEEP-IN-SYNC contract** (as the gate-tools
  override already does).
- **Per-session opt-out of fleet policy as a unit** (the `disable_global_guardrails` mirror) — a flag the
  session/profile can carry.
- **`flag/observe` tier:** no blocking path — rides the existing ledger + risk score as an indicator only.
- **Transparency:** thread the fired bundle/rule name into the `ledger_decision` `by`/`pattern`
  ([cc-approve.sh](cc-approve.sh) ~145–164); `gateDecisionSummary` ([cc-core.lua:752](cc-core.lua#L752))
  already renders "which fired".
- **`key_type=read_only` flavor + starter bundles:** ship 2–3 named bundles — *read-only* (autoDeny the
  `DEFAULT_GATE_TOOLS` mutating set — **mind the gate semantics above**), *no-Bash*, *MCP-only*. Ties to L1
  (a saved agent profile carries a default bundle).
- **enforced/locked fields** (force permMode / a gate list the session can't loosen / force provider) = the
  weakest piece; **defer** unless needed — a single-user console rarely needs to defend a preset against itself.
- **Keep ALL opt-in** — do NOT port LiteLLM's `default_on` (violates the off-by-default scope limit).
- **DROP:** request-body content filtering / PII / prompt-injection scanning, request-field validation, MASK,
  during_call/modify_response (Shepherd sees no response bodies), HTTP CRUD endpoints, DB table, the
  draft→published→prod version state machine (git already versions cc-config.json), the compliance-template
  catalog, and the teams/keys/models/tags attachment axes.
- **crewAI-corroborated enrichments:**
  - **Deny reason (human-in-the-loop):** free-text reason on the panel deny → `handleAction` deny branch
    ([cc-core.lua](cc-core.lua):133) → `fx.writeDecision(key,"deny",reason)` → `cc-approve.sh` `emit_deny`
    already wires `permissionDecisionReason`. Ledger it so `gateDecisionSummary` (cc-core.lua:752) renders
    "⛔ denied — <reason>". Folds into L2's transparency work.
  - **Per-task tool restriction at spawn:** a saved agent (L1) / template (L3) carries a bundle applied as the
    new session's scope at spawn — `autoDeny` the mutating set (NOT an allow-list, per the gate-semantics
    caveat above), optionally a `--disallowed-tools` flag for hard launch scope. The unit carrying tools is the
    saved agent/template, not a per-queue-item field.
  - **Per-tool usage limit:** bundle field `toolLimits = {Bash=5,…}`; pure cc-core counts a session's
    invocations from the ledger (reuse the `tool_request` tally in `riskScore` ~1393); at/over ceiling →
    `autoDeny` `by='usage-limit'` + reason; "X/N" tile badge; per-session reset. **Soft** (next-request) limit —
    Claude Code owns true enforcement. Off by default; attach via bundle, never `default_on`.
  - **Per-tool + per-agent-role scoping & log-only tier** = exactly L2's per-rule `action: deny|allow|flag` +
    `tier: pre|observe`. DROP after-call output rewrite/redact and before/after-LLM interception (no payloads in
    Shepherd's hooks — already on L2's DROP list).
  - **Fingerprint/identity seam:** the per-component policy attach point IS L2's bundles + attachments +
    resolver; "auditable identity" is already `projectKey` + `session_id` + ledger stamping — NO Fingerprint
    object. Drop credentials/impersonation/delegation-token (no-secrets/no-auth scope).

### L3 — Parameterized + versioned prompt templates with a definition source — effort **M**
> ✅ **SHIPPED 2026-06-14** (see CHANGELOG): `cc-templates.json` records grew from flat `{name, text}` into
> structured/versioned, all back-compat. cc-core (clock-pure): `validateTemplate`/`templateLoad`/`templateList`
> (fail-safe load), `composeTemplate`, `templateVars`/`renderTemplate` (`{{name}}`/`{{name?}}` + built-ins
> date/today/now/`{{prev_output}}`; required-var refusal, or `keepMissing` for autonomous feed),
> `effectiveVars`/`fillDefaults`, `templatePushVersioned`/`templateVersions`/`templateRevert` (duplicate-on-edit,
> change detector signs on the composed body), `parsePromptFile`/`promptImport`. Wired: inline var form in the
> Tpl menu (render-before-insert, no-auto-send), a New-Session modal **Templates** picker (render-before-spawn),
> render-before-feed at all three queue sites, versioned saves, and `⤓ Import from prompts folder` (`*.prompt`/
> `*.md` from `templates.sourceDir`, default `~/.claude/cc-prompts`). cc-core is the authoritative renderer (no JS
> render twin). Two adversarial-review passes (3 real fixed; then 0). Suite 1425 core + 293 ui + 183 bash.
> **Editor ✅ SHIPPED 2026-06-14 (deferred-polish ②):** a 📝 Templates editor (☰ drawer + Tpl-menu "Manage…")
> with structured authoring (description + expected_output toggle vs raw text, live var readout), a
> version-history view with non-destructive **revert**, in-panel rename (new pure `core.templateRename` preserves
> history; vars-schema carried forward on edit), name-collision confirm, XSS-safe textContent rendering.
> Adversarial review: 0 findings. **Still deferred:** an in-editor vars-schema editor (labels/defaults — derived
> from `{{var}}` or hand-edited today).
*Source: ADAPT items 42, 43, 44 (dotprompt file definitions + input-schema, prompt-management CRUD +
versioning + playground, remote/git prompt sources). This is the local "agent-definition directory" that
feeds L1.* `cc-templates.json` stores verbatim task text today (no vars, no schema; `templatePush`
overwrites in place at [cc-core.lua:3613](cc-core.lua#L3613)). Enrich it.

- **Variable interpolation (pure cc-core):** `templateVars(text)` → ordered `{{name}}` / `{{name?}}`
  placeholders with required/optional flags; `renderTemplate(text, vars)` → `(rendered, missingRequired)`
  that **refuses to render on a missing required var**. Persist an optional vars-schema alongside `name/text`.
- **Render-before-spawn:** the New Session modal + queue prompt for required vars before enabling spawn. The
  "test/playground" = render with sample vars + paste into a session via the existing **no-auto-send**
  `templateInsert` path ([claude-dashboard.lua:3480](claude-dashboard.lua#L3480)) — human submits.
- **Versioning-lite:** `templatePushVersioned` (duplicate-on-edit / `v(n+1)`, don't overwrite) + versions/revert view.
- **Definition SOURCE (the "saved into a directory" the user asked for):** a configurable local dir (e.g.
  `~/.claude/agents` or user-set) scanned with the existing accelerators (`folderScanShellCommand` +
  `resolveBin` rg/fd, grep/find fallback) → `{name, prompt, systemPrompt, presetFields}` records feeding the
  spawn modal + `spawnInner` `[prompt]` arg + `spawnFlags` (`--append-system-prompt`/`--add-dir`). **Strictly
  local-disk** — no network client, no token storage.
- **`.prompt` → JSON import:** a new `FX` reader feeding `templatePush` — no YAML parser, no Jinja2 (keep it
  pure cc-core).
- **DROP:** environments/promotion (dev/staging/prod), `metadata['prompts']` allow-list, RBAC/admin checks,
  the SQL PromptRepository, the streamed `/prompts/test` completion call, `merge_messages` + sampling-param
  overrides, and the credentialed git/SaaS network clients (Bitbucket/GitLab/Langfuse/Phoenix tokens).
- **crewAI-corroborated enrichments:**
  - **Built-in interpolation vars** in `renderTemplate`/`templateVars`: `{{date}}`/`{{today}}`/`{{now}}` (from
    `os.date` at render-time) and **`{{prev_output}}`** single-hop context-chaining — on the done edge
    ([cc-core.lua](cc-core.lua) ~2092) capture `transcriptSnippet` of the finishing session into an in-memory
    per-project slot (not persisted, like `routePending`); render into the next routed task before paste.
    Opt-in "carry output forward" flag (rides the queue file like `queueSetRouted`), human-visible before paste.
  - **Structured task record:** enrich `cc-templates.json` from `{name, text}` to `{name, description,
    expected_output}` (`text` = back-compat fallback); a pure composer near `templatePush` (~3604–3638) builds
    `description + "Expected output:" + expected_output`, interpolated with `{{var}}`. Drop the md5 key and any
    output-validation (Shepherd never reads results back).
  - **`attachments[] = [{name, path}]`** on templates/profiles: derive unique parent dirs → `--add-dir`; expand
    `{{name}}` → resolved path in the prompt; attachment picker reuses the folder browser (`FX.listDirs`).
    Path reference, not byte injection (Claude Code owns multimodal).
  - **Input-schema collection ("chat with a crew" pattern):** `templateVars` declares required/optional vars;
    the New-Session modal renders one field per var, disables Spawn/Feed until required are filled, then
    interpolates → `spawnSpec` `[prompt]` / `--append-system-prompt`. Human submits (no LLM). L1 profiles supply
    the schema source. The conversational/continue half is already the live nudge textarea + per-session queue.

- **OpenHands-corroborated enrichments:**
  - **Suggested-tasks "Work feed" overlay:** opt-in, `gh`-backed (detect→use→degrade) per-repo actionable
    items — `gh issue list --assignee @me`, `gh pr list --author @me`, `gh pr checks` (failing), mergeable
    state, unresolved review threads — tagged by a pure `core.classifyWorkItems`; repos = the git roots
    Shepherd already discovers (`FX.gitRoot`); gh uses the user's own login (NO token store). One-click "Fix
    this" renders an L3 template (`{{repo}}/{{issue}}/{{pr_number}}`) → inject into a selected session (the
    Improve/`pasteIntoWindow` path) or spawn-from-L1-agent + enqueue (L4). Slow poll (≥60s)/on-demand, off by
    default; ledger a `work_feed_dispatch` event.
  - **Trigger → rendered seed prompt:** model each "resolver" convention as an L3 template
    `{name, description, expected_output, vars}` with an "ask before pushing" line baked in; bundle the
    per-repo convention into an L1 agent profile (+ a read-only/ask-before-push L2 bundle). DROP the webhook
    server, signature verification, OAuth, and the branch/commit/push executor — the spawned session owns that.

### L4 — Declarative routing & orchestration (NEW from crewAI) — effort **M**; unblocks the deferred 4c-E follow-ups
> ✅ **SHIPPED 2026-06-14** (the non-UX-gated parts; see CHANGELOG): conditional routing by a queue-line `@role:`
> prefix (matches a member's GROUP — `core.taskRoute`/`memberRole`/`routePick` role filter); process modes
> (`core.queueRouteMode`/`queueSetMode` + `projectBusy`; *distribute* default / *sequential* one-at-a-time, a
> detail-panel **seq** toggle); join barriers (`core.taskBarrier` `@all:`/`@any:` + `routeBarrierMet`, composes
> with a role); per-task timing (`core.stepTaskDone` → `task_done` ledger at the 3 feed sites, rolled into
> `fleetStandup`/Shift report). `renderFeed` strips the routing scaffolding before typing. Two adversarial-review
> passes caught + fixed the `applyGroups`-before-dispatcher ordering bug and the `taskStart` GC leak (now
> abandoned-on-stale + reaped-on-vanish). Suite 1481 core + 308 ui + 183 bash.
> **Deferred (still UX-gated — need a design call first):** the routing **topology view** (`plot`), role-addressed
> **delegation/handoff**, **idle-as-routing-target**, and **auto-spawn on starvation**. Also deferred: hierarchical
> "manager" mode, the OpenHands pending-before-ready queue + parent/delegation lineage + per-session diff view, and
> the cline dependency-chains / priority+concurrency-cap / broadcast-mailbox enrichments below.
*Source: crewAI ADAPT items — Flow `@start`/`@listen`/`@router`, `and_`/`or_` join barriers, `plot()`,
sequential/hierarchical process modes, delegation/handoff, per-task timing. The 3 genuinely-new items + the
routing-flavored reinforcements.* crewAI's Flow engine maps onto Shepherd's **shipped Project Routing v1**
dispatcher (`routeTask`/`routePick`/`sessionFree`/`routePendingDone`, [cc-core.lua](cc-core.lua) ~1981–2084).
This is the concrete shape for the **4c-E follow-ups deferred above** (task→session affinity/tags). **DROP all
decorators / in-process method execution / return-value event bus / in-memory flow state** — Shepherd has no
firing engine; the level-triggered dispatcher + the ledger ARE the engine.

- **Conditional routing (route labels / `@router`):** give a queued task an optional **route label** — this
  answers the deferred "where does the tag come from": a queue-line prefix like `@review: <task>` (parsed in
  `queueSplitLines` ~1921) or inherited from a session group (`applyGroups`). A pure label→target resolver
  beside `routePick` filters members by label before the longest-free tiebreak. Keep `shouldFeed` (~1975) as
  the `@listen` trigger, `routePendingDone` (~2007) as the in-flight guard. Behind the existing
  `queue.routing.enabled` + `routing:true` double opt-in; ledger `by:"router"`.
- **Process modes (sequential vs distribute):** `queueRouteMode(q)` → `"distribute"` (today's `routePick`,
  default) | `"sequential"` (pin to one chosen member, feed in declared order, hold the rest). `routeTask`/
  `routePick` honor the mode; pure + unit-tested. (Hierarchical "manager" = designate which profile the
  coordinator session spawns from — NO in-process manager/manager_llm.)
- **Join barriers (`and_`/`or_`):** pure `core.routeBarrierMet(members, opts)` → true only when all (or any)
  members of the armed project/group are `done` (same stale/remote/error exclusions as `sessionFree`); gate a
  designated "join" task on it before `routePick`. Flat AND/OR-over-done only — no nested condition tree.
- **Delegation / role-addressed handoff:** extend the dispatcher from done-only/by-project toward AGENT/ROLE-
  addressed targets (the deferred affinity item). Addressable identity from **L1** (`cc-agents.json` role/name);
  handoff payload from **L3** (rendered `{{var}}` task). "Delegate" = render an L3 task + enqueue onto the named
  L1 agent's queue, delivered by the router (ledger `by:"router"`/delegation). "Ask coworker" = the existing
  cross-session nudge (`handleAction "nudge"`) at the target — fire-and-forget. Opt-in, dry-run-able, ledgered.
- **Routing topology view (`plot`, reshaped):** NOT an HTML export — a read-only in-panel topology of
  routing/queue state. Pure cc-core aggregation (sibling to `fleetStats` ~943 / `lineageByProject` ~1061) walks
  routing state + `by:"router"`/`queueStarved`/`starvedSince` ledger events into nodes/edges (project
  group-nodes, session member-nodes, feed edges, queue-depth/starvation annotations); render in the webview JS
  twin (insights/sparkline/timeline), gated to appear only while routing/ledger on.
- **Per-task timing/outcome counters:** stamp task-start ts on dispatch (~2040–2098); on done/idle compute
  `execution_duration` (`since`/`updated` + `fmtDuration` ~902); emit a `task_done` ledger event `{projectKey,
  sessionId, role, durationS, toolRequests, approvals, escalations, continues, routerHandoffs}`; roll into
  `fleetStandup` (~1137) / the Shift tab. Feeds L3 per-template analytics ("this template averages 4m, 2
  denials"). NO in-process output object.
- **Still UX-gated:** L4 realizes the 4c-E follow-ups deferred pending a design call (idle-as-target, the
  affinity tag SOURCE, auto-spawn on starvation). **Decide the route-label/affinity source first** — it's the
  load-bearing choice the rest hangs off.
- **OpenHands-corroborated enrichments:**
  - **Pending-message queue (queue-before-ready):** let an armed project's projectKey-keyed queue hold ordered
    tasks even with ZERO live members; `routeTask`/`routePick` deliver in created-at order to the first session
    that reaches `done` for that folder (the no-session-yet case `routePick` can't reach today). Pairs with L1
    spawn-seeding so "spawn from agent" pre-stages a multi-message queue the new session drains on first ready.
    projectKey keying removes any placeholder-id/rekey need.
  - **Sub-conversations = parent/delegation lineage:** when a session spawns/delegates another (the L4 Delegate
    path), stamp the route/spawn ledger event with `parent_session`/`spawnedBy`; show parent→child edges in the
    routing topology view; reuse session groups + collapse for "collapse children under parent." Config
    inheritance on spawn is already `respawnSpec` + L1's config-by-ref resolver — don't reimplement. **DROP
    cascade-delete** (never auto-kill a child the human is steering). Keep "lineage" for the existing
    respawn/clear read; call the new edge "parent/delegation."
  - **Per-session git changes/diff view:** a 'Changes' overlay tab — `FX.gitChanges(cwd)` runs
    `git -C <q> status --porcelain=v1 -z` + `FX.gitDiff` per file; pure `core.parseGitStatus` (A/D/M/R/??) is
    unit-tested; render status icons + collapsible unified-diff `<pre>` (not Monaco), lazy on open + manual
    refresh, never on the 1s loop. Feeds a per-session "files touched" count into the shift report/lineage —
    the deliberately-omitted "what changed" signal, without claiming outcomes. (Shares the tab framework with L5.)

- **cline-corroborated enrichments:**
  - **Task dependency chains + auto-start next ready** `[M]` — optional `dependsOn[]` on the queue task record
    (rides the projectKey-keyed queue file like `queueSetRouted`, not a new store); gate a dependent task in
    `routeTask` via `routeBarrierMet` over its deps' done-state; the shipped `shouldFeed` + level-triggered
    done-edge already auto-starts the next ready task. A panel "link these cards" affordance writes `dependsOn[]`
    (+ optional route label), rendered alongside the routing topology view. Behind the existing double opt-in.
  - **Queue priority + concurrency cap** `[M]` — optional per-task `priority` consulted by `routePick` when
    choosing which queued task to feed first (dispatcher loop ~5623); a fleet `queue.routing.maxConcurrent` the
    post-loop dispatcher honors by counting active sessions before feeding. Reuse `isHung` for stuck-detection.
    DROP retry/lease/heartbeat fields (respawn + Auto-Continue budgets already cover Shepherd's only retry).
  - **Broadcast nudge / inter-session mailbox** `[S]` — "send to one agent" = role-addressed handoff (resolve an
    L1 name → its queue via `queuePush`); "send to a not-yet-live session" = the pending-message queue;
    "broadcast to a group" = the existing bulk nudge (`selectActionable` + `BULK_RULES.nudge` + staggered
    dispatcher) scoped to a session group. Optional subject prefix on the queue line. DROP the read/unread
    mailbox state machine + the agent-side team_* tools.

### L5 — Richer session observability & detail (NEW from OpenHands) — effort **M** (mostly S sub-items)
> ✅ **PARTIALLY SHIPPED 2026-06-14** (the high-value pure-core derivations; see CHANGELOG): error-reason
> taxonomy (`core.classifyError` → `transcriptError.reason` + tile cause badge + fresh-edge `error` ledger);
> plan/TODO on the detail panel (`core.planFromTranscript`, loaded on selection); auto-title (`core.deriveAutoTitle`,
> `autoTitle.enabled` off, cached in `cc-autotitles.json`); loop-detection watchdog (`core.toolCallSig`/
> `transcriptToolSigs`/`isLooping`, `escalation.loop.enabled` off, ⟳ badge + `loop` ledger); OS-native banners
> (`core.notifyDecision` + `FX.notify`, `notifications.banner.*` off). Adversarial review clean (2 reported, 0
> confirmed). Suite 1528 core + 330 ui + 183 bash.
> **Partial batch ✅ SHIPPED 2026-06-15 (deferred-polish ⑥):** the **Settings UI** for the auto-title / loop /
> banner toggles (now real ⚙ checkboxes, keys verified against the engine read sites) + the **hooks inspector**
> (read-only ⚙ section via pure `core.parseHookInventory`/`gateHookTimeoutOk`; warns if `cc-approve.sh` lacks its
> ≥130s timeout). Adversarial-review-caught + fixed: the new `notifications` block dropped hand-edited
> `notifications.days` on Save → added to `SETTINGS_KEEP_SUBKEYS`. `onAutoApproved` not exposed (unconsumed).
> **Still deferred L5 sub-items** (each warrants its own build): detail-panel **tab strip**, **export session
> archive**, **host stats + fleet idle-since**, **PR/MR status** per tile (`gh`-backed), **post-run self-summary**,
> the cline/AutoGPT **session-history browser** + **bulk history management**, and `notifications.banner.onAutoApproved`.
*Source: OpenHands ADAPT items with no prior backlog match — the management/UI layer that makes Shepherd a
better WATCH console. All pure-core derivations off the transcript Shepherd already tails + local reads; no
executor/sandbox/server.*

- **Surface the agent's plan/TODO on a tile** `[H/S]` — pure `core.planFromTranscript(text)` scans the tail
  (same `^%s*{` JSON guard as `transcriptError`, [cc-core.lua:1544](cc-core.lua#L1544)) for the latest
  `ExitPlanMode` input and/or `TodoWrite` todos; show in the detail panel + optional tile 📋 affordance, loaded
  on selection/status-change (never the 1s tick). Optional `<cwd>/PLAN.md` fallback via an FX file read.
- **Auto-title tiles from content** `[H/M]` — `core.deriveAutoTitle(tail, maxLen)` from the first prompt
  (`cc-status.sh` already captures `last_prompt` as the seed); precedence `manual relabel > auto-title >
  folder basename`; cache by projectKey (`cc-autotitles.json`), recompute only while empty; `esc()` at the
  render sink; Settings toggle default OFF.
- **Error-reason taxonomy** `[H/M]` — `core.classifyError(message)` →
  budget_exceeded|model_error|runtime_error|timeout|user_cancelled|unknown (extends `transcriptError`'s result
  with `.reason`); cause badge on the error tile + a search/filter facet; ledger the reason so `fleetStats`/
  shift report gain an "errors by cause" breakdown. Prefer non-message signals (usage-limit autoDeny →
  budget_exceeded; watchdog hung → timeout).
- **Detail-panel tabs** `[H/M]` — reshape the flat `#detail` stack into a tab strip over views Shepherd ALREADY
  produces: Activity (default), Timeline (pull `sessionTimeline` inline), Decisions, Usage, Queue (+ optional
  Lineage / Changes from the L4 diff view). Pin/unpin via the existing right-click menu; persist
  `{selectedTab, unpinnedTabs}` to webview localStorage keyed by projectKey; keep the lazy-load discipline.
  **DROP** Code/Terminal/Browser tabs (no sandbox) — Jump stays the editor affordance. Mostly panel JS.
- **Export session archive** `[H/S]` — per-tile + fleet "Export selected": copy the session's `.jsonl`
  transcript + a `meta.json` (label, provider/model, lineage, shift-report counters); reuse the audit-export
  side-effect path (mkdir `~/.claude/cc-exports`, write, optional zip, alert/Reveal). Pure assembly in cc-core;
  honor the ledger redaction posture so prompt bodies aren't leaked. Explicit operator action.
- **Host stats + fleet idle-since** `[M/M]` — `core.hostHealth` + `core.fleetIdleSince(tiles, now)` (pure,
  injected `now`); feed CPU/mem/disk/uptime from `hs.host.cpuUsage`/`vmStat` + a disk read (NOT `/proc`);
  compact strip in the 📊 insights overlay/footer; wire the host signal into `starvedSince` so a starvation
  alert can note "box is CPU/disk-pressured." Read-only, off by default.
- **PR/MR status per tile** `[H/M]` — STATUS ONLY: `core.parsePrStatus(json)` + `core.prBadge(item)`; opt-in
  cached poll `gh -C <gitRoot> pr view --json number,state,url,title` (reuse the cached `FX.gitRoot`); tile
  badge "PR #123 open/merged" + open-url action; ledger PR-opened/merged into lineage + shift report.
  Self-gates when `gh` absent or no remote. **DROP** create tools, token storage, any VCS API call by Shepherd.
- **Post-run self-summary callback** `[M/M]` — opt-in, off-by-default: `core.summaryPrompt(item)` (sibling to
  `auditReviewPrompt`/`improvePrompt`) + a target filter (modeled on `remoteControlSweepTargets`/
  `shouldAutoContinue`) selecting sessions on a FRESH `done` edge; type via the `dispatchSerialized` chokepoint
  so the reply lands in that session's own tile; optional `summary` ledger event. Framed strictly as "Shepherd
  typed a self-review prompt," never an authoritative outcome.
- **Hooks inspector** `[H/S]` — `core.parseHookInventory(settingsJson [, projectSettingsJson])` walks the same
  hooks table `mergeHooks` operates on, groups by event, returns `{matcher, command, timeout, isOurs}` (reuse
  `OUR_HOOK_SCRIPTS`); read-only 'Hooks' section in ⚙ Settings / `make doctor`, warns if `cc-approve.sh` lacks
  its 130s timeout; per-session twist reads the cwd's `.claude/settings.json` for effective hooks.

- **cline + AutoGPT-corroborated enrichments:**
  - **Session history browser** `[M]` — one search/history overlay (or extend the audit overlay) over the ledger
    + transcript corpus Shepherd already reads: a fuzzy query box (reuse `filterTiles`/`searchArgv`), sort chips
    (newest/oldest/most-tokens/most-relevant via `filterLedger`), facets ("current workspace only" projectKey
    filter, "pinned only"), and a star/pin persisted by projectKey. Derive records — don't persist a parallel
    history store; rows show tokens/size from existing tracking. DROP a cost column + a resumable-task object
    (Claude Code owns `--resume`).
  - **Bulk history management** `[S]` — a storage readout (`localStorageReport` over ledger/queue/state-file
    bytes) in ⚙ Settings near `retentionDays`; multi-select delete in the Audit Rows view routed through the
    existing scoped audit-purge path (with its modal-confirm). DROP deleting Claude Code's own transcripts.
  - **OS-native desktop notifications** `[S]` — `FX.notify(title, text, opts)` wrapping `hs.notify` (click→jump),
    beside `FX.playSound`/`FX.push`; config `notifications.banner = {onApproval, onDone, onAutoApproved}` (default
    off); fire on the rising edge to approval/done (reuse the escalation edge detector + a `notified`
    carry-forward field); pure `notifyDecision(pv, it, cfg)` in cc-core.
  - **Loop-detection watchdog** `[M]` — pure `isLooping(item, recentActions, now, thresholdN)` beside `isHung`:
    fed a ring buffer of the last N tool calls from the transcript tail, true when the same command+args repeats
    ≥N consecutively; a distinct ⟳ tile decoration (not the ⏳ hung ring); nag once per episode; ledger a `loop`
    type; optional auto-nudge ("you seem to be repeating <tool> — try another approach"). Config
    `escalation.loop {enabled=false, repeats=N}`. Detection + human/nudge escalation only — no rewind/model-swap.

### L6 — Event-callback rule engine (NEW from OpenHands) — effort **M**
> ✅ **SHIPPED 2026-06-14** (see CHANGELOG): opt-in `cc-rules.json` rules (`rules.enabled`, default off) react
> to a fresh status edge with a safe effect. cc-core: `validateRule`/`ruleLoad`/`ruleList` (fail-safe),
> `ruleScopeMatch`/`ruleFires`/`rulesForEdge`; v1 triggers `{done, error, approval}`, processors `{log, relabel,
> nudge}`. Engine: `runRules` on the edge, `once` via a reaped `ruleFired` map, ledgered `by:"rule"`. Automation
> result ledger: `outcome` on `auto_respawn`/`auto_continue` + the new `auto_respawn_blocked` (was silent) +
> delivery-gated `handleAction("continue")` (both auto + manual paths ledger gated on delivery). Adversarial
> review (5 reported, 3 confirmed = one manual-continue audit issue, fixed). Suite 1548 core + 344 ui + 183 bash.
> **Editor + triggers/processors ✅ SHIPPED 2026-06-14 (deferred-polish ⑤):** an ⚙️ Automation rules editor (☰
> drawer) — author trigger/scope/processor + once/enabled, list-toggle, edit/rename, delete. **NEW triggers**
> `hung`/`loop`/`starved` now fire `runRules` at their own rising-edge detection sites; **NEW processors** `feed`
> (enqueue a task, auto-feed delivers it) + `continue` (delivery-gated resume). New pure cc-core: triggers/
> processors added to the constants + `ruleGet`/`rulePush`/`ruleRemove`/`ruleSetEnabled` CRUD; new `FX.writeRules`.
> Adversarial review caught + fixed a high-sev silent data-loss bug (feed keyed the queue by the RAW projectKey/cwd
> instead of the SANITIZED `FX.queueKeyFor` key). **Still deferred:** per-rule status lifecycle (COMPLETED/ERROR) +
> `retryUntil`.
*Source: OpenHands event-callback registry + result ledger. Generalizes Shepherd's hard-coded
auto-respawn/auto-continue/escalation into declarative, opt-in rules — layered on the existing level-triggered
dispatcher, NOT a new event bus.*

- **Rule registry (`cc-rules.json`):** opt-in rules `{name, status(ACTIVE|DISABLED|COMPLETED|ERROR),
  trigger:{scope: projectKey|sessionKey, kind: done|error|hung|approval|starved}, processor:{kind:
  feed|continue|nudge|relabel|log, …}, once?, retryUntil?}`, evaluated each refresh tick by pure cc-core
  predicates sitting ALONGSIDE the existing `shouldFeed`(~1975)/`shouldAutoContinue`(~2200)/`isHung`(~2375).
  Status self-mutation persists through `fx` like the `routePending`/`alerted` markers; lifecycle transitions
  emit a `by:"rule"` ledger event. Processor catalog maps onto present effects: log→`appendLedger`,
  relabel→`setLabel`, nudge→`handleAction "nudge"`, feed→`routeTask`. Reuses L1/L3's name→resolver + the
  validator family. Sequential execution = today's single-dispatcher-per-tick.
- **Automation result ledger:** add an `outcome`/`detail` convention to the existing automation ledger events
  (`auto_respawn` ~5595, `auto_continue` ~5615, router feed ~5656, `drain_close` ~5463) — incl. the missing
  write for auto-respawn's wouldFire-but-can't branch (carry `rs.reason`) and an auto-continue delivery outcome
  via the `dispatchSerialized` delivered callback; pure classifier beside `queueFeedCommit`; a "failed
  automations" filter chip in the 📜 Audit overlay. Folds into L4's `task_done` so per-task and per-automation
  outcomes share one event family. No new SQL/pagination — reuse JSONL + the overlay's cap.

### L7 — Scheduled spawns / routines (NEW from cline + AutoGPT) — effort **M**
> ✅ **SHIPPED 2026-06-14** (see CHANGELOG): cron/schedule engine (`cc-schedules.json`, `schedules.enabled` off)
> fires the normal spawn/nudge effects on a schedule. cc-core (pure on injected now): `cronMatches`/`nextRunAt`/
> `dueSchedules`/`humanizeCron`/`validateSchedule`/`scheduleLoad`/`scheduleMarkFired`/`scheduleBackpressure`.
> Engine: a guarded refresh pass fires due routines via `FX.spawnSession` (respects `spawn.live` dry-run), stamps
> `lastFiredAt`, self-deletes one-shots, honors `schedules.maxConcurrent`. `action:"digest"` pushes a
> `fleetStandup` report via `FX.push`. Suite 1599 core + 355 ui + 183 bash.
> **Board UI ✅ SHIPPED 2026-06-14 (deferred-polish ①):** a ⏰ Routines board (☰ drawer) lists routines with an
> enabled dot / schedule+action badges / next-run, inline **Run · Pause/Resume · Edit · Delete**, and an Add/Edit
> form with a **live cron preview** (hour/minute/weekday pickers → `core.cronBuild`, hand-mirrored in the JS
> `cronBuildJS` twin). Pure cc-core: `cronBuild`/`schedulePush`/`scheduleRemove`/`scheduleGet`/`scheduleSetEnabled`/
> `scheduleBoard`. Run-now fires immediately (bypasses cron/enabled, no state mutation, honors `spawn.live` dry-run).
> Adversarial-review-caught + fixed: edit dropped non-form fields (`pushTopic`/`model`/`templateRef`/`agentRef`/
> `tags`) and rename dropped `lastFiredAt` (double-fire) → now carried forward + a name-collision confirm + an
> in-panel pushTopic input. **Still deferred:** import/export routines, overlap control, a launchd
> asleep-while-due backstop.
*Source: cline (Desktop Routine board) + AutoGPT (cron / one-shot / recurring / visual cron builder / next-run /
activity digest) — the one genuinely-new, multi-source candidate. Off by default, ledgered, edge-disciplined
exactly like auto-respawn/auto-continue. NOT a second executor — it fires the normal spawn/nudge effects on a
schedule. (See also [schedule](#) the cloud-routines skill is unrelated — this is local.)*

- **Schedule store + engine:** `cc-schedules.json` operator data of routines `{name, kind: cron|oneShot, when
  (cron expr | epoch), folder, editor, provider, model, permMode, prompt|templateRef|agentRef, enabled:false,
  tags, lastFiredAt}`. Pure cc-core (deterministic on injected `now`): `cronFromSchedule`/`scheduleFromCron`/
  `nextRunAt(cron, now)`/`dueSchedules(list, lastFired, now)` + `humanizeCron(cron)` → "Every Monday 9:00 AM".
  Payload = an existing `spawnSpec` / saved preset / L1 profile / L3 template — NOT a new run type.
- **Firing:** a guarded pass in the ~1s loop (or a dedicated `hs.timer`) calls `dueSchedules` and routes a due
  routine through the normal spawn `fx` (`onSpawn`/`spawnSpec`), or for a resume target pushes `nudgeText` into a
  tile's queue; jump `lastFiredAt` via fx (like `routePending`); one-shots self-delete after a *delivered* fire
  (gate on the fx delivery return). A `sweepOnStartup` re-arms timers + coalesces missed one-shots (copy
  `remoteControlSweepTargets`). Backpressure: `scheduleBackpressure(liveTiles, cap)` defers when over cap.
  **Local-tz only** (`os.date`) — drop timezone fields. Optional launchd plist as the asleep-while-due backstop
  that just opens Shepherd / writes a trigger file (NOT a second executor).
- **Routine board (UI):** routines as a list reusing the tile/badge idiom — enabled dot, cron + mode badges,
  prompt/model/folder, **next-run** (`nextRunAt`), inline **run-now**, **pause/resume** (toggle `enabled`),
  delete; an "Add Routine" modal = the spawn-preset modal + hour/minute/weekday picker → **live cron preview**
  (the pure builder, hand-mirrored in the JS twin). "Last run" soft-links to the live tile it spawned.
- **Periodic activity digest:** a daily/weekly cron routine (off by default) that calls the existing
  `fleetStandup`/`standupMarkdown` over the window and pushes a headline via `FX.push` (full markdown in the
  📋 Shift tab); persists last-fire in `hs.settings`. The first concrete consumer of the scheduling primitive.
- **Import/export routines** (JSON/YAML) + **overlap control** ("don't start if this routine's previous run is
  still busy") round it out.
- **DROP:** SQLAlchemyJobStore / per-user quota / credentials / max_instances / the cline-hub execution board —
  all executor/server.

## Tooling stance (from the June 2026 review)

**Principle for any external tool: detect → use → degrade gracefully** — a missing binary
means slower, never broken (`jq` remains the only hard dependency; `rg` and `fd` are
auto-detected accelerators for fleet search and the spawn modal's fuzzy folder search,
resolved by `resolveBin` via PATH + `/opt/homebrew/bin` + `/usr/local/bin`). The chosen
engine is now **logged at runtime** (`[cc-search] engine=rg …`, `[cc-spawn] folder scan: fd …`)
and **`make doctor`** reports tool status + offers to install a missing accelerator — so an
accelerator can't silently sit unused (which is exactly how `fd` went uninstalled for a while).
Note: any `hs.task` that captures large output must redirect to a file (the ~64KB pipe-buffer
deadlock — see context.md); the folder scan does. Evaluated and **declined**: `gron`/`yq`/
`htmlq`/`hexyl` (no YAML/HTML/binary surfaces; `jq` already covers the JSON), `jc` (a parser
framework for ~5 lines of working `pmset` shell is altitude inversion), `eza`/`bat`/`tv`/`fzf`
(terminal-human niceties; the panel's webview wants embedded JS / pure-Lua `fuzzyFilter`, not
shelled-out TUIs).

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
