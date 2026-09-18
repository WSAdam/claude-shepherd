-- fleet.test.lua : BEHAVIORAL fixture for batch driving, Shepherd's side (2026-09-11).
-- Loads the real claude-dashboard.lua under a stubbed hs (git facts and ps canned), with a
-- proposal on disk the way cc-fleet.sh writes it, then drives the real effects: the driver's
-- card and one alert, Approve writing a nonce-bound decision AND Shepherd's own grant, a tab
-- request answered with the new session's name and message, a delegated merge approved for
-- the unit's own session only, and Stop revoking it all. Never a keystroke.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- fleet.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local FD, MD, SD, BR = T .. "/.claude/cc-fleet", T .. "/.claude/cc-merge", T .. "/sessions", T .. "/.claude/cc-bridge"
os.execute('mkdir -p "' .. T .. '/status" "' .. FD .. '" "' .. MD .. '" "' .. SD .. '" "' .. BR .. '/701.in" "' .. BR .. '/701.out"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function status(key, cwd, pid, extra)
  local t = { status = "done", session_id = key, name = "A", cwd = cwd, since = now - 60, updated = now - 60,
              editor = "vscode", host_window = "701", session_pid = pid }
  for k, v in pairs(extra or {}) do t[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(t))
end
status("drv", "/r/A", "4242")
write(SD .. "/4242.json", json.encode({ pid = 4242, sessionId = "drv", name = "A-drv", cwd = "/r/A" }))
-- 2026-09-17 requirement change: this was 0.2.0, but a unit's tab now opens only in a window
-- whose bridge can tag it ("expect", 0.3.0+), so the healthy window runs the current bridge.
write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.4.0", folders = { "/r/A" }, tabs = {}, at = now }))
write(FD .. "/b1.json", json.encode({ v = 1, id = "b1", nonce = "n-b1", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
  repo = "/r/A", commonDir = "/r/A/.git", title = "Two helpers", mergeWhenGreen = true, at = now, phase = "proposed",
  units = { { type = "feat", slug = "alpha", task = "Add alpha.", branch = "feat/alpha" },
            { type = "fix", slug = "beta", task = "Fix beta.", branch = "fix/beta" } } }))
write(T .. "/.panel-alive", tostring(now))
local FACTS = {}
local function facts(wt, branch)
  FACTS[wt] = table.concat({ "@@listed", "worktree /r/A", "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD b", "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@status", "", "@@ahead", "1", "@@behind", "0",
    "@@commits", "abc1234\tchange", "@@stat", " 1 file changed", "@@files", "M\tx", "" }, "\n")
end

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", CC_SESSIONS_DIR = SD, HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, alerts = 0, {}
local function webviewHandle()
  -- 2026-09-11: messages are ccToast calls into the panel (FX.alert), not hs.alert overlays
  return setmetatable({ evaluateJavaScript = function(_, s)
      local m = tostring(s or ""):match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
    end },
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
    if cmd:find("@@listed", 1, true) then return FACTS[cmd:match("%-C '([^']+)'") or ""] or "" end
    if cmd:match("^ps %-o ppid= %-p %d+$") then return "701\n" end
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
local fx = rawget(_G, "__ccDashboard").fx
-- the test's repos (/r/A) are made-up paths: only b3's repo counts as gone (FX.fleetRepoGone)
fx.fleetRepoGone = function(bb) return bb.id == "b3" end
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function alerted(needle) local n = 0 for _, a in ipairs(alerts) do if a:find(needle, 1, true) then n = n + 1 end end return n end
local function decoded(path) local s = read(path); return s and json.decode(s) or nil end

tick()
local I = items()
check("the driver's card says what it proposes  (" .. tostring(I.drv and I.drv.fleet and I.drv.fleet.line) .. ")",
      I.drv and I.drv.fleet and I.drv.fleet.line == "⇉ proposes 2 units in A" and I.drv.fleet.needsYou)
check("one alert for the proposal", alerted("proposes 2 units") == 1)
tick()
check("...not one per tick", alerted("proposes 2 units") == 1)

-- Approve (Adam leaves "Claude may merge these when green" ticked)
quiet(function() fx.batchApprove("drv", '{"id":"b1","grantMerge":true}') end)
local d = decoded(FD .. "/b1.decision")
check("Approve writes the decision, bound to the proposal's nonce, with the merge grant",
      d and d.nonce == "n-b1" and d.verdict == "approve" and d.grantMerge == true)
local st = decoded(FD .. "/b1.state.json")
check("...and Shepherd records the grant in its own state", st and st.grant and st.grant.approved == true and st.grant.grantMerge == true)
tick()
I = items()
check("the card now says it's driving  (" .. tostring(I.drv.fleet.line) .. ")", I.drv.fleet.line == "⇉ driving 2 units in A · merges delegated")

-- the driver asks for unit alpha's tab. FX.openClaudeTab is asynchronous (it may have to open the
-- window first); the test plays its part and says when the tab was actually opened.
local opened = {}
fx.openClaudeTab = function(o) opened[#opened + 1] = o; return true end
write(FD .. "/b1.tab-alpha.json", json.encode({ v = 1, batch = "b1", slug = "alpha", session_id = "drv", nonce = "t-alpha", at = os.time() }))
tick()
check("a tab request starts opening the unit's tab", fx._fleetState.b1 and fx._fleetState.b1.units.alpha and fx._fleetState.b1.units.alpha.opening)
check("...through FX.openClaudeTab, told to report back", opened[1] and type(opened[1].onDone) == "function" and type(opened[1].beforeOpen) == "function")
-- 2026-09-11 live: Shepherd had to open the repo's window, VS Code restored its old Claude tabs, one
-- resumed its session -- and that session was taken for the unit although its tab never opened.
write(SD .. "/4999.json", json.encode({ pid = 4999, sessionId = "restored", name = "A-old", cwd = "/r/A" }))
quiet(function() fx.fleetTabPoll("b1", "alpha") end)
check("a session that resumes before the unit's tab has opened is not the unit's",
      read(FD .. "/b1.tab-alpha.answer") == nil and not (fx._fleetState.b1.units.alpha or {}).session)
quiet(function() opened[1].beforeOpen(); opened[1].onDone(true) end)
write(SD .. "/5001.json", json.encode({ pid = 5001, sessionId = "ua", name = "A-a1", cwd = "/r/A" }))
quiet(function() fx.fleetTabPoll("b1", "alpha") end)
local a = decoded(FD .. "/b1.tab-alpha.answer")
check("...and answers with the new session's name, bound to the request",
      a and a.ok == true and a.nonce == "t-alpha" and a.name == "A-a1" and a.sessionId == "ua")
check("...and the message to send it", a and type(a.message) == "string" and a.message:find('EnterWorktree with name "alpha"', 1, true) ~= nil)
st = decoded(FD .. "/b1.state.json")
check("Shepherd remembers which session is unit alpha", st and st.units and st.units.alpha and st.units.alpha.session and st.units.alpha.session.id == "ua")

-- 2026-09-11 E2E: a unit's tab never gets a name (its task arrives by message), so Shepherd tells
-- the window's bridge to EXPECT it before opening it: the bridge tags the tab it sees open.
local function inboxCmds()
  local out, p = {}, io.popen('ls -1 "' .. BR .. '/701.in" 2>/dev/null')
  if p then for n in p:lines() do out[#out + 1] = decoded(BR .. "/701.in/" .. n) or {}; end; p:close() end
  return out
end
local exp
for _, c in ipairs(inboxCmds()) do if c.op == "expect" then exp = c end end
check("opening a unit's tab first tells its window's bridge to expect it  (unit=" .. tostring(exp and exp.unit) .. ")",
      exp and exp.unit == "b1:alpha")
os.execute('rm -f "' .. BR .. '/701.in/"*')

-- unit alpha finishes and asks to merge: approved on the batch's grant
status("ua", "/r/A/.claude/worktrees/alpha", "5001")
facts("/r/A/.claude/worktrees/alpha", "feat/alpha")
write(MD .. "/ua.json", json.encode({ v = 1, key = "ua", session_id = "ua", pid = "5001", nonce = "m-ua",
  worktree = "/r/A/.claude/worktrees/alpha", branch = "feat/alpha", base = "main", commonDir = "/r/A/.git",
  summary = "alpha", tests = "green", ahead = 1, at = os.time(), phase = "requested" }))
-- and an intruder asks to merge unit beta's branch
status("zz", "/r/A/.claude/worktrees/beta", "6001")
facts("/r/A/.claude/worktrees/beta", "fix/beta")
write(MD .. "/zz.json", json.encode({ v = 1, key = "zz", session_id = "zz", pid = "6001", nonce = "m-zz",
  worktree = "/r/A/.claude/worktrees/beta", branch = "fix/beta", base = "main", commonDir = "/r/A/.git",
  summary = "beta", tests = "green", ahead = 1, at = os.time(), phase = "requested" }))
tick(); tick()
local md = decoded(MD .. "/ua.decision")
check("a delegated unit's ready merge is approved on the batch's grant", md and md.verdict == "merge" and md.nonce == "m-ua")
check("...and says so", alerted("on your batch grant") >= 1)
check("a session that isn't the unit's never merges on the grant (it waits for Adam)", read(MD .. "/zz.decision") == nil)

-- closing unit alpha's tab: it reads "Claude Code" like the others, but its bridge tagged it
write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.3.0", folders = { "/r/A" }, at = os.time(),
  tabs = { { label = "Claude Code", unit = "b1:alpha" }, { label = "Claude Code" }, { label = "Claude Code" } } }))
local ua = items().ua
local sentClose = ua and select(2, quiet(function() return fx.closeTab(ua, { quiet = true }) end))
local cl
for _, c in ipairs(inboxCmds()) do if c.op == "close" then cl = c end end
check("a unit's nameless tab is closed by its tag, not by a name  (unit=" .. tostring(cl and cl.unit) .. ")",
      sentClose == true and cl and cl.unit == "b1:alpha" and cl.label == nil)
os.execute('rm -f "' .. BR .. '/701.in/"*')

-- 2026-09-11 live: no tab carried the unit's tag (it was a restored tab, named "/clear" after its
-- first command), and Shepherd gave up without trying the name -- a red card with nothing to press.
write(T .. "/ua.jsonl", '{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}\n'
  .. '{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}\n')
status("ua", "/r/A/.claude/worktrees/alpha", "5001", { transcript_path = T .. "/ua.jsonl" })
write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.3.0", folders = { "/r/A" }, at = os.time(),
  tabs = { { label = "/clear" }, { label = "Claude Code" }, { label = "Claude Code" } } }))
tick()
ua = items().ua
local sentByName = ua and select(2, quiet(function() return fx.closeTab(ua, { quiet = true }) end))
cl = nil
for _, c in ipairs(inboxCmds()) do if c.op == "close" then cl = c end end
check("no tab tagged for the unit: Close falls back to the tab's name, when it's the only one  (label=" .. tostring(cl and cl.label) .. ")",
      sentByName == true and cl and cl.label == "/clear" and cl.unit == nil)
os.execute('rm -f "' .. BR .. '/701.in/"*')

-- 2026-09-11 live: the unit's tab never opened ("window wasn't in front"), yet a new session in the
-- repo was recorded as the unit's. A tab that didn't open answers the driver with why.
write(FD .. "/b1.tab-beta.json", json.encode({ v = 1, batch = "b1", slug = "beta", session_id = "drv", nonce = "t-beta0", at = os.time() }))
tick()
local ob = opened[#opened]
check("unit beta's tab is being opened", ob and ob.label and tostring(ob.label):find("beta", 1, true) ~= nil)
write(SD .. "/5002.json", json.encode({ pid = 5002, sessionId = "stray", name = "A-stray", cwd = "/r/A" }))
quiet(function() ob.onDone(false, "its window wasn't in front") end)
quiet(function() fx.fleetTabPoll("b1", "beta") end)
local ab0 = decoded(FD .. "/b1.tab-beta.answer")
check("a unit tab that didn't open is refused, with the reason  (" .. tostring(ab0 and ab0.reason) .. ")",
      ab0 and ab0.ok == false and ab0.nonce == "t-beta0" and tostring(ab0.reason):find("wasn't in front", 1, true) ~= nil)
check("...and no session is recorded for it", not ((fx._fleetState.b1.units or {}).beta or {}).session)
os.remove(FD .. "/b1.tab-beta.answer")

-- 2026-09-11 live: a batch whose units had all merged kept "⇉ driving 2 units" on the driver's card
-- for hours, because the driver never ran stop. A finished batch ends itself.
write(FD .. "/b2.json", json.encode({ v = 1, id = "b2", nonce = "n-b2", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
  repo = "/r/A", commonDir = "/r/A/.git", title = "One helper", mergeWhenGreen = false, at = now - 7200, phase = "approved",
  units = { { type = "feat", slug = "gamma", task = "Add gamma.", branch = "feat/gamma" } } }))
write(FD .. "/b2.state.json", json.encode({ grant = { approved = true, grantMerge = false, at = now - 7200 },
  units = { gamma = { session = { id = "ug", name = "A-g", pid = "5003" } } } }))
status("ug", "/r/A", "5003")
write(MD .. "/ug.json", json.encode({ v = 1, key = "ug", session_id = "ug", pid = "5003", nonce = "m-ug",
  worktree = "/r/A/.claude/worktrees/gamma", branch = "feat/gamma", base = "main", commonDir = "/r/A/.git",
  summary = "gamma", tests = "green", ahead = 0, at = now, phase = "merged", sha = "abc1234" }))
fx._fleetState.b2 = nil
tick(); tick()
local s2 = decoded(FD .. "/b2.state.json")
check("a unit's merge is recorded as its outcome", s2 and s2.units and s2.units.gamma and s2.units.gamma.result == "merged")
check("...and with every unit done, the batch ends itself  (" .. tostring(s2 and s2.grant and s2.grant.finished) .. ")",
      s2 and s2.grant and s2.grant.stopped == true and s2.grant.finished == "1 merged")
check("...and says so once", alerted("One helper") == 1)
tick()
I = items()
check("a finished batch's panel leaves the driver's card", not (I.drv.fleet and I.drv.fleet.id == "b2"))
write(FD .. "/b3.json", json.encode({ v = 1, id = "b3", nonce = "n-b3", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
  repo = "/r/gone", commonDir = "/r/gone/.git", title = "Gone repo", mergeWhenGreen = false, at = now - 7200, phase = "approved",
  units = { { type = "feat", slug = "delta", task = "Add delta.", branch = "feat/delta" } } }))
write(FD .. "/b3.state.json", json.encode({ grant = { approved = true, at = now - 7200 }, units = {} }))
tick()
local s3 = decoded(FD .. "/b3.state.json")
check("a batch whose repo is gone ends itself", s3 and s3.grant and s3.grant.stopped == true and s3.grant.finished == "its repo is gone")
alerts = {}

-- ---- a unit's tab and an out-of-date tab bridge (2026-09-17) ----
-- 2026-09-15 live: ChargebackSentinel's window still ran tab bridge 0.1.0, which has no "expect";
-- it refused every unit's expect ("unknown op"), nobody read the answer, and no unit's tab ever
-- closed after its merge -- found only at merge time as "no tab in its window is tagged".
do
  local before = #opened
  write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.1.0", folders = { "/r/A" }, tabs = {}, at = os.time() }))
  write(FD .. "/b1.tab-beta.json", json.encode({ v = 1, batch = "b1", slug = "beta", session_id = "drv", nonce = "t-beta-old", at = os.time() }))
  tick()
  local old = decoded(FD .. "/b1.tab-beta.answer")
  check("a unit's tab is refused up front when its window's tab bridge can't tag it  (" .. tostring(old and old.reason) .. ")",
        old and old.ok == false and old.nonce == "t-beta-old" and tostring(old.reason):find("Reload Window", 1, true) ~= nil)
  check("...and no tab is opened for it", #opened == before)
  os.remove(FD .. "/b1.tab-beta.answer"); os.remove(FD .. "/b1.tab-beta.json")
  fx._fleetTabs["b1|beta"] = nil

  write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.4.0", folders = { "/r/A" }, tabs = {}, at = os.time() }))
  write(FD .. "/b1.tab-beta.json", json.encode({ v = 1, batch = "b1", slug = "beta", session_id = "drv", nonce = "t-beta-new", at = os.time() }))
  tick()
  check("a window whose bridge can tag the unit's tab gets it opened", #opened == before + 1)
  alerts = {}
  quiet(function() opened[#opened].beforeOpen() end)
  local exp2
  for _, c in ipairs(inboxCmds()) do if c.op == "expect" and c.unit == "b1:beta" then exp2 = c end end
  check("...after telling its bridge to expect it", exp2 ~= nil)
  if exp2 then
    os.remove(BR .. "/701.in/" .. exp2.id .. ".json")
    write(BR .. "/701.out/" .. exp2.id .. ".json", json.encode({ v = 1, id = exp2.id, ok = false, reason = "unknown op" }))
  end
  quiet(function() fx.tabBridgePollResults() end)
  check("a refused expect warns that the unit's tab won't close after its merge",
        alerted("beta") >= 1 and alerted("unknown op") >= 1)
  check("...and the answer is collected", exp2 and read(BR .. "/701.out/" .. exp2.id .. ".json") == nil)
  os.remove(FD .. "/b1.tab-beta.answer"); os.remove(FD .. "/b1.tab-beta.json")
  fx._fleetTabs["b1|beta"] = nil
  alerts = {}
end

-- Stop
quiet(function() fx.batchStop("drv", "b1") end)
st = decoded(FD .. "/b1.state.json")
check("Stop records the batch as stopped", st and st.grant and st.grant.stopped == true)
write(FD .. "/b1.tab-beta.json", json.encode({ v = 1, batch = "b1", slug = "beta", session_id = "drv", nonce = "t-beta", at = os.time() }))
tick()
local ab = decoded(FD .. "/b1.tab-beta.answer")
check("a tab request after Stop is refused, with the reason", ab and ab.ok == false and tostring(ab.reason):find("stopped", 1, true) ~= nil)
tick()
I = items()
check("the driver's card says the batch stopped", I.drv.fleet and I.drv.fleet.line:find("stopped", 1, true) ~= nil)
-- 2026-09-18 batch outcomes: the review gets its units grouped by outcome, from Shepherd's own state
local bsum = I.drv.fleet and type(I.drv.fleet.summary) == "table" and table.concat(I.drv.fleet.summary, " / ") or ""
check("the driver's review groups the batch's units by outcome  (" .. bsum .. ")",
      bsum:find("alpha", 1, true) ~= nil and bsum:find("beta", 1, true) ~= nil
      and type(I.drv.fleet.outcomes) == "table" and I.drv.fleet.units[1].outcome ~= nil)
check("no keystroke anywhere", taps == 0)
finish()
