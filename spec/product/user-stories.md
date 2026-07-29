# Claude Shepherd — User Stories

User stories derived from [spec.md](./spec.md) — reverse-engineered from the shipped app
(README + code), capturing what Claude Shepherd does today as demoable stories. Shepherd is
a floating, always-on-top Mac fleet console for **Claude Code** sessions — one tile per
session, with control, observability, automation, and governance from a single pane.

Stories are grouped by capability area and written in the canonical form
"As a `<role>`, I want `<capability>`, so that `<benefit>`". Three roles recur:
the **fleet operator** (supervising many Claude Code sessions at once), the
**developer** (focused on the work inside one session), and the **reviewer**
(looking at what the fleet did, for governance and accountability).

This is a living document we'll iterate on before extending the pattern to other
projects. Capabilities still in design (routing topology, in-panel bundle/agent
editors, the routine board) are intentionally omitted until they ship.

## Fleet overview & status

- As a **fleet operator**, I want one always-on-top tile per Claude Code session showing its project and a live color-coded status, so that I can see the whole fleet at a glance without hunting through windows.
- As a **fleet operator**, I want each session keyed by its session_id, so that two sessions in the same folder never collapse into one tile.
- As a **fleet operator**, I want a tile to pulse red when its session needs permission or input, so that I can tell instantly which agent is blocked on me right now.
- As a **fleet operator**, I want a tile to turn green when its turn finishes, so that I know which sessions are ready for my next instruction.
- As a **fleet operator**, I want stale tiles to dim after ~90s of silence and disappear on SessionEnd, so that the grid reflects what's actually alive after a crash or clean exit.
- As a **fleet operator**, I want a "done" tile to self-heal back to "working" when the transcript shows the model resumed, so that an auto-continued turn isn't mistaken for one waiting on me.
- As a **fleet operator**, I want each tile to show time-in-state, the latest prompt, and the exact command being requested on an approval, so that I can triage what a session needs before opening it.
- As a **fleet operator**, I want a live "Doing:" activity peek from the selected session's transcript, so that I can see what an agent is currently working on without switching to it.
- As a **fleet operator**, I want duplicate "ghost" tiles left by /clear or restart auto-pruned by matching them to the same window, so that the grid stays clean without manual cleanup.

## Session observability

- As a **fleet operator**, I want an errored tile to show a coarse cause badge (budget exceeded, timeout, runtime error, model error, user cancelled), so that I know why a session froze without reading its logs.
- As a **developer**, I want the panel to show a session's current plan and TODO list, so that I can see what the agent intends to do next.
- As a **fleet operator**, I want unlabeled tiles optionally auto-named from their first prompt, so that I can recognize sessions without relabeling each one by hand.
- As a **fleet operator**, I want a loop-watchdog badge when a session keeps repeating the same tool call, so that I can spot an agent stuck re-running a failing command.
- As a **fleet operator**, I want optional native macOS banners when a session needs me, finishes, or auto-approves a tool, so that I'm pulled back to it even when the panel isn't in front of me.
- As a **reviewer**, I want an optional post-run self-summary typed into a session after each turn, so that the running log carries a short record of what the agent just did.
- As a **fleet operator**, I want an optional clickable "PR #N open/merged" badge per repo, so that I can track a session's pull request status without leaving the panel.
- As a **fleet operator**, I want a host-stats strip (CPU/memory/disk/uptime/load) plus fleet idle-since in the insights overlay, so that I can tell when the machine is too pressured to take on more work.
- As a **fleet operator**, I want subagents and Workflow fan-outs listed in an Agents tab grouped by Workflow with a running/total rollup, so that I can see and drill into delegated background work.
- As a **fleet operator**, I want a tile to show a "⚙ N" pill and "Running N agents" while background subagents work, so that a busy session isn't mistaken for one idly waiting on me.
- As a **reviewer**, I want a 0–100 run score per session computed from the ledger with a trend sparkline, so that I can spot sessions whose quality is degrading.

## Controlling a session

- As a **developer**, I want to jump straight to a session's editor window from its tile, so that I can take over hands-on without searching my Spaces.
- As a **developer**, I want to approve or deny a pending permission prompt from the panel, so that I can unblock a session without switching to it.
- As a **developer**, I want a Stop button that interrupts the current turn, so that I can halt an agent going the wrong direction.
- As a **developer**, I want a one-click Continue when a session freezes on an API error, so that I can resume the same aborted turn instead of relaunching it.
- As a **developer**, I want a multi-line nudge box where Enter sends and Shift+Enter adds a newline, so that I can type or paste a multi-item instruction that arrives intact.
- As a **developer**, I want to paste an image into the nudge box and send it as an attachment, so that I can hand a session a screenshot or diagram.
- As a **developer**, I want to set a session's reasoning effort live from an Effort dropdown, so that I can dial a model up or down for the task at hand.
- As a **developer**, I want to switch a session's permission mode (Default/Accept edits/Plan) live, so that I can loosen or tighten autonomy without restarting it.
- As a **developer**, I want to switch a running session's model live from a Model dropdown reflecting what's actually running, so that I can change models mid-task without a fresh session.
- As a **developer**, I want Clear and Compact buttons with a confirm, so that I can reset or shrink a session's context safely from the panel.
- As a **fleet operator**, I want an Improve action that sends this repo's un-applied leaderboard insights to a session as a review-first prompt, so that I can fold in suggested improvements without blind wholesale edits.
- As a **developer**, I want the Wants and Why lines clamped to two lines but click-to-expand, so that I can scan many tiles yet still read the full reasoning when I care.

## Headless approvals (the gate)

- As a **fleet operator**, I want a one-click "Headless approvals" switch that arms the gate and turns off every auto-policy, so that I can approve/deny reliably with no window focus or keystrokes.
- As a **fleet operator**, I want the gate to hold a configurable list of risky tools (Bash/Write/Edit/…) until I decide, so that an agent can't run a dangerous tool without my sign-off.
- As a **fleet operator**, I want headless approvals to work for both terminal and VS Code-extension sessions, so that my whole fleet is governable regardless of editor.
- As a **fleet operator**, I want to override the gated-tool list per session (Default/All/None/Custom), so that I can lock down a risky experiment while letting a trusted session run free.
- As a **fleet operator**, I want an Autopilot button that time-boxes a session to auto-approve all its prompts, so that I can let a trusted run proceed unattended for a bounded window.
- As a **fleet operator**, I want pattern allow/deny globs where deny always wins, so that I can pre-authorize safe commands and hard-block dangerous ones fleet-wide.
- As a **fleet operator**, I want the gate to fall back to Claude's native prompt if I don't answer in time, so that a session is never permanently wedged waiting on me.

## Named policy bundles

- As a **fleet operator**, I want reusable named policy bundles (read-only, no-bash, no-network), so that I can apply a consistent guardrail set instead of editing one global list.
- As a **fleet operator**, I want to attach a bundle to a session via the Policy dropdown, so that I can give one session tighter rules without touching the others.
- As a **fleet operator**, I want bundles auto-attached by project/group/provider/session glob, so that sensitive projects get locked-down rules without per-session setup.
- As a **fleet operator**, I want a bundle to optionally replace rather than union the fleet patterns, so that a strict session ignores looser global allowances.

## Spawning sessions

- As a **fleet operator**, I want a New session modal to launch a session in a chosen folder and editor, so that I can start work from the panel without a terminal.
- As a **fleet operator**, I want to start a brand-new project that opens reliably past the cold-start/trust prompts and lands its initial task, so that a fresh folder actually starts working.
- As a **fleet operator**, I want savable presets that spawn a folder+editor+mode+provider bundle in one click, so that I can relaunch a familiar setup instantly.
- As a **fleet operator**, I want fuzzy folder search over my project roots as I type, so that I can pick a project by a name fragment instead of a full path.
- As a **fleet operator**, I want a folder browser and recent-folder chips, so that I can find and reopen projects I work in often.
- As a **fleet operator**, I want to choose the editor (Terminal/Kitty/VS Code/Cursor) and permission mode at spawn, so that each session starts the way that task needs.
- As a **fleet operator**, I want spawning to be dry-run until I explicitly opt in, so that I can preview the exact launch command before anything actually runs.
- As a **fleet operator**, I want savable agent profiles (persona + provider/model + skills/MCP/knowledge/plugins) I can spawn from in one click, so that I can hand work to a configured agent reproducibly.
- As a **fleet operator**, I want Shepherd-spawned local sessions to register Claude Code Remote Control automatically, so that I can drive them from claude.ai or mobile with no extra step.

## Providers & models

- As a **fleet operator**, I want named provider profiles that inject env vars + a model id into the launch, so that I can run sessions against different models and backends.
- As a **fleet operator**, I want gateway providers that set a base URL to an Anthropic-compatible endpoint, so that I can run Gemini/OpenAI/local models through LiteLLM while keeping Shepherd's controls.
- As a **fleet operator**, I want providers to reference an env-var name for the key rather than store the secret, so that my API keys never live in Shepherd's config or process.
- As a **fleet operator**, I want a default provider plus per-session selection, so that I can standardize on one model yet override it where a task needs another.
- As a **fleet operator**, I want the tile to badge the model that's actually running, so that I can confirm at a glance which backend a session is on.

## Task queue & routing

- As a **developer**, I want a per-session task queue I can add to and feed the next item from, so that I can line up work for a session to pick up later.
- As a **fleet operator**, I want optional autofeed that sends the next queued task when a session finishes, so that a session works through a backlog unattended.
- As a **fleet operator**, I want feeds to pop a task only once the paste actually reached the window, so that a missed delivery leaves the task queued instead of silently lost.
- As a **developer**, I want to expand, reorder, and remove queued tasks in place, so that I can manage a backlog without retyping it.
- As a **developer**, I want to bulk-paste a multi-line list into one queued task per line, so that I can load a backlog in one action.
- As a **developer**, I want parameterized, versioned task templates with required/optional and built-in variables, so that I can reuse standard prompts and fill them in before they're sent.
- As a **fleet operator**, I want a project's queue to feed whichever of its sessions is free, so that parallel sessions in one folder drain a shared backlog.
- As a **fleet operator**, I want queue-line routing syntax (@role / @all / @any / seq), so that I can target tasks to a role, gate on join barriers, or force one-at-a-time processing.
- As a **reviewer**, I want each routed/queued task timed from feed to completion, so that the shift report can show throughput and average duration.

## Automation & policies

- As a **fleet operator**, I want one settings file (and a ⚙ Settings panel) governing all automatic behavior with everything off by default, so that nothing acts on my fleet until I opt in.
- As a **fleet operator**, I want escalation that nags harder (stronger pulse, optional sound/push) when an approval waits too long, so that a forgotten prompt eventually gets my attention.
- As a **fleet operator**, I want optional focus-pop of the editor when a session completes or needs approval, so that the right window comes forward at the moment it matters.
- As a **fleet operator**, I want declarative event-callback rules that react to a done/error/approval edge with a safe effect (log/relabel/nudge), so that I can automate small reactions without writing code.
- As a **fleet operator**, I want scheduled routines (cron/one-shot) that spawn sessions or push a digest, so that recurring work like nightly tests runs on its own.
- As a **fleet operator**, I want a per-session risk indicator computed from its ledger history, so that I can notice a session accumulating denials and odd behavior.
- As a **fleet operator**, I want collision warnings when two active sessions share a working directory, so that two agents don't silently clobber each other's edits.
- As a **fleet operator**, I want a Drain action that finishes the current turn then closes a session, so that I can retire a session without interrupting its work.
- As a **fleet operator**, I want manual and automatic respawn of a session frozen mid-turn, capped per folder, so that a crashed run recovers without me and a crash-loop can't thrash.
- As a **fleet operator**, I want optional Auto-Continue that resumes a session frozen on an API error, capped per folder, so that transient connection failures recover hands-free.

## Fleet navigation & bulk actions

- As a **fleet operator**, I want a search bar that filters the grid by name/project/status/group as I type, so that I can find a session fast in a large fleet.
- As a **fleet operator**, I want to tag sessions into named groups and scope the grid to one, so that I can supervise a cohort of related sessions together.
- As a **fleet operator**, I want bulk Approve all / Stop all over the currently visible sessions, so that I can act on many sessions at once instead of one by one.
- As a **fleet operator**, I want the Fleet bar to shrink its buttons rather than wrap to a second row, so that a narrow panel keeps the whole fleet row on one line.
- As a **fleet operator**, I want a custom persistent relabel per project keyed to its launch folder, so that a tile keeps a meaningful name across reloads, respawns, and directory changes.

## Global hotkeys

- As a **fleet operator**, I want a hotkey to approve the front approval from any app, so that I can unblock the waiting session without raising the panel.
- As a **fleet operator**, I want a hotkey that jumps to the session that most needs me (approval, then error, then stall), so that I always land on the most urgent one first.
- As a **fleet operator**, I want hotkeys to cycle-jump sessions, spawn a new one, and show/hide the panel, so that I can drive the fleet from the keyboard.
- As a **fleet operator**, I want every hotkey remappable in config with a live in-panel legend, so that I can avoid conflicts and never forget the bindings.

## Audit log & governance

- As a **reviewer**, I want an opt-in append-only JSONL ledger of session lifecycle, prompts, tool requests, and gate decisions with provenance, so that I have an accountable record of what the fleet did.
- As a **reviewer**, I want a Fleet insights overlay aggregating turns, approval/denial rates, decision provenance, and time the fleet spent blocked on me, so that I can see where my attention is the bottleneck.
- As a **fleet operator**, I want a notification-history view of what fired while I was away, so that I can catch up on escalations, stalls, and auto-actions I missed.
- As a **reviewer**, I want a one-click shift report rolling up what the fleet did over a window, so that I can summarize unattended activity and copy it out.
- As a **reviewer**, I want a session-history browser with filter/sort/pin and scoped multi-select delete, so that I can review and prune recorded session history without touching Claude's transcripts.
- As a **reviewer**, I want per-row redact/export/purge and a GC'd retention policy on the ledger, so that I can keep the record useful without it growing unbounded or leaking sensitive lines.
- As a **reviewer**, I want session-lineage rollups for auto-respawns and /clears, so that I can recognize a crash-loop survivor instead of seeing a churn of unrelated session ids.
- As a **fleet operator**, I want to search every live and dead session's transcript and the ledger, so that I can answer "which session touched this file?" across the fleet.
- As a **reviewer**, I want a "Review activity" prompt that sends a ledger slice to a session as a read-only governance review, so that an agent can assess risky actions without editing anything.

## Token & usage tracking

- As a **fleet operator**, I want a per-tile context-fullness bar with a numeric percent, so that I can tell which session to /compact before it auto-compacts.
- As a **fleet operator**, I want a fleet token total and an estimated API-equivalent dollar figure in the footer, so that I can gauge overall consumption at a glance.
- As a **fleet operator**, I want real plan-window (5h and weekly) utilization bars from my Claude login, so that I can see how close I am to my usage limits.
- As a **fleet operator**, I want all usage read locally from transcripts with the plan call being a metadata-only request, so that monitoring usage spends no model tokens.

## Working with a session's project

- As a **developer**, I want a Changes tab showing the session folder's git status with click-to-expand colorized diffs, so that I can review what an agent changed without leaving the panel.
- As a **developer**, I want a Transcript tab with recent turns and search, so that I can read back what happened in a session.
- As a **developer**, I want a Rewind tab of checkpoints and recorded activity, so that I can revisit a session's earlier states.
- As a **developer**, I want a Decisions tab showing the session's recent gate decisions with provenance, so that I can see what the gate has been doing right where I act.
- As a **developer**, I want a project-aware User Stories tab to view and edit spec/product/user-stories.md grouped by capability area, so that I can keep a project's stories current from inside Shepherd.
- As a **developer**, I want a soft warning on any story missing the mandatory "so that", so that I keep stories in the canonical form without it blocking my save.
- As a **developer**, I want story saves hash-guarded against external edits and written atomically with non-story content preserved verbatim, so that editing stories can never corrupt or clobber my file.
- As a **developer**, I want an Export action that archives a session's transcript plus metadata and reveals it in Finder, so that I can keep a record of a finished session.

## Remote sessions (SSH bridge)

- As a **fleet operator**, I want SSH-provider sessions running on a remote box to appear as live ⇄ tiles, so that I can monitor remote agents alongside local ones.
- As a **fleet operator**, I want remote tiles to be headless-only with approve/deny routed back as nonce-bound decision files, so that I can govern remote sessions safely without keystroke control.
- As a **fleet operator**, I want a stalled remote sync to show "bridge offline" on the tile, so that I don't trust a stale remote status as current.

## Reference catalogs (MCPs & Skills)

- As a **fleet operator**, I want a read-only catalog of installed MCP servers with scope/transport/command but never secret values, so that I can see what's configured without exposing credentials.
- As a **fleet operator**, I want an on-demand re-check that merges live connector health (connected/failed/needs-auth) into the list, so that I can confirm my MCPs are actually working.
- As a **fleet operator**, I want a list of my skills and slash commands plus the CLI's built-ins, so that I can see what capabilities are available to my sessions.
- As a **fleet operator**, I want a CLI-tools panel showing each external dependency as installed/missing with its resolved path, so that I can tell what's set up and what falls back.

## Worklist (My List)

- As a **fleet operator**, I want a built-in checklist that swaps in over the tiles, so that I can track my own to-dos without leaving the panel.
- As a **fleet operator**, I want a global list plus one tab per project that has a live session OR a saved list, persisted by launch-folder identity, so that a project's to-dos never disappear when its window is idle or closed.
- As a **fleet operator**, I want to add, check, delete, and clear worklist items, so that I can manage my list without leaving the panel.
- As a **fleet operator**, I want one modal that captures an item's subject, details, and expected date, so that a to-do carries its context instead of being a bare line of text.
- As a **fleet operator**, I want to nudge an item's expected date a day at a time with ◀ ▶, so that I can reschedule without opening the date picker.
- As a **fleet operator**, I want a checklist of sub-steps inside an item that saves the moment I tick one, so that I can check off mini pieces as I go without losing progress.
- As a **fleet operator**, I want each list row to show its date (amber today, red overdue) and its checklist progress, so that I can see what's pressing at a glance.
- As a **fleet operator**, I want a read-only MASTER tab that rolls every open item up by date priority, tagged with its list, so that I can see everything I owe across projects in one place.
- As a **fleet operator**, I want to tick an item done from MASTER and have it write to its own list, so that I can clear work from the rollup without switching tabs.
- As a **fleet operator**, I want clicking a MASTER row to jump to that item's tab with the item open, so that the rollup is a way in, not a dead end.
- As a **fleet operator**, I want a MASTER "Recently completed" drawer showing what I finished in the last 7 days across all lists, so that I can review recent progress without hunting through each scope's Done.
- As a **fleet operator**, I want each scope's Done area ordered by due date, so that completed work reads in a predictable order.
- As a **fleet operator**, I want every Done row to show both the date it was expected and the date I actually finished it, so that I can see whether I hit my own deadlines.
- As a **fleet operator**, I want to paste text into any modal field (subject, details, a step), so that I can drop in context without it landing in the nudge box.

## Keeping the Mac & fleet running

- As a **fleet operator**, I want a ☕ keep-awake toggle that prevents sleep even with the lid closed, so that long unattended agent runs aren't interrupted.
- As a **fleet operator**, I want a 🔒 soft-lock overlay that blocks input while everything keeps running, so that I can step away with the fleet working and casual access deterred.
- As a **fleet operator**, I want a force-unlock chord and release on quit/reboot, so that a typo at the lock screen can never lock me out.

## Personalization & ergonomics

- As a **fleet operator**, I want to hide detail-panel tabs I don't use and have my last-open tab remembered per project, so that the panel shows only what I care about.
- As a **developer**, I want AskUserQuestion options rendered as clickable buttons (driven directly on Kitty, jump-to on VS Code), so that I can answer an agent's question from the panel.
- As a **fleet operator**, I want selectable themes, so that the panel fits how I like to work.
- As a **fleet operator**, I want a Stream Deck integration mirroring panel actions, so that I can drive the fleet from physical keys.

## Install & first run

- As a **fleet operator**, I want a ~5-minute install plus an optional Dock launcher and launch-on-startup, so that I can get Shepherd running and keep it running with little setup.
- As a **fleet operator**, I want a way to test the panel without Claude and confirm my hook payloads once, so that I can verify the setup before relying on it for real sessions.
- As a **fleet operator**, I want an always-reliable menu-bar 🐑 icon to show the panel, so that I can bring it back even after a native Dock-minimize.
