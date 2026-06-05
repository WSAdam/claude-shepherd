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
  -- old sms-bot went stale after /clear; a fresh sms-bot is live -> prune the old
  local list = {
    { key = "old", name = "sms-bot", stale = true },
    { key = "new", name = "sms-bot", stale = false },
    { key = "solo", name = "rune",   stale = true },   -- stale but no live twin -> keep
    { key = "live", name = "canary", stale = false },
  }
  local ghosts = core.staleDuplicateKeys(list)
  eq("ghost: exactly one pruned", #ghosts, 1)
  eq("ghost: prunes the stale duplicate", ghosts[1], "old")

  -- two live tiles for the same project (legit parallel sessions) -> prune none
  local twoLive = {
    { key = "a", name = "sms-bot", stale = false },
    { key = "b", name = "sms-bot", stale = false },
  }
  eq("ghost: two live same-name -> none pruned", #core.staleDuplicateKeys(twoLive), 0)

  -- a lone stale tile (no fresher twin) -> keep (handled by the 24h backstop instead)
  eq("ghost: lone stale -> none pruned",
     #core.staleDuplicateKeys({ { key = "x", name = "rune", stale = true } }), 0)
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

print(string.format("-- ui.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
