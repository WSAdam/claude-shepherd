-- send.test.lua : BEHAVIORAL fixture for cc-send's Shepherd side (2026-09-29, build program unit 30).
-- `cc-send.sh <project|session> "prompt" [--wait]` leaves a request in ~/.claude/cc-send/; each tick
-- Shepherd claims it, picks the target (core.sendTarget: a session by key or name, or a project by
-- its repo root or name -> its best live session, idle before busy, never one waiting on Adam and
-- never the caller), leaves the prompt in that session's mailbox (FX.deliverTo -> FX.mailboxSend,
-- [shepherd]-marked, ledgered) and answers with where it went and where to follow the reply. The
-- CLI half is tests/send.test.sh. Loads the real claude-dashboard.lua under a stubbed hs, like
-- tests/mailbox.test.lua. Side-effect-free: HOME and every dir live in a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- send.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.sendTarget exists", type(core.sendTarget) == "function")
if type(core.sendTarget) ~= "function" then finish() end

-- ---- target selection (2026-09-29) ----
local function tile(key, over)
  local t = { key = key, session_id = key, name = key, status = "done", updated = 100, editor = "vscode",
              session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end
local fleet = {
  -- project alpha: a main-checkout session sitting idle, and a busier worktree session
  tile("a-idle", { name = "alpha", mainRoot = "/r/alpha", wtRoot = "/r/alpha", cwd = "/r/alpha", stackName = "alpha", updated = 100 }),
  tile("a-busy", { name = "fix-x", mainRoot = "/r/alpha", wtRoot = "/r/alpha/.claude/worktrees/fix-x",
                   cwd = "/r/alpha/.claude/worktrees/fix-x", stackName = "alpha", status = "working", updated = 900 }),
  -- project beta: its one session is mid-turn
  tile("b-busy", { name = "beta", mainRoot = "/r/beta", wtRoot = "/r/beta", cwd = "/r/beta", stackName = "beta", status = "working" }),
  -- project gamma: its one session is waiting on Adam's answer to a question
  tile("g-ask", { name = "gamma", mainRoot = "/r/gamma", wtRoot = "/r/gamma", cwd = "/r/gamma", stackName = "gamma",
                  status = "approval", needsYou = "needs", needsYouSource = "ask" }),
  -- project delta: the caller's own session, and another one
  tile("d-me", { name = "delta", mainRoot = "/r/delta", wtRoot = "/r/delta", cwd = "/r/delta", stackName = "delta",
                 session_pid = "4242", updated = 999 }),
  tile("d-other", { name = "delta-wt", mainRoot = "/r/delta", wtRoot = "/r/delta/wt", cwd = "/r/delta/wt", stackName = "delta",
                    status = "working" }),
  -- project solo: nothing but the caller
  tile("s-me", { name = "solo", mainRoot = "/r/solo", wtRoot = "/r/solo", cwd = "/r/solo", stackName = "solo" }),
  -- two sessions named alike in two projects, neither project named that
  tile("t-one", { name = "twin", mainRoot = "/r/one", wtRoot = "/r/one", cwd = "/r/one", stackName = "one" }),
  tile("t-two", { name = "twin", mainRoot = "/r/two", wtRoot = "/r/two", cwd = "/r/two", stackName = "two" }),
  -- two repos with the same folder name
  tile("m-a", { name = "m-a", mainRoot = "/a/same", wtRoot = "/a/same", cwd = "/a/same", stackName = "same" }),
  tile("m-b", { name = "m-b", mainRoot = "/b/same", wtRoot = "/b/same", cwd = "/b/same", stackName = "same" }),
  -- a session other sessions know by its Claude Code name (the one SendMessage addresses)
  tile("p-peer", { name = "wgs", peerName = "wgsUltra-7f", mainRoot = "/r/wgs", wtRoot = "/r/wgs", cwd = "/r/wgs", stackName = "wgs" }),
  -- ones that can't take anything
  tile("x-far", { name = "far", remote = { host = "mini" }, stackName = "far" }),
  tile("x-gone", { name = "gone", procAlive = false, stackName = "gone" }),
  tile("x-ghost", { name = "ghost", tabless = true, stackName = "ghost" }),
  -- a heads-up on its card isn't waiting on Adam
  tile("f-fyi", { name = "calm", status = "error", needsYou = "fyi", needsYouSource = "error", stackName = "calm" }),
}
local function pick(target, opts) return core.sendTarget(fleet, target, opts) end

local it, why, code, choices = pick("b-busy")
check("a session key picks that session", it and it.key == "b-busy")
check("...even mid-turn (its turn end hands the prompt over)", it and it.status == "working")
it = pick("wgsUltra-7f")
check("a session's Claude Code name picks it (the name other sessions message it by)", it and it.key == "p-peer")
it = pick("WGSULTRA-7F")
check("...whatever the case", it and it.key == "p-peer")
it = pick("alpha")
check("a project name picks its idle session over a busy one, however recent", it and it.key == "a-idle")
it = pick("beta")
check("a project whose only live session is busy gets that one", it and it.key == "b-busy")
it = pick("x", { path = "/r/alpha" })
check("a repo root picks the project's best session", it and it.key == "a-idle")
it = pick("x", { path = "/r/alpha/.claude/worktrees/fix-x" })
check("a worktree's root picks the session working there", it and it.key == "a-busy")
it = pick("/r/alpha/")
check("...a path typed with a trailing slash too", it and it.key == "a-idle")

it, why, code = pick("gamma")
check("a project whose only session is waiting on Adam: none  (" .. tostring(why) .. ")",
      it == nil and code == "none" and tostring(why):find("waiting on you", 1, true) ~= nil)
it, why, code = pick("g-ask")
check("...and by its key it's refused, saying why  (" .. tostring(why) .. ")",
      it == nil and code == "unavailable" and tostring(why):find("a question", 1, true) ~= nil)
it = pick("calm")
check("a card with only a heads-up (not waiting on Adam) can take a prompt", it and it.key == "f-fyi")

it = pick("delta", { callerKey = "d-me" })
check("never the caller: its project's other session is picked", it and it.key == "d-other")
it = pick("delta", { callerPid = "4242" })
check("...known by its pid too (a /clear gives the caller a new key, not a new process)", it and it.key == "d-other")
it, why, code = pick("solo", { callerKey = "s-me" })
check("a project with nobody but the caller: none  (" .. tostring(why) .. ")",
      it == nil and code == "none" and tostring(why):find("you", 1, true) ~= nil)
it, why, code = pick("d-me", { callerKey = "d-me" })
check("the caller's own key is refused  (" .. tostring(why) .. ")", it == nil and code == "unavailable")

it, why, code, choices = pick("twin")
check("a name two sessions share is ambiguous  (" .. tostring(why) .. ")", it == nil and code == "ambiguous")
local joined = table.concat(choices or {}, " | ")
check("...listing both, by key  (" .. joined .. ")", joined:find("t-one", 1, true) ~= nil and joined:find("t-two", 1, true) ~= nil)
it, why, code, choices = pick("same")
joined = table.concat(choices or {}, " | ")
check("a name two projects share is ambiguous, listing both roots  (" .. joined .. ")",
      it == nil and code == "ambiguous" and joined:find("/a/same", 1, true) ~= nil and joined:find("/b/same", 1, true) ~= nil)
it, why, code = pick("nobody-here")
check("a name nothing has: none  (" .. tostring(why) .. ")", it == nil and code == "none")
it, why, code = pick("x", { path = "/r/nowhere" })
check("a folder no session is open in: none", it == nil and code == "none")
it, why, code = pick("   ")
check("an empty target is a usage error", it == nil and code == "usage")

it, why = pick("far")
check("a session on another machine is refused  (" .. tostring(why) .. ")", it == nil and tostring(why):find("another machine", 1, true) ~= nil)
it, why = pick("gone")
check("a session that has ended is refused", it == nil and tostring(why):find("ended", 1, true) ~= nil)
it, why = pick("ghost")
check("a session whose tab is gone is refused", it == nil and tostring(why):find("tab", 1, true) ~= nil)

local ranked = core.sendCandidates(fleet, { callerKey = "d-me" }, function(t) return t.mainRoot == "/r/alpha" or t.mainRoot == "/r/delta" end)
local order = {}
for _, t in ipairs(ranked) do order[#order + 1] = t.key end
check("sendCandidates ranks the live ones idle first, then the most recent  (" .. table.concat(order, ",") .. ")",
      table.concat(order, ",") == "a-idle,a-busy,d-other")

-- ---- the request and the text delivered ----
local NOW = 1790000000
local function request(over)
  local r = { v = 1, id = "1790000000-4242", nonce = "77.1790000000.1", target = "alpha", text = "What is the test count?",
              wait = true, from = { key = "caller-1", pid = "4242" }, at = NOW }
  for k, v in pairs(over or {}) do r[k] = v end
  return json.encode(r)
end
local owner, id = core.sendRequestName("caller-1.1790000000-4242.json")
check("a request file is named <caller key>.<epoch>-<n>.json", owner == "caller-1" and id == "1790000000-4242")
check("...answers, temps and claims aren't requests",
      core.sendRequestName("caller-1.1790000000-4242.answer") == nil
      and core.sendRequestName("caller-1.1790000000-4242.json.tmp.77") == nil
      and core.sendRequestName("caller-1.1790000000-4242.json.claim.shepherd") == nil)
local req = core.parseSendRequest(request(), "1790000000-4242", NOW)
check("a request is read back", req and req.target == "alpha" and req.wait == true and req.from.key == "caller-1")
local bad, bwhy, bnonce = core.parseSendRequest(request({ text = "/clear" }), "1790000000-4242", NOW)
check("a slash command is refused, keeping the nonce for the answer", bad == nil and bwhy == "slash command" and bnonce == "77.1790000000.1")
check("...marked [shepherd] or not", core.parseSendRequest(request({ text = "[shepherd] /compact" }), "1790000000-4242", NOW) == nil)
check("an empty prompt is refused", core.parseSendRequest(request({ text = " \n " }), "1790000000-4242", NOW) == nil)
local _, lwhy = core.parseSendRequest(request({ text = string.rep("x", core.SEND.textMax + 1) }), "1790000000-4242", NOW)
check("a prompt over core.SEND.textMax bytes is refused  (" .. tostring(lwhy) .. ")", lwhy ~= nil and lwhy:find("too long", 1, true) ~= nil)
local _, ewhy = core.parseSendRequest(request({ at = NOW - core.SEND.requestMaxAge - 5 }), "1790000000-4242", NOW)
check("a request its CLI has given up on is expired", ewhy == "expired")
check("a body whose id isn't its file name's is refused", core.parseSendRequest(request(), "1790000000-9999", NOW) == nil)
check("torn JSON is refused", core.parseSendRequest('{"v":1,"id":"17', "1790000000-4242", NOW) == nil)

local text = core.sendText(req, "claude-instance-manager-60")
check("the delivered text is marked [shepherd]  (" .. text:gsub("\n", "\\n") .. ")", text:sub(1, 11) == "[shepherd] ")
check("...names the sender and carries the request's marker",
      text:find("claude-instance-manager-60", 1, true) ~= nil and text:find(core.sendMarker(req.id), 1, true) ~= nil)
check("...says a reply is awaited only with --wait", text:find("waiting for your reply", 1, true) ~= nil
      and core.sendText(core.parseSendRequest(request({ wait = false }), "1790000000-4242", NOW), "x"):find("waiting", 1, true) == nil)
check("...and ends with the prompt itself", text:sub(-#"What is the test count?") == "What is the test count?")
check("a plain shell is named as one", core.sendText(req, nil):find("from a shell", 1, true) ~= nil)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local SEND = T .. "/.claude/cc-send"
local INBOX = T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude/cc-send" "' .. T .. '/vs" "' .. T .. '/sh" "' .. T .. '/busy" "' .. T .. '/tr"')
local NOWP = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function ls(dir)
  local out, p = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  table.sort(out)
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2},"ledger":{"enabled":true}}')
local TRANSCRIPT = T .. "/tr/solo1.jsonl"
write(TRANSCRIPT, '{"type":"user","message":{"role":"user","content":"hi"}}\n{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"hello"}]}}\n')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/vs", since = NOWP - 100,
              updated = NOWP - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("solo1", { transcript_path = TRANSCRIPT })                       -- a VS Code window to itself
status("tabA", { cwd = T .. "/sh", host_window = "4242" })              -- two Claude tabs, one window
status("tabB", { cwd = T .. "/sh", host_window = "4242" })
status("busy1", { cwd = T .. "/busy", status = "working", updated = NOWP - 1 })

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
local beatsDue = {}
local function beats()
  local n = 0
  while #beatsDue > 0 do
    local b = table.remove(beatsDue, 1)
    n = n + 1
    b.fn()
    if n > 80 then break end
  end
  return n
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path)
      local h = io.open(tostring(path), "r")
      if h then h:close(); return { mode = "file" } end
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
  doAfter = function(delay, fn) beatsDue[#beatsDue + 1] = { delay = delay, fn = fn }; return mkstub() end,
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
beatsDue = {}
check("FX.stepSend exists", type(fx.stepSend) == "function")
check("FX.deliverTo exists (the helper unit 29's tickets reuse)", type(fx.deliverTo) == "function")
if type(fx.stepSend) ~= "function" then finish() end

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOWP end
local pastes = {}
fx.pasteIntoWindow = function(target, payload)
  pastes[#pastes + 1] = { key = target.key, text = payload and payload.text }
  return true
end
local byK = {}
for _, t in ipairs(fx._shownItems or {}) do byK[t.key] = t end
check("every fixture session is on the panel", byK.solo1 and byK.tabA and byK.tabB and byK.busy1)
if not (byK.solo1 and byK.tabA and byK.busy1) then finish() end
local list = fx._shownItems

local seq = 0
local function send(target, textIn, over)
  seq = seq + 1
  local rid = tostring(NOWP) .. "-" .. seq
  local owner_ = (over and over.owner) or "shell"
  local r = { v = 1, id = rid, nonce = "n" .. seq, target = target, text = textIn, wait = true,
              from = { key = owner_ ~= "shell" and owner_ or nil }, at = NOWP }
  for k, v in pairs(over or {}) do if k ~= "owner" then r[k] = v end end
  write(SEND .. "/" .. owner_ .. "." .. rid .. ".json", json.encode(r))
  return SEND .. "/" .. owner_ .. "." .. rid, "n" .. seq, rid
end
local function answerOf(base)
  local raw = readFile(base .. ".answer")
  return raw and json.decode(raw) or nil
end
local function events(t) local out = {} for _, e in ipairs(ledger) do if e.type == t then out[#out + 1] = e end end return out end

-- a request by key: delivered to the mailbox, answered with where to follow the reply
local base, nonce, rid = send("solo1", "What is the test count?")
local size0 = #readFile(TRANSCRIPT)
quietly(function() fx.stepSend(list) end)
local a = answerOf(base)
check("Shepherd answers the request, bound to its nonce", a and a.nonce == nonce)
check("...delivered to the session it names", a and a.ok == true and a.key == "solo1")
check("...an idle session alone in its window gets it typed once ready", a and a.route == "type")
check("...with its transcript and the size it had when the prompt was sent",
      a and a.transcript == TRANSCRIPT and tonumber(a.offset) == size0)
check("...and the marker its reply is found by", a and a.marker == core.sendMarker(rid))
check("the request file is taken (claimed and removed)", readFile(base .. ".json") == nil and #ls(SEND) == 1)
local inbox = ls(INBOX .. "/solo1")
local msg = inbox[1] and json.decode(readFile(INBOX .. "/solo1/" .. inbox[1]) or "{}") or {}
check("the prompt waits in the session's mailbox, marked [shepherd] and carrying the marker",
      #inbox == 1 and tostring(msg.text):sub(1, 11) == "[shepherd] " and tostring(msg.text):find(core.sendMarker(rid), 1, true) ~= nil
      and tostring(msg.text):find("What is the test count?", 1, true) ~= nil)
-- 2026-09-29 ledger pin: every cc-send delivery is ledgered, by the request's id, with how it arrives
local dl = events("send_delivered")
check("the ledger records send_delivered: the session, the request and the route",
      #dl == 1 and dl[1].key == "solo1" and dl[1].id == rid and dl[1].route == "type" and dl[1].target == "solo1")
local ms = events("mailbox_sent")
check("...and the mailbox send, as a cc-send", #ms == 1 and ms[1].kind == "send")

-- the next tick's mailbox step types it: one line, readiness-checked
quietly(function() fx.stepMailbox(list) end)
quietly(beats)
check("the idle session gets the prompt typed, as one line carrying the marker",
      #pastes == 1 and pastes[1].key == "solo1" and tostring(pastes[1].text):find(core.sendMarker(rid), 1, true) ~= nil
      and not tostring(pastes[1].text):find("\n", 1, true))

-- taken once: the same request seen again (a second tick, a reload) delivers nothing more
os.remove(base .. ".answer")
write(base .. ".json", json.encode({ v = 1, id = rid, nonce = nonce, target = "solo1", text = "again", from = {}, at = NOWP }))
quietly(function() fx.stepSend(list) end)
check("a request id already answered is never delivered twice", #events("send_delivered") == 1 and #ls(INBOX .. "/solo1") == 0)

-- a busy session: it gets it at its turn end
base = send("busy1", "When you're done, summarise.")
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("a busy session gets the prompt at its turn end", a and a.ok and a.route == "turn-end" and #ls(INBOX .. "/busy1") == 1)
check("...and with no transcript known the answer says so (nothing to follow)", a and a.transcript == nil)

-- a shared window: nothing typed, it waits, and the answer says so
base = send("tabA", "Check in.")
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("an idle session in a shared window: its prompt waits in its mailbox", a and a.ok and a.route == "waiting")

-- a folder: the session open there
base = send("x", "By path.", { path = T .. "/busy" })
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("a folder picks the session open in it", a and a.ok and a.key == "busy1")

-- refusals: answered with why, nothing delivered, ledgered
local before = #ls(INBOX .. "/solo1")
base = send("nobody-at-all", "Hello?")
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("no such session or project: refused with code none", a and a.ok == false and a.code == "none" and type(a.reason) == "string")
base = send("tabA", "Twice?", { owner = "tabA" })
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("the caller's own session is refused", a and a.ok == false and a.code == "unavailable")
base = send("solo1", "/clear")
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("a slash command is refused as a bad request", a and a.ok == false and a.code == "refused")
base = send("solo1", "Late.", { at = NOWP - core.SEND.requestMaxAge - 10 })
quietly(function() fx.stepSend(list) end)
a = answerOf(base)
check("a request its CLI gave up on is dropped undelivered", a and a.ok == false and a.code == "expired")
check("...and none of them reached a mailbox", #ls(INBOX .. "/solo1") == before)
check("...each refusal is ledgered", #events("send_refused") == 4)

-- cleanup: a session's requests go with it; a stale file goes on the next tick
write(SEND .. "/tabA.1790000000-1.json", "{}")
write(SEND .. "/tabB.1790000000-2.json.tmp.5", "{}")
quietly(function() fx.removeStatus("tabA") end)
check("FX.removeStatus drops the requests that session made", readFile(SEND .. "/tabA.1790000000-1.json") == nil)
check("...and leaves the others' alone", readFile(SEND .. "/tabB.1790000000-2.json.tmp.5") ~= nil)
quietly(function() fx.removeStatus("..") end)
check("...never reaching outside the folder", #ls(T .. "/status") > 0)
write(SEND .. "/shell." .. tostring(NOWP - core.SEND.keepSeconds - 60) .. "-9.answer", "{}")
quietly(function() fx.stepSend(list) end)
check("a file older than core.SEND.keepSeconds is pruned", readFile(SEND .. "/shell." .. tostring(NOWP - core.SEND.keepSeconds - 60) .. "-9.answer") == nil)

os.execute('rm -r "' .. T .. '"')
finish()
