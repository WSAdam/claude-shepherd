# Claude Shepherd — TODO (what's left)

The cross-machine / controls roadmap (Parts A/C/E) is **done**. This tracks the small
remaining items. Full per-round detail is in CHANGELOG.md and git history.

## Shipped ✅
- **Per-session editor detection** + **AskUserQuestion surfacing** + **effort dropdown** +
  **click-to-answer** + nudge focus-race fix.
- **Persistent relabels** (keyed by project path, `cc-labels.json`), **caffeinate toggle**
  (top-bar `pmset disablesleep`), **in-panel New-session modal** (folder browser + recent
  dirs + new-project), **editor-aware spawn** (Terminal/Kitty/VS Code/Cursor), **Shepherd.app
  Dock launcher**.
- **Headless approvals** — one-click Settings toggle (arm gate + all policies off); editable
  `gate.tools`; per-control explanations. **Editor-window pop split** (`popOnComplete` /
  `popOnApproval`) with an editor-aware `cc-popup.sh`.
- **Part A — Kitty effect routing**: `core.kittyCmd`/`kittyKeyToken`; per-session effects run
  headlessly via `kitty @` (focus/approve/deny/nudge/close/answer/mode); spawned Kitty +
  global `kitty.conf` get remote control auto-enabled.
- **Part C — Permission-mode dropdown**: `core.modeCycleSteps` (Shift+Tab); detail-panel Mode
  select + New-session permission-mode picker.
- **Part E — Installer**: `make setup` / `install.sh` (idempotent: copy, jq-merge hooks with
  backup, ensure init.lua dofile, build Shepherd.app); `core.mergeHooks`; `tests/install.test.sh`.

## TODO
- **Verify on a real Kitty box** (the one thing that needs the hardware): the `core.KITTY_KEY`
  send-key tokens (`enter`/`esc`/`down`/`tab` — `kitty @ send-key` fails *silently*) and the
  AskUserQuestion picker nav (`answerKeys` = arrow-down×N + Enter). Retune `KITTY_KEY` /
  `answerKeys` if a token's off.
- **4c-E — project routing / orchestrator** (deferred): per-project task routing + richer
  autopilot. Design notes in [docs/orchestrator-next.md](docs/orchestrator-next.md).

## Known platform limits (not bugs)
- **VS Code extension** UI widgets (AskUserQuestion picker, permission-mode switcher) are
  **mouse-only** — no keyboard path. So click-to-answer, live mode-switch, and non-gate approve
  are **best-effort/jump-only** in the extension and **reliable only on Kitty** (`kitty @`) or via
  the **headless gate** (decision file). VS Code spawn ("run claude in a new terminal") is likewise
  best-effort keystrokes; Kitty/Terminal spawn reliably.
- A pop on *completion* with both `popOn*` flags off is the **VS Code extension** raising its own
  window, not Shepherd (arming the gate stops the *approval* pop).

## Testing discipline (keep it)
Pure decisions → `cc-core.lua` + unit tests; effects → `fx` recorder; shell hooks → bash suites
with temp dirs. No live `kitty @` / keystrokes in tests. `make test` green before every `make deploy`.
