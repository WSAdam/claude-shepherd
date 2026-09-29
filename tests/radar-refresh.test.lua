-- radar-refresh.test.lua : the overlap radar's wiring under a STUBBED Hammerspoon (2026-09-29,
-- build program unit 24). FX.refreshRadar runs core.RADAR_SH per repo in an hs.task with stdout
-- redirected to a scratch file, on the FX.refreshCommits pattern -- its own timer, never the tick.
-- This drives the real functions: one scan per repo a tile is in, no second while one runs, the
-- cache holding within radar.refreshSeconds, a hung scan reclaimed without its late exit
-- clobbering the new one, a failed scan keeping the last good one, the tile stamps
-- (FX.annotateRadar) on worktree tiles only, a repo with no tile dropped, radar.enabled=false,
-- and a tick that starts nothing.
-- Side-effect-free: a temp HOME holds the config and the scratch dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end

local HOME
do
  local p = io.popen("mktemp -d 2>/dev/null"); HOME = p and p:read("*l"); if p then p:close() end
  assert(HOME and HOME ~= "", "could not mktemp a HOME")
  os.execute("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/status'")
end
local CONFIG = HOME .. "/.claude/cc-config.json"
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local tasks = {}   -- every hs.task.new: { path, cb, args, started, terminated }
local json = dofile(HERE .. "support/json.lua")
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function() return function() return nil end end,
    attributes = function(p) if exists(tostring(p)) then return { mode = "file" } end return nil end,
    symlinkAttributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = {
    new = function(path, cb, args)
      local t = { path = path, cb = cb, args = args }
      function t:start() self.started = true; return self end
      function t:terminate() self.terminated = true end
      function t:setWorkingDirectory() end
      tasks[#tasks + 1] = t
      return t
    end,
  },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
check("the dashboard loads under the stub", ok)
if not ok then print("       " .. tostring(err)); print(string.format("-- radar-refresh.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core

local function radarTasks()
  local out = {}
  for _, t in ipairs(tasks) do
    if t.args and type(t.args[2]) == "string" and t.args[2]:find("cc-radar", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function outFileOf(t) return t.args[2]:match("> '([^']+)' 2>/dev/null$") end
local function finish(t, code, output)
  local out = outFileOf(t)
  if output then writeFile(out, output) end
  t.cb(code, "", "")
  return out
end
local function forRoot(root)
  for _, t in ipairs(radarTasks()) do if t.args[2]:find("'cc-radar' '" .. root .. "'", 1, true) then return t end end
  return nil
end

local LIST = {
  { key = "m", repoKey = "/r/main/.git", mainRoot = "/r/main", wtRoot = "/r/main", isMainWt = true },
  { key = "a", repoKey = "/r/main/.git", mainRoot = "/r/main", wtRoot = "/r/main/.claude/worktrees/a", isMainWt = false },
  { key = "b", repoKey = "/r/main/.git", mainRoot = "/r/main", wtRoot = "/r/main/.claude/worktrees/b", isMainWt = false },
  { key = "o", repoKey = "/r/other/.git", mainRoot = "/r/other", wtRoot = "/r/other", isMainWt = true },
  { key = "x", remote = { host = "box" }, repoKey = "/r/far/.git", mainRoot = "/r/far", wtRoot = "/r/far/w" },
}
local SCAN = table.concat({
  "@@base\tmain\t1111111111111111111111111111111111111111",
  "@@wt\t/r/main/.claude/worktrees/a\tfeat/a\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "@@committed", "app.lua", "@@dirty", "@@untracked",
  "@@wt\t/r/main/.claude/worktrees/b\tfeat/b\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "@@committed", "app.lua", "other.lua", "@@dirty", "@@untracked",
  "@@pair\t/r/main/.claude/worktrees/a\t/r/main/.claude/worktrees/b",
  "cb1d25b3182699adc66e7ac1ecfdc3ebe8a44cce", "app.lua", "@@rc\t1", "" }, "\n")

-- 0. the panel's tick never scans
local before = #radarTasks()
pcall(function() FX._refreshBody() end)
check("the tick starts no radar scan", #radarTasks() == before)

writeFile(CONFIG, json.encode({ radar = { refreshSeconds = 120 } }))

-- 1. one scan per local repo a tile is in, through /bin/sh, into a scratch file
FX.refreshRadar(LIST)
local tm, to = forRoot("/r/main"), forRoot("/r/other")
check("one scan per local repo (never a remote tile's)", #radarTasks() == 2 and tm ~= nil and to ~= nil)
check("...through /bin/sh with its stdout in a scratch file",
      tm and tm.path == "/bin/sh" and tm.args[1] == "-c" and (outFileOf(tm) or ""):find("/.claude/cc-scratch/radar-", 1, true) ~= nil)
check("...running the radar's own program", tm and tm.args[2]:find("merge-tree --write-tree --name-only", 1, true) ~= nil)
check("nothing is stamped before a scan lands", (function() FX.annotateRadar(LIST); return LIST[2].overlap == nil end)())

-- 2. while one runs, no second scan of that repo
FX.refreshRadar(LIST)
FX.refreshRadar(LIST, true)
check("no second scan of a repo while one runs", #radarTasks() == 2)

-- 3. it lands: parsed, cached, stamped on the worktree tiles only
local out1 = finish(tm, 0, SCAN)
FX.annotateRadar(LIST)
check("a landed scan reaches the worktree tiles  (" .. tostring(LIST[2].overlap and LIST[2].overlap.line) .. ")",
      LIST[2].overlap ~= nil and LIST[2].overlap.line == "⚠ overlaps feat/b: 1 shared file, 1 conflict · merge feat/a first")
check("...both of them", LIST[3].overlap ~= nil and LIST[3].overlap.line:find("overlaps feat/a", 1, true) ~= nil)
check("...never the main checkout's tile", LIST[1].overlap == nil)
check("the scratch file is removed", not exists(out1))
local rv = FX.radarViewFor("/r/main/.git")
check("the repo's view carries the merge order", rv and rv.orderLine == "merge order: feat/a → feat/b")
-- the tick reads it every second, for every repo: built once per scan, not once per tick
check("the view is built once per scan, not on every read", FX.radarViewFor("/r/main/.git") == rv)
FX._mergeReqs = { k = { commonDir = "/r/main/.git", phase = "requested", worktree = "/r/main/.claude/worktrees/b" } }
local rv2 = FX.radarViewFor("/r/main/.git")
check("...but again when a worktree asks to merge (it goes first)", rv2 ~= rv and rv2.orderLine == "merge order: feat/b → feat/a")
FX._mergeReqs = {}
check("...and back when the request is gone", FX.radarViewFor("/r/main/.git").orderLine == "merge order: feat/a → feat/b")
check("a request's review gets its worktree's overlap",
      (function() local r = FX.radarReviewFor({ commonDir = "/r/main/.git", worktree = "/r/main/.claude/worktrees/b" })
        return r and r.order == "merge order: feat/a → feat/b" and #r.lines == 1 end)())
finish(to, 0, "@@base\tmain\t2222222222222222222222222222222222222222\n")

-- 4. the cache holds for radar.refreshSeconds; a forced scan runs at once
FX.refreshRadar(LIST)
check("a fresh scan isn't repeated", #radarTasks() == 2)
FX._radar["/r/main/.git"].cache.ts = os.time() - 300
FX.refreshRadar(LIST)
check("a scan older than radar.refreshSeconds is repeated", #radarTasks() == 3)
local t3 = radarTasks()[3]

-- 5. a hung scan is reclaimed, and its late exit can't clobber the new one
FX._radar["/r/main/.git"].inflight.ts = os.time() - 100
FX.refreshRadar(LIST)
check("a scan hung past 60s is terminated and restarted", t3.terminated == true and #radarTasks() == 4)
local t4 = radarTasks()[4]
local out3 = finish(t3, 0, "@@base\tmain\t3333333333333333333333333333333333333333\n")
FX.annotateRadar(LIST)
check("the reclaimed scan's late exit is dropped", LIST[2].overlap ~= nil)
check("...and its scratch file removed", not exists(out3))
check("...while the new scan still owns the slot", FX._radar["/r/main/.git"].inflight and FX._radar["/r/main/.git"].inflight.task == t4)

-- 6. a failed scan keeps the last good view
finish(t4, 3, "")
FX.annotateRadar(LIST)
check("a failed scan keeps the last good view", LIST[2].overlap ~= nil)

-- 7. the worktrees stop overlapping: the stamp goes
FX._radar["/r/main/.git"].cache.ts = 0
FX.refreshRadar(LIST)
local t5 = radarTasks()[#radarTasks()]
finish(t5, 0, table.concat({
  "@@base\tmain\t1111111111111111111111111111111111111111",
  "@@wt\t/r/main/.claude/worktrees/a\tfeat/a\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "@@committed", "app.lua", "@@dirty", "@@untracked",
  "@@wt\t/r/main/.claude/worktrees/b\tfeat/b\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "@@committed", "other.lua", "@@dirty", "@@untracked",
  "@@pair\t/r/main/.claude/worktrees/a\t/r/main/.claude/worktrees/b",
  "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "@@rc\t0", "" }, "\n"))
FX.annotateRadar(LIST)
check("worktrees that no longer overlap lose the stamp", LIST[2].overlap == nil and LIST[3].overlap == nil)

-- 8. a repo with no tile any more is dropped
FX.refreshRadar({ LIST[4] })
check("a repo with no tile any more drops its radar", FX._radar["/r/main/.git"] == nil and FX._radar["/r/other/.git"] ~= nil)

-- 9. radar.enabled = false: nothing runs, nothing is stamped
writeFile(CONFIG, json.encode({ radar = { enabled = false } }))
local n = #radarTasks()
FX.refreshRadar(LIST, true)
FX.annotateRadar(LIST)
check("disabled: no scan runs", #radarTasks() == n)
check("disabled: no tile is stamped", LIST[2].overlap == nil)
check("the radar function is live on FX and core", type(FX.refreshRadar) == "function" and type(core.radarView) == "function")

print(string.format("-- radar-refresh.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
