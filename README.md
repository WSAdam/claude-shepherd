# Claude Shepherd

**A fleet console for Claude Code on macOS.** One floating panel shows every Claude Code session
you have running, tells you which one needs you, and lets you approve, answer, steer and merge them
without hunting for the right window.

![Shepherd's panel: six sessions, three of them waiting on you](docs/img/panel.png)

## Why

Running several Claude Code sessions at once makes you the bottleneck. A session that finishes, asks
a question or hits a permission prompt sits idle until you notice. With parallel worktrees on top,
you also have to keep track of which branch is done, which tests passed, and which tab to close.

Shepherd puts all of that on one screen:

- **Who needs you, right now.** Each project is a card. A card reads **Needs you** only when there
  is something for you to press.
- **Answer from the panel.** Approve or deny a tool, answer a question, or review and merge a unit
  in the panel. You don't have to find the tab, and nothing is typed into a window.
- **Parallel work that lands safely.** Units in their own worktrees ask to merge. Shepherd checks
  the request with its own git, can run the tests itself, and closes the tab afterwards.

It runs inside [Hammerspoon](https://www.hammerspoon.org) and reads status files that Claude Code
hooks write on your Mac. It has no server or account of its own; its one default network call reads
your plan usage from api.anthropic.com with your existing Claude Code login.

## Feature tour

Every feature below has a reference page one click away. The panel lists the same features under
**☰ → ✨ Features list**.

### See

- [**Fleet dashboard**](docs/fleet.md#statuses): every session is a live tile: working, needs you,
  ready, or errored.
- [**How each turn ended**](docs/fleet.md#statuses): a finished card says whether its last turn got
  done, made progress, only planned, did nothing, got blocked, or needs follow-up.
- [**Project cards & instances**](docs/fleet.md#project-cards-and-instances): a repo and its
  worktrees share one card that leads with the instance that needs you; its corner button lists
  every instance.
- [**Transcript peek**](docs/fleet.md#the-detail-panel): read a session's recent messages, and
  search them, inside the panel.
- [**Find in fleet**](docs/fleet.md#search-groups-and-bulk-actions): search every session's
  transcript and the audit ledger for the session that touched a file or ran a command.
- [**Groups & labels**](docs/fleet.md#search-groups-and-bulk-actions): rename tiles, sort them into
  groups, and filter the grid to one group.
- [**Worklist (My List)**](docs/fleet.md#my-list): a checklist beside the fleet that imports each
  project's `TODO.md`, so you can verify what an automation says it finished.
- [**User stories**](docs/fleet.md#user-stories-tab): view and edit a project's
  `spec/product/user-stories.md` in a detail-panel tab.
- [**Audit ledger & insights**](docs/usage-and-cost.md#the-audit-ledger): an optional local log of
  everything that happens, with fleet insights, decision provenance and session history.
- [**Cost & token analytics**](docs/usage-and-cost.md#cost-and-tokens): per-session and fleet token
  use, estimated dollars, and a 14-day chart.
- [**Plan usage meter**](docs/usage-and-cost.md#plan-window-bars): your real 5-hour and weekly plan
  usage, with a warning at every point past 90%.
- [**Commits today and this week**](docs/usage-and-cost.md#commits-today-and-this-week): your
  commits and lines changed, per day and per project, straight from local git.
- [**Shift report**](docs/usage-and-cost.md#shift-report): a summary of what the fleet did while you
  were away.

### Steer

- [**Jump, nudge, stop, clear**](docs/controls.md#the-detail-panel): focus a session's tab, send it
  a message, stop its turn, or clear or compact it, from its tile.
- [**Answer questions from Shepherd**](docs/approvals-and-policies.md#answer-questions-from-shepherd):
  a session's question shows up on its card as buttons, and your click goes straight to the session.
- [**Spawn new sessions**](docs/controls.md#spawn-new-sessions): start a session in any project with
  an editor, permission mode, provider and first task, or from a saved preset.
- [**Rewind & checkpoints**](docs/fleet.md#the-detail-panel): see each turn's restore point and the
  files it changed, then open Claude Code's rewind picker.
- [**Global hotkeys**](docs/controls.md#global-hotkeys): approve, jump to whoever needs you, cycle,
  spawn and show the panel from any app.
- [**Stream Deck**](docs/controls.md#stream-deck): sessions and fleet actions on physical keys, with
  local voice dictation.
- [**Remote control**](docs/providers-and-integrations.md#remote-control-claudeai-and-mobile): new
  sessions can be driven from claude.ai or the Claude app.

### Automate

The automatic behaviours here are off until you turn them on.

- [**Task queue & auto-feed**](docs/automation.md#task-queue): line up tasks per session, feed the
  next when one finishes, and route a project's tasks to whichever session is free.
- [**Prompt templates**](docs/automation.md#prompt-templates): reusable, versioned prompts with
  variables filled in at send time.
- [**Model auto-routing**](docs/automation.md#model-auto-routing): a queued task switches the
  session to a cheaper or stronger model based on how hard it looks.
- [**Auto-respawn & auto-continue**](docs/automation.md#auto-respawn-and-auto-continue): relaunch a
  session that died mid-turn, or resume one frozen on an API error, within retry budgets.
- [**Automation rules**](docs/automation.md#automation-rules): when a session finishes, errors or
  stalls, log it, relabel it, nudge it or feed it.
- [**Routines**](docs/automation.md#routines): spawn a session or push a digest on a cron schedule.
- [**Notifications & escalation**](docs/automation.md#escalation-and-watchdogs): louder nags, macOS
  banners and phone pushes when a session has waited on you too long or stalled.
- [**A/B compare**](docs/automation.md#ab-compare): run one task as 2–4 variants in separate
  worktrees, score them, and keep the winner.

### Merge safely

- [**New worktree tab**](docs/merging-and-batches.md#new-worktree-tab): start a unit in a new
  Claude tab with the prompt to enter its own worktree already typed in.
- [**Ready to merge**](docs/merging-and-batches.md#ready-to-merge): a finished unit asks to merge,
  and you review its commits, files, diff and tests before pressing **Merge**. Then it rebases,
  tests and fast-forwards main, one merge per repo at a time.
- [**Merge gates**](docs/merging-and-batches.md#merge-gates-shepherd-runs-the-tests-itself):
  Shepherd runs the project's suite itself, before the merge and again on main after it.
- [**Claude drives a batch**](docs/merging-and-batches.md#claude-drives-a-batch): a session proposes
  several units, you approve once, and it opens their tabs and hands out the tasks.
- [**Tab bridge**](docs/merging-and-batches.md#the-tab-bridge): a small VS Code extension that
  closes or selects exactly one Claude tab, so finished units close their own tabs.

### Stay safe

- [**Headless approvals**](docs/approvals-and-policies.md#headless-approvals-the-gate): risky tools
  wait for your Approve or Deny in the panel, with no window switching.
- [**Policy bundles & autopilot**](docs/approvals-and-policies.md#policies): reusable allow and deny
  rules per session or fleet, and a time-boxed autopilot.
- [**Shared-window guard**](docs/controls.md#sessions-that-share-a-window): Shepherd won't type into
  a window that hosts several sessions, because the keys could land in the wrong tab.
- [**Keep awake & screen lock**](docs/controls.md#keep-this-mac-awake): keep the Mac awake for long
  runs, and lock the screen without pausing the sessions.
- [**Diagnostics**](docs/troubleshooting.md#start-with-diagnostics): a one-screen health check of the
  hooks, the gate, the panel heartbeat, the tab bridge and the ledger, with fixes.

### Make it yours

- [**Visual theme editor**](docs/customizing.md#appearance): 50 themes, an editor for every colour
  with live preview, and theme export and import.
- [**Layout & density**](docs/customizing.md#layouts): cards, bar, contrast or dots, with scale,
  tile width, font, density and reduced motion.
- [**Faster rendering**](docs/customizing.md#faster-rendering): the grid is rebuilt only when a
  card's content changed; otherwise only the ages update.

### Connect

- [**Providers & models**](docs/providers-and-integrations.md#providers-and-models): Claude models,
  other companies' models through a gateway, or local models, with no API keys stored.
- [**Agent profiles**](docs/providers-and-integrations.md#agent-profiles): saved agents with a role,
  skills, MCP servers and knowledge folders, spawned in one click.
- [**MCPs & Skills**](docs/providers-and-integrations.md#mcps-and-skills): what MCP servers, skills
  and command-line tools your sessions can reach.
- [**SSH status bridge**](docs/providers-and-integrations.md#ssh-status-bridge): sessions running on
  another machine, mirrored as tiles.

![A ready-to-merge review in the detail panel](docs/img/merge-review.png)

## How it works

```text
Claude Code session ──hooks──► ~/.claude/cc-status/<session>.json ──► Shepherd panel (Hammerspoon)
       ▲                                                                       │
       └── gate hook waits for a decision file ◄────────── Approve / Deny ─────┤
VS Code window ◄── tab bridge extension: close or select one Claude tab ◄──────┘
```

- **Hooks write, the panel reads.** Claude Code hooks ([cc-status.sh](cc-status.sh) and friends)
  write one small JSON file per session. The panel, Lua running inside Hammerspoon, reads them every
  second and writes a heartbeat so the hooks know it's alive.
- **Answers are files, not keystrokes.** The approval gate, held questions, merge requests and
  batches wait for a decision file bound to their request. That works in any editor, even with many
  tabs in one window.
- **Keystrokes only where they're safe.** Nudges, feeds and slash commands type into the session's
  window, so Shepherd refuses them for a window that hosts several sessions.
- **The tab bridge** is a small VS Code extension that closes or selects exactly one Claude tab on
  Shepherd's request.

More in [Development → How it fits together](docs/development.md#how-it-fits-together).

## Install

You need macOS. The installer gets the rest.

1. Download the repo (**Code → Download ZIP**, then unzip) or `git clone` it.
2. Double-click **`Install Shepherd.command`** (for a downloaded copy: right-click → **Open** the
   first time). It installs what's missing (Xcode command-line tools, Homebrew, `jq`, `lua`, `node`,
   Hammerspoon, VS Code, Claude Code and its extension), then Shepherd itself.
3. Once, by hand: allow **Hammerspoon** in System Settings → Privacy & Security → **Accessibility**,
   and sign in to Claude in VS Code. The panel appears top-right.

`Install Shepherd.command` runs `bootstrap.sh` (the prerequisites), which runs `install.sh`
(Shepherd). Already have the tools? Run `make setup`. Re-running either is safe.

**Upgrade** after a `git pull` with `make setup` (not `make install`), then Hammerspoon → **Reload
Config**, and **Developer: Reload Window** in VS Code windows that were already open.

**Uninstall** with **`Uninstall Shepherd.command`** or `make uninstall`. Your settings and history
stay unless you ask to remove them.

Details, including what the installer changes in your Claude Code settings:
[docs/install.md](docs/install.md).

## The daily workflow

Shepherd is built around one rule: **one unit of work = one branch = one worktree = one Claude
session.**

1. **Start a unit.** Right-click a card → **New worktree tab…** (or ask a session to do it). The new
   tab enters its own worktree under `.claude/worktrees/` and works there.
2. **Watch the cards.** Answer approvals and questions from the panel as they come up.
3. **Merge.** When the unit is done and green, it asks to merge. Review it on its card and press
   **Merge**; it rebases, tests and fast-forwards main, then its tab closes.
4. **Or hand over a batch.** Ask one session to run several units in parallel. You approve the batch
   once, and choose whether it may merge the units when they're green.

The installer puts these working rules into `~/.claude/CLAUDE.md`, so every session follows them:
[methodology/CLAUDE.md](methodology/CLAUDE.md). To see the whole loop, run the
[worktree demo](docs/merging-and-batches.md#try-it-the-worktree-demo) (`make demo`).

## Configuration

- **⚙ Settings** in the panel covers nearly everything, with a one-line explanation per switch.
- It writes `~/.claude/cc-config.json`. [cc-config.example.json](cc-config.example.json) documents
  most keys. [defaults/cc-config.json](defaults/cc-config.json) is what a fresh install starts with,
  and `make setup` adds any of its keys you haven't set.
- The automations (queue, rules, routines, respawn, auto-continue, escalation, policies) are off
  until you turn them on. A few conveniences are on by default: held questions, Remote Control for
  spawned sessions, and ending leftover processes that have no tab.

Reference: [docs/configuration.md](docs/configuration.md).

## Safety model

- **Nothing is gated until you arm the gate.** Turn on ⚙ Settings → Approvals → **Headless
  approvals** and the tools in `gate.tools` (Bash, Write, Edit, MultiEdit, NotebookEdit by default)
  wait for your Approve or Deny in the panel.
- **What can approve without you**, only while the gate is armed and only if you turned it on: an
  `autoAllow` pattern or an attached policy bundle, Autopilot (time-boxed, per session), and
  "approve repeats" of the exact command you approved before. `autoDeny` always wins. Headless
  approvals turns off approve-repeats, Autopilot and the fleet patterns; an attached bundle keeps
  working until you detach it.
- **When the gate can't answer, Claude Code decides.** When the gate is off, the tool isn't gated,
  Shepherd wasn't running when the request came in, or 120 seconds pass without an answer, the gate
  steps aside and Claude Code's own permission mode decides. In the default mode you get the normal
  prompt in the tab. In Accept edits, Auto or Bypass permissions mode there may be no prompt at
  all. The gate never approves on a timeout.
- **Never automatic:** answering a session's question, merging without your **Merge** or a batch
  grant you gave, and closing a session you didn't ask to close. (Exceptions: a finished unit's own
  tab closes after its merge, and a leftover process with no tab is ended after it has sat idle.)
- **Remote Control is on by default**: sessions Shepherd spawns get it, Shepherd re-arms it in
  running terminal sessions at startup, and the installer turns on Claude Code's own
  `remoteControlAtStartup` where you haven't set it. It widens who can type into a session to anyone
  with your claude.ai account. Turn it off in ⚙ Settings → Spawn and in Claude Code's `/config` if
  that's too broad.

Full detail: [docs/approvals-and-policies.md](docs/approvals-and-policies.md#the-safety-model).

## Troubleshooting

- **☰ → 🩺 Diagnostics** checks the hooks, the gate, the panel heartbeat, the tab bridge and the
  ledger, and says how to fix what's wrong. `make doctor` checks the command-line tools.
- **Shepherd has no process of its own.** It runs inside Hammerspoon, so `pgrep shepherd` finds
  nothing even when it's running. The panel heartbeat (`~/.claude/cc-status/.panel-alive`) is the
  signal: `~/.claude/cc-fleet.sh alive` reads it.
- **Changes didn't take effect?** Run `make setup`, reload Hammerspoon, and reload older VS Code
  windows.
- **Logs:** `tail -f ~/.claude/cc-shepherd.log`.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

| Page | What's in it |
|------|--------------|
| [Install](docs/install.md) | Install, upgrade, uninstall, what the installer changes, the tab bridge, the Dock launcher |
| [Fleet](docs/fleet.md) | Statuses, project cards, Instances, the detail panel and its tabs, search, groups, My List |
| [Controls](docs/controls.md) | Clicks and menus, detail-panel buttons, shared windows, spawning, hotkeys, Stream Deck, awake and lock |
| [Approvals and policies](docs/approvals-and-policies.md) | The safety model, the gate, policies and bundles, answering questions |
| [Merging and batches](docs/merging-and-batches.md) | Worktree tabs, ready to merge, merge gates, batches, the demo, the tab bridge |
| [Automation](docs/automation.md) | Queue, templates, routing, auto-model, respawn, escalation, rules, routines, A/B compare |
| [Usage and cost](docs/usage-and-cost.md) | Context bars, plan usage, cost, commits, the audit ledger and its views |
| [Providers and integrations](docs/providers-and-integrations.md) | Providers and models, agent profiles, MCPs and skills, Remote Control, the SSH bridge |
| [Make it yours](docs/customizing.md) | Layouts, themes, colours, sizing |
| [Configuration](docs/configuration.md) | Settings tabs, `cc-config.json`, the files Shepherd keeps, environment variables |
| [Troubleshooting](docs/troubleshooting.md) | Diagnostics, "is it running?", logs, common problems, known limits |
| [Development](docs/development.md) | Architecture, tests, deploying, screenshots |
| [Reverse-engineering user stories](docs/reverse-engineering-user-stories.md) | Writing `spec/product/` for an existing project |

Also: [methodology/CLAUDE.md](methodology/CLAUDE.md) (the working rules sessions follow),
[demo/GUIDE.md](demo/GUIDE.md) (the worktree demo), [CHANGELOG.md](CHANGELOG.md) (what changed),
and [context.md](context.md) (orientation for working on Shepherd itself).

## License

[MIT](LICENSE).
