-- time-lost.test.lua : where the time went (2026-09-29, build program unit 34). Pure cc-core, on
-- literal transcript lines, scrubbed real transcript windows (tests/fixtures/transcripts/) and
-- literal ledger events:
--   * core.timeIndexFold    -- one transcript's turns, retries, compactions, exits and tokens
--   * core.timeIndexPlan / timeIndexApply -- the indexer reads only what changed (size/mtime, offset)
--   * core.timeLostStep     -- the tick's episodes -> waited / hung_end / error_end ledger events
--   * core.timeLostSummary  -- ledger + index -> the Time view, with its plain-sentence callouts
-- Run with plain `lua`. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end
local function readFixture(name)
  local f = assert(io.open(HERE .. "fixtures/transcripts/" .. name, "rb"))
  local s = f:read("*a"); f:close(); return s
end
local function has(list, s)
  for _, v in ipairs(list or {}) do if v == s then return true end end
  return false
end

-- Literal transcript records, in the key order Claude Code writes them. T(n) = 2026-09-29T10:00:00Z + n s.
local function T(n)
  local s = 36000 + n
  return string.format("2026-09-29T%02d:%02d:%02d.000Z", s // 3600, (s % 3600) // 60, s % 60)
end
local T0 = core.isoToEpoch(T(0))
local function prompt(n, kind)
  return '{"parentUuid":null,"isSidechain":false,"promptId":"p' .. n .. '","type":"user","message":{"role":"user","content":"do the thing"},'
    .. (kind and ('"origin":{"kind":"' .. kind .. '"},') or "")
    .. (kind == "peer" and '"isMeta":true,' or "")
    .. '"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '","cwd":"/r"}'
end
local function meta(n)
  return '{"parentUuid":"x","isSidechain":false,"type":"user","message":{"role":"user","content":"skill body"},"isMeta":true,"uuid":"m' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function assistant(n, id, u, model)
  u = u or {}
  return '{"parentUuid":"x","isSidechain":false,"message":{"model":"' .. (model or "claude-opus-5") .. '","id":"' .. id
    .. '","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn",'
    .. '"usage":{"input_tokens":' .. (u.input or 0) .. ',"cache_creation_input_tokens":' .. ((u.w5 or 0) + (u.w1 or 0))
    .. ',"cache_read_input_tokens":' .. (u.read or 0) .. ',"output_tokens":' .. (u.output or 0)
    .. ',"cache_creation":{"ephemeral_1h_input_tokens":' .. (u.w1 or 0) .. ',"ephemeral_5m_input_tokens":' .. (u.w5 or 0) .. '}}},'
    .. '"requestId":"r","type":"assistant","uuid":"a' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function toolResult(n)
  return '{"parentUuid":"x","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"{\\"timestamp\\":\\"2020-01-01T00:00:00.000Z\\"}"}]},"uuid":"t' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function stopHook(n)
  return '{"parentUuid":"x","isSidechain":false,"type":"system","subtype":"stop_hook_summary","hookCount":3,"hookErrors":[],"preventedContinuation":false,"stopReason":"","hasOutput":true,"level":"suggestion","timestamp":"' .. T(n) .. '","uuid":"s' .. n .. '"}'
end
local function apiError(n, ms, attempt)
  return '{"parentUuid":"x","isSidechain":false,"type":"system","subtype":"api_error","level":"error","error":{"message":"Connection error."},"retryInMs":' .. ms
    .. ',"retryAttempt":' .. attempt .. ',"maxRetries":10,"timestamp":"' .. T(n) .. '","uuid":"e' .. n .. '"}'
end
local function interrupt(n)
  return '{"parentUuid":"x","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"i' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function apiFailure(n)
  return '{"parentUuid":"x","isSidechain":false,"message":{"model":"<synthetic>","id":"f' .. n .. '","type":"message","role":"assistant","content":[{"type":"text","text":"API Error: 529 Overloaded"}]},"type":"assistant","uuid":"f' .. n .. '","timestamp":"' .. T(n) .. '","isApiErrorMessage":true,"error":"server_error"}'
end
local function compactBoundary(n, ms)
  return '{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto","preTokens":968342,"postTokens":30043,"durationMs":' .. ms .. '},"uuid":"c' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function lines(t) return table.concat(t, "\n") .. "\n" end

local function foldAll(text, sub)
  local e = core.timeIndexBlank(sub)
  local consumed
  e, consumed = core.timeIndexFold(e, text)
  return e, consumed
end

-- ---- a transcript's turns, retries, exits and tokens (2026-09-29) ----
do
  -- one turn: a prompt, two API messages (the first written as two records), a tool result, the Stop
  local text = lines({
    prompt(0, "human"),
    assistant(5, "msg_1", { input = 10, output = 100, read = 9000, w1 = 1000 }),
    assistant(5, "msg_1", { input = 10, output = 100, read = 9000, w1 = 1000 }),   -- same message, second block
    toolResult(20),
    assistant(40, "msg_2", { input = 5, output = 50, read = 10000, w5 = 400 }),
    stopHook(60),
  })
  local e, consumed = foldAll(text)
  eq("fold: consumes every complete line", consumed, #text)
  eq("fold: one turn", e.turns, 1)
  eq("fold: the turn ran from its prompt to its Stop (60s)", e.turnSeconds, 60)
  eq("fold: ...and it ended done", e.exits.done, 1)
  eq("fold: no turn left open", e.turnOpen, nil)
  eq("fold: a message written as two records counts once (input)", e.usage.input, 15)
  eq("fold: ...output", e.usage.output, 150)
  eq("fold: cache reads", e.usage.cacheRead, 19000)
  eq("fold: cache writes, both TTLs", e.usage.cacheCreate, 1400)
  eq("fold: the 1-hour part of them", e.usage.cacheCreate1h, 1000)
  eq("fold: tokens by model", e.usage.byModel["claude-opus-5"].cacheCreate1h, 1000)
  eq("fold: a timestamp inside a tool result is not the record's", e.lastTs, T0 + 60)

  -- a retry episode: two api_error records, then the answer 10s after the first
  local e2 = foldAll(lines({
    prompt(0, "human"), apiError(100, 500, 1), apiError(101, 1000, 2), assistant(110, "msg_3", { output = 1 }), stopHook(120),
  }))
  eq("retry: two retries", e2.retries, 2)
  eq("retry: one episode", e2.retryEpisodes, 1)
  eq("retry: from the first error to the answer (10s)", e2.retrySeconds, 10)
  eq("retry: the episode is closed", e2.retryOpen, nil)

  -- an interrupted turn, then one that died on an API error, then a compaction
  local e3 = foldAll(lines({
    prompt(200, "human"), assistant(205, "msg_4", { output = 1 }), interrupt(230),
    prompt(300, "human"), apiFailure(320),
    compactBoundary(400, 164306),
  }))
  eq("exits: two turns", e3.turns, 2)
  eq("exits: one interrupted", e3.exits.interrupted, 1)
  eq("exits: one ended on an API error", e3.exits.error, 1)
  eq("exits: 30s + 20s of turns", e3.turnSeconds, 50)
  eq("exits: the longest was 30s", e3.longestTurn, 30)
  eq("compaction: one", e3.compactions, 1)
  check("compaction: its 164.3s", math.abs(e3.compactSeconds - 164.306) < 0.001)

  -- a meta record (a skill's body) doesn't start a turn; a batch driver's message (peer) does
  local e4 = foldAll(lines({ meta(0), prompt(10, "peer"), assistant(15, "msg_5"), stopHook(25) }))
  eq("prompts: a meta record isn't a prompt, a peer message is", e4.turns, 1)
  eq("prompts: the turn starts at the peer message", e4.turnSeconds, 15)

  -- the Stop hook blocked (a mailbox message): the turn carries on without a prompt
  local e5 = foldAll(lines({ prompt(0, "human"), assistant(5, "msg_6"), stopHook(10), assistant(12, "msg_7"), stopHook(30) }))
  eq("continuation: activity after a Stop reopens a turn", e5.turns, 2)
  eq("continuation: 10s + 18s", e5.turnSeconds, 28)

  -- a new prompt while a turn is still open (killed mid-turn, resumed): the old one is cut
  local e6 = foldAll(lines({ prompt(0, "human"), assistant(5, "msg_8"), prompt(500, "human"), stopHook(510) }))
  eq("unfinished: the open turn is closed at its last record", e6.exits.unfinished, 1)
  eq("unfinished: 5s + 10s", e6.turnSeconds, 15)

  -- 2026-09-29: a cross-session wake-up notice arrives as a META user record with no prompt, and its
  -- retries ran out: the API failure found no turn open, so a real session's error exit went uncounted
  local e7 = foldAll(lines({ meta(0), apiError(1, 500, 1), apiError(2, 1000, 2), apiFailure(180) }))
  eq("wake-up: a meta record with no turn open starts one", e7.turns, 1)
  eq("wake-up: ...which the API failure ends as an error", e7.exits.error, 1)
  eq("wake-up: ...180s long", e7.turnSeconds, 180)
  local e8 = foldAll(lines({ apiError(0, 500, 1), apiFailure(60) }))
  eq("failure with no turn at all: still an error exit, from its first retry", e8.exits.error .. "/" .. e8.turnSeconds, "1/60")
  -- a meta record after a turn, then a prompt an hour later: the turn starts at the prompt
  local e9 = foldAll(lines({ prompt(0, "human"), assistant(5, "msg_9"), stopHook(10), meta(20), prompt(3600, "human"), stopHook(3630) }))
  eq("idle meta: nothing reads unfinished", e9.exits.unfinished, 0)
  eq("idle meta: the idle hour isn't a turn (10s + 30s)", e9.turnSeconds, 40)

  -- a subagent's transcript: tokens and span only, no turns
  local s = foldAll(lines({ prompt(0), assistant(5, "msg_s1", { input = 3, output = 30, w5 = 700 }), toolResult(8), assistant(20, "msg_s2", { output = 7 }) }), true)
  eq("subagent: flagged sub", s.sub, true)
  eq("subagent: no turns", s.turns, 0)
  eq("subagent: its tokens", s.usage.output, 37)
  eq("subagent: its span starts at its first record", s.firstTs, T0)
end

-- ---- scrubbed real windows (2026-09-29) ----
do
  local rec = foldAll(readFixture("tail-connection-dropped-recovered.jsonl"))
  eq("real: a dropped connection that recovered is one retry", rec.retries, 1)
  eq("real: ...and 7s of retrying (api_error at :12, answer at :19)", rec.retrySeconds, 7)

  local retrying = foldAll(readFixture("tail-connection-dropped-retrying.jsonl"))
  check("real: still retrying -- the episode is open", type(retrying.retryOpen) == "table")
  local v = core.timeLostSummary({ entries = { retrying }, events = {}, now = T0 })
  check("real: an open episode counts up to its next attempt (0.609s)", v.retry.seconds > 0.6 and v.retry.seconds < 0.62)

  local intr = foldAll(readFixture("tail-interrupted-for-tool-use.jsonl"))
  eq("real: the interrupt marker ends the turn as interrupted", intr.exits.interrupted, 1)

  local prog = foldAll(readFixture("tail-turn-made-progress.jsonl"))
  check("real: a Stop hook ends a turn as done", (prog.exits.done or 0) >= 1)
  check("real: tokens were counted", prog.usage.output > 0)
end

-- ---- the indexer reads only what changed (2026-09-29) ----
do
  local text = lines({ prompt(0, "human"), assistant(5, "msg_1", { output = 10 }), apiError(20, 500, 1),
                       assistant(30, "msg_2", { output = 20 }), stopHook(60) })
  local whole = foldAll(text)
  -- split in the middle of the third record: the torn half waits for the next read
  local cut = #lines({ prompt(0, "human"), assistant(5, "msg_1", { output = 10 }) }) + 40
  local e = core.timeIndexBlank(false)
  local c1
  e, c1 = core.timeIndexFold(e, text:sub(1, cut))
  check("incremental: a torn last line is not consumed", c1 < cut)
  local c2
  e, c2 = core.timeIndexFold(e, text:sub(c1 + 1))
  eq("incremental: the rest is consumed from where the first read stopped", c1 + c2, #text)
  eq("incremental: two reads give the same turns as one", e.turnSeconds, whole.turnSeconds)
  eq("incremental: ...the same retry time", e.retrySeconds, whole.retrySeconds)
  eq("incremental: ...the same tokens", e.usage.output, whole.usage.output)

  -- the plan: only files whose size or mtime moved are read, from their offset
  local entries = {
    ["/t/same.jsonl"] = { offset = 100, size = 100, mtime = 5 },
    ["/t/grew.jsonl"] = { offset = 100, size = 100, mtime = 5 },
    ["/t/shrank.jsonl"] = { offset = 900, size = 900, mtime = 5 },
    ["/t/touched.jsonl"] = { offset = 100, size = 100, mtime = 5 },
    ["/t/torn.jsonl"] = { offset = 90, size = 100, mtime = 5 },
    ["/t/behind.jsonl"] = { offset = 100, size = 5000, mtime = 5, more = true },
  }
  local files = {
    { path = "/t/same.jsonl", size = 100, mtime = 5 },
    { path = "/t/grew.jsonl", size = 250, mtime = 6 },
    { path = "/t/shrank.jsonl", size = 300, mtime = 6 },
    { path = "/t/new.jsonl", size = 50, mtime = 6, sub = true },
    { path = "/t/touched.jsonl", size = 100, mtime = 9 },
    { path = "/t/torn.jsonl", size = 100, mtime = 5 },
    { path = "/t/behind.jsonl", size = 5000, mtime = 5 },
  }
  local reads = core.timeIndexPlan(entries, files, { fileBytes = 1000, passBytes = 100000 })
  local by = {}
  for _, r in ipairs(reads) do by[r.path] = r end
  eq("plan: an unchanged file (size and mtime) isn't read", by["/t/same.jsonl"], nil)
  eq("plan: a file that grew is read from its offset", by["/t/grew.jsonl"] and by["/t/grew.jsonl"].from, 100)
  eq("plan: ...only the new bytes", by["/t/grew.jsonl"] and by["/t/grew.jsonl"].len, 150)
  eq("plan: a file that shrank below its offset starts over", by["/t/shrank.jsonl"] and by["/t/shrank.jsonl"].fresh, true)
  eq("plan: ...from byte 0", by["/t/shrank.jsonl"] and by["/t/shrank.jsonl"].from, 0)
  eq("plan: a new file is read from 0", by["/t/new.jsonl"] and by["/t/new.jsonl"].from, 0)
  eq("plan: ...and keeps its subagent flag", by["/t/new.jsonl"] and by["/t/new.jsonl"].sub, true)
  eq("plan: a touched file with nothing past its offset isn't read", by["/t/touched.jsonl"], nil)
  eq("plan: a torn last line isn't re-read until the file changes", by["/t/torn.jsonl"], nil)
  eq("plan: a file left behind by the per-file cap is read on", by["/t/behind.jsonl"] and by["/t/behind.jsonl"].from, 100)
  eq("plan: ...at most the per-file cap", by["/t/behind.jsonl"] and by["/t/behind.jsonl"].len, 1000)
  local capped = core.timeIndexPlan({}, { { path = "/a", size = 700, mtime = 1 }, { path = "/b", size = 700, mtime = 1 } },
    { fileBytes = 1000, passBytes = 1000 })
  eq("plan: the pass cap stops the second file", #capped, 2)
  eq("plan: ...which gets only what is left of the pass", capped[2] and capped[2].len, 300)

  -- apply: a read lands in its entry, and marks whether bytes are still waiting
  local a = core.timeIndexApply(nil, { path = "/x", from = 0, len = #text, size = #text, mtime = 7, fresh = true }, text)
  eq("apply: the offset is what was consumed", a.offset, #text)
  eq("apply: size and mtime are remembered", a.size .. "/" .. a.mtime, #text .. "/7")
  eq("apply: nothing waiting", a.more, false)
  local half = core.timeIndexApply(nil, { path = "/x", from = 0, len = 200, size = #text, mtime = 7, fresh = true }, text:sub(1, 200))
  eq("apply: a capped read leaves the rest for the next pass", half.more, true)
  local s = core.timeIndexApply(half, { path = "/x", from = 0, len = 100, size = 900, mtime = 8, fresh = true }, text:sub(1, 100))
  eq("apply: a fresh read starts the entry over", s.turns + s.offset, 0 + 0)
  -- one line longer than the per-file cap: skipped, never read forever
  local big = '{"type":"user","message":"' .. string.rep("x", 3000) .. '"}\n' .. prompt(0, "human") .. "\n"
  local g = core.timeIndexApply(nil, { from = 0, len = 1000, cap = 1000, size = #big, mtime = 1, fresh = true }, big:sub(1, 1000))
  eq("giant line: the offset moves past the bytes read", g.offset, 1000)
  local g2 = core.timeIndexApply(g, { from = 1000, len = #big - 1000, size = #big, mtime = 1 }, big:sub(1001))
  eq("giant line: the rest of it is skipped and the next line read", g2.offset, #big)
  eq("giant line: the next line's prompt opened a turn", g2.turnOpen, T0)

  -- the read command: each file's new bytes into its own scratch file, every path quoted
  local cmd = core.timeIndexScanCommand({ { path = "/t/it's.jsonl", from = 100, len = 150 } }, "/s/cc-time")
  check("scan command: tail from the byte after the offset", cmd:find("tail -c +101 '/t/it'\\''s.jsonl'", 1, true) ~= nil)
  check("scan command: head caps it at the planned length", cmd:find("head -c 150 > '/s/cc-time.1'", 1, true) ~= nil)
end

-- ---- the tick's episodes become ledger events (2026-09-29) ----
do
  eq("source: a permission prompt", core.timeLostWaitSource({ status = "approval", needsYou = "needs", needsYouSource = "approval" }), "approval")
  eq("source: a question", core.timeLostWaitSource({ status = "approval", needsYou = "needs", needsYouSource = "ask" }), "question")
  eq("source: a merge review", core.timeLostWaitSource({ status = "done", needsYou = "needs", needsYouSource = "merge" }), "merge")
  eq("source: a batch proposal", core.timeLostWaitSource({ status = "done", needsYou = "needs", needsYouSource = "fleet" }), "batch")
  eq("source: a heads-up is not a wait on Adam", core.timeLostWaitSource({ status = "approval", needsYou = "fyi", needsYouSource = "approval" }), nil)
  eq("source: a usage limit", core.timeLostWaitSource({ status = "error", error_reason = "budget_exceeded", needsYou = "needs", needsYouSource = "error" }), "limit")
  eq("source: another error is not a wait", core.timeLostWaitSource({ status = "error", error_reason = "runtime_error", needsYou = "needs", needsYouSource = "error" }), nil)
  eq("source: a dead session waits on nobody", core.timeLostWaitSource({ status = "approval", procAlive = false, needsYou = "needs", needsYouSource = "approval" }), nil)
  eq("source: working", core.timeLostWaitSource({ status = "working", needsYou = "no" }), nil)

  local now = 1000
  local rec, ev = core.timeLostStep(nil, { status = "approval", updated = 990, needsYou = "needs", needsYouSource = "approval" }, now)
  eq("step: a wait that starts is not ledgered yet", #ev, 0)
  eq("step: first sight dates it from the status file (a reload mid-wait keeps its start)", rec.wait.since, 990)
  rec, ev = core.timeLostStep(rec, { status = "approval", updated = 1100, needsYou = "needs", needsYouSource = "approval" }, 1500)
  eq("step: still waiting -- nothing", #ev, 0)
  rec, ev = core.timeLostStep(rec, { status = "working", updated = 1710 }, 1710)
  eq("step: the wait ends -> one event", #ev, 1)
  local w = ev[1] or {}
  eq("waited: type", w.type, "waited")
  eq("waited: source", w.source, "approval")
  eq("waited: seconds (12m)", w.seconds, 720)
  local keys = {}
  for k in pairs(w) do keys[#keys + 1] = k end
  table.sort(keys)
  eq("waited: exactly {type, source, seconds}", table.concat(keys, ","), "seconds,source,type")

  -- an approval that becomes a question: the first wait ends, the second starts now
  rec = nil
  rec, ev = core.timeLostStep(rec, { status = "approval", updated = 100, needsYou = "needs", needsYouSource = "approval" }, 100)
  rec, ev = core.timeLostStep(rec, { status = "approval", updated = 160, needsYou = "needs", needsYouSource = "ask" }, 160)
  eq("switch: the approval's wait is ledgered", ev[1] and (ev[1].source .. ":" .. ev[1].seconds), "approval:60")
  eq("switch: the question's wait starts", rec.wait and rec.wait.source, "question")

  -- a stall: hung from its last progress until it moves again
  rec = nil
  rec, ev = core.timeLostStep(rec, { status = "working", hung = true }, 2000, 1400)
  eq("stall: flagged -- nothing yet", #ev, 0)
  rec, ev = core.timeLostStep(rec, { status = "working" }, 2100, nil)
  eq("hung_end: type", ev[1] and ev[1].type, "hung_end")
  eq("hung_end: seconds from the last progress (700)", ev[1] and ev[1].seconds, 700)

  -- an error, and a usage limit (a wait, not an error)
  rec = nil
  rec, ev = core.timeLostStep(rec, { status = "error", error_reason = "runtime_error", updated = 3000 }, 3000)
  rec, ev = core.timeLostStep(rec, { status = "working" }, 3090)
  eq("error_end: type", ev[1] and ev[1].type, "error_end")
  eq("error_end: its reason", ev[1] and ev[1].reason, "runtime_error")
  eq("error_end: seconds", ev[1] and ev[1].seconds, 90)
  rec = nil
  rec, ev = core.timeLostStep(rec, { status = "error", error_reason = "budget_exceeded", updated = 4000, needsYou = "needs", needsYouSource = "error" }, 4000)
  rec, ev = core.timeLostStep(rec, { status = "working" }, 5800)
  eq("limit: one event", #ev, 1)
  eq("limit: a waited event with source limit", ev[1] and (ev[1].type .. ":" .. ev[1].source .. ":" .. ev[1].seconds), "waited:limit:1800")

  -- a session that ends mid-wait: what was open is ledgered once
  rec = core.timeLostStep(nil, { status = "approval", updated = 100, needsYou = "needs", needsYouSource = "approval", hung = false }, 100)
  local fin = core.timeLostFinish(rec, 400)
  eq("finish: the open wait is ledgered", fin[1] and (fin[1].type .. ":" .. fin[1].seconds), "waited:300")
  eq("finish: nothing open -> nothing", #core.timeLostFinish(nil, 400), 0)
end

-- ---- ledger + index -> the Time view (2026-09-29) ----
do
  local events = {
    { type = "waited", source = "approval", seconds = 720, session_id = "s1", projectKey = "-p" },
    { type = "waited", source = "question", seconds = 600, session_id = "s1", projectKey = "-p" },
    { type = "waited", source = "approval", seconds = 480, session_id = "s2", projectKey = "-p" },
    { type = "waited", source = "question", seconds = 480, session_id = "s2", projectKey = "-p" },
    { type = "waited", source = "limit", seconds = 1800, session_id = "s1", projectKey = "-p" },
    { type = "hung_end", seconds = 600, session_id = "s1", projectKey = "-p" },
    { type = "hung_end", seconds = 600, session_id = "s2", projectKey = "-p" },
    { type = "error_end", reason = "runtime_error", seconds = 90, session_id = "s1", projectKey = "-p" },
    { type = "session_end", reason = "clear", session_id = "s0", projectKey = "-p" },
    { type = "session_end", reason = "clear", session_id = "s0b", projectKey = "-p" },
    { type = "session_end", reason = "prompt_input_exit", session_id = "s0c", projectKey = "-p" },
    { type = "waited", source = "approval", seconds = 9999, session_id = "other", projectKey = "-q" },
    { type = "prompt", session_id = "s1", projectKey = "-p" },
  }
  local scoped = core.timeLostEventsFor(events, { projects = { ["-p"] = true } })
  eq("scope: a project's events, and only the ones the view reads", #scoped, 11)
  eq("scope: one session", #core.timeLostEventsFor(events, { sessions = { s2 = true } }), 3)

  local main = foldAll(lines({
    prompt(0, "human"), assistant(5, "msg_1", { input = 100, output = 1000, read = 60000, w1 = 20000 }),
    apiError(10, 500, 1), assistant(20, "msg_2", { input = 100, output = 1000, read = 60000, w5 = 0 }), stopHook(600),
    prompt(700, "human"), interrupt(760),
  }))
  local sub = foldAll(lines({ prompt(0), assistant(5, "msg_s", { input = 200, output = 1000, read = 0, w5 = 16000 }) }), true)
  local v = core.timeLostSummary({ entries = { main, sub }, events = scoped, now = T0 + 1000, name = "proj" })
  eq("view: waiting on you = 2280s (38m)", v.you.seconds, 2280)
  eq("view: four waits", v.you.count, 4)
  eq("view: the longest was one approval", v.you.longest.source .. ":" .. v.you.longest.seconds, "approval:720")
  eq("view: limits", v.limit.seconds, 1800)
  eq("view: stalls", v.stalls.seconds .. "/" .. v.stalls.count, "1200/2")
  eq("view: errors", v.errors.seconds, 90)
  eq("view: retries from the transcript", v.retry.seconds, 10)
  eq("view: lost = you + limits + stalls + the larger of errors and retries", v.lost, 2280 + 1800 + 1200 + 90)
  eq("view: turns", v.turns.count, 2)
  eq("view: turn exits", v.turns.exits.done .. "/" .. v.turns.exits.interrupted, "1/1")
  -- cache: reads 120000 of 120000 + 400 input + 36000 writes -> 76.7%
  check("view: cache hit rate is reads over all input", math.abs(v.cache.hitRate - 120000 / (120000 + 400 + 36000)) < 1e-9)
  eq("view: 5-minute cache writes", v.cache.write5m, 16000)
  eq("view: 1-hour cache writes", v.cache.write1h, 20000)
  check("view: 1-hour writes priced at the 1-hour rate (opus $10/M)", math.abs(v.cache.write1hUsd - 0.2) < 1e-9)
  check("view: 5-minute writes at the 5-minute rate (opus $6.25/M)", math.abs(v.cache.write5mUsd - 0.1) < 1e-9)
  eq("view: one subagent", v.split.subagents, 1)
  -- real tokens: main 200 + 2000 + 20000 = 22200; sub 200 + 1000 + 16000 = 17200 -> 44%
  eq("view: main tokens", v.split.mainTokens, 22200)
  eq("view: subagent tokens", v.split.subTokens, 17200)
  eq("view: session ends by reason", v.ends.clear, 2)

  local c = v.callouts
  check("callout: waiting on you, with the one longest wait", has(c, "38m waiting on you, 12m of it on one approval"))
  check("callout: usage limits", has(c, "30m stopped at a usage limit"))
  check("callout: stalls", has(c, "20m stalled with no progress (2 stalls)"))
  check("callout: errors", has(c, "1m 30s in errors (runtime errors)"))
  check("callout: retries", has(c, "10s retrying the API (1 retry)"))
  check("callout: turns and how they ended", has(c, "2 turns took 11m; 1 was interrupted"))
  check("callout: cache", has(c, "77% of input came from the cache"))
  check("callout: cache writes and what they cost", has(c, "Cache writes: 16.0k at 5 minutes, 20.0k at 1 hour (~$0.30)"))
  check("callout: subagents' share", has(c, "Subagents used 44% of the tokens (1 subagent)"))
  check("callout: how sessions ended", has(c, "Sessions ended: 2 cleared, 1 exited"))

  local one = core.timeLostSummary({ entries = {}, events = { { type = "waited", source = "question", seconds = 300 } } })
  check("callout: a single wait says so", has(one.callouts, "5m waiting on you, on one question"))
  local none = core.timeLostSummary({ entries = {}, events = {} })
  eq("view: nothing recorded -> empty", none.empty, true)
  eq("view: ...and no callouts", #none.callouts, 0)
end

print(string.format("-- time-lost.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
