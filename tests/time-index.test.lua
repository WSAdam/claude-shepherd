-- time-index.test.lua : where the time went, wired under a STUBBED Hammerspoon (2026-09-29, build
-- program unit 34). Drives the real dashboard functions:
--   * FX.refreshTimeIndex -- the transcript index on the FX.refreshCommits pattern: its own timer,
--     never the tick; each pass one hs.task that reads only what changed (`tail -c +offset | head`)
--     into scratch files, folded only while that task owns the slot; an unchanged transcript not
--     read at all; a hung pass reclaimed without its late exit landing; subagents flagged; a
--     transcript no live session has dropped; timeLost.enabled = false.
--   * FX.stepTimeLost -- a card's wait, ledgered once when it ends, with the card's identity; a card
--     that goes away mid-wait; nothing while the ledger is off.
--   * FX.pushTimeLost -- the view's payload (index + ledger) to window.ccTimeLost.
-- Each task's shell command runs for real against real temp transcripts. Side-effect-free: a temp
-- HOME holds the config, the ledger, the scratch dir and the transcripts.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end

local HOME
do
  local p = io.popen("mktemp -d 2>/dev/null"); HOME = p and p:read("*l"); if p then p:close() end
  assert(HOME and HOME ~= "", "could not mktemp a HOME")
  os.execute("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/.claude/cc-ledger' '" .. HOME .. "/status' '"
    .. HOME .. "/tr/s1/subagents'")
end
local CONFIG = HOME .. "/.claude/cc-config.json"
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function appendFile(path, s) local f = assert(io.open(path, "a")); f:write(s); f:close() end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function sizeOf(path) local f = io.open(path, "rb"); if not f then return nil end; local n = f:seek("end"); f:close(); return n end

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local js = {}   -- every evaluateJavaScript the panel ran
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) js[#js + 1] = s end },
    { __index = function() return function() return webviewHandle() end end })
end
local tasks = {}   -- every hs.task.new: { path, cb, args, started, terminated }
local json = dofile(HERE .. "support/json.lua")
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local mtimes = {}   -- path -> fake mtime (bumped by each write, so size and mtime both move)
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local names = {}
      local p = io.popen("ls -1 '" .. tostring(path) .. "' 2>/dev/null")
      if p then for n in p:lines() do names[#names + 1] = n end; p:close() end
      local i = 0
      return function() i = i + 1; return names[i] end, nil
    end,
    attributes = function(p, attr)
      local n = sizeOf(tostring(p))
      if not n then return nil end
      local t = { mode = "file", size = n, modification = mtimes[p] or 1 }
      if attr then return t[attr] end
      return t
    end,
    symlinkAttributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = {
    new = function(path, cb, args)
      local t = { path = path, cb = cb, args = args }
      function t:start() self.started = true; return self end
      function t:terminate() self.terminated = true end
      function t:setWorkingDirectory() end
      tasks[#tasks + 1] = t
      return t
    end,
  },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
hs.webview = setmetatable({
  windowMasks  = setmetatable({}, { __index = function() return 0 end }),
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return webviewHandle() end,
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
check("the dashboard loads under the stub", ok)
if not ok then print("       " .. tostring(err)); print(string.format("-- time-index.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core

local function timeTasks()
  local out = {}
  for _, t in ipairs(tasks) do
    if t.args and type(t.args[2]) == "string" and t.args[2]:find("/cc-scratch/time-", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function scratchFiles()
  local p = io.popen("ls -1 '" .. HOME .. "/.claude/cc-scratch' 2>/dev/null")
  local n = 0
  if p then for _ in p:lines() do n = n + 1 end; p:close() end
  return n
end
-- run a task's command for real, then its callback
local function finish(t, code) os.execute(t.args[2]); t.cb(code or 0, "", "") end

-- literal transcript records (see tests/time-lost.test.lua)
local function T(n) local s = 36000 + n; return string.format("2026-09-29T%02d:%02d:%02d.000Z", s // 3600, (s % 3600) // 60, s % 60) end
local function prompt(n) return '{"type":"user","message":{"role":"user","content":"go"},"origin":{"kind":"human"},"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '"}\n' end
local function assistant(n, id, out) return '{"message":{"model":"claude-opus-5","id":"' .. id .. '","type":"message","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":' .. out .. ',"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"type":"assistant","uuid":"a' .. n .. '","timestamp":"' .. T(n) .. '"}\n' end
local function stopHook(n) return '{"type":"system","subtype":"stop_hook_summary","timestamp":"' .. T(n) .. '","uuid":"s' .. n .. '"}\n' end

local TR = HOME .. "/tr/s1.jsonl"
local SUB = HOME .. "/tr/s1/subagents/agent-a1.jsonl"
local function write(path, s, mode) if mode == "a" then appendFile(path, s) else writeFile(path, s) end; mtimes[path] = (mtimes[path] or 1) + 1 end
write(TR, prompt(0) .. assistant(5, "m1", 10) .. stopHook(60))
local LIST = {
  { key = "k1", session_id = "s1", name = "one", projectKey = "-p", stackKey = "-p", cwd = "/r", transcript_path = TR },
  { key = "rk", session_id = "r1", name = "far", remote = { host = "box" }, transcript_path = HOME .. "/tr/far.jsonl" },
}

-- 0. the panel's tick never reads a transcript for the index
local before = #timeTasks()
pcall(function() FX._refreshBody() end)
check("the tick starts no index pass", #timeTasks() == before)
check("the index has its own retained timer", type(FX.timeIndexTimer) == "table")

-- 1. one pass: one hs.task through /bin/sh, the new bytes of each transcript into a scratch file
FX.refreshTimeIndex(true, LIST)
local t1 = timeTasks()[#timeTasks()]
check("a pass starts one task", #timeTasks() == before + 1 and t1 ~= nil and t1.path == "/bin/sh" and t1.args[1] == "-c")
check("...reading the transcript from its first byte", t1 and t1.args[2]:find("tail -c +1 '" .. TR .. "'", 1, true) ~= nil)
check("...never a remote card's", t1 and t1.args[2]:find("far.jsonl", 1, true) == nil)
FX.refreshTimeIndex(true, LIST)
check("no second pass while one runs", #timeTasks() == before + 1)
finish(t1)
local e = FX._timeIndex.entries[TR]
check("the pass lands: one turn indexed", e ~= nil and e.turns == 1 and e.turnSeconds == 60)
check("...its offset is the transcript's size", e ~= nil and e.offset == sizeOf(TR))
check("...and the scratch files are removed", scratchFiles() == 0)

-- 2. an unchanged transcript is not read again
FX.refreshTimeIndex(true, LIST)
check("an unchanged transcript starts no pass", #timeTasks() == before + 1)

-- 3. the transcript grows: only the new bytes are read, from the old offset
local old = sizeOf(TR)
write(TR, prompt(100) .. assistant(110, "m2", 20) .. stopHook(130), "a")
FX.refreshTimeIndex(true, LIST)
local t2 = timeTasks()[#timeTasks()]
check("a grown transcript is read from its offset", t2 ~= t1 and t2.args[2]:find("tail -c +" .. (old + 1) .. " '" .. TR .. "'", 1, true) ~= nil)
check("...only the bytes it grew by", t2.args[2]:find("head -c " .. (sizeOf(TR) - old) .. " ", 1, true) ~= nil)
finish(t2)
e = FX._timeIndex.entries[TR]
check("the new turn is added to the old  (turns=" .. tostring(e and e.turns) .. ")", e and e.turns == 2 and e.turnSeconds == 90)
check("...tokens too", e and e.usage.output == 30)

-- 4. a hung pass is reclaimed, and its late exit is dropped
write(TR, prompt(200) .. stopHook(210), "a")
FX.refreshTimeIndex(true, LIST)
local t3 = timeTasks()[#timeTasks()]
FX._timeIndex.inflight.ts = os.time() - 100
FX.refreshTimeIndex(true, LIST)
local t4 = timeTasks()[#timeTasks()]
check("a pass hung past 60s is terminated and restarted", t3.terminated == true and t4 ~= t3)
finish(t3)
e = FX._timeIndex.entries[TR]
check("the reclaimed pass's late exit is dropped", e and e.turns == 2)
check("...and its scratch files removed", scratchFiles() == 0)
finish(t4)
e = FX._timeIndex.entries[TR]
check("...while the new pass lands", e and e.turns == 3)

-- 5. a subagent's transcript is indexed beside the session's, flagged
write(SUB, prompt(0) .. assistant(3, "ms", 7))
FX.refreshTimeIndex(true, LIST)
local t5 = timeTasks()[#timeTasks()]
check("a subagent transcript is read", t5.args[2]:find("agent-a1.jsonl", 1, true) ~= nil)
check("...but not the unchanged main one", t5.args[2]:find("tail -c +" .. "1 '" .. TR .. "'", 1, true) == nil
      and t5.args[2]:find("'" .. TR .. "'", 1, true) == nil)
finish(t5)
local se = FX._timeIndex.entries[SUB]
check("...flagged as a subagent's", se and se.sub == true and se.usage.output == 7)
check("the session's transcripts are known by its key", #(FX._timeIndex.bySession.k1 or {}) == 2)

-- 6. the view: the index and the ledger, pushed to the panel
writeFile(CONFIG, json.encode({ ledger = { enabled = true } }))
local now = os.time()
local card = { key = "k1", session_id = "s1", name = "one", projectKey = "-p", stackKey = "-p", cwd = "/r",
               status = "approval", updated = now - 720, needsYou = "needs", needsYouSource = "approval" }
FX.stepTimeLost({ card })
local LF = HOME .. "/.claude/cc-ledger/" .. os.date("!%Y-%m-%d") .. ".jsonl"
check("a wait that is still running is not ledgered", not exists(LF))
FX.stepTimeLost({ { key = "k1", session_id = "s1", name = "one", projectKey = "-p", cwd = "/r", status = "working" } })
local led = exists(LF) and core.parseLedger(io.open(LF):read("*a")) or {}
local w = led[1] or {}
check("the wait is ledgered once it ends", #led == 1 and w.type == "waited" and w.source == "approval")
check("...its seconds from when the status file says it began", tonumber(w.seconds) and w.seconds >= 720 and w.seconds <= 722)
check("...with the card's identity", w.session_id == "s1" and w.key == "k1" and w.projectKey == "-p")
-- a card that goes away mid-wait: what it had open ends now
FX.stepTimeLost({ { key = "k2", session_id = "s2", name = "two", projectKey = "-p", status = "approval", updated = now - 60,
                    needsYou = "needs", needsYouSource = "ask" } })
FX.stepTimeLost({})
led = core.parseLedger(io.open(LF):read("*a"))
check("a card that went away mid-wait ledgers it  (" .. tostring(led[2] and led[2].source) .. ")",
      #led == 2 and led[2].type == "waited" and led[2].source == "question" and led[2].session_id == "s2")

FX._timeView = { kind = "session", id = "k1" }
js = {}
FX.pushTimeLost(LIST)
local call = js[#js] or ""
local body = call:match("^window%.ccTimeLost%((.*)%)$")
check("the view is pushed to window.ccTimeLost", body ~= nil)
local payload = body and json.decode(body) or {}
local v = payload.view or {}
check("...with the session's turns from the index", v.turns and v.turns.count == 3)
check("...its subagent", v.split and v.split.subagents == 1)
check("...and its wait from the ledger", v.you and tonumber(v.you.seconds) and v.you.seconds >= 720 and v.you.count == 1)
check("...another session's wait left out", v.you and v.you.bySource and v.you.bySource.question == nil)
check("...the ledger reads as on", payload.ledger == true and payload.kind == "session")
FX._timeView = { kind = "project", id = "-p" }
js = {}
FX.pushTimeLost(LIST)
payload = json.decode((js[#js] or ""):match("^window%.ccTimeLost%((.*)%)$") or "{}")
check("a project's view counts every wait with its projectKey", payload.view and payload.view.you and payload.view.you.count == 2)
FX._timeView = nil

-- the ledger off: nothing is tracked or written
writeFile(CONFIG, json.encode({ ledger = { enabled = false } }))
local n0 = #core.parseLedger(io.open(LF):read("*a"))
FX.stepTimeLost({ card })
FX.stepTimeLost({ { key = "k1", session_id = "s1", status = "working" } })
check("ledger off: nothing is written", #core.parseLedger(io.open(LF):read("*a")) == n0)
check("ledger off: nothing is tracked", next(FX._timeLost) == nil)

-- 7. a transcript no live session has any more is dropped
FX.refreshTimeIndex(true, {})
check("a gone session's transcripts leave the index", next(FX._timeIndex.entries) == nil)

-- 8. timeLost.enabled = false: nothing runs
writeFile(CONFIG, json.encode({ timeLost = { enabled = false } }))
local n = #timeTasks()
FX.refreshTimeIndex(true, LIST)
check("disabled: no pass runs", #timeTasks() == n)
check("the index functions are live on FX and core",
      type(FX.refreshTimeIndex) == "function" and type(core.timeIndexFold) == "function" and type(core.timeLostSummary) == "function")

os.execute("rm -r '" .. HOME .. "' 2>/dev/null")
print(string.format("-- time-index.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
