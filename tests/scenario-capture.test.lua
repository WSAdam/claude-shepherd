-- scenario-capture.test.lua : "Capture as scenario" under a STUBBED Hammerspoon (2026-09-29).
-- A card's transcript window is scrubbed by the installed ~/.claude/cc-scrub.js and saved to
-- ~/.claude/cc-scenarios/ with a label to fill in -- never into a repo -- so a moment where a
-- detector got it wrong can be labelled and replayed (tests/scenario-replay.test.lua --captures).
-- Drives the real FX.captureScenario in a temp HOME; hs.task runs the scrubber for real (node),
-- everything else hs does is stubbed.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local HOME = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(HOME ~= "", "could not mktemp a HOME")
local SCEN = HOME .. "/.claude/cc-scenarios"
sh("mkdir -p " .. q(HOME .. "/.claude/cc-scratch") .. " " .. q(HOME .. "/.claude/cc-ledger") .. " " .. q(HOME .. "/status"))

local json = dofile(HERE .. "support/json.lua")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function listing(dir) return sh("ls -1 " .. q(dir) .. " 2>/dev/null") end

-- the session: a readable transcript well over the 64KB the tick reads -- turn after turn about the
-- zebra module -- ending on a turn that edited quokka.ts and stopped
local TRANSCRIPT = HOME .. "/sid-1.jsonl"
local function rec(t) return json.encode(t) .. "\n" end
local function at(n) return string.format("2026-09-29T08:%02d:%02d.000Z", n // 60 % 60, n % 60) end
local parts = {}
for i = 1, 120 do
  local t = i * 20
  parts[#parts + 1] = rec({ type = "user", origin = { kind = "human" }, timestamp = at(t),
    message = { role = "user", content = { { type = "text", text = "step " .. i .. " of the zebra refactor, please" } } } })
  parts[#parts + 1] = rec({ type = "assistant", timestamp = at(t + 5), message = { role = "assistant",
    content = { { type = "tool_use", id = "toolu_" .. i, name = "Bash", input = { command = "make test" } } } } })
  parts[#parts + 1] = rec({ type = "user", timestamp = at(t + 9), message = { role = "user",
    content = { { type = "tool_result", tool_use_id = "toolu_" .. i, content = string.rep("zebra quokka suite green ", 20) } } } })
  parts[#parts + 1] = rec({ type = "assistant", timestamp = at(t + 12), message = { role = "assistant",
    content = { { type = "text", text = "Step " .. i .. " of the zebra refactor is done; the suite is green." } } } })
end
parts[#parts + 1] = rec({ type = "user", origin = { kind = "human" }, timestamp = "2026-09-29T09:00:00.000Z",
  message = { role = "user", content = { { type = "text", text = "rename the zebra module" } } } })
parts[#parts + 1] = rec({ type = "assistant", timestamp = "2026-09-29T09:00:03.000Z", message = { role = "assistant",
  content = { { type = "tool_use", id = "toolu_z", name = "Edit", input = { file_path = "/src/quokka.ts", old_string = "zebra", new_string = "okapi" } } } } })
parts[#parts + 1] = rec({ type = "user", timestamp = "2026-09-29T09:00:04.000Z", message = { role = "user",
  content = { { type = "tool_result", tool_use_id = "toolu_z", content = "The file /src/quokka.ts has been updated." } } } })
parts[#parts + 1] = rec({ type = "assistant", timestamp = "2026-09-29T09:00:05.000Z", message = { role = "assistant",
  content = { { type = "text", text = "Renamed the zebra module in quokka.ts." } } } })
writeFile(TRANSCRIPT, table.concat(parts))
local FIXTURE_LISTING = listing(ROOT .. "tests/fixtures/transcripts")

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

-- ---- the stubbed Hammerspoon surface (as tests/handoff.test.lua), with a task that really runs ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function attributes(p, k)
  local out = sh("stat -c '%F|%Y' " .. q(p) .. " 2>/dev/null || stat -f '%HT|%m' " .. q(p) .. " 2>/dev/null")
  local kind, mtime = out:match("^([^|]+)|(%d+)")
  if not kind then return nil end
  local a = { mode = kind:lower():find("directory", 1, true) and "directory" or "file", modification = tonumber(mtime) }
  if k then return a[k] end
  return a
end
-- hs.task: records every task; start() runs its argv for real and calls back as Hammerspoon does
local tasks = {}
local function newTask(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, started = false }
  function t:start()
    self.started = true
    local cmd = q(self.bin)
    for _, a in ipairs(self.args) do cmd = cmd .. " " .. q(a) end
    local errFile = HOME .. "/task.err"
    local p = io.popen(cmd .. " 2>" .. q(errFile) .. "; echo \"@@rc=$?\"")
    local out = p:read("*a"); p:close()
    local rc = tonumber(out:match("@@rc=(%d+)%s*$"))
    self.rc = rc
    if self.cb then self.cb(rc, out:gsub("@@rc=%d+%s*$", ""), readAll(errFile) or "") end
    return self
  end
  function t:isRunning() return false end
  function t:terminate() end
  function t:setWorkingDirectory() return self end
  tasks[#tasks + 1] = t
  return t
end
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1a "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = attributes,
    symlinkAttributes = function() return nil end,
    mkdir = function(p) sh("mkdir " .. q(p) .. " 2>/dev/null"); return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd, withShell)
    if withShell and tostring(cmd):match("^command %-v node$") then return sh("command -v node") end
    return ""
  end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = { new = newTask },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
check("the dashboard loads under the stub", ok)
if not ok then print("       " .. tostring(err)); print(string.format("-- scenario-capture.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core
local toasts = {}
local realAlert = FX.alert
FX.alert = function(msg, ...) toasts[#toasts + 1] = tostring(msg); if realAlert then return realAlert(msg, ...) end end

eq("captures live in ~/.claude/cc-scenarios", FX.SCENARIO_DIR, SCEN)
eq("the scrubber is the one make install ships to ~/.claude", FX.SCRUBBER, HOME .. "/.claude/cc-scrub.js")

-- ---- not installed yet: nothing runs, and the toast says what to do -------------------------
-- 2026-09-30: `updated` was os.time(), so from the day after it was written the card's "done"
-- landed a day past its 2026-09-29 transcript and the scrubbed `since` read 2026-01-02. The card
-- read done a minute after its transcript's last record.
local it = { key = "k1", name = "zebra-proj", status = "done", updated = core.isoToEpoch("2026-09-29T09:01:05.000Z"), cwd = HOME, transcript_path = TRANSCRIPT }
toasts = {}
check("without the installed scrubber there is no capture", FX.captureScenario(it) == nil)
eq("...and no task", #tasks, 0)
check("...and the toast says to install it  (" .. tostring(toasts[1]) .. ")",
      toasts[1] ~= nil and toasts[1]:find("cc-scrub.js", 1, true) ~= nil and toasts[1]:find("make install", 1, true) ~= nil)

-- ---- a done card, captured --------------------------------------------------------------------
sh("cp " .. q(ROOT .. "cc-scrub.js") .. " " .. q(HOME .. "/.claude/cc-scrub.js"))
toasts = {}
local plan = FX.captureScenario(it)
check("a done card with a transcript is captured", type(plan) == "table")
plan = plan or {}
eq("...through one retained task", #tasks, 1)
check("...that ran node on the installed scrubber", tasks[1] and tasks[1].bin:match("node$") ~= nil and tasks[1].args[1] == FX.SCRUBBER)
eq("...which exited 0", tasks[1] and tasks[1].rc, 0)
eq("...and let go of the task when it finished", FX._scenarioTasks[plan.name or ""], nil)
local window = plan.out and readAll(plan.out) or ""
check("the window is in ~/.claude/cc-scenarios", plan.out and plan.out:sub(1, #SCEN + 1) == SCEN .. "/" and #window > 0)
check("...scrubbed: none of the session's words survive", not window:find("zebra", 1, true) and not window:find("quokka", 1, true))
check("...cut the size the tick reads, plus the lead-in line it drops", #window > 60000 and #window <= core.SCENARIO_WINDOW + 1024)
local label = plan.label and json.decode(readAll(plan.label) or "null") or nil
check("its label is beside it", type(label) == "table")
label = label or {}
eq("the label names the window", label.fixture, (plan.out or ""):match("([^/]+)$"))
eq("...and the tail to read it back with", label.window, core.SCENARIO_WINDOW)
eq("...says how the card read", label.status, "done")
check("...and when it last read done, on the window's clock", type(label.since) == "string" and label.since:match("^2026%-01%-01T") ~= nil)
local said = core.scenarioVerdicts(FX.readTail(TRANSCRIPT, core.SCENARIO_WINDOW), { since = it.updated })
eq("...records what Shepherd's detectors said on the raw transcript", label.said and label.said.turn, said.turn)
check("...with every verdict left blank to fill in (null)", type(label.expect) == "table" and next(label.expect) == nil)
check("the toast says where it went", toasts[#toasts] and toasts[#toasts]:find(plan.out or "?", 1, true) ~= nil)
check("nothing was written into the repo's fixtures", listing(ROOT .. "tests/fixtures/transcripts") == FIXTURE_LISTING)

-- the corpus replays a filled-in label as it is
writeFile(plan.label, ((readAll(plan.label) or ""):gsub('"expect":%s*%b{}', '"expect": {"turn": "made progress"}')))
local rep = sh("lua " .. q(ROOT .. "tests/scenario-replay.test.lua") .. " --captures " .. q(SCEN) .. " 2>&1")
check("the corpus replays your labelled captures  (" .. (rep:match("Accuracy over [^\n]*") or rep:sub(1, 200)) .. ")",
      rep:find("Accuracy over 1 labelled capture", 1, true) ~= nil)

-- a second capture in the same second never overwrites the first
local plan2 = FX.captureScenario(it)
check("a second capture gets its own name", plan2 and plan2.out ~= plan.out and exists(plan2.out))

-- ---- what can't be captured -----------------------------------------------------------------
local before = #tasks
toasts = {}
check("a card with no transcript isn't captured", FX.captureScenario({ key = "k2", name = "p", status = "done" }) == nil)
check("...and says so  (" .. tostring(toasts[1]) .. ")", toasts[1] ~= nil and toasts[1]:find("transcript", 1, true) ~= nil)
toasts = {}
check("a card whose transcript is gone isn't captured",
      FX.captureScenario({ key = "k3", name = "p", status = "done", transcript_path = HOME .. "/gone.jsonl" }) == nil)
check("...and says so  (" .. tostring(toasts[1]) .. ")", toasts[1] ~= nil and toasts[1]:find("transcript", 1, true) ~= nil)
toasts = {}
check("a remote session isn't captured (its transcript is on another machine)",
      FX.captureScenario({ key = "k4", name = "p", status = "done", remote = true, transcript_path = TRANSCRIPT }) == nil)
eq("...none of them ran anything", #tasks, before)

-- a torn last line (the writer mid-record, as a live capture often meets it) is masked whole, not fatal
toasts = {}
local torn = HOME .. "/torn.jsonl"
writeFile(torn, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"zebra\"}}\n{\"type\":\"assistant\",\"message\":{\"con")
local tornPlan = FX.captureScenario({ key = "k6", name = "p", status = "working", transcript_path = torn })
local tornOut = tornPlan and readAll(tornPlan.out) or ""
check("a transcript torn mid-record is still captured", tornOut ~= "" and not tornOut:find("zebra", 1, true))
eq("...its torn line masked whole, same length", tornOut:match("\n([^\n]*)$"), '{"xxxx":"xxxxxxxxx","xxxxxxx":{"xxx')

-- the scrubber failing is said out loud, and leaves no half-written window behind: a line whose
-- bytes JSON can't reproduce (a space after a colon -- Claude Code never writes one) would tear
-- the window somewhere else, so the scrubber refuses the whole capture
toasts = {}
local bad = HOME .. "/bad.jsonl"
writeFile(bad, "{\"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": \"a\"}}\n")
local badPlan = FX.captureScenario({ key = "k5", name = "p", status = "working", transcript_path = bad })
check("a transcript the scrubber can't read fails the capture  (" .. tostring(toasts[#toasts]) .. ")",
      toasts[#toasts] ~= nil and toasts[#toasts]:lower():find("fail", 1, true) ~= nil)
check("...leaving no window", badPlan == nil or not exists(badPlan.out))

sh("rm -r " .. q(HOME))
print(string.format("-- scenario-capture.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
