# Configuration

[← README](../README.md) · [Install](install.md) · [Approvals and policies](approvals-and-policies.md)

Most of Shepherd's behaviour is governed by one settings file, `~/.claude/cc-config.json`. (The
gate's on/off switch is the flag file `~/.claude/cc-gate.enabled`; the layout and the panel's size
live in Hammerspoon's settings; launch at login is Hammerspoon's own login item.) The automations
are off until you turn them on; a few conveniences (held questions, Remote Control for spawned
sessions, ending tab-less leftovers, plan-limit alerts, closing a merged unit's tab) are on by
default. A fresh install writes the author's daily settings
([defaults/cc-config.json](../defaults/cc-config.json)) when you have no file yet; on an upgrade,
`make setup` adds any of its keys you haven't set, and never changes one you have.

## The ⚙ Settings panel

Click **⚙** in the header for a form with most switches and a one-line explanation of each. **Save**
writes `~/.claude/cc-config.json` (creating it if missing) and arms or disarms the gate. Blocks the
form doesn't show survive a Save, and so do a few hand-tuned keys inside the blocks it does show
(such as `risk.weights`, `spawn.searchRoots` or `bridge.staleSlackSeconds`). Other hand-added keys
inside a form-managed block are dropped on Save; see the policy-bundle
[known issue](approvals-and-policies.md#named-policy-bundles). Its tabs:

- **General**: launch Shepherd at login; tile cleanup (`prune.hours`, `cleanup.idleHours`).
- **Appearance**: the layout, themes, colours, font, sizing, and the detail-panel switches
  ([Make it yours](customizing.md)).
- **Approvals**: **Headless approvals** and the gated tools, **Answer questions in Shepherd**, the
  advanced gate settings, and the policies (approve repeats, Autopilot, allow/deny patterns)
  ([Approvals and policies](approvals-and-policies.md)).
- **Automation**: the task queue, escalation, graceful drain, respawn, Auto-Continue
  ([Automation](automation.md)).
- **Observability**: risk score, same-folder collision, insights, auto-title, loop watchdog, macOS
  banners, post-run summary, PR status, the hooks inventory, the audit log and **Measure storage**
  ([Usage and cost](usage-and-cost.md)).
- **Spawn**: editor window pop, spawn defaults (**Actually launch**, editor, flavour), Claude Code
  Remote Control, the SSH status bridge and provider profiles
  ([Controls](controls.md#spawn-new-sessions),
  [Providers and integrations](providers-and-integrations.md)).

File-only switches include, among others: `rules.enabled`, `schedules.enabled` and
`schedules.maxConcurrent`, `hotkeys`, `voice`, `automodel.*`, `pricing.*`, `merge.*`, `fleet.enabled`,
`commits.*`, `usage.limitAlerts.*`, `ask.waitSeconds`, `tabless.autoEndMinutes`,
`escalation.hung`, `search.*`, `worklist.*`, `decisions.*`, `notifications.days`,
`templates.sourceDir`, `context.autoCompactFraction`, and the `keystrokes`, `tabBridge`, `stacks`
and `alerts` sections. Policy bundles and attachments are edited in the 🛡 editor.

## Editing the file by hand

Copy [cc-config.example.json](../cc-config.example.json) to `~/.claude/cc-config.json` and flip what
you want. The example documents most keys with a `_comment`; the reference pages cover the rest.
The panel re-reads the file within about a second (except `hotkeys`, which need Hammerspoon →
**Reload Config**); the hooks read it on their next run.

| Section | What it controls | Reference |
|---------|------------------|-----------|
| `gate`, `policies`, `ask` | Gated tools, auto-allow/deny, bundles, Autopilot, held questions | [Approvals and policies](approvals-and-policies.md) |
| `merge`, `fleet`, `tabBridge` | Ready to merge, merge gates, batches, the tab bridge | [Merging and batches](merging-and-batches.md) |
| `queue`, `templates`, `automodel` | Task queue, routing, templates, model auto-routing | [Automation](automation.md) |
| `respawn`, `autoContinue`, `drain`, `prune`, `cleanup`, `tabless` | Recovery and cleanup | [Automation](automation.md), [Controls](controls.md#sessions-with-no-tab) |
| `escalation`, `notifications`, `focus`, `summary`, `rules`, `schedules` | Nags, banners, focus pop, rules, routines | [Automation](automation.md) |
| `autoTitle`, `prStatus`, `risk`, `collision`, `subagents`, `status` | Tile observability | [Fleet](fleet.md#session-observability) |
| `ledger`, `decisions`, `insights` | The audit ledger and the views built on it | [Usage and cost](usage-and-cost.md) |
| `usage`, `context`, `pricing`, `commits` | Plan bars, limit alerts, context bar, cost, commit counts | [Usage and cost](usage-and-cost.md) |
| `spawn`, `providers`, `remoteControl`, `bridge` | Launching sessions, backends, Remote Control, remote tiles | [Controls](controls.md#spawn-new-sessions), [Providers and integrations](providers-and-integrations.md) |
| `stacks`, `keystrokes`, `search`, `hotkeys`, `voice` | Project cards, the shared-window guard, search, shortcuts, Stream Deck voice | [Fleet](fleet.md), [Controls](controls.md) |
| `appearance`, `alerts`, `worklist` | Look, on-screen alerts, My List archive | [Make it yours](customizing.md), [Fleet](fleet.md#my-list) |

A starting point for the most common switches:

```json
{
  "queue":      { "autofeed": false, "dryRun": false,
                  "routing": { "enabled": false, "starveMinutes": 0 } },
  "escalation": { "enabled": false, "minutes": 5, "sound": false, "push": false, "pushTopic": "" },
  "focus":      { "popOnComplete": false, "popOnApproval": false },
  "spawn":      { "editor": "vscode", "live": false, "kittyRemote": true, "kittyAutoRemote": true,
                  "searchRoots": [], "searchDepth": 4 },
  "gate":       { "tools": "Bash Write Edit MultiEdit NotebookEdit" },
  "ledger":     { "enabled": false, "retentionDays": 30, "maxTotalMB": 0 },
  "risk":       { "enabled": false },
  "collision":  { "enabled": false, "useGitRoot": false },
  "drain":      { "enabled": false },
  "respawn":    { "enabled": false, "auto": { "enabled": false, "maxRetries": 3, "staleSeconds": 600 } },
  "policies": {
    "approveRepeats": false,
    "autopilot": { "enabled": false, "minutes": 15 },
    "patterns":  { "enabled": false, "autoAllow": [], "autoDeny": [] }
  }
}
```

## Files Shepherd keeps

Everything lives under `~/.claude/`:

| Path | What it holds |
|------|---------------|
| `cc-config.json` | Your settings |
| `cc-status/` | One status file per session, written by the hooks; `.panel-alive` is the panel heartbeat |
| `cc-merge/`, `cc-fleet/` | Merge requests and batches, with their answers |
| `cc-ask/` | Answers to held questions (the question itself is in the session's status file) |
| `cc-bridge/` | The tab bridge's per-window tab lists and command folders |
| `cc-policy/`, `cc-gate-tools/`, `cc-automodel/` | Per-session policy, gated-tool and auto-model settings |
| `cc-ledger/` | The audit ledger (one JSONL file per day) |
| `cc-labels.json`, `cc-groups.json` | Relabels and groups, by project |
| `cc-worklist.json`, `cc-worklist-archive.json` | My List and its archive |
| `cc-presets.json`, `cc-recent-dirs.json` | Spawn presets and recent folders |
| `cc-agents.json`, `cc-mcp.json` | Agent profiles and their MCP server registry |
| `cc-templates.json`, `cc-rules.json`, `cc-schedules.json` | Templates, automation rules, routines |
| `cc-ab.json` | A/B compare cohorts |
| `cc-lock.json` | The screen lock's salted password hash |
| `cc-exports/` | Exported sessions |
| `cc-shepherd.log` | The panel's log (the Hammerspoon console, mirrored) |

The layout choice and the panel's size and position live in Hammerspoon's own settings. The
uninstaller keeps all of these unless you ask it to purge them ([Install](install.md#uninstall)); a
purge leaves Hammerspoon's settings and, for now, `cc-worklist-archive.json`.

## Hook environment variables

For the hook scripts (and the test suite):

| Variable | Default | Effect |
|----------|---------|--------|
| `CC_GATE_TOOLS` | from `gate.tools` | Overrides the gated tools |
| `CC_GATE_TIMEOUT` | `120` | Seconds the gate waits before stepping aside |
| `CC_PANEL_MAX_AGE` | `5` | How old the panel heartbeat may be before the gate and the question hook treat the panel as gone |
| `CC_ASK_WAIT` | from `ask.waitSeconds` (900) | Seconds a held question waits before going back to the tab (1–3600) |
| `CC_STATUS_DIR` | `~/.claude/cc-status` | Where the status files go ([Development](development.md#test-it-without-claude)) |
| `CC_STATUS_DEBUG` | unset | Any value appends raw hook input to `cc-status/.debug.log` (so does a `cc-status/.debug-hooks` file) |

## Settings in the code

A few settings are constants near the top of [claude-dashboard.lua](../claude-dashboard.lua):
`DEFAULT_THEME` (the default layout), `EDITOR_BUNDLES` (which editors Shepherd recognises), and the
Stream Deck tunables (`STREAMDECK_ENABLED`, `STREAMDECK_ACTIONS`, `SD_LONG_PRESS`,
`SD_LONG_PRESS_STOPS`, `SD_JUMP_RESET`, `SD_BRIGHTNESS`, `SD_FALLBACK_KEYS`). Edit the repo copy,
then `make install` and reload ([Development](development.md#deploying-changes)).
