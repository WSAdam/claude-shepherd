-- maingreen.test.lua : BEHAVIORAL fixture for the scheduled main-green check (2026-10-03, mining
-- round 2 unit E1b). A routine with action "gate" runs the repo's merge gate (core.mainGreenGateFor)
-- in its MAIN checkout, in the repo's one gate lane (behind every run that judges a merge), at a time
-- Adam sets. A red run raises ONE banner, a "main is red" flag on every card of that repo (with the
-- failing lines) and a coach-log entry; the next green run clears the flag. A run that couldn't run
-- or timed out is never red. A fleet freeze, or a session of that repo on hold (D2), stands it down.
-- The verdict is kept in a file, so a reload neither forgets the flag nor banners it again.
-- Loads the real claude-dashboard.lua under a stubbed hs (the tests/gateblame.test.lua harness): git
-- answers are canned, hs.task and hs.timer are recorders, and the test plays the runner by writing
-- its output file and firing the task's exit callback. The last section runs the real shell line
-- against a real temp git repo. Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- maingreen.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/+$", "")
local SCR, HOLD = T .. "/scratch", T .. "/hold"
-- hs.fs.mkdir is a stub here: the coach's folder exists up front, as it does once Shepherd has run
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude/cc-merge" "' .. T .. '/.claude/cc-coach" "' .. SCR .. '" "' .. HOLD .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

write(T .. "/.claude/cc-config.json", json.encode({
  schedules = { enabled = true },
  merge = { gates = {
    { match = { project = "/r/R" }, command = "GATE-R" },
    { match = { project = "/r/K" }, command = "GATE-K", timeoutSeconds = 7 },
  } },
}))
write(T .. "/.panel-alive", tostring(now))
local SCHED = T .. "/schedules.json"
local function routines(list) write(SCHED, json.encode({ schedules = list })) end
local function mg(extra)
  local r = { name = "main-green-R", kind = "cron", cron = "* * * * *", action = "gate", folder = "/r/R", enabled = true }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
routines({ mg({ enabled = false }) })
-- a session working in the repo's main checkout: its card is the one that gets the flag
write(T .. "/status/s1.json", string.format(
  '{"status":"done","session_id":"s1","name":"s1","cwd":"/r/R","since":%d,"updated":%d,"editor":"terminal","session_pid":"901"}',
  now - 60, now - 60))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SCRATCH_DIR = SCR, SHELL = "/bin/zsh", HOME = T, CC_SCHEDULES_FILE = SCHED, CC_HOLD_DIR = HOLD,
              CC_MAIN_GREEN_FILE = T .. "/main-green.json" }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local alerts = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s)
      local m = tostring(s or ""):match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local panelCb
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
  execute = function(cmd)
    cmd = tostring(cmd or "")
    -- FX.repoIdentity: /r/R and /r/K are the main checkouts of their repos
    if cmd:find("--show-toplevel --git-common-dir --git-dir", 1, true) then
      local dir = cmd:match("git %-C '([^']+)'") or ""
      local top = dir:match("^(/r/[RK])")
      if top then return top .. "\n" .. top .. "/.git\n" .. top .. "/.git\n" end
    end
    return ""
  end,
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
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) panelCb = fn end }, { __index = function() return function() return mkstub() end end })
  end },
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
local banners, spawns = {}, 0
fx.notify = function(title, text) banners[#banners + 1] = tostring(title) .. " | " .. tostring(text) end
fx.spawnSession = function() spawns = spawns + 1 end
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function cmdOf(t) return tostring(t.args[3] or t.args[2] or "") end
local function tasks(needle)
  local out = {}
  for _, t in ipairs(TASKS) do if cmdOf(t):find(needle, 1, true) then out[#out + 1] = t end end
  return out
end
local function logOf(t) return cmdOf(t):match("> '([^']+)' 2>&1") end
local function finishTask(t, code, text)
  local f = logOf(t)
  os.execute('mkdir -p "' .. (f:match("^(.*)/[^/]+$") or ".") .. '"')
  write(f, text or "")
  t.running = false
  quiet(function() t.cb(code, "", "") end)
end
local function lastGate(name) local g = tasks(name); return g[#g] end
local function saved() return json.decode(read(T .. "/main-green.json") or "{}") or {} end
local function flag() local I = items(); return I.s1 and I.s1.mainRed end
local function fired(name)
  for _, s in ipairs((json.decode(read(SCHED) or "{}") or {}).schedules or {}) do
    if s.name == name then return tonumber(s.lastFiredAt) end
  end
end
local function refire(extra) routines({ mg(extra) }) end
local SHA = string.rep("a", 40)
local RED = "@@main-sha " .. SHA .. "\n== suite: core ==\nok   - one\nFAIL - main broke this (0.2s)\n-- core.test.lua: 2 run, 1 failed --\n"
local GREEN = "@@main-sha " .. string.rep("b", 40) .. "\n== suite: core ==\nok   - one\nok   - two\n"

-- ---- off until Adam adds a routine; then it runs in the lane, behind a gate that judges a merge ----
tick()
check("a paused gate routine runs nothing", #tasks("GATE-R") == 0 and next(fx._mainGreenRuns or {}) == nil)
local busy = { state = "running", commonDir = "/r/R/.git", at = now, nonce = "busy", task = {}, command = "MERGE-GATE" }
fx._mergeGates["busy|x"] = busy
refire()
tick()
check("the routine fires once its minute comes, and is marked fired", fired("main-green-R") ~= nil)
local q = (fx._mainGreenRuns or {})["/r/R/.git"]
check("...but waits for the repo's gate lane while a merge gate runs  (" .. tostring(q and q.state) .. ")",
      q and q.state == "queued" and #tasks("GATE-R") == 0)
check("...and spawns no session", spawns == 0)
busy.state, busy.task = "passed", nil
fx._mergeGates["busy|x"] = nil
tick()
local g1 = tasks("GATE-R")[1]
check("once the lane is free, the repo's merge gate runs, in the MAIN checkout", g1 ~= nil and g1.dir == "/r/R")
if not g1 then finish() end
local c1 = cmdOf(g1)
check("...through the login shell", g1.args[1] == "-l")
check("...after checking the checkout is on main and clean, and saying the sha it tests",
      c1:find("symbolic-ref", 1, true) and c1:find("status --porcelain --untracked-files=no", 1, true)
      and c1:find("@@main-sha", 1, true) and c1:find("GATE-R", 1, true))
check("nothing is flagged while it runs", flag() == nil and #banners == 0)

-- ---- red: one banner, the card's flag with the failing lines, a coach-log entry ----
finishTask(g1, 2, RED)
tick()
check("a red run raises one banner  (" .. #banners .. ")", #banners == 1 and banners[1]:find("main is red", 1, true) ~= nil)
local f = flag()
check("the repo's card is flagged main is red  (" .. tostring(f and f.label) .. ")", f and f.label and f.label:find("main is red", 1, true))
check("...with the failing lines in its tooltip", f and f.tip:find("FAIL - main broke this", 1, true) and f.tip:find(SHA:sub(1, 7), 1, true))
local s = saved()["/r/R/.git"]
check("the verdict is kept on disk", s and s.state == "red" and s.sha == SHA)
local logp = fx.coachPath("/r/R", ".log.json")
local clog = json.decode(read(logp or "") or "[]") or {}
check("the coach log hears main went red  (" .. #clog .. ")", #clog == 1 and clog[1].kind == "mainred"
      and tostring(clog[1].note):find("FAIL - main broke this", 1, true) ~= nil)
tick(); tick()
check("later ticks raise no second banner", #banners == 1 and flag() ~= nil)

-- ---- red again: still one banner. couldn't run: no change. green: the flag clears ----
refire()
tick()
local g2 = lastGate("GATE-R")
check("the next firing runs again", g2 ~= g1)
finishTask(g2, 2, RED)
tick()
check("still red is still one banner", #banners == 1 and flag() ~= nil)
refire()
tick()
local g3 = lastGate("GATE-R")
finishTask(g3, 9, "CC_TEST_SUITE_LOCKED: another run holds this checkout\n")
tick()
check("a run that couldn't run neither clears the flag nor banners", #banners == 1 and flag() ~= nil and saved()["/r/R/.git"].state == "red")
refire()
tick()
local g4 = lastGate("GATE-R")
finishTask(g4, 0, GREEN)
tick()
check("the next green run clears the flag", flag() == nil and saved()["/r/R/.git"].state == "green")
check("...with no banner", #banners == 1)

-- ---- a reload neither forgets the flag nor banners it again ----
refire()
tick()
finishTask(lastGate("GATE-R"), 1, RED)
tick()
check("red again after a green is a new banner", #banners == 2 and flag() ~= nil)
fx._mainGreen.state = nil   -- what a reload starts with
tick()
check("after a reload the flag is read back from disk, with no banner", flag() ~= nil and #banners == 2)

-- ---- the fleet freeze, or a session of the repo on hold, stands it down ----
local n = #tasks("GATE-R")
write(HOLD .. "/.fleet", "{}")
refire()
tick()
check("frozen: the routine is spent but nothing runs", #tasks("GATE-R") == n and fired("main-green-R") ~= nil)
local fl = (fx._hold.skipped or {})[".fleet"] or {}
check("...and the skipped check is listed on the fleet's list", #fl >= 1 and fl[#fl].kind == "schedule")
os.remove(HOLD .. "/.fleet")
write(HOLD .. "/901", "{}")
refire()
tick()
check("a session of the repo on hold: nothing runs", #tasks("GATE-R") == n)
local sl = (fx._hold.skipped or {})["901"] or {}
check("...and the skipped check is listed on that session", #sl >= 1 and sl[#sl].kind == "schedule")
os.remove(HOLD .. "/901")
-- queued behind a merge gate when the freeze comes: it leaves the lane
fx._mergeGates["busy|y"] = { state = "running", commonDir = "/r/R/.git", at = now, nonce = "busy", task = {}, command = "MERGE-GATE" }
refire()
tick()
check("queued again behind a merge gate", (fx._mainGreenRuns["/r/R/.git"] or {}).state == "queued")
write(HOLD .. "/.fleet", "{}")
tick()
check("...a freeze drops it from the lane", fx._mainGreenRuns["/r/R/.git"] == nil)
os.remove(HOLD .. "/.fleet")
fx._mergeGates["busy|y"] = nil
tick()
check("...so the lane freeing starts nothing", #tasks("GATE-R") == n)

-- ---- Run on the board: runs the check now, never spawns ----
quiet(function() panelCb({ body = json.encode({ a = "schedule-run-now", v = "main-green-R" }) }) end)
check("Run starts the check now", #tasks("GATE-R") == n + 1)
check("...and spawns no session", spawns == 0)
finishTask(lastGate("GATE-R"), 0, GREEN)
tick()
check("...and its green clears the flag", flag() == nil)

-- ---- a timeout is never red ----
routines({ mg({ name = "main-green-K", folder = "/r/K" }) })
tick()
local k1 = tasks("GATE-K")[1]
check("the K repo's check runs in its own lane", k1 ~= nil and k1.dir == "/r/K")
if not k1 then finish() end
local backstop
for _, tm in ipairs(TIMERS) do if tm.secs == 7 and not tm.stopped then backstop = tm end end
check("the run has a retained backstop timer (the gate's timeout)", backstop ~= nil)
if backstop then quiet(function() backstop.fn() end) end
finishTask(k1, 143, "FAIL - something\n")
tick()
check("a timed-out check is never red", (saved()["/r/K/.git"] or {}).state ~= "red" and #banners == 2)

-- ---- a repo whose gate routine is deleted loses its flag ----
routines({ mg() })
tick()
finishTask(lastGate("GATE-R"), 1, RED)
tick()
check("red once more", flag() ~= nil)
quiet(function() panelCb({ body = json.encode({ a = "schedule-delete", v = "main-green-R" }) }) end)
tick()
check("deleting the routine drops the repo's flag", flag() == nil and saved()["/r/R/.git"] == nil)

-- ---- the real shell line, against a real repo ----
local R = T .. "/repo"
local function sh(c) return os.execute("cd '" .. R .. "' && " .. c .. " >/dev/null 2>&1") == true end
local function capture(c) local p = io.popen(c .. " 2>/dev/null"); local s = p and p:read("*a") or ""; if p then p:close() end; return s end
os.execute("mkdir -p '" .. R .. "/tests'")
local G = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false"
write(R .. "/app.sh", "greet() { echo hi; }\n")
write(R .. "/tests/greet.test.sh", '. ./app.sh; [ "$(greet)" = hi ] && echo "ok   - greets" || { echo "FAIL - greets"; exit 1; }\n')
local okRepo = sh(G .. " init -q") and sh(G .. " add -A") and sh(G .. " commit -qm base")
check("a real repo on main", okRepo)
local GATE = 'rc=0; for f in tests/*.test.sh; do sh "$f" || rc=1; done; exit $rc'
local function runIt(tag)
  local line = core.mergeGateCmd({ command = GATE, run = core.mainGreenRun(GATE, "main") }, R, T .. "/" .. tag .. ".log")
  local _, _, code = os.execute(line)
  local out = read(T .. "/" .. tag .. ".log") or ""
  return { state = core.mergeGateOutcome(code, out), code = code, output = out, command = GATE, branch = "main" }, out
end
local r1, o1 = runIt("green")
check("a green main passes  (" .. o1:gsub("\n", " | ") .. ")", r1.state == "passed")
check("...and says the commit it tested", core.mainGreenSha(o1) == capture("git -C '" .. R .. "' rev-parse HEAD"):match("%x+"))
write(R .. "/app.sh", "greet() { echo go away; }\n")
local r2, o2 = runIt("dirty")
check("uncommitted changes in the main checkout: couldn't run, never red  (" .. o2:gsub("\n", " | ") .. ")",
      r2.state == "couldntRun" and o2:find("uncommitted changes", 1, true) ~= nil and not o2:find("FAIL", 1, true))
sh(G .. " commit -qam rude")
local r3, o3 = runIt("red")
local v3 = core.mainGreenVerdict(nil, r3, now)
check("a red main is red, with its failing line  (" .. o3:gsub("\n", " | "):gsub("FAIL", "F-AIL") .. ")",
      r3.state == "failed" and v3 and v3.state == "red" and v3.lines == "FAIL - greets"
      and v3.sha == capture("git -C '" .. R .. "' rev-parse HEAD"):match("%x+"))
sh(G .. " checkout -qb feat/other")
local r4, o4 = runIt("branch")
check("a main checkout on another branch: couldn't run  (" .. o4:gsub("\n", " | ") .. ")",
      r4.state == "couldntRun" and o4:find("feat/other", 1, true) ~= nil)
check("...and the checkout wasn't touched", capture("git -C '" .. R .. "' status --porcelain") == "")

finish()
