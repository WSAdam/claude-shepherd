-- fx_recorder.lua : a test double for the effects layer. Instead of focusing
-- windows, sending keystrokes, or writing decision files, it records the intent
-- so tests can assert "Claude Shepherd WOULD have done X" with zero side effects.
--
-- Usage:
--   local newRecorder = dofile("support/fx_recorder.lua")
--   local r = newRecorder()
--   core.handleAction(r.fx, item, "approve")
--   assert(r.last().op == "writeDecision")

local function newRecorder()
  -- _geometry / _imagePath let a test control what the read-style effects return.
  local r = { calls = {}, _now = 1000, _geometry = nil, _imagePath = "/tmp/cc-img-test.png" }

  local function rec(op, a, b)
    r.calls[#r.calls + 1] = { op = op, a = a, b = b }
  end
  -- Window effects now receive a target TABLE {name,cwd,editor,kittyWindowId,
  -- kittyListenOn} (Part A). Surface target.name as `.a` so existing name
  -- assertions keep working, and stash the full target on `.tgt` for kitty-routing
  -- tests. (focus also records target.cwd as `.b`, matching the old signature.)
  local function recWin(op, target, b)
    r.calls[#r.calls + 1] = { op = op, a = (target or {}).name, b = b, tgt = target }
  end

  r.fx = {
    now             = function() return r._now end,
    log             = function() end,
    focusWindow     = function(t) recWin("focusWindow", t, t and t.cwd); return true end,
    actOnWindow     = function(t, keySpec) recWin("actOnWindow", t, keySpec) end,
    typeIntoWindow  = function(t, text) recWin("typeIntoWindow", t, text) end,
    pasteIntoWindow = function(t, payload) recWin("pasteIntoWindow", t, payload) end,
    closeWindow     = function(t) recWin("closeWindow", t) end,
    sendKeys        = function(t, keys) recWin("sendKeys", t, keys) end,
    removeStatus    = function(key) rec("removeStatus", key) end,
    saveGeometry    = function(frame) rec("saveGeometry", frame) end,
    loadGeometry    = function() rec("loadGeometry"); return r._geometry end,
    writeImageTemp  = function(b64) rec("writeImageTemp", b64); return r._imagePath end,
    writeDecision   = function(key, value) rec("writeDecision", key, value) end,
    spawnSession    = function(editor, project, task) rec("spawnSession", editor, { project = project, task = task }) end,
    readDir         = function() return {} end,
    readFile        = function() return nil end,
    writeFile       = function() end,
  }

  function r.last() return r.calls[#r.calls] end
  function r.count() return #r.calls end

  return r
end

return newRecorder
