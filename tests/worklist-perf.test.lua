-- worklist-perf.test.lua : BEHAVIORAL fixture for the cost of checking an item off.
--
-- 2026-09-21: Adam's My List had 1,065 items in a 778KB cc-worklist.json, and every click
-- on a checkbox took about half a second -- during which the WHOLE panel is frozen, because
-- Hammerspoon is single-threaded. Measured in the live VM: FX.readWorklist() = 266ms, of
-- which 257ms is decoding the store; the JS render was only 8ms. The handler decoded it
-- ONCE for the mutation and FX.worklistPayload() decoded it AGAIN to build the push, so a
-- single check-off paid for two full decodes of every project's items.
--
-- What this pins is the count, not the clock: a toggle decodes the store at most once, and
-- a run of toggles doesn't decode it again while the file hasn't changed. Timing assertions
-- would be flaky on a loaded machine; the decode count is exact and is the thing that was
-- wrong. A deep copy of the decoded state measured 1.7ms against 231ms for a fresh read,
-- so the cache hands out copies and callers keep mutating their own state as before.
--
-- Loads the real claude-dashboard.lua under the stubbed hs, capturing the webview
-- controller's callback so the test can post real bridge messages at it.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish()
  print("-- worklist-perf.test.lua: " .. run .. " run, " .. failed .. " failed --")
  os.exit(failed == 0 and 0 or 1)
end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/proj" "' .. T .. '/.claude"')
local PROJ = T .. "/proj"
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readf(path) local h = io.open(path, "r"); if not h then return nil end
  local s = h:read("*a"); h:close(); return s end

write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"proj","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
  PROJ, now, now))
-- A list with enough items that a re-decode would be the dominant cost, as Adam's is.
local items = {}
for i = 1, 200 do
  items[#items + 1] = { id = "i" .. i, text = "item " .. i, ts = now - i, done = false }
end
local WL = T .. "/worklist.json"
write(WL, json.encode({ generic = {}, byProject = { [PROJ] = items }, todoMeta = {} }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = WL, HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end; return realGetenv(k) end

-- ---- stubbed hs, with the controller callback captured ----------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, CALLBACK = {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
-- mtimes are served from a table the test controls, so "the file changed" is exact
local MTIME = {}
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      local m = MTIME[path]
      if m == nil then
        local h = io.open(path, "r"); if not h then return nil end
        local sz = #(h:read("*a")); h:close()
        if attr == "modification" then return now end
        if attr == "size" then return sz end
        return { mode = "file", modification = now, size = sz }
      end
      local h = io.open(path, "r"); local sz = h and #(h:read("*a")) or 0; if h then h:close() end
      if attr == "modification" then return m end
      if attr == "size" then return sz end
      return { mode = "file", modification = m, size = sz }
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok = quiet(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads", ok)
if not ok then finish() end
local dash = rawget(_G, "__ccDashboard")
local fx, core = dash.fx, dash.core
check("the controller callback was captured, so the test can post real messages", type(CALLBACK) == "function")
if type(CALLBACK) ~= "function" then finish() end

-- Count decodes OF THE STORE. core.json.decode is looked up on the table at each call
-- site, so replacing it here counts every one; filtering on the store's own shape keeps
-- unrelated decodes (labels, auto-titles) out of the number.
local realDecode, decodes = core.json.decode, 0
core.json.decode = function(s)
  local v = realDecode(s)
  if type(v) == "table" and (v.byProject ~= nil or v.generic ~= nil) then decodes = decodes + 1 end
  return v
end
local function post(tbl) quiet(function() CALLBACK({ body = json.encode(tbl) }) end) end
local function realDecodeFile(path) return realDecode(readf(path) or "{}") end
local function lastPayload()
  for i = #jsCalls, 1, -1 do
    local body = jsCalls[i]:match("^window%.ccWorklist%((.*)%)$")
    if body then return json.decode(body) end
  end
end
local function itemsOf(payload, key)
  for _, p in ipairs((payload or {}).projects or {}) do
    if p.key == key then return p.items or {} end
  end
  return {}
end

-- ---- one check-off decodes the store once ----------------------------------
jsCalls = {}
decodes = 0
post({ a = "worklist-toggle", v = PROJ, text = "i7" })
check("a check-off decodes the whole store at most once  (decodes=" .. decodes .. ")", decodes <= 1)
local after = lastPayload()
check("...and the panel is still told about it", after ~= nil)
local done7
for _, it in ipairs(itemsOf(after, PROJ)) do if it.id == "i7" then done7 = it.done end end
check("...and the item really is done in what it was told", done7 == true)
check("...and it is done on disk too",
      (readf(WL) or ""):find('"id":"i7"') ~= nil and (function()
        local st = realDecode(readf(WL) or "{}")
        for _, it in ipairs((st.byProject or {})[PROJ] or {}) do
          if it.id == "i7" then return it.done == true end
        end
        return false
      end)())

-- ---- a run of them doesn't re-decode per click -----------------------------
-- The real complaint: working through a backlog, click after click. Twenty clicks used to
-- be forty decodes of every project's items.
decodes = 0
for i = 10, 29 do post({ a = "worklist-toggle", v = PROJ, text = "i" .. i }) end
check("twenty check-offs in a row decode the store at most once  (decodes=" .. decodes .. ")", decodes <= 1)
local run20 = lastPayload()
local doneCount = 0
for _, it in ipairs(itemsOf(run20, PROJ)) do if it.done then doneCount = doneCount + 1 end end
check("...and all twenty landed, plus the first one  (done=" .. doneCount .. ")", doneCount == 21)

-- ---- a change made outside the panel is still picked up --------------------
-- The cache may not outrank the file: cc-worklist.json is the panel's own, but a hand-edit
-- (or a restore from a backup) has to win, or the panel would serve a stale list for good.
local raw = realDecode(readf(WL))
raw.byProject[PROJ][1].text = "edited outside the panel"
write(WL, json.encode(raw))
MTIME[WL] = now + 60          -- ...and the file's mtime moves, as a real edit's would
decodes = 0
post({ a = "worklist-load" })
local edited = lastPayload()
check("an edit made outside the panel is re-read  (decodes=" .. decodes .. ")", decodes >= 1)
check("...and shows in the list", (itemsOf(edited, PROJ)[1] or {}).text == "edited outside the panel")

-- ---- a caller may mutate what it gets back ---------------------------------
-- Every mutation site does `local st = FX.readWorklist()` and edits it in place, so a cache
-- that handed out its own table would be corrupted by the next caller that mutates without
-- writing. It hands out copies instead.
local a1 = fx.readWorklist()
a1.byProject[PROJ][2].text = "scribbled on by a caller"
a1.generic[#a1.generic + 1] = { id = "junk", text = "never written" }
local a2 = fx.readWorklist()
check("mutating a returned worklist doesn't change the next read",
      a2.byProject[PROJ][2].text ~= "scribbled on by a caller" and #a2.generic == 0)

-- ---- the daily archive moves old done work out of the store (2026-09-21) ----
-- Adam: "once a day moves everything from already done that is older than 10 days to an
-- archive list, that way i can keep my previous stuff for referencing etc but the main list
-- stays smaller". The point is the MAIN store shrinking, so what is asserted is that the
-- items left it, that they are all still there in the archive's own file, and that the tick
-- does it once a day rather than on every pass.
do
  local DAY = 86400
  local nowT = os.time()
  local ARCH = T .. "/archive.json"
  ENV.CC_WORKLIST_ARCHIVE_FILE = ARCH
  local st = { generic = {}, byProject = { [PROJ] = {
    { id = "old1", text = "done long ago", done = true, doneTs = nowT - 30 * DAY },
    { id = "old2", text = "also long ago", done = true, doneTs = nowT - 11 * DAY },
    { id = "new1", text = "done this morning", done = true, doneTs = nowT - 3600 },
    { id = "open1", text = "still to do" },
  } }, todoMeta = {} }
  write(WL, json.encode(st))
  MTIME[WL] = nowT + 100                       -- the cache must not serve the old content
  settingsStore.ccWorklistArchivedAt = nil     -- never archived on this machine

  local moved = select(2, quiet(function() return fx.worklistArchiveTick() end))
  check("the daily pass archives the done work older than the window  (moved=" .. tostring(moved) .. ")",
        moved == 2)
  local left = realDecodeFile(WL)
  local ids = {}
  for _, it in ipairs((left.byProject or {})[PROJ] or {}) do ids[#ids + 1] = it.id end
  table.sort(ids)
  check("...the main list keeps only recent and open work  (" .. table.concat(ids, ",") .. ")",
        table.concat(ids, ",") == "new1,open1")
  local arch = realDecodeFile(ARCH)
  local aids = {}
  for _, it in ipairs((arch.byProject or {})[PROJ] or {}) do aids[#aids + 1] = it.id end
  table.sort(aids)
  check("...and the archive has them, in their own file  (" .. table.concat(aids, ",") .. ")",
        table.concat(aids, ",") == "old1,old2")
  check("...with the time each was actually done",
        (function()
          for _, it in ipairs((arch.byProject or {})[PROJ] or {}) do
            if it.id == "old1" then return it.doneTs == nowT - 30 * DAY end
          end
        end)() == true)

  -- ...and not again on the next pass: it is a daily job, not a per-tick one.
  local again = select(2, quiet(function() return fx.worklistArchiveTick() end))
  check("a second pass the same day does nothing  (moved=" .. tostring(again) .. ")", again == 0)
  -- A day later it runs again, and finds the item that has since aged out.
  settingsStore.ccWorklistArchivedAt = nowT - DAY - 60
  local st2 = realDecodeFile(WL)
  st2.byProject[PROJ][1].doneTs = nowT - 20 * DAY      -- "done this morning" is now old
  write(WL, json.encode(st2))
  MTIME[WL] = nowT + 200
  local nextDay = select(2, quiet(function() return fx.worklistArchiveTick() end))
  check("a day later it runs again  (moved=" .. tostring(nextDay) .. ")", nextDay == 1)
  check("...and the archive keeps what it already had, plus the new one",
        #((realDecodeFile(ARCH).byProject or {})[PROJ] or {}) == 3)
end

os.execute('rm -rf "' .. T .. '"')
finish()
