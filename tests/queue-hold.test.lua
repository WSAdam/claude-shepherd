-- queue-hold.test.lua : held queue lines and the fleet-wide Queue view (2026-10-03, mining round 2
-- unit D4b).
-- A queued line can be held: auto-feed, Feed next and the router skip it (core.queuePeek /
-- core.queuePop take the first line that isn't held), and it keeps its place. The flag rides WITH
-- the line in the queue file -- a held line is { "text": ..., "held": true }, every other line stays
-- a plain string -- so a queue with nothing held keeps the old file shape, and an old file reads as
-- it always did. ☰ → Queues lists every ~/.claude/cc-queue/*.json: whose it is, each line, held or
-- not, and an @packet line's last drift check (read-only: the check itself runs only at feed time).
-- Part 1 drives the pure functions. Part 2 loads the shipped FX Queue-view block over a temp
-- cc-queue/ with real files. Side-effect-free: every file lives in a temp dir.

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
local function finish() print("-- queue-hold.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
-- a line as written to the file, key order fixed (the JSON encoder's isn't): "a" | {held=true,text=a}
local function shape(x)
  if type(x) ~= "table" then return tostring(x) end
  local keys = {}
  for k in pairs(x) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(x[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function shapes(list)
  local out = {}
  for _, x in ipairs(list or {}) do out[#out + 1] = shape(x) end
  return table.concat(out, " ")
end
local function texts(q)
  local out = {}
  for _, l in ipairs(core.queueLines(q)) do out[#out + 1] = l.text .. (l.held and "*" or "") end
  return table.concat(out, ",")
end

-- ============ Part 1: the pure queue functions ============

-- ---- an old queue file, written before lines could be held (2026-10-03) ----
do
  local old = core.json.decode('{"tasks":["a","b","c"],"routing":true,"mode":"sequential"}')
  eq("old file: the head is its first line", core.queuePeek(old), "a")
  eq("old file: every line counts", core.queueDepth(old), 3)
  eq("old file: nothing is held", core.queueHeldCount(old), 0)
  eq("old file: queueLines reads each line, none held", texts(old), "a,b,c")
  local first, rest = core.queuePop(old)
  eq("old file: pop takes the first line", first, "a")
  eq("old file: ...and keeps the rest in order", texts(rest), "b,c")
  check("old file: ...with its routing and mode flags", rest.routing == true and rest.mode == "sequential")
  local moved = core.queueMove(old, 1, 1, "a")
  eq("old file: a rebuild writes plain strings, the old shape", core.json.encode(moved.tasks), '["b","a","c"]')
end

-- ---- hold and release one line (2026-10-03) ----
do
  local q = { tasks = { "a", "b", "c" }, routing = true }
  local q2, ok = core.queueSetHeld(q, 1, true, "a")
  check("hold: the line is held", ok == true)
  eq("hold: the flag rides with the line", shape(q2.tasks[1]), "{held=true,text=a}")
  eq("hold: the other lines stay plain strings", q2.tasks[2], "b")
  check("hold: the queue's flags are kept", q2.routing == true)
  eq("hold: the original is untouched (pure)", q.tasks[1], "a")
  eq("hold: peek skips the held line", core.queuePeek(q2), "b")
  local task, rest = core.queuePop(q2)
  eq("hold: pop feeds the next line that isn't held", task, "b")
  eq("hold: the held line keeps its place", texts(rest), "a*,c")
  eq("hold: depth still counts the held line", core.queueDepth(rest), 2)
  eq("hold: one held", core.queueHeldCount(rest), 1)

  -- round trip through the file
  local back = core.json.decode(core.json.encode(q2))
  eq("round trip: the held flag survives the file", texts(back), "a*,b,c")
  eq("round trip: ...and peek still skips it", core.queuePeek(back), "b")

  local r, okr = core.queueSetHeld(back, 1, false, "a")
  check("release: the line is released", okr == true)
  eq("release: it is a plain string again (the old shape)", r.tasks[1], "a")
  eq("release: it feeds first again", core.queuePeek(r), "a")

  local s, oks = core.queueSetHeld(q2, 2, true, "stale text")
  check("hold: a stale click (the text doesn't match) is refused", oks == false)
  eq("hold: ...and nothing changes", texts(s), "a*,b,c")
  check("hold: out of range is refused", select(2, core.queueSetHeld(q2, 9, true)) == false)
  check("hold: a fractional index is refused", select(2, core.queueSetHeld(q2, 1.5, true)) == false)
  check("hold: a nil queue is refused, canonical shape", select(2, core.queueSetHeld(nil, 1, true)) == false
        and #core.queueSetHeld(nil, 1, true).tasks == 0)
  local same, oksame = core.queueSetHeld(q2, 1, true, "a")
  check("hold: holding a held line again is fine and changes nothing", oksame == true and texts(same) == "a*,b,c")
end

-- ---- every reader skips held lines the same way (2026-10-03) ----
do
  local all = { tasks = { { text = "a", held = true }, { text = "b", held = true } }, routing = true }
  eq("all held: nothing to peek", core.queuePeek(all), nil)
  local none, kept = core.queuePop(all)
  eq("all held: pop returns nothing", none, nil)
  eq("all held: ...and keeps every line", texts(kept), "a*,b*")
  eq("all held: depth still counts them", core.queueDepth(all), 2)
  eq("auto-feed: a done edge feeds nothing when every line is held", core.shouldFeed("working", "done", all, true), false)
  eq("auto-feed: ...but does once a line isn't held", core.shouldFeed("working", "done",
     { tasks = { { text = "a", held = true }, "b" } }, true), true)
  local members = { { key = "m1", status = "done", name = "m1" } }
  eq("router: nothing routed when every line is held", core.routeTask(members, all, { globalOn = true }), nil)
  local pick = core.routeTask(members, { tasks = { { text = "a", held = true }, "b" }, routing = true }, { globalOn = true })
  eq("router: routes the first line that isn't held", pick and pick.key, "m1")
  eq("router: a queue whose every line is held isn't starved", core.queueStarved({}, all,
     { minutes = 1, sinceTs = 0, now = 99999 }), false)
  -- a held @role: head doesn't decide the route: the next line's does
  local roleQ = { tasks = { { text = "@role:review look", held = true }, "plain" }, routing = true }
  eq("router: a held head's @role: doesn't steer the route", (core.routeTask(members, roleQ, { globalOn = true }) or {}).role, nil)
end

-- ---- edits carry the flag with the line (2026-10-03) ----
do
  local q = { tasks = { { text = "a", held = true }, "b", "c" }, mode = "sequential" }
  local m, ok = core.queueMove(q, 1, 1, "a")
  check("move: a held line moves, matched by its text", ok == true)
  eq("move: ...still held in its new place", texts(m), "b,a*,c")
  check("move: ...and the mode is kept", m.mode == "sequential")
  local r, removed = core.queueRemoveAt(q, 1, "a")
  eq("remove: a held line's text comes back", removed, "a")
  eq("remove: the rest stay", texts(r), "b,c")
  eq("push: keeps the held line", texts(core.queuePush(q, "d")), "a*,b,c,d")
  eq("bulk push: keeps the held line", texts(core.queuePushAll(q, { "d", "e" })), "a*,b,c,d,e")
  eq("merge: keeps held lines from both", texts(core.queueMerge(q, { tasks = { { text = "z", held = true } } })), "a*,b,c,z*")
  eq("routing toggle: keeps the held line", texts(core.queueSetRouted(q, true)), "a*,b,c")
  eq("mode toggle: keeps the held line", texts(core.queueSetMode(q, "distribute")), "a*,b,c")
end

-- ---- parsed tolerantly (2026-10-03) ----
do
  local odd = { tasks = { "a", { held = true }, 42, { text = 5 }, { text = "b", held = "yes" }, { text = "c" },
                          { text = "d", held = true, extra = 1 } } }
  eq("tolerant: lines with no text are dropped, a non-true held reads as not held", texts(odd), "a,b,c,d*")
  eq("tolerant: depth counts only real lines", core.queueDepth(odd), 4)
  local _, rest = core.queuePop(odd)
  eq("tolerant: a rebuild writes plain strings and only the held flag", shapes(core.json.decode(core.json.encode(rest)).tasks),
     "b c {held=true,text=d}")
  eq("tolerant: not a table", core.queueDepth("junk"), 0)
end

-- ---- packets: a held @packet line keeps its packet (2026-10-03) ----
do
  local ids = core.packetIdsIn({ { text = "@packet:p3 Fix it", held = true }, "@packet:p4 Other", "plain" })
  check("packets: a held packet line still counts as the queue's", ids.p3 == true and ids.p4 == true)
end

-- ---- the Queue view's pieces (2026-10-03) ----
do
  eq("file key: a queue file", core.queueFileKey("-Users-adam-Programming-x.json"), "-Users-adam-Programming-x")
  eq("file key: a packet store isn't a queue", core.queueFileKey("k.packets.json"), nil)
  eq("file key: a temp write isn't", core.queueFileKey("k.json.tmp.1700000000"), nil)
  eq("file key: a set-aside bad file isn't", core.queueFileKey("k.json.bad.1700000000"), nil)
  eq("file key: dot entries aren't", core.queueFileKey(".json"), nil)
  eq("file key: a name a queue key can't have isn't", core.queueFileKey("a b.json"), nil)
  check("key ok: a sanitized key", core.queueKeyOk("-Users-adam-x_y.z") == true)
  check("key ok: no path, no dots-only, no packet store", not core.queueKeyOk("../x") and not core.queueKeyOk("..")
        and not core.queueKeyOk("") and not core.queueKeyOk(nil) and not core.queueKeyOk("k.packets"))

  local now = 2000
  local pk = { cites = { { label = "src/a.lua:1-3" } }, at = 10 }
  eq("drift: a packet the store doesn't have", core.queueViewPacket("p1", nil, nil, now).state, "missing")
  eq("drift: no cited code", core.queueViewPacket("p1", { cites = {} }, nil, now).state, "nocites")
  eq("drift: not checked yet", core.queueViewPacket("p1", pk, nil, now).state, "unchecked")
  local mv = core.queueViewPacket("p1", pk, { head = "abcdef1234", moved = { { label = "src/a.lua:1-3" } }, at = 1900 }, now)
  eq("drift: moved", mv.state, "moved")
  eq("drift: ...with the card's line", mv.why, "cited code moved: src/a.lua:1-3")
  eq("drift: ...at the commit it was read at", mv.head, "abcdef1")
  eq("drift: ...and how long ago", mv.age, 100)
  eq("drift: unchanged", core.queueViewPacket("p1", pk, { head = "abcdef1234", moved = {}, at = 1990 }, now).state, "unchanged")
  local bad = core.queueViewPacket("p1", pk, { failed = "no such file", at = 1990 }, now)
  check("drift: unreadable, with why", bad.state == "unreadable" and bad.why:find("no such file", 1, true) ~= nil)

  local items = {
    { key = "s1", name = "alpha one", projectKey = "-Users-adam-Programming-alpha" },
    { key = "s2", name = "alpha two", projectKey = "-Users-adam-Programming-alpha" },
    { key = "s3", name = "beta", projectKey = "-Users-adam-Programming-beta" },
  }
  local entries = {
    { qk = "-Users-adam-Programming-beta", q = { tasks = { "b1" } } },
    { qk = "-Users-adam-Programming-alpha", q = { tasks = { { text = "a1", held = true }, "@packet:p2 Fix", "a3" }, routing = true },
      packets = { packets = { p2 = pk } }, verdicts = { p2 = { head = "1234567890", moved = {}, at = 1990 } } },
    { qk = "-Users-adam-Programming-empty", q = { tasks = {} }, },
    { qk = "-Users-adam-Programming-gone", q = { tasks = { "orphan" } } },
    { qk = "-Users-adam-Programming-torn", unreadable = true },
  }
  local rows = core.queueViewRows(entries, items, now)
  eq("view: an empty queue isn't listed", #rows, 4)
  eq("view: sorted by project", rows[1].project .. "|" .. rows[2].project .. "|" .. rows[3].project .. "|" .. rows[4].project,
     "alpha|beta|gone|torn")
  local a = rows[1]
  eq("view: the queue file's key rides along (what a click sends)", a.qk, "-Users-adam-Programming-alpha")
  eq("view: every live session whose queue it is", (a.sessions[1] or {}).name .. "+" .. (a.sessions[2] or {}).name, "alpha one+alpha two")
  eq("view: ...by key", a.sessions[1].key, "s1")
  eq("view: each line with its held state", (a.lines[1].held and "H" or "-") .. (a.lines[2].held and "H" or "-"), "H-")
  eq("view: the line that feeds next skips the held one", a.next, 2)
  eq("view: held count", a.held, 1)
  check("view: the routing flag", a.routed == true and not a.seq)
  eq("view: an @packet line carries its last drift check", a.lines[2].packet and a.lines[2].packet.state, "unchanged")
  eq("view: ...its id", a.lines[2].packet and a.lines[2].packet.id, "p2")
  eq("view: a plain line has none", a.lines[1].packet, nil)
  eq("view: a queue no live session has", #rows[3].sessions, 0)
  check("view: an unreadable queue file is listed as such, with no lines", rows[4].unreadable == true and #rows[4].lines == 0)
  eq("view: every line held -- nothing feeds next", core.queueViewRows({ { qk = "k", q = { tasks = { { text = "x", held = true } } } } }, {}, now)[1].next, nil)
end

-- ============ Part 2: the shipped FX Queue-view block over real files ============
local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local body = src:match("\n(FX%._queueView = .-\nfunction FX%.pushQueueView%(force%).-\nend\n)")
check("the panel ships the Queue-view block (FX._queueView .. FX.pushQueueView)", body ~= nil)
if not body then finish() end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local QD = T .. "/cc-queue"
os.execute('mkdir -p "' .. QD .. '"')
local function readAll(path)
  local h = io.open(path, "r"); if not h then return nil end
  local s = h:read("*a"); h:close(); return s
end
local function writeAll(path, s) local h = assert(io.open(path, "w")); h:write(s); h:close() end
local function readQ(qk) return core.json.decode(readAll(QD .. "/" .. qk .. ".json") or '{"tasks":[]}') end

writeAll(QD .. "/-Users-adam-Programming-alpha.json", core.json.encode({ tasks = { "a1", "@packet:p1 Fix it", "a3" } }))
writeAll(QD .. "/-Users-adam-Programming-alpha.packets.json", core.json.encode({ next = 2, packets = { p1 = { task = "t", at = 5,
           cites = { { path = "src/x.lua", from = 1, to = 1, sha = "fedcba9876", text = "x" } } } } }))
writeAll(QD .. "/-Users-adam-Programming-beta.json", core.json.encode({ tasks = { "b1" } }))
writeAll(QD .. "/-Users-adam-Programming-beta.json.tmp.99", "{torn")
writeAll(QD .. "/-Users-adam-Programming-beta.json.bad.98", "{torn")
writeAll(QD .. "/-Users-adam-Programming-torn.json", "{not json")

local calls = { js = {}, ledger = {}, dropped = {}, alerts = {} }
local NOW = 2000
local FX = {}
FX.now = function() return NOW end
FX.readFile = readAll
FX.readDir = function(dir)
  local out = {}
  local p = io.popen('ls -a "' .. dir .. '" 2>/dev/null')
  for l in p:lines() do out[#out + 1] = l end
  p:close()
  return out
end
FX.readQueue = function(qk) return readQ(qk) end
FX.writeQueue = function(qk, q) writeAll(QD .. "/" .. qk .. ".json", core.json.encode(q)) end
FX.readPackets = function(qk) return core.parsePackets(readAll(QD .. "/" .. core.packetsFileName(qk))) or { packets = {} } end
FX.dropPacket = function(qk, id) calls.dropped[#calls.dropped + 1] = tostring(qk) .. ":" .. tostring(id) end
FX.alert = function(s) calls.alerts[#calls.alerts + 1] = s end
FX._packetVerdicts = { ["/r/alpha\0-Users-adam-Programming-alpha\0p1\0005"] = { head = "fedcba9876", moved = { { label = "x:1" } }, at = 1990 } }
FX.allItems = function() return { { key = "s1", name = "alpha one", projectKey = "-Users-adam-Programming-alpha" } } end
local wv = { evaluateJavaScript = function(_, js) calls.js[#calls.js + 1] = js end }
local env = setmetatable({ FX = FX, core = core, hs = { json = core.json }, QUEUE_DIR = QD, wv = wv,
  ledgerFor = function(it, e) calls.ledger[#calls.ledger + 1] = { key = it and it.key, e = e } end,
  print = function() end }, { __index = _G })
assert(load(body, "=queueview", "t", env))()

local rows = FX.queueViewRows()
eq("view: lists every queue file with lines (the torn one as unreadable), never a packet store, temp or set-aside file", #rows, 3)
eq("view: alpha first", rows[1].qk, "-Users-adam-Programming-alpha")
eq("view: the packet's drift is the verdict the feed check left (read-only)", rows[1].lines[2].packet and rows[1].lines[2].packet.state, "moved")
check("view: reading it ran no check and touched no file", readAll(QD .. "/-Users-adam-Programming-torn.json") == "{not json")

-- hold, from the view
local ok, why = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "hold", idx = 1, task = "a1" })
check("edit: hold a line", ok == true)
eq("edit: ...written to the file, with the line", shapes(readQ("-Users-adam-Programming-alpha").tasks),
   "{held=true,text=a1} @packet:p1 Fix it a3")
eq("edit: ...the ledger says so, on the queue's session", calls.ledger[#calls.ledger] and calls.ledger[#calls.ledger].e.op, "hold")
eq("edit: ...by the queue view", calls.ledger[#calls.ledger] and calls.ledger[#calls.ledger].e.by, "queue view")
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "release", idx = 1, task = "a1" })
eq("edit: release writes the plain line back", ok and readQ("-Users-adam-Programming-alpha").tasks[1], "a1")
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "down", idx = 1, task = "a1" })
eq("edit: move down", ok and texts(readQ("-Users-adam-Programming-alpha")), "@packet:p1 Fix it,a1,a3")
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "up", idx = 2, task = "a1" })
eq("edit: move up", ok and texts(readQ("-Users-adam-Programming-alpha")), "a1,@packet:p1 Fix it,a3")
ok, why = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "hold", idx = 1, task = "stale" })
check("edit: a stale click is refused, and nothing written", ok == false and texts(readQ("-Users-adam-Programming-alpha")) == "a1,@packet:p1 Fix it,a3")
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "remove", idx = 2, task = "@packet:p1 Fix it" })
check("edit: remove", ok == true and texts(readQ("-Users-adam-Programming-alpha")) == "a1,a3")
eq("edit: ...a removed packet line takes its packet", calls.dropped[#calls.dropped], "-Users-adam-Programming-alpha:p1")
local nLedger = #calls.ledger
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-beta", op = "hold", idx = 1, task = "b1" })
check("edit: a queue with no live session can be edited too", ok == true and readQ("-Users-adam-Programming-beta").tasks[1].held == true)
eq("edit: ...with no session to ledger it on, nothing is ledgered", #calls.ledger, nLedger)
ok, why = FX.queueViewEdit({ qk = "../etc/passwd", op = "hold", idx = 1 })
check("edit: a key that isn't a queue key is refused", ok == false and why ~= nil)
ok, why = FX.queueViewEdit({ qk = "-Users-adam-Programming-nope", op = "hold", idx = 1 })
check("edit: a queue that isn't there is refused, and none is created", ok == false
      and readAll(QD .. "/-Users-adam-Programming-nope.json") == nil)
ok = FX.queueViewEdit({ qk = "-Users-adam-Programming-alpha", op = "explode", idx = 1, task = "a1" })
check("edit: an unknown op is refused", ok == false)

-- the push: only while the view is open (or forced right after a click)
calls.js = {}
FX._queueView.open = false
FX.pushQueueView()
eq("push: nothing while the view is closed", #calls.js, 0)
FX._queueView.open = true
FX.pushQueueView()
check("push: the rows go to ccQueues while it's open", #calls.js == 1 and calls.js[1]:find("^ccQueues%(") ~= nil)
os.execute('rm -r "' .. T .. '"')

finish()
