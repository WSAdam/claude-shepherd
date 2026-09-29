# Automation

[← README](../README.md) · [Configuration](configuration.md) · [Controls](controls.md)

Every **automatic** behaviour on this page is **off until you turn it on**, in ⚙ Settings →
Automation or in `~/.claude/cc-config.json`; the manual tools (Queue, Feed next, templates, A/B
compare, a routine's **Run**) work without a switch. Automatic actions that type into a session are delivery-gated (a task
leaves the queue only once it reached the session's window), skip sessions whose window hosts other
sessions, wait until the session can take the text ([below](#when-automation-types)), and are
recorded in the audit ledger.

## When automation types

Auto-feed, project routing, a rule's `nudge` or `continue`, auto-continue, the post-run
self-summary, the startup `/rc` sweep and a waiting [mailbox](#session-mailbox) message all type
into a session without you. Each one waits until the session can take it:

- **Never mid-turn**: not while the session is working, waiting on an approval or on a question
  Shepherd holds, or running a tool.
- **Settled**: at least 3 seconds after the session's last status change. A send on a turn that
  just ended waits out the rest; it isn't dropped.
- **One at a time**: at most one automatic send queued per session. When two fire on the same turn
  end (auto-feed and the self-summary, say), the first goes and the second is refused.
- **Kitty**: right before typing, Shepherd reads the window (`kitty @ get-text`) and types only
  into an empty composer. A dim prompt suggestion counts as empty; your half-typed text, an open
  menu or picker, the session survey or the trust dialog refuse the send, and so does a screen it
  can't read. The text and its Return go as two writes, so Claude Code submits the text instead
  of taking it as a paste.
- **VS Code**: only a window with one Claude tab is typed into at all
  ([shared windows](controls.md#sessions-that-share-a-window)); the status checks above apply.

The checks run when the sender fires and again right before the keys go out, against the live
status file, so a turn that started in between is caught.

A refused send records one `typing_refused` event in the ledger: `by` names the sender, `reason`
says why (`working`, `approval`, `question`, `tool`, `queued`, `composer`, `menu`, `trust`,
`no composer`). Shepherd then leaves that session alone until its status changes, instead of trying
again every second. What happens to the send depends on the sender: a queued task stays queued for
the next turn end, routing picks another free session, the self-summary tries again after the next
turn, and a rule's nudge or continue is skipped (`nudge_skipped` / `continue_skipped` with the
reason). A nudge rule on a `hung` or `loop` edge fires while the session is still working, so it is
always refused.

Your own clicks (Nudge, Feed next, Continue and the rest) aren't gated: when you act, it types.

## Task queue

Each session has a queue. **Queue** in the detail panel adds the input; **Feed next** sends the
front task; the tile shows `+N queued`. Turn on `queue.autofeed` and Shepherd feeds the next task
each time the session finishes, so a session works through a backlog unattended
(`queue.dryRun` logs instead of sending).

- **Delivery-safe**: a task leaves the queue only when the paste actually reached the session's
  window. No window match and it stays queued, and the ledger records `task_feed_skipped`.
- **Queues follow the project**, so a respawned or `/clear`-ed session inherits its folder's pending
  tasks.
- **Edit in place**: click "Queue: N" to expand the list, then reorder (▲▼) or remove (✕) entries.
  Each edit carries the task text you clicked, so if the queue changed underneath, the edit is
  refused and the list refreshed instead of moving the wrong task.
- **Bulk paste**: paste a multi-line list and press Queue. It splits into one task per line
  (bullets and numbering stripped, blanks dropped) after a confirm.

### Prompt templates

**Tpl ▾** next to Queue saves the current input as a named template and inserts saved ones back into
the input (it never auto-sends). The **📝 Templates** editor (☰ menu) creates, edits, renames and
deletes them. Templates live in `~/.claude/cc-templates.json`.

- **Variables**: a body can carry `{{name}}` (required) and `{{name?}}` (optional). Picking a
  template opens a fill-in form (required variables gate Insert). The built-ins fill themselves:
  `{{date}}` / `{{today}}`, `{{now}}` and `{{prev_output}}` (the selected session's latest output).
- **Structured or raw**: a template is a description plus an optional expected output, or raw text.
- **Before a spawn**: the New session dialog's **Templates** picker seeds the initial task, with
  variables filled in first.
- **Before a feed**: queued tasks are rendered just before they're typed in (manual, auto-feed or
  routed): `{{prev_output}}` (the turn that just finished) and the date built-ins resolve; variables
  that can't be filled automatically are left as they are.
- **Versions**: every save keeps the previous body and bumps the version (a `v2` chip marks edited
  templates). **Versions (N)** in the editor lists them, with a non-destructive **Revert to this**.
- **Import a folder**: **Tpl ▾ → ⤓ Import from prompts folder…** pulls `*.prompt` / `*.md` files (an
  optional `--- name: … ---` front-matter block plus the body) from `templates.sourceDir` (default
  `~/.claude/cc-prompts`). Local disk only.

### Project routing

With `queue.routing.enabled` on **and** a project armed with the detail panel's **route** toggle,
the project's queue feeds **whichever of its sessions is free** (Ready, sitting at its prompt), not only the
one that emptied its own backlog, so parallel sessions in one folder drain a shared backlog. One
feed per project per second, delivery-gated, ledgered as `by:"router"`. `starveMinutes` flags a
project whose tasks wait with no free session (⌛).

Routing reads a prefix on each queue line (stripped before the task is typed, so the session never
sees it):

- **`@role:`**: a task prefixed `@review: …` goes only to a free session whose **group** is
  `review`. Unprefixed tasks go to anyone free.
- **`@all:` / `@any:`**: a join barrier. `@all: …` waits until **every** session in the project has
  finished before it routes; `@any:` waits for one. It composes with a role: `@all: @review: ship`.
- **seq**: the detail panel's **seq** toggle (next to **route**) runs a project's queue **one routed
  task at a time**. Off, tasks spread across free sessions in parallel.
- **Timing**: each routed or queued task is timed from feed to completion; the Shift report shows
  tasks completed with average and total duration (needs the ledger).

## Model auto-routing

Per session, off by default. Tick **Auto-model** in the detail panel (shown with **Model controls**)
and each queued, auto-fed or routed task picks a model by how hard it looks, sending `/model <id>`
just before the task:

- **hard** (default `opus`) when the task has a "hard" keyword (refactor, debug, migrate, security,
  race condition and the like), or is 40 words or more;
- **cheap** (default `haiku`) when it has a "cheap" keyword (typo, rename, lint, bump, changelog and
  the like), or is 6 words or fewer;
- **standard** (default `sonnet`) otherwise.

A hard keyword wins over a cheap one. The full keyword lists are `core.AUTOMODEL_DEFAULTS` in
[cc-core.lua](../cc-core.lua).

It switches only when the chosen tier differs from the model already running, never on a direct
Send, and only in a local, native-Anthropic session in VS Code or Cursor (a terminal's `/model` is an
interactive picker). Tune it with `automodel.models.{cheap,standard,hard}`, `automodel.cheapMax`,
`automodel.hardMin`, `automodel.cheapWords` and `automodel.hardWords`. The switch itself is
per-session only (`~/.claude/cc-automodel/<key>`).

## Auto-respawn and auto-continue

- **Respawn** (`respawn.enabled`, on in a fresh install): a right-click **Respawn from cwd** action
  that relaunches a dead or stale session from its last working directory with the matched provider
  and editor. The new session starts with the dead one's [handoff note](#handoff-notes).
- **Auto-respawn** (`respawn.auto.enabled`): a session whose status file freezes **mid-turn** (status
  `working` with no hook write for `respawn.auto.staleSeconds`, default 600, well above the longest
  tool call) is relaunched, capped by `respawn.auto.maxRetries` **per launch folder** (per window
  for Kitty sessions). The budget
  resets only after sustained healthy running, so a crash-looping folder can't thrash. A session
  waiting on an **approval is never auto-respawned**; that's the escalation's job.
- **Auto-Continue** (`autoContinue.enabled`, ⚙ Settings, on in a fresh install): when a tile shows
  the magenta **Error** state, after `autoContinue.delaySeconds` (default 60) Shepherd types
  `continue`, capped by `autoContinue.maxAttempts` **per launch folder** (per window for Kitty;
  default 3). The budget resets on a turn that changed something, so a dead connection can't loop.
  It resumes the *same* session instead of relaunching it.
- **Back-off** (`autoContinue.backoff.startSeconds`, default 120; `autoContinue.backoff.maxSeconds`,
  default 1800): a turn whose [label](fleet.md#statuses) is **did nothing** or **only planned**
  doesn't reset the budget, and counts toward a streak kept per launch folder (per window for
  Kitty). From the second such turn in a row, the next continue waits 2 minutes instead of the
  grace delay, then 4, 8, 16, and at most 30. The card reads **backing off · 4m** while it waits.
  Your own prompt (a **Continue** click included) restarts the streak, and so does a turn that made
  progress or finished something (a `TODO.md` line or a commit). The same wait holds a rule's
  `continue` ([rules](#automation-rules)), which is dropped if the session starts a turn meanwhile.
  `startSeconds: 0` turns the back-off off.

Each automatic action records an `outcome` in the ledger, and a death that can't be respawned is
logged instead of failing silently.

### Handoff notes

A fresh or respawned session picks up where the last one left off.

- **The note.** Each time a session finishes a turn, Shepherd writes
  `~/.claude/cc-notes/<session>.handoff.md` from the transcript: how the turn ended, the last
  result, the files it touched, its errors, the worktree's open `TODO.md` lines (under **Next**) and
  the transcript's path. It's the same read that labels a finished card.
- **After `/clear`.** The fresh session is told, in one line, where the note of the conversation
  before it is. The note is found by the claude process (its pid and window; a kitty window for
  kitty), so another tab in the same window never gets it.
- **After a respawn.** Before relaunching, Shepherd writes the dead session's note to
  `~/.claude/cc-notes/pending/`, built fresh from its transcript, so a session that died mid-turn
  says so. The new session starts with the whole note, once. A note nobody takes within the hour is
  dropped, and a dry run leaves none.
- **A resumed or compacted session** keeps its own context and gets no note (it is still shown the
  [mailbox](#session-mailbox) messages waiting for it).
- **Cleanup.** Notes older than 14 days are pruned at startup and then hourly.

How it reaches the session: Claude Code adds a SessionStart hook's output to the new session's
context. `cc-status.sh` prints `cc_session_context` (`cc-lib.sh`) there: each part is labelled
`[Shepherd: <part>]` and the whole is capped at 8,000 characters.

## Session mailbox

Shepherd can leave a session a message instead of typing it into its window, so automation can
reach a session that is mid-turn, or one in a VS Code window it shares with other Claude tabs. The
entry point is `FX.mailboxSend(key, text, meta)`; nothing in the panel sends mail yet (the
automation built on it comes later). To try it from a terminal, with the session's key (its status
file's name in `~/.claude/cc-status/`):

```bash
hs -c '_G.__ccDashboard.fx.mailboxSend("<session key>", "Summarise what you just did.")'
```

- **Where it waits.** `~/.claude/cc-inbox/<session>/`, one file per message, named
  `<time>-<order>-<nonce>.msg` and written whole. Its first line is marked `[shepherd]`. A slash
  command is never sent, and never handed over.
- **At the next turn end.** When the session finishes a turn, its Stop hook hands over the oldest
  waiting message: it blocks the stop with the message as the reason, so the session carries on
  with it and its card stays working. One message per turn end. The turn that message started ends
  normally: Claude Code marks that stop `stop_hook_active`, and Shepherd never blocks one of those,
  so a message can't loop.
- **At the next start.** A resumed or compacted session is shown every message still waiting,
  oldest first, as `[Shepherd: mailbox]` in its context, up to 2,000 characters. A message that
  doesn't fit waits, whole, for the turn end.
- **An idle session.** A session sitting at its prompt gets the message typed, as one line, where
  typing is allowed: a kitty window, or a VS Code window with just this one Claude tab, once the
  session is ready ([when automation types](#when-automation-types)). In a VS Code window shared
  with other Claude tabs nothing is typed: the card says **1 message waiting** until the session's
  next turn end or start takes it. A paste that doesn't land puts the message back.
- **Delivered once.** Whoever hands a message over first (the Stop hook, the SessionStart hook or
  the typed nudge) claims it by renaming its file. A file whose body doesn't carry the nonce in its
  name is left alone.
- **Cleanup and Diagnostics.** A session's inbox goes when the session ends, or when its card is
  forgotten or pruned. 🩺 Diagnostics counts the messages waiting, per session. The ledger records
  `mailbox_sent` and `mailbox_delivered` (`via`: `stop`, `start` or `typed`).

## Escalation and watchdogs

- **Escalation** (`escalation.enabled`): when an approval waits longer than `escalation.minutes`,
  nag harder: a stronger tile pulse, plus an optional `sound` and an optional high-priority `push`
  to your [ntfy](https://ntfy.sh) `pushTopic`.
- **Stuck-session watchdog** (`escalation.hung.enabled`, file only): a session that stays
  `working` with no transcript growth for `escalation.hung.minutes` gets ⏳ and a purple ring, and
  nags once per stall with the same sound and push settings. A single tool call that is still
  running gets up to `escalation.hung.toolMinutes` (default 30) before it counts.
- **Loop watchdog** (`escalation.loop.enabled`): a ⟳ badge when a working session keeps repeating
  the same tool call. Detection only.
- **Desktop banners** (`notifications.banner.onApproval` / `onDone` / `onAutoApproved`): a macOS
  notification when a session starts needing you, finishes, or **auto-approves** a tool (that last
  one needs the audit ledger and can lag a second or two). Click it to jump to the session.
- **Focus pop** (`focus.popOnComplete` / `focus.popOnApproval`): bring the detected VS Code or
  Cursor window forward when a session finishes or needs approval. The hooks call
  [cc-popup.sh](../cc-popup.sh), which acts only when the flag is on (a legacy `focus.popEditor`
  still seeds both). The Claude Code extension may raise its own window on completion
  independently of this.

## Drain and tile cleanup

- **Drain** (`drain.enabled`): a right-click **Drain (finish turn, then close)** action that waits
  for the current turn to finish, then closes the session.
- **Tile cleanup**: `prune.hours` auto-deletes tiles idle that long (0 = never, the default).
  `cleanup.idleHours` decides which sessions **Select finished** checks in Instances
  ([Fleet](fleet.md#clearing-finished-sessions)). A stale tile with no `session_id` (an orphan from a
  broken hook) is always cleaned up.

## Post-run self-summary

Off by default (`summary.enabled`). When a session finishes a turn, Shepherd types a brief
"summarize what you just did" prompt into it, for the log you're watching; the prompt forbids
further edits. It fires once per turn (the summary's own completion is skipped so it can't loop),
local sessions only.

## Automation rules

Rules react to a session event with a safe action, a lighter per-session complement to the fleet
automations above. Create and edit them in **⚙️ Automation rules** (☰ menu), which writes
`~/.claude/cc-rules.json`. The engine's master switch is `rules.enabled` in `cc-config.json`
(default off). A rule is
`{name, enabled?, trigger:{kind, match?}, processor:{kind, text?, label?}, once?}`:

- **enabled** (default true): switch one rule off without deleting it.
- **trigger.kind**: `done`, `error`, `approval`, `hung`, `loop` or `starved` (the fresh edge).
  `hung`, `loop` and `starved` fire only while their detectors are on (`escalation.hung.enabled`,
  `escalation.loop.enabled`, and routing with `starveMinutes` above 0).
- **trigger.match** (optional): globs on `project` (the encoded project key, as in
  [policy attachments](approvals-and-policies.md#named-policy-bundles)), `group` and `sessionKey`;
  absent means fleet-wide. (A `provider` match doesn't work yet: sessions don't carry the field it
  compares.)
- **processor.kind**: `log` (write an audit note), `relabel` (rename the tile to `label`), `nudge`
  (type `text` into the session through the same delivery-gated path as a manual nudge, once it
  [can take it](#when-automation-types)), `feed` (add `text` to the session's project queue, for
  auto-feed or routing to deliver) or `continue` (resume an errored turn; held by
  [auto-continue's back-off](#auto-respawn-and-auto-continue) after turns that change nothing).
- **once**: fire at most once per rule per tile, until Hammerspoon reloads.

```json
{ "name": "flag-prod-errors", "trigger": { "kind": "error", "match": { "group": "prod" } },
  "processor": { "kind": "relabel", "label": "⚠ prod error" }, "once": true }
```

Every firing is ledgered as `by:"rule"`.

## Routines

Routines fire the normal spawn or digest effects on a schedule. They are not a second executor, and
a scheduled spawn still respects `spawn.live`. Manage them on the **⏰ Routines** board (☰ menu),
which writes `~/.claude/cc-schedules.json`. The board shows each routine's action, schedule and next
run, with **Run** (now), **Pause / Resume**, **Edit** and **Delete**. New routines are saved paused.

- **Recurring** routines use a standard 5-field cron expression (`min hour dom month dow`, with `*`,
  ranges, lists and `*/step`); the board's pickers fill it in. **Once** routines fire at a set time
  and delete themselves.
- **Spawn a session** launches a session in a folder with an editor, provider, permission mode and
  prompt.
- **Push a shift-report digest** pushes a fleet shift report over a window through ntfy (a
  `pushTopic`, or the escalation topic); it needs no folder.
- The master switch is `schedules.enabled` in `cc-config.json` (default off). While the fleet is
  at `schedules.maxConcurrent`, a recurring run is skipped (it's retried only within its own
  minute) and a once-routine waits. **Run** works while the switch is off. Each firing is ledgered
  as `schedule_fire`.

```json
{ "name": "nightly-tests", "kind": "cron", "cron": "0 2 * * *", "folder": "/path/to/repo",
  "prompt": "run the full test suite and summarize failures", "enabled": true }
```

## A/B compare

Run the same task as 2–4 variants and keep the best one. Right-click a tile → **⚖ A/B
fork-to-compare…** opens the A/B dialog with that tile's folder filled in (you can change it).

- **New run**: a repo folder (a git repo), a base task, a permission mode, and one row per variant:
  a label, a model and/or provider, and an optional prompt override.
- **Launch**: one git worktree per variant beside the repo (`.cc-ab/<repo>-<cohort>-<label>` in the
  repo's parent folder), on branch `ab/<cohort>/<label>`, then one VS Code session per variant. If
  creating a worktree fails, the worktrees and branches already made are rolled back. Cohorts are tracked in
  `~/.claude/cc-ab.json`.
- **Compare**: each variant shows its model, run score (needs the ledger), live status and activity;
  the top scorer is marked **★ lead**.
- **⚖ Judge**: pastes a judging prompt built from each variant's recent output into the first live
  variant's session; the verdict appears there.
- **Keep this**: after a confirm, closes the other variants' tiles, removes their worktrees and
  branches, and keeps the winner's worktree and branch for you to merge. A cohort you never keep
  leaves its worktrees behind; remove them with `git worktree remove` / `git worktree prune`.
