# The fleet panel

[← README](../README.md) · [Controls](controls.md) · [Usage and cost](usage-and-cost.md)

What the panel shows: statuses, project cards, the Instances view, the detail panel and its tabs,
search and groups, and My List.

![The panel with six sessions](img/panel.png)

## Statuses

| Status     | Card says         | Colour          | Set by                       | Meaning                                  |
|------------|-------------------|-----------------|------------------------------|------------------------------------------|
| `idle`     | Idle              | gray            | SessionStart                 | Session open, nothing happening yet      |
| `working`  | Working           | amber           | UserPromptSubmit, Pre/PostToolUse | Claude is doing work                |
| `approval` | Needs you         | red (pulsing)   | PermissionRequest, Notification (permission), AskUserQuestion | Claude needs a permission or your answer |
| `done`     | Ready for you     | green           | Stop, Notification (idle)    | Claude finished its turn                 |
| `error`    | Needs you, or Retrying | red, or gray while retrying | StopFailure, and the transcript | The turn died on an API error or a usage limit |

Instances rows and the Stream Deck show an errored session as **Error** in magenta.

- Sessions are keyed by their **session_id**, so two sessions in one folder never collide into one
  tile. A tile goes away when its session ends (SessionEnd).
- **Needs you** is one decision: a card ranks as needing you only when a live counterpart will
  receive your answer *and* the card offers something that changes the outcome (an approval, a
  held question, a merge to review, a batch to approve, a blocked unit, an errored turn to
  Continue). Anything else is a quiet
  **Heads-up** with one line saying why (see
  [Merging and batches → The card](merging-and-batches.md#the-card)).
- A working session waiting inside one tool for over a minute says which tool and for how long
  (*Working - Bash 9m*), so a long build reads as work.
- A done or idle session with live subagents or a Workflow reads **Running N agents**, one with a
  background shell job still going reads **Running 1 job** (both: *Running 2 agents · 1 job*), and
  a batch driver whose units are working reads **Driving N units**. The underlying status is unchanged;
  this is display only.
- A **Ready for you** card says how its last turn went, read from the transcript since the newest
  prompt: **done** (a `TODO.md` line ticked to `[x]`, or a commit), **made progress** (edits,
  commands that change things, test runs), **only planned** (it only read, or explained at
  length), **did nothing**, **blocked** (it stopped on a denial or an API error) or **needs
  follow-up** (it asked you, put up a plan, or ended on a question). Its Instances row says the
  same, and the ledger records a `turn_outcome` event. What Shepherd sends on its own
  (auto-continue, a rule's nudge or continue, the self-summary) starts with `[shepherd]`, so those
  turns never read as yours; your own **Continue** click still types a plain `continue`. Task
  notifications and compaction summaries don't count as prompts either. A batch unit, which only
  ever gets its driver's messages, is labelled from the newest of those. When the turn's prompt is
  further back than the last 256KB of the transcript, the label covers that whole 256KB.
- A `done` tile **self-heals back to `working`** when the transcript shows the turn resumed (the
  model wrote a new line, or you typed a fresh prompt). In Auto mode or the VS Code extension, a
  text-only reply or an auto-continued turn can land before the `working` hooks do, so a tile no
  longer sticks on "Ready for you" while it's working (`status.resumeSlack`, default 2s). IDE
  file-open lines are ignored, so opening a file never flips it.
- An **errored** tile (a turn frozen on an API error such as `ECONNRESET`) shows the error with a
  coarse cause: `[budget exceeded]`, `[timeout]`, `[runtime error]`, `[model error]`,
  `[user cancelled]`. It reads **Needs you**, and its Approve button becomes **Continue**. A
  transient connection fault the session is still retrying reads **Retrying** (a heads-up) for up
  to 75 seconds before it goes red. A usage limit reads `[budget exceeded]` with Claude Code's
  message, which names the reset time (*You've hit your limit · resets 3pm*), and auto-continue
  skips it: continuing only fails again until the limit resets.
- Only a genuinely idle card **dims**, once its status file is more than 90 seconds old. A card
  waiting on you, a quiet "Ready for you" and a heads-up never dim.
- Each tile shows time-in-state, a context-fullness bar
  ([Usage and cost](usage-and-cost.md#context-fullness-bar)), and on an approval the **exact
  command** being requested (for example `wants: npm test -- --watch`).

## Project cards and Instances

The grid shows **one card per project**, not one per session. It's built for the parallel-worktree
workflow ([Merging and batches](merging-and-batches.md)).

- **What folds together.** A session launched at a git worktree top-level joins its repo's card:
  the main checkout and every linked worktree, whatever their folder names (identity comes from
  git, one cached `git rev-parse` per launch folder). Two sessions in one plain folder share a card
  too. A folder nested inside a repo that isn't its own repo (a scratch folder) keeps its own card,
  and A/B compare variants keep theirs so the comparison stays visible.
- **Tabs that entered a worktree.** A tab that started in the main checkout and ran `EnterWorktree`
  (into `.claude/worktrees/<slug>`, or a sibling folder) stays on the repo's card but shows the
  worktree **it is working in**: its branch, its folder in Instances (never offered to Open while
  it's there) and its `TODO.md` in My List.
- **What the card shows.** The instance that most needs you: blocked longest first (approval or
  question, then error, then stalled), then one that's still **running** (a batch's driver first),
  then the newest *finished* one you haven't jumped to yet, else the most recently active. It shows
  that instance's branch chip and an "also: 2 ready · 1 idle" line for the rest. A project with
  anything still at work reads **Working**, never *Ready for you*. A stationary lead is held for
  30 seconds so two busy instances don't swap the card every few seconds. The card is named after
  the main checkout (its relabel, if any); **Relabel** on a card renames the whole repo.
- **Double-click** a card to jump to that same instance. Once you've jumped to a finished instance
  it stops outranking the others until it finishes again (remembered across reloads).
- **The corner button** (top-right of every card) opens the **Instances view**: every instance
  with its folder, branch, status, age and what it's waiting on, with **Focus** or **Details**
  (which opens that instance's detail panel). It also lists hidden instances (**Unhide**) and the
  repo's **worktrees with no session**, each with **Open** (only a worktree the repo itself lists
  can be opened). The button shows the instance count, and a pulsing dot when *another* instance
  needs you. Right-click → **Instances…** opens the same view.
- **＋ New worktree tab** starts a new unit from the Instances header
  ([Merging and batches → New worktree tab](merging-and-batches.md#new-worktree-tab)).
- The detail panel stays on the instance you selected even if the card starts showing a different
  one (the card then gets a dashed outline), so a nudge never goes to the wrong worktree.
- `stacks.enabled: false` in `~/.claude/cc-config.json` switches back to one card per session. The
  Stream Deck stays one key per session.

### Clearing finished sessions

Every Instances row has a checkbox. **Select finished** checks the sessions whose merge landed and
those finished longer than **Settings → Tile cleanup** allows (`cleanup.idleHours`, default 12;
0 = merged ones only). **Select all** checks every row that can be closed, so you can uncheck the
ones to keep. **Close selected** asks first, then closes those tabs through the tab bridge.
Shepherd re-checks every one, so a session that is working, holding a question, mid-merge or
driving a batch is never closed. Unnamed "Claude Code" tabs (a batch unit's) look identical, so they
close only when **every** unnamed tab in that window is selected. A card with two or more finished
sessions shows **🧹 N finished**, which opens Instances with them already checked. Nothing closes
on its own.

## The detail panel

**Single-click** a tile to select it and open the detail panel. Its buttons are described in
[Controls](controls.md#the-detail-panel). Its views sit in a **tab strip**:

- **Activity** (the default): status, the **Wants** (the exact command) and **Why** (the
  assistant's reasoning before a request; both clamp to two lines, click to expand), the agent's
  current **plan and TODO list** (its latest `TodoWrite` or plan-mode plan), a live **activity
  peek** ("Doing: …", the latest assistant line), and session lineage.
- **Transcript**: up to the 60 most recent messages from the last 128 KB of the transcript, oldest
  first: your prompts and Claude's text replies, each cut to 800 characters. Tool calls, tool
  results and IDE file-open lines are skipped. A search box filters the loaded messages as you
  type. It doesn't search the whole history; use **Find in fleet** for that.
- **Rewind**: restore points, newest first (the prompt, its age, and the files changed in that
  turn), above this session's recorded activity. **↶ Rewind…** opens Claude Code's own restore-point
  picker (`/rewind`) after a confirm that states the caveat: rewind reverts Write / Edit /
  NotebookEdit changes only, not changes made through Bash.
- **Decisions**: the gate's recent decisions for this session, grouped with counts and provenance
  (*"⛔ deny Bash ×4 (autoDeny: Bash(rm*)) · 2m ago"*). `decisions.limit` / `decisions.hours` tune it.
- **Usage**: this session's token breakdown.
- **Changes**: the session folder's working tree: changed files with A/M/D/R/?? marks; click a file
  to expand its colorized, rename-aware diff. Read-only, local sessions only, with **↻ Refresh**.
  Only read-only git runs against the repo (`rev-parse`, `status`, `diff`).
- **User Stories**: shown only when the project has `spec/product/user-stories.md` (below).
- **Agents**: the session's subagents and Workflows (below).
- **Queue**: the session's task queue ([Automation → Task queue](automation.md#task-queue)).

The expensive tabs load only when opened. The **⋯** button hides tabs you don't want; your choice
(and the last-open tab) is remembered per project.

### Agents tab and background work

When a session spawns subagents or runs a Workflow, the **Agents** tab lists each one, **grouped
under a per-Workflow header with a running/total rollup** (`⚙ Workflow wf_… · N agents ·
M running`). Each row is labeled by the agent's **actual task prompt**, not its auto-generated slug,
with a green running dot and its latest "Doing:" line. Click a row to read that agent's recent
output. It's read from the `subagents/` folder Claude Code writes beside the transcript; no extra
hooks.

While background work is running, the tile shows a green **⚙ N** pill, and a done or idle session
reads **Running N agents** instead of "Ready for you", so a session busy behind the scenes isn't
mistaken for one waiting on you (`subagents.activeWindow`, default 45s).

Background **shell jobs** count too: a Bash command the session started with `run_in_background`
keeps the card at **Running 1 job** until its completion notice lands in the transcript or the
session stops it. A server or watcher (`deno task dev`, `npm start`, `http.server`, `--watch`,
`tail -f`, a `serve.ts`) never finishes, so it doesn't count, and any other job stops counting
30 minutes after it started (`subagents.jobMaxMinutes`). While a job counts, the card also isn't
offered to Close selected, closed after its merge, or ended as a tab-less leftover.

### User Stories tab

Shown **only when** the session's project has `spec/product/user-stories.md` (it appears and
disappears live if the file is created or deleted). It lists the stories grouped by capability area
(the `##` headings), with **+ Add story** per area; **double-click** a story to edit it inline,
**✕** to delete it, and an explicit **Save** (staged edits, with an "● unsaved" indicator). A soft
**⚠** flags any story that doesn't read "As a …, I want …, so that …". The file's other content (title, intro,
headings, prose, fenced code) is kept **verbatim**: an unedited file round-trips byte for byte.
Saves are guarded against an external edit and written atomically.

To **generate** these files for a project that doesn't have them yet, see
[Reverse-engineering user stories](reverse-engineering-user-stories.md). Shepherd's own
[spec/product/spec.md](../spec/product/spec.md) and
[spec/product/user-stories.md](../spec/product/user-stories.md) are a worked example.

## Session observability

All derived locally from the transcript Shepherd already reads, with no extra hooks:

- **Auto-title** (off by default, `autoTitle.enabled`): names an unlabeled tile from its first
  prompt. A manual relabel always wins.
- **Loop watchdog** (off by default, `escalation.loop.enabled`): a ⟳ badge when a working session
  keeps repeating the same tool call (for example re-running a failing command). Detection only.
- **Stuck-session watchdog** (off by default, `escalation.hung.enabled`): a session that stays `working` with no transcript
  growth for `escalation.hung.minutes` gets ⏳ and a purple ring
  ([Automation → Escalation](automation.md#escalation-and-watchdogs)).
- **PR / MR status** (off by default, `prStatus.enabled`, needs the GitHub CLI `gh`): a clickable
  **"PR #N open / merged"** badge per repo, polled with `gh pr view`. Status only; Shepherd never
  opens or edits PRs.
- **Risk indicator** (off by default, `risk.enabled`): a per-session ⚠/▲ badge computed from that
  session's ledger history (deny rate, auto-deny hits, timeout fallbacks, slow approvals, tool
  volume). Indicator only; it never blocks.
- **Same-folder collision** (off by default, `collision.enabled`): an amber ring and
  "⚠ shared dir" when 2+ **active** sessions share a working directory, so two agents don't
  silently clobber each other's edits. `useGitRoot` groups by repo root instead. Detection only.
- **Session lineage**: auto-respawns and `/clear`s mint a new session id for the same project. The
  detail panel shows a one-liner ("3rd session today · 2 auto-respawns · 1 clear") and a tile gets a
  **♻️N** badge once the churn adds up (needs the audit ledger).
- **Run score, history, insights and cost** are in [Usage and cost](usage-and-cost.md).

## Search, groups and bulk actions

- **🔍 Filter sessions** (☰ menu) reveals a filter bar that scopes the grid as you type. Every word
  must match something about the session: its name or label, folder path, project, status id
  (`approval`, `working`, `done`, …), group, branch or chat title.
- **🔎 Find in fleet** (☰ menu) searches every session's **transcript**, live *and* ended, plus the
  audit ledger: "which session touched `auth.ts`?", "who ran that migration?". Click a hit to select
  the live session (or open an ended one's audit timeline). Instant with
  [ripgrep](https://github.com/BurntSushi/ripgrep) installed; it falls back to grep otherwise.
  `search.maxResults` caps the hits.
- **Groups**: right-click → **Set group…** tags a session into a named cohort, kept by the stable
  project identity so it survives close and reopen (`~/.claude/cc-groups.json`). When groups exist,
  a chip row scopes the grid to one group (it composes with the filter).
- **Bulk actions**: the **Fleet** bar acts on whatever is visible after filtering: **Approve all**
  waiting sessions (shown from one), or **Stop all** working ones (shown from two, after a
  confirm). The buttons show live counts. There is no bulk nudge.
- **Hide tile**: right-click → **Hide tile** takes a session off the grid without touching it; it
  keeps running and Shepherd keeps managing it. Restore it from **☰ → 🙈 Hidden sessions**.
- **Timeline**: the detail panel's **📜 Timeline** button opens the audit ledger scoped to that one
  session's history (needs the ledger).

## My List

A checklist built into the panel: add, work, check off. The **📋 My List** button on the right of
the FLEET row swaps the session tiles for the list (click again to go back).

- **Scopes**: a **MASTER** rollup, a **Generic** list, and one tab per project that **has a live
  session or still owns a saved list**, labeled with the project's relabel name. Lists are stored in
  `~/.claude/cc-worklist.json`, keyed by the stable launch-folder identity. A project's tab and its
  items **persist whether or not a window is open**, until you clear the list.
- **TODO.md import**: **⇪ Import TODO.md** pulls a project's `TODO.md` checkboxes into its tab as
  verify-me items (the file's `[x]` shows as a **✓ auto** chip; the row checkbox stays yours). Once
  imported, the tab **re-syncs whenever the file changes**. A repo's main checkout and its worktrees
  share one tab, and the import reads **every worktree's** `TODO.md`: a line in several copies
  imports once, a line that exists only on a branch carries a **⎇ branch** chip until it reaches
  main's copy, and a removed worktree's items stay. The file format is in
  [methodology/CLAUDE.md](../methodology/CLAUDE.md).
- **Filter**: the box under the tabs filters **whichever tab you're on**: a project tab that
  project, **MASTER** the rollup, **🗄 Archive** every archived row. It is case-insensitive and
  every word must match. It searches the subject, the **details**, the expected date (`2026-09`
  filters a month) and, on MASTER and Archive, the project the row came from. The count beside it
  reads **N / M shown**; **Esc** clears it. Done drawers are not filtered, and **✓ Mark all N done**
  hides itself while a filter is on.
- **The item editor**: **＋ Add an item…** (or clicking a row) opens one editor with a **Subject**
  (Enter saves), **Details** (free-form notes), a **Checklist** of sub-steps (ticking a step saves
  immediately; the row shows a `2/5` chip that turns green when all are done), and an **Expected
  date** (defaults to today; **◀ ▶** nudge it a day, **↻** resets, **Clear** drops it). Esc or a
  backdrop click discards; **Delete** removes the item after a confirm.
- **The list**: each row shows its subject and date chip (dim normally, amber for **Today** /
  **Tomorrow**, red once **overdue**), a 📝 when it has details, and its checklist progress.
  Checking a row moves it to a collapsed **Done** area (ordered by due date) with both its expected
  date and a **✓ completion date**. **✕** deletes it; **Clear** empties Done for that scope.
- **✓ Mark all N done**: ticks off everything still open on the tab you're looking at, after a
  confirm that states the count. On **MASTER** it marks every project's open items, each in its own
  list.
- **🗄 Archive**: once a day, work you finished more than **10 days** ago moves out of the live list
  into `~/.claude/cc-worklist-archive.json`, and the **Archive** tab shows it, newest first and
  read-only. Nothing is deleted. The archive is fetched **only when you open that tab**.
  `worklist.archiveAfterDays` (default `10`) and `worklist.archive` (`false` turns it off) tune it.
- **MASTER**: a read-only, date-ordered rollup of every **open** item across Generic and every
  project, grouped **Overdue / Today / Next 7 days / Later / No date** and tagged with the list it
  came from. Tick a row to mark it done in its own list, or click it to jump to that tab with the
  item open. A collapsed **Recently completed** drawer shows everything finished in the **last
  7 days**, newest first.

## Messages

Shepherd's messages (a session asking you something, a merge starting, an action it refused and
why) appear as small toasts at the bottom of its own panel (up to three, fading after a few
seconds; click one to dismiss it) and in the Hammerspoon console. Nothing pops up over your other
windows; `"alerts": { "onScreen": true }` brings back the big centre-screen overlay.
