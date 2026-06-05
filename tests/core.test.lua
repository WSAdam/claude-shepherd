-- core.test.lua : standalone unit tests for cc-core.lua. Run with plain `lua`.
-- No Hammerspoon, no side effects: JSON via the vendored parser, effects via the
-- recorder. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")
local newRecorder = dofile(HERE .. "support/fx_recorder.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then
    print("ok   - " .. name)
  else
    failed = failed + 1
    print("FAIL - " .. name)
  end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

local function entry(key, tbl) return { key = key, content = core.json.encode(tbl) } end

-- ---- config: dotted lookup with safe defaults ------------------------------
do
  local cfg = core.json.decode(
    '{"queue":{"autofeed":true},"policies":{"approveRepeats":false,"autopilot":{"minutes":15}}}')
  eq("config: nested true", core.config(cfg, "queue.autofeed", false), true)
  eq("config: false preserved (not default)", core.config(cfg, "policies.approveRepeats", true), false)
  eq("config: missing key -> default", core.config(cfg, "policies.patterns.enabled", false), false)
  eq("config: deep value", core.config(cfg, "policies.autopilot.minutes", 0), 15)
  eq("config: nil table -> default", core.config(nil, "a.b", "d"), "d")
end

-- ---- parseStatusList: decode + stale + approvals-first sort ----------------
do
  local now = 10000
  local entries = {
    entry("a", { name = "alpha",   status = "idle",     updated = now }),
    entry("b", { name = "bravo",   status = "approval", updated = now }),
    entry("c", { name = "charlie", status = "working",  updated = now - 1000 }), -- stale
    entry("d", { name = "delta",   status = "done",     updated = now }),
    { key = "junk", content = "{ not json" },             -- dropped (malformed)
    entry("e", { status = "idle", updated = now }),        -- dropped (no name)
  }
  local list = core.parseStatusList(entries, now, 90)
  eq("parse: keeps 4 valid entries", #list, 4)
  eq("parse: approval sorts first", list[1].status, "approval")
  eq("parse: approval is bravo", list[1].name, "bravo")
  eq("parse: key tagged", list[1].key, "b")
  -- find charlie and assert stale; alpha not stale
  local charlie, alpha
  for _, it in ipairs(list) do
    if it.name == "charlie" then charlie = it end
    if it.name == "alpha" then alpha = it end
  end
  eq("parse: old entry is stale", charlie.stale, true)
  eq("parse: fresh entry not stale", alpha.stale, false)
end

-- ---- resolveGesture: gate-aware short/long press ---------------------------
do
  local waiting = { gate = "waiting" }
  local normal  = {}
  eq("gesture: waiting + short = approve", core.resolveGesture(waiting, "primary"), "approve")
  eq("gesture: waiting + long  = deny",    core.resolveGesture(waiting, "secondary"), "deny")
  eq("gesture: normal  + short = focus",   core.resolveGesture(normal, "primary"), "focus")
  eq("gesture: normal  + long  = focus (default)", core.resolveGesture(normal, "secondary"), "focus")
  eq("gesture: normal  + long  = stop (opt-in)",
     core.resolveGesture(normal, "secondary", { longPressStops = true }), "stop")
end

-- ---- handleAction: routes to the right effect, gate-aware ------------------
do
  local waiting = { key = "w1", name = "proj-w", gate = "waiting" }
  local normal  = { key = "n1", name = "proj-n", cwd = "/Users/x/proj-n" }

  local r = newRecorder()
  core.handleAction(r.fx, waiting, "approve")
  eq("approve(waiting): writeDecision op", r.last().op, "writeDecision")
  eq("approve(waiting): allow value", r.last().b, "allow")

  r = newRecorder()
  core.handleAction(r.fx, normal, "approve")
  eq("approve(normal): actOnWindow op", r.last().op, "actOnWindow")
  eq("approve(normal): targets window name", r.last().a, "proj-n")
  eq("approve(normal): uses APPROVE key", r.last().b.key, "return")

  r = newRecorder()
  core.handleAction(r.fx, waiting, "deny")
  eq("deny(waiting): writeDecision deny", r.last().b, "deny")

  r = newRecorder()
  core.handleAction(r.fx, normal, "deny")
  eq("deny(normal): uses DENY key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "stop")
  eq("stop: actOnWindow", r.last().op, "actOnWindow")
  eq("stop: uses STOP key (escape)", r.last().b.key, "escape")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "run the tests")
  eq("nudge: pasteIntoWindow op", r.last().op, "pasteIntoWindow")
  eq("nudge: passes text in payload", r.last().b.text, "run the tests")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "")
  eq("nudge: empty text is a no-op", r.count(), 0)

  r = newRecorder()
  core.handleAction(r.fx, normal, "focus")
  eq("focus: focusWindow op", r.last().op, "focusWindow")
  eq("focus: targets name", r.last().a, "proj-n")
  eq("focus: passes cwd for ancestor matching", r.last().b, "/Users/x/proj-n")
end

-- ---- deckLayout: row-major fill + overflow ---------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  local lay = core.deckLayout(2, list)
  eq("deck: fills 2 keys", lay.items[1].key, "a")
  eq("deck: 2nd key", lay.items[2].key, "b")
  eq("deck: no 3rd key", lay.items[3], nil)
  eq("deck: overflow counts the rest", lay.overflow, 1)

  local lay2 = core.deckLayout(15, list)
  eq("deck: no overflow when room", lay2.overflow, 0)
  eq("deck: empty keys are nil", lay2.items[4], nil)
end

-- ---- hotkey helpers --------------------------------------------------------
do
  local list = {
    { name = "a", status = "done" },
    { name = "b", status = "approval" },
    { name = "c", status = "approval" },
  }
  eq("nextApproval: first approval", core.nextApproval(list).name, "b")
  eq("frontSession: first item", core.frontSession(list).name, "a")
  eq("nextApproval: none -> nil", core.nextApproval({ { status = "idle" } }), nil)
end

-- ---- cycleNext: wrapping jump target ---------------------------------------
do
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  eq("cycle: nil start -> first", core.cycleNext(list, nil).key, "a")
  eq("cycle: after a -> b", core.cycleNext(list, "a").key, "b")
  eq("cycle: after c wraps -> a", core.cycleNext(list, "c").key, "a")
  eq("cycle: unknown key -> first", core.cycleNext(list, "zzz").key, "a")
  eq("cycle: empty list -> nil", core.cycleNext({}, "a"), nil)
end

-- ---- hotkey wiring: front approval -> approve via recorder -----------------
do
  local list = {
    { key = "w", name = "proj-w", status = "approval", gate = "waiting" },
    { key = "n", name = "proj-n", status = "working" },
  }
  local r = newRecorder()
  local target = core.nextApproval(list)
  core.handleAction(r.fx, target, "approve")
  eq("hotkey approve-front: targets the approval", target.key, "w")
  eq("hotkey approve-front: hands-free writeDecision", r.last().op, "writeDecision")
  eq("hotkey approve-front: allow", r.last().b, "allow")
end

-- ---- transcriptSnippet: latest assistant text from a jsonl tail -----------
do
  local function aline(text) -- an assistant line carrying one text block
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end
  local function toolline() -- an assistant line that is only a tool_use
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "tool_use", name = "Bash" } } } })
  end
  local userline = core.json.encode({ type = "user", message = { role = "user" } })

  -- last assistant text is "Refactoring the parser", even though a tool_use
  -- line and a user line come after it.
  local jsonl = table.concat({
    userline,
    aline("Refactoring the parser   now"),
    toolline(),
  }, "\n")
  eq("snippet: finds last assistant text (whitespace collapsed)",
     core.transcriptSnippet(jsonl), "Refactoring the parser now")

  eq("snippet: empty input -> nil", core.transcriptSnippet(""), nil)
  eq("snippet: no assistant text -> nil",
     core.transcriptSnippet(userline .. "\n" .. toolline()), nil)
  eq("snippet: garbled lines are skipped",
     core.transcriptSnippet("{ not json\n" .. aline("hello")), "hello")

  local long = string.rep("x", 300)
  local snip = core.transcriptSnippet(aline(long), 140)
  check("snippet: truncated to maxLen", #snip <= 140)
end

-- ---- Task queue: push / pop / depth / shouldFeed --------------------------
do
  eq("queue: push onto empty", core.queueDepth(core.queuePush(nil, "a")), 1)
  local q = core.queuePush(core.queuePush(nil, "a"), "b")
  eq("queue: depth after two pushes", core.queueDepth(q), 2)
  local first, rest = core.queuePop(q)
  eq("queue: pop returns front", first, "a")
  eq("queue: pop leaves the rest", core.queueDepth(rest), 1)
  eq("queue: pop next is b", (core.queuePop(rest)), "b")
  local none = core.queuePop({ tasks = {} })
  eq("queue: pop empty -> nil", none, nil)
  eq("queue: push ignores empty task", core.queueDepth(core.queuePush(nil, "")), 0)

  local q1 = { tasks = { "next" } }
  eq("feed: done transition with queue+auto -> true", core.shouldFeed("working", "done", q1, true), true)
  eq("feed: still done (no fresh transition) -> false", core.shouldFeed("done", "done", q1, true), false)
  eq("feed: empty queue -> false", core.shouldFeed("working", "done", { tasks = {} }, true), false)
  eq("feed: autofeed off -> false", core.shouldFeed("working", "done", q1, false), false)
  eq("feed: not done -> false", core.shouldFeed("working", "working", q1, true), false)
end

-- ---- shouldPrune: orphan + ghost cleanup ----------------------------------
do
  local opts = { pruneNoSid = true, pruneSeconds = 86400 }
  -- orphan: stale tile with no session_id
  local orphan = { stale = true, session_id = "", updated = 100 }
  eq("prune: stale + no session_id -> true", core.shouldPrune(orphan, 1000, opts), true)
  -- real session, stale but has a session_id, within the ghost window -> keep
  local realStale = { stale = true, session_id = "abc", updated = 1000 }
  eq("prune: stale but has session_id (recent) -> false", core.shouldPrune(realStale, 2000, opts), false)
  -- ghost backstop: very old even with a session_id
  local ghost = { stale = true, session_id = "abc", updated = 0 }
  eq("prune: older than backstop -> true", core.shouldPrune(ghost, 90000, opts), true)
  -- fresh, valid -> keep
  local fresh = { stale = false, session_id = "abc", updated = 1000 }
  eq("prune: fresh valid -> false", core.shouldPrune(fresh, 1010, opts), false)
  -- pruneNoSid off -> no orphan prune
  eq("prune: orphan kept when pruneNoSid off",
     core.shouldPrune(orphan, 1000, { pruneNoSid = false, pruneSeconds = 0 }), false)
end

-- ---- Policy A: approvalStale ----------------------------------------------
do
  eq("escalate: fresh approval -> false", core.approvalStale({ status = "approval", since = 100 }, 150, 60), false)
  eq("escalate: old approval -> true", core.approvalStale({ status = "approval", since = 100 }, 200, 60), true)
  eq("escalate: non-approval -> false", core.approvalStale({ status = "working", since = 0 }, 999, 60), false)
end

-- ---- Orchestrator: spawn command building + shell escaping ----------------
do
  eq("spawn: inner basic", core.spawnInner("/p", "hi"), "cd '/p' && claude 'hi'")
  eq("spawn: inner without a prompt", core.spawnInner("/p", ""), "cd '/p' && claude")
  -- a path with a space and a prompt with a single quote must stay safe
  eq("spawn: inner escapes single quotes",
     core.spawnInner("/my proj", "it's broken"),
     "cd '/my proj' && claude 'it'\\''s broken'")

  local as = core.spawnAppleScript("/p", "hi", { terminal = "Terminal" })
  eq("spawn: applescript exact",
     as, 'tell application "Terminal" to do script "cd \'/p\' && claude \'hi\'"')
  -- AppleScript double-quotes in the prompt must be backslash-escaped
  local as2 = core.spawnAppleScript("/p", 'say "hi"')
  check("spawn: escapes double quotes for AppleScript", as2:find('\\"hi\\"', 1, true) ~= nil)
  -- a single quote in the prompt survives both layers
  local as3 = core.spawnAppleScript("/p", "it's")
  check("spawn: handles single quotes", as3:find("'it'\\\\''s'", 1, true) ~= nil)
end

-- ---- caffeinate: pmset command builder + SleepDisabled parser --------------
do
  eq("pmset: on -> disablesleep 1", core.pmsetDisableSleepCmd(true), "/usr/bin/pmset -a disablesleep 1")
  eq("pmset: off -> disablesleep 0", core.pmsetDisableSleepCmd(false), "/usr/bin/pmset -a disablesleep 0")

  eq("sleepflag: parses 1 -> true", core.parseSleepDisabled(" SleepDisabled         1\n"), true)
  eq("sleepflag: parses 0 -> false", core.parseSleepDisabled("Some line\n SleepDisabled  0\nmore"), false)
  eq("sleepflag: absent field -> nil", core.parseSleepDisabled("System-wide power settings:\n"), nil)
  eq("sleepflag: non-string -> nil", core.parseSleepDisabled(nil), nil)
end

-- ---- parseToolList: normalize the editable gated-tools list ----------------
do
  eq("toollist: spaces pass through", core.parseToolList("Bash Write Edit"), "Bash Write Edit")
  eq("toollist: commas -> spaces", core.parseToolList("Bash, Write ,Edit"), "Bash Write Edit")
  eq("toollist: trims + drops blanks", core.parseToolList("  Bash   Write  "), "Bash Write")
  eq("toollist: de-dupes preserving order", core.parseToolList("Bash Write Bash Edit Write"), "Bash Write Edit")
  eq("toollist: empty -> empty", core.parseToolList(""), "")
  eq("toollist: nil -> empty", core.parseToolList(nil), "")
  eq("toollist: default constant", core.DEFAULT_GATE_TOOLS, "Bash Write Edit MultiEdit NotebookEdit")
end

-- ---- jsString: JS string literal with escaping (locks paste/relabel/close) --
do
  eq("jsString: plain wraps in quotes", core.jsString("hi"), '"hi"')
  eq("jsString: escapes a double quote", core.jsString('a"b'), '"a\\"b"')
  eq("jsString: escapes a newline", core.jsString("a\nb"), '"a\\nb"')
  eq("jsString: coerces non-string", core.jsString(42), '"42"')
end

-- ---- kitty remote control: detect state + idempotent enable ----------------
do
  -- bare conf: remote control off
  local d = core.kittyRemoteStatus("font_size 12\n")
  eq("kitty: bare conf -> not enabled", d.enabled, false)
  eq("kitty: bare conf -> not usable", d.usable, false)
  eq("kitty: explicit no -> not enabled", core.kittyRemoteStatus("allow_remote_control no\n").enabled, false)

  -- yes + listen_on -> usable from outside
  local u = core.kittyRemoteStatus("allow_remote_control yes\nlisten_on unix:/tmp/k\n")
  eq("kitty: yes+listen -> enabled", u.enabled, true)
  eq("kitty: yes+listen -> usable", u.usable, true)
  eq("kitty: captures listen socket", u.listen, "unix:/tmp/k")
  eq("kitty: yes but no listen -> not usable", core.kittyRemoteStatus("allow_remote_control yes\n").usable, false)

  eq("kitty: commented line ignored", core.kittyRemoteStatus("# allow_remote_control yes\n").enabled, false)
  eq("kitty: last directive wins", core.kittyRemoteStatus("allow_remote_control yes\nallow_remote_control no\n").enabled, false)

  -- enable from scratch: appends both, reports changed, keeps existing lines
  local t1, c1 = core.kittyConfWithRemote("font_size 12", "unix:/tmp/s")
  eq("kitty-enable: reports changed", c1, true)
  check("kitty-enable: keeps existing line", t1:find("font_size 12", 1, true) ~= nil)
  check("kitty-enable: adds allow yes", t1:find("allow_remote_control yes", 1, true) ~= nil)
  check("kitty-enable: adds listen socket", t1:find("listen_on unix:/tmp/s", 1, true) ~= nil)

  -- rewrites an explicit `no` to `yes`
  local t2, c2 = core.kittyConfWithRemote("allow_remote_control no\nlisten_on unix:/tmp/s")
  eq("kitty-enable: rewrites no -> changed", c2, true)
  check("kitty-enable: no became yes", t2:find("allow_remote_control yes", 1, true) ~= nil)
  check("kitty-enable: no leftover 'no'", t2:find("allow_remote_control no", 1, true) == nil)

  -- idempotent: already usable -> no change
  local _, c3 = core.kittyConfWithRemote("allow_remote_control yes\nlisten_on unix:/tmp/s")
  eq("kitty-enable: already enabled -> no change", c3, false)

  -- launch flags for self-spawned kitty
  local f = core.kittyLaunchRemoteFlags("unix:/tmp/z")
  eq("kitty-flags: -o first", f[1], "-o")
  eq("kitty-flags: allow_remote_control=yes", f[2], "allow_remote_control=yes")
  eq("kitty-flags: --listen-on", f[3], "--listen-on")
  eq("kitty-flags: socket passed through", f[4], "unix:/tmp/z")
  eq("kitty-flags: default socket when nil", core.kittyLaunchRemoteFlags(nil)[4], core.KITTY_SOCKET)
end

-- ---- spawnSpec: editor-aware spawn intent ----------------------------------
do
  local k = core.spawnSpec("kitty", "/Users/a/proj", "fix the bug", {})
  eq("spawnspec(kitty): kind", k.kind, "kitty")
  eq("spawnspec(kitty): kitty bin first", k.argv[1], "kitty")
  local joined = table.concat(k.argv, " ")
  check("spawnspec(kitty): has allow_remote_control", joined:find("allow_remote_control=yes", 1, true) ~= nil)
  check("spawnspec(kitty): has --listen-on", joined:find("--listen-on", 1, true) ~= nil)
  check("spawnspec(kitty): has --directory <project>", joined:find("--directory /Users/a/proj", 1, true) ~= nil)
  check("spawnspec(kitty): runs claude", joined:find(" claude", 1, true) ~= nil)
  eq("spawnspec(kitty): task is final argv element", k.argv[#k.argv], "fix the bug")

  eq("spawnspec(kitty): no task -> ends with claude", core.spawnSpec("kitty", "/p", nil, {}).argv[#core.spawnSpec("kitty", "/p", nil, {}).argv], "claude")

  local k3 = core.spawnSpec("kitty", "/p", nil, { kittyRemote = false })
  check("spawnspec(kitty): remote=false omits flags", table.concat(k3.argv, " "):find("allow_remote_control", 1, true) == nil)

  local k4 = core.spawnSpec("kitty", "/p", nil, { kittyBin = "/opt/homebrew/bin/kitty", kittySocket = "unix:/tmp/z" })
  eq("spawnspec(kitty): custom bin", k4.argv[1], "/opt/homebrew/bin/kitty")
  check("spawnspec(kitty): custom socket", table.concat(k4.argv, " "):find("unix:/tmp/z", 1, true) ~= nil)

  local k5 = core.spawnSpec("kitty", "/p", nil, { permissionMode = "plan" })
  check("spawnspec(kitty): permission-mode flag", table.concat(k5.argv, " "):find("--permission-mode plan", 1, true) ~= nil)

  local v = core.spawnSpec("vscode", "/Users/a/proj", "do it", {})
  eq("spawnspec(vscode): kind", v.kind, "vscode")
  eq("spawnspec(vscode): app", v.app, "Visual Studio Code")
  eq("spawnspec(vscode): project", v.project, "/Users/a/proj")
  eq("spawnspec(vscode): open-terminal key", v.openTerminalKey.key, "`")
  check("spawnspec(vscode): post types claude + quoted task", v.postType:find("claude 'do it'", 1, true) ~= nil)
  eq("spawnspec(cursor): app", core.spawnSpec("cursor", "/p", nil, {}).app, "Cursor")

  local t = core.spawnSpec("terminal", "/p", "hi", { terminal = "Terminal" })
  eq("spawnspec(terminal): kind", t.kind, "terminal")
  eq("spawnspec(terminal): applescript matches builder", t.applescript, core.spawnAppleScript("/p", "hi", { terminal = "Terminal" }))
  eq("spawnspec(nil): falls back to terminal", core.spawnSpec(nil, "/p", nil, {}).kind, "terminal")

  eq("spawnspec(kitty): tricky task stays one element", core.spawnSpec("kitty", "/p", "it's a test", {}).argv[#core.spawnSpec("kitty", "/p", "it's a test", {}).argv], "it's a test")
end

-- ---- spawnFlags ------------------------------------------------------------
do
  eq("spawnflags: none -> empty", #core.spawnFlags(nil, nil), 0)
  local f = core.spawnFlags("plan", "high")
  eq("spawnflags: mode -> --permission-mode", f[1], "--permission-mode")
  eq("spawnflags: mode value", f[2], "plan")
  eq("spawnflags: effort not emitted (no launch flag)", #f, 2)
end

-- ---- path helpers (folder browser) -----------------------------------------
do
  eq("normDir: strips trailing slash", core.normDir("/a/b/"), "/a/b")
  eq("normDir: keeps root", core.normDir("/"), "/")
  eq("normDir: empty stays empty", core.normDir(""), "")

  eq("pathJoin: simple", core.pathJoin("/a/b", "c"), "/a/b/c")
  eq("pathJoin: trailing slash base", core.pathJoin("/a/", "b"), "/a/b")
  eq("pathJoin: root base", core.pathJoin("/", "x"), "/x")

  eq("parentPath: nested", core.parentPath("/a/b/c"), "/a/b")
  eq("parentPath: single seg", core.parentPath("/a"), "/")
  eq("parentPath: root", core.parentPath("/"), "/")
  eq("parentPath: trailing slash", core.parentPath("/a/b/"), "/a")

  local b = core.breadcrumbs("/a/b")
  eq("breadcrumbs: count", #b, 3)
  eq("breadcrumbs: root first", b[1].path, "/")
  eq("breadcrumbs: mid path", b[2].path, "/a")
  eq("breadcrumbs: leaf name", b[3].name, "b")
  eq("breadcrumbs: leaf path", b[3].path, "/a/b")
  eq("breadcrumbs: root only", #core.breadcrumbs("/"), 1)

  eq("isVisibleDir: normal", core.isVisibleDir("src"), true)
  eq("isVisibleDir: dot", core.isVisibleDir("."), false)
  eq("isVisibleDir: dotdot", core.isVisibleDir(".."), false)
  eq("isVisibleDir: dotfile", core.isVisibleDir(".git"), false)

  local s = core.sortDirs({ "Zeb", "apple", "Banana" })
  eq("sortDirs: case-insensitive 1st", s[1], "apple")
  eq("sortDirs: case-insensitive 2nd", s[2], "Banana")
  eq("sortDirs: case-insensitive 3rd", s[3], "Zeb")
  local src = { "b", "a" }
  core.sortDirs(src)
  eq("sortDirs: does not mutate input", src[1], "b")
end

-- ---- recent dirs -----------------------------------------------------------
do
  local s0 = core.recentPush(nil, "/a")
  eq("recent: push onto empty -> 1", #s0.dirs, 1)
  eq("recent: pushed dir", s0.dirs[1], "/a")

  local s1 = core.recentPush(core.recentPush(s0, "/b"), "/a")
  eq("recent: re-push moves to front, no dup (len 2)", #s1.dirs, 2)
  eq("recent: front is re-pushed", s1.dirs[1], "/a")
  eq("recent: other kept", s1.dirs[2], "/b")

  eq("recent: trailing slash dedupes", #core.recentPush(core.recentPush(nil, "/a"), "/a/").dirs, 1)

  local capped = { dirs = {} }
  for i = 1, 5 do capped = core.recentPush(capped, "/d" .. i, 3) end
  eq("recent: respects cap", #capped.dirs, 3)
  eq("recent: newest first under cap", capped.dirs[1], "/d5")

  eq("recent: empty dir ignored", #core.recentPush(s0, "").dirs, 1)

  local seeded = core.recentSeed({ dirs = { "/a" } }, { "/a", "/b", "/c" })
  eq("recent-seed: keeps existing first", seeded.dirs[1], "/a")
  eq("recent-seed: appends new", seeded.dirs[2], "/b")
  eq("recent-seed: total", #seeded.dirs, 3)
  eq("recentList: nil -> empty", #core.recentList(nil), 0)
end

-- ---- new project -----------------------------------------------------------
do
  eq("safeName: simple", core.safeFolderName("my-proj"), "my-proj")
  eq("safeName: underscores/dots/spaces ok", core.safeFolderName("App_v2.1 beta"), "App_v2.1 beta")
  eq("safeName: trims", core.safeFolderName("  trimmed  "), "trimmed")
  eq("safeName: empty -> nil", core.safeFolderName(""), nil)
  eq("safeName: slash -> nil", core.safeFolderName("a/b"), nil)
  eq("safeName: dotdot -> nil", core.safeFolderName(".."), nil)
  eq("safeName: dot -> nil", core.safeFolderName("."), nil)
  eq("safeName: leading dash -> nil", core.safeFolderName("-x"), nil)

  eq("newProjectPath: builds under parent", core.newProjectPath("/Users/a/Programming", "new"), "/Users/a/Programming/new")
  eq("newProjectPath: bad name -> nil", core.newProjectPath("/p", "bad/name"), nil)
end

-- ---- Part A: kittyCmd argv builder + kittyKeyToken -------------------------
do
  local it = { kitty_window_id = "7", kitty_listen_on = "unix:/tmp/k", cwd = "/p" }
  local f = core.kittyCmd("focus", it, {})
  eq("kittyCmd: argv[1] is @", f[1], "@")
  eq("kittyCmd: --to flag", f[2], "--to")
  eq("kittyCmd: socket", f[3], "unix:/tmp/k")
  eq("kittyCmd: focus subcommand", f[4], "focus-window")
  eq("kittyCmd: --match", f[5], "--match")
  eq("kittyCmd: id selector", f[6], "id:7")

  eq("kittyCmd: close subcommand", core.kittyCmd("close", it, {})[4], "close-window")

  local k = core.kittyCmd("key", it, { token = "enter" })
  eq("kittyCmd: key subcommand", k[4], "send-key")
  eq("kittyCmd: key token last", k[#k], "enter")
  eq("kittyCmd: key without token -> nil", core.kittyCmd("key", it, {}), nil)

  local t = core.kittyCmd("text", it, { text = "hello" })
  eq("kittyCmd: text subcommand", t[4], "send-text")
  eq("kittyCmd: text -- guard", t[#t - 1], "--")
  eq("kittyCmd: text payload last", t[#t], "hello")
  eq("kittyCmd: empty text -> nil", core.kittyCmd("text", it, { text = "" }), nil)

  local ns = core.kittyCmd("focus", { kitty_window_id = "9", cwd = "/p" }, {})
  eq("kittyCmd: no socket -> no --to", ns[2], "focus-window")
  eq("kittyCmd: no socket selector", ns[4], "id:9")
  eq("kittyCmd: cwd fallback selector", core.kittyCmd("focus", { cwd = "/proj" }, {})[#core.kittyCmd("focus", { cwd = "/proj" }, {})], "cwd:/proj")
  eq("kittyCmd: untargetable -> nil", core.kittyCmd("focus", {}, {}), nil)
  eq("kittyCmd: unknown action -> nil", core.kittyCmd("bogus", it, {}), nil)

  eq("kittyKeyToken: return -> enter", core.kittyKeyToken({ mods = {}, key = "return" }), "enter")
  eq("kittyKeyToken: escape -> esc", core.kittyKeyToken({ mods = {}, key = "escape" }), "esc")
  eq("kittyKeyToken: shift+tab", core.kittyKeyToken({ mods = { "shift" }, key = "tab" }), "shift+tab")
  eq("kittyKeyToken: unknown base passes through", core.kittyKeyToken({ mods = {}, key = "x" }), "x")
end

-- ---- review #4: focusCandidates + titleFolderMatch -------------------------
do
  eq("titleMatch: folder segment after em-dash", core.titleFolderMatch("main.lua — autobottom", "autobottom"), true)
  eq("titleMatch: ignores file part", core.titleFolderMatch("autobottom.md — other", "autobottom"), false)
  eq("titleMatch: no em-dash uses whole title", core.titleFolderMatch("autobottom", "autobottom"), true)
  eq("titleMatch: empty needle -> false", core.titleFolderMatch("x — y", ""), false)

  local cands = core.focusCandidates("frontend", "/Users/adam/Programming/autobottom/frontend", "adam")
  eq("focusCands: name first", cands[1], "frontend")
  eq("focusCands: parent next (basename excluded)", cands[2], "autobottom")
  local joined = "," .. table.concat(cands, ",") .. ","
  check("focusCands: skips generics + user", not joined:find(",programming,") and not joined:find(",adam,") and not joined:find(",users,"))
end

-- ---- Part C: modeCycleSteps ------------------------------------------------
do
  eq("mode: default->plan = 2", core.modeCycleSteps("default", "plan", {}), 2)
  eq("mode: plan->default wraps = 1", core.modeCycleSteps("plan", "default", {}), 1)
  eq("mode: same = 0", core.modeCycleSteps("plan", "plan", {}), 0)
  eq("mode: acceptEdits->plan = 1", core.modeCycleSteps("acceptEdits", "plan", {}), 1)
  eq("mode: bypass disabled -> 0 (not in cycle)", core.modeCycleSteps("default", "bypassPermissions", {}), 0)
  eq("mode: default->bypass enabled = 3", core.modeCycleSteps("default", "bypassPermissions", { bypassPermissions = true }), 3)
  eq("mode: bypass->default wraps = 1", core.modeCycleSteps("bypassPermissions", "default", { bypassPermissions = true }), 1)
  eq("mode: unknown cur -> 0", core.modeCycleSteps("weird", "plan", {}), 0)
end

-- ---- Part E: mergeHooks (idempotent installer merge) -----------------------
do
  local template = { hooks = {
    Stop = { { hooks = { { type = "command", command = "bash cc-status.sh stop" } } } },
    PreToolUse = { { hooks = { { type = "command", command = "bash cc-approve.sh" } } } },
  } }
  local m1, c1 = core.mergeHooks({}, template)
  eq("mergeHooks: empty -> changed", c1, true)
  check("mergeHooks: Stop adopted", m1.hooks.Stop ~= nil)
  eq("mergeHooks: preserves other keys", core.mergeHooks({ model = "opus" }, template).model, "opus")
  local _, c3 = core.mergeHooks(m1, template)
  eq("mergeHooks: re-run is a no-op", c3, false)
  local userHooks = { hooks = { Stop = { { hooks = { { type = "command", command = "bash my-own.sh" } } } } } }
  local m4, c4 = core.mergeHooks(userHooks, template)
  eq("mergeHooks: user-hook event -> changed", c4, true)
  eq("mergeHooks: keeps user's group first", m4.hooks.Stop[1].hooks[1].command, "bash my-own.sh")
  eq("mergeHooks: appends ours after (2 groups)", #m4.hooks.Stop, 2)
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
