-- main-moved.test.lua : the "main moved" notice (2026-10-03, mining round 2 unit E2).
-- After a verified merge, the repo's OTHER worktree sessions whose own changes touch the files the
-- merge brought in hear about it once, through their mailbox at their turn end (never typed): they
-- rebase before they ask to merge instead of finding out in the gate. The merge's files come from
-- the verify command's @@files; each sibling's from the overlap radar's scan. "Sent" is kept on
-- disk per repo + merged sha, because Shepherd forgets FX._mergeVerify on a reload and the
-- verified edge can fire again for a request still on disk.
-- Part 1: the pure half (core.mainMovedTargets, core.mainMovedMessage, the verify's files, the
-- turn-end-only mailbox route) and the real shell programs against real repos. Part 2: the real
-- claude-dashboard.lua under a stubbed hs, from the verified edge (FX.mergeAutoClose) to the
-- message in the sibling's inbox. Side-effect-free: every file lives in a temp dir; HOME is there.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got " .. tostring(got) .. ")", got == want)
end
local function finish() print("-- main-moved.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function join(t) return table.concat(t or {}, ",") end

-- ---- Part 1: the pure half (2026-10-03) ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.mainMovedTargets exists", type(core.mainMovedTargets) == "function")
check("core.mainMovedMessage exists", type(core.mainMovedMessage) == "function")
check("core.mergeVerifyFiles exists", type(core.mergeVerifyFiles) == "function")
check("core.mainMovedKey exists", type(core.mainMovedKey) == "function")
check("core.mainMovedPrune exists", type(core.mainMovedPrune) == "function")
if type(core.mainMovedTargets) ~= "function" or type(core.mainMovedMessage) ~= "function"
   or type(core.mergeVerifyFiles) ~= "function" or type(core.mainMovedKey) ~= "function"
   or type(core.mainMovedPrune) ~= "function" then finish() end

local CD, MAIN = "/r/R/.git", "/r/R"
local WA, WB, WC, WD = MAIN .. "/.claude/worktrees/a", MAIN .. "/.claude/worktrees/b", MAIN .. "/.claude/worktrees/c",
  MAIN .. "/.claude/worktrees/d"
local SHA = "abcdef1234567890abcdef1234567890abcdef12"
local r = { key = "merged1", session_id = "merged1", nonce = "n1", worktree = WA, commonDir = CD,
            branch = "feat/a", base = "main", sha = SHA, phase = "merged" }
local scan = { base = { branch = "main", sha = "f00" }, worktrees = {
  { path = WA, committed = { "app.lua", "cc-core.lua" }, dirty = {}, untracked = {} },
  { path = WB, committed = { "app.lua", "x.lua" }, dirty = { "README.md" }, untracked = {} },
  { path = WC, committed = { "other.lua" }, dirty = {}, untracked = { "notes.md" } },
  { path = WD, committed = {}, dirty = {}, untracked = { "cc-core.lua" } },
}, pairs = {} }
local function tile(key, wt, over)
  local t = { key = key, session_id = key, name = key, status = "done", repoKey = CD, mainRoot = MAIN, wtRoot = wt }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end
local list = {
  tile("merged1", WA),                                   -- the merged session itself
  tile("sibB", WB),                                      -- shares app.lua and README.md
  tile("sibC", WC),                                      -- shares nothing
  tile("mainS", MAIN, { isMainWt = true }),              -- the main checkout
  tile("sibD", WD, { status = "working" }),              -- an untracked file the merge added
  tile("remote1", WB, { remote = "host" }),              -- another machine's session
  tile("other1", "/r/O/.claude/worktrees/b", { repoKey = "/r/O/.git", mainRoot = "/r/O" }),   -- another repo
  tile("dead1", WB, { procAlive = false }),              -- its process is gone
  tile("noscan", MAIN .. "/.claude/worktrees/e"),        -- a worktree the scan didn't cover
}
local merged = { "app.lua", "README.md", "cc-core.lua" }
local targets = core.mainMovedTargets(list, r, merged, scan)
local keys = {}
for _, t in ipairs(targets) do keys[#keys + 1] = t.key end
eq("targets: only the live sibling worktrees whose own files overlap the merge", join(keys), "sibB,sibD")
eq("targets: ...each with the overlapping files, sorted", targets[1] and join(targets[1].files), "README.md,app.lua")
eq("targets: ...an untracked file counts too", targets[2] and join(targets[2].files), "cc-core.lua")
check("targets: ...and each carries its tile", targets[1] and targets[1].it == list[2])
check("targets: the merged session, the main checkout, a remote, another repo, a dead process and an unscanned worktree never",
      not (keys[1] == "merged1" or keys[1] == "mainS"))
eq("targets: a repo key with a trailing slash still matches", #core.mainMovedTargets(
  { tile("sibB", WB, { repoKey = CD .. "/" }) }, r, merged, scan), 1)
eq("targets: no merged files and no scan entry for the merged worktree: nobody", #core.mainMovedTargets(list, r, {},
  { worktrees = { scan.worktrees[2] } }), 0)
local fb = core.mainMovedTargets(list, r, nil, scan)
local fbKeys = {}
for _, t in ipairs(fb) do fbKeys[#fbKeys + 1] = t.key .. "=" .. join(t.files) end
eq("targets: no verify files: the radar's entry for the merged worktree stands in", join(fbKeys), "sibB=app.lua,sibD=cc-core.lua")
eq("targets: no scan: nobody (overlap can't be told)", #core.mainMovedTargets(list, r, merged, nil), 0)
eq("targets: one session per key, even listed twice", #core.mainMovedTargets({ list[2], list[2] }, r, merged, scan), 1)

eq("message: names the new tip, the unit and the shared files",
   core.mainMovedMessage(r, { "README.md", "app.lua" }),
   "main moved to abcdef1 (feat/a), touching README.md, app.lua: rebase onto main before you ask to merge")
eq("message: more than three files are capped",
   core.mainMovedMessage(r, { "a", "b", "c", "d", "e" }),
   "main moved to abcdef1 (feat/a), touching a, b, c and 2 more: rebase onto main before you ask to merge")
eq("message: another base is named as it is",
   core.mainMovedMessage({ sha = SHA, branch = "fix/x", base = "develop" }, { "a" }),
   "develop moved to abcdef1 (fix/x), touching a: rebase onto develop before you ask to merge")
local odd = core.mainMovedMessage(r, { "evil\nname.lua" })
check("message: a file name can't break the message into lines", not odd:find("\n", 1, true))
check("message: it is never a slash command", not core.mailboxSlash(core.mainMovedMessage(r, { "/etc" })))

-- the merge's files: the verify command's @@files (main's tip before the merge, to the merged commit)
local vcmd = core.mergeVerifyCmd(r)
check("verify: lists the files the merge brought in, from main's tip before it to the merged commit",
      vcmd:find("echo @@files", 1, true) ~= nil and vcmd:find('diff --name-only "$from" ' .. SHA, 1, true) ~= nil)
check("verify: ...with the worktree list still last",
      vcmd:sub(-#"worktree list --porcelain 2>/dev/null") == "worktree list --porcelain 2>/dev/null")
local vout = "@@in\n@@mainhead\nmain\n@@markers\n@@files\napp.lua\nREADME.md\n\napp.lua\n@@stash\n0\n@@list\nworktree /r/R\n"
eq("verify files: read from the @@files section, once each", join(core.mergeVerifyFiles(vout)), "app.lua,README.md")
eq("verify files: an older output without the section has none", #core.mergeVerifyFiles("@@in\n@@list\n"), 0)
eq("verify files: no output, none", #core.mergeVerifyFiles(nil), 0)
check("verify files: the new section doesn't change the verdict", (core.mergeVerified(r, vout)) == true)

-- "sent" is kept per repo + merged sha
eq("key: the repo's git dir and the merged sha", core.mainMovedKey(r), CD .. "|" .. SHA)
eq("key: a trailing slash on the git dir is the same repo", core.mainMovedKey({ commonDir = CD .. "/", sha = SHA }), CD .. "|" .. SHA)
eq("key: no sha, no key", core.mainMovedKey({ commonDir = CD }), nil)
local NOW = 1800000000
local store = core.mainMovedPrune({ old = NOW - core.MAIN_MOVED_KEEP - 1, fresh = NOW - 10, junk = "x" }, NOW)
check("prune: a mark older than core.MAIN_MOVED_KEEP goes, a fresh one stays, junk goes",
      store.old == nil and store.fresh == NOW - 10 and store.junk == nil)
local many = {}
for i = 1, core.MAIN_MOVED_MAX + 5 do many["k" .. i] = NOW - i end
local kept, n = core.mainMovedPrune(many, NOW), 0
for _ in pairs(kept) do n = n + 1 end
check("prune: at most core.MAIN_MOVED_MAX marks, the newest", n == core.MAIN_MOVED_MAX and kept.k1 ~= nil
      and kept["k" .. (core.MAIN_MOVED_MAX + 5)] == nil)

-- the turn-end-only mailbox route: such a message is never typed into an idle session
local m = core.mailboxMessage("main moved", { kind = "main-moved", turnEndOnly = true }, "ab12", NOW, 1)
local body = m and json.decode(m.body) or {}
check("mailbox: a turn-end-only message says so in its body", body.turnEndOnly == true)
check("mailbox: ...and reads back as one", (core.parseMailbox(m.name, m.body) or {}).turnEndOnly == true)
local plain = core.mailboxMessage("hello", {}, "ab13", NOW, 2)
check("mailbox: an ordinary message carries no such flag", json.decode(plain.body).turnEndOnly == nil
      and core.parseMailbox(plain.name, plain.body).turnEndOnly == nil)
local idle = { key = "k", status = "done", editor = "vscode" }
eq("route: an idle session whose waiting messages are all turn-end-only: waiting, never typed",
   core.mailboxRoute(idle, 1, false, 0), "waiting")
eq("route: ...one typeable message among them: typed", core.mailboxRoute(idle, 2, false, 1), "type")
eq("route: ...an older caller that doesn't say: typed, as before", core.mailboxRoute(idle, 1), "type")
eq("route: ...mid-turn its turn end hands it over", core.mailboxRoute({ key = "k", status = "working" }, 1, false, 0), "turn-end")
eq("route: ...on hold it is held", core.mailboxRoute(idle, 1, true, 0), "held")

-- ---- the real shell programs, against real repos (2026-10-03) ----
local function sh(cmd) local ok = os.execute(cmd .. " >/dev/null 2>&1"); return ok == true or ok == 0 end
-- a fixture file, written by Lua (sh's own >/dev/null would override a shell redirect)
local function put(path, text) local f = io.open(path, "w"); if not f then return false end f:write(text); f:close(); return true end
local function capture(cmd) local p = io.popen(cmd); local s = p and p:read("*a") or ""; if p then p:close() end; return s end
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = capture("cd '" .. T .. "' && pwd -P"):gsub("%s+$", "")
do
  local R = T .. "/repo"
  local G = "git -C '" .. R .. "' -c user.email=t@example.invalid -c user.name=t "
  local A = R .. "/.claude/worktrees/a"
  local GA = "git -C '" .. A .. "' -c user.email=t@example.invalid -c user.name=t "
  local okSetup = sh("git init -q -b main '" .. R .. "'")
    and put(R .. "/app.lua", "a\n") and put(R .. "/keep.lua", "k\n")
    and sh(G .. "add -A") and sh(G .. "commit -qm base")
    and sh(G .. "worktree add -q -b feat/a '" .. A .. "'")
    and put(A .. "/app.lua", "A changed\n") and put(A .. "/new.lua", "n\n")
    and sh(GA .. "add -A") and sh(GA .. "commit -qm a")
  local sha = capture(GA .. "rev-parse HEAD"):gsub("%s+$", "")
  okSetup = okSetup and sh(G .. "merge -q --ff-only feat/a")
    and put(R .. "/later.lua", "l\n") and sh(G .. "add -A") and sh(G .. "commit -qm later")
  check("real repo: a unit fast-forwarded into main, then another commit on main", okSetup and sha:match("^%x+$") ~= nil)
  local req = { commonDir = R .. "/.git", worktree = A, branch = "feat/a", base = "main", sha = sha }
  local out = capture(core.mergeVerifyCmd(req))
  eq("real repo: the verify lists exactly the merge's files (not main's later commit)", join(core.mergeVerifyFiles(out)), "app.lua,new.lua")
end
do
  -- 2026-10-03: the radar scanned a repo's worktrees only when it had two or more linked ones, so
  -- once the merged unit's worktree was gone the LAST sibling had no files in the scan and could
  -- never hear that main moved.
  local R = T .. "/solo"
  local G = "git -C '" .. R .. "' -c user.email=t@example.invalid -c user.name=t "
  local B = R .. "/.claude/worktrees/b"
  local GB = "git -C '" .. B .. "' -c user.email=t@example.invalid -c user.name=t "
  local okSetup = sh("git init -q -b main '" .. R .. "'")
    and put(R .. "/app.lua", "a\n") and sh(G .. "add -A") and sh(G .. "commit -qm base")
    and sh(G .. "worktree add -q -b feat/b '" .. B .. "'")
    and put(B .. "/app.lua", "b changed\n") and sh(GB .. "add -A") and sh(GB .. "commit -qm b")
  check("real repo: one linked worktree", okSetup)
  local outFile = T .. "/radar.out"
  local cmd = core.folderScanShellCommand(core.radarScanArgv(R, core.RADAR_MAX_WORKTREES), outFile)
  sh("/bin/sh -c '" .. cmd:gsub("'", "'\\''") .. "'")
  local f = io.open(outFile, "r"); local text = f and f:read("*a") or ""; if f then f:close() end
  local sc = core.parseRadarScan(text)
  eq("radar: a repo with ONE linked worktree still has its files scanned", #sc.worktrees, 1)
  eq("radar: ...its branch diff", sc.worktrees[1] and join(sc.worktrees[1].committed), "app.lua")
  eq("radar: ...and no pairs (nothing to pair it with)", #sc.pairs, 0)
  eq("radar: ...so the view flags nothing", #core.radarView(sc, {}).pairs, 0)
end

-- ---- Part 2: the real dashboard under a stubbed hs (2026-10-03) ----
local INBOX = T .. "/.claude/cc-inbox"
local MERGE = T .. "/.claude/cc-merge"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. MERGE .. '"')
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function ls(dir)
  local out, p = {}, io.popen('ls -A "' .. dir .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  table.sort(out)
  return out
end
local function msgs(key)
  local out = {}
  for _, fn in ipairs(ls(INBOX .. "/" .. key)) do
    if fn:match("%.msg$") then out[#out + 1] = json.decode(readFile(INBOX .. "/" .. key .. "/" .. fn) or "{}") or {} end
  end
  return out
end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2}}')
local NOWT = os.time()
local function status(key, over)
  local s = { status = "done", session_id = key, name = key, cwd = T .. "/" .. key, since = NOWT - 100,
              updated = NOWT - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
status("merged1", { status = "working", updated = NOWT - 1 })
status("sibB")                                                   -- idle, alone in its VS Code window
status("sibC")
status("mainS")
status("sibD", { status = "working", updated = NOWT - 1 })

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
-- Shepherd's verify of the merge: the commit is in main, main is clean, the worktree is gone,
-- and the merge brought in app.lua, README.md and cc-core.lua.
local VERIFY = "@@in\n@@mainhead\nmain\n@@maindirty\n@@markers\n@@files\napp.lua\nREADME.md\ncc-core.lua\n@@stash\n0\n"
  .. "@@list\nworktree /r/R\nHEAD " .. SHA .. "\nbranch refs/heads/main\n"
local verifies = 0
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
  execute = function(cmd)
    if tostring(cmd):find("merge-base --is-ancestor " .. SHA, 1, true) then verifies = verifies + 1; return VERIFY end
    return ""
  end,
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
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quietly(fn) print = function() end; local res = { pcall(fn) }; print = realPrint; return table.unpack(res) end
local ok, err = quietly(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
beatsDue = {}
check("FX.mainMovedQueue and FX.stepMainMoved exist", type(fx.mainMovedQueue) == "function" and type(fx.stepMainMoved) == "function")
if type(fx.mainMovedQueue) ~= "function" or type(fx.stepMainMoved) ~= "function" then finish() end

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return NOWT end
local pastes = {}
fx.pasteIntoWindow = function(target, payload)
  pastes[#pastes + 1] = { key = target.key, text = payload and payload.text }
  return true
end
local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("every fixture session is on the panel", byK.merged1 and byK.sibB and byK.sibC and byK.mainS and byK.sibD)
if not (byK.merged1 and byK.sibB and byK.sibC and byK.mainS and byK.sibD) then finish() end
-- the stack identity the panel stamps from git (core.applyStackIdentity), stamped by hand here
for key, wt in pairs({ merged1 = WA, sibB = WB, sibC = WC, mainS = MAIN, sibD = WD }) do
  byK[key].repoKey, byK[key].mainRoot, byK[key].wtRoot, byK[key].isMainWt = CD, MAIN, wt, (key == "mainS") or nil
end
local tiles = fx._shownItems

-- the verified edge queues the notice; it waits for the repo's radar scan
fx._radar[CD] = nil
quietly(function() fx.mergeAutoClose(r, byK.merged1) end)
eq("the verify ran once, with Shepherd's own git", verifies, 1)
local pend = 0
for _ in pairs(fx._mainMoved and fx._mainMoved.pending or {}) do pend = pend + 1 end
eq("a verified merge queues one main-moved notice", pend, 1)
quietly(function() fx.stepMainMoved(tiles) end)
eq("...which waits while the repo has no radar scan", #ls(INBOX .. "/sibB"), 0)

-- the scan lands: the overlapping siblings get one message each
fx._radar[CD] = { root = MAIN, cache = { ts = NOWT, data = scan } }
quietly(function() fx.stepMainMoved(tiles) end)
local mb, md = msgs("sibB"), msgs("sibD")
eq("the idle sibling that shares files gets one message", #mb, 1)
eq("...its text", mb[1] and mb[1].text,
   "[shepherd] main moved to abcdef1 (feat/a), touching README.md, app.lua: rebase onto main before you ask to merge")
check("...turn-end only, kind main-moved", mb[1] and mb[1].turnEndOnly == true and mb[1].kind == "main-moved")
eq("the working sibling that shares a file gets one too", #md, 1)
check("the sibling that shares nothing, the main checkout and the merged session get none",
      #msgs("sibC") == 0 and #msgs("mainS") == 0 and #msgs("merged1") == 0)
local sentEv = {}
for _, ev in ipairs(ledger) do if ev.type == "main_moved_sent" then sentEv[#sentEv + 1] = tostring(ev.key) end end
table.sort(sentEv)
eq("the ledger records each notice", join(sentEv), "sibB,sibD")
local marks = json.decode(readFile(MERGE .. "/main-moved.seen") or "{}") or {}
check("the notice is marked sent on disk, per repo + merged sha", type(marks[CD .. "|" .. SHA]) == "number")
pend = 0
for _ in pairs(fx._mainMoved.pending) do pend = pend + 1 end
eq("...and nothing is left queued", pend, 0)

-- a reload forgets the verify, and the edge fires again: the mark on disk keeps it to once
fx._mergeVerify[r.nonce] = nil
quietly(function() fx.mergeAutoClose(r, byK.merged1) end)
quietly(function() fx.stepMainMoved(tiles) end)
eq("the edge firing again after a reload sends nothing new", #msgs("sibB") + #msgs("sibD"), 2)
eq("...the verify did run again (the edge fired)", verifies, 2)

-- the mailbox never types it into the idle sibling: it waits for its turn end or next start
quietly(function() fx.stepMailbox(tiles) end)
quietly(beats)
local typed = false
for _, p in ipairs(pastes) do if p.key == "sibB" then typed = true end end
check("an idle sibling is never typed into for it", not typed)
eq("...its card says the message waits", byK.sibB.mailboxWaiting, 1)
-- an ordinary message for the same session is still typed, and the notice stays for the turn end
quietly(function() fx.mailboxSend("sibB", "Check the build.") end)
quietly(function() fx.stepMailbox(tiles) end)
quietly(beats)
local typedText
for _, p in ipairs(pastes) do if p.key == "sibB" then typedText = p.text end end
eq("an ordinary message to it is typed as before", typedText, "[shepherd] Check the build.")
local left = msgs("sibB")
check("...and the main-moved notice is still waiting, untouched", #left == 1 and left[1].turnEndOnly == true)

-- switched off: merge.mainMovedNotice false queues nothing
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false},"merge":{"mainMovedNotice":false}}')
local r2 = {}
for k, v in pairs(r) do r2[k] = v end
r2.sha, r2.nonce = string.rep("b", 40), "n2"
quietly(function() fx.mainMovedQueue(r2, VERIFY) end)
pend = 0
for _ in pairs(fx._mainMoved.pending) do pend = pend + 1 end
eq("merge.mainMovedNotice false: nothing is queued", pend, 0)

-- radar off: a queued notice is dropped (nobody's files can be told), never left waiting
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false},"radar":{"enabled":false}}')
fx._radar[CD] = nil
quietly(function() fx.mainMovedQueue(r2, VERIFY) end)
quietly(function() fx.stepMainMoved(tiles) end)
pend = 0
for _ in pairs(fx._mainMoved.pending) do pend = pend + 1 end
eq("radar.enabled false: the notice is dropped, not left waiting", pend, 0)
eq("...and sends nothing", #msgs("sibB") + #msgs("sibD"), 2)

-- the wiring: the verified edge queues it, and every tick steps it
local src = readFile(ROOT .. "claude-dashboard.lua") or ""
local ac = src:match("function FX%.mergeAutoClose%(r, it%)(.-)\nend\n") or ""
check("wiring: the verified edge in FX.mergeAutoClose queues the notice",
      ac:find("if ok then pcall(FX.mainMovedQueue, r, out) end", 1, true) ~= nil)
check("wiring: the tick steps it, after the merges", src:find("pcall(FX.stepMainMoved, list)", 1, true) ~= nil
      and (src:find("pcall(FX.stepMainMoved, list)", 1, true) or 0) > (src:find("FX.annotateMerges(list, cfg, bannerOn)", 1, true) or math.huge))

os.execute('rm -r "' .. T .. '"')
finish()
