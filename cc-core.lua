-- cc-core.lua
--
-- Pure logic for Claude Shepherd's panel/deck, with ZERO direct hs.* calls so it can
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
  -- The window effects route per editor (Part A), so they need more than the
  -- name: a compact target carries the kitty targeting data too. Key-based
  -- effects (writeDecision/removeStatus) stay headless regardless of editor.
  local tgt = {
    name = item.name, cwd = item.cwd, editor = item.editor,
    kittyWindowId = item.kitty_window_id, kittyListenOn = item.kitty_listen_on,
  }
  if action == "focus" then
    fx.focusWindow(tgt)
  elseif action == "approve" then
    if item.gate == "waiting" then fx.writeDecision(item.key, "allow")
    else fx.actOnWindow(tgt, M.KEY_APPROVE) end  -- kitty: headless send-key "enter"
  elseif action == "deny" then
    if item.gate == "waiting" then fx.writeDecision(item.key, "deny")
    else fx.actOnWindow(tgt, M.KEY_DENY) end
  elseif action == "stop" then
    fx.actOnWindow(tgt, M.KEY_STOP)
  elseif action == "nudge" then
    -- Inject via the clipboard (one ⌘V), not char-by-char keystrokes: that's
    -- newline-safe (a multi-line list pastes as one block instead of each line
    -- submitting early) and more reliable in the VS Code extension.
    if text and #text > 0 then fx.pasteIntoWindow(tgt, { text = text }) else return nil end
  elseif action == "close" then
    -- Best-effort close the editor window, then drop its dashboard tile.
    fx.closeWindow(tgt)
    fx.removeStatus(item.key)
  elseif action == "effort" then
    -- Change effort live via the `/effort <level>` slash command.
    local cmd = M.effortCommand(text)
    if cmd then fx.typeIntoWindow(tgt, cmd) else return nil end
  elseif action == "set-mode" then
    -- Cycle to permission mode `text` via Shift+Tab x N (Part C). Kitty reliable;
    -- VS Code best-effort (its mode switcher is mouse-only). N is 0 (no-op) when
    -- already there or the target isn't in the active cycle.
    local n = M.modeCycleSteps(item.permission_mode or "default", text, item.modeCycle)
    if n <= 0 then return nil end
    local keys = {}
    for _ = 1, n do keys[#keys + 1] = { mods = { "shift" }, key = "tab" } end
    fx.sendKeys(tgt, keys)
  elseif action == "answer" then
    -- Select option #text (0-based) in a pending single-select AskUserQuestion:
    -- only a terminal TUI (kitty) responds to synthesized arrow/Enter; the VS Code
    -- extension's picker is mouse-only. A MULTI-select picker can't be driven by
    -- down*N+Enter (it needs toggle-then-confirm), so for it -- and for non-kitty --
    -- we JUMP so the user finishes it by hand.
    if item.editor == "kitty" and not M.askIsMulti(item) then
      fx.sendKeys(tgt, M.answerKeys(text))
    else
      fx.focusWindow(tgt)
    end
  else
    return nil
  end
  return action
end

-- Keys to select option `optIndex` (0-based) in a single-question picker: press
-- Down `optIndex` times (option 0 starts highlighted), then Enter to confirm.
-- The nav scheme is centralized here so it's easy to retune once verified live.
function M.answerKeys(optIndex)
  local n = math.floor(tonumber(optIndex) or 0)
  if n < 0 then n = 0 end
  local keys = {}
  for _ = 1, n do keys[#keys + 1] = { mods = {}, key = "down" } end
  keys[#keys + 1] = { mods = {}, key = "return" }
  return keys
end

-- Is the session's pending AskUserQuestion a MULTI-select? The single-select
-- down*N + Enter scheme can't drive a multi-select picker (that needs
-- toggle-then-confirm), so the caller jumps instead of synthesizing keys.
function M.askIsMulti(item)
  local ask = item and item.pending and item.pending.ask
  if type(ask) ~= "table" then return false end
  local q = ask[1]
  return type(q) == "table" and q.multiSelect == true
end

-- Valid effort levels that can be set live via `/effort` (matches settings).
M.EFFORT_LEVELS = { low = true, medium = true, high = true, xhigh = true }

-- Build the `/effort <level>` slash command, or nil for an unknown level.
function M.effortCommand(level)
  level = tostring(level or ""):lower()
  if not M.EFFORT_LEVELS[level] then return nil end
  return "/effort " .. level
end

-- ---- Panel geometry (Step 1) ----------------------------------------------
-- Minimum sane panel size; anything smaller is treated as garbage and ignored.
M.PANEL_MIN_W = 200
M.PANEL_MIN_H = 120

local function isNum(v) return type(v) == "number" end

-- The default top-right rect, derived from the screen frame + desired size.
local function defaultPanelRect(screenFrame, defaults)
  return {
    x = screenFrame.x + screenFrame.w - defaults.w - 20,
    y = screenFrame.y + 40,
    w = defaults.w,
    h = defaults.h,
  }
end

-- Decide where to open the panel: a previously-saved frame if it's well-formed,
-- big enough, and still visible on this screen; otherwise the default top-right
-- rect. This is what lets a user-resized window survive a Hammerspoon reload.
function M.resolvePanelRect(saved, screenFrame, defaults)
  if type(saved) == "table"
     and isNum(saved.x) and isNum(saved.y) and isNum(saved.w) and isNum(saved.h)
     and saved.w >= M.PANEL_MIN_W and saved.h >= M.PANEL_MIN_H then
    local onScreen = saved.x < screenFrame.x + screenFrame.w
      and saved.x + saved.w > screenFrame.x
      and saved.y < screenFrame.y + screenFrame.h
      and saved.y + saved.h > screenFrame.y
    if onScreen then
      return { x = saved.x, y = saved.y, w = saved.w, h = saved.h }
    end
  end
  return defaultPanelRect(screenFrame, defaults)
end

-- ---- Relabels (Step 3) -----------------------------------------------------
-- Apply in-memory display labels onto a session list, in place. `labels` maps a
-- session key -> override name. Only the DISPLAY field (.label) is set; .name
-- (used to focus/target the real window) is never touched, so jumps still work.
function M.applyLabels(list, labels)
  labels = labels or {}
  for _, it in ipairs(list or {}) do
    it.label = labels[it.key]
  end
  return list
end

-- Apply PERSISTENT display labels keyed by project path (cwd) onto a session
-- list, in place. labelsByCwd maps cwd -> override name. Like applyLabels, only
-- .label (display) is set, never .name. Keying by cwd (not the session_id-based
-- key) means a brand-new session in the same folder inherits the label, so a
-- relabel survives close/reopen and a new instance.
function M.applyLabelsByCwd(list, labelsByCwd)
  labelsByCwd = labelsByCwd or {}
  for _, it in ipairs(list or {}) do
    it.label = it.cwd and labelsByCwd[it.cwd] or nil
  end
  return list
end

-- Set or clear a project label, immutably (returns a NEW table; the input is
-- never mutated, mirroring the queue helpers). A blank/whitespace value, or one
-- equal to fallbackName (the real folder name), CLEARS the entry -- so relabeling
-- back to the folder name resets to the default. A nil/empty cwd is a no-op.
function M.setLabel(labelsByCwd, cwd, value, fallbackName)
  local out = {}
  for k, v in pairs(labelsByCwd or {}) do out[k] = v end
  if not cwd or cwd == "" then return out end
  local txt = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" or txt == fallbackName then out[cwd] = nil else out[cwd] = txt end
  return out
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
    -- Only attempt to decode lines that look like a JSON object; this skips
    -- blank lines and any partial line from a mid-file tail read (which would
    -- otherwise make the JSON decoder log an error every refresh).
    if line:find("^%s*{") then
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

-- Find ghost duplicates left by `/clear` or a session restart: a `/clear` gives
-- the project a NEW session_id (a new tile) while the old session_id's status
-- file lingers with no SessionEnd. Returns the keys of tiles that are stale AND
-- share a `name` with a non-stale tile (the live session for that project). A
-- genuinely-active second session in the same folder isn't stale, so it's safe.
function M.staleDuplicateKeys(list)
  local liveNames = {}
  for _, it in ipairs(list or {}) do
    if not it.stale and it.name then liveNames[it.name] = true end
  end
  local keys = {}
  for _, it in ipairs(list or {}) do
    if it.stale and it.name and liveNames[it.name] then keys[#keys + 1] = it.key end
  end
  return keys
end

-- ---- Policy A: stale-approval escalation -----------------------------------
-- True when a session has been waiting for you (status "approval") longer than
-- thresholdSec. (`since` is when it entered the approval state.)
function M.approvalStale(item, now, thresholdSec)
  if not item or item.status ~= "approval" or not item.since then return false end
  return (now - item.since) > thresholdSec
end

-- ---- Image paste (Step 5) --------------------------------------------------
-- Parse a clipboard image data URL ("data:image/png;base64,...."), returning
-- its mime, a normalized lowercase file extension, and the base64 payload.
-- Returns nil for anything that isn't a base64-encoded image.
function M.parseDataUrl(s)
  if type(s) ~= "string" then return nil end
  -- Tolerate intermediate params between the mime and ;base64, e.g.
  -- "data:image/svg+xml;charset=utf-8;base64,...". The mime is the bit before the
  -- first ';' or ','; anything up to ";base64," is skipped.
  local mime, b64 = s:match("^data:([^;,]+)[^,]*;base64,(.+)$")
  if not mime or not b64 then return nil end
  if not mime:find("^image/") then return nil end
  local ext = (mime:match("^image/(.+)$") or ""):lower()
  if ext == "jpeg" then ext = "jpg" end
  if ext == "svg+xml" then ext = "svg" end
  return { mime = mime, ext = ext, b64 = b64 }
end

-- Build a deterministic temp path for a pasted image. The key is sanitized so a
-- session key containing path separators can't escape `dir`.
function M.tempImagePath(dir, key, ext)
  local safe = tostring(key):gsub("[^%w%-_]", "_")
  return dir .. "/cc-paste-" .. safe .. "." .. ext
end

-- Encode a scalar as a JS string literal (WITH surrounding quotes) for embedding
-- in evaluateJavaScript. Reuses the JSON encoder's escaping (quotes, newlines,
-- unicode) by wrapping in a 1-element array and stripping the [ ]. M.json must be
-- set. This is the escaping the panel relies on for ⌘V / relabel / close -- a bare
-- json.encode(string) errors, so this wrap-and-strip is deliberate.
function M.jsString(s)
  return M.json.encode({ tostring(s) }):sub(2, -2)
end

-- ---- Caffeinate: keep-awake toggle (F2) ------------------------------------
-- Build the pmset command to enable/disable system sleep. Kept pure so the exact
-- command (and the 1/0 mapping) is tested without running anything. The caller
-- runs it elevated (it needs root); reading state (below) does not.
function M.pmsetDisableSleepCmd(on)
  return "/usr/bin/pmset -a disablesleep " .. (on and "1" or "0")
end

-- Parse `pmset -g` output for the SleepDisabled flag. Returns true/false, or nil
-- if the field is absent -- so the caller can leave the toggle as-is instead of
-- flipping it OFF on unexpected output.
function M.parseSleepDisabled(pmsetOutput)
  if type(pmsetOutput) ~= "string" then return nil end
  local v = pmsetOutput:match("SleepDisabled%s+(%d)")
  if not v then return nil end
  return v == "1"
end

-- ---- Gate: gated-tools list (headless approvals) ---------------------------
-- Normalize the editable gated-tools list: accept a space/comma-separated string,
-- trim, drop blanks, de-dupe (preserving order). Returns a clean space-separated
-- string -- the shape cc-approve.sh matches with `case " $GATE_TOOLS " in`.
function M.parseToolList(str)
  local seen, out = {}, {}
  for tok in tostring(str or ""):gmatch("[^%s,]+") do
    if not seen[tok] then seen[tok] = true; out[#out + 1] = tok end
  end
  return table.concat(out, " ")
end

-- The default gated tools (everything that runs commands or changes files).
M.DEFAULT_GATE_TOOLS = "Bash Write Edit MultiEdit NotebookEdit"

-- ---- Installer: merge our hooks into the user's settings (Part E) ----------
-- Merge `template.hooks` into `existing` settings, idempotently. Per event: if no
-- cc-*.sh hook is wired yet we add the template's group(s) (appending after any
-- of the user's own hooks for that event); if ours are already present (re-run),
-- leave it untouched. All other settings keys are preserved. Returns newSettings,
-- changed(bool) -- so the installer can skip a no-op write.
function M.mergeHooks(existing, template)
  existing = type(existing) == "table" and existing or {}
  local out = {}
  for k, v in pairs(existing) do out[k] = v end  -- preserve non-hook keys
  out.hooks = {}
  if type(existing.hooks) == "table" then
    for ev, groups in pairs(existing.hooks) do out.hooks[ev] = groups end
  end
  local function hasOurs(groups)
    if type(groups) ~= "table" then return false end
    for _, g in ipairs(groups) do
      if type(g) == "table" and type(g.hooks) == "table" then
        for _, h in ipairs(g.hooks) do
          if type(h) == "table" and type(h.command) == "string"
             and h.command:find("cc-", 1, true) then return true end
        end
      end
    end
    return false
  end
  local thooks = (type(template) == "table" and template.hooks) or {}
  local changed = false
  for ev, tgroups in pairs(thooks) do
    if hasOurs(out.hooks[ev]) then
      -- already wired -> idempotent no-op
    elseif out.hooks[ev] == nil then
      out.hooks[ev] = tgroups
      changed = true
    else
      local merged = {}
      for _, g in ipairs(out.hooks[ev]) do merged[#merged + 1] = g end
      for _, g in ipairs(tgroups) do merged[#merged + 1] = g end
      out.hooks[ev] = merged
      changed = true
    end
  end
  return out, changed
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

-- Build claude CLI launch flags from a permission mode (+ effort, reserved). Both
-- optional. `--permission-mode <m>` is a real launch flag (Part C); effort has no
-- documented launch flag (it's set live via /effort), so it's accepted but not
-- emitted. Returns a flat argv-style list (possibly empty).
function M.spawnFlags(mode, effort)  -- luacheck: ignore effort (reserved)
  local flags = {}
  if mode and tostring(mode) ~= "" then
    flags[#flags + 1] = "--permission-mode"
    flags[#flags + 1] = tostring(mode)
  end
  return flags
end

-- ---- Permission-mode cycle (Part C) ----------------------------------------
-- The Shift+Tab cycle order. Optional modes are in the cycle only when enabled.
M.MODE_CYCLE = { "default", "acceptEdits", "plan", "bypassPermissions", "auto" }
local MODE_OPTIONAL = { bypassPermissions = true, auto = true }

-- How many Shift+Tab presses cycle from `cur` to `target`, given which optional
-- modes are enabled (e.g. { bypassPermissions = true }). The cycle wraps. Returns
-- 0 when cur==target or either isn't in the active cycle (a safe no-op).
function M.modeCycleSteps(cur, target, enabledModes)
  enabledModes = enabledModes or {}
  local cycle = {}
  for _, m in ipairs(M.MODE_CYCLE) do
    if not MODE_OPTIONAL[m] or enabledModes[m] then cycle[#cycle + 1] = m end
  end
  local ci, ti
  for i, m in ipairs(cycle) do
    if m == cur then ci = i end
    if m == target then ti = i end
  end
  if not ci or not ti then return 0 end
  return (ti - ci) % #cycle
end

-- Editor-aware spawn spec (F3-F5). Returns a STRUCTURED intent, not a string, that
-- the impure FX layer dispatches on -- so the editor->command mapping is testable.
--   kitty    -> { kind="kitty",    argv={...} }            run via hs.task
--   vscode   -> { kind="vscode",   app, project, openTerminalKey, postType }
--   cursor   -> same as vscode with app="Cursor"
--   else     -> { kind="terminal", applescript=... }        the reliable fallback
-- opts: { terminal, kittyBin, kittyRemote(bool), kittySocket, permissionMode, effort }
function M.spawnSpec(editor, project, task, opts)
  opts = opts or {}
  editor = tostring(editor or ""):lower()
  task = (task and #task > 0) and task or nil
  if editor == "kitty" then
    -- A fresh kitty window with remote control on a known socket (default ON), so
    -- click-to-answer / mode-switch (Part A) work without touching global config.
    local argv = { opts.kittyBin or "kitty" }
    if opts.kittyRemote ~= false then
      for _, f in ipairs(M.kittyLaunchRemoteFlags(opts.kittySocket)) do argv[#argv + 1] = f end
    end
    argv[#argv + 1] = "--directory"; argv[#argv + 1] = project or "."
    argv[#argv + 1] = "claude"
    for _, f in ipairs(M.spawnFlags(opts.permissionMode, opts.effort)) do argv[#argv + 1] = f end
    if task then argv[#argv + 1] = task end  -- one argv element: no shell, no quoting
    return { kind = "kitty", argv = argv }
  elseif editor == "vscode" or editor == "cursor" then
    -- Open the window; "run claude" is best-effort keystrokes into a new integrated
    -- terminal (no supported API), consistent with the project's VS Code stance.
    local post = "claude"
    for _, f in ipairs(M.spawnFlags(opts.permissionMode, opts.effort)) do post = post .. " " .. f end
    if task then post = post .. " " .. shquote(task) end
    return { kind = "vscode", editor = editor,
             app = (editor == "cursor") and "Cursor" or "Visual Studio Code",
             project = project, openTerminalKey = { mods = { "ctrl" }, key = "`" },
             postType = post }
  end
  return { kind = "terminal",
           applescript = M.spawnAppleScript(project, task, { terminal = opts.terminal }) }
end

-- ---- Kitty remote control (detect + enable) --------------------------------
-- `kitty @` (focus/type/send-keys/close, used by Part A) only works when kitty
-- runs with remote control enabled AND a listen_on socket. Default kitty has it
-- OFF. These pure helpers detect the state from kitty.conf and produce an enabled
-- config; the bootstrap reads/writes the file and (for sessions WE spawn) passes
-- launch flags so our windows are controllable regardless of the global config.

-- The default socket. `{kitty_pid}` is expanded by kitty, giving a unique socket
-- per window (so multiple kitty instances don't collide). cc-status.sh captures
-- the resolved KITTY_LISTEN_ON per session, which Part A targets with `--to`.
M.KITTY_SOCKET = "unix:/tmp/cc-kitty-{kitty_pid}"

-- Parse kitty.conf text for remote-control state. Later directives win (kitty's
-- own rule), so the last match is taken. Commented (`#…`) lines don't match.
-- Returns { allow=<value|nil>, listen=<socket|nil>, enabled=bool, usable=bool }.
-- enabled = allow present and not "no"; usable = enabled AND a listen_on is set.
function M.kittyRemoteStatus(confText)
  confText = tostring(confText or "")
  local allow, listen
  for line in (confText .. "\n"):gmatch("(.-)\n") do
    local a = line:match("^%s*allow_remote_control%s+(%S+)")
    if a then allow = a:lower() end
    local l = line:match("^%s*listen_on%s+(%S+)")
    if l then listen = l end
  end
  local enabled = (allow ~= nil) and (allow ~= "no")
  return { allow = allow, listen = listen, enabled = enabled,
           usable = enabled and (listen ~= nil) }
end

-- Return kitty.conf text with remote control enabled on `socket`, plus a boolean
-- saying whether anything changed (so the caller can skip a no-op write). It's
-- idempotent: an existing `allow_remote_control no` is rewritten to `yes`, any
-- other present value (yes/socket-only/...) is left alone, a present `listen_on`
-- is respected, and only the missing directives are appended.
function M.kittyConfWithRemote(confText, socket)
  confText = tostring(confText or "")
  socket = (socket and #socket > 0) and socket or M.KITTY_SOCKET
  local lines, sawAllow, sawListen, rewrote = {}, false, false, false
  for line in (confText .. "\n"):gmatch("(.-)\n") do
    local av = line:match("^%s*allow_remote_control%s+(%S+)")
    if av then
      sawAllow = true
      if av:lower() == "no" then line = "allow_remote_control yes"; rewrote = true end
    elseif line:match("^%s*listen_on%s+(%S+)") then
      sawListen = true
    end
    lines[#lines + 1] = line
  end
  if lines[#lines] == "" then table.remove(lines) end  -- drop the trailing split blank
  if not sawAllow then lines[#lines + 1] = "allow_remote_control yes" end
  if not sawListen then lines[#lines + 1] = "listen_on " .. socket end
  local changed = rewrote or (not sawAllow) or (not sawListen)
  return table.concat(lines, "\n") .. "\n", changed
end

-- Launch flags so a kitty WE spawn has remote control on a known socket, with no
-- dependency on the user's global kitty.conf. The spawned session self-reports
-- KITTY_LISTEN_ON via the status hook, which Part A targets with `kitty @ --to`.
function M.kittyLaunchRemoteFlags(socket)
  socket = (socket and #socket > 0) and socket or M.KITTY_SOCKET
  return { "-o", "allow_remote_control=yes", "--listen-on", socket }
end

-- ---- Kitty effect routing (Part A) -----------------------------------------
-- Panel key name -> kitty `send-key` base token (GLFW/`map` names). Centralized so
-- it's the ONE place to retune once verified live -- send-key swallows errors
-- silently, so a wrong token fails invisibly. Unknown keys pass through as-is.
M.KITTY_KEY = { ["return"] = "enter", escape = "esc", down = "down", up = "up", tab = "tab" }

-- Build a kitty send-key token from a panel keySpec {mods={...}, key=...}: remap
-- the base key (return->enter, escape->esc, ...) and prefix modifiers
-- (shift+/ctrl+/alt+/cmd+). e.g. {mods={"shift"},key="tab"} -> "shift+tab";
-- {mods={},key="return"} -> "enter". Returns nil for an empty base.
function M.kittyKeyToken(keySpec)
  if type(keySpec) ~= "table" then return nil end
  local base = M.KITTY_KEY[keySpec.key] or keySpec.key
  if not base or base == "" then return nil end
  local prefix = ""
  for _, m in ipairs(keySpec.mods or {}) do prefix = prefix .. tostring(m) .. "+" end
  return prefix .. base
end

-- Build the `kitty @` argv (the tail AFTER the kitty binary) for one per-session
-- effect, or nil if unsupported / un-targetable. Routed to headlessly via hs.task
-- (no window focus). `item` carries kitty_window_id / kitty_listen_on / cwd;
-- `payload` = { key=<panel key name>, text=<string> }.
--   focus -> @ [--to S] focus-window --match SEL
--   close -> @ [--to S] close-window --match SEL
--   key   -> @ [--to S] send-key   --match SEL <token>
--   text  -> @ [--to S] send-text  --match SEL -- <text>
function M.kittyCmd(action, item, payload)
  item = item or {}
  payload = payload or {}
  local sel
  if item.kitty_window_id and tostring(item.kitty_window_id) ~= "" then
    sel = "id:" .. tostring(item.kitty_window_id)
  elseif item.cwd and item.cwd ~= "" then
    sel = "cwd:" .. tostring(item.cwd)
  else
    return nil  -- nothing to target
  end
  local argv = { "@" }
  local sock = item.kitty_listen_on
  if sock and sock ~= "" then argv[#argv + 1] = "--to"; argv[#argv + 1] = sock end
  if action == "focus" then
    argv[#argv + 1] = "focus-window"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
  elseif action == "close" then
    argv[#argv + 1] = "close-window"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
  elseif action == "key" then
    local tok = payload.token  -- a ready kitty token (built via M.kittyKeyToken)
    if not tok or tok == "" then return nil end
    argv[#argv + 1] = "send-key"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
    argv[#argv + 1] = tok
  elseif action == "text" then
    if not payload.text or #payload.text == 0 then return nil end
    argv[#argv + 1] = "send-text"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
    argv[#argv + 1] = "--"; argv[#argv + 1] = payload.text
  else
    return nil
  end
  return argv
end

-- ---- Window focus matching (extracted from focusProject; review #4) --------
-- Generic path components that must never be used as a focus candidate (too
-- ambiguous -- they'd grab the wrong window).
M.FOCUS_SKIP = { users = true, programming = true, desktop = true, documents = true,
  projects = true, project = true, src = true, code = true, repos = true, repo = true,
  dev = true, home = true, [""] = true }

-- Does a window title's folder segment (after the last em-dash) contain needle?
-- VS Code titles are "<file> — <folder>"; matching the folder avoids grabbing a
-- window whose task title merely mentions the word (e.g. "Canary alerts").
function M.titleFolderMatch(title, needle)
  if not title or not needle or needle == "" then return false end
  local seg = title:match(".*—%s*(.+)$") or title
  return seg:find(needle, 1, true) ~= nil
end

-- Build focus candidates most-specific first: the session name, then cwd
-- ancestors (deepest first, excluding the basename which usually equals name),
-- lowercased, skipping generic roots + skipUser, de-duped.
function M.focusCandidates(name, cwd, skipUser, skip)
  skip = skip or M.FOCUS_SKIP
  skipUser = string.lower(skipUser or "")
  local out, seen = {}, {}
  local function add(n)
    n = string.lower(n or "")
    if n ~= "" and not skip[n] and n ~= skipUser and not seen[n] then
      seen[n] = true; out[#out + 1] = n
    end
  end
  add(name)
  if cwd then
    local parts = {}
    for p in tostring(cwd):gmatch("[^/]+") do parts[#parts + 1] = p end
    for i = #parts - 1, 1, -1 do add(parts[i]) end  -- ancestors, deepest first
  end
  return out
end

-- ---- New-session UI helpers (F3-F5): folder browser + recents + new project --
-- Strip trailing slash(es), keeping root "/" intact. Used to normalize paths so
-- "/a/b" and "/a/b/" don't read as two different dirs.
function M.normDir(path)
  path = tostring(path or "")
  while #path > 1 and path:sub(-1) == "/" do path = path:sub(1, -2) end
  return path
end

-- Join one path segment onto a base, normalized. pathJoin("/a/", "b") -> "/a/b".
function M.pathJoin(base, name)
  base = M.normDir(base or "")
  name = tostring(name or ""):gsub("^/+", "")
  if base == "" then return name end
  if base == "/" then return "/" .. name end
  return base .. "/" .. name
end

-- Parent of a path: "/a/b/c" -> "/a/b"; "/a" and "/" -> "/".
function M.parentPath(path)
  path = M.normDir(path or "")
  if path == "" or path == "/" then return "/" end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then return "/" end
  return parent
end

-- Breadcrumb trail for a path. "/a/b" -> {{name="/",path="/"},{name="a",path="/a"},
-- {name="b",path="/a/b"}}. The root is always the first crumb.
function M.breadcrumbs(path)
  path = M.normDir(path or "")
  local crumbs = { { name = "/", path = "/" } }
  if path == "" or path == "/" then return crumbs end
  local acc = ""
  for seg in path:gmatch("[^/]+") do
    acc = acc .. "/" .. seg
    crumbs[#crumbs + 1] = { name = seg, path = acc }
  end
  return crumbs
end

-- Should a directory entry be shown in the browser? Drops ".", "..", and dotfiles.
function M.isVisibleDir(name)
  name = tostring(name or "")
  if name == "" or name == "." or name == ".." then return false end
  if name:sub(1, 1) == "." then return false end
  return true
end

-- Case-insensitive sort of dir names, returning a NEW list (input untouched).
-- Ties break on the raw string so the order is total and deterministic.
function M.sortDirs(names)
  local out = {}
  for _, n in ipairs(names or {}) do out[#out + 1] = n end
  table.sort(out, function(a, b)
    local la, lb = tostring(a):lower(), tostring(b):lower()
    if la == lb then return tostring(a) < tostring(b) end
    return la < lb
  end)
  return out
end

-- Recent directories list (F5): a { dirs = { "/a", "/b", ... } } most-recent-first.
M.RECENT_CAP = 12

local function rdirs(state)
  if type(state) == "table" and type(state.dirs) == "table" then return state.dirs end
  return {}
end

-- Safe accessor: a copy of the dirs list (never the internal table).
function M.recentList(state)
  local out = {}
  for _, d in ipairs(rdirs(state)) do out[#out + 1] = d end
  return out
end

-- Prepend `dir` (normalized), de-dupe, cap. Empty/nil dir -> unchanged copy.
function M.recentPush(state, dir, cap)
  cap = cap or M.RECENT_CAP
  dir = M.normDir(dir or "")
  local out = {}
  if dir ~= "" then out[1] = dir end
  for _, d in ipairs(rdirs(state)) do
    if M.normDir(d) ~= dir and #out < cap then out[#out + 1] = d end
  end
  return { dirs = out }
end

-- Merge active session cwds in AFTER the existing recents (so the panel can show
-- live projects before the first spawn), de-duped and capped.
function M.recentSeed(state, activeDirs)
  local out = M.recentList(state)
  local seen = {}
  for _, d in ipairs(out) do seen[M.normDir(d)] = true end
  for _, d in ipairs(activeDirs or {}) do
    local nd = M.normDir(d or "")
    if nd ~= "" and not seen[nd] and #out < M.RECENT_CAP then
      seen[nd] = true
      out[#out + 1] = nd
    end
  end
  return { dirs = out }
end

-- Validate a new project folder name (F3). Returns the trimmed name, or nil if
-- unsafe: empty, "."/"..", containing "/" or NUL, leading "-" (arg-like), or any
-- char outside letters/digits/-/_/./space.
function M.safeFolderName(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or name == "." or name == ".." then return nil end
  if name:find("/", 1, true) or name:find("\0", 1, true) then return nil end
  if name:sub(1, 1) == "-" then return nil end
  if name:find("[^%w%-_. ]") then return nil end
  return name
end

-- Full path for a new project under `parent`, or nil if the name is unsafe.
function M.newProjectPath(parent, name)
  local safe = M.safeFolderName(name)
  if not safe then return nil end
  return M.pathJoin(parent, safe)
end

return M
