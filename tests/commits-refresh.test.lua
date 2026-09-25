-- commits-refresh.test.lua : the commit stats' wiring under a STUBBED Hammerspoon (2026-09-25).
-- FX.refreshCommits runs ~/.claude/cc-commits.sh in an hs.task with stdout redirected to a
-- scratch file, at most every commits.refreshSeconds; FX.pushCommits re-buckets the cached
-- count and hands it to the panel. This drives the real functions through their states: a
-- first count, no second task while one runs, the cache holding within its TTL, Update now
-- forcing a recount, a hung count reclaimed without its late exit clobbering the new one, a
-- failed count keeping the last good one (marked stale), and commits.enabled=false.
-- Side-effect-free: a temp HOME holds the config, the script stand-in and the scratch dir.

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
local SCRIPT = HOME .. "/.claude/cc-commits.sh"
local CONFIG = HOME .. "/.claude/cc-config.json"
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
writeFile(SCRIPT, "#!/bin/sh\n")

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

-- ---- the stubbed Hammerspoon surface (smoke.test.lua's, plus a recording hs.task) ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
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
if not ok then print("       " .. tostring(err)); print(string.format("-- commits-refresh.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx

local function lastCommitsPush()
  for i = #jsCalls, 1, -1 do
    local s = jsCalls[i]:match("^window%.ccCommits%((.*)%)$")
    if s then return json.decode(s) end
  end
  return nil
end
local function outFileOf(t) return t.args[2]:match("> '([^']+)' 2>/dev/null$") end
local NOW = os.time()
local function commitLine(sha, secondsAgo, subject)
  return "\1" .. sha .. "\t" .. (NOW - secondsAgo) .. "\tme@example.invalid\t" .. subject .. "\n\n3\t1\tsrc/a.lua\n"
end
local function finish(t, code, output)
  local out = outFileOf(t)
  if output then writeFile(out, output) end
  t.cb(code, "", "")
  return out
end

writeFile(CONFIG, json.encode({ commits = { authorEmails = { "alias@example.invalid" }, refreshSeconds = 300 } }))

-- 1. a first count starts ONE task, through /bin/sh, into a scratch file
FX.refreshCommits(true)
check("a count starts one task", #tasks == 1 and tasks[1].started == true)
local t1 = tasks[1]
check("...through /bin/sh with its stdout in a scratch file",
      t1.path == "/bin/sh" and t1.args[1] == "-c" and (outFileOf(t1) or ""):find("/.claude/cc-scratch/commits-", 1, true) ~= nil)
check("...running the installed cc-commits.sh with /bin/bash", t1.args[2]:find("'/bin/bash' '" .. SCRIPT .. "'", 1, true) ~= nil)
check("...from last week's Monday on", t1.args[2]:find("'--since' '%d+'") ~= nil)
check("...with the configured alias", t1.args[2]:find("'--email' 'alias@example.invalid'", 1, true) ~= nil)
check("...and a lookback never under 14 days", t1.args[2]:find("'--lookback-days' '14'", 1, true) ~= nil)
check("nothing reaches the panel before a count lands", lastCommitsPush() == nil)

-- 2. while it runs, neither the timer nor Update now piles on a second git run
FX.refreshCommits()
FX.refreshCommits(true)
check("no second task while one is counting", #tasks == 1)

-- 3. it lands: parsed, cached, pushed
local out1 = finish(t1, 0, "@@repo\t/r/alpha\tme@example.invalid\n" .. commitLine("aaa1", 60, "fresh work"))
local push = lastCommitsPush()
check("a landed count reaches the panel", push ~= nil and push.today.commits == 1 and push.week.commits == 1)
check("...with its lines", push ~= nil and push.today.add == 3 and push.today.del == 1)
check("...naming the project and whose commits", push ~= nil and push.repos[1].name == "alpha" and push.emails[1] == "me@example.invalid")
check("...and when it was counted", push ~= nil and type(push.ts) == "number" and push.stale == nil)
check("the scratch file is removed", not exists(out1))

-- 4. the cache holds for commits.refreshSeconds; Update now and an opened drawer override it
FX.refreshCommits()
check("the timer doesn't recount a fresh count", #tasks == 1)
FX.refreshCommits(60)
check("an opened drawer doesn't recount a count under a minute old", #tasks == 1)
FX._commits.cache.ts = NOW - 120
FX.refreshCommits(60)
check("an opened drawer recounts a count over a minute old", #tasks == 2)
local t2 = tasks[2]
finish(t2, 0, "@@repo\t/r/alpha\tme@example.invalid\n" .. commitLine("aaa1", 60, "fresh work") .. commitLine("aaa2", 30, "more"))
FX.refreshCommits(true)
check("Update now recounts at once", #tasks == 3)
local t3 = tasks[3]

-- 5. a hung count is reclaimed, and its late exit can't clobber the new one
FX._commits.inflight.ts = NOW - 100
FX.refreshCommits(true)
check("a count hung past 90s is terminated and restarted", t3.terminated == true and #tasks == 4)
local t4 = tasks[4]
local out3 = finish(t3, 15, "@@repo\t/r/alpha\tme@example.invalid\n")
check("the reclaimed count's late exit is dropped", FX._commits.stale == nil and lastCommitsPush().week.commits == 2)
check("...and its scratch file removed", not exists(out3))
check("...while the new count still owns the slot", FX._commits.inflight ~= nil and FX._commits.inflight.task == t4)

-- 6. a failed count keeps the last good one, marked stale
finish(t4, 1, "")
push = lastCommitsPush()
check("a failed count keeps the last good one", push.week.commits == 2)
check("...and says it's stale", push.stale == true)

-- 7. re-bucketing needs no git: a push re-reads the cache
local before = #tasks
FX.pushCommits()
check("a push re-buckets the cache without running git", #tasks == before and lastCommitsPush().week.commits == 2)

-- 8. commits.enabled = false hides the block and runs nothing
writeFile(CONFIG, json.encode({ commits = { enabled = false } }))
FX._commits.cache.ts = 0
FX.refreshCommits(true)
check("disabled: no count runs", #tasks == before)
FX.pushCommits()
check("disabled: the panel is told to hide the block", lastCommitsPush().enabled == false)

-- 9. not installed yet: nothing runs
writeFile(CONFIG, "{}")
os.remove(SCRIPT)
FX.refreshCommits(true)
check("no cc-commits.sh installed: no count runs", #tasks == before)

os.execute("rm -rf '" .. HOME .. "'")
print(string.format("-- commits-refresh.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
