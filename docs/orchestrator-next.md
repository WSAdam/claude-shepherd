# Orchestrator — Phase 4b/4c design spec

Status: **mostly shipped.** Phase 4b (queue + auto-feed) and Phase 4c **A–D**
(stale-approval escalation, approve-repeats, per-session autopilot, pattern
auto-allow/deny) are built and live; **4c-E (project routing)** is the only deferred
piece. This file is retained as the original design rationale — the authoritative,
**current** config schema is [cc-config.example.json](../cc-config.example.json), and
CHANGELOG.md records what has shipped since (incl. the audit ledger, fleet insights,
collision warning, per-session gating, risk score, drain/respawn, and the fleet-scale
console — tile search, session groups, bulk actions, per-session timeline, auto-respawn,
insights sparklines, the stuck-session watchdog, and the API-error "Error" state with
one-click Continue recovery).

## Goal

Turn Claude Shepherd from a *supervisor* into a *dispatcher*: keep a fleet working by
auto-feeding queued work (4b), and cut hands-on oversight with **safe, opt-in** policies
(4c). Same idiom as everything else: pure logic in [cc-core.lua](../cc-core.lua)
(unit-tested), effects through the `fx` table (recorder in tests, dry-run flags in
prod), permission policy evaluated at the gate ([cc-approve.sh](../cc-approve.sh)).

Guiding principles: **off by default, opt-in, logged when automatic, visible on
the tile, and dry-run-able.** Nothing here should ever surprise you.

---

## Configuration — one settings file, everything off by default

All new auto/policy behavior is governed by a single JSON settings file read by
**both** the panel (Lua) and the gate (bash). It does not exist until you create
it, and every field is conservative — **nothing auto-acts unless you explicitly
turn it on.**

`~/.claude/cc-config.json` — the **4b/4c subset** below was the original design; the
file has since grown more blocks (`gate`, `spawn`, `providers`, `focus`, `ledger`,
`risk`, `collision`, `drain`, `respawn`, `insights`). See
[cc-config.example.json](../cc-config.example.json) for the full current schema. These
ARE the defaults if the file is absent or a key is missing:
```json
{
  "queue":      { "autofeed": false, "dryRun": false },
  "escalation": { "enabled": false, "minutes": 5, "sound": false, "push": false,
                  "pushTopic": "" },
  "policies": {
    "approveRepeats": false,
    "autopilot":      { "enabled": false, "minutes": 15 },
    "patterns":       { "enabled": false, "autoAllow": [], "autoDeny": [] }
  }
}
```

- **Loader:** `cc-lib.sh` adds `cc_config <jq-path> <default>` (bash, via jq);
  `cc-core.lua` adds `M.config(tbl, path, default)` (pure, over a decoded table).
  Both are unit-tested; both treat a missing file/key as the default.
- A starter `cc-config.example.json` ships in the repo and is documented in the
  README, so the toggles are discoverable.
- The existing `~/.claude/cc-gate.enabled` flag-file keeps working (it just turns
  the gate on); the new policies live in `cc-config.json`.

---

## Phase 4b — Per-session task queue + auto-feed

You line up follow-up tasks for a session; when it finishes, Claude Shepherd feeds the
next one automatically (via the same focus+type nudge), so a session chews through
a backlog unattended.

### Data model
`~/.claude/cc-queue/<key>.json` (separate dir, so the status reader is untouched):
```json
{ "tasks": ["write tests for auth.ts", "run the suite", "open a PR"] }
```
- `tasks`: ordered prompts to feed, front first.
- **Auto-feeding is off until you enable `queue.autofeed`** in `cc-config.json`.
  Until then the queue just holds tasks and a **"Feed next"** button (detail panel)
  feeds the front task on demand. With autofeed on, the front task feeds itself
  when the session goes done/idle.

### cc-core (pure, tested)
- `queuePush(q, task) -> q'`   `queuePop(q) -> task, q'`   `queueDepth(q)`
- `shouldFeed(prev, cur, q, autoOn) -> bool` — true **only** on a fresh transition
  into `done`/idle-ready, with `depth>0` and `autoOn` (from `queue.autofeed`). The
  anti-double-feed guard and the key tested decision. With autofeed off it's always
  false (manual feed only).

### Effects (fx)
- `fx.feedTask(name, task)` → reuses `fx.typeIntoWindow` (focus, type, Enter,
  restore focus).
- `fx.readQueue(key)` / `fx.writeQueue(key, q)` → file I/O (recorder in tests).

### Bootstrap wiring
`refresh()` tracks `prevStatus[key]`. Per session: read queue; if
`core.shouldFeed(prev, cur, q, q.auto)` → pop, `fx.feedTask`, write back, log.
Config: `QUEUE_AUTOFEED` (default on), `QUEUE_DRY_RUN` (logs instead of feeding).

### UX
- Tile badge: queue depth (e.g. `+3`).
- Detail panel: list queued tasks with remove buttons, plus a "Queue" input
  (same row as Nudge, but **adds** instead of sending now), and an `auto` toggle.

### Edge cases / safety
- Feeds only on the done→ transition, never repeatedly while idle.
- Brief focus-steal per feed (restored) — acceptable in opt-in auto-mode; documented.
- Skips stale/closed sessions (no window to focus).
- A fed task may itself hit approvals — that's just the normal gate/panel flow.

### Tests
- `shouldFeed`: done+queue→true; still-done next tick→false; done+empty→false; auto off→false.
- queue push/pop/depth.
- Recorder: simulated done transition → `fx.feedTask` with the right task; queue dequeued.

---

## Phase 4c — Policies (a menu; pick what to build)

Ordered by safety. Note: Claude Code already auto-allows its native
`permissions.allow` list *before* the gate, so these only act on prompts that
actually **reach** Claude Shepherd.

### A. Stale-approval escalation  — *safe, high value*
A session sitting in `approval` > `escalation.minutes` unanswered gets escalated.
No auto-decision — just nags harder. `cc-core.isStale(item, now, threshold)`.
Governed by `cc-config.json > escalation`: master `enabled:false`, plus two
independent channels both **off by default** — `sound:false` (panel chime) and
`push:false` (high-priority ntfy to `pushTopic`). Enabled-with-both-off = just a
stronger visual pulse.

### B. Auto-approve repeats  — *medium, consent-based*
If you already approved the *exact* command in this session, auto-approve it next
time (kills repetitive prompts). The gate consults a per-session approved-set
(`~/.claude/cc-approved/<key>`). You approved it once = consent. Opt-in.

### C. Per-session autopilot  — *scoped trust*
Toggle a session into autopilot: the gate auto-approves **all** its prompts for a
**time-boxed** window (auto-expires after N min), with a loud `AUTOPILOT` badge on
the tile. Per-session, visible, expiring. Riskier than A/B but bounded.

### D. Pattern auto-approve/deny  — *riskiest*
`~/.claude/cc-policy.json` globs the gate honors (autoDeny→deny, autoAllow→allow).
Overlaps Claude Code's native allow/deny — prefer native for global rules; reserve
this for Claude Shepherd-only nuance. Off by default, empty.

### E. Project routing  — *separate, bigger*
A project task pool: tasks tagged by project get fed to whichever session in that
project is free. Extends 4b's per-session queue to load-balance parallel work.

### Where policy runs
A/B/C/D evaluate at the **gate** (cc-approve.sh) before routing to the panel; the
matching logic is tested in the bash gate suite, per-session state in small files.
Every policy: **off by default, logged when it fires, and the panel shows when a
decision was automatic** ("auto-approved by policy"/"autopilot").

---

## Decided (this review)
- **Queue scope:** per-session only. (Project routing / E deferred.)
- **Policies to build:** **all of A, B, C, D** — but every one **off by default**
  in `cc-config.json`, each requiring an explicit opt-in.
- **Escalation:** build **both** channels (panel sound + ntfy push), **both off by
  default**, each its own toggle.
- **Everything** auto/policy lives in `cc-config.json` with conservative defaults;
  the panel and gate both read it; a `cc-config.example.json` documents the knobs.

## Build order
1. **Config foundation** — `cc-config.json` loader in `cc-lib.sh` + `cc-core.lua`
   (tested, missing-file-safe) + `cc-config.example.json` + README. Everything below
   reads it.
2. **4b queue** — `cc-queue/<key>.json`, `queue*`/`shouldFeed` in cc-core,
   `fx.feedTask`, depth badge, "Feed next" + queue UI. Autofeed gated by config (off).
3. **A escalation** — `isStale` in cc-core; panel pulse always, sound/push per config.
4. **B approve-repeats** — gate consults a per-session approved-set; opt-in.
5. **C autopilot** — per-session, time-boxed, loud badge; opt-in.
6. **D patterns** — gate honors `policies.patterns` globs; opt-in, empty by default.

Each step: cc-core/gate logic unit-tested with the recorder/temp-dir harness, then
deployed, then a live check. Same loop as Phases 0–4a.
