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

-- ---- config: dotted lookup with safe defaults ------------------------------
do
  local cfg = core.json.decode(
    '{"queue":{"autofeed":true},"policies":{"approveRepeats":false,"autopilot":{"minutes":15}}}')
  eq("config: nested true", core.config(cfg, "queue.autofeed", false), true)
  eq("config: false preserved (not default)", core.config(cfg, "policies.approveRepeats", true), false)
  eq("config: missing key -> default", core.config(cfg, "policies.patterns.enabled", false), false)
  eq("config: deep value", core.config(cfg, "policies.autopilot.minutes", 0), 15)
  eq("config: nil table -> default", core.config(nil, "a.b", "d"), "d")
end

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
  local normal  = { key = "n1", name = "proj-n", cwd = "/Users/x/proj-n" }

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
  eq("nudge: pasteIntoWindow op", r.last().op, "pasteIntoWindow")
  eq("nudge: passes text in payload", r.last().b.text, "run the tests")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "")
  eq("nudge: empty text is a no-op", r.count(), 0)

  r = newRecorder()
  core.handleAction(r.fx, normal, "focus")
  eq("focus: focusWindow op", r.last().op, "focusWindow")
  eq("focus: targets name", r.last().a, "proj-n")
  eq("focus: passes cwd for ancestor matching", r.last().b, "/Users/x/proj-n")
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

-- ---- cycleNext: wrapping jump target ---------------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  eq("cycle: nil start -> first", core.cycleNext(list, nil).key, "a")
  eq("cycle: after a -> b", core.cycleNext(list, "a").key, "b")
  eq("cycle: after c wraps -> a", core.cycleNext(list, "c").key, "a")
  eq("cycle: unknown key -> first", core.cycleNext(list, "zzz").key, "a")
  eq("cycle: empty list -> nil", core.cycleNext({}, "a"), nil)
end

-- ---- hotkey wiring: front approval -> approve via recorder -----------------
do
  local list = {
    { key = "w", name = "proj-w", status = "approval", gate = "waiting" },
    { key = "n", name = "proj-n", status = "working" },
  }
  local r = newRecorder()
  local target = core.nextApproval(list)
  core.handleAction(r.fx, target, "approve")
  eq("hotkey approve-front: targets the approval", target.key, "w")
  eq("hotkey approve-front: hands-free writeDecision", r.last().op, "writeDecision")
  eq("hotkey approve-front: allow", r.last().b, "allow")
end

-- ---- transcriptSnippet: latest assistant text from a jsonl tail -----------
do
  local function aline(text) -- an assistant line carrying one text block
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end
  local function toolline() -- an assistant line that is only a tool_use
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "tool_use", name = "Bash" } } } })
  end
  local userline = core.json.encode({ type = "user", message = { role = "user" } })

  -- last assistant text is "Refactoring the parser", even though a tool_use
  -- line and a user line come after it.
  local jsonl = table.concat({
    userline,
    aline("Refactoring the parser   now"),
    toolline(),
  }, "\n")
  eq("snippet: finds last assistant text (whitespace collapsed)",
     core.transcriptSnippet(jsonl), "Refactoring the parser now")

  eq("snippet: empty input -> nil", core.transcriptSnippet(""), nil)
  eq("snippet: no assistant text -> nil",
     core.transcriptSnippet(userline .. "\n" .. toolline()), nil)
  eq("snippet: garbled lines are skipped",
     core.transcriptSnippet("{ not json\n" .. aline("hello")), "hello")

  local long = string.rep("x", 300)
  local snip = core.transcriptSnippet(aline(long), 140)
  check("snippet: truncated to maxLen", #snip <= 140)
end

-- ---- Task queue: push / pop / depth / shouldFeed --------------------------
do
  eq("queue: push onto empty", core.queueDepth(core.queuePush(nil, "a")), 1)
  local q = core.queuePush(core.queuePush(nil, "a"), "b")
  eq("queue: depth after two pushes", core.queueDepth(q), 2)
  local first, rest = core.queuePop(q)
  eq("queue: pop returns front", first, "a")
  eq("queue: pop leaves the rest", core.queueDepth(rest), 1)
  eq("queue: pop next is b", (core.queuePop(rest)), "b")
  local none = core.queuePop({ tasks = {} })
  eq("queue: pop empty -> nil", none, nil)
  eq("queue: push ignores empty task", core.queueDepth(core.queuePush(nil, "")), 0)

  local q1 = { tasks = { "next" } }
  eq("feed: done transition with queue+auto -> true", core.shouldFeed("working", "done", q1, true), true)
  eq("feed: still done (no fresh transition) -> false", core.shouldFeed("done", "done", q1, true), false)
  eq("feed: empty queue -> false", core.shouldFeed("working", "done", { tasks = {} }, true), false)
  eq("feed: autofeed off -> false", core.shouldFeed("working", "done", q1, false), false)
  eq("feed: not done -> false", core.shouldFeed("working", "working", q1, true), false)
end

-- ---- shouldPrune: orphan + ghost cleanup ----------------------------------
do
  local opts = { pruneNoSid = true, pruneSeconds = 86400 }
  -- orphan: stale tile with no session_id
  local orphan = { stale = true, session_id = "", updated = 100 }
  eq("prune: stale + no session_id -> true", core.shouldPrune(orphan, 1000, opts), true)
  -- real session, stale but has a session_id, within the ghost window -> keep
  local realStale = { stale = true, session_id = "abc", updated = 1000 }
  eq("prune: stale but has session_id (recent) -> false", core.shouldPrune(realStale, 2000, opts), false)
  -- ghost backstop: very old even with a session_id
  local ghost = { stale = true, session_id = "abc", updated = 0 }
  eq("prune: older than backstop -> true", core.shouldPrune(ghost, 90000, opts), true)
  -- fresh, valid -> keep
  local fresh = { stale = false, session_id = "abc", updated = 1000 }
  eq("prune: fresh valid -> false", core.shouldPrune(fresh, 1010, opts), false)
  -- pruneNoSid off -> no orphan prune
  eq("prune: orphan kept when pruneNoSid off",
     core.shouldPrune(orphan, 1000, { pruneNoSid = false, pruneSeconds = 0 }), false)
end

-- ---- Policy A: approvalStale ----------------------------------------------
do
  eq("escalate: fresh approval -> false", core.approvalStale({ status = "approval", since = 100 }, 150, 60), false)
  eq("escalate: old approval -> true", core.approvalStale({ status = "approval", since = 100 }, 200, 60), true)
  eq("escalate: non-approval -> false", core.approvalStale({ status = "working", since = 0 }, 999, 60), false)
end

-- ---- Orchestrator: spawn command building + shell escaping ----------------
do
  eq("spawn: inner basic", core.spawnInner("/p", "hi"), "cd '/p' && claude 'hi'")
  eq("spawn: inner without a prompt", core.spawnInner("/p", ""), "cd '/p' && claude")
  -- a path with a space and a prompt with a single quote must stay safe
  eq("spawn: inner escapes single quotes",
     core.spawnInner("/my proj", "it's broken"),
     "cd '/my proj' && claude 'it'\\''s broken'")

  local as = core.spawnAppleScript("/p", "hi", { terminal = "Terminal" })
  eq("spawn: applescript exact",
     as, 'tell application "Terminal" to do script "cd \'/p\' && claude \'hi\'"')
  -- AppleScript double-quotes in the prompt must be backslash-escaped
  local as2 = core.spawnAppleScript("/p", 'say "hi"')
  check("spawn: escapes double quotes for AppleScript", as2:find('\\"hi\\"', 1, true) ~= nil)
  -- a single quote in the prompt survives both layers
  local as3 = core.spawnAppleScript("/p", "it's")
  check("spawn: handles single quotes", as3:find("'it'\\\\''s'", 1, true) ~= nil)
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
