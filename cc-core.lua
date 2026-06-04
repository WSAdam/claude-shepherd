-- cc-core.lua
--
-- Pure logic for babysitter's panel/deck, with ZERO direct hs.* calls so it can
-- be unit-tested in plain `lua`. Two injection points keep it pure:
--   * M.json  - a JSON impl with .decode/.encode (prod: hs.json; tests: json.lua)
--   * fx       - an "effects" table passed to handleAction; the ONLY side effects
--                (focus a window, send keys, write a decision file). Prod wires it
--                to hs.*; tests pass a recorder that captures intent.
--
-- The Hammerspoon bootstrap (claude-dashboard.lua) requires this, sets M.json,
-- builds the real fx, and owns all the I/O / webview / Stream Deck / timers.

local M = {}

-- Injected by the caller before use. Prod: hs.json. Tests: support/json.lua.
M.json = nil

-- Default staleness threshold (seconds); the bootstrap passes its own value.
M.STALE_SECONDS = 90

-- Keystrokes the permission TUI expects (data only; fx performs them).
M.KEY_APPROVE = { mods = {}, key = "return" } -- accept highlighted "Yes"
M.KEY_DENY    = { mods = {}, key = "escape" } -- cancel the prompt
M.KEY_STOP    = { mods = {}, key = "escape" } -- interrupt the turn

-- Stream Deck key colors/labels by status (used by the bootstrap's renderer).
M.SD_COLORS = {
  idle     = { red = 0.42, green = 0.45, blue = 0.50 },
  working  = { red = 0.96, green = 0.71, blue = 0.04 },
  done     = { red = 0.13, green = 0.77, blue = 0.37 },
  approval = { red = 0.94, green = 0.27, blue = 0.27 },
}
M.SD_LABELS = { idle = "idle", working = "working", done = "ready", approval = "NEEDS YOU" }

-- Read a config value from a decoded settings table by dotted path, returning
-- `default` if any segment is missing. A stored `false` is preserved (returns
-- false, not the default), so boolean toggles work correctly.
function M.config(tbl, path, default)
  local node = tbl
  for key in tostring(path):gmatch("[^.]+") do
    if type(node) ~= "table" then return default end
    node = node[key]
    if node == nil then return default end
  end
  return node
end

-- Sort priority: approvals first (they need you), then by name for stability.
local RANK = { approval = 0, done = 1, working = 2, idle = 3 }

-- Decode each {key=, content=} status entry, tag it with key + stale flag, drop
-- malformed/nameless ones, and return the list sorted approvals-first.
function M.parseStatusList(entries, now, staleSeconds)
  staleSeconds = staleSeconds or M.STALE_SECONDS
  local list = {}
  for _, e in ipairs(entries or {}) do
    local okj, data = pcall(function() return M.json.decode(e.content) end)
    if okj and type(data) == "table" and data.name then
      data.key = e.key
      data.stale = (data.updated ~= nil) and ((now - data.updated) > staleSeconds) or false
      list[#list + 1] = data
    end
  end
  table.sort(list, function(a, b)
    local ra, rb = RANK[a.status] or 9, RANK[b.status] or 9
    if ra ~= rb then return ra < rb end
    return (a.name or "") < (b.name or "")
  end)
  return list
end

-- Which action a deck/hotkey gesture maps to, given the session's gate state.
-- kind: "primary" (short press) | "secondary" (long press).
function M.resolveGesture(item, kind, opts)
  opts = opts or {}
  if not item then return nil end
  if item.gate == "waiting" then
    if kind == "secondary" then return "deny" else return "approve" end
  end
  if kind == "secondary" and opts.longPressStops then return "stop" end
  return "focus"
end

-- Perform an action on a session via the injected fx (the only side effects).
-- Returns the action actually taken (handy for tests/logging).
function M.handleAction(fx, item, action, text)
  if not item then return nil end
  if action == "focus" then
    fx.focusWindow(item.name)
  elseif action == "approve" then
    if item.gate == "waiting" then fx.writeDecision(item.key, "allow")
    else fx.actOnWindow(item.name, M.KEY_APPROVE) end
  elseif action == "deny" then
    if item.gate == "waiting" then fx.writeDecision(item.key, "deny")
    else fx.actOnWindow(item.name, M.KEY_DENY) end
  elseif action == "stop" then
    fx.actOnWindow(item.name, M.KEY_STOP)
  elseif action == "nudge" then
    if text and #text > 0 then fx.typeIntoWindow(item.name, text) else return nil end
  else
    return nil
  end
  return action
end

-- Map the sorted session list onto a deck of `count` keys (row-major). Returns
-- items[1..count] (nil for empty keys) and how many sessions didn't fit.
function M.deckLayout(count, list)
  local items = {}
  for i = 1, count do items[i] = list[i] end
  local overflow = #list - count
  if overflow < 0 then overflow = 0 end
  return { items = items, overflow = overflow }
end

-- Hotkey helpers (used in Phase 2).
function M.nextApproval(list)
  for _, it in ipairs(list or {}) do
    if it.status == "approval" then return it end
  end
  return nil
end

function M.frontSession(list) return (list or {})[1] end

-- Extract the latest assistant text from a transcript.jsonl tail, for the "live
-- activity peek". Scans lines backwards (the last assistant line is often a
-- tool_use with no text), returns the last text block found, whitespace-collapsed
-- and truncated. Returns nil if there's no assistant text.
function M.transcriptSnippet(text, maxLen)
  maxLen = maxLen or 140
  if not text or #text == 0 then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line ~= "" then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "assistant"
         and obj.message and type(obj.message.content) == "table" then
        local txt
        for _, c in ipairs(obj.message.content) do
          if type(c) == "table" and c.type == "text" and c.text and #c.text > 0 then
            txt = c.text
          end
        end
        if txt then
          txt = txt:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
          -- reserve 3 bytes for the … ellipsis so the result stays within maxLen
          if #txt > maxLen then txt = txt:sub(1, maxLen - 3) .. "\226\128\166" end
          return txt
        end
      end
    end
  end
  return nil
end

-- Next session after the one with key==afterKey (wraps to the front). Used by
-- the cycle-jump hotkey. afterKey nil/unknown -> first session.
function M.cycleNext(list, afterKey)
  list = list or {}
  if #list == 0 then return nil end
  if not afterKey then return list[1] end
  local idx
  for i, it in ipairs(list) do
    if it.key == afterKey then idx = i; break end
  end
  if not idx then return list[1] end
  return list[(idx % #list) + 1]
end

-- ---- Task queue (Phase 4b) -------------------------------------------------
-- A queue is { tasks = { "task1", "task2", ... } }; nil/missing is empty.
local function qtasks(q)
  if type(q) == "table" and type(q.tasks) == "table" then return q.tasks end
  return {}
end

function M.queueDepth(q) return #qtasks(q) end

function M.queuePush(q, task)
  local t = {}
  for _, x in ipairs(qtasks(q)) do t[#t + 1] = x end
  if task and #task > 0 then t[#t + 1] = task end
  return { tasks = t }
end

-- Returns the front task and the queue without it.
function M.queuePop(q)
  local src = qtasks(q)
  if #src == 0 then return nil, { tasks = {} } end
  local rest = {}
  for i = 2, #src do rest[#rest + 1] = src[i] end
  return src[1], { tasks = rest }
end

-- Feed the next task only on a FRESH transition into `done`, when the queue is
-- non-empty and auto-feed is on. (prev==done means we already handled it.)
function M.shouldFeed(prev, cur, q, autoOn)
  if not autoOn then return false end
  if M.queueDepth(q) == 0 then return false end
  return cur == "done" and prev ~= "done"
end

-- Should this tile be pruned? Orphans = stale tiles with no session_id (a hook
-- fire that lacked one, keyed by folder name, that SessionEnd can't clean), plus
-- a ghost backstop for anything older than opts.pruneSeconds.
function M.shouldPrune(item, now, opts)
  opts = opts or {}
  if not item then return false end
  local age = item.updated and (now - item.updated) or 0
  local orphan = opts.pruneNoSid and item.stale
    and (not item.session_id or item.session_id == "")
  local ghost = opts.pruneSeconds and opts.pruneSeconds > 0
    and item.updated and age > opts.pruneSeconds
  return (orphan or ghost) and true or false
end

-- ---- Policy A: stale-approval escalation -----------------------------------
-- True when a session has been waiting for you (status "approval") longer than
-- thresholdSec. (`since` is when it entered the approval state.)
function M.approvalStale(item, now, thresholdSec)
  if not item or item.status ~= "approval" or not item.since then return false end
  return (now - item.since) > thresholdSec
end

-- ---- Orchestrator (Phase 4): build the command to spawn a session ----------
-- POSIX single-quote a string so it's safe to embed in a shell command.
local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
-- AppleScript double-quote a string.
local function asquote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- The shell command run INSIDE the spawned terminal:
--   cd <project> && claude [prompt]
function M.spawnInner(project, prompt)
  local inner = "cd " .. shquote(project or ".") .. " && claude"
  if prompt and #prompt > 0 then inner = inner .. " " .. shquote(prompt) end
  return inner
end

-- The AppleScript to run (via hs.osascript, NOT a shell) that opens `terminal`
-- and runs the inner command in it. Running AppleScript directly avoids an extra
-- shell-quoting layer, so this only needs to escape for AppleScript + the inner
-- shell -- two well-defined levels instead of three nested ones.
function M.spawnAppleScript(project, prompt, opts)
  opts = opts or {}
  local term = opts.terminal or "Terminal"
  return "tell application " .. asquote(term)
    .. " to do script " .. asquote(M.spawnInner(project, prompt))
end

return M
