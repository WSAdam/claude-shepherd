-- scenario-replay.test.lua : how accurate is each transcript detector? (2026-09-29)
-- Run with plain `lua`. Shepherd reads a card's state out of its transcript tail through six
-- detectors (core.scenarioVerdicts runs them all): the turn's label (core.turnEvidence +
-- core.turnOutcome), resumed (core.transcriptResumed), awaiting a tool (core.transcriptAwaitingTool),
-- interrupted (core.transcriptInterrupted), error (core.transcriptError) and looping
-- (core.isLooping). Each row below is one real moment -- a scrubbed window cut from a real
-- transcript (tests/fixtures/transcripts/, README there) -- labelled with what was TRUE at that
-- moment, judged from the raw transcript it was cut from. The run prints how often each detector
-- agrees with the truth and goes red on any row whose verdict differs from its table entry.
--
-- A row's fields:
--   fixture, window  the file and the tail it was cut for, read back the way the tick reads it
--   since            when the card last read done (the rebased clock of the window); only a card
--                    that read done is asked "resumed?", so without it resumed is "n/a"
--   expect           the truth for every detector: a label, true/false, or "n/a" when the question
--                    doesn't arise at that moment (a turn still running has no label yet)
--   miss             a detector's KNOWN wrong answer: counted against its accuracy, not a failure.
--                    A detector that starts answering differently -- right, or wrong another way --
--                    goes red, so the table is updated with the fix.
--
-- `lua tests/scenario-replay.test.lua --captures ~/.claude/cc-scenarios` replays your own labelled
-- captures ("Capture as scenario" on a card writes them there, each with a .label.json to fill in)
-- the same way and reports their accuracy -- nothing leaves your Mac. There a disagreement is a
-- finding, not a failure.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local FIXTURES = HERE .. "fixtures/transcripts/"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end

-- the tick's own tail read, lifted out of claude-dashboard.lua and run as shipped
local dashboard = assert(io.open(ROOT .. "claude-dashboard.lua", "r")):read("*a")
local function shipped(name)
  local from = dashboard:find("function FX." .. name .. "(", 1, true)
  local _, to = dashboard:find("\nend\n", from or 1, true)
  assert(from and to, "FX." .. name .. " not found in claude-dashboard.lua")
  local chunk = assert(load("local FX, core = {}, ...\n" .. dashboard:sub(from, to) .. "\nreturn FX." .. name))
  return chunk(core)
end
local readTail = shipped("readTail")

local NA = "n/a"
local CORPUS = {
  -- ---- the fixtures tests/transcript-replay.test.lua already replays (2026-09-18 .. 09-28) ----
  { name = "a turn that died on a 529, its prompt typed after the card read done",
    fixture = "tail-ends-on-api-error.jsonl", window = 65536, since = "2026-01-01T00:01:23Z",
    -- 2026-09-28: unit 9 noticed this turn reads "blocked" (the API error ends it) but nothing pinned it.
    expect = { turn = "blocked", resumed = true, awaiting = false, interrupted = false, error = true, looping = false } },
  { name = "a turn that made two edits and stopped",
    fixture = "tail-turn-made-progress.jsonl", window = 89500, since = "2026-01-01T00:07:17Z",
    expect = { turn = "made progress", resumed = false, awaiting = false, interrupted = false, error = false, looping = false } },
  { name = "a batch unit's one-paragraph answer to its driver",
    fixture = "tail-unit-turn-from-peer.jsonl", window = 60000, since = "2026-01-01T00:06:49Z",
    expect = { turn = "only planned", resumed = false, awaiting = false, interrupted = false, error = false, looping = false } },
  { name = "...with the card still reading done from the turn before the driver's message",
    fixture = "tail-unit-turn-from-peer.jsonl", window = 60000, since = "2026-01-01T00:06:04Z",
    expect = { turn = "only planned", resumed = true, awaiting = false, interrupted = false, error = false, looping = false } },
  { name = "a merge-and-deploy turn whose prompt is out of reach, which flipped its TODO lines",
    fixture = "tail-turn-prompt-out-of-reach.jsonl", window = 90000, since = "2026-01-01T00:06:40Z",
    expect = { turn = "done", resumed = false, awaiting = false, interrupted = false, error = false, looping = false },
    -- 2026-09-29: the unit flipped three TODO lines to [x] with `sed -i` (the merge protocol's last
    -- step); turnEvidence counts a flip only through an Edit/Write of TODO.md, so the turn reads
    -- "made progress" -- in the raw transcript too, not only in the scrubbed one.
    miss = { turn = "made progress" } },

  -- ---- cut for the corpus (2026-09-29): a detector with no case, and the labels with none ----
  { name = "Voice-Agent's '2h Working' card: Adam stopped a TaskOutput wait",
    -- 2026-09-18's leftover (see transcriptInterrupted): no Stop hook, so the card read working for
    -- good. Claude Code wrote the stop as a rejected tool use, then the interrupt marker.
    fixture = "tail-interrupted-for-tool-use.jsonl", window = 32768,
    expect = { turn = "blocked", resumed = NA, awaiting = false, interrupted = true, error = false, looping = false } },
  { name = "the same session four minutes earlier, waiting on Adam's answer to a question",
    fixture = "tail-awaiting-a-question.jsonl", window = 16384,
    expect = { turn = NA, resumed = NA, awaiting = true, interrupted = false, error = false, looping = false } },
  { name = "one file edited in three places in a row, each edit different and each landing",
    fixture = "tail-one-file-edited-three-times.jsonl", window = 16384,
    expect = { turn = NA, resumed = NA, awaiting = false, interrupted = false, error = false, looping = false },
    -- 2026-09-29: core.toolCallSig signs an Edit by its file_path alone, so three different edits of
    -- one file read as the same call three times. The commonest "loop" in Adam's transcripts
    -- (the loop watchdog is off by default, so no card has flagged it yet).
    miss = { looping = true } },
  { name = "a connection dropped mid-turn, Claude Code retrying",
    fixture = "tail-connection-dropped-retrying.jsonl", window = 16400,
    expect = { turn = NA, resumed = NA, awaiting = false, interrupted = false, error = true, looping = false } },
  { name = "...and seven seconds later, answering again",
    fixture = "tail-connection-dropped-recovered.jsonl", window = 16384,
    expect = { turn = NA, resumed = NA, awaiting = false, interrupted = false, error = false, looping = false } },
  { name = "a reply that ends by asking Adam which he meant",
    fixture = "tail-turn-ends-on-a-question.jsonl", window = 20480, since = "2026-01-01T00:04:03Z",
    expect = { turn = "needs follow-up", resumed = false, awaiting = false, interrupted = false, error = false, looping = false } },
  { name = "'commit and push': a turn that committed, its prompt after the card read done",
    fixture = "tail-turn-committed.jsonl", window = 16420, since = "2026-01-01T00:00:02Z",
    expect = { turn = "done", resumed = true, awaiting = false, interrupted = false, error = false, looping = false } },
}

-- ---- the runner ------------------------------------------------------------------------------
local tally = {}
for _, d in ipairs(core.SCENARIO_DETECTORS or {}) do tally[d] = { right = 0, total = 0, misses = 0, na = 0, fired = {} } end

local function show(v) return v == nil and "nil" or tostring(v) end

-- One row; `lenient` (private captures) reports a disagreement instead of failing on it.
local function replay(row, dir, lenient)
  local tail = readTail(dir .. row.fixture, row.window)
  if not tail then check(row.name .. ": the fixture " .. row.fixture .. " is readable", false); return end
  local since = row.since and core.isoToEpoch(row.since) or nil
  if row.since and not since then check(row.name .. ": since " .. row.since .. " parses", false); return end
  local v = core.scenarioVerdicts(tail, { since = since })
  for _, d in ipairs(core.SCENARIO_DETECTORS) do
    local want, got, t = row.expect and row.expect[d], v[d], tally[d]
    if got ~= nil then t.fired[show(got)] = true end
    local miss = row.miss and row.miss[d]
    if want == nil then
      if not lenient then check(row.name .. ": says what is true for " .. d .. " (a value or \"n/a\")", false) end
    elseif want == NA then
      t.na = t.na + 1
      if d == "resumed" and not lenient then
        check(row.name .. ": resumed is n/a exactly when no since is given", row.since == nil)
      end
    else
      t.total = t.total + 1
      if got == want and miss == nil then
        t.right = t.right + 1
        check(row.name .. ": " .. d .. " = " .. show(want), true)
      elseif got == want then
        check(row.name .. ": " .. d .. " now answers right (" .. show(got) .. ") -- drop its miss entry", false)
      elseif miss ~= nil and got == miss then
        t.misses = t.misses + 1
        print("miss - " .. row.name .. ": " .. d .. " says " .. show(got) .. ", the truth is " .. show(want) .. " (known)")
      elseif lenient then
        t.misses = t.misses + 1
        print("WRONG - " .. row.name .. ": " .. d .. " says " .. show(got) .. ", your label says " .. show(want))
      else
        check(row.name .. ": " .. d .. " = " .. show(want) .. "  (got=" .. show(got) .. ")", false)
      end
    end
  end
end

local function report(title)
  print("\n" .. title)
  for _, d in ipairs(core.SCENARIO_DETECTORS) do
    local t = tally[d]
    local pct = t.total > 0 and string.format("%3d%%", math.floor(100 * t.right / t.total + 0.5)) or "  --"
    print(string.format("  %-12s %s  %d/%d right%s%s", d, pct, t.right, t.total,
      t.misses > 0 and (", " .. t.misses .. " wrong") or "", t.na > 0 and (", " .. t.na .. " n/a") or ""))
  end
end

check("core names the detectors the corpus measures", type(core.SCENARIO_DETECTORS) == "table" and #core.SCENARIO_DETECTORS == 6)
if type(core.SCENARIO_DETECTORS) ~= "table" or type(core.scenarioVerdicts) ~= "function" then
  print(string.format("\n%d checks, %d failed", run, failed + 1)); os.exit(1)
end

-- --captures DIR: your own labelled captures, never the repo's
if arg and arg[1] == "--captures" then
  local dir = (arg[2] or ((os.getenv("HOME") or "") .. "/.claude/cc-scenarios")):gsub("/?$", "/")
  local p, n, unlabelled = io.popen('ls -1 "' .. dir .. '" 2>/dev/null'), 0, 0
  for f in (p and p:lines() or function() return nil end) do
    if f:match("%.label%.json$") then
      local h = io.open(dir .. f, "r")
      local ok, label = pcall(core.json.decode, h and h:read("*a") or "")
      if h then h:close() end
      local filled = false
      if ok and type(label) == "table" and type(label.expect) == "table" then
        for _, d in ipairs(core.SCENARIO_DETECTORS) do if label.expect[d] ~= nil then filled = true end end
      end
      if filled and type(label.fixture) == "string" and tonumber(label.window) then
        n = n + 1
        replay({ name = f:gsub("%.label%.json$", ""), fixture = label.fixture, window = tonumber(label.window),
                 since = type(label.since) == "string" and label.since or nil, expect = label.expect }, dir, true)
      else
        unlabelled = unlabelled + 1
      end
    end
  end
  if p then p:close() end
  report(string.format("Accuracy over %d labelled capture(s) in %s (%d not labelled yet):", n, dir, unlabelled))
  os.exit(0)
end

for _, row in ipairs(CORPUS) do replay(row, FIXTURES, false) end

-- ---- the corpus itself ------------------------------------------------------------------------
-- Every tail fixture is labelled here (the heads are first-prompt cases, not moments of a card).
do
  local listed, missing = {}, {}
  for _, row in ipairs(CORPUS) do listed[row.fixture] = true end
  local p = io.popen('ls -1 "' .. FIXTURES .. '" 2>/dev/null')
  for f in (p and p:lines() or function() return nil end) do
    if f:match("^tail%-.*%.jsonl$") and not listed[f] then missing[#missing + 1] = f end
  end
  if p then p:close() end
  check("every tail fixture has a row in the corpus  (" .. table.concat(missing, ", ") .. ")", #missing == 0)
end
-- Each detector is seen both firing and not, on real windows -- a detector that only ever says one
-- thing here is measured on nothing.
for _, d in ipairs(core.SCENARIO_DETECTORS) do
  local seen = {}
  for k in pairs(tally[d].fired) do seen[#seen + 1] = k end
  table.sort(seen)
  local enough
  if d == "turn" then enough = #seen >= 4 else enough = tally[d].fired["true"] and tally[d].fired["false"] end
  check(d .. ": the corpus has windows where it answers each way  (" .. table.concat(seen, ", ") .. ")", enough == true)
end

report(string.format("Detector accuracy over %d labelled moment(s) of real transcripts:", #CORPUS))
print(string.format("\n%d checks, %d failed", run, failed))
os.exit(failed == 0 and 0 or 1)
