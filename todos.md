# Claude Shepherd — TODO (what's left)

Roadmap for the cross-machine / controls work. Shipped items are in git history; this
tracks what remains. Full design notes:
`~/.claude/plans/2026-06-04-09-19-07-cc-dashboard-focus-glittery-parasol.md`.

## Shipped ✅ (this round)
- Per-session **editor auto-detection** (`cc-status.sh` → `editor`/`permission_mode`/`effort`/
  `kitty_window_id`/`kitty_listen_on` in the status JSON). Tests: `tests/editor.test.sh`.
- **AskUserQuestion surfacing**: options render in the panel as clickable buttons.
  Tests: `tests/ask.test.sh`.
- **Effort dropdown** → `/effort <level>` (live slash command). Detail badges: editor · mode · effort.
- **Click-to-answer** (editor-aware): Kitty → drive picker keys; VS Code → jump to the picker
  (mouse-only there). `core.answerKeys` + `FX.sendKeys`.
- **Nudge focus-race fix**: `typeIntoWindow`/`pasteIntoWindow`/`sendKeys` restore focus only AFTER
  the final keystroke (the old early restore was the chronic nudge flakiness — now reliable).

## TODO

### Part A — Kitty effect routing (the cross-machine foundation)
Detection is done; **effects still always use the VS Code path.** Route per session on `it.editor`:
- Pure (cc-core, tested): `core.kittyCmd(action, session, payload)` → exact `kitty @ …` argv
  (`focus-window` / `send-text` / `send-key` / `close-window` / `launch`), matched by
  `--match id:<kitty_window_id>` (fallback `cwd:`), with the `--to <kitty_listen_on>` socket.
- Impure: `FX.focusWindow/typeIntoWindow/pasteIntoWindow/sendKeys/closeWindow/spawn` dispatch on
  `item.editor`; kitty → run the built argv via `hs.task`. Non-kitty → today's behavior (unchanged).
- `cc-popup.sh`: branch on `cc_config '.editor.profile'`/detected editor for the focus-on-finish pop.
- **Prereq to document/enable:** kitty.conf `allow_remote_control yes` + `listen_on`.
- **Verify live on a Kitty box:** the env (`CLAUDE_CODE_ENTRYPOINT=cli`, `KITTY_WINDOW_ID`,
  `KITTY_LISTEN_ON`), `kitty @ --match id:` targeting, and the AskUserQuestion picker nav keys
  (currently `answerKeys` assumes arrow-down×N + Enter — confirm/retune).

### Part C — Permission-mode dropdown (plan / ask / edit / automate)
- Pure (tested): `core.modeCycleSteps(cur, target, enabledModes)` → Shift+Tab count along the cycle
  `default → acceptEdits → plan → [bypassPermissions] → [auto]`; `core.spawnFlags(mode, effort)`.
- Dropdown in the detail (like Effort): pick → `handleAction("set-mode")` → Shift+Tab×N via the
  session's send-key. **Kitty reliable; VS Code best-effort** (extension mode-switch is mouse-only,
  same limit as click-to-answer). Show current mode from the captured `permission_mode`.
- `+ New` spawn: mode picker → `claude --permission-mode <m>`. Automate=`bypassPermissions` is
  launch-gated (only in the Shift+Tab cycle if enabled at launch) — note in UI.

### Part E — Installer (`make setup` / `install.sh`)
- Idempotent first-run: copy `cc-*.sh` + `cc-core.lua` → `~/.claude`, `claude-dashboard.lua` +
  `cc-core.lua` → `~/.hammerspoon`, `chmod +x`; **merge** `settings-hooks.json` into
  `~/.claude/settings.json` (back up first; skip if present); ensure the `dofile(...)` in
  `~/.hammerspoon/init.lua`; print the Kitty prereq when relevant.
- Pure (tested): `core.mergeHooks(existing, template)` (idempotent, preserves user keys).
- Test: `tests/install.test.sh` against a temp `$HOME` (files copied, hooks merged, backup made,
  re-run is a no-op). `make install` stays the fast code-only redeploy.

## Known platform limits (not bugs)
- **VS Code extension** UI controls (AskUserQuestion picker, permission-mode switcher) are
  **mouse-only** — no keyboard path to drive them. So click-to-answer and live mode-switch are
  **best-effort/jump-only** in the extension and **reliable only on Kitty** (terminal TUI + `kitty @`).
- No supported API to inject a prompt into a running session → nudge/effort/clear use
  clipboard/keystrokes (now race-fixed and reliable in the extension's *chat input*; the gate's
  decision-file path remains the only truly hands-free approve/deny).

## Testing discipline (keep it)
Pure decisions → `cc-core.lua` + unit tests; effects → `fx` recorder; shell hooks → bash suites with
temp dirs. No live `kitty @` / keystrokes in tests. `make test` green before every `make deploy`.
