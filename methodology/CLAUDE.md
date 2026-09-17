# Claude Shepherd methodology

How Claude sessions work alongside Shepherd: units of work in worktrees, merges through Shepherd's
ready-to-merge review, batches of parallel units, and tests first with regression fixtures.
The installer copies this file into `~/.claude/CLAUDE.md` between two marker lines; re-running the
installer replaces that block, so change it here, not there. "I"/"me" is you, the person at Shepherd.

## Parallel Worktree Workflow

**One unit of work = one branch = one worktree = one Claude session.** A feature, a bug and
a UI rework are separate units — never combine them in one branch. If work in progress
reveals a second unit, stop and cut a new worktree for it rather than widening the current
one. `main` stays clean and green. **Exception — sequential work:** a session doing one
unit, or several strictly one after another, while no other session is changing that
checkout, works straight on `main` — still test-first, a TODO.md line per item, the full
suite green before each commit, one commit per unit. Worktrees are for units that run in
parallel.

- **Default — tabs.** Each unit is its own Claude tab in the repo's one VS Code window. The
  tab starts in the main checkout and calls `EnterWorktree` with `name: "<slug>"`: that
  creates `.claude/worktrees/<slug>` from the current HEAD (`worktree.baseRef: "head"`)
  without an approval prompt and fences the session off from main. Then rename the branch
  Claude made (`worktree-<slug>`) with `git branch -m <type>/<slug>` (`feat/`, `fix/`, `ui/`,
  `docs/`). Shepherd's **New worktree tab** button opens such a tab with that prompt typed
  in. To pick a worktree up again in a fresh tab, `EnterWorktree` with its `path`.
- **Separate window — only when the project needs its own dev server or browser** (a web
  app you run and click through, a fixed port, headed browser work): a sibling worktree,
  `git worktree add ../<repo>-<slug> -b <type>/<slug>`, opened in its own VS Code window with
  its own Claude session, so its server and browser stay apart from every other unit.
- **Setup.** Worktrees share the repo's `.git` (every branch and commit is visible
  everywhere, no fetch) but not its gitignored files or deps. Tabs: list what a worktree
  needs (`.env`, …) in `.worktreeinclude` at the repo root (`.gitignore` syntax) and Claude
  copies it into every worktree it creates; `git worktree add` never reads that file, so in
  a sibling folder `cp ../<repo>/.env .env` by hand. Install deps in the worktree, and give
  it its own `PORT` whenever it runs a server. Test configs read `baseURL` and every host
  from the environment; never hardcode `localhost:<port>`. Gitignore `.claude/worktrees/`,
  and exclude it from anything that globs the repo (test runners, linters, `tsconfig.json`,
  `deno.json`) — otherwise main's suite runs every worktree's copy too.
- **Work.** One Claude session per worktree, and never edit files that belong to another
  worktree. `EnterWorktree` fences a session off from main on its own; a session started
  normally in a sibling folder is not fenced, so there the rule is ours to keep. When I ask
  one session to do several units itself, it does them one at a time straight on `main` (the
  sequential exception), one commit per unit.
- **Driving a batch (units in parallel tabs, one approval).** When I ask for units to run in
  parallel and Shepherd is running, drive them instead of doing them yourself:
  1. Write the batch to a scratch file: `{"title": "...", "mergeWhenGreen": true|false, "units":
     [{"type": "feat|fix|ui|docs", "slug": "...", "task": "<a complete, self-contained brief>"}]}`
     (1–8 units that don't edit the same code if you can help it). Ask for `mergeWhenGreen`
     only if I said merges can go through without me.
  2. Run `~/.claude/cc-fleet.sh propose --file <batch.json>` from inside the repo **in the
     background** and end the turn with a short summary; I approve or deny it in Shepherd.
  3. `BATCH APPROVED` → for each unit run `~/.claude/cc-fleet.sh tab --batch <id> --unit <slug>`,
     then SendMessage the session it prints the message it prints (`notify_when_idle: true`).
     `DENIED: <note>` → act on the note; nothing was opened.
  4. Follow the units through the idle notices, their messages and `cc-fleet.sh status --batch
     <id>` — never poll `ListAgents`. Answer their questions; never ask a unit to do something
     its own permissions would refuse, and never approve its merges yourself.
  5. When every unit has merged or blocked: `~/.claude/cc-fleet.sh stop --batch <id>`, then
     summarise what landed and what didn't.
- **Finish — ask Shepherd, then merge.** When the unit is done (full suite green, everything
  committed), don't merge on your own. Leave the worktree first (`ExitWorktree`, keep — the
  worktree guard can refuse to run the script inside it), then from the main checkout run
  `~/.claude/cc-merge.sh request --worktree <the worktree's path> --summary "<what the unit
  does and why, 1–3 sentences>" --tests "<the command you ran>: <result>"` **in the
  background** (`run_in_background`) and end the turn with a two-line summary. (A session in
  an unfenced sibling folder can run it from inside its worktree, without `--worktree`.)
  Shepherd shows me a ready-to-merge review; when I answer, the script exits and you're woken:
  - `MERGE APPROVED` → follow the printed steps: `EnterWorktree` with the worktree's path,
    rebase on main there (conflicts: the next bullet), full suite green, `ExitWorktree` (keep),
    `git merge --ff-only <type>/<slug>` in the main checkout (main moved meanwhile → back to
    the rebase), full suite green on main plus the project's own post-merge steps, then
    `~/.claude/cc-merge.sh done --result merged` — it removes the worktree and the branch
    (never forced), and Shepherd closes the tab if it opened it for the unit (a batch unit or a
    New worktree tab; a main chat that did the unit itself stays open). If the tests can't settle a conflict or the
    suite stays red: `~/.claude/cc-merge.sh done --result blocked --note "<why>"` and stop.
  - `NOT YET: <note>` → `EnterWorktree` with its path, act on the note, then leave and ask again.
  - A refusal → fix what it names. Shepherd not running (exit 6) → ask me in chat, then finish
    by hand: green → rebase on main → green → `ExitWorktree`, `git merge --ff-only` → green on
    main → `git worktree remove <path>` and `git branch -d <type>/<slug>`.

  Never `rm -rf` a worktree folder — git keeps tracking it; run `git worktree list` now and
  then to catch strays. The same branch can't be checked out in two worktrees.
- **Merge conflicts: the tests are the oracle.** Both sides arrive with tests that record
  what each branch protects. Read both sides' tests before touching the conflicted code,
  keep the resolution that satisfies both, and replay a bugfix branch's fixture against the
  merged code — if it fails, the resolution silently reintroduced the bug. If no resolution
  satisfies both, the branches disagree about intended behaviour: that's a design question —
  stop and escalate, never pick a side or delete a test to get green. The merge is done when
  the ENTIRE suite passes on the merged result. Main is never left red.
- **MCP & browsers.** Shared MCP config lives in the tracked `.mcp.json` at the repo root,
  so every worktree inherits it. Playwright MCP runs `--headless --isolated` at user scope:
  every session gets its own in-memory browser profile, so tabs that share a workspace root
  never fight over one. Logins don't persist — for an authed flow, save a storage state
  once and add `--storage-state=<file>` to that project's `.mcp.json` Playwright entry (a
  project entry replaces the user one, so repeat `--headless --isolated` there).
- **Shepherd.** It types into a window, not a tab, so it refuses keystroke actions (nudge,
  queue feed, `/clear`, auto-continue) for sessions that share a window; Jump, hands-free
  approvals and ready-to-merge still work, and Close goes through its tab bridge (a local VS
  Code extension) that closes just that tab. A unit that needs the keystroke automation gets
  its own window.
- **Subagents.** Worktree-isolated subagents (e.g. an implement fleet) start from
  the current HEAD (`worktree.baseRef: "head"` in settings), not from the working tree —
  commit before spawning them.

## Test-First & Regression Fixtures

- **No production code before a failing test.** Features: write the test that describes the behaviour first, then implement. Bugs: extract the broken state into a fixture — a literal snapshot of the input, state or payload that triggers it — write a test that fails against it, then fix. The fixture ships with the branch; it is part of the deliverable.
- **No tests, no merge.** A branch that reaches a merge without tests isn't ready — there is no "I'll add them after".
- **Every bug gets a test before it gets a fix.** However it surfaced — you reported it, I found it, a review or sweep flagged it — capture the failing case as a permanent fixture in the project's suite, then fix it.
- **Every bug also gets a `TODO.md` line** (Shepherd's My List imports `- [ ]` lines from `TODO.md` at the project root), written when the bug is identified, before the fix. The fixture proves the fix to the suite; the TODO line is how I click-verify it by hand in Shepherd afterwards.
- **Prove it goes red first.** Run the new test against the unfixed code and confirm it fails. A test that never failed proves nothing about the bug.
- Name it for the behaviour that broke, not the function: `empty section renders when refundStatement is blank`, not `test refund 3`. One comment line with the date and the actual cause.
- **Never delete, skip, or loosen one later to get a suite green.** If it starts failing, either the bug is back or the requirement changed — say which, out loud, before touching it.
- Fixtures live with the project's existing tests (`deno test` / `*.test.ts`, `busted`, …). Don't stand up a parallel harness.
- On a multi-bug sweep, every bug I actually fix still earns a fixture. Report any I could not cover, and why — don't quietly skip them.

**When it isn't a unit test** — layout, rendering, contrast, encoding, config drift — still leave something executable:

- DOM/visual → assert the measurement (geometry, computed style, overflow, contrast ratio), not the screenshot.
- Whole-file corruption (encoding, escaping, malformed markup) → a check that parses or greps the built artifact.
- Genuinely un-automatable → commit the reproduction steps as an explicitly skipped test naming the reason. That is the one sanctioned skip; it is not the same as skipping to go green.
