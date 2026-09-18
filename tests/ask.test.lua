-- ask.test.lua : BEHAVIORAL fixture for Shepherd answers (2026-09-11).
-- 2026-09-11 batch E2E: a unit waited on Adam's word; Shepherd flashed its card, but Focus only
-- brought him to the tab and nothing in Shepherd could answer it. cc-ask.sh now holds the
-- question (ask_nonce + ask_until on the status file); Adam answers on the card.
-- Loads the real claude-dashboard.lua under a stubbed hs, with one VS Code session whose
-- question is held, and drives the real panel messages: the card is marked and alerts once,
-- a click writes <key>.answer bound to the nonce on disk, a second click writes nothing, a
-- stale nonce is refused, the form's Send answers and Answer in the tab instead work, and no
-- keystroke is ever sent.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- ask.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local REPO = T .. "/proj"
local ASK = T .. "/ask"
os.execute('mkdir -p "' .. T .. '/status" "' .. REPO .. '" "' .. ASK .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(p) local h = io.open(p, "r"); if h then h:close() return true end return false end
local Q1 = { { question = "Leave the worktree, then ask to merge?", header = "Finish", multiSelect = false,
               options = { { label = "Yes, leave then ask", description = "the fence allows it" }, { label = "Not yet" } } } }
local Q2 = { { question = "Which toppings?", multiSelect = true, options = { { label = "Cheese" }, { label = "Ham" } } },
             { question = "Which size?", multiSelect = false, options = { { label = "Small" }, { label = "Large" } } } }
local function session(nonce, ask)
  write(T .. "/status/s1.json", json.encode({ status = "approval", session_id = "s1", name = "proj", cwd = REPO,
    since = now - 5, updated = now - 5, editor = "vscode", host_window = "1051", session_pid = "2000",
    pending = { tool = "AskUserQuestion", summary = ask[1].question, message = ask[1].question, ask = ask },
    ask_nonce = nonce, ask_until = now + 600 }))
end
session("100.1", Q1)

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", CC_ASK_DIR = ASK, HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, overlays, toasts, panelCb = 0, {}, {}, nil
local function webviewHandle()
  -- 2026-09-11: Shepherd's messages are toasts in its own panel (ccToast), never hs.alert's overlay
  return setmetatable({ evaluateJavaScript = function(_, js)
      local m = tostring(js or ""):match("^ccToast%((.*)%)$")
      if m then toasts[#toasts + 1] = m end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local WATCHERS = {}
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
  -- keep every watcher's dir + callback, so the test can fire one the way FSEvents would
  pathwatcher = { new = function(dir, cb) WATCHERS[#WATCHERS + 1] = { dir = dir, cb = cb }; return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function(s) overlays[#overlays + 1] = tostring(s) end },
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
  -- the panel's message channel: keep the callback so the test can post what a click posts
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
local fx, core = dash.fx, dash.core
check("the panel's message channel is wired", type(panelCb) == "function")
local function tick() return quiet(function() fx._refreshBody() end) end
local function item() for _, it in ipairs(fx._shownItems or {}) do if it.key == "s1" then return it end end end
local function click(a, v, text) return quiet(function() panelCb({ body = json.encode({ a = a, v = v or "", text = text or "" }) }) end) end
local function asksAlerts() local n = 0 for _, a in ipairs(toasts) do if a:find("asks:", 1, true) then n = n + 1 end end return n end
local ANS = ASK .. "/s1.answer"

tick(); tick()
local it = item()
check("the session is on the panel", it ~= nil)
if not it then finish() end
check("a held question marks the card", it.askHeld == true)
check("...with the question on its meta line", tostring(it.askLine):find("Leave the worktree", 1, true) ~= nil)
check("...and one-click answers (a single-choice question)", it.askView and it.askView.simple == true and it.askView.options[1] == "Yes, leave then ask")
check("it alerts once, as a toast in Shepherd's panel  (" .. asksAlerts() .. ")", asksAlerts() == 1)
check("...never as the big on-screen overlay that covers every window  (" .. #overlays .. ")", #overlays == 0)
tick()
check("...and not again on the next tick", asksAlerts() == 1)
local row
for _, r in ipairs(core.instancesPayload(it.stackKey, fx._shownItems, {}, {}, {}).members) do if r.key == "s1" then row = r end end
check("Instances carries the question and its answers", row and row.ask and row.ask.options[2] == "Not yet")

click("answer", "s1", "0")
local body = json.decode(read(ANS) or "null")
check("a click on an answer writes the answer file", type(body) == "table")
check("...bound to the nonce on disk", body and body.nonce == "100.1")
check("...carrying the label, keyed by the question", body and body.answers and body.answers["Leave the worktree, then ask to merge?"] == "Yes, leave then ask")
os.remove(ANS)   -- the hook claimed it
click("answer", "s1", "1")
check("a second click writes nothing (that question is answered)", not exists(ANS))
tick()
check("the card stops asking once answered", not item().askHeld)

-- a newer question on the same session: the old nonce on disk is gone
session("200.2", Q1)
tick()
check("a new question is held again", item().askHeld == true)
check("...and alerts once more", asksAlerts() == 2)
write(T .. "/status/s1.json", (read(T .. "/status/s1.json"):gsub('"200%.2"', '"999.9"')))
quiet(function() fx.answerAsk("s1", { nonce = "200.2", answers = { x = "y" } }) end)
check("an answer for a nonce that isn't on disk any more is refused", not exists(ANS))

-- several parts: the form's Send answers
session("300.3", Q2)
tick()
check("a several-part question needs the form", item().askView.simple == false)
click("answer", "s1", "0")
check("a bare option index doesn't answer a several-part question", not exists(ANS))
click("answer-ask", "s1", json.encode({ { labels = { "Cheese" } } }))
check("Send answers with a part missing writes nothing", not exists(ANS))
click("answer-ask", "s1", json.encode({ { labels = { "Cheese", "Ham" } }, { other = "extra large" } }))
body = json.decode(read(ANS) or "null")
check("Send answers with every part answered writes the answers",
      body and body.nonce == "300.3" and type(body.answers["Which toppings?"]) == "table"
      and body.answers["Which toppings?"][2] == "Ham" and body.answers["Which size?"] == "extra large")
os.remove(ANS)

-- Answer in the tab instead
session("400.4", Q1)
tick()
click("release-ask", "s1")
body = json.decode(read(ANS) or "null")
check("Answer in the tab instead hands it back to the tab's picker", body and body.nonce == "400.4" and body.release == true)
os.remove(ANS)
click("answer", "s1", "0")
check("...after which Shepherd doesn't answer it", not exists(ANS))

-- ---- a new question reaches the panel at once (2026-09-18) ----
-- 2026-09-18 measured live: a held question took 626-1127ms to show. The status dir's watcher is
-- slowed by the panel's own 1Hz heartbeat writes there (12-1443ms to deliver); a watcher on the
-- quiet ask dir delivers in ~11ms, and cc-ask.sh touches .poke there once the card can show it.
do
  local askWatch
  for _, w in ipairs(WATCHERS) do if w.dir == ASK then askWatch = w end end
  check("Shepherd watches the ask dir, not only the status dir", askWatch ~= nil and type(askWatch.cb) == "function")
  local bodies, realBody = 0, fx._refreshBody
  fx._refreshBody = function(...) bodies = bodies + 1; return realBody(...) end
  session("500.5", Q1)
  if askWatch then quiet(function() askWatch.cb({ ASK .. "/.poke" }) end) end
  fx._refreshBody = realBody
  check("the hook's poke refreshes the panel right away, without waiting for the tick  (refreshes=" .. bodies .. ")", bodies == 1)
  local seen = item()
  check("...so the card has the new question", seen ~= nil and seen.askHeld == true and seen.ask_nonce == "500.5")
  bodies = 0
  fx._refreshBody = function(...) bodies = bodies + 1; return realBody(...) end
  if askWatch then quiet(function() askWatch.cb({ ASK .. "/s1.answer.tmp.1" }) end) end
  fx._refreshBody = realBody
  check("Shepherd's own answer-file writes there don't set off a refresh each", bodies == 0)

  -- the click shows at once: the card's buttons used to stay live until the next 1Hz tick
  session("600.6", Q2); tick()
  check("(a held two-part question is on the card)", item() ~= nil and item().askHeld == true)
  click("answer-ask", "s1", json.encode({ { labels = { "Ham" } }, { labels = { "Small" } } }))
  check("Send answers clears the question off the card at once, no tick needed", item() ~= nil and item().askHeld ~= true)
  os.remove(ANS)
  session("700.7", Q1); tick()
  click("release-ask", "s1")
  check("...and so does Answer in the tab instead", item() ~= nil and item().askHeld ~= true)
  os.remove(ANS)
  session("800.8", Q1); tick()
  click("answer", "s1", "1")
  check("...and so does a one-click answer", exists(ANS) and item() ~= nil and item().askHeld ~= true)
  os.remove(ANS)
end

check("no keystroke anywhere", taps == 0)
check("no on-screen overlay anywhere in the flow  (" .. table.concat(overlays, " | ") .. ")", #overlays == 0)
-- alerts.onScreen = true brings the overlay back (read live from cc-config.json)
os.execute('mkdir -p "' .. T .. '/.claude"')
write(T .. "/.claude/cc-config.json", '{"alerts":{"onScreen":true}}')
quiet(function() fx.alert("overlay test") end)
check("alerts.onScreen true: the overlay is back", overlays[#overlays] == "overlay test")
finish()
