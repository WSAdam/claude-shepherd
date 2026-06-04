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

**Single-click** a tile to select it (opens the detail panel). **Double-click** a
tile to **jump** straight to its window. **Right-click** a tile for a context menu:

- **Relabel…** — give the tile a custom display name (e.g. "auth refactor" instead
  of the folder name). Display-only — jumps still target the real window — and
  **ephemeral**: relabels are in-memory and clear on a Hammerspoon reload.
- **Close instance** — confirm, then best-effort close the editor window (⌘⇧W) and
  remove the tile.

The detail panel has:

- **Jump** — focus that session's VS Code/Cursor window (switches Spaces if needed).
- **Approve / Deny** — answer a pending permission prompt.
- **Stop** — interrupt the current turn.
- **Autopilot** — time-box a session to auto-approve all its prompts (needs the gate + config).
- **Clear / Compact** — pop a yes/no confirm, then run `/clear` or `/compact` in the session.
- **Effort** dropdown — set the session's reasoning effort (Low/Medium/High/XHigh) live; sends
  the `/effort <level>` slash command. The detail also shows badges for the detected **editor**,
  current **permission mode**, and **effort**.
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
mouse-only, so clicking **jumps you to it** to pick by hand. Either way you see *what's being asked*
without leaving Shepherd.

### Editor auto-detection
Each session self-reports its host editor. [cc-status.sh](cc-status.sh) reads the env it inherits
from `claude` (`CLAUDE_CODE_ENTRYPOINT`, `__CFBundleIdentifier`, `TERM`/`KITTY_WINDOW_ID`) plus the
hook's `permission_mode`, and records `editor` (`vscode`/`cursor`/`kitty`/`terminal`),
`permission_mode`, and `effort` into the session's status JSON. The panel routes actions per session
on that — **anything not detected as `kitty` uses the VS Code/Cursor path**, so a machine running
both just works. (Kitty *effect routing* — `kitty @` remote control — is on the roadmap; see
[todos.md](todos.md).)

### How control reaches the session — and its limits

Two paths, and it matters which one your sessions use:

1. **Hook approval gate (hands-free, reliable everywhere).** When armed,
   [cc-approve.sh](cc-approve.sh) routes a permission decision to the panel and
   Approve/Deny write a decision file the hook honors — **no window focus, no
   keystrokes.** Works for terminal *and* VS Code-extension sessions. This is the
   recommended approve/deny path. See "The approval gate" below.

2. **Keystroke injection (best-effort).** Jump, Stop, Nudge/Feed, and Clear/Compact
   focus the target window and type into it. This lands reliably when Claude runs
   in a **terminal** (cursor at the prompt), but is **unreliable for the Claude Code
   VS Code extension** (the chat input isn't reliably the focused element) — and
   there's no supported API to inject a prompt into a running session. Needs
   Hammerspoon **Accessibility** permission.

> Keystroke keys (`Return`/`Esc`) and behavior depend on your setup. For reliable
> approve/deny regardless of UI, use the gate. For delivering work, **Queue** stores
> it reliably; feeding/nudge is the fragile part for the extension UI.

## Global hotkeys

Act on the session that needs you without touching the panel (configurable near
the top of [claude-dashboard.lua](claude-dashboard.lua)):

- **⌘⌥A** — approve the front approval (hands-free via the gate when it's waiting).
- **⌘⌥J** — jump to the session that needs you.
- **⌘⌥N** — cycle-jump to the next session.
- **⌘⌥S** — spawn a new session (see below).
- **⌘⌥B** — show/hide the panel (it also minimizes to the Dock, and there's a 🐑
  menu-bar icon to reopen it when closed).

## Spawn new sessions (orchestrator)

Launch a fresh Claude session from the panel — the **+ New** button in the header
or **⌘⌥S**. It asks for a project folder and an initial task, then opens a terminal
running `claude` there; the new session shows up as a tile automatically.

This is **dry-run by default** (`ORCH_DRY_RUN = true`): it logs the exact command
it *would* run to the Hammerspoon Console and launches nothing, so you can confirm
it before enabling. Set `ORCH_DRY_RUN = false` (and `ORCH_TERMINAL` /
`ORCH_DEFAULT_DIR` to taste) to spawn for real.

### Task queue
Each session has a queue (`Queue` button in the detail panel adds the input;
`Feed next` sends the front task; the tile shows `+N queued`). Turn on
`queue.autofeed` in the settings file (below) and Claude Shepherd feeds the next task
automatically each time the session finishes — so a session works through a
backlog unattended.

## Automation & policies (`~/.claude/cc-config.json`)

All automatic behavior is governed by one settings file, and **everything is off
until you turn it on**.

**Easiest: the ⚙ Settings panel.** Click the **gear button next to + New** for a
form with every toggle (arm the gate, queue autofeed/dry-run, escalation, and the
policies). **Save** writes `~/.claude/cc-config.json` (creating it if missing) and
arms/disarms the gate flag — no hand-editing.

To edit by hand instead, copy [cc-config.example.json](cc-config.example.json) to
`~/.claude/cc-config.json` and flip what you want. Both the panel and the gate
read it (the panel live within ~1s; the gate on the next hook fire).

```json
{
  "queue":      { "autofeed": false, "dryRun": false },
  "escalation": { "enabled": false, "minutes": 5, "sound": false, "push": false, "pushTopic": "" },
  "focus":      { "popEditor": false },
  "policies": {
    "approveRepeats": false,
    "autopilot": { "enabled": false, "minutes": 15 },
    "patterns":  { "enabled": false, "autoAllow": [], "autoDeny": [] }
  }
}
```

- **queue.autofeed / dryRun** — auto-feed queued tasks on done (dryRun logs instead).
- **escalation** — when an approval waits longer than `minutes`, nag harder: a
  stronger tile pulse always, plus an optional `sound` and an optional high-priority
  `push` to your ntfy `pushTopic`. Both channels off by default.
- **focus.popEditor** — pop/focus the editor window when a session finishes or needs
  you. Off by default; toggle it from the ⚙ panel ("Pop the editor window…"). The
  Stop/Notification/PermissionRequest hooks call [cc-popup.sh](cc-popup.sh), which only
  opens the window when this is on (the macOS notification + sound stay independent).
- **policies.approveRepeats** — if you already approved the *exact* command in a
  session, auto-approve it next time.
- **policies.autopilot** — the **Autopilot** button time-boxes a session to
  auto-approve *all* its prompts (badge `🛫 autopilot`), expiring after `minutes`.
- **policies.patterns** — gate honors `autoDeny` (wins) and `autoAllow` globs,
  written like `"Bash(npm test*)"` or `"Read"`.

The gate's auto-decisions apply only to the gated tools (`CC_GATE_TOOLS`) and are
logged to the Hammerspoon Console / hook stderr whenever they fire. Auto-deny
always beats auto-allow.

## Install (about 5 minutes)

1. **Install Hammerspoon** (free) and `jq` (required for the rich tiles):
   ```
   brew install --cask hammerspoon
   brew install jq
   ```
   Launch Hammerspoon once and grant it Accessibility permission when asked
   (System Settings > Privacy & Security > Accessibility). It needs that to focus
   windows and send keystrokes.

2. **Install the status scripts:**
   ```
   mkdir -p ~/.claude
   cp cc-lib.sh cc-status.sh cc-approve.sh ~/.claude/
   chmod +x ~/.claude/cc-status.sh ~/.claude/cc-approve.sh
   ```

3. **Add the hooks** to `~/.claude/settings.json`. If that file doesn't exist
   yet, copy `settings-hooks.json` to it. If it already exists, merge the
   `"hooks"` block from `settings-hooks.json` into your existing JSON.

4. **Install the dashboard** (the panel and its logic module — keep them together):
   ```
   cp claude-dashboard.lua cc-core.lua ~/.hammerspoon/
   ```
   Then add this line to `~/.hammerspoon/init.lua` (create the file if needed):
   ```lua
   dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")
   ```
   Click the Hammerspoon menu-bar icon and choose **Reload Config**.

The panel appears top-right. Drag it by its title bar, resize it, and it floats
above other windows and shows on every Space.

## The approval gate (optional, hands-free approve/deny)

By default Claude Shepherd leaves Claude Code's normal permission prompts untouched
and you answer them with keystroke injection. If you'd rather approve/deny from
the panel with **no window switch**, arm the gate:

```
touch ~/.claude/cc-gate.enabled      # arm
rm   ~/.claude/cc-gate.enabled        # disarm
```

When armed, a permission request for a *mutating* tool (Bash, Write, Edit,
MultiEdit, NotebookEdit by default) turns the tile red with `gate (hands-free)`,
and the Approve/Deny buttons answer it directly.

It is built to be safe:

- **Never freezes a session.** The gate only waits while the panel is running
  (it checks the panel's heartbeat). Panel closed → the request falls straight
  through to Claude Code's native prompt.
- **Times out gracefully.** If you don't answer within `CC_GATE_TIMEOUT` seconds
  (default 120), it falls back to the native prompt rather than denying.
- **Reads stay fast.** Only the tools in `CC_GATE_TOOLS` are gated.

Tunables (set in your shell environment / the hook's env):

- `CC_GATE_TOOLS` — space-separated tool names to gate (default the mutating set).
- `CC_GATE_TIMEOUT` — seconds to wait for your decision (default 120).
- `CC_PANEL_MAX_AGE` — max heartbeat age in seconds to consider the panel alive (default 5).

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

- **Pure logic in [cc-core.lua](cc-core.lua)** — status parsing, sorting,
  staleness, action selection, deck layout, transcript snippet, spawn-command
  building, panel-geometry resolution, ephemeral relabels, image data-URL parsing,
  stale-duplicate pruning, `/effort` command building, and AskUserQuestion answer
  keys — has no `hs.*` calls and is unit-tested directly in plain `lua`
  ([tests/core.test.lua](tests/core.test.lua) + [tests/ui.test.lua](tests/ui.test.lua)).
- **All effects go through one `fx` table** (focus, keystrokes, paste, send-keys,
  decision/file writes, Stream Deck, session spawn). Production wires it to
  Hammerspoon; tests pass a **recorder** that captures intent — so a test asserts
  *"would press Return on window X"* or *"would spawn in /path"* without doing it.
- **The shell scripts** are driven against a throwaway `CC_STATUS_DIR`:
  [tests/status.test.sh](tests/status.test.sh) (status writer),
  [tests/editor.test.sh](tests/editor.test.sh) (editor/mode/effort detection),
  [tests/ask.test.sh](tests/ask.test.sh) (AskUserQuestion capture),
  [tests/config.test.sh](tests/config.test.sh), [tests/gate.test.sh](tests/gate.test.sh).
- **~188 checks, all side-effect-free.** Every new feature lands with its tests.

Spawning is additionally guarded by `ORCH_DRY_RUN` (default on), so even the live
app logs-but-doesn't-launch until you opt in.

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
- **Relabel / Close** use in-panel UI (an inline rename bar / confirm bar), not
  native dialogs, specifically so they don't activate Hammerspoon and yank its
  console forward. (The `+ New` spawn prompt still uses a native dialog; it's rare
  and off by default.)
- **Known limit:** click-to-focus matches by window title, so two sessions in the
  *same* window remain ambiguous to jump to (their tiles are still distinct).
