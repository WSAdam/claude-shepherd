# Handoff: Generating User Stories from an Existing Codebase (rune-aware)

A reusable playbook for **reverse-engineering** `spec/product/user-stories.md` (and its
companion `spec/product/spec.md`) from a project that **already has code** — when there's
no scoping doc to start from. Doubly relevant when the project **already uses rune**, where
the stories are the test-first seam the whole pipeline hangs off.

This is the manual companion to the **`rune:scope`** skill. `rune:scope` drives this
*interactively* for a new idea; this doc is the recipe for the *retrofit* case — an app that
exists and needs its intent layer recovered, faithfully, after the fact.

> Lives in the Claude Shepherd repo because Shepherd's **User Stories tab** views/edits these
> files, but the playbook is **project-portable** — drop the output into any repo.

---

## 1. When to use this

- An existing app has no `spec/product/spec.md` / `user-stories.md` and you want them.
- A **rune** project was built without stories (or grew past them) and you need to
  retrofit the intent layer so specs + tests have a home and stay aligned with intent.
- You're setting up a **scope ⇄ code round-trip** check and need the reverse direction
  (app → stories → spec) to be faithful and canonical.

## 2. What you produce (the output contract)

Two files, fixed paths, signed off by a human before anything downstream consumes them:

| File | Purpose |
|------|---------|
| `spec/product/spec.md` | The product intent: thesis, goals/non-goals, the core mechanism, data model, milestones, **resolved decisions**, verdict. The stories' traced home. |
| `spec/product/user-stories.md` | Stories grouped by capability area, each in canonical form, each traceable to a goal in `spec.md`. |

Derive `spec.md` **first** (it gives every story a "so that" to point at), then the stories.

## 3. Canonical format (what rune:scope and the Shepherd tab both expect)

```markdown
# <Product> — User Stories

User stories derived from [spec.md](./spec.md). Roles: <list them in prose, not bullets>.

## <Capability area>

- As a **<role>**, I want <capability>, so that <benefit>.
- As a **<role>**, I want <capability>, so that <benefit>.

## <Next capability area>

- ...
```

Rules:

- **`## ` headings are capability areas** — and the *only* thing treated as an area.
- **`- ` / `* ` bullets are stories.** One story = **one line**.
- **Canonical shape, every story:** `As a <role>, I want <capability>, so that <benefit>`.
  The **"so that" is mandatory** — a story without it is incomplete (and the Shepherd tab
  flags it with a soft ⚠).
- **Trace every story to a goal** in `spec.md`. If a story serves no goal, either the goal
  is missing from `spec.md` or the story isn't real.
- **One story per discrete, demoable capability.** Small. If it needs "and", it's two stories.
- **Group reference data (DTOs/validation/infra) into the story it serves** — those aren't
  their own user stories.

## 4. Shepherd User Stories tab — parser facts & gotchas

These are exact behaviors of the parser the tab uses (`cc-core.lua`
`parseUserStories`/`serializeUserStories`). Author to them and the file round-trips cleanly.

- **Only `## ` (exactly two hashes + a space) is an area.** A `# ` title and any `### `
  sub-heading are **not** areas — they're preserved as prose. Use `#` once for the title;
  use `##` for every area.
- **ANY line starting with `- ` or `* ` (up to 3 leading spaces) is parsed as a story.**
  ⚠ **The #1 gotcha:** a bullet list in your intro/roles block becomes phantom, malformed
  "stories" grouped under no area. **Write the intro and the role list as prose**, never as
  `-`/`*` bullets.
- **Newlines inside a story collapse to one space on save** — a story is always one line.
- **Non-story content is preserved verbatim** — title, intro, `##` headings, prose, and
  fenced code blocks all round-trip byte-for-byte if untouched. (Even `- ` lines *inside*
  a ```` ``` ```` fence are kept raw, so code samples won't be eaten as stories.)
- **`*` markers and CRLF line endings are preserved**; the well-formed check is lenient and
  case-insensitive (it looks for `as a` + `i want`/`i'd like` + `so that` as substrings).
- **Saves are safe:** hash-guarded against an external edit, atomic (temp + rename), and a
  save that would write an empty file over a non-empty one is refused.
- **The tab is gated on the file existing** at `<session cwd>/spec/product/user-stories.md`.
  Create the file and the tab appears within ~1s; delete it and the tab disappears. No
  reload needed.

## 5. Roles

Keep a **tight, consistent vocabulary** — usually 2–4 roles. List them in `spec.md` and in
the stories' prose intro. Bold them in stories (`As a **operator**, …`) to match the
canonical style. Don't invent a new role per story; reuse the few that matter. If two
"roles" always do the same things, they're one role.

## 6. The procedure

### Step 0 — Set up
- Ensure `spec/product/` exists. (`mkdir -p spec/product`.)

### Step 1 — Inventory the surface (sources, in priority order)
1. **Product docs** — README / changelog / design notes. Usually the highest-signal,
   most-current description of *intent*. Section headings often map straight to capability areas.
2. **The running app** — actual behavior. Catches what docs gloss.
3. **The code** — ground truth, and the tiebreaker. **For rune projects, the `.rune` specs
   are the richest source — read them before the implementation** (see §7).
- **Omit what isn't shipped.** Capabilities still in design belong (if anywhere) as a
  "deferred" note in `spec.md`, never as a user story.

### Step 2 — Derive `spec.md` (canonical sections)
Thesis → Goals / Non-goals → **the core mechanism ("the heart")** → architecture & data
model → milestones (the capability ladder, retrospective for a shipped app) → **resolved
decisions** (`[DECISION]` — the choices already made + *why*; this is the most valuable part
to recover) → risks & honest limits → verdict. Mark it "reverse-engineered from the shipped
app", not a forward draft. See the worked example in this repo: [spec.md](../spec/product/spec.md).

### Step 3 — Derive `user-stories.md`
- One `##` area per capability area (for rune, per `[MOD]` / feature module).
- Walk each area; write one canonical story per demoable capability.
- Make each "so that" point at a real `spec.md` goal.
- Header is prose (link `spec.md`, name the roles) — **no bullets in the intro**.

### Step 4 — Verify (don't trust it by eye — see §8)
- Parse, round-trip, and well-formed-check the file.
- For rune: confirm each story maps to a real endpoint, and each endpoint has ≥1 story.

### Step 5 — Sign-off
- A human reviews and signs off. Only then does it feed `rune:spec` (or get committed).

## 7. The rune track (if the project already uses rune)

rune expects **user stories before any `.rune`** — they're the **test-first foundation**:
one story → one `[REQ]` endpoint → its tests. On an existing rune project with no stories,
**reverse-engineer `spec.md` + `user-stories.md` from the app first**, so the specs and tests
have a home and stay tied to intent.

**Read `spec/runes/*.rune` (and `src/`) before the implementation — it's already structured
intent.** Map it like this:

| rune construct | Maps to | Notes |
|----------------|---------|-------|
| `[MOD]` module | a **`##` capability area** | the natural grouping |
| `[REQ]` / `[ENT]` endpoint (`@ METHOD /path`) | **one user story** | the core seam: story ↔ endpoint ↔ its tests |
| `[NEW]`/`[CTR]`/`[PLY]` steps inside an endpoint | the *capability* phrasing | what the story lets the role do |
| `[DTO]` / `[TYP]` (validators, `from=`, `example=`) | the data/validation the story implies | **fold into the story**, don't make them stories |
| `[SRV]` backing service (`core.rune` + `@docs`) | an external dependency | usually a non-goal/infra note in `spec.md`, not a story |

- Phrase the **capability** from what the endpoint does; phrase the **benefit** ("so that")
  from the `spec.md` goal that endpoint serves. If there's no `spec.md` yet, recover the goal
  from the product thesis first (Step 2).
- Skip `*.in-prog.rune` drafts (half-finished specs auto-skipped by rune) unless you're
  deliberately capturing in-flight work — and if so, mark those stories as not-yet-shipped.

**Why the clean story ↔ endpoint mapping matters:** it's what makes a **scope ⇄ code
round-trip** measurable. The fidelity oracle isn't "did `rune:build` go green" — a rebuild is
always green against its *own* regenerated tests (`rune:build` writes the tests from the spec,
then fills bodies until `rune lint --strict` passes; that's circular). The real check is the
**original `spec/misc/cake.json` endpoint expectations (rune:cake) run unchanged against the
regenerated code** — green = behaviorally equivalent on what the original covered, red = a
located drift to fix. That oracle only works if stories map 1:1 to endpoints, so the cake has
something stable to grade. (Favor a project that already has a populated `cake.json`; if it
doesn't, building those expectations is step zero of any round-trip.)

## 8. Verification (mechanical, not by eye)

**Route A — the Shepherd tab (visual).** Open the project's tile → **User Stories** tab. Every
story should sit under the right `##` area, and **no story should show a ⚠** (each has its "so
that"). No stray "stories" before the first heading = your intro is clean prose.

**Route B — standalone (CI-style), against Shepherd's parser.** Point this at any
`user-stories.md`; it parses, round-trips, and well-formed-checks every story:

```lua
-- verify.lua — run: lua verify.lua <path-to-user-stories.md>
local CORE = "/Users/adam/Programming/claude-instance-manager/cc-core.lua"
local core = dofile(CORE)
local path = assert(arg[1], "usage: lua verify.lua <user-stories.md>")
local f = assert(io.open(path)); local text = f:read("*a"); f:close()
local doc = core.parseUserStories(text)
print(("areas=%d  stories=%d"):format(#doc.areas, #doc.stories))
print("round-trips byte-for-byte: " ..
      tostring(core.serializeUserStories(doc.blocks) == text))
local bad = 0
for _, s in ipairs(doc.stories) do
  if not core.userStoryWellFormed(s.text) then
    bad = bad + 1; print("  ⚠ ["..s.area.."] "..s.text)
  end
end
print("missing 'so that' (or As a / I want): "..bad)
```

Pass criteria: **round-trips byte-for-byte = true**, **missing = 0**, and `areas`/`stories`
counts match what you intended (a surprise count usually means an intro bullet leaked in as a
story, or an area heading used the wrong number of `#`).

## 9. Quality checklist

- [ ] `spec.md` written first; every story's "so that" traces to one of its goals.
- [ ] Intro and role list are **prose, not bullets** (no phantom stories).
- [ ] Exactly one `#` title; every area is `## ` (not `#`, not `###`).
- [ ] One demoable capability per story; no "and"; reference data folded in.
- [ ] Tight, consistent, bolded role vocabulary (2–4 roles).
- [ ] Unshipped/in-design work omitted (or clearly marked deferred in `spec.md`).
- [ ] **rune:** each story ↔ a real `[REQ]`/`[ENT]`; each endpoint ↔ ≥1 story; `[DTO]`/`[SRV]`
      not turned into stories.
- [ ] Verified: round-trips byte-for-byte, 0 ⚠, area/story counts as intended.
- [ ] Human sign-off before it feeds `rune:spec` or gets committed.

## 10. References

- **Skills:** `rune:scope` (idea → `spec.md` + `user-stories.md`), `rune:spec` (prose → `.rune`),
  `rune:cake` (endpoint expectations / the round-trip oracle), `rune:build` (spec → tested code).
- **Canonical examples:** `~/.claude/skills/rune:scope/references/example-spec.md` and
  `example-user-stories.md`.
- **Worked output in this repo:** [spec/product/spec.md](../spec/product/spec.md) and
  [spec/product/user-stories.md](../spec/product/user-stories.md) — Shepherd reverse-engineered
  with this playbook (note: Shepherd is Lua/Hammerspoon, **not** a rune target, so its files are
  the *format* reference, not a round-trip subject).
