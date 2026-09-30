-- schedlock-refresh.test.lua : the scheduled-tasks lock check's wiring under a STUBBED Hammerspoon
-- (2026-09-29, build program unit 39). FX.refreshSchedLocks reads each launch folder's
-- .claude/scheduled_tasks.lock and runs ONE background probe (core.SCHED_LOCK_SH: a ps for every
-- lock's pid plus Shepherd's own, and `git ls-tree` for folders whose HEAD it hasn't read) in an
-- hs.task with stdout in a scratch file, on the FX.refreshCommits pattern -- its own timer, never
-- the tick. This drives the real functions on real folders: no lock means no probe, the probe's
-- argv, a landed probe stamped on every tile of the card (FX.annotateSchedLocks), the per-HEAD git
-- cache (a new commit asks again), a hung probe reclaimed, a failed one keeping the last answer,
-- schedLock.enabled=false, and a tick that starts nothing.
-- Side-effect-free: a temp HOME holds the config, the scratch dir and the folders.

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
local function sh(cmd) local p = io.popen(cmd .. " 2>/dev/null"); local o = p:read("*a"); p:close(); return o end

-- Two real folders: a git repo with a committed lock, and a plain folder whose lock is a copy.
local REPO, PLAIN, QUIET = HOME .. "/qb", HOME .. "/plain", HOME .. "/quiet"
local LOCK = '{"sessionId":"sess-qb","pid":44063,"procStart":"Thu Jun 11 20:07:15 2026","acquiredAt":1781224931116}'
os.execute("mkdir -p '" .. REPO .. "/.claude' '" .. PLAIN .. "/.claude' '" .. QUIET .. "'")
writeFile(REPO .. "/.claude/scheduled_tasks.lock", LOCK)
writeFile(PLAIN .. "/.claude/scheduled_tasks.lock", LOCK)
sh("cd '" .. REPO .. "' && git init -q && git -c user.email=t@t -c user.name=t add -A && git -c user.email=t@t -c user.name=t commit -qm one")
local function headOf(dir) return (sh("git -C '" .. dir .. "' rev-parse HEAD"):gsub("%s+$", "")) end
local SHA1 = headOf(REPO)

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
local executed = {}
local hs = {
  json = json,
  processInfo = { processID = 900 },
  fs = {
    dir = function() return function() return nil end end,
    attributes = function(p) if exists(tostring(p)) then return { mode = "file" } end return nil end,
    symlinkAttributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd) executed[#executed + 1] = cmd; return "" end,
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
if not ok then print("       " .. tostring(err)); print(string.format("-- schedlock-refresh.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core

local function lockTasks()
  local out = {}
  for _, t in ipairs(tasks) do
    if t.args and type(t.args[2]) == "string" and t.args[2]:find("'cc-schedlock'", 1, true) then out[#out + 1] = t end
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
-- the probe's positional args, as the shell will see them: 'cc-schedlock' '<pids>' '<dir>'...
local function argsOf(t)
  local tail = t.args[2]:match("'cc%-schedlock' (.-) > '") or ""
  local out = {}
  for a in tail:gmatch("'([^']*)'") do out[#out + 1] = a end
  return out
end
local function asks(t, dir) for i = 2, #argsOf(t) do if argsOf(t)[i] == dir then return i - 1 end end return nil end

-- the card's sessions: two in the repo (one of them holds the lock), one in the plain folder, one
-- in a folder with no lock, and a remote one that is never looked at
local function mklist()
  return {
    { key = "a", session_id = "sess-qb", session_pid = "44063", projectKey = REPO, cwd = REPO, stackKey = "repo:" .. REPO .. "/.git", stackName = "qb" },
    { key = "b", session_id = "sess-b", session_pid = "44100", projectKey = REPO, cwd = REPO, stackKey = "repo:" .. REPO .. "/.git", stackName = "qb" },
    { key = "p", session_id = "sess-p", session_pid = "5150", projectKey = PLAIN, cwd = PLAIN, stackKey = PLAIN, stackName = "plain" },
    { key = "q", session_id = "sess-q", session_pid = "6000", projectKey = QUIET, cwd = QUIET, stackKey = QUIET, stackName = "quiet" },
    { key = "r", remote = { host = "box" }, projectKey = "/far", cwd = "/far", stackKey = "remote:box|/far" },
  }
end
local LIST = mklist()
local LIVE = "@@ps\n44063 Thu Jun 11 20:07:15 2026\n  900 Tue Sep  1 08:00:00 2026\n"

-- 0. the panel's tick never probes
local before = #lockTasks()
pcall(function() FX._refreshBody() end)
check("the tick starts no lock probe", #lockTasks() == before)

-- 1. no folder has a lock: nothing runs
FX.refreshSchedLocks({ LIST[4] }, true)
check("no lock file anywhere: no probe runs", #lockTasks() == before)

-- 2. one probe for every lock, through /bin/sh, into a scratch file
local n0 = #executed
FX.refreshSchedLocks(LIST, true)
local t1 = lockTasks()[1]
check("one probe for every folder's lock", #lockTasks() == 1 and t1 ~= nil)
check("...through /bin/sh with its stdout in a scratch file",
      t1 and t1.path == "/bin/sh" and t1.args[1] == "-c" and (outFileOf(t1) or ""):find("/.claude/cc-scratch/schedlock-", 1, true) ~= nil)
check("...asking ps about the lock's pid and Shepherd's own", t1 and argsOf(t1)[1] == "44063,900")
check("...and git about both folders whose HEAD it hasn't read", t1 and asks(t1, REPO) ~= nil and asks(t1, PLAIN) ~= nil)
check("...never a folder with no lock, nor a remote one", t1 and asks(t1, QUIET) == nil and asks(t1, "/far") == nil)
check("...and nothing ran synchronously", #executed == n0)
FX.annotateSchedLocks(LIST)
check("nothing is stamped before the probe lands", LIST[1].schedLock == nil and LIST[3].schedLock == nil)

-- 3. no second probe while one runs
FX.refreshSchedLocks(LIST, true)
check("no second probe while one runs", #lockTasks() == 1)

-- 4. it lands: the committed lock on the repo's card (every tile of it), the copy on the plain card
local gi, pi = asks(t1, REPO), asks(t1, PLAIN)
local out1 = finish(t1, 0, LIVE .. "@@git\t" .. gi .. "\n.claude/scheduled_tasks.lock\n@@rc\t0\n@@git\t" .. pi .. "\n@@rc\t128\n")
FX.annotateSchedLocks(LIST)
check("the repo's card says its lock is in git  (" .. tostring(LIST[1].schedLock and LIST[1].schedLock.label) .. ")",
      LIST[1].schedLock ~= nil and LIST[1].schedLock.label == "🔒 lock in git")
check("...on every tile of the card", LIST[2].schedLock ~= nil and LIST[2].schedLock.label == "🔒 lock in git")
check("the plain folder's copy is held by the repo's session", LIST[3].schedLock ~= nil and LIST[3].schedLock.label == "🔒 lock held elsewhere")
check("...named in the tooltip", LIST[3].schedLock and LIST[3].schedLock.tip:find("qb", 1, true) ~= nil)
check("a folder with no lock shows nothing", LIST[4].schedLock == nil)
check("a remote tile shows nothing", LIST[5].schedLock == nil)
check("the scratch file is removed", not exists(outFileOf(t1)) and not exists(out1))

-- 5. the git answer holds for as long as HEAD does
FX.refreshSchedLocks(LIST, true)
local t2 = lockTasks()[2]
check("a second probe runs when asked", t2 ~= nil)
check("...but never asks git again at the same HEAD", t2 and asks(t2, REPO) == nil)
check("...while the pid is asked every time", t2 and argsOf(t2)[1] == "44063,900")
-- the pid died meanwhile: dead, and still committed from the cache
finish(t2, 0, "@@ps\n  900 Tue Sep  1 08:00:00 2026\n")
FX.annotateSchedLocks(LIST)
check("a dead pid reads dead, and the cached answer keeps it in git  (" .. tostring(LIST[1].schedLock and LIST[1].schedLock.label) .. ")",
      LIST[1].schedLock ~= nil and LIST[1].schedLock.label == "🔒 lock dead · in git")
check("...and the copy is dead too, not held", LIST[3].schedLock ~= nil and LIST[3].schedLock.label == "🔒 lock dead")

-- a new commit moves HEAD: git is asked again
writeFile(REPO .. "/x.txt", "x")
sh("cd '" .. REPO .. "' && git -c user.email=t@t -c user.name=t add x.txt && git -c user.email=t@t -c user.name=t commit -qm two")
check("(the fixture's HEAD moved)", headOf(REPO) ~= SHA1)
FX.refreshSchedLocks(LIST, true)
local t3 = lockTasks()[3]
check("a new HEAD asks git again", t3 and asks(t3, REPO) ~= nil)

-- 6. a hung probe is reclaimed, and its late exit can't clobber the new one
FX._schedLock.inflight.ts = os.time() - 100
FX.refreshSchedLocks(LIST)
local t4 = lockTasks()[4]
check("a probe hung past its deadline is terminated and restarted", t3.terminated == true and t4 ~= nil)
local out3 = finish(t3, 0, LIVE)
check("the reclaimed probe's late exit is dropped", FX._schedLock.inflight and FX._schedLock.inflight.task == t4)
check("...and its scratch file removed", not exists(out3))

-- 7. a failed probe keeps the last answer
finish(t4, 2, "")
FX.annotateSchedLocks(LIST)
check("a failed probe keeps the last answer", LIST[1].schedLock ~= nil and LIST[1].schedLock.label == "🔒 lock dead · in git")

-- 8. the lock is fixed (the file deleted): the badge goes at the next probe
os.remove(PLAIN .. "/.claude/scheduled_tasks.lock")
FX.refreshSchedLocks(LIST, true)
local t5 = lockTasks()[#lockTasks()]
check("a HEAD whose git answer never landed is asked again", asks(t5, REPO) ~= nil and asks(t5, PLAIN) == nil)
finish(t5, 0, LIVE .. "@@git\t" .. asks(t5, REPO) .. "\n.claude/scheduled_tasks.lock\n@@rc\t0\n")
FX.annotateSchedLocks(LIST)
check("a deleted lock loses its badge", LIST[3].schedLock == nil)
check("...while the repo's live, committed lock keeps its", LIST[1].schedLock ~= nil and LIST[1].schedLock.label == "🔒 lock in git")
check("...cached for the new HEAD", FX._schedLock.tracked[REPO] and FX._schedLock.tracked[REPO].sha == headOf(REPO))

-- 9. a probe that can't see Shepherd's own pid proves nothing
FX.refreshSchedLocks(LIST, true)
local t6 = lockTasks()[#lockTasks()]
finish(t6, 0, "@@ps\n")
FX.annotateSchedLocks(LIST)
check("an untrusted ps never reads a lock dead", LIST[1].schedLock ~= nil and LIST[1].schedLock.label == "🔒 lock in git")

-- 10. schedLock.enabled = false: nothing runs, nothing is stamped
writeFile(CONFIG, json.encode({ schedLock = { enabled = false } }))
local n = #lockTasks()
FX.refreshSchedLocks(LIST, true)
FX.annotateSchedLocks(LIST)
check("disabled: no probe runs", #lockTasks() == n)
check("disabled: no tile is stamped", LIST[1].schedLock == nil and LIST[2].schedLock == nil)
check("the lock check is live on FX and core", type(FX.refreshSchedLocks) == "function" and type(core.schedLockVerdict) == "function")

print(string.format("-- schedlock-refresh.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
