# Install, upgrade and uninstall

[← README](../README.md) · [Configuration](configuration.md) · [Troubleshooting](troubleshooting.md)

Shepherd runs on **macOS** and supervises Claude Code sessions in **VS Code** (and Cursor, Kitty and
Terminal).

## The easy way: double-click

1. Download the repo (GitHub → **Code → Download ZIP**, then unzip) or `git clone` it.
2. Double-click **`Install Shepherd.command`**. macOS blocks a downloaded copy the first time
   ("unidentified developer" / "Apple could not verify"): right-click it → **Open** → **Open**, or on
   newer macOS click **Open Anyway** in System Settings → Privacy & Security. A `git clone` isn't
   blocked.
3. A Terminal window installs whatever this Mac is missing, and skips anything already there:
   - the Xcode command-line tools (click **Install** in macOS's dialog, then wait),
   - [Homebrew](https://brew.sh) (it asks for your Mac password),
   - `jq`, `lua` and `node` (required), `ripgrep` and `fd` (faster search, optional),
   - Hammerspoon and VS Code,
   - Claude Code and its VS Code extension,
   - then Shepherd itself (`install.sh`, below), and it restarts Hammerspoon.
4. Once, by hand: turn on **Hammerspoon** in System Settings → Privacy & Security →
   **Accessibility** (the installer opens that pane), and sign in to Claude in VS Code's Claude
   Code panel. The panel appears top-right.

Re-running it is safe: finished steps are skipped. If a required piece won't install, it stops
before it touches your Claude or Hammerspoon settings and says what to fix.

`Install Shepherd.command` runs `bootstrap.sh` (the prerequisites above), which runs `install.sh`
(Shepherd itself).

## What the install sets up

- **Shepherd**: the hook scripts and logic go into `~/.claude` and `~/.hammerspoon`. Its hooks are
  **merged** into `~/.claude/settings.json` (backed up first; your own hooks stay; a symlinked
  settings.json stays a symlink). It adds the `dofile(...)` line to `~/.hammerspoon/init.lua`, and
  installs **Shepherd.app** (a Dock launcher, below) and the **tab bridge** VS Code extension.
- **Default settings**: Shepherd's settings as the author runs them daily
  ([defaults/cc-config.json](../defaults/cc-config.json)), written whole if you have no
  `~/.claude/cc-config.json`; otherwise only the settings you haven't set are added. Change
  anything later in ⚙ Settings. Notably on: **Actually launch**
  (New really opens sessions), the audit ledger, Remote Control for spawned sessions, VS Code as
  the editor.
- **Claude Code settings the workflow relies on**
  ([defaults/claude-settings.json](../defaults/claude-settings.json)): worktrees branch from your
  current HEAD, Remote Control at startup, push notifications, effort high. Each is added only
  where you haven't set it yourself. Plus **permission deny rules** that enforce the methodology's
  secrets rules instead of just stating them: `git add -f` and `git add --force` (both spellings),
  and writing `.env.example` / `.env.sample` / `.env.template`. Reading `.env` is *not* denied,
  because sessions legitimately need it. If you already keep a `permissions.deny` list, yours is
  merged with ours: every entry you had stays, ours are appended where missing, and re-installing
  adds no duplicates.
- **The methodology** ([methodology/CLAUDE.md](../methodology/CLAUDE.md)): how Claude sessions work
  with Shepherd — units in worktrees, ready-to-merge reviews, batches of parallel units, tests first
  with regression fixtures. It goes into `~/.claude/CLAUDE.md` between two marker lines (your own
  text stays; re-installing replaces just that block). It is skipped if your CLAUDE.md already has
  a `## Parallel Worktree Workflow` section.

## By hand

Prerequisites: [Claude Code](https://claude.com/claude-code) (run it once), VS Code, and

```bash
brew install --cask hammerspoon
brew install jq lua node        # required: jq for the tiles, lua + node run the test gate
brew install ripgrep fd         # optional: faster fleet search and folder scan
```

Launch Hammerspoon once and grant it Accessibility (System Settings → Privacy & Security →
Accessibility). It needs that to focus windows and send keystrokes. Then:

```bash
make setup
```

`make setup` runs the **pre-flight test suite** first. If the suite is red (or `lua` / `node` is
missing so it can't run), the install aborts having changed nothing. Bypass it with
`bash install.sh --skip-tests` (or `CC_INSTALL_SKIP_TESTS=1`). It ends with the **tooling check**
(jq / lua / node / Hammerspoon / ripgrep / fd). Run **`make doctor`** any time to see that check
again. Finally click the Hammerspoon menu-bar icon → **Reload Config**.

## Upgrading after a `git pull`

```bash
git pull
make setup
```

**`make setup`, not `make install`.** `make install` only copies the scripts and the dashboard. It
never touches `~/.claude/settings.json`, the default settings or the methodology block, so a
release that adds a *hook* (as the held-question hook did) would land on disk and never run.
`make setup` is the full installer: the same one a fresh install runs, safe to re-run, and a no-op
where nothing changed. It re-runs the pre-flight suite, so it also tells you if the version you
pulled is red on your machine before it changes anything.

Then, once it finishes:

1. **Hammerspoon** menu-bar icon → **Reload Config**. Hammerspoon runs the copies in
   `~/.hammerspoon`, and it doesn't reload them on its own.
2. In each **VS Code window that was already open**: ⌘⇧P → **Developer: Reload Window**. A window
   holds the tab bridge extension it loaded at startup, so until it reloads it keeps running the
   older one. 🩺 **Diagnostics** says so explicitly (*"An older tab bridge runs in N VS Code
   windows"*), and also checks that all four hooks are wired.

Upgrading never overwrites a setting you made. Shepherd settings added since your install are
filled in where you have no value of your own (your `false` stays `false`), and `cc-config.json`
is backed up before it is rewritten. Your `~/.claude/CLAUDE.md` is changed only between the
methodology markers; everything outside them stays.

## Uninstall

Double-click **`Uninstall Shepherd.command`**, or run `make uninstall`. It removes Shepherd's hooks
from `~/.claude/settings.json` (backup made; your own hooks and settings stay), the scripts and
dashboard it copied, its `init.lua` line, the methodology block in `~/.claude/CLAUDE.md`,
Shepherd.app and the tab bridge. Shepherd's settings and history (`cc-config.json`, `cc-status/`,
the ledger, …) stay: the double-click uninstaller asks first and deletes them only if you answer
yes, while `make uninstall` always keeps them unless you ask for `make uninstall PURGE=1`.
Hammerspoon, VS Code, Claude Code and the Homebrew packages stay installed. Reload Hammerspoon
afterwards to close the panel.

The **Claude Code settings** the install filled in, including the `permissions.deny` rules above,
are left alone, the same as the other defaults: once they're in `~/.claude/settings.json` they're
yours, and the uninstaller can't tell them from a rule you wrote. To drop the deny rules, edit
`~/.claude/settings.json` and remove the entries from `permissions.deny`, or run:

```bash
jq '.permissions.deny -= ["Bash(git add -f:*)","Bash(git add --force:*)",
      "Write(**/.env.example)","Write(**/.env.sample)","Write(**/.env.template)"]' \
  ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

## The panel

The panel appears top-right. Drag it by its title bar and resize it; it floats above other windows
and shows on every Space. Its size and position are remembered (in `hs.settings`): a reload
restores them instead of snapping back to the default. If a saved frame ends up off-screen or too
small, it falls back to the top-right default.

## The tab bridge: a companion VS Code extension

`make setup` and `make install` also put a small extension, **Shepherd Bridge**
([vscode-bridge/](../vscode-bridge/)), into VS Code. Nothing is published: `make tab-bridge` zips it
into a `.vsix` and hands that to VS Code's own command-line tool (`code --install-extension`),
found on your PATH or inside the app bundle (so a VS Code run from Downloads works too; set
`CC_CODE_CLI` to point elsewhere). It reinstalls only when its version changes
(`FORCE=1 make tab-bridge` forces it), and a machine without VS Code just gets a warning. Open
windows normally pick it up at once; one that doesn't needs **Developer: Reload Window**
(Diagnostics lists those windows).

What it does, and what it never does, is in
[Merging and batches → The tab bridge](merging-and-batches.md#the-tab-bridge).

## Shepherd.app: a Dock launcher

`make setup` (or `make app`) builds **`~/Applications/Shepherd.app`**. Drag it to your Dock and
click it to show or hide the panel like any app. It toggles the panel through Hammerspoon's
built-in `hammerspoon://` URL scheme (no extra dependencies). The first open is unsigned, so
right-click → **Open** once to clear Gatekeeper.

To pin it to the Dock automatically, run **`make dock`**: it builds the app if needed, then adds it
to the Dock. It is idempotent, and the Dock briefly restarts. Remove it any time by dragging the
icon off the Dock.

The app's icon comes from [docs/assets/shepherd.png](assets/README.md) when present. The **menu-bar**
icon stays 🐑. The app is only a launcher: Shepherd has no process of its own (see
[Troubleshooting](troubleshooting.md#is-shepherd-running)).

## Launch on startup

Shepherd runs inside Hammerspoon, so "launch on startup" means **Hammerspoon opens at login** and
the panel comes up with it. This is **on by default** the first time Shepherd runs. Toggle it any
time in **⚙ Settings → General → "Launch Shepherd on startup"**. It sets Hammerspoon's real
*Open at Login* item (`hs.autoLaunch`).

## Kitty users

For reliable click-to-answer and headless approve on Kitty, Shepherd turns on remote control in
your `kitty.conf` (`allow_remote_control` + `listen_on`) when it detects a Kitty session, backing
the file up first. **Restart Kitty** for it to take effect. Sessions Shepherd spawns get it through
launch flags, with no restart needed.
