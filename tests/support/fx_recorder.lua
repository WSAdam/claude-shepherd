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

  r.fx = {
    now             = function() return r._now end,
    log             = function() end,
    focusWindow     = function(name, cwd) rec("focusWindow", name, cwd); return true end,
    actOnWindow     = function(name, keySpec) rec("actOnWindow", name, keySpec) end,
    typeIntoWindow  = function(name, text) rec("typeIntoWindow", name, text) end,
    pasteIntoWindow = function(name, payload) rec("pasteIntoWindow", name, payload) end,
    closeWindow     = function(name) rec("closeWindow", name) end,
    sendKeys        = function(name, keys) rec("sendKeys", name, keys) end,
    removeStatus    = function(key) rec("removeStatus", key) end,
    saveGeometry    = function(frame) rec("saveGeometry", frame) end,
    loadGeometry    = function() rec("loadGeometry"); return r._geometry end,
    writeImageTemp  = function(b64) rec("writeImageTemp", b64); return r._imagePath end,
    writeDecision   = function(key, value) rec("writeDecision", key, value) end,
    spawnSession    = function(project, prompt) rec("spawnSession", project, prompt) end,
    readDir         = function() return {} end,
    readFile        = function() return nil end,
    writeFile       = function() end,
  }

  function r.last() return r.calls[#r.calls] end
  function r.count() return #r.calls end

  return r
end

return newRecorder
