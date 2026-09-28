-- readiness.test.lua : BEHAVIORAL fixture for readiness before typing (2026-09-28, build
-- program unit 11). Loads the real claude-dashboard.lua under a stubbed hs (timer beats are
-- collected and fired by hand; kitty's `kitty @` commands are recorded and answered) and
-- drives FX.typeWhenReady, the one door every automated typist goes through: it must wait
-- out the settle time, refuse a busy session with ONE typing_refused event and then leave it
-- alone until its status changes, let only one send per session queue, re-check the live
-- status file and kitty's screen right before typing, and type kitty's text and Return as
-- two writes. Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- readiness.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/vs" "' .. T .. '/kt"')
local NOW = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2}}')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/vs", since = NOW - 100,
              updated = NOW - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("idle1"); status("busy1", { status = "working" }); status("fresh1", { updated = NOW - 1 })
status("twice1"); status("moved1")
status("kit1", { editor = "kitty", cwd = T .. "/kt", kitty_window_id = "7", kitty_listen_on = "unix:" .. T .. "/k.sock" })

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
-- timer beats are collected; beats() fires what is due, in order
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
-- kitty @ commands: recorded; ls says the window is there, get-text answers with `screenNow`
local kittyCalls, screenNow = {}, ""
local function kittyTask(bin, cb, argv)
  local sub
  for _, a in ipairs(argv or {}) do
    if a == "ls" or a == "get-text" or a == "send-text" or a == "send-key" then sub = a; break end
  end
  return {
    start = function() kittyCalls[#kittyCalls + 1] = { sub = sub, argv = argv }; return true end,
    waitUntilExit = function()
      if cb then
        local out = (sub == "ls" and '[{"tabs":[{"windows":[{"id":7}]}]}]') or (sub == "get-text" and screenNow) or ""
        cb(0, out, "")
      end
    end,
    terminationStatus = function() return 0 end,
  }
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local taps = 0
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
  alert = { show = function() end },
  task = { new = kittyTask },
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
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "base", "console" }) do
  hs[ns] = mkstub()
end
rawset(hs.eventtap, "keyStroke", function() taps = taps + 1 end)
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
beatsDue = {}   -- nothing that load scheduled belongs to these checks

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
local clock = NOW
fx.now = function() return clock end
local function refusals(key)
  local out = {}
  for _, ev in ipairs(ledger) do if ev.type == "typing_refused" and ev.key == key then out[#out + 1] = ev end end
  return out
end
local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("every fixture session is on the panel", byK.idle1 and byK.busy1 and byK.fresh1 and byK.kit1 and byK.twice1 and byK.moved1)
if not (byK.idle1 and byK.busy1 and byK.fresh1 and byK.kit1) then finish() end
local function quietly(fn) logs = {}; print = capture; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end

-- a finished, settled session: typed (in the serialized slot)
local typed = {}
local _, sched = quietly(function() return fx.typeWhenReady(byK.idle1, "autofeed", function() typed.idle1 = true end) end)
quietly(beats)
check("a settled, finished session is typed into", sched == true and typed.idle1 == true)
check("...with nothing refused", #refusals("idle1") == 0)

-- a session mid-turn: refused now, ledgered once, then left alone until its status changes
local refusedWhy
local _, s1 = quietly(function() return fx.typeWhenReady(byK.busy1, "rule-nudge", function() typed.busy1 = true end,
  { onRefused = function(why) refusedWhy = why end }) end)
quietly(beats)
local r1 = refusals("busy1")
check("a session mid-turn is not typed into", s1 == false and not typed.busy1)
check("...one typing_refused event names the sender and why  (n=" .. #r1 .. ")",
      #r1 == 1 and r1[1].by == "rule-nudge" and r1[1].reason == "working")
check("...and the sender hears why", refusedWhy == "working")
quietly(function() fx.typeWhenReady(byK.busy1, "rule-nudge", function() typed.busy1 = true end) end)
quietly(function() fx.typeWhenReady(byK.busy1, "router", function() typed.busy1 = true end) end)
quietly(beats)
check("...later sends skip it without typing or another event (held until its status changes)",
      not typed.busy1 and #refusals("busy1") == 1)
local moved = {}; for k, v in pairs(byK.busy1) do moved[k] = v end
moved.status = "done"; moved.updated = NOW - 30
status("busy1", { status = "done", updated = NOW - 30 })
local _, s2 = quietly(function() return fx.typeWhenReady(moved, "autofeed", function() typed.busy1 = true end) end)
quietly(beats)
check("once its status changes the hold is gone and it is typed into", s2 == true and typed.busy1 == true)

-- a turn that just ended: waits out the settle time instead of refusing
local _, s3 = quietly(function() return fx.typeWhenReady(byK.fresh1, "summary", function() typed.fresh1 = true end) end)
local waitBeat = beatsDue[1]
check("a session that finished a second ago waits to settle (not refused)",
      s3 == true and #refusals("fresh1") == 0 and waitBeat ~= nil and math.abs((waitBeat.delay or 0) - 2) < 0.01)
check("...nothing is typed before the wait is over", not typed.fresh1)
clock = NOW + 2
quietly(beats)
check("...and once it has settled it is typed into", typed.fresh1 == true)

-- one send queued per session: a second sender in the same tick is refused
clock = NOW
local _, q1 = quietly(function() return fx.typeWhenReady(byK.twice1, "autofeed", function() typed.twiceA = true end) end)
local _, q2 = quietly(function() return fx.typeWhenReady(byK.twice1, "summary", function() typed.twiceB = true end) end)
quietly(beats)
local rq = refusals("twice1")
check("two senders for one session in one tick: the first types, the second is refused",
      q1 == true and q2 == false and typed.twiceA and not typed.twiceB)
check("...as queued  (n=" .. #rq .. " reason=" .. tostring(rq[1] and rq[1].reason) .. ")", #rq == 1 and rq[1].reason == "queued")

-- the status file moves on between scheduling and typing: the send is refused at send time
local _, m1 = quietly(function() return fx.typeWhenReady(byK.moved1, "router", function() typed.moved1 = true end,
  { onRefused = function(why) refusedWhy = why end }) end)
status("moved1", { status = "working", updated = NOW })
quietly(beats)
local rm = refusals("moved1")
check("a session that started a turn before its send fired is not typed into",
      m1 == true and not typed.moved1 and #rm == 1 and rm[1].reason == "working" and refusedWhy == "working")

-- kitty: the screen is read right before typing
local function fixture(name) return readFile(HERE .. "fixtures/kitty-screens/" .. name .. ".ansi") or "" end
screenNow = fixture("typed-text")
kittyCalls = {}
local _, k1 = quietly(function() return fx.typeWhenReady(byK.kit1, "autofeed", function() typed.kit1 = true end) end)
quietly(beats)
local gotText = false
for _, c in ipairs(kittyCalls) do if c.sub == "get-text" then gotText = true end end
local rk = refusals("kit1")
check("kitty: the screen is read right before typing", k1 == true and gotText)
check("kitty: never over Adam's half-typed prompt  (reason=" .. tostring(rk[1] and rk[1].reason) .. ")",
      not typed.kit1 and #rk == 1 and rk[1].reason == "composer")
local kitMoved = {}; for k, v in pairs(byK.kit1) do kitMoved[k] = v end
kitMoved.updated = NOW - 20
status("kit1", { editor = "kitty", cwd = T .. "/kt", kitty_window_id = "7", kitty_listen_on = "unix:" .. T .. "/k.sock", updated = NOW - 20 })
screenNow = fixture("dim-suggestion")
quietly(function() fx.typeWhenReady(kitMoved, "autofeed", function() typed.kit1 = true end) end)
quietly(beats)
check("kitty: an empty composer (a dim suggestion in it) is typed into", typed.kit1 == true)

-- kitty: the text and its Return are two writes, the Return after the text has landed
kittyCalls = {}
local _, delivered = quietly(function() return fx.typeIntoWindow(fx.targetFor(byK.kit1), "run the tests") end)
local beforeReturn = #kittyCalls
quietly(beats)
local subs = {}
for _, c in ipairs(kittyCalls) do subs[#subs + 1] = c.sub end
local textCall = kittyCalls[2] and kittyCalls[2].argv or {}
check("kitty: typing reports delivery once the text is written", delivered == true)
check("kitty: probe, text, then the Return as its own write  (" .. table.concat(subs, ",") .. ")",
      table.concat(subs, ",") == "ls,send-text,send-key" and beforeReturn == 2)
check("kitty: the text write carries no Return", textCall[#textCall] == "run the tests")
check("kitty: the Return is send-key enter", (kittyCalls[3] and kittyCalls[3].argv[#kittyCalls[3].argv]) == "enter")
check("kitty: nothing went through macOS keystrokes", taps == 0)

os.execute('rm -r "' .. T .. '"')
finish()
