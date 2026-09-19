-- reap-session-files.test.lua : BEHAVIORAL fixture for the two per-key reapers (2026-09-19).
-- 2026-09-19: cc-merge.sh parks an answer that isn't its own as <key>.decision.parked.<pid>
-- (cc-merge.sh: the `ln` fallback). Neither remover knew that shape -- cc_remove lists
-- .decision.claim.* and FX.removeStatus sweeps the prefix "<key>.decision.claim." -- so a
-- parked answer whose session ended before it won a claim of its own stayed in
-- ~/.claude/cc-merge for good. Keys are UUIDs, so nothing ever matched it again.
-- Same class, same two functions: the write-temps (<key>.json.tmp.<pid> from cc-status.sh and
-- cc-lib.sh, .answer.tmp / .decision.tmp from FX.writeFileAtomic) leak on a crash between the
-- redirect and the rename.
-- This drives the REAL FX.removeStatus (dashboard under a stubbed hs) and the REAL cc_remove
-- over a temp tree, rather than pinning source text. Side-effect-free: everything is in a
-- temp dir, HOME included.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish()
  print("-- reap-session-files.test.lua: " .. run .. " run, " .. failed .. " failed --")
  os.exit(failed == 0 and 0 or 1)
end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end

local STATUS, MERGE, ASK = T .. "/status", T .. "/cc-merge", T .. "/cc-ask"
os.execute(('mkdir -p "%s" "%s" "%s" "%s/repo"'):format(STATUS, MERGE, ASK, T))
local function write(path, s) local f = io.open(path, "w"); if f then f:write(s); f:close() end end
local function exists(p) local h = io.open(p, "r"); if h then h:close(); return true end; return false end

-- The per-key file family as the hooks really write it, for one session key.
local KEY = "k9"
local function plant()
  local now = os.time()
  write(STATUS .. "/" .. KEY .. ".json", ('{"status":"done","session_id":"%s","name":"repo","cwd":"%s","since":%d,"updated":%d}')
    :format(KEY, T .. "/repo", now - 60, now - 60))
  write(STATUS .. "/" .. KEY .. ".decision", '{"verdict":"approve"}')
  write(STATUS .. "/" .. KEY .. ".decision.claim.4242", '{"verdict":"approve"}')
  write(STATUS .. "/" .. KEY .. ".decision.claim.4242.parked.1", '{"verdict":"approve"}')
  write(STATUS .. "/" .. KEY .. ".decision.note", "not like that")
  write(STATUS .. "/" .. KEY .. ".decision.note.tmp.4242", "not like that")
  -- torn writes: cc-status.sh:99/448 and cc-lib.sh:266/293 (shell), FX.writeFileAtomic (panel)
  write(STATUS .. "/" .. KEY .. ".json.tmp.4242", "{")
  write(MERGE .. "/" .. KEY .. ".json", '{"phase":"requested"}')
  write(MERGE .. "/" .. KEY .. ".decision", '{"verdict":"merge","nonce":"n1"}')
  write(MERGE .. "/" .. KEY .. ".decision.claim.4242", '{"verdict":"merge","nonce":"n1"}')
  -- the one that started this: cc-merge.sh parks a foreign answer under its OWN shape
  write(MERGE .. "/" .. KEY .. ".decision.parked.4242", '{"verdict":"merge","nonce":"other"}')
  write(MERGE .. "/" .. KEY .. ".decision.tmp.5150", '{"verdict":')
  write(ASK .. "/" .. KEY .. ".answer", '{"answers":{}}')
  write(ASK .. "/" .. KEY .. ".answer.claim.4242", '{"answers":{}}')
  write(ASK .. "/" .. KEY .. ".answer.tmp.5150", '{"answers"')
end

-- Every file above must be gone after a reap. Named for what it is, so a failure reads as
-- "the parked merge answer survived", not "file 11 survived".
local TARGETS = {
  { "the status file",                 STATUS .. "/" .. KEY .. ".json" },
  { "an approval decision",            STATUS .. "/" .. KEY .. ".decision" },
  { "a claimed approval decision",     STATUS .. "/" .. KEY .. ".decision.claim.4242" },
  { "a parked approval decision",      STATUS .. "/" .. KEY .. ".decision.claim.4242.parked.1" },
  { "the deny note",                   STATUS .. "/" .. KEY .. ".decision.note" },
  { "a torn deny note",                STATUS .. "/" .. KEY .. ".decision.note.tmp.4242" },
  { "a torn status write",             STATUS .. "/" .. KEY .. ".json.tmp.4242" },
  { "the merge request",               MERGE .. "/" .. KEY .. ".json" },
  { "the merge answer",                MERGE .. "/" .. KEY .. ".decision" },
  { "a claimed merge answer",          MERGE .. "/" .. KEY .. ".decision.claim.4242" },
  { "a PARKED merge answer",           MERGE .. "/" .. KEY .. ".decision.parked.4242" },
  { "a torn merge answer",             MERGE .. "/" .. KEY .. ".decision.tmp.5150" },
  { "the answer to a held question",   ASK .. "/" .. KEY .. ".answer" },
  { "a claimed answer",                ASK .. "/" .. KEY .. ".answer.claim.4242" },
  { "a torn answer",                   ASK .. "/" .. KEY .. ".answer.tmp.5150" },
}

-- A second session's files must SURVIVE both reaps -- a prefix sweep must not eat the fleet.
local OTHER = {
  STATUS .. "/k90.json", MERGE .. "/k90.decision.parked.4242", ASK .. "/k90.answer.tmp.5150",
}
local function plantOther() for _, p in ipairs(OTHER) do write(p, "{}") end end

-- ---- cc_remove (the shell side, SessionEnd) ----
plant(); plantOther()
check("(fixture: the parked merge answer exists before the reap)",
      exists(MERGE .. "/" .. KEY .. ".decision.parked.4242"))
os.execute(([[
  export CC_STATUS_DIR=%q CC_MERGE_DIR=%q CC_ASK_DIR=%q
  export CC_GATE_TOOLS_DIR=%q CC_APPROVED_DIR=%q CC_AUTOPILOT_DIR=%q
  export CC_POLICY_DIR=%q CC_POLICY_OVERRIDE_DIR=%q CC_AUTOMODEL_DIR=%q
  . %q; cc_remove %s
]]):format(STATUS, MERGE, ASK, T .. "/gt", T .. "/ap", T .. "/au",
           T .. "/po", T .. "/pov", T .. "/am", ROOT .. "cc-lib.sh", KEY) .. " >/dev/null 2>&1")
for _, t in ipairs(TARGETS) do
  check("cc_remove drops " .. t[1], not exists(t[2]))
end
for _, p in ipairs(OTHER) do
  check("cc_remove leaves another session's " .. p:match("[^/]+$") .. " alone", exists(p))
end

-- ---- FX.removeStatus (the panel side: ghost prune, Forget tile, auto-respawn) ----
plant(); plantOther()

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
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
    attributes = function() return nil, "no such file" end,
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

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = STATUS, CC_MERGE_DIR = MERGE, CC_ASK_DIR = ASK,
              CC_GATE_TOOLS_DIR = T .. "/gt", CC_APPROVED_DIR = T .. "/ap",
              CC_AUTOPILOT_DIR = T .. "/au", CC_POLICY_DIR = T .. "/po",
              CC_POLICY_OVERRIDE_DIR = T .. "/pov", CC_AUTOMODEL_DIR = T .. "/am",
              CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              HOME = T }
os.getenv = function(k) if ENV[k] ~= nil then return ENV[k] end; return realGetenv(k) end

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads", ok)
if not ok then print("       " .. tostring(err)); finish() end
local fx = rawget(_G, "__ccDashboard").fx

quiet(function() fx.removeStatus(KEY) end)
for _, t in ipairs(TARGETS) do
  check("FX.removeStatus drops " .. t[1], not exists(t[2]))
end
for _, p in ipairs(OTHER) do
  check("FX.removeStatus leaves another session's " .. p:match("[^/]+$") .. " alone", exists(p))
end

os.execute('rm -rf "' .. T .. '"')
finish()
