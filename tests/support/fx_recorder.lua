-- fx_recorder.lua : a test double for the effects layer. Instead of focusing
-- windows, sending keystrokes, or writing decision files, it records the intent
-- so tests can assert "babysitter WOULD have done X" with zero side effects.
--
-- Usage:
--   local newRecorder = dofile("support/fx_recorder.lua")
--   local r = newRecorder()
--   core.handleAction(r.fx, item, "approve")
--   assert(r.last().op == "writeDecision")

local function newRecorder()
  local r = { calls = {}, _now = 1000 }

  local function rec(op, a, b)
    r.calls[#r.calls + 1] = { op = op, a = a, b = b }
  end

  r.fx = {
    now            = function() return r._now end,
    log            = function() end,
    focusWindow    = function(name) rec("focusWindow", name); return true end,
    actOnWindow    = function(name, keySpec) rec("actOnWindow", name, keySpec) end,
    typeIntoWindow = function(name, text) rec("typeIntoWindow", name, text) end,
    writeDecision  = function(key, value) rec("writeDecision", key, value) end,
    readDir        = function() return {} end,
    readFile       = function() return nil end,
    writeFile      = function() end,
  }

  function r.last() return r.calls[#r.calls] end
  function r.count() return #r.calls end

  return r
end

return newRecorder
