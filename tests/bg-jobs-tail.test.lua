-- bg-jobs-tail.test.lua : BEHAVIORAL fixture for a finished session's background jobs (2026-11-04).
-- Runs the REAL FX.readTail and the FX job-count block sliced out of claude-dashboard.lua against
-- real transcript files in a temp dir (the packets.test.lua pattern).
--
-- Adam, 2026-11-04: "find out why this isn't saying working and make it say working lol".
-- Custom-browser had ended its turn to wait on its open-web sweep (bizs84957, `npm run open-web >
-- …log 2>&1`, run_in_background), so its status file read done. FX.backgroundJobsFor is what turns
-- that into Working, but it read only the transcript's last 256KB, and the sweep's start was 354KB
-- back: 17 minutes of browser snapshots (~10KB a record) came after it. The card read Heads-up.
--
-- Usage: lua tests/bg-jobs-tail.test.lua [path/to/claude-dashboard.lua]

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- bg-jobs-tail.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local tailBody = src:match("\n(function FX%.readTail%(path, maxBytes%).-\nend\n)")
check("the panel ships FX.readTail", tailBody ~= nil)
local jobsBody = src:match("\n(FX%.JOBS_TAIL_BYTES = .-\nfunction FX%.backgroundJobsFor%(it, now, maxAge%).-\nend\n)")
check("the panel ships the job-count block (FX.JOBS_TAIL_BYTES .. FX.backgroundJobsFor)", jobsBody ~= nil)
if not (tailBody and jobsBody) then finish() end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end

-- hs.fs.attributes on the real file: its size, and a modification stamp that moves with it
local function fileSize(path)
  local fh = io.open(path, "rb"); if not fh then return nil end
  local n = fh:seek("end"); fh:close(); return n
end
local hs = { fs = { attributes = function(path, what)
  local n = fileSize(path)
  if not n then return nil end
  if what == "size" then return n end
  if what == "modification" then return n end
  return { size = n, modification = n }
end } }
local FX = {}
local env = setmetatable({ FX = FX, core = core, hs = hs }, { __index = _G })
assert(load(tailBody, "=readTail", "t", env))()
assert(load(jobsBody, "=jobs", "t", env))()
-- every tail asked for, to see how far back a count reads
local asked = {}
local realTail = FX.readTail
FX.readTail = function(path, n) asked[#asked + 1] = n; return realTail(path, n) end

local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", t) end
local function J(t) return core.json.encode(t) end
local NOW = core.isoToEpoch("2026-11-04T16:53:00.000Z")
local SNAP = string.rep("- generic [ref=e12]: a browser snapshot line ", 220)   -- ~10KB, like pilot's tool results
local function sweepStart(at)
  return J({ type = "assistant", timestamp = iso(at), message = { role = "assistant", content = {
           { type = "tool_use", id = "toolu_012f7y77haGEVaJtgc23b3o8", name = "Bash",
             input = { command = "npm run open-web > /private/tmp/claude-503/p/s/scratchpad/logs/open-web-full.log 2>&1",
                       description = "Rerun the open-web sweep with full output", run_in_background = true } } } } })
    .. "\n" .. J({ type = "user", timestamp = iso(at), message = { role = "user", content = {
           { type = "tool_result", tool_use_id = "toolu_012f7y77haGEVaJtgc23b3o8",
             content = "Command running in background with ID: bizs84957. Output is being written to: /private/tmp/claude-503/p/s/tasks/bizs84957.output" } } } })
end
local function snapshots(from, to, n)
  local out = {}
  for i = 1, n do
    out[i] = J({ type = "user", timestamp = iso(from + math.floor((to - from) * i / n)),
                 message = { role = "user", content = { { type = "tool_result", tool_use_id = "toolu_snap" .. i, content = SNAP } } } })
  end
  return table.concat(out, "\n")
end
local function write(path, s) local fh = io.open(path, "w"); fh:write(s); fh:close() end
local function count(path, status)
  asked = {}
  return FX.backgroundJobsFor({ key = path, transcript_path = path, status = status or "done" }, NOW, 1800)
end

-- 1. the case that read Heads-up: the sweep started 17 minutes ago, 35 snapshots (~354KB) after it
local P1 = T .. "/custom-browser.jsonl"
-- (an hour of earlier work before it, all from before the 30-minute window)
write(P1, snapshots(NOW - 7200, NOW - 1900, 60) .. "\n" .. sweepStart(NOW - 1017) .. "\n"
  .. snapshots(NOW - 1000, NOW - 15, 35) .. "\n" .. J({ type = "system", subtype = "stop_hook_summary", timestamp = iso(NOW - 15) }) .. "\n")
local fh1 = io.open(P1, "rb"); local all1 = fh1:read("*a"); fh1:close()
local startAt = all1:find("Command running in background with ID: bizs84957", 1, true)
check("fixture: the sweep's start is more than 256KB back  (" .. (#all1 - startAt) .. " bytes)", #all1 - startAt > 262144)
check("a job that started more than 256KB back still counts: the card reads Working", count(P1) == 1)
check("...the read reaches back only as far as the job window needs, not the whole file",
      #asked > 0 and asked[#asked] < fileSize(P1))

-- 2. a job that started before the window opened (40 minutes ago) doesn't count, however far it reads
local P2 = T .. "/old-job.jsonl"
write(P2, sweepStart(NOW - 2400) .. "\n" .. snapshots(NOW - 2390, NOW - 30, 60) .. "\n")
check("a job older than the window doesn't count", count(P2) == 0)

-- 3. a transcript written that fast for the whole window still stops at the cap
local P3 = T .. "/dense.jsonl"
write(P3, snapshots(NOW - 600, NOW - 10, 240) .. "\n")
local cap = FX.JOBS_TAIL_MAX
FX.JOBS_TAIL_MAX = 1048576
count(P3)
local most = 0
for _, n in ipairs(asked) do if n > most then most = n end end
check("the read never passes its cap  (asked up to " .. most .. ")", most > 0 and most <= 1048576)
FX.JOBS_TAIL_MAX = cap

-- 4. a working session is working anyway: no read at all
check("a working session counts no jobs and reads nothing", count(P1, "working") == 0 and #asked == 0)

os.execute('rm -r "' .. T .. '"')
finish()
