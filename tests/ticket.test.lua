-- ticket.test.lua : BEHAVIORAL fixture for cross-repo tickets, Shepherd's side (2026-09-29, build
-- program unit 29). A session files work for ANOTHER repo with cc-ticket.sh (tests/ticket.test.sh):
-- ~/.claude/cc-tickets/<id>.json. Each tick Shepherd offers every open ticket to the target repo's
-- least-busy live session -- core.ticketCandidates, built on unit 30's core.sendCandidates (never
-- the filer, never one waiting on Adam, never one that let the ticket lapse), fewest tickets first,
-- then idle before busy -- claiming the ticket file with a rename before it hands the ticket over
-- through FX.deliverTo (the mailbox; never typed straight into a window). An offer nobody took in 45
-- minutes, or one whose holder's session is gone, is reclaimed and offered again. With no session
-- to take it, the ticket shows on the target repo's card and the board with "Open a tab for it".
-- Replies and the close go back the same way to the other side. Loads the real claude-dashboard.lua
-- under a stubbed hs, like tests/send.test.lua. Side-effect-free: HOME and every dir are a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- ticket.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.ticketCandidates exists", type(core.ticketCandidates) == "function")
if type(core.ticketCandidates) ~= "function" then finish() end

local NOW = 1790000000
local function ticket(over)
  local t = { v = 1, id = "t1790000000-1", title = "Bump the parser", body = "alpha needs parser 2.x.",
              from = { key = "f1", root = "/r/alpha", cwd = "/r/alpha", name = "alpha" },
              to = { root = "/r/beta", name = "beta" }, filed = NOW, passed = {},
              thread = {}, closed = nil }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end

-- ids and file names
check("a ticket id is t<epoch>-<n>", core.ticketIdOk("t1790000000-4242") and not core.ticketIdOk("../x")
      and not core.ticketIdOk("t1-") and not core.ticketIdOk("1790000000-1"))
local fo = core.ticketFileOf("t1790000000-1.json")
check("a ticket's file is <id>.json", fo and fo.id == "t1790000000-1" and fo.kind == "json")
fo = core.ticketFileOf("t1790000000-1.json.claim.shepherd")
check("...a writer's claim of it is a claim", fo and fo.id == "t1790000000-1" and fo.kind == "claim")
fo = core.ticketFileOf("t1790000000-1.json.tmp.77")
check("...its temp a temp", fo and fo.kind == "tmp")
check("...anything else isn't a ticket's", core.ticketFileOf("notes.txt") == nil and core.ticketFileOf("x.json") == nil)

-- parsing: a body that names another id, or no target, is refused
local raw = json.encode(ticket())
local t = core.parseTicket(raw, "t1790000000-1")
check("a ticket is read back", t and t.title == "Bump the parser" and t.to.root == "/r/beta" and t.from.key == "f1")
check("...a body naming another id is refused", core.parseTicket(raw, "t1790000000-2") == nil)
check("...torn JSON is refused", core.parseTicket('{"v":1,"id":"t17', "t1790000000-1") == nil)
check("...one with no target root is refused",
      core.parseTicket(json.encode(ticket({ to = { name = "beta" } })), "t1790000000-1") == nil)

-- phases
check("no holder: open", core.ticketPhase(ticket(), NOW) == "open")
check("offered, not taken yet: offered",
      core.ticketPhase(ticket({ holder = { key = "w1", at = NOW, taken = false } }), NOW + 60) == "offered")
check("...45 minutes on and never taken: lapsed",
      core.ticketPhase(ticket({ holder = { key = "w1", at = NOW, taken = false } }), NOW + core.TICKET.lapseSeconds) == "lapsed")
check("the lapse is 45 minutes", core.TICKET.lapseSeconds == 45 * 60)
check("taken: held, however long ago",
      core.ticketPhase(ticket({ holder = { key = "w1", at = NOW, taken = true } }), NOW + 86400) == "held")
check("closed wins over everything",
      core.ticketPhase(ticket({ holder = { key = "w1", at = NOW, taken = true }, closed = { by = "holder", note = "done", at = NOW } }), NOW) == "closed")

-- routing: the least-busy live session of the target repo
local function tile(key, over)
  local x = { key = key, session_id = key, name = key, status = "done", updated = 100, editor = "vscode", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do x[k] = v end
  return x
end
local fleet = {
  tile("f1", { mainRoot = "/r/alpha", cwd = "/r/alpha" }),                                   -- the filer
  tile("w-idle", { mainRoot = "/r/beta", cwd = "/r/beta", updated = 100 }),
  tile("w-idle2", { mainRoot = "/r/beta", cwd = "/r/beta/.claude/worktrees/x", updated = 50 }),
  tile("w-busy", { mainRoot = "/r/beta", cwd = "/r/beta/wt", status = "working", updated = 900 }),
  tile("w-ask", { mainRoot = "/r/beta", cwd = "/r/beta", status = "approval", needsYou = "needs", needsYouSource = "ask" }),
  tile("g1", { mainRoot = "/r/gamma", cwd = "/r/gamma" }),
  tile("plain", { cwd = "/r/plain" }),                                                        -- not a git repo
}
local function keys(list) local o = {} for _, x in ipairs(list) do o[#o + 1] = x.key end return table.concat(o, ",") end
local c = core.ticketCandidates(fleet, ticket(), {}, NOW)
check("candidates: the target repo's live sessions, idle first, the most recent first  (" .. keys(c) .. ")",
      keys(c) == "w-idle,w-idle2,w-busy")
c = core.ticketCandidates(fleet, ticket(), { ["w-idle"] = 1 }, NOW)
check("...least busy first: a session already holding a ticket goes after one holding none  (" .. keys(c) .. ")",
      keys(c) == "w-idle2,w-busy,w-idle")
c = core.ticketCandidates(fleet, ticket({ passed = { "w-idle" } }), {}, NOW)
check("...never one that let this ticket lapse  (" .. keys(c) .. ")", keys(c) == "w-idle2,w-busy")
c = core.ticketCandidates(fleet, ticket({ to = { root = "/r/alpha" } }), {}, NOW)
check("...never the filer, even in its own repo", keys(c) == "")
c = core.ticketCandidates(fleet, ticket({ to = { root = "/r/plain" } }), {}, NOW)
check("...a folder that isn't a git repo matches its sessions by folder", keys(c) == "plain")
check("...a session waiting on Adam is never one", not keys(core.ticketCandidates(fleet, ticket(), {}, NOW)):find("w-ask", 1, true))
check("...and a repo with nobody live has none", #core.ticketCandidates(fleet, ticket({ to = { root = "/r/none" } }), {}, NOW) == 0)

local tickets = {
  ticket({ id = "t1-1", holder = { key = "w-idle", at = NOW, taken = false } }),
  ticket({ id = "t1-2", holder = { key = "w-idle", at = NOW - core.TICKET.lapseSeconds - 1, taken = false } }),
  ticket({ id = "t1-3", holder = { key = "w-busy", at = NOW, taken = true }, closed = { by = "holder", note = "x", at = NOW } }),
  ticket({ id = "t1-4", holder = { key = "w-busy", at = NOW - 99999, taken = true } }),
}
local held = core.ticketHeldCounts(tickets, NOW)
check("held counts: an offer and a taken ticket count, a lapsed or closed one doesn't",
      held["w-idle"] == 1 and held["w-busy"] == 1)

-- reclaim: lapsed, or its holder's session is gone
local function live(key) return key == "w-idle" or key == "w-busy" end
check("reclaim: an offer untaken for 45 minutes is lapsed",
      core.ticketReclaim(tickets[2], NOW, live) == "lapsed")
check("...a fresh offer isn't reclaimed", core.ticketReclaim(tickets[1], NOW, live) == nil)
check("...a held ticket whose holder's session is gone is",
      core.ticketReclaim(ticket({ holder = { key = "ghost", at = NOW, taken = true } }), NOW, live) == "gone")
check("...a holder found by its pid after a /clear isn't gone",
      core.ticketReclaim(ticket({ holder = { key = "old-key", pid = "4242", at = NOW, taken = true } }), NOW,
        function(_, pid) return pid == "4242" end) == nil)
check("...a closed ticket never is", core.ticketReclaim(tickets[3], NOW, function() return false end) == nil)

-- what the target session is handed
local offer = core.ticketOfferText(ticket(), "claude-instance-manager-60")
check("the offer is marked [shepherd]", offer:sub(1, 11) == "[shepherd] ")
check("...names the ticket, the filer and its repo",
      offer:find("t1790000000-1", 1, true) and offer:find("claude-instance-manager-60", 1, true) and offer:find("alpha", 1, true))
check("...carries the title and body", offer:find("Bump the parser", 1, true) and offer:find("alpha needs parser 2.x.", 1, true))
check("...and says how to take, reply and close it -- within 45 minutes",
      offer:find("cc-ticket.sh take t1790000000-1", 1, true) and offer:find("cc-ticket.sh reply", 1, true)
      and offer:find("--note", 1, true) and offer:find("45 minutes", 1, true))
check("...never as a slash command", not core.mailboxSlash(offer))
check("...and fits the mailbox uncut", #core.ticketOfferText(ticket({ body = string.rep("x", core.TICKET.bodyMax),
      title = string.rep("y", core.TICKET.titleMax) }), string.rep("n", 80)) <= core.MAILBOX_MAX)

-- news: what each side hasn't been told
local tn = ticket({ holder = { key = "w1", at = NOW, taken = true }, thread = {
  { by = "holder", key = "w1", text = "On it.", at = NOW + 1, told = false },
  { by = "filer", key = "f1", text = "2.1 please.", at = NOW + 2, told = false },
  { by = "holder", key = "w1", text = "Old news.", at = NOW + 3, told = "wait" },
}, closed = { by = "holder", key = "w1", note = "Tagged v2.1.0.", at = NOW + 4, told = false } })
local news = core.ticketNews(tn, "filer")
check("news for the filer: the holder's untold replies and its close", news and #news.entries == 1
      and news.entries[1].text == "On it." and news.close and news.close.note == "Tagged v2.1.0.")
news = core.ticketNews(tn, "holder")
check("news for the holder: the filer's untold replies", news and #news.entries == 1 and news.entries[1].text == "2.1 please." and news.close == nil)
local text = core.ticketNewsText(tn, core.ticketNews(tn, "filer"), "filer", "beta-worker")
check("the news text is [shepherd]-marked, names the ticket and says what came",
      text:sub(1, 11) == "[shepherd] " and text:find("t1790000000-1", 1, true) and text:find("On it.", 1, true)
      and text:find("Tagged v2.1.0.", 1, true) and text:find("beta-worker", 1, true))
core.ticketTell(tn, "filer", "turn-end")
check("telling the filer marks just its news told, by the route it went", tn.thread[1].told == "turn-end"
      and tn.closed.told == "turn-end" and tn.thread[2].told == false and core.ticketNews(tn, "filer") == nil)

-- the tab Adam can open for a ticket nobody can take
local p = core.ticketTabPrompt(ticket())
check("the tab's prompt takes the ticket by id and says to close it with a note",
      p:find("cc-ticket.sh take t1790000000-1", 1, true) ~= nil and p:find("--note", 1, true) ~= nil)

-- the board's rows
local rows = core.ticketRows({ ticket({ id = "t1-9" }), tickets[1], tickets[3] }, NOW, { ["t1-9"] = true },
  function(key) return key == "w-idle" and "beta worker" or nil end)
check("board rows: one per ticket", #rows == 3)
check("...a ticket no session can take comes first, with Open a tab for it", rows[1].id == "t1-9" and rows[1].phase == "waiting" and rows[1].canTab == true)
check("...an offered one names who it's offered to", rows[2].phase == "offered" and rows[2].holder == "beta worker")
check("...a closed one last, with its note", rows[3].phase == "closed" and rows[3].note == "x" and not rows[3].canTab)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local ph = io.popen("mktemp -d 2>/dev/null"); T = ph and ph:read("*l"); if ph then ph:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local TK = T .. "/.claude/cc-tickets"
local INBOX = T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. TK .. '" "' .. T .. '/alpha" "' .. T .. '/beta" "' .. T .. '/gamma" "' .. T .. '/wt"')
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
              updated = NOWP - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("f1", { cwd = T .. "/alpha" })                                        -- the filer, in alpha
status("w1", { cwd = T .. "/beta" })                                         -- beta: idle, a window to itself
status("w2", { cwd = T .. "/wt", status = "working", updated = NOWP - 1 })   -- beta: a worktree, mid-turn
status("g1", { cwd = T .. "/gamma", status = "approval" })                   -- gamma: waiting on Adam

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
local function quietly(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quietly(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
check("FX.stepTickets exists", type(fx.stepTickets) == "function")
if type(fx.stepTickets) ~= "function" then finish() end

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOWP end
local alive = {}
fx.probeAlive = function(pids) local o = {} for pid in pairs(pids or {}) do o[pid] = alive[pid] end return o end
local byK = {}
for _, x in ipairs(fx._shownItems or {}) do byK[x.key] = x end
check("every fixture session is on the panel", byK.f1 and byK.w1 and byK.w2 and byK.g1)
if not (byK.f1 and byK.w1 and byK.w2 and byK.g1) then finish() end
-- the repos, as Shepherd's git identity stamps them
local ALPHA, BETA, GAMMA = T .. "/alpha", T .. "/beta", T .. "/gamma"
byK.f1.mainRoot = ALPHA; byK.w1.mainRoot = BETA; byK.w2.mainRoot = BETA; byK.g1.mainRoot = GAMMA
byK.g1.needsYou, byK.g1.needsYouSource = "needs", "approval"
local list = fx._shownItems

local seq = 0
local function file(over)
  seq = seq + 1
  local tk = { v = 1, id = "t" .. NOWP .. "-" .. seq, title = "Ticket " .. seq, body = "Please do thing " .. seq .. ".",
               from = { key = "f1", root = ALPHA, cwd = ALPHA, name = "alpha" }, to = { root = BETA, name = "beta" },
               filed = NOWP, passed = {}, thread = {} }
  for k, v in pairs(over or {}) do tk[k] = v end
  write(TK .. "/" .. tk.id .. ".json", json.encode(tk))
  return tk.id
end
local function load(id) local r = readFile(TK .. "/" .. id .. ".json"); return r and json.decode(r) or nil end
local function mail(key)
  local out = {}
  for _, fn in ipairs(ls(INBOX .. "/" .. key)) do
    local m = json.decode(readFile(INBOX .. "/" .. key .. "/" .. fn) or "{}") or {}
    out[#out + 1] = tostring(m.text)
  end
  return out
end
local function events(ty) local out = {} for _, e in ipairs(ledger) do if e.type == ty then out[#out + 1] = e end end return out end
local function step() fx._tickets.nextRoute = 0; quietly(function() fx.stepTickets(list) end) end

-- an open ticket for beta: offered to its idle session through the mailbox
local id1 = file()
step()
local t1 = load(id1)
check("an open ticket is offered to the target repo's idle session", t1 and t1.holder and t1.holder.key == "w1")
check("...not taken yet: the session takes it itself", t1 and t1.holder and t1.holder.taken == false)
check("...the offer's time is recorded (its 45 minutes run from it)", t1 and t1.holder and t1.holder.at == NOWP)
local m = mail("w1")
check("...handed over through w1's mailbox, [shepherd]-marked, carrying the ticket",
      #m == 1 and m[1]:sub(1, 11) == "[shepherd] " and m[1]:find(id1, 1, true) ~= nil and m[1]:find("Please do thing 1.", 1, true) ~= nil)
check("...never the filer's", #mail("f1") == 0)
check("the ticket file is whole again: no claim or temp left", #ls(TK) == 1)
local ev = events("ticket_offered")
check("the ledger records ticket_offered: the ticket, the session, the route",
      #ev == 1 and ev[1].ticket == id1 and ev[1].key == "w1" and ev[1].route ~= nil)
step()
check("a second tick doesn't offer it again", #mail("w1") == 1 and #events("ticket_offered") == 1)

-- a second ticket: w1 holds one now, so the busy-but-free w2 is the least busy
local id2 = file()
step()
check("least busy: the next ticket goes to the session holding none", load(id2).holder.key == "w2")

-- no one can take it: gamma's only session is waiting on Adam
local id3 = file({ to = { root = GAMMA, name = "gamma" } })
step()
check("a ticket whose repo has no session that can take it stays open", load(id3).holder == nil)
check("...it shows on that repo's card, with how many wait", byK.g1.tickets and byK.g1.tickets.waiting == 1 and byK.g1.tickets.id == id3)
check("...and on no other card", byK.w1.tickets == nil and byK.f1.tickets == nil)
local rows = fx.ticketRows()
local r3
for _, r in ipairs(rows) do if r.id == id3 then r3 = r end end
check("...and on the board, waiting, with Open a tab for it", r3 and r3.phase == "waiting" and r3.canTab == true)

-- Open a tab for it: a new tab in that repo, its prompt taking the ticket
local opened
fx.openClaudeTab = function(opts) opened = opts; return true end
quietly(function() fx.openTicketTab(id3) end)
check("Open a tab for it opens a Claude tab in the target repo", opened and opened.root == GAMMA)
check("...its prompt takes the ticket (typed, never sent)", opened and tostring(opened.prompt):find("cc-ticket.sh take " .. id3, 1, true) ~= nil)
check("...and the ticket records it, so routing leaves it to that tab a while", type(load(id3).tabAt) == "number")
opened = nil
quietly(function() fx.openTicketTab(id1) end)
check("...a ticket someone holds gets no tab", opened == nil)
quietly(function() fx.openTicketTab("../../etc/passwd") end)
check("...nor does an id that isn't one", opened == nil)

-- reclaim: an offer untaken for 45 minutes goes to another session, and not back to the first
local id4 = file({ holder = { key = "w1", at = NOWP - core.TICKET.lapseSeconds - 5, taken = false } })
step()
local t4 = load(id4)
check("an offer untaken for 45 minutes is reclaimed and offered to another session", t4.holder and t4.holder.key == "w2")
check("...passing over the one that let it lapse", t4.passed and t4.passed[1] == "w1")
check("...ledgered as ticket_reclaimed (lapsed)", #events("ticket_reclaimed") == 1 and events("ticket_reclaimed")[1].why == "lapsed")
-- ...and its holder's session is gone: back to open, offered again
local id5 = file({ holder = { key = "ghost", at = NOWP - 30, taken = true } })
step()
local t5 = load(id5)
check("a ticket whose holder's session is gone is reclaimed and offered again", t5.holder and t5.holder.key ~= "ghost" and t5.holder.taken == false)

-- news: the holder's reply and close go to the live filer, through its mailbox
local id6 = file({ holder = { key = "w1", at = NOWP, taken = true }, thread = {
  { by = "holder", key = "w1", text = "On it.", at = NOWP, told = false } } })
step()
local fm = mail("f1")
check("the holder's reply reaches the live filer through its mailbox", #fm == 1 and fm[1]:find("On it.", 1, true) ~= nil and fm[1]:find(id6, 1, true) ~= nil)
check("...marked told, by the route it went", load(id6).thread[1].told ~= false)
check("...ledgered as ticket_news", #events("ticket_news") == 1 and events("ticket_news")[1].ticket == id6)
step()
check("...once", #mail("f1") == 1)
local t6 = load(id6)
t6.closed = { by = "holder", key = "w1", note = "Tagged v2.1.0.", at = NOWP, told = false }
write(TK .. "/" .. id6 .. ".json", json.encode(t6))
step()
fm = mail("f1")
check("the close reaches the filer with its note", #fm == 2 and fm[2]:find("Tagged v2.1.0.", 1, true) ~= nil)
-- the filer's reply reaches the holder
local w1Before = #mail("w1")
local id7 = file({ holder = { key = "w1", at = NOWP, taken = true }, thread = {
  { by = "filer", key = "f1", text = "2.1 at least, please.", at = NOWP, told = false } } })
step()
check("the filer's reply reaches the holder", #mail("w1") == w1Before + 1 and mail("w1")[#mail("w1")]:find("2.1 at least", 1, true) ~= nil)
-- a filer running `cc-ticket.sh wait` gets it from the waiter, not the mailbox
local id8 = file({ holder = { key = "w1", at = NOWP, taken = true }, waiting = { filer = { pid = "777", at = NOWP } },
                   thread = { { by = "holder", key = "w1", text = "For the waiter.", at = NOWP, told = false } } })
alive["777"] = true
step()
check("a live waiter takes the news itself: no mailbox copy", #mail("f1") == 2 and load(id8).thread[1].told == false)
alive["777"] = false
step()
check("...a waiter that died leaves it to the mailbox", #mail("f1") == 3 and load(id8).thread[1].told ~= false)
-- a filer that isn't live: its next start takes it
local id9 = file({ from = { key = "gone-filer", root = ALPHA, cwd = ALPHA, name = "alpha" },
                   holder = { key = "w1", at = NOWP, taken = true },
                   thread = { { by = "holder", key = "w1", text = "Nobody home.", at = NOWP, told = false } } })
step()
check("news for a filer that isn't live waits for its next start", load(id9).thread[1].told == false)

-- a ticket the CLI has claimed this instant is left for the next tick, never overwritten
local idA = file()
os.rename(TK .. "/" .. idA .. ".json", TK .. "/" .. idA .. ".json.claim.4242")
step()
check("a ticket claimed by another writer is left alone this tick", readFile(TK .. "/" .. idA .. ".json.claim.4242") ~= nil
      and readFile(TK .. "/" .. idA .. ".json") == nil)
os.rename(TK .. "/" .. idA .. ".json.claim.4242", TK .. "/" .. idA .. ".json")

-- the removers: an ended session's tickets go back
quietly(function() fx.removeStatus("w2") end)
local t2 = load(id2)
check("FX.removeStatus puts back the tickets the ended session held", t2.holder == nil)
check("...passing it over from now on", t2.passed and t2.passed[1] == "w2")
check("...and leaves the tickets the filer filed alone", load(id9) ~= nil)
quietly(function() fx.removeStatus("..") end)
check("...never reaching outside the folder", #ls(T .. "/status") > 0)

-- the board goes to the panel
check("FX.pushTickets exists (ccTickets(rows) to the panel)", type(fx.pushTickets) == "function")

os.execute('rm -r "' .. T .. '"')
finish()
