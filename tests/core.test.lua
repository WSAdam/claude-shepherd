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
  -- L5: the banner toggles made `notifications` form-managed; its hand-edited
  -- `days` (no UI input) must survive a Save (review-caught regression).
  local nOut = core.overlayConfig(
    { notifications = { days = 30, banner = { onApproval = false } } },
    { notifications = { banner = { onApproval = true, onDone = false } } })
  eq("overlay: notifications.days carried forward", nOut.notifications.days, 30)
  eq("overlay: notifications.banner form field wins", nOut.notifications.banner.onApproval, true)
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
  -- #6: hand-edited insights.hostPressure thresholds survive a Save (form sends only
  -- maxBlockSeconds + hostStats), like escalation.hung / risk.weights.
  local iOut = core.overlayConfig(
    { insights = { hostPressure = { cpu = 80, disk = 95 } } },
    { insights = { maxBlockSeconds = 1800, hostStats = true } })
  eq("overlay: insights.hostPressure.cpu carried forward", iOut.insights.hostPressure.cpu, 80)
  eq("overlay: insights.hostPressure.disk carried forward", iOut.insights.hostPressure.disk, 95)
  eq("overlay: insights.hostStats taken from the form", iOut.insights.hostStats, true)
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
  -- R2-17: status is clamped to the known set at the parse chokepoint so a hostile
  -- (e.g. rsync-mirrored from a compromised host) value can't reach the panel's
  -- innerHTML sink raw. Unknown -> "idle". Every known status passes through.
  local xss = core.parseStatusList(
    { entry("h", { name = "evil", status = '<img src=x onerror=alert(1)>', updated = now }) }, now, 90)
  eq("R2-17: hostile status clamped to idle", xss[1].status, "idle")
  for _, s in ipairs({ "idle", "working", "approval", "done", "error" }) do
    local kept = core.parseStatusList({ entry("k", { name = "n", status = s, updated = now }) }, now, 90)
    eq("R2-17: known status '" .. s .. "' preserved", kept[1].status, s)
  end
end

-- ---- R1-01/R1-02: non-numeric updated/since must not crash the refresh tick --
do
  local now = 10000
  -- A hand-edited / foreign / rsync-mirrored status file with non-numeric time
  -- fields must parse without throwing (arithmetic is outside the decode pcall).
  local okBool = pcall(function()
    return core.parseStatusList({ entry("y", { name = "y", status = "working", updated = true }) }, now, 90)
  end)
  check("parse: boolean updated does not throw", okBool)
  local okStr = pcall(function()
    return core.parseStatusList({ entry("z", { name = "z", status = "working", updated = "not-a-number" }) }, now, 90)
  end)
  check("parse: non-numeric string updated does not throw", okStr)

  local lst = core.parseStatusList({
    entry("a", { name = "a", status = "working", updated = "soon", since = "oops" }),
    entry("b", { name = "b", status = "approval", since = true, updated = now }),
  }, now, 90)
  local a, b
  for _, it in ipairs(lst) do
    if it.name == "a" then a = it end
    if it.name == "b" then b = it end
  end
  eq("parse: garbage updated -> stale false", a.stale, false)
  eq("parse: garbage updated -> coerced to nil", a.updated, nil)
  eq("parse: garbage since -> coerced to nil", a.since, nil)
  eq("parse: garbage since on approval -> coerced to nil", b.since, nil)
  -- the parsed items must flow through the downstream raw-arithmetic consumers
  -- without throwing, returning fail-closed values.
  local okA = pcall(function() return core.approvalStale(b, now, 5) end)
  check("approvalStale: garbage since does not throw", okA)
  eq("approvalStale: garbage since -> false", core.approvalStale(b, now, 5), false)
  eq("shouldPrune: garbage updated -> no ghost", core.shouldPrune(a, now, { pruneSeconds = 10 }), false)
  -- raw (un-parsed) consumers are hardened too
  eq("approvalStale: raw string since -> false",
     core.approvalStale({ status = "approval", since = "oops" }, 5000, 300), false)
  eq("approvalStale: raw boolean since -> false",
     core.approvalStale({ status = "approval", since = true }, 5000, 300), false)
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

-- ---- #9-pin: Stream Deck styling covers the error state ---------------------
-- A frozen-on-API-error session ranks just below approvals (RANK.error) and the
-- panel styles it distinctly (.s-error magenta) -- but SD_COLORS/SD_LABELS had no
-- `error` entry, so sdButtonImage's `or SD_COLORS.idle` fallback painted the
-- needs-attention key the same gray-blue as an idle session.
do
  check("#9-pin: SD_COLORS has an error entry", type(core.SD_COLORS.error) == "table")
  check("#9-pin: error key color is NOT the idle fallback",
        core.SD_COLORS.error ~= core.SD_COLORS.idle
        and (core.SD_COLORS.error.red ~= core.SD_COLORS.idle.red
             or core.SD_COLORS.error.green ~= core.SD_COLORS.idle.green
             or core.SD_COLORS.error.blue ~= core.SD_COLORS.idle.blue))
  eq("#9-pin: SD_LABELS names the error state", core.SD_LABELS.error, "ERROR")
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

  -- Delivery gating: pasteIntoWindow/sendKeys report delivery, and the contract
  -- is STRICTLY == false ("positively not delivered" -- the no-window-match
  -- skip). false -> handleAction returns nil + logs, so the dashboard never
  -- ledgers an undelivered nudge / re-bases an unset mode; nil (fakes and
  -- effect paths that return nothing) MUST stay on the success path.
  r = newRecorder()
  r._pasteResult = false
  eq("nudge: skipped paste (false) -> nil", core.handleAction(r.fx, normal, "nudge", "hi"), nil)
  eq("nudge: skipped paste logs 'not delivered'", "yes",
     (r.last().op == "log" and r.last().a:find("not delivered", 1, true)) and "yes" or "no")
  r = newRecorder()  -- positive control: nil delivery report = success
  eq("nudge: nil delivery report -> success", core.handleAction(r.fx, normal, "nudge", "hi"), "nudge")
  local modal = { key = "m1", name = "proj-m", permission_mode = "default" }
  r = newRecorder()
  r._sendKeysResult = false
  eq("set-mode: skipped keys (false) -> nil (mode NOT re-based)",
     core.handleAction(r.fx, modal, "set-mode", "plan"), nil)
  eq("set-mode: skipped keys log 'NOT re-based'", "yes",
     (r.last().op == "log" and r.last().a:find("NOT re-based", 1, true)) and "yes" or "no")
  r = newRecorder()
  eq("set-mode: nil delivery report -> success", core.handleAction(r.fx, modal, "set-mode", "plan"), "set-mode")

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
  eq("continue: returns continue when delivered", core.handleAction(r.fx, normal, "continue"), "continue")
  eq("continue: typeIntoWindow op", r.last().op, "typeIntoWindow")
  eq("continue: types the word continue", r.last().b, "continue")
  -- L6: continue is delivery-gated — a no-window-match skip returns nil (accurate outcome)
  local rskip = newRecorder(); rskip._typeResult = false
  eq("continue: skip on no-window-match -> nil", core.handleAction(rskip.fx, normal, "continue"), nil)

  -- R1-06: model/effort are delivery-gated too (typeIntoWindow false -> nil), so the
  -- dashboard can ledger model_skipped/effort_skipped instead of a false change.
  local rmskip = newRecorder(); rmskip._typeResult = false
  eq("model: skip on no-window-match -> nil",
     core.handleAction(rmskip.fx, normal, "model", "claude-opus-4-8"), nil)
  local reskip = newRecorder(); reskip._typeResult = false
  eq("effort: skip on no-window-match -> nil",
     core.handleAction(reskip.fx, normal, "effort", "high"), nil)
  -- positive control: a delivered model switch still returns "model"
  r = newRecorder()
  eq("model: delivered -> model", core.handleAction(r.fx, normal, "model", "claude-opus-4-8"), "model")

  -- R2-16: a SINGLE single-select question on kitty drives the picker via answerKeys.
  local askSingle = { key = "as1", name = "ask1", editor = "kitty",
                      pending = { ask = { { question = "Q1", multiSelect = false } } } }
  r = newRecorder()
  eq("answer: single-question kitty -> answer (sendKeys)",
     core.handleAction(r.fx, askSingle, "answer", "1"), "answer")
  eq("answer: single-question uses sendKeys", r.last().op, "sendKeys")
  -- A MULTI-QUESTION ask must JUMP (focusWindow), never drive the wrong picker --
  -- answerAsk sends only the option index, not the question index.
  eq("askIsMultiQuestion: 2 questions -> true",
     core.askIsMultiQuestion({ pending = { ask = { { question = "Q1" }, { question = "Q2" } } } }), true)
  eq("askIsMultiQuestion: 1 question -> false",
     core.askIsMultiQuestion({ pending = { ask = { { question = "Q1" } } } }), false)
  local askMultiQ = { key = "aq1", name = "ask2", editor = "kitty",
                      pending = { ask = { { question = "Q1", multiSelect = false },
                                          { question = "Q2", multiSelect = false } } } }
  r = newRecorder()
  eq("answer: multi-question kitty -> answer (jumps)",
     core.handleAction(r.fx, askMultiQ, "answer", "1"), "answer")
  eq("answer: multi-question jumps (focusWindow, NOT sendKeys)", r.last().op, "focusWindow")
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

  -- reserved action keys: sessions skip those indices, overflow counts non-reserved slots
  local reserved = { [1] = true, [2] = true }  -- first two keys are actions
  local lay3 = core.deckLayout(4, list, reserved)
  eq("deck: reserved key 1 holds no session", lay3.items[1], nil)
  eq("deck: reserved key 2 holds no session", lay3.items[2], nil)
  eq("deck: first session lands on the first FREE key", lay3.items[3].key, "a")
  eq("deck: second session on the next free key", lay3.items[4].key, "b")
  eq("deck: overflow counts only non-reserved slots", lay3.overflow, 1)  -- 3 sessions, 2 free slots
end

-- ---- deckActionKeys: the bottom-left action row from deck geometry ----------
do
  eq("deckActionKeys: XL 8x4 bottom-left 4 -> {25,26,27,28}",
     table.concat(core.deckActionKeys(8, 4, 4), ","), "25,26,27,28")
  eq("deckActionKeys: standard 5x3 -> {11,12,13,14}",
     table.concat(core.deckActionKeys(5, 3, 4), ","), "11,12,13,14")
  eq("deckActionKeys: clamps n to the column count",
     table.concat(core.deckActionKeys(3, 2, 4), ","), "4,5,6")  -- only 3 cols
  eq("deckActionKeys: degenerate geometry -> none", #core.deckActionKeys(0, 0, 4), 0)
end

-- ---- deckReservations: action-row + bottom-right tail, with free-slot guard ----
do
  local ORDER = { "jump", "approve", "spawn", "voice" }
  local TAIL  = { "caffeine", "apptab" }
  -- XL 8x4: left row 25-28, caffeine on the corner (32), apptab just left of it (31). 6 actions.
  local r = core.deckReservations(8, 4, 32, ORDER, TAIL)
  eq("deckReservations: XL left row jump@25", r.actionByKey[25], "jump")
  eq("deckReservations: XL left row voice@28", r.actionByKey[28], "voice")
  eq("deckReservations: XL caffeine on corner (count)", r.actionByKey[32], "caffeine")
  eq("deckReservations: XL apptab just left of caffeine (count-1)", r.actionByKey[31], "apptab")
  eq("deckReservations: XL apptab slot reserved", r.reserved[31], true)
  eq("deckReservations: XL session key 29 left free", r.reserved[29], nil)
  eq("deckReservations: XL total action count", r.actionCount, 6)
  -- Small deck where the left row reaches the right edge: caffeine + apptab slots are already
  -- taken, so BOTH skip rather than clobbering a row action. This is the new guard's skip branch.
  -- 4x2: count=8, deckActionKeys(4,2,4)={5,6,7,8}. caffeine wants 8 (taken), apptab wants 7 (taken).
  local s = core.deckReservations(4, 2, 8, ORDER, TAIL)
  eq("deckReservations: tight deck keeps voice@8 (caffeine skipped)", s.actionByKey[8], "voice")
  eq("deckReservations: tight deck keeps spawn@7 (apptab skipped)", s.actionByKey[7], "spawn")
  eq("deckReservations: tight deck only the 4 row actions", s.actionCount, 4)
  -- apptab-specific branch: same geometry, but pretend only the apptab slot (count-1) is free.
  -- 5x3: count=15, left row {11,12,13,14}. caffeine@15 free -> assigned; apptab@14 TAKEN -> skip.
  local m = core.deckReservations(5, 3, 15, ORDER, TAIL)
  eq("deckReservations: 5x3 caffeine assigned@15", m.actionByKey[15], "caffeine")
  eq("deckReservations: 5x3 apptab skipped (14 is voice)", m.actionByKey[14], "voice")
  eq("deckReservations: 5x3 count = 4 row + caffeine", m.actionCount, 5)
  -- Decks below 4x2 host no action keys at all.
  local tiny = core.deckReservations(3, 2, 6, ORDER, TAIL)
  eq("deckReservations: sub-4-col deck -> no actions", tiny.actionCount, 0)
  eq("deckReservations: sub-4-col deck -> nothing reserved", next(tiny.reserved), nil)
end

-- ---- sessionForTitle: reverse window->session match (deck Voice routing) ----
do
  local list = {
    { key = "a", name = "autobottom",  cwd = "/Users/adam/Programming/autobottom" },
    { key = "b", name = "qb-interface", cwd = "/Users/adam/Programming/qb-interface" },
  }
  local hit = core.sessionForTitle(list, "main.ts — autobottom", "adam")  -- editor title: file — folder
  eq("sessionForTitle: matches the project in the window title", hit and hit.key, "a")
  eq("sessionForTitle: empty title -> nil", core.sessionForTitle(list, "", "adam"), nil)
  eq("sessionForTitle: no match -> nil", core.sessionForTitle(list, "Slack | general", "adam"), nil)
  -- tie-break: when two sessions both appear in the title, the exact folder segment (rank 2)
  -- must win over a bare substring (rank 1) -- NOT first-found. "qb" contains-matches the
  -- "qb-interface" segment, but "qb-interface" IS the segment, so it wins.
  local amb = {
    { key = "x", name = "qb" },
    { key = "y", name = "qb-interface" },
  }
  eq("sessionForTitle: exact segment beats substring",
     (core.sessionForTitle(amb, "index.ts — qb-interface", "adam") or {}).key, "y")
  -- order-independent: same result with the higher-rank session listed first
  local ambRev = {
    { key = "y", name = "qb-interface" },
    { key = "x", name = "qb" },
  }
  eq("sessionForTitle: exact segment wins regardless of list order",
     (core.sessionForTitle(ambRev, "index.ts — qb-interface", "adam") or {}).key, "y")
  -- when only the plain 'qb' is a real segment ('qb-interface' doesn't appear), it's chosen
  eq("sessionForTitle: substring session chosen when it's the only match",
     (core.sessionForTitle(amb, "notes — qb", "adam") or {}).key, "x")
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
  -- a genuine human-typed prompt after the error (the operator typed "continue")
  local humanline = core.json.encode({ type = "user", message = { role = "user",
    content = { { type = "text", text = "continue" } } } })
  -- an IDE-injected / tool-result-only user line (NOT real activity)
  local injectline = core.json.encode({ type = "user", isMeta = true, message = { role = "user",
    content = { { type = "tool_result", tool_use_id = "x", content = "ok" } } } })

  -- latest significant line is an api_error -> stuck; return its formatted message
  local stuck = aline("working on it") .. "\n" .. errline("Unable to connect to API (ECONNRESET)")
  local e = core.transcriptError(stuck)
  check("error: detects api_error as the latest event", e ~= nil)
  eq("error: returns the formatted message", e and e.message, "Unable to connect to API (ECONNRESET)")

  -- an assistant line AFTER the error -> recovered, not stuck
  eq("error: assistant after error -> nil",
     core.transcriptError(errline("boom") .. "\n" .. aline("recovered")), nil)
  -- R3-04: a GENUINE human-typed prompt after the error (user typed continue) -> nil
  eq("error: genuine human prompt after error -> nil",
     core.transcriptError(errline("boom") .. "\n" .. humanline), nil)
  -- R3-04: an IDE-injected / tool-result / empty user line is NOT recovery -> still errored
  check("error: bare user line after error is NOT recovery",
     core.transcriptError(errline("boom") .. "\n" .. userline) ~= nil)
  check("error: IDE-injected meta user line after error is NOT recovery",
     core.transcriptError(errline("boom") .. "\n" .. injectline) ~= nil)
  -- no api_error at all -> nil
  eq("error: clean transcript -> nil", core.transcriptError(aline("all good")), nil)
  -- empty / garbled input is safe
  eq("error: empty input -> nil", core.transcriptError(""), nil)
  eq("error: garbled line skipped, still finds the error",
     (core.transcriptError("{ not json\n" .. errline("late boom")) or {}).message, "late boom")
  -- falls back to error.message when there is no formatted field
  local nofmt = core.json.encode({ type = "system", subtype = "api_error", error = { message = "Overloaded" } })
  eq("error: falls back to error.message", (core.transcriptError(nofmt) or {}).message, "Overloaded")
  -- L5 error-reason taxonomy: transcriptError carries a .reason; classifyError maps causes
  eq("error: carries a reason", (core.transcriptError(stuck) or {}).reason, "runtime_error")
  eq("error: overloaded -> model_error", (core.transcriptError(nofmt) or {}).reason, "model_error")
  eq("classify: usage limit -> budget", core.classifyError("You have hit your usage limit"), "budget_exceeded")
  eq("classify: 429 -> budget", core.classifyError("HTTP 429 Too Many Requests"), "budget_exceeded")
  eq("classify: timed out -> timeout", core.classifyError("request timed out after 60s"), "timeout")
  eq("classify: ECONNRESET -> runtime", core.classifyError("read ECONNRESET"), "runtime_error")
  eq("classify: overloaded -> model", core.classifyError("Error: Overloaded (529)"), "model_error")
  eq("classify: cancelled -> user", core.classifyError("Request was cancelled"), "user_cancelled")
  eq("classify: unknown fallback", core.classifyError("something weird happened"), "unknown")
  eq("classify: empty -> unknown", core.classifyError(""), "unknown")
  eq("classify: nil -> unknown", core.classifyError(nil), "unknown")
  -- review fix: bare "insufficient"/"abort" mis-bucketed -> scope them
  eq("classify: insufficient permissions not budget", core.classifyError("insufficient permissions"), "unknown")
  eq("classify: insufficient quota -> budget", core.classifyError("insufficient quota remaining"), "budget_exceeded")
  eq("classify: connection aborted -> runtime", core.classifyError("Error: connection aborted"), "runtime_error")
  eq("classify: user abort -> user_cancelled", core.classifyError("user aborted the request"), "user_cancelled")
  -- precedence lock: budget (rule #1) beats timeout when a message has both
  eq("classify: budget beats timeout on multi-keyword", core.classifyError("request timed out: HTTP 429"), "budget_exceeded")
end

-- ---- planFromTranscript: agent plan/TODO from the tail ---------------------
do
  local function asst(blocks) return core.json.encode({ type = "assistant", message = { content = blocks } }) end
  local todoLine = asst({ { type = "tool_use", name = "TodoWrite", input = { todos = {
    { content = "write tests", status = "completed" }, { content = "wire dashboard", status = "in_progress" } } } } })
  local planLine = asst({ { type = "tool_use", name = "ExitPlanMode", input = { plan = "Step 1. do X\nStep 2. do Y" } } })
  local chat = asst({ { type = "text", text = "hello" } })
  -- todos parsed
  local p = core.planFromTranscript(chat .. "\n" .. todoLine)
  check("plan: todos found", p ~= nil and p.todos ~= nil)
  eq("plan: todo count", p and #p.todos, 2)
  eq("plan: todo content", p and p.todos[2].content, "wire dashboard")
  eq("plan: todo status", p and p.todos[2].status, "in_progress")
  -- plan text parsed
  local p2 = core.planFromTranscript(planLine)
  eq("plan: ExitPlanMode plan", p2 and p2.plan, "Step 1. do X\nStep 2. do Y")
  -- newest TodoWrite wins (scan backwards)
  local older = asst({ { type = "tool_use", name = "TodoWrite", input = { todos = { { content = "old", status = "pending" } } } } })
  local pn = core.planFromTranscript(older .. "\n" .. todoLine)
  eq("plan: newest todos win", pn and #pn.todos, 2)
  -- both plan + todos
  local both = core.planFromTranscript(planLine .. "\n" .. todoLine)
  check("plan: both plan and todos", both and both.plan ~= nil and both.todos ~= nil)
  -- newest ExitPlanMode plan wins (mirror of newest-todos-wins; locks the backward scan)
  local oldPlan = asst({ { type = "tool_use", name = "ExitPlanMode", input = { plan = "OLD" } } })
  eq("plan: newest ExitPlanMode wins", core.planFromTranscript(oldPlan .. "\n" .. planLine).plan, "Step 1. do X\nStep 2. do Y")
  -- none / garbage
  eq("plan: no plan/todos -> nil", core.planFromTranscript(chat), nil)
  eq("plan: empty -> nil", core.planFromTranscript(""), nil)
  eq("plan: garbage line skipped", core.planFromTranscript("{ not json\n" .. todoLine) ~= nil, true)
end

-- ---- deriveAutoTitle: tile title from the first prompt ----------------------
do
  eq("autotitle: first line", core.deriveAutoTitle("Fix the login bug\nmore detail", 48), "Fix the login bug")
  eq("autotitle: strips list marker", core.deriveAutoTitle("- refactor the parser", 48), "refactor the parser")
  eq("autotitle: strips md header", core.deriveAutoTitle("## Add caching", 48), "Add caching")
  eq("autotitle: collapses whitespace", core.deriveAutoTitle("do    a   thing", 48), "do a thing")
  eq("autotitle: skips blank leading lines", core.deriveAutoTitle("\n\n  real task", 48), "real task")
  eq("autotitle: blank -> nil", core.deriveAutoTitle("   ", 48), nil)
  eq("autotitle: nil -> nil", core.deriveAutoTitle(nil, 48), nil)
  local long = core.deriveAutoTitle(string.rep("x", 100), 20)
  check("autotitle: truncates to maxLen", #long <= 20 + 3)  -- + ellipsis bytes
  check("autotitle: truncation adds ellipsis", long:sub(-3) == "\226\128\166")
end

-- ---- isLooping: repeated-tool-call watchdog --------------------------------
do
  local function tu(name, input) return core.json.encode({ type = "assistant",
    message = { content = { { type = "tool_use", name = name, input = input } } } }) end
  -- toolCallSig: primary arg picked deterministically
  eq("loopsig: bash command", core.toolCallSig("Bash", { command = "ls -la" }), "Bash\1ls -la")
  eq("loopsig: read file", core.toolCallSig("Read", { file_path = "/a/b.lua" }), "Read\1/a/b.lua")
  eq("loopsig: no primary -> name only", core.toolCallSig("Glob", {}), "Glob\1")
  -- transcriptToolSigs: ordered, capped
  local tail = tu("Bash", { command = "make test" }) .. "\n" .. tu("Read", { file_path = "/x" })
  local sigs = core.transcriptToolSigs(tail, 12)
  eq("loopsigs: count", #sigs, 2)
  eq("loopsigs: order oldest->newest", sigs[1], "Bash\1make test")
  -- isLooping: 3 identical consecutive -> looping
  local loopTail = (tu("Bash", { command = "npm run x" }) .. "\n"):rep(3)
  check("loop: 3 same in a row -> true", core.isLooping(core.transcriptToolSigs(loopTail, 12), 3))
  -- mixed tail -> not looping
  local mixed = tu("Bash", { command = "a" }) .. "\n" .. tu("Bash", { command = "b" }) .. "\n" .. tu("Bash", { command = "a" })
  eq("loop: alternating -> false", core.isLooping(core.transcriptToolSigs(mixed, 12), 3), false)
  -- below threshold -> false
  eq("loop: 2 when n=3 -> false", core.isLooping({ "x", "x" }, 3), false)
  eq("loop: n<2 disabled", core.isLooping({ "x", "x", "x" }, 1), false)
  eq("loop: empty sig not a loop", core.isLooping({ "\1", "\1", "\1" }, 3), false)
  -- review fix: an arg-less sig (name only, e.g. repeated TodoWrite) is not a loop
  eq("loop: arg-less repeats not a loop", core.isLooping({ "TodoWrite\1", "TodoWrite\1", "TodoWrite\1" }, 3), false)
end

-- ---- notifyDecision: OS banner on a rising edge -----------------------------
do
  local onApp = { notifications = { banner = { onApproval = true } } }
  local onDone = { notifications = { banner = { onDone = true } } }
  local off = {}
  local appItem = { name = "alpha", status = "approval", pending = { summary = "Bash(rm)" } }
  local doneItem = { name = "beta", status = "done", activity = "wrote the file" }
  -- rising edge into approval fires when enabled
  local n = core.notifyDecision("working", appItem, onApp)
  check("notify: approval edge fires", n ~= nil and n.kind == "approval")
  check("notify: approval text has summary", n and n.text:find("Bash(rm)", 1, true) ~= nil)
  -- done edge
  eq("notify: done edge kind", (core.notifyDecision("working", doneItem, onDone) or {}).kind, "done")
  -- no edge (same status) -> nil
  eq("notify: no edge when status unchanged", core.notifyDecision("approval", appItem, onApp), nil)
  -- nil prev (post-reload) -> nil
  eq("notify: nil prev -> no banner", core.notifyDecision(nil, appItem, onApp), nil)
  -- config off -> nil
  eq("notify: off by default", core.notifyDecision("working", appItem, off), nil)
  -- approval edge but only onDone enabled -> nil
  eq("notify: wrong toggle -> nil", core.notifyDecision("working", appItem, onDone), nil)
end

-- ---- L6 rule engine: validate / fail-safe load / matcher -------------------
do
  local goodLog = { name = "log-done", trigger = { kind = "done" }, processor = { kind = "log", text = "finished" } }
  local goodNudge = { name = "nudge-err", trigger = { kind = "error", match = { group = "build*" } },
                      processor = { kind = "nudge", text = "continue" }, once = true }
  eq("rule: valid log", core.validateRule(goodLog).ok, true)
  eq("rule: valid nudge w/ scope", core.validateRule(goodNudge).ok, true)
  eq("rule: missing name", core.validateRule({ trigger = { kind = "done" }, processor = { kind = "log" } }).ok, false)
  eq("rule: bad trigger kind", core.validateRule({ name = "x", trigger = { kind = "boom" }, processor = { kind = "log" } }).ok, false)
  eq("rule: bad processor kind", core.validateRule({ name = "x", trigger = { kind = "done" }, processor = { kind = "explode" } }).ok, false)
  eq("rule: nudge needs text", core.validateRule({ name = "x", trigger = { kind = "done" }, processor = { kind = "nudge" } }).ok, false)
  eq("rule: relabel needs label", core.validateRule({ name = "x", trigger = { kind = "done" }, processor = { kind = "relabel" } }).ok, false)
  eq("rule: unknown field", core.validateRule({ name = "x", trigger = { kind = "done" }, processor = { kind = "log" }, bogus = 1 }).ok, false)
  -- fail-safe load: keep valid, drop bad, dedupe by name
  local ld = core.ruleLoad({ rules = { goodLog, { name = "" }, goodLog, goodNudge } })
  eq("rule-load: keeps valid", #ld.valid, 2)
  eq("rule-load: drops bad + dup", #ld.errors, 2)
  -- ruleFires: kind + scope
  local item = { projectKey = "/p", group = "build", key = "k1", providerId = "anthropic" }
  local lrule = core.ruleList({ rules = { goodLog } })[1]
  eq("rule-fires: kind match", core.ruleFires(lrule, "done", item), true)
  eq("rule-fires: wrong edge", core.ruleFires(lrule, "error", item), false)
  local nrule = core.ruleList({ rules = { goodNudge } })[1]
  eq("rule-fires: scope group glob", core.ruleFires(nrule, "error", item), true)
  eq("rule-fires: scope mismatch",
     core.ruleFires(nrule, "error", { group = "review", key = "k", projectKey = "/p" }), false)
  eq("rule-fires: disabled -> false",
     core.ruleFires({ enabled = false, trigger = { kind = "done" } }, "done", item), false)
  -- rulesForEdge ordered
  local rs = core.ruleList({ rules = { goodLog, goodNudge } })
  eq("rules-for-edge: done -> 1", #core.rulesForEdge(rs, "done", item), 1)
  eq("rules-for-edge: error -> 1 (scoped)", #core.rulesForEdge(rs, "error", item), 1)
  eq("rules-for-edge: matched scope on hung", #core.rulesForEdge(rs, "hung", item), 0)

  -- L6 NEW triggers (hung/loop/starved) + processors (feed/continue) now valid
  eq("rule: hung trigger valid",
     core.validateRule({ name = "h", trigger = { kind = "hung" }, processor = { kind = "log" } }).ok, true)
  eq("rule: loop trigger valid",
     core.validateRule({ name = "l", trigger = { kind = "loop" }, processor = { kind = "nudge", text = "try again" } }).ok, true)
  eq("rule: starved trigger valid",
     core.validateRule({ name = "s", trigger = { kind = "starved" }, processor = { kind = "log" } }).ok, true)
  eq("rule: feed processor needs text",
     core.validateRule({ name = "f", trigger = { kind = "done" }, processor = { kind = "feed" } }).ok, false)
  eq("rule: feed processor valid w/ text",
     core.validateRule({ name = "f", trigger = { kind = "done" }, processor = { kind = "feed", text = "next task" } }).ok, true)
  eq("rule: continue processor valid (no text)",
     core.validateRule({ name = "c", trigger = { kind = "error" }, processor = { kind = "continue" } }).ok, true)
  local hrule = core.ruleList({ rules = { { name = "h", trigger = { kind = "hung" }, processor = { kind = "log" } } } })[1]
  eq("rule-fires: hung edge", core.ruleFires(hrule, "hung", item), true)

  -- L6 rule CRUD (editor): push / replace / remove / get / setEnabled
  local rst = { rules = {} }
  local rst1, rok = core.rulePush(rst, goodLog)
  eq("rulePush: saved", rok, true)
  eq("rulePush: count 1", #core.ruleList(rst1), 1)
  local _, rbad, rerrs = core.rulePush(rst, { name = "x", trigger = { kind = "boom" }, processor = { kind = "log" } })
  eq("rulePush: invalid rejected", rbad, false)
  check("rulePush: errors returned", type(rerrs) == "table" and #rerrs > 0)
  local rst2 = core.rulePush(rst1, { name = goodLog.name, trigger = { kind = "error" }, processor = { kind = "log" } })
  eq("rulePush: replace in place", #core.ruleList(rst2), 1)
  eq("rulePush: replaced trigger", core.ruleGet(rst2, goodLog.name).trigger.kind, "error")
  check("ruleGet: finds", core.ruleGet(rst1, goodLog.name) ~= nil)
  eq("ruleGet: miss -> nil", core.ruleGet(rst1, "nope"), nil)
  eq("ruleRemove: deletes", #core.ruleList(core.ruleRemove(rst1, goodLog.name)), 0)
  -- setEnabled preserves the rest of the record (RAW state)
  local rEn = core.ruleSetEnabled({ rules = { { name = "r", enabled = true, trigger = { kind = "done" },
    processor = { kind = "nudge", text = "hi" } } } }, "r", false)
  eq("ruleSetEnabled: disabled", core.ruleList(rEn)[1].enabled, false)
  eq("ruleSetEnabled: preserves processor text", core.ruleList(rEn)[1].processor.text, "hi")
end

-- ---- L7 cron / schedule layer ----------------------------------------------
do
  local t = { min = 30, hour = 9, day = 15, month = 6, wday = 2 }  -- Mon (os.date wday 2)
  eq("cron: exact match", core.cronMatches("30 9 15 6 *", t), true)
  eq("cron: wildcard all", core.cronMatches("* * * * *", t), true)
  eq("cron: minute mismatch", core.cronMatches("31 9 15 6 *", t), false)
  eq("cron: step */15 at :30", core.cronMatches("*/15 * * * *", t), true)
  eq("cron: step */15 at :31", core.cronMatches("*/15 * * * *", { min = 31, hour = 9, day = 1, month = 1, wday = 1 }), false)
  eq("cron: hour range 8-17", core.cronMatches("0 8-17 * * *", { min = 0, hour = 9, day = 1, month = 1, wday = 1 }), true)
  eq("cron: day list 1,15", core.cronMatches("0 0 1,15 * *", { min = 0, hour = 0, day = 15, month = 3, wday = 1 }), true)
  eq("cron: dow Monday", core.cronMatches("30 9 * * 1", t), true)
  eq("cron: dow Sunday via 0", core.cronMatches("0 9 * * 0", { min = 0, hour = 9, day = 1, month = 1, wday = 1 }), true)
  eq("cron: dow Sunday via 7", core.cronMatches("0 9 * * 7", { min = 0, hour = 9, day = 1, month = 1, wday = 1 }), true)
  eq("cron: dom-OR-dow when both set", core.cronMatches("30 9 15 * 5", t), true)  -- dom 15 matches even though dow != Fri
  eq("cron: bad field count", core.cronMatches("* * *", t), false)
  -- nextRunAt: future + satisfies the cron
  local n0 = 1700000000
  local nr = core.nextRunAt("*/15 * * * *", n0)
  check("nextrun: in the future", nr ~= nil and nr > n0)
  check("nextrun: minute is a /15", nr ~= nil and (tonumber(os.date("%M", nr)) % 15) == 0)
  eq("nextrun: nil now -> nil", core.nextRunAt("* * * * *", nil), nil)
  -- dueSchedules: a cron matching now's minute fires once; lastFiredAt gates it
  local now = 1700000000
  local d = os.date("*t", now)
  local matching = string.format("%d %d * * *", d.min, d.hour)
  local sCron = { name = "c", kind = "cron", cron = matching, folder = "/p", enabled = true }
  eq("due: cron matches this minute", #core.dueSchedules({ sCron }, now), 1)
  eq("due: not refired same minute",
     #core.dueSchedules({ { name = "c", kind = "cron", cron = matching, folder = "/p", enabled = true, lastFiredAt = now } }, now), 0)
  eq("due: disabled never fires",
     #core.dueSchedules({ { name = "c", kind = "cron", cron = matching, folder = "/p", enabled = false } }, now), 0)
  eq("due: oneShot past fires",
     #core.dueSchedules({ { name = "o", kind = "oneShot", at = now - 10, folder = "/p", enabled = true } }, now), 1)
  eq("due: oneShot future skipped",
     #core.dueSchedules({ { name = "o", kind = "oneShot", at = now + 1000, folder = "/p", enabled = true } }, now), 0)
  eq("due: oneShot already fired",
     #core.dueSchedules({ { name = "o", kind = "oneShot", at = now - 10, folder = "/p", enabled = true, lastFiredAt = now - 5 } }, now), 0)
  -- humanizeCron
  eq("human: daily", core.humanizeCron("30 9 * * *"), "daily at 09:30")
  eq("human: every 15", core.humanizeCron("*/15 * * * *"), "every 15 min")
  eq("human: weekly Mon", core.humanizeCron("0 9 * * 1"), "Mon at 09:00")
  eq("human: hourly", core.humanizeCron("0 * * * *"), "hourly")
  -- validate / load / backpressure
  eq("vsched: valid", core.validateSchedule(sCron).ok, true)
  eq("vsched: missing folder", core.validateSchedule({ name = "x", kind = "cron", cron = "* * * * *" }).ok, false)
  eq("vsched: bad cron fields", core.validateSchedule({ name = "x", kind = "cron", cron = "* *", folder = "/p" }).ok, false)
  eq("vsched: oneShot needs at", core.validateSchedule({ name = "x", kind = "oneShot", folder = "/p" }).ok, false)
  eq("vsched: unknown field", core.validateSchedule({ name = "x", kind = "cron", cron = "* * * * *", folder = "/p", bogus = 1 }).ok, false)
  local sl = core.scheduleLoad({ schedules = { sCron, { name = "" }, sCron } })
  eq("sload: keeps valid", #sl.valid, 1)
  eq("sload: drops bad + dup", #sl.errors, 2)
  eq("sload: enabled normalized", core.scheduleList({ schedules = { sCron } })[1].enabled, true)
  eq("backpressure: over cap", core.scheduleBackpressure(10, 8), true)
  eq("backpressure: under cap", core.scheduleBackpressure(5, 8), false)
  eq("backpressure: disabled (cap 0)", core.scheduleBackpressure(100, 0), false)
  -- scheduleMarkFired: cron stamps lastFiredAt; oneShot self-deletes
  local st = { schedules = { sCron, { name = "o", kind = "oneShot", at = 1, folder = "/p", enabled = true } } }
  local after = core.scheduleMarkFired(st, "c", 555)
  eq("markfired: cron count unchanged", #after.schedules, 2)
  eq("markfired: cron stamped", core.scheduleList(after)[1].lastFiredAt, 555)
  local after2 = core.scheduleMarkFired(st, "o", 555)
  eq("markfired: oneShot removed", #after2.schedules, 1)
  eq("markfired: unknown name no-op", #core.scheduleMarkFired(st, "nope", 555).schedules, 2)
  -- L7 digest action: a digest routine needs no folder; action validated + normalized
  eq("vsched: digest needs no folder",
     core.validateSchedule({ name = "d", kind = "cron", cron = "0 9 * * *", action = "digest" }).ok, true)
  eq("vsched: bad action", core.validateSchedule({ name = "d", kind = "cron", cron = "0 9 * * *", folder = "/p", action = "boom" }).ok, false)
  eq("sched: action defaults to spawn", core.scheduleList({ schedules = { sCron } })[1].action, "spawn")
  eq("sched: digest action normalized",
     core.scheduleList({ schedules = { { name = "d", kind = "cron", cron = "0 9 * * *", action = "digest", digestHours = 8 } } })[1].action, "digest")
end

-- ---- L7 routine-board CRUD + cron builder ----------------------------------
do
  -- cronBuild: each freq -> a valid 5-field cron the matcher accepts
  eq("cronBuild: minute", core.cronBuild({ freq = "minute", every = 10 }), "*/10 * * * *")
  eq("cronBuild: minute clamps", core.cronBuild({ freq = "minute", every = 0 }), "*/1 * * * *")
  eq("cronBuild: minute default", core.cronBuild({ freq = "minute" }), "*/5 * * * *")
  eq("cronBuild: hourly at :15", core.cronBuild({ freq = "hour", minute = 15 }), "15 * * * *")
  eq("cronBuild: daily", core.cronBuild({ freq = "day", minute = 30, hour = 9 }), "30 9 * * *")
  eq("cronBuild: day default 09:00", core.cronBuild({ freq = "day" }), "0 9 * * *")
  eq("cronBuild: weekly sorted+dedup", core.cronBuild({ freq = "week", minute = 0, hour = 8, weekdays = { 5, 1, 1, 3 } }), "0 8 * * 1,3,5")
  eq("cronBuild: weekly none -> *", core.cronBuild({ freq = "week", minute = 0, hour = 8, weekdays = {} }), "0 8 * * *")
  eq("cronBuild: weekly drops out-of-range", core.cronBuild({ freq = "week", weekdays = { 9, 2 } }), "0 9 * * 2")
  eq("cronBuild: monthly", core.cronBuild({ freq = "month", minute = 0, hour = 6, dom = 15 }), "0 6 15 * *")
  eq("cronBuild: hour clamps", core.cronBuild({ freq = "day", hour = 99 }), "0 23 * * *")
  eq("cronBuild: empty -> daily default", core.cronBuild(nil), "0 9 * * *")
  check("cronBuild output is a valid 5-field cron", core.validateSchedule({
    name = "x", kind = "cron", cron = core.cronBuild({ freq = "week", weekdays = { 2 } }), folder = "/p" }).ok)
  -- schedulePush: validate, replace-in-place, prepend, cap
  local s0 = { schedules = {} }
  local s1, ok1 = core.schedulePush(s0, { name = "a", kind = "cron", cron = "0 9 * * *", folder = "/p" })
  eq("schedPush: saved", ok1, true)
  eq("schedPush: count 1", #s1.schedules, 1)
  local _, ok2, errs2 = core.schedulePush(s0, { name = "", kind = "cron", cron = "0 9 * * *", folder = "/p" })
  eq("schedPush: invalid rejected", ok2, false)
  check("schedPush: returns errors", type(errs2) == "table" and #errs2 > 0)
  -- replace-in-place carries forward lastFiredAt
  local sFired = { schedules = { { name = "a", kind = "cron", cron = "0 9 * * *", folder = "/p", enabled = true, lastFiredAt = 999 } } }
  local sRepl = core.schedulePush(sFired, { name = "a", kind = "cron", cron = "0 10 * * *", folder = "/p", enabled = true })
  eq("schedPush: replace same name (no dup)", #sRepl.schedules, 1)
  eq("schedPush: replace updates cron", core.scheduleList(sRepl)[1].cron, "0 10 * * *")
  eq("schedPush: replace keeps lastFiredAt", core.scheduleList(sRepl)[1].lastFiredAt, 999)
  -- prepend (new name goes to front)
  local sPre = core.schedulePush(s1, { name = "b", kind = "cron", cron = "0 8 * * *", folder = "/p" })
  eq("schedPush: prepend to front", core.scheduleList(sPre)[1].name, "b")
  -- cap drops the oldest
  local capState = { schedules = {} }
  for i = 1, 5 do capState = core.schedulePush(capState, { name = "r" .. i, kind = "cron", cron = "0 9 * * *", folder = "/p" }, 3) end
  eq("schedPush: cap honored", #capState.schedules, 3)
  -- scheduleRemove / scheduleGet
  eq("schedRemove: deletes by name", #core.scheduleRemove(sRepl, "a").schedules, 0)
  eq("schedRemove: miss is no-op", #core.scheduleRemove(sRepl, "nope").schedules, 1)
  check("schedGet: finds", core.scheduleGet(sRepl, "a") ~= nil)
  eq("schedGet: miss -> nil", core.scheduleGet(sRepl, "nope"), nil)
  -- scheduleSetEnabled toggles + preserves extra fields (raw state)
  local sToggle = core.scheduleSetEnabled(sFired, "a", false)
  eq("schedSetEnabled: paused", core.scheduleList(sToggle)[1].enabled, false)
  eq("schedSetEnabled: preserves lastFiredAt", core.scheduleList(sToggle)[1].lastFiredAt, 999)
  eq("schedSetEnabled: resume", core.scheduleList(core.scheduleSetEnabled(sToggle, "a", true))[1].enabled, true)
  -- scheduleBoard: human + nextRunAt annotations
  local now = 1700000000
  local board = core.scheduleBoard(core.scheduleList({ schedules = {
    { name = "c", kind = "cron", cron = "0 9 * * *", folder = "/p", enabled = true },
    { name = "o", kind = "oneShot", at = now + 1000, folder = "/p", enabled = true },
  } }), now)
  eq("schedBoard: cron human", board[1].human, "daily at 09:00")
  check("schedBoard: cron nextRunAt set", type(board[1].nextRunAt) == "number" and board[1].nextRunAt > now)
  eq("schedBoard: oneShot human", board[2].human, "once")
  eq("schedBoard: oneShot nextRunAt = at", board[2].nextRunAt, now + 1000)
end

-- ---- runSequence: beat-list scheduling (injected scheduler) ----------------
do
  -- Cumulative offsets: delays are RELATIVE to the previous beat, so the
  -- scheduler must receive the running sum (the spawn ladder's tunable column).
  local offsets, ran = {}, {}
  local function fakeSchedule(t, fn)
    offsets[#offsets + 1] = t
    fn()                       -- synchronous: run the beat now
    return "handle-" .. #offsets
  end
  local handles = core.runSequence({
    { delay = 3.0, fn = function() ran[#ran + 1] = "a" end },
    { delay = 0.8, fn = function() ran[#ran + 1] = "b" end },
    { delay = 2.0, fn = function() ran[#ran + 1] = "c" end },
  }, fakeSchedule)
  eq("runSeq: first offset", offsets[1], 3.0)
  eq("runSeq: offsets accumulate", offsets[2], 3.8)
  eq("runSeq: third offset", offsets[3], 5.8)
  eq("runSeq: all beats ran in order", table.concat(ran, ","), "a,b,c")
  eq("runSeq: one handle per beat", #handles, 3)
  eq("runSeq: handles are the scheduler's returns", handles[2], "handle-2")
  -- per-beat pcall (see runSequence's header): a throwing beat doesn't abort the rest
  local ran2 = {}
  core.runSequence({
    { delay = 1, fn = function() ran2[#ran2 + 1] = 1 end },
    { delay = 1, fn = function() error("boom") end },
    { delay = 1, fn = function() ran2[#ran2 + 1] = 3 end },
  }, function(_, fn) fn() end)
  eq("runSeq: beats around a throwing one still fire", table.concat(ran2, ","), "1,3")
  -- degenerate inputs
  eq("runSeq: nil steps -> empty handles", #core.runSequence(nil, function() end), 0)
  eq("runSeq: missing delay treated as 0", (function()
    local o = {}
    core.runSequence({ { fn = function() end } }, function(t) o[1] = t end)
    return o[1]
  end)(), 0)
end

-- ---- staggerSlot: the shared injection-chain schedule ----------------------
do
  -- cold start: now is past the (empty) tail -> no delay, tail = now + gap
  local d, t = core.staggerSlot(0, 100, 5)
  eq("stagger: cold start no delay", d, 0)
  eq("stagger: cold start tail = now + gap", t, 105)
  -- back-to-back reservation while the tail is still ahead -> wait for it,
  -- and the tail advances by gap FROM THE TAIL (not from now)
  local d2, t2 = core.staggerSlot(105, 101, 5)
  eq("stagger: queued behind in-flight chain", d2, 4)
  eq("stagger: tail advances by gap", t2, 110)
  -- a reservation arriving after the tail passed -> resets off NOW, not the
  -- stale tail (no phantom delay from long-finished chains)
  local d3, t3 = core.staggerSlot(110, 200, 5)
  eq("stagger: stale tail -> no delay", d3, 0)
  eq("stagger: stale tail -> tail rebased off now", t3, 205)
  -- degenerate inputs coerce to 0 (nil-safe)
  local d4, t4 = core.staggerSlot(nil, nil, nil)
  eq("stagger: nil inputs -> zero delay", d4, 0)
  eq("stagger: nil inputs -> zero tail", t4, 0)
  local d5, t5 = core.staggerSlot("junk", "junk", 5)
  eq("stagger: garbage strings coerce", d5, 0)
  eq("stagger: garbage tail = gap", t5, 5)
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

-- ---- L3: template validate / fail-safe load --------------------------------
do
  eq("vtpl: not a table", core.validateTemplate("x").ok, false)
  eq("vtpl: blank name invalid", core.validateTemplate({ name = "", text = "t" }).ok, false)
  eq("vtpl: needs text or description",
     core.validateTemplate({ name = "n" }).ok, false)
  eq("vtpl: text-only valid", core.validateTemplate({ name = "n", text = "t" }).ok, true)
  eq("vtpl: description-only valid", core.validateTemplate({ name = "n", description = "d" }).ok, true)
  eq("vtpl: non-string text invalid", core.validateTemplate({ name = "n", text = 5 }).ok, false)
  eq("vtpl: non-list vars invalid", core.validateTemplate({ name = "n", text = "t", vars = "x" }).ok, false)
  eq("vtpl: unknown field flagged", core.validateTemplate({ name = "n", text = "t", bogus = 1 }).ok, false)
  -- fail-safe load keeps valid, drops bad with reasons; dup keeps first
  local ld = core.templateLoad({ templates = {
    { name = "a", text = "t" }, { name = "", text = "x" },
    { name = "a", text = "dup" }, { name = "c", description = "d" } } })
  eq("ltpl: keeps the valid", #ld.valid, 2)
  eq("ltpl: drops the bad + dup", #ld.errors, 2)
  eq("ltpl: dup keeps first text", core.templateGet({ templates = ld.valid }, "a"), "t")
  -- legacy round-trips byte-identically (no spurious fields)
  local leg = core.templateList({ templates = { { name = "L", text = "body" } } })[1]
  eq("ltpl: legacy keeps text", leg.text, "body")
  eq("ltpl: legacy has no version", leg.version, nil)
end

-- ---- L3: compose / vars / render -------------------------------------------
do
  eq("compose: legacy text", core.composeTemplate({ name = "n", text = "hi" }), "hi")
  eq("compose: structured w/ expected",
     core.composeTemplate({ name = "n", description = "Do X", expected_output = "A diff" }),
     "Do X\n\nExpected output:\nA diff")
  eq("compose: description only", core.composeTemplate({ name = "n", description = "Do X" }), "Do X")
  eq("compose: nil -> nil", core.composeTemplate(nil), nil)
  eq("compose: contentless -> nil", core.composeTemplate({ name = "n" }), nil)

  local vs = core.templateVars("Fix {{bug}} in {{file}}, note {{ctx?}}, on {{today}}")
  eq("vars: count excludes builtins", #vs, 3)
  eq("vars: first name", vs[1].name, "bug")
  eq("vars: required default", vs[1].required, true)
  eq("vars: optional marker", vs[3].required, false)
  -- a name required if ANY occurrence is required
  local vs2 = core.templateVars("{{x?}} then {{x}}")
  eq("vars: dedup", #vs2, 1)
  eq("vars: any-required wins", vs2[1].required, true)

  -- render: required-missing refuses
  local r1, miss = core.renderTemplate("Hi {{name}}", {})
  eq("render: refuses on missing required", r1, nil)
  eq("render: reports the missing name", miss[1], "name")
  -- render: filled + optional blanks
  eq("render: substitutes", core.renderTemplate("Hi {{name}}", { name = "Sam" }), "Hi Sam")
  eq("render: optional blanks out", core.renderTemplate("a{{x?}}b", {}), "ab")
  -- render: blank value counts as missing for required
  eq("render: blank required missing", core.renderTemplate("{{a}}", { a = "  " }), nil)
  -- render: built-ins from injected now (TZ-agnostic: same os.date both sides)
  local T = 1700000000
  eq("render: today", core.renderTemplate("{{today}}", {}, { now = T }), os.date("%Y-%m-%d", T))
  eq("render: now", core.renderTemplate("{{now}}", {}, { now = T }), os.date("%Y-%m-%d %H:%M", T))
  eq("render: no clock -> blank date", core.renderTemplate("[{{date}}]", {}, {}), "[]")
  eq("render: prev_output", core.renderTemplate("<{{prev_output}}>", {}, { prevOutput = "OUT" }), "<OUT>")
  eq("render: prev_output default blank", core.renderTemplate("<{{prev_output}}>", {}, {}), "<>")
  -- keepMissing (autonomous feed): builtins/prev_output resolve, user vars stay verbatim, never refuses
  local rk, mk = core.renderTemplate("do {{thing}} on {{today}}", {}, { now = T, keepMissing = true })
  eq("render: keepMissing fills builtins, keeps user var", rk, "do {{thing}} on " .. os.date("%Y-%m-%d", T))
  eq("render: keepMissing never refuses", #mk, 0)
  eq("render: keepMissing fills prev_output",
     core.renderTemplate("from {{prev_output}}", {}, { prevOutput = "RESULT", keepMissing = true }), "from RESULT")
  eq("render: keepMissing blanks optional", core.renderTemplate("a{{x?}}b", {}, { keepMissing = true }), "ab")
  eq("render: keepMissing plain task unchanged",
     core.renderTemplate("just do the thing", {}, { keepMissing = true }), "just do the thing")

  -- effectiveVars merges declared schema + parsed body
  local ev = core.effectiveVars({ name = "n", description = "use {{repo}} and {{extra}}",
    vars = { { name = "repo", label = "Repository", required = true },
             { name = "branch", required = false, default = "main" } } })
  eq("effvars: declared first", ev[1].name, "repo")
  eq("effvars: carries label", ev[1].label, "Repository")
  eq("effvars: declared-only kept", ev[2].name, "branch")
  eq("effvars: parsed-only appended", ev[3].name, "extra")
  -- fillDefaults applies a default only when missing/blank
  local fd = core.fillDefaults({ { name = "branch", default = "main" } }, { repo = "r" })
  eq("filld: keeps existing", fd.repo, "r")
  eq("filld: applies default", fd.branch, "main")
  eq("filld: no override of set",
     core.fillDefaults({ { name = "branch", default = "main" } }, { branch = "dev" }).branch, "dev")
end

-- ---- L3: versioning + revert ----------------------------------------------
do
  -- new template starts at version 1, empty history
  local s1 = core.templatePushVersioned(nil, { name = "T", text = "v one" }, { now = 100 })
  local r1 = core.templateGetRecord(s1, "T")
  eq("ver: new starts at 1", r1.version, 1)
  eq("ver: new empty history", #r1.versions, 0)
  -- editing snapshots the previous head and bumps
  local s2 = core.templatePushVersioned(s1, { name = "T", text = "v two" }, { now = 200 })
  local r2 = core.templateGetRecord(s2, "T")
  eq("ver: edit bumps to 2", r2.version, 2)
  eq("ver: edit keeps one snapshot", #r2.versions, 1)
  eq("ver: snapshot holds old body", r2.versions[1].text, "v one")
  eq("ver: head is new body", core.templateGet(s2, "T"), "v two")
  -- an unchanged push is a no-op (no churn)
  local s3 = core.templatePushVersioned(s2, { name = "T", text = "v two" }, { now = 300 })
  eq("ver: unchanged no churn", core.templateGetRecord(s3, "T").version, 2)
  -- version history list: current first, newest-first
  local vh = core.templateVersions(s2, "T")
  eq("ver: history length", #vh, 2)
  eq("ver: current first", vh[1].current, true)
  eq("ver: current version num", vh[1].version, 2)
  eq("ver: prior version num", vh[2].version, 1)
  eq("ver: unknown -> empty", #core.templateVersions(s2, "nope"), 0)
  -- revert is non-destructive: restores old content, bumps forward
  local s4, ok = core.templateRevert(s2, "T", 1, { now = 400 })
  eq("ver: revert ok", ok, true)
  eq("ver: revert restores body", core.templateGet(s4, "T"), "v one")
  eq("ver: revert bumps to 3", core.templateGetRecord(s4, "T").version, 3)
  eq("ver: revert unknown version -> false", select(2, core.templateRevert(s2, "T", 99)), false)
  eq("ver: revert unknown name -> false", select(2, core.templateRevert(s2, "nope", 1)), false)
  -- version history capped
  local big = core.templatePushVersioned(nil, { name = "C", text = "x0" }, { now = 0, versionCap = 2 })
  for i = 1, 5 do
    big = core.templatePushVersioned(big, { name = "C", text = "x" .. i }, { now = i, versionCap = 2 })
  end
  eq("ver: history capped", #core.templateGetRecord(big, "C").versions, 2)
  -- templateRename (editor rename) preserves the full record incl. version history
  local rnOk, ok2 = core.templateRename(s2, "T", "T2")
  eq("rename: ok", ok2, true)
  eq("rename: old gone", core.templateGetRecord(rnOk, "T"), nil)
  eq("rename: new present", core.templateGetRecord(rnOk, "T2").name, "T2")
  eq("rename: keeps version", core.templateGetRecord(rnOk, "T2").version, 2)
  eq("rename: keeps history", #core.templateGetRecord(rnOk, "T2").versions, 1)
  eq("rename: unknown old -> false", select(2, core.templateRename(s2, "nope", "X")), false)
  eq("rename: blank new -> false", select(2, core.templateRename(s2, "T", "  ")), false)
  eq("rename: same name -> false", select(2, core.templateRename(s2, "T", "T")), false)
  -- rename ONTO an existing different template overwrites it (caller confirms)
  local two = core.templatePushVersioned(core.templatePushVersioned(nil,
    { name = "A", text = "aa" }, { now = 1 }), { name = "B", text = "bb" }, { now = 2 })
  local merged = core.templateRename(two, "A", "B")
  eq("rename: collision overwrites", #core.templateList(merged), 1)
  eq("rename: collision keeps renamed body", core.templateGet(merged, "B"), "aa")
  -- review-fix: "edit" is measured on the COMPOSED body, not raw shadowed fields.
  -- description shadows text -> changing text alone is a no-op (no version bump).
  local sv = core.templatePushVersioned(nil, { name = "S", text = "a", description = "D" }, { now = 1 })
  local sv2 = core.templatePushVersioned(sv, { name = "S", text = "b", description = "D" }, { now = 2 })
  eq("ver: shadowed text edit no-op", core.templateGetRecord(sv2, "S").version, 1)
  -- expected_output without a description isn't rendered -> changing it is a no-op
  local se = core.templatePushVersioned(nil, { name = "E", text = "body", expected_output = "x" }, { now = 1 })
  local se2 = core.templatePushVersioned(se, { name = "E", text = "body", expected_output = "y" }, { now = 2 })
  eq("ver: unrendered expected_output edit no-op", core.templateGetRecord(se2, "E").version, 1)
  -- but a real change to the rendered body DOES bump (expected_output WITH a description)
  local sr = core.templatePushVersioned(nil, { name = "R", description = "d", expected_output = "x" }, { now = 1 })
  local sr2 = core.templatePushVersioned(sr, { name = "R", description = "d", expected_output = "y" }, { now = 2 })
  eq("ver: rendered-body edit bumps", core.templateGetRecord(sr2, "R").version, 2)
end

-- ---- L3: prompt-file import (definition source) ----------------------------
do
  -- frontmatter name + body (vars derived from the body at render time)
  local rec = core.parsePromptFile("---\nname: Reviewer\n---\nReview {{file}} now", "fallback")
  eq("prompt: frontmatter name", rec.name, "Reviewer")
  eq("prompt: body is the text", rec.text, "Review {{file}} now")
  -- no frontmatter -> stem is the name, whole (trimmed) text is the body
  local rec2 = core.parsePromptFile("  just do {{x}}  ", "do-it")
  eq("prompt: stem fallback name", rec2.name, "do-it")
  eq("prompt: whole text body trimmed", rec2.text, "just do {{x}}")
  -- import folds files into the store (versioned); bad ones skipped with reasons
  local st, sum = core.promptImport(nil, {
    { stem = "a", text = "---\nname: Alpha\n---\nbody A" },
    { stem = "b", text = "do {{thing}}" },
    { stem = "empty", text = "---\nname: E\n---\n   " } }, { now = 10 })
  eq("import: imported count", sum.imported, 2)
  eq("import: skipped the empty", sum.skipped, 1)
  eq("import: error carries a name", sum.errors[1].name, "E")
  eq("import: stored Alpha body", core.templateGet(st, "Alpha"), "body A")
  eq("import: stored stem-named", core.templateGet(st, "b"), "do {{thing}}")
  eq("import: vars parse from imported body", core.templateVars(core.templateGet(st, "b"))[1].name, "thing")
  -- re-import of a changed body versions (duplicate-on-edit)
  local st2 = core.promptImport(st, { { stem = "a", text = "---\nname: Alpha\n---\nbody A v2" } }, { now = 20 })
  eq("import: re-import bumps version", core.templateGetRecord(st2, "Alpha").version, 2)
  -- garbage tolerated
  local _, sum2 = core.promptImport(nil, "nonsense", { now = 1 })
  eq("import: garbage files -> nothing", sum2.imported, 0)
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
  -- folderScanShellCommand: argv -> a /bin/sh -c command that redirects to a file (so hs.task's
  -- own stdout stays empty -> no >64KB pipe-buffer deadlock over a large tree). Single-quoted.
  eq("fscan: shell cmd quotes argv + redirects",
     core.folderScanShellCommand({ "/opt/homebrew/bin/fd", "--type", "d", "/u/a/Programming" }, "/tmp/out"),
     "'/opt/homebrew/bin/fd' '--type' 'd' '/u/a/Programming' > '/tmp/out' 2>/dev/null")
  local c2 = core.folderScanShellCommand({ "/usr/bin/find", "/Users/a b/Programming" }, "/tmp/o o")
  check("fscan: spaced root stays one quoted token", c2:find("'/Users/a b/Programming'", 1, true) ~= nil)
  check("fscan: spaced outfile is quoted", c2:find("> '/tmp/o o'", 1, true) ~= nil)
  -- a single-quote in a path is POSIX-escaped ('\'') -- not a quote-break (injection guard)
  local c3 = core.folderScanShellCommand({ "fd", "/Users/a's/p" }, "/tmp/o")
  check("fscan: single-quote in a path is escaped", c3:find("'/Users/a'\\''s/p'", 1, true) ~= nil)
  eq("fscan: empty argv -> just the redirect", core.folderScanShellCommand({}, "/tmp/o"), " > '/tmp/o' 2>/dev/null")
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
  eq("escalate: non-approval -> false", core.approvalHealable({ status = "working", since = 0 }, 999, 60), false)
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

  -- DEFAULT flavor: the Claude Code EXTENSION (the panel the operator works
  -- in), not a terminal CLI -- field feedback: "i do not want to run claude
  -- code in the terminal". The task rides along for the Claude input.
  local v = core.spawnSpec("vscode", "/Users/a/proj", "do it", {})
  eq("spawnspec(vscode): kind", v.kind, "vscode")
  eq("spawnspec(vscode): app", v.app, "Visual Studio Code")
  eq("spawnspec(vscode): project", v.project, "/Users/a/proj")
  eq("spawnspec(vscode): default flavor is the extension", v.flavor, "extension")
  eq("spawnspec(vscode): extension carries the task", v.task, "do it")
  eq("spawnspec(vscode): extension has no typed launch line", v.postType, nil)
  eq("spawnspec(cursor): app", core.spawnSpec("cursor", "/p", nil, {}).app, "Cursor")
  -- terminal flavor (opt-in): the typed integrated-terminal launch line
  local vt = core.spawnSpec("vscode", "/Users/a/proj", "do it", { vscodeFlavor = "terminal" })
  eq("spawnspec(vscode/terminal): flavor", vt.flavor, "terminal")
  eq("spawnspec(vscode/terminal): open-terminal key", vt.openTerminalKey.key, "`")
  check("spawnspec(vscode/terminal): post types claude + quoted task",
        vt.postType:find("claude 'do it'", 1, true) ~= nil)
  -- ssh ALWAYS uses the terminal flavor (the extension can't run a remote claude)
  local vs = core.spawnSpec("vscode", "/p", nil, { ssh = { host = "h" } })
  eq("spawnspec(vscode/ssh): forced terminal flavor", vs.flavor, "terminal")
  check("spawnspec(vscode/ssh): post is the ssh line", vs.postType:find("^ssh ") ~= nil)
  -- provider env ALSO forces the terminal flavor: the extension launches its
  -- own claude, so a gateway's ANTHROPIC_* env can only ride the typed line
  local ve = core.spawnSpec("vscode", "/p", nil,
    { env = { { name = "ANTHROPIC_MODEL", value = "m" } } })
  eq("spawnspec(vscode/provider-env): forced terminal flavor", ve.flavor, "terminal")
  check("spawnspec(vscode/provider-env): env rides the typed line",
        ve.postType:find("ANTHROPIC_MODEL=", 1, true) ~= nil)
  -- #37-pin: the extension flavor launches ITS OWN claude and silently discarded
  -- every launch flag -- an agent-profile spawn (persona/--mcp-config/--agent/
  -- --add-dir/--plugin-dir) or a permission mode must force the typed terminal
  -- line so the flags actually apply (mirrors the ssh / provider-env forcing).
  local vp = core.spawnSpec("vscode", "/p", nil, { permissionMode = "plan" })
  eq("#37-pin: permission mode forces the terminal flavor", vp.flavor, "terminal")
  check("#37-pin: the mode rides the typed line",
        vp.postType:find("--permission-mode plan", 1, true) ~= nil)
  local va = core.spawnSpec("vscode", "/p", nil, { agentName = "rev" })
  eq("#37-pin: agent-profile flag forces the terminal flavor", va.flavor, "terminal")
  check("#37-pin: --agent rides the typed line",
        va.postType:find("--agent rev", 1, true) ~= nil)
  local vpersona = core.spawnSpec("vscode", "/p", nil, { appendSystemPrompt = "be terse" })
  eq("#37-pin: persona forces the terminal flavor", vpersona.flavor, "terminal")
  check("#37-pin: persona rides the typed line (quoted)",
        vpersona.postType:find("'be terse'", 1, true) ~= nil)
  -- --remote-control alone must NOT force it (defaults on; forcing would retire
  -- the extension flavor entirely), and a flag-free spawn stays the extension.
  eq("#37-pin: remote-control alone keeps the extension flavor",
     core.spawnSpec("vscode", "/p", nil, { remoteControl = true }).flavor, "extension")
  eq("#37-pin: flag-free spawn still defaults to the extension flavor",
     core.spawnSpec("vscode", "/p", "do it", {}).flavor, "extension")

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
  local vb = core.spawnSpec("vscode", "/p", "do it", { claudeBin = CB, vscodeFlavor = "terminal" })
  check("claudebin: vscode terminal post types the absolute path",
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

-- ---- Remote Control launch flag + startup-sweep targeting ------------------
do
  -- spawnFlags: --remote-control rides only when rc=true; composes with --permission-mode
  eq("rcflag: omitted by default", table.concat(core.spawnFlags(nil, nil), " "), "")
  check("rcflag: present when rc=true",
        table.concat(core.spawnFlags(nil, nil, true), " "):find("--remote-control", 1, true) ~= nil)
  eq("rcflag: absent when rc=false", table.concat(core.spawnFlags("plan", nil, false), " "), "--permission-mode plan")
  check("rcflag: composes with permission-mode",
        table.concat(core.spawnFlags("plan", nil, true), " "):find("--permission%-mode plan.*--remote%-control") ~= nil)

  -- spawnSpec threads the flag through for a LOCAL session, drops it for ssh (the remote
  -- box would register RC to its own claude.ai window)
  local rk = core.spawnSpec("kitty", "/p", nil, { remoteControl = true })
  check("rcspec(kitty): --remote-control present", table.concat(rk.argv, " "):find("--remote-control", 1, true) ~= nil)
  local rt = core.spawnSpec("terminal", "/p", nil, { remoteControl = true, terminal = "Terminal" })
  check("rcspec(terminal): --remote-control in the launch line", rt.applescript:find("--remote-control", 1, true) ~= nil)
  local rkSsh = core.spawnSpec("kitty", "/p", nil, { remoteControl = true, ssh = { host = "h" } })
  check("rcspec(kitty/ssh): flag dropped for a remote box", table.concat(rkSsh.argv, " "):find("--remote-control", 1, true) == nil)
  local rkOff = core.spawnSpec("kitty", "/p", nil, { remoteControl = false })
  check("rcspec(kitty): no flag when off", table.concat(rkOff.argv, " "):find("--remote-control", 1, true) == nil)

  -- remoteControlSweepTargets: only real, local, non-stale, quiescent (idle/done) sessions
  local list = {
    { key = "a", status = "idle",     session_id = "s1" },                 -- target
    { key = "b", status = "done",     session_id = "s2" },                 -- target
    { key = "c", status = "working",  session_id = "s3" },                 -- mid-turn: skip
    { key = "d", status = "approval", session_id = "s4" },                 -- mid-prompt: skip
    { key = "e", status = "error",    session_id = "s5" },                 -- errored: skip
    { key = "f", status = "idle",     session_id = "s6", stale = true },   -- stale ghost: skip
    { key = "g", status = "idle",     session_id = "s7", remote = true },  -- remote tile: skip
    { key = "h", status = "idle",     session_id = "" },                   -- no real session: skip
    { key = "i", status = "idle",     session_id = "s9", model = "gemini-2.5-pro",
      base_url = "http://localhost:4000" },                               -- gateway: /rc would error: skip
  }
  local tgts = core.remoteControlSweepTargets(list)
  eq("rcsweep: count = the two quiescent local sessions", #tgts, 2)
  eq("rcsweep: first is the idle session", tgts[1].key, "a")
  eq("rcsweep: second is the done session", tgts[2].key, "b")
  eq("rcsweep: nil list -> empty", #core.remoteControlSweepTargets(nil), 0)
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

  -- R1-11: a malicious authTokenEnv (shell metachars) is DROPPED -> no token emitted
  -- (fail-closed; the spawn shell can never run the injected substitution).
  local gwbad = { kind = "gateway", baseUrl = "http://x", model = "m",
                  authTokenEnv = "K\"; rm -rf ~ #" }
  local eb = core.providerEnv(gwbad)
  eq("providerenv: malicious authTokenEnv -> no token emitted",
     (function() for _, x in ipairs(eb) do if x.name == "ANTHROPIC_AUTH_TOKEN" then return "leaked" end end return "dropped" end)(),
     "dropped")
  local gwsub = { kind = "gateway", baseUrl = "http://x", model = "m",
                  authTokenEnv = "$(curl evil)" }
  eq("providerenv: command-substitution authTokenEnv -> no token",
     (function() for _, x in ipairs(core.providerEnv(gwsub)) do if x.name == "ANTHROPIC_AUTH_TOKEN" then return "leaked" end end return "dropped" end)(),
     "dropped")

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

  -- vscode TERMINAL flavor prefixes the typed command with the env (the
  -- default extension flavor has no typed line -- the extension owns its env)
  local v = core.spawnSpec("vscode", "/p", "hi", { env = env, vscodeFlavor = "terminal" })
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
  -- R3-02: a metacharacter/dot-traversal host fail-CLOSES sshDest -> nil; the kitty
  -- branch must abort with argv=nil + error, NOT silently drop the dest.
  local kbad = core.spawnSpec("kitty", "/p", "go", { ssh = { host = "h", user = "u;reboot" } })
  eq("spawnspec(kitty,ssh,bad-dest): argv nil (aborted)", kbad.argv, nil)
  check("spawnspec(kitty,ssh,bad-dest): error set", kbad.error ~= nil)
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

  -- contextFractionFor: 437k on opus-4-8 -> effective limit is 1M * 0.92 = 920k (auto-compact
  -- reserve), so ~47.5% -- still NOT a false 100% (the original bug), and tracks the editor.
  local frac, lim = core.contextFractionFor({}, "claude-opus-4-8", 437000)
  eq("ctxfrac: opus 437k effective limit is 920k", lim, 920000)
  check("ctxfrac: opus 437k ~= 0.475 (not full)", frac > 0.46 and frac < 0.49)
  -- self-heal: unknown model at 437k uses the 1M tier (x0.92), not a false 100%
  local f2, l2 = core.contextFractionFor({}, "mystery-model", 437000)
  eq("ctxfrac: unknown 437k bumped to 1M tier x0.92", l2, 920000)
  check("ctxfrac: unknown 437k not full", f2 < 0.5)
  -- a genuinely full 200k model still reads 100% (198k/184k effective -> clamped)
  local f3 = core.contextFractionFor({}, "claude-haiku-4-5", 198000)
  check("ctxfrac: haiku 198k/200k ~ full", f3 >= 0.98)
  -- autoCompactFraction: config override + clamp to a SANE range [0.5, 1]
  eq("autocompact: default 0.92", core.autoCompactFraction({}), 0.92)
  eq("autocompact: config override", core.autoCompactFraction({ context = { autoCompactFraction = 0.85 } }), 0.85)
  eq("autocompact: zero -> default", core.autoCompactFraction({ context = { autoCompactFraction = 0 } }), 0.92)
  eq("autocompact: >1 -> default", core.autoCompactFraction({ context = { autoCompactFraction = 1.5 } }), 0.92)
  -- a tiny value would shrink the denominator to ~0 and pin every tile to a false 100% --
  -- the floor rejects it (the divide-by-~0 the comment warns about)
  eq("autocompact: tiny -> default", core.autoCompactFraction({ context = { autoCompactFraction = 0.01 } }), 0.92)
  eq("autocompact: 0.5 floor is accepted", core.autoCompactFraction({ context = { autoCompactFraction = 0.5 } }), 0.5)
  eq("autocompact: just under floor -> default", core.autoCompactFraction({ context = { autoCompactFraction = 0.49 } }), 0.92)
  -- a smaller fraction makes the same tokens read fuller (reserve tuned tighter):
  -- 460k/(1M*0.5)=0.92 vs 460k/(1M*0.92)=0.50 at the default
  local fTight = core.contextFractionFor({ context = { autoCompactFraction = 0.5 } }, "claude-opus-4-8", 460000)
  local fDefault = core.contextFractionFor({}, "claude-opus-4-8", 460000)
  check("ctxfrac: tighter fraction reads fuller", fTight > fDefault and fTight > 0.9)

  -- contextBand: calm <50, then a band every 10% from 50, distinct last-5% critical band
  eq("band: 0 -> b0", core.contextBand(0), "b0")
  eq("band: 0.49 -> b0", core.contextBand(0.49), "b0")
  eq("band: 0.50 -> b1", core.contextBand(0.50), "b1")
  eq("band: 0.59 -> b1", core.contextBand(0.59), "b1")
  eq("band: 0.60 -> b2", core.contextBand(0.60), "b2")
  eq("band: 0.70 -> b3", core.contextBand(0.70), "b3")
  eq("band: 0.80 -> b4", core.contextBand(0.80), "b4")
  eq("band: 0.90 -> b5", core.contextBand(0.90), "b5")
  eq("band: 0.94 -> b5", core.contextBand(0.94), "b5")
  eq("band: 0.95 -> b6 (last 5%)", core.contextBand(0.95), "b6")
  eq("band: 1.0 -> b6", core.contextBand(1.0), "b6")
  -- contextBucket: deck repaint signature -- ~2.5% steps (0..40), clamped, nil for no-bar
  eq("bucket: 0 -> 0", core.contextBucket(0), 0)
  eq("bucket: 0.5 -> 20", core.contextBucket(0.5), 20)
  eq("bucket: 1.0 -> 40", core.contextBucket(1.0), 40)
  eq("bucket: >1 clamps to 40", core.contextBucket(1.7), 40)
  eq("bucket: <0 clamps to 0", core.contextBucket(-0.3), 0)
  eq("bucket: nil -> nil (no bar)", core.contextBucket(nil), nil)
  eq("bucket: non-numeric -> nil", core.contextBucket("x"), nil)
  -- the threshold that drives a repaint: 0.59 vs 0.61 land in DIFFERENT buckets
  eq("bucket: 0.59 and 0.61 differ (repaint trigger)",
     core.contextBucket(0.59) ~= core.contextBucket(0.61), true)
  -- voiceMaxSeconds: hard cap, default 120, clamps non-positive to default (no `-t 0`)
  eq("voiceMax: default 120", core.voiceMaxSeconds({}), 120)
  eq("voiceMax: override applied", core.voiceMaxSeconds({ voice = { maxSeconds = 45 } }), 45)
  eq("voiceMax: zero -> default", core.voiceMaxSeconds({ voice = { maxSeconds = 0 } }), 120)
  eq("voiceMax: negative -> default", core.voiceMaxSeconds({ voice = { maxSeconds = -10 } }), 120)
  eq("voiceMax: non-numeric -> default", core.voiceMaxSeconds({ voice = { maxSeconds = "nope" } }), 120)
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

  -- The rejection REASON comes from the validator (single source of truth for
  -- the panel's alert): assert the right branch fires with the right value, so
  -- the alert can never blame the parent for a bad name or vice versa.
  local _, whyName = core.newProjectPath("/ok/parent", "bad/name")
  check("newProjectPath: bad-name reason names the name",
    whyName:find('"bad/name"', 1, true) ~= nil and whyName:find("unsupported characters", 1, true) ~= nil)
  check("newProjectPath: bad-name reason does NOT blame the parent",
    whyName:find("absolute path", 1, true) == nil)
  local _, whyParent = core.newProjectPath("rel/path", "good-name")
  check("newProjectPath: relative-parent reason names the parent",
    whyParent:find('"rel/path"', 1, true) ~= nil and whyParent:find("absolute path", 1, true) ~= nil)
  check("newProjectPath: relative-parent reason does NOT blame the name",
    whyParent:find("unsupported characters", 1, true) == nil)
  local okPath, noWhy = core.newProjectPath("/ok", "fine")
  eq("newProjectPath: success has no reason", noWhy, nil)
  eq("newProjectPath: success path intact", okPath, "/ok/fine")
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

  -- R1-15: `ls` liveness-probe argv + the pure window-alive parser
  local ls = core.kittyCmd("ls", it)
  eq("kittyCmd: ls subcommand", ls[4], "ls")
  eq("kittyCmd: ls --match", ls[5], "--match")
  eq("kittyCmd: ls selector", ls[6], "id:7")
  local liveJson = '[{"tabs":[{"windows":[{"id":7}]}]}]'
  local emptyJson = '[]'
  local noWinJson = '[{"tabs":[{"windows":[]}]}]'
  eq("kittyWindowAlive: a matching window -> true", core.kittyWindowAlive(liveJson), true)
  eq("kittyWindowAlive: empty array -> false (window gone)", core.kittyWindowAlive(emptyJson), false)
  eq("kittyWindowAlive: tab with no windows -> false", core.kittyWindowAlive(noWinJson), false)
  eq("kittyWindowAlive: empty string -> false (fail-closed)", core.kittyWindowAlive(""), false)
  eq("kittyWindowAlive: garbage -> false (fail-closed)", core.kittyWindowAlive("not json"), false)
  eq("kittyWindowAlive: nil -> false", core.kittyWindowAlive(nil), false)

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

  -- rank tiers (rationale on titleFolderRank): exact must outrank contains
  -- so prefix-named sibling projects can't steal each other's windows
  eq("titleRank: exact folder segment = 2",
     core.titleFolderRank("claude code — dialer-info", "dialer-info"), 2)
  eq("titleRank: prefix-sibling is only contains = 1",
     core.titleFolderRank("claude code — dialer-info-five9", "dialer-info"), 1)
  eq("titleRank: ancestor vs sibling project = 1 (never exact)",
     core.titleFolderRank("x — dialer-scraper", "dialer"), 1)
  eq("titleRank: ancestor's own window = 2",
     core.titleFolderRank("x — dialer", "dialer"), 2)
  eq("titleRank: decorated title still contains-matches",
     core.titleFolderRank("x — dialer-info (workspace)", "dialer-info"), 1)
  eq("titleRank: trimmed segment can be exact",
     core.titleFolderRank("x —   dialer-info  ", "dialer-info"), 2)
  eq("titleRank: no match -> nil", core.titleFolderRank("x — other", "dialer-info"), nil)
  eq("titleRank: nil title -> nil", core.titleFolderRank(nil, "x"), nil)
  -- self-contained case handling: mixed-case on EITHER side must not silently
  -- demote an exact match (the function can't depend on pre-lowercased input)
  eq("titleRank: mixed-case title still exact", core.titleFolderRank("X — Dialer-Info", "dialer-info"), 2)
  eq("titleRank: mixed-case needle still exact", core.titleFolderRank("x — dialer-info", "Dialer-Info"), 2)

  -- bestWindowFor: the cross-window preference focusProject relies on -- an
  -- exact (rank 2) ANYWHERE beats a contains (rank 1) seen earlier, in BOTH
  -- enumeration orders (first-contains-wins was the field bug).
  local sib  = "claude code — dialer-info-five9"
  local mine = "claude code — dialer-info"
  local i1, r1 = core.bestWindowFor({ sib, mine }, "dialer-info")
  eq("bestWindow: rank-1 sibling first, exact still wins", i1, 2)
  eq("bestWindow: winning rank is exact", r1, 2)
  local i2 = core.bestWindowFor({ mine, sib }, "dialer-info")
  eq("bestWindow: exact first also wins", i2, 1)
  -- contains-only fallback when no exact window exists (decorated title)
  local i3, r3 = core.bestWindowFor({ "x — other", "x — dialer-info (workspace)" }, "dialer-info")
  eq("bestWindow: contains fallback picks the only match", i3, 2)
  eq("bestWindow: fallback rank is contains", r3, 1)
  eq("bestWindow: no match -> nil", core.bestWindowFor({ "x — other" }, "dialer-info"), nil)
  eq("bestWindow: empty list -> nil", core.bestWindowFor({}, "x"), nil)

  -- describeSpec: the dry-run line (spawn.live=false) per spec kind
  local dx = core.describeSpec(core.spawnSpec("vscode", "/Users/a/proj", "do it", {}))
  check("describe: extension marker", dx:find("⌘Esc (Claude Code extension)", 1, true) ~= nil)
  check("describe: extension carries the task", dx:find("+ task: do it", 1, true) ~= nil)
  local dn = core.describeSpec(core.spawnSpec("vscode", "/p", nil, {}))
  check("describe: no task -> no task suffix", dn:find("+ task:", 1, true) == nil)
  local dt = core.describeSpec(core.spawnSpec("vscode", "/p", "go", { vscodeFlavor = "terminal" }))
  check("describe: terminal flavor shows the typed line", dt:find("+ type: ", 1, true) ~= nil)
  check("describe: kitty is the argv", core.describeSpec(core.spawnSpec("kitty", "/p", nil, {}))
    :find("claude", 1, true) ~= nil)
  check("describe: terminal kind is the applescript",
    core.describeSpec(core.spawnSpec("terminal", "/p", nil, {})):find("tell application", 1, true) ~= nil)

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

  -- L5 hooks inspector: flatten settings.json hooks into per-hook rows
  local settings = { hooks = {
    Stop = { { hooks = { { type = "command", command = "bash $HOME/.claude/cc-status.sh" } } } },
    PreToolUse = { { matcher = "Bash", hooks = {
      { type = "command", command = "bash $HOME/.claude/cc-approve.sh", timeout = 130 },
      { type = "command", command = "bash my-own.sh" } } } },
  } }
  local inv = core.parseHookInventory(settings)
  eq("hookInv: row count", #inv, 3)
  eq("hookInv: events sorted (PreToolUse first)", inv[1].event, "PreToolUse")
  eq("hookInv: matcher captured", inv[1].matcher, "Bash")
  eq("hookInv: timeout captured", inv[1].timeout, 130)
  eq("hookInv: ours flagged", inv[1].isOurs, true)
  eq("hookInv: ours script basename", inv[1].script, "cc-approve.sh")
  eq("hookInv: a user hook is not ours", inv[2].isOurs, false)
  eq("hookInv: default matcher is *", inv[3].matcher, "*")  -- the Stop group has no matcher
  eq("hookInv: empty settings -> empty", #core.parseHookInventory({}), 0)
  -- malformed settings.json must degrade to empty/partial, never error (locks the
  -- type-guards the commit claims). hooks-not-a-table, group/hooks/entry not tables.
  eq("hookInv: hooks not a table -> 0", #core.parseHookInventory({ hooks = "bad" }), 0)
  eq("hookInv: group.hooks not a table -> 0",
     #core.parseHookInventory({ hooks = { Stop = { { hooks = "nope" } } } }), 0)
  local mixed = core.parseHookInventory({ hooks = { Stop = { { hooks = {
    "string-not-table", { type = "command", command = "bash $HOME/.claude/cc-status.sh" } } } } } })
  eq("hookInv: non-table hook entry skipped, good one kept", #mixed, 1)
  local junkGroup = core.parseHookInventory({ hooks = { PreToolUse = { "junk", { matcher = "Bash", hooks = {
    { type = "command", command = "bash my.sh" } } } } } })
  eq("hookInv: non-table group element skipped", #junkGroup, 1)
  -- gateHookTimeoutOk
  local gt = core.gateHookTimeoutOk(inv)
  eq("gateTimeout: present", gt.present, true)
  eq("gateTimeout: ok at 130", gt.ok, true)
  local low = core.gateHookTimeoutOk({ { script = "cc-approve.sh", timeout = 60 } })
  eq("gateTimeout: 60 < 130 not ok", low.ok, false)
  -- present but timeout UNSET (hand-wired hook with no timeout field) -> not ok,
  -- still present (the most likely real-world misconfig; pins the t~=nil half).
  local none = core.gateHookTimeoutOk({ { script = "cc-approve.sh" } })
  eq("gateTimeout: present but timeout unset -> not ok", none.ok, false)
  eq("gateTimeout: present even when timeout nil", none.present, true)
  eq("gateTimeout: missing not present",
     core.gateHookTimeoutOk({ { script = "cc-status.sh", timeout = 5 } }).present, false)
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
  -- #7 multi-session set (bulk history delete): matches any listed session_id
  eq("filterLedger: sessions set matches both", #core.filterLedger(evs, { sessions = { "s1", "s2" } }), 3)
  eq("filterLedger: sessions set matches one", #core.filterLedger(evs, { sessions = { "s2" } }), 1)
  eq("filterLedger: empty sessions = all (no filter)", #core.filterLedger(evs, { sessions = {} }), 3)
  check("purge: sessions set is a SCOPED filter", core.purgeFilterIsScoped({ sessions = { "s1" } }) == true)
  check("purge: empty sessions is NOT scoped", core.purgeFilterIsScoped({ sessions = {} }) == false)

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

  -- ledgerCachePlan: incremental re-parse decision (only touch changed files)
  local files = {
    { name = "2026-06-15.jsonl", sig = "100:111" },
    { name = "2026-06-16.jsonl", sig = "200:222" },
    { name = "2026-06-17.jsonl", sig = "300:333" },  -- today (hot)
  }
  -- cold cache: everything reparses, changed
  local cold = core.ledgerCachePlan({}, files)
  check("cachePlan: cold cache is changed", cold.changed == true)
  eq("cachePlan: cold reparses today", cold.reparse["2026-06-17.jsonl"], true)
  eq("cachePlan: cold reparses history", cold.reparse["2026-06-15.jsonl"], true)
  -- warm cache, only today grew (append): reparse ONLY today, others reused
  local warm = {
    ["2026-06-15.jsonl"] = { sig = "100:111", events = {} },
    ["2026-06-16.jsonl"] = { sig = "200:222", events = {} },
    ["2026-06-17.jsonl"] = { sig = "250:300", events = {} },  -- prior, smaller
  }
  local plan = core.ledgerCachePlan(warm, files)
  check("cachePlan: append is changed", plan.changed == true)
  eq("cachePlan: reparses only the grown file", plan.reparse["2026-06-17.jsonl"], true)
  check("cachePlan: reuses unchanged history (15)", plan.reparse["2026-06-15.jsonl"] == nil)
  check("cachePlan: reuses unchanged history (16)", plan.reparse["2026-06-16.jsonl"] == nil)
  -- fully warm, nothing moved: not changed, no reparse (the hot-path win)
  local same = {
    ["2026-06-15.jsonl"] = { sig = "100:111", events = {} },
    ["2026-06-16.jsonl"] = { sig = "200:222", events = {} },
    ["2026-06-17.jsonl"] = { sig = "300:333", events = {} },
  }
  local noop = core.ledgerCachePlan(same, files)
  check("cachePlan: unchanged tick is NOT changed", noop.changed == false)
  check("cachePlan: unchanged tick reparses nothing", next(noop.reparse) == nil)
  -- a redact/purge that shrinks a PAST file (sig moves) reparses just that file
  local shrunk = {
    ["2026-06-15.jsonl"] = { sig = "100:111", events = {} },
    ["2026-06-16.jsonl"] = { sig = "999:999", events = {} },  -- rewritten
    ["2026-06-17.jsonl"] = { sig = "300:333", events = {} },
  }
  local rplan = core.ledgerCachePlan(shrunk, files)
  check("cachePlan: rewritten past file is changed", rplan.changed == true)
  eq("cachePlan: reparses the rewritten file", rplan.reparse["2026-06-16.jsonl"], true)
  -- a vanished cached file (expiry/purge of a whole day) invalidates the snapshot
  local expired = {
    ["2026-06-14.jsonl"] = { sig = "50:50", events = {} },  -- no longer on disk
    ["2026-06-15.jsonl"] = { sig = "100:111", events = {} },
    ["2026-06-16.jsonl"] = { sig = "200:222", events = {} },
    ["2026-06-17.jsonl"] = { sig = "300:333", events = {} },
  }
  local eplan = core.ledgerCachePlan(expired, files)
  check("cachePlan: a vanished daily file is changed", eplan.changed == true)
  check("cachePlan: vanished file not marked present", eplan.present["2026-06-14.jsonl"] == nil)
  -- both-empty (empty ledger dir / feature just enabled): must NOT report changed,
  -- else refresh would needlessly reparse+reassemble every tick (the very stall fixed)
  local empt = core.ledgerCachePlan({}, {})
  check("cachePlan: empty corpus is NOT changed", empt.changed == false and next(empt.reparse) == nil and next(empt.present) == nil)

  -- assembleLedger: the pure ASSEMBLY counterpart to the (tested) decision. Concat
  -- per-file events in file order, sort newest-first, global cap. (This is what the
  -- impure ledgerSnapshot inlined with zero coverage before the extract.)
  local aByFile = {
    ["2026-06-15.jsonl"] = { events = { { ts = 100, type = "x" }, { ts = 300, type = "x" } } },
    ["2026-06-16.jsonl"] = { events = { { ts = 200, type = "x" } } },
  }
  local aOrder = { { name = "2026-06-15.jsonl" }, { name = "2026-06-16.jsonl" } }
  local aev = core.assembleLedger(aOrder, aByFile)
  eq("assembleLedger: total count", #aev, 3)
  eq("assembleLedger: newest first (global sort)", aev[1].ts, 300)
  eq("assembleLedger: middle", aev[2].ts, 200)
  eq("assembleLedger: oldest last", aev[3].ts, 100)
  -- a vanished file (not in the order list) contributes nothing, even if still cached
  local av2 = core.assembleLedger({ { name = "2026-06-16.jsonl" } }, aByFile)
  eq("assembleLedger: vanished file dropped (count)", #av2, 1)
  eq("assembleLedger: vanished file dropped (survivor)", av2[1].ts, 200)
  -- cap is GLOBAL newest-N across files, not per-file (matches old FX.readLedger 2000)
  local big = { f1 = { events = {} }, f2 = { events = {} } }
  for i = 1, 1300 do big.f1.events[i] = { ts = i, type = "x" } end           -- ts 1..1300
  for i = 1, 1300 do big.f2.events[i] = { ts = 2000 + i, type = "x" } end     -- ts 2001..3300
  local capped = core.assembleLedger({ { name = "f1" }, { name = "f2" } }, big)  -- default cap 2000
  eq("assembleLedger: default cap = 2000", #capped, 2000)
  eq("assembleLedger: cap keeps global newest", capped[1].ts, 3300)
  eq("assembleLedger: 2000th is global, not file-local", capped[2000].ts, 601)
  eq("assembleLedger: nil inputs -> empty", #core.assembleLedger(nil, nil), 0)
  -- a file in the order with no cache entry contributes nothing (no crash)
  eq("assembleLedger: missing cache entry skipped", #core.assembleLedger({ { name = "ghost" } }, aByFile), 0)

  check("narrateEvent: decision shows provenance",
    core.narrateEvent({ type = "decision", outcome = "deny", tool = "Bash", summary = "x",
                        by = "autoDeny", pattern = "Bash(rm*)" }):find("autoDeny", 1, true) ~= nil)
  -- glyph-fix: a `fallback` decision (gate timed out / deferred to native) is NOT an
  -- allow -- it must render with ⚠, not the allow ✅ (which read as "gate approved it").
  do
    local fb = core.narrateEvent({ type = "decision", outcome = "fallback", tool = "Bash",
                                   summary = "make deploy", by = "timeout-fallback" })
    check("narrateEvent: fallback decision uses ⚠, not ✅",
          fb:find("⚠", 1, true) ~= nil and fb:find("✅", 1, true) == nil)
    check("narrateEvent: deny still ⛔",
          core.narrateEvent({ type = "decision", outcome = "deny", tool = "Bash" }):find("⛔", 1, true) ~= nil)
    check("narrateEvent: allow still ✅",
          core.narrateEvent({ type = "decision", outcome = "allow", tool = "Bash", by = "human" }):find("✅", 1, true) ~= nil)
  end
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

-- ---- #6 host stats + fleet idle-since --------------------------------------
do
  -- fmtBytes
  eq("host: bytes", core.fmtBytes(512), "512 B")
  eq("host: KB", core.fmtBytes(1536), "1.5 KB")
  eq("host: GB", core.fmtBytes(2 * 1024^3), "2.0 GB")
  eq("host: nil bytes -> dash", core.fmtBytes(nil), "—")
  eq("host: negative bytes -> dash", core.fmtBytes(-5), "—")
  -- fmtUptime
  eq("host: uptime days+hours", core.fmtUptime(4 * 86400 + 3600), "4d 1h")
  eq("host: uptime exact day", core.fmtUptime(2 * 86400), "2d")
  eq("host: uptime under a day falls back to h/m", core.fmtUptime(3661), "1h 1m")
  -- hostHealth: full reading, no pressure
  local h = core.hostHealth({ cpuPct = 42.6, memUsedBytes = 8 * 1024^3, memTotalBytes = 16 * 1024^3,
    diskUsedBytes = 100 * 1024^3, diskTotalBytes = 500 * 1024^3, uptimeSeconds = 90000, loadAvg1 = 1.5 })
  eq("host: cpu rounded", h.cpu, 43)
  eq("host: memPct", h.memPct, 50)
  eq("host: diskPct", h.diskPct, 20)
  eq("host: uptime humanized", h.uptime, "1d 1h")
  eq("host: load passthrough", h.load1, 1.5)
  eq("host: not pressured", h.pressured, false)
  eq("host: no pressure string", h.pressure, nil)
  -- pressure thresholds (default 90): CPU + mem + disk all over
  local hp = core.hostHealth({ cpuPct = 95, memUsedBytes = 95, memTotalBytes = 100,
    diskUsedBytes = 92, diskTotalBytes = 100 })
  eq("host: pressured", hp.pressured, true)
  check("host: pressure lists each at-or-over-threshold metric",
        hp.pressure:find("CPU 95%", 1, true) and hp.pressure:find("mem 95%", 1, true)
        and hp.pressure:find("disk 92%", 1, true))
  -- boundary: the pressure compare is at-or-over (>=), so a metric EXACTLY at the threshold
  -- trips (and the integer-percent rounding means the raw trip point is ~89.5%). Pins the
  -- `>=` intent so a later switch to strict `>` would fail loudly.
  eq("host: disk exactly at threshold (90) is pressured",
     core.hostHealth({ diskUsedBytes = 90, diskTotalBytes = 100 }).pressured, true)
  eq("host: disk just under threshold (89) not pressured",
     core.hostHealth({ diskUsedBytes = 89, diskTotalBytes = 100 }).pressured, false)
  -- custom thresholds
  eq("host: custom cpu threshold not tripped", core.hostHealth({ cpuPct = 80 }, { cpuThreshold = 95 }).pressured, false)
  -- missing readings degrade to nil, never pressured, no crash
  local hm = core.hostHealth({})
  eq("host: missing cpu -> nil", hm.cpu, nil)
  eq("host: missing mem -> nil pct", hm.memPct, nil)
  eq("host: missing -> not pressured", hm.pressured, false)
  eq("host: zero total -> nil pct (no div-by-zero)", core.hostHealth({ memUsedBytes = 5, memTotalBytes = 0 }).memPct, nil)
  eq("host: cpu clamps over 100", core.hostHealth({ cpuPct = 130 }).cpu, 100)

  -- fleetIdleSince
  local fi = core.fleetIdleSince({ { status = "idle", since = 100 }, { status = "done", since = 250 } }, 400)
  eq("idle: all idle/done -> idle", fi.idle, true)
  eq("idle: sinceTs = the last to go quiet", fi.sinceTs, 250)
  eq("idle: seconds = now - sinceTs", fi.seconds, 150)
  local fa = core.fleetIdleSince({ { status = "idle", since = 100 }, { status = "working", since = 250 } }, 400)
  eq("idle: a working tile -> not idle", fa.idle, false)
  eq("idle: ...and active", fa.active, true)
  eq("idle: approval counts as active", core.fleetIdleSince({ { status = "approval", since = 100 } }, 400).active, true)
  eq("idle: error counts as active", core.fleetIdleSince({ { status = "error", since = 100 } }, 400).active, true)
  local fe = core.fleetIdleSince({}, 400)
  eq("idle: empty fleet not idle", fe.idle, false)
  eq("idle: empty fleet not active", fe.active, false)
  eq("idle: falls back to updated, clamps future ts to 0",
     core.fleetIdleSince({ { status = "idle", updated = 500 } }, 400).seconds, 0)
  -- a timestampless quiet tile: idle, but sinceTs/seconds stay nil (no clock to anchor)
  local fn = core.fleetIdleSince({ { status = "idle" } }, 400)
  eq("idle: timestampless quiet tile -> idle", fn.idle, true)
  eq("idle: ...sinceTs nil", fn.sinceTs, nil)
  eq("idle: ...seconds nil", fn.seconds, nil)

  -- insightsHostAttach: the off-by-default gate as a PURE decision (so the off-omission is
  -- behavior-tested, not just source-pinned)
  local hAttachOff = core.insightsHostAttach({ insights = { hostStats = false } }, { cpu = 5 }, { idle = true })
  eq("attach: off -> no host key", hAttachOff.host, nil)
  eq("attach: off -> no fleetIdle key", hAttachOff.fleetIdle, nil)
  eq("attach: off -> empty table", next(hAttachOff), nil)
  eq("attach: default (no cfg) -> off", next(core.insightsHostAttach({}, {}, {})), nil)
  local hAttachOn = core.insightsHostAttach({ insights = { hostStats = true } }, { cpu = 5 }, { idle = true })
  eq("attach: on -> host present", hAttachOn.host.cpu, 5)
  eq("attach: on -> fleetIdle present", hAttachOn.fleetIdle.idle, true)
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

  -- R3-11: a bundle-scoped auto-deny (by='bundle:<name>') counts as an autoDeny hit,
  -- while a bundle auto-ALLOW does not (gated on outcome=='deny').
  eq("risk: bundle-scoped auto-deny counts as autoDeny hit", core.sessionRisk({
    { ts = 1, type = "tool_request", session_id = "b", tool = "Bash" },
    { ts = 2, type = "decision", session_id = "b", outcome = "deny", by = "bundle:locked", pattern = "Bash(rm*)" },
    { ts = 3, type = "tool_request", session_id = "b", tool = "Write" },
    { ts = 4, type = "decision", session_id = "b", outcome = "allow", by = "bundle:locked", pattern = "Write" },
  }, {}).signals.autoDenyHits, 1)

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
  -- R1-24: a no-profile native Anthropic tile carries its raw model so the relaunch
  -- rebuilds it (not the account default). A profile match (model wins via env) and a
  -- gateway session (base_url set) both leave .model nil.
  eq("respawn: no-profile native carries the raw model", b.model, "claude-future-9")
  eq("respawn: profile-matched tile -> nil model", a.model, nil)
  eq("respawn: gateway tile -> nil model",
     core.respawnSpec({ editor = "terminal", cwd = "/x/q", model = "gemini-2.5-pro", base_url = "http://localhost:4000" }, cfg).model, nil)
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

-- ---- #35-pin: per-TILE group entries can split one project queue -------------
-- Queue membership (queueKey) and the group axis were BOTH projectKey-keyed, so
-- every member of a queue necessarily shared one group and '@role:' routing could
-- never discriminate them (match-all or match-none). A session-key entry now wins
-- over the projectKey cohort in applyGroups, so one member of a folder can carry
-- its own role while its siblings keep the cohort tag.
do
  local list = {
    { key = "s1", name = "a", projectKey = "proj-x" },
    { key = "s2", name = "b", projectKey = "proj-x" },   -- same folder, same queue
  }
  core.applyGroups(list, { ["proj-x"] = "builders", ["s2"] = "reviewer" })
  eq("#35-pin: untagged member keeps the project cohort", list[1].group, "builders")
  eq("#35-pin: per-tile entry wins over the projectKey cohort", list[2].group, "reviewer")
  -- memberRole (the @role: axis) now differs WITHIN one project queue
  check("#35-pin: @role: axis discriminates queue members",
        core.memberRole(list[1]) == "builders" and core.memberRole(list[2]) == "reviewer")
  -- a per-tile entry alone (no cohort) resolves too, and setGroup can write it
  local solo = { { key = "s3", name = "c", projectKey = "proj-y" } }
  core.applyGroups(solo, core.setGroup({}, "s3", "docs"))
  eq("#35-pin: tile-keyed setGroup entry resolves for that session", solo[1].group, "docs")
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

-- ---- #7 sessionHistory: per-session records from the ledger ----------------
do
  local evs = {
    { ts = 10, type = "session_start", session_id = "s1", name = "alpha", projectKey = "pkA" },
    { ts = 20, type = "prompt",        session_id = "s1", prompt = "x" },
    { ts = 30, type = "tool_request",  session_id = "s1", tool = "Bash" },
    { ts = 35, type = "decision",      session_id = "s1", outcome = "allow" },
    { ts = 40, type = "decision",      session_id = "s1", outcome = "deny" },
    { ts = 50, type = "prompt",        session_id = "s2", name = "bravo", projectKey = "pkB" },
    { ts = 60, type = "prompt",        session_id = "s2" },
    { ts = 70, type = "prompt",        session_id = "s2" },
    { ts =  5, type = "prompt" },                                  -- no session_id -> ignored
  }
  local recent = core.sessionHistory(evs)
  eq("history: one record per session", #recent, 2)
  -- default sort = recent (s2 lastTs 70 > s1 lastTs 40)
  eq("history: recent sort newest first", recent[1].session_id, "s2")
  local s1 = recent[2]
  eq("history: name captured", s1.name, "alpha")
  eq("history: projectKey captured", s1.projectKey, "pkA")
  eq("history: firstTs", s1.firstTs, 10)
  eq("history: lastTs", s1.lastTs, 40)
  eq("history: lastType is the newest event's", s1.lastType, "decision")
  eq("history: event count", s1.events, 5)
  eq("history: prompts", s1.prompts, 1)
  eq("history: toolRequests", s1.toolRequests, 1)
  eq("history: allow", s1.allow, 1)
  eq("history: deny", s1.deny, 1)
  -- sort: oldest
  eq("history: oldest sort", core.sessionHistory(evs, { sort = "oldest" })[1].session_id, "s1")
  -- sort: active (s2 has 3 prompts > s1's 1 prompt + 1 tool = 2)
  eq("history: active sort by prompts+tools", core.sessionHistory(evs, { sort = "active" })[1].session_id, "s2")
  -- empty / no-session inputs
  eq("history: empty events -> none", #core.sessionHistory({}), 0)
  eq("history: events without session_id ignored", #core.sessionHistory({ { ts = 1, type = "prompt" } }), 0)
  -- tie-breaks: two events at the SAME ts -> the LATER one (in order) sets lastType (>= rule)
  local tie = core.sessionHistory({
    { ts = 200, type = "prompt",   session_id = "z" },
    { ts = 200, type = "decision", session_id = "z", outcome = "allow" },
  })
  eq("history: equal-ts lastType = later event (>= tie-break)", tie[1].lastType, "decision")
  -- R1-12: name/projectKey selection must be order-independent. The production caller
  -- (FX.sendHistory) feeds events NEWEST-first (filterLedger sorts ts desc). Feed the
  -- same shape and assert the LATEST non-empty name wins and the EARLIEST projectKey
  -- (the stable pin) is kept -- the old code inverted both on newest-first input.
  local newestFirst = core.sessionHistory({
    { ts = 30, type = "relabel", session_id = "h", name = "new-name", projectKey = "pkNew" },
    { ts = 20, type = "prompt",  session_id = "h", name = "mid-name", projectKey = "pkMid" },
    { ts = 10, type = "session_start", session_id = "h", name = "old-name", projectKey = "pkOrig" },
  })
  eq("history: newest-first input -> latest non-empty name wins", newestFirst[1].name, "new-name")
  eq("history: newest-first input -> earliest projectKey pinned", newestFirst[1].projectKey, "pkOrig")
  -- internal ts-trackers must not leak into the emitted record
  eq("history: _nameTs not emitted", newestFirst[1]._nameTs, nil)
  eq("history: _pkTs not emitted", newestFirst[1]._pkTs, nil)
  -- a blank name between two real ones must NOT override the latest real name
  local blankGap = core.sessionHistory({
    { ts = 30, type = "tool_request", session_id = "g" },               -- newest, no name
    { ts = 20, type = "prompt",  session_id = "g", name = "real-name" },
  })
  eq("history: blank newest event keeps the real name", blankGap[1].name, "real-name")
  -- active sort secondary key: equal activity (prompts+tools) -> the more RECENT lastTs wins
  -- (this branch was never hit when the two sessions differed on activity). p: 1 prompt +
  -- 1 tool @ lastTs 300; q: 2 prompts @ lastTs 200 -> both activity 2, so p (newer) sorts first.
  local sec = core.sessionHistory({
    { ts = 100, type = "prompt",       session_id = "p", name = "p" },
    { ts = 300, type = "tool_request", session_id = "p", tool = "Bash" },
    { ts = 150, type = "prompt",       session_id = "q", name = "q" },
    { ts = 200, type = "prompt",       session_id = "q" },
  }, { sort = "active" })
  eq("history: active-sort tie broken by newer lastTs", sec[1].session_id, "p")
  eq("history: active-sort tie second", sec[2].session_id, "q")

  -- localStorageReport: format + sort + total
  local rep = core.localStorageReport({
    { name = "ledger", bytes = 2 * 1024 * 1024 },
    { name = "queue", bytes = 512 },
    { name = "state", bytes = 1024 },
    { name = "bad" },                 -- no bytes -> skipped
    "not a table",                    -- skipped
  })
  eq("storage: skips entries without bytes", #rep.items, 3)
  eq("storage: sorted desc by bytes", rep.items[1].name, "ledger")
  eq("storage: smallest last", rep.items[3].name, "queue")
  eq("storage: human formatted", rep.items[1].human, "2.0 MB")
  eq("storage: total bytes", rep.totalBytes, 2 * 1024 * 1024 + 512 + 1024)
  eq("storage: empty -> zero total", core.localStorageReport({}).totalBytes, 0)

  -- sumDirBytes: skip . / .. self-entries + entries with no numeric size; sum the rest
  eq("sumdir: sums real entries, skips ./.. + sizeless + negative", core.sumDirBytes({
    { name = ".",  size = 4096 },
    { name = "..", size = 4096 },
    { name = "a.jsonl", size = 100 },
    { name = "b.jsonl", size = 250 },
    { name = "no-size" },            -- nil size -> skipped
    { name = "bad", size = -1 },     -- negative size -> skipped (locks the `s >= 0` guard)
  }), 350)
  eq("sumdir: empty/nil -> 0", core.sumDirBytes(nil), 0)
  -- matchStateFiles: only cc-*.json. `cc-.json` pins the `.*` (empty-middle) edge -- tightening
  -- to `.+` would silently drop it; the trailing 123 pins the `type(fn)=='string'` guard, which
  -- is load-bearing (without it `(123):match` throws, it doesn't just skip).
  local sf = core.matchStateFiles({ ".", "cc-.json", "cc-config.json", "cc-agents.json", "transcript.json", "cc-notes.txt", "notcc.json", 123 })
  eq("matchstate: count", #sf, 3)
  eq("matchstate: keeps cc-.json (.* empty middle)", sf[1], "cc-.json")
  eq("matchstate: keeps cc-config.json", sf[2], "cc-config.json")
  eq("matchstate: keeps cc-agents.json", sf[3], "cc-agents.json")
  eq("matchstate: skips non-string (type guard)", sf[4], nil)
  eq("matchstate: empty/nil -> none", #core.matchStateFiles(nil), 0)
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
  -- R1-13: auto_continue must narrate (was missing from NARRATE -> raw type fallback,
  -- a Lua<->JS twin drift in the Timeline / LLM-review text).
  check("notify: narrate auto_continue emoji + verb",
    core.narrateEvent({ type = "auto_continue" }):find("▶️", 1, true) ~= nil
    and core.narrateEvent({ type = "auto_continue" }):find("resumed after API error", 1, true) ~= nil)
  check("notify: narrate auto_continue is attempt-aware (mirrors JS evDesc)",
    core.narrateEvent({ type = "auto_continue", attempt = 2 }):find("attempt 2", 1, true) ~= nil)
  check("notify: auto_continue not a raw-type fallback",
    core.narrateEvent({ type = "auto_continue" }):find("• auto_continue", 1, true) == nil)
  -- R3-10: detail parity with the JS evDesc twin -- these types carry detail in non-default
  -- fields, so narrateEvent must surface them (not render a bare verb).
  check("R3-10: narrate loop includes Nx detail",
    core.narrateEvent({ type = "loop", repeats = 3 }):find("3x", 1, true) ~= nil)
  check("R3-10: narrate rule includes rule name",
    core.narrateEvent({ type = "rule", rule = "auto-merge" }):find("auto-merge", 1, true) ~= nil)
  check("R3-10: narrate queue_starved includes depth",
    core.narrateEvent({ type = "queue_starved", depth = 5 }):find("5 queued", 1, true) ~= nil)
  check("R3-10: narrate error uses reason (then message)",
    core.narrateEvent({ type = "error", reason = "timeout" }):find("timeout", 1, true) ~= nil
    and core.narrateEvent({ type = "error", message = "boom" }):find("boom", 1, true) ~= nil)
  check("R3-10: narrate auto_respawn_blocked uses reason (then outcome)",
    core.narrateEvent({ type = "auto_respawn_blocked", reason = "not respawnable here" }):find("not respawnable here", 1, true) ~= nil)
  -- R3-10: NARRATE is exposed for single-source injection (__NARRATE__); every NARRATE
  -- entry has [emoji, verb] so the JS twin can derive both.
  check("R3-10: M.NARRATE exposed for injection", type(core.NARRATE) == "table" and core.NARRATE.error ~= nil)
  check("R3-10: mode_skipped is in NARRATE (R3-08 twin)", core.NARRATE.mode_skipped ~= nil)
  -- R2-14: nudge content lives ONLY in e.text; the Lua fallback must include it
  -- (the JS evDesc twin already does) so the LLM review sees WHAT was nudged.
  check("R2-14: narrate nudge includes e.text content",
    core.narrateEvent({ type = "nudge", text = "run the tests" }):find("run the tests", 1, true) ~= nil)
  -- R2-15: the parity-added types render their rich verb (not a bare "• <type>").
  check("R2-15: narrate rule -> rich verb", core.narrateEvent({ type = "rule" }):find("rule fired", 1, true) ~= nil)
  check("R2-15: narrate queue_starved -> rich verb",
    core.narrateEvent({ type = "queue_starved" }):find("queued work waiting", 1, true) ~= nil)
  check("R2-15: rule not a raw-type fallback",
    core.narrateEvent({ type = "rule" }):find("• rule", 1, true) == nil)
  check("R2-15: queue_starved not a raw-type fallback",
    core.narrateEvent({ type = "queue_starved" }):find("• queue_starved", 1, true) == nil)
end

-- ---- #18-pin: usage_limit is a notification type -----------------------------
-- The plan-limit guard fires an OS banner + a usage_limit ledger event, but the
-- alert-type set was never extended, so the 🔔 history and the unseen badge
-- silently dropped every plan-limit warning ("exactly the set of things that
-- happened without you" -- which a passive usage-limit alert is).
do
  local evs = {
    { ts = 90, type = "usage_limit", window = "weekly", percent = 93 },
    { ts = 80, type = "escalation",  session_id = "s1" },
  }
  local n = core.notificationEvents(evs, {})
  eq("#18-pin: usage_limit events reach the notification history", #n, 2)
  eq("#18-pin: usage_limit kept newest-first", n[1].type, "usage_limit")
  eq("#18-pin: NOTIFY_TYPES carries usage_limit", core.NOTIFY_TYPES.usage_limit, true)
  eq("#18-pin: an unseen usage_limit counts toward the badge",
     core.unseenNotificationCount(n, 85), 1)
end

-- ---- SSH status bridge (roadmap #7): pure layer -----------------------------
do
  -- sshDest: the one dest formatter
  eq("bridge: dest user@host", core.sshDest({ host = "devbox", user = "adam" }), "adam@devbox")
  eq("bridge: dest host only", core.sshDest({ host = "devbox" }), "devbox")
  eq("bridge: dest nil host -> nil", core.sshDest({ user = "adam" }), nil)
  eq("bridge: dest empty host -> nil", core.sshDest({ host = "" }), nil)
  eq("bridge: dest non-table -> nil", core.sshDest("devbox"), nil)
  -- R1-34: host/user with shell metacharacters fail SAFE (nil) so dest can't inject
  -- when interpolated unquoted into the spawn shell string.
  eq("bridge: dest malicious host -> nil", core.sshDest({ host = "h; rm -rf ~ #" }), nil)
  eq("bridge: dest command-sub host -> nil", core.sshDest({ host = "$(curl evil)" }), nil)
  eq("bridge: dest malicious user -> nil", core.sshDest({ host = "h", user = "u;reboot" }), nil)
  eq("bridge: dest clean host.with-dashes ok", core.sshDest({ host = "dev-box.local" }), "dev-box.local")
  -- R2-24: dot-traversal host/user must fail SAFE -- the bridge derives a mirror-dir
  -- name from the dest, and a "." / ".." / "a..b" component would let rsync --delete
  -- traverse out of MIRROR_DIR (e.g. ns=".." -> ~/.claude). The clean dotted form above stays valid.
  eq("bridge: dest dotdot host -> nil", core.sshDest({ host = ".." }), nil)
  eq("bridge: dest dot host -> nil", core.sshDest({ host = "." }), nil)
  eq("bridge: dest embedded dotdot host -> nil", core.sshDest({ host = "a..b" }), nil)
  eq("bridge: dest dotdot user -> nil", core.sshDest({ host = "h", user = ".." }), nil)
  eq("bridge: malicious host -> sshWrap aborts to inner",
     core.sshWrap("claude", { host = "h;reboot" }), "claude")
  -- sshWrap still works through sshDest (regression)
  check("bridge: sshWrap unchanged", core.sshWrap("cd /p && claude", { host = "h", user = "u" })
    :find("^ssh %-t u@h ") ~= nil)
  -- sshHosts: gated on bridge.enabled, deduped, ns sanitized
  local cfgOff = { providers = { { id = "r", ssh = { host = "devbox", user = "adam" } } } }
  eq("bridge: hosts gated off by default", #core.sshHosts(cfgOff), 0)
  local cfgOn = { bridge = { enabled = true }, providers = {
    { id = "r1", ssh = { host = "devbox", user = "adam" } },
    { id = "r2", ssh = { host = "devbox", user = "adam" } },   -- same dest: deduped
    { id = "r3", ssh = { host = "gpu.local", user = "a" } },   -- distinct dest
    { id = "local1" },                                          -- no ssh: skipped
    { id = "bad", ssh = { user = "x" } },                       -- no host: skipped
    { id = "evil", ssh = { host = "h; rm -rf ~ #" } },          -- R1-34: rejected (unsafe)
    { id = "trav", ssh = { host = ".." } },                     -- R2-24: rejected (traversal)
  } }
  local hosts = core.sshHosts(cfgOn)
  eq("bridge: hosts deduped count (unsafe + traversal hosts dropped)", #hosts, 2)
  eq("bridge: host dest", hosts[1].dest, "adam@devbox")
  eq("bridge: ns from dest", hosts[1].ns, "adam_devbox")
  eq("bridge: nil cfg -> {}", #core.sshHosts(nil), 0)
  -- R1-25: two providers on the SAME host but different users must get DISTINCT ns
  -- (ns derived from dest, not host) so reconcileBridge's want[ns]=h can't drop one.
  local cfgCollide = { bridge = { enabled = true }, providers = {
    { id = "a", ssh = { host = "devbox", user = "adam" } },
    { id = "b", ssh = { host = "devbox", user = "root" } },
  } }
  local ch = core.sshHosts(cfgCollide)
  eq("bridge: two users one host -> 2 entries", #ch, 2)
  eq("bridge: distinct ns per dest",
     (ch[1].ns ~= ch[2].ns) and "distinct" or "collided", "distinct")
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
  -- R1-36: when a parallel hook cleared the pending block, fall back to top-level gate_nonce
  eq("bridge: decision uses gate_nonce when pending cleared",
     core.decisionContent("allow", '{"status":"approval","gate":"waiting","gate_nonce":"n-9"}'), "allow n-9")
  eq("bridge: pending.nonce still preferred over gate_nonce",
     core.decisionContent("allow", '{"gate_nonce":"top","pending":{"nonce":"n-1"}}'), "allow n-1")
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
  -- R3-09: there is no remote-keystroke transport, so the keystrokes flag NEVER unlocks
  -- nudge/stop/clear/compact -- restoring agreement with handleAction's R2-07 refusal.
  eq("bridge: keystrokes flag never unlocks nudge",
     core.remoteActionAllowed(rWait, "nudge", { keystrokes = true }), false)
  eq("bridge: keystrokes flag never unlocks stop",
     core.remoteActionAllowed(rWait, "stop", { keystrokes = true }), false)
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
    -- R1-07: a remote approval tile WITHOUT gate=='waiting' must NOT be bulk-approvable
    -- (no decision file to consume) -- this is the case the JS twin previously overcounted.
    { key = "devbox:r3", status = "approval", stale = false, remote = { host = "h" } },
  }
  local app = core.selectActionable(fleet, "approve")
  eq("bridge: bulk approve includes remote waiter, excludes gateless remote", #app, 2)
  eq("bridge: bulk approve excludes remote approval w/o gate",
     (function() for _, k in ipairs(app) do if k == "devbox:r3" then return "present" end end return "absent" end)(), "absent")
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
  -- R1-26: a remote approval tile WITHOUT gate=='waiting' must NOT fall through to
  -- actOnWindow (which would focus a LOCAL window matching the remote name + press
  -- Enter). handleAction returns nil and records NO op for it.
  local recR = newRecorder()
  eq("bridge: remote approve w/o gate -> nil (no local keystroke)",
     core.handleAction(recR.fx, { key = "devbox:r3", name = "remote-proj", remote = { host = "h" }, status = "approval" }, "approve"), nil)
  eq("bridge: remote approve w/o gate records NO op", recR.count(), 0)
  local recRd = newRecorder()
  eq("bridge: remote deny w/o gate -> nil", core.handleAction(recRd.fx,
     { key = "devbox:r3", name = "remote-proj", remote = { host = "h" }, status = "approval" }, "deny"), nil)
  eq("bridge: remote deny w/o gate records NO op", recRd.count(), 0)
  -- R2-07: the non-approve/deny window-effect branches (focus/stop/nudge/continue)
  -- must ALSO fail closed for a remote tile -- the rule engine, Stream Deck, and
  -- jump/cycle hotkey reach them without pre-gating, and they'd otherwise drive a
  -- LOCAL window matching the remote name. handleAction returns nil + records NO op.
  local remoteTile = { key = "devbox:r4", name = "remote-proj", remote = { host = "h" }, status = "working" }
  for _, act in ipairs({ "focus", "stop", "nudge", "continue" }) do
    local rrc = newRecorder()
    eq("R2-07: remote " .. act .. " -> nil", core.handleAction(rrc.fx, remoteTile, act, "some text"), nil)
    eq("R2-07: remote " .. act .. " records NO op", rrc.count(), 0)
  end
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
  -- #36: display-staleness no longer disqualifies -- hook-written status files go
  -- stale ~90s after Stop (the NORMAL between-turns state; see staleDuplicateKeys'
  -- header), so the old `stale -> false` pin made a whole project permanently
  -- unroutable minutes after its sessions finished. A genuinely DEAD done tile is
  -- caught by the delivery gate (feedTask finds no window -> task kept queued).
  eq("route-free: stale done stays routable (#36)",
     core.sessionFree(sess("a", "done", { stale = true }), {}), true)
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
  -- L4 conditional routing: a "@role:" prefix routes to a session whose GROUP matches
  eq("taskRoute: strips the prefix", select(2, core.taskRoute("@review: do the thing")), "do the thing")
  eq("taskRoute: role lowercased", (core.taskRoute("@Review: x")), "review")
  eq("taskRoute: no prefix -> nil role", core.taskRoute("just do it"), nil)
  eq("taskRoute: bare prefix -> no role", core.taskRoute("@review:"), nil)
  eq("taskRoute: bare prefix kept literal", select(2, core.taskRoute("@review:")), "@review:")
  eq("memberRole: group lowercased", core.memberRole({ group = "Review" }), "review")
  eq("memberRole: blank -> nil", core.memberRole({ group = "  " }), nil)
  local roled = { sess("rv", "done", { since = 50, group = "review" }),
                  sess("bd", "done", { since = 40, group = "build" }) }
  eq("route-pick: role restricts the pool", core.routePick(roled, { now = 100, role = "review" }), "rv")
  eq("route-pick: unmatched role -> nil", core.routePick(roled, { now = 100, role = "deploy" }), nil)
  eq("route-pick: no role -> longest-free across all", core.routePick(roled, { now = 100 }), "bd")
  local rq = { tasks = { "@review: ship it" }, routing = true }
  eq("route-task: labeled head -> matching group",
     core.routeTask(roled, rq, { globalOn = true, now = 100 }).key, "rv")
  eq("route-task: labeled head returns role",
     core.routeTask(roled, rq, { globalOn = true, now = 100 }).role, "review")
  eq("route-task: label with no matching member -> nil",
     core.routeTask(roled, { tasks = { "@deploy: x" }, routing = true }, { globalOn = true, now = 100 }), nil)
  eq("route-starved: labeled head, no matching free -> starved",
     core.queueStarved({ sess("bd", "done", { group = "build" }) },
       { tasks = { "@review: x" }, routing = true }, { minutes = 1, sinceTs = 0, now = 1000 }), true)
  -- L4 process modes: distribute (default) vs sequential (one routed task at a time)
  eq("mode: default distribute", core.queueRouteMode({ tasks = { "x" } }), "distribute")
  local seqQ = core.queueSetMode({ tasks = { "a", "b" }, routing = true }, "sequential")
  eq("mode: set sequential", core.queueRouteMode(seqQ), "sequential")
  eq("mode: preserves routing", core.queueRouted(seqQ), true)
  eq("mode: preserves tasks", table.concat(seqQ.tasks, ","), "a,b")
  eq("mode: setRouted preserves mode", core.queueRouteMode(core.queueSetRouted(seqQ, true)), "sequential")
  eq("mode: survives a pop", core.queueRouteMode(select(2, core.queuePop(seqQ))), "sequential")
  eq("mode: back to distribute", core.queueRouteMode(core.queueSetMode(seqQ, "distribute")), "distribute")
  eq("busy: working -> true", core.projectBusy({ sess("a", "working") }, {}), true)
  eq("busy: approval -> true", core.projectBusy({ sess("a", "approval") }, {}), true)
  eq("busy: all done -> false", core.projectBusy({ sess("a", "done"), sess("b", "done") }, {}), false)
  eq("busy: fresh pending -> true", core.projectBusy({ sess("a", "done") }, { pending = { a = 100 }, now = 110 }), true)
  eq("busy: expired pending -> false", core.projectBusy({ sess("a", "done") }, { pending = { a = 100 }, now = 200 }), false)
  local seqBusy = { sess("a", "done", { since = 50 }), sess("b", "working") }
  eq("route-seq: holds while a member works",
     core.routeTask(seqBusy, core.queueSetMode({ tasks = { "t" }, routing = true }, "sequential"),
       { globalOn = true, now = 100 }), nil)
  local seqIdle = { sess("a", "done", { since = 50 }), sess("b", "done", { since = 60 }) }
  eq("route-seq: feeds when the project is idle",
     core.routeTask(seqIdle, core.queueSetMode({ tasks = { "t" }, routing = true }, "sequential"),
       { globalOn = true, now = 100 }).key, "a")
  eq("route-dist: feeds despite a busy sibling (default)",
     core.routeTask(seqBusy, { tasks = { "t" }, routing = true }, { globalOn = true, now = 100 }).key, "a")
  -- R2-19: a STALE 'working' member must NOT count as in-flight (a dead/frozen session
  -- would otherwise hold a sequential queue forever behind a corpse).
  local seqStale = { sess("a", "done", { since = 50 }), sess("b", "working", { stale = true }) }
  eq("busy: stale working member is NOT in-flight",
     core.projectBusy(seqStale, {}), false)
  eq("route-seq: feeds past a STALE working sibling (not held by a corpse)",
     core.routeTask(seqStale, core.queueSetMode({ tasks = { "t" }, routing = true }, "sequential"),
       { globalOn = true, now = 100 }).key, "a")
  -- L4 join barriers: @all:/@any: hold a task until members finish
  eq("barrier: @all parses", (core.taskBarrier("@all: merge")), "all")
  eq("barrier: @all strips", select(2, core.taskBarrier("@all: merge")), "merge")
  eq("barrier: @any parses", (core.taskBarrier("@any: go")), "any")
  eq("barrier: @role is not a barrier", core.taskBarrier("@review: x"), nil)
  eq("barrier: bare @all is literal", core.taskBarrier("@all:"), nil)
  eq("barrier: composes with a role", select(2, core.taskBarrier("@all: @review: x")), "@review: x")
  -- R3-05: uppercase barrier is recognized (case-insensitive, mirroring role lowercasing)
  eq("barrier: @ALL parses (case-insensitive)", (core.taskBarrier("@ALL: merge")), "all")
  eq("barrier: @Any parses (case-insensitive)", (core.taskBarrier("@Any: go")), "any")
  -- an uppercase barrier strips to the bare body with NO spurious role
  eq("barrier: @ALL stripped body has no role",
     core.taskRoute(select(2, core.taskBarrier("@ALL: x"))), nil)
  -- R3-06: leading whitespace does not defeat barrier/role parsing
  eq("barrier: leading space tolerated", (core.taskBarrier("  @all: merge")), "all")
  eq("barrier: leading tab tolerated", (core.taskBarrier("\t@any: go")), "any")
  eq("route: leading space tolerated role", (core.taskRoute("  @review: x")), "review")
  eq("route: leading space stripped body", select(2, core.taskRoute("  @review: x")), "x")
  local allDone = { sess("a", "done"), sess("b", "done") }
  local oneWorking = { sess("a", "done"), sess("b", "working") }
  eq("barrier-met: all done -> all true", core.routeBarrierMet(allDone, "all"), true)
  eq("barrier-met: one working -> all false", core.routeBarrierMet(oneWorking, "all"), false)
  eq("barrier-met: one done -> any true", core.routeBarrierMet(oneWorking, "any"), true)
  eq("barrier-met: none done -> any false", core.routeBarrierMet({ sess("a", "working") }, "any"), false)
  eq("barrier-met: empty -> false", core.routeBarrierMet({}, "all"), false)
  -- #36: a stale DONE member is the normal between-turns state (hook-written status
  -- files go stale ~90s after Stop), NOT a corpse -- it is settled and routable
  -- (sessionFree no longer rejects stale), so it counts on both sides. The old
  -- exclusion made "@all:" forever-unsatisfiable (total==0 -> false) for a project
  -- whose members all finished >90s ago.
  eq("barrier-met: stale done counts as settled (#36)",
     core.routeBarrierMet({ sess("a", "done", { stale = true }) }, "all"), true)
  eq("#36-pin: @any: satisfiable by a long-done (display-stale) member",
     core.routeBarrierMet({ sess("a", "done", { stale = true }),
                            sess("b", "working") }, "any"), true)
  -- R2-18: a stale MID-TURN (working/approval -- died or froze mid-turn, can never
  -- settle) or remote sibling is EXCLUDED from the requirement, not a permanent
  -- blocker -- counting it would make @all forever-unmet.
  eq("barrier-met: stale sibling excluded -> all true",
     core.routeBarrierMet({ sess("a", "done"), sess("b", "working", { stale = true }) }, "all"), true)
  eq("barrier-met: remote sibling excluded -> all true",
     core.routeBarrierMet({ sess("a", "done"), sess("b", "done", { remote = { host = "h" } }) }, "all"), true)
  local bq = { tasks = { "@all: merge" }, routing = true }
  eq("route-barrier: @all holds while one works",
     core.routeTask(oneWorking, bq, { globalOn = true, now = 100 }), nil)
  eq("route-barrier: @all routes when all done",
     core.routeTask({ sess("a", "done", { since = 50 }), sess("b", "done", { since = 60 }) }, bq,
       { globalOn = true, now = 100 }).key, "a")
  eq("route-barrier: returns the barrier mode",
     core.routeTask(allDone, bq, { globalOn = true, now = 100 }).barrier, "all")
  eq("route-barrier: nested role honored after the barrier",
     core.routeTask({ sess("rv", "done", { since = 50, group = "review" }),
                      sess("bd", "done", { since = 40, group = "build" }) },
       { tasks = { "@all: @review: ship" }, routing = true }, { globalOn = true, now = 100 }).key, "rv")
  eq("route-barrier: blocked head is not starved",
     core.queueStarved(oneWorking, bq, { minutes = 1, sinceTs = 0, now = 1000 }), false)
  -- R1-18: routeFeedMatches re-validates the popped head against the chosen member so a
  -- queue reorder during the dispatch delay can't feed a role-mismatched task.
  local rvMember = sess("rv", "done", { since = 50, group = "review" })
  local bdMember = sess("bd", "done", { since = 40, group = "build" })
  local roleMembers = { rvMember, bdMember }
  eq("feed-match: head @review: matches a review member",
     core.routeFeedMatches(rvMember, "@review: ship", roleMembers), true)
  eq("feed-match: head @review: does NOT match a build member (reorder hazard)",
     core.routeFeedMatches(bdMember, "@review: ship", roleMembers), false)
  eq("feed-match: an unaddressed head matches any member",
     core.routeFeedMatches(bdMember, "plain task", roleMembers), true)
  eq("feed-match: an unmet barrier head refuses the feed",
     core.routeFeedMatches(rvMember, "@all: ship", oneWorking), false)
  eq("feed-match: a met barrier + role head feeds the right member",
     core.routeFeedMatches(rvMember, "@all: @review: ship", roleMembers), true)
  eq("feed-match: nil item -> false", core.routeFeedMatches(nil, "x", roleMembers), false)
  -- L4 per-task timing: fire on the first done edge after a feed, with the duration
  eq("task-done: fires on working->done edge",
     core.stepTaskDone({ ts = 100 }, "working", "done", 160).durationS, 60)
  eq("task-done: no start -> nil", core.stepTaskDone(nil, "working", "done", 160), nil)
  eq("task-done: not done yet -> nil", core.stepTaskDone({ ts = 100 }, "working", "working", 160), nil)
  eq("task-done: already done (no edge) -> nil", core.stepTaskDone({ ts = 100 }, "done", "done", 160), nil)
  eq("task-done: nil prev (post-reload) -> nil", core.stepTaskDone({ ts = 100 }, nil, "done", 160), nil)
  eq("task-done: clamps negative", core.stepTaskDone({ ts = 200 }, "working", "done", 100).durationS, 0)
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
  -- R1-16: a SEQUENTIAL queue with its one task in flight is PROGRESSING, not starved
  -- (the lone working member makes routePick nil, which the distribute path reads as
  -- starvation). The distribute queue with the same busy member still starves.
  local seqArmed = core.queueSetMode({ tasks = { "t" }, routing = true }, "sequential")
  eq("starve: sequential busy is NOT starved",
     core.queueStarved(busy, seqArmed, { minutes = 5, sinceTs = 100, now = 100 + 301 }), false)
  eq("starve: distribute busy (same member) still starves (control)",
     core.queueStarved(busy, armed, { minutes = 5, sinceTs = 100, now = 100 + 301 }), true)
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

-- ---- #20-pin: subagent transcript hits resolve to the PARENT session ---------
-- The recursive search reaches /projects/<ENC>/<sid>/subagents/agent-<id>.jsonl;
-- the old basename extraction yielded sessionId "agent-<id>" (which the ledger
-- keys nothing by) and a nil projectKey (two path segments follow <ENC>), so the
-- hit row rendered who="?" and its audit overlay opened empty.
do
  local hits = {
    { file = "/h/.claude/projects/-Users-a-proj/sid-123/subagents/agent-aad450.jsonl", line = 1, text = "s" },
    { file = "/h/.claude/projects/-Users-a-dead/sid-999/subagents/agent-ffff.jsonl", line = 2, text = "d" },
  }
  local items = { { key = "k1", name = "proj", label = "my proj",
                    transcript_path = "/h/.claude/projects/-Users-a-proj/sid-123.jsonl" } }
  core.annotateSearchHits(hits, items, "/h/.claude/cc-ledger")
  eq("#20-pin: subagent hit sessionId is the parent session", hits[1].sessionId, "sid-123")
  eq("#20-pin: subagent hit projectKey resolves", hits[1].projectKey, "-Users-a-proj")
  eq("#20-pin: subagent hit maps to the parent's live tile", hits[1].key, "k1")
  eq("#20-pin: subagent hit takes the tile label", hits[1].name, "my proj")
  eq("#20-pin: dead parent still yields the parent sessionId", hits[2].sessionId, "sid-999")
  eq("#20-pin: dead parent projectKey resolves", hits[2].projectKey, "-Users-a-dead")
  eq("#20-pin: dead parent has no tile key", hits[2].key, nil)
end

-- ---- #24-pin: maxPerFile caps HITS per file, not matching lines --------------
-- rg --max-count / grep -m limit matching LINES, but -o fans one dense line out
-- to a row per match -- transcript JSONL events are giant single lines, so one
-- file could flood the whole `limit` before any other file's rows were reached.
-- parseSearchResults enforces the real per-FILE cap.
do
  local fan = ("/a/dense.jsonl:1:hit\n"):rep(5) .. "/b/other.jsonl:2:hit\n"
  local r = core.parseSearchResults(fan)
  eq("#24-pin: default per-file cap 3 (5 fan-out rows -> 3)", #r.hits, 4)
  eq("#24-pin: the other file's row still gets through", r.hits[4].file, "/b/other.jsonl")
  eq("#24-pin: per-file overflow is not `truncated` (no limit hit)", r.truncated, false)
  local r1 = core.parseSearchResults(fan, { maxPerFile = 1 })
  eq("#24-pin: opts.maxPerFile honored", #r1.hits, 2)
  eq("#24-pin: first hit per file wins", r1.hits[1].file, "/a/dense.jsonl")
  -- the global limit check stays FIRST (pinned semantics: truncated flips when
  -- limit is reached even while a file is being per-file capped)
  local r2 = core.parseSearchResults(fan, { limit = 3 })
  eq("#24-pin: limit still caps and flags truncated", #r2.hits, 3)
  eq("#24-pin: truncated flag preserved", r2.truncated, true)
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

-- ---- liveBudgetKeys: the respawn-gap hold must survive across ticks (#4 fix) -----
-- The original #4 patch was WRONG (caught by the loop-2 fix-validation): it wiped
-- the hold whenever a tile reported the key, but the just-removed dead tile lingers
-- one tick in the caller's list, so the hold died the same tick it was set and the
-- retry budget was reaped during the relaunch gap -> maxRetries never bound. The
-- fix moves the decision here and expires holds by DEADLINE only. This test walks
-- the exact multi-tick timeline the bug needs.
do
  local deadTile = { session_id = "s1", cwd = "/p", kitty_listen_on = "unix:/s", kitty_window_id = "1" }
  local bk = core.budgetKey(deadTile)
  local holds = {}
  -- Tick T: spawn site charged attempts[bk] and set the hold (deadline in the future).
  holds[bk] = 1000 + 30
  -- Reap at T: the just-removed dead tile still lingers in `list` this tick.
  local liveT = core.liveBudgetKeys({ deadTile }, holds, 1000)
  check("liveBudgetKeys T: key is live during the same tick", liveT[bk] == true)
  check("liveBudgetKeys T: lingering dead tile does NOT wipe the hold", holds[bk] == 1030)
  -- Tick T+1: dead tile's files gone, successor not landed -> NO tile reports bk.
  -- Only the hold keeps it live; a counter backed solely by the hold must survive.
  local attempts = { [bk] = 1 }
  local liveT1 = core.liveBudgetKeys({}, holds, 1001)
  check("liveBudgetKeys T+1: hold carries the key across the gap", liveT1[bk] == true)
  core.reapUnbacked(attempts, liveT1)
  check("liveBudgetKeys T+1: charged retry survives the gap (maxRetries can bind)", attempts[bk] == 1)
  -- Deadline passes with no successor: expire the hold and reap the now-unbacked counter.
  local liveExp = core.liveBudgetKeys({}, holds, 2000)
  check("liveBudgetKeys: expired hold is cleared in place", holds[bk] == nil)
  check("liveBudgetKeys: expired hold no longer keeps the key live", liveExp[bk] == nil)
  core.reapUnbacked(attempts, liveExp)
  check("liveBudgetKeys: unbacked counter reaped once the hold expires", attempts[bk] == nil)
  -- A landed successor (its fresh tile carries the lineage bk) keeps the budget live.
  local succ = { session_id = "s2", budget_lineage = bk }
  check("liveBudgetKeys: landed successor (lineage) backs the key", core.liveBudgetKeys({ succ }, {}, 3000)[bk] == true)
end

-- ---- shouldAutoContinue: time-gated, capped resume of a frozen API error ----
do
  local function with(o)
    local a = { status = "error", elapsed = 100, minSeconds = 60, attempts = 0, maxAttempts = 3 }
    for k, v in pairs(o) do a[k] = v end
    return a
  end
  eq("autocont: fires once errored + past delay + under cap", core.shouldAutoContinue(with{}), true)
  eq("autocont: not before the grace delay", core.shouldAutoContinue(with{ elapsed = 30 }), false)
  eq("autocont: exactly at the delay -> fires", core.shouldAutoContinue(with{ elapsed = 60 }), true)
  eq("autocont: only the error state (working never)", core.shouldAutoContinue(with{ status = "working" }), false)
  eq("autocont: not on done", core.shouldAutoContinue(with{ status = "done" }), false)
  eq("autocont: disabled when maxAttempts 0", core.shouldAutoContinue(with{ maxAttempts = 0 }), false)
  eq("autocont: at cap -> stop", core.shouldAutoContinue(with{ attempts = 3, maxAttempts = 3 }), false)
  eq("autocont: under cap -> go", core.shouldAutoContinue(with{ attempts = 2, maxAttempts = 3 }), true)
  eq("autocont: nil args -> false", core.shouldAutoContinue(nil), false)
end

-- ---- stepAutoContinue: per-tile grace clock + per-window fire budget --------
-- R2-22: the budget is charged on CONFIRMED DELIVERY via chargeAutoContinue, not
-- inside stepAutoContinue's pure gate -- so a no-window-match tile that fires but
-- doesn't deliver never advances the cap. Tests simulate delivery by calling
-- chargeAutoContinue(state, step.budgetKey) after each fire.
do
  local st = { since = {}, attempts = {} }
  local function err(now) return core.stepAutoContinue(st,
    { key = "k1", projectKey = "pf", status = "error" },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = now }) end
  -- charge-on-delivery helper: fire AND deliver
  local function fired(now) local r = err(now); if r.fire then core.chargeAutoContinue(st, r.budgetKey) end; return r end

  -- the grace clock starts on first sighting; nothing fires until it elapses
  eq("step-cont: first error sighting does NOT fire", err(1000).fire, false)
  eq("step-cont: clock stamped at first sighting", st.since["k1"], 1000)
  eq("step-cont: still inside the grace delay -> no fire", err(1030).fire, false)
  eq("step-cont: no premature charge", st.attempts["pf"], nil)

  -- R2-22: a fired-but-UNDELIVERED attempt must NOT advance the budget (only the
  -- clock restarts so it re-spaces instead of re-firing every tick).
  local fu = err(1061)
  eq("step-cont: fires once past the grace delay", fu.fire, true)
  eq("R2-22: undelivered fire does NOT charge the budget", st.attempts["pf"], nil)
  eq("step-cont: fire restarts the grace clock", st.since["k1"], 1061)
  eq("step-cont: does not immediately re-fire next tick", err(1062).fire, false)

  -- a delivered fire (next window) DOES charge exactly one
  local f1 = fired(1122)
  eq("step-cont: delivered fire after another delay", f1.fire, true)
  eq("R2-22: delivered fire charges one attempt", st.attempts["pf"], 1)

  -- still errored a full delay later: second (final) delivered fire, then the cap binds
  eq("step-cont: second fire after another full delay", fired(1183).fire, true)
  eq("step-cont: budget climbs to the cap", st.attempts["pf"], 2)
  eq("step-cont: at cap -> no more fires even past the delay", err(1300).fire, false)
  eq("step-cont: capped budget holds", st.attempts["pf"], 2)

  -- a CLEAN completion resets the folder budget AND clears the tile clock; a still-dead
  -- connection that only flips to `working` (what the continue itself produces) must NOT
  -- reset, or the cap would never bind and it would loop forever.
  local stB = { since = { kb = 500 }, attempts = { pfb = 2 } }
  core.stepAutoContinue(stB, { key = "kb", projectKey = "pfb", status = "working" },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = 2000 })
  eq("step-cont: working clears the tile clock", stB.since["kb"], nil)
  eq("step-cont: working does NOT reset the folder budget (loop guard)", stB.attempts["pfb"], 2)
  core.stepAutoContinue(stB, { key = "kb", projectKey = "pfb", status = "done" },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = 2100 })
  eq("step-cont: a clean done resets the folder budget", stB.attempts["pfb"], nil)

  -- R3-23: a FAILED-read tick (statusKnown=false) on a frozen-error tile must NOT wipe
  -- the accumulated grace clock (status falls back to 'working' on a nil tail). The clock
  -- survives and elapsed keeps accumulating; a genuine known status still clears it.
  local stF = { since = { kf = 1000 }, attempts = {} }
  local rF = core.stepAutoContinue(stF, { key = "kf", projectKey = "pff", status = "working" },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = 1030, statusKnown = false })
  eq("step-cont: failed-read tick does NOT clear the grace clock", stF.since["kf"], 1000)
  eq("step-cont: failed-read tick does NOT fire", rF.fire, false)
  -- after the read recovers and the tile is still errored, the SAME clock fires past delay
  eq("step-cont: clock preserved across flicker fires past delay",
    core.stepAutoContinue(stF, { key = "kf", projectKey = "pff", status = "error" },
      { enabled = true, minSeconds = 60, maxAttempts = 2, now = 1100, statusKnown = true }).fire, true)
  -- a KNOWN non-error status (statusKnown true, the default) still clears the clock
  local stK = { since = { kk = 500 }, attempts = {} }
  core.stepAutoContinue(stK, { key = "kk", projectKey = "pfk", status = "working" },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = 2000, statusKnown = true })
  eq("step-cont: known working still clears the clock", stK.since["kk"], nil)

  -- disabled never fires and never writes; keyless tiles never nil-key write
  local stC = { since = {}, attempts = {} }
  eq("step-cont: disabled -> no fire", core.stepAutoContinue(stC,
    { key = "kc", projectKey = "pfc", status = "error" },
    { enabled = false, minSeconds = 60, maxAttempts = 2, now = 9000 }).fire, false)
  eq("step-cont: disabled past-delay -> no fire", core.stepAutoContinue(stC,
    { key = "kc", projectKey = "pfc", status = "error" },
    { enabled = false, minSeconds = 60, maxAttempts = 2, now = 9100 }).fire, false)
  eq("step-cont: disabled -> no charge", stC.attempts["pfc"], nil)
  eq("step-cont: keyless tile -> no fire", core.stepAutoContinue(stC,
    { projectKey = "pfc", status = "error" }, { enabled = true, minSeconds = 0, maxAttempts = 2, now = 1 }).fire, false)

  -- missing clock (opts.now == nil): the grace clock degrades to elapsed 0 -> never fires,
  -- never crashes (pins the implicit fail-closed behavior against a future refactor)
  local stN = { since = {}, attempts = {} }
  local rN = core.stepAutoContinue(stN, { key = "kn", projectKey = "pfn", status = "error" },
    { enabled = true, minSeconds = 60, maxAttempts = 3 })  -- no now
  eq("step-cont: nil now -> no fire", rN.fire, false)
  eq("step-cont: nil now -> elapsed 0", rN.elapsed, 0)

  -- THE anti-loop invariant, exercised as a natural sequence (not pre-seeded state): the
  -- `working` the continue itself produces must NOT reset the budget, or a still-dead
  -- connection that re-errors would loop forever past maxAttempts.
  local stL = { since = {}, attempts = {} }
  local function stepL(status, now) return core.stepAutoContinue(stL,
    { key = "kl", projectKey = "pfl", status = status },
    { enabled = true, minSeconds = 60, maxAttempts = 2, now = now }) end
  -- R2-22: fire AND deliver (charge) -- the dashboard charges only on a landed keystroke
  local function firedL(status, now) local r = stepL(status, now); if r.fire then core.chargeAutoContinue(stL, r.budgetKey) end; return r end
  stepL("error", 1000)                                   -- clock starts
  eq("step-cont(seq): first fire after the delay", firedL("error", 1061).fire, true)
  eq("step-cont(seq): budget at 1", stL.attempts["pfl"], 1)
  -- the continue drives the tile to `working`: clock clears, budget MUST hold
  eq("step-cont(seq): working does not fire", stepL("working", 1062).fire, false)
  eq("step-cont(seq): working held the budget at 1 (loop guard)", stL.attempts["pfl"], 1)
  -- still dead -> re-errors: a fresh clock, then the second fire COUNTS toward the cap
  stepL("error", 1100)                                   -- clock restarts on re-error
  eq("step-cont(seq): second fire counts toward the cap", firedL("error", 1161).fire, true)
  eq("step-cont(seq): budget at the cap", stL.attempts["pfl"], 2)
  stepL("error", 1300)
  eq("step-cont(seq): capped -> no further fires", stepL("error", 1400).fire, false)
  eq("step-cont(seq): cap holds (no runaway loop)", stL.attempts["pfl"], 2)

  -- R2-21: two parallel sessions in ONE folder but DIFFERENT terminal windows must keep
  -- INDEPENDENT budgets -- a healthy sibling's reset must not zero the crash-looper's count.
  eq("R2-21: budgetKey is per-window when kitty ids present",
     core.budgetKey({ projectKey = "pf", kitty_listen_on = "unix:/s", kitty_window_id = "1" }), "pf@unix:/s#1")
  eq("R2-21: budgetKey distinct per window",
     core.budgetKey({ projectKey = "pf", kitty_listen_on = "unix:/s", kitty_window_id = "2" }), "pf@unix:/s#2")
  eq("R2-21: budgetKey falls back to projectKey without kitty ids",
     core.budgetKey({ projectKey = "pf" }), "pf")
  -- respawn budget: two windows in one folder accumulate independently
  local aw = {}
  local function deadW(key, sid, wid) return { key = key, projectKey = "pf", status = "working",
    stale = true, updated = 300, session_id = sid, kitty_listen_on = "unix:/s", kitty_window_id = wid } end
  core.stepAutoRespawn(aw, deadW("w1a", "s1", "1"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, staleSeconds = 90, respawnStaleSeconds = 600, canRespawn = true })
  core.stepAutoRespawn(aw, deadW("w2a", "s2", "2"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, staleSeconds = 90, respawnStaleSeconds = 600, canRespawn = true })
  eq("R2-21: window 1 has its own budget", aw["pf@unix:/s#1"], 1)
  eq("R2-21: window 2 has a SEPARATE budget", aw["pf@unix:/s#2"], 1)
  -- a respawn reuses the SAME window -> the count carries across (new session_id, same wid)
  core.stepAutoRespawn(aw, deadW("w1b", "s1b", "1"), { enabled = true, maxRetries = 2, wasStale = false,
    now = 1000, staleSeconds = 90, respawnStaleSeconds = 600, canRespawn = true })
  eq("R2-21: respawn reusing the window keeps counting toward the cap", aw["pf@unix:/s#1"], 2)

  -- #19-pin: a kitty respawn does NOT reuse the window (fresh {kitty_pid} socket +
  -- window id), so the successor's per-window key never equalled the charged one
  -- and maxRetries could never bind. The spawner threads the predecessor's budget
  -- key through CC_SHEPHERD_LINEAGE -> cc-status.sh budget_lineage, and budgetKey
  -- PREFERS it, carrying the count across kitty generations.
  eq("#19-pin: budget_lineage wins over the fresh per-window key",
     core.budgetKey({ projectKey = "pf", budget_lineage = "pf@unix:/old#3",
                      kitty_listen_on = "unix:/new", kitty_window_id = "1" }), "pf@unix:/old#3")
  eq("#19-pin: empty lineage falls back to the R2-21 keying",
     core.budgetKey({ projectKey = "pf", budget_lineage = "",
                      kitty_listen_on = "unix:/s", kitty_window_id = "1" }), "pf@unix:/s#1")
  eq("#19-pin: non-string lineage ignored",
     core.budgetKey({ projectKey = "pf", budget_lineage = true }), "pf")
  -- end-to-end: gen-2 (new socket/wid, lineage = gen-1's key) continues the SAME
  -- budget entry, so the cap binds across generations instead of restarting at 0
  local gen2 = { key = "w1c", projectKey = "pf", status = "working", stale = true,
                 updated = 300, session_id = "s1c", budget_lineage = "pf@unix:/s#1",
                 kitty_listen_on = "unix:/gen2", kitty_window_id = "1" }
  local s2 = core.stepAutoRespawn(aw, gen2, { enabled = true, maxRetries = 5, wasStale = false,
    now = 1000, staleSeconds = 90, respawnStaleSeconds = 600, canRespawn = true })
  eq("#19-pin: lineage-carrying successor fires against the inherited budget", s2.spawn, true)
  eq("#19-pin: the charge lands on the inherited key (2 -> 3)", aw["pf@unix:/s#1"], 3)
  eq("#19-pin: no fresh per-window budget entry is minted", aw["pf@unix:/gen2#1"], nil)
  local s3 = core.stepAutoRespawn(aw, gen2, { enabled = true, maxRetries = 3, wasStale = false,
    now = 1000, staleSeconds = 90, respawnStaleSeconds = 600, canRespawn = true })
  eq("#19-pin: maxRetries binds across generations (capped -> no fire)", s3.spawn, false)
  eq("#19-pin: capped generation leaves the budget uncharged", aw["pf@unix:/s#1"], 3)
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

-- ---- nextAttention: who most needs the operator (approval>error>hung) -------
do
  local function S(name, status, hung) return { name = name, status = status, hung = hung } end
  local l = { S("a","approval"), S("b","error"), S("c","working",true), S("d","idle") }
  eq("nextAttention: approval wins", core.nextAttention(l).name, "a")
  eq("nextAttention: error beats hung when no approval",
     core.nextAttention({ S("b","error"), S("c","working",true) }).name, "b")
  eq("nextAttention: hung when only a stalled session",
     core.nextAttention({ S("d","idle"), S("c","working",true) }).name, "c")
  check("nextAttention: nil when nothing is wedged",
        core.nextAttention({ S("d","idle"), S("e","working"), S("f","done") }) == nil)
  check("nextAttention: nil/empty safe", core.nextAttention(nil) == nil and core.nextAttention({}) == nil)
  eq("nextAttention: front-most approval (list order, not a later one)",
     core.nextAttention({ S("a","approval"), S("z","approval") }).name, "a")
end

-- ---- fmtHotkey / hotkeyLegend: the ⌨ legend built from real bindings --------
do
  eq("fmtHotkey: cmd+alt+j -> macOS canonical ⌥⌘J", core.fmtHotkey({ "cmd", "alt" }, "j"), "⌥⌘J")
  eq("fmtHotkey: order-independent (input alt,cmd same as cmd,alt)",
     core.fmtHotkey({ "alt", "cmd" }, "j"), "⌥⌘J")
  eq("fmtHotkey: full canonical ⌃⌥⇧⌘ order",
     core.fmtHotkey({ "cmd", "shift", "ctrl", "alt" }, "k"), "⌃⌥⇧⌘K")
  eq("fmtHotkey: named key title-cased", core.fmtHotkey({ "cmd" }, "space"), "⌘Space")
  local legend = core.hotkeyLegend(
    { { mods = { "cmd", "alt" }, key = "j", desc = "Jump to who needs you" },
      { mods = { "cmd", "alt" }, key = "s", desc = "Spawn" } },
    { { combo = "Enter", desc = "Send" } })
  eq("hotkeyLegend: two sections (global + panel)", #legend, 2)
  eq("hotkeyLegend: global rows formatted from bindings", legend[1].rows[1].combo, "⌥⌘J")
  eq("hotkeyLegend: global desc carried", legend[1].rows[1].desc, "Jump to who needs you")
  eq("hotkeyLegend: panel rows passed through", legend[2].rows[1].combo, "Enter")
  eq("hotkeyLegend: empty panel section omitted",
     #core.hotkeyLegend({ { mods = { "cmd" }, key = "b", desc = "x" } }, nil), 1)
end

-- ---- resolveHotkeys: configurable global hotkeys (defaults + validation) ----
do
  local function combo(hk) return core.fmtHotkey(hk[1], hk[2]) end  -- {mods,key} -> display combo
  -- absent / nil / non-table hotkeys block -> the five ⌘⌥ defaults (no crash)
  local d = core.resolveHotkeys({})
  eq("resolveHotkeys: default approveFront", combo(d.approveFront), "⌥⌘A")
  eq("resolveHotkeys: default jumpNeedy",    combo(d.jumpNeedy),    "⌥⌘J")
  eq("resolveHotkeys: default cycle",        combo(d.cycle),        "⌥⌘N")
  eq("resolveHotkeys: default spawn",        combo(d.spawn),        "⌥⌘S")
  eq("resolveHotkeys: default toggle",       combo(d.toggle),       "⌥⌘B")
  eq("resolveHotkeys: nil cfg -> default",          combo(core.resolveHotkeys(nil).spawn), "⌥⌘S")
  eq("resolveHotkeys: non-table block -> default",  combo(core.resolveHotkeys({ hotkeys = "nope" }).toggle), "⌥⌘B")
  -- a valid override is applied; siblings keep their defaults
  local o = core.resolveHotkeys({ hotkeys = { approveFront = { mods = { "ctrl", "alt" }, key = "a" } } })
  eq("resolveHotkeys: override applied",       combo(o.approveFront), "⌃⌥A")
  eq("resolveHotkeys: siblings keep default",  combo(o.toggle),       "⌥⌘B")
  -- F-key with empty mods is the ONLY legal no-modifier binding
  eq("resolveHotkeys: F-key no-mods allowed",
     combo(core.resolveHotkeys({ hotkeys = { cycle = { mods = {}, key = "f13" } } }).cycle), "F13")
  eq("resolveHotkeys: F20 (top of range) no-mods allowed",
     combo(core.resolveHotkeys({ hotkeys = { cycle = { mods = {}, key = "f20" } } }).cycle), "F20")
  -- ...but a bare key outside F1..F20 is a dead key, not a binding -> revert to default:
  eq("resolveHotkeys: bare f0 (no such key) -> default",
     combo(core.resolveHotkeys({ hotkeys = { cycle = { mods = {}, key = "f0" } } }).cycle), "⌥⌘N")
  eq("resolveHotkeys: bare f25 (above F20) -> default",
     combo(core.resolveHotkeys({ hotkeys = { cycle = { mods = {}, key = "f25" } } }).cycle), "⌥⌘N")
  -- malformed entries each fall back to the default:
  eq("resolveHotkeys: unknown mod -> default",
     combo(core.resolveHotkeys({ hotkeys = { spawn = { mods = { "hyper" }, key = "s" } } }).spawn), "⌥⌘S")
  eq("resolveHotkeys: empty key -> default",
     combo(core.resolveHotkeys({ hotkeys = { jumpNeedy = { mods = { "cmd" }, key = "" } } }).jumpNeedy), "⌥⌘J")
  eq("resolveHotkeys: no-mod letter (can't bind globally) -> default",
     combo(core.resolveHotkeys({ hotkeys = { cycle = { mods = {}, key = "n" } } }).cycle), "⌥⌘N")
  eq("resolveHotkeys: non-table entry -> default",
     combo(core.resolveHotkeys({ hotkeys = { toggle = "b" } }).toggle), "⌥⌘B")
  -- mods are case-insensitive + de-duped (Command/Alt/alt -> ⌥⌘)
  eq("resolveHotkeys: mods case-insensitive + de-duped",
     combo(core.resolveHotkeys({ hotkeys = { spawn = { mods = { "Command", "Alt", "alt" }, key = "s" } } }).spawn), "⌥⌘S")
  -- the returned default is a FRESH copy: mutating one result can't poison the next call
  d.approveFront[1][#d.approveFront[1] + 1] = "shift"
  eq("resolveHotkeys: defaults not shared (fresh copy)", combo(core.resolveHotkeys({}).approveFront), "⌥⌘A")
end

-- ---- filterLedger projectKey + projectLineage + lineageSummary -------------
do
  local evs = {
    { ts = 100, type = "spawn",        projectKey = "P", session_id = "s1", name = "alpha" },
    { ts = 110, type = "prompt",       projectKey = "P", session_id = "s1", name = "alpha" },
    { ts = 120, type = "auto_respawn", projectKey = "P", session_id = "s1", name = "alpha" },
    { ts = 130, type = "prompt",       projectKey = "P", session_id = "s2", name = "alpha" },
    { ts = 140, type = "clear",        projectKey = "P", session_id = "s2", name = "alpha" },
    { ts = 150, type = "prompt",       projectKey = "Q", session_id = "s9", name = "other" },
    { ts =  50, type = "prompt",       projectKey = "P", session_id = "s0", name = "alpha" }, -- before window
  }
  local pOnly = core.filterLedger(evs, { projectKey = "P" })
  eq("filterLedger: projectKey slices one project", #pOnly, 6)
  check("filterLedger: projectKey excludes other projects",
        (function() for _, e in ipairs(pOnly) do if e.projectKey ~= "P" then return false end end return true end)())

  local lin = core.projectLineage(evs, "P", { sinceTs = 100 })
  eq("projectLineage: distinct sessions in window", lin.sessionCount, 2)  -- s1, s2 (s0 is pre-window)
  eq("projectLineage: auto-respawns counted", lin.autoRespawns, 1)
  eq("projectLineage: clears counted", lin.clears, 1)
  eq("projectLineage: ignores other projects (Q)", lin.counts.prompt or 0, 0)
  check("projectLineage: nil projectKey -> nil", core.projectLineage(evs, nil) == nil)

  eq("lineageSummary: formats sessions + churn",
     core.lineageSummary({ sessionCount = 3, autoRespawns = 2, clears = 1 }),
     "3rd session today · 2 auto-respawns · 1 clear")
  eq("lineageSummary: singular churn unit",
     core.lineageSummary({ sessionCount = 2, autoRespawns = 1 }),
     "2nd session today · 1 auto-respawn")
  check("lineageSummary: nil when nothing notable",
        core.lineageSummary({ sessionCount = 1 }) == nil)
  eq("lineageSummary: ordinal 11th not 11st",
     core.lineageSummary({ sessionCount = 11, clears = 1 }), "11th session today · 1 clear")
  eq("lineageSummary: ordinal 21st",
     core.lineageSummary({ sessionCount = 21, clears = 1 }), "21st session today · 1 clear")

  -- lineageByProject: one pass -> map for ALL projects (drives per-tile badges)
  local m = core.lineageByProject(evs, 100)
  eq("lineageByProject: P session count", m["P"].sessionCount, 2)
  eq("lineageByProject: P auto-respawns", m["P"].autoRespawns, 1)
  eq("lineageByProject: P clears", m["P"].clears, 1)
  eq("lineageByProject: Q present (one session)", m["Q"].sessionCount, 1)
  -- the pre-window session s0@50 is excluded by sinceTs=100 (P counts s1,s2 only).
  -- Re-run with a wider window: s0 now counts -> P=3, proving the boundary actually
  -- filters, rather than the count of 2 merely reflecting a missing fixture row.
  eq("lineageByProject: wider window includes pre-window s0 (P=3)",
     core.lineageByProject(evs, 0)["P"].sessionCount, 3)
  -- projectLineage now delegates to lineageByProject -> identical numbers
  eq("projectLineage: delegates (sessions match map)", core.projectLineage(evs, "P", { sinceTs = 100 }).sessionCount, m["P"].sessionCount)
  eq("projectLineage: unknown project -> zeroed lineage", core.projectLineage(evs, "ZZ", { sinceTs = 100 }).sessionCount, 0)
end

-- ---- fleetStandup: ops-only shift report -----------------------------------
do
  local evs = {
    { ts = 200, type = "spawn",        projectKey = "P", session_id = "s1", name = "alpha" },
    { ts = 210, type = "prompt",       projectKey = "P", session_id = "s1", name = "alpha" },
    { ts = 220, type = "decision",     projectKey = "P", session_id = "s1", name = "alpha", outcome = "deny",  by = "human" },
    { ts = 230, type = "decision",     projectKey = "P", session_id = "s1", name = "alpha", outcome = "allow", by = "router" },
    -- R2-13: routed feeds are DELIVERED task_feed events (by=router), not decisions.
    { ts = 235, type = "task_feed",    projectKey = "P", session_id = "s1", name = "alpha", by = "router", task = "do x" },
    { ts = 236, type = "task_feed_skipped", projectKey = "P", session_id = "s1", name = "alpha", by = "router", task = "skip me" },
    { ts = 240, type = "auto_respawn", projectKey = "P", session_id = "s2", name = "alpha" },
    { ts = 250, type = "escalation",   projectKey = "Q", session_id = "s9", name = "beta", minutes = 6 },
    { ts = 260, type = "prompt",       projectKey = "Q", session_id = "s9", name = "beta" },
    { ts = 270, type = "task_done",    projectKey = "P", session_id = "s1", name = "alpha", durationS = 30, by = "router" },
    { ts = 280, type = "task_done",    projectKey = "Q", session_id = "s9", name = "beta",  durationS = 90, by = "autofeed" },
    { ts =  10, type = "prompt",       projectKey = "P", session_id = "s0", name = "alpha" }, -- before window
  }
  local r = core.fleetStandup(evs, { sinceTs = 200 })
  check("fleetStandup: not empty with events in window", r.empty == false)
  eq("fleetStandup: deny counted", r.decisions.deny, 1)
  eq("fleetStandup: allow counted", r.decisions.allow, 1)
  eq("fleetStandup: provenance records who decided (router)", r.provenance.router, 1)
  eq("fleetStandup: auto-respawn tallied", r.autoActions.auto_respawn, 1)
  -- R2-13: only the DELIVERED task_feed counts; task_feed_skipped does NOT.
  eq("fleetStandup: routed feeds counted (delivered only)", r.autoActions.routed, 1)
  eq("fleetStandup: escalation problem tallied", r.problems.escalation, 1)
  eq("fleetStandup: pre-window event excluded (prompts=alpha1+beta1)", r.totals.prompts, 2)
  check("fleetStandup: byProject rollup present", #r.byProject >= 2)
  eq("fleetStandup: task_done count", r.tasks.done, 2)
  eq("fleetStandup: task_done total seconds", r.tasks.totalSeconds, 120)
  eq("fleetStandup: task_done avg seconds", r.tasks.avgSeconds, 60)
  local empty = core.fleetStandup({}, { sinceTs = 0 })
  check("fleetStandup: empty window flagged", empty.empty == true)

  -- standupMarkdown: the <pre> body + Copy share this render
  local md = core.standupMarkdown(r, { windowLabel = "since open" })
  check("standupMarkdown: carries the window label", md:find("since open", 1, true) ~= nil)
  check("standupMarkdown: reports approvals line", md:find("1 allow / 1 deny", 1, true) ~= nil)
  check("standupMarkdown: lists provenance (router)", md:find("router", 1, true) ~= nil)
  check("standupMarkdown: reports routed tasks completed", md:find("Routed tasks completed: 2", 1, true) ~= nil)
  check("standupMarkdown: by-project section present", md:find("By project:", 1, true) ~= nil)
  local mdEmpty = core.standupMarkdown(core.fleetStandup({}, { sinceTs = 0 }), { windowLabel = "8h" })
  check("standupMarkdown: empty window explains the ledger", mdEmpty:find("ledger must be enabled", 1, true) ~= nil)
end

-- ---- L1: Agent Profiles registry -------------------------------------------
do
  -- validateAgent: required + shape + unknown-field + cross-refs
  check("validateAgent: missing name", core.validateAgent({}).ok == false)
  check("validateAgent: ok minimal", core.validateAgent({ name = "rev" }).ok == true)
  check("validateAgent: relative folder rejected",
    core.validateAgent({ name = "a", folder = "rel/path" }).ok == false)
  check("validateAgent: absolute folder ok",
    core.validateAgent({ name = "a", folder = "/abs" }).ok == true)
  check("validateAgent: array field must be a list",
    core.validateAgent({ name = "a", skills = "nope" }).ok == false)
  check("validateAgent: unknown field flagged",
    core.validateAgent({ name = "a", bogus = 1 }).ok == false)
  local xref = core.validateAgent({ name = "a", provider = "missing", mcpServers = { "x" } },
    { providers = {}, mcp = {} })
  check("validateAgent: cross-ref provider not found", xref.ok == false and #xref.errors == 2)

  -- agentPush/List/Get/Remove: strict save, replace-in-place, drop malformed
  local st = { agents = {} }
  local saved
  st, saved = core.agentPush(st, { name = "reviewer", role = "a senior reviewer",
    provider = "claude", skills = { "code-review" } })
  check("agentPush: saved valid", saved == true)
  st = (core.agentPush(st, { name = "builder", folder = "/work" }))
  eq("agentList: two agents", #core.agentList(st), 2)
  check("agentGet: by name", core.agentGet(st, "reviewer").role == "a senior reviewer")
  local _, bad = core.agentPush(st, { name = "" })
  check("agentPush: rejects invalid (no name)", bad == false)
  st = (core.agentPush(st, { name = "reviewer", role = "updated" }))
  eq("agentPush: replace-in-place (still 2)", #core.agentList(st), 2)
  check("agentPush: in-place updated value", core.agentGet(st, "reviewer").role == "updated")
  st = core.agentRemove(st, "builder")
  eq("agentRemove: one left", #core.agentList(st), 1)

  -- agentLoad fail-safe: drop the bad, keep the good, report the drop
  local rep = core.agentLoad({ agents = { { name = "good" }, { name = "" }, { name = "good" } } })
  eq("agentLoad: one valid kept", #rep.valid, 1)
  eq("agentLoad: two errors (blank + dup)", #rep.errors, 2)

  -- agentFork: unique name + lineage stamp
  local fk = (core.agentFork(st, "reviewer"))
  check("agentFork: copy exists", core.agentGet(fk, "reviewer (copy)") ~= nil)
  check("agentFork: lineage stamped", core.agentGet(fk, "reviewer (copy)").forkedFrom == "reviewer")

  -- agentSort: favorite-first then name
  local list = { { name = "zed" }, { name = "amy", favorite = true }, { name = "bob" } }
  local sorted = core.agentSort(list, "favorite")
  eq("agentSort: favorite first", sorted[1].name, "amy")
  eq("agentSort: name order", core.agentSort(list, "name")[1].name, "amy")

  -- agentSetFlag: toggles favorite/hidden/archived, preserving every other field
  local fstate = { agents = { { name = "rev", role = "r", skills = { "a", "b" },
    mcpServers = { "linear" }, knowledge = { "/k" }, provider = "p" } } }
  local fav = core.agentSetFlag(fstate, "rev", "favorite", true)
  eq("agentSetFlag: favorite set", core.agentGet(fav, "rev").favorite, true)
  eq("agentSetFlag: preserves skills", #core.agentGet(fav, "rev").skills, 2)
  eq("agentSetFlag: preserves mcp", core.agentGet(fav, "rev").mcpServers[1], "linear")
  eq("agentSetFlag: archive toggles independently",
     core.agentGet(core.agentSetFlag(fav, "rev", "archived", true), "rev").archived, true)
  eq("agentSetFlag: unfavorite", core.agentGet(core.agentSetFlag(fav, "rev", "favorite", false), "rev").favorite, false)
  eq("agentSetFlag: unknown flag no-op", #core.agentList(core.agentSetFlag(fstate, "rev", "bogus", true)), 1)
  check("agentSetFlag: unknown flag leaves record unchanged",
     core.agentGet(core.agentSetFlag(fstate, "rev", "bogus", true), "rev").favorite ~= true)
  eq("agentSetFlag: missing name no-op", #core.agentList(core.agentSetFlag(fstate, "nope", "favorite", true)), 1)
end

-- ---- L1: MCP registry + mcp-config -----------------------------------------
do
  check("validateMcp: stdio needs command",
    core.validateMcp({ id = "x", transport = "stdio" }).ok == false)
  check("validateMcp: stdio ok",
    core.validateMcp({ id = "x", transport = "stdio", command = "npx" }).ok == true)
  check("validateMcp: http needs url",
    core.validateMcp({ id = "x", transport = "http" }).ok == false)
  check("validateMcp: bad transport",
    core.validateMcp({ id = "x", transport = "carrier-pigeon", command = "x" }).ok == false)

  local m = { servers = {} }
  m = (core.mcpPush(m, { id = "linear", transport = "sse", url = "https://mcp.linear.app/sse" }))
  m = (core.mcpPush(m, { id = "local", transport = "stdio", command = "npx",
    args = { "-y", "srv" }, authTokenEnv = "MY_TOKEN" }))
  eq("mcpList: two servers", #core.mcpList(m), 2)
  check("mcpGet: by id", core.mcpGet(m, "linear").transport == "sse")

  local cfg = core.mcpConfig(core.mcpList(m))
  check("mcpConfig: stdio command", cfg.mcpServers["local"].command == "npx")
  check("mcpConfig: stdio env ref", cfg.mcpServers["local"].env.MY_TOKEN == "${MY_TOKEN}")
  check("mcpConfig: sse type+url", cfg.mcpServers["linear"].type == "sse"
    and cfg.mcpServers["linear"].url == "https://mcp.linear.app/sse")
end

-- ---- Installed MCP + skills INVENTORY (read-only 🔌 viewer) -----------------
do
  -- extractInstalledMcp: user + per-project mcpServers, deduped, NO env exposed
  local cj = {
    mcpServers = {
      context7 = { type = "stdio", command = "npx", args = { "-y", "@upstash/context7-mcp" } },
      playwright = { command = "npx", args = { "-y", "@playwright/mcp@latest" } },
    },
    projects = {
      ["/Users/adam"] = { mcpServers = {
        playwright = { command = "npx", args = { "@playwright/mcp@latest", "--isolated" } },  -- also user
        github = { command = "docker", args = { "run", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN" },
                   env = { GITHUB_PERSONAL_ACCESS_TOKEN = "ghp_SECRET_VALUE" } },
        unity = { url = "http://localhost:8080/mcp", type = "http" },
      } },
    },
  }
  local mcp = core.extractInstalledMcp(cj)
  local byName = {}; for _, e in ipairs(mcp) do byName[e.name] = e end
  eq("extractInstalledMcp: deduped count", #mcp, 4)  -- context7, playwright, github, unity
  eq("extractInstalledMcp: user scope", byName.context7.scope, "user")
  eq("extractInstalledMcp: dual scope merged", byName.playwright.scope, "user+project")
  eq("extractInstalledMcp: project scope", byName.github.scope, "project")
  eq("extractInstalledMcp: stdio detail = command+args", byName.context7.detail, "npx -y @upstash/context7-mcp")
  eq("extractInstalledMcp: http transport from url", byName.unity.transport, "http")
  eq("extractInstalledMcp: url detail", byName.unity.detail, "http://localhost:8080/mcp")
  check("extractInstalledMcp: NEVER leaks env values",
    not byName.github.detail:find("SECRET") and not byName.github.detail:find("ghp_"))
  eq("extractInstalledMcp: nil input -> empty", #core.extractInstalledMcp(nil), 0)
  check("extractInstalledMcp: sorted by name", mcp[1].name == "context7")

  -- parseMcpListOutput: the real `claude mcp list` format
  local raw = table.concat({
    "Checking MCP server health…",
    "",
    "claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected",
    "claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ! Needs authentication",
    "playwright: npx @playwright/mcp@latest --isolated - ✔ Connected",
    "github: docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server - ✘ Failed to connect",
    "UnityMCP: http://localhost:8080/mcp (HTTP) - ✘ Failed to connect",
    "",
    "MCP Config Diagnostics",
    "",
    " └ [Warning] Server \"playwright\" defined in multiple scopes",
  }, "\n")
  local live = core.parseMcpListOutput(raw)
  local lByName = {}; for _, e in ipairs(live) do lByName[e.name] = e end
  eq("parseMcpListOutput: server count (diagnostics excluded)", #live, 5)
  eq("parseMcpListOutput: connector name stripped", lByName["Google Drive"].connector, true)
  eq("parseMcpListOutput: connected status", lByName.playwright.status, "connected")
  eq("parseMcpListOutput: failed status", lByName.github.status, "failed")
  eq("parseMcpListOutput: needs-auth status", lByName.Gmail.status, "needs-auth")
  eq("parseMcpListOutput: detail keeps full command", lByName.playwright.detail, "npx @playwright/mcp@latest --isolated")
  eq("parseMcpListOutput: detail splits on LAST ' - '",
     lByName.github.detail, "docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server")
  eq("parseMcpListOutput: header line ignored", lByName["Checking MCP server health…"], nil)

  -- mergeMcpStatus: config gains live status; connectors appended
  local merged = core.mergeMcpStatus(
    { { name = "playwright", scope = "user+project", transport = "stdio", detail = "npx …" },
      { name = "github", scope = "project", transport = "stdio", detail = "docker …" } },
    live)
  local mByName = {}; for _, e in ipairs(merged) do mByName[e.name] = e end
  eq("mergeMcpStatus: config gets live status", mByName.playwright.status, "connected")
  eq("mergeMcpStatus: config keeps its scope", mByName.github.scope, "project")
  eq("mergeMcpStatus: connector added as connector scope", mByName["Google Drive"].scope, "connector")
  check("mergeMcpStatus: nil live -> unknown status",
    core.mergeMcpStatus({ { name = "x", scope = "user", transport = "stdio", detail = "y" } }, nil)[1].status == "unknown")

  -- builtin skills catalog
  check("builtinSkillCards: non-empty", #core.builtinSkillCards() > 0)
  check("builtinSkillCards: command is /name", core.builtinSkillCards()[1].command:match("^/") ~= nil)
  check("builtinSkillCards: flagged builtin", core.builtinSkillCards()[1].builtin == true)

  -- CLI tools inventory (🔌 viewer "CLI tools" section)
  local toolByBin = {}
  for _, t in ipairs(core.CLI_TOOLS) do toolByBin[t.bin] = t end
  check("cliTools: includes the rg + fd search accelerators", toolByBin.rg ~= nil and toolByBin.fd ~= nil)
  check("cliTools: jq flagged required (the one hard dep)", toolByBin.jq and toolByBin.jq.required == true)
  eq("cliTools: rg degrades to grep", toolByBin.rg.fallback, "grep")
  eq("cliTools: fd degrades to find", toolByBin.fd.fallback, "find")
  -- isInstalledPath: the single-source install rule (absolute path => installed). Pure.
  check("isInstalledPath: absolute path => true", core.isInstalledPath("/opt/bin/jq") == true)
  check("isInstalledPath: bare name => false", core.isInstalledPath("rg") == false)
  check("isInstalledPath: relative path => false", core.isInstalledPath("./jq") == false)
  check("isInstalledPath: nil => false", core.isInstalledPath(nil) == false)
  check("isInstalledPath: empty string => false", core.isInstalledPath("") == false)
  -- cliToolCards: a bare-name resolved value (PATH-relative, never absolute) => missing
  check("cliToolCards: bare-name resolve => missing", core.cliToolCards({ rg = "rg" })[1] ~= nil
        and (function() for _, c in ipairs(core.cliToolCards({ rg = "rg" })) do if c.bin == "rg" then return c.installed == false end end end)())
  -- cliToolCards: an ABSOLUTE resolved path => installed (+ path surfaced)
  local cards = core.cliToolCards({ jq = "/opt/homebrew/bin/jq", rg = "/usr/local/bin/rg" })
  eq("cliToolCards: one card per catalog tool", #cards, #core.CLI_TOOLS)
  local cc = {}; for _, c in ipairs(cards) do cc[c.bin] = c end
  check("cliToolCards: resolved abs path => installed", cc.jq.installed == true)
  eq("cliToolCards: installed surfaces the path", cc.jq.path, "/opt/homebrew/bin/jq")
  check("cliToolCards: rg installed too", cc.rg.installed == true)
  -- a tool absent from the resolved map => missing, no path, fallback preserved
  check("cliToolCards: absent tool => missing", cc.fd.installed == false)
  eq("cliToolCards: missing tool has no path", cc.fd.path, nil)
  eq("cliToolCards: missing tool keeps its fallback", cc.fd.fallback, "find")
  -- required / optional flags ride through to the card
  check("cliToolCards: jq required flag", cc.jq.required == true)
  check("cliToolCards: ffmpeg optional flag", cc.ffmpeg.optional == true)
  -- a BARE-NAME resolve (resolveBin's not-found fallback) is NOT "installed"
  local cards2 = core.cliToolCards({ rg = "rg" })
  local cc2 = {}; for _, c in ipairs(cards2) do cc2[c.bin] = c end
  check("cliToolCards: bare-name resolve is not installed", cc2.rg.installed == false)
  -- nil / garbage resolved map => every tool missing (no crash)
  local cards3 = core.cliToolCards(nil)
  local anyInstalled = false
  for _, c in ipairs(cards3) do if c.installed then anyInstalled = true end end
  check("cliToolCards: nil resolved => all missing", (not anyInstalled) and #cards3 == #core.CLI_TOOLS)

  -- extractInstalledMcp fallbacks: a server with neither command nor url, and an
  -- explicit type that overrides url-based transport inference
  local cj2 = { mcpServers = {
    broken = { type = "stdio" },                                   -- no command, no url
    linear = { url = "https://mcp.linear.app/sse", type = "sse" }, -- explicit type wins
  } }
  local m2 = {}; for _, e in ipairs(core.extractInstalledMcp(cj2)) do m2[e.name] = e end
  eq("extractInstalledMcp: no command/url -> detail '?'", m2.broken.detail, "?")
  eq("extractInstalledMcp: no command/url -> transport from type", m2.broken.transport, "stdio")
  eq("extractInstalledMcp: explicit type beats url inference", m2.linear.transport, "sse")

  -- parseMcpListOutput remaining status branches + the statusless-line contract
  eq("parseMcpListOutput: pending status", core.parseMcpListOutput("x: cmd - ⏸ Pending approval")[1].status, "pending")
  eq("parseMcpListOutput: unrecognized status -> unknown", core.parseMcpListOutput("x: cmd - ✦ weird state")[1].status, "unknown")
  -- a line with no ' - <status>' is NOT a server line -> dropped (locks the contract:
  -- claude mcp list health-checks every server, so a real server line always has one)
  eq("parseMcpListOutput: statusless line dropped", #core.parseMcpListOutput("noStatusServer: just a detail here"), 0)

  -- mergeMcpStatus live-only inference + config-absent-from-NONEMPTY-live (distinct
  -- code path from the nil-live 'unknown' already covered above)
  local loHttp = core.mergeMcpStatus({}, { { name = "remote", status = "connected", connector = false, detail = "https://x/mcp" } })
  eq("mergeMcpStatus: live-only scope 'other'", loHttp[1].scope, "other")
  eq("mergeMcpStatus: live-only http transport from url", loHttp[1].transport, "http")
  local loStdio = core.mergeMcpStatus({}, { { name = "loc", status = "failed", connector = false, detail = "npx foo" } })
  eq("mergeMcpStatus: live-only non-url -> stdio", loStdio[1].transport, "stdio")
  local absent = core.mergeMcpStatus(
    { { name = "absent", scope = "user", transport = "stdio", detail = "x" } },
    { { name = "elsewhere", status = "connected" } })
  local aById = {}; for _, e in ipairs(absent) do aById[e.name] = e end
  eq("mergeMcpStatus: config absent from non-empty live stays unknown", aById.absent.status, "unknown")
end

-- ---- parseSkillFrontmatter: YAML folded/block scalars + inline values --------
do
  -- folded scalar ">-" (the rune / deno-fresh2 SKILL.md shape): value is the
  -- following indented lines folded to one line, NOT the literal ">-".
  local folded = "---\nname: rune\ndescription: >-\n  Author .rune specs and generate\n  code with the toolchain.\n---\nbody"
  local f = core.parseSkillFrontmatter(folded, "rune")
  eq("frontmatter: folded name", f.name, "rune")
  eq("frontmatter: folded description joined", f.description, "Author .rune specs and generate code with the toolchain.")
  check("frontmatter: folded never leaves the >- indicator", f.description ~= ">-" and not f.description:find(">%-"))
  -- literal block scalar "|"
  local lit = core.parseSkillFrontmatter("---\nname: x\ndescription: |\n  line one\n  line two\n---", "x")
  eq("frontmatter: literal block joined", lit.description, "line one line two")
  -- plain inline value still works (regression)
  local inline = core.parseSkillFrontmatter("---\nname: improve\ndescription: Apply cards. Usage: /improve\n---", "improve")
  eq("frontmatter: inline description", inline.description, "Apply cards. Usage: /improve")
  -- quoted inline value still unwrapped (regression)
  local q = core.parseSkillFrontmatter('---\nname: y\ndescription: "quoted desc"\n---', "y")
  eq("frontmatter: quoted inline unwrapped", q.description, "quoted desc")
  -- no frontmatter -> name falls back to stem, no description
  local none = core.parseSkillFrontmatter("just a prompt body, no fence", "triage-email")
  eq("frontmatter: stem fallback name", none.name, "triage-email")
  check("frontmatter: no description when absent", none.description == nil)
end

-- ---- In-app worklist (generic + per-project checklists) ---------------------
do
  local st = { generic = {}, byProject = {} }
  -- add to generic + a project scope
  core.worklistAdd(st, "generic", "call the bank", "g1", 100)
  core.worklistAdd(st, "generic", "  send invoice  ", "g2", 101)  -- trimmed
  core.worklistAdd(st, "proj:/Users/adam/qb", "fix date filter", "p1", 102)
  eq("worklist: generic count", #core.worklistScopeList(st, "generic"), 2)
  eq("worklist: text trimmed", core.worklistScopeList(st, "generic")[2].text, "send invoice")
  eq("worklist: project scope count", #core.worklistScopeList(st, "proj:/Users/adam/qb"), 1)
  eq("worklist: nil scope == generic", #core.worklistScopeList(st, nil), 2)
  -- empty/whitespace text ignored
  core.worklistAdd(st, "generic", "   ", "g3", 103)
  core.worklistAdd(st, "generic", "", "g4", 104)
  eq("worklist: blank text ignored", #core.worklistScopeList(st, "generic"), 2)
  -- new items start active (not done)
  check("worklist: new item active", core.worklistScopeList(st, "generic")[1].done == false)
  -- toggle moves to done (stamping doneTs); toggle again brings back (clearing it)
  core.worklistToggle(st, "generic", "g1", 5000)
  check("worklist: toggle sets done", core.worklistScopeList(st, "generic")[1].done == true)
  eq("worklist: toggle stamps doneTs", core.worklistScopeList(st, "generic")[1].doneTs, 5000)
  local active, done = core.worklistSplit(core.worklistScopeList(st, "generic"))
  eq("worklist: split active", #active, 1)
  eq("worklist: split done", #done, 1)
  eq("worklist: split done is the toggled one", done[1].id, "g1")
  core.worklistToggle(st, "generic", "g1", 6000)
  check("worklist: toggle back to active", core.worklistScopeList(st, "generic")[1].done == false)
  check("worklist: un-done clears doneTs", core.worklistScopeList(st, "generic")[1].doneTs == nil)
  -- clearDone removes only done items, only in that scope
  core.worklistToggle(st, "generic", "g2")          -- mark "send invoice" done
  core.worklistToggle(st, "proj:/Users/adam/qb", "p1")  -- mark project item done
  core.worklistClearDone(st, "generic")
  eq("worklist: clearDone drops done in scope", #core.worklistScopeList(st, "generic"), 1)
  eq("worklist: clearDone keeps active", core.worklistScopeList(st, "generic")[1].id, "g1")
  eq("worklist: clearDone leaves other scope untouched", #core.worklistScopeList(st, "proj:/Users/adam/qb"), 1)
  -- toggle of an unknown id is a no-op (no crash)
  core.worklistToggle(st, "generic", "nope")
  eq("worklist: unknown-id toggle is a no-op", #core.worklistScopeList(st, "generic"), 1)
  -- worklistEdit: the double-click inline edit -- change an item's text by id
  core.worklistEdit(st, "generic", "g1", "call the bank URGENTLY")
  eq("worklist: edit changes text by id", core.worklistScopeList(st, "generic")[1].text, "call the bank URGENTLY")
  core.worklistEdit(st, "generic", "g1", "   spaced out   ")
  eq("worklist: edit trims the new text", core.worklistScopeList(st, "generic")[1].text, "spaced out")
  core.worklistEdit(st, "generic", "g1", "   ")
  eq("worklist: edit ignores blank text (keeps original)", core.worklistScopeList(st, "generic")[1].text, "spaced out")
  core.worklistToggle(st, "generic", "g1")          -- mark done, edit, expect done preserved
  core.worklistEdit(st, "generic", "g1", "still done")
  check("worklist: edit preserves the done flag", core.worklistScopeList(st, "generic")[1].done == true)
  core.worklistToggle(st, "generic", "g1")          -- restore active for clarity
  core.worklistEdit(st, "generic", "nope", "ghost")
  eq("worklist: edit unknown id is a no-op", core.worklistScopeList(st, "generic")[1].text, "still done")
  eq("worklist: edit unknown id adds nothing", #core.worklistScopeList(st, "generic"), 1)
  -- details + expected date (the item modal's other two fields)
  core.worklistAdd(st, "generic", "ship the panel", "d1", 200,
                   { details = "  subject is the row; this is the body  ", due = "2026-08-01" })
  local d1 = core.worklistScopeList(st, "generic")[2]
  eq("worklist: add stores trimmed details", d1.details, "subject is the row; this is the body")
  eq("worklist: add stores the due date", d1.due, "2026-08-01")
  -- an add with no extras still yields present-but-empty fields (never nil in the payload)
  core.worklistAdd(st, "generic", "bare item", "d2", 201)
  eq("worklist: bare add has empty details", core.worklistScopeList(st, "generic")[3].details, "")
  eq("worklist: bare add has empty due", core.worklistScopeList(st, "generic")[3].due, "")
  -- edit rewrites the extras it is GIVEN...
  core.worklistEdit(st, "generic", "d1", "ship the panel", { details = "revised", due = "2026-09-09" })
  eq("worklist: edit rewrites details", core.worklistScopeList(st, "generic")[2].details, "revised")
  eq("worklist: edit rewrites due", core.worklistScopeList(st, "generic")[2].due, "2026-09-09")
  -- ...clears one when it is sent empty (the modal always sends both)...
  core.worklistEdit(st, "generic", "d1", "ship the panel", { details = "revised", due = "" })
  eq("worklist: edit can clear the due date", core.worklistScopeList(st, "generic")[2].due, "")
  -- ...and leaves them ALONE when the caller omits them entirely.
  core.worklistEdit(st, "generic", "d1", "renamed")
  eq("worklist: subject-only edit keeps details", core.worklistScopeList(st, "generic")[2].details, "revised")
  eq("worklist: subject-only edit renames", core.worklistScopeList(st, "generic")[2].text, "renamed")
  -- checklist steps: sanitized on the way in, counted for the row's progress chip
  core.worklistEdit(st, "generic", "d1", "renamed",
                    { steps = { { text = "  one  ", done = true }, { text = "two" }, { text = "  " }, "junk" } })
  local steps = core.worklistScopeList(st, "generic")[2].steps
  eq("worklist: blank + non-table steps dropped", #steps, 2)
  eq("worklist: step text trimmed", steps[1].text, "one")
  check("worklist: step done flag kept", steps[1].done == true)
  check("worklist: step done defaults false", steps[2].done == false)
  local sd, stot = core.worklistStepProgress(steps)
  eq("worklist: step progress done", sd, 1)
  eq("worklist: step progress total", stot, 2)
  eq("worklist: progress of no steps", select(2, core.worklistStepProgress(nil)), 0)
  -- an edit that omits steps leaves the checklist alone; sending {} clears it
  core.worklistEdit(st, "generic", "d1", "renamed again")
  eq("worklist: subject-only edit keeps steps", #core.worklistScopeList(st, "generic")[2].steps, 2)
  core.worklistEdit(st, "generic", "d1", "renamed again", { steps = {} })
  eq("worklist: empty steps clears the checklist", #core.worklistScopeList(st, "generic")[2].steps, 0)
  core.worklistRemove(st, "generic", "d1"); core.worklistRemove(st, "generic", "d2")
  -- projectKeyLabel: friendly fallback name from a Claude project-dir key
  eq("worklist: label strips home prefix",
     core.projectKeyLabel("-Users-adam-Programming-ChargebackSentinel"), "ChargebackSentinel")
  eq("worklist: label strips Programming too",
     core.projectKeyLabel("-Users-adam-Programming-claude-instance-manager"), "claude-instance-manager")
  eq("worklist: label leaves a plain key alone", core.projectKeyLabel("mything"), "mything")
  eq("worklist: label of empty is empty", core.projectKeyLabel(""), "")
  eq("worklist: label of non-string is empty", core.projectKeyLabel(nil), "")
  -- scope list for an unknown project is empty (no crash)
  eq("worklist: unknown scope -> empty", #core.worklistScopeList(st, "proj:/nope"), 0)
  -- tolerant of a nil/garbled state
  eq("worklist: nil state scope -> empty", #core.worklistScopeList(nil, "generic"), 0)
  check("worklist: add to nil state builds it", #core.worklistScopeList(core.worklistAdd(nil, "generic", "x", "z1", 1), "generic") == 1)

  -- worklistNormalize: de-alias + self-heal a decoded blob
  -- (1) the JSON-intern alias bug: generic and byProject are the SAME table
  local shared = { { id = "a", text = "t", done = false, ts = 1 } }
  local aliased = { generic = shared, byProject = shared }
  local n1 = core.worklistNormalize(aliased)
  check("normalize: generic and byProject are DISTINCT tables", not rawequal(n1.generic, n1.byProject))
  eq("normalize: generic keeps its item", #n1.generic, 1)
  check("normalize: byProject drops numeric-keyed (aliased) entries", next(n1.byProject) == nil)
  -- adding to the normalized generic must NOT touch byProject
  core.worklistAdd(n1, "generic", "b", "b1", 2)
  eq("normalize: post-add generic", #n1.generic, 2)
  check("normalize: post-add byProject still empty", next(n1.byProject) == nil)
  -- (2) a corrupted byProject-as-array is healed to an empty map
  local n2 = core.worklistNormalize({ generic = {}, byProject = { { id = "x", text = "y" } } })
  check("normalize: array byProject healed to empty map", next(n2.byProject) == nil)
  -- (3) a valid byProject map is preserved, keyed by project
  local n3 = core.worklistNormalize({ generic = {}, byProject = { ["proj:/a"] = { { id = "p", text = "q", done = true } } } })
  eq("normalize: valid project list preserved", #core.worklistScopeList(n3, "proj:/a"), 1)
  check("normalize: preserved item flag", core.worklistScopeList(n3, "proj:/a")[1].done == true)
  -- (4) nil / garbage -> empty distinct containers
  local n4 = core.worklistNormalize(nil)
  check("normalize: nil -> distinct empties", not rawequal(n4.generic, n4.byProject) and #n4.generic == 0 and next(n4.byProject) == nil)
  -- (5) junk drop INSIDE valid containers: non-table generic items + a non-table
  -- byProject value are dropped (self-heal beyond the alias case)
  local n5 = core.worklistNormalize({
    generic = { "astring", { id = "1", text = "x" }, 42 },
    byProject = { good = { { id = "2", text = "y" }, "junkitem" }, junk = "alsoastring" },
  })
  eq("normalize: non-table generic items dropped", #n5.generic, 1)
  eq("normalize: non-table project value dropped", core.worklistScopeList(n5, "junk") and #core.worklistScopeList(n5, "junk"), 0)
  eq("normalize: valid project kept, junk item dropped", #core.worklistScopeList(n5, "good"), 1)

  -- worklistClearDone PROJECT-scope branch (only the generic branch was covered)
  local cd = { generic = { { id = "g", text = "keep", done = false } },
               byProject = { ["proj:/p"] = { { id = "a", text = "done1", done = true },
                                              { id = "b", text = "active", done = false } } } }
  core.worklistClearDone(cd, "proj:/p")
  eq("clearDone(project): drops done in that project", #core.worklistScopeList(cd, "proj:/p"), 1)
  eq("clearDone(project): keeps the active one", core.worklistScopeList(cd, "proj:/p")[1].id, "b")
  eq("clearDone(project): leaves generic untouched", #core.worklistScopeList(cd, "generic"), 1)

  -- worklistRemove: per-item ✕ delete (works on active OR done items, by id)
  local rm = { generic = { { id = "a", text = "1st", done = false },
                           { id = "b", text = "2nd", done = true  },
                           { id = "c", text = "3rd", done = false } },
               byProject = { ["proj:/r"] = { { id = "x", text = "px", done = false },
                                             { id = "y", text = "py", done = false } } } }
  core.worklistRemove(rm, "generic", "b")  -- delete a DONE item by id
  eq("remove: drops the targeted item", #core.worklistScopeList(rm, "generic"), 2)
  eq("remove: survivors keep order (1st)", core.worklistScopeList(rm, "generic")[1].id, "a")
  eq("remove: survivors keep order (3rd)", core.worklistScopeList(rm, "generic")[2].id, "c")
  core.worklistRemove(rm, "generic", "a")  -- delete an ACTIVE item by id
  eq("remove: active item deletes too", #core.worklistScopeList(rm, "generic"), 1)
  eq("remove: last survivor is c", core.worklistScopeList(rm, "generic")[1].id, "c")
  -- unknown id is a no-op (no crash, nothing dropped)
  core.worklistRemove(rm, "generic", "nope")
  eq("remove: unknown id is a no-op", #core.worklistScopeList(rm, "generic"), 1)
  -- scope isolation: removing from generic left the project list untouched
  eq("remove: other scope untouched", #core.worklistScopeList(rm, "proj:/r"), 2)
  -- project-scope branch deletes by id there too
  core.worklistRemove(rm, "proj:/r", "x")
  eq("remove(project): drops in that project", #core.worklistScopeList(rm, "proj:/r"), 1)
  eq("remove(project): keeps the other one", core.worklistScopeList(rm, "proj:/r")[1].id, "y")
  eq("remove(project): leaves generic untouched", #core.worklistScopeList(rm, "generic"), 1)
  -- removing every item empties the scope (not a crash, just an empty list)
  core.worklistRemove(rm, "generic", "c")
  eq("remove: emptying a scope is fine", #core.worklistScopeList(rm, "generic"), 0)
  -- tolerant of nil/garbled state and unknown scope (mirrors clearDone: the guard
  -- only prevents a crash on non-table state; real callers always pass a table)
  eq("remove: nil state -> empty distinct", #core.worklistScopeList(core.worklistRemove(nil, "generic", "z"), "generic"), 0)
  check("remove: non-table state does not crash", (pcall(core.worklistRemove, "nope", "generic", "z")))
  core.worklistRemove(rm, "proj:/unknown", "z")  -- unknown project scope: no crash
  eq("remove: unknown project scope is a no-op", #core.worklistScopeList(rm, "proj:/unknown"), 0)
end

-- ---- User stories editor: parse / serialize / hash (spec/product/user-stories.md) ----
do
  -- THE core safety invariant: serialize(parse(x).blocks) == x BYTE-FOR-BYTE for any
  -- unmodified file that ends in a newline (so opening the tab and saving without edits
  -- can never churn it).
  local function rt(label, text)
    local doc = core.parseUserStories(text)
    eq("userStories rt: " .. label, core.serializeUserStories(doc.blocks), text)
  end
  rt("empty", "")
  rt("trailing newline", "# Title\n\n## Area\n\n- a story\n- another\n")
  rt("wrapped bullet", "## Chrome\n\n- Visit the root and see\n  the overview render\n- Click a thing\n")
  rt("prose between sections", "# T\n\nintro para\n\n## A\n- one\n\nsome note\n\n## B\n- two\n")
  rt("bullets before any heading", "# T\n\nintro\n\n- top one\n- top two\n\n## Later\n- grouped\n")
  rt("headings only, no stories", "# T\n\n## Empty Area\n\n## Another\n")
  rt("leading/trailing blank lines", "\n\n# T\n\n- s\n\n\n")
  -- a file with NO final newline NORMALIZES (gains one): the old trailing-newline strip
  -- left the last block "open", so an append glued onto it and corrupted the file (the
  -- fleet's #2-5 finding). Adding the newline is the safe POSIX-text fix.
  eq("userStories rt: no final newline normalizes to add one",
     core.serializeUserStories(core.parseUserStories("# Title\n\n- a story").blocks), "# Title\n\n- a story\n")
  eq("userStories rt: single line, no newline -> adds one",
     core.serializeUserStories(core.parseUserStories("- lone story").blocks), "- lone story\n")

  -- structure
  local doc = core.parseUserStories("# T\n\n## Chrome\n\n- story one\n- story two\n\n## Overview\n\n- story three\n")
  eq("userStories: story count", #doc.stories, 3)
  eq("userStories: areas in order", table.concat(doc.areas, "|"), "Chrome|Overview")
  eq("userStories: area tag", doc.stories[1].area, "Chrome")
  eq("userStories: later area tag", doc.stories[3].area, "Overview")
  eq("userStories: text parsed", doc.stories[1].text, "story one")
  check("userStories: stable unique ids", doc.stories[1].id == "s1" and doc.stories[3].id == "s3")

  -- wrapped bullet: continuation lines join into one text; src preserved verbatim
  local w = core.parseUserStories("## A\n- first line\n  second line\n  third\n")
  eq("userStories: wrapped joined to one text", w.stories[1].text, "first line second line third")
  eq("userStories: wrapped src preserved", w.stories[1].src, "- first line\n  second line\n  third\n")

  -- edit one story: only that line reserializes (single bullet); all else verbatim
  local d2 = core.parseUserStories("# T\n\n## A\n\n- keep me\n- change me\n")
  d2.stories[2].text = "changed"; d2.stories[2].dirty = true
  eq("userStories: edit touches only the edited story",
     core.serializeUserStories(d2.blocks), "# T\n\n## A\n\n- keep me\n- changed\n")

  -- delete: drop a story block, the rest (incl. headings) stays
  local d3 = core.parseUserStories("## A\n- one\n- two\n- three\n")
  local kept = {}
  for _, blk in ipairs(d3.blocks) do if blk.id ~= d3.stories[2].id then kept[#kept + 1] = blk end end
  eq("userStories: delete drops only that story", core.serializeUserStories(kept), "## A\n- one\n- three\n")

  -- add: a new dirty story (no src) emits a trimmed bullet; a blank new story is dropped
  local d4 = core.parseUserStories("## A\n- one\n")
  d4.blocks[#d4.blocks + 1] = { id = "new1", area = "A", text = "  brand new  ", dirty = true }
  eq("userStories: add appends a trimmed bullet", core.serializeUserStories(d4.blocks), "## A\n- one\n- brand new\n")
  local d5 = core.parseUserStories("## A\n- one\n")
  d5.blocks[#d5.blocks + 1] = { id = "new2", area = "A", text = "   ", dirty = true }
  eq("userStories: blank new story dropped", core.serializeUserStories(d5.blocks), "## A\n- one\n")

  -- robustness: nil / junk blocks never crash or corrupt
  eq("userStories: nil text -> empty doc", #core.parseUserStories(nil).stories, 0)
  eq("userStories: serialize nil -> empty", core.serializeUserStories(nil), "")
  eq("userStories: serialize skips junk blocks", core.serializeUserStories({ "x", 5, { raw = "ok\n" } }), "ok\n")
  eq("userStories: --- rule / bare dash / *** are not stories",
     #core.parseUserStories("---\n***\n-nope\n").stories, 0)

  -- a story edited to contain newlines (Shift+Enter / paste) collapses to ONE bullet
  -- so it can't inject fake structure (a "\n## heading" or a second "- bullet")
  local d6 = core.parseUserStories("## A\n- one\n")
  d6.blocks[#d6.blocks + 1] = { id = "new3", area = "A", text = "multi\nline\n## fake\n- inject", dirty = true }
  eq("userStories: newlines in a story collapse to one bullet (no injection)",
     core.serializeUserStories(d6.blocks), "## A\n- one\n- multi line ## fake - inject\n")

  -- FENCED CODE (fleet #1, HIGH): a "- " line inside a ``` fence is RAW, not a
  -- deletable story (deleting it would corrupt the fence).
  local fenced = core.parseUserStories("## A\n- real story\n\n```\n- not a story\n```\n")
  eq("userStories: fenced bullet is NOT a story", #fenced.stories, 1)
  eq("userStories: fenced file round-trips byte-exact",
     core.serializeUserStories(fenced.blocks), "## A\n- real story\n\n```\n- not a story\n```\n")
  local keptF = {}
  for _, blk in ipairs(fenced.blocks) do if blk.id ~= fenced.stories[1].id then keptF[#keptF + 1] = blk end end
  eq("userStories: deleting the real story leaves the fence intact",
     core.serializeUserStories(keptF), "## A\n\n```\n- not a story\n```\n")

  -- ADD to a file with NO final newline must NOT glue onto the last line (fleet #2-5, HIGH)
  local nn = core.parseUserStories("## Notes\nfinal line no newline")
  nn.blocks[#nn.blocks + 1] = { id = "new9", area = "Notes", text = "added story", dirty = true }
  eq("userStories: add to a no-newline file does not glue",
     core.serializeUserStories(nn.blocks), "## Notes\nfinal line no newline\n- added story\n")
  eq("userStories: the added story survives a re-parse",
     #core.parseUserStories(core.serializeUserStories(nn.blocks)).stories, 1)

  -- each ## heading anchors its OWN raw block tagged with the exact area (add placement)
  local h = core.parseUserStories("## Auth\n\n## Authentication\n- b\n")
  local tags = {}
  for _, blk in ipairs(h.blocks) do if blk.headingArea then tags[#tags + 1] = blk.headingArea end end
  eq("userStories: heading blocks tagged with the EXACT area", table.concat(tags, "|"), "Auth|Authentication")

  -- CRLF (fleet #6,9,15): an edited story uses the file's prevailing newline; no mixing
  local crlf = core.parseUserStories("## A\r\n- one\r\n")
  eq("userStories: CRLF round-trips unchanged", core.serializeUserStories(crlf.blocks), "## A\r\n- one\r\n")
  crlf.stories[1].text = "changed"; crlf.stories[1].dirty = true
  eq("userStories: edited story keeps CRLF", core.serializeUserStories(crlf.blocks), "## A\r\n- changed\r\n")

  -- bullet marker preserved on edit (fleet #20: no * -> - churn)
  local star = core.parseUserStories("## A\n* one\n")
  eq("userStories: marker captured", star.stories[1].marker, "*")
  star.stories[1].text = "two"; star.stories[1].dirty = true
  eq("userStories: edited story keeps its * marker", core.serializeUserStories(star.blocks), "## A\n* two\n")

  -- a story edited/pasted to START with a bullet marker doesn't double up (re-verify #2)
  local dm = core.parseUserStories("## A\n- one\n")
  dm.stories[1].text = "- pasted with dash"; dm.stories[1].dirty = true
  eq("userStories: leading bullet marker in edited text is not doubled",
     core.serializeUserStories(dm.blocks), "## A\n- pasted with dash\n")

  -- idempotency: a second parse->serialize of edited output is stable
  local once = core.serializeUserStories(d4.blocks)
  eq("userStories: edited output is round-trip stable", core.serializeUserStories(core.parseUserStories(once).blocks), once)

  -- well-formedness soft hint: the MANDATORY "so that"
  check("userStories wellFormed: full story", core.userStoryWellFormed("As a user, I want X, so that Y"))
  check("userStories wellFormed: missing so-that -> false", not core.userStoryWellFormed("As a user, I want X"))
  check("userStories wellFormed: case-insensitive", core.userStoryWellFormed("AS A admin, I WANT logs, SO THAT I can audit"))
  check("userStories wellFormed: empty -> false", not core.userStoryWellFormed("   "))
  check("userStories wellFormed: plain text -> false", not core.userStoryWellFormed("just do the thing"))

  -- cheapHash: deterministic, change-sensitive, fixed width
  eq("userStories hash: deterministic", core.cheapHash("hello world"), core.cheapHash("hello world"))
  check("userStories hash: change-sensitive", core.cheapHash("a") ~= core.cheapHash("b"))
  eq("userStories hash: 8 hex chars", #core.cheapHash("anything"), 8)
  eq("userStories hash: nil safe", #core.cheapHash(nil), 8)

  -- storiesSaveDecision: the save guards, exercised behaviorally (real calls, not a
  -- source grep) -- this is the data-safety chokepoint the panel's stories-save runs.
  local base = "## A\n- one\n- two\n"
  local baseHash = core.cheapHash(base)
  local baseBlocks = core.parseUserStories(base).blocks
  eq("storiesSave: missing file (nil current) -> rejected", core.storiesSaveDecision(nil, baseHash, baseBlocks).error, "missing")
  eq("storiesSave: hash mismatch -> changed (external edit, never clobber)",
     core.storiesSaveDecision(base, "deadbeef", baseBlocks).error, "changed")
  eq("storiesSave: non-table blocks -> bad-payload", core.storiesSaveDecision(base, baseHash, "nope").error, "bad-payload")
  eq("storiesSave: empty serialization over a non-empty file -> empty-refused",
     core.storiesSaveDecision(base, baseHash, {}).error, "empty-refused")
  local clean = core.storiesSaveDecision(base, baseHash, baseBlocks)
  check("storiesSave: unedited save ok", clean.ok == true)
  eq("storiesSave: unedited save returns the file verbatim (zero churn)", clean.text, base)
  local ed = core.parseUserStories(base)
  ed.stories[1].text = "changed"; ed.stories[1].dirty = true
  local edDec = core.storiesSaveDecision(base, baseHash, ed.blocks)
  check("storiesSave: edited save ok", edDec.ok == true)
  eq("storiesSave: edited save returns the edited markdown", edDec.text, "## A\n- changed\n- two\n")
  check("storiesSave: empty file legitimately staying empty is allowed",
        core.storiesSaveDecision("", core.cheapHash(""), {}).ok == true)
end

-- ---- L1: persona / extra flags / resolver / env ----------------------------
do
  eq("personaPrompt: nil when empty", core.personaPrompt({ name = "x" }), nil)
  local pp = core.personaPrompt({ role = "a reviewer", goal = "find bugs", backstory = "Be terse." })
  check("personaPrompt: role line", pp:find("You are a reviewer.", 1, true) ~= nil)
  check("personaPrompt: goal line", pp:find("Your goal: find bugs", 1, true) ~= nil)

  eq("spawnExtraFlags: empty when none", #core.spawnExtraFlags({}), 0)
  local xf = core.spawnExtraFlags({ appendSystemPrompt = "you are bob", mcpConfigPath = "/tmp/m.json",
    strictMcp = true, agentName = "reviewer", addDirs = { "/k" }, pluginDirs = { "/p" } })
  local joined = table.concat(xf, " ")
  check("spawnExtraFlags: append-system-prompt", joined:find("--append-system-prompt you are bob", 1, true) ~= nil)
  check("spawnExtraFlags: mcp-config + strict", joined:find("--mcp-config /tmp/m.json --strict-mcp-config", 1, true) ~= nil)
  check("spawnExtraFlags: --agent", joined:find("--agent reviewer", 1, true) ~= nil)
  check("spawnExtraFlags: --add-dir", joined:find("--add-dir /k", 1, true) ~= nil)
  check("spawnExtraFlags: --plugin-dir", joined:find("--plugin-dir /p", 1, true) ~= nil)

  -- resolveAgent dereferences MCP names; reports a missing one
  local mcpState = (core.mcpPush({ servers = {} }, { id = "linear", transport = "sse", url = "u" }))
  local res = core.resolveAgent({ name = "r", provider = "claude", seedPrompt = "go",
    role = "a reviewer", knowledge = { "/docs" }, mcpServers = { "linear", "ghost" } },
    { mcpState = mcpState })
  eq("resolveAgent: providerId", res.providerId, "claude")
  eq("resolveAgent: seedPrompt", res.seedPrompt, "go")
  check("resolveAgent: persona built", res.appendSystemPrompt ~= nil)
  eq("resolveAgent: addDirs from knowledge", res.addDirs[1], "/docs")
  eq("resolveAgent: one MCP resolved", #res.mcpServers, 1)
  check("resolveAgent: mcpConfig built", res.mcpConfig ~= nil)
  check("resolveAgent: missing MCP reported", #res.errors == 1)

  -- missingEnv
  local miss = core.missingEnv({ requiredEnv = { "PRESENT", { name = "ABSENT" }, { name = "OPT", required = false } } },
    { PRESENT = "1" })
  eq("missingEnv: only the absent required one", #miss, 1)
  eq("missingEnv: it is ABSENT", miss[1], "ABSENT")
end

-- ---- L1: spawn integration (flags flow through; non-agent unchanged) --------
do
  local si = core.spawnInner("/tmp/x", nil,
    { flags = { "--permission-mode", "default", "--append-system-prompt", "you are bob" } })
  check("spawnInner: safe flag raw", si:find("--permission-mode default", 1, true) ~= nil)
  check("spawnInner: spaced flag quoted", si:find("'you are bob'", 1, true) ~= nil)

  local spec = core.spawnSpec("terminal", "/tmp/x", nil,
    { permissionMode = "plan", appendSystemPrompt = "be terse", agentName = "rev" })
  check("spawnSpec: agent flags appear", spec.applescript:find("--agent rev", 1, true) ~= nil)
  check("spawnSpec: persona quoted in applescript", spec.applescript:find("'be terse'", 1, true) ~= nil)
  local base = core.spawnSpec("kitty", "/tmp/x", nil, { permissionMode = "plan" })
  check("spawnSpec: non-agent kitty has no agent flags",
    table.concat(base.argv, " "):find("--append-system-prompt", 1, true) == nil)
end

-- ---- L1: skills frontmatter + slash command --------------------------------
do
  local sk = core.parseSkillFrontmatter(
    "---\nname: code-review\ndisplay_title: Code Review\ndescription: \"Review a diff.\"\n---\nBody here", "fallback")
  eq("parseSkill: name from frontmatter", sk.name, "code-review")
  eq("parseSkill: display_title", sk.display_title, "Code Review")
  eq("parseSkill: description (dequoted)", sk.description, "Review a diff.")
  eq("parseSkill: stem fallback when no frontmatter",
    core.parseSkillFrontmatter("just a body, no fence", "my-skill").name, "my-skill")
  eq("skillCommand: slugified", core.skillCommand("Deep Planning"), "/deep-planning")
  eq("skillCommand: nil on blank", core.skillCommand("  "), nil)
end

-- ---- L1: folder-scoped profile matching ------------------------------------
do
  local profs = {
    { name = "fe", folderGlobs = { "/work/frontend/**" } },
    { name = "any", folderGlobs = { "/work/*" } },
    { name = "none" },
  }
  local m1 = core.profilesForFolder(profs, "/work/frontend/app/sub")
  local names = {}; for _, p in ipairs(m1) do names[p.name] = true end
  check("profilesForFolder: ** matches deep", names.fe == true)
  check("profilesForFolder: single * matches one segment", core.profilesForFolder(profs, "/work/api")[1] ~= nil)
  check("profilesForFolder: no-glob profile never matches",
    (function() for _, p in ipairs(core.profilesForFolder(profs, "/work/api")) do
       if p.name == "none" then return false end end; return true end)())
  eq("profilesForFolder: empty dir -> none", #core.profilesForFolder(profs, ""), 0)
end

-- ---- L2: named policy / guardrail bundles + attachments --------------------
do
  -- globEq: wildcard, glob, exact
  check("globEq: empty pattern is wildcard", core.globEq("", "anything") == true)
  check("globEq: nil pattern is wildcard", core.globEq(nil, "anything") == true)
  check("globEq: exact match", core.globEq("claude", "claude") == true)
  check("globEq: star match", core.globEq("my-*", "my-repo") == true)
  check("globEq: no match", core.globEq("my-*", "other") == false)

  local cfg = core.json.decode([[{
    "gate": { "tools": "Bash" },
    "policies": {
      "patterns": { "autoAllow": ["Read"], "autoDeny": ["Bash(rm*)"] },
      "bundles": {
        "read-only": { "autoDeny": ["Write","Edit"], "gateTools": "Bash Write Edit" },
        "tight": { "autoDeny": ["Bash(curl*)"], "disableGlobal": true, "toolLimits": {"Bash": 3} },
        "trusted": { "autopilot": true }
      },
      "attachments": [
        { "match": { "project": "secure-*" }, "bundle": "read-only" },
        { "match": { "group": "prod" }, "bundle": "tight" }
      ]
    }
  }]])

  -- matchAttachment: project glob, group, no-match
  eq("matchAttachment: project glob -> read-only",
     core.matchAttachment(cfg, { project = "secure-api" }), "read-only")
  eq("matchAttachment: group -> tight",
     core.matchAttachment(cfg, { group = "prod" }), "tight")
  eq("matchAttachment: no match -> nil",
     core.matchAttachment(cfg, { project = "scratch", group = "dev" }), nil)

  -- resolvePolicy: fleet default (no override, no attachment)
  local fleet = core.resolvePolicy(cfg, { project = "scratch" })
  eq("resolvePolicy: fleet source", fleet.source, "fleet")
  eq("resolvePolicy: fleet autoDeny is the patterns list", fleet.autoDeny[1], "Bash(rm*)")
  eq("resolvePolicy: fleet gateTools", fleet.gateTools, "Bash")

  -- attachment-matched bundle UNIONS the fleet lists
  local att = core.resolvePolicy(cfg, { project = "secure-api" })
  eq("resolvePolicy: attachment source", att.source, "attachment")
  eq("resolvePolicy: attachment bundle name", att.bundle, "read-only")
  check("resolvePolicy: union keeps fleet deny",
        (function() for _, d in ipairs(att.autoDeny) do if d == "Bash(rm*)" then return true end end return false end)())
  check("resolvePolicy: union adds bundle deny",
        (function() for _, d in ipairs(att.autoDeny) do if d == "Write" then return true end end return false end)())
  eq("resolvePolicy: bundle gateTools wins over fleet", att.gateTools, "Bash Write Edit")

  -- R1-04: a bundle with autopilot:true surfaces autopilot=true (so the panel can
  -- persist it into the resolved-policy file the gate reads).
  local ap = core.resolvePolicy(cfg, { project = "scratch" }, { bundle = "trusted" })
  eq("resolvePolicy: bundle autopilot surfaced", ap.autopilot, true)
  eq("resolvePolicy: non-autopilot bundle -> false", att.autopilot, false)

  -- disableGlobal drops the fleet lists; explicit override beats attachment
  local ov = core.resolvePolicy(cfg, { project = "secure-api" }, { bundle = "tight" })
  eq("resolvePolicy: override source", ov.source, "session")
  eq("resolvePolicy: override bundle", ov.bundle, "tight")
  check("resolvePolicy: disableGlobal drops fleet deny",
        (function() for _, d in ipairs(ov.autoDeny) do if d == "Bash(rm*)" then return false end end return true end)())
  eq("resolvePolicy: only the bundle deny survives", ov.autoDeny[1], "Bash(curl*)")
  check("resolvePolicy: toolLimits carried", ov.toolLimits ~= nil and ov.toolLimits.Bash == 3)

  -- starter bundles + overToolLimit
  check("DEFAULT_POLICY_BUNDLES: read-only gates Bash",
        (function() for _, d in ipairs(core.DEFAULT_POLICY_BUNDLES["read-only"].autoDeny) do
           if d == "Bash" then return true end end return false end)())
  local over = core.overToolLimit({ Bash = 3, Write = 5 }, { Bash = 3, Write = 1 })
  eq("overToolLimit: one tool over", #over, 1)
  eq("overToolLimit: it is Bash", over[1].tool, "Bash")

  -- L2 editor CRUD: bundles (map) + attachments (ordered array) on the policies subtree
  local pol = { patterns = { autoAllow = { "Read" } } }
  local p1, ok1, errs1 = core.policySetBundle(pol, "tight", { autoDeny = { "Bash", "Write" }, gateTools = "Bash Edit" })
  eq("polBundle: saved", ok1, true)
  eq("polBundle: stored under name", #p1.bundles.tight.autoDeny, 2)
  eq("polBundle: gateTools normalized string", p1.bundles.tight.gateTools, "Bash Edit")
  eq("polBundle: patterns ride through", p1.patterns.autoAllow[1], "Read")
  local _, okBad, errsBad = core.policySetBundle(pol, "", { autoDeny = {} })
  eq("polBundle: blank name rejected", okBad, false)
  check("polBundle: returns errors", type(errsBad) == "table" and #errsBad > 0)
  eq("polBundle: bad lockedPermMode rejected",
     select(2, core.policySetBundle(pol, "x", { lockedPermMode = "nope" })), false)
  -- empty fields are dropped on normalize
  local p2 = core.policySetBundle(pol, "empty", { autoAllow = {}, autopilot = false })
  eq("polBundle: empty autoAllow dropped", p2.bundles.empty.autoAllow, nil)
  eq("polBundle: autopilot false dropped", p2.bundles.empty.autopilot, nil)
  -- toolLimits normalized to numbers
  local p3 = core.policySetBundle(pol, "lim", { toolLimits = { Bash = "5", Junk = "x" } })
  eq("polBundle: toolLimit number kept", p3.bundles.lim.toolLimits.Bash, 5)
  eq("polBundle: toolLimit non-number dropped", p3.bundles.lim.toolLimits.Junk, nil)
  -- remove
  local p4 = core.policyRemoveBundle(p1, "tight")
  eq("polBundle: removed", p4.bundles.tight, nil)
  -- attachments: add / order / move / remove
  local a1 = core.policyAddAttachment(pol, { match = { project = "shep*" }, bundle = "tight" })
  eq("polAtt: added", #a1.attachments, 1)
  eq("polAtt: match normalized", a1.attachments[1].match.project, "shep*")
  local a2 = core.policyAddAttachment(a1, { match = {}, bundle = "read-only" })
  eq("polAtt: second appended", #a2.attachments, 2)
  eq("polAtt: blank match = wildcard (empty match table)", next(a2.attachments[2].match), nil)
  local _, okA, errsA = core.policyAddAttachment(pol, { match = {} })
  eq("polAtt: missing bundle rejected", okA, false)
  -- move down then back up
  local a3 = core.policyMoveAttachment(a2, 1, 1)
  eq("polAtt: moved to second", a3.attachments[2].bundle, "tight")
  eq("polAtt: other moved to first", a3.attachments[1].bundle, "read-only")
  eq("polAtt: move out of range no-op", core.policyMoveAttachment(a2, 2, 1).attachments[2].bundle, "read-only")
  -- set (replace at index)
  local a4 = core.policySetAttachment(a2, 1, { match = { group = "g" }, bundle = "no-bash" })
  eq("polAtt: replaced bundle", a4.attachments[1].bundle, "no-bash")
  eq("polAtt: set bad index rejected", select(2, core.policySetAttachment(a2, 9, { bundle = "x" })), false)
  -- remove by index
  local a5 = core.policyRemoveAttachment(a2, 1)
  eq("polAtt: removed one", #a5.attachments, 1)
  eq("polAtt: remaining is the second", a5.attachments[1].bundle, "read-only")
end

-- ---- L5: detail-panel tab strip state normalizer --------------------------
do
  -- canonical list is non-empty and starts with the default
  check("tabs: DETAIL_TABS non-empty", #core.DETAIL_TABS > 0)
  eq("tabs: default is first id", core.DETAIL_TABS[1].id, core.DETAIL_TAB_DEFAULT)
  local ids = core.detailTabIds()
  check("tabs: ids set has activity", ids.activity == true)
  check("tabs: ids set has queue", ids.queue == true)

  -- nil / garbage raw -> default selected, no unpinned
  local n0 = core.normalizeTabState(nil)
  eq("tabs: nil raw -> default selected", n0.selectedTab, "activity")
  eq("tabs: nil raw -> no unpinned (next is nil)", next(n0.unpinned), nil)
  local ng = core.normalizeTabState("not a table")
  eq("tabs: garbage raw -> default", ng.selectedTab, "activity")

  -- a valid selection that is pinned is kept
  local n1 = core.normalizeTabState({ selectedTab = "usage", unpinned = { decisions = true } })
  eq("tabs: valid selection kept", n1.selectedTab, "usage")
  check("tabs: valid unpinned kept", n1.unpinned.decisions == true)
  eq("tabs: unrelated tab not unpinned", n1.unpinned.usage, nil)

  -- unknown selectedTab -> default
  eq("tabs: unknown selection -> default",
     core.normalizeTabState({ selectedTab = "bogus" }).selectedTab, "activity")

  -- the default tab can NEVER be unpinned
  local n2 = core.normalizeTabState({ selectedTab = "activity", unpinned = { activity = true } })
  eq("tabs: default cannot be unpinned", n2.unpinned.activity, nil)

  -- selecting a tab that is also unpinned -> falls back to default (active must be visible)
  local n3 = core.normalizeTabState({ selectedTab = "queue", unpinned = { queue = true } })
  eq("tabs: selected-but-unpinned -> default", n3.selectedTab, "activity")
  check("tabs: that tab stays unpinned", n3.unpinned.queue == true)

  -- unknown ids in unpinned are dropped
  local n4 = core.normalizeTabState({ unpinned = { nope = true, rewind = true } })
  eq("tabs: unknown unpinned id dropped", n4.unpinned.nope, nil)
  check("tabs: known unpinned id kept", n4.unpinned.rewind == true)

  -- canonical map form only: a stray non-true value is ignored (no array form)
  local n5 = core.normalizeTabState({ unpinned = { decisions = true, usage = "x" } })
  check("tabs: map-form unpinned kept", n5.unpinned.decisions == true)
  eq("tabs: non-true unpinned value ignored", n5.unpinned.usage, nil)

  -- injected tabs list (test override) is honored
  local n6 = core.normalizeTabState({ selectedTab = "x", unpinned = { y = true } },
                                     { { id = "activity" }, { id = "x" }, { id = "y" } })
  eq("tabs: injected list selection kept", n6.selectedTab, "x")
  check("tabs: injected list unpinned kept", n6.unpinned.y == true)
end

-- ---- L5: git Changes tab (parseGitStatus / parseGitDiff) ------------------
do
  -- 'changes' tab is registered in the canonical list
  check("git: changes tab present", core.detailTabIds().changes == true)

  -- empty / nil input -> empty result
  eq("git: nil status -> 0 files", #core.parseGitStatus(nil).files, 0)
  eq("git: empty status -> 0 total", core.parseGitStatus("").summary.total, 0)

  -- a representative porcelain -z stream (NUL-terminated records). Per the git
  -- -z spec (verified against real `git status --porcelain=v1 -z`): paths are
  -- VERBATIM (no C-quoting) and a renamed record is `XY <new>\0<old>` -- the NEW
  -- path first, then the ORIGINAL in a following NUL token.
  local z = " M src/app.lua\0" .. "?? new.txt\0" .. "A  added.lua\0"
         .. " D gone.lua\0" .. "R  renamed.lua\0old.lua\0"
  local s = core.parseGitStatus(z)
  eq("git: parsed 5 files", #s.files, 5)
  eq("git: modified path", s.files[1].path, "src/app.lua")
  eq("git: modified mark", s.files[1].mark, "M")
  eq("git: untracked mark", s.files[2].mark, "?")
  eq("git: untracked cls", s.files[2].cls, "untracked")
  eq("git: added mark", s.files[3].mark, "A")
  eq("git: deleted mark", s.files[4].mark, "D")
  eq("git: renamed mark", s.files[5].mark, "R")
  eq("git: renamed NEW path is first token", s.files[5].path, "renamed.lua")
  eq("git: renamed ORIG path is the extra token", s.files[5].orig, "old.lua")
  eq("git: summary modified", s.summary.modified, 1)
  eq("git: summary untracked", s.summary.untracked, 1)
  eq("git: summary added", s.summary.added, 1)
  eq("git: summary deleted", s.summary.deleted, 1)
  eq("git: summary renamed", s.summary.renamed, 1)
  eq("git: summary total", s.summary.total, 5)

  -- resolveDiffTarget: the security boundary -- a path NOT in the cached status set
  -- is refused; an in-set path returns ok=true + its rename orig (or nil).
  local allowed = { ["a.lua"] = false, ["b.lua"] = "old.lua", ["c.lua"] = "" }
  local okA, origA = core.resolveDiffTarget(allowed, "a.lua")
  check("resolveDiff: in-set no-rename ok", okA == true and origA == nil)
  local okB, origB = core.resolveDiffTarget(allowed, "b.lua")
  check("resolveDiff: in-set rename returns orig", okB == true and origB == "old.lua")
  -- empty-string orig still resolves ok=true but collapses to nil (never pass orig="" to gitDiff)
  local okC, origC = core.resolveDiffTarget(allowed, "c.lua")
  check("resolveDiff: empty orig -> nil (still served)", okC == true and origC == nil)
  local okX = core.resolveDiffTarget(allowed, "/etc/passwd")
  eq("resolveDiff: out-of-set REFUSED", okX, false)
  eq("resolveDiff: nil allowed -> refused", core.resolveDiffTarget(nil, "a.lua"), false)

  -- rename does NOT swallow the following real entry (consumes exactly one extra token)
  local z2 = "R  a.lua\0b.lua\0 M c.lua\0"
  local s2 = core.parseGitStatus(z2)
  eq("git: rename + next entry = 2 files", #s2.files, 2)
  eq("git: entry after rename parsed", s2.files[2].path, "c.lua")

  -- -z paths are verbatim: spaces and quote chars survive unmangled (no C-unescape)
  local z3 = ' M weird name.txt\0' .. ' M qu"ote.txt\0'
  local s3 = core.parseGitStatus(z3)
  eq("git: space in path verbatim", s3.files[1].path, "weird name.txt")
  eq("git: quote in path verbatim", s3.files[2].path, 'qu"ote.txt')

  -- two-sided XY codes: the index column (X) wins when it's non-blank/non-?,
  -- else the worktree column (Y). Locks the documented precedence.
  local z4 = "MM both.lua\0" .. "AM staged-add-wt-mod.lua\0" .. "MD del-in-wt.lua\0" .. " M wt-only.lua\0"
  local s4 = core.parseGitStatus(z4)
  eq("git: MM -> M", s4.files[1].mark, "M")
  eq("git: AM -> A (index wins)", s4.files[2].mark, "A")
  eq("git: MD -> M (index wins over worktree delete)", s4.files[3].mark, "M")
  eq("git: ' M' -> M (worktree when index blank)", s4.files[4].mark, "M")

  -- a head -c-truncated stream can cut a rename's ORIG token: safe-drop (orig=nil),
  -- still one file, still marked R, no crash and no swallowed next entry.
  local zt = "R  renamed.lua\0"
  local st = core.parseGitStatus(zt)
  eq("git: truncated rename = 1 file", #st.files, 1)
  eq("git: truncated rename still marks R", st.files[1].mark, "R")
  eq("git: truncated rename orig is nil", st.files[1].orig, nil)
end

-- ---- L5: export session archive ------------------------------------------
do
  -- basename: slug + UTC stamp, deterministic on injected now
  local t = 1781000000   -- a fixed epoch
  local bn = core.sessionExportBasename({ label = "My Cool Repo!" }, t)
  check("export: basename prefix", bn:find("^session%-My%-Cool%-Repo%-") ~= nil)
  check("export: basename has UTC stamp", bn:find("%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$") ~= nil)
  eq("export: basename deterministic", core.sessionExportBasename({ label = "My Cool Repo!" }, t), bn)
  -- slug collapses unsafe chars; falls back when empty
  check("export: unsafe chars slugged", core.sessionExportBasename({ label = "a/b c:d" }, t):find("a%-b%-c%-d", 1) ~= nil)
  check("export: empty label -> session", core.sessionExportBasename({}, t):find("^session%-session%-") ~= nil)
  -- prefers label > name > projectKey > key
  check("export: falls back to projectKey", core.sessionExportBasename({ projectKey = "proj" }, t):find("session%-proj%-") ~= nil)
  -- review fix: dot hygiene -- no leading/trailing/repeated dots in the folder name
  check("export: repeated dots collapse", core.sessionExportBasename({ label = "a...b" }, t):find("session%-a%.b%-", 1) ~= nil)
  check("export: dot-only label -> session", core.sessionExportBasename({ label = ".." }, t):find("^session%-session%-") ~= nil)
  check("export: leading/trailing dots stripped", core.sessionExportBasename({ label = ".secret." }, t):find("session%-secret%-", 1) ~= nil)

  -- counters: per-type tally
  local evs = {
    { type = "prompt", session_id = "s" },
    { type = "tool_request", session_id = "s", tool = "Bash" },
    { type = "decision", session_id = "s", outcome = "deny" },
    { type = "decision", session_id = "s", outcome = "allow" },
    { type = "error", session_id = "s" },
    { type = "escalation", session_id = "s" },
    { type = "prompt", session_id = "other" },
  }
  local c = core.sessionExportCounters(evs)
  eq("export: counters prompts", c.prompts, 2)   -- counts ALL given (filter happens upstream)
  eq("export: counters toolRequests", c.toolRequests, 1)
  eq("export: counters denials", c.denials, 1)
  eq("export: counters approvals", c.approvals, 1)
  eq("export: counters errors", c.errors, 1)
  eq("export: counters escalations", c.escalations, 1)
  eq("export: counters empty", core.sessionExportCounters({}).total, 0)
  -- unknown / missing event types bump ONLY total, never a real bucket (else-less dispatch)
  local cg = core.sessionExportCounters({ { type = "prompt" }, { type = "frobnicate" }, { type = nil } })
  eq("export: garbage type bumps only total", cg.total, 3)
  eq("export: garbage type -> prompts unchanged", cg.prompts, 1)
  eq("export: garbage type -> toolRequests 0", cg.toolRequests, 0)
  eq("export: garbage type -> errors 0", cg.errors, 0)

  -- uniquifyName: skip taken names with -N; injected existence predicate (pure)
  eq("uniquify: no collision keeps base", core.uniquifyName("s", function(_) return false end), "s")
  local taken = { ["s"] = true }
  eq("uniquify: one collision -> -2", core.uniquifyName("s", function(c) return taken[c] end), "s-2")
  local taken2 = { ["s"] = true, ["s-2"] = true }
  eq("uniquify: two collisions -> -3", core.uniquifyName("s", function(c) return taken2[c] end), "s-3")
  eq("uniquify: no predicate -> base", core.uniquifyName("s", nil), "s")

  -- meta DTO: shape + lineage/activity wiring + no prompt bodies
  local item = { label = "Repo", projectKey = "pk", session_id = "s", cwd = "/r",
                 provider = "anthropic", model = "claude-opus-4-8", status = "done" }
  local meta = core.sessionExportMeta(item, evs, { exportedAt = "2026-06-15T00:00:00Z", transcriptName = "transcript.jsonl" })
  eq("export: meta schema", meta.schema, "cc-session-export/1")
  eq("export: meta label", meta.label, "Repo")
  eq("export: meta provider", meta.provider, "anthropic")
  eq("export: meta model", meta.model, "claude-opus-4-8")
  eq("export: meta exportedAt", meta.exportedAt, "2026-06-15T00:00:00Z")
  eq("export: meta transcript name", meta.transcript, "transcript.jsonl")
  check("export: meta has lineage", type(meta.lineage) == "table")
  check("export: meta has activity", type(meta.activity) == "table")
  -- activity is filtered to THIS session (the 'other' prompt excluded)
  eq("export: meta activity session-scoped", meta.activity.prompts, 1)
  -- no prompt-body field leaks into the meta DTO
  eq("export: meta carries no prompt body", meta.prompt, nil)
  -- nil-safe
  check("export: meta nil-safe", type(core.sessionExportMeta(nil, nil, nil)) == "table")
end

-- ---- L5: post-run self-summary + onAutoApproved detector -------------------
do
  -- summaryPrompt: review-first framing, forbids further work, no transcript interp
  local p = core.summaryPrompt({ activity = "edited x" })
  check("summary: mentions self-summary", p:find("self%-summary") ~= nil)
  check("summary: forbids further changes", p:lower():find("do not make further") ~= nil)
  check("summary: deterministic (no item interp)", core.summaryPrompt({ activity = "other" }) == p)

  -- shouldSummarize: done + real local session + not stale/remote
  check("summary: done local eligible", core.shouldSummarize({ status="done", session_id="s" }) == true)
  check("summary: working not eligible", core.shouldSummarize({ status="working", session_id="s" }) == false)
  check("summary: stale not eligible", core.shouldSummarize({ status="done", session_id="s", stale=true }) == false)
  check("summary: remote not eligible", core.shouldSummarize({ status="done", session_id="s", remote={} }) == false)
  check("summary: no sid not eligible", core.shouldSummarize({ status="done" }) == false)

  -- stepSelfSummary: fires once on a fresh done edge; the summary's own done is skipped
  local st = {}
  local item = { key="k", status="done", session_id="s" }
  eq("summary: disabled -> no fire", core.stepSelfSummary(st, item, { enabled=false, prevStatus="working" }).fire, false)
  eq("summary: fresh done edge fires", core.stepSelfSummary(st, item, { enabled=true, prevStatus="working" }).fire, true)
  -- a fire ARMS pending (not fired) -- the dashboard promotes pending->fired only on delivery
  check("summary: fire arms pending, not fired", st.pending.k == true and st.fired.k == nil)
  -- the typed prompt drives working -> done again; that done must NOT re-fire (loop guard)
  eq("summary: summary's own done skipped (pending set)",
     core.stepSelfSummary(st, item, { enabled=true, prevStatus="working" }).fire, false)
  -- guard cleared -> a later real completion fires again
  core.stepSelfSummary(st, { key="k", status="idle", session_id="s" }, { enabled=true, prevStatus="done" })
  eq("summary: fires again after a clean completion",
     core.stepSelfSummary(st, item, { enabled=true, prevStatus="idle" }).fire, true)
  -- no edge when already done (prev==done)
  eq("summary: no edge when prev already done",
     core.stepSelfSummary({}, item, { enabled=true, prevStatus="done" }).fire, false)
  -- ineligible (stale) never fires even on a fresh edge
  eq("summary: stale never fires",
     core.stepSelfSummary({}, { key="k", status="done", session_id="s", stale=true }, { enabled=true, prevStatus="working" }).fire, false)
  -- missing key -> no fire (early guard; never index state with a nil key)
  eq("summary: missing key -> no fire",
     core.stepSelfSummary({}, { status="done", session_id="s" }, { enabled=true, prevStatus="working" }).fire, false)

  -- DELIVERED path: core.promoteSummary lands the paste (pending->fired); the summary's
  -- own done is then skipped via `fired` (exercises the REAL promotion, not a manual poke)
  local sd = {}
  core.stepSelfSummary(sd, item, { enabled=true, prevStatus="working" })   -- fire, pending=true
  core.promoteSummary(sd, "k", true)                                        -- landed paste
  check("summary: promote landed -> fired set, pending cleared", sd.fired.k == true and sd.pending.k == nil)
  eq("summary: delivered -> own done skipped", core.stepSelfSummary(sd, item, { enabled=true, prevStatus="working" }).fire, false)
  check("summary: guard fully cleared after own done", sd.fired.k == nil and sd.pending.k == nil)

  -- FAILED-delivery path: core.promoteSummary(landed=false) clears pending -> the next
  -- real done RETRIES (no orphaned guard)
  local sf = {}
  core.stepSelfSummary(sf, item, { enabled=true, prevStatus="working" })   -- fire, pending=true
  core.promoteSummary(sf, "k", false)                                       -- paste did NOT land
  check("summary: promote miss -> nothing armed", sf.fired.k == nil and sf.pending.k == nil)
  core.stepSelfSummary(sf, { key="k", status="idle", session_id="s" }, { enabled=true, prevStatus="done" })
  eq("summary: failed paste retries on the next real done",
     core.stepSelfSummary(sf, item, { enabled=true, prevStatus="idle" }).fire, true)
  -- promoteSummary nil-safe
  check("summary: promote nil key no-op", (function() local s={}; core.promoteSummary(s, nil, true); return next(s.fired)==nil end)())

  -- officialUsageStep(prev, status, bodyOk): log once per status run; recovery on the
  -- first DECODABLE 200; a garbage 200 is a no-op so a later good 200 still recovers.
  local sl, rc, np = core.officialUsageStep(nil, -1, false)
  check("usage: first failure logs", sl == true and rc == false and np == -1)
  sl, rc, np = core.officialUsageStep(-1, -1, false)
  check("usage: repeat failure no log", sl == false and np == -1)
  sl, rc, np = core.officialUsageStep(-1, 401, false)
  check("usage: status change logs", sl == true and np == 401)
  sl, rc, np = core.officialUsageStep(-1, 200, true)
  check("usage: recovery on first usable success", sl == false and rc == true and np == 200)
  sl, rc, np = core.officialUsageStep(200, 200, true)
  check("usage: steady success no log/recover", sl == false and rc == false and np == 200)
  sl, rc, np = core.officialUsageStep(nil, 200, true)
  check("usage: first-call success isn't a recovery", sl == false and rc == false and np == 200)
  -- DECODABLE-body gating (the dashboard edge that's easy to regress):
  sl, rc, np = core.officialUsageStep(-1, 200, false)
  check("usage: garbage 200 is a no-op (prev unchanged, no recover)", sl == false and rc == false and np == -1)
  -- ...and the full chain: garbage 200 keeps prev at the failure value, then a good 200 recovers
  sl, rc, np = core.officialUsageStep(np, 200, true)
  check("usage: good 200 after a garbage 200 still recovers", rc == true and np == 200)

  -- officialModelLimits: pull per-model WEEKLY limits out of the OAuth payload's
  -- `limits[]` (the model-scoped surface where Fable lives). Shape mirrors the live
  -- endpoint: a session entry, a weekly_all entry (scope null), and a weekly_scoped
  -- entry carrying scope.model.display_name.
  local function fableLimit(pct, active)
    return { kind = "weekly_scoped", group = "weekly", percent = pct, severity = "normal",
             resets_at = "2026-07-14T06:59:59Z", scope = { model = { id = false, display_name = "Fable" } },
             is_active = active }
  end
  local base = {
    { kind = "session", group = "session", percent = 5, scope = false, is_active = true },
    { kind = "weekly_all", group = "weekly", percent = 1, scope = false, is_active = false },
  }
  -- dormant Fable (0%, inactive) -> present but show=false ("hide when unavailable")
  do
    local L = { limits = { base[1], base[2], fableLimit(0, false) } }
    local r = core.officialModelLimits(L)
    check("modelLimits: dormant Fable parsed (1 entry)", #r == 1)
    check("modelLimits: model name is Fable", r[1] and r[1].model == "Fable")
    check("modelLimits: dormant (0%, inactive) -> show=false", r[1] and r[1].show == false)
    check("modelLimits: percent + resetsAt carried", r[1] and r[1].percent == 0 and r[1].resetsAt == "2026-07-14T06:59:59Z")
    check("modelLimits: weekly_all (scope=false) + session excluded", #r == 1)
  end
  -- active Fable -> show=true regardless of percent
  do
    local r = core.officialModelLimits({ limits = { fableLimit(0, true) } })
    check("modelLimits: active Fable -> show=true", r[1] and r[1].show == true and r[1].active == true)
  end
  -- active with an ABSENT percent -> show=true, percent stays nil (not coerced to 0).
  -- The JS render is the only place the 0-fallback happens (Math.round(ml.percent||0)),
  -- so core must hand it a genuine nil rather than masking it.
  do
    local r = core.officialModelLimits({ limits = { fableLimit(nil, true) } })
    check("modelLimits: active + nil percent -> show=true, percent stays nil",
          r[1] and r[1].show == true and r[1].percent == nil)
  end
  -- nonzero usage while inactive -> show=true (a hit cap still surfaces)
  do
    local r = core.officialModelLimits({ limits = { fableLimit(97, false) } })
    check("modelLimits: 97% inactive -> show=true (capped usage visible)", r[1] and r[1].show == true and r[1].percent == 97)
  end
  -- multiple scoped models sorted by name; a malformed entry is skipped, not fatal
  do
    local L = { limits = {
      { kind = "weekly_scoped", group = "weekly", percent = 10, scope = { model = { display_name = "Opus" } }, is_active = true },
      fableLimit(50, true),
      { kind = "weekly_scoped", group = "weekly", percent = 3, scope = { model = {} } },  -- no display_name -> skip
      "junk", 42,                                                                          -- non-tables -> skip
    } }
    local r = core.officialModelLimits(L)
    check("modelLimits: two valid scoped models (malformed skipped)", #r == 2)
    check("modelLimits: sorted by model name (Fable < Opus)", r[1].model == "Fable" and r[2].model == "Opus")
  end
  -- defensive: no limits array / wrong types -> [] (never errors, never a nil deref)
  eq("modelLimits: no limits key -> empty", #core.officialModelLimits({ five_hour = {} }), 0)
  eq("modelLimits: limits not a table -> empty", #core.officialModelLimits({ limits = "x" }), 0)
  eq("modelLimits: non-table payload -> empty", #core.officialModelLimits("nope"), 0)
  eq("modelLimits: nil payload -> empty", #core.officialModelLimits(nil), 0)

  -- modelLimitRowsToShow: the render-ready rows -- show-filtered + de-duped against the
  -- legacy Weekly·Sonnet line (drawn only when official.seven_day_sonnet.utilization is
  -- non-nil). This is where the JS used to decide; lifting it here makes it testable.
  local function scoped(name, pct, active)
    return { kind = "weekly_scoped", group = "weekly", percent = pct, is_active = active,
             scope = { model = { display_name = name } } }
  end
  -- dormant models are dropped (show=false), active/nonzero kept, sorted by name
  do
    local L = { limits = { scoped("Fable", 0, false), scoped("Opus", 12, true) } }
    local r = core.modelLimitRowsToShow(L)
    eq("rowsToShow: dormant Fable dropped, active Opus kept", #r, 1)
    check("rowsToShow: kept row is Opus", r[1] and r[1].model == "Opus")
  end
  -- Sonnet de-dup: a scoped Sonnet collapses onto the legacy line when it renders...
  do
    local L = { seven_day_sonnet = { utilization = 5 }, limits = { scoped("Sonnet", 40, true) } }
    eq("rowsToShow: scoped Sonnet de-duped vs the legacy Weekly·Sonnet line", #core.modelLimitRowsToShow(L), 0)
  end
  -- ...INCLUDING a VERSIONED name (the exact-match bug: "Sonnet 4.6" must still collapse)
  do
    local L = { seven_day_sonnet = { utilization = 5 }, limits = { scoped("Sonnet 4.6", 40, true) } }
    eq("rowsToShow: versioned 'Sonnet 4.6' still de-dups (prefix, not exact)", #core.modelLimitRowsToShow(L), 0)
  end
  -- but WITHOUT a legacy Sonnet line, a scoped Sonnet is drawn (nothing to collide with)
  do
    local L = { limits = { scoped("Sonnet 4.6", 40, true) } }
    local r = core.modelLimitRowsToShow(L)
    check("rowsToShow: no legacy line -> scoped Sonnet is kept", #r == 1 and r[1].model == "Sonnet 4.6")
  end
  -- seven_day_sonnet PRESENT but utilization nil -> the legacy Weekly·Sonnet line does
  -- NOT render, so a scoped Sonnet must NOT be de-duped. Pins the `utilization ~= nil`
  -- conjunct of the sonnetLegacy gate (the JS mirror guards on it too); without this a
  -- relaxed gate (`type(...)=="table"` alone) would wrongly hide the row and pass.
  do
    local L = { seven_day_sonnet = {}, limits = { scoped("Sonnet", 40, true) } }
    local r = core.modelLimitRowsToShow(L)
    check("rowsToShow: sonnet table present but utilization nil -> scoped Sonnet KEPT",
          #r == 1 and r[1].model == "Sonnet")
  end
  -- a non-Sonnet family (Fable) is never touched by the Sonnet de-dup
  do
    local L = { seven_day_sonnet = { utilization = 5 }, limits = { scoped("Fable", 63, true) } }
    local r = core.modelLimitRowsToShow(L)
    check("rowsToShow: Fable unaffected by the Sonnet legacy line", #r == 1 and r[1].model == "Fable")
  end
  eq("rowsToShow: no payload -> empty", #core.modelLimitRowsToShow(nil), 0)

  -- usageLimitAlerts: the plan-limit guard's pure decision -- one alert per window
  -- crossing, keyed by resets_at so the same window never re-fires but a rolled
  -- window re-arms. Covers session/weekly/legacy-Sonnet/per-model (Fable) bars.
  local function officialAt(sessPct, weekPct, fablePct, resets)
    return {
      five_hour = { utilization = sessPct, resets_at = resets or "R1" },
      seven_day = { utilization = weekPct, resets_at = resets or "R1" },
      limits = { { kind = "weekly_scoped", group = "weekly", percent = fablePct,
                   is_active = true, resets_at = resets or "R1",
                   scope = { model = { display_name = "Fable" } } } },
    }
  end
  do
    local fired = {}
    local a = core.usageLimitAlerts(officialAt(92, 10, 5), fired)
    eq("limitAlerts: session 92% crosses default 90 -> one alert", #a, 1)
    check("limitAlerts: alert is the session window", a[1] and a[1].key == "session" and a[1].percent == 92)
    eq("limitAlerts: memo records the window", fired.session, "R1")
    -- same window again -> silent (once per window, not per poll)
    eq("limitAlerts: same resets_at stays silent", #core.usageLimitAlerts(officialAt(95, 10, 5), fired), 0)
    -- window rolls (new resets_at) while still over -> re-arms exactly once
    local b = core.usageLimitAlerts(officialAt(95, 10, 5, "R2"), fired)
    eq("limitAlerts: rolled window re-fires once", #b, 1)
  end
  do
    local fired = {}
    local a = core.usageLimitAlerts(officialAt(10, 20, 97), fired)
    eq("limitAlerts: Fable 97% fires the per-model window", #a, 1)
    check("limitAlerts: per-model key + label", a[1] and a[1].key == "weekly:Fable"
          and a[1].label == "Weekly · Fable")
  end
  do
    -- legacy Sonnet line fires its own window key
    local fired = {}
    local o = { seven_day_sonnet = { utilization = 91, resets_at = "R1" } }
    local a = core.usageLimitAlerts(o, fired)
    check("limitAlerts: legacy Sonnet line fires weekly:Sonnet", #a == 1 and a[1].key == "weekly:Sonnet")
  end
  do
    -- custom threshold + below-threshold silence + nil-percent guard
    local fired = {}
    eq("limitAlerts: custom threshold 50 fires at 55",
       #core.usageLimitAlerts(officialAt(55, 1, 1), fired, { threshold = 50 }), 1)
    eq("limitAlerts: below threshold silent", #core.usageLimitAlerts(officialAt(10, 10, 10), {}), 0)
    local oNil = { limits = { { kind = "weekly_scoped", group = "weekly", is_active = true,
                                scope = { model = { display_name = "Fable" } } } } }
    eq("limitAlerts: active model with nil percent never fires", #core.usageLimitAlerts(oNil, {}), 0)
  end
  eq("limitAlerts: non-table payload -> empty", #core.usageLimitAlerts("x", {}), 0)
  eq("limitAlerts: non-table memo -> empty (no throw)", #core.usageLimitAlerts(officialAt(99, 99, 99), nil), 0)

  -- #1-pin: the memo is a SET of warned windows per key, not a single last-value
  -- slot. A payload that alternates two representations of one window (resets_at
  -- present <-> absent -- the changelog notes the legacy flat fields are "usually
  -- null", i.e. unstable) used to flip the slot every 180s poll and re-fire
  -- forever (4 alerts in 4 polls). Now: at most one alert per distinct window
  -- string, then silence on every alternation.
  do
    local fired = {}
    local withReset = { five_hour = { utilization = 95, resets_at = "R1" } }
    local noReset   = { five_hour = { utilization = 95 } }  -- resets_at omitted
    local total = #core.usageLimitAlerts(withReset, fired)       -- R1 window: fires
    total = total + #core.usageLimitAlerts(noReset, fired)       -- "no-reset": fires once
    total = total + #core.usageLimitAlerts(withReset, fired)     -- R1 again: silent
    total = total + #core.usageLimitAlerts(noReset, fired)       -- nil again: silent
    total = total + #core.usageLimitAlerts(withReset, fired)     -- still silent
    eq("#1-pin: A<->nil resets_at jitter is bounded at 2 alerts, then silent", total, 2)
    -- a genuinely NEW window still re-arms exactly once
    eq("#1-pin: a real window roll still re-fires once",
       #core.usageLimitAlerts({ five_hour = { utilization = 95, resets_at = "R2" } }, fired), 1)
  end
  -- #1-pin: rows are de-duped by key within one call. Two weekly-scoped limits[]
  -- entries sharing a display_name (two metered versions both named "Sonnet")
  -- used to BOTH fire on every poll (the second consider() overwrote the memo
  -- the first had just written): 2 alerts/poll, forever.
  do
    local fired = {}
    local twoSonnets = { limits = {
      { kind = "weekly_scoped", group = "weekly", percent = 95, is_active = true,
        resets_at = "RA", scope = { model = { display_name = "Sonnet" } } },
      { kind = "weekly_scoped", group = "weekly", percent = 96, is_active = true,
        resets_at = "RB", scope = { model = { display_name = "Sonnet" } } },
    } }
    eq("#1-pin: duplicate display_name rows fire ONCE (first eligible wins)",
       #core.usageLimitAlerts(twoSonnets, fired), 1)
    eq("#1-pin: the duplicate pair stays silent on the next poll",
       #core.usageLimitAlerts(twoSonnets, fired), 0)
    eq("#1-pin: ...and the poll after that (no ping-pong storm)",
       #core.usageLimitAlerts(twoSonnets, fired), 0)
  end

  -- newestAutoApprove: newest automated allow ts; ignores human + denies + other sids
  local evs = {
    { type="decision", session_id="s", outcome="allow", by="autoAllow", ts=100 },
    { type="decision", session_id="s", outcome="allow", by="autopilot", ts=300 },
    { type="decision", session_id="s", outcome="allow", by="human",     ts=400 },  -- manual: ignored
    { type="decision", session_id="s", outcome="deny",  by="autoDeny",  ts=500 },  -- deny: ignored
    { type="decision", session_id="other", outcome="allow", by="autopilot", ts=999 },  -- other sid
  }
  eq("autoApprove: newest automated allow", core.newestAutoApprove(evs, "s"), 300)
  eq("autoApprove: none for unknown sid", core.newestAutoApprove(evs, "nope"), nil)
  eq("autoApprove: nil sid -> nil", core.newestAutoApprove(evs, nil), nil)
  eq("autoApprove: empty -> nil", core.newestAutoApprove({}, "s"), nil)
end

-- ---- L5: PR/MR status per tile (parsePrStatus / prBadge) -------------------
do
  local op = core.parsePrStatus('{"number":7,"state":"OPEN","url":"https://x/7","title":"Add thing"}')
  eq("pr: number", op.number, 7)
  eq("pr: state lowercased", op.state, "open")
  eq("pr: url", op.url, "https://x/7")
  eq("pr: title", op.title, "Add thing")
  eq("pr: badge open", core.prBadge(op), "PR #7 open")
  eq("pr: merged state", core.parsePrStatus('{"number":9,"state":"MERGED","url":"u"}').state, "merged")
  eq("pr: closed state", core.parsePrStatus('{"number":9,"state":"CLOSED"}').state, "closed")
  -- draft = OPEN + isDraft
  eq("pr: draft state", core.parsePrStatus('{"number":3,"state":"OPEN","isDraft":true}').state, "draft")
  -- number-without-state -> "unknown" (never a trailing-space badge / empty pr- class)
  local ns = core.parsePrStatus('{"number":7}')
  eq("pr: missing state -> unknown", ns.state, "unknown")
  eq("pr: badge has no trailing space", core.prBadge(ns), "PR #7 unknown")
  -- no PR / garbage / missing number -> nil
  eq("pr: empty -> nil", core.parsePrStatus(""), nil)
  eq("pr: gh 'no pr' text (no brace) -> nil", core.parsePrStatus("no pull requests found"), nil)
  -- brace present but UNdecodable -> the pcall/decode path returns nil (not the brace guard)
  eq("pr: brace but malformed json -> nil", core.parsePrStatus("{not json"), nil)
  eq("pr: truncated object -> nil", core.parsePrStatus('{"number":'), nil)
  eq("pr: object without number -> nil", core.parsePrStatus('{"state":"OPEN"}'), nil)
  -- present-but-non-numeric number: guard passes (not nil) but tonumber fails -> treat as no
  -- PR (else number=nil silently nulls the badge). gh's --json number is always an int.
  eq("pr: non-numeric string number -> nil", core.parsePrStatus('{"number":"x","state":"OPEN"}'), nil)
  eq("pr: boolean number -> nil", core.parsePrStatus('{"number":true,"state":"OPEN"}'), nil)
  -- a numeric STRING still parses (tonumber coerces) -- gh won't emit this, but it's the boundary
  eq("pr: numeric-string number coerces", core.parsePrStatus('{"number":"7","state":"OPEN"}').number, 7)
  eq("pr: badge nil for non-table", core.prBadge(nil), nil)
  eq("pr: badge nil without number", core.prBadge({ state = "open" }), nil)

  -- isOpenableUrl: the open-url scheme guard (http(s) + a host; reject smuggled schemes)
  check("pr: https openable", core.isOpenableUrl("https://github.com/x/y/pull/7") == true)
  check("pr: http openable", core.isOpenableUrl("http://x") == true)
  check("pr: file:// rejected", core.isOpenableUrl("file:///etc/passwd") == false)
  check("pr: javascript: rejected", core.isOpenableUrl("javascript:alert(1)") == false)
  check("pr: data: rejected", core.isOpenableUrl("data:text/html,x") == false)
  check("pr: non-anchored https rejected", core.isOpenableUrl("x https://y") == false)
  check("pr: nil url rejected", core.isOpenableUrl(nil) == false)
  -- boundary cases: empty string (type ok, match fails) and a hostless scheme are rejected
  check("pr: empty url rejected", core.isOpenableUrl("") == false)
  check("pr: bare https:// (no host) rejected", core.isOpenableUrl("https://") == false)
  check("pr: triple-slash (empty host) rejected", core.isOpenableUrl("https:///path") == false)
  -- the host char must be non-whitespace (so " " / tab can't stand in for a host)
  check("pr: whitespace-only host rejected", core.isOpenableUrl("https:// github.com") == false)
  check("pr: tab host rejected", core.isOpenableUrl("https://\tx") == false)
  -- scheme is case-insensitive (RFC 3986); only the scheme, not the path
  check("pr: uppercase HTTPS:// accepted", core.isOpenableUrl("HTTPS://github.com/x") == true)
  check("pr: mixed-case Http:// accepted", core.isOpenableUrl("Http://x") == true)
  -- ...but case-insensitivity must NOT open the smuggle door: uppercase non-http rejected
  check("pr: uppercase FILE:// still rejected", core.isOpenableUrl("FILE:///etc/passwd") == false)
  check("pr: uppercase JAVASCRIPT: still rejected", core.isOpenableUrl("JAVASCRIPT:alert(1)") == false)
  check("pr: mixed-case Data: still rejected", core.isOpenableUrl("Data:text/html,x") == false)
end

-- ---- L5: gh PR-status poll planner (hung-task aware) + reapUnbacked --------
do
  local function plan(cached, inflight, now) return core.prPollPlan(cached, inflight, now, { ttl = 180, retryTtl = 20 }) end
  local p = plan(nil, nil, 1000)
  check("prpoll: cold start", p.act == "start" and p.killStale == false)
  p = plan({ ts = 1000, data = { number = 1 } }, nil, 1100)
  check("prpoll: fresh data within TTL skips", p.act == "skip")
  p = plan({ ts = 1000, data = { number = 1 } }, nil, 1181)
  check("prpoll: stale data re-polls", p.act == "start" and p.killStale == false)
  p = plan({ ts = 1000, data = nil }, { ts = 1000 }, 1005)
  check("prpoll: in-flight poll within retry window skips", p.act == "skip")
  -- the headline: nil data past the retry window with a still-in-flight task = HUNG gh ->
  -- kill the orphaned task and re-poll (the bug both reviews flagged: this was unreachable)
  p = plan({ ts = 1000, data = nil }, { ts = 1000 }, 1025)
  check("prpoll: hung gh past retry window kills + re-polls", p.act == "start" and p.killStale == true)
  -- a refresh poll that HAD data but hangs is reclaimed at the hung deadline (default = the
  -- 20s retry window here), WITHOUT waiting for the full cache TTL -- the hung check runs
  -- before the cache-freshness skip, so a frozen badge recovers fast.
  p = plan({ ts = 1000, data = { number = 1 } }, { ts = 1000 }, 1025)
  check("prpoll: hung refresh poll (had data) reclaimed at deadline, not full TTL", p.act == "start" and p.killStale == true)
  p = plan(nil, { ts = 1000 }, 1005)
  check("prpoll: in-flight, no cache, within window skips", p.act == "skip")
  -- defaults (no opts): ttl 180 / retry 20
  check("prpoll: default retryTtl re-polls nil data past 20s", core.prPollPlan({ ts = 0, data = nil }, nil, 25).act == "start")
  -- opts.deadline OVERRIDE is independent of the cache window (effTtl). Had data so
  -- effTtl=180: with deadline=30 a 50s-old in-flight task is hung -> start+kill, even though
  -- the cache is "fresh" (50 < 180).
  p = core.prPollPlan({ ts = 1000, data = { number = 1 } }, { ts = 1000 }, 1050, { ttl = 180, retryTtl = 20, deadline = 30 })
  check("prpoll: deadline override flips killStale inside the cache window", p.act == "start" and p.killStale == true)
  -- ...and a generous deadline keeps a not-yet-hung in-flight poll skipped despite a tiny effTtl
  p = core.prPollPlan({ ts = 1000, data = nil }, { ts = 1000 }, 1050, { ttl = 180, retryTtl = 20, deadline = 200 })
  check("prpoll: deadline override (200) keeps an alive poll skipped", p.act == "skip")

  -- prCallbackOwns: does this callback still own its root's slot?
  local tk = {}  -- stand-in for an hs.task (the guard uses reference identity only)
  check("prowns: same task still owns", core.prCallbackOwns({ task = tk, ts = 1 }, tk) == true)
  check("prowns: superseded by a newer poll -> not owned (drop, no clobber)", core.prCallbackOwns({ task = {}, ts = 2 }, tk) == false)
  check("prowns: reaped latch (nil) -> not owned (drop, no re-populate)", core.prCallbackOwns(nil, tk) == false)

  -- reapUnbacked: prune cache entries not backed by a live key, in place
  local cache = { ["/a"] = 1, ["/b"] = 2, ["/c"] = 3 }
  local ret = core.reapUnbacked(cache, { ["/a"] = true, ["/c"] = true })
  check("reap: drops unbacked key", cache["/b"] == nil)
  check("reap: keeps backed keys", cache["/a"] == 1 and cache["/c"] == 3)
  check("reap: returns the same table (in place)", ret == cache)
  check("reap: nil liveKeys clears all", (function() local c = { a = 1, b = 2 }; core.reapUnbacked(c, nil); return next(c) == nil end)())
  check("reap: non-table cache is a no-op", core.reapUnbacked(nil, {}) == nil)
end

-- ---- DR1/DR2: subagent fan-out trace + background-activity indicator -------
do
  eq("subagentsDir: from transcript_path",
     core.subagentsDir("/p/projects/ENC/sess-uuid.jsonl"), "/p/projects/ENC/sess-uuid/subagents")
  eq("subagentsDir: nil without .jsonl", core.subagentsDir("/p/sess"), nil)
  eq("subagentsDir: nil for non-string", core.subagentsDir(nil), nil)

  local meta = core.subagentMeta(core.json.encode(
    { type = "user", agentId = "a382c84e9550c1460", slug = "do-a-full-scan-sunny-panda", isSidechain = true }))
  eq("subagentMeta: agentId", meta and meta.agentId, "a382c84e9550c1460")
  eq("subagentMeta: slug", meta and meta.slug, "do-a-full-scan-sunny-panda")
  eq("subagentMeta: nil for non-json", core.subagentMeta("not json"), nil)
  eq("subagentMeta: nil when no agentId", core.subagentMeta(core.json.encode({ type = "user" })), nil)
  -- prompt: the agent's first user message (the real task), as a string or a text block
  eq("subagentMeta: prompt from string content",
     core.subagentMeta(core.json.encode({ agentId = "z1", message = { role = "user", content = "Author the spec" } })).prompt,
     "Author the spec")
  eq("subagentMeta: prompt from first text block",
     core.subagentMeta(core.json.encode({ agentId = "z2", message = { content = { { type = "text", text = "Review auth.ts" } } } })).prompt,
     "Review auth.ts")
  eq("subagentMeta: prompt nil when absent",
     core.subagentMeta(core.json.encode({ agentId = "z3", slug = "s" })).prompt, nil)

  eq("subagentLabel: humanizes slug",
     core.subagentLabel("can-you-review-if-swirling-otter", "x"), "can you review if swirling otter")
  eq("subagentLabel: falls back to short id", core.subagentLabel(nil, "a382c84e9550c1460"), "agent a382c84e")
  eq("subagentLabel: prefers the prompt over the slug",
     core.subagentLabel("random-prancy-hippo", "x", "Verify the missing-password coercion path"),
     "Verify the missing-password coercion path")
  eq("subagentLabel: collapses whitespace in the prompt",
     core.subagentLabel(nil, "x", "  do   a\nthing  "), "do a thing")
  check("subagentLabel: truncates a long prompt with an ellipsis", (function()
    local lbl = core.subagentLabel(nil, "x", string.rep("word ", 40))
    return #lbl <= 84 and lbl:sub(-3) == "…"
  end)())

  local now = 100000
  local tailA = core.json.encode(
    { type = "assistant", message = { content = { { type = "text", text = "Scanning the payments module" } } } })
  local files = {
    { name = "agent-a1.jsonl", mtime = now - 5,
      firstLine = core.json.encode({ agentId = "a1", slug = "full-scan-sunny-panda" }), tail = tailA },
    { name = "workflows/wf_abc123/agent-b2.jsonl", mtime = now - 500,
      firstLine = core.json.encode({ agentId = "b2", slug = "deep-research-otter" }) },
    { name = "notes.txt", mtime = now },            -- ignored (not an agent file)
  }
  local tree = core.subagentTree(files, now, { activeWindow = 45 })
  eq("subagentTree: counts agents only", tree.count, 2)
  eq("subagentTree: running within window", tree.runningCount, 1)
  check("subagentTree: active flag", tree.active == true)
  eq("subagentTree: newest first", tree.agents[1].agentId, "a1")
  eq("subagentTree: keeps relative name (for drill-in)", tree.agents[1].name, "agent-a1.jsonl")
  eq("subagentTree: lastLine snippet", tree.agents[1].lastLine, "Scanning the payments module")
  eq("subagentTree: workflow grouping", tree.agents[2].wfId, "wf_abc123")
  eq("subagentTree: kind=workflow", tree.agents[2].kind, "workflow")
  check("subagentTree: workflows map counts",
        tree.workflows["wf_abc123"] ~= nil and tree.workflows["wf_abc123"].count == 1)
  -- a workflow agent's label comes from its first prompt, not its (random) fleet slug
  local treeP = core.subagentTree({
    { name = "workflows/wf_x/agent-p1.jsonl", mtime = now,
      firstLine = core.json.encode({ agentId = "p1", slug = "great-prancy-hippo",
        message = { content = { { type = "text", text = "Author a new OpenAPI spec file" } } } }) },
  }, now, { activeWindow = 45 })
  eq("subagentTree: label uses the agent's prompt, not the slug",
     treeP.agents[1].label, "Author a new OpenAPI spec file")

  local function al(t) return core.json.encode({ type = "assistant", message = { content = { { type = "text", text = t } } } }) end
  local recentTail = al("first step") .. "\n" .. core.json.encode({ type = "user", message = { content = "x" } }) .. "\n" .. al("second step")
  local recent = core.transcriptRecent(recentTail, 12, 200)
  eq("transcriptRecent: count (assistant only)", #recent, 2)
  eq("transcriptRecent: chronological order", recent[1], "first step")
  eq("transcriptRecent: newest last", recent[2], "second step")
  eq("transcriptRecent: empty tail -> {}", #core.transcriptRecent("", 12), 0)
  eq("transcriptRecent: caps to n", #core.transcriptRecent(al("a").."\n"..al("b").."\n"..al("c"), 2), 2)

  check("subagentNameOk: direct agent file", core.subagentNameOk("agent-a1.jsonl") == true)
  check("subagentNameOk: workflow agent file", core.subagentNameOk("workflows/wf_abc123/agent-b2.jsonl") == true)
  check("subagentNameOk: rejects traversal", core.subagentNameOk("../../etc/passwd") == false)
  check("subagentNameOk: rejects absolute", core.subagentNameOk("/etc/passwd") == false)
  check("subagentNameOk: rejects non-agent file", core.subagentNameOk("notes.txt") == false)
  check("subagentNameOk: rejects empty", core.subagentNameOk("") == false)

  -- DR4: run score + regression trend (from ledger signals)
  local function ev(sid, t, extra) local e = { session_id = sid, type = t }; for k, v in pairs(extra or {}) do e[k] = v end; return e end
  eq("runScore: clean session = 100",
     core.runScore({ ev("s1", "decision", { outcome = "allow" }), ev("s1", "prompt") }, "s1").score, 100)
  eq("runScore: 1 error + 2 denies = 100-18-12 = 70",
     core.runScore({ ev("s1", "error"), ev("s1", "decision", { outcome = "deny" }), ev("s1", "decision", { outcome = "deny" }) }, "s1").score, 70)
  eq("runScore: clamps at 0", core.runScore({ ev("s1","error"),ev("s1","error"),ev("s1","error"),ev("s1","error"),ev("s1","error"),ev("s1","error") }, "s1").score, 0)
  eq("runScore: scopes to sid", core.runScore({ ev("s1","error"), ev("s2","error") }, "s2").score, 82)
  check("runScore: no data -> hadData false", core.runScore({}, "s1").hadData == false)
  -- trend: three sessions declining 100 -> 70 -> 40 (by ts) => regression
  local declining = {
    ev("a","decision",{outcome="allow",ts=10}),
    ev("b","error",{ts=20}), ev("b","decision",{outcome="deny",ts=21}), ev("b","decision",{outcome="deny",ts=22}),  -- 100-18-12=70
    ev("c","error",{ts=30}), ev("c","error",{ts=31}), ev("c","error",{ts=32}),  -- 100-54=46
  }
  local tr = core.scoreTrend(declining, { window = 3, drop = 12 })
  eq("scoreTrend: ordered oldest->newest", tr.series[1].sid, "a")
  eq("scoreTrend: newest is the worst", tr.series[3].score, 46)
  check("scoreTrend: flags the decline", tr.regression == true)
  local steady = core.scoreTrend({ ev("a","decision",{outcome="allow",ts=1}), ev("b","decision",{outcome="allow",ts=2}), ev("c","decision",{outcome="allow",ts=3}) }, {})
  check("scoreTrend: flat 100s -> no regression", steady.regression == false)
  check("scoreTrend: fewer than window -> no regression", core.scoreTrend({ ev("a","error",{ts=1}) }, {}).regression == false)

  -- DR5: cost estimate (Anthropic list prices; gateway/local skipped)
  eq("priceFamily: opus", core.priceFamily("claude-opus-4-8"), "opus")
  eq("priceFamily: sonnet", core.priceFamily("claude-sonnet-4-6"), "sonnet")
  eq("priceFamily: haiku", core.priceFamily("claude-haiku-4-5"), "haiku")
  eq("priceFamily: gateway model -> nil", core.priceFamily("gemini-2.5-pro"), nil)
  eq("priceFor: opus input rate", core.priceFor("claude-opus-4-8").input, 5.0)
  eq("priceFor: override merges", core.priceFor("claude-opus-4-8", { opus = { input = 4 } }).input, 4)
  eq("priceFor: override keeps un-set fields", core.priceFor("claude-opus-4-8", { opus = { input = 4 } }).output, 25.0)
  local cost = core.estimateCost({ ["claude-opus-4-8"] = { input = 1000000, output = 1000000, cacheCreate = 1000000, cacheRead = 1000000 } })
  eq("estimateCost: opus 1M each bucket", string.format("%.2f", cost.usd), "36.75")  -- 5 + 25 + 6.25 + 0.50
  check("estimateCost: priced flag set", cost.priced == true)
  local mixed = core.estimateCost({ ["claude-haiku-4-5"] = { input = 2000000 }, ["gemini-2.5-pro"] = { input = 5000000 } })
  eq("estimateCost: haiku 2M input = $2, gateway skipped", string.format("%.2f", mixed.usd), "2.00")
  eq("estimateCost: gateway listed as unpriced", mixed.unpriced[1], "gemini-2.5-pro")
  check("estimateCost: empty -> not priced", core.estimateCost({}).priced == false)

  -- DR6: per-session model auto-routing heuristic (pure; enable is per-session elsewhere)
  eq("suggestModel: empty -> nil", core.suggestModel("", {}), nil)
  eq("suggestModel: whitespace -> nil", core.suggestModel("   \n ", {}), nil)
  local sh = core.suggestModel("refactor the auth module", {})
  eq("suggestModel: hard keyword -> hard/opus", sh.tier, "hard"); eq("suggestModel: hard model", sh.model, "opus")
  check("suggestModel: keyword beats short length", core.suggestModel("debug it", {}).tier == "hard")
  local sc = core.suggestModel("fix a typo in the readme", {})
  eq("suggestModel: cheap keyword -> cheap/haiku", sc.tier, "cheap"); eq("suggestModel: cheap model", sc.model, "haiku")
  eq("suggestModel: short no-keyword -> cheap", core.suggestModel("update the header", {}).tier, "cheap")
  eq("suggestModel: mid-length no-keyword -> standard",
     core.suggestModel("please add a new endpoint that returns the list of active users for the dashboard view today", {}).tier, "standard")
  local longTask = string.rep("word ", 45)
  eq("suggestModel: long no-keyword -> hard", core.suggestModel(longTask, {}).tier, "hard")
  check("suggestModel: reason carries the keyword", core.suggestModel("optimize the query", {}).reason == "keyword: optimize")
  -- config overrides: remap the tier->model + thresholds
  local cfgOv = core.json.decode('{"automodel":{"models":{"cheap":"haiku-lite","standard":"sonnet","hard":"opus-max"},"cheapMax":2}}')
  eq("suggestModel: model map override", core.suggestModel("rename foo", cfgOv).model, "haiku-lite")
  eq("suggestModel: cheapMax override pushes 3-word to standard", core.suggestModel("add new feature", cfgOv).tier, "standard")
  -- R1-33: a PARTIAL models override (only cheap) must keep standard/hard working via
  -- the defaults (was: M.config returns the node as-is, so standard/hard went nil ->
  -- suggestModel returned nil for those tiers -- silent routing loss).
  local cfgPartial = core.json.decode('{"automodel":{"models":{"cheap":"haiku-lite"}}}')
  eq("suggestModel: partial override keeps cheap tier", core.suggestModel("fix a typo", cfgPartial).model, "haiku-lite")
  eq("suggestModel: partial override falls back to default hard model",
     core.suggestModel("refactor the auth module", cfgPartial).model, "opus")
  eq("suggestModel: partial override falls back to default standard model",
     core.suggestModel("please add a new endpoint that returns the list of active users for the dashboard view today", cfgPartial).model, "sonnet")
  -- R2-28: an inverted/overlapping threshold config (cheapMax >= hardMin) must NOT
  -- silently classify a long task as cheap -- the bad pair falls back to the defaults.
  local cfgBad = core.json.decode('{"automodel":{"cheapMax":50,"hardMin":10}}')
  eq("suggestModel: inverted thresholds -> long task still hard",
     core.suggestModel(string.rep("word ", 45), cfgBad).tier, "hard")

  -- spawn: a brand-new project (opts.isNew) marks the extension spec coldStart, and the
  -- open args gain --disable-workspace-trust so the trust modal can't swallow the prompt.
  local newSpec = core.spawnSpec("vscode", "/p/Farter", "build me a thing", { isNew = true, vscodeFlavor = "extension" })
  check("spawn: new project => extension flavor", newSpec.flavor == "extension")
  check("spawn: new project => coldStart", newSpec.coldStart == true)
  check("spawn: new project carries the task", newSpec.task == "build me a thing")
  local oldSpec = core.spawnSpec("vscode", "/p/Existing", "do x", { vscodeFlavor = "extension" })
  check("spawn: existing project => not coldStart", oldSpec.coldStart ~= true)
  local function hasArg(args, v) for _, a in ipairs(args) do if a == v then return true end end return false end
  check("vscodeOpenArgs: coldStart adds --disable-workspace-trust", hasArg(core.vscodeOpenArgs(newSpec), "--disable-workspace-trust"))
  check("vscodeOpenArgs: non-cold has NO trust flag", not hasArg(core.vscodeOpenArgs(oldSpec), "--disable-workspace-trust"))
  check("vscodeOpenArgs: project is the last arg", core.vscodeOpenArgs(newSpec)[#core.vscodeOpenArgs(newSpec)] == "/p/Farter")

  local bg = core.backgroundActivity(files, now, { activeWindow = 45 })
  check("backgroundActivity: active", bg.active == true)
  eq("backgroundActivity: count of recent", bg.count, 1)
  check("backgroundActivity: idle when all stale",
        core.backgroundActivity(files, now + 100000, { activeWindow = 45 }).active == false)
  check("backgroundActivity: empty list -> inactive", core.backgroundActivity({}, now, {}).active == false)
end

-- ---- stale-"done" self-heal: transcript-resumed override ------------------
do
  local function aline(ts)
    return core.json.encode({ type = "assistant", timestamp = ts,
                              message = { content = { { type = "text", text = "x" } } } })
  end
  local function uline(ts)  -- e.g. an IDE file-open injection (a user line)
    return core.json.encode({ type = "user", timestamp = ts,
                              message = { content = "<ide_opened_file>foo</ide_opened_file>" } })
  end
  local t0 = core.isoToEpoch("2026-06-18T14:00:00Z")
  check("resumed: isoToEpoch sanity", type(t0) == "number")
  -- genuinely done: the turn's final assistant line, then Stop bumped updated to t0+1
  check("resumed: genuine done not flagged",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z"), t0 + 1, 2) == false)
  -- resumed: previous done recorded updated=t0; a NEW assistant line 30s later
  check("resumed: new assistant after stale done -> working",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. aline("2026-06-18T14:00:30Z"), t0, 2) == true)
  -- an IDE-open (user line) newer than done must NOT flip to working
  check("resumed: IDE-open user line ignored",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. uline("2026-06-18T14:05:00Z"), t0 + 1, 2) == false)
  check("resumed: no assistant line -> false",
        core.transcriptResumed(uline("2026-06-18T14:05:00Z"), t0, 2) == false)
  check("resumed: within slack not flagged", core.transcriptResumed(aline("2026-06-18T14:00:01Z"), t0, 2) == false)
  check("resumed: nil updated -> false", core.transcriptResumed(aline("2026-06-18T14:00:30Z"), nil, 2) == false)
  check("resumed: empty tail -> false", core.transcriptResumed("", t0, 2) == false)

  -- R3-04 fix: a genuine human prompt after a stale "done" MUST resume the tile, even
  -- with no fresh assistant line yet (VS Code extension / Auto mode: the operator typed
  -- a new prompt but no UserPromptSubmit hook reached us).
  local function huline(ts, txt)   -- a genuine human-typed user prompt (array text block)
    return core.json.encode({ type = "user", timestamp = ts, message = { role = "user",
      content = { { type = "text", text = txt or "do the thing" } } } })
  end
  local function pairedUline(ts)    -- a real IDE submit: an <ide_opened_file> block + the prompt
    return core.json.encode({ type = "user", timestamp = ts, message = { role = "user", content = {
      { type = "text", text = "<ide_opened_file>opened /tmp/x.ts</ide_opened_file>" },
      { type = "text", text = "also review this handoff" } } } })
  end
  local function diagUline(ts)      -- a bare IDE diagnostics injection (no human text)
    return core.json.encode({ type = "user", timestamp = ts,
      message = { role = "user", content = "<ide_diagnostics>3 problems</ide_diagnostics>" } })
  end
  local function openUline(ts)      -- a bare IDE file-open injection, STRING content (the headline false-trigger)
    return core.json.encode({ type = "user", timestamp = ts,
      message = { role = "user", content = "<ide_opened_file>opened /tmp/x.ts</ide_opened_file>" } })
  end
  local function openUlineArr(ts)   -- a bare IDE file-open injection, ARRAY content (drives the table branch)
    return core.json.encode({ type = "user", timestamp = ts, message = { role = "user",
      content = { { type = "text", text = "<ide_opened_file>opened /tmp/x.ts</ide_opened_file>" } } } })
  end
  check("resumed: genuine human prompt after stale done -> working",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. huline("2026-06-18T14:00:30Z"), t0, 2) == true)
  check("resumed: lone human prompt newer than done -> working (no assistant line yet)",
        core.transcriptResumed(huline("2026-06-18T14:00:30Z"), t0, 2) == true)
  check("resumed: IDE-paired prompt (ide block + human text) -> working",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. pairedUline("2026-06-18T14:00:30Z"), t0, 2) == true)
  check("resumed: bare ide_diagnostics line ignored",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. diagUline("2026-06-18T14:05:00Z"), t0 + 1, 2) == false)
  -- The headline false-trigger: a lone <ide_opened_file> user line landing AFTER a stale done.
  -- ts (14:05) is unambiguously > updatedEpoch (t0+1) + slack, so a pass proves it's rejected by
  -- userHasHumanText (content strips to empty), NOT merely by the timestamp guard.
  check("resumed: bare ide_opened_file line ignored (string content)",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. openUline("2026-06-18T14:05:00Z"), t0 + 1, 2) == false)
  check("resumed: bare ide_opened_file line ignored (array content / table branch)",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. openUlineArr("2026-06-18T14:05:00Z"), t0 + 1, 2) == false)
  check("resumed: human prompt within slack not flagged",
        core.transcriptResumed(huline("2026-06-18T14:00:01Z"), t0, 2) == false)
end

-- ---- stale-"approval" self-heal: transcriptAwaitingTool ---------------------
do
  local function toolUse(name)  -- an assistant turn that emitted a tool_use (awaiting)
    return core.json.encode({ type = "assistant", timestamp = "2026-07-15T18:00:00Z",
      message = { content = { { type = "text", text = "let me run this" },
                              { type = "tool_use", name = name or "Bash", input = { command = "ls" } } } } })
  end
  local function toolResult()  -- the user turn carrying that tool's result (completed)
    return core.json.encode({ type = "user", timestamp = "2026-07-15T18:00:01Z",
      message = { content = { { type = "tool_result", content = "ok" } } } })
  end
  local function asstText()    -- an assistant turn that ended with plain text
    return core.json.encode({ type = "assistant", timestamp = "2026-07-15T18:00:02Z",
      message = { content = { { type = "text", text = "done thinking" } } } })
  end
  local attach = '{"type":"attachment","x":1}'  -- non-conversational noise, must be skipped
  -- GENUINE block: newest real event is a dangling tool_use -> awaiting (keep approval)
  check("awaiting: dangling tool_use -> true", core.transcriptAwaitingTool(toolUse("Bash")) == true)
  check("awaiting: dangling AskUserQuestion -> true", core.transcriptAwaitingTool(toolUse("AskUserQuestion")) == true)
  -- STALE: the tool completed (result landed) -> not awaiting (heal to working)
  check("awaiting: tool_use then tool_result -> false",
        core.transcriptAwaitingTool(toolUse("Bash") .. "\n" .. toolResult()) == false)
  -- attachment noise after the result is skipped; still not awaiting
  check("awaiting: attachment after result is skipped -> false",
        core.transcriptAwaitingTool(toolUse("Bash") .. "\n" .. toolResult() .. "\n" .. attach) == false)
  -- assistant ended with text (no tool) -> not awaiting
  check("awaiting: assistant text turn -> false", core.transcriptAwaitingTool(asstText()) == false)
  -- newest wins: an OLD dangling tool_use followed by a completed newer one -> not awaiting
  check("awaiting: newest completed pair wins over an older tool_use",
        core.transcriptAwaitingTool(toolUse("Bash") .. "\n" .. toolResult() .. "\n" .. toolUse("Bash") .. "\n" .. toolResult()) == false)
  check("awaiting: empty/garbage -> false",
        core.transcriptAwaitingTool("") == false and core.transcriptAwaitingTool("not json\n{bad") == false)
end

-- ---- approvalHealable: does a status=approval tile actually NEED you? --------
-- Heal a status=approval tile to "working" ONLY once the session has MOVED PAST the
-- pending, which needs BOTH transcript signals: awaiting==false (no DANGLING tool_use --
-- the terminal-CLI block sits at awaiting==true) AND progressed==true (the transcript has
-- advanced beyond when the approval was armed, it.since). progressed is load-bearing for
-- the VS Code extension, which BUFFERS the assistant message so a LIVE permission dialog
-- writes NO dangling tool_use: awaiting reads false (same as a finished tool) while the
-- transcript stays frozen at the pre-prompt turn. awaiting==false ALONE (the old rule)
-- healed real VS Code prompts to "Working", hiding a blocked session. permission_mode does
-- NOT change the outcome.
do
  local function tile(t) t.status = "approval"; return t end
  -- a dangling native tool -> KEEP "needs you", in EVERY mode, even when the transcript
  -- also progressed (a just-written tool_use IS newer than the arm time)
  check("approvalHealable: acceptEdits native Bash mid-call (awaiting) -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "acceptEdits" }), true, true) == false)
  check("approvalHealable: bypass native Bash awaiting -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "bypassPermissions" }), true, true) == false)
  check("approvalHealable: auto native Write awaiting -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Write" }, permission_mode = "auto" }), true, false) == false)
  check("approvalHealable: unknown tail (both nil) -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "acceptEdits" }), nil, nil) == false)
  -- THE VS Code fix: not awaiting (no dangling tool_use -- the extension buffers it) but the
  -- transcript is FROZEN before the arm time (progressed==false) -> a genuine live "Allow
  -- this bash command?" dialog -> KEEP "needs you". awaiting-alone healed this to "Working".
  check("approvalHealable: VS Code live prompt (not awaiting, not progressed) -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "acceptEdits" }), false, false) == false)
  -- heal only once the tool finished AND the session demonstrably moved on (the STUCK-
  -- pending case: the guard's resolution event was missed but the transcript advanced)
  check("approvalHealable: native tool done + progressed -> heal (true)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "acceptEdits" }), false, true) == true)
  check("approvalHealable: default-mode tool done + progressed -> heal (true)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, permission_mode = "default" }), false, true) == true)
  -- a CONFIRMED live prompt dialog (pending.prompt=true, set by cc-status.sh when a
  -- permission Notification DOES fire -- terminal sessions) is never healed, even progressed
  check("approvalHealable: prompt dialog flag -> keep even if progressed (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash", prompt = true }, permission_mode = "acceptEdits" }), false, true) == false)
  -- AskUserQuestion / gate follow the same two-signal rule
  check("approvalHealable: AskUserQuestion awaiting -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "AskUserQuestion" } }), true, true) == false)
  check("approvalHealable: AskUserQuestion resolved + progressed -> heal (true)",
        core.approvalHealable(tile({ pending = { tool = "AskUserQuestion" } }), false, true) == true)
  check("approvalHealable: gate=waiting awaiting -> keep (false)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, gate = "waiting" }), true, true) == false)
  check("approvalHealable: gate=waiting resolved + progressed -> heal (true)",
        core.approvalHealable(tile({ pending = { tool = "Bash" }, gate = "waiting" }), false, true) == true)
  -- guards: only approval tiles, only tool-scoped pendings (early returns, signals moot)
  check("approvalHealable: non-approval tile -> false",
        core.approvalHealable({ status = "working", pending = { tool = "Bash" } }, false, true) == false)
  check("approvalHealable: no pending tool (bare notification) -> false",
        core.approvalHealable(tile({ pending = {} }), false, true) == false
        and core.approvalHealable(tile({}), false, true) == false)
  check("approvalHealable: nil arg safe", core.approvalHealable(nil, false, true) == false)
end

-- ---- userHasHumanText: genuine prompt vs IDE-context / meta / tool-result injection --
do
  local function u(content, extra)
    local o = { type = "user", message = { role = "user", content = content } }
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return o
  end
  check("human: plain string prompt -> true", core.userHasHumanText(u("fix the bug")) == true)
  check("human: whitespace-only string -> false", core.userHasHumanText(u("   ")) == false)
  check("human: isMeta -> false", core.userHasHumanText(u("hi", { isMeta = true })) == false)
  check("human: bare ide_opened_file string -> false",
        core.userHasHumanText(u("<ide_opened_file>foo</ide_opened_file>")) == false)
  check("human: bare ide_diagnostics string -> false",
        core.userHasHumanText(u("<ide_diagnostics>2 problems</ide_diagnostics>")) == false)
  check("human: bare ide_opened_file array block -> false",
        core.userHasHumanText(u({ { type = "text", text = "<ide_opened_file>opened /tmp/x.ts</ide_opened_file>" } })) == false)
  check("human: ide_selection block alongside a real prompt -> true",
        core.userHasHumanText(u({ { type = "text", text = "<ide_selection>x</ide_selection>" },
                                  { type = "text", text = "do it" } })) == true)
  check("human: ide context prepended in one text block -> true",
        core.userHasHumanText(u({ { type = "text", text = "<ide_opened_file>f</ide_opened_file>\n\nrun tests" } })) == true)
  check("human: tool_result-only block -> false",
        core.userHasHumanText(u({ { type = "tool_result", content = "ok" } })) == false)
  check("human: non-table arg -> false", core.userHasHumanText("nope") == false)
end

-- ---- custom screen lock: salted-hash password ----------------------------
do
  local function fakeHash(s) return "H<" .. s .. ">" end
  local rec = core.lockRecord("salt1", "hunter2", fakeHash)
  eq("lock: record salt", rec and rec.salt, "salt1")
  eq("lock: record hash", rec and rec.hash, "H<salt1:hunter2>")
  check("lock: verify correct password", core.lockVerify(rec, "hunter2", fakeHash) == true)
  check("lock: verify wrong password", core.lockVerify(rec, "wrong", fakeHash) == false)
  check("lock: verify nil record", core.lockVerify(nil, "hunter2", fakeHash) == false)
  check("lock: verify empty input", core.lockVerify(rec, "", fakeHash) == false)
  check("lock: record needs a hasher", core.lockRecord("s", "p", nil) == nil)
  check("lock: salt changes the hash (defeats precompute)",
        core.lockRecord("saltA", "pw", fakeHash).hash ~= core.lockRecord("saltB", "pw", fakeHash).hash)
  eq("lock: saltedInput format", core.lockSaltedInput("s", "p"), "s:p")
end

-- ---- DR3: checkpoint / rewind timeline ------------------------------------
do
  local function snap(mid, isUpd, ts, files)
    return core.json.encode({ type = "file-history-snapshot", messageId = mid, isSnapshotUpdate = isUpd,
      snapshot = { messageId = mid, timestamp = ts, trackedFileBackups = files or {} } })
  end
  -- u1: 0 files at start, a.txt@v1 created during the turn (update line);
  -- u2: baseline a.txt@v1, then a.txt bumped to v2 + b.md@v1 created;
  -- u3: baseline a.txt@v2 + b.md@v1 (committed end of u2), no further edits.
  local T1, T2, T3 = "2026-06-18T14:00:00Z", "2026-06-18T14:05:00Z", "2026-06-18T14:09:00Z"
  local av1 = { ["/p/a.txt"] = { version = 1, backupTime = "b1" } }
  local av2b = { ["/p/a.txt"] = { version = 2, backupTime = "b2" }, ["/p/sub/b.md"] = { version = 1, backupTime = "b3" } }
  local text = table.concat({
    snap("u1", false, T1, {}),
    snap("u1", true,  T1, av1),
    snap("u2", false, T2, av1),
    snap("u2", true,  T2, av2b),
    snap("u3", false, T3, av2b),
  }, "\n")
  local pts = core.checkpointTimeline(text, {})
  eq("checkpoint: 3 restore points", #pts, 3)
  eq("checkpoint: newest-first (u3 head)", pts[1].messageId, "u3")
  eq("checkpoint: oldest last (u1 tail)", pts[3].messageId, "u1")
  check("checkpoint: ts parsed to epoch", type(pts[1].ts) == "number")
  -- u1 turn created a.txt (diff establishing-u1 {} vs establishing-u2 {a.txt})
  eq("checkpoint: u1 changed 1 file", pts[3].filesChanged, 1)
  eq("checkpoint: u1 changed = a.txt", pts[3].changed[1].name, "a.txt")
  -- u2 turn bumped a.txt v1->v2 and created b.md (diff vs establishing-u3)
  eq("checkpoint: u2 changed 2 files", pts[2].filesChanged, 2)
  eq("checkpoint: changed sorted by path (a.txt first)", pts[2].changed[1].name, "a.txt")
  eq("checkpoint: changed includes basename of nested", pts[2].changed[2].name, "b.md")
  eq("checkpoint: changed carries new version", pts[2].changed[1].version, 2)
  -- u3 is the latest turn: no committed next snapshot, no own updates -> 0 changed
  eq("checkpoint: latest turn 0 changed (uncommitted)", pts[1].filesChanged, 0)
  -- limit keeps the most-recent N
  local two = core.checkpointTimeline(text, { limit = 2 })
  eq("checkpoint: limit caps to N", #two, 2)
  eq("checkpoint: limit keeps newest", two[1].messageId, "u3")
  -- robustness
  eq("checkpoint: empty -> {}", #core.checkpointTimeline("", {}), 0)
  eq("checkpoint: garbage skipped", #core.checkpointTimeline("not json\n{bad", {}), 0)
  eq("checkpoint: nil -> {}", #core.checkpointTimeline(nil, {}), 0)

  -- userPromptSnippet (the caller's label source, decoded per matching user line)
  local strLine = core.json.encode({ type = "user", uuid = "u1", message = { content = "please review this prompt\nmore detail" } })
  eq("promptSnippet: string content, first line", core.userPromptSnippet(strLine, 140), "please review this prompt")
  local arrLine = core.json.encode({ type = "user", message = { content = { { type = "text", text = "build the thing" } } } })
  eq("promptSnippet: array text block", core.userPromptSnippet(arrLine, 140), "build the thing")
  local toolLine = core.json.encode({ type = "user", message = { content = { { type = "tool_result", content = "x" } } } })
  eq("promptSnippet: tool_result-only -> empty", core.userPromptSnippet(toolLine, 140), "")
  eq("promptSnippet: non-user -> empty", core.userPromptSnippet(strLine:gsub('"user"', '"assistant"'), 140), "")
  eq("promptSnippet: non-json -> empty", core.userPromptSnippet("garbage", 140), "")
  local longLine = core.json.encode({ type = "user", message = { content = string.rep("x", 300) } })
  check("promptSnippet: truncates to maxLen", #core.userPromptSnippet(longLine, 40) <= 40)
end

-- ---- DR7: A/B fork-to-compare (plan / worktree cmds / compare / judge) -----
do
  eq("abSlug: sanitizes + caps", core.abSlug("My Cohort #1!!"), "my-cohort-1")
  eq("abSlug: trims dashes", core.abSlug("--a/b--"), "a-b")
  eq("abBranchName", core.abBranchName("Run 1", "Opus"), "ab/run-1/opus")
  eq("abWorktreePath: sibling .cc-ab dir",
     core.abWorktreePath("/Users/x/Programming/repo", "c1", "a"), "/Users/x/Programming/.cc-ab/repo-c1-a")

  local plan = core.abCohortPlan({
    cohort = "c1", repoRoot = "/p/repo", task = "build the feature",
    variants = { { label = "Sonnet", model = "sonnet" }, { label = "Opus", model = "opus", prompt = "build it carefully" } },
  })
  check("abCohortPlan: ok", plan.ok == true)
  eq("abCohortPlan: 2 variants", #plan.variants, 2)
  eq("abCohortPlan: branch", plan.variants[1].branch, "ab/c1/sonnet")
  eq("abCohortPlan: worktree", plan.variants[2].worktreePath, "/p/.cc-ab/repo-c1-opus")
  eq("abCohortPlan: base task inherited", plan.variants[1].task, "build the feature")
  eq("abCohortPlan: per-variant prompt overrides task", plan.variants[2].task, "build it carefully")
  eq("abCohortPlan: model carried", plan.variants[2].model, "opus")
  eq("abCohortPlan: base defaults to HEAD", plan.base, "HEAD")
  check("abCohortPlan: rejects <2 variants",
        core.abCohortPlan({ cohort = "c", repoRoot = "/p", task = "t", variants = { { label = "a" } } }).ok == false)
  check("abCohortPlan: rejects no repo",
        core.abCohortPlan({ cohort = "c", task = "t", variants = { { label = "a" }, { label = "b" } } }).ok == false)
  check("abCohortPlan: rejects dup labels",
        core.abCohortPlan({ cohort = "c", repoRoot = "/p", task = "t", variants = { { label = "A" }, { label = "a" } } }).ok == false)
  check("abCohortPlan: rejects a variant with no task at all",
        core.abCohortPlan({ cohort = "c", repoRoot = "/p", variants = { { label = "a" }, { label = "b" } } }).ok == false)

  -- git command builders (quoted; run via /bin/sh by the dashboard)
  check("gitWorktreeAddCmd: shape",
        core.gitWorktreeAddCmd("/p/repo", "/p/.cc-ab/repo-c1-a", "ab/c1/a", "HEAD")
        == "git -C /p/repo worktree add -b ab/c1/a /p/.cc-ab/repo-c1-a HEAD")
  check("gitWorktreeRemoveCmd: shape",
        core.gitWorktreeRemoveCmd("/p/repo", "/p/.cc-ab/repo-c1-a")
        == "git -C /p/repo worktree remove --force /p/.cc-ab/repo-c1-a")
  check("gitBranchDeleteCmd: shape",
        core.gitBranchDeleteCmd("/p/repo", "ab/c1/a") == "git -C /p/repo branch -D ab/c1/a")
  check("gitWorktreeAddCmd: quotes a spacey path",
        core.gitWorktreeAddCmd("/p/my repo", "/p/wt a", "ab/c/a", "HEAD"):find("'/p/my repo'", 1, true) ~= nil)

  -- compare: rank by score (scored first, highest wins, stable ties)
  local cmp = core.abCompare(plan.variants, { Sonnet = { score = 70, hadData = true }, Opus = { score = 92, hadData = true } })
  eq("abCompare: winner is highest score", cmp.winner, "Opus")
  eq("abCompare: rank 1 = winner", cmp.rows[1].label, "Opus")
  eq("abCompare: rank 2", cmp.rows[2].label, "Sonnet")
  local cmp2 = core.abCompare(plan.variants, { Sonnet = { score = 80, hadData = true } })  -- Opus unscored
  eq("abCompare: scored before unscored", cmp2.rows[1].label, "Sonnet")
  check("abCompare: winner is the scored one", cmp2.winner == "Sonnet")
  local cmp3 = core.abCompare(plan.variants, {})   -- none scored
  check("abCompare: no scores -> no winner", cmp3.winner == nil)
  check("abCompare: stable order when no data", cmp3.rows[1].label == "Sonnet" and cmp3.rows[2].label == "Opus")

  -- A/B model variant on a fresh worktree: env forces the terminal flavor, which must
  -- ALSO carry coldStart so vscodeOpenArgs adds --disable-workspace-trust (else the trust
  -- modal blocks the integrated-terminal launch line).
  local abSpec = core.spawnSpec("vscode", "/p/.cc-ab/repo-c1-a", "build it",
    { isNew = true, env = { { name = "ANTHROPIC_MODEL", value = "opus", secret = false } } })
  eq("ab spawn: env -> terminal flavor", abSpec.flavor, "terminal")
  check("ab spawn: terminal flavor carries coldStart when isNew", abSpec.coldStart == true)
  local function hasArg2(args, v) for _, a in ipairs(args) do if a == v then return true end end return false end
  check("ab spawn: cold terminal flavor gets --disable-workspace-trust",
        hasArg2(core.vscodeOpenArgs(abSpec), "--disable-workspace-trust"))
  check("ab spawn: ANTHROPIC_MODEL rides the typed line", (abSpec.postType or ""):find("ANTHROPIC_MODEL", 1, true) ~= nil)

  -- judge prompt
  local jp = core.abJudgePrompt("do X", { { label = "A", model = "opus", output = "did X via foo" }, { label = "B", output = "did X via bar" } })
  check("abJudgePrompt: includes task", jp:find("do X", 1, true) ~= nil)
  check("abJudgePrompt: includes both variants + a winner ask",
        jp:find("Variant A", 1, true) ~= nil and jp:find("Variant B", 1, true) ~= nil and jp:find("WINNING variant", 1, true) ~= nil)
end

-- ---- Appearance: token themes + overrides + CSS render ---------------------
do
  -- defaults / empty -> Refined Midnight
  local d = core.resolveAppearance({})
  eq("appearance: empty -> midnight theme", d.theme, "midnight")
  eq("appearance: midnight bg default", d.tokens.bg, "#15161b")
  eq("appearance: midnight scheme dark", d.scheme, "dark")
  eq("appearance: midnight look card", d.look, "card")
  eq("appearance: default scale 1.0", d.scale, 1.0)
  eq("appearance: default tileMin 170", d.tileMin, 170)
  eq("appearance: default density comfortable", d.density, "comfortable")
  eq("appearance: nil arg safe", core.resolveAppearance(nil).theme, "midnight")

  -- unknown theme falls back; known theme applies its palette + scheme + look
  eq("appearance: unknown theme -> midnight", core.resolveAppearance({ theme = "bogus" }).theme, "midnight")
  local lt = core.resolveAppearance({ theme = "light" })
  eq("appearance: light scheme", lt.scheme, "light")
  eq("appearance: light bg", lt.tokens.bg, "#f4f6f9")
  eq("appearance: slate look", core.resolveAppearance({ theme = "slate" }).look, "slate")
  eq("appearance: flat look", core.resolveAppearance({ theme = "flat" }).look, "flat")

  -- palette override: valid hex wins, unknown key + bad hex ignored
  local ov = core.resolveAppearance({ theme = "midnight", colors = { bg = "#222222", nope = "#fff", surface = "zzz" } })
  eq("appearance: valid color override applied", ov.tokens.bg, "#222222")
  eq("appearance: bad-hex override ignored (keeps theme value)", ov.tokens.surface, "#21232c")
  check("appearance: unknown override key dropped", ov.tokens.nope == nil)

  -- accent shortcut + status overrides
  eq("appearance: accent shortcut", core.resolveAppearance({ accent = "#abc" }).tokens.accent, "#abc")
  local st = core.resolveAppearance({ status = { working = "#101010", bogus = "#fff" } })
  eq("appearance: status.working override", st.tokens.stWorking, "#101010")
  eq("appearance: untouched status keeps default", st.tokens.stDone, "#22c55e")

  -- sizing clamps
  eq("appearance: scale clamp high", core.resolveAppearance({ scale = 5 }).scale, 1.4)
  eq("appearance: scale clamp low", core.resolveAppearance({ scale = 0.1 }).scale, 0.8)
  eq("appearance: scale numeric string", core.resolveAppearance({ scale = "1.2" }).scale, 1.2)
  -- R1-30: a numeric-prefix-plus-garbage string must fall back to default (tonumber
  -- rejects it); the JS apClamp twin is tightened to match so SSR CSS == live preview.
  eq("appearance: garbage-suffix scale -> default", core.resolveAppearance({ scale = "1.2x" }).scale, 1.0)
  eq("appearance: garbage-suffix tileMin -> default", core.resolveAppearance({ tileMin = "200px" }).tileMin, 170)
  -- R2-26: a HEX string literal must fall back to default so the Lua side matches the
  -- JS apClamp twin (which rejects hex). tonumber("0x96")==150 would otherwise make SSR
  -- CSS disagree with the live preview.
  eq("appearance: hex tileMin string -> default", core.resolveAppearance({ tileMin = "0x96" }).tileMin, 170)
  eq("appearance: hex scale string -> default", core.resolveAppearance({ scale = "0x1.2" }).scale, 1.0)
  -- R3-13: an EXPONENTIAL string literal must fall back to default on BOTH sides (the Lua
  -- regex has no [eE] alternative; apClamp is tightened to drop its [eE] group to match).
  eq("appearance: exponential scale string -> default", core.resolveAppearance({ scale = "1.3e0" }).scale, 1.0)
  eq("appearance: exponential tileMin string -> default", core.resolveAppearance({ tileMin = "3e2" }).tileMin, 170)
  eq("appearance: tileMin clamp high", core.resolveAppearance({ tileMin = 9999 }).tileMin, 320)
  eq("appearance: tileMin clamp low", core.resolveAppearance({ tileMin = 10 }).tileMin, 120)
  eq("appearance: density dense passes", core.resolveAppearance({ density = "dense" }).density, "dense")
  eq("appearance: density junk -> comfortable", core.resolveAppearance({ density = "huge" }).density, "comfortable")

  -- isHex guard
  check("appearance: isHex #rgb", core.appearanceIsHex("#abc"))
  check("appearance: isHex #rrggbb", core.appearanceIsHex("#a1b2c3"))
  check("appearance: isHex rejects no-#", not core.appearanceIsHex("abc123"))
  check("appearance: isHex rejects len", not core.appearanceIsHex("#abcd"))

  -- appearanceCss: :root block, color-scheme, a couple tokens, sizing vars
  local css = core.appearanceCss(core.resolveAppearance({}))
  check("appearanceCss: opens :root", css:sub(1, 6) == ":root{")
  check("appearanceCss: color-scheme dark", css:find("color-scheme:dark", 1, true) ~= nil)
  check("appearanceCss: emits --st-working", css:find("--st-working:#f5b50a", 1, true) ~= nil)
  check("appearanceCss: emits --bg", css:find("--bg:#15161b", 1, true) ~= nil)
  check("appearanceCss: emits --ui-scale", css:find("--ui-scale:", 1, true) ~= nil)
  check("appearanceCss: emits --tile-min px", css:find("--tile-min:170px", 1, true) ~= nil)
  local lcss = core.appearanceCss(core.resolveAppearance({ theme = "light" }))
  check("appearanceCss: light -> color-scheme light", lcss:find("color-scheme:light", 1, true) ~= nil)
  check("appearanceCss: light -> light bg token", lcss:find("--bg:#f4f6f9", 1, true) ~= nil)
end

-- ---- Appearance batch 2: more themes + font + reduce-motion -----------------
do
  -- new themes resolve with their palettes + correct scheme
  eq("appearance: dracula accent", core.resolveAppearance({ theme = "dracula" }).tokens.accent, "#bd93f9")
  eq("appearance: tokyonight done", core.resolveAppearance({ theme = "tokyonight" }).tokens.stDone, "#9ece6a")
  eq("appearance: gruvbox bg", core.resolveAppearance({ theme = "gruvbox" }).tokens.bg, "#282828")
  eq("appearance: solarized dark scheme", core.resolveAppearance({ theme = "solarized" }).scheme, "dark")
  eq("appearance: solarizedlight scheme light", core.resolveAppearance({ theme = "solarizedlight" }).scheme, "light")
  eq("appearance: rosepine accent", core.resolveAppearance({ theme = "rosepine" }).tokens.accent, "#c4a7e7")
  eq("appearance: catppuccin bg", core.resolveAppearance({ theme = "catppuccin" }).tokens.bg, "#1e1e2e")
  eq("appearance: gruvboxlight scheme light", core.resolveAppearance({ theme = "gruvboxlight" }).scheme, "light")
  eq("appearance: monokai accent", core.resolveAppearance({ theme = "monokai" }).tokens.accent, "#66d9ef")
  eq("appearance: oled true-black bg", core.resolveAppearance({ theme = "oled" }).tokens.bg, "#000000")
  -- new palettes (2 dark-red, 2 dark-green, 2 bright)
  eq("appearance: ember accent", core.resolveAppearance({ theme = "ember" }).tokens.accent, "#ff5a3c")
  eq("appearance: bloodmoon accent", core.resolveAppearance({ theme = "bloodmoon" }).tokens.accent, "#e11d48")
  eq("appearance: matrix true-black bg", core.resolveAppearance({ theme = "matrix" }).tokens.bg, "#000000")
  eq("appearance: emerald accent", core.resolveAppearance({ theme = "emerald" }).tokens.accent, "#2dd4bf")
  eq("appearance: synthwave accent", core.resolveAppearance({ theme = "synthwave" }).tokens.accent, "#ff2e97")
  eq("appearance: cyberpunk accent", core.resolveAppearance({ theme = "cyberpunk" }).tokens.accent, "#fcee0a")
  -- neon family (Cyberpunk DNA): 3 reds, 3 greens, 4 more bright neons
  eq("appearance: redline accent", core.resolveAppearance({ theme = "redline" }).tokens.accent, "#ff0040")
  eq("appearance: magma accent", core.resolveAppearance({ theme = "magma" }).tokens.accent, "#ff3d00")
  eq("appearance: plasma accent", core.resolveAppearance({ theme = "plasma" }).tokens.accent, "#ff0059")
  eq("appearance: acid accent", core.resolveAppearance({ theme = "acid" }).tokens.accent, "#39ff14")
  eq("appearance: toxic accent", core.resolveAppearance({ theme = "toxic" }).tokens.accent, "#ccff00")
  eq("appearance: spearmint accent", core.resolveAppearance({ theme = "spearmint" }).tokens.accent, "#00ffa3")
  eq("appearance: tron accent", core.resolveAppearance({ theme = "tron" }).tokens.accent, "#00fff5")
  eq("appearance: hotline accent", core.resolveAppearance({ theme = "hotline" }).tokens.accent, "#ff2bd6")
  eq("appearance: voltage accent", core.resolveAppearance({ theme = "voltage" }).tokens.accent, "#b026ff")
  eq("appearance: laser accent", core.resolveAppearance({ theme = "laser" }).tokens.accent, "#00b3ff")
  -- video-game franchises (18): each theme's signature accent resolves
  eq("appearance: mario accent", core.resolveAppearance({ theme = "mario" }).tokens.accent, "#e52521")
  eq("appearance: zelda accent", core.resolveAppearance({ theme = "zelda" }).tokens.accent, "#f5d020")
  eq("appearance: sonic accent", core.resolveAppearance({ theme = "sonic" }).tokens.accent, "#1b78e6")
  eq("appearance: pokemon accent", core.resolveAppearance({ theme = "pokemon" }).tokens.accent, "#ee1515")
  eq("appearance: minecraft accent", core.resolveAppearance({ theme = "minecraft" }).tokens.accent, "#5ea833")
  eq("appearance: splatoon accent", core.resolveAppearance({ theme = "splatoon" }).tokens.accent, "#ff2d95")
  eq("appearance: stardew accent", core.resolveAppearance({ theme = "stardew" }).tokens.accent, "#7dbe4e")
  eq("appearance: halo accent", core.resolveAppearance({ theme = "halo" }).tokens.accent, "#4ec3f7")
  eq("appearance: portal accent", core.resolveAppearance({ theme = "portal" }).tokens.accent, "#00a2ff")
  eq("appearance: doom accent", core.resolveAppearance({ theme = "doom" }).tokens.accent, "#e53935")
  eq("appearance: fallout accent", core.resolveAppearance({ theme = "fallout" }).tokens.accent, "#3fff3f")
  eq("appearance: masseffect accent", core.resolveAppearance({ theme = "masseffect" }).tokens.accent, "#e63946")
  eq("appearance: bioshock accent", core.resolveAppearance({ theme = "bioshock" }).tokens.accent, "#2ec4b6")
  eq("appearance: persona accent", core.resolveAppearance({ theme = "persona" }).tokens.accent, "#e60012")
  eq("appearance: hollowknight accent", core.resolveAppearance({ theme = "hollowknight" }).tokens.accent, "#bcd3e6")
  eq("appearance: celeste accent", core.resolveAppearance({ theme = "celeste" }).tokens.accent, "#ff4d9d")
  eq("appearance: eldenring accent", core.resolveAppearance({ theme = "eldenring" }).tokens.accent, "#e6b422")
  eq("appearance: godofwar accent", core.resolveAppearance({ theme = "godofwar" }).tokens.accent, "#ff5722")
  do local n = 0; for _ in pairs(core.APPEARANCE_THEMES) do n = n + 1 end
     check("appearance: 50 built-in themes", n == 50) end
  -- structural validity of EVERY theme: required fields + all token values are #rrggbb
  do
    local bad = {}
    for key, t in pairs(core.APPEARANCE_THEMES) do
      if type(t.label) ~= "string" or t.label == "" then bad[#bad + 1] = key .. ".label" end
      if t.scheme ~= "dark" and t.scheme ~= "light" then bad[#bad + 1] = key .. ".scheme" end
      if t.look ~= "card" and t.look ~= "slate" and t.look ~= "flat" then bad[#bad + 1] = key .. ".look" end
      if type(t.tokens) ~= "table" then bad[#bad + 1] = key .. ".tokens"
      else for tk, tv in pairs(t.tokens) do
        if type(tv) ~= "string" or not tv:match("^#%x%x%x%x%x%x$") then bad[#bad + 1] = key .. "." .. tk end
      end end
    end
    check("appearance: every theme is structurally valid (#rrggbb tokens)  [" .. table.concat(bad, ",") .. "]", #bad == 0)
  end

  -- Theme grouping: the picker's chip ORDER + section HEADERS come only from
  -- APPEARANCE_THEME_GROUPS (a hash-ordered theme table would render arbitrarily). Pin the
  -- invariant BOTH ways -- every grouped key names a real theme, and every theme sits in
  -- exactly one group -- so a newly-added theme can't silently fall out of the picker.
  do
    local groups = core.APPEARANCE_THEME_GROUPS
    check("appearance: theme groups is a non-empty ordered array", type(groups) == "table" and #groups > 0)
    local count, dup, missing, badmeta = {}, {}, {}, {}
    for _, g in ipairs(groups or {}) do
      if type(g.id) ~= "string" or g.id == "" or type(g.label) ~= "string" or g.label == "" or type(g.themes) ~= "table" then
        badmeta[#badmeta + 1] = tostring(g and g.id)
      end
      for _, key in ipairs(g.themes or {}) do
        if not core.APPEARANCE_THEMES[key] then missing[#missing + 1] = key end
        if count[key] then dup[#dup + 1] = key end
        count[key] = (count[key] or 0) + 1
      end
    end
    local orphan = {}
    for key in pairs(core.APPEARANCE_THEMES) do if not count[key] then orphan[#orphan + 1] = key end end
    check("appearance: every group has id+label+themes  [" .. table.concat(badmeta, ",") .. "]", #badmeta == 0)
    check("appearance: every grouped key names a real theme  [" .. table.concat(missing, ",") .. "]", #missing == 0)
    check("appearance: no theme is listed in two groups  [" .. table.concat(dup, ",") .. "]", #dup == 0)
    check("appearance: every theme belongs to exactly one group (no orphan)  [" .. table.concat(orphan, ",") .. "]", #orphan == 0)
  end

  -- font: default system, valid passes, junk -> system; appearanceCss emits --font stack
  eq("appearance: default font system", core.resolveAppearance({}).font, "system")
  eq("appearance: valid font passes", core.resolveAppearance({ font = "mono" }).font, "mono")
  eq("appearance: junk font -> system", core.resolveAppearance({ font = "comic" }).font, "system")
  check("appearanceCss: emits a --font stack", core.appearanceCss(core.resolveAppearance({ font = "mono" })):find("--font:ui%-monospace") ~= nil)
  check("appearanceCss: default --font is the system stack", core.appearanceCss(core.resolveAppearance({})):find("--font:-apple-system", 1, true) ~= nil)

  -- reduce motion: bool passthrough, default false
  check("appearance: reduceMotion default false", core.resolveAppearance({}).reduceMotion == false)
  check("appearance: reduceMotion true", core.resolveAppearance({ reduceMotion = true }).reduceMotion == true)
end

-- ---- Review-fix: cold-start poll bound + appearanceCss completeness + junk coercion ----
do
  -- coldStartStep: the bounded open/wait/giveup decision (pure; the ladder executes it)
  eq("coldStartStep: window seen -> open", core.coldStartStep(true, 0, 25), "open")
  eq("coldStartStep: seen overrides elapsed", core.coldStartStep(true, 999, 25), "open")
  eq("coldStartStep: not seen, under cap -> wait", core.coldStartStep(false, 5, 25), "wait")
  eq("coldStartStep: not seen, at cap -> giveup (no infinite poll)", core.coldStartStep(false, 25, 25), "giveup")
  eq("coldStartStep: not seen, over cap -> giveup", core.coldStartStep(false, 99, 25), "giveup")
  eq("coldStartStep: nil elapsed safe -> wait", core.coldStartStep(false, nil, 25), "wait")
  eq("coldStartStep: nil waitMax -> default-25 cap", core.coldStartStep(false, 25, nil), "giveup")

  -- R1-09: spawnLadderKey gives each concurrent spawn its OWN window key so an A/B
  -- cohort's ladders don't cancel each other; a repeat same-project spawn shares a key.
  eq("spawnLadderKey: project path is the key", core.spawnLadderKey({ project = "/w/a" }), "/w/a")
  eq("spawnLadderKey: distinct variants -> distinct keys",
     core.spawnLadderKey({ project = "/w/v1" }) == core.spawnLadderKey({ project = "/w/v2" }), false)
  eq("spawnLadderKey: same project -> same key (self-supersede)",
     core.spawnLadderKey({ project = "/w/a" }), core.spawnLadderKey({ project = "/w/a" }))
  eq("spawnLadderKey: falls back to name when no project", core.spawnLadderKey({ name = "proj" }), "proj")
  eq("spawnLadderKey: empty spec -> default sentinel", core.spawnLadderKey({}), "__default__")

  -- R3-07: spawnLadderWorst reserves the spawn ladder's worst-case wall-clock on the
  -- shared injection tail so a concurrent dispatched paste can't cross-clobber it.
  eq("spawnLadderWorst: warm extension ladder = 6.3s",
     core.spawnLadderWorst({ flavor = "extension" }), 6.3)
  eq("spawnLadderWorst: warm terminal ladder = 7.1s",
     core.spawnLadderWorst({ flavor = "terminal" }), 7.1)
  eq("spawnLadderWorst: cold-start sums head start + wait + activate + drive",
     core.spawnLadderWorst({ flavor = "extension", coldStart = true, coldWindowWait = 25, coldActivate = 6 }),
     2.0 + 25 + 6 + 7.1)
  eq("spawnLadderWorst: cold-start defaults waitMax/activate when absent",
     core.spawnLadderWorst({ coldStart = true }), 2.0 + 25 + 6 + 7.1)
  eq("spawnLadderWorst: a positive reservation for any spec (no zero-slot)",
     core.spawnLadderWorst({}) > 0, true)

  -- appearanceCss COMPLETENESS: every APPEARANCE_VARS token is emitted (catches a token
  -- added to the list but missed in the render loop). The SSR side single-sources the JS
  -- twin's setProperty loop (both iterate APPEARANCE_VARS), so this guards both.
  local css0 = core.appearanceCss(core.resolveAppearance({}))
  local missingVar = nil
  for _, pair in ipairs(core.APPEARANCE_VARS) do
    if not css0:find(pair[2] .. ":", 1, true) then missingVar = pair[2]; break end
  end
  check("appearanceCss: emits EVERY APPEARANCE_VARS token (" .. #core.APPEARANCE_VARS .. " of them)", missingVar == nil)

  -- junk coercion: a hand-edited cc-config.json non-numeric scale/tileMin must fall back,
  -- never crash the appearance render (appearanceClamp = tonumber-or-default before compare).
  eq("appearance: junk scale string -> 1.0", core.resolveAppearance({ scale = "abc" }).scale, 1.0)
  eq("appearance: table scale -> 1.0", core.resolveAppearance({ scale = {} }).scale, 1.0)
  eq("appearance: boolean scale -> 1.0", core.resolveAppearance({ scale = true }).scale, 1.0)
  eq("appearance: junk tileMin string -> 170", core.resolveAppearance({ tileMin = "big" }).tileMin, 170)
end

-- F7: cost summary + daily series from cumulative usage_snapshot events
do
  local DAY = 86400
  local evs = {
    { type="usage_snapshot", session_id="A", ts=0*DAY+100, real=100, estCostUsd=1.0, name="alpha", model="opus" },
    { type="usage_snapshot", session_id="A", ts=1*DAY+100, real=300, estCostUsd=3.0, name="alpha", model="opus" },
    { type="usage_snapshot", session_id="B", ts=1*DAY+200, real=50,  estCostUsd=0.5, name="beta",  model="sonnet" },
    { type="decision",       session_id="A", ts=1*DAY+300, outcome="allow" },  -- ignored
  }
  local sum = core.costSummary(evs)
  eq("costSummary: 2 sessions", sum.sessions, 2)
  eq("costSummary: latest-cumulative real (300+50)", sum.real, 350)
  check("costSummary: usd sums latest (3.0+0.5)", math.abs(sum.usd - 3.5) < 1e-9)
  eq("costSummary: perSession sorted by $ (alpha first)", sum.perSession[1].name, "alpha")
  eq("costSummary: empty -> 0 sessions", core.costSummary({}).sessions, 0)

  local series = core.costSeries(evs, { days = 2, tzOffset = 0, now = 1*DAY + 500 })
  eq("costSeries: 2 day buckets", #series, 2)
  eq("costSeries: day0 real delta (A from 0)", series[1].real, 100)
  eq("costSeries: day1 real delta (A +200, B +50)", series[2].real, 250)
  check("costSeries: day1 usd delta (~2.5)", math.abs(series[2].usd - 2.5) < 1e-9)

  local reset = {
    { type="usage_snapshot", session_id="C", ts=0*DAY+50, real=500, estCostUsd=5.0 },
    { type="usage_snapshot", session_id="C", ts=1*DAY+50, real=20,  estCostUsd=0.2 },  -- transcript reset
  }
  local rs = core.costSeries(reset, { days = 2, tzOffset = 0, now = 1*DAY + 100 })
  check("costSeries: reset day clamps to >= 0 (no negative)", rs[2].real >= 0)
  eq("costSeries: empty -> N day rows", #core.costSeries({}, { days = 3, now = 5*DAY }), 3)

  -- carry-in: a session that existed BEFORE the window must diff its first in-window day
  -- against its pre-window cumulative, NOT from 0 (else pre-window spend is over-attributed
  -- to the first bucket). The Cost overlay passes the FULL ledger (not a windowed slice), so
  -- cumAt() finds the pre-window baseline. This pins that behavior.
  local carryin = {
    { type="usage_snapshot", session_id="D", ts=-1*DAY+50, real=1000, estCostUsd=10.0 },  -- before window
    { type="usage_snapshot", session_id="D", ts=0*DAY+50, real=1050, estCostUsd=10.5 },    -- first in-window day
  }
  local ci = core.costSeries(carryin, { days = 2, tzOffset = 0, now = 1*DAY + 100 })
  eq("costSeries: pre-window session diffs against carry-in (50, not 1050)", ci[1].real, 50)
  check("costSeries: pre-window usd carry-in (~0.5)", math.abs(ci[1].usd - 0.5) < 1e-9)
end

-- F6: doctor health classifier
do
  local function findRow(rows, statusWanted, labelSub)
    for _, r in ipairs(rows) do
      if (not statusWanted or r.status == statusWanted)
         and (not labelSub or r.label:find(labelSub, 1, true)) then return r end
    end
    return nil
  end
  local function anyStatus(rows, s) for _, r in ipairs(rows) do if r.status == s then return true end end return false end

  local healthy = core.doctorChecks({ jq=true, hooksWired=3, hooksTotal=3, scriptsInstalled=true,
    heartbeatAgeSec=2, gateArmed=true, ledgerEnabled=true, ledgerBytes=1024, sessions=2 })
  check("doctorChecks: healthy env -> no crit/warn", not anyStatus(healthy, "crit") and not anyStatus(healthy, "warn"))
  check("doctorChecks: jq present -> ok", findRow(healthy, "ok", "jq") ~= nil)

  local sick = core.doctorChecks({ jq=false, hooksWired=0, hooksTotal=3, scriptsInstalled=false,
    heartbeatAgeSec=nil, gateArmed=false, ledgerEnabled=false, sessions=0 })
  check("doctorChecks: jq missing -> crit + brew fix",
        (function() local r=findRow(sick,"crit","jq"); return r and r.fix and r.fix:find("brew") ~= nil end)())
  check("doctorChecks: no hooks -> crit", findRow(sick, "crit", "Hooks not installed") ~= nil)
  check("doctorChecks: missing heartbeat -> warn", findRow(sick, "warn", "heartbeat") ~= nil)
  check("doctorChecks: gate off -> info (not an alarm)", findRow(sick, "info", "Gate disarmed") ~= nil)

  local partial = core.doctorChecks({ jq=true, hooksWired=1, hooksTotal=3, scriptsInstalled=true,
    heartbeatAgeSec=120, ledgerEnabled=true, ledgerBytes=60*1024*1024, sessions=1 })
  check("doctorChecks: partial hooks -> warn", findRow(partial, "warn", "Some hooks") ~= nil)
  check("doctorChecks: stale heartbeat -> warn", findRow(partial, "warn", "stale") ~= nil)
  check("doctorChecks: big ledger -> warn", findRow(partial, "warn", "large") ~= nil)
  check("doctorChecks: 1 session -> singular label", findRow(partial, "info", "1 live session") ~= nil)
  check("doctorChecks: non-table facts safe", #core.doctorChecks(nil) > 0)
end

-- F9: features list shape (comprehensive, categorized)
do
  check("FEATURES: comprehensive list", type(core.FEATURES) == "table" and #core.FEATURES >= 25)
  local cats = {}; for _, c in ipairs(core.FEATURE_CATEGORIES) do cats[c] = true end
  local shapeOk, catOk = true, true
  for _, f in ipairs(core.FEATURES) do
    if type(f.title) ~= "string" or type(f.what) ~= "string" or type(f.why) ~= "string" then shapeOk = false end
    if not (f.cat and cats[f.cat]) then catOk = false end
  end
  check("FEATURES: every entry has title/what/why", shapeOk)
  check("FEATURES: every entry has a known category", catOk)
  -- categories must be contiguous so the overlay renders each header exactly once
  local seen, contiguous, last = {}, true, nil
  for _, f in ipairs(core.FEATURES) do
    if f.cat ~= last then
      if seen[f.cat] then contiguous = false end
      seen[f.cat] = true; last = f.cat
    end
  end
  check("FEATURES: categories are contiguous (one header each)", contiguous)
  -- The overlay (ccFeatures) emits headers in FIRST-SEEN order, not from
  -- FEATURE_CATEGORIES -- so the two are independent sources of truth that could
  -- silently drift. Pin the pairing: first-seen category sequence must equal
  -- FEATURE_CATEGORIES exactly (length too -- catches a declared category with no
  -- entries, or entries whose category isn't declared).
  local order, ordSeen = {}, {}
  for _, f in ipairs(core.FEATURES) do
    if f.cat and not ordSeen[f.cat] then ordSeen[f.cat] = true; order[#order + 1] = f.cat end
  end
  local orderOk = #order == #core.FEATURE_CATEGORIES
  for i = 1, #core.FEATURE_CATEGORIES do if order[i] ~= core.FEATURE_CATEGORIES[i] then orderOk = false end end
  check("FEATURES: first-seen category order matches FEATURE_CATEGORIES (render contract)", orderOk)
  local keys = {}; for _, f in ipairs(core.FEATURES) do keys[f.key] = true end
  check("FEATURES: covers the new features (theme/transcript/doctor/cost/render)",
        keys.theme and keys.transcript and keys.doctor and keys.cost and keys.render)
  check("FEATURES: covers major existing flows too",
        keys.search and keys.policies and keys.automodel and keys.bridge and keys.agents and keys.ab and keys.usage and keys.rewind)
  check("FEATURES: lists the user-stories tab", keys.stories == true)
  local newCount = 0; for _, f in ipairs(core.FEATURES) do if f.new then newCount = newCount + 1 end end
  eq("FEATURES: the 6 new features are flagged", newCount, 6)
end

-- F4: transcript peek (user + assistant rows, chronological, noise filtered)
do
  local function L(t) return core.json.encode(t) end
  local lines = {
    L({ type="user", timestamp="2026-06-23T00:00:00Z", message={ role="user", content="first prompt" } }),
    L({ type="assistant", message={ role="assistant", content={ { type="text", text="hi there" } } } }),
    L({ type="user", isMeta=true, message={ role="user", content="ide file open" } }),                 -- meta -> skip
    L({ type="user", message={ role="user", content={ { type="tool_result", content="x" } } } }),      -- tool-result -> skip
    L({ type="assistant", message={ role="assistant", content={ { type="tool_use", name="Bash" } } } }), -- no text -> skip
    L({ type="assistant", message={ role="assistant", content={ { type="text", text="done now" } } } }),
  }
  local text = table.concat(lines, "\n")
  local rows = core.transcriptPeek(text, { n = 40 })
  eq("transcriptPeek: keeps real turns only (3)", #rows, 3)
  eq("transcriptPeek: chronological (first = user prompt)", rows[1].role, "user")
  eq("transcriptPeek: user text", rows[1].text, "first prompt")
  eq("transcriptPeek: assistant text", rows[2].text, "hi there")
  eq("transcriptPeek: last row = final assistant turn", rows[3].text, "done now")
  eq("transcriptPeek: carries the source timestamp onto the row", rows[1].ts, "2026-06-23T00:00:00Z")
  check("transcriptPeek: a line without a timestamp -> ts nil (no error)", rows[2].ts == nil)

  local capped = core.transcriptPeek(text, { n = 1 })
  eq("transcriptPeek: n caps to newest", #capped, 1)
  eq("transcriptPeek: newest kept on cap", capped[1].text, "done now")

  local long = core.json.encode({ type="assistant", message={ role="assistant", content={ { type="text", text=string.rep("x", 50) } } } })
  local tr = core.transcriptPeek(long, { maxLen = 10 })
  check("transcriptPeek: truncates long text (+ ellipsis)", #tr[1].text < 20 and tr[1].text:find("\226\128\166") ~= nil)

  eq("transcriptPeek: empty -> {}", #core.transcriptPeek("", {}), 0)
  eq("transcriptPeek: nil -> {}", #core.transcriptPeek(nil), 0)
  eq("transcriptPeek: corrupt line skipped", #core.transcriptPeek("{not json\n" .. lines[1], {}), 1)
end

-- F3: theme export / import round-trip + validation
do
  local nvars = #core.APPEARANCE_VARS
  local exp = core.exportTheme(core.resolveAppearance({ theme = "dracula" }))
  local cnt = 0; for _ in pairs(exp.colors) do cnt = cnt + 1 end
  eq("exportTheme: exports every color token", cnt, nvars)
  eq("exportTheme: dracula accent present", exp.colors.accent, "#bd93f9")
  eq("exportTheme: carries scheme", exp.scheme, "dark")

  local imp = core.importTheme(exp)
  check("importTheme: valid theme -> ok", imp.ok == true)
  eq("importTheme: round-trips accent", imp.appearance.colors.accent, "#bd93f9")
  eq("import->resolve reproduces accent", core.resolveAppearance(imp.appearance).tokens.accent, "#bd93f9")

  check("importTheme: rejects a bad hex (whole import fails, no half-valid palette)",
        core.importTheme({ colors = { accent = "#bd93f9", bg = "nothex" } }).ok == false)
  check("importTheme: rejects an unknown token",
        core.importTheme({ colors = { nope = "#ffffff" } }).ok == false)
  check("importTheme: rejects empty colors", core.importTheme({ colors = {} }).ok == false)
  check("importTheme: non-table rejected", core.importTheme("x").ok == false)
end

-- F8: incremental render signatures
do
  local A = { key = "k1", status = "working", name = "alpha", since = 100 }
  local B = { key = "k1", name = "alpha", since = 100, status = "working" } -- same data, different key order
  eq("tileSignature: key-order independent (stable canonical form)",
     core.tileSignature(A), core.tileSignature(B))
  eq("tileSignature: identical item -> identical sig",
     core.tileSignature(A), core.tileSignature({ key = "k1", status = "working", name = "alpha", since = 100 }))
  check("tileSignature: a changed field changes the sig",
     core.tileSignature(A) ~= core.tileSignature({ key = "k1", status = "idle", name = "alpha", since = 100 }))
  check("tileSignature: a changed key changes the sig",
     core.tileSignature(A) ~= core.tileSignature({ key = "k2", status = "working", name = "alpha", since = 100 }))
  check("tileSignature: 'since' is part of the sig (status reset rebuilds)",
     core.tileSignature(A) ~= core.tileSignature({ key = "k1", status = "working", name = "alpha", since = 200 }))
  check("tileSignature: nested pending.summary captured",
     core.tileSignature({ key="k", pending={ summary="rm x" } }) ~=
     core.tileSignature({ key="k", pending={ summary="rm y" } }))

  local L1  = { { key="a", status="idle" }, { key="b", status="working" } }
  local L1b = { { key="a", status="idle" }, { key="b", status="working" } }
  eq("gridSignature: identical lists -> identical sig", core.gridSignature(L1), core.gridSignature(L1b))
  check("gridSignature: reordering tiles changes the sig",
     core.gridSignature(L1) ~= core.gridSignature({ { key="b", status="working" }, { key="a", status="idle" } }))
  check("gridSignature: adding a tile changes the sig",
     core.gridSignature(L1) ~= core.gridSignature({ { key="a", status="idle" }, { key="b", status="working" }, { key="c", status="done" } }))
  check("gridSignature: removing a tile changes the sig",
     core.gridSignature(L1) ~= core.gridSignature({ { key="a", status="idle" } }))
  check("gridSignature: a tile content change changes the sig",
     core.gridSignature(L1) ~= core.gridSignature({ { key="a", status="error" }, { key="b", status="working" } }))
  eq("gridSignature: non-table -> empty", core.gridSignature(nil), "")
end

-- =============================================================================
-- Regression pins for the 2026-07 fix batch (cc-core half). Each block names the
-- bug it locks; a revert of the fix must fail here.
-- =============================================================================

-- ---- #3: parseStatusList coerces cwd/transcript_path to string-or-nil -------
do
  local now = 10000
  -- A hand-edited / rsync-mirrored status file can legally carry a JSON bool or
  -- number in cwd/transcript_path. Un-coerced, those reach the per-tile loop's
  -- `it.cwd .. "/spec/..."` concat and io.open(it.transcript_path) OUTSIDE the
  -- decode pcall -- and since the file persists, EVERY 1Hz tick aborts there.
  local lst = core.parseStatusList({
    entry("cb", { name = "cb", status = "working", updated = now, cwd = true,  transcript_path = false }),
    entry("cn", { name = "cn", status = "working", updated = now, cwd = 123,   transcript_path = 456 }),
    entry("ck", { name = "ck", status = "working", updated = now, cwd = "/real/path",
                  transcript_path = "/h/.claude/projects/-real-path/s.jsonl" }),
  }, now, 90)
  local by = {}
  for _, it in ipairs(lst) do by[it.name] = it end
  eq("#3: boolean cwd -> nil", by.cb.cwd, nil)
  eq("#3: boolean transcript_path -> nil", by.cb.transcript_path, nil)
  eq("#3: numeric cwd -> nil", by.cn.cwd, nil)
  eq("#3: numeric transcript_path -> nil", by.cn.transcript_path, nil)
  eq("#3: string cwd preserved", by.ck.cwd, "/real/path")
  eq("#3: string transcript_path preserved", by.ck.transcript_path,
     "/h/.claude/projects/-real-path/s.jsonl")
  -- the coercion must run BEFORE projectKey (whose fallback returns data.cwd raw)
  check("#3: projectKey never a non-string (boolean cwd)", type(by.cb.projectKey) ~= "boolean")
  check("#3: projectKey never a non-string (numeric cwd)", type(by.cn.projectKey) ~= "number")
  -- the downstream truthy-guarded consumers must be able to concat safely
  local okConcat = pcall(function()
    for _, it in ipairs(lst) do
      if it.cwd then local _ = it.cwd .. "/spec/product/user-stories.md" end
      if it.transcript_path then local _ = it.transcript_path .. "" end
    end
  end)
  check("#3: downstream concat over the parsed list never throws", okConcat)
end

-- ---- #7 (reader half): parseStatusList lifts mode_cycle -> item.modeCycle ---
do
  local now = 10000
  local lst = core.parseStatusList({
    entry("m1", { name = "m1", status = "working", updated = now,
                  mode_cycle = { bypassPermissions = true } }),
    entry("m2", { name = "m2", status = "working", updated = now, mode_cycle = "garbage" }),
    entry("m3", { name = "m3", status = "working", updated = now }),
  }, now, 90)
  local by = {}
  for _, it in ipairs(lst) do by[it.name] = it end
  check("#7: mode_cycle table lifted onto item.modeCycle",
        type(by.m1.modeCycle) == "table" and by.m1.modeCycle.bypassPermissions == true)
  eq("#7: non-table mode_cycle normalizes to nil", by.m2.modeCycle, nil)
  eq("#7: absent mode_cycle stays nil", by.m3.modeCycle, nil)
end

-- ---- #7 (action half): set-mode sizes the cycle from modeCycle + current mode
do
  -- A session spawned with --permission-mode bypassPermissions rotates through 4
  -- modes; with modeCycle never populated the press count was computed over 3.
  -- plan -> default over [default acceptEdits plan bypassPermissions] = 2 presses
  -- (the 3-mode cycle would send 1, landing set-mode ON acceptEdits... and a later
  -- wrap-around ON bypassPermissions while the panel shows the safe target).
  -- (r.last() is nil-guarded: on regressed code these are 0-step no-ops with no
  -- recorded effect, which must read as a clean FAIL, not abort the suite.)
  local r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", editor = "kitty", permission_mode = "plan",
                            modeCycle = { bypassPermissions = true } }, "set-mode", "default")
  eq("#7: bypass-enabled cycle -> plan->default = 2 presses",
     r.last() and #r.last().b or 0, 2)

  -- Definitional membership: a session sitting IN bypassPermissions has bypass in
  -- its cycle even before any mode_cycle was persisted. Pre-fix this was a 0-step
  -- no-op (cur not in the 3-mode cycle) -- leaving bypass was impossible.
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", editor = "kitty",
                            permission_mode = "bypassPermissions" }, "set-mode", "default")
  eq("#7: leaving bypass works (current mode joins the cycle)",
     r.last() and r.last().op, "sendKeys")
  eq("#7: bypass->default wraps = 1 press", r.last() and #r.last().b or 0, 1)

  -- both optional modes recorded -> the full 5-mode cycle
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", editor = "kitty", permission_mode = "default",
                            modeCycle = { bypassPermissions = true, auto = true } }, "set-mode", "auto")
  eq("#7: 5-mode cycle -> default->auto = 4 presses", r.last() and #r.last().b or 0, 4)

  -- target still outside the cycle -> unchanged no-op (no false keystrokes)
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", editor = "kitty",
                            permission_mode = "default" }, "set-mode", "bypassPermissions")
  eq("#7: un-enabled optional target stays a no-op", r.count(), 0)
end

-- ---- #8: ledger retention keeps a day file until its WHOLE day is expired ----
do
  local ep = core.ledgerFileEpoch("2026-01-01.jsonl")
  check("#8: ledgerFileEpoch sanity", type(ep) == "number")
  -- retention 1 day: cutoff = now - 86400. The file spans [ep, ep+86400); it may
  -- only be deleted once ep+86400 <= cutoff. The old `ep < cutoff` deleted events
  -- up to 24h INSIDE the "Keep for N days" window (written seconds before UTC
  -- midnight, GC'd seconds after).
  eq("#8: newest events still in-window -> file kept",
     #core.expiredLedgerFiles({ "2026-01-01.jsonl" }, ep + 2 * 86400 - 1, 1), 0)
  eq("#8: whole day at the cutoff boundary -> expired",
     #core.expiredLedgerFiles({ "2026-01-01.jsonl" }, ep + 2 * 86400, 1), 1)
  eq("#8: whole day past the cutoff -> expired",
     #core.expiredLedgerFiles({ "2026-01-01.jsonl" }, ep + 3 * 86400, 1), 1)
end

-- ---- #10: fleetStats ignores session-less bookkeeping events for per-session rows
do
  local evs = {
    { ts = 10, type = "prompt",        session_id = "s1", name = "alpha" },
    { ts = 20, type = "purge",         removed = 2 },              -- retention tombstone
    { ts = 30, type = "schedule_fire", name = "daily-digest" },    -- routine record
    { ts = 40, type = "decision",      outcome = "allow", by = "human" },  -- sid-less decision
  }
  local st = core.fleetStats(evs, { now = 100, topN = 8 })
  eq("#10: only the real session is counted", st.totals.sessions, 1)
  eq("#10: session-less events still count in totals.events", st.totals.events, 4)
  eq("#10: session-less decision still counted in decisions", st.decisions.allow, 1)
  eq("#10: session-less decision still counted in provenance", st.provenance.human, 1)
  eq("#10: mostActive has no phantom row", #st.mostActive, 1)
  eq("#10: mostActive is the real session", st.mostActive[1].session_id, "s1")
  for _, row in ipairs(st.mostActive) do
    check("#10: no '?' session row rendered", row.session_id ~= "?")
  end
end

-- ---- #11: slash-command transcript lines are machine bookkeeping, not prompts
do
  -- The exact on-disk shape (verified against a real local transcript): a /clear
  -- (or /model, /cost, ...) is an ordinary non-meta `user` line whose content is
  -- the <command-name>/<command-message>/<command-args> wrapper; local command
  -- output lands as <local-command-stdout>.
  local cmdContent = "<command-name>/clear</command-name>\n"
    .. "<command-message>clear</command-message>\n<command-args></command-args>"
  local function u(content, ts)
    return { type = "user", timestamp = ts, message = { role = "user", content = content } }
  end
  check("#11: command wrapper is not a human prompt (string content)",
        core.userHasHumanText(u(cmdContent)) == false)
  check("#11: command wrapper is not a human prompt (array content)",
        core.userHasHumanText({ type = "user", message = { role = "user",
          content = { { type = "text", text = cmdContent } } } }) == false)
  check("#11: local-command stdout is not a human prompt",
        core.userHasHumanText(u("<local-command-stdout>4.2 MB used</local-command-stdout>")) == false)
  -- a real prompt still registers, incl. next to an IDE wrapper
  check("#11: genuine prompt still a human prompt",
        core.userHasHumanText(u("run the tests")) == true)
  check("#11: prompt paired with an IDE wrapper still registers",
        core.userHasHumanText(u("<ide_opened_file>f</ide_opened_file>\nfix it")) == true)

  -- (a) transcriptResumed: a /model line minutes after `done` must NOT flip the
  -- tile back to working (the exact false-trigger class 6bb790b locked for
  -- bare ide_opened_file, reintroduced for command lines by 809cf19).
  local function aline(ts)
    return core.json.encode({ type = "assistant", timestamp = ts,
                              message = { content = { { type = "text", text = "x" } } } })
  end
  local cmdLine = core.json.encode(u(cmdContent, "2026-06-18T14:05:00Z"))
  local t0 = core.isoToEpoch("2026-06-18T14:00:00Z")
  check("#11: command line after stale done does NOT resume",
        core.transcriptResumed(aline("2026-06-18T14:00:00Z") .. "\n" .. cmdLine, t0 + 1, 2) == false)

  -- (b) transcriptError: a command line after an api_error is NOT recovery --
  -- clearing the error status silenced auto-continue for a genuinely frozen session.
  local errline = core.json.encode({ type = "system", subtype = "api_error",
    error = { formatted = "Unable to connect to API" } })
  check("#11: command line after api_error does NOT mask the error",
        core.transcriptError(errline .. "\n" .. cmdLine) ~= nil)

  -- (c) transcriptPeek: no fake user turn rendering the raw wrapper blob
  local rows = core.transcriptPeek(aline("2026-06-18T14:00:00Z") .. "\n" .. cmdLine, { n = 10 })
  for _, row in ipairs(rows) do
    check("#11: peek never renders a <command-name> blob as a user turn",
          not (row.role == "user" and row.text:find("<command-name>", 1, true)))
  end
end

-- ---- #16: search hit text is repaired to whole UTF-8 characters --------------
do
  -- C-locale grep's `.{0,60}` context wrap counts BYTES, so a hit can start with
  -- orphaned continuation bytes / end mid-sequence; hs.json.encode would sanitize
  -- them to U+FFFD and the row renders visible '�' garbage.
  local contTail = "\150\145"                    -- two orphaned continuation bytes
  local res = core.parseSearchResults("/f.jsonl:1:" .. contTail .. "rocket tail\n")
  eq("#16: leading continuation bytes dropped", res.hits[1].text, "rocket tail")

  -- a trailing truncated sequence (first 2 bytes of a 4-byte emoji) is dropped
  local res2 = core.parseSearchResults("/f.jsonl:2:abc\240\159\n")
  eq("#16: trailing truncated sequence dropped", res2.hits[1].text, "abc")

  -- the maxLen display slice is a byte slice too: slicing mid-emoji must not
  -- leave the partial sequence before the ellipsis
  local res3 = core.parseSearchResults("/f.jsonl:3:ab\240\159\154\128xyz\n", { maxLen = 4 })
  eq("#16: maxLen slice mid-emoji repaired", res3.hits[1].text, "ab\226\128\166")

  -- intact multibyte text passes through byte-for-byte
  local intact = "\240\159\154\128 ok"           -- a whole rocket + ascii
  local res4 = core.parseSearchResults("/f.jsonl:4:" .. intact .. "\n")
  eq("#16: intact UTF-8 untouched", res4.hits[1].text, intact)
  -- plain ASCII behavior is unchanged (exact bytes, incl. the maxLen backstop)
  local res5 = core.parseSearchResults("/f.jsonl:5:" .. string.rep("x", 300) .. "\n", { maxLen = 10 })
  eq("#16: ASCII maxLen behavior unchanged", res5.hits[1].text, string.rep("x", 10) .. "\226\128\166")
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
