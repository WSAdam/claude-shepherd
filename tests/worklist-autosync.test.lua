-- worklist-autosync.test.lua : BEHAVIORAL fixture for My List auto-sync. Loads the real
-- claude-dashboard.lua under a stubbed hs (the smoke-test stubs) with ONE relabelled
-- project whose enrolled TODO.md just changed, lets the load-time refresh() run, and
-- reads the window.ccWorklist(...) push auto-sync makes.
--
-- 2026-09-10: every auto-sync while My List was open renamed a relabelled project's tab
-- back to its folder name. Cause: FX.todoAutoSyncTick ran (and pushed the payload)
-- BEFORE core.applyLabelsByCwd in the tick, and the payload's label reads it.label first
-- and it.name second -- so with no relabel applied yet, the folder name won.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- worklist-autosync.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a relabelled, enrolled project whose TODO.md moved ------------
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/proj-folder" "' .. T .. '/.claude"')
local PROJ = T .. "/proj-folder"          -- no transcript_path, so projectKey == cwd
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"proj-folder","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
  PROJ, now, now))
write(T .. "/labels.json", json.encode({ [PROJ] = "Renamed Project" }))
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = {},
  todoMeta = { [PROJ] = { cwd = PROJ, mtime = 1, seen = {} } } }))
write(PROJ .. "/TODO.md", "- [ ] first item from the file\n")
-- 2026-09-29 (needs live run, build program unit 37): the same file also carries a [~] line and a
-- marked [x] line, so the push below proves the flag survives file -> import -> payload.
write(PROJ .. "/TODO.md", "- [ ] first item from the file\n- [~] open the panel and look\n"
  .. "- [x] shipped the probe (needs live run)\n")

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = T .. "/worklist.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs (as tests/smoke.test.lua), with a real mtime for the TODO.md ----
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
    -- the enrolled TODO.md changed 10s ago (past auto-sync's 2s settle guard)
    attributes = function(path, attr)
      if path == PROJ .. "/TODO.md" then
        if attr == "modification" then return now - 10 end
        if attr == nil then return { mode = "file", modification = now - 10 } end
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

-- ---- the auto-sync push ------------------------------------------------------
local payload
for _, s in ipairs(jsCalls) do
  local body = s:match("^window%.ccWorklist%((.*)%)$")
  if body then payload = json.decode(body) end
end
check("auto-sync imported the changed TODO.md and pushed My List", payload ~= nil)
if not payload then finish() end
local tab
for _, p in ipairs(payload.projects or {}) do if p.key == PROJ then tab = p end end
check("the pushed tabs include the relabelled project", tab ~= nil)
check("auto-sync push shows the tab's rename, not the folder name  (got="
      .. tostring(tab and tab.label) .. " want=Renamed Project)", tab ~= nil and tab.label == "Renamed Project")

-- ---- needs live run: the round trip (2026-09-29) ----
local byText = {}
for _, item in ipairs((tab and tab.items) or {}) do byText[item.text] = item end
local plain, tilde, marked = byText["first item from the file"], byText["open the panel and look"],
  byText["shipped the probe (needs live run)"]
check("live run: every line of the file reached My List", plain ~= nil and tilde ~= nil and marked ~= nil)
check("live run: the [~] line arrives flagged, open and unclaimed",
      tilde ~= nil and tilde.liveRun == true and tilde.done == false and tilde.fileDone == nil)
check("live run: the marked [x] line arrives flagged and claimed done, never ticked",
      marked ~= nil and marked.liveRun == true and marked.fileDone == true and marked.done == false)
check("live run: a plain line carries no flag", plain ~= nil and plain.liveRun == nil)
finish()
