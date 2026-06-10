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

  -- model: live /model switch types the slash command into the window
  r = newRecorder()
  core.handleAction(r.fx, normal, "model", "claude-sonnet-4-6")
  eq("model: typeIntoWindow op", r.last().op, "typeIntoWindow")
  eq("model: types the /model command", r.last().b, "/model claude-sonnet-4-6")

  r = newRecorder()
  core.handleAction(r.fx, normal, "model", "")
  eq("model: empty id is a no-op", r.count(), 0)
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

-- ---- provider profiles: lookup, env injection, /model command --------------
do
  local an = { id = "opus", kind = "anthropic", model = "claude-opus-4-8" }
  local gw = { id = "gemini", kind = "gateway", baseUrl = "http://localhost:4000",
               model = "gemini-2.5-pro", authTokenEnv = "MY_LITELLM_KEY",
               smallFastModel = "gemini-flash", headers = "X-Foo: bar" }
  local cfg = { providers = { an, gw } }

  -- providerById
  eq("provider: by id found", core.providerById(cfg, "gemini").model, "gemini-2.5-pro")
  eq("provider: anthropic by id", core.providerById(cfg, "opus").kind, "anthropic")
  eq("provider: missing id -> nil", core.providerById(cfg, "nope"), nil)
  eq("provider: empty id -> nil", core.providerById(cfg, ""), nil)
  eq("provider: no providers key -> nil", core.providerById({}, "opus"), nil)

  -- providerEnv: anthropic sets just ANTHROPIC_MODEL (so the hook can see it)
  local ea = core.providerEnv(an)
  eq("providerenv: anthropic count", #ea, 1)
  eq("providerenv: anthropic model name", ea[1].name, "ANTHROPIC_MODEL")
  eq("providerenv: anthropic model value", ea[1].value, "claude-opus-4-8")
  eq("providerenv: nil -> empty", #core.providerEnv(nil), 0)
  eq("providerenv: model-less anthropic -> empty", #core.providerEnv({ kind = "anthropic" }), 0)

  -- providerEnv: gateway sets base/model/small-fast/headers + auth as a $VAR secret
  local e = core.providerEnv(gw)
  eq("providerenv: gateway count", #e, 5)
  eq("providerenv: base url first", e[1].name, "ANTHROPIC_BASE_URL")
  eq("providerenv: base url value", e[1].value, "http://localhost:4000")
  eq("providerenv: base url not secret", e[1].secret, false)
  eq("providerenv: model second", e[2].name, "ANTHROPIC_MODEL")
  eq("providerenv: model value", e[2].value, "gemini-2.5-pro")
  eq("providerenv: small-fast model", e[3].name, "ANTHROPIC_SMALL_FAST_MODEL")
  eq("providerenv: custom headers", e[4].name, "ANTHROPIC_CUSTOM_HEADERS")
  eq("providerenv: auth token name", e[5].name, "ANTHROPIC_AUTH_TOKEN")
  eq("providerenv: auth is a $VAR ref", e[5].value, "$MY_LITELLM_KEY")
  eq("providerenv: auth marked secret", e[5].secret, true)
  -- gateway without a model still injects base url; no auth when no env name
  local gw2 = { kind = "gateway", baseUrl = "http://x" }
  eq("providerenv: gateway no-model/no-auth count", #core.providerEnv(gw2), 1)

  -- envPrefix: literals single-quoted, secrets double-quoted (shell-expanded)
  eq("envprefix: empty list -> empty", core.envPrefix({}), "")
  eq("envprefix: nil -> empty", core.envPrefix(nil), "")
  local pre = core.envPrefix(e)
  eq("envprefix: exact",
     pre,
     "ANTHROPIC_BASE_URL='http://localhost:4000' ANTHROPIC_MODEL='gemini-2.5-pro' "
     .. "ANTHROPIC_SMALL_FAST_MODEL='gemini-flash' ANTHROPIC_CUSTOM_HEADERS='X-Foo: bar' "
     .. "ANTHROPIC_AUTH_TOKEN=\"$MY_LITELLM_KEY\" ")

  -- modelCommand: live /model switch
  eq("modelcmd: builds /model", core.modelCommand("claude-sonnet-4-6"), "/model claude-sonnet-4-6")
  eq("modelcmd: empty -> nil", core.modelCommand(""), nil)
  eq("modelcmd: nil -> nil", core.modelCommand(nil), nil)
end

-- ---- spawn with a provider: env injection through every editor path --------
do
  local gw = { id = "gemini", kind = "gateway", baseUrl = "http://localhost:4000",
               model = "gemini-2.5-pro", authTokenEnv = "MY_LITELLM_KEY" }
  local env = core.providerEnv(gw)

  -- spawnInner: env prefix (incl. ANTHROPIC_MODEL) + prompt, in order
  eq("spawn-inner(env): exact",
     core.spawnInner("/p", "hi", { env = env }),
     "cd '/p' && ANTHROPIC_BASE_URL='http://localhost:4000' ANTHROPIC_MODEL='gemini-2.5-pro' "
     .. "ANTHROPIC_AUTH_TOKEN=\"$MY_LITELLM_KEY\" claude 'hi'")
  -- no opts -> byte-identical to the original two-arg form
  eq("spawn-inner: no-opts unchanged", core.spawnInner("/p", "hi"), "cd '/p' && claude 'hi'")

  -- terminal path threads the env into the AppleScript
  local t = core.spawnSpec("terminal", "/p", "hi", { terminal = "Terminal", env = env })
  check("spawnspec(terminal,env): has base url", t.applescript:find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
  check("spawnspec(terminal,env): has model env", t.applescript:find("ANTHROPIC_MODEL=", 1, true) ~= nil)
  check("spawnspec(terminal,env): auth stays a $VAR", t.applescript:find("$MY_LITELLM_KEY", 1, true) ~= nil)

  -- vscode path prefixes the typed command with the env
  local v = core.spawnSpec("vscode", "/p", "hi", { env = env })
  check("spawnspec(vscode,env): post has base url", v.postType:find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
  check("spawnspec(vscode,env): post has model env", v.postType:find("ANTHROPIC_MODEL=", 1, true) ~= nil)

  -- kitty path wraps the inner in a login shell so $VAR expands
  local k = core.spawnSpec("kitty", "/p", "hi", { env = env })
  eq("spawnspec(kitty,env): runs via login shell", k.argv[#k.argv - 1], "-lc")
  check("spawnspec(kitty,env): inner has env + model",
        k.argv[#k.argv]:find("ANTHROPIC_BASE_URL=", 1, true) ~= nil
        and k.argv[#k.argv]:find("ANTHROPIC_MODEL=", 1, true) ~= nil)
  check("spawnspec(kitty,env): still has --directory", table.concat(k.argv, " "):find("--directory /p", 1, true) ~= nil)
  -- no-provider kitty path is unchanged (bare `claude`, task as final element)
  local kp = core.spawnSpec("kitty", "/p", "hi", {})
  eq("spawnspec(kitty): no-provider ends with task", kp.argv[#kp.argv], "hi")
  eq("spawnspec(kitty): no-provider has bare claude", kp.argv[#kp.argv - 1], "claude")
end

-- ---- SSH remote harness (Phase 2): run claude on another box ---------------
do
  -- sshWrap: single-quotes the whole inner so its $VAR expands on the REMOTE host
  eq("sshwrap: user@host + -t",
     core.sshWrap("claude", { host = "gpubox", user = "adam" }),
     "ssh -t adam@gpubox 'claude'")
  eq("sshwrap: host only (no user)",
     core.sshWrap("x", { host = "gpubox" }), "ssh -t gpubox 'x'")
  eq("sshwrap: tty=false drops -t",
     core.sshWrap("x", { host = "h", tty = false }), "ssh h 'x'")
  eq("sshwrap: no ssh -> inner unchanged", core.sshWrap("claude", nil), "claude")
  eq("sshwrap: empty host -> unchanged", core.sshWrap("claude", { host = "" }), "claude")

  local gw = { kind = "gateway", baseUrl = "http://localhost:4000",
               model = "ollama/llama3", authTokenEnv = "LOCAL_GW_KEY" }
  local env = core.providerEnv(gw)
  local ssh = { host = "gpubox", user = "adam" }

  -- spawnInner wraps the env-injected command in ssh; the auth $VAR stays for the
  -- REMOTE shell (single-quoted, not expanded locally)
  local inner = core.spawnInner("/remote/proj", "go", { env = env, ssh = ssh })
  check("spawn-inner(ssh): starts with ssh -t adam@gpubox", inner:find("^ssh %-t adam@gpubox ") ~= nil)
  check("spawn-inner(ssh): carries the remote cd", inner:find("cd ", 1, true) ~= nil)
  check("spawn-inner(ssh): auth $VAR preserved for remote", inner:find("$LOCAL_GW_KEY", 1, true) ~= nil)

  -- terminal path: AppleScript runs the ssh command
  local t = core.spawnSpec("terminal", "/remote/proj", "go", { terminal = "Terminal", env = env, ssh = ssh })
  check("spawnspec(terminal,ssh): applescript runs ssh", t.applescript:find("ssh -t adam@gpubox", 1, true) ~= nil)

  -- kitty path: runs ssh directly (no local login shell), inner as one argv element
  local k = core.spawnSpec("kitty", "/remote/proj", "go", { env = env, ssh = ssh })
  local ai
  for i, a in ipairs(k.argv) do if a == "ssh" then ai = i end end
  check("spawnspec(kitty,ssh): has ssh in argv", ai ~= nil)
  eq("spawnspec(kitty,ssh): -t after ssh", k.argv[ai + 1], "-t")
  eq("spawnspec(kitty,ssh): dest after -t", k.argv[ai + 2], "adam@gpubox")
  check("spawnspec(kitty,ssh): inner is one argv element with env",
        (k.argv[ai + 3] or ""):find("ANTHROPIC_BASE_URL=", 1, true) ~= nil)
end

-- ---- token usage: parse + aggregate transcript usage (zero-cost, local) -----
do
  -- isoToEpoch: UTC, tz-independent (compare deltas, not absolute local time)
  eq("iso: unix epoch start", core.isoToEpoch("1970-01-01T00:00:00.000Z"), 0)
  eq("iso: one day later", core.isoToEpoch("1970-01-02T00:00:00Z"), 86400)
  eq("iso: one hour", core.isoToEpoch("1970-01-01T01:00:00Z"), 3600)
  eq("iso: garbage -> nil", core.isoToEpoch("not-a-date"), nil)
  -- a known recent instant: 2026-01-01T00:00:00Z
  local jan1 = core.isoToEpoch("2026-01-01T00:00:00Z")
  eq("iso: a day after jan1 2026", core.isoToEpoch("2026-01-02T00:00:00Z") - jan1, 86400)

  -- parseUsageLine: real transcript line shape
  local line = '{"type":"assistant","timestamp":"2026-06-09T12:00:00.000Z","message":'
    .. '{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,'
    .. '"cache_read_input_tokens":1000,"cache_creation_input_tokens":300}}}'
  local e = core.parseUsageLine(line)
  eq("parse: model", e.model, "claude-opus-4-8")
  eq("parse: input", e.input, 10)
  eq("parse: output", e.output, 20)
  eq("parse: cacheRead", e.cacheRead, 1000)
  eq("parse: cacheCreate", e.cacheCreate, 300)
  eq("parse: ts is epoch", e.ts, core.isoToEpoch("2026-06-09T12:00:00.000Z"))
  -- non-usage / non-assistant lines are skipped
  eq("parse: user line -> nil", core.parseUsageLine('{"type":"user","message":{}}'), nil)
  eq("parse: assistant w/o usage -> nil", core.parseUsageLine('{"type":"assistant","message":{"model":"x"}}'), nil)
  eq("parse: blank -> nil", core.parseUsageLine(""), nil)
  eq("parse: partial tail (no leading brace) -> nil", core.parseUsageLine('tokens":5}'), nil)

  -- contextTokens / contextFraction
  eq("ctx: tokens = input+cacheRead+cacheCreate", core.contextTokens(e), 10 + 1000 + 300)
  eq("ctx: fraction vs default 200k", core.contextFraction(100000), 0.5)
  eq("ctx: fraction clamps >1", core.contextFraction(500000), 1)
  eq("ctx: fraction custom limit (gemini 1M)", core.contextFraction(500000, 1000000), 0.5)
  eq("ctx: zero limit -> 0", core.contextFraction(100, 0), 0)

  -- sumUsage: cumulative + per-model
  local events = {
    { model = "claude-opus-4-8", input = 10, output = 20, cacheRead = 100, cacheCreate = 5, ts = 1000 },
    { model = "claude-opus-4-8", input = 1,  output = 2,  cacheRead = 10,  cacheCreate = 0, ts = 2000 },
    { model = "gemini-2.5-pro",  input = 7,  output = 3,  cacheRead = 0,   cacheCreate = 0, ts = 3000 },
  }
  local s = core.sumUsage(events)
  eq("sum: input", s.input, 18)
  eq("sum: output", s.output, 25)
  eq("sum: total (gross, incl cache reads)", s.total, 18 + 25 + 110 + 5)
  eq("sum: real (excl cache reads)", s.real, 18 + 25 + 5)
  eq("sum: opus per-model output", s.byModel["claude-opus-4-8"].output, 22)
  eq("sum: gemini per-model total", s.byModel["gemini-2.5-pro"].total, 10)
  eq("sum: opus per-model real (excl cacheRead 110)", s.byModel["claude-opus-4-8"].real, 11 + 22 + 5)
  eq("sum: empty -> zero total", core.sumUsage({}).total, 0)
  eq("sum: empty -> zero real", core.sumUsage({}).real, 0)

  -- usageInWindow: rolling sum of REAL tokens (excl cacheRead). now=3500, 1500s -> ts>=2000
  eq("window: last 1500s (real)", core.usageInWindow(events, 3500, 1500), (1+2+0) + (7+3+0))
  eq("window: huge window catches all (real)", core.usageInWindow(events, 3500, 999999), s.real)
  eq("window: zero window -> 0", core.usageInWindow(events, 3500, 0), 0)

  -- formatTokens
  eq("fmt: small int", core.formatTokens(42), "42")
  eq("fmt: thousands", core.formatTokens(254337), "254.3k")
  eq("fmt: millions", core.formatTokens(1300000), "1.30M")

  -- usageBarLevel thresholds
  eq("level: ok", core.usageBarLevel(0.5), "ok")
  eq("level: warn at .75", core.usageBarLevel(0.8), "warn")
  eq("level: full at .9", core.usageBarLevel(0.95), "full")

  -- isAnthropicSession: scopes the plan-window bar
  eq("anthropic: claude model, no base url", core.isAnthropicSession("claude-opus-4-8", nil), true)
  eq("anthropic: empty model defaults true", core.isAnthropicSession("", ""), true)
  eq("anthropic: gateway base url -> false", core.isAnthropicSession("claude-opus-4-8", "http://localhost:4000"), false)
  eq("anthropic: gemini model -> false", core.isAnthropicSession("gemini-2.5-pro", nil), false)

  -- lastUsage: scan a tail bottom-up for the most recent usage line
  local tail = table.concat({
    '{"type":"user","message":{"role":"user"}}',
    line,  -- the opus usage line built above
    '{"type":"assistant","timestamp":"2026-06-09T13:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5,"output_tokens":6,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}',
    'partial-half-written-line-no-brace',
  }, "\n")
  local lu = core.lastUsage(tail)
  eq("lastusage: picks the most recent complete usage", lu.model, "claude-sonnet-4-6")
  eq("lastusage: its context tokens", core.contextTokens(lu), 5 + 2000 + 0)
  eq("lastusage: empty -> nil", core.lastUsage(""), nil)

  -- contextLimitFor: provider override > built-in model map > default
  local cfg = { providers = {
    { id = "gemini", model = "gemini-2.5-pro", contextLimit = 1500000 },
    { id = "opus", model = "claude-opus-4-8" } } }
  eq("ctxlimit: gemini override wins", core.contextLimitFor(cfg, "gemini-2.5-pro"), 1500000)
  eq("ctxlimit: opus-4 model map -> 1M", core.contextLimitFor(cfg, "claude-opus-4-8"), 1000000)
  eq("ctxlimit: sonnet-4 model map -> 1M", core.contextLimitFor({}, "claude-sonnet-4-6"), 1000000)
  eq("ctxlimit: haiku -> 200k default", core.contextLimitFor({}, "claude-haiku-4-5"), 200000)
  eq("ctxlimit: unknown model -> default", core.contextLimitFor({}, "mystery"), 200000)
  eq("ctxlimit: no config -> default", core.contextLimitFor({}, "x"), 200000)

  -- nextContextTier: round observed up to a standard window
  eq("tier: 150k -> 200k", core.nextContextTier(150000), 200000)
  eq("tier: 437k -> 1M", core.nextContextTier(437000), 1000000)
  eq("tier: 1.4M -> 2M", core.nextContextTier(1400000), 2000000)

  -- contextFractionFor: the real bug case — 437k on opus-4-8 is ~44% of 1M, NOT 100%
  local frac, lim = core.contextFractionFor({}, "claude-opus-4-8", 437000)
  eq("ctxfrac: opus 437k limit is 1M", lim, 1000000)
  check("ctxfrac: opus 437k ~= 0.44 (not full)", frac > 0.43 and frac < 0.45)
  -- self-heal: unknown model at 437k uses the 1M tier, not a false 100%
  local f2, l2 = core.contextFractionFor({}, "mystery-model", 437000)
  eq("ctxfrac: unknown 437k bumped to 1M tier", l2, 1000000)
  check("ctxfrac: unknown 437k not full", f2 < 0.5)
  -- a genuinely full 200k model still reads ~100%
  local f3 = core.contextFractionFor({}, "claude-haiku-4-5", 198000)
  check("ctxfrac: haiku 198k/200k ~ full", f3 >= 0.98)
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

-- ---- Audit ledger: parse / filter / retention / narrative -----------------
do
  local text = table.concat({
    core.json.encode({ v = 1, ts = 100, id = "a", type = "prompt",
                       session_id = "s1", name = "proj", prompt = "fix bug" }),
    "",                                  -- blank line tolerated
    "{ partial tail line",               -- malformed tolerated
    core.json.encode({ v = 1, ts = 200, id = "b", type = "decision",
                       session_id = "s1", name = "proj", tool = "Bash", summary = "rm -rf x",
                       outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" }),
    core.json.encode({ v = 1, ts = 150, id = "c", type = "prompt",
                       session_id = "s2", name = "other", prompt = "hi" }),
    core.json.encode({ ts = 50 }),       -- no type -> dropped
  }, "\n")
  local evs = core.parseLedger(text)
  eq("parseLedger: keeps only well-formed events", #evs, 3)

  local f1 = core.filterLedger(evs, { session = "s1" })
  eq("filterLedger: session match count", #f1, 2)
  eq("filterLedger: newest first", f1[1].ts, 200)
  eq("filterLedger: by type (list)", #core.filterLedger(evs, { types = { "decision" } }), 1)
  eq("filterLedger: by type (set)", #core.filterLedger(evs, { types = { decision = true } }), 1)
  eq("filterLedger: time window", #core.filterLedger(evs, { sinceTs = 120, untilTs = 180 }), 1)
  eq("filterLedger: empty types = all", #core.filterLedger(evs, { types = {} }), 3)

  eq("ledgerFileEpoch: parses daily name", core.ledgerFileEpoch("2026-01-01.jsonl"),
     core.isoToEpoch("2026-01-01T00:00:00Z"))
  eq("ledgerFileEpoch: rejects non-ledger", core.ledgerFileEpoch("notes.txt"), nil)

  local files = { "2026-01-01.jsonl", "2026-06-01.jsonl", "2026-06-09.jsonl", "exports" }
  local now = core.isoToEpoch("2026-06-09T00:00:00Z")
  local exp = core.expiredLedgerFiles(files, now, 30)
  eq("expiredLedgerFiles: 30d cutoff count", #exp, 1)
  eq("expiredLedgerFiles: drops the oldest", exp[1], "2026-01-01.jsonl")
  eq("expiredLedgerFiles: retention 0 = keep all", #core.expiredLedgerFiles(files, now, 0), 0)

  check("narrateEvent: decision shows provenance",
    core.narrateEvent({ type = "decision", outcome = "deny", tool = "Bash", summary = "x",
                        by = "autoDeny", pattern = "Bash(rm*)" }):find("autoDeny", 1, true) ~= nil)
  check("renderNarrative: contains a prompt line",
    core.renderNarrative(evs):find("fix bug", 1, true) ~= nil)
  check("renderNarrative: empty -> placeholder",
    core.renderNarrative({}):find("no activity", 1, true) ~= nil)
  check("auditReviewPrompt: read-only instruction",
    core.auditReviewPrompt("LOG", { scope = "session proj" }):find("READ%-ONLY") ~= nil)
  check("auditReviewPrompt: embeds the narrative",
    core.auditReviewPrompt("LOGTEXT"):find("LOGTEXT", 1, true) ~= nil)
end

-- ---- Improve cards: bug fixes + previously-untested branches --------------
do
  local function aline(text)
    return core.json.encode({ type = "assistant", message = { role = "assistant",
      content = { { type = "text", text = text } } } })
  end

  -- repoFromRemote: scp, https, and the new ssh:// (with user+port) form
  eq("repo: scp-style git@host:owner/repo.git",
     core.repoFromRemote("git@github.com:WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: https with .git",
     core.repoFromRemote("https://github.com/WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: ssh://user@host:port/owner/repo.git",
     core.repoFromRemote("ssh://git@github.com:22/WSAdam/claude-shepherd.git"), "WSAdam/claude-shepherd")
  eq("repo: ssh:// without user", core.repoFromRemote("ssh://github.com/o/r"), "o/r")

  -- transcriptSnippet: whitespace-only block is skipped to the older real text
  eq("snippet: whitespace-only block skipped",
     core.transcriptSnippet(aline("real answer") .. "\n" .. aline("   ")), "real answer")
  eq("snippet: only-whitespace -> nil", core.transcriptSnippet(aline("   \n  ")), nil)
  -- multiple text blocks on one assistant line: the last non-empty wins
  local multi = core.json.encode({ type = "assistant", message = { role = "assistant",
    content = { { type = "text", text = "first" }, { type = "text", text = "second" } } } })
  eq("snippet: last text block wins", core.transcriptSnippet(multi), "second")
  -- truncation appends the … ellipsis and preserves a prefix of the original
  local snip = core.transcriptSnippet(aline(string.rep("a", 300)), 20)
  check("snippet: truncation appends ellipsis", snip:sub(-3) == "\226\128\166")
  check("snippet: truncation keeps a prefix", snip:sub(1, 3) == "aaa")
  -- UTF-8 boundary: a run of 3-byte glyphs is never split mid-character
  local usnip = core.transcriptSnippet(aline(string.rep("\226\128\166", 30)), 20)
  check("snippet: utf8-safe within bound", #usnip <= 20)
  check("snippet: utf8-safe keeps whole glyphs only", (#usnip:sub(1, #usnip - 3) % 3) == 0)

  -- shouldPrune: session_id == nil (not just "") is an orphan; pruneSeconds=0 off
  local opts = { pruneNoSid = true, pruneSeconds = 86400 }
  eq("prune: nil session_id orphan -> true",
     core.shouldPrune({ stale = true, session_id = nil, updated = 100 }, 1000, opts), true)
  local noBackstop = { pruneNoSid = true, pruneSeconds = 0 }
  eq("prune: pruneSeconds=0 disables ghost backstop",
     core.shouldPrune({ stale = true, session_id = "abc", updated = 0 }, 9e9, noBackstop), false)
  eq("prune: pruneSeconds=0 still prunes a true orphan",
     core.shouldPrune({ stale = true, session_id = "", updated = 0 }, 9e9, noBackstop), true)

  -- cycleNext advances on repeated calls, threading the prior key (the hotkey loop)
  local list = { { key = "a" }, { key = "b" }, { key = "c" } }
  local k = core.cycleNext(list, nil).key;  eq("cycle: 1st -> a", k, "a")
  k = core.cycleNext(list, k).key;          eq("cycle: 2nd -> b", k, "b")
  k = core.cycleNext(list, k).key;          eq("cycle: 3rd -> c", k, "c")
  k = core.cycleNext(list, k).key;          eq("cycle: 4th wraps -> a", k, "a")

  -- jump-needy fallback: no approval -> frontSession is the target
  local idleList = { { key = "x", name = "x", status = "idle" }, { key = "y", name = "y", status = "working" } }
  eq("jump-needy: falls back to front session",
     (core.nextApproval(idleList) or core.frontSession(idleList)).key, "x")

  -- parseStatusList: same-status entries break ties by name (apple before zebra)
  local sorted = core.parseStatusList({
    { key = "k2", content = core.json.encode({ name = "zebra", status = "working", updated = 100 }) },
    { key = "k1", content = core.json.encode({ name = "apple", status = "working", updated = 100 }) },
  }, 100, 9999)
  eq("parseStatusList: name tiebreak within status", sorted[1].name, "apple")

  -- usageInWindow: only events whose ts is inside [now-window, now] count
  local now = 10000
  eq("usageInWindow: only in-window events count", core.usageInWindow({
    { ts = now - 10, input = 1, output = 1, cacheCreate = 0 },  -- in window -> 2
    { ts = now - 99999, input = 5, output = 5 },                -- outside -> 0
    { input = 9, output = 9 },                                  -- no ts -> skipped
  }, now, 3600), 2)

  -- isoToEpoch: a 2024 leap day (Feb 29 exists) -> Feb 28 to Mar 1 spans two days
  eq("iso: 2024 leap day spans Feb 29",
     core.isoToEpoch("2024-03-01T00:00:00Z") - core.isoToEpoch("2024-02-28T00:00:00Z"), 2 * 86400)
end

-- ---- fmtDuration -----------------------------------------------------------
do
  eq("fmt: seconds", core.fmtDuration(45), "45s")
  eq("fmt: minutes+seconds", core.fmtDuration(90), "1m 30s")
  eq("fmt: whole minutes", core.fmtDuration(120), "2m")
  eq("fmt: hours+minutes", core.fmtDuration(3600 + 5 * 60), "1h 5m")
  eq("fmt: whole hours", core.fmtDuration(7200), "2h")
  eq("fmt: negative clamps to 0s", core.fmtDuration(-5), "0s")
end

-- ---- fleetStats: aggregate the ledger --------------------------------------
do
  local evs = {
    { ts = 10, type = "session_start", session_id = "s1", name = "alpha" },
    { ts = 20, type = "prompt",        session_id = "s1", name = "alpha" },
    { ts = 30, type = "prompt",        session_id = "s1", name = "alpha" },
    { ts = 40, type = "tool_request",  session_id = "s1", name = "alpha", tool = "Bash" },
    { ts = 70, type = "decision",      session_id = "s1", name = "alpha", outcome = "allow", by = "human" },
    { ts = 80, type = "decision",      session_id = "s1", name = "alpha", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 25, type = "prompt",        session_id = "s2", name = "bravo" },
    { ts = 35, type = "decision",      session_id = "s2", name = "bravo", outcome = "fallback", by = "timeout-fallback" },
    { ts = 50, type = "spawn",         session_id = "s2", name = "bravo" },
  }
  local st = core.fleetStats(evs, { now = 200, topN = 8 })
  eq("fleet: total prompts", st.totals.prompts, 3)
  eq("fleet: total sessions", st.totals.sessions, 2)
  eq("fleet: total spawns", st.totals.spawns, 1)
  eq("fleet: total toolRequests", st.totals.toolRequests, 1)
  eq("fleet: decisions allow", st.decisions.allow, 1)
  eq("fleet: decisions deny", st.decisions.deny, 1)
  eq("fleet: decisions fallback (own bucket, not a denial)", st.decisions.fallback, 1)
  eq("fleet: decisions total", st.decisions.total, 3)
  eq("fleet: provenance autoDeny", st.provenance.autoDeny, 1)
  eq("fleet: provenance timeout-fallback", st.provenance["timeout-fallback"], 1)
  eq("fleet: provenance human", st.provenance.human, 1)
  eq("fleet: most active session is s1", st.mostActive[1].session_id, "s1")
  eq("fleet: most active prompt count", st.mostActive[1].prompts, 2)
  -- s1 request@40 -> human decision@70 = 30s; s2's fallback has no preceding request
  eq("fleet: approval blocked seconds", st.approvalBlockedSeconds, 30)
  check("fleet: fleet denial rate ~1/3", math.abs(st.denialRate - (1 / 3)) < 1e-9)
end

-- ---- sessionRisk: empirical per-session score ------------------------------
do
  local clean = {
    { ts = 10, type = "tool_request", session_id = "c", tool = "Bash" },
    { ts = 15, type = "decision", session_id = "c", outcome = "allow", by = "human" },
    { ts = 20, type = "tool_request", session_id = "c", tool = "Edit" },
    { ts = 25, type = "decision", session_id = "c", outcome = "allow", by = "human" },
  }
  local rc = core.sessionRisk(clean, {})
  eq("risk: clean band low", rc.band, "low")
  check("risk: clean score small (<=5)", rc.score <= 5)
  eq("risk: empty -> score 0", core.sessionRisk({}, {}).score, 0)
  eq("risk: empty -> band low", core.sessionRisk({}, {}).band, "low")
  eq("risk: deterministic", core.sessionRisk(clean, {}).score, core.sessionRisk(clean, {}).score)

  local mid = {
    { ts = 10, type = "tool_request", session_id = "m", tool = "Bash" },
    { ts = 12, type = "decision", session_id = "m", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 20, type = "tool_request", session_id = "m", tool = "Bash" },
    { ts = 22, type = "decision", session_id = "m", outcome = "deny", by = "autoDeny", pattern = "Bash(curl*)" },
    { ts = 30, type = "tool_request", session_id = "m", tool = "Edit" },
    { ts = 32, type = "decision", session_id = "m", outcome = "allow", by = "human" },
    { ts = 40, type = "tool_request", session_id = "m", tool = "Edit" },
    { ts = 42, type = "decision", session_id = "m", outcome = "allow", by = "human" },
  }
  eq("risk: mid band med", core.sessionRisk(mid, {}).band, "med")

  local risky = {
    { ts = 10,  type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 400, type = "decision", session_id = "h", outcome = "deny", by = "human" },   -- stale (390s) deny
    { ts = 410, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 412, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 420, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 422, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(curl*)" },
    { ts = 430, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 432, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Bash(rm*)" },
    { ts = 440, type = "tool_request", session_id = "h", tool = "Write" },
    { ts = 442, type = "decision", session_id = "h", outcome = "deny", by = "autoDeny", pattern = "Write" },
    { ts = 450, type = "tool_request", session_id = "h", tool = "Bash" },
    { ts = 452, type = "decision", session_id = "h", outcome = "fallback", by = "timeout-fallback" },
  }
  local rh = core.sessionRisk(risky, {})
  eq("risk: risky band high", rh.band, "high")
  check("risk: score clamped <= 100", rh.score <= 100)
  eq("risk: signals autoDenyHits", rh.signals.autoDenyHits, 4)
  eq("risk: signals timeoutFallbacks", rh.signals.timeoutFallbacks, 1)
  eq("risk: signals staleApprovals", rh.signals.staleApprovals, 1)
end

-- ---- resolveGateTools: per-session precedence + sentinel -------------------
do
  eq("gate: no inputs -> built-in default", core.resolveGateTools(nil, nil, nil), core.DEFAULT_GATE_TOOLS)
  eq("gate: fleet default used", core.resolveGateTools(nil, nil, "Bash Edit"), "Bash Edit")
  eq("gate: session override wins", core.resolveGateTools("WebFetch Bash", nil, "Bash Edit"), "WebFetch Bash")
  eq("gate: sentinel '-' gates nothing", core.resolveGateTools("-", nil, "Bash Edit"), "")
  eq("gate: sentinel NONE gates nothing", core.resolveGateTools("NONE", nil, "Bash"), "")
  eq("gate: sentinel none (lower) gates nothing", core.resolveGateTools("none", nil, "Bash"), "")
  eq("gate: blank override is NOT an override", core.resolveGateTools("   ", nil, "Bash Edit"), "Bash Edit")
  eq("gate: empty override is NOT an override", core.resolveGateTools("", nil, "Bash Edit"), "Bash Edit")
  eq("gate: override normalized + deduped", core.resolveGateTools("Bash, Edit ,Bash", nil, nil), "Bash Edit")
  eq("gate: provider-default layer", core.resolveGateTools(nil, "Write", "Bash"), "Write")
  eq("gate: override beats provider default", core.resolveGateTools("Edit", "Write", "Bash"), "Edit")
end

-- ---- shouldDrainClose: fire only on a fresh transition into done -----------
do
  eq("drain: working->done fires", core.shouldDrainClose(true, "working", "done"), true)
  eq("drain: approval->done fires", core.shouldDrainClose(true, "approval", "done"), true)
  eq("drain: done->done no fire (already handled)", core.shouldDrainClose(true, "done", "done"), false)
  eq("drain: not draining no fire", core.shouldDrainClose(false, "working", "done"), false)
  eq("drain: nil draining no fire", core.shouldDrainClose(nil, "working", "done"), false)
  eq("drain: working->working no fire", core.shouldDrainClose(true, "working", "working"), false)
end

-- ---- collisions: 2+ active sessions sharing a working dir ------------------
do
  local r = core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "working" },
    { key = "c", cwd = "/x/q", status = "working" },
  }, {})
  eq("collide: a flagged", r.flags.a, true)
  eq("collide: b flagged", r.flags.b, true)
  eq("collide: c alone not flagged", r.flags.c, nil)
  eq("collide: idle peer not counted", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "idle" },
  }, {}).flags.a, nil)
  eq("collide: stale peer excluded", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/p", status = "working", stale = true },
  }, {}).flags.a, nil)
  local items4 = {
    { key = "a", cwd = "/repo/sub1", status = "working" },
    { key = "b", cwd = "/repo/sub2", status = "approval" },
  }
  local root = { ["/repo/sub1"] = "/repo", ["/repo/sub2"] = "/repo" }
  eq("collide: git-root groups subfolders", core.collisions(items4, { rootByCwd = root }).flags.a, true)
  eq("collide: cwd mode does NOT group subfolders", core.collisions(items4, {}).flags.a, nil)
  local root5 = { ["/x/p"] = "", ["/x/q"] = "" }
  eq("collide: empty root sentinel falls back to cwd", core.collisions({
    { key = "a", cwd = "/x/p", status = "working" },
    { key = "b", cwd = "/x/q", status = "working" },
  }, { rootByCwd = root5 }).flags.a, nil)
end

-- ---- providerByModel + respawnSpec: relaunch a dead session ----------------
do
  local cfg = core.json.decode([[
    { "spawn": { "editor": "terminal" },
      "providers": [
        { "id": "anthropic-opus", "kind": "anthropic", "model": "claude-opus-4-8" },
        { "id": "gemini", "kind": "gateway", "model": "gemini-2.5-pro",
          "baseUrl": "http://localhost:4000", "authTokenEnv": "MY_KEY" } ] }]])
  eq("provByModel: anthropic by model alone", core.providerByModel(cfg, "claude-opus-4-8", nil).id, "anthropic-opus")
  eq("provByModel: gateway needs base url too",
     core.providerByModel(cfg, "gemini-2.5-pro", "http://localhost:4000").id, "gemini")
  check("provByModel: gateway model w/o base url -> nil", core.providerByModel(cfg, "gemini-2.5-pro", nil) == nil)
  check("provByModel: unknown model -> nil", core.providerByModel(cfg, "gpt-4", nil) == nil)

  local a = core.respawnSpec({ editor = "kitty", cwd = "/x/p", permission_mode = "plan", model = "claude-opus-4-8" }, cfg)
  eq("respawn: anthropic canRespawn", a.canRespawn, true)
  eq("respawn: anthropic providerId", a.providerId, "anthropic-opus")
  eq("respawn: project = cwd", a.project, "/x/p")
  eq("respawn: editor carried", a.editor, "kitty")
  eq("respawn: permission mode carried", a.permissionMode, "plan")
  eq("respawn: gateway providerId matched", core.respawnSpec(
    { editor = "terminal", cwd = "/x/q", model = "gemini-2.5-pro", base_url = "http://localhost:4000" }, cfg).providerId, "gemini")
  local gb = core.respawnSpec({ editor = "terminal", cwd = "/x/q", model = "mystery", base_url = "http://elsewhere" }, cfg)
  eq("respawn: unknown gateway not respawnable", gb.canRespawn, false)
  check("respawn: unknown gateway reason set", type(gb.reason) == "string")
  local b = core.respawnSpec({ editor = "terminal", cwd = "/x/r", model = "claude-future-9" }, cfg)
  eq("respawn: unknown anthropic still respawnable (bare claude)", b.canRespawn, true)
  check("respawn: unknown anthropic has nil providerId", b.providerId == nil)
  eq("respawn: editor falls back to spawn.editor", core.respawnSpec({ cwd = "/x/s", model = "claude-opus-4-8" }, cfg).editor, "terminal")
  eq("respawn: no cwd -> not respawnable", core.respawnSpec({ model = "x" }, cfg).canRespawn, false)
end

print(string.format("-- core.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
