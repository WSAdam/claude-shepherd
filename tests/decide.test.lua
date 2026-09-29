-- decide.test.lua : BEHAVIORAL fixture for the decisions inbox, the panel side (2026-09-29, build
-- program unit 28). A session asks with cc-decide.sh instead of stopping: non-blocking, it goes on
-- with the default; --blocking, its waiter takes Adam's answer (tests/decide.test.sh). Shepherd
-- reads ~/.claude/cc-decide/<key>.<epoch>-<pid>.json, lists the open ones with the held
-- AskUserQuestions in one fleet-wide Inbox, and writes Adam's answer as <id>.answer, bound to the
-- nonce READ FROM DISK. A late answer to a session that went on reaches it through the mailbox
-- (FX.mailboxSend) while it is live, else waits for its next start. Needs-you: an open blocking
-- question needs Adam; a non-blocking one is a heads-up, inside core.needsYouKind's one predicate.
-- The pure half runs cc-core.lua; the panel half the real claude-dashboard.lua under a stubbed hs.
-- Side-effect-free: HOME and every dir live in a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- decide.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.parseDecision exists", type(core.parseDecision) == "function")
if type(core.parseDecision) ~= "function" then finish() end

local NOW = 1790000000
local function record(over)
  local r = { v = 1, id = "k1.1789999900-4242", key = "k1", session_id = "k1", cwd = "/r/proj",
              question = "Which port?", default = "4100", options = { "4100", "4200" },
              blocking = false, nonce = "0123456789abcdef", asked = NOW - 100 }
  for k, v in pairs(over or {}) do r[k] = v end
  if over and over.options == false then r.options = nil end
  return r
end
local function parse(over, name)
  local r = record(over)
  return core.parseDecision(name or (r.id .. ".json"), json.encode(r))
end

-- the id: <key>.<epoch>-<pid>, the key being everything before the LAST dot
check("decisionKeyOf: the key of <key>.<epoch>-<pid>", core.decisionKeyOf("k1.1789999900-4242") == "k1")
check("...a key with a dot in it keeps it", core.decisionKeyOf("k1.x.1789999900-4242") == "k1.x")
check("...not an id: nil", core.decisionKeyOf("k1") == nil and core.decisionKeyOf("k1.12a-3") == nil
      and core.decisionKeyOf("../x.1-2") == nil and core.decisionKeyOf("a/b.1-2") == nil and core.decisionKeyOf(nil) == nil)

-- parse: what cc-decide.sh writes, checked field by field
local d = parse()
check("parseDecision reads a record", d ~= nil and d.id == "k1.1789999900-4242" and d.key == "k1")
check("...its question, default and options", d and d.question == "Which port?" and d.default == "4100"
      and #d.options == 2 and d.options[2] == "4200")
check("...not blocking", d and d.blocking == false)
check("a record named for another id: refused", parse({}, "k1.1789999900-9999.json") == nil)
check("a record whose key isn't its id's: refused", parse({ key = "k2" }) == nil)
check("a record with no nonce: refused", parse({ nonce = "" }) == nil and parse({ nonce = "a b" }) == nil)
check("a record with no question: refused", parse({ question = "  " }) == nil)
check("a record with no default: refused", parse({ default = json.null or "" }) == nil)
check("torn JSON: refused", core.parseDecision("k1.1789999900-4242.json", '{"v":1,"id":"k1.17') == nil)
check("a temp or an answer isn't a record", core.parseDecision("k1.1789999900-4242.json.tmp.7", json.encode(record())) == nil
      and core.parseDecision("k1.1789999900-4242.answer", json.encode(record())) == nil)
check("no options: an empty list", (parse({ options = false }) or {}).options ~= nil and #parse({ options = false }).options == 0)
local long = parse({ question = string.rep("q", 3000) })
check("a long question is capped for the Inbox", long ~= nil and #long.question <= core.DECIDE.questionMax + 8)

-- blocking: only while its waiter still waits
check("decisionBlocking: a blocking question before its timeout", core.decisionBlocking(parse({ blocking = true, ["until"] = NOW + 60 }), NOW))
check("...not after it", not core.decisionBlocking(parse({ blocking = true, ["until"] = NOW - 1 }), NOW))
check("...never a non-blocking one", not core.decisionBlocking(parse({ blocking = false, ["until"] = NOW + 60 }), NOW))
check("...nor a blocking one with no timeout", not core.decisionBlocking(parse({ blocking = true }), NOW))

-- Adam's answer: bound to the record's nonce
local p = core.decisionAnswerPayload(d, "  4200  ", NOW)
check("decisionAnswerPayload: the record's nonce, the answer trimmed, when", p and p.nonce == d.nonce
      and p.answer == "4200" and p.at == NOW)
check("...an empty answer: refused", core.decisionAnswerPayload(d, "   ", NOW) == nil)
check("...an answer too long: refused", core.decisionAnswerPayload(d, string.rep("a", core.DECIDE.answerMax + 1), NOW) == nil)
check("...free text is Adam's to give", (core.decisionAnswerPayload(d, "5000, and say why", NOW) or {}).answer == "5000, and say why")
check("parseDecisionAnswer: the answer, when its nonce is the record's",
      core.parseDecisionAnswer(d, json.encode(p)) == "4200")
check("...nil for another nonce", core.parseDecisionAnswer(d, json.encode({ nonce = "ffffffffffffffff", answer = "4200" })) == nil)
check("...nil for torn JSON or an empty answer", core.parseDecisionAnswer(d, '{"nonce":"01') == nil
      and core.parseDecisionAnswer(d, json.encode({ nonce = d.nonce, answer = " " })) == nil)

-- what a live session is told (through the mailbox)
local msg = core.decisionMessage(d, "4200")
check("decisionMessage names the question, the default it went with and Adam's answer",
      type(msg) == "string" and msg:find("Which port?", 1, true) and msg:find("4100", 1, true) and msg:find("4200", 1, true))
check("...nothing when the answer IS the default (nothing to change)", core.decisionMessage(d, "4100") == nil)
check("...and never a slash command, whatever the answer", not core.mailboxSlash(core.decisionMessage(d, "/clear") or ""))

-- the tiles: open questions per session
local decs = { parse(), parse({ id = "k1.1789999950-1", question = "Second?" }),
               parse({ id = "k2.1789999900-7", key = "k2", blocking = true, ["until"] = NOW + 60 }),
               parse({ id = "k3.1789999900-8", key = "k3", blocking = true, ["until"] = NOW - 5 }) }
local tiles = core.decisionTiles(decs, NOW)
check("decisionTiles: two open questions on k1, none blocking", tiles.k1 and tiles.k1.open == 2 and tiles.k1.blocking == 0)
check("...the oldest first as its line", tiles.k1 and tiles.k1.question == "Which port?")
check("...one blocking on k2", tiles.k2 and tiles.k2.open == 1 and tiles.k2.blocking == 1)
check("...a timed-out blocking question is open, not blocking", tiles.k3 and tiles.k3.blocking == 0 and tiles.k3.open == 1)

-- ---- needs-you: one predicate (core.needsYouKind), no new tier ----
local function kind(over)
  local it = { key = "k", status = "done", procAlive = true }
  for k, v in pairs(over or {}) do it[k] = v end
  return core.needsYouKind(it, NOW)
end
local k1, s1, w1 = kind({ decisions = { open = 1, blocking = 0 } })
check("an open non-blocking question on a finished session: a heads-up", k1 == "fyi" and s1 == "decide")
check("...saying it went on with the default  (" .. tostring(w1) .. ")", type(w1) == "string" and w1:find("default", 1, true) ~= nil)
check("...ranked as a heads-up (core.TIER_FYI)", core.instanceTier({ key = "k", status = "done", procAlive = true,
      decisions = { open = 1, blocking = 0 } }, {}, NOW) == core.TIER_FYI)
check("an open question on a session still WORKING: nothing (it reads Working)",
      kind({ status = "working", decisions = { open = 1, blocking = 0 } }) == nil)
check("...or one with background agents running", kind({ bg_active = true, decisions = { open = 1, blocking = 0 } }) == nil)
local k2, s2 = kind({ status = "working", decisions = { open = 1, blocking = 1 } })
check("a blocking question needs Adam (its waiter holds the session)", k2 == "needs" and s2 == "decide")
check("...ranked with the other needs (tier 1), never a new tier",
      core.instanceTier({ key = "k", status = "working", procAlive = true, decisions = { open = 1, blocking = 1 } }, {}, NOW) == 1)
check("...a heads-up once the session that asked has gone",
      kind({ procAlive = false, decisions = { open = 1, blocking = 1 } }) == "fyi")
local k3, s3 = kind({ status = "approval", decisions = { open = 1, blocking = 0 } })
check("a permission prompt still wins over a non-blocking question", k3 == "needs" and s3 == "approval")
check("no question: nothing", kind({ decisions = { open = 0, blocking = 0 } }) == nil and kind({}) == nil)

-- ---- the Inbox: open questions and held AskUserQuestions, fleet-wide ----
local items = {
  { key = "k1", label = "alpha", name = "proj-a", cwd = "/r/proj" },
  { key = "k2", label = "beta", name = "proj-b", cwd = "/r/b" },
  { key = "k5", label = "gamma", name = "proj-c", cwd = "/r/c", askHeld = true, ask_nonce = "an1",
    askView = { question = "Pick a colour", options = { "red", "blue" }, count = 1, simple = true } },
}
local rows = core.inboxRows(decs, items, NOW)
check("inboxRows: every open question and held ask  (" .. #rows .. ")", #rows == 5)
check("...the ones holding a session first: the blocking question, then the held ask",
      rows[1] and rows[1].kind == "decide" and rows[1].blocking == true and rows[2] and rows[2].kind == "ask")
check("...then the rest, oldest first", rows[3] and rows[3].id == "k1.1789999900-4242" and rows[4].id == "k1.1789999950-1")
check("...each named for its session", rows[3].session == "alpha" and rows[2].session == "gamma")
check("...a question carries its id, default and options", rows[3].default == "4100" and #rows[3].options == 2)
check("...a held ask carries its key and options", rows[2].key == "k5" and rows[2].options[2] == "blue" and rows[2].simple == true)
check("...a question whose session isn't on the panel still shows", rows[5] and rows[5].key == "k3" and rows[5].session ~= nil)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local ph = io.popen("mktemp -d 2>/dev/null"); T = ph and ph:read("*l"); if ph then ph:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local DEC, INBOX = T .. "/.claude/cc-decide", T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. DEC .. '" "' .. T .. '/vs" "' .. T .. '/kt"')
local RNOW = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) return readFile(path) ~= nil end
local function ls(dir)
  local out, ph = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if ph then for line in ph:lines() do out[#out + 1] = line end; ph:close() end
  table.sort(out)
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2}}')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/vs", since = RNOW - 100,
              updated = RNOW - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
local function plantDecision(id, over)
  local r = record({ id = id, key = core.decisionKeyOf(id), session_id = core.decisionKeyOf(id), asked = RNOW - 50 })
  for k, v in pairs(over or {}) do r[k] = v end
  write(DEC .. "/" .. id .. ".json", json.encode(r))
  return r
end
status("live1")
status("busy1", { status = "working", updated = RNOW - 1 })
plantDecision("live1.1789999900-11")                               -- a live session's open question
plantDecision("busy1.1789999900-12", { blocking = true, ["until"] = RNOW + 600, pid = 99999 })
plantDecision("gone1.1789999900-13")                               -- its session has no status file

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, js) jsCalls[#jsCalls + 1] = js end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, ph = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if ph then for line in ph:lines() do files[#files + 1] = line end; ph:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path)
      local h = io.open(tostring(path), "r")
      if h then h:close(); return { mode = "file" } end
      return nil, "no such file"
    end,
    mkdir = function(path) os.execute('mkdir "' .. tostring(path) .. '" 2>/dev/null'); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end, usleep = function() end,
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
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quietly(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quietly(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
check("FX.stepDecisions, FX.answerDecision and FX.DECIDE_DIR exist",
      type(fx.stepDecisions) == "function" and type(fx.answerDecision) == "function" and fx.DECIDE_DIR == DEC)
if type(fx.stepDecisions) ~= "function" or type(fx.answerDecision) ~= "function" then finish() end
local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return RNOW end

local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("(fixture: both sessions are on the panel)", byK.live1 ~= nil and byK.busy1 ~= nil)
if not (byK.live1 and byK.busy1) then finish() end

-- the tick stamps each card
quietly(function() fx.stepDecisions(fx._shownItems) end)
check("the tick stamps a card with its open questions", byK.live1.decisions and byK.live1.decisions.open == 1
      and byK.live1.decisions.blocking == 0)
check("...and one with a blocking question", byK.busy1.decisions and byK.busy1.decisions.blocking == 1)
check("...the card with the non-blocking question is a heads-up once stamped",
      core.needsYouKind(byK.live1, RNOW) == "fyi")
local inbox = fx.inboxRows and fx.inboxRows() or {}
check("the Inbox lists all three open questions, fleet-wide  (" .. #inbox .. ")", #inbox == 3)
check("...the blocking one first", inbox[1] and inbox[1].id == "busy1.1789999900-12")

-- the answer is bound to the nonce READ FROM DISK, never one the panel remembered
local onDisk = json.decode(readFile(DEC .. "/live1.1789999900-11.json"))
onDisk.nonce = "fedcba9876543210"
write(DEC .. "/live1.1789999900-11.json", json.encode(onDisk))
local okA
quietly(function() okA = fx.answerDecision("live1.1789999900-11", "4200") end)
check("FX.answerDecision answers an open question", okA == true)
-- a live session: the tick hands the answer over through its mailbox and closes the question
quietly(function() fx.stepDecisions(fx._shownItems) end)
local box = ls(INBOX .. "/live1")
check("a live session's late answer goes to its mailbox  (" .. table.concat(box, " ") .. ")", #box == 1)
local m = box[1] and json.decode(readFile(INBOX .. "/live1/" .. box[1]) or "{}") or {}
check("...naming the question, the default and Adam's answer", type(m.text) == "string"
      and m.text:find("Which port?", 1, true) and m.text:find("4100", 1, true) and m.text:find("4200", 1, true))
check("...as a [shepherd] message", type(m.text) == "string" and m.text:sub(1, 11) == "[shepherd] ")
check("...and the question is closed, answer and all",
      not exists(DEC .. "/live1.1789999900-11.json") and not exists(DEC .. "/live1.1789999900-11.answer"))
-- (the answer carried the nonce on disk: the delivery above only happens for a matching nonce)
check("...the ledger says so", (function()
  for _, ev in ipairs(ledger) do if ev.type == "decision_answered" and ev.via == "mailbox" then return true end end
  return false end)())

-- a second answer to a closed question is refused
local again
quietly(function() again = fx.answerDecision("live1.1789999900-11", "5000") end)
check("answering a question that is closed: refused", again == false)
check("...nothing written", not exists(DEC .. "/live1.1789999900-11.answer"))

-- a blocking question: its waiter takes the answer, Shepherd never delivers it itself
local okB
quietly(function() okB = fx.answerDecision("busy1.1789999900-12", "no") end)
quietly(function() fx.stepDecisions(fx._shownItems) end)
check("a blocking question's answer is written for its waiter", okB == true and exists(DEC .. "/busy1.1789999900-12.answer"))
check("...bound to its nonce", (json.decode(readFile(DEC .. "/busy1.1789999900-12.answer") or "{}") or {}).nonce == "0123456789abcdef")
check("...and Shepherd leaves it to the waiter (no mailbox message)", #ls(INBOX .. "/busy1") == 0)
local answeredGone = true
for _, r in ipairs(fx.inboxRows()) do if r.id == "busy1.1789999900-12" then answeredGone = false end end
check("...an answered question leaves the Inbox", answeredGone)

-- a session that isn't live: the answer waits for its next start
local okC
quietly(function() okC = fx.answerDecision("gone1.1789999900-13", "4200") end)
quietly(function() fx.stepDecisions(fx._shownItems) end)
check("a session that isn't live: the answer waits on disk for its next start",
      okC == true and exists(DEC .. "/gone1.1789999900-13.json") and exists(DEC .. "/gone1.1789999900-13.answer"))
check("...no mailbox message", #ls(INBOX .. "/gone1") == 0)

-- answering with the default closes it without telling the session anything
plantDecision("live1.1789999960-14")
quietly(function() fx.stepDecisions(fx._shownItems) end)
local okD
quietly(function() okD = fx.answerDecision("live1.1789999960-14", "4100") end)
quietly(function() fx.stepDecisions(fx._shownItems) end)
check("keeping the default closes the question", okD == true and not exists(DEC .. "/live1.1789999960-14.json"))
check("...without a message (nothing to change)", #ls(INBOX .. "/live1") == 1)

-- a forged answer (another nonce) is never delivered, and is thrown away
plantDecision("live1.1789999970-15")
write(DEC .. "/live1.1789999970-15.answer", json.encode({ nonce = "ffffffffffffffff", answer = "9999" }))
quietly(function() fx.stepDecisions(fx._shownItems) end)
check("an answer with another nonce is never delivered", #ls(INBOX .. "/live1") == 1)
check("...it is thrown away, and the question stays open",
      not exists(DEC .. "/live1.1789999970-15.answer") and exists(DEC .. "/live1.1789999970-15.json"))

-- unknown or malformed ids are refused before anything is read or written
local okE
quietly(function() okE = fx.answerDecision("../../etc/passwd.1-2", "x") end)
check("an id that could leave the folder: refused", okE == false)

-- FX.removeStatus mirrors cc_remove: the key's open questions go, an answer waiting for its start stays
plantDecision("gone2.1789999900-16")
plantDecision("gone2.1789999910-17")
write(DEC .. "/gone2.1789999910-17.answer", json.encode({ nonce = "0123456789abcdef", answer = "4200" }))
write(DEC .. "/gone2.1789999900-16.json.tmp.4242", "{")
plantDecision("gone2.x.1789999900-18")
write(DEC .. "/orphan.1789999900-19.answer", json.encode({ nonce = "0123456789abcdef", answer = "x" }))
quietly(function() fx.removeStatus("gone2") end)
check("...and prunes an answer whose question is gone (any session's)", not exists(DEC .. "/orphan.1789999900-19.answer"))
check("FX.removeStatus drops the session's open question", not exists(DEC .. "/gone2.1789999900-16.json"))
check("...and a torn write of it", not exists(DEC .. "/gone2.1789999900-16.json.tmp.4242"))
check("...keeps an answered one for its next start",
      exists(DEC .. "/gone2.1789999910-17.json") and exists(DEC .. "/gone2.1789999910-17.answer"))
check("...and leaves another session's alone (gone2 is not gone2.x)", exists(DEC .. "/gone2.x.1789999900-18.json"))

-- the panel gets the Inbox's rows
jsCalls = {}
quietly(function() fx.pushInbox() end)
local pushed = false
for _, js in ipairs(jsCalls) do if js:find("ccInbox(", 1, true) then pushed = true end end
check("FX.pushInbox sends the rows to the panel (ccInbox)", pushed)

finish()
