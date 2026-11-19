-- shared-window.test.lua : BEHAVIORAL fixture for the shared-window keystroke guard
-- (2026-09-10). Several Claude tabs in one VS Code window share its extension host
-- (host_window), and Shepherd types into the WINDOW -- the keys land in whichever tab is
-- in front. Loads the real claude-dashboard.lua under a stubbed hs (a fake VS Code window
-- per folder; hs.eventtap and window focus counted), with two sessions on one host and one
-- alone, then drives the real effects: the pair must get no focus and no keystroke, the
-- lone session must still be typed into.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- shared-window.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: two tabs in one window (host 500), one session alone (host 600) ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MAIN, OTHER = T .. "/repo", T .. "/other"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. MAIN .. '" "' .. OTHER .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
-- 2026-09-11: Adam's real config -- the SSH remote bridge off (its default). The tab bridge's
-- switch first shared that `bridge.enabled` key, so this switched Close-by-tab off.
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2}}')
for _, s in ipairs({ { "a1", MAIN, "500", "501" }, { "a2", MAIN, "500", "502" }, { "b1", OTHER, "600", "601" } }) do
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%s","session_pid":"%s"}',
    s[1], s[2]:match("([^/]+)$"), s[2], now, now, s[3], s[4]))
end

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs: a VS Code window per folder; keystrokes + focus counted ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, focusCalls, alerts = 0, 0, {}
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
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,   -- beats never fire
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
-- a window for EACH folder, so without the guard the pair's window would really be focused
local function fakeWindow(title) return { title = function() return title end, focus = function() focusCalls = focusCalls + 1 end } end
local fakeApp = { allWindows = function() return { fakeWindow("main.lua — repo"), fakeWindow("notes.md — other") } end,
                  activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local logs = {}
print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
print = realPrint
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local core, fx = dash.core, dash.fx
-- 2026-09-11: messages are FX.alert toasts in the panel, not hs.alert overlays -- capture them there
do local real = fx.alert; fx.alert = function(m, s) alerts[#alerts + 1] = tostring(m); return real(m, s) end end

local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
local a1, a2, b1 = byK.a1, byK.a2, byK.b1
check("all three sessions are on the panel", a1 and a2 and b1)
if not (a1 and a2 and b1) then finish() end
check("the two tabs in one window are flagged as sharing it  (got=" .. tostring(a1.sharedWindow) .. ")",
      a1.sharedWindow == 2 and a2.sharedWindow == 2)
check("the session alone in its window isn't", b1.sharedWindow == nil)

local function quiet(fn) logs = {}; print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local function logged(needle) for _, l in ipairs(logs) do if l:find(needle, 1, true) then return true end end return false end
local function refusalAlerts() local n = 0 for _, a in ipairs(alerts) do if a:find("Claude tabs", 1, true) then n = n + 1 end end return n end

-- a nudge (every hotkey / deck / rule / detail-panel action takes this path)
local _, acted = quiet(function() return core.handleAction(fx, a1, "nudge", "hello") end)
check("a nudge to a shared-window session is refused", acted == nil)
check("...before any focus or keystroke  (focus=" .. focusCalls .. " taps=" .. taps .. ")", focusCalls == 0 and taps == 0)
check("...and an alert says why", refusalAlerts() == 1)

-- the direct paths (/clear, image paste, Improve...) hit the effect layer itself
local _, pasted = quiet(function() return fx.pasteIntoWindow(fx.targetFor(a1), { text = "x" }) end)
check("a direct paste into a shared window reports not delivered", pasted == false)
check("...logs the refusal", logged("NOT sent") and logged("hosts 2 Claude sessions"))
check("...still with no focus or keystroke", focusCalls == 0 and taps == 0)
check("the alert shows at most once a minute per session", refusalAlerts() == 1)
local _, keyed = quiet(function() return fx.sendKeys(fx.targetFor(a2), { { mods = {}, key = "return" } }) end)
check("a key chain into a shared window reports not delivered", keyed == false and focusCalls == 0 and taps == 0)

-- close would be ⌘⇧W on the whole window: every session in it
local _, closed = quiet(function() return core.handleAction(fx, a2, "close") end)
local f = io.open(T .. "/status/a2.json", "r"); local stillThere = f ~= nil; if f then f:close() end
check("close on a shared-window session is refused and its card stays", closed == nil and stillThere and focusCalls == 0 and taps == 0)

-- ---- 2026-09-11: the companion extension closes exactly that session's tab ----
-- (Adam had to close tabs by hand: nothing outside VS Code could pick one.) The bridge in
-- the window (host 500) reports its Claude tabs by name; Shepherd asks it to close the one
-- named like this session's tab -- never a keystroke, and only when exactly one matches.
local BR = T .. "/.claude/cc-bridge"
os.execute('mkdir -p "' .. BR .. '/500.in" "' .. BR .. '/500.out"')
local function exists(p) local h = io.open(p, "r"); if h then h:close() return true end return false end
local function registry(labels)
  local tabs = {}
  for _, l in ipairs(labels) do tabs[#tabs + 1] = { label = l, group = 1, active = false } end
  write(BR .. "/500.json", json.encode({ v = 1, pid = 500, version = "0.1.0", folders = { MAIN }, tabs = tabs, at = os.time() }))
end
local function inbox()
  local out, p = {}, io.popen('ls -1 "' .. BR .. '/500.in" 2>/dev/null')
  if p then for l in p:lines() do out[#out + 1] = l end; p:close() end
  return out
end
write(T .. "/a2.jsonl", '{"type":"ai-title","aiTitle":"Fix the sibling window matching","sessionId":"a2"}\n')
a2.transcript_path = T .. "/a2.jsonl"
registry({ "Fix the sibling window m…", "Other work" })
local _, viaBridge = quiet(function() return core.handleAction(fx, a2, "close") end)
check("close on a shared-window session asks the bridge in its window to close its tab", viaBridge == "close")
local sent = inbox()
local cmd = sent[1] and json.decode(io.open(BR .. "/500.in/" .. sent[1]):read("*a")) or {}
check("...one close command, by the name the tab shows  (label=" .. tostring(cmd.label) .. ")",
      #sent == 1 and cmd.op == "close" and cmd.label == "Fix the sibling window m…")
check("...with no focus and no keystroke", focusCalls == 0 and taps == 0)
check("...and the card stays until the bridge confirms", exists(T .. "/status/a2.json"))
write(BR .. "/500.out/" .. tostring(cmd.id) .. ".json", json.encode({ v = 1, id = cmd.id, ok = true }))
quiet(function() fx.tabBridgePollResults() end)
check("once the bridge confirms the tab closed, the card goes", not exists(T .. "/status/a2.json"))
check("...and the result is cleaned up", not exists(BR .. "/500.out/" .. tostring(cmd.id) .. ".json"))

-- two tabs share the name: the bridge must not guess
os.remove(BR .. "/500.in/" .. tostring(sent[1]))
write(T .. "/a1.jsonl", '{"type":"ai-title","aiTitle":"Twin","sessionId":"a1"}\n')
a1.transcript_path = T .. "/a1.jsonl"
registry({ "Twin", "Twin" })
alerts = {}
local _, twin = quiet(function() return core.handleAction(fx, a1, "close") end)
check("two tabs sharing the name -> Close is refused, nothing is sent", twin == nil and #inbox() == 0)
local why = table.concat(alerts, " | ")
check("...the card stays and one alert says why  (" .. why .. ")",
      exists(T .. "/status/a1.json") and #alerts == 1 and why:find("2 Claude tabs", 1, true) ~= nil)

-- no bridge in that window at all
os.remove(BR .. "/500.json")
alerts = {}
local _, nobridge = quiet(function() return core.handleAction(fx, a1, "close") end)
check("no bridge in the window -> refused, with the reason  (" .. table.concat(alerts, " | ") .. ")",
      nobridge == nil and #inbox() == 0 and table.concat(alerts, " "):find("isn't running", 1, true) ~= nil)

-- the bridge never answers: give up, keep the card, say so
registry({ "Twin", "Solo" })
write(T .. "/a1.jsonl", '{"type":"ai-title","aiTitle":"Solo","sessionId":"a1"}\n')
alerts = {}
quiet(function() return core.handleAction(fx, a1, "close") end)
for _, p in pairs(fx._tabBridgePending or {}) do p.at = p.at - 60 end
quiet(function() fx.tabBridgePollResults() end)
check("a bridge that never answers -> the card stays and an alert says so",
      exists(T .. "/status/a1.json") and table.concat(alerts, " "):find("didn't answer", 1, true) ~= nil)
check("...and the unanswered command is withdrawn", #inbox() == 0)
check("the bridge path never focused a window or pressed a key", focusCalls == 0 and taps == 0)

-- the lone session is untouched by the guard
local _, lone = quiet(function() return fx.pasteIntoWindow(fx.targetFor(b1), { text = "x" }) end)
check("a session alone in its window is still typed into (its window focused, the paste scheduled)",
      lone == true and focusCalls == 1 and not logged("NOT sent to"))
-- 2026-11-19, REQUIREMENT CHANGE: "the router never picks a shared-window session" went with the task
-- queue and its router (core.sessionFree)

-- 2026-09-11: Jump brings the session's own tab forward through the tab bridge -- Adam's second
-- Focus in a two-tab window landed on the other tab's chat.
registry({ "Twin", "Solo" })
for _, n in ipairs(inbox()) do os.remove(BR .. "/500.in/" .. n) end
local before = focusCalls
local _, jumped = quiet(function() return core.handleAction(fx, a1, "focus") end)
local sel = inbox()
local sc = sel[1] and json.decode(io.open(BR .. "/500.in/" .. sel[1]):read("*a")) or {}
check("Jump focuses the window, then asks its tab bridge to bring the session's tab forward  (op=" .. tostring(sc.op) .. " label=" .. tostring(sc.label) .. ")",
      jumped == "focus" and focusCalls == before + 1 and #sel == 1 and sc.op == "select" and sc.label == "Solo")
check("...still without a keystroke", taps == 0)

-- ---- 2026-09-11 live: two never-used chats ("Claude Code") in Shepherd's own window kept the
-- shared-window banner up as "also: 2 idle"; no name told them apart, so nothing closed them. ----
os.execute('mkdir -p "' .. T .. '/win7" "' .. BR .. '/700.in" "' .. BR .. '/700.out"')
write(T .. "/r7.jsonl", '{"type":"ai-title","aiTitle":"Claude tabs workflow integration","sessionId":"r7"}\n')
for _, s in ipairs({ { "r7", "701", T .. "/r7.jsonl" }, { "e7", "702", T .. "/e7.jsonl" }, { "f7", "703", T .. "/f7.jsonl" } }) do
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"idle","session_id":"%s","name":"win7","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"700","session_pid":"%s","transcript_path":"%s"}',
    s[1], T .. "/win7", now, now, s[2], s[3]))
end
local function reg7(labels, version)
  local tabs = {}
  for _, l in ipairs(labels) do tabs[#tabs + 1] = { label = l, group = 1, active = false } end
  write(BR .. "/700.json", json.encode({ v = 1, pid = 700, version = version or "0.4.0", folders = { T .. "/win7" }, tabs = tabs, at = os.time() }))
end
reg7({ "Claude tabs workflow int…", "Claude Code", "Claude Code" })
quiet(function() fx._refreshBody() end)
byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("never-used chats are marked empty", byK.e7 and byK.e7.emptyChat == true and byK.f7 and byK.f7.emptyChat == true)
check("...the real chat isn't, and its card knows its window has 2  (" .. tostring(byK.r7 and byK.r7.windowEmptyChats) .. ")",
      byK.r7 and not byK.r7.emptyChat and byK.r7.windowEmptyChats == 2)
local function inbox7()
  local out, p = {}, io.popen('ls -1 "' .. BR .. '/700.in" 2>/dev/null')
  if p then for l in p:lines() do local fh = io.open(BR .. "/700.in/" .. l); out[#out + 1] = json.decode(fh:read("*a")); fh:close() end; p:close() end
  return out
end
quiet(function() fx.closeEmptyChats("r7", "all") end)
local ec = inbox7()
check("Close them: one close per empty chat, each \"Claude Code\" with the count it expects  (n=" .. #ec .. ")",
      #ec == 2 and ec[1].label == "Claude Code" and ec[1].empty == 2 and ec[2].empty == 1 and ec[1].op == "close")
os.execute('rm -f "' .. BR .. '/700.in/"*')
reg7({ "Claude tabs workflow int…", "Claude Code", "Claude Code", "Claude Code" })
alerts = {}
quiet(function() fx._refreshBody(); fx.closeEmptyChats("r7", "all") end)
check("an extra \"Claude Code\" tab (a restored old chat) -> nothing sent, and it says why",
      #inbox7() == 0 and table.concat(alerts, " "):find("restored old chat", 1, true) ~= nil)
check("no keystroke for any of it", taps == 0)

-- ---- 2026-11-19 live: Close on Project Stupid's card refused twice, "its tab has no name yet, so it
-- can't be told apart" -- its lead was a never-used chat (no transcript yet) sharing a window with a
-- named session, and the card's Close only ever tried the tab's name. A never-used chat closes as one
-- of its window's interchangeable "Claude Code" tabs (the empty-chat rule). ----
os.execute('mkdir -p "' .. T .. '/win8" "' .. BR .. '/800.in" "' .. BR .. '/800.out"')
write(T .. "/n8.jsonl", '{"type":"ai-title","aiTitle":"Stupid project work","sessionId":"n8"}\n')
for _, s in ipairs({ { "n8", "801", T .. "/n8.jsonl", "done" }, { "e8", "802", T .. "/e8-never-written.jsonl", "idle" } }) do
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"%s","session_id":"%s","name":"win8","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"800","session_pid":"%s","transcript_path":"%s"}',
    s[4], s[1], T .. "/win8", now, now, s[2], s[3]))
end
local function reg8(labels)
  local tabs = {}
  for _, l in ipairs(labels) do tabs[#tabs + 1] = { label = l, group = 1, active = false } end
  write(BR .. "/800.json", json.encode({ v = 1, pid = 800, version = "0.6.0", folders = { T .. "/win8" }, tabs = tabs, at = os.time() }))
end
local function inbox8()
  local out, p = {}, io.popen('ls -1 "' .. BR .. '/800.in" 2>/dev/null')
  if p then for l in p:lines() do local fh = io.open(BR .. "/800.in/" .. l); out[#out + 1] = json.decode(fh:read("*a")); fh:close() end; p:close() end
  return out
end
reg8({ "Stupid project work", "Claude Code" })
quiet(function() fx._refreshBody() end)
byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("the never-used chat is marked empty, in a window it shares", byK.e8 and byK.e8.emptyChat == true and (tonumber(byK.e8.sharedWindow) or 0) >= 2)
alerts = {}
local tapsBefore = taps
local _, r8 = quiet(function() return core.handleAction(fx, byK.e8, "close") end)
local c8 = inbox8()
check("Close on its card asks the bridge to close one of the window's \"Claude Code\" tabs  (n=" .. #c8 .. " alerts=" .. table.concat(alerts, " | ") .. ")",
      r8 == "close" and #c8 == 1 and c8[1].op == "close" and c8[1].label == "Claude Code" and c8[1].empty == 1)
check("...with no \"has no name yet\" refusal and no keystroke",
      not table.concat(alerts, " "):find("no name yet", 1, true) and taps == tapsBefore)
os.execute('rm -f "' .. BR .. '/800.in/"*')
reg8({ "Stupid project work", "Claude Code", "Claude Code" })
alerts = {}
quiet(function() fx._refreshBody() end)
byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
quiet(function() core.handleAction(fx, byK.e8, "close") end)
check("an extra \"Claude Code\" tab (a restored old chat) -> nothing sent, and it says why",
      #inbox8() == 0 and table.concat(alerts, " "):find("restored old chat", 1, true) ~= nil)
finish()
