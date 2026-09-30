-- checker.test.lua : BEHAVIORAL fixture for the merge checker (2026-09-29, build program unit 17).
-- Every merge request gets a background review: core.diffRedFlags reads the diff with no model,
-- then FX.runHeadless runs a read-only `claude -p` in the unit's worktree -- one per repo at a
-- time, through the login shell, output to scratch files, with a retained timeout timer. The
-- verdict lands in ~/.claude/cc-merge/<key>.checker.json keyed by nonce|sha, and the review shows
-- it. A batch unit's delegated merge needs a pass; couldn't-run gets one retry, then waits for
-- Adam; Adam's own click still merges. Verify runs the same review for any session.
-- Loads the real claude-dashboard.lua under a stubbed hs: git answers are canned, hs.task and
-- hs.timer are recorders, and the test plays claude's part by writing its output file and firing
-- the task's exit callback. Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- checker.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local FD, MD, SCR = T .. "/.claude/cc-fleet", T .. "/.claude/cc-merge", T .. "/scratch"
os.execute('mkdir -p "' .. T .. '/status" "' .. FD .. '" "' .. MD .. '" "' .. SCR .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function decoded(path) local s = read(path); return s and json.decode(s) or nil end
local function status(key, cwd, pid)
  write(T .. "/status/" .. key .. ".json", json.encode({ status = "done", session_id = key, name = key, cwd = cwd,
    since = now - 60, updated = now - 60, editor = "vscode", host_window = "701", session_pid = pid }))
end

-- verify.onMerge is on (the driver flips it live; defaults/ ships it on)
write(T .. "/.claude/cc-config.json", json.encode({ verify = { onMerge = true } }))
write(T .. "/.panel-alive", tostring(now))

-- A batch with merges granted: units alpha and beta in repo A (one lane), gamma in repo G.
write(FD .. "/b1.json", json.encode({ v = 1, id = "b1", nonce = "n-b1", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
  repo = "/r/A", commonDir = "/r/A/.git", title = "Checked units", mergeWhenGreen = true, at = now, phase = "approved",
  units = { { type = "feat", slug = "alpha", task = "Add alpha.", branch = "feat/alpha" },
            { type = "feat", slug = "beta", task = "Add beta.", branch = "feat/beta" } } }))
write(FD .. "/b1.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = now },
  units = { alpha = { session = { id = "ua", name = "A-a", pid = "5001" } },
            beta = { session = { id = "ub", name = "A-b", pid = "5002" } } } }))
write(FD .. "/b2.json", json.encode({ v = 1, id = "b2", nonce = "n-b2", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
  repo = "/r/G", commonDir = "/r/G/.git", title = "Flaky unit", mergeWhenGreen = true, at = now, phase = "approved",
  units = { { type = "feat", slug = "gamma", task = "Add gamma.", branch = "feat/gamma" } } }))
write(FD .. "/b2.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = now },
  units = { gamma = { session = { id = "ug", name = "G-g", pid = "5003" } } } }))

local FACTS, DIFFS = {}, {}
local function request(key, repo, slug, branch, sha, pid)
  local wt = repo .. "/.claude/worktrees/" .. slug
  status(key, wt, pid)
  FACTS[wt] = table.concat({ "@@listed", "worktree " .. repo, "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD " .. sha, "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@sha", sha, "@@status", "", "@@ahead", "1", "@@behind", "0",
    "@@commits", sha:sub(1, 7) .. "\tchange", "@@stat", " 1 file changed", "@@files", "M\tapp.lua", "" }, "\n")
  write(MD .. "/" .. key .. ".json", json.encode({ v = 1, key = key, session_id = key, pid = pid, nonce = "m-" .. key,
    worktree = wt, branch = branch, base = "main", commonDir = repo .. "/.git",
    summary = slug .. " unit", tests = "make test: green", ahead = 1, at = now, phase = "requested" }))
end
request("ua", "/r/A", "alpha", "feat/alpha", "aaa111", "5001")
request("ub", "/r/A", "beta", "feat/beta", "bbb222", "5002")
request("ug", "/r/G", "gamma", "feat/gamma", "ddd333", "5003")
-- c1 is Adam's own unit (no batch): the checker reviews it, and his click merges it regardless
request("c1", "/r/C", "cee", "fix/cee", "ccc444", "5004")
-- v1 has no merge request at all: Verify reviews its checkout against main
status("v1", "/r/V", "5005")

DIFFS["main...aaa111"] = "diff --git a/app.lua b/app.lua\n--- a/app.lua\n+++ b/app.lua\n@@ -1 +1,2 @@\n x = 1\n+error(\"not implemented\")\n"
DIFFS["main...bbb222"] = "diff --git a/app.lua b/app.lua\n--- a/app.lua\n+++ b/app.lua\n@@ -1 +1,2 @@\n x = 1\n+y = 2\n"
DIFFS["main...ddd333"] = DIFFS["main...bbb222"]
DIFFS["main...ccc444"] = DIFFS["main...bbb222"]
DIFFS["fff000"] = "diff --git a/v.lua b/v.lua\n--- a/v.lua\n+++ b/v.lua\n@@ -1 +1,2 @@\n v = 1\n+w = 2\n"
local VERIFY_V = table.concat({ "@@root", "/r/V", "@@common", "/r/V/.git", "@@branch", "main", "@@sha", "eee555",
  "@@mbmain", "fff000", "@@mbmaster", "", "@@untracked", "", "" }, "\n")

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SCRATCH_DIR = SCR, SHELL = "/bin/zsh", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, alerts, execs = 0, {}, {}
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
      -- the batches' repo roots exist (an absent one ends its batch: "its repo is gone")
      if path == "/r/A" or path == "/r/G" then return { mode = "directory" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    if cmd:find("diff --no-color", 1, true) and cmd:find("head -c", 1, true) then
      execs[#execs + 1] = cmd
      for k, d in pairs(DIFFS) do
        if cmd:find(" " .. k .. " ", 1, true) then return d end
      end
      return ""
    end
    if cmd:find("@@listed", 1, true) then return FACTS[cmd:match("%-C '([^']+)'") or ""] or "" end
    if cmd:find("@@root", 1, true) and cmd:find("'/r/V'", 1, true) then return VERIFY_V end
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
local fx = rawget(_G, "__ccDashboard").fx
fx.fleetRepoGone = function() return false end
local OFFSET = 0
fx.now = function() return os.time() + OFFSET end
local function tick() return quiet(function() fx._refreshBody() end) end
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function alerted(needle) local n = 0 for _, a in ipairs(alerts) do if a:find(needle, 1, true) then n = n + 1 end end return n end
-- the claude runs, by the folder they were started in (the checker's tasks are all there is here:
-- no merge.gates is configured)
local function runsIn(dir)
  local out = {}
  for _, t in ipairs(TASKS) do
    if tostring(t.args[3] or ""):find("cd '" .. dir .. "' ", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function files(t)
  return tostring(t.args[3] or ""):match("< '([^']+)' > '([^']+)' 2> '([^']+)'")
end
-- play claude: write its output where the command line sends it, then exit
local function answer(t, verdict, summary, code, errText)
  local _, outFile, errFile = files(t)
  if verdict then
    write(outFile, json.encode({ type = "result", subtype = "success", is_error = false, num_turns = 4, total_cost_usd = 0.11,
      result = "Reviewed.\n" .. json.encode({ verdict = verdict, summary = summary,
        findings = verdict == "fail" and { { file = "app.lua", line = 2, severity = "high", issue = "a stub left in" } } or {} }) }))
  end
  if errText then write(errFile, errText) end
  t.running = false
  quiet(function() t.cb(code or 0, "", "") end)
end

tick()
local A = runsIn("/r/A/.claude/worktrees/alpha")
local B = runsIn("/r/A/.claude/worktrees/beta")
local C = runsIn("/r/C/.claude/worktrees/cee")
check("a merge request starts its checker in the unit's worktree", #A == 1)
local a = A[1] or { args = {} }
check("...through the login shell ($SHELL -l -c)", a.bin == "/bin/zsh" and a.args[1] == "-l" and a.args[2] == "-c")
local cmd = tostring(a.args[3] or "")
check("...headless, read-only, hooks off, no MCP, capped  (" .. cmd:sub(1, 120) .. "…)",
      cmd:find("CC_SHEPHERD_INTERNAL=1 claude -p --model sonnet --output-format json --no-session-persistence", 1, true) ~= nil
      and cmd:find("--settings '{\"disableAllHooks\":true}'", 1, true) ~= nil and cmd:find("--max-budget-usd 1 ", 1, true) ~= nil
      and cmd:find("--strict-mcp-config", 1, true) ~= nil and cmd:find("--permission-mode dontAsk", 1, true) ~= nil
      and not cmd:find("--bare", 1, true))
check("...started in that folder", a.dir == "/r/A/.claude/worktrees/alpha")
local promptFile = files(a)
local prompt = promptFile and read(promptFile) or ""
check("...its prompt names the diff to review", prompt:find("git diff main...aaa111", 1, true) ~= nil)
check("...and the red flags Shepherd found without a model", prompt:find("stub in app.lua", 1, true) ~= nil)
check("one checker per repo: beta waits for alpha's lane", #B == 0)
check("...while another repo's runs at the same time", #C == 1)
local tmo
for _, tm in ipairs(TIMERS) do if tm.secs == 600 then tmo = tm end end
check("every run has a retained timeout timer (600s)", tmo ~= nil)

local I = items()
local ck = I.ua and I.ua.merge and I.ua.merge.checker
check("the review shows the checker at once, red flags first  (" .. tostring(ck and ck.flags and ck.flags[1]) .. ")",
      ck and ck.state == "running" and ck.flags and tostring(ck.flags[1]):find("stub in app.lua", 1, true) ~= nil)
check("the flags are on disk before the model answers", (decoded(MD .. "/ua.checker.json") or {}).state == "running")
check("a delegated merge waits for the checker  (" .. tostring(I.ua.merge.line) .. ")",
      read(MD .. "/ua.decision") == nil and tostring(I.ua.merge.line):find("the checker is reviewing it", 1, true) ~= nil)
check("...and doesn't call Adam while it does", I.ua.merge.needsYou == false)
check("beta's review says its checker is queued", I.ub.merge.checker and I.ub.merge.checker.state == "queued")

-- alpha fails
answer(a, "fail", "Leaves a stub in app.lua")
local va = decoded(MD .. "/ua.checker.json")
check("the verdict lands in <key>.checker.json, keyed by nonce|sha",
      va and va.verdict == "fail" and va.id == "m-ua|aaa111" and va.attempts == 1 and va.state == "done")
check("...with its findings and red flags", va and va.findings and va.findings[1].issue == "a stub left in"
      and va.flags and va.flags[1].kind == "stub")
check("its scratch files are cleaned up", read(promptFile) == nil)
tick()
I = items()
check("a failed check holds the delegated merge", read(MD .. "/ua.decision") == nil)
check("...says why on the card  (" .. tostring(I.ua.merge.line) .. ")",
      I.ua.merge.line == "⇡ ready to merge feat/alpha → main -- the checker failed it, so it waits for your click")
check("...needs Adam", I.ua.merge.needsYou == true)
check("...and tells him once", alerted("checker") >= 1)
B = runsIn("/r/A/.claude/worktrees/beta")
check("alpha's lane freed: beta's checker starts", #B == 1)

-- beta passes -> merges on the grant
answer(B[1], "pass", "Adds beta.")
tick(); tick()
local db = decoded(MD .. "/ub.decision")
check("a pass lets the delegated merge through", db and db.verdict == "merge" and db.nonce == "m-ub")

-- c1 (Adam's own unit) fails, and his click merges it anyway
answer(C[1], "fail", "Looks wrong")
tick()
quiet(function() fx.mergeApprove("c1") end)
local dc = decoded(MD .. "/c1.decision")
check("Adam's own click still merges a unit the checker failed", dc and dc.verdict == "merge" and dc.nonce == "m-c1")

-- gamma: couldn't run -> one retry -> couldn't run again (a timeout) -> waits for Adam
local G = runsIn("/r/G/.claude/worktrees/gamma")
check("gamma's checker runs in its own repo's lane", #G == 1)
answer(G[1], nil, nil, 127, "zsh: command not found: claude\n")
local vg = decoded(MD .. "/ug.checker.json")
check("a run that couldn't start reads couldn't-run, with why  (" .. tostring(vg and vg.why) .. ")",
      vg and vg.verdict == "couldntRun" and tostring(vg.why):find("command not found", 1, true) ~= nil)
tick()
I = items()
check("...no retry straight away", #runsIn("/r/G/.claude/worktrees/gamma") == 1)
check("...and the delegated merge waits for it  (" .. tostring(I.ug.merge.line) .. ")",
      read(MD .. "/ug.decision") == nil and I.ug.merge.needsYou == false)
OFFSET = 61
tick()
G = runsIn("/r/G/.claude/worktrees/gamma")
check("a minute on, couldn't-run gets its one retry", #G == 2)
local tmo2
for _, tm in ipairs(TIMERS) do if tm.secs == 600 and not tm.stopped then tmo2 = tm end end
quiet(function() tmo2.fn() end)
check("a run past its timeout is terminated", G[2].terminated == true)
quiet(function() G[2].cb(15, "", "") end)
vg = decoded(MD .. "/ug.checker.json")
check("...and reads couldn't-run  (" .. tostring(vg and vg.why) .. ")", vg and vg.verdict == "couldntRun" and vg.attempts == 2
      and tostring(vg.why):find("timed out", 1, true) ~= nil)
OFFSET = 200
tick()
I = items()
check("couldn't run twice: no third run", #runsIn("/r/G/.claude/worktrees/gamma") == 2)
check("...and the merge waits for Adam  (" .. tostring(I.ug.merge.line) .. ")", read(MD .. "/ug.decision") == nil
      and I.ug.merge.needsYou == true and tostring(I.ug.merge.line):find("couldn't run twice", 1, true) ~= nil)

-- a reload: the verdict is read back from disk, never re-run
local before = #TASKS
fx._checkers = {}
tick()
I = items()
check("after a reload the verdict comes back from disk", I.ua.merge.checker and I.ua.merge.checker.verdict == "fail")
check("...and isn't run again", #TASKS == before)

-- ---- a reload mid-run is not one of the checker's two attempts (2026-09-30) ----
-- 2026-09-30: a deploy at 15:50 cut feat/ask-send's first run. Its record, left
-- "running", read back as an ordinary couldn't-run with attempt 1 spent, so the re-run was try 2
-- of 2 and its one real failure put the unit on Adam's click. And that failure said only "claude
-- gave no answer": no exit code, and its scratch files were already deleted.
do
  DIFFS["main...abc999"] = DIFFS["main...bbb222"]
  request("rl", "/r/R", "rho", "fix/rho", "abc999", "5006")
  tick()
  local R = runsIn("/r/R/.claude/worktrees/rho")
  check("rho's checker starts", #R == 1 and (decoded(MD .. "/rl.checker.json") or {}).state == "running")
  -- the reload: memory is gone (the task with it); the file still says "running"
  fx._checkers, fx._headless = {}, {}
  tick()
  R = runsIn("/r/R/.claude/worktrees/rho")
  check("a run a reload cut is run again at once", #R == 2)
  local vr = decoded(MD .. "/rl.checker.json") or {}
  check("...as the same attempt, not the second  (attempts=" .. tostring(vr.attempts) .. ")", vr.attempts == 1 and vr.state == "running")
  -- that run really fails: killed, nothing on stdout
  local logged = {}
  local rerun = R[2] or R[1]   -- (without the fix there is no second run: the first plays its part)
  do
    local _, _, errFile = files(rerun)
    write(errFile, "Terminated: 15\n")
    rerun.running = false
    print = function(...) local p = {} for _, v in ipairs({ ... }) do p[#p + 1] = tostring(v) end logged[#logged + 1] = table.concat(p, " ") end
    pcall(function() rerun.cb(143, "", "") end)
    print = realPrint
  end
  vr = decoded(MD .. "/rl.checker.json") or {}
  check("a run that gave no answer says claude's exit code  (" .. tostring(vr.why) .. ")",
        vr.verdict == "couldntRun" and tostring(vr.why):find("exit 143", 1, true) ~= nil)
  check("...and keeps what it printed on its record", type(vr.kept) == "table" and vr.kept.code == 143
        and tostring(vr.kept.err):find("Terminated: 15", 1, true) ~= nil)
  local line
  for _, l in ipairs(logged) do if l:find("couldn't run", 1, true) and l:find("fix/rho", 1, true) then line = l end end
  check("...and logs both  (" .. tostring(line) .. ")", line ~= nil and line:find("[cc-dashboard]", 1, true) ~= nil
        and line:find("exit 143", 1, true) ~= nil and line:find("stderr 15 bytes", 1, true) ~= nil)
  OFFSET = OFFSET + 61
  tick()
  R = runsIn("/r/R/.claude/worktrees/rho")
  check("its one real retry still happens (the reload didn't spend it)", #R == 3
        and (decoded(MD .. "/rl.checker.json") or {}).attempts == 2)
  if R[3] then answer(R[3], "pass", "Adds rho.") end
  vr = decoded(MD .. "/rl.checker.json") or {}
  check("...and its verdict counts", vr.verdict == "pass" and vr.kept == nil)
  os.remove(MD .. "/rl.json"); os.remove(MD .. "/rl.checker.json"); os.remove(T .. "/status/rl.json")
end

-- Verify on a session with no merge request
quiet(function() fx.verifySession("v1") end)
local V = runsIn("/r/V")
check("Verify reviews a session with no merge request, in its checkout", #V == 1)
local vp = read(files(V[1]) or "") or ""
check("...against where it left main, uncommitted work included", vp:find("git diff fff000", 1, true) ~= nil)
answer(V[1], "pass", "Fine.")
tick()
I = items()
check("...and its verdict shows on the session  (" .. tostring(I.v1 and I.v1.checker and I.v1.checker.verdict) .. ")",
      I.v1 and I.v1.checker and I.v1.checker.verdict == "pass" and I.v1.checker.trigger == "verify")
check("never a keystroke", taps == 0)

-- verify.onMerge off: no checker, and delegated merges go through as before
write(T .. "/.claude/cc-config.json", json.encode({ verify = { onMerge = false } }))
fx._checkers = {}
os.remove(MD .. "/ua.checker.json")
-- beta's merge has finished (its request is gone), so repo A's one merge lane is free for alpha
os.remove(MD .. "/ub.json"); os.remove(MD .. "/ub.decision")
before = #TASKS
tick(); tick()
check("with verify.onMerge off nothing starts", #TASKS == before)
check("...and the held unit merges on the grant as it did before the checker", (decoded(MD .. "/ua.decision") or {}).verdict == "merge")

os.execute('rm -rf "' .. T .. '"')
finish()
