# Configuration

[← README](../README.md) · [Install](install.md) · [Approvals and policies](approvals-and-policies.md)

Most of Shepherd's behaviour is governed by one settings file, `~/.claude/cc-config.json`. (The
gate's on/off switch is the flag file `~/.claude/cc-gate.enabled`; the layout and the panel's size
live in Hammerspoon's settings; launch at login is Hammerspoon's own login item.)

**What's on.** With no file at all, nothing acts on a session by itself apart from a few
conveniences: held questions, resume at a usage limit's reset, worktree leases, Remote Control for
spawned sessions, ending tab-less leftovers, plan-limit alerts, the
[fleet idle alert](automation.md#fleet-idle-alert) (`alerts.idleMinutes`, 15 minutes), the
[My List review heads-up](fleet.md#my-list) (`worklist.reviewCount` 30 items, `worklist.reviewHours` 24 hours), the
[main moved notice](merging-and-batches.md#main-moved-sibling-worktrees-hear-about-a-merge)
(`merge.mainMovedNotice`) and closing a merged unit's tab. [Grant grading](merging-and-batches.md#grant-grading-a-risky-merge-waits-for-your-click)
holds back merges on a batch grant from the start (`merge.grantWaitsFor` unset means every
category). (The read-only background checks, such as commit counts, the overlap radar and the
scheduled-tasks lock check, are on too.) A fresh install writes the author's daily
settings ([defaults/cc-config.json](../defaults/cc-config.json)) when you have no file yet, and
those also turn on auto-continue, respawn, auto-compact, the three Stop guards (`stopGuards`), the
merge checker, the worktree fence, the audit ledger and real spawning. Escalation and the coach's own runs
(`coach.enabled`, which its weekly and evidence runs both need) stay off until you switch them on. On an upgrade, `make setup` adds any of the
defaults' keys you haven't set, and never changes one you have.

## The ⚙ Settings panel

Click **⚙** in the header for a form with most switches and a one-line explanation of each. **Save**
writes `~/.claude/cc-config.json` (creating it if missing) and arms or disarms the gate. Blocks the
form doesn't show survive a Save, and so do the hand-kept keys inside the blocks it does show: the
`spawn.matchWindowSize`, `risk.weights`, `spawn.searchRoots`, `bridge.staleSlackSeconds` and the
like, plus any `_`-prefixed note such as `_comment`. Any other key you add by hand inside a
form-managed block is dropped on Save. Its tabs:

- **General**: launch Shepherd at login; tile cleanup (`prune.hours`, `cleanup.idleHours`).
- **Appearance**: the layout, themes, colours, font, sizing, and the detail-panel switches
  ([Make it yours](customizing.md)).
- **Approvals**: **Headless approvals** and the gated tools, **Answer questions in Shepherd**, the
  advanced gate settings, the policies (approve repeats, allow/deny patterns), and the
  **Always ask** commands with your own additions
  ([Approvals and policies](approvals-and-policies.md)).
- **Automation**: escalation, the fleet idle alert, graceful drain, respawn,
  Auto-Continue, **Dry run** (all automation, or one feature at a time) and Auto-compact
  ([Automation](automation.md)).
- **Observability**: risk score, same-folder collision, insights, auto-title, loop watchdog, macOS
  banners, post-run summary, PR status, the hooks inventory, the audit log and **Measure storage**
  ([Usage and cost](usage-and-cost.md)).
- **Spawn**: editor window pop, spawn defaults (**Actually launch**, editor, flavour), Claude Code
  Remote Control and the SSH status bridge
  ([Controls](controls.md#spawn-new-sessions),
  [Providers and integrations](providers-and-integrations.md)).

File-only switches include, among others: `providers` and `spawn.provider`
([provider profiles](providers-and-integrations.md#providers-and-models)), `hotkeys`, `voice`, `pricing.*`, `merge.*`, `verify.*`,
`gate.fence`, `lease.*`,
`coach.*`, `radar.*`, `schedLock.*`, `timeLost.*`, `score.weights`,
`subagents.*`, `status.resumeSlack`, `autoContinue.backoff.*`, `fleet.enabled`, `commits.*`,
`usage.limitAlerts.*`, `ask.waitSeconds`, `ask.awayIdleSeconds`, `tabless.autoEndMinutes`, `escalation.hung`, `search.*`,
`worklist.*`, `decisions.*`, `notifications.days`,
`context.autoCompactFraction`, `stopGuards.*`, `alerts.onScreen` and
`alerts.voiceEvents`, and the `keystrokes`, `tabBridge` and `stacks` sections.

## Editing the file by hand

Copy [cc-config.example.json](../cc-config.example.json) to `~/.claude/cc-config.json` and flip what
you want. The example documents most keys with a `_comment`; the reference pages cover the rest.
The panel re-reads the file within about a second (except `hotkeys`, which need Hammerspoon →
**Reload Config**); the hooks read it on their next run.

| Section | What it controls | Reference |
|---------|------------------|-----------|
| `gate`, `policies`, `ask`, `stopGuards` | Gated tools, the worktree fence, auto-allow/deny, always-ask commands, held questions, the three Stop guards (questions asked in prose, "done" checked against the diff, the finished-unit merge reminder) | [Approvals and policies](approvals-and-policies.md) |
| `merge`, `verify`, `fleet`, `radar`, `tabBridge` | Ready to merge, merge gates, the merge checker, batches, the overlap radar, the tab bridge | [Merging and batches](merging-and-batches.md) |
| `coach` | The coach | [Automation](automation.md) |
| `respawn`, `autoContinue`, `resume`, `drain`, `prune`, `cleanup`, `tabless` | Recovery, resuming at a usage limit's reset, and cleanup | [Automation](automation.md), [Controls](controls.md#sessions-with-no-tab) |
| `compact` | Auto-compact at `atPct` with notes kept across it (sets `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in Claude Code's `settings.json`) | [Automation](automation.md#auto-compact-with-notes) |
| `escalation`, `notifications`, `focus`, `summary` | Nags, banners, focus pop, the self-summary | [Automation](automation.md) |
| `automation` (and each feature's `dryRun`) | Dry run for all automation, or one feature at a time | [Automation](automation.md#dry-run-and-the-automation-trace) |
| `autoTitle`, `prStatus`, `risk`, `collision`, `subagents`, `status` | Tile observability | [Fleet](fleet.md#session-observability) |
| `schedLock` | The 🔒 scheduled-tasks lock check on project cards | [Troubleshooting](troubleshooting.md#a-card-flags-a-scheduled-tasks-lock) |
| `ledger`, `decisions`, `insights`, `score` | The audit ledger and the views built on it, the run score's weights | [Usage and cost](usage-and-cost.md) |
| `usage`, `context`, `pricing`, `commits`, `timeLost` | Plan bars, limit alerts, context bar, cost, commit counts, where the time went | [Usage and cost](usage-and-cost.md) |
| `spawn`, `providers`, `remoteControl`, `bridge` | Launching sessions, backends, Remote Control, remote tiles | [Controls](controls.md#spawn-new-sessions), [Providers and integrations](providers-and-integrations.md) |
| `stacks`, `keystrokes`, `search`, `hotkeys`, `voice` | Project cards, the shared-window guard, search, shortcuts, Stream Deck voice | [Fleet](fleet.md), [Controls](controls.md) |
| `lease` | Each worktree's own port (`portFrom`–`portTo`) and database folder (`dbDir`) | [Fleet](fleet.md#worktree-leases) |
| `appearance`, `alerts`, `worklist` | Look, on-screen alerts, the fleet idle alert and spoken alerts, My List archive | [Make it yours](customizing.md), [Automation](automation.md#fleet-idle-alert), [Fleet](fleet.md#my-list) |

### Newer blocks and their defaults

The default is what the code does when the key is absent; the last column says where a fresh
install's [defaults](../defaults/cc-config.json) differ.

| Key | Default | Fresh install | Reference |
|-----|---------|---------------|-----------|
| `automation.dryRun` | `false` | | [Dry run](automation.md#dry-run-and-the-automation-trace) |
| `<feature>.dryRun` (`autoContinue`, `respawn`, `summary`, `tabless`, `mailbox`, `remoteControl`) | `false` | | [Dry run](automation.md#dry-run-and-the-automation-trace) |
| `autoContinue.backoff.startSeconds` / `maxSeconds` | `120` / `1800` (`startSeconds: 0` turns it off) | | [Auto-continue](automation.md#auto-respawn-and-auto-continue) |
| `compact.enabled` | `false` | `true` | [Auto-compact with notes](automation.md#auto-compact-with-notes) |
| `compact.atPct` / `notesLeadPct` | `85` / `5` | | [Auto-compact with notes](automation.md#auto-compact-with-notes) |
| `coach.enabled` | `false` (the 🧭 Coach button works either way) | | [The coach](automation.md#the-coach) |
| `coach.day` / `maxBudgetUsd` / `timeoutSeconds` | `"mon"` / `1` / `600` | | [The coach](automation.md#the-coach) |
| `coach.evidence.minItems` / `cooldownHours` / `dailyUsd` | unset: no evidence runs / `24` / `3` (evidence runs also need `coach.enabled`) | `10` | [Evidence runs](automation.md#the-coach) |
| `lease.enabled` | `true` | | [Worktree leases](fleet.md#worktree-leases) |
| `lease.portFrom` / `portTo` / `dbDir` | `4100` / `4199` / `~/.claude/cc-lease/db` | | [Worktree leases](fleet.md#worktree-leases) |
| `gate.fence` | `false` | `true` | [Worktree fence](approvals-and-policies.md#worktree-fence) |
| `policies.alwaysAsk.patterns` | `[]` (the built-ins always apply) | | [Always-ask commands](approvals-and-policies.md#always-ask-commands) |
| `ask.waitSeconds` | `120` (at most 3600) | | [Answer questions from Shepherd](approvals-and-policies.md#answer-questions-from-shepherd) |
| `ask.awayIdleSeconds` | `120` (30 to 3600) | | [Answer questions from Shepherd](approvals-and-policies.md#answer-questions-from-shepherd) |
| `stopGuards.question` | `false` | `true` | [Questions asked in prose come back](approvals-and-policies.md#questions-asked-in-prose-come-back) |
| `stopGuards.fakeDone` | `false` | `true` | ["Done" is checked against the diff](approvals-and-policies.md#done-is-checked-against-the-diff) |
| `stopGuards.unfinished` | `false` | `true` | [Finished units get a merge reminder](approvals-and-policies.md#finished-units-get-a-merge-reminder) |
| `verify.onMerge` | `false` (🔎 Verify works either way) | `true` | [The checker](merging-and-batches.md#the-checker-a-read-only-review-of-every-merge-request) |
| `verify.maxBudgetUsd` / `timeoutSeconds` | `1` / `600` | | [The checker](merging-and-batches.md#the-checker-a-read-only-review-of-every-merge-request) |
| `alerts.idleMinutes` | `15` (`0` turns it off) | `15` | [Fleet idle alert](automation.md#fleet-idle-alert) |
| `worklist.reviewCount` | `30` (`0` turns the count rule off) | | [My List review heads-up](fleet.md#my-list) |
| `worklist.reviewHours` | `24` (`0` turns the age rule off) | | [My List review heads-up](fleet.md#my-list) |
| `alerts.voice` / `voiceEvents` | `false` / `[]` (voice speaks the fleet idle alert; listing `"needsYou"` also speaks a card that starts needing you) | | [Fleet idle alert](automation.md#fleet-idle-alert) |
| `merge.repoGate` | `false` | | [A repo can declare its own gate](merging-and-batches.md#a-repo-can-declare-its-own-gate) |
| `merge.grantWaitsFor` | every category | every category | [Grant grading](merging-and-batches.md#grant-grading-a-risky-merge-waits-for-your-click) |
| `merge.gates[].redFirstCommand` | none | | [The red-first proof](merging-and-batches.md#the-red-first-proof-do-the-new-tests-fail-without-the-fix) |
| `radar.enabled` / `refreshSeconds` | `true` / `120` (at least 30) | | [The overlap radar](merging-and-batches.md#the-overlap-radar) |
| `merge.mainMovedNotice` | `true` | | [Main moved](merging-and-batches.md#main-moved-sibling-worktrees-hear-about-a-merge) |
| `merge.mainGreenAfterMerge` | `true` | | [Is main still green?](merging-and-batches.md#is-main-still-green-a-check-after-each-merge) |
| `schedLock.enabled` / `refreshSeconds` | `true` / `60` (at least 30) | | [Scheduled-tasks lock](troubleshooting.md#a-card-flags-a-scheduled-tasks-lock) |
| `timeLost.enabled` / `refreshSeconds` / `days` | `true` / `120` / `7` | | [Where the time went](usage-and-cost.md#where-the-time-went) |
| `score.weights` | `{ "error": 18, "deny": 6, "loop": 12, "respawn": 14 }` | | [Run score](usage-and-cost.md#run-score) |
| `subagents.activeWindow` / `jobMaxMinutes` | `45` (seconds) / `30` | | [Background work](fleet.md#background-work) |

A starting point for the most common switches:

```json
{
  "automation": { "dryRun": false },
  "escalation": { "enabled": false, "minutes": 5, "sound": false, "push": false, "pushTopic": "" },
  "focus":      { "popOnComplete": false, "popOnApproval": false },
  "spawn":      { "editor": "vscode", "live": false, "kittyRemote": true, "kittyAutoRemote": true,
                  "searchRoots": [], "searchDepth": 4 },
  "gate":       { "tools": "Bash Write Edit MultiEdit NotebookEdit", "fence": true },
  "ledger":     { "enabled": false, "retentionDays": 30, "maxTotalMB": 0 },
  "risk":       { "enabled": false },
  "collision":  { "enabled": false, "useGitRoot": false },
  "drain":      { "enabled": false },
  "respawn":    { "enabled": false, "auto": { "enabled": false, "maxRetries": 3, "staleSeconds": 600 } },
  "policies": {
    "approveRepeats": false,
    "patterns":  { "enabled": false, "autoAllow": [], "autoDeny": [] },
    "alwaysAsk": { "patterns": [] }
  }
}
```

## Files Shepherd keeps

Everything lives under `~/.claude/`:

| Path | What it holds |
|------|---------------|
| `cc-config.json` | Your settings |
| `cc-gate.enabled` | The gate's on/off switch (a flag file) |
| `cc-status/` | One status file per session, written by the hooks; `.panel-alive` is the panel heartbeat |
| `cc-status-mirror/` | Remote sessions' status files, pulled by the [SSH status bridge](providers-and-integrations.md#ssh-status-bridge) |
| `cc-merge/`, `cc-fleet/` | Merge requests and batches, with their answers, the checker's verdicts, a batch's events and the commit each **Not yet** answered (`<key>.notyet`), and the merges already announced to their [sibling worktrees](merging-and-batches.md#main-moved-sibling-worktrees-hear-about-a-merge) (`main-moved.seen`) |
| `cc-scratch/` | The [red-first proof](merging-and-batches.md#the-red-first-proof-do-the-new-tests-fail-without-the-fix)'s and [gate blame](merging-and-batches.md#gate-blame-which-failures-were-already-on-main)'s scratch worktrees, removed after each run; the background scans' temporary output; and `seance/`, a leftover of Seance (removed 2026-11-19) on an old install |
| `cc-reqs.json` | [Requirement ids](merging-and-batches.md#requirement-ids-and-the-merge-receipt): each repo's `REQ-NNN` list (Shepherd is its only writer) |
| `cc-compare.json` | The [Compare tab](fleet.md#compare-tab): the GitHub users you compare with, and what its daily checks found (created when you first open the tab) |
| `cc-ask/` | Answers to held questions (the question itself is in the session's status file) |
| `cc-decide/`, `cc-decide.sh` | Left by the decisions inbox, removed 2026-11-19: nothing reads them; `--purge` deletes them |
| `cc-guard/` | The Stop guards' once-markers: a turn [sent back for asking in prose](approvals-and-policies.md#questions-asked-in-prose-come-back) is marked here, so it is sent back once, and so is the commit a [finished unit was reminded](approvals-and-policies.md#finished-units-get-a-merge-reminder) about, or [sent back for its diff](approvals-and-policies.md#done-is-checked-against-the-diff) |
| `cc-hold/` | Left by the hands-off hold and ❄ Freeze, removed 2026-11-19: nothing reads it; `--purge` deletes it |
| `cc-inbox/` | The [session mailbox](automation.md#session-mailbox): messages waiting for each session |
| `cc-send/`, `cc-send.sh` | Left by cc-send, removed 2026-11-19: nothing reads them; `--purge` deletes them |
| `cc-tickets/` | [Cross-repo tickets](automation.md#cross-repo-tickets), one file each |
| `cc-queue/` | Leftover of the task queue and task packets (removed 2026-11-19): each project's queue and `<queue>.packets.json`. Nothing reads it; `uninstall.sh --purge` deletes it |
| `cc-pins/`, `cc-pin.sh` | Left by pinned links, removed 2026-11-19: nothing reads them; `--purge` deletes them |
| `cc-talk/` | Left by talk mode, removed 2026-11-19: nothing reads it; `--purge` deletes it |
| `cc-resume/`, `cc-resume.sh` | Left by resume at the limit reset, removed 2026-11-19: nothing reads them, and `make setup` unwires and deletes the hook; `--purge` deletes them |
| `cc-notes/` | [Handoff notes](automation.md#handoff-notes), and [auto-compact](automation.md#auto-compact-with-notes)'s due-ats and each session's own notes |
| `cc-bridge/` | The tab bridge's per-window tab lists and command folders |
| `cc-lease/` | [Worktree leases](fleet.md#worktree-leases): each repo's leased ports and database paths, and (by default) the databases in `db/` |
| `cc-restart.json` | Left by restart in place, removed 2026-11-19: nothing reads it; `--purge` deletes it |
| `cc-coach/` | [The coach](automation.md#the-coach)'s files per repo, named by the main checkout's encoded project folder (`-Users-you-code-app`): its suggestions, its log (merge notes, checker findings, filed lessons, main-went-red entries), `<repo>.applied.json` (applied edits), `<repo>.lessons.json` (the lessons ledger) and `<repo>.memory-backup/` (auto-memory backups for Undo); `evidence-spend.json` (today's evidence-run spend); `global.json` and `global.claude-backup/` for [lessons learned across repos](automation.md#across-repos) |
| `cc-lesson/` | Lessons filed with `cc-lesson.sh`, until Shepherd moves them into the coach's log |
| `cc-gate-tools/` | Per-session gated-tool settings |
| `cc-automodel/` | Leftover of model auto-routing (removed 2026-11-19): its per-session switches. Nothing reads it; `uninstall.sh --purge` deletes it |
| `cc-policy/`, `cc-policy-override/`, `cc-autopilot/` | Leftovers of named policy bundles and Autopilot (removed 2026-11-19). The gate never reads them; `uninstall.sh --purge` deletes them |
| `cc-approved/` | What approve-repeats remembers per session |
| `cc-ledger/` | The audit ledger (one JSONL file per day) |
| `cc-usage-state.json` | Where the [token totals](usage-and-cost.md#fleet-total) stopped reading each transcript, so a reload reads only what's new |
| `cc-skill-labels.json` | Your ok / not ok labels on [skill runs](providers-and-integrations.md#how-often-each-skill-works) |
| `cc-labels.json`, `cc-groups.json`, `cc-hidden.json`, `cc-autotitles.json` | Relabels and groups by project, hidden tiles, and auto-titles |
| `cc-worklist.json`, `cc-worklist-archive.json` | My List (its items and TODO.md sync state) and its archive |
| `cc-run/` | [Checklist runs](fleet.md#my-list) started with **Run selected**: each run's `<id>.run.json` (Shepherd is its only writer; kept a week after it ends) and the `cc-run.sh` reports waiting for it |
| `cc-presets.json`, `cc-recent-dirs.json` | Spawn presets and recent folders |
| `cc-agents.json`, `cc-mcp.json`, `cc-mcp-configs/` | Leftovers of agent profiles (removed 2026-11-19): the profiles, their MCP server registry and the `--mcp-config` files written for their spawns. Nothing reads them; `uninstall.sh --purge` deletes them |
| `cc-audit/` | A [find-only audit](providers-and-integrations.md#find-only-audit)'s launch files (its findings are in `~/.cc-audit/`, which a purge keeps) |
| `cc-templates.json`, `cc-prompts/` | Leftovers of prompt templates (removed 2026-11-19): the templates and the folder they imported from. Nothing reads them; `uninstall.sh --purge` deletes them |
| `cc-schedules.json` | Leftover of routines (removed 2026-11-19). Nothing reads it; `uninstall.sh --purge` deletes it |
| `cc-rules.json` | Leftover of automation rules (removed 2026-11-19). Nothing reads it; `uninstall.sh --purge` deletes it |
| `cc-main-green.json` | Each repo's last [main-green check](merging-and-batches.md#is-main-still-green-a-check-after-each-merge) verdict, so a reload keeps the card's flag (Shepherd is its only writer) |
| `cc-ab.json` | Leftover of A/B compare (removed 2026-11-19): its cohorts. Nothing reads it; `uninstall.sh --purge` deletes it |
| `cc-lock.json` | The screen lock's salted password hash |
| `cc-exports/` | Exported sessions |
| `cc-scenarios/` | Scrubbed transcript windows saved by [Capture as scenario](development.md#capturing-a-scenario) |
| `cc-keep/` | Left by kept transcripts, removed 2026-11-19: nothing reads or writes it. Its copies are your transcripts, so even `--purge` leaves it; delete it yourself |
| `cc-shepherd.log` | The panel's log (the Hammerspoon console, mirrored) |

The layout choice and the panel's size and position live in Hammerspoon's own settings. The
uninstaller keeps all of these unless you ask it to purge them ([Install](install.md#uninstall)); a
purge leaves Hammerspoon's settings.

## Hook environment variables

For the hook scripts (and the test suite):

| Variable | Default | Effect |
|----------|---------|--------|
| `CC_GATE_TOOLS` | from `gate.tools` | Overrides the gated tools |
| `CC_GATE_TIMEOUT` | `120` | Seconds the gate waits before stepping aside |
| `CC_PANEL_MAX_AGE` | `5` | How old the panel heartbeat may be before the gate and the question hook treat the panel as gone |
| `CC_ASK_WAIT` | from `ask.waitSeconds` (120) | Seconds a held question waits before going back to the tab (1–3600) |
| `CC_STATUS_DIR` | `~/.claude/cc-status` | Where the status files go ([Development](development.md#test-it-without-claude)) |
| `CC_STATUS_DEBUG` | unset | Any value appends raw hook input to `cc-status/.debug.log` (so does a `cc-status/.debug-hooks` file) |

## Settings in the code

A few settings are constants near the top of [claude-dashboard.lua](../claude-dashboard.lua):
`DEFAULT_THEME` (the default layout), `EDITOR_BUNDLES` (which editors Shepherd recognises), and the
Stream Deck tunables (`STREAMDECK_ENABLED`, `STREAMDECK_ACTIONS`, `SD_LONG_PRESS`,
`SD_LONG_PRESS_STOPS`, `SD_JUMP_RESET`, `SD_BRIGHTNESS`, `SD_FALLBACK_KEYS`). Edit the repo copy,
then `make install` and reload ([Development](development.md#deploying-changes)).
