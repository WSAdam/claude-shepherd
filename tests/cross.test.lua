-- cross.test.lua : BEHAVIORAL fixture for crossings, Shepherd's side (2026-10-14).
-- Adam, 2026-10-14: "projects should not be able to utilize having shepherd to talk to each other,
-- that needs to be an approved translation between the two rather than something automatic". A
-- ticket one repo's session files for another, and every reply and close travelling back, used to
-- reach the other side on its own (ticket t1792000806-490435810 went confirmations-bot ->
-- ChargebackSentinel and back with two replies, unseen). Now the CLI leaves a REQUEST in
-- ~/.claude/cc-cross/, Shepherd holds it on the author's card as a red Needs you with the exact
-- text, and only Adam's Approve -- after an edit, if he likes -- publishes it into the ticket; Deny
-- tells the author his note. Pure half first (cc-core), then the real dashboard under a stubbed hs,
-- like tests/ticket.test.lua. Side-effect-free: HOME and every dir are a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end
local function finish() print("-- cross.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.parseCrossRequest exists", type(core.parseCrossRequest) == "function")
if type(core.parseCrossRequest) ~= "function" then finish() end

local NOW = 1792100000
local CID = "f1.1792100000-77"
local function req(over)
  local r = { v = 1, cid = CID, nonce = "77.1792100000.5", kind = "ticket", at = NOW, ticket = "t1792100000-77",
              from = { key = "f1", pid = "4242", cwd = "/r/alpha", root = "/r/alpha", name = "alpha" },
              to = { root = "/r/beta", name = "beta" }, title = "Bump the parser", body = "alpha needs parser 2.x." }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

-- ids and file names
check("a crossing id is <author key>.<epoch>-<n>", core.crossIdOk(CID) and core.crossIdOk("a.b-c.1-2")
      and not core.crossIdOk("f1") and not core.crossIdOk("../x.1-2") and not core.crossIdOk("f1.1-"))
eq("...its author is the key before it", core.crossAuthorOf("a.b-c.1792100000-3"), "a.b-c")
local fo = core.crossFileOf(CID .. ".req.json")
check("a session's request is <cid>.req.json", fo and fo.cid == CID and fo.kind == "req")
fo = core.crossFileOf(CID .. ".json")
check("...Shepherd's record of it <cid>.json", fo and fo.cid == CID and fo.kind == "record")
fo = core.crossFileOf(CID .. ".notice")
check("...a note left for an ended author <cid>.notice", fo and fo.cid == CID and fo.kind == "notice")
fo = core.crossFileOf(CID .. ".req.json.claim.shepherd")
check("...a claim of a request is a claim", fo and fo.cid == CID and fo.kind == "claim" and fo.of == "req")
fo = core.crossFileOf(CID .. ".json.tmp.12")
check("...a temp is a temp", fo and fo.kind == "tmp" and fo.of == "record")
check("...anything else isn't a crossing's", core.crossFileOf("notes.txt") == nil and core.crossFileOf("x.json") == nil)

-- parsing a request: the CLI wrote it, so every field is checked again
local r = core.parseCrossRequest(json.encode(req()), CID)
check("a filing request is read back", r and r.kind == "ticket" and r.title == "Bump the parser" and r.to.root == "/r/beta"
      and r.from.key == "f1" and r.ticket == "t1792100000-77")
check("...a body naming another cid is refused", core.parseCrossRequest(json.encode(req()), "f1.1792100000-78") == nil)
check("...one whose author isn't the cid's is refused",
      core.parseCrossRequest(json.encode(req({ from = { key = "w9" } })), CID) == nil)
check("...an unknown kind is refused", core.parseCrossRequest(json.encode(req({ kind = "mail" })), CID) == nil)
check("...a title over 200 bytes is refused",
      core.parseCrossRequest(json.encode(req({ title = string.rep("x", 201) })), CID) == nil)
check("...a title that isn't one line is refused",
      core.parseCrossRequest(json.encode(req({ title = "two\nlines" })), CID) == nil)
check("...a body over 2500 bytes is refused",
      core.parseCrossRequest(json.encode(req({ body = string.rep("x", 2501) })), CID) == nil)
check("...a filing with no target is refused", core.parseCrossRequest(json.encode(req({ to = { name = "beta" } })), CID) == nil)
check("...torn JSON is refused", core.parseCrossRequest('{"v":1,"cid":"f1.17', CID) == nil)
local rr = core.parseCrossRequest(json.encode(req({ kind = "ticket-reply", role = "holder", text = "On it." })), CID)
check("a reply request is read back with its role and text", rr and rr.kind == "ticket-reply" and rr.role == "holder" and rr.text == "On it.")
check("...a reply over 2000 bytes is refused", core.parseCrossRequest(json.encode(req({ kind = "ticket-reply", role = "holder",
      text = string.rep("x", 2001) })), CID) == nil)
check("...an empty one is refused", core.parseCrossRequest(json.encode(req({ kind = "ticket-reply", role = "holder", text = "  " })), CID) == nil)
check("...a role that is neither side is refused", core.parseCrossRequest(json.encode(req({ kind = "ticket-reply", role = "boss",
      text = "x" })), CID) == nil)
local rc = core.parseCrossRequest(json.encode(req({ kind = "ticket-close", role = "holder", note = "Done: 2.1.0." })), CID)
check("a close request is read back with its note", rc and rc.kind == "ticket-close" and rc.note == "Done: 2.1.0.")
check("...a note over 1000 bytes is refused", core.parseCrossRequest(json.encode(req({ kind = "ticket-close", role = "holder",
      note = string.rep("x", 1001) })), CID) == nil)
local rw = core.parseCrossRequest(json.encode(req({ kind = "withdraw" })), CID)
check("a withdraw request names the filing's ticket", rw and rw.kind == "withdraw" and rw.ticket == "t1792100000-77")

-- the record Shepherd keeps, and Adam's decision on it
local rec = core.crossRecord(r, NOW + 5)
check("a held request becomes a pending record", rec and rec.state == "pending" and rec.cid == CID and rec.at == NOW
      and rec.heldAt == NOW + 5 and rec.original.title == "Bump the parser" and rec.nonce == "77.1792100000.5")
check("...read back from its file", core.parseCrossRecord(json.encode(rec), CID) ~= nil
      and core.parseCrossRecord(json.encode(rec), "f1.1792100000-99") == nil)
local d = core.crossDecide(core.crossRecord(r, NOW), "approve", nil, nil, NOW + 60)
check("Approve as written: approved, not edited", d and d.state == "approved" and d.final.title == "Bump the parser"
      and d.decided.verdict == "approve" and not d.decided.edited)
d = core.crossDecide(core.crossRecord(r, NOW), "approve", { title = "Bump the parser to 2.1", body = "alpha needs 2.1." }, nil, NOW + 60)
check("Approve after an edit: approved, edited, the final text is Adam's", d and d.state == "approved" and d.decided.edited == true
      and d.final.title == "Bump the parser to 2.1" and d.final.body == "alpha needs 2.1." and d.original.title == "Bump the parser")
local bad, why = core.crossDecide(core.crossRecord(r, NOW), "approve", { title = string.rep("x", 201) }, nil, NOW)
check("an edit over a cap is refused, saying why", bad == nil and type(why) == "string" and why:find("200", 1, true) ~= nil)
bad = core.crossDecide(core.crossRecord(r, NOW), "approve", { title = "  " }, nil, NOW)
check("...so is an emptied title", bad == nil)
bad = core.crossDecide(core.crossRecord(r, NOW), "approve", { title = "a\nb" }, nil, NOW)
check("...and a title broken onto two lines", bad == nil)
d = core.crossDecide(core.crossRecord(r, NOW), "deny", nil, "Not now -- rune is mid-release.", NOW + 60)
check("Deny: denied, with Adam's note", d and d.state == "denied" and d.decided.note == "Not now -- rune is mid-release.")
check("a decided record can't be decided again", core.crossDecide(d, "approve", nil, nil, NOW + 61) == nil)
d = core.crossDecide(core.crossRecord(rr, NOW), "approve", { text = "On it, bumping now." }, nil, NOW)
check("a reply is edited through its text", d and d.final.text == "On it, bumping now." and d.decided.edited == true)
d = core.crossDecide(core.crossRecord(rc, NOW), "approve", { note = "Done: 2.1.0 tagged." }, nil, NOW)
check("a close is edited through its note", d and d.final.note == "Done: 2.1.0 tagged." and d.decided.edited == true)

-- publishing into the ticket: only an approved record, once
local fil = core.crossDecide(core.crossRecord(r, NOW), "approve", { title = "Bump the parser to 2.1", body = "alpha needs 2.1." }, nil, NOW + 60)
local t = core.crossTicketPublish(fil, nil, NOW + 60)
check("an approved filing becomes a published ticket with Adam's text", t and t.id == "t1792100000-77" and t.title == "Bump the parser to 2.1"
      and t.cid == CID and t.from.key == "f1" and t.to.root == "/r/beta" and t.filed == NOW and t.edited == true)
check("...a pending record publishes nothing", core.crossTicketPublish(core.crossRecord(r, NOW), nil, NOW) == nil)
check("...nor a filing whose ticket file is there already", core.crossTicketPublish(fil, t, NOW) == nil)
check("a ticket published by Shepherd is published", core.ticketPublished(t))
check("...one filed before the gate shipped is too (Adam: let them through)",
      core.ticketPublished({ id = "t1-1", filed = core.CROSS.legacyBefore - 1 }))
check("...one written after it with no crossing is not", not core.ticketPublished({ id = "t1-1", filed = core.CROSS.legacyBefore + 1 }))
t.holder = { key = "w1", taken = true, at = NOW }
local rep = core.crossDecide(core.crossRecord(core.parseCrossRequest(json.encode(req({ cid = "w1.1792100100-1",
      from = { key = "w1" }, kind = "ticket-reply", role = "holder", text = "On it." })), "w1.1792100100-1"), NOW + 100),
      "approve", { text = "On it -- 2.1 by noon." }, nil, NOW + 200)
local t2 = core.crossTicketPublish(rep, t, NOW + 200)
local e = t2 and t2.thread[#t2.thread]
check("an approved reply lands in the thread, untold, carrying its crossing", e and e.by == "holder" and e.key == "w1"
      and e.text == "On it -- 2.1 by noon." and e.told == false and e.cid == "w1.1792100100-1" and e.edited == true)
check("...publishing it twice adds it once", #core.crossTicketPublish(rep, t2, NOW + 201).thread == 1)
check("...ticketNews hands it to the filer", core.ticketNews(t2, "filer") ~= nil)
local news = core.ticketNewsText(t2, core.ticketNews(t2, "filer"), "filer", "w1")
check("...and the news says Adam edited it", news:find("On it -- 2.1 by noon.", 1, true) ~= nil and news:find(core.CROSS_EDITED, 1, true) ~= nil)
check("the offer of an edited ticket says so too", core.ticketOfferText(t, "f1"):find(core.CROSS_EDITED, 1, true) ~= nil)
check("...one Adam passed as written doesn't", not core.ticketOfferText(core.crossTicketPublish(
      core.crossDecide(core.crossRecord(r, NOW), "approve", nil, nil, NOW), nil, NOW), "f1"):find(core.CROSS_EDITED, 1, true))
local cls = core.crossDecide(core.crossRecord(core.parseCrossRequest(json.encode(req({ cid = "w1.1792100300-1",
      from = { key = "w1" }, kind = "ticket-close", role = "holder", note = "Tagged 2.1.0." })), "w1.1792100300-1"), NOW + 300),
      "approve", nil, nil, NOW + 400)
local t3 = core.crossTicketPublish(cls, t2, NOW + 400)
check("an approved close closes the ticket, untold", t3 and t3.closed and t3.closed.by == "holder" and t3.closed.note == "Tagged 2.1.0."
      and t3.closed.told == false and t3.closed.cid == "w1.1792100300-1")
local late = core.crossDecide(core.crossRecord(core.parseCrossRequest(json.encode(req({ cid = "w1.1792100500-1", at = NOW + 500,
      from = { key = "w1" }, kind = "ticket-reply", role = "holder", text = "One more thing." })), "w1.1792100500-1"), NOW + 500),
      "approve", nil, nil, NOW + 600)
local lt, lwhy = core.crossTicketPublish(late, t3, NOW + 600)
check("a reply written after the ticket closed is void", lt == nil and lwhy == "closed")
check("a reply to a ticket that's gone is void", select(2, core.crossTicketPublish(rep, nil, NOW)) == "gone")
-- the role a request claims must be the author's
check("the holder's role is the holder's", core.crossRoleOk(rep, t2))
check("...a session claiming to be the filer isn't", not core.crossRoleOk({ role = "filer", from = { key = "w1" } }, t2))
check("...the filer found by pid after a /clear is the filer",
      core.crossRoleOk({ role = "filer", from = { key = "f1-new", pid = "4242" } }, { from = { key = "f1", pid = "4242" } }))

-- what the author is told
local denied = core.crossDecide(core.crossRecord(r, NOW), "deny", nil, "Not now -- rune is mid-release.", NOW)
local nt = core.crossNoticeText(denied)
check("a denied filing tells its author Adam's note, [shepherd]-marked",
      nt and nt:sub(1, 11) == "[shepherd] " and nt:find("Not now -- rune is mid-release.", 1, true) ~= nil
      and nt:find("not filed", 1, true) ~= nil and nt:find("beta", 1, true) ~= nil)
check("...and not to route around it", nt and nt:find("route around", 1, true) ~= nil)
nt = core.crossNoticeText(core.crossDecide(core.crossRecord(r, NOW), "approve", { title = "Bump the parser to 2.1" }, nil, NOW))
check("an edited approval tells its author what went out", nt and nt:find("edited", 1, true) ~= nil
      and nt:find("Bump the parser to 2.1", 1, true) ~= nil)
check("an approval as written tells nobody anything", core.crossNoticeText(core.crossDecide(core.crossRecord(r, NOW), "approve", nil, nil, NOW)) == nil)

-- the card: count, the oldest's line and view
local recs = {
  core.crossRecord(core.parseCrossRequest(json.encode(req({ cid = "f1.1792100900-2", at = NOW + 900 })), "f1.1792100900-2"), NOW),
  core.crossRecord(r, NOW),
  core.crossRecord(core.parseCrossRequest(json.encode(req({ cid = "z9.1792100000-1", from = { key = "z9" } })), "z9.1792100000-1"), NOW),
  denied,
}
local tiles = core.crossTiles(recs, function(key) return (key == "f1") and "tile-f1" or nil end)
local c = tiles["tile-f1"]
check("a card counts its author's pending crossings, never a decided one", c and c.n == 2)
check("...and shows the oldest", c and c.cid == CID and c.line:find("Bump the parser", 1, true) ~= nil and c.line:find("beta", 1, true) ~= nil)
check("...its view carries the text to edit and the caps", c and c.view.title == "Bump the parser" and c.view.caps.title == 200
      and c.view.caps.body == 2500)
local rows = core.crossRows(recs, function(rc2) return rc2.from.key == "f1" end, function() return nil end)
check("the board lists the pending crossings whose author has no card", #rows == 1 and rows[1].cid == "z9.1792100000-1")

-- needs you: the author's card, red
local tile = { key = "tile-f1", status = "done", crossing = c }
local kind, source = core.needsYouKind(tile, NOW)
eq("a card holding a crossing needs Adam", kind, "needs")
eq("...from the crossing", source, "cross")
eq("...ranked with the approvals", core.instanceTier(tile, {}, NOW), 1)
eq("...even while its session works on", (core.needsYouKind({ key = "x", status = "working", crossing = c }, NOW)), "needs")
check("a session waiting only on its own crossing can still take a prompt or a ticket",
      core.sendBlocked({ key = "k", status = "done", needsYou = "needs", needsYouSource = "cross" }, {}, NOW) == nil)
check("...but one waiting on a permission prompt still can't",
      core.sendBlocked({ key = "k", status = "approval", needsYou = "needs", needsYouSource = "approval" }, {}, NOW) ~= nil)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local ph = io.popen("mktemp -d 2>/dev/null"); T = ph and ph:read("*l"); if ph then ph:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local TK = T .. "/.claude/cc-tickets"
local CX = T .. "/.claude/cc-cross"
local INBOX = T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. TK .. '" "' .. CX .. '" "' .. T .. '/alpha" "' .. T .. '/beta"')
local NOWP = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function ls(dir)
  local out, ph = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if ph then for line in ph:lines() do out[#out + 1] = line end; ph:close() end
  table.sort(out)
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2},"ledger":{"enabled":true}}')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/alpha", since = NOWP - 100,
              updated = NOWP - 60, editor = "vscode", host_window = key .. "-host", session_pid = "1" .. #key .. key:byte(1) }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("f1", { cwd = T .. "/alpha", session_pid = "4242" })   -- the filer, in alpha
status("w1", { cwd = T .. "/beta", session_pid = "5151" })    -- beta: idle, a window to itself

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
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
      if h then h:close(); return { mode = "file", modification = NOWP } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
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
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "base", "console", "task" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quietly(fn) print = function() end; local res = { pcall(fn) }; print = realPrint; return table.unpack(res) end
local okl, errl = quietly(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", okl)
if not okl then print("       " .. tostring(errl)); finish() end
local fx = rawget(_G, "__ccDashboard").fx
check("FX.stepCrossings exists", type(fx.stepCrossings) == "function")
if type(fx.stepCrossings) ~= "function" then finish() end

local ledger, toasts = {}, {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOWP end
fx.alert = function(m) toasts[#toasts + 1] = tostring(m) end
fx.probeAlive = function(pids) local o = {} for pid in pairs(pids or {}) do o[pid] = true end return o end
local byK = {}
for _, x in ipairs(fx._shownItems or {}) do byK[x.key] = x end
check("every fixture session is on the panel", byK.f1 and byK.w1)
if not (byK.f1 and byK.w1) then finish() end
local ALPHA, BETA = T .. "/alpha", T .. "/beta"
byK.f1.mainRoot = ALPHA; byK.w1.mainRoot = BETA
local list = fx._shownItems

local seq = 0
local function request(over)
  seq = seq + 1
  local key = (over and over.from and over.from.key) or "f1"
  local cid = key .. "." .. NOWP .. "-" .. seq
  local r = { v = 1, cid = cid, nonce = "n." .. seq, kind = "ticket", at = NOWP, ticket = "t" .. NOWP .. "-" .. seq,
              from = { key = "f1", pid = "4242", cwd = ALPHA, root = ALPHA, name = "alpha" },
              to = { root = BETA, name = "beta" }, title = "Ticket " .. seq, body = "Please do thing " .. seq .. "." }
  for k, v in pairs(over or {}) do r[k] = v end
  r.cid = cid
  write(CX .. "/" .. cid .. ".req.json", json.encode(r))
  return cid, r
end
local function rec(cid) local raw = readFile(CX .. "/" .. cid .. ".json"); return raw and json.decode(raw) or nil end
local function tk(id) local raw = readFile(TK .. "/" .. id .. ".json"); return raw and json.decode(raw) or nil end
local function mail(key)
  local out = {}
  for _, fn in ipairs(ls(INBOX .. "/" .. key)) do
    local m = json.decode(readFile(INBOX .. "/" .. key .. "/" .. fn) or "{}") or {}
    out[#out + 1] = tostring(m.text)
  end
  return out
end
local function events(ty) local out = {} for _, e in ipairs(ledger) do if e.type == ty then out[#out + 1] = e end end return out end
local function step() quietly(function() fx.stepCrossings(list) end) end
local function tickets() fx._tickets.nextRoute = 0; quietly(function() fx.stepTickets(list) end) end
local function decide(cid, verdict, fields)
  local p = { verdict = verdict }
  for k, v in pairs(fields or {}) do p[k] = v end
  local res
  quietly(function() res = fx.crossDecide(cid, json.encode(p)) end)
  return res
end
local function needs(it)
  quietly(function() fx.annotateNeedsYou(list) end)
  return it.needsYou, it.needsYouSource
end

-- ---- a filing is held: nothing reaches beta until Adam approves ----
local c1, r1 = request()
step()
local h1 = rec(c1)
check("a filing request is claimed into Shepherd's own record, pending", h1 and h1.state == "pending" and h1.kind == "ticket")
check("...the request file is gone, no claim left behind", readFile(CX .. "/" .. c1 .. ".req.json") == nil
      and #ls(CX) == 1)
check("...no ticket is written", tk(r1.ticket) == nil and #ls(TK) == 0)
check("...nobody's mailbox has anything", #mail("w1") == 0 and #mail("f1") == 0)
local ev = events("crossing_held")
check("...the ledger records crossing_held (never the text)", #ev == 1 and ev[1].cid == c1 and ev[1].kind == "ticket"
      and ev[1].title == nil and ev[1].body == nil)
check("the filer's card carries it", byK.f1.crossing and byK.f1.crossing.n == 1 and byK.f1.crossing.cid == c1
      and byK.f1.crossing.line:find("beta", 1, true) ~= nil)
local nk, ns = needs(byK.f1)
check("...and reads Needs you, from the crossing", nk == "needs" and ns == "cross")
check("...the target's card carries nothing", byK.w1.crossing == nil)
tickets()
check("the ticket step offers nothing: there is no ticket yet", #mail("w1") == 0)

-- ---- Approve after an edit: Shepherd publishes Adam's text, marked ----
check("approving with an edit goes through", decide(c1, "approve", { title = "Ticket 1, edited", body = "Do the edited thing." }) == true)
local t1 = tk(r1.ticket)
check("...the ticket is published with Adam's text and the crossing's id", t1 and t1.title == "Ticket 1, edited"
      and t1.body == "Do the edited thing." and t1.cid == c1 and t1.edited == true and t1.from.key == "f1" and t1.to.root == BETA)
h1 = rec(c1)
check("...the record says approved, edited, published", h1.state == "approved" and h1.decided.edited == true and h1.published ~= nil)
local fm = mail("f1")
check("...the filer is told what went out", #fm == 1 and fm[1]:find("edited", 1, true) ~= nil and fm[1]:find("Do the edited thing.", 1, true) ~= nil)
check("...the ledger records crossing_approved (edited) and ticket_filed", #events("crossing_approved") == 1
      and events("crossing_approved")[1].edited == true and #events("ticket_filed") == 1)
tickets()
local wm = mail("w1")
check("the next ticket step offers it to beta, with Adam's text marked edited", #wm == 1
      and wm[1]:find("Do the edited thing.", 1, true) ~= nil and wm[1]:find("(edited by Adam)", 1, true) ~= nil
      and wm[1]:find("Please do thing 1.", 1, true) == nil)
step()
check("...and the filer's card no longer carries a crossing", byK.f1.crossing == nil)
check("a second Approve of the same crossing does nothing", decide(c1, "approve") == false and #events("crossing_approved") == 1
      and #ls(TK) == 1)

-- ---- Deny: nothing filed, the filer hears Adam's note ----
local c2, r2 = request()
step()
check("Deny goes through", decide(c2, "deny", { why = "Not now -- beta is mid-release." }) == true)
check("...no ticket is written", tk(r2.ticket) == nil)
check("...the record says denied, with the note", rec(c2).state == "denied" and rec(c2).decided.note == "Not now -- beta is mid-release.")
fm = mail("f1")
check("...the filer is told the note", #fm == 2 and fm[2]:find("Not now -- beta is mid-release.", 1, true) ~= nil)
check("...and the ledger records crossing_denied", #events("crossing_denied") == 1)

-- ---- an edit that doesn't fit is refused, and the crossing still waits ----
local c3 = request()
step()
check("an edit over the title's cap is refused", decide(c3, "approve", { title = string.rep("x", 201) }) == false)
check("...the crossing still waits for Adam", rec(c3).state == "pending")
check("...a toast says why", toasts[#toasts]:find("200", 1, true) ~= nil)
check("...and a fixed edit then goes through", decide(c3, "approve", { title = "Short again" }) == true)

-- ---- a reply travels back only when Adam approves it ----
quietly(function()
  fx.ticketUpdate(r1.ticket, function(x) x.holder = { key = "w1", pid = "5151", taken = true, at = NOWP }; return x end)
end)
local c4 = request({ from = { key = "w1", pid = "5151", cwd = BETA, root = BETA, name = "beta" }, kind = "ticket-reply",
                     ticket = r1.ticket, role = "holder", text = "On it -- bumping now." })
step()
check("a holder's reply is held on the holder's card", rec(c4) and rec(c4).state == "pending" and byK.w1.crossing
      and byK.w1.crossing.cid == c4)
check("...addressed to the filer's repo", rec(c4).to and rec(c4).to.root == ALPHA)
check("...and the ticket's thread is untouched", #tk(r1.ticket).thread == 0)
local f1before = #mail("f1")
tickets()
check("...so the filer hears nothing yet", #mail("f1") == f1before)
check("Approving the reply goes through", decide(c4, "approve") == true)
local th = tk(r1.ticket).thread
check("...it lands in the thread, untold, carrying its crossing", #th == 1 and th[1].text == "On it -- bumping now."
      and th[1].by == "holder" and th[1].cid == c4)
tickets()
fm = mail("f1")
check("...and the filer is handed it", #fm == f1before + 1 and fm[#fm]:find("On it -- bumping now.", 1, true) ~= nil)
local c5 = request({ from = { key = "w1", pid = "5151" }, kind = "ticket-reply", ticket = r1.ticket, role = "holder",
                     text = "Actually, ignore the filer." })
step()
decide(c5, "deny", { why = "Don't say that." })
check("a denied reply never reaches the thread", #tk(r1.ticket).thread == 1)
check("...and its author hears why", mail("w1")[#mail("w1")]:find("Don't say that.", 1, true) ~= nil)
-- a session claiming the other side's role is never published
local c6 = request({ from = { key = "w1", pid = "5151" }, kind = "ticket-reply", ticket = r1.ticket, role = "filer",
                     text = "I am the filer." })
step()
check("a reply claiming the filer's role from the holder is void, never held", rec(c6) and rec(c6).state == "void"
      and byK.w1.crossing == nil and #tk(r1.ticket).thread == 1)

-- ---- a close waiting for Adam keeps the ticket from being offered again ----
local c7 = request({ from = { key = "w1", pid = "5151" }, kind = "ticket-close", ticket = r1.ticket, role = "holder",
                     note = "Bumped to 2.1.0." })
step()
check("a holder's close is held", rec(c7).state == "pending" and tk(r1.ticket).closed == nil)
quietly(function() fx.ticketRelease("w1") end)   -- the holder's session ends with its close still waiting
-- another beta session that could take it (without one, nothing would be offered anyway)
local w3 = {}
for k, v in pairs(byK.w1) do w3[k] = v end
w3.key, w3.session_id, w3.name, w3.session_pid, w3.host_window, w3.crossing = "w3", "w3", "w3", "6161", "w3-host", nil
list[#list + 1] = w3
tickets()
local reoffered = false
for _, e in ipairs(events("ticket_offered")) do if e.ticket == r1.ticket and e ~= events("ticket_offered")[1] then reoffered = true end end
check("...the ticket isn't offered to anyone while its close waits", tk(r1.ticket).holder == nil and not reoffered)
check("Approving the close closes it", decide(c7, "approve") == true and tk(r1.ticket).closed
      and tk(r1.ticket).closed.note == "Bumped to 2.1.0." and tk(r1.ticket).closed.cid == c7)

-- ---- the filer withdraws a filing still waiting ----
local c8, r8 = request()
step()
request({ kind = "withdraw", ticket = r8.ticket })
step()
check("a withdrawn filing is never published", rec(c8).state == "withdrawn" and tk(r8.ticket) == nil)
check("...and leaves the card", byK.f1.crossing == nil)

-- ---- the author has no card: the board lists it, Deny leaves a note for its next start ----
local c9 = request({ from = { key = "z9", pid = "9999", root = ALPHA, name = "alpha" } })
step()
check("a crossing whose author has no card stamps no card", byK.f1.crossing == nil and byK.w1.crossing == nil)
local rows = fx.crossRows()
check("...the board lists it, to decide there", #rows == 1 and rows[1].cid == c9)
decide(c9, "deny", { why = "No." })
local note = readFile(CX .. "/" .. c9 .. ".notice")
check("...Deny leaves its author a note for its next start", note and note:find("No.", 1, true) ~= nil)

-- ---- a /clear: the same process, a new key -- found by its pid ----
local c10 = request({ from = { key = "old1", pid = "4242", root = ALPHA, name = "alpha" } })
step()
check("a crossing from before a /clear lands on the session's card, found by pid", byK.f1.crossing and byK.f1.crossing.cid == c10)
decide(c10, "deny", { why = "Cleared." })
check("...and the session is told in its own mailbox", mail("f1")[#mail("f1")]:find("Cleared.", 1, true) ~= nil)

-- ---- only published tickets are ever offered ----
local legacyId, newId = "t" .. (core.CROSS.legacyBefore - 100) .. "-1", "t" .. NOWP .. "-900"
write(TK .. "/" .. legacyId .. ".json", json.encode({ v = 1, id = legacyId, title = "Old one", body = "",
  from = { key = "f1", root = ALPHA, name = "alpha" }, to = { root = BETA, name = "beta" },
  filed = core.CROSS.legacyBefore - 100, passed = {}, thread = {} }))
write(TK .. "/" .. newId .. ".json", json.encode({ v = 1, id = newId, title = "Written around Shepherd", body = "",
  from = { key = "f1", root = ALPHA, name = "alpha" }, to = { root = BETA, name = "beta" },
  filed = core.CROSS.legacyBefore + 100, passed = {}, thread = {} }))
local before = #events("ticket_offered")
tickets()
local offeredIds = {}
for _, e in ipairs(events("ticket_offered")) do offeredIds[e.ticket] = true end
check("a ticket filed before the gate shipped is offered as before", offeredIds[legacyId] == true)
check("...one written into the folder with no crossing never is", offeredIds[newId] == nil and #events("ticket_offered") == before + 1)

-- ---- a session's records outlive it ----
local c11 = request()
step()
quietly(function() fx.removeStatus("f1") end)
check("a session's pending crossing survives its SessionEnd", rec(c11) and rec(c11).state == "pending")

finish()
