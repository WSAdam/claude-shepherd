-- fleet-idle.test.lua : the fleet-idle alert and spoken alerts (2026-10-03, mining round 2 unit D4a).
-- When every local session has been idle or done for alerts.idleMinutes, Shepherd sends ONE alert
-- (a macOS banner, plus an ntfy push when escalation push is set up), and arms again only once a
-- session works again. A "working" card counts as idle only on the transcript's interrupt marker
-- (it.interruptedAt), never because it has gone quiet. alerts.voice speaks the alert through
-- hs.speech, and the needs-you events alerts.voiceEvents lists.
-- Part 1 drives the pure decision (core.fleetIdleAlertDue, core.voiceWants, core.needsYouRose).
-- Part 2 loads the real claude-dashboard.lua under a stubbed hs (hs.notify, hs.http and hs.speech
-- are recorders) and ticks it. Side-effect-free: every file lives in a temp dir; HOME is pointed there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- fleet-idle.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- Part 1: the pure decision (2026-10-03) ----
local core = dofile(ROOT .. "cc-core.lua")
local NOW = 1800000000
local function tile(key, status, ageMin, extra)
  local t = { key = key, name = key, status = status, since = NOW - ageMin * 60, updated = NOW - ageMin * 60 }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local due = core.fleetIdleAlertDue
check("fleetIdleAlertDue exists", type(due) == "function")
if type(due) ~= "function" then finish() end

local a, st = due({ tile("a", "done", 30) }, NOW, { armed = true }, 0)
check("off (idleMinutes 0): no alert and no state", a == nil and st == nil)

a, st = due({ tile("a", "done", 30), tile("b", "idle", 40) }, NOW, nil, 15)
check("first sight of a fleet already idle past the threshold: no alert (a reload never fires)", a == nil)
check("...and it stays unarmed until a session works", st and st.armed == false)

a, st = due({ tile("a", "done", 5) }, NOW, nil, 15)
check("first sight of a fleet idle for less than the threshold: armed", a == nil and st and st.armed == true)

a, st = due({ tile("a", "done", 16), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("armed, every session idle 16 min: ONE alert", type(a) == "table" and a.kind == "fleetIdle")
check("...titled for the fleet", a and a.title == "Fleet idle")
check("...saying how many sessions and for how long  (" .. tostring(a and a.text) .. ")",
      a and tostring(a.text):find("2 sessions", 1, true) ~= nil and tostring(a.text):find("16 min", 1, true) ~= nil)
check("...with a sentence to speak", a and type(a.speech) == "string" and a.speech:find("16 minutes", 1, true) ~= nil)
check("...and disarms", st and st.armed == false)

a, st = due({ tile("a", "done", 60), tile("b", "done", 90) }, NOW, st, 15)
check("still idle after the alert: nothing more", a == nil and st and st.armed == false)

a, st = due({ tile("a", "working", 0), tile("b", "done", 90) }, NOW, { armed = false }, 15)
check("a session working again re-arms", a == nil and st and st.armed == true)

a = due({ tile("a", "approval", 30), tile("b", "done", 90) }, NOW, { armed = true }, 15)
check("a session waiting on an approval is not idle", a == nil)
a = due({ tile("a", "error", 30), tile("b", "done", 90) }, NOW, { armed = true }, 15)
check("an errored session is not idle (it has its own alerts)", a == nil)

-- 2026-09-18 rule: an interrupted turn fires no Stop hook, so its card stays "working" for good.
a, st = due({ tile("a", "working", 120, { interruptedAt = NOW - 20 * 60 }), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("an orphaned working card with the interrupt marker counts as idle", type(a) == "table")
a = due({ tile("a", "working", 120, { interruptedAt = NOW - 2 * 60 }), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("...idle since the interrupt, not since its last hook write", a == nil)
a, st = due({ tile("a", "working", 120, { stale = true }), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("a working card quiet for 2h with no interrupt marker stays working (never by staleness)", a == nil)
check("...and keeps the alert armed", st and st.armed == true)

a = due({ tile("a", "done", 30, { bg_active = true }), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("a finished session running background agents is not idle", a == nil)

a = due({ tile("r", "working", 0, { remote = true }), tile("b", "done", 30) }, NOW, { armed = true }, 15)
check("a remote (bridge) session doesn't count: the local fleet is idle", type(a) == "table")
check("...and the alert counts local sessions only  (" .. tostring(a and a.text) .. ")",
      a and tostring(a.text):find("1 session", 1, true) ~= nil)
a, st = due({ tile("r", "done", 60, { remote = true }) }, NOW, { armed = true }, 15)
check("no local sessions: no alert, state kept", a == nil and st and st.armed == true)
a, st = due({}, NOW, nil, 15)
check("an empty fleet on first sight: no alert, nothing learned", a == nil and st == nil)

-- voice
check("voiceWants: off by default", core.voiceWants({}, "fleetIdle") == false and core.voiceWants(nil, "needsYou") == false)
local v1 = { alerts = { voice = true } }
check("voiceWants: alerts.voice speaks the fleet-idle alert", core.voiceWants(v1, "fleetIdle") == true)
check("voiceWants: ...but needs-you only when alerts.voiceEvents lists it", core.voiceWants(v1, "needsYou") == false)
local v2 = { alerts = { voice = true, voiceEvents = { "needsYou" } } }
check("voiceWants: alerts.voiceEvents = [needsYou] speaks needs-you", core.voiceWants(v2, "needsYou") == true)
check("voiceWants: voiceEvents alone, voice off, says nothing",
      core.voiceWants({ alerts = { voice = false, voiceEvents = { "needsYou" } } }, "needsYou") == false)
check("needsYouRose: first sight is no edge", core.needsYouRose(nil, { needsYou = "needs" }) == false)
check("needsYouRose: no -> needs is the edge", core.needsYouRose("no", { needsYou = "needs" }) == true)
check("needsYouRose: a heads-up turning into needs is the edge", core.needsYouRose("fyi", { needsYou = "needs" }) == true)
check("needsYouRose: still needing you is no edge", core.needsYouRose("needs", { needsYou = "needs" }) == false)
check("needsYouRose: a heads-up is never spoken", core.needsYouRose("no", { needsYou = "fyi" }) == false)
check("needsYouRose: a remote session is never spoken", core.needsYouRose("no", { needsYou = "needs", remote = true }) == false)

-- config
local kept = core.overlayConfig({ alerts = { onScreen = true, voiceEvents = { "needsYou" }, idleMinutes = 15 } },
                                { alerts = { idleMinutes = 30, voice = true } })
check("a Settings save keeps the hand-set alerts.onScreen and alerts.voiceEvents",
      kept.alerts.onScreen == true and type(kept.alerts.voiceEvents) == "table" and kept.alerts.voiceEvents[1] == "needsYou")
check("...and takes the form's idleMinutes and voice", kept.alerts.idleMinutes == 30 and kept.alerts.voice == true)
local df = io.open(ROOT .. "defaults/cc-config.json", "r")
local okd, dcfg = pcall(json.decode, df and df:read("*a") or "")
if df then df:close() end
local al = okd and type(dcfg) == "table" and dcfg.alerts or {}
check("defaults/cc-config.json ships the fleet-idle alert on at 15 minutes", al.idleMinutes == 15)
check("...and spoken alerts off", al.voice == false)
local fkeys = {}; for _, f in ipairs(core.FEATURES) do fkeys[f.key] = f end
check("FEATURES lists the fleet-idle alert, flagged new", fkeys.fleetidle ~= nil and fkeys.fleetidle.new == true)

-- ---- Part 2: the real dashboard (2026-10-03) ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/r/A" "' .. T .. '/r/B" "' .. T .. '/r/C"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function iso(ts) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", ts) end
local function status(id, dir, pid, fields)
  local t = { session_id = id, name = id, cwd = T .. "/r/" .. dir, editor = "terminal", session_pid = pid,
              transcript_path = T .. "/" .. id .. ".jsonl" }
  for k, v in pairs(fields) do t[k] = v end
  write(T .. "/status/" .. id .. ".json", json.encode(t))
end
local function transcript(id, records)
  local out = {}
  for _, r in ipairs(records) do out[#out + 1] = json.encode(r) end
  write(T .. "/" .. id .. ".jsonl", table.concat(out, "\n") .. "\n")
end
local reply = { type = "assistant", timestamp = iso(now - 1800), message = { role = "assistant", id = "m1",
  content = { { type = "text", text = "Done." } } } }
transcript("sa", { reply })
transcript("sb", { reply })
-- C was interrupted 20 minutes ago: its status file still says "working"
transcript("sc", { reply, { type = "user", timestamp = iso(now - 1200),
  message = { role = "user", content = { { type = "text", text = "[Request interrupted by user]" } } } } })
status("sa", "A", "5001", { status = "done", since = now - 1800, updated = now - 1800 })
status("sb", "B", "5002", { status = "done", since = now - 1700, updated = now - 1700 })
status("sc", "C", "5003", { status = "working", since = now - 1300, updated = now - 1300 })
write(T .. "/.claude/cc-config.json", json.encode({
  alerts = { idleMinutes = 15, voice = true, voiceEvents = { "needsYou" } },
  escalation = { push = true, pushTopic = "my-topic" } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local banners, posts, spoken, executed = {}, {}, {}, {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
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
      local ok = os.execute('test -d "' .. tostring(path) .. '"')
      if ok == true or ok == 0 then
        if attr == "mode" then return "directory" end
        return { mode = "directory" }
      end
      local f = io.open(tostring(path), "r")
      if f then f:close(); if attr == "mode" then return "file" end return { mode = "file" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function(p) os.execute('mkdir -p "' .. tostring(p) .. '"'); return true end,
    symlinkAttributes = function() return nil end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd) executed[#executed + 1] = tostring(cmd); return "" end,
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
  "keycodes", "canvas", "image", "sound", "osascript", "dialog", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
local fakeApp = { allWindows = function() return {} end, activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
-- the three channels, as recorders
hs.notify = { new = function(_, attrs)
  local n = { attrs = attrs or {} }
  function n:send() banners[#banners + 1] = self.attrs; return self end
  return n
end }
hs.http = setmetatable({ asyncPost = function(url, body, headers)
  posts[#posts + 1] = { url = url, body = body, title = headers and headers.Title }
end }, { __index = function() return function() return nil end end })
hs.speech = { new = function()
  local s = {}
  function s:speak(text) spoken[#spoken + 1] = tostring(text); return self end
  function s:isSpeaking() return false end
  return setmetatable(s, { __index = function() return function() return nil end end })
end }
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
local fx = dash.fx
fx.now = function() return os.time() end
local function tick() return quiet(function() fx._refreshBody() end) end
local function fleetBanners()
  local n = 0
  for _, b in ipairs(banners) do if b.title == "Fleet idle" then n = n + 1 end end
  return n
end
check("the fleet-idle step is wired: FX.stepFleetIdle exists", type(fx.stepFleetIdle) == "function")
if type(fx.stepFleetIdle) ~= "function" then os.execute('rm -rf "' .. T .. '"'); finish() end

tick()
check("a fleet already idle 28 min when Shepherd starts: no alert", fleetBanners() == 0 and #posts == 0 and #spoken == 0)

-- A works again (re-arms the alert), then finishes 16 minutes ago in the fixture's clock
status("sa", "A", "5001", { status = "working", since = now, updated = now })
tick()
check("a session working: no alert", fleetBanners() == 0)
status("sa", "A", "5001", { status = "done", since = now - 16 * 60, updated = now - 16 * 60 })
tick()
check("every local session idle 16 min (C's interrupted turn included): ONE banner", fleetBanners() == 1)
local fb; for _, b in ipairs(banners) do if b.title == "Fleet idle" then fb = b end end
check("...saying all 3 sessions  (" .. tostring(fb and fb.informativeText) .. ")",
      fb and tostring(fb.informativeText):find("3 sessions", 1, true) ~= nil)
check("...one ntfy push to the escalation topic", #posts == 1 and tostring(posts[1].url):find("ntfy.sh/my-topic", 1, true) ~= nil)
check("...and it is spoken through hs.speech", #spoken == 1 and spoken[1]:find("idle", 1, true) ~= nil)
tick(); tick()
check("still idle: nothing more", fleetBanners() == 1 and #posts == 1 and #spoken == 1)
local sayRan = false
for _, c in ipairs(executed) do if c:find("say", 1, true) and c:find("/usr/bin/say", 1, true) then sayRan = true end end
check("nothing ran /usr/bin/say", not sayRan)

-- B starts needing Adam: a rising needs-you edge is spoken (alerts.voiceEvents lists it)
status("sb", "B", "5002", { status = "approval", since = now, updated = now,
  pending = { tool = "Bash", summary = "rm -r build" } })
tick()
local needs; for _, s in ipairs(spoken) do if s:find("needs you", 1, true) then needs = s end end
check("a session starting to need you is spoken  (" .. tostring(needs) .. ")", needs ~= nil and needs:find("sb", 1, true) ~= nil)
local n0 = #spoken
tick()
check("...once", #spoken == n0)

-- switched off: no alert, however long the fleet sits idle
write(T .. "/.claude/cc-config.json", json.encode({ alerts = { idleMinutes = 0 } }))
status("sb", "B", "5002", { status = "working", since = now, updated = now })
tick()
status("sb", "B", "5002", { status = "done", since = now - 20 * 60, updated = now - 20 * 60 })
tick(); tick()
check("alerts.idleMinutes 0 switches the alert off", fleetBanners() == 1)

os.execute('rm -rf "' .. T .. '"')
finish()
