-- reqs.test.lua : requirement ids and the merge receipt (2026-09-29, build program unit 22).
-- Shepherd mints REQ-NNN per repo in ~/.claude/cc-reqs.json (it is the only writer), and every
-- merge review carries v.receipt: where the work came from, the requester's words, the tests it
-- changed by layer, the evidence Shepherd gathered, and what the unit says it knowingly left.
-- Pure core, plain `lua`: JSON via the vendored parser, the store's file effects through a fake.
-- The receipt is display only -- the last section proves readiness and the card never read it.

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

local A, B = "/Users/adam/Programming/app-a", "/Users/adam/Programming/app-b"

-- ---- REQ minting: pure allocation (2026-09-29) ----
do
  local store = core.parseReqs(nil)
  check("no file yet: an empty store", type(store) == "table" and next(store.repos) == nil)
  local s1, r1 = core.mintReq(store, A, { title = "  Merge reviews carry a receipt  ", source = "Adam, chat" }, 1000)
  eq("the first requirement of a repo is REQ-001", r1 and r1.id, "REQ-001")
  eq("...its title is trimmed", r1 and r1.title, "Merge reviews carry a receipt")
  eq("...its source is kept", r1 and r1.source, "Adam, chat")
  eq("...and it records when", r1 and r1.at, 1000)
  eq("minting never changes the store it was given", #core.reqsFor(store, A), 0)
  local s2, r2 = core.mintReq(s1, A, { title = "Second" }, 1001)
  eq("the next one in the same repo is REQ-002", r2 and r2.id, "REQ-002")
  eq("...a missing source is empty, not nil", r2 and r2.source, "")
  local s3, r3 = core.mintReq(s2, B, { title = "Other repo" }, 1002)
  eq("another repo counts from its own REQ-001", r3 and r3.id, "REQ-001")
  local s4, r4 = core.mintReq(s3, A .. "/", { title = "Third" }, 1003)
  eq("a trailing slash is the same repo", r4 and r4.id, "REQ-003")
  local list = core.reqsFor(s4, A)
  eq("reqsFor: the repo's requirements, in id order", #list, 3)
  eq("...first REQ-001", list[1].id, "REQ-001")
  eq("...last REQ-003", list[3].id, "REQ-003")
  eq("reqsFor: the other repo's list is its own", #core.reqsFor(s4, B), 1)

  local _, bad, why = core.mintReq(s4, A, { title = "   " }, 1004)
  check("a blank title is refused, with a reason  (" .. tostring(why) .. ")", bad == nil and type(why) == "string")
  local _, nr, why2 = core.mintReq(s4, "relative/path", { title = "x" }, 1004)
  check("a repo that isn't an absolute path is refused  (" .. tostring(why2) .. ")", nr == nil and type(why2) == "string")
  local _, one = core.mintReq(s4, A, { title = "line one\nline two\tend", source = string.rep("s", 900) }, 1005)
  eq("a title is one line", one and one.title, "line one line two end")
  check("a long source is capped", one and #one.source <= core.REQS_SOURCE_CHARS)
  local _, long = core.mintReq(s4, A, { title = string.rep("t", 900) }, 1005)
  check("a long title is capped", long and #long.title <= core.REQS_TITLE_CHARS)

  -- ids are never reused: a hand-trimmed list or a stale counter still counts up from the highest
  local raw = core.json.encode({ v = 1, repos = { [A] = { next = 2, reqs = {
    { id = "REQ-007", title = "seven", source = "", at = 1 } } } } })
  local st = core.parseReqs(raw)
  local _, r8 = core.mintReq(st, A, { title = "after seven" }, 2000)
  eq("the next id is above the highest one on file, whatever `next` says", r8 and r8.id, "REQ-008")
  local _, r1000 = core.mintReq(core.parseReqs(core.json.encode({ v = 1, repos = { [A] = { next = 1000, reqs = {} } } })),
    A, { title = "big" }, 1)
  eq("past 999 the number just grows", r1000 and r1000.id, "REQ-1000")
end

-- ---- REQ store: parsed tolerantly, never clobbered ----
do
  local ok, s = pcall(core.parseReqs, "")
  check("an empty file is an empty store", ok and type(s) == "table" and next(s.repos) == nil)
  local s2, why = core.parseReqs("{not json")
  check("a corrupt file is NOT an empty store (minting would erase it)  (" .. tostring(why) .. ")", s2 == nil and why ~= nil)
  local s3 = core.parseReqs(core.json.encode({ v = 1, repos = { [A] = { next = 3, reqs = {
    { id = "REQ-001", title = "ok", source = "", at = 1 },
    { id = "nope", title = "a bad id" },
    { id = "REQ-002", title = 5 },
    "junk",
    { id = "REQ-002", title = "fine", source = { "not a string" }, at = "x" } } } } }))
  local l = core.reqsFor(s3, A)
  eq("rows with a bad id or title are dropped", #l, 2)
  eq("...a non-string source reads as empty", l[2] and l[2].source, "")
  eq("...a non-number time reads as 0", l[2] and l[2].at, 0)
  local s4 = core.parseReqs(core.json.encode({ v = 1, repos = { ["relative"] = { reqs = { { id = "REQ-001", title = "x" } } } } }))
  check("a repo key that isn't an absolute path is dropped", s4 and next(s4.repos) == nil)
  local round = core.parseReqs(core.encodeReqs(core.mintReq(core.parseReqs(nil), A, { title = "round trip" }, 5)))
  eq("encodeReqs round-trips through parseReqs", core.reqsFor(round, A)[1].title, "round trip")
end

-- ---- REQ commit: temp + mv, and a concurrent writer never loses an id ----
do
  -- a fake filesystem: path -> text. `race` runs once, between our read and our rename.
  local function fakeIo(files, race)
    local io_ = { renames = {}, removed = {}, tmps = {} }
    function io_.read(p) return files[p] end
    function io_.write(p, text) files[p] = text; io_.tmps[#io_.tmps + 1] = p; return true end
    function io_.rename(from, to)
      if race then local r = race; race = nil; r(files) end
      if files[to] ~= nil and io_.guard and files[to] ~= io_.guard then return false end
      files[to] = files[from]; files[from] = nil; io_.renames[#io_.renames + 1] = { from, to }; return true
    end
    function io_.remove(p) files[p] = nil; io_.removed[#io_.removed + 1] = p end
    io_.seq = 0
    function io_.token() io_.seq = io_.seq + 1; return "t" .. io_.seq end
    return io_
  end
  local P = "/home/.claude/cc-reqs.json"
  local files = {}
  local fio = fakeIo(files)
  local r, why = core.reqsMint(fio, P, A, { title = "one" }, 10)
  eq("reqsMint: mints REQ-001 into a missing file  (" .. tostring(why) .. ")", r and r.id, "REQ-001")
  check("...written to a temp file first, then moved over the store",
        #fio.renames == 1 and fio.renames[1][2] == P and fio.renames[1][1] ~= P and fio.renames[1][1]:find(P, 1, true) == 1)
  check("...and the temp file is gone", files[fio.renames[1][1]] == nil)
  eq("...the store on disk has it", core.reqsFor(core.parseReqs(files[P]), A)[1].id, "REQ-001")
  local r2 = core.reqsMint(fio, P, A, { title = "two" }, 11)
  eq("a second mint reads the file again: REQ-002", r2 and r2.id, "REQ-002")
  check("two mints never share a temp name", fio.tmps[1] ~= fio.tmps[2])

  -- another writer commits REQ-003 after our read: our write must not erase it
  local fio2 = fakeIo(files)
  local raced = false
  local realRead = fio2.read
  fio2.read = function(p)
    local got = realRead(p)
    if not raced and p == P then
      raced = true
      local s = core.mintReq(core.parseReqs(got), A, { title = "the other writer's" }, 12)
      files[P] = core.encodeReqs(s)   -- lands right after this read
    end
    return got
  end
  local r3, why3 = core.reqsMint(fio2, P, A, { title = "ours" }, 13)
  eq("a writer that raced us: ours becomes REQ-004  (" .. tostring(why3) .. ")", r3 and r3.id, "REQ-004")
  local l = core.reqsFor(core.parseReqs(files[P]), A)
  eq("...and theirs (REQ-003) survived on disk", l[3] and l[3].title, "the other writer's")
  eq("...four requirements, none lost", #l, 4)
  check("...the discarded attempt's temp file was removed", #fio2.removed >= 1 and files[fio2.removed[1]] == nil)

  -- a store that never stops changing gives up rather than looping forever
  -- (valid JSON every time, a different store every read)
  local fio3 = fakeIo(files)
  local n = 0
  fio3.read = function() n = n + 1; return core.json.encode({ v = 1, repos = {}, stamp = n }) end
  local r4, why4 = core.reqsMint(fio3, P, A, { title = "never lands" }, 14)
  check("a store that keeps changing: refused, with a reason  (" .. tostring(why4) .. ")", r4 == nil and type(why4) == "string"
        and why4:find("kept changing", 1, true) ~= nil)
  eq("...after exactly REQS_COMMIT_TRIES tries (two reads each)", n, 2 * core.REQS_COMMIT_TRIES)
  check("...and nothing was moved into place", #fio3.renames == 0)
  eq("...every temp file it wrote was removed", #fio3.removed, core.REQS_COMMIT_TRIES)

  -- a corrupt store is never overwritten
  local bad = { [P] = "{oops" }
  local fio4 = fakeIo(bad)
  local r5, why5 = core.reqsMint(fio4, P, A, { title = "x" }, 15)
  check("a corrupt store: refused  (" .. tostring(why5) .. ")", r5 == nil and type(why5) == "string")
  eq("...and left exactly as it was", bad[P], "{oops")
  check("...nothing was renamed over it", #fio4.renames == 0)
end

-- ---- the panel's add: hash-guarded, like stories-save ----
do
  local list = { { id = "REQ-001", title = "one", source = "" } }
  local h = core.reqsHash(list)
  check("reqsHash: the same list, the same hash", h == core.reqsHash({ { id = "REQ-001", title = "one", source = "" } }))
  check("reqsHash: a new requirement changes it", h ~= core.reqsHash({ list[1], { id = "REQ-002", title = "two", source = "" } }))
  check("reqsHash: an empty list has one too", type(core.reqsHash({})) == "string")
  local d = core.reqsAddDecision(list, h, { title = "  two\n", source = " Adam " })
  check("reqsAddDecision: the list the panel showed -> ok, fields trimmed",
        d.ok == true and d.fields.title == "two" and d.fields.source == "Adam")
  eq("reqsAddDecision: a list that changed since (a double click) -> refused", core.reqsAddDecision(list, "stale", { title = "x" }).error, "changed")
  eq("reqsAddDecision: a blank title -> refused", core.reqsAddDecision(list, h, { title = " " }).error, "bad-title")
  eq("reqsAddDecision: no payload -> refused", core.reqsAddDecision(list, h, nil).error, "bad-title")
end

-- ---- the Requirements tab's gate: a local session in a git repo ----
do
  eq("reqsRepoOf: a session's repo is its main checkout", core.reqsRepoOf({ mainRoot = A .. "/" }), A)
  check("reqsRepoOf: no git repo -> no tab", core.reqsRepoOf({ cwd = "/tmp/x" }) == nil)
  check("reqsRepoOf: a remote tile -> no tab", core.reqsRepoOf({ mainRoot = A, remote = "box" }) == nil)
  check("reqsRepoOf: not a tile -> nil", core.reqsRepoOf(nil) == nil)
  local hasTab = false
  for _, t in ipairs(core.DETAIL_TABS) do if t.id == "reqs" then hasTab = true end end
  check("the Requirements tab is a detail tab (id reqs)", hasTab)
end

-- ---- REQ ids named in text ----
do
  local ids = core.reqIdsIn("Implements REQ-004 and req-2; see REQ-004 again, REQ-12x is not one, xREQ-3 neither")
  eq("reqIdsIn: finds each id once, in order", table.concat(ids, ","), "REQ-004")
  local ids2 = core.reqIdsIn("REQ-7, REQ-012 (REQ-1000).")
  eq("reqIdsIn: short and long numbers, normalized to three digits", table.concat(ids2, ","), "REQ-007,REQ-012,REQ-1000")
  eq("reqIdsIn: nil text -> none", #core.reqIdsIn(nil), 0)
end

-- ---- test layers ----
do
  eq("testLayer: a core suite", core.testLayer("tests/core.test.lua"), "core")
  eq("testLayer: any Lua suite is core", core.testLayer("tests/reqs.test.lua"), "core")
  eq("testLayer: the panel pins are ui", core.testLayer("tests/ui.test.lua"), "ui")
  eq("testLayer: a real-browser test is ui", core.testLayer("tests/merge-review.browser.test.js"), "ui")
  eq("testLayer: a hook suite is bash", core.testLayer("tests/merge.test.sh"), "bash")
  eq("testLayer: a node test is node", core.testLayer("tests/receipt-view.test.js"), "node")
  eq("testLayer: a fixture file", core.testLayer("tests/fixtures/transcripts/a.jsonl"), "fixtures")
  eq("testLayer: anything else that is a test", core.testLayer("src/foo_test.go"), "other")
  eq("testLayer: not a test at all", core.testLayer("cc-core.lua"), nil)
end

-- ---- the receipt, on literal request + facts fixtures ----
local REQ = {   -- as core.parseMergeRequest returns it
  key = "k1", session_id = "s1", pid = "1", nonce = "n1", worktree = A .. "/.claude/worktrees/req-ids",
  commonDir = A .. "/.git", branch = "feat/req-ids", base = "main", phase = "requested", at = 100,
  summary = "Mints REQ ids and shows a receipt (REQ-001, REQ-009)", tests = "make lint && make test: all green",
  note = "", knownIssues = "The Requirements tab can't edit a requirement yet",
}
local FACTS = {
  listed = true, head = "feat/req-ids", sha = "abc1234", clean = true, dirty = {}, ahead = 2, behind = 0,
  commits = { { h = "abc1234", s = "REQ ids" } }, stat = "7 files changed",
  files = {
    { st = "M", path = "cc-core.lua" },
    { st = "A", path = "tests/reqs.test.lua" },
    { st = "M", path = "tests/ui.test.lua" },
    { st = "M", path = "tests/merge.test.sh" },
    { st = "A", path = "tests/receipt-view.test.js" },
    { st = "D", path = "tests/old.test.lua" },
    { st = "R", path = "tests/a.test.sh → tests/b.test.sh" },
  },
  markers = 0, markerFiles = {},
}
local STORE_LIST = { { id = "REQ-001", title = "Merge reviews carry a receipt", source = "Adam", at = 1 } }

do
  local rc = core.mergeReceipt(REQ, FACTS, { firstPrompt = "Build the receipt, please", reqs = STORE_LIST })
  check("a receipt is a table", type(rc) == "table")
  -- source
  check("source: no batch for a plain session", rc.source.batch == nil)
  eq("source: the REQ ids the request names", #rc.source.reqs, 2)
  eq("...a minted one with its title", rc.source.reqs[1].title, "Merge reviews carry a receipt")
  eq("...an id this repo never minted is marked unknown", rc.source.reqs[2].unknown, true)
  eq("...and keeps the id it was named by", rc.source.reqs[2].id, "REQ-009")
  -- the requester's words
  eq("asked: the session's first prompt, for a plain session", rc.asked and rc.asked.by, "prompt")
  eq("...its text", rc.asked and rc.asked.text, "Build the receipt, please")
  -- tests by layer
  local byLayer = {}
  for _, g in ipairs(rc.tests.layers) do byLayer[g.layer] = g.files end
  eq("tests: core", table.concat(byLayer.core or {}, ","), "tests/reqs.test.lua")
  eq("tests: ui", table.concat(byLayer.ui or {}, ","), "tests/ui.test.lua")
  eq("tests: bash (a rename counts at its new path)", table.concat(byLayer.bash or {}, ","), "tests/merge.test.sh,tests/b.test.sh")
  eq("tests: node", table.concat(byLayer.node or {}, ","), "tests/receipt-view.test.js")
  eq("tests: a deleted test file is not evidence", rc.tests.count, 5)
  eq("tests: layers in a fixed order (core ui bash node)", rc.tests.layers[1].layer .. rc.tests.layers[2].layer
     .. rc.tests.layers[3].layer .. rc.tests.layers[4].layer, "coreuibashnode")
  -- known issues
  eq("known issues: what the unit said it knowingly left", rc.knownIssues, "The Requirements tab can't edit a requirement yet")
  -- evidence with nothing gathered yet
  eq("evidence: no gate configured", rc.evidence.gate, "off")
  eq("evidence: no red-first run", rc.evidence.redFirst, "off")
  eq("evidence: no checker", rc.evidence.checker, "off")
end

do
  -- a batch unit: the driver's brief is the requester's words, and the batch is the source
  local ctx = { batch = { title = "B11: REQ ids", unit = "feat/req-ids", brief = "Unit 22: requirements get ids (REQ-001)" },
                firstPrompt = "Start unit feat/req-ids in its own worktree", reqs = STORE_LIST }
  local rc = core.mergeReceipt(REQ, FACTS, ctx, { gate = { state = "passed", command = "make test" },
                                                  redFirst = { state = "red" },
                                                  checker = { state = "done", verdict = "pass" } })
  eq("batch unit: the batch is the source", rc.source.batch and rc.source.batch.title, "B11: REQ ids")
  eq("...naming the unit", rc.source.batch and rc.source.batch.unit, "feat/req-ids")
  eq("...the driver's brief is the requester's words", rc.asked.by, "batch")
  eq("...its text", rc.asked.text, "Unit 22: requirements get ids (REQ-001)")
  eq("...REQ ids named only once, however many places name them", #rc.source.reqs, 2)
  eq("evidence: the gate's state", rc.evidence.gate, "passed")
  eq("...and its command", rc.evidence.gateCommand, "make test")
  eq("evidence: red-first", rc.evidence.redFirst, "red")
  eq("evidence: the checker's verdict", rc.evidence.checker, "pass")
  local rc2 = core.mergeReceipt(REQ, FACTS, ctx, { checker = { state = "running" }, redFirst = { state = "waiting" },
                                                   gate = { state = "running", command = "make test" } })
  eq("evidence: a checker still running says so", rc2.evidence.checker, "running")
  eq("evidence: a red-first proof still waiting says so", rc2.evidence.redFirst, "waiting")
  eq("evidence: a gate still running says so", rc2.evidence.gate, "running")
end

do
  -- the unit said nothing: no REQ ids, no known issues, no prompt on record, no facts yet
  local bare = {}
  for k, v in pairs(REQ) do bare[k] = v end
  bare.summary, bare.knownIssues = "Fix it", nil
  local rc = core.mergeReceipt(bare, nil, nil)
  check("nothing on record: still a receipt", type(rc) == "table")
  eq("...no REQ ids", #rc.source.reqs, 0)
  check("...no requester's words", rc.asked == nil)
  eq("...no tests counted until the diff is in", rc.tests.count, 0)
  eq("...and it says the diff isn't in", rc.tests.pending, true)
  check("...no known issues", rc.knownIssues == nil)
  local long = {}
  for k, v in pairs(REQ) do long[k] = v end
  local rc2 = core.mergeReceipt(long, FACTS, { firstPrompt = string.rep("w", 5000) })
  check("the requester's words are capped", #rc2.asked.text <= core.RECEIPT_ASKED_CHARS)
  local many = { files = {} }
  for i = 1, core.MERGE_FACTS_MAX_FILES do many.files[i] = { st = "A", path = "tests/t" .. i .. ".test.lua" } end
  local rc3 = core.mergeReceipt(long, many, nil)
  eq("a cut file list says the test count may be more", rc3.tests.cut, true)
  check("...and each layer lists a bounded number of files",
        #rc3.tests.layers[1].files <= core.RECEIPT_LAYER_FILES and rc3.tests.layers[1].n == core.MERGE_FACTS_MAX_FILES)
end

-- ---- the request carries --known-issues, and old requests still load ----
do
  local base = { v = 1, key = "k", session_id = "s", nonce = "n", worktree = "/r/wt", commonDir = "/r/.git",
                 branch = "feat/x", base = "main", phase = "requested", summary = "s", tests = "t", at = 1 }
  local r = core.parseMergeRequest(core.json.encode(base))
  check("a request with no known_issues still parses", r ~= nil and r.knownIssues == nil)
  base.known_issues = "  the tab can't edit yet  "
  r = core.parseMergeRequest(core.json.encode(base))
  eq("known_issues rides the request, trimmed", r and r.knownIssues, "the tab can't edit yet")
  base.known_issues = string.rep("k", 3000)
  r = core.parseMergeRequest(core.json.encode(base))
  check("...capped", r and #r.knownIssues <= 1000)
  base.known_issues = { "not", "a string" }
  r = core.parseMergeRequest(core.json.encode(base))
  check("a malformed known_issues is dropped, never the whole request", r ~= nil and r.knownIssues == nil)
  base.known_issues = "   "
  r = core.parseMergeRequest(core.json.encode(base))
  check("a blank known_issues is none", r ~= nil and r.knownIssues == nil)
end

-- ---- display only: the receipt never changes readiness, the card or the delegated verdict ----
do
  local plain = {}
  for k, v in pairs(REQ) do plain[k] = v end
  plain.knownIssues = nil
  local item = { key = "k1", status = "done", since = 0 }
  local rdWith = core.mergeReadiness(REQ, FACTS, item)
  local rdPlain = core.mergeReadiness(plain, FACTS, item)
  eq("readiness is the same with known issues on the request", rdWith.ready, rdPlain.ready)
  eq("...with the same problems", table.concat(rdWith.problems, "|"), table.concat(rdPlain.problems, "|"))
  local ctx = { batch = { title = "B", unit = "feat/req-ids", brief = "brief" }, firstPrompt = "p", reqs = STORE_LIST }
  local vWith = core.mergeView(REQ, rdWith, FACTS, { receipt = ctx }, nil, nil, { state = "notRed" })
  local vPlain = core.mergeView(plain, rdPlain, FACTS, {}, nil, nil, { state = "notRed" })
  check("the review carries the receipt", type(vWith.receipt) == "table" and vWith.receipt.asked.by == "batch")
  eq("...the card line is the same", vWith.line, vPlain.line)
  eq("...Merge is exactly as clickable", vWith.ready, vPlain.ready)
  eq("...and it wants Adam exactly as much", vWith.needsYou, vPlain.needsYou)
  local notRd = core.mergeReadiness(REQ, { listed = true, head = "feat/req-ids", clean = false, dirty = { " M x" }, ahead = 1,
                                           behind = 0, commits = {}, files = {}, markers = 0, markerFiles = {} }, item)
  local vNot = core.mergeView(REQ, notRd, FACTS, { receipt = ctx }, nil, { state = "done", verdict = "pass" }, { state = "red" })
  check("a receipt full of green evidence doesn't make a not-ready unit ready", vNot.ready == false)
  local merged = {}
  for k, v in pairs(REQ) do merged[k] = v end
  merged.phase = "merged"
  check("a finished merge carries no receipt (the review is over)", core.mergeView(merged, nil, nil, { receipt = ctx }).receipt == nil)
  -- the delegated merge reads the batch's grant, state and request -- never a receipt field
  local batch = { units = { { slug = "req-ids", branch = "feat/req-ids" } } }
  local grant = { approved = true, grantMerge = true }
  local state = { units = { ["req-ids"] = { session = { id = "s1" } } } }
  eq("the delegated merge verdict is the same with known issues", core.fleetDelegatedMerge(batch, grant, state, REQ),
     core.fleetDelegatedMerge(batch, grant, state, plain))
end

print(string.format("-- reqs.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
