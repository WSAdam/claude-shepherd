# spec.md — Claude Shepherd ("the fleet console for Claude Code")

A floating, always-on-top Mac panel with **one tile per Claude Code session**. Each
tile shows the project and a live status; selecting it opens a control panel to
**jump**, **approve/deny**, **nudge**, or **stop** that session — plus observability,
automation, and governance over the whole fleet from a single pane.

> Status: **reverse-engineered from the shipped app** (README + source), not a forward
> scoping draft. This documents intent and the decisions already made, so the
> [user stories](./user-stories.md) have a traced home and future features can be scoped
> against it. Sections marked **[DECISION]** record a product choice that's already
> settled (with its rationale), not an open question.

---

## 1. Product thesis

**When you run several Claude agents at once, the bottleneck is *you*.** A session that
finishes or hits a permission prompt sits idle until you happen to notice it. Shepherd's
job is to **tell you which agent needs a human right now, and let you handle it without
losing your place.**

- One **always-on-top panel**, one tile per session, color-coded by who needs attention.
- Everything you'd otherwise context-switch for — approve a permission, read what it's
  doing, nudge it, stop it, switch its model — happens **in the panel**.
- It is the on-screen equivalent of a **Stream Deck for a fleet of agents**.

The design constant: Shepherd **observes and nudges**; it never becomes the thing doing
the work. Claude Code is still the harness; Shepherd is the supervisor's console.

## 2. Goals / Non-goals

**Goals**
- See the whole fleet at a glance; surface the one session that needs a human first.
- Reliable **approve/deny** of permission prompts — ideally hands-free, regardless of editor.
- Per-session control (jump, stop, nudge, clear/compact, effort/mode/model) from the panel.
- Spawn new sessions (folders, presets, agent profiles, providers) from the panel.
- Opt-in automation: queues/routing, escalation, respawn, rules, schedules — **all off by default**.
- Governance you can audit: an opt-in ledger, insights, shift reports, gate-decision provenance.
- Local-first observability (status, plan/TODO, usage, subagents) **derived from data Claude
  already writes** — no extra hooks, zero model tokens.

**Non-goals**
- **Orchestrating non-Claude agent CLIs** (aider, gemini-cli). They have no hook system, so
  tiles/approvals couldn't work. Shepherd supervises **Claude Code** specifically. **[DECISION D-1]**
- **Being a second executor.** Rules and routines fire the *normal* spawn/nudge effects; they
  don't introduce a parallel action engine. **[DECISION D-2]**
- **Enforcement by quarantine.** Risk/collision/loop/hung are **detection only** — they badge,
  they never block, lock, or kill another process. **[DECISION D-3]**
- **A hardened security boundary.** The screen lock is a *soft* deterrent, not the macOS login
  window (that would break keystroke control of GUI sessions). **[DECISION D-4]**
- **Cross-platform.** macOS + Hammerspoon only; control relies on macOS Accessibility, `kitty @`,
  and AppleScript-style focus.
- **Claiming outcomes.** Shepherd reports *operations* (prompts, approvals, spawns), never "what
  shipped" — it has no git/CI ground truth. **[DECISION D-5]**

## 3. The core loop (the heart of the design)

Everything rests on a one-way **hook → status file → panel** flow, with an optional
**panel → decision file → gate** return path. No daemon, no socket, no DB.

```
Claude Code hooks ──► cc-status.sh ──► ~/.claude/cc-status/<session_id>.json ──► dashboard (tiles)
                  └─► cc-approve.sh ◄── ~/.claude/cc-status/<session_id>.decision ◄── (panel Approve/Deny)
```

- **`cc-status.sh`** merges each hook event (SessionStart, UserPromptSubmit, Pre/PostToolUse,
  Notification, Stop, SessionEnd, PermissionRequest, AskUserQuestion) into that session's JSON.
- **`cc-approve.sh`** is the optional PreToolUse gate: it parks a gated tool and reads the
  decision file the panel writes — **no window focus, no keystrokes** needed to approve.
- **`cc-core.lua`** is the pure logic (parsing, sorting, action selection, deck layout,
  spawn-command building) — no `hs.*`, fully unit-tested.
- **`claude-dashboard.lua`** is the Hammerspoon bootstrap: reads the JSON, renders tiles,
  writes a heartbeat, and wires the real effects (focus, keystrokes, Kitty remote, Stream Deck).

**Why a file-merge model.** Hooks are fire-and-forget shell calls; a status file per session is
crash-safe, inspectable, and needs nothing running between events. The dashboard is a *reader*;
the gate is a *reader*; the only writers are the hook script and the panel's decision file.
**[DECISION D-6]**

## 4. Status model

| Status     | Color           | Fires from                    | Meaning                                |
|------------|-----------------|-------------------------------|----------------------------------------|
| `idle`     | gray            | SessionStart                  | Open, nothing happening yet            |
| `working`  | amber           | UserPromptSubmit, Pre/PostTool| Actively doing work                    |
| `approval` | red (pulsing)   | Notification (permission)     | Needs permission or your input         |
| `done`     | green           | Stop, Notification (idle)     | Finished its turn, ready for you       |
| `error`    | magenta         | *derived from transcript*     | Frozen on an API error (no Stop fired)  |

- Sessions are keyed by **session_id** (two sessions in one folder never collide).
- Tiles **dim** after ~90s of silence (a crash), **disappear** on SessionEnd.
- A `done` tile **self-heals to `working`** when the transcript shows the model resumed, so an
  auto-continued/text-only turn isn't stuck on "Ready for you" (`status.resumeSlack`).
- `error` is detected from the transcript with a coarse **cause badge** (budget/timeout/runtime/
  model/cancelled); auto-respawn is held off so you resume the *same* session.

## 5. Control paths — and their honest limits

Two delivery paths, and which one a session uses determines reliability. **[DECISION D-7]**

1. **Headless approvals (reliable everywhere).** Arm the gate; Approve/Deny write a decision file
   the hook honors — no focus, no keystrokes. Works for terminal *and* VS Code-extension sessions.
   This is the recommended path for governance.
2. **Per-session keystroke effects** (jump, stop, nudge, clear/compact, answer, mode-switch). On
   **Kitty** these run headlessly via `kitty @` remote control. On **VS Code/Cursor** they focus
   the window and type — reliable in a terminal, **best-effort in the VS Code extension** (no
   supported API to inject into a running session). **Queue** stores work reliably; feeding into
   the VS Code chat input is the fragile part.

Each session **self-reports its editor** (`cc-status.sh` reads the env it inherits from `claude`),
so the panel routes effects per session: Kitty → headless, everything else → focus-and-type.

## 6. Observability (local, derived, zero extra hooks)

All from the transcript Shepherd already tails — **no extra hooks, no model tokens**:

- Live "Doing:" activity peek; current plan/TODO; error-cause badge; loop-repeat watchdog (badge
  only); stuck/hung watchdog (badge only).
- **Subagent/Workflow fan-out** read from the `subagents/` tree Claude writes; a "⚙ N" pill and
  "Running N agents" so background work isn't mistaken for idle.
- Optional: auto-title, desktop banners, post-run self-summary, PR/MR status (via `gh`), host
  stats, run score — each off by default.
- **Token usage** read from the local transcript `usage` fields: per-tile context-fullness bar,
  fleet total + estimated $ (subscription is flat-rate; this is an API-equivalent estimate),
  and real plan-window (5h/weekly) bars from a **metadata-only** OAuth usage call (spends no
  model tokens; falls back to a labeled local approximation).

## 7. Automation & governance posture

**One settings file (`~/.claude/cc-config.json`), and everything is off until you turn it on.**
A ⚙ Settings panel writes it; the gate reads it on the next hook fire. The capability ladder:

- **The gate** holds a configurable risky-tool list (default `Bash Write Edit MultiEdit
  NotebookEdit`) until you decide; pattern `autoAllow`/`autoDeny` globs (deny wins); per-session
  override (Default/All/None/Custom); time-boxed **Autopilot**. Emptying the tool list restores
  the default (a blank can't be distinguished from unset). **[DECISION D-8]**
- **Named policy bundles** (read-only/no-bash/no-network) attachable per session or by
  project/group/provider glob; union with or replace the fleet patterns.
- **Event-callback rules** (L6): `{trigger: done|error|approval, processor: log|relabel|nudge}`,
  optional match scope, fire-once.
- **Scheduled routines** (L7): cron/one-shot that fire the normal spawn/nudge/digest effects;
  a scheduled spawn still respects `spawn.live` (dry-run).
- **Recovery:** manual + automatic **respawn** of a session frozen mid-turn (capped per folder);
  **Auto-Continue** of a session frozen on an API error (capped per folder); **escalation** nag
  when an approval waits too long. A session waiting on *you* is never auto-respawned.
- **Detection:** risk indicator, shared-directory collision, loop/hung watchdogs — badges only.

**Audit:** an opt-in append-only JSONL **ledger** (`~/.claude/cc-ledger/`) is the data source for
**Fleet insights**, **notification history**, the **shift report**, the **session-history browser**,
**lineage**, and **gate-decision provenance**. Retention is GC'd by days/size; rows can be
redacted/exported/purged. Off by default; never records Claude's own transcripts.

## 8. Providers & models

A "provider profile" is a named bundle of **env vars + a model id** injected into the `claude`
launch. **No API keys are stored** — a profile names an *env var* the spawned login shell expands;
the key lives in your shell, never in Shepherd's config or process. **[DECISION D-9]**

- **anthropic** — sets `ANTHROPIC_MODEL` against the normal endpoint.
- **gateway** — also sets `ANTHROPIC_BASE_URL` to an Anthropic-Messages-compatible endpoint
  (LiteLLM → Gemini/OpenAI/etc., or a local Ollama/vLLM/LM Studio server).

A session's **base URL is fixed at launch**: switching the *model* within a provider goes live via
`/model`; switching the *provider* needs a new session. Every Shepherd control keeps working
because the harness is still Claude Code — only the backend swaps.

## 9. State & data model

No database. State is small JSON files in `~/.claude/`, keyed by **stable project identity** (the
session's launch folder) so labels/groups/queues/worklists survive `/clear`, respawn, and
close/reopen. **[DECISION D-10]**

```
cc-status/<session_id>.json     live per-session status (hook-written)
cc-status/<session_id>.decision panel→gate approval decisions
cc-labels.json / cc-groups.json relabels, group tags        (by project identity)
cc-presets.json / cc-agents.json spawn presets, agent profiles
cc-mcp.json                     MCP server defs (secrets as ${VAR} refs, never values)
cc-queue (per project)          task queues; cc-templates.json parameterized templates
cc-worklist.json                the My-List checklist          (by project identity)
cc-config.json / cc-rules.json / cc-schedules.json  automation config
cc-policy/<key> / cc-gate-tools/<key>  resolved per-session gate state
cc-ledger/YYYY-MM-DD.jsonl      opt-in append-only audit ledger
cc-exports/                     archived sessions (transcript + meta.json)
```

## 10. UX & interaction model

- **Grid of tiles** (status, time-in-state, latest prompt, wants/why, context bar, badges) +
  header (New, ☕ keep-awake, 🔒 lock, 📊 insights, 📜 audit, ⚙ settings, theme, 🔍 search).
- **Detail panel** with a tab strip — Activity, Transcript, Rewind, Decisions, Usage, Changes
  (git status + diff), **User Stories** (gated on `spec/product/user-stories.md`), Agents, Queue —
  expensive tabs load on open; the ⋯ menu hides tabs and remembers your last-open tab per project.
- **Fleet navigation:** search, groups + group chips, bulk Approve/Stop/Nudge over the visible set.
- **Global hotkeys** (remappable): approve front, **jump-to-the-session-that-needs-you**, cycle,
  spawn, show/hide; a live legend so they never drift.
- **Worklist** (My List): a built-in per-project + global checklist.
- **Keep the fleet alive:** ☕ caffeinate (holds with the lid closed) + 🔒 soft lock (blocks input
  while everything keeps running; force-unlock chord so a typo can't lock you out).
- **Remote (SSH bridge):** rsync-pulled remote `cc-status/` renders remote sessions as headless-
  only ⇄ tiles (approve/deny via nonce-bound decision files; keystroke actions disabled).

## 11. Capability ladder (shipped, retrospective)

Shepherd grew in levels; these are the milestones as built, not a forward plan.

| # | Capability |
|---|------------|
| **L0** | The core loop: hooks → status files → tiles → approve/deny/jump/stop/nudge. |
| **L1** | **Agent profiles** — spawn from a saved persona + provider/model + skills/MCP/knowledge/plugins. |
| **L2** | **Named policy bundles** — reusable per-session guardrail sets + attachments. |
| **L3** | **Task templates** — parameterized, versioned prompts; render-before-spawn/feed. |
| **L4** | **Declarative routing** — queue-line `@role`/`@all`/`@any`/`seq`; shared-folder backlog drain. |
| **L5** | **Session observability** — error cause, plan/TODO, subagent fan-out, run score, banners. |
| **L6** | **Event-callback rules** — react to a done/error/approval edge with log/relabel/nudge. |
| **L7** | **Scheduled routines** — cron/one-shot spawn or fleet digest. |

Deferred (need a design call first): in-panel bundle/agent/template editors, a routing topology
view, role-addressed delegation/handoff, idle/auto-spawn routing targets, the routine board.

## 12. Risks & honest limits

1. **VS Code keystroke delivery is best-effort** — no supported injection API. Mitigated by
   Headless approvals (reliable) + Queue (reliable storage) + Kitty's `kitty @` path.
2. **Auto-actions could thrash** — respawn/continue are capped per launch folder, and budgets
   reset only after sustained healthy running; a session waiting on you is never auto-respawned.
3. **Stale/ghost tiles** after `/clear` — auto-pruned by matching old+new tiles to the same
   window; Forget tile is the always-safe manual escape.
4. **Usage is tokens, not dollars** — subscription is flat-rate; gateway/local pricing unknown.
   The $ figure is a labeled estimate; the plan-window % reflects the Anthropic account only.
5. **Remote Control widens the trust boundary** (on by default) — anyone on your claude.ai can
   type into a local shell; documented and toggle-able.

## 13. Verdict

Feasible and shipped on well-understood pieces (Hammerspoon, Claude Code hooks, a per-session
status file, a decision-file gate, `kitty @`, macOS Accessibility). The design's power is **where
state lives and who writes it**: hooks write status files, the panel writes decision files, and
everything else is a pure read — no daemon, no DB, crash-safe, inspectable. The one thing that
stays fragile by nature is **keystroke delivery into the VS Code extension**, which is why the
reliable spine is **headless approvals + queues + Kitty remote control**. Every automation is
**off by default**, every detector is **advisory not enforcing**, and the audit trail is **opt-in
and local** — so the tool earns trust before it acts.
