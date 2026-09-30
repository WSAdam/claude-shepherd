-- usage-totals.test.lua : the fleet token/cost totals under a STUBBED Hammerspoon (2026-09-28).
-- 2026-09-28: Claude Code writes one assistant record per content block, each repeating the whole
-- message's usage, and FX.computeUsage summed every record; it also never read the session's
-- subagent transcripts (<sid>/subagents/*.jsonl), and a line torn at the read boundary was skipped
-- for good. Drives the real FX.computeUsage over a fixture transcript and checks what reaches the
-- panel. Side-effect-free: a temp HOME holds the status file and the transcripts.

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

local HOME
do
  local p = io.popen("mktemp -d 2>/dev/null"); HOME = p and p:read("*l"); if p then p:close() end
  assert(HOME and HOME ~= "", "could not mktemp a HOME")
  os.execute("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/.claude/cc-ledger' '" .. HOME .. "/status' '" .. HOME .. "/proj/s1/subagents'")
end
local json = dofile(HERE .. "support/json.lua")
local function writeFile(path, s, mode) local f = assert(io.open(path, mode or "w")); f:write(s); f:close() end

local TRANSCRIPT = HOME .. "/proj/s1.jsonl"
local SUBAGENT = HOME .. "/proj/s1/subagents/agent-a1.jsonl"
local NOW = os.time()
local function rec(id, block, u, model)
  return json.encode({ type = "assistant", timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z", NOW - 60),
    message = { model = model or "claude-opus-5-5", id = id, type = "message", role = "assistant",
      content = { { type = block } }, usage = u } })
end
local uA = { input_tokens = 2, output_tokens = 134, cache_read_input_tokens = 25792, cache_creation_input_tokens = 21302,
             cache_creation = { ephemeral_1h_input_tokens = 21302, ephemeral_5m_input_tokens = 0 } }
local uB = { input_tokens = 1, output_tokens = 50, cache_read_input_tokens = 47094, cache_creation_input_tokens = 300,
             cache_creation = { ephemeral_1h_input_tokens = 300, ephemeral_5m_input_tokens = 0 } }
local uC = { input_tokens = 3, output_tokens = 70, cache_read_input_tokens = 47394, cache_creation_input_tokens = 900,
             cache_creation = { ephemeral_1h_input_tokens = 900, ephemeral_5m_input_tokens = 0 } }
local uS = { input_tokens = 5, output_tokens = 400, cache_read_input_tokens = 10000, cache_creation_input_tokens = 8000,
             cache_creation = { ephemeral_1h_input_tokens = 0, ephemeral_5m_input_tokens = 8000 } }
-- message A over three records, B once, then C torn mid-line (no newline yet)
local lineC = rec("msg_C", "text", uC)
local cut = math.floor(#lineC / 2)
writeFile(TRANSCRIPT, rec("msg_A", "thinking", uA) .. "\n" .. rec("msg_A", "text", uA) .. "\n"
  .. rec("msg_A", "tool_use", uA) .. "\n" .. '{"type":"user","message":{"role":"user","content":"ok"}}' .. "\n"
  .. rec("msg_B", "text", uB) .. "\n" .. lineC:sub(1, cut))
writeFile(SUBAGENT, rec("msg_S", "text", uS, "claude-sonnet-5") .. "\n" .. rec("msg_S", "tool_use", uS, "claude-sonnet-5") .. "\n")
writeFile(HOME .. "/status/s1.json", json.encode({ name = "s1", status = "working", session_id = "s1",
  cwd = HOME .. "/proj", transcript_path = TRANSCRIPT, updated = NOW, since = NOW }))
-- the ledger on, so the 10-minute usage snapshot (the Cost overlay's history) is written too
writeFile(HOME .. "/.claude/cc-config.json", json.encode({ ledger = { enabled = true } }))

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

-- ---- the stubbed Hammerspoon surface (as tests/commits-refresh.test.lua) ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(p, k)
      if not exists(tostring(p)) then return nil end
      if k == "modification" then return 1 end
      return { mode = "file", modification = 1 }
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
  task = { new = function() return mkstub() end },
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
if not ok then print("       " .. tostring(err)); print(string.format("-- usage-totals.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx

local function lastUsage()
  for i = #jsCalls, 1, -1 do
    local s = jsCalls[i]:match("^window%.ccUsage%((.*)%)$")
    if s then return json.decode(s) end
  end
end

FX.computeUsage()
local p = lastUsage()
local s1 = p and p.perSession and p.perSession.s1
check("the session's totals reach the panel", s1 ~= nil)
s1 = s1 or {}
eq("a message written as three records counts once (cache reads A+B, plus the subagent's S)",
   s1.cacheRead, 25792 + 47094 + 10000)
eq("output tokens: A + B + the subagent's S", s1.output, 134 + 50 + 400)
eq("cache writes include the subagent's", s1.cacheCreate, 21302 + 300 + 8000)
check("the subagent's model is in the breakdown", s1.byModel and s1.byModel["claude-sonnet-5"] ~= nil)
-- $: Opus A+B (1h writes at $10/M) + Sonnet S (5m writes at $3.75/M)
local want = (2 + 1) / 1e6 * 5 + (134 + 50) / 1e6 * 25 + (21302 + 300) / 1e6 * 10 + (25792 + 47094) / 1e6 * 0.5
           + 5 / 1e6 * 3 + 400 / 1e6 * 15 + 8000 / 1e6 * 3.75 + 10000 / 1e6 * 0.3
check(string.format("the fleet $ prices 1-hour writes at their rate (got %.6f want %.6f)", p.fleet.costUsd or -1, want),
      math.abs((p.fleet.costUsd or 0) - want) < 1e-9)

-- the Cost overlay's snapshot carries the same session total (subagents included, priced right)
local snap
do
  local p2 = io.popen('cat "' .. HOME .. '/.claude/cc-ledger/"*.jsonl 2>/dev/null')
  for line in (p2 and p2:lines() or function() end) do
    local ok2, e = pcall(json.decode, line)
    if ok2 and type(e) == "table" and e.type == "usage_snapshot" then snap = e end
  end
  if p2 then p2:close() end
end
check("a usage snapshot is written", snap ~= nil)
eq("the snapshot's cache reads include the subagent's", snap and snap.cacheRead, 25792 + 47094 + 10000)
check(string.format("the snapshot's $ matches the fleet's (got %s)", tostring(snap and snap.estCostUsd)),
      snap and math.abs((snap.estCostUsd or 0) - want) < 1e-9)

-- the torn line completes: it must be counted, once
writeFile(TRANSCRIPT, lineC:sub(cut + 1) .. "\n", "a")
FX.computeUsage()
s1 = (lastUsage().perSession or {}).s1 or {}
eq("a line torn at the read boundary is counted once it completes", s1.cacheRead, 25792 + 47094 + 47394 + 10000)
FX.computeUsage()
s1 = (lastUsage().perSession or {}).s1 or {}
eq("a pass with nothing new changes nothing", s1.cacheRead, 25792 + 47094 + 47394 + 10000)
eq("the context bar reads the main thread's last message, not a subagent's", s1.context_tokens, 3 + 47394 + 900)

-- ---- Usage totals survive a reload (2026-09-28) ----
-- 2026-09-28: the per-transcript usage state lived only in memory, so every Hammerspoon reload
-- re-read every transcript from byte 0. It is saved to ~/.claude/cc-usage-state.json (at most every
-- 5 minutes from the usage pass, and on shutdown) and a boot resumes each transcript at its offset.
local STATE_FILE = HOME .. "/.claude/cc-usage-state.json"
local function fileSize(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local n = f:seek("end"); f:close(); return n
end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
check("the first usage pass saves the state", exists(STATE_FILE))
os.remove(STATE_FILE)
FX.computeUsage()
check("a pass within 5 minutes of the last save doesn't save again", not exists(STATE_FILE))
local shutdown = hs.shutdownCallback
check("a shutdown callback is set", type(shutdown) == "function")
if type(shutdown) == "function" then pcall(shutdown) end
check("the shutdown callback (a reload) saves the state", exists(STATE_FILE))
local savedMain, savedSub = fileSize(TRANSCRIPT), fileSize(SUBAGENT)

-- the session keeps working while Shepherd is down
local uD = { input_tokens = 4, output_tokens = 90, cache_read_input_tokens = 48294, cache_creation_input_tokens = 700,
             cache_creation = { ephemeral_1h_input_tokens = 700, ephemeral_5m_input_tokens = 0 } }
writeFile(TRANSCRIPT, rec("msg_D", "thinking", uD) .. "\n" .. rec("msg_D", "text", uD) .. "\n", "a")

-- a fresh dashboard instance, as a reload makes; every transcript read it makes is recorded
local function boot()
  jsCalls = {}
  local okB, errB = pcall(dofile, ROOT .. "claude-dashboard.lua")
  if not okB then print("       " .. tostring(errB)) end
  local fx = _G.__ccDashboard.fx
  local reads, realReadFrom = {}, fx.readFrom
  fx.readFrom = function(path, offset) reads[#reads + 1] = { path = path, offset = offset }; return realReadFrom(path, offset) end
  return okB, fx, reads
end
local function firstRead(reads, path)
  for _, r in ipairs(reads) do if r.path == path then return r.offset end end
end
local function totals(payload)
  local s = (payload and payload.perSession or {}).s1 or {}
  local sonnet = (s.byModel or {})["claude-sonnet-5"] or {}
  return { input = s.input, output = s.output, cacheRead = s.cacheRead, cacheCreate = s.cacheCreate,
           cacheCreate1h = s.cacheCreate1h, context = s.context_tokens, sonnetRead = sonnet.cacheRead,
           cost = payload and payload.fleet and payload.fleet.costUsd,
           w5h = payload and payload.window and payload.window.w5h, w7d = payload and payload.window and payload.window.w7d }
end

local ok2, FX2, reads2 = boot()
check("a second boot loads", ok2)
FX2.computeUsage()
local t2 = totals(lastUsage())
eq("the second boot resumes the transcript at its saved offset, not byte 0", firstRead(reads2, TRANSCRIPT), savedMain)
eq("...and the subagent's transcript at its own", firstRead(reads2, SUBAGENT), savedSub)
eq("...and counts what was written while it was down", t2.cacheRead, 25792 + 47094 + 47394 + 48294 + 10000)

-- the same transcripts with no saved state: read from byte 0, the totals must be identical
os.remove(STATE_FILE)
local ok3, FX3, reads3 = boot()
check("a boot with no saved state loads", ok3)
FX3.computeUsage()
local t3 = totals(lastUsage())
eq("a boot with no saved state reads from byte 0", firstRead(reads3, TRANSCRIPT), 0)
for _, k in ipairs({ "input", "output", "cacheRead", "cacheCreate", "cacheCreate1h", "context", "sonnetRead", "w5h", "w7d" }) do
  eq("resumed and full-read totals agree: " .. k, t2[k], t3[k])
end
check(string.format("resumed and full-read totals agree: $ (%s vs %s)", tostring(t2.cost), tostring(t3.cost)),
      t2.cost and t3.cost and math.abs(t2.cost - t3.cost) < 1e-9)

-- a transcript rewritten shorter than its saved offset is dropped on load and re-read from 0
check("the full-read boot saved the state", exists(STATE_FILE))
local uT = { input_tokens = 1, output_tokens = 9, cache_read_input_tokens = 123, cache_creation_input_tokens = 0 }
writeFile(SUBAGENT, rec("msg_T", "text", uT, "claude-sonnet-5") .. "\n")
check("(the rewritten subagent transcript is shorter than its saved offset)", fileSize(SUBAGENT) < savedSub)
local ok4, FX4, reads4 = boot()
check("a boot over a shrunk transcript loads", ok4)
local loaded = FX4.loadUsageState and FX4.loadUsageState() or {}
check("a file now shorter than its saved offset is dropped from the loaded state", loaded[SUBAGENT] == nil)
check("...while an intact file keeps its state", loaded[TRANSCRIPT] ~= nil)
FX4.computeUsage()
local t4 = totals(lastUsage())
eq("...the shrunk file is re-read from byte 0", firstRead(reads4, SUBAGENT), 0)
eq("...and its totals are the new content's only", t4.sonnetRead, 123)
eq("...while the intact transcript resumes at its offset", firstRead(reads4, TRANSCRIPT), fileSize(TRANSCRIPT))

-- a corrupt state file is ignored: a fresh scan, never an error
local full = t4.cacheRead
writeFile(STATE_FILE, "{not json")
local ok5, FX5, reads5 = boot()
check("a corrupt state file doesn't break the boot", ok5)
FX5.computeUsage()
eq("...the pass reads from byte 0", firstRead(reads5, TRANSCRIPT), 0)
eq("...with the right totals", totals(lastUsage()).cacheRead, full)
local rewritten = readAll(STATE_FILE) or ""
local okJ, saved = pcall(json.decode, rewritten)
check("...and the corrupt file is replaced by a good save", okJ and type(saved) == "table" and type(saved.version) == "number")

-- a state file from another version is ignored, even one whose entries look usable
writeFile(STATE_FILE, json.encode({ version = 999, files = { [TRANSCRIPT] = { offset = fileSize(TRANSCRIPT), seen = {},
  cum = { input = 1, output = 1, cacheRead = 9e9, cacheCreate = 1, cacheCreate1h = 1, total = 9e9, real = 3, byModel = {} },
  recent = {} } } }))
local ok6, FX6, reads6 = boot()
check("an other-version state file doesn't break the boot", ok6)
FX6.computeUsage()
eq("...the pass reads from byte 0", firstRead(reads6, TRANSCRIPT), 0)
eq("...with the right totals", totals(lastUsage()).cacheRead, full)

-- ---- a /model switch to or from [1m] moves the context window (2026-09-30) ----
-- 2026-09-30: the [1m] opt-in came from the spawn-time model and the settings files only, so a
-- session switched to opus[1m] mid-way kept a 200k bar (full at a fifth of its real window) and
-- one switched away kept a 1M bar. The transcript records the switch as the command's own
-- output; the usage pass reads it, and the saved state carries it across a reload.
do
  local function frac() return ((lastUsage().perSession or {}).s1 or {}).context_frac end
  local function switchTo(model)
    writeFile(TRANSCRIPT, json.encode({ type = "user", message = { role = "user",
      content = "<local-command-stdout>Set model to `" .. model .. "`</local-command-stdout>" } }) .. "\n", "a")
  end
  local okS, FXs = boot()
  check("a boot before any switch loads", okS)
  FXs.computeUsage()
  local base = frac()
  check("before any switch the bar is measured against 200k  (" .. tostring(base) .. ")", type(base) == "number" and base > 0.2)
  switchTo("claude-opus-5-5[1m]")
  FXs.computeUsage()
  local wide = frac()
  check("a /model switch to [1m] widens the window five-fold, on the very next pass  (" .. tostring(wide) .. ")",
        type(wide) == "number" and math.abs(wide - base / 5) < 1e-9)
  -- a reload resumes the transcript past the switch: it must come back from the saved state
  if type(hs.shutdownCallback) == "function" then pcall(hs.shutdownCallback) end
  local okR, FXr, readsR = boot()
  check("a boot after the switch loads", okR)
  FXr.computeUsage()
  eq("after a reload the transcript resumes past the switch", firstRead(readsR, TRANSCRIPT), fileSize(TRANSCRIPT))
  check("...and the window is still the 1M one  (" .. tostring(frac()) .. ")", type(frac()) == "number" and math.abs(frac() - base / 5) < 1e-9)
  switchTo("claude-opus-5-5")
  FXr.computeUsage()
  check("a /model switch away from [1m] narrows it again  (" .. tostring(frac()) .. ")", type(frac()) == "number" and math.abs(frac() - base) < 1e-9)
end

os.execute("rm -rf '" .. HOME .. "'")
print(string.format("-- usage-totals.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
