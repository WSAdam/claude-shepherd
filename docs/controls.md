# Controls

[← README](../README.md) · [Fleet](fleet.md) · [Approvals and policies](approvals-and-policies.md)

How to act on sessions from the panel, the keyboard and a Stream Deck, how to start new sessions,
and the limits of acting on a window you're not looking at.

## Clicks

- **Single-click** a tile to select it (opens the detail panel).
- **Double-click** a tile to **jump** to its window; on a project card, to the instance that needs
  you most. Both are decided the moment the button goes down, so they land even while a busy fleet
  re-renders the grid under the pointer.
- **Right-click** a tile for the context menu (below).

The **header** has **New** (the new-session dialog), **☕** (keep awake), **🔒** (lock the screen),
the **☰** menu (filter, Find in fleet, Fleet insights, Audit ledger, Routines, Templates, Agents,
MCPs & Skills, Policy bundles, Automation rules, Cost & tokens, Diagnostics, Features list, Shift
report, Hidden sessions, Notifications), **⚙** Settings, and the layout switcher. The small
**⌨** button in the bottom-right corner shows every shortcut, read from the live bindings.

## The context menu

In order (a remote SSH-bridge tile offers only Relabel and Set group):

- **Jump to window**: focus that session's editor window (the same as a double-click).
- **Instances…**: the project's Instances view (same as the card's corner button; shown while
  project cards are on).
- **New worktree tab…**: start a new unit in this repo (repo cards in VS Code or Cursor only;
  [Merging and batches](merging-and-batches.md#new-worktree-tab)).
- **Relabel…**: give the tile a custom display name. It is display-only (jumps still target the real
  window) and **persistent**: keyed by the session's stable project identity (its launch folder, in
  `~/.claude/cc-labels.json`), so it survives the agent changing directories, a Hammerspoon reload,
  a new instance, and close/reopen in the same folder. On a repo card it renames the whole repo
  (keyed by the main checkout). Relabel back to the folder name (or blank) to clear it.
- **Set group…**: tag the session into a cohort ([Fleet](fleet.md#search-groups-and-bulk-actions)).
- **Export session…**: archive the session (its transcript `.jsonl` plus a `meta.json` with label,
  provider/model, lineage and activity counts) into `~/.claude/cc-exports/` and reveal it in Finder.
- **⚖ A/B fork-to-compare…**: run the same task as 2+ variants in isolated git worktrees of this
  project, then compare them and keep the winner ([Automation](automation.md#ab-compare)).
- **Talk mode (discussion only)**: checked while on. The session can read and talk but not change
  anything: edits and commands that change things are denied, and the tile wears a **TALK** badge
  ([Approvals and policies](approvals-and-policies.md#talk-mode)). Click again to turn it off.
- **Clear conversation / Compact**: confirm, then run `/clear` or `/compact` in the session.
- **Close instance**: confirm, then close the session and remove the tile. In a window shared with
  other sessions the tab bridge closes just its Claude tab (a batch unit's by its tag, any other by
  its name). A Kitty session is closed with `kitty @ close`. Otherwise Shepherd closes its editor
  window (⌘⇧W), found by **title**, so for two sessions sharing a name prefer **Forget tile** or
  **Hide tile**. The project's saved label is kept.
- **Hide tile (keep session running)**: takes a session **off the grid** without touching it. It
  keeps running and Shepherd keeps managing it: gate decisions, auto-feed, escalation, policies and
  auto-respawn all still apply. Only the drawing stops (panel and Stream Deck). The mark belongs to
  that one session, so reopening the project gives a fresh, visible tile. Restore any time from
  **☰ → 🙈 Hidden sessions**, which shows each hidden session's live status.
- **Forget tile (stale orphan only)**: drops the tile's status file with **no window keystroke**, so
  it can't close a live session that shares the name. Use it for a session that ended without a
  clean SessionEnd. On a **running** session the tile comes back within seconds, because the hooks
  rewrite it; use **Hide** for that. A `/clear` (or restart) leaves a duplicate tile behind; the
  panel prunes it once the fresh session is live in the same window.
- **Drain (finish turn, then close)**: shown when `drain.enabled`. Waits for the in-flight turn to
  finish, then closes (at once if already idle or done).
- **Respawn from cwd**: shown when `respawn.enabled`. Relaunches a dead or stale session from its
  last working directory with the matched provider and editor.

## The detail panel

- **Jump**: focus that session's window (switching Spaces if needed), then ask the tab bridge to
  bring **the session's own tab** to the front when one of its names (custom title, AI title, first
  or last prompt) picks out exactly one Claude tab there. Otherwise you land on the window.
- **Approve / Deny**: answer a pending permission. With the gate waiting, both are decision files
  and a **Why?** box sends your reason with a Deny
  ([Approvals and policies](approvals-and-policies.md#deny-with-a-reason)).
- **Stop**: interrupt the current turn.
- **Continue**: on an errored tile the Approve button becomes **Continue**, which types `continue`
  and Enter to resume the aborted turn. Auto-respawn is held off so you resume the *same* session.
  **Auto-Continue** does this for you ([Automation](automation.md#auto-respawn-and-auto-continue)).
- **Autopilot**: time-box a session to auto-approve all its gated prompts (needs the gate and
  `policies.autopilot.enabled`).
- **Talk mode**: the same toggle as the context menu's; it reads **Talk mode: ON** while it's on
  ([Approvals and policies](approvals-and-policies.md#talk-mode)).
- **Clear / Compact**: confirm, then run `/clear` or `/compact` in the session.
- **Score**: rate the session 0–100 from the audit ledger
  ([Usage and cost](usage-and-cost.md#run-score)).
- **📜 Timeline**: the audit ledger scoped to this session.
- **⤓ Export**: the same export as the context menu's **Export session…**.
- **Improve**: pull this repo's un-applied improvement insights from an AI Monsters leaderboard and
  send them to the session as a **review-first** prompt (assess and suggest, not wholesale edits),
  so you approve a plan before any changes. It shows "No improvements found" when the latest push's
  insights are already claimed, and needs `LB_URL` / `GRADE_PREVIEW_TOKEN` in your shell.
- **Nudge box**: a multi-line input. **Enter** sends, **Shift+Enter** adds a newline, so a pasted
  list arrives intact. **Paste an image** and it's attached as a chip; **Send** delivers text and
  image through the clipboard (one ⌘V). **Queue** saves the text for later instead
  ([Automation → Task queue](automation.md#task-queue)); **Tpl ▾** inserts a saved template.

**Model controls** (off by default; ⚙ Settings → Appearance → **Model controls**) add a row of six:

- **Effort**: set the session's reasoning effort (Low / Medium / High / XHigh) live with `/effort`.
- **Mode**: switch the permission mode (Default / Accept edits / Plan) with Shift+Tab; reliable on
  Kitty, best-effort in the VS Code extension.
- **Model**: shows the session's **current** model (read live from the transcript, so it follows
  an in-session `/model`) and switches it within the provider (`/model <id>`). The list comes from
  the `providers[]` you define; with none it shows just the current model. Changing the provider or
  base URL needs a new session.
- **Gate**: per-session tool gating
  ([Approvals and policies](approvals-and-policies.md#which-tools-are-gated)).
- **Policy**: attach a policy bundle to this session.
- **Auto-model**: per-session model auto-routing ([Automation](automation.md#model-auto-routing)).

The detail panel also shows badges for the detected **editor**, **permission mode** and
**effort**.

⚙ Settings → Appearance → **Hide the detail panel's controls** (off by default) takes the whole
bottom of the panel off screen: the button rows, the nudge box and the template menu. What it
leaves is what you can't reach any other way: a session **waiting on the gate** brings back
Approve, Deny, the reason box and Stop (and hides them again once you answer), and an **errored**
session brings back the Continue button. A held question and the plan / TODO box stay as they are.
The nudge box is hidden, not disabled, so ⌘V still pastes into it.

## How control reaches a session, and its limits

Two paths, and it matters which one your sessions use:

1. **Decision files (hands-free, reliable everywhere).** Gate approvals, held-question answers,
   merge answers and batch approvals are files the waiting hook or script reads. **No window focus,
   no keystrokes**, for terminal *and* VS Code sessions.
2. **Keystrokes.** Stop, Nudge, Feed, Clear / Compact, Continue, mode and model switches. On
   **Kitty** these run headlessly through `kitty @` remote control (no window focus). On **VS Code /
   Cursor / Terminal** Shepherd focuses the target window and types into it: reliable in a
   terminal, **best-effort in the VS Code extension** (its chat input isn't reliably the focused
   element, and there's no supported API to type into a running session). This needs Hammerspoon's
   **Accessibility** permission.

For reliable approve and deny, use the gate or Kitty. For handing over work, **Queue** stores it
reliably; the typing into the VS Code chat input is the fragile part.

### Editor auto-detection

Each session reports its host editor. [cc-status.sh](../cc-status.sh) reads the environment it
inherits from `claude` (`CLAUDE_CODE_ENTRYPOINT`, `__CFBundleIdentifier`, `TERM` / `KITTY_WINDOW_ID`)
plus the hook's `permission_mode`, and records `editor` (`vscode` / `cursor` / `kitty` /
`terminal`), `permission_mode` and `effort` in the session's status file. **Kitty sessions** get
their effects through `kitty @` remote control; **everything else** uses the VS Code / Cursor path,
so a machine running both just works. Cursor and VS Code Insiders are in the `EDITOR_BUNDLES` list
in [claude-dashboard.lua](../claude-dashboard.lua); add or reorder editors there.

### Sessions that share a window

When several Claude tabs run in one VS Code window, keys land in whichever tab is in front. So a
session whose window hosts other sessions gets **no keystroke action at all**: no nudge, queue feed,
routed task, auto-continue, `/clear`, `/compact`, `/rc`, Rewind, model / effort / mode switch or key
approval. The detail panel greys those controls and says how many sessions share the window; each
refusal is logged and raises a toast (at most once a minute per session).

Everything that isn't a keystroke still works: **Jump**, gate approvals, held questions,
ready-to-merge answers, Queue add, Gate and Policy. A queued task simply waits, and a message in
the [session mailbox](automation.md#session-mailbox) arrives at the session's next turn end or
start, with **1 message waiting** on its card until then. **Close** goes
through the tab bridge, which closes just that session's Claude tab: a batch unit's by the tag the
bridge gave it, any other when exactly one Claude tab in the window carries the session's name. A
fresh tab still named "Claude Code", two tabs with the same name, or a window without the bridge
keep Close refused, with the reason. Kitty sessions are
unaffected. `keystrokes.refuseSharedWindow: false` in `~/.claude/cc-config.json` turns the guard off.

### Sessions with no tab

Starting a new conversation in a Claude tab can leave the old session's `claude` process running
with no tab of its own. Where the tab bridge runs and a window has **more Claude sessions than
Claude tabs**, Shepherd compares every name each session's tab could show with the window's tabs.
When the sessions that match no tab are exactly that surplus for 20 seconds, they're marked
**⊘ no tab — a leftover process, or the Claude sidebar** on the card, in Instances and in the detail
panel, with **End session**. End asks first, checks with `ps` that the pid is still a `claude`
process of that window, stops it and drops the card; the chat stays in its transcript.

Shepherd also **ends a leftover by itself** once it has been tab-less and idle for
`tabless.autoEndMinutes` (default 10; 0 = off), with the same `ps` check, never for a session that
is waiting on you or running agents, and says so in a toast. A leftover that reads **Working** is
ended only on proof that its turn is over: the newest record in its transcript is Claude Code's own
*Request interrupted by user* marker, and that marker, the status file and the missing tab are all
older than `tabless.autoEndMinutes`. Being quiet is never enough, because hooks write status only
when something happens. A tab-less session gone quiet at Working also stops leading its card.

## Spawn new sessions

Click **New** to open the **New session** dialog. (**⌘⌥S** is the quick way: it asks for a folder
and an initial task in two native prompts and spawns in `spawn.editor`. Submitting the dialog
without a folder falls back to the same prompts.)

- **Open existing / Start new project**: open a folder, or create a new one and start in it. A new
  project gets extra settle time, opens VS Code with `--disable-workspace-trust`, and **pastes** the
  initial task, so the prompt reliably lands.
- **Presets**: ▶ chips that spawn a saved folder + editor + mode + provider bundle in one click.
  **Save as preset** captures the current form (`~/.claude/cc-presets.json`; ✕ deletes). Picking a
  known folder also recalls the editor, mode and provider you last used there.
- **Agents**: ✦ chips that spawn from a saved agent profile
  ([Providers and integrations](providers-and-integrations.md#agent-profiles)).
- **Templates**: seed the initial task from a saved template, with its variables filled in first.
- **Fuzzy folder search**: type a fragment of a project name. Your project roots
  (`spawn.searchRoots`, default `~/Programming`) are indexed once per open, with
  [fd](https://github.com/sharkdp/fd) when installed (gitignore-aware) or `find` otherwise.
- **Folder browser** and **Recent**: drill into folders, or pick one of the folders you've launched
  in (`~/.claude/cc-recent-dirs.json`).
- **Open in**: Terminal / Kitty / VS Code / Cursor (defaults to `spawn.editor`). Kitty and Terminal
  launch reliably. VS Code and Cursor open the window, then drive Claude Code best-effort: by default
  they open the **Claude Code extension panel** and type the initial task into it
  (`spawn.vscodeFlavor: "terminal"` types a `claude` command into an integrated terminal instead).
  SSH spawns, gateway providers, a non-Default permission mode and agent-profile spawns always use
  the terminal flavor, since the extension can't take those launch flags. If the project's window already
  has a live Claude tab, the spawn opens a **new Claude tab** with the task typed in; press Return to
  send it.
- **Permission mode**: Default / Plan / Accept edits / Automate (bypass), passed as
  `claude --permission-mode <m>` (Automate is `bypassPermissions`).
- **Provider**: the model or backend for this session
  ([Providers and integrations](providers-and-integrations.md#providers-and-models)).
- **Initial task** (optional).

A spawned VS Code or Cursor window takes the frame of the editor window you already have open,
instead of a full-width frame under a right-docked panel (`spawn.matchWindowSize: false` turns this
off). It never moves a window you already placed.

**Spawning is dry-run until you opt in.** The installer's default settings opt in. A hand-made
config without `spawn.live` logs the exact command to `~/.claude/cc-shepherd.log` without launching;
flip **"Actually launch"** in ⚙ Settings → Spawn. The new session shows up as a tile automatically.

## Global hotkeys

Act on the session that needs you without touching the panel:

- **⌘⌥A**: approve the front approval (hands-free through the gate when it's waiting).
- **⌘⌥J**: **jump to the session that most needs you, from any app**: a pending approval first, then
  a session frozen on an API error, then one the watchdog flagged as stalled. It falls back to the
  front session when nothing is wedged.
- **⌘⌥N**: cycle-jump to the next session.
- **⌘⌥S**: spawn a new session (two quick prompts: folder, then initial task).
- **⌘⌥B**: show or hide the panel. It restores the panel even after a Dock-minimize. The 🐑
  menu-bar icon → **Show panel** always works too.

Remap any of them in `~/.claude/cc-config.json` under `hotkeys`, each as
`{ "mods": [...], "key": "x" }`. Valid modifiers are `cmd`/`command`, `ctrl`/`control`,
`alt`/`option`, `shift` and `fn`. macOS can't bind a bare key globally **except function keys**
(`f1`–`f20`, with `"mods": []`). Single-modifier combos collide (`ctrl` alone breaks terminal
readline, `alt` alone hits app shortcuts), so ⌘⌥ or ⌃⌥ are the low-conflict picks. A malformed
entry keeps its default. Reload Hammerspoon (🐑 → **Reload config**) after editing.

## Stream Deck

Shepherd can mirror the panel onto a physical Elgato Stream Deck and act on sessions from its keys,
with no extra software: Hammerspoon drives the deck directly and reuses the panel's actions. It
adapts to any size (Mini 6 / Standard 15 / XL 32) by asking the device for its key count.

1. **Quit the official Elgato Stream Deck app.** Only one program can own the device at a time.
2. Plug in the Stream Deck.

Hammerspoon detects it and paints one session per key, coloured by the session's raw status (gray
idle / amber working / green ready / magenta ERROR / **red blinking = approval**), with sessions that
need you first. Each session key
draws a thin **context-fill bar** along its bottom edge (green below 60%, amber below 85%, then red).

- **Short press**: jump to that session's window, or **approve** it if it is waiting on the gate.
- **Long press** (about 0.7s): **deny** a gate-waiting session. For a normal session it does nothing
  unless `SD_LONG_PRESS_STOPS = true` (then it stops the turn).

On a deck of at least 4×2 keys (the Standard and the XL, not the Mini), the four **bottom-left**
keys are fleet actions:

- **🎯 JUMP**: the first tap jumps to the session that most needs you (approval › error › stalled);
  each further tap cycles to the next. After a few seconds idle a fresh tap restarts at the neediest
  (`SD_JUMP_RESET`).
- **✓ APPROVE**: approve the front-most pending approval, like ⌘⌥A (hands-free through the gate
  when it's waiting).
- **＋ SPAWN**: reveal the panel and ask for a folder and task, like ⌘⌥S.
- **🎙 VOICE**: local push-to-talk dictation. Tap to record (the key turns red **REC**), talk, tap
  again: **whisper-cli transcribes on-device** and sends the text to the project window you have
  focused (it auto-submits by default). It needs `brew install whisper-cpp ffmpeg`, a model at
  `voice.model` (for example `ggml-base.en.bin`) and Microphone permission for Hammerspoon. Tune it
  under `voice` in `cc-config.json` (`model` / `micDevice` / `autoSend` / `maxSeconds`, a hard cap,
  default 120s).

The **bottom-right** key is **☕ CAFFEINE**: it toggles keep-awake (below) and shows amber **AWAKE**
or dim **SLEEP OK**. On the XL, the key just left of it is **⌘⇥ APP TAB**, which sends a real
⌘-Tab. `STREAMDECK_ACTIONS = false` gives all the action keys back to sessions.

Tunables near the top of [claude-dashboard.lua](../claude-dashboard.lua): `STREAMDECK_ENABLED`,
`STREAMDECK_ACTIONS`, `SD_LONG_PRESS`, `SD_LONG_PRESS_STOPS`, `SD_JUMP_RESET`, `SD_BRIGHTNESS`,
`SD_FALLBACK_KEYS`. Keeping your normal Elgato profiles running alongside would need a separate
Stream Deck plugin, which isn't built.

## Keep this Mac awake

The **☕** toggle in the header keeps your Mac awake while long runs work unattended. It runs
`pmset -a disablesleep 1/0`, so it holds even with the lid closed. That needs root, so macOS asks for
your password each time you flip it. The button reads the real state with `pmset -g` (no password)
and shows **☕ Awake** (amber) when on.

## Lock the screen, keep the agents running

The **🔒** button locks the Mac behind a full-screen overlay that blocks all keyboard and mouse input
until you type your password, while **everything keeps running**: Claude sessions, the gate and
Remote Control. It is deliberately **not** the macOS login window, which would block Shepherd's
keystroke control. The first click sets a password, stored as a salted SHA-256 hash in
`~/.claude/cc-lock.json`, never in plain text. Pair it with **Awake** to close the lid locked and
leave the fleet working.

It is a **soft lock** that deters casual access, not a security boundary: the `⌘⌥⌃⇧U` chord
force-unlocks so a typo can't lock you out, and `killall Hammerspoon` or a reboot always releases
it. For a real security boundary use the macOS lock, which stops keystroke-driven control.

While it's up, the lock shows the clock and one ring per project that has something going on. A
working project's ring spins in its own colour; one that needs you holds a full amber ring; one
that's **ready to merge** holds a teal ring; an error holds a red ring. The line under the rings
counts sessions (`2 working  ·  1 needs you  ·  1 ready to merge`) and reads "All quiet" only when
nothing is running or waiting. It decides "needs you" the same way the cards do.
