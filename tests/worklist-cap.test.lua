-- worklist-cap.test.lua -- My List imports every line of a TODO.md, however long it has grown
-- (2026-10-19). Loads the real dashboard under a stubbed hs (the worklist-parserev.test.lua harness)
-- and lets its first refresh tick run.
--
-- 2026-10-19: core.parseTodoFile kept only the first 500 unique lines. TODO.md is append-only, so
-- once a project's file passed 500 items every new line was dropped before the import saw it: this
-- repo's 55 and ChargebackSentinel's 115 newer lines never reached My List, which read empty from
-- 2026-10-13 on. The fixture is that state: the parser rev already recorded (1), the first 500 lines
-- imported and the file's mtime recorded, so only a forced re-read can bring the rest in.
--
-- Usage: lua tests/worklist-cap.test.lua

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- worklist-cap.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: an enrolled project whose TODO.md grew past 500 lines ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/proj-folder" "' .. T .. '/.claude"')
local PROJ = T .. "/proj-folder"
local now = os.time()
local MTIME = now - 600                    -- the file hasn't changed since that import
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"proj-folder","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
  PROJ, now, now))
local lines, seen = {}, {}
for i = 1, 500 do
  lines[#lines + 1] = "- [x] shipped item " .. i
  seen["shipped item " .. i] = true         -- imported, verified and cleared by Adam
end
lines[#lines + 1] = "- [ ] newer work 501"
lines[#lines + 1] = "- [x] newer claim 502"
lines[#lines + 1] = "- [~] newer live check 503 (needs live run)"
write(PROJ .. "/TODO.md", table.concat(lines, "\n") .. "\n")
-- what the capped build stored: one item still on the list (Adam hasn't cleared it), every one of the
-- first 500 lines tombstoned, the file's mtime recorded
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = { [PROJ] = {
    { id = "k1", text = "shipped item 7", src = "todo", srcText = "shipped item 7", done = false, fileDone = true,
      claimTs = MTIME, ts = MTIME, details = "", due = "", steps = {} } } },
  todoMeta = { [PROJ] = { cwd = PROJ, mtime = MTIME, seen = seen } } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = T .. "/worklist.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs (as tests/worklist-parserev.test.lua) ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
-- the live install had already recorded parser rev 1 (the 2026-10-13 re-read)
local settingsStore, frame = { ccTodoParseRev = 1 }, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      if path == PROJ .. "/TODO.md" then
        if attr == "modification" then return MTIME end
        if attr == nil then return { mode = "file", modification = MTIME } end
      end
      return nil
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
print = function() end
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
print = realPrint
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end

local function stored()
  local f = io.open(T .. "/worklist.json", "r"); local s = f and f:read("*a") or "{}"; if f then f:close() end
  local by = {}
  for _, it in ipairs(((json.decode(s) or {}).byProject or {})[PROJ] or {}) do by[it.text] = it end
  return by
end

-- ---- the lines past the 500th reach My List, with no change to the file ----
local by = stored()
check("an open line past the 500th is imported as To do", by["newer work 501"] ~= nil
      and by["newer work 501"].done == false and by["newer work 501"].fileDone == nil)
check("a ticked line past the 500th is imported as a claim (To verify), never ticked for Adam",
      by["newer claim 502"] ~= nil and by["newer claim 502"].fileDone == true and by["newer claim 502"].done == false)
check("a [~] line past the 500th waits on its live run", by["newer live check 503 (needs live run)"] ~= nil
      and by["newer live check 503 (needs live run)"].fileWait == true)
check("lines Adam already cleared stay cleared", by["shipped item 3"] == nil and by["shipped item 500"] == nil)
check("the item still on the list is untouched and not flagged missing", by["shipped item 7"] ~= nil
      and by["shipped item 7"].id == "k1" and by["shipped item 7"].fileMissing == nil)
check("the re-read is recorded past rev 1  (ccTodoParseRev=" .. tostring(settingsStore.ccTodoParseRev) .. ")",
      (tonumber(settingsStore.ccTodoParseRev) or 0) > 1)
finish()
