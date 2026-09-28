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

os.execute("rm -rf '" .. HOME .. "'")
print(string.format("-- usage-totals.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
