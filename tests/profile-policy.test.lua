-- profile-policy.test.lua : BEHAVIORAL fixture (2026-10-15) for an agent profile's policyBundle.
-- 2026-10-15: core.resolveAgent resolved profile.policyBundle, but the spawn path never used it -- a
-- session spawned from a profile naming a bundle started with no bundle at all.
-- Loads the real claude-dashboard.lua under a stubbed hs (the audit-preset.test.lua stubs: the
-- panel's message channel kept, hs.task.new recorded), posts what the spawn modal posts for a saved
-- agent, then runs the REAL SessionStart hook (cc-status.sh) for the session that starts in that
-- folder, and compares its per-session policy files with what the card's Policy dropdown writes.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end
local function finish() print("-- profile-policy.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a project, a saved agent naming a bundle, the bundle in the config --------------
local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local T = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
if T == "" then check("mktemp a fixture dir", false); finish() end
local PROJ = T .. "/shop"
local PLAIN = T .. "/plain"
local C = T .. "/.claude"
local NOTES = C .. "/cc-notes"
local POLICY, OVERRIDE = C .. "/cc-policy", C .. "/cc-policy-override"
os.execute('mkdir -p "' .. T .. '/status" "' .. C .. '" "' .. PROJ .. '" "' .. PLAIN .. '"')
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local BUNDLE = { autoAllow = { "Read" }, autoDeny = { "Bash(rm *)", "Write" }, autopilot = true }
write(C .. "/cc-config.json", json.encode({ spawn = { live = true, editor = "kitty" },
  remoteControl = { onSpawn = false }, policies = { bundles = { ["read-only"] = BUNDLE } } }))
write(C .. "/cc-agents.json", json.encode({ agents = {
  { name = "reviewer", folder = PROJ, policyBundle = "read-only" },
  { name = "helper", folder = PLAIN } } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k)
  if ENV[k] then return ENV[k] end
  if k:sub(1, 3) == "CC_" then return nil end   -- every other Shepherd dir defaults under HOME
  return realGetenv(k)
end

-- ---- stubbed hs (as tests/audit-preset.test.lua) ----------------------------------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local tasks, panelCb = {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function under(path, dir) return path == dir or path:sub(1, #dir + 1) == dir .. "/" end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1a "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function() return nil, "No such file or directory" end,
    mkdir = function(path)
      if under(tostring(path), T) then os.execute('mkdir -p "' .. tostring(path) .. '"') end
      return true
    end,
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
    return setmetatable({ setCallback = function(_, fn) panelCb = fn end }, { __index = function() return function() return mkstub() end end })
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
rawset(hs.task, "new", function(bin, _, args)
  tasks[#tasks + 1] = { bin = bin, args = args }
  return { start = function() end }
end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
check("the panel's message channel is wired", type(panelCb) == "function")
if type(panelCb) ~= "function" then finish() end
local function post(msg) quiet(function() panelCb({ body = json.encode(msg) }) end) end
local function spawn(dir, agent)
  post({ a = "spawn", v = "", text = "", img = "", mode = "existing", dir = dir, editor = "kitty",
         permMode = "", provider = "", agent = agent })
end

-- the real SessionStart hook, for a session that starts in `cwd`; HOME is the fixture's
local function sessionStart(sid, cwd, source)
  local input = T .. "/hook-input.json"
  write(input, json.encode({ session_id = sid, cwd = cwd, source = source or "startup" }))
  local env = "HOME='" .. T .. "' CC_STATUS_DIR='" .. T .. "/status' CC_NOTES_DIR='" .. NOTES
    .. "' CC_POLICY_DIR='" .. POLICY .. "' CC_POLICY_OVERRIDE_DIR='" .. OVERRIDE
    .. "' CC_LEDGER_DIR='" .. T .. "/ledger' CC_CONFIG_FILE='" .. C .. "/cc-config.json'"
    .. " CLAUDE_CODE_ENTRYPOINT=claude-vscode"
  return sh(env .. " bash '" .. ROOT .. "cc-status.sh' sessionstart < '" .. input .. "' 2>/dev/null")
end
local function decoded(path) local s = read(path); if not s then return nil end; local okd, t = pcall(json.decode, s); return okd and t or nil end
local function list(t) return type(t) == "table" and table.concat(t, "|") or tostring(t) end

-- ---- a profile's bundle reaches the session spawned from it (2026-10-15) ----------------------
spawn(PROJ, "reviewer")
check("the profile spawn launched one kitty session", #tasks == 1)
eq("...after leaving the bundle under the id a respawn's note uses",
   (sh("ls -1A '" .. NOTES .. "/pending' 2>/dev/null"):gsub("%s+$", "")),
   "cwd-" .. _G.__ccDashboard.core.cheapHash(PROJ) .. ".policy.json")
eq("taking it prints nothing into the session's context", sessionStart("new1", PROJ), "")
eq("the session spawned from a profile naming a bundle has that bundle chosen, as from its card",
   read(OVERRIDE .. "/new1"), "read-only")
local got = decoded(POLICY .. "/new1")
check("...and the gate's resolved policy file is there from its first tool call", type(got) == "table")
got = got or {}
eq("...naming the bundle", got.bundle, "read-only")
eq("...with the bundle's deny rules", list(got.autoDeny), "Bash(rm *)|Write")
eq("...its allow rules", list(got.autoAllow), "Read")
eq("...and its autopilot", got.autopilot, true)

-- the same choice made from a card: the two sessions' files must say the same thing. card1 is a
-- live session (a status file), or the tick's orphan sweep drops its resolved file at once.
local now = os.time()
write(T .. "/status/card1.json", json.encode({ status = "idle", session_id = "card1", name = "shop", cwd = PROJ,
  since = now, updated = now, editor = "kitty" }))
post({ a = "set-policy", v = "card1", text = "read-only" })
local kept = decoded(POLICY .. "/new1") or {}
eq("a tick keeps the spawned session's bundle (re-resolved from its choice, not swept)", kept.bundle, "read-only")
eq("the card's Policy dropdown writes the same choice", read(OVERRIDE .. "/card1"), read(OVERRIDE .. "/new1"))
local card = decoded(POLICY .. "/card1") or {}
eq("the card's resolved policy names the bundle", card.bundle, "read-only")
check("...and the spawned session's is the same",
      card.bundle == got.bundle and list(card.autoDeny) == list(got.autoDeny)
      and list(card.autoAllow) == list(got.autoAllow) and card.autopilot == got.autopilot)

-- taken once: the next session to start in that folder is a session Adam started himself
sessionStart("new2", PROJ)
check("the next session to start in that folder gets no bundle", not exists(OVERRIDE .. "/new2") and not exists(POLICY .. "/new2"))
local function pendingLeft() return (sh("ls -1A '" .. NOTES .. "/pending' 2>/dev/null"):gsub("%s+$", "")) end
local left = pendingLeft()
eq("...and nothing is left pending", left, "")

-- a resumed session keeps whatever it had; only a fresh start takes the bundle
spawn(PROJ, "reviewer")
sessionStart("resumed1", PROJ, "resume")
check("a resumed session in that folder doesn't take a spawn's bundle", not exists(OVERRIDE .. "/resumed1"))
sessionStart("new3", PROJ)
eq("...the session the spawn started does", read(OVERRIDE .. "/new3"), "read-only")

-- a profile with no bundle, and a spawn that launched nothing, leave nothing for anyone
spawn(PLAIN, "helper")
sessionStart("plain1", PLAIN)
check("a profile with no bundle gives its session none", not exists(OVERRIDE .. "/plain1") and not exists(POLICY .. "/plain1"))
write(C .. "/cc-config.json", json.encode({ spawn = { live = false, editor = "kitty" },
  remoteControl = { onSpawn = false }, policies = { bundles = { ["read-only"] = BUNDLE } } }))
local before = #tasks
spawn(PROJ, "reviewer")
check("a dry-run profile spawn launches nothing", #tasks == before)
sessionStart("dry1", PROJ)
check("...and leaves no bundle for a session Adam starts there", not exists(OVERRIDE .. "/dry1"))

-- an ssh spawn's session starts on its own host, whose hook never reads this one's pending folder
write(C .. "/cc-config.json", json.encode({ spawn = { live = true, editor = "kitty" },
  remoteControl = { onSpawn = false }, policies = { bundles = { ["read-only"] = BUNDLE } },
  providers = { { id = "box", kind = "anthropic", ssh = { host = "devbox" } } } }))
before = #tasks
post({ a = "spawn", v = "", text = "", img = "", mode = "existing", dir = PROJ, editor = "kitty",
       permMode = "", provider = "box", agent = "reviewer" })
check("(the ssh profile spawn launched)", #tasks == before + 1)
eq("an ssh spawn leaves no bundle where only a local session could take it", pendingLeft(), "")

-- a bundle nobody took for 10 minutes belongs to a launch that never came: dropped, not applied
write(C .. "/cc-config.json", json.encode({ spawn = { live = true, editor = "kitty" },
  remoteControl = { onSpawn = false }, policies = { bundles = { ["read-only"] = BUNDLE } } }))
spawn(PROJ, "reviewer")
check("(the spawn left one pending)", pendingLeft() ~= "")
sh("for f in '" .. NOTES .. "/pending/'*; do touch -t " .. os.date("%Y%m%d%H%M", os.time() - 11 * 60) .. " \"$f\"; done")
sessionStart("late1", PROJ)
check("a spawn's bundle older than 10 minutes isn't applied", not exists(OVERRIDE .. "/late1"))
left = pendingLeft()
eq("...and is dropped", left, "")

sh("rm -rf '" .. T .. "'")
finish()
