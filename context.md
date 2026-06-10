# Context — Claude Shepherd

Orientation for working in this repo: architecture, invariants, and workflow. Other docs:
user-facing [README.md](README.md), dated history [CHANGELOG.md](CHANGELOG.md), what's left
[todos.md](todos.md), design rationale [docs/orchestrator-next.md](docs/orchestrator-next.md).

## What it is

A local, single-user macOS control panel for a fleet of Claude Code sessions (renamed from
"babysitter"). A Hammerspoon webview dashboard surfaces every session's live status, lets you
approve / stop / nudge them, and automates routine babysitting: task auto-feed, graceful
drain, stale-approval escalation, opt-in auto-respawn, and a stuck-session watchdog. No
network, no multi-user, no secrets — it reads session status off the local filesystem.

## Architecture — the load-bearing split

- **[cc-core.lua](cc-core.lua) — pure logic, zero `hs.*`.** Every decision (status
  parse/sort/staleness, action selection, spawn specs, ledger + fleet-insights aggregation,
  per-session risk, grouping/filtering, sparkline bucketing) is a pure, deterministic
  function unit-tested directly in plain `lua`. **New logic goes here.**
- **[claude-dashboard.lua](claude-dashboard.lua) — Hammerspoon glue (~3,900 lines).** The
  webview, the ~1s refresh loop, module-level state, and all side effects. Effects funnel
  through one `fx` table (focus / keys / paste / file writes / spawn) so tests pass a
  **recorder double** instead of acting. This file is NOT unit-tested directly — put logic in
  cc-core, or smoke-test after `make install`.
- **Panel JS** (embedded in claude-dashboard.lua as an HTML string) renders the grid
  client-side. A few pure cc-core helpers are **hand-mirrored** in this JS for instant
  interactivity (`filterTiles`, `applyGroups`, `fmtDuration`, `usageBarLevel`); these twins
  must stay in sync — comments mark them. `BULK_RULES` is single-sourced (injected as
  `__BULK_RULES__`) so the bulk-bar count can't drift from what Lua acts on.
- **Shell hooks** — [cc-status.sh](cc-status.sh) / [cc-approve.sh](cc-approve.sh) /
  [cc-popup.sh](cc-popup.sh) + [cc-lib.sh](cc-lib.sh). Claude Code hooks write session status
  JSON into `~/.claude/cc-status/`; the dashboard reads it.

## Invariants worth knowing

- **projectKey is the stable identity** — the encoded launch folder from `transcript_path`
  (cwd fallback when there's no transcript). Labels, groups, and respawn budgets key by it so
  they survive cd-drift and close/reopen. A live `cwd` can drift, so **never resolve
  persistent per-project state by cwd when a projectKey exists** (the cwd-keyed fallback fires
  only for genuinely keyless sessions — see `applyGroups` / `applyLabelsByCwd`).
- **cc-core stays pure + deterministic** — no `hs.*`, no wall-clock except via an injected
  `now`. Need a side effect? Route it through `fx`.
- **Webview XSS defense is render-time `esc()`**, not input sanitization — every
  user-controlled string (label / relabel / group) passes through `esc()` at the sink.
  [tests/escaping.test.sh](tests/escaping.test.sh) is a source-level tripwire for it.
- **Per-tile refresh state is one row**: `prev[key] = { status, stale, escalated }`, rebuilt
  and swapped each refresh so a vanished tile drops out. `respawnAttempts` is separate
  (keyed by projectKey — a per-folder budget, different lifecycle).

## Workflow

- **`make test`** runs the whole suite ([tests/run.sh](tests/run.sh)): bash + standalone lua,
  all side-effect-free (temp dirs + recorder doubles, never touches real `~/.claude`). Keep it
  green before every deploy.
- **`make install`** copies files into `~/.claude` + `~/.hammerspoon`; **`make deploy`** =
  test + install + reload. **Edits are not live until installed/deployed.**
- Typical change: add a pure cc-core function + its regression test → wire it into the
  dashboard → mirror in the panel JS if it affects rendering (and note the twin).

## State (2026-06-10)

Cross-machine / controls roadmap done. Fleet-scale console shipped (tile search, session
groups, bulk fleet actions, per-session timeline, auto-respawn, insights sparklines,
stuck-session watchdog). Two rounds of adversarial + leaderboard-review bug-sweeps applied.
Suite: **648 core + 104 ui + 128 bash** checks, all green. Remaining work is in
[todos.md](todos.md) (4c-E project routing is the main deferred piece).
