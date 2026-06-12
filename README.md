# Claude Shepherd — Claude Code fleet console (Mac)

A floating, always-on-top panel with one tile per Claude Code session. Each tile
shows the project name and a live status, and selecting it opens a control panel
where you can **jump** to that VS Code window, **approve / deny** a pending
permission, **nudge** the session with a quick message, or **stop** the current
turn — all without losing your place. This is the on-screen version of a Stream
Deck for a fleet of Claude agents.

When you run several Claude sessions at once, the bottleneck is you: a session
that finishes or hits a permission prompt sits idle until you notice it.
Claude Shepherd tells you which agent needs a human *right now* and lets you handle it
from one pane.

## Statuses

| Status     | Color           | Fires from hook              | Meaning                                  |
|------------|-----------------|------------------------------|------------------------------------------|
| `idle`     | gray            | SessionStart                 | Session open, nothing happening yet      |
| `working`  | amber           | UserPromptSubmit, Pre/PostToolUse | Claude is actively doing work       |
| `approval` | red (pulsing)   | Notification (permission)    | Claude needs permission or your input    |
| `done`     | green           | Stop, Notification (idle)    | Claude finished its turn, ready for you   |

Sessions are keyed by their **session_id**, so two sessions in the same folder
never collide into one tile. Tiles disappear when a session ends (SessionEnd) and
**dim** if a session goes stale (no updates for ~90s, e.g. after a crash). Each
tile shows time-in-state, the latest prompt, and — on an approval — the **exact
command** being requested (e.g. `wants: npm test -- --watch`, via the
`PermissionRequest` hook). Selecting a tile also shows a **live activity peek**:
the latest assistant line from that session's transcript ("Doing: …").

## How it works

```
Claude Code hooks ──► cc-status.sh ──► ~/.claude/cc-status/<session_id>.json ──► dashboard
                  └─► cc-approve.sh ◄── <session_id>.decision ◄────────────────── (gate)
```

- [cc-status.sh](cc-status.sh) merges each hook event into the session's JSON file.
- [cc-approve.sh](cc-approve.sh) is the optional PreToolUse approval gate (below).
- [cc-lib.sh](cc-lib.sh) holds shared helpers for both.
- [cc-core.lua](cc-core.lua) is the pure logic (parsing, sorting, action
  selection, deck layout, spawn-command building) — no `hs.*` calls, fully
  unit-tested. [claude-dashboard.lua](claude-dashboard.lua) is the Hammerspoon
  bootstrap: it reads the JSON files, renders tiles, writes a heartbeat, and wires
  the real effects (focus, keystrokes, Stream Deck) into cc-core.

## Control actions

The **header** has **New** (opens the new-session modal — see "Spawn"), a **☕
keep-awake toggle** (see "Keep this Mac awake"), **📊 Fleet insights** and **📜 Audit
ledger** overlays (see "Audit log & insights"), the **⚙ Settings** panel, and a theme switcher.

**Single-click** a tile to select it (opens the detail panel). **Double-click** a
tile to **jump** straight to its window. **Right-click** a tile for a context menu:

- **Jump to window** — focus that session's editor window (double-click does the
  same, but isn't always reliable, so it's offered here too).
- **Relabel…** — give the tile a custom display name (e.g. "auth refactor" instead
  of the folder name). Display-only — jumps still target the real window — and
  **persistent**: keyed by the session's **stable project identity** (its launch
  folder, recorded in `~/.claude/cc-labels.json`), so the name sticks even as the
  agent changes directories, and survives a Hammerspoon reload, a new instance, and
  close/reopen in the same folder. Relabel back to the folder name (or blank) to clear it.
- **Clear conversation / Compact** — native confirm, then run `/clear` or `/compact`
  in the session (same effect as the detail-panel buttons).
- **Close instance** — confirm, then best-effort close the editor window (⌘⇧W) and
  remove the tile (the project's saved label is kept for next time).
- **Drain (finish turn, then close)** — *shown when `drain.enabled`*: wait for the
  session to finish its in-flight turn, then close it (closes now if already idle/done).
- **Respawn from cwd** — *shown when `respawn.enabled`*: relaunch a dead/stale session
  from its last working dir + matched provider + editor.

The detail panel has:

- **Jump** — focus that session's VS Code/Cursor window (switches Spaces if needed).
- **Approve / Deny** — answer a pending permission prompt.
- **Stop** — interrupt the current turn.
- **Continue** (error recovery) — when a session freezes on an API error (e.g. `Unable to
  connect to API (ECONNRESET)`) that aborts the turn without a Stop, its tile turns a distinct
  **magenta "Error"** and the Approve button becomes **Continue**; one click types `continue` +
  Enter to resume the aborted turn. Detected from the transcript (no hooks); auto-respawn is
  held off so you resume the *same* session rather than relaunching it.
- **Autopilot** — time-box a session to auto-approve all its prompts (needs the gate + config).
- **Clear / Compact** — pop a yes/no confirm, then run `/clear` or `/compact` in the session.
- **Improve** — pull this repo's un-applied improvement insights from the AI Monsters
  leaderboard and send them to the session as a **review-first** prompt (assess and
  suggest where applicable — *not* wholesale edits), so you approve a plan before any
  changes. Shows "No improvements found" when the latest push's insights are already
  claimed. Needs `LB_URL` / `GRADE_PREVIEW_TOKEN` in your shell (`~/.zshrc`).
- **Effort** dropdown — set the session's reasoning effort (Low/Medium/High/XHigh) live; sends
  the `/effort <level>` slash command.
- **Mode** dropdown — switch the permission mode (Default / Accept edits / Plan) live via
  Shift+Tab; reliable on Kitty, best-effort in the VS Code extension (its switcher is mouse-only).
  The detail also shows badges for the detected **editor**, current **permission mode**, and **effort**.
- **Model** dropdown — switch the model live within the session's backend (`/model`).
- **Gate** dropdown — per-session tool gating (Default / All / None / Custom): override the
  fleet `gate.tools` for just this session. Only enforced while headless approvals are armed.
- **Nudge box** — a multi-line input: **Enter** sends, **Shift+Enter** adds a newline
  (mirrors the Claude chat), so a pasted multi-item list arrives intact. **Paste an
  image** and it's attached as a chip; **Send** delivers text and/or image via the
  clipboard (one ⌘V, newline-safe). **Queue** saves text for later (the tile shows
  `+N queued`, **Feed next** sends the front one).

The **Wants** (the exact command) and **Why** (the assistant's reasoning before a
request) clamp to two lines — **click to expand**.

### AskUserQuestion in the panel
When a session calls **AskUserQuestion**, the hook captures the question + options and the panel
renders them as clickable buttons under the detail. Clicking an option: on a **terminal (Kitty)**
session it drives the picker directly (auto-select); in the **VS Code extension** the picker is
mouse-only, so clicking **jumps you to it** to pick by hand. **Multi-select** questions can't be
driven by synthesized keys, so Shepherd jumps you to those regardless of editor. Either way you see
*what's being asked* without leaving Shepherd.

### Editor auto-detection
Each session self-reports its host editor. [cc-status.sh](cc-status.sh) reads the env it inherits
from `claude` (`CLAUDE_CODE_ENTRYPOINT`, `__CFBundleIdentifier`, `TERM`/`KITTY_WINDOW_ID`) plus the
hook's `permission_mode`, and records `editor` (`vscode`/`cursor`/`kitty`/`terminal`),
`permission_mode`, and `effort` into the session's status JSON. The panel routes actions per session
on that: **Kitty sessions run effects headlessly via `kitty @` remote control** (focus/approve/deny/
nudge/close/answer with no window focus), and **anything else uses the VS Code/Cursor path**, so a
machine running both just works. Kitty remote control is auto-enabled in your `kitty.conf` when Kitty
is in use (Shepherd backs the file up first; needs a kitty restart to take effect), and sessions
Shepherd spawns get it via launch flags.

### How control reaches the session — and its limits

Two paths, and it matters which one your sessions use:

1. **Headless approvals (hands-free, reliable everywhere).** Flip **Headless
   approvals** in ⚙ Settings (one click: arms the gate + turns off every auto-policy).
   [cc-approve.sh](cc-approve.sh) then routes each gated permission to the panel and
   Approve/Deny write a decision file the hook honors — **no window focus, no
   keystrokes** — while Claude still can't run a gated tool until you decide. Works
   for terminal *and* VS Code-extension sessions. See "Headless approvals" below.

2. **Per-session effects.** Jump, Stop, Nudge/Feed, Clear/Compact, answer, mode-switch.
   On **Kitty** these run headlessly via `kitty @` (no window focus). On **VS Code /
   terminal** they focus the target window and type into it — reliable in a terminal,
   **best-effort in the VS Code extension** (the chat input/picker isn't reliably the
   focused element; there's no supported API to inject into a running session). Needs
   Hammerspoon **Accessibility** permission.

> For reliable approve/deny regardless of UI, use Headless approvals (or Kitty).
> For delivering work, **Queue** stores it reliably; feeding/nudge into the VS Code
> extension's chat input is the fragile part.

## Fleet navigation & bulk actions

For supervising many sessions at once (always on; nothing automatic):

- **🔍 Search** — the magnifying-glass header button reveals a filter bar that scopes the
  grid as you type (token-AND over each session's name, project, status, and group).
- **Groups** — right-click → **Set group…** tags a session into a named cohort (kept by
  the stable project identity, so it survives close/reopen, in `~/.claude/cc-groups.json`).
  When groups exist, a chip row lets you scope the grid to one group (composes with search).
- **Bulk actions** — a **Fleet** bar acts on whatever's currently visible (post
  search/group) at once: **Approve all** waiting sessions, **Stop all** working ones
  (confirm), or **Nudge all** (broadcast text). Buttons show live counts and appear only
  when there's something to act on; bulk nudge skips sessions sitting at an approval prompt.
- **📜 Timeline** — the detail-panel **Timeline** button opens the audit overlay scoped to
  that one session's chronological history (needs the ledger enabled).

## Global hotkeys

Act on the session that needs you without touching the panel (configurable near
the top of [claude-dashboard.lua](claude-dashboard.lua)):

- **⌘⌥A** — approve the front approval (hands-free via the gate when it's waiting).
- **⌘⌥J** — jump to the session that needs you.
- **⌘⌥N** — cycle-jump to the next session.
- **⌘⌥S** — spawn a new session (see below).
- **⌘⌥B** — show/hide the panel (it also minimizes to the Dock, and there's a 🐑
  menu-bar icon to reopen it when closed).

## Keep this Mac awake (caffeinate)

The **☕ toggle** in the header keeps your Mac awake while long agent runs work
unattended — it runs `pmset -a disablesleep 1/0` (so it holds even with the lid
closed). Because that needs root, macOS asks for your password each time you flip it
(your choice over a passwordless sudoers entry). The button reads the real state via
`pmset -g` (no password needed) and shows **☕ Awake** (amber) when on.

## Spawn new sessions

Click **New** (or **⌘⌥S**) to open the **New session** modal:

- **Open existing / Start new project** — open a folder, or create a new folder and start in it.
- **Presets** — ▶ chips that spawn a saved folder+editor+mode+provider bundle in one click;
  "Save as preset" in the footer captures the current form (`~/.claude/cc-presets.json`,
  ✕ on a chip deletes). Picking a known folder also recalls the editor/mode/provider you
  last used for that project.
- **Fuzzy folder search** — just type a project name fragment into the path field: your
  project roots (`spawn.searchRoots`, default `~/Programming`) are indexed once per open
  (with [fd](https://github.com/sharkdp/fd) when installed — gitignore-aware, so
  `node_modules` never appears; plain `find` otherwise) and ranked suggestions drop down
  (arrows + Enter to pick).
- **Folder browser** — drill into subfolders, breadcrumb back up, "Use this folder" fills the
  path; the free-text path field stays editable too.
- **Recent** — one-click chips for folders you've launched in (plus currently-active session
  folders), persisted to `~/.claude/cc-recent-dirs.json`.
- **Open in** — Terminal / Kitty / VS Code / Cursor (defaults to your `spawn.editor`). Kitty and
  Terminal launch reliably; VS Code/Cursor open the window, then best-effort drive Claude Code
  (no supported API — Kitty/Terminal are the reliable spawns). By default that means opening the
  **Claude Code extension panel** (its ⌘Esc quick-launch; the resume/new-session UI), typing the
  optional initial task into the Claude input; set `spawn.vscodeFlavor` to `terminal` (⚙ Settings →
  Spawn) for the old behavior of typing a `claude` CLI line into a fresh integrated terminal. ssh
  spawns and gateway providers always use the terminal flavor (the extension can't run a remote
  claude or carry `ANTHROPIC_*` env).
- **Permission mode** — Default / Plan / Accept edits / Automate (`claude --permission-mode <m>`).
- **Provider** — which model/backend to launch this session against (see "Providers & models" below).
- **Initial task** (optional).

Spawning is **dry-run until you opt in**: leave it off to log the exact command to
`~/.claude/cc-shepherd.log` without launching, or flip **"Actually launch"** in ⚙ Settings → Spawn
(`spawn.live`; the `ORCH_DRY_RUN` code default stays as a safety net). The new session shows up as a
tile automatically. (The ⌘⌥S hotkey falls back to two native prompts if the modal can't open.)

## Providers & models (multi-model / other companies / local)

Claude Shepherd supervises **Claude Code** sessions, and Claude Code is provider-flexible,
so a "provider profile" is just a **named bundle of env vars + a model id** injected into
the `claude` launch. Define profiles in **⚙ Settings → Providers**, pick one per session in
the **New session** modal (or set a **Default provider**), and switch a running session's
model live from the detail panel's **Model** dropdown (`/model`). The tile/detail shows a
**model** badge for what's actually running (captured from the session's env by the hook).

Two kinds:

- **Claude** (`kind: "anthropic"`) — just sets `ANTHROPIC_MODEL` (e.g. `claude-opus-4-8`,
  `claude-sonnet-4-6`, `claude-haiku-4-5`) against the normal endpoint.
- **Gateway** (`kind: "gateway"`) — also sets `ANTHROPIC_BASE_URL` so Claude Code talks to an
  **Anthropic-Messages-compatible endpoint**: a [LiteLLM](https://docs.litellm.ai/) proxy
  (which translates to **Gemini, OpenAI**, and others), or a **local/remote REST server**
  (Ollama/vLLM/LM Studio, optionally behind LiteLLM). Set `baseUrl`, the `model` id your
  gateway expects, and optionally `smallFastModel` / `headers`.

**No API keys are stored.** A profile names an **environment variable** in `authTokenEnv`
(e.g. `MY_LITELLM_KEY`); the spawned **login shell** expands `$MY_LITELLM_KEY` at launch, so
the key lives in your shell (`~/.zshrc` / a secrets manager), never in `cc-config.json` and
never in Shepherd's process. Example `~/.claude/cc-config.json`:

```json
{
  "spawn": { "provider": "anthropic-opus" },
  "providers": [
    { "id": "anthropic-opus", "label": "Claude Opus 4.8", "kind": "anthropic", "model": "claude-opus-4-8" },
    { "id": "gemini", "label": "Gemini (LiteLLM)", "kind": "gateway",
      "baseUrl": "http://localhost:4000", "model": "gemini-2.5-pro", "authTokenEnv": "MY_LITELLM_KEY" }
  ]
}
```

**Limits (be honest):** every Shepherd control keeps working because the **harness is still
Claude Code** — only the backend model swaps. A non-Claude backend may ignore Claude-specific
behaviors (effort/thinking), but slash commands, hooks, and approvals are Claude Code client
features and still function. A session's **base URL is fixed at launch**, so switching the
*model* within a provider goes live via `/model`, but switching the *provider* (a different
base URL) means starting a **new session**. Running a *different agent CLI* (aider, gemini-cli)
is out of scope — those have no hook system, so the tiles/approvals couldn't work.

## Token usage

Shepherd reads token usage straight from Claude Code's **local transcript files**
(`~/.claude/projects/<proj>/<session>.jsonl`), which log every turn's `usage`. Three views:

- **Context-fullness bar (per tile)** — the last turn's prompt size (input + cache) ÷ the model's
  context window, colored blue → amber → red as it fills. Tells you which session to `/compact`.
  The window is **model-aware** (Opus 4.x / Sonnet 4.6 = 1M on Claude Code; others 200k), with a
  per-provider `contextLimit` override and a self-healing guard so a session never reads a false
  100%. Computed on the 60s usage pass (and live on the 1s loop for active sessions), so it shows
  on **every** tile — including idle/finished ones. **Local only, zero tokens, zero network.**
- **Fleet total (footer under the grid)** — cumulative tokens across active sessions (headline
  **excludes cache reads** — input + output + cache-creation — since cache reads dominate the gross
  count but aren't how the plan is metered; gross is on hover). Per-model breakdown in the detail
  panel. Recomputed on a **60s timer** (incremental reads — only new bytes) + an **Update now** button.
  **Local only, zero tokens.**
- **Plan window bars (footer)** — your real **session (5h)** and **weekly** utilization %, matching
  `claude.ai/settings/usage` and Claude Code's `/usage`, with reset times and a Sonnet-only line.

The window bars come from Anthropic's OAuth usage endpoint (`/api/oauth/usage`) using your existing
Claude Code login token (macOS Keychain or `CLAUDE_CODE_OAUTH_TOKEN`). **This is a metadata call —
it spends no model tokens**; it's polled at most every **180s**, sends the token only to
`api.anthropic.com` over HTTPS, and never logs it. If the token is missing/expired or the endpoint
is unreachable, the bars **fall back** to a labeled local approximation (rolling 5h/7d token sums
from your Anthropic-session transcripts).

**Honest limits:** usage is shown in **tokens, not dollars** (subscription cost is flat; gateway/
local model pricing is unknown). For **gateway** sessions (Gemini/OpenAI) cumulative usage still
appears (whatever the gateway reports; cache tokens ~0) — set a per-provider `contextLimit` (e.g.
Gemini → 1000000) so the fullness bar uses the right window. The plan window % reflects your
**Anthropic** account only (gateway/local tokens don't count against it). Local servers that omit
`usage` simply show no bar.

### Task queue
Each session has a queue (`Queue` button in the detail panel adds the input;
`Feed next` sends the front task; the tile shows `+N queued`). Turn on
`queue.autofeed` in the settings file (below) and Claude Shepherd feeds the next task
automatically each time the session finishes — so a session works through a
backlog unattended. Feeds are delivery-safe: a task is only popped off the queue when
the paste actually reached the session's window (no window match → it stays queued, and
the ledger records `task_feed_skipped`), and queues follow the **project**, so a
respawned or `/clear`-ed session inherits its folder's pending tasks.

Queue extras:
- **Edit the queue in place** — click "Queue: N" to expand the task list and reorder
  (▲▼) or remove (✕) entries. Edits are race-safe against the 1s autofeed loop: each
  one carries the task text you clicked, and a mismatch (the queue changed underneath)
  is refused and the list refreshed instead of moving the wrong task.
- **Bulk paste** — paste a multi-line list into the input and hit Queue: it splits into
  one task per line (bullets/numbering stripped, blanks dropped) after a confirm.
- **Task templates** — "Tpl ▾" next to Queue saves the current input as a named
  template and inserts saved ones back into the input (never auto-sends). Stored in
  `~/.claude/cc-templates.json`.
- **Project routing (4c-E)** — with `queue.routing.enabled` on AND a project armed via
  the detail panel's **route** toggle, the project's queue feeds **whichever of its
  sessions is free** (just finished a turn), not only the one that emptied its own
  backlog — parallel sessions in one folder drain a shared backlog. One feed per project
  per second, delivery-gated, ledgered as `by:"router"`; `starveMinutes` flags a project
  whose tasks wait with no free session (⌛). Off by default at both levels.

## Automation & policies (`~/.claude/cc-config.json`)

All automatic behavior is governed by one settings file, and **everything is off
until you turn it on**.

**Easiest: the ⚙ Settings panel.** Click the **gear button in the header** for a
form with every toggle — **Headless approvals** (one click: arm the gate + all
policies off) and its editable gated-tools list, the editor-window pop toggles, the
Spawn defaults, queue autofeed/dry-run/project-routing, escalation, the risk badge,
collision warning, drain, respawn (manual + auto), insights cap, the SSH status
bridge, and the advanced gate/policies — each with a one-line explanation. **Save**
writes `~/.claude/cc-config.json` (creating it if missing) and arms/disarms the gate
flag — no hand-editing. (A hand-added `risk.weights` tuning map and the
`spawn.searchRoots`/`bridge.staleSlackSeconds`-style power keys survive Saves.)

To edit by hand instead, copy [cc-config.example.json](cc-config.example.json) to
`~/.claude/cc-config.json` and flip what you want. Both the panel and the gate
read it (the panel live within ~1s; the gate on the next hook fire).

```json
{
  "queue":      { "autofeed": false, "dryRun": false,
                  "routing": { "enabled": false, "starveMinutes": 0 } },
  "escalation": { "enabled": false, "minutes": 5, "sound": false, "push": false, "pushTopic": "" },
  "focus":      { "popOnComplete": false, "popOnApproval": false },
  "spawn":      { "editor": "terminal", "live": false, "kittyRemote": true, "kittyAutoRemote": true,
                  "searchRoots": [], "searchDepth": 4 },
  "gate":       { "tools": "Bash Write Edit MultiEdit NotebookEdit" },
  "ledger":     { "enabled": false, "retentionDays": 30, "maxTotalMB": 0 },
  "decisions":  { "limit": 5, "hours": 48 },
  "notifications": { "days": 7 },
  "search":     { "rgBin": "", "maxResults": 200 },
  "bridge":     { "enabled": false, "intervalSeconds": 2, "staleSlackSeconds": 15 },
  "risk":       { "enabled": false, "thresholds": { "med": 34, "high": 67, "staleSeconds": 300 } },
  "collision":  { "enabled": false, "useGitRoot": false },
  "drain":      { "enabled": false },
  "respawn":    { "enabled": false, "auto": { "enabled": false, "maxRetries": 3, "staleSeconds": 600 } },
  "insights":   { "maxBlockSeconds": 1800 },
  "policies": {
    "approveRepeats": false,
    "autopilot": { "enabled": false, "minutes": 15 },
    "patterns":  { "enabled": false, "autoAllow": [], "autoDeny": [] }
  }
}
```

- **queue.autofeed / dryRun** — auto-feed queued tasks on done (dryRun logs instead).
- **queue.routing** — 4c-E project routing (see "Task queue" above): global switch +
  per-project arm toggle; `starveMinutes` flags queued work with no free session.
- **decisions / notifications / search / bridge** — the gate decision log window, the 🔔
  history window, the 🔎 fleet-search caps, and the SSH status bridge (see their sections;
  all read-only except the bridge, which is off by default).
- **escalation** — when an approval waits longer than `minutes`, nag harder: a
  stronger tile pulse always, plus an optional `sound` and an optional high-priority
  `push` to your ntfy `pushTopic`. Both channels off by default.
- **focus.popOnComplete / popOnApproval** — pop/focus the **detected** editor (VS Code /
  Cursor; Kitty/terminal are left alone) when a session finishes / needs approval. Both off
  by default; toggle from the ⚙ panel. The Stop/Notification/PermissionRequest hooks call
  [cc-popup.sh](cc-popup.sh) with the event, which opens the window only when the matching
  flag is on (legacy `focus.popEditor` still seeds both). Note: the Claude Code VS Code
  extension may raise its own window on completion independently of this.
- **spawn** — the New / New project launcher: `editor` (terminal/kitty/vscode/cursor),
  `live` (false = dry-run, log only), `kittyRemote` (give spawned Kitty windows remote control),
  `kittyAutoRemote` (auto-enable remote control in `kitty.conf` when Kitty is in use).
- **gate.tools** — space/comma list of tools the approval gate holds for you (default
  `Bash Write Edit MultiEdit NotebookEdit`); editable from ⚙ Settings. With the gate armed
  and all policies off ("Headless approvals"), these wait for your panel Approve/Deny —
  headless, no window pop — and fall back to Claude's native prompt if you don't answer.
- **policies.approveRepeats** — if you already approved the *exact* command in a
  session, auto-approve it next time.
- **policies.autopilot** — the **Autopilot** button time-boxes a session to
  auto-approve *all* its prompts (badge `🛫 autopilot`), expiring after `minutes`.
- **policies.patterns** — gate honors `autoDeny` (wins) and `autoAllow` globs,
  written like `"Bash(npm test*)"` or `"Read"`.

The gate's auto-decisions apply only to the gated tools (`gate.tools`, editable in
Settings) and are logged to the Hammerspoon Console / hook stderr whenever they
fire. Auto-deny always beats auto-allow.

### More fleet controls (all off by default)

These extend the panel without changing any existing behavior when left off:

- **Per-session tool gating** — the detail panel's **Gate** dropdown overrides
  `gate.tools` for one session: *Default* (use the fleet list), *All* (gate
  everything the fleet considers risky), *None* (trusted session — gate nothing), or
  *Custom*. Stored per session in `~/.claude/cc-gate-tools/<key>`; the gate reads it
  on every request. Lets a risky experiment lock down while a trusted session runs free.
- **risk** — a per-session risk **indicator** computed from that session's ledger
  history (deny rate, auto-deny hits, timeout-fallbacks, slow approvals, tool volume).
  Med/high shows a small ⚠/▲ badge on the tile; low shows nothing. Indicator only —
  it never blocks or quarantines. Needs the ledger on for data.
- **collision** — flags tiles when 2+ **active** sessions share a working directory
  (amber ring + "⚠ shared dir"), so two agents don't silently clobber each other's
  edits. `useGitRoot` groups by repo root (cached `git rev-parse`) instead of the exact
  folder. Detection only — it can't lock another process's writes.
- **drain** — a right-click **Drain (finish turn, then close)** action: waits for the
  current turn to finish, then closes (closes immediately if already idle/done).
- **respawn** — a right-click **Respawn from cwd** action that relaunches a dead/stale
  session from its last working dir + matched provider + editor. `respawn.auto.enabled`
  adds **automatic** respawn: a session whose status file freezes **mid-turn** (status
  `working` with no hook write for `respawn.auto.staleSeconds`, default 600 — well above
  the longest tool call, so a 2-minute `npm test` never reads as a death) is relaunched,
  capped by `respawn.auto.maxRetries` **per launch folder** (the budget resets only after
  sustained healthy running, so a crash-looping folder can't thrash). Sessions waiting on
  an **approval are never auto-respawned** — that's the escalation nag's job.
- **escalation.hung** — a **stuck-session watchdog**: a session that stays `working` with
  no transcript growth for `escalation.hung.minutes` gets a ⏳ + purple ring and nags once
  per stall (reusing the escalation sound/push prefs). Complements the approval-wait
  escalation — that covers a session waiting on *you*; this covers one wedged on its own.
- **insights** — the 📊 toolbar button opens a read-only **Fleet insights** view that
  aggregates the ledger (turns per session, approval/denial rates, decision provenance,
  the total time the fleet spent blocked on you, and **24h hourly trend sparklines**).
  Always available like the audit view; shows zeros until the ledger is enabled.

Per-session gating, drain, and respawn use these state dirs / config keys:
`~/.claude/cc-gate-tools/<key>`, and `risk` / `collision` / `drain` / `respawn`
(incl. `respawn.auto`) / `escalation.hung` / `insights` blocks in `cc-config.json`
(see [cc-config.example.json](cc-config.example.json)).

## Audit log & insights

Two header overlays read fleet activity. Both are **local and cost no model tokens**.

- **📜 Audit ledger** — an opt-in, append-only JSONL record at
  `~/.claude/cc-ledger/YYYY-MM-DD.jsonl` (one event per line): session start/end,
  prompts, tool requests, gate **decisions** (with provenance — autoDeny / autoAllow /
  autopilot / approveRepeats / human / timeout), mode/model/effort changes, nudges,
  clears, compacts, spawns, relabels. **Off by default** — enable `ledger.enabled` (it's
  the source of data for everything below). The overlay has **Rows** + **Timeline** tabs,
  filters by session/type/date, and per-row **redact**, **export**, and **purge**.
  Retention is GC'd ~hourly by `ledger.retentionDays` / `ledger.maxTotalMB`. A **Review
  activity** button sends the current slice to the selected session as a read-only
  governance prompt (assess risky/odd actions — never edits).
- **📊 Fleet insights** — a read-only aggregate of the ledger: turns per session,
  approval/denial rates, decision provenance, most-active sessions, and the total time
  the fleet spent **blocked on you** (the gap from each request to its human/timeout
  answer, capped by `insights.maxBlockSeconds` so an overnight idle isn't counted). A
  **Trends — last 24h (hourly)** section adds four sparklines: time blocked on you, fleet
  activity, active sessions, and denial rate. Always available; zeros until the ledger is on.

Three more ledger-backed views (all read-only, local, zero model tokens):

- **🔔 Notification history** — "what fired while you were away": escalations, stall
  warnings, auto-respawns, and every **non-human** gate decision, in an **Alerts** tab of
  the audit overlay. The header bell shows an unseen count; opening it marks everything
  seen and highlights what's new since you last looked. (If you've set
  `ledger.captureTypes`, include `escalation` and `hung`.)
- **Per-session gate decision log** — the detail panel shows the selected session's last
  few gate decisions, grouped with counts and provenance ("⛔ deny Bash ×4 (autoDeny:
  Bash(rm*)) · 2m ago"), so what the gate has been doing to a session is visible right
  where you act on it. `decisions.limit` / `decisions.hours` tune it.
- **🔎 Find in fleet** — search every session's **transcript** (live *and* dead sessions)
  plus the ledger: "which session touched `auth.ts`?", "who ran that migration?". Click a
  hit to select the live session (or open a dead one's audit timeline). Instant with
  [ripgrep](https://github.com/BurntSushi/ripgrep) installed (`brew install ripgrep`);
  falls back to grep — slower, never broken.

### SSH status bridge (remote sessions as tiles)

A provider can carry `ssh: {"host": "devbox", "user": "adam"}` — its sessions run
`claude` on the remote box inside a local terminal. With **⚙ Settings → SSH status
bridge** enabled, Shepherd also rsync-pulls each such host's remote `~/.claude/cc-status/`
(every `bridge.intervalSeconds`, key-based auth required) so those remote sessions render
as **⇄ tiles** with live status. Remote tiles are **headless-only**: Approve/Deny route
back over ssh as nonce-bound decision files; keystroke actions (nudge/stop/clear/…) are
disabled. Remote staleness gets `bridge.staleSlackSeconds` of slack for sync lag, and a
stalled sync shows "bridge offline" on the tile. The remote box needs this repo's
`make install` run on it. Off by default; see todos.md for the hardware-verification
checklist.

## Install (about 5 minutes)

1. **Install Hammerspoon** (free) and `jq` (required for the rich tiles):
   ```
   brew install --cask hammerspoon
   brew install jq
   ```
   Launch Hammerspoon once and grant it Accessibility permission when asked
   (System Settings > Privacy & Security > Accessibility). It needs that to focus
   windows and send keystrokes.

2. **Run the installer** (idempotent — safe to re-run):
   ```
   make setup
   ```
   This copies the hook scripts + logic into `~/.claude` and `~/.hammerspoon`,
   **merges** the hooks into `~/.claude/settings.json` (backing it up first and
   preserving any hooks you already have), ensures the `dofile(...)` line in
   `~/.hammerspoon/init.lua`, and builds **Shepherd.app** (a Dock launcher — see below).

3. Click the Hammerspoon menu-bar icon and choose **Reload Config**.

The panel appears top-right. Drag it by its title bar, resize it, and it floats
above other windows and shows on every Space.

### Shepherd.app — a Dock launcher
`make setup` (or `make app`) builds **`~/Applications/Shepherd.app`** with a sheep
icon; drag it to your Dock and click it to show/hide the panel like any app. It
toggles the panel via Hammerspoon's built-in `hammerspoon://` URL scheme (no extra
deps). First open is unsigned, so right-click → **Open** once to clear Gatekeeper.

To pin it to the Dock automatically, run **`make dock`** (builds the app if needed,
then adds it to the Dock — idempotent; the Dock briefly restarts). Remove it any time
by dragging the icon off the Dock.

### Launch on startup
Shepherd runs inside Hammerspoon, so "launch on startup" means **Hammerspoon opens at
login** and the panel comes up with it. This is **on by default** the first time
Shepherd runs. Toggle it any time from **⚙ Settings → General → "Launch Shepherd on
startup"** — it sets Hammerspoon's real *Open at Login* item (`hs.autoLaunch`).

### Kitty users
For reliable click-to-answer / headless approve on Kitty, Shepherd auto-enables
remote control in your `kitty.conf` (`allow_remote_control` + `listen_on`) when a
Kitty session is detected — backing the file up first. **Restart Kitty** for it to
take effect (sessions Shepherd spawns get it via launch flags, no restart needed).

## Headless approvals (the gate)

Want to approve/deny from the panel with **no window switch** and still keep Claude
fully gated? Flip **Headless approvals** in ⚙ Settings — one click that arms the gate
([cc-approve.sh](cc-approve.sh)) and turns off every auto-approve policy. A permission
request for a *gated* tool (`gate.tools` — Bash/Write/Edit/MultiEdit/NotebookEdit by
default, editable in Settings) then turns the tile red, and Approve/Deny answer it via
a decision file — **headless, no focus, no keystrokes**. Claude can't run a gated tool
until you decide. (Manual equivalent: `touch ~/.claude/cc-gate.enabled` to arm, `rm` to
disarm.)

It is built to be safe:

- **Never freezes a session.** The gate only waits while the panel is running
  (it checks the panel's heartbeat). Panel closed → the request falls straight
  through to Claude Code's native prompt.
- **Times out gracefully.** If you don't answer within `CC_GATE_TIMEOUT` seconds
  (default 120), it falls back to the native prompt rather than denying. (The shipped
  hook registration carries a 130s hook timeout so Claude Code doesn't kill the gate
  mid-wait; the installer migrates existing installs.)
- **Decisions are request-bound.** Each gated request publishes a one-time nonce and the
  panel's Approve/Deny echoes it back, so a leftover or concurrent decision file can never
  answer a *different* request — no stale silent-allows, even with several gated calls in
  flight on one session.
- **Reads stay fast.** Only the tools in `gate.tools` are gated; everything else runs normally.

The advanced **policies** below (autopilot, approve-repeats, pattern auto-allow/deny)
let some requests auto-decide; Headless approvals keeps them all off so *you* decide
every gated tool. Hook-env tunables: `CC_GATE_TOOLS` (overrides `gate.tools`),
`CC_GATE_TIMEOUT` (default 120), `CC_PANEL_MAX_AGE` (default 5).

## Test it without Claude

Each command writes one fake event; the panel should update within a second.
The status scripts honor `CC_STATUS_DIR`, so you can rehearse in a throwaway dir:

```
export CC_STATUS_DIR=/tmp/cc-test
printf '{"session_id":"demo1","cwd":"'"$PWD"'","prompt_text":"Refactor the parser"}' \
  | bash ~/.claude/cc-status.sh userpromptsubmit
printf '{"session_id":"demo1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Allow Bash command: npm test"}' \
  | bash ~/.claude/cc-status.sh notification
printf '{"session_id":"demo1","cwd":"'"$PWD"'"}' \
  | bash ~/.claude/cc-status.sh stop
printf '{"session_id":"demo1","cwd":"'"$PWD"'"}' \
  | bash ~/.claude/cc-status.sh sessionend     # removes the tile
```

(Leave `CC_STATUS_DIR` unset to point at the real `~/.claude/cc-status` the panel
watches.)

## Confirm your hook payloads (recommended once)

Field names like `prompt_text` and `notification_type` can vary slightly by
Claude Code version. To capture exactly what your build sends, set
`CC_STATUS_DEBUG=1` for the hooks (or just once by hand) and the scripts append
raw stdin to `~/.claude/cc-status/.debug.log`. Run a real session, trigger a tool
and an approval, then check that log and adjust the field paths in
[cc-status.sh](cc-status.sh) if needed.

## Stream Deck (physical, optional)

Claude Shepherd can mirror the panel onto a physical Elgato Stream Deck and let you
act on sessions from its keys — no extra software, because Hammerspoon drives the
deck directly and reuses the same actions as the on-screen panel. It adapts to
any size (Mini 6 / Standard 15 / XL 32) by asking the device for its key count at
connect time.

**Plug-and-play:**

1. **Quit the official Elgato Stream Deck app.** Only one program can own the
   device at a time, and Claude Shepherd takes it over.
2. Plug in the Stream Deck (or it's already plugged in).

That's it — Hammerspoon detects it and paints one session per key, colored by
status (gray idle / amber working / green ready / **red blinking = needs you**),
with sessions that need you sorted to the front.

**Key actions:**

- **Short press** → **Jump** to that session's window. If the session is waiting
  on the hands-free gate, short press **Approves** it instead.
- **Long press** (~0.7s) → **Deny** a gate-waiting session. For a normal session,
  long-press does nothing unless you set `SD_LONG_PRESS_STOPS = true` (then it
  **Stops** the turn) — off by default to avoid accidental interrupts.

Tunables near the top of [claude-dashboard.lua](claude-dashboard.lua):
`STREAMDECK_ENABLED`, `SD_LONG_PRESS`, `SD_LONG_PRESS_STOPS`, `SD_BRIGHTNESS`,
`SD_FALLBACK_KEYS`. If you'd rather keep your normal Elgato profiles running,
Claude Shepherd would instead need a separate Stream Deck *plugin* (coexists with the
Elgato app) — that path isn't built yet.

## Themes

A dropdown in the top-right switches themes instantly; your choice is saved.

- **Cards** (default): two-line tiles with name, status, and time/pending.
- **Bar**: compact rounded pills in a single flowing row.
- **Contrast**: large, bold tiles with a thick colored border.
- **Dots**: minimal vertical list, just a colored dot and the project name.

To change the default for a fresh install, edit `DEFAULT_THEME` near the top of
[claude-dashboard.lua](claude-dashboard.lua). To restyle a theme, edit its
`.theme-NAME` CSS block (or open the webview developer tools to tweak it live).

## Testing & development

Claude Shepherd has a **side-effect-free** test suite. Run it with:

```
make test          # or: bash tests/run.sh
```

**Deploying changes.** Hammerspoon runs the **copies** in `~/.hammerspoon/`
(`init.lua` does `dofile(... claude-dashboard.lua)`), so edits in this repo are
**not live until copied**. After a change:

```
make install       # copy claude-dashboard.lua + cc-core.lua -> ~/.hammerspoon/
make reload        # hs.reload() via the `hs` CLI (needs require('hs.ipc'))
make deploy        # test + install + reload, in one shot
```

A plain `hs.reload()` without `make install` first just re-runs the *old* copy.

It never touches your real `~/.claude/cc-status`, never fires a keystroke, never
focuses a window, and never spawns a session. How that's possible:

- **Pure logic in [cc-core.lua](cc-core.lua)** — status parsing, sorting, staleness,
  action selection (+ the editor-aware target), deck layout, transcript snippet,
  editor-aware spawn spec, `kitty @` argv + key tokens, permission-mode cycle steps,
  window focus-candidate/title matching, folder-browser path helpers, recent-dirs,
  new-project validation, persistent-relabel set/apply-by-cwd, pmset command/parse,
  gated-tool list parsing (+ per-session `resolveGateTools` precedence), hook-merge,
  panel geometry, image data-URL parsing, `/effort` + AskUserQuestion answer keys
  (multi-select guarded), provider env-injection / `respawnSpec` / `providerByModel`,
  ledger parse/filter/narrative, fleet-insights aggregation (`fleetStats` /
  `blockedSeconds`), per-session `sessionRisk`, `collisions`, and `shouldDrainClose` —
  has no `hs.*` calls and is unit-tested directly in plain `lua`
  ([tests/core.test.lua](tests/core.test.lua) + [tests/ui.test.lua](tests/ui.test.lua)).
- **All effects go through one `fx` table** (focus, keystrokes, paste, send-keys,
  decision/file writes, Stream Deck, session spawn). Production wires it to
  Hammerspoon; tests pass a **recorder** that captures intent — so a test asserts
  *"would press Return on window X"* or *"would spawn in /path"* without doing it.
- **The shell scripts** are driven against a throwaway `CC_STATUS_DIR`:
  [tests/status.test.sh](tests/status.test.sh) (status writer),
  [tests/editor.test.sh](tests/editor.test.sh) (editor/mode/effort detection),
  [tests/ask.test.sh](tests/ask.test.sh) (AskUserQuestion + multi-select capture),
  [tests/config.test.sh](tests/config.test.sh), [tests/gate.test.sh](tests/gate.test.sh)
  (the config-driven gated-tool list + per-session overrides),
  [tests/ledger.test.sh](tests/ledger.test.sh) (audit ledger append/retention),
  [tests/install.test.sh](tests/install.test.sh) (the installer against a temp `$HOME`), and
  [tests/escaping.test.sh](tests/escaping.test.sh) (the panel-webview XSS escaping tripwire).
- **659 core + 104 ui + 132 bash checks, all side-effect-free.** Every new feature lands with its tests.

Spawning is additionally gated by `spawn.live` (default off → log-but-don't-launch),
with the `ORCH_DRY_RUN` code constant as a fixed safety net, so the live app never
launches until you opt in from Settings.

Layout: [cc-core.lua](cc-core.lua) (logic) + [claude-dashboard.lua](claude-dashboard.lua)
(Hammerspoon bootstrap) + `tests/` (`run.sh`, bash + lua suites, `support/`).

## Notes and tweaks

- **Different editor:** Cursor and VS Code Insiders are already in the
  `EDITOR_BUNDLES` list in the `.lua` file; add or reorder as needed.
- **Select vs jump:** single-click selects a tile (opens its controls);
  **double-click** jumps to the window; **right-click** opens the relabel/close menu.
  This keeps the grid clean and lets you act (especially hands-free gate approvals)
  without switching windows.
- **Window size is remembered:** resize/move the panel and it's saved (in
  `hs.settings`); a reload restores it instead of snapping back to the default. If a
  saved frame ends up off-screen or too small, it falls back to the top-right default.
- **Orphan tiles self-clean:** a status file with no `session_id` that goes stale
  (from a hook fire that lacked one), or any tile older than 24h, is auto-pruned —
  so dead/duplicate tiles don't pile up. (`PRUNE_NO_SID` / `PRUNE_SECONDS`.)
- **Window not focusing:** open the Hammerspoon Console and double-click a tile.
  The log shows whether a title match was found. Focus matches the folder name in
  the VS Code window title (the default title format).
- **Logs:** the hook scripts log to stderr (`[cc-status]` / `[cc-approve]`). The
  Lua side logs to the Hammerspoon Console **and** mirrors every line to
  `~/.claude/cc-shepherd.log` — `tail -f ~/.claude/cc-shepherd.log`. Keep the HS
  Console **closed**: an open console pops over your work whenever Hammerspoon
  activates, so read the file instead.
- **Relabel / Close / New session** use in-panel UI (inline bars / a modal), not
  native dialogs, so they don't activate Hammerspoon and yank its console forward.
  (⌘⌥S falls back to a native prompt only if the modal can't open.) Relabels persist
  per project path in `~/.claude/cc-labels.json`.
- **Known limit:** click-to-focus matches by window title, so two sessions in the
  *same* window remain ambiguous to jump to (their tiles are still distinct).
