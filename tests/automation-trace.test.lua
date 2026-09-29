-- automation-trace.test.lua : BEHAVIORAL fixture for the automation dry run and trace (2026-09-29,
-- build program unit 14). Loads the real claude-dashboard.lua under a stubbed hs (timer beats are
-- collected and fired by hand, the panel's message channel and every evaluateJavaScript are kept)
-- and drives FX.automationAct, the one door every automatic effect goes through: with
-- automation.dryRun or the kind's own <feature>.dryRun on it records would_<kind> and acts on
-- nothing (checked with the FX recorder); otherwise it acts and records acted, or refused with why.
-- Repeats bump a count instead of a row or a ledger line; the Trace serves them newest first; and
-- Settings saves the switches into their own blocks. Side-effect-free: every file lives in a temp
-- dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")
local newRecorder = dofile(HERE .. "support/fx_recorder.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- automation-trace.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/vs" "' .. T .. '/inbox"')
local NOW = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local CFG = T .. "/.claude/cc-config.json"
local function config(t)
  t.bridge = { enabled = false, intervalSeconds = 2 }
  write(CFG, json.encode(t))
end
config({})
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/vs", since = NOW - 100,
              updated = NOW - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
for _, k in ipairs({ "idle1", "idle2", "idle3", "idle4" }) do status(k) end
status("busy1", { status = "working" })

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", CC_INBOX_DIR = T .. "/inbox", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local js = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) js[#js + 1] = s end },
    { __index = function() return function() return webviewHandle() end end })
end
local beatsDue = {}
local function beats()
  local n = 0
  while #beatsDue > 0 do
    local b = table.remove(beatsDue, 1)
    n = n + 1
    b.fn()
    if n > 50 then break end
  end
  return n
end
local panelCb
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
    mkdir = function(path) os.execute('mkdir -p "' .. tostring(path) .. '"'); return true end,
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
  doEvery = function() return mkstub() end,
  doAfter = function(delay, fn) beatsDue[#beatsDue + 1] = { delay = delay, fn = fn }; return mkstub() end,
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local logs = {}
local function capture(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end
print = capture
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
print = realPrint
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local core, fx = dash.core, dash.fx
beatsDue = {}
check("the panel's message channel is wired", type(panelCb) == "function")
check("FX.automationAct exists", type(fx.automationAct) == "function")
if type(fx.automationAct) ~= "function" then finish() end

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
local clock = NOW
fx.now = function() return clock end
local function quietly(fn) logs = {}; print = capture; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local function events(typ, key)
  local out = {}
  for _, ev in ipairs(ledger) do if ev.type == typ and (key == nil or ev.key == key) then out[#out + 1] = ev end end
  return out
end
local function rows(key, kind)
  local out = {}
  for _, e in ipairs(fx._automation.trace) do
    if e.key == key and (kind == nil or e.kind == kind) then out[#out + 1] = e end
  end
  return out
end
local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("every fixture session is on the panel", byK.idle1 and byK.idle2 and byK.idle3 and byK.idle4 and byK.busy1)
if not (byK.idle1 and byK.idle2 and byK.idle3 and byK.busy1) then finish() end

-- ---- live: automation acts, and the Trace says so ----
local typed = {}
quietly(function() fx.typeWhenReady(byK.idle1, "autofeed", function() typed.idle1 = true end, { summary = "feed 'fix the tests'" }) end)
quietly(beats)
local r1 = rows("idle1", "feed")
check("live: an automated send types", typed.idle1 == true)
check("live: ...and the Trace records it acted, with what and who sent it",
      #r1 == 1 and r1[1].outcome == "acted" and r1[1].summary == "feed 'fix the tests'" and r1[1].by == "autofeed")
local a1 = events("automation", "idle1")
check("live: ...ledgered once as automation/acted", #a1 == 1 and a1[1].kind == "feed" and a1[1].outcome == "acted")
check("live: nothing is ledgered as a would", #events("would_feed") == 0)

-- ---- dry run for all automation: nothing is acted on, a would is recorded ----
config({ automation = { dryRun = true } })
local rec = newRecorder()
local dryHeard = 0
quietly(function()
  fx.typeWhenReady(byK.idle2, "auto-continue", function()
    typed.idle2 = true
    core.handleAction(rec.fx, byK.idle2, "continue", "continue")
  end, { summary = "continue", onDry = function() dryHeard = dryHeard + 1 end })
end)
quietly(beats)
check("dry run: nothing is typed", typed.idle2 == nil)
check("dry run: ...the recorder saw no effect at all  (calls=" .. rec.count() .. ")", rec.count() == 0)
local w1 = events("would_continue", "idle2")
check("dry run: would_continue is ledgered, with what it would have done",
      #w1 == 1 and w1[1].summary == "continue" and w1[1].by == "auto-continue")
local r2 = rows("idle2", "continue")
check("dry run: the Trace row says would", #r2 == 1 and r2[1].outcome == "would")
check("dry run: the sender hears it was a dry run (so it can release what it reserved)", dryHeard == 1)
-- the same decision again: one row, counted; no second ledger line
clock = NOW + 60
quietly(function()
  fx.typeWhenReady(byK.idle2, "auto-continue", function() typed.idle2 = true end, { summary = "continue" })
end)
quietly(beats)
r2 = rows("idle2", "continue")
check("dry run: a repeat bumps the row's count (x2) instead of adding one",
      #r2 == 1 and r2[1].count == 2 and r2[1].first == NOW and r2[1].at == NOW + 60)
check("dry run: ...and is not ledgered again", #events("would_continue", "idle2") == 1)
-- the recorder, through the door directly
local rec2 = newRecorder()
local _, rA, rB = quietly(function()
  return fx.automationAct("continue", byK.idle3, { summary = "continue" }, function()
    core.handleAction(rec2.fx, byK.idle3, "continue", "continue")
    return true
  end)
end)
check("dry run: FX.automationAct runs nothing and says why  (" .. tostring(rA) .. ", " .. tostring(rB) .. ")",
      rA == false and rB == core.AUTOMATION_DRY and rec2.count() == 0)
-- a direct effect (a respawn) in dry run
local spawned = false
quietly(function() fx.automationAct("respawn", byK.idle3, { summary = "relaunch from cwd" }, function() spawned = true; return true end) end)
check("dry run: a respawn launches nothing", spawned == false)
check("dry run: ...would_respawn is ledgered", #events("would_respawn", "idle3") == 1)
-- a mailbox send in dry run writes nothing
local _, mp, mwhy = quietly(function() return fx.mailboxSend("idle3", "Summarise what you just did.") end)
local inbox = io.popen('ls -1 "' .. T .. '/inbox/idle3" 2>/dev/null'):read("*a") or ""
check("dry run: a mailbox send writes no message  (" .. tostring(mp) .. ", " .. tostring(mwhy) .. ")",
      not mp and mwhy == core.AUTOMATION_DRY and inbox == "")
check("dry run: ...would_mailbox is ledgered", #events("would_mailbox", "idle3") == 1 and #events("mailbox_sent", "idle3") == 0)

-- ---- one feature's own switch: only that kind is held ----
config({ autoContinue = { dryRun = true } })
quietly(function()
  fx.typeWhenReady(byK.idle3, "auto-continue", function() typed.idle3c = true end, { summary = "continue" })
end)
quietly(beats)
clock = NOW + 120
quietly(function()
  fx.typeWhenReady(byK.idle4, "autofeed", function() typed.idle4f = true end, { summary = "feed 'y'" })
end)
quietly(beats)
check("autoContinue.dryRun: auto-continue is held", typed.idle3c == nil and #events("would_continue", "idle3") == 1)
check("autoContinue.dryRun: ...auto-feed still types", typed.idle4f == true and #events("would_feed", "idle4") == 0)
local _, mp2 = quietly(function() return fx.mailboxSend("idle3", "Summarise what you just did.") end)
check("autoContinue.dryRun: ...and a mailbox send is written", type(mp2) == "string" and readFile(mp2) ~= nil)

-- ---- refusals: the readiness door, an effect's own `false, why`, FX.automationRefuse, an error ----
config({})
quietly(function() fx.typeWhenReady(byK.busy1, "router", function() typed.busy1 = true end, { summary = "feed 'z'" }) end)
quietly(beats)
local rb = rows("busy1", "route")
check("refused: a session mid-turn is a refused row, with why  (" .. tostring(rb[1] and rb[1].reason) .. ")",
      #rb == 1 and rb[1].outcome == "refused" and rb[1].reason == "working" and rb[1].summary == "feed 'z'" and not typed.busy1)
check("refused: ...ledgered as automation/refused", (function()
  for _, ev in ipairs(events("automation", "busy1")) do if ev.outcome == "refused" and ev.reason == "working" then return true end end
  return false
end)())
quietly(function() fx.automationAct("respawn", byK.idle4, { summary = "relaunch" }, function() return false, "spawn.live is off" end) end)
local rr = rows("idle4", "respawn")
check("refused: an effect's `false, why` is a refused row", #rr == 1 and rr[1].outcome == "refused" and rr[1].reason == "spawn.live is off")
quietly(function() fx.automationAct("feed", byK.idle4, { summary = "feed 'q'" }, function() fx.automationRefuse("no window match") end) end)
local rf = rows("idle4", "feed")
check("refused: FX.automationRefuse inside the effect makes it refused, not acted  (" .. #rf .. " rows)",
      #rf == 2 and rf[2].outcome == "refused" and rf[2].reason == "no window match")
local okErr = quietly(function() fx.automationAct("rule", byK.idle4, { summary = "log" }, function() error("boom") end) end)
local re = rows("idle4", "rule")
check("refused: an effect that errors still errors (the tick behaves as before)", okErr == false)
check("refused: ...and the Trace records it", #re == 1 and re[1].outcome == "refused" and tostring(re[1].reason):find("boom", 1, true) ~= nil)

-- ---- the Trace view ----
js = {}
quietly(function() panelCb({ body = json.encode({ a = "open-trace", v = "idle2", text = "" }) }) end)
local payload
for _, s in ipairs(js) do
  local body = s:match("^window%.ccTrace%((.*)%)$")
  if body then payload = json.decode(body) end
end
check("trace view: open-trace answers window.ccTrace", type(payload) == "table")
if type(payload) ~= "table" then os.execute('rm -r "' .. T .. '"'); finish() end
local ents = payload.entries or {}
check("trace view: newest first", #ents >= 5 and (ents[1].at or 0) >= (ents[#ents].at or 0))
local sawX2 = false
for _, e in ipairs(ents) do if e.key == "idle2" and e.kind == "continue" and e.count == 2 then sawX2 = true end end
check("trace view: a repeated decision comes as one row x2", sawX2)
check("trace view: focused on the session it was opened for", payload.focus == "idle2")
check("trace view: says whether dry run is on (off now)", type(payload.dry) == "table" and payload.dry.on == false)
check("trace view: labels for every kind", type(payload.kinds) == "table" and payload.kinds.tabless_end ~= nil and payload.kinds.continue ~= nil)

-- ---- Settings: Save writes the switches into their own blocks, keeping the rest ----
config({ rules = { enabled = true }, tabless = { autoEndMinutes = 20 } })
quietly(function()
  panelCb({ body = json.encode({ a = "save-config", v = "", text = json.encode({
    config = { queue = { autofeed = true, routing = { enabled = false, starveMinutes = 0 } } },
    gate = false, autoLaunch = false,
    dryRun = { automation = false, rules = true, queue = true, tabless = false } }) }) })
end)
local saved = json.decode(readFile(CFG) or "{}") or {}
check("settings: rules.dryRun saved, rules.enabled kept",
      saved.rules and saved.rules.dryRun == true and saved.rules.enabled == true)
check("settings: queue.dryRun saved beside the form's queue block",
      saved.queue and saved.queue.dryRun == true and saved.queue.autofeed == true)
check("settings: automation.dryRun saved off", saved.automation and saved.automation.dryRun == false)
check("settings: tabless.autoEndMinutes kept", saved.tabless and saved.tabless.autoEndMinutes == 20 and saved.tabless.dryRun == false)
-- a later Save that doesn't send the switches keeps them
quietly(function()
  panelCb({ body = json.encode({ a = "save-config", v = "", text = json.encode({
    config = { queue = { autofeed = false, routing = { enabled = false, starveMinutes = 0 } } }, gate = false }) }) })
end)
saved = json.decode(readFile(CFG) or "{}") or {}
check("settings: a Save without the switches keeps queue.dryRun and rules.dryRun",
      saved.queue and saved.queue.dryRun == true and saved.queue.autofeed == false and saved.rules and saved.rules.dryRun == true)

os.execute('rm -r "' .. T .. '"')
finish()
