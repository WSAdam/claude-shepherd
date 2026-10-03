-- gateblame.test.lua : BEHAVIORAL fixture for gate blame (2026-10-03, mining round 2 unit E1a).
-- A red pre-merge gate said THAT the suite failed, never whose failures they were: a unit cut from
-- a red main took the blame for main's breakage too. When a gate fails with failing test lines,
-- Shepherd runs the SAME gate command on a detached scratch worktree at the merge-base -- outside
-- .claude/worktrees/, Shepherd's own git, nothing of the unit's applied, removed after -- cached per
-- repo + merge-base + command, in the repo's one gate lane BEHIND any gate that judges a merge. The
-- review splits the failures (v.gateBlame); it never makes a red gate mergeable.
-- Loads the real claude-dashboard.lua under a stubbed hs (the tests/redfirst.test.lua harness): git
-- answers are canned, hs.task and hs.timer are recorders, and the test plays the runner by writing
-- its output file and firing the task's exit callback. The last section runs the real shell lines
-- against a real temp git repo. Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- gateblame.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

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
  { match = { project = "/r/R/*" }, command = "GATE-R" },
  { match = { project = "/r/K/*" }, command = "GATE-K", timeoutSeconds = 7 },
  { match = { project = "/r/Q/*" }, command = "GATE-Q" },
} } }))
write(T .. "/.panel-alive", tostring(now))

-- git's canned answers: the facts per worktree, the merge-base per branch commit
local FACTS, MBS, EXECS = {}, {}, {}
local function setFacts(wt, repo, branch, sha)
  FACTS[wt] = table.concat({ "@@listed", "worktree " .. repo, "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD " .. sha, "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@sha", sha, "@@status", "", "@@ahead", "1", "@@behind", "0",
    "@@commits", sha:sub(1, 7) .. "\tthe unit's change", "@@stat", " 2 files changed", "@@files", "M\tapp.lua", "" }, "\n")
end
local function newUnit(key, repo, branch, sha, pid, at)
  local wt = repo .. "/.claude/worktrees/" .. key
  write(T .. "/" .. key .. ".jsonl", '{"type":"user","message":{"role":"user","content":"Start unit ' .. branch
    .. ' in its own worktree: call EnterWorktree with name \\"' .. key .. '\\", then rename its branch."}}\n')
  write(T .. "/status/" .. key .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%d","session_pid":"%d","transcript_path":"%s"}',
    key, key, wt, now - 60, now - 60, pid, pid, T .. "/" .. key .. ".jsonl"))
  write(MD .. "/" .. key .. ".json", json.encode({ v = 1, key = key, session_id = key, pid = tostring(pid),
    nonce = "n-" .. key, worktree = wt, branch = branch, base = "main", commonDir = repo .. "/.git",
    summary = "unit " .. key, tests = "make test: green", ahead = 1, at = at or now, phase = "requested" }))
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
    local sha = cmd:match("merge%-base 'refs/heads/main' (%x+)")
    if sha then
      EXECS[#EXECS + 1] = cmd
      return MBS[sha] and ("@@mergebase\n" .. MBS[sha] .. "\n") or "@@mergebase\n"
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
local function mbExecs(sha)
  local n = 0
  for _, c in ipairs(EXECS) do if c:find(" " .. sha, 1, true) then n = n + 1 end end
  return n
end
local function gb(key) local I = items(); return I[key] and I[key].merge and I[key].merge.gateBlame end
local MB = string.rep("c", 40)
local function blameRuns(repo)
  local out = {}
  for _, t in ipairs(tasks("worktree add --detach '" .. SCR .. "/redfirst-")) do
    if not repo or cmdOf(t):find("--git-dir='" .. repo .. "/.git'", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function lastGate(name) local g = tasks(name); return g[#g] end

-- ---- a red gate gets a run on main, behind every gate that judges a merge ----------------------
local RED = "== suite: config ==\nok   - reads the file\nFAIL - an old breakage (0.2s)\n== suite: core ==\nFAIL - the new behaviour\n"
local u1Wt = newUnit("u1", "/r/R", "feat/u1", "aaa111", 801, now - 30)
local u2Wt = newUnit("u2", "/r/R", "feat/u2", "bbb111", 802, now - 20)
MBS["aaa111"], MBS["bbb111"], MBS["ccc111"] = MB, MB, MB
tick()
local g1 = tasks("GATE-R")[1]
check("one gate per repo: u1's gate runs first, in its worktree", g1 ~= nil and g1.dir == u1Wt and #tasks("GATE-R") == 1)
if not g1 then finish() end
check("...nothing is read about main while the gate runs", mbExecs("aaa111") == 0 and gb("u1") == nil)
finishTask(g1, 2, RED)
tick()
check("a red gate with failing test lines reads the merge-base with Shepherd's own git, once",
      mbExecs("aaa111") == 1 and (EXECS[1] or ""):find("--git-dir='/r/R/.git' merge-base 'refs/heads/main' aaa111", 1, true) ~= nil)
local g2 = lastGate("GATE-R")
check("u2's gate takes the lane; the blame run waits  (" .. #TASKS .. " tasks)", g2 ~= g1 and g2.dir == u2Wt and #blameRuns() == 0)
local v = gb("u1")
check("...and the review says the run on main is queued  (" .. tostring(v and v.state) .. ")",
      v and v.state == "queued" and v.at == MB:sub(1, 7))
local I = items()
check("the red gate still holds the merge  (" .. tostring(I.u1.merge.line) .. ")", I.u1.merge.ready == false)
-- the blame run has waited a while; a gate asked for only now must still go ahead of it
for _, g in pairs(fx._gateBlameRuns or {}) do g.at = (g.at or now) - 100 end
local u3Wt = newUnit("u3", "/r/R", "feat/u3", "ccc111", 803)
tick()
check("u3's gate queues behind u2's", lastGate("GATE-R") == g2)
finishTask(g2, 0, "all green\n")
tick()
local g3 = lastGate("GATE-R")
check("a gate queued AFTER the blame run still takes the lane first: blame is information, the gate judges a merge",
      g3 ~= g2 and g3.dir == u3Wt and #blameRuns() == 0)
finishTask(g3, 1, "== suite: config ==\nFAIL - an old breakage\n")
tick()
local B = blameRuns()
check("once no gate waits, the blame run starts -- one run for both units cut from this main  (" .. #B .. ")", #B == 1)
if #B ~= 1 then finish() end
check("...and u3's red gate didn't read the merge-base twice for nothing", mbExecs("ccc111") == 1)
local bc = cmdOf(B[1])
local scratch = bc:match("worktree add %-%-detach '([^']+)'") or ""
check("the scratch worktree lives in Shepherd's scratch dir  (" .. scratch .. ")",
      scratch:sub(1, #SCR + 10) == SCR .. "/redfirst-" and not scratch:find(".claude/worktrees", 1, true))
check("...is a DETACHED worktree at the merge-base, made with the repo's own git",
      bc:find("--git-dir='/r/R/.git' worktree add --detach '" .. scratch .. "' " .. MB, 1, true) ~= nil)
check("...gets nothing of the unit's checked out onto it", not bc:find("checkout", 1, true))
check("...runs the SAME gate command inside it", bc:find("(cd '" .. scratch .. "' && GATE-R)", 1, true) ~= nil)
check("...removes the worktree after", bc:find("worktree remove --force '" .. scratch .. "'", 1, true) ~= nil)
check("...through the login shell, from the main checkout", B[1].args[1] == "-l" and B[1].dir == "/r/R")
v = gb("u1")
check("...and the review says it is running  (" .. tostring(v and v.state) .. ")", v and v.state == "running")
finishTask(B[1], 2, "== suite: config ==\nFAIL - an old breakage (0.9s)\n== suite: core ==\nok   - the new behaviour\n")
tick()
v = gb("u1")
check("the split: one failure already on main, one new in this branch  (" .. tostring(v and v.newN) .. "/" .. tostring(v and v.oldN) .. ")",
      v and v.state == "split" and v.newN == 1 and v.oldN == 1
      and v.new == "FAIL - the new behaviour" and v.old == "FAIL - an old breakage (0.2s)")
v = gb("u3")
check("...and u3, cut from the same main, reads the same run: its only failure is main's  (" .. tostring(v and v.state) .. ")",
      v and v.state == "split" and v.newN == 0 and v.oldN == 1)
I = items()
check("information only: a red gate stays red with the split in hand  (" .. tostring(I.u3.merge.line) .. ")",
      I.u1.merge.ready == false and I.u3.merge.ready == false)
quiet(function() fx.mergeApprove("u3") end)
check("...and Merge is still refused, even when every failure is main's", read(MD .. "/u3.decision") == nil)
do
  local realVerdict, calls = core.gateBlameVerdict, 0
  core.gateBlameVerdict = function(...) calls = calls + 1; return realVerdict(...) end
  tick(); tick(); tick()
  core.gateBlameVerdict = realVerdict
  check("a finished split is read once, not on every tick  (" .. calls .. " reads over 3 ticks)", calls == 0)
  v = gb("u1")
  check("...and still shows", v and v.state == "split")
end

-- ---- a gate that isn't red, or names no failing test, gets nothing -------------------------------
setFacts(u1Wt, "/r/R", "feat/u1", "aaa222")
MBS["aaa222"] = MB
quiet(function() fx.mergeFacts(fx._mergeReqs.u1, true) end)
tick()
local g4 = lastGate("GATE-R")
check("a new commit re-runs the gate", g4 ~= g3 and g4.dir == u1Wt)
check("...and while it runs there's no blame", gb("u1") == nil)
finishTask(g4, 0, "all green\n")
tick()
check("a green gate: no blame, and main isn't read", gb("u1") == nil and mbExecs("aaa222") == 0)
newUnit("u5", "/r/R", "feat/u5", "eee111", 805)
MBS["eee111"] = string.rep("e", 40)
tick()
finishTask(lastGate("GATE-R"), 2, "luacheck: 4 warnings / 0 errors\n❌ lint failed\n")
tick()
v = gb("u5")
check("a red gate that names no failing test: nothing to compare, nothing runs  (" .. tostring(v and v.state) .. ")",
      v and v.state == "none" and mbExecs("eee111") == 0 and #blameRuns() == 1)

-- ---- couldn't run: a timeout counts on neither side, and isn't retried ------------------------
newUnit("k1", "/r/K", "feat/k1", "ddd111", 806)
MBS["ddd111"] = string.rep("d", 40)
tick()
finishTask(tasks("GATE-K")[1], 1, "== s ==\nFAIL - mine\n")
tick()
local kRun = blameRuns("/r/K")[1]
check("the K repo's blame run starts beside R's lane: lanes are per repo", kRun ~= nil)
if not kRun then finish() end
local backstop
for _, tm in ipairs(TIMERS) do if tm.secs == 7 and not tm.stopped then backstop = tm end end
check("the run has a retained backstop timer (the gate's timeout)", backstop ~= nil)
if not backstop then finish() end
quiet(function() backstop.fn() end)
check("...which terminates the wedged run", kRun.terminated == true)
finishTask(kRun, 143, "== s ==\nFAIL - mine\n")
tick()
v = gb("k1")
check("a timed-out run on main is couldn't-run: no failure counted on either side  (" .. tostring(v and v.state) .. ")",
      v and v.state == "couldntRun" and v.why == "it timed out" and v.newN == nil and v.oldN == nil)
newUnit("q1", "/r/Q", "feat/q1", "fff111", 807)
MBS["fff111"] = string.rep("f", 40)
tick()
finishTask(tasks("GATE-Q")[1], 1, "== s ==\nFAIL - mine\n")
tick()
local qRun = blameRuns("/r/Q")[1]
check("the Q repo's blame run starts", qRun ~= nil)
if not qRun then finish() end
finishTask(qRun, 9, "CC_GATE_CANNOT_RUN: Shepherd couldn't set up the scratch worktree at ffffff\n")
tick()
v = gb("q1")
check("a run on main that couldn't run counts on neither side  (" .. tostring(v and v.state) .. ")",
      v and v.state == "couldntRun" and v.newN == nil and v.oldN == nil)
for _, g in pairs(fx._gateBlameRuns or {}) do g.doneAt = (g.doneAt or now) - 3600 end
tick()
check("...and it isn't retried, long after the gate's own retry would be: a fresh scratch would answer the same",
      #blameRuns("/r/Q") == 1 and #blameRuns("/r/K") == 1)

-- ---- a finished request takes its runs with it ------------------------------------------------
for _, k in ipairs({ "u1", "u2", "u3", "u5", "k1", "q1" }) do os.remove(MD .. "/" .. k .. ".json") end
tick()
local leftPlans, leftRuns = 0, 0
for _ in pairs(fx._gateBlamePlans or {}) do leftPlans = leftPlans + 1 end
for _ in pairs(fx._gateBlameRuns or {}) do leftRuns = leftRuns + 1 end
check("requests that are gone drop their blame plans and finished runs  (" .. leftPlans .. " plans, " .. leftRuns .. " runs)",
      leftPlans == 0 and leftRuns == 0)

-- ---- the real shell lines, against a real repo --------------------------------------------------
-- main already fails one test (and names its own path); the branch breaks a second one. The gate,
-- run again at the merge-base in a scratch worktree, splits them -- and the scratch worktree is gone.
local R = T .. "/repo"
local function sh(c) return os.execute("cd '" .. R .. "' && " .. c .. " >/dev/null 2>&1") == true end
os.execute("mkdir -p '" .. R .. "/tests'")
local G = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false"
write(R .. "/app.sh", "greet() { echo hi; }\n")
write(R .. "/tests/old.test.sh", 'echo "FAIL - old breakage in $(pwd)/app.sh"; exit 1\n')
write(R .. "/tests/greet.test.sh", '. ./app.sh; [ "$(greet)" = hi ] && echo "ok   - greets" || { echo "FAIL - greets"; exit 1; }\n')
local okRepo = sh(G .. " init -q") and sh(G .. " add -A") and sh(G .. " commit -qm base")
  and sh(G .. " checkout -qb feat/rude")
write(R .. "/app.sh", "greet() { echo go away; }\n")
okRepo = okRepo and sh(G .. " add -A") and sh(G .. " commit -qm rude")
check("a real repo with a unit branch that breaks a test on a main that already fails one", okRepo)
local function capture(c) local p = io.popen(c .. " 2>/dev/null"); local s = p and p:read("*a") or ""; if p then p:close() end; return s end
local GATE = 'rc=0; for f in tests/*.test.sh; do echo "== $f =="; sh "$f" || rc=1; done; exit $rc'
local sha = capture("git -C '" .. R .. "' rev-parse feat/rude"):match("%x+") or ""
-- the unit's own gate, in its checkout (the branch is checked out in R)
local gateLine = core.mergeGateCmd({ command = GATE }, R, T .. "/gate.log")
local _, _, gcode = os.execute(gateLine)
local gateOut = read(T .. "/gate.log") or ""
local gate = { state = core.mergeGateOutcome(gcode, gateOut), code = gcode, command = GATE, output = gateOut }
check("the unit's gate is red, with both failures  (" .. gateOut:gsub("\n", " | "):gsub("FAIL", "F-AIL") .. ")",
      gate.state == "failed" and gateOut:find("FAIL - greets", 1, true) and gateOut:find("FAIL - old breakage", 1, true))
check("...so it is due a run on main", core.gateBlameDue(gate) == "run")
sh(G .. " checkout -q main")
local req = { commonDir = R .. "/.git", base = "main", branch = "feat/rude", worktree = R }
local mb = core.gateBlamePlan(capture(core.gateBlamePlanCmd(req, sha) or "false"))
check("the real merge-base", mb ~= nil and mb == capture("git -C '" .. R .. "' rev-parse main"):match("%x+"))
local scr = T .. "/scr/redfirst-1-1"
os.execute("mkdir -p '" .. T .. "/scr'")
local line = core.mergeGateCmd({ command = GATE, run = core.redFirstRunCmd({ commonDir = req.commonDir, scratch = scr,
  at = mb, command = core.gateBlameCommand(gate) }) }, R, T .. "/blame.log")
local _, _, bcode = os.execute(line)
local baseOut = read(T .. "/blame.log") or ""
local v2 = core.gateBlameVerdict(gate, { state = core.mergeGateOutcome(bcode, baseOut), code = bcode, output = baseOut, scratch = scr },
  { mergeBase = mb, command = GATE, root = R })
if not (v2 and v2.state == "split") then print("       run output: " .. baseOut:gsub("\n", " | "):gsub("FAIL", "F-AIL")) end
check("the run on main splits them: the old breakage is main's, greets is the branch's  (" .. tostring(v2 and v2.state) .. ")",
      v2 and v2.state == "split" and v2.newN == 1 and v2.oldN == 1
      and v2.new == "FAIL - greets" and (v2.old or ""):find("old breakage in " .. R .. "/app.sh", 1, true) ~= nil)
check("...the scratch worktree is gone afterwards", not exists(scr))
check("...and git no longer lists it", not capture("git -C '" .. R .. "' worktree list --porcelain"):find(scr, 1, true))
check("...and the checkout wasn't touched",
      capture("git -C '" .. R .. "' status --porcelain") == "" and capture("git -C '" .. R .. "' rev-parse --abbrev-ref HEAD"):match("^main"))

finish()
