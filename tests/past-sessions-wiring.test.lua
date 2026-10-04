-- past-sessions-wiring.test.lua : browse and reopen past sessions under a STUBBED Hammerspoon
-- (2026-10-04, mining round 2 unit F2). Opening 🗂 History starts a background scan (hs.task, never
-- the tick) of every transcript in ~/.claude/projects plus the kept copies whose originals Claude Code
-- deleted; its callback merges the rows into History. Resume reopens only a session verified dead
-- (FX.restartVerifyDead -> for a session in no restart snapshot, core.pastLiveness over one ps):
-- a VS Code session through FX.openClaudeTab with restartSession (the ?session= link, D-14's rule), a
-- terminal one through FX.spawnSession with resume (`claude -r`). A kept-only session's copy goes
-- back to its original path first, by an async task that never overwrites a file.
-- This drives the real functions on real files in a temp HOME: tasks are recorders the test runs for
-- real before firing their callbacks.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- past-sessions-wiring.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local function sh(cmd) local p = io.popen(cmd); local o = p and p:read("*a") or ""; if p then p:close() end; return o end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local T = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
if T == "" then check("mktemp a fixture dir", false); finish() end
-- realpath: macOS's /var/folders is /private/var/folders, and the launch folder must encode to its key
T = sh("cd " .. q(T) .. " && pwd -P"):gsub("%s+$", "")
local CLAUDE = T .. "/.claude"
local PROJ, KEEP, SCR = CLAUDE .. "/projects", CLAUDE .. "/cc-keep", T .. "/scratch"
local REPO = T .. "/repo"
local NOW = os.time()
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end

local core0 = dofile(ROOT .. "cc-core.lua")
local PK = core0.encodeProjectPath(REPO)
sh("mkdir -p " .. q(T .. "/status") .. " " .. q(PROJ .. "/" .. PK) .. " " .. q(KEEP .. "/" .. PK) .. " " .. q(SCR)
   .. " " .. q(CLAUDE .. "/cc-ledger") .. " " .. q(CLAUDE .. "/sessions") .. " " .. q(REPO))

local S = {}
for i = 1, 9 do S[i] = string.format("%04d%04d-0000-4000-8000-%012d", i, i, i) end
local function orig(i) return PROJ .. "/" .. PK .. "/" .. S[i] .. ".jsonl" end
local function kept(i) return KEEP .. "/" .. PK .. "/" .. S[i] .. ".jsonl" end
local function transcript(i, prompt, entry)
  return json.encode({ type = "user", sessionId = S[i], cwd = REPO, entrypoint = entry or "claude-vscode",
    timestamp = "2026-09-20T10:00:00.000Z", message = { role = "user", content = prompt } }) .. "\n"
end
-- S1: an ended VS Code session. S2: live (it has a card). S3: Claude Code deleted it; only its kept copy
-- is left. S4: an ended terminal session. S5: Shepherd's own headless run. S6: ended, but a process
-- still resumes it (`--resume=<id>`, as VS Code runs one).
write(orig(1), transcript(1, "ended vscode work"))
write(orig(2), transcript(2, "the live one"))
write(kept(3), transcript(3, "kept-only work"))
write(orig(4), transcript(4, "terminal work", "cli"))
write(orig(5), transcript(5, "review this diff", "sdk-cli"))
write(orig(6), transcript(6, "resumed elsewhere"))
write(T .. "/status/k2.json", json.encode({ status = "working", session_id = S[2], name = "repo-live", cwd = REPO,
  transcript_path = orig(2), since = NOW - 60, updated = NOW - 60, editor = "vscode", session_pid = "5002" }))
write(CLAUDE .. "/cc-config.json", json.encode({ spawn = { editor = "kitty" } }))
write(T .. "/status/.panel-alive", tostring(NOW))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              CC_SCRATCH_DIR = SCR, SHELL = "/bin/zsh", HOME = T }
os.getenv = function(k)
  if ENV[k] then return ENV[k] end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local alerts, pushed, CALLBACK = {}, {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s)
      s = tostring(s or "")
      local m = s:match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
      local fn, arg = s:match("^window%.(cc%a+)%((.*)%)$")
      if fn then
        local okd, v = pcall(json.decode, arg)
        pushed[#pushed + 1] = { fn = fn, v = okd and v or arg }
      end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local function lastPush(fn) for i = #pushed, 1, -1 do if pushed[i].fn == fn then return pushed[i].v end end end
local function statOf(path)
  local o = sh("stat -c '%s %Y %F' " .. q(path) .. " 2>/dev/null || stat -f '%z %m %HT' " .. q(path) .. " 2>/dev/null")
  local size, mtime, kind = o:match("^(%d+) (%d+) (.-)%s*$")
  if not size then return nil end
  kind = kind:lower()
  return { size = tonumber(size), modification = tonumber(mtime),
           mode = kind:find("directory", 1, true) and "directory" or (kind:find("regular", 1, true) and "file" or "other") }
end
-- ps: Shepherd's own pid (the control) plus whatever a case puts in PS
local ME = 10000
local PS = {}
local EXECUTED = {}
local function psOut()
  local lines = { string.format("%5d Thu Oct  1 09:00:00 2026 /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon", ME) }
  for _, l in ipairs(PS) do lines[#lines + 1] = l end
  return table.concat(lines, "\n") .. "\n"
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen("ls -1A " .. q(tostring(path)) .. " 2>/dev/null")
      if p then for l in p:lines() do files[#files + 1] = l end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      local a = statOf(tostring(path))
      if not a then return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory" end
      if attr then return a[attr] end
      return a
    end,
    mkdir = function(p) os.execute("mkdir -p " .. q(tostring(p))); return true end,
    symlinkAttributes = function() return nil end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    EXECUTED[#EXECUTED + 1] = cmd
    if cmd:find("ps -axww", 1, true) then return psOut() end
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
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) CALLBACK = fn end },
      { __index = function() return function() return mkstub() end end })
  end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
local TASKS = {}
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, running = false, terminated = false }
  function t:start() self.running = true; return self end
  function t:setWorkingDirectory() return true end
  function t:terminate() self.terminated = true; self.running = false; return true end
  function t:isRunning() return self.running end
  TASKS[#TASKS + 1] = t
  return setmetatable(t, { __index = function() return function() return nil end end })
end)
hs.reload = function() end
hs.processInfo = { processID = ME, bundleID = "org.hammerspoon.Hammerspoon" }
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
local clock = NOW
fx.now = function() return clock end
local function tick() return quiet(function() fx._refreshBody() end) end
local function post(tbl) return quiet(function() CALLBACK({ body = json.encode(tbl) }) end) end
check("the past-session scan and Resume are wired",
      type(fx.refreshPastSessions) == "function" and type(fx.pastResume) == "function" and type(fx.pastVerifyDead) == "function")
if type(fx.refreshPastSessions) ~= "function" or type(fx.pastResume) ~= "function" then finish() end
tick()

local function scanTasks()
  local out = {}
  for _, t in ipairs(TASKS) do
    if t.bin == "/bin/sh" and tostring(t.args[2] or ""):find("head -c " .. core.PAST.headBytes, 1, true) then out[#out + 1] = t end
  end
  return out
end
local function restoreTasks()
  local out = {}
  for _, t in ipairs(TASKS) do if t.bin == "/bin/sh" and t.args[3] == "cc-past-restore" then out[#out + 1] = t end end
  return out
end
local function runTask(t)
  local parts = { q(t.bin) }
  for _, x in ipairs(t.args) do parts[#parts + 1] = q(x) end
  local p = io.popen(table.concat(parts, " ") .. " 2>&1; echo \"@@rc $?\"")
  local o = p:read("*a"); p:close()
  t.running = false
  quiet(function() t.cb(tonumber(o:match("@@rc (%d+)")) or 1, o, "") end)
end
local function rowsById()
  local h = lastPush("ccHistory") or {}
  local by = {}
  for _, r in ipairs(h.records or {}) do by[r.session_id] = r end
  return by, h
end

-- 1. the tick never scans
local n0 = #TASKS
tick(); tick()
check("the panel's tick starts no transcript scan", #scanTasks() == 0 and #TASKS == n0)

-- 2. opening History starts ONE background scan; its callback fills the rows
post({ a = "open-history-view" })
local scans = scanTasks()
check("opening History starts a background scan", #scans == 1 and scans[1].running == true)
check("...over the transcripts and the kept copy whose original is gone",
      scans[1] and scans[1].args[2]:find(q(orig(1)), 1, true) ~= nil and scans[1].args[2]:find(q(kept(3)), 1, true) ~= nil)
local _, h0 = rowsById()
check("...while History already shows what the ledger has", h0 and h0.scanning == true)
post({ a = "open-history-view" })
check("a second open while it runs starts no second scan", #scanTasks() == 1)
runTask(scans[1])
local by, h = rowsById()
check("the scan's rows reach History", by[S[1]] and by[S[1]].past and by[S[1]].past.prompt == "ended vscode work")
check("...the kept-only session is a row, marked so", by[S[3]] and by[S[3]].keptOnly == true and by[S[3]].canResume == true)
check("...the live session is marked live, not resumable", by[S[2]] and by[S[2]].live == true and not by[S[2]].canResume)
check("...Shepherd's own headless run is left out", by[S[5]] == nil)
check("...and the scan is done", h and not h.scanning)
local nScan = #scanTasks()
post({ a = "open-history-view" })
check("re-opening soon after with nothing changed reads nothing again",
      #scanTasks() == nScan or (scanTasks()[#scanTasks()].args[2]:find(q(orig(1)), 1, true) == nil))

-- 3. Resume: a live session is refused, nothing opens
local opened, spawned = {}, {}
fx.openClaudeTab = function(o) opened[#opened + 1] = o; if type(o.onDone) == "function" then o.onDone(true) end; return true end
fx.spawnSession = function(...) spawned[#spawned + 1] = { ... }; return true end
alerts = {}
post({ a = "past-resume", text = json.encode({ sessionId = S[2], projectKey = PK }) })
check("Resume refuses a session with a card", #opened == 0 and #spawned == 0)
check("...and says why", #alerts > 0 and table.concat(alerts, " "):find("card", 1, true) ~= nil)

-- 4. an ended VS Code session reopens as its tab, through the restart path's ?session= rule
post({ a = "past-resume", text = json.encode({ sessionId = S[1], projectKey = PK }) })
check("an ended VS Code session reopens through FX.openClaudeTab", #opened == 1)
check("...handing it the session (restartSession), in its own folder's window",
      opened[1] and opened[1].restartSession == S[1] and opened[1].root == REPO and opened[1].editor == "vscode")
check("...with no prompt typed", opened[1] and opened[1].prompt == "")
local ps = false
for _, c in ipairs(EXECUTED) do if c:find("ps -axww", 1, true) then ps = true end end
check("...after one ps verified it dead", ps)

-- 5. a process still resuming it (VS Code runs `claude --resume=<id>`): refused
PS = { "66494 Sun Oct  4 10:46:30 2026 /x/claude --output-format stream-json --resume=" .. S[6] .. " --setting-sources=user" }
alerts = {}
post({ a = "past-resume", text = json.encode({ sessionId = S[6], projectKey = PK }) })
check("a session a process still resumes is refused", #opened == 1)
check("...naming the process", table.concat(alerts, " "):find("66494", 1, true) ~= nil)
-- a ps that can't see Shepherd proves nothing
local realExec = hs.execute
hs.execute = function(cmd) if tostring(cmd):find("ps -axww", 1, true) then return "  1 Thu Oct  1 09:00:00 2026 /sbin/launchd\n" end return realExec(cmd) end
post({ a = "past-resume", text = json.encode({ sessionId = S[1], projectKey = PK }) })
check("a ps without Shepherd's own pid: nothing opens", #opened == 1)
hs.execute = realExec
PS = {}

-- 6. a terminal session reopens with claude -r, in the editor Shepherd spawns in
post({ a = "past-resume", text = json.encode({ sessionId = S[4], projectKey = PK }) })
check("an ended terminal session reopens through FX.spawnSession", #spawned == 1)
check("...with resume = its id, in its folder", spawned[1] and spawned[1][1] == "kitty" and spawned[1][2] == REPO
      and type(spawned[1][6]) == "table" and spawned[1][6].resume == S[4])

-- 7. kept-only: its copy goes back first (never over a file), then the tab
post({ a = "past-resume", text = json.encode({ sessionId = S[3], projectKey = PK }) })
local rs = restoreTasks()
check("a kept-only session starts a restore first", #rs == 1 and rs[1].running == true)
check("...and opens nothing until it lands", #opened == 1)
runTask(rs[1])
check("the kept copy is back at its original path", read(orig(3)) == read(kept(3)))
check("...and then the tab opens with the session", #opened == 2 and opened[2].restartSession == S[3])
-- the original came back (or another session wrote there) before the restore ran: left alone
os.remove(orig(3))
post({ a = "past-resume", text = json.encode({ sessionId = S[3], projectKey = PK }) })
rs = restoreTasks()
write(orig(3), "a session wrote here meanwhile\n")
alerts = {}
runTask(rs[#rs])
check("a restore never overwrites a transcript that appeared meanwhile", read(orig(3)) == "a session wrote here meanwhile\n")
check("...opens nothing", #opened == 2)
check("...and says why", #alerts > 0)

-- 7b. 2026-10-04 (the driver's review): a restored session must not SHARE its kept copy's inode. A
-- hard link from the kept copy would let the resumed session append straight into the copy, and the
-- keeper's "grown" re-copy (cp -c <original> <kept>) would then copy a file onto itself. The restore
-- clones into a part file and links THAT, so the two stay separate and the keeper stays quiet.
local function inode(p) return (sh("stat -f %i " .. q(p) .. " 2>/dev/null || stat -c %i " .. q(p)):gsub("%s+$", "")) end
local function keepTasks()
  local out = {}
  for _, t in ipairs(TASKS) do if t.bin == "/bin/sh" and t.args[6] == KEEP then out[#out + 1] = t end end
  return out
end
write(kept(7), transcript(7, "kept and resumed later"))
sh("touch -t " .. os.date("%Y%m%d%H%M.%S", NOW - 40 * 86400) .. " " .. q(kept(7)))
post({ a = "past-resume", text = json.encode({ sessionId = S[7], projectKey = PK }) })
rs = restoreTasks()
runTask(rs[#rs])
check("a restored transcript is its own file, not the kept copy's inode", exists(orig(7)) and inode(orig(7)) ~= inode(kept(7)))
-- the resumed session writes on; the original grows, the copy doesn't
local f7 = assert(io.open(orig(7), "a")); f7:write(transcript(7, "more after the resume")); f7:close()
check("...so the resumed session's writes stay out of the kept copy", read(orig(7)) ~= read(kept(7)))
sh("touch -t " .. os.date("%Y%m%d%H%M.%S", NOW - 3600) .. " " .. q(orig(7)))
local nKeep = #keepTasks()
post({ a = "keep-pins", text = json.encode({ PK }) })
quiet(function() fx.stepKeeper(true) end)
local kt = keepTasks()
local grew
for i = nKeep + 1, #kt do if kt[i].args[4] == orig(7) then grew = kt[i] end end
check("the keeper copies the grown original once", grew ~= nil)
if grew then runTask(grew) end
check("...and the copy lands (no \"are identical\" refusal)", read(kept(7)) == read(orig(7)) and inode(orig(7)) ~= inode(kept(7)))
local nAfter = #keepTasks()
quiet(function() fx.stepKeeper(true) end)
quiet(function() fx.stepKeeper(true) end)
check("...then stays quiet: no failing copy, no endless re-copy", #keepTasks() == nAfter)
check("...and Diagnostics names no failed copy", fx._keep.lastError == nil)

-- 8. what the panel sends is checked in Lua
local nT, nO, nS = #TASKS, #opened, #spawned
post({ a = "past-resume", text = json.encode({ sessionId = "x; rm -rf ~", projectKey = PK }) })
post({ a = "past-resume", text = json.encode({ sessionId = S[1], projectKey = "../../etc" }) })
post({ a = "past-resume", text = "not json" })
check("a bad id, project key or payload opens nothing", #opened == nO and #spawned == nS and #TASKS == nT)

-- 9. FX.restartVerifyDead: a session in the restart snapshot keeps the restart rule; one in no
-- snapshot is checked by the past-session rule
local dead1 = fx.restartVerifyDead(S[1])
check("FX.restartVerifyDead verifies a past session (in no snapshot) by the past-session rule", dead1 == true)
local dead2, why2 = fx.restartVerifyDead(S[2])
check("...and refuses a live one (" .. tostring(why2) .. ")", dead2 == false)

sh("rm -r " .. q(T))
finish()
