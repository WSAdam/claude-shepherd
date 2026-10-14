# spec.md — Claude Shepherd ("the fleet console for Claude Code")

A floating, always-on-top Mac panel with **one tile per Claude Code session**. Each
tile shows the project and a live status; selecting it opens a control panel to
**jump**, **approve/deny**, **nudge**, or **stop** that session — plus observability,
automation, and governance over the whole fleet from a single pane.

> Status: **reverse-engineered from the shipped app** (README + source), not a forward
> scoping draft. Brought up to date on 2026-10-04, after the build program and mining round 2.
> This documents intent and the decisions already made, so the
> [user stories](./user-stories.md) have a traced home and future features can be scoped
> against it. Sections marked **[DECISION]** record a product choice that's already
> settled (with its rationale), not an open question.

---

## 1. Product thesis

**When you run several Claude agents at once, the bottleneck is *you*.** A session that
finishes or hits a permission prompt sits idle until you happen to notice it. Shepherd's
job is to **tell you which agent needs a human right now, and let you handle it without
losing your place.**

- One **always-on-top panel**, one tile per session, color-coded by who needs attention.
- Everything you'd otherwise context-switch for — approve a permission, read what it's
  doing, nudge it, stop it, switch its model — happens **in the panel**.
- It is the on-screen equivalent of a **Stream Deck for a fleet of agents**.

The design constant: Shepherd **supervises; it never does a unit's work**. Claude Code is still
the harness and the sessions still write the code; Shepherd is the supervisor's console. Its own
hands are few and bounded: it starts read-only headless `claude -p` runs (the merge checker, the
coach, Seance), runs a project's test gate itself, opens a fresh session for a batch unit or a
My List item (a My List item's brief is typed in and never sent: you press Return), and writes
instruction files (a repo's `CLAUDE.md`, a marked block in `~/.claude/CLAUDE.md`, a repo's
auto-memory) only on your click.

## 2. Goals / Non-goals

**Goals**
- See the whole fleet at a glance; surface the one session that needs a human first.
- Reliable **approve/deny** of permission prompts — ideally hands-free, regardless of editor.
- Per-session control (jump, stop, nudge, clear/compact, effort/mode/model) from the panel.
- Spawn new sessions (folders, presets, agent profiles, providers) from the panel.
- Automation you switch on: queues/routing, escalation, auto-respawn, rules, schedules and the
  coach act only once enabled. A few named conveniences are on from the start, and a fresh install
  writes the author's defaults, which turn on more; §7 lists both exactly.
- Governance you can audit: a local ledger, insights, shift reports, gate-decision provenance.
- Evidence Shepherd gathers itself (its own git, its own test-gate runs) before it calls a merge
  ready, merges on a batch grant or ticks an item off, never a session's word (D-5).
- Local-first observability (status, plan/TODO, usage, subagents) **derived from data Claude
  already writes** and Shepherd's own hook events, spending no model tokens. The few features that
  do spend tokens (merge checker, coach, Seance) are named and capped (§6).

**Non-goals**
- **Orchestrating non-Claude agent CLIs** (aider, gemini-cli). They have no hook system, so
  tiles/approvals couldn't work. Shepherd supervises **Claude Code** specifically. **[DECISION D-1]**
- **Being a second executor.** Rules and routines fire the *normal* spawn/nudge/digest effects,
  and a routine's `gate` action (**Check main is green**) runs the repo's own merge gate in its
  gate lane; they don't introduce a parallel action engine. **[DECISION D-2]**
- **Enforcement by quarantine.** Risk/collision/loop/hung are **detection only** — they badge,
  they never block, lock, or kill another process. The brief pre-flight and gate blame are
  advisory in the same way. **[DECISION D-3]** Two things do hold work back, on purpose, and
  neither touches another process: the **Stop guards** send a session's own turn end back once
  with a reason (D-22), and **grant grading** holds Shepherd's own merge on a batch grant until
  Adam clicks (D-18). Denying a tool call (the gate, always-ask commands, talk mode, the worktree
  fence) is the approval hook's job, not a detector's.
- **A hardened security boundary.** The screen lock is a *soft* deterrent, not the macOS login
  window (that would break keystroke control of GUI sessions). **[DECISION D-4]**
- **Cross-platform.** macOS + Hammerspoon only; control relies on macOS Accessibility, `kitty @`,
  and AppleScript-style focus.
- **Claiming outcomes on a session's word.** Shepherd claims an outcome only on evidence it
  checks itself, never on a session's prose ("done", "tests pass"). It reads merges with its own
  git (D-16), runs a project's test gate itself, re-runs a red gate at the merge-base to say which
  failures main already has (gate blame), checks main on a schedule (main-green), merges on a
  batch grant only on its own gate pass for that commit (D-18), ticks a My List item off only on
  its own reading of the item's file or that item's own session's `cc-run.sh` report (D-24), and
  says how each restarted session came back. Beyond that it reports *operations* (prompts,
  approvals, spawns): it has no CI of its own, and a PR's state is only read through `gh`.
  **[DECISION D-5, revised]**

## 3. The core loop (the heart of the design)

Everything rests on a one-way **hook → status file → panel** flow, with **panel → file → hook**
return paths for the answers only Adam gives. No daemon, no socket, no DB.

```
Claude Code hooks ──► cc-status.sh ──► ~/.claude/cc-status/<session_id>.json ──► dashboard (tiles)
                  ├─► cc-approve.sh ◄── ~/.claude/cc-status/<session_id>.decision ◄── (panel Approve/Deny)
                  ├─► cc-ask.sh ◄── ~/.claude/cc-ask/<key>.answer ◄── (panel answers a held question)
                  ├─► cc-resume.sh ◄── ~/.claude/cc-resume/<key>.plan.json ◄── (panel's limit-reset plan)
                  ├─► cc-worktree-guard.sh  (EnterWorktree: one worktree, one agent)
                  └─► cc-popup.sh           (optional editor focus-pop)
Stop ──► cc-status.sh ──► {"decision":"block"}  (a mailbox message, a notes request, a Stop guard)
```

- **`cc-status.sh`** merges each hook event into that session's JSON. `settings-hooks.json` wires
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
  Notification, Stop, StopFailure, PreCompact and SessionEnd. PostToolUseFailure (2026-10-02)
  clears a failed tool's in-flight marker the way PostToolUse clears a successful one: before it,
  a failed Bash command left the session refusing every automated send with "tool" until it ran
  another tool.
- **`cc-approve.sh`** is the optional PreToolUse gate: it parks a gated tool and reads the
  decision file the panel writes — **no window focus, no keystrokes** needed to approve.
- **`cc-ask.sh`** is a PreToolUse hook on the AskUserQuestion matcher (D-19);
  **`cc-worktree-guard.sh`** one on EnterWorktree, denying a linked worktree another live session
  works in; **`cc-resume.sh`** a StopFailure hook on `rate_limit` that wakes the session at the
  usage limit's reset.
- **`cc-core.lua`** is the pure logic (parsing, sorting, action selection, deck layout,
  spawn-command building) — no `hs.*`, fully unit-tested.
- **`claude-dashboard.lua`** is the Hammerspoon bootstrap: reads the JSON, renders tiles,
  writes a heartbeat, and wires the real effects (focus, keystrokes, Kitty remote, Stream Deck).

**Why a file-merge model.** A status file per session is crash-safe, inspectable, and needs
nothing running between events. The dashboard is a *reader* of status files; the hooks read back
what Adam decides. Every answer the panel gives (an approval, a held question's answer, a merge
decision, a batch's grant) is a file bound to its request's nonce read from disk and claimed with
`mv`. Not every hook is fire-and-forget any more: the Stop hook may print a block decision (a
mailbox message, a notes request, a Stop guard), and it reads `cc-hold/` first so a held session
gets none of them. Each writer owns its own files: the hooks (`cc-status/`, a Stop guard's
`cc-guard/<key>.<guard>`); the scripts sessions run (`cc-merge.sh` → `cc-merge/`, including the
`<key>.notyet` a Not yet leaves; `cc-fleet.sh` → a batch's proposal; `cc-lesson.sh` → `cc-lesson/`;
`cc-run.sh` → reports in `cc-run/`; `cc-decide.sh`, `cc-ticket.sh`, `cc-send.sh`, `cc-pin.sh`);
and the panel (decision and answer files, a batch's own state, `cc-hold/`, `cc-main-green.json`,
`cc-keep/`, checklist runs). **[DECISION D-6, revised]**

## 4. Status model

| Status     | Color           | Fires from                    | Meaning                                |
|------------|-----------------|-------------------------------|----------------------------------------|
| `idle`     | gray            | SessionStart                  | Open, nothing happening yet            |
| `working`  | amber           | UserPromptSubmit, Pre/PostTool| Actively doing work                    |
| `approval` | red (pulsing)   | Notification (permission)     | Needs permission or your input         |
| `done`     | green           | Stop, Notification (idle)     | Finished its turn, ready for you       |
| `error`    | magenta         | StopFailure, *or the transcript* | Frozen on an API error (no Stop fired)  |

- Sessions are keyed by **session_id** (two sessions in one folder never collide).
- A **grey card**, in its own row under the grid, is a live interactive session in Claude Code's
  `~/.claude/sessions/` that no status file covers (started before Shepherd's hooks, or with hooks
  off): its folder, Claude Code's own busy/idle, and "restart it to get live status". It must stay
  alive and unmatched for 15 s first and is never an `sdk-*` headless run (Shepherd's own `claude -p`
  included). No sender, count, needs-you verdict or restart snapshot sees one.
- Badges ride on top of the status: **HOLD** (one session on hands-off hold) or **FROZEN** (the
  fleet is frozen), D-23; **⚠ main is red** on every card of a repo whose scheduled main-green
  check last failed, with the failing lines in its tooltip.
- Tiles **dim** after ~90s of silence (a crash), **disappear** on SessionEnd.
- A `done` tile **self-heals to `working`** when the transcript shows the model resumed, so an
  auto-continued/text-only turn isn't stuck on "Ready for you" (`status.resumeSlack`).
- `error` is detected from the transcript with a coarse **cause badge** (budget/timeout/runtime/
  model/cancelled); auto-respawn is held off so you resume the *same* session.

## 5. Control paths — and their honest limits

Two delivery paths, and which one a session uses determines reliability. **[DECISION D-7]**

1. **Headless approvals (reliable everywhere).** Arm the gate; Approve/Deny write a decision file
   the hook honors — no focus, no keystrokes. Works for terminal *and* VS Code-extension sessions.
   This is the recommended path for governance.
2. **Per-session keystroke effects** (jump, stop, nudge, clear/compact, answer, mode-switch). On
   **Kitty** these run headlessly via `kitty @` remote control. On **VS Code/Cursor** they focus
   the window and type — reliable in a terminal, **best-effort in the VS Code extension** (no
   supported API to inject into a running session). **Queue** stores work reliably; feeding into
   the VS Code chat input is the fragile part.

A third path carries messages rather than keystrokes: the **session mailbox** (2026-09-29).
Shepherd leaves a session a `[shepherd]`-marked message in `~/.claude/cc-inbox/<key>/`; the Stop
hook hands the oldest over by blocking the turn's stop with it (never while `stop_hook_active`),
a resumed or compacted session is shown what still waits, and an idle session is typed a one-line
nudge only in kitty or a VS Code window of its own. In a shared window nothing is typed and the
card says **1 message waiting**. Each message is claimed by rename, so it arrives once. `cc-send.sh`,
tickets, late decision answers, the main moved notice and the driver's uncollected-answer mail all
travel this way.

Each session **self-reports its editor** (`cc-status.sh` reads the env it inherits from `claude`),
so the panel routes effects per session: Kitty → headless, everything else → focus-and-type.

Focus-and-type reaches a **window**, not a tab. When several Claude sessions run as tabs in one
VS Code/Cursor window (they share its extension host, `host_window`), the keys go to whichever tab
is in front — so a session in a shared window gets **no keystroke effect**: Shepherd refuses and
says why rather than risk the wrong tab, and the automatic senders skip it. Jump and headless
approvals are unaffected; `keystrokes.refuseSharedWindow` turns the guard off. **[DECISION D-12]**

New Claude tabs don't go through keystrokes at all: the Claude extension's
`vscode://anthropic.claude-code/open?prompt=` URI opens a **new** tab in the *active* editor
window with the prompt typed in. Shepherd uses it for **New worktree tab**, to resume an idle
`.claude/worktrees/` worktree, for a spawn into a window that already holds a live Claude session,
for a ticket's **Open a tab for it**, for a batch unit's tab (opened empty: the driver sends its
task with SendMessage, D-18) and for each item tab of a My List checklist run (its brief typed in,
D-24). Every time it brings the repo's own window to the front, re-checks it right before the URI
goes out, and **never sends the prompt** — the operator reads it and presses Return. A prefilled
tab costs one keypress; an automatic Return would be the very keystroke into a shared window that
D-12 refuses. **[DECISION D-13]**

Jump stays **window-level**: it doesn't bring a session's own tab to the front. The same URI with
`?session=<id>` can — a 2026-09-10 spike showed it switches the active tab to that session's
editor tab with no second panel, and it follows `/clear` (the extension rebinds the tab to the new
session id). But when the window the URI reaches holds the session anywhere *other* than an editor
tab — the Claude **sidebar**, or a different window after a focus race or with two windows on one
folder — the extension opens a new tab that resumes the session and launches a **second Claude
process on it** (its webview calls `launchClaude()` even when the session is live in another
surface). Shepherd can't tell a sidebar session from an editor tab, so a Jump would risk forking a
live session; instead you pick the tab (its title is the chat title). Revisit if the extension ever
refuses to resume a session live elsewhere. **[DECISION D-14]**

D-14 has **one exception** (2026-09-30): reopening a session that is **verified dead**. A session
with no process anywhere cannot be forked, so `?session=<id>` may reopen its tab. The URI is
written in one place (`core.restartTabUri`) and sent by one function (`FX.openClaudeTab`, which
verifies again right before it goes out), and it has exactly two callers:

- **Restart in place** (`FX.restartOne`, 2026-09-30): after a Claude Code update or a reboot,
  ☰ → ♻️ Restart fleet reopens the sessions of its snapshot one at a time, each stamped so it is
  never reopened twice. Dead means no session file of Claude Code's (`~/.claude/sessions/`) names
  it under a process `ps` still shows, and its own recorded process is gone or is another process
  now (start times compared, Shepherd's own pid as the control).
- **History's ↻ Resume** (`FX.pastResumeLaunch`, 2026-10-04, Adam's call): a past session in no
  restart snapshot is judged by `core.pastLiveness` — no card in Shepherd, no live
  `~/.claude/sessions` entry, and no process whose command line holds its id. A spike found a
  missing transcript makes the link open an *empty* tab, so a session whose original transcript
  Claude Code has deleted but whose kept copy remains gets that copy put back at its original path
  first: clone-copied to a part file beside it, then linked into place, never over a file that is
  there. A terminal session comes back with `claude -r <id>` instead.

Anything that can't be verified counts as alive and is never reopened. Every other use stays
banned: Jump, Open and New worktree tab never pass a session id. **[DECISION D-14, revised]**

Closing **one** tab needs something inside VS Code: nothing outside can target a tab (⌘W hits
the front one; the Claude extension's URI has no close; VS Code's Accessibility tree is off). So a
tiny local companion extension, the **tab bridge** (`vscode-bridge/`), runs in every window's
extension host — the same process as that window's Claude tabs, so its pid *is* `host_window` —
lists the window's Claude tabs by name, and takes exactly three commands, each acting only on a
**single** match: **close** a Claude tab, **select** one (D-17), and **expect**: tag the next
Claude tab that opens as a batch unit's (D-18) or a checklist run item's (D-24). Those tabs never
get a name, so close and select take the tag instead of a name for them. The tab API exposes no
session id, so the name is the identity: Shepherd computes it as the Claude extension does (custom
title, else AI title, cut to 24 UTF-16 units + "…"), and close uses only that strict name — a fresh
"Claude Code" tab, or two tabs sharing a name, stay refused. One narrow exception: never-used chats
all read "Claude Code" and are interchangeable, so close may carry a count and close an untagged
"Claude Code" tab only while the window shows exactly as many as Shepherd counts empty sessions
there; Instances' **Close selected** (2026-09-25, Adam confirms first) closes unnamed sessions by
that count only when every unnamed session in the window is selected. Widened again 2026-10-13
(Adam's call): an unnamed session's tab can show a leftover name (an old chat's title after a
session-link reopen), so when a window's Claude tabs equal its live sessions with a tab (no restored
old chat), the tabs no named session claims close too: "Claude Code" by count, any other by its own
single-match name (`core.unclaimedTabs`). The bridge gains no op. Bridge 0.6.0 carries the
tags over when VS Code rebuilds its tab objects on a tab switch. It is installed locally with VS
Code's own CLI, never published. **[DECISION D-15]**

**Ready to merge** is its own channel, not the approval gate: the gate's status values, its
`allow|deny <nonce>` answers and its 120 s hook wait can't carry a review or wait an hour. A
worktree tab runs `cc-merge.sh request` in the **background** (Claude Code wakes the session when
it exits), which writes `~/.claude/cc-merge/<key>.json`; Shepherd checks it with **its own git**,
reviews it on the card, and answers with a decision file bound to the request's nonce, claimed with
`mv` like the gate's. Approving means "go": the **session** that did the work rebases, settles
conflicts with the tests, fast-forwards main and runs `cc-merge.sh done` (which removes the
worktree and branch only once the branch is in main, never forced) — one merge per repo at a time,
in click order. Shepherd re-verifies with git before the tab bridge closes the tab. In Claude Code's
auto mode the classifier refused that fast-forward ("Merge Without Review"), because the only sign
of approval it could see was the script's own output. So since 2026-10-13 the approval hook answers
**allow** for exactly the session's own approved `git merge --ff-only <branch>` into main, checked
against the request on disk (`cc_approved_merge`); a hook's allow skips the classifier. While
Shepherd is still checking a request (its test gate running or queued), the card reads **Working**,
not a heads-up: nothing on it is Adam's to press yet. **[DECISION D-16]**

Around a merge Shepherd gathers more of its own evidence (D-5):

- **Test gate** (`merge.gates`, 2026-09-17; or, with `merge.repoGate`, the base branch's own
  `.worktree-check`, read with Shepherd's git so a unit can't rewrite its own gate): Shepherd runs
  the project's suite itself in the worktree before the review calls the unit ready — one gate per
  repo at a time, pre- and post-merge sharing the lane. A gate that couldn't run (a locked suite, a
  missing command, a folder that's gone) is never reported as one that failed.
- **Merge checker** (`verify.onMerge`, 2026-09-29): red flags from the diff with no model (added
  conflict markers, deleted tests or lines removed from one, a new `.skip`/`.only`/`fdescribe(`,
  stubs), then a headless read-only Sonnet review (`verify.maxBudgetUsd`, $1 by default), once per
  request per commit, shown as pass / fail / couldn't run. 🔎 Verify runs the same review for any
  session. Adam's own Merge click never reads it.
- **Gate blame** (2026-10-03): a gate that fails with failing test lines is run again at the
  merge-base in a detached scratch worktree (cached per repo, merge-base and command, queued behind
  any gate that judges a merge), and the review splits the failures into *already failing on main*
  and *new in this branch*. Informational only: a red gate stays red, and a merge-base run that
  couldn't finish counts on neither side.
- **Main moved notice** (`merge.mainMovedNotice`, on by default, 2026-10-03): at a verified merge,
  every other live worktree session of that repo whose own changes (as the overlap radar scanned
  them) touch the merged files gets one mailbox note — "main moved to <sha7> (<unit>), touching
  <files>: rebase onto main before you ask to merge". It is handed over at a turn end or start,
  never typed, and announced once per repo and merged sha, across reloads (`main-moved.seen`).
- **Main-green check** (2026-10-03): a routine with `"action": "gate"` (**Check main is green** on
  the ⏰ Routines board, opt-in per repo) runs the repo's merge gate in its main checkout, behind any
  merge in the repo's gate lane, after checking the checkout is on its branch with no uncommitted
  tracked changes. Red raises one banner (and a phone push with escalation push on), **⚠ main is
  red** on every card of the repo and an entry in the coach's log; the next green clears it. A run
  that couldn't run or timed out changes nothing, and a fleet freeze or a held session of the repo
  skips a scheduled run. It fires on schedule only with `schedules.enabled`; **Run** (Adam's own
  click) works regardless.

Jump lands on the **exact tab** after all — through the tab bridge, not the Claude URI. The bridge's
second op, `select` (by name, single match only), focuses the tab's editor group and opens the tab
at its index (`workbench.action.focus<Nth>EditorGroup` + `workbench.action.openEditorAtIndex`):
pure tab switching, so D-14's resume-a-live-session risk can't arise. A wrong pick only shows
another tab, so select may use any of a session's names; **close keeps the strict one**. Any window
still on an older bridge just lands on the window (Doctor says to reload it). **[DECISION D-17]**

A Claude session may **drive a batch** of worktree units, and Adam's permission is **one approval per
batch**. The session proposes it with `cc-fleet.sh propose`; the review on its card carries a
"Claude may merge these when green" box. The grant is recorded in Shepherd's own state file —
the proposal file is the session's and is never trusted for permission. Approved, Shepherd opens each unit's
tab on the driver's request (an empty Claude tab, then the one new session in the repo root whose
parent is that window's extension host — one opening per repo at a time); the driver hands the unit
its task with SendMessage, which runs under the unit's own permissions. Stop ends the grant at once.
**[DECISION D-18]**

- **Brief pre-flight** (2026-10-03): before Adam answers, the units' *full* briefs (not the
  review's 300-character cut) are scanned for force push, push to main, deleting or skipping
  tests, `rm -rf`, secrets and CI or deploy files (negation-aware: "never git push" doesn't
  count), plus two units citing one file and more than one hook-wiring unit. The review lists each
  flag with the words that raised it, the card counts them, and `propose` prints one line. It is
  advisory (D-3): Approve is never held.
- **A late answer is still collected** (2026-10-02/03): when the driver's `propose` stopped
  waiting before Adam answered (a background time limit), `cc-fleet.sh propose --resume <id>`
  collects the answer, for the session that proposed the batch only. An answer still uncollected
  30 s after Adam gives it mails the driver, once, that command.
- **Merges on the grant need Shepherd's own evidence.** They go through only for a unit's **own
  session on its own branch**, after Shepherd's readiness check, and only with **its own test
  gate's pass recorded for that commit** (a repo with no gate configured waits for Adam's click)
  plus, with `verify.onMerge` on, the merge checker's pass.
- **Grant grading** (`core.grantRisk`, 2026-10-03) holds a merge for Adam's click when the diff's
  full file list touches hook wiring (`settings-hooks.json`, `install.sh`, `uninstall.sh`,
  `SHIPPED`), any `CLAUDE.md` or `methodology/`, `DECISIONS.md`, `defaults/`, CI config,
  migrations, lockfiles or `.claude/settings*`, deletes a tracked file, or the checker passed it
  with a high-severity finding. `merge.grantWaitsFor` picks the categories; unset means all of
  them. A hands-off hold on the unit's session, or a ❄ fleet freeze, makes it wait too (D-23).
  The card says why it waits, and Adam's own Merge click never reads any of this.
  **[DECISION D-18, revised]**

A session's **question is answered from Shepherd**, not by driving the tab. Nothing outside the
VS Code webview can click its picker, so the question is caught before it is shown: `cc-ask.sh`, a
PreToolUse hook on AskUserQuestion, holds it while Shepherd's heartbeat is fresh, publishes a nonce,
and waits for `cc-ask/<key>.answer` bound to that nonce. It then allows the tool with the answers in
`updatedInput.answers` (keyed by question text; a list for multi-select; free text accepted), and
Claude Code skips its picker and gives Claude the answer as the tool result — spiked 2026-09-11 in
the CLI and a VS Code tab. A release, a timeout (`ask.waitSeconds`, ≤ 3600) or a dead panel emits
nothing, and the tab's own picker is the fallback. Approve/Deny never act on a held question. A
turn that asks Adam in prose instead is sent back once to ask it this way (the question Stop
guard, D-22). **[DECISION D-19]**

After a verified merge Shepherd closes **only a tab it opened for that one job** — a batch unit's
(known by its tag) or one started with its own prompt (New worktree tab, a resumed worktree). A main
chat that did a unit itself in a worktree stays open; its finished request is cleared with a toast.
(2026-09-14: closing every merged session's tab took Adam's working conversation with it.) A
checklist run's item tab (D-24) closes by its run tag once its item is done, through the bridge's
own close by tag: `core.mergeClosesTab` was never widened for it. **[DECISION D-20]**

Shepherd never types a slash command into a VS Code/Cursor tab that the extension lacks: the chat
input's slash menu fuzzy-matches and the autocomplete Return runs its guess. The Remote Control
startup sweep therefore types `/rc` into **terminal** sessions only; extension tabs get Remote
Control from their launch flags. (2026-09-15: `/rc` ran `/deep-research` in VS Code tabs on every
Shepherd reload, 11 times in a week.) **[DECISION D-21]**

## 6. Observability (local, derived, no model tokens)

All from the transcript Shepherd already tails, its own hook events and Claude Code's own session
files — **no model tokens**:

- Live "Doing:" activity peek; current plan/TODO; error-cause badge; loop-repeat watchdog (badge
  only); stuck/hung watchdog (badge only).
- **Subagent/Workflow fan-out** read from the `subagents/` tree Claude writes; a "⚙ N" pill and
  "Running N agents" so background work isn't mistaken for idle.
- **Grey cards** for live sessions the hooks never reported (§4).
- Optional: auto-title, desktop banners, post-run self-summary, PR/MR status (via `gh`), host
  stats, run score — each off by default.
- **Fleet idle alert** (on, `alerts.idleMinutes`, 15): one macOS banner (plus a phone push when
  escalation push is on) once every local session has been idle or done that long, armed again
  only when a session works again. An interrupted turn counts as idle by its transcript marker,
  never by going quiet. `alerts.voice` (off) speaks it through `hs.speech`, and
  `alerts.voiceEvents: ["needsYou"]` also says when a session starts needing you.
- **Token usage** read from the local transcript `usage` fields: per-tile context-fullness bar,
  fleet total + estimated $ (subscription is flat-rate; this is an API-equivalent estimate),
  and real plan-window (5h/weekly) bars from a **metadata-only** OAuth usage call (spends no
  model tokens; falls back to a labeled local approximation).

**What does spend model tokens** is named and capped, each a headless read-only `claude -p` run
with its own `--max-budget-usd`: the **merge checker** (`verify.maxBudgetUsd`, $1 a run), the
**coach** (`coach.maxBudgetUsd`, $1 a run; its evidence runs also stop at `coach.evidence.dailyUsd`,
$3 a day across repos; its across-repos run at most once a day) and **Seance** (a budget sized from
the session's context, at most `seance.maxBudgetUsd`, 20 by default).

## 7. Automation & governance posture

**One settings file (`~/.claude/cc-config.json`).** A ⚙ Settings panel writes it; the hooks read
it on their next fire. Not everything starts off; this is exactly what is on, and when:

- **With no file at all**, only conveniences act by themselves: a held question answered on the
  card (D-19), resume at a usage limit's reset, worktree leases, Remote Control for spawned
  sessions, ending a tab-less leftover, plan-limit alerts, the **fleet idle alert**
  (`alerts.idleMinutes`, 15), the **main moved notice** (`merge.mainMovedNotice`) and closing a
  merged unit's tab. **Grant grading** holds merges on a batch grant from the start
  (`merge.grantWaitsFor` unset means every category). Read-only background checks (commit
  counts, the overlap radar, the scheduled-tasks lock check) run too.
- **A fresh install** writes the author's daily settings (`defaults/cc-config.json`) when there is
  no file yet, and those also turn on auto-continue, the Respawn menu, auto-compact with notes, the
  three **Stop guards** (`stopGuards.question`, `.fakeDone`, `.unfinished`), the merge checker
  (`verify.onMerge`), the worktree fence, the audit ledger and real spawning (`spawn.live`).
- **Off until switched on**, either way: the queue's auto-feed and routing, rules, routines
  (`schedules.enabled`), escalation, auto-respawn, voice alerts (`alerts.voice`) and the coach's
  own runs (`coach.enabled`).

The capability ladder:

- **The gate** holds a configurable risky-tool list (default `Bash Write Edit MultiEdit
  NotebookEdit`) until you decide; pattern `autoAllow`/`autoDeny` globs (deny wins); per-session
  override (Default/All/None/Custom); time-boxed **Autopilot**. Emptying the tool list restores
  the default (a blank can't be distinguished from unset). **[DECISION D-8]**
- **Named policy bundles** (read-only/no-bash/no-network) attachable per session or by
  project/group/provider glob; union with or replace the fleet patterns.
- **Event-callback rules** (L6): `{trigger: done|error|approval, processor: log|relabel|nudge}`,
  optional match scope, fire-once.
- **Scheduled routines** (L7): cron/one-shot that fire the normal spawn or digest effects, or a
  `gate` action (**Check main is green**, §5); a scheduled spawn still respects `spawn.live`
  (dry-run). Nothing fires on schedule until `schedules.enabled`.
- **Queues:** a queued line can be **held** in place (stored as `{text, held = true}`): auto-feed,
  Feed next and the router feed the next line that isn't held, until it is released. ☰ → 📑 Queues
  lists every session's queue (its sessions, held lines, a packet line's last cited-code check)
  with Hold / Release, ▲ ▼ and ✕ (which asks first).
- **Recovery:** manual + automatic **respawn** of a session frozen mid-turn (capped per folder);
  **Auto-Continue** of a session frozen on an API error (capped per folder); **escalation** nag
  when an approval waits too long. A session waiting on *you* is never auto-respawned. After a
  Claude Code update or a reboot, ☰ → ♻️ **Restart fleet** previews and then reopens every session
  that went down (D-14), and each reopened row ends as **resumed** (its hooks wrote again, or a
  session file names it under a new process), **came back fresh** (a new session in its folder) or
  **didn't come back** (neither within 5 minutes), recorded as `restart_outcome` and summed up in
  one toast per run.
- **Detection:** risk indicator, shared-directory collision, loop/hung watchdogs — badges only.

**Stop guards** (2026-10-02/03). A guard reads how a turn ended and, when it shouldn't have ended
that way, the Stop hook blocks the stop **once** with a reason, so the session carries on and its
card stays working:

- **question** — the last paragraph asks Adam something in prose (code, quotes and a question
  answered in the same breath don't count): ask it with AskUserQuestion, so it lands on the card
  (D-19). Never while a question is already held.
- **fakeDone** — the last message claims done while the diff from the merge-base with main to the
  working tree adds a `.skip`/`.only`/`xit`/`fdescribe`… to a test, deletes a test, or leaves a
  stub: the lines are listed (up to 8), to fix, or to justify in one line. The merge checker's own
  rules, run at the turn end.
- **unfinished** — a session in a `.claude/worktrees/` worktree claims done, with commits ahead of
  main and no merge request for that worktree: ExitWorktree, then `cc-merge.sh request`. Not while
  background tasks run, and never for a commit Adam answered Not yet; after a compaction a unit's
  session is told the finish steps again.

A mailbox message stands every guard down (it is new input, maybe the very answer); the notes
request goes first and the guard joins it; among the guards question > fakeDone > unfinished, and
only the first that fires speaks. Each blocks once per session and turn (question) or head sha
(the other two), remembered in `cc-guard/<key>.<guard>`; none runs while `stop_hook_active`, in
plan mode, in Shepherd's own internal runs, on hold, or where the panel's heartbeat is stale. Each
block is one `stop_guard` ledger event. This is D-3's carve-out: a guard sends back the session's
own turn end, never another process, and the session may answer it in one line and carry on.
**[DECISION D-22]**

**Hands-off hold** (2026-10-03). **Hold** (a tile's menu, the detail panel) puts one session on
hold, and **❄ Freeze** in the toolbar holds the fleet; the card reads HOLD or FROZEN. Every
automatic send stands down: the automation door (auto-feed, routing, rules, auto-continue,
respawn, a *held* row in the Trace), the drain close, scheduled spawns and the main-green check,
a checklist run, merges on a batch grant (they wait for Adam's click), and in the hooks the Stop
guards, the notes request and the resume wake. Each skipped send is listed on the session and
never replayed. Mail (the mailbox, decisions, tickets) waits and goes out once the hold is lifted.
The flags are `cc-hold/<pid>` (it survives `/clear`), `key-<key>` (no known process) and `.fleet`.
**[DECISION D-23]**

**Playbooks and the checklist runner** (2026-10-03). **📘 Add a playbook…** on a project's My List
tab picks a markdown checklist through the Mac's file chooser (never a path typed into the panel);
its `- [ ]` lines import like `TODO.md`'s, grouped under the file's name, and their ✓ auto and
▶ live run chips follow the file. **Remove playbook** stops the import and keeps its items to
verify. **▶ Run…** picks open items (nothing preselected) and **Run selected** works through them
one at a time, each in a fresh tab in the repo's **main checkout**, opened through D-13 with its
brief typed in (Adam presses Return) and tagged through the bridge's `expect`, so it closes by
its run tag when the item is done (D-20). A file line (`TODO.md`, a playbook) counts once Shepherd
reads its box ticked and the turn didn't end as *did nothing*; any other item once its own session
runs `cc-run.sh done` (or `blocked`, which pauses the run). Then Shepherd sets **Adam's own
checkmark**, shown as **✓ by run** and unchecked like any other, and only for a run Adam started;
importing a `TODO.md` or a playbook never sets it. Three items in a row that finish nothing stop
the run; a live-run item, a blocked report or a batch in the repo pauses it; a hold or a freeze
holds it; one run per repo at a time. Runs are `cc-run/<id>.run.json`, written only by the panel.
**[DECISION D-24]**

**The coach** (2026-09-30, extended 2026-10-02/03). With `coach.enabled` (off by default) the coach
runs weekly (`coach.day`), or sooner once enough new evidence has come in (`coach.evidence.minItems`,
after a 24 h cooldown, under the daily dollar cap); a session's **🧭 Coach** button starts one by
hand, switch or not. A headless read-only Sonnet reads the repo's last 10 sessions (corrections,
interrupts, tool errors, denials with a note, Not yet notes) and Shepherd's own log (merge notes,
checker findings, main going red, and lessons sessions filed with `cc-lesson.sh "<one line>"`),
and proposes up to 5 `CLAUDE.md` edits with evidence, optional `DECISIONS.md` entries, and a review
of the repo's Claude Code auto-memory (delete, rewrite or keep a note, or promote one into
`CLAUDE.md`). Nothing is written but on Adam's click:

- **Apply** writes `CLAUDE.md` and commits it alone, refused when the file changed since the
  coach read it (hash) or has uncommitted edits; **Undo** takes an applied edit back out in a
  commit of its own. A memory edit is refused the same way when a session changed the note, is
  backed up first in `cc-coach/<repo>.memory-backup/` with `MEMORY.md`'s index kept in step, and
  Undo restores it. Nothing outside the repo's memory folder is touched.
- A per-repo **lessons ledger** keeps every Apply, Skip (with an optional one-line *Why skip?*)
  and Undo; the next run reads it, so an applied suggestion isn't proposed again and a skipped or
  undone one comes back only with new evidence.
- Each run judges the applied edits that at least 3 later sessions postdate: working, still seen
  (with quotes) or no data yet, decided by Shepherd, not the model. **Sharpen** runs the coach on
  one edit alone for a better wording.
- **Across repos**: at most once a day, when 2+ repos have applied lessons it hasn't compared, one
  run groups the same lesson across repos (the model's call, never fuzzy matching) and proposes
  each group as one rule for a marked, 4 KB-capped block in `~/.claude/CLAUDE.md`. Apply is a
  click, refused once the file changed since the run read it, written through a link to its
  target and backed up first in `cc-coach/global.claude-backup/`; Undo restores the backup. It is
  never mirrored into `methodology/CLAUDE.md`.

**[DECISION D-25]**

**Seance** (2026-10-02). Any session, live or long finished, can be asked a question from its
detail panel, a Find-in-fleet hit or a 🗂 History row. A read-only headless fork of its own
conversation answers (`claude -p --resume <transcript> --fork-session --no-session-persistence`,
the checker's read-only tools, hooks off, no MCP), in the session's model with a budget sized from
its context (§6). Nothing is saved, the session never sees the question, and its transcript is
only read. It runs in its own lane, never behind a repo's checker or coach. **[DECISION D-26]**

**Crossings** (2026-10-14, Adam's call: "projects should not be able to utilize having shepherd to
talk to each other, that needs to be an approved translation between the two rather than something
automatic"). Nothing a session writes for ANOTHER project reaches it on its own: a ticket's filing,
every reply and every close note waits on the writing session's card as a red Needs you, with the
exact text, until Adam approves it -- edited if he likes; the receiver sees "(edited by Adam)" -- or
denies it, and the author is told his note. Both directions are held. The CLI only leaves a request
(`~/.claude/cc-cross/<cid>.req.json`); Shepherd keeps its own record, which only Shepherd writes,
and Adam's click is the only thing that publishes the text into a ticket. A crossing never expires
and outlives its session's `/clear` and end (the 🎫 board carries it when no card does). Taking a
ticket carries no text and stays immediate, but only a session it was offered to or one of its repo
-- where the session LAUNCHED, not where it `cd`'d -- can take or read one. Tickets filed before
crossings shipped (2026-10-15) went through as they were. Limit: every session runs as the same Unix
user, so one that writes another project's files directly (`cc-inbox`, a ticket file, a transcript)
isn't stopped; every channel Shepherd provides is, and sessions are told not to route around a
hold. cc-send between projects gets the same approval: a send from a Claude session to a session of
another project waits on the sender's card, and with `--wait` its reply waits on the replying
session's card before the sender sees it. Shepherd follows the reply itself, so the sender is never
told where the other side's transcript is, and who sent a request is read from the CLI's process
ancestry, never its environment. Same-project sends and Adam's own shell stay instant. Fleet batches
from another repo's folder, cc-lesson and Claude Code's own SendMessage were left as they are.
**[DECISION D-27]**

**Audit:** an append-only JSONL **ledger** (`~/.claude/cc-ledger/`; off in code, on in a fresh
install's defaults) is the data source for **Fleet insights**, **notification history**, the
**shift report**, the **session-history browser**, **lineage**, and **gate-decision provenance**.
Round 2 adds `stop_guard`, `restart_outcome` and `past_resume` events. Retention is GC'd by
days/size; rows can be redacted/exported/purged. The ledger never records Claude's own transcripts.

**Past sessions and kept transcripts** (2026-10-03/04). 🗂 History also lists every transcript
Claude Code still has in `~/.claude/projects` and every kept copy (AI title or first prompt, size,
date), read by a background scan, never the tick; each row offers 🔮 Ask (Seance) and ↻ Resume
(D-14). The **transcript keeper** copies every transcript of a project ★-pinned in History into
`~/.claude/cc-keep/<project>/<session>.jsonl` once its session ends (an APFS clone on its own
5-minute timer), and again when it grows. History, fleet search and Seance read the copy once
Claude Code has deleted the original. Nothing deletes a copy on its own: unstarring offers
**Remove kept copies**, confirmed first, and `uninstall.sh --purge` leaves the folder. Diagnostics
shows Claude Code's `cleanupPeriodDays` (30 when unset) and offers **Keep transcripts 365 days**,
which writes only that key.

## 8. Providers & models

A "provider profile" is a named bundle of **env vars + a model id** injected into the `claude`
launch. **No API keys are stored** — a profile names an *env var* the spawned login shell expands;
the key lives in your shell, never in Shepherd's config or process. **[DECISION D-9]**

- **anthropic** — sets `ANTHROPIC_MODEL` against the normal endpoint.
- **gateway** — also sets `ANTHROPIC_BASE_URL` to an Anthropic-Messages-compatible endpoint
  (LiteLLM → Gemini/OpenAI/etc., or a local Ollama/vLLM/LM Studio server).

A session's **base URL is fixed at launch**: switching the *model* within a provider goes live via
`/model`; switching the *provider* needs a new session. Every Shepherd control keeps working
because the harness is still Claude Code — only the backend swaps.

## 9. State & data model

No database. State is small JSON files in `~/.claude/`, keyed by **stable project identity** (the
session's launch folder) so labels/groups/queues/worklists survive `/clear`, respawn, and
close/reopen. **[DECISION D-10]**

On top of that, sessions fold into **project cards** (2026-09-10): a session launched at a git
worktree top-level joins its repo's card (key = the repo's common git dir), so a main checkout
and its sibling worktrees are one project; everything else stacks by its launch folder. A repo
card's name is the main checkout's relabel. Display and triage fold; per-session state
(queues, gate, policies) stays per launch folder. **[DECISION D-11]**

```
cc-status/<session_id>.json     live per-session status (hook-written)
cc-status/<session_id>.decision panel→gate approval decisions
cc-ask/<key>.answer             panel→cc-ask.sh answer to a held question
cc-labels.json / cc-groups.json relabels, group tags        (by project identity)
cc-presets.json / cc-agents.json spawn presets, agent profiles
cc-mcp.json                     MCP server defs (secrets as ${VAR} refs, never values)
cc-queue/*.json (per project)   task queues: a line is a string, or {text, held = true} while held
cc-templates.json               parameterized templates
cc-worklist.json                the My-List checklist and its `playbooks` sources (by project identity)
cc-config.json / cc-rules.json / cc-schedules.json  automation config
cc-policy/<key> / cc-gate-tools/<key>  resolved per-session gate state
cc-ledger/YYYY-MM-DD.jsonl      append-only audit ledger
cc-exports/                     archived sessions (transcript + meta.json)
cc-inbox/<key>/                 the session mailbox
cc-merge/<key>.json             merge requests (cc-merge.sh); <key>.notyet = the commit Adam said
                                Not yet to; main-moved.seen = main moved notices already sent
cc-fleet/<id>.*                 a batch: the driver's proposal, Shepherd's own state, its events
cc-hold/                        hands-off holds: <pid>, key-<key>, .fleet
cc-guard/<key>.<guard>          a Stop guard's once-marker (the turn, or the head sha)
cc-lesson/<epoch>-<pid>.json    lessons sessions filed for the coach (cc-lesson.sh)
cc-run/<id>.run.json            checklist runs (the panel's); <run>.<item>.*.json = cc-run.sh reports
cc-main-green.json              the main-green check's verdicts, per repo
cc-coach/                       per repo: <repo>.json (the run), .log.json, .lessons.json,
                                .applied.json, .memory-backup/; across repos: global.json,
                                global.claude-backup/; evidence-spend.json (today's evidence runs)
cc-scratch/                     scratch worktrees and runs (Seance's in cc-scratch/seance)
cc-keep/<project>/<session>.jsonl  kept transcripts of ★ projects, plus pins.json; --purge leaves it
```

`uninstall.sh`'s `STATE` list is the full inventory of what `--purge` removes.

## 10. UX & interaction model

- **Grid of tiles** (status, time-in-state, latest prompt, wants/why, context bar, badges such as
  HOLD / FROZEN, ⚠ main is red and the coach's 🧭 chip), with **grey cards** in their own row under
  the grid. Header: New, ☕ keep-awake, 🔒 lock, **❄ Freeze**, the ☰ views menu, ⚙ settings, theme.
- **☰ views menu:** 📥 Inbox, 🎫 Tickets, **📑 Queues**, 🔍 Filter sessions, 🔎 Find in fleet,
  📊 Fleet insights, 📜 Audit ledger (with 🗂 History), ⏰ Routines, 📝 Templates, ✦ Agents,
  🔌 MCPs & Skills, 🛡 Policy bundles, ⚙️ Automation rules, ⚡ Automation trace, **♻️ Restart
  fleet**, 💰 Cost & tokens, 🩺 Diagnostics, ✨ Features list, 📋 Shift report, 🔔 Notifications.
- **Detail panel** with a tab strip — Activity, Transcript, Rewind, Decisions, Usage, Changes
  (git status + diff), **User Stories** (gated on `spec/product/user-stories.md`), On purpose and
  Requirements (gated on a git repo), Agents, Queue — expensive tabs load on open; the ⋯ menu hides
  tabs and remembers your last-open tab per project. It also carries **Hold** (with the list of
  sends a hold skipped) and the **Seance** box (🔮 Ask).
- **🗂 History:** the ledger's sessions plus every past transcript and kept copy (📦 kept /
  📦 kept copy only), ★ to keep a project's transcripts, 🔮 Ask and ↻ Resume on each row.
- **Coach overlay** (from a card's 🧭 chip or a session's 🧭 Coach): the waiting suggestions (Apply,
  Skip with *Why skip?*, Bring back), memory rows (Delete it / Rewrite it, Undo), **Applied edits**
  (each one's verdict, **Sharpen**, Undo) and **Across repos**.
- **Fleet navigation:** search, groups + group chips, bulk Approve/Stop over the visible set.
- **Global hotkeys** (remappable): approve front, **jump-to-the-session-that-needs-you**, cycle,
  spawn, show/hide; a live legend so they never drift.
- **Worklist** (📋 My List): a built-in per-project + global checklist — items carry subject,
  details, a tickable sub-step checklist and an expected date, with a MASTER tab rolling every
  open item up by date priority across lists. A project tab adds **📘 Add a playbook…** and
  **▶ Run…** (pick items, then Run selected); a run's checkmark shows as **✓ by run**.
- **Keep the fleet alive:** ☕ caffeinate (holds with the lid closed) + 🔒 soft lock (blocks input
  while everything keeps running; force-unlock chord so a typo can't lock you out).
- **Remote (SSH bridge):** rsync-pulled remote `cc-status/` renders remote sessions as headless-
  only ⇄ tiles (approve/deny via nonce-bound decision files; keystroke actions disabled).

## 11. Capability ladder (shipped, retrospective)

Shepherd grew in levels; these are the milestones as built, not a forward plan.

| # | Capability |
|---|------------|
| **L0** | The core loop: hooks → status files → tiles → approve/deny/jump/stop/nudge. |
| **L1** | **Agent profiles** — spawn from a saved persona + provider/model + skills/MCP/knowledge/plugins. |
| **L2** | **Named policy bundles** — reusable per-session guardrail sets + attachments. |
| **L3** | **Task templates** — parameterized, versioned prompts; render-before-spawn/feed. |
| **L4** | **Declarative routing** — queue-line `@role`/`@all`/`@any`/`seq`; shared-folder backlog drain. |
| **L5** | **Session observability** — error cause, plan/TODO, subagent fan-out, run score, banners. |
| **L6** | **Event-callback rules** — react to a done/error/approval edge with log/relabel/nudge. |
| **L7** | **Scheduled routines** — cron/one-shot spawn or fleet digest. |
| **L8** | **Merge flow & the build program** (2026-09) — ready to merge, the tab bridge, batch driving on one approval, the test gate and merge checker, the session mailbox, tickets, restart in place, the worktree fence and leases. |
| **L9** | **Mining round 2** (2026-10) — Stop guards, grant grading, gate blame, main-green and main moved, hands-off hold, queue hold, the coach's ledger/evidence/memory/across-repos runs, Seance, kept transcripts and past sessions, playbooks and Run selected, grey cards, the fleet idle alert. |

The in-panel bundle, agent and template editors and the ⏰ Routines board have shipped. Deferred
(need a design call first): a routing topology view, role-addressed delegation/handoff,
idle/auto-spawn routing targets.

## 12. Risks & honest limits

1. **VS Code keystroke delivery is best-effort** — no supported injection API. Mitigated by
   Headless approvals (reliable) + Queue (reliable storage) + Kitty's `kitty @` path.
2. **Auto-actions could thrash** — respawn/continue are capped per launch folder, and budgets
   reset only after sustained healthy running; a session waiting on you is never auto-respawned.
3. **Stale/ghost tiles** after `/clear` — auto-pruned by matching old+new tiles to the same
   window; Forget tile is the always-safe manual escape.
4. **Usage is tokens, not dollars** — subscription is flat-rate; gateway/local pricing unknown.
   The $ figure is a labeled estimate; the plan-window % reflects the Anthropic account only.
5. **Remote Control widens the trust boundary** (on by default) — anyone on your claude.ai can
   type into a local shell; documented and toggle-able.
6. **Some features spend model tokens** — the merge checker, the coach and Seance run headless
   `claude -p`. Each run carries its own `--max-budget-usd` (§6), the coach's scheduled and evidence
   runs stay off until `coach.enabled`, and the evidence runs share a daily cap across repos.
7. **Stop guards read prose** — a guard can misread a turn's last message. Each blocks at most once
   per turn or commit, never in plan mode or on hold, and the session can answer it in one line and
   carry on; each switch is its own `stopGuards.*` key.

## 13. Verdict

Feasible and shipped on well-understood pieces (Hammerspoon, Claude Code hooks, a per-session
status file, a decision-file gate, `kitty @`, macOS Accessibility). The design's power is **where
state lives and who writes it**: hooks and Shepherd's scripts write their own files, the panel's
answers are nonce-bound files claimed with `mv`, and everything else is a read — no daemon, no DB,
crash-safe, inspectable. The one thing that stays fragile by nature is **keystroke delivery into
the VS Code extension**, which is why the reliable spine is **headless approvals + queues + the
session mailbox + Kitty remote control**. What acts on its own is named (§7): a few conveniences
with no config, and the author's defaults a fresh install writes. Detectors are **advisory not
enforcing**; the two things that hold work back, the Stop guards and grant grading, are named
decisions (D-22, D-18) that never touch another process. Shepherd claims outcomes only on evidence
it gathered itself (D-5), and the audit trail is **local** — so the tool earns trust before it
acts.
