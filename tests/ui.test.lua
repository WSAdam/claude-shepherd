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

  -- nil map and a missing cwd are both no-ops (no crash, AND no label applied)
  local safe = { { key = "x", name = "n" } }
  core.applyLabelsByCwd(safe, nil)
  eq("labels-cwd: nil map / missing cwd is a safe no-op (no label added)", safe[1].label, nil)
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

  -- no window identity at all (no kitty handles AND no host_window) -> no death
  -- evidence, never prune here; the 24h shouldPrune backstop owns that cleanup.
  local noId = {
    { key = "p", name = "api", projectKey = "p-api", stale = true },
    { key = "q", name = "api", projectKey = "p-api", stale = false },
  }
  eq("ghost: no window identity -> NOT pruned", #core.staleDuplicateKeys(noId), 0)

  -- VS Code/Cursor have no kitty handles: the host_window pid (the claude process's
  -- parent) is the per-window id. A /clear spawns a fresh claude under the SAME editor
  -- window -> old (ghost) + new share host_window -> prune the stale one. THIS is the
  -- bug that left a duplicate ChargebackSentinel tile lingering up to 24h.
  -- BOUNDARY (do not "fix" by pinning the claude pid -- that breaks /clear pruning):
  -- host_window is per-WINDOW, not per-pane (unlike kitty's window id), so two parallel
  -- claude sessions in ONE VS Code window share it. The resting (stale) one is then
  -- pruned here as a false twin -- an accepted, SELF-HEALING trade-off: its tile
  -- reappears on that session's next hook event. (Same assertion as this /clear case.)
  local vsGhost = {
    { key = "vold", name = "cbs", projectKey = "p-cbs", stale = true,  host_window = "1301" },
    { key = "vnew", name = "cbs", projectKey = "p-cbs", stale = false, host_window = "1301" },
  }
  eq("ghost: VS Code /clear ghost (same host_window) -> prune the stale one",
     core.staleDuplicateKeys(vsGhost)[1], "vold")
  eq("ghost: VS Code prunes exactly one", #core.staleDuplicateKeys(vsGhost), 1)

  -- both twins stale (e.g. two /clears in quick succession, neither alive yet) -> no
  -- live tile to serve as death evidence -> prune NOTHING here; the 24h shouldPrune
  -- backstop owns that cleanup. Guards against a refactor that prunes any stale
  -- duplicate sharing a termId regardless of whether the twin is actually live.
  local staleBothDead = {
    { key = "d1", name = "cbs", projectKey = "p-cbs", stale = true, host_window = "1301" },
    { key = "d2", name = "cbs", projectKey = "p-cbs", stale = true, host_window = "1301" },
  }
  eq("ghost: both stale (no live twin) -> none pruned", #core.staleDuplicateKeys(staleBothDead), 0)

  -- a HALF-present host id (only one side has it) is NO identity -- same safe-side rule
  -- as the kitty half-identity. The side without host_window has a nil termId, so
  -- neither orientation can match. (Realistic: a fresh /clear session's first event can
  -- land BEFORE host_window is captured, so transient one-sided ids do occur.)
  local vsHalfA = {
    { key = "ha", name = "cbs", projectKey = "p-cbs", stale = true,  host_window = "1301" },
    { key = "hb", name = "cbs", projectKey = "p-cbs", stale = false },
  }
  eq("ghost: stale has host_window, live lacks it -> NOT pruned", #core.staleDuplicateKeys(vsHalfA), 0)
  local vsHalfB = {
    { key = "hc", name = "cbs", projectKey = "p-cbs", stale = true },
    { key = "hd", name = "cbs", projectKey = "p-cbs", stale = false, host_window = "1301" },
  }
  eq("ghost: live has host_window, stale lacks it -> NOT pruned", #core.staleDuplicateKeys(vsHalfB), 0)

  -- two VS Code windows on the same project occupy DISTINCT host_window pids: the
  -- resting one is a real parallel session, not a /clear ghost -> keep both.
  local vsParallel = {
    { key = "wa", name = "cbs", projectKey = "p-cbs", stale = true,  host_window = "1301" },
    { key = "wb", name = "cbs", projectKey = "p-cbs", stale = false, host_window = "1302" },
  }
  eq("ghost: VS Code parallel windows (distinct host_window) -> NOT pruned",
     #core.staleDuplicateKeys(vsParallel), 0)

  -- the kitty/host namespaces don't cross-collide: a stale kitty tile whose bare wid
  -- equals a live VS Code tile's host_window must NOT read as its twin.
  local mixed = {
    { key = "kx", name = "cbs", projectKey = "p-cbs", stale = true,
      kitty_listen_on = sock, kitty_window_id = "1301" },
    { key = "hx", name = "cbs", projectKey = "p-cbs", stale = false, host_window = "1301" },
  }
  eq("ghost: kitty wid vs vscode host_window don't cross-match", #core.staleDuplicateKeys(mixed), 0)

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

-- ---- #10-pin: kitty "focus" is NOT headless (kitty @ focus-window raises) ----
-- `kitty @ send-key/send-text` are focus-neutral, but the jump path runs
-- `kitty @ focus-window`, which RAISES the kitty OS window -- fired un-staggered
-- it hijacks an in-flight chain's pending Cmd+V/Return beats into the kitty
-- session, exactly the hazard the shared injection tail exists to prevent. Same
-- for "answer" when key synthesis can't drive the picker (multi-select /
-- multi-question asks jump via fx.focusWindow instead of sending keys).
do
  local kitty = { key = "k", editor = "kitty" }
  check("#10-pin: kitty focus reserves a tail slot (not headless)",
        core.actionIsHeadless(kitty, "focus") == false)
  local multiSel = { key = "k", editor = "kitty",
    pending = { ask = { { question = "q", multiSelect = true } } } }
  check("#10-pin: kitty answer on a multi-SELECT ask is not headless (jumps)",
        core.actionIsHeadless(multiSel, "answer") == false)
  local multiQ = { key = "k", editor = "kitty",
    pending = { ask = { { question = "q1" }, { question = "q2" } } } }
  check("#10-pin: kitty answer on a multi-QUESTION ask is not headless (jumps)",
        core.actionIsHeadless(multiQ, "answer") == false)
  local singleQ = { key = "k", editor = "kitty",
    pending = { ask = { { question = "q1" } } } }
  check("#10-pin: kitty answer on a single-select ask stays headless (send-key)",
        core.actionIsHeadless(singleQ, "answer") == true)
  -- every other kitty action keeps the focus-neutral `kitty @` fast path
  check("#10-pin: kitty stop still headless", core.actionIsHeadless(kitty, "stop") == true)
  check("#10-pin: kitty approve still headless", core.actionIsHeadless(kitty, "approve") == true)
  -- remote tiles keep the unconditional headless short-circuit (bridge tiles
  -- never focus a local window -- even for "focus")
  check("#10-pin: remote kitty focus stays headless (bridge tile)",
        core.actionIsHeadless({ key = "r", editor = "kitty", remote = { host = "h" } }, "focus") == true)
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
  -- R1-20: after() returns a wrapper whose :stop() reaps the pendingTimers entry (an
  -- externally :stop()'d timer never fires, so its entry would otherwise leak forever).
  check("after-pin: after() returns a stop-wrapper that reaps pendingTimers",
        src:find("return { stop = function() pendingTimers[id] = nil;", 1, true) ~= nil)
  -- R1-21: after()'s fired callback runs fn in pcall (per-beat isolation), and the
  -- hand-rolled paste/sendKeys ladders pcall each step so a throw can't strand restore.
  check("after-pin: after() callback runs fn in pcall",
        src:find("local ok, err = pcall(fn)", 1, true) ~= nil)
  check("ladder-pin: pasteIntoWindow pcalls each step + the ⌘V",
        src:find("pcall(steps[i])", 1, true) ~= nil)
  check("ladder-pin: sendKeys pcalls each keystroke",
        src:find("pcall(function() hs.eventtap.keyStroke(k.mods or {}, k.key) end)", 1, true) ~= nil)
  -- R1-17: writeQueue is durable (temp+rename) and readQueue backs up an undecodable
  -- file instead of silently stripping its routing/mode flags.
  check("queue-pin: writeQueue writes via temp+rename (durable)",
        src:find('local tmp = path .. ".tmp." .. tostring(FX.now())', 1, true) ~= nil
        and src:find("if not os.rename(tmp, path) then os.remove(tmp) end", 1, true) ~= nil)
  check("queue-pin: readQueue backs up an undecodable queue (no silent disarm)",
        src:find("undecodable queue", 1, true) ~= nil
        and src:find('local bak = path .. ".bad." .. tostring(FX.now())', 1, true) ~= nil)
  -- R3-09: the JS actionableKeys twin must mirror core.remoteActionAllowed (remote
  -- approve/deny only when gate=='waiting'). There is NO remote-keystroke transport, so
  -- nudge/stop/clear/compact must NEVER be bulk-eligible for a remote tile -- the JS twin
  -- returns false for them, matching the Lua side after the keystrokes branch was removed.
  check("bulk-pin: actionableKeys gates remote approve/deny on gate=='waiting'",
        src:find('if(action === "approve" || action === "deny") return it.gate === "waiting";', 1, true) ~= nil)
  check("bulk-pin: actionableKeys never bulk-keystrokes a remote tile",
        src:find("if(BRIDGE_KEYSTROKES) return (action === \"nudge\"", 1, true) == nil)
  -- Folder scan must run deadlock-proof: via /bin/sh with stdout redirected to a file (NOT
  -- direct-exec hs.task, which stalls >64KB over a large tree), reading the file on exit,
  -- with a timeout backstop. Reverting to `hs.task.new(argv[1]` would reintroduce the hang.
  check("fscan-pin: scan runs via /bin/sh (not direct-exec)", src:find('hs.task.new("/bin/sh"', 1, true) ~= nil)
  check("fscan-pin: scan command built by core (quoted + redirect)", src:find("core.folderScanShellCommand(argv, outFile)", 1, true) ~= nil)
  check("fscan-pin: scan reads the temp file on exit", src:find("FX.readFile(outFile)", 1, true) ~= nil)
  check("fscan-pin: scan has a timeout backstop", src:find("folder scan timed out", 1, true) ~= nil)
  -- New-project spawn cold-start fix: the VS Code open goes through core.vscodeOpenArgs (so a
  -- cold start gets --disable-workspace-trust), and the extension ladder, on a cold start, is
  -- ADAPTIVE -- it polls until the project window actually appears (focusProject true only on a
  -- real title match), waits a tunable activation buffer, then opens the panel once and pastes
  -- the task. Fixed-delay ⌘Esc was firing into the still-loading Welcome tab and missing.
  check("spawn-pin: VS Code open uses core.vscodeOpenArgs(spec)",
        src:find("core.vscodeOpenArgs(spec)", 1, true) ~= nil)
  check("spawn-pin: cold-start ladder branches on spec.coldStart",
        src:find("if spec.coldStart == true then", 1, true) ~= nil)
  check("spawn-pin: cold-start polls for the window (focusProject false) before opening the panel",
        -- R2-09: the editor is threaded through (spec.editor), never nil, so a Cursor
        -- spawn can't resolve to a VS Code window.
        src:find("focusProject(name, proj, spec.editor, false)", 1, true) ~= nil
        and src:find("focusProject(name, proj, nil, false)", 1, true) == nil
        and src:find("cold-start: window seen after", 1, true) ~= nil)
  check("spawn-pin: cold-start poll is BOUNDED via pure core.coldStartStep (giveup, can't hang)",
        src:find("core.coldStartStep(focusProject", 1, true) ~= nil
        and src:find('step == "wait"', 1, true) ~= nil      -- ladder reads the helper's decision
        and src:find("never matched after", 1, true) ~= nil)  -- + the give-up log on the bounded path
  check("spawn-pin: cold-start activation buffer is tunable (spec.coldWindowWait / coldActivate, Save-safe)",
        src:find("spec.coldWindowWait", 1, true) ~= nil and src:find("spec.coldActivate", 1, true) ~= nil)
  check("spawn-pin: cold-start pastes the task (not char-typing)",
        src:find("hs.pasteboard.setContents(spec.task)", 1, true) ~= nil)
  -- R1-09: per-window ladder map so concurrent A/B variants don't cancel each other.
  check("spawn-pin: cold-start ladder keyed per window (core.spawnLadderKey)",
        src:find("core.spawnLadderKey(spec)", 1, true) ~= nil
        and src:find("spawnSeqHandlesByKey[ladderKey]", 1, true) ~= nil)
  -- R1-19: the cold-start deliver path is delivery-gated (no paste on a window miss).
  check("spawn-pin: cold-start task is delivery-gated (no paste on window miss)",
        src:find("task NOT delivered", 1, true) ~= nil)
  -- R1-10: the user's clipboard is saved + restored around the cold-start task paste.
  check("spawn-pin: cold-start restores the user's clipboard after the task paste",
        src:find("local prevClip = hs.pasteboard.readString()", 1, true) ~= nil
        and src:find("if prevClip then pcall(function() hs.pasteboard.setContents(prevClip) end) end", 1, true) ~= nil)
  check("spawn-pin: new-project flag threaded from the modal (mode == new)",
        src:find("agentOpts, mode == \"new\")", 1, true) ~= nil)
  -- CLI-tools inventory (review of a4bef0c): the absolute-path install rule lives ONCE in
  -- core.isInstalledPath; FX.cliToolStatus calls it and keeps hs.fs.attributes on top (the
  -- on-disk existence check pure core can't do). The prefix gate must precede the stat.
  check("clitool-pin: FX.cliToolStatus uses the shared core.isInstalledPath rule",
        src:find("core.isInstalledPath(p) and hs.fs.attributes(p)", 1, true) ~= nil)
  check("clitool-pin: no duplicate inline '/'-prefix check remains in FX.cliToolStatus",
        src:find('p:sub(1, 1) == "/" and hs.fs.attributes(p)', 1, true) == nil)
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

  -- #2/#5: EVERY window-keystroke DISPATCH must reserve its slot through the ONE
  -- chokepoint (dispatchSerialized). Raw core.staggerSlot arithmetic at a call site
  -- is how drain/auto-feed/ctx-menu/Stream-Deck/hotkey paths drifted out of
  -- serialization in round 2. R3-07 adds exactly ONE more legitimate call site:
  -- spawnEditorWindow reserves the spawn ladder's worst-case on the SAME shared tail
  -- (the spawn paste/type beats run on after() timers too, so they must serialize
  -- against dispatched pastes). So the allowed count is now 2 (dispatchSerialized +
  -- the spawn-ladder reservation); any further raw call is still a drift smell.
  local slotCalls = select(2, src:gsub("core%.staggerSlot%(", ""))
  eq("inject-pin: staggerSlot called only by the 2 chokepoints (dispatch + R3-07 spawn ladder)", slotCalls, 2)
  -- Pin the R3-07 reservation specifically so the second call site can't be a stray.
  check("inject-pin: the 2nd staggerSlot site is the spawn-ladder reservation",
        src:find("spawnDelay, injectionTailAt = core.staggerSlot(", 1, true) ~= nil)
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
        src:find('dispatchSerialized(ct, "continue", function()', 1, true) ~= nil
        and src:find('core.handleAction(FX, ct, "continue")', 1, true) ~= nil)
  check("inject-pin: auto-continue ledgers the resume",
        src:find('type = "auto_continue",', 1, true) ~= nil
        -- R2-22: the budget is charged on confirmed delivery via chargeAutoContinue
        and src:find('core.chargeAutoContinue(autoContinueState, bk)', 1, true) ~= nil)
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
  -- R3-12: dateToTs boundaries are LOCAL (matching the local-time display), NOT UTC --
  -- a UTC boundary would filter/PURGE a different set than shown at the day edge.
  check("r3-12-pin: dateToTs uses local midnight (not Date.UTC)",
        src:find("var t = new Date(+m[1], +m[2]-1, +m[3]).getTime() / 1000;", 1, true) ~= nil
        and src:find("Date.UTC(+m[1], +m[2]-1, +m[3]) / 1000", 1, true) == nil)

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
        src:find("function FX.spawnSession(editor, project, task, permissionMode, providerId, agentOpts, isNew, modelOverride)", 1, true) ~= nil)
  check("l1-pin: opts.appendSystemPrompt threaded", src:find("opts.appendSystemPrompt = agentOpts.appendSystemPrompt", 1, true) ~= nil)
  check("l1-pin: opts.mcpConfigPath threaded", src:find("opts.mcpConfigPath = agentOpts.mcpConfigPath", 1, true) ~= nil)

  -- handleAction CRUD + spawn-from-agent
  check("l1-pin: agent CRUD action", src:find('a == "agent%-save" or a == "agent%-delete" or a == "agent%-fork"') ~= nil)
  check("l1-pin: agentPush wired", src:find("core.agentPush(FX.readAgents()", 1, true) ~= nil)
  check("l1-pin: agentFork wired", src:find("core.agentFork(FX.readAgents()", 1, true) ~= nil)
  check("l1-pin: mcp CRUD action", src:find('a == "mcp%-save" or a == "mcp%-delete"') ~= nil)
  check("l1-pin: spawn resolves a saved agent", src:find("core.resolveAgent(profile, { mcpState = FX.readMcp() })", 1, true) ~= nil)
  check("l1-pin: spawn writes the mcp-config", src:find("FX.writeMcpConfig(profile.name, res.mcpConfig)", 1, true) ~= nil)
  check("l1-pin: spawn passes agentOpts", src:find("payload.provider and tostring(payload.provider) or nil, agentOpts, mode == \"new\")", 1, true) ~= nil)
  check("l1-pin: spawn_agent ledger event", src:find('type = "spawn_agent"', 1, true) ~= nil)
  check("l1-pin: open-new feeds agentState", src:find("agentState = { agents = core.agentList(FX.readAgents())", 1, true) ~= nil)

  -- modal JS
  check("l1-pin: Agents chip row in modal", src:find('id="n%-agents"') ~= nil)
  check("l1-pin: skills card in modal", src:find('id="n%-skills"') ~= nil)
  check("l1-pin: showNew takes agentState", src:find("function showNew(cfg, recent, browse, presetState, agentState, templates)", 1, true) ~= nil)
  check("l1-pin: agentSpawn carries agent name", src:find("agent:p.name", 1, true) ~= nil)
  check("l1-pin: ccAgents updater", src:find("function ccAgents(list)", 1, true) ~= nil)
  check("l1-pin: saveAgent button", src:find("function saveAgent()", 1, true) ~= nil)
  check("l1-pin: renderSkills card", src:find("function renderSkills()", 1, true) ~= nil)
end

-- ---- L2 named policy bundles: dashboard wiring pins ------------------------
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("l2-pin: dashboard source readable", #src > 0)
  check("l2-pin: POLICY_DIR matches cc-approve default", src:find("/.claude/cc%-policy\"") ~= nil)
  check("l2-pin: POLICY_OVERRIDE_DIR", src:find("cc%-policy%-override") ~= nil)
  check("l2-pin: FX.policyOverride", src:find("function FX.policyOverride(", 1, true) ~= nil)
  check("l2-pin: FX.writeResolvedPolicy", src:find("function FX.writeResolvedPolicy(", 1, true) ~= nil)
  check("l2-pin: set-policy handler", src:find('a == "set%-policy"') ~= nil)
  check("l2-pin: refresh resolves policy", src:find("core.resolvePolicy(cfg,", 1, true) ~= nil)
  check("l2-pin: change-gated write via policyCache", src:find("policyCache[it.key] ~= enc", 1, true) ~= nil)
  check("l2-pin: bundle names pushed to panel", src:find("core.policyBundles(cfg)", 1, true) ~= nil)
  check("l2-pin: ccUpdate takes bundles", src:find("window.ccUpdate = function(items, providers, bundles)", 1, true) ~= nil)
  check("l2-pin: d-policy select in detail", src:find('id="d%-policy"') ~= nil)
  check("l2-pin: onPolicyChange", src:find("function onPolicyChange()", 1, true) ~= nil)
  check("l2-pin: syncPolicySelect called", src:find("syncPolicySelect(it)", 1, true) ~= nil)
  check("l2-pin: d-policy disabled for remote", src:find('"d-model","d-gate","d-policy","nudge"', 1, true) ~= nil)

  -- cc-approve.sh reads the per-session policy file (KEEP-IN-SYNC anchor)
  local g = io.open(ROOT .. "cc-approve.sh", "r")
  local gsrc = g and g:read("*a") or ""
  if g then g:close() end
  check("l2-pin: cc-approve POLICY_DIR default", gsrc:find("CC_POLICY_DIR", 1, true) ~= nil)
  check("l2-pin: cc-approve reads POLICY_FILE in match_patterns",
        gsrc:find('jq -r --arg k "$leaf"', 1, true) ~= nil)
  check("l2-pin: cc-approve bundle in ledger by", gsrc:find('by="bundle:$POLICY_BUNDLE"', 1, true) ~= nil)

  -- Review fixes: orphan sweep (decoupled from hasAtt/hasOvr), atomic write, cc_remove cleanup.
  check("l2-fix: orphan sweep reads POLICY_DIR", src:find("for _, n in ipairs(FX.readDir(POLICY_DIR))", 1, true) ~= nil)
  check("l2-fix: sweep clears keys not (re)written this tick", src:find("not wrote[n] then", 1, true) ~= nil)
  check("l2-fix: writeResolvedPolicy is atomic (temp+rename)",
        src:find("torn truncate-then-write", 1, true) ~= nil and src:find("os.rename(tmp, path)", 1, true) ~= nil)
  local lib = io.open(ROOT .. "cc-lib.sh", "r")
  local lsrc = lib and lib:read("*a") or ""
  if lib then lib:close() end
  check("l2-fix: cc-lib hoists CC_POLICY_DIR", lsrc:find("CC_POLICY_DIR=", 1, true) ~= nil)
  check("l2-fix: cc_remove reaps the L2 policy files",
        lsrc:find('"$CC_POLICY_DIR/$1" "$CC_POLICY_OVERRIDE_DIR/$1"', 1, true) ~= nil)
end

-- ---- L3 pins: template {{var}} render wiring (dashboard) -------------------
-- cc-core owns the render (no JS render twin); these guard the FX handler +
-- panel JS round-trip + the no-auto-send insert discipline against unwiring.
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("l3-pin: dashboard source readable", #src > 0)
  -- Lua handler: render action (cc-core authoritative) + versioned save + rich list
  check("l3-pin: template-render action", src:find('a == "template%-render"') ~= nil)
  check("l3-pin: render via cc-core",
        src:find("core.renderTemplate(core.composeTemplate(rec)", 1, true) ~= nil)
  check("l3-pin: prev_output from selected tile", src:find("sel.activity", 1, true) ~= nil)
  check("l3-pin: save is versioned",
        src:find("core.templatePushVersioned(FX.readTemplates()", 1, true) ~= nil)
  check("l3-pin: list reply carries vars", src:find("vars = core.effectiveVars(r)", 1, true) ~= nil)
  check("l3-pin: rendered echoed to panel", src:find("ccTemplateRendered(", 1, true) ~= nil)
  -- panel JS: var form -> render round-trip -> no-auto-send insert
  check("l3-pin: JS ccTemplateRendered", src:find("function ccTemplateRendered(o)", 1, true) ~= nil)
  check("l3-pin: JS var form", src:find("function renderVarForm()", 1, true) ~= nil)
  check("l3-pin: JS sends template-render", src:find('send("template-render"', 1, true) ~= nil)
  check("l3-pin: required-var gates Insert", src:find("btn.disabled = !ok", 1, true) ~= nil)
  check("l3-pin: menu renders body", src:find('esc(t.body || "")', 1, true) ~= nil)
  check("l3-pin: insert stays no-auto-send", src:find("el.value = (o && o.text)", 1, true) ~= nil)
  -- review-fix: dropped/corrupt records are surfaced, not silently reaped on save/delete
  check("l3-pin: load surfaces dropped records", src:find("dropped \" .. #loaded.errors", 1, true) ~= nil)
  -- Inc 3: render-before-spawn — modal template picker seeds #n-task via the same render
  check("l3-pin: shared enrichedTemplates helper", src:find("local function enrichedTemplates()", 1, true) ~= nil)
  check("l3-pin: open-new passes templates to modal", src:find("local tpls = enrichedTemplates()", 1, true) ~= nil)
  check("l3-pin: showNew takes templates arg",
        src:find("function showNew(cfg, recent, browse, presetState, agentState, templates)", 1, true) ~= nil)
  check("l3-pin: modal n-templates row", src:find('id="n-templates"', 1, true) ~= nil)
  check("l3-pin: modal picker fn", src:find("function modalTplPick(name)", 1, true) ~= nil)
  check("l3-pin: render target switch", src:find("var tplRenderTarget", 1, true) ~= nil)
  check("l3-pin: modal render targets n-task", src:find('tplRenderTarget = "n-task"', 1, true) ~= nil)
  check("l3-pin: modal required-var gates Use", src:find('document.getElementById("m-tpl-go")', 1, true) ~= nil)
  -- Inc 4: queue render-before-feed — {{prev_output}}/built-ins resolved before the paste,
  -- raw task still popped/persisted; keepMissing so non-template queues are byte-unaffected.
  check("l3-pin: renderFeed helper", src:find("local function renderFeed(task, item)", 1, true) ~= nil)
  check("l3-pin: renderFeed uses keepMissing", src:find("keepMissing = true", 1, true) ~= nil)
  check("l3-pin: renderFeed prevOutput from item.activity", src:find("item.activity", 1, true) ~= nil)
  -- every feed site renders before typing; none feeds the raw task verbatim
  check("l3-pin: all 3 feed sites render",
        select(2, src:gsub("FX%.feedTask%(winTarget%([a-z]+%), renderFeed%(task,", "")) == 3)
  check("l3-pin: no feed site bypasses render",
        src:find("FX.feedTask(winTarget(item), task)", 1, true) == nil
        and src:find("FX.feedTask(winTarget(it), task)", 1, true) == nil)
  -- Inc 5: definition source — import *.prompt/*.md from a local dir via cc-core
  check("l3-pin: PROMPTS_DIR constant", src:find("local PROMPTS_DIR", 1, true) ~= nil)
  check("l3-pin: FX.listPromptFiles", src:find("function FX.listPromptFiles(dir)", 1, true) ~= nil)
  check("l3-pin: template-import handler", src:find('a == "template%-import"') ~= nil)
  check("l3-pin: import via cc-core promptImport", src:find("core.promptImport(FX.readTemplates()", 1, true) ~= nil)
  check("l3-pin: sourceDir config override", src:find('core.config(loadConfig(), "templates.sourceDir"', 1, true) ~= nil)
  check("l3-pin: JS import row", src:find("function templateImport()", 1, true) ~= nil)
  -- L4 Inc 1: renderFeed strips the @role: routing prefix before typing
  check("l4-pin: renderFeed strips @role:", src:find("local _, bare = core.taskRoute(afterBarrier)", 1, true) ~= nil)
  -- L4 Inc 1 (review fix): applyGroups MUST run before the routing dispatcher, or
  -- every tile's .group is nil at route time and labeled tasks starve. Guard the order.
  do
    local agPos = src:find("core.applyGroups(list, groups)", 1, true)
    local rtPos = src:find("core.routeTask(members, q", 1, true)
    check("l4-pin: applyGroups runs before the router (so .group is set for @role:)",
          agPos ~= nil and rtPos ~= nil and agPos < rtPos)
  end
  -- L4 Inc 2: process modes (sequential vs distribute) wired to the detail panel
  check("l4-pin: queue-route-mode handler", src:find('a == "queue%-route%-mode"') ~= nil)
  check("l4-pin: mode handler uses queueSetMode", src:find("core.queueSetMode(FX.readQueue(qk)", 1, true) ~= nil)
  check("l4-pin: tile carries routeSeq", src:find("it.routeSeq = (core.queueRouteMode(q)", 1, true) ~= nil)
  check("l4-pin: seq checkbox + toggle", src:find('id="q-route-seq"', 1, true) ~= nil
        and src:find("function onRouteModeToggle()", 1, true) ~= nil)
  check("l4-pin: seq checkbox synced from routeSeq", src:find("seqEl.checked = !!it.routeSeq", 1, true) ~= nil)
  -- L4 Inc 3: renderFeed strips the @all:/@any: join barrier before typing
  check("l4-pin: renderFeed strips barrier", src:find("local _, afterBarrier = core.taskBarrier(tostring(task or ", 1, true) ~= nil)
  -- L4 Inc 4: per-task timing — stamp at feed, ledger task_done on the done edge
  check("l4-pin: taskStart map", src:find("local taskStart", 1, true) ~= nil)
  check("l4-pin: stampTaskStart helper", src:find("local function stampTaskStart(item, task, by)", 1, true) ~= nil)
  check("l4-pin: stamps at all 3 feed sites",
        select(2, src:gsub('stampTaskStart%(it[em]*, task, "', "")) == 3)
  check("l4-pin: task_done via stepTaskDone", src:find("core.stepTaskDone(started, pv and pv.status", 1, true) ~= nil)
  check("l4-pin: task_done ledger event", src:find('type = "task_done", durationS', 1, true) ~= nil)
  -- L4 review fix: taskStart has no self-expiry -> must abandon on stale + reap vanished keys
  check("l4-pin: abandon timer on stale", src:find("taskStart[it.key] = nil  -- abandon", 1, true) ~= nil)
  check("l4-pin: reap vanished task timers", src:find("core.reapUnbacked(taskStart, newPrev)", 1, true) ~= nil)
  -- L5 Inc 1: error-reason taxonomy — tile carries the cause, badge + fresh-edge ledger
  check("l5-pin: tile carries error_reason", src:find("it.error_reason = err.reason", 1, true) ~= nil)
  check("l5-pin: cause badge on the error tile", src:find("it.error_reason.replace(/_/g", 1, true) ~= nil)
  check("l5-pin: error cause ledgered on the fresh edge",
        src:find('type = "error", reason = it.error_reason', 1, true) ~= nil)
  -- L5 Inc 2: plan/TODO on the detail panel, loaded on selection via core.planFromTranscript
  check("l5-pin: plan handler", src:find('a == "plan"') ~= nil)
  check("l5-pin: plan via cc-core", src:find("core.planFromTranscript(tail)", 1, true) ~= nil)
  check("l5-pin: plan requested on selection", src:find('if(key) send("plan", key)', 1, true) ~= nil)
  check("l5-pin: ccPlan + renderPlan", src:find("window.ccPlan = function(key, data)", 1, true) ~= nil
        and src:find("function renderPlan()", 1, true) ~= nil)
  check("l5-pin: d-plan element", src:find('id="d-plan"', 1, true) ~= nil)
  check("l5-pin: plan text esc()'d (XSS sink)", src:find("esc(d.plan)", 1, true) ~= nil)
  -- L5 Inc 3: auto-title (off by default) — cached per projectKey, manual relabel wins
  check("l5-pin: autotitle persistence", src:find("function FX.loadAutoTitles()", 1, true) ~= nil
        and src:find("function FX.saveAutoTitles(map)", 1, true) ~= nil)
  check("l5-pin: autotitle loaded at startup", src:find("autoTitles = FX.loadAutoTitles()", 1, true) ~= nil)
  check("l5-pin: autotitle pass uses cc-core", src:find("core.deriveAutoTitle(it.last_prompt, 48)", 1, true) ~= nil)
  check("l5-pin: autotitle gated off by default", src:find('core.config(cfg, "autoTitle.enabled", false)', 1, true) ~= nil)
  check("l5-pin: name precedence label>autoTitle>name",
        src:find("esc(it.label || it.autoTitle || it.name)", 1, true) ~= nil)
  -- L5 Inc 4: loop-detection watchdog (off by default) — reuses the tail, ⟳ badge, once/episode
  check("l5-pin: loop detection via cc-core",
        src:find("core.isLooping(core.transcriptToolSigs(tail, loopRepeats + 2), loopRepeats)", 1, true) ~= nil)
  check("l5-pin: loop gated off by default", src:find('core.config(cfg, "escalation.loop.enabled", false)', 1, true) ~= nil)
  check("l5-pin: loop ledger once per episode", src:find("loopAlerted[it.key] = true", 1, true) ~= nil)
  check("l5-pin: loop alerted reaped", src:find("core.reapUnbacked(loopAlerted, newPrev)", 1, true) ~= nil)
  check("l5-pin: loop tile badge", src:find("⟳ looping", 1, true) ~= nil)
  -- L5 Inc 5: OS-native banners (off by default) via core.notifyDecision + FX.notify (hs.notify)
  check("l5-pin: FX.notify wraps hs.notify", src:find("function FX.notify(title, text, opts)", 1, true) ~= nil
        and src:find("hs.notify.new(function()", 1, true) ~= nil)
  check("l5-pin: notify click jumps to session", src:find("focusProject(it.name, it.cwd, it.editor, true)", 1, true) ~= nil)
  check("l5-pin: banner decision via cc-core", src:find("core.notifyDecision(pv.status, it, cfg)", 1, true) ~= nil)
  check("l5-pin: banner gated off by default", src:find('core.config(cfg, "notifications.banner.onApproval", false)', 1, true) ~= nil)
  -- L6: event-callback rule engine (cc-rules.json, off by default), safe processors
  check("l6-pin: RULES_FILE + FX.readRules", src:find("local RULES_FILE", 1, true) ~= nil
        and src:find("function FX.readRules()", 1, true) ~= nil)
  check("l6-pin: rules gated off by default", src:find('core.config(cfg, "rules.enabled", false)', 1, true) ~= nil)
  check("l6-pin: ruleSet loaded once per refresh", src:find("core.ruleList(FX.readRules())", 1, true) ~= nil)
  check("l6-pin: runRules helper", src:find("local function runRules(ruleSet, it, edgeKind)", 1, true) ~= nil)
  check("l6-pin: fires via core.rulesForEdge", src:find("core.rulesForEdge(ruleSet, edgeKind, it)", 1, true) ~= nil)
  check("l6-pin: fired on a fresh status edge", src:find("runRules(ruleSet, it, it.status)", 1, true) ~= nil)
  check("l6-pin: log processor ledgers by:rule", src:find('type = "rule", rule = r.name', 1, true) ~= nil)
  check("l6-pin: nudge processor uses delivery-gated path",
        src:find('core.handleAction(FX, target, "nudge", p.text)', 1, true) ~= nil)
  check("l6-pin: once-state reaped on vanish", src:find("if tk and not newPrev[tk] then ruleFired[k] = nil", 1, true) ~= nil)
  -- L6 Inc 3: automation result ledger — outcome field + the previously-silent blocked branch
  -- R1-22: outcome reflects the REAL launch (ok on a real spawn, dryrun on the no-op),
  -- and the dead tile is dropped only when a launch actually happened.
  check("l6-pin: auto_respawn outcome gated on real launch",
        src:find('outcome = launched and "ok" or "dryrun"', 1, true) ~= nil)
  check("r1-22-pin: removeStatus gated on a real launch (no vanish on dry-run)",
        src:find("if launched then", 1, true) ~= nil)
  check("r1-22-pin: spawnSession returns false on a dry-run no-op",
        src:find("return false  -- R1-22:", 1, true) ~= nil)
  check("l6-pin: blocked respawn now ledgered", src:find('type = "auto_respawn_blocked", outcome = "skipped"', 1, true) ~= nil)
  check("l6-pin: auto_continue outcome from delivery",
        src:find('outcome = (acted == "continue") and "ok" or "skipped"', 1, true) ~= nil)
  -- L6 review fix: manual continue is ledgered POST-dispatch, gated on delivery (not eager)
  check("l6-pin: manual continue gated ledger",
        src:find('type = "continue", outcome = (acted == "continue") and "ok" or "skipped"', 1, true) ~= nil)
  check("l6-pin: no eager continue ledger", src:find('ledgerFor(item, { type = "continue" })', 1, true) == nil)
  -- L7: scheduled routines (cc-schedules.json, off by default) firing engine
  check("l7-pin: SCHEDULES_FILE + FX.readSchedules", src:find("local SCHEDULES_FILE", 1, true) ~= nil
        and src:find("function FX.readSchedules()", 1, true) ~= nil)
  check("l7-pin: schedules gated off by default", src:find('core.config(cfg, "schedules.enabled", false)', 1, true) ~= nil)
  check("l7-pin: fires via core.dueSchedules", src:find("core.dueSchedules(core.scheduleList(sstate), os.time())", 1, true) ~= nil)
  check("l7-pin: fires through the normal spawn fx", src:find("FX.spawnSession(r.editor or core.config(cfg", 1, true) ~= nil)
  check("l7-pin: backpressure honored", src:find("core.scheduleBackpressure(liveCount, cap)", 1, true) ~= nil)
  check("l7-pin: mark fired (stamp/self-delete)", src:find("core.scheduleMarkFired(sstate, r.name, os.time())", 1, true) ~= nil)
  check("l7-pin: schedule_fire ledger", src:find('type = "schedule_fire", routine = r.name', 1, true) ~= nil)
  -- L7 Inc 4: periodic digest action pushes a fleetStandup over a window
  check("l7-pin: digest action branch", src:find('if r.action == "digest" then', 1, true) ~= nil)
  check("l7-pin: digest builds fleetStandup", src:find("core.fleetStandup(ledgerSnapshot()", 1, true) ~= nil)
  check("l7-pin: digest pushes via FX.push", src:find('FX.push(topic, "Claude Shepherd: shift report', 1, true) ~= nil)
  -- L7 board UI (deferred polish): the routine board overlay + CRUD bridge handlers
  check("l7board-pin: open/save/delete/toggle bridge",
        src:find('a == "open-routines" or a == "schedule-save" or a == "schedule-delete"', 1, true) ~= nil)
  check("l7board-pin: save via core.schedulePush", src:find("core.schedulePush(FX.readSchedules()", 1, true) ~= nil)
  check("l7board-pin: delete via core.scheduleRemove", src:find("core.scheduleRemove(FX.readSchedules()", 1, true) ~= nil)
  check("l7board-pin: toggle via core.scheduleSetEnabled", src:find("core.scheduleSetEnabled(FX.readSchedules()", 1, true) ~= nil)
  check("l7board-pin: board annotated via core.scheduleBoard", src:find("core.scheduleBoard(core.scheduleList(FX.readSchedules())", 1, true) ~= nil)
  check("l7board-pin: ccSchedules reply carries enabled+live", src:find('wv:evaluateJavaScript("ccSchedules("', 1, true) ~= nil)
  -- run-now: a separate handler that fires immediately, bypassing cron/enabled
  check("l7board-pin: run-now handler", src:find('a == "schedule-run-now"', 1, true) ~= nil)
  check("l7board-pin: run-now resolves via scheduleGet", src:find("core.scheduleGet(FX.readSchedules()", 1, true) ~= nil)
  check("l7board-pin: run-now ledgers by manual", src:find('by = "manual"', 1, true) ~= nil)
  -- panel JS: the board render + the cron-builder twin
  check("l7board-pin: ccSchedules render fn", src:find("function ccSchedules(list, schedOn, live)", 1, true) ~= nil)
  check("l7board-pin: cronBuildJS twin present", src:find("function cronBuildJS(spec)", 1, true) ~= nil)
  check("l7board-pin: cronBuildJS noted as a twin of core.cronBuild",
        src:find("HAND%-MIRRORED twin of core.cronBuild") ~= nil)
  check("l7board-pin: drawer routines entry", src:find("menuPick('routines')", 1, true) ~= nil)
  check("l7board-pin: routines overlay markup", src:find('<div id="routines">', 1, true) ~= nil)
  -- review fixes (adversarial pass): edit must not drop non-form fields, rename
  -- must keep lastFiredAt, and a name collision must confirm before clobbering.
  check("l7board-pin: edit carries forward lastFiredAt",
        src:find("if(prev.lastFiredAt != null) rec.lastFiredAt = prev.lastFiredAt", 1, true) ~= nil)
  check("l7board-pin: edit carries forward model/refs/tags",
        src:find('["model","templateRef","agentRef","tags"].forEach', 1, true) ~= nil)
  check("l7board-pin: pushTopic editable in-panel", src:find('gv("rf-pushtopic")', 1, true) ~= nil)
  check("l7board-pin: name-collision confirm",
        src:find("already exists — overwrite it?", 1, true) ~= nil)
  -- L3 templates editor (deferred polish): structured authoring + version/revert
  check("l3ed-pin: editorTemplates structured reply", src:find("local function editorTemplates()", 1, true) ~= nil)
  check("l3ed-pin: editor bridge handlers",
        src:find('a == "template-editor-list" or a == "template-editor-save"', 1, true) ~= nil)
  check("l3ed-pin: versioned save via templatePushVersioned", src:find("core.templatePushVersioned(stt, rec", 1, true) ~= nil)
  check("l3ed-pin: rename preserves history via core.templateRename", src:find("core.templateRename(stt, oldName, rec.name)", 1, true) ~= nil)
  check("l3ed-pin: carries forward vars schema", src:find("if prior and prior.vars then rec.vars = prior.vars end", 1, true) ~= nil)
  check("l3ed-pin: versions reply", src:find("core.templateVersions(FX.readTemplates(), name)", 1, true) ~= nil)
  check("l3ed-pin: revert via core.templateRevert", src:find("core.templateRevert(FX.readTemplates()", 1, true) ~= nil)
  check("l3ed-pin: ccTplEditor render fn", src:find("function ccTplEditor(list)", 1, true) ~= nil)
  check("l3ed-pin: ccTplVersions render fn", src:find("function ccTplVersions(name, versions)", 1, true) ~= nil)
  check("l3ed-pin: drawer templates entry", src:find("menuPick('templates')", 1, true) ~= nil)
  check("l3ed-pin: templates overlay markup", src:find('<div id="tpleditor">', 1, true) ~= nil)
  -- L1 agents registry editor (deferred polish): full-field authoring + attach + MCP surface
  check("l1ed-pin: editor bridge handlers",
        src:find('a == "open-agents-editor" or a == "agent-ed-save"', 1, true) ~= nil)
  check("l1ed-pin: save via core.agentPush", src:find("core.agentPush(st0, p)", 1, true) ~= nil)
  check("l1ed-pin: carries forward non-form fields", src:find('"modelByMode", "requiredEnv", "versions", "forkedFrom"', 1, true) ~= nil)
  check("l1ed-pin: rename removes old record first", src:find("st0 = core.agentRemove(st0, oldName)", 1, true) ~= nil)
  check("l1ed-pin: flag toggle via core.agentSetFlag", src:find("core.agentSetFlag(FX.readAgents()", 1, true) ~= nil)
  check("l1ed-pin: fork via core.agentFork", src:find("core.agentFork(FX.readAgents()", 1, true) ~= nil)
  check("l1ed-pin: MCP registry save via core.mcpPush in editor", src:find('a == "mcp-ed-save"', 1, true) ~= nil)
  check("l1ed-pin: editor bundle reply", src:find('wv:evaluateJavaScript("ccAgentEd("', 1, true) ~= nil)
  check("l1ed-pin: bundle carries skills+providers+bundles",
        src:find("skills = FX.listSkills(), providers = core.config(lc", 1, true) ~= nil)
  check("l1ed-pin: ccAgentEd render fn", src:find("function ccAgentEd(b)", 1, true) ~= nil)
  check("l1ed-pin: attach chips union (no silent drop)", src:find("Object.keys(afSkills).forEach", 1, true) ~= nil)
  check("l1ed-pin: drawer agents entry", src:find("menuPick('agents')", 1, true) ~= nil)
  check("l1ed-pin: agents overlay markup", src:find('<div id="agented">', 1, true) ~= nil)
  -- review fix: MCP form pre-validates the transport requirement before the
  -- optimistic reset (else a server-side reject wipes the typed input).
  check("l1ed-pin: MCP form pre-validates transport",
        src:find('alert("stdio transport needs a command.")', 1, true) ~= nil)
  -- L2 policy bundle/attachment editor (deferred polish): edits cc-config.json policies
  check("l2ed-pin: policy editor bridge handlers",
        src:find('a == "open-policy-editor" or a == "policy-bundle-save"', 1, true) ~= nil)
  check("l2ed-pin: reads RAW config file", src:find("local raw = FX.readFile(CONFIG_FILE)", 1, true) ~= nil)
  check("l2ed-pin: bundle save via core.policySetBundle", src:find("core.policySetBundle(policies, name, p)", 1, true) ~= nil)
  check("l2ed-pin: bundle rename removes old key", src:find("policies = core.policyRemoveBundle(policies, oldName)", 1, true) ~= nil)
  check("l2ed-pin: attachment add/move/remove",
        src:find("core.policyAddAttachment(policies", 1, true) ~= nil
        and src:find("core.policyMoveAttachment(policies, p.index, p.dir)", 1, true) ~= nil)
  check("l2ed-pin: writes cfg.policies back", src:find("cfg.policies = policies", 1, true) ~= nil)
  check("l2ed-pin: reply carries starters + armed",
        src:find("hs.json.encode(core.DEFAULT_POLICY_BUNDLES)", 1, true) ~= nil
        and src:find("FX.readFile(GATE_FLAG) ~= nil) and \"true\" or \"false\"", 1, true) ~= nil)
  check("l2ed-pin: ccPolicyEd render fn", src:find("function ccPolicyEd(o)", 1, true) ~= nil)
  check("l2ed-pin: drawer policies entry", src:find("menuPick('policies')", 1, true) ~= nil)
  check("l2ed-pin: policy overlay markup", src:find('<div id="policyed">', 1, true) ~= nil)
  -- L6 rules editor + new triggers/processors (deferred polish)
  check("l6ed-pin: FX.writeRules", src:find("function FX.writeRules(state)", 1, true) ~= nil)
  check("l6ed-pin: editor bridge handlers",
        src:find('a == "open-rules-editor" or a == "rule-ed-save"', 1, true) ~= nil)
  check("l6ed-pin: save via core.rulePush", src:find("core.rulePush(st0, p)", 1, true) ~= nil)
  check("l6ed-pin: toggle via core.ruleSetEnabled", src:find("core.ruleSetEnabled(FX.readRules()", 1, true) ~= nil)
  check("l6ed-pin: ccRuleEd render fn", src:find("function ccRuleEd(list, on)", 1, true) ~= nil)
  check("l6ed-pin: drawer rules entry", src:find("menuPick('rules')", 1, true) ~= nil)
  check("l6ed-pin: rules overlay markup", src:find('<div id="ruleed">', 1, true) ~= nil)
  -- new triggers fired at their detection sites + new processors in the engine
  check("l6trig-pin: loop trigger fired on rising edge", src:find('runRules(ruleSet, it, "loop")', 1, true) ~= nil)
  check("l6trig-pin: hung trigger fired on rising edge", src:find('runRules(ruleSet, it, "hung")', 1, true) ~= nil)
  check("l6trig-pin: starved trigger fired on rising edge", src:find('runRules(ruleSet, members[1], "starved")', 1, true) ~= nil)
  check("l6proc-pin: feed processor enqueues via queuePush",
        src:find("core.queuePush(FX.readQueue(qk), tostring(p.text))", 1, true) ~= nil)
  check("l6proc-pin: feed key sanitized like the reader (review fix)",
        src:find("review%-caught silent data loss") ~= nil)
  check("l6proc-pin: continue processor delivery-gated",
        src:find('core.handleAction(FX, target, "continue")', 1, true) ~= nil)
  -- L5 observability batch: Settings toggles (autoTitle/loop/banner) + hooks inspector
  check("l5b-pin: autoTitle toggle populated", src:find('cv(cfg,"autoTitle.enabled",false)', 1, true) ~= nil)
  check("l5b-pin: loop toggle populated", src:find('cv(cfg,"escalation.loop.enabled",false)', 1, true) ~= nil)
  check("l5b-pin: banner toggles populated", src:find('cv(cfg,"notifications.banner.onApproval",false)', 1, true) ~= nil)
  check("l5b-pin: toggles persisted (escalation.loop)", src:find('loop: { enabled: ck("s-loop-en")', 1, true) ~= nil)
  check("l5b-pin: toggles persisted (autoTitle/notifications)",
        src:find('autoTitle: { enabled: ck("s-autotitle") }', 1, true) ~= nil
        and src:find('notifications: { banner:', 1, true) ~= nil)
  check("l5b-pin: hooks inspector bridge", src:find('a == "inspect-hooks"', 1, true) ~= nil)
  check("l5b-pin: hooks via core.parseHookInventory", src:find("core.parseHookInventory(settings)", 1, true) ~= nil)
  check("l5b-pin: gate timeout check", src:find("core.gateHookTimeoutOk(inv, 130)", 1, true) ~= nil)
  check("l5b-pin: ccHooks render fn", src:find("function ccHooks(inv, gate, path)", 1, true) ~= nil)
  -- L5 detail-panel tab strip (keystone): tabs from core.DETAIL_TABS, localStorage
  -- bridge keyed by projectKey, lazy Timeline fetch, pin/unpin menu.
  check("l5tab-pin: DETAIL_TABS injected single-source",
        src:find("__DETAIL_TABS__", 1, true) ~= nil
        and src:find('HTML:gsub("__DETAIL_TABS__"', 1, true) ~= nil)
  -- R3-10: NARRATE (emoji+verb) is single-sourced via __NARRATE__; the JS evDesc twin
  -- derives emoji + label from it (evEmoji/evVerb), and the hand-maintained EV_VERB/EV_EMOJI
  -- partial maps are GONE so they can't drift from cc-core.lua NARRATE.
  check("r3-10-pin: NARRATE injected single-source",
        src:find("var NARRATE = __NARRATE__;", 1, true) ~= nil
        and src:find('HTML:gsub("__NARRATE__"', 1, true) ~= nil)
  check("r3-10-pin: evDesc derives emoji+label from NARRATE (no EV_VERB/EV_EMOJI maps)",
        src:find("function evVerb(t)", 1, true) ~= nil
        and src:find("var label = evVerb(e.type);", 1, true) ~= nil
        and src:find("var EV_VERB = {", 1, true) == nil
        and src:find("var EV_EMOJI = {", 1, true) == nil)
  check("l5tab-pin: tab bar + panels markup", src:find('<div id="d-tabs">', 1, true) ~= nil
        and src:find('class="d-panel" data-tab="activity"', 1, true) ~= nil
        and src:find('class="d-panel" data-tab="queue"', 1, true) ~= nil)
  check("l5tab-pin: JS mirrors core.normalizeTabState", src:find("function normalizeTabStateJS(raw)", 1, true) ~= nil)
  check("l5tab-pin: localStorage keyed by projectKey",
        src:find('return "cc-detailTabs-" + pk', 1, true) ~= nil
        and src:find("function projectKeyOf(it)", 1, true) ~= nil)
  check("l5tab-pin: tab state restored on selection", src:find("loadTabState(key)", 1, true) ~= nil)
  check("l5tab-pin: lazy Timeline fetch (not on tick)", src:find('send("detail-timeline", selectedKey)', 1, true) ~= nil
        and src:find('a == "detail-timeline"', 1, true) ~= nil)
  check("l5tab-pin: inline timeline reuses narr + stale guard",
        src:find("evs.map(narr).join", 1, true) ~= nil
        and src:find("if(TIMELINE.key !== selectedKey)", 1, true) ~= nil)
  check("l5tab-pin: default tab can't be unpinned", src:find('if(id === "activity") return;', 1, true) ~= nil)
  -- adversarial-review fixes (round 1): dedup in-flight timeline fetch, DOM-safe
  -- tab menu (no inline-handler id interpolation), empty-state notes, JS/Lua parity.
  check("l5tab-fix: timeline fetch deduped via pending marker",
        src:find("TIMELINE = { key: selectedKey, events: null }", 1, true) ~= nil
        and src:find("if(evs === null)", 1, true) ~= nil)
  check("l5tab-fix: tab menu built DOM-safe (no inline onchange interpolation)",
        src:find("cb.onchange = function(){ toggleTabPinned(t.id); }", 1, true) ~= nil
        and src:find('onchange="toggleTabPinned(', 1, true) == nil)
  check("l5tab-fix: empty-state notes for active-but-empty tabs",
        src:find("No gate decisions recorded for this session yet", 1, true) ~= nil
        and src:find("No token usage recorded for this session yet", 1, true) ~= nil)
  check("l5tab-fix: normalizeTabStateJS canonical map form (matches Lua)",
        src:find("function normalizeTabStateJS(raw)", 1, true) ~= nil
        and src:find("if(ru[k]===true && valid[k] && k!==def) unp[k]=true;", 1, true) ~= nil)
  -- #2 git Changes tab: panel markup, lazy fetch via FX.gitStatus/Diff, per-file
  -- diff expand, run-from-root, capped diff, remote/no-repo guards.
  check("l5chg-pin: changes panel markup", src:find('class="d-panel" data-tab="changes"', 1, true) ~= nil
        and src:find('<div id="d-changes">', 1, true) ~= nil)
  check("l5chg-pin: status + diff bridge handlers",
        src:find('a == "detail-changes"', 1, true) ~= nil and src:find('a == "detail-diff"', 1, true) ~= nil)
  check("l5chg-pin: parses status via core.parseGitStatus",
        src:find("core.parseGitStatus(FX.gitStatus(root)", 1, true) ~= nil)
  check("l5chg-pin: runs git from the repo ROOT (path parity)",
        src:find("FX.gitRoot(it.cwd) or nil", 1, true) ~= nil)
  -- semantic anchors (not the exact byte count) so harmless refactors don't break the test
  check("l5chg-pin: diff output is capped", src:find("head -c", 1, true) ~= nil)
  check("l5chg-pin: remote + no-repo guarded",
        src:find("reply({ remote = true })", 1, true) ~= nil
        and src:find("reply({ noRepo = true })", 1, true) ~= nil)
  check("l5chg-pin: lazy fetch (not on tick) + stale guard",
        src:find('send("detail-changes", selectedKey)', 1, true) ~= nil
        and src:find("if(CHANGES.key !== selectedKey){ box.innerHTML", 1, true) ~= nil)
  check("l5chg-pin: per-file diff fetch on expand",
        src:find('send("detail-diff", selectedKey, f.path)', 1, true) ~= nil)
  -- #2 review fixes (semantic anchors, not verbatim shell strings): status is
  -- porcelain v1 in -z mode, verbatim paths, byte-capped; ccDetailChanges guarded.
  check("l5chg-fix: status is porcelain v1 -z, verbatim, capped",
        src:find("porcelain=v1", 1, true) ~= nil and src:find("quotepath=false", 1, true) ~= nil
        and src:find("status --porcelain=v1 -z", 1, true) ~= nil)
  check("l5chg-fix: ccDetailChanges entry stale guard",
        src:find("window.ccDetailChanges = function(key, data){", 1, true) ~= nil
        and src:find("if(key !== selectedKey) return;", 1, true) ~= nil)
  -- leaderboard review: rename-aware diff (orig forwarded from the cached file set)
  -- + detail-diff validates the bridge path against that set (no --no-index arbitrary read).
  check("l5chg-rev: rename-aware diff via orig",
        src:find("function FX.gitDiff(root, file, orig)", 1, true) ~= nil
        and src:find("diff HEAD -M --no-color", 1, true) ~= nil)
  check("l5chg-rev: detail-diff validates path via pure core.resolveDiffTarget",
        src:find("core.resolveDiffTarget(gitChangeFiles[key], file)", 1, true) ~= nil
        and src:find("not okPath then reply", 1, true) ~= nil)
  check("l5chg-rev: detail-changes caches the authoritative file set",
        src:find("gitChangeFiles[key] = allowed", 1, true) ~= nil)
  -- observed-from-console fix: the official-usage poll logs only on STATUS CHANGE
  -- (a persistent -1/401 was spamming every 180s); the pure decision lives in
  -- core.officialUsageStep (behavior-tested, incl. the decodable-body gating), the
  -- callback just decodes the body and wires it in one call.
  check("usagelog-fix: official fetch uses pure core.officialUsageStep(prev,status,bodyOk)",
        src:find("core.officialUsageStep(lastOfficialStatus, status, bodyOk)", 1, true) ~= nil
        and src:find("official usage recovered (HTTP 200)", 1, true) ~= nil)
  -- fable-usage: per-model weekly rows (Fable + any future scoped model) from the OAuth
  -- limits[] surface. The show-gate AND the legacy-Sonnet de-dup are decided in pure,
  -- unit-tested core (core.modelLimitRowsToShow, incl. the versioned-name prefix match),
  -- so the callback enriches the payload once and the footer is a thin renderer.
  check("fable-usage: payload enriched via pure core.modelLimitRowsToShow",
        src:find("j.modelRows = core.modelLimitRowsToShow(j)", 1, true) ~= nil)
  check("fable-usage: footer iterates the render-ready o.modelRows",
        src:find("o.modelRows && o.modelRows.length", 1, true) ~= nil)
  check("fable-usage: renders a Weekly · <model> bar (Fable when active)",
        src:find('pctBarRow("Weekly · " + ml.model', 1, true) ~= nil)
  -- the JS-side show/dedup logic is GONE (moved to core) -- guard against it creeping back
  check("fable-usage: no JS-side show/dedup remains (decided in core)",
        src:find("ml.model.toLowerCase()", 1, true) == nil
        and src:find("o.modelLimits", 1, true) == nil)
  -- pctBarRow HTML-escapes its label: the Weekly·<model> row interpolates an
  -- Anthropic-supplied display_name into innerHTML (defense in depth).
  check("fable-usage: pctBarRow escapes its label before innerHTML",
        src:find('String(lbl).replace(/[&<>"]/g', 1, true) ~= nil
        and src:find('<span class="lbl">\'+l+\'</span>', 1, true) ~= nil)
  -- limit-guard: the plan-limit warning wiring. Decision is pure+tested
  -- (core.usageLimitAlerts); the callback owns the effects (one OS notification +
  -- ledger event per window crossing) and the memo lives on FX (200-local ceiling).
  check("limit-guard: memo on FX, not a new top-level local",
        src:find("FX._usageAlertFired = {}", 1, true) ~= nil)
  check("limit-guard: decision via pure core.usageLimitAlerts with the FX memo",
        src:find("core.usageLimitAlerts(j, FX._usageAlertFired", 1, true) ~= nil)
  check("limit-guard: config-gated (default ON) with a tunable threshold",
        src:find('core.config(cfg, "usage.limitAlerts.enabled", true)', 1, true) ~= nil
        and src:find('core.config(cfg, "usage.limitAlerts.thresholdPct", 90)', 1, true) ~= nil)
  check("limit-guard: fires an OS notification and a usage_limit ledger event",
        src:find('FX.notify("Claude plan: " .. a.label', 1, true) ~= nil
        and src:find('type = "usage_limit", window = a.key', 1, true) ~= nil)
  -- #3 export session archive: bridge handler, transcript cp (verbatim, large-safe),
  -- meta via core, ledger event, two entry points (detail button + ctx-menu).
  check("l5exp-pin: export-session handler", src:find('a == "export-session"', 1, true) ~= nil)
  check("l5exp-pin: meta assembled via core", src:find("core.sessionExportMeta(it, res.events", 1, true) ~= nil
        and src:find("core.sessionExportBasename(it, now)", 1, true) ~= nil)
  check("l5exp-pin: transcript copied verbatim via cp (large-safe)",
        src:find('hs.execute("cp -- " .. s', 1, true) ~= nil)
  check("l5exp-pin: ledgers a session_export action",
        src:find('type = "session_export"', 1, true) ~= nil)
  check("l5exp-pin: detail-panel Export button + fn",
        src:find('id="b-export"', 1, true) ~= nil and src:find('send("export-session", selectedKey)', 1, true) ~= nil)
  check("l5exp-pin: ctx-menu Export entry", src:find('title = "Export session…"', 1, true) ~= nil)
  check("l5exp-pin: export dir constant", src:find("/.claude/cc-exports", 1, true) ~= nil)
  -- #3 review fixes: success verified by real meta.json existence (no phantom
  -- ledger on write failure) + re-exports uniquified (no silent overwrite).
  check("l5exp-fix: success verified via meta.json existence",
        src:find('local ok = hs.fs.attributes(dir .. "/meta.json") ~= nil', 1, true) ~= nil)
  check("l5exp-fix: export failure surfaced", src:find("export FAILED", 1, true) ~= nil)
  -- #3 review round 2: uniquify via pure core.uniquifyName; ledger the resolved
  -- name (not the bare basename); meta.transcript reflects the ACTUAL copy.
  check("l5exp-rev: uniquify via pure core.uniquifyName",
        src:find("core.uniquifyName(basename, function(c)", 1, true) ~= nil)
  check("l5exp-rev: ledgers the uniquified name (matches folder)",
        src:find('dir = out.name', 1, true) ~= nil)
  check("l5exp-rev: meta.transcript reflects actual copy",
        src:find('meta.transcript = (hs.fs.attributes(dir .. "/transcript.jsonl") ~= nil)', 1, true) ~= nil)
  check("l5exp-rev: exportSession takes the meta table (sets transcript itself)",
        src:find("FX.exportSession(it, basename, meta)", 1, true) ~= nil)
  -- #4 post-run self-summary + onAutoApproved banner
  check("l5sum-pin: Settings toggles populated + persisted",
        src:find('cv(cfg,"summary.enabled",false)', 1, true) ~= nil
        and src:find('summary: { enabled: ck("s-summary-en") }', 1, true) ~= nil
        and src:find('onAutoApproved: ck("s-banner-auto")', 1, true) ~= nil)
  check("l5sum-pin: self-summary fires on fresh done edge via core",
        src:find("core.stepSelfSummary(summaryState, it", 1, true) ~= nil
        and src:find('prevStatus = pv and pv.status or nil', 1, true) ~= nil)
  check("l5sum-pin: summary typed via serialized chokepoint",
        src:find('dispatchSerialized(su, "summary"', 1, true) ~= nil
        and src:find("FX.pasteIntoWindow(winTarget(su), { text = core.summaryPrompt(su) })", 1, true) ~= nil)
  -- review fix: the summary ledger is delivery-gated (only when the paste landed).
  check("l5sum-fix: summary ledger gated on delivery",
        src:find("if landed and ledgerOn then ledgerFor(su", 1, true) ~= nil)
  -- review fix: delivery promotion goes through pure core.promoteSummary (land->fired,
  -- miss->clear-pending-retry); the summary-OFF branch clears the guard (no orphan).
  -- Loosened anchors (no embedded whitespace/comment) so a reflow doesn't break them.
  check("l5sum-fix: promotion via pure core.promoteSummary",
        src:find("core.promoteSummary(summaryState, su.key, landed and true or false)", 1, true) ~= nil)
  check("l5sum-fix: feature-off clears the guard (no orphaned pending)",
        src:find("summaryState.fired[it.key] = nil; summaryState.pending[it.key] = nil", 1, true) ~= nil)
  check("l5sum-pin: onAutoApproved edge observes first sighting (no false alarm)",
        src:find("core.newestAutoApprove(ledgerSnapshot(), it.session_id)", 1, true) ~= nil
        and src:find("autoApproveFired[it.key] = newest", 1, true) ~= nil)
  -- review fix: onAutoApproved excludes remote/stale (parity with shouldSummarize)
  check("l5sum-fix: onAutoApproved excludes remote/stale + needs ledger + prev",
        src:find("if autoApprovedBannerOn and ledgerOn and pv ~= nil and not it.remote and not it.stale", 1, true) ~= nil)
  -- review fix: the per-key reaps are single-sourced through pure core.reapUnbacked
  -- (behavior-tested), so the unbounded-growth guard can't drift per table.
  check("l5sum-pin: new per-key state is reaped via core.reapUnbacked (no leak)",
        src:find("core.reapUnbacked(autoApproveFired, newPrev)", 1, true) ~= nil
        and src:find("core.reapUnbacked(summaryState.fired, newPrev)", 1, true) ~= nil
        and src:find("core.reapUnbacked(summaryState.pending, newPrev)", 1, true) ~= nil
        and src:find("core.reapUnbacked(gitChangeFiles, newPrev)", 1, true) ~= nil)
  -- R1-23: the auto-continue / respawn state tables are reaped too (no slow leak for
  -- a tile pruned/abandoned while still in error/respawn state).
  check("r1-23-pin: autoContinueState.since reaped (tile-key)",
        src:find("core.reapUnbacked(autoContinueState.since, newPrev)", 1, true) ~= nil)
  check("r1-23-pin: respawnAttempts + autoContinueState.attempts reaped (budgetKey)",
        -- R2-21: reaped against the live budgetKey set (per-window), not bare projectKey
        src:find("core.reapUnbacked(respawnAttempts, liveBudgetKeys)", 1, true) ~= nil
        and src:find("core.reapUnbacked(autoContinueState.attempts, liveBudgetKeys)", 1, true) ~= nil)
  check("r2-23-pin: watchdog + draining reaped on tile vanish",
        src:find("core.reapUnbacked(watchdog, newPrev)", 1, true) ~= nil
        and src:find("core.reapUnbacked(draining, newPrev)", 1, true) ~= nil)
  -- R3-20: routePending + starved* are reaped so vanished tiles/projects can't leak
  check("r3-20-pin: routePending reaped on tile vanish",
        src:find("core.reapUnbacked(routePending, newPrev)", 1, true) ~= nil)
  check("r3-20-pin: starved* reaped against live queueKeys",
        src:find("core.reapUnbacked(starvedSince, liveQk)", 1, true) ~= nil
        and src:find("core.reapUnbacked(starvedAlerted, liveQk)", 1, true) ~= nil)
  -- R3-24: refresh() has a re-entrancy guard (a kitty feed's waitUntilExit pumps the loop)
  check("r3-24-pin: refresh re-entrancy guard",
        src:find("if FX._refreshBusy then return end", 1, true) ~= nil
        and src:find("local ok, err = pcall(FX._refreshBody)", 1, true) ~= nil)
  -- R3-07: spawn ladders reserve a slot on the SHARED injection tail (so a concurrent
  -- dispatched paste queues behind them) and re-assert focus right before each task
  -- paste/type beat (so a focus theft mid-ladder skips rather than typing into the
  -- wrong window). The worst-case reservation comes from the pure core.spawnLadderWorst.
  check("r3-07-pin: spawnEditorWindow reserves a shared-tail slot for the ladder",
        src:find("spawnDelay, injectionTailAt = core.staggerSlot(", 1, true) ~= nil
        and src:find("core.spawnLadderWorst(spec)", 1, true) ~= nil)
  check("r3-07-pin: ladder entry beats are offset by spawnDelay",
        src:find("delay = 3.0 + spawnDelay", 1, true) ~= nil
        and src:find("termDriveBeats(3.0 + spawnDelay)", 1, true) ~= nil
        and src:find("sched(2.0 + spawnDelay, poll)", 1, true) ~= nil)
  check("r3-07-pin: warm + terminal task beats re-assert focus before paste/type",
        src:find("warmMatched = focusProject(name, proj, spec.editor, true)\n        if warmMatched == false then", 1, true) ~= nil
        and src:find("termMatched = focusProject(name, proj, spec.editor, true)\n          if termMatched == false then\n            print(\"[cc-orch] vscode terminal: no window match on re-assert", 1, true) ~= nil)
  -- #5 PR/MR status per tile (gh-backed, status-only)
  check("l5pr-pin: gh self-gates (resolveBin, absent -> false)",
        src:find("ghBinPath = (p and hs.fs.attributes(p)) and p or false", 1, true) ~= nil)
  check("l5pr-pin: async gh poll (hs.task) parses via core, planned by core.prPollPlan",
        src:find("function FX.ghPrStatus(root)", 1, true) ~= nil
        and src:find("core.parsePrStatus(stdout)", 1, true) ~= nil
        and src:find("core.prPollPlan(cached, inflight, now", 1, true) ~= nil)
  -- review fix (both leaderboard reviews): a HUNG gh (callback never fires) used to latch
  -- prStatusTasks[root] forever, making the short-retry window dead code. core.prPollPlan
  -- now flags a stale in-flight task and FX terminates it before re-polling. The retry
  -- behavior itself is behavior-tested in core.test (prpoll: hung gh ... kills + re-polls).
  -- R1-27: bridgeSync has a timeout backstop so a never-returning rsync task can't
  -- pin b.running forever and permanently starve that host's sync.
  check("bridge-pin: bridgeSync arms a per-host timeout backstop",
        src:find("b.timeoutTimer = hs.timer.doAfter(backstop", 1, true) ~= nil)
  check("bridge-pin: backstop terminates a wedged task + frees the slot",
        src:find("sync timed out -- task wedged, slot freed", 1, true) ~= nil)
  check("bridge-pin: backstop cancelled on normal exit",
        src:find("R1-27: cancel the timeout backstop on a real exit", 1, true) ~= nil)
  -- R1-38: a terminated/superseded folder scan's late exit callback must not clobber a
  -- good folderIndex with an empty one (ownership compare against the live slot).
  check("r1-38-pin: folder-scan exit callback guards against a terminated/superseded scan",
        src:find("if folderScanTask ~= myTask then pcall(os.remove, outFile); return end", 1, true) ~= nil)
  check("l5pr-fix: hung gh task is terminated before re-poll (slot reclaimed)",
        src:find("if plan.killStale and inflight and inflight.task then", 1, true) ~= nil
        and src:find("inflight.task:terminate()", 1, true) ~= nil
        and src:find("local PR_RETRY_TTL = 20", 1, true) ~= nil)
  -- review fix: a data-aware hung deadline is passed to the planner (the cold-vs-had-data
  -- mapping is the dashboard wiring; the deadline BEHAVIOR is covered by core.test prpoll).
  -- Loose pins (survive a reword): the value is wired as `deadline =` and is data-aware.
  check("l5pr-fix: data-aware hung deadline wired into the poll plan",
        src:find("deadline = hungTtl", 1, true) ~= nil
        and src:find("PR_HUNG_TTL", 1, true) ~= nil
        and src:find("cached.data ~= nil", 1, true) ~= nil)
  check("l5pr-pin: runs gh in the repo root, status-only fields",
        src:find("t:setWorkingDirectory(root)", 1, true) ~= nil
        and src:find('"number,state,url,title,isDraft"', 1, true) ~= nil)
  check("l5pr-pin: annotated only for local tiles when enabled",
        src:find("if prOn and not it.remote and it.cwd", 1, true) ~= nil
        and src:find("it.pr = FX.prDataForRoot(proot)", 1, true) ~= nil)
  -- review fix: badge click reads the tile's data-key (NOT an interpolated key) so a
  -- cwd/key with a quote can't break out of the inline handler.
  check("l5pr-fix: badge click reads data-key (no key interpolation)",
        src:find('onclick="openPr(event)"', 1, true) ~= nil
        and src:find('tile.getAttribute("data-key")', 1, true) ~= nil)
  -- review fix: openPr depends on the .tile carrying an esc'd data-key -- pin the WRITE
  -- site (the tile render) so a markup refactor that drops/renames it fails here instead
  -- of silently breaking every badge click.
  check("l5pr-fix: tile render emits an esc'd data-key for badge clicks",
        src:find("data-key=\"'+esc(it.key)", 1, true) ~= nil)
  check("l5pr-pin: open-url validates scheme via pure core.isOpenableUrl",
        src:find("core.isOpenableUrl(url)", 1, true) ~= nil
        and src:find("hs.urlevent.openURL(url)", 1, true) ~= nil)
  check("l5pr-pin: Settings toggle populated + persisted",
        src:find('cv(cfg,"prStatus.enabled",false)', 1, true) ~= nil
        and src:find('prStatus: { enabled: ck("s-pr-en") }', 1, true) ~= nil)
  -- review fixes: gh re-detected if installed later; task retained (GC-safe); the
  -- per-root cache is reaped so it can't grow unbounded across many repos.
  check("l5pr-fix: ghBin re-checks the ABSENT case (TTL)",
        src:find("ghBinPath == false and (os.time() - ghBinAt) > 300", 1, true) ~= nil)
  check("l5pr-fix: gh task retained + timestamped until callback (GC-safe, hung-detectable)",
        src:find("prStatusTasks[root] = { task = t, ts = now }", 1, true) ~= nil
        and src:find("prStatusTasks[root] = nil", 1, true) ~= nil)
  -- review fix: the callback PAINTS only if this task still owns the slot, so a terminated
  -- (stale-killed/reaped) task's late SIGTERM callback can't clobber a fresh poll's data or
  -- re-populate a reaped root. Pin the specific guard (generic '= nil' matches 3 sites).
  check("l5pr-fix: callback drops its result if superseded (no clobber/re-populate)",
        src:find("if not core.prCallbackOwns(prStatusTasks[root], t) then return end", 1, true) ~= nil)
  -- the prune step is behavior-tested via core.reapUnbacked; keep a thin source pin on the
  -- LIVE-SET construction (which stays in the dashboard) + the reapUnbacked wiring, and on
  -- the vanished-root latch TERMINATE (else a hung task ref leaks for a root never re-examined).
  check("l5pr-fix: prStatusByRoot reaped (live-set built from local tiles' git roots)",
        src:find("core.reapUnbacked(prStatusByRoot, liveRoots)", 1, true) ~= nil
        and src:find("local r = FX.gitRoot(it.cwd)", 1, true) ~= nil
        and src:find("if r then liveRoots[r] = true end", 1, true) ~= nil)
  check("l5pr-fix: vanished-root in-flight poll latch is dropped + terminated",
        src:find("next(prStatusByRoot) or next(prStatusTasks)", 1, true) ~= nil
        and src:find("for r, inf in pairs(prStatusTasks) do", 1, true) ~= nil
        and src:find("inf.task:terminate()", 1, true) ~= nil)

  -- ===== #6 host stats + fleet idle-since (read-only, off by default) =====
  -- FX gather self-gates on the toggle + is throttled; ALL derivation is pure core.hostHealth.
  check("host-pin: FX.pollHostStats self-gates on insights.hostStats + throttles",
        src:find("function FX.pollHostStats(force, cfg)", 1, true) ~= nil
        and src:find('core.config(cfg, "insights.hostStats", false)', 1, true) ~= nil
        and src:find("(now - lastHostPoll) < HOST_TTL", 1, true) ~= nil)
  check("host-pin: gathers cpu/mem/disk/uptime/load from hs (each pcall-guarded, derived in core)",
        src:find("hs.host.cpuUsage()", 1, true) ~= nil
        and src:find("hs.host.vmStat()", 1, true) ~= nil
        and src:find("pagesUsedByVMCompressor", 1, true) ~= nil
        and src:find("df -kP / | tail -1", 1, true) ~= nil
        and src:find("kern.boottime", 1, true) ~= nil
        and src:find("lastHostHealth = core.hostHealth(raw,", 1, true) ~= nil)
  check("host-pin: polled once per refresh tick (reuses tick cfg, self-gating + throttled)",
        src:find("FX.pollHostStats(false, cfg)", 1, true) ~= nil)
  check("host-pin: insights handler routes the host attach through pure core.insightsHostAttach (off-omission behavior-tested)",
        src:find("core.insightsHostAttach(insCfg, lastHostHealth, core.fleetIdleSince(lastRenderList or {}, FX.now()))", 1, true) ~= nil
        and src:find("for k, v in pairs(core.insightsHostAttach(", 1, true) ~= nil)
  check("host-pin: insights panel renders the host strip + fleet idle line",
        src:find("var hh = st.host, fi = st.fleetIdle;", 1, true) ~= nil
        and src:find('hostHtml += \'<div class="i-sec">Host', 1, true) ~= nil
        and src:find("Fleet idle for ", 1, true) ~= nil)
  check("host-pin: Settings toggle loaded + persisted",
        src:find('ck("s-ins-host",   cv(cfg,"insights.hostStats",false))', 1, true) ~= nil
        and src:find('hostStats: ck("s-ins-host")', 1, true) ~= nil
        and src:find('id="s-ins-host"', 1, true) ~= nil)
  check("host-pin: starvation alert notes host pressure when present",
        src:find("lastHostHealth.pressured and lastHostHealth.pressure", 1, true) ~= nil
        and src:find("hostPressure = pressure", 1, true) ~= nil)

  -- ===== #7 session-history browser + bulk history management =====
  -- the uncapped read + aggregate + ccHistory push are single-sourced in FX.sendHistory so the
  -- tab and its post-delete refresh can't diverge (e.g. one site capping the read).
  check("hist-pin: open-history-view + FX.sendHistory aggregate the FULL (uncapped) ledger",
        src:find('a == "open-history-view"', 1, true) ~= nil
        and src:find("FX.sendHistory()", 1, true) ~= nil
        and src:find("function FX.sendHistory()", 1, true) ~= nil
        and src:find("core.sessionHistory(FX.readLedger({ limit = 0 }).events)", 1, true) ~= nil
        and src:find("window.ccHistory(", 1, true) ~= nil)
  check("hist-pin: bulk delete purges selected sessions through the scoped-purge path (+ confirm)",
        src:find('a == "history-delete"', 1, true) ~= nil
        and src:find("FX.purgeLedger({ sessions = sessions })", 1, true) ~= nil
        and src:find('hs.dialog.blockAlert("Delete session history"', 1, true) ~= nil)
  check("hist-pin: bulk delete no-ops on an empty selection (never escalates to delete-all)",
        src:find("if #sessions == 0 then return end", 1, true) ~= nil)
  check("hist-pin: bulk delete refreshes BOTH the History view (sendHistory) and the audit-rows cache",
        src:find("FX.sendHistory()", 1, true) ~= nil
        and src:find('window.ccAudit(" .. hs.json.encode(FX.readLedger({})) .. ")', 1, true) ~= nil)
  -- STRUCTURAL dedup pin (not just present-in-file): slice each handler body and assert it
  -- DELEGATES to FX.sendHistory() and never re-inlines the uncapped read / ccHistory push --
  -- the exact regression (one site capping `limit`) that a file-wide substring pin would miss.
  local function handlerSlice(marker, nextMarker)
    local s = src:find(marker, 1, true)
    local e = s and src:find(nextMarker, s, true)
    return (s and e) and src:sub(s, e - 1) or ""
  end
  local openHist = handlerSlice('a == "open-history-view"', 'a == "history-delete"')
  local delHist  = handlerSlice('a == "history-delete"', 'a == "storage-report"')
  check("hist-pin: open-history-view delegates to FX.sendHistory (no inlined read/push)",
        openHist ~= "" and openHist:find("FX.sendHistory()", 1, true) ~= nil
        and openHist:find("core.sessionHistory(", 1, true) == nil
        and openHist:find("window.ccHistory(", 1, true) == nil)
  check("hist-pin: history-delete refresh delegates to FX.sendHistory (no inlined read/push)",
        delHist ~= "" and delHist:find("FX.sendHistory()", 1, true) ~= nil
        and delHist:find("core.sessionHistory(", 1, true) == nil
        and delHist:find("window.ccHistory(", 1, true) == nil)
  check("hist-pin: the uncapped read lives ONLY in FX.sendHistory (single source, no divergence)",
        select(2, src:gsub("core%.sessionHistory%(FX%.readLedger", "")) == 1)
  check("hist-pin: History tab hidden when the ledger is off (parity with Shift)",
        src:find('htab = document.getElementById("a-tab-history"); if(htab) htab.style.display = LEDGER_ON', 1, true) ~= nil
        and src:find('(auditView === "shift" || auditView === "history")) auditTab("rows")', 1, true) ~= nil)
  check("hist-pin: storage report = core.localStorageReport over FX.storageEntries",
        src:find('a == "storage-report"', 1, true) ~= nil
        and src:find("core.localStorageReport(FX.storageEntries())", 1, true) ~= nil
        and src:find("function FX.storageEntries()", 1, true) ~= nil)
  -- the count/skip + cc-*.json decisions now live in pure core (behavior-tested: sumdir:* /
  -- matchstate:*); FX.storageEntries is a thin readDir+attributes adapter (nil-guarded).
  check("hist-pin: storageEntries measures Shepherd state via pure core helpers, NOT Claude transcripts",
        src:find('name = "Audit ledger"', 1, true) ~= nil
        and src:find('name = "Task queues"', 1, true) ~= nil
        and src:find("core.sumDirBytes(", 1, true) ~= nil
        and src:find("core.matchStateFiles(FX.readDir(claudeDir) or {})", 1, true) ~= nil)
  check("hist-pin: History tab wired (button + filter row + auditTab branch)",
        src:find('onclick="auditTab(\'history\')"', 1, true) ~= nil
        and src:find('id="h-filters"', 1, true) ~= nil
        and src:find("isHist = (v === \"history\")", 1, true) ~= nil
        and src:find("openHistory(); return;", 1, true) ~= nil)
  check("hist-pin: a normal audit open resets a stale History/Shift view to Rows",
        src:find('auditView === "shift" || auditView === "history"', 1, true) ~= nil)
  check("hist-pin: history rows use ESC'd data-pk/data-sid read back raw (no JS interpolation)",
        src:find('data-pk="\' + esc(r.projectKey || "")', 1, true) ~= nil
        and src:find('data-sid="\' + esc(r.session_id || "")', 1, true) ~= nil
        and src:find('row.getAttribute("data-pk")', 1, true) ~= nil
        and src:find('row.getAttribute("data-sid")', 1, true) ~= nil)
  check("hist-pin: pins persist by projectKey in localStorage; pinned/workspace facets + sort chips",
        src:find('window.localStorage.getItem("cc-historyPins"', 1, true) ~= nil
        and src:find("function historySortCmp(s)", 1, true) ~= nil
        and src:find('document.getElementById("h-fac-pin").checked', 1, true) ~= nil)
  check("hist-pin: Settings storage readout (button + ccStorage render)",
        src:find('id="s-storage"', 1, true) ~= nil
        and src:find("function measureStorage()", 1, true) ~= nil
        and src:find("window.ccStorage = function(rep)", 1, true) ~= nil)

  -- ===== QoL batch: panel restore, live model, configurable hotkeys, decisions hint =====
  check("qol-pin: panel toggle decides on REAL visibility (native-minimize-safe) + showPanel un-minimizes",
        src:find("local function panelIsOnScreen()", 1, true) ~= nil
        and src:find("if panelIsOnScreen() then hidePanel() else showPanel() end", 1, true) ~= nil
        and src:find("if w and w:isMinimized() then w:unminimize() end", 1, true) ~= nil
        and src:find('panelIsOnScreen() and "Hide panel" or "Show panel"', 1, true) ~= nil)
  check("qol-pin: live model from the transcript tail synced onto the tile for the Model dropdown",
        src:find("then it.model = st.lastModel; it.live_model = st.lastModel end", 1, true) ~= nil)
  check("qol-pin: global hotkeys resolved from cc-config via pure core.resolveHotkeys (legend + binds share it)",
        src:find("core.resolveHotkeys(readConfigEarly())", 1, true) ~= nil
        and src:find("_hk.approveFront", 1, true) ~= nil
        and src:find("_hk.toggle", 1, true) ~= nil)
  check("qol-pin: Decisions empty-state points at ledger+gate only when the ledger is OFF",
        src:find("box.innerHTML = LEDGER_ON", 1, true) ~= nil
        and src:find("and arm the gate to record allow/deny decisions", 1, true) ~= nil)

  -- Stream Deck: keys show the panel's name (relabel > auto-title > folder), and the deck is
  -- painted AFTER the per-tick label/auto-title decoration (not before, the original bug).
  check("sd-pin: deck key name precedence matches the tile (label || autoTitle || name)",
        src:find("local name = item.label or item.autoTitle or item.name", 1, true) ~= nil)
  check("sd-pin: deck rendered AFTER label/auto-title decoration (same list as the panel)",
        (function()
           local u = src:find("window.ccUpdate(", 1, true)
           local s = src:find("Paint the Stream Deck from the SAME fully-decorated", 1, true)
           return (u ~= nil) and (s ~= nil) and (s > u)
         end)())

  -- Stream Deck global action row (bottom-left): Jump / Approve / Spawn / Voice
  -- The left-row order is fed to core.deckReservations (which calls deckActionKeys internally;
  -- both are value-tested in core.test). Pin the order literal + that it's the order argument.
  check("sd-pin: action row order jump,approve,spawn,voice fed to core.deckReservations",
        src:find('SD_ACTION_ORDER = { "jump", "approve", "spawn", "voice" }', 1, true) ~= nil
        and src:find("sd.count, SD_ACTION_ORDER", 1, true) ~= nil)
  check("sd-pin: action keys get a custom button image; deckLayout skips the reserved slots",
        src:find("local function sdActionImage(spec, active)", 1, true) ~= nil
        and src:find("core.deckLayout(sd.count, list, reserved)", 1, true) ~= nil)
  check("sd-pin: Jump taps cycle (neediest seed -> cycleNext through all)",
        src:find("core.cycleNext(list, sd.jumpKey)", 1, true) ~= nil
        and src:find("core.nextAttention(list) or core.frontSession(list)", 1, true) ~= nil)
  check("sd-pin: Spawn reveals the panel + opens the New-session flow",
        src:find("local function sdSpawn()", 1, true) ~= nil
        and src:find("spawnPrompt()", 1, true) ~= nil)
  check("sd-pin: Voice records via ffmpeg avfoundation, whisper-cli transcribes, routes by focused window",
        src:find('"avfoundation"', 1, true) ~= nil
        and src:find('resolveBin("whisper-cli"', 1, true) ~= nil
        and src:find("core.sessionForTitle(list, fw", 1, true) ~= nil
        and src:find("FX.typeIntoWindow(target, text)", 1, true) ~= nil)

  -- Efficiency + safety pass
  -- The cap VALUE/clamp is pinned in core.test (voiceMaxSeconds); here we only pin the wiring:
  -- the cap is sourced from the helper and reaches ffmpeg's -t arg.
  check("sd-pin: Voice recorder has a hard -t cap + auto-resets REC when ffmpeg self-exits (anti-runaway)",
        src:find('"-t", tostring(maxSec)', 1, true) ~= nil
        and src:find("core.voiceMaxSeconds(cfg)", 1, true) ~= nil)
  check("sd-pin: deck repaints only keys whose content signature changed (per-tick diff)",
        src:find("if sd.sig[i] ~= sig then", 1, true) ~= nil)
  check("sd-pin: panel ccUpdate push skipped when the panel is hidden (panelVisible gate)",
        src:find("running JS into a hidden webview is wasted work", 1, true) ~= nil)
  check("sd-pin: 'Forget tile' drops the tile via removeStatus with NO window close (orphan-safe)",
        src:find('title = "Forget tile (no close)"', 1, true) ~= nil
        and src:find("FX.removeStatus(item.key)", 1, true) ~= nil)
  -- Bar presence + perSession fallback is glue (grep); the bucket math/clamp is pinned by VALUE
  -- in core.test (contextBucket) and wired here via core.contextBucket in the repaint signature.
  check("sd-pin: session keys draw a context-fill bar (it.context_frac, perSession fallback)",
        src:find("local cf = item.context_frac", 1, true) ~= nil
        and src:find("ps and ps.context_frac", 1, true) ~= nil
        and src:find("core.contextBucket(cf)", 1, true) ~= nil)
  -- The reservation geometry/free-slot logic (left row + caffeine + apptab tail) is value-tested
  -- in core.test (deckReservations); here we pin the wiring: the dashboard feeds the tail
  -- {caffeine, apptab} through it, and each action's handler does the right thing.
  check("sd-pin: caffeine keep-awake key reserved via deckReservations tail + cached state on sd.caffeine",
        src:find('{ "caffeine", "apptab" }', 1, true) ~= nil
        and src:find("local function sdCaffeine()", 1, true) ~= nil
        and src:find("FX.setCaffeinate(not (sd.caffeine == true))", 1, true) ~= nil)
  check("sd-pin: deck action reservations come from pure core.deckReservations (left row + tail)",
        src:find("core.deckReservations(sd.cols, sd.rows, sd.count, SD_ACTION_ORDER", 1, true) ~= nil)
  check("sd-pin: App Tab fires a real ⌘-Tab keystroke via its sdRunAction arm",
        src:find('hs.eventtap.keyStroke({ "cmd" }, "tab")', 1, true) ~= nil
        and src:find('elseif name == "apptab" then sdAppTab()', 1, true) ~= nil)

  -- ---- DR3: Rewind tab (Timeline folded in) + guarded /rewind ----------------
  -- The timeline detail tab was renamed to "rewind" (core.DETAIL_TABS); the panel
  -- folds the checkpoint list + the activity timeline under it.
  check("dr3-pin: DETAIL_TABS renamed timeline -> rewind (single source)",
        src:find('data%-tab="rewind"') ~= nil
        and src:find('data%-tab="timeline"') == nil)
  check("dr3-pin: Rewind tab folds in the activity timeline (#d-timeline retained)",
        src:find('id="d%-checkpoints"') ~= nil and src:find('id="d%-timeline"') ~= nil)
  check("dr3-pin: rewind lazy-load fetches BOTH checkpoints and the folded timeline",
        src:find('detailTab === "rewind"', 1, true) ~= nil
        and src:find('send("detail-rewind", selectedKey)', 1, true) ~= nil
        and src:find('send("detail-timeline", selectedKey)', 1, true) ~= nil)
  check("dr3-pin: checkpoints round-trip (handler -> core.checkpointTimeline -> ccCheckpoints)",
        src:find('a == "detail-rewind"', 1, true) ~= nil
        and src:find("core.checkpointTimeline(snap", 1, true) ~= nil
        and src:find("FX.attachCheckpointPrompts(path, points)", 1, true) ~= nil
        and src:find("window.ccCheckpoints(", 1, true) ~= nil)
  check("dr3-pin: snapshot/prompt scan is thin FX + on-demand (core.userPromptSnippet)",
        src:find("function FX.snapshotLines(path)", 1, true) ~= nil
        and src:find("function FX.attachCheckpointPrompts(path, points)", 1, true) ~= nil
        and src:find("core.userPromptSnippet(line, 160)", 1, true) ~= nil)
  -- the rewind ACTION is HARD-gated by a modal confirm (bash-changes caveat) and
  -- delivery-gated like every keystroke chain (a skip is never announced as sent).
  check("dr3-pin: /rewind behind a modal confirm with the bash-changes caveat",
        src:find('a == "rewind-open"', 1, true) ~= nil
        and src:find("Open the rewind picker?", 1, true) ~= nil
        and src:find("by bash are NOT undone", 1, true) ~= nil)
  check("dr3-pin: /rewind serialized + delivery-gated + ledgered only on a real send",
        src:find('FX.typeIntoWindow(winTarget(target), "/rewind")', 1, true) ~= nil
        and src:find('ledgerFor(target, { type = "rewind_open" })', 1, true) ~= nil)
  check("dr3-pin: checkpoint rows stale-guarded + ESC'd (no key interpolation)",
        src:find("CHECKPOINTS.key !== selectedKey", 1, true) ~= nil
        and src:find("esc(p.prompt", 1, true) ~= nil)

  -- ---- DR6: per-session model auto-routing (opt-in, off by default) -----------
  -- The model switch + the task feed are ONE atomic delivery via pasteIntoWindow's
  -- preface (so the pop/commit can't race a 2nd tick); the switch is local-native only
  -- and ledgered ONLY on a delivered feed.
  check("dr6-pin: feedTask carries an optional slash preface into one paste",
        src:find("function FX.feedTask(target, task, preface)", 1, true) ~= nil
        and src:find("text = task, preface = preface", 1, true) ~= nil)
  check("dr6-pin: pasteIntoWindow submits the preface then settles before the main text",
        src:find("local preface =", 1, true) ~= nil
        and src:find("after(0.5, function() runFrom(1) end)", 1, true) ~= nil)
  check("dr6-pin: autoModelPreface is local-native-only + classifies the rendered task",
        src:find("function FX.autoModelPreface(item, task)", 1, true) ~= nil
        and src:find("core.isAnthropicSession(item.model, item.base_url)", 1, true) ~= nil
        and src:find("core.suggestModel(typed, loadConfig())", 1, true) ~= nil)  -- R1-32: rendered, not bare template
  -- all THREE feed sites (manual / autofeed / router) consult it + ledger on delivery
  do
    local n = 0; for _ in src:gmatch("= FX%.autoModelPreface%(") do n = n + 1 end  -- call sites, not the def
    check("dr6-pin: all 3 feed sites consult autoModelPreface", n == 3)
    local m = 0; for _ in src:gmatch('type = "model_change", from = pre%.from') do m = m + 1 end
    check("dr6-pin: model_change ledgered (by=auto) at all 3 sites, gated on commit.persist", m == 3)
  end
  check("dr6-pin: per-session opt-in file (presence=on), off by default, NEVER fleet-wide",
        src:find("function FX.autoModelOn(key)", 1, true) ~= nil
        and src:find("function FX.setAutoModel(key, on)", 1, true) ~= nil
        and src:find('a == "set-automodel"', 1, true) ~= nil)
  check("dr6-pin: set-automodel rejects remote/gateway sessions",
        src:find("it.remote or not core.isAnthropicSession(it.model, it.base_url)", 1, true) ~= nil)
  -- R1-31: the gate must ALSO exclude kitty/terminal (the effect no-ops for them) at
  -- all 3 opt-in sites, so the checkbox can't advertise a setting the delivery ignores.
  check("r1-31-pin: set-automodel rejects kitty/terminal too",
        src:find('it.editor == "kitty" or it.editor == "terminal") then', 1, true) ~= nil)
  check("dr6-pin: detail toggle wired + gated to local-native (checkbox disabled otherwise)",
        src:find('id="d-automodel"', 1, true) ~= nil
        and src:find("function onAutoModelChange()", 1, true) ~= nil
        and src:find("var ok = !it.remote && !!it.anthropic && it.editor !== 'kitty' && it.editor !== 'terminal';", 1, true) ~= nil)
  check("dr6-pin: per-tile auto_model/anthropic decoration is local-native short-circuited",
        src:find("it.anthropic = core.isAnthropicSession(it.model, it.base_url)", 1, true) ~= nil
        and src:find('it.auto_model = (not it.remote) and it.anthropic and it.editor ~= "kitty" and it.editor ~= "terminal"', 1, true) ~= nil)
  -- review fixes (round 1):
  check("dr6-fix: auto-routing restricted to chat-input editors (kitty/terminal skipped)",
        src:find('item.editor == "kitty" or item.editor == "terminal" then return nil', 1, true) ~= nil)
  -- R1-32: classify on the RENDERED (template-expanded) text, not the raw template.
  check("r1-32-pin: autoModelPreface classifies the rendered feed text",
        src:find("local typed = renderFeed(task, item)", 1, true) ~= nil
        and src:find("local s = core.suggestModel(typed, loadConfig())", 1, true) ~= nil)
  check("dr6-fix: same-tier skip is nil-family-safe (no nil==nil wrong-skip)",
        src:find("if (sf and cf == sf) or cur == s.model then return nil end", 1, true) ~= nil)
  -- R3-03: the no-op check compares against the LIVE model (live_model from the transcript
  -- tail), not the stale spawn-time snapshot that refreshList reverts within 1s.
  check("r3-03-pin: autoModelPreface compares against the live model",
        src:find("local cur = item.live_model or item.model", 1, true) ~= nil)
  check("r3-03-pin: delivered/manual model switch persisted via patchStatus(model)",
        src:find("FX.patchStatus(item.key, { model = pre.model })", 1, true) ~= nil
        and src:find("FX.patchStatus(item.key, { model = item.model })", 1, true) ~= nil)
  check("dr6-fix: kitty preface concatenated into ONE send-text (ordered, no socket race)",
        src:find("function dispatchSerialized(item, action, fn, extraStagger)", 1, true) ~= nil
        and src:find("BULK_STAGGER + (tonumber(extraStagger) or 0)", 1, true) ~= nil)
  do
    local n = 0; for _ in src:gmatch("item%.auto_model and 0%.8 or 0") do n = n + 1 end
    local m = 0; for _ in src:gmatch("it%.auto_model and 0%.8 or 0") do m = m + 1 end
    check("dr6-fix: all 3 feed sites reserve extra stagger for the preface ladder", (n + m) == 3)
  end

  -- ---- DR7: A/B fork-to-compare (panel flow, worktree isolation) --------------
  -- A/B is now a PER-PROJECT action (tile right-click menu), not a global header button.
  check("dr7-pin: A/B modal + open-ab bridge still wired",
        src:find('id="abmodal"', 1, true) ~= nil
        and src:find('a == "open-ab"', 1, true) ~= nil)
  check("abproj-pin: the global header A/B button is GONE",
        src:find('id="b-ab"', 1, true) == nil
        and src:find('onclick="openAb()"', 1, true) == nil)
  check("abproj-pin: A/B lives in the tile right-click context menu, scoped to its folder",
        src:find("A/B fork-to-compare", 1, true) ~= nil
        and src:find('openAb(" .. jsString(item.cwd or "")', 1, true) ~= nil)
  check("abproj-pin: openAb(repo) pre-fills the (still-editable) repo field",
        src:find("function openAb(repo){ AB_PREFILL", 1, true) ~= nil
        and src:find('rp.value = AB_PREFILL', 1, true) ~= nil)
  check("dr7-pin: launch creates a worktree per variant then spawns into it (cold-start)",
        src:find("function FX.abLaunch(spec)", 1, true) ~= nil
        and src:find("core.abCohortPlan(spec)", 1, true) ~= nil
        and src:find("core.gitWorktreeAddCmd(plan.repoRoot", 1, true) ~= nil
        and src:find('FX.spawnSession("vscode", v.worktreePath, v.task, spec.mode, v.provider or "", nil, true, v.model)', 1, true) ~= nil)
  check("dr7-pin: launch rolls back created worktrees + branches on a failed add",
        src:find("core.gitWorktreeRemoveCmd(plan.repoRoot, c.path)", 1, true) ~= nil
        and src:find("core.gitBranchDeleteCmd(plan.repoRoot, c.branch)", 1, true) ~= nil
        and src:find("FX.gitRoot(plan.repoRoot)", 1, true) ~= nil)
  check("dr7-pin: a raw per-variant model rides ANTHROPIC_MODEL (no provider needed)",
        src:find('{ name = "ANTHROPIC_MODEL", value = modelOverride, secret = false }', 1, true) ~= nil)
  check("dr7-pin: keep-winner closes losers + removes their worktrees, behind a confirm",
        src:find("function FX.abKeep(cohort, winnerLabel)", 1, true) ~= nil
        and src:find("core.gitWorktreeRemoveCmd(c.repoRoot, v.worktreePath)", 1, true) ~= nil
        and src:find('hs.dialog.blockAlert("Keep \\"" .. tostring(req.winner)', 1, true) ~= nil)
  check("dr7-pin: compare uses DR4 runScore + core.abCompare for the winner",
        src:find("core.runScore(led.events, sid)", 1, true) ~= nil
        and src:find("core.abCompare(c.variants, scores)", 1, true) ~= nil)
  check("dr7-pin: optional LLM-judge pastes core.abJudgePrompt, delivery-gated",
        src:find("function FX.abJudge(cohort)", 1, true) ~= nil
        and src:find("core.abJudgePrompt(c.task, entries)", 1, true) ~= nil
        and src:find('FX.pasteIntoWindow(winTarget(firstTile)', 1, true) ~= nil)
  check("dr7-pin: cohort keys read RAW from esc'd data- attrs (no JS-string interpolation)",
        src:find("function keepAbBtn(el)", 1, true) ~= nil
        and src:find('data-cohort="\'+esc(c.cohort)+\'"', 1, true) ~= nil
        and src:find("el.getAttribute(\"data-cohort\")", 1, true) ~= nil)
end

-- ---- Appearance: token layer + injection + tabbed settings -----------------
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end

  check("appearance: :root declares the token defaults (tokenized stylesheet)",
        src:find("--bg:#15161b", 1, true) ~= nil and src:find("--surface:#21232c", 1, true) ~= nil
        and src:find("--accent:#6ea8fe", 1, true) ~= nil and src:find("--st-working:#f5b50a", 1, true) ~= nil)
  check("appearance: stylesheet references tokens, not raw palette literals (var(--border) used widely)",
        select(2, src:gsub("var%(%-%-border%)", "")) > 50)
  check("appearance: second <style> consumes the injected __APPEARANCE_CSS__",
        src:find('id="appearance-root">__APPEARANCE_CSS__', 1, true) ~= nil)
  check("appearance: Lua injects core.appearanceCss into __APPEARANCE_CSS__ (wrapped in do/end for the 200-local cap)",
        src:find("core.appearanceCss(ap)", 1, true) ~= nil
        and src:find('HTML = HTML:gsub("__APPEARANCE_CSS__"', 1, true) ~= nil)
  check("appearance: body carries look + density init from the resolved appearance",
        src:find('data%-look="__INIT_LOOK__"') ~= nil and src:find("__INIT_DENSITY__", 1, true) ~= nil
        and src:find('HTML = HTML:gsub("__INIT_LOOK__"', 1, true) ~= nil)
  check("appearance: status colors single-sourced (JS COLORS == --st-* tokens, no hex twin)",
        src:find('working:"var(--st-working)"', 1, true) ~= nil
        and src:find(".s%-working%s*{%s*%-%-c:var%(%-%-st%-working%)") ~= nil)
  check("appearance: themes/defaults/vars injected for the live-preview twin",
        src:find("var APPEARANCE = __APPEARANCE_THEMES__", 1, true) ~= nil
        and src:find('HTML = HTML:gsub("__APPEARANCE_THEMES__"', 1, true) ~= nil)
  -- Grouped theme picker: the ordered groups are injected (single-sourced from
  -- core.APPEARANCE_THEME_GROUPS) and the renderer walks them + sweeps un-grouped keys.
  check("appearance: theme groups injected alongside themes",
        src:find("groups = core.APPEARANCE_THEME_GROUPS", 1, true) ~= nil)
  check("appearance: renderThemeChips walks APPEARANCE.groups (ordered headers, not hash order)",
        src:find("groups=(APPEARANCE.groups||[])", 1, true) ~= nil
        and src:find("groups.forEach(function(g){ section(", 1, true) ~= nil)
  check("appearance: un-grouped theme keys swept into a trailing More section",
        src:find("var leftover=Object.keys(APPEARANCE.themes).filter", 1, true) ~= nil
        and src:find('section("More", leftover)', 1, true) ~= nil)
  check("appearance: applyAppearance twin merges defaults<-theme<-overrides like resolveAppearance",
        src:find("function applyAppearance(ap)", 1, true) ~= nil
        and src:find("function resolveAp(ap)", 1, true) ~= nil
        and src:find("root.style.setProperty(cssv, v)", 1, true) ~= nil)
  check("appearance: form round-trips through persistSettings (appearance: readApForm())",
        src:find("appearance: readApForm()", 1, true) ~= nil)
  check("appearance: Cancel reverts live preview to the saved appearance",
        src:find("function closeSettings(){ applyAppearance(apSaved)", 1, true) ~= nil
        and src:find("apSaved = readApForm()", 1, true) ~= nil)
  check("appearance: settings tabs built + section-tagged; openSettings lands on a tab",
        src:find("function tagSettingsTabs()", 1, true) ~= nil
        and src:find("function settingsTabFor(t)", 1, true) ~= nil
        and src:find('settingsTab("general")', 1, true) ~= nil)
  check("appearance: layout chip uses the existing onThemeChange (hs.settings) path",
        src:find("function pickLayout(l)", 1, true) ~= nil and src:find("onThemeChange();", 1, true) ~= nil)
  -- R1-28: onThemeChange swaps only the layout token (regex replace), never clobbers
  -- the whole class list (which would drop dense/calm/worklist-mode). R1-29: it keeps
  -- body data-theme in lockstep so the Appearance chip detection stays accurate.
  check("r1-28-pin: onThemeChange swaps only the theme-* token (no className clobber)",
        src:find('b.className.replace(/(^|\\s)theme-\\S+/g, "").trim()', 1, true) ~= nil
        and src:find('b.classList.add("theme-" + t)', 1, true) ~= nil)
  check("r1-28-pin: no whole-className clobber remains in onThemeChange",
        src:find('document.body.className = "theme-" + t;', 1, true) == nil)
  check("r1-29-pin: onThemeChange keeps body data-theme in sync",
        src:find('b.setAttribute("data-theme", t)', 1, true) ~= nil)
  -- R1-30 / R3-13: apClamp rejects non-pure-DECIMAL strings (matching the Lua
  -- appearanceClamp regex, which has NO exponential [eE] alternative), so the live preview
  -- agrees with the SSR CSS on a garbage-suffix OR exponential appearance value.
  check("r1-30-pin: apClamp uses a pure-decimal regex guard (tonumber parity)",
        src:find("/^\\s*[-+]?(\\d+\\.?\\d*|\\.\\d+)\\s*$/.test(v)", 1, true) ~= nil)
  check("r3-13-pin: apClamp regex has NO exponential [eE] group (Lua-twin parity)",
        src:find("([eE][-+]?\\d+)?", 1, true) == nil)
  check("appearance: look shape rules keyed off body[data-look]",
        src:find('body%[data%-look="flat"%] %.theme%-cards %.tile') ~= nil
        and src:find('body%[data%-look="slate"%] %.theme%-cards %.tile') ~= nil)
  check("appearance b2: font token applied + selector wired to APPEARANCE.fonts",
        src:find("font-family:var(--font)", 1, true) ~= nil
        and src:find('id="a-font"', 1, true) ~= nil and src:find("APPEARANCE.fonts", 1, true) ~= nil)
  check("appearance b2: reduce-motion body.calm rule + toggle",
        src:find("body.calm *", 1, true) ~= nil and src:find('id="a-motion"', 1, true) ~= nil
        and src:find('classList.toggle("calm"', 1, true) ~= nil)
  check("appearance b2: accent quick-swatches (dedicated, not gated by the custom palette)",
        src:find("function renderAccentSwatches(active)", 1, true) ~= nil
        and src:find("function pickAccent(hex)", 1, true) ~= nil and src:find('id="a-accent-sw"', 1, true) ~= nil)
  -- Review: the live-preview twin must iterate the INJECTED APPEARANCE.vars (== core.APPEARANCE_VARS),
  -- NOT a hand-written copy -- so the token list can't drift between the SSR appearanceCss and JS.
  check("appearance b2: live-preview iterates the injected APPEARANCE.vars (single-sourced, no twin list)",
        src:find("(APPEARANCE.vars||[]).forEach", 1, true) ~= nil
        and src:find("vars = core.APPEARANCE_VARS", 1, true) ~= nil)
end

-- ---- F7: cost analytics (durable snapshots + Cost overlay) ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("f7-pin: snapshot writer gated + emits usage_snapshot",
        src:find("function FX.writeUsageSnapshots()", 1, true) ~= nil
        and src:find('type = "usage_snapshot"', 1, true) ~= nil)
  check("f7-pin: snapshots fire from the usage timer path",
        src:find("pcall(FX.writeUsageSnapshots)", 1, true) ~= nil)
  check("f7-pin: open-cost-view aggregates via costSummary + costSeries",
        src:find("core.costSummary(res.events)", 1, true) ~= nil and src:find("core.costSeries(res.events", 1, true) ~= nil)
  check("f7-pin: cost overlay + opener + menu entry + chart receiver",
        src:find('id="cost"', 1, true) ~= nil and src:find("function openCost()", 1, true) ~= nil
        and src:find("menuPick('cost')", 1, true) ~= nil and src:find("window.ccCost = function", 1, true) ~= nil)
  check("f7-pin: cost values esc()'d into the overlay", src:find("esc(fmtUsd(s.usd))", 1, true) ~= nil)
end

-- ---- F6 + F9: Diagnostics + Features overlays (☰ menu) ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("f6-pin: FX.doctorStatus gathers facts -> core.doctorChecks",
        src:find("function FX.doctorStatus()", 1, true) ~= nil and src:find("core.doctorChecks({", 1, true) ~= nil)
  check("f6-pin: open-doctor-view handler pushes ccDoctor",
        src:find('a == "open-doctor-view"', 1, true) ~= nil and src:find("window.ccDoctor(", 1, true) ~= nil)
  check("f6-pin: doctor overlay + opener + menu entry",
        src:find('id="doctor"', 1, true) ~= nil and src:find("function openDoctor()", 1, true) ~= nil
        and src:find("menuPick('doctor')", 1, true) ~= nil)
  check("f9-pin: open-features-view handler pushes core.FEATURES",
        src:find('a == "open-features-view"', 1, true) ~= nil and src:find("hs.json.encode(core.FEATURES)", 1, true) ~= nil)
  check("f9-pin: features overlay + opener + menu entry",
        src:find('id="features"', 1, true) ~= nil and src:find("function openFeatures()", 1, true) ~= nil
        and src:find("menuPick('features')", 1, true) ~= nil)
  check("f9-pin: features rows render what + why, esc()'d",
        src:find("window.ccFeatures = function", 1, true) ~= nil and src:find("esc(f.why", 1, true) ~= nil)
  check("f9-pin: features grouped under category headers",
        src:find("feat-cat", 1, true) ~= nil and src:find("f.cat !== curCat", 1, true) ~= nil)
end

-- ---- Background-aware status + Agents-tab workflow grouping ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  -- A done/idle session with live background agents must NOT read as "Ready for you".
  check("bg-status: background-aware status helpers defined",
        src:find("function bgRunning(it)", 1, true) ~= nil
        and src:find("function effStatus(it)", 1, true) ~= nil
        and src:find("function statusWords(it)", 1, true) ~= nil)
  check("bg-status: override only fires for done/idle (real status untouched)",
        src:find('it.bg_active && (it.status === "done" || it.status === "idle")', 1, true) ~= nil)
  check("bg-status: running label counts the background agents",
        src:find('"Running " + n + " agent"', 1, true) ~= nil)
  check("bg-status: tile dot + words route through the helpers",
        src:find("var est = effStatus(it)", 1, true) ~= nil
        and src:find("var label = esc(statusWords(it))", 1, true) ~= nil)
  check("bg-status: detail header dot + words route through the helpers",
        src:find("COLORS[est]", 1, true) ~= nil
        and src:find("statusWords(it) + (it.since", 1, true) ~= nil)
  check("bg-status: stale suffix/dimming suppressed while background-running",
        src:find("it.stale && !bgRunning(it)", 1, true) ~= nil)
  -- Agents tab groups the Workflow fan-out under one header with a running/total rollup.
  check("agents-tab: subagent rows grouped by workflow",
        src:find("sa-grp", 1, true) ~= nil and src:find("byG[gid]", 1, true) ~= nil)
  check("agents-tab: workflow group header shows a running/total rollup",
        src:find("runN + ' running'", 1, true) ~= nil
        and src:find("grp.agents.length + ' agent'", 1, true) ~= nil)
end

-- ---- Worklist: click an item to open it in the add/edit modal ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("wl-edit: backend handles the worklist-edit action",
        src:find('a == "worklist-edit"', 1, true) ~= nil
        and src:find("core.worklistEdit(st, scope", 1, true) ~= nil)
  check("wl-edit: edit posts scope+id+subject+details+due",
        src:find('a:"worklist-edit", v:worklistScope, text:id, edit:subj, details:details, due:due', 1, true) ~= nil)
  check("wl-edit: clicking a row opens the item modal",
        src:find("function wlModalOpen(", 1, true) ~= nil
        and src:find('t.closest(".wl-item")', 1, true) ~= nil
        and src:find("if(rid) wlModalOpen(rid)", 1, true) ~= nil)
  check("wl-edit: row click ignores the checkbox + delete control",
        src:find('t.classList.contains("wl-cb") || t.classList.contains("wl-del")', 1, true) ~= nil)
  check("wl-edit: modal saves a non-empty subject, Esc/backdrop discard",
        src:find("function wlModalSave(", 1, true) ~= nil
        and src:find('if(e.key === "Escape" && wlModalOpenNow()) wlModalClose();', 1, true) ~= nil
        and src:find('e.target.id === "wl-modal"', 1, true) ~= nil)
  check("wl-edit: the inline dblclick editor is gone (modal is the only editor)",
        src:find("function startWorklistEdit(", 1, true) == nil
        and src:find("worklistEditSend(id, nt)", 1, true) == nil)
end

-- ---- User Stories tab (spec/product/user-stories.md viewer/editor) ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("stories: HTML panel exists",
        src:find('data-tab="stories"', 1, true) ~= nil and src:find('id="d-stories"', 1, true) ~= nil)
  check("stories: backend load + save handlers",
        src:find('a == "detail-stories"', 1, true) ~= nil and src:find('a == "stories-save"', 1, true) ~= nil)
  check("stories: load reads the FIXED project path + parses via core",
        src:find('"/spec/product/user-stories.md"', 1, true) ~= nil
        and src:find("core.parseUserStories(content)", 1, true) ~= nil)
  -- The save GUARDS (missing/changed/bad-payload/empty-refused + serialize) are pure in
  -- core.storiesSaveDecision and tested behaviorally in core.test.lua; here we only pin
  -- that the handler delegates to it and writes atomically (the IO it still owns).
  check("stories: handler delegates the guards to core.storiesSaveDecision",
        src:find("core.storiesSaveDecision(current,", 1, true) ~= nil)
  check("stories: handler writes the decided text atomically",
        src:find("FX.writeFileAtomic(path, dec.text)", 1, true) ~= nil)
  check("stories: tab gated on per-item has_user_stories (bar + selection fallback)",
        src:find('t.id === "stories" && !itemHasStories(selectedKey)', 1, true) ~= nil
        and src:find('detailTab === "stories" && !itemHasStories(key)', 1, true) ~= nil)
  check("stories: per-item flag set from a cheap stat in refresh",
        src:find('it.has_user_stories = FX.fileExists(it.cwd .. "/spec/product/user-stories.md")', 1, true) ~= nil)
  check("stories: lazy-loads on tab activation (not the 1Hz tick)",
        src:find('send("detail-stories", selectedKey)', 1, true) ~= nil)
  check("stories: staged add/edit/delete/save JS present",
        src:find("function renderStories(", 1, true) ~= nil
        and src:find("function storiesAdd(", 1, true) ~= nil
        and src:find("function storiesCommitEdit(", 1, true) ~= nil
        and src:find("function storiesDelete(", 1, true) ~= nil
        and src:find("function storiesSave(", 1, true) ~= nil)
  check("stories: double-click a row edits; +Add / ✕ delete wired",
        src:find('t.closest(".us-row")', 1, true) ~= nil
        and src:find('t.closest(".us-add")', 1, true) ~= nil
        and src:find('t.closest(".us-del")', 1, true) ~= nil)
  check("stories: Save disabled until dirty; soft so-that hint twin",
        src:find("STORIES.dirty ? '' : ' disabled'", 1, true) ~= nil
        and src:find("function storyWellFormed(", 1, true) ~= nil)
  check("stories: no doubled-bracket in the embedded JS (would close the Lua [[ string)",
        src:find("groups[byArea[a]].items", 1, true) == nil)
  check("stories: add placement matches the heading area EXACTLY (not substring)",
        src:find("b[i].headingArea === area", 1, true) ~= nil
        and src:find('String(b[i].raw).indexOf("## "', 1, true) == nil)
  check("stories: gated tab appears/disappears mid-session when the file flips",
        src:find("lastSelectedHasStories", 1, true) ~= nil
        and src:find('detailTab === "stories" && !hs', 1, true) ~= nil)
  check("stories: empty-refused save shows a human-readable reason (not a raw token)",
        src:find('er === "empty-refused"', 1, true) ~= nil)
end

-- ---- F4: transcript peek detail tab ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("f4-pin: transcript tab registered in DETAIL_TABS", core.detailTabIds().transcript == true)
  check("f4-pin: handler reads a bounded tail via core.transcriptPeek",
        src:find("core.transcriptPeek(FX.readTail", 1, true) ~= nil)
  check("f4-pin: ccTranscript receiver + renderTranscript",
        src:find("window.ccTranscript = function", 1, true) ~= nil
        and src:find("function renderTranscript()", 1, true) ~= nil)
  check("f4-pin: client-side search filters rows",
        src:find("d-tr-search", 1, true) ~= nil and src:find("txt.toLowerCase().indexOf(q)", 1, true) ~= nil)
  check("f4-pin: rows are esc()'d (XSS-safe sink)", src:find("esc(txt)", 1, true) ~= nil)
  check("f4-pin: lazy-load on tab activation only",
        src:find('send("detail-transcript", selectedKey)', 1, true) ~= nil)
end

-- ---- F3: visual theme editor (all-token pickers + export / import) ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("f3-pin: advanced all-color editor generated from APPEARANCE.vars (single-sourced)",
        src:find("function renderAllColors()", 1, true) ~= nil)
  check("f3-pin: readApForm reads advanced colors into ap.colors",
        src:find('apG("a-all-on") && apG("a-all-on").checked', 1, true) ~= nil)
  check("f3-pin: export builds theme JSON from the resolved palette",
        src:find("function exportThemeUI()", 1, true) ~= nil)
  check("f3-pin: import validates each color via apIsHex before applying",
        src:find("function importThemeUI()", 1, true) ~= nil
        and src:find("apIsHex(colors[k])", 1, true) ~= nil)
  check("f3-pin: populate opens the advanced editor when extra tokens are overridden",
        src:find("basic5", 1, true) ~= nil)
  check("f3-pin: HTML carries the advanced toggle + theme-file IO",
        src:find('id="a-all-on"', 1, true) ~= nil and src:find('id="a-theme-io"', 1, true) ~= nil)
end

-- ---- F8: incremental render (skip the full grid rebuild when nothing changed) ----
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("f8-pin: JS tileSignature twin defined", src:find("function tileSignature(v)", 1, true) ~= nil)
  check("f8-pin: JS gridSignature twin defined", src:find("function gridSignature(list)", 1, true) ~= nil)
  check("f8-pin: tileSignature sorts keys (canonical, encoder-order-independent)",
        src:find("Object.keys(v).sort()", 1, true) ~= nil)
  check("f8-pin: renderGrid computes the grid signature", src:find("var sig = gridSignature(vis)", 1, true) ~= nil)
  check("f8-pin: renderGrid rebuilds ONLY on signature change",
        src:find("if(sig !== lastGridSig){", 1, true) ~= nil)
  check("f8-pin: lastGridSig cache reset on empty/filtered-empty",
        select(2, src:gsub("lastGridSig = null", "")) >= 2)
  check("f8-pin: updateAges refreshes only the churning .age text",
        src:find("function updateAges(vis)", 1, true) ~= nil
        and src:find('querySelector(".age")', 1, true) ~= nil)
  check("f8-pin: updateAges uses fmtAge (same age fn as tileHtml)",
        src:find("fmtAge(vis[i].since)", 1, true) ~= nil)
  check("f8-pin: selection still handled separately (not in the signature)",
        src:find("function paintSelection()", 1, true) ~= nil)
end

-- =============================================================================
-- Regression pins for the 2026-07 fix batch (dashboard half). The fixed logic
-- lives in claude-dashboard.lua's refresh loop / FX layer, which has no headless
-- runtime in this suite (same rationale as the Panel-JS tripwires above), so the
-- load-bearing expressions are pinned at the source level; the pure halves are
-- unit-tested in core.test.lua. Reformatting these lines can false-alarm; if one
-- trips after a refactor, re-verify the BEHAVIOR it names before appeasing it.
-- =============================================================================
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("regr-pin: dashboard source readable", #src > 0)

  -- #2: the stale-'done' self-heal is LATCHED (FX._healedDone) so a tick with no
  -- observable tail (display-stale skip / transient readTail failure) carries the
  -- healed 'working' instead of snapping back to the raw-file 'done' -- the
  -- pure-artifact working->done edge fired drain-close/autofeed/banners/rules
  -- into a mid-turn session.
  check("#2-pin: heal latch lives on FX (200-local cap)",
        src:find("FX._healedDone = {}", 1, true) ~= nil)
  check("#2-pin: heal records the frozen updated it healed against",
        src:find("FX._healedDone[it.key] = it.updated", 1, true) ~= nil)
  check("#2-pin: no-tail tick carries the heal (latch consulted)",
        src:find("elseif tail == nil and FX._healedDone[it.key] ~= nil", 1, true) ~= nil
        and src:find("FX._healedDone[it.key] == it.updated", 1, true) ~= nil)
  check("#2-pin: a real hook write (new updated/status) drops the latch",
        src:find("FX._healedDone[it.key] = nil", 1, true) ~= nil)
  check("#2-pin: latch reaped with the other per-key state",
        src:find("core.reapUnbacked(FX._healedDone, newPrev)", 1, true) ~= nil)

  -- stale-approval heal: a TOOL-scoped approval whose transcript is not awaiting a tool
  -- is stale (the native-prompt guard never got its resolution event) -> heal to working.
  -- Gated on it.pending.tool (a bare-notification approval is never hidden), decided by
  -- the pure+tested core.transcriptAwaitingTool, and latched like the done heal.
  check("appheal-pin: latch on FX (200-local cap) + reaped",
        src:find("FX._healedApproval = {}", 1, true) ~= nil
        and src:find("core.reapUnbacked(FX._healedApproval, newPrev)", 1, true) ~= nil)
  check("appheal-pin: only a tool-scoped approval is eligible (bare notification kept)",
        src:find('it.status == "approval" and type(it.pending) == "table" and it.pending.tool', 1, true) ~= nil)
  check("appheal-pin: decision delegated to pure core.approvalHealable(it, awaiting, progressed)",
        src:find("core.approvalHealable(it, awaiting, progressed)", 1, true) ~= nil
        and src:find("awaiting = core.transcriptAwaitingTool(tail)", 1, true) ~= nil
        and src:find("FX._healedApproval[it.key] = it.updated", 1, true) ~= nil)
  -- The VS Code fix: heal also requires the transcript to have advanced past the arm time
  -- (it.since) -- a live VS Code prompt writes no dangling tool_use, so awaiting alone is blind.
  check("appheal-pin: progressed = transcriptResumed(tail, it.since) gates the heal",
        src:find("progressed = core.transcriptResumed(tail, it.since", 1, true) ~= nil)
  -- The latch carries a prior heal on a no-tail tick AND on a read tick where progressed
  -- transiently dips (awaiting ~= true, so a real dangling tool_use still forces re-eval).
  check("appheal-pin: latch carries the heal (no-tail OR transient progressed dip)",
        src:find("elseif awaiting ~= true and FX._healedApproval[it.key] ~= nil", 1, true) ~= nil
        and src:find("FX._healedApproval[it.key] == it.updated", 1, true) ~= nil)

  -- #4: per-task timing abandons taskStart only past the RESPAWN death threshold
  -- (autoRespawnStale, default 600s), not the 90s display staleness -- a healthy
  -- session running one long build/test goes display-stale mid-task and its
  -- task_done record was silently lost.
  check("#4-pin: abandon keyed to the respawn death threshold",
        src:find("if it.updated ~= nil and (now - it.updated) > autoRespawnStale then", 1, true) ~= nil)
  check("#4-pin: abandon comment names the death threshold",
        src:find("taskStart[it.key] = nil  -- abandon: frozen past the death threshold", 1, true) ~= nil)
  check("#4-pin: the old display-staleness abandon is gone",
        src:find("abandon: a frozen session's in-flight task can't be timed", 1, true) == nil)

  -- #5: voice dictation adapts the raw status item via winTarget (the kitty path
  -- reads camelCase kittyWindowId/kittyListenOn; the raw snake_case item nil'd
  -- both and fell back to the socketless cwd: probe), and the success alert is
  -- delivery-gated instead of unconditional.
  do
    local p = src:find('dispatchSerialized(target, "voice", function()', 1, true)
    check("#5-pin: voice dispatch found", p ~= nil)
    local w = p and src:sub(p, p + 600) or ""
    check("#5-pin: voice types via winTarget(target)",
          w:find("FX.typeIntoWindow(winTarget(target), text)", 1, true) ~= nil)
    check("#5-pin: voice alert is delivery-gated (skip reports NOT sent)",
          w:find("text NOT sent", 1, true) ~= nil)
  end

  -- #6/#27: every nudge path re-checks the LIVE status at FIRE time
  -- (FX.nudgeSafeNow, the router's R2-20 idiom) -- a stagger-delayed nudge's
  -- Return must never answer an approval prompt that appeared meanwhile.
  check("#6-pin: FX.nudgeSafeNow defined",
        src:find("function FX.nudgeSafeNow(it)", 1, true) ~= nil)
  check("#6-pin: nudgeSafeNow re-reads the live status file",
        src:find("local fresh = it and FX.liveStatusFor(it.key) or nil", 1, true) ~= nil)
  check("#6-pin: bulk-nudge slot re-checks at fire time",
        src:find("if action == \"nudge\" and not FX.nudgeSafeNow(it) then", 1, true) ~= nil)
  check("#27-pin: per-tile dispatch re-checks at fire time",
        src:find("if a == \"nudge\" and not FX.nudgeSafeNow(item) then", 1, true) ~= nil)
  check("#27-pin: per-tile skip is ledgered",
        src:find('type = "nudge_skipped", reason = "approval"', 1, true) ~= nil)
  check("#27-pin: rule-nudge slot re-checks at fire time",
        src:find("if not FX.nudgeSafeNow(target) then", 1, true) ~= nil)
  check("#27-pin: rule-nudge skip is ledgered as processor=nudge_skipped",
        src:find('processor = "nudge_skipped", reason = "approval"', 1, true) ~= nil)

  -- #9: ledgerSnapshot's one-shot `changed` edge is latched (ledgerCache.dirty)
  -- so non-refresh callers (decision log, shift report, digest, per-tile banner)
  -- can no longer eat it and starve the 🔔 badge / lineage recomputes; only
  -- refresh() consumes.
  check("#9-pin: ledgerSnapshot takes a consume flag",
        src:find("function ledgerSnapshot(consume)", 1, true) ~= nil)
  check("#9-pin: a non-consuming re-read latches dirty",
        src:find("ledgerCache.dirty = not consume", 1, true) ~= nil)
  check("#9-pin: consume drains the latch on a cache hit",
        src:find("if consume and ledgerCache.dirty then", 1, true) ~= nil)
  eq("#9-pin: exactly ONE consuming call site (refresh)",
     select(2, src:gsub("ledgerSnapshot%(true%)", "")), 1)

  -- #13: FX.removeStatus mirrors cc_remove -- ghost/orphan prune, Forget tile and
  -- the auto-respawn dead-tile drop must not strand the per-key sibling files
  -- (SessionEnd never fires for those sessions).
  do
    local p = src:find("function FX.removeStatus(key)", 1, true)
    check("#13-pin: FX.removeStatus found", p ~= nil)
    local body = p and src:sub(p, p + 1500) or ""
    check("#13-pin: removes the decision file",
          body:find('key .. ".decision")', 1, true) ~= nil)
    check("#13-pin: sweeps decision claim files (incl. .parked)",
          body:find('key .. ".decision.claim."', 1, true) ~= nil)
    check("#13-pin: removes the gate-tools override", body:find("GATE_TOOLS_DIR", 1, true) ~= nil)
    check("#13-pin: removes the autopilot expiry", body:find("AUTOPILOT_DIR", 1, true) ~= nil)
    check("#13-pin: removes the resolved policy", body:find("POLICY_DIR", 1, true) ~= nil)
    check("#13-pin: removes the policy override", body:find("POLICY_OVERRIDE_DIR", 1, true) ~= nil)
    check("#13-pin: removes the approveRepeats memo", body:find("cc-approved", 1, true) ~= nil)
    check("#13-pin: removes the automodel marker", body:find("cc-automodel", 1, true) ~= nil)

    -- #13-drift (review q87): the per-key file family is encoded TWICE -- here and
    -- in cc_remove (cc-lib.sh) -- bound only by a "KEEP IN SYNC" comment. The
    -- markers above pin that the Lua side has every KNOWN slot, but can't catch a
    -- NEW sidecar added to only one remover. Canary: both functions must reference
    -- the SAME number of per-key targets (os.remove( on the Lua side, $1 on the
    -- shell side). Add a file to cc_remove but not FX.removeStatus (or vice-versa)
    -- and the counts diverge -- failing here and forcing the next author to touch
    -- BOTH removers (and the per-slot markers above).
    -- NB: these are deliberately-brittle HEURISTIC token counts (`os.remove(` and
    -- `$1`), not semantic ones. A pure refactor can shift them -- a batch/loop
    -- remove, `os.remove (` with a space, or a `$1` in cc_remove used for anything
    -- but a sidecar target (today it has none). A mismatch here means "re-check both
    -- removers by hand", not necessarily a bug; realign the counts once verified.
    local rsBody = src:match("function FX%.removeStatus%(key%)(.-)\nend")
    local luaTargets = rsBody and select(2, rsBody:gsub("os%.remove%(", "")) or 0
    local shf = io.open(ROOT .. "cc-lib.sh", "r")
    local shSrc = shf and shf:read("*a") or ""
    if shf then shf:close() end
    local rmBody = shSrc:match("\ncc_remove%(%)%s*{(.-)\n}")
    local shellTargets = rmBody and select(2, rmBody:gsub("%$1", "")) or 0
    check("#13-drift: FX.removeStatus target count parses (>=9)", luaTargets >= 9)
    check("#13-drift: cc_remove target count parses (>=9)", shellTargets >= 9)
    check("#13-drift: FX.removeStatus (" .. tostring(luaTargets) .. ") and cc_remove ("
          .. tostring(shellTargets) .. ") reference the same per-key file count",
          luaTargets == shellTargets)
  end

  -- #14: fleet search runs via /bin/sh with stdout redirected to a temp file
  -- (the folder-scan R1-38 fix): a direct-exec hs.task deadlocks once matches
  -- exceed the ~64KB pipe buffer, hanging the panel at "searching…".
  check("#14-pin: no direct-exec search task remains",
        src:find("searchTask = hs.task.new(", 1, true) == nil)
  check("#14-pin: search exit callback reads the redirect file",
        src:find('local out = FX.readFile(outFile) or ""', 1, true) ~= nil)

  -- #15/#29: the search exit callback checks OWNERSHIP first -- a superseded
  -- query's terminate-triggered callback must not nil the NEWER task's latch
  -- (which broke terminate-on-new-query and let the new task be GC'd mid-run).
  do
    local b = src:find("if searchTask ~= myTask then pcall(os.remove, outFile); return end", 1, true)
    check("#15-pin: ownership check present in the search callback", b ~= nil)
    local c = b and src:find("searchTask = nil", b, true) or nil
    check("#15-pin: the latch release comes AFTER the ownership check",
          b ~= nil and c ~= nil and (c - b) < 200)
    check("#15-pin: generation check still guards stale results",
          src:find("if gen ~= searchGen then return end", 1, true) ~= nil)
  end

  -- scratch-pin (review q87): the search/scan subprocess stdout goes to an
  -- app-owned scratch file, NOT os.tmpname() in world-writable /tmp (a TOCTOU
  -- symlink-plant vector). Source-shape pin (FX isn't loadable here, like the
  -- #14/#15 pins): guards the two named regressions -- revert to os.tmpname, or a
  -- dropped counter increment (which is what makes concurrent scans collision-free).
  do
    -- the real regression is an ASSIGNMENT from os.tmpname() at a scan site (the
    -- word also appears in the explanatory comment, so match the usage, not a mention)
    check("scratch-pin: no scan path assigns from os.tmpname()",
          src:find("= os.tmpname()", 1, true) == nil)
    check("scratch-pin: both scan sites route through FX.scratchFile",
          src:find('FX.scratchFile("folderscan")', 1, true) ~= nil
          and src:find('FX.scratchFile("search")', 1, true) ~= nil)
    local sfBody = src:match("function FX%.scratchFile%(tag%)(.-)\nend")
    check("scratch-pin: FX.scratchFile found", sfBody ~= nil)
    sfBody = sfBody or ""
    check("scratch-pin: path is contained in the app-owned scratch dir",
          sfBody:find("FX._scratchDir ..", 1, true) ~= nil)
    check("scratch-pin: the app dir is ~/.claude/cc-scratch (or CC_SCRATCH_DIR), not /tmp",
          src:find('"/.claude/cc-scratch"', 1, true) ~= nil
          and src:find('os.getenv("CC_SCRATCH_DIR")', 1, true) ~= nil)
    check("scratch-pin: a per-call counter increment gives each scan a unique name",
          sfBody:find("FX._scratchSeq = FX._scratchSeq + 1", 1, true) ~= nil
          and sfBody:find(".. FX._scratchSeq", 1, true) ~= nil)
  end

  -- #22: gate-consumed files are written atomically (temp+rename) -- a torn
  -- truncate-then-write read of .panel-alive judged the live panel dead (native
  -- fallback), of the gate-tools override momentarily reverted the gated set,
  -- of the autopilot expiry read as 0 (autopilot off).
  check("#22-pin: heartbeat written atomically",
        src:find("FX.writeFileAtomic(HEARTBEAT, tostring(now))", 1, true) ~= nil
        and src:find("FX.writeFile(HEARTBEAT", 1, true) == nil)
  check("#22-pin: autopilot expiry written atomically",
        src:find("FX.writeFileAtomic(AUTOPILOT_DIR", 1, true) ~= nil
        and src:find("FX.writeFile(AUTOPILOT_DIR", 1, true) == nil)
  check("#22-pin: gate-tools override written atomically",
        src:find("FX.writeFileAtomic(GATE_TOOLS_DIR", 1, true) ~= nil
        and src:find("FX.writeFile(GATE_TOOLS_DIR", 1, true) == nil)
  -- the atomic temp is `path .. ".tmp." .. pid`, so the heartbeat's temp name
  -- still contains "/.panel-alive" and the pathwatcher self-ignore keeps
  -- matching -- pin both halves (the naming and the matcher behavior).
  check("#22-pin: writeFileAtomic temp keeps the path prefix",
        src:find('local tmp = path .. ".tmp."', 1, true) ~= nil)
  check("#22: watcher self-ignores the heartbeat's atomic temp file",
        core.watcherShouldRefresh({ "/s/.panel-alive.tmp.123" }) == false)
  check("#22: watcher still refreshes on real files next to the temp",
        core.watcherShouldRefresh({ "/s/.panel-alive.tmp.123", "/s/abc.json" }) == true)

  -- #26: the context-menu 'Jump to window' reserves a slot on the shared
  -- injection tail like every sibling jump path -- a direct focus mid-chain
  -- landed another dispatch's pending ⌘V/Return beats in the wrong session.
  do
    local p = src:find('{ title = "Jump to window", fn = function()', 1, true)
    check("#26-pin: context-menu Jump found", p ~= nil)
    local w = p and src:sub(p, p + 300) or ""
    check("#26-pin: Jump routes through dispatchSerialized",
          w:find('dispatchSerialized(item, "focus", function() core.handleAction(FX, item, "focus") end)', 1, true) ~= nil)
  end

  -- #28: FX.notify's click callback dispatches the focus through the serialized
  -- tail, and the forward declaration precedes FX.notify so the reference
  -- compiles as the upvalue (not a nil global).
  do
    local d = src:find("local dispatchSerialized", 1, true)
    local n = src:find("function FX.notify(", 1, true)
    check("#28-pin: dispatchSerialized declared before FX.notify",
          d ~= nil and n ~= nil and d < n)
    local body = n and src:sub(n, n + 1400) or ""
    check("#28-pin: notify click reserves a serialized slot",
          body:find('dispatchSerialized(it, "focus", function()', 1, true) ~= nil)
    check("#28-pin: the focus itself still goes through focusProject",
          body:find("focusProject(it.name, it.cwd, it.editor, true)", 1, true) ~= nil)
  end

  -- #30: each voice recording gets a unique wav (no fixed cc-voice.wav that a
  -- re-record's -y could rewrite mid-transcription) and transcription fires from
  -- ffmpeg's OWN exit callback (rec.transcribe), not a fixed 0.5s grace; the
  -- self-stop branch is ownership-guarded.
  check("#30-pin: per-recording unique wav path",
        src:find("sd.voiceSeq = (sd.voiceSeq or 0) + 1", 1, true) ~= nil
        and src:find('"cc-voice-" .. sd.voiceSeq', 1, true) ~= nil)
  check("#30-pin: the fixed wav path is gone",
        src:find("cc-voice.wav", 1, true) == nil)
  check("#30-pin: the fixed 0.5s transcription grace is gone",
        src:find("after(0.5, function() sdTranscribeAndSend", 1, true) == nil)
  check("#30-pin: transcription fires from ffmpeg's exit callback",
        src:find("if rec.transcribe then", 1, true) ~= nil)
  check("#30-pin: self-stop branch is ownership-guarded",
        src:find("elseif sd.recording and sd.voiceTask == t then", 1, true) ~= nil)
end

-- =============================================================================
-- Regression pins for the 2026-07-07/08 sweep (dashboard half). Same rationale
-- as the batch above: the fixed logic lives in claude-dashboard.lua's FX layer /
-- refresh loop / embedded JS, which has no headless runtime here, so the
-- load-bearing expressions are pinned at the source level; the pure halves are
-- behavior-tested in core.test.lua (and #10 above). Ids reference THIS sweep's
-- bug list; if a pin trips after a refactor, re-verify the BEHAVIOR it names
-- before appeasing it.
-- =============================================================================
do
  local f = io.open(ROOT .. "claude-dashboard.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("sweep-pin: dashboard source readable", #src > 0)

  -- #2: the plan-limit alert memo survives hs.reload (every `make deploy`
  -- reloads) via hs.settings, like ccNotifySeen -- an in-memory-only memo
  -- re-warned every still-open window >= threshold after each deploy.
  check("#2-pin: usage-alert memo loaded from hs.settings",
        src:find('FX._usageAlertFired = hs.settings.get("ccUsageAlertFired")', 1, true) ~= nil
        and src:find('if type(FX._usageAlertFired) ~= "table" then FX._usageAlertFired = {} end', 1, true) ~= nil)
  check("#2-pin: memo persisted after a fired alert",
        src:find('if #alerts > 0 then hs.settings.set("ccUsageAlertFired", FX._usageAlertFired) end', 1, true) ~= nil)
  check("#2-pin: the bare reload-wiped reset is gone",
        src:find("\nFX._usageAlertFired = {}\n", 1, true) == nil)

  -- #3/#22: orphaned scan/search scratch files (Hammerspoon quit/crash mid-scan)
  -- are swept at startup -- unlike /tmp, nothing else ever cleans the app dir.
  check("#3-pin: FX.pruneScratch defined",
        src:find("function FX.pruneScratch()", 1, true) ~= nil)
  do
    local body = src:match("function FX%.pruneScratch%(%)(.-)\nend") or ""
    check("#3-pin: prune sweeps the app scratch dir (self-gating readDir)",
          body:find("FX.readDir(FX._scratchDir)", 1, true) ~= nil
          and body:find('pcall(os.remove, FX._scratchDir .. "/" .. name)', 1, true) ~= nil)
  end
  check("#3-pin: prune wired once at startup (retained after())",
        src:find("after(2.5, function() pcall(FX.pruneScratch) end)", 1, true) ~= nil)

  -- #4: a just-fired respawn's freshly-charged budget key backs NO tile until the
  -- relaunch lands, so the liveBudgetKeys reap wiped it and maxRetries never
  -- bound. The spawn site holds the key live for the relaunch gap.
  check("#4b-pin: respawn hold table on FX (200-local cap)",
        src:find("FX._respawnHold = {}", 1, true) ~= nil)
  check("#4b-pin: hold written when the auto-respawn launches",
        src:find("FX._respawnHold[core.budgetKey(it)] = now + autoRespawnStale", 1, true) ~= nil)
  -- #4b-fix (loop-2 validation caught the original patch as wrong): the reap now
  -- delegates to pure, unit-tested core.liveBudgetKeys, which expires holds by
  -- DEADLINE only. The old inline reap wiped the hold whenever a tile reported the
  -- key -- but the just-removed dead tile lingers one tick in `list`, so it wiped the
  -- hold on the same tick the spawn site set it and the budget was reaped during the
  -- relaunch gap (maxRetries never bound). Guard against that line creeping back:
  check("#4b-fix: reap delegates to pure core.liveBudgetKeys",
        src:find("core.liveBudgetKeys(list, FX._respawnHold, now)", 1, true) ~= nil)
  -- glyph-fix: the Alerts-tab evDesc twin renders a `fallback` decision with ⚠ (a
  -- gate hand-off to native), not the allow ✅ — matching core.narrateEvent + Rows.
  check("glyph-fix: evDesc distinguishes a fallback decision (⚠, not ✅)",
        src:find('e.outcome === "fallback" ? "⚠" : "✅"', 1, true) ~= nil)
  check("#4b-fix: the same-tick hold-wipe is gone (no tile loop nils the hold)",
        src:find("liveBudgetKeys[bk] = true; FX._respawnHold[bk] = nil", 1, true) == nil
        and src:find("if now < deadline then liveBudgetKeys[bk] = true else FX._respawnHold[bk] = nil end", 1, true) == nil)

  -- #5: bg_active/bg_count are computed for display-STALE tiles too -- background
  -- agents fire no hooks on the parent, so the tile goes stale ~90s into exactly
  -- the fleet run the badge exists for; the old `not it.stale` gate made the
  -- pinned JS `stale && !bgRunning` suppression unsatisfiable.
  check("#5b-pin: background scan no longer gated on display staleness",
        src:find("if it.transcript_path and not it.remote then", 1, true) ~= nil)
  check("#5b-pin: the stale-gated variant is gone",
        src:find("if it.transcript_path and not it.remote and not it.stale then", 1, true) == nil)

  -- #6: a heal-carried 'working' is the heal's own ALIVE verdict on a raw-'done'
  -- file -- it must never feed stepAutoRespawn as frozen-at-working death
  -- evidence (the respawn would kill a live mid-turn session's tile and spawn a
  -- duplicate in the same folder).
  check("#6b-pin: auto-respawn gate excludes heal-latched sessions",
        src:find("and FX._healedDone[it.key] == nil, maxRetries = autoRespawnMax,", 1, true) ~= nil)

  -- #11: audit-review ('Review activity') refuses remote tiles BEFORE building /
  -- dispatching the paste -- the branch bypasses handleAction's R2-07 chokepoint
  -- and would otherwise focus a LOCAL window matching the remote session's name
  -- and inject the review prompt there (the clear/compact R3-17 shape).
  do
    local p = src:find('if a == "audit-review" then', 1, true)
    check("#11-pin: audit-review branch found", p ~= nil)
    local w = p and src:sub(p, p + 2200) or ""
    local g = w:find("if target.remote then", 1, true)
    local paste = w:find("FX.pasteIntoWindow(winTarget(target)", 1, true)
    check("#11-pin: remote guard present in the branch", g ~= nil)
    check("#11-pin: refusal names the limitation",
          w:find("'Review activity' isn't available for remote session", 1, true) ~= nil)
    check("#11-pin: the guard precedes the paste dispatch",
          g ~= nil and paste ~= nil and g < paste)
  end

  -- #13: FX.sendKeys' kitty path probes window liveness (R1-15 idiom) instead of
  -- trusting bare runKitty, which returns true the instant `kitty @` LAUNCHES --
  -- set-mode re-based permission_mode (and ledgered mode_change) on sends into
  -- a dead/closed window.
  check("#13b-pin: sendKeys kitty path routes through runKittyChecked",
        src:find('return FX.runKittyChecked(kittyItem(target), core.kittyCmd("key", kittyItem(target), { tokens = tokens }))', 1, true) ~= nil)
  check("#13b-pin: the unprobed send-key ladder is gone",
        src:find('return runKitty(core.kittyCmd("key", kittyItem(target), { tokens = tokens }))', 1, true) == nil)

  -- #15: the notification-click jump short-circuits kitty to FX.focusWindow --
  -- focusProject only knows GUI editors (no 'kitty' bundle/app entry), so it
  -- raised an unrelated VS Code window instead of the kitty window the banner
  -- advertised. Non-kitty keeps the direct focusProject jump (#28-pinned above).
  do
    local n = src:find("function FX.notify(", 1, true)
    local body = n and src:sub(n, n + 2200) or ""
    check("#15b-pin: notify click branches on kitty",
          body:find('if it.editor == "kitty" then', 1, true) ~= nil)
    check("#15b-pin: kitty jump goes through FX.focusWindow with an inline target",
          body:find("FX.focusWindow({ name = it.name, cwd = it.cwd, editor = it.editor,", 1, true) ~= nil)
  end

  -- #16: a successful live /effort dispatch persists the new value (item.effort +
  -- FX.patchStatus, the R3-03 model idiom) so the 1s refreshList rebuild doesn't
  -- snap the Effort dropdown back to the spawn-time $CLAUDE_EFFORT.
  check("#16-pin: effort change persisted like model",
        src:find('item.effort = tostring(text or ""); FX.patchStatus(item.key, { effort = item.effort })', 1, true) ~= nil)

  -- #18 (JS twin): isNotification includes usage_limit (Lua half pinned in
  -- core.test.lua), and the Alerts empty-state names the new type.
  check("#18-pin: JS isNotification counts usage_limit",
        src:find('|| e.type === "usage_limit") return true;', 1, true) ~= nil)

  -- limit-display (JS twins): the Alerts panel drew "• usage_limit" with no detail
  -- because usage_limit had no NARRATE entry and no evDesc branch, the session
  -- column rendered "?" for an account-wide event, and NO audit row of any type
  -- was clickable. All four halves pinned here against the Lua originals.
  check("limit-display: evDesc has a usage_limit branch",
        src:find('else if(e.type === "usage_limit") detail = usageLimitDetail(e);', 1, true) ~= nil)
  check("limit-display: JS twin of core.usageWindowLabel",
        src:find('function usageWindowLabel(key)', 1, true) ~= nil
        and src:find('if(k === "session") return "Session (5h)";', 1, true) ~= nil)
  check("limit-display: JS twin of core.usageLimitDetail shows percent + threshold",
        src:find('function usageLimitDetail(e)', 1, true) ~= nil
        and src:find('" at " + Math.floor(+e.percent) + "%"', 1, true) ~= nil
        and src:find('" (warns at " + Math.round(+e.threshold) + "%)"', 1, true) ~= nil)
  check("limit-display: an account-wide event shows an em dash, not '?'",
        src:find('var ACCOUNT_SCOPED = { usage_limit: 1 };', 1, true) ~= nil
        and src:find('ACCOUNT_SCOPED[e.type] ? "—" : "?"', 1, true) ~= nil)
  check("limit-display: rows carrying detail are clickable and expand",
        src:find('function auditToggle(el)', 1, true) ~= nil
        and src:find('onclick="auditToggle(this)"', 1, true) ~= nil
        and src:find(".a-item.open .a-detail{ display:grid; }", 1, true) ~= nil)
  -- the redact button lives INSIDE the clickable row: without stopPropagation a
  -- redact click would also toggle the detail open.
  check("limit-display: redact click does not also toggle the row",
        src:find('onclick="event.stopPropagation();auditRedact(', 1, true) ~= nil)
  check("#18-pin: Alerts empty-state mentions usage-limit warnings",
        src:find("usage-limit warnings, and non-human gate decisions land here", 1, true) ~= nil)

  -- #19: both respawn call sites thread the dead tile's budget key as lineage,
  -- and FX.spawnSession injects it as spawn env for KITTY only (an env entry
  -- would force the VS Code spawn onto the typed-terminal flavor; cc-status.sh
  -- publishes it as budget_lineage, core.budgetKey prefers it -- core-pinned).
  check("#19-pin: auto-respawn passes the lineage",
        src:find('rs.providerId or "", { lineage = core.budgetKey(it) }, false, rs.model)', 1, true) ~= nil)
  check("#19-pin: manual respawn passes the lineage",
        src:find("{ lineage = core.budgetKey(item) }, false, rs.model)", 1, true) ~= nil)
  check("#19-pin: spawn env carries CC_SHEPHERD_LINEAGE",
        src:find('env[#env + 1] = { name = "CC_SHEPHERD_LINEAGE", value = lineage, secret = false }', 1, true) ~= nil)
  check("#19-pin: lineage env injection is kitty-gated",
        src:find('and tostring(editor):lower() == "kitty" then', 1, true) ~= nil)

  -- #21: the folder-scan exit callback checks OWNERSHIP before stopping the
  -- SHARED folderScanTimer slot -- stopped first, a stale scan's late exit
  -- disarmed the CURRENT scan's 15s backstop (the fleet-search callback order).
  do
    local own = src:find("if folderScanTask ~= myTask then pcall(os.remove, outFile); return end", 1, true)
    local stop = src:find("if folderScanTimer then pcall(function() folderScanTimer:stop() end); folderScanTimer = nil end", 1, true)
    check("#21-pin: ownership check and timer stop both present", own ~= nil and stop ~= nil)
    check("#21-pin: ownership check comes BEFORE the shared timer stop",
          own ~= nil and stop ~= nil and own < stop and (stop - own) < 500)
  end

  -- #23: the fleet search has a wedge backstop (the folder scan's idiom): a
  -- stuck mount / hung engine must never pin "searching…" forever. Retained on
  -- FX (200-local cap), ownership-checked, cancelled on a real exit, and the
  -- webview learns it timed out instead of waiting forever.
  check("#23-pin: search backstop armed (30s, retained on FX)",
        src:find("FX._searchTimer = hs.timer.doAfter(30, function()", 1, true) ~= nil)
  check("#23-pin: stale backstop is a no-op (ownership check)",
        src:find("if searchTask ~= myTask then return end", 1, true) ~= nil)
  check("#23-pin: real exit cancels the backstop",
        src:find("if FX._searchTimer then pcall(function() FX._searchTimer:stop() end); FX._searchTimer = nil end", 1, true) ~= nil)
  check("#23-pin: timeout pushes an explicit timedOut result",
        src:find("hs.json.encode({ q = q, hits = {}, timedOut = true })", 1, true) ~= nil)
  check("#23-pin: JS renders the timeout instead of pinning 'searching…'",
        src:find('res.timedOut ? "search timed out (30s)', 1, true) ~= nil)

  -- #29: FX.abKeep closes each loser through the serialized injection tail (a
  -- captured per-loser target), not a direct synchronous loop whose overdue
  -- ⌘⇧W beats fired back-to-back into whatever was frontmost -- including the
  -- WINNER's window.
  check("#29-pin: abKeep loser close rides the injection tail",
        src:find('dispatchSerialized(tile, "close", function() FX.closeWindow(target) end)', 1, true) ~= nil)
  check("#29-pin: the direct un-serialized close is gone",
        src:find("FX.closeWindow({ name = tile.name", 1, true) == nil)

  -- #30 (Stream Deck gestures): key -> session binds at PRESS time (sdRender
  -- reassigns sd.buttons every 1Hz tick, so a long press straddling a tick
  -- resolved against a DIFFERENT session -- or this session's NEW gate state,
  -- silently converting a focus tap into an approve).
  check("#30b-pin: press snapshots the item under the finger",
        src:find("sd.pressItem[button] = sd.buttons[button] and byKey[sd.buttons[button]] or nil", 1, true) ~= nil)
  check("#30b-pin: release resolves against the press-time snapshot",
        src:find("local item = sd.pressItem and sd.pressItem[button] or nil", 1, true) ~= nil)
  check("#30b-pin: snapshot is one-shot (cleared on release)",
        src:find("if sd.pressItem then sd.pressItem[button] = nil end", 1, true) ~= nil)
  check("#30b-pin: release-time re-resolve is gone",
        src:find("local key = sd.buttons[button]", 1, true) == nil)

  -- #31: hs.timer callbacks fire in NSModalPanelRunLoopMode, so pending
  -- injection beats pressed a modal dialog's destructive DEFAULT button
  -- (Purge/Delete/Yes/Keep winner). after() defers beats while a modal is up;
  -- FX.runModal brackets every dialog site; a zero-delay chain start also holds.
  check("#31-pin: after() defers beats while a modal is active (re-armed, retained)",
        src:find("if FX._modalActive then", 1, true) ~= nil
        and src:find("hs.timer.doAfter(0.25, fire)", 1, true) ~= nil)
  check("#31-pin: FX.runModal sets/clears the modal latch",
        src:find("function FX.runModal(fn)", 1, true) ~= nil
        and src:find("FX._modalActive = true", 1, true) ~= nil)
  do
    local wrapped = select(2, src:gsub("FX%.runModal%(function%(%) return hs%.dialog", ""))
    local alerts  = select(2, src:gsub("hs%.dialog%.blockAlert%(", ""))
    local prompts = select(2, src:gsub("hs%.dialog%.textPrompt%(", ""))
    check("#31-pin: EVERY dialog site is runModal-wrapped (" .. wrapped .. " of "
          .. (alerts + prompts) .. ")", wrapped > 0 and wrapped == alerts + prompts)
  end
  check("#31-pin: zero-delay chain starts also hold during a modal",
        src:find("if delay > 0 or FX._modalActive then after(math.max(delay, 0), fn) else fn() end", 1, true) ~= nil)

  -- #32: the bridgeSync rsync exit callback + timeout backstop are ownership-
  -- checked (R1-38 idiom) -- a terminated wedged rsync's LATE exit stopped the
  -- next sync's backstop, broke its skip-if-running guard, and dropped its
  -- retained task handle.
  check("#32-pin: bridge exit callback proves ownership first",
        src:find("if b.task ~= myTask then return end", 1, true) ~= nil)
  check("#32-pin: bridge backstop is ownership-checked too",
        src:find("if b.running and b.task == myTask then", 1, true) ~= nil)

  -- #33: the per-host bridge doEvery timers live in the module-local `bridge`
  -- table; exporting it on _G.__ccDashboard lets the re-dofile guard stop the
  -- PRIOR instance's timers (else every console re-dofile stacked another set
  -- of always-firing rsync --delete pipelines into the same mirror dirs).
  check("#33-pin: bridge table exported for the re-dofile guard",
        src:find("toggle = togglePanel, bridge = bridge }", 1, true) ~= nil)
  do
    local g = src:find('if prev and type(prev.bridge) == "table" then', 1, true)
    check("#33-pin: guard walks the prior instance's bridge entries", g ~= nil)
    local w = g and src:sub(g, g + 500) or ""
    check("#33-pin: guard stops timer + backstop and terminates in-flight rsync",
          w:find("b.timer:stop()", 1, true) ~= nil
          and w:find("b.timeoutTimer:stop()", 1, true) ~= nil
          and w:find("b.task:terminate()", 1, true) ~= nil)
  end

  -- #34: the queue pop -> deliver -> persist critical section is single-flight
  -- (FX.feedGuard): a kitty delivery's waitUntilExit PUMPS the run loop, letting
  -- a nested tick/bridge message re-read the still-unwritten queue and pop +
  -- deliver the same head twice.
  check("#34-pin: FX.feedGuard defined",
        src:find("function FX.feedGuard(fn)", 1, true) ~= nil)
  do
    local body = src:match("function FX%.feedGuard%(fn%)(.-)\nend") or ""
    check("#34-pin: guard is pcall'd so a throw can't latch the flag",
          body:find("local ok, err = pcall(fn)", 1, true) ~= nil
          and body:find("FX._queueFeedBusy = false", 1, true) ~= nil)
  end
  eq("#34-pin: all 3 feed sites are guarded (manual + autofeed + router)",
     select(2, src:gsub("FX%.feedGuard%(function%(%)", "")), 3)
  check("#34-pin: a guarded-out router attempt clears its pending marker",
        src:find("end) then routePending[item.key] = nil end", 1, true) ~= nil)

  -- #35 (writer half): set-group accepts scope=='session' and keys the entry by
  -- the TILE key (which core.applyGroups resolves first -- core-pinned), so ONE
  -- member of a project queue can carry its own @role: routing target.
  check("#35-pin: set-group keys by tile on scope=='session'",
        src:find('local gkey = (tostring(payload.scope or "") == "session" and item.key)', 1, true) ~= nil)
  check("#35-pin: group bar has the 'this session only' checkbox (reset on open)",
        src:find('id="setgroupbar-tile"', 1, true) ~= nil
        and src:find('document.getElementById("setgroupbar-tile").checked = false;', 1, true) ~= nil)
  check("#35-pin: commitGroup sends the scope through send()'s 5th field",
        src:find('var scope = document.getElementById("setgroupbar-tile").checked ? "session" : "";', 1, true) ~= nil
        and src:find('scope:scope||""', 1, true) ~= nil)

  -- #38: legacy queue adoption verifies the merged write actually LANDED
  -- (re-read depth >= merged depth) before deleting the legacy file -- a silent
  -- writeQueue failure otherwise destroyed the only durable copy of its tasks.
  do
    local v = src:find("if core.queueDepth(FX.readQueue(qk)) >= core.queueDepth(merged) then", 1, true)
    local rm = src:find("FX.removeQueue(legacy)", 1, true)
    check("#38-pin: adoption verifies the write before removing the legacy queue",
          v ~= nil and rm ~= nil and v < rm and (rm - v) < 300)
    check("#38-pin: a failed write keeps the legacy file (retry next tick)",
          src:find("legacy queue adoption write did not land", 1, true) ~= nil)
  end
end

print(string.format("-- ui.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
