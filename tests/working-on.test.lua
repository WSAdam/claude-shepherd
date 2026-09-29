-- working-on.test.lua : BEHAVIORAL fixture for the tick's working-on cache (2026-09-29, build
-- program unit 10). Runs the REAL shipped FX.workingOnFor / FX.reapWorkingOn, sliced out of
-- claude-dashboard.lua and loaded against a recorded hs.fs / FX.readTail / FX.sessionFirstPrompt,
-- so there is no copy of the rule to drift. The tick reads a 64KB tail for working and fresh
-- sessions every second; the label and skill must come from THAT tail, parsed again only when the
-- transcript's mtime moves, with no read of its own unless the tick had none -- and a batch unit's
-- first prompt (its only prompt) is read once per transcript.
--
-- Usage: lua tests/working-on.test.lua [path/to/claude-dashboard.lua]

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
local function finish() print("-- working-on.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local f = io.open((arg and arg[1]) or (ROOT .. "claude-dashboard.lua"), "r")
local src = f and f:read("*a") or ""
if f then f:close() end
local body = src:match("\n(FX%._workingOn = {}.-\nfunction FX%.reapWorkingOn%(list%).-\nend\n)")
check("the panel ships FX.workingOnFor and FX.reapWorkingOn", body ~= nil)
if not body then finish() end

-- the recorded world: mtimes, transcript tails, first prompts, and every read
local mtimes, tails, firsts = {}, {}, {}
local reads = { stat = 0, tail = 0, first = 0 }
local FX = {}
FX.readTail = function(path) reads.tail = reads.tail + 1; return tails[path] end
FX.sessionFirstPrompt = function(it) reads.first = reads.first + 1; return firsts[it.transcript_path] end
local env = setmetatable({ FX = FX, core = core, ACTIVITY_BYTES = 65536,
  hs = { fs = { attributes = function(path, what)
    reads.stat = reads.stat + 1
    return what == "modification" and mtimes[path] or nil
  end } } }, { __index = _G })
local chunk = assert(load(body, "=workingOnFor", "t", env))
chunk()

local function L(t) return core.json.encode(t) .. "\n" end
local function lp(text) return L({ type = "last-prompt", lastPrompt = text, leafUuid = "u" }) end
local function asst(skill) return L({ type = "assistant", attributionSkill = skill, message = { role = "assistant", content = { { type = "text", text = "x" } } } }) end
local NOW = 1000

-- a working session: the tick hands over its tail
local it = { key = "a", transcript_path = "/t/a.jsonl", status = "working", tool_name = "Bash", tool_started_at = 990 }
mtimes["/t/a.jsonl"] = 1
local v = FX.workingOnFor(it, lp("Fix the tile layout") .. asst("dataviz"), NOW)
check("the label and skill come from the tick's tail", v and v.label == "Fix the tile layout" and v.skill == "dataviz")
check("...with the tool in flight from the status file", v and v.tool == "Bash" and v.toolSecs == 10)
eq("...and no read of its own", reads.tail, 0)

v = FX.workingOnFor(it, lp("a different tail, same mtime"), NOW)
eq("an unchanged mtime keeps the cached label (the tail isn't parsed again)", v and v.label, "Fix the tile layout")

mtimes["/t/a.jsonl"] = 2
v = FX.workingOnFor(it, lp("Now wire the chips") .. asst(nil), NOW)
eq("a moved mtime parses the new tail", v and v.label, "Now wire the chips")
eq("...and a newest assistant record with no skill clears it", v and v.skill, nil)

-- an idle session: the tick read no tail
local idle = { key = "b", transcript_path = "/t/b.jsonl", status = "idle", tool_name = "Bash", tool_started_at = 900 }
mtimes["/t/b.jsonl"] = 5
tails["/t/b.jsonl"] = lp("Write the docs page")
v = FX.workingOnFor(idle, nil, NOW)
eq("no tail from the tick: the transcript is read once", reads.tail, 1)
eq("...for its label", v and v.label, "Write the docs page")
FX.workingOnFor(idle, nil, NOW); FX.workingOnFor(idle, nil, NOW)
eq("...and not again while its mtime holds", reads.tail, 1)
mtimes["/t/b.jsonl"] = 6
tails["/t/b.jsonl"] = lp("Write the docs page") .. lp("Then the changelog")
v = FX.workingOnFor(idle, nil, NOW)
check("...again when it moves", reads.tail == 2 and v and v.label == "Then the changelog")
eq("a tool stamp on an idle session is no tool in flight", v and v.tool, nil)

-- a batch unit: only ever messaged, never typed to
local unit = { key = "c", transcript_path = "/t/c.jsonl", status = "working",
               last_prompt = "[shepherd] continue" }
mtimes["/t/c.jsonl"] = 1
firsts["/t/c.jsonl"] = 'Another Claude session sent a message:\n<cross-session-message from="uds:/tmp/d.sock">\n'
  .. 'Start unit feat/working-on-label in its own worktree: call EnterWorktree with name "working-on-label"\n</cross-session-message>'
v = FX.workingOnFor(unit, L({ type = "last-prompt", leafUuid = "u" }), NOW)
eq("a batch unit reads as its unit, from its first prompt", v and v.label, "unit feat/working-on-label")
eq("...read once", reads.first, 1)
mtimes["/t/c.jsonl"] = 2
FX.workingOnFor(unit, L({ type = "last-prompt", leafUuid = "v" }), NOW)
mtimes["/t/c.jsonl"] = 3
v = FX.workingOnFor(unit, L({ type = "last-prompt", leafUuid = "w" }), NOW)
eq("...and never again for the same transcript, however often it changes", reads.first, 1)
eq("...still labelled", v and v.label, "unit feat/working-on-label")

-- a session with a typed prompt never reads its head
local typed = { key = "d", transcript_path = "/t/d.jsonl", status = "done", last_prompt = "Ship it" }
mtimes["/t/d.jsonl"] = 1
v = FX.workingOnFor(typed, "", NOW)
check("the status file's last_prompt covers a tail with no typed prompt, no head read",
      v and v.label == "Ship it" and reads.first == 1)

-- remote tiles: their transcript path is a REMOTE path, never read here
local stats = reads.stat
local remote = { key = "r", transcript_path = "/t/r.jsonl", remote = { host = "box" }, status = "working",
                 last_prompt = "Deploy the box", tool_name = "Bash", tool_started_at = 999 }
v = FX.workingOnFor(remote, nil, NOW)
check("a remote tile is neither stat'ed nor read", reads.stat == stats and reads.tail == 2 and reads.first == 1)
check("...and still says what it's working on, from its status file", v and v.label == "Deploy the box" and v.tool == "Bash")

-- the cache follows the fleet
FX.reapWorkingOn({ { key = "a" }, { key = "c" } })
check("ended sessions leave the cache", FX._workingOn.a ~= nil and FX._workingOn.c ~= nil
      and FX._workingOn.b == nil and FX._workingOn.d == nil)
eq("no key, no view", FX.workingOnFor({ transcript_path = "/t/x" }, nil, NOW), nil)

finish()
