-- worklist-runner.test.lua : BEHAVIORAL fixture for Run selected, the checklist runner in My List.
--
-- 2026-10-03 (mining round 2, unit D3b): Adam selects open items on a project's My List tab and
-- clicks Run selected. Each item runs, one at a time, in a fresh tab in the repo's main checkout,
-- opened through the expect-tag machinery with its brief typed in (never a keystroke). A TODO.md
-- line is finished when its box is ticked in the file and the turn did something; Adam's own item
-- when ITS session reports done through cc-run.sh. Then the item gets Adam's checkmark, marked
-- doneBy = "run:<id>", and its tab closes by the run's tag. One run per repo, none during a batch;
-- a freeze holds it; a live-run item pauses it (Resume skips it); Stop ends it.
--
-- Loads the real claude-dashboard.lua under the stubbed hs (the worklist-playbooks.test.lua harness),
-- posts real bridge messages through the captured controller callback, and drives FX.runTick with
-- handmade cards. FX.openClaudeTab / FX.readSessions / FX.closeTab are recorded, so nothing opens.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish()
  print("-- worklist-runner.test.lua: " .. run .. " run, " .. failed .. " failed --")
  os.exit(failed == 0 and 0 or 1)
end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/proj" "' .. T .. '/cc-run" "' .. T .. '/cc-hold" "' .. T .. '/.claude"')
local PROJ = T .. "/proj"                 -- no transcript_path, so projectKey == cwd
local RUNDIR = T .. "/cc-run"
local now0 = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readf(path) local h = io.open(path, "r"); if not h then return nil end
  local s = h:read("*a"); h:close(); return s end

write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"proj","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
  PROJ, now0, now0))
write(PROJ .. "/TODO.md", "- [ ] fix the parser\n- [x] ticked already\n")
local WL = T .. "/worklist.json"
write(WL, json.encode({ generic = {}, byProject = { [PROJ] = {
  { id = "t1", text = "fix the parser", src = "todo", srcText = "fix the parser", done = false, ts = now0 },
  { id = "t3", text = "ticked already", src = "todo", srcText = "ticked already", fileDone = true, done = false, ts = now0 },
  { id = "o1", text = "renew the cert", done = false, ts = now0 },
  { id = "l1", text = "look at the panel (needs live run)", done = false, ts = now0 },
} }, todoMeta = {} }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = WL, CC_RUN_DIR = RUNDIR, CC_HOLD_DIR = T .. "/cc-hold", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end; return realGetenv(k) end

-- ---- stubbed hs (the worklist-playbooks.test.lua harness) -------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, CALLBACK = {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1a "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      local h = io.open(path, "r")
      if not h then return nil, "cannot obtain information from file '" .. tostring(path) .. "'" end
      local sz = #(h:read("*a") or ""); h:close()
      if attr == "modification" then return now0 - 100 end
      if attr == "size" then return sz end
      if attr == "mode" then return "file" end
      return { mode = "file", modification = now0 - 100, size = sz }
    end,
    mkdir = function(p) os.execute('mkdir -p "' .. p .. '"'); return true end,
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
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) CALLBACK = fn end },
      { __index = function() return function() return mkstub() end end })
  end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
-- Any keystroke would be a failure: a run's tab is opened by its link and never typed into.
local KEYS = 0
hs.eventtap = setmetatable({ keyStroke = function() KEYS = KEYS + 1 end, keyStrokes = function() KEYS = KEYS + 1 end },
  { __index = function() return mkstub() end })
for _, ns in ipairs({ "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "http", "task", "base", "console", "dialog" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads" .. (ok and "" or ("  (" .. tostring(err) .. ")")), ok)
if not ok then finish() end
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
check("the controller callback was captured, so the test can post real messages", type(CALLBACK) == "function")
if type(CALLBACK) ~= "function" then finish() end

-- the clock, the new tab's link, Claude Code's session files and the tab bridge's close: recorded
local CLOCK = now0
fx.now = function() return CLOCK end
local opened, SESSIONS, closed = {}, {}, {}
fx.openClaudeTab = function(opts)
  opened[#opened + 1] = opts
  if type(opts.beforeOpen) == "function" then opts.beforeOpen() end
  if type(opts.onDone) == "function" then opts.onDone(true) end
  return true
end
fx.readSessions = function() local o = {}; for k, v in pairs(SESSIONS) do o[k] = v end; return o end
fx.fleetRepoHost = function() return nil end
fx.closeTab = function(it, opts) closed[#closed + 1] = { key = it and it.key, unit = opts and opts.unit }; return true end

local function post(tbl) local okp, errp = quiet(function() CALLBACK({ body = json.encode(tbl) }) end); return okp, errp end
local function store() return json.decode(readf(WL) or "{}") or {} end
local function item(id) for _, it in ipairs((store().byProject or {})[PROJ] or {}) do if it.id == id then return it end end end
local function lastCall(fnName)
  local pat = "^window%." .. fnName .. "%((.*)%)$"
  for i = #jsCalls, 1, -1 do
    local body = jsCalls[i]:match(pat)
    if body then return json.decode(body) end
  end
end
local function projOf(payload)
  for _, p in ipairs((payload or {}).projects or {}) do if p.key == PROJ then return p end end
end
local function runFiles()
  local out, p = {}, io.popen('ls -1 "' .. RUNDIR .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  return out
end
local function runState(id) return json.decode(readf(RUNDIR .. "/" .. id .. ".run.json") or "null") end
local function tick(list) local okt, errt = quiet(function() fx.runTick(list or {}) end)
  if not okt then print("   tick error: " .. tostring(errt)) end end
local function card(sid, status, since, label)
  return { key = "k-" .. sid, session_id = sid, name = "proj", cwd = PROJ, editor = "vscode", status = status,
           since = since, updated = since, last_prompt = "[shepherd] Run", turnLabel = label }
end

-- ---- 1. Run selected: a run of what can run, in the tab's order -------------
jsCalls = {}
post({ a = "worklist-run", v = PROJ, text = json.encode({ "o1", "t3", "t1" }) })
local files = runFiles()
check("Run selected writes the run's own file  (" .. table.concat(files, ",") .. ")", #files == 1 and files[1]:match("^r%x+%.run%.json$") ~= nil)
local RID = (files[1] or ""):match("^(r%x+)%.run%.json$") or "?"
local rs = runState(RID) or { items = {} }
check("...started by Adam", rs.startedBy == "adam")
check("...in the project's folder", rs.root == PROJ)
check("...the items that can run, in the tab's order", #rs.items == 2 and rs.items[1].id == "t1" and rs.items[2].id == "o1")
local res = lastCall("ccRunResult")
check("...and the panel is told how many  (" .. json.encode(res or {}) .. ")", res and res.started == 2 and res.refused == 1)
local p = projOf(lastCall("ccWorklist"))
check("the tab's payload carries the run", p and type(p.run) == "table" and p.run.id == RID and p.run.phase == "running")
check("...and why an open item can't run", p and type(p.runWhy) == "table" and type(p.runWhy.t3) == "string")
check("...never a session id or path in the run view", p and p.run and p.run.root == nil and json.encode(p.run):find(PROJ, 1, true) == nil)

-- one run per repo
jsCalls = {}
post({ a = "worklist-run", v = PROJ, text = json.encode({ "o1" }) })
res = lastCall("ccRunResult")
check("a second run in the same repo is refused, saying why", res and type(res.error) == "string" and #runFiles() == 1)
post({ a = "worklist-run", v = "generic", text = json.encode({ "o1" }) })
check("never on the Generic tab", #runFiles() == 1)

-- ---- 2. Item 1 (a TODO.md line): its tab opens with the brief typed in -------
tick({})
check("the first item's tab is opened  (n=" .. #opened .. ")", #opened == 1)
local o = opened[1] or {}
check("...in the main checkout", o.root == PROJ)
check("...its brief typed in, Shepherd's, naming the run", type(o.prompt) == "string"
      and o.prompt:sub(1, #("[shepherd] Run " .. RID .. " #1")) == "[shepherd] Run " .. RID .. " #1")
check("...do only this item, and tick its box in TODO.md", (o.prompt or ""):find("fix the parser", 1, true) ~= nil
      and (o.prompt or ""):find(PROJ .. "/TODO.md", 1, true) ~= nil)
check("...quiet: the run tells Adam itself", o.quiet == true)
check("...nothing typed into any window", KEYS == 0)
tick({})
check("no session yet: still opening, nothing else opens", #opened == 1 and runState(RID).items[1].state == "opening")
SESSIONS["4242"] = { pid = 4242, sessionId = "S1", cwd = PROJ, name = "proj" }
jsCalls = {}
tick({})
rs = runState(RID)
check("the new session is the item's", rs.items[1].state == "open" and rs.items[1].session.id == "S1")
local toast = false
for _, c in ipairs(jsCalls) do if c:find("press Return", 1, true) then toast = true end end
check("...and Adam is told to press Return in its tab", toast)

-- mid-turn, then a turn that did something but never ticked the box would be nothing; tick it first
CLOCK = CLOCK + 30
tick({ card("S1", "working", CLOCK - 5) })
check("mid-turn: waits", runState(RID).items[1].state == "open")
write(PROJ .. "/TODO.md", "- [x] fix the parser\n- [x] ticked already\n")
tick({ card("S1", "done", CLOCK - 10, "made progress") })
rs = runState(RID)
check("box ticked and the turn did something: the item is done", rs.items[1].state == "done")
local t1 = item("t1") or {}
check("...it gets Adam's checkmark", t1.done == true and t1.doneTs == CLOCK)
check("...marked as checked by the run", t1.doneBy == "run:" .. RID)
check("...and its tab closes by the run's tag", #closed == 1 and closed[1].unit == RID .. ":1" and closed[1].key == "k-S1")

-- ---- 3. Item 2 (Adam's own): only its own session's done report counts ------
tick({})
check("the next item's tab opens", #opened == 2 and (opened[2].prompt or ""):find("cc-run.sh done " .. RID .. " 2", 1, true) ~= nil)
SESSIONS["4343"] = { pid = 4343, sessionId = "S2", cwd = PROJ, name = "proj" }
tick({})
check("...its session recorded", runState(RID).items[2].session.id == "S2")
-- another session's report is dropped; the item's own (from the REAL cc-run.sh) is taken
local ABS
do local p = io.popen('cd "' .. ROOT .. '" && pwd'); ABS = p and p:read("*l"); if p then p:close() end end
local function ccrun(sid, args)   -- the script by its absolute path: it runs from the project folder
  return os.execute('cd "' .. PROJ .. '" && CC_RUN_DIR="' .. RUNDIR .. '" CLAUDE_CODE_SESSION_ID="' .. sid .. '" bash "'
    .. tostring(ABS) .. '/cc-run.sh" ' .. args .. ' >/dev/null 2>&1')
end
local function reportCount()
  local n = 0
  for _, f in ipairs(runFiles()) do if f:match("^r%x+%.%d+%.%d+%-%d+%.json$") then n = n + 1 end end
  return n
end
ccrun("S9", "done " .. RID .. " 2")
check("the real cc-run.sh left a report (from another session)", reportCount() == 1)
CLOCK = CLOCK + 30
tick({ card("S2", "done", CLOCK - 10, "made progress") })
check("another session's done report is dropped", runState(RID).items[2].report == nil and #runFiles() == 1)
check("...and with no report of its own the item finished nothing", runState(RID).items[2].state == "nothing"
      and (item("o1") or {}).done == false)
check("...its tab stays open for Adam to look at", #closed == 1)

-- ---- 4. Every item ran: the run is finished and Adam is told -----------------
jsCalls = {}
tick({})
rs = runState(RID)
check("every item ran: the run is finished", rs.phase == "finished")
p = projOf(lastCall("ccWorklist"))
check("...the panel shows it", p and p.run and p.run.phase == "finished" and p.run.done == 1 and p.run.total == 2)

-- ---- 5. Adam's own item reported done by its own session ---------------------
post({ a = "worklist-run", v = PROJ, text = json.encode({ "o1" }) })
local R2
for _, f in ipairs(runFiles()) do local id = f:match("^(r%x+)%.run%.json$"); if id and id ~= RID then R2 = id end end
check("a new run once the last one ended", R2 ~= nil)
R2 = R2 or "?"
tick({})
SESSIONS["4444"] = { pid = 4444, sessionId = "S3", cwd = PROJ, name = "proj" }
tick({})
ccrun("S3", "done " .. R2 .. " 1 --note renewed")
CLOCK = CLOCK + 30
tick({ card("S3", "working", CLOCK - 2) })
check("its own session's done report is taken (the file is gone)", (runState(R2).items[1].report or {}).verdict == "done"
      and #runFiles() == 2)
tick({ card("S3", "done", CLOCK - 10, "made progress") })
check("...and once its turn ends the item is done and checked off by the run",
      runState(R2).items[1].state == "done" and (item("o1") or {}).doneBy == "run:" .. R2)
tick({})

-- ---- 6. A live-run item pauses; Resume skips it; a freeze holds; Stop ends ----
post({ a = "worklist-run", v = PROJ, text = json.encode({ "l1" }) })
local R3
for _, f in ipairs(runFiles()) do local id = f:match("^(r%x+)%.run%.json$"); if id and id ~= RID and id ~= R2 then R3 = id end end
R3 = R3 or "?"
local before = #opened
tick({})
check("a live-run item pauses the run before its tab opens", runState(R3).phase == "paused" and #opened == before)
post({ a = "worklist-run-resume", v = PROJ })
check("Resume skips it", runState(R3).items[1].state == "skipped" and runState(R3).phase == "running")
tick({})
check("...and with nothing left the run is finished", runState(R3).phase == "finished")

write(WL, json.encode({ generic = {}, byProject = { [PROJ] = {
  { id = "n1", text = "next job", done = false, ts = now0 }, { id = "n2", text = "after that", done = false, ts = now0 } } }, todoMeta = {} }))
post({ a = "worklist-run", v = PROJ, text = json.encode({ "n1", "n2" }) })
local R4
for _, f in ipairs(runFiles()) do
  local id = f:match("^(r%x+)%.run%.json$")
  if id and id ~= RID and id ~= R2 and id ~= R3 then R4 = id end
end
R4 = R4 or "?"
write(T .. "/cc-hold/.fleet", "{}")
quiet(function() fx.readHolds() end)
before = #opened
tick({})
check("a frozen fleet holds the run: no tab opens", #opened == before and runState(R4).items[1].state == "queued")
os.remove(T .. "/cc-hold/.fleet")
quiet(function() fx.readHolds() end)
tick({})
check("thawed: it goes on", #opened == before + 1)
post({ a = "worklist-run-stop", v = PROJ })
check("Stop ends the run", runState(R4).phase == "stopped")
SESSIONS["4545"] = { pid = 4545, sessionId = "S4", cwd = PROJ, name = "proj" }
tick({})
check("...and nothing more opens", #opened == before + 1)

-- ---- 7. Refused while a batch runs in the repo ------------------------------
fx._fleetBatches = { b1x = { id = "b1x", repo = PROJ, units = {} } }
local realState = fx.fleetState
fx.fleetState = function() return { grant = { approved = true }, units = {} } end
jsCalls = {}
post({ a = "worklist-run", v = PROJ, text = json.encode({ "n2" }) })
res = lastCall("ccRunResult")
check("a run is refused while a batch runs in the repo", res and type(res.error) == "string"
      and res.error:find("batch", 1, true) ~= nil)
fx.fleetState = realState
fx._fleetBatches = {}

check("core.mergeClosesTab is untouched: a run's session isn't a batch unit", core.mergeClosesTab(false, "[shepherd] Run r1 #1 of 2") == false)
os.execute('rm -r "' .. T .. '"')
finish()
