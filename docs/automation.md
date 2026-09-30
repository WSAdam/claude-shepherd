# Automation

[← README](../README.md) · [Configuration](configuration.md) · [Controls](controls.md)

Each **automatic** behaviour on this page has a switch, in ⚙ Settings → Automation or in
`~/.claude/cc-config.json`. A fresh install turns four on: auto-continue, the **Respawn from cwd**
action, [resume at the limit reset](#resume-at-the-limit-reset) and
[auto-compact with notes](#auto-compact-with-notes). [Handoff notes](#handoff-notes) and the
[session mailbox](#session-mailbox) have no switch. Auto-feed, routing, auto-respawn, model
auto-routing, the self-summary, escalation, rules, routines and the weekly coach start off; their
keys are in [Configuration](configuration.md#editing-the-file-by-hand). The manual tools (Queue,
Feed next, templates, A/B compare, a routine's **Run**) work without a switch.

Automatic actions that type into a session are delivery-gated (a task leaves the queue only once
it reached the session's window), skip sessions whose window hosts other sessions, wait until the
session can take the text ([below](#when-automation-types)), and are recorded in the audit ledger.

## When automation types

Auto-feed, project routing, a rule's `nudge` or `continue`, auto-continue, the post-run
self-summary, the startup `/rc` sweep, a waiting [mailbox](#session-mailbox) message and the
`Continue` after a [fleet restart](fleet.md#restart-the-fleet-in-place) all type into a session
without you. Each one waits until the session can take it:

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

## Dry run and the automation trace

Every automatic action goes through one door, so you can see what automation would do before you
let it, and what it did while you were away. Your own clicks never go through it.

- **What counts.** Auto-continue, auto-feed, project routing, a rule firing (log, relabel, feed,
  nudge, continue), auto-respawn, the post-run self-summary, resuming at the limit reset (arming the
  hook, its typed line, its phone push), ending a tab-less leftover, a mailbox message (leaving it,
  and typing it into an idle session), the startup `/rc` sweep, and each session a
  [fleet restart](fleet.md#restart-the-fleet-in-place) reopens (with the `Continue` after it).
- **Dry run.** ⚙ Settings → Automation → **Dry run** switches it on for all automation
  (`automation.dryRun`) or for one feature at a time (`autoContinue.dryRun`, `queue.dryRun` for
  auto-feed and routing, `rules.dryRun`, `respawn.dryRun`, `summary.dryRun`, `resume.dryRun`,
  `tabless.dryRun`, `mailbox.dryRun`, `remoteControl.dryRun`, `restart.dryRun`). In a dry run Shepherd records what it
  would have done and does nothing: nothing typed, no task taken off a queue, nothing launched or
  ended, no message left, and a resume is planned as *skip* so the hook stops without waking the
  session. A typed action still waits until the session [can take it](#when-automation-types)
  first, so what's recorded is what would really have been typed; a refusal is still a refusal.
  A Settings Save keeps these switches; a fresh install has them off.
- **The trace.** ☰ → **⚡ Automation trace** lists every decision fleet-wide, newest first; the
  detail panel's **⚡ Trace** opens it for that session (the menu at the bottom switches sessions).
  Each row says when, **acted**, **would** (a dry run) or **refused** with why (`working`, `tool`,
  `no window match`, `not delivered`…), which automation, which session and what it does. The
  same decision repeated by the same automation on the same session collapses into one row with
  **×N** and the time it started; a different decision in between starts a new row. The trace keeps
  the last 500 distinct decisions since Hammerspoon loaded.
- **Ledger.** With the audit ledger on, each new row is also written once: `would_<kind>`
  (`would_continue`, `would_feed`, `would_route`, `would_rule`, `would_respawn`, `would_summary`,
  `would_resume`, `would_tabless_end`, `would_mailbox`, `would_rc`, `would_restart`) for a dry run, `automation`
  with `outcome` `acted` or `refused` (and `reason`) otherwise. Repeats bump the trace's count and
  aren't written again.

Outside a dry run nothing changes: each action does exactly what it did before, with the same
readiness and shared-window refusals.

## Task queue

Each session has a queue. **Queue** in the detail panel adds the input; **Feed next** sends the
front task; the tile shows `+N queued`. Turn on `queue.autofeed` and Shepherd feeds the next task
each time the session finishes, so a session works through a backlog unattended
(`queue.dryRun` records what it [would feed](#dry-run-and-the-automation-trace) instead of sending).

- **Delivery-safe**: a task leaves the queue only when the paste actually reached the session's
  window. No window match and it stays queued, and the ledger records `task_feed_skipped`.
- **Queues follow the project**, so a respawned or `/clear`-ed session inherits its folder's pending
  tasks.
- **Edit in place**: click "Queue: N" to expand the list, then reorder (▲▼) or remove (✕) entries.
  Each edit carries the task text you clicked, so if the queue changed underneath, the edit is
  refused and the list refreshed instead of moving the wrong task.
- **Bulk paste**: paste a multi-line list and press Queue. It splits into one task per line
  (bullets and numbering stripped, blanks dropped) after a confirm.

### Task packets

A task written against the code as it is today can send a session after lines that are gone by
the time it's fed. A **packet** carries its evidence, and isn't fed once that evidence has moved.

- **Save one**: **+ Packet** in the queue panel opens a form: the task, an optional title, the
  cited code (one `path:line` or `path:from-to` per line, relative to the repo root; up to 8
  ranges of up to 80 lines), repro steps and done-when. Shepherd reads each range at the
  session's HEAD in the background and saves the lines with that commit. A path that isn't in
  the repo, or a range past the end of its file, is refused with the reason.
- **Stored**: packets live in `~/.claude/cc-queue/<queue>.packets.json`, next to the queue file,
  written atomically. The queue holds a token in place of the text, `@packet:p3 <title>`, which
  can sit behind `@all:`/`@any:` and `@role:` like any task.
- **At feed time** (Feed next, auto-feed or the router), Shepherd re-reads every cited range at
  the **receiving** session's worktree HEAD, in the background. HEAD is read from the repo's
  files, so a commit the session made just before it finished is noticed at once.
  - Unchanged: the session gets the task, each cited range as it was read (with its commit),
    the repro and done-when. A packet isn't template-expanded.
  - Changed or gone: it isn't fed. The card says `📦 cited code moved: path:from-to`, the ledger
    records `packet_moved` once, and the packet stays at the head until you remove it (✕) or the
    code matches again. A queue that can't be read, or a packet that isn't saved, is flagged the
    same way.
  - Still being checked: the feed waits. Auto-feed tries again while the session stays done;
    Feed next goes through once the check lands.
- **Batches**: a unit in a batch file can name a packet (`"packet": "p3"`), one saved from a
  session in the repo's main checkout. Before its tab opens, Shepherd checks it at the repo's
  HEAD. If the cited code moved, `cc-fleet.sh tab` is refused with the reason; if not, the
  packet's evidence goes into the unit's message.
- A packet leaves the store once it is fed or its token is removed. A queue keeps at most 100
  packets; when it's full, the oldest one the queue no longer holds goes first.

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
  result, the files it touched, its errors, its open `TODO.md` lines (under **Next**) and the
  transcript's path. It's the same read that labels a finished card. **Next** lists the session's
  own items: the open lines it wrote to `TODO.md` itself (added or ticked, as far back as the read
  reaches). In a linked worktree, whose `TODO.md` is its unit's own list, every open line counts
  when it wrote none. In the main checkout, where `TODO.md` is the whole project's list, a session
  that wrote none gets no **Next**.
- **After `/clear`.** The fresh session is told, in one line, where the note of the conversation
  before it is. The note is found by the claude process (its pid and window; a kitty window for
  kitty), so another tab in the same window never gets it.
- **After a respawn.** Before relaunching, Shepherd writes the dead session's note to
  `~/.claude/cc-notes/pending/`, built fresh from its transcript, so a session that died mid-turn
  says so. The new session starts with the whole note, once. A note nobody takes within the hour is
  dropped, and a dry run leaves none.
- **A resumed or compacted session** keeps its own context and gets no note (it is still shown the
  [mailbox](#session-mailbox) messages waiting for it). A compacted session gets back the working
  notes it wrote itself instead ([auto-compact with notes](#auto-compact-with-notes)).
- **Cleanup.** Notes older than 14 days are pruned at startup and then hourly.

How it reaches the session: Claude Code adds a SessionStart hook's output to the new session's
context. `cc-status.sh` prints `cc_session_context` (`cc-lib.sh`) there: each part is labelled
`[Shepherd: <part>]` and the whole is capped at 8,000 characters. After a compaction, the session's
own notes have another 12 KB of their own on top.

### Auto-compact with notes

Claude Code compacts a session on its own near the end of its window, and the summary keeps only
what it keeps. With `compact.enabled` (⚙ Settings → **Auto-compact**; on in a fresh install's
defaults), sessions compact earlier, and write their own notes first.

- **When it compacts.** Shepherd sets `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in
  `~/.claude/settings.json` to `compact.atPct` (85 by default), so Claude Code compacts at that
  percent. Claude Code measures it against its auto-compact window, the window less a 20k output
  reserve: 85% is 153,000 tokens of a 200k window and 833,000 of a 1M one. It can only bring
  compaction earlier, never later than Claude Code's own point. Sessions started afterwards pick it
  up. The write (`FX.setClaudeSettingsEnv`) changes that one key and nothing else, atomically, and
  follows a symlinked settings file to its target. A file it can't read as JSON is left as it is,
  and 🩺 Diagnostics says the override is missing.
- **The notes.** Each live session gets `~/.claude/cc-notes/<session>.due-at`,
  `compact.notesLeadPct` points (5 by default) of the same window before compaction: 144,000
  tokens of 200k, 784,000 of 1M (an `[1m]` model counts as 1M). At the first turn end past it, the
  Stop hook asks the session, once per compaction cycle, to write its working notes to
  `~/.claude/cc-notes/<session>.notes.md`: the task and its goal, what's done and in progress, the
  exact next steps, the decisions and why, the files and commands involved. The card stays working
  while it writes them. It isn't asked while `stop_hook_active` is set (a block already kept that
  turn going), or in plan mode, where it can't write a file; the next turn end asks instead.
- **The compaction.** Every compaction (automatic or `/compact`) runs `cc-status.sh precompact`.
  Claude Code adds a PreCompact hook's output to the summary's instructions, so with notes saved the
  summary is told they come back whole and needn't repeat them.
- **Afterwards.** The compacted session starts with its notes, as `[Shepherd: notes]`, up to 12 KB;
  longer notes are cut with the file named for the rest. A cycle ends when the context drops below
  the due-at again, so a compaction that failed isn't asked for notes twice.
- **On the card.** 📝 means the session has notes. The detail panel's Notes line says when they
  were saved and when they're next due: *📝 Notes saved 5m ago (1.2 KB) · due at 144k tokens,
  compaction at 153k*.
- **Turning it off** takes Shepherd's own value back out of `settings.json` (a value you set
  yourself stays) and removes every due-at, so no session is asked for notes. Uninstalling leaves
  the override in `settings.json`; take it out of `env` by hand if you don't want it.
- **Diagnostics** checks that settings.json carries the override and that every installed claude
  still reads it: the CLI and the newest binary each editor extension bundles, grepped once per
  version in the background. A claude that no longer mentions `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is
  a warning: it may compact at its own threshold, after the notes are due.
- **Cleanup and the ledger.** A session's due-at goes when it ends or its card is forgotten; its
  notes stay, like its handoff note, and are pruned after 14 days. The ledger records
  `notes_requested` (with the tokens) and `compaction` (its trigger, and whether notes were saved).

## Session mailbox

Shepherd can leave a session a message instead of typing it into its window, so automation can
reach a session that is mid-turn, or one in a VS Code window it shares with other Claude tabs. The
entry point is `FX.mailboxSend(key, text, meta)`; [cc-send](#send-a-prompt-from-a-shell) is built
on it, and is the way to try it from a terminal.

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

## Send a prompt from a shell

`~/.claude/cc-send.sh` hands a live session a prompt from any shell -- a script, a cron job, a
terminal or another Claude session -- through the [session mailbox](#session-mailbox), and with
`--wait` prints its reply.

```bash
~/.claude/cc-send.sh claude-instance-manager "Run make test and tell me the count." --wait
reply="$(~/.claude/cc-send.sh ~/Programming/wgsUltra "Summarise what you changed today." --wait)"
```

- **The target.** A session: its key (the session id, its status file's name in
  `~/.claude/cc-status/`) or its name -- the one Claude Code gives it, which other sessions message
  it by, or its card's name. A project: its repo's root, a worktree's root, a folder inside one
  (`.` works), or its name. A project gets its best live session: an idle one before a busy one
  (then the most recently active), never one waiting on you (a question, a permission prompt, a
  merge, a batch proposal or an error on its card), never one that has ended or lost its tab, and
  never the session running the command (known by `CLAUDE_CODE_SESSION_ID`, or by its process
  after a `/clear`). A name that fits two sessions or two projects is refused with the choices
  listed: give a key or the repo root. A named session that can't take it is refused, saying why.
- **How it arrives.** Through the mailbox, as `[shepherd] Message from <sender> via cc-send #<id>`
  and then the prompt. A busy session gets it when its current turn ends and carries on with it; an
  idle session in a kitty window or a VS Code window of its own gets it typed once it's ready; an
  idle session in a VS Code window shared with other Claude tabs keeps it in its mailbox until its
  next turn end or start. cc-send says which, on stderr. Slash commands are refused, and a prompt
  is at most 3,500 bytes.
- **`--wait`.** Follows the session's transcript from the moment the prompt was sent until the turn
  that takes it ends, then prints that turn's last assistant text on stdout. Progress and errors go
  to stderr, so `$(…)` captures just the reply. `--timeout <seconds>` (default 1800) bounds the
  wait. A prompt handed over at a session's start is answered in that session's next turn.
- **Exit codes.** 0 sent (with `--wait`: answered) · 2 refused (the arguments, an empty prompt, a
  slash command, too long, no such folder) · 3 no session to send it to (none, ambiguous, waiting
  on you, ended, or yourself) · 4 `--wait` ran out · 5 no reply to print (the turn was interrupted
  or died on an API error, or there is no transcript to follow) · 6 Shepherd isn't running, or
  didn't take the request within 30 seconds (it is then withdrawn, so it can't arrive later).
- **Under the hood.** cc-send leaves a request in `~/.claude/cc-send/`; each tick Shepherd claims
  it, picks the session (`core.sendTarget`), hands it the prompt (`FX.deliverTo`) and answers with
  where it went and where to read the reply. A request goes with the session that made it, and
  anything left over is pruned after 10 minutes. The ledger records `send_delivered` (the session,
  the request id, the sender and the route) and `send_refused`, besides the mailbox's own
  `mailbox_sent`. With [dry run](#dry-run-and-the-automation-trace) on for the mailbox, nothing is
  delivered and cc-send says so.

## Cross-repo tickets

A session that needs something done in **another** repo -- a fix, a release, an answer only that
repo's sessions can give -- files a ticket with `~/.claude/cc-ticket.sh` instead of asking you to
carry the message. Shepherd hands it to a live session there, and the replies and the closing note
come back to the session that filed it.

```bash
id=$(~/.claude/cc-ticket.sh file --repo ~/Programming/parser --title "Bump to 2.x and tag a release" \
       --body "alpha's build needs parser 2.1 or later.")
~/.claude/cc-ticket.sh wait "$id"          # run it in the background: prints the next reply or the close
```

- **Filing.** `--repo` is a repo's root (or any folder in it, or one of its worktrees) or its name,
  looked up among the sessions Shepherd knows; a name two repos share is refused with both roots
  listed. A ticket is for another repo: a session's own repo is refused (hand one of your own
  sessions a prompt with [cc-send](#send-a-prompt-from-a-shell)). The title is one line of at most
  200 characters, the body at most 2,500 bytes. `file` prints only the ticket's id on stdout.
- **Who gets it.** Each tick Shepherd offers every open ticket to the target repo's least-busy
  live session: the one with the fewest tickets on its plate, then an idle one before a busy one.
  Never the filer, never a session waiting on you, one that has ended or lost its tab, or one that
  let this ticket lapse before. It arrives through the [session mailbox](#session-mailbox), marked
  `[shepherd] Ticket <id> from <filer> in <repo>`: a busy session gets it when its turn ends, an
  idle one gets it typed once it's ready, and one in a VS Code window shared with other Claude
  tabs keeps it in its mailbox until its next turn end or start (its card says a message is
  waiting, and the board says so too).
- **Taking it.** The session takes the ticket with `cc-ticket.sh take <id>` (which prints it),
  `reply` or `close`, within 45 minutes of the offer. Otherwise the offer lapses and Shepherd offers
  the ticket to another session. A ticket whose holder's session ends goes back as well, and is
  never offered to that session again.
- **Nobody to take it.** When no session of that repo can take it (none is open, or each is
  waiting on you), the ticket waits on that repo's card as **🎫 N** with **Open a tab for it**, and
  on the board. **Open a tab for it** opens a Claude tab in the repo's window with the ticket's
  `take` typed in, never sent: check it and press Return. Shepherd then leaves the ticket to that
  tab for 10 minutes.
- **Replies and the close.** `cc-ticket.sh reply <id> "…"` goes to the other side: the holder's
  replies to the filer, the filer's to the holder. `cc-ticket.sh close <id> --note "…"` closes it,
  and **closing always needs a note**: what was done, or why it isn't this repo's to do. The holder
  or the filer can close a ticket. Each side gets the other's news through its mailbox while it is
  live, at its next start (a `[Shepherd: tickets]` part) when it isn't, or from a
  `cc-ticket.sh wait <id>` it has running. While a `wait` runs, Shepherd leaves that side's news to
  it, so nothing arrives twice.
- **☰ → 🎫 Tickets.** Every ticket, fleet-wide: the ones no session can take first, with **Open a
  tab for it**, then the open, offered and held ones, then the closed ones with their notes, for a
  week. The menu item counts the tickets waiting.
- **Commands.** `file`, `take`, `reply`, `close`, `wait [--timeout <seconds>]` (default 3600),
  `show <id>` (the whole ticket) and `list` (the tickets this session filed or holds, and the ones
  waiting for its repo). Every command must run inside a Claude Code session. Exit codes: 0 done ·
  2 refused (the arguments, a closed ticket, your own repo) · 3 not yours (another session holds it
  or has been offered it, or you filed it) · 4 `wait` ran out · 5 no such ticket.
- **Under the hood.** A ticket is `~/.claude/cc-tickets/<id>.json`. Every writer changes it the
  same way: the CLI, SessionStart, both removers and Shepherd each claim the file by renaming it,
  write the changed ticket whole into place, then drop the claim. When two writers race, one
  rename wins and the others wait their turn. Delivery is cc-send's `FX.deliverTo`. A session that
  ends puts back the tickets it held, and keeps the ones it filed for its next start. Closed tickets
  are pruned after a week, and any ticket after 30 days. The ledger records `ticket_filed`,
  `ticket_taken`, `ticket_reply`, `ticket_closed`, `ticket_offered`, `ticket_reclaimed`,
  `ticket_news` and `ticket_tab`. With [dry run](#dry-run-and-the-automation-trace) on for the
  mailbox, nothing is handed over and the ticket waits.

## Resume at the limit reset

A session stopped by a usage limit (*You've hit your session limit · resets 3pm*) carries on by
itself when the limit resets, once per window. Its card says **resumes at 3:00pm**, with
**Resume now** and **Cancel**. While it waits the card is a **Heads-up**, not a red Needs you:
Shepherd does the waiting. It needs you again once the reset has passed and the session still
sits, when its process is gone, or when nothing is scheduled (the cases under *Not resumed*).

- **The hook.** A turn stopped by a usage limit fires StopFailure with the error `rate_limit`.
  `cc-resume.sh` runs in its own StopFailure group (matcher `rate_limit`) as a background hook
  (`async` and `asyncRewake`, with an 8-day timeout). It writes `~/.claude/cc-resume/<session>.json`
  and waits. When the reset comes it prints *[shepherd] The usage limit has reset: continue the
  task.* and exits 2, which Claude Code hands to the model. It checks the session's claude process,
  its arm and the card's Cancel every 15 seconds, and stops if any of them is gone. It fires 15 to
  75 seconds after the reset, so a whole fleet doesn't wake in the same second.
- **When it resets.** Shepherd plans each arm once and writes `<session>.plan.json`, bound to the
  arm's nonce. It uses the plan meter's `resets_at` for the full window (the session or weekly
  bar), else the time in the error (`core.parseResetTime`: *3pm*, *3:30pm*, *Oct 3, 9am*, read in
  this Mac's own time zone, which is the one Claude Code printed).
- **Once per window.** Each session is resumed at most once per window (the limit plus its reset
  time). The attempts are kept in Hammerspoon's settings, so a reload doesn't forget them. A resumed
  session that hits the limit again is not armed again until one of its turns ends cleanly: a
  clean Stop clears the arm, and a limit ends a turn in StopFailure, never Stop. So it can't loop.
- **Not resumed.** A per-model limit (*You've hit your Opus limit*) says **Opus limit — switch
  model** instead, since the whole-plan reset doesn't lift it. A kitty or terminal session is left
  to Claude Code's own `autoContinueAtUsageLimit`, which waits for the reset itself. Claude Code
  treats that setting as on when it isn't set, so Shepherd resumes a terminal session only when
  `~/.claude/settings.json` sets it to `false`. A reset more than 8 days out isn't waited for, and
  `resume.enabled: false` turns the whole thing off.
- **If the session doesn't wake.** Whether the hook's exit 2 wakes a session that is sitting
  idle has not been verified, so Shepherd checks again 2 minutes after the reset. A session that
  is working again is left alone. One still stopped gets the same line typed where typing is
  allowed: a kitty window, or a VS Code window with just this one Claude tab, once the session is
  ready ([when automation types](#when-automation-types)). In a VS Code window shared with other
  Claude tabs nothing is typed: the card says **limit reset — continue it**, and your phone gets
  a push on `escalation.pushTopic`. The plan records what was done, so nothing is typed or pushed
  twice.
- **Resume now and Cancel.** **Resume now** moves the reset to now: the hook fires at its next
  check, and the typed fallback follows 30 seconds later if the session still sits. **Cancel**
  leaves the hook a `<session>.cancel` file and it stops.
- **Cleanup.** A clean Stop, the session's end, or its card being forgotten or pruned removes its
  files. The ledger records `resume_planned` (with the verdict and why), `resume_typed`,
  `resume_notified`, `resume_resumed`, `resume_now` and `resume_cancelled`.

## Escalation and watchdogs

- **Escalation** (`escalation.enabled`): when an approval waits longer than `escalation.minutes`,
  nag harder: a stronger tile pulse, plus an optional `sound` and an optional high-priority `push`
  to your [ntfy](https://ntfy.sh) `pushTopic`.
- **Stuck-session watchdog** (`escalation.hung.enabled`, file only): a session that stays
  `working` with no transcript growth for `escalation.hung.minutes` gets ⏳ and a purple ring, and
  nags once per stall with the same sound and push settings. A single tool call that is still
  running gets up to `escalation.hung.toolMinutes` (default 30) before it counts.
- **Loop watchdog** (`escalation.loop.enabled`): a ⟳ badge when a working session keeps repeating
  the same tool call. A command is the same by its command line, a read by its file and the chunk
  of it that was asked for (a long file read in three chunks is three reads), and an edit only
  when it writes the same thing to the same file. Detection only.
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
  [policy attachments](approvals-and-policies.md#named-policy-bundles)), `group`, `sessionKey` and
  `provider` (a provider profile's `id`: the profile the session's model, and for a gateway its
  base URL, belong to); absent means fleet-wide.
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

## The coach

The coach turns the corrections you keep making into edits to the repo's `CLAUDE.md`, the
instructions every session in it reads first. It suggests; nothing changes until you click.

- **What it reads:** the repo's last 10 sessions (the main checkout's and every
  `.claude/worktrees/<slug>`'s transcripts, newest first): your corrections (every prompt after a
  session's first), your interrupts, tool errors, tool calls you denied with a note, and **Not
  yet** notes. Shepherd adds what transcripts don't hold: your **Not yet** notes on merge requests,
  blocked merges' notes, and merge-checker fails and findings, from its own log
  (`~/.claude/cc-coach/<repo>.log.json`, three weeks, 40 entries). The digest is capped at about 30KB;
  the repo's `CLAUDE.md` and `DECISIONS.md` go in on top.
- **How it runs:** a headless, read-only Sonnet (the [merge checker](merging-and-batches.md#the-checker-a-read-only-review-of-every-merge-request)'s
  runner: hooks off, no MCP, no tab) in the repo's main checkout, at `coach.maxBudgetUsd` (default
  $1). It shares the checker's one-run-per-repo lane, and never starts while that repo's checker is
  queued or running: it waits, and starts once the checker is done.
- **What it suggests:** up to 5 `CLAUDE.md` edits, each with its section, why, what sessions do
  today and what they are expected to do once it is applied (**Today** / **Expected after**, so you
  can judge later whether it worked), the text it replaces (or where an addition goes) and the
  evidence behind it, plus up to 3 `DECISIONS.md` entries for
  choices sessions keep "fixing". It never proposes undoing a [DECISIONS.md](fleet.md#on-purpose-tab)
  entry. An answer with no usable JSON is **couldn't run**; "nothing to change" is an answer too.
- **When:** from any session's **🧭 Coach** button (the detail panel) for its repo, at any time;
  and weekly for every repo with a card, when `coach.enabled` is on (default off). The weekly run
  is due once `coach.day` (default `mon`) has passed since the last run, so a Mac that slept
  through Monday catches up when it wakes, and only when a session ran since. A couldn't-run counts
  as that week's run. A Hammerspoon reload kills a run in flight: it reads **lost**, never counts
  as a verdict, and is retried 15 minutes later (up to 3 times).
- **Reviewing:** suggestions wait behind a **🧭 N** chip on the project card; click it for the
  Coach overlay. **Apply** writes the edit into `CLAUDE.md` and commits that file alone
  (`git commit -- CLAUDE.md`, a plain message: `CLAUDE.md: <section>` and the why), leaving
  anything else you have staged as it was. It's refused, and says why on the edit, when
  `CLAUDE.md` changed since the coach read it (its hash) or has uncommitted edits, when the
  text the edit replaces isn't in the file exactly once (line wrapping and spacing don't count: a
  paragraph the coach quoted on one line is found in its wrapped lines, and the file's own lines
  are left as they are), or when `CLAUDE.md` is a link (edit its target by hand). If a hook refuses the commit, `CLAUDE.md` goes back as it
  was. An edit refused because `CLAUDE.md` changed gets **Run the coach again** next to Skip: a
  fresh run reads the file as it is now and replaces the suggestions (the same for a `DECISIONS.md`
  entry whose file changed). No other refusal offers it. Applying one edit doesn't block the next. **Skip** puts one aside. A `DECISIONS.md` entry is
  added through the On purpose tab's own guard, not committed. While it runs, the overlay counts how long it has been reading and says when it gives up
  (`coach.timeoutSeconds`, default 10 minutes). A quiet chip shows while the coach
  reads or waits, and **🧭 ⚠** when its last run couldn't run (the overlay says why, with **Run the
  coach again**).

- **History and Undo:** every applied edit is also kept in the repo's history
  (`~/.claude/cc-coach/<repo>.applied.json`, the newest 100), which the next coach run doesn't
  replace. The overlay lists them under **Applied edits**, newest first: when, its commit, what it
  was expected to change, and the text before and after. **Undo** reads `CLAUDE.md` before and
  after that commit from git, takes the lines it added back out of the file as it is now (and puts
  back the lines it removed), and commits `CLAUDE.md` alone as `CLAUDE.md: undo <section>`. It is
  one more commit; nothing is rewritten, and later edits stay. It's refused, and says why on the
  entry, when `CLAUDE.md` has uncommitted edits, when those lines aren't in the file exactly once
  any more (undo it by hand with `git revert`), or when the commit is no longer in the repo.

```json
{ "coach": { "enabled": true, "day": "mon", "maxBudgetUsd": 1, "timeoutSeconds": 600 } }
```

Its records live in `~/.claude/cc-coach/`, one per repo; `uninstall.sh --purge` removes them.

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
