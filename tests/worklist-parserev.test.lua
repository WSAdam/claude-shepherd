-- worklist-parserev.test.lua -- My List re-reads every enrolled TODO.md ONCE after the parser learns a
-- new fact (2026-10-13). Loads the real dashboard under a stubbed hs (the worklist-autosync.test.lua
-- harness) and lets its first refresh tick run.
--
-- My List lanes put a `[~]` line in To verify through a new item field, fileWait, which only the
-- import writes. Auto-sync re-imports a file only when its modification time moves, so an item
-- imported before the upgrade would sit in To do until its TODO.md next changed. One flag in
-- hs.settings (ccTodoParseRev) forces one re-read of every watched file, then never again.
--
-- Usage: lua tests/worklist-parserev.test.lua

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- worklist-parserev.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: an enrolled project whose [~] item was imported by an older build ----
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
write(PROJ .. "/TODO.md", "- [ ] plain work\n- [~] open the panel and look\n")
-- what an older build stored: liveRun on the [~] item, but no fileWait -- and the file's mtime recorded
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = { [PROJ] = {
    { id = "a1", text = "plain work", src = "todo", srcText = "plain work", done = false, ts = MTIME, details = "", due = "", steps = {} },
    { id = "a2", text = "open the panel and look", src = "todo", srcText = "open the panel and look", done = false,
      liveRun = true, ts = MTIME, details = "", due = "", steps = {} } } },
  todoMeta = { [PROJ] = { cwd = PROJ, mtime = MTIME, seen = { ["plain work"] = true, ["open the panel and look"] = true } } } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = T .. "/worklist.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs (as tests/worklist-autosync.test.lua) ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
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
local function pushes()
  local n = 0
  for _, s in ipairs(jsCalls) do if s:find("^window%.ccWorklist%(") then n = n + 1 end end
  return n
end

-- ---- the one re-read ----
local by = stored()
check("the [~] item imported by an older build now waits on its live run (To verify)",
      by["open the panel and look"] ~= nil and by["open the panel and look"].fileWait == true)
check("...it is still the same item, never ticked", (by["open the panel and look"] or {}).id == "a2"
      and (by["open the panel and look"] or {}).done == false)
check("...the plain line doesn't wait", by["plain work"] ~= nil and by["plain work"].fileWait == nil)
check("the re-read is recorded, so it never runs again  (ccTodoParseRev=" .. tostring(settingsStore.ccTodoParseRev) .. ")",
      tonumber(settingsStore.ccTodoParseRev) ~= nil and tonumber(settingsStore.ccTodoParseRev) >= 1)

-- ---- and only once: a later tick with the file unchanged imports nothing ----
local dash = _G.__ccDashboard
local fx = dash and dash.fx
check("the running dashboard exposes FX", type(fx) == "table" and type(fx.todoAutoSyncTick) == "function")
if type(fx) == "table" and type(fx.todoAutoSyncTick) == "function" then
  local before = pushes()
  fx.todoAutoSyncTick({})
  fx.todoAutoSyncTick({})
  check("later ticks with the file unchanged import nothing  (pushes " .. before .. " -> " .. pushes() .. ")",
        pushes() == before)
  -- a fresh FX (a Hammerspoon reload) with the flag already set doesn't re-read either
  fx._todoWatch = nil
  fx._todoMtime = nil
  fx.todoAutoSyncTick({})
  check("a reload with the flag set doesn't re-read  (pushes " .. before .. " -> " .. pushes() .. ")", pushes() == before)
end
finish()
