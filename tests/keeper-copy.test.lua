-- keeper-copy.test.lua : the transcript keeper's wiring under a STUBBED Hammerspoon (2026-10-03,
-- mining round 2 unit F3). The ★ pins live in the panel's localStorage, which Lua can't read: the
-- panel sends them (keep-pins) and Shepherd keeps them in ~/.claude/cc-keep/pins.json. On its own
-- timer (never the tick) FX.stepKeeper looks at the starred projects' transcripts and copies each
-- ended one that has no copy, or whose original grew, with ONE async hs.task at a time (`cp -c`,
-- an APFS clone) into ~/.claude/cc-keep/<project>/<session>.jsonl. Seance, fleet search and History
-- read the kept copy once Claude Code has deleted the original; nothing deletes a copy but Adam's
-- confirmed Remove; Diagnostics' offer writes cleanupPeriodDays and nothing else.
-- This drives the real functions on real files in a temp HOME: tasks are recorders that the test
-- runs for real (sh, cp, rg/grep) before firing their callbacks.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- keeper-copy.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local function sh(cmd) local p = io.popen(cmd); local o = p and p:read("*a") or ""; if p then p:close() end; return o end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local T = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
if T == "" then check("mktemp a fixture dir", false); finish() end
local CLAUDE = T .. "/.claude"
local PROJ, KEEP, SCR = CLAUDE .. "/projects", CLAUDE .. "/cc-keep", T .. "/scratch"
sh("mkdir -p " .. q(T .. "/status") .. " " .. q(PROJ .. "/-r-A") .. " " .. q(PROJ .. "/-r-B") .. " " .. q(SCR)
   .. " " .. q(CLAUDE .. "/cc-ledger"))
local NOW = os.time()
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function append(path, s) local f = assert(io.open(path, "a")); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function age(path, secs) sh("touch -t " .. os.date("%Y%m%d%H%M.%S", NOW - secs) .. " " .. q(path)) end
local function modeOf(path) return (sh("stat -c %a " .. q(path) .. " 2>/dev/null || stat -f %Lp " .. q(path)):gsub("%s+$", "")) end
local function line(text) return json.encode({ type = "user", cwd = "/r/A", message = { role = "user", content = text } }) .. "\n" end

local S = {}
for i = 1, 9 do S[i] = string.format("%04d%04d-0000-4000-8000-%012d", i, i, i) end
local function orig(pk, i) return PROJ .. "/" .. pk .. "/" .. S[i] .. ".jsonl" end
local function kept(pk, i) return KEEP .. "/" .. pk .. "/" .. S[i] .. ".jsonl" end
-- -r-A (starred): S1 ended long ago, S2 still live (a card), S3 written a minute ago. -r-B: never starred.
write(orig("-r-A", 1), line("first session: needle-kept-one")); age(orig("-r-A", 1), 20 * 86400)
write(orig("-r-A", 2), line("the live one")); age(orig("-r-A", 2), 3600)
write(orig("-r-A", 3), line("fresh: needle-kept-one")); age(orig("-r-A", 3), 60)
write(orig("-r-B", 4), line("unstarred: needle-kept-one")); age(orig("-r-B", 4), 20 * 86400)
write(T .. "/status/k2.json", json.encode({ status = "working", session_id = S[2], name = "A-live", cwd = "/r/A",
  transcript_path = orig("-r-A", 2), since = NOW - 60, updated = NOW - 60, editor = "terminal", session_pid = "5002" }))
write(CLAUDE .. "/cc-config.json", json.encode({}))
write(CLAUDE .. "/settings.json", '{\n  "model": "opus",\n  "hooks": {}\n}\n')
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
        local okd, v = pcall(json.decode, (arg:gsub(",%s*\"[^\"]*\"%s*,%s*\"[^\"]*\"%s*$", "")))
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
-- hs.execute runs for real only what the keeper and the settings writer need; anything else is a no-op
local EXECUTED = {}
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
    if cmd:find(KEEP, 1, true) or cmd:find("/bin/bash -c ", 1, true) == 1 then return sh(cmd .. " 2>&1") end
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
local DIALOG = { answer = "Keep them", asked = {} }
rawset(hs.dialog, "blockAlert", function(...)
  DIALOG.asked[#DIALOG.asked + 1] = { ... }
  return DIALOG.answer
end)
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
local clock = NOW
fx.now = function() return clock end
local function tick() return quiet(function() fx._refreshBody() end) end
local function post(tbl) return quiet(function() CALLBACK({ body = json.encode(tbl) }) end) end
check("the keeper is wired", type(fx.stepKeeper) == "function" and type(fx.keepSetPins) == "function")
if type(fx.stepKeeper) ~= "function" or type(fx.keepSetPins) ~= "function" then finish() end
tick()

local function copyTasks()
  local out = {}
  for _, t in ipairs(TASKS) do
    if t.bin == "/bin/sh" and type(t.args[6]) == "string" and t.args[6] == KEEP then out[#out + 1] = t end
  end
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
local function step() return quiet(function() fx.stepKeeper(true) end) end

-- 0. nothing starred: nothing copied, no keep folder made; the tick never copies
step()
check("no ★ project: nothing is copied", #copyTasks() == 0)
check("...and no keep folder is made", statOf(KEEP) == nil)
local n0 = #TASKS
tick()
check("the panel's tick starts no copy", #copyTasks() == 0 and #TASKS == n0)

-- 1. the panel sends its pins: kept on disk, keepable keys only; the keep folder is private
post({ a = "keep-pins", text = json.encode({ "-r-A", "../evil", "/r/cwd-key" }) })
check("the pins are kept in cc-keep/pins.json", table.concat(core.keeperPinsParse(read(KEEP .. "/pins.json")), ",") == "-r-A")
check("...the keep folder is mode 700", modeOf(KEEP) == "700")
local c = copyTasks()
check("starring copies the project's ended transcript at once: one task", #c == 1)
check("...for the session that ended", c[1] and c[1].args[4] == orig("-r-A", 1) and c[1].args[5] == kept("-r-A", 1))
check("...through /bin/sh, an APFS clone first", c[1] and tostring(c[1].args[2]):find("cp -c", 1, true) ~= nil)
check("...started, never run synchronously", c[1] and c[1].running == true and not read(kept("-r-A", 1)))

-- 2. one at a time
step()
check("no second copy while one runs", #copyTasks() == 1)

-- 3. it lands
runTask(c[1])
check("the kept copy is the transcript", read(kept("-r-A", 1)) == read(orig("-r-A", 1)))
check("...nothing else was copied: not the live session, not the fresh one, not the unstarred project",
      #copyTasks() == 1 and not exists(kept("-r-A", 2)) and not exists(kept("-r-A", 3)) and not exists(kept("-r-B", 4)))
step()
check("a copy as big as its original isn't copied again", #copyTasks() == 1)

-- 4. the original grows: copied again
append(orig("-r-A", 1), line("resumed later: more"))
age(orig("-r-A", 1), 2 * 86400)
step()
c = copyTasks()
check("the original grew: copied again", #c == 2 and c[2].args[4] == orig("-r-A", 1))
runTask(c[2])
check("...the copy has the new lines", read(kept("-r-A", 1)) == read(orig("-r-A", 1)))

-- 5. two at once go one after the other
age(orig("-r-A", 3), 3 * 3600)
write(orig("-r-A", 5), line("another ended one")); age(orig("-r-A", 5), 30 * 86400)
step()
c = copyTasks()
check("two wanted: the oldest goes first", #c == 3 and c[3].args[4] == orig("-r-A", 5))
runTask(c[3])
c = copyTasks()
check("...and the next starts when it lands", #c == 4 and c[4].args[4] == orig("-r-A", 3) and c[4].running)
runTask(c[4])
check("...both kept", exists(kept("-r-A", 5)) and exists(kept("-r-A", 3)))

-- 6. a copy that fails is reported in Diagnostics and doesn't stop the next
write(orig("-r-A", 6), line("gone before it was copied")); age(orig("-r-A", 6), 40 * 86400)
step()
c = copyTasks()
os.remove(orig("-r-A", 6))
runTask(c[#c])
check("a failed copy leaves no file", not exists(kept("-r-A", 6)))
post({ a = "open-doctor-view" })
local rows = lastPush("ccDoctor") or {}
local function rowWith(needle) for _, r in ipairs(rows) do if tostring(r.label):find(needle, 1, true) then return r end end end
check("...and Diagnostics names it", rowWith("couldn't copy") ~= nil and rowWith("couldn't copy").label:find(S[6], 1, true) ~= nil)

-- 7. a hung copy is reclaimed
write(orig("-r-A", 7), line("slow disk")); age(orig("-r-A", 7), 40 * 86400)
step()
c = copyTasks()
local hung = c[#c]
check("a copy is running", hung and hung.args[4] == orig("-r-A", 7) and hung.running)
clock = NOW + core.KEEPER.copyTimeoutSeconds + 5
step()
check("...still running past copyTimeoutSeconds: terminated", hung.terminated == true)
c = copyTasks()
check("...and a fresh one takes its place", #c >= 1 and c[#c] ~= hung and c[#c].args[4] == orig("-r-A", 7))
runTask(c[#c])
check("...which lands", exists(kept("-r-A", 7)))
quiet(function() hung.cb(15, "", "") end)
check("the reclaimed task's late callback changes nothing", exists(kept("-r-A", 7)) and #copyTasks() == #c)
clock = NOW

-- 8. Claude Code deletes the original: readers use the kept copy
os.remove(orig("-r-A", 1))
check("FX.keepReadPath: the kept copy once the original is gone", fx.keepReadPath(orig("-r-A", 1)) == kept("-r-A", 1))
check("...the original while it exists", fx.keepReadPath(orig("-r-A", 3)) == orig("-r-A", 3))
-- Seance from a History row (its session id and project key)
post({ a = "seance-ask", text = json.encode({ sessionId = S[1], projectKey = "-r-A", question = "What did you change?" }) })
local asked
for _, t in ipairs(TASKS) do
  local all = table.concat(t.args, " ")
  if all:find("--fork-session", 1, true) and all:find(S[1], 1, true) then asked = all end
end
check("Seance asks a deleted session from its kept copy", asked ~= nil and asked:find(q(kept("-r-A", 1)), 1, true) ~= nil)
-- ...and from a fleet-search hit in the kept copy
local nTasks = #TASKS
post({ a = "seance-ask", text = json.encode({ sessionId = S[1], file = kept("-r-A", 1), question = "Again?" }) })
check("...and from a fleet-search hit in it (a file in cc-keep is allowed)", #TASKS > nTasks)

-- fleet search: the kept copy's hit when its original is gone, the original's otherwise (never twice)
post({ a = "fleet-search", text = json.encode({ q = "needle-kept-one" }) })
local search
for _, t in ipairs(TASKS) do
  if t.bin == "/bin/sh" and tostring(t.args[2] or ""):find("needle%-kept%-one") then search = t end
end
check("fleet search runs", search ~= nil)
if search then
  check("...over the keep folder too", search.args[2]:find(KEEP, 1, true) ~= nil)
  sh("/bin/sh -c " .. q(search.args[2]))
  quiet(function() search.cb(0, "", "") end)
end
local res = lastPush("ccSearch") or { hits = {} }
local byFile = {}
for _, h in ipairs(res.hits or {}) do byFile[h.file] = (byFile[h.file] or 0) + 1; byFile[h.file .. "#h"] = h end
check("the deleted session is found in its kept copy", byFile[kept("-r-A", 1)] == 1)
check("...marked kept, mapped to its session", byFile[kept("-r-A", 1) .. "#h"] and byFile[kept("-r-A", 1) .. "#h"].kept == true
      and byFile[kept("-r-A", 1) .. "#h"].sessionId == S[1])
check("a session whose original is still there is found once, in the original",
      byFile[orig("-r-A", 3)] == 1 and byFile[kept("-r-A", 3)] == nil)
check("the unstarred project's transcript is found as always", byFile[orig("-r-B", 4)] == 1)

-- History: rows with a kept copy, and the copies per project
local LEDGER = CLAUDE .. "/cc-ledger/" .. os.date("!%Y-%m-%d", NOW) .. ".jsonl"
for i, sid in ipairs({ S[1], S[3], S[4] }) do
  append(LEDGER, json.encode({ ts = NOW - 100 + i, type = "prompt", session_id = sid, name = "s" .. i,
                               projectKey = (sid == S[4]) and "-r-B" or "-r-A" }) .. "\n")
end
post({ a = "open-history-view" })
local hist = lastPush("ccHistory") or {}
local byId = {}
for _, r in ipairs(hist.records or {}) do byId[r.session_id] = r end
check("History: the deleted session's row has only its kept copy", byId[S[1]] and byId[S[1]].kept == true and byId[S[1]].keptOnly == true)
check("...a row with both says kept", byId[S[3]] and byId[S[3]].kept == true and not byId[S[3]].keptOnly)
check("...an unstarred project's row says nothing", byId[S[4]] and byId[S[4]].kept == nil)
check("...and the copies per project ride along", type(hist.keptByProject) == "table" and hist.keptByProject["-r-A"] == 4)

-- 9. unstarring never deletes a copy
post({ a = "keep-pins", text = json.encode({}) })
check("unstarred: pins.json is empty", #core.keeperPinsParse(read(KEEP .. "/pins.json")) == 0)
check("...and every kept copy is still there", exists(kept("-r-A", 1)) and exists(kept("-r-A", 3)) and exists(kept("-r-A", 5)))
write(orig("-r-A", 8), line("ended after unstarring")); age(orig("-r-A", 8), 40 * 86400)
local before = #copyTasks()
step()
check("...and an unstarred project isn't copied any more", #copyTasks() == before)

-- 10. Remove the kept copies: only for an unstarred project, only on Adam's confirmed click
post({ a = "keep-pins", text = json.encode({ "-r-A" }) })
for _, t in ipairs(copyTasks()) do if t.running then runTask(t) end end
local asks = #DIALOG.asked
post({ a = "keep-remove", v = "-r-A" })
check("a starred project's copies can't be removed", exists(kept("-r-A", 1)) and #DIALOG.asked == asks)
post({ a = "keep-pins", text = json.encode({}) })
DIALOG.answer = "Keep them"
post({ a = "keep-remove", v = "-r-A" })
check("Remove asks first", #DIALOG.asked == asks + 1)
check("...'Keep them' keeps them", exists(kept("-r-A", 1)) and exists(kept("-r-A", 5)))
DIALOG.answer = "Remove"
post({ a = "keep-remove", v = "-r-A" })
check("...'Remove' removes the project's copies", not exists(kept("-r-A", 1)) and not exists(kept("-r-A", 5))
      and statOf(KEEP .. "/-r-A") == nil)
check("...and nothing else in the keep folder", exists(KEEP .. "/pins.json"))
asks = #DIALOG.asked
post({ a = "keep-remove", v = "../.." })
check("a key that isn't a project is refused before any question", #DIALOG.asked == asks and exists(KEEP .. "/pins.json"))

-- 11. Diagnostics: cleanupPeriodDays, and the offer that writes only that key
post({ a = "open-doctor-view" })
rows = lastPush("ccDoctor") or {}
local cr = rowWith("30 days")
check("Diagnostics: Claude Code deletes transcripts after 30 days (unset)", cr ~= nil and cr.offer and cr.offer.id == "cleanup-days")
post({ a = "doctor-offer", v = "something-else" })
check("an unknown offer writes nothing", not read(CLAUDE .. "/settings.json"):find("cleanupPeriodDays", 1, true))
post({ a = "doctor-offer", v = "cleanup-days" })
local st = json.decode(read(CLAUDE .. "/settings.json"))
check("the offer sets cleanupPeriodDays to 365", st.cleanupPeriodDays == 365)
check("...and keeps every other key", st.model == "opus" and type(st.hooks) == "table")
rows = lastPush("ccDoctor") or {}
cr = rowWith("365 days")
check("...and Diagnostics shows it at once, with no offer", cr ~= nil and cr.status == "ok" and cr.offer == nil)

sh("rm -r " .. q(T))
finish()
