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
- **[claude-dashboard.lua](claude-dashboard.lua) — Hammerspoon glue (~5,900 lines).** The
  webview, the ~1s refresh loop, module-level state, and all side effects. Effects funnel
  through one `fx` table (focus / keys / paste / file writes / spawn) so tests pass a
  **recorder double** instead of acting. This file is NOT unit-tested directly — put logic in
  cc-core, or smoke-test after `make install`.
- **Panel JS** (embedded in claude-dashboard.lua as an HTML string) renders the grid
  client-side. A few pure cc-core helpers are **hand-mirrored** in this JS for instant
  interactivity (`filterTiles`, `applyGroups`, `fmtDuration`, and `contextBand` → the JS
  `barLevel`); these twins must stay in sync — comments mark them. `BULK_RULES` is single-sourced (injected as
  `__BULK_RULES__`) so the bulk-bar count can't drift from what Lua acts on; likewise the ⌨ hotkey
  legend is injected as `__HOTKEY_LEGEND__`, built from the real `HOTKEY_*` bindings so the displayed
  combos can't drift from what's bound.
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
  (keyed by projectKey — a per-folder budget, different lifecycle). **Autonomous actions
  (feed / prune / respawn) never fire from a missing prev** — the first refresh after a
  reload is an observation, not a transition edge — and never target a stale tile.
- **A large `hs.task` capture deadlocks — redirect to a file.** `hs.task` direct-exec waits for
  the child to exit while reading its stdout pipe; once the child's output exceeds the OS pipe
  buffer (~64KB) it blocks on write and neither side advances (this silently wedged the
  folder-scan index over `~/Programming`). For any scan that can emit a lot, run it via
  `/bin/sh -c "<cmd> > <tmpfile>"` (keeps the task's own pipe empty) and read the file on exit,
  with a retained-timer timeout backstop. `core.folderScanShellCommand` builds the quoted command.
  The accelerators it runs (`rg`/`fd`) are resolved by `resolveBin` (PATH + `/opt/homebrew/bin`
  + `/usr/local/bin`) and **degrade gracefully** to grep/find; `make doctor` reports what's live.
- **Keystroke delivery is a contract.** `FX.pasteIntoWindow` / `FX.sendKeys` / `feedTask`
  return delivery status; when no window positively matches, they **skip** (never type into
  whatever is frontmost) and the caller must gate its side effects (queue pop, mode patch,
  ledger event, success alert) on that return. Every window-keystroke dispatch goes through
  the single `dispatchSerialized` chokepoint (shared `core.staggerSlot` tail) so chains
  can't interleave; headless paths (kitty `@`, armed-gate decision files) stay immediate.
- **Gate decisions are nonce-bound.** `cc-approve.sh` publishes `pending.nonce` per request;
  `FX.writeDecision` echoes it (`allow <nonce>`, written tmp+rename); the gate consumes only
  a matching nonce (legacy bare verbs need a strictly-newer mtime) via an atomic PID-owned
  claim, restoring non-matching answers for their owner.
- **The context bar tracks the editor, not the raw window.** `core.contextFractionFor` divides
  context tokens by `window * context.autoCompactFraction` (default 0.92) so the per-tile bar
  matches Claude Code's "% until auto-compact" (the editor measures against the window minus an
  output reserve). The threshold is **undocumented** — the fraction is an approximation, hand-
  tunable, and preserved across Settings saves (`SETTINGS_KEEP_SUBKEYS.context`). Color comes
  from `core.contextBand` (7 bands, mirrored in the panel `barLevel` twin — keep them in sync).
- **Two different "remote controls" — don't conflate them.** `spawn.kittyRemote` /
  `kittyAutoRemote` is **Kitty's** `kitty @` control (so *Shepherd* can drive the window
  headlessly). `remoteControl.*` is **Claude Code's own** Remote Control (so *you* drive a local
  session from claude.ai / mobile): `onSpawn` adds the `--remote-control` launch flag (LOCAL
  native-Anthropic only — it rejects gateway/ssh and needs claude.ai auth), `sweepOnStartup`
  types `/rc` into already-running idle/done local sessions. The "enable for all sessions"
  Claude Code setting has **no documented settings.json key**, so Shepherd can't set it — it's a
  manual `/config` toggle (noted in the ⚙ help + README).
- **Auto-Continue is a bounded loop-guard.** `core.stepAutoContinue` resumes an `error` tile by
  typing `continue` after a grace delay, but charges a **per-folder** budget that resets ONLY on
  a clean `done`/`idle` — never on the `working` the continue itself produces — so a persistently
  dead connection can't loop. Same edge discipline as auto-respawn (off by default, ledgered).
- **L1 Agent Profiles + L2 policy bundles (shipped 2026-06-14) — the operator-data files + sync
  contracts a refactor must not break:**
  - **Operator-data registries** (same posture as `cc-presets.json`, never store secrets — env-var
    NAMES only): `cc-agents.json` (saved agent profiles; `core.agentList/agentPush/.../agentFork`),
    `cc-mcp.json` (MCP servers; `core.mcpList/.../mcpConfig`). Skills are read-only from
    `~/.claude/skills/*/SKILL.md` (`core.parseSkillFrontmatter`, `FX.listSkills`).
  - **"Spawn from a saved agent"** = `core.resolveAgent` → `core.spawnExtraFlags` appends
    `--mcp-config`/`--append-system-prompt`/`--agent`/`--add-dir`/`--plugin-dir` inside `spawnSpec`.
    New `shArg` quotes value-bearing flags in the shell sinks only (kitty argv stays raw; existing
    no-space flags byte-identical — don't regress that).
  - **L2 gate KEEP-IN-SYNC (load-bearing):** the panel resolves each session's policy with
    `core.resolvePolicy` (precedence per-session override > attachment > fleet) and writes
    `~/.claude/cc-policy/<key>` = `{autoAllow, autoDeny, bundle}`; `cc-approve.sh` `match_patterns`
    reads that file as **authoritative + opt-in** (applies regardless of `policies.patterns.enabled`),
    falling back to the flat fleet `policies.patterns.*` only when the file is absent. Three rules a
    change must preserve: (1) the per-session **orphan sweep** in `refresh()` (readDir `POLICY_DIR`,
    clear any key not re-written this tick) is **decoupled** from the `hasAtt/hasOvr` fast-path — a
    removed attachment must never leave an enforcing orphan; (2) `FX.writeResolvedPolicy` is **atomic**
    (temp+rename) — the gate reads it on the hot path; (3) `cc_remove` (SessionEnd, `cc-lib.sh`) reaps
    `cc-policy`/`cc-policy-override`. The `POLICY_DIR` default must match across `cc-lib.sh`,
    `cc-approve.sh`, and the dashboard (`~/.claude/cc-policy`).

## Workflow

- **`make test`** runs the whole suite ([tests/run.sh](tests/run.sh)): bash + standalone lua,
  all side-effect-free (temp dirs + recorder doubles, never touches real `~/.claude`). Keep it
  green before every deploy.
- **`make install`** copies files into `~/.claude` + `~/.hammerspoon`; **`make deploy`** =
  test + install + reload. **Edits are not live until installed/deployed.**
- Typical change: add a pure cc-core function + its regression test → wire it into the
  dashboard → mirror in the panel JS if it affects rendering (and note the twin).

## State (2026-06-14)

**Feature-mining → build:** 5 top AI apps (LiteLLM/crewAI/OpenHands/cline/AutoGPT) were adversarially
mined into a backlog L1–L7 (see [todos.md](todos.md); per-project reports in `docs/feature-mining/`).
**L1 — Agent Profiles ("spawn from a saved agent")** is the first shipped (see [CHANGELOG.md](CHANGELOG.md)):
a pure-`cc-core` registry layer (`cc-agents.json` + `cc-mcp.json`, validator, `resolveAgent`, `mcpConfig`,
`personaPrompt`, `spawnExtraFlags`, skills parser) plus the New-Session modal's Agents chip row, Save-as-agent,
and a read-only Skills card. The richer registry-management UI (folders/favorites/fork/sort, in-panel
skills/MCP/knowledge attach editor) is the deferred L1 follow-up.

**L2 — named policy/guardrail bundles** is shipped too: `policies.bundles` + `policies.attachments` resolved
per session (`core.resolvePolicy`, precedence override > attachment > fleet) into a `cc-policy/<key>` file the
gate (`cc-approve.sh`) reads authoritatively, with a detail-panel Policy dropdown, an orphan sweep, atomic
writes, and SessionEnd cleanup — built with an adversarial-review pass that caught + fixed an orphaned-policy
enforcement bug. Deferred: the bundle/attachment editor UI.

**L3 — parameterized + versioned prompt templates** is shipped: saved templates (`cc-templates.json`) grew from
flat `{name, text}` into structured/versioned records with `{{var}}` interpolation, all back-compat. The
load-bearing facts a refactor must keep:
- **cc-core is the authoritative renderer — no JS render twin.** `core.renderTemplate` does the substitution;
  the panel round-trips through the `template-render` handler (which composes + interpolates and echoes back via
  `ccTemplateRendered`). The only JS twin is the trivial `{{`-detection. Built-ins: `date`/`today`/`now` come
  from an **injected `os.time()`** (cc-core stays clock-pure — `opts.now`); `{{prev_output}}` = the relevant
  tile's `it.activity` (transcript snippet).
- **Two render modes.** Interactive (Tpl menu, modal picker) REFUSES on a missing required var. Autonomous feed
  (`renderFeed` at the three queue feed sites) uses `keepMissing=true`: built-ins + `{{prev_output}}` resolve,
  unfillable user vars are left VERBATIM, it never refuses, and a placeholder-free task is byte-identical — so
  existing queues are unaffected. The **raw** queued task is still what's popped/persisted/ledgered; only the
  typed text is rendered. Delivery gating (`queueFeedCommit`) is untouched.
- **Validator family mirrors L1.** `validateTemplate → templateLoad (keep-valid/drop-bad/return errors) →
  templateList`. Versioning (`templatePushVersioned`) is duplicate-on-edit; its change detector signs on the
  **composed body** (so an edit to a `composeTemplate`-shadowed field doesn't spuriously bump). Definition source:
  `parsePromptFile`/`promptImport` import `*.prompt`/`*.md` from `templates.sourceDir` (default
  `~/.claude/cc-prompts`), strictly local. Deferred: the structured-template authoring + version/revert editor UI.

Build order next: **L4** (declarative routing — the affinity source is DECIDED = queue-line `@role:` prefix) → L5 → L6 → L7.

## State (2026-06-13)

Cross-machine / controls roadmap done. Fleet-scale console shipped (tile search, session
groups, bulk fleet actions, per-session timeline, auto-respawn, insights sparklines,
stuck-session watchdog). A distinct **"Error" state** (magenta) flags sessions frozen on an
API error and offers a one-click **Continue** to resume them — derived client-side from the
transcript tail (`core.transcriptError`), no hooks. A **three-round multi-agent scan**
(per-flow finders → adversarial verifiers → engineer fixes, June 2026) fixed 46 verified
bugs and hardened the gate IPC (nonce-bound decisions), autonomy loops (600s frozen
threshold), and keystroke delivery (skip-on-no-match + serialized dispatch). The scan's
**feature roadmap then shipped in full** (June 12): Settings UI for the dark config,
per-session gate decision log, 🔔 notification history, queue editing/bulk-paste/templates,
spawn presets + fd fuzzy folder search, 🔎 rg-backed fleet-wide transcript/ledger search,
**4c-E project routing** (level-triggered dispatcher, double opt-in), and the **SSH status
bridge** (rsync-mirrored ⇄ remote tiles, headless approve/deny over ssh — hardware
verification checklist pending).

**June 13 batch** (this session): (1) the **context bar** now shows the `NN%` on the bar,
tracks the editor's "% until auto-compact" via `context.autoCompactFraction`, and colors in 7
bands (calm <50, every 10% to 90, critical last-5%); (2) **Auto-Continue** auto-resumes an
API-error tile after a grace delay (bounded per-folder, off by default); (3) **Auto-Remote-
Control** launches new spawns with `--remote-control` and sweeps `/rc` into running sessions on
startup. Routing follow-ups were **deliberately deferred** (UX-blocked — see todos.md). Suite:
**1260 core + 210 ui + 177 bash** checks, all green. Remaining work is in [todos.md](todos.md):
the **needs-hardware** runbook ([docs/hardware-verification.md](docs/hardware-verification.md))
for the Kitty tokens + the SSH bridge, and the deferred routing follow-ups.
