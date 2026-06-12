-- core.test.lua : standalone unit tests for cc-core.lua. Run with plain `lua`.
-- No Hammerspoon, no side effects: JSON via the vendored parser, effects via the
-- recorder. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")
local newRecorder = dofile(HERE .. "support/fx_recorder.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then
    print("ok   - " .. name)
  else
    failed = failed + 1
    print("FAIL - " .. name)
  end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

local function entry(key, tbl) return { key = key, content = core.json.encode(tbl) } end

-- ---- config: dotted lookup with safe defaults ------------------------------
do
  local cfg = core.json.decode(
    '{"queue":{"autofeed":true},"policies":{"approveRepeats":false,"autopilot":{"minutes":15}}}')
  eq("config: nested true", core.config(cfg, "queue.autofeed", false), true)
  eq("config: false preserved (not default)", core.config(cfg, "policies.approveRepeats", true), false)
  eq("config: missing key -> default", core.config(cfg, "policies.patterns.enabled", false), false)
  eq("config: deep value", core.config(cfg, "policies.autopilot.minutes", 0), 15)
  eq("config: nil table -> default", core.config(nil, "a.b", "d"), "d")
end

-- ---- overlayConfig: Settings Save must not delete hand-edited fields --------
do
  local cfg = {
    spawn = { editor = "kitty", kittyBin = "/opt/kitty/kitty", kittySocket = "unix:/tmp/k" },
    escalation = { enabled = true, minutes = 5, hung = { enabled = true, minutes = 10 } },
    risk = { enabled = true },  -- block absent from THIS incoming -> must survive
  }
  local incoming = {
    spawn = { editor = "terminal", live = true, provider = "" },  -- the form's spawn shape
    escalation = { enabled = false, minutes = 3 },                -- no `hung` subkey
    providers = { { id = "a" } },
  }
  local out = core.overlayConfig(cfg, incoming)
  eq("overlay: form field updated", out.spawn.editor, "terminal")
  eq("overlay: kittyBin carried forward", out.spawn.kittyBin, "/opt/kitty/kitty")
  eq("overlay: kittySocket carried forward", out.spawn.kittySocket, "unix:/tmp/k")
  eq("overlay: escalation.hung carried forward", out.escalation.hung.minutes, 10)
  eq("overlay: escalation form field wins", out.escalation.enabled, false)
  eq("overlay: unexposed top-level block survives", out.risk.enabled, true)
  eq("overlay: array-valued key replaced wholesale", #out.providers, 1)
  -- a Save that DOES carry the subkey (e.g. a future UI field) wins over disk
  local out2 = core.overlayConfig({ spawn = { kittyBin = "/old" } }, { spawn = { kittyBin = "/new" } })
  eq("overlay: incoming subkey beats the on-disk one", out2.spawn.kittyBin, "/new")
  -- degenerate inputs are safe
  eq("overlay: nil incoming -> cfg unchanged", core.overlayConfig({ a = 1 }, nil).a, 1)
  eq("overlay: nil cfg -> incoming kept", core.overlayConfig(nil, { a = 2 }).a, 2)
  -- risk: the Settings form now manages enabled+thresholds but NEVER sends
  -- weights -- the hand-edited tuning map must ride through a wholesale save.
  local riskCfg = { risk = { enabled = false, weights = { denyRate = 99 },
                             thresholds = { med = 10, high = 20, staleSeconds = 30 } } }
  local riskIn  = { risk = { enabled = true,
                             thresholds = { med = 40, high = 70, staleSeconds = 300 } } }
  local rOut = core.overlayConfig(riskCfg, riskIn)
  eq("overlay: risk form field wins", rOut.risk.enabled, true)
  eq("overlay: hand-edited risk.weights survives the save", rOut.risk.weights.denyRate, 99)
  eq("overlay: risk.thresholds replaced wholesale", rOut.risk.thresholds.med, 40)
  -- an incoming that DOES carry weights (hand-rolled save-config) wins over disk
  local rOut2 = core.overlayConfig({ risk = { weights = { denyRate = 1 } } },
                                   { risk = { weights = { denyRate = 2 } } })
  eq("overlay: explicit incoming risk.weights beats disk", rOut2.risk.weights.denyRate, 2)
  -- first-ever save on a config with no risk block: form block lands intact
  local rOut3 = core.overlayConfig({}, { risk = { enabled = true } })
  eq("overlay: risk block created on first save", rOut3.risk.enabled, true)
  -- spawn search keys (fd fuzzy search) ride through like kittyBin
  local sOut = core.overlayConfig(
    { spawn = { searchRoots = { "/a" }, searchDepth = 6, fdBin = "/opt/fd" } },
    { spawn = { editor = "kitty" } })
  eq("overlay: spawn.searchRoots carried forward", sOut.spawn.searchRoots[1], "/a")
  eq("overlay: spawn.searchDepth carried forward", sOut.spawn.searchDepth, 6)
  eq("overlay: spawn.fdBin carried forward", sOut.spawn.fdBin, "/opt/fd")
end

-- ---- parseStatusList: decode + stale + approvals-first sort ----------------
do
  local now = 10000
  local entries = {
    entry("a", { name = "alpha",   status = "idle",     updated = now }),
    entry("b", { name = "bravo",   status = "approval", updated = now }),
    entry("c", { name = "charlie", status = "working",  updated = now - 1000 }), -- stale
    entry("d", { name = "delta",   status = "done",     updated = now }),
    entry("f", { name = "echo",    status = "error",    updated = now }),  -- frozen on API error
    { key = "junk", content = "{ not json" },             -- dropped (malformed)
    entry("e", { status = "idle", updated = now }),        -- dropped (no name)
  }
  local list = core.parseStatusList(entries, now, 90)
  eq("parse: keeps 5 valid entries", #list, 5)
  eq("parse: approval sorts first", list[1].status, "approval")
  eq("parse: error sorts right after approval", list[2].status, "error")
  eq("parse: approval is bravo", list[1].name, "bravo")
  eq("parse: key tagged", list[1].key, "b")
  -- find charlie and assert stale; alpha not stale
  local charlie, alpha
  for _, it in ipairs(list) do
    if it.name == "charlie" then charlie = it end
    if it.name == "alpha" then alpha = it end
  end
  eq("parse: old entry is stale", charlie.stale, true)
  eq("parse: fresh entry not stale", alpha.stale, false)
end

-- ---- resolveGesture: gate-aware short/long press ---------------------------
do
  local waiting = { gate = "waiting" }
  local normal  = {}
  eq("gesture: waiting + short = approve", core.resolveGesture(waiting, "primary"), "approve")
  eq("gesture: waiting + long  = deny",    core.resolveGesture(waiting, "secondary"), "deny")
  eq("gesture: normal  + short = focus",   core.resolveGesture(normal, "primary"), "focus")
  eq("gesture: normal  + long  = focus (default)", core.resolveGesture(normal, "secondary"), "focus")
  eq("gesture: normal  + long  = stop (opt-in)",
     core.resolveGesture(normal, "secondary", { longPressStops = true }), "stop")
end

-- ---- handleAction: routes to the right effect, gate-aware ------------------
do
  local waiting = { key = "w1", name = "proj-w", gate = "waiting" }
  local normal  = { key = "n1", name = "proj-n", cwd = "/Users/x/proj-n" }

  local r = newRecorder()
  core.handleAction(r.fx, waiting, "approve")
  eq("approve(waiting): writeDecision op", r.last().op, "writeDecision")
  eq("approve(waiting): allow value", r.last().b, "allow")

  r = newRecorder()
  core.handleAction(r.fx, normal, "approve")
  eq("approve(normal): actOnWindow op", r.last().op, "actOnWindow")
  eq("approve(normal): targets window name", r.last().a, "proj-n")
  eq("approve(normal): uses APPROVE key", r.last().b.key, "return")

  r = newRecorder()
  core.handleAction(r.fx, waiting, "deny")
  eq("deny(waiting): writeDecision deny", r.last().b, "deny")

  r = newRecorder()
  core.handleAction(r.fx, normal, "deny")
  eq("deny(normal): uses DENY key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "stop")
  eq("stop: actOnWindow", r.last().op, "actOnWindow")
  eq("stop: uses STOP key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "run the tests")
  eq("nudge: pasteIntoWindow op", r.last().op, "pasteIntoWindow")
  eq("nudge: passes text in payload", r.last().b.text, "run the tests")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "")
  eq("nudge: empty text is a no-op", r.count(), 0)

  r = newRecorder()
  core.handleAction(r.fx, normal, "focus")
  eq("focus: focusWindow op", r.last().op, "focusWindow")
  eq("focus: targets name", r.last().a, "proj-n")
  eq("focus: passes cwd for ancestor matching", r.last().b, "/Users/x/proj-n")

  -- model: live /model switch types the slash command into the window
  r = newRecorder()
  core.handleAction(r.fx, normal, "model", "claude-sonnet-4-6")
  eq("model: typeIntoWindow op", r.last().op, "typeIntoWindow")
  eq("model: types the /model command", r.last().b, "/model claude-sonnet-4-6")

  r = newRecorder()
  core.handleAction(r.fx, normal, "model", "")
  eq("model: empty id is a no-op", r.count(), 0)

  -- continue: resume a session frozen on an API error by typing "continue" + Enter
  r = newRecorder()
  core.handleAction(r.fx, normal, "continue")
  eq("continue: typeIntoWindow op", r.last().op, "typeIntoWindow")
  eq("continue: types the word continue", r.last().b, "continue")
end

-- ---- deckLayout: row-major fill + overflow ---------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  local lay = core.deckLayout(2, list)
  eq("deck: fills 2 keys", lay.items[1].key, "a")
  eq("deck: 2nd key", lay.items[2].key, "b")
  eq("deck: no 3rd key", lay.items[3], nil)
  eq("deck: overflow counts the rest", lay.overflow, 1)

  local lay2 = core.deckLayout(15, list)
  eq("deck: no overflow when room", lay2.overflow, 0)
  eq("deck: empty keys are nil", lay2.items[4], nil)
end

-- ---- hotkey helpers --------------------------------------------------------
do
  local list = {
    { name = "a", status = "done" },
    { name = "b", status = "approval" },
    { name = "c", status = "approval" },
  }
  eq("nextApproval: first approval", core.nextApproval(list).name, "b")
  eq("frontSession: first item", core.frontSession(list).name, "a")
  eq("nextApproval: none -> nil", core.nextApproval({ { status = "idle" } }), nil)
end

-- ---- cycleNext: wrapping jump target ---------------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  eq("cycle: nil start -> first", core.cycleNext(list, nil).key, "a")
  eq("cycle: after a -> b", core.cycleNext(list, "a").key, "b")
  eq("cycle: after c wraps -> a", core.cycleNext(list, "c").key, "a")
  eq("cycle: unknown key -> first", core.cycleNext(list, "zzz").key, "a")
  eq("cycle: empty list -> nil", core.cycleNext({}, "a"), nil)
end

-- ---- hotkey wiring: front approval -> approve via recorder -----------------
do
  local list = {
    { key = "w", name = "proj-w", status = "approval", gate = "waiting" },
    { key = "n", name = "proj-n", status = "working" },
  }
  local r = newRecorder()
  local target = core.nextApproval(list)
  core.handleAction(r.fx, target, "approve")
  eq("hotkey approve-front: targets the approval", target.key, "w")
  eq("hotkey approve-front: hands-free writeDecision", r.last().op, "writeDecision")
  eq("hotkey approve-front: allow", r.last().b, "allow")
end

-- ---- transcriptSnippet: latest assistant text from a jsonl tail -----------
do
  local function aline(text) -- an assistant line carrying one text block
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end
  local function toolline() -- an assistant line that is only a tool_use
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "tool_use", name = "Bash" } } } })
  end
  local userline = core.json.encode({ type = "user", message = { role = "user" } })

  -- last assistant text is "Refactoring the parser", even though a tool_use
  -- line and a user line come after it.
  local jsonl = table.concat({
    userline,
    aline("Refactoring the parser   now"),
    toolline(),
  }, "\n")
  eq("snippet: finds last assistant text (whitespace collapsed)",
     core.transcriptSnippet(jsonl), "Refactoring the parser now")

  eq("snippet: empty input -> nil", core.transcriptSnippet(""), nil)
  eq("snippet: no assistant text -> nil",
     core.transcriptSnippet(userline .. "\n" .. toolline()), nil)
  eq("snippet: garbled lines are skipped",
     core.transcriptSnippet("{ not json\n" .. aline("hello")), "hello")

  local long = string.rep("x", 300)
  local snip = core.transcriptSnippet(aline(long), 140)
  check("snippet: truncated to maxLen", #snip <= 140)
end

-- ---- transcriptError: frozen-on-API-error detection from a jsonl tail -------
do
  local function errline(msg) -- a { type=system, subtype=api_error } transcript line
    return core.json.encode({ type = "system", subtype = "api_error", level = "error",
      error = { formatted = msg, message = "Connection error." } })
  end
  local function aline(text)
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end
  local userline = core.json.encode({ type = "user", message = { role = "user" } })

  -- latest significant line is an api_error -> stuck; return its formatted message
  local stuck = aline("working on it") .. "\n" .. errline("Unable to connect to API (ECONNRESET)")
  local e = core.transcriptError(stuck)
  check("error: detects api_error as the latest event", e ~= nil)
  eq("error: returns the formatted message", e and e.message, "Unable to connect to API (ECONNRESET)")

  -- an assistant line AFTER the error -> recovered, not stuck
  eq("error: assistant after error -> nil",
     core.transcriptError(errline("boom") .. "\n" .. aline("recovered")), nil)
  -- a user line after the error (e.g. the user typed continue) -> nil
  eq("error: user activity after error -> nil",
     core.transcriptError(errline("boom") .. "\n" .. userline), nil)
  -- no api_error at all -> nil
  eq("error: clean transcript -> nil", core.transcriptError(aline("all good")), nil)
  -- empty / garbled input is safe
  eq("error: empty input -> nil", core.transcriptError(""), nil)
  eq("error: garbled line skipped, still finds the error",
     (core.transcriptError("{ not json\n" .. errline("late boom")) or {}).message, "late boom")
  -- falls back to error.message when there is no formatted field
  local nofmt = core.json.encode({ type = "system", subtype = "api_error", error = { message = "Overloaded" } })
  eq("error: falls back to error.message", (core.transcriptError(nofmt) or {}).message, "Overloaded")
end

-- ---- Task queue: push / pop / depth / shouldFeed --------------------------
do
  eq("queue: push onto empty", core.queueDepth(core.queuePush(nil, "a")), 1)
  local q = core.queuePush(core.queuePush(nil, "a"), "b")
  eq("queue: depth after two pushes", core.queueDepth(q), 2)
  local first, rest = core.queuePop(q)
  eq("queue: pop returns front", first, "a")
  eq("queue: pop leaves the rest", core.queueDepth(rest), 1)
  eq("queue: pop next is b", (core.queuePop(rest)), "b")
  local none = core.queuePop({ tasks = {} })
  eq("queue: pop empty -> nil", none, nil)
  eq("queue: push ignores empty task", core.queueDepth(core.queuePush(nil, "")), 0)

  local q1 = { tasks = { "next" } }
  eq("feed: done transition with queue+auto -> true", core.shouldFeed("working", "done", q1, true), true)
  eq("feed: still done (no fresh transition) -> false", core.shouldFeed("done", "done", q1, true), false)
  -- nil prev = no prior observation (first refresh after a reload, queue persisted
  -- on disk): NOT a fresh transition, else every reload would re-feed a done tile.
  eq("feed: nil prev (first refresh after reload) -> false", core.shouldFeed(nil, "done", q1, true), false)
  eq("feed: empty queue -> false", core.shouldFeed("working", "done", { tasks = {} }, true), false)
  eq("feed: autofeed off -> false", core.shouldFeed("working", "done", q1, false), false)
  eq("feed: not done -> false", core.shouldFeed("working", "working", q1, true), false)
end

-- ---- Queue editing (roadmap #5): move / removeAt / splitLines / pushAll -----
do
  local q3 = { tasks = { "a", "b", "c" } }
  -- queueMove: happy paths + boundary no-ops
  local m1, ok1 = core.queueMove(q3, 2, -1, "b")
  eq("qmove: middle up", table.concat(m1.tasks, ","), "b,a,c")
  eq("qmove: middle up flag", ok1, true)
  local m2, ok2 = core.queueMove(q3, 2, 1, "b")
  eq("qmove: middle down", table.concat(m2.tasks, ","), "a,c,b")
  eq("qmove: middle down flag", ok2, true)
  local m3, ok3 = core.queueMove(q3, 1, -1, "a")
  eq("qmove: first up refused", ok3, false)
  eq("qmove: refused leaves order", table.concat(m3.tasks, ","), "a,b,c")
  local _, ok4 = core.queueMove(q3, 3, 1, "c")
  eq("qmove: last down refused", ok4, false)
  local _, ok5 = core.queueMove(q3, 9, -1, "x")
  eq("qmove: out of range refused", ok5, false)
  -- the expect guard: a stale panel (autofeed popped the head) must not move
  -- the WRONG task -- mismatch refuses and returns an unchanged copy.
  local m6, ok6 = core.queueMove(q3, 2, -1, "stale-text")
  eq("qmove: expect mismatch refused", ok6, false)
  eq("qmove: mismatch leaves order", table.concat(m6.tasks, ","), "a,b,c")
  local m7, ok7 = core.queueMove(nil, 1, 1, "a")
  eq("qmove: nil queue tolerated", ok7, false)
  eq("qmove: nil queue -> canonical shape", #m7.tasks, 0)
  eq("qmove: original untouched (pure)", table.concat(q3.tasks, ","), "a,b,c")
  -- queueRemoveAt
  local r1, rem1 = core.queueRemoveAt(q3, 2, "b")
  eq("qrm: removes the task", rem1, "b")
  eq("qrm: remaining order", table.concat(r1.tasks, ","), "a,c")
  local _, rem2 = core.queueRemoveAt(q3, 9, nil)
  eq("qrm: out of range -> nil", rem2, nil)
  local r3, rem3 = core.queueRemoveAt(q3, 1, "not-a")
  eq("qrm: expect mismatch -> nil", rem3, nil)
  eq("qrm: mismatch leaves queue", #r3.tasks, 3)
  local r4, rem4 = core.queueRemoveAt({ tasks = { "only" } }, 1, "only")
  eq("qrm: last task removed", rem4, "only")
  eq("qrm: empty canonical shape", #r4.tasks, 0)
  check("qrm: shape stays {tasks=...}", type(r4.tasks) == "table")
  -- queueSplitLines
  local s1 = core.queueSplitLines("a\nb\n\n   \nc")
  eq("qsplit: blanks dropped", #s1, 3)
  eq("qsplit: order kept", table.concat(s1, ","), "a,b,c")
  eq("qsplit: CRLF tolerated", table.concat(core.queueSplitLines("a\r\nb\r\n"), ","), "a,b")
  eq("qsplit: dash bullet stripped", core.queueSplitLines("- task one")[1], "task one")
  eq("qsplit: star bullet stripped", core.queueSplitLines("* task two")[1], "task two")
  eq("qsplit: numbered dot stripped", core.queueSplitLines("3. task three")[1], "task three")
  eq("qsplit: numbered paren stripped", core.queueSplitLines("12) task twelve")[1], "task twelve")
  eq("qsplit: bare marker line dropped", #core.queueSplitLines("- \n* "), 0)
  eq("qsplit: single line -> 1", #core.queueSplitLines("just one"), 1)
  eq("qsplit: empty -> {}", #core.queueSplitLines(""), 0)
  eq("qsplit: nil -> {}", #core.queueSplitLines(nil), 0)
  -- a literal "-x" (no space) is a task, not a bullet
  eq("qsplit: dash without space kept", core.queueSplitLines("-x flag")[1], "-x flag")
  -- queuePushAll
  local pa = core.queuePushAll({ tasks = { "old" } }, { "n1", "n2" })
  eq("qpushall: appends after existing", table.concat(pa.tasks, ","), "old,n1,n2")
  eq("qpushall: empty list unchanged", table.concat(core.queuePushAll(q3, {}).tasks, ","), "a,b,c")
  eq("qpushall: drops empty strings", #core.queuePushAll(nil, { "", "x" }).tasks, 1)
  check("qpushall: nil queue canonical shape", type(core.queuePushAll(nil, nil).tasks) == "table")
end

-- ---- Saved task templates (roadmap #5c) -------------------------------------
do
  local st, ok1 = core.templatePush(nil, "deploy", "run make deploy")
  eq("tpl: push onto nil state", ok1, true)
  eq("tpl: list after push", #core.templateList(st), 1)
  eq("tpl: get by name", core.templateGet(st, "deploy"), "run make deploy")
  -- replace-by-name updates in place (no duplicate)
  local st2 = core.templatePush(st, "deploy", "make deploy && make test")
  eq("tpl: replace keeps one entry", #core.templateList(st2), 1)
  eq("tpl: replace updates text", core.templateGet(st2, "deploy"), "make deploy && make test")
  -- prepend order: newest first
  local st3 = core.templatePush(st2, "lint", "run the linter")
  eq("tpl: newest first", core.templateList(st3)[1].name, "lint")
  -- blank name/text rejected
  local _, okBlank = core.templatePush(st3, "  ", "x")
  eq("tpl: blank name rejected", okBlank, false)
  local _, okNoText = core.templatePush(st3, "x", "")
  eq("tpl: blank text rejected", okNoText, false)
  -- trim both fields
  local st4 = core.templatePush(nil, "  padded  ", "  body  ")
  eq("tpl: name trimmed", core.templateList(st4)[1].name, "padded")
  eq("tpl: text trimmed", core.templateGet(st4, "padded"), "body")
  -- remove: hit + miss
  eq("tpl: remove", #core.templateList(core.templateRemove(st3, "lint")), 1)
  eq("tpl: remove miss is no-op", #core.templateList(core.templateRemove(st3, "nope")), 2)
  eq("tpl: get miss -> nil", core.templateGet(st3, "nope"), nil)
  -- cap drops the oldest
  local big = nil
  for i = 1, 5 do big = core.templatePush(big, "t" .. i, "x" .. i, 3) end
  eq("tpl: cap size", #core.templateList(big), 3)
  eq("tpl: cap keeps newest", core.templateList(big)[1].name, "t5")
  eq("tpl: cap dropped oldest", core.templateGet(big, "t1"), nil)
  -- garbage state tolerated; malformed entries dropped
  eq("tpl: garbage state -> empty", #core.templateList("nonsense"), 0)
  eq("tpl: malformed entries dropped",
     #core.templateList({ templates = { { name = "ok", text = "t" }, { name = "" }, "junk" } }), 1)
end

-- ---- Spawn presets (roadmap #4a) --------------------------------------------
do
  local st, ok1 = core.presetPush(nil, { name = "api work", folder = "/u/a/api",
                                         editor = "kitty", permMode = "plan", provider = "opus" })
  eq("preset: push onto nil state", ok1, true)
  eq("preset: list after push", #core.presetList(st), 1)
  eq("preset: fields kept", core.presetList(st)[1].editor, "kitty")
  -- trailing slash normalized (normDir)
  local stN = core.presetPush(nil, { name = "n", folder = "/u/a/api/" })
  eq("preset: folder normalized", core.presetList(stN)[1].folder, "/u/a/api")
  -- replace-by-name in place
  local st2 = core.presetPush(st, { name = "api work", folder = "/u/a/api2" })
  eq("preset: replace keeps one", #core.presetList(st2), 1)
  eq("preset: replace updates folder", core.presetList(st2)[1].folder, "/u/a/api2")
  -- validation: blank name / relative folder rejected
  local _, okBlank = core.presetPush(st, { name = " ", folder = "/x" })
  eq("preset: blank name rejected", okBlank, false)
  local _, okRel = core.presetPush(st, { name = "x", folder = "relative/path" })
  eq("preset: relative folder rejected", okRel, false)
  -- remove: hit + miss are safe copies
  eq("preset: remove", #core.presetList(core.presetRemove(st, "api work")), 0)
  eq("preset: remove miss no-op", #core.presetList(core.presetRemove(st, "nope")), 1)
  -- cap drops oldest
  local big = nil
  for i = 1, 4 do big = core.presetPush(big, { name = "p" .. i, folder = "/p/" .. i }, 2) end
  eq("preset: cap size", #core.presetList(big), 2)
  eq("preset: cap keeps newest", core.presetList(big)[1].name, "p4")
  -- lastByProject recall round-trip + normalization + survival through push/remove
  local mu = core.presetMarkUsed(st, "/u/a/proj/", { editor = "vscode", permMode = "plan", provider = "" })
  check("preset: markUsed recorded", core.presetForProject(mu, "/u/a/proj") ~= nil)
  eq("preset: recall editor", core.presetForProject(mu, "/u/a/proj").editor, "vscode")
  eq("preset: recall via trailing slash", core.presetForProject(mu, "/u/a/proj/").editor, "vscode")
  local mu2 = core.presetPush(mu, { name = "z", folder = "/z" })
  eq("preset: lastByProject survives push", core.presetForProject(mu2, "/u/a/proj").editor, "vscode")
  local mu3 = core.presetRemove(mu2, "z")
  eq("preset: lastByProject survives remove", core.presetForProject(mu3, "/u/a/proj").editor, "vscode")
  -- degenerate inputs
  eq("preset: markUsed relative folder no-op", core.presetForProject(
     core.presetMarkUsed(nil, "relative", { editor = "k" }), "relative"), nil)
  eq("preset: garbage state -> empty", #core.presetList(42), 0)
  check("preset: forProject on nil state", core.presetForProject(nil, "/x") == nil)
end

-- ---- Fuzzy folder search (roadmap #4b) --------------------------------------
do
  -- argv builders: exact shape (binary first; hs.task takes the rest)
  local fa = core.folderScanArgv("/opt/homebrew/bin/fd", { "/u/a/Programming", "/u/a/Work" }, 4)
  eq("fscan: fd argv", table.concat(fa, " "),
     "/opt/homebrew/bin/fd --type d --max-depth 4 --absolute-path . /u/a/Programming /u/a/Work")
  local ga = core.folderScanFallbackArgv({ "/u/a/Programming" }, 3)
  eq("fscan: find argv", table.concat(ga, " "),
     "/usr/bin/find /u/a/Programming -maxdepth 3 -type d -not -path */.* -not -path *node_modules*")
  -- parseDirList: trim, CRLF, dedupe, trailing-slash normalize, cap
  local pd = core.parseDirList("/a/b\r\n/a/b/\n  /a/c  \n\n/a/b\n")
  eq("fscan: parse count", #pd, 2)
  eq("fscan: parse first", pd[1], "/a/b")
  eq("fscan: parse second", pd[2], "/a/c")
  eq("fscan: parse cap", #core.parseDirList("/a\n/b\n/c\n", 2), 2)
  eq("fscan: parse nil -> empty", #core.parseDirList(nil), 0)
  -- fuzzyFilter ranking
  local idx = { "/u/p/shepherd", "/u/p/shepherd-docs", "/u/p/old/shepherd-archive",
                "/u/p/sheep", "/u/other/herd" }
  local r = core.fuzzyFilter("shep", idx)
  eq("fuzzy: basename prefix first", r[1], "/u/p/shepherd")
  eq("fuzzy: shorter beats longer on ties", r[2], "/u/p/shepherd-docs")
  check("fuzzy: non-matching dropped", #r < #idx)
  -- multi-token AND across the whole path
  local r2 = core.fuzzyFilter("old shep", idx)
  eq("fuzzy: multi-token AND", #r2, 1)
  eq("fuzzy: multi-token hit", r2[1], "/u/p/old/shepherd-archive")
  -- case-insensitive both sides
  eq("fuzzy: case-insensitive", core.fuzzyFilter("SHEP", { "/u/Shepherd" })[1], "/u/Shepherd")
  -- limit, empty query, pattern-injection safety
  eq("fuzzy: limit", #core.fuzzyFilter("p", { "/p1", "/p2", "/p3" }, 2), 2)
  eq("fuzzy: empty query -> {}", #core.fuzzyFilter("", idx), 0)
  eq("fuzzy: whitespace query -> {}", #core.fuzzyFilter("   ", idx), 0)
  eq("fuzzy: lua-pattern chars are literal", #core.fuzzyFilter("(x%", { "/a/(x%y" }), 1)
  eq("fuzzy: nil paths -> {}", #core.fuzzyFilter("x", nil), 0)
end

-- ---- queueKey: queues are PROJECT-keyed so respawn//clear can't strand them --
do
  -- a respawned session gets a NEW session_id (= a new tile key); the queue must
  -- key off the stable projectKey so the successor inherits the pending tasks.
  eq("queueKey: projectKey wins", core.queueKey({ key = "sess-1", projectKey = "-Users-a-proj", cwd = "/u/a/proj" }),
     "-Users-a-proj")
  eq("queueKey: same project, new session -> same key",
     core.queueKey({ key = "sess-2", projectKey = "-Users-a-proj" }), "-Users-a-proj")
  -- cwd fallback is sanitized like cc_sanitize (outside [A-Za-z0-9._-] -> "_")
  eq("queueKey: cwd fallback sanitized", core.queueKey({ key = "s", cwd = "/u/a proj" }), "_u_a_proj")
  eq("queueKey: no project identity -> tile key", core.queueKey({ key = "sess-3" }), "sess-3")
  eq("queueKey: nil item -> nil", core.queueKey(nil), nil)
end

-- ---- queueMerge: legacy session-keyed queue adopted into the project queue ---
do
  local m = core.queueMerge({ tasks = { "a" } }, { tasks = { "b", "c" } })
  eq("queueMerge: depth", core.queueDepth(m), 3)
  eq("queueMerge: keeps order, a first", m.tasks[1], "a")
  eq("queueMerge: appends legacy", m.tasks[3], "c")
  eq("queueMerge: nil sides safe", core.queueDepth(core.queueMerge(nil, nil)), 0)
end

-- ---- queueFeedCommit: only a DELIVERED feed pops the queue -------------------
do
  -- FX.feedTask returns false when the no-window-match guard skipped the paste;
  -- persisting the popped queue then would silently destroy the task and write a
  -- false task_feed audit event.
  local ok = core.queueFeedCommit(true)
  eq("feed-commit: delivered -> persist", ok.persist, true)
  eq("feed-commit: delivered -> task_feed event", ok.event, "task_feed")
  local skip = core.queueFeedCommit(false)
  eq("feed-commit: skipped -> queue kept", skip.persist, false)
  eq("feed-commit: skipped -> task_feed_skipped event", skip.event, "task_feed_skipped")
  eq("feed-commit: nil (legacy no-report) -> queue kept", core.queueFeedCommit(nil).persist, false)
end

-- ---- shouldPrune: orphan + ghost cleanup ----------------------------------
do
  local opts = { pruneNoSid = true, pruneSeconds = 86400 }
  -- orphan: stale tile with no session_id
  local orphan = { stale = true, session_id = "", updated = 100 }
  eq("prune: stale + no session_id -> true", core.shouldPrune(orphan, 1000, opts), true)
  -- real session, stale but has a session_id, within the ghost window -> keep
  local realStale = { stale = true, session_id = "abc", updated = 1000 }
  eq("prune: stale but has session_id (recent) -> false", core.shouldPrune(realStale, 2000, opts), false)
  -- ghost backstop: very old even with a session_id
  local ghost = { stale = true, session_id = "abc", updated = 0 }
  eq("prune: older than backstop -> true", core.shouldPrune(ghost, 90000, opts), true)
  -- fresh, valid -> keep
  local fresh = { stale = false, session_id = "abc", updated = 1000 }
  eq("prune: fresh valid -> false", core.shouldPrune(fresh, 1010, opts), false)
  -- pruneNoSid off -> no orphan prune
  eq("prune: orphan kept when pruneNoSid off",
     core.shouldPrune(orphan, 1000, { pruneNoSid = false, pruneSeconds = 0 }), false)
end

-- ---- Policy A: approvalStale ----------------------------------------------
do
  eq("escalate: fresh approval -> false", core.approvalStale({ status = "approval", since = 100 }, 150, 60), false)
  eq("escalate: old approval -> true", core.approvalStale({ status = "approval", since = 100 }, 200, 60), true)
  eq("escalate: non-approval -> false", core.approvalStale({ status = "working", since = 0 }, 999, 60), false)
end

-- ---- Orchestrator: spawn command building + shell escaping ----------------
do
  eq("spawn: inner basic", core.spawnInner("/p", "hi"), "cd '/p' && claude 'hi'")
  eq("spawn: inner without a prompt", core.spawnInner("/p", ""), "cd '/p' && claude")
  -- a path with a space and a prompt with a single quote must stay safe
  eq("spawn: inner escapes single quotes",
     core.spawnInner("/my proj", "it's broken"),
     "cd '/my proj' && claude 'it'\\''s broken'")

  local as = core.spawnAppleScript("/p", "hi", { terminal = "Terminal" })
  eq("spawn: applescript exact",
     as, 'tell application "Terminal" to do script "cd \'/p\' && claude \'hi\'"')
  -- AppleScript double-quotes in the prompt must be backslash-escaped
  local as2 = core.spawnAppleScript("/p", 'say "hi"')
  check("spawn: escapes double quotes for AppleScript", as2:find('\\"hi\\"', 1, true) ~= nil)
  -- a single quote in the prompt survives both layers
  local as3 = core.spawnAppleScript("/p", "it's")
  check("spawn: handles single quotes", as3:find("'it'\\\\''s'", 1, true) ~= nil)
end

-- ---- caffeinate: pmset command builder + SleepDisabled parser --------------
do
  eq("pmset: on -> disablesleep 1", core.pmsetDisableSleepCmd(true), "/usr/bin/pmset -a disablesleep 1")
  eq("pmset: off -> disablesleep 0", core.pmsetDisableSleepCmd(false), "/usr/bin/pmset -a disablesleep 0")

  eq("sleepflag: parses 1 -> true", core.parseSleepDisabled(" SleepDisabled         1\n"), true)
  eq("sleepflag: parses 0 -> false", core.parseSleepDisabled("Some line\n SleepDisabled  0\nmore"), false)
  eq("sleepflag: absent field -> nil", core.parseSleepDisabled("System-wide power settings:\n"), nil)
  eq("sleepflag: non-string -> nil", core.parseSleepDisabled(nil), nil)
end

-- ---- parseToolList: normalize the editable gated-tools list ----------------
do
  eq("toollist: spaces pass through", core.parseToolList("Bash Write Edit"), "Bash Write Edit")
  eq("toollist: commas -> spaces", core.parseToolList("Bash, Write ,Edit"), "Bash Write Edit")
  eq("toollist: trims + drops blanks", core.parseToolList("  Bash   Write  "), "Bash Write")
  eq("toollist: de-dupes preserving order", core.parseToolList("Bash Write Bash Edit Write"), "Bash Write Edit")
  eq("toollist: empty -> empty", core.parseToolList(""), "")
  eq("toollist: nil -> empty", core.parseToolList(nil), "")
  eq("toollist: default constant", core.DEFAULT_GATE_TOOLS, "Bash Write Edit MultiEdit NotebookEdit")
end

-- ---- jsString: JS string literal with escaping (locks paste/relabel/close) --
do
  eq("jsString: plain wraps in quotes", core.jsString("hi"), '"hi"')
  eq("jsString: escapes a double quote", core.jsString('a"b'), '"a\\"b"')
  eq("jsString: escapes a newline", core.jsString("a\nb"), '"a\\nb"')
  eq("jsString: coerces non-string", core.jsString(42), '"42"')
end

-- ---- kitty remote control: detect state + idempotent enable ----------------
do
  -- bare conf: remote control off
  local d = core.kittyRemoteStatus("font_size 12\n")
  eq("kitty: bare conf -> not enabled", d.enabled, false)
  eq("kitty: bare conf -> not usable", d.usable, false)
  eq("kitty: explicit no -> not enabled", core.kittyRemoteStatus("allow_remote_control no\n").enabled, false)

  -- yes + listen_on -> usable from outside
  local u = core.kittyRemoteStatus("allow_remote_control yes\nlisten_on unix:/tmp/k\n")
  eq("kitty: yes+listen -> enabled", u.enabled, true)
  eq("kitty: yes+listen -> usable", u.usable, true)
  eq("kitty: captures listen socket", u.listen, "unix:/tmp/k")
  eq("kitty: yes but no listen -> not usable", core.kittyRemoteStatus("allow_remote_control yes\n").usable, false)

  eq("kitty: commented line ignored", core.kittyRemoteStatus("# allow_remote_control yes\n").enabled, false)
  eq("kitty: last directive wins", core.kittyRemoteStatus("allow_remote_control yes\nallow_remote_control no\n").enabled, false)

  -- enable from scratch: appends both, reports changed, keeps existing lines
  local t1, c1 = core.kittyConfWithRemote("font_size 12", "unix:/tmp/s")
  eq("kitty-enable: reports changed", c1, true)
  check("kitty-enable: keeps existing line", t1:find("font_size 12", 1, true) ~= nil)
  check("kitty-enable: adds allow yes", t1:find("allow_remote_control yes", 1, true) ~= nil)
  check("kitty-enable: adds listen socket", t1:find("listen_on unix:/tmp/s", 1, true) ~= nil)

  -- rewrites an explicit `no` to `yes`
  local t2, c2 = core.kittyConfWithRemote("allow_remote_control no\nlisten_on unix:/tmp/s")
  eq("kitty-enable: rewrites no -> changed", c2, true)
  check("kitty-enable: no became yes", t2:find("allow_remote_control yes", 1, true) ~= nil)
  check("kitty-enable: no leftover 'no'", t2:find("allow_remote_control no", 1, true) == nil)

  -- idempotent: already usable -> no change
  local _, c3 = core.kittyConfWithRemote("allow_remote_control yes\nlisten_on unix:/tmp/s")
  eq("kitty-enable: already enabled -> no change", c3, false)

  -- launch flags for self-spawned kitty
  local f = core.kittyLaunchRemoteFlags("unix:/tmp/z")
  eq("kitty-flags: -o first", f[1], "-o")
  eq("kitty-flags: allow_remote_control=yes", f[2], "allow_remote_control=yes")
  eq("kitty-flags: --listen-on", f[3], "--listen-on")
  eq("kitty-flags: socket passed through", f[4], "unix:/tmp/z")
  eq("kitty-flags: default socket when nil", core.kittyLaunchRemoteFlags(nil)[4], core.KITTY_SOCKET)
end

-- ---- spawnSpec: editor-aware spawn intent ----------------------------------
do
  local k = core.spawnSpec("kitty", "/Users/a/proj", "fix the bug", {})
  eq("spawnspec(kitty): kind", k.kind, "kitty")
  eq("spawnspec(kitty): kitty bin first", k.argv[1], "kitty")
  local joined = table.concat(k.argv, " ")
  check("spawnspec(kitty): has allow_remote_control", joined:find("allow_remote_control=yes", 1, true) ~= nil)
  check("spawnspec(kitty): has --listen-on", joined:find("--listen-on", 1, true) ~= nil)
  check("spawnspec(kitty): has --directory <project>", joined:find("--directory /Users/a/proj", 1, true) ~= nil)
  check("spawnspec(kitty): runs claude", joined:find(" claude", 1, true) ~= nil)
  eq("spawnspec(kitty): task is final argv element", k.argv[#k.argv], "fix the bug")

  eq("spawnspec(kitty): no task -> ends with claude", core.spawnSpec("kitty", "/p", nil, {}).argv[#core.spawnSpec("kitty", "/p", nil, {}).argv], "claude")

  local k3 = core.spawnSpec("kitty", "/p", nil, { kittyRemote = false })
  check("spawnspec(kitty): remote=false omits flags", table.concat(k3.argv, " "):find("allow_remote_control", 1, true) == nil)

  local k4 = core.spawnSpec("kitty", "/p", nil, { kittyBin = "/opt/homebrew/bin/kitty", kittySocket = "unix:/tmp/z" })
  eq("spawnspec(kitty): custom bin", k4.argv[1], "/opt/homebrew/bin/kitty")
  check("spawnspec(kitty): custom socket", table.concat(k4.argv, " "):find("unix:/tmp/z", 1, true) ~= nil)

  local k5 = core.spawnSpec("kitty", "/p", nil, { permissionMode = "plan" })
  check("spawnspec(kitty): permission-mode flag", table.concat(k5.argv, " "):find("--permission-mode plan", 1, true) ~= nil)

  local v = core.spawnSpec("vscode", "/Users/a/proj", "do it", {})
  eq("spawnspec(vscode): kind", v.kind, "vscode")
  eq("spawnspec(vscode): app", v.app, "Visual Studio Code")
  eq("spawnspec(vscode): project", v.project, "/Users/a/proj")
  eq("spawnspec(vscode): open-terminal key", v.openTerminalKey.key, "`")
  check("spawnspec(vscode): post types claude + quoted task", v.postType:find("claude 'do it'", 1, true) ~= nil)
  eq("spawnspec(cursor): app", core.spawnSpec("cursor", "/p", nil, {}).app, "Cursor")

  local t = core.spawnSpec("terminal", "/p", "hi", { terminal = "Terminal" })
  eq("spawnspec(terminal): kind", t.kind, "terminal")
  eq("spawnspec(terminal): applescript matches builder", t.applescript, core.spawnAppleScript("/p", "hi", { terminal = "Terminal" }))
  eq("spawnspec(nil): falls back to terminal", core.spawnSpec(nil, "/p", nil, {}).kind, "terminal")

  eq("spawnspec(kitty): tricky task stays one element", core.spawnSpec("kitty", "/p", "it's a test", {}).argv[#core.spawnSpec("kitty", "/p", "it's a test", {}).argv], "it's a test")

  -- claudeBin: spawns embed the locally-resolved absolute path so contexts whose
  -- PATH/aliases don't carry `claude` (the VS Code integrated terminal is the
  -- proven case) still launch. nil keeps the legacy bare word everywhere above.
  local CB = "/Users/a/.claude/local/claude"
  eq("claudebin: spawnInner quotes the path",
     core.spawnInner("/p", "hi", { claudeBin = CB }),
     "cd '/p' && '" .. CB .. "' 'hi'")
  eq("claudebin: spawnInner ignores literal 'claude'",
     core.spawnInner("/p", nil, { claudeBin = "claude" }), "cd '/p' && claude")
  -- ssh: the REMOTE box resolves its own claude -- a local path would be wrong
  check("claudebin: ssh inner stays bare claude",
     core.spawnInner("/p", nil, { claudeBin = CB, ssh = { host = "h" } })
       :find(CB, 1, true) == nil)
  local vb = core.spawnSpec("vscode", "/p", "do it", { claudeBin = CB })
  check("claudebin: vscode post types the absolute path",
     vb.postType:find("'" .. CB .. "' 'do it'", 1, true) ~= nil)
  local vbSsh = core.spawnSpec("vscode", "/p", nil, { claudeBin = CB, ssh = { host = "h" } })
  check("claudebin: vscode ssh post stays bare", vbSsh.postType:find(CB, 1, true) == nil)
  local kb = core.spawnSpec("kitty", "/p", nil, { claudeBin = CB })
  eq("claudebin: kitty bare argv uses the path raw", kb.argv[#kb.argv], CB)
  local env1 = { { name = "ANTHROPIC_MODEL", value = "m" } }
  check("claudebin: kitty env inner carries the quoted path",
     core.spawnSpec("kitty", "/p", nil, { claudeBin = CB, env = env1 })
       .argv[#core.spawnSpec("kitty", "/p", nil, { claudeBin = CB, env = env1 }).argv]
       :find("'" .. CB .. "'", 1, true) ~= nil)
  check("claudebin: terminal applescript carries the quoted path",
     core.spawnSpec("terminal", "/p", nil, { claudeBin = CB, terminal = "Terminal" })
       .applescript:find(CB, 1, true) ~= nil)
  -- a path with a space survives the shell-string contexts
  local SP = "/Users/a b/claude"
  check("claudebin: spaced path is single-quoted",
     core.spawnInner("/p", nil, { claudeBin = SP }):find("'" .. SP .. "'", 1, true) ~= nil)
  -- newestClaudeExtension: numeric version compare (lexicographic would pick 2.1.9)
  eq("claudebin: newest extension picked numerically",
     core.newestClaudeExtension({ "anthropic.claude-code-2.1.9-darwin-arm64",
                                  "anthropic.claude-code-2.1.173-darwin-arm64",
                                  "ms-python.python-2024.1.0", "junk" }),
     "anthropic.claude-code-2.1.173-darwin-arm64")
  eq("claudebin: major beats minor", core.newestClaudeExtension(
     { "anthropic.claude-code-2.9.9", "anthropic.claude-code-3.0.0-darwin-arm64" }),
     "anthropic.claude-code-3.0.0-darwin-arm64")
  eq("claudebin: no extension dirs -> nil", core.newestClaudeExtension({ "foo", "bar" }), nil)
  eq("claudebin: nil listing -> nil", core.newestClaudeExtension(nil), nil)
end

-- ---- spawnFlags ------------------------------------------------------------
do
  eq("spawnflags: none -> empty", #core.spawnFlags(nil, nil), 0)
  local f = core.spawnFlags("plan", "high")
  eq("spawnflags: mode -> --permission-mode", f[1], "--permission-mode")
  eq("spawnflags: mode value", f[2], "plan")
  eq("spawnflags: effort not emitted (no launch flag)", #f, 2)
end

-- ---- provider profiles: lookup, env injection, /model command --------------
do
  local an = { id = "opus", kind = "anthropic", model = "claude-opus-4-8" }
  local gw = { id = "gemini", kind = "gateway", baseUrl = "http://localhost:4000",
               model = "gemini-2.5-pro", authTokenEnv = "MY_LITELLM_KEY",
               smallFastModel = "gemini-flash", headers = "X-Foo: bar" }
  local cfg = { providers = { an, gw } }

  -- providerById
  eq("provider: by id found", core.providerById(cfg, "gemini").model, "gemini-2.5-pro")
  eq("provider: anthropic by id", core.providerById(cfg, "opus").kind, "anthropic")
  eq("provider: missing id -> nil", core.providerById(cfg, "nope"), nil)
  eq("provider: empty id -> nil", core.providerById(cfg, ""), nil)
  eq("provider: no providers key -> nil", core.providerById({}, "opus"), nil)

  -- spawnProviderKey: "" is the EXPLICIT "(none — bare claude)" pick and must NOT
  -- fall back to the spawn.provider default; only nil (no pick at all) does.
  local dcfg = { spawn = { provider = "gemini" }, providers = { an, gw } }
  eq("spawnkey: nil -> spawn.provider default", core.spawnProviderKey(dcfg, nil), "gemini")
  eq("spawnkey: explicit '' -> no provider", core.spawnProviderKey(dcfg, ""), nil)
  eq("spawnkey: explicit pick wins", core.spawnProviderKey(dcfg, "opus"), "opus")
  eq("spawnkey: nil with no default -> nil", core.spawnProviderKey({}, nil), nil)
  -- end-to-end: the explicit none resolves to NO profile (no gateway env injected)
  eq("spawnkey: '' resolves to no profile", core.providerById(dcfg, core.spawnProviderKey(dcfg, "")), nil)
  eq("spawnkey: nil resolves to the default profile",
     core.providerById(dcfg, core.spawnProviderKey(dcfg, nil)).id, "gemini")

  -- providerEnv: anthropic sets just ANTHROPIC_MODEL (so the hook can see it)
  local ea = core.providerEnv(an)
  eq("providerenv: anthropic count", #ea, 1)
  eq("providerenv: anthropic model name", ea[1].name, "ANTHROPIC_MODEL")
  eq("providerenv: anthropic model value", ea[1].value, "claude-opus-4-8")
  eq("providerenv: nil -> empty", #core.providerEnv(nil), 0)
  eq("providerenv: model-less anthropic -> empty", #core.providerEnv({ kind = "anthropic" }), 0)

  -- providerEnv: gateway sets base/model/small-fast/headers + auth as a $VAR secret
  local e = core.providerEnv(gw)
  eq("providerenv: gateway count", #e, 5)
  eq("providerenv: base url first", e[1].name, "ANTHROPIC_BASE_URL")
  eq("providerenv: base url value", e[1].value, "http://localhost:4000")
  eq("providerenv: base url not secret", e[1].secret, false)
  eq("providerenv: model second", e[2].name, "ANTHROPIC_MODEL")
  eq("providerenv: model value", e[2].value, "gemini-2.5-pro")
  eq("providerenv: small-fast model", e[3].name, "ANTHROPIC_SMALL_FAST_MODEL")
  eq("providerenv: custom headers", e[4].name, "ANTHROPIC_CUSTOM_HEADERS")
  eq("providerenv: auth token name", e[5].name, "ANTHROPIC_AUTH_TOKEN")
  eq("providerenv: auth is a $VAR ref", e[5].value, "$MY_LITELLM_KEY")
  eq("providerenv: auth marked secret", e[5].secret, true)
  -- gateway without a model still injects base url; no auth when no env name
  local gw2 = { kind = "gateway", baseUrl = "http://x" }
  eq("providerenv: gateway no-model/no-auth count", #core.providerEnv(gw2), 1)

  -- envPrefix: literals single-quoted, secrets double-quoted (shell-expanded)
  eq("envprefix: empty list -> empty", core.envPrefix({}), "")
  eq("envprefix: nil -> empty", core.envPrefix(nil), "")
  local pre = core.envPrefix(e)
  eq("envprefix: exact",
     pre,
     "ANTHROPIC_BASE_URL='http://localhost:4000' ANTHROPIC_MODEL='gemini-2.5-pro' "
     .. "ANTHROPIC_SMALL_FAST_MODEL='gemini-flash' ANTHROPIC_CUSTOM_HEADERS='X-Foo: bar' "
     .. "ANTHROPIC_AUTH_TOKEN=\"$MY_LITELLM_KEY\" ")

  -- modelCommand: live /model switch
  eq("modelcmd: builds /model", core.modelCommand("claude-sonnet-4-6"), "/model claude-sonnet-4-6")
  eq("modelcmd: empty -> nil", core.modelCommand(""), nil)
  eq("modelcmd: nil -> nil", core.modelCommand(nil), nil)
end

-- ---- spawn with a provider: env injection through every editor path --------
do
  local gw = { id = "gemini", kind = "gateway", baseUrl = "http://localhost:4000",
               model = "gemini-2.5-pro", authTokenEnv = "MY_LITELLM_KEY" }
  local env = core.providerEnv(gw)

  -- spawnInner: env prefix (incl. ANTHROPIC_MODEL) + prompt, in order
  eq("spawn-inner(env): exact",
     core.spawnInner("/p", "hi", { env = env }),
     "cd '/p' && ANTHROPIC_BASE_URL='http://localhost:4000' ANTHROPIC_MODEL='gemini-2.5-pro' "
     .. "ANTHROPIC_AUTH_TOKEN=\"$MY_LITELLM_KEY\" claude 'hi'")
  -- no opts -> byte-identical to the original two-arg form
  eq("spawn-inner: no-opts unchanged", core.spawnInner("/p", "hi"), "cd '/p' && claude 'hi'")

  -- terminal path threads the env into the AppleScript
  local t = core.spawnSpec("terminal", "/p", "hi", { terminal = "Terminal", env = env })
  check("spawnspec(terminal,env): has base url", t.applescript:find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
  check("spawnspec(terminal,env): has model env", t.applescript:find("ANTHROPIC_MODEL=", 1, true) ~= nil)
  check("spawnspec(terminal,env): auth stays a $VAR", t.applescript:find("$MY_LITELLM_KEY", 1, true) ~= nil)

  -- vscode path prefixes the typed command with the env
  local v = core.spawnSpec("vscode", "/p", "hi", { env = env })
  check("spawnspec(vscode,env): post has base url", v.postType:find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
  check("spawnspec(vscode,env): post has model env", v.postType:find("ANTHROPIC_MODEL=", 1, true) ~= nil)

  -- kitty path wraps the inner in an INTERACTIVE login shell so $VAR expands:
  -- the README keeps authTokenEnv secrets in ~/.zshrc, which plain `zsh -lc`
  -- (login, NON-interactive) never sources -- the secret would expand to ""
  -- and every gateway call 401s (R3 #6). `-lic` sources ~/.zshrc.
  local k = core.spawnSpec("kitty", "/p", "hi", { env = env })
  eq("spawnspec(kitty,env): shell is zsh", k.argv[#k.argv - 2], "zsh")
  eq("spawnspec(kitty,env): runs via INTERACTIVE login shell (-lic sources ~/.zshrc)",
     k.argv[#k.argv - 1], "-lic")
  -- pin the exact generated inner so the spawned command can't drift silently
  eq("spawnspec(kitty,env): exact inner command", k.argv[#k.argv],
     "cd '/p' && ANTHROPIC_BASE_URL='http://localhost:4000' ANTHROPIC_MODEL='gemini-2.5-pro' "
     .. "ANTHROPIC_AUTH_TOKEN=\"$MY_LITELLM_KEY\" claude 'hi'")
  check("spawnspec(kitty,env): still has --directory", table.concat(k.argv, " "):find("--directory /p", 1, true) ~= nil)
  -- no-provider kitty path is unchanged (bare `claude`, task as final element)
  local kp = core.spawnSpec("kitty", "/p", "hi", {})
  eq("spawnspec(kitty): no-provider ends with task", kp.argv[#kp.argv], "hi")
  eq("spawnspec(kitty): no-provider has bare claude", kp.argv[#kp.argv - 1], "claude")
end

-- ---- SSH remote harness (Phase 2): run claude on another box ---------------
do
  -- sshWrap: single-quotes the whole inner so its $VAR expands on the REMOTE host
  eq("sshwrap: user@host + -t",
     core.sshWrap("claude", { host = "gpubox", user = "adam" }),
     "ssh -t adam@gpubox 'claude'")
  eq("sshwrap: host only (no user)",
     core.sshWrap("x", { host = "gpubox" }), "ssh -t gpubox 'x'")
  eq("sshwrap: tty=false drops -t",
     core.sshWrap("x", { host = "h", tty = false }), "ssh h 'x'")
  eq("sshwrap: no ssh -> inner unchanged", core.sshWrap("claude", nil), "claude")
  eq("sshwrap: empty host -> unchanged", core.sshWrap("claude", { host = "" }), "claude")

  local gw = { kind = "gateway", baseUrl = "http://localhost:4000",
               model = "ollama/llama3", authTokenEnv = "LOCAL_GW_KEY" }
  local env = core.providerEnv(gw)
  local ssh = { host = "gpubox", user = "adam" }

  -- loginShellWrap (R3 #6): provider env rides $VAR secrets that live in
  -- ~/.zshrc (README), which only an INTERACTIVE login zsh sources -- command
  -- shells (sshd's `shell -c`, kitty argv) skip it and expand the secret to "".
  eq("login-wrap: env -> interactive login zsh",
     core.loginShellWrap("claude", env), "zsh -lic 'claude'")
  eq("login-wrap: no env -> inner unchanged", core.loginShellWrap("claude", nil), "claude")
  eq("login-wrap: empty env -> inner unchanged", core.loginShellWrap("claude", {}), "claude")
  eq("login-wrap: custom shell", core.loginShellWrap("claude", env, "bash"), "bash -lic 'claude'")

  -- spawnInner wraps the env-injected command in ssh; the auth $VAR stays for the
  -- REMOTE shell (single-quoted, not expanded locally). sshd runs the remote
  -- command NON-login/NON-interactive, so the inner must ride an interactive
  -- login zsh there or the remote ~/.zshrc secret never resolves (R3 #6).
  local inner = core.spawnInner("/remote/proj", "go", { env = env, ssh = ssh })
  check("spawn-inner(ssh): starts with ssh -t adam@gpubox", inner:find("^ssh %-t adam@gpubox ") ~= nil)
  check("spawn-inner(ssh): remote command runs an interactive login zsh",
        inner:find("zsh -lic ", 1, true) ~= nil)
  check("spawn-inner(ssh): carries the remote cd", inner:find("cd ", 1, true) ~= nil)
  check("spawn-inner(ssh): auth $VAR preserved for remote", inner:find("$LOCAL_GW_KEY", 1, true) ~= nil)
  -- no env -> no shell wrap (the no-provider ssh spawn keeps its exact shape)
  eq("spawn-inner(ssh,no-env): unchanged shape",
     core.spawnInner("/p", "hi", { ssh = { host = "h" } }), "ssh -t h 'cd '\\''/p'\\'' && claude '\\''hi'\\'''")

  -- terminal path: AppleScript runs the ssh command
  local t = core.spawnSpec("terminal", "/remote/proj", "go", { terminal = "Terminal", env = env, ssh = ssh })
  check("spawnspec(terminal,ssh): applescript runs ssh", t.applescript:find("ssh -t adam@gpubox", 1, true) ~= nil)

  -- kitty path: runs ssh directly (no local login shell), inner as one argv element
  local k = core.spawnSpec("kitty", "/remote/proj", "go", { env = env, ssh = ssh })
  local ai
  for i, a in ipairs(k.argv) do if a == "ssh" then ai = i end end
  check("spawnspec(kitty,ssh): has ssh in argv", ai ~= nil)
  eq("spawnspec(kitty,ssh): -t after ssh", k.argv[ai + 1], "-t")
  eq("spawnspec(kitty,ssh): dest after -t", k.argv[ai + 2], "adam@gpubox")
  check("spawnspec(kitty,ssh): inner is one argv element with env",
        (k.argv[ai + 3] or ""):find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
  -- the remote command must run under an interactive login zsh: sshd's
  -- `shell -c` is non-login, so the remote ~/.zshrc secret would otherwise
  -- expand to "" (R3 #6 -- same wrap as sshWrap above)
  check("spawnspec(kitty,ssh,env): remote inner wrapped in zsh -lic",
        (k.argv[ai + 3] or ""):find("^zsh %-lic ") ~= nil)
  -- no provider env -> no shell wrap on the remote command
  local kne = core.spawnSpec("kitty", "/p", "go", { ssh = { host = "h" } })
  eq("spawnspec(kitty,ssh,no-env): bare inner unchanged",
     kne.argv[#kne.argv], "cd '/p' && claude 'go'")
end

-- ---- token usage: parse + aggregate transcript usage (zero-cost, local) -----
do
  -- isoToEpoch: UTC, tz-independent (compare deltas, not absolute local time)
  eq("iso: unix epoch start", core.isoToEpoch("1970-01-01T00:00:00.000Z"), 0)
  eq("iso: one day later", core.isoToEpoch("1970-01-02T00:00:00Z"), 86400)
  eq("iso: one hour", core.isoToEpoch("1970-01-01T01:00:00Z"), 3600)
  eq("iso: garbage -> nil", core.isoToEpoch("not-a-date"), nil)
  -- a known recent instant: 2026-01-01T00:00:00Z
  local jan1 = core.isoToEpoch("2026-01-01T00:00:00Z")
  eq("iso: a day after jan1 2026", core.isoToEpoch("2026-01-02T00:00:00Z") - jan1, 86400)

  -- parseUsageLine: real transcript line shape
  local line = '{"type":"assistant","timestamp":"2026-06-09T12:00:00.000Z","message":'
    .. '{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,'
    .. '"cache_read_input_tokens":1000,"cache_creation_input_tokens":300}}}'
  local e = core.parseUsageLine(line)
  eq("parse: model", e.model, "claude-opus-4-8")
  eq("parse: input", e.input, 10)
  eq("parse: output", e.output, 20)
  eq("parse: cacheRead", e.cacheRead, 1000)
  eq("parse: cacheCreate", e.cacheCreate, 300)
  eq("parse: ts is epoch", e.ts, core.isoToEpoch("2026-06-09T12:00:00.000Z"))
  -- non-usage / non-assistant lines are skipped
  eq("parse: user line -> nil", core.parseUsageLine('{"type":"user","message":{}}'), nil)
  eq("parse: assistant w/o usage -> nil", core.parseUsageLine('{"type":"assistant","message":{"model":"x"}}'), nil)
  eq("parse: blank -> nil", core.parseUsageLine(""), nil)
  eq("parse: partial tail (no leading brace) -> nil", core.parseUsageLine('tokens":5}'), nil)

  -- contextTokens / contextFraction
  eq("ctx: tokens = input+cacheRead+cacheCreate", core.contextTokens(e), 10 + 1000 + 300)
  eq("ctx: fraction vs default 200k", core.contextFraction(100000), 0.5)
  eq("ctx: fraction clamps >1", core.contextFraction(500000), 1)
  eq("ctx: fraction custom limit (gemini 1M)", core.contextFraction(500000, 1000000), 0.5)
  eq("ctx: zero limit -> 0", core.contextFraction(100, 0), 0)

  -- sumUsage: cumulative + per-model
  local events = {
    { model = "claude-opus-4-8", input = 10, output = 20, cacheRead = 100, cacheCreate = 5, ts = 1000 },
    { model = "claude-opus-4-8", input = 1,  output = 2,  cacheRead = 10,  cacheCreate = 0, ts = 2000 },
    { model = "gemini-2.5-pro",  input = 7,  output = 3,  cacheRead = 0,   cacheCreate = 0, ts = 3000 },
  }
  local s = core.sumUsage(events)
  eq("sum: input", s.input, 18)
  eq("sum: output", s.output, 25)
  eq("sum: total (gross, incl cache reads)", s.total, 18 + 25 + 110 + 5)
  eq("sum: real (excl cache reads)", s.real, 18 + 25 + 5)
  eq("sum: opus per-model output", s.byModel["claude-opus-4-8"].output, 22)
  eq("sum: gemini per-model total", s.byModel["gemini-2.5-pro"].total, 10)
  eq("sum: opus per-model real (excl cacheRead 110)", s.byModel["claude-opus-4-8"].real, 11 + 22 + 5)
  eq("sum: empty -> zero total", core.sumUsage({}).total, 0)
  eq("sum: empty -> zero real", core.sumUsage({}).real, 0)

  -- usageInWindow: rolling sum of REAL tokens (excl cacheRead). now=3500, 1500s -> ts>=2000
  eq("window: last 1500s (real)", core.usageInWindow(events, 3500, 1500), (1+2+0) + (7+3+0))
  eq("window: huge window catches all (real)", core.usageInWindow(events, 3500, 999999), s.real)
  eq("window: zero window -> 0", core.usageInWindow(events, 3500, 0), 0)

  -- formatTokens
  eq("fmt: small int", core.formatTokens(42), "42")
  eq("fmt: thousands", core.formatTokens(254337), "254.3k")
  eq("fmt: millions", core.formatTokens(1300000), "1.30M")

  -- usageBarLevel thresholds
  eq("level: ok", core.usageBarLevel(0.5), "ok")
  eq("level: warn at .75", core.usageBarLevel(0.8), "warn")
  eq("level: full at .9", core.usageBarLevel(0.95), "full")

  -- isAnthropicSession: scopes the plan-window bar
  eq("anthropic: claude model, no base url", core.isAnthropicSession("claude-opus-4-8", nil), true)
  eq("anthropic: empty model defaults true", core.isAnthropicSession("", ""), true)
  eq("anthropic: gateway base url -> false", core.isAnthropicSession("claude-opus-4-8", "http://localhost:4000"), false)
  eq("anthropic: gemini model -> false", core.isAnthropicSession("gemini-2.5-pro", nil), false)

  -- lastUsage: scan a tail bottom-up for the most recent usage line
  local tail = table.concat({
    '{"type":"user","message":{"role":"user"}}',
    line,  -- the opus usage line built above
    '{"type":"assistant","timestamp":"2026-06-09T13:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5,"output_tokens":6,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}',
    'partial-half-written-line-no-brace',
  }, "\n")
  local lu = core.lastUsage(tail)
  eq("lastusage: picks the most recent complete usage", lu.model, "claude-sonnet-4-6")
  eq("lastusage: its context tokens", core.contextTokens(lu), 5 + 2000 + 0)
  eq("lastusage: empty -> nil", core.lastUsage(""), nil)

  -- contextLimitFor: provider override > built-in model map > default
  local cfg = { providers = {
    { id = "gemini", model = "gemini-2.5-pro", contextLimit = 1500000 },
    { id = "opus", model = "claude-opus-4-8" } } }
  eq("ctxlimit: gemini override wins", core.contextLimitFor(cfg, "gemini-2.5-pro"), 1500000)
  eq("ctxlimit: opus-4 model map -> 1M", core.contextLimitFor(cfg, "claude-opus-4-8"), 1000000)
  eq("ctxlimit: sonnet-4 model map -> 1M", core.contextLimitFor({}, "claude-sonnet-4-6"), 1000000)
  eq("ctxlimit: haiku -> 200k default", core.contextLimitFor({}, "claude-haiku-4-5"), 200000)
  eq("ctxlimit: unknown model -> default", core.contextLimitFor({}, "mystery"), 200000)
  eq("ctxlimit: no config -> default", core.contextLimitFor({}, "x"), 200000)

  -- nextContextTier: round observed up to a standard window
  eq("tier: 150k -> 200k", core.nextContextTier(150000), 200000)
  eq("tier: 437k -> 1M", core.nextContextTier(437000), 1000000)
  eq("tier: 1.4M -> 2M", core.nextContextTier(1400000), 2000000)

  -- contextFractionFor: the real bug case — 437k on opus-4-8 is ~44% of 1M, NOT 100%
  local frac, lim = core.contextFractionFor({}, "claude-opus-4-8", 437000)
  eq("ctxfrac: opus 437k limit is 1M", lim, 1000000)
  check("ctxfrac: opus 437k ~= 0.44 (not full)", frac > 0.43 and frac < 0.45)
  -- self-heal: unknown model at 437k uses the 1M tier, not a false 100%
  local f2, l2 = core.contextFractionFor({}, "mystery-model", 437000)
  eq("ctxfrac: unknown 437k bumped to 1M tier", l2, 1000000)
  check("ctxfrac: unknown 437k not full", f2 < 0.5)
  -- a genuinely full 200k model still reads ~100%
  local f3 = core.contextFractionFor({}, "claude-haiku-4-5", 198000)
  check("ctxfrac: haiku 198k/200k ~ full", f3 >= 0.98)
end

-- ---- path helpers (folder browser) -----------------------------------------
do
  eq("normDir: strips trailing slash", core.normDir("/a/b/"), "/a/b")
  eq("normDir: keeps root", core.normDir("/"), "/")
  eq("normDir: empty stays empty", core.normDir(""), "")

  eq("pathJoin: simple", core.pathJoin("/a/b", "c"), "/a/b/c")
  eq("pathJoin: trailing slash base", core.pathJoin("/a/", "b"), "/a/b")
  eq("pathJoin: root base", core.pathJoin("/", "x"), "/x")

  eq("parentPath: nested", core.parentPath("/a/b/c"), "/a/b")
  eq("parentPath: single seg", core.parentPath("/a"), "/")
  eq("parentPath: root", core.parentPath("/"), "/")
  eq("parentPath: trailing slash", core.parentPath("/a/b/"), "/a")

  local b = core.breadcrumbs("/a/b")
  eq("breadcrumbs: count", #b, 3)
  eq("breadcrumbs: root first", b[1].path, "/")
  eq("breadcrumbs: mid path", b[2].path, "/a")
  eq("breadcrumbs: leaf name", b[3].name, "b")
  eq("breadcrumbs: leaf path", b[3].path, "/a/b")
  eq("breadcrumbs: root only", #core.breadcrumbs("/"), 1)

  eq("isVisibleDir: normal", core.isVisibleDir("src"), true)
  eq("isVisibleDir: dot", core.isVisibleDir("."), false)
  eq("isVisibleDir: dotdot", core.isVisibleDir(".."), false)
  eq("isVisibleDir: dotfile", core.isVisibleDir(".git"), false)

  local s = core.sortDirs({ "Zeb", "apple", "Banana" })
  eq("sortDirs: case-insensitive 1st", s[1], "apple")
  eq("sortDirs: case-insensitive 2nd", s[2], "Banana")
  eq("sortDirs: case-insensitive 3rd", s[3], "Zeb")
  local src = { "b", "a" }
  core.sortDirs(src)
  eq("sortDirs: does not mutate input", src[1], "b")
end

-- ---- recent dirs -----------------------------------------------------------
do
  local s0 = core.recentPush(nil, "/a")
  eq("recent: push onto empty -> 1", #s0.dirs, 1)
  eq("recent: pushed dir", s0.dirs[1], "/a")

  local s1 = core.recentPush(core.recentPush(s0, "/b"), "/a")
  eq("recent: re-push moves to front, no dup (len 2)", #s1.dirs, 2)
  eq("recent: front is re-pushed", s1.dirs[1], "/a")
  eq("recent: other kept", s1.dirs[2], "/b")

  eq("recent: trailing slash dedupes", #core.recentPush(core.recentPush(nil, "/a"), "/a/").dirs, 1)

  local capped = { dirs = {} }
  for i = 1, 5 do capped = core.recentPush(capped, "/d" .. i, 3) end
  eq("recent: respects cap", #capped.dirs, 3)
  eq("recent: newest first under cap", capped.dirs[1], "/d5")

  eq("recent: empty dir ignored", #core.recentPush(s0, "").dirs, 1)

  local seeded = core.recentSeed({ dirs = { "/a" } }, { "/a", "/b", "/c" })
  eq("recent-seed: keeps existing first", seeded.dirs[1], "/a")
  eq("recent-seed: appends new", seeded.dirs[2], "/b")
  eq("recent-seed: total", #seeded.dirs, 3)
  eq("recentList: nil -> empty", #core.recentList(nil), 0)
end

-- ---- new project -----------------------------------------------------------
do
  eq("safeName: simple", core.safeFolderName("my-proj"), "my-proj")
  eq("safeName: underscores/dots/spaces ok", core.safeFolderName("App_v2.1 beta"), "App_v2.1 beta")
  eq("safeName: trims", core.safeFolderName("  trimmed  "), "trimmed")
  eq("safeName: empty -> nil", core.safeFolderName(""), nil)
  eq("safeName: slash -> nil", core.safeFolderName("a/b"), nil)
  eq("safeName: dotdot -> nil", core.safeFolderName(".."), nil)
  eq("safeName: dot -> nil", core.safeFolderName("."), nil)
  eq("safeName: leading dash -> nil", core.safeFolderName("-x"), nil)

  eq("newProjectPath: builds under parent", core.newProjectPath("/Users/a/Programming", "new"), "/Users/a/Programming/new")
  eq("newProjectPath: bad name -> nil", core.newProjectPath("/p", "bad/name"), nil)
  -- a non-absolute parent must be rejected: the relative result would mkdir
  -- against Hammerspoon's cwd while the spawned shell cd's relative to $HOME
  eq("newProjectPath: empty parent -> nil", core.newProjectPath("", "x"), nil)
  eq("newProjectPath: relative parent -> nil", core.newProjectPath("rel/path", "x"), nil)
  eq("newProjectPath: root parent ok", core.newProjectPath("/", "x"), "/x")
end

-- ---- Part A: kittyCmd argv builder + kittyKeyToken -------------------------
do
  local it = { kitty_window_id = "7", kitty_listen_on = "unix:/tmp/k", cwd = "/p" }
  local f = core.kittyCmd("focus", it, {})
  eq("kittyCmd: argv[1] is @", f[1], "@")
  eq("kittyCmd: --to flag", f[2], "--to")
  eq("kittyCmd: socket", f[3], "unix:/tmp/k")
  eq("kittyCmd: focus subcommand", f[4], "focus-window")
  eq("kittyCmd: --match", f[5], "--match")
  eq("kittyCmd: id selector", f[6], "id:7")

  eq("kittyCmd: close subcommand", core.kittyCmd("close", it, {})[4], "close-window")

  local k = core.kittyCmd("key", it, { token = "enter" })
  eq("kittyCmd: key subcommand", k[4], "send-key")
  eq("kittyCmd: key token last", k[#k], "enter")
  eq("kittyCmd: key without token -> nil", core.kittyCmd("key", it, {}), nil)

  -- payload.tokens batches several keys into ONE send-key argv. One process per
  -- key raced to the control socket, so down/.../return could arrive out of order
  -- and an early Return confirmed the WRONG AskUserQuestion option.
  local kb = core.kittyCmd("key", it, { tokens = { "down", "down", "enter" } })
  eq("kittyCmd: batched key subcommand", kb[4], "send-key")
  eq("kittyCmd: batched token 1 in order", kb[7], "down")
  eq("kittyCmd: batched token 2 in order", kb[8], "down")
  eq("kittyCmd: batched return last", kb[#kb], "enter")
  eq("kittyCmd: empty tokens -> nil", core.kittyCmd("key", it, { tokens = {} }), nil)
  eq("kittyCmd: blank tokens dropped", #core.kittyCmd("key", it, { tokens = { "", "enter" } }), 7)

  local t = core.kittyCmd("text", it, { text = "hello" })
  eq("kittyCmd: text subcommand", t[4], "send-text")
  eq("kittyCmd: text -- guard", t[#t - 1], "--")
  eq("kittyCmd: text payload last", t[#t], "hello")
  eq("kittyCmd: empty text -> nil", core.kittyCmd("text", it, { text = "" }), nil)

  local ns = core.kittyCmd("focus", { kitty_window_id = "9", cwd = "/p" }, {})
  eq("kittyCmd: no socket -> no --to", ns[2], "focus-window")
  eq("kittyCmd: no socket selector", ns[4], "id:9")
  eq("kittyCmd: cwd fallback selector", core.kittyCmd("focus", { cwd = "/proj" }, {})[#core.kittyCmd("focus", { cwd = "/proj" }, {})], "cwd:/proj")
  eq("kittyCmd: untargetable -> nil", core.kittyCmd("focus", {}, {}), nil)
  eq("kittyCmd: unknown action -> nil", core.kittyCmd("bogus", it, {}), nil)

  eq("kittyKeyToken: return -> enter", core.kittyKeyToken({ mods = {}, key = "return" }), "enter")
  eq("kittyKeyToken: escape -> esc", core.kittyKeyToken({ mods = {}, key = "escape" }), "esc")
  eq("kittyKeyToken: shift+tab", core.kittyKeyToken({ mods = { "shift" }, key = "tab" }), "shift+tab")
  eq("kittyKeyToken: unknown base passes through", core.kittyKeyToken({ mods = {}, key = "x" }), "x")
end

-- ---- review #4: focusCandidates + titleFolderMatch -------------------------
do
  eq("titleMatch: folder segment after em-dash", core.titleFolderMatch("main.lua — autobottom", "autobottom"), true)
  eq("titleMatch: ignores file part", core.titleFolderMatch("autobottom.md — other", "autobottom"), false)
  eq("titleMatch: no em-dash uses whole title", core.titleFolderMatch("autobottom", "autobottom"), true)
  eq("titleMatch: empty needle -> false", core.titleFolderMatch("x — y", ""), false)

  local cands = core.focusCandidates("frontend", "/Users/adam/Programming/autobottom/frontend", "adam")
  eq("focusCands: name first", cands[1], "frontend")
  eq("focusCands: parent next (basename excluded)", cands[2], "autobottom")
  local joined = "," .. table.concat(cands, ",") .. ","
  check("focusCands: skips generics + user", not joined:find(",programming,") and not joined:find(",adam,") and not joined:find(",users,"))
end

-- ---- Part C: modeCycleSteps ------------------------------------------------
do
  eq("mode: default->plan = 2", core.modeCycleSteps("default", "plan", {}), 2)
  eq("mode: plan->default wraps = 1", core.modeCycleSteps("plan", "default", {}), 1)
  eq("mode: same = 0", core.modeCycleSteps("plan", "plan", {}), 0)
  eq("mode: acceptEdits->plan = 1", core.modeCycleSteps("acceptEdits", "plan", {}), 1)
  eq("mode: bypass disabled -> 0 (not in cycle)", core.modeCycleSteps("default", "bypassPermissions", {}), 0)
  eq("mode: default->bypass enabled = 3", core.modeCycleSteps("default", "bypassPermissions", { bypassPermissions = true }), 3)
  eq("mode: bypass->default wraps = 1", core.modeCycleSteps("bypassPermissions", "default", { bypassPermissions = true }), 1)
  eq("mode: unknown cur -> 0", core.modeCycleSteps("weird", "plan", {}), 0)
end

-- ---- Part E: mergeHooks (idempotent installer merge) -----------------------
do
  local template = { hooks = {
    Stop = { { hooks = { { type = "command", command = "bash cc-status.sh stop" } } } },
    PreToolUse = { { hooks = { { type = "command", command = "bash cc-approve.sh" } } } },
  } }
  local m1, c1 = core.mergeHooks({}, template)
  eq("mergeHooks: empty -> changed", c1, true)
  check("mergeHooks: Stop adopted", m1.hooks.Stop ~= nil)
  eq("mergeHooks: preserves other keys", core.mergeHooks({ model = "opus" }, template).model, "opus")
  local _, c3 = core.mergeHooks(m1, template)
  eq("mergeHooks: re-run is a no-op", c3, false)
  local userHooks = { hooks = { Stop = { { hooks = { { type = "command", command = "bash my-own.sh" } } } } } }
  local m4, c4 = core.mergeHooks(userHooks, template)
  eq("mergeHooks: user-hook event -> changed", c4, true)
  eq("mergeHooks: keeps user's group first", m4.hooks.Stop[1].hooks[1].command, "bash my-own.sh")
  eq("mergeHooks: appends ours after (2 groups)", #m4.hooks.Stop, 2)

  -- F-005 (bug sweep): a user's OWN cc-prefixed hook (cc-notify.sh) on a wired event
  -- must NOT count as "already ours" -- Shepherd's group must still be appended.
  local ccUser = { hooks = { Stop = { { hooks = { { type = "command", command = "bash $HOME/.claude/cc-notify.sh" } } } } } }
  local m5, c5 = core.mergeHooks(ccUser, template)
  eq("mergeHooks: user's cc-* hook still triggers a merge", c5, true)
  eq("mergeHooks: appends ours after the user's cc-* hook", #m5.hooks.Stop, 2)
  local wiredOurs = false
  for _, g in ipairs(m5.hooks.Stop) do
    for _, h in ipairs(g.hooks or {}) do
      if type(h.command) == "string" and h.command:find("cc-status.sh", 1, true) then wiredOurs = true end
    end
  end
  check("mergeHooks: our cc-status.sh actually gets wired", wiredOurs)
  -- a genuine prior install (our cc-status.sh present) is still a no-op re-run
  local _, c6 = core.mergeHooks(m1, template)
  eq("mergeHooks: genuine prior install stays a no-op", c6, false)

  -- OUR_HOOK_SCRIPTS is single-sourced for the Lua side and mirrored by install.sh's
  -- jq alternation; pin its contents so a Lua-side drift is caught (the jq mirror is
  -- exercised end-to-end by install.test.sh's cc-notify.sh case).
  -- Pin EXACT set-equality via a sorted compare: this rejects a drop, an extra, AND a
  -- duplicate (a membership-only loop would pass {cc-status.sh x3} while losing two).
  local got = {}
  for _, n in ipairs(core.OUR_HOOK_SCRIPTS) do got[#got + 1] = n end
  table.sort(got)
  local wantScripts = { "cc-approve.sh", "cc-popup.sh", "cc-status.sh" }  -- sorted
  local scriptsOk = (#got == #wantScripts)
  for i = 1, #wantScripts do if got[i] ~= wantScripts[i] then scriptsOk = false end end
  check("mergeHooks: OUR_HOOK_SCRIPTS == {cc-approve, cc-popup, cc-status}.sh exactly", scriptsOk)
end

-- ---- Audit ledger: parse / filter / retention / narrative -----------------
do
  local text = table.concat({
    core.json.encode({ v = 1, ts = 100, id = "a", type = "prompt",
                       session_id = "s1", name = "proj", prompt = "fix bug" }),
    "",                                  -- blank line tolerated
    "{ partial tail line",               -- malformed tolerated
    core.json.encode({ v = 1, ts = 200, id = "b", type = "decision",
                       session_id = "s1", name = "proj", tool = "Bash", summary = "rm -rf x",
                       outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" }),
    core.json.encode({ v = 1, ts = 150, id = "c", type = "prompt",
                       session_id = "s2", name = "other", prompt = "hi" }),
    core.json.encode({ ts = 50 }),       -- no type -> dropped
  }, "\n")
  local evs = core.parseLedger(text)
  eq("parseLedger: keeps only well-formed events", #evs, 3)

  local f1 = core.filterLedger(evs, { session = "s1" })
  eq("filterLedger: session match count", #f1, 2)
  eq("filterLedger: newest first", f1[1].ts, 200)
  eq("filterLedger: by type (list)", #core.filterLedger(evs, { types = { "decision" } }), 1)
  eq("filterLedger: by type (set)", #core.filterLedger(evs, { types = { decision = true } }), 1)
  eq("filterLedger: time window", #core.filterLedger(evs, { sinceTs = 120, untilTs = 180 }), 1)
  eq("filterLedger: empty types = all", #core.filterLedger(evs, { types = {} }), 3)

  eq("ledgerFileEpoch: parses daily name", core.ledgerFileEpoch("2026-01-01.jsonl"),
     core.isoToEpoch("2026-01-01T00:00:00Z"))
  eq("ledgerFileEpoch: rejects non-ledger", core.ledgerFileEpoch("notes.txt"), nil)

  local files = { "2026-01-01.jsonl", "2026-06-01.jsonl", "2026-06-09.jsonl", "exports" }
  local now = core.isoToEpoch("2026-06-09T00:00:00Z")
  local exp = core.expiredLedgerFiles(files, now, 30)
  eq("expiredLedgerFiles: 30d cutoff count", #exp, 1)
  eq("expiredLedgerFiles: drops the oldest", exp[1], "2026-01-01.jsonl")
  eq("expiredLedgerFiles: retention 0 = keep all", #core.expiredLedgerFiles(files, now, 0), 0)

  -- ledgerDayIsPast: redact may only touch PAST days (today's file is hot)
  check("ledgerDayIsPast: yesterday ok", core.ledgerDayIsPast("2026-06-08", now) == true)
  check("ledgerDayIsPast: today refused", core.ledgerDayIsPast("2026-06-09", now) == false)
  check("ledgerDayIsPast: future refused", core.ledgerDayIsPast("2026-06-10", now) == false)
  check("ledgerDayIsPast: nil day refused", core.ledgerDayIsPast(nil, now) == false)

  -- ledgerCapVictims: size cap deletes oldest first but NEVER the newest (hot) file
  local live = { "2026-06-01.jsonl", "2026-06-02.jsonl", "2026-06-03.jsonl" }
  local sizes = { ["2026-06-01.jsonl"] = 600, ["2026-06-02.jsonl"] = 600, ["2026-06-03.jsonl"] = 600 }
  local vict = core.ledgerCapVictims(live, sizes, 700)
  eq("capVictims: count to get under cap", #vict, 2)
  eq("capVictims: oldest first", vict[1], "2026-06-01.jsonl")
  eq("capVictims: second oldest next", vict[2], "2026-06-02.jsonl")
  -- a single file over the cap is the newest -> untouchable (today's audit trail)
  eq("capVictims: lone over-cap file kept (never the newest)",
     #core.ledgerCapVictims({ "2026-06-09.jsonl" }, { ["2026-06-09.jsonl"] = 5 * 1024 * 1024 }, 1024), 0)
  -- even when older deletions can't free enough, the loop stops before the newest
  local vict2 = core.ledgerCapVictims(live, sizes, 100)
  eq("capVictims: stops before newest even while over cap", #vict2, 2)
  eq("capVictims: cap 0 = disabled", #core.ledgerCapVictims(live, sizes, 0), 0)
  eq("capVictims: under cap -> none", #core.ledgerCapVictims(live, sizes, 9999), 0)

  check("narrateEvent: decision shows provenance",
    core.narrateEvent({ type = "decision", outcome = "deny", tool = "Bash", summary = "x",
                        by = "autoDeny", pattern = "Bash(rm*)" }):find("autoDeny", 1, true) ~= nil)
  check("renderNarrative: contains a prompt line",
    core.renderNarrative(evs):find("fix bug", 1, true) ~= nil)
  check("renderNarrative: empty -> placeholder",
    core.renderNarrative({}):find("no activity", 1, true) ~= nil)
  check("auditReviewPrompt: read-only instruction",
    core.auditReviewPrompt("LOG", { scope = "session proj" }):find("READ%-ONLY") ~= nil)
  check("auditReviewPrompt: embeds the narrative",
    core.auditReviewPrompt("LOGTEXT"):find("LOGTEXT", 1, true) ~= nil)
end

-- ---- Improve cards: bug fixes + previously-untested branches --------------
do
  local function aline(text)
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end

  -- repoFromRemote: scp, https, and the new ssh:// (with user+port) form
  eq("repo: scp-style git@host:owner/repo.git",
     core.repoFromRemote("git@github.com:WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: https with .git",
     core.repoFromRemote("https://github.com/WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: ssh://user@host:port/owner/repo.git",
     core.repoFromRemote("ssh://git@github.com:22/WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: ssh:// without user", core.repoFromRemote("ssh://github.com/o/r"), "o/r")

  -- transcriptSnippet: whitespace-only block is skipped to the older real text
  eq("snippet: whitespace-only block skipped",
     core.transcriptSnippet(aline("real answer") .. "\n" .. aline("   ")), "real answer")
  eq("snippet: only-whitespace -> nil", core.transcriptSnippet(aline("   \n  ")), nil)
  -- multiple text blocks on one assistant line: the last non-empty wins
  local multi = core.json.encode({ type = "assistant", message = { role = "assistant",
    content = { { type = "text", text = "first" }, { type = "text", text = "second" } } } })
  eq("snippet: last text block wins", core.transcriptSnippet(multi), "second")
  -- truncation appends the … ellipsis and preserves a prefix of the original
  local snip = core.transcriptSnippet(aline(string.rep("a", 300)), 20)
  check("snippet: truncation appends ellipsis", snip:sub(-3) == "\226\128\166")
  check("snippet: truncation keeps a prefix", snip:sub(1, 3) == "aaa")
  -- UTF-8 boundary: a run of 3-byte glyphs is never split mid-character
  local usnip = core.transcriptSnippet(aline(string.rep("\226\128\166", 30)), 20)
  check("snippet: utf8-safe within bound", #usnip <= 20)
  check("snippet: utf8-safe keeps whole glyphs only", (#usnip:sub(1, #usnip - 3) % 3) == 0)

  -- shouldPrune: session_id == nil (not just "") is an orphan; pruneSeconds=0 off
  local opts = { pruneNoSid = true, pruneSeconds = 86400 }
  eq("prune: nil session_id orphan -> true",
     core.shouldPrune({ stale = true, session_id = nil, updated = 100 }, 1000, opts), true)
  local noBackstop = { pruneNoSid = true, pruneSeconds = 0 }
  eq("prune: pruneSeconds=0 disables ghost backstop",
     core.shouldPrune({ stale = true, session_id = "abc", updated = 0 }, 9e9, noBackstop), false)
  eq("prune: pruneSeconds=0 still prunes a true orphan",
     core.shouldPrune({ stale = true, session_id = "", updated = 0 }, 9e9, noBackstop), true)

  -- cycleNext advances on repeated calls, threading the prior key (the hotkey loop)
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  local k = core.cycleNext(list, nil).key;  eq("cycle: 1st -> a", k, "a")
  k = core.cycleNext(list, k).key;          eq("cycle: 2nd -> b", k, "b")
  k = core.cycleNext(list, k).key;          eq("cycle: 3rd -> c", k, "c")
  k = core.cycleNext(list, k).key;          eq("cycle: 4th wraps -> a", k, "a")

  -- jump-needy fallback: no approval -> frontSession is the target
  local idleList = { { key = "x", name = "x", status = "idle" }, { key = "y", name = "y", status = "working" } }
  eq("jump-needy: falls back to front session",
     (core.nextApproval(idleList) or core.frontSession(idleList)).key, "x")

  -- parseStatusList: same-status entries break ties by name (apple before zebra)
  local sorted = core.parseStatusList({
    { key = "k2", content = core.json.encode({ name = "zebra", status = "working", updated = 100 }) },
    { key = "k1", content = core.json.encode({ name = "apple", status = "working", updated = 100 }) },
  }, 100, 9999)
  eq("parseStatusList: name tiebreak within status", sorted[1].name, "apple")

  -- usageInWindow: only events whose ts is inside [now-window, now] count
  local now = 10000
  eq("usageInWindow: only in-window events count", core.usageInWindow({
    { ts = now - 10, input = 1, output = 1, cacheCreate = 0 },  -- in window -> 2
    { ts = now - 99999, input = 5, output = 5 },                -- outside -> 0
    { input = 9, output = 9 },                                  -- no ts -> skipped
  }, now, 3600), 2)

  -- isoToEpoch: a 2024 leap day (Feb 29 exists) -> Feb 28 to Mar 1 spans two days
  eq("iso: 2024 leap day spans Feb 29",
     core.isoToEpoch("2024-03-01T00:00:00Z") - core.isoToEpoch("2024-02-28T00:00:00Z"), 2 * 86400)
end

-- ---- fmtDuration -----------------------------------------------------------
do
  eq("fmt: seconds", core.fmtDuration(45), "45s")
  eq("fmt: minutes+seconds", core.fmtDuration(90), "1m 30s")
  eq("fmt: whole minutes", core.fmtDuration(120), "2m")
  eq("fmt: hours+minutes", core.fmtDuration(3600 + 5 * 60), "1h 5m")
  eq("fmt: whole hours", core.fmtDuration(7200), "2h")
  eq("fmt: negative clamps to 0s", core.fmtDuration(-5), "0s")
end

-- ---- fleetStats: aggregate the ledger --------------------------------------
do
  local evs = {
    { ts = 10, type = "session_start", session_id = "s1", name = "alpha" },
    { ts = 20, type = "prompt",        session_id = "s1", name = "alpha" },
    { ts = 30, type = "prompt",        session_id = "s1", name = "alpha" },
    { ts = 40, type = "tool_request",  session_id = "s1", name = "alpha", tool = "Bash" },
    { ts = 70, type = "decision",      session_id = "s1", name = "alpha", outcome = "allow", by = "human" },
    { ts = 80, type = "decision",      session_id = "s1", name = "alpha", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 25, type = "prompt",        session_id = "s2", name = "bravo" },
    { ts = 35, type = "decision",      session_id = "s2", name = "bravo", outcome = "fallback", by = "timeout-fallback" },
    { ts = 50, type = "spawn",         session_id = "s2", name = "bravo" },
  }
  local st = core.fleetStats(evs, { now = 200, topN = 8 })
  eq("fleet: total prompts", st.totals.prompts, 3)
  eq("fleet: total sessions", st.totals.sessions, 2)
  eq("fleet: total spawns", st.totals.spawns, 1)
  eq("fleet: total toolRequests", st.totals.toolRequests, 1)
  eq("fleet: decisions allow", st.decisions.allow, 1)
  eq("fleet: decisions deny", st.decisions.deny, 1)
  eq("fleet: decisions fallback (own bucket, not a denial)", st.decisions.fallback, 1)
  eq("fleet: decisions total", st.decisions.total, 3)
  eq("fleet: provenance autoDeny", st.provenance.autoDeny, 1)
  eq("fleet: provenance timeout-fallback", st.provenance["timeout-fallback"], 1)
  eq("fleet: provenance human", st.provenance.human, 1)
  eq("fleet: most active session is s1", st.mostActive[1].session_id, "s1")
  eq("fleet: most active prompt count", st.mostActive[1].prompts, 2)
  -- s1 request@40 -> human decision@70 = 30s; s2's fallback has no preceding request
  eq("fleet: approval blocked seconds", st.approvalBlockedSeconds, 30)
  check("fleet: fleet denial rate ~1/3", math.abs(st.denialRate - (1 / 3)) < 1e-9)

  -- maxBlock cap: an over-cap gap is DROPPED (not clamped). One session, a single
  -- request@0 -> human@4000 pair with maxBlock=1800 contributes ZERO, not 1800.
  local capped = core.fleetStats({
    { ts = 0,    type = "tool_request", session_id = "z", tool = "Bash" },
    { ts = 4000, type = "decision", session_id = "z", outcome = "allow", by = "human" },
  }, { maxBlock = 1800 })
  eq("fleet: over-cap gap dropped (not clamped)", capped.approvalBlockedSeconds, 0)
end

-- ---- blockedSeconds: request->resolving-decision pairing -------------------
do
  -- simple in-window gap credited to a human decision
  eq("blocked: request->human gap", core.blockedSeconds({
    { ts = 100, type = "tool_request" },
    { ts = 130, type = "decision", by = "human" },
  }, 1800), 30)
  -- over-cap gap dropped entirely
  eq("blocked: over-cap dropped", core.blockedSeconds({
    { ts = 0, type = "tool_request" },
    { ts = 4000, type = "decision", by = "human" },
  }, 1800), 0)
  -- mixed: one in-window (30) + one over-cap (dropped) -> only the in-window counts
  eq("blocked: mixed sums only in-window", core.blockedSeconds({
    { ts = 100,  type = "tool_request" },
    { ts = 130,  type = "decision", by = "human" },     -- +30
    { ts = 200,  type = "tool_request" },
    { ts = 9000, type = "decision", by = "human" },     -- over cap -> 0
  }, 1800), 30)
  -- B2: an auto-decision RESOLVES the request, so a later human decision with no
  -- intervening request is NOT credited (was the stale-lastReqTs over-attribution bug).
  eq("blocked: auto-decision clears pending (no mis-attribution)", core.blockedSeconds({
    { ts = 100, type = "tool_request" },
    { ts = 110, type = "decision", by = "autoAllow" },  -- resolves; not credited
    { ts = 300, type = "decision", by = "human" },      -- no pending request -> 0
  }, 1800), 0)
  -- an auto-decision is never credited even when it directly resolves a request
  eq("blocked: auto-decision never credited", core.blockedSeconds({
    { ts = 100, type = "tool_request" },
    { ts = 130, type = "decision", by = "autoDeny" },
  }, 1800), 0)
  -- unsorted input is handled (sorts a copy internally)
  eq("blocked: unsorted input sorted", core.blockedSeconds({
    { ts = 130, type = "decision", by = "human" },
    { ts = 100, type = "tool_request" },
  }, 1800), 30)
end

-- ---- sessionRisk: empirical per-session score ------------------------------
do
  local clean = {
    { ts = 10, type = "tool_request", session_id = "c", tool = "Bash" },
    { ts = 15, type = "decision", session_id = "c", outcome = "allow", by = "human" },
    { ts = 20, type = "tool_request", session_id = "c", tool = "Edit" },
    { ts = 25, type = "decision", session_id = "c", outcome = "allow", by = "human" },
  }
  local rc = core.sessionRisk(clean, {})
  eq("risk: clean band low", rc.band, "low")
  check("risk: clean score small (<=5)", rc.score <= 5)
  eq("risk: empty -> score 0", core.sessionRisk({}, {}).score, 0)
  eq("risk: empty -> band low", core.sessionRisk({}, {}).band, "low")
  eq("risk: deterministic", core.sessionRisk(clean, {}).score, core.sessionRisk(clean, {}).score)

  local mid = {
    { ts = 10, type = "tool_request", session_id = "m", tool = "Bash" },
    { ts = 12, type = "decision", session_id = "m", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 20, type = "tool_request", session_id = "m", tool = "Bash" },
    { ts = 22, type = "decision", session_id = "m", outcome = "deny", by = "autoDeny", pattern = "Bash(curl*)" },
    { ts = 30, type = "tool_request", session_id = "m", tool = "Edit" },
    { ts = 32, type = "decision", session_id = "m", outcome = "allow", by = "human" },
    { ts = 40, type = "tool_request", session_id = "m", tool = "Edit" },
    { ts = 42, type = "decision", session_id = "m", outcome = "allow", by = "human" },
  }
  eq("risk: mid band med", core.sessionRisk(mid, {}).band, "med")

  local risky = {
    { ts = 10,  type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 400, type = "decision", session_id = "h", outcome = "deny", by = "human" },   -- stale (390s) deny
    { ts = 410, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 412, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 420, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 422, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(curl*)" },
    { ts = 430, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 432, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 440, type = "tool_request", session_id = "h", tool = "Write" },
    { ts = 442, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Write" },
    { ts = 450, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 452, type = "decision", session_id = "h", outcome = "fallback", by = "timeout-fallback" },
  }
  local rh = core.sessionRisk(risky, {})
  eq("risk: risky band high", rh.band, "high")
  check("risk: score clamped <= 100", rh.score <= 100)
  eq("risk: signals autoDenyHits", rh.signals.autoDenyHits, 4)
  eq("risk: signals timeoutFallbacks", rh.signals.timeoutFallbacks, 1)
  eq("risk: signals staleApprovals", rh.signals.staleApprovals, 1)

  -- B2 (staleApprovals path): an auto-decision RESOLVES the request, so a later human
  -- decision with no intervening request must NOT be mis-paired as a slow approval.
  -- (Mirrors the blockedSeconds auto-clears-pending case but on the discrete counter;
  -- catches a regression that re-nests `lastReqTs = nil` into the human-only branch.)
  eq("risk: auto-decision clears pending -> no stale approval", core.sessionRisk({
    { ts = 0,    type = "tool_request", session_id = "k", tool = "Bash" },
    { ts = 10,   type = "decision", session_id = "k", outcome = "allow", by = "autoAllow" },
    { ts = 1000, type = "decision", session_id = "k", outcome = "allow", by = "human" },
  }, {}).signals.staleApprovals, 0)
  -- Companion: a genuine slow request->human gap (no auto-decision between, > 300s) DOES
  -- count, so the test pins both directions and can't pass by always reading zero.
  eq("risk: genuine slow request->human gap counts", core.sessionRisk({
    { ts = 0,    type = "tool_request", session_id = "k2", tool = "Bash" },
    { ts = 1000, type = "decision", session_id = "k2", outcome = "allow", by = "human" },
  }, {}).signals.staleApprovals, 1)

  -- F-003 (bug sweep): a stringified threshold from config (a quoted JSON number)
  -- must be coerced, not crash the numeric compares (which would freeze refresh).
  local okT, rT = pcall(core.sessionRisk,
    { { ts = 0, type = "decision", session_id = "k", outcome = "allow", by = "human" } },
    { thresholds = { high = "67", med = "34" } })
  check("risk: string thresholds don't throw", okT)
  check("risk: string thresholds still yield a band", type(rT) == "table" and rT.band ~= nil)
  local okS = pcall(core.sessionRisk, {
    { ts = 0,   type = "tool_request", session_id = "k" },
    { ts = 500, type = "decision", session_id = "k", outcome = "allow", by = "human" },
  }, { thresholds = { staleSeconds = "300" } })
  check("risk: string staleSeconds doesn't throw", okS)

  -- F-002 (bug sweep): the band must agree with the DISPLAYED (rounded) score at a
  -- boundary. This event mix is hand-tuned so the RAW score lands in (33.5, 34) -- just
  -- under default th.med=34 but rounding up to it -- to prove the band derives from the
  -- rounded `shown`, not raw. The rawScore window is asserted directly below, so a weight
  -- retune that slides raw out of (33.5, 34) fails loudly here instead of staying green.
  local evs, ts = {}, 0
  for _ = 1, 13 do ts = ts + 1; evs[#evs + 1] = { ts = ts, type = "tool_request", session_id = "x", tool = "Bash" } end
  ts = ts + 5; evs[#evs + 1] = { ts = ts, type = "decision", session_id = "x", outcome = "deny", by = "human" }
  ts = ts + 5; evs[#evs + 1] = { ts = ts, type = "tool_request", session_id = "x", tool = "Bash" }
  ts = ts + 400; evs[#evs + 1] = { ts = ts, type = "decision", session_id = "x", outcome = "fallback", by = "timeout-fallback" }
  local rB = core.sessionRisk(evs, {})
  eq("risk: boundary score rounds to 34", rB.score, 34)
  eq("risk: band agrees with rounded score (med, not low)", rB.band, "med")
  check("risk: raw score sits in the (33.5, 34) boundary window", rB.rawScore > 33.5 and rB.rawScore < 34)
  -- F-003 follow-up: a string `high` must actually FEED the band compare, not merely
  -- avoid throwing. shown=34 >= 30 reads "high" ONLY if "30" was coerced to a number
  -- (a string would throw -> earlier pcall; a silent fallback to default 67 stays "med").
  eq("risk: string high threshold coerced INTO the band compare",
     core.sessionRisk(evs, { thresholds = { high = "30" } }).band, "high")
end

-- ---- resolveGateTools: per-session precedence + sentinel -------------------
do
  eq("gate: no inputs -> built-in default", core.resolveGateTools(nil, nil, nil), core.DEFAULT_GATE_TOOLS)
  eq("gate: fleet default used", core.resolveGateTools(nil, nil, "Bash Edit"), "Bash Edit")
  eq("gate: session override wins", core.resolveGateTools("WebFetch Bash", nil, "Bash Edit"), "WebFetch Bash")
  eq("gate: sentinel '-' gates nothing", core.resolveGateTools("-", nil, "Bash Edit"), "")
  eq("gate: sentinel NONE gates nothing", core.resolveGateTools("NONE", nil, "Bash"), "")
  eq("gate: sentinel none (lower) gates nothing", core.resolveGateTools("none", nil, "Bash"), "")
  eq("gate: blank override is NOT an override", core.resolveGateTools("   ", nil, "Bash Edit"), "Bash Edit")
  eq("gate: empty override is NOT an override", core.resolveGateTools("", nil, "Bash Edit"), "Bash Edit")
  eq("gate: override normalized + deduped", core.resolveGateTools("Bash, Edit ,Bash", nil, nil), "Bash Edit")
  eq("gate: provider-default layer", core.resolveGateTools(nil, "Write", "Bash"), "Write")
  eq("gate: override beats provider default", core.resolveGateTools("Edit", "Write", "Bash"), "Edit")
end

-- ---- shouldDrainClose: fire only on a fresh transition into done -----------
do
  eq("drain: working->done fires", core.shouldDrainClose(true, "working", "done"), true)
  eq("drain: approval->done fires", core.shouldDrainClose(true, "approval", "done"), true)
  eq("drain: done->done no fire (already handled)", core.shouldDrainClose(true, "done", "done"), false)
  eq("drain: not draining no fire", core.shouldDrainClose(false, "working", "done"), false)
  eq("drain: nil draining no fire", core.shouldDrainClose(nil, "working", "done"), false)
  eq("drain: working->working no fire", core.shouldDrainClose(true, "working", "working"), false)

  -- the "draining" tile badge: armed + feature on -> true; otherwise nil (omitted
  -- from the JSON payload entirely, like the other optional tile flags)
  eq("drain-badge: armed + enabled -> shown", core.drainingBadge(true, true), true)
  eq("drain-badge: not armed -> hidden (nil)", core.drainingBadge(true, false), nil)
  eq("drain-badge: feature off -> hidden (nil)", core.drainingBadge(false, true), nil)
end

-- ---- collisions: 2+ active sessions sharing a working dir ------------------
do
  local r = core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "working" },
    { key = "c", cwd = "/x/q", status = "working" },
  }, {})
  eq("collide: a flagged", r.flags.a, true)
  eq("collide: b flagged", r.flags.b, true)
  eq("collide: c alone not flagged", r.flags.c, nil)
  eq("collide: idle peer not counted", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "idle" },
  }, {}).flags.a, nil)
  eq("collide: stale peer excluded", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "working", stale = true },
  }, {}).flags.a, nil)
  local items4 = {
    { key = "a", cwd = "/repo/sub1", status = "working" },
    { key = "b", cwd = "/repo/sub2", status = "approval" },
  }
  local root = { ["/repo/sub1"] = "/repo", ["/repo/sub2"] = "/repo" }
  eq("collide: git-root groups subfolders", core.collisions(items4, { rootByCwd = root }).flags.a, true)
  eq("collide: cwd mode does NOT group subfolders", core.collisions(items4, {}).flags.a, nil)
  local root5 = { ["/x/p"] = "", ["/x/q"] = "" }
  eq("collide: empty root sentinel falls back to cwd", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/q", status = "working" },
  }, { rootByCwd = root5 }).flags.a, nil)
end

-- ---- providerByModel + respawnSpec: relaunch a dead session ----------------
do
  local cfg = core.json.decode([[
    { "spawn": { "editor": "terminal" },
      "providers": [
        { "id": "anthropic-opus", "kind": "anthropic", "model": "claude-opus-4-8" },
        { "id": "gemini", "kind": "gateway", "model": "gemini-2.5-pro",
          "baseUrl": "http://localhost:4000", "authTokenEnv": "MY_KEY" } ] }]])
  eq("provByModel: anthropic by model alone", core.providerByModel(cfg, "claude-opus-4-8", nil).id, "anthropic-opus")
  eq("provByModel: gateway needs base url too",
     core.providerByModel(cfg, "gemini-2.5-pro", "http://localhost:4000").id, "gemini")
  check("provByModel: gateway model w/o base url -> nil", core.providerByModel(cfg, "gemini-2.5-pro", nil) == nil)
  check("provByModel: unknown model -> nil", core.providerByModel(cfg, "gpt-4", nil) == nil)

  -- R2 #11: a claude/anthropic-kind profile carrying a STALE baseUrl (left over
  -- from a gateway->claude kind switch before the Save-merge cleared the gateway
  -- fields) must still match a base-less tile by model alone: only a GATEWAY
  -- profile has a base-URL signature. Otherwise respawn runs bare `claude` on
  -- the account-default model with no warning.
  local cfgStale = core.json.decode([[
    { "providers": [ { "id": "ant", "kind": "anthropic", "model": "m-1",
                       "baseUrl": "http://localhost:4000" } ] }]])
  eq("provByModel: anthropic-kind ignores stale baseUrl",
     core.providerByModel(cfgStale, "m-1", nil).id, "ant")
  check("provByModel: anthropic-kind never matches BY base url",
        core.providerByModel(cfgStale, "m-1", "http://localhost:4000") == nil)
  eq("respawn: stale-baseUrl anthropic profile still matched (faithful model)",
     core.respawnSpec({ editor = "terminal", cwd = "/x", model = "m-1" }, cfgStale).providerId, "ant")

  local a = core.respawnSpec({ editor = "kitty", cwd = "/x/p", permission_mode = "plan", model = "claude-opus-4-8" }, cfg)
  eq("respawn: anthropic canRespawn", a.canRespawn, true)
  eq("respawn: anthropic providerId", a.providerId, "anthropic-opus")
  eq("respawn: project = cwd", a.project, "/x/p")
  eq("respawn: editor carried", a.editor, "kitty")
  eq("respawn: permission mode carried", a.permissionMode, "plan")
  eq("respawn: gateway providerId matched", core.respawnSpec(
    { editor = "terminal", cwd = "/x/q", model = "gemini-2.5-pro", base_url = "http://localhost:4000" }, cfg).providerId, "gemini")
  local gb = core.respawnSpec({ editor = "terminal", cwd = "/x/q", model = "mystery", base_url = "http://elsewhere" }, cfg)
  eq("respawn: unknown gateway not respawnable", gb.canRespawn, false)
  check("respawn: unknown gateway reason set", type(gb.reason) == "string")
  local b = core.respawnSpec({ editor = "terminal", cwd = "/x/r", model = "claude-future-9" }, cfg)
  eq("respawn: unknown anthropic still respawnable (bare claude)", b.canRespawn, true)
  check("respawn: unknown anthropic has nil providerId", b.providerId == nil)
  -- faithful bare respawn: the FX call sites pass `rs.providerId or ""` (the
  -- explicit-none sentinel), so it must resolve to NO provider, never the
  -- spawn.provider default the config may carry.
  local rcfg = { spawn = { provider = "gemini" }, providers = cfg.providers }
  eq("respawn: bare session resolves to no provider key",
     core.spawnProviderKey(rcfg, b.providerId or ""), nil)
  eq("respawn: editor falls back to spawn.editor", core.respawnSpec({ cwd = "/x/s", model = "claude-opus-4-8" }, cfg).editor, "terminal")
  eq("respawn: no cwd -> not respawnable", core.respawnSpec({ model = "x" }, cfg).canRespawn, false)
end

-- ---- filterTiles: free-text token-AND search over a session list ----------
do
  local list = {
    { key = "a", name = "auth-api",  label = "Auth service", cwd = "/Users/x/auth",  status = "working",  group = "backend" },
    { key = "b", name = "web-ui",    cwd = "/Users/x/web",   status = "approval", group = "frontend" },
    { key = "c", name = "auth-docs", cwd = "/Users/x/docs",  status = "idle" },
  }
  eq("filter: blank query keeps all", #core.filterTiles(list, ""), 3)
  eq("filter: nil query keeps all", #core.filterTiles(list, nil), 3)
  eq("filter: whitespace query keeps all", #core.filterTiles(list, "   "), 3)
  eq("filter: name substring", #core.filterTiles(list, "auth"), 2)
  eq("filter: case-insensitive", #core.filterTiles(list, "AUTH"), 2)
  eq("filter: matches display label", #core.filterTiles(list, "service"), 1)
  eq("filter: matches cwd path", #core.filterTiles(list, "/web"), 1)
  eq("filter: matches status", #core.filterTiles(list, "approval"), 1)
  eq("filter: matches group", #core.filterTiles(list, "backend"), 1)
  eq("filter: token-AND narrows", #core.filterTiles(list, "auth working"), 1)
  eq("filter: token-AND no match -> empty", #core.filterTiles(list, "auth frontend"), 0)
  eq("filter: no match -> empty", #core.filterTiles(list, "zzz"), 0)
  check("filter: returns the matching item", core.filterTiles(list, "web-ui")[1].key == "b")
  eq("filter: nil list -> empty", #core.filterTiles(nil, "x"), 0)
end

-- ---- session groups: applyGroups / groupNames / setGroup -------------------
do
  local list = {
    { key = "a", name = "auth", projectKey = "proj-auth" },
    { key = "b", name = "web",  projectKey = "proj-web" },
    { key = "c", name = "docs", cwd = "/legacy/docs" },           -- legacy cwd key
    { key = "d", name = "misc", projectKey = "proj-misc" },        -- ungrouped
    -- R2-B: projectKey present but ungrouped, with a cwd that collides with a legacy
    -- cwd-keyed entry. The cwd fallback must NOT fire (it's gated on no projectKey) --
    -- else a real migrated session silently inherits a stale legacy group.
    { key = "e", name = "migrated", projectKey = "proj-migrated", cwd = "/legacy/docs" },
  }
  local groups = { ["proj-auth"] = "backend", ["proj-web"] = "frontend", ["/legacy/docs"] = "backend" }
  core.applyGroups(list, groups)
  eq("groups: projectKey-tagged", list[1].group, "backend")
  eq("groups: frontend tagged", list[2].group, "frontend")
  eq("groups: legacy cwd fallback (no projectKey)", list[3].group, "backend")
  eq("groups: ungrouped stays nil", list[4].group, nil)
  eq("groups: projectKey'd session ignores stale legacy cwd group (R2-B)", list[5].group, nil)
  eq("groups: name untouched", list[1].name, "auth")

  local names = core.groupNames(list)
  eq("groups: distinct count", #names, 2)
  eq("groups: sorted first", names[1], "backend")
  eq("groups: sorted second", names[2], "frontend")
  eq("groups: empty list -> no names", #core.groupNames({}), 0)

  local g2 = core.setGroup(groups, "proj-misc", "infra")
  eq("setGroup: adds new", g2["proj-misc"], "infra")
  eq("setGroup: immutable (input untouched)", groups["proj-misc"], nil)
  eq("setGroup: overwrites existing (replace, not merge)", core.setGroup(groups, "proj-auth", "x")["proj-auth"], "x")
  eq("setGroup: blank clears", core.setGroup(groups, "proj-auth", "  ")["proj-auth"], nil)
  eq("setGroup: trims value", core.setGroup(groups, "proj-misc", "  ops ")["proj-misc"], "ops")
  eq("setGroup: empty key is no-op", core.setGroup(groups, "", "x")["proj-auth"], "backend")
  eq("setGroup: nil map tolerated (seed from nothing)", core.setGroup(nil, "k", "v")["k"], "v")
  -- applyGroups with no map clears tags (all nil)
  core.applyGroups(list, nil)
  eq("groups: nil map -> all ungrouped", list[1].group, nil)
end

-- ---- selectActionable: which keys a bulk action targets --------------------
do
  local list = {
    { key = "w1", status = "approval", gate = "waiting" },        -- needs decision (headless)
    { key = "n1", status = "approval" },                          -- needs decision (native)
    { key = "wk", status = "working" },
    { key = "wk2", status = "working" },
    { key = "id", status = "idle" },
    { key = "dn", status = "done" },
    { key = "st", status = "approval", stale = true },            -- stale -> never targeted
  }
  local ap = core.selectActionable(list, "approve")
  eq("bulk approve: count (excludes stale)", #ap, 2)
  check("bulk approve: includes headless waiter", ap[1] == "w1")
  check("bulk approve: includes native waiter", ap[2] == "n1")
  local stp = core.selectActionable(list, "stop")
  eq("bulk stop: only working", #stp, 2)
  check("bulk stop: working keys", stp[1] == "wk" and stp[2] == "wk2")
  local ng = core.selectActionable(list, "nudge")
  eq("bulk nudge: live non-approval sessions", #ng, 4)
  local ngHas = {}; for _, k in ipairs(ng) do ngHas[k] = true end
  check("bulk nudge: excludes approval waiters (would corrupt y/n)", not ngHas["w1"] and not ngHas["n1"])
  check("bulk nudge: includes idle + done", ngHas["id"] and ngHas["dn"])
  eq("bulk: unknown action -> none", #core.selectActionable(list, "bogus"), 0)
  eq("bulk: nil list -> none", #core.selectActionable(nil, "approve"), 0)
  eq("bulk: item without key skipped", #core.selectActionable({ { status = "approval" } }, "approve"), 0)
  -- BULK_RULES is the single source the panel JS also reads (injected as __BULK_RULES__);
  -- pin its shape so selectActionable and the JS twin can't silently disagree.
  check("bulk: rules table exists", type(core.BULK_RULES) == "table")
  eq("bulk: approve rule matches approval", core.BULK_RULES.approve.match, "approval")
  eq("bulk: stop rule matches working", core.BULK_RULES.stop.match, "working")
  eq("bulk: nudge rule excludes approval", core.BULK_RULES.nudge.exclude, "approval")
end

-- ---- sessionTimeline: chronological per-session slice ----------------------
do
  local evs = {
    { ts = 30, type = "prompt",       session_id = "s1", prompt = "third" },
    { ts = 10, type = "session_start", session_id = "s1" },
    { ts = 20, type = "tool_request", session_id = "s1", tool = "Bash" },
    { ts = 15, type = "prompt",       session_id = "s2", prompt = "other session" },
    { ts = 25, type = "decision",     session_id = "s2", outcome = "allow" },
  }
  local t1 = core.sessionTimeline(evs, "s1")
  eq("timeline: scopes to one session", #t1, 3)
  eq("timeline: ascending first", t1[1].ts, 10)
  eq("timeline: ascending middle", t1[2].ts, 20)
  eq("timeline: ascending last", t1[3].ts, 30)
  eq("timeline: other session excluded", #core.sessionTimeline(evs, "s2"), 2)
  eq("timeline: nil session -> empty", #core.sessionTimeline(evs, nil), 0)
  eq("timeline: empty session -> empty", #core.sessionTimeline(evs, ""), 0)
  eq("timeline: unknown session -> empty", #core.sessionTimeline(evs, "nope"), 0)
  -- cap keeps the NEWEST `limit`, then sorts ascending
  local many = {}
  for i = 1, 10 do many[i] = { ts = i, type = "prompt", session_id = "s1" } end
  local capped = core.sessionTimeline(many, "s1", { limit = 3 })
  eq("timeline: cap count", #capped, 3)
  eq("timeline: cap keeps newest, ascending", capped[1].ts, 8)
  eq("timeline: cap last is newest", capped[3].ts, 10)
end

-- ---- gateDecisionSummary: grouped last-N gate decisions (roadmap #2) --------
do
  local function dec(ts, sid, tool, outcome, by, pattern, summary)
    return { ts = ts, type = "decision", session_id = sid, tool = tool,
             outcome = outcome, by = by, pattern = pattern, summary = summary }
  end
  -- four identical consecutive denies collapse to one ×4 group
  local burst = {
    dec(40, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)", "rm -rf build"),
    dec(30, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)", "rm -rf dist"),
    dec(20, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)", "rm -rf tmp"),
    dec(10, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)", "rm -rf old"),
  }
  local g = core.gateDecisionSummary(burst, "s1")
  eq("decisions: burst collapses to one group", #g, 1)
  eq("decisions: count", g[1].count, 4)
  eq("decisions: lastTs is newest", g[1].lastTs, 40)
  eq("decisions: firstTs is oldest", g[1].firstTs, 10)
  eq("decisions: summary is newest member's", g[1].summary, "rm -rf build")
  eq("decisions: pattern carried", g[1].pattern, "Bash(rm*)")
  -- an interleaved different decision splits the run (A A B A = 3 groups)
  local mixed = {
    dec(40, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)"),
    dec(30, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)"),
    dec(20, "s1", "Write", "allow", "human"),
    dec(10, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)"),
  }
  local gm = core.gateDecisionSummary(mixed, "s1")
  eq("decisions: interleave splits groups", #gm, 3)
  eq("decisions: newest group first", gm[1].count, 2)
  eq("decisions: middle group is the allow", gm[2].outcome, "allow")
  -- nil vs set pattern are DIFFERENT group keys (no false merge)
  local pat = {
    dec(20, "s1", "Bash", "deny", "autoDeny", "Bash(rm*)"),
    dec(10, "s1", "Bash", "deny", "autoDeny", nil),
  }
  eq("decisions: nil-vs-set pattern split", #core.gateDecisionSummary(pat, "s1"), 2)
  -- limit caps GROUPS (not raw events); newest groups win
  local alt = {}
  for i = 10, 1, -1 do  -- alternate tools -> 10 groups, newest ts=10..1
    alt[#alt + 1] = dec(i, "s1", (i % 2 == 0) and "Bash" or "Write", "allow", "human")
  end
  local gl = core.gateDecisionSummary(alt, "s1", { limit = 3 })
  eq("decisions: limit caps groups", #gl, 3)
  eq("decisions: capped keeps newest", gl[1].lastTs, 10)
  -- sinceTs window + other-session + non-decision exclusion
  local noisy = {
    dec(50, "s1", "Bash", "allow", "human"),
    dec(5,  "s1", "Bash", "allow", "human"),          -- below sinceTs
    dec(45, "s2", "Bash", "deny", "autoDeny"),        -- other session
    { ts = 48, type = "prompt", session_id = "s1" },  -- not a decision
  }
  local gn = core.gateDecisionSummary(noisy, "s1", { sinceTs = 10 })
  eq("decisions: sinceTs + scope filters", #gn, 1)
  eq("decisions: scoped result is the fresh allow", gn[1].lastTs, 50)
  -- degenerate inputs
  eq("decisions: nil session -> empty", #core.gateDecisionSummary(burst, nil), 0)
  eq("decisions: empty session -> empty", #core.gateDecisionSummary(burst, ""), 0)
  eq("decisions: nil events -> empty", #core.gateDecisionSummary(nil, "s1"), 0)
end

-- ---- notificationEvents / unseenNotificationCount (roadmap #6) --------------
do
  local evs = {
    { ts = 90, type = "escalation",   session_id = "s1", minutes = 5 },
    { ts = 80, type = "hung",         session_id = "s1", minutes = 5 },
    { ts = 70, type = "auto_respawn", session_id = "s2" },
    { ts = 60, type = "decision", session_id = "s1", by = "autoDeny", outcome = "deny" },
    { ts = 55, type = "decision", session_id = "s1", by = "timeout-fallback", outcome = "allow" },
    { ts = 50, type = "decision", session_id = "s1", by = "human", outcome = "allow" },  -- excluded
    { ts = 45, type = "decision", session_id = "s1", outcome = "allow" },                -- no by -> excluded
    { ts = 40, type = "prompt",   session_id = "s1", prompt = "hi" },                    -- excluded
    { ts = 5,  type = "escalation", session_id = "s1" },                                 -- below sinceTs
  }
  local n = core.notificationEvents(evs, { sinceTs = 10 })
  eq("notify: count", #n, 5)
  eq("notify: newest first", n[1].ts, 90)
  eq("notify: oldest kept", n[5].ts, 55)
  eq("notify: limit caps", #core.notificationEvents(evs, { sinceTs = 10, limit = 2 }), 2)
  eq("notify: nil events -> empty", #core.notificationEvents(nil, {}), 0)
  -- unseen counting (newest-first input)
  eq("notify: unseen between events", core.unseenNotificationCount(n, 72), 2)
  eq("notify: unseen nil lastSeen = all", core.unseenNotificationCount(n, nil), 5)
  eq("notify: unseen 0 lastSeen = all", core.unseenNotificationCount(n, 0), 5)
  eq("notify: lastSeen newer than all -> 0", core.unseenNotificationCount(n, 999), 0)
  eq("notify: empty list -> 0", core.unseenNotificationCount({}, 0), 0)
  eq("notify: nil list -> 0", core.unseenNotificationCount(nil, 0), 0)
  -- narrateEvent renders the new types without crashing on missing fields
  check("notify: narrate escalation", core.narrateEvent({ type = "escalation" }):find("waiting too long", 1, true) ~= nil)
  check("notify: narrate hung", core.narrateEvent({ type = "hung" }):find("stalled", 1, true) ~= nil)
  check("notify: narrate auto_respawn", core.narrateEvent({ type = "auto_respawn" }):find("respawned", 1, true) ~= nil)
  check("notify: narrate drain_close", core.narrateEvent({ type = "drain_close" }):find("drained", 1, true) ~= nil)
end

-- ---- SSH status bridge (roadmap #7): pure layer -----------------------------
do
  -- sshDest: the one dest formatter
  eq("bridge: dest user@host", core.sshDest({ host = "devbox", user = "adam" }), "adam@devbox")
  eq("bridge: dest host only", core.sshDest({ host = "devbox" }), "devbox")
  eq("bridge: dest nil host -> nil", core.sshDest({ user = "adam" }), nil)
  eq("bridge: dest empty host -> nil", core.sshDest({ host = "" }), nil)
  eq("bridge: dest non-table -> nil", core.sshDest("devbox"), nil)
  -- sshWrap still works through sshDest (regression)
  check("bridge: sshWrap unchanged", core.sshWrap("cd /p && claude", { host = "h", user = "u" })
    :find("^ssh %-t u@h ") ~= nil)
  -- sshHosts: gated on bridge.enabled, deduped, ns sanitized
  local cfgOff = { providers = { { id = "r", ssh = { host = "devbox", user = "adam" } } } }
  eq("bridge: hosts gated off by default", #core.sshHosts(cfgOff), 0)
  local cfgOn = { bridge = { enabled = true }, providers = {
    { id = "r1", ssh = { host = "devbox", user = "adam" } },
    { id = "r2", ssh = { host = "devbox", user = "adam" } },   -- same dest: deduped
    { id = "r3", ssh = { host = "my box!", user = "a" } },     -- ns sanitized
    { id = "local1" },                                          -- no ssh: skipped
    { id = "bad", ssh = { user = "x" } },                       -- no host: skipped
  } }
  local hosts = core.sshHosts(cfgOn)
  eq("bridge: hosts deduped count", #hosts, 2)
  eq("bridge: host dest", hosts[1].dest, "adam@devbox")
  eq("bridge: ns sanitized", hosts[2].ns, "my_box_")
  eq("bridge: nil cfg -> {}", #core.sshHosts(nil), 0)
  -- rsyncArgv: exact shape (BatchMode is load-bearing; home-relative remote path)
  eq("bridge: rsync argv", table.concat(core.rsyncArgv("adam@devbox", "/m/devbox"), " "),
     "rsync -az --delete --timeout=5 -e ssh -oBatchMode=yes -oConnectTimeout=3 "
     .. "adam@devbox:.claude/cc-status/ /m/devbox/")
  eq("bridge: rsync nil dest -> nil", core.rsyncArgv(nil, "/m"), nil)
  -- namespacing round-trip; ":" is impossible in local keys (cc_sanitize)
  eq("bridge: namespaceKey", core.namespaceKey("devbox", "abc-123"), "devbox:abc-123")
  local ns, rest = core.splitNamespacedKey("devbox:abc-123")
  eq("bridge: split ns", ns, "devbox")
  eq("bridge: split rest", rest, "abc-123")
  local ns2, rest2 = core.splitNamespacedKey("local-key")
  eq("bridge: local key has nil ns", ns2, nil)
  eq("bridge: local key passes through", rest2, "local-key")
  -- a (theoretical) second colon stays in the rest
  local _, rest3 = core.splitNamespacedKey("h:a:b")
  eq("bridge: only first colon splits", rest3, "a:b")
  -- parseMirrorList: tagging + namespaced projectKey + slack-widened staleness
  local hostSpec = { ns = "devbox", host = "devbox", dest = "adam@devbox" }
  local now = 10000
  local mentries = {
    entry("r1", { name = "remote-proj", status = "working", updated = now - 95,
                  transcript_path = "/home/adam/.claude/projects/-home-a-proj/s1.jsonl" }),
    entry("r2", { name = "fresh", status = "done", updated = now }),
  }
  local ml = core.parseMirrorList(hostSpec, mentries, now, 90, { slack = 15 })
  eq("bridge: mirror count", #ml, 2)
  local r1
  for _, it in ipairs(ml) do if it.remoteKey == "r1" then r1 = it end end
  eq("bridge: key namespaced", r1.key, "devbox:r1")
  eq("bridge: raw key kept", r1.remoteKey, "r1")
  eq("bridge: remote tag host", r1.remote.host, "devbox")
  eq("bridge: projectKey namespaced", r1.projectKey, "devbox:-home-a-proj")
  -- 95s old: stale at the local 90s threshold, NOT stale with 15s slack
  eq("bridge: slack widens staleness", r1.stale, false)
  local mlTight = core.parseMirrorList(hostSpec, mentries, now, 90, { slack = 0 })
  local r1t
  for _, it in ipairs(mlTight) do if it.remoteKey == "r1" then r1t = it end end
  eq("bridge: no slack -> stale", r1t.stale, true)
  -- queueKey folding: a remote projectKey can never collide with the local clone
  eq("bridge: queueKey folds the namespace", core.queueKey({ projectKey = "devbox:-home-a-proj" }),
     "devbox_-home-a-proj")
  -- mergeStatusLists: sort holds across the merge; no collisions by construction
  local localList = { { key = "l1", name = "loc", status = "done" } }
  local merged = core.mergeStatusLists(localList, ml)
  eq("bridge: merged count", #merged, 3)
  eq("bridge: merge re-sorts by status rank (done before working)", merged[1].status, "done")
  eq("bridge: working sorts last", merged[3].status, "working")
  -- decisionContent: nonce binding shared by local + remote writers
  eq("bridge: decision with nonce",
     core.decisionContent("allow", '{"pending":{"nonce":"n-1"}}'), "allow n-1")
  eq("bridge: decision no nonce", core.decisionContent("deny", '{"status":"approval"}'), "deny")
  eq("bridge: decision garbled json", core.decisionContent("allow", "{ not json"), "allow")
  eq("bridge: decision nil text", core.decisionContent("allow", nil), "allow")
  -- decisionSshArgv: exact shape + injection guards (nil, never best-effort)
  eq("bridge: decision argv", table.concat(core.decisionSshArgv("adam@devbox", "k-1", "allow n-1"), " "),
     "ssh -oBatchMode=yes -oConnectTimeout=3 adam@devbox "
     .. "printf %s 'allow n-1' > '.claude/cc-status/k-1.decision.tmp' && "
     .. "mv '.claude/cc-status/k-1.decision.tmp' '.claude/cc-status/k-1.decision'")
  eq("bridge: argv refuses key with semicolon", core.decisionSshArgv("d", "k;rm -rf /", "allow"), nil)
  eq("bridge: argv refuses key with slash", core.decisionSshArgv("d", "../k", "allow"), nil)
  eq("bridge: argv refuses key with space", core.decisionSshArgv("d", "k 1", "allow"), nil)
  eq("bridge: argv refuses non-verb content", core.decisionSshArgv("d", "k", "reboot"), nil)
  eq("bridge: argv refuses quoted content", core.decisionSshArgv("d", "k", "allow 'x'"), nil)
  eq("bridge: argv refuses nil dest", core.decisionSshArgv(nil, "k", "allow"), nil)
  check("bridge: argv accepts bare deny", core.decisionSshArgv("d", "k", "deny") ~= nil)
  -- remoteActionAllowed: headless-only matrix
  local rWait = { remote = { host = "h" }, gate = "waiting" }
  local rIdle = { remote = { host = "h" } }
  eq("bridge: remote approve while waiting", core.remoteActionAllowed(rWait, "approve"), true)
  eq("bridge: remote deny while waiting", core.remoteActionAllowed(rWait, "deny"), true)
  eq("bridge: remote approve not waiting", core.remoteActionAllowed(rIdle, "approve"), false)
  eq("bridge: remote nudge blocked", core.remoteActionAllowed(rWait, "nudge"), false)
  eq("bridge: remote stop blocked", core.remoteActionAllowed(rWait, "stop"), false)
  eq("bridge: remote focus blocked", core.remoteActionAllowed(rWait, "focus"), false)
  eq("bridge: remote autopilot blocked", core.remoteActionAllowed(rWait, "autopilot"), false)
  eq("bridge: keystrokes flag unlocks nudge",
     core.remoteActionAllowed(rWait, "nudge", { keystrokes = true }), true)
  eq("bridge: keystrokes flag never unlocks focus",
     core.remoteActionAllowed(rWait, "focus", { keystrokes = true }), false)
  eq("bridge: local item always allowed", core.remoteActionAllowed({ key = "l" }, "nudge"), true)
  -- actionIsHeadless: remote tiles never focus a window
  eq("bridge: remote action is headless", core.actionIsHeadless(rWait, "approve"), true)
  eq("bridge: remote nudge headless too", core.actionIsHeadless(rIdle, "nudge"), true)
  -- selectActionable: bulk approve reaches a remote waiter; bulk stop/nudge never
  local fleet = {
    { key = "l1", status = "approval", stale = false },
    { key = "devbox:r1", status = "approval", stale = false, remote = { host = "h" }, gate = "waiting" },
    { key = "devbox:r2", status = "working", stale = false, remote = { host = "h" } },
    { key = "l2", status = "working", stale = false },
  }
  local app = core.selectActionable(fleet, "approve")
  eq("bridge: bulk approve includes remote waiter", #app, 2)
  local stops = core.selectActionable(fleet, "stop")
  eq("bridge: bulk stop excludes remote", #stops, 1)
  eq("bridge: bulk stop hits the local one", stops[1], "l2")
  local nudges = core.selectActionable(fleet, "nudge")
  eq("bridge: bulk nudge excludes remote", #nudges, 1)
  -- routing never targets remote (re-pin alongside the bridge)
  eq("bridge: sessionFree excludes remote",
     core.sessionFree({ key = "devbox:r", status = "done", stale = false, remote = { host = "h" } }, {}), false)
  -- recorder contract: approve on a remote waiting tile still routes through
  -- fx.writeDecision with the NAMESPACED key (FX owns local-vs-ssh routing)
  local rec = newRecorder()
  core.handleAction(rec.fx, { key = "devbox:r1", name = "remote-proj", gate = "waiting",
                              remote = { host = "devbox" } }, "approve")
  eq("bridge: handleAction routes to writeDecision", rec.last().op, "writeDecision")
  eq("bridge: writeDecision gets namespaced key", rec.last().a, "devbox:r1")
  eq("bridge: writeDecision verb", rec.last().b, "allow")
end

-- ---- 4c-E project routing: free-set, pick, dispatch gating ------------------
do
  local function sess(key, status, over)
    local s = { key = key, status = status, since = 100, stale = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  -- sessionFree: v1 is done-only (an idle session may be one you're typing into)
  eq("route-free: done -> true", core.sessionFree(sess("a", "done"), {}), true)
  eq("route-free: idle -> false (v1)", core.sessionFree(sess("a", "idle"), {}), false)
  eq("route-free: working -> false", core.sessionFree(sess("a", "working"), {}), false)
  eq("route-free: approval -> false", core.sessionFree(sess("a", "approval"), {}), false)
  eq("route-free: error -> false", core.sessionFree(sess("a", "error"), {}), false)
  eq("route-free: stale -> false", core.sessionFree(sess("a", "done", { stale = true }), {}), false)
  eq("route-free: remote -> false", core.sessionFree(sess("a", "done", { remote = { host = "h" } }), {}), false)
  eq("route-free: draining -> false", core.sessionFree(sess("a", "done"), { draining = true }), false)
  eq("route-free: fresh pending -> false",
     core.sessionFree(sess("a", "done"), { pending = 100, now = 110 }), false)
  eq("route-free: expired pending -> true (lost feed re-eligible)",
     core.sessionFree(sess("a", "done"), { pending = 100, now = 200 }), true)
  eq("route-free: nil item -> false", core.sessionFree(nil, {}), false)
  -- routePendingDone: satisfied (left done/idle) / held / timed out
  eq("route-pending: nil marker -> false", core.routePendingDone(nil, "done", 100, 45), false)
  eq("route-pending: flipped to working -> done", core.routePendingDone(50, "working", 60, 45), true)
  eq("route-pending: still done within timeout -> held", core.routePendingDone(50, "done", 60, 45), false)
  eq("route-pending: still done past timeout -> done", core.routePendingDone(50, "done", 100, 45), true)
  -- routePick: determinism
  local members = { sess("b", "done", { since = 50 }), sess("a", "done", { since = 80 }),
                    sess("c", "working") }
  eq("route-pick: longest-free wins", core.routePick(members, { now = 100 }), "b")
  local tied = { sess("z", "done", { since = 50 }), sess("a", "done", { since = 50 }) }
  eq("route-pick: key tiebreak ascending", core.routePick(tied, { now = 100 }), "a")
  -- missing since reads as newest (lowest priority)
  local noSince = { sess("a", "done", { since = nil }), sess("b", "done", { since = 70 }) }
  eq("route-pick: missing since loses", core.routePick(noSince, { now = 100 }), "b")
  eq("route-pick: all busy -> nil", core.routePick({ sess("a", "working") }, {}), nil)
  eq("route-pick: empty members -> nil", core.routePick({}, {}), nil)
  -- simultaneous finishers: one deterministic pick (the dispatcher feeds ONE per tick)
  local simul = { sess("s2", "done", { since = 90 }), sess("s1", "done", { since = 90 }) }
  eq("route-pick: simultaneous finishers -> single deterministic pick",
     core.routePick(simul, { now = 100 }), "s1")
  -- pending map blocks the just-fed session on the next tick (two-tick drain)
  local two = { sess("s1", "done", { since = 90 }), sess("s2", "done", { since = 95 }) }
  eq("route-pick: tick 1 picks s1", core.routePick(two, { now = 100, pending = {} }), "s1")
  eq("route-pick: tick 2 skips pending s1",
     core.routePick(two, { now = 101, pending = { s1 = 100 } }), "s2")
  -- routeTask: double opt-in gating
  local armed = { tasks = { "t" }, routing = true }
  local unarmed = { tasks = { "t" } }
  local free = { sess("a", "done") }
  eq("route-task: happy path", core.routeTask(free, armed, { globalOn = true, now = 100 }).key, "a")
  eq("route-task: global off -> nil", core.routeTask(free, armed, { globalOn = false, now = 100 }), nil)
  eq("route-task: project unarmed -> nil", core.routeTask(free, unarmed, { globalOn = true, now = 100 }), nil)
  eq("route-task: empty queue -> nil",
     core.routeTask(free, { tasks = {}, routing = true }, { globalOn = true, now = 100 }), nil)
  eq("route-task: nobody free -> nil",
     core.routeTask({ sess("a", "working") }, armed, { globalOn = true, now = 100 }), nil)
  -- queueRouted / queueSetRouted round-trip; tasks preserved; legacy shape clean
  eq("route-flag: legacy file unarmed", core.queueRouted({ tasks = { "x" } }), false)
  local on = core.queueSetRouted({ tasks = { "x", "y" } }, true)
  eq("route-flag: armed", core.queueRouted(on), true)
  eq("route-flag: tasks preserved", table.concat(on.tasks, ","), "x,y")
  local off = core.queueSetRouted(on, false)
  eq("route-flag: disarmed", core.queueRouted(off), false)
  eq("route-flag: off leaves no key (legacy shape)", off.routing, nil)
  eq("route-flag: nil queue tolerated", core.queueRouted(core.queueSetRouted(nil, false)), false)
  -- EVERY queue rebuild must carry the arm flag: a routed feed pops + writes
  -- the queue back, and dropping `routing` there would silently disarm the
  -- project on its first fed task. Same for add/move/remove/bulk on an armed
  -- queue. (Regression: queuePop originally rebuilt a bare {tasks} shape.)
  local _, popped = core.queuePop(on)
  eq("route-flag: pop preserves arm flag", core.queueRouted(popped), true)
  eq("route-flag: push preserves arm flag", core.queueRouted(core.queuePush(on, "z")), true)
  local moved = core.queueMove(on, 1, 1, "x")
  eq("route-flag: move preserves arm flag", core.queueRouted(moved), true)
  local removedQ = core.queueRemoveAt(on, 1, "x")
  eq("route-flag: remove preserves arm flag", core.queueRouted(removedQ), true)
  eq("route-flag: bulk add preserves arm flag", core.queueRouted(core.queuePushAll(on, { "n" })), true)
  -- queueMerge: the DESTINATION (project) queue's flag wins on adoption
  eq("route-flag: merge keeps destination arm", core.queueRouted(core.queueMerge(on, unarmed)), true)
  eq("route-flag: merge unarmed destination stays off", core.queueRouted(core.queueMerge(unarmed, on)), false)
  -- unarmed queues still serialize to the legacy plain shape
  local _, plainPop = core.queuePop(unarmed)
  eq("route-flag: unarmed pop has no routing key", plainPop.routing, nil)
  -- queueStarved
  local busy = { sess("a", "working") }
  eq("starve: armed+depth+nobody free past threshold",
     core.queueStarved(busy, armed, { minutes = 5, sinceTs = 100, now = 100 + 301 }), true)
  eq("starve: within threshold -> false",
     core.queueStarved(busy, armed, { minutes = 5, sinceTs = 100, now = 100 + 299 }), false)
  eq("starve: free member -> false",
     core.queueStarved(free, armed, { minutes = 5, sinceTs = 100, now = 999 }), false)
  eq("starve: minutes 0 -> never", core.queueStarved(busy, armed, { minutes = 0, sinceTs = 0, now = 999 }), false)
  eq("starve: unarmed -> false", core.queueStarved(busy, unarmed, { minutes = 5, sinceTs = 100, now = 999 }), false)
end

-- ---- Fleet-wide search (roadmap #3): argv builders + result parsing ---------
do
  -- ERE escaping: literal search, no metachar injection
  eq("fsearch: escape metas", core.escapeSearchPattern("a.b(c)*+?[x]{2}^$|\\"),
     "a\\.b\\(c\\)\\*\\+\\?\\[x\\]\\{2\\}\\^\\$\\|\\\\")
  eq("fsearch: plain word unchanged", core.escapeSearchPattern("auth_ts"), "auth_ts")
  -- rg argv shape
  local ra = core.searchArgv("rg", "auth.ts", { "/h/.claude/projects", "/h/.claude/cc-ledger" })
  eq("fsearch: rg argv", table.concat(ra, " "),
     "--no-config -i -n -o --no-heading --with-filename --max-count 3 --max-filesize 50M "
     .. "-g *.jsonl -e .{0,60}auth\\.ts.{0,60} /h/.claude/projects /h/.claude/cc-ledger")
  -- grep fallback shape (BSD-compatible flags)
  local ga = core.searchArgv("grep", "auth.ts", { "/h/.claude/projects" })
  eq("fsearch: grep argv", table.concat(ga, " "),
     "-r -I -i -n -o -H -E -m 3 --include=*.jsonl -e .{0,60}auth\\.ts.{0,60} /h/.claude/projects")
  -- too-short / blank queries refuse to build
  eq("fsearch: 2-char query -> nil", core.searchArgv("rg", "ab", { "/p" }), nil)
  eq("fsearch: whitespace query -> nil", core.searchArgv("rg", "  a  ", { "/p" }), nil)
  -- result parsing: first-two-colons split, colons in text survive
  local out = "/h/projects/ENC/sid-1.jsonl:12:cmd: npm test -- --watch\n"
    .. "/h/cc-ledger/2026-06-11.jsonl:3:decision allow\n"
    .. "garbage line without colons\n"
    .. "relative.jsonl:9:not absolute -> skipped\n"
  local res = core.parseSearchResults(out)
  eq("fsearch: parse hit count", #res.hits, 2)
  eq("fsearch: parse file", res.hits[1].file, "/h/projects/ENC/sid-1.jsonl")
  eq("fsearch: parse line number", res.hits[1].line, 12)
  eq("fsearch: colons in text survive", res.hits[1].text, "cmd: npm test -- --watch")
  eq("fsearch: not truncated", res.truncated, false)
  -- limit + truncated flag + maxLen backstop
  local many = ("/a/b.jsonl:1:" .. string.rep("x", 300) .. "\n"):rep(5)
  local r2 = core.parseSearchResults(many, { limit = 3, maxLen = 10 })
  eq("fsearch: limit caps hits", #r2.hits, 3)
  eq("fsearch: truncated flag", r2.truncated, true)
  eq("fsearch: maxLen truncates", r2.hits[1].text, string.rep("x", 10) .. "…")
  eq("fsearch: nil output -> empty", #core.parseSearchResults(nil).hits, 0)
  -- annotation: transcript vs ledger, projectKey/sessionId extraction, live mapping
  local hits = {
    { file = "/h/.claude/projects/-Users-a-proj/sid-123.jsonl", line = 1, text = "t" },
    { file = "/h/.claude/cc-ledger/2026-06-11.jsonl", line = 2, text = "l" },
    { file = "/h/.claude/projects/-Users-a-other/sid-999.jsonl", line = 3, text = "d" },
  }
  local items = { { key = "k1", name = "proj", label = "my proj",
                    transcript_path = "/h/.claude/projects/-Users-a-proj/sid-123.jsonl" } }
  core.annotateSearchHits(hits, items, "/h/.claude/cc-ledger")
  eq("fsearch: live hit kind", hits[1].kind, "transcript")
  eq("fsearch: live hit projectKey", hits[1].projectKey, "-Users-a-proj")
  eq("fsearch: live hit sessionId", hits[1].sessionId, "sid-123")
  eq("fsearch: live hit tile key", hits[1].key, "k1")
  eq("fsearch: live hit label wins", hits[1].name, "my proj")
  eq("fsearch: ledger hit kind", hits[2].kind, "ledger")
  eq("fsearch: ledger hit has no session", hits[2].sessionId, nil)
  eq("fsearch: dead hit kind", hits[3].kind, "transcript")
  eq("fsearch: dead hit sessionId", hits[3].sessionId, "sid-999")
  eq("fsearch: dead hit has no tile key", hits[3].key, nil)
end

-- ---- shouldAutoRespawn: fire once on the unexpected-death edge --------------
do
  local base = { wasStale = false, isStale = true, status = "working", hasSession = true,
                 intentional = false, attempts = 0, maxRetries = 3 }
  local function with(over)
    local a = {}; for k, v in pairs(base) do a[k] = v end
    for k, v in pairs(over or {}) do a[k] = v end
    return a
  end
  eq("respawn-auto: fires on fresh frozen-working edge", core.shouldAutoRespawn(with{}), true)
  -- Only a long-frozen `working` reads as dead: done/idle quiet is the NORMAL alive
  -- state between turns (no hooks fire after Stop, so every finished session goes
  -- stale ~90s later) -- respawning it would duplicate a live agent.
  eq("respawn-auto: stale done is alive-but-quiet -> no fire", core.shouldAutoRespawn(with{ status = "done" }), false)
  eq("respawn-auto: stale idle is alive-but-quiet -> no fire", core.shouldAutoRespawn(with{ status = "idle" }), false)
  -- A stale approval is waiting on a HUMAN (escalation expects multi-minute waits);
  -- respawning would destroy the tile the user was about to Approve on, and make
  -- the 5-minute stale-approval escalation unreachable. Escalation owns this case.
  eq("respawn-auto: stale approval waits on a human -> no fire", core.shouldAutoRespawn(with{ status = "approval" }), false)
  eq("respawn-auto: error is resumed via Continue, not respawned", core.shouldAutoRespawn(with{ status = "error" }), false)
  eq("respawn-auto: not on a still-stale tile", core.shouldAutoRespawn(with{ wasStale = true }), false)
  eq("respawn-auto: not when still healthy", core.shouldAutoRespawn(with{ isStale = false }), false)
  eq("respawn-auto: skips intentional close/drain", core.shouldAutoRespawn(with{ intentional = true }), false)
  eq("respawn-auto: skips orphan (no session_id)", core.shouldAutoRespawn(with{ hasSession = false }), false)
  eq("respawn-auto: disabled when maxRetries 0", core.shouldAutoRespawn(with{ maxRetries = 0 }), false)
  eq("respawn-auto: at cap -> stop", core.shouldAutoRespawn(with{ attempts = 3, maxRetries = 3 }), false)
  eq("respawn-auto: under cap -> go", core.shouldAutoRespawn(with{ attempts = 2, maxRetries = 3 }), true)
  eq("respawn-auto: nil args -> false", core.shouldAutoRespawn(nil), false)
end

-- ---- stepAutoRespawn: per-folder budget bookkeeping ------------------------
do
  local attempts = {}
  local function step(item, wasStale, now)
    return core.stepAutoRespawn(attempts, item,
      { enabled = true, maxRetries = 2, intentional = false, wasStale = wasStale,
        now = now or 1000, staleSeconds = 90, respawnStaleSeconds = 600 })
  end
  -- frozen at `working` for 700s (updated=300, now=1000) -- past the 600s respawn
  -- threshold, which is deliberately ABOVE the 90s display staleness (no hook fires
  -- mid-tool-call, so a healthy long build freezes the file for minutes).
  local function dead(key, sid) return { key = key, projectKey = "pf", status = "working",
    stale = true, updated = 300, session_id = sid } end

  local r1 = step(dead("k1", "s1"), false)
  eq("step: fires on the death edge", r1.spawn, true)
  eq("step: attempt counted", attempts["pf"], 1)
  eq("step: returns isStale", r1.isStale, true)

  eq("step: no re-fire while still stale", step(dead("k1", "s1"), true).spawn, false)
  eq("step: attempt unchanged when not firing", attempts["pf"], 1)

  eq("step: second death edge fires", step(dead("k2", "s2"), false).spawn, true)
  eq("step: attempt climbs to 2", attempts["pf"], 2)

  eq("step: at cap -> no fire", step(dead("k3", "s3"), false).spawn, false)
  eq("step: attempt holds at cap", attempts["pf"], 2)

  -- a healthy session resets the budget ONLY after SUSTAINED health: a freshly
  -- relaunched tile is non-stale by construction (SessionStart just wrote it), so
  -- a first-sight reset would wipe the budget ~90s before the relaunch could ever
  -- re-edge -- maxRetries would never bind and a crash loop respawns forever.
  local function healthy(since)
    return { key = "k4", projectKey = "pf", status = "working", stale = false, session_id = "s4", since = since }
  end
  step(healthy(1000), false, 1000)  -- just (re)spawned: 0s healthy
  eq("step: fresh healthy tile does NOT reset the budget", attempts["pf"], 2)
  step(healthy(1000), false, 1050)  -- 50s healthy: still inside the stale window
  eq("step: sub-window health does NOT reset", attempts["pf"], 2)
  step(healthy(1000), false, 1091)  -- survived a full stale window (> 90s)
  eq("step: sustained health resets the folder budget", attempts["pf"], nil)
  local r6 = step(dead("k5", "s5"), false)
  eq("step: fires again after recovery", r6.spawn, true)
  eq("step: budget climbs from zero again", attempts["pf"], 1)

  -- no clock/since provided -> fail closed: never reset the budget blindly
  local a8 = { pf = 2 }
  core.stepAutoRespawn(a8, healthy(nil), { enabled = true, maxRetries = 2, wasStale = false })
  eq("step: no clock/since -> fail-closed, budget kept", a8["pf"], 2)

  -- a stale done tile is alive-but-quiet (the normal between-turns state), not a
  -- death: no fire, no charge -- only a long-frozen `working` reads as dead.
  local a9 = {}
  local rq = core.stepAutoRespawn(a9,
    { key = "q", projectKey = "pf", status = "done", stale = true, updated = 300, session_id = "sq" },
    { enabled = true, maxRetries = 2, wasStale = false, now = 1000, staleSeconds = 90, respawnStaleSeconds = 600 })
  eq("step: stale done (alive between turns) -> no fire", rq.spawn, false)
  eq("step: stale done -> no charge", a9["pf"], nil)

  -- THE healthy-long-tool-call case (the bug this threshold exists for): a session
  -- 2 minutes into one Bash call is display-stale (90s) at status=working, but far
  -- under the 600s respawn threshold -- it is ALIVE and must NOT be duplicated.
  local a10 = {}
  local rl = core.stepAutoRespawn(a10,
    { key = "l", projectKey = "pf", status = "working", stale = true, updated = 880, session_id = "sl" },
    { enabled = true, maxRetries = 2, wasStale = false, now = 1000, staleSeconds = 90, respawnStaleSeconds = 600 })
  eq("step: healthy 2-min tool call (display-stale, under threshold) -> no fire", rl.spawn, false)
  eq("step: under-threshold working is not frozen", rl.isStale, false)
  eq("step: under-threshold -> no charge", a10["pf"], nil)

  -- ... and a pending approval frozen past even the RESPAWN threshold still never
  -- fires (waiting on a human; stale-approval escalation owns it).
  local a11 = {}
  eq("step: frozen approval -> escalation's case, no fire",
     core.stepAutoRespawn(a11,
       { key = "ap", projectKey = "pf", status = "approval", stale = true, updated = 300, session_id = "sa" },
       { enabled = true, maxRetries = 2, wasStale = false, now = 1000, staleSeconds = 90, respawnStaleSeconds = 600 }).spawn,
     false)
  eq("step: frozen approval -> no charge", a11["pf"], nil)

  -- no respawn threshold / clock / updated stamp -> fail closed (no death evidence)
  local a12 = {}
  eq("step: missing respawnStaleSeconds -> fail closed",
     core.stepAutoRespawn(a12, dead("m1", "s"), { enabled = true, maxRetries = 2, wasStale = false, now = 1000 }).spawn, false)
  eq("step: missing now -> fail closed",
     core.stepAutoRespawn(a12, dead("m2", "s"), { enabled = true, maxRetries = 2, wasStale = false, respawnStaleSeconds = 600 }).spawn, false)
  eq("step: missing updated -> fail closed",
     core.stepAutoRespawn(a12, { key = "m3", projectKey = "pf", status = "working", stale = true, session_id = "s" },
       { enabled = true, maxRetries = 2, wasStale = false, now = 1000, respawnStaleSeconds = 600 }).spawn, false)
  eq("step: fail-closed paths never charge", a12["pf"], nil)

  -- disabled never fires and never writes
  local a2 = {}
  eq("step: disabled -> no fire",
     core.stepAutoRespawn(a2, dead("x", "s"), { enabled = false, maxRetries = 2, wasStale = false,
       now = 1000, respawnStaleSeconds = 600 }).spawn, false)
  eq("step: disabled -> no write", a2["pf"], nil)

  -- a tile with no projectKey/cwd: no fire, NO nil-key write (the review's bug)
  local a3 = {}
  local rn = core.stepAutoRespawn(a3, { key = "y", status = "working", stale = true, updated = 300, session_id = "s" },
    { enabled = true, maxRetries = 2, wasStale = false, now = 1000, respawnStaleSeconds = 600 })
  eq("step: no projectKey -> no fire (guards the nil-key write)", rn.spawn, false)
  eq("step: still reports isStale without a key", rn.isStale, true)

  -- already frozen before the edge (wasStale=true, isStale=true): a level, not an
  -- edge -> no fire and no write, even with a fresh budget.
  local a4 = {}
  eq("step: already-frozen (level, not edge) -> no fire",
     core.stepAutoRespawn(a4, dead("z", "s"), { enabled = true, maxRetries = 2, wasStale = true,
       now = 1000, respawnStaleSeconds = 600 }).spawn, false)
  eq("step: already-frozen -> no write", a4["pf"], nil)

  -- a deliberate drain/close suppresses the fire even on a fresh death edge.
  local a5 = {}
  eq("step: intentional drain suppresses a fresh edge",
     core.stepAutoRespawn(a5, dead("d", "s"), { enabled = true, maxRetries = 2, intentional = true,
       wasStale = false, now = 1000, respawnStaleSeconds = 600 }).spawn, false)
  eq("step: intentional -> no write", a5["pf"], nil)

  -- a fresh death edge that isn't respawnable: wouldFire, but no spawn and NO charge
  -- (an un-respawnable death must not burn the per-folder budget).
  local a6 = {}
  local rc = core.stepAutoRespawn(a6, dead("c", "s"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, respawnStaleSeconds = 600, canRespawn = false })
  eq("step: un-respawnable edge does not spawn", rc.spawn, false)
  eq("step: un-respawnable edge still reports wouldFire", rc.wouldFire, true)
  eq("step: un-respawnable edge does NOT charge the budget", a6["pf"], nil)

  -- the POSITIVE bracket of the canRespawn gate: a fresh respawnable edge fires,
  -- spawns, and charges exactly one retry; a second one accumulates to two.
  local a7 = {}
  local rok = core.stepAutoRespawn(a7, dead("ok", "s"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, respawnStaleSeconds = 600, canRespawn = true })
  eq("step: fresh respawnable edge spawns", rok.spawn, true)
  eq("step: fresh respawnable edge wouldFire", rok.wouldFire, true)
  eq("step: fresh respawnable edge charges the budget", a7["pf"], 1)
  local rok2 = core.stepAutoRespawn(a7, dead("ok2", "s2"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, respawnStaleSeconds = 600, canRespawn = true })
  eq("step: second respawnable edge still spawns (under cap)", rok2.spawn, true)
  eq("step: second respawnable edge accumulates the budget", a7["pf"], 2)
  -- the cap firing: a third edge at maxRetries=2 is suppressed. The cap lives inside
  -- shouldAutoRespawn (attempts < cap), so a capped edge reports wouldFire=false and
  -- never over-charges. This brackets the accumulate->cap boundary.
  local rok3 = core.stepAutoRespawn(a7, dead("ok3", "s3"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, respawnStaleSeconds = 600, canRespawn = true })
  eq("step: respawnable edge suppressed once cap is reached", rok3.spawn, false)
  eq("step: capped edge reports wouldFire=false (cap is part of the gate)", rok3.wouldFire, false)
  eq("step: capped edge does NOT over-charge the budget", a7["pf"], 2)
end

-- ---- bucketEvents: time-series sparkline buckets ---------------------------
do
  local evs = {
    { ts = 100,  type = "prompt",       session_id = "a" },                              -- bucket 1
    { ts = 200,  type = "tool_request", session_id = "a" },                              -- bucket 1
    { ts = 3700, type = "prompt",       session_id = "b" },                              -- bucket 2
    { ts = 3800, type = "tool_request", session_id = "a" },                              -- bucket 2
    { ts = 3900, type = "decision", outcome = "deny",  by = "human", session_id = "a" }, -- bucket 2
    { ts = 7300, type = "decision", outcome = "allow", by = "human", session_id = "b" }, -- bucket 3
  }
  local act = core.bucketEvents(evs, 3600, "activity")
  eq("bucket: dense bucket count", #act, 3)
  eq("bucket: first ts aligned to bucket", act[1].ts, 0)
  eq("bucket: second ts aligned", act[2].ts, 3600)
  eq("bucket: activity b1 (prompt+tool)", act[1].value, 2)
  eq("bucket: activity b2 (prompt+tool)", act[2].value, 2)
  eq("bucket: activity b3 (none)", act[3].value, 0)

  local actv = core.bucketEvents(evs, 3600, "active")
  eq("bucket: active b1 distinct (driving) sessions", actv[1].value, 1)
  eq("bucket: active b2 distinct (driving) sessions", actv[2].value, 2)
  -- b3 has only a trailing decision for session b (no prompt/tool that hour) -> 0,
  -- matching `activity`'s event set (a decision-only session wasn't "running").
  eq("bucket: active b3 (decision-only -> not active)", actv[3].value, 0)

  local dr = core.bucketEvents(evs, 3600, "denialRate")
  eq("bucket: denialRate b1 (no decisions = 0)", dr[1].value, 0)
  eq("bucket: denialRate b2 (1 deny / 1)", dr[2].value, 1)
  eq("bucket: denialRate b3 (0 deny / 1)", dr[3].value, 0)

  local bl = core.bucketEvents(evs, 3600, "blocked")
  eq("bucket: blocked b1 (no wait)", bl[1].value, 0)
  eq("bucket: blocked b2 (req->human gap credited to wait start)", bl[2].value, 100)
  eq("bucket: blocked b3 (cleared, no credit)", bl[3].value, 0)

  eq("bucket: empty events -> {}", #core.bucketEvents({}, 3600, "activity"), 0)
  eq("bucket: unknown metric -> {}", #core.bucketEvents(evs, 3600, "bogus"), 0)
  eq("bucket: zero bucketSec defaults to 3600", #core.bucketEvents(evs, 0, "activity"), 3)
  eq("bucket: single event -> one bucket",
     #core.bucketEvents({ { ts = 500, type = "prompt", session_id = "x" } }, 3600, "activity"), 1)
  eq("bucket: blocked over-cap dropped", core.bucketEvents({
     { ts = 100, type = "tool_request" },
     { ts = 100 + 4000, type = "decision", by = "human", outcome = "allow" },
  }, 3600, "blocked", { maxBlock = 1800 })[1].value, 0)

  -- denialRate with a denominator > 1 (locks in deny / TOTAL-decisions, not deny/deny)
  eq("bucket: denialRate fractional (1 deny / 2 decisions)", core.bucketEvents({
     { ts = 100, type = "decision", outcome = "deny",  by = "human" },
     { ts = 200, type = "decision", outcome = "allow", by = "human" },
  }, 3600, "denialRate")[1].value, 0.5)

  -- a non-human/timeout decision RESOLVES the pending request without crediting it,
  -- so a later human decision can't be mis-paired with that already-cleared request.
  eq("bucket: blocked — non-human decision clears, no later mis-credit", core.bucketEvents({
     { ts = 100,  type = "tool_request" },
     { ts = 200,  type = "decision", by = "auto",  outcome = "allow" },
     { ts = 1000, type = "decision", by = "human", outcome = "allow" },
  }, 3600, "blocked")[1].value, 0)

  -- R2-001 (round-2 sweep): blocked pairs PER SESSION. The insights feed is fleet-wide,
  -- so two sessions waiting in the same hour must each pair its OWN request -> decision
  -- (a single pending slot would let B's request overwrite A's and lose both true gaps).
  local concurrent = {
    { ts = 100, type = "tool_request", session_id = "A" },
    { ts = 120, type = "tool_request", session_id = "B" },
    { ts = 160, type = "decision", by = "human", outcome = "allow", session_id = "A" },  -- A waited 60
    { ts = 200, type = "decision", by = "human", outcome = "allow", session_id = "B" },  -- B waited 80
  }
  local cb = core.bucketEvents(concurrent, 3600, "blocked", { maxBlock = 1800 })
  eq("bucket: blocked pairs per session (A 60 + B 80)", cb[1].value, 140)
  -- and the sparkline now AGREES with the per-session approvalBlockedSeconds headline
  eq("bucket: blocked sparkline agrees with the fleetStats headline",
     cb[1].value, core.fleetStats(concurrent, { maxBlock = 1800 }).approvalBlockedSeconds)

  -- R2-001 follow-up A: a pending request that NEVER resolves must not steal another
  -- session's decision. A's request (150) is the most recent before B's decision, so a
  -- single shared slot would pair B's decision with A's request (gap 50); per-session
  -- pairing credits B's OWN request (gap 100). The concurrent fixture above can't catch
  -- this -- both sessions resolve cleanly there, so the wrong pairing still sums to 140.
  local dangling = {
    { ts = 100, type = "tool_request", session_id = "B" },
    { ts = 150, type = "tool_request", session_id = "A" },  -- A pending, never resolves
    { ts = 200, type = "decision", by = "human", outcome = "allow", session_id = "B" },  -- B waited 100
  }
  local db = core.bucketEvents(dangling, 3600, "blocked", { maxBlock = 1800 })
  eq("bucket: B's decision pairs B's request, not A's dangling one", db[1].value, 100)
  eq("bucket: dangling case agrees with the fleetStats headline",
     db[1].value, core.fleetStats(dangling, { maxBlock = 1800 }).approvalBlockedSeconds)

  -- R2-001 follow-up B: each gap is credited to the bucket where ITS OWN wait STARTED
  -- (idx(req)), not the decision's bucket and not another session's. A's wait crosses the
  -- bucket boundary (req in b1, decision in b2) so this also pins start-bucket crediting.
  -- The concurrent fixture collapses everything into bucket 1, so it can't test placement.
  -- (Old single-slot code would yield b1=0, b2=50 here.)
  local split = {
    { ts = 1700, type = "tool_request", session_id = "A" },                              -- b1
    { ts = 1850, type = "tool_request", session_id = "B" },                              -- b2
    { ts = 1900, type = "decision", by = "human", outcome = "allow", session_id = "A" }, -- A waited 200, started b1
    { ts = 2000, type = "decision", by = "human", outcome = "allow", session_id = "B" }, -- B waited 150, started b2
  }
  local sb = core.bucketEvents(split, 1800, "blocked", { maxBlock = 1800 })
  eq("bucket: A's gap credited to its OWN start bucket b1", sb[1].value, 200)
  eq("bucket: B's gap credited to its OWN start bucket b2", sb[2].value, 150)
  eq("bucket: split blocked buckets sum to the fleetStats headline",
     sb[1].value + sb[2].value, core.fleetStats(split, { maxBlock = 1800 }).approvalBlockedSeconds)
end

-- ---- isHung: stalled `working` session watchdog ----------------------------
do
  local now = 10000
  local working = { status = "working" }
  eq("hung: working + stalled past threshold", core.isHung(working, now - 400, now, 300), true)
  eq("hung: working + recent progress", core.isHung(working, now - 100, now, 300), false)
  eq("hung: exactly at threshold not yet hung", core.isHung(working, now - 300, now, 300), false)
  eq("hung: not working (idle) -> false", core.isHung({ status = "idle" }, now - 400, now, 300), false)
  eq("hung: not working (approval) -> false", core.isHung({ status = "approval" }, now - 400, now, 300), false)
  eq("hung: stale tile -> false", core.isHung({ status = "working", stale = true }, now - 400, now, 300), false)
  eq("hung: no progress timestamp yet -> false", core.isHung(working, nil, now, 300), false)
  -- post-reset / never-seeded: watchdog[key] is nil so the dashboard passes ts=nil;
  -- the status/stale + nil-ts guards must keep this harmless (no spurious hung).
  eq("hung: nil ts post-reset (working, not stale) -> false",
     core.isHung({ status = "working", stale = false }, nil, now, 300), false)
  eq("hung: nil item -> false", core.isHung(nil, now - 400, now, 300), false)
end

-- ---- trackProgress + watchdogShouldReset: the watchdog state machine --------
do
  local r1 = core.trackProgress(nil, nil, 100, 1000)
  eq("track: first sight seeds size", r1.size, 100)
  eq("track: first sight seeds ts=now", r1.ts, 1000)
  local r2 = core.trackProgress(100, 1000, 250, 2000)
  eq("track: growth updates size", r2.size, 250)
  eq("track: growth rebases ts", r2.ts, 2000)
  local r3 = core.trackProgress(250, 2000, 250, 3000)
  eq("track: unchanged holds size", r3.size, 250)
  eq("track: unchanged keeps timing (ts held)", r3.ts, 2000)
  local r4 = core.trackProgress(250, 2000, 40, 4000)
  eq("track: shrink (rotation) resets size", r4.size, 40)
  eq("track: shrink rebases ts (no false stall)", r4.ts, 4000)
  local r5 = core.trackProgress(40, 4000, nil, 5000)
  eq("track: nil size holds size", r5.size, 40)
  eq("track: nil size holds ts", r5.ts, 4000)

  eq("watchdog-reset: idle -> reset", core.watchdogShouldReset("idle", false), true)
  eq("watchdog-reset: done -> reset", core.watchdogShouldReset("done", false), true)
  eq("watchdog-reset: working + stale -> reset (no resume false-trip)", core.watchdogShouldReset("working", true), true)
  eq("watchdog-reset: working + healthy -> keep timing", core.watchdogShouldReset("working", false), false)

  -- applyProgress: merges trackProgress onto a watchdog entry. F-006: progress (a
  -- size change that rebases the timer) RE-ARMS the alert ("once per stall"); a held
  -- tick KEEPS alerted so a continuous stall isn't re-nagged every second.
  local wp = { size = 10, ts = 1000, alerted = true }
  local rp = core.applyProgress(wp, 50, 2000)
  eq("applyProgress: growth updates size", rp.size, 50)
  eq("applyProgress: growth rebases ts", rp.ts, 2000)
  eq("applyProgress: growth CLEARS alerted (re-arm for the next stall)", rp.alerted, nil)
  check("applyProgress: mutates-and-returns the same entry", rp == wp)
  local wp2 = { size = 50, ts = 2000, alerted = true }
  local rp2 = core.applyProgress(wp2, 50, 3000)
  eq("applyProgress: unchanged holds ts", rp2.ts, 2000)
  eq("applyProgress: unchanged KEEPS alerted (no re-nag mid-stall)", rp2.alerted, true)
  local wp3 = { size = 50, ts = 2000, alerted = true }
  eq("applyProgress: shrink (rotation) also clears alerted", core.applyProgress(wp3, 10, 5000).alerted, nil)
  local rp3 = core.applyProgress(nil, 100, 4000)
  eq("applyProgress: nil entry seeds size", rp3.size, 100)
  eq("applyProgress: nil entry seeds ts", rp3.ts, 4000)
  check("applyProgress: nil entry has no alerted", rp3.alerted == nil)
end

-- ---- watchdog re-alert across a resume (F-006 integration) -----------------
-- Replay the dashboard's watchdog state machine: a session that stays `working`,
-- stalls -> alerts, resumes (progress), then stalls again must RE-ALERT.
do
  local watchdog, it, T = {}, { status = "working", stale = false }, 60
  local fires = {}
  local function tick(now, size)
    watchdog.k = core.applyProgress(watchdog.k, size, now)
    local w = watchdog.k
    local fired = false
    if core.isHung(it, w and w.ts, now, T) and w and not w.alerted then
      w.alerted = true; fired = true
    end
    if core.watchdogShouldReset(it.status, it.stale) then watchdog.k = nil end
    fires[#fires + 1] = fired
  end
  tick(0, 100)    -- seed
  tick(70, 100)   -- stall #1 -> alert
  tick(80, 200)   -- resume (progress) -> re-arm
  tick(160, 200)  -- stall #2 -> must re-alert
  eq("watchdog: seed tick does not fire", fires[1], false)
  eq("watchdog: first stall fires", fires[2], true)
  eq("watchdog: resume tick does not fire", fires[3], false)
  eq("watchdog: SECOND stall re-fires after a resume", fires[4], true)
end

-- ---- editorBundleIds: the editor kind scopes the app lookup (R2 #5) --------
do
  local fallback = { "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                     "com.todesktop.230313mzl4w4u92" }
  -- a cursor session must NEVER search VS Code's windows (and vice versa):
  -- with both editors running, the fixed-order walk matched VS Code first and
  -- either injected keys into the wrong app or skipped a matchable window.
  local cur = core.editorBundleIds("cursor", fallback)
  eq("editor-app: cursor -> exactly one bundle", #cur, 1)
  eq("editor-app: cursor -> Cursor's bundle id", cur[1], "com.todesktop.230313mzl4w4u92")
  local vs = core.editorBundleIds("vscode", fallback)
  eq("editor-app: vscode -> VS Code first", vs[1], "com.microsoft.VSCode")
  eq("editor-app: vscode -> Insiders second", vs[2], "com.microsoft.VSCodeInsiders")
  local vsHasCursor = false
  for _, bid in ipairs(vs) do if bid == "com.todesktop.230313mzl4w4u92" then vsHasCursor = true end end
  check("editor-app: vscode never includes Cursor", vsHasCursor == false)
  eq("editor-app: terminal -> Terminal.app", core.editorBundleIds("terminal", fallback)[1], "com.apple.Terminal")
  -- only a nil/unknown editor keeps the legacy full walk
  eq("editor-app: nil editor -> legacy fallback walk", core.editorBundleIds(nil, fallback), fallback)
  eq("editor-app: unknown editor -> legacy fallback walk", core.editorBundleIds("emacs", fallback), fallback)
  eq("editor-app: no fallback -> empty list", #core.editorBundleIds("emacs"), 0)
end

-- ---- staggerSlot: shared injection tail serializes across dispatches (R2 #7) --
do
  -- one bulk dispatch: 3 window targets at now=1000, gap 1.5 -> t=0, 1.5, 3.0
  local tail, d1, d2, d3 = 0
  d1, tail = core.staggerSlot(tail, 1000, 1.5)
  d2, tail = core.staggerSlot(tail, 1000, 1.5)
  d3, tail = core.staggerSlot(tail, 1000, 1.5)
  eq("stagger: 1st chain immediate", d1, 0)
  eq("stagger: 2nd chain +1.5", d2, 1.5)
  eq("stagger: 3rd chain +3.0", d3, 3.0)
  eq("stagger: tail after 3 chains", tail, 1004.5)
  -- a SECOND dispatch 1s later (the second bulk click / a per-tile action in
  -- the stagger window) queues AFTER the in-flight chains, never at t=0
  local d4
  d4, tail = core.staggerSlot(tail, 1001, 1.5)
  eq("stagger: 2nd dispatch queues after the in-flight tail", d4, 3.5)
  eq("stagger: tail advances past the 2nd dispatch", tail, 1006)
  -- idle (tail in the past) -> immediate again, tail rebased on now
  local d5, t5 = core.staggerSlot(1004.5, 2000, 1.5)
  eq("stagger: idle tail -> immediate", d5, 0)
  eq("stagger: idle tail rebases on now", t5, 2001.5)
  -- garbage state is safe
  local d6, t6 = core.staggerSlot(nil, 100, 1.5)
  eq("stagger: nil tail -> immediate", d6, 0)
  eq("stagger: nil tail still reserves a slot", t6, 101.5)
end

-- ---- purge: exact-filter split + scoped-confirmation decision (R2 #8) -------
do
  local evs = {
    { id = "1", ts = 100, session_id = "sX", type = "decision" },
    { id = "2", ts = 110, session_id = "sX", type = "prompt" },
    { id = "3", ts = 120, session_id = "sY", type = "decision" },
    { id = "4", ts = 130, session_id = "sX", type = "decision" },
  }
  -- session AND types: only sX's decisions purge; sX's prompt and sY's decision
  -- survive (the old purge matched on session alone -- an irreversible superset).
  local kept, purged = core.splitLedgerEvents(evs, { session = "sX", types = { "decision" } })
  eq("purge-split: purges ONLY sX decisions", #purged, 2)
  eq("purge-split: keeps sX prompt + sY decision", #kept, 2)
  check("purge-split: purged the right ids", purged[1].id == "1" and purged[2].id == "4")
  check("purge-split: kept the sX prompt", kept[1].id == "2")
  check("purge-split: kept the other session's decision", kept[2].id == "3")
  -- type-only filter purges just that type across sessions
  local k2, p2 = core.splitLedgerEvents(evs, { types = { "prompt" } })
  eq("purge-split: type-only purges just that type", #p2, 1)
  eq("purge-split: type-only keeps the rest", #k2, 3)
  -- the day window composes with session + type
  local _, p3 = core.splitLedgerEvents(evs, { session = "sX", types = { "decision" }, sinceTs = 105 })
  eq("purge-split: window AND session AND type", #p3, 1)
  eq("purge-split: windowed purge hits the right event", p3[1].id, "4")
  -- empty filter matches everything (the f.all path removes whole files upstream)
  local _, pAll = core.splitLedgerEvents(evs, {})
  eq("purge-split: empty filter matches all", #pAll, 4)

  -- the confirmation-scope decision: `types` counts as a filter, so a type-only
  -- purge must NOT escalate to f.all (= delete every ledger file).
  check("purge-scope: types alone is scoped", core.purgeFilterIsScoped({ types = { "prompt" } }) == true)
  check("purge-scope: session is scoped", core.purgeFilterIsScoped({ session = "sX" }) == true)
  check("purge-scope: sinceTs is scoped", core.purgeFilterIsScoped({ sinceTs = 1 }) == true)
  check("purge-scope: untilTs is scoped", core.purgeFilterIsScoped({ untilTs = 1 }) == true)
  check("purge-scope: empty filter -> ALL", core.purgeFilterIsScoped({}) == false)
  check("purge-scope: empty types list -> ALL", core.purgeFilterIsScoped({ types = {} }) == false)
  check("purge-scope: non-table safe", core.purgeFilterIsScoped(nil) == false)
end

-- ---- capLedgerSlice: webview cap, bypassable for export (R2 #9) -------------
do
  local evs = {}
  for i = 1, 2101 do evs[i] = { id = i } end
  local sliced, trunc = core.capLedgerSlice(evs, nil)
  eq("ledger-cap: default caps at 2000", #sliced, 2000)
  eq("ledger-cap: default cap flags truncation", trunc, true)
  -- limit 0 = NO cap: the export/audit-review full-data paths
  local all, t2 = core.capLedgerSlice(evs, 0)
  eq("ledger-cap: limit 0 bypasses the cap (export)", #all, 2101)
  eq("ledger-cap: bypass is not truncated", t2, false)
  local five, t3 = core.capLedgerSlice(evs, 5)
  eq("ledger-cap: explicit limit honored", #five, 5)
  eq("ledger-cap: explicit limit flags truncation", t3, true)
  local small, t4 = core.capLedgerSlice({ { id = 1 } }, 5)
  eq("ledger-cap: under the cap untouched", #small, 1)
  eq("ledger-cap: under the cap not truncated", t4, false)
end

-- ---- ledgerCacheStale: risk read cached off the 1 Hz refresh (R2 #10) -------
do
  check("risk-cache: empty cache is stale", core.ledgerCacheStale({}, "sig", 100, 30) == true)
  check("risk-cache: nil cache is stale", core.ledgerCacheStale(nil, "sig", 100, 30) == true)
  local cache = { events = {}, sig = "a.jsonl:10:99", ts = 100 }
  check("risk-cache: same sig, fresh -> serve cached",
        core.ledgerCacheStale(cache, "a.jsonl:10:99", 101, 30) == false)
  check("risk-cache: 1 Hz ticks stay cached until the TTL",
        core.ledgerCacheStale(cache, "a.jsonl:10:99", 129, 30) == false)
  check("risk-cache: sig change (hook append / new day) -> re-read",
        core.ledgerCacheStale(cache, "a.jsonl:11:99", 101, 30) == true)
  check("risk-cache: TTL backstop expired -> re-read",
        core.ledgerCacheStale(cache, "a.jsonl:10:99", 130, 30) == true)
  check("risk-cache: default TTL is 30s", core.ledgerCacheStale(cache, "a.jsonl:10:99", 130) == true)
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
