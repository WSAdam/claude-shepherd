-- seance.test.lua : BEHAVIORAL fixture for Seance (2026-10-02, mining round 2 unit D1).
-- Ask any session -- live, or dead and found in fleet search or History -- a question, read-only:
-- FX.seanceAsk forks its conversation with a headless `claude -p --resume <transcript>
-- --fork-session --no-session-persistence` (core.headlessCmd), in the session's own model and a
-- budget sized from its context, and the answer comes back to the panel (window.ccSeance).
-- Seance runs in its OWN lane: a merge checker or coach run queued in the same repo never holds a
-- question up. Loads the real claude-dashboard.lua under a stubbed hs: hs.task and hs.timer are
-- recorders, and the test plays claude's part by writing its output file and firing the task's
-- exit callback. Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- seance.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local PROJ, SCR = T .. "/.claude/projects", T .. "/scratch"
os.execute('mkdir -p "' .. T .. '/status" "' .. PROJ .. '/-r-A" "' .. PROJ .. '/-r-gone" "' .. SCR .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- A transcript: where it started, then a reply with ~250k of context in Opus.
local function transcript(path, cwd, model, ctx)
  write(path, table.concat({
    json.encode({ type = "user", cwd = cwd, message = { role = "user", content = "Make the change." } }),
    json.encode({ type = "assistant", cwd = cwd, message = { model = model, id = "m1",
      usage = { input_tokens = 3, cache_read_input_tokens = ctx - 1003, cache_creation_input_tokens = 1000, output_tokens = 40 },
      content = { { type = "text", text = "Done." } } } }), "" }, "\n"))
end
local S1 = "aaaa1111-0000-4000-8000-000000000001"   -- live, in /r/A
local S2 = "bbbb2222-0000-4000-8000-000000000002"   -- dead, its folder gone
local S3 = "cccc3333-0000-4000-8000-000000000003"   -- dead, found by a subagent's line in fleet search
local TP1, TP2, TP3 = PROJ .. "/-r-A/" .. S1 .. ".jsonl", PROJ .. "/-r-gone/" .. S2 .. ".jsonl", PROJ .. "/-r-A/" .. S3 .. ".jsonl"
transcript(TP1, "/r/A", "claude-opus-5-5", 250000)
transcript(TP2, "/r/gone", "claude-sonnet-5-5", 40000)
transcript(TP3, "/r/A", "claude-sonnet-5-5", 30000)
os.execute('mkdir -p "' .. PROJ .. "/-r-A/" .. S3 .. '/subagents"')
write(PROJ .. "/-r-A/" .. S3 .. "/subagents/agent-1.jsonl", "{}\n")
write(T .. "/status/k1.json", json.encode({ status = "done", session_id = S1, name = "A-unit", cwd = "/r/A/sub",
  transcript_path = TP1, since = now - 60, updated = now - 60, editor = "vscode", host_window = "701", session_pid = "5001" }))
write(T .. "/.claude/cc-config.json", json.encode({}))
write(T .. "/.panel-alive", tostring(now))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SCRATCH_DIR = SCR, SHELL = "/bin/zsh", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, alerts, pushes = 0, {}, {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s)
      s = tostring(s or "")
      local m = s:match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
      local p = s:match("^window%.ccSeance%((.*)%)$")
      if p then pushes[#pushes + 1] = json.decode(p) end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
-- The folders that exist: /r/A (the live session's launch folder), and the real temp dirs.
local DIRS = { ["/r/A"] = true, ["/r/A/sub"] = true }
local function isDir(p)
  if DIRS[p] then return true end
  if type(p) == "string" and p:sub(1, #T) == T then
    local ok = os.execute('test -d "' .. p .. '"')
    return ok == true or ok == 0
  end
  return false
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      if isDir(path) then
        if attr == "mode" then return "directory" end
        return { mode = "directory" }
      end
      local f = io.open(tostring(path), "r")
      if f then f:close(); if attr == "mode" then return "file" end return { mode = "file" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function(p) os.execute('mkdir -p "' .. tostring(p) .. '"'); return true end,
    symlinkAttributes = function() return nil end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function(s) alerts[#alerts + 1] = tostring(s) end },
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
rawset(hs.eventtap, "keyStroke", function() taps = taps + 1 end)
rawset(hs.eventtap, "keyStrokes", function() taps = taps + 1 end)
local fakeApp = { allWindows = function() return {} end, activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
-- Tasks and backstop timers are recorders: the test fires their callbacks itself.
local TASKS, TIMERS = {}, {}
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, dir = false, running = false, terminated = false }
  function t:start() self.running = true; return self end
  function t:setWorkingDirectory(d) self.dir = d; return true end
  function t:terminate() self.terminated = true; self.running = false; return true end
  function t:isRunning() return self.running end
  TASKS[#TASKS + 1] = t
  return setmetatable(t, { __index = function() return function() return nil end end })
end)
rawset(hs.timer, "doAfter", function(secs, fn)
  local t = { secs = secs, fn = fn, stopped = false }
  function t:stop() self.stopped = true end
  function t:start() return self end
  TIMERS[#TIMERS + 1] = t
  return t
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
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
fx.now = function() return os.time() end
local function tick() return quiet(function() fx._refreshBody() end) end
local function seanceTasks()
  local out = {}
  for _, t in ipairs(TASKS) do
    if tostring(t.args[3] or ""):find("--fork-session", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function cmdOf(t) return tostring(t and t.args[3] or "") end
-- Headless runs only: since 2026-10-22 the panel's own tick also starts a background
-- tab-title scan (FX.customTitleLines), which is not a run.
local function runTasks()
  local n = 0
  for _, t in ipairs(TASKS) do
    if not tostring(t.args[2] or ""):find("custom-title", 1, true) then n = n + 1 end
  end
  return n
end
local function files(t) return cmdOf(t):match("< '([^']+)' > '([^']+)' 2> '([^']+)'") end
-- play claude: write its output where the command line sends it, then exit
local function answer(t, result, code, errText)
  local _, outFile, errFile = files(t)
  if result then
    write(outFile, json.encode({ type = "result", subtype = "success", is_error = false, num_turns = 1, total_cost_usd = 0.04,
      result = result }))
  end
  if errText then write(errFile, errText) end
  t.running = false
  quiet(function() t.cb(code or 0, "", "") end)
end
local function ask(t) return quiet(function() fx.seanceAsk(json.encode(t)) end) end
local function lastPush(sid)
  for i = #pushes, 1, -1 do if pushes[i].sid == sid then return pushes[i] end end
  return nil
end

check("Seance is wired: FX.seanceAsk exists", type(fx.seanceAsk) == "function")
if type(fx.seanceAsk) ~= "function" then os.execute('rm -rf "' .. T .. '"'); finish() end
tick()

-- A checker holds repo A's lane, and a coach run waits behind it.
quiet(function()
  fx.runHeadless({ id = "checker|other", lane = "/r/A/.git", dir = "/r/A", prompt = "review" })
  fx.runHeadless({ id = "coach|/r/A", lane = "/r/A/.git", dir = "/r/A", prompt = "coach" })
end)
check("(setup) the checker runs and the coach waits in repo A's lane",
      runTasks() == 1 and fx._headless["coach|/r/A"] and fx._headless["coach|/r/A"].state == "queued")

-- 1. A live session, asked from its detail panel
ask({ key = "k1", question = "What did you change in <app.lua> & why?" })
local L = seanceTasks()
check("asking a live session starts one headless run at once, past the repo's busy lane", #L == 1)
local l1 = L[1] or { args = {} }
local c1 = cmdOf(l1)
check("...through the login shell ($SHELL -l -c)", l1.bin == "/bin/zsh" and l1.args[1] == "-l" and l1.args[2] == "-c")
check("...in its launch folder  (" .. c1:sub(1, 60) .. "…)", c1:find("cd '/r/A' ", 1, true) ~= nil and l1.dir == "/r/A")
check("...forking its own transcript", c1:find("--resume '" .. TP1 .. "' --fork-session", 1, true) ~= nil)
check("...saving nothing", c1:find("--no-session-persistence", 1, true) ~= nil)
check("...read-only: hooks off, no MCP, read-only tools, never asks",
      c1:find("disableAllHooks", 1, true) ~= nil and c1:find("--strict-mcp-config", 1, true) ~= nil
      and c1:find("--tools 'Read,Grep,Glob,Bash'", 1, true) ~= nil and c1:find("--permission-mode dontAsk", 1, true) ~= nil
      and c1:find("CC_SHEPHERD_INTERNAL=1", 1, true) ~= nil)
check("...in its model, with the 1M window its 250k of context needs", c1:find("--model 'claude-opus-5-5[1m]'", 1, true) ~= nil)
local want = core.seanceBudget(250000, "claude-opus-5-5")
check("...a budget sized from that context ($" .. tostring(want) .. ")",
      c1:find("--max-budget-usd " .. string.format("%g", want) .. " ", 1, true) ~= nil)
local pf = files(l1)
local prompt = pf and read(pf) or ""
check("...the question goes in on stdin, as written", prompt:find("What did you change in <app.lua> & why?", 1, true) ~= nil)
local tmo
for _, tm in ipairs(TIMERS) do if tm.secs == core.SEANCE.timeoutSeconds then tmo = tm end end
check("...with a retained timeout timer (" .. tostring(core.SEANCE.timeoutSeconds) .. "s)", tmo ~= nil)
check("...and the coach still waits for the checker: Seance never took repo A's lane",
      fx._headless["coach|/r/A"] and fx._headless["coach|/r/A"].state == "queued")
local p0 = lastPush(S1)
check("the panel hears it's running  (" .. tostring(p0 and p0.state) .. ")", p0 and p0.state == "running"
      and p0.question == "What did you change in <app.lua> & why?" and p0.name == "A-unit")

-- claude answers
answer(l1, "I renamed the parser & added a test.")
local rec = fx._seance and fx._seance[S1]
check("the answer lands on the session's record", rec and rec.state == "done" and rec.outcome == "answered"
      and rec.answer == "I renamed the parser & added a test.")
local p1 = lastPush(S1)
check("...and the panel gets it in place  (" .. tostring(p1 and p1.answer) .. ")",
      p1 and p1.state == "done" and p1.answer == "I renamed the parser & added a test." and p1.costUsd == 0.04)
check("...and the transcript it forked is untouched", read(TP1):find("Make the change.", 1, true) ~= nil
      and select(2, read(TP1):gsub("\n", "")) == 2)

-- a second question supersedes one still running
ask({ key = "k1", question = "First?" })
ask({ key = "k1", question = "Second?" })
L = seanceTasks()
check("a new question to the same session replaces the one still running",
      #L == 3 and L[2].terminated == true and L[3].terminated == false)
answer(L[2], "late answer to the first")
check("...and the replaced run's late answer never lands", fx._seance[S1].question == "Second?" and fx._seance[S1].state == "running")
answer(L[3], "the second answer")
check("...the new one's does", fx._seance[S1].answer == "the second answer")

-- 2. A dead session from History (session id + project key): its launch folder is gone
ask({ sessionId = S2, projectKey = "-r-gone", question = "Where did you leave it?" })
L = seanceTasks()
local l2 = L[#L]
local c2 = cmdOf(l2)
check("a dead session from History resumes its transcript by path  (" .. c2:sub(1, 80) .. "…)",
      c2:find("--resume '" .. TP2 .. "' --fork-session", 1, true) ~= nil)
check("...from Shepherd's own folder, since its launch folder is gone", c2:find("cd '" .. SCR .. "/seance' ", 1, true) ~= nil)
check("...in its own model (small context, no 1M window)", c2:find("--model 'claude-sonnet-5-5' ", 1, true) ~= nil)
answer(l2, nil, 1, "No conversation found with session ID: " .. S2 .. "\n")
local r2 = fx._seance[S2]
check("a run that couldn't answer says claude's own reason  (" .. tostring(r2 and r2.why) .. ")",
      r2 and r2.state == "done" and r2.outcome == "couldntRun" and tostring(r2.why):find("No conversation found", 1, true) ~= nil)
check("...and the panel hears it", lastPush(S2) and lastPush(S2).outcome == "couldntRun")

-- 3. A fleet-search hit on a subagent's transcript asks its parent session
ask({ sessionId = S3, file = PROJ .. "/-r-A/" .. S3 .. "/subagents/agent-1.jsonl", question = "Which test?" })
L = seanceTasks()
local c3 = cmdOf(L[#L])
check("a fleet-search hit in a subagent's file asks its parent session", c3:find("--resume '" .. TP3 .. "' --fork-session", 1, true) ~= nil
      and c3:find("cd '/r/A' ", 1, true) ~= nil)

-- 3b. A detail box whose card has just gone still asks: its key finds nothing, its project key does
ask({ key = "k-gone", sessionId = S3, projectKey = "-r-A", question = "Still there?" })
L = seanceTasks()
check("a detail box whose card just went asks by its project key", cmdOf(L[#L]):find("--resume '" .. TP3 .. "'", 1, true) ~= nil)

-- 4. Refusals: nothing runs, and a toast says why
local before, toasts = #TASKS, #alerts
ask({ sessionId = S1, file = "/etc/passwd", question = "?" })
ask({ sessionId = S1, file = PROJ .. "/../../etc/" .. S1 .. ".jsonl", question = "?" })
ask({ sessionId = "not a session; id", projectKey = "-r-A", question = "?" })
ask({ sessionId = "dddd4444-0000-4000-8000-000000000004", projectKey = "-r-A", question = "?" })
ask({ key = "k1", question = "   " })
check("a file outside Claude's projects, a bad id, a missing transcript, an empty question: nothing runs",
      #TASKS == before)
check("...and each says why  (" .. (#alerts - toasts) .. " toasts)", #alerts - toasts >= 5)

-- 5. the panel can ask for a record again (after a reload of the panel)
pushes = {}
quiet(function() fx.seanceSend(S1) end)
check("the panel can ask for a session's last answer again", lastPush(S1) and lastPush(S1).answer == "the second answer")

check("never a keystroke", taps == 0)
os.execute('rm -rf "' .. T .. '"')
finish()
