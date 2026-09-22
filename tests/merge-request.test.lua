-- merge-request.test.lua : BEHAVIORAL fixture for Shepherd's side of the ready-to-merge flow
-- (2026-09-11). Loads the real claude-dashboard.lua under a stubbed hs whose git answers
-- are canned, with merge requests on disk the way cc-merge.sh writes them, then drives
-- the real effects: the card line and one alert per request, Merge writing a decision
-- bound to the request's nonce, one merge per repo at a time in click order, Not yet with
-- a note, a request that isn't ready refused, and never a keystroke.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- merge-request.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MD = T .. "/.claude/cc-merge"
os.execute('mkdir -p "' .. T .. '/status" "' .. MD .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- five sessions: a1 + a2 in repo A, b1 in repo B, c1 in repo C, d1 in repo D (dirty)
local S = {
  { "a1", "/r/A", "fix/a1" }, { "a2", "/r/A", "fix/a2" }, { "b1", "/r/B", "fix/b1" },
  { "c1", "/r/C", "fix/c1" }, { "d1", "/r/D", "fix/d1" },
}
local FACTS = {}
local VERIFY_OUT = "@@in\n@@list\nworktree /r/A\nHEAD a\nbranch refs/heads/main\n"   -- the merged worktree is gone
for i, s in ipairs(S) do
  local key, repo, branch = s[1], s[2], s[3]
  local wt = repo .. "/.claude/worktrees/" .. key
  write(T .. "/status/" .. key .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%d","session_pid":"%d","transcript_path":"%s"}',
    key, key, wt, now - 60, now - 60, 700 + i, 900 + i, T .. "/" .. key .. ".jsonl"))
  -- 2026-09-14 requirement change: only a tab opened for the job closes after its merge, so these
  -- sessions are New worktree tabs -- their first prompt is Shepherd's "Start unit …" prompt.
  write(T .. "/" .. key .. ".jsonl", '{"type":"user","message":{"role":"user","content":"Start unit ' .. branch
    .. ' in its own worktree: call EnterWorktree with name \\"' .. key .. '\\", then rename its branch."}}\n'
    .. '{"type":"ai-title","aiTitle":"Fix ' .. key .. ' tab","sessionId":"' .. key .. '"}\n')
  write(MD .. "/" .. key .. ".json", json.encode({ v = 1, key = key, session_id = key, pid = tostring(900 + i),
    nonce = "n-" .. key, worktree = wt, branch = branch, base = "main", commonDir = repo .. "/.git",
    summary = "Unit " .. key .. " <b>bold</b>", tests = "make test: green", ahead = 1, at = now, phase = "requested" }))
  FACTS[wt] = table.concat({ "@@listed", "worktree " .. repo, "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD b", "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@status", (key == "d1") and " M app.lua" or "", "@@ahead", "1", "@@behind", "0",
    "@@commits", "abc1234\t" .. key .. " change", "@@stat", " 1 file changed, 1 insertion(+)", "@@files", "M\tapp.lua", "" }, "\n")
end
-- a request whose session isn't on the panel at all
write(MD .. "/zz.json", json.encode({ v = 1, key = "zz", session_id = "zz", pid = "1", nonce = "n-zz",
  worktree = "/r/A/.claude/worktrees/zz", branch = "fix/zz", base = "main", commonDir = "/r/A/.git", phase = "approved", at = now, approvedAt = now }))
write(T .. "/.panel-alive", tostring(now))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, focusCalls, alerts, js = 0, 0, {}, {}
local function webviewHandle()
  -- 2026-09-11: messages are ccToast calls into the panel (FX.alert), not hs.alert overlays
  return setmetatable({ evaluateJavaScript = function(_, s)
      js[#js + 1] = s
      local m = tostring(s or ""):match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local EXISTS = {}   -- fake absolute paths hs.fs.attributes should report as real directories
local DEAD = {}     -- pid (string) -> true: a process the fake ps must report as gone
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path)
      -- EXISTS names the few fake paths a test needs git/Shepherd to believe in (a batch's repo
      -- root: an absent one makes the batch "finished -- its repo is gone" before it can merge).
      if EXISTS[tostring(path)] then return { mode = "directory" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    -- 2026-09-17: the liveness probe behind the needs-you rule. Every pid is alive unless a
    -- test says otherwise (DEAD[pid] = true), so the checks written before this existed are
    -- unaffected -- exactly what a real machine reports for sessions that are still running.
    if cmd:find("ps -o pid=", 1, true) then
      local out = {}
      for d in (cmd:match("%-p ([%d,]+)") or ""):gmatch("%d+") do
        if not DEAD[d] then out[#out + 1] = "  " .. d end
      end
      return table.concat(out, "\n") .. "\n"
    end
    if cmd:find("@@listed", 1, true) then return FACTS[cmd:match("%-C '([^']+)'") or ""] or "" end
    if cmd:find("merge-base --is-ancestor", 1, true) then return VERIFY_OUT end
    if cmd:find("diff --no-color", 1, true) then return "diff --git a/app.txt b/app.txt\n+<script>x</script>\n" end
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
rawset(hs.window, "focusedWindow", function() focusCalls = focusCalls + 1; return nil end)
-- 2026-09-17 (test gate): hs.task here was the generic mkstub, which swallows a launch whole --
-- a task-based gate would have silently no-op'd and every run would have looked green. Tasks are
-- recorders now: each keeps the argv it was launched with, its working directory and its exit
-- callback, and the test fires that callback itself. Same for the backstop timers.
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
-- The liveness probe sends Shepherd's OWN pid along as a control: a ps that can't see us isn't
-- one to trust, and every answer is then "unknown" (= assume alive). Give the stub a real one
-- so the probe is actually exercised here instead of degrading to unknown.
hs.processInfo = { processID = 10000, bundleID = "org.hammerspoon.Hammerspoon" }
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
local function items() local t = {} for _, it in ipairs(fx._shownItems or {}) do t[it.key] = it end return t end
local function tick() return quiet(function() fx._refreshBody() end) end
local function alerted(needle) local n = 0 for _, a in ipairs(alerts) do if a:find(needle, 1, true) then n = n + 1 end end return n end
local function decision(key) local s = read(MD .. "/" .. key .. ".decision"); return s and json.decode(s) or nil end
local function setPhase(key, phase, extra)
  local r = json.decode(read(MD .. "/" .. key .. ".json"))
  r.phase = phase
  for k, v in pairs(extra or {}) do r[k] = v end
  write(MD .. "/" .. key .. ".json", json.encode(r))
end

local I = items()
check("every session is on the panel", I.a1 and I.a2 and I.b1 and I.c1 and I.d1)
if not (I.a1 and I.d1) then finish() end
check("a request Shepherd finds ready shows on its card  (" .. tostring(I.a1.merge and I.a1.merge.line) .. ")",
      I.a1.merge and I.a1.merge.line == "⇡ ready to merge fix/a1 → main")
check("...and wants Adam", I.a1.merge.needsYou == true)
check("...with the review: commits, files, the session's summary", I.a1.merge.commits and I.a1.merge.commits[1].h == "abc1234"
      and I.a1.merge.files[1].path == "app.lua" and I.a1.merge.summary:find("Unit a1", 1, true))
check("...and never the nonce, session id or pid", I.a1.merge.nonce == nil and I.a1.merge.session_id == nil and I.a1.merge.pid == nil)
check("a dirty worktree's request says why it isn't ready  (" .. tostring(I.d1.merge and I.d1.merge.line) .. ")",
      I.d1.merge and I.d1.merge.line:find("uncommitted", 1, true) ~= nil and I.d1.merge.ready == false)
check("one alert per request", alerted("ready to merge fix/a1") == 1)
tick()
check("...not one per tick", alerted("ready to merge fix/a1") == 1)
check("a request whose session isn't on the panel is ignored", fx._mergeReqs.zz == nil)

-- Merge: the decision carries the request's nonce
quiet(function() fx.mergeApprove("a1") end)
local d = decision("a1")
check("Merge writes the decision for that request  (" .. tostring(d and d.nonce) .. ")", d and d.nonce == "n-a1" and d.verdict == "merge")
check("...and says it's merging", alerted("Merging fix/a1") == 1)
quiet(function() fx.mergeApprove("a2") end)
check("a second Merge in the same repo waits its turn (no decision yet)", decision("a2") == nil and alerted("fix/a2 is queued") == 1)
quiet(function() fx.mergeApprove("b1") end)
check("a Merge in another repo starts at once", decision("b1") and decision("b1").nonce == "n-b1")
tick()
I = items()
check("the queued card says so  (" .. tostring(I.a2.merge.line) .. ")", I.a2.merge.line == "⇡ queued to merge fix/a2 (next in line)")
check("...and no longer wants Adam", I.a2.merge.needsYou == false)
check("the started one says so  (" .. tostring(I.a1.merge.line) .. ")", I.a1.merge.line == "⇡ merge approved: fix/a1 is starting")

-- the script claims a1 and merges; a2 waits until a1 is done
os.remove(MD .. "/a1.decision")
setPhase("a1", "approved", { approvedAt = os.time() })
tick()
check("while a1 merges, a2 still waits", decision("a2") == nil)
setPhase("a1", "merged", { sha = "abc1234def" })
tick()
check("a1 merged -> a2 starts, on its own nonce", decision("a2") and decision("a2").nonce == "n-a2")
I = items()
-- (no tab bridge in a1's window yet, so the card also says to close the tab by hand)
check("a1's card says merged  (" .. tostring(I.a1.merge.line) .. ")", I.a1.merge.line:sub(1, #"✓ merged fix/a1 into main") == "✓ merged fix/a1 into main")
check("...and, with no tab bridge in its window, to close the tab by hand", I.a1.merge.line:find("isn't running", 1, true) ~= nil)

-- ---- after a verified merge, the tab bridge closes that session's tab (2026-09-11) ----
local BR = T .. "/.claude/cc-bridge"
local function registry(host, labels)
  os.execute('mkdir -p "' .. BR .. '/' .. host .. '.in" "' .. BR .. '/' .. host .. '.out"')
  local tabs = {}
  for _, l in ipairs(labels) do tabs[#tabs + 1] = { label = l, group = 1, active = false } end
  write(BR .. "/" .. host .. ".json", json.encode({ v = 1, pid = host, version = "0.1.0", tabs = tabs, at = os.time() }))
end
local function inbox(host)
  local out, p = {}, io.popen('ls -1 "' .. BR .. '/' .. host .. '.in" 2>/dev/null')
  if p then for l in p:lines() do out[#out + 1] = l end; p:close() end
  return out
end
registry(701, { "Fix a1 tab", "Fix a2 tab" })
registry(703, { "Fix b1 tab" })
setPhase("a1", "merged", { sha = "abc1234def" })
tick()
local sent = inbox(701)
local cmd = sent[1] and json.decode(read(BR .. "/701.in/" .. sent[1])) or {}
check("a verified merge whose session finished its turn: the bridge is asked to close its tab  (" .. tostring(cmd.label) .. ")",
      #sent == 1 and cmd.op == "close" and cmd.label == "Fix a1 tab")
tick()
check("...once, not every tick", #inbox(701) == 1)
write(BR .. "/701.out/" .. tostring(cmd.id) .. ".json", json.encode({ v = 1, id = cmd.id, ok = true }))
quiet(function() fx.tabBridgePollResults() end)
check("once the tab is closed, the card and its merge request go", read(T .. "/status/a1.json") == nil and read(MD .. "/a1.json") == nil)

-- merged, but Shepherd's git still sees the worktree: no close, the card says why
VERIFY_OUT = VERIFY_OUT .. "\nworktree /r/B/.claude/worktrees/b1\nHEAD b\nbranch refs/heads/fix/b1\n"
os.remove(MD .. "/b1.decision")
setPhase("b1", "merged", { sha = "abc1234def" })
tick()
I = items()
check("a merge Shepherd can't verify never closes the tab", #inbox(703) == 0)
check("...and the card says to close it by hand, and why  (" .. tostring(I.b1 and I.b1.merge and I.b1.merge.line) .. ")",
      I.b1 and I.b1.merge and I.b1.merge.line:find("still there", 1, true) ~= nil)
-- 2026-09-15 live: a merged unit's tab Shepherd couldn't close turned its card red "Needs you",
-- ahead of the working driver and units -- but a tab left open is housekeeping, not a wait on Adam.
check("...quietly: a merged unit's leftover tab doesn't make its card Needs you", I.b1 and I.b1.merge and I.b1.merge.needsYou == false)
-- 2026-09-22: ...and it offers no Close tab button either -- close was never tried here, and
-- pressing it would defeat the very verification that is holding the tab open.
check("...and no Close tab button, which would defeat the verification guard",
      I.b1 and I.b1.merge and I.b1.merge.canCloseTab == nil)

-- 2026-09-14 live: Adam's main Chargeback Sentinel chat did a unit itself in a worktree, merged, and
-- Shepherd closed its tab -- the very chat he was working in. Only a tab opened for the job closes.
write(T .. "/m1.jsonl", '{"type":"user","message":{"role":"user","content":"review the following and work on a plan to have this be the way by which we operate writes"}}\n'
  .. '{"type":"ai-title","aiTitle":"Flexible Chargeback Payloads migration plan","sessionId":"m1"}\n')
write(T .. "/status/m1.json", string.format(
  '{"status":"done","session_id":"m1","name":"ChargebackSentinel","cwd":"/r/M","since":%d,"updated":%d,"editor":"vscode","host_window":"790","session_pid":"990","transcript_path":"%s"}',
  now - 60, now - 60, T .. "/m1.jsonl"))
registry(790, { "Flexible Chargeback Payl…" })
write(MD .. "/m1.json", json.encode({ v = 1, key = "m1", session_id = "m1", pid = "990", nonce = "n-m1",
  worktree = "/r/M/.claude/worktrees/reconcile", branch = "fix/reconcile-upload-atomic", base = "master", commonDir = "/r/M/.git",
  summary = "atomic upload", tests = "deno task test: green", ahead = 1, at = now, phase = "merged", sha = "abc1234def" }))
alerts = {}
tick(); tick()
check("a main chat that did the unit itself is never closed after its merge", #inbox(790) == 0)
check("...its finished request is cleared, so no red card is left with nothing to press", read(MD .. "/m1.json") == nil)
check("...and a toast says its chat stays open  (" .. table.concat(alerts, " | ") .. ")",
      table.concat(alerts, " "):find("stays open", 1, true) ~= nil)
check("...and its card stays", read(T .. "/status/m1.json") ~= nil)

-- Not yet, with a note
quiet(function() fx.mergeHold("c1", "rename the helper first") end)
d = decision("c1")
check("Not yet sends the note, bound to the request", d and d.verdict == "hold" and d.note == "rename the helper first" and d.nonce == "n-c1")

-- not ready: refused, nothing written
quiet(function() fx.mergeApprove("d1") end)
check("Merge on a request that isn't ready is refused, nothing written", decision("d1") == nil and alerted("Can't merge fix/d1 yet") == 1)

-- the full diff goes to the panel as data
js = {}
quiet(function() fx.mergeDiff("b1") end)
local pushed = table.concat(js, "\n")
check("Full diff pushes the diff to the panel as JSON data", pushed:find("window.ccMergeDiff(", 1, true) ~= nil and pushed:find("diff --git", 1, true) ~= nil)

-- 2026-09-11 live: a finished merge ("merged -- close its tab yourself") turned the card red with
-- nothing to press. A finished card has Dismiss (and Close tab); a live request can't be dismissed.
quiet(function() fx.mergeDismiss("d1") end)
check("Dismiss never clears a request still waiting for Merge", read(MD .. "/d1.json") ~= nil)
local d1 = json.decode(read(MD .. "/d1.json"))
d1.phase, d1.note = "blocked", "tests disagree"
write(MD .. "/d1.json", json.encode(d1))
tick()
local dI = nil
for _, it in ipairs(fx._shownItems or {}) do if it.key == "d1" then dI = it end end
check("...(it does: blocked)", dI and dI.merge and dI.merge.needsYou == true)
quiet(function() fx.mergeDismiss("d1") end)
check("Dismiss clears a finished request", read(MD .. "/d1.json") == nil)
tick()
dI = nil
for _, it in ipairs(fx._shownItems or {}) do if it.key == "d1" then dI = it end end
check("...and the card stops needing Adam", dI and dI.merge == nil)

-- closing a session drops its merge files
quiet(function() fx.removeStatus("c1") end)
check("removing a session drops its merge request and decision", read(MD .. "/c1.json") == nil and read(MD .. "/c1.decision") == nil)

-- ---- Shepherd runs the project's test gate itself before the review (2026-09-17) ------------
-- The one part of the review Shepherd took on trust was the session's --tests string. With a
-- merge.gates entry for the project, Shepherd runs the project's own suite in the worktree and
-- the verdict is its own: a red or still-running gate blocks Adam's Merge AND a batch unit's
-- delegated merge, and the same suite runs in the main checkout before the unit's tab closes.
local FD = T .. "/.claude/cc-fleet"
os.execute('mkdir -p "' .. FD .. '"')
write(T .. "/.claude/cc-config.json", json.encode({ merge = { gates = {
  { match = { project = "/r/G/*" }, command = "GATE-G", timeoutSeconds = 5 },
  { match = { project = "/r/K/*" }, command = "GATE-K" },
  { match = { project = "/r/S/*" }, command = "GATE-S" },
} } }))

local function gateTasks(needle)
  local out = {}
  for _, t in ipairs(TASKS) do
    if type(t.args[3]) == "string" and t.args[3]:find(needle, 1, true) then out[#out + 1] = t end
  end
  return out
end
local function gateLog(t) return t.args[3]:match("> '([^']+)' 2>&1") end
local function endGate(t, code, text)
  local f = gateLog(t)
  os.execute('mkdir -p "' .. (f:match("^(.*)/[^/]+$") or ".") .. '"')
  write(f, text or "")
  quiet(function() t.cb(code, "", "") end)
end
local function setFacts(wt, repo, branch, sha)
  FACTS[wt] = table.concat({ "@@listed", "worktree " .. repo, "HEAD a", "branch refs/heads/main", "",
    "worktree " .. wt, "HEAD b", "branch refs/heads/" .. branch, "",
    "@@head", branch, "@@sha", sha, "@@status", "", "@@ahead", "1", "@@behind", "0",
    "@@commits", "abc1234\tthe unit's change", "@@stat", " 1 file changed", "@@files", "M\tapp.lua", "" }, "\n")
end
local function newUnit(key, repo, branch, sha, host, pid)
  local wt = repo .. "/.claude/worktrees/" .. key
  write(T .. "/" .. key .. ".jsonl", '{"type":"user","message":{"role":"user","content":"Start unit ' .. branch
    .. ' in its own worktree: call EnterWorktree with name \\"' .. key .. '\\", then rename its branch."}}\n')
  write(T .. "/status/" .. key .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%d","session_pid":"%d","transcript_path":"%s"}',
    key, key, wt, now - 60, now - 60, host, pid, T .. "/" .. key .. ".jsonl"))
  write(MD .. "/" .. key .. ".json", json.encode({ v = 1, key = key, session_id = key, pid = tostring(pid),
    nonce = "n-" .. key, worktree = wt, branch = branch, base = "main", commonDir = repo .. "/.git",
    summary = "unit " .. key, tests = "make test: all green, honest", ahead = 1, at = now, phase = "requested" }))
  setFacts(wt, repo, branch, sha)
  return wt
end

-- an ungated project is untouched: no gate runs, and the request is ready at once
local hWt = newUnit("h1", "/r/H", "fix/h1", "aaa000", 791, 991)
alerts = {}
tick()
I = items()
check("a project with no merge.gates entry runs nothing and is ready as before  (" .. tostring(I.h1 and I.h1.merge and I.h1.merge.line) .. ")",
      I.h1 and I.h1.merge and I.h1.merge.ready == true and I.h1.merge.gate == nil)
check("...no task was launched for it", #gateTasks("GATE-") == 0)
check("...and its request can be merged straight away", (function()
  quiet(function() fx.mergeApprove("h1") end); return decision("h1") ~= nil end)())
os.remove(MD .. "/h1.json"); os.remove(MD .. "/h1.decision"); os.remove(T .. "/status/h1.json")
local _ = hWt

-- a gated project: the suite runs in the worktree, and the request waits for its verdict
local gWt = newUnit("g1", "/r/G", "fix/g1", "aaa111", 792, 992)
tick()
local gt = gateTasks("GATE-G")[1]
check("a gated project's merge request runs the project's own suite  (" .. tostring(gt and gt.args[3]) .. ")", gt ~= nil)
if not gt then finish() end
check("...in the unit's worktree", gt.dir == gWt)
check("...through the login shell, so the suite finds Adam's PATH", gt.args[1] == "-l" and gt.args[2] == "-c")
check("...with stdout and stderr redirected to a file, never read from a pipe",
      gt.args[3]:find("2>&1", 1, true) ~= nil and gateLog(gt) ~= nil)
I = items()
check("while the gate runs the request is checking, never ready  (" .. tostring(I.g1.merge.line) .. ")",
      I.g1.merge.ready == false and I.g1.merge.checking == true)
quiet(function() fx.mergeApprove("g1") end)
check("Merge is refused while the gate is still running", decision("g1") == nil)
tick(); tick()
check("the gate runs ONCE per request, not once per tick", #gateTasks("GATE-G") == 1)

-- the backstop terminates a gate that never finishes
local backstop
for _, t in ipairs(TIMERS) do if t.secs == 5 and not t.stopped then backstop = t end end
check("the gate's timeout is armed as a retained backstop timer", backstop ~= nil)
quiet(function() backstop.fn() end)
check("...and it terminates the wedged suite", gt.terminated == true)
endGate(gt, 143, "make: *** [test] Terminated\n")
tick()
I = items()
check("a gate that timed out blocks the merge  (" .. tostring(I.g1.merge.line) .. ")",
      I.g1.merge.ready == false and I.g1.merge.line:find("timed out", 1, true) ~= nil)
check("...and the review says which command  (" .. tostring(I.g1.merge.gate and I.g1.merge.gate.state) .. ")",
      I.g1.merge.gate.state == "timedOut" and I.g1.merge.gate.command == "GATE-G")

-- a new commit in the worktree is a new gate key: the suite runs again
setFacts(gWt, "/r/G", "fix/g1", "bbb222")
quiet(function() fx.mergeFacts(fx._mergeReqs.g1, true) end)
tick()
check("a new HEAD sha re-runs the gate", #gateTasks("GATE-G") == 2)
local gt2 = gateTasks("GATE-G")[2]
local log = {}
for i = 1, 30 do log[#log + 1] = "suite line " .. i end
log[#log + 1] = "FAILED 2 of 40 tests"
endGate(gt2, 2, table.concat(log, "\n"))
tick()
I = items()
check("a red gate blocks the merge and says so on the card  (" .. tostring(I.g1.merge.line) .. ")",
      I.g1.merge.ready == false and I.g1.merge.line:find("test gate failed", 1, true) ~= nil
      and I.g1.merge.line:find("GATE-G", 1, true) ~= nil)
check("...with the tail of the suite's own output in the review",
      I.g1.merge.gate.state == "failed" and I.g1.merge.gate.code == 2
      and I.g1.merge.gate.tail:find("FAILED 2 of 40 tests", 1, true) ~= nil
      and I.g1.merge.gate.tail:find("suite line 1\n", 1, true) == nil)
check("...and the session's own test claim is still carried, as a claim", I.g1.merge.tests:find("honest", 1, true) ~= nil)
alerts = {}
quiet(function() fx.mergeApprove("g1") end)
check("Merge on a red gate is refused, nothing written", decision("g1") == nil and alerted("Can't merge fix/g1 yet") == 1)

-- the fix lands: a third sha, and this time the suite is green
setFacts(gWt, "/r/G", "fix/g1", "ccc333")
quiet(function() fx.mergeFacts(fx._mergeReqs.g1, true) end)
tick()
endGate(gateTasks("GATE-G")[3], 0, "40 passed\n")
tick()
I = items()
check("a green gate lets the request through  (" .. tostring(I.g1.merge.line) .. ")",
      I.g1.merge.ready == true and I.g1.merge.line == "⇡ ready to merge fix/g1 → main")
check("...and the review says Shepherd ran it", I.g1.merge.gate.state == "passed")
quiet(function() fx.mergeApprove("g1") end)
check("...so Merge goes through", decision("g1") and decision("g1").nonce == "n-g1")

-- a batch unit's DELEGATED merge is gated exactly the same way
EXISTS["/r/K"] = true
local kWt = newUnit("k1", "/r/K", "fix/k1", "ddd444", 793, 993)
write(FD .. "/bk1.json", json.encode({ v = 1, id = "bk1", nonce = "n-bk1", phase = "approved",
  repo = "/r/K", commonDir = "/r/K/.git", driver = { session_id = "kdrv", pid = "994", name = "driver" },
  title = "gated batch", mergeWhenGreen = true, at = now,
  units = { { type = "fix", slug = "k1", branch = "fix/k1", task = "do the unit" } } }))
write(FD .. "/bk1.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = now },
  units = { k1 = { session = { id = "k1" } } } }))
tick()
local kt = gateTasks("GATE-K")[1]
check("a batch unit's request runs its project's gate too", kt ~= nil and kt.dir == kWt)
check("...and while it runs the batch grant does NOT merge it", decision("k1") == nil)
endGate(kt, 1, "1 failing spec\n")
tick()
check("a red gate blocks the delegated merge on Adam's batch grant", decision("k1") == nil)
I = items()
check("...and the unit's card says the gate failed  (" .. tostring(I.k1.merge.line) .. ")",
      I.k1.merge.line:find("test gate failed", 1, true) ~= nil)
setFacts(kWt, "/r/K", "fix/k1", "eee555")
quiet(function() fx.mergeFacts(fx._mergeReqs.k1, true) end)
tick()
endGate(gateTasks("GATE-K")[2], 0, "all green\n")
tick()
check("once the gate is green the batch grant merges the unit", decision("k1") and decision("k1").nonce == "n-k1")

-- after the merge the same suite runs in the MAIN checkout, before the tab closes
os.remove(MD .. "/g1.decision")
registry(792, { "Fix g1 tab" })
setPhase("g1", "merged", { sha = "abc1234def" })
alerts = {}
tick()
local post = gateTasks("GATE-G")[4]
check("a merged unit runs the gate once more, in the main checkout", post ~= nil and post.dir == "/r/G")
check("...and its tab is not closed while that runs", #inbox(792) == 0)
I = items()
check("...nor offered as a button, which would bypass the gate outright (2026-09-22)",
      I.g1.merge.canCloseTab == nil)
endGate(post, 2, "make test: 1 failed on main\n")
tick()
I = items()
check("main red after the merge: the tab stays open", #inbox(792) == 0)
check("...the card says so  (" .. tostring(I.g1.merge.line) .. ")",
      I.g1.merge.line:find("is red after the merge", 1, true) ~= nil)
check("...it wants Adam, unlike a merely un-closed tab", I.g1.merge.needsYou == true)
check("...and its own note says the tab stays open, so no button offers to close it anyway",
      I.g1.merge.canCloseTab == nil)
check("...and Shepherd said so once, in the panel  (" .. table.concat(alerts, " | ") .. ")",
      alerted("is red after the merge") == 1)

-- ---- The gate never runs retroactively, never twice in one checkout (2026-09-17) ----------
-- Adam configured merge.gates at 15:58; two units that had merged HOURS earlier each got a
-- post-merge gate started right then, in the same main checkout, at the same moment. They ran
-- `make lint && make test` concurrently there -- install.test.sh shells out to the real make
-- in that checkout -- so they killed each other and both said `exited 2`
-- about a main that was green. Two cards then pulsed red "Needs you" for hours, on merges
-- hours old, where the only affordance was Dismiss.
local core = dash.core
local mWt = newUnit("m1", "/r/G", "fix/m1", "fff666", 794, 994)
local _ = mWt
setPhase("m1", "merged", { sha = "fff666" })
local beforeG = #gateTasks("GATE-G")
alerts = {}
tick(); tick()
check("a merge whose own pre-merge gate never ran here is NOT gated retroactively",
      #gateTasks("GATE-G") == beforeG)
I = items()
check("...and its card never claims main is red over a gate that never ran  ("
      .. tostring(I.m1 and I.m1.merge and I.m1.merge.line) .. ")",
      I.m1 and I.m1.merge and (I.m1.merge.line or ""):find("is red after the merge", 1, true) == nil)
check("...so it isn't ranked as needing Adam", I.m1.needsYou ~= "needs")

-- one gate per repo at a time, pre- and post-merge sharing the lane
local s1Wt = newUnit("s1", "/r/S", "fix/s1", "111aaa", 795, 995)
local s2Wt = newUnit("s2", "/r/S", "fix/s2", "222bbb", 796, 996)
local __ = s1Wt; local ___ = s2Wt
tick()
check("two units in ONE repo start one gate, not two  (" .. #gateTasks("GATE-S") .. ")",
      #gateTasks("GATE-S") == 1)
I = items()
local states = { I.s1.merge.gate and I.s1.merge.gate.state, I.s2.merge.gate and I.s2.merge.gate.state }
table.sort(states)
check("...one runs while the other queues  (" .. table.concat(states, "+") .. ")",
      states[1] == "queued" and states[2] == "running")
check("...and the queued one reads as still checking, NEVER as ready-with-no-gate",
      I.s1.merge.ready == false and I.s1.merge.checking == true
      and I.s2.merge.ready == false and I.s2.merge.checking == true)
-- 2026-09-22: ...and the card says WHICH of the two checking states it is. Collapsing them made
-- the waiting card claim "checking", needsYouKind say "the test gate is still running" (it had
-- not started), and the review say "queued behind another run in this repo" -- three stories.
do
  local sRun  = (I.s1.merge.gate.state == "running") and I.s1 or I.s2
  local sWait = (I.s1.merge.gate.state == "queued") and I.s1 or I.s2
  check("the RUNNING gate's card still reads 'checking', word for word  ("
        .. tostring(sRun.merge.line) .. ")",
        sRun.merge.line == "⇡ merge request: checking " .. sRun.merge.branch
        and sRun.merge.gateQueued == nil)
  check("...while the one waiting for the lane says it hasn't started  ("
        .. tostring(sWait.merge.line) .. ")",
        sWait.merge.gateQueued == true
        and sWait.merge.line:find("queued behind another run in this repo", 1, true) ~= nil)
  check("...and names its place in that repo's one lane", sWait.merge.line:find("#1 in line", 1, true) ~= nil)
  check("...so the card now says what the review beside it says", sWait.merge.gate.state == "queued")
  check("...a queued GATE is never read as a place in the APPROVAL queue", sWait.merge.queued == nil)
  check("...neither is ready: a gate that never ran proves nothing",
        sRun.merge.ready == false and sWait.merge.ready == false)
  check("...and the waiting card's reason says it is waiting, not that it is running  ("
        .. tostring(sWait.needsYouWhy) .. ")",
        sRun.needsYou == "fyi" and sWait.needsYou == "fyi"
        and (sWait.needsYouWhy or ""):find("queued behind another run", 1, true) ~= nil
        and (sWait.needsYouWhy or ""):find("still running", 1, true) == nil)
end
tick(); tick()
check("...and it stays one gate however many ticks pass", #gateTasks("GATE-S") == 1)
endGate(gateTasks("GATE-S")[1], 0, "ok - all good\n-- suite: 12 run, 0 failed --\n")
tick()
check("the queued gate starts as soon as the lane is free", #gateTasks("GATE-S") == 2)

-- COULDN'T-RUN is not FAILED: the suite refusing to start says nothing about the code
endGate(gateTasks("GATE-S")[2], 2,
        "make: *** [test] Error " .. core.TEST_LOCK_EXIT .. "\n" .. core.TEST_LOCK_TOKEN .. "\n")
tick()
I = items()
local norun = (I.s1.merge.gate.state == "couldntRun") and I.s1 or I.s2
check("a gate that couldn't run is told apart from one that failed  ("
      .. tostring(norun.merge.gate.state) .. ")", norun.merge.gate.state == "couldntRun")
check("...the card says it couldn't run, not that the tests failed  ("
      .. tostring(norun.merge.line) .. ")",
      (norun.merge.line or ""):find("couldn't run", 1, true) ~= nil
      and (norun.merge.line or ""):find("failed", 1, true) == nil)
check("...and the request is still not ready (it was never proven green)", norun.merge.ready == false)

-- ...and it must not let a delegated batch merge through either
EXISTS["/r/S"] = true
write(FD .. "/bs1.json", json.encode({ v = 1, id = "bs1", nonce = "n-bs1", phase = "approved",
  repo = "/r/S", commonDir = "/r/S/.git", driver = { session_id = "sdrv", pid = "997", name = "driver" },
  title = "serialised batch", mergeWhenGreen = true, at = now,
  units = { { type = "fix", slug = norun.key, branch = norun.merge.branch, task = "do the unit" } } }))
write(FD .. "/bs1.state.json", json.encode({ grant = { approved = true, grantMerge = true, at = now },
  units = { [norun.key] = { session = { id = norun.key } } } }))
tick()
check("a gate that couldn't run never auto-approves a delegated batch merge",
      decision(norun.key) == nil)

-- ...and it is retried, so Adam's own hand-run of the same suite can't wedge the request
do
  local before = #gateTasks("GATE-S")
  tick()
  check("a couldn't-run gate is not retried straight away", #gateTasks("GATE-S") == before)
  for _, slot in ipairs({ fx._mergeGates, fx._mergeGatesPost }) do
    for _, g in pairs(slot) do
      if g.state == "couldntRun" then g.doneAt = os.time() - core.GATE_RETRY_AFTER - 1 end
    end
  end
  tick()
  check("...but it is once the grace has passed", #gateTasks("GATE-S") == before + 1)
  endGate(gateTasks("GATE-S")[before + 1], 0, "ok - all green\n")
  tick()
  I = items()
  check("...and a green retry lets the request through", (I.s1.merge.ready or I.s2.merge.ready) == true)
end

-- ...and the same collapse one line away: a POST-merge gate waiting for the repo's one lane
-- told the merged unit's card it was "running make test on main first" (2026-09-22).
do
  local t1Wt = newUnit("t1", "/r/S", "fix/t1", "aa1111", 801, 1001)
  local _t1 = t1Wt
  tick()   -- t1's gate takes the lane
  local t2Wt = newUnit("t2", "/r/S", "fix/t2", "bb2222", 802, 1002)
  local _t2 = t2Wt
  tick()   -- t2's own pre-merge gate queues behind it (so its post-merge gate is due later)
  registry(802, { "Fix t2 tab" })
  setPhase("t2", "merged", { sha = "bb2222" })
  tick()
  I = items()
  check("a post-merge gate queued behind another run says so, never 'running ... first'  ("
        .. tostring(I.t2.merge.line) .. ")",
        (I.t2.merge.line or ""):find("queued behind another run in this repo", 1, true) ~= nil
        and (I.t2.merge.line or ""):find("running GATE-S", 1, true) == nil)
  check("...and the unit's tab is not closed while it waits", #inbox(802) == 0)
  check("...nor offered as a button while the guard holds it open", I.t2.merge.canCloseTab == nil)
  os.remove(MD .. "/t1.json"); os.remove(T .. "/status/t1.json")
  os.remove(MD .. "/t2.json"); os.remove(T .. "/status/t2.json")
  tick()
end

-- a red gate has to be actionable: the FAILING lines, and where the whole log is
local rWt = newUnit("r1", "/r/G", "fix/r1", "999zzz", 798, 998)
local ____ = rWt
tick()
local rt = gateTasks("GATE-G")[beforeG + 1]
check("the red-gate unit's suite runs", rt ~= nil)
if rt then
  local noisy = {}
  for i = 1, 40 do noisy[#noisy + 1] = "ok   - fine " .. i end
  table.insert(noisy, 6, "FAIL - empty section renders when refundStatement is blank")
  noisy[#noisy + 1] = "-- ui.test.lua: 120 run, 1 failed --"
  for i = 1, 20 do noisy[#noisy + 1] = "ok   - later suite " .. i end
  endGate(rt, 2, table.concat(noisy, "\n") .. "\n")
  tick()
  I = items()
  local rg = I.r1.merge.gate
  check("a red gate surfaces the FAILING lines, not the trailing noise  ("
        .. tostring(rg and rg.fails) .. ")",
        rg and rg.fails and rg.fails:find("refundStatement is blank", 1, true) ~= nil
        and rg.fails:find("120 run, 1 failed", 1, true) ~= nil
        and rg.fails:find("later suite 20", 1, true) == nil)
  check("...and names the full log, kept on disk so Adam can read it", rg.log ~= nil
        and read(rg.log) ~= nil)
end

-- ---- Close tab is offered only where a press could still close the tab (2026-09-22) -------
-- Live: a merged batch unit's tab couldn't be closed and the review offered a Close tab button
-- that re-ran the identical refusal every press -- the window had been reloaded, so the bridge
-- had forgotten its tags, and a batch unit's tab never gets a name. Neither channel could ever
-- identify that tab again. The button was drawn from the mere existence of a closeNote.
do
  EXISTS["/r/X"] = true
  -- (a) a refusal a press COULD still fix: two tabs in its window share the tab's name
  local xWt = newUnit("x1", "/r/X", "fix/x1", "xx1111", 810, 1010)
  local _x1 = xWt
  write(T .. "/x1.jsonl", '{"type":"user","message":{"role":"user","content":"Start unit fix/x1'
    .. ' in its own worktree: call EnterWorktree with name \\"x1\\", then rename its branch."}}\n'
    .. '{"type":"ai-title","aiTitle":"Fix x1 tab","sessionId":"x1"}\n')
  registry(810, { "Fix x1 tab", "Fix x1 tab" })
  setPhase("x1", "merged", { sha = "abc1234def" })
  tick()
  I = items()
  check("a merged unit whose tab can't be told apart yet says so  (" .. tostring(I.x1.merge.line) .. ")",
        (I.x1.merge.line or ""):find("share the name", 1, true) ~= nil)
  check("...and keeps its Close tab button: that refusal can heal", I.x1.merge.canCloseTab == true)
  check("...while nothing was written to the bridge's inbox", #inbox(810) == 0)

  -- (b) ADAM'S CASE: a batch unit, the window reloaded (tags gone), and a tab with no name
  local yWt = newUnit("y1", "/r/X", "fix/y1", "yy2222", 811, 1011)
  local _y1 = yWt
  write(T .. "/y1.jsonl", "")   -- a tab Shepherd opened for a unit never gets a name
  write(FD .. "/bx1.json", json.encode({ v = 1, id = "bx1", nonce = "n-bx1", phase = "approved",
    repo = "/r/X", commonDir = "/r/X/.git", driver = { session_id = "xdrv", pid = "1012", name = "driver" },
    title = "close-tab batch", at = now,
    units = { { type = "fix", slug = "y1", branch = "fix/y1", task = "do the unit" } } }))
  write(FD .. "/bx1.state.json", json.encode({ grant = { approved = true, at = now },
    units = { y1 = { session = { id = "y1" } } } }))
  registry(811, { "Claude Code", "Claude Code" })
  setPhase("y1", "merged", { sha = "abc1234def" })
  tick()
  I = items()
  check("a merged unit neither channel can identify explains itself  (" .. tostring(I.y1.merge.line) .. ")",
        (I.y1.merge.line or ""):find("tagged as unit", 1, true) ~= nil
        and (I.y1.merge.line or ""):find("and by name:", 1, true) ~= nil)
  check("...and offers NO Close tab button: that refusal can never heal", I.y1.merge.canCloseTab == nil)
  local ySent, yWhy, yRetry = table.unpack({ quiet(function() return fx.closeTab(I.y1, { quiet = true }) end) }, 2, 4)
  check("...because the close itself reports the refusal as terminal  (" .. tostring(yWhy) .. ")",
        ySent == false and yRetry == false)
  check("...and nothing was written to the bridge's inbox", #inbox(811) == 0)
  alerts = {}
  quiet(function() fx.mergeCloseTab("y1") end)
  check("...pressing it anyway from a tick-stale panel is refused, and still writes nothing",
        #inbox(811) == 0)
  check("...saying why, in the panel  (" .. table.concat(alerts, " | ") .. ")",
        table.concat(alerts, " "):find("tagged as unit", 1, true) ~= nil)
  check("...and neither card is a red Needs you: a leftover tab is housekeeping (2026-09-15)",
        I.x1.merge.needsYou == false and I.y1.merge.needsYou == false)
  os.remove(MD .. "/x1.json"); os.remove(T .. "/status/x1.json")
  os.remove(MD .. "/y1.json"); os.remove(T .. "/status/y1.json")
  os.remove(FD .. "/bx1.json"); os.remove(FD .. "/bx1.state.json")
  tick()
end

-- ---- "Needs you" only when a live counterpart will get the answer (2026-09-17) ------------
-- Adam's rule: never say "Needs you" when he can't do anything about it.
local function freshProbe() fx._alive = {} end
-- a merge request whose cc-merge.sh has gone: his click would write a decision nobody claims
local nWt = newUnit("n1", "/r/N", "fix/n1", "n00001", 799, 999)
local _____ = nWt
local nreq = json.decode(read(MD .. "/n1.json")); nreq.wait_pid = 31999
write(MD .. "/n1.json", json.encode(nreq))
tick()
I = items()
check("a merge request whose script is still waiting needs Adam  ("
      .. tostring(I.n1.needsYou) .. ")", I.n1.needsYou == "needs")
DEAD["31999"] = true; freshProbe()
tick()
I = items()
check("...and once that process is gone it is only a heads-up", I.n1.needsYou == "fyi")
check("...which ranks below a working session", core.instanceTier(I.n1, {}, os.time()) > core.TIER_RUNNING)
check("...and says why, on the card", (I.n1.needsYouWhy or ""):find("waiting", 1, true) ~= nil)
DEAD["31999"] = nil; freshProbe()

-- a held question whose asking session's process has gone
local qKey = "q1"
write(T .. "/" .. qKey .. ".jsonl", '{"type":"user","message":{"role":"user","content":"hi"}}\n')
write(T .. "/status/" .. qKey .. ".json", json.encode({ status = "approval", session_id = qKey,
  name = qKey, cwd = "/r/Q", since = now - 10, updated = now - 10, editor = "vscode",
  host_window = "800", session_pid = "31888", transcript_path = T .. "/" .. qKey .. ".jsonl",
  ask_nonce = "an-q1", ask_until = now + 3600,
  pending = { tool = "AskUserQuestion", ask = { { question = "Which way?",
    options = { { label = "A" }, { label = "B" } } } } } }))
tick()
I = items()
check("a held question on a live session needs Adam  (" .. tostring(I.q1 and I.q1.needsYou) .. ")",
      I.q1 and I.q1.needsYou == "needs")
DEAD["31888"] = true; freshProbe()
tick()
I = items()
check("...and once its session's process is gone it is only a heads-up", I.q1.needsYou == "fyi")
DEAD["31888"] = nil; freshProbe()

-- a transient API error is the session's to retry, not Adam's to fix (the VPN blip)
write(T .. "/" .. qKey .. ".jsonl", '{"type":"user","message":{"role":"user","content":"hi"}}\n')
write(T .. "/status/" .. qKey .. ".json", json.encode({ status = "error", session_id = qKey,
  name = qKey, cwd = "/r/Q", since = now - 2, updated = now - 2, editor = "vscode",
  host_window = "800", session_pid = "31888", transcript_path = T .. "/" .. qKey .. ".jsonl",
  error_reason = "runtime_error", error_message = "Connection error." }))
tick()
I = items()
check("a fresh connection error is a heads-up, not a red Error  (" .. tostring(I.q1.needsYou) .. ")",
      I.q1.needsYou == "fyi" and I.q1.needsYouSource == "error")
check("...and its card ranks below a working session", core.instanceTier(I.q1, {}, os.time()) > core.TIER_RUNNING)
-- ...but a usage limit is his to act on, straight away
write(T .. "/status/" .. qKey .. ".json", json.encode({ status = "error", session_id = qKey,
  name = qKey, cwd = "/r/Q", since = now - 2, updated = now - 2, editor = "vscode",
  host_window = "800", session_pid = "31888", transcript_path = T .. "/" .. qKey .. ".jsonl",
  error_reason = "budget_exceeded", error_message = "usage limit reached" }))
tick()
I = items()
check("a usage limit still goes red at once", I.q1.needsYou == "needs")

check("the whole flow never focused a window or pressed a key", taps == 0 and focusCalls == 0)
finish()
