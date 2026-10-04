-- past-sessions.test.lua : browse and reopen past sessions, the pure half (2026-10-04, mining round 2
-- unit F2). The 🗂 History tab lists every session the ledger saw; it now also lists every session
-- Claude Code still has a transcript for (~/.claude/projects/<project>/<session>.jsonl), and every one
-- the transcript keeper kept a copy of after Claude Code deleted the original (~/.claude/cc-keep). A
-- background scan reads each transcript's head (its first prompt, where it ran, which surface ran it)
-- and tail (its newest AI title), a capped batch at a time, never on the tick. A row offers Seance
-- and Resume. Resume reopens only a session verified dead: no card, no ~/.claude/sessions entry
-- naming it under a live process, no process using its id (a VS Code resume runs
-- `claude --resume=<id>`). VS Code reopens it with the extension's ?session= link (core.restartTabUri
-- via FX.openClaudeTab, the restart path's rule); a terminal or kitty session with `claude -r <id>`.
-- Spike S4 (2026-10-04, on 913fcf84): with its transcript moved away, ?session= opened a NEW EMPTY
-- tab (a fresh session id, no error); with the same bytes moved back, it resumed. So a kept-only
-- session is resumed by copying its kept copy back first -- never over an existing file.

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
local function finish()
  print(string.format("-- past-sessions.test.lua: %d run, %d failed --", run, failed))
  os.exit(failed == 0 and 0 or 1)
end

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = core.json or json

local fns = { "pastHeadFacts", "pastTailTitle", "pastScanPlan", "pastScanCommand", "pastScanApply", "pastSessionRows",
  "pastSessionsMerge", "pastLiveness", "pastPsCmd", "pastResumePlan", "pastRestoreArgv", "pastRestoreResult" }
local missing = {}
for _, f in ipairs(fns) do if type(core[f]) ~= "function" then missing[#missing + 1] = f end end
check("core has the past-session functions (" .. table.concat(missing, ", ") .. " missing)", #missing == 0)
check("core.PAST holds the scan's limits", type(core.PAST) == "table" and tonumber(core.PAST.headBytes) and tonumber(core.PAST.passFiles))
if #missing > 0 or type(core.PAST) ~= "table" then finish() end

local SID = "913fcf84-2494-4bed-ade2-c31543c16c04"
local function rec(t) return json.encode(t) .. "\n" end
-- a user record in Claude Code's own key order (type and message first, isMeta after the message),
-- written by hand: a torn line keeps only its start, so the order is part of the fixture
local function user(content, extra)
  extra = extra or {}
  return '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":' .. json.encode(content) .. '}'
    .. (extra.isMeta and ',"isMeta":true' or '')
    .. ',"timestamp":"2026-09-28T18:27:19.276Z","cwd":"/Users/adam/Programming/repo","sessionId":"' .. SID
    .. '","entrypoint":"claude-vscode"}\n'
end

-- ---- the head: first prompt, folder, surface (2026-10-04) ----
do
  local head = rec({ type = "queue-operation", operation = "enqueue", sessionId = SID, content = "queued text" })
    .. rec({ type = "instructions", content = "CLAUDE.md ..." })
    .. user({ { type = "text", text = "<ide_opened_file>The user opened foo.lua</ide_opened_file>" },
              { type = "text", text = "  Fix the   History tab\nso it lists past sessions  " } })
    .. user("a later prompt")
  local f = core.pastHeadFacts(head, true)
  eq("the first prompt skips an IDE tag part and takes the real text, whitespace folded", f.prompt, "Fix the History tab so it lists past sessions")
  eq("...the folder it ran in", f.cwd, "/Users/adam/Programming/repo")
  eq("...the surface that ran it", f.entrypoint, "claude-vscode")
  eq("...when it started", f.firstTs, core.isoToEpoch("2026-09-28T18:27:19.276Z"))

  -- a batch unit's first prompt arrives as a meta cross-session message: unwrapped, not skipped
  local meta = user("Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"x\">\n"
    .. "Start unit feat/past-sessions in its own worktree.\n</cross-session-message>", { isMeta = true })
  eq("a unit's cross-session first prompt is unwrapped", core.pastHeadFacts(meta, true).prompt, "Start unit feat/past-sessions in its own worktree.")
  -- any other meta record (a hook's injected context) is no prompt
  local other = user("Caveat: the messages below were generated by the user while running local commands.", { isMeta = true })
    .. user("the real one")
  eq("another meta record is skipped", core.pastHeadFacts(other, true).prompt, "the real one")
  eq("a slash command names the session", core.pastHeadFacts(user("<command-name>/clear</command-name>"), true).prompt, "/clear")
  local tool = user({ { type = "tool_result", tool_use_id = "t1", content = "out" } }) .. user("after the tool")
  eq("a tool result is no prompt", core.pastHeadFacts(tool, true).prompt, "after the tool")
  local long = string.rep("word ", 200)
  check("a long prompt is capped", #core.pastHeadFacts(user(long), true).prompt <= core.PAST.promptMax + 3)

  -- 2026-10-04: a fixed-size head ends mid-line; that line is never decoded (LuaSkin logs a JSON
  -- error even inside pcall) and never walked with a *-quantified pattern (quadratic backtracking)
  local torn = user("the first") .. string.sub(user("torn " .. string.rep("x", 40000)), 1, 30000)
  local t0 = os.clock()
  local tf = core.pastHeadFacts(torn, false)
  local secs = os.clock() - t0
  eq("a torn last line is left alone", tf.prompt, "the first")
  check("...and walking it is linear (" .. string.format("%.3f", secs) .. "s)", secs < 0.05)
  -- (requirement changed in this unit, before it shipped: a torn user line's text start is read, below)
  eq("a head whose only user line is torn reads that line's text start, never decoding it",
     (core.pastHeadFacts(string.sub(user("only " .. string.rep("y", 9000)), 1, 5000), false).prompt or ""):sub(1, 7), "only yy")
  eq("...but a whole file with no trailing newline still has its last line",
     core.pastHeadFacts((user("no newline at the end"):gsub("\n$", "")), true).prompt, "no newline at the end")
  -- 2026-10-04: 18 of Adam's 212 transcripts open with a user line longer than the head (a long
  -- paste, or an image ahead of the text). A long text's start is read from the torn line without
  -- decoding it; an image-led one has no prompt in reach, but it is still a session (user = true)
  local pasted = user("Hi there! i need your help\nwith scoping " .. string.rep("q", 50000))
  local pf = core.pastHeadFacts(string.sub(pasted, 1, 20000), false)
  check("a first prompt longer than the head is read from its torn line (" .. tostring(pf.prompt) .. ")",
        pf.prompt ~= nil and pf.prompt:sub(1, 26) == "Hi there! i need your help")
  check("...unescaped, whitespace folded", pf.prompt ~= nil and pf.prompt:find("help with scoping", 1, true) ~= nil)
  local img = user({ { type = "image", source = { type = "base64", media_type = "image/png", data = string.rep("A", 60000) } },
                     { type = "text", text = "what's in this picture?" } })
  local imf = core.pastHeadFacts(string.sub(img, 1, 20000), false)
  check("an image-led first line has no prompt in reach", imf.prompt == nil)
  check("...but it is a session all the same", imf.user == true)
  local metaTorn = string.sub(user("Another Claude session sent a message:\n<cross-session-message from=\"x\">\nStart unit fix/y now. "
    .. string.rep("z", 40000), { isMeta = true }), 1, 9000)
  check("a torn unit brief is unwrapped too", (core.pastHeadFacts(metaTorn, false).prompt or ""):sub(1, 21) == "Start unit fix/y now.")
  -- a title-only stub (79 of Adam's 291 transcripts, 2026-10-04) has no prompt
  local stub = rec({ type = "ai-title", aiTitle = "Improve session safety", sessionId = SID })
  eq("a title-only stub has no prompt", core.pastHeadFacts(stub, true).prompt, nil)
  eq("garbage is no facts", core.pastHeadFacts(nil, true).prompt, nil)
end

-- ---- the tail: the newest AI title ----
do
  local tail = "torn-start-of-a-line\"}\n" .. rec({ type = "ai-title", aiTitle = "Old title", sessionId = SID })
    .. user("x") .. rec({ type = "ai-title", aiTitle = "Newest title", sessionId = SID }) .. user("y")
  eq("the newest AI title in the tail", core.pastTailTitle(tail, false), "Newest title")
  eq("a tail with none", core.pastTailTitle(user("x") .. user("y"), false), nil)
  -- the tail's first line is torn unless the tail is the whole file
  local whole = rec({ type = "ai-title", aiTitle = "Only title", sessionId = SID })
  eq("a whole-file tail reads its first line", core.pastTailTitle(whole, true), "Only title")
  eq("...a partial tail never decodes its torn first line", core.pastTailTitle(whole, false), nil)
  check("a long title is capped", #core.pastTailTitle(rec({ type = "ai-title", aiTitle = string.rep("t", 400) }), true) <= core.PAST.titleMax + 3)
end

-- ---- the scan plan: only what changed, newest first, a capped batch per pass ----
do
  local P = "/h/.claude/projects/-r-A/"
  local files = {
    { path = P .. "a.jsonl", pk = "-r-A", sid = "aaaa", size = 100, mtime = 10 },
    { path = P .. "b.jsonl", pk = "-r-A", sid = "bbbb", size = 900000, mtime = 30 },
    { path = P .. "c.jsonl", pk = "-r-A", sid = "cccc", size = 500, mtime = 20 },
  }
  local reads, behind = core.pastScanPlan({}, files, { passFiles = 2 })
  eq("a first scan reads the newest first, capped per pass", #reads, 2)
  eq("...newest", reads[1] and reads[1].path, P .. "b.jsonl")
  eq("...then the next", reads[2] and reads[2].path, P .. "c.jsonl")
  check("...and says more is left", behind == true)
  check("...each read takes the head and the tail", reads[1].head == true and reads[1].tail == true)
  check("...a small file's head and tail are the whole file", reads[2].wholeHead == true and reads[2].wholeTail == true
        and reads[1].wholeHead == false and reads[1].wholeTail == false)

  -- land them
  local cache = {}
  local headB = user("the b prompt") .. string.rep("z", 10)
  -- a big file's tail starts mid-line
  cache[P .. "b.jsonl"] = core.pastScanApply(nil, reads[1], headB, 'torn"}\n' .. rec({ type = "ai-title", aiTitle = "B title" }))
  eq("...and its title from the tail", cache[P .. "b.jsonl"].title, "B title")
  cache[P .. "c.jsonl"] = core.pastScanApply(nil, reads[2], user("the c prompt"), user("the c prompt"))
  eq("an applied read keeps the prompt", cache[P .. "b.jsonl"].facts.prompt, "the b prompt")
  check("...a big file's head is done once its prompt is found", cache[P .. "b.jsonl"].headDone == true)
  reads, behind = core.pastScanPlan(cache, files, { passFiles = 2 })
  eq("the next pass reads only what's left", #reads, 1)
  eq("...the oldest", reads[1] and reads[1].path, P .. "a.jsonl")
  check("...and nothing is left after it", behind == false)
  cache[P .. "a.jsonl"] = core.pastScanApply(nil, reads[1], "", "")
  eq("an unchanged set reads nothing", #core.pastScanPlan(cache, files, {}), 0)

  -- a live session's transcript grows: its tail is read again, its finished head isn't
  files[2].size, files[2].mtime = 950000, 40
  reads = core.pastScanPlan(cache, files, {})
  check("a grown transcript re-reads its tail only", #reads == 1 and reads[1].tail == true and reads[1].head == false)
  cache[P .. "b.jsonl"] = core.pastScanApply(cache[P .. "b.jsonl"], reads[1], nil, 'torn"}\n' .. rec({ type = "ai-title", aiTitle = "B newer" }))
  eq("...the prompt survives a tail-only read", cache[P .. "b.jsonl"].facts.prompt, "the b prompt")
  eq("...and the title moves on", cache[P .. "b.jsonl"].title, "B newer")
  -- a fresh session with no prompt yet keeps reading its head until one shows up
  files[1].size, files[1].mtime = 300, 50
  reads = core.pastScanPlan(cache, files, {})
  check("a small transcript with no prompt yet reads its head again as it grows", #reads == 1 and reads[1].head == true)
  -- a file that shrank was replaced: read from scratch
  files[3].size = 100
  reads = core.pastScanPlan(cache, files, {})
  local r3
  for _, r in ipairs(reads) do if r.path == P .. "c.jsonl" then r3 = r end end
  check("a transcript that shrank is read from scratch", r3 ~= nil and r3.head == true and r3.fresh == true)

  -- the command: every path single-quoted, head and tail into their own scratch files
  local cmd = core.pastScanCommand({ { path = "/x/it's.jsonl", head = true, tail = true }, { path = "/x/b.jsonl", tail = true } }, "/tmp/out")
  check("the scan command quotes every path", cmd:find("'/x/it'\\''s.jsonl'", 1, true) ~= nil)
  check("...reads a head and a tail into their own files", cmd:find("head -c " .. core.PAST.headBytes, 1, true) ~= nil
        and cmd:find("> '/tmp/out.1.h'", 1, true) ~= nil and cmd:find("tail -c " .. core.PAST.tailBytes, 1, true) ~= nil
        and cmd:find("> '/tmp/out.1.t'", 1, true) ~= nil)
  check("...and only the tail where the head isn't wanted", cmd:find("/tmp/out.2.h", 1, true) == nil and cmd:find("/tmp/out.2.t", 1, true) ~= nil)
end

-- ---- rows: one per session with a prompt; kept copies; headless runs left out ----
do
  local P, K = "/h/.claude/projects/", "/h/.claude/cc-keep/"
  local files = {
    { path = P .. "-r-A/s1.jsonl", pk = "-r-A", sid = "s1", size = 2048, mtime = 100 },
    { path = P .. "-r-A/s2.jsonl", pk = "-r-A", sid = "s2", size = 120, mtime = 90 },             -- a title-only stub
    { path = K .. "-r-A/s3.jsonl", pk = "-r-A", sid = "s3", size = 4096, mtime = 80, keptOnly = true },
    { path = P .. "-r-B/s4.jsonl", pk = "-r-B", sid = "s4", size = 999, mtime = 70, kept = true },
    { path = P .. "-r-B/s5.jsonl", pk = "-r-B", sid = "s5", size = 999, mtime = 60 },             -- Shepherd's own claude -p
    { path = P .. "-r-B/s6.jsonl", pk = "-r-B", sid = "s6", size = 99999, mtime = 55 },           -- opened with an image
  }
  local cache = {
    [files[1].path] = { facts = { prompt = "fix it", cwd = "/r/A", entrypoint = "claude-vscode", firstTs = 50 }, title = "Fixing it" },
    [files[2].path] = { facts = {}, title = "A stub" },
    [files[3].path] = { facts = { prompt = "old work", cwd = "/r/A" } },
    [files[4].path] = { facts = { prompt = "b work", cwd = "/r/B", entrypoint = "cli" } },
    [files[5].path] = { facts = { prompt = "review this diff", cwd = "/r/B", entrypoint = "sdk-cli" } },
    [files[6].path] = { facts = { user = true, cwd = "/r/B", entrypoint = "claude-vscode" } },
  }
  local rows = core.pastSessionRows(files, cache)
  local by = {}
  for _, r in ipairs(rows) do by[r.session_id] = r end
  eq("a row per session that has a user line", #rows, 4)
  check("...one that opened with an image is a row with no prompt", by.s6 and by.s6.prompt == nil)
  check("...not a title-only stub", by.s2 == nil)
  check("...not a headless run (Shepherd's coach, checker or Seance)", by.s5 == nil)
  check("a row carries its prompt, title, folder and size", by.s1 and by.s1.prompt == "fix it" and by.s1.title == "Fixing it"
        and by.s1.cwd == "/r/A" and by.s1.size == 2048 and by.s1.mtime == 100 and by.s1.projectKey == "-r-A")
  check("...and a readable size", by.s1 and by.s1.sizeHuman == core.fmtBytes(2048))
  check("a kept-only row says so", by.s3 and by.s3.keptOnly == true and by.s3.kept == true)
  check("a row with a copy besides its original says so", by.s4 and by.s4.kept == true and not by.s4.keptOnly)
  check("no scan entry yet: no row", #core.pastSessionRows(files, {}) == 0)
end

-- ---- merged with the ledger's records ----
do
  local recs = {
    { session_id = "s1", name = "repo-ea", projectKey = "-r-A", lastTs = 100, prompts = 3, toolRequests = 4, events = 9 },
    { session_id = "s9", name = "gone", projectKey = "-r-A", lastTs = 50, prompts = 1, toolRequests = 0, events = 2 },
  }
  local rows = {
    { session_id = "s1", projectKey = "-r-A", prompt = "fix it", size = 2048, sizeHuman = "2.0 KB", mtime = 200, cwd = "/r/A" },
    { session_id = "s3", projectKey = "-r-A", prompt = "old work", size = 4096, sizeHuman = "4.0 KB", mtime = 80, keptOnly = true, kept = true },
    { session_id = "s4", projectKey = "-r-B", prompt = "live one", size = 10, sizeHuman = "10 B", mtime = 300 },
  }
  local out = core.pastSessionsMerge(recs, rows, { scanned = true, live = { s4 = true } })
  local by = {}
  for _, r in ipairs(out) do by[r.session_id] = r end
  eq("every ledger record and every transcript, once each", #out, 4)
  check("a ledger record gains its transcript's facts", by.s1 and by.s1.past and by.s1.past.prompt == "fix it" and by.s1.prompts == 3)
  eq("...its last activity is the later of the two", by.s1 and by.s1.lastTs, 200)
  check("...and the ledger's own records are left untouched", recs[1].past == nil and recs[1].lastTs == 100)
  check("a transcript the ledger never saw is a row of its own", by.s3 and by.s3.transcriptOnly == true and by.s3.lastTs == 80
        and by.s3.past.prompt == "old work" and by.s3.keptOnly == true)
  check("a ledger record with no transcript anywhere, once the scan is done, says so", by.s9 and by.s9.noTranscript == true)
  check("...and can't be resumed", by.s9 and not by.s9.canResume)
  check("a live session can't be resumed", by.s4 and by.s4.live == true and not by.s4.canResume)
  check("an ended one with a transcript can", by.s1 and by.s1.canResume == true)
  check("...and so can one with only its kept copy left (spike S4)", by.s3 and by.s3.canResume == true)
  local early = core.pastSessionsMerge(recs, nil, { scanned = false })
  check("before the scan has finished, no record is called transcript-less", early[1].noTranscript == nil and early[2].noTranscript == nil)
end

-- ---- verified dead: no card, no live session file, no process using it ----
do
  local ME = "4242"
  local LS = "Sun Oct  4 10:46:30 2026"
  local function ps(lines)
    local out = { string.format("%5s %s /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon", ME, "Thu Oct  1 09:00:00 2026") }
    for _, l in ipairs(lines) do out[#out + 1] = l end
    return table.concat(out, "\n") .. "\n"
  end
  local dead, why = core.pastLiveness(SID, { psOut = ps({ " 100 " .. LS .. " /bin/zsh -l" }), me = ME, registry = {}, liveIds = {} })
  eq("nothing names it anywhere: dead", dead, "dead")
  dead, why = core.pastLiveness(SID, { psOut = ps({}), me = ME, registry = {}, liveIds = { [SID] = true } })
  check("a card has it: alive (" .. tostring(why) .. ")", dead == "alive")
  -- 2026-10-04, spike S4: VS Code ran the resumed session as `claude ... --resume=<id>`
  dead, why = core.pastLiveness(SID, { psOut = ps({ "66494 " .. LS .. " /Users/adam/.vscode/extensions/anthropic.claude-code/claude --output-format stream-json --resume=" .. SID .. " --setting-sources=user" }),
    me = ME, registry = {}, liveIds = {} })
  check("a VS Code process resuming it (--resume=<id>): alive (" .. tostring(why) .. ")", dead == "alive" and tostring(why):find("66494", 1, true) ~= nil)
  dead = core.pastLiveness(SID, { psOut = ps({ "  777 " .. LS .. " claude -r " .. SID }), me = ME, registry = {}, liveIds = {} })
  eq("a terminal `claude -r <id>`: alive", dead, "alive")
  dead = core.pastLiveness(SID, { psOut = ps({ "  777 " .. LS .. " claude --resume " .. SID }), me = ME, registry = {}, liveIds = {} })
  eq("a `claude --resume <id>`: alive", dead, "alive")
  -- Claude Code's own session file names it under a process that still runs
  local reg = { ["555"] = { pid = 555, sessionId = SID, procStart = LS } }
  dead, why = core.pastLiveness(SID, { psOut = ps({ "  555 " .. LS .. " claude" }), me = ME, registry = reg, liveIds = {} })
  check("a session file naming it under a live process: alive (" .. tostring(why) .. ")", dead == "alive")
  -- ...but a crash leaves the file behind: its process gone, or its pid another process now
  eq("a session file whose process is gone is stale", core.pastLiveness(SID, { psOut = ps({}), me = ME, registry = reg, liveIds = {} }), "dead")
  eq("...and one whose pid is another process now",
     core.pastLiveness(SID, { psOut = ps({ "  555 Mon Oct  5 08:00:00 2026 /usr/bin/other" }), me = ME, registry = reg, liveIds = {} }), "dead")
  -- a ps that can't see Shepherd itself proves nothing
  dead, why = core.pastLiveness(SID, { psOut = "  100 " .. LS .. " /bin/zsh\n", me = ME, registry = {}, liveIds = {} })
  check("a ps without Shepherd's own pid: unknown (" .. tostring(why) .. ")", dead == "unknown")
  eq("...nor does no ps at all", core.pastLiveness(SID, { psOut = nil, me = ME, registry = {}, liveIds = {} }), "unknown")
  eq("not a session id: unknown", core.pastLiveness("bad id; rm -rf", { psOut = ps({}), me = ME }), "unknown")
  -- the probe: one ps for every process, full command lines, in Claude Code's zone and locale
  local cmd = core.pastPsCmd()
  check("the probe asks ps for every process's start and full command line",
        cmd:find("ps -axww -o pid=,lstart=,command=", 1, true) ~= nil and cmd:find("LC_ALL=C TZ=UTC", 1, true) == 1)
end

-- ---- the resume plan ----
do
  local dirs = { ["/r/A"] = true, ["/r/A/.claude/worktrees/x"] = false }
  local function isDir(d) return dirs[d] == true end
  local base = { sid = SID, pk = "-r-A", original = "/h/.claude/projects/-r-A/" .. SID .. ".jsonl", originalExists = true,
                 keptPath = "/h/.claude/cc-keep/-r-A/" .. SID .. ".jsonl", keptExists = false, cwd = "/r/A",
                 entrypoint = "claude-vscode", editor = "vscode" }
  local function with(over) local t = {}; for k, v in pairs(base) do t[k] = v end; for k, v in pairs(over) do t[k] = v end; return t end
  local p, why = core.pastResumePlan(base, isDir)
  check("a VS Code session reopens as its tab (" .. tostring(why) .. ")", p and p.how == "tab" and p.editor == "vscode" and p.dir == "/r/A" and p.id == SID)
  check("...with nothing to restore", p and p.restore == nil)
  p = core.pastResumePlan(with({ editor = "cursor" }), isDir)
  check("...in Cursor when that's the editor Shepherd spawns in", p and p.editor == "cursor" and p.how == "tab")
  p = core.pastResumePlan(with({ entrypoint = "cli", editor = "kitty" }), isDir)
  check("a CLI session reopens with claude -r in kitty", p and p.how == "shell" and p.editor == "kitty")
  p = core.pastResumePlan(with({ entrypoint = "cli", editor = "vscode" }), isDir)
  check("...or in Terminal when Shepherd spawns VS Code tabs", p and p.how == "shell" and p.editor == "terminal")
  p = core.pastResumePlan(with({ originalExists = false, keptExists = true }), isDir)
  check("only its kept copy left: restored to its original path first (spike S4)", p and p.restore
        and p.restore.from == base.keptPath and p.restore.to == base.original)
  p, why = core.pastResumePlan(with({ originalExists = false, keptExists = false }), isDir)
  check("no transcript and no copy: refused (" .. tostring(why) .. ")", p == nil and tostring(why):find("gone", 1, true) ~= nil)
  p, why = core.pastResumePlan(with({ entrypoint = "sdk-cli" }), isDir)
  check("a headless run: refused (" .. tostring(why) .. ")", p == nil)
  p, why = core.pastResumePlan(with({ pk = "-r-A--claude-worktrees-x", cwd = "/r/A/.claude/worktrees/x" }), isDir)
  check("its folder is gone (a removed worktree): refused (" .. tostring(why) .. ")", p == nil and tostring(why):find("/r/A/.claude/worktrees/x", 1, true) ~= nil)
  p, why = core.pastResumePlan(with({ cwd = "/elsewhere" }), isDir)
  check("a folder that doesn't encode to its project: refused (" .. tostring(why) .. ")", p == nil)
  check("not a session id: refused", core.pastResumePlan(with({ sid = "x; rm -rf /" }), isDir) == nil)
  check("not a project key: refused", core.pastResumePlan(with({ pk = "../etc" }), isDir) == nil)
end

-- ---- the restore: the kept copy back to its original path, never over a file (run for real) ----
do
  local T = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
  check("mktemp a fixture dir", T ~= "")
  local PROJ, KEEP = T .. "/projects", T .. "/cc-keep"
  sh("mkdir -p " .. q(PROJ .. "/-r-A") .. " " .. q(KEEP .. "/-r-A"))
  local from, to = KEEP .. "/-r-A/" .. SID .. ".jsonl", PROJ .. "/-r-A/" .. SID .. ".jsonl"
  writeFile(from, user("kept bytes"))
  sh("touch -t 202601010000 " .. q(from))
  check("only a kept copy and its own original path pass",
        core.pastRestoreArgv(from, PROJ .. "/-r-A/other.jsonl", KEEP, PROJ) == nil
        and core.pastRestoreArgv(T .. "/x.jsonl", to, KEEP, PROJ) == nil
        and core.pastRestoreArgv(from, to, KEEP, PROJ) ~= nil)
  local function runArgv(argv)
    local parts = { "/bin/sh" }
    for _, a in ipairs(argv) do parts[#parts + 1] = q(a) end
    local p = io.popen(table.concat(parts, " ") .. " 2>&1; echo \"@@rc $?\"")
    local o = p:read("*a"); p:close()
    return tonumber(o:match("@@rc (%d+)")), o
  end
  local code, out = runArgv(core.pastRestoreArgv(from, to, KEEP, PROJ))
  local ok, res = core.pastRestoreResult(code, out)
  check("the restore lands (" .. tostring(res) .. ")", ok == true)
  eq("...byte for byte", readAll(to), readAll(from))
  local mtime = tonumber((sh("stat -f %m " .. q(to) .. " 2>/dev/null || stat -c %Y " .. q(to)):gsub("%s+$", "")))
  check("...with a fresh mtime, so cleanupPeriodDays doesn't take it again at once", mtime and mtime > os.time() - 600)
  eq("...private, like Claude Code's own", (sh("stat -f %Lp " .. q(to) .. " 2>/dev/null || stat -c %a " .. q(to)):gsub("%s+$", "")), "600")
  check("...and no part file is left behind", sh("ls " .. q(PROJ .. "/-r-A")):gsub("%s+$", "") == SID .. ".jsonl")
  -- never over an existing transcript
  writeFile(to, user("a newer session wrote here"))
  code, out = runArgv(core.pastRestoreArgv(from, to, KEEP, PROJ))
  ok, res = core.pastRestoreResult(code, out)
  check("a file at the original path is never overwritten (" .. tostring(res) .. ")", ok == false and readAll(to) == user("a newer session wrote here"))
  check("...and no part file is left behind", sh("ls " .. q(PROJ .. "/-r-A")):gsub("%s+$", "") == SID .. ".jsonl")
  sh("rm -r " .. q(T))
end

finish()
