# Configuration

[← README](../README.md) · [Install](install.md) · [Approvals and policies](approvals-and-policies.md)

Most of Shepherd's behaviour is governed by one settings file, `~/.claude/cc-config.json`. (The
gate's on/off switch is the flag file `~/.claude/cc-gate.enabled`; the layout and the panel's size
live in Hammerspoon's settings; launch at login is Hammerspoon's own login item.)

**What's on.** With no file at all, nothing acts on a session by itself apart from a few
conveniences: held questions, resume at a usage limit's reset, worktree leases, Remote Control for
spawned sessions, ending tab-less leftovers, plan-limit alerts and closing a merged unit's tab.
(The read-only background checks, such as commit counts, the overlap radar and the scheduled-tasks
lock check, are on too.) A fresh install writes the author's daily
settings ([defaults/cc-config.json](../defaults/cc-config.json)) when you have no file yet, and
those also turn on auto-continue, respawn, auto-compact, the merge checker, the worktree fence, the
audit ledger and real spawning. The queue's auto-feed, routing, rules, routines, escalation and the
weekly coach stay off until you switch them on. On an upgrade, `make setup` adds any of the
defaults' keys you haven't set, and never changes one you have.

## The ⚙ Settings panel

Click **⚙** in the header for a form with most switches and a one-line explanation of each. **Save**
writes `~/.claude/cc-config.json` (creating it if missing) and arms or disarms the gate. Blocks the
form doesn't show survive a Save, and so do the hand-kept keys inside the blocks it does show: the
[policy bundles and attachments](approvals-and-policies.md#named-policy-bundles),
`spawn.matchWindowSize`, `risk.weights`, `spawn.searchRoots`, `bridge.staleSlackSeconds` and the
like, plus any `_`-prefixed note such as `_comment`. Any other key you add by hand inside a
form-managed block is dropped on Save. Its tabs:

- **General**: launch Shepherd at login; tile cleanup (`prune.hours`, `cleanup.idleHours`).
- **Appearance**: the layout, themes, colours, font, sizing, and the detail-panel switches
  ([Make it yours](customizing.md)).
- **Approvals**: **Headless approvals** and the gated tools, **Answer questions in Shepherd**, the
  advanced gate settings, the policies (approve repeats, Autopilot, allow/deny patterns), and the
  **Always ask** commands with your own additions
  ([Approvals and policies](approvals-and-policies.md)).
- **Automation**: the task queue, escalation, graceful drain, respawn, Auto-Continue, **Dry run**
  (all automation, or one feature at a time) and Auto-compact ([Automation](automation.md)).
- **Observability**: risk score, same-folder collision, insights, auto-title, loop watchdog, macOS
  banners, post-run summary, PR status, the hooks inventory, the audit log and **Measure storage**
  ([Usage and cost](usage-and-cost.md)).
- **Spawn**: editor window pop, spawn defaults (**Actually launch**, editor, flavour), Claude Code
  Remote Control, the SSH status bridge and provider profiles
  ([Controls](controls.md#spawn-new-sessions),
  [Providers and integrations](providers-and-integrations.md)).

File-only switches include, among others: `rules.enabled`, `schedules.enabled` and
`schedules.maxConcurrent`, `hotkeys`, `voice`, `automodel.*`, `pricing.*`, `merge.*`, `verify.*`,
`gate.fence`, `resume.enabled`, `restart.waveMinutes` and `restart.keepHours`, `lease.*`,
`coach.*`, `decide.waitSeconds`, `radar.*`, `schedLock.*`, `timeLost.*`, `score.weights`,
`subagents.*`, `status.resumeSlack`, `autoContinue.backoff.*`, `fleet.enabled`, `commits.*`,
`usage.limitAlerts.*`, `ask.waitSeconds`, `tabless.autoEndMinutes`, `escalation.hung`, `search.*`,
`worklist.*`, `decisions.*`, `notifications.days`, `templates.sourceDir`,
`context.autoCompactFraction`, and the `keystrokes`, `tabBridge`, `stacks` and `alerts` sections.
Policy bundles and attachments are edited in the 🛡 editor.

## Editing the file by hand

Copy [cc-config.example.json](../cc-config.example.json) to `~/.claude/cc-config.json` and flip what
you want. The example documents most keys with a `_comment`; the reference pages cover the rest.
The panel re-reads the file within about a second (except `hotkeys`, which need Hammerspoon →
**Reload Config**); the hooks read it on their next run.

| Section | What it controls | Reference |
|---------|------------------|-----------|
| `gate`, `policies`, `ask`, `decide` | Gated tools, the worktree fence, auto-allow/deny, always-ask commands, bundles, Autopilot, held questions, the decisions inbox | [Approvals and policies](approvals-and-policies.md) |
| `merge`, `verify`, `fleet`, `radar`, `tabBridge` | Ready to merge, merge gates, the merge checker, batches, the overlap radar, the tab bridge | [Merging and batches](merging-and-batches.md) |
| `queue`, `templates`, `automodel`, `coach` | Task queue, routing, templates, model auto-routing, the coach | [Automation](automation.md) |
| `respawn`, `autoContinue`, `resume`, `drain`, `prune`, `cleanup`, `tabless` | Recovery, resuming at a usage limit's reset, and cleanup | [Automation](automation.md), [Controls](controls.md#sessions-with-no-tab) |
| `compact` | Auto-compact at `atPct` with notes kept across it (sets `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in Claude Code's `settings.json`) | [Automation](automation.md#auto-compact-with-notes) |
| `escalation`, `notifications`, `focus`, `summary`, `rules`, `schedules` | Nags, banners, focus pop, rules, routines | [Automation](automation.md) |
| `automation` (and each feature's `dryRun`) | Dry run for all automation, or one feature at a time | [Automation](automation.md#dry-run-and-the-automation-trace) |
| `autoTitle`, `prStatus`, `risk`, `collision`, `subagents`, `status` | Tile observability | [Fleet](fleet.md#session-observability) |
| `schedLock` | The 🔒 scheduled-tasks lock check on project cards | [Troubleshooting](troubleshooting.md#a-card-flags-a-scheduled-tasks-lock) |
| `ledger`, `decisions`, `insights`, `score` | The audit ledger and the views built on it, the run score's weights | [Usage and cost](usage-and-cost.md) |
| `usage`, `context`, `pricing`, `commits`, `timeLost` | Plan bars, limit alerts, context bar, cost, commit counts, where the time went | [Usage and cost](usage-and-cost.md) |
| `spawn`, `providers`, `remoteControl`, `bridge` | Launching sessions, backends, Remote Control, remote tiles | [Controls](controls.md#spawn-new-sessions), [Providers and integrations](providers-and-integrations.md) |
| `stacks`, `keystrokes`, `search`, `hotkeys`, `voice` | Project cards, the shared-window guard, search, shortcuts, Stream Deck voice | [Fleet](fleet.md), [Controls](controls.md) |
| `lease` | Each worktree's own port (`portFrom`–`portTo`) and database folder (`dbDir`) | [Fleet](fleet.md#worktree-leases) |
| `restart` | Restart in place: which ended sessions count as the last wave (`waveMinutes`, default 30), how long an ended session stays in the snapshot (`keepHours`, default 72), and its `dryRun` | [Fleet](fleet.md#restart-the-fleet-in-place) |
| `appearance`, `alerts`, `worklist` | Look, on-screen alerts, My List archive | [Make it yours](customizing.md), [Fleet](fleet.md#my-list) |

### Newer blocks and their defaults

The default is what the code does when the key is absent; the last column says where a fresh
install's [defaults](../defaults/cc-config.json) differ.

| Key | Default | Fresh install | Reference |
|-----|---------|---------------|-----------|
| `automation.dryRun` | `false` | | [Dry run](automation.md#dry-run-and-the-automation-trace) |
| `<feature>.dryRun` (`autoContinue`, `queue`, `rules`, `respawn`, `summary`, `resume`, `tabless`, `mailbox`, `remoteControl`, `restart`) | `false` | | [Dry run](automation.md#dry-run-and-the-automation-trace) |
| `autoContinue.backoff.startSeconds` / `maxSeconds` | `120` / `1800` (`startSeconds: 0` turns it off) | | [Auto-continue](automation.md#auto-respawn-and-auto-continue) |
| `compact.enabled` | `false` | `true` | [Auto-compact with notes](automation.md#auto-compact-with-notes) |
| `compact.atPct` / `notesLeadPct` | `85` / `5` | | [Auto-compact with notes](automation.md#auto-compact-with-notes) |
| `resume.enabled` | `true` | | [Resume at the limit reset](automation.md#resume-at-the-limit-reset) |
| `coach.enabled` | `false` (the 🧭 Coach button works either way) | | [The coach](automation.md#the-coach) |
| `coach.day` / `maxBudgetUsd` / `timeoutSeconds` | `"mon"` / `1` / `600` | | [The coach](automation.md#the-coach) |
| `restart.waveMinutes` / `keepHours` | `30` / `72` | | [Restart the fleet in place](fleet.md#restart-the-fleet-in-place) |
| `lease.enabled` | `true` | | [Worktree leases](fleet.md#worktree-leases) |
| `lease.portFrom` / `portTo` / `dbDir` | `4100` / `4199` / `~/.claude/cc-lease/db` | | [Worktree leases](fleet.md#worktree-leases) |
| `gate.fence` | `false` | `true` | [Worktree fence](approvals-and-policies.md#worktree-fence) |
| `policies.alwaysAsk.patterns` | `[]` (the built-ins always apply) | | [Always-ask commands](approvals-and-policies.md#always-ask-commands) |
| `decide.waitSeconds` | `1800` (at most 7200) | | [Decisions inbox](approvals-and-policies.md#decisions-inbox) |
| `verify.onMerge` | `false` (🔎 Verify works either way) | `true` | [The checker](merging-and-batches.md#the-checker-a-read-only-review-of-every-merge-request) |
| `verify.maxBudgetUsd` / `timeoutSeconds` | `1` / `600` | | [The checker](merging-and-batches.md#the-checker-a-read-only-review-of-every-merge-request) |
| `merge.repoGate` | `false` | | [A repo can declare its own gate](merging-and-batches.md#a-repo-can-declare-its-own-gate) |
| `merge.gates[].redFirstCommand` | none | | [The red-first proof](merging-and-batches.md#the-red-first-proof-do-the-new-tests-fail-without-the-fix) |
| `radar.enabled` / `refreshSeconds` | `true` / `120` (at least 30) | | [The overlap radar](merging-and-batches.md#the-overlap-radar) |
| `schedLock.enabled` / `refreshSeconds` | `true` / `60` (at least 30) | | [Scheduled-tasks lock](troubleshooting.md#a-card-flags-a-scheduled-tasks-lock) |
| `timeLost.enabled` / `refreshSeconds` / `days` | `true` / `120` / `7` | | [Where the time went](usage-and-cost.md#where-the-time-went) |
| `score.weights` | `{ "error": 18, "deny": 6, "loop": 12, "respawn": 14 }` | | [Run score](usage-and-cost.md#run-score) |
| `subagents.activeWindow` / `jobMaxMinutes` | `45` (seconds) / `30` | | [Agents tab and background work](fleet.md#agents-tab-and-background-work) |

A starting point for the most common switches:

```json
{
  "automation": { "dryRun": false },
  "queue":      { "autofeed": false, "dryRun": false,
                  "routing": { "enabled": false, "starveMinutes": 0 } },
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
    "autopilot": { "enabled": false, "minutes": 15 },
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
| `cc-merge/`, `cc-fleet/` | Merge requests and batches, with their answers, the checker's verdicts and a batch's events |
| `cc-scratch/` | The [red-first proof](merging-and-batches.md#the-red-first-proof-do-the-new-tests-fail-without-the-fix)'s scratch worktrees, removed after each run |
| `cc-reqs.json` | [Requirement ids](merging-and-batches.md#requirement-ids-and-the-merge-receipt): each repo's `REQ-NNN` list (Shepherd is its only writer) |
| `cc-ask/` | Answers to held questions (the question itself is in the session's status file) |
| `cc-decide/` | The [decisions inbox](approvals-and-policies.md#decisions-inbox): open `cc-decide.sh` questions and their answers |
| `cc-inbox/` | The [session mailbox](automation.md#session-mailbox): messages waiting for each session |
| `cc-send/` | [cc-send](automation.md#send-a-prompt-from-a-shell) requests waiting for Shepherd, and its answers |
| `cc-tickets/` | [Cross-repo tickets](automation.md#cross-repo-tickets), one file each |
| `cc-queue/` | Each project's [task queue](automation.md#task-queue) and its [packets](automation.md#task-packets) |
| `cc-pins/` | [Pinned links](controls.md#pinned-links), one file per worktree |
| `cc-talk/` | One flag file per session in [talk mode](approvals-and-policies.md#talk-mode) |
| `cc-resume/` | [Resumes waiting for a usage limit's reset](automation.md#resume-at-the-limit-reset): the hook's arm, Shepherd's plan, a Cancel |
| `cc-notes/` | [Handoff notes](automation.md#handoff-notes), and [auto-compact](automation.md#auto-compact-with-notes)'s due-ats and each session's own notes |
| `cc-bridge/` | The tab bridge's per-window tab lists and command folders |
| `cc-lease/` | [Worktree leases](fleet.md#worktree-leases): each repo's leased ports and database paths, and (by default) the databases in `db/` |
| `cc-restart.json` | The [restart snapshot](fleet.md#restart-the-fleet-in-place): every session Shepherd could reopen, and the ones it already did (Shepherd is its only writer) |
| `cc-coach/` | [The coach](automation.md#the-coach)'s suggestions and its log of merge notes and checker findings, per repo |
| `cc-policy/`, `cc-policy-override/`, `cc-gate-tools/`, `cc-automodel/` | Per-session policy (the resolved rules, and the **Policy** dropdown's choice), gated-tool and auto-model settings |
| `cc-approved/`, `cc-autopilot/` | What approve-repeats remembers per session, and each session's Autopilot window |
| `cc-ledger/` | The audit ledger (one JSONL file per day) |
| `cc-usage-state.json` | Where the [token totals](usage-and-cost.md#fleet-total) stopped reading each transcript, so a reload reads only what's new |
| `cc-skill-labels.json` | Your ok / not ok labels on [skill runs](providers-and-integrations.md#how-often-each-skill-works) |
| `cc-labels.json`, `cc-groups.json`, `cc-hidden.json`, `cc-autotitles.json` | Relabels and groups by project, hidden tiles, and auto-titles |
| `cc-worklist.json`, `cc-worklist-archive.json` | My List and its archive |
| `cc-presets.json`, `cc-recent-dirs.json` | Spawn presets and recent folders |
| `cc-agents.json`, `cc-mcp.json`, `cc-mcp-configs/` | Agent profiles, their MCP server registry, and the `--mcp-config` files written for their spawns |
| `cc-audit/` | A [find-only audit](providers-and-integrations.md#find-only-audit)'s launch files (its findings are in `~/.cc-audit/`, which a purge keeps) |
| `cc-templates.json`, `cc-prompts/`, `cc-rules.json`, `cc-schedules.json` | Templates, the folder they import from, automation rules, routines |
| `cc-ab.json` | A/B compare cohorts |
| `cc-lock.json` | The screen lock's salted password hash |
| `cc-exports/` | Exported sessions |
| `cc-scenarios/` | Scrubbed transcript windows saved by [Capture as scenario](development.md#capturing-a-scenario) |
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
| `CC_ASK_WAIT` | from `ask.waitSeconds` (900) | Seconds a held question waits before going back to the tab (1–3600) |
| `CC_DECIDE_WAIT` | from `decide.waitSeconds` (1800) | Seconds a `cc-decide.sh --blocking` question waits before it prints the default |
| `CC_STATUS_DIR` | `~/.claude/cc-status` | Where the status files go ([Development](development.md#test-it-without-claude)) |
| `CC_STATUS_DEBUG` | unset | Any value appends raw hook input to `cc-status/.debug.log` (so does a `cc-status/.debug-hooks` file) |

## Settings in the code

A few settings are constants near the top of [claude-dashboard.lua](../claude-dashboard.lua):
`DEFAULT_THEME` (the default layout), `EDITOR_BUNDLES` (which editors Shepherd recognises), and the
Stream Deck tunables (`STREAMDECK_ENABLED`, `STREAMDECK_ACTIONS`, `SD_LONG_PRESS`,
`SD_LONG_PRESS_STOPS`, `SD_JUMP_RESET`, `SD_BRIGHTNESS`, `SD_FALLBACK_KEYS`). Edit the repo copy,
then `make install` and reload ([Development](development.md#deploying-changes)).
