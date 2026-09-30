-- restart.test.lua : restart the fleet in place (build program unit 41, 2026-09-30).
-- 2026-09-30: a Claude Code update or a reboot takes every session down at once, and SessionEnd
-- deletes the status files -- so by the time anyone looked there was nothing to reopen from, and
-- each conversation had to be found and resumed by hand. Shepherd now keeps its own snapshot of the
-- fleet (~/.claude/cc-restart.json), plans a restart from it, shows the plan first (the dry run) and
-- reopens only what it can verify is dead, each session at most once.
-- Pure halves in core on literal status files (as the hooks write them), session files (as Claude
-- Code writes them) and ps / kitty output; then the real FX functions under a stubbed Hammerspoon in
-- a temp HOME: the snapshot file, the preview (which must do nothing), and a whole run with stubbed
-- windows, where the only thing that can "open" is a recorded hs.urlevent.openURL.
-- Nothing here touches a real session: HOME, the status dir and the session files are temp dirs.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end
local function finish()
  print(string.format("-- restart.test.lua: %d run, %d failed --", run, failed))
  os.exit(failed == 0 and 0 or 1)
end

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local HOME = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(HOME ~= "", "could not mktemp a HOME")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = core.json or json

local API = { "restartIdOk", "restartEntry", "parseRestartSnapshot", "restartSnapshotJson", "restartSnapshotStep",
              "restartApplyRegistry", "restartPsCmd", "parsePsLstart", "restartLiveness", "restartPlan",
              "restartPlanText", "restartTabUri", "kittyWindowIdle", "restartShellLine", "restartTerminalScript",
              "restartContinueDue", "restartContinueTile", "restartProbePids", "restartShellProbeCmd", "restartApplyShell" }
local shipped = type(core.RESTART) == "table"
for _, name in ipairs(API) do if type(core[name]) ~= "function" then shipped = false end end
check("core ships restart in place (the snapshot, the plan, the launch lines)", shipped)
if not shipped then sh("rm -r " .. q(HOME)); finish() end

-- ---- the literal fixtures: status files as cc-status.sh writes them --------------------------------
local NOW = 1790761000
local A = "11111111-aaaa-4bbb-8ccc-000000000001"   -- a VS Code tab, mid-turn
local B = "22222222-aaaa-4bbb-8ccc-000000000002"   -- a VS Code tab that entered a worktree, finished
local C = "33333333-aaaa-4bbb-8ccc-000000000003"   -- a kitty session, mid-turn
local D = "44444444-aaaa-4bbb-8ccc-000000000004"   -- a Terminal session waiting on an approval
local STATUS = {
  [A] = '{"session_id":"' .. A .. '","name":"shop","cwd":"/Users/u/code/shop","status":"working","updated":' .. (NOW - 5)
    .. ',"since":' .. (NOW - 60) .. ',"transcript_path":"/Users/u/.claude/projects/-Users-u-code-shop/' .. A .. '.jsonl",'
    .. '"editor":"vscode","host_window":"501","session_pid":"611","last_prompt":"fix the cart","permission_mode":"acceptEdits",'
    .. '"mode_cycle":{"auto":true},"tool_name":"Bash","tool_use_id":"toolu_01","tool_started_at":' .. (NOW - 5) .. ',"effort":"xhigh"}',
  [B] = '{"session_id":"' .. B .. '","name":"fix-x","cwd":"/Users/u/code/shop/.claude/worktrees/fix-x","status":"done","updated":' .. (NOW - 400)
    .. ',"since":' .. (NOW - 400) .. ',"transcript_path":"/Users/u/.claude/projects/-Users-u-code-shop--claude-worktrees-fix-x/' .. B .. '.jsonl",'
    .. '"editor":"vscode","host_window":"501","session_pid":"612","permission_mode":"auto","effort":"high"}',
  [C] = '{"session_id":"' .. C .. '","name":"api","cwd":"/Users/u/code/api","status":"working","updated":' .. (NOW - 2)
    .. ',"since":' .. (NOW - 30) .. ',"transcript_path":"/Users/u/.claude/projects/-Users-u-code-api/' .. C .. '.jsonl",'
    .. '"editor":"kitty","kitty_window_id":"7","kitty_listen_on":"unix:/tmp/kitty-900","permission_mode":"default",'
    .. '"model":"claude-opus-5-5[1m]"}',
  [D] = '{"session_id":"' .. D .. '","name":"docs","cwd":"/Users/u/code/docs","status":"approval","updated":' .. (NOW - 9)
    .. ',"since":' .. (NOW - 9) .. ',"transcript_path":"/Users/u/.claude/projects/-Users-u-code-docs/' .. D .. '.jsonl",'
    .. '"editor":"terminal","permission_mode":"plan"}',
}
-- Claude Code's own session files (~/.claude/sessions/<pid>.json), by pid
local function regEntry(pid, id, start)
  return { pid = pid, sessionId = id, cwd = "/Users/u/code", startedAt = 1790612760698, procStart = start,
           version = "2.1.284", kind = "interactive", entrypoint = "cli", name = "s-" .. pid, status = "idle" }
end
local T_A, T_B, T_C, T_D = "Wed Sep 30 09:37:15 2026", "Wed Sep 30 09:40:00 2026", "Tue Sep 29 18:00:01 2026", "Mon Sep 28 16:25:59 2026"
local REG = { ["611"] = regEntry(611, A, T_A), ["612"] = regEntry(612, B, T_B),
              ["713"] = regEntry(713, C, T_C), ["814"] = regEntry(814, D, T_D) }

-- The tick's items for a set of status files (the real parse), with the origin the dashboard stamps.
local function items(ids, mutate)
  local files = {}
  for _, id in ipairs(ids) do files[#files + 1] = { key = id, content = STATUS[id] } end
  local list = core.parseStatusList(files, NOW)
  for _, it in ipairs(list) do
    if it.session_id == B then it.originDir = "/Users/u/code/shop" end
    if mutate then mutate(it) end
  end
  return list
end
local function entries(ids, mutate)
  local out, updated = {}, {}
  for _, it in ipairs(items(ids, mutate)) do
    local e = core.restartEntry(it, core.launchDirFor(it.projectKey, it.cwd, it.originDir))
    if e then out[#out + 1] = e; updated[e.id] = it.updated end
  end
  return out, updated
end
local function step(prev, ids, now, opts, mutate)
  local es, updated = entries(ids, mutate)
  opts = opts or {}
  opts.updated = opts.updated or updated
  return core.restartSnapshotStep(prev, es, now, opts)
end

-- ---- the snapshot on literal status fixtures (2026-09-30) -----------------------------------------
local snap, changed = step(nil, { A, B, C, D }, NOW)
check("snapshot: the first tick is a change (the file gets written)", changed == true)
local a, b, c, d = snap.sessions[A], snap.sessions[B], snap.sessions[C], snap.sessions[D]
check("snapshot: one entry per session id", a ~= nil and b ~= nil and c ~= nil and d ~= nil)
eq("snapshot: a session's folder", a and a.cwd, "/Users/u/code/shop")
eq("snapshot: its editor", a and a.editor, "vscode")
eq("snapshot: its window (the editor window's host pid)", a and a.window.host, "501")
eq("snapshot: ...and its own process", a and a.window.pid, "611")
eq("snapshot: its permission mode", a and a.mode, "acceptEdits")
eq("snapshot: a turn was in progress (status working)", a and a.turn, true)
eq("snapshot: a finished session has no turn in progress", b and b.turn, nil)
eq("snapshot: a session waiting on an approval is mid-turn too", d and d.turn, true)
eq("snapshot: the model the status file carries, suffix and all", c and c.model, "claude-opus-5-5[1m]")
eq("snapshot: no model on a session whose status file names none (the live one has no [1m])", a and a.model, nil)
eq("snapshot: a kitty session's window is its socket", c and c.window.kittyListenOn, "unix:/tmp/kitty-900")
eq("snapshot: ...and window id", c and c.window.kittyWindowId, "7")
eq("snapshot: a worktree tab lives in the window of the folder it started in", b and b.root, "/Users/u/code/shop")
eq("snapshot: ...and resumes from the folder whose project holds its transcript", b and b.dir, "/Users/u/code/shop/.claude/worktrees/fix-x")
eq("snapshot: nothing is ended while its status file is there", a and a.ended, nil)
check("snapshot: a remote tile is never in it",
      core.restartEntry({ session_id = A, cwd = "/x", name = "x", editor = "vscode", remote = true }) == nil)
check("snapshot: nor a tile with no session id",
      core.restartEntry({ cwd = "/x", name = "x", editor = "vscode" }) == nil)
check("snapshot: nor one whose id isn't a session id (it would reach a command line)",
      core.restartEntry({ session_id = "x; rm -rf ~", cwd = "/x", name = "x", editor = "kitty" }) == nil)

-- written only on a change
local same, ch2 = step(snap, { A, B, C, D }, NOW + 1)
eq("snapshot: the same fleet a tick later is no change (nothing is written)", ch2, false)
local _, ch3 = step(same, { A, B, C, D }, NOW + 2, nil, function(it) if it.session_id == A then it.status = "done" end end)
eq("snapshot: a turn that ends is a change", ch3, true)
local _, ch4 = step(same, { A, B, C, D }, NOW + 2, nil, function(it) if it.session_id == A then it.permission_mode = "plan" end end)
eq("snapshot: a permission mode that changes is a change", ch4, true)

-- Claude Code's session files fill in the process
for _, e in pairs(snap.sessions) do core.restartApplyRegistry(e, REG) end
eq("registry: a kitty session's pid comes from Claude Code's session file", snap.sessions[C].window.pid, "713")
eq("registry: ...with when that process started", snap.sessions[C].window.procStart, T_C)
eq("registry: a VS Code session keeps its pid and gains its start time", snap.sessions[A].window.procStart, T_A)
eq("registry: asked again, nothing changes", core.restartApplyRegistry(snap.sessions[A], REG), false)
local kept = step(snap, { A, B, C, D }, NOW + 3)
eq("registry: what it said stays on the entry across ticks (the status file never carries it)", kept.sessions[C].window.pid, "713")
snap = kept
-- 2026-09-30: a status file that outlived its process (no SessionEnd) keeps the dead one's
-- session_pid even after the session is resumed under another process -- cc-status.sh reads the
-- pid back from the file. The process Claude Code's own session file names is the one that counts.
local resumedReg = { ["955"] = regEntry(955, A, "Wed Sep 30 12:00:00 2026") }
local resumed = step(snap, { A, B, C, D }, NOW + 4)
eq("registry: a session resumed under another process takes that process", core.restartApplyRegistry(resumed.sessions[A], resumedReg), true)
eq("registry: ...its pid", resumed.sessions[A].window.pid, "955")
local nextTick = step(resumed, { A, B, C, D }, NOW + 5)   -- the status file still says session_pid 611
eq("registry: the status file's stale pid doesn't take it back on the next tick", nextTick.sessions[A].window.pid, "955")
eq("registry: ...nor its start time", nextTick.sessions[A].window.procStart, "Wed Sep 30 12:00:00 2026")

-- SessionEnd deletes the status file: the entry stays, stamped
local after1, chEnd = step(snap, { B }, NOW + 10)
eq("ended: a session whose status file is gone stays in the snapshot", after1.sessions[A] ~= nil, true)
eq("ended: ...stamped with when it went", after1.sessions[A].ended, NOW + 10)
eq("ended: ...still knowing a turn was in progress", after1.sessions[A].turn, true)
eq("ended: that is a change", chEnd, true)
local after2, chEnd2 = step(after1, { B }, NOW + 20)
eq("ended: the stamp doesn't move on later ticks", after2.sessions[A].ended, NOW + 10)
eq("ended: ...so nothing is rewritten", chEnd2, false)
local back = step(after2, { A, B }, NOW + 30)
eq("ended: a session whose status file is back is open again", back.sessions[A].ended, nil)
-- dropped by Shepherd itself (closed from the panel, pruned, respawned): forgotten
local forgot = step(snap, { B, C, D }, NOW + 10, { forget = { [A] = true } })
eq("forget: a session Shepherd dropped itself leaves the snapshot", forgot.sessions[A], nil)
eq("forget: ...the others stay", forgot.sessions[C] ~= nil, true)
-- kept for keepSeconds
local old = step(after1, { B }, NOW + 10 + core.RESTART.keepSeconds + 1)
eq("keep: an ended session leaves after keepSeconds", old.sessions[A], nil)
eq("keep: ...not before", step(after1, { B }, NOW + 10 + core.RESTART.keepSeconds - 1).sessions[A] ~= nil, true)
-- /clear keeps the process and mints a new id: the retired id is replaced, not lost
local CLEARED = "99999999-aaaa-4bbb-8ccc-000000000009"
local clearedEntry = core.restartEntry({ session_id = CLEARED, name = "shop", cwd = "/Users/u/code/shop", status = "idle",
  editor = "vscode", host_window = "501", session_pid = "611", updated = NOW + 40 })
local sup = core.restartSnapshotStep(after1, { clearedEntry }, NOW + 40, {})
eq("superseded: the id a /clear retired (same process, new id) is dropped", sup.sessions[A], nil)
eq("superseded: ...the new id is there", sup.sessions[CLEARED] ~= nil, true)

-- the file: round trip, and what a hand-edited or torn one does
local text = core.restartSnapshotJson(after1, NOW + 10)
local parsed = core.parseRestartSnapshot(text)
eq("file: it parses back", parsed.sessions[A] and parsed.sessions[A].ended, NOW + 10)
eq("file: ...with when it was written", parsed.written, NOW + 10)
eq("file: ...and the window", parsed.sessions[C] and parsed.sessions[C].window.kittyWindowId, "7")
eq("file: what was read back is what was written (nothing lost, nothing added)",
   core.tileSignature(parsed.sessions), core.tileSignature(after1.sessions))
check("file: the sessions are a list, in id order",
      text:find('"id":"' .. A, 1, true) < text:find('"id":"' .. B, 1, true) and text:find('"id":"' .. B, 1, true) < text:find('"id":"' .. C, 1, true))
eq("file: no file is an empty snapshot", next(core.parseRestartSnapshot(nil).sessions), nil)
eq("file: torn JSON is an empty snapshot", next(core.parseRestartSnapshot('{"version":1,"sessions":[{"id":"').sessions), nil)
local dupText = json.encode({ version = 1, written = 5, sessions = {
  { id = A, name = "shop", cwd = "/Users/u/code/shop", editor = "vscode", ended = 100, window = { pid = "611" } },
  { id = A, name = "shop", cwd = "/Users/u/code/shop", editor = "vscode", window = { pid = "611" } },
  { id = "bad id", name = "x", cwd = "/x", editor = "vscode", window = {} },
  { id = B, name = "rel", cwd = "relative/path", editor = "vscode", window = {} },
  { id = C, name = "api", cwd = "/Users/u/code/api", editor = "emacs", window = { pid = "7; rm -rf ~", tty = "/dev/ttys003; rm" } },
} })
local dup = core.parseRestartSnapshot(dupText)
local nDup = 0
for _ in pairs(dup.sessions) do nDup = nDup + 1 end
eq("file: a session id listed twice is ONE session", nDup, 2)
eq("file: ...the copy that is still open", dup.sessions[A] and dup.sessions[A].ended, nil)
eq("file: an id that isn't one, or a folder that isn't absolute, is not read", dup.sessions[B], nil)
eq("file: an unknown editor is no editor", dup.sessions[C] and dup.sessions[C].editor, nil)
eq("file: a pid that isn't digits is no pid", dup.sessions[C] and dup.sessions[C].window.pid, nil)
eq("file: a tty that isn't one is no tty", dup.sessions[C] and dup.sessions[C].window.tty, nil)

-- ---- ps: one probe, in Claude Code's own zone and locale ------------------------------------------
eq("ps: only digits reach the command, sorted, once each",
   core.restartPsCmd({ ["713"] = true, ["611"] = true, ["x; rm"] = true, [611] = true }),
   "LC_ALL=C TZ=UTC ps -o pid=,lstart= -p 611,713 2>/dev/null")
eq("ps: nothing to ask, no command", core.restartPsCmd({}), nil)
local ls = core.parsePsLstart("  611 Wed Sep 30 09:37:15 2026    \n 4242 Wed Sep 30 08:00:00 2026\n  713 Tue Sep 29 18:0")
eq("ps: a listed pid's start time", ls["611"], T_A)
eq("ps: a line torn mid-time is no answer", ls["713"], nil)
eq("ps: the probe asks about every process in the snapshot and its session files",
   (function() local n = 0; for _ in pairs(core.restartProbePids(snap, REG)) do n = n + 1 end; return n end)(), 4)

-- ---- verified dead ---------------------------------------------------------------------------------
local function facts(alive, registry, extra)
  local f = { now = NOW + 100, probed = true, registry = registry or {}, lstart = alive or {}, asked = {},
              exists = function() return true end, kittyState = function() return "gone" end }
  for p in pairs(core.restartProbePids(snap, registry or {})) do f.asked[p] = true end
  for p in pairs(alive or {}) do f.asked[p] = true end
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end
local eA = snap.sessions[A]
eq("alive: its session file names a process ps still shows", core.restartLiveness(eA, facts({ ["611"] = T_A }, REG)), "alive")
eq("alive: no session file, but its own process still runs", core.restartLiveness(eA, facts({ ["611"] = T_A }, {})), "alive")
eq("alive: resumed elsewhere -- another process holds the same session id",
   core.restartLiveness(eA, facts({ ["990"] = "Wed Sep 30 11:00:00 2026" }, { ["990"] = regEntry(990, A, "Wed Sep 30 11:00:00 2026") })), "alive")
eq("dead: not in the session files, and ps no longer lists its process", core.restartLiveness(eA, facts({}, {})), "dead")
eq("dead: a stale session file whose process is gone doesn't keep it alive", core.restartLiveness(eA, facts({}, REG)), "dead")
eq("dead: its pid is another process now (it started at another time)",
   core.restartLiveness(eA, facts({ ["611"] = "Wed Sep 30 12:00:00 2026" }, REG)), "dead")
local st, why = core.restartLiveness(eA, facts({}, {}, { probed = false }))
eq("unknown: ps never showed Shepherd's own pid -- nothing is verified", st, "unknown")
check("unknown: ...and it says why", type(why) == "string" and why ~= "")
eq("unknown: a process ps was never asked about", core.restartLiveness(eA, facts({}, {}, { asked = {} })), "unknown")
eq("unknown: no process on record at all",
   core.restartLiveness({ id = A, cwd = "/x", window = {} }, facts({}, {})), "unknown")
-- a pid only the status file named may be stale, and on a Claude Code with no session files "no
-- file names it" proves nothing: such a session is never called dead
eq("unknown: a process Claude Code's session files never named (only the status file did)",
   core.restartLiveness({ id = A, cwd = "/x", window = { pid = "611", host = "501" } }, facts({}, {}, { asked = { ["611"] = true } })), "unknown")

-- ---- the plan: alive vs verified dead, per editor, each id once -------------------------------------
-- everything went down: A, C, D ended together a minute ago; B's status file is still there (no SessionEnd)
local down = step(snap, { B }, NOW + 40)
local plan = core.restartPlan(down, facts({}, {}), {})
local byId = {}
for _, r in ipairs(plan.rows) do byId[r.id] = r end
eq("plan: every dead session would reopen", plan.reopen, 4)
eq("plan: a VS Code session reopens as its tab", byId[A].how, "tab")
check("plan: ...in the window of the folder it started in", byId[B].where:find("shop's VS Code window", 1, true) ~= nil)
eq("plan: a tab gets no Continue typed (nothing is typed into a VS Code window)", byId[A].continue, nil)
eq("plan: ...but the preview says a turn was in progress", byId[A].turn, true)
eq("plan: a kitty session whose window is gone gets a new kitty window", byId[C].how, "kitty-new")
eq("plan: ...running claude -r <its id>", byId[C].command, "claude -r " .. C)
eq("plan: ...then Continue, because a turn was in progress", byId[C].continue, true)
eq("plan: a Terminal session with no tab on record gets a new window", byId[D].how, "terminal-new")
eq("plan: a kitty session whose window is still at a shell prompt reopens in it",
   core.restartPlan(down, facts({}, {}, { kittyState = function() return "idle" end }), {}).rows[1] and
   (function() for _, r in ipairs(core.restartPlan(down, facts({}, {}, { kittyState = function() return "idle" end }), {}).rows) do
      if r.id == C then return r.how end end end)(), "kitty-window")
-- a Terminal tab is "its own" only while the very shell that ran claude is still there
local withTab = core.parseRestartSnapshot(core.restartSnapshotJson(down, NOW))
withTab.sessions[D].window.tty, withTab.sessions[D].window.shell, withTab.sessions[D].window.shellStart = "/dev/ttys004", "800", T_D
local function howOf(p, id) for _, r in ipairs(p.rows) do if r.id == id then return r.how end end end
eq("plan: a Terminal session whose shell is still there reopens in its tab",
   howOf(core.restartPlan(withTab, facts({ ["800"] = T_D }, {}), {}), D), "terminal-tab")
eq("plan: ...a new window when that shell is gone", howOf(core.restartPlan(withTab, facts({}, {}), {}), D), "terminal-new")
eq("plan: ...or when its pid is another process now",
   howOf(core.restartPlan(withTab, facts({ ["800"] = "Wed Sep 30 12:00:00 2026" }, {}), {}), D), "terminal-new")

-- alive is never reopened
plan = core.restartPlan(down, facts({ ["611"] = T_A, ["713"] = T_C }, REG), {})
byId = {}
for _, r in ipairs(plan.rows) do byId[r.id] = r end
eq("plan: a session that is alive is never reopened", byId[A].verdict, "skip")
eq("plan: ...and says so", byId[A].reason, "alive")
eq("plan: ...the kitty one too", byId[C].verdict, "skip")
eq("plan: ...while the dead ones still would", plan.reopen, 2)
-- nothing verified, nothing reopened
plan = core.restartPlan(down, facts({}, {}, { probed = false }), {})
eq("plan: a probe that can't be trusted reopens NOTHING", plan.reopen + plan.older, 0)
eq("plan: ...every session is left alone as unverified", plan.rows[1] and plan.rows[1].reason, "unverified")
-- already reopened: never twice
local stamped = core.parseRestartSnapshot(core.restartSnapshotJson(down, NOW))
stamped.sessions[A].restarted = NOW + 50
plan = core.restartPlan(stamped, facts({}, {}), {})
eq("plan: a session already reopened is not reopened again", howOf(plan, A), nil)
eq("plan: ...the rest still are", plan.reopen, 3)
-- its folder is gone
plan = core.restartPlan(down, facts({}, {}, { exists = function(p) return p ~= "/Users/u/code/api" end }), {})
byId = {}
for _, r in ipairs(plan.rows) do byId[r.id] = r end
eq("plan: a session whose folder is gone is left alone", byId[C].reason, "gone")
-- a gateway session whose provider profile is gone can't be rebuilt
local gw = core.parseRestartSnapshot(core.restartSnapshotJson(down, NOW))
gw.sessions[C].baseUrl = "https://gateway.example/v1"
eq("plan: a gateway session with no matching provider profile is left alone",
   (function() for _, r in ipairs(core.restartPlan(gw, facts({}, {}), { cfg = {} }).rows) do if r.id == C then return r.reason end end end)(), "provider")
-- a headless run (its session file's kind isn't "interactive") was never a window: not in the plan
local headless = core.parseRestartSnapshot(core.restartSnapshotJson(down, NOW))
eq("plan: the session files say what kind each session is", headless.sessions[C].kind, "interactive")
headless.sessions[C].kind = "print"
plan = core.restartPlan(headless, facts({}, {}), {})
eq("plan: a headless run is never offered for reopening", howOf(plan, C), nil)
eq("plan: ...it isn't even listed", #plan.rows, 3)
-- each id once, even from a snapshot that lists one twice
local twice = { sessions = { down.sessions[A], down.sessions[A], down.sessions[C] } }
plan = core.restartPlan(twice, facts({}, {}), {})
eq("plan: a session id listed twice is one row", #plan.rows, 2)
-- the last wave: a session closed long before the fleet went down is listed, not ticked
local waves = core.parseRestartSnapshot(core.restartSnapshotJson(down, NOW))
waves.sessions[A].ended = NOW - 5 * 3600      -- closed by hand this morning
waves.sessions[C].ended = NOW + 40
waves.sessions[D].ended = NOW + 40 - 10 * 60  -- ten minutes before the rest: the same wave
local onlyEnded = { sessions = { waves.sessions[A], waves.sessions[C], waves.sessions[D] } }
plan = core.restartPlan(onlyEnded, facts({}, {}), {})
byId = {}
for _, r in ipairs(plan.rows) do byId[r.id] = r end
eq("wave: a session closed hours before the rest is not ticked", byId[A].older, true)
eq("wave: ...it is still listed as something that could reopen", byId[A].verdict, "reopen")
eq("wave: what ended with the newest ending is", byId[D].older, nil)
eq("wave: the counts say so", plan.reopen .. "/" .. plan.older, "2/1")
eq("wave: reopen rows come first, then the older ones", plan.rows[#plan.rows].id, A)
-- ...and with a crash leftover (status file still there), "now" is the wave
plan = core.restartPlan(waves, facts({}, {}), {})
byId = {}
for _, r in ipairs(plan.rows) do byId[r.id] = r end
eq("wave: a session whose status file is still there is always in it", byId[B].older, nil)
eq("wave: ...and the wave is measured from now", byId[A].older, true)

-- the preview text: exactly what would reopen, where and how
local textPlan = core.restartPlanText(core.restartPlan(down, facts({ ["611"] = T_A }, REG), {}), NOW + 100)
check("preview: it says it is a dry run, with the counts", textPlan:find("dry run", 1, true) ~= nil and textPlan:find("3 would reopen", 1, true) ~= nil)
check("preview: a reopen line names the session, where, and the command",
      textPlan:find("reopen  api [kitty] " .. C .. " -- a new kitty window: claude -r " .. C .. ", then Continue", 1, true) ~= nil)
check("preview: a skipped line says why", textPlan:find("skip    shop [vscode] " .. A .. " -- it is running (pid 611)", 1, true) ~= nil)

-- ---- resume argv (2026-09-30) ------------------------------------------------------------------
eq("argv: spawnExtraFlags gains resume", table.concat(core.spawnExtraFlags({ resume = C }), " "), "-r " .. C)
eq("argv: ...first, before any variadic flag",
   table.concat(core.spawnExtraFlags({ resume = C, addDirs = { "/k" }, allowedTools = { "Read" } }), " "),
   "-r " .. C .. " --add-dir=/k --allowedTools=Read")
eq("argv: no resume, no flag (every other spawn is byte-identical)", #core.spawnExtraFlags({}), 0)
eq("argv: something that isn't a session id never reaches the command line", #core.spawnExtraFlags({ resume = "x; rm -rf ~" }), 0)
local spec = core.spawnSpec("kitty", "/Users/u/code/api", nil, { resume = C, permissionMode = "default", kittyBin = "kitty", claudeBin = "/bin/claude" })
eq("argv: a kitty relaunch is claude --permission-mode <mode> -r <id> in that folder",
   table.concat(spec.argv, " "):match("%-%-directory .*$"), "--directory /Users/u/code/api /bin/claude --permission-mode default -r " .. C)
spec = core.spawnSpec("terminal", "/Users/u/code/docs", nil, { resume = D, permissionMode = "plan" })
check("argv: a Terminal relaunch runs cd <folder> && claude ... -r <id>",
      spec.applescript:find("cd '/Users/u/code/docs' && claude --permission-mode plan -r " .. D, 1, true) ~= nil)
eq("line: the line typed into a session's own window",
   core.restartShellLine("/Users/u/code/my api", C, { permissionMode = "acceptEdits" }),
   "cd '/Users/u/code/my api' && claude --permission-mode acceptEdits -r " .. C)
eq("line: the model rides the env, as every spawn's does",
   core.restartShellLine("/p", C, { env = { { name = "ANTHROPIC_MODEL", value = "claude-opus-5-5[1m]", secret = false } } }),
   "cd '/p' && ANTHROPIC_MODEL='claude-opus-5-5[1m]' claude -r " .. C)
eq("line: nothing for an id that isn't one", core.restartShellLine("/p", "$(reboot)", {}), nil)
eq("line: nothing for a folder that isn't absolute", core.restartShellLine("p", C, {}), nil)
local script = core.restartTerminalScript("Terminal", "/dev/ttys004", "cd '/p' && claude -r " .. D)
check("terminal: the script runs the line in the tab on that tty, only while it is idle",
      script ~= nil and script:find('if (tty of t) is "/dev/ttys004" and (busy of t) is false then', 1, true) ~= nil
      and script:find("do script \"cd '/p' && claude -r " .. D .. "\" in t", 1, true) ~= nil)
check("terminal: ...and says whether it did", script ~= nil and script:find('return "tab"', 1, true) ~= nil and script:find('return "none"', 1, true) ~= nil)
eq("terminal: a tty that isn't one is no script", core.restartTerminalScript("Terminal", '/dev/ttys004" & do shell script "x', "ls"), nil)
-- the shell that ran a Terminal session, from one ps
eq("shell: only digits reach the probe", core.restartShellProbeCmd("12; rm"), nil)
check("shell: the probe asks about the session and its parent", (core.restartShellProbeCmd("814") or ""):find("p=814;", 1, true) == 1)
local term = { id = D, window = { pid = "814" } }
eq("shell: claude's parent shell, its start and their tty",
   core.restartApplyShell(term, "  814   800 ttys004  Mon Sep 28 16:25:59 2026\n  800   790 ttys004  Mon Sep 28 16:20:00 2026\n"), true)
eq("shell: ...the tty Terminal names its tab by", term.window.tty, "/dev/ttys004")
eq("shell: ...the shell's pid", term.window.shell, "800")
eq("shell: ...and when it started", term.window.shellStart, "Mon Sep 28 16:20:00 2026")
eq("shell: a session with no tty (a VS Code one) has no tab",
   core.restartApplyShell({ id = A, window = { pid = "611" } }, "  611   501 ??       Wed Sep 30 09:37:15 2026\n  501     1 ??       Wed Sep 30 09:00:00 2026\n"), false)

-- ---- the URI: a session id only through core.restartTabUri ----------------------------------------
eq("uri: VS Code", core.restartTabUri("com.microsoft.VSCode", A, "vscode"), "vscode://anthropic.claude-code/open?session=" .. A)
eq("uri: Cursor, by its bundle id", core.restartTabUri("com.todesktop.230313mzl4w4u92", A, "vscode"), "cursor://anthropic.claude-code/open?session=" .. A)
eq("uri: no bundle id, the editor kind", core.restartTabUri(nil, A, "cursor"), "cursor://anthropic.claude-code/open?session=" .. A)
eq("uri: nothing for an id that isn't one", core.restartTabUri("com.microsoft.VSCode", "a&prompt=rm", "vscode"), nil)
check("uri: the New-tab URI still can't carry a session (a prompt is percent-encoded)",
      core.claudeTabUri("com.microsoft.VSCode", "x&session=" .. A, "vscode") == "vscode://anthropic.claude-code/open?prompt=x%26session%3D" .. A)

-- ---- kitty: is the old window still there, at a shell prompt? --------------------------------------
local function kittyLs(procs)
  return json.encode({ { id = 1, tabs = { { id = 3, windows = { { id = 7, title = "zsh", cwd = "/Users/u/code/api",
    foreground_processes = procs } } } } } })
end
eq("kitty: one window, only its shell in front: idle", core.kittyWindowIdle(kittyLs({ { pid = 5, cmdline = { "-zsh" } } })), "idle")
eq("kitty: a shell by its full path", core.kittyWindowIdle(kittyLs({ { pid = 5, cmdline = { "/bin/bash", "-l" } } })), "idle")
eq("kitty: something running in it: busy", core.kittyWindowIdle(kittyLs({ { pid = 9, cmdline = { "claude" } } })), "busy")
eq("kitty: a shell with a job in front: busy", core.kittyWindowIdle(kittyLs({ { pid = 5, cmdline = { "-zsh" } }, { pid = 9, cmdline = { "vim", "x" } } })), "busy")
eq("kitty: no foreground processes reported: busy (can't tell)", core.kittyWindowIdle(kittyLs({})), "busy")
eq("kitty: no such window: gone", core.kittyWindowIdle("[]"), "gone")
eq("kitty: kitty said nothing (its socket is gone): gone", core.kittyWindowIdle(""), "gone")

-- ---- Continue: only once the reopened session is back ------------------------------------------
local p = { id = C, at = NOW }
eq("continue: not before a hook of the session has written since the relaunch", core.restartContinueDue(p, { session_id = C, updated = NOW - 50 }, NOW + 5), "wait")
eq("continue: no tile yet", core.restartContinueDue(p, nil, NOW + 5), "wait")
eq("continue: once it is back", core.restartContinueDue(p, { session_id = C, updated = NOW + 4 }, NOW + 5), "type")
eq("continue: dropped when it never comes back", core.restartContinueDue(p, nil, NOW + core.RESTART.continueSeconds + 1), "drop")
local tiles = { { session_id = A, key = A }, { session_id = "new-id", key = "new-id", editor = "kitty", kitty_window_id = "7", kitty_listen_on = "unix:/tmp/kitty-900" } }
eq("continue: its tile is the one with its session id", core.restartContinueTile({ id = A }, tiles), tiles[1])
eq("continue: ...or, relaunched in its own kitty window, the one in that window",
   core.restartContinueTile({ id = C, kittyWindowId = "7", kittyListenOn = "unix:/tmp/kitty-900" }, tiles), tiles[2])
eq("continue: a new window gives no window to match", core.restartContinueTile({ id = C }, tiles), nil)
check("continue: it is typed through the readiness check, as its own automation kind",
      core.AUTOMATION_TYPISTS.restart == "restart" and core.automationDryRun({ restart = { dryRun = true } }, "restart") == true)
eq("continue: a mid-turn session is never typed into (core.readyToType)",
   core.readyToType({ key = C, status = "working", updated = NOW }, nil, NOW + 10), false)

-- ---- the real FX functions under a stubbed Hammerspoon ------------------------------------------
local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "USER" then return "u" end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k == "CC_SESSIONS_DIR" then return HOME .. "/sessions" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end
sh("mkdir -p " .. q(HOME .. "/.claude/cc-scratch") .. " " .. q(HOME .. "/.claude/cc-ledger") .. " "
   .. q(HOME .. "/status") .. " " .. q(HOME .. "/sessions") .. " " .. q(HOME .. "/code/shop/.claude/worktrees/fix-x")
   .. " " .. q(HOME .. "/code/api") .. " " .. q(HOME .. "/code/docs"))
writeFile(HOME .. "/.claude/cc-config.json", '{"spawn":{"live":true,"editor":"vscode","kittyRemote":true},"remoteControl":{"onSpawn":false}}\n')

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function attributes(path, k)
  local out = sh("stat -c '%F|%Y|%s' " .. q(path) .. " 2>/dev/null || stat -f '%HT|%m|%z' " .. q(path) .. " 2>/dev/null")
  local kind, mtime, size = out:match("^([^|]+)|(%d+)|(%d+)")
  if not kind then return nil end
  local at = { mode = kind:lower():find("directory", 1, true) and "directory" or "file", modification = tonumber(mtime), size = tonumber(size) }
  if k then return at[k] end
  return at
end
-- what the stubbed machine looks like: the processes ps lists, the editor windows, what got opened
local psAlive = {}          -- pid -> lstart
local shellProbe = {}       -- pid -> what the Terminal shell probe prints for it
local kittyLsOut = nil      -- what `kitty @ ls` prints (nil = kitty says nothing: its socket is gone)
local scriptAnswer = "none" -- what the Terminal tab script answers
local executed, opened, scripts, tasks = {}, {}, {}, {}
local vclock, timers = 1000, {}
local windows, focused = {}, nil
local function mkWindow(title)
  local w = { _title = title }
  function w:title() return self._title end
  function w:focus() focused = self; return self end
  function w:application() return windows.app end
  return w
end
windows.app = { allWindows = function() return windows.list or {} end, bundleID = function() return "com.microsoft.VSCode" end,
                activate = function() end }
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  processInfo = { processID = 4242 },
  fs = {
    dir = function(path)
      local files, pp = {}, io.popen("ls -1a " .. q(path) .. " 2>/dev/null")
      if pp then for line in pp:lines() do files[#files + 1] = line end; pp:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = attributes,
    symlinkAttributes = function() return nil end,
    pathToAbsolute = function(path) return path end,
    mkdir = function(path) sh("mkdir " .. q(path) .. " 2>/dev/null"); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  -- ps answers for the pids it was asked about that are "alive" (and always for Shepherd's own)
  execute = function(cmd)
    executed[#executed + 1] = cmd
    local probed = tostring(cmd):match("^p=(%d+);")
    if probed then return shellProbe[probed] or "" end
    local list = tostring(cmd):match("ps %-o pid=,lstart= %-p ([%d,]+)")
    if not list then return "" end
    local out = {}
    for pid in list:gmatch("%d+") do
      if pid == "4242" then out[#out + 1] = " 4242 Wed Sep 30 08:00:00 2026" end
      if psAlive[pid] then out[#out + 1] = string.format("%5s %s    ", pid, psAlive[pid]) end
    end
    return table.concat(out, "\n") .. "\n"
  end,
  task = { new = function(bin, cb, args)
    local t = { bin = bin, cb = cb, args = args }
    t.start = function(self)
      tasks[#tasks + 1] = self
      -- kitty's `ls` answers at once (the dashboard waits for it); everything else is only recorded
      if cb and kittyLsOut and table.concat(args or {}, " "):find(" ls --match ", 1, true) then cb(0, kittyLsOut, "") end
      return self
    end
    t.waitUntilExit = function() end
    t.terminationStatus = function() return 0 end
    t.isRunning = function() return false end
    t.terminate = function() end
    return t
  end },
  application = { applicationsForBundleID = function() return { windows.app } end, find = function() return windows.app end },
  window = { focusedWindow = function() return focused end },
  urlevent = { openURL = function(uri) opened[#opened + 1] = uri; return true end },
  -- the tab script answers scriptAnswer; any other AppleScript (a new Terminal window) just runs
  osascript = { applescript = function(s)
    scripts[#scripts + 1] = s
    return true, (tostring(s):find("tty of t", 1, true) and scriptAnswer or nil), ""
  end },
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
-- timers: queued with their delay, run by the test in due order on a virtual clock
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return vclock * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function(delay, fn)
    local t = { due = vclock + (tonumber(delay) or 0), fn = fn }
    function t:stop() self.cancelled = true end
    timers[#timers + 1] = t
    return t
  end,
  new = function() return mkstub() end, usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
local function runTimers(limit)
  local n = 0
  while n < (limit or 500) do
    local best
    for i, t in ipairs(timers) do
      if not t.cancelled and (not best or t.due < timers[best].due) then best = i end
    end
    if not best then break end
    local t = table.remove(timers, best)
    vclock = math.max(vclock, t.due)
    t.fn()
    n = n + 1
  end
  for i = #timers, 1, -1 do if timers[i].cancelled then table.remove(timers, i) end end
  return n
end
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
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
check("the dashboard loads under the stub", ok)
if not ok then print("       " .. tostring(err)); sh("rm -r " .. q(HOME)); finish() end
local FX = _G.__ccDashboard.fx
core = _G.__ccDashboard.core
timers, tasks, opened, scripts = {}, {}, {}, {}   -- whatever loading queued is not this test's
check("FX ships the restart functions", type(FX.stepRestartSnapshot) == "function" and type(FX.restartPreview) == "function"
      and type(FX.restartFleet) == "function" and type(FX.restartVerifyDead) == "function")
eq("the snapshot lives in this HOME (never the real one)", FX.RESTART_FILE, HOME .. "/.claude/cc-restart.json")
eq("the session files are read from this HOME's test dir", FX.SESSIONS_DIR, HOME .. "/sessions")

local clock = 1790800000
FX.now = function() return clock end
local toasts = {}
local realAlert = FX.alert
FX.alert = function(m, secs) toasts[#toasts + 1] = tostring(m); return realAlert(m, secs) end

-- the fleet, in this HOME: two VS Code tabs in one window, a kitty session, a Terminal session
local function statusText(id, name, cwd, editor, status, extra)
  local t = { session_id = id, name = name, cwd = cwd, status = status, updated = clock - 5, since = clock - 60, editor = editor,
              transcript_path = HOME .. "/.claude/projects/" .. core.encodeProjectPath(cwd) .. "/" .. id .. ".jsonl" }
  for k, v in pairs(extra or {}) do t[k] = v end
  return json.encode(t)
end
local SHOP, WT, API, DOCS = HOME .. "/code/shop", HOME .. "/code/shop/.claude/worktrees/fix-x", HOME .. "/code/api", HOME .. "/code/docs"
local LIVE = {
  [A] = statusText(A, "shop", SHOP, "vscode", "working", { host_window = "501", session_pid = "611", permission_mode = "acceptEdits" }),
  [B] = statusText(B, "fix-x", WT, "vscode", "done", { host_window = "501", session_pid = "612", permission_mode = "auto" }),
  [C] = statusText(C, "api", API, "kitty", "working", { kitty_window_id = "7", kitty_listen_on = "unix:/tmp/kitty-900", permission_mode = "default" }),
  [D] = statusText(D, "docs", DOCS, "terminal", "done", { permission_mode = "plan" }),
}
local function tick(ids)
  local files = {}
  for _, id in ipairs(ids) do files[#files + 1] = { key = id, content = LIVE[id] } end
  local list = core.parseStatusList(files, clock)
  for _, it in ipairs(list) do if it.session_id == B then it.originDir = SHOP end end
  FX.stepRestartSnapshot(list)
  return list
end
for pid, e in pairs(REG) do writeFile(HOME .. "/sessions/" .. pid .. ".json", json.encode(e)) end
psAlive = { ["611"] = T_A, ["612"] = T_B, ["713"] = T_C, ["814"] = T_D }

-- the snapshot file: written whole, on a change, and only then
tick({ A, B, C, D })
local file1 = readAll(FX.RESTART_FILE)
check("file: the first tick writes ~/.claude/cc-restart.json", file1 ~= nil)
local onDisk = core.parseRestartSnapshot(file1)
eq("file: every session is in it", (function() local n = 0; for _ in pairs(onDisk.sessions) do n = n + 1 end; return n end)(), 4)
eq("file: with the process Claude Code's session file names (a kitty session's status file has none)",
   onDisk.sessions[C] and onDisk.sessions[C].window.pid, "713")
eq("file: a worktree tab's window folder", onDisk.sessions[B] and onDisk.sessions[B].root, SHOP)
eq("file: no temp file is left behind (written whole, then renamed)",
   sh("ls -1 " .. q(HOME .. "/.claude") .. " | grep -c 'cc-restart.json.tmp'"):gsub("%s+$", ""), "0")
clock = clock + 1
tick({ A, B, C, D })
eq("file: a tick with nothing changed writes nothing", readAll(FX.RESTART_FILE), file1)
clock = clock + 1
LIVE[A] = statusText(A, "shop", SHOP, "vscode", "done", { host_window = "501", session_pid = "611", permission_mode = "acceptEdits" })
tick({ A, B, C, D })
check("file: a turn that ends rewrites it", readAll(FX.RESTART_FILE) ~= file1
      and core.parseRestartSnapshot(readAll(FX.RESTART_FILE)).sessions[A].turn == nil)
LIVE[A] = statusText(A, "shop", SHOP, "vscode", "working", { host_window = "501", session_pid = "611", permission_mode = "acceptEdits" })
clock = clock + 1
tick({ A, B, C, D })

-- the preview with everything alive: nothing would reopen, and it does nothing
local ex0 = #executed
local plan0 = FX.restartPreview()
eq("preview: with the fleet alive, nothing would reopen", plan0.reopen + plan0.older, 0)
eq("preview: ...every session is listed as left alone", plan0.skipped, 4)
eq("preview: it asks ps once, for every process at once", #executed - ex0, 1)
eq("preview: refusing to reopen a live session by hand too", select(1, FX.restartVerifyDead(A)), false)
eq("restart: a run over live sessions reopens nothing", FX.restartFleet({ A, B, C, D }), false)
eq("restart: ...no URI", #opened, 0)

-- a session Shepherd drops itself leaves the snapshot
FX.removeStatus(D)
clock = clock + 1
tick({ A, B, C })
eq("forget: a session dropped from the panel (FX.removeStatus) leaves the snapshot", FX.restartSnapshot().sessions[D], nil)
eq("forget: ...on disk too", core.parseRestartSnapshot(readAll(FX.RESTART_FILE)).sessions[D], nil)

-- the fleet goes down: the VS Code tabs' and the kitty session's processes die, SessionEnd deletes A's and C's
-- status files, B's stays (no SessionEnd fired for it)
psAlive = {}
sh("rm " .. q(HOME .. "/sessions/611.json") .. " " .. q(HOME .. "/sessions/612.json") .. " " .. q(HOME .. "/sessions/713.json"))
clock = clock + 60
tick({ B })
local s = FX.restartSnapshot()
eq("down: the sessions whose status files went stay in the snapshot, ended", s.sessions[A] and s.sessions[A].ended, clock)
eq("down: ...a turn was in progress in one", s.sessions[A] and s.sessions[A].turn, true)

-- the dry run: what would reopen, where and how -- and nothing happens
local before = { opened = #opened, tasks = #tasks, scripts = #scripts, timers = #timers, file = readAll(FX.RESTART_FILE) }
clock = clock + 5
local preview = FX.restartPreview()
eq("dry run: three sessions would reopen", preview.reopen, 3)
local rowOf = {}
for _, r in ipairs(preview.rows) do rowOf[r.id] = r end
eq("dry run: a VS Code tab, as its tab", rowOf[A] and rowOf[A].how, "tab")
eq("dry run: the kitty session (its window is gone), in a new kitty window", rowOf[C] and rowOf[C].how, "kitty-new")
check("dry run: the text lists exactly that", FX.restartPreviewText():find("3 would reopen", 1, true) ~= nil)
eq("dry run: no URI went out", #opened, before.opened)
eq("dry run: no AppleScript ran", #scripts, before.scripts)
eq("dry run: nothing was scheduled", #timers, before.timers)
eq("dry run: the snapshot file wasn't touched", readAll(FX.RESTART_FILE), before.file)
local kittyAsked = 0
for i = before.tasks + 1, #tasks do
  if tostring(tasks[i].bin):find("kitty", 1, true) and table.concat(tasks[i].args or {}, " "):find("ls --match id:7", 1, true) then kittyAsked = kittyAsked + 1 end
end
check("dry run: the only processes it ran were kitty's `ls` (is the old window there?)", kittyAsked > 0 and kittyAsked == #tasks - before.tasks)

-- a restart with automation in dry run: recorded, nothing opened
writeFile(HOME .. "/.claude/cc-config.json", '{"spawn":{"live":true,"editor":"vscode"},"restart":{"dryRun":true},"remoteControl":{"onSpawn":false}}\n')
windows.list = { mkWindow("cart.ts — shop") }
eq("restart.dryRun: the run starts", FX.restartFleet({ A, B }), true)
runTimers()
eq("restart.dryRun: ...and opens nothing", #opened, 0)
eq("restart.dryRun: no session was stamped as reopened", FX.restartSnapshot().sessions[A].restarted, nil)
check("restart.dryRun: the Trace says what it would do",
      (function() for _, tr in ipairs(FX._automation.trace) do if tr.kind == "restart" and tr.outcome == "would" and tr.key == A then return true end end end)() == true)
check("restart.dryRun: the summary says so", (toasts[#toasts] or ""):find("2 would reopen (dry run)", 1, true) ~= nil)
writeFile(HOME .. "/.claude/cc-config.json", '{"spawn":{"live":true,"editor":"vscode"},"remoteControl":{"onSpawn":false}}\n')

-- the real run, stubbed windows: VS Code tabs, one at a time, each by its session id, never twice
opened = {}
eq("restart: refuses a run with no list (nothing restarts without ids from a plan)", FX.restartFleet(nil), false)
eq("restart: ...or a list of things that aren't session ids", FX.restartFleet({ "x; rm", 7 }), false)
eq("restart: the run starts", FX.restartFleet({ A, A, B }), true)
eq("restart: a second click while it runs is refused", FX.restartFleet({ A, B }), false)
-- the first tab is scheduled; the second has not been touched yet
eq("restart: nothing is out before the window is confirmed in front", #opened, 0)
local stampedFirst = core.parseRestartSnapshot(readAll(FX.RESTART_FILE))
local nStamped = 0
for _, id in ipairs({ A, B }) do if stampedFirst.sessions[id].restarted then nStamped = nStamped + 1 end end
eq("restart: one at a time -- exactly one session is stamped (on disk, before its tab opens)", nStamped, 1)
runTimers()
eq("restart: one URI per session, even with an id picked twice", #opened, 2)
local uris = table.concat(opened, "\n")
check("restart: each is that session's own link", uris:find("vscode://anthropic.claude-code/open?session=" .. A, 1, true) ~= nil
      and uris:find("vscode://anthropic.claude-code/open?session=" .. B, 1, true) ~= nil)
check("restart: the summary says two reopened", (toasts[#toasts] or ""):find("2 reopened", 1, true) ~= nil)
eq("restart: the run is over", FX._restart.run, nil)
eq("restart: both are stamped in the snapshot", core.parseRestartSnapshot(readAll(FX.RESTART_FILE)).sessions[B].restarted ~= nil, true)
-- never twice: a second run over the same sessions opens nothing
eq("never twice: a second run has nothing to reopen", FX.restartFleet({ A, B }), false)
runTimers()
eq("never twice: ...no further URI", #opened, 2)
eq("never twice: the preview says they were already reopened", (function()
  for _, r in ipairs(FX.restartPreview().rows) do if r.id == A then return r.reason end end end)(), "reopened")
-- ...and the stamp survives the ticks while B's frozen status file is still there
clock = clock + 1
tick({ B })
eq("never twice: a leftover status file's stamp survives the next tick", FX.restartSnapshot().sessions[B].restarted ~= nil, true)
-- once a hook of the session writes again, it is simply a live session
clock = clock + 30
LIVE[B] = statusText(B, "fix-x", WT, "vscode", "idle", { host_window = "777", session_pid = "912", permission_mode = "auto" })
tick({ B })
eq("back: a hook write after the reopen clears the stamp", FX.restartSnapshot().sessions[B].restarted, nil)

-- verified right before the URI goes out: a session that came alive in between is not reopened
local E = "55555555-aaaa-4bbb-8ccc-000000000005"
LIVE[E] = statusText(E, "shop", SHOP, "vscode", "done", { host_window = "501", session_pid = "655", permission_mode = "default" })
psAlive = { ["912"] = "Wed Sep 30 13:00:00 2026", ["655"] = "Wed Sep 30 09:50:00 2026" }
writeFile(HOME .. "/sessions/655.json", json.encode(regEntry(655, E, "Wed Sep 30 09:50:00 2026")))
clock = clock + 1
tick({ B, E })
psAlive["655"] = nil
sh("rm " .. q(HOME .. "/sessions/655.json"))
clock = clock + 1
tick({ B })                       -- E's status file is gone and its process is dead: reopenable
opened = {}
eq("race: the run starts for a dead session", FX.restartFleet({ E }), true)
-- ...and before its window is confirmed, someone resumes it by hand: a live process holds the id
writeFile(HOME .. "/sessions/990.json", json.encode(regEntry(990, E, "Wed Sep 30 14:00:00 2026")))
psAlive["990"] = "Wed Sep 30 14:00:00 2026"
runTimers()
eq("race: a session that came alive before its URI went out is NOT reopened", #opened, 0)
eq("race: ...its stamp is taken back (nothing was opened)", FX.restartSnapshot().sessions[E].restarted, nil)
check("race: ...and the summary says it wasn't reopened", (toasts[#toasts] or ""):find("1 not reopened", 1, true) ~= nil)

-- the window not in front: nothing opened, the stamp taken back, the session can be tried again
sh("rm " .. q(HOME .. "/sessions/990.json"))
psAlive["990"] = nil
windows.list = { mkWindow("notes.md — elsewhere") }
focused = windows.list[1]
opened = {}
eq("no window: the run starts", FX.restartFleet({ E }), true)
runTimers()
eq("no window: nothing is opened into some other window", #opened, 0)
eq("no window: the stamp is taken back", FX.restartSnapshot().sessions[E].restarted, nil)

-- kitty: a new window running claude -r <id>; Continue only once the session is back and ready
windows.list = { mkWindow("cart.ts — shop") }
tasks = {}
eq("kitty: the run starts", FX.restartFleet({ C }), true)
runTimers()
local kittyLaunch
for _, t in ipairs(tasks) do
  local line = table.concat(t.args or {}, " ")
  if line:find("-r " .. C, 1, true) then kittyLaunch = line end
end
check("kitty: a new kitty window runs claude -r <id> in the session's folder",
      kittyLaunch ~= nil and kittyLaunch:find("--directory " .. API, 1, true) ~= nil
      and kittyLaunch:find("--permission-mode default -r " .. C, 1, true) ~= nil)
check("kitty: a Continue is pending for it (a turn was in progress)", FX._restart.pending[C] ~= nil)
eq("kitty: it is stamped as reopened", FX.restartSnapshot().sessions[C].restarted ~= nil, true)
local typed = {}
FX.typeIntoWindow = function(target, text) typed[#typed + 1] = { key = target.key, text = text }; return true end
local EMPTY = readAll(HERE .. "fixtures/kitty-screens/empty-composer.ansi") or ""
local TYPED = readAll(HERE .. "fixtures/kitty-screens/typed-text.ansi") or ""
check("the kitty screen fixtures are there", EMPTY ~= "" and TYPED ~= "")
local screen = EMPTY
FX.kittyScreen = function() return screen end
local function backAs(status, updated)
  return core.parseStatusList({ { key = C, content = statusText(C, "api", API, "kitty", status,
    { kitty_window_id = "9", kitty_listen_on = "unix:/tmp/kitty-901", updated = updated }) } }, clock)
end
-- not back yet: its old status file is gone, nothing to type into
FX.stepRestartContinue({})
runTimers()
eq("continue: nothing is typed before the session is back", #typed, 0)
-- back, but mid-turn (it picked the turn up by itself): never typed into
clock = clock + 5
FX.stepRestartContinue(backAs("working", clock))
runTimers()
eq("continue: a session that is working is not typed into", #typed, 0)
eq("continue: ...and its Continue stays pending", FX._restart.pending[C] ~= nil, true)
-- back and idle, but something is already typed in its composer: refused
clock = clock + 10
screen = TYPED
FX.stepRestartContinue(backAs("idle", clock - 5))
runTimers()
eq("continue: a composer that already holds text is not typed into", #typed, 0)
-- back, idle, an empty composer: typed once, as Shepherd's own line
clock = clock + 10
screen = EMPTY
local idle = backAs("idle", clock - 4)
FX.stepRestartContinue(idle)
runTimers()
eq("continue: typed once the session is back and ready", #typed, 1)
eq("continue: ...as Shepherd's own line", typed[1] and typed[1].text, core.shepherdSays(core.RESTART.continueLine))
eq("continue: ...into that session", typed[1] and typed[1].key, C)
FX.stepRestartContinue(idle)
runTimers()
eq("continue: never a second time", #typed, 1)

-- kitty, its window still there at a shell prompt: the line is typed into THAT window, no new one
local G = "77777777-aaaa-4bbb-8ccc-000000000007"
LIVE[G] = statusText(G, "api", API, "kitty", "done", { kitty_window_id = "11", kitty_listen_on = "unix:/tmp/kitty-950", permission_mode = "acceptEdits" })
writeFile(HOME .. "/sessions/877.json", json.encode(regEntry(877, G, "Wed Sep 30 10:00:00 2026")))
psAlive["877"] = "Wed Sep 30 10:00:00 2026"
clock = clock + 1
tick({ B, G })
psAlive["877"] = nil
sh("rm " .. q(HOME .. "/sessions/877.json"))
clock = clock + 1
tick({ B })
kittyLsOut = json.encode({ { id = 1, tabs = { { id = 2, windows = { { id = 11, foreground_processes = { { pid = 5, cmdline = { "-zsh" } } } } } } } } })
eq("kitty window: the preview says it reopens in its own window", (function()
  for _, r in ipairs(FX.restartPreview().rows) do if r.id == G then return r.how end end end)(), "kitty-window")
tasks = {}
eq("kitty window: the run starts", FX.restartFleet({ G }), true)
runTimers()
local sentText, newWindow, pressedEnter = nil, false, false
for _, t in ipairs(tasks) do
  local line = table.concat(t.args or {}, " ")
  if line:find("send-text --match id:11 -- ", 1, true) then sentText = line end
  if line:find("send-key --match id:11 enter", 1, true) then pressedEnter = true end
  if line:find("--directory", 1, true) then newWindow = true end
end
check("kitty window: claude -r <id> is typed into its own window, through its own socket",
      sentText ~= nil and sentText:find("@ --to unix:/tmp/kitty-950 send-text", 1, true) ~= nil
      and sentText:find("cd '" .. API .. "' && claude --permission-mode acceptEdits -r " .. G, 1, true) ~= nil)
check("kitty window: ...then Return, as its own write", pressedEnter)
check("kitty window: no new kitty window is opened", not newWindow)
eq("kitty window: a session that had finished gets no Continue", FX._restart.pending[G], nil)
kittyLsOut = nil

-- Terminal, the shell that ran it still there: the line goes into its own tab
local T1 = "66666666-aaaa-4bbb-8ccc-000000000006"
LIVE[T1] = statusText(T1, "docs", DOCS, "terminal", "working", { permission_mode = "plan" })
writeFile(HOME .. "/sessions/866.json", json.encode(regEntry(866, T1, "Wed Sep 30 10:30:00 2026")))
psAlive["866"], psAlive["860"] = "Wed Sep 30 10:30:00 2026", "Wed Sep 30 10:20:00 2026"
shellProbe["866"] = "  866   860 ttys004  Wed Sep 30 10:30:00 2026\n  860   850 ttys004  Wed Sep 30 10:20:00 2026\n"
clock = clock + 1
tick({ B, T1 })
eq("terminal: the snapshot knows the tab's tty (asked of ps once, when the session first shows up)",
   FX.restartSnapshot().sessions[T1].window.tty, "/dev/ttys004")
local probes = 0
for _, cmd in ipairs(executed) do if tostring(cmd):find("^p=866;") then probes = probes + 1 end end
clock = clock + 1
tick({ B, T1 })
local probes2 = 0
for _, cmd in ipairs(executed) do if tostring(cmd):find("^p=866;") then probes2 = probes2 + 1 end end
eq("terminal: ...and never asks again", probes2 .. "/" .. probes, "1/1")
psAlive["866"] = nil          -- claude is gone; its shell (860) is still there
sh("rm " .. q(HOME .. "/sessions/866.json"))
clock = clock + 1
tick({ B })
scripts, scriptAnswer = {}, "tab"
eq("terminal tab: the run starts", FX.restartFleet({ T1 }), true)
runTimers()
eq("terminal tab: one AppleScript ran", #scripts, 1)
check("terminal tab: it runs claude -r <id> in the tab on that tty, only while it is idle",
      (scripts[1] or ""):find('if (tty of t) is "/dev/ttys004" and (busy of t) is false then', 1, true) ~= nil
      and (scripts[1] or ""):find("cd '" .. DOCS .. "' && claude --permission-mode plan -r " .. T1, 1, true) ~= nil)
check("terminal tab: a Continue is pending (a turn was in progress)", FX._restart.pending[T1] ~= nil)
-- ...and when that tab is busy or gone, a new window instead
local T2 = "88888888-aaaa-4bbb-8ccc-000000000008"
LIVE[T2] = statusText(T2, "docs", DOCS, "terminal", "done", { permission_mode = "default" })
writeFile(HOME .. "/sessions/888.json", json.encode(regEntry(888, T2, "Wed Sep 30 10:40:00 2026")))
psAlive["888"], psAlive["880"] = "Wed Sep 30 10:40:00 2026", "Wed Sep 30 10:35:00 2026"
shellProbe["888"] = "  888   880 ttys007  Wed Sep 30 10:40:00 2026\n  880   850 ttys007  Wed Sep 30 10:35:00 2026\n"
clock = clock + 1
tick({ B, T2 })
psAlive["888"] = nil
sh("rm " .. q(HOME .. "/sessions/888.json"))
clock = clock + 1
tick({ B })
scripts, scriptAnswer = {}, "none"
eq("terminal new: the run starts", FX.restartFleet({ T2 }), true)
runTimers()
eq("terminal new: its tab didn't take the line, so a second script opens a new window", #scripts, 2)
check("terminal new: ...running cd <folder> && claude ... -r <id>",
      (scripts[2] or ""):find('tell application "Terminal" to do script', 1, true) ~= nil
      and (scripts[2] or ""):find("cd '" .. DOCS .. "' && claude --permission-mode default -r " .. T2, 1, true) ~= nil
      and not (scripts[2] or ""):find("tty of t", 1, true))
-- a session that finished its turn gets no Continue at all
eq("continue: only where a turn was in progress (a finished Terminal session gets none)", FX._restart.pending[T2], nil)

sh("rm -r " .. q(HOME))
finish()
