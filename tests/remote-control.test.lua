-- remote-control.test.lua : BEHAVIORAL fixture for Remote Control on VS Code tabs (2026-10-22).
-- Loads the real claude-dashboard.lua under a stubbed hs (the maingreen.test.lua harness), with
-- Claude Code's own session registry (~/.claude/sessions/<pid>.json) in a temp dir, and plays the
-- clock forward past the grace. Every effect that would type is a recorder.
--
-- 2026-10-22: three VS Code tabs restored together on 2026-10-16 came back without Remote Control
-- (no bridgeSessionId in their session files) though remoteControlAtStartup is on. The /rc sweep is
-- terminal-only, so no card said so and nothing connected them for six days. Now each card carries
-- the state, an out one shows a chip, and a tab alone in its window gets /remote-control typed once,
-- after the grace -- never one that's in (a second /remote-control disconnects), never a shared window.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- remote-control.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/+$", "")
local SD = T .. "/sessions"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. SD .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(T .. "/.claude/cc-config.json", json.encode({}))
write(T .. "/.panel-alive", tostring(now))
-- four VS Code sessions: alone and out; two out in one shared window; alone and in
local function status(key, pid, win, extra)
  local t = { status = "idle", session_id = key, name = key, cwd = "/r/" .. key, since = now - 60, updated = now - 60,
              editor = "vscode", host_window = win, session_pid = pid, model = "claude-opus-5-5" }
  for k, v in pairs(extra or {}) do t[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(t))
end
local function sess(pid, key, bridge, version)
  write(SD .. "/" .. pid .. ".json", json.encode({ pid = tonumber(pid), sessionId = key, kind = "interactive",
    entrypoint = "claude-vscode", version = version or "2.1.301", bridgeSessionId = bridge }))
end
status("alone", "9028", "501");      sess("9028", "alone", nil)
status("sharedA", "9101", "502");    sess("9101", "sharedA", nil)
status("sharedB", "9102", "502");    sess("9102", "sharedB", nil)
status("inrc", "9200", "503");       sess("9200", "inrc", "session_01MsGA8cr4NRdQDfAuJn45qY")

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SESSIONS_DIR = SD, HOME = T, SHELL = "/bin/zsh" }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
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
  execute = function() return "" end,
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

-- every typing effect is a recorder: what would be typed, into which session
local typed = {}
fx.typeWhenReady = function(it, typist, fn) typed[#typed + 1] = { key = it.key, typist = typist, fn = fn }; return true end
fx.typeIntoWindow = function(_, text) typed[#typed].text = text; return true end
local clock = now
fx.now = function() return clock end
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function fire() for _, t in ipairs(typed) do if t.fn and not t.text then pcall(t.fn) end end end

tick()
local I = items()
check("a card whose session file has no bridgeSessionId reads out of Remote Control  (" .. tostring(I.alone and I.alone.rc) .. ")",
      I.alone ~= nil and I.alone.rc == "off" and I.alone.rcOff == true)
check("...a card that's in reads in, with no chip", I.inrc ~= nil and I.inrc.rc == "on" and not I.inrc.rcOff)
check("...a card out in a shared window shows the chip too", I.sharedA ~= nil and I.sharedA.rcOff == true)
check("nothing is typed before the grace (remoteControlAtStartup may still connect it)", #typed == 0)

clock = now + 120
tick()
fire()
local alone = 0
for _, t in ipairs(typed) do if t.key == "alone" then alone = alone + 1 end end
check("past the grace, the tab alone in its window gets /remote-control  (" .. #typed .. " sends)",
      alone == 1 and typed[1].text == "/remote-control" and typed[1].typist == "rc-sweep")
check("...never a tab in a shared window, nor one that's in", #typed == 1)

clock = now + 300
tick()
fire()
check("...and only once per session (a second /remote-control would disconnect it)", #typed == 1)

-- the session connects: its file gains a bridgeSessionId; the next registry read clears the chip
sess("9028", "alone", "session_01NewlyConnected")
clock = now + 400
tick()
I = items()
check("once it connects, the card reads in and the chip goes", I.alone.rc == "on" and not I.alone.rcOff)

-- Settings' remoteControl.sweepOnStartup = false keeps Shepherd's hands off (the chip still shows)
status("fresh", "9300", "504"); sess("9300", "fresh", nil)
write(T .. "/.claude/cc-config.json", json.encode({ remoteControl = { sweepOnStartup = false } }))
clock = now + 500
tick()
clock = now + 700
tick()
fire()
I = items()
check("with the sweep off nothing is typed, but the chip shows", #typed == 1 and I.fresh ~= nil and I.fresh.rcOff == true)

finish()
