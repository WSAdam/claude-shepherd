# Context — Claude Shepherd

Orientation for working on Shepherd's own code: what it is, how it is split, the invariants a change
must keep, and the workflow. Read [CLAUDE.md](CLAUDE.md) first: it holds the traps that have bitten
this repo, and this file points to it rather than repeating them. Other docs: the front page
[README.md](README.md) (its feature tour), the reference pages under [docs/](docs/) (start with
[docs/development.md](docs/development.md) and [docs/configuration.md](docs/configuration.md)), and
the dated history in [CHANGELOG.md](CHANGELOG.md). Older planning notes (`todos.md`,
`docs/orchestrator-next.md`, `docs/feature-mining/`, `docs/hardware-verification.md`) have been
gitignored since 2026-09-17: a checkout may have local copies, and git history has the old ones.

## What it is

A local, single-user macOS console for a fleet of Claude Code sessions (renamed from
"babysitter"). It is Lua running inside Hammerspoon, with no process of its own. Claude Code hooks
write each session's status to `~/.claude/cc-status/`; the panel turns that into one card per
project, and lets Adam approve, deny, answer a held question, stop, nudge, jump to or close a
session. It also runs Adam's parallel-worktree method end to end. What it automates, by area
(the README's [feature tour](README.md#feature-tour) has the full list; `core.FEATURES` holds 89
entries):

- **Feeding work:** task queues with auto-feed and routing, routines (cron spawns, digests, the
  main-green check), event rules, auto-continue with back-off, resume at a usage-limit reset,
  auto-respawn with handoff notes, auto-compact with notes, task packets.
- **Steering without keystrokes:** the session mailbox, `cc-send.sh`, cross-repo tickets, the
  decisions inbox, AskUserQuestion answered on the card, the Stop guards, the hands-off hold and
  ❄ Freeze.
- **Safety:** the opt-in approval gate and policy bundles, always-ask commands, talk mode, the
  worktree fence, one worktree per agent.
- **Merging:** ready-to-merge requests, Shepherd-run test gates, the red-first proof, gate blame,
  the merge checker, batches driven by a session with grant grading, the overlap radar, worktree
  leases, the main-moved notice.
- **Learning and looking back:** the coach (CLAUDE.md and memory edits, across repos too), the
  audit ledger, History (every transcript, kept copies, Resume), Seance, the Time view, usage and
  cost, commit stats, My List (TODO.md import, playbooks, Run selected).

It is not offline. What reaches the network:

- the plan-usage call to `api.anthropic.com/api/oauth/usage`, with the user's own Claude Code OAuth
  token (read from the Keychain or `$CLAUDE_CODE_OAUTH_TOKEN`, never logged);
- `gh` for PR status;
- ntfy pushes (escalation, the fleet idle alert, main red, a compatibility failure, a usage-limit
  resume), when a topic is set;
- headless `claude -p` runs: Seance, the coach, the merge checker (`FX.runHeadless`, hooks off,
  `CC_SHEPHERD_INTERNAL=1`, a dollar cap each);
- the SSH status bridge and the leaderboard "Improve" claim, when configured.

Single user, no server, no accounts. Records store env-var names, never secrets.

## Architecture — the load-bearing split

- **[cc-core.lua](cc-core.lua) — pure logic, zero `hs.*` (~26,600 lines).** Every decision is a
  pure, deterministic function, unit-tested in plain `lua` ([tests/core.test.lua](tests/core.test.lua)
  plus topic suites). Clock only through an injected `now`. **New logic goes here.**
- **[claude-dashboard.lua](claude-dashboard.lua) — Hammerspoon glue (~30,000 lines).** The webview,
  the ~1s refresh tick, module-level state, the background timers, and every side effect. Effects
  go through the `FX` table (declared near the top, `local FX = {}`), so tests swap in
  [tests/support/fx_recorder.lua](tests/support/fx_recorder.lua). The main chunk sits at Lua's
  200-local cap: new state and functions hang on `FX` or go inside a `do … end` (CLAUDE.md).
- **The glue is tested.** About 50 Lua suites load the real dashboard, or an `FX` block cut from it,
  under a stubbed `hs`: `smoke`, `readiness`, `shared-window`, `fleet`, `merge-request`, `seance`,
  `fleet-idle`, `maingreen`, `worklist-runner`, `past-sessions-wiring`, `keeper-copy` and more.
  `tests/ui.test.lua` pins wiring at the source level.
- **Panel HTML/CSS/JS** lives in one Lua long string, `local HTML = [[ … ]]` (about lines
  16,360–27,770). A literal `]]` or `[[` inside it ends the string (CLAUDE.md). Small pure helpers
  are hand-mirrored as JS twins for instant interactivity (the tile filter, `barLevel`,
  `applyAppearance`, `cronBuild`, the My List search, and others; each is commented "twin", so
  `grep -n twin claude-dashboard.lua` finds them) and must stay in sync. Lists that both sides read
  are injected instead: `__BULK_RULES__`, `__HOTKEY_LEGEND__` (built from the bound `HOTKEY_*`,
  themselves resolved by `core.resolveHotkeys` from `cc-config.json`), `__DETAIL_TABS__`,
  `__APPEARANCE_THEMES__`. Shipped JS is tested by node suites that extract and run the real
  function from claude-dashboard.lua (the [tests/done-order.test.js](tests/done-order.test.js)
  pattern) and by 17 Playwright `*.browser.test.js` geometry suites (they skip without Playwright).
- **Hooks**, wired in [settings-hooks.json](settings-hooks.json). Changing the wiring needs
  `make setup`, not `make install`:

  | Event | Scripts |
  | --- | --- |
  | SessionStart | `cc-status.sh` (also prints Shepherd's session context: handoff note, compaction notes, lease, mail, tickets, decisions, DECISIONS.md) |
  | UserPromptSubmit | `cc-status.sh` (stamps `turn_id`) |
  | PreToolUse, any tool | `cc-status.sh`, `cc-approve.sh` (gate, always-ask, talk mode, fence, policies; 130s) |
  | PreToolUse, AskUserQuestion | `cc-ask.sh` (holds the question for the card; 3630s) |
  | PreToolUse, EnterWorktree | `cc-worktree-guard.sh` (denies a worktree another live session is in) |
  | PostToolUse | `cc-status.sh` |
  | PostToolUseFailure | `cc-status.sh` (clears `tool_started_at` after a failed tool; without it `core.readyToType` refused every send to that session) |
  | PermissionRequest, Notification | `cc-status.sh`, `cc-popup.sh approval` |
  | Stop | `cc-status.sh stop` (can block the turn, see below), `cc-popup.sh complete` |
  | StopFailure | `cc-status.sh`; matcher `rate_limit`: `cc-resume.sh` (async, asyncRewake) |
  | PreCompact | `cc-status.sh precompact` |
  | SessionEnd | `cc-status.sh sessionend` (`cc_remove` reaps the session's files) |

- **The Stop hook blocks turns.** At a turn end `cc-status.sh stop` may keep the session working,
  highest first: a mailbox message, the notes request (auto-compact), then the Stop guards in
  order question → fakeDone → unfinished (`cc_stop_guard` in [cc-lib.sh](cc-lib.sh)). A guard
  fires once per session and turn (question) or head sha (the other two), with its marker in
  `~/.claude/cc-guard/`. None runs while the session is held, in plan mode, while
  `stop_hook_active`, in Shepherd's own internal runs, or when the panel heartbeat is stale. The
  guards are off in code and on in `defaults/`.
- **Scripts sessions run themselves:** `cc-merge.sh` (ready to merge), `cc-fleet.sh` (batches),
  `cc-pin.sh`, `cc-decide.sh`, `cc-lesson.sh`, `cc-run.sh`, `cc-send.sh`, `cc-ticket.sh`; plus
  `cc-commits.sh` (commit stats) and `cc-scrub.js` (transcript scrubber). Shared bash helpers are
  in `cc-lib.sh`.
- **[SHIPPED](SHIPPED)** is the one list of shipped files: `install.sh`, `uninstall.sh`, the
  Makefile and the tests all read it, and `core.OUR_HOOK_SCRIPTS` names the same hooks. Shipping a
  new script is one line there, plus its wiring for a hook.
- **[vscode-bridge/](vscode-bridge/)** is the tab bridge, a plain-JS VS Code extension (0.6.0) with
  three ops: close, select, expect. Its rules are in CLAUDE.md.
- **[defaults/](defaults/)** is a fresh install's setup: `cc-config.json` (Adam's config; many
  features off in code are on here) and `claude-settings.json`. [methodology/CLAUDE.md](methodology/CLAUDE.md)
  is the worktree and test-first part of Adam's global CLAUDE.md. Refresh the copies when he changes
  the originals at home.
- **State** lives under `~/.claude/`: `cc-status/` (one JSON per session, plus the panel heartbeat
  `.panel-alive`), `cc-config.json`, and a `cc-*` file or folder per feature. `uninstall.sh`'s
  `STATE` is the full list (what `--purge` removes);
  [docs/configuration.md](docs/configuration.md#files-shepherd-keeps) says what each holds. Newer ones: `cc-guard/`, `cc-hold/`, `cc-lesson/`, `cc-run/`,
  `cc-main-green.json`, `cc-coach/`, `cc-merge/<key>.notyet` and `cc-merge/main-moved.seen`,
  `cc-scratch/` (Seance, red-first and gate-blame worktrees), and `cc-keep/` (kept transcripts,
  which `--purge` leaves in place).

## Invariants worth knowing

The traps in CLAUDE.md are invariants too (the 200-local cap, retained timers, `dispatchSerialized`
and `esc()`, the tab bridge's three ops, the merge and question channels bound to a nonce read from
disk, `FX.alert`, interrupted turns, FSEvents). These are the others.

- **projectKey is the stable identity**: the encoded launch folder from `transcript_path` (cwd
  fallback when there's no transcript). Labels, groups and respawn budgets key by it so they survive
  cd-drift and close/reopen. **Never resolve persistent per-project state by cwd when a projectKey
  exists** (`core.applyGroups` / `core.applyLabelsByCwd` fall back to cwd only for keyless sessions).
- **cc-core stays pure and deterministic.** No `hs.*`, no wall clock except an injected `now`. A
  side effect goes through `FX`.
- **Webview XSS defense is render-time `esc()`**, not input sanitization.
  [tests/escaping.test.sh](tests/escaping.test.sh) is the tripwire. A key that a click sends back
  rides an `esc()`'d `data-` attribute read with `getAttribute`, never an inline JS string.
- **Per-tile refresh state is one row**: `prev[key] = { status, stale, escalated }`, rebuilt each
  tick so a vanished tile drops out. `respawnAttempts` is keyed by projectKey. **Autonomous actions
  never fire from a missing `prev`** (the first tick after a reload observes, it is not an edge) and
  never target a stale tile. Every module-level per-key table starts as `{}`: the end-of-tick reaps
  iterate them even when their feature is off (`core.reapUnbacked`).
- **A large `hs.task` capture deadlocks: redirect to a file.** Past the ~64KB pipe buffer the child
  blocks on write while `hs.task` waits for it to exit. Anything that can print a lot runs as
  `/bin/sh -c "<cmd> > <tmpfile>"` and is read on exit, with a retained-timer backstop
  (`core.folderScanShellCommand`; the compatibility check hit the same wall at 64KB).
- **Nothing heavy on the tick.** Scans (radar, time index, past sessions, schedLock, commits, the
  transcript keeper) run as background tasks on their own timers, cached, with a hung task
  reclaimed. Time the tick before blaming a feature for a freeze (CLAUDE.md).
- **Typing into a session is a contract.**
  - `FX.pasteIntoWindow` / `FX.sendKeys` / `feedTask` return whether they delivered; with no
    positive window match they skip, never type into whatever is frontmost, and the caller gates
    its side effects (queue pop, ledger event, alert) on that return. Window keystrokes are
    serialized through `dispatchSerialized` (shared `core.staggerSlot` tail); headless paths
    (kitty `@`, decision files) stay immediate.
  - Automated sends go through `FX.typeWhenReady`, which waits for `core.readyToType`: not mid-turn,
    not into an approval or a held question, not during a tool, not within 3s of a status change,
    and in kitty only into an empty composer. A refusal is ledgered once as `typing_refused`.
  - Every automatic effect passes `FX.automationAct`, which asks the hold first (a held session or a
    frozen fleet gets nothing), then honours `automation.dryRun` / `<feature>.dryRun` and records
    the ⚡ Trace. Senders outside that door call `FX.holdStops`. Hold flags live in
    `~/.claude/cc-hold/` (`<pid>`, `key-<key>`, `.fleet` = ❄ Freeze).
  - A window shared by several sessions gets no keystrokes (`core.keystrokeBlocked`; build every
    target with `FX.targetFor`). Such a session is reached through the mailbox instead
    (`FX.deliverTo`): a message is handed over at its next turn end by the Stop hook, and a
    turn-end-only note (the main-moved notice) is never typed (`core.mailboxRoute`).
- **Gate decisions are nonce-bound.** `cc-approve.sh` publishes `pending.nonce`; `FX.writeDecision`
  echoes it (tmp + rename); the gate consumes only a matching nonce through an atomic PID-owned
  claim. The merge (`FX.writeMergeDecision`) and question (`FX.answerAsk`) channels use the same
  shape.
- **The panel's localStorage holds per-viewer state only**: detail-tab state keyed by projectKey,
  the commit drawer's open state, and History's ★ pins (`cc-historyPins`). The pins are also sent to
  Lua (`keep-pins`) and kept in `~/.claude/cc-keep/pins.json`, because the transcript keeper acts on
  them.
- **"Needs you" is one decision**, `core.needsYouKind`: needs, heads-up (`core.TIER_FYI`) or nothing.
  A new source joins that predicate, never a new branch in `core.instanceTier` (CLAUDE.md has why).
- **The Claude URI never reveals an existing tab (D-14).** New tabs open through
  `vscode://anthropic.claude-code/open?prompt=`, sent only by `FX.openClaudeTab` after a positive
  window match, the prompt typed in and never sent. `?session=` is the one exception: written only
  by `core.restartTabUri`, sent only by `FX.openClaudeTab` after it re-checks the session is dead
  (`FX.restartVerifyDead`). Its two callers are `FX.restartOne` (Restart fleet) and
  `FX.pastResumeLaunch` (History's Resume, Adam's call 2026-10-04). `tests/ui.test.lua` pins both.
- **The context bar tracks the editor, not the raw window.** `core.contextFractionFor` divides by
  `window * context.autoCompactFraction` (default 0.92, an undocumented approximation kept across a
  Settings Save). A `[1m]` model reads a 1M window. Colour comes from `core.contextBand` (7 bands,
  mirrored in the JS `barLevel`).
- **Two different "remote controls".** `spawn.kittyRemote` / `kittyAutoRemote` is Kitty's `kitty @`
  (Shepherd drives the window headlessly). `remoteControl.*` is Claude Code's own Remote Control:
  `onSpawn` adds `--remote-control` (local, native-Anthropic sessions only), and `sweepOnStartup`
  types `/rc` into idle terminal and kitty sessions only (`core.RC_SWEEP_EDITORS`): in VS Code the
  slash menu once fuzzy-matched it to `/deep-research` (CLAUDE.md). The "enable for all sessions"
  setting has no settings.json key; it is a manual `/config` toggle.
- **Auto-continue is a bounded loop guard.** `core.stepAutoContinue` charges a per-folder budget that
  resets only on a clean `done`/`idle`, never on the `working` its own continue produces, and not on
  a turn that did nothing or only planned. From the second such turn in a row it backs off (2
  minutes, doubling to 30). A usage limit is left to the resume path. Auto-respawn has the same edge
  discipline. Both are off in code and on in `defaults/`.
- **Agent profiles and policy bundles** (L1/L2, 2026-06-14) rest on three facts:
  1. **Shepherd stays a thin layer over the `claude` CLI** (`~/.local/bin/claude`): it emits flags
     (`--mcp-config`, `--agent`, `--plugin-dir`, `--append-system-prompt`, `--add-dir`, `--settings`,
     `--allowedTools`) through `core.spawnExtraFlags` and never reimplements MCP, skills or plugins.
     Skills are read from `~/.claude/skills/<name>/SKILL.md`.
  2. **`gate.tools` is a hold-for-approval list, not a capability allow-list.** A read-only agent is
     built with `autoDeny` of the mutating set (`core.DEFAULT_GATE_TOOLS`), never by adding tools to
     `gate.tools`.
  3. **Secrets are never stored.** Records keep the env-var name (`authTokenEnv`), expanded by the
     spawned login shell. Operator registries (`cc-presets.json`, `cc-agents.json`, `cc-mcp.json`)
     live outside the Settings round-trip; spawns are dry-run until `spawn.live`.

  The gate reads `~/.claude/cc-policy/<key>` (resolved by `core.resolvePolicy`, written atomically by
  `FX.writeResolvedPolicy`) as authoritative. The per-tick orphan sweep must stay decoupled from the
  attachment fast path, and `cc_remove` reaps the file; `POLICY_DIR` must match across `cc-lib.sh`,
  `cc-approve.sh` and the dashboard.

## Workflow

- **`make test`** runs [tests/run.sh](tests/run.sh): about 167 files (65 Lua, 41 bash, 61 node, 17
  of them Playwright browser suites) plus the demo's deno tests. Side-effect-free: temp dirs, a temp
  `HOME` for stubbed-`hs` suites, recorder doubles, `hermetic-env.sh` strips `CC_*` from the calling
  shell. It holds a per-checkout lock (`install.test.sh` shells out to the real `make`), and
  `bash tests/run.sh <files…>` runs just those files, which is how the red-first proof runs a unit's
  tests on the merge-base. CI (`.github/workflows/ci.yml`) runs lint and the suite on ubuntu;
  `tests/portability.test.sh` catches Mac-only test code.
- **`make lint`** = luacheck (when installed) + `tests/lint-timers.sh` + `luac -p`.
- **`make install`** copies the `SHIPPED` files by rename (Lua to `~/.hammerspoon`, scripts and
  `cc-core.lua` to `~/.claude`) and reinstalls the tab bridge on a version bump. **`make deploy`** =
  lint + test + install + reload. **`make setup`** (`install.sh`) is the full install and upgrade:
  suite first, then copy, merge the hook wiring, the `init.lua` line, the Dock launcher. Others:
  `make reload` (stops a hung `hs` client after ~10s), `make doctor`, `make uninstall [PURGE=1]`,
  `make demo`.
- **Edits are not live until deployed**, and a deploy is verified in the running VM with `hs -c`
  (CLAUDE.md).
- **A typical change:** a failing test first (a bug gets a fixture and a TODO.md line), then a pure
  `cc-core` function, wiring in the dashboard with a `ui.test.lua` pin or a stubbed-`hs` behavioural
  suite, a JS twin or a node/browser test if the panel shows it, a new suite wired into
  `tests/run.sh`, `make lint` and `make test`, deploy, probe with `hs -c`. New transcript-fixture
  words go in `tests/fixtures/transcripts/vocabulary.txt`.
- **Units and merges** follow the worktree method: `.claude/worktrees/<slug>`, `cc-merge.sh
  request` when green, the gate again after the rebase and on main, then `make deploy` from main
  before `cc-merge.sh done` (CLAUDE.md, "Finishing a unit here").

## Tooling stance — detect → use → degrade gracefully

- **Required:** `jq`, `lua` and `node` (`bootstrap.sh` installs them, `install.sh` checks),
  Hammerspoon (its `hs` CLI for reloads and probes), `git`.
- **Needed by a feature:** the `claude` CLI for Seance, the coach and the merge checker; `gh` for PR
  status; VS Code's `code` CLI to install the tab bridge (without it, Close on shared-window tabs
  stays refused); `ffmpeg` + `whisper-cli` for Stream Deck voice.
- **Optional accelerators:** `rg`/`fd` for fleet search and the spawn modal's folder scan, resolved by
  `resolveBin` (PATH + `/opt/homebrew/bin` + `/usr/local/bin`), falling back to grep/find. The engine
  in use is logged (`[cc-search] engine=rg …`), and `make doctor` reports tool status and offers to
  install a missing one.
- **Test-only:** luacheck, Playwright (browser suites skip without it), deno (the demo).
- **Declined:** `gron`/`yq`/`htmlq`/`hexyl`, `jc`, `eza`/`bat`/`tv`/`fzf` (no surface in a webview).

## Known platform limits (not bugs)

- **VS Code / Cursor extension widgets are mouse-only.** Shepherd works around them: AskUserQuestion
  is answered through `cc-ask.sh` (`updatedInput`) from the card; approvals go through the gate's
  decision file; new tabs open through the Claude URI (`FX.openClaudeTab`) for New worktree tab,
  batch units, Instances Open, Run selected items, a ticket's tab, a new session in a window that
  already has one, Restart fleet and History Resume. The permission-mode switcher still has no
  keyboard path.
- **Keystrokes go to a window, not a tab**, so a VS Code window with several sessions gets none
  (mailbox instead). Kitty (`kitty @`) is the one surface where typing is fully reliable.
- **Waking an idle session** with `asyncRewake` (the resume at a limit reset) is unverified; Shepherd
  types the line where typing is allowed, else says so on the card and pushes.
- **A pop on completion** with both `popOn*` flags off is the VS Code extension raising its own
  window, not Shepherd.

## Deferred / not-yet-built (historical, as of the 2026-06-19 todos reset)

Kept as written on 2026-06-19; check the code before assuming an item is still unbuilt. Since then
the session mailbox (04273f3), `cc-send.sh` and cross-repo tickets covered part of the delegation
and "broadcast mailbox" family. The editors the 2026-06-14 entries below call deferred (agents
1d2966c, bundles 19ab916, templates 6eff6b5, rules 432c594, the routine board 5801199) had already
shipped on 2026-06-14; the polish items here are what remained of them. Full per-item detail is in
git history of `todos.md` and `docs/feature-mining/*`.

- **Needs hardware (runbook ready):** `docs/hardware-verification.md` (local, gitignored) — verify
  the `core.KITTY_KEY` send-key tokens + AskUserQuestion `answerKeys` nav on a real Kitty box, and the SSH
  status-bridge 8-step checklist (remote install / headless-only assumption, rsync+openrsync round-trip,
  decision round-trip, `BatchMode` auth, clock-skew → `bridge.staleSlackSeconds`, the `bridge.keystrokes`
  title-escape experiment, SessionEnd prune, spawn-then-appear).
- **UX-gated routing (4c-E / L4 follow-ups)** — each needs a design call first: task→session affinity/tag
  **source**, auto-spawn on starvation (needs a cap + UX), idle sessions as routing targets, remote tiles as
  routing targets (pairs with `bridge.keystrokes`), plus L4's topology view (`plot`), role-addressed
  delegation, hierarchical "manager" mode, pending-before-ready queue, parent/delegation lineage, task
  dependency chains, queue priority + concurrency cap, broadcast mailbox.
- **Per-feature editor / enforcement polish:** L1 in-editor `modelByMode`/`requiredEnv`, agent-folders tree,
  recently-deleted/restore; L2 bundle `gateTools` auto-apply at spawn + `toolLimits` shell enforcement (soft
  ledger indicator today) + deny-reason enrichment; L3 in-editor vars-schema editor; L6 per-rule status
  lifecycle (COMPLETED/ERROR) + `retryUntil`; L7 import/export routines, overlap control, a launchd
  asleep-while-due backstop.
- **DR follow-ons:** DR1 in-transcript `Task`/`isSidechain` sidechains (none exist locally yet); DR3
  per-checkpoint targeted rewind is impossible (`/rewind` is an interactive picker with no arg) + deletions
  aren't counted as "changed"; DR4 an LLM-as-judge "deep score" + a fleet-wide score trend; DR5 per-tile /
  per-project $ + budget-alert rules; DR6 an LLM classify pass + fleet-wide opt-in once trusted; DR7 worktree
  cleanup of an abandoned (never-kept) cohort (`git worktree prune`).

## State (2026-10-14) — Crossings

- **Crossings** (D-27): nothing one project's session writes for another reaches it without Adam.
  `cc-ticket.sh` leaves the filing, each reply and each close note as a request in
  `~/.claude/cc-cross/`; the writing session's card goes red with the text in editable boxes;
  Adam's Approve (`FX.crossDecide`) is the only publisher, and a Deny tells the session his note.
  Only the filer, the holder and the ticket's repo can take or show a ticket. Code:
  `core.cross*` (the Crossings block after the tickets block), `FX.stepCrossings` / `FX.crossDecide`
  in the dashboard, `cc_cross_*` and `cc_session_project` in cc-lib.sh. cc-send between projects is
  held the same way (`FX.sendHold`): the sender is the CLI's process ancestry (`FX.sendSender`,
  `core.ancestorSession`), Adam's Approve delivers (`FX.crossPublishSend`), Shepherd follows the
  reply (`FX.crossFollow`, `core.sendFollowStep` -- the Lua twin of cc-send.sh's jq reducer) and
  holds it on the replier's card, and the waiting CLI reads `cc-cross/<cid>.answer` /
  `.reply.answer` (exit 7 on a Deny). Fleet, cc-lesson and Claude Code's SendMessage were left as
  they are.
- **Fixes after the 2026-10-13 push**: a permission prompt in a shared window reads Needs you, the
  bulk bar counts only what it can do there, and CI runs green on Linux again.

## State (2026-10-13) — My List lanes and review, merges in auto mode

- **Mining round 3** (2026-10-10): 30 new fleet-manager repos plus NCC Group's research, compared
  against Shepherd. The report is `docs/feature-mining/round3/SUMMARY.md` (gitignored), and its
  confirmed bugs are logged in TODO.md.
- **My List** gets **To do · To verify · All** lanes (Mark all marks the lane shown; the filter box
  is the Archive's alone; `[~]` lines are To verify) and the **review heads-up**: 30 items to
  verify, or one waiting a day, puts a heads-up on the project's cards and a count on 📋. The
  clock is `claimTs`, which the import stamps from file facts.
- **Merges in auto mode**: the approval hook answers allow for the session's own approved
  fast-forward (`cc_approved_merge`), because the classifier refused it ("Merge Without Review"). A
  merge Shepherd is still checking reads **Working**, not a heads-up (`core.mergeChecking`).
- **Fixes**: the lock counts a session running background work as working, and Close selected
  closes an unnamed session whose tab shows a leftover name (Adam's widening, `core.unclaimedTabs`).

## State (2026-10-04) — the worktree method, the build program, mining round 2

Since 2026-06-29 Shepherd went from a fleet monitor to the console that runs Adam's parallel-worktree
method. This is the map; [CHANGELOG.md](CHANGELOG.md) has one dated section per change and the
[docs/](docs/) pages have the reference detail.

**July–August.** Two multi-agent bug sweeps (2026-07-02: 30 fixes; 2026-07-13: 36), the VS Code
transcript-buffering status fixes, My List growing into a per-project verification list (item modal,
MASTER rollup, persistent tabs), more Appearance themes (50 now), an installer that runs the suite
before it touches any config.

**The worktree method (2026-09-10 → 09-25).** One card per project with its worktrees folded in, and
the Instances view; New worktree tab; no keystrokes into a shared window; the tab bridge extension;
ready to merge (`cc-merge.sh`) with Shepherd running the test gate itself; batches driven by a session
(`cc-fleet.sh`); held questions answered on the card (`cc-ask.sh`); "Needs you" as one decision;
toasts instead of `hs.alert`; install by double-click with `defaults/` and `methodology/`. See
[docs/merging-and-batches.md](docs/merging-and-batches.md) and the 2026-09-10 to 09-25 CHANGELOG
sections.

**The build program (2026-09-28 → 09-30, complete).** A 44-unit plan run as parallel batches B0–B15,
each unit a worktree that Shepherd merged on a green gate. The
[CHANGELOG section](CHANGELOG.md#2026-09-30--the-build-program) lists every unit; in short:

- Cards: turn labels, the working-on line, Running N jobs, pinned links (`cc-pin.sh`), the
  scheduled-tasks lock check, API errors and usage limits read as errors.
- Reaching a session: the session mailbox, `cc-send.sh`, tickets (`cc-ticket.sh`), the decisions
  inbox (`cc-decide.sh`, 📥 Inbox), Restart fleet in place.
- Automation: readiness before typing, the automation door with dry run and the ⚡ Trace,
  auto-continue back-off, resume at the limit reset (`cc-resume.sh`), handoff notes, auto-compact with
  notes, task packets, the coach.
- Safety: always-ask commands, talk mode, the worktree fence, `cc-worktree-guard.sh`.
- Merging: merge hardening (markers, clean main, stash count), the merge checker, the red-first proof,
  the repo-declared gate, REQ ids and merge receipts, the batch relay (`cc-fleet.sh wait`), the overlap
  radar with `blockedBy`, the coverage index, worktree leases.
- Health, docs, tests: the Claude Code compatibility check, `SHIPPED`, the README split into `docs/`,
  the ledger quarantine, the scenario corpus and `cc-scrub.js`, CI on ubuntu.

Follow-ups on 2026-09-30 and 10-02: the coach's applied-edit history with Undo, and the
`PostToolUseFailure` hook (a failed tool no longer blocks every send to its session).

**Mining round 2 (2026-10-02 → 10-04, complete).** A second feature-mining round (Maestro, Gas Town,
ECC, oh-my-claudecode, OpenRig), built as 23 units in 8 batches after the U0 hook fix, merged on
green. See [the CHANGELOG section](CHANGELOG.md#2026-10-04--mining-round-2):

- Stop guards: question, fakeDone, unfinished (`cc_stop_guard`; on in `defaults/`).
- The coach: a lessons ledger, evidence runs and `cc-lesson.sh`, edit outcomes and Sharpen, a review
  of the repo's auto-memory, lessons across repos into the global CLAUDE.md.
- Steering: Seance, the fleet idle alert, the hands-off hold and ❄ Freeze, playbooks and Run selected
  in My List (`cc-run.sh`), queue hold and the 📑 Queues view, Restart fleet outcomes.
- Merging: brief pre-flight, gate blame, the main-moved notice, the main-green check (a routine with
  `"action": "gate"`), grant grading (a risky merge on a batch grant waits for Adam's click).
- Unseen sessions: grey cards for live sessions with no status file; the transcript keeper
  (`cc-keep/`, and Diagnostics can set `cleanupPeriodDays`); History listing every transcript and
  kept copy (`FX.refreshPastSessions`, a background scan) with Resume, which puts a kept copy back
  first when Claude Code has deleted the original.

A fix after the round (78f3a73) stopped the stub check reading `/TODO.md` paths as TODO comments.
Open after it: the E5 "land together" design note (`docs/feature-mining/e5-land-together-design.md`,
local) waits for Adam's decision, and the live checks no test can prove are the `[~]` /
`(needs live run)` lines in TODO.md.

---

The entries below are dated snapshots, kept as history and not updated: names, counts and "deferred"
notes in them may be out of date. The sections above describe the code as it is now.

## State (2026-06-29) — User Stories detail tab (view/edit spec/product/user-stories.md)

A gated **User Stories** detail tab (`core.DETAIL_TABS` `stories`), shown only when the selected
project has `spec/product/user-stories.md` (per-item `has_user_stories` stat in the refresh;
`renderTabBar`/⋯ menu/selection honor the gate, and `ccUpdate` re-renders the bar when the file
appears/disappears mid-session via `lastSelectedHasStories`). Lazy `detail-stories` load +
`stories-save` save handlers (local-only, fixed project path — no client path component).

Pure core: **`M.parseUserStories`/`M.serializeUserStories`** — an "anchored block" model where
every non-story line (title, intro, `##` headings, prose, blanks, **fenced code**) is a `raw`
block kept VERBATIM and each bullet is a `story` tagged with `area` + `marker`. **Invariant:**
`serialize(parse(x)) == x` byte-for-byte for a `\n`-terminated file; a no-final-newline file
gains one (normalization — the old trailing-newline strip caused appends to glue + corrupt).
A story is ONE line (embedded newlines collapse; a leading bullet marker is stripped) so an
edit can't inject structure. Each `##` heading anchors its own raw block (tagged `headingArea`)
so an add lands under the EXACT area. `M.cheapHash` backs the save concurrency guard;
`M.userStoryWellFormed` the soft "so that" hint. Saves: re-read + hash-guard against an external
edit, refuse an empty write over a non-empty file, atomic temp+rename (`FX.writeFileAtomic`).
Built test-first, then hardened by two multi-agent adversarial sweeps (44 agents; 21 + 6 LOW
findings triaged). Accepted LOW edges: duplicate same-name headings merge in the UI; an indented
fence written inside a bullet folds into that bullet's text — both round-trip-safe.

## State (2026-06-19) — Appearance system (themeable UI) + new-project cold-start fix

A full visual refresh: the panel stylesheet was converted to a **`:root` design-token layer**, and an
**Appearance tab** (in a newly **tabbed** Settings overlay) lets the operator pick a theme + customize
colors / size / font, live. Plus a field-reported new-project spawn bug fixed.

- **Token layer.** The ~800-line `<style>` block now references CSS custom properties (`--bg`/`--surface`/
  `--border`/`--text…`, status `--st-*`, `--accent*`, sizing `--ui-scale`/`--tile-min`/`--gap`/`--pad`/
  `--font`) declared in a `:root` block (the Refined-Midnight defaults == the old hand-tuned palette).
  **Edit the palette/themes in `cc-core` `APPEARANCE_*`, NOT the literals** — almost no raw hex remains in
  the stylesheet. The few always-light spots (ctx-bar `%`, notify badges) keep a literal `#fff` on purpose.
- **Pure core (tested):** `core.APPEARANCE_DEFAULTS` (Midnight baseline) + `APPEARANCE_THEMES` (**16**
  presets, each a token delta over defaults) + `APPEARANCE_VARS` (the ordered `{key→cssVar}` list, also the
  emit order) + `APPEARANCE_FONTS`. `core.resolveAppearance(ap)` merges defaults←theme←overrides
  (accent / palette / status), validates hex, clamps scale/tileMin, carries font + reduceMotion;
  `core.appearanceCss(resolved)` renders the `:root` override block (valid-hex tokens only, so a malformed
  override silently falls back to the default).
- **Injection (mirrors `__INIT_THEME__`):** a 2nd `<style id="appearance-root">__APPEARANCE_CSS__</style>`
  after the main stylesheet receives `core.appearanceCss(resolveAppearance(readConfigEarly().appearance))`;
  the body carries `data-look` (`__INIT_LOOK__` → static `body[data-look=slate|flat]` SHAPE rules) and a
  density / `calm` (reduce-motion) class via `__INIT_DENSITY__`. `__APPEARANCE_THEMES__` injects
  `{vars,defaults,themes,fonts}` for the JS. **The whole gsub block is wrapped in `do…end`** — the file is
  at Lua's 200-local main-chunk cap, so it adds NO new main-chunk local (same lesson as the lock/automodel blocks).
- **KEEP-IN-SYNC twin:** JS `applyAppearance(ap)` mirrors `resolveAppearance`+`appearanceCss` for instant
  **live preview** (sets the `:root` vars on `documentElement`, toggles `data-look`/`dense`/`calm`); and JS
  `COLORS` (the detail dot) is single-sourced to the `--st-*` tokens (no hex twin). The injected `APPEARANCE`
  single-sources themes/defaults/vars/fonts, so only the small merge logic is duplicated.
- **Two persistence axes — don't conflate.** **Appearance** (theme + accent/palette/status + font + sizing +
  reduce-motion) persists in **`cc-config.json`** (`appearance` block, form-managed, written wholesale →
  `resolveAppearance` tolerates any missing piece). **Layout** (cards/bar/contrast/dots — tile *arrangement*)
  stays in **`hs.settings`** via the existing `onThemeChange`, so the Appearance "Layout" chips apply
  **instantly** (not on Save). Cold-start spawn timing lives under `spawn.*` and is kept across a Settings
  Save (added to `SETTINGS_KEEP_SUBKEYS.spawn`).
- **Tabbed Settings:** the flat `#s-body` sections are bucketed into tabs (General/Appearance/Approvals/
  Automation/Observability/Spawn) by their header text on open (`tagSettingsTabs`/`settingsTabFor`) — no
  per-section markup wrapping needed. Cancel reverts the live preview (`applyAppearance(apSaved)`); Save commits.
- **🐞 New-project cold-start spawn fix (field-reported).** "Start new project" opened VS Code but the lone
  `⌘Esc` fired at ~7s into a still-loading Welcome tab and missed (logs confirmed: `⌘Esc` then nothing). The
  extension cold ladder is now **adaptive** — it polls until the project window actually appears
  (`focusProject` returns true ONLY on a real title match → also focuses it), waits a buffer for the
  extension to activate, then opens the panel **once** (`⌘Esc` toggles, so never double-fire) and delivers
  the task. Tunable + Save-safe: `spawn.coldWindowWaitSeconds` (25) / `spawn.coldActivateSeconds` (6). Linear
  chain (one pending timer) tracked in `spawnSeqHandles` for supersession; `after` keeps timers GC-safe.
  The bounded open/wait/giveup decision is the **pure, tested `core.coldStartStep(windowSeen, elapsed,
  waitMax)`** — a window that never title-matches gives up after `coldWindowWaitSeconds` (best-effort open),
  it can't infinite-poll. **Still best-effort by nature** — extension-activation time is unobservable — so it needs a live
  new-project spawn to confirm per-machine; bump `coldActivateSeconds` if a heavy setup needs longer. A
  no-task new project opens the panel ready (a tile appears once a first prompt is sent).

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
  (first line carries `agentId`+`slug`+ the agent's first `message.content` = its task prompt) +
  `subagents/workflows/wf_*/`, NOT in-transcript `Task`/`isSidechain` lines (0 of those exist locally —
  verified). `core.subagentsDir`/`subagentTree`/`subagentMeta`/`subagentLabel` (prefers the prompt over the
  random fleet slug, collapsed + truncated) + `FX.subagentScan(dir, withContent)`; detail `Agents` tab (in
  `core.DETAIL_TABS`) groups rows **under a per-Workflow header with a running/total rollup**, click to drill
  (`detail-subagent` → `core.transcriptRecent`, path-validated by `core.subagentNameOk`).
- **DR2 — Background-work indicator** — green `⚙ N` tile pill via `core.backgroundActivity` over the same
  `subagents/` mtimes (`subagents.activeWindow` default 45s); cheap mtime-only scan on the refresh tick. A
  done/idle session with live background agents also reports **"Running N agents"** instead of "Ready for
  you" (display-only `bgRunning`/`effStatus`/`statusWords` in the panel JS; `it.status` stays untouched, so
  hooks/auto-continue/notifications/queue-feed are unaffected).
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
mined into a backlog L1–L7 (`todos.md` and the per-project reports in `docs/feature-mining/`, both in git history).
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
**1260 core + 210 ui + 177 bash** checks, all green. Remaining work was in `todos.md` (git history):
the **needs-hardware** runbook (`docs/hardware-verification.md`, git history)
for the Kitty tokens + the SSH bridge, and the deferred routing follow-ups.
