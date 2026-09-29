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

-- ---- the batch relay: each unit's events, once each, for cc-fleet.sh wait (2026-09-29) ----
-- Build program unit 23. The driver learned what a unit did by stitching idle notices, unit
-- messages and status polls together. The tick now turns each unit's live state into events
-- (core.unitEvent) and appends them, numbered, to <id>.events.jsonl -- which `wait` relays.
do
  local function events(id)
    local out, raw = {}, read(FD .. "/" .. id .. ".events.jsonl") or ""
    for line in raw:gmatch("[^\n]+") do
      local okd, e = pcall(json.decode, line)
      if okd and type(e) == "table" then out[#out + 1] = e end
    end
    return out
  end
  local function said(list)
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = tostring(e.seq) .. ":" .. tostring(e.unit) .. ":" .. tostring(e.event) end
    return table.concat(t, " ")
  end
  write(FD .. "/b4.json", json.encode({ v = 1, id = "b4", nonce = "n-b4", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
    repo = "/r/A", commonDir = "/r/A/.git", title = "Relay", mergeWhenGreen = false, at = now, phase = "approved",
    units = { { type = "feat", slug = "eps", task = "Add eps.", branch = "feat/eps" },
              { type = "fix", slug = "zeta", task = "Fix zeta.", branch = "fix/zeta" } } }))
  write(FD .. "/b4.state.json", json.encode({ grant = { approved = true, grantMerge = false, at = now },
    units = { eps = { session = { id = "ue", name = "A-e", pid = "5010" } },
              zeta = { session = { id = "uz-old", name = "A-z", pid = "5011" } } } }))
  status("ue", "/r/A/.claude/worktrees/eps", "5010", { status = "working", since = now - 30 })
  -- zeta ran /clear: a new session id in the same process, and its turn has ended
  status("uz-new", "/r/A/.claude/worktrees/zeta", "5011", { status = "done", since = now - 20 })
  fx._fleetState.b4 = nil
  tick()
  local e1 = events("b4")
  check("the tick relays each unit's events, numbered  (" .. said(e1) .. ")",
        said(e1) == "1:eps:tab_opened 2:zeta:tab_opened 3:zeta:turn_finished")
  check("...a unit whose session changed id links by its process (session_pid)", e1[3] and e1[3].session == "A-z")
  check("...every line says its batch and a line of text", e1[1] and e1[1].batch == "b4" and type(e1[1].text) == "string" and e1[1].text ~= "")
  tick()
  check("a steady state relays nothing more", #events("b4") == 3)
  status("ue", "/r/A/.claude/worktrees/eps", "5010", { status = "done", since = now - 5 })
  tick(); tick()
  check("eps's turn ends: one event, the next number  (" .. said(events("b4")) .. ")",
        said(events("b4")) == "1:eps:tab_opened 2:zeta:tab_opened 3:zeta:turn_finished 4:eps:turn_finished")
  -- a reload forgets everything in memory; the file is the memory
  fx._fleetRelay = {}
  tick()
  check("after a reload nothing is told twice", #events("b4") == 4)
  -- eps's session ends: no tile, and its process is gone
  os.remove(T .. "/status/ue.json")
  local realProbe = fx.probeAlive
  fx.probeAlive = function(pids) local o = {} for p in pairs(pids or {}) do o[p] = (p ~= "5010") end return o end
  tick()
  fx.probeAlive = realProbe
  local e5 = events("b4")
  check("a unit whose session is gone -> session_ended  (" .. said(e5) .. ")", e5[5] and e5[5].unit == "eps" and e5[5].event == "session_ended" and e5[5].seq == 5)
  tick()
  check("...once", #events("b4") == 5)
  -- a running batch is never pruned; one stopped over a week ago goes, its events with it
  write(FD .. "/b5.json", json.encode({ v = 1, id = "b5", nonce = "n-b5", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
    repo = "/r/A", commonDir = "/r/A/.git", title = "Old", mergeWhenGreen = false, at = now - 30 * 86400, phase = "stopped",
    units = { { type = "feat", slug = "eta", task = "t", branch = "feat/eta" } } }))
  write(FD .. "/b5.state.json", json.encode({ grant = { approved = true, stopped = true, stoppedAt = now - 8 * 86400, at = now - 30 * 86400 }, units = {} }))
  write(FD .. "/b5.events.jsonl", '{"v":1,"seq":1,"unit":"eta","event":"merged","key":"result:merged"}\n')
  write(FD .. "/b5.stop", "")
  fx._fleetState.b5 = nil
  tick()
  check("a batch stopped over a week ago is pruned, its events file too",
        read(FD .. "/b5.json") == nil and read(FD .. "/b5.state.json") == nil and read(FD .. "/b5.events.jsonl") == nil and read(FD .. "/b5.stop") == nil)
  check("...while a batch stopped just now keeps its files", read(FD .. "/b1.json") ~= nil and read(FD .. "/b1.state.json") ~= nil)
  check("...and a running one keeps its events", #events("b4") == 5)
  local s1 = decoded(FD .. "/b1.state.json")
  check("Stop records when the batch stopped (the prune's clock)", s1 and s1.grant and tonumber(s1.grant.stoppedAt) ~= nil)
end

-- ---- blockedBy: a unit waits for its blockers, at its tab and at its merge (2026-09-29) ----
-- Build program unit 24: unit "two" names "one" in blockedBy. Its tab isn't opened -- the driver
-- is told it waits (cc-fleet.sh exits 7) -- and a merge request on its branch isn't ready, so
-- the batch's grant never merges it ahead of "one".
do
  -- the repo's earlier requests are done with: one merge per repo, so they'd queue unit two behind them
  for _, f in ipairs({ "ua.json", "ua.decision", "zz.json", "zz.decision" }) do os.remove(MD .. "/" .. f) end
  fx._mergeSent, fx._mergeApproved = {}, {}
  write(BR .. "/701.json", json.encode({ v = 1, pid = 701, version = "0.4.0", folders = { "/r/A" }, tabs = {}, at = os.time() }))
  write(FD .. "/b7.json", json.encode({ v = 1, id = "b7", nonce = "n-b7", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
    repo = "/r/A", commonDir = "/r/A/.git", title = "In order", mergeWhenGreen = true, at = os.time(), phase = "approved",
    units = { { type = "feat", slug = "one", task = "First.", branch = "feat/one" },
              { type = "feat", slug = "two", task = "Second.", branch = "feat/two", blockedBy = { "one" } } } }))
  write(FD .. "/b7.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = os.time() },
    units = { one = { session = { id = "u1", name = "A-1", pid = "5101" } } } }))
  fx._fleetState.b7 = nil
  local before = #opened
  write(FD .. "/b7.tab-two.json", json.encode({ v = 1, batch = "b7", slug = "two", session_id = "drv", nonce = "t-two", at = os.time() }))
  tick()
  local aw = decoded(FD .. "/b7.tab-two.answer")
  check("a unit whose blocker hasn't merged: its tab isn't opened  (" .. tostring(aw and aw.reason) .. ")",
        aw and aw.ok == false and aw.nonce == "t-two" and aw.reason == "waits for one to merge first" and #opened == before)
  check("...and the answer says what it waits for, so cc-fleet.sh can say 'waits'",
        aw and type(aw.waits) == "table" and aw.waits[1] == "one")
  os.remove(FD .. "/b7.tab-two.answer"); os.remove(FD .. "/b7.tab-two.json")

  -- unit two's session exists anyway (the driver opened it by hand) and asks to merge first
  write(FD .. "/b7.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = os.time() },
    units = { one = { session = { id = "u1", name = "A-1", pid = "5101" } }, two = { session = { id = "u2", name = "A-2", pid = "5102" } } } }))
  fx._fleetState.b7 = nil
  status("u2", "/r/A/.claude/worktrees/two", "5102")
  facts("/r/A/.claude/worktrees/two", "feat/two")
  write(MD .. "/u2.json", json.encode({ v = 1, key = "u2", session_id = "u2", pid = "5102", nonce = "m-u2",
    worktree = "/r/A/.claude/worktrees/two", branch = "feat/two", base = "main", commonDir = "/r/A/.git",
    summary = "two", tests = "green", ahead = 1, at = os.time(), phase = "requested" }))
  tick(); tick()
  check("its merge is not approved on the batch's grant while its blocker hasn't merged", read(MD .. "/u2.decision") == nil)
  local u2 = items().u2
  check("...and its card says why  (" .. tostring(u2 and u2.merge and u2.merge.line) .. ")",
        u2 and u2.merge and tostring(u2.merge.line):find("waits for one", 1, true) ~= nil)
  local okA = select(2, quiet(function() return fx.mergeApprove("u2") end))
  check("...nor on Adam's click", okA == false and read(MD .. "/u2.decision") == nil)

  -- unit one merges: two is free
  write(FD .. "/b7.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = os.time() },
    units = { one = { session = { id = "u1", name = "A-1", pid = "5101" }, result = "merged" },
              two = { session = { id = "u2", name = "A-2", pid = "5102" } } } }))
  fx._fleetState.b7 = nil
  tick(); tick()
  local dm = decoded(MD .. "/u2.decision")
  check("once its blocker has merged, it merges on the grant", dm and dm.verdict == "merge" and dm.nonce == "m-u2")
  os.remove(MD .. "/u2.json"); os.remove(MD .. "/u2.decision")
  quiet(function() fx.batchStop("drv", "b7") end)
end

-- ---- coverage index: Approve re-checks coverage from the file on disk (2026-09-29) ----
-- Build program unit 25: a batch built from an issue list can't be approved until every issue is
-- covered by a unit or triaged. The review disables Approve, but the click's handler must not
-- trust what was rendered: it reads the proposal from disk again, so a file rewritten after the
-- panel drew it (or a stale view) can't slip an uncovered issue past Adam.
do
  local core = rawget(_G, "__ccDashboard").core
  local function b8(triage)
    return json.encode({ v = 1, id = "b8", nonce = "n-b8", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
      repo = "/r/A", commonDir = "/r/A/.git", title = "Issue sweep", mergeWhenGreen = true, at = os.time(), phase = "proposed",
      issues = { { id = "BUG-1", title = "Paste drops the last line" }, { id = "BUG-2", title = "Toast covers Approve" } },
      triage = triage,
      units = { { type = "fix", slug = "paste", task = "Fix paste.", branch = "fix/paste", covers = { "BUG-1" } } } })
  end
  -- the panel's copy says every issue is accounted for; the file on disk no longer does
  fx._fleetBatches = fx._fleetBatches or {}
  fx._fleetBatches.b8 = core.parseBatch(b8({ { id = "BUG-2", as = "later", note = "after the release" } }))
  write(FD .. "/b8.json", b8(nil))
  fx._fleetState.b8 = nil
  local before = #alerts
  local okA = select(2, quiet(function() return fx.batchApprove("drv", '{"id":"b8","grantMerge":true}') end))
  check("Approve on a batch with an uncovered issue is refused", okA == false)
  check("...no decision is written for cc-fleet.sh to claim", read(FD .. "/b8.decision") == nil)
  local s8 = decoded(FD .. "/b8.state.json")
  check("...and Shepherd records no grant", not (s8 and s8.grant) and not (fx._fleetState.b8 and fx._fleetState.b8.grant))
  local said = table.concat(alerts, "\n", before + 1)
  check("...and says which issue holds it  (" .. said .. ")", said:find("BUG-2", 1, true) ~= nil and said:find("uncovered", 1, true) ~= nil)

  -- the driver triages BUG-2: the same click now goes through
  write(FD .. "/b8.json", b8({ { id = "BUG-2", as = "later", note = "after the release" } }))
  okA = select(2, quiet(function() return fx.batchApprove("drv", '{"id":"b8","grantMerge":true}') end))
  local d8 = decoded(FD .. "/b8.decision")
  check("once every issue is covered or triaged, Approve writes its decision", okA == true and d8 and d8.verdict == "approve" and d8.nonce == "n-b8")
  os.remove(FD .. "/b8.decision")

  -- Deny never waits for coverage: Adam can always say no
  write(FD .. "/b9.json", (b8(nil):gsub('"b8"', '"b9"'):gsub('"n%-b8"', '"n-b9"')))
  fx._fleetState.b9 = nil
  local okD = select(2, quiet(function() return fx.batchDeny("drv", '{"id":"b9","note":"not this one"}') end))
  local d9 = decoded(FD .. "/b9.decision")
  check("Deny on an uncovered batch still goes through", okD == true and d9 and d9.verdict == "deny")
  quiet(function() fx.batchStop("drv", "b8"); fx.batchStop("drv", "b9") end)
end
check("no keystroke anywhere", taps == 0)
finish()
