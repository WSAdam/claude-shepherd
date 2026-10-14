-- send-cross.test.lua : BEHAVIORAL fixture for crossings over cc-send (2026-10-14, D-27 unit 2).
-- Adam, 2026-10-14: "projects should not be able to utilize having shepherd to talk to each other,
-- that needs to be an approved translation between the two rather than something automatic", and
-- cc-send gets "the same approval": a prompt one project's session sends a session of ANOTHER
-- project waits on the sender's card until Adam approves it (edited if he likes), and with --wait the
-- reply waits on the replying session's card the same way before the sender sees it. Same-project
-- sends and Adam's own shell stay instant. Who sent it is read from the CLI's process ancestry (one
-- ps), so `env -u CLAUDE_CODE_SESSION_ID` or a borrowed session id doesn't make a send look local, and
-- Shepherd follows the reply itself (core.sendFollowStep, the Lua twin of cc-send.sh's jq reducer),
-- so the sender never gets the other project's transcript path. Pure half first, then the real
-- dashboard under a stubbed hs. Side-effect-free: HOME and every dir are a temp dir.

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
local function finish() print("-- send-cross.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- ---- the pure half ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.sendCrosses exists", type(core.sendCrosses) == "function")
if type(core.sendCrosses) ~= "function" then finish() end

-- same project or not
check("two sessions of one repo don't cross", not core.sendCrosses("/r/alpha/.git", "/r/alpha/.git"))
check("two repos cross", core.sendCrosses("/r/alpha/.git", "/r/beta/.git"))
check("...and a project Shepherd can't place counts as crossing (fail closed)",
      core.sendCrosses(nil, "/r/beta/.git") and core.sendCrosses("/r/alpha/.git", nil))

-- who sent it: the CLI's ancestry
local tree = core.parsePsTree(table.concat({
  "    1     0 launchd",
  "  500     1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron",
  " 4242   500 /Users/a/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude",
  " 4300  4242 /bin/zsh",
  " 4301  4300 bash",
  " 7000     1 /bin/zsh",
  " 7001  7000 bash",
  " 8800   500 /usr/local/bin/claude",
  " 8801  8800 bash",
}, "\n"))
check("ps output is read into pid -> parent and command", tree["4301"] and tree["4301"].ppid == "4300" and tree["4242"].comm:find("claude", 1, true))
local isSession = function(p) return p == "4242" end
local pid, how = core.ancestorSession("4301", tree, isSession)
check("a CLI run by a session's shell is that session's", pid == "4242" and how == "session")
pid, how = core.ancestorSession("7001", tree, isSession)
check("one run from Adam's own terminal is nobody's", pid == nil and how == nil)
pid, how = core.ancestorSession("8801", tree, isSession)
check("one under a claude process Shepherd has no card for is a Claude session it can't place", pid == "8800" and how == "claude")
check("a pid ps doesn't list is nobody's", core.ancestorSession("99999", tree, isSession) == nil)
local loop = core.parsePsTree("  10    11 bash\n  11    10 bash")
check("a broken tree (a cycle) ends, nobody's", core.ancestorSession("10", loop, isSession) == nil)

-- the reply: core.sendFollowStep against cc-send.sh's own jq reducer, on every fixture
local sh = readFile(ROOT .. "cc-send.sh") or ""
local STEP = sh:match("\nSTEP='(.-)'\n")
check("cc-send.sh's reducer is found", STEP ~= nil)
local MARK = "cc-send #1790000000-4242"
local function jqFollow(path)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w"); f:write(STEP); f:close()
  local p = io.popen("jq -R -n -c --argjson s '{\"delivered\":false,\"reply\":null,\"replyId\":null,\"done\":null}' --arg m '"
    .. MARK .. "' -f '" .. tmp .. "' < '" .. path .. "' 2>/dev/null")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  os.remove(tmp)
  local ok, s = pcall(json.decode, out)
  return ok and s or nil
end
local function luaFollow(path)
  local recs = {}
  for line in ((readFile(path) or "") .. "\n"):gmatch("([^\n]*)\n") do
    local ok, r = pcall(json.decode, line)
    if ok and type(r) == "table" then recs[#recs + 1] = r end
  end
  -- in two halves, as the follower reads a growing transcript
  local half = math.floor(#recs / 2)
  local a, b = {}, {}
  for i, r in ipairs(recs) do if i <= half then a[#a + 1] = r else b[#b + 1] = r end end
  return core.sendFollowStep(core.sendFollowStep(nil, a, MARK), b, MARK)
end
for _, name in ipairs({ "turn-end", "queued-prompt", "session-start", "interrupted", "api-error" }) do
  local path = HERE .. "fixtures/send/" .. name .. ".jsonl"
  local want, got = jqFollow(path), luaFollow(path)
  check("sendFollowStep reads " .. name .. ".jsonl as cc-send.sh's reducer does",
        want and got and want.done == got.done and want.delivered == got.delivered and want.reply == got.reply
        and (want.error or json.null) == (got.error or json.null))
end
local te = luaFollow(HERE .. "fixtures/send/turn-end.jsonl")
eq("...turn-end's reply", te and te.reply, "There are 412 tests, all green.\n\nNothing failed.")

-- a held send's record, and its text
local req = { id = "1792100000-7", nonce = "77.1792100000.5", target = "beta", text = "How many tests are there?", wait = true,
              at = 1792100000, from = { key = "f1", pid = "4242" }, cliPid = "4301" }
local rec = core.crossSendRecord(req, "f1", { key = "f1", pid = "4242", name = "alpha-session", project = "/r/alpha/.git", projectName = "alpha" },
                                 { key = "w1", name = "beta-session", project = "/r/beta/.git", projectName = "beta" }, 1792100005, 3)
check("a held send is a pending crossing on its sender", rec and rec.kind == "send" and rec.state == "pending"
      and rec.from.key == "f1" and rec.to.name == "beta" and rec.original.text == "How many tests are there?"
      and rec.send.id == "1792100000-7" and rec.send.owner == "f1" and rec.send.wait == true and rec.send.cliPid == "4301")
check("...its cid is the sender's", core.crossAuthorOf(rec.cid) == "f1" and core.crossIdOk(rec.cid))
check("...read back from its file", core.parseCrossRecord(json.encode(rec), rec.cid) ~= nil)
eq("...its line says where it wants to go", core.crossLine(rec):find("beta", 1, true) ~= nil and core.crossLine(rec):find("prompt", 1, true) ~= nil, true)
local ap = core.crossDecide(rec, "approve", { text = "How many tests pass?" }, nil, 1792100100)
check("Adam edits the prompt and approves it", ap and ap.final.text == "How many tests pass?" and ap.decided.edited == true)
local bad = core.crossDecide(core.crossSendRecord(req, "f1", { key = "f1" }, { key = "w1", project = "/r/beta/.git" }, 1792100005, 4),
                             "approve", { text = "/clear" }, nil, 1792100100)
check("...never into a slash command", bad == nil)
local rep = core.crossSendReplyRecord(ap, "There are 412 tests.", { key = "w1", pid = "5151", name = "beta-session" }, 1792100200, 1)
check("the reply is a pending crossing on the session that wrote it", rep and rep.kind == "send-reply" and rep.from.key == "w1"
      and rep.to.key == "f1" and rep.parent == ap.cid and rep.original.text == "There are 412 tests." and core.crossAuthorOf(rep.cid) == "w1")
check("...its line says it goes back to the sender's project", core.crossLine(rep):find("alpha", 1, true) ~= nil)
local den = core.crossDecide(rep, "deny", nil, "Not that number.", 1792100300)
check("a denied reply tells its author", core.crossNoticeText(den):find("Not that number.", 1, true) ~= nil)

-- the answers a waiting cc-send takes are crossing files too (pruned with the rest)
local fa = core.crossFileOf("f1.1792100000-7.answer")
check("Shepherd's answer to a waiting cc-send is an answer", fa and fa.kind == "answer" and fa.cid == "f1.1792100000-7")
fa = core.crossFileOf("f1.1792100000-7.reply.answer")
check("...so is the reply it passed on", fa and fa.kind == "answer" and fa.cid == "f1.1792100000-7")
fa = core.crossFileOf("f1.1792100000-7.reply.answer.claim.4300")
check("...and the CLI's claim of one", fa and fa.kind == "claim" and fa.of == "answer")

-- a send nobody can take now is a heads-up, not red
local tile = { key = "f1", status = "done", crossing = { n = 1, cid = rec.cid, deliverable = false, why = "no live session in beta now" } }
local kind, source, why = core.needsYouKind(tile, 1792100000)
check("a held send whose project has no live session is a heads-up, saying why", kind == "fyi" and source == "cross" and why:find("beta", 1, true))
tile.crossing.deliverable = nil
eq("...one it can deliver needs Adam", (core.needsYouKind(tile, 1792100000)), "needs")

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local ph = io.popen("mktemp -d 2>/dev/null"); T = ph and ph:read("*l"); if ph then ph:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local SD, CX, INBOX = T .. "/.claude/cc-send", T .. "/.claude/cc-cross", T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. SD .. '" "' .. CX .. '" "' .. T .. '/alpha" "' .. T .. '/beta"')
local NOWP = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function append(path, s) local f = io.open(path, "a"); f:write(s); f:close() end
local function ls(dir)
  local out, ph = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if ph then for line in ph:lines() do out[#out + 1] = line end; ph:close() end
  table.sort(out)
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2},"ledger":{"enabled":true}}')
local ALPHA, BETA = T .. "/alpha", T .. "/beta"
-- w1's transcript lives where Claude Code keeps it: under the projects folder its launch folder names
local TR_W1 = T .. "/projects/" .. BETA:gsub("[^%w]", "-") .. "/w1.jsonl"
os.execute('mkdir -p "' .. TR_W1:match("^(.*)/") .. '"')
write(TR_W1, '{"type":"user","cwd":"' .. BETA .. '","message":{"role":"user","content":"earlier work"}}\n')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, since = NOWP - 100, updated = NOWP - 60, editor = "kitty",
              host_window = key .. "-host" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("f1", { cwd = ALPHA, session_pid = "4242" })                          -- alpha
status("f2", { cwd = ALPHA, session_pid = "4343" })                          -- alpha too
status("w1", { cwd = BETA, session_pid = "5151", transcript_path = TR_W1 })   -- beta

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
  secondsSinceEpoch = function() return os.time() end, absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,
  new = function() return mkstub() end, usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
hs.webview = setmetatable({
  windowMasks = setmetatable({}, { __index = function() return 0 end }),
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return webviewHandle() end, usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
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
check("FX.sendSender exists", type(fx.sendSender) == "function")
if type(fx.sendSender) ~= "function" then finish() end

local ledger, toasts = {}, {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOWP end
fx.alert = function(m) toasts[#toasts + 1] = tostring(m) end
local alive = {}
fx.probeAlive = function(pids) local o = {} for p in pairs(pids or {}) do o[p] = (alive[p] ~= false) end return o end
fx.readSessions = function() return {} end
-- the process tree every CLI here runs under: f1's shell (4242), f2's (4343), Adam's terminal, a claude with no card
fx.psTree = function() return table.concat({
  "    1     0 launchd", " 4242     1 claude", " 4300  4242 bash", " 4343     1 claude", " 4400  4343 bash",
  " 7000     1 zsh", " 7001  7000 bash", " 8800     1 claude", " 8801  8800 bash" }, "\n") end
local byK = {}
for _, x in ipairs(fx._shownItems or {}) do byK[x.key] = x end
check("every fixture session is on the panel", byK.f1 and byK.f2 and byK.w1)
if not (byK.f1 and byK.f2 and byK.w1) then finish() end
local list = fx._shownItems

local seq = 0
local function send(target, over)   -- the request cc-send.sh writes ("beta" goes as its folder, as the CLI sends a path)
  seq = seq + 1
  if target == "beta" then target = BETA end
  local r = { v = 1, id = NOWP .. "-" .. seq, nonce = "n." .. seq, target = target, text = "Prompt " .. seq .. ": how many tests?",
              wait = true, at = NOWP, from = { cwd = ALPHA, key = "f1", pid = "4242" }, cli_pid = "4300",
              path = (target:sub(1, 1) == "/") and target or nil }
  for k, v in pairs(over or {}) do r[k] = v end
  local owner = (r.from and r.from.key) or "shell"
  write(SD .. "/" .. owner .. "." .. r.id .. ".json", json.encode(r))
  return owner, r
end
local function answer(owner, r) local raw = readFile(SD .. "/" .. owner .. "." .. r.id .. ".answer"); return raw and json.decode(raw) or nil end
local function mail(key)
  local out = {}
  for _, fn in ipairs(ls(INBOX .. "/" .. key)) do out[#out + 1] = tostring((json.decode(readFile(INBOX .. "/" .. key .. "/" .. fn) or "{}") or {}).text) end
  return out
end
local function events(ty) local out = {} for _, e in ipairs(ledger) do if e.type == ty then out[#out + 1] = e end end return out end
local function rec(cid) local raw = readFile(CX .. "/" .. cid .. ".json"); return raw and json.decode(raw) or nil end
local function stepSend() quietly(function() fx.stepSend(list) end) end
local function step() quietly(function() fx.stepCrossings(list) end) end
local function decide(cid, verdict, fields)
  local p = { verdict = verdict }
  for k, v in pairs(fields or {}) do p[k] = v end
  local res
  quietly(function() res = fx.crossDecide(cid, json.encode(p)) end)
  return res
end
local function needs(it) quietly(function() fx.annotateNeedsYou(list) end); return it.needsYou, it.needsYouSource end

-- ---- same project, and Adam's own shell: instant, as before ----
local o1, r1 = send("f2")
stepSend()
local a1 = answer(o1, r1)
check("a send within one project is delivered at once", a1 and a1.ok == true and not a1.held and #mail("f2") == 1)
check("...holding nothing", #ls(CX) == 0)
local o2, r2 = send("beta", { from = { cwd = T }, cli_pid = "7001" })
stepSend()
local a2 = answer(o2, r2)
check("a send from Adam's own terminal to any project is delivered at once", a2 and a2.ok == true and not a2.held and #mail("w1") == 1)

-- ---- another project: held on the sender's card ----
local o3, r3 = send("beta")
stepSend()
local a3 = answer(o3, r3)
check("a send from alpha to beta is held, not delivered", a3 and a3.ok == true and a3.held == true and type(a3.cid) == "string"
      and #mail("w1") == 1)
check("...its answer carries no transcript path, offset or mailbox", a3 and a3.transcript == nil and a3.offset == nil and a3.mailbox == nil
      and a3.marker == nil)
local h3 = a3 and rec(a3.cid)
check("...Shepherd keeps a pending record of it, from f1 to beta", h3 and h3.kind == "send" and h3.state == "pending"
      and h3.from.key == "f1" and h3.send.target == BETA)
check("...the ledger records crossing_held", #events("crossing_held") == 1)
step()
check("...and f1's card carries it", byK.f1.crossing and byK.f1.crossing.cid == a3.cid)
local nk, ns = needs(byK.f1)
check("...red: Needs you, from the crossing", nk == "needs" and ns == "cross")
-- the sender is its ancestry, not what the environment says
local o4, r4 = send("beta", { from = { cwd = ALPHA } })                     -- env -u CLAUDE_CODE_SESSION_ID
stepSend()
check("a send with the session id blanked is still f1's, and held", answer(o4, r4).held == true and rec(answer(o4, r4).cid).from.key == "f1")
local o5, r5 = send("beta", { from = { cwd = ALPHA, key = "w1", pid = "5151" } })   -- a borrowed beta session id
stepSend()
local a5 = answer(o5, r5)
check("a send under a borrowed beta session id is still f1's, and held", a5 and a5.held == true and rec(a5.cid).from.key == "f1")
local o6, r6 = send("beta", { from = { cwd = ALPHA }, cli_pid = "8801" })
stepSend()
check("a send from a Claude session Shepherd has no card for is held (fail closed)", answer(o6, r6).held == true)
check("...nothing reached beta all along", #mail("w1") == 1)

-- ---- Approve: delivered with Adam's text, and the reply followed by Shepherd ----
local before = readFile(TR_W1)
check("Approving the held send with an edit goes through", decide(a3.cid, "approve", { text = "How many tests pass?" }) == true)
local wm = mail("w1")
check("...beta gets Adam's text, marked edited, naming the marker", #wm == 2 and wm[2]:find("How many tests pass?", 1, true)
      and wm[2]:find("(edited by Adam)", 1, true) and wm[2]:find("cc-send #" .. r3.id, 1, true) and not wm[2]:find("how many tests?", 1, true))
local da = readFile(CX .. "/" .. a3.cid .. ".answer")
local dad = da and json.decode(da) or {}
check("...the waiting CLI is told it went out, bound to its nonce, with no paths", dad.ok == true and dad.nonce == r3.nonce
      and dad.transcript == nil and dad.offset == nil)
h3 = rec(a3.cid)
check("...the record is published, and Shepherd follows the reply", h3.state == "approved" and h3.published ~= nil and type(h3.follow) == "table")
append(TR_W1, json.encode({ type = "user", message = { role = "user", content = "[shepherd] Message ... cc-send #" .. r3.id .. ": How many tests pass?" } }) .. "\n")
append(TR_W1, json.encode({ type = "assistant", message = { id = "m1", role = "assistant", content = { { type = "text", text = "412 pass." } } } }) .. "\n")
append(TR_W1, json.encode({ type = "system", subtype = "stop_hook_summary" }) .. "\n")
step()
local repRec
for _, fn in ipairs(ls(CX)) do
  local f = core.crossFileOf(fn)
  if f and f.kind == "record" then local x = rec(f.cid); if x and x.kind == "send-reply" then repRec = x end end
end
check("the reply is held as a crossing of w1's, back to alpha", repRec and repRec.state == "pending" and repRec.from.key == "w1"
      and repRec.original.text == "412 pass." and repRec.parent == a3.cid)
check("...on w1's card", byK.w1.crossing and byK.w1.crossing.cid == repRec.cid)
check("...and nothing reaches the waiting CLI yet", readFile(CX .. "/" .. a3.cid .. ".reply.answer") == nil)
check("Approving the reply goes through", decide(repRec.cid, "approve") == true)
local ra = readFile(CX .. "/" .. a3.cid .. ".reply.answer")
local rad = ra and json.decode(ra) or {}
check("...the waiting CLI gets it, bound to its nonce", rad.verdict == "approved" and rad.text == "412 pass." and rad.nonce == r3.nonce)

-- ---- Deny a send: the waiting CLI is told, nothing reaches beta ----
local before2 = #mail("w1")
check("Denying a held send goes through", decide(answer(o4, r4).cid, "deny", { why = "Ask beta yourself." }) == true)
local dn = json.decode(readFile(CX .. "/" .. answer(o4, r4).cid .. ".answer") or "{}") or {}
check("...the waiting CLI is told Adam denied it, with his note", dn.ok == false and dn.code == "denied"
      and tostring(dn.reason):find("Ask beta yourself.", 1, true))
check("...and beta got nothing", #mail("w1") == before2)

-- ---- a held send whose project has nobody to take it: a heads-up, and Approve waits ----
alive["5151"] = false
byK.w1.procAlive = false
step()
local k6, s6 = needs(byK.f1)
check("a send to a project with no live session reads as a heads-up on the sender", k6 == "fyi" and s6 == "cross")
check("...and Approve is refused, the send still waiting", decide(a5.cid, "approve") == false and rec(a5.cid).state == "pending")
alive["5151"] = nil
byK.w1.procAlive = nil

-- ---- the reply when the sender has stopped waiting: its mailbox ----
local o7, r7 = send("beta", { cli_pid = "4300" })
stepSend()
local a7 = answer(o7, r7)
decide(a7.cid, "approve")
append(TR_W1, json.encode({ type = "user", message = { role = "user", content = "cc-send #" .. r7.id } }) .. "\n")
append(TR_W1, json.encode({ type = "assistant", message = { id = "m2", role = "assistant", content = { { type = "text", text = "Second answer." } } } }) .. "\n")
append(TR_W1, json.encode({ type = "system", subtype = "stop_hook_summary" }) .. "\n")
step()
local rep7
for _, fn in ipairs(ls(CX)) do
  local f = core.crossFileOf(fn)
  if f and f.kind == "record" then local x = rec(f.cid); if x and x.kind == "send-reply" and x.parent == a7.cid then rep7 = x end end
end
alive["4300"] = false   -- the CLI gave up waiting
local fBefore = #mail("f1")
decide(rep7.cid, "approve")
local fm = mail("f1")
check("an approved reply whose CLI stopped waiting reaches the sender's mailbox", #fm == fBefore + 1 and fm[#fm]:find("Second answer.", 1, true))

finish()
