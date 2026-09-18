# Claude Shepherd — notes for Claude sessions in this repo

Shepherd is a macOS Hammerspoon fleet console for parallel Claude Code sessions. Hooks
(`cc-status.sh`, `cc-approve.sh`, `cc-popup.sh`, helpers in `cc-lib.sh`) write per-session JSON
to `~/.claude/cc-status/`; `claude-dashboard.lua` renders the panel (its HTML/CSS/JS is
embedded) and wires the real effects; `cc-core.lua` holds the pure logic. The code is **Lua
+ bash** — the global TypeScript/Deno defaults don't apply here. Orientation: `context.md`
and the README's "Testing & development" section.

## Architecture rule

- `cc-core.lua` has zero `hs.*` calls. Every effect goes through the `FX` table, so tests
  swap in `tests/support/fx_recorder.lua`. New logic that can be pure goes in `cc-core.lua`
  with tests; `claude-dashboard.lua` only wires it.

## Gate before any merge

- `make lint` (luacheck + `luac -p` + `tests/lint-timers.sh`) and `make test` (every suite)
  are both green — in the worktree, again after rebasing on main, and again on main after
  the merge.

## Deploying — edits don't run until they're deployed

- Hammerspoon runs **copies**: `make install` copies the Lua into `~/.hammerspoon/` and the
  hook scripts into `~/.claude/`; `make deploy` = lint + test + install + reload. A bare
  reload re-runs the stale copy. Changes to the hooks' `settings.json` wiring need
  `make setup` (the full `install.sh`).
- After a deploy, verify the **running** VM with `hs -c` by probing something new in the
  change — the live modules hang off `_G.__ccDashboard`
  (e.g. `hs -c 'return type(_G.__ccDashboard.core.someNewFn)'`, `.fx` for `FX`).
- **Worktrees:** Shepherd needs no dev server or browser of its own, so units take the tabs
  default: `EnterWorktree` with name `<slug>` → `.claude/worktrees/<slug>`, then
  `git branch -m <type>/<slug>`. `make install` deploys whichever checkout runs it — only
  one worktree deploys at a time, and after a merge redeploy from main so the live copy is
  main. TODO.md is gitignored, so a worktree's copy never blocks `git worktree remove`
  (`tests/worktree-hygiene.test.sh`); main's TODO.md is updated after `ExitWorktree`, since
  the fence blocks main from inside a worktree.
- **Finishing a unit here** follows the global ready-to-merge protocol, with one extra step:
  after the ff-merge and `make test` on main, run `make deploy` from main (the live copy must
  be main) BEFORE `~/.claude/cc-merge.sh done --result merged`, then flip the unit's TODO lines.

## Traps that have bitten this repo

- The webview HTML/CSS/JS sits inside a Lua long string (`local HTML = [[ … ]]`). A literal
  `]]` or `[[` anywhere in it — even in a JS comment — ends the string. Use a temp var
  (`var k = a[i]; b[k]`), and run `luac -p claude-dashboard.lua` after editing it.
- The dashboard's main chunk is at Lua's 200-local cap: hang new state and functions on
  `FX` (or inside a `do … end` block), never a new chunk-level `local`.
- Retain every `hs.timer` (assign it); in keystroke chains use the `after()` helper — an
  unretained `hs.timer.doAfter` can be garbage-collected before it fires.
- Every window action (focus, keystrokes, paste) goes through `dispatchSerialized`; every
  item field that reaches `innerHTML` goes through `esc()` (`tests/escaping.test.sh`).
- Status heuristics must be checked on BOTH surfaces: the VS Code extension buffers the
  assistant message (a pending `tool_use` isn't in the transcript until after the tool
  runs); the terminal CLI writes it first.
- One VS Code window hosts many sessions: every Claude tab in it shares `host_window` (the
  extension-host pid), while `session_pid` is per session and survives `/clear`. Never
  read a shared `host_window` as "the same session".
- Keystrokes go to a window, not a tab: effects refuse a session whose window hosts others
  (`it.sharedWindow`, `core.keystrokeBlocked`). Build every target with `FX.targetFor(it)`,
  and make a new automatic sender skip blocked sessions up front so it can't retry every tick.
- The tab bridge (`vscode-bridge/`, plain JS, no deps) has exactly three ops, all single-match
  only: close (`FX.closeTab`, the strict label `core.claudeTabLabel`), select (`FX.selectTab`
  after a Jump, any of `core.claudeTabCandidates`), and expect (tag the next Claude tab that opens
  as a batch unit's -- those tabs never get a name, so close/select take `unit` instead of a
  label for them; a window reload forgets the tags). One narrow exception (0.4.0): close with
  `empty: <count>` closes ANY untagged "Claude Code" tab (never-used chats are interchangeable),
  only while that count equals Shepherd's empty sessions there (`core.emptyChatsVerdict`) -- a
  restored old chat reads "Claude Code" too but has no session. Never add another op, and never use the
  Claude URI to reveal a tab (D-14). Bump its `package.json` version with every change, or
  `make install` won't reinstall it; running windows pick it up after a reload. A window keeps
  the bridge it loaded, so before relying on an op check `core.tabBridgeSupports(reg.version, op)`
  and read every command's answer (`FX.tabBridgeTrack`) -- on 2026-09-15 every expect went to a
  0.1.0 window, was refused as "unknown op" unread, and no unit's tab ever closed.
- The tab bridge's switch is `tabBridge.*`; plain `bridge.*` is the SSH remote bridge
  (`FX.bridgeSync`). Keep the two apart in config keys, names and wording.
- Ready to merge is its own channel (`cc-merge.sh`, `~/.claude/cc-merge/`), not the approval
  gate: answers are JSON decision files bound to the request's nonce READ FROM DISK
  (`FX.writeMergeDecision`), claimed with `mv` by the waiting script. Readiness and the
  post-merge check use Shepherd's own git (`core.mergeFactsCmd`, `core.mergeVerifyCmd`), never
  the session's word; the tab closes only after both. A new per-key merge file goes in BOTH
  `cc_remove` and `FX.removeStatus`.
- Batch driving (`cc-fleet.sh`, `~/.claude/cc-fleet/`): Adam's grant lives in Shepherd's own
  `<id>.state.json` (`FX.fleetState`) -- never read permission from the proposal file, which
  the session writes. Tabs open one per repo at a time (that's what makes `core.newTabSession`
  unambiguous); merges on a grant go only through `core.fleetDelegatedMerge` (the unit's own
  session and branch) plus the normal readiness check and queue.
- A question `cc-ask.sh` holds (`core.askHeld`: `ask_nonce` + `ask_until` on the status file,
  the questions in `pending.ask`) is answered only through `~/.claude/cc-ask/<key>.answer`, bound
  to the nonce READ FROM DISK (`FX.answerAsk`), never by keystrokes -- its tab has no picker
  up. Approve/Deny skip it. The hook's group has its own matcher (AskUserQuestion) and a
  3630s timeout; never merge it into the matcher-"" group. Its answer file is in BOTH
  `cc_remove` and `FX.removeStatus`.
- "Needs you" is ONE decision (`core.needsYouKind`, stamped on every tile as `it.needsYou` by
  `FX.annotateNeedsYou`): a card ranks as needing Adam only when a live counterpart will receive
  his answer AND the card offers something that changes the outcome. Acknowledge-only is a
  heads-up (`core.TIER_FYI`, `.tile.fyi`) -- visible, dismissible, never red, never above a
  working session. Add a new source to that predicate, never as a sixth branch in
  `core.instanceTier`. Liveness is FX's (`FX.probeAlive`, one batched ps with Shepherd's own pid
  as a control); the decision stays pure. A transient error (`core.ERROR_TRANSIENT`) gets a grace
  window before it goes red -- on 2026-09-17 a VPN blip turned a card red and outranked every
  working session for a fault that healed itself in 40s.
- A project's suite is usually NOT safe to run twice in one checkout (`install.test.sh` shells out
  to the real `make` there; the reload test kills `hs` processes). One merge gate runs per repo at
  a time, pre- and post-merge sharing the lane (`core.mergeGateReleases`), `tests/run.sh` refuses
  a second concurrent run itself (exit `core.TEST_LOCK_EXIT` + `core.TEST_LOCK_TOKEN` -- `make`
  masks a recipe's exit code as 2), and a gate that COULDN'T run is never reported as one that
  failed (`core.mergeGateOutcome`). A post-merge gate only ever runs for a request whose own
  pre-merge gate ran in this Shepherd lifecycle (`core.postMergeGateDue`) -- turning `merge.gates`
  on once gated two merges that had happened hours earlier.
- Messages go through `FX.alert` (a toast in the panel); never call `hs.alert.show` directly —
  Adam found its centre-screen overlay covering every window (`tests/ui.test.lua` pins one caller).
  Stubbed-panel tests read messages from `ccToast(...)` calls or by wrapping `fx.alert`.
- After a merge Shepherd closes ONLY a tab it opened for that job (`core.mergeClosesTab`: a batch
  unit's tag, or a first prompt that is Shepherd's own "Start unit …" / "Resume work in the
  worktree at …"). Never widen it: it once closed Adam's main chat, which had done a unit itself.
- Never type a slash command into a VS Code/Cursor tab that the extension doesn't have: the paste
  path's autocomplete Return runs whatever the slash menu fuzzy-matches (`/rc` ran `/deep-research`
  on every reload). The Remote Control sweep is terminal-only (`core.RC_SWEEP_EDITORS`). When a
  session "does something on its own", check the ledger's prompt events against the console first.
- A tab-less leftover is ended by Shepherd after `tabless.autoEndMinutes` (`core.tablessAutoEndDue`,
  through `FX.endSession`'s ps check); a running batch's driver ranks 4.5 (`core.isDriving`) so its
  card reads Driving and never flips.
- Scripts reach `~/.claude` by RENAME (`make install`, `install.sh`): bash reads a running
  script lazily, so rewriting one in place garbles a hook that's mid-run.
- `vscode://anthropic.claude-code/open?prompt=` opens a new Claude tab in the ACTIVE editor
  window, prompt typed in but never sent. Only `FX.openClaudeTab` sends it, after a positive
  window match re-checked right before the URI goes out; never follow it with a keystroke.
- When live behaviour contradicts the code, dump the running state with `hs -c` before
  theorising (and compare the Hammerspoon process start time with the deployed files).

## Tests

- Pure logic → `tests/core.test.lua`. Panel wiring → source pins in `tests/ui.test.lua`.
  Shipped panel JS that has to actually run → a node test that extracts the real function
  from `claude-dashboard.lua` (the `tests/done-order.test.js` pattern). Hooks → the bash
  suites (`tests/lib.sh` helpers). New suites get wired into `tests/run.sh`.
- Behaviour-named tests under a dated `-- ---- <topic> (YYYY-MM-DD) ----` banner; a bug
  fixture carries one comment line with the date and the actual cause.
- Log lines keep the file's `[cc-dashboard]` prefix.

## Shipping

- Finished, rebased, green units fast-forward into main. Push main and deploy when Adam
  says ship. No AI attribution in commits.
- The repo is public and handed to coworkers: track only what a fresh install needs to run
  Adam's daily methodology (`tests/worktree-hygiene.test.sh` lists what stays local).
- A fresh install copies Adam's setup: `defaults/cc-config.json` (his `~/.claude/cc-config.json`),
  `defaults/claude-settings.json`, and `methodology/CLAUDE.md` (the worktree + test-first sections
  of his global CLAUDE.md). When he changes those at home, refresh the copies here.
- `Install Shepherd.command` → `bootstrap.sh` (prerequisites) → `install.sh`; `uninstall.sh`
  reverses `install.sh` -- a new file `install.sh` ships goes in both file lists.
