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

Status is hook-driven, but a `done` tile **self-heals back to `working`** when the
transcript shows the turn resumed — the model wrote a new line *or* you typed a fresh
prompt — so in Auto mode or the VS Code extension (where a text-only reply, an
auto-continued turn, or a freshly submitted prompt can land before the `working` hooks
do) a tile no longer gets stuck on "Ready for you" while it's actually working. Spurious
IDE file-open lines are ignored, so opening a file never false-flags it.
(`status.resumeSlack`, default 2s.)

### Session observability (L5)

All derived locally from the transcript Shepherd already tails — no extra hooks:

- **Error cause** — an errored tile (frozen on an API error) shows a coarse cause
  badge: `[budget exceeded]`, `[timeout]`, `[runtime error]`, `[model error]`,
  `[user cancelled]`. The cause is recorded in the audit log (errors-by-cause).
- **Plan / TODO** — selecting a tile shows the agent's current plan and TODO list
  (its latest `TodoWrite` / plan-mode plan), if any.
- **Auto-title** (off by default, `autoTitle.enabled`) — names an unlabeled tile
  from its first prompt (cached). A manual relabel always wins.
- **Loop watchdog** (off by default, `escalation.loop.enabled`) — a ⟳ badge when a
  working session keeps repeating the same tool call (e.g. re-running a failing
  command); detection only.
- **Desktop banners** (off by default, `notifications.banner.onApproval` /
  `onDone` / `onAutoApproved`) — a native macOS notification on a rising edge into
  "needs you" / "done", or when a session **auto-approves** a tool (the last needs the
  audit ledger on and can lag ~30s); click it to jump to the session.
- **Post-run self-summary** (off by default, `summary.enabled`) — when a session
  finishes a turn, Shepherd types a brief "summarize what you just did" prompt into it
  (for the log you're watching — it forbids further edits). Fires once per turn (the
  summary's own completion is skipped so it can't loop); local sessions only.
- **PR/MR status** (off by default, `prStatus.enabled`, needs the GitHub CLI `gh`) — a
  clickable **"PR #N open / merged"** badge per repo, polled with `gh pr view`
  (status only — Shepherd never opens or edits PRs). Self-gates when `gh` is absent or
  the repo has no PR/remote.
- **Host stats + fleet idle-since** (off by default, `insights.hostStats`) — a read-only
  strip at the top of the 📊 Fleet insights overlay: CPU / memory / disk / uptime / load,
  plus how long the whole fleet has been idle. A queue-starvation alert notes when the box
  is CPU/disk-pressured. Pressure thresholds are hand-editable
  (`insights.hostPressure.{cpu,mem,disk}`, default 90%).
- **Session history browser** — a 🗂 **History** tab in the 📜 Audit overlay (see
  "Audit log & insights") lists every recorded session with its activity, a fuzzy filter,
  sort + pin, and a multi-select delete.
- **Subagent fan-out (Agents tab)** — when a session spawns subagents or runs a Workflow,
  the detail panel's **Agents** tab lists each one, **grouped under a per-Workflow header
  with a running/total rollup** (`⚙ Workflow wf_… · N agents · M running`). Each row is
  labeled by the agent's **actual task prompt** (e.g. "Review auth.ts"), not its auto-slug,
  with a green running dot and its latest "Doing:" line; click a row to drill into that
  agent's recent output. Read from the `subagents/` tree Claude Code writes beside the
  transcript — no extra hooks. Self-gates when a session has no subagents.
- **Background-work indicator** — while background work is running (delegated subagents or a
  Workflow fleet), the tile shows a green **⚙ N** pill, **and a done/idle session reports
  "Running N agents" instead of "Ready for you"** (with the working dot) so a session that's
  busy behind the scenes isn't mistaken for one waiting on your reply. The underlying status
  is unchanged — this is display-only. Tunable window: `subagents.activeWindow` (default 45s).
- **Run score** — a **Score** button in the detail panel rates the selected session 0–100 from
  the audit ledger (penalizes API errors, denied tools, loop episodes, and forced respawns),
  shows a ⚠ when recent sessions trend down, and a mini sparkline of the trend. Needs the Audit
  log on; weights are hand-tunable (`score.weights`).

### Event-callback rules (L6, off by default)

Opt-in declarative rules (`~/.claude/cc-rules.json`, enable with `rules.enabled`) that react to a
session edge with a safe effect — a lighter, per-session complement to the fleet automations.
A rule is `{name, trigger:{kind, match?}, processor:{kind, …}, once?}`:

- **trigger.kind** — `done`, `error`, or `approval` (the fresh status edge).
- **trigger.match** (optional) — wildcard-glob scope on `project` / `group` / `sessionKey` /
  `provider` (absent = fleet-wide).
- **processor.kind** — `log` (write an audit note), `relabel` (rename the tile), or `nudge`
  (type text into the session, via the same delivery-gated path as a manual nudge).
- **once** — fire at most once per session.

Example: `{ "name":"flag-prod-errors", "trigger":{"kind":"error","match":{"group":"prod"}},
"processor":{"kind":"relabel","label":"⚠ prod error"}, "once":true }`. Every rule firing is
ledgered as `by:"rule"`. Automation events (`auto_respawn`, `auto_continue`) now also record an
`outcome` (and a death that can't be auto-respawned is logged instead of failing silently).

### Scheduled routines (L7, off by default)

Routines (`~/.claude/cc-schedules.json`, enable with `schedules.enabled`) fire the normal
spawn/nudge effects on a schedule — they are NOT a second executor, and a scheduled spawn still
respects `spawn.live` (dry-run by default). A routine is `{name, kind:"cron"|"oneShot",
cron|at, folder, editor?, provider?, model?, permMode?, prompt?, action:"spawn"|"digest",
enabled:false}`:

- **cron** uses a standard 5-field expression (`min hour dom month dow`, with `*`, ranges,
  lists, and `*/step`); **oneShot** uses an `at` epoch and self-deletes after it fires.
- **action "spawn"** (default) launches a session in `folder` with the given options + `prompt`.
- **action "digest"** pushes a fleet shift report (`fleetStandup`) over a window via `ntfy`
  (`pushTopic` or the escalation push topic) — a daily/weekly summary; needs no folder.
- `schedules.maxConcurrent` backpressure defers spawns when the fleet is at capacity.

Example: `{ "name":"nightly-tests", "kind":"cron", "cron":"0 2 * * *", "folder":"/repo",
"prompt":"run the full test suite and summarize failures", "enabled":true }`. Each firing is
ledgered as `schedule_fire`. (Routines are hand-edited for now; the routine-board UI is a
deferred follow-up.)

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
- **⚖ A/B fork-to-compare…** — run the same task as 2+ variants (different model
  and/or prompt) in **isolated git worktrees** of this project, then score them side by
  side and keep the winner. Opens the A/B panel **pre-scoped to this tile's folder**
  (the repo field stays editable, so you can retarget or A/B any repo). *This is a
  per-project action — it used to be a global button in the header.*
- **Clear conversation / Compact** — native confirm, then run `/clear` or `/compact`
  in the session (same effect as the detail-panel buttons).
- **Close instance** — confirm, then best-effort close the editor window (⌘⇧W) and
  remove the tile (the project's saved label is kept for next time). *Note:* it finds
  the window by **title**, so for two sessions sharing a name, prefer **Forget tile** to
  clear a stale one (Close could match the live twin's window).
- **Forget tile (no close)** — just drops the dashboard tile (removes its status file)
  with **no window keystroke**, so it can't close a live session that shares the name.
  Use it for stale/orphan tiles (a session that ended without a clean `SessionEnd`). A
  still-running session simply reappears on its next hook event — so it's always safe.
  Note: a `/clear` (or restart) leaves a stale **duplicate** tile behind; the panel now
  **auto-prunes** these once the fresh session is live by matching the old + new tile to
  the same terminal/editor **window** (kitty window id, or the host pid for VS Code/
  Cursor), so you rarely need Forget for `/clear` ghosts.
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
  held off so you resume the *same* session rather than relaunching it. **Auto-Continue**
  (⚙ Settings, off by default) does this for you: after a grace delay it types `continue`
  automatically, capped per folder so a persistently dead connection can't loop.
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
- **Model** dropdown — shows the session's **current** model (read live from the transcript, so it
  follows an in-session `/model`) and switches it within the backend (`/model <id>`). The switchable
  list comes from the `providers[]` you define in `cc-config.json`; with none configured it shows
  just the current model. Changing the *provider / base URL* needs a fresh session (by design).
- **Gate** dropdown — per-session tool gating (Default / All / None / Custom): override the
  fleet `gate.tools` for just this session. Only enforced while headless approvals are armed.
- **Nudge box** — a multi-line input: **Enter** sends, **Shift+Enter** adds a newline
  (mirrors the Claude chat), so a pasted multi-item list arrives intact. **Paste an
  image** and it's attached as a chip; **Send** delivers text and/or image via the
  clipboard (one ⌘V, newline-safe). **Queue** saves text for later (the tile shows
  `+N queued`, **Feed next** sends the front one).

The **Wants** (the exact command) and **Why** (the assistant's reasoning before a
request) clamp to two lines — **click to expand**.

The detail panel groups its views into a **tab strip** — **Activity** (the default: status,
wants/why, plan/TODO, lineage), **Transcript** (recent turns + search), **Rewind**
(checkpoints + this session's recorded activity), **Decisions** (the gate decision log),
**Usage** (per-session token breakdown), **Changes** (see below), **User Stories** (gated —
see below), **Agents** (subagent/Workflow fan-out), and **Queue**. The expensive tabs load
only when opened. The **⋯** button hides
tabs you don't want; your choice (and the last-open tab) is remembered per project. A **⤓
Export** button (also on the tile right-click menu) archives the session — its transcript
`.jsonl` plus a `meta.json` (label, provider/model, lineage, activity counts) — into
`~/.claude/cc-exports/` and reveals it in Finder.

#### Changes tab (per-session git status + diff)

The **Changes** tab shows the session folder's working tree: a list of changed files with
A/M/D/R/?? marks, and **click any file to expand its colorized diff** (rename-aware). Read-only,
local sessions only, with a **↻ Refresh**. Nothing runs against the repo except `git status` /
`git diff` from the repo root.

#### User Stories tab (gated — view/edit `spec/product/user-stories.md`)

Shown **only when** the session's project has `spec/product/user-stories.md` (it appears /
disappears live if the file is created or deleted mid-session). It lists the file's stories
grouped by capability area (the `##` headings), with **+ Add story** per area, **double-click**
a story to edit it inline, **✕** to delete, and an explicit **Save** (staged edits, with an
"● unsaved" indicator). A soft **⚠** flags any story missing the mandatory "so that". The file's
non-story content — title, intro, headings, prose, fenced code — is preserved **verbatim**
(an unedited file round-trips byte-for-byte), and saves are **hash-guarded** against an external
edit and written atomically; an edit can't inject fake structure and `*`/CRLF are preserved.

To **generate** these files for a project that doesn't have them yet — especially a **rune**
project — see the playbook in
[docs/reverse-engineering-user-stories.md](docs/reverse-engineering-user-stories.md). Shepherd's
own [spec/product/spec.md](spec/product/spec.md) and
[spec/product/user-stories.md](spec/product/user-stories.md) are a worked example.

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
  search/group) at once: **Approve all** waiting sessions or **Stop all** working ones
  (confirm). Buttons show live counts and appear only when there's something to act on, and
  the row scales its type down rather than wrapping when the panel is narrow. (There is no
  bulk nudge — broadcasting one message to the fleet was noise, not a fix.)
- **📜 Timeline** — the detail-panel **Timeline** button opens the audit overlay scoped to
  that one session's chronological history (needs the ledger enabled).

## Global hotkeys

Act on the session that needs you without touching the panel. Defaults are ⌘⌥-based;
**remap any of them in `cc-config.json` under `hotkeys`** (each `{ "mods": [...], "key": "x" }`):

- **⌘⌥A** — approve the front approval (hands-free via the gate when it's waiting).
- **⌘⌥J** — **jump to the session that most needs you, from any app.** Ranks hard
  attention signals: a pending **approval** first, then a session frozen on an API
  **error**, then one the watchdog flagged **stalled** — and focuses its window even
  when the panel isn't open. (Falls back to the front session when nothing's wedged.)
- **⌘⌥N** — cycle-jump to the next session.
- **⌘⌥S** — spawn a new session (see below).
- **⌘⌥B** — show/hide the panel — state-aware, so it **restores even after a native Dock-minimize**
  (no more "wrong-way" toggle). The 🐑 **menu-bar icon → "Show panel"** is the always-reliable way
  to bring it back; the Dock launcher app is an optional extra.

Remapping notes: valid modifiers are `cmd`/`command`, `ctrl`/`control`, `alt`/`option`, `shift`.
macOS can't bind a bare un-modified key globally **except function keys** (`f1`–`f20`, which take
`"mods": []`). Single-modifier combos collide — `ctrl` alone breaks terminal readline (⌃A/⌃N/⌃S),
`alt` alone hits app shortcuts — so ⌘⌥ (or ⌃⌥) stay the low-conflict picks. A malformed entry keeps
its default; reload Hammerspoon (menu-bar 🐑 → **Reload config**) after editing.

Forget the combos? The small **⌨ button** in the **bottom-right** of the panel pops
up a legend of every shortcut and what it does (sourced from the live bindings, so
it never drifts — including your remaps).

## Keep this Mac awake (caffeinate)

The **☕ toggle** in the header keeps your Mac awake while long agent runs work
unattended — it runs `pmset -a disablesleep 1/0` (so it holds even with the lid
closed). Because that needs root, macOS asks for your password each time you flip it
(your choice over a passwordless sudoers entry). The button reads the real state via
`pmset -g` (no password needed) and shows **☕ Awake** (amber) when on.

## Lock the screen (keep agents running)

The **🔒 button** (next to ☕ Awake) locks the Mac behind a full-screen overlay that
blocks all keyboard/mouse input until you type your password — while **everything keeps
running**: Claude sessions, the approval gate, and remote control. It is deliberately
**not** the macOS login window (that would block Shepherd's keystroke control of your
GUI sessions). First click sets a password (stored as a salted SHA-256 hash in
`~/.claude/cc-lock.json` — never plaintext, and it's your own password, not a hash you
type). Pair it with **Awake** to close the lid locked and leave the fleet working. It's a
**soft lock** (deters casual access, not a security boundary): a `⌘⌥⌃⇧U` chord force-unlocks
so a typo can't lock you out, and `killall Hammerspoon` / a reboot always releases it. For a
true security boundary use the real macOS lock — but it stops keystroke-driven control.

## Spawn new sessions

Click **New** (or **⌘⌥S**) to open the **New session** modal:

- **Open existing / Start new project** — open a folder, or create a new folder and start in it.
  A brand-new project is the fragile spawn (cold-start window on the Welcome tab, Workspace Trust
  prompt), so new-project spawns get extra settle time, open VS Code with `--disable-workspace-trust`,
  re-assert the chat-input focus, and **paste** the initial task — so the prompt reliably lands and the
  session actually starts.
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

### Agent profiles (spawn from a saved agent)

Beyond presets (folder + editor + mode + provider), the modal has an **Agents** row — saved,
reusable **agent profiles** you hand work off to: a name + persona (role/goal/backstory) +
provider/model + permission mode + an optional seed task + attached **skills**, **MCP servers**,
**knowledge** dirs, and **plugins**. Click an **✦ agent chip** to *spawn from that agent* in one
click; **Save as agent** in the footer captures the current form (plus a role you're prompted for).
Stored in `~/.claude/cc-agents.json` (operator data — **no secrets**; an MCP server's auth is an
env-var NAME your shell expands, never a value).

Spawning from an agent emits the right launch flags for native Claude Code: `--append-system-prompt`
(persona + skills), `--mcp-config` (built from `~/.claude/cc-mcp.json`, secrets as `${VAR}` refs),
`--add-dir` (knowledge), `--agent`, `--plugin-dir`. A read-only **Skills card** in the modal lists
every skill in `~/.claude/skills` (its `/command` + description). Real spawning still honors
`spawn.live` (dry-run by default).

Today you attach skills/MCP/knowledge to a profile by editing the `cc-agents.json` / `cc-mcp.json`
arrays by hand — a profile is `{name, folder?, provider?, model?, permMode?, seedPrompt?, role?,
goal?, backstory?, skills[], mcpServers[], knowledge[], plugins[]}`; an in-panel editor with
folders/favorites/fork is a planned follow-up.

### Auto-enable Remote Control (claude.ai / mobile)

Claude Code's own **Remote Control** lets you drive a *local* session from claude.ai or the
Claude app. Shepherd can turn it on for you (⚙ Settings → *Claude Code Remote Control*; on by
default — distinct from the Kitty `kitty @` control above, which is how Shepherd drives the
window):

- **On spawn** (`remoteControl.onSpawn`) — new Shepherd-spawned sessions launch with the
  documented `--remote-control` flag, so they register Remote Control with no extra step. This
  applies only to **local, native-Anthropic** sessions: Remote Control needs a claude.ai login
  and rejects gateway/SSH providers, so the flag is skipped for those.
- **On startup** (`remoteControl.sweepOnStartup`) — when Shepherd starts, it types `/rc` into
  already-running idle/finished local sessions, so after a computer restart Remote Control is
  re-armed across the fleet (it skips sessions mid-turn or waiting on a prompt; `/rc` is harmless
  to repeat).
- **Sessions you start yourself in a terminal** aren't Shepherd-spawned, so to auto-register them
  run `/config` inside Claude Code once and set **Enable Remote Control for all sessions** — there
  is no settings.json key documented for that toggle, so Shepherd can't set it for you.

> **⚠ Security — this is on by default.** A session with Remote Control can be driven from your
> claude.ai account, so anyone with access to that account (or the Claude mobile app) can type
> into a **local** shell session. That widens the trust boundary from "whoever is at this machine"
> to "whoever can reach my claude.ai." Turn `remoteControl.onSpawn` / `sweepOnStartup` off (⚙
> Settings) if that's broader than you want.

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
  context window, with the **numeric `% shown on the bar`**. Tells you which session to `/compact`.
  The window is **model-aware** (Opus 4.x / Sonnet 4.6 = 1M on Claude Code; others 200k), with a
  per-provider `contextLimit` override and a self-healing guard so a session never reads a false
  100%. To **match Claude Code's own "% until auto-compact"** (which measures against the window
  minus an output reserve, so it reads higher than raw tokens/window), the bar divides by
  `window × context.autoCompactFraction` (default `0.92` — hand-tunable in `cc-config.json`; the
  exact threshold is undocumented, so this is a close approximation). The color steps through **7
  bands** — calm below 50%, a new color every 10% (50/60/70/80/90), and a distinct **critical**
  band for the last 5% (95–100%). Computed on the 60s usage pass (and live on the 1s loop for
  active sessions), so it shows on **every** tile — including idle/finished ones. **Local only,
  zero tokens, zero network.**
- **Fleet total (footer under the grid)** — cumulative tokens across active sessions (headline
  **excludes cache reads** — input + output + cache-creation — since cache reads dominate the gross
  count but aren't how the plan is metered; gross is on hover). Per-model breakdown in the detail
  panel. Recomputed on a **60s timer** (incremental reads — only new bytes) + an **Update now** button.
  **Local only, zero tokens.** The footer also shows an **`~$X est.`** API-equivalent dollar figure
  from a per-model price table (`core.PRICING`; Opus 4.x $5/$25, Sonnet 4.6 $3/$15, Haiku 4.5 $1/$5 per
  Mtok, cache-aware) — an estimate (your subscription is flat-rate), hand-tunable via `pricing.<family>`;
  gateway/local models have unknown pricing and are excluded.
- **Plan window bars (footer)** — your real **session (5h)** and **weekly** utilization %, matching
  `claude.ai/settings/usage` and Claude Code's `/usage`, with reset times. Below them, a
  **per-model weekly line** for any model the endpoint meters separately — a **`Weekly · Sonnet`**
  line, and a **`Weekly · Fable`** (Fable 5) line drawn from the structured `limits[]` surface.
  Each per-model line appears **only when that model is actually being metered** (active, or with
  nonzero weekly usage); a model you don't use — or that isn't provisioned — draws **no row**, so
  the footer never shows an empty `0%` line. (Fable 5 local per-session tokens/cost already roll up
  in the per-model breakdown and the `~$` estimate via `core.PRICING.fable`.)

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
- **Task templates (parameterized + versioned)** — "Tpl ▾" next to Queue saves the
  current input as a named template and inserts saved ones back into the input (never
  auto-sends). Stored in `~/.claude/cc-templates.json`.
  - **Variables** — a template body can carry `{{name}}` (required) and `{{name?}}`
    (optional) placeholders. Picking one opens an inline fill-in form (required vars gate
    Insert), then it's rendered before it lands in the input. Built-in vars fill
    automatically: `{{date}}`/`{{today}}`, `{{now}}`, and `{{prev_output}}` (the selected
    session's latest output).
  - **Render-before-spawn** — the New-Session modal has a **Templates** picker that seeds
    the Initial-task field; any `{{vars}}` are filled in (required vars gate "Use") and
    rendered so the spawn task is fully resolved before launch.
  - **Render-before-feed** — queued tasks are rendered just before they're typed in
    (manual / autofeed / router): `{{prev_output}}` (the turn that just finished) and the
    date built-ins resolve; user `{{vars}}` that can't be auto-filled are left as-is, and a
    task with no `{{ }}` is fed unchanged.
  - **Versioning** — re-saving a template snapshots the previous body and bumps its
    version (a `v2` chip marks edited templates); an identical save is a no-op.
  - **Import a definitions folder** — "⤓ Import from prompts folder…" pulls `*.prompt` /
    `*.md` files (a leading `--- name: … ---` front-matter block + the body) from a local
    directory (`templates.sourceDir`, default `~/.claude/cc-prompts`) into the store.
    Strictly local-disk — no network. Structured fields (`description`/`expected_output`)
    and the version history are hand-editable in `cc-templates.json` for now (a richer
    editor is the deferred follow-up).
- **Project routing (4c-E)** — with `queue.routing.enabled` on AND a project armed via
  the detail panel's **route** toggle, the project's queue feeds **whichever of its
  sessions is free** (just finished a turn), not only the one that emptied its own
  backlog — parallel sessions in one folder drain a shared backlog. One feed per project
  per second, delivery-gated, ledgered as `by:"router"`; `starveMinutes` flags a project
  whose tasks wait with no free session (⌛). Off by default at both levels.
- **Declarative routing (L4)** — built on the router, all driven by queue-line syntax (the
  prefix is stripped before the task is typed, so the session never sees it):
  - **`@role:` conditional routing** — a task prefixed `@review: …` routes only to a free
    session whose **group** is `review` (sessions are grouped via the tile's 🏷 tag).
    Unlabeled tasks route to anyone free, as before.
  - **`seq` (process mode)** — the detail panel's **seq** toggle (next to **route**) runs a
    project's queue **one routed task at a time** (the next starts only after the current
    finishes); off = distribute across free sessions in parallel.
  - **`@all:` / `@any:` join barriers** — a task prefixed `@all: …` waits until **every**
    session in the project has finished before it routes (`@any:` waits for one). Composes
    with a role: `@all: @review: ship`.
  - **Per-task timing** — each routed/queued task is timed from feed to completion; the 📋
    Shift report shows tasks completed with average + total duration (ledger must be on).
  - Deferred (needs a design call first): a visual routing topology view, role-addressed
    delegation/handoff, and idle/auto-spawn routing targets.

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
  Emptying `gate.tools` (to `""` or `[]`) does **not** mean "gate nothing" — it restores
  the default 5 (and logs a warning), because a blank value can't be told apart from
  unset. To gate nothing fleet-wide, disable the gate (`cc-gate.enabled`); to gate
  nothing for one session, use the per-session **None** sentinel.
- **policies.approveRepeats** — if you already approved the *exact* command in a
  session, auto-approve it next time.
- **policies.autopilot** — the **Autopilot** button time-boxes a session to
  auto-approve *all* its prompts (badge `🛫 autopilot`), expiring after `minutes`.
- **policies.patterns** — gate honors `autoDeny` (wins) and `autoAllow` globs,
  written like `"Bash(npm test*)"` or `"Read"`.

The gate's auto-decisions apply only to the gated tools (`gate.tools`, editable in
Settings) and are logged to the Hammerspoon Console / hook stderr whenever they
fire. Auto-deny always beats auto-allow.

### Named policy bundles (per-session guardrails)

`policies.patterns` is one fleet-wide allow/deny list. **Bundles** make those rules reusable and
per-session: define named sets under `policies.bundles`, then attach one to a session — via the
detail-panel **Policy** dropdown, or fleet-wide with `policies.attachments` (matched by
project / group / provider / session key, each a glob):

```json
"policies": {
  "patterns": { "enabled": false, "autoAllow": [], "autoDeny": [] },
  "bundles": {
    "read-only":  { "autoDeny": ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"] },
    "no-network": { "autoDeny": ["Bash(curl*)", "Bash(wget*)", "WebFetch"] }
  },
  "attachments": [ { "match": { "project": "secure-*" }, "bundle": "read-only" } ]
}
```

When a bundle is attached, its rules apply **even if `patterns.enabled` is false** (attaching is the
opt-in) — the bundle's lists union with the fleet patterns, or *replace* them if the bundle sets
`"disableGlobal": true`. The panel resolves each session (precedence: per-session **Policy**
dropdown > attachment > fleet), writes the result to `~/.claude/cc-policy/<key>`, and the gate reads
it; removing an attachment tears its enforcement down within a tick. Starter bundles to copy:
**read-only**, **no-bash**, **no-network**. (An in-panel bundle/attachment editor is a planned
follow-up; today they're config.)

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
- **autoContinue** — **automatic** API-error recovery (a sibling to auto-respawn, but it
  resumes the *same* session instead of relaunching). When a tile shows the magenta `Error`
  state, after `autoContinue.delaySeconds` (default 60) Shepherd types `continue`, capped by
  `autoContinue.maxAttempts` **per launch folder** (default 3, fires spaced ~delay apart; the
  budget resets on a clean turn completion, so a dead connection can't loop). Off by default;
  emits an `auto_continue` ledger event.
- **remoteControl** — auto-enable **Claude Code's Remote Control** (drive a local session from
  claude.ai / mobile). `onSpawn` adds the `--remote-control` launch flag to new spawns (local
  native-Anthropic only); `sweepOnStartup` types `/rc` into already-running local sessions on
  startup. Both on by default. See "Auto-enable Remote Control" above. (Distinct from
  `spawn.kittyRemote`, which is the Kitty `kitty @` control Shepherd uses to drive windows.)
- **context.autoCompactFraction** — the per-tile context bar's denominator factor (default
  0.92) so it matches Claude Code's "% until auto-compact"; see *Token usage* above. Hand-edit
  in `cc-config.json` (preserved across Settings saves).
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
  activity, active sessions, and denial rate. With `insights.hostStats` on, a **Host** strip
  (CPU / memory / disk / uptime / load) and a **fleet idle-since** line sit at the top.
  Always available; zeros until the ledger is on.

More ledger-backed views (all read-only, local, zero model tokens):

- **🔔 Notification history** — "what fired while you were away": escalations, stall
  warnings, auto-respawns, and every **non-human** gate decision, in an **Alerts** tab of
  the audit overlay. The header bell shows an unseen count; opening it marks everything
  seen and highlights what's new since you last looked. (If you've set
  `ledger.captureTypes`, include `escalation` and `hung`.)
- **📋 Shift report** — a one-click narrative of **what the fleet did over a window** (a
  **📋 Shift** tab in the audit overlay, also in the ☰ drawer). Pick **Since opened** (what
  ran while you were away since you launched Shepherd), **Last 8h**, or **Last 24h**: it
  rolls up sessions active, prompts, approvals (allow/deny and who decided), auto-actions
  (respawns / continues / drained / routed feeds), escalations and stalls, time you were the
  bottleneck, and a per-project breakdown — then **Copy** the report to the clipboard. It
  reports *operations*, not outcomes: there's deliberately no "what shipped" line, because a
  prompt is an instruction and Shepherd has no git/CI ground truth to claim a result. The
  **📋 Shift** tab and drawer entry only appear while the ledger is enabled (it's pure ledger
  aggregation — nothing to report otherwise), and they show/hide live with the setting.
- **🗂 Session history browser** — a **History** tab in the audit overlay lists every session the
  ledger has seen (derived on the fly — no parallel store), each with its turns / tool calls /
  events and last activity. Filter by name or folder, sort **Recent / Oldest / Most active**, and
  narrow to **this workspace** or **pinned only**; ★-pin the projects you care about (saved by
  stable project id). Multi-select rows and **Delete selected** purges those sessions' recorded
  history through the same confirmed, scoped purge the Purge button uses (it never deletes Claude
  Code's own transcripts). Appears only while the ledger is enabled, like the Shift tab.
- **Storage readout** — ⚙ Settings → **Measure storage** shows how much disk Shepherd's own state
  uses (audit ledger / task queues / session status / `cc-*.json` state files — never Claude Code's
  transcripts). Trim old ledger days with the retention setting; delete a session's recorded history
  from the 🗂 History tab.
- **Per-session gate decision log** — the detail panel shows the selected session's last
  few gate decisions, grouped with counts and provenance ("⛔ deny Bash ×4 (autoDeny:
  Bash(rm*)) · 2m ago"), so what the gate has been doing to a session is visible right
  where you act on it. `decisions.limit` / `decisions.hours` tune it.
- **♻️ Session lineage** — auto-respawns and `/clear`s mint a new session id for the same
  project, and that churn is normally invisible. The detail panel now shows a one-liner
  ("3rd session today · 2 auto-respawns · 1 clear") for the project since midnight, and a
  tile gets a small **♻️N** badge once the churn adds up — so a crash-loop survivor is
  obvious at a glance. Pure read of the ledger; nothing new is stored.
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

## MCPs & Skills viewer

The **🔌 MCPs & Skills** item in the ☰ drawer opens a read-only catalog of what's actually
installed for Claude Code — distinct from the agent-profile registry (`cc-mcp.json`), which is
just the servers you attach to spawns.

- **MCP servers** — read instantly from `~/.claude.json` (user-scope `mcpServers` + every
  project's `mcpServers`, deduped; a server defined in both shows `user+project`). Each row shows
  scope, transport, and the command/url — **env values are never surfaced** (only the var names
  Claude itself prints). A **Re-check** button (footer) runs `claude mcp list` via your login shell
  — only on demand, never on a timer — to add the claude.ai **connectors** (Drive/Calendar/Gmail)
  and live **connected / failed / needs-auth** health, merged onto the config list and cached for
  the next open.
- **Skills** — your `~/.claude/skills` (SKILL.md) and `~/.claude/commands` (`/slash` files), plus
  a pinned list of the CLI's **built-in** skills (which have no file to enumerate), each with its
  `/command` and description.
- **CLI tools** — the external binaries Shepherd shells out to, each with an **installed / missing**
  chip and its resolved path. Detected via the same PATH/Homebrew lookup the app uses to actually
  run them, so the status reflects the real binary it would pick: `jq` (the one **required** dep),
  `ripgrep` and `fd` (the search/folder-scan accelerators — when missing, they show the POSIX tool
  they fall back to: `grep` / `find`), `rsync` (the SSH status bridge), and `ffmpeg` + `whisper-cli`
  (the optional Stream Deck voice key).

Read-only — Shepherd never edits your MCP config, skills, or tools; it just shows the inventory.

## Worklist (My List)

A checklist built into the panel — no code hooks, just add → work → check. The
**📋 My List** button on the right of the FLEET row swaps the session tiles for the worklist (click
again to go back; the fleet bulk buttons still appear only when there's something to act on).

- **Scopes** — a **MASTER** rollup, a **Generic** (global) list, plus one button per
  project that **has a live session _or_ still owns a saved list**, labeled with that project's
  relabel name. Lists are stored in `~/.claude/cc-worklist.json` keyed by the **stable
  launch-folder identity** (same as relabels/groups). A project's tab and its items **persist
  whether or not a window is open** — an idle or closed project keeps its button (labeled from its
  saved relabel / auto-title) until you clear the list, so its to-dos never disappear on you.
- **The item modal** — **＋ Add an item…** (or clicking any row) opens one editor with:
  - **Subject** — the one line the list shows. Enter saves.
  - **Details** — free-form notes/context, as long as you like.
  - **Checklist** — sub-steps with their own checkboxes (**＋ Step**, Enter for the next one,
    **✕** to drop one). Ticking a step **saves immediately**, so mid-work progress can't be lost;
    the list row shows a `2/5` chip that turns green when every step is done.
  - **Expected date** — a new item defaults to **today**; the native picker plus **◀ ▶** nudge
    it a day at a time, **↻** resets to today, and **Clear** drops the date so the item can be
    saved without one. With no date set, the first ◀/▶ lands on today.

  Esc or a backdrop click discards; **Delete** (edit mode only) removes the item after a confirm.
- **The list** — each row shows subject + date chip (dim normally, amber for **Today**/**Tomorrow**,
  red once **overdue**), a 📝 when it has details, and its checklist progress. Checking a row moves
  it to a collapsed **Done** area (ordered by due date), where each row shows **both** its expected
  date and a **✓ completion date**; the **✕** deletes it; **Clear** empties Done for that scope.
- **MASTER** — a read-only, date-priority rollup of every **open** item across Generic *and* every
  project, grouped **Overdue / Today / Next 7 days / Later / No date** and tagged with the list it
  came from. Tick a row to mark it done in its own list, or click it to jump to that tab with the
  item open. A collapsed **Recently completed** drawer reveals everything finished in the **last 7
  days** across all lists, newest first, each stamped with its ✓ completion date. No adding from
  MASTER — that's what Generic and the project tabs are for.

## Install (about 5 minutes)

1. **Install Hammerspoon** (free) and `jq` (required for the rich tiles):
   ```
   brew install --cask hammerspoon
   brew install jq
   ```
   Launch Hammerspoon once and grant it Accessibility permission when asked
   (System Settings > Privacy & Security > Accessibility). It needs that to focus
   windows and send keystrokes.

   **Optional accelerators** (`jq` is the only hard dependency — everything else degrades
   gracefully): [ripgrep](https://github.com/BurntSushi/ripgrep) speeds up fleet-wide search
   and [fd](https://github.com/sharkdp/fd) makes the New-session folder scan faster and
   gitignore-aware. Without them, search falls back to `grep` and folder scan to `find`.
   ```
   brew install ripgrep fd
   ```
   `make setup` checks for these at the end and offers to install any that are missing; run
   **`make doctor`** any time to see which engine each path is using (and confirm it in the
   Hammerspoon console — a fleet search logs `[cc-search] engine=rg …`, a folder scan
   `[cc-spawn] folder scan: fd …`).

2. **Run the installer** (idempotent — safe to re-run):
   ```
   make setup
   ```
   This copies the hook scripts + logic into `~/.claude` and `~/.hammerspoon`,
   **merges** the hooks into `~/.claude/settings.json` (backing it up first and
   preserving any hooks you already have), ensures the `dofile(...)` line in
   `~/.hammerspoon/init.lua`, builds **Shepherd.app** (a Dock launcher — see below), and
   runs the **tooling check** (jq / ripgrep / fd).

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

**Global action row** (the four **bottom-left** keys, on a deck with room to spare — e.g.
the XL). These are reserved for fleet actions instead of sessions; sessions fill the rest:

- **🎯 JUMP** — first tap jumps to the session that most needs you (approval › error ›
  stalled); each further tap cycles to the next in order, through all of them. After a few
  seconds idle a fresh tap restarts at the neediest (`SD_JUMP_RESET`).
- **✓ APPROVE** — approve the front-most pending approval, hands-free via the gate.
- **＋ SPAWN** — reveal the panel and open the New-session folder browser.
- **🎙 VOICE** — local push-to-talk dictation. Tap to start recording (the key turns red
  **REC**), talk, tap again → **whisper-cli transcribes on-device** and sends the text to the
  **project window you have focused** (auto-submits by default). Needs `brew install
  whisper-cpp ffmpeg`, a model at `voice.model` (e.g. `ggml-base.en.bin`), and Microphone
  permission for Hammerspoon. Tune under `voice` in cc-config.json (`model` / `micDevice` /
  `autoSend` / `maxSeconds` — a hard recording cap, default 120s, so a missed second-tap can't
  record forever). Set `STREAMDECK_ACTIONS = false` to give those four keys back to sessions.

The **bottom-right** corner key is **☕ CAFFEINE** — toggles keep-awake (the same `pmset`
keep-awake as the panel's ☕ button, so it asks for your admin password); the key shows amber
**AWAKE** vs dim **SLEEP OK**.

Each **session key** also draws a thin **context-fill bar** along its bottom edge — how full
that session's context window is (green < 60% < amber < 85% < red), so you can see at a glance
which sessions are getting close to a compact.

Tunables near the top of [claude-dashboard.lua](claude-dashboard.lua):
`STREAMDECK_ENABLED`, `STREAMDECK_ACTIONS`, `SD_LONG_PRESS`, `SD_LONG_PRESS_STOPS`,
`SD_JUMP_RESET`, `SD_BRIGHTNESS`, `SD_FALLBACK_KEYS`. If you'd rather keep your normal Elgato profiles running,
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
- **2,743 core + 762 ui + 368 bash checks (+ a load-and-refresh smoke test), all side-effect-free.**
  Every new feature lands with its tests, and the critical guards are **mutation-checked** — reverting
  the fix has to turn its own test red — so an assertion can't quietly go vacuous. Source-shape "pins"
  (used where a Hammerspoon-only path can't be loaded in the harness) are called out as such.

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

## Review tags (`R1-`/`R2-`/`R3-` in comments & tests)

Many code comments and test names carry tags like `R1-26`, `R2-17`, or `R3-18`.
These reference findings from the multi-agent bug-hunt review sweeps: `R<round>-<id>`
is the `<id>`-th confirmed finding of review **round** `<round>` (round 1, 2, 3, …).
The authoritative "why" for each tag is the code comment next to it — it records the
non-obvious invariant (usually a concurrency or fail-closed rule) the fix protects, so
a later edit doesn't "simplify" the guard back into the bug. To trace one across the
tree: `git log --grep='R2-17'` or `grep -rn 'R2-17' .`.

The 2026-07-02 sweep (see the CHANGELOG) tracks its 30 findings as `#1`–`#30`, with
regression tests named `#<id>-pin`; the same rule applies — the comment beside each
`#<id>` is the authoritative "why", and `grep -rn '#18-pin' tests/` finds its test.
