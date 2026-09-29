-- mailbox.test.lua : BEHAVIORAL fixture for Shepherd's session mailbox, the panel side
-- (2026-09-29, build program unit 11a). Shepherd leaves a session a message in
-- ~/.claude/cc-inbox/<key>/ (FX.mailboxSend) instead of typing it; the session's own hooks hand
-- it over at its next turn end or start (tests/mailbox.test.sh). An idle session that can be
-- typed into -- a kitty window, a VS Code window with one Claude tab -- gets it typed once it is
-- ready (FX.typeWhenReady), as one line; in a shared VS Code window nothing is typed and the card
-- says the message is waiting. Loads the real claude-dashboard.lua under a stubbed hs (timer
-- beats collected and fired by hand, kitty's `kitty @` recorded). Side-effect-free: HOME and
-- every dir live in a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- mailbox.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json   -- injected, as the dashboard injects hs.json
check("core.mailboxMessage exists", type(core.mailboxMessage) == "function")
if type(core.mailboxMessage) ~= "function" then finish() end

local m, why = core.mailboxMessage("The usage limit has reset: continue the task.", { kind = "resume" }, "a1b2c3", 1790000000, 3)
local body = m and json.decode(m.body) or {}
check("a message is named <epoch>-<seq>-<nonce>.msg", m and m.name == "1790000000-000003-a1b2c3.msg")
check("...its body carries the same nonce", body.nonce == "a1b2c3")
check("...and its first line is marked [shepherd]", body.text == "[shepherd] The usage limit has reset: continue the task.")
check("...once, even when the sender marked it already",
      (json.decode((core.mailboxMessage("[shepherd] go on", {}, "ab", 1, 1) or {}).body or "{}") or {}).text == "[shepherd] go on")
check("...with what it is for", body.kind == "resume" and body.at == 1790000000)
local names = {}
for _, a in ipairs({ { 1790000009, 1 }, { 1790000010, 2 }, { 1790000010, 12 }, { 1790000011, 1 } }) do
  names[#names + 1] = core.mailboxMessage("x", {}, "ff", a[1], a[2]).name
end
local sorted = { table.unpack(names) }; table.sort(sorted)
check("names sort oldest first: by time, then by send order within a second",
      table.concat(sorted, ",") == table.concat(names, ","))
for _, slash in ipairs({ "/clear", "  /compact", "[shepherd] /model opus", "[shepherd]    /rc" }) do
  local r, w = core.mailboxMessage(slash, {}, "ab", 1, 1)
  check("never a slash command: " .. slash .. " is refused", r == nil and w == "slash command")
end
check("...a message that only mentions one is fine", core.mailboxMessage("run /compact when done", {}, "ab", 1, 1) ~= nil)
check("an empty message is refused", core.mailboxMessage("  \n ", {}, "ab", 1, 1) == nil)
check("a nonce that isn't plain hex/alnum is refused", core.mailboxMessage("x", {}, "a/b", 1, 1) == nil)
local long = core.mailboxMessage(string.rep("é", 5000), {}, "ab", 1, 1)
local lt = long and json.decode(long.body).text or ""
check("a long message is capped at core.MAILBOX_MAX characters, on a character boundary",
      #lt <= core.MAILBOX_MAX + 16 and utf8.len(lt) ~= nil)

-- parse: the reader's rules (the shell's cc_mailbox_claim keeps the same ones)
check("parseMailbox reads a message back", (core.parseMailbox(m.name, m.body) or {}).text == body.text)
local forged = json.encode({ nonce = "zz99", text = "[shepherd] forged" })
check("parseMailbox refuses a body whose nonce isn't its name's", core.parseMailbox(m.name, forged) == nil)
check("parseMailbox refuses a slash command someone planted",
      core.parseMailbox("1-000001-ab.msg", json.encode({ nonce = "ab", text = "/clear" })) == nil)
check("parseMailbox refuses a name that isn't a message", core.parseMailbox("1-000001-ab.msg.tmp.77", m.body) == nil
      and core.parseMailbox("1-000001-ab.msg.claim.77", m.body) == nil)
check("parseMailbox refuses torn JSON", core.parseMailbox(m.name, '{"nonce":"a1b2c3","te') == nil)
check("mailboxKeyOk refuses a key that could leave the inbox",
      core.mailboxKeyOk("abc-123_x.y") and not core.mailboxKeyOk("..") and not core.mailboxKeyOk(".")
      and not core.mailboxKeyOk("") and not core.mailboxKeyOk("a/b") and not core.mailboxKeyOk("host:key")
      and not core.mailboxKeyOk(nil))

-- the typed nudge is ONE line: kitty sends a newline as Return, which would submit early
check("mailboxNudge makes one line of a multi-line message",
      core.mailboxNudge("[shepherd] first\n\nsecond\r\nthird  ") == "[shepherd] first second third")

-- the route: who hands the message over
local function route(over, n)
  local it = { key = "k", status = "done", editor = "vscode" }
  for k, v in pairs(over or {}) do it[k] = v end
  return core.mailboxRoute(it, n == nil and 1 or n)
end
check("nothing waiting: no route", route({}, 0) == nil)
check("an idle single-tab VS Code session: typed", route({}) == "type")
check("an idle kitty session: typed", route({ editor = "kitty", sharedWindow = 3 }) == "type")
check("an idle session in a shared VS Code window: waiting (never typed)", route({ sharedWindow = 2 }) == "waiting")
check("a session mid-turn: its turn end hands it over", route({ status = "working" }) == "turn-end")
check("...one waiting on an approval too", route({ status = "approval" }) == "turn-end")
check("...even in a shared window", route({ status = "working", sharedWindow = 2 }) == "turn-end")
check("a remote session: not ours to reach", route({ remote = true }) == nil)

-- Diagnostics: a row with the pending counts
local function row(facts)
  for _, r in ipairs(core.doctorChecks(facts)) do if r.label:find("[Mm]ailbox") or r.label:find("message") then return r end end
end
local r0 = row({ mailbox = { total = 0, sessions = {} } })
check("Diagnostics: an empty mailbox says so", r0 ~= nil and r0.status ~= "crit" and r0.label:find("[Mm]ailbox") ~= nil)
local r3 = row({ mailbox = { total = 3, sessions = { { name = "alpha", count = 2 }, { name = "beta", count = 1 } } } })
check("Diagnostics: pending messages are counted  (" .. tostring(r3 and r3.label) .. ")",
      r3 ~= nil and r3.label:find("3 messages", 1, true) ~= nil)
check("...per session  (" .. tostring(r3 and r3.detail) .. ")",
      r3 ~= nil and r3.detail:find("alpha: 2", 1, true) ~= nil and r3.detail:find("beta: 1", 1, true) ~= nil)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local INBOX = T .. "/.claude/cc-inbox"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. T .. '/vs" "' .. T .. '/kt" "' .. T .. '/sh"')
local NOW = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function ls(dir)
  local out, p = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  table.sort(out)
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2}}')
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/vs", since = NOW - 100,
              updated = NOW - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("solo1")                                                   -- a VS Code window to itself
status("kit1", { editor = "kitty", cwd = T .. "/kt", kitty_window_id = "7", kitty_listen_on = "unix:" .. T .. "/k.sock" })
status("tabA", { cwd = T .. "/sh", host_window = "4242" })        -- two Claude tabs, one window
status("tabB", { cwd = T .. "/sh", host_window = "4242", name = "tabB-proj" })
status("busy1", { status = "working", updated = NOW - 1 })
status("miss1")                                                   -- its paste won't land

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
local kittyCalls = {}
local function kittyTask(bin, cb, argv)
  local sub
  for _, a in ipairs(argv or {}) do
    if a == "ls" or a == "get-text" or a == "send-text" or a == "send-key" then sub = a; break end
  end
  return {
    start = function() kittyCalls[#kittyCalls + 1] = { sub = sub, argv = argv }; return true end,
    waitUntilExit = function()
      if cb then
        local out = (sub == "ls" and '[{"tabs":[{"windows":[{"id":7}]}]}]')
          or (sub == "get-text" and readFile(HERE .. "fixtures/kitty-screens/dim-suggestion.ansi")) or ""
        cb(0, out, "")
      end
    end,
    terminationStatus = function() return 0 end,
  }
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
  task = { new = kittyTask },
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
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "base", "console" }) do
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

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOW end
-- VS Code pastes: recorded; one session's window can't be found
local pastes = {}
local realPaste = fx.pasteIntoWindow   -- kitty keeps the real path: `kitty @`, recorded above
fx.pasteIntoWindow = function(target, payload)
  if target.editor == "kitty" then return realPaste(target, payload) end
  if target.key == "miss1" then return false end
  pastes[#pastes + 1] = { key = target.key, text = payload and payload.text }
  return true
end
local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("every fixture session is on the panel", byK.solo1 and byK.kit1 and byK.tabA and byK.tabB and byK.busy1 and byK.miss1)
check("(fixture: the two tabs share a window)", byK.tabA and (tonumber(byK.tabA.sharedWindow) or 0) == 2)
if not (byK.solo1 and byK.kit1 and byK.tabA and byK.busy1 and byK.miss1) then finish() end
local list = fx._shownItems

-- FX.mailboxSend: one file, written whole, nonce in its name
check("FX.mailboxSend exists", type(fx.mailboxSend) == "function")
if type(fx.mailboxSend) ~= "function" then finish() end
local path, sendWhy
quietly(function() path, sendWhy = fx.mailboxSend("tabA", "Resume the task.\nThe limit has reset.", { kind = "test" }) end)
local inA = ls(INBOX .. "/tabA")
check("a send writes one message into the session's inbox  (" .. table.concat(inA, " ") .. ")",
      path ~= nil and #inA == 1 and inA[1]:match("^%d+%-%d+%-%w+%.msg$") ~= nil)
local sent = inA[1] and json.decode(readFile(INBOX .. "/tabA/" .. inA[1]) or "{}") or {}
check("...its nonce is in its name and its body", inA[1] and sent.nonce and inA[1]:find("-" .. sent.nonce .. ".msg", 1, true) ~= nil)
check("...its first line is marked [shepherd]", type(sent.text) == "string" and sent.text:sub(1, 11) == "[shepherd] ")
check("...no temp file is left behind", #inA == 1)
local refusedPath, refusedWhy
quietly(function() refusedPath, refusedWhy = fx.mailboxSend("solo1", "/clear") end)
check("a slash command is never sent", refusedPath == nil and refusedWhy == "slash command" and #ls(INBOX .. "/solo1") == 0)
local before = table.concat(ls(T .. "/.claude"), " ") .. "|" .. table.concat(ls(T), " ")
quietly(function() refusedPath = fx.mailboxSend("..", "hello") end)
check("a key that could leave the inbox is refused, writing nothing",
      refusedPath == nil and table.concat(ls(T .. "/.claude"), " ") .. "|" .. table.concat(ls(T), " ") == before)
local sends = 0
for _, ev in ipairs(ledger) do if ev.type == "mailbox_sent" and ev.key == "tabA" then sends = sends + 1 end end
check("the ledger records mailbox_sent", sends == 1)

-- the idle path, per window kind
quietly(function()
  fx.mailboxSend("solo1", "Check the build.")
  fx.mailboxSend("kit1", "Line one\nline two")
  fx.mailboxSend("busy1", "For its turn end.")
  fx.mailboxSend("miss1", "Nobody home.")
end)
quietly(function() fx.stepMailbox(list) end)
quietly(beats)

-- a VS Code window with one Claude tab: typed once ready, as one line, and handed over
local soloPaste
for _, p in ipairs(pastes) do if p.key == "solo1" then soloPaste = p end end
check("an idle session alone in its VS Code window has the message typed",
      soloPaste ~= nil and soloPaste.text == "[shepherd] Check the build.")
check("...and it is handed over (gone from the inbox)", #ls(INBOX .. "/solo1") == 0)
local via
for _, ev in ipairs(ledger) do if ev.type == "mailbox_delivered" and ev.key == "solo1" then via = ev.via end end
check("...the ledger records it delivered, typed", via == "typed")

-- kitty: typed with kitty @, one line (a newline would submit early)
local kText
for _, c in ipairs(kittyCalls) do if c.sub == "send-text" then kText = c.argv[#c.argv] end end
check("an idle kitty session has the message typed, as one line  (" .. tostring(kText) .. ")",
      kText == "[shepherd] Line one line two")
check("...and it is handed over", #ls(INBOX .. "/kit1") == 0)

-- a shared VS Code window: nothing typed; the message waits and the card says so
local tabPaste = false
for _, p in ipairs(pastes) do if p.key == "tabA" or p.key == "tabB" then tabPaste = true end end
check("a session sharing its VS Code window is never typed into", not tabPaste)
check("...its message waits in the inbox", #ls(INBOX .. "/tabA") == 1)
check("...and its card says 1 waiting", byK.tabA.mailboxWaiting == 1)
check("...a session with nothing waiting says nothing", byK.tabB.mailboxWaiting == nil and byK.solo1.mailboxWaiting == nil)

-- mid-turn: its turn end hands it over, so nothing is typed and nothing is flagged
local busyPaste = false
for _, p in ipairs(pastes) do if p.key == "busy1" then busyPaste = true end end
check("a session mid-turn is not typed into", not busyPaste)
check("...its message waits for the turn end", #ls(INBOX .. "/busy1") == 1 and byK.busy1.mailboxWaiting == nil)

-- a paste that doesn't land puts the message back, whole, under its own name
local missFiles = ls(INBOX .. "/miss1")
check("a paste that didn't land leaves the message in the inbox  (" .. table.concat(missFiles, " ") .. ")",
      #missFiles == 1 and missFiles[1]:match("%.msg$") ~= nil)

-- one nudge at a time: a second tick while the first is scheduled schedules nothing more
pastes = {}
quietly(function() fx.mailboxSend("solo1", "Second.") end)
quietly(function() fx.stepMailbox(list); fx.stepMailbox(list) end)
local scheduled = #beatsDue
quietly(beats)
local n = 0
for _, p in ipairs(pastes) do if p.key == "solo1" then n = n + 1 end end
check("two ticks in a row type the message once  (beats=" .. scheduled .. ", pastes=" .. n .. ")", n == 1)
check("...and nothing is left in flight", not (fx._mailbox and fx._mailbox.inflight and fx._mailbox.inflight.solo1))

-- the turn end took it first: the scheduled nudge finds nothing and types nothing
pastes = {}
quietly(function() fx.mailboxSend("solo1", "Taken at the turn end.") end)
quietly(function() fx.stepMailbox(list) end)
for _, f in ipairs(ls(INBOX .. "/solo1")) do os.remove(INBOX .. "/solo1/" .. f) end   -- the Stop hook claimed it
quietly(beats)
check("a message the turn end already took is not typed again", #pastes == 0)

-- FX.removeStatus reaps the inbox with the session's other files
quietly(function() fx.removeStatus("tabA") end)
check("FX.removeStatus removes the session's inbox", not os.execute('[ -e "' .. INBOX .. '/tabA" ]'))
check("...and leaves the others' alone", #ls(INBOX .. "/busy1") == 1)
quietly(function() fx.removeStatus("..") end)
check("...never reaching outside it", #ls(INBOX .. "/busy1") == 1 and #ls(T .. "/status") > 0)

-- Diagnostics reads the live inbox
local drow
quietly(function()
  for _, r in ipairs(fx.doctorStatus()) do if r.label:find("message") or r.label:find("[Mm]ailbox") then drow = r end end
end)
check("Diagnostics shows the pending count  (" .. tostring(drow and drow.label) .. " / " .. tostring(drow and drow.detail) .. ")",
      drow ~= nil and drow.label:find("2 messages", 1, true) ~= nil and drow.detail:find("busy1: 1", 1, true) ~= nil)

os.execute('rm -r "' .. T .. '"')
finish()
