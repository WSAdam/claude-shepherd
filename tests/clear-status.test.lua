-- clear-status.test.lua : BEHAVIORAL fixture for a card stuck at a status it no longer has.
-- 2026-11-13: Chargeback Sentinel's card stayed red over Claude Code's own "switch to Opus 4.8?"
-- question after Adam closed it with X: a dismissal writes the interrupt marker and fires no hook,
-- and a card waiting on Adam stopped reading its transcript once it went stale (90s), so nothing
-- could see the marker. Loads the real claude-dashboard.lua under a stubbed hs and drives real ticks.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- clear-status.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local REPO = T .. "/ChargebackSentinel"
os.execute('mkdir -p "' .. T .. '/status" "' .. REPO .. '"')
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%S.700Z", t) end

local now = os.time()
-- Sentinel's question was armed 31s before Adam closed it; both are half an hour old now (stale)
local armed, closed = now - 1831, now - 1800
-- the live transcript's last records, trimmed: the refused reply, Claude Code's notice and its
-- meta note, an api-request record, then the marker Adam's X wrote
local REFUSED = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the captcha step."}]},"timestamp":"' .. iso(armed - 12) .. '"}\n'
local NOTICE = '{"type":"system","subtype":"informational","content":"Opus 5.5\'s safeguards stopped the response above · continuing once with that noted","timestamp":"' .. iso(armed - 11) .. '"}\n'
local META = '{"type":"user","message":{"role":"user","content":"Your response above was stopped by a safety classifier."},"isMeta":true,"timestamp":"' .. iso(armed - 11) .. '"}\n'
local APIREQ = '{"type":"api-request","timestamp":"' .. iso(armed - 11) .. '"}\n'
local MARKER = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"' .. iso(closed) .. '"}\n'
local OLD_MARKER = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"' .. iso(armed - 60) .. '"}\n'
local ASKING = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[]}}]},"timestamp":"' .. iso(armed) .. '"}\n'
local QUESTION = "Opus 5.5's safeguards flagged this session. Switch to Opus 4.8 and keep going whenever this happens?"

local function card(key, pid, transcript, fields)
  write(T .. "/" .. key .. ".jsonl", transcript)
  local s = { status = "approval", session_id = key, name = "ChargebackSentinel", cwd = REPO,
              since = armed, updated = armed, editor = "vscode", host_window = tostring(2000 + pid),
              session_pid = tostring(pid), transcript_path = T .. "/" .. key .. ".jsonl",
              pending = { tool = "AskUserQuestion", prompt = true, message = QUESTION, summary = QUESTION,
                          ask = { { question = QUESTION, options = { { label = "Yes" }, { label = "No" } } } } } }
  for k, v in pairs(fields or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
-- d1: Sentinel's card -- the question Adam closed
card("d1", 101, REFUSED .. NOTICE .. META .. APIREQ .. MARKER)
-- d2: a question still up in the tab (its tool_use is the newest record) -- really waiting
card("d2", 102, REFUSED .. ASKING)
-- d3: a dialog Claude Code raised on its own AFTER an earlier interrupt -- writes nothing, still up
card("d3", 103, REFUSED .. OLD_MARKER)

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps = 0
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local menus = {}
local panelCb
local function menuStub()
  return setmetatable({ setMenu = function(_, m) menus[#menus + 1] = m end },
    { __index = function() return function() return mkstub() end end })
end
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
  menubar = { new = function() return menuStub() end },
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
  -- the panel's message channel: keep the callback so the test can post what a right-click posts
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
local fx = dash.fx
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
tick(); tick()
local I = items()
check("all three cards are on the panel", I.d1 and I.d2 and I.d3)
if not (I.d1 and I.d2 and I.d3) then finish() end

-- ---- a prompt dismissed in the tab (2026-11-13) ----
check("a question Adam closed in the tab half an hour ago leaves its card idle  (status=" .. tostring(I.d1.status) .. ")",
      I.d1.status == "idle")
check("...so it no longer needs Adam  (needsYou=" .. tostring(I.d1.needsYou) .. ")", I.d1.needsYou ~= "needs")
check("...and offers no answer buttons for a question that's gone", I.d1.pending == nil)
check("a question still up in the tab keeps its card red", I.d2.status == "approval")
check("a dialog raised after an earlier interrupt keeps its card red", I.d3.status == "approval")
check("the status file itself is left alone (a heal, like the others)", read(T .. "/status/d1.json"):find('"approval"', 1, true) ~= nil)
-- a tick that can't read the transcript (a transient failure) keeps the heal
local realReadTail = fx.readTail
fx.readTail = function() return nil end
tick()
fx.readTail = realReadTail
check("a tick with no transcript read keeps the card idle", items().d1.status == "idle")
-- any hook write after it is the truth again
do
  local s = json.decode(read(T .. "/status/d1.json"))
  s.updated = os.time(); s.since = os.time()
  write(T .. "/status/d1.json", json.encode(s))
  write(T .. "/d1.jsonl", REFUSED .. NOTICE .. META .. APIREQ .. MARKER
    .. '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"try again"}]},"timestamp":"' .. iso(os.time()) .. '"}\n'
    .. '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"AskUserQuestion","input":{"questions":[]}}]},"timestamp":"' .. iso(os.time()) .. '"}\n')
end
tick()
check("a new question after it turns the card red again", items().d1.status == "approval")

-- ---- right-click Clear status (2026-11-13) ----
-- 2026-11-13 (Adam): "from right click i'd like a way to clear a set status on a card".
local function rightClick(key)
  menus = {}
  quiet(function() panelCb({ body = json.encode({ a = "ctx-menu", v = key, text = "" }) }) end)
  return menus[#menus] or {}
end
local function clearLine(menu)
  for _, m in ipairs(menu) do
    if type(m.title) == "string" and m.title:find("^Clear status") then return m end
  end
  return nil
end
-- c1: frozen at Working for two hours; c2: an API error; c3: a question Shepherd holds on the card;
-- c4: the approval gate holding a tool; c5: finished
local hourAgo = now - 7200
card("c1", 111, REFUSED, { status = "working", since = hourAgo, updated = hourAgo, pending = nil })
card("c2", 112, REFUSED, { status = "error", since = hourAgo, updated = hourAgo, pending = nil,
                           error_kind = "rate_limit", error_message = "You've hit your limit" })
card("c3", 113, REFUSED .. ASKING, { since = now - 5, updated = now - 5, ask_nonce = "n3", ask_until = now + 100 })
card("c4", 114, REFUSED, { since = now - 5, updated = now - 5, gate = "waiting", gate_nonce = "g4",
                           pending = { tool = "Bash", summary = "rm -rf build", message = "rm -rf build" } })
card("c5", 115, REFUSED, { status = "done", pending = nil })
tick(); tick()
I = items()
check("the five Clear status cards are on the panel", I.c1 and I.c2 and I.c3 and I.c4 and I.c5)

local line = clearLine(rightClick("d1"))
check("a red card's right-click menu has Clear status", line ~= nil and type(line.fn) == "function" and not line.disabled)
-- a hold that turns up while the menu is open: the file is re-checked, nothing is written
do
  local s = json.decode(read(T .. "/status/d1.json"))
  s.ask_nonce, s.ask_until = "late", os.time() + 100
  write(T .. "/status/d1.json", json.encode(s))
  quiet(function() line.fn() end)
  check("a hold that appeared since the menu opened refuses the clear", json.decode(read(T .. "/status/d1.json")).status == "approval")
  s.ask_nonce, s.ask_until = nil, nil
  write(T .. "/status/d1.json", json.encode(s))
end
quiet(function() line.fn() end)
local d1 = json.decode(read(T .. "/status/d1.json"))
check("Clear status writes the card's file idle and drops the gone prompt",
      d1.status == "idle" and d1.pending == nil and d1.session_id == "d1")
tick()
check("...and the card reads idle, not needing Adam", items().d1.status == "idle" and items().d1.needsYou ~= "needs")

line = clearLine(rightClick("c1"))
check("a card frozen at Working has Clear status", line ~= nil and not line.disabled)
quiet(function() line.fn() end)
check("...and clearing it makes it idle", json.decode(read(T .. "/status/c1.json")).status == "idle")
line = clearLine(rightClick("c2"))
quiet(function() if line and line.fn then line.fn() end end)
local c2 = json.decode(read(T .. "/status/c2.json"))
check("clearing an error card drops the error", c2.status == "idle" and c2.error_kind == nil and c2.error_message == nil)

line = clearLine(rightClick("c3"))
check("a question Shepherd holds on the card: Clear status is greyed out, saying why  (" .. tostring(line and line.title) .. ")",
      line ~= nil and line.disabled == true and line.fn == nil and line.title:find("held on the card", 1, true) ~= nil)
line = clearLine(rightClick("c4"))
check("the approval gate holding a tool: greyed out, Approve or Deny it  (" .. tostring(line and line.title) .. ")",
      line ~= nil and line.disabled == true and line.fn == nil and line.title:find("Approve or Deny", 1, true) ~= nil)
check("...and both files are untouched",
      json.decode(read(T .. "/status/c3.json")).status == "approval" and json.decode(read(T .. "/status/c4.json")).gate == "waiting")
check("a finished card has no Clear status line", clearLine(rightClick("c5")) == nil)
check("no keystroke anywhere", taps == 0)
finish()
