-- tab-title-scan.test.lua : BEHAVIORAL fixture for reading a tab's rename without re-reading the
-- transcript (2026-10-22). Loads the real claude-dashboard.lua under a stubbed hs (the
-- remote-control.test.lua harness), with a real transcript file in a temp dir; hs.task and hs.execute
-- are recorders, and the test runs a recorded task's real command itself to answer it.
--
-- 2026-10-22: Shepherd felt slow. A live profile put 69% of the tick in one call:
-- `grep -F '"type":"custom-title"' <whole transcript>` through synchronous hs.execute, every 30s per
-- session (FX.sessionTabCandidates, FX.sessionTabLabel). Adam's transcripts had reached 100-264 MB, so
-- each grep froze the whole panel for up to 1.75s. Now the first read runs as a background task over
-- the bytes the file had then, and later reads fold in only the bytes appended since, in Lua.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- tab-title-scan.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/+$", "")
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/sessions"')
local now = os.time()
local function write(path, s, mode) local f = io.open(path, mode or "w"); f:write(s); f:close() end
write(T .. "/.claude/cc-config.json", json.encode({}))
write(T .. "/.panel-alive", tostring(now))
local TR = T .. "/transcript.jsonl"
local CT = function(t) return '{"type":"custom-title","customTitle":"' .. t .. '","sessionId":"s1"}\n' end
local filler = string.rep('{"type":"assistant","message":{"content":"' .. string.rep("z", 200) .. '"}}\n', 400)
write(TR, '{"type":"user","message":{"content":"first prompt"}}\n' .. CT("Renamed early") .. filler)

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SESSIONS_DIR = T .. "/sessions", HOME = T, SHELL = "/bin/zsh" }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local execs = {}
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1A "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function() return nil, "no such file" end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd) execs[#execs + 1] = tostring(cmd); return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,
  new = function() return mkstub() end, usleep = function() end,
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
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
local fakeApp = { allWindows = function() return {} end, activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
-- background tasks are recorders: the test runs the real command and fires the callback itself
local TASKS = {}
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, running = false }
  function t:start() self.running = true; return self end
  function t:isRunning() return self.running end
  function t:terminate() self.running = false; return true end
  TASKS[#TASKS + 1] = t
  return setmetatable(t, { __index = function() return function() return nil end end })
end)
hs.reload = function() end
hs.processInfo = { processID = 10000, bundleID = "org.hammerspoon.Hammerspoon" }
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local fx = rawget(_G, "__ccDashboard").fx
check("the panel has the incremental reader", type(fx.customTitleLines) == "function")
if type(fx.customTitleLines) ~= "function" then finish() end

local function grepsRun() local n = 0 for _, c in ipairs(execs) do if c:find("custom-title", 1, true) then n = n + 1 end end return n end
local function scanTasks() local out = {} for _, t in ipairs(TASKS) do if table.concat(t.args, " "):find("custom-title", 1, true) then out[#out + 1] = t end end return out end
local function answer(t)   -- run the recorded command for real, then fire the task's callback
  local cmd = t.args[#t.args]
  local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end
  t.running = false
  quiet(function() t.cb(0, out, "") end)
end

-- 1. the first read: a background task over the bytes the file has now, never a blocking grep
execs, TASKS = {}, {}
local first = fx.customTitleLines(TR)
local tasks = scanTasks()
check("the first read starts one background scan", #tasks == 1)
check("...and blocks on nothing (no synchronous grep)", grepsRun() == 0)
check("...while it runs there's no rename yet", first == nil or first == "")
check("a second call while the scan runs starts no other", (function() fx.customTitleLines(TR); return #scanTasks() == 1 end)())
if #tasks == 1 then answer(tasks[1]) end
local got = fx.customTitleLines(TR) or ""
check("once it answers, the rename is read  (" .. got:sub(1, 60) .. ")", got:find("Renamed early", 1, true) ~= nil)

-- 2. a rename appended later is read from the new bytes alone
write(TR, filler .. CT("Renamed later") .. filler, "a")
execs, TASKS = {}, {}
got = fx.customTitleLines(TR) or ""
check("a later rename is read from the appended bytes", got:find("Renamed later", 1, true) ~= nil)
check("...with no new scan and no grep", #scanTasks() == 0 and grepsRun() == 0)
check("...and the tab's title is the newest rename",
      rawget(_G, "__ccDashboard").core.claudeTabTitle(got, nil) == "Renamed later")

-- 3. the tab label paths use it: no whole-transcript grep from either
execs, TASKS = {}, {}
local cands = fx.sessionTabCandidates({ key = "s1", transcript_path = TR, last_prompt = "x" }) or {}
local label = fx.sessionTabLabel({ key = "s1", transcript_path = TR })
check("the tab's candidate names carry the rename", table.concat(cands, "|"):find("Renamed later", 1, true) ~= nil)
check("...and so does its label", label ~= nil and label:find("Renamed later", 1, true) ~= nil)
check("...and neither ran a grep", grepsRun() == 0)

-- 4. a file that got shorter (rewritten) is scanned again from the start
write(TR, CT("Rewritten") .. "\n")
execs, TASKS = {}, {}
fx.customTitleLines(TR)
tasks = scanTasks()
check("a rewritten (shorter) transcript is scanned again in the background", #tasks == 1 and grepsRun() == 0)
if #tasks == 1 then answer(tasks[1]) end
got = fx.customTitleLines(TR) or ""
check("...and its rename replaces the old ones", got:find("Rewritten", 1, true) ~= nil and not got:find("Renamed later", 1, true))

finish()
