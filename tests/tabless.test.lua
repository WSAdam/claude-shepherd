-- tabless.test.lua : BEHAVIORAL fixture for tab-less sessions (2026-09-11).
-- 2026-09-11: starting a new conversation in a Chargeback Sentinel tab left the old session's
-- claude process running with no tab; Shepherd counted it as a second session in the window.
-- Loads the real claude-dashboard.lua under a stubbed hs (ps and kill answered by the stub),
-- with two sessions on one VS Code host whose tab bridge lists ONE Claude tab, then drives the
-- real effects: the leftover is marked, End session refuses anything but that leftover, and
-- ending it frees the real tab.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- tabless.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local REPO = T .. "/ChargebackSentinel"
local BR = T .. "/.claude/cc-bridge"
os.execute('mkdir -p "' .. T .. '/status" "' .. REPO .. '" "' .. BR .. '/1051.in" "' .. BR .. '/1051.out"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function exists(p) local h = io.open(p, "r"); if h then h:close() return true end return false end
-- the real tab (6698) and the leftover (957b), both children of extension host 1051
for _, s in ipairs({ { "6698", "25135", "Chargeback Sentinel handoff and QuickBase API gaps" },
                     { "957b", "2713", "Nexio rematch run 2026-09-09-ddaece11" } }) do
  write(T .. "/" .. s[1] .. ".jsonl", '{"type":"ai-title","aiTitle":"' .. s[3] .. '","sessionId":"' .. s[1] .. '"}\n')
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"ChargebackSentinel","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"1051","session_pid":"%s","transcript_path":"%s"}',
    s[1], REPO, now - 60, now - 60, s[2], T .. "/" .. s[1] .. ".jsonl"))
end
write(BR .. "/1051.json", json.encode({ v = 1, pid = 1051, version = "0.1.0", tabs = { { label = "Chargeback Sentinel hand…", group = 1, active = true } }, at = now }))
-- 2026-09-11 (wgsUltra): a lone session whose tab shows its FIRST PROMPT, not its AI title
os.execute('mkdir -p "' .. T .. '/wgsUltra"')
write(T .. "/wg.jsonl", '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"from your printed guide show me the onboarding"}]}}\n'
  .. '{"type":"ai-title","aiTitle":"Project onboarding","sessionId":"wg"}\n')
write(T .. "/status/wg.json", string.format(
  '{"status":"done","session_id":"wg","name":"wgsUltra","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"1052","session_pid":"3000","transcript_path":"%s"}',
  T .. "/wgsUltra", now - 60, now - 60, T .. "/wg.jsonl"))
write(BR .. "/1052.json", json.encode({ v = 1, pid = 1052, version = "0.1.0", tabs = { { label = "from your printed guide …", group = 1, active = true } }, at = now }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, kills, PS = 0, {}, {}
PS["2713"] = "1051 /Users/adam/.vscode/extensions/anthropic.claude-code-2.1.268-darwin-arm64/resources/native-binary/claude --output-format stream-json"
PS["25135"] = "1051 /Users/adam/.vscode/extensions/anthropic.claude-code-2.1.268-darwin-arm64/resources/native-binary/claude --output-format stream-json"
local alerts = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
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
    attributes = function(path)
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    local pid = cmd:match("^ps %-o ppid=,command= %-p (%d+)$")
    if pid then return PS[pid] or "" end
    local k = cmd:match("^kill %-TERM (%d+)$")
    if k then kills[#kills + 1] = k; PS[k] = nil; return "" end
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
fx.TABLESS_AFTER = 0   -- the live panel waits a few seconds before believing a mismatch
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
tick(); tick()
local I = items()
check("both sessions are on the panel", I["6698"] and I["957b"])
if not (I["6698"] and I["957b"]) then finish() end
check("the leftover with no tab is marked tab-less", I["957b"].tabless == true)
check("...the real tab isn't", not I["6698"].tabless)
check("a lone session whose tab shows its first prompt, not its AI title, is never tab-less (wgsUltra)",
      I.wg and not I.wg.tabless)
check("it still counts toward the shared window until it's gone (it could be the Claude sidebar)",
      I["6698"].sharedWindow == 2)
local row
for _, r in ipairs(core.instancesPayload(I["957b"].stackKey, fx._shownItems, {}, {}, {}).members) do
  if r.key == "957b" then row = r end
end
check("Instances marks it too", row and row.tabless == true)

quiet(function() fx.endSession("6698") end)
check("End session refuses a session that has a tab", #kills == 0 and exists(T .. "/status/6698.json"))
PS["2713"] = "999 /x/native-binary/claude --output-format stream-json"
quiet(function() fx.endSession("957b") end)
check("...and a process that isn't a child of its window's host", #kills == 0)
PS["2713"] = "1051 /Users/adam/.vscode/extensions/anthropic.claude-code-2.1.268-darwin-arm64/resources/native-binary/claude --output-format stream-json"
quiet(function() fx.endSession("957b") end)
check("End session on the leftover stops that process  (killed=" .. table.concat(kills, ",") .. ")", #kills == 1 and kills[1] == "2713")
check("...and drops its card", not exists(T .. "/status/957b.json"))
tick()
I = items()
check("the real tab no longer shares its window", I["6698"] and I["6698"].sharedWindow == nil)

-- ---- 2026-09-14 live: the Sept 11 conversation's claude process lingered for three days after a
-- new conversation started in the Chargeback Sentinel tab, until Adam asked. A leftover that stays
-- tab-less and idle past the grace period is now ended by Shepherd itself, and says so. ----
local toasts = {}
do local real = fx.alert; fx.alert = function(m, s) toasts[#toasts + 1] = tostring(m); return real(m, s) end end
for _, s in ipairs({ { "a11", "3100", "Nexio rematch run", "done", now - 3600 }, { "a12", "3200", "Busy leftover", "working", now } }) do
  write(T .. "/" .. s[1] .. ".jsonl", '{"type":"ai-title","aiTitle":"' .. s[3] .. '","sessionId":"' .. s[1] .. '"}\n')
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"%s","session_id":"%s","name":"ChargebackSentinel","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"1051","session_pid":"%s","transcript_path":"%s"}',
    s[4], s[1], REPO, s[5], s[5], s[2], T .. "/" .. s[1] .. ".jsonl"))
  PS[s[2]] = "1051 /Users/adam/.vscode/extensions/anthropic.claude-code-2.1.268-darwin-arm64/resources/native-binary/claude --output-format stream-json"
end
write(BR .. "/1051.json", json.encode({ v = 1, pid = 1051, version = "0.4.0", tabs = { { label = "Chargeback Sentinel hand…", group = 1, active = true } }, at = os.time() }))
kills = {}
tick(); tick()
I = items()
check("both leftovers are marked tab-less", I.a11 and I.a11.tabless == true and I.a12 and I.a12.tabless == true)
check("...and neither is ended the moment it's marked", #kills == 0)
fx._tablessSince.a11 = os.time() - 700   -- tab-less (and idle) for longer than the 10-minute grace period
fx._tablessSince.a12 = os.time() - 700
tick()
check("an idle leftover past the grace period is ended by Shepherd  (killed=" .. table.concat(kills, ",") .. ")",
      #kills == 1 and kills[1] == "3100" and not exists(T .. "/status/a11.json"))
check("...with a toast saying so", table.concat(toasts, " | "):find("no tab for", 1, true) ~= nil)
check("a working leftover is left alone", exists(T .. "/status/a12.json"))
tick()
check("...and isn't retried every tick (one attempt each)", #kills == 1)
check("no keystroke anywhere", taps == 0)
finish()
