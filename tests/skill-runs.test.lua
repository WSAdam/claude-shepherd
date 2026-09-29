-- skill-runs.test.lua : how often each skill works, wired under a STUBBED Hammerspoon (2026-09-29,
-- build program unit 35). Drives the real dashboard:
--   * the time index (FX.refreshTimeIndex, unit 34) folds skill runs from real temp transcripts in
--     its background pass -- never the tick -- and a grown transcript adds only its new runs;
--   * FX.mcpSkillsPayload carries every skill's runs to the 🔌 viewer; opening the viewer asks the
--     index for a pass, and a pass that lands while it is open re-pushes them (window.ccSkillRuns);
--   * the "skill-label" click writes Adam's label to ~/.claude/cc-skill-labels.json atomically
--     (temp + rename), refuses a bad id or verdict, clears, and re-pushes;
--   * the labels file is Adam's: FX.removeStatus (the session remover) leaves it alone.
-- Each task's shell command runs for real. Side-effect-free: a temp HOME holds everything.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end

local HOME
do
  local p = io.popen("mktemp -d 2>/dev/null"); HOME = p and p:read("*l"); if p then p:close() end
  assert(HOME and HOME ~= "", "could not mktemp a HOME")
  os.execute("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/.claude/skills/simplify' '" .. HOME .. "/status' '"
    .. HOME .. "/tr'")
end
local LABELS = HOME .. "/.claude/cc-skill-labels.json"
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function appendFile(path, s) local f = assert(io.open(path, "a")); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function sizeOf(path) local f = io.open(path, "rb"); if not f then return nil end; local n = f:seek("end"); f:close(); return n end
local function ls(dir)
  local out = {}
  local p = io.popen("ls -1A '" .. dir .. "' 2>/dev/null")
  if p then for n in p:lines() do out[#out + 1] = n end; p:close() end
  return out
end

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local js = {}   -- every evaluateJavaScript the panel ran
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) js[#js + 1] = s end },
    { __index = function() return function() return webviewHandle() end end })
end
local panelCb
local tasks = {}
local json = dofile(HERE .. "support/json.lua")
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local mtimes = {}
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local names = ls(tostring(path))
      local i = 0
      return function() i = i + 1; return names[i] end, nil
    end,
    attributes = function(p, attr)
      p = tostring(p)
      local isDir = os.execute("test -d '" .. p .. "'")
      if isDir == true or isDir == 0 then
        local t = { mode = "directory", size = 0, modification = 1 }
        if attr then return t[attr] end
        return t
      end
      local n = sizeOf(p)
      if not n then return nil end
      local t = { mode = "file", size = n, modification = mtimes[p] or 1 }
      if attr then return t[attr] end
      return t
    end,
    symlinkAttributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = {
    new = function(path, cb, args)
      local t = { path = path, cb = cb, args = args }
      function t:start() self.started = true; return self end
      function t:terminate() self.terminated = true end
      function t:setWorkingDirectory() end
      tasks[#tasks + 1] = t
      return t
    end,
  },
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
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) panelCb = fn end }, { __index = function() return function() return mkstub() end end })
  end },
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
if not ok then print("       " .. tostring(err)); print(string.format("-- skill-runs.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core
local function click(a, v, text) panelCb({ body = json.encode({ a = a, v = v or "", text = text or "" }) }) end

local function timeTasks()
  local out = {}
  for _, t in ipairs(tasks) do
    if t.args and type(t.args[2]) == "string" and t.args[2]:find("/cc-scratch/time-", 1, true) then out[#out + 1] = t end
  end
  return out
end
local function finish(t, code) os.execute(t.args[2]); t.cb(code or 0, "", "") end
local function lastCall(fn)
  for i = #js, 1, -1 do
    local body = js[i]:match("^window%." .. fn .. "%((.*)%)$")
    if body then return json.decode(body) end
  end
  return nil
end

-- a skill on disk, and a session that ran it
writeFile(HOME .. "/.claude/skills/simplify/SKILL.md", "---\nname: simplify\ndescription: Review the changed code\n---\nbody\n")
local function T(n) local s = 36000 + n; return string.format("2026-09-29T%02d:%02d:%02d.000Z", s // 3600, (s % 3600) // 60, s % 60) end
local function prompt(n, text) return '{"type":"user","message":{"role":"user","content":' .. json.encode(text) .. '},"origin":{"kind":"human"},"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '"}\n' end
local function skillUse(n, id, skill) return '{"message":{"model":"claude-opus-5","id":"m' .. n .. '","type":"message","role":"assistant","content":[{"type":"tool_use","id":"' .. id .. '","name":"Skill","input":{"skill":"' .. skill .. '"}}]},"type":"assistant","uuid":"a' .. n .. '","timestamp":"' .. T(n) .. '"}\n' end
local function editBy(n, skill) return '{"message":{"model":"claude-opus-5","id":"m' .. n .. '","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_e' .. n .. '","name":"Edit","input":{"file_path":"/r/a.lua","old_string":"a","new_string":"b"}}]},"attributionSkill":"' .. skill .. '","type":"assistant","uuid":"a' .. n .. '","timestamp":"' .. T(n) .. '"}\n' end
local function stopHook(n) return '{"type":"system","subtype":"stop_hook_summary","timestamp":"' .. T(n) .. '","uuid":"s' .. n .. '"}\n' end
local TR = HOME .. "/tr/s1.jsonl"
local function write(path, s, mode) if mode == "a" then appendFile(path, s) else writeFile(path, s) end; mtimes[path] = (mtimes[path] or 1) + 1 end
write(TR, prompt(0, "tidy <b>the</b> login module") .. skillUse(1, "toolu_s1", "simplify") .. editBy(5, "simplify") .. stopHook(9))
-- the session's status file, so the tick lists it (the index and the viewer read the tick's list)
writeFile(HOME .. "/status/k1.json", json.encode({ session_id = "s1", name = "Login work", cwd = HOME .. "/tr", status = "idle",
  transcript_path = TR, updated = os.time() }))

-- 1. the tick reads nothing; the index's own pass folds the run
local before = #timeTasks()
local okTick, tickErr = pcall(function() FX._refreshBody() end)
check("the tick runs  (" .. tostring(tickErr) .. ")", okTick)
check("the tick starts no index pass", #timeTasks() == before)
FX.refreshTimeIndex(true)
finish(timeTasks()[#timeTasks()])
local e = FX._timeIndex.entries[TR]
check("the index's pass folds the skill run", e and e.episodes and #e.episodes == 1 and e.episodes[1].id == "toolu_s1")

-- 2. the viewer's payload: the card's skill has its runs
local p = FX.mcpSkillsPayload()
local r = p and p.runs
local s = r and r.bySkill and r.bySkill.simplify
check("the 🔌 payload carries each skill's runs", s ~= nil and s.runs == 1 and s.ok == 1 and s.rate == 100)
check("...a run names the session it ran in", s and s.rows[1].session == "Login work")
check("...and its goal", s and s.rows[1].goal == "tidy <b>the</b> login module")
check("...the index is on", r and r.enabled == true)

-- 3. opening the viewer asks the index for a pass; one landing while it's open re-pushes the runs
write(TR, prompt(20, "again") .. skillUse(21, "toolu_s2", "simplify") .. stopHook(22), "a")
local n0 = #timeTasks()
js = {}
click("open-mcpskills-view")
check("opening the viewer pushes it", lastCall("ccMcpSkills") ~= nil)
check("...and asks the index for a pass", #timeTasks() == n0 + 1)
finish(timeTasks()[#timeTasks()])
local pushed = lastCall("ccSkillRuns")
check("a pass that lands while the viewer is open re-pushes the runs", pushed and pushed.bySkill and pushed.bySkill.simplify
      and pushed.bySkill.simplify.runs == 2)
check("...a grown transcript added only its new run", #FX._timeIndex.entries[TR].episodes == 2)
check("...the older run's id is unchanged, so its label will still find it", FX._timeIndex.entries[TR].episodes[1].id == "toolu_s1")

-- 4. Adam labels a run: written atomically, re-pushed, the hand label winning
js = {}
click("skill-label", "toolu_s1", "not ok")
local st = core.skillLabelsParse(readFile(LABELS))
check("a label is written to ~/.claude/cc-skill-labels.json", st.labels.toolu_s1 and st.labels.toolu_s1.verdict == "not ok"
      and st.labels.toolu_s1.skill == "simplify")
local left = {}
for _, n in ipairs(ls(HOME .. "/.claude")) do if n:find("cc-skill-labels", 1, true) and n ~= "cc-skill-labels.json" then left[#left + 1] = n end end
check("...through temp + rename (no temp left behind)", #left == 0)
pushed = lastCall("ccSkillRuns")
local row
for _, x in ipairs(pushed and pushed.bySkill.simplify.rows or {}) do if x.id == "toolu_s1" then row = x end end
check("...and the runs are re-pushed with the label winning", row and row.label == "not ok" and row.derived == "ok"
      and row.verdict == "not ok" and pushed.bySkill.simplify.labelled == 1)
local saved = readFile(LABELS)
click("skill-label", "../../etc/passwd", "ok")
click("skill-label", "toolu_s1", "maybe")
check("a bad id or verdict is refused and nothing is written", readFile(LABELS) == saved)
click("skill-label", "toolu_s1", "clear")
check("a label is cleared", core.skillLabelsParse(readFile(LABELS)).labels.toolu_s1 == nil)
click("skill-label", "toolu_s2", "ok")

-- 5. closing the viewer stops the pushes
click("close-mcpskills-view")
write(TR, prompt(30, "third") .. skillUse(31, "toolu_s3", "simplify") .. stopHook(32), "a")
js = {}
FX.refreshTimeIndex(true)
finish(timeTasks()[#timeTasks()])
check("a pass while the viewer is closed pushes nothing", lastCall("ccSkillRuns") == nil)

-- 6. the labels file is Adam's: the session remover leaves it alone
FX.removeStatus("k1")
check("FX.removeStatus leaves cc-skill-labels.json", exists(LABELS) and core.skillLabelsParse(readFile(LABELS)).labels.toolu_s2 ~= nil)

-- 7. the time index off: no runs, and the payload says so
writeFile(HOME .. "/.claude/cc-config.json", json.encode({ timeLost = { enabled = false } }))
FX.refreshTimeIndex(true)
p = FX.mcpSkillsPayload()
check("with the time index off the viewer says so", p.runs and p.runs.enabled == false)
check("the skill-run functions are live", type(core.skillOutcomes) == "function" and type(FX.skillRunsPayload) == "function")

os.execute("rm -r '" .. HOME .. "' 2>/dev/null")
print(string.format("-- skill-runs.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
