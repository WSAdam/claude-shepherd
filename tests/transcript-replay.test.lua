-- transcript-replay.test.lua : replay windows of REAL transcripts through the transcript parsers.
-- Run with plain `lua`. Every other transcript test feeds the parsers three hand-written lines,
-- and the two worst bugs of 2026-09 (a quadratic line walk that froze the panel, a card stuck at
-- Working for 2h35m) reproduce in neither: they need a 16KB head torn mid-record, records in the
-- order Claude Code really writes them, and the bytes framed the way the dashboard frames them.
-- The fixtures in tests/fixtures/transcripts/ are cut from real sessions and scrubbed of every
-- readable string (scrub.js there; its README lists each one); nothing here reads ~/.claude.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local FIXTURES = HERE .. "fixtures/transcripts/"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

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

-- ---- the dashboard's own framing, run from its source (2026-09-18) --------------------------
-- The readers are lifted out of claude-dashboard.lua and run as shipped (the done-order.test.js
-- pattern), so a change to how production frames a transcript reaches these fixtures at once.
local dashboard = assert(io.open(ROOT .. "claude-dashboard.lua", "r")):read("*a")
local function shipped(name)
  local from = dashboard:find("function FX." .. name .. "(", 1, true)
  local _, to = dashboard:find("\nend\n", from or 1, true)
  assert(from and to, "FX." .. name .. " not found in claude-dashboard.lua")
  local chunk = assert(load("local FX, core = {}, ...\n" .. dashboard:sub(from, to) .. "\nreturn FX." .. name))
  return chunk(core)
end
local readTail = shipped("readTail")                      -- seeks to size-maxBytes, drops the partial first line
local sessionFirstPrompt = shipped("sessionFirstPrompt")  -- f:read(16384) -> core.firstPromptFromTranscript
local TICK_TAIL = tonumber(dashboard:match("\nlocal ACTIVITY_BYTES = (%d+)"))   -- the per-tick tail budget
local HEAD_BYTES = 16384

local function readHead(name)
  local f = assert(io.open(FIXTURES .. name, "rb")); local head = f:read(HEAD_BYTES); f:close(); return head
end

-- A decode that fails is a torn or garbled line reaching the JSON decoder: under Hammerspoon
-- LuaSkin logs every one, even inside pcall (the JSON spam f1252be fixed).
local failedDecodes = 0
do
  local decode = core.json.decode
  core.json.decode = function(s)
    local ok, v = pcall(decode, s)
    if not ok then failedDecodes = failedDecodes + 1; error(v, 0) end
    return v
  end
end

eq("framing: the tick's tail budget is read from the dashboard", TICK_TAIL, 65536)

-- ---- head-first-prompt: a session's first 16KB (2026-09-18) ---------------------------------
-- Two queue-operation records, a hook attachment, the first prompt (a content ARRAY, as the VS
-- Code extension writes it), three attachments, then a 46KB attachment torn at byte 16384.
do
  local name = "head-first-prompt.jsonl"
  local head = readHead(name)
  eq("head-first-prompt: the fixture is a full 16KB head", #head, HEAD_BYTES)
  check("head-first-prompt: its last line is torn (no newline at the end)", head:sub(-1) ~= "\n")
  local want = "xxxxxx xxx xxxx xxxx xxx xxxxxx xxx xxxxxxx xxxxxx/xxx xx xx xxxxxxx xxxxx. xxxxxx xxx xxxx "
            .. "xxxx xx xx xx xxx xxx xxx xx xxxx x xxxx xxxx xx xxxxxxx xxxxxxxx xx xxxxx xxx xxx"
  failedDecodes = 0
  eq("head-first-prompt: the first prompt is found past the queue and attachment records",
     core.firstPromptFromTranscript(head), want)
  eq("head-first-prompt: the torn last line never reaches the JSON decoder", failedDecodes, 0)
  eq("head-first-prompt: the dashboard's own reader gives the same answer",
     sessionFirstPrompt({ transcript_path = FIXTURES .. name }), want)
  eq("head-first-prompt: the tab is labelled with the prompt cut the way the tab cuts it",
     core.claudeTabLabel(core.firstPromptFromTranscript(head)), "xxxxxx xxx xxxx xxxx xxx\226\128\166")

  -- Speed. 2026-09-18: `head:gmatch("([^\n]*)\n")` has no newline to find in the torn last line,
  -- so it retries from every byte of it -- quadratic. One 16KB head cost 201ms on Hammerspoon's
  -- only thread, every tick, per open tab, and froze the whole panel; the find-based walk is
  -- 0.016ms there. Here the torn line is 5.3KB and the decoder is the slow pure-Lua one: a call
  -- runs ~0.04ms and the old walk ~110ms. The bound is 2ms a call -- ~50x headroom for a loaded CI
  -- box, ~50x under what the old walk costs -- and the old walk is timed on this very head too, so
  -- the fixture is known to be one the old code chokes on (a head regenerated without a torn
  -- last line would pass the bound and guard nothing).
  local function perCallMs(fn, n)
    local t0 = os.clock()
    for _ = 1, n do fn() end
    return (os.clock() - t0) * 1000 / n
  end
  local fast = perCallMs(function() core.firstPromptFromTranscript(head) end, 50)
  check(string.format("head-first-prompt: firstPromptFromTranscript stays under 2ms a call (%.3fms)", fast), fast < 2)
  local oldWalk = perCallMs(function() for _ in head:gmatch("([^\n]*)\n") do end end, 3)
  check(string.format("head-first-prompt: the old whole-lines pattern is at least 100x slower on this head (%.1fms)", oldWalk),
        oldWalk > fast * 100)
end

-- ---- head-prompt-past-the-tear: the head the old code actually chokes on (2026-09-18) -------
-- Derived from head-first-prompt (same records, same scrubbing, see the README): its only user
-- record is the TORN final one, so a 16KB window holds no whole prompt and the walk must cross
-- every byte before giving up. This is the case head-first-prompt cannot cover -- there the
-- prompt sits 1KB in, so the function returns long before it meets the tear, and a mutant that
-- restores the old pattern SURVIVES. Here the pattern's cost is the function's cost.
do
  local name = "head-prompt-past-the-tear.jsonl"
  local head = readHead(name)
  eq("past-the-tear: the fixture is a full 16KB head", #head, HEAD_BYTES)
  check("past-the-tear: its last line is torn (no newline at the end)", head:sub(-1) ~= "\n")
  local whole = 0
  for line in head:gmatch("([^\n]+)\n") do if line:find('"type":"user"', 1, true) then whole = whole + 1 end end
  eq("past-the-tear: no WHOLE user record is in the window -- the scan cannot stop early", whole, 0)

  failedDecodes = 0
  eq("past-the-tear: a prompt that is only in the torn line is not reported",
     core.firstPromptFromTranscript(head), nil)
  eq("past-the-tear: the torn last line never reaches the JSON decoder", failedDecodes, 0)
  eq("past-the-tear: the dashboard's own reader agrees",
     sessionFirstPrompt({ transcript_path = FIXTURES .. name }), nil)

  -- The mutant is the REAL one: core.firstPromptFromTranscript as it stood at f1252be, pattern
  -- and all, so the comparison runs through the same code path rather than past it. Measured on
  -- this head: the shipped walk 0.002ms a call, the mutant 873ms -- the torn remainder is 15KB
  -- and the cost is quadratic in it. The bound is 5ms, ~2000x over the shipped cost for a loaded
  -- CI box and ~175x under the mutant, and the mutant is timed here too so the fixture is known
  -- to be one the old code chokes on.
  local function mutantFirstPrompt(text)
    for line in text:gmatch("([^\n]*)\n") do
      if line:find('"type":"user"', 1, true) then return line end
    end
    return nil
  end
  local function perCallMs(fn, n)
    local t0 = os.clock()
    for _ = 1, n do fn() end
    return (os.clock() - t0) * 1000 / n
  end
  local fast = perCallMs(function() core.firstPromptFromTranscript(head) end, 50)
  check(string.format("past-the-tear: firstPromptFromTranscript stays under 5ms a call (%.3fms)", fast), fast < 5)
  local slow = perCallMs(function() mutantFirstPrompt(head) end, 1)
  check(string.format("past-the-tear: the f1252be mutant blows the same bound on this head (%.0fms)", slow), slow > 5)
end

print(string.format("\n%d checks, %d failed", run, failed))
os.exit(failed == 0 and 0 or 1)
