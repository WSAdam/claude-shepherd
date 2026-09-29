-- coverage.test.lua : the coverage index -- a batch built from an issue list says what it covers
-- (2026-09-29, build program unit 25). Pure core logic.
--
-- A batch may carry the issue list it was built from (issues[{id,title}]) and the issues it
-- decided not to build (triage[{id,as,note}], as = dup | wontfix | later | covered-elsewhere, a
-- note required); each unit's covers[] names the issues it covers. Every issue must be covered
-- by a unit or triaged before the batch can be approved: core.batchView lists the uncovered ids
-- and marks the proposal not approvable. A covers or triage id that isn't in the list refuses
-- the batch; a batch file without an issue list parses exactly as before.
--
-- Usage: lua tests/coverage.test.lua

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want) check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want) end
local function finish() print("-- coverage.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function ids(list) local t = {} for _, x in ipairs(list or {}) do t[#t + 1] = x.id end return table.concat(t, ",") end

-- A proposal as cc-fleet.sh writes it: three issues, two units; `over` replaces top-level fields,
-- `units` the units.
local ISSUES = { { id = "BUG-1", title = "Paste drops the last line" },
                 { id = "BUG-2", title = "The toast covers the Approve button" },
                 { id = "REQ-3", title = "Export the ledger as CSV" } }
local function bj(over, units)
  local t = { v = 1, id = "b1757", nonce = "n1", driver = { session_id = "drv", pid = "4242", name = "repo-drv" },
              repo = "/r/main", commonDir = "/r/main/.git", title = "Issue sweep", mergeWhenGreen = true,
              at = 100, phase = "proposed", issues = ISSUES,
              units = units or {
                { type = "fix", slug = "paste", task = "Fix paste.", branch = "fix/paste", covers = { "BUG-1" } },
                { type = "fix", slug = "toast", task = "Move the toast.", branch = "fix/toast", covers = { "BUG-2", "BUG-1" } } },
              triage = { { id = "REQ-3", as = "later", note = "Needs Adam's call on the columns" } } }
  for k, v in pairs(over or {}) do
    if v == "nil" then t[k] = nil else t[k] = v end
  end
  return core.json.encode(t)
end

-- ---- every issue covered or triaged (2026-09-29) ----
do
  local b = core.parseBatch(bj())
  check("parse: a batch with an issue list, covers and triage parses", b ~= nil)
  if not b then finish() end
  eq("parse: it keeps its issues, in order", ids(b.issues), "BUG-1,BUG-2,REQ-3")
  eq("parse: ...with their titles", b.issues[2].title, "The toast covers the Approve button")
  eq("parse: ...and its triage", b.triage and b.triage[1].id .. " " .. b.triage[1].as .. " " .. b.triage[1].note,
     "REQ-3 later Needs Adam's call on the columns")

  local c = core.batchCoverage(b)
  check("coverage: all covered or triaged -> nothing uncovered", c and #c.uncovered == 0)
  eq("coverage: ...counts every issue", c and c.total, 3)
  eq("coverage: ...the covered ones, in issue order", c and ids(c.covered), "BUG-1,BUG-2")
  eq("coverage: ...each with the units that cover it", c and table.concat(c.covered[1].by, ","), "paste,toast")
  eq("coverage: ...and the triaged one, with how and why", c and c.triaged[1] and (c.triaged[1].id .. " " .. c.triaged[1].as), "REQ-3 later")
  eq("approve: nothing holds an approval", core.batchApproveProblem(b), nil)
  local v = core.batchView(b, nil, {})
  check("view: the proposal is approvable", v.approvable == true)
  check("view: ...and says every issue is accounted for  (" .. tostring(v.coverage and v.coverage.line) .. ")",
        v.coverage and v.coverage.line == "✓ all 3 issues accounted for: 2 covered by units, 1 triaged")
  eq("view: ...with nothing uncovered", v.coverage and #v.coverage.uncovered, 0)
  eq("view: the card line doesn't mention coverage when it's complete", v.line, "⇉ proposes 2 units in main")
end

do
  -- REQ-3 is neither covered nor triaged
  local b = core.parseBatch(bj({ triage = "nil" }))
  check("parse: a batch with an uncovered issue still parses (the review shows it)", b ~= nil)
  if not b then finish() end
  local c = core.batchCoverage(b)
  eq("coverage: one uncovered issue is listed", c and ids(c.uncovered), "REQ-3")
  eq("coverage: ...with its title", c and c.uncovered[1] and c.uncovered[1].title, "Export the ledger as CSV")
  local why = core.batchApproveProblem(b)
  check("approve: an uncovered issue holds the approval, naming it  (" .. tostring(why) .. ")",
        why == "1 issue isn't covered by a unit or triaged: REQ-3")
  local v = core.batchView(b, nil, {})
  check("view: the proposal is not approvable", v.approvable == false)
  eq("view: ...its uncovered issues are listed", v.coverage and ids(v.coverage.uncovered), "REQ-3")
  eq("view: ...and titled", v.coverage and v.coverage.uncovered[1].title, "Export the ledger as CSV")
  eq("view: ...the review line says Approve waits", v.coverage and v.coverage.line,
     "⚠ 1 of 3 issues isn't covered by a unit or triaged — Approve waits until it is")
  eq("view: ...and the card line says so too", v.line, "⇉ proposes 2 units in main · 1 issue uncovered")

  local two = core.parseBatch(bj({ triage = "nil" }, {
    { type = "fix", slug = "paste", task = "Fix paste.", branch = "fix/paste", covers = { "BUG-1" } },
    { type = "fix", slug = "toast", task = "Move the toast.", branch = "fix/toast" } }))
  eq("coverage: two uncovered, in issue order", ids(core.batchCoverage(two).uncovered), "BUG-2,REQ-3")
  eq("approve: ...both named", core.batchApproveProblem(two), "2 issues aren't covered by a unit or triaged: BUG-2, REQ-3")
  local v2 = core.batchView(two, nil, {})
  eq("view: ...plural wording", v2.coverage.line, "⚠ 2 of 3 issues aren't covered by a unit or triaged — Approve waits until they are")
  eq("view: ...on the card too", v2.line, "⇉ proposes 2 units in main · 2 issues uncovered")
end

do
  -- every triage kind counts; an issue both covered and triaged counts as covered
  for _, as in ipairs({ "dup", "wontfix", "later", "covered-elsewhere" }) do
    local b = core.parseBatch(bj({ triage = { { id = "REQ-3", as = as, note = "why" } } }))
    check("triage: '" .. as .. "' accounts for an issue", b and #core.batchCoverage(b).uncovered == 0)
  end
  local b = core.parseBatch(bj({ triage = { { id = "BUG-1", as = "dup", note = "same as BUG-2" },
                                           { id = "REQ-3", as = "wontfix", note = "not ours" } } }))
  local c = b and core.batchCoverage(b)
  check("triage: an issue a unit covers counts as covered, not triaged",
        c and ids(c.covered) == "BUG-1,BUG-2" and ids(c.triaged) == "REQ-3")
  local all = core.parseBatch(bj({ triage = { { id = "BUG-1", as = "dup", note = "n" }, { id = "BUG-2", as = "later", note = "n" },
                                              { id = "REQ-3", as = "wontfix", note = "n" } } },
    { { type = "docs", slug = "notes", task = "Write it down.", branch = "docs/notes" } }))
  check("triage: a batch whose every issue is triaged is approvable", all and core.batchView(all, nil, {}).approvable == true)
end

-- ---- a bad id refuses the batch (2026-09-29) ----
do
  local function unitCovering(...) return { { type = "fix", slug = "paste", task = "t", branch = "fix/paste", covers = { ... } } } end
  for what, raw in pairs({
    ["a unit covering an id that isn't in the issue list"] = bj(nil, unitCovering("BUG-1", "BUG-9")),
    ["a triage id that isn't in the issue list"] = bj({ triage = { { id = "BUG-9", as = "dup", note = "n" } } }),
    ["triage with no issue list"] = bj({ issues = "nil" }),
    ["a triage kind that isn't dup/wontfix/later/covered-elsewhere"] = bj({ triage = { { id = "REQ-3", as = "maybe", note = "n" } } }),
    ["a triage entry with no note"] = bj({ triage = { { id = "REQ-3", as = "later" } } }),
    ["a triage entry with an empty note"] = bj({ triage = { { id = "REQ-3", as = "later", note = "" } } }),
    ["the same issue triaged twice"] = bj({ triage = { { id = "REQ-3", as = "later", note = "n" }, { id = "REQ-3", as = "dup", note = "n" } } }),
    ["an issue list that isn't a list"] = bj({ issues = { id = "BUG-1", title = "x" } }),
    ["an empty issue list"] = bj({ issues = {}, triage = "nil" }, { { type = "fix", slug = "paste", task = "t", branch = "fix/paste" } }),
    ["the same issue id twice"] = bj({ issues = { ISSUES[1], ISSUES[1], ISSUES[2], ISSUES[3] } }),
    ["an issue id with shell characters"] = bj({ issues = { ISSUES[1], ISSUES[2], ISSUES[3], { id = "X; rm -rf /", title = "x" } } }),
    ["an issue with no title"] = bj({ issues = { ISSUES[1], ISSUES[2], { id = "REQ-3" } } }),
    ["triage that isn't a list"] = bj({ triage = { id = "REQ-3", as = "later", note = "n" } }),
  }) do
    check("refuses " .. what, core.parseBatch(raw) == nil)
  end
  local why = core.batchCoverageProblem(ISSUES, nil, unitCovering("BUG-9"))
  check("problem: a bad cover names the unit and the id  (" .. tostring(why) .. ")",
        why == "unit paste covers 'BUG-9', which isn't one of the batch's issues")
  why = core.batchCoverageProblem(ISSUES, { { id = "BUG-9", as = "dup", note = "n" } }, {})
  check("problem: a bad triage id is named  (" .. tostring(why) .. ")",
        why == "triage names 'BUG-9', which isn't one of the batch's issues")
  why = core.batchCoverageProblem(nil, { { id = "BUG-1", as = "dup", note = "n" } }, {})
  check("problem: triage with no issue list says so  (" .. tostring(why) .. ")",
        why == "triage names 'BUG-1', which isn't one of the batch's issues")
  eq("problem: a sound batch has none", core.batchCoverageProblem(ISSUES, { { id = "REQ-3", as = "later", note = "n" } },
     unitCovering("BUG-1", "BUG-2")), nil)
end

-- ---- old batch files parse as before (2026-09-29) ----
do
  local old = core.parseBatch(core.json.encode({ v = 1, id = "b1", nonce = "n1", driver = { session_id = "drv" },
    repo = "/r/main", commonDir = "/r/main/.git", title = "Old", phase = "proposed", at = 1,
    units = { { type = "feat", slug = "alpha", task = "t", branch = "feat/alpha" } } }))
  check("old: a batch file with no issue list still parses", old ~= nil)
  check("old: ...has no coverage", old and core.batchCoverage(old) == nil and old.issues == nil and old.triage == nil)
  check("old: ...nothing holds its approval", old and core.batchApproveProblem(old) == nil)
  local v = old and core.batchView(old, nil, {})
  check("old: ...its view is approvable, with no coverage block", v and v.approvable == true and v.coverage == nil)
  -- unit 24 let covers ride along with no issue list; that still works
  local free = core.parseBatch(bj({ issues = "nil", triage = "nil" }))
  check("old: covers with no issue list are free-form, as unit 24 shipped them", free ~= nil and core.batchCoverage(free) == nil)
end

finish()
