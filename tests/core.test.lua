-- core.test.lua : standalone unit tests for cc-core.lua. Run with plain `lua`.
-- No Hammerspoon, no side effects: JSON via the vendored parser, effects via the
-- recorder. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")
local newRecorder = dofile(HERE .. "support/fx_recorder.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then
    print("ok   - " .. name)
  else
    failed = failed + 1
    print("FAIL - " .. name)
  end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

local function entry(key, tbl) return { key = key, content = core.json.encode(tbl) } end

-- ---- parseStatusList: decode + stale + approvals-first sort ----------------
do
  local now = 10000
  local entries = {
    entry("a", { name = "alpha",   status = "idle",     updated = now }),
    entry("b", { name = "bravo",   status = "approval", updated = now }),
    entry("c", { name = "charlie", status = "working",  updated = now - 1000 }), -- stale
    entry("d", { name = "delta",   status = "done",     updated = now }),
    { key = "junk", content = "{ not json" },             -- dropped (malformed)
    entry("e", { status = "idle", updated = now }),        -- dropped (no name)
  }
  local list = core.parseStatusList(entries, now, 90)
  eq("parse: keeps 4 valid entries", #list, 4)
  eq("parse: approval sorts first", list[1].status, "approval")
  eq("parse: approval is bravo", list[1].name, "bravo")
  eq("parse: key tagged", list[1].key, "b")
  -- find charlie and assert stale; alpha not stale
  local charlie, alpha
  for _, it in ipairs(list) do
    if it.name == "charlie" then charlie = it end
    if it.name == "alpha" then alpha = it end
  end
  eq("parse: old entry is stale", charlie.stale, true)
  eq("parse: fresh entry not stale", alpha.stale, false)
end

-- ---- resolveGesture: gate-aware short/long press ---------------------------
do
  local waiting = { gate = "waiting" }
  local normal  = {}
  eq("gesture: waiting + short = approve", core.resolveGesture(waiting, "primary"), "approve")
  eq("gesture: waiting + long  = deny",    core.resolveGesture(waiting, "secondary"), "deny")
  eq("gesture: normal  + short = focus",   core.resolveGesture(normal, "primary"), "focus")
  eq("gesture: normal  + long  = focus (default)", core.resolveGesture(normal, "secondary"), "focus")
  eq("gesture: normal  + long  = stop (opt-in)",
     core.resolveGesture(normal, "secondary", { longPressStops = true }), "stop")
end

-- ---- handleAction: routes to the right effect, gate-aware ------------------
do
  local waiting = { key = "w1", name = "proj-w", gate = "waiting" }
  local normal  = { key = "n1", name = "proj-n" }

  local r = newRecorder()
  core.handleAction(r.fx, waiting, "approve")
  eq("approve(waiting): writeDecision op", r.last().op, "writeDecision")
  eq("approve(waiting): allow value", r.last().b, "allow")

  r = newRecorder()
  core.handleAction(r.fx, normal, "approve")
  eq("approve(normal): actOnWindow op", r.last().op, "actOnWindow")
  eq("approve(normal): targets window name", r.last().a, "proj-n")
  eq("approve(normal): uses APPROVE key", r.last().b.key, "return")

  r = newRecorder()
  core.handleAction(r.fx, waiting, "deny")
  eq("deny(waiting): writeDecision deny", r.last().b, "deny")

  r = newRecorder()
  core.handleAction(r.fx, normal, "deny")
  eq("deny(normal): uses DENY key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "stop")
  eq("stop: actOnWindow", r.last().op, "actOnWindow")
  eq("stop: uses STOP key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "run the tests")
  eq("nudge: typeIntoWindow op", r.last().op, "typeIntoWindow")
  eq("nudge: passes text", r.last().b, "run the tests")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "")
  eq("nudge: empty text is a no-op", r.count(), 0)

  r = newRecorder()
  core.handleAction(r.fx, normal, "focus")
  eq("focus: focusWindow op", r.last().op, "focusWindow")
  eq("focus: targets name", r.last().a, "proj-n")
end

-- ---- deckLayout: row-major fill + overflow ---------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  local lay = core.deckLayout(2, list)
  eq("deck: fills 2 keys", lay.items[1].key, "a")
  eq("deck: 2nd key", lay.items[2].key, "b")
  eq("deck: no 3rd key", lay.items[3], nil)
  eq("deck: overflow counts the rest", lay.overflow, 1)

  local lay2 = core.deckLayout(15, list)
  eq("deck: no overflow when room", lay2.overflow, 0)
  eq("deck: empty keys are nil", lay2.items[4], nil)
end

-- ---- hotkey helpers --------------------------------------------------------
do
  local list = {
    { name = "a", status = "done" },
    { name = "b", status = "approval" },
    { name = "c", status = "approval" },
  }
  eq("nextApproval: first approval", core.nextApproval(list).name, "b")
  eq("frontSession: first item", core.frontSession(list).name, "a")
  eq("nextApproval: none -> nil", core.nextApproval({ { status = "idle" } }), nil)
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
