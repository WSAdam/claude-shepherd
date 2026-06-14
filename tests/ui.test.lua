-- ui.test.lua : standalone unit tests for the panel-UX logic added to cc-core
-- (window geometry, ephemeral relabels, close routing, image data-URLs). Run
-- with plain `lua`. No Hammerspoon, no side effects: JSON via the vendored
-- parser, effects via the recorder. Exits nonzero if any check fails.

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

-- ---- resolvePanelRect: restore a sane saved frame, else the default --------
do
  local screen   = { x = 0, y = 0, w = 1920, h = 1080 }
  local defaults = { w = 580, h = 320 }
  local function defaultRect()
    return { x = screen.x + screen.w - defaults.w - 20, y = screen.y + 40, w = defaults.w, h = defaults.h }
  end

  -- nil saved -> default top-right rect
  local d = core.resolvePanelRect(nil, screen, defaults)
  eq("rect: nil saved -> default x", d.x, defaultRect().x)
  eq("rect: nil saved -> default y", d.y, defaultRect().y)
  eq("rect: nil saved -> default w", d.w, defaults.w)
  eq("rect: nil saved -> default h", d.h, defaults.h)

  -- a valid, on-screen saved frame is returned as-is
  local saved = { x = 100, y = 100, w = 700, h = 500 }
  local g = core.resolvePanelRect(saved, screen, defaults)
  eq("rect: valid saved -> kept w", g.w, 700)
  eq("rect: valid saved -> kept h", g.h, 500)
  eq("rect: valid saved -> kept x", g.x, 100)

  -- garbage / missing fields -> default
  eq("rect: non-table saved -> default w", core.resolvePanelRect("nope", screen, defaults).w, defaults.w)
  eq("rect: partial saved -> default w", core.resolvePanelRect({ x = 1, y = 2 }, screen, defaults).w, defaults.w)
  eq("rect: zero-size saved -> default h", core.resolvePanelRect({ x = 0, y = 0, w = 0, h = 0 }, screen, defaults).h, defaults.h)

  -- fully off-screen saved -> default (window would be unreachable)
  eq("rect: off-screen saved -> default w",
     core.resolvePanelRect({ x = 5000, y = 5000, w = 600, h = 400 }, screen, defaults).w, defaults.w)
end

-- ---- applyLabels: display override only, never the real name ---------------
do
  local list = { { key = "a", name = "alpha" }, { key = "b", name = "bravo" } }
  core.applyLabels(list, { a = "Renamed A" })
  eq("labels: sets display label", list[1].label, "Renamed A")
  eq("labels: leaves real name untouched", list[1].name, "alpha")
  eq("labels: unlabeled item has no label", list[2].label, nil)
  eq("labels: unlabeled item keeps name", list[2].name, "bravo")
  -- nil labels table is a no-op
  core.applyLabels(list, nil)
  eq("labels: nil table is a no-op", list[1].label, nil)
end

-- ---- applyLabelsByCwd: persistent display override keyed by project path ----
do
  local list = {
    { key = "s1", name = "frontend", cwd = "/Users/a/proj" },
    { key = "s2", name = "rune",     cwd = "/Users/a/rune" },
  }
  core.applyLabelsByCwd(list, { ["/Users/a/proj"] = "Web UI" })
  eq("labels-cwd: sets display label by cwd", list[1].label, "Web UI")
  eq("labels-cwd: real name untouched", list[1].name, "frontend")
  eq("labels-cwd: unmatched cwd has no label", list[2].label, nil)

  -- a brand-new session (different key) in the SAME folder inherits the label
  local fresh = { { key = "s3", name = "frontend", cwd = "/Users/a/proj" } }
  core.applyLabelsByCwd(fresh, { ["/Users/a/proj"] = "Web UI" })
  eq("labels-cwd: new session same cwd inherits", fresh[1].label, "Web UI")

  -- nil map and a missing cwd are both no-ops (no crash)
  core.applyLabelsByCwd({ { key = "x", name = "n" } }, nil)
  check("labels-cwd: nil map / missing cwd safe", true)
end

-- ---- projectKey: stable label key from transcript_path (immune to cwd drift) -
do
  local tp = "/Users/a/.claude/projects/-Users-a-proj/sess-1.jsonl"
  eq("projectKey: from transcript_path",
     core.projectKey({ transcript_path = tp, cwd = "/Users/a/proj/sub" }), "-Users-a-proj")
  eq("projectKey: falls back to cwd when no transcript",
     core.projectKey({ cwd = "/Users/a/proj" }), "/Users/a/proj")

  -- the label must stick to projectKey even after cwd drifts to a subfolder, AND
  -- win over a stale cwd-keyed entry for that drifted cwd.
  local list = { { key = "s1", name = "sub", cwd = "/Users/a/proj/sub", projectKey = "-Users-a-proj" } }
  core.applyLabelsByCwd(list, { ["-Users-a-proj"] = "Web UI", ["/Users/a/proj/sub"] = "Stale" })
  eq("labels-key: projectKey beats drifted cwd", list[1].label, "Web UI")

  -- R2-B: a session WITH a projectKey never falls back to a cwd-keyed entry, even when
  -- its projectKey is unlabeled -- otherwise a drifted cwd could grab a stale entry (the
  -- cd-drift immunity this keying exists for, cf. the "beats drifted cwd" case above).
  local pk = { { key = "s2", name = "proj", cwd = "/Users/a/proj", projectKey = "-Users-a-proj" } }
  core.applyLabelsByCwd(pk, { ["/Users/a/proj"] = "Legacy" })
  eq("labels-key: projectKey'd-but-unlabeled session ignores cwd entry", pk[1].label, nil)
  -- the legacy cwd fallback still resolves for a session that has NO projectKey at all
  local keyless = { { key = "s3", name = "proj", cwd = "/Users/a/proj" } }
  core.applyLabelsByCwd(keyless, { ["/Users/a/proj"] = "Legacy" })
  eq("labels-key: legacy cwd fallback resolves when there's no projectKey", keyless[1].label, "Legacy")
end

-- ---- repoFromRemote: git remote URL -> owner/repo (mirrors /improve sed) -----
do
  eq("repo: ssh form", core.repoFromRemote("git@github.com:adam/claude-instance-manager.git"),
     "adam/claude-instance-manager")
  eq("repo: https form", core.repoFromRemote("https://github.com/adam/claude-instance-manager.git"),
     "adam/claude-instance-manager")
  eq("repo: no .git suffix", core.repoFromRemote("git@gitlab.com:org/sub/proj"), "org/sub/proj")
  eq("repo: trailing newline trimmed", core.repoFromRemote("git@github.com:a/b.git\n"), "a/b")
  eq("repo: empty -> empty", core.repoFromRemote(nil), "")
end

-- ---- improvePrompt: review-first prompt embeds each card, never wholesale ----
do
  local p = core.improvePrompt({ { text = "[Simplicity] extract helper X" },
                                 { text = "[Perf] memoize Y" } })
  check("improve: counts cards", p:find("2 reflected improvement", 1, true) ~= nil)
  check("improve: review framing", p:find("give suggestions where applicable", 1, true) ~= nil)
  check("improve: not wholesale", p:find("Do NOT apply them wholesale", 1, true) ~= nil)
  check("improve: includes card 1", p:find("extract helper X", 1, true) ~= nil)
  check("improve: includes card 2", p:find("memoize Y", 1, true) ~= nil)
  check("improve: numbered list", p:find("1. [Simplicity]", 1, true) ~= nil)
  -- accepts plain-string cards too, and an empty list is safe
  check("improve: plain string card", core.improvePrompt({ "raw tip" }):find("raw tip", 1, true) ~= nil)
  check("improve: empty list safe", core.improvePrompt({}):find("0 reflected", 1, true) ~= nil)
end

-- ---- setLabel: immutable set / clear-on-blank / clear-on-equals-name --------
do
  local m = core.setLabel({}, "/p", "Nice Name", "p")
  eq("setLabel: sets value", m["/p"], "Nice Name")

  -- input table is never mutated
  local src = {}
  core.setLabel(src, "/p", "x", "p")
  eq("setLabel: input untouched", next(src), nil)

  eq("setLabel: trims whitespace", core.setLabel({}, "/p", "  Spaced  ", "p")["/p"], "Spaced")
  eq("setLabel: blank clears", core.setLabel({ ["/p"] = "x" }, "/p", "  ", "p")["/p"], nil)
  eq("setLabel: equals folder name clears", core.setLabel({ ["/p"] = "x" }, "/p", "p", "p")["/p"], nil)
  eq("setLabel: nil cwd is a no-op (returns copy)", core.setLabel({ ["/p"] = "x" }, nil, "y", "z")["/p"], "x")
end

-- ---- handleAction: nudge pastes (newline-safe), close stops + removes -------
do
  local normal = { key = "n1", name = "proj-n" }

  local r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "line one\nline two")
  eq("nudge: routes to pasteIntoWindow", r.last().op, "pasteIntoWindow")
  eq("nudge: targets the window name", r.last().a, "proj-n")
  eq("nudge: passes the multi-line text", r.last().b.text, "line one\nline two")

  r = newRecorder()
  core.handleAction(r.fx, normal, "nudge", "")
  eq("nudge: empty text is a no-op", r.count(), 0)

  r = newRecorder()
  core.handleAction(r.fx, normal, "close")
  eq("close: first effect closes the window", r.calls[1].op, "closeWindow")
  eq("close: closeWindow targets the name", r.calls[1].a, "proj-n")
  eq("close: then removes the status tile", r.calls[2].op, "removeStatus")
  eq("close: removeStatus targets the key", r.calls[2].a, "n1")
  eq("close: exactly two effects", r.count(), 2)
end

-- ---- parseDataUrl: pull mime/ext/base64 out of a clipboard image -----------
do
  local png = core.parseDataUrl("data:image/png;base64,iVBORw0KGgo=")
  eq("dataurl: png mime", png.mime, "image/png")
  eq("dataurl: png ext", png.ext, "png")
  eq("dataurl: png payload", png.b64, "iVBORw0KGgo=")

  local jpg = core.parseDataUrl("data:image/jpeg;base64,/9j/4AAQ=")
  eq("dataurl: jpeg ext normalized to jpg", jpg.ext, "jpg")

  eq("dataurl: non-image rejected", core.parseDataUrl("data:text/plain;base64,aGk="), nil)
  eq("dataurl: garbage rejected", core.parseDataUrl("not a data url"), nil)
  eq("dataurl: nil rejected", core.parseDataUrl(nil), nil)

  -- tolerate intermediate params (charset) between mime and ;base64,
  local svg = core.parseDataUrl("data:image/svg+xml;charset=utf-8;base64,PHN2Zz4=")
  eq("dataurl: svg+params mime", svg and svg.mime, "image/svg+xml")
  eq("dataurl: svg ext normalized to svg", svg and svg.ext, "svg")
  eq("dataurl: svg payload", svg and svg.b64, "PHN2Zz4=")
end

-- ---- tempImagePath: deterministic, key/ext-derived path --------------------
do
  eq("temppath: builds under dir with key + ext",
     core.tempImagePath("/tmp", "sess-1", "png"), "/tmp/cc-paste-sess-1.png")
  -- a key with path separators is sanitized so it can't escape the dir
  eq("temppath: sanitizes slashes in key",
     core.tempImagePath("/tmp", "a/b", "jpg"), "/tmp/cc-paste-a_b.jpg")
end

-- ---- staleDuplicateKeys: prune /clear ghosts, keep live + lone tiles -------
do
  -- old sms-bot went stale after /clear; a fresh sms-bot in the SAME kitty window
  -- (same projectKey AND same terminal identity -- /clear reuses the window) is
  -- live -> prune the old. The shared terminal is the death evidence; staleness
  -- alone isn't (every alive session dims ~90s after its turn).
  local sock = "unix:/tmp/cc-kitty-100"
  local list = {
    { key = "old", name = "sms-bot", projectKey = "p-sms",    stale = true,
      kitty_listen_on = sock, kitty_window_id = "7" },
    { key = "new", name = "sms-bot", projectKey = "p-sms",    stale = false,
      kitty_listen_on = sock, kitty_window_id = "7" },
    { key = "solo", name = "rune",   projectKey = "p-rune",   stale = true,
      kitty_listen_on = sock, kitty_window_id = "3" },   -- no live twin -> keep
    { key = "live", name = "canary", projectKey = "p-canary", stale = false },
  }
  local ghosts = core.staleDuplicateKeys(list)
  eq("ghost: exactly one pruned", #ghosts, 1)
  eq("ghost: prunes the stale duplicate", ghosts[1], "old")

  -- two live tiles for the same project (legit parallel sessions) -> prune none
  local twoLive = {
    { key = "a", name = "sms-bot", projectKey = "p-sms", stale = false,
      kitty_listen_on = sock, kitty_window_id = "1" },
    { key = "b", name = "sms-bot", projectKey = "p-sms", stale = false,
      kitty_listen_on = sock, kitty_window_id = "2" },
  }
  eq("ghost: two live same project -> none pruned", #core.staleDuplicateKeys(twoLive), 0)

  -- parallel sessions in one folder occupy DISTINCT windows: the resting twin
  -- (stale `done`, but ALIVE and holding its result) must survive while the
  -- other is driven -- pruning it would delete a live session's tile.
  local parallel = {
    { key = "resting", name = "sms-bot", projectKey = "p-sms", status = "done",
      stale = true,  kitty_listen_on = sock, kitty_window_id = "1" },
    { key = "driving", name = "sms-bot", projectKey = "p-sms", status = "working",
      stale = false, kitty_listen_on = sock, kitty_window_id = "2" },
  }
  eq("ghost: alive-but-quiet twin in another window -> NOT pruned",
     #core.staleDuplicateKeys(parallel), 0)

  -- no terminal identity (non-kitty editors) -> no death evidence, never prune
  -- here; the 24h shouldPrune backstop owns that cleanup.
  local noId = {
    { key = "p", name = "api", projectKey = "p-api", stale = true },
    { key = "q", name = "api", projectKey = "p-api", stale = false },
  }
  eq("ghost: no terminal identity -> NOT pruned", #core.staleDuplicateKeys(noId), 0)

  -- a window id WITHOUT the socket is a HALF identity, i.e. NO identity: kitty
  -- exports KITTY_WINDOW_ID always but KITTY_LISTEN_ON only with remote control
  -- configured, and window ids are a per-INSTANCE counter from 1 -- so two
  -- default-config kitty instances both carry window "1". The resting parallel
  -- session must NOT read as the live one's twin.
  local sockless = {
    { key = "resting2", name = "sms-bot", projectKey = "p-sms", stale = true,
      kitty_window_id = "1" },
    { key = "driving2", name = "sms-bot", projectKey = "p-sms", stale = false,
      kitty_window_id = "1" },
  }
  eq("ghost: sock-less same wid (two kitty instances) -> NOT pruned",
     #core.staleDuplicateKeys(sockless), 0)
  -- socket without a window id is equally half an identity
  local widless = {
    { key = "a2", name = "api", projectKey = "p-api", stale = true, kitty_listen_on = sock },
    { key = "b2", name = "api", projectKey = "p-api", stale = false, kitty_listen_on = sock },
  }
  eq("ghost: socket-only identity -> NOT pruned", #core.staleDuplicateKeys(widless), 0)

  -- a lone stale tile (no fresher twin) -> keep (handled by the 24h backstop instead)
  eq("ghost: lone stale -> none pruned",
     #core.staleDuplicateKeys({ { key = "x", name = "rune", projectKey = "p-rune", stale = true,
                                  kitty_listen_on = sock, kitty_window_id = "9" } }), 0)

  -- F-004 (bug sweep): two sessions in DIFFERENT folders that merely share a basename
  -- `name` must NOT cross-prune (different projectKeys) -- else the stale one's
  -- auto-respawn is silently swallowed. (Same terminal identity on both makes this a
  -- strict projectKey check.)
  local crossProject = {
    { key = "dead",  name = "shepherd", projectKey = "-Users-me-work-shepherd",    stale = true,
      kitty_listen_on = sock, kitty_window_id = "5" },
    { key = "alive", name = "shepherd", projectKey = "-Users-me-scratch-shepherd", stale = false,
      kitty_listen_on = sock, kitty_window_id = "5" },
  }
  eq("ghost: same basename, different project -> NOT pruned", #core.staleDuplicateKeys(crossProject), 0)

  -- legacy cwd-fallback (tiles without a projectKey) still prunes a same-folder
  -- same-window ghost
  local legacy = {
    { key = "o", name = "api", cwd = "/x/api", stale = true,
      kitty_listen_on = sock, kitty_window_id = "4" },
    { key = "n", name = "api", cwd = "/x/api", stale = false,
      kitty_listen_on = sock, kitty_window_id = "4" },
  }
  eq("ghost: legacy cwd-keyed same-folder ghost pruned", core.staleDuplicateKeys(legacy)[1], "o")
end

-- ---- effort: /effort slash command building + routing --------------------
do
  eq("effort: valid level -> command", core.effortCommand("high"), "/effort high")
  eq("effort: uppercase normalized", core.effortCommand("XHigh"), "/effort xhigh")
  eq("effort: invalid level -> nil", core.effortCommand("turbo"), nil)
  eq("effort: empty -> nil", core.effortCommand(""), nil)

  local r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "proj" }, "effort", "medium")
  eq("effort: types the command", r.last().op, "typeIntoWindow")
  eq("effort: command text", r.last().b, "/effort medium")

  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "proj" }, "effort", "bogus")
  eq("effort: invalid level is a no-op", r.count(), 0)
end

-- ---- answer: select an AskUserQuestion option by driving picker keys --------
do
  local k0 = core.answerKeys(0)
  eq("answer: option 0 -> just Return", #k0, 1)
  eq("answer: option 0 key is return", k0[1].key, "return")

  local k2 = core.answerKeys(2)
  eq("answer: option 2 -> down,down,return (3 keys)", #k2, 3)
  eq("answer: first key is down", k2[1].key, "down")
  eq("answer: last key is return", k2[3].key, "return")
  eq("answer: negative clamps to 0 (just return)", #core.answerKeys(-5), 1)

  -- kitty session: drives the picker via keys
  local r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "proj", editor = "kitty" }, "answer", "1")
  eq("answer(kitty): routes to sendKeys", r.last().op, "sendKeys")
  eq("answer(kitty): targets the window", r.last().a, "proj")
  eq("answer(kitty): sends down,return for option 1", #r.last().b, 2)

  -- vscode session: picker is mouse-only, so just jump to it
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "proj", cwd = "/p", editor = "vscode" }, "answer", "1")
  eq("answer(vscode): jumps instead of sending keys", r.last().op, "focusWindow")

  -- kitty + MULTI-select picker: down*N+Enter can't drive it, so jump instead
  local multiItem = { key = "k", name = "proj", cwd = "/p", editor = "kitty",
    pending = { ask = { { question = "Pick", multiSelect = true, options = {} } } } }
  r = newRecorder()
  core.handleAction(r.fx, multiItem, "answer", "1")
  eq("answer(kitty multi): jumps, not sendKeys", r.last().op, "focusWindow")
  check("askIsMulti: true for multiSelect", core.askIsMulti(multiItem) == true)
  check("askIsMulti: false for single-select", core.askIsMulti({ pending = { ask = { { multiSelect = false } } } }) == false)
  check("askIsMulti: false when no pending ask", core.askIsMulti({ name = "x" }) == false)
end

-- ---- Part A: kitty effect routing carries the target (headless) ------------
do
  local kitty = { key = "k1", name = "proj", cwd = "/p", editor = "kitty",
    kitty_window_id = "7", kitty_listen_on = "unix:/tmp/k" }

  -- ungated approve on kitty -> actOnWindow with the kitty target (becomes a
  -- headless send-key "enter" in the FX layer; no focus).
  local r = newRecorder()
  core.handleAction(r.fx, kitty, "approve")
  eq("kitty approve: actOnWindow", r.last().op, "actOnWindow")
  eq("kitty approve: target editor kitty", r.last().tgt.editor, "kitty")
  eq("kitty approve: target window id", r.last().tgt.kittyWindowId, "7")
  eq("kitty approve: key is return", r.last().b.key, "return")

  -- close routes with the kitty target (socket carried through)
  r = newRecorder()
  core.handleAction(r.fx, kitty, "close")
  eq("kitty close: closeWindow first", r.calls[1].op, "closeWindow")
  eq("kitty close: target carries socket", r.calls[1].tgt.kittyListenOn, "unix:/tmp/k")

  -- set-mode default->plan = 2 Shift+Tab via sendKeys (Part C)
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", editor = "kitty", permission_mode = "default" }, "set-mode", "plan")
  eq("set-mode: routes to sendKeys", r.last().op, "sendKeys")
  eq("set-mode: 2 shift-tabs", #r.last().b, 2)
  eq("set-mode: key is tab", r.last().b[1].key, "tab")
  eq("set-mode: shift modifier", r.last().b[1].mods[1], "shift")

  -- set-mode no-op when already in the target mode
  r = newRecorder()
  core.handleAction(r.fx, { key = "k", name = "p", permission_mode = "plan" }, "set-mode", "plan")
  eq("set-mode: same mode -> no effect", r.count(), 0)
end

-- ---- window-effect targets carry cwd + editor (focusProject matching) -------
do
  -- The FX layer threads target.cwd/editor into focusProject on EVERY keystroke
  -- path (not just Jump): a subfolder session (name "frontend", window titled
  -- "… — autobottom") is only matchable via the cwd ancestors, and a terminal
  -- session is only findable in Terminal.app. Pin that every window effect
  -- receives the full target, so the FX layer always has them to use.
  local item = { key = "s1", name = "frontend", cwd = "/u/a/autobottom/frontend",
                 editor = "vscode" }
  local r = newRecorder()
  core.handleAction(r.fx, item, "approve")
  eq("target: ungated approve carries cwd", r.last().tgt.cwd, "/u/a/autobottom/frontend")
  eq("target: ungated approve carries editor", r.last().tgt.editor, "vscode")
  r = newRecorder()
  core.handleAction(r.fx, item, "stop")
  eq("target: stop carries cwd", r.last().tgt.cwd, "/u/a/autobottom/frontend")
  r = newRecorder()
  core.handleAction(r.fx, item, "nudge", "hi")
  eq("target: nudge carries cwd", r.last().tgt.cwd, "/u/a/autobottom/frontend")
  r = newRecorder()
  core.handleAction(r.fx, item, "set-mode", "plan")  -- routes to sendKeys
  eq("target: set-mode carries cwd", r.last().tgt.cwd, "/u/a/autobottom/frontend")
  r = newRecorder()
  core.handleAction(r.fx, item, "close")
  eq("target: close carries cwd", r.calls[1].tgt.cwd, "/u/a/autobottom/frontend")
  -- terminal sessions route with their editor kind so the FX layer searches
  -- Terminal.app for the window instead of VS Code (which can't have it)
  r = newRecorder()
  core.handleAction(r.fx, { key = "t1", name = "api", cwd = "/u/a/api", editor = "terminal" }, "stop")
  eq("target: terminal editor kind carried", r.last().tgt.editor, "terminal")
end

-- ---- actionIsHeadless: which bulk dispatches must be staggered --------------
do
  -- The bulk loop fires headless dispatches together but staggers the window-
  -- keystroke ones (each focuses NOW and injects on after() timers, so a
  -- synchronous loop would land every key in the LAST-focused window).
  local kitty = { key = "k", editor = "kitty" }
  local vs    = { key = "v", editor = "vscode" }
  check("headless: kitty always", core.actionIsHeadless(kitty, "stop") == true)
  check("headless: armed-gate approve", core.actionIsHeadless({ key = "g", gate = "waiting" }, "approve") == true)
  check("headless: armed-gate deny", core.actionIsHeadless({ key = "g", gate = "waiting" }, "deny") == true)
  check("headless: ungated vscode approve is NOT", core.actionIsHeadless(vs, "approve") == false)
  check("headless: vscode stop is NOT", core.actionIsHeadless(vs, "stop") == false)
  check("headless: armed gate doesn't cover nudge", core.actionIsHeadless({ key = "g", gate = "waiting" }, "nudge") == false)
  check("headless: nil item safe", core.actionIsHeadless(nil, "stop") == false)
end

-- ---- set-mode optimistic re-base: return contract + patchedStatus -----------
do
  -- handleAction reports WHAT it did so the dashboard can optimistically persist
  -- the new mode: Shift+Tab fires no hook, so the stored base would go stale and
  -- a re-pick would cycle PAST the target (default->plan twice = acceptEdits).
  local item = { key = "k", name = "p", editor = "kitty", permission_mode = "default" }
  local r = newRecorder()
  eq("set-mode: success returns the action",
     core.handleAction(r.fx, item, "set-mode", "plan"), "set-mode")
  eq("set-mode: no-op returns nil",
     core.handleAction(r.fx, { key = "k", name = "p", permission_mode = "plan" }, "set-mode", "plan"), nil)

  -- patchedStatus merges fields into the status JSON (the pure half of FX.patchStatus)
  local txt = core.patchedStatus('{"status":"done","permission_mode":"default"}',
                                 { permission_mode = "plan" })
  local back = core.json.decode(txt)
  eq("patchedStatus: sets the new mode", back.permission_mode, "plan")
  eq("patchedStatus: keeps other fields", back.status, "done")
  eq("patchedStatus: garbage input -> nil", core.patchedStatus("not json", { x = 1 }), nil)
  eq("patchedStatus: empty input -> nil", core.patchedStatus("", { x = 1 }), nil)

  -- once the dashboard re-bases the item, re-picking the SAME mode is a no-op
  -- (this is the double-apply that used to land in acceptEdits)
  item.permission_mode = "plan"
  r = newRecorder()
  eq("set-mode: re-pick after re-base is a no-op",
     core.handleAction(r.fx, item, "set-mode", "plan"), nil)
  eq("set-mode: re-pick sends no keys", r.count(), 0)
end

-- ---- watcherShouldRefresh: the panel's own heartbeat must not re-trigger ----
do
  -- refresh() writes .panel-alive INTO the watched status dir every tick; if the
  -- pathwatcher refreshed on it, every refresh would schedule the next forever.
  check("watch: heartbeat only -> no refresh",
        core.watcherShouldRefresh({ "/s/.panel-alive" }) == false)
  check("watch: status change -> refresh",
        core.watcherShouldRefresh({ "/s/abc123.json" }) == true)
  check("watch: heartbeat + status change -> refresh",
        core.watcherShouldRefresh({ "/s/.panel-alive", "/s/abc123.json" }) == true)
  check("watch: decision file -> refresh",
        core.watcherShouldRefresh({ "/s/abc123.decision" }) == true)
  check("watch: empty batch -> no refresh (timer covers it)",
        core.watcherShouldRefresh({}) == false)
  check("watch: nil batch safe", core.watcherShouldRefresh(nil) == false)
end

-- ---- set-mode delivery contract: no dispatch -> no optimistic re-base (R2 #4)
do
  local item = { key = "k", name = "p", editor = "vscode", permission_mode = "default" }
  -- FX.sendKeys returns an EXPLICIT false when it skipped (no window match /
  -- dead kitty target). handleAction must then report nil so the bridge never
  -- persists the target mode into the status file -- a lying panel, plus every
  -- re-pick computing a 0-step no-op from the fake base.
  local r = newRecorder()
  r.fx.sendKeys = function(t, keys)
    r.calls[#r.calls + 1] = { op = "sendKeys", a = (t or {}).name, b = keys, tgt = t }
    return false
  end
  eq("set-mode: skipped dispatch returns nil",
     core.handleAction(r.fx, item, "set-mode", "plan"), nil)
  -- the skip logs AFTER the attempt (the `delivered` helper), so the attempt
  -- is the second-to-last recorded call
  eq("set-mode: the skip still ATTEMPTED the keys", r.calls[#r.calls - 1].op, "sendKeys")
  eq("set-mode: the skip is logged", r.last().op, "log")

  -- a delivered dispatch (true) returns the action -> the bridge re-bases
  r = newRecorder()
  r.fx.sendKeys = function() return true end
  eq("set-mode: delivered dispatch returns the action",
     core.handleAction(r.fx, item, "set-mode", "plan"), "set-mode")

  -- a fake returning NOTHING (the recorder default, and the answer path's
  -- contract) still counts as success: only an explicit false means "not sent"
  r = newRecorder()
  eq("set-mode: nil-returning fx keeps the success contract",
     core.handleAction(r.fx, item, "set-mode", "plan"), "set-mode")
end

-- ---- nudge delivery contract: skipped paste -> nil, never ledgered (R3 #1) --
do
  local item = { key = "k", name = "p", editor = "vscode" }
  -- FX.pasteIntoWindow returns an EXPLICIT false when the no-window-match guard
  -- skipped the paste. handleAction must then report nil so the bridge ledgers
  -- nudge_skipped instead of a delivery the session never received.
  local r = newRecorder()
  r.fx.pasteIntoWindow = function(t, payload)
    r.calls[#r.calls + 1] = { op = "pasteIntoWindow", a = (t or {}).name, b = payload, tgt = t }
    return false
  end
  eq("nudge: skipped paste returns nil", core.handleAction(r.fx, item, "nudge", "hi"), nil)
  -- the skip logs AFTER the attempt (the `delivered` helper)
  eq("nudge: the skip still ATTEMPTED the paste", r.calls[#r.calls - 1].op, "pasteIntoWindow")
  eq("nudge: the skip is logged", r.last().op, "log")

  -- a delivered paste (true) returns the action -> the bridge ledgers "nudge"
  r = newRecorder()
  r.fx.pasteIntoWindow = function() return true end
  eq("nudge: delivered paste returns the action",
     core.handleAction(r.fx, item, "nudge", "hi"), "nudge")

  -- a fake returning NOTHING (the recorder default) keeps the success contract:
  -- only an explicit false means "not sent" (same as set-mode/sendKeys)
  r = newRecorder()
  eq("nudge: nil-returning fx keeps the success contract",
     core.handleAction(r.fx, item, "nudge", "hi"), "nudge")
  -- empty text stays a no-op (returns nil WITHOUT attempting a paste)
  r = newRecorder()
  eq("nudge: empty text still a no-op", core.handleAction(r.fx, item, "nudge", ""), nil)
  eq("nudge: empty text attempts nothing", r.count(), 0)
end

-- ---- Panel-JS source tripwires (R2 #11 / #15) -------------------------------
-- The settings JS has no headless runtime in this Lua+bash suite (same rationale
-- as tests/escaping.test.sh), so pin the load-bearing expressions at the source
-- level. Reformatting these lines can false-alarm; re-verify the behavior then.
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("js-pin: dashboard source readable", #src > 0)
  -- #15: a cancelled default-provider pick must not resurrect from the stale DOM.
  -- showSettings passes the SAVED spawn.provider ("" = bare claude); falling back
  -- to sel.value would re-select -- and any Save silently persist -- the cancel.
  check("js-pin: refreshProviderDefault has NO stale-DOM fallback",
        src:find("want = want || sel.value", 1, true) == nil)
  check("js-pin: refreshProviderDefault keeps the saved-empty sentinel",
        src:find('want = want || "";', 1, true) ~= nil)
  -- #11: switching a provider card's kind back to claude must clear the
  -- gateway-only fields the Save-merge inherited -- a stale baseUrl poisons
  -- providerByModel's respawn matching (see core.test.lua's pure-side pin).
  check("js-pin: non-gateway kind clears baseUrl/authTokenEnv on Save",
        src:find("delete p.baseUrl; delete p.authTokenEnv;", 1, true) ~= nil)
  check("js-pin: non-gateway kind clears smallFastModel/headers on Save",
        src:find("delete p.smallFastModel; delete p.headers;", 1, true) ~= nil)
  -- Context bar: the % must live ON the bar (a .pct label), the fill width is still the
  -- pct, and the band classes/colors must cover b0..b6 (mirror of core.contextBand).
  check("js-pin: ctx-bar carries a visible % label",
        src:find('<span class="pct">\'+pct+\'%</span>', 1, true) ~= nil)
  check("js-pin: ctx-bar fill width is still driven by pct",
        src:find("<i style=\"width:'+pct+'%\">", 1, true) ~= nil)
  check("js-pin: barLevel mirrors the 7-band contextBand ramp",
        src:find('f>=0.95?"b6":f>=0.90?"b5"', 1, true) ~= nil)
  check("js-pin: ctx-bar CSS defines the calm band b0", src:find(".ctx-bar.b0 > i", 1, true) ~= nil)
  check("js-pin: ctx-bar CSS defines the critical band b6", src:find(".ctx-bar.b6 > i", 1, true) ~= nil)
  -- Folder scan must run deadlock-proof: via /bin/sh with stdout redirected to a file (NOT
  -- direct-exec hs.task, which stalls >64KB over a large tree), reading the file on exit,
  -- with a timeout backstop. Reverting to `hs.task.new(argv[1]` would reintroduce the hang.
  check("fscan-pin: scan runs via /bin/sh (not direct-exec)", src:find('hs.task.new("/bin/sh"', 1, true) ~= nil)
  check("fscan-pin: scan command built by core (quoted + redirect)", src:find("core.folderScanShellCommand(argv, outFile)", 1, true) ~= nil)
  check("fscan-pin: scan reads the temp file on exit", src:find("FX.readFile(outFile)", 1, true) ~= nil)
  check("fscan-pin: scan has a timeout backstop", src:find("folder scan timed out", 1, true) ~= nil)
  check("fscan-pin: no direct-exec scan remains", src:find("hs.task.new(argv[1], function(_, stdout)", 1, true) == nil)
  -- Toolbar collapse: the ☰ drawer must still wire all five views (search / fleet-search /
  -- insights / audit / notifications) -- a dropped menuPick branch silently buries a view.
  check("js-pin: toolbar drawer exists", src:find('id="toolmenu"', 1, true) ~= nil)
  for _, w in ipairs({ "search", "fsearch", "insights", "audit", "notify" }) do
    check("js-pin: drawer wires menuPick('" .. w .. "')", src:find("menuPick('" .. w .. "')", 1, true) ~= nil)
  end
  check("js-pin: menuPick routes search->toggleSearch", src:find('which === "search") toggleSearch()', 1, true) ~= nil)
  check("js-pin: menuPick routes notify->openNotifications", src:find('which === "notify") openNotifications()', 1, true) ~= nil)
  check("js-pin: notify badge still updated on the collapsed button", src:find('"notify-badge", "tm-notify-badge"', 1, true) ~= nil)
end

-- ---- Injection-tail chokepoint + delivery-gated alerts (R3 #0/#1/#2/#5) -----
-- The dashboard's dispatch wiring has no headless runtime here (same rationale
-- as the Panel-JS tripwires above), so pin the load-bearing call shapes at the
-- source level. Reformatting these lines can false-alarm; re-verify then.
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("inject-pin: dashboard source readable", #src > 0)

  -- #2/#5: EVERY window-keystroke dispatch must reserve its slot through the
  -- ONE chokepoint (dispatchSerialized). Raw core.staggerSlot arithmetic at a
  -- call site is how drain/auto-feed/ctx-menu/Stream-Deck/hotkey paths drifted
  -- out of serialization in round 2.
  local slotCalls = select(2, src:gsub("core%.staggerSlot%(", ""))
  eq("inject-pin: staggerSlot called ONLY by the chokepoint", slotCalls, 1)
  local sites = select(2, src:gsub("dispatchSerialized%(", ""))
  check("inject-pin: chokepoint wired at all dispatch sites (16 calls + def, got=" .. sites .. ")",
        sites >= 17)
  -- the specific launchers round 3 caught bypassing the tail:
  check("inject-pin: refresh() drain close serialized",
        src:find('dispatchSerialized(it, "close", function() core.handleAction(FX, it, "close") end)', 1, true) ~= nil)
  check("inject-pin: refresh() auto-feed serialized (pop inside the slot)",
        src:find('dispatchSerialized(it, "queue-feed", function()', 1, true) ~= nil)
  check("inject-pin: per-tile close no longer skips the tail",
        src:find('dispatchSerialized(item, a, function() core.handleAction(FX, item, "close") end)', 1, true) ~= nil)
  check("inject-pin: ctx-menu clear serialized",
        src:find('dispatchSerialized(item, "clear", function() FX.typeIntoWindow(winTarget(item), "/clear") end)', 1, true) ~= nil)
  check("inject-pin: ctx-menu compact serialized",
        src:find('dispatchSerialized(item, "compact", function() FX.typeIntoWindow(winTarget(item), "/compact") end)', 1, true) ~= nil)
  check("inject-pin: Stream Deck / hotkey presses serialized",
        select(2, src:gsub('dispatchSerialized%(it[em]*, action, function%(%) core%.handleAction%(FX, it[em]*, action%) end%)', "")) >= 2)
  check("inject-pin: generic per-tile tail uses the chokepoint",
        src:find("dispatchSerialized(item, a, dispatch)", 1, true) ~= nil)
  -- Auto-Continue fires the SAME serialized continue keystroke the manual button uses.
  check("inject-pin: auto-continue serialized through the chokepoint",
        src:find('dispatchSerialized(it, "continue", function() core.handleAction(FX, it, "continue") end)', 1, true) ~= nil)
  check("inject-pin: auto-continue ledgers the resume",
        src:find('type = "auto_continue", attempt = cstep.attempts', 1, true) ~= nil)
  -- Remote-control startup sweep types /rc through the SAME serialized chokepoint.
  check("inject-pin: RC startup sweep serialized through the chokepoint",
        src:find('dispatchSerialized(it, "rc", function() FX.typeIntoWindow(winTarget(it), "/rc") end)', 1, true) ~= nil)
  check("inject-pin: RC sweep targets come from cc-core",
        src:find("core.remoteControlSweepTargets(list)", 1, true) ~= nil)

  -- #0: the audit-review alert is gated on pasteIntoWindow's delivery status
  -- (a skipped paste must never announce "sent a N-event review").
  check("audit-pin: review paste return gates the alert",
        src:find("if FX.pasteIntoWindow(winTarget(target), { text = prompt }) then", 1, true) ~= nil)
  check("audit-pin: skip announces review NOT sent",
        src:find("review NOT sent", 1, true) ~= nil)

  -- #1: an image nudge ledgers nudge_skipped (and alerts) on a skipped paste;
  -- a text nudge ledgers AFTER dispatch, gated on handleAction's result.
  check("nudge-pin: image paste return gates the ledger",
        src:find('if FX.pasteIntoWindow(winTarget(item), { text = payload.text and tostring(payload.text) or nil, imagePath = path }) then', 1, true) ~= nil)
  check("nudge-pin: skipped image nudge ledgers nudge_skipped",
        src:find('ledgerFor(item, { type = "nudge_skipped", text = tostring(payload.text or ""):sub(1, 200), image = true })', 1, true) ~= nil)
  check("nudge-pin: skipped image nudge alerts the operator",
        src:find("nudge NOT sent", 1, true) ~= nil)
  check("nudge-pin: text nudge ledger gated on delivery",
        src:find('type = (acted == "nudge") and "nudge" or "nudge_skipped"', 1, true) ~= nil)
end

-- ---- source-pins for the pad-mirror batch (no JS runtime here) --------------
-- These four features are wired in the webview/handlers, which has no headless
-- runtime; pin the load-bearing wiring at the source level so it can't silently
-- regress (especially an UNSUBSTITUTED placeholder, which breaks the panel).
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("padmirror-pin: dashboard source readable", #src > 0)

  -- 1.1a: the ⌘⌥J jump hotkey targets nextAttention (approval>error>hung), not
  -- nextApproval, and reads the fully-annotated render list (it.hung/error).
  check("padmirror-pin: jump hotkey uses nextAttention",
        src:find("core.nextAttention(l) or core.frontSession(l)", 1, true) ~= nil)
  check("padmirror-pin: hotkey reads the annotated lastRenderList",
        src:find("selector(lastRenderList or refreshList())", 1, true) ~= nil)
  check("padmirror-pin: render tick captures lastRenderList after the re-sort",
        src:find("lastRenderList = list", 1, true) ~= nil)

  -- 1.1b: the ⌨ legend placeholder MUST have a matching gsub (an unsubstituted
  -- __HOTKEY_LEGEND__ is invalid JS and takes the whole panel script down).
  check("padmirror-pin: legend placeholder referenced once in the template",
        select(2, src:gsub("window%.HOTKEY_LEGEND = __HOTKEY_LEGEND__;", "")) == 1)
  check("padmirror-pin: legend placeholder is substituted (gsub present)",
        src:find('HTML:gsub("__HOTKEY_LEGEND__", legendJson)', 1, true) ~= nil)
  check("padmirror-pin: legend sourced from core.hotkeyLegend (no drift)",
        src:find("core.hotkeyLegend(legendGlobals, legendPanel)", 1, true) ~= nil)

  -- 1.3: the Shift report computes fleetStandup + standupMarkdown in Lua (one
  -- source for the <pre> body and the Copy button); copy-text writes the pasteboard.
  check("padmirror-pin: open-shift handler present", src:find('a == "open-shift"', 1, true) ~= nil)
  check("padmirror-pin: shift uses core.fleetStandup", src:find("core.fleetStandup(ledgerSnapshot()", 1, true) ~= nil)
  check("padmirror-pin: shift renders via core.standupMarkdown", src:find("core.standupMarkdown(report", 1, true) ~= nil)
  check("padmirror-pin: copy-text writes the pasteboard", src:find("hs.pasteboard.setContents(txt)", 1, true) ~= nil)

  -- 1.6: lineage annotated once per tick via lineageByProject (cached), assigned
  -- to it.lineage/it.churn, and the day-window anchored at local midnight.
  check("padmirror-pin: lineage map via core.lineageByProject",
        src:find("core.lineageByProject(ledgerEvents, midnight)", 1, true) ~= nil)
  check("padmirror-pin: lineage one-liner via core.lineageSummary",
        src:find("core.lineageSummary(lin)", 1, true) ~= nil)

  -- ledger-gating: the 📋 Shift tab + drawer row default HIDDEN and are revealed
  -- only by setLedgerOn, which the refresh tick pushes on change. (Lineage needs
  -- no such gate -- it simply isn't computed when the ledger is off.)
  check("padmirror-pin: shift tab defaults hidden",
        src:find('id="a-tab-shift" class="a-tab" style="display:none"', 1, true) ~= nil)
  check("padmirror-pin: shift drawer row defaults hidden",
        src:find('id="tm-shift" class="tm-item" style="display:none"', 1, true) ~= nil)
  check("padmirror-pin: setLedgerOn toggles the shift tab",
        src:find('document.getElementById("a-tab-shift"); if(tab) tab.style.display = LEDGER_ON', 1, true) ~= nil)
  check("padmirror-pin: refresh tick pushes ledger state on change",
        src:find('"setLedgerOn(" .. tostring(ledgerOn) .. ")"', 1, true) ~= nil)
  check("padmirror-pin: shift drawer entry guarded by LEDGER_ON",
        src:find('else if(which === "shift"){ if(LEDGER_ON) openShiftReport(); }', 1, true) ~= nil)
end

-- ---- L1 Agent Profiles: dashboard wiring pins ------------------------------
-- Source-level guards that the L1 FX layer / handleAction / modal JS stay wired
-- (claude-dashboard.lua is not directly unit-tested; the pure logic is in
-- cc-core + core.test). These catch an accidental unwiring on refactor.
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("l1-pin: dashboard source readable", #src > 0)

  -- FX layer
  check("l1-pin: AGENT_FILE constant", src:find("cc%-agents%.json") ~= nil)
  check("l1-pin: MCP_FILE constant", src:find("cc%-mcp%.json") ~= nil)
  check("l1-pin: FX.readAgents", src:find("function FX.readAgents()", 1, true) ~= nil)
  check("l1-pin: FX.writeAgents", src:find("function FX.writeAgents(", 1, true) ~= nil)
  check("l1-pin: FX.readMcp", src:find("function FX.readMcp()", 1, true) ~= nil)
  check("l1-pin: FX.listSkills enumerator", src:find("function FX.listSkills()", 1, true) ~= nil)
  check("l1-pin: listSkills uses core parser", src:find("core.parseSkillFrontmatter", 1, true) ~= nil)
  check("l1-pin: FX.writeMcpConfig", src:find("function FX.writeMcpConfig(", 1, true) ~= nil)

  -- spawnSession threads agentOpts -> spawnExtraFlags (via opts.*)
  check("l1-pin: spawnSession takes agentOpts",
        src:find("function FX.spawnSession(editor, project, task, permissionMode, providerId, agentOpts)", 1, true) ~= nil)
  check("l1-pin: opts.appendSystemPrompt threaded", src:find("opts.appendSystemPrompt = agentOpts.appendSystemPrompt", 1, true) ~= nil)
  check("l1-pin: opts.mcpConfigPath threaded", src:find("opts.mcpConfigPath = agentOpts.mcpConfigPath", 1, true) ~= nil)

  -- handleAction CRUD + spawn-from-agent
  check("l1-pin: agent CRUD action", src:find('a == "agent%-save" or a == "agent%-delete" or a == "agent%-fork"') ~= nil)
  check("l1-pin: agentPush wired", src:find("core.agentPush(FX.readAgents()", 1, true) ~= nil)
  check("l1-pin: agentFork wired", src:find("core.agentFork(FX.readAgents()", 1, true) ~= nil)
  check("l1-pin: mcp CRUD action", src:find('a == "mcp%-save" or a == "mcp%-delete"') ~= nil)
  check("l1-pin: spawn resolves a saved agent", src:find("core.resolveAgent(profile, { mcpState = FX.readMcp() })", 1, true) ~= nil)
  check("l1-pin: spawn writes the mcp-config", src:find("FX.writeMcpConfig(profile.name, res.mcpConfig)", 1, true) ~= nil)
  check("l1-pin: spawn passes agentOpts", src:find("payload.provider and tostring(payload.provider) or nil, agentOpts)", 1, true) ~= nil)
  check("l1-pin: spawn_agent ledger event", src:find('type = "spawn_agent"', 1, true) ~= nil)
  check("l1-pin: open-new feeds agentState", src:find("agentState = { agents = core.agentList(FX.readAgents())", 1, true) ~= nil)

  -- modal JS
  check("l1-pin: Agents chip row in modal", src:find('id="n%-agents"') ~= nil)
  check("l1-pin: skills card in modal", src:find('id="n%-skills"') ~= nil)
  check("l1-pin: showNew takes agentState", src:find("function showNew(cfg, recent, browse, presetState, agentState){", 1, true) ~= nil)
  check("l1-pin: agentSpawn carries agent name", src:find("agent:p.name", 1, true) ~= nil)
  check("l1-pin: ccAgents updater", src:find("function ccAgents(list)", 1, true) ~= nil)
  check("l1-pin: saveAgent button", src:find("function saveAgent()", 1, true) ~= nil)
  check("l1-pin: renderSkills card", src:find("function renderSkills()", 1, true) ~= nil)
end

print(string.format("-- ui.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
