-- smoke.test.lua : load claude-dashboard.lua under a STUBBED Hammerspoon and let
-- its load-time refresh() run once. Catches runtime errors the pure unit tests +
-- luac can't see -- e.g. `pairs` over a state table that was never initialized,
-- which aborts the whole refresh loop (the panel shows no sessions). The crash
-- that motivated this file: a reap iterating summaryState.pending while it was nil.
--
-- The reap loops at the end of refresh() run regardless of how many sessions are
-- live, so even an EMPTY fleet exercises them. Side-effect-free: HOME is redirected
-- to a temp dir by the runner and hs.fs.dir reports no files.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

-- Universal stub: any index yields a callable that yields another stub, so an
-- arbitrary hs.<ns>.<fn>(...) chain and obj:method(...) call both succeed.
local function mkstub()
  return setmetatable({}, {
    __index = function() return mkstub() end,
    __call  = function() return mkstub() end,
  })
end

local json = dofile(HERE .. "support/json.lua")
local settingsStore = {}
local frame = { x = 0, y = 0, w = 1920, h = 1080 }

local hs = {
  json = json,
  fs = {
    dir = function() return function() return nil end end,  -- empty directory iterator
    attributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = {
    get = function(k) return settingsStore[k] end,
    set = function(k, v) settingsStore[k] = v end,
  },
  screen = { mainScreen = function()
    return { frame = function() return frame end, fullFrame = function() return frame end }
  end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
-- hs.timer: real-ish clock, no-op schedulers (the scheduled fns must NOT fire here)
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
-- hs.webview: windowMasks must be numeric (the code OR-s them), new returns a handle
hs.webview = setmetatable({
  windowMasks  = setmetatable({}, { __index = function() return 0 end }),
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return mkstub() end,
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
-- Namespaces touched but not needing real values
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application",
  "window", "pasteboard", "keycodes", "canvas", "image", "sound",
  "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
-- hs.drawing: windowLevels / windowBehaviors are bit-OR-ed -> numeric value-tables
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
hs.reload = function() end
-- final catch-all for anything missed
setmetatable(hs, { __index = function() return mkstub() end })

_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
if ok then
  print("ok   - smoke: claude-dashboard.lua loads + initial refresh() runs clean")
  print("-- smoke.test.lua: 1 run, 0 failed --")
  os.exit(0)
else
  print("FAIL - smoke: claude-dashboard.lua crashed on load / first refresh:")
  print("       " .. tostring(err))
  print("-- smoke.test.lua: 1 run, 1 failed --")
  os.exit(1)
end
