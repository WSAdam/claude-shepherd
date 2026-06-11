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
local function jsString(s) return core.jsString(s) end  -- pure impl in cc-core (tested)

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
local GATE_TOOLS_DIR = os.getenv("CC_GATE_TOOLS_DIR") or (os.getenv("HOME") .. "/.claude/cc-gate-tools")
local GATE_FLAG     = os.getenv("CC_GATE_FLAG") or (os.getenv("HOME") .. "/.claude/cc-gate.enabled")
local LABELS_FILE   = os.getenv("CC_LABELS_FILE") or (os.getenv("HOME") .. "/.claude/cc-labels.json")
local GROUPS_FILE   = os.getenv("CC_GROUPS_FILE") or (os.getenv("HOME") .. "/.claude/cc-groups.json")
local RECENT_FILE   = os.getenv("CC_RECENT_FILE") or (os.getenv("HOME") .. "/.claude/cc-recent-dirs.json")
local LEDGER_DIR    = os.getenv("CC_LEDGER_DIR") or (os.getenv("HOME") .. "/.claude/cc-ledger")
local CLAUDE_DIR    = (os.getenv("HOME") or "") .. "/.claude"
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
-- ⌘Esc is a TOGGLE, so if the chat input already had focus it would UNFOCUS it and
-- our keystrokes would land in the editor (the chronic nudge flakiness). Sending
-- "Focus First Editor Group" (⌘1) first guarantees the input is unfocused, so the
-- ⌘Esc toggle is deterministic (always unfocused -> focused). nil to disable.
local FOCUS_EDITOR_KEY = { { "cmd" }, "1" }

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
local ORCH_DEFAULT_DIR = (os.getenv("HOME") or "") .. "/Programming"
local HOTKEY_SPAWN     = { { "cmd", "alt" }, "s" } -- spawn a new Claude session
local HOTKEY_TOGGLE    = { { "cmd", "alt" }, "b" } -- show/hide the panel
-- -------------------------------------------------------------------------

core.STALE_SECONDS = STALE_SECONDS

-- session key (status filename base) -> latest item, for resolving actions.
local byKey = {}
-- Persistent display relabels, keyed by project path (cwd) so a brand-new session
-- in the same folder inherits the name. Persisted to cc-labels.json; survives a
-- new instance, close/reopen, and a Hammerspoon reload. (This intentionally
-- reverses the earlier in-memory-only rule.) Loaded from disk once FX exists.
local labels = {}
local groups = {}        -- projectKey -> group name (cohort tag); loaded from disk
local ctxMenu            -- holds the live right-click popup menu (so it isn't GC'd)
local wv                 -- the webview; forward-declared so the controller can push to it
local lastJumpKey = nil  -- for the cycle-jump hotkey
local spawnPrompt        -- forward declaration (defined after FX)
-- One per-tile snapshot of the LAST refresh, keyed by tile key: status (auto-feed
-- transitions), stale (auto-respawn edge), escalated (one nag per approval episode).
-- Rebuilt-and-swapped each refresh so a vanished tile drops out; see refresh().
local prev = {}
local respawnAttempts = {}  -- projectKey (NOT tile key) -> auto-respawn count; resets when healthy
local watchdog = {}      -- key -> { size, ts, alerted }: transcript progress + stall episode
local draining    = {}   -- key -> true: close on the next fresh `done` (Feature F)
local gitRootByCwd = {}  -- cwd -> resolved git root ("" = not a repo) cache (Feature B)
local caffeineTick = 0   -- throttles the keep-awake state re-read (F2)
local ledgerGcTick = 0   -- throttles the ledger retention GC (off the 180s timer)
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
-- Focus the editor window for a session. Tries the session name first, then walks
-- UP the cwd path (parent folders), so a session running in a subfolder (name
-- "frontend") still finds its workspace window (titled "… — autobottom"). Returns
-- true if a specific window was focused (switches Spaces automatically). The
-- candidate-building + title matching are pure (cc-core, tested -- review #4).
local function focusProject(name, cwd)
  print("[cc-dashboard] focus request: " .. tostring(name))
  local app = findEditorApp()
  if not app then
    print("[cc-dashboard] editor app not found")
    hs.alert.show("No editor window found")
    return false
  end
  local windows = app:allWindows()
  local candidates = core.focusCandidates(name, cwd, os.getenv("USER"))

  -- Pass 1: folder-match each candidate in order; first hit wins.
  for _, needle in ipairs(candidates) do
    for _, w in ipairs(windows) do
      local title = string.lower(w:title() or "")
      if title ~= "" and core.titleFolderMatch(title, needle) then
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

-- Incremental reader: return (newText, newSize) reading from byte `offset` to EOF.
-- Used by the token-usage aggregator so each tick parses only appended bytes, never
-- re-chewing multi-MB transcripts. A shrunk file (offset>size) is reread from 0.
function FX.readFrom(path, offset)
  local f = io.open(path, "rb"); if not f then return nil, offset or 0 end
  local size = f:seek("end")
  offset = offset or 0
  if offset > size then offset = 0 end
  if offset == size then f:close(); return "", size end
  f:seek("set", offset)
  local data = f:read("*a"); f:close()
  return data, size
end

-- Byte size of a file (the watchdog's transcript-growth signal), or nil if
-- unreadable. Cheap: one seek-to-end, no read.
function FX.fileSize(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local size = f:seek("end"); f:close()
  return size
end

-- Token-usage aggregation across active sessions' transcripts. ZERO API cost: pure
-- local file reads, incremental per tick. Builds per-session + fleet cumulative
-- totals + a 5h/7d Anthropic-only window approximation, pushes them to the webview.
-- Called on a 60s timer and the "Update now" button. (Pure parse/sum/window logic
-- lives in cc-core; this is just the IO + aggregation shell.)
local usageState = {}      -- [path] = { offset, cum = {...}, recent = { {ts, buckets, anthropic} } }
local lastUsagePayload = nil
local lastOfficialUsage = nil   -- parsed { five_hour, seven_day, seven_day_sonnet, ... } or nil
local lastOfficialFetch = 0     -- epoch of the last successful/attempted fetch (180s TTL)
local ccVersion = nil           -- "x.y.z" for the User-Agent (detected once)
local function blankCum() return { input = 0, output = 0, cacheRead = 0, cacheCreate = 0, total = 0, real = 0, byModel = {} } end
local function addBuckets(dst, e)
  dst.input = dst.input + e.input; dst.output = dst.output + e.output
  dst.cacheRead = dst.cacheRead + e.cacheRead; dst.cacheCreate = dst.cacheCreate + e.cacheCreate
  dst.total = dst.input + dst.output + dst.cacheRead + dst.cacheCreate
  dst.real = dst.input + dst.output + dst.cacheCreate  -- excl. cache reads (meaningful headline)
end
function FX.computeUsage()
  local cfg = loadConfig()                 -- for per-provider contextLimit
  local now = os.time()
  local cutoff7d = now - core.WINDOW_7D
  local seen, perSession = {}, {}
  local fleet = blankCum()
  local w5h, w7d = 0, 0
  for key, it in pairs(byKey) do
    local path = it.transcript_path
    if path and path ~= "" then
      seen[path] = true
      local st = usageState[path] or { offset = 0, cum = blankCum(), recent = {} }
      local text, newSize = FX.readFrom(path, st.offset)
      if newSize and newSize < st.offset then st.cum = blankCum(); st.recent = {} end  -- file replaced
      if text and #text > 0 then
        for line in (text .. "\n"):gmatch("(.-)\n") do
          local e = core.parseUsageLine(line)
          if e then
            addBuckets(st.cum, e)
            local mk = e.model or "unknown"
            st.cum.byModel[mk] = st.cum.byModel[mk] or blankCum()
            addBuckets(st.cum.byModel[mk], e)
            st.lastContext = core.contextTokens(e)  -- most recent turn = current context fill
            st.lastModel = e.model
            st.recent[#st.recent + 1] = { ts = e.ts, input = e.input, output = e.output,
              cacheRead = e.cacheRead, cacheCreate = e.cacheCreate,
              anthropic = core.isAnthropicSession(e.model, it.base_url) }
          end
        end
      end
      st.offset = newSize or st.offset
      local pruned = {}  -- keep only events inside the 7d window
      for _, ev in ipairs(st.recent) do if ev.ts and ev.ts >= cutoff7d then pruned[#pruned + 1] = ev end end
      st.recent = pruned
      usageState[path] = st

      -- Context fullness for EVERY session (works for stale/done tiles, unlike the 1s peek).
      local cfrac, ctoks
      if st.lastContext then
        ctoks = st.lastContext
        cfrac = core.contextFractionFor(cfg, st.lastModel or it.model, ctoks)
      end
      perSession[key] = { total = st.cum.total, real = st.cum.real, input = st.cum.input,
        output = st.cum.output, cacheRead = st.cum.cacheRead, cacheCreate = st.cum.cacheCreate,
        byModel = st.cum.byModel, context_tokens = ctoks, context_frac = cfrac }
      addBuckets(fleet, st.cum)
      for m, v in pairs(st.cum.byModel) do
        fleet.byModel[m] = fleet.byModel[m] or blankCum(); addBuckets(fleet.byModel[m], v)
      end
      local anthro = {}  -- plan-window approximation counts Anthropic sessions only
      for _, ev in ipairs(st.recent) do if ev.anthropic then anthro[#anthro + 1] = ev end end
      w5h = w5h + core.usageInWindow(anthro, now, core.WINDOW_5H)
      w7d = w7d + core.usageInWindow(anthro, now, core.WINDOW_7D)
    end
  end
  for p in pairs(usageState) do if not seen[p] then usageState[p] = nil end end  -- drop ended sessions
  lastUsagePayload = { fleet = fleet, perSession = perSession, window = { w5h = w5h, w7d = w7d },
    official = lastOfficialUsage, ts = now }
  if wv then
    pcall(function() wv:evaluateJavaScript("window.ccUsage(" .. hs.json.encode(lastUsagePayload) .. ")") end)
  end
  return lastUsagePayload
end

-- ---- Official plan-usage window (undocumented Anthropic OAuth endpoint) -------
-- GET https://api.anthropic.com/api/oauth/usage returns the SAME numbers as
-- claude.ai/settings/usage and Claude Code's /usage: five_hour/seven_day utilization %
-- + reset times. NO model tokens are spent (it's a metadata call). We read the user's
-- existing Claude Code OAuth token (macOS Keychain or $CLAUDE_CODE_OAUTH_TOKEN) and send
-- it only to api.anthropic.com over HTTPS; the token is never logged. Polled at most
-- every 180s (the endpoint 429s if hammered) and on any failure we silently fall back to
-- the local approximation. The token is the user's own, used read-only for their account.
local OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local OFFICIAL_TTL = 180

-- Read the OAuth access token without ever logging it. Prefer the env var, else the
-- macOS Keychain entry Claude Code keeps (and auto-refreshes while it runs).
local function oauthToken()
  local env = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  if env and #env > 0 then return env end
  local h = io.popen([[security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null]])
  if not h then return nil end
  local raw = h:read("*a"); h:close()
  if not raw or #raw == 0 then return nil end
  local ok, j = pcall(function() return core.json.decode(raw) end)
  if ok and type(j) == "table" and j.claudeAiOauth and j.claudeAiOauth.accessToken then
    return j.claudeAiOauth.accessToken
  end
  return nil
end

-- Detect the Claude Code version once for the required User-Agent (claude-code/<ver>).
local function ccUserAgent()
  if not ccVersion then
    local h = io.popen("claude --version 2>/dev/null")
    if h then local v = h:read("*a"); h:close()
      ccVersion = (v or ""):match("(%d+%.%d+%.%d+)") or "2.0.0"
    else ccVersion = "2.0.0" end
  end
  return "claude-code/" .. ccVersion
end

-- Fetch the official usage window (async, non-blocking). force=true bypasses the TTL
-- (the Update-now button); otherwise it no-ops if fetched within OFFICIAL_TTL seconds.
function FX.fetchOfficialUsage(force)
  local now = os.time()
  if not force and (now - lastOfficialFetch) < OFFICIAL_TTL then return end
  lastOfficialFetch = now
  local token = oauthToken()
  if not token then return end  -- no token -> stay on the local approximation
  local headers = {
    ["Authorization"] = "Bearer " .. token,
    ["anthropic-beta"] = "oauth-2025-04-20",
    ["User-Agent"] = ccUserAgent(),
    ["Content-Type"] = "application/json",
  }
  hs.http.asyncGet(OAUTH_USAGE_URL, headers, function(status, body)
    if status ~= 200 or not body then
      print("[cc-usage] official usage fetch: HTTP " .. tostring(status) .. " (using local approx)")
      return
    end
    local ok, j = pcall(function() return hs.json.decode(body) end)
    if not ok or type(j) ~= "table" then return end
    lastOfficialUsage = j
    -- push immediately so the bars update without waiting for the next 60s pass
    if wv then pcall(function()
      wv:evaluateJavaScript("window.ccOfficial(" .. hs.json.encode(j) .. ")")
    end) end
  end)
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
function FX.feedTask(target, task) FX.typeIntoWindow(target, task) end

-- Persistent relabels (F1): a JSON map of project path (cwd) -> override name.
-- Missing/garbled file -> empty map (no labels). Mirrors the queue I/O above.
function FX.loadLabels()
  local c = FX.readFile(LABELS_FILE)
  if not c or #c == 0 then return {} end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or {}
end
function FX.saveLabels(labelsByCwd)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(LABELS_FILE, core.json.encode(labelsByCwd or {}))
end

-- Session groups (cohort tags): a JSON map of projectKey -> group name. Same
-- shape + failure mode as labels (missing/garbled -> empty map). Survives reload.
function FX.loadGroups()
  local c = FX.readFile(GROUPS_FILE)
  if not c or #c == 0 then return {} end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or {}
end
function FX.saveGroups(groupsByKey)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(GROUPS_FILE, core.json.encode(groupsByKey or {}))
end

-- ---- Audit/event ledger I/O ------------------------------------------------
-- Append-only JSONL under LEDGER_DIR, one event per line, in per-day (UTC) files.
-- This is the dashboard's writer for OPERATOR ACTIONS; the shell hooks write
-- lifecycle + decisions into the same store. Pure parse/filter/retention/narrative
-- live in cc-core; here is just the I/O. OFF unless ledger.enabled.
local ledgerSeq = 0
local function ledgerEnabled() return core.config(loadConfig(), "ledger.enabled", false) == true end

-- Append one event. `event` carries at least `type`; v/ts/id are stamped here.
-- No-op unless enabled and the type passes ledger.captureTypes (empty = all).
function FX.appendLedger(event)
  if type(event) ~= "table" or not ledgerEnabled() then return end
  local cap = core.config(loadConfig(), "ledger.captureTypes", nil)
  if type(cap) == "table" and #cap > 0 then
    local ok = false
    for _, t in ipairs(cap) do if t == event.type then ok = true; break end end
    if not ok then return end
  end
  ledgerSeq = ledgerSeq + 1
  event.v  = event.v or 1
  event.ts = event.ts or FX.now()
  event.id = event.id or (tostring(event.ts) .. "-d-" .. tostring(ledgerSeq))
  hs.fs.mkdir(LEDGER_DIR)
  local day = os.date("!%Y-%m-%d")  -- UTC, to match cc-core.ledgerFileEpoch + the shell writer
  local f = io.open(LEDGER_DIR .. "/" .. day .. ".jsonl", "a")
  if f then f:write(core.json.encode(event) .. "\n"); f:close() end
end

-- Build + append an operator-action event from a live status item. `extra` holds
-- the type-specific fields (must include `type`); identity fields come from the
-- item (projectKey from the live value the dashboard already computes).
local function ledgerFor(item, extra)
  if type(item) ~= "table" or type(extra) ~= "table" then return end
  local ev = { session_id = item.session_id, key = item.key, name = item.name,
               projectKey = item.projectKey, cwd = item.cwd }
  for k, v in pairs(extra) do ev[k] = v end
  FX.appendLedger(ev)
end

-- Read + parse + filter the ledger. opts = { session, sinceTs, untilTs, types,
-- limit }. Caps the slice (newest-first) so a huge ledger can't bloat the webview
-- payload. Returns { events, files, truncated, ts }.
function FX.readLedger(opts)
  opts = opts or {}
  local files = {}
  for _, fn in ipairs(FX.readDir(LEDGER_DIR)) do
    if fn:match("%.jsonl$") then files[#files + 1] = fn end
  end
  table.sort(files)  -- chronological by name
  local events = {}
  for _, fn in ipairs(files) do
    local text = FX.readFile(LEDGER_DIR .. "/" .. fn)
    if text then
      for _, e in ipairs(core.parseLedger(text)) do events[#events + 1] = e end
    end
  end
  local filtered = core.filterLedger(events, opts)
  local cap, truncated = opts.limit or 2000, false
  if #filtered > cap then
    local t = {}; for i = 1, cap do t[i] = filtered[i] end
    filtered, truncated = t, true
  end
  return { events = filtered, files = files, truncated = truncated, ts = FX.now() }
end

-- Atomically rewrite the daily file `day` (UTC "YYYY-MM-DD"), nulling `fields` on
-- the line whose id == `id` and marking it redacted, then log a `redact` tombstone.
-- temp+mv is atomic; redact PAST days (today's file is hot with appends). true on hit.
function FX.redactLedger(day, id, fields)
  local path = LEDGER_DIR .. "/" .. day .. ".jsonl"
  local text = FX.readFile(path)
  if not text then return false end
  local out, hit = {}, false
  for _, e in ipairs(core.parseLedger(text)) do
    if e.id == id then
      hit = true
      for _, fld in ipairs(fields or {}) do e[fld] = nil end
      e.redacted = true
    end
    out[#out + 1] = core.json.encode(e)
  end
  if not hit then return false end
  local tmp = path .. ".tmp." .. tostring(FX.now())
  local f = io.open(tmp, "w"); if not f then return false end
  f:write(table.concat(out, "\n") .. "\n"); f:close()
  if not os.rename(tmp, path) then os.remove(tmp); return false end
  FX.appendLedger({ type = "redact", targetId = id, fields = fields })
  return true
end

-- Purge events. filter.all removes every daily file; otherwise { session, sinceTs,
-- untilTs } rewrites each file dropping matches. Logs a `purge` tombstone with the
-- count removed (appended AFTER the rewrite so it survives). Returns the count.
function FX.purgeLedger(filter)
  filter = filter or {}
  local removed = 0
  local files = {}
  for _, fn in ipairs(FX.readDir(LEDGER_DIR)) do
    if fn:match("%.jsonl$") then files[#files + 1] = fn end
  end
  for _, fn in ipairs(files) do
    local path = LEDGER_DIR .. "/" .. fn
    local events = core.parseLedger(FX.readFile(path) or "")
    if filter.all then
      removed = removed + #events
      os.remove(path)
    else
      local kept = {}
      for _, e in ipairs(events) do
        local match = true
        if filter.session and e.session_id ~= filter.session then match = false end
        if match and filter.sinceTs and (tonumber(e.ts) or 0) < filter.sinceTs then match = false end
        if match and filter.untilTs and (tonumber(e.ts) or 0) > filter.untilTs then match = false end
        if match then removed = removed + 1 else kept[#kept + 1] = core.json.encode(e) end
      end
      local tmp = path .. ".tmp." .. tostring(FX.now())
      local f = io.open(tmp, "w")
      if f then
        f:write(#kept > 0 and (table.concat(kept, "\n") .. "\n") or "")
        f:close(); os.rename(tmp, path)
      end
    end
  end
  FX.appendLedger({ type = "purge", filter = filter, count = removed })
  return removed
end

-- Retention GC: delete daily files past ledger.retentionDays, then (if maxTotalMB
-- is set) delete oldest files until total size is under the cap. Logs a `purge`
-- tombstone listing what was removed. Cheap dir scan; safe to call on a timer.
function FX.expireLedger()
  if not ledgerEnabled() then return end
  local cfg = loadConfig()
  local files = {}
  for _, fn in ipairs(FX.readDir(LEDGER_DIR)) do
    if fn:match("%.jsonl$") then files[#files + 1] = fn end
  end
  local removed = {}
  -- 1) age-based expiry (pure decision in cc-core)
  local days = tonumber(core.config(cfg, "ledger.retentionDays", 0)) or 0
  local expired = core.expiredLedgerFiles(files, FX.now(), days)
  local expiredSet = {}
  for _, fn in ipairs(expired) do
    os.remove(LEDGER_DIR .. "/" .. fn); removed[#removed + 1] = fn; expiredSet[fn] = true
  end
  -- 2) total-size cap, oldest first
  local capMB = tonumber(core.config(cfg, "ledger.maxTotalMB", 0)) or 0
  if capMB > 0 then
    local live = {}
    for _, fn in ipairs(files) do if not expiredSet[fn] then live[#live + 1] = fn end end
    table.sort(live)  -- oldest first by name
    local function fsize(fn)
      local a = hs.fs.attributes(LEDGER_DIR .. "/" .. fn); return (a and a.size) or 0
    end
    local total = 0; for _, fn in ipairs(live) do total = total + fsize(fn) end
    local capBytes, i = capMB * 1024 * 1024, 1
    while total > capBytes and i <= #live do
      total = total - fsize(live[i])
      os.remove(LEDGER_DIR .. "/" .. live[i]); removed[#removed + 1] = live[i]; i = i + 1
    end
  end
  if #removed == 0 then return end
  print("[cc-ledger] retention: removed " .. #removed .. " file(s)")
  FX.appendLedger({ type = "purge", filter = { retention = true }, expired = removed, count = #removed })
end

-- ---- New-session effects (F3-F5): folder browser, recents, mkdir -----------
-- List the visible SUBFOLDERS of a path for the in-panel browser. Expands a
-- leading ~, resolves to an absolute path, keeps only directories, sorts, caps.
-- Falls back to the raw path + empty list on a bad/denied dir (never errors).
function FX.listDirs(path)
  local raw = tostring(path or "")
  if raw:sub(1, 1) == "~" then raw = (os.getenv("HOME") or "") .. raw:sub(2) end
  local abs = hs.fs.pathToAbsolute(raw) or raw
  if abs == "" then abs = ORCH_DEFAULT_DIR end
  local dirs = {}
  for _, name in ipairs(FX.readDir(abs)) do
    if core.isVisibleDir(name)
       and hs.fs.attributes(core.pathJoin(abs, name), "mode") == "directory" then
      dirs[#dirs + 1] = name
    end
  end
  dirs = core.sortDirs(dirs)
  if #dirs > 500 then local t = {}; for i = 1, 500 do t[i] = dirs[i] end; dirs = t end
  return { path = abs, parent = core.parentPath(abs), dirs = dirs }
end

-- Recent project dirs (F5). Missing/garbled -> empty. Mirrors the queue/label I/O.
function FX.readRecent()
  local c = FX.readFile(RECENT_FILE)
  if not c or #c == 0 then return { dirs = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table" and type(t.dirs) == "table") and t or { dirs = {} }
end
function FX.writeRecent(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(RECENT_FILE, core.json.encode(state or { dirs = {} }))
end

-- Create a project folder (F3). One level under an existing parent (the browsed
-- dir). An existing path is treated as success ("use existing").
function FX.mkdirP(path)
  if not path or path == "" then return false end
  if hs.fs.attributes(path) then return true end
  return hs.fs.mkdir(path) and true or false
end

-- Resolve a binary to an absolute path (hs.task does NOT search PATH). Prefers a
-- configured path, then the user's login-shell PATH, then common Homebrew spots.
local function resolveBin(name, configured)
  if configured and configured ~= "" and configured ~= name
     and hs.fs.attributes(configured) then return configured end
  local out = hs.execute("command -v " .. name, true)  -- true = user's shell/PATH
  if out then out = out:gsub("%s+$", "") end
  if out and #out > 0 and hs.fs.attributes(out) then return out end
  for _, p in ipairs({ "/opt/homebrew/bin/" .. name, "/usr/local/bin/" .. name }) do
    if hs.fs.attributes(p) then return p end
  end
  return configured or name
end

-- ---- Kitty remote control (F: detect + auto-enable) ------------------------
function FX.kittyConfPath()
  local dir = os.getenv("KITTY_CONFIG_DIRECTORY")
  if not dir or dir == "" then dir = (os.getenv("HOME") or "") .. "/.config/kitty" end
  return dir .. "/kitty.conf"
end

function FX.kittyRunning()
  local apps = hs.application.applicationsForBundleID("net.kovidgoyal.kitty")
  return (apps and #apps > 0) or (hs.application.find("kitty") ~= nil)
end

-- Ensure the user's global kitty.conf enables remote control on a socket, so the
-- kitty windows they open themselves (not just the ones we spawn) are reachable
-- by `kitty @` (Part A). Backs up first, idempotent. Returns "ok" (changed),
-- "already" (nothing to do), or "error". A change needs a kitty restart to apply.
function FX.ensureKittyRemote()
  local path = FX.kittyConfPath()
  local cur = FX.readFile(path) or ""
  if core.kittyRemoteStatus(cur).usable then return "already" end
  local newText, changed = core.kittyConfWithRemote(cur, nil)
  if not changed then return "already" end
  hs.fs.mkdir((os.getenv("HOME") or "") .. "/.config")
  hs.fs.mkdir(path:match("(.*)/[^/]+$") or ".")
  if #cur > 0 then FX.writeFile(path .. ".cc-backup", cur) end
  FX.writeFile(path, newText)
  print("[cc-kitty] enabled remote control in " .. path)
  return "ok"
end

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

-- Per-session gated-tools override (Feature D): a dedicated file per session that
-- cc-approve.sh reads on its hot path. "" / nil = no override; "-" = gate nothing.
function FX.gateToolsOverride(key) return FX.readFile(GATE_TOOLS_DIR .. "/" .. key) end
function FX.setGateToolsOverride(key, str)
  hs.fs.mkdir(GATE_TOOLS_DIR)
  FX.writeFile(GATE_TOOLS_DIR .. "/" .. key, str)
end
function FX.clearGateToolsOverride(key) os.remove(GATE_TOOLS_DIR .. "/" .. key) end

-- Cached git-root resolver (Feature B). Shells out at most once per distinct cwd
-- for the panel's life (a session's cwd rarely changes), so the 1s refresh never
-- runs git in steady state. Caches the miss too: a non-repo dir resolves to "" and
-- is not re-shelled. Returns the repo root, or nil if cwd isn't in a git repo.
function FX.gitRoot(cwd)
  if not cwd or cwd == "" then return nil end
  local cached = gitRootByCwd[cwd]
  if cached ~= nil then return (cached ~= "") and cached or nil end
  local root = ""
  pcall(function()
    local q = "'" .. tostring(cwd):gsub("'", "'\\''") .. "'"
    local out = hs.execute("git -C " .. q .. " rev-parse --show-toplevel 2>/dev/null")
    if out then root = out:gsub("%s+$", "") end
  end)
  gitRootByCwd[cwd] = root
  return (root ~= "") and root or nil
end

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

-- Improve button: pull this repo's un-applied leaderboard improvement cards and,
-- instead of applying them wholesale (what /improve does), inject a REVIEW-first
-- prompt into the session so the user approves suggestions before any edits.
-- NOTE: claim-cards is the only (mutating) endpoint, so this CLAIMS the cards --
-- a second click then correctly reports "no improvements found".
local improveCreds = nil  -- { url=, token= } cached after the first successful read
-- LB_URL/GRADE_PREVIEW_TOKEN live in ~/.zshrc; Hammerspoon doesn't inherit the
-- shell env and a login shell won't source ~/.zshrc, so read them via an
-- INTERACTIVE zsh (-i sources ~/.zshrc). Cached so the rc cost is paid once.
local function improveCredsRead()
  if improveCreds then return improveCreds end
  local out = hs.execute([[/bin/zsh -ic 'echo "$LB_URL"; echo "$GRADE_PREVIEW_TOKEN"']], false) or ""
  local url, token = out:match("^(.-)\n(.-)\n")
  url   = (url   or ""):gsub("%s+$", "")
  token = (token or ""):gsub("%s+$", "")
  if url ~= "" and token ~= "" then improveCreds = { url = url, token = token } end
  return improveCreds
end
function FX.runImprove(item)
  local cwd = item and item.cwd
  if not cwd or cwd == "" then hs.alert.show("Improve: no working dir for this session"); return end
  local function dq(s) return '"' .. tostring(s):gsub('[\\"`$]', "\\%0") .. '"' end
  local creds = improveCredsRead()
  local lbUrl = creds and creds.url or ""
  local token = creds and creds.token or ""
  -- git is on PATH (/usr/bin/git); plain exec keeps each click fast (no rc reload).
  local remote = hs.execute("git -C " .. dq(cwd) .. " remote get-url origin 2>/dev/null", false) or ""
  local repo = core.repoFromRemote(remote)
  if lbUrl == "" or token == "" then
    hs.alert.show("Improve: leaderboard not configured — source ~/.zshrc and reload Hammerspoon")
    print("[cc-improve] missing LB_URL/token (Hammerspoon can't see shell env)")
    return
  end
  if repo == "" then
    hs.alert.show("Improve: no git origin remote for " .. tostring(item.name))
    print("[cc-improve] no origin remote under " .. tostring(cwd))
    return
  end
  print("[cc-improve] claiming cards for repo: " .. repo)
  hs.http.asyncPost(lbUrl .. "/api/grade/claim-cards", hs.json.encode({ repo = repo }),
    { ["x-grade-token"] = token, ["content-type"] = "application/json" },
    function(status, body)
      if status ~= 200 or not body then
        hs.alert.show("Improve: leaderboard error (HTTP " .. tostring(status) .. ")")
        print("[cc-improve] HTTP " .. tostring(status) .. " body=" .. tostring(body))
        return
      end
      local ok, data = pcall(function() return hs.json.decode(body) end)
      if not ok or type(data) ~= "table" then
        hs.alert.show("Improve: bad response from leaderboard")
        print("[cc-improve] bad JSON: " .. tostring(body))
        return
      end
      local cards = (type(data.cards) == "table") and data.cards or {}
      local claimed = tonumber(data.claimed) or #cards
      print("[cc-improve] repo=" .. repo .. " claimed=" .. tostring(claimed))
      if claimed <= 0 or #cards == 0 then
        hs.alert.show("No improvements found for " .. repo)
        return
      end
      -- inline target (winTarget is a local defined later in the file, so not in
      -- scope here; this mirrors its shape for the kitty/VS Code injection routing).
      local target = { name = item.name, cwd = item.cwd, editor = item.editor,
                       kittyWindowId = item.kitty_window_id, kittyListenOn = item.kitty_listen_on }
      FX.pasteIntoWindow(target, { text = core.improvePrompt(cards) })
      hs.alert.show("Improve: pulled " .. #cards .. " insight(s) → review prompt sent to " .. tostring(item.name))
    end)
end

function FX.writeFile(path, content)
  local f = io.open(path, "w"); if f then f:write(content); f:close() end
end

-- Caffeinate / keep-awake (F2). Reading state needs no privileges; toggling does.
-- Read the live keep-awake flag without sudo (pmset -g is unprivileged). Returns
-- true/false, or nil if the flag couldn't be read (caller keeps the UI as-is).
function FX.caffeineState()
  local out = hs.execute("/usr/bin/pmset -g")
  return core.parseSleepDisabled(out or "")
end

-- Toggle keep-awake via a GUI admin-password prompt (one prompt per toggle, by
-- the user's explicit choice over a NOPASSWD sudoers entry). The command is a
-- fixed string (only the literal 1/0 from the pure builder), so no injection.
-- Returns true on success; a cancelled/failed dialog returns false (the caller
-- re-reads caffeineState() to resync the UI to the real, unchanged state).
function FX.setCaffeinate(on)
  local script = 'do shell script "' .. core.pmsetDisableSleepCmd(on)
    .. '" with administrator privileges'
  local ok, _, raw = hs.osascript.applescript(script)
  if not ok then print("[cc-caffeine] toggle cancelled or failed: " .. tostring(raw)) end
  return ok and true or false
end

function FX.removeStatus(key) os.remove(STATUS_DIR .. "/" .. key .. ".json") end

function FX.writeDecision(key, value)
  FX.writeFile(STATUS_DIR .. "/" .. key .. ".decision", value)
  print("[cc-dashboard] decision " .. tostring(value) .. " -> " .. tostring(key))
end

-- ---- Kitty effect routing (Part A): run effects headlessly via `kitty @` ----
-- Fire one kitty @ remote-control command (no window focus) via hs.task. Returns
-- true if launched. nil argv (un-targetable / unsupported) or no bin -> false.
local function runKitty(argv)
  if not argv then return false end
  local bin = resolveBin("kitty", core.config(loadConfig(), "spawn.kittyBin", nil))
  print("[cc-kitty] " .. bin .. " " .. table.concat(argv, " "))
  local t = hs.task.new(bin, nil, argv)
  if t then t:start(); return true end
  return false
end
local function isKitty(target) return type(target) == "table" and target.editor == "kitty" end
-- Adapt the handleAction target to the field names core.kittyCmd reads.
local function kittyItem(target)
  return { kitty_window_id = target.kittyWindowId,
           kitty_listen_on = target.kittyListenOn, cwd = target.cwd }
end
-- Build a window-effect target from a status item (for the direct, non-handleAction
-- call sites: feedTask / clear / compact / image-paste).
local function winTarget(it)
  return { name = it.name, cwd = it.cwd, editor = it.editor,
           kittyWindowId = it.kitty_window_id, kittyListenOn = it.kitty_listen_on }
end

function FX.focusWindow(target)
  if isKitty(target) then return runKitty(core.kittyCmd("focus", kittyItem(target))) end
  return focusProject(target.name, target.cwd)
end

-- hs.timer.doAfter returns a timer that, if nothing references it, can be GC'd
-- BEFORE it fires -- silently aborting nested injection chains mid-way (the chronic
-- nudge/clear/compact flakiness: the deeper the nesting, the likelier a pending
-- timer is collected). Hold a strong ref to every pending timer until it fires.
local pendingTimers, ptSeq = {}, 0
local function after(delay, fn)
  ptSeq = ptSeq + 1
  local id = ptSeq
  pendingTimers[id] = hs.timer.doAfter(delay, function()
    pendingTimers[id] = nil
    fn()
  end)
  return pendingTimers[id]
end

-- Focus a window, then send after a short delay, then restore prior focus.
local function sendToWindow(name, sendFn)
  local prev = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  after(FOCUS_DELAY, function()
    pcall(sendFn)
    if prev then
      after(FOCUS_DELAY, function() pcall(function() prev:focus() end) end)
    end
  end)
end

function FX.actOnWindow(target, keySpec)
  -- kitty: headless send-key (no focus) -- approve="enter", deny/stop="esc".
  if isKitty(target) then
    return runKitty(core.kittyCmd("key", kittyItem(target), { token = core.kittyKeyToken(keySpec) }))
  end
  sendToWindow(target.name, function() hs.eventtap.keyStroke(keySpec.mods, keySpec.key) end)
end

-- Focus a window, run the (timer-driven) injection sequence, and ONLY restore the
-- prior focus AFTER the final Return. (sendToWindow restores too early for these
-- multi-step sequences — it re-focuses while ⌘V/Return are still pending, so the
-- keystrokes hit the wrong window. That race was the chronic nudge flakiness.)
function FX.typeIntoWindow(target, text)
  -- kitty: one headless send-text (trailing \r submits); no focus / chat-key dance.
  if isKitty(target) then
    return runKitty(core.kittyCmd("text", kittyItem(target), { text = text .. "\r" }))
  end
  -- VS Code: char-by-char keystrokes were flaky and slash commands never submitted.
  -- Route through the same reliable clipboard-paste path as nudges (it handles the
  -- deterministic chat-input focus and the slash-command autocomplete on submit).
  print("[cc-dashboard] type -> " .. tostring(target.name) .. ": " .. tostring(text))
  return FX.pasteIntoWindow(target, { text = text })
end

-- Inject text and/or an image into a session via the clipboard + ⌘V instead of
-- char-by-char typing. This is newline-safe (a multi-line list pastes as one
-- block rather than each line submitting early) and a single keystroke, which is
-- more reliable in the VS Code extension. payload = { text=…, imagePath=… }.
-- Best-effort: depends on the chat input being focusable. The prior text
-- clipboard is restored afterwards.
function FX.pasteIntoWindow(target, payload)
  payload = payload or {}
  -- kitty: no clipboard-image attach via @; send the text (if any) headlessly.
  if isKitty(target) then
    if payload.text and #payload.text > 0 then
      return runKitty(core.kittyCmd("text", kittyItem(target), { text = payload.text .. "\r" }))
    end
    return false
  end
  local name = target.name
  print("[cc-dashboard] paste -> " .. tostring(name)
    .. (payload.imagePath and " [image]" or "")
    .. (payload.text and (": " .. payload.text) or ""))
  -- Slash commands (/clear, /compact, /effort…) open the extension's autocomplete
  -- popup; the first Return only ACCEPTS the suggestion, so submitting needs a 2nd.
  local isSlash = payload.text ~= nil and payload.text:match("^/") ~= nil
  local prevClip = hs.pasteboard.readString()  -- best-effort restore (text only)
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  after(FOCUS_DELAY, function()
    -- Focus the editor group first so the ⌘Esc chat-input toggle is deterministic
    -- (always unfocused -> focused, never the reverse). Then focus the chat input.
    if FOCUS_EDITOR_KEY then hs.eventtap.keyStroke(FOCUS_EDITOR_KEY[1], FOCUS_EDITOR_KEY[2]) end
    after(FOCUS_EDITOR_KEY and 0.06 or 0, function()
      if FOCUS_CHAT_KEY then hs.eventtap.keyStroke(FOCUS_CHAT_KEY[1], FOCUS_CHAT_KEY[2]) end
      after(0.12, function()
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
            local restoreDelay = 0.15
            if isSlash then  -- 2nd Return past the autocomplete; restore after it
              after(0.12, function() hs.eventtap.keyStroke({}, "return") end)
              restoreDelay = 0.30
            end
            after(restoreDelay, function()
              if prevClip then pcall(function() hs.pasteboard.setContents(prevClip) end) end
              if prevWin then pcall(function() prevWin:focus() end) end
            end)
            return
          end
          steps[i]()
          hs.eventtap.keyStroke({ "cmd" }, "v")
          after(0.12, function() runFrom(i + 1) end)
        end
        runFrom(1)
      end)
    end)
  end)
end

-- Best-effort close the editor window for a session: focus it, then send the
-- VS Code/Cursor "Close Window" chord (⌘⇧W). Unreliable if the title can't be
-- matched (focusProject falls back to just activating the app), so the caller
-- also drops the dashboard tile regardless.
function FX.closeWindow(target)
  if isKitty(target) then return runKitty(core.kittyCmd("close", kittyItem(target))) end
  print("[cc-dashboard] close window -> " .. tostring(target.name))
  sendToWindow(target.name, function() hs.eventtap.keyStroke({ "cmd", "shift" }, "w") end)
end

-- Drive a sequence of keystrokes into a session (e.g. arrow-down ×N + Return to
-- pick an AskUserQuestion option). Focus first, send each key with a small gap,
-- restore prior focus only AFTER the last key (same race-safe pattern as paste).
function FX.sendKeys(target, keys)
  keys = keys or {}
  -- kitty: one headless send-key per key (no focus); used by answer + set-mode.
  if isKitty(target) then
    for _, k in ipairs(keys) do
      runKitty(core.kittyCmd("key", kittyItem(target), { token = core.kittyKeyToken(k) }))
    end
    return
  end
  local name = target.name
  print("[cc-dashboard] send keys -> " .. tostring(name) .. " (" .. #keys .. " keys)")
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(name)
  after(FOCUS_DELAY, function()
    local function step(i)
      if i > #keys then
        if prevWin then after(0.12, function() pcall(function() prevWin:focus() end) end) end
        return
      end
      local k = keys[i]
      hs.eventtap.keyStroke(k.mods or {}, k.key)
      after(0.08, function() step(i + 1) end)
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

-- Best-effort: open a VS Code/Cursor window at the project, then drive a new
-- integrated terminal and type `claude …`. There's no supported API to start a
-- session in the editor's terminal, so this is keystroke automation (Kitty and
-- Terminal are the reliable paths). Reuses focusProject + the eventtap ladder.
local function spawnEditorWindow(spec)
  print("[cc-orch] " .. spec.editor .. " spawn: open " .. spec.app .. " at " .. tostring(spec.project))
  local t = hs.task.new("/usr/bin/open", nil, { "-na", spec.app, "--args", spec.project })
  if t then t:start() end
  hs.alert.show("Claude Shepherd: opening " .. spec.app .. " — starting claude (best-effort)")
  local proj = spec.project
  local name = proj and proj:match("([^/]+)/?$") or nil
  after(2.0, function() pcall(function()
    focusProject(name, proj)
    after(0.5, function()
      -- New integrated terminal via the Command Palette (more reliable than ⌃`,
      -- which would hide an already-open terminal).
      hs.eventtap.keyStroke({ "cmd", "shift" }, "p")
      after(0.35, function()
        hs.eventtap.keyStrokes("Terminal: Create New Terminal")
        after(0.2, function()
          hs.eventtap.keyStroke({}, "return")
          after(0.6, function()
            hs.eventtap.keyStrokes(spec.postType)
            hs.eventtap.keyStroke({}, "return")
          end)
        end)
      end)
    end)
  end) end)
end

-- Short human-readable description of a spawn spec, for dry-run logging.
local function describeSpec(spec)
  if spec.kind == "kitty" then return table.concat(spec.argv, " ")
  elseif spec.kind == "vscode" then
    return "open " .. spec.app .. " @ " .. tostring(spec.project) .. " + type: " .. spec.postType
  end
  return spec.applescript
end

-- Spawn a new Claude session, editor-aware (F3-F5). The editor comes from the
-- caller (the modal's picker) or falls back to `spawn.editor` in config. Effective
-- dry-run = the code default ORCH_DRY_RUN unless the user flips `spawn.live` on.
function FX.spawnSession(editor, project, task, permissionMode, providerId)
  local cfg = loadConfig()
  editor = (editor and editor ~= "") and editor or core.config(cfg, "spawn.editor", "terminal")
  -- Resolve the provider profile (explicit pick, else the spawn.provider default).
  -- A missing/unknown profile leaves env/model nil -> bare `claude`, unchanged.
  local providerKey = (providerId and providerId ~= "") and providerId
    or core.config(cfg, "spawn.provider", nil)
  local profile = core.providerById(cfg, providerKey)
  local opts = {
    terminal       = ORCH_TERMINAL,
    kittyBin       = resolveBin("kitty", core.config(cfg, "spawn.kittyBin", nil)),
    kittyRemote    = core.config(cfg, "spawn.kittyRemote", true) ~= false,
    kittySocket    = core.config(cfg, "spawn.kittySocket", nil),
    permissionMode = (permissionMode and permissionMode ~= "") and permissionMode or nil,
    env            = profile and core.providerEnv(profile) or nil,  -- carries ANTHROPIC_MODEL
    ssh            = profile and type(profile.ssh) == "table" and profile.ssh or nil,
  }
  local spec = core.spawnSpec(editor, project, task, opts)
  if profile then print("[cc-orch] provider: " .. tostring(profile.id)
    .. " (" .. tostring(profile.kind or "anthropic") .. " / " .. tostring(profile.model) .. ")") end
  local live = core.config(cfg, "spawn.live", false) == true
  FX.appendLedger({ type = "spawn",
    name = (project and project:match("([^/]+)/?$")) or project, cwd = project,
    editor = editor, kind = spec.kind, provider = profile and profile.id or nil,
    task = task and tostring(task):sub(1, 200) or nil, dryRun = (ORCH_DRY_RUN and not live) })
  if ORCH_DRY_RUN and not live then
    print("[cc-orch] DRY-RUN (" .. spec.kind .. ") would spawn in "
      .. tostring(project) .. ": " .. describeSpec(spec))
    hs.alert.show("Claude Shepherd (dry-run): would spawn " .. spec.kind .. " in " .. tostring(project))
    return
  end
  if spec.kind == "kitty" then
    print("[cc-orch] kitty spawn: " .. table.concat(spec.argv, " "))
    local args = {}
    for i = 2, #spec.argv do args[#args + 1] = spec.argv[i] end
    local t = hs.task.new(spec.argv[1], nil, args)
    if t then t:start() else print("[cc-orch] kitty task failed to build") end
    hs.alert.show("Claude Shepherd: spawning kitty in " .. tostring(project))
  elseif spec.kind == "vscode" then
    spawnEditorWindow(spec)
  else
    print("[cc-orch] terminal spawn in " .. tostring(project))
    hs.osascript.applescript(spec.applescript)  -- Terminal login shell -> claude on PATH
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
  local editor = core.config(loadConfig(), "spawn.editor", "terminal")
  FX.writeRecent(core.recentPush(FX.readRecent(), project))
  FX.spawnSession(editor, project, task)
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
  if a == "usage-refresh" then
    pcall(function() FX.fetchOfficialUsage(true) end)  -- force the official window (bypass TTL)
    pcall(FX.computeUsage)  -- recompute local totals immediately (no model tokens either way)
    return
  end
  if a == "caffeinate" then
    -- Global toggle (not per-session). Flip via the admin prompt, then re-read the
    -- TRUE state (a cancelled dialog leaves it unchanged) and push it back, so the
    -- button reflects reality rather than an optimistic guess.
    local want = (payload.v == true) or (payload.v == "true") or (payload.v == 1)
    FX.setCaffeinate(want)
    local state = FX.caffeineState()
    if state ~= nil then
      pcall(function() wv:evaluateJavaScript("setCaffeine(" .. tostring(state) .. ")") end)
    end
    return
  end
  if a == "kitty-remote" then
    -- Manually enable kitty remote control in the user's kitty.conf (so `kitty @`
    -- effects work). Idempotent; a change needs a kitty restart to take effect.
    local res = FX.ensureKittyRemote()
    local msg = (res == "ok") and "enabled kitty remote control — restart kitty to apply"
      or (res == "already") and "kitty remote control already enabled"
      or "couldn't update kitty.conf"
    pcall(function() hs.alert.show("Claude Shepherd: " .. msg) end)
    return
  end
  if a == "open-settings" then
    -- Push the current config (or {} = all defaults) + gate state into the form.
    -- Decode + RE-ENCODE via hs.json rather than splicing raw file bytes into the
    -- JS call: a malformed cc-config.json would otherwise produce broken JS that
    -- silently fails the pcall. On a parse error we fall back to defaults + alert.
    local raw = FX.readFile(CONFIG_FILE)
    local cfg = {}
    if raw and #raw > 0 then
      local ok, parsed = pcall(function() return hs.json.decode(raw) end)
      if ok and type(parsed) == "table" then cfg = parsed
      else pcall(function() hs.alert.show("Claude Shepherd: cc-config.json is malformed — showing defaults") end) end
    end
    local gateOn = (FX.readFile(GATE_FLAG) ~= nil) and "true" or "false"
    local autoOn = "false"
    pcall(function() if hs.autoLaunch() then autoOn = "true" end end)
    pcall(function()
      wv:evaluateJavaScript("showSettings(" .. hs.json.encode(cfg) .. ", " .. gateOn .. ", " .. autoOn .. ")")
    end)
    return
  end
  if a == "save-config" then
    local ok, parsed = pcall(function() return hs.json.decode(payload.text or "{}") end)
    if ok and type(parsed) == "table" then
      hs.fs.mkdir(CLAUDE_DIR)
      local incoming = parsed.config or {}
      -- Normalize the editable gated-tools list (space/comma -> clean, deduped).
      if type(incoming.gate) == "table" then incoming.gate.tools = core.parseToolList(incoming.gate.tools) end
      -- Overlay the Settings-managed keys onto the EXISTING config rather than
      -- replacing the whole file, so hand-edited top-level blocks the UI doesn't
      -- expose (risk / collision / drain / respawn / insights, spawn.kittyBin…)
      -- survive a Save.
      local cfg = loadConfig()
      for k, v in pairs(incoming) do cfg[k] = v end
      FX.writeFile(CONFIG_FILE, hs.json.encode(cfg, true))  -- creates if missing
      if parsed.gate == true then FX.writeFile(GATE_FLAG, "")
      else os.remove(GATE_FLAG) end
      -- Launch-on-startup: the source of truth is Hammerspoon's real login item.
      if parsed.autoLaunch ~= nil then
        pcall(function() hs.autoLaunch(parsed.autoLaunch == true) end)
        hs.settings.set("ccAutoLaunchDefaulted", true)
      end
      print("[cc-dashboard] saved cc-config.json (gate=" .. tostring(parsed.gate)
        .. ", autoLaunch=" .. tostring(parsed.autoLaunch) .. ")")
      pcall(function() hs.alert.show("Claude Shepherd: settings saved") end)
    end
    return
  end
  if a == "open-new" then
    -- Feed the modal: current config + recent dirs (seeded with active session
    -- cwds) + the initial folder listing. loadConfig() decodes-or-{}, and we
    -- re-encode via hs.json so a malformed file can't break the spliced JS.
    local cfg = loadConfig()
    local active = {}
    for _, it in pairs(byKey) do if it.cwd then active[#active + 1] = it.cwd end end
    local recent = core.recentSeed(FX.readRecent(), active)
    local browse = FX.listDirs(ORCH_DEFAULT_DIR)
    pcall(function()
      wv:evaluateJavaScript("showNew(" .. hs.json.encode(cfg) .. ", "
        .. hs.json.encode(recent.dirs) .. ", " .. hs.json.encode(browse) .. ")")
    end)
    return
  end
  if a == "list-dir" then
    local path = (payload.v and tostring(payload.v) ~= "") and tostring(payload.v) or ORCH_DEFAULT_DIR
    local browse = FX.listDirs(path)
    pcall(function() wv:evaluateJavaScript("ccBrowse(" .. hs.json.encode(browse) .. ")") end)
    return
  end
  if a == "spawn" then
    -- From the in-panel modal (carries mode + dir/parent+name + editor); with no
    -- usable dir we fall back to the native two-prompt flow (also the ⌘⌥S path).
    local mode   = tostring(payload.mode or "")
    local editor = payload.editor and tostring(payload.editor) or nil
    local task   = payload.text and tostring(payload.text) or nil
    local dir
    if mode == "new" then
      dir = core.newProjectPath(tostring(payload.parent or ""), tostring(payload.name or ""))
      if not dir then
        pcall(function() hs.alert.show("Claude Shepherd: invalid project name") end)
        return
      end
      if not FX.mkdirP(dir) then
        pcall(function() hs.alert.show("Claude Shepherd: couldn't create " .. dir) end)
        return
      end
    elseif mode == "existing" then
      dir = payload.dir and tostring(payload.dir) or ""
    end
    if not dir or dir == "" then
      spawnPrompt()  -- no dir from the modal -> native fallback
      return
    end
    FX.writeRecent(core.recentPush(FX.readRecent(), dir))
    FX.spawnSession(editor, dir, task, payload.permMode and tostring(payload.permMode) or nil,
      payload.provider and tostring(payload.provider) or nil)
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
      if task then
        FX.feedTask(winTarget(item), task); FX.writeQueue(key, q2)
        ledgerFor(item, { type = "task_feed", task = tostring(task):sub(1, 200), by = "manual" })
      end
    end
    return
  end
  if a == "clear" or a == "compact" then
    local item = byKey[tostring(payload.v or "")]
    if item then
      -- One spec per action keeps cmd/title/msg in lockstep (no parallel ternaries).
      local SPEC = {
        clear = { cmd = "/clear", title = "Clear conversation",
          msg = "Clear ALL conversation context for " .. item.name .. "?\nThis types /clear into its terminal." },
        compact = { cmd = "/compact", title = "Auto-compact",
          msg = "Compact (summarize) the conversation for " .. item.name .. "?\nThis types /compact into its terminal." },
      }
      local s = SPEC[a]
      pcall(function()
        if hs.dialog.blockAlert(s.title, s.msg, "Yes", "Cancel") == "Yes" then
          FX.typeIntoWindow(winTarget(item), s.cmd)
          ledgerFor(item, { type = a })
        end
      end)
    end
    return
  end
  if a == "improve" then
    local item = byKey[tostring(payload.v or "")]
    if item then FX.runImprove(item) end
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
        ledgerFor(byKey[key], { type = "autopilot_arm", minutes = mins })
        print("[cc-autopilot] on for " .. key .. " (" .. mins .. "m)")
      end
    end
    return
  end
  if a == "set-gate-tools" then
    -- Feature D: per-session gated-tools override. "" -> clear (use fleet default);
    -- "all" -> gate the full fleet list; "none" -> sentinel "-" (gate nothing);
    -- anything else -> a normalized custom list. cc-approve.sh reads the file.
    local key = tostring(payload.v or "")
    local v   = tostring(payload.text or "")
    if key ~= "" then
      if v == "" then
        FX.clearGateToolsOverride(key)
      elseif v == "all" then
        FX.setGateToolsOverride(key, core.parseToolList(
          core.config(loadConfig(), "gate.tools", core.DEFAULT_GATE_TOOLS)))
      elseif v == "none" then
        FX.setGateToolsOverride(key, "-")
      else
        FX.setGateToolsOverride(key, core.parseToolList(v))
      end
      ledgerFor(byKey[key], { type = "gate_tools", scope = v })
      print("[cc-gate] per-session tools for " .. key .. " -> " .. (v == "" and "(default)" or v))
    end
    refresh()
    return
  end
  if a == "open-insights-view" then
    local res = FX.readLedger({})
    local maxBlock = tonumber(core.config(loadConfig(), "insights.maxBlockSeconds", 1800)) or 1800
    local stats = core.fleetStats(res.events, { now = FX.now(), topN = 8, maxBlock = maxBlock })
    -- Sparkline trends: last 24h in hourly buckets (windowed first so the series is
    -- small). `blocked` pairs a tool_request with its later decision, so its window
    -- gets a maxBlock lookback: a wait that started just before the 24h edge but
    -- resolved inside it is still paired (its request isn't filtered out).
    local since = FX.now() - 24 * 3600
    local recent = core.filterLedger(res.events, { sinceTs = since })
    local recentBlocked = core.filterLedger(res.events, { sinceTs = since - maxBlock })
    stats.spark = {
      blocked    = core.bucketEvents(recentBlocked, 3600, "blocked", { maxBlock = maxBlock }),
      activity   = core.bucketEvents(recent, 3600, "activity"),
      active     = core.bucketEvents(recent, 3600, "active"),
      denialRate = core.bucketEvents(recent, 3600, "denialRate"),
    }
    pcall(function() wv:evaluateJavaScript("window.ccInsights(" .. hs.json.encode(stats) .. ")") end)
    return
  end
  if a == "open-audit-view" then
    pcall(function() wv:evaluateJavaScript("window.ccAudit(" .. hs.json.encode(FX.readLedger({})) .. ")") end)
    return
  end
  if a == "open-session-timeline" then
    -- Per-session drill-down: open the audit overlay scoped to this session's
    -- chronological history (timeline view). Reuses core.sessionTimeline + the
    -- existing audit overlay render. session_id is the cross-writer key.
    local it = byKey[tostring(payload.v or "")]
    local sid = it and it.session_id
    if not sid or tostring(sid) == "" then
      pcall(function() hs.alert.show("Claude Shepherd: no recorded activity for this session yet (ledger off or no session id)") end)
      return
    end
    local res = FX.readLedger({})
    local events = core.sessionTimeline(res.events, sid, { limit = 1000 })
    pcall(function() wv:evaluateJavaScript("window.ccAudit("
      .. hs.json.encode({ events = events, files = res.files, truncated = res.truncated })
      .. ", " .. jsString(sid) .. ", " .. jsString("timeline") .. ")") end)
    return
  end
  if a == "audit-export" then
    local okf, f = pcall(function() return hs.json.decode(payload.text or "{}") end)
    local res = FX.readLedger((okf and type(f) == "table") and f or {})
    hs.fs.mkdir(LEDGER_DIR .. "/exports")
    local fname = LEDGER_DIR .. "/exports/audit-" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl"
    local lines = {}
    for _, e in ipairs(res.events) do lines[#lines + 1] = core.json.encode(e) end
    FX.writeFile(fname, (#lines > 0) and (table.concat(lines, "\n") .. "\n") or "")
    pcall(function() hs.alert.show("Claude Shepherd: exported " .. #res.events .. " event(s) → " .. fname) end)
    return
  end
  if a == "audit-purge" then
    local okf, f = pcall(function() return hs.json.decode(payload.text or "{}") end)
    f = (okf and type(f) == "table") and f or {}
    local scope
    if f.session or f.sinceTs or f.untilTs then scope = "events matching the current filter"
    else f.all = true; scope = "ALL recorded events" end
    pcall(function()
      if hs.dialog.blockAlert("Purge audit ledger",
           "Permanently delete " .. scope .. "?\nThis cannot be undone.", "Purge", "Cancel") == "Purge" then
        local n = FX.purgeLedger(f)
        wv:evaluateJavaScript("window.ccAudit(" .. hs.json.encode(FX.readLedger({})) .. ")")
        hs.alert.show("Claude Shepherd: purged " .. n .. " event(s)")
      end
    end)
    return
  end
  if a == "audit-redact" then
    local okr, r = pcall(function() return hs.json.decode(payload.text or "{}") end)
    if okr and type(r) == "table" and r.id and r.ts then
      local day = os.date("!%Y-%m-%d", tonumber(r.ts))
      local done = FX.redactLedger(day, tostring(r.id), type(r.fields) == "table" and r.fields or {})
      pcall(function()
        if done then
          wv:evaluateJavaScript("window.ccAudit(" .. hs.json.encode(FX.readLedger({})) .. ")")
          hs.alert.show("Claude Shepherd: redacted entry")
        else
          hs.alert.show("Claude Shepherd: couldn't redact (entry not found)")
        end
      end)
    end
    return
  end
  if a == "audit-review" then
    local okf, f = pcall(function() return hs.json.decode(payload.text or "{}") end)
    f = (okf and type(f) == "table") and f or {}
    local target = byKey[tostring(payload.v or "")]
    if not target then
      pcall(function() hs.alert.show("Claude Shepherd: select a session first, then Review activity") end)
      return
    end
    local res = FX.readLedger(f)
    local scope = f.session and ("session " .. tostring(target.name or f.session)) or "all sessions"
    local prompt = core.auditReviewPrompt(core.renderNarrative(res.events), { scope = scope })
    FX.pasteIntoWindow(winTarget(target), { text = prompt })
    pcall(function() hs.alert.show("Claude Shepherd: sent a " .. #res.events .. "-event review to " .. tostring(target.name)) end)
    return
  end
  if a == "bulk" then
    -- Fleet-wide action over the keys the panel currently shows (post search/group
    -- filter -> WYSIWYG). cc-core picks which of those the action targets (by status),
    -- then each routes through the same handleAction the per-tile buttons use.
    local action = tostring(payload.v or "")
    local keys = (type(payload.keys) == "table") and payload.keys or {}
    local visible = {}
    for _, k in ipairs(keys) do
      local it = byKey[tostring(k)]
      if it then visible[#visible + 1] = it end
    end
    local text = (payload.text and tostring(payload.text) ~= "") and tostring(payload.text) or nil
    local n = 0
    for _, k in ipairs(core.selectActionable(visible, action)) do
      local it = byKey[k]
      if it then
        core.handleAction(FX, it, action, text)
        ledgerFor(it, { type = "bulk_action", action = action })
        n = n + 1
      end
    end
    print("[cc-bulk] " .. action .. " -> " .. n .. " session(s)")
    if n > 0 then
      pcall(function() hs.alert.show("Claude Shepherd: " .. action .. " → " .. n .. " session(s)") end)
    end
    refresh()
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
      local cfg0 = loadConfig()
      local menu = {
        -- Jump focuses the editor window (double-click on a tile isn't always
        -- reliable, so offer it here too). Same effect as the detail-panel Jump.
        { title = "Jump to window", fn = function()
            core.handleAction(FX, item, "focus")
          end },
        { title = "-" },
        { title = "Relabel…", fn = function()
            pcall(function() wv:evaluateJavaScript("startRename(" .. keyJson .. ")") end)
          end },
        { title = "Set group…", fn = function()
            pcall(function() wv:evaluateJavaScript("startGroup(" .. keyJson .. ")") end)
          end },
        { title = "-" },
        -- Clear / Compact: same effect as the detail-panel buttons (type the slash
        -- command into the session; headless on Kitty, best-effort in VS Code). A
        -- native confirm-submenu keeps the destructive /clear behind one more click,
        -- using the same reliable pattern as Close (no separate dialog -> no console pop).
        { title = "Clear conversation", menu = {
            { title = "Confirm: clear ALL context for " .. shown, fn = function()
                FX.typeIntoWindow(winTarget(item), "/clear")
                ledgerFor(item, { type = "clear" })
                refresh()
              end },
            { title = "Cancel", fn = function() end },
        } },
        { title = "Compact", menu = {
            { title = "Confirm: compact (summarize) " .. shown, fn = function()
                FX.typeIntoWindow(winTarget(item), "/compact")
                ledgerFor(item, { type = "compact" })
                refresh()
              end },
            { title = "Cancel", fn = function() end },
        } },
        { title = "-" },
        -- Close uses a native submenu confirm. Native menu clicks are reliable on
        -- this non-activating panel; an in-webview confirm button was not (the
        -- first click just activated the window, so commitClose never fired).
        { title = "Close instance", menu = {
            { title = "Confirm: close " .. shown, fn = function()
                -- Keep the project's persistent label (F1): closing this session
                -- shouldn't forget the name for the next session in that folder.
                core.handleAction(FX, item, "close")
                refresh()
              end },
            { title = "Cancel", fn = function() end },
        } },
      }
      -- Drain (Feature F): finish the in-flight turn, then close. While working/
      -- waiting, arm the in-memory flag; if already idle/done there's no turn to
      -- finish, so close now. Only shown when drain.enabled.
      if core.config(cfg0, "drain.enabled", false) == true then
        menu[#menu + 1] = { title = "-" }
        menu[#menu + 1] = { title = "Drain (finish turn, then close)", fn = function()
            if item.status == "working" or item.status == "approval" then
              draining[item.key] = true
              ledgerFor(item, { type = "drain_request" })
              pcall(function() hs.alert.show("Claude Shepherd: will close " .. shown .. " after this turn") end)
            else
              core.handleAction(FX, item, "close")
              refresh()
            end
          end }
        if draining[item.key] then
          menu[#menu + 1] = { title = "Cancel drain", fn = function() draining[item.key] = nil end }
        end
      end
      -- Respawn (Feature F): relaunch a dead/stale session from its last cwd +
      -- matched provider + editor. Behind a confirm submenu (it spawns a process).
      if core.config(cfg0, "respawn.enabled", false) == true then
        menu[#menu + 1] = { title = "Respawn from cwd", menu = {
            { title = "Confirm: respawn " .. shown, fn = function()
                local rs = core.respawnSpec(item, loadConfig())
                if not rs.canRespawn then
                  pcall(function() hs.alert.show("Claude Shepherd: can't respawn — " .. tostring(rs.reason)) end)
                  return
                end
                FX.spawnSession(rs.editor, rs.project, nil, rs.permissionMode, rs.providerId)
                ledgerFor(item, { type = "respawn", cwd = rs.project, editor = rs.editor, provider = rs.providerId })
              end },
            { title = "Cancel", fn = function() end },
        } }
      end
      ctxMenu:setMenu(menu)
      pcall(function() ctxMenu:popupMenu(hs.mouse.absolutePosition(), true) end)
    end
    return
  end
  if a == "relabel" then
    -- Persistent display name keyed by the session's STABLE projectKey (launch
    -- folder), not the live cwd which drifts as the agent cd's around (that drift
    -- was why relabels didn't stick). Blank or == the real folder name clears it.
    -- Survives close/reopen/new-instance/reload (F1).
    local lkey = item.projectKey or item.cwd
    labels = core.setLabel(labels, lkey, payload.text, item.name)
    FX.saveLabels(labels)
    ledgerFor(item, { type = "relabel", to = labels[lkey] or "" })
    print("[cc-dashboard] relabel " .. tostring(lkey) .. " -> " .. tostring(labels[lkey]))
    refresh()
    return
  end
  if a == "set-group" then
    -- Cohort tag keyed by the stable projectKey (like relabel), so it survives
    -- close/reopen and a new session in the same folder inherits it. Blank clears.
    local gkey = item.projectKey or item.cwd
    groups = core.setGroup(groups, gkey, payload.text)
    FX.saveGroups(groups)
    ledgerFor(item, { type = "group", to = groups[gkey] or "" })
    print("[cc-dashboard] group " .. tostring(gkey) .. " -> " .. tostring(groups[gkey] or "(cleared)"))
    refresh()
    return
  end
  if a == "close" then
    -- Keep the project's persistent label (F1): only an explicit relabel-to-blank
    -- clears it, not closing a session.
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
        FX.pasteIntoWindow(winTarget(item), { text = payload.text and tostring(payload.text) or nil, imagePath = path })
        ledgerFor(item, { type = "nudge", text = tostring(payload.text or ""):sub(1, 200), image = true })
      else
        print("[cc-dashboard] image paste: failed to write temp file")
      end
    else
      print("[cc-dashboard] image paste: unrecognized data URL")
    end
    return
  end
  -- Log operator actions that fall through to the generic handler (the rest log at
  -- their own branch above). Navigation (focus/approve/deny/stop/answer) is NOT
  -- logged: approve/deny are shell-owned, the others aren't state changes.
  if a == "set-mode" then
    ledgerFor(item, { type = "mode_change", from = item.permission_mode, to = tostring(payload.text or "") })
  elseif a == "model" then
    ledgerFor(item, { type = "model_change", from = item.model, to = tostring(payload.text or "") })
  elseif a == "effort" then
    ledgerFor(item, { type = "effort_change", from = item.effort, to = tostring(payload.text or "") })
  elseif a == "nudge" then
    ledgerFor(item, { type = "nudge", text = tostring(payload.text or ""):sub(1, 200) })
  elseif a == "continue" then
    ledgerFor(item, { type = "continue" })  -- resumed a session frozen on an API error
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
  #caffeine { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px;
           font-size:12px; padding:3px 8px; cursor:pointer; white-space:nowrap; }
  #caffeine:hover { background:#272a35; }
  #caffeine.active { background:#3a2f17; color:#f5b50a; border-color:#b9772a; }
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
  .s-help { color:#6b7280; font-size:11px; margin:1px 0 6px 22px; line-height:1.35; }
  .s-row b { color:#cfd2db; font-weight:600; }
  .s-num { width:54px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a; border-radius:6px; padding:2px 5px; }
  .s-txt { flex:1; min-width:120px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a; border-radius:6px; padding:2px 6px; }
  .s-area { width:100%; height:54px; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
            border-radius:6px; padding:5px 7px; font-family:ui-monospace,monospace; font-size:12px; box-sizing:border-box; }
  .prov { border:1px solid #2c2f3a; border-radius:8px; padding:6px 8px; margin:6px 0; background:#191b22; }
  .prov-head { display:flex; align-items:center; gap:6px; }
  .prov-head .s-txt { flex:1; }
  .prov-del { background:#21232c; color:#e88; border:1px solid #3a2c2f; border-radius:6px; padding:2px 7px; cursor:pointer; }
  .prov-gw { margin-top:4px; }
  #s-foot { display:flex; gap:8px; padding:10px 12px; border-top:1px solid #2c2f3a; }
  #s-save { background:#21232c; color:#8fd4a3; border:1px solid #2c5; border-radius:8px; font-size:13px; padding:6px 14px; cursor:pointer; }
  #s-foot button:not(#s-save) { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px; font-size:13px; padding:6px 14px; cursor:pointer; }

  /* shared bits */
  #grid { display:grid; gap:8px; padding:10px; }
  .tile { cursor:pointer; position:relative; }
  .tile.sel { outline:2px solid #6ea8fe; outline-offset:1px; }
  .tile.stale { opacity:.45; }
  /* collision (Feature B): amber ring. Defined BEFORE .escalate so the red
     escalate ring wins when a tile is somehow both. */
  .tile.collide { box-shadow:0 0 0 2px #f5b50a, 0 0 10px #f5b50a; }
  /* stuck-session watchdog (Feature 8): purple ring. Before .escalate so a
     red escalate ring still wins when a tile is somehow both. */
  .tile.hung { box-shadow:0 0 0 2px #a855f7, 0 0 10px #a855f7; }
  .tile.escalate { box-shadow:0 0 0 2px #ef4444, 0 0 12px #ef4444; }
  /* per-session risk badge (Feature E): only shown for med/high */
  .risk { font-size:10px; margin-left:5px; }
  .risk.r-med  { color:#f5b50a; }
  .risk.r-high { color:#ef4444; }
  .name { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .dot  { border-radius:50%; flex:0 0 auto; }
  .meta { font-size:11px; color:#8a8d99; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  /* context-fullness mini-bar (per tile + detail) */
  .ctx-bar { height:3px; border-radius:2px; background:#2c2f3a; overflow:hidden; margin-top:3px; grid-column:1 / -1; }
  .ctx-bar > i { display:block; height:100%; width:0; background:#3b82f6; }
  .ctx-bar.ok > i { background:#3b82f6; } .ctx-bar.warn > i { background:#f5b50a; } .ctx-bar.full > i { background:#ef4444; }
  .theme-bar .ctx-bar, .theme-dots .ctx-bar { display:none; }  /* compact themes: badge in detail only */
  /* usage footer under the grid */
  #usage-foot { border-top:1px solid #2c2f3a; padding:6px 10px; font-size:11px; color:#9aa0ad; }
  .uf-row { display:flex; align-items:center; justify-content:space-between; gap:8px; }
  .uf-total { color:#cfd2db; }
  #uf-update { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:6px; padding:2px 8px; cursor:pointer; font-size:11px; }
  .uf-windows { margin-top:4px; display:flex; flex-direction:column; gap:3px; }
  .uf-win { display:flex; align-items:center; gap:6px; }
  .uf-win .lbl { width:78px; color:#8a8d99; } .uf-win .bar { flex:1; height:4px; border-radius:2px; background:#2c2f3a; overflow:hidden; }
  .uf-win .bar > i { display:block; height:100%; background:#8b5cf6; }
  .uf-win .bar.ok > i { background:#8b5cf6; } .uf-win .bar.warn > i { background:#f5b50a; } .uf-win .bar.full > i { background:#ef4444; }
  .uf-win .val { color:#9aa0ad; min-width:64px; text-align:right; }
  .uf-approx { color:#6b7280; font-style:italic; }
  #d-usage { font-size:11px; color:#9aa0ad; margin-top:6px; }
  #d-usage .um-row { display:flex; justify-content:space-between; gap:8px; }
  #empty { color:#6b7280; font-size:13px; padding:18px; text-align:center; }
  /* shared bar rows (search / set-group / rename / confirm). The wrapper carries
     class="barrow" for styling so adding a new bar needs zero CSS; the per-bar id
     stays for JS show/hide targeting. Per-bar exceptions keep their id selectors. */
  .barrow { display:none; align-items:center; gap:6px; padding:8px 12px;
    background:#161821; border-bottom:1px solid #2c2f3a; }
  .barrow.show { display:flex; }
  .barrow-label { font-size:12px; color:#9fb6d6; }
  #searchbar-count { font-size:11px; color:#8a8d99; white-space:nowrap; }
  #confirmbar-label { font-size:12px; color:#e8e9ee; flex:1; }
  .barrow input { flex:1; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
    border-radius:6px; font-size:12px; padding:4px 6px; font-family:inherit; }
  .barrow button { background:#21232c; color:#cfd2db;
    border:1px solid #2c2f3a; border-radius:6px; font-size:12px; padding:4px 10px; cursor:pointer; }
  .barrow button:hover { background:#2b2e39; }
  #confirmbar button.danger { border-color:#ef4444; color:#f3a1a1; }
  /* group filter chips (shown only when groups exist) */
  #groupchips { display:none; flex-wrap:wrap; gap:6px; padding:6px 10px; border-bottom:1px solid #2c2f3a; }
  #groupchips.show { display:flex; }
  .gchip { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:999px;
           font-size:11px; padding:2px 10px; cursor:pointer; }
  .gchip:hover { background:#272a35; }
  .gchip.active { border-color:#6ea8fe; color:#cfe0f5; background:#1c2536; }
  .gtag { font-size:10px; color:#8a8d99; margin-left:5px; }
  /* bulk fleet actions (shown only when actionable sessions exist) */
  #bulkbar { display:none; align-items:center; flex-wrap:wrap; gap:6px; padding:6px 10px; border-bottom:1px solid #2c2f3a; }
  #bulkbar.show { display:flex; }
  .bulk-lbl { font-size:11px; color:#8a8d99; text-transform:uppercase; letter-spacing:.04em; }
  #bulkbar button { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px;
                    font-size:12px; padding:3px 10px; cursor:pointer; }
  #bulkbar button:hover { background:#272a35; }
  #bulkbar button.bulk-ap { border-color:#22c55e; color:#7ee2a0; }
  #bulkbar button.bulk-st { border-color:#ef4444; color:#f3a1a1; }

  /* status colors, shared by all themes via the --c variable */
  .s-idle     { --c:#6b7280; }
  .s-working  { --c:#f5b50a; }
  .s-done     { --c:#22c55e; }
  .s-approval { --c:#ef4444; }
  .s-error    { --c:#ec4899; }  /* magenta: API error -- session frozen, needs Continue */

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
  .theme-cards .s-approval .dot, .theme-cards .s-error .dot { animation:pulse 1s infinite; }

  /* THEME: bar (compact single row of pills) ------------------------------ */
  .theme-bar #grid { display:flex; flex-wrap:wrap; }
  .theme-bar .tile { display:inline-flex; align-items:center; gap:7px;
                     background:#21232c; border:1px solid #2c2f3a; border-radius:999px;
                     padding:6px 12px; }
  .theme-bar .tile:hover { background:#272a35; }
  .theme-bar .dot   { width:9px; height:9px; background:var(--c); }
  .theme-bar .name  { color:#e8e9ee; font-size:13px; font-weight:600; }
  .theme-bar .label, .theme-bar .meta { display:none; }
  .theme-bar .s-approval .dot, .theme-bar .s-error .dot { animation:pulse 1s infinite; }

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
  .theme-contrast .s-approval, .theme-contrast .s-error { animation:pulse 1.2s infinite; }

  /* THEME: dots (minimal vertical list) ----------------------------------- */
  .theme-dots #grid { grid-template-columns:1fr; gap:2px; padding:6px; }
  .theme-dots .tile { display:flex; align-items:center; gap:8px; padding:5px 8px;
                      border-radius:6px; }
  .theme-dots .tile:hover { background:#21232c; }
  .theme-dots .dot   { width:8px; height:8px; background:var(--c); }
  .theme-dots .name  { color:#cfd2db; font-size:12px; }
  .theme-dots .label, .theme-dots .meta { display:none; }
  .theme-dots .s-approval .dot, .theme-dots .s-error .dot { animation:pulse 1s infinite; }

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
  #b-improve { border-color:#6ea8fe; color:#9fc1ff; }
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

  /* new-session overlay (F3-F5): own ids so it never collides with #settings */
  #newsession { display:none; position:fixed; inset:0; background:#15161b; z-index:11;
                flex-direction:column; }
  #newsession.show { display:flex; }
  #n-head { display:flex; align-items:center; justify-content:space-between;
            padding:10px 12px; border-bottom:1px solid #2c2f3a; font-weight:700; color:#fff; }
  #n-body { flex:1; overflow-y:auto; padding:10px 12px; }
  #n-foot { display:flex; gap:8px; padding:10px 12px; border-top:1px solid #2c2f3a; }
  #n-spawn { background:#21232c; color:#8fd4a3; border:1px solid #2c5; border-radius:8px;
             font-size:13px; padding:6px 14px; cursor:pointer; }
  #n-foot button:not(#n-spawn) { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a;
             border-radius:8px; font-size:13px; padding:6px 14px; cursor:pointer; }
  #n-path, #n-name { width:100%; box-sizing:border-box; margin-top:2px; }
  .n-modes { display:flex; gap:6px; margin-bottom:8px; }
  .n-mode { flex:1; background:#1b1d24; color:#cfd2db; border:1px solid #2c2f3a;
            border-radius:8px; font-size:12px; padding:6px 10px; cursor:pointer; }
  .n-mode.active { border-color:#6ea8fe; color:#cfe0f5; background:#1c2536; }
  .n-recent { display:flex; flex-wrap:wrap; gap:6px; }
  .n-chip { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:999px;
            font-size:11px; padding:3px 10px; cursor:pointer; max-width:100%;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .n-chip:hover { background:#272a35; border-color:#3a4a66; }
  .n-crumbs { display:flex; flex-wrap:wrap; align-items:center; gap:2px; font-size:11px;
              color:#8a8d99; margin-bottom:4px; }
  .n-crumb { color:#9fb6d6; cursor:pointer; }
  .n-crumb:hover { text-decoration:underline; }
  .n-dirs { max-height:160px; overflow-y:auto; border:1px solid #2c2f3a; border-radius:8px;
            background:#1b1d24; }
  .n-dir { padding:5px 10px; font-size:12px; color:#cfd2db; cursor:pointer;
           border-bottom:1px solid #21232c; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .n-dir:hover { background:#21232c; }
  .n-dir.up { color:#8a8d99; }
  .n-browse-foot { display:flex; align-items:center; gap:8px; margin-top:6px; }
  .n-browse-foot button { background:#21232c; color:#8fd4a3; border:1px solid #2c5;
            border-radius:8px; font-size:12px; padding:4px 10px; cursor:pointer; }
  .n-dim { font-size:11px; color:#6b7280; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
/* Audit ledger overlay (modeled on #settings). */
#audit{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#audit.show{ display:flex; }
#a-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; }
.a-tab{ background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:6px; padding:2px 8px; cursor:pointer; }
.a-tab.active{ color:#fff; border-color:#4b5563; background:#23262f; }
#a-head .s-x{ margin-left:auto; }
#a-filters{ display:flex; flex-wrap:wrap; gap:6px; padding:8px 10px; border-bottom:1px solid #23262f; }
#a-filters select, #a-filters input{ background:#1a1c22; border:1px solid #2c2f3a; color:#cfd2db; border-radius:6px; padding:3px 6px; font-size:12px; }
#a-body{ flex:1; overflow:auto; padding:6px 10px; }
.a-row{ display:flex; gap:8px; align-items:baseline; padding:3px 0; border-bottom:1px solid #1e2027; }
.a-ts{ color:#6b7280; white-space:nowrap; font-variant-numeric:tabular-nums; }
.a-name{ color:#9aa0ad; white-space:nowrap; max-width:120px; overflow:hidden; text-overflow:ellipsis; }
.a-desc{ color:#cfd2db; flex:1; word-break:break-word; }
.a-redacted{ color:#6b7280; }
.a-redact{ background:none; border:1px solid #3a2c2c; color:#d08; border-radius:5px; padding:1px 6px; cursor:pointer; font-size:11px; }
.a-narr{ white-space:pre-wrap; color:#cfd2db; font-family:ui-monospace,Menlo,monospace; font-size:11px; line-height:1.5; margin:0; }
#a-foot{ display:flex; gap:8px; align-items:center; padding:8px 10px; border-top:1px solid #2c2f3a; }
#a-info{ margin-left:auto; }
/* Fleet insights overlay (Feature A; modeled on #audit). Pure read of the ledger. */
#insights{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#insights.show{ display:flex; }
#i-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; }
#i-head .s-x{ margin-left:auto; }
#i-body{ flex:1; overflow:auto; padding:10px 12px; }
.i-cards{ display:flex; flex-wrap:wrap; gap:8px; margin-bottom:12px; }
.i-card{ background:#191b22; border:1px solid #2c2f3a; border-radius:8px; padding:8px 12px; min-width:96px; }
.i-card .v{ font-size:18px; color:#e8e9ee; font-variant-numeric:tabular-nums; }
.i-card .k{ font-size:11px; color:#8a8d99; margin-top:2px; }
.i-sec{ font-weight:600; color:#cfd2db; margin:10px 0 6px; }
.i-tbl{ width:100%; border-collapse:collapse; }
.i-tbl th, .i-tbl td{ text-align:left; padding:3px 8px; border-bottom:1px solid #1e2027; color:#cfd2db; }
.i-tbl th{ color:#8a8d99; font-weight:500; }
.i-tbl td.n{ text-align:right; font-variant-numeric:tabular-nums; }
#i-foot{ display:flex; gap:8px; align-items:center; padding:8px 10px; border-top:1px solid #2c2f3a; }
#i-info{ margin-left:auto; }
/* insights sparklines (Feature 6): trend lines over the ledger */
.spark-row{ display:flex; align-items:center; gap:8px; padding:4px 0; }
.spark-lbl{ width:110px; flex:0 0 auto; color:#9aa0ad; font-size:11px; }
.spark{ flex:1; min-width:0; background:#191b22; border:1px solid #23262f; border-radius:4px; }
.spark-val{ width:160px; flex:0 0 auto; text-align:right; color:#8a8d99; font-size:11px; font-variant-numeric:tabular-nums; }
.spark-empty{ flex:1; color:#6b7280; font-size:11px; font-style:italic; }
</style></head>
<body class="theme-__INIT_THEME__" data-theme="__INIT_THEME__">
  <div id="bar">
    <span class="t">Claude sessions</span>
    <span class="right">
      <button id="spawn" onclick="openNew()" title="Spawn a new Claude session">+ New</button>
      <button id="caffeine" onclick="toggleCaffeine()" title="Keep this Mac awake — pmset disablesleep (asks for your password)">☕ Sleep ok</button>
      <button id="search-btn" onclick="toggleSearch()" title="Filter sessions (name, project, status, group)">🔍</button>
      <button id="insights-btn" onclick="openInsights()" title="Fleet insights — aggregate stats from the ledger">📊</button>
      <button id="audit-btn" onclick="openAudit()" title="Audit ledger — recorded fleet activity">📜</button>
      <button id="settings-btn" onclick="openSettings()" title="Settings">⚙</button>
      <select id="theme" onchange="onThemeChange()">
        <option value="cards">Cards</option>
        <option value="bar">Bar</option>
        <option value="contrast">Contrast</option>
        <option value="dots">Dots</option>
      </select>
    </span>
  </div>
  <div id="searchbar" class="barrow">
    <span id="searchbar-label" class="barrow-label">🔍</span>
    <input id="searchbar-input" placeholder="Filter sessions… (name, project, status, group)"
           oninput="onSearchInput()" onkeydown="searchKeydown(event)">
    <span id="searchbar-count"></span>
    <button onclick="toggleSearch()">✕</button>
  </div>
  <div id="setgroupbar" class="barrow">
    <span id="setgroupbar-label" class="barrow-label">Group:</span>
    <input id="setgroupbar-input" placeholder="group name (blank to clear)" onkeydown="groupKeydown(event)">
    <button onclick="commitGroup()">Set</button>
    <button onclick="hideBars()">Cancel</button>
  </div>
  <div id="renamebar" class="barrow">
    <span id="renamebar-label" class="barrow-label">Rename:</span>
    <input id="renamebar-input" onkeydown="renameKeydown(event)">
    <button onclick="commitRename()">Set</button>
    <button onclick="hideBars()">Cancel</button>
  </div>
  <div id="confirmbar" class="barrow">
    <span id="confirmbar-label"></span>
    <button class="danger" onclick="commitClose()">Close</button>
    <button onclick="hideBars()">Cancel</button>
  </div>
  <div id="groupchips"></div>
  <div id="bulkbar"></div>
  <div id="grid"></div>
  <div id="empty">Waiting for Claude Code sessions...<br>Start a session in any project.</div>

  <div id="usage-foot">
    <div class="uf-row">
      <span class="uf-total" id="uf-total">Fleet: —</span>
      <button id="uf-update" onclick="send('usage-refresh')" title="Recompute from local transcripts (no tokens used)">Update now</button>
    </div>
    <div class="uf-windows" id="uf-windows"></div>
  </div>

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
    <div id="d-usage"></div>
    <div id="d-actions">
      <button id="b-jump"    onclick="act('focus')">Jump</button>
      <button id="b-approve" onclick="act('approve')">Approve</button>
      <button id="b-deny"    onclick="act('deny')">Deny</button>
      <button id="b-stop"    onclick="act('stop')">Stop</button>
      <button id="b-auto"    onclick="act('autopilot')">Autopilot</button>
      <span class="sep"></span>
      <button id="b-clear"   onclick="act('clear')">Clear</button>
      <button id="b-compact" onclick="act('compact')">Compact</button>
      <button id="b-improve" onclick="act('improve')" title="Pull this repo's un-applied leaderboard improvement insights and send them to this session as a review-first prompt (suggestions, not wholesale edits).">Improve</button>
      <button id="b-timeline" onclick="openSessionTimeline()" title="Show this session's recorded activity timeline (needs the ledger enabled).">📜 Timeline</button>
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
      <label class="ctl">Mode
        <select id="mode" onchange="onModeChange()" title="Cycle permission mode (Shift+Tab). Kitty reliable; VS Code best-effort. Automate is launch-only.">
          <option value="default">Default</option>
          <option value="acceptEdits">Accept edits</option>
          <option value="plan">Plan</option>
        </select>
      </label>
      <label class="ctl">Model
        <select id="d-model" onchange="onModelChange()" title="Switch model live via /model. Works within the session's current backend; changing the provider/base URL needs a new session.">
        </select>
      </label>
      <label class="ctl">Gate
        <select id="d-gate" onchange="onGateChange()" title="Per-session tool gating (least-privilege). Default = use the fleet Gated-tools list. All = gate everything the fleet considers risky. None = gate nothing (trusted session). Custom = a specific list. Only takes effect while headless approvals are armed.">
          <option value="">Default</option>
          <option value="all">All</option>
          <option value="none">None</option>
          <option value="custom">Custom…</option>
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
      <div class="s-sec">General</div>
      <label class="s-row"><input type="checkbox" id="s-autolaunch"> Launch Shepherd on startup (open at login)</label>
      <div class="s-help">Starts Hammerspoon (which hosts this panel) automatically when you log in, so Shepherd is up after a restart. On by default. This sets Hammerspoon's real "Open at Login" item.</div>

      <div class="s-sec">Headless approvals</div>
      <label class="s-row"><input type="checkbox" id="s-headless" onchange="onHeadlessToggle()"> <b>Headless approvals (recommended)</b></label>
      <div class="s-help">One switch: arms the gate AND turns off every auto-approve policy. Approve/Deny then go through this panel with no editor window popping, and Claude still can't run a gated tool until you say so. If you don't answer in ~2&nbsp;min (or the panel is closed) it safely falls back to Claude's own prompt — it never auto-approves.</div>
      <div class="s-lbl">Gated tools (space or comma separated — only these wait for you; reads stay instant)</div>
      <label class="s-row"><input type="text" id="s-gate-tools" class="s-txt" placeholder="Bash Write Edit MultiEdit NotebookEdit"></label>

      <div class="s-sec">Approval gate (advanced)</div>
      <label class="s-row"><input type="checkbox" id="s-gate"> Arm the approval gate (route permission prompts to this panel)</label>
      <div class="s-help">The mechanism behind Headless approvals. Leave the policies below OFF for "approve everything by hand, headlessly." Turn a policy on only to let some requests auto-decide without you.</div>
      <div class="s-sec">Queue</div>
      <label class="s-row"><input type="checkbox" id="s-q-auto"> Auto-feed the next queued task when a session finishes</label>
      <label class="s-row"><input type="checkbox" id="s-q-dry"> Dry-run (log what it would feed, don't send)</label>
      <div class="s-sec">Escalation (a waiting approval nags harder)</div>
      <label class="s-row"><input type="checkbox" id="s-e-en"> Enable escalation</label>
      <label class="s-row">After <input type="number" id="s-e-min" class="s-num" min="1"> minutes</label>
      <label class="s-row"><input type="checkbox" id="s-e-snd"> Play a sound</label>
      <label class="s-row"><input type="checkbox" id="s-e-push"> Push to ntfy topic <input type="text" id="s-e-topic" class="s-txt" placeholder="my-topic"></label>
      <div class="s-sec">Audit log (records fleet activity to a local ledger)</div>
      <label class="s-row"><input type="checkbox" id="s-ledger-en"> Enable the audit/event ledger</label>
      <div class="s-help">Append-only JSONL under ~/.claude/cc-ledger. Records decisions (with who/what decided), prompts, tool requests, spawns, and operator actions — OFF until you enable it. Open the 📜 Audit view to read, filter, export, redact, or purge it.</div>
      <label class="s-row">Keep for <input type="number" id="s-ledger-days" class="s-num" min="0"> days (0 = forever)</label>
      <label class="s-row">Cap total size at <input type="number" id="s-ledger-mb" class="s-num" min="0"> MB (0 = no cap)</label>
      <div class="s-lbl">Only record these event types (space/comma separated; blank = everything)</div>
      <label class="s-row"><input type="text" id="s-ledger-types" class="s-txt" placeholder="decision prompt spawn"></label>

      <div class="s-sec">Editor window pop</div>
      <label class="s-row"><input type="checkbox" id="s-pop-complete"> Pop the editor when a session finishes</label>
      <label class="s-row"><input type="checkbox" id="s-pop-approval"> Pop the editor when a session needs approval</label>
      <div class="s-help">Routes to your detected editor (VS Code / Cursor); Kitty/terminal sessions are left alone. Note: the Claude Code VS Code extension may raise its own window on completion — that's the extension, not Shepherd. Arming Headless approvals stops the approval-time pop entirely.</div>
      <div class="s-sec">Spawn (the + New / New project launcher)</div>
      <label class="s-row">Open new sessions in
        <select id="s-spawn-editor">
          <option value="terminal">Terminal</option>
          <option value="kitty">Kitty</option>
          <option value="vscode">VS Code</option>
          <option value="cursor">Cursor</option>
        </select>
      </label>
      <label class="s-row"><input type="checkbox" id="s-spawn-live"> Actually launch (off = dry-run: log only, don't spawn)</label>
      <label class="s-row"><input type="checkbox" id="s-kitty-remote"> Give spawned Kitty windows remote control (recommended)</label>
      <label class="s-row"><input type="checkbox" id="s-kitty-auto"> Auto-enable Kitty remote control in kitty.conf when Kitty is in use</label>
      <label class="s-row"><button class="s-x" style="border:1px solid #2c2f3a;border-radius:6px;padding:3px 8px;color:#cfd2db;" onclick="send('kitty-remote')">Enable Kitty remote control now</button></label>
      <label class="s-row">Default provider <select id="s-spawn-provider"></select></label>

      <div class="s-sec">Providers (model / company per session)</div>
      <div class="s-help">Each profile launches <code>claude</code> against a model. <b>Claude</b> just sets the model; a <b>Gateway</b> points Claude Code at an Anthropic-compatible endpoint (a LiteLLM proxy for Gemini/OpenAI, or a local/remote REST server) via its base URL. <b>No API keys are stored here</b> — put the key in an environment variable and name that variable below; the spawned shell expands <code>$NAME</code> at launch.</div>
      <div id="s-providers"></div>
      <label class="s-row"><button class="s-x" style="border:1px solid #2c2f3a;border-radius:6px;padding:3px 8px;color:#cfd2db;" onclick="addProvider()">+ Add provider</button></label>

      <div class="s-sec">Policies (auto-decide — gate must be armed)</div>
      <div class="s-help">Each one ON lets some requests be decided WITHOUT you. Headless approvals keeps all three OFF.</div>
      <label class="s-row"><input type="checkbox" id="s-p-rep"> Auto-approve a command already approved this session</label>
      <label class="s-row"><input type="checkbox" id="s-ap-en"> Enable per-session Autopilot, window of <input type="number" id="s-ap-min" class="s-num" min="1"> min</label>
      <div class="s-help">Autopilot auto-approves <i>everything</i> for that one session for N minutes — use sparingly.</div>
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

  <div id="newsession">
    <div id="n-head"><span>New session</span><button class="s-x" onclick="closeNew()">✕</button></div>
    <div id="n-body">
      <div class="n-modes">
        <button id="n-mode-existing" class="n-mode active" onclick="setMode('existing')">Open existing</button>
        <button id="n-mode-new" class="n-mode" onclick="setMode('new')">Start new project</button>
      </div>
      <div class="s-lbl">Project folder</div>
      <input id="n-path" class="s-txt" placeholder="/Users/you/Programming/project">
      <div id="n-newrow" style="display:none;">
        <div class="s-lbl">New folder name (created inside the folder above)</div>
        <input id="n-name" class="s-txt" placeholder="my-new-project">
      </div>
      <div class="s-lbl">Recent</div>
      <div id="n-recent" class="n-recent"></div>
      <div class="s-lbl">Browse</div>
      <div id="n-crumbs" class="n-crumbs"></div>
      <div id="n-dirs" class="n-dirs"></div>
      <div class="n-browse-foot">
        <button onclick="useThisFolder()">Use this folder</button>
        <span id="n-browse-path" class="n-dim"></span>
      </div>
      <div class="s-lbl">Initial task (optional)</div>
      <textarea id="n-task" class="s-area"></textarea>
      <label class="s-row" style="margin-top:8px;">Open in
        <select id="n-editor">
          <option value="terminal">Terminal</option>
          <option value="kitty">Kitty</option>
          <option value="vscode">VS Code</option>
          <option value="cursor">Cursor</option>
        </select>
      </label>
      <label class="s-row">Permission mode
        <select id="n-permmode">
          <option value="">Default</option>
          <option value="plan">Plan</option>
          <option value="acceptEdits">Accept edits</option>
          <option value="bypassPermissions">Automate (bypass)</option>
        </select>
      </label>
      <label class="s-row">Provider <select id="n-provider"></select></label>
    </div>
    <div id="n-foot">
      <button id="n-spawn" onclick="submitNew()">Spawn</button>
      <button onclick="closeNew()">Cancel</button>
    </div>
  </div>

  <div id="insights">
    <div id="i-head">
      <span>Fleet insights</span>
      <button class="s-x" onclick="closeInsights()">✕</button>
    </div>
    <div id="i-body"></div>
    <div id="i-foot">
      <button onclick="openInsights()">Refresh</button>
      <span id="i-info" class="n-dim"></span>
    </div>
  </div>

  <div id="audit">
    <div id="a-head">
      <span>Audit ledger</span>
      <button id="a-tab-rows" class="a-tab active" onclick="auditTab('rows')">Rows</button>
      <button id="a-tab-time" class="a-tab" onclick="auditTab('timeline')">Timeline</button>
      <button class="s-x" onclick="closeAudit()">✕</button>
    </div>
    <div id="a-filters">
      <select id="a-f-session" onchange="auditApply()"></select>
      <select id="a-f-type" onchange="auditApply()">
        <option value="">All types</option>
        <option value="decision">Decisions</option>
        <option value="prompt">Prompts</option>
        <option value="tool_request">Tool requests</option>
        <option value="session_start">Session start</option>
        <option value="session_end">Session end</option>
        <option value="task_feed">Task feeds</option>
        <option value="mode_change">Mode change</option>
        <option value="model_change">Model change</option>
        <option value="effort_change">Effort change</option>
        <option value="clear">Clear</option>
        <option value="compact">Compact</option>
        <option value="nudge">Nudge</option>
        <option value="autopilot_arm">Autopilot</option>
        <option value="spawn">Spawn</option>
        <option value="relabel">Relabel</option>
        <option value="redact">Redact</option>
        <option value="purge">Purge</option>
      </select>
      <input type="text" id="a-f-since" class="s-txt" style="max-width:120px;" placeholder="since YYYY-MM-DD" onchange="auditApply()">
      <input type="text" id="a-f-until" class="s-txt" style="max-width:120px;" placeholder="until YYYY-MM-DD" onchange="auditApply()">
    </div>
    <div id="a-body"></div>
    <div id="a-foot">
      <button onclick="auditReview()" title="Send this slice to the SELECTED session for a read-only governance review">Review activity</button>
      <button onclick="auditExport()">Export</button>
      <button class="danger" onclick="auditPurge()">Purge…</button>
      <span id="a-info" class="n-dim"></span>
    </div>
  </div>

  <script>
    var LABELS = { idle:"Idle", working:"Working",
                   approval:"Needs you", done:"Ready for you", error:"Error" };
    var COLORS = { idle:"#6b7280", working:"#f5b50a", done:"#22c55e", approval:"#ef4444", error:"#ec4899" };
    var BULK_RULES = __BULK_RULES__;  // injected from core.BULK_RULES (single source)
    var lastItems = [];
    var selectedKey = null;
    var searchQuery = "";   // free-text tile filter (🔍); empty = show all
    var activeGroup = "";   // group-chip filter; empty = all groups
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
    // Kill WebKit's native right-click menu everywhere else. On macOS 26 it offers a
    // "Reload" item that BLANKS the panel: our HTML is injected once via wv:html, so a
    // webview reload loads an empty URL -> white screen, app dead. Tiles keep their own
    // menu (showCtx above); ⌘V already handles paste into the inputs, so nothing here
    // needs the native menu. preventDefault on a bubble-phase listener cancels it.
    document.addEventListener("contextmenu", function(e){ e.preventDefault(); }, false);

    // Relabel / Close happen via in-panel bars (no native dialog -> no console pop).
    // Lua's popup-menu items call startRename/startClose; these post the result back.
    var renameKey = null, closeKey = null, groupKey = null;
    function hideBars(){
      renameKey = null; closeKey = null; groupKey = null;
      document.getElementById("renamebar").classList.remove("show");
      document.getElementById("confirmbar").classList.remove("show");
      document.getElementById("setgroupbar").classList.remove("show");
    }
    function startRename(key){
      var it = findItem(key); if(!it) return;
      hideBars();
      renameKey = key;
      var inp = document.getElementById("renamebar-input");
      inp.value = it.label || it.name || "";
      document.getElementById("renamebar").classList.add("show");
      inp.focus(); inp.select();
    }
    // Assign/clear a session's group (cohort tag). Blank input clears it. Keyed
    // server-side by the stable projectKey, like relabel.
    function startGroup(key){
      var it = findItem(key); if(!it) return;
      hideBars();
      groupKey = key;
      var inp = document.getElementById("setgroupbar-input");
      inp.value = it.group || "";
      document.getElementById("setgroupbar").classList.add("show");
      inp.focus(); inp.select();
    }
    function commitGroup(){
      if(groupKey){ send("set-group", groupKey, (document.getElementById("setgroupbar-input").value||"").trim()); }
      hideBars();
    }
    function groupKeydown(e){
      if(e.key === "Enter"){ e.preventDefault(); commitGroup(); }
      else if(e.key === "Escape"){ e.preventDefault(); hideBars(); }
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

    // Caffeinate toggle (F2). Lua is the single source of truth: clicking asks Lua
    // to flip the OS flag, Lua re-reads pmset and calls setCaffeine(realState). The
    // button never optimistically flips, so a cancelled password dialog snaps back.
    var caffeineOn = false;
    function setCaffeine(on){
      caffeineOn = !!on;
      var b = document.getElementById("caffeine");
      if(!b) return;
      b.classList.toggle("active", caffeineOn);
      b.textContent = caffeineOn ? "☕ Awake" : "☕ Sleep ok";
    }
    function toggleCaffeine(){ send("caffeinate", (!caffeineOn).toString()); }

    // ---- Tile search (🔍): client-side filter over the live grid ------------
    // The filter is a JS twin of core.filterTiles (token-AND over the same fields),
    // mirrored here so typing stays instant (no Lua round-trip), like fmtDur/barLevel.
    function searchTokens(){
      var toks = [];
      (searchQuery || "").toLowerCase().split(/\s+/).forEach(function(t){ if(t) toks.push(t); });
      return toks;
    }
    function tileMatches(it, toks){
      if(!toks.length) return true;
      var hay = [it.label||"", it.name||"", it.cwd||"", it.projectKey||"",
                 it.status||"", it.group||""].join(" ").toLowerCase();
      for(var i=0;i<toks.length;i++){ if(hay.indexOf(toks[i]) < 0) return false; }
      return true;
    }
    function visibleItems(){
      var toks = searchTokens();
      return lastItems.filter(function(it){
        if(activeGroup && (it.group || "") !== activeGroup) return false;  // group chip filter
        return tileMatches(it, toks);
      });
    }
    // ---- Group filter chips (shown only when groups exist) ------------------
    var GROUP_NAMES = [];  // JS twin of core.groupNames over lastItems (index = chip)
    function groupNamesJS(){
      var seen = {}, out = [];
      lastItems.forEach(function(it){ var g = it.group; if(g && !seen[g]){ seen[g] = 1; out.push(g); } });
      out.sort();
      return out;
    }
    function setActiveGroup(i){
      var g = (i < 0) ? "" : (GROUP_NAMES[i] || "");
      activeGroup = (activeGroup === g) ? "" : g;  // re-click clears
      renderGrid();
    }
    function renderGroupChips(){
      var bar = document.getElementById("groupchips");
      GROUP_NAMES = groupNamesJS();
      if(!GROUP_NAMES.length){ activeGroup = ""; bar.classList.remove("show"); bar.innerHTML = ""; return; }
      if(activeGroup && GROUP_NAMES.indexOf(activeGroup) < 0) activeGroup = "";  // group vanished
      var chips = '<span class="gchip'+(activeGroup===""?" active":"")+'" onclick="setActiveGroup(-1)">All</span>';
      GROUP_NAMES.forEach(function(g, i){
        chips += '<span class="gchip'+(activeGroup===g?" active":"")+'" onclick="setActiveGroup('+i+')">'+esc(g)+'</span>';
      });
      bar.innerHTML = chips; bar.classList.add("show");
    }

    // ---- Bulk fleet actions (act on the visible set at once) ----------------
    // JS twin of core.selectActionable for the live bar counts. Both sides read the
    // SAME rule table (BULK_RULES, injected from cc-core), so the count can't drift
    // from what Lua re-derives and acts on (WYSIWYG). Only the tiny interpreter is
    // mirrored here; the per-action data lives in one place.
    function actionableKeys(action, items){
      var rule = BULK_RULES[action]; if(!rule) return [];
      return (items || []).filter(function(it){
        if(it.stale || !it.key) return false;
        return (rule.match !== undefined) ? (it.status === rule.match) : (it.status !== rule.exclude);
      }).map(function(it){ return it.key; });
    }
    function sendBulk(action, keys, text){
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify({a:"bulk", v:action, text:text||"", keys:keys})); }
      catch(e){ console.log("bulk send error", e); }
    }
    function bulkAction(action){
      var keys = actionableKeys(action, visibleItems());
      if(!keys.length) return;
      var text = "";
      if(action === "stop"){
        if(!confirm("Stop " + keys.length + " working session(s)? Sends Escape to interrupt each.")) return;
      } else if(action === "nudge"){
        text = prompt("Broadcast a nudge to " + keys.length + " session(s):", "");
        if(text === null || !text.trim()) return;
      }
      sendBulk(action, keys, text);
    }
    function renderBulkBar(vis){
      var bar = document.getElementById("bulkbar");
      var nAp = actionableKeys("approve", vis).length;
      var nSt = actionableKeys("stop", vis).length;
      var nLv = actionableKeys("nudge", vis).length;
      // approve-all earns its place at 1 (clearing an approval backlog is the point);
      // stop/nudge need 2+, since acting on one session is the per-tile button's job.
      if(!(nAp >= 1 || nSt >= 2 || nLv >= 2)){ bar.classList.remove("show"); bar.innerHTML = ""; return; }
      var html = '<span class="bulk-lbl">Fleet</span>';
      if(nAp >= 1) html += '<button class="bulk-ap" onclick="bulkAction(\'approve\')">✅ Approve all (' + nAp + ')</button>';
      if(nSt >= 2) html += '<button class="bulk-st" onclick="bulkAction(\'stop\')">■ Stop all (' + nSt + ')</button>';
      if(nLv >= 2) html += '<button onclick="bulkAction(\'nudge\')">👉 Nudge all (' + nLv + ')</button>';
      bar.innerHTML = html; bar.classList.add("show");
    }
    function toggleSearch(){
      var b = document.getElementById("searchbar");
      var show = !b.classList.contains("show");
      b.classList.toggle("show", show);
      if(show){
        document.getElementById("renamebar").classList.remove("show");
        document.getElementById("confirmbar").classList.remove("show");
        var inp = document.getElementById("searchbar-input"); inp.focus(); inp.select();
      } else {
        searchQuery = ""; document.getElementById("searchbar-input").value = ""; renderGrid();
      }
    }
    function onSearchInput(){ searchQuery = document.getElementById("searchbar-input").value || ""; renderGrid(); }
    function searchKeydown(e){ if(e.key === "Escape"){ e.preventDefault(); toggleSearch(); } }
    function updateSearchCount(shown, total){
      var el = document.getElementById("searchbar-count"); if(!el) return;
      el.textContent = ((searchQuery || "").trim() && total) ? (shown + " / " + total + " shown") : "";
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
    function showSettings(cfg, gateOn, autoOn){
      cfg = cfg || {};
      function ck(id,v){ document.getElementById(id).checked = !!v; }
      function val(id,v){ document.getElementById(id).value = v; }
      ck("s-autolaunch", autoOn);
      ck("s-gate", gateOn);
      ck("s-q-auto", cv(cfg,"queue.autofeed",false));
      ck("s-q-dry",  cv(cfg,"queue.dryRun",false));
      ck("s-e-en",   cv(cfg,"escalation.enabled",false));
      val("s-e-min", cv(cfg,"escalation.minutes",5));
      ck("s-e-snd",  cv(cfg,"escalation.sound",false));
      ck("s-e-push", cv(cfg,"escalation.push",false));
      val("s-e-topic", cv(cfg,"escalation.pushTopic",""));
      var legacyPop = cv(cfg,"focus.popEditor",false);  // back-compat seeds both
      ck("s-pop-complete", cv(cfg,"focus.popOnComplete",legacyPop));
      ck("s-pop-approval", cv(cfg,"focus.popOnApproval",legacyPop));
      val("s-spawn-editor", cv(cfg,"spawn.editor","terminal"));
      ck("s-spawn-live",  cv(cfg,"spawn.live",false));
      ck("s-kitty-remote", cv(cfg,"spawn.kittyRemote",true));
      ck("s-kitty-auto",  cv(cfg,"spawn.kittyAutoRemote",true));
      ck("s-p-rep",  cv(cfg,"policies.approveRepeats",false));
      ck("s-ap-en",  cv(cfg,"policies.autopilot.enabled",false));
      val("s-ap-min", cv(cfg,"policies.autopilot.minutes",15));
      ck("s-pat-en", cv(cfg,"policies.patterns.enabled",false));
      val("s-pat-allow", (cv(cfg,"policies.patterns.autoAllow",[])||[]).join("\n"));
      val("s-pat-deny",  (cv(cfg,"policies.patterns.autoDeny",[])||[]).join("\n"));
      val("s-gate-tools", cv(cfg,"gate.tools","Bash Write Edit MultiEdit NotebookEdit"));
      ck("s-ledger-en",   cv(cfg,"ledger.enabled",false));
      val("s-ledger-days", cv(cfg,"ledger.retentionDays",30));
      val("s-ledger-mb",   cv(cfg,"ledger.maxTotalMB",0));
      val("s-ledger-types", (cv(cfg,"ledger.captureTypes",[])||[]).join(" "));
      // Headless = gate armed AND every auto-policy off.
      ck("s-headless", gateOn && !cv(cfg,"policies.approveRepeats",false)
        && !cv(cfg,"policies.autopilot.enabled",false) && !cv(cfg,"policies.patterns.enabled",false));
      // Providers: editable list + default picker.
      PROVIDERS = (cv(cfg,"providers",[])||[]).map(function(p){ return p||{}; });
      renderProviders();
      refreshProviderDefault(cv(cfg,"spawn.provider",""));
      document.getElementById("settings").classList.add("show");
    }
    // ---- Providers tab (multi-model) ----------------------------------------
    var PROVIDERS = [];
    function slugify(s){ return (s||"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,""); }
    function renderProviders(){
      var box = document.getElementById("s-providers"); box.innerHTML = "";
      PROVIDERS.forEach(function(p, i){
        var kind = (p.kind === "gateway") ? "gateway" : "anthropic";
        var d = document.createElement("div"); d.className = "prov"; d.setAttribute("data-i", i);
        d.innerHTML =
          '<div class="prov-head">'
          + '<input class="s-txt p-label" placeholder="Label (e.g. Claude Opus 4.8)" value="'+esc(p.label)+'">'
          + '<select class="p-kind" onchange="onKindChange('+i+')">'
          + '<option value="anthropic"'+(kind==="anthropic"?" selected":"")+'>Claude</option>'
          + '<option value="gateway"'+(kind==="gateway"?" selected":"")+'>Gateway</option>'
          + '</select>'
          + '<button class="prov-del" onclick="removeProvider('+i+')">Remove</button>'
          + '</div>'
          + '<div class="s-lbl">Model id</div>'
          + '<input class="s-txt p-model" placeholder="claude-opus-4-8 / gemini-2.5-pro / ollama/llama3" value="'+esc(p.model)+'">'
          + '<div class="prov-gw" style="display:'+(kind==="gateway"?"block":"none")+'">'
          + '<div class="s-lbl">Base URL (Anthropic-compatible endpoint, e.g. http://localhost:4000)</div>'
          + '<input class="s-txt p-baseurl" placeholder="http://localhost:4000" value="'+esc(p.baseUrl)+'">'
          + '<div class="s-lbl">Auth-token env var NAME (not the key) — e.g. MY_LITELLM_KEY</div>'
          + '<input class="s-txt p-authenv" placeholder="MY_LITELLM_KEY" value="'+esc(p.authTokenEnv)+'">'
          + '<div class="s-lbl">Small/fast model (optional)</div>'
          + '<input class="s-txt p-smallfast" placeholder="gemini-2.5-flash" value="'+esc(p.smallFastModel)+'">'
          + '<div class="s-lbl">Custom headers (optional, sent as ANTHROPIC_CUSTOM_HEADERS)</div>'
          + '<input class="s-txt p-headers" placeholder="X-Header: value" value="'+esc(p.headers)+'">'
          + '</div>';
        box.appendChild(d);
      });
      if(!PROVIDERS.length){ box.innerHTML = '<div class="s-help" style="margin-left:0;">No providers yet — add one to launch sessions against a model.</div>'; }
    }
    function onKindChange(i){
      var card = document.querySelector('.prov[data-i="'+i+'"]'); if(!card) return;
      var gw = card.querySelector(".prov-gw");
      gw.style.display = (card.querySelector(".p-kind").value === "gateway") ? "block" : "none";
    }
    function addProvider(){
      collectProviders(); // keep current edits
      PROVIDERS.push({ kind:"anthropic", label:"", model:"" });
      renderProviders(); refreshProviderDefault(document.getElementById("s-spawn-provider").value);
    }
    function removeProvider(i){
      collectProviders(); PROVIDERS.splice(i,1);
      renderProviders(); refreshProviderDefault(document.getElementById("s-spawn-provider").value);
    }
    // Read the DOM rows back into PROVIDERS, 1:1 with the cards (blank rows kept so
    // data-i indices stay valid during editing; blanks are dropped only at persist).
    function collectProviders(){
      var out = [];
      document.querySelectorAll("#s-providers .prov").forEach(function(card){
        function v(sel){ var el=card.querySelector(sel); return el? (el.value||"").trim() : ""; }
        var label = v(".p-label"), model = v(".p-model");
        var kind = card.querySelector(".p-kind").value;
        var p = { id: slugify(label) || slugify(model), label: label, kind: kind, model: model };
        if(kind === "gateway"){
          p.baseUrl = v(".p-baseurl"); p.authTokenEnv = v(".p-authenv");
          p.smallFastModel = v(".p-smallfast"); p.headers = v(".p-headers");
        }
        out.push(p);
      });
      PROVIDERS = out;
      return out;
    }
    function nonBlankProviders(){ return collectProviders().filter(function(p){ return p.label || p.model; }); }
    // Populate the default-provider select from the (non-blank) providers, keeping the choice.
    function refreshProviderDefault(want){
      var list = nonBlankProviders();
      var sel = document.getElementById("s-spawn-provider");
      want = want || sel.value || "";
      sel.innerHTML = '<option value="">(none — bare claude)</option>';
      list.forEach(function(p){
        if(!p.id) return;
        var o = document.createElement("option");
        o.value = p.id; o.textContent = (p.label||p.id) + " — " + (p.model||"?");
        if(p.id === want) o.selected = true;
        sel.appendChild(o);
      });
    }
    // Fill an arbitrary <select> from a providers array (modal + per-tile switch).
    function fillProviderSelect(selId, list, want){
      var sel = document.getElementById(selId); if(!sel) return;
      sel.innerHTML = '<option value="">(none — bare claude)</option>';
      (list||[]).forEach(function(p){
        if(!p || !p.id) return;
        var o = document.createElement("option");
        o.value = p.id; o.textContent = (p.label||p.id) + " — " + (p.model||"?");
        if(p.id === (want||"")) o.selected = true;
        sel.appendChild(o);
      });
    }
    function lines(id){
      return (document.getElementById(id).value||"").split("\n")
        .map(function(s){return s.trim();}).filter(function(s){return s.length>0;});
    }
    function toks(id){
      return (document.getElementById(id).value||"").split(/[\s,]+/).filter(function(s){return s.length>0;});
    }
    function persistSettings(){
      function ck(id){ return document.getElementById(id).checked; }
      function num(id,d){ var n=parseInt(document.getElementById(id).value,10); return isNaN(n)?d:n; }
      function txt(id){ return document.getElementById(id).value||""; }
      var config = {
        queue: { autofeed: ck("s-q-auto"), dryRun: ck("s-q-dry") },
        escalation: { enabled: ck("s-e-en"), minutes: num("s-e-min",5), sound: ck("s-e-snd"),
                      push: ck("s-e-push"), pushTopic: txt("s-e-topic") },
        focus: { popOnComplete: ck("s-pop-complete"), popOnApproval: ck("s-pop-approval") },
        spawn: { editor: txt("s-spawn-editor"), live: ck("s-spawn-live"),
                 kittyRemote: ck("s-kitty-remote"), kittyAutoRemote: ck("s-kitty-auto"),
                 provider: txt("s-spawn-provider") },
        providers: nonBlankProviders(),
        gate: { tools: txt("s-gate-tools") },
        ledger: { enabled: ck("s-ledger-en"), retentionDays: num("s-ledger-days",30),
                  maxTotalMB: num("s-ledger-mb",0), captureTypes: toks("s-ledger-types") },
        policies: {
          approveRepeats: ck("s-p-rep"),
          autopilot: { enabled: ck("s-ap-en"), minutes: num("s-ap-min",15) },
          patterns: { enabled: ck("s-pat-en"), autoAllow: lines("s-pat-allow"), autoDeny: lines("s-pat-deny") }
        }
      };
      send("save-config", "", JSON.stringify({ config: config, gate: ck("s-gate"), autoLaunch: ck("s-autolaunch") }));
    }
    function saveSettings(){ persistSettings(); closeSettings(); }
    // One-click: arm the gate + force all auto-policies OFF (or disarm when off),
    // then persist immediately WITHOUT closing so you can still tweak the tool list.
    function onHeadlessToggle(){
      var on = document.getElementById("s-headless").checked;
      document.getElementById("s-gate").checked = on;
      if(on){
        document.getElementById("s-p-rep").checked = false;
        document.getElementById("s-ap-en").checked = false;
        document.getElementById("s-pat-en").checked = false;
        var t = document.getElementById("s-gate-tools");
        if(!(t.value||"").trim()) t.value = "Bash Write Edit MultiEdit NotebookEdit";
      }
      persistSettings();
    }

    // ---- New-session modal (F3-F5): browse + recents + new project ----------
    var browsePath = "";        // folder currently shown in the browser
    var newMode = "existing";
    function openNew(){ send("open-new"); }
    function closeNew(){ document.getElementById("newsession").classList.remove("show"); }
    function setMode(m){
      newMode = m;
      document.getElementById("n-mode-existing").classList.toggle("active", m === "existing");
      document.getElementById("n-mode-new").classList.toggle("active", m === "new");
      document.getElementById("n-newrow").style.display = (m === "new") ? "block" : "none";
    }
    // Lua pushes config + recent dirs + the initial folder listing.
    function showNew(cfg, recent, browse){
      cfg = cfg || {};
      setMode("existing");
      document.getElementById("n-path").value = "";
      document.getElementById("n-name").value = "";
      document.getElementById("n-task").value = "";
      document.getElementById("n-editor").value = cv(cfg, "spawn.editor", "terminal");
      fillProviderSelect("n-provider", cv(cfg,"providers",[])||[], cv(cfg,"spawn.provider",""));
      renderRecent(recent || []);
      ccBrowse(browse || { path:"", parent:"", dirs:[] });
      document.getElementById("newsession").classList.add("show");
      document.getElementById("n-path").focus();
    }
    function shortPath(p){
      var parts = (p||"").split("/").filter(Boolean);
      return parts.length <= 2 ? p : ".../" + parts.slice(-2).join("/");
    }
    function renderRecent(dirs){
      var box = document.getElementById("n-recent"); box.innerHTML = "";
      if(!dirs.length){ box.innerHTML = '<span class="n-dim">No recent folders yet</span>'; return; }
      dirs.forEach(function(d){
        var b = document.createElement("button");
        b.className = "n-chip"; b.textContent = shortPath(d); b.title = d;
        b.onclick = function(){ pickRecent(d); };
        box.appendChild(b);
      });
    }
    function browseTo(path){ send("list-dir", path); }
    // Lua replies to "list-dir" / "open-new" with { path, parent, dirs }.
    function ccBrowse(res){
      res = res || {};
      browsePath = res.path || "";
      document.getElementById("n-browse-path").textContent = browsePath;
      var cr = document.getElementById("n-crumbs"); cr.innerHTML = "";
      var crumbs = crumbsFor(browsePath);
      crumbs.forEach(function(c, i){
        var s = document.createElement("span");
        s.className = "n-crumb"; s.textContent = c.name;
        s.onclick = function(){ browseTo(c.path); };
        cr.appendChild(s);
        if(i < crumbs.length - 1){ var sep = document.createElement("span"); sep.textContent = " / "; cr.appendChild(sep); }
      });
      var box = document.getElementById("n-dirs"); box.innerHTML = "";
      if(res.parent && res.parent !== browsePath){
        var up = document.createElement("div");
        up.className = "n-dir up"; up.textContent = "⬆ ..";
        up.onclick = function(){ browseTo(res.parent); };
        box.appendChild(up);
      }
      (res.dirs || []).forEach(function(name){
        var d = document.createElement("div");
        d.className = "n-dir"; d.textContent = "📁 " + name;
        d.onclick = function(){ browseTo(joinPath(browsePath, name)); };
        box.appendChild(d);
      });
      if(!(res.dirs || []).length){
        var e = document.createElement("div"); e.className = "n-dir n-dim"; e.textContent = "(no subfolders)";
        box.appendChild(e);
      }
    }
    function crumbsFor(path){
      var out = [{ name:"/", path:"/" }], acc = "";
      (path||"").split("/").filter(Boolean).forEach(function(seg){ acc += "/" + seg; out.push({ name: seg, path: acc }); });
      return out;
    }
    function joinPath(base, name){
      if(!base || base === "/") return "/" + name;
      return base.replace(/\/+$/, "") + "/" + name;
    }
    function useThisFolder(){ document.getElementById("n-path").value = browsePath; }
    function pickRecent(dir){ document.getElementById("n-path").value = dir; browseTo(dir); }
    function submitNew(){
      var path = (document.getElementById("n-path").value || "").trim();
      var name = (document.getElementById("n-name").value || "").trim();
      var task = (document.getElementById("n-task").value || "").trim();
      var editor = document.getElementById("n-editor").value;
      var payload = { a:"spawn", v:"", text:task, img:"", mode:newMode, editor:editor,
                      permMode: document.getElementById("n-permmode").value,
                      provider: document.getElementById("n-provider").value };
      if(newMode === "new"){ payload.parent = path; payload.name = name; } else { payload.dir = path; }
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify(payload)); } catch(e){ console.log("spawn send error", e); }
      closeNew();
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
      ["pending","activity"].forEach(function(which){
        document.getElementById("d-" + which).classList.toggle("expanded", detailExpanded[which]);
      });
    }
    function paintSelection(){
      var tiles = document.querySelectorAll(".tile");
      tiles.forEach(function(t){ t.classList.toggle("sel", t.dataset.key === selectedKey); });
    }

    function onEffortChange(){
      var lvl = document.getElementById("effort").value;
      if(selectedKey) send("effort", selectedKey, lvl);
    }
    // Cycle the permission mode via Shift+Tab x N (Part C). Lua computes N from the
    // current mode; kitty drives it reliably, VS Code is best-effort.
    function onModeChange(){
      var m = document.getElementById("mode").value;
      if(selectedKey) send("set-mode", selectedKey, m);
    }
    // Switch model live via /model. Sends the chosen model id (works within the
    // session's current backend; a provider/base-URL change needs a new session).
    function onModelChange(){
      var m = document.getElementById("d-model").value;
      if(selectedKey && m) send("model", selectedKey, m);
    }
    // Per-session gated-tools override (Feature D). "custom" prompts for an explicit
    // list; the rest send a scope keyword the native side resolves to a file value.
    var lastGateCustom = "";
    function onGateChange(){
      if(!selectedKey) return;
      var sel = document.getElementById("d-gate");
      var v = sel.value;
      if(v === "custom"){
        var s = prompt("Gate which tools for this session? (space/comma separated)", lastGateCustom);
        if(s === null){ syncGateSelect(findItem(selectedKey)); return; }  // cancelled
        lastGateCustom = s;
        send("set-gate-tools", selectedKey, s);
      } else {
        send("set-gate-tools", selectedKey, v);  // "" = default, "all", "none"
      }
    }
    // Reflect a session's current override in the Gate dropdown: absent -> Default,
    // "-"/NONE -> None, a list equal to the fleet default -> Default, else Custom.
    function syncGateSelect(it){
      var sel = document.getElementById("d-gate"); if(!sel || !it) return;
      var ovr = it.gate_tools_override;
      var val;
      if(ovr == null || String(ovr).trim() === "") val = "";
      else {
        var norm = String(ovr).replace(/\s+/g,"").toUpperCase();
        if(norm === "-" || norm === "NONE") val = "none";
        else { val = "custom"; lastGateCustom = String(ovr).replace(/,/g," ").replace(/\s+/g," ").trim(); }
      }
      sel.value = val;
      sel.title = "Effective gated tools for this session: "
        + ((it.gate_tools_effective && it.gate_tools_effective !== "") ? it.gate_tools_effective : "(none)")
        + " — only enforced while headless approvals are armed.";
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
    // Small badges: detected editor + live permission mode + effort + model.
    function renderMeta(it){
      var el = document.getElementById("d-meta"), bits = [];
      if(it.editor) bits.push(it.editor);
      if(it.permission_mode) bits.push("mode: " + it.permission_mode);
      if(it.effort) bits.push("effort: " + it.effort);
      if(it.model) bits.push("model: " + it.model);
      var cf = ctxFracFor(it);
      if(cf != null) bits.push("ctx: " + Math.round(cf*100) + "%");
      if(bits.length){ el.textContent = bits.join("  ·  "); el.style.display="block"; }
      else { el.style.display="none"; el.textContent=""; }
      var ef = document.getElementById("effort"); if(ef && it.effort) ef.value = it.effort;
      var md = document.getElementById("mode"); if(md && it.permission_mode) md.value = it.permission_mode;
      // Model dropdown: list the configured providers' models, plus the session's
      // live model (so it shows even if no profile matches), selected to it.model.
      var dm = document.getElementById("d-model");
      if(dm){
        var seen = {}, models = [];
        (PANEL_PROVIDERS||[]).forEach(function(p){ if(p && p.model && !seen[p.model]){ seen[p.model]=1; models.push(p.model); } });
        if(it.model && !seen[it.model]){ models.unshift(it.model); }
        dm.innerHTML = '<option value="">(model…)</option>'
          + models.map(function(m){ return '<option value="'+esc(m)+'">'+esc(m)+'</option>'; }).join("");
        if(it.model) dm.value = it.model;
      }
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
      if(st === "error"){ ac.textContent = "Error: " + (it.error_message || "API error — stopped"); ac.style.display="block"; }
      else if(it.activity){ ac.textContent = (st==="approval" ? "Why: " : "Doing: ") + it.activity; ac.style.display="block"; }
      else { ac.style.display="none"; }
      var pr = document.getElementById("d-prompt");
      if(it.last_prompt){ pr.textContent = "Last: " + it.last_prompt; pr.style.display="block"; }
      else { pr.style.display="none"; }
      renderAsk(it);
      renderMeta(it);
      syncGateSelect(it);
      renderDetailUsage(it);
      var n = it.queue || 0;
      document.getElementById("q-count").textContent = n>0 ? ("Queue: " + n) : "Queue: empty";
      document.getElementById("b-feed").style.display = n>0 ? "inline-block" : "none";
      var ba = document.getElementById("b-auto");
      ba.textContent = it.autopilot ? "Autopilot: ON" : "Autopilot";
      ba.style.color = it.autopilot ? "#8fd4a3" : "#e8e9ee";
      // Errored session: the Approve button becomes Continue (types "continue" + Enter to
      // resume the aborted turn). Restored to Approve for every other status.
      var bap = document.getElementById("b-approve");
      if(st === "error"){
        bap.textContent = "Continue";
        bap.setAttribute("onclick", "act('continue')");
        bap.style.borderColor = "#ec4899"; bap.style.color = "#f3a9d0";
      } else {
        bap.textContent = "Approve";
        bap.setAttribute("onclick", "act('approve')");
        bap.style.borderColor = ""; bap.style.color = "";
      }
      applyExpand();
    }

    // ---- Token usage (local, zero-cost) -------------------------------------
    var LAST_USAGE = null;
    function fmtTok(n){
      n = n || 0;
      if(n >= 1e9) return (n/1e9).toFixed(2)+"B";
      if(n >= 1e6) return (n/1e6).toFixed(2)+"M";
      if(n >= 1e3) return (n/1e3).toFixed(1)+"k";
      return String(Math.floor(n));
    }
    function barLevel(f){ return f>=0.9 ? "full" : (f>=0.75 ? "warn" : "ok"); }
    // Context for a tile: prefer the live 1s value (active sessions), else the 60s
    // usage pass (covers stale/done tiles — which is most of them between turns).
    function psFor(it){ return (LAST_USAGE && LAST_USAGE.perSession) ? LAST_USAGE.perSession[it.key] : null; }
    function ctxFracFor(it){ if(it.context_frac != null) return it.context_frac; var p = psFor(it); return p ? p.context_frac : null; }
    function ctxTokFor(it){ if(it.context_tokens != null) return it.context_tokens; var p = psFor(it); return p ? p.context_tokens : null; }
    function ctxBarHtml(it){
      var frac = ctxFracFor(it);
      if(frac == null) return "";   // no usage yet / unknown -> no bar
      var pct = Math.round(frac*100);
      var tok = ctxTokFor(it); tok = (tok != null) ? fmtTok(tok) : "";
      return '<div class="ctx-bar '+barLevel(frac)+'" title="Context: '+tok+' ('+pct+'% of window)"><i style="width:'+pct+'%"></i></div>';
    }
    var LAST_OFFICIAL = null;
    // ---- Audit ledger view --------------------------------------------------
    var AUDIT = { events: [], files: [], truncated: false };
    var auditView = "rows";
    function openAudit(){ send("open-audit-view"); }
    function closeAudit(){ document.getElementById("audit").classList.remove("show"); }
    // Per-session drill-down: open the audit overlay scoped to the selected
    // session's chronological timeline. Needs the ledger on + a session id.
    function openSessionTimeline(){
      if(!selectedKey) return;
      var it = findItem(selectedKey);
      if(!it || !it.session_id){
        alert("No recorded activity for this session yet (the ledger is off, or this session has no id).");
        return;
      }
      send("open-session-timeline", selectedKey);
    }

    // ---- Fleet insights view (Feature A) ------------------------------------
    function openInsights(){ send("open-insights-view"); }
    function closeInsights(){ document.getElementById("insights").classList.remove("show"); }
    function fmtDur(s){
      s = Math.max(0, Math.round(s||0));
      if(s < 60) return s+"s";
      var m = Math.floor(s/60);
      if(m < 60) return (s%60) ? (m+"m "+(s%60)+"s") : (m+"m");
      var h = Math.floor(m/60); return (m%60) ? (h+"h "+(m%60)+"m") : (h+"h");
    }
    // Inline SVG sparkline from a [{ts,value}] series (Feature 6). opts:{w,h,color,max}.
    function sparkline(series, opts){
      opts = opts || {};
      var w = opts.w || 260, h = opts.h || 30, pad = 3;
      if(!series || !series.length) return '<span class="spark-empty">no data in range</span>';
      var max = opts.max || 0;
      if(!max){ series.forEach(function(p){ if(p.value > max) max = p.value; }); }
      if(max <= 0) max = 1;
      var n = series.length, innerW = w - 2*pad, innerH = h - 2*pad;
      var xAt = function(i){ return pad + (n === 1 ? innerW/2 : (i/(n-1))*innerW); };
      var yAt = function(v){ return pad + innerH - (Math.max(0, Math.min(v, max))/max)*innerH; };
      var pts = series.map(function(p, i){ return xAt(i).toFixed(1)+","+yAt(p.value).toFixed(1); }).join(" ");
      var color = opts.color || "#6ea8fe", lastI = n-1;
      return '<svg class="spark" width="'+w+'" height="'+h+'" viewBox="0 0 '+w+' '+h+'" preserveAspectRatio="none">'
        + '<polyline points="'+pts+'" fill="none" stroke="'+color+'" stroke-width="1.5" stroke-linejoin="round" />'
        + '<circle cx="'+xAt(lastI).toFixed(1)+'" cy="'+yAt(series[lastI].value).toFixed(1)+'" r="1.8" fill="'+color+'" />'
        + '</svg>';
    }
    function sparkRow(label, series, opts){
      opts = opts || {}; series = series || [];
      var peak = 0, last = series.length ? series[series.length-1].value : 0;
      series.forEach(function(p){ if(p.value > peak) peak = p.value; });
      var f = function(v){ return opts.fmt === "dur" ? fmtDur(v) : (opts.fmt === "pct" ? Math.round(v*100)+"%" : Math.round(v)); };
      return '<div class="spark-row"><div class="spark-lbl">'+esc(label)+'</div>'
        + sparkline(series, opts)
        + '<div class="spark-val">now '+esc(f(last))+' · peak '+esc(f(peak))+'</div></div>';
    }
    window.ccInsights = function(st){
      st = st || {};
      var body = document.getElementById("i-body");
      var tot = st.totals || {}, dec = st.decisions || {}, prov = st.provenance || {};
      var card = function(v, k){ return '<div class="i-card"><div class="v">'+esc(v)+'</div><div class="k">'+esc(k)+'</div></div>'; };
      var pct = function(x){ return Math.round((x||0)*100)+"%"; };
      var html = '<div class="i-cards">'
        + card(tot.sessions||0, "sessions")
        + card(tot.prompts||0, "prompts (turns)")
        + card(tot.toolRequests||0, "tool requests")
        + card(tot.spawns||0, "spawns")
        + card(dec.total||0, "decisions")
        + card(pct(st.approvalRate), "approval rate")
        + card(pct(st.denialRate), "denial rate")
        + card(fmtDur(st.approvalBlockedSeconds), "fleet time blocked on you")
        + '</div>';
      // Decision split + provenance
      html += '<div class="i-sec">Decisions</div><table class="i-tbl"><tr><th>outcome</th><th class="n">count</th></tr>'
        + '<tr><td>✅ allow</td><td class="n">'+(dec.allow||0)+'</td></tr>'
        + '<tr><td>⛔ deny</td><td class="n">'+(dec.deny||0)+'</td></tr>'
        + '<tr><td>⚠ fallback (timeout)</td><td class="n">'+(dec.fallback||0)+'</td></tr></table>';
      var provKeys = Object.keys(prov);
      if(provKeys.length){
        html += '<div class="i-sec">Decision provenance</div><table class="i-tbl"><tr><th>by</th><th class="n">count</th></tr>';
        provKeys.sort(function(a,b){ return prov[b]-prov[a]; }).forEach(function(k){
          html += '<tr><td>'+esc(k)+'</td><td class="n">'+prov[k]+'</td></tr>';
        });
        html += '</table>';
      }
      // Most active sessions
      var ma = st.mostActive || [];
      if(ma.length){
        html += '<div class="i-sec">Most active sessions</div><table class="i-tbl">'
          + '<tr><th>session</th><th class="n">turns</th><th class="n">tools</th><th class="n">denials</th><th class="n">blocked</th></tr>';
        ma.forEach(function(s){
          html += '<tr><td>'+esc(s.name||s.session_id||"?")+'</td><td class="n">'+(s.prompts||0)
                + '</td><td class="n">'+(s.toolRequests||0)+'</td><td class="n">'+pct(s.denialRate)
                + '</td><td class="n">'+fmtDur(s.blockedSeconds)+'</td></tr>';
        });
        html += '</table>';
      }
      // Trend sparklines (last 24h, hourly) — Feature 6.
      if(st.spark){
        html += '<div class="i-sec">Trends — last 24h (hourly)</div>';
        html += sparkRow("Blocked on you", st.spark.blocked, { color:"#ef4444", fmt:"dur" });
        html += sparkRow("Fleet activity", st.spark.activity, { color:"#6ea8fe" });
        html += sparkRow("Active sessions", st.spark.active, { color:"#22c55e" });
        html += sparkRow("Denial rate", st.spark.denialRate, { color:"#f5b50a", fmt:"pct", max:1 });
      }
      if((tot.events||0) === 0){
        html += '<div class="n-dim" style="margin-top:12px;">No ledger activity yet. Enable the ledger ('
          + 'ledger.enabled in cc-config.json) to record fleet activity for these stats.</div>';
      }
      body.innerHTML = html;
      document.getElementById("i-info").textContent = (tot.events||0) + " event(s)";
      document.getElementById("insights").classList.add("show");
    };
    function auditTab(v){
      auditView = v;
      document.getElementById("a-tab-rows").classList.toggle("active", v === "rows");
      document.getElementById("a-tab-time").classList.toggle("active", v === "timeline");
      renderAudit();
    }
    // YYYY-MM-DD -> epoch seconds (UTC midnight, or end-of-day for `until`).
    function dateToTs(s, endOfDay){
      s = (s || "").trim(); if(!s) return null;
      var m = s.match(/^(\d{4})-(\d{2})-(\d{2})$/); if(!m) return null;
      var t = Date.UTC(+m[1], +m[2]-1, +m[3]) / 1000;
      return endOfDay ? t + 86399 : t;
    }
    function currentFilter(){
      return { session: document.getElementById("a-f-session").value || "",
               type:    document.getElementById("a-f-type").value || "",
               sinceTs: dateToTs(document.getElementById("a-f-since").value, false),
               untilTs: dateToTs(document.getElementById("a-f-until").value, true) };
    }
    // Server-side filter shape (for export/purge/review — full data, not the capped slice).
    function serverFilter(){
      var f = currentFilter(), o = {};
      if(f.session) o.session = f.session;
      if(f.type) o.types = [f.type];
      if(f.sinceTs != null) o.sinceTs = f.sinceTs;
      if(f.untilTs != null) o.untilTs = f.untilTs;
      return o;
    }
    function auditPasses(e, f){
      if(f.session && e.session_id !== f.session) return false;
      if(f.type && e.type !== f.type) return false;
      if(f.sinceTs != null && (e.ts || 0) < f.sinceTs) return false;
      if(f.untilTs != null && (e.ts || 0) > f.untilTs) return false;
      return true;
    }
    function auditApply(){ renderAudit(); }  // filtering is client-side over the loaded slice
    function fmtTs(ts){
      if(!ts) return "????-??-?? ??:??";
      var d = new Date(ts * 1000), p = function(n){ return (n<10?"0":"") + n; };
      return d.getFullYear()+"-"+p(d.getMonth()+1)+"-"+p(d.getDate())+" "+p(d.getHours())+":"+p(d.getMinutes());
    }
    var EV_EMOJI = { session_start:"🟢", session_end:"⚪", prompt:"📝", tool_request:"🔧",
      task_feed:"📥", mode_change:"🎚", model_change:"🤖", effort_change:"🎚", clear:"🧹",
      compact:"🗜", nudge:"👉", autopilot_arm:"🛫", spawn:"✨", relabel:"🏷", redact:"🚫", purge:"🗑" };
    function evDesc(e){
      if(e.type === "decision"){
        return (e.outcome === "deny" ? "⛔" : "✅") + " " + (e.outcome || "?") + " " + (e.tool || "")
          + (e.summary ? (' "' + e.summary + '"') : "")
          + (e.by ? (" (" + e.by + (e.pattern ? (": " + e.pattern) : "") + ")") : "");
      }
      var em = EV_EMOJI[e.type] || "•";
      var detail = e.prompt || e.summary || e.task || e.text || e.message || "";
      if(e.type === "mode_change" || e.type === "model_change" || e.type === "effort_change")
        detail = (e.from || "") + " → " + (e.to || "?");
      else if(e.type === "tool_request") detail = (e.tool || "") + (e.summary ? (' "' + e.summary + '"') : "");
      else if(e.type === "spawn") detail = (e.editor || "") + " " + (e.kind || "") + (e.dryRun ? " (dry-run)" : "");
      else if(e.type === "purge") detail = (e.count != null ? (e.count + " event(s)") : "");
      return em + " " + e.type + (detail ? (": " + detail) : "");
    }
    function narr(e){ return fmtTs(e.ts) + "  " + (e.name || e.session_id || "?") + "  " + evDesc(e) + (e.redacted ? " [redacted]" : ""); }
    function auditRow(e){
      var hasContent = (e.prompt || e.summary || e.task || e.text || e.message);
      var canRedact = hasContent && !e.redacted;
      return '<div class="a-row">'
        + '<span class="a-ts">' + esc(fmtTs(e.ts)) + '</span>'
        + '<span class="a-name">' + esc(e.name || e.session_id || "?") + '</span>'
        + '<span class="a-desc">' + esc(evDesc(e)) + (e.redacted ? ' <i class="a-redacted">[redacted]</i>' : '') + '</span>'
        + (canRedact ? '<button class="a-redact" onclick="auditRedact(\'' + e.id + '\',' + (e.ts || 0) + ')">redact</button>' : '')
        + '</div>';
    }
    function populateAuditSessions(){
      var sel = document.getElementById("a-f-session"), cur = sel.value, seen = {};
      var opts = '<option value="">All sessions</option>';
      (AUDIT.events || []).forEach(function(e){
        if(e.session_id && !seen[e.session_id]){ seen[e.session_id] = 1;
          opts += '<option value="' + esc(e.session_id) + '">' + esc(e.name || e.session_id) + '</option>'; }
      });
      sel.innerHTML = opts; if(cur) sel.value = cur;
    }
    function renderAudit(){
      var f = currentFilter();
      var evs = (AUDIT.events || []).filter(function(e){ return auditPasses(e, f); });
      document.getElementById("a-info").textContent = evs.length + " shown"
        + (AUDIT.truncated ? " · newest " + (AUDIT.events || []).length + " loaded (older not shown)" : "");
      var body = document.getElementById("a-body");
      if(auditView === "timeline"){
        var asc = evs.slice().sort(function(a, b){ return (a.ts || 0) - (b.ts || 0); });
        body.innerHTML = asc.length
          ? '<pre class="a-narr">' + esc(asc.map(narr).join("\n")) + '</pre>'
          : '<div class="s-help" style="margin-left:0;">No events in range.</div>';
        return;
      }
      body.innerHTML = evs.length
        ? evs.map(auditRow).join("")
        : '<div class="s-help" style="margin-left:0;">No events in range.</div>';
    }
    function auditRedact(id, ts){
      send("audit-redact", "", JSON.stringify({ id: id, ts: ts,
        fields: ["prompt","summary","task","text","message","command"] }));
    }
    function auditReview(){ send("audit-review", selectedKey || "", JSON.stringify(serverFilter())); }
    function auditExport(){ send("audit-export", "", JSON.stringify(serverFilter())); }
    function auditPurge(){ send("audit-purge", "", JSON.stringify(serverFilter())); }  // Lua confirms
    window.ccAudit = function(payload, focusSession, focusView){
      AUDIT = payload || { events: [], files: [], truncated: false };
      if(!Array.isArray(AUDIT.events)) AUDIT.events = [];
      if(!Array.isArray(AUDIT.files)) AUDIT.files = [];
      populateAuditSessions();
      // Per-session drill-down (Timeline button): pre-select the session + view.
      if(focusSession){ var sel = document.getElementById("a-f-session"); if(sel) sel.value = focusSession; }
      document.getElementById("audit").classList.add("show");
      if(focusView){ auditTab(focusView); }  // auditTab also re-renders
      else { renderAudit(); }
    };

    window.ccUsage = function(u){ LAST_USAGE = u || null; if(u && u.official) LAST_OFFICIAL = u.official; renderUsageFoot(); renderDetail(); };
    window.ccOfficial = function(o){ LAST_OFFICIAL = o || null; renderUsageFoot(); };
    function pctBarRow(lbl, pct, valText){
      pct = Math.max(0, Math.min(100, Math.round(pct||0)));
      var lvl = pct>=90 ? "full" : (pct>=75 ? "warn" : "ok");
      return '<div class="uf-win"><span class="lbl">'+lbl+'</span><span class="bar '+lvl+'"><i style="width:'+pct+'%"></i></span><span class="val">'+valText+'</span></div>';
    }
    function resetsIn(iso){
      if(!iso) return "";
      var ms = Date.parse(iso) - Date.now(); if(isNaN(ms) || ms<=0) return "";
      var m = Math.round(ms/60000);
      var d = Math.floor(m/1440), h = Math.floor((m%1440)/60), mm = m%60;
      var parts = [];
      if(d>0) parts.push(d+"d");
      if(d>0 || h>0) parts.push(h+"h");
      parts.push(mm+"m");
      return "resets in "+parts.join(" ");
    }
    function renderUsageFoot(){
      var totEl = document.getElementById("uf-total"), winEl = document.getElementById("uf-windows");
      if(!LAST_USAGE){ totEl.textContent = "Fleet: —"; winEl.innerHTML = ""; return; }
      var f = LAST_USAGE.fleet || {};
      // Headline excludes cache reads (the meaningful number); gross shown on hover.
      totEl.textContent = "Fleet: " + fmtTok(f.real||0) + " tokens · " + fmtTok(f.output||0) + " out";
      totEl.title = "excl. cache reads · gross " + fmtTok(f.total||0) + " (incl. cache)";
      var o = LAST_OFFICIAL;
      if(o && o.five_hour){
        // OFFICIAL plan window — matches claude.ai/settings/usage exactly.
        var rows = pctBarRow("Session (5h)", o.five_hour.utilization, Math.round(o.five_hour.utilization||0)+"%")
          + pctBarRow("Weekly", (o.seven_day&&o.seven_day.utilization)||0, Math.round((o.seven_day&&o.seven_day.utilization)||0)+"%");
        if(o.seven_day_sonnet && o.seven_day_sonnet.utilization != null){
          rows += pctBarRow("Weekly · Sonnet", o.seven_day_sonnet.utilization, Math.round(o.seven_day_sonnet.utilization)+"%");
        }
        var reset5 = resetsIn(o.five_hour.resets_at), reset7 = resetsIn(o.seven_day && o.seven_day.resets_at);
        winEl.innerHTML = rows + '<span class="uf-approx" style="font-style:normal;">official · '
          + (reset5 ? "5h "+reset5 : "") + (reset5&&reset7 ? " · " : "") + (reset7 ? "weekly "+reset7 : "") + '</span>';
      } else {
        // Local approximation fallback (no official token / endpoint unavailable).
        var w = LAST_USAGE.window || {};
        var max = Math.max(w.w7d||0, 1);
        function winRow(lbl, tokens){
          var pct = Math.round(Math.min(1, (tokens||0)/max)*100);
          return '<div class="uf-win"><span class="lbl">'+lbl+'</span><span class="bar"><i style="width:'+pct+'%"></i></span><span class="val">'+fmtTok(tokens||0)+'</span></div>';
        }
        winEl.innerHTML = winRow("5h (approx)", w.w5h) + winRow("7d (approx)", w.w7d)
          + '<span class="uf-approx">approx from local transcripts — official % unavailable (no Claude login token found)</span>';
      }
    }

    // Per-session cumulative breakdown in the detail panel (from the 60s usage pass).
    function renderDetailUsage(it){
      var du = document.getElementById("d-usage"); if(!du) return;
      var ps = (LAST_USAGE && LAST_USAGE.perSession) ? LAST_USAGE.perSession[it.key] : null;
      if(!ps){ du.style.display="none"; du.innerHTML=""; return; }
      var rows = '<div class="um-row"><span>Session total</span><span title="excl. cache reads; gross '+fmtTok(ps.total)+'">'+fmtTok(ps.real != null ? ps.real : ps.total)+'</span></div>'
        + '<div class="um-row"><span>output / input</span><span>'+fmtTok(ps.output)+' / '+fmtTok(ps.input)+'</span></div>';
      if(ps.byModel){ Object.keys(ps.byModel).forEach(function(m){
        rows += '<div class="um-row"><span>'+esc(m)+'</span><span>'+fmtTok(ps.byModel[m].total)+'</span></div>';
      }); }
      du.innerHTML = rows; du.style.display="block";
    }

    var PANEL_PROVIDERS = [];
    window.ccUpdate = function(items, providers){
      lastItems = items || [];
      if(providers !== undefined) PANEL_PROVIDERS = providers || [];
      renderGrid();
      renderDetail();
    };

    // One tile's HTML. Extracted from ccUpdate so renderGrid can map the (filtered)
    // visible set without duplicating the markup.
    function tileHtml(it){
      var st = it.status || "idle";
      var label = LABELS[st] || st;
      var meta = "";
      if(st === "approval" && it.pending && it.pending.summary){
        meta = "wants: " + it.pending.summary;
      } else if(st === "error"){
        meta = it.error_message || "API error — stopped";
      } else if(it.since){
        meta = fmtAge(it.since);
      }
      if(it.queue > 0){ meta = (meta ? meta + " · " : "") + "+" + it.queue + " queued"; }
      if(it.autopilot){ meta = (meta ? meta + " · " : "") + "🛫 autopilot"; }
      if(it.draining){ meta = (meta ? meta + " · " : "") + "⛔ draining"; }
      if(it.collide){ meta = (meta ? meta + " · " : "") + "⚠ shared dir"; }
      if(it.hung){ meta = (meta ? meta + " · " : "") + "⏳ stalled"; }
      var cls = "tile s-" + st + (it.stale ? " stale" : "") + (it.collide ? " collide" : "") + (it.hung ? " hung" : "") + (it.escalate ? " escalate" : "") + (it.key === selectedKey ? " sel" : "");
      return '<div class="'+cls+'" data-key="'+esc(it.key)+'" onclick="selectTile(\''+esc(it.key)+'\')" ondblclick="send(\'focus\',\''+esc(it.key)+'\')" oncontextmenu="showCtx(event,\''+esc(it.key)+'\')" title="Double-click to jump · right-click for more">'
           + '<span class="dot"></span>'
           + '<span class="name">'+esc(it.label || it.name)+(it.group ? ' <span class="gtag">🏷 '+esc(it.group)+'</span>' : '')+'</span>'
           + '<span class="label">'+label+'</span>'
           + riskBadge(it)
           + '<span class="meta">'+esc(meta)+'</span>'
           + ctxBarHtml(it)
           + '</div>';
    }

    var EMPTY_WAITING = 'Waiting for Claude Code sessions...<br>Start a session in any project.';
    // Render the grid from lastItems through the active search filter. Re-run both on
    // a fresh ccUpdate and on every keystroke in the search bar (no re-fetch needed).
    function renderGrid(){
      var grid  = document.getElementById("grid");
      var empty = document.getElementById("empty");
      renderGroupChips();  // refresh the group filter row from the latest data
      if(lastItems.length === 0){
        grid.innerHTML = ""; empty.innerHTML = EMPTY_WAITING; empty.style.display = "block";
        renderBulkBar([]); updateSearchCount(0, 0); return;
      }
      var vis = visibleItems();
      renderBulkBar(vis);  // fleet-action buttons reflect the visible (filtered) set
      if(vis.length === 0){
        grid.innerHTML = ""; empty.innerHTML = "No sessions match your filter.";
        empty.style.display = "block"; updateSearchCount(0, lastItems.length); return;
      }
      empty.style.display = "none";
      grid.innerHTML = vis.map(tileHtml).join("");
      paintSelection();
      updateSearchCount(vis.length, lastItems.length);
    }

    function esc(s){
      return String(s == null ? "" : s)
        .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;").replace(/'/g,"&#39;");
    }

    // Per-session risk badge (Feature E): only med/high show — low stays silent to
    // keep the panel calm. Title carries the empirical score (from ledger history).
    function riskBadge(it){
      if(it.risk !== "med" && it.risk !== "high") return "";
      var glyph = it.risk === "high" ? "⚠" : "▲";
      return '<span class="risk r-'+esc(it.risk)+'" title="Empirical risk '+(it.riskScore||0)
           + '/100 — from this session’s ledger history (deny rate, auto-deny hits, timeouts)">'+glyph+'</span>';
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
-- Inject the bulk-action targeting rules so the panel JS shares cc-core's single
-- source of truth (the bulk-bar count can't drift from what selectActionable acts on).
HTML = HTML:gsub("__BULK_RULES__", hs.json.encode(core.BULK_RULES))
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
    -- Snap the keep-awake toggle to the real state on show (F2), in case the OS
    -- flag changed while the panel was hidden.
    local caf = FX.caffeineState()
    if caf ~= nil then wv:evaluateJavaScript("setCaffeine(" .. tostring(caf) .. ")") end
  end)
  panelVisible = true
end
local function hidePanel() pcall(function() wv:hide() end); panelVisible = false end
local function togglePanel() if panelVisible then hidePanel() else showPanel() end end

-- Stable toggle entry point for the standalone Shepherd.app Dock launcher (F6).
-- The app runs `open "hammerspoon://ccShepherdToggle"`; Hammerspoon owns the
-- built-in hammerspoon:// scheme, so no custom-scheme registration and no `hs`
-- CLI dependency. Clicking the Dock icon shows/hides the panel like Chrome/VS Code.
_G.__ccShepherdToggle = togglePanel
pcall(function() hs.urlevent.bind("ccShepherdToggle", function() togglePanel() end) end)
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
  local hungOn     = core.config(cfg, "escalation.hung.enabled", false) == true
  local hungMin    = tonumber(core.config(cfg, "escalation.hung.minutes", 5)) or 5
  local apEnabled  = core.config(cfg, "policies.autopilot.enabled", false) == true
  local drainOn    = core.config(cfg, "drain.enabled", false) == true
  local autoRespawnOn  = core.config(cfg, "respawn.auto.enabled", false) == true
  local autoRespawnMax = tonumber(core.config(cfg, "respawn.auto.maxRetries", 3)) or 3
  local collEnabled = core.config(cfg, "collision.enabled", false) == true
  local collGitRoot = core.config(cfg, "collision.useGitRoot", false) == true
  local riskEnabled = core.config(cfg, "risk.enabled", false) == true
  local riskOpts = riskEnabled and {
    weights    = core.config(cfg, "risk.weights", nil),
    thresholds = core.config(cfg, "risk.thresholds", nil),
  } or nil
  -- Read the ledger ONCE per refresh for risk scoring (not per tile).
  local ledgerEvents = riskEnabled and FX.readLedger({}).events or nil
  local now = FX.now()
  local newPrev = {}  -- key -> { status, stale, escalated }: rebuilt this refresh, swapped in below

  -- Collision detection (Feature B): flag tiles where 2+ active sessions share a
  -- working dir / git-root. Computed once over the whole list before the tile loop.
  local collFlags = {}
  if collEnabled then
    local rootByCwd = nil
    if collGitRoot then
      rootByCwd = {}
      for _, it in ipairs(list) do
        if it.cwd and it.cwd ~= "" and rootByCwd[it.cwd] == nil then
          rootByCwd[it.cwd] = FX.gitRoot(it.cwd) or ""
        end
      end
    end
    collFlags = core.collisions(list, { rootByCwd = rootByCwd }).flags
  end

  for _, it in ipairs(list) do
    local pv = prev[it.key]  -- last refresh's snapshot for this tile (status/stale/escalated), or nil
    -- Live activity peek (non-stale sessions). Include `done` so the peek refreshes
    -- to the FINAL assistant line when a session finishes (a done transcript doesn't
    -- change, so the re-read is stable) instead of freezing mid-turn.
    -- The same tail feeds error detection below, so read it once for any `working`
    -- session (even stale -- a frozen-on-error session goes stale but must still flag)
    -- plus the non-stale peek statuses.
    local peekable = ACTIVITY_PEEK and not it.stale
       and (it.status == "working" or it.status == "approval" or it.status == "done")
    local wantTail = it.transcript_path and (peekable or it.status == "working")
    local tail = wantTail and FX.readTail(it.transcript_path, ACTIVITY_BYTES) or nil
    if peekable and tail then
      it.activity = core.transcriptSnippet(tail, ACTIVITY_LEN)
      -- Free context-fullness bar: the last usage line is already in this tail.
      local u = core.lastUsage(tail)
      if u then
        it.context_tokens = core.contextTokens(u)
        it.context_frac = core.contextFractionFor(cfg, u.model or it.model, it.context_tokens)
      end
    end
    -- Frozen-on-API-error detection: a `working` session whose latest transcript event
    -- is an api_error aborted WITHOUT a Stop hook -- it's stuck "working" but actually
    -- stopped. Override the status to "error" so it renders distinctly + offers Continue.
    -- Done before the watchdog/auto-respawn below (which key off "working", so they skip
    -- it), and the list is re-sorted after the loop so errors surface near approvals.
    if tail and it.status == "working" then
      local err = core.transcriptError(tail)
      if err then it.status = "error"; it.error_message = err.message end
    end

    -- Watchdog (Feature 8): track transcript progress so a stalled `working` session
    -- (no new output) can be flagged. trackProgress seeds on first sight, rebases the
    -- stall timer on any size change (growth OR a rotation/truncation shrink), and
    -- holds the timer when the size is unchanged.
    if hungOn and it.transcript_path and not it.stale and it.status == "working" then
      local sz = FX.fileSize(it.transcript_path)
      if sz then watchdog[it.key] = core.applyProgress(watchdog[it.key], sz, now) end
    end

    -- Autopilot badge (active only while the feature is enabled in config).
    it.autopilot = apEnabled and FX.autopilotActive(it.key) or false

    -- Per-session gated-tools override (Feature D): surface the current scope +
    -- resolved effective list so the detail panel can reflect/edit it.
    local ovr = FX.gateToolsOverride(it.key)
    it.gate_tools_override = ovr
    it.gate_tools_effective = core.resolveGateTools(ovr, nil, core.config(cfg, "gate.tools", nil))

    -- Collision + risk indicators (Features B/E), both off by default.
    it.collide = collEnabled and (collFlags[it.key] or false) or nil
    if riskEnabled and it.session_id and it.session_id ~= "" then
      local r = core.sessionRisk(core.filterLedger(ledgerEvents, { session = it.session_id }), riskOpts)
      it.risk = r.band
      it.riskScore = r.score
      it.riskSignals = r.signals
    end

    -- Graceful drain (Feature F): if armed, close on the SAME fresh `done` transition
    -- the queue uses. Drain WINS over auto-feed (an explicit stop beats a queued task).
    local drained = false
    if drainOn and core.shouldDrainClose(draining[it.key], pv and pv.status, it.status) then
      draining[it.key] = nil
      print("[cc-drain] " .. it.name .. " finished its turn -> closing")
      ledgerFor(it, { type = "drain_close" })
      core.handleAction(FX, it, "close")
      drained = true
    end

    -- Task queue: depth badge + auto-feed on a fresh done transition.
    local q = FX.readQueue(it.key)
    it.queue = core.queueDepth(q)
    if not drained and core.shouldFeed(pv and pv.status, it.status, q, autofeed) then
      local task, q2 = core.queuePop(q)
      if queueDry then
        print("[cc-queue] DRY-RUN would feed '" .. tostring(task) .. "' to " .. it.name)
      else
        print("[cc-queue] feeding '" .. tostring(task) .. "' to " .. it.name)
        FX.feedTask(winTarget(it), task)
        FX.writeQueue(it.key, q2)
        it.queue = core.queueDepth(q2)
        ledgerFor(it, { type = "task_feed", task = tostring(task):sub(1, 200), by = "autofeed" })
      end
    end

    -- Escalation: nag harder when an approval sits too long (once per episode). nowEsc is an
    -- accumulator, NOT a mutation of pv: pv is last refresh's read-only snapshot (and may be
    -- nil), and the loop swaps a fresh newPrev in at the end -- so writing pv.escalated would
    -- just be discarded. The carried/updated value is stored into newPrev below and becomes
    -- this tile's new escalated flag (carry-forward -> set-once-on-escalation -> reset-on-non-approval).
    local nowEsc = (pv and pv.escalated) or false
    if escEnabled and core.approvalStale(it, now, escMin * 60) then
      it.escalate = true
      if not nowEsc then
        nowEsc = true
        print("[cc-escalate] " .. it.name .. " waiting > " .. escMin .. "m")
        if escSound then FX.playSound() end
        if escPush then
          FX.push(escTopic, "Claude Shepherd: " .. it.name .. " needs you",
            (it.pending and it.pending.summary) or "Waiting for approval")
        end
      end
    end
    if it.status ~= "approval" then nowEsc = false end

    -- Stuck-session watchdog (Feature 8): flag a `working` session with no transcript
    -- progress past the threshold; nag once per stall, reusing the escalation
    -- sound/push prefs. Distinct from approvalStale (which covers waiting on you).
    local w = watchdog[it.key]
    if hungOn and core.isHung(it, w and w.ts, now, hungMin * 60) then
      it.hung = true
      if w and not w.alerted then
        w.alerted = true
        print("[cc-watchdog] " .. it.name .. " stalled (no progress > " .. hungMin .. "m)")
        if escSound then FX.playSound() end
        if escPush then FX.push(escTopic, "Claude Shepherd: " .. it.name .. " stalled",
          "No transcript progress for over " .. hungMin .. " min while working") end
      end
    end
    -- Reset watchdog state when a session isn't actively working, OR while it's
    -- stale (the growth path is skipped during stale, so a frozen timer must not
    -- survive to flag hung the instant it un-stales). Each new stint times afresh.
    if core.watchdogShouldReset(it.status, it.stale) then watchdog[it.key] = nil end

    -- Auto-respawn (opt-in): relaunch a session that died unexpectedly. cc-core owns
    -- the bookkeeping (per-folder budget: reset when healthy, increment when firing;
    -- the projectKey is folded into the gate so a keyless tile can't nil-key write).
    -- Compute respawnSpec first so cc-core can charge the budget ONLY on a real
    -- relaunch (an un-respawnable death shouldn't burn a retry). respawnSpec is pure
    -- and cheap, and only computed while the feature is on.
    local rs = autoRespawnOn and core.respawnSpec(it, cfg) or nil
    local step = core.stepAutoRespawn(respawnAttempts, it, {
      -- never auto-relaunch a session frozen on an API error: the user resumes it with
      -- Continue (same session/context), not a fresh respawn.
      enabled = autoRespawnOn and it.status ~= "error", maxRetries = autoRespawnMax,
      intentional = (draining[it.key] ~= nil) or drained,
      wasStale = (pv and pv.stale) or false,
      -- strict boolean (fail-closed): a nil/absent canRespawn must NOT read as
      -- "respawnable" via stepAutoRespawn's permissive `~= false` default.
      canRespawn = rs ~= nil and rs.canRespawn == true })
    if step.spawn then  -- rs.canRespawn was true (the increment is gated on it)
      print("[cc-respawn] auto-relaunch " .. tostring(it.name)
        .. " (attempt " .. tostring(step.attempts) .. "/" .. autoRespawnMax .. ")")
      ledgerFor(it, { type = "auto_respawn", cwd = rs.project, editor = rs.editor,
        provider = rs.providerId, attempt = step.attempts })
      FX.spawnSession(rs.editor, rs.project, nil, rs.permissionMode, rs.providerId)
      FX.removeStatus(it.key)  -- drop the dead tile; the relaunch makes a fresh one
    elseif step.wouldFire and rs and not rs.canRespawn then
      print("[cc-respawn] " .. tostring(it.name) .. " died but isn't respawnable: " .. tostring(rs.reason))
    end

    newPrev[it.key] = { status = it.status, stale = step.isStale, escalated = nowEsc }
  end
  prev = newPrev

  -- Errored tiles were detected mid-loop (status overridden to "error"); re-sort so they
  -- surface near approvals -- parseStatusList sorted before we'd read any transcript.
  core.sortByStatus(list)

  FX.writeFile(HEARTBEAT, tostring(now))
  sd.blink = not sd.blink
  sdRender(list)
  -- Overlay persistent relabels by project path (display-only; .name stays the
  -- real target). A new session in a labeled folder inherits the name (F1).
  core.applyLabelsByCwd(list, labels)
  core.applyGroups(list, groups)  -- cohort tag (.group); drives filter chips + group-scoped bulk
  local payload = (#list == 0) and "[]" or hs.json.encode(list)
  local provs = core.config(cfg, "providers", nil)  -- reuse the cfg loaded above
  local provJson = (type(provs) == "table") and hs.json.encode(provs) or "[]"
  wv:evaluateJavaScript("window.ccUpdate(" .. payload .. ", " .. provJson .. ")")

  -- Reflect the live keep-awake state in the toggle on a light cadence (every 10
  -- polls, not every 1s) so a `pmset -g` subprocess doesn't run each second. The
  -- first refresh (tick 1) syncs immediately so the button is right on load (F2).
  caffeineTick = (caffeineTick + 1) % 10
  if caffeineTick == 1 then
    local caf = FX.caffeineState()
    if caf ~= nil then
      pcall(function() wv:evaluateJavaScript("setCaffeine(" .. tostring(caf) .. ")") end)
    end
  end
end

-- Bind global hotkeys to act on whichever session needs you, no panel needed.
-- The target SELECTION is cc-core logic (tested); here we just wire the keys.
local function bindHotkeys()
  if not HOTKEYS_ENABLED then return end
  -- Shared shape for the session hotkeys: pick a target from the live list via
  -- `selector(list)`, then log + act. opts.remember updates lastJumpKey; opts.alertNone
  -- shows the "nothing waiting" toast when no target matches. (A 4th key is one line.)
  local function hotkeyAct(label, selector, action, opts)
    opts = opts or {}
    local it = selector(refreshList())
    if it then
      if opts.remember then lastJumpKey = it.key end
      print("[cc-hotkey] " .. label .. " -> " .. tostring(it.name))
      core.handleAction(FX, it, action)
    elseif opts.alertNone then
      hs.alert.show("Claude Shepherd: nothing waiting")
    end
  end
  M.hotkeys = {
    hs.hotkey.bind(HOTKEY_APPROVE_FRONT[1], HOTKEY_APPROVE_FRONT[2], function()
      hotkeyAct("approve-front", core.nextApproval, "approve", { alertNone = true })
    end),
    hs.hotkey.bind(HOTKEY_JUMP_NEEDY[1], HOTKEY_JUMP_NEEDY[2], function()
      hotkeyAct("jump-needy", function(l) return core.nextApproval(l) or core.frontSession(l) end,
        "focus", { remember = true })
    end),
    hs.hotkey.bind(HOTKEY_CYCLE[1], HOTKEY_CYCLE[2], function()
      hotkeyAct("cycle", function(l) return core.cycleNext(l, lastJumpKey) end, "focus", { remember = true })
    end),
    hs.hotkey.bind(HOTKEY_SPAWN[1], HOTKEY_SPAWN[2], function() spawnPrompt() end),
    hs.hotkey.bind(HOTKEY_TOGGLE[1], HOTKEY_TOGGLE[2], function() togglePanel() end),
  }
  print("[cc-dashboard] hotkeys bound")
end

-- Ensure the status dir exists so the watcher has something to watch.
hs.fs.mkdir(STATUS_DIR)

-- Load persistent relabels + group tags from disk now that FX is wired up.
labels = FX.loadLabels()
groups = FX.loadGroups()

-- Poll on a timer, and also react instantly to file changes.
M.timer = hs.timer.doEvery(POLL_SECONDS, refresh)
M.watcher = hs.pathwatcher.new(STATUS_DIR, function() refresh() end):start()
-- Token usage (local, zero API cost): recompute fleet/per-session/window every 60s.
M.usageTimer = hs.timer.doEvery(60, function() pcall(FX.computeUsage) end)
-- Official plan-usage window (metadata call, no model tokens): refresh every 180s.
M.officialUsageTimer = hs.timer.doEvery(OFFICIAL_TTL, function()
  pcall(FX.fetchOfficialUsage)
  -- Ledger retention GC: cheap dir scan, throttled to ~hourly (20 * 180s). Reuses
  -- this already-retained timer rather than a bare doAfter (which can be GC'd).
  ledgerGcTick = (ledgerGcTick + 1) % 20
  if ledgerGcTick == 0 then pcall(FX.expireLedger) end
end)
sdStart()  -- begin Stream Deck discovery (no-op if none plugged in)
bindHotkeys()
refresh()
after(1.0, function() pcall(FX.computeUsage) end)          -- first local pass
after(1.5, function() pcall(function() FX.fetchOfficialUsage(true) end) end)  -- first official pass
after(2.0, function() pcall(FX.expireLedger) end)          -- first retention pass

-- Launch-on-startup defaults ON the first time Shepherd runs (so it comes back after
-- a restart); the user's later choice in Settings is then respected (the real
-- "Open at Login" item is the source of truth). One-time, gated by an hs.settings flag.
if hs.settings.get("ccAutoLaunchDefaulted") == nil then
  pcall(function() hs.autoLaunch(true) end)
  hs.settings.set("ccAutoLaunchDefaulted", true)
  print("[cc-dashboard] launch-on-startup enabled by default (toggle in ⚙ Settings)")
end

-- Auto-enable kitty remote control when kitty is actually in use (user request):
-- only touch kitty.conf if a kitty session exists or kitty is the spawn editor,
-- always back up, and alert that a restart is needed. Off via spawn.kittyAutoRemote.
do
  local cfg = loadConfig()
  if core.config(cfg, "spawn.kittyAutoRemote", true) ~= false then
    local usingKitty = core.config(cfg, "spawn.editor", "terminal") == "kitty"
    if not usingKitty then
      for _, it in pairs(byKey) do if it.editor == "kitty" then usingKitty = true; break end end
    end
    if usingKitty and FX.ensureKittyRemote() == "ok" then
      hs.alert.show("Claude Shepherd: enabled kitty remote control — restart kitty to apply")
    end
  end
end

-- Keep references alive so Lua does not garbage-collect them.
_G.__ccDashboard = { webview = wv, controller = controller, module = M, core = core, fx = FX, toggle = togglePanel }
print("[cc-dashboard] loaded; watching " .. STATUS_DIR)

return M
