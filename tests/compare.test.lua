-- compare.test.lua : BEHAVIORAL fixture for the Compare tab's GitHub check (2026-10-27). Loads the
-- real claude-dashboard.lua under a stubbed hs (the tab-title-scan.test.lua harness); hs.task is a
-- recorder and a fake gh answers each recorded job, so the whole run -- who you are, each person's
-- search, each repo's commit list, each commit's lines, the hidden counts -- plays out here.
--
-- Adam, 2026-10-27: "i want to get rid of the requirements tab and instead have a compare tab, i want
-- to be able to list up to 5 github users and have it track our commits + lines per day vs the people
-- on the comparison list for a weekly leaderboard, we'd do a daily check against github". The check
-- never blocks the panel (the 2026-10-22 lesson: one synchronous grep froze it 1.75s): every gh call
-- is a background task, a few at a time, and a hung one can't stall the run.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- compare.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/+$", "")
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/sessions"')
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
write(T .. "/.claude/cc-config.json", json.encode({}))
write(T .. "/.panel-alive", tostring(os.time()))
local STORE = T .. "/.claude/cc-compare.json"

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SESSIONS_DIR = T .. "/sessions", HOME = T, SHELL = "/bin/zsh" }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local js, toasts, PANEL_CB = {}, {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s)
      js[#js + 1] = s
      local m = tostring(s or ""):match("^ccToast%((.*)%)$")
      if m then toasts[#toasts + 1] = m end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local GH = "/fake/bin/gh"
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
    attributes = function(p) if p == GH then return { mode = "file" } end return nil, "no such file" end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    execs[#execs + 1] = tostring(cmd)
    if tostring(cmd) == "command -v gh" then return GH .. "\n" end
    return ""
  end,
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
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) PANEL_CB = fn end }, { __index = function() return function() return mkstub() end end })
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
-- background tasks are recorders: the fake gh below answers them
local TASKS = {}
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, running = false, terminated = false }
  function t:start() self.running = true; return self end
  function t:isRunning() return self.running end
  function t:terminate() self.terminated = true; self.running = false; return true end
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
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
local NOW = core.isoToEpoch("2026-10-27T18:00:00Z")
fx.now = function() return NOW end
local function tick() return quiet(function() fx._refreshBody() end) end
local function post(tbl) return quiet(function() PANEL_CB({ body = json.encode(tbl) }) end) end
check("the panel's message channel is wired", type(PANEL_CB) == "function")
check("the Compare check is wired", type(fx.stepCompare) == "function" and type(fx.compareStart) == "function")
if type(PANEL_CB) ~= "function" or type(fx.stepCompare) ~= "function" then finish() end

-- ---- the fake gh ----
local A, B, C = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
local asked = {}
local function ghAnswer(args)
  local cmd = table.concat(args, " ")
  asked[#asked + 1] = cmd
  if cmd == "api user -q .login" then return 0, "WSAdam\n", "" end
  if args[2] == "graphql" then return 0, cmd:find("login=jonkopp17", 1, true) and "20\n" or "0\n", "" end
  if cmd:find("search/commits", 1, true) then
    if cmd:find("author:jonkopp17", 1, true) then return 0, "Org/crm-sdk\nOrg/crm-sdk\nOrg/mail\n", "" end
    if cmd:find("author:WSAdam", 1, true) then return 0, "WSAdam/claude-shepherd\n", "" end
    return 0, "", ""
  end
  if cmd:find("repos/Org/crm-sdk/commits?", 1, true) then return 0, A .. " 2026-10-26T15:00:00Z\n", "" end
  if cmd:find("repos/Org/mail/commits?", 1, true) then return 0, B .. " 2026-10-27T13:00:00Z\n", "" end
  if cmd:find("repos/WSAdam/claude-shepherd/commits?", 1, true) then return 0, C .. " 2026-10-26T20:00:00Z\n", "" end
  if cmd:find("/commits/" .. A, 1, true) then return 0, '{"a":120,"d":20,"f":[{"n":"a.ts","a":20,"d":5},{"n":"yarn.lock","a":100,"d":15}]}', "" end
  if cmd:find("/commits/" .. B, 1, true) then return 0, '{"a":7,"d":2,"f":[{"n":"m.ts","a":7,"d":2}]}', "" end
  if cmd:find("/commits/" .. C, 1, true) then return 0, '{"a":300,"d":10,"f":[{"n":"x.lua","a":300,"d":10}]}', "" end
  return 1, "", "gh: Not Found (HTTP 404)"
end
local function ghTasks() local out = {} for _, t in ipairs(TASKS) do if t.bin == GH then out[#out + 1] = t end end return out end
local function running() local n = 0 for _, t in ipairs(ghTasks()) do if t.running then n = n + 1 end end return n end
local maxRunning = 0
local function drain()   -- answer every running gh task until none is left (and note the most at once)
  for _ = 1, 500 do
    local t
    for _, x in ipairs(ghTasks()) do if x.running then t = x; break end end
    if not t then return end
    maxRunning = math.max(maxRunning, running())
    t.running = false
    local code, out, errText = ghAnswer(t.args)
    quiet(function() t.cb(code, out, errText) end)
  end
end
local function lastBoard()
  for i = #js, 1, -1 do
    local body = tostring(js[i]):match("^window%.ccCompare%((.*)%)$")
    if body then return json.decode(body) end
  end
  return nil
end
local function rowOf(week, login)
  for _, r in ipairs(week and week.rows or {}) do if r.login == login then return r end end
  return nil
end

-- 1. nothing calls GitHub until the tab is opened
for _ = 1, 3 do tick() end
check("no tab opened, no file: the tick never calls GitHub", #ghTasks() == 0 and read(STORE) == nil)

-- 2. opening the tab starts the first check, in the background
js = {}
post({ a = "compare-load" })
check("opening Compare creates its file", read(STORE) ~= nil)
check("...and starts a check in the background: who you are first",
      #ghTasks() == 1 and ghTasks()[1].running and table.concat(ghTasks()[1].args, " ") == "api user -q .login")
local b0 = lastBoard()
check("...and answers the tab at once, saying it's checking", b0 ~= nil and b0.running == true)
drain()
local b1 = lastBoard()
check("the check finishes and the tab gets the board", b1 ~= nil and b1.running == false and b1.self == "WSAdam")
local you = b1 and rowOf(b1.weeks.this, "WSAdam")
check("...your week: 1 commit, +300 -10  (" .. tostring(you and you.commits) .. ")", you and you.commits == 1 and you.add == 300 and you.del == 10)
check("...saved to the file", (read(STORE) or ""):find(C, 1, true) ~= nil)
check("no gh call ever ran in the foreground", (function()
  for _, c in ipairs(execs) do if c:find("gh api", 1, true) or c:find(" api ", 1, true) then return false end end
  return true end)())

-- 3. adding people: a bad name is refused, the rest saved, and their check starts at once
js = {}
local before = #ghTasks()
post({ a = "compare-users", users = { "jonkopp17", "bad name", "WSAdam" } })
local b2 = lastBoard()
check("adding a list saves the good names (not you)", b2 and #b2.users == 1 and b2.users[1] == "jonkopp17"
      and (read(STORE) or ""):find("jonkopp17", 1, true) ~= nil)
check("...names the one it refused", b2 and type(b2.rejected) == "table" and b2.rejected[1] == "bad name")
check("...and checks GitHub right away", #ghTasks() > before)
drain()
check("never more than 4 gh calls at once  (" .. maxRunning .. ")", maxRunning >= 1 and maxRunning <= 4)
local b3 = lastBoard()
local jon = b3 and rowOf(b3.weeks.this, "jonkopp17")
check("their week is on the board: 2 commits, lockfiles skipped  (" .. tostring(jon and (jon.commits .. " +" .. jon.add .. " -" .. jon.del)) .. ")",
      jon and jon.commits == 2 and jon.add == 27 and jon.del == 7)
check("...the repos they wrote to", jon and #jon.repos == 2 and jon.repos[1].repo == "Org/crm-sdk")
check("...and what GitHub hides from you", jon and jon.hidden == 20)
check("...ranked above you", b3 and b3.weeks.this.rows[1].login == "jonkopp17")

-- 4. once a day: the tick doesn't check again today, and does tomorrow
local n = #ghTasks()
tick(); tick()
check("the tick doesn't check again the same day", #ghTasks() == n)
NOW = core.isoToEpoch("2026-10-28T13:00:00Z")
tick()
check("...and does the next day, in the background", #ghTasks() > n and running() > 0)

-- 5. Refresh while a check runs starts no second one
local m = #ghTasks()
toasts = {}
post({ a = "compare-refresh" })
check("Refresh during a check starts no second one", #ghTasks() == m)
check("...and says so", #toasts >= 1)

-- 6. a hung gh can't stall the run: past its deadline it's ended and the run moves on
local hung = {}
for _, t in ipairs(ghTasks()) do if t.running then hung[#hung + 1] = t end end
NOW = NOW + 300
tick()
local ended = 0
for _, t in ipairs(hung) do if t.terminated then ended = ended + 1 end end
check("a gh call past its deadline is ended  (" .. ended .. "/" .. #hung .. ")", #hung > 0 and ended == #hung)
drain()
local b4 = lastBoard()
check("...and the run still finishes", b4 and b4.running == false)

-- 7. Refresh after it's done checks again
local k = #ghTasks()
post({ a = "compare-refresh" })
check("Refresh when idle checks again", #ghTasks() > k)
drain()

-- 8. no gh: the tab says so, and nothing runs
fx._compare.gh = false
local g = #ghTasks()
js = {}
quiet(function() fx.compareStart("refresh") end)
local b5 = lastBoard()
check("without gh, nothing runs and the tab says why", #ghTasks() == g and b5 and tostring(b5.error):find("gh", 1, true) ~= nil)

os.execute('rm -rf "' .. T .. '"')
finish()
