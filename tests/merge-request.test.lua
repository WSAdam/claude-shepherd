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
hs.reload = function() end
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

check("the whole flow never focused a window or pressed a key", taps == 0 and focusCalls == 0)
finish()
