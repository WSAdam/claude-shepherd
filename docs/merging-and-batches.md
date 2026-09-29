# Merging and batches

[← README](../README.md) · [Fleet](fleet.md) · [Approvals and policies](approvals-and-policies.md)

Shepherd is built for parallel work: **one unit of work = one branch = one worktree = one Claude
session.** This page covers how a unit starts, how it asks to merge, how Shepherd checks and lands
it, and how one Claude session can drive a whole batch of units with one approval from you. The
full working rules the sessions follow are in [methodology/CLAUDE.md](../methodology/CLAUDE.md).

## Worktree tabs

By default each unit is its own **Claude tab in the repo's one VS Code window**. The tab starts in
the main checkout and calls `EnterWorktree`, which creates `.claude/worktrees/<slug>` and fences
the session off from main. A unit that needs its own dev server or browser gets a sibling worktree
(`../<repo>-<slug>`) in its own VS Code window instead. Shepherd's
[worktree fence](approvals-and-policies.md#worktree-fence) keeps each session out of the others'
worktrees, whichever kind it started in.

On the grid, the main checkout and every worktree fold into **one project card** (see
[Fleet → Project cards and Instances](fleet.md#project-cards-and-instances)).

### New worktree tab

**＋ New worktree tab** (in the Instances header, or right-click a card → **New worktree tab…**):
pick a type (feat / fix / ui / docs), a name and, optionally, what it should do. Shepherd checks the
name against the repo's branches and worktrees, brings the repo's own window to the front, and
opens a **new Claude tab** there through the Claude extension's URI, with a prompt already typed
in: *EnterWorktree with that name, rename the branch to `<type>/<name>`, then the task*. Nothing is
sent: read or edit the prompt and press Return.

If the repo has no window open, its folder is opened first. If its window isn't in front when the
tab would open, nothing opens. **Open** on an idle `.claude/worktrees/` worktree in Instances works
the same way: a new tab in the repo's window whose prompt re-enters that worktree. A sibling
worktree still opens in its own window. VS Code and Cursor only.

## Ready to merge

A worktree tab that has finished its unit (suite green, everything committed) asks for a merge
instead of merging on its own. It leaves its worktree (`ExitWorktree`), then from the main checkout
runs this **in the background** and ends its turn:

```bash
~/.claude/cc-merge.sh request --worktree <its path> --summary "…" --tests "…"
```

Claude Code wakes it when you answer. (Asking from inside a tab's worktree works too where nothing
fences it, but Claude Code's worktree guard can refuse to run the script there, so fenced tabs ask
from outside and step back in to rebase.)

### The card

The card says *⇡ ready to merge fix/x → main* and reads **Needs you**, with a red dot and a pulsing
red ring. It leads its project card, and you get one alert (plus an OS banner if approval banners
are on).

**A card that says Needs you always has something to press, and only then.** A card ranks as
needing you when a live counterpart will actually receive your answer *and* the card offers
something that changes the outcome. Anything else is a **Heads-up** instead: on the card,
dismissible, with one line saying why, but never red, never pulsing and never ranked above a
session that is working. Heads-ups include:

- a merge request whose `cc-merge.sh` has gone,
- a question whose session exited,
- a merge request whose test gate is still running (nothing to press yet; it turns red on its own
  the moment the gate finishes),
- a batch unit's merge while [the checker](#the-checker-a-read-only-review-of-every-merge-request)
  reviews it (it merges on your grant on a pass, and turns red on a fail),
- a merged unit whose post-merge gate went red (main is red, and its worktree is already gone),
- a connection blip the session is still retrying.

A unit that came back **blocked** stays Needs you. The affordance isn't the Dismiss button, it's
the stalled tab and the branch, and a blocked unit going quiet is how parallel work gets silently
lost.

Shepherd checks the request with **its own git** first: the worktree is one of the repo's, on the
requested branch, clean and ahead of main, and its changes add **no conflict markers**. Otherwise it
says what's wrong.

A conflict marker is a line the unit's diff adds that starts with seven `<` or seven `>` and a
space, or is exactly seven `=`. That's what a rebase conflict "resolved" with its markers still in
leaves behind. Only added lines count, so a marker-like line the unit never touched can't hold its
merge. Whitespace problems don't count either (no `git diff --check`). A Markdown heading
underlined with exactly seven `=` looks the same as a marker, so write that heading with `#`.
`cc-merge.sh request` refuses such a unit on the spot and names the files.

### The review

The detail panel (or **Review** in the Instances view) shows the session's summary, the tests it
reports, how far ahead of main it is and whether main moved on, the commits, the changed files,
and **Full diff**.

### Merge gates: Shepherd runs the tests itself

Everything else in the review is checked with Shepherd's own git; the test line is the session's
word. List the project's suite under `merge.gates` and Shepherd runs it: in the unit's worktree,
through your login shell, once per request per commit (a new commit in the worktree re-runs it).

```json
"merge": { "gates": [
  { "match": { "project": "*my-repo*" }, "command": "make lint && make test", "timeoutSeconds": 900 }
] }
```

- While it runs, the card says *checking* and **Merge** is refused. A gate still waiting for its
  repo's lane says it is *queued behind another run in this repo* instead. The card, its reason
  and the review all name which of the two it is, and a queued gate holds the merge just the same.
- A red or timed-out run blocks the merge: your button **and** a batch unit's merge on your grant.
  The review leads with the **failing lines** of the suite's own output (`FAIL`, `not ok`, an
  `N run, M failed` summary), names the full log's path, and keeps the last lines underneath as
  context. The session's test line stays, relabelled *advisory*.
- **One gate runs per repo at a time**, pre- and post-merge sharing the lane, even when the units
  sit in different worktrees; gates in different repos run at the same time. A project's suite
  usually isn't safe to run twice in one checkout, and two concurrent runs kill each other and both
  report a failure about a tree that is green.
- A suite that **couldn't run at all** (its own concurrency lock, a missing command, a worktree
  that has gone) is told apart from one that failed. It still holds the merge, because nothing was
  proven, but the review says plainly that the suite never started instead of claiming the tests
  failed, and Shepherd retries it a minute and a half later.
- After the merge the **same suite runs once in the main checkout**, but only for a request whose
  own pre-merge gate ran in this Shepherd session. Turning `merge.gates` on never gates merges that
  already happened. If main is red, the unit's tab stays open and the card says so.
- `match` works like `policies.attachments` (project / group / key globs, first entry wins, an
  absent field is a wildcard; `project` is the session's project key). With no `gates` listed,
  nothing runs.

#### A repo can declare its own gate

A repo can name its merge gate in an executable `.worktree-check` at its root: the script that
must be green before anything merges. Turn on `"merge": { "repoGate": true }` (it is off by
default) and a request that no `merge.gates` entry matches runs that script as its gate, through
the same queue and lane as above. A matching `merge.gates` entry always wins.

- Shepherd runs the **base branch's** copy. It reads `refs/heads/<base>:.worktree-check` with its
  own git, never the worktree's file, so a unit can't rewrite its own gate. The copy runs from a
  scratch file with the unit's worktree as the working directory (the main checkout for the
  post-merge run, which reads the base again: after the merge the unit's version is main's gate).
- A shell script (`#!/bin/sh`, `bash`, `zsh`, or none) sees `$0` as the checkout's own
  `.worktree-check`, so `cd "$(dirname "$0")"` lands in the checkout. Another interpreter
  (`#!/usr/bin/env -S deno run -A`) runs the scratch copy by path.
- No `.worktree-check` on the base means no gate, as before. A symlinked one, or one over 64KB,
  counts as a gate that couldn't run: it holds the merge and the review says why.
- The review labels it **repo-declared gate** and names the copy it ran (*main's .worktree-check*).
- A diff that edits `.worktree-check` gets a warning line in the review, whether or not the repo
  gate ran. It's a hint like the claim check below, and it blocks nothing.

#### The red-first proof: do the new tests fail without the fix?

A green gate proves the suite passes **with** the unit's change. It doesn't prove the unit's new
tests would have caught the bug **without** it. Give a gate entry a `redFirstCommand` and Shepherd
checks that too, once the pre-merge gate has passed:

```json
{ "match": { "project": "*my-repo*" }, "command": "make lint && make test",
  "redFirstCommand": "bash tests/run.sh {files}" }
```

- Shepherd lists the unit's changed test files with its own git (`git diff --name-only
  --diff-filter=AMR <base>...<branch>`, with no cap). It makes a **detached scratch worktree at the
  merge-base** in `~/.claude/cc-scratch/`, never under `.claude/worktrees/`. It checks the changed
  test paths out onto it from the unit's commit (fixtures and helpers too; the rest of the unit's
  files stay behind), runs the command there, and removes the worktree.
- `{files}` becomes the changed files that are tests themselves (`*.test.*`, `*_test.*`,
  `test_*`, `*.spec.*` and the like, outside `fixtures/` and `support/` folders), shell-quoted.
  Without `{files}` the command runs as written. With no `redFirstCommand`, nothing runs.
- It runs in the repo's one gate lane, after the gate, so it never runs beside another suite, and
  it uses the gate's `timeoutSeconds`.
- **Proved red** means every changed test file printed a failing line of its own: `FAIL - name`,
  `not ok`, jest's `FAIL <file>`, go's `--- FAIL:`, or deno's `... FAILED`. A failing line belongs
  to the file it names; otherwise to the file named by the last header above it (`== <path> ==`,
  jest's `PASS <file>`); otherwise, when only one file ran, to that file.
- Failures that **already happen on the base branch** don't count. The changed files that also
  exist there run on its tip too, once per base commit. A failing line that also fails there
  (durations and line numbers aside) is counted as old. If that run couldn't run, every failure
  counts and the review says so.
- A run that **couldn't run** (the suite's lock, a missing command, a scratch worktree git wouldn't
  make, a timeout) never counts as red.
- The review shows it under the checker line: *proved red*, *not red* with the files that had no
  new failure, or *couldn't run*, with the new failing lines and how many already fail on main.
  It's a hint like the claim check: **Merge** and a batch unit's merge on your grant never wait for
  it or read it.
- A scratch worktree a timed-out run leaves behind is removed in the background, and one a crash
  leaves behind is removed when Shepherd next starts. The Instances view never lists one.

**This repo's own suites** take file arguments through `tests/run.sh`: `bash tests/run.sh
tests/core.test.lua tests/merge.test.sh` runs just those files, each under a `== <path> ==` header,
by extension (`.lua` with `lua` and a temp `HOME`, `.sh` with `bash`, `.js` with `node`, `.ts` with
`deno test`). A file that crashes before it prints a `FAIL` line gets one naming it, so a test that
calls a function the fix adds still reads as red. Its red-first command is
`bash tests/run.sh {files}`.

### The claim check: a hint, never a gate

The gate proves the suite is green; it doesn't prove what the session *wrote* is true. The review
reads the summary and the tests line against the changed files it already has (no extra git call).
A summary that says tests or fixtures were **added** should come with at least one test path among
the added or changed files: for example a `tests/`, `test/`, `__tests__/`, `fixtures/`, `testdata/`,
`e2e/` or `isolate/` folder, or a `*.test.*` / `*_test.*` / `*-test.*` / `test_*` / `*.spec.*` /
`*_spec.*` / `FooTest.*` file. A rename counts by where it ends up; a deletion doesn't.

It answers one of three ways: *ok* with the paths, *flagged* with the sentence it read and the file
count, or *couldn't tell* when no such claim was made, the diff isn't in yet, or the file list was
cut at 200. It reads English with a small, conservative matcher (a verb of adding next to
"test"/"fixture"; a negated clause is skipped; "tests green" is the gate's business, not a claim).
So it **warns in the review and holds nothing**: Merge stays clickable, and a batch unit's
delegated merge goes through with a flag up.

### The checker: a read-only review of every merge request

The gate proves the suite is green, and the claim check reads the summary. The checker reads the
**code**. With `verify.onMerge` on, every merge request gets a background review in two steps:

1. **Red flags, no model.** Shepherd scans the diff itself and lists what it finds:
   - conflict markers the diff adds;
   - a test file the diff deletes, or lines it removes from a test that stays (a test file that
     only gains lines is normal);
   - a new `.only`, `.skip`, `xit`, `@Disabled`, `ignore: true` and the like in a test;
   - stubs in code: `not implemented`, `todo!()`, a `TODO`/`FIXME` comment (never in Markdown).

   The flags show in the review straight away, and still show if the model never answers.
2. **A read-only review.** A headless `claude -p` runs in the unit's worktree with the flags in
   hand. It uses Sonnet with no hooks, no MCP servers and no saved session, and it can only read:
   Read, Grep, Glob and read-only git (`diff`, `log`, `show`, `blame` and so on). Anything else is
   refused, not asked. It answers **pass** or **fail** with a one-line summary and its findings
   (file, line, severity). The session's own summary goes into its prompt as data it is told not to
   follow.

What happens next depends on the verdict:

- **Pass:** a batch unit's merge goes through on your grant, as before.
- **Fail:** a batch unit's merge **waits for your click**. The card says *the checker failed it, so
  it waits for your click*, it reads **Needs you**, and you get one alert.
- **Couldn't run** (no answer, a timeout, the turn or budget cap, a Hammerspoon reload mid-run):
  nothing was proven either way, so the checker tries once more a minute later. If it fails to run
  a second time, the merge waits for your click.
- **Your own Merge click never looks at it.** A unit the checker failed still merges when you say
  so.

While the review runs, a batch unit's card says *the checker is reviewing it before it merges on
your grant*. That's a heads-up, not **Needs you**: nothing is waiting on you yet.

There's one review per request per commit: a new commit in the worktree gets a new review, and the
verdict is kept in `~/.claude/cc-merge/<key>.checker.json`, so a reload doesn't run it again.
**Only one review runs per repo at a time**, first asked, first reviewed. Reviews in different
repos run side by side, and they never share a lane with the test gate.

**🔎 Verify** in the detail panel runs the same review for any session, whenever you like:

- A session with a merge request is reviewed on its request's commit, so a pass counts for that
  merge.
- Any other session is reviewed on its checkout against where it left `main` (or `master`),
  uncommitted work included. Untracked files are listed for the model to read, since `git diff`
  doesn't show them.

The verdict shows under the buttons, and you get a toast when it's in.

```json
"verify": { "onMerge": true, "maxBudgetUsd": 1, "timeoutSeconds": 600 }
```

`onMerge` is off unless set; a fresh install ships it on. `maxBudgetUsd` caps each run's spend
(default $1), and `timeoutSeconds` caps how long it may take (default 600). Verify works whatever
`onMerge` says.

### Merge, Not yet

**Merge** tells the waiting session to go:

1. rebase on main (conflicts are settled by the tests: both sides' tests must pass, or it stops and
   reports *blocked*),
2. run the suite,
3. `ExitWorktree`, then `git merge --ff-only` in the main checkout,
4. run the suite on main,
5. `cc-merge.sh done --result merged`, which confirms the branch is in main and removes the
   worktree and the branch, never forced. Before it removes anything it also checks main: the main
   checkout is on main, its **tracked** files are clean (untracked files like `TODO.md` or scratch
   notes never count), no conflict markers came in with the merge, and the stash has no entries
   newer than the request. If one fails it refuses, says how to fix it (restore stashes by hash,
   never a bare pop), and leaves the worktree and the branch alone. The unit fixes it and runs
   `done` again, or reports *blocked* if it isn't the unit's to fix.

Merges in one repo run **one at a time, in the order you clicked**. The rest show
*queued (next in line)* and start on their own. **Not yet** sends your note back, and the unit
stays in its worktree.

### A unit's own tab closes itself

Once `done` reports the merge, Shepherd checks with its own git that the merged commit is in main
and the worktree is gone. It runs `done`'s checks on main again too: on main, tracked files clean,
no stash entries newer than the request, and no conflict markers in the merge. The merge's range
starts at main's reflog entry for the branch (`merge <branch>: Fast-forward`), so a later commit
can't hide markers the merge brought in, and one that removes them clears them. A request made
before this check existed carries no stash count and skips that one check. A merge verified once
stays verified, so a later change in main isn't blamed on a unit whose tab is only waiting for its
last turn to end. Then Shepherd waits for that turn to end. Then, **only for a tab it
opened for that job** (a batch unit's, or one started with **New worktree tab** or resumed from
Instances), it has the tab bridge close it: a batch unit's tab by the tag the bridge gave it, any
other by its name, on a single match.

A main chat that did a unit itself in a worktree stays open: its finished request is cleared and a
toast says *✓ Merged … — its chat stays open*.

If it can't close the tab (no bridge in that window, a tab name shared by two tabs, a terminal
session) or git disagrees, the card says *merged — close its tab yourself* and why. It offers
**Dismiss** (clear it from the card), and **Close tab** (try again now) only where a press could
actually close it: never while a post-merge gate runs or queues, while main is red, for a merge
Shepherd couldn't verify, or when the tab can never be identified again. A *blocked* unit's card
has Dismiss too. `"merge": { "closeTab": false }` leaves every tab open.

### No keystrokes

The request and your answer are files in `~/.claude/cc-merge/`, and the answer is bound to the
request it's for. `"merge": { "enabled": false }` makes Shepherd ignore requests.

## Claude drives a batch

Ask a Claude session to run several units in parallel and it can drive the whole loop, with **one
approval from you per batch**:

1. It writes the batch (a `title`, `units` each with a `type` / `slug` / `task`, and
   `mergeWhenGreen` if it asks to merge them when green) and runs
   `~/.claude/cc-fleet.sh propose --file <batch.json>` in the background.
2. Its card says *⇉ proposes 3 units in <repo>* and reads **Needs you** (red dot, pulsing ring, one
   alert). Its detail panel shows the
   batch: every unit and its task, and a **"Claude may merge these when green"** checkbox set to
   what it asked for. Untick it to keep merges for yourself. **Approve batch** or **Deny** (with a
   note).
3. On approval it runs `cc-fleet.sh tab --batch <id> --unit <name>` per unit. Shepherd opens an
   empty Claude tab in the repo's window, works out which new session is that tab (one tab opening
   per repo at a time), and hands back its name and the unit's message. First it tells that
   window's tab bridge to tag the new tab as the unit's; the tab never gets a name, so the tag is
   how Shepherd closes it after the merge. A window still running a bridge too old to tag it is
   refused up front with *Developer: Reload Window there, then ask again*, and a tag the bridge
   refuses raises a toast at once instead of surfacing at merge time. The driver sends the message
   with **SendMessage**: the tab starts working with no Enter pressed, under its own permissions,
   and the driver is notified when the unit goes idle. While the batch runs, the driver's card reads
   **Driving N units** in the working colour and stays ahead of its units (anything that needs you
   still leads).
4. Each unit finishes with the ready-to-merge flow above. With merge permission, Shepherd approves a
   unit's merge on the batch's grant **only** for that unit's own session on its own branch, once
   its own git check passes (and, with `verify.onMerge` on, once
   [the checker](#the-checker-a-read-only-review-of-every-merge-request) passes it), one merge per
   repo at a time. Without it, units wait for your Merge.
   Tabs close after their merges as usual.
5. **Stop batch** (on the driver's card) or `cc-fleet.sh stop --batch <id>` ends it at once: no more tabs, no
   more merges on its grant. A batch also **ends itself** once every unit has merged or blocked (or
   its repo is gone). Shepherd records each unit's outcome from its merge request, says
   *batch finished: … (2 merged)* once, and the panel leaves the driver's card.
6. While it runs, the batch review groups the units **by outcome**: *✅ 2 merged — alpha, delta*,
   *⛔ 1 blocked — beta*, *⏳ 1 working — gamma*, *· 1 not opened — eps*. Each unit's row leads with
   its result. `cc-fleet.sh status --batch <id>` prints the same grouping as JSON: `counts`,
   `outcomes` (the slugs in each bucket), a per-unit `units` list (branch, outcome, result,
   session) and your `grant` as Shepherd recorded it. A unit with its session and no result is
   *working*; one with no session yet is *unopened*; *merged-dirty* counts as merged.

Your approval lives in Shepherd (`~/.claude/cc-fleet/<id>.state.json`), never in the proposal's
own file. `"fleet": { "enabled": false }` makes Shepherd ignore proposals.

`~/.claude/cc-fleet.sh alive` tells a session whether Shepherd is running (see
[Troubleshooting](troubleshooting.md#is-shepherd-running)).

## Try it: the worktree demo

`deno task demo` (or `make demo`) sets up a fresh little Deno app and opens it in a new VS Code
window. Say **run the worktree demo** in a Claude tab there and watch two units work on the same
file at once, land on main one after the other (the second through a merge conflict settled by the
tests), and close their own tabs, with one approval and two Merge clicks from you. See
[demo/GUIDE.md](../demo/GUIDE.md) for the walkthrough and
[demo/HOW-IT-WORKS.md](../demo/HOW-IT-WORKS.md) for the mechanics.

## The tab bridge

Shepherd acts on a VS Code session by focusing its *window*, and keys land in whichever tab is in
front. The **tab bridge** (a small companion extension; see
[Install → The tab bridge](install.md#the-tab-bridge-a-companion-vs-code-extension)) lets it act on
one tab without keystrokes. It runs in every VS Code window, has no network access, never touches
other tabs, and has exactly three operations, each on a single match only:

- **close** a Claude tab: by its name (its chat title, as the tab shows it) when exactly one Claude
  tab in that window carries it, or, for a batch unit, by the tag it gave the tab when it opened
  (bridge 0.3.0+; since 0.5.0 also when the tab opened a moment before the tag request arrived).
- **select** a Claude tab after a Jump: when one of the session's names (custom title, AI title,
  first or last prompt) picks out exactly one Claude tab, it brings that tab to the front. A batch
  unit's tab is selected by its tag.
- **expect** a tab: tag the next Claude tab that opens as a batch unit's.

Each window writes its Claude tabs' names to `~/.claude/cc-bridge/<pid>.json`. Shepherd drops a
command in `<pid>.in/` and reads the answer from `<pid>.out/`.

**Empty chats** are the one exception to closing by name. Never-used chats all read "Claude Code",
so no name picks one out, but they're interchangeable. A card whose window has any shows
*🧹 2 empty chats in this window (never used)* with **Close them** (and each gets **Close** in the
Instances view). The bridge (0.4.0+) then closes any untagged "Claude Code" tab, and only while
their number still equals the empty sessions Shepherd counted there, so a restored old chat (which
also reads "Claude Code") is never closed by mistake. **Close selected** in Instances uses the same
count for unnamed sessions, and only when every unnamed session in the window is selected.

VS Code rebuilds every tab object on a tab switch. Since bridge 0.6.0 the bridge carries each
unit's tag across that rebuild, so a unit's tab still closes after you've clicked around. A window
keeps the bridge it loaded at startup: after an upgrade, **Developer: Reload Window** there.

`"tabBridge": { "enabled": false }` in `~/.claude/cc-config.json` stops Shepherd using it. (That is
not the SSH remote `"bridge"` section, which mirrors other machines' sessions.)
