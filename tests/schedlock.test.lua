-- schedlock.test.lua : the scheduled-tasks lock verdict (2026-09-29, build program unit 39). Plain
-- `lua`, no Hammerspoon. Claude Code keeps one scheduler per folder through
-- <launch dir>/.claude/scheduled_tasks.lock, JSON {sessionId, pid, procStart, acquiredAt}; a lock
-- whose pid is gone, or whose pid now belongs to a process that started at another time (pid
-- reuse), is dead. One committed to git ships to every clone and worktree. One whose live session
-- is another card's keeps this card's scheduled tasks from firing. The card flags those three and
-- says how to fix them; Shepherd never runs the fix. Every case below is a literal lock plus
-- literal `ps` and `git` output.

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

-- The real one, from ~/Programming/qb-interface/.claude/scheduled_tasks.lock (2026-09-29).
local QB = '{"sessionId":"e8c76239-f62c-49c4-a14a-7900b3fd2a7c","pid":44063,"procStart":"Thu Jun 11 20:07:15 2026","acquiredAt":1781224931116}'
local QB_DIR = "/Users/u/Programming/qb-interface"
local ME = "900"   -- Shepherd's own pid, the probe's control

-- ---- the lock file (2026-09-29) ----
do
  local lk = core.parseSchedLock(QB)
  check("a real lock parses", type(lk) == "table")
  eq("...its session", lk and lk.sessionId, "e8c76239-f62c-49c4-a14a-7900b3fd2a7c")
  eq("...its pid, as digits", lk and lk.pid, "44063")
  eq("...its process start, as Claude Code wrote it", lk and lk.procStart, "Thu Jun 11 20:07:15 2026")
  eq("...when it was taken", lk and lk.acquiredAt, 1781224931116)
  local old = core.parseSchedLock('{"sessionId":"s1","pid":12,"acquiredAt":1}')
  check("an older lock with no procStart parses too (Claude Code's schema has it optional)", old and old.pid == "12" and old.procStart == nil)
  eq("malformed JSON is no lock", core.parseSchedLock('{"sessionId":"s1","pid":'), nil)
  eq("an empty file (caught mid-write) is no lock", core.parseSchedLock(""), nil)
  eq("a pid that isn't a number is no lock (Claude Code rejects it too)", core.parseSchedLock('{"sessionId":"s","pid":"12","acquiredAt":1}'), nil)
  eq("a pid of 0 is no lock", core.parseSchedLock('{"sessionId":"s","pid":0,"acquiredAt":1}'), nil)
  eq("no sessionId is no lock", core.parseSchedLock('{"pid":12,"acquiredAt":1}'), nil)
  eq("a JSON array is no lock", core.parseSchedLock('[1,2]'), nil)
  eq("nil is no lock", core.parseSchedLock(nil), nil)
  eq("the lock's path under a launch folder", core.SCHED_LOCK_REL, ".claude/scheduled_tasks.lock")
end

-- ---- the background probe: one ps, and git per folder (2026-09-29) ----
do
  local argv = core.schedLockScanArgv({ ["44063"] = true, [ME] = true, ["7; rm -rf ~"] = true }, { QB_DIR, "/r/two" })
  check("the probe is one /bin/sh program", argv[1] == "/bin/sh" and argv[2] == "-c" and type(argv[3]) == "string")
  eq("...named cc-schedlock", argv[4], "cc-schedlock")
  eq("...asked about the lock pids and its own, digits only, sorted", argv[5], "44063,900")
  check("...then each folder whose HEAD it hasn't read", argv[6] == QB_DIR and argv[7] == "/r/two" and argv[8] == nil)
  -- Claude Code writes procStart from `LC_ALL=C TZ=UTC ps -o lstart=`; any other zone or locale
  -- reads every live lock as a reused pid.
  check("ps runs in Claude Code's own zone and locale", argv[3]:find("LC_ALL=C TZ=UTC ps -o pid=,lstart= -p", 1, true) ~= nil)
  check("...and git asks HEAD's tree, not the index", argv[3]:find("ls-tree --name-only HEAD -- .claude/scheduled_tasks.lock", 1, true) ~= nil)
  eq("no pids and no folders: an empty pid list", core.schedLockScanArgv({}, {})[5], "")

  -- ps pads the pid, and lstart pads a one-digit day with a space: that space is kept
  local out = table.concat({
    "@@ps",
    "44063 Thu Jun 11 20:07:15 2026    ",
    "  900 Tue Sep  1 08:00:00 2026",
    "@@git\t1",
    ".claude/scheduled_tasks.lock",
    "@@rc\t0",
    "@@git\t2",
    "@@rc\t0",
    "" }, "\n")
  local scan = core.parseSchedLockScan(out, { QB_DIR, "/r/two" })
  eq("ps: a live pid's start time", scan.lstart["44063"], "Thu Jun 11 20:07:15 2026")
  eq("ps: ...a one-digit day keeps its padding", scan.lstart["900"], "Tue Sep  1 08:00:00 2026")
  eq("git: a lock in HEAD's tree is committed", scan.tracked[QB_DIR], true)
  eq("git: an empty answer is not committed", scan.tracked["/r/two"], false)
  local notRepo = core.parseSchedLockScan("@@ps\n  900 Tue Sep  1 08:00:00 2026\n@@git\t1\n@@rc\t128\n", { "/tmp/x" })
  eq("git: outside a repo (or no commit yet) nothing is known", notRepo.tracked["/tmp/x"], nil)
  eq("...but the folder was answered (cached, not asked every probe)", notRepo.answered["/tmp/x"], true)
  eq("both folders answered", scan.answered[QB_DIR] and scan.answered["/r/two"], true)
  local tornGit = core.parseSchedLockScan("@@ps\n  900 x\n@@git\t1\n.claude/sched", { QB_DIR })
  eq("git: a section cut off before its exit code answers nothing", tornGit.answered[QB_DIR], nil)
  eq("...and says nothing", tornGit.tracked[QB_DIR], nil)
  eq("no @@ps section: nothing is known about any pid", core.parseSchedLockScan("", {}).lstart, nil)
  local torn = core.parseSchedLockScan("@@ps\n44063 Thu Jun 11 20:0", {})
  eq("a torn last line is no start time", torn.lstart["44063"], nil)
end

-- ---- the per-HEAD cache for "is it committed" (2026-09-29) ----
do
  local now = 10000
  check("never asked: due", core.schedLockTrackDue(nil, "abc", now))
  check("asked at this HEAD: not due", not core.schedLockTrackDue({ sha = "abc", at = 0, tracked = true }, "abc", now))
  check("...however long ago", not core.schedLockTrackDue({ sha = "abc", at = 0, tracked = false }, "abc", now + 86400 * 30))
  check("HEAD moved: due", core.schedLockTrackDue({ sha = "abc", at = now, tracked = true }, "def", now))
  check("HEAD unreadable (a subfolder, no repo): due again after the retry window",
        core.schedLockTrackDue({ sha = nil, at = now - core.SCHED_LOCK_RETRY, tracked = nil }, nil, now))
  check("...but not within it", not core.schedLockTrackDue({ sha = nil, at = now - 10, tracked = nil }, nil, now))
  check("a HEAD that becomes readable: due", core.schedLockTrackDue({ sha = nil, at = now, tracked = nil }, "abc", now))
end

-- ---- the verdict (2026-09-29) ----
local LIVE_LSTART = { ["44063"] = "Thu Jun 11 20:07:15 2026", [ME] = "Tue Sep  1 08:00:00 2026" }
local function entry(over)
  local e = { dir = QB_DIR, present = true, lock = core.parseSchedLock(QB), probed = true, lstart = LIVE_LSTART, tracked = false }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end
local CARD = "repo:/Users/u/Programming/qb-interface/.git"
local SESSIONS = {
  { key = "k1", session_id = "e8c76239-f62c-49c4-a14a-7900b3fd2a7c", session_pid = "44063", card = CARD, dir = QB_DIR, name = "qb-interface" },
  { key = "k2", session_id = "other-session", session_pid = "5150", card = "repo:/r/other/.git", dir = "/r/other", name = "other-app" },
}
do
  eq("live, held by this card's own session: nothing to show", core.schedLockVerdict(entry(), CARD, SESSIONS), nil)
  eq("live, held by a session Shepherd doesn't show: nothing to show", core.schedLockVerdict(entry(), CARD, {}), nil)
  eq("no lock file: nothing to show", core.schedLockVerdict({ dir = QB_DIR, present = false }, CARD, SESSIONS), nil)
  eq("nil entry: nothing", core.schedLockVerdict(nil, CARD, SESSIONS), nil)

  local gone = core.schedLockVerdict(entry({ lstart = { [ME] = "Tue Sep  1 08:00:00 2026" } }), CARD, SESSIONS)
  eq("dead: its pid is gone", gone and gone.dead, "gone")
  eq("...naming the pid", gone and gone.pid, "44063")
  eq("...and not committed", gone and gone.committed, nil)

  local reused = core.schedLockVerdict(entry({ lstart = { ["44063"] = "Mon Sep 28 09:12:03 2026", [ME] = "x" } }), CARD, SESSIONS)
  eq("dead: its pid is alive but started at another time (a reused pid)", reused and reused.dead, "reused")
  eq("...with both start times to show", reused and (reused.lstart .. " | " .. reused.procStart), "Mon Sep 28 09:12:03 2026 | Thu Jun 11 20:07:15 2026")

  -- Claude Code's own rule: no procStart, or ps couldn't say when the pid started -> the pid decides
  local noStart = entry({ lock = core.parseSchedLock('{"sessionId":"x","pid":44063,"acquiredAt":1}') })
  eq("a lock with no procStart and a live pid is live", core.schedLockVerdict(noStart, CARD, {}), nil)
  eq("a live pid whose start ps left blank is live", core.schedLockVerdict(entry({ lstart = { ["44063"] = "", [ME] = "x" } }), CARD, {}), nil)

  -- a probe that can't see Shepherd's own pid proves nothing: never "dead" on a broken ps
  eq("an untrusted probe says nothing about the pid", core.schedLockVerdict(entry({ probed = false, lstart = {} }), CARD, SESSIONS), nil)
  eq("...nor does a probe that hasn't landed", core.schedLockVerdict(entry({ probed = nil, lstart = nil }), CARD, SESSIONS), nil)

  local committed = core.schedLockVerdict(entry({ tracked = true }), CARD, SESSIONS)
  check("committed: git tracks it, live or not", committed and committed.committed == true and committed.dead == nil)
  local both = core.schedLockVerdict(entry({ tracked = true, lstart = { [ME] = "x" } }), CARD, SESSIONS)
  check("committed AND dead: both are said", both and both.committed == true and both.dead == "gone")

  -- another repo's folder carries a copy of qb-interface's lock (a committed lock, cloned): its
  -- session is alive, so Claude Code in /r/other believes the scheduler is taken
  local held = core.schedLockVerdict(entry({ dir = "/r/other" }), "repo:/r/other/.git", SESSIONS)
  check("held by another card: its session is live and on a different card", held and held.other ~= nil)
  eq("...named by that card", held and held.other and held.other.name, "qb-interface")
  eq("...and not dead", held and held.dead, nil)
  -- a session that ran /clear keeps its process but not its session id: the pid still finds it
  local cleared = { { key = "k9", session_id = "after-clear", session_pid = "44063", card = CARD, dir = QB_DIR, name = "qb-interface" } }
  local byPid = core.schedLockVerdict(entry({ dir = "/r/other" }), "repo:/r/other/.git", cleared)
  check("...found by its pid when its session id changed (/clear)", byPid and byPid.other and byPid.other.name == "qb-interface")
  eq("a dead lock is never 'held by' anyone", (core.schedLockVerdict(entry({ dir = "/r/other", lstart = { [ME] = "x" } }), "repo:/r/other/.git", SESSIONS) or {}).other, nil)
  -- stacks off: every session is its own card, but the rightful owner is the session launched in that folder
  eq("the session launched in the lock's own folder is never 'another card'",
     core.schedLockVerdict(entry(), "k:k3", SESSIONS), nil)

  -- malformed: it may be mid-write, and Claude Code replaces an unreadable lock itself
  local bad = { dir = QB_DIR, present = true, lock = nil, probed = true, lstart = LIVE_LSTART, tracked = false }
  eq("malformed JSON: nothing to show", core.schedLockVerdict(bad, CARD, SESSIONS), nil)
  bad.tracked = true
  local badC = core.schedLockVerdict(bad, CARD, SESSIONS)
  check("malformed but committed: committed is still said", badC and badC.committed == true and badC.dead == nil)
end

-- ---- what the card shows, and the fix it suggests (2026-09-29) ----
do
  eq("no verdicts: no badge", core.schedLockView({}), nil)
  eq("nil: no badge", core.schedLockView(nil), nil)
  local dead = core.schedLockView({ core.schedLockVerdict(entry({ lstart = { [ME] = "x" } }), CARD, SESSIONS) })
  eq("dead: the chip", dead and dead.label, "🔒 lock dead")
  check("...the tooltip names the file", dead and dead.tip:find(QB_DIR .. "/.claude/scheduled_tasks.lock", 1, true) ~= nil)
  check("...says why", dead and dead.tip:find("pid 44063 is gone", 1, true) ~= nil)
  check("...suggests deleting it", dead and dead.tip:find("rm .claude/scheduled_tasks.lock", 1, true) ~= nil)
  check("...and says Shepherd won't", dead and dead.tip:find("Shepherd never runs", 1, true) ~= nil)
  check("...and no git fix for a lock git doesn't track", dead and dead.tip:find("git rm", 1, true) == nil)

  local reused = core.schedLockView({ core.schedLockVerdict(entry({ lstart = { ["44063"] = "Mon Sep 28 09:12:03 2026", [ME] = "x" } }), CARD, SESSIONS) })
  check("reused: the tooltip says the pid is another process now",
        reused and reused.tip:find("pid 44063 is another process now", 1, true) ~= nil
        and reused.tip:find("Mon Sep 28 09:12:03 2026", 1, true) ~= nil)

  local com = core.schedLockView({ core.schedLockVerdict(entry({ tracked = true }), CARD, SESSIONS) })
  eq("committed: the chip", com and com.label, "🔒 lock in git")
  check("...suggests git rm --cached", com and com.tip:find("git rm --cached .claude/scheduled_tasks.lock", 1, true) ~= nil)
  check("...and a .gitignore line", com and com.tip:find("echo '.claude/scheduled_tasks.lock' >> .gitignore", 1, true) ~= nil)
  check("...and not rm, for a live lock", com and com.tip:find("\n  rm ", 1, true) == nil)

  local both = core.schedLockView({ core.schedLockVerdict(entry({ tracked = true, lstart = { [ME] = "x" } }), CARD, SESSIONS) })
  eq("both: one chip says both", both and both.label, "🔒 lock dead · in git")
  local gi, rmi = both.tip:find("git rm --cached", 1, true), both.tip:find("\n  rm .claude", 1, true)
  check("...untrack it before deleting it", gi and rmi and gi < rmi)

  local held = core.schedLockView({ core.schedLockVerdict(entry({ dir = "/r/other" }), "repo:/r/other/.git", SESSIONS) })
  eq("held: the chip", held and held.label, "🔒 lock held elsewhere")
  check("...names the card that holds it", held and held.tip:find("qb-interface", 1, true) ~= nil)
  check("...and says nothing here needs deleting", held and held.tip:find("rm ", 1, true) == nil)

  -- two launch folders on one card, each with its own problem
  local two = core.schedLockView({
    core.schedLockVerdict(entry({ tracked = true }), CARD, SESSIONS),
    core.schedLockVerdict(entry({ dir = "/r/qb-sibling", lstart = { [ME] = "x" } }), CARD, SESSIONS) })
  eq("two folders: one chip with both kinds", two and two.label, "🔒 lock dead · in git")
  check("...and a tooltip block per folder", two and two.tip:find(QB_DIR, 1, true) ~= nil and two.tip:find("/r/qb-sibling", 1, true) ~= nil)
end

-- ---- which card shows what (2026-09-29) ----
do
  local rows = {
    { key = "k1", session_id = "e8c76239-f62c-49c4-a14a-7900b3fd2a7c", session_pid = "44063", card = CARD, dir = QB_DIR, name = "qb-interface" },
    { key = "k1b", session_id = "s-b", session_pid = "44100", card = CARD, dir = QB_DIR, name = "qb-interface" },
    { key = "k2", session_id = "other-session", session_pid = "5150", card = "repo:/r/other/.git", dir = "/r/other", name = "other-app" },
    { key = "k3", session_id = "s-3", session_pid = "6000", card = "repo:/r/quiet/.git", dir = "/r/quiet", name = "quiet" },
  }
  local entries = {
    [QB_DIR] = entry({ tracked = true }),
    ["/r/other"] = entry({ dir = "/r/other" }),
  }
  local views = core.schedLockCards(rows, entries)
  eq("the committed lock reaches its own card", views[CARD] and views[CARD].label, "🔒 lock in git")
  eq("the copy another card's folder holds reaches that card", views["repo:/r/other/.git"] and views["repo:/r/other/.git"].label, "🔒 lock held elsewhere")
  eq("a card with no lock file shows nothing", views["repo:/r/quiet/.git"], nil)
  eq("no entries: nothing anywhere", next(core.schedLockCards(rows, {})), nil)
  check("a row with no launch folder is skipped", next(core.schedLockCards({ { key = "x", card = "c" } }, entries)) == nil)
end

print(string.format("-- schedlock.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
