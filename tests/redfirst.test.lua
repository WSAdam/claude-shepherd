-- redfirst.test.lua : BEHAVIORAL fixture for the red-first proof (2026-09-29, build program unit 20).
-- After a unit's pre-merge gate passes, Shepherd takes the unit's changed test files (an uncapped
-- --diff-filter=AMR base...branch list), applies them onto a DETACHED scratch worktree at the
-- merge-base -- outside .claude/worktrees/, with Shepherd's own git, removed after -- and runs the
-- gate entry's redFirstCommand there with {files} = the changed test files, in the repo's one gate
-- lane. Failures that already happen on the base tip (a cached run of the same files there) are
-- split out. The review shows v.redFirst; it never blocks a merge.
-- Loads the real claude-dashboard.lua under a stubbed hs: git answers are canned, hs.task and
-- hs.timer are recorders, and the test plays the runner by writing its output file and firing the
-- task's exit callback. The last section runs the real shell lines against a real temp git repo.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- redfirst.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/+$", "")
local MD, SCR = T .. "/.claude/cc-merge", T .. "/scratch"
os.execute('mkdir -p "' .. T .. '/status" "' .. MD .. '" "' .. SCR .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) return os.execute('test -e "' .. tostring(path) .. '"') == true end

write(T .. "/.claude/cc-config.json", json.encode({ merge = { gates = {
  { match = { project = "/r/R/*" }, command = "GATE-R", redFirstCommand = "RF {files}" },
  { match = { project = "/r/Q/*" }, command = "GATE-Q", redFirstCommand = "RF {files}" },
  { match = { project = "/r/K/*" }, command = "GATE-K", redFirstCommand = "RF {files}", timeoutSeconds = 7 },
  { match = { project = "/r/F/*" }, command = "GATE-F", redFirstCommand = "RF {files}" },
  { match = { project = "/r/N/*" }, command = "GATE-N" },
} } }))
write(T .. "/.panel-alive", tostring(now))

-- git's canned answers: the changed files per branch commit, what exists on each base tip
local FACTS, PLANS, ATBASE, EXECS = {}, {}, {}, {}
local function plan(sha, mb, tip, files)
  PLANS[sha] = "@@mergebase\n" .. mb .. "\n@@basetip\n" .. tip .. "\n@@changed\n" .. table.concat(files, "\n") .. "\n"
end
local function setFacts(wt, repo, branch, sha)
  FACTS[wt] = table.concat({ "@@listed", "worktree " .. repo, "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD " .. sha, "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@sha", sha, "@@status", "", "@@ahead", "1", "@@behind", "0",
    "@@commits", sha:sub(1, 7) .. "\tthe unit's change", "@@stat", " 2 files changed", "@@files", "M\tapp.lua", "" }, "\n")
end
local function newUnit(key, repo, branch, sha, pid)
  local wt = repo .. "/.claude/worktrees/" .. key
  write(T .. "/" .. key .. ".jsonl", '{"type":"user","message":{"role":"user","content":"Start unit ' .. branch
    .. ' in its own worktree: call EnterWorktree with name \\"' .. key .. '\\", then rename its branch."}}\n')
  write(T .. "/status/" .. key .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%d","session_pid":"%d","transcript_path":"%s"}',
    key, key, wt, now - 60, now - 60, pid, pid, T .. "/" .. key .. ".jsonl"))
  write(MD .. "/" .. key .. ".json", json.encode({ v = 1, key = key, session_id = key, pid = tostring(pid),
    nonce = "n-" .. key, worktree = wt, branch = branch, base = "main", commonDir = repo .. "/.git",
    summary = "unit " .. key, tests = "make test: green", ahead = 1, at = now, phase = "requested" }))
  setFacts(wt, repo, branch, sha)
  return wt
end

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SCRATCH_DIR = SCR, SHELL = "/bin/zsh", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local alerts = {}
local function webviewHandle()
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
    -- the scratch dir is real (a leftover scratch worktree is a real folder there); /r/* never is
    attributes = function(path)
      if tostring(path):sub(1, #SCR) == SCR and exists(path) then return { mode = "directory" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    if cmd:find("@@listed", 1, true) then return FACTS[cmd:match("%-C '([^']+)'") or ""] or "" end
    if cmd:find("@@mergebase", 1, true) then
      EXECS[#EXECS + 1] = cmd
      return PLANS[cmd:match("%.%.%.(%x+)") or ""] or ""
    end
    if cmd:find("ls-tree -r --name-only", 1, true) then
      EXECS[#EXECS + 1] = cmd
      return ATBASE[cmd:match("ls%-tree %-r %-%-name%-only (%x+)") or ""] or ""
    end
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
local fakeApp = { allWindows = function() return {} end, activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
-- Tasks and backstop timers are recorders: the test fires their callbacks itself.
local TASKS, TIMERS = {}, {}
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, dir = false, running = false, terminated = false }
  function t:start() self.running = true; return self end
  function t:setWorkingDirectory(d) self.dir = d; return true end
  function t:terminate() self.terminated = true; self.running = false; return true end
  function t:isRunning() return self.running end
  TASKS[#TASKS + 1] = t
  return setmetatable(t, { __index = function() return function() return nil end end })
end)
rawset(hs.timer, "doAfter", function(secs, fn)
  local t = { secs = secs, fn = fn, stopped = false }
  function t:stop() self.stopped = true end
  function t:start() return self end
  TIMERS[#TIMERS + 1] = t
  return t
end)
hs.reload = function() end
hs.processInfo = { processID = 10000, bundleID = "org.hammerspoon.Hammerspoon" }
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function cmdOf(t) return tostring(t.args[3] or t.args[2] or "") end
local function tasks(needle)
  local out = {}
  for _, t in ipairs(TASKS) do if cmdOf(t):find(needle, 1, true) then out[#out + 1] = t end end
  return out
end
local function logOf(t) return cmdOf(t):match("> '([^']+)' 2>&1") end
local function finishTask(t, code, text)
  local f = logOf(t)
  os.execute('mkdir -p "' .. (f:match("^(.*)/[^/]+$") or ".") .. '"')
  write(f, text or "")
  t.running = false
  quiet(function() t.cb(code, "", "") end)
end
local function planExecs(sha)
  local n = 0
  for _, c in ipairs(EXECS) do if c:find("@@mergebase", 1, true) and c:find("..." .. sha, 1, true) then n = n + 1 end end
  return n
end
local function rf(key) local I = items(); return I[key] and I[key].merge and I[key].merge.redFirst end

-- ---- the proof runs only after the pre-merge gate passes ------------------------------------
local u1Wt = newUnit("u1", "/r/R", "feat/u1", "aaa111", 801)
plan("aaa111", "cb0001", "bb0002", { "app.lua", "tests/a.test.lua", "tests/fixtures/f.json", "tests/b.test.sh" })
ATBASE["bb0002"] = "tests/b.test.sh\n"
tick()
local g1 = tasks("GATE-R")[1]
check("the unit's pre-merge gate runs first, in its worktree", g1 ~= nil and g1.dir == u1Wt)
if not g1 then finish() end
local v = rf("u1")
check("while the gate runs, the review says red-first waits for it  (" .. tostring(v and v.state) .. ")", v and v.state == "waiting")
check("...and nothing about the branch is read yet", planExecs("aaa111") == 0 and #tasks("RF ") == 0)

finishTask(g1, 0, "all green\n")
tick()
check("a passed gate reads the changed files with Shepherd's own git, once", planExecs("aaa111") == 1)
local planCmd = EXECS[1] or ""
check("...an uncapped --diff-filter=AMR base...branch list  (" .. planCmd:sub(1, 160) .. "…)",
      planCmd:find("--diff-filter=AMR 'refs/heads/main'...aaa111", 1, true) ~= nil and planCmd:find("head -n", 1, true) == nil)
local B = tasks("worktree add --detach '" .. SCR .. "/redfirst-")
local branchRun, baseRun
for _, t in ipairs(TASKS) do
  if cmdOf(t):find("' cb0001", 1, true) then branchRun = t end
  if cmdOf(t):find("' bb0002", 1, true) then baseRun = t end
end
check("one run per repo at a time: the branch run and the base-tip run share the gate lane  (" .. #B .. " launched)", #B == 1)
v = rf("u1")
check("...and the review says it is on its way  (" .. tostring(v and v.state) .. ")", v and (v.state == "running" or v.state == "queued"))
local I = items()
check("red-first never holds the merge: the request is ready while it runs  (" .. tostring(I.u1.merge.line) .. ")",
      I.u1.merge.ready == true and I.u1.merge.line == "⇡ ready to merge feat/u1 → main")

-- let whichever went first finish, then the other one starts
local first = B[1]
if first == branchRun then
  finishTask(branchRun, 1, "== tests/a.test.lua ==\nFAIL - a new behaviour\n== tests/b.test.sh ==\nFAIL - b old breakage\nFAIL - b new behaviour\n")
else
  finishTask(baseRun, 1, "== tests/b.test.sh ==\nFAIL - b old breakage\n")
end
tick()
for _, t in ipairs(TASKS) do
  if cmdOf(t):find("' cb0001", 1, true) then branchRun = t end
  if cmdOf(t):find("' bb0002", 1, true) then baseRun = t end
end
check("the second run starts once the lane frees", branchRun ~= nil and baseRun ~= nil)
if not (branchRun and baseRun) then finish() end

-- the scratch worktree: detached, at the merge-base, outside .claude/worktrees/, removed after
local bc = cmdOf(branchRun)
local scratch = bc:match("worktree add %-%-detach '([^']+)'") or ""
check("the scratch worktree lives in Shepherd's scratch dir  (" .. scratch .. ")",
      scratch:sub(1, #SCR + 10) == SCR .. "/redfirst-" and not scratch:find(".claude/worktrees", 1, true))
check("...is a DETACHED worktree at the merge-base, made with the repo's own git",
      bc:find("--git-dir='/r/R/.git' worktree add --detach '" .. scratch .. "' cb0001", 1, true) ~= nil)
check("...gets the unit's changed test files (fixtures too) from the branch commit, nothing else",
      bc:find("checkout aaa111 -- 'tests/a.test.lua' 'tests/fixtures/f.json' 'tests/b.test.sh'", 1, true) ~= nil
      and not bc:find("'app.lua'", 1, true))
check("...runs the command with {files} = the changed test files", bc:find("RF 'tests/a.test.lua' 'tests/b.test.sh'", 1, true) ~= nil)
check("...and removes the worktree after", bc:find("worktree remove --force '" .. scratch .. "'", 1, true) ~= nil)
check("...through the login shell, from the main checkout", branchRun.args[1] == "-l" and branchRun.dir == "/r/R")
local bsc = cmdOf(baseRun)
check("the base-tip run: the files that exist there, on the base tip, nothing checked out  (" .. bsc:sub(1, 200) .. "…)",
      bsc:find("RF 'tests/b.test.sh'", 1, true) ~= nil and not bsc:find("tests/a.test.lua", 1, true)
      and not bsc:find("checkout", 1, true))

if first == branchRun then
  finishTask(baseRun, 1, "== tests/b.test.sh ==\nFAIL - b old breakage\n")
else
  finishTask(branchRun, 1, "== tests/a.test.lua ==\nFAIL - a new behaviour\n== tests/b.test.sh ==\nFAIL - b old breakage\nFAIL - b new behaviour\n")
end
tick()
v = rf("u1")
check("every changed test file fails without the fix -> proved red  (" .. tostring(v and v.state) .. ")", v and v.state == "red")
check("...both files named", v and table.concat(v.red or {}, ",") == "tests/a.test.lua,tests/b.test.sh")
check("...the failure that already fails on the base tip is split out", v and v.old == 1
      and v.fails:find("b new behaviour", 1, true) and not v.fails:find("b old breakage", 1, true))
check("a scratch worktree the run removed itself needs no second cleanup", #tasks("worktree remove --force '" .. SCR) == 2)
-- 2026-09-29: the verdict reads the whole runner log; the 1 Hz tick must not re-read it every second
do
  local realVerdict, calls = core.redFirstVerdict, 0
  core.redFirstVerdict = function(...) calls = calls + 1; return realVerdict(...) end
  tick(); tick(); tick()
  core.redFirstVerdict = realVerdict
  check("a finished verdict is read once, not on every tick  (" .. calls .. " reads over 3 ticks)", calls == 0)
  v = rf("u1")
  check("...and still shows", v and v.state == "red")
end

-- a new commit: a new branch run, the cached base-tip run reused
setFacts(u1Wt, "/r/R", "feat/u1", "aaa222")
plan("aaa222", "cb0001", "bb0002", { "app.lua", "tests/a.test.lua", "tests/fixtures/f.json", "tests/b.test.sh" })
quiet(function() fx.mergeFacts(fx._mergeReqs.u1, true) end)
tick()
local g2 = tasks("GATE-R")[2]
check("a new commit re-runs the gate", g2 ~= nil)
finishTask(g2, 0, "all green\n")
tick()
local br2
for _, t in ipairs(TASKS) do if cmdOf(t):find("checkout aaa222 --", 1, true) then br2 = t end end
check("...then a new red-first run for that commit", br2 ~= nil)
local baseRuns = 0
for _, t in ipairs(TASKS) do if cmdOf(t):find("' bb0002", 1, true) then baseRuns = baseRuns + 1 end end
check("...while the base tip's run is cached: same tip, same files, no second run", baseRuns == 1)
if br2 then finishTask(br2, 1, "== tests/a.test.lua ==\nFAIL - a new behaviour\n== tests/b.test.sh ==\nFAIL - b old breakage\n") end
tick()
v = rf("u1")
check("...and its split still uses it: b's only failure is old, so b is not red  (" .. tostring(v and v.state) .. ")",
      v and v.state == "notRed" and table.concat(v.notRed or {}, ",") == "tests/b.test.sh" and v.old == 1)

-- ---- not red never blocks Merge -----------------------------------------------------------
newUnit("u2", "/r/Q", "feat/u2", "ccc111", 802)
plan("ccc111", "cb0101", "bb0102", { "tests/c.test.lua" })
ATBASE["bb0102"] = ""
tick()
finishTask(tasks("GATE-Q")[1], 0, "all green\n")
tick()
local qRun = tasks("RF 'tests/c.test.lua'")[1]
check("a new test file alone: one run, no base-tip run", qRun ~= nil and #tasks("' bb0102") == 0)
if qRun then finishTask(qRun, 0, "== tests/c.test.lua ==\nok   - c works\n") end
tick()
v = rf("u2")
check("tests that pass without the fix -> not red, naming the file  (" .. tostring(v and v.state) .. ")",
      v and v.state == "notRed" and table.concat(v.notRed or {}, ",") == "tests/c.test.lua")
I = items()
check("...the request is still ready", I.u2.merge.ready == true)
quiet(function() fx.mergeApprove("u2") end)
check("...and Merge goes through", read(MD .. "/u2.decision") ~= nil)

-- ---- couldn't run: a timeout, and the scratch worktree it left behind ----------------------
newUnit("u3", "/r/K", "feat/u3", "ddd111", 803)
plan("ddd111", "cb0201", "bb0202", { "tests/d.test.lua" })
tick()
finishTask(tasks("GATE-K")[1], 0, "all green\n")
tick()
local kRun = tasks("RF 'tests/d.test.lua'")[1]
check("the run starts", kRun ~= nil)
if not kRun then finish() end
local kScratch = cmdOf(kRun):match("worktree add %-%-detach '([^']+)'")
os.execute('mkdir -p "' .. kScratch .. '"')   -- the wedged run had made its worktree
local backstop
for _, tm in ipairs(TIMERS) do if tm.secs == 7 and not tm.stopped then backstop = tm end end
check("the run has a retained backstop timer (the gate entry's timeout)", backstop ~= nil)
local before = #TASKS
quiet(function() backstop.fn() end)
check("...which terminates the wedged run", kRun.terminated == true)
finishTask(kRun, 143, "FAIL - d half-ran\n")
tick()
v = rf("u3")
check("a timed-out run is couldn't-run, never red  (" .. tostring(v and v.state) .. ")", v and v.state == "couldntRun" and v.red == nil)
local cl
for i = before + 1, #TASKS do
  if cmdOf(TASKS[i]):find("worktree remove --force '" .. kScratch .. "'", 1, true) and TASKS[i].args[1] == "-c" then cl = TASKS[i] end
end
check("...and Shepherd removes the scratch worktree it left behind, with the repo's git  (" .. tostring(cl and cmdOf(cl)) .. ")",
      cl ~= nil and cmdOf(cl):find("--git-dir='/r/K/.git'", 1, true) ~= nil and cl.running == true)
tick()
local again = 0
for i = before + 1, #TASKS do if cmdOf(TASKS[i]):find("worktree remove --force '" .. kScratch .. "'", 1, true) then again = again + 1 end end
check("...once, not once per tick", again == 1)

-- ---- no red-first: no command, or a gate that isn't green ---------------------------------
newUnit("u4", "/r/N", "feat/u4", "eee111", 804)
plan("eee111", "cb0301", "bb0302", { "tests/e.test.lua" })
tick()
finishTask(tasks("GATE-N")[1], 0, "all green\n")
tick()
check("no redFirstCommand: nothing is read, nothing runs, nothing is shown",
      planExecs("eee111") == 0 and rf("u4") == nil)
newUnit("u5", "/r/F", "feat/u5", "fff111", 805)
plan("fff111", "cb0401", "bb0402", { "tests/f.test.lua" })
tick()
finishTask(tasks("GATE-F")[1], 1, "FAIL - the unit's own suite is red\n")
tick()
check("a red gate: no red-first run (the gate is the news)", planExecs("fff111") == 0 and rf("u5") == nil)

-- ---- a finished request takes its runs with it --------------------------------------------
os.remove(MD .. "/u1.json")
tick()
local left = 0
for _, p in pairs(fx._redFirstPlans or {}) do if p.nonce == "n-u1" then left = left + 1 end end
check("a request that is gone drops its red-first plans", left == 0)

-- ---- a leftover from a crash: the startup sweep removes it --------------------------------
local stray = SCR .. "/redfirst-9-9"
os.execute('mkdir -p "' .. stray .. '/tests"')
before = #TASKS
quiet(function() fx.pruneScratch() end)
local sw
for i = before + 1, #TASKS do if cmdOf(TASKS[i]):find("worktree remove --force '" .. stray .. "'", 1, true) then sw = TASKS[i] end end
check("startup removes a red-first scratch worktree a crash left behind, asking it which repo it belongs to",
      sw ~= nil and cmdOf(sw):find("git -C '" .. stray .. "' rev-parse", 1, true) ~= nil)

-- ---- the real shell lines, against a real repo ----------------------------------------------
-- A main with app.sh and a passing test; a branch that adds wave() and a test for it. The run at
-- the merge-base gets the new test, not the fix, so it fails -- and the scratch worktree is gone.
local R = T .. "/repo"
local function sh(c) return os.execute("cd '" .. R .. "' && " .. c .. " >/dev/null 2>&1") == true end
os.execute("mkdir -p '" .. R .. "/tests'")
local G = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false"
write(R .. "/app.sh", "greet() { echo hi; }\n")
write(R .. "/tests/old.test.sh", '. ./app.sh; [ "$(greet)" = hi ] && echo "ok   - greets" || { echo "FAIL - greets"; exit 1; }\n')
local okRepo = sh(G .. " init -q") and sh(G .. " add -A") and sh(G .. " commit -qm base")
  and sh(G .. " checkout -qb feat/wave")
write(R .. "/app.sh", "greet() { echo hi; }\nwave() { echo wave; }\n")
write(R .. "/tests/new.test.sh", '. ./app.sh; [ "$(wave 2>/dev/null)" = wave ] && echo "ok   - waves" || { echo "FAIL - waves"; exit 1; }\n')
okRepo = okRepo and sh(G .. " add -A") and sh(G .. " commit -qm wave") and sh(G .. " checkout -q main")
check("a real repo with a unit branch", okRepo)
local function capture(c) local p = io.popen(c .. " 2>/dev/null"); local s = p and p:read("*a") or ""; if p then p:close() end; return s end
local sha = capture("git -C '" .. R .. "' rev-parse feat/wave"):match("%x+") or ""
local req = { commonDir = R .. "/.git", base = "main", branch = "feat/wave", worktree = R }
local realPlan = core.redFirstPlan(capture(core.redFirstPlanCmd(req, sha) or "false"),
  "rc=0; for f in {files}; do echo \"== $f ==\"; sh \"$f\" || rc=1; done; exit $rc")
check("the real plan: the new test runs, app.sh stays behind",
      realPlan and table.concat(realPlan.run, ",") == "tests/new.test.sh" and table.concat(realPlan.apply, ",") == "tests/new.test.sh")
if realPlan then
  realPlan.atBase = core.redFirstAtBase(capture(core.redFirstAtBaseCmd(req.commonDir, realPlan.baseTip, realPlan.run) or "false"), realPlan.run)
  check("...none of it exists on the base tip yet", realPlan.atBase and #realPlan.atBase == 0)
  local scr = T .. "/scr/redfirst-1-1"
  os.execute("mkdir -p '" .. T .. "/scr'")
  local line = core.mergeGateCmd({ command = "x", run = core.redFirstRunCmd({ commonDir = req.commonDir, scratch = scr,
    at = realPlan.mergeBase, applyFrom = sha, apply = realPlan.apply, command = realPlan.branchCmd }) }, R, T .. "/rf.log")
  local _, _, code = os.execute(line)
  local outText = read(T .. "/rf.log") or ""
  local verdict = core.redFirstVerdict(realPlan, { state = core.mergeGateOutcome(code, outText), code = code, output = outText }, nil)
  if not (verdict and verdict.state == "red") then print("       run output: " .. outText:gsub("\n", " | "):gsub("FAIL", "F-AIL")) end
  check("the new test fails at the merge-base without its fix -> proved red",
        verdict and verdict.state == "red" and outText:find("FAIL - waves", 1, true) ~= nil)
  check("...the scratch worktree is gone afterwards", not exists(scr))
  check("...and git no longer lists it", not capture("git -C '" .. R .. "' worktree list --porcelain"):find(scr, 1, true))
  check("...and neither checkout was touched",
        capture("git -C '" .. R .. "' status --porcelain") == "" and capture("git -C '" .. R .. "' rev-parse --abbrev-ref HEAD"):match("^main"))
end

finish()
