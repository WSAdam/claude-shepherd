-- worklist-review.test.lua -- BEHAVIORAL: the My List review heads-up, wired (2026-10-13).
--
-- My List grew to 262 open items before Adam looked at it: nothing said the To verify pile was
-- growing. A project with 30+ items to verify, or one waiting more than 24h, now stamps its cards
-- (it.wlReview -> a Heads-up through core.needsYouKind), counts on 📋 My List, and fires ONE banner
-- per crossing -- persisted, so a reload doesn't fire it again. The step runs every tick, so it must
-- read the cached store without decoding or copying it while the file hasn't changed.
--
-- Loads the real claude-dashboard.lua under a stubbed hs (the worklist-perf.test.lua harness) and
-- drives FX.stepWorklistReview / FX.annotateNeedsYou with a card of its own.
-- Usage: lua tests/worklist-review.test.lua

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish()
  print("-- worklist-review.test.lua: " .. run .. " run, " .. failed .. " failed --")
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

-- 31 items the automation ticked an hour ago, plus two to do: over the line by count
local items = {}
for i = 1, 31 do
  items[#items + 1] = { id = "v" .. i, text = "ticked " .. i, src = "todo", srcText = "ticked " .. i,
                        done = false, fileDone = true, claimTs = now - 3600, ts = now - 3600 }
end
items[#items + 1] = { id = "t1", text = "work one", done = false, ts = now }
items[#items + 1] = { id = "t2", text = "work two", done = false, ts = now }
local WL = T .. "/worklist.json"
write(WL, json.encode({ generic = {}, byProject = { [PROJ] = items }, todoMeta = {} }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = WL, HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end; return realGetenv(k) end

-- ---- stubbed hs, with the controller callback captured (as worklist-perf.test.lua) ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, CALLBACK = {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
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
      local h = io.open(path, "r"); if not h then return nil end
      local sz = #(h:read("*a")); h:close()
      local m = MTIME[path] or now
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
check("FX.stepWorklistReview exists", type(fx.stepWorklistReview) == "function")
check("FX.worklistCached exists", type(fx.worklistCached) == "function")
if type(fx.stepWorklistReview) ~= "function" then finish() end

-- record banners and writes; count decodes of the store
local banners, writes = {}, 0
fx.notify = function(title, text, opts) banners[#banners + 1] = { title = title, text = text, opts = opts } end
local realWrite = fx.writeWorklist
fx.writeWorklist = function(st) writes = writes + 1; return realWrite(st) end
local realDecode, decodes = core.json.decode, 0
core.json.decode = function(s)
  local v = realDecode(s)
  if type(v) == "table" and (v.byProject ~= nil or v.generic ~= nil) then decodes = decodes + 1 end
  return v
end

-- a fresh review state, as a reload starts it; `fired` is what hs.settings holds
local function fresh(fired)
  fx._wlReview = nil
  settingsStore.ccWorklistReviewFired = fired
end
local function card() return { key = "w1", status = "idle", name = "proj", cwd = PROJ, projectKey = PROJ, since = now - 60 } end
local function tick(list) quiet(function() fx.stepWorklistReview(list, {}); fx.annotateNeedsYou(list) end) end

-- ---- over the line: the card, the badge, one banner ----
fresh({})                                -- banners have fired before (not the first sight ever)
local list = { card() }
tick(list)
local it = list[1]
check("an idle card of an over project is stamped  (n=" .. tostring(it.wlReview and it.wlReview.n) .. ")",
      type(it.wlReview) == "table" and it.wlReview.n == 31 and it.wlReview.key == PROJ)
check("...and reads as a heads-up from My List  (" .. tostring(it.needsYou) .. "/" .. tostring(it.needsYouSource) .. ")",
      it.needsYou == "fyi" and it.needsYouSource == "mylist")
check("...saying what to do  (" .. tostring(it.needsYouWhy) .. ")",
      type(it.needsYouWhy) == "string" and it.needsYouWhy:find("31 to verify", 1, true) ~= nil)
check("one banner fires for the crossing  (" .. #banners .. ")", #banners == 1)
check("...naming the project and the count  (" .. tostring(banners[1] and banners[1].title) .. ": "
      .. tostring(banners[1] and banners[1].text) .. ")",
      banners[1] ~= nil and tostring(banners[1].title):find("proj", 1, true) ~= nil
      and tostring(banners[1].text):find("31 to verify", 1, true) ~= nil)
check("...with no session to jump to (a click can't land in the wrong window)", banners[1] ~= nil and banners[1].opts == nil)
local badge = realDecode((fx._wlReview or {}).badge or "null") or {}
check("the 📋 badge counts every item to verify  (" .. tostring(badge.n) .. ")", badge.n == 31)

-- ---- only once ----
list = { card() }
tick(list)
check("the next tick fires no second banner", #banners == 1)
fresh(settingsStore.ccWorklistReviewFired)   -- a reload, with what the panel saved
list = { card() }
tick(list)
check("a reload doesn't fire it again", #banners == 1)
check("...the card still carries the heads-up", list[1].needsYou == "fyi")

-- ---- cheap per tick: no decode, one summary while the file hasn't changed ----
decodes = 0
local before = fx._wlReview.computes
for _ = 1, 10 do tick({ card() }) end
check("ten ticks on an unchanged store decode nothing  (decodes=" .. decodes .. ")", decodes == 0)
check("...and work the summary out no more than once  (" .. (fx._wlReview.computes - before) .. ")",
      fx._wlReview.computes - before <= 1)

-- ---- a working session keeps its word ----
list = { card() }; list[1].status = "working"
tick(list)
check("a working card in the project isn't turned into a heads-up", list[1].needsYou ~= "fyi")

-- ---- verifying clears it ----
quiet(function() CALLBACK({ body = json.encode({ a = "worklist-mark-all", v = PROJ, text = "verify" }) }) end)
list = { card() }
tick(list)
check("Mark all on the To verify lane clears the heads-up", list[1].wlReview == nil and list[1].needsYou == "no")
badge = realDecode(fx._wlReview.badge or "null") or {}
check("...and the badge  (" .. tostring(badge.n) .. ")", (badge.n or 0) == 0)

-- ---- the age rule, and the clock backfill for items claimed before it existed ----
local st = realDecode(readf(WL))
st.byProject[PROJ][#st.byProject[PROJ] + 1] = { id = "old", text = "claimed long ago", done = false,
  src = "todo", fileDone = true, claimTs = now - 25 * 3600 }
st.byProject[PROJ][#st.byProject[PROJ] + 1] = { id = "nc", text = "claimed before the clock", done = false,
  src = "todo", fileDone = true }
write(WL, json.encode(st)); MTIME[WL] = now + 5
banners = {}; writes = 0
fresh({})
list = { card() }
tick(list)
check("one item waiting over 24h is enough  (n=" .. tostring(list[1].wlReview and list[1].wlReview.n) .. ")",
      list[1].needsYou == "fyi" and list[1].wlReview ~= nil and list[1].wlReview.n == 2)
check("...and its banner fires", #banners == 1)
local after = realDecode(readf(WL))
local nc
for _, x in ipairs(after.byProject[PROJ]) do if x.id == "nc" then nc = x end end
check("a claimed item with no clock gets one, once  (writes=" .. writes .. ")", nc ~= nil and tonumber(nc.claimTs) ~= nil and writes == 1)
tick({ card() }); tick({ card() })
check("...and is never written again", writes == 1)

-- ---- the first sight ever is silent ----
banners = {}
fresh(nil)
tick({ card() })
check("the very first look (an upgrade) fires no banner for a backlog already there", #banners == 0)
finish()
