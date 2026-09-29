-- packets.test.lua : BEHAVIORAL fixture for task packets (2026-09-29, build program unit 26).
-- A queued task used to be bare text: whatever evidence it was written against went stale the
-- moment someone committed, and the queue fed it anyway. A packet carries its evidence -- the
-- task, `path:line[-line]` snippets captured with the sha they were read at, repro steps and
-- done-when -- and is not fed while the code it cites has moved. The pure parsing and drift
-- logic in cc-core.lua (over literal before/after files), then the REAL shipped FX packet block
-- (FX._packetVerdicts .. FX.fleetPacketGate), renderFeed and FX.fleetOpenTab, sliced out of
-- claude-dashboard.lua and run against a recorded hs over a real git repo and worktree.
--
-- Usage: lua tests/packets.test.lua [path/to/claude-dashboard.lua]

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want) check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want) end
local function finish() print("-- packets.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function has(s, needle) return type(s) == "string" and s:find(needle, 1, true) ~= nil end
local function readAll(p) local h = io.open(p, "r"); if not h then return nil end; local c = h:read("*a"); h:close(); return c end

local FIX = HERE .. "fixtures/packets/"
local BEFORE = readAll(FIX .. "cited-before.lua")
local MOVED = readAll(FIX .. "cited-after-moved.lua")
local BELOW = readAll(FIX .. "cited-after-below.lua")
check("the literal before/after files are there", BEFORE and MOVED and BELOW)
if not (BEFORE and MOVED and BELOW) then finish() end
local SHA, SHA2 = string.rep("a", 40), string.rep("b", 40)

-- ---- task packets: cites (2026-09-29) ----
do
  local c = core.parseCite("cc-core.lua:120-134")
  eq("cite: a path and a line range", c and (c.path .. ":" .. c.from .. "-" .. c.to), "cc-core.lua:120-134")
  local one = core.parseCite("  src/a b.lua:7  ")
  eq("cite: one line is from = to (trimmed, a space in the path is fine)", one and (one.path .. ":" .. one.from .. "-" .. one.to), "src/a b.lua:7-7")
  for _, bad in ipairs({ "/abs/x.lua:3", "../x.lua:3", "a/../b.lua:3", "x.lua", "x.lua:0", "x.lua:5-3",
                         "x.lua:1-200", "-x.lua:3", "x.lua:3-", "", ":3", "x\1.lua:3", "x.lua:3:4", "a//b.lua:2" }) do
    local got, why = core.parseCite(bad)
    check("cite: '" .. bad:gsub("%c", "?") .. "' is refused, with a reason", got == nil and type(why) == "string" and why ~= "")
  end
  local list = core.parseCites("a.lua:1-3\n\n b.lua:5\r\na.lua:1-3\n")
  eq("cites: one per line, blanks skipped, a repeat kept once", list and #list, 2)
  eq("...in the order given", list and list[2].path, "b.lua")
  local many = {}
  for i = 1, core.PACKET_MAX_CITES + 1 do many[#many + 1] = "f" .. i .. ".lua:1" end
  local none, whyMany = core.parseCites(table.concat(many, "\n"))
  check("cites: more than " .. core.PACKET_MAX_CITES .. " are refused", none == nil and has(whyMany, tostring(core.PACKET_MAX_CITES)))
  local bad, whyBad = core.parseCites("a.lua:1-3\nnope")
  check("cites: one bad line refuses them all, naming it", bad == nil and has(whyBad, "nope"))
  eq("cites: none is an empty list (a packet may carry only repro and done-when)", #(core.parseCites("  \n") or { 1 }), 0)
  eq("cite label: one line", core.citeLabel({ path = "a.lua", from = 5, to = 5 }), "a.lua:5")
  eq("cite label: a range", core.citeLabel({ path = "a.lua", from = 1, to = 3 }), "a.lua:1-3")
end

-- ---- task packets: the queue token (2026-09-29) ----
do
  eq("token: @packet:<id> and a one-line title", core.packetToken("p3", "Fix the depth\nsecond line"), "@packet:p3 Fix the depth second line")
  local id, title = core.packetRef("@packet:p3 Fix the depth")
  eq("ref: the id", id, "p3")
  eq("ref: the title", title, "Fix the depth")
  eq("ref: under a join barrier and a role", core.packetRef("@all: @review: @packet:p12 Fix"), "p12")
  eq("ref: leading space is fine", core.packetRef("  @packet:p4 x"), "p4")
  eq("ref: not an id", core.packetRef("@packet:x3 y"), nil)
  eq("ref: only at the front", core.packetRef("fix @packet:p3"), nil)
  local role, bare = core.taskRoute("@packet:p3 Fix the depth")
  check("routing: @packet: is not an @role: prefix", role == nil and bare == "@packet:p3 Fix the depth")
  local role2, bare2 = core.taskRoute("@review: @packet:p3 Fix")
  check("routing: a role in front of a packet still routes", role2 == "review" and bare2 == "@packet:p3 Fix")
  local ids = core.packetIdsIn({ "@packet:p1 a", "plain", "@review: @packet:p7 b" })
  check("the ids a queue refers to", ids.p1 and ids.p7 and not ids.p2)
end

-- ---- task packets: reading cited code at a sha (2026-09-29) ----
do
  local argv = core.packetReadArgv("/r/main", { { path = "a b.lua", from = 4, to = 6 }, { path = "c.lua", from = 1, to = 1 } })
  eq("read argv: /bin/sh -c with the script", argv[1] .. "|" .. (argv[2] == core.PACKET_READ_SH and "script" or "?"), "-c|script")
  eq("read argv: the root, then path, from, to for each cite, as separate words (no quoting)",
     table.concat(argv, "|", 3), "sh|/r/main|a b.lua|4|6|c.lua|1|1")
  local out = "HEAD " .. SHA .. "\nCITE ok 12\nline1\nline2\nCITE missing 0\n"
  local r = core.parsePacketRead(out, 2)
  eq("read: the sha it read at", r and r.head, SHA)
  eq("read: a cite's lines, exactly", r and r.cites[1].text, "line1\nline2\n")
  eq("read: a path the sha doesn't have", r and r.cites[2].missing, true)
  eq("read: a torn output is nothing", core.parsePacketRead("HEAD " .. SHA .. "\nCITE ok 50\nshort", 1), nil)
  eq("read: fewer cites than asked is nothing", core.parsePacketRead("HEAD " .. SHA .. "\n", 1), nil)
  eq("read: more than asked is nothing", core.parsePacketRead(out, 1), nil)
  eq("read: no HEAD line is nothing", core.parsePacketRead("CITE ok 0\n", 1), nil)
  eq("slice: lines 4-6 of the literal before file", core.packetSlice(BEFORE, 4, 6), "function M.depth(q)\n  return #(q.tasks or {})\nend\n")
  eq("slice: past the end gives what there is", core.packetSlice("a\nb", 2, 5), "b")
  eq("line count: a final line without a newline counts", core.packetLineCount("a\nb"), 2)
  eq("line count: empty", core.packetLineCount(""), 0)
  -- the script, run for real on a throwaway repo: HEAD's sha, then each range, length-prefixed
  local T; do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
  local R = T .. "/repo"
  os.execute(('git init -q "%s" && mkdir -p "%s/src" && cp "%s" "%s/src/cited.lua" && cd "%s" && git add -A && '
    .. 'git -c user.email=t@t -c user.name=t commit -q -m init'):format(R, R, FIX .. "cited-before.lua", R, R))
  local q = {}
  for _, a in ipairs(core.packetReadArgv(R, { { path = "src/cited.lua", from = 4, to = 6 }, { path = "nope.lua", from = 1, to = 1 },
                                            { path = "src", from = 1, to = 1 } })) do
    q[#q + 1] = "'" .. a:gsub("'", "'\\''") .. "'"
  end
  local p = io.popen("/bin/sh " .. table.concat(q, " ") .. " 2>/dev/null")
  local got = p:read("*a"); p:close()
  local rr = core.parsePacketRead(got, 3)
  check("the read script: HEAD's sha", rr and rr.head and #rr.head == 40)
  eq("the read script: the cited lines at that sha", rr and rr.cites[1].text, core.packetSlice(BEFORE, 4, 6))
  eq("the read script: a path that isn't there", rr and rr.cites[2].missing, true)
  eq("the read script: a folder is not a file", rr and rr.cites[3].missing, true)
  os.execute('rm -r "' .. T .. '"')
end

-- ---- task packets: saving one (2026-09-29) ----
local P1
do
  local empty = core.parsePackets(nil)
  check("store: nothing on disk is an empty store", empty and next(empty.packets) == nil and empty.next == 1)
  eq("store: undecodable is nil (the panel backs the file up)", core.parsePackets("{nope"), nil)
  local fields = { title = "", task = "Make depth() tolerate a nil queue", repro = "lua -e 'require(\"cited\").depth(nil)'",
                   doneWhen = "depth(nil) returns 0" }
  local cites = core.parseCites("src/cited.lua:4-6")
  local read = { head = SHA, cites = { { text = core.packetSlice(BEFORE, 4, 6) } } }
  local store, id = core.packetNew(empty, fields, cites, read, 100)
  eq("new: the first packet is p1", id, "p1")
  eq("new: the next one will be p2", store and store.next, 2)
  P1 = store and store.packets.p1
  eq("new: the title defaults to the task's first line", P1 and P1.title, "Make depth() tolerate a nil queue")
  eq("new: the cite keeps the sha it was read at", P1 and P1.cites[1].sha, SHA)
  eq("new: ...and the lines it read", P1 and P1.cites[1].text, core.packetSlice(BEFORE, 4, 6))
  eq("new: repro and done-when ride along", P1 and (P1.repro .. "|" .. P1.doneWhen), fields.repro .. "|depth(nil) returns 0")
  eq("new: stamped", P1 and P1.at, 100)
  local back = core.parsePackets(core.json.encode(store))
  eq("store: survives a round trip through the file", back and back.packets.p1 and back.packets.p1.cites[1].text, P1 and P1.cites[1].text)
  eq("store: ...with its counter", back and back.next, 2)
  local _, id2 = core.packetNew(store, { task = "second" }, {}, { head = SHA, cites = {} }, 101)
  eq("new: the next is p2", id2, "p2")
  local none, why = core.packetNew(empty, { task = "  " }, cites, read, 100)
  check("new: a packet needs its task", none == nil and has(why, "task"))
  local _, whyGone = core.packetNew(empty, fields, cites, { head = SHA, cites = { { missing = true } } }, 100)
  check("new: a cited file that isn't at the sha is refused, naming it and the sha", has(whyGone, "src/cited.lua") and has(whyGone, "aaaaaaa"))
  local _, whyShort = core.packetNew(empty, fields, core.parseCites("src/cited.lua:10-14"),
    { head = SHA, cites = { { text = core.packetSlice(BEFORE, 10, 14) } } }, 100)
  check("new: a range past the end of the file is refused", has(whyShort, "src/cited.lua:10-14") and has(whyShort, "past the end"))
  local _, whyLong = core.packetNew(empty, { task = string.rep("x", core.PACKET_MAX_TEXT + 1) }, {}, { head = SHA, cites = {} }, 100)
  check("new: a task over the cap is refused", has(whyLong, tostring(core.PACKET_MAX_TEXT)))
  local long = select(1, core.packetNew(empty, { task = "t", title = string.rep("y", 200) }, {}, { head = SHA, cites = {} }, 100))
  eq("new: a long title is capped", long and #long.packets.p1.title <= core.PACKET_MAX_TITLE, true)
  -- a full store drops its oldest packet the queue no longer refers to; one the queue holds stays
  local full = core.parsePackets(nil)
  for i = 1, core.PACKETS_MAX do full = select(1, core.packetNew(full, { task = "t" .. i }, {}, { head = SHA, cites = {} }, i)) end
  local more = select(1, core.packetNew(full, { task = "one more" }, {}, { head = SHA, cites = {} }, 999, { p1 = true }))
  check("full store: the oldest packet the queue doesn't hold goes (p2), the queued p1 stays",
        more and more.packets.p1 and not more.packets.p2 and more.packets["p" .. (core.PACKETS_MAX + 1)])
  local keepAll = {}; for i = 1, core.PACKETS_MAX do keepAll["p" .. i] = true end
  local nope, whyFull = core.packetNew(full, { task = "x" }, {}, { head = SHA, cites = {} }, 999, keepAll)
  check("full store: when the queue holds every one, the new packet is refused", nope == nil and has(whyFull, "full"))
  check("remove: a packet can be dropped", core.packetRemove(store, "p1").packets.p1 == nil)
end

-- ---- task packets: drift on the literal before/after files (2026-09-29) ----
do
  local moved = core.packetDrift(P1, { head = SHA2, cites = { { text = core.packetSlice(MOVED, 4, 6) } } })
  eq("drift: a commit that rewrote the cited lines moved them", moved and #moved, 1)
  eq("drift: ...saying which", moved and moved[1] and moved[1].label, "src/cited.lua:4-6")
  eq("drift: ...and how", moved and moved[1] and moved[1].why, "changed")
  eq("drift: a change below the cited range moves nothing",
     #(core.packetDrift(P1, { head = SHA2, cites = { { text = core.packetSlice(BELOW, 4, 6) } } }) or { 1 }), 0)
  eq("drift: a file that's gone", (core.packetDrift(P1, { head = SHA2, cites = { { missing = true } } }) or {})[1].why, "gone")
  eq("drift: a read with the wrong number of cites is no verdict", core.packetDrift(P1, { head = SHA2, cites = {} }), nil)
  eq("moved line: one", core.packetMovedLine(moved), "cited code moved: src/cited.lua:4-6")
  eq("moved line: several", core.packetMovedLine({ { label = "a:1" }, { label = "b:2" }, { label = "c:3" } }), "cited code moved: a:1, b:2 and 1 more")
end

-- ---- task packets: what the session is sent (2026-09-29) ----
do
  local text = core.renderPacket(P1)
  check("render: the task first", text:sub(1, #"Make depth() tolerate a nil queue") == "Make depth() tolerate a nil queue")
  check("render: each cite with the sha it was read at", has(text, "src/cited.lua:4-6 (read at aaaaaaa)"))
  check("render: ...and its lines", has(text, core.packetSlice(BEFORE, 4, 6)))
  check("render: the repro", has(text, "Repro:\nlua -e"))
  check("render: done-when", has(text, "Done when:\ndepth(nil) returns 0"))
  local fenced = core.renderPacket({ task = "t", cites = { { path = "x.md", from = 1, to = 1, sha = SHA, text = "```lua\n" } } })
  check("render: a snippet holding ``` gets a longer fence", has(fenced, "````\n```lua\n````"))
  local bare = core.renderPacket({ task = "just this", cites = {} })
  eq("render: a packet with nothing else is its task", bare, "just this")
end

-- ---- task packets: the gate and the autofeed hold (2026-09-29) ----
do
  local v = { head = SHA, at = 10, moved = {} }
  eq("gate: no packet", select(1, core.packetGateFor("p9", nil, nil, SHA, 10)), "missing")
  check("gate: ...said so", has(select(2, core.packetGateFor("p9", nil, nil, SHA, 10)), "p9"))
  eq("gate: a packet with no cites feeds", core.packetGateFor("p2", { task = "t", cites = {} }, nil, SHA, 10), "feed")
  eq("gate: no verdict yet waits", core.packetGateFor("p1", P1, nil, SHA, 10), "wait")
  eq("gate: a verdict at this HEAD feeds", core.packetGateFor("p1", P1, v, SHA, 99999), "feed")
  eq("gate: HEAD moved since the verdict waits", core.packetGateFor("p1", P1, v, SHA2, 11), "wait")
  eq("gate: HEAD unknown, a verdict seconds old stands", core.packetGateFor("p1", P1, v, nil, 10 + core.PACKET_FRESH_SECONDS), "feed")
  eq("gate: HEAD unknown, an older one waits", core.packetGateFor("p1", P1, v, nil, 11 + core.PACKET_FRESH_SECONDS), "wait")
  local g, why = core.packetGateFor("p1", P1, { head = SHA, at = 10, moved = { { label = "src/cited.lua:4-6" } } }, SHA, 10)
  eq("gate: moved", g, "moved")
  eq("gate: ...with the line the card shows", why, "cited code moved: src/cited.lua:4-6")
  eq("gate: a read that failed", core.packetGateFor("p1", P1, { failed = "not a git repo", at = 10 }, SHA, 20), "unreadable")
  eq("gate: ...is tried again after a while", core.packetGateFor("p1", P1, { failed = "x", at = 10 }, SHA, 11 + core.PACKET_RETRY_SECONDS), "wait")
  local function af(...) local a, b = core.packetAutofeed(...); return tostring(a) .. "," .. tostring(b) end
  eq("autofeed: the done edge feeds a plain task", af(true, false, "done", nil), "true,false")
  eq("autofeed: the done edge feeds a checked packet", af(true, false, "done", "feed"), "true,false")
  eq("autofeed: a packet being checked holds, to try again", af(true, false, "done", "wait"), "false,true")
  eq("autofeed: the held feed goes once the check says feed", af(false, true, "done", "feed"), "true,false")
  eq("autofeed: a moved packet holds", af(true, false, "done", "moved"), "false,true")
  eq("autofeed: once the moved packet is removed, the next task goes", af(false, true, "done", nil), "true,false")
  eq("autofeed: a session that moved on drops the hold", af(false, true, "working", "feed"), "false,false")
  eq("autofeed: nothing due, nothing fed", af(false, false, "done", "feed"), "false,false")
end

-- ---- task packets: HEAD from the files, no git process (2026-09-29) ----
do
  local k, v = core.headRef("ref: refs/heads/feat/x\n")
  eq("head: a branch", (k or "") .. " " .. (v or ""), "ref refs/heads/feat/x")
  local k2, v2 = core.headRef(SHA .. "\n")
  eq("head: detached", (k2 or "") .. " " .. (v2 or ""), "sha " .. SHA)
  eq("head: junk", core.headRef("junk"), nil)
  local packed = "# pack-refs with: peeled fully-peeled sorted\n" .. SHA .. " refs/heads/main\n^" .. SHA2 .. "\n" .. SHA2 .. " refs/heads/x\n"
  eq("packed refs: the branch's sha", core.packedRefSha(packed, "refs/heads/main"), SHA)
  eq("packed refs: another", core.packedRefSha(packed, "refs/heads/x"), SHA2)
  eq("packed refs: absent", core.packedRefSha(packed, "refs/heads/y"), nil)
end

-- ---- task packets: a batch unit's message carries its packet (2026-09-29) ----
do
  local batch = { title = "B", driver = { name = "drv" }, units = {} }
  local unit = { type = "feat", slug = "u1", branch = "feat/u1", task = "do it", packet = "p1" }
  batch.units[1] = unit
  local plain = core.fleetUnitMessage(batch, unit, nil)
  check("unit message: names its packet", has(plain, "Its task packet: p1."))
  local full = core.fleetUnitMessage(batch, unit, nil, P1)
  check("unit message: with the packet, its evidence", has(full, "Its task packet: p1.") and has(full, core.packetSlice(BEFORE, 4, 6))
        and has(full, "Done when:\ndepth(nil) returns 0"))
end

-- ============ the shipped FX packet block, renderFeed and FX.fleetOpenTab ============
local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local body = src:match("\n(FX%._packetVerdicts = .-\nfunction FX%.fleetPacketGate%(b, slug%).-\nend\n)")
check("the panel ships the packet block (FX._packetVerdicts .. FX.fleetPacketGate)", body ~= nil)
local feedBody = src:match("\n(local function renderFeed%(task, item%).-\nend\n)")
check("the panel ships renderFeed", feedBody ~= nil)
local openBody = src:match("\n(function FX%.fleetOpenTab%(b, slug, req%).-\nend\n)")
check("the panel ships FX.fleetOpenTab", openBody ~= nil)
if not (body and feedBody and openBody) then finish() end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
do local p = io.popen('cd "' .. T .. '" && pwd -P'); T = p:read("*l"); p:close() end
local QD, MAIN, WT = T .. "/cc-queue", T .. "/main", T .. "/wt-w"
local function sh(cmd) return os.execute(cmd .. " >/dev/null 2>&1") == true end
local function commitFile(root, from, msg)
  return sh(('cp "%s" "%s/src/cited.lua" && cd "%s" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m "%s"')
    :format(from, root, root, msg))
end
local function revParse(root)
  local p = io.popen('git -C "' .. root .. '" rev-parse HEAD 2>/dev/null'); local s = p and p:read("*l"); if p then p:close() end
  return s
end
check("a real repo whose src/cited.lua is the literal before file",
  sh(('git init -q "%s" && mkdir -p "%s/src" "%s"'):format(MAIN, MAIN, QD)) and commitFile(MAIN, FIX .. "cited-before.lua", "before"))

-- a recorded hs.task: start() runs the command for real but holds its callback until drain(),
-- so the test sees the check in flight exactly as the panel would between two ticks
local pending, started = {}, 0
local function drain()
  local n = #pending
  while #pending > 0 do local cb = table.remove(pending, 1); cb() end
  return n
end
local hs = { task = { new = function(path, cb, argv)
  local t = { path = path, argv = argv or {} }
  function t:setWorkingDirectory(d) self.dir = d end
  function t:terminate() self.dead = true end
  function t:start()
    started = started + 1
    local q = { "'" .. self.path .. "'" }
    for _, a in ipairs(self.argv) do q[#q + 1] = "'" .. tostring(a):gsub("'", "'\\''") .. "'" end
    local p = io.popen(table.concat(q, " ") .. " 2>/dev/null; echo \"__code=$?\"")
    local out = p:read("*a"); p:close()
    local code = tonumber(out:match("__code=(%d+)\n?$")) or 1
    out = out:gsub("__code=%d+\n?$", "")
    pending[#pending + 1] = function() if not self.dead then cb(code, out, "") end end
    return self
  end
  return t
end } }

local calls = { answers = {}, opened = 0, logs = {}, queue = {} }
local NOW = 1000
local FX = { _fleetTabs = {} }
FX.now = function() return NOW end
FX.readFile = readAll
FX.gitRoot = function(cwd) return cwd end
FX.queueKeyFor = function(item) return core.queueKey(item) end
FX.readQueue = function(qk) return calls.queue[qk] or { tasks = {} } end
FX.writeQueue = function(qk, q) calls.queue[qk] = q end
FX.fleetAnswer = function(id, slug, b) calls.answers[#calls.answers + 1] = { id = id, slug = slug, body = b } end
FX.fleetRepoHost = function() return nil end
FX.fleetState = function() return { units = {} } end
FX.saveFleetState = function() end
FX.openClaudeTab = function() calls.opened = calls.opened + 1; return true end
hs.timer = { doEvery = function() return { stop = function() end } end }
local env = setmetatable({ FX = FX, core = core, hs = hs, QUEUE_DIR = QD,
  print = function(s) calls.logs[#calls.logs + 1] = tostring(s) end }, { __index = _G })
assert(load(body, "=packets", "t", env))()
local renderFeed = assert(load(feedBody .. "\nreturn renderFeed", "=renderFeed", "t", env))()
assert(load(openBody, "=fleetOpenTab", "t", env))()

local item = { key = "k1", cwd = MAIN, wtRoot = MAIN, projectKey = MAIN }
local QK = core.queueKey(item)

-- save a packet from the queue editor: its cites read at the session's HEAD, saved, then queued
local saved
FX.packetCapture(item, QK, { task = "Make depth() tolerate a nil queue", cites = "src/cited.lua:4-6",
                             repro = "call depth(nil)", doneWhen = "depth(nil) returns 0" },
  function(ok, a, b) saved = { ok = ok, a = a, b = b } end)
check("capture: waits on its read (async, nothing synchronous)", saved == nil and #pending == 1)
drain()
check("capture: saved", saved and saved.ok == true)
eq("capture: as p1", saved and saved.a, "p1")
local store = core.parsePackets(readAll(QD .. "/" .. core.packetsFileName(QK)))
eq("capture: in <qk>.packets.json next to the queue file", store and store.packets.p1 and store.packets.p1.cites[1].sha, revParse(MAIN))
local leftovers = io.popen('ls "' .. QD .. '" | grep -cF ".packets.json.tmp." || true'):read("*l")
eq("capture: no torn write left behind (temp + rename)", leftovers, "0")
local TOKEN = calls.queue[QK] and calls.queue[QK].tasks[1]
eq("capture: the queue holds the token in place of the text", TOKEN, "@packet:p1 Make depth() tolerate a nil queue")
local badSave
FX.packetCapture(item, QK, { task = "t", cites = "src/cited.lua:40-44" }, function(ok, why) badSave = { ok = ok, why = why } end)
drain()
check("capture: a range past the end is refused with the reason, nothing queued",
      badSave and badSave.ok == false and has(badSave.why, "past the end") and #calls.queue[QK].tasks == 1)

-- a store that can't be encoded (a cited file that isn't UTF-8, under hs.json) is refused, and the
-- form hears back instead of waiting on "Reading the cited code…" for good
do
  local realEncode = core.json.encode
  core.json.encode = function() error("invalid UTF-8") end
  local heard
  FX.packetCapture(item, QK, { task = "t", cites = "src/cited.lua:4-6" }, function(ok, why) heard = { ok = ok, why = why } end)
  drain()
  core.json.encode = realEncode
  check("capture: an unencodable store is refused, and said so", heard and heard.ok == false and has(heard.why, "couldn't write"))
  eq("capture: ...nothing queued for it", #calls.queue[QK].tasks, 1)
end

-- the gate at feed time: a verdict for the TARGET's HEAD, read in the background
local g = FX.packetGate(item, QK, TOKEN)
eq("gate: nothing checked yet -- wait", g, "wait")
eq("gate: ...and the check is running", #pending, 1)
eq("gate: asked again while it runs -- no second check", (FX.packetGate(item, QK, TOKEN)) .. "/" .. #pending, "wait/1")
drain()
eq("gate: the cited lines are unchanged -- feed", (FX.packetGate(item, QK, TOKEN)), "feed")
eq("gate: FX.gitHead read the HEAD from the files", FX.gitHead(MAIN), revParse(MAIN))
local typed = renderFeed(TOKEN, item)
check("renderFeed: types the packet's evidence, not the token", has(typed, "src/cited.lua:4-6 (read at ") and has(typed, "Done when:"))
eq("renderFeed: a plain task is untouched", renderFeed("just do it", item), "just do it")

check("a commit below the cited range", commitFile(MAIN, FIX .. "cited-after-below.lua", "below"))
eq("gate: HEAD moved -- checked again", (FX.packetGate(item, QK, TOKEN)) .. "/" .. #pending, "wait/1")
local typedWait, whyWait = renderFeed(TOKEN, item)
check("renderFeed: while it's checked, nothing is typed", typedWait == nil and has(whyWait, "checking"))
drain()
eq("gate: a change below the range doesn't move it", (FX.packetGate(item, QK, TOKEN)), "feed")
local BELOW_SHA = revParse(MAIN)

check("a commit that rewrites the cited function", commitFile(MAIN, FIX .. "cited-after-moved.lua", "moved"))
FX.packetGate(item, QK, TOKEN); drain()
local _, _, unrecorded = FX.packetGate(item, QK, TOKEN)
check("gate: a feed site's look doesn't use up the record (only the tick records)", not unrecorded)
local g2, why2, first2 = FX.packetGate(item, QK, TOKEN, true)
eq("gate: the cited code moved", g2, "moved")
eq("gate: ...the line the card shows", why2, "cited code moved: src/cited.lua:4-6")
eq("gate: ...recorded once", first2, true)
local _, _, again = FX.packetGate(item, QK, TOKEN, true)
check("gate: ...and only once per episode", not again)
local refused, refusedWhy = renderFeed(TOKEN, item)
check("renderFeed: refuses the drifted packet, with the reason", refused == nil and refusedWhy == "cited code moved: src/cited.lua:4-6")

-- the TARGET worktree's HEAD, not main's: a worktree still at the commit before
check("a worktree at the commit before", sh(('cd "%s" && git worktree add -q "%s" -b feat/w %s'):format(MAIN, WT, BELOW_SHA)))
local wtItem = { key = "k2", cwd = WT, wtRoot = WT, projectKey = MAIN }
eq("gitHead: a linked worktree's HEAD (its .git file, its own HEAD, the common refs)", FX.gitHead(WT), BELOW_SHA)
FX.packetGate(wtItem, QK, TOKEN); drain()
eq("gate: read at the target worktree's HEAD, where the code hasn't moved -- feed", (FX.packetGate(wtItem, QK, TOKEN)), "feed")
check("packed refs", sh('git -C "' .. MAIN .. '" pack-refs --all'))
eq("gitHead: a packed branch", FX.gitHead(MAIN), revParse(MAIN))
eq("gitHead: not a repo", FX.gitHead(T), nil)

-- a root that can't be read: not fed, said so, tried again later
local lost = { key = "k3", cwd = T .. "/nowhere", wtRoot = T .. "/nowhere", projectKey = MAIN }
FX.packetGate(lost, QK, TOKEN); drain()
local g3, why3 = FX.packetGate(lost, QK, TOKEN)
eq("gate: a worktree that can't be read isn't fed", g3, "unreadable")
check("gate: ...and says why", has(why3, "couldn't read"))
eq("gate: a packet the store doesn't have", (FX.packetGate(item, QK, "@packet:p9 gone")), "missing")

-- batches: drift is checked before FX.fleetOpenTab opens the unit's tab
local batch = { id = "b1", repo = MAIN, title = "B", driver = { name = "drv", session_id = "s" },
  units = { { type = "feat", slug = "u1", branch = "feat/u1", task = "t", packet = "p1" },
            { type = "feat", slug = "u2", branch = "feat/u2", task = "t" },
            { type = "feat", slug = "u3", branch = "feat/u3", task = "t", packet = "p9" } } }
eq("fleet gate: a unit without a packet opens", (FX.fleetPacketGate(batch, "u2")), "feed")
FX.fleetOpenTab(batch, "u1", { nonce = "n1" })
local a1 = calls.answers[#calls.answers]
check("fleet: a drifted unit is refused", a1 and a1.slug == "u1" and a1.body.ok == false and a1.body.nonce == "n1")
check("fleet: ...with the reason", a1 and has(a1.body.reason, "cited code moved: src/cited.lua:4-6") and has(a1.body.reason, "p1"))
eq("fleet: ...and no tab opened", calls.opened, 0)
FX.fleetOpenTab(batch, "u3", { nonce = "n3" })
local a3 = calls.answers[#calls.answers]
check("fleet: a unit whose packet isn't saved is refused, naming it", a3 and a3.slug == "u3" and a3.body.ok == false and has(a3.body.reason, "p9"))
FX.fleetOpenTab(batch, "u2", { nonce = "n2" })
eq("fleet: a unit without a packet opens its tab", calls.opened, 1)

-- a checked-out batch repo the packet still matches opens; one not checked yet waits (asked again next tick)
FX._packetVerdicts = {}
local nAnswers = #calls.answers
check("main goes back to the code the packet cites", commitFile(MAIN, FIX .. "cited-before.lua", "back"))
FX.fleetOpenTab(batch, "u1", { nonce = "n4" })
check("fleet: not checked yet -- nothing answered, nothing opened, the check runs",
      #calls.answers == nAnswers and calls.opened == 1 and #pending == 1)
drain()
FX._fleetTabs = {}
FX.fleetOpenTab(batch, "u1", { nonce = "n4" })
eq("fleet: checked and unchanged -- its tab opens", calls.opened, 2)

-- dropping a packet, and a store that won't decode
FX.dropPacket(QK, "p1")
check("drop: gone from the store", core.parsePackets(readAll(QD .. "/" .. core.packetsFileName(QK))).packets.p1 == nil)
local fh = io.open(QD .. "/" .. core.packetsFileName(QK), "w"); fh:write("{torn"); fh:close()
local s2 = FX.readPackets(QK)
check("store: an undecodable file reads as empty", s2 and next(s2.packets) == nil)
local bak = io.popen('ls "' .. QD .. '" | grep -cF ".packets.json.bad." || true'):read("*l")
eq("store: ...after it was backed up", bak, "1")

os.execute('rm -r "' .. T .. '"')
finish()
