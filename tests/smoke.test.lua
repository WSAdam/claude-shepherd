-- smoke.test.lua : load claude-dashboard.lua under a STUBBED Hammerspoon and let
-- its load-time refresh() run once, over a one-session FIXTURE. Catches runtime
-- errors the pure unit tests + luac can't see -- e.g. `pairs` over a state table
-- that was never initialized, which aborts the whole refresh loop (the panel shows
-- no sessions). The crash that motivated this file: a reap iterating
-- summaryState.pending while it was nil.
--
-- The reap loops at the end of refresh() run regardless of fleet size, and the
-- fixture makes the per-tile loop process ≥1 real session (not just the empty
-- path). Oracle: the load must not error AND the panel must receive a populated
-- ccUpdate (so "refreshed correctly" is distinguished from "did nothing quietly").
-- Side-effect-free: a temp CC_STATUS_DIR holds the fixture; nothing touches ~/.claude.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local function fail(msg) print("FAIL - smoke: " .. msg); print("-- smoke.test.lua: 1 run, 1 failed --"); os.exit(1) end

-- ---- a temp status dir with one fixture session -----------------------------
local FIXDIR
do
  local p = io.popen("mktemp -d 2>/dev/null"); FIXDIR = p and p:read("*l"); if p then p:close() end
  if not FIXDIR or FIXDIR == "" then fail("could not mktemp a fixture status dir") end
end
do
  local now = os.time()
  local f = io.open(FIXDIR .. "/smoke-fixture.json", "w")
  if not f then fail("could not write the fixture status file") end
  -- the status keys cc-status.sh writes: status/session_id/name/cwd/since/updated
  f:write(string.format(
    '{"status":"working","session_id":"smoke1","name":"smoke","cwd":"%s","since":%d,"updated":%d}',
    FIXDIR, now, now))
  f:close()
end
-- Point the dashboard at the fixture dir. It reads CC_STATUS_DIR via os.getenv at
-- LOAD, and Lua has no os.setenv, so shim os.getenv before dofile.
local realGetenv = os.getenv
os.getenv = function(k) if k == "CC_STATUS_DIR" then return FIXDIR end return realGetenv(k) end

-- ---- the stubbed Hammerspoon surface ----------------------------------------
-- Universal stub: any index yields a callable that yields another stub, so an
-- arbitrary hs.<ns>.<fn>(...) chain and obj:method(...) call both succeed.
-- NOTE: a stubbed value is ALWAYS a table. If the dashboard ever does a string/
-- number op (concat, arithmetic, #) on a value from an un-special-cased hs path,
-- you'll get a confusing "attempt to concatenate a table value" instead of a clean
-- skip -- add a numeric/string stub for that path (as windowMasks/windowLevels = 0).
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end

-- capture the panel's evaluateJavaScript calls so we can assert it rendered
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end

local json = dofile(HERE .. "support/json.lua")
local settingsStore = {}
local frame = { x = 0, y = 0, w = 1920, h = 1080 }

local hs = {
  json = json,
  fs = {
    -- list the REAL directory (so the fixture is discovered); empty for missing dirs
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function() return nil end,
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
  absoluteTime = function() return os.time() * 1e9 end,  -- monotonic ns (R1-08 dispatchSerialized)
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
hs.webview = setmetatable({
  windowMasks  = setmetatable({}, { __index = function() return 0 end }),  -- bit-OR-ed -> numeric
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return webviewHandle() end,
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
-- The explicit list below is NOT required for correctness -- the catch-all __index
-- on `hs` already stubs any unset key. It's a documentation of the exact hs surface
-- claude-dashboard.lua touches (the blast radius at a glance); a stale/missing entry
-- just falls through to the catch-all, so it need not stay in sync with the dashboard.
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application",
  "window", "pasteboard", "keycodes", "canvas", "image", "sound",
  "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })   -- catch-all
_G.hs = hs

-- ---- run it -----------------------------------------------------------------
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
if not ok then fail("claude-dashboard.lua crashed on load / first refresh:\n       " .. tostring(err)) end

-- the load-time refresh() must have pushed a POPULATED panel update (not silently
-- nothing). ccUpdate carries the session list; assert one fired with our fixture.
local sawUpdate, sawFixture = false, false
for _, s in ipairs(jsCalls) do
  if s:find("ccUpdate", 1, true) then sawUpdate = true end
  if s:find("smoke1", 1, true) then sawFixture = true end
end
if not sawUpdate then fail("refresh() never pushed a ccUpdate to the panel") end
if not sawFixture then fail("the fixture session never reached the panel (per-tile loop didn't process it)") end

print("ok   - smoke: dashboard loads, first refresh() runs clean, fixture session renders")
print("-- smoke.test.lua: 1 run, 0 failed --")
os.exit(0)
