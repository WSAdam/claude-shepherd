-- pins.test.lua : BEHAVIORAL fixture for pinned links on the panel side (2026-09-29, build program
-- unit 31). Runs the REAL shipped FX pin block (FX.PINS_DIR .. FX.prunePins), sliced out of
-- claude-dashboard.lua and loaded against a recorded hs (the working-on.test.lua pattern), over real
-- files in a temp dir. The tick stamps each local session's worktree pins on it (it.pins); a chip's
-- click opens an http(s) link in the browser and a file with /usr/bin/open given an argv -- never a
-- shell string -- after checking the link again, the file's REAL path included; a verified merge
-- clears the unit's pins; the removers drop the pins of a worktree that is gone.
--
-- Usage: lua tests/pins.test.lua [path/to/claude-dashboard.lua]

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
local function finish() print("-- pins.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local body = src:match("\n(FX%.PINS_DIR = .-\nfunction FX%.prunePins%(%).-\nend\n)")
check("the panel ships the pinned-links block (FX.PINS_DIR .. FX.prunePins)", body ~= nil)
if not body then finish() end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local PINS = T .. "/cc-pins"
local R, R2, GONE = T .. "/repo", T .. "/repo2", T .. "/gone-wt"
os.execute(('mkdir -p "%s" "%s/docs" "%s" "%s/outside"'):format(PINS, R, R2, T))
local function write(path, s) local h = io.open(path, "w"); if h then h:write(s); h:close() end end
local function exists(p) local h = io.open(p, "r"); if h then h:close(); return true end; return false end
write(R .. "/docs/b.md", "b\n")

-- the recorded world
local calls = { openURL = {}, task = {}, started = 0, execute = 0, alert = {}, gitRoot = 0 }
local realpaths = {}   -- path -> what pathToAbsolute says (default: itself when it exists)
local FX = {}
local NOW = 1000
FX.now = function() return NOW end
FX.readFile = function(path) local h = io.open(path, "r"); if not h then return nil end; local c = h:read("*a"); h:close(); return c end
FX.readDir = function(path)
  local out, p = {}, io.popen('ls -1a "' .. path .. '" 2>/dev/null')
  if p then for line in p:lines() do out[#out + 1] = line end; p:close() end
  return out
end
FX.alert = function(msg) calls.alert[#calls.alert + 1] = msg end
FX.gitRoot = function(cwd) calls.gitRoot = calls.gitRoot + 1; if cwd == R .. "/docs" then return R end; return nil end
local hs = {
  fs = {
    attributes = function(path, what)
      local isDir = os.execute('test -d "' .. path .. '"')
      local mode = isDir and "directory" or (exists(path) and "file" or nil)
      if not mode then return nil end
      if what then return (what == "mode") and mode or nil end
      return { mode = mode }
    end,
    pathToAbsolute = function(path)
      if realpaths[path] ~= nil then return realpaths[path] or nil end
      return (exists(path) or os.execute('test -d "' .. path .. '"')) and path or nil
    end,
  },
  urlevent = { openURL = function(u) calls.openURL[#calls.openURL + 1] = u end },
  task = { new = function(exe, cb, args)
    calls.task[#calls.task + 1] = { exe = exe, cb = cb, args = args }
    return { start = function(self) calls.started = calls.started + 1; return self end }
  end },
  execute = function() calls.execute = calls.execute + 1; return "" end,
}
local realGetenv = os.getenv
local env = setmetatable({ FX = FX, core = core, hs = hs, print = function() end,
  os = setmetatable({ getenv = function(k) if k == "CC_PINS_DIR" then return PINS end; return realGetenv(k) end },
                    { __index = os }) }, { __index = _G })
local chunk = assert(load(body, "=pins", "t", env))
chunk()
eq("FX.PINS_DIR honours CC_PINS_DIR", FX.PINS_DIR, PINS)

local function pinsFile(root, pins) return core.json.encode({ v = 1, root = root, pins = pins }) end
local PFILE = PINS .. "/" .. core.pinFileName(R)
write(PFILE, pinsFile(R, {
  { url = "https://github.com/o/r/pull/12", kind = "http", at = 1 },
  { url = "file://" .. R .. "/docs/b.md", kind = "file", label = "Spec", at = 2 },
}))

-- ---- the tick: each local session's worktree pins ----
local A = { key = "a", wtRoot = R }
local B = { key = "b", wtRoot = R2 }
local C = { key = "c", wtRoot = R, remote = { host = "box" } }
local D = { key = "d", cwd = R .. "/docs" }          -- not stacked: its git root, found once
local list = { A, B, C, D }
FX.stepPins(list)
eq("stepPins: a session in the worktree gets its pins", A.pins and #A.pins, 2)
check("...each with its label (a default one when none was given)", A.pins and A.pins[1].label == "PR #12" and A.pins[2].label == "Spec")
check("...and nothing the panel doesn't need", A.pins and A.pins[2].path == nil and A.pins[2].at == nil)
eq("stepPins: a worktree with no pins file: none", B.pins, nil)
eq("stepPins: a remote session: none", C.pins, nil)
eq("stepPins: a session with no stack root finds its worktree through its git root", D.pins and #D.pins, 2)

write(PFILE, pinsFile(R, { { url = "http://localhost:5173/", kind = "http", at = 3 } }))
FX.stepPins(list)
eq("stepPins: a change waits for the next look (2s)", A.pins and #A.pins, 2)
NOW = NOW + 2
FX.stepPins(list)
eq("stepPins: ...and then shows", A.pins and #A.pins, 1)
eq("...its label", A.pins and A.pins[1].label, "localhost:5173")

write(PFILE, pinsFile("/some/other-root", { { url = "https://x.example/", kind = "http", at = 1 } }))
NOW = NOW + 2
FX.stepPins(list)
eq("stepPins: another worktree's file under the same name shows nothing here", A.pins, nil)

write(PFILE, pinsFile(R, {
  { url = "https://github.com/o/r/pull/12", kind = "http", at = 1 },
  { url = "file://" .. R .. "/docs/b.md", kind = "file", at = 2 },
}))
NOW = NOW + 2
FX.stepPins(list)
eq("(fixture: two pins again)", A.pins and #A.pins, 2)

-- ---- a click ----
check("openPin: an http pin opens in the browser", FX.openPin(A, 1) == true and calls.openURL[1] == "https://github.com/o/r/pull/12")
eq("...and nothing else runs", #calls.task, 0)
check("openPin: a file pin opens with /usr/bin/open", FX.openPin(A, "2") == true and calls.task[1] and calls.task[1].exe == "/usr/bin/open")
check("...given an argv: the path is its one argument", calls.task[1] and #calls.task[1].args == 1 and calls.task[1].args[1] == R .. "/docs/b.md")
eq("...started", calls.started, 1)
eq("...and never through a shell", calls.execute, 0)
check("...the running task is held until it ends (not garbage-collected)", next(FX._pinTasks) ~= nil)
if calls.task[1] and calls.task[1].cb then calls.task[1].cb(0, "", "") end
eq("...and let go once it has", next(FX._pinTasks), nil)

realpaths[R .. "/docs/b.md"] = T .. "/outside/b.md"   -- a symlink swapped in after the pin
eq("openPin: a file whose real path leads outside the worktree is refused", FX.openPin(A, 2), false)
eq("...nothing opened", #calls.task, 1)
check("...and the panel says why", #calls.alert == 1 and calls.alert[1]:find("pin", 1, true) ~= nil)
realpaths[R .. "/docs/b.md"] = nil
eq("openPin: a number past the card's pins is refused", FX.openPin(A, 9), false)
eq("openPin: a remote session's pin is refused", FX.openPin(C, 1), false)
A.pins[1] = { url = "javascript:alert(1)", kind = "http", label = "x" }
eq("openPin: a pin that doesn't pass the check again is refused", FX.openPin(A, 1), false)
eq("...no browser", #calls.openURL, 1)
-- 2026-09-30: & was refused as a shell metacharacter, so a link with two query parameters never
-- reached the card. It opens by argv like every other link: the browser gets it whole.
A.pins[1] = { url = "https://github.com/o/r/pulls?q=is%3Aopen&sort=updated&page=2", kind = "http", label = "Open PRs" }
check("openPin: a link with a multi-parameter query opens whole",
      FX.openPin(A, 1) == true and calls.openURL[2] == "https://github.com/o/r/pulls?q=is%3Aopen&sort=updated&page=2")
eq("...in the browser, never through a shell", calls.execute, 0)

-- ---- a verified merge clears the unit's pins ----
local R2FILE = PINS .. "/" .. core.pinFileName(R2)
write(R2FILE, pinsFile("/not/r2", { { url = "https://keep.example/", kind = "http", at = 1 } }))
eq("clearPins: another worktree's file under the same name is left alone", FX.clearPins(R2, "merged"), false)
check("...it's still there", exists(R2FILE))
eq("clearPins: the merged worktree's pins go", FX.clearPins(R, "merged feat/x"), true)
check("...the file is gone", not exists(PFILE))
eq("clearPins: no pins: nothing to do", FX.clearPins(R, "merged"), false)

-- ---- both removers: the pins of a worktree that is gone ----
os.execute(('mkdir -p "%s"'):format(GONE))
write(PFILE, pinsFile(R, { { url = "https://live.example/", kind = "http", at = 1 } }))
local GFILE = PINS .. "/" .. core.pinFileName(GONE)
write(GFILE, pinsFile(GONE, { { url = "https://gone.example/", kind = "http", at = 1 } }))
write(GFILE .. ".tmp.4242", "{")
write(PINS .. "/torn.json", "not json")
os.execute(('rmdir "%s"'):format(GONE))
FX.prunePins()
check("prunePins: a live worktree keeps its pins (they outlive /clear)", exists(PFILE))
check("prunePins: a worktree that's gone loses its pins", not exists(GFILE))
check("...and their torn writes", not exists(GFILE .. ".tmp.4242"))
check("...and a pins file that names no worktree", not exists(PINS .. "/torn.json"))
check("...the other worktree's file, whose root isn't there either, goes too", not exists(R2FILE))

os.execute(('rm -r "%s"'):format(T))
finish()
