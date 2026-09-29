-- leases.test.lua : BEHAVIORAL fixture for worktree leases (2026-09-29, build program unit 27).
-- Parallel units that each run a dev server or a database used to fight over one port and one
-- file. Each worktree Shepherd starts a session for now gets its own PORT and DB path: the pure
-- allocation and texts in cc-core.lua, then the REAL shipped FX lease block (FX.LEASE_DIR ..
-- FX.sweepLeases), sliced out of claude-dashboard.lua and loaded against a recorded hs (the
-- pins.test.lua pattern), over real files and a real git worktree in a temp dir.
--
-- Usage: lua tests/leases.test.lua [path/to/claude-dashboard.lua]

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
local function finish() print("-- leases.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function has(s, needle) return type(s) == "string" and s:find(needle, 1, true) ~= nil end

-- ---- worktree leases: settings and allocation (2026-09-29) ----
local S
do
  local s = core.leaseSettings({}, "/Users/u")
  eq("settings: leases are on by default", s.enabled, true)
  eq("settings: ports 4100-4199 by default", s.from .. "-" .. s.to, "4100-4199")
  eq("settings: the database folder defaults to ~/.claude/cc-lease/db", s.dbDir, "/Users/u/.claude/cc-lease/db")
  local s2 = core.leaseSettings({ lease = { enabled = false, portFrom = 5000, portTo = 5002, dbDir = "~/dbs/" } }, "/Users/u")
  eq("settings: lease.enabled false turns them off", s2.enabled, false)
  eq("settings: the configured range", s2.from .. "-" .. s2.to, "5000-5002")
  eq("settings: ~/ in dbDir is the home folder (and a trailing / goes)", s2.dbDir, "/Users/u/dbs")
  for what, l in pairs({ ["an upside-down range"] = { portFrom = 5002, portTo = 5000 },
                         ["a privileged port"] = { portFrom = 80, portTo = 90 },
                         ["a port past 65535"] = { portFrom = 65000, portTo = 70000 },
                         ["a fractional port"] = { portFrom = 5000.5, portTo = 5010 },
                         ["a string"] = { portFrom = "x", portTo = 5010 } }) do
    local b = core.leaseSettings({ lease = l }, "/Users/u")
    eq("settings: " .. what .. " falls back to the default range", b.from .. "-" .. b.to, "4100-4199")
  end
  eq("settings: a relative dbDir falls back to the default",
     core.leaseSettings({ lease = { dbDir = "dbs" } }, "/Users/u").dbDir, "/Users/u/.claude/cc-lease/db")
  eq("settings: a dbDir holding a quote falls back to the default",
     core.leaseSettings({ lease = { dbDir = "/tmp/it's" } }, "/Users/u").dbDir, "/Users/u/.claude/cc-lease/db")
  S = core.leaseSettings({ lease = { portFrom = 4100, portTo = 4103 } }, "/Users/u")
end

do
  local regs = {}
  local a, regA, freshA = core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/a", S, 100)
  eq("mint: the first worktree gets the lowest port of the range", a and a.port, 4100)
  eq("mint: ...a fresh lease", freshA, true)
  eq("mint: ...and a database path of its own, named for the repo, the unit and the port",
     a and a.db, "/Users/u/.claude/cc-lease/db/main-a-4100.db")
  eq("mint: ...stamped with when", a and a.at, 100)
  regs["/r/main"] = regA
  local b = select(1, core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/b/", S, 101))
  eq("mint: the next worktree gets the next free port", b and b.port, 4101)
  regs["/r/main"] = select(2, core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/b", S, 101))
  check("mint: ...recorded under its path without the trailing /", regs["/r/main"].leases["/r/main/.claude/worktrees/b"] ~= nil)
  local again, _, freshAgain = core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/a", S, 999)
  eq("mint: a worktree that has a lease keeps it", again and again.port, 4100)
  eq("mint: ...not a fresh one", freshAgain, false)
  eq("mint: ...its time unchanged", again and again.at, 100)
  local o, regO = core.leaseMint(regs, "/q/other", "/q/other-x", S, 102)
  eq("mint: ports are machine-wide -- another repo's worktree never gets a port a lease holds", o and o.port, 4102)
  eq("mint: a sibling folder that already carries the repo's name isn't named twice",
     core.leaseDbPath("/d", "/q/other", "/q/other-x", 4102), "/d/other-x-4102.db")
  regs["/q/other"] = regO
  local d = select(1, core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/d", S, 103))
  eq("mint: the last port of the range", d and d.port, 4103)
  regs["/r/main"] = select(2, core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/d", S, 103))
  local none, why = core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/e", S, 104)
  check("mint: a full range leases nothing  (" .. tostring(why) .. ")", none == nil and has(why, "4100-4103"))
  -- reuse after release: a freed port is the lowest free one again
  regs["/r/main"].leases["/r/main/.claude/worktrees/a"] = nil
  local e, regE = core.leaseMint(regs, "/r/main", "/r/main/.claude/worktrees/e", S, 105)
  eq("mint: a released port is handed out again", e and e.port, 4100)
  regs["/r/main"] = regE
  check("mint: the main checkout gets no lease", core.leaseMint({}, "/r/main", "/r/main/", S, 1) == nil)
  check("mint: a relative worktree path gets none", core.leaseMint({}, "/r/main", "wt", S, 1) == nil)
  check("mint: nor one holding a control character", core.leaseMint({}, "/r/main", "/r/w\nt", S, 1) == nil)
  local off = core.leaseSettings({ lease = { enabled = false } }, "/Users/u")
  check("mint: nothing while leases are off", core.leaseMint({}, "/r/main", "/r/main/.claude/worktrees/a", off, 1) == nil)
  local held = core.leaseHeldPorts(regs)
  check("held ports: every lease of every repo", held[4101] and held[4102] and held[4103] and held[4100] and not held[4104])
  eq("free port: the lowest one no lease holds", core.leaseFreePort(4100, 4110, { [4100] = "x", [4102] = "y" }), 4101)
end

-- ---- the registry file (2026-09-29) ----
do
  local reg = { main = "/r/main", leases = {
    ["/r/main/.claude/worktrees/a"] = { port = 4100, db = "/d/main-a-4100.db", at = 5, seen = true },
    ["/r/main/.claude/worktrees/b"] = { port = 4101, db = "/d/main-b-4101.db", at = 6 } } }
  local raw = core.encodeLeases(reg)
  local back = core.parseLeases(raw, "/r/main")
  check("registry: it round-trips", back ~= nil and back.main == "/r/main"
        and back.leases["/r/main/.claude/worktrees/a"].port == 4100 and back.leases["/r/main/.claude/worktrees/a"].seen == true
        and back.leases["/r/main/.claude/worktrees/b"].db == "/d/main-b-4101.db" and not back.leases["/r/main/.claude/worktrees/b"].seen)
  check("registry: one line of JSON", not raw:find("\n", 1, true))
  check("registry: a file written for another checkout (a name both share) is nil", core.parseLeases(raw, "/r/main2") == nil)
  check("registry: garbage is nil", core.parseLeases("{nope", nil) == nil and core.parseLeases("", nil) == nil)
  check("registry: a file that names no checkout is nil", core.parseLeases('{"v":1,"leases":{}}', nil) == nil)
  local mixed = core.parseLeases(core.json.encode({ v = 1, main = "/r/main", leases = {
    ["/r/main/.claude/worktrees/ok"] = { port = 4100, db = "/d/ok.db" },
    ["/r/main/.claude/worktrees/p"] = { port = "4101", db = "/d/p.db" },
    ["/r/main/.claude/worktrees/q"] = { port = 4102, db = "relative.db" },
    ["relative"] = { port = 4103, db = "/d/r.db" },
    ["/r/main/.claude/worktrees/n"] = { port = 4104, db = "/d/n\n.db" } } }), "/r/main")
  local n = 0; for _ in pairs(mixed and mixed.leases or {}) do n = n + 1 end
  check("registry: only well-formed leases are read (a number port, absolute paths, no control characters)",
        n == 1 and mixed.leases["/r/main/.claude/worktrees/ok"] ~= nil)
  eq("registry: the file is named for the main checkout", core.leaseFileName("/r/main"), "-r-main.json")
end

-- ---- when a lease is released (2026-09-29) ----
do
  local P = core.LEASE_PENDING_SECONDS
  check("release: a worktree that is there keeps its lease", not core.leaseReleaseDue({ at = 1, seen = true }, true, 10 ^ 9))
  check("release: a worktree seen and now gone is released", core.leaseReleaseDue({ at = 100, seen = true }, false, 101))
  check("release: a lease whose worktree hasn't been made yet waits (the tab hasn't run EnterWorktree)",
        not core.leaseReleaseDue({ at = 100 }, false, 100 + P - 1))
  check("release: ...but not forever", core.leaseReleaseDue({ at = 100 }, false, 100 + P))
  check("release: a day, at least", P >= 86400)
end

-- ---- what the session is told (2026-09-29) ----
local LEASE = { port = 4107, db = "/Users/u/.claude/cc-lease/db/main-a-4107.db", at = 1 }
do
  local wt = "/r/main/.claude/worktrees/a"
  local text = core.leaseEnvText(wt, LEASE)
  check("env file: PORT=", has(text, "\nPORT=4107\n"))
  check("env file: DB_PATH=", has(text, "\nDB_PATH=/Users/u/.claude/cc-lease/db/main-a-4107.db\n"))
  check("env file: says whose it is", has(text, wt))
  eq("env file: named shepherd-lease.env", core.LEASE_ENV_FILE, "shepherd-lease.env")
  -- sourced for real: what a project gets
  local T
  do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
  local function sourced(t)
    local f = io.open(T .. "/e.env", "w"); f:write(t); f:close()
    local p = io.popen("sh -c 'set -a; . \"" .. T .. "/e.env\"; printf \"%s|%s\" \"$PORT\" \"$DB_PATH\"' 2>&1")
    local out = p:read("*a"); p:close()
    return out
  end
  eq("env file: a shell that sources it gets both", sourced(text), "4107|/Users/u/.claude/cc-lease/db/main-a-4107.db")
  local odd = { port = 4108, db = "/Users/u u/it's $HOME/db.db" }
  eq("env file: a path with a space, a quote or a $ comes through as it is",
     sourced(core.leaseEnvText(wt, odd)), "4108|/Users/u u/it's $HOME/db.db")
  os.execute('rm -r "' .. T .. '"')

  eq("gitdir: an absolute gitdir line", core.gitdirFromDotGit(wt, "gitdir: /r/main/.git/worktrees/a\n"), "/r/main/.git/worktrees/a")
  eq("gitdir: a relative one is the worktree's", core.gitdirFromDotGit(wt, "gitdir: ../../../.git/worktrees/a"),
     wt .. "/../../../.git/worktrees/a")
  check("gitdir: anything else is nil", core.gitdirFromDotGit(wt, "nope") == nil and core.gitdirFromDotGit(wt, nil) == nil)

  local line = core.leasePromptLine(LEASE)
  check("prompt line: states the port and the database path",
        has(line, "PORT=4107") and has(line, "DB_PATH=/Users/u/.claude/cc-lease/db/main-a-4107.db"))
  check("prompt line: ...and where the env file is", has(line, "$(git rev-parse --git-dir)/shepherd-lease.env"))
  eq("prompt line: no lease, no line", core.leasePromptLine(nil), "")

  local req = { branch = "feat/a", slug = "a" }
  local p = core.worktreeTabPrompt(req, "Do the thing.", LEASE)
  check("New worktree tab prompt: states the lease", has(p, "PORT=4107") and has(p, "Do the thing."))
  check("...and is still Shepherd's own unit prompt (its tab closes after the merge)", core.isUnitTabPrompt(p))
  check("...a full task never cuts the lease", has(core.worktreeTabPrompt(req, string.rep("x", 9000), LEASE), "PORT=4107"))
  eq("...with no lease it reads as before", core.worktreeTabPrompt(req, "Do the thing.", nil), core.worktreeTabPrompt(req, "Do the thing."))
  check("...and says nothing of one", not has(core.worktreeTabPrompt(req, "Do the thing."), "leased"))
  local ep = core.enterWorktreePrompt(wt, "feat/a", LEASE)
  check("Instances Open prompt: states the lease", has(ep, "PORT=4107") and core.isUnitTabPrompt(ep))
  check("...none without one", not has(core.enterWorktreePrompt(wt, "feat/a"), "leased"))
  local batch = { title = "B9", driver = { name = "drv" }, units = { { slug = "a", branch = "feat/a", task = "Add a." } } }
  local msg = core.fleetUnitMessage(batch, batch.units[1], LEASE)
  check("fleet unit message: states the lease", has(msg, "PORT=4107") and has(msg, "DB_PATH=") and has(msg, "Add a."))
  check("...none without one", not has(core.fleetUnitMessage(batch, batch.units[1]), "leased"))

  local files = core.leaseDbFiles("/d/db/main-a-4107.db", "/d/db/")
  eq("db files: a released lease's database and its SQLite sidecars", table.concat(files, " "),
     "/d/db/main-a-4107.db /d/db/main-a-4107.db-wal /d/db/main-a-4107.db-shm /d/db/main-a-4107.db-journal")
  eq("db files: never one outside the database folder", #core.leaseDbFiles("/etc/main-a-4107.db", "/d/db"), 0)
  eq("db files: never one in a folder under it", #core.leaseDbFiles("/d/db/sub/x.db", "/d/db"), 0)
  eq("db files: never one that isn't a .db Shepherd could have named", #core.leaseDbFiles("/d/db/notes.txt", "/d/db"), 0)
end

-- ---- Settings Save keeps the hand-set lease keys (2026-09-29) ----
do
  local cfg = { lease = { enabled = true, portFrom = 5000, portTo = 5099, dbDir = "/x/db" } }
  local out = core.overlayConfig(cfg, { lease = { enabled = false } })
  check("settings save: lease.portFrom/portTo/dbDir survive a form that rebuilds lease",
        out.lease.portFrom == 5000 and out.lease.portTo == 5099 and out.lease.dbDir == "/x/db" and out.lease.enabled == false)
end

-- ---- the shipped FX lease block, on real files (2026-09-29) ----
local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local body = src:match("\n(FX%.LEASE_DIR = .-\nfunction FX%.sweepLeases%(cfg%).-\nend\n)")
check("the panel ships the lease block (FX.LEASE_DIR .. FX.sweepLeases)", body ~= nil)
if not body then finish() end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
do local p = io.popen('cd "' .. T .. '" && pwd -P'); T = p:read("*l"); p:close() end   -- /private/tmp on macOS
local LD, DB = T .. "/cc-lease", T .. "/db"
local MAIN = T .. "/main"
local WA, WB = MAIN .. "/.claude/worktrees/a", MAIN .. "/.claude/worktrees/b"
local function sh(cmd) return os.execute(cmd .. " >/dev/null 2>&1") end
local function write(path, s) local h = io.open(path, "w"); if h then h:write(s); h:close() end end
local function exists(p) local h = io.open(p, "r"); if h then h:close(); return true end; return false end
local function isDir(p) return os.execute('test -d "' .. p .. '"') == true end
local function readAll(p) local h = io.open(p, "r"); if not h then return nil end; local c = h:read("*a"); h:close(); return c end
check("a real repo with a linked worktree", sh(([[
  git init -q "%s" && cd "%s" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init &&
  git worktree add -q "%s" -b feat/a]]):format(MAIN, MAIN, WA)))

local calls = { alert = {}, logs = {} }
local FX = {}
local NOW = 1000
FX.now = function() return NOW end
FX.readFile = readAll
FX.readDir = function(path)
  local out, p = {}, io.popen('ls -1a "' .. path .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  return out
end
FX.mkdirP = function(path) return sh('mkdir -p "' .. path .. '"') == true end
FX.alert = function(msg) calls.alert[#calls.alert + 1] = msg end
local hs = { fs = { attributes = function(path, what)
  local mode = isDir(path) and "directory" or (exists(path) and "file" or nil)
  if not mode then return nil end
  if what then return (what == "mode") and mode or nil end
  return { mode = mode }
end } }
local realGetenv = os.getenv
local env = setmetatable({ FX = FX, core = core, hs = hs,
  print = function(s) calls.logs[#calls.logs + 1] = tostring(s) end,
  os = setmetatable({ getenv = function(k)
    if k == "CC_LEASE_DIR" then return LD end
    if k == "HOME" then return T end
    return realGetenv(k) end }, { __index = os }) }, { __index = _G })
local chunk = assert(load(body, "=leases", "t", env))
chunk()
local CFG = { lease = { portFrom = 4100, portTo = 4102, dbDir = DB } }
local NAME = core.leaseFileName(MAIN)
local function reg() return core.parseLeases(readAll(LD .. "/" .. NAME), MAIN) end
local function gitDirOf(wt)
  local p = io.popen('git -C "' .. wt .. '" rev-parse --path-format=absolute --git-dir 2>/dev/null')
  local out = p and p:read("*l"); if p then p:close() end
  return out
end
local function tmps()
  local n = 0
  for _, fn in ipairs(FX.readDir(LD)) do if fn:find(".tmp.", 1, true) then n = n + 1 end end
  return n
end

-- mint: into the registry, atomically, and into the worktree's env file when it exists
local la = FX.mintLease(MAIN, WA, CFG)
eq("FX.mintLease: the lowest port of the range", la and la.port, 4100)
eq("FX.mintLease: the registry holds it", reg() and reg().leases[WA] and reg().leases[WA].port, 4100)
eq("FX.mintLease: no torn write left behind", tmps(), 0)
check("FX.mintLease: the database folder exists, ready for the project", isDir(DB))
local envA = (gitDirOf(WA) or "?") .. "/shepherd-lease.env"
check("FX.mintLease: an existing worktree gets $(git rev-parse --git-dir)/shepherd-lease.env", exists(envA))
check("...holding its PORT and DB_PATH", has(readAll(envA), "\nPORT=4100\n") and has(readAll(envA), "\nDB_PATH=" .. DB .. "/main-a-4100.db\n"))
eq("FX.mintLease: again for the same worktree, the same lease", (FX.mintLease(MAIN, WA, CFG) or {}).port, 4100)

-- a worktree a New worktree tab hasn't made yet: leased, no env file until it exists
local lb = FX.mintLease(MAIN, WB, CFG)
eq("FX.mintLease: a worktree still to be made gets the next port", lb and lb.port, 4101)
check("...and waits for its env file (there is no git dir yet)", not isDir(WB))
eq("FX.mintLease: nothing while leases are off", FX.mintLease(MAIN, MAIN .. "/.claude/worktrees/z", { lease = { enabled = false } }), nil)

-- the tick: each session in a leased worktree carries its lease; the card shows it
check("a session enters the second worktree", sh(('cd "%s" && git worktree add -q "%s" -b feat/b'):format(MAIN, WB)))
local list = {
  { key = "ka", mainRoot = MAIN, wtRoot = WA },
  { key = "kb", mainRoot = MAIN, wtRoot = WB },
  { key = "km", mainRoot = MAIN, wtRoot = MAIN, isMainWt = true },
  { key = "kr", remote = "box", mainRoot = MAIN, wtRoot = WA },
  { key = "kx", cwd = "/elsewhere" },
}
FX.stepLeases(list, CFG)
eq("FX.stepLeases: a session in a leased worktree carries its port", list[1].lease and list[1].lease.port, 4100)
eq("...and its database path", list[1].lease and list[1].lease.db, DB .. "/main-a-4100.db")
eq("...the second one its own", list[2].lease and list[2].lease.port, 4101)
check("...the main checkout none", list[3].lease == nil)
check("...a remote tile none", list[4].lease == nil)
check("...a session in no repo none", list[5].lease == nil)
local envB = (gitDirOf(WB) or "?") .. "/shepherd-lease.env"
check("FX.stepLeases: a worktree that appeared gets its env file at once", has(readAll(envB), "\nPORT=4101\n"))
FX.stepLeases(list, { lease = { enabled = false, portFrom = 4100, portTo = 4102, dbDir = DB } })
check("FX.stepLeases: nothing is shown while leases are off", list[1].lease == nil and list[2].lease == nil)

-- the sweep: seen, then released once the worktree goes -- with the database Shepherd named
local lc = FX.mintLease(MAIN, MAIN .. "/.claude/worktrees/c", CFG)
eq("a third worktree, never made, takes the last port", lc and lc.port, 4102)
FX.sweepLeases(CFG)
check("FX.sweepLeases: a worktree that exists is marked seen", reg().leases[WA].seen == true and reg().leases[WB].seen == true)
check("FX.sweepLeases: one not made yet isn't", not reg().leases[MAIN .. "/.claude/worktrees/c"].seen)
write(DB .. "/main-a-4100.db", "sqlite"); write(DB .. "/main-a-4100.db-wal", "wal")
write(T .. "/keep.db", "not Shepherd's")
check("the first unit merges and its worktree goes", sh(('cd "%s" && git worktree remove --force "%s"'):format(MAIN, WA)))
FX.sweepLeases(CFG)
check("FX.sweepLeases: the gone worktree's lease is released", reg().leases[WA] == nil)
check("...its database file goes with it", not exists(DB .. "/main-a-4100.db"))
check("...and its SQLite sidecar", not exists(DB .. "/main-a-4100.db-wal"))
check("...the others stay", reg().leases[WB] ~= nil and reg().leases[MAIN .. "/.claude/worktrees/c"] ~= nil)
check("...and nothing outside the database folder is touched", exists(T .. "/keep.db"))
eq("FX.mintLease: the released port is the lowest free one again", (FX.mintLease(MAIN, MAIN .. "/.claude/worktrees/d", CFG) or {}).port, 4100)
check("FX.mintLease: the range is full now", FX.mintLease(MAIN, MAIN .. "/.claude/worktrees/e", CFG) == nil)
NOW = NOW + core.LEASE_PENDING_SECONDS
FX.sweepLeases(CFG)
check("FX.sweepLeases: a lease whose worktree was never made is released after the grace", reg().leases[MAIN .. "/.claude/worktrees/c"] == nil
      and reg().leases[MAIN .. "/.claude/worktrees/d"] == nil)
check("...the live one stays", reg().leases[WB] ~= nil)
-- a hand-edited lease naming a file outside the database folder: released, the file left alone
do
  local r = reg()
  r.leases[T .. "/gone-wt"] = { port = 4109, db = T .. "/keep.db", at = 1, seen = true }
  write(LD .. "/" .. NAME, core.encodeLeases(r))
end
FX.sweepLeases(CFG)
check("FX.sweepLeases: a lease naming a database outside the folder is released", reg().leases[T .. "/gone-wt"] == nil)
check("...and that file is never deleted", exists(T .. "/keep.db"))
check("the second unit merges too", sh(('cd "%s" && git worktree remove --force "%s"'):format(MAIN, WB)))
FX.sweepLeases(CFG)
check("FX.sweepLeases: a registry with no lease left is removed", not exists(LD .. "/" .. NAME))

-- both removers: what nothing can use
write(LD .. "/-nowhere.json", '{"v":1,"leases":{}}')
write(LD .. "/-wrong-name.json", core.encodeLeases({ main = MAIN, leases = { [WA] = { port = 4100, db = DB .. "/x.db" } } }))
write(LD .. "/-r-main.json.tmp.4242", '{"v":')
local live = core.leaseFileName(T .. "/live")
write(LD .. "/" .. live, core.encodeLeases({ main = T .. "/live", leases = { [T .. "/live-x"] = { port = 4100, db = DB .. "/x.db" } } }))
FX.pruneLeaseFiles()
check("FX.pruneLeaseFiles: a file that names no checkout goes", not exists(LD .. "/-nowhere.json"))
check("...so does one whose name isn't its checkout's", not exists(LD .. "/-wrong-name.json"))
check("...and a torn write", not exists(LD .. "/-r-main.json.tmp.4242"))
check("...a live repo's leases stay", exists(LD .. "/" .. live))
check("the sweep logs each release", (function()
  for _, l in ipairs(calls.logs) do if has(l, "released") and has(l, WA) then return true end end
  return false end)())

os.execute('rm -r "' .. T .. '"')
finish()
