-- claude-dashboard.lua  (bootstrap)
--
-- Claude Shepherd: a floating, always-on-top fleet console for Claude Code sessions.
-- One tile per running session with a live status (idle / working / approval /
-- done). Select a tile to Jump, Approve / Deny, Nudge, or Stop. Mirrors onto a
-- physical Stream Deck when one is connected.
--
-- This file is the Hammerspoon BOOTSTRAP. All pure logic (status parsing,
-- sorting, action selection, deck layout) lives in cc-core.lua so it can be
-- unit-tested without Hammerspoon. Here we wire the real effects (window focus,
-- keystrokes, file I/O, webview, Stream Deck) into cc-core's `fx` interface.
--
-- Load it from ~/.hammerspoon/init.lua with:
--   dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")
-- then pick "Reload Config" from the Hammerspoon menu.

local M = {}

-- Load the pure-logic core sitting next to this file.
local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local core = dofile(HERE .. "cc-core.lua")
core.json = hs.json   -- production JSON impl (tests inject a vendored one)

-- Encode a scalar as a JS string literal for evaluateJavaScript. NOTE:
-- hs.json.encode only accepts TABLES (it errors on a bare string), so wrap the
-- value in a 1-element array and strip the [ ] — that reuses hs.json's correct
-- escaping (quotes, newlines, unicode) and yields "...". Using hs.json.encode on
-- a bare string was the silent ⌘V/relabel/close failure.
local function jsString(s) return hs.json.encode({ tostring(s) }):sub(2, -2) end

-- Mirror every print() to a logfile so the Hammerspoon console can stay CLOSED
-- (an open console pops over your work whenever HS activates). Tail it with:
--   tail -f ~/.claude/cc-shepherd.log
local LOG_FILE = os.getenv("CC_LOG_FILE") or (os.getenv("HOME") .. "/.claude/cc-shepherd.log")
do
  local _print = print
  print = function(...)  -- luacheck: ignore (intentional global override)
    _print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    pcall(function()
      local f = io.open(LOG_FILE, "a")
      if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. table.concat(parts, "\t") .. "\n")
        f:close()
      end
    end)
  end
end

-- ---- config -------------------------------------------------------------
-- Honor CC_STATUS_DIR like the shell scripts so tests/dev can redirect state.
local STATUS_DIR = os.getenv("CC_STATUS_DIR") or (os.getenv("HOME") .. "/.claude/cc-status")
local HEARTBEAT  = STATUS_DIR .. "/.panel-alive"
local CONFIG_FILE   = os.getenv("CC_CONFIG_FILE") or (os.getenv("HOME") .. "/.claude/cc-config.json")
local QUEUE_DIR     = os.getenv("CC_QUEUE_DIR") or (os.getenv("HOME") .. "/.claude/cc-queue")
local AUTOPILOT_DIR = os.getenv("CC_AUTOPILOT_DIR") or (os.getenv("HOME") .. "/.claude/cc-autopilot")
local GATE_FLAG     = os.getenv("CC_GATE_FLAG") or (os.getenv("HOME") .. "/.claude/cc-gate.enabled")
local EDITOR_BUNDLES = {
  "com.microsoft.VSCode",
  "com.microsoft.VSCodeInsiders",
  "com.todesktop.230313mzl4w4u92", -- Cursor
}
local POLL_SECONDS  = 1.0
local PANEL_W       = 580
local DEFAULT_THEME = "cards"  -- cards | bar | contrast | dots
local STALE_SECONDS = 90       -- dim a tile after this long with no updates
local PRUNE_NO_SID  = true     -- delete stale tiles that have no session_id (orphans)
local PRUNE_SECONDS = 86400    -- also delete any tile older than this (24h ghost backstop; 0=off)
local FOCUS_DELAY   = 0.12     -- wait after focusing before sending keystrokes
local RESTORE_FOCUS = true     -- return focus to where you were after acting
-- Before typing (nudge/feed/clear/compact), focus the chat input. The Claude Code
-- VS Code extension binds ⌘Esc to focus/unfocus its input ("⌘ Esc to focus or
-- unfocus Claude"). Set to nil for terminal sessions (where typing goes straight
-- to the prompt and this would be wrong).
local FOCUS_CHAT_KEY = { { "cmd" }, "escape" }

-- Stream Deck (optional). Owns the device only if the Elgato app isn't running.
local STREAMDECK_ENABLED  = true
local SD_LONG_PRESS       = 0.7    -- seconds held to count as a "long press"
local SD_LONG_PRESS_STOPS = false  -- if true, long-press a normal tile = Stop
local SD_FALLBACK_KEYS    = 15     -- assume a standard deck if detection fails
local SD_BRIGHTNESS       = 70

-- Global hotkeys (set HOTKEYS_ENABLED = false to disable). {mods, key}.
local HOTKEYS_ENABLED      = true
local HOTKEY_APPROVE_FRONT = { { "cmd", "alt" }, "a" } -- approve the front approval
local HOTKEY_JUMP_NEEDY    = { { "cmd", "alt" }, "j" } -- jump to the session needing you
local HOTKEY_CYCLE         = { { "cmd", "alt" }, "n" } -- jump to the next session

-- Live activity peek: show each active session's latest assistant line.
local ACTIVITY_PEEK  = true
local ACTIVITY_BYTES = 65536  -- transcript tail to scan (big tool outputs need room)
local ACTIVITY_LEN   = 600    -- how much reasoning to keep (the panel clamps it)

-- Orchestrator (Phase 4). DRY-RUN by default: shows what it WOULD spawn without
-- launching anything. Set ORCH_DRY_RUN = false to actually open sessions.
local ORCH_ENABLED     = true
local ORCH_DRY_RUN     = true
local ORCH_TERMINAL    = "Terminal"
local ORCH_DEFAULT_DIR = os.getenv("HOME") .. "/Programming"
local HOTKEY_SPAWN     = { { "cmd", "alt" }, "s" } -- spawn a new Claude session
local HOTKEY_TOGGLE    = { { "cmd", "alt" }, "b" } -- show/hide the panel
-- -------------------------------------------------------------------------

core.STALE_SECONDS = STALE_SECONDS

-- session key (status filename base) -> latest item, for resolving actions.
local byKey = {}
-- Ephemeral display relabels: key -> override name. In-memory only, so a reload
-- clears them (the user asked for relabels NOT to persist across restart).
local labels = {}
local ctxMenu            -- holds the live right-click popup menu (so it isn't GC'd)
local wv                 -- the webview; forward-declared so the controller can push to it
local lastJumpKey = nil  -- for the cycle-jump hotkey
local spawnPrompt        -- forward declaration (defined after FX)
local prevStatus = {}    -- key -> last refresh's status (for auto-feed transitions)
local escalated  = {}    -- key -> true once we've escalated this approval episode
local loadConfig         -- forward declaration (defined near refresh)
local refresh            -- forward declaration (so the controller can repaint now)

-- Find the editor application object across possible bundle ids.
local function findEditorApp()
  for _, bid in ipairs(EDITOR_BUNDLES) do
    local apps = hs.application.applicationsForBundleID(bid)
    if apps and #apps > 0 then return apps[1] end
  end
  return hs.application.find("Code")
      or hs.application.find("Visual Studio Code")
      or hs.application.find("Cursor")
end

-- Generic path components that should never be used as a focus candidate.
local FOCUS_SKIP = { users = true, programming = true, desktop = true,
  documents = true, projects = true, project = true, src = true, code = true,
  repos = true, repo = true, dev = true, home = true, [""] = true }
FOCUS_SKIP[string.lower(os.getenv("USER") or "")] = true

-- Does a window title's folder segment (after the last em-dash) contain needle?
-- VS Code titles are "<file> — <folder>"; matching the folder avoids grabbing a
-- window whose task title merely mentions the word (e.g. sms-bot's "Canary alerts").
local function titleFolderMatch(title, needle)
  local seg = title:match(".*—%s*(.+)$") or title
  return seg:find(needle, 1, true) ~= nil
end

-- Focus the editor window for a session. Tries the session name first, then walks
-- UP the cwd path (parent folders), so a session running in a subfolder (name
-- "frontend") still finds its workspace window (titled "… — autobottom"). Returns
-- true if a specific window was focused (switches Spaces automatically).
local function focusProject(name, cwd)
  print("[cc-dashboard] focus request: " .. tostring(name))
  local app = findEditorApp()
  if not app then
    print("[cc-dashboard] editor app not found")
    hs.alert.show("No editor window found")
    return false
  end
  local windows = app:allWindows()

  -- Build candidates most-specific first: the name, then cwd ancestors (deepest
  -- first), skipping generic roots. De-duped.
  local candidates, seen = {}, {}
  local function add(n)
    n = string.lower(n or "")
    if n ~= "" and not FOCUS_SKIP[n] and not seen[n] then
      seen[n] = true; candidates[#candidates + 1] = n
    end
  end
  add(name)
  if cwd then
    local parts = {}
    for p in tostring(cwd):gmatch("[^/]+") do parts[#parts + 1] = p end
    for i = #parts - 1, 1, -1 do add(parts[i]) end  -- ancestors, deepest first
  end

  -- Pass 1: folder-match each candidate in order; first hit wins.
  for _, needle in ipairs(candidates) do
    for _, w in ipairs(windows) do
      local title = string.lower(w:title() or "")
      if title ~= "" and titleFolderMatch(title, needle) then
        w:focus()
        print("[cc-dashboard] focused (folder: " .. needle .. "): " .. (w:title() or "?"))
        return true
      end
    end
  end
  -- Pass 2: loose substring match on the name only (original fallback behavior).
  local needle = string.lower(name or "")
  if needle ~= "" then
    for _, w in ipairs(windows) do
      local title = string.lower(w:title() or "")
      if title ~= "" and title:find(needle, 1, true) then
        w:focus()
        print("[cc-dashboard] focused (loose): " .. (w:title() or "?"))
        return true
      end
    end
  end
  app:activate()
  print("[cc-dashboard] no title match for '" .. tostring(name) .. "', activated app")
  return false
end

-- ---- the real effects layer (cc-core calls these; tests swap a recorder) ----
local FX = {}
function FX.now() return os.time() end
function FX.log(m) print(m) end

-- Panel geometry persistence (Step 1): remember the size/position the user last
-- left the window so a Hammerspoon reload doesn't snap it back to the default.
-- Stored in hs.settings, exactly like the theme.
function FX.loadGeometry() return hs.settings.get("ccDashboardGeometry") end
function FX.saveGeometry(frame)
  if type(frame) == "table" then
    hs.settings.set("ccDashboardGeometry",
      { x = frame.x, y = frame.y, w = frame.w, h = frame.h })
  end
end

function FX.readDir(path)
  local names = {}
  local ok, iterFn, dirObj = pcall(hs.fs.dir, path)
  if not ok or type(iterFn) ~= "function" then return names end
  for file in iterFn, dirObj do names[#names + 1] = file end
  return names
end

function FX.readFile(path)
  local f = io.open(path, "r"); if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

-- Read only the last maxBytes of a (possibly large) file, e.g. a transcript.
function FX.readTail(path, maxBytes)
  local f = io.open(path, "r"); if not f then return nil end
  local size = f:seek("end")
  local start = math.max(0, size - (maxBytes or 16384))
  f:seek("set", start)
  if start > 0 then f:read("*l") end  -- drop the partial first line (start at a boundary)
  local c = f:read("*a"); f:close(); return c
end

-- Task queue I/O (Phase 4b).
function FX.readQueue(key)
  local c = FX.readFile(QUEUE_DIR .. "/" .. key .. ".json")
  if not c or #c == 0 then return { tasks = {} } end
  local ok, q = pcall(function() return core.json.decode(c) end)
  if ok and type(q) == "table" then return q end
  return { tasks = {} }
end
function FX.writeQueue(key, q)
  hs.fs.mkdir(QUEUE_DIR)
  FX.writeFile(QUEUE_DIR .. "/" .. key .. ".json", core.json.encode(q))
end
function FX.feedTask(name, task) FX.typeIntoWindow(name, task) end

-- Per-session autopilot (Phase 4c-C): a file holding an expiry epoch.
function FX.autopilotExpiry(key)
  return tonumber(FX.readFile(AUTOPILOT_DIR .. "/" .. key) or "") or 0
end
function FX.autopilotActive(key) return FX.autopilotExpiry(key) > FX.now() end
function FX.setAutopilot(key, expiry)
  hs.fs.mkdir(AUTOPILOT_DIR)
  FX.writeFile(AUTOPILOT_DIR .. "/" .. key, tostring(math.floor(expiry)))
end
function FX.clearAutopilot(key) os.remove(AUTOPILOT_DIR .. "/" .. key) end

-- Escalation channels (Phase 4c-A), both off unless enabled in cc-config.json.
function FX.playSound()
  local s = hs.sound.getByName("Submarine") or hs.sound.getByName("Ping")
  if s then s:play() end
end
function FX.push(topic, title, msg)
  if not topic or topic == "" then return end
  pcall(function()
    hs.http.asyncPost("https://ntfy.sh/" .. topic, msg or "",
      { Title = title or "Claude Shepherd", Priority = "high" }, function() end)
  end)
end

function FX.writeFile(path, content)
  local f = io.open(path, "w"); if f then f:write(content); f:close() end
end

function FX.removeStatus(key) os.remove(STATUS_DIR .. "/" .. key .. ".json") end

function FX.writeDecision(key, value)
  FX.writeFile(STATUS_DIR .. "/" .. key .. ".decision", value)
  print("[cc-dashboard] decision " .. tostring(value) .. " -> " .. tostring(key))
end

function FX.focusWindow(name, cwd) return focusProject(name, cwd) end

-- Focus a window, then send after a short delay, then restore prior focus.
local function sendToWindow(name, sendFn)
  local prev = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  hs.timer.doAfter(FOCUS_DELAY, function()
    pcall(sendFn)
    if prev then
      hs.timer.doAfter(FOCUS_DELAY, function() pcall(function() prev:focus() end) end)
    end
  end)
end

function FX.actOnWindow(name, keySpec)
  sendToWindow(name, function() hs.eventtap.keyStroke(keySpec.mods, keySpec.key) end)
end

-- Focus a window, run the (timer-driven) injection sequence, and ONLY restore the
-- prior focus AFTER the final Return. (sendToWindow restores too early for these
-- multi-step sequences — it re-focuses while ⌘V/Return are still pending, so the
-- keystrokes hit the wrong window. That race was the chronic nudge flakiness.)
function FX.typeIntoWindow(name, text)
  print("[cc-dashboard] type -> " .. tostring(name) .. ": " .. tostring(text))
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  hs.timer.doAfter(FOCUS_DELAY, function()
    if FOCUS_CHAT_KEY then hs.eventtap.keyStroke(FOCUS_CHAT_KEY[1], FOCUS_CHAT_KEY[2]) end
    hs.timer.doAfter(0.12, function()
      hs.eventtap.keyStrokes(text)
      hs.timer.doAfter(0.08, function()
        hs.eventtap.keyStroke({}, "return")
        if prevWin then hs.timer.doAfter(0.15, function() pcall(function() prevWin:focus() end) end) end
      end)
    end)
  end)
end

-- Inject text and/or an image into a session via the clipboard + ⌘V instead of
-- char-by-char typing. This is newline-safe (a multi-line list pastes as one
-- block rather than each line submitting early) and a single keystroke, which is
-- more reliable in the VS Code extension. payload = { text=…, imagePath=… }.
-- Best-effort: depends on the chat input being focusable. The prior text
-- clipboard is restored afterwards.
function FX.pasteIntoWindow(name, payload)
  payload = payload or {}
  print("[cc-dashboard] paste -> " .. tostring(name)
    .. (payload.imagePath and " [image]" or "")
    .. (payload.text and (": " .. payload.text) or ""))
  local prevClip = hs.pasteboard.readString()  -- best-effort restore (text only)
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  hs.timer.doAfter(FOCUS_DELAY, function()
    if FOCUS_CHAT_KEY then hs.eventtap.keyStroke(FOCUS_CHAT_KEY[1], FOCUS_CHAT_KEY[2]) end
    hs.timer.doAfter(0.12, function()
      -- Build the paste steps: image first (becomes an attachment), then text.
      local steps = {}
      if payload.imagePath then
        steps[#steps + 1] = function()
          local img = hs.image.imageFromPath(payload.imagePath)
          if img then hs.pasteboard.writeObjects(img) end
        end
      end
      if payload.text and #payload.text > 0 then
        steps[#steps + 1] = function() hs.pasteboard.setContents(payload.text) end
      end
      -- Run each step (set clipboard -> ⌘V) sequentially, submit, THEN restore the
      -- clipboard + prior focus (only after Return, so nothing races the paste).
      local function runFrom(i)
        if i > #steps then
          hs.eventtap.keyStroke({}, "return")
          hs.timer.doAfter(0.15, function()
            if prevClip then pcall(function() hs.pasteboard.setContents(prevClip) end) end
            if prevWin then pcall(function() prevWin:focus() end) end
          end)
          return
        end
        steps[i]()
        hs.eventtap.keyStroke({ "cmd" }, "v")
        hs.timer.doAfter(0.12, function() runFrom(i + 1) end)
      end
      runFrom(1)
    end)
  end)
end

-- Best-effort close the editor window for a session: focus it, then send the
-- VS Code/Cursor "Close Window" chord (⌘⇧W). Unreliable if the title can't be
-- matched (focusProject falls back to just activating the app), so the caller
-- also drops the dashboard tile regardless.
function FX.closeWindow(name)
  print("[cc-dashboard] close window -> " .. tostring(name))
  sendToWindow(name, function() hs.eventtap.keyStroke({ "cmd", "shift" }, "w") end)
end

-- Drive a sequence of keystrokes into a session (e.g. arrow-down ×N + Return to
-- pick an AskUserQuestion option). Focus first, send each key with a small gap,
-- restore prior focus only AFTER the last key (same race-safe pattern as paste).
function FX.sendKeys(name, keys)
  keys = keys or {}
  print("[cc-dashboard] send keys -> " .. tostring(name) .. " (" .. #keys .. " keys)")
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  hs.timer.doAfter(FOCUS_DELAY, function()
    local function step(i)
      if i > #keys then
        if prevWin then hs.timer.doAfter(0.12, function() pcall(function() prevWin:focus() end) end) end
        return
      end
      local k = keys[i]
      hs.eventtap.keyStroke(k.mods or {}, k.key)
      hs.timer.doAfter(0.08, function() step(i + 1) end)
    end
    step(1)
  end)
end

-- Decode a base64 image payload to a temp file and return its path (Step 5).
function FX.writeImageTemp(b64, ext)
  local data = hs.base64.decode(b64)
  if not data then return nil end
  local path = core.tempImagePath(os.getenv("TMPDIR") or "/tmp", tostring(FX.now()), ext or "png")
  local f = io.open(path, "wb"); if not f then return nil end
  f:write(data); f:close()
  return path
end

-- Spawn a new Claude session (Phase 4). Dry-run logs what it WOULD do.
function FX.spawnSession(project, prompt)
  local script = core.spawnAppleScript(project, prompt, { terminal = ORCH_TERMINAL })
  if ORCH_DRY_RUN then
    print("[cc-orch] DRY-RUN would run: " .. script)
    hs.alert.show("Claude Shepherd (dry-run): would spawn in " .. tostring(project))
  else
    print("[cc-orch] spawning in " .. tostring(project))
    hs.osascript.applescript(script)  -- Terminal opens a login shell -> claude on PATH
    hs.alert.show("Claude Shepherd: spawning a session in " .. tostring(project))
  end
end

-- Ask for a project + initial task, then spawn. (Interactive; not unit-tested -
-- the command building it relies on lives in cc-core and is tested.)
function spawnPrompt()
  if not ORCH_ENABLED then return end
  local b1, project = hs.dialog.textPrompt("New Claude session", "Project folder:",
    ORCH_DEFAULT_DIR, "Next", "Cancel")
  if b1 ~= "Next" or not project or project == "" then return end
  local b2, task = hs.dialog.textPrompt("New Claude session", "Initial task (optional):",
    "", "Spawn", "Cancel")
  if b2 ~= "Spawn" then return end
  FX.spawnSession(project, task)
end

-- Relabel + close are driven by IN-WEBVIEW UI (inline rename input / inline
-- confirm), not native hs.dialog — native dialogs activate the Hammerspoon app,
-- which yanks its console window over your work. The right-click popup just asks
-- the webview to start the interaction; the webview posts back "relabel"/"close".

-- Single message bridge. JS posts JSON: {a=action, v=key, text=optional}.
local controller = hs.webview.usercontent.new("cc")
local function handleBridgeMsg(msg)
  local okj, payload = pcall(hs.json.decode, msg.body)
  if not okj or not payload then
    print("[cc-dashboard] bad message: " .. tostring(msg.body))
    return
  end
  local a = tostring(payload.a or "")
  if a == "theme" then
    hs.settings.set("ccDashboardTheme", tostring(payload.v))
    print("[cc-dashboard] theme saved: " .. tostring(payload.v))
    return
  end
  if a == "open-settings" then
    -- Push the current config (or {} = all defaults) + gate state into the form.
    local raw = FX.readFile(CONFIG_FILE)
    local json = (raw and #raw > 0) and raw or "{}"
    local gateOn = (FX.readFile(GATE_FLAG) ~= nil) and "true" or "false"
    pcall(function()
      wv:evaluateJavaScript("showSettings(" .. json .. ", " .. gateOn .. ")")
    end)
    return
  end
  if a == "save-config" then
    local ok, parsed = pcall(function() return hs.json.decode(payload.text or "{}") end)
    if ok and type(parsed) == "table" then
      hs.fs.mkdir(os.getenv("HOME") .. "/.claude")
      FX.writeFile(CONFIG_FILE, hs.json.encode(parsed.config or {}, true))  -- creates if missing
      if parsed.gate == true then FX.writeFile(GATE_FLAG, "")
      else os.remove(GATE_FLAG) end
      print("[cc-dashboard] saved cc-config.json (gate=" .. tostring(parsed.gate) .. ")")
      pcall(function() hs.alert.show("Claude Shepherd: settings saved") end)
    end
    return
  end
  if a == "spawn" then
    spawnPrompt()
    return
  end
  if a == "queue-add" then
    local key = tostring(payload.v or "")
    local task = payload.text and tostring(payload.text) or ""
    if key ~= "" and task ~= "" then
      FX.writeQueue(key, core.queuePush(FX.readQueue(key), task))
      print("[cc-queue] queued for " .. key .. ": " .. task)
    end
    return
  end
  if a == "queue-feed" then
    local key = tostring(payload.v or "")
    local item = byKey[key]
    if item then
      local task, q2 = core.queuePop(FX.readQueue(key))
      if task then FX.feedTask(item.name, task); FX.writeQueue(key, q2) end
    end
    return
  end
  if a == "clear" or a == "compact" then
    local item = byKey[tostring(payload.v or "")]
    if item then
      local cmd   = (a == "clear") and "/clear" or "/compact"
      local title = (a == "clear") and "Clear conversation" or "Auto-compact"
      local msg   = (a == "clear")
        and ("Clear ALL conversation context for " .. item.name ..
             "?\nThis types /clear into its terminal.")
        or  ("Compact (summarize) the conversation for " .. item.name ..
             "?\nThis types /compact into its terminal.")
      pcall(function()
        if hs.dialog.blockAlert(title, msg, "Yes", "Cancel") == "Yes" then
          FX.typeIntoWindow(item.name, cmd)
        end
      end)
    end
    return
  end
  if a == "autopilot" then
    local key = tostring(payload.v or "")
    if key ~= "" then
      if FX.autopilotActive(key) then
        FX.clearAutopilot(key)
        print("[cc-autopilot] off for " .. key)
      else
        local mins = tonumber(core.config(loadConfig(), "policies.autopilot.minutes", 15)) or 15
        FX.setAutopilot(key, FX.now() + mins * 60)
        print("[cc-autopilot] on for " .. key .. " (" .. mins .. "m)")
      end
    end
    return
  end
  local item = byKey[tostring(payload.v or "")]
  if not item then
    print("[cc-dashboard] action '" .. a .. "' for unknown key " .. tostring(payload.v))
    return
  end
  if a == "ctx-menu" then
    -- Right-click: show a real macOS popup menu at the cursor. Its items kick off
    -- IN-WEBVIEW interactions (no native dialog -> no console pop).
    print("[cc-dashboard] context menu for " .. item.key)
    if ctxMenu then pcall(function() ctxMenu:delete() end); ctxMenu = nil end
    ctxMenu = hs.menubar.new(false)  -- false = not in the system menu bar
    if ctxMenu then
      local keyJson  = jsString(item.key)
      local nameJson = jsString(item.label or item.name)
      local shown = item.label or item.name
      ctxMenu:setMenu({
        { title = "Relabel…", fn = function()
            pcall(function() wv:evaluateJavaScript("startRename(" .. keyJson .. ")") end)
          end },
        { title = "-" },
        -- Close uses a native submenu confirm. Native menu clicks are reliable on
        -- this non-activating panel; an in-webview confirm button was not (the
        -- first click just activated the window, so commitClose never fired).
        { title = "Close instance", menu = {
            { title = "Confirm: close " .. shown, fn = function()
                labels[item.key] = nil
                core.handleAction(FX, item, "close")
                refresh()
              end },
            { title = "Cancel", fn = function() end },
        } },
      })
      pcall(function() ctxMenu:popupMenu(hs.mouse.absolutePosition(), true) end)
    end
    return
  end
  if a == "relabel" then
    -- New display name from the inline editor; blank or == real name clears it.
    local txt = (payload.text and tostring(payload.text) or ""):gsub("^%s+", ""):gsub("%s+$", "")
    labels[item.key] = (txt ~= "" and txt ~= item.name) and txt or nil
    print("[cc-dashboard] relabel " .. item.key .. " -> " .. tostring(labels[item.key]))
    refresh()
    return
  end
  if a == "close" then
    labels[item.key] = nil
    core.handleAction(FX, item, "close")
    refresh()
    return
  end
  if a == "nudge" and payload.img and payload.img ~= "" then
    -- Image paste: decode the data URL to a temp file, then paste it (+ any text).
    local parsed = core.parseDataUrl(tostring(payload.img))
    if parsed then
      local path = FX.writeImageTemp(parsed.b64, parsed.ext)
      if path then
        FX.pasteIntoWindow(item.name, { text = payload.text and tostring(payload.text) or nil, imagePath = path })
      else
        print("[cc-dashboard] image paste: failed to write temp file")
      end
    else
      print("[cc-dashboard] image paste: unrecognized data URL")
    end
    return
  end
  core.handleAction(FX, item, a, payload.text and tostring(payload.text) or nil)
end
-- Wrap the bridge so a stray error in a handler is logged, NOT raised — an
-- uncaught callback error makes Hammerspoon yank its console over your work.
controller:setCallback(function(msg)
  local ok, err = pcall(handleBridgeMsg, msg)
  if not ok then print("[cc-dashboard] controller error: " .. tostring(err)) end
end)

-- ---- Stream Deck (optional, plug-and-play) ------------------------------
local sd = { deck = nil, count = SD_FALLBACK_KEYS, size = { w = 72, h = 72 },
             buttons = {}, downAt = {}, blink = false }

-- Render a key image for a session (or a blank dark key when item is nil).
local function sdButtonImage(item)
  local w, h = sd.size.w, sd.size.h
  local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
  if not item then
    c[1] = { type = "rectangle", action = "fill", fillColor = { red = 0.07, green = 0.07, blue = 0.09 } }
    local img = c:imageFromCanvas(); c:delete(); return img
  end
  local st = item.status or "idle"
  local col = core.SD_COLORS[st] or core.SD_COLORS.idle
  if st == "approval" and sd.blink then
    col = { red = col.red * 0.35, green = col.green * 0.35, blue = col.blue * 0.35 }
  end
  c[1] = { type = "rectangle", action = "fill", fillColor = col,
           roundedRectRadii = { xRadius = 10, yRadius = 10 } }
  local name = item.name or "?"
  if #name > 12 then name = name:sub(1, 11) .. "\226\128\166" end
  c[2] = { type = "text", text = name, textColor = { white = 1.0 }, textSize = h * 0.18,
           frame = { x = 3, y = h * 0.12, w = w - 6, h = h * 0.42 }, textAlignment = "center" }
  c[3] = { type = "text", text = core.SD_LABELS[st] or st, textColor = { white = 0.0, alpha = 0.75 },
           textSize = h * 0.13, frame = { x = 3, y = h * 0.60, w = w - 6, h = h * 0.3 },
           textAlignment = "center" }
  local img = c:imageFromCanvas(); c:delete(); return img
end

-- Paint every key from the current (already sorted) session list.
local function sdRender(list)
  if not sd.deck then return end
  local lay = core.deckLayout(sd.count, list)
  for i = 1, sd.count do
    local item = lay.items[i]
    sd.buttons[i] = item and item.key or nil
    local ok, img = pcall(sdButtonImage, item)
    if ok and img then pcall(function() sd.deck:setButtonImage(i, img) end) end
  end
  if lay.overflow > 0 then
    print("[cc-streamdeck] " .. lay.overflow .. " session(s) beyond the "
          .. sd.count .. " keys aren't on the deck (still on the panel)")
  end
end

-- Short press = primary, long press = secondary; cc-core decides the action.
local function sdOnButton(deck, button, isDown)
  if isDown then sd.downAt[button] = hs.timer.secondsSinceEpoch(); return end
  local t0 = sd.downAt[button]; sd.downAt[button] = nil
  local held = t0 and (hs.timer.secondsSinceEpoch() - t0) or 0
  local key = sd.buttons[button]
  local item = key and byKey[key] or nil
  if not item then return end
  local kind = (held >= SD_LONG_PRESS) and "secondary" or "primary"
  local action = core.resolveGesture(item, kind, { longPressStops = SD_LONG_PRESS_STOPS })
  print("[cc-streamdeck] key " .. button .. " " .. kind .. " -> " .. tostring(action) .. " " .. tostring(key))
  core.handleAction(FX, item, action)
end

-- Begin discovery. Fires for already-connected and hot-plugged devices.
local function sdStart()
  if not STREAMDECK_ENABLED or not hs.streamdeck then return end
  local ok = pcall(function()
    hs.streamdeck.init(function(connected, deck)
      if connected then
        sd.deck = deck
        local a, b = deck:buttonLayout()
        if a and b then sd.count = a * b elseif a then sd.count = a end
        if not sd.count or sd.count < 1 then sd.count = SD_FALLBACK_KEYS end
        local oks, sz = pcall(function() return deck:imageSize() end)
        if oks and sz and sz.w and sz.h then sd.size = { w = sz.w, h = sz.h } end
        pcall(function() deck:reset() end)
        pcall(function() deck:setBrightness(SD_BRIGHTNESS) end)
        pcall(function() deck:buttonCallback(sdOnButton) end)
        print("[cc-streamdeck] connected: " .. sd.count .. " keys @ "
              .. sd.size.w .. "x" .. sd.size.h)
        sdRender(refreshList())
      else
        print("[cc-streamdeck] disconnected")
        if sd.deck == deck then sd.deck = nil; sd.buttons = {} end
      end
    end)
  end)
  if not ok then print("[cc-streamdeck] init failed") end
end

-- The HTML/CSS/JS for the panel. Native pushes data via window.ccUpdate().
-- __INIT_THEME__ is replaced below with the saved theme before showing.
local HTML = [[
<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: dark; }
  html,body { margin:0; padding:0; background:#15161b; color:#e8e9ee;
              font-family:-apple-system,system-ui,sans-serif; -webkit-user-select:none; }

  /* header with theme switcher */
  #bar { display:flex; align-items:center; justify-content:space-between;
         padding:6px 10px; gap:8px; border-bottom:1px solid #2c2f3a; }
  #bar .t { color:#8a8d99; font-size:11px; letter-spacing:.04em; text-transform:uppercase; }
  #bar .right { display:flex; align-items:center; gap:6px; }
  #theme { background:#21232c; color:#e8e9ee; border:1px solid #2c2f3a;
           border-radius:8px; font-size:12px; padding:3px 6px; }
  #spawn { background:#21232c; color:#8fd4a3; border:1px solid #2c5; border-radius:8px;
           font-size:12px; padding:3px 8px; cursor:pointer; }
  #spawn:hover { background:#27332b; }
  #settings-btn { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a;
           border-radius:8px; font-size:13px; padding:3px 8px; cursor:pointer; }

  /* settings overlay */
  #settings { display:none; position:fixed; inset:0; background:#15161b; z-index:10;
              flex-direction:column; }
  #settings.show { display:flex; }
  #s-head { display:flex; align-items:center; justify-content:space-between;
            padding:10px 12px; border-bottom:1px solid #2c2f3a; font-weight:700; color:#fff; }
  .s-x { background:none; border:none; color:#8a8d99; font-size:14px; cursor:pointer; }
  #s-body { flex:1; overflow-y:auto; padding:10px 12px; }
  .s-sec { color:#8a8d99; font-size:11px; text-transform:uppercase; letter-spacing:.04em;
           margin:12px 0 4px; border-bottom:1px solid #2c2f3a; padding-bottom:3px; }
  .s-row { display:flex; align-items:center; gap:6px; font-size:13px; color:#d7d9e0;
           padding:4px 0; flex-wrap:wrap; }
  .s-lbl { color:#8a8d99; font-size:11px; margin:8px 0 3px; }
  .s-num { width:54px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a; border-radius:6px; padding:2px 5px; }
  .s-txt { flex:1; min-width:120px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a; border-radius:6px; padding:2px 6px; }
  .s-area { width:100%; height:54px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
            border-radius:6px; padding:5px 7px; font-family:ui-monospace,monospace; font-size:12px; box-sizing:border-box; }
  #s-foot { display:flex; gap:8px; padding:10px 12px; border-top:1px solid #2c2f3a; }
  #s-save { background:#21232c; color:#8fd4a3; border:1px solid #2c5; border-radius:8px; font-size:13px; padding:6px 14px; cursor:pointer; }
  #s-foot button:not(#s-save) { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px; font-size:13px; padding:6px 14px; cursor:pointer; }

  /* shared bits */
  #grid { display:grid; gap:8px; padding:10px; }
  .tile { cursor:pointer; position:relative; }
  .tile.sel { outline:2px solid #6ea8fe; outline-offset:1px; }
  .tile.stale { opacity:.45; }
  .tile.escalate { box-shadow:0 0 0 2px #ef4444, 0 0 12px #ef4444; }
  .name { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .dot  { border-radius:50%; flex:0 0 auto; }
  .meta { font-size:11px; color:#8a8d99; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  #empty { color:#6b7280; font-size:13px; padding:18px; text-align:center; }
  #renamebar, #confirmbar { display:none; align-items:center; gap:6px; padding:8px 12px;
    background:#161821; border-bottom:1px solid #2c2f3a; }
  #renamebar.show, #confirmbar.show { display:flex; }
  #renamebar-label { font-size:12px; color:#9fb6d6; }
  #confirmbar-label { font-size:12px; color:#e8e9ee; flex:1; }
  #renamebar-input { flex:1; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
    border-radius:6px; font-size:12px; padding:4px 6px; font-family:inherit; }
  #renamebar button, #confirmbar button { background:#21232c; color:#cfd2db;
    border:1px solid #2c2f3a; border-radius:6px; font-size:12px; padding:4px 10px; cursor:pointer; }
  #renamebar button:hover, #confirmbar button:hover { background:#2b2e39; }
  #confirmbar button.danger { border-color:#ef4444; color:#f3a1a1; }

  /* status colors, shared by all themes via the --c variable */
  .s-idle     { --c:#6b7280; }
  .s-working  { --c:#f5b50a; }
  .s-done     { --c:#22c55e; }
  .s-approval { --c:#ef4444; }

  /* THEME: cards (default) ------------------------------------------------ */
  .theme-cards #grid { grid-template-columns:repeat(auto-fill,minmax(170px,1fr)); }
  .theme-cards .tile { display:grid; grid-template-areas:"name name" "dot label" "meta meta";
                       grid-template-columns:auto 1fr; gap:4px 8px; align-items:center;
                       background:#21232c; border:1px solid #2c2f3a; border-radius:12px;
                       padding:10px 12px; transition:transform .06s, background .15s; }
  .theme-cards .tile:hover  { background:#272a35; }
  .theme-cards .tile:active { transform:scale(.98); }
  .theme-cards .name  { grid-area:name; color:#e8e9ee; font-size:14px; font-weight:600; }
  .theme-cards .dot   { grid-area:dot; width:10px; height:10px; background:var(--c); }
  .theme-cards .label { grid-area:label; font-size:12px; color:#aeb1bd; }
  .theme-cards .meta  { grid-area:meta; }
  .theme-cards .s-approval { border-color:var(--c); }
  .theme-cards .s-approval .dot { animation:pulse 1s infinite; }

  /* THEME: bar (compact single row of pills) ------------------------------ */
  .theme-bar #grid { display:flex; flex-wrap:wrap; }
  .theme-bar .tile { display:inline-flex; align-items:center; gap:7px;
                     background:#21232c; border:1px solid #2c2f3a; border-radius:999px;
                     padding:6px 12px; }
  .theme-bar .tile:hover { background:#272a35; }
  .theme-bar .dot   { width:9px; height:9px; background:var(--c); }
  .theme-bar .name  { color:#e8e9ee; font-size:13px; font-weight:600; }
  .theme-bar .label, .theme-bar .meta { display:none; }
  .theme-bar .s-approval .dot { animation:pulse 1s infinite; }

  /* THEME: contrast (large, bold, thick colored border) ------------------- */
  .theme-contrast #grid { grid-template-columns:repeat(auto-fill,minmax(210px,1fr)); }
  .theme-contrast .tile { display:grid; grid-template-areas:"dot name" "dot label" "dot meta";
                          grid-template-columns:auto 1fr; column-gap:12px; align-items:center;
                          background:#1b1d24; border:2px solid var(--c); border-radius:14px;
                          padding:14px 16px; }
  .theme-contrast .dot   { grid-area:dot; width:18px; height:18px; background:var(--c); }
  .theme-contrast .name  { grid-area:name; color:#ffffff; font-size:16px; font-weight:700; }
  .theme-contrast .label { grid-area:label; color:#d7d9e0; font-size:13px; }
  .theme-contrast .meta  { grid-area:meta; }
  .theme-contrast .s-approval { animation:pulse 1.2s infinite; }

  /* THEME: dots (minimal vertical list) ----------------------------------- */
  .theme-dots #grid { grid-template-columns:1fr; gap:2px; padding:6px; }
  .theme-dots .tile { display:flex; align-items:center; gap:8px; padding:5px 8px;
                      border-radius:6px; }
  .theme-dots .tile:hover { background:#21232c; }
  .theme-dots .dot   { width:8px; height:8px; background:var(--c); }
  .theme-dots .name  { color:#cfd2db; font-size:12px; }
  .theme-dots .label, .theme-dots .meta { display:none; }
  .theme-dots .s-approval .dot { animation:pulse 1s infinite; }

  /* detail / control panel (shared across themes) ------------------------- */
  #detail { border-top:1px solid #2c2f3a; padding:10px 12px; display:none; }
  #detail.show { display:block; }
  #d-head { display:flex; align-items:center; gap:8px; }
  #d-dot  { width:10px; height:10px; border-radius:50%; background:var(--dc,#6b7280); flex:0 0 auto; }
  #d-name { font-size:14px; font-weight:700; color:#fff; }
  #d-status { font-size:11px; color:#8a8d99; margin-left:auto; }
  #d-prompt { font-size:12px; color:#aeb1bd; margin:8px 0 0; max-height:48px; overflow:hidden; }
  #d-ask { display:none; margin:8px 0 0; }
  #d-ask .ask-q { font-size:12px; color:#cfd2db; margin-top:6px; }
  #d-ask .ask-opts { display:flex; flex-wrap:wrap; gap:6px; margin-top:4px; }
  #d-ask .ask-opt { font-size:11px; color:#cfe0f5; background:#21232c; border:1px solid #3a4a66;
    border-radius:8px; padding:3px 10px; cursor:pointer; font-family:inherit; }
  #d-ask .ask-opt:hover { background:#2b3346; border-color:#5a7bb0; }
  #d-ask .ask-hint { font-size:11px; color:#6b7280; margin-top:6px; }
  #d-meta { display:none; font-size:11px; color:#8a8d99; margin:8px 0 0; }
  #d-controls { display:flex; flex-wrap:wrap; gap:10px; margin:8px 0 0; }
  #d-controls .ctl { font-size:11px; color:#9fb6d6; display:flex; align-items:center; gap:4px; }
  #d-controls select { background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
    border-radius:6px; font-size:11px; padding:2px 4px; }
  #d-activity, #d-pending { font-size:12px; margin:6px 0 0; cursor:pointer;
    display:-webkit-box; -webkit-box-orient:vertical; -webkit-line-clamp:2; overflow:hidden; }
  #d-activity { color:#9fb6d6; }
  #d-pending  { color:#f3b1b1; }
  #d-activity.expanded, #d-pending.expanded { -webkit-line-clamp:unset; }
  .exp-hint { color:#6b7280; font-size:11px; }
  #d-actions { display:flex; flex-wrap:wrap; gap:6px; margin-top:10px; }
  #d-actions button { background:#21232c; color:#e8e9ee; border:1px solid #2c2f3a;
                      border-radius:8px; font-size:12px; padding:5px 10px; cursor:pointer; }
  #d-actions button:hover { background:#2b2e39; }
  #b-approve { border-color:#22c55e; color:#7ee2a0; }
  #b-deny, #b-stop { border-color:#ef4444; color:#f3a1a1; }
  #b-clear { border-color:#b9772a; color:#e6b277; }
  .sep { flex-basis:100%; height:0; }
  #nudge-row { display:flex; gap:6px; margin-top:8px; align-items:flex-start; }
  #nudge { flex:1; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
           border-radius:8px; font-size:12px; padding:5px 8px; font-family:inherit;
           line-height:1.4; resize:vertical; min-height:24px; max-height:400px; overflow-y:auto; }
  #nudge-chip { display:none; font-size:11px; color:#9fb6d6; margin-top:6px; }
  #nudge-chip.show { display:flex; align-items:center; gap:6px; }
  #nudge-chip button { background:none; border:none; color:#8a8d99; cursor:pointer;
             font-size:12px; padding:0 2px; }
  #b-nudge, #b-queue { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a;
             border-radius:8px; font-size:12px; padding:5px 10px; cursor:pointer; }
  #queue-row { display:flex; align-items:center; gap:8px; margin-top:8px; }
  #q-count { font-size:12px; color:#9fb6d6; flex:1; }
  #b-feed { background:#21232c; color:#8fd4a3; border:1px solid #2c5; border-radius:8px;
            font-size:12px; padding:5px 10px; cursor:pointer; }
  .qbadge { color:#9fb6d6; }
</style></head>
<body class="theme-__INIT_THEME__" data-theme="__INIT_THEME__">
  <div id="bar">
    <span class="t">Claude sessions</span>
    <span class="right">
      <button id="spawn" onclick="send('spawn','')" title="Spawn a new Claude session">+ New</button>
      <button id="settings-btn" onclick="openSettings()" title="Settings">⚙</button>
      <select id="theme" onchange="onThemeChange()">
        <option value="cards">Cards</option>
        <option value="bar">Bar</option>
        <option value="contrast">Contrast</option>
        <option value="dots">Dots</option>
      </select>
    </span>
  </div>
  <div id="renamebar">
    <span id="renamebar-label">Rename:</span>
    <input id="renamebar-input" onkeydown="renameKeydown(event)">
    <button onclick="commitRename()">Set</button>
    <button onclick="hideBars()">Cancel</button>
  </div>
  <div id="confirmbar">
    <span id="confirmbar-label"></span>
    <button class="danger" onclick="commitClose()">Close</button>
    <button onclick="hideBars()">Cancel</button>
  </div>
  <div id="grid"></div>
  <div id="empty">Waiting for Claude Code sessions...<br>Start a session in any project.</div>

  <div id="detail">
    <div id="d-head">
      <span id="d-dot"></span>
      <span id="d-name"></span>
      <span id="d-status"></span>
    </div>
    <div id="d-pending" onclick="toggleExpand('pending')"></div>
    <div id="d-ask"></div>
    <div id="d-activity" onclick="toggleExpand('activity')"></div>
    <div id="d-prompt"></div>
    <div id="d-meta"></div>
    <div id="d-actions">
      <button id="b-jump"    onclick="act('focus')">Jump</button>
      <button id="b-approve" onclick="act('approve')">Approve</button>
      <button id="b-deny"    onclick="act('deny')">Deny</button>
      <button id="b-stop"    onclick="act('stop')">Stop</button>
      <button id="b-auto"    onclick="act('autopilot')">Autopilot</button>
      <span class="sep"></span>
      <button id="b-clear"   onclick="act('clear')">Clear</button>
      <button id="b-compact" onclick="act('compact')">Compact</button>
    </div>
    <div id="d-controls">
      <label class="ctl">Effort
        <select id="effort" onchange="onEffortChange()">
          <option value="low">Low</option>
          <option value="medium">Medium</option>
          <option value="high">High</option>
          <option value="xhigh">XHigh</option>
        </select>
      </label>
    </div>
    <div id="nudge-row">
      <textarea id="nudge" rows="1" placeholder="Nudge now, or Queue for later... (Enter sends, Shift+Enter newline, paste an image)" onkeydown="onNudgeKey(event)" oninput="autoGrow(this)"></textarea>
      <button id="b-nudge" onclick="sendNudge()">Send</button>
      <button id="b-queue" onclick="queueAdd()">Queue</button>
    </div>
    <div id="nudge-chip"><span id="nudge-chip-label"></span><button onclick="clearImage()" title="Remove image">✕</button></div>
    <div id="queue-row">
      <span id="q-count"></span>
      <button id="b-feed" onclick="act('queue-feed')">Feed next</button>
    </div>
  </div>

  <div id="settings">
    <div id="s-head"><span>Claude Shepherd settings</span><button class="s-x" onclick="closeSettings()">✕</button></div>
    <div id="s-body">
      <label class="s-row"><input type="checkbox" id="s-gate"> Arm the approval gate (route permission prompts to this panel)</label>
      <div class="s-sec">Queue</div>
      <label class="s-row"><input type="checkbox" id="s-q-auto"> Auto-feed the next queued task when a session finishes</label>
      <label class="s-row"><input type="checkbox" id="s-q-dry"> Dry-run (log what it would feed, don't send)</label>
      <div class="s-sec">Escalation (a waiting approval nags harder)</div>
      <label class="s-row"><input type="checkbox" id="s-e-en"> Enable escalation</label>
      <label class="s-row">After <input type="number" id="s-e-min" class="s-num" min="1"> minutes</label>
      <label class="s-row"><input type="checkbox" id="s-e-snd"> Play a sound</label>
      <label class="s-row"><input type="checkbox" id="s-e-push"> Push to ntfy topic <input type="text" id="s-e-topic" class="s-txt" placeholder="my-topic"></label>
      <div class="s-sec">Editor</div>
      <label class="s-row"><input type="checkbox" id="s-focus-pop"> Pop the editor window when a session finishes or needs you</label>
      <div class="s-sec">Policies (gate must be armed)</div>
      <label class="s-row"><input type="checkbox" id="s-p-rep"> Auto-approve a command already approved this session</label>
      <label class="s-row"><input type="checkbox" id="s-ap-en"> Enable per-session Autopilot, window of <input type="number" id="s-ap-min" class="s-num" min="1"> min</label>
      <label class="s-row"><input type="checkbox" id="s-pat-en"> Enable pattern rules</label>
      <div class="s-lbl">Auto-allow (one per line, e.g. Read or Bash(npm test*))</div>
      <textarea id="s-pat-allow" class="s-area"></textarea>
      <div class="s-lbl">Auto-deny (wins over allow)</div>
      <textarea id="s-pat-deny" class="s-area"></textarea>
    </div>
    <div id="s-foot">
      <button id="s-save" onclick="saveSettings()">Save</button>
      <button onclick="closeSettings()">Cancel</button>
    </div>
  </div>

  <script>
    var LABELS = { idle:"Idle", working:"Working",
                   approval:"Needs you", done:"Ready for you" };
    var COLORS = { idle:"#6b7280", working:"#f5b50a", done:"#22c55e", approval:"#ef4444" };
    var lastItems = [];
    var selectedKey = null;
    var detailExpanded = { pending:false, activity:false };
    var pendingImage = null;  // data URL of an image pasted into the input

    function send(a, v, text, img){
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify({a:a, v:v||"", text:text||"", img:img||""})); }
      catch(e){ console.log("send error", e); }
    }
    function act(a){ if(selectedKey) send(a, selectedKey); }
    // Grow the textarea with its content, up to the CSS max-height.
    function autoGrow(el){ el.style.height = "auto"; el.style.height = Math.min(el.scrollHeight, 220) + "px"; }
    function resetInput(el){ el.value=""; el.style.height="auto"; clearImage(); }
    function clearImage(){ pendingImage = null; document.getElementById("nudge-chip").classList.remove("show"); }
    function setImage(dataUrl){
      pendingImage = dataUrl;
      document.getElementById("nudge-chip-label").textContent = "📎 image attached";
      document.getElementById("nudge-chip").classList.add("show");
    }
    function sendNudge(){
      var el = document.getElementById("nudge");
      var t = (el.value || "").trim();
      if(selectedKey && (t || pendingImage)){ send("nudge", selectedKey, t, pendingImage); resetInput(el); }
    }
    // Enter sends; Shift+Enter inserts a newline (mirrors the Claude chat input).
    function onNudgeKey(e){ if(e.key === "Enter" && !e.shiftKey){ e.preventDefault(); sendNudge(); } }
    function queueAdd(){
      var el = document.getElementById("nudge");
      var t = (el.value || "").trim();
      if(selectedKey && t){ send("queue-add", selectedKey, t); resetInput(el); }
    }
    // Capture a pasted image as a data URL; plain text keeps default paste.
    (function(){
      var el = document.getElementById("nudge");
      if(!el) return;
      el.addEventListener("paste", function(e){
        var items = (e.clipboardData && e.clipboardData.items) || [];
        for(var i=0;i<items.length;i++){
          if(items[i].type && items[i].type.indexOf("image") === 0){
            e.preventDefault();
            var file = items[i].getAsFile();
            var r = new FileReader();
            r.onload = function(){ setImage(r.result); };
            r.readAsDataURL(file);
            return;
          }
        }
      });
    })();

    // Right-click a tile -> ask Lua to show a REAL macOS popup menu at the cursor.
    // (hs.webview renders its own native menu over any in-page one, so we don't
    // try to draw the menu in HTML.)
    function showCtx(e, key){ e.preventDefault(); send("ctx-menu", key); }

    // Relabel / Close happen via in-panel bars (no native dialog -> no console pop).
    // Lua's popup-menu items call startRename/startClose; these post the result back.
    var renameKey = null, closeKey = null;
    function hideBars(){
      renameKey = null; closeKey = null;
      document.getElementById("renamebar").classList.remove("show");
      document.getElementById("confirmbar").classList.remove("show");
    }
    function startRename(key){
      var it = findItem(key); if(!it) return;
      closeKey = null; document.getElementById("confirmbar").classList.remove("show");
      renameKey = key;
      var inp = document.getElementById("renamebar-input");
      inp.value = it.label || it.name || "";
      document.getElementById("renamebar").classList.add("show");
      inp.focus(); inp.select();
    }
    function commitRename(){
      if(renameKey){ send("relabel", renameKey, (document.getElementById("renamebar-input").value||"").trim()); }
      hideBars();
    }
    function renameKeydown(e){
      if(e.key === "Enter"){ e.preventDefault(); commitRename(); }
      else if(e.key === "Escape"){ e.preventDefault(); hideBars(); }
    }
    function startClose(key, name){
      renameKey = null; document.getElementById("renamebar").classList.remove("show");
      closeKey = key;
      document.getElementById("confirmbar-label").textContent = "Close " + (name || "this session") + "?";
      document.getElementById("confirmbar").classList.add("show");
    }
    function commitClose(){ if(closeKey){ send("close", closeKey); } hideBars(); }
    // Lua's ⌘V handler calls these, because hs.webview inputs don't receive the
    // standard paste shortcut on their own (Hammerspoon provides no Edit menu).
    function insertIntoNudge(t){
      var el = document.getElementById("nudge");
      if(!el) return;
      el.focus();
      var s  = (el.selectionStart != null) ? el.selectionStart : el.value.length;
      var en = (el.selectionEnd   != null) ? el.selectionEnd   : el.value.length;
      el.value = el.value.slice(0, s) + t + el.value.slice(en);
      el.selectionStart = el.selectionEnd = s + t.length;
      autoGrow(el);
    }

    function onThemeChange(){
      var t = document.getElementById("theme").value;
      document.body.className = "theme-" + t;
      send("theme", t);
    }

    function cv(o, path, def){
      var p = path.split("."), n = o;
      for(var i=0;i<p.length;i++){
        if(n==null || typeof n!=="object") return def;
        var k = p[i]; n = n[k];
        if(n===undefined) return def;
      }
      return n===undefined ? def : n;
    }
    function openSettings(){ send("open-settings"); }
    function closeSettings(){ document.getElementById("settings").classList.remove("show"); }
    function showSettings(cfg, gateOn){
      cfg = cfg || {};
      function ck(id,v){ document.getElementById(id).checked = !!v; }
      function val(id,v){ document.getElementById(id).value = v; }
      ck("s-gate", gateOn);
      ck("s-q-auto", cv(cfg,"queue.autofeed",false));
      ck("s-q-dry",  cv(cfg,"queue.dryRun",false));
      ck("s-e-en",   cv(cfg,"escalation.enabled",false));
      val("s-e-min", cv(cfg,"escalation.minutes",5));
      ck("s-e-snd",  cv(cfg,"escalation.sound",false));
      ck("s-e-push", cv(cfg,"escalation.push",false));
      val("s-e-topic", cv(cfg,"escalation.pushTopic",""));
      ck("s-focus-pop", cv(cfg,"focus.popEditor",false));
      ck("s-p-rep",  cv(cfg,"policies.approveRepeats",false));
      ck("s-ap-en",  cv(cfg,"policies.autopilot.enabled",false));
      val("s-ap-min", cv(cfg,"policies.autopilot.minutes",15));
      ck("s-pat-en", cv(cfg,"policies.patterns.enabled",false));
      val("s-pat-allow", (cv(cfg,"policies.patterns.autoAllow",[])||[]).join("\n"));
      val("s-pat-deny",  (cv(cfg,"policies.patterns.autoDeny",[])||[]).join("\n"));
      document.getElementById("settings").classList.add("show");
    }
    function lines(id){
      return (document.getElementById(id).value||"").split("\n")
        .map(function(s){return s.trim();}).filter(function(s){return s.length>0;});
    }
    function saveSettings(){
      function ck(id){ return document.getElementById(id).checked; }
      function num(id,d){ var n=parseInt(document.getElementById(id).value,10); return isNaN(n)?d:n; }
      function txt(id){ return document.getElementById(id).value||""; }
      var config = {
        queue: { autofeed: ck("s-q-auto"), dryRun: ck("s-q-dry") },
        escalation: { enabled: ck("s-e-en"), minutes: num("s-e-min",5), sound: ck("s-e-snd"),
                      push: ck("s-e-push"), pushTopic: txt("s-e-topic") },
        focus: { popEditor: ck("s-focus-pop") },
        policies: {
          approveRepeats: ck("s-p-rep"),
          autopilot: { enabled: ck("s-ap-en"), minutes: num("s-ap-min",15) },
          patterns: { enabled: ck("s-pat-en"), autoAllow: lines("s-pat-allow"), autoDeny: lines("s-pat-deny") }
        }
      };
      send("save-config", "", JSON.stringify({ config: config, gate: ck("s-gate") }));
      closeSettings();
    }

    function fmtAge(since){
      if(!since) return "";
      var s = Math.max(0, Math.floor(Date.now()/1000) - since);
      if(s < 60) return s + "s";
      if(s < 3600) return Math.floor(s/60) + "m";
      return Math.floor(s/3600) + "h";
    }
    function findItem(key){
      for(var i=0;i<lastItems.length;i++){ if(lastItems[i].key === key) return lastItems[i]; }
      return null;
    }
    function selectTile(key){
      if(key !== selectedKey){ detailExpanded = { pending:false, activity:false }; }
      selectedKey = key; renderDetail(); paintSelection();
    }
    function toggleExpand(which){ detailExpanded[which] = !detailExpanded[which]; applyExpand(); }
    function applyExpand(){
      document.getElementById("d-pending").classList.toggle("expanded", detailExpanded.pending);
      document.getElementById("d-activity").classList.toggle("expanded", detailExpanded.activity);
    }
    function paintSelection(){
      var tiles = document.querySelectorAll(".tile");
      tiles.forEach(function(t){ t.classList.toggle("sel", t.dataset.key === selectedKey); });
    }

    function onEffortChange(){
      var lvl = document.getElementById("effort").value;
      if(selectedKey) send("effort", selectedKey, lvl);
    }
    // Render the options of a pending AskUserQuestion so they're visible in the
    // panel (today: read-only + Jump to answer; clickable answering comes later).
    function renderAsk(it){
      var el = document.getElementById("d-ask");
      var ask = it.pending && it.pending.ask;
      if(!ask || !ask.length){ el.style.display="none"; el.innerHTML=""; return; }
      // Clickable options: clicking drives the picker (arrow-down to it + Enter).
      // qi=question index, oi=option index. (Best-effort for multi-question asks.)
      el.innerHTML = ask.map(function(q, qi){
        var opts = (q.options||[]).map(function(o, oi){
          return '<button class="ask-opt" title="'+esc(o.description||"")
               + '" onclick="answerAsk('+qi+','+oi+')">'+esc(o.label)+'</button>';
        }).join("");
        return '<div class="ask-q">'+(q.header?('<b>'+esc(q.header)+'</b> · '):'')+esc(q.question)+'</div>'
             + '<div class="ask-opts">'+opts+'</div>';
      }).join("") + '<div class="ask-hint">Click an option — auto-selects on Kitty; jumps to the picker in VS Code (mouse-only there)</div>';
      el.style.display="block";
    }
    function answerAsk(qi, oi){ if(selectedKey) send("answer", selectedKey, String(oi)); }
    // Small badges: detected editor + live permission mode + effort.
    function renderMeta(it){
      var el = document.getElementById("d-meta"), bits = [];
      if(it.editor) bits.push(it.editor);
      if(it.permission_mode) bits.push("mode: " + it.permission_mode);
      if(it.effort) bits.push("effort: " + it.effort);
      if(!bits.length){ el.style.display="none"; el.textContent=""; return; }
      el.textContent = bits.join("  ·  "); el.style.display="block";
      var ef = document.getElementById("effort"); if(ef && it.effort) ef.value = it.effort;
    }

    function renderDetail(){
      var d = document.getElementById("detail");
      var it = selectedKey ? findItem(selectedKey) : null;
      if(!it){ d.classList.remove("show"); selectedKey=null; return; }
      d.classList.add("show");
      var st = it.status || "idle";
      document.getElementById("d-dot").style.setProperty("--dc", COLORS[st] || "#6b7280");
      document.getElementById("d-dot").style.background = COLORS[st] || "#6b7280";
      document.getElementById("d-name").textContent = it.label || it.name || "?";
      document.getElementById("d-status").textContent =
        (LABELS[st] || st) + (it.since ? " - " + fmtAge(it.since) : "") + (it.stale ? " - stale" : "");
      var pend = document.getElementById("d-pending");
      if(it.pending && it.pending.summary){
        pend.textContent = "Wants: " + it.pending.summary + (it.gate === "waiting" ? "  (hands-free approve)" : "");
        pend.style.display = "block";
      } else { pend.style.display = "none"; }
      var ac = document.getElementById("d-activity");
      if(it.activity){ ac.textContent = (st==="approval" ? "Why: " : "Doing: ") + it.activity; ac.style.display="block"; }
      else { ac.style.display="none"; }
      var pr = document.getElementById("d-prompt");
      if(it.last_prompt){ pr.textContent = "Last: " + it.last_prompt; pr.style.display="block"; }
      else { pr.style.display="none"; }
      renderAsk(it);
      renderMeta(it);
      var n = it.queue || 0;
      document.getElementById("q-count").textContent = n>0 ? ("Queue: " + n) : "Queue: empty";
      document.getElementById("b-feed").style.display = n>0 ? "inline-block" : "none";
      var ba = document.getElementById("b-auto");
      ba.textContent = it.autopilot ? "Autopilot: ON" : "Autopilot";
      ba.style.color = it.autopilot ? "#8fd4a3" : "#e8e9ee";
      applyExpand();
    }

    window.ccUpdate = function(items){
      lastItems = items || [];
      var grid  = document.getElementById("grid");
      var empty = document.getElementById("empty");
      if(lastItems.length === 0){
        grid.innerHTML=""; empty.style.display="block";
        selectedKey=null; renderDetail();
        return;
      }
      empty.style.display="none";
      grid.innerHTML = lastItems.map(function(it){
        var st = it.status || "idle";
        var label = LABELS[st] || st;
        var meta = "";
        if(st === "approval" && it.pending && it.pending.summary){
          meta = "wants: " + it.pending.summary;
        } else if(it.since){
          meta = fmtAge(it.since);
        }
        if(it.queue > 0){ meta = (meta ? meta + " · " : "") + "+" + it.queue + " queued"; }
        if(it.autopilot){ meta = (meta ? meta + " · " : "") + "🛫 autopilot"; }
        var cls = "tile s-" + st + (it.stale ? " stale" : "") + (it.escalate ? " escalate" : "") + (it.key === selectedKey ? " sel" : "");
        return '<div class="'+cls+'" data-key="'+esc(it.key)+'" onclick="selectTile(\''+esc(it.key)+'\')" ondblclick="send(\'focus\',\''+esc(it.key)+'\')" oncontextmenu="showCtx(event,\''+esc(it.key)+'\')" title="Double-click to jump · right-click for more">'
             + '<span class="dot"></span>'
             + '<span class="name">'+esc(it.label || it.name)+'</span>'
             + '<span class="label">'+label+'</span>'
             + '<span class="meta">'+esc(meta)+'</span>'
             + '</div>';
      }).join("");
      renderDetail();
    };

    function esc(s){
      return String(s == null ? "" : s)
        .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;").replace(/'/g,"&#39;");
    }

    // sync the dropdown to the saved theme on first paint
    (function(){
      var t = document.body.dataset.theme || "cards";
      var sel = document.getElementById("theme");
      if (sel) sel.value = t;
    })();
  </script>
</body></html>
]]

-- Apply the saved theme (or default) to the markup before showing.
local savedTheme = hs.settings.get("ccDashboardTheme") or DEFAULT_THEME
HTML = HTML:gsub("__INIT_THEME__", savedTheme)
print("[cc-dashboard] starting with theme: " .. savedTheme)

-- Build and show the panel. Restore the user's last size/position if we saved
-- one (and it's still sane and on-screen); otherwise default to the top-right.
local PANEL_DEFAULTS = { w = PANEL_W, h = 320 }
local screen = hs.screen.mainScreen():frame()
local rect = core.resolvePanelRect(FX.loadGeometry(), screen, PANEL_DEFAULTS)

-- developerExtrasEnabled stays OFF in normal use: with it on, right-click pops
-- WebKit's "Reload / Inspect Element" menu, which competes with our popup menu.
-- Flip to true temporarily if you need the web inspector.
wv = hs.webview.new(rect, { developerExtrasEnabled = false }, controller)
wv:windowStyle(
  hs.webview.windowMasks.titled |
  hs.webview.windowMasks.closable |
  hs.webview.windowMasks.miniaturizable |  -- yellow minimize-to-Dock button
  hs.webview.windowMasks.resizable
)
wv:windowTitle("Claude Shepherd")
wv:level(hs.drawing.windowLevels.floating)
wv:behavior(hs.drawing.windowBehaviors.canJoinAllSpaces | hs.drawing.windowBehaviors.stationary)
wv:html(HTML)
wv:allowTextEntry(true)  -- let the Nudge/Queue input accept keyboard input
wv:show()
print("[cc-dashboard] panel shown")

-- Show/hide so the panel can be dismissed (minimize-to-menubar) and reopened.
local panelVisible = true
-- Tracks whether the panel webview is the KEY window. The panel is a floating,
-- non-activating webview, so it can be key (receiving keys) without Hammerspoon
-- being the frontmost app — hs.window/frontmostApplication can't tell. The
-- webview's own focusChange callback is the only reliable signal (used by ⌘V).
local panelHasFocus = false
-- Re-apply the saved frame on show, in case something (a Space switch, a restore
-- from the Dock) nudged the window back to a smaller size.
local function showPanel()
  pcall(function()
    wv:frame(core.resolvePanelRect(FX.loadGeometry(), hs.screen.mainScreen():frame(), PANEL_DEFAULTS))
    wv:show()
  end)
  panelVisible = true
end
local function hidePanel() pcall(function() wv:hide() end); panelVisible = false end
local function togglePanel() if panelVisible then hidePanel() else showPanel() end end
-- The red close button just hides it; reopen from the menubar or with the hotkey.
-- On a resize/move, persist the new frame (debounced — frameChange fires rapidly
-- while dragging) so the size survives the next reload.
local saveGeomTimer
pcall(function()
  wv:windowCallback(function(action, _webview, extra)
    if action == "closing" then
      panelVisible = false
    elseif action == "focusChange" then
      -- `extra` is a boolean: true = gained key focus, false = lost it.
      panelHasFocus = extra and true or false
    elseif action == "frameChange" then
      if saveGeomTimer then saveGeomTimer:stop() end
      saveGeomTimer = hs.timer.doAfter(0.4, function()
        pcall(function() FX.saveGeometry(wv:frame()) end)
      end)
    end
  end)
end)

-- Menubar icon to reopen/hide the panel even when it's closed.
M.menubar = hs.menubar.new()
if M.menubar then
  M.menubar:setTitle("🐑")
  M.menubar:setTooltip("Claude Shepherd — Claude sessions")
  M.menubar:setMenu(function()
    return {
      { title = panelVisible and "Hide panel" or "Show panel", fn = togglePanel },
      { title = "-" },
      { title = "Reload config", fn = function() hs.reload() end },
    }
  end)
end

-- ⌘V into the panel: hs.webview text inputs don't get the standard paste shortcut
-- (Hammerspoon has no Edit menu), so we handle it ourselves while the panel is the
-- focused window — inject text into the input, or stage a pasted image as a chip.
local function panelIsFocused()
  -- Primary: the webview's own focusChange signal (works for a non-activating
  -- panel). Fallback: the focused-window id match (accurate when hs.window can
  -- see the webview, harmless when it can't).
  if panelHasFocus then return true end
  local mw = wv and wv:hswindow()
  local fw = hs.window.focusedWindow()
  return (mw and fw and fw:id() == mw:id()) or false
end
local function handlePanelPaste()
  -- Read BOTH reps and PREFER text. Copied text often carries a tag-along image
  -- representation; checking image-first hijacked plain-text pastes (and the
  -- image encode then threw, swallowed by the caller's pcall). Only treat it as
  -- an image when there's an image and no text.
  local txt = hs.pasteboard.readString()
  local img = hs.pasteboard.readImage()
  print(string.format("[cc-dashboard] ⌘V: textlen=%d img=%s",
    txt and #txt or 0, tostring(img ~= nil)))
  if txt and #txt > 0 then
    wv:evaluateJavaScript("insertIntoNudge(" .. jsString(txt) .. ")")
    print("[cc-dashboard] ⌘V: inserted text len=" .. #txt)
  elseif img then
    local ok, durl = pcall(function() return img:encodeAsURLString() end)
    if ok and durl and #durl > 0 then
      if not durl:find("^data:") then durl = "data:image/png;base64," .. durl end
      wv:evaluateJavaScript("setImage(" .. jsString(durl) .. ")")
      print("[cc-dashboard] ⌘V: staged a pasted image")
    else
      print("[cc-dashboard] ⌘V: image encode failed: " .. tostring(durl))
    end
  end
end
M.pasteTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  local f = e:getFlags()
  if f.cmd and not f.shift and not f.alt and not f.ctrl
     and e:getKeyCode() == hs.keycodes.map["v"] then
    local focused = panelIsFocused()
    print("[cc-dashboard] ⌘V seen (focus=" .. tostring(focused) .. ")")
    if focused then
      local ok, err = pcall(handlePanelPaste)
      if not ok then print("[cc-dashboard] ⌘V handler error: " .. tostring(err)) end
      return true  -- swallow ⌘V so it isn't also handled elsewhere
    end
  end
  return false
end)
M.pasteTap:start()

-- Read the status dir, parse via cc-core, refresh byKey, return the sorted list.
function refreshList()
  local entries = {}
  for _, fname in ipairs(FX.readDir(STATUS_DIR)) do
    local key = fname:match("^(.+)%.json$")
    if key then
      local content = FX.readFile(STATUS_DIR .. "/" .. fname)
      if content and #content > 0 then entries[#entries + 1] = { key = key, content = content } end
    end
  end
  local raw = core.parseStatusList(entries, FX.now(), STALE_SECONDS)
  -- Prune orphans: stale tiles with no session_id, or any tile older than the
  -- 24h backstop. (SessionEnd can't clean these; staleness only dims them.)
  -- Also prune /clear "ghosts": a stale tile whose project has a fresher live tile.
  local now = FX.now()
  local list = {}
  local pruneOpts = { pruneNoSid = PRUNE_NO_SID, pruneSeconds = PRUNE_SECONDS }
  local ghost = {}
  for _, k in ipairs(core.staleDuplicateKeys(raw)) do ghost[k] = true end
  for _, it in ipairs(raw) do
    if core.shouldPrune(it, now, pruneOpts) then
      FX.removeStatus(it.key)
      print("[cc-dashboard] pruned orphan tile: " .. tostring(it.name) .. " (" .. it.key .. ")")
    elseif ghost[it.key] then
      FX.removeStatus(it.key)
      print("[cc-dashboard] pruned ghost duplicate: " .. tostring(it.name) .. " (" .. it.key .. ")")
    else
      list[#list + 1] = it
    end
  end
  byKey = {}
  for _, it in ipairs(list) do byKey[it.key] = it end
  return list
end

-- Read cc-config.json (missing/garbled -> empty table = all defaults).
function loadConfig()
  local c = FX.readFile(CONFIG_FILE)
  if not c or #c == 0 then return {} end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or {}
end

-- Push current statuses into the webview + deck; run queue auto-feed and
-- stale-approval escalation; keep the heartbeat fresh.
function refresh()
  local list = refreshList()
  local cfg = loadConfig()
  local autofeed   = core.config(cfg, "queue.autofeed", false) == true
  local queueDry   = core.config(cfg, "queue.dryRun", false) == true
  local escEnabled = core.config(cfg, "escalation.enabled", false) == true
  local escMin     = tonumber(core.config(cfg, "escalation.minutes", 5)) or 5
  local escSound   = core.config(cfg, "escalation.sound", false) == true
  local escPush    = core.config(cfg, "escalation.push", false) == true
  local escTopic   = tostring(core.config(cfg, "escalation.pushTopic", ""))
  local apEnabled  = core.config(cfg, "policies.autopilot.enabled", false) == true
  local now = FX.now()
  local newPrev = {}

  for _, it in ipairs(list) do
    -- Live activity peek (non-stale sessions). Include `done` so the peek refreshes
    -- to the FINAL assistant line when a session finishes (a done transcript doesn't
    -- change, so the re-read is stable) instead of freezing mid-turn.
    if ACTIVITY_PEEK and it.transcript_path and not it.stale
       and (it.status == "working" or it.status == "approval" or it.status == "done") then
      local tail = FX.readTail(it.transcript_path, ACTIVITY_BYTES)
      if tail then it.activity = core.transcriptSnippet(tail, ACTIVITY_LEN) end
    end

    -- Autopilot badge (active only while the feature is enabled in config).
    it.autopilot = apEnabled and FX.autopilotActive(it.key) or false

    -- Task queue: depth badge + auto-feed on a fresh done transition.
    local q = FX.readQueue(it.key)
    it.queue = core.queueDepth(q)
    if core.shouldFeed(prevStatus[it.key], it.status, q, autofeed) then
      local task, q2 = core.queuePop(q)
      if queueDry then
        print("[cc-queue] DRY-RUN would feed '" .. tostring(task) .. "' to " .. it.name)
      else
        print("[cc-queue] feeding '" .. tostring(task) .. "' to " .. it.name)
        FX.feedTask(it.name, task)
        FX.writeQueue(it.key, q2)
        it.queue = core.queueDepth(q2)
      end
    end

    -- Escalation: nag harder when an approval sits too long (once per episode).
    if escEnabled and core.approvalStale(it, now, escMin * 60) then
      it.escalate = true
      if not escalated[it.key] then
        escalated[it.key] = true
        print("[cc-escalate] " .. it.name .. " waiting > " .. escMin .. "m")
        if escSound then FX.playSound() end
        if escPush then
          FX.push(escTopic, "Claude Shepherd: " .. it.name .. " needs you",
            (it.pending and it.pending.summary) or "Waiting for approval")
        end
      end
    end
    if it.status ~= "approval" then escalated[it.key] = nil end

    newPrev[it.key] = it.status
  end
  prevStatus = newPrev

  FX.writeFile(HEARTBEAT, tostring(now))
  sd.blink = not sd.blink
  sdRender(list)
  -- Overlay any ephemeral relabels (display-only; .name stays the real target).
  core.applyLabels(list, labels)
  local payload = (#list == 0) and "[]" or hs.json.encode(list)
  wv:evaluateJavaScript("window.ccUpdate(" .. payload .. ")")
end

-- Bind global hotkeys to act on whichever session needs you, no panel needed.
-- The target SELECTION is cc-core logic (tested); here we just wire the keys.
local function bindHotkeys()
  if not HOTKEYS_ENABLED then return end
  M.hotkeys = {
    hs.hotkey.bind(HOTKEY_APPROVE_FRONT[1], HOTKEY_APPROVE_FRONT[2], function()
      local it = core.nextApproval(refreshList())
      if it then
        print("[cc-hotkey] approve-front -> " .. tostring(it.name))
        core.handleAction(FX, it, "approve")
      else
        hs.alert.show("Claude Shepherd: nothing waiting")
      end
    end),
    hs.hotkey.bind(HOTKEY_JUMP_NEEDY[1], HOTKEY_JUMP_NEEDY[2], function()
      local list = refreshList()
      local it = core.nextApproval(list) or core.frontSession(list)
      if it then
        lastJumpKey = it.key
        print("[cc-hotkey] jump-needy -> " .. tostring(it.name))
        core.handleAction(FX, it, "focus")
      end
    end),
    hs.hotkey.bind(HOTKEY_CYCLE[1], HOTKEY_CYCLE[2], function()
      local it = core.cycleNext(refreshList(), lastJumpKey)
      if it then
        lastJumpKey = it.key
        print("[cc-hotkey] cycle -> " .. tostring(it.name))
        core.handleAction(FX, it, "focus")
      end
    end),
    hs.hotkey.bind(HOTKEY_SPAWN[1], HOTKEY_SPAWN[2], function() spawnPrompt() end),
    hs.hotkey.bind(HOTKEY_TOGGLE[1], HOTKEY_TOGGLE[2], function() togglePanel() end),
  }
  print("[cc-dashboard] hotkeys bound")
end

-- Ensure the status dir exists so the watcher has something to watch.
hs.fs.mkdir(STATUS_DIR)

-- Poll on a timer, and also react instantly to file changes.
M.timer = hs.timer.doEvery(POLL_SECONDS, refresh)
M.watcher = hs.pathwatcher.new(STATUS_DIR, function() refresh() end):start()
sdStart()  -- begin Stream Deck discovery (no-op if none plugged in)
bindHotkeys()
refresh()

-- Keep references alive so Lua does not garbage-collect them.
_G.__ccDashboard = { webview = wv, controller = controller, module = M, core = core, fx = FX }
print("[cc-dashboard] loaded; watching " .. STATUS_DIR)

return M
