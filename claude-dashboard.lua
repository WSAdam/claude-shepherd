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
local TEMPLATE_FILE = os.getenv("CC_TEMPLATE_FILE") or (os.getenv("HOME") .. "/.claude/cc-templates.json")
local PRESET_FILE   = os.getenv("CC_PRESET_FILE") or (os.getenv("HOME") .. "/.claude/cc-presets.json")
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
local BULK_STAGGER  = 1.5      -- gap between bulk window-keystroke targets (> the
                               -- worst-case paste ladder, so chains never interleave)
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
local autoContinueState = { since = {}, attempts = {} }  -- key->first-error ts; projectKey->continue count
local watchdog = {}      -- key -> { size, ts, alerted }: transcript progress + stall episode
local draining    = {}   -- key -> true: close on the next fresh `done` (Feature F)
local gitRootByCwd = {}  -- cwd -> resolved git root ("" = not a repo) cache (Feature B)
local caffeineTick = 0   -- throttles the keep-awake state re-read (F2)
local ledgerGcTick = 0   -- throttles the ledger retention GC (off the 180s timer)
local lastNotifyCount = -1  -- 🔔 unseen-badge value last pushed to JS (-1 = never)
local searchTask, searchGen = nil, 0  -- fleet-search hs.task + stale-result guard
local MIRROR_DIR = os.getenv("CC_MIRROR_DIR") or ((os.getenv("HOME") or "") .. "/.claude/cc-status-mirror")
local BRIDGE_SECONDS = 2     -- per-host rsync cadence (SSH status bridge)
local bridge = {}            -- ns -> { timer, running, lastOkTs, dest, host }: live bridge state
                             -- (module-level so the timers are GC-safe, per the after() lesson)
local routePending = {}  -- tile key -> dispatch ts: a routed feed in flight (4c-E);
                         -- in-memory on purpose -- pops are delivery-gated, so a
                         -- reload losing the marker can at worst re-pick a target
local starvedSince  = {} -- queueKey -> first ts the armed project had work but no free session
local starvedAlerted = {} -- queueKey -> true once the starvation ledger event fired this episode
local loadConfig         -- forward declaration (defined near refresh)
local ledgerSnapshot     -- forward declaration (defined near refresh; bridge handlers use it)
local refresh            -- forward declaration (so the controller can repaint now)

-- Find the editor application object for a session's editor kind. The kind
-- scopes the lookup (core.editorBundleIds): a 'cursor' session must never
-- search VS Code's windows (and vice versa) -- with both running, the fixed
-- EDITOR_BUNDLES order would match the wrong app and either inject keystrokes
-- into an unrelated window or skip a perfectly matchable one. Only a nil/
-- unknown editor falls back to the legacy full walk.
local EDITOR_APP_NAMES = {
  terminal = { "Terminal" },
  cursor   = { "Cursor" },
  vscode   = { "Code", "Visual Studio Code" },
}
local function findEditorApp(editor)
  for _, bid in ipairs(core.editorBundleIds(editor, EDITOR_BUNDLES)) do
    local apps = hs.application.applicationsForBundleID(bid)
    if apps and #apps > 0 then return apps[1] end
  end
  local names = EDITOR_APP_NAMES[tostring(editor or "")]
      or { "Code", "Visual Studio Code", "Cursor" }
  for _, n in ipairs(names) do
    local app = hs.application.find(n)
    if app then return app end
  end
  return nil
end

-- Generic path components that should never be used as a focus candidate.
-- Focus the editor window for a session. Tries the session name first, then walks
-- UP the cwd path (parent folders), so a session running in a subfolder (name
-- "frontend") still finds its workspace window (titled "… — autobottom"). Returns
-- true if a specific window was focused (switches Spaces automatically). The
-- candidate-building + title matching are pure (cc-core, tested -- review #4).
-- activateOnMiss: only an explicit JUMP (FX.focusWindow / spawn follow-up) may
-- raise the app when no title matches. The keystroke guards (sendToWindow /
-- pasteIntoWindow / sendKeys) skip injection on a miss -- activating the app
-- there would yank the user's focus to the editor and abandon it (their typing
-- lands in the wrong app, and the early return never restores prev focus).
local function focusProject(name, cwd, editor, activateOnMiss)
  print("[cc-dashboard] focus request: " .. tostring(name))
  local app = findEditorApp(editor)
  if not app then
    print("[cc-dashboard] editor app not found")
    hs.alert.show("No editor window found")
    return false
  end
  local windows = app:allWindows()
  local candidates = core.focusCandidates(name, cwd, os.getenv("USER"))

  -- Pass 1: per candidate, pick the best-RANKED window (core.bestWindowFor:
  -- exact folder segment beats contains across ALL windows -- the
  -- prefix-named-sibling fix; rationale on titleFolderRank).
  local titles = {}
  for i, w in ipairs(windows) do titles[i] = w:title() or "" end
  for _, needle in ipairs(candidates) do
    local idx, rank = core.bestWindowFor(titles, needle)
    if idx then
      windows[idx]:focus()
      print("[cc-dashboard] focused (folder" .. (rank == 2 and ", exact" or "") .. ": "
        .. needle .. "): " .. (titles[idx] or "?"))
      return true
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
  if activateOnMiss then
    app:activate()
    print("[cc-dashboard] no title match for '" .. tostring(name) .. "', activated app")
  else
    print("[cc-dashboard] no title match for '" .. tostring(name) .. "' (focus left untouched)")
  end
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
function FX.removeQueue(key) os.remove(QUEUE_DIR .. "/" .. key .. ".json") end
-- Resolve a session's queue file key (project-stable via core.queueKey, so a
-- respawned or /clear'd session inherits its project's pending tasks), adopting
-- any legacy session-keyed queue file left from before queues were project-keyed:
-- its tasks are merged under the project key once and the legacy file removed.
function FX.queueKeyFor(item)
  local qk = core.queueKey(item)
  local legacy = item and item.key
  if qk and legacy and legacy ~= qk then
    local old = FX.readQueue(legacy)
    if core.queueDepth(old) > 0 then
      FX.writeQueue(qk, core.queueMerge(FX.readQueue(qk), old))
      FX.removeQueue(legacy)
      print("[cc-queue] adopted legacy session queue " .. legacy .. " -> " .. qk)
    end
  end
  return qk or legacy
end
-- Returns whether the task was actually delivered (false = the no-window-match
-- guard skipped the paste); callers must NOT pop the queue on a skip.
function FX.feedTask(target, task) return FX.typeIntoWindow(target, task) end

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
-- payload; limit <= 0 disables the cap (the export/review full-data paths).
-- Returns { events, files, truncated, ts }.
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
  local filtered, truncated = core.capLedgerSlice(core.filterLedger(events, opts), opts.limit)
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
-- untilTs, types } rewrites each file dropping matches. The match is delegated to
-- core.splitLedgerEvents (which reuses filterLedger), so purge honors the EXACT
-- filter the audit UI confirmed -- including `types` -- never a superset. Logs a
-- `purge` tombstone with the count removed (appended AFTER the rewrite so it
-- survives). Returns the count.
function FX.purgeLedger(filter)
  filter = filter or {}
  local removed = 0
  local files = {}
  for _, fn in ipairs(FX.readDir(LEDGER_DIR)) do
    if fn:match("%.jsonl$") then files[#files + 1] = fn end
  end
  for _, fn in ipairs(files) do
    local path = LEDGER_DIR .. "/" .. fn
    local before = FX.readFile(path) or ""
    local events = core.parseLedger(before)
    if filter.all then
      removed = removed + #events
      os.remove(path)
    else
      local keptEvents, purged = core.splitLedgerEvents(events, filter)
      local hits = #purged
      local kept = {}
      for _, e in ipairs(keptEvents) do kept[#kept + 1] = core.json.encode(e) end
      -- Nothing matched -> leave the file alone: a pointless rewrite of today's
      -- hot file would race a concurrent hook append (O_APPEND) and destroy it.
      if hits > 0 then
        removed = removed + hits
        local tmp = path .. ".tmp." .. tostring(FX.now())
        local f = io.open(tmp, "w")
        if f then
          f:write(#kept > 0 and (table.concat(kept, "\n") .. "\n") or "")
          -- Carry over any bytes a hook appended since our read (today's file is
          -- hot), so the rename can't silently drop a fresh audit event.
          local tail = (FX.readFile(path) or ""):sub(#before + 1)
          if tail ~= "" then f:write(tail) end
          f:close(); os.rename(tmp, path)
        end
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
  -- 2) total-size cap, oldest first (pure decision in cc-core; never selects the
  -- newest file, so the hot current day's audit trail can't be cap-deleted)
  local capMB = tonumber(core.config(cfg, "ledger.maxTotalMB", 0)) or 0
  if capMB > 0 then
    local live = {}
    for _, fn in ipairs(files) do if not expiredSet[fn] then live[#live + 1] = fn end end
    table.sort(live)  -- oldest first by name
    local sizes = {}
    for _, fn in ipairs(live) do
      local a = hs.fs.attributes(LEDGER_DIR .. "/" .. fn); sizes[fn] = (a and a.size) or 0
    end
    for _, fn in ipairs(core.ledgerCapVictims(live, sizes, capMB * 1024 * 1024)) do
      os.remove(LEDGER_DIR .. "/" .. fn); removed[#removed + 1] = fn
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

-- Saved task templates (roadmap #5c). Missing/garbled -> empty. readRecent mirrors.
function FX.readTemplates()
  local c = FX.readFile(TEMPLATE_FILE)
  if not c or #c == 0 then return { templates = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { templates = {} }
end
function FX.writeTemplates(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(TEMPLATE_FILE, core.json.encode(state or { templates = {} }))
end

-- Spawn presets (roadmap #4a). Missing/garbled -> empty.
function FX.readPresets()
  local c = FX.readFile(PRESET_FILE)
  if not c or #c == 0 then return { presets = {}, lastByProject = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { presets = {}, lastByProject = {} }
end
function FX.writePresets(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(PRESET_FILE, core.json.encode(state or { presets = {}, lastByProject = {} }))
end

-- Create a project folder (F3), with real `mkdir -p` semantics: every missing
-- component on the way down is created (hs.fs.mkdir is single-level, which made
-- "Start new project" fail whenever the typed parent didn't exist yet -- e.g.
-- a fresh ~/Programming/Dialer holding the new Dialer-scraper). Walks the
-- tested core.breadcrumbs prefixes. An existing path is success ("use existing").
function FX.mkdirP(path)
  if not path or path == "" then return false end
  if hs.fs.attributes(path) then return true end
  for _, c in ipairs(core.breadcrumbs(path)) do
    if c.path ~= "/" and not hs.fs.attributes(c.path) then
      if not hs.fs.mkdir(c.path) then return false end
    end
  end
  return hs.fs.attributes(path) ~= nil
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

-- ---- SSH status bridge (roadmap #7): rsync-pull remote cc-status ------------
-- One repeating timer per configured ssh host pulls its remote ~/.claude/
-- cc-status/ into MIRROR_DIR/<ns>/ via hs.task (async; skip-if-running so a
-- slow/dead host can't stack tasks). reconcileBridge diffs config against the
-- live timer set each refresh tick (cheap) so Settings changes apply without a
-- reload. NEEDS-HARDWARE: end-to-end verified only with a real remote box --
-- the pure pieces (argv, namespacing, merge) are unit-tested.
function FX.bridgeSync(hostSpec)
  local b = bridge[hostSpec.ns]
  if not b or b.running then return end
  b.running = true
  local dir = MIRROR_DIR .. "/" .. hostSpec.ns
  hs.fs.mkdir(MIRROR_DIR); hs.fs.mkdir(dir)
  local argv = core.rsyncArgv(hostSpec.dest, dir)
  if not argv then b.running = false; return end
  local bin = resolveBin("rsync")  -- /usr/bin/rsync ships with macOS; resolveBin finds brew's too
  local args = {}
  for i = 2, #argv do args[#args + 1] = argv[i] end
  local ok = pcall(function()
    local t = hs.task.new(bin, function(code)
      b.running = false
      if code == 0 then
        b.lastOkTs = hs.timer.secondsSinceEpoch()
        if b.failed then b.failed = false; print("[cc-bridge] " .. hostSpec.ns .. " sync recovered") end
      elseif not b.failed then
        b.failed = true  -- log once per outage, not once per 2s tick
        print("[cc-bridge] " .. hostSpec.ns .. " rsync failed (exit " .. tostring(code) .. ")")
      end
    end, args)
    if t then t:start() else error("task create failed") end
  end)
  if not ok then b.running = false end
end

local function reconcileBridge(cfg)
  local interval = tonumber(core.config(cfg, "bridge.intervalSeconds", BRIDGE_SECONDS)) or BRIDGE_SECONDS
  if interval < 1 then interval = 1 end
  local want = {}
  for _, h in ipairs(core.sshHosts(cfg)) do want[h.ns] = h end
  -- stop timers for hosts no longer configured (or bridge disabled), and for
  -- hosts whose interval changed (recreated below with the new cadence)
  for ns, b in pairs(bridge) do
    if not want[ns] or b.interval ~= interval then
      if b.timer then pcall(function() b.timer:stop() end) end
      bridge[ns] = nil
      if not want[ns] then print("[cc-bridge] " .. ns .. " stopped") end
    end
  end
  -- start timers for newly configured hosts
  for ns, h in pairs(want) do
    if not bridge[ns] then
      bridge[ns] = { dest = h.dest, host = h.host, running = false, lastOkTs = 0, interval = interval }
      bridge[ns].timer = hs.timer.doEvery(interval, function() FX.bridgeSync(h) end)
      print("[cc-bridge] " .. ns .. " syncing " .. h.dest .. " every " .. interval .. "s")
      FX.bridgeSync(h)  -- first pull now, not in <interval>s
    end
  end
end

-- ---- Fuzzy folder search index (roadmap #4b) --------------------------------
-- Scanned ONCE per modal open (async hs.task, 60s TTL cache); per-keystroke
-- ranking happens in pure core.fuzzyFilter against this cache -- never a
-- process per keystroke. fd when present (gitignore-aware), find fallback.
local folderIndex = { paths = {}, ts = 0 }
local folderScanTask = nil
function FX.scanFolders()
  local now = hs.timer.secondsSinceEpoch()
  if folderScanTask or (now - (folderIndex.ts or 0)) < 60 then return end  -- fresh or in flight
  local cfg = loadConfig()
  local roots = core.config(cfg, "spawn.searchRoots", nil)
  if type(roots) ~= "table" or #roots == 0 then roots = { ORCH_DEFAULT_DIR } end
  local expanded = {}
  for _, r in ipairs(roots) do
    local raw = tostring(r or "")
    if raw:sub(1, 1) == "~" then raw = (os.getenv("HOME") or "") .. raw:sub(2) end
    if raw ~= "" and hs.fs.attributes(raw) then expanded[#expanded + 1] = raw end
  end
  if #expanded == 0 then return end
  local depth = tonumber(core.config(cfg, "spawn.searchDepth", 4)) or 4
  -- detect -> use -> degrade gracefully: resolveBin returns the bare name on a
  -- total miss and hs.task needs a real path, so verify with hs.fs.attributes.
  local fd = resolveBin("fd", core.config(cfg, "spawn.fdBin", nil))
  local argv
  if hs.fs.attributes(fd) then argv = core.folderScanArgv(fd, expanded, depth)
  else argv = core.folderScanFallbackArgv(expanded, depth) end
  local args = {}
  for i = 2, #argv do args[#args + 1] = argv[i] end
  local ok = pcall(function()
    folderScanTask = hs.task.new(argv[1], function(_, stdout)
      folderScanTask = nil
      folderIndex = { paths = core.parseDirList(stdout), ts = hs.timer.secondsSinceEpoch() }
      print("[cc-spawn] folder index: " .. #folderIndex.paths .. " dir(s)")
    end, args)
    if folderScanTask then folderScanTask:start() else error("task create failed") end
  end)
  if not ok then folderScanTask = nil end
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

-- Forward-declared; defined next to the injection tail below. FX.runImprove's
-- async HTTP callback dispatches a paste chain, and every window-keystroke
-- dispatch must reserve a slot on the SHARED injection tail (R3 #2/#5).
local dispatchSerialized

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
      -- pasteIntoWindow reports delivery (false = no positive window match); the
      -- cards are already claimed server-side, so a skipped paste must not be
      -- announced as "sent" -- surface it so the user can re-run from the window.
      -- Serialized: the paste is a multi-second keystroke ladder (R3 #2/#5).
      dispatchSerialized(item, "improve", function()
        if FX.pasteIntoWindow(target, { text = core.improvePrompt(cards) }) then
          hs.alert.show("Improve: pulled " .. #cards .. " insight(s) → review prompt sent to " .. tostring(item.name))
        else
          hs.alert.show("Improve: no window match for " .. tostring(item.name) .. " — prompt NOT sent (cards claimed)")
        end
      end)
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

-- Merge fields into a session's status file (optimistic local patch -- e.g. the
-- new permission_mode after set-mode, which fires no hook). temp+mv is atomic so
-- the shell side never reads a half-written file; the next hook write wins.
function FX.patchStatus(key, fields)
  local path = STATUS_DIR .. "/" .. key .. ".json"
  local text = core.patchedStatus(FX.readFile(path) or "", fields)
  if not text then return false end
  local tmp = path .. ".tmp." .. tostring(FX.now())
  local f = io.open(tmp, "w"); if not f then return false end
  f:write(text); f:close()
  if not os.rename(tmp, path) then os.remove(tmp); return false end
  return true
end

-- temp+mv is atomic, so cc-approve's exists-then-read poll can never observe the
-- decision file created but still empty (io.open("w") creates it BEFORE the
-- content lands at close) -- an empty read would fall through to the native
-- prompt and discard the user's click. Same idiom as FX.patchStatus / cc_merge.
-- The pending request's nonce (cc-approve.sh publishes it in the status JSON's
-- pending block) is echoed into the content ("allow <nonce>") so the gate
-- consumes this answer ONLY for the request it was clicked for: a leftover from
-- a double-click can no longer answer the NEXT gated call (mtime alone has
-- 1-second granularity and can't bind answers to requests). Read from disk, not
-- the panel snapshot -- the file is fresher than the last refresh. No nonce
-- (older hook still deployed) -> legacy bare verb, which the gate accepts only
-- on a strictly-newer mtime.
-- A namespaced key (host:key, SSH bridge) routes the decision to the REMOTE
-- box instead: nonce read from the mirror copy (≤ a few seconds old; a stale
-- nonce is ignored by the remote gate, worst case a no-op), write executed as
-- a temp+mv over ssh (core.decisionSshArgv -- validated argv, BatchMode).
function FX.writeDecision(key, value)
  local ns, rawKey = core.splitNamespacedKey(key)
  if ns then
    local b = bridge[ns]
    if not b or not b.dest then
      print("[cc-bridge] decision dropped: no live bridge for host " .. tostring(ns))
      return
    end
    local statusText = FX.readFile(MIRROR_DIR .. "/" .. ns .. "/" .. rawKey .. ".json")
    local content = core.decisionContent(value, statusText)
    local argv = core.decisionSshArgv(b.dest, rawKey, content)
    if not argv then
      print("[cc-bridge] decision dropped: unsafe key/content for " .. tostring(key))
      return
    end
    local args = {}
    for i = 2, #argv do args[#args + 1] = argv[i] end
    pcall(function()
      local t = hs.task.new("/usr/bin/ssh", nil, args)
      if t then t:start() end
    end)
    print("[cc-bridge] remote decision " .. tostring(content) .. " -> " .. tostring(key))
    return
  end
  local path = STATUS_DIR .. "/" .. key .. ".decision"
  local content = core.decisionContent(value, FX.readFile(STATUS_DIR .. "/" .. key .. ".json"))
  local tmp = path .. ".tmp." .. tostring(FX.now())
  local f = io.open(tmp, "w")
  if f then f:write(content); f:close(); os.rename(tmp, path) end
  print("[cc-dashboard] decision " .. tostring(content) .. " -> " .. tostring(key))
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
  -- Jump is an explicit "take me there": raising the app on a title miss is
  -- still useful. The keystroke paths pass false (a miss must disturb nothing).
  return focusProject(target.name, target.cwd, target.editor, true)
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

-- Beat-list scheduling lives in core.runSequence (pure, scheduler-injected,
-- unit-tested); production passes the GC-safe `after` above. It returns the
-- timer handles so a superseded ladder can be cancelled (spawnEditorWindow).

-- Absolute deadline (epoch s) of the LAST scheduled window-keystroke injection
-- chain. Module-level so the BULK_STAGGER serialization holds across bridge
-- messages, not just within one: a second bulk click -- or a single window
-- action arriving during the stagger window -- reserves the next slot via
-- core.staggerSlot and queues AFTER the in-flight chains instead of
-- interleaving with them (which lands keys in the wrong session).
local injectionTailAt = 0

-- THE chokepoint for dispatching session actions (R3 #2/#5: every window-
-- keystroke launcher must serialize, not just the bulk loop + per-tile tail).
-- Headless dispatches (kitty @ remote / armed-gate decision-file writes) fire
-- NOW; everything else focuses a window and injects keystrokes on after()
-- timers, so it reserves the next slot on the shared injection tail -- chains
-- launched from ANY site (bulk, per-tile, ctx-menu, refresh()'s drain close /
-- queue auto-feed, Stream Deck, hotkeys, Improve, audit review) queue behind
-- the in-flight ones instead of interleaving (keys land in the wrong session).
-- (Assigned to the local forward-declared above FX.runImprove, whose async
-- callback needs it before this line runs.)
function dispatchSerialized(item, action, fn)
  if core.actionIsHeadless(item, action) then fn() return end
  local delay
  delay, injectionTailAt = core.staggerSlot(injectionTailAt, hs.timer.secondsSinceEpoch(), BULK_STAGGER)
  if delay > 0 then after(delay, fn) else fn() end
end

-- Focus a window, then send after a short delay, then restore prior focus.
-- Takes the full target so focusProject gets the cwd (its subfolder-session
-- ancestor matching) and the editor kind. If the window can't be POSITIVELY
-- identified, the keys are SKIPPED: typing into whatever happens to be
-- frontmost answers/closes a different session.
local function sendToWindow(target, sendFn)
  local prev = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  if not focusProject(target.name, target.cwd, target.editor) then
    print("[cc-dashboard] no window match for '" .. tostring(target.name) .. "' -- keys NOT sent")
    return
  end
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
  sendToWindow(target, function() hs.eventtap.keyStroke(keySpec.mods, keySpec.key) end)
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
  if not focusProject(name, target.cwd, target.editor) then
    print("[cc-dashboard] no window match for '" .. tostring(name) .. "' -- paste NOT sent")
    return false  -- callers must be able to tell a skip from a delivery (queue pop gates on it)
  end
  -- The ⌘1/⌘Esc chat-focus dance is VS Code-only; in a terminal typing goes
  -- straight to the prompt and those chords would be wrong (see FOCUS_CHAT_KEY).
  local chatKeys = target.editor ~= "terminal"
  after(FOCUS_DELAY, function()
    -- Focus the editor group first so the ⌘Esc chat-input toggle is deterministic
    -- (always unfocused -> focused, never the reverse). Then focus the chat input.
    if chatKeys and FOCUS_EDITOR_KEY then hs.eventtap.keyStroke(FOCUS_EDITOR_KEY[1], FOCUS_EDITOR_KEY[2]) end
    after((chatKeys and FOCUS_EDITOR_KEY) and 0.06 or 0, function()
      if chatKeys and FOCUS_CHAT_KEY then hs.eventtap.keyStroke(FOCUS_CHAT_KEY[1], FOCUS_CHAT_KEY[2]) end
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
  return true  -- window positively matched; the injection sequence is scheduled
end

-- Best-effort close the editor window for a session: focus it, then send the
-- VS Code/Cursor "Close Window" chord (⌘⇧W). Unreliable if the title can't be
-- matched (focusProject falls back to just activating the app), so the caller
-- also drops the dashboard tile regardless.
function FX.closeWindow(target)
  if isKitty(target) then return runKitty(core.kittyCmd("close", kittyItem(target))) end
  print("[cc-dashboard] close window -> " .. tostring(target.name))
  sendToWindow(target, function() hs.eventtap.keyStroke({ "cmd", "shift" }, "w") end)
end

-- Drive a sequence of keystrokes into a session (e.g. arrow-down ×N + Return to
-- pick an AskUserQuestion option). Focus first, send each key with a small gap,
-- restore prior focus only AFTER the last key (same race-safe pattern as paste).
-- Returns false when nothing was dispatched (no window match / dead kitty
-- target), true when the chain was scheduled: set-mode only re-bases the stored
-- permission_mode on a REAL dispatch, so a skip can't make the panel lie.
function FX.sendKeys(target, keys)
  keys = keys or {}
  -- kitty: ONE headless send-key carrying every token (answer + set-mode). One
  -- process per key would race to the control socket -- the OS can deliver them
  -- out of order, so down/.../return could confirm the WRONG picker option.
  if isKitty(target) then
    local tokens = {}
    for _, k in ipairs(keys) do tokens[#tokens + 1] = core.kittyKeyToken(k) end
    return runKitty(core.kittyCmd("key", kittyItem(target), { tokens = tokens }))
  end
  local name = target.name
  print("[cc-dashboard] send keys -> " .. tostring(name) .. " (" .. #keys .. " keys)")
  local prevWin = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  if not focusProject(name, target.cwd, target.editor) then
    print("[cc-dashboard] no window match for '" .. tostring(name) .. "' -- keys NOT sent")
    return false
  end
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
  return true  -- window positively matched; the key chain is scheduled
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
local spawnSeqHandles = nil  -- the in-flight spawn ladder's timers (module-level: GC-safe)
local function spawnEditorWindow(spec)
  print("[cc-orch] " .. spec.editor .. " spawn: open " .. spec.app .. " at " .. tostring(spec.project))
  -- Supersede any previous spawn's still-pending beats: two overlapping ladders
  -- would interleave their keystrokes into whichever window is focused when
  -- each beat's wall-clock arrives.
  if spawnSeqHandles then
    local stopped = 0
    for _, h in ipairs(spawnSeqHandles) do
      if h and h.stop then pcall(function() h:stop() end); stopped = stopped + 1 end
    end
    if stopped > 0 then print("[cc-orch] superseding previous spawn ladder (" .. stopped .. " pending beat(s) cancelled)") end
    spawnSeqHandles = nil
  end
  local t = hs.task.new("/usr/bin/open", nil, { "-na", spec.app, "--args", spec.project })
  if t then t:start() end
  hs.alert.show("Claude Shepherd: opening " .. spec.app .. " — starting claude (best-effort)")
  local proj = spec.project
  local name = proj and proj:match("([^/]+)/?$") or nil
  -- Cold-start timing: a NEW window (the new-project case) takes seconds to be
  -- input-ready. Beats run via core.runSequence (see its header for the
  -- column/pcall semantics); handles are captured into spawnSeqHandles so the
  -- next spawn can cancel a superseded ladder (the block above).
  if spec.flavor == "extension" then
    -- DEFAULT: open the Claude Code EXTENSION (the panel the operator works
    -- in -- resume the recent session / new-session UI) via its quick-launch
    -- shortcut ⌘Esc. An optional initial task is typed into the Claude input
    -- the shortcut focuses.
    local beats = {
      { delay = 3.0, fn = function()
          -- The just-opened window may not be titled yet: activating the app on
          -- a title miss IS the desired behavior (the keystrokes must land in it).
          focusProject(name, proj, nil, true)
        end },
      { delay = 1.0, fn = function()
          print("[cc-orch] vscode: opening the Claude Code extension (⌘Esc)")
          hs.eventtap.keyStroke({ "cmd" }, "escape")
        end },
    }
    if spec.task and #spec.task > 0 then
      beats[#beats + 1] = { delay = 2.0, fn = function()
        print("[cc-orch] vscode: typing initial task into the Claude input")
        hs.eventtap.keyStrokes(spec.task)
      end }
      beats[#beats + 1] = { delay = 0.3, fn = function()
        hs.eventtap.keyStroke({}, "return")
        print("[cc-orch] vscode: initial task submitted")
      end }
    end
    spawnSeqHandles = core.runSequence(beats, after)
    return
  end
  -- flavor "terminal" (spawn.vscodeFlavor = "terminal", and every ssh spawn):
  -- a new integrated terminal + the typed claude launch line. The palette is
  -- more reliable than ⌃` (which would hide an already-open terminal), and the
  -- shell needs ~2s before it accepts input (field-verified cold-start miss).
  spawnSeqHandles = core.runSequence({
    { delay = 3.0, fn = function()
        focusProject(name, proj, nil, true)
      end },
    { delay = 0.8, fn = function()
        print("[cc-orch] vscode: opening command palette")
        hs.eventtap.keyStroke({ "cmd", "shift" }, "p")
      end },
    { delay = 0.6, fn = function() hs.eventtap.keyStrokes("Terminal: Create New Terminal") end },
    { delay = 0.4, fn = function()
        print("[cc-orch] vscode: creating integrated terminal")
        hs.eventtap.keyStroke({}, "return")
      end },
    { delay = 2.0, fn = function()
        print("[cc-orch] vscode: typing claude launch line: " .. tostring(spec.postType))
        hs.eventtap.keyStrokes(spec.postType)
      end },
    { delay = 0.3, fn = function()
        hs.eventtap.keyStroke({}, "return")
        print("[cc-orch] vscode: launch line submitted")
      end },
  }, after)
end

-- Dry-run spec description lives in core.describeSpec (pure, tested).
local function describeSpec(spec) return core.describeSpec(spec) end

-- Resolve `claude` to an absolute path for spawns. Bare `claude` breaks where
-- the spawned context's PATH/aliases don't carry it -- proven in the VS Code
-- integrated terminal (`zsh: command not found: claude`; the usual install is
-- an ~/.zshrc alias to ~/.claude/local/claude, invisible to that typed line).
-- Order: spawn.claudeBin (hand-edit override, survives Settings saves) ->
-- resolveBin (login-shell `command -v` resolves the alias value + homebrew
-- dirs) -> the known install homes. nil = unresolved; spawnSpec then keeps the
-- legacy bare word (which still works for Terminal's login shell).
local function claudeBinPath()
  local bin = resolveBin("claude", core.config(loadConfig(), "spawn.claudeBin", nil))
  if bin and bin ~= "claude" and hs.fs.attributes(bin) then return bin end
  local home = os.getenv("HOME") or ""
  for _, p in ipairs({ home .. "/.claude/local/claude", home .. "/.local/bin/claude" }) do
    if hs.fs.attributes(p) then return p end
  end
  -- No CLI installed at all: fall back to the binary the VS Code / Cursor
  -- extension bundles (it IS the full CLI). The dir is version-pinned, so pick
  -- the newest numerically (pure + tested).
  for _, extRoot in ipairs({ home .. "/.vscode/extensions", home .. "/.cursor/extensions" }) do
    local newest = core.newestClaudeExtension(FX.readDir(extRoot))
    if newest then
      local p = extRoot .. "/" .. newest .. "/resources/native-binary/claude"
      if hs.fs.attributes(p) then return p end
    end
  end
  return nil
end

-- Spawn a new Claude session, editor-aware (F3-F5). The editor comes from the
-- caller (the modal's picker) or falls back to `spawn.editor` in config. Effective
-- dry-run = the code default ORCH_DRY_RUN unless the user flips `spawn.live` on.
function FX.spawnSession(editor, project, task, permissionMode, providerId)
  local cfg = loadConfig()
  editor = (editor and editor ~= "") and editor or core.config(cfg, "spawn.editor", "terminal")
  -- Resolve the provider profile. "" is an EXPLICIT "(none — bare claude)" pick;
  -- only nil (no pick at all) falls back to the spawn.provider default (pure
  -- resolution in cc-core). A missing/unknown profile leaves env/model nil ->
  -- bare `claude`, unchanged.
  local profile = core.providerById(cfg, core.spawnProviderKey(cfg, providerId))
  local opts = {
    terminal       = ORCH_TERMINAL,
    kittyBin       = resolveBin("kitty", core.config(cfg, "spawn.kittyBin", nil)),
    kittyRemote    = core.config(cfg, "spawn.kittyRemote", true) ~= false,
    kittySocket    = core.config(cfg, "spawn.kittySocket", nil),
    permissionMode = (permissionMode and permissionMode ~= "") and permissionMode or nil,
    env            = profile and core.providerEnv(profile) or nil,  -- carries ANTHROPIC_MODEL
    ssh            = profile and type(profile.ssh) == "table" and profile.ssh or nil,
    claudeBin      = claudeBinPath(),  -- absolute path; nil keeps the bare word
    vscodeFlavor   = core.config(cfg, "spawn.vscodeFlavor", "extension"),  -- extension | terminal
  }
  -- Auto-enable Remote Control via the --remote-control launch flag, but only for a LOCAL,
  -- native-Anthropic session: RC needs claude.ai auth and rejects third-party/gateway
  -- providers, and an ssh-remote box would register RC to its own window. Off via
  -- remoteControl.onSpawn. (spawnSpec also drops the flag for ssh as a belt-and-suspenders.)
  local isGateway = profile and tostring(profile.kind or "anthropic") == "gateway"
  local isSshProfile = profile and type(profile.ssh) == "table" and profile.ssh.host
  opts.remoteControl = core.config(cfg, "remoteControl.onSpawn", true) == true
    and not isGateway and not isSshProfile
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
      -- expose (risk / collision / drain / respawn / insights) survive a Save --
      -- including the UI-unmanaged subkeys inside rebuilt blocks (spawn.kittyBin/
      -- kittySocket, escalation.hung), carried forward by core.overlayConfig.
      local cfg = core.overlayConfig(loadConfig(), incoming)
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
    -- cwds) + the initial folder listing + saved presets / per-project last-used
    -- options. loadConfig() decodes-or-{}, and we re-encode via hs.json so a
    -- malformed file can't break the spliced JS. Also warm the fuzzy-search
    -- folder index (async; the dropdown just stays empty until it lands).
    local cfg = loadConfig()
    local active = {}
    for _, it in pairs(byKey) do if it.cwd then active[#active + 1] = it.cwd end end
    local recent = core.recentSeed(FX.readRecent(), active)
    local browse = FX.listDirs(ORCH_DEFAULT_DIR)
    local pstate = FX.readPresets()
    FX.scanFolders()
    pcall(function()
      wv:evaluateJavaScript("showNew(" .. hs.json.encode(cfg) .. ", "
        .. hs.json.encode(recent.dirs) .. ", " .. hs.json.encode(browse) .. ", "
        .. hs.json.encode({ presets = core.presetList(pstate),
                            lastByProject = pstate.lastByProject or {} }) .. ")")
    end)
    return
  end
  if a == "list-dir" then
    local path = (payload.v and tostring(payload.v) ~= "") and tostring(payload.v) or ORCH_DEFAULT_DIR
    local browse = FX.listDirs(path)
    pcall(function() wv:evaluateJavaScript("ccBrowse(" .. hs.json.encode(browse) .. ")") end)
    return
  end
  -- Spawn presets (roadmap #4a): save / delete; both reply with the fresh list.
  if a == "preset-save" or a == "preset-delete" then
    if a == "preset-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local st, saved = core.presetPush(FX.readPresets(), (okp and type(p) == "table") and p or {})
      if saved then FX.writePresets(st)
      else pcall(function() hs.alert.show("Claude Shepherd: preset needs a name and an absolute folder") end) end
    else
      FX.writePresets(core.presetRemove(FX.readPresets(), tostring(payload.v or "")))
    end
    local list = core.presetList(FX.readPresets())
    local listJson = (#list > 0) and hs.json.encode(list) or "[]"
    pcall(function() wv:evaluateJavaScript("ccPresets(" .. listJson .. ")") end)
    return
  end
  -- Fuzzy folder search (roadmap #4b): rank the CACHED index (no per-keystroke
  -- process; the scan ran once on modal open).
  if a == "folder-search" then
    local hits = core.fuzzyFilter(tostring(payload.v or ""), folderIndex.paths or {}, 12)
    local hitsJson = (#hits > 0) and hs.json.encode(hits) or "[]"
    pcall(function() wv:evaluateJavaScript("ccSearchResults(" .. hitsJson .. ")") end)
    return
  end
  if a == "spawn" then
    -- From the in-panel modal (carries mode + dir/parent+name + editor); with no
    -- usable dir we fall back to the native two-prompt flow (also the ⌘⌥S path).
    -- A typed "~/..." path is expanded here (the browser/listDirs already does);
    -- newProjectPath would otherwise reject it as relative.
    local function expandHome(p)
      p = tostring(p or "")
      if p:sub(1, 1) == "~" then return (os.getenv("HOME") or "") .. p:sub(2) end
      return p
    end
    local mode   = tostring(payload.mode or "")
    local editor = payload.editor and tostring(payload.editor) or nil
    local task   = payload.text and tostring(payload.text) or nil
    local dir
    if mode == "new" then
      local parentDir = expandHome(payload.parent)
      local projName = tostring(payload.name or "")
      local why
      dir, why = core.newProjectPath(parentDir, projName)
      if not dir then
        -- The rejection reason comes from the validator itself (single source
        -- of truth) -- a bare "invalid" popup was field-proven undiagnosable,
        -- and re-deriving the reason here could mislabel future checks.
        why = why or "invalid project name or parent folder"
        print("[cc-orch] new-project rejected: " .. why)
        pcall(function() hs.alert.show("Claude Shepherd: " .. why) end)
        return
      end
      if not FX.mkdirP(dir) then
        print("[cc-orch] new-project mkdir failed: " .. dir)
        pcall(function() hs.alert.show("Claude Shepherd: couldn't create " .. dir) end)
        return
      end
      print("[cc-orch] new project folder ready: " .. dir)
    elseif mode == "existing" then
      dir = payload.dir and expandHome(payload.dir) or ""
    end
    if not dir or dir == "" then
      spawnPrompt()  -- no dir from the modal -> native fallback
      return
    end
    FX.writeRecent(core.recentPush(FX.readRecent(), dir))
    -- Per-project last-used recall (roadmap #4a): every modal spawn records its
    -- options so re-opening the modal on this folder pre-fills them.
    FX.writePresets(core.presetMarkUsed(FX.readPresets(), dir, {
      editor = editor, permMode = payload.permMode and tostring(payload.permMode) or nil,
      provider = payload.provider and tostring(payload.provider) or nil }))
    FX.spawnSession(editor, dir, task, payload.permMode and tostring(payload.permMode) or nil,
      payload.provider and tostring(payload.provider) or nil)
    return
  end
  if a == "queue-add" then
    local key = tostring(payload.v or "")
    local task = payload.text and tostring(payload.text) or ""
    if key ~= "" and task ~= "" then
      -- queues are PROJECT-keyed (survive respawn//clear); unknown tile -> raw key
      local qk = byKey[key] and FX.queueKeyFor(byKey[key]) or key
      FX.writeQueue(qk, core.queuePush(FX.readQueue(qk), task))
      print("[cc-queue] queued for " .. qk .. ": " .. task)
    end
    return
  end
  if a == "queue-feed" then
    local key = tostring(payload.v or "")
    local item = byKey[key]
    if item and item.remote then
      pcall(function() hs.alert.show("Claude Shepherd: can't feed a remote session (no local window)") end)
      return
    end
    if item then
      -- Serialized on the shared injection tail (R3 #2/#5): the paste ladder
      -- must queue behind in-flight chains. The pop runs INSIDE the slot -- the
      -- queue is re-read at dispatch time (an earlier slot may have consumed
      -- the head) and the pop decision still gates on feedTask's synchronous
      -- delivery result: only a DELIVERED paste pops the queue (persisting q2
      -- after a skipped paste would silently destroy the task).
      dispatchSerialized(item, a, function()
        local qk = FX.queueKeyFor(item)
        local task, q2 = core.queuePop(FX.readQueue(qk))
        if task then
          local commit = core.queueFeedCommit(FX.feedTask(winTarget(item), task))
          if commit.persist then FX.writeQueue(qk, q2)
          else print("[cc-queue] feed skipped (no window match) -- task kept queued") end
          ledgerFor(item, { type = commit.event, task = tostring(task):sub(1, 200), by = "manual" })
        end
      end)
    end
    return
  end
  -- Queue editing (roadmap #5): list / reorder / remove / bulk-add. Every
  -- mutation re-reads the file INSIDE the handler (the autofeed loop pops heads
  -- asynchronously, so the JS snapshot may be stale), passes the clicked task
  -- text as the `expect` guard, and always replies with the fresh list so the
  -- panel self-heals after a refused edit.
  if a == "queue-list" or a == "queue-move" or a == "queue-remove" or a == "queue-add-bulk" then
    local key = tostring(payload.v or "")
    local item = byKey[key]
    local qk = item and FX.queueKeyFor(item) or ((key ~= "") and key or nil)
    if not qk then return end
    if a == "queue-move" or a == "queue-remove" then
      local okr, req = pcall(hs.json.decode, payload.text or "{}")
      req = (okr and type(req) == "table") and req or {}
      local q = FX.readQueue(qk)
      if a == "queue-move" then
        local q2, moved = core.queueMove(q, req.idx, req.dir, req.task)
        if moved then
          FX.writeQueue(qk, q2)
          if item then ledgerFor(item, { type = "queue_edit", op = "move" }) end
        end
      else
        local q2, removed = core.queueRemoveAt(q, req.idx, req.task)
        if removed then
          FX.writeQueue(qk, q2)
          if item then ledgerFor(item, { type = "queue_edit", op = "remove",
            task = tostring(removed):sub(1, 200) }) end
        end
      end
    elseif a == "queue-add-bulk" then
      local tasks = core.queueSplitLines(payload.text)
      if #tasks > 0 then
        FX.writeQueue(qk, core.queuePushAll(FX.readQueue(qk), tasks))
        print("[cc-queue] bulk-queued " .. #tasks .. " task(s) for " .. qk)
        if item then ledgerFor(item, { type = "queue_edit", op = "bulk_add", count = #tasks }) end
      end
    end
    local tasks = FX.readQueue(qk).tasks or {}
    local listJson = (#tasks > 0) and hs.json.encode(tasks) or "[]"
    pcall(function() wv:evaluateJavaScript("ccQueueList(" .. jsString(key) .. ", " .. listJson .. ")") end)
    return
  end
  -- 4c-E: arm/disarm project routing for this project's queue. The flag lives
  -- in the queue file (routing:true) so it inherits projectKey keying; every
  -- session of the project shows the same toggle (intended -- it's per-project).
  if a == "queue-route" then
    local key = tostring(payload.v or "")
    local item = byKey[key]
    if not item then return end
    local qk = FX.queueKeyFor(item)
    local on = tostring(payload.text or "") == "on"
    FX.writeQueue(qk, core.queueSetRouted(FX.readQueue(qk), on))
    print("[cc-route] " .. qk .. " routing " .. (on and "ARMED" or "off"))
    ledgerFor(item, { type = "route_arm", on = on })
    return
  end
  -- Saved task templates (roadmap #5c): named reusable task strings in
  -- cc-templates.json (operator data, outside the Settings round-trip).
  if a == "template-list" or a == "template-save" or a == "template-delete" then
    if a == "template-save" then
      local st, saved = core.templatePush(FX.readTemplates(), payload.v, payload.text)
      if saved then FX.writeTemplates(st)
      else pcall(function() hs.alert.show("Claude Shepherd: template needs a name and text") end) end
    elseif a == "template-delete" then
      FX.writeTemplates(core.templateRemove(FX.readTemplates(), tostring(payload.v or "")))
    end
    local list = core.templateList(FX.readTemplates())
    local listJson = (#list > 0) and hs.json.encode(list) or "[]"
    pcall(function() wv:evaluateJavaScript("ccTemplates(" .. listJson .. ")") end)
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
          -- Serialized: /clear into the wrong session (an in-flight chain's
          -- focus) wipes a context that wasn't confirmed (R3 #2/#5).
          dispatchSerialized(item, a, function() FX.typeIntoWindow(winTarget(item), s.cmd) end)
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
  -- Fleet-wide transcript/ledger search (roadmap #3): rg when installed, grep
  -- fallback. Async hs.task with a generation guard + terminate-on-new-query so
  -- out-of-order results can never paint over a newer search. Output stays tiny
  -- by construction (core.searchArgv emits -o context-wrapped matches only).
  if a == "fleet-search" then
    local okq, req = pcall(hs.json.decode, payload.text or "{}")
    local q = (okq and type(req) == "table") and tostring(req.q or "") or ""
    searchGen = searchGen + 1
    local gen = searchGen
    if searchTask then pcall(function() searchTask:terminate() end); searchTask = nil end
    local cfg = loadConfig()
    local rg = resolveBin("rg", core.config(cfg, "search.rgBin", nil))
    local kind = hs.fs.attributes(rg) and "rg" or "grep"
    local bin = (kind == "rg") and rg or "/usr/bin/grep"
    local paths = { (os.getenv("HOME") or "") .. "/.claude/projects" }
    if hs.fs.attributes(LEDGER_DIR) then paths[#paths + 1] = LEDGER_DIR end
    local args = core.searchArgv(kind, q, paths)
    if not args then return end  -- too-short query: JS already cleared the view
    local maxResults = tonumber(core.config(cfg, "search.maxResults", 200)) or 200
    local ok = pcall(function()
      searchTask = hs.task.new(bin, function(_, out)
        searchTask = nil
        if gen ~= searchGen then return end  -- superseded by a newer query
        local res = core.parseSearchResults(out or "", { limit = maxResults })
        local items = {}
        for _, it in pairs(byKey) do items[#items + 1] = it end
        res.hits = core.annotateSearchHits(res.hits, items, LEDGER_DIR)
        res.q = q
        pcall(function() wv:evaluateJavaScript("window.ccSearch(" .. hs.json.encode(res) .. ")") end)
      end, args)
      if searchTask then searchTask:start() else error("task create failed") end
    end)
    if not ok then searchTask = nil end
    return
  end
  -- Open the audit overlay pre-scoped to a session found via fleet search (the
  -- hit may be a DEAD session -- no byKey entry -- so this takes a session_id
  -- directly, unlike open-session-timeline).
  if a == "open-audit-for-session" then
    local sid = tostring(payload.v or "")
    if sid == "" then return end
    local res = FX.readLedger({})
    local events = core.sessionTimeline(res.events, sid, { limit = 1000 })
    pcall(function() wv:evaluateJavaScript("window.ccAudit("
      .. hs.json.encode({ events = events, files = res.files, truncated = res.truncated })
      .. ", " .. jsString(sid) .. ", " .. jsString("timeline") .. ")") end)
    return
  end
  if a == "open-notifications" then
    -- 🔔 history: the audit overlay's Alerts tab, scoped to the notification
    -- window, with the PREVIOUS last-seen as the unseen divider. Opening marks
    -- everything seen (hs.settings survives reloads, like ccDashboardTheme).
    local lastSeen = tonumber(hs.settings.get("ccNotifySeen")) or 0
    local days = tonumber(core.config(loadConfig(), "notifications.days", 7)) or 7
    local notifs = core.notificationEvents(ledgerSnapshot(), { sinceTs = FX.now() - days * 86400 })
    hs.settings.set("ccNotifySeen", FX.now())
    lastNotifyCount = 0  -- badge cleared; recomputed against the fresh mark next change
    pcall(function() wv:evaluateJavaScript("window.ccAudit("
      .. hs.json.encode({ events = notifs, files = {}, truncated = false })
      .. ", null, " .. jsString("alerts") .. ", " .. tostring(lastSeen) .. ")") end)
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
  if a == "decision-log" then
    -- Detail-panel gate decision log: last N grouped decisions for the selected
    -- session, read from the CACHED ledger snapshot (selection-triggered, never
    -- on the 1s tick). Replies null when there's nothing to show -- the JS hides
    -- the section (and an empty Lua table would json-encode as {} not []).
    local key = tostring(payload.v or "")
    local it = byKey[key]
    local sid = it and it.session_id
    if not ledgerEnabled() or not sid or tostring(sid) == "" then
      pcall(function() wv:evaluateJavaScript("window.ccDecisions(" .. jsString(key) .. ", null)") end)
      return
    end
    local cfg = loadConfig()
    local hours = tonumber(core.config(cfg, "decisions.hours", 48)) or 48
    local rows = core.gateDecisionSummary(ledgerSnapshot(), sid, {
      limit = tonumber(core.config(cfg, "decisions.limit", 5)) or 5,
      sinceTs = FX.now() - hours * 3600,
    })
    local payloadJson = (#rows > 0) and hs.json.encode(rows) or "null"
    pcall(function() wv:evaluateJavaScript("window.ccDecisions(" .. jsString(key) .. ", " .. payloadJson .. ")") end)
    return
  end
  if a == "audit-export" then
    local okf, f = pcall(function() return hs.json.decode(payload.text or "{}") end)
    f = (okf and type(f) == "table") and f or {}
    f.limit = 0  -- export is the full-data path: NEVER the capped webview slice
    local res = FX.readLedger(f)
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
    -- `types` counts as scope (core.purgeFilterIsScoped): a type-only purge must
    -- delete just that type, not escalate to f.all = every ledger file.
    local scope
    if core.purgeFilterIsScoped(f) then scope = "events matching the current filter"
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
      -- PAST days only (enforcing redactLedger's contract): today's file is hot
      -- with hook appends, and the rewrite+rename would silently destroy one.
      if not core.ledgerDayIsPast(day, FX.now()) then
        pcall(function() hs.alert.show("Claude Shepherd: can't redact today's events yet — try after UTC midnight") end)
        return
      end
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
    f.limit = 0  -- review narrates the FULL filtered history, not the webview slice
    local res = FX.readLedger(f)
    local scope = f.session and ("session " .. tostring(target.name or f.session)) or "all sessions"
    local prompt = core.auditReviewPrompt(core.renderNarrative(res.events), { scope = scope })
    -- Serialized like every keystroke chain (R3 #2/#5); pasteIntoWindow reports
    -- delivery (false = no positive window match), so a skipped paste must not
    -- be announced as sent (R3 #0 -- same contract as the Improve caller).
    dispatchSerialized(target, a, function()
      if FX.pasteIntoWindow(winTarget(target), { text = prompt }) then
        pcall(function() hs.alert.show("Claude Shepherd: sent a " .. #res.events .. "-event review to " .. tostring(target.name)) end)
      else
        pcall(function() hs.alert.show("Claude Shepherd: no window match for " .. tostring(target.name) .. " — review NOT sent") end)
      end
    end)
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
        -- Headless targets (kitty / armed-gate decisions) can all fire now. The
        -- window-keystroke ones focus NOW but inject on after() timers, so a
        -- synchronous loop would land every session's keys in the LAST-focused
        -- window -- the chokepoint reserves a slot on the SHARED injection tail
        -- so each chain finishes before the next, including chains still pending
        -- from an earlier dispatch (a second bulk click must queue, not interleave).
        dispatchSerialized(it, action, function() core.handleAction(FX, it, action, text) end)
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
  -- Remote (bridge) tiles are headless-only in v1: approve/deny route over ssh
  -- (remoteActionAllowed gates on the remote gate actually waiting); local-data
  -- actions (relabel/group/menu) stay fine; everything keystroke- or
  -- local-file-shaped (nudge/stop/clear/compact/focus/autopilot/gate-tools/
  -- mode/model/effort/improve/continue) is refused loudly, never silently.
  if item.remote and a ~= "ctx-menu" and a ~= "relabel" and a ~= "set-group" then
    local ks = core.config(loadConfig(), "bridge.keystrokes", false) == true
    if not core.remoteActionAllowed(item, a, { keystrokes = ks }) then
      pcall(function() hs.alert.show("Claude Shepherd: '" .. a .. "' isn't available for remote session "
        .. tostring(item.label or item.name) .. " (headless approve/deny only)") end)
      return
    end
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
      -- Remote (bridge) tile: every other item is window/keystroke-shaped, so
      -- the menu is just the local-data actions.
      if item.remote then
        ctxMenu:setMenu({
          { title = "Remote session on " .. tostring(item.remote.host) .. " — headless approve/deny only", disabled = true },
          { title = "-" },
          { title = "Relabel…", fn = function()
              pcall(function() wv:evaluateJavaScript("startRename(" .. keyJson .. ")") end)
            end },
          { title = "Set group…", fn = function()
              pcall(function() wv:evaluateJavaScript("startGroup(" .. keyJson .. ")") end)
            end },
        })
        pcall(function() ctxMenu:popupMenu(hs.mouse.absolutePosition(), true) end)
        return
      end
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
                dispatchSerialized(item, "clear", function() FX.typeIntoWindow(winTarget(item), "/clear") end)
                ledgerFor(item, { type = "clear" })
                refresh()
              end },
            { title = "Cancel", fn = function() end },
        } },
        { title = "Compact", menu = {
            { title = "Confirm: compact (summarize) " .. shown, fn = function()
                dispatchSerialized(item, "compact", function() FX.typeIntoWindow(winTarget(item), "/compact") end)
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
                -- ⌘⇧W is a window keystroke -> serialized (R3 #2/#5).
                dispatchSerialized(item, "close", function() core.handleAction(FX, item, "close") end)
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
              dispatchSerialized(item, "close", function() core.handleAction(FX, item, "close") end)
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
                -- rs.providerId=nil means a FAITHFUL bare-claude relaunch: pass the
                -- explicit-none sentinel "" so it can't inherit the spawn.provider default.
                FX.spawnSession(rs.editor, rs.project, nil, rs.permissionMode, rs.providerId or "")
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
    -- clears it, not closing a session. ⌘⇧W is a window keystroke, so it must
    -- reserve a slot like every other chain (R3 #2/#5: this branch used to
    -- early-return BEFORE the staggered tail below).
    dispatchSerialized(item, a, function() core.handleAction(FX, item, "close") end)
    refresh()
    return
  end
  if a == "nudge" and payload.img and payload.img ~= "" then
    -- Image paste: decode the data URL to a temp file, then paste it (+ any text).
    local parsed = core.parseDataUrl(tostring(payload.img))
    if parsed then
      local path = FX.writeImageTemp(parsed.b64, parsed.ext)
      if path then
        -- Serialized (R3 #2/#5), and gated on pasteIntoWindow's delivery status
        -- (R3 #1): a skipped paste (no window match, or a kitty target -- no
        -- image attach over `kitty @`) must ledger nudge_skipped, never a
        -- delivery that didn't happen (same contract as task_feed_skipped),
        -- and tell the operator instead of dropping the nudge silently.
        dispatchSerialized(item, a, function()
          if FX.pasteIntoWindow(winTarget(item), { text = payload.text and tostring(payload.text) or nil, imagePath = path }) then
            ledgerFor(item, { type = "nudge", text = tostring(payload.text or ""):sub(1, 200), image = true })
          else
            ledgerFor(item, { type = "nudge_skipped", text = tostring(payload.text or ""):sub(1, 200), image = true })
            pcall(function() hs.alert.show("Claude Shepherd: no window match for " .. tostring(item.label or item.name) .. " — nudge NOT sent") end)
          end
        end)
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
  elseif a == "continue" then
    ledgerFor(item, { type = "continue" })  -- resumed a session frozen on an API error
  end
  local text = payload.text and tostring(payload.text) or nil
  local function dispatch()
    local acted = core.handleAction(FX, item, a, text)
    -- A text nudge is ledgered AFTER dispatch, gated on what was DELIVERED:
    -- handleAction returns nil when pasteIntoWindow reported a skip (no window
    -- match), so the audit ledger records nudge_skipped instead of a delivery
    -- that never happened (R3 #1 -- same contract as task_feed_skipped).
    if a == "nudge" and text and #text > 0 then
      ledgerFor(item, { type = (acted == "nudge") and "nudge" or "nudge_skipped",
                        text = tostring(text):sub(1, 200) })
    end
    -- set-mode fires Shift+Tab blind: no hook reports the new mode, so the stored
    -- permission_mode goes stale, the dropdown snaps back ~1s later, and a re-pick
    -- would compute the cycle count from the WRONG base (landing past the target).
    -- Optimistically persist the target mode -- but ONLY on a real dispatch:
    -- handleAction returns nil when FX.sendKeys reported a skip (window miss /
    -- dead kitty target), so the panel never claims a mode the session isn't in.
    -- The next real hook overwrites the optimistic value.
    if acted == "set-mode" then
      item.permission_mode = tostring(payload.text or "")
      FX.patchStatus(item.key, { permission_mode = item.permission_mode })
    end
  end
  -- Window-keystroke actions reserve a slot on the shared injection tail so
  -- they queue behind any chains still pending (bulk stagger window, or a
  -- rapid previous per-tile action) instead of interleaving with them;
  -- headless ones (kitty / armed-gate decisions) fire now.
  dispatchSerialized(item, a, dispatch)
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
  -- An ungated approve/stop is a window keystroke -> serialized (R3 #2/#5).
  dispatchSerialized(item, action, function() core.handleAction(FX, item, action) end)
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
  .age  { font-size:11px; color:#8a8d99; font-weight:400; }  /* elapsed-in-status, inline before the status word */
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  /* context-fullness mini-bar (per tile + detail): a labeled gauge that tracks Claude Code's
     "% until auto-compact". Color ramp steps every 10% from 50%, with a critical last-5% band. */
  .ctx-bar { position:relative; height:12px; border-radius:3px; background:#2c2f3a; overflow:hidden; margin-top:4px; grid-column:1 / -1; }
  .ctx-bar > i { display:block; height:100%; width:0; background:#3b82f6; transition:width .3s ease; }
  .ctx-bar.b0 > i { background:#3b82f6; }  /* <50%  calm blue   */
  .ctx-bar.b1 > i { background:#22c55e; }  /* 50-60 green       */
  .ctx-bar.b2 > i { background:#84cc16; }  /* 60-70 lime        */
  .ctx-bar.b3 > i { background:#eab308; }  /* 70-80 yellow      */
  .ctx-bar.b4 > i { background:#f97316; }  /* 80-90 orange      */
  .ctx-bar.b5 > i { background:#ef4444; }  /* 90-95 red         */
  .ctx-bar.b6 > i { background:#dc2626; }  /* 95-100 critical   */
  .ctx-bar.b6 { animation:pulse 1.6s ease-in-out infinite; }
  .ctx-bar .pct { position:absolute; top:50%; right:4px; transform:translateY(-50%); font-size:9px; line-height:1;
                  font-weight:600; color:#fff; text-shadow:0 0 2px rgba(0,0,0,.95), 0 0 3px rgba(0,0,0,.85); pointer-events:none; }
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
  /* gate decision log (roadmap #2): last-N grouped gate decisions, dim one-liners */
  #d-decisions { display:none; font-size:11px; color:#8a8d99; margin:6px 0 0; line-height:1.5; }
  #d-decisions .dec-deny { color:#e88; }
  #d-decisions .dec-fallback { color:#f5b50a; }
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
  #q-count { font-size:12px; color:#9fb6d6; flex:1; cursor:pointer; }
  #q-count:hover { text-decoration:underline; }
  #route-lbl { font-size:11px; color:#9aa0ad; display:flex; align-items:center; gap:3px; cursor:pointer; }
  /* queue editor (roadmap #5): expandable task list with reorder/remove */
  #queue-list { display:none; margin-top:4px; border:1px solid #2c2f3a; border-radius:8px;
                background:#191b22; max-height:140px; overflow-y:auto; }
  #queue-list.show { display:block; }
  .ql-row { display:flex; align-items:center; gap:4px; padding:3px 8px;
            border-bottom:1px solid #1e2027; font-size:12px; }
  .ql-row:last-child { border-bottom:none; }
  .ql-text { flex:1; color:#cfd2db; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ql-row button { background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:5px;
                   padding:0 5px; cursor:pointer; font-size:11px; }
  .ql-row button:disabled { opacity:.3; cursor:default; }
  .ql-row button.ql-x { color:#e88; border-color:#3a2c2f; }
  /* saved task templates (roadmap #5c) */
  #b-tpl { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px;
           font-size:12px; padding:4px 8px; cursor:pointer; }
  #tpl-menu { display:none; margin-top:4px; border:1px solid #2c2f3a; border-radius:8px;
              background:#191b22; max-height:160px; overflow-y:auto; }
  #tpl-menu.show { display:block; }
  .tpl-row { display:flex; align-items:center; gap:6px; padding:4px 8px;
             border-bottom:1px solid #1e2027; font-size:12px; cursor:pointer; }
  .tpl-row:hover { background:#21232c; }
  .tpl-row:last-child { border-bottom:none; }
  .tpl-name { color:#cfd2db; white-space:nowrap; font-weight:600; }
  .tpl-text { flex:1; color:#8a8d99; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .tpl-row button { background:none; border:1px solid #3a2c2f; color:#e88; border-radius:5px;
                    padding:0 5px; cursor:pointer; font-size:11px; }
  .tpl-save { color:#8fd4a3; font-style:italic; }
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
  /* fuzzy folder search (roadmap #4b): suggestion dropdown under #n-path */
  #n-suggest { display:none; border:1px solid #2c2f3a; border-radius:8px; background:#1b1d24;
               max-height:160px; overflow-y:auto; margin-top:2px; }
  #n-suggest.show { display:block; }
  .n-sug { padding:5px 10px; font-size:12px; color:#cfd2db; cursor:pointer;
           border-bottom:1px solid #21232c; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .n-sug:hover, .n-sug.sel { background:#23304a; }
  /* spawn presets (roadmap #4a): chip row; ✕ inside the chip deletes */
  .n-chip .chip-x { margin-left:6px; color:#8a8d99; }
  .n-chip .chip-x:hover { color:#e88; }
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
/* notification history (roadmap #6): "since you last looked" highlight + 🔔 badge */
.a-row.unseen{ background:#1d2333; border-left:2px solid #6ea8fe; padding-left:6px; }
#notify-btn{ background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px;
             font-size:13px; padding:3px 8px; cursor:pointer; position:relative; }
#notify-badge{ display:none; background:#ef4444; color:#fff; border-radius:8px; font-size:9px;
               padding:0 4px; margin-left:3px; vertical-align:top; font-variant-numeric:tabular-nums; }
#a-foot{ display:flex; gap:8px; align-items:center; padding:8px 10px; border-top:1px solid #2c2f3a; }
#a-info{ margin-left:auto; }
/* Fleet-wide search overlay (roadmap #3; modeled on #audit). Read-only. */
#fsearch{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#fsearch.show{ display:flex; }
#fs-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; }
#fs-head input{ flex:1; background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 8px; font-size:12px; }
#fs-body{ flex:1; overflow:auto; padding:6px 10px; }
.fs-row{ display:flex; gap:8px; align-items:baseline; padding:4px 0; border-bottom:1px solid #1e2027; cursor:pointer; }
.fs-row:hover{ background:#191c24; }
.fs-row.dead{ cursor:default; }
.fs-who{ color:#9fb6d6; white-space:nowrap; max-width:170px; overflow:hidden; text-overflow:ellipsis; }
.fs-file{ color:#6b7280; white-space:nowrap; font-variant-numeric:tabular-nums; }
.fs-text{ color:#cfd2db; flex:1; word-break:break-all; font-family:ui-monospace,Menlo,monospace; font-size:11px; }
.fs-jump{ background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:5px; padding:0 6px; cursor:pointer; font-size:11px; }
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
      <button id="spawn" onclick="openNew()" title="Spawn a new Claude session">New</button>
      <button id="caffeine" onclick="toggleCaffeine()" title="Keep this Mac awake — pmset disablesleep (asks for your password)">☕ Sleep ok</button>
      <button id="search-btn" onclick="toggleSearch()" title="Filter sessions (name, project, status, group)">🔍</button>
      <button id="fsearch-btn" onclick="openFleetSearch()" title="Find in fleet — search every session's transcript + the ledger (which session touched that file?)">🔎</button>
      <button id="insights-btn" onclick="openInsights()" title="Fleet insights — aggregate stats from the ledger">📊</button>
      <button id="audit-btn" onclick="openAudit()" title="Audit ledger — recorded fleet activity">📜</button>
      <button id="notify-btn" onclick="openNotifications()" title="Notification history — what fired while you were away">🔔<span id="notify-badge"></span></button>
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
    <div id="d-decisions"></div>
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
      <button id="b-tpl" onclick="toggleTemplates()" title="Saved task templates — insert into the input (never auto-sends)">Tpl ▾</button>
    </div>
    <div id="tpl-menu"></div>
    <div id="nudge-chip"><span id="nudge-chip-label"></span><button onclick="clearImage()" title="Remove image">✕</button></div>
    <div id="queue-row">
      <span id="q-count" onclick="toggleQueueList()" title="Click to view / reorder / remove queued tasks"></span>
      <label id="route-lbl" title="4c-E project routing: feed this project's queue to WHICHEVER of its sessions is free (not just the one that finished). Per-project flag; also needs Settings → Queue → project routing enabled. Logged as by:'router'."><input type="checkbox" id="q-route" onchange="onRouteToggle()"> route</label>
      <button id="b-feed" onclick="act('queue-feed')">Feed next</button>
    </div>
    <div id="queue-list"></div>
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
      <label class="s-row"><input type="checkbox" id="s-q-route"> Project routing (4c-E): feed a project's queue to <i>any</i> free session of that project</label>
      <div class="s-help">Double opt-in: this global switch AND the per-project "route" toggle in the detail panel. Targets only sessions that just finished a turn (never one you're typing into); one feed per project per second; every routed feed is ledgered as by:"router". Flag a starving project after <input type="number" id="s-q-starve" class="s-num" min="0"> minutes with queued work but no free session (0 = off).</div>
      <div class="s-sec">Escalation (a waiting approval nags harder)</div>
      <label class="s-row"><input type="checkbox" id="s-e-en"> Enable escalation</label>
      <label class="s-row">After <input type="number" id="s-e-min" class="s-num" min="1"> minutes</label>
      <label class="s-row"><input type="checkbox" id="s-e-snd"> Play a sound</label>
      <label class="s-row"><input type="checkbox" id="s-e-push"> Push to ntfy topic <input type="text" id="s-e-topic" class="s-txt" placeholder="my-topic"></label>

      <div class="s-sec">Risk score (per-session indicator on tiles)</div>
      <label class="s-row"><input type="checkbox" id="s-risk-en"> Show a med/high risk badge from ledger history</label>
      <div class="s-help">Indicator only — never quarantines. Needs the audit ledger enabled to have data. Band thresholds (score 0–100): med ≥ <input type="number" id="s-risk-med" class="s-num" min="0" max="100"> high ≥ <input type="number" id="s-risk-high" class="s-num" min="0" max="100">, slow-approval signal after <input type="number" id="s-risk-stale" class="s-num" min="1"> s. Signal weights stay hand-edit-only (<code>risk.weights</code> in cc-config.json) and survive Saves.</div>

      <div class="s-sec">Same-folder collision warning</div>
      <label class="s-row"><input type="checkbox" id="s-coll-en"> Amber-flag tiles when 2+ active sessions share a folder</label>
      <label class="s-row"><input type="checkbox" id="s-coll-git"> Compare by git repo root (not just the exact folder)</label>

      <div class="s-sec">Graceful drain</div>
      <label class="s-row"><input type="checkbox" id="s-drain-en"> Show "finish turn, then close" in the tile right-click menu</label>

      <div class="s-sec">Respawn</div>
      <label class="s-row"><input type="checkbox" id="s-resp-en"> Show "Respawn from cwd" in the tile right-click menu (relaunch a dead session)</label>
      <label class="s-row"><input type="checkbox" id="s-resp-auto"> Auto-respawn a session that died unexpectedly</label>
      <div class="s-help">⚠ Launches processes without you. Per-folder retry budget of <input type="number" id="s-resp-max" class="s-num" min="1"> attempts; a session counts as dead only after its status file is frozen mid-<code>working</code> for <input type="number" id="s-resp-stale" class="s-num" min="60"> s (default 600 — above the longest Bash tool timeout, so a long build never triggers it).</div>

      <div class="s-sec">Auto-Continue (API-error recovery)</div>
      <label class="s-row"><input type="checkbox" id="s-cont-auto"> Auto-resume a session frozen on an API error (types "continue")</label>
      <div class="s-help">⚠ Sends a keystroke without you. When a tile shows the magenta <code>Error</code> state (e.g. ECONNRESET, no Stop hook), wait <input type="number" id="s-cont-delay" class="s-num" min="5"> s then type <code>continue</code> to resume the same session. Capped at <input type="number" id="s-cont-max" class="s-num" min="1"> attempts per folder (a clean turn completion resets the budget) so a persistently dead connection can't loop.</div>

      <div class="s-sec">Insights</div>
      <label class="s-row">Cap "time blocked on you" per approval at <input type="number" id="s-ins-block" class="s-num" min="0"> seconds</label>
      <div class="s-help">An approval you never answered counts as blocking for at most this long in the 📊 fleet stats (0 = no cap).</div>

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
      <div class="s-sec">Spawn (the New / New project launcher)</div>
      <label class="s-row">Open new sessions in
        <select id="s-spawn-editor">
          <option value="terminal">Terminal</option>
          <option value="kitty">Kitty</option>
          <option value="vscode">VS Code</option>
          <option value="cursor">Cursor</option>
        </select>
      </label>
      <label class="s-row">VS Code / Cursor spawns open
        <select id="s-spawn-vsflavor">
          <option value="extension">the Claude Code extension (⌘Esc panel)</option>
          <option value="terminal">an integrated terminal running claude</option>
        </select>
      </label>
      <div class="s-help">Extension = the side-panel UI (resume recent / new session). Terminal = the CLI typed into a fresh integrated terminal. Both are best-effort keystrokes; ssh spawns always use the terminal. Kitty/Terminal spawns are unaffected.</div>
      <label class="s-row"><input type="checkbox" id="s-spawn-live"> Actually launch (off = dry-run: log only, don't spawn)</label>
      <label class="s-row"><input type="checkbox" id="s-kitty-remote"> Give spawned Kitty windows remote control (recommended)</label>
      <label class="s-row"><input type="checkbox" id="s-kitty-auto"> Auto-enable Kitty remote control in kitty.conf when Kitty is in use</label>
      <label class="s-row"><button class="s-x" style="border:1px solid #2c2f3a;border-radius:6px;padding:3px 8px;color:#cfd2db;" onclick="send('kitty-remote')">Enable Kitty remote control now</button></label>
      <label class="s-row">Default provider <select id="s-spawn-provider"></select></label>

      <div class="s-sec">Claude Code Remote Control (drive sessions from claude.ai / mobile)</div>
      <label class="s-row"><input type="checkbox" id="s-rc-spawn"> Launch new sessions with <code>--remote-control</code> (auto-register RC)</label>
      <label class="s-row"><input type="checkbox" id="s-rc-sweep"> On startup, type <code>/rc</code> into already-running sessions</label>
      <div class="s-help">Distinct from Kitty remote control above (that lets Shepherd drive the window). This is Claude Code's own Remote Control — continue a local session from claude.ai or the Claude app. New Shepherd spawns get the <code>--remote-control</code> flag (native-Anthropic, local sessions only — RC rejects gateway/ssh providers); the startup sweep covers sessions started outside Shepherd. To auto-enable RC for sessions you start in a terminal yourself, run <code>/config</code> in Claude Code and set <b>Enable Remote Control for all sessions</b> (no settings.json key is documented for it).</div>

      <div class="s-sec">SSH status bridge (remote sessions as tiles)</div>
      <label class="s-row"><input type="checkbox" id="s-br-en"> Mirror remote sessions from ssh providers into the panel</label>
      <div class="s-help">For providers that declare <code>ssh:{host,user}</code> (hand-edit in cc-config.json for now): rsync-pulls each host's remote <code>~/.claude/cc-status/</code> every <input type="number" id="s-br-int" class="s-num" min="1"> s so its sessions render as ⇄ tiles. Remote tiles are <b>headless-only</b>: Approve/Deny route back over ssh (nonce-bound); keystroke actions are disabled. Needs key-based ssh auth (BatchMode) and the remote box set up with <code>make install</code>. Off by default.</div>

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
      <div class="s-help">One rule per line. <code>Read</code> matches the tool by name; <code>Bash(npm test*)</code> also shell-glob-matches the command/summary (<code>*</code> and <code>?</code> wildcards).</div>
      <div class="s-lbl">Auto-deny (wins over allow)</div>
      <textarea id="s-pat-deny" class="s-area"></textarea>
      <div class="s-help">Same syntax, e.g. <code>Bash(rm -rf*)</code> or <code>WebFetch</code>. A request matching both lists is denied — deny always wins.</div>
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
      <div class="s-lbl">Presets</div>
      <div id="n-presets" class="n-recent"></div>
      <div class="s-lbl">Project folder (type to fuzzy-search your project roots)</div>
      <input id="n-path" class="s-txt" placeholder="/Users/you/Programming/project" autocomplete="off"
             oninput="onPathInput()" onkeydown="onPathKey(event)" onchange="applyLastUsed(this.value)">
      <div id="n-suggest"></div>
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
      <button onclick="savePreset()" title="Save the current folder + editor + mode + provider as a one-click preset">Save as preset</button>
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
      <button id="a-tab-alerts" class="a-tab" onclick="auditTab('alerts')">🔔 Alerts</button>
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

  <div id="fsearch">
    <div id="fs-head">
      <span>🔎 Find in fleet</span>
      <input type="text" id="fs-input" placeholder="Search transcripts + ledger… (3+ chars; auth.ts, a command, an error…)"
             oninput="onFleetSearchInput()" autocomplete="off">
      <span id="fs-info" class="n-dim"></span>
      <button class="s-x" onclick="closeFleetSearch()">✕</button>
    </div>
    <div id="fs-body"><div class="s-help" style="margin-left:0;">Searches every session's transcript JSONL (live and dead) plus the audit ledger. Instant with ripgrep installed (<code>brew install ripgrep</code>); falls back to grep.</div></div>
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
      if(!selectedKey || !t) return;
      // Bulk paste (roadmap #5b): a multi-line input splits into one task per
      // line. The count here is display-only -- the authoritative split rules
      // (CRLF, bullets, blanks) live in core.queueSplitLines on the Lua side.
      if(t.indexOf("\n") >= 0){
        var n = t.split("\n").map(function(s){ return s.trim(); })
                 .filter(function(s){ return s.length > 0; }).length;
        if(n > 1){
          if(confirm("Queue " + n + " tasks (one per line)?")){
            send("queue-add-bulk", selectedKey, t); resetInput(el);
          }
          return;  // cancelled: leave the textarea untouched (Send still works)
        }
      }
      send("queue-add", selectedKey, t); resetInput(el);
    }

    // ---- Queue editor (roadmap #5a): list / reorder / remove ---------------
    var QUEUE_LIST = { key: null, tasks: [] };
    var queueListOpen = false;
    function toggleQueueList(){
      queueListOpen = !queueListOpen;
      if(queueListOpen && selectedKey){ send("queue-list", selectedKey); }
      renderQueueList();
    }
    function ccQueueList(key, tasks){
      QUEUE_LIST = { key: key, tasks: tasks || [] };
      renderQueueList();
    }
    function renderQueueList(){
      var box = document.getElementById("queue-list"); if(!box) return;
      var ok = queueListOpen && selectedKey && QUEUE_LIST.key === selectedKey
               && QUEUE_LIST.tasks && QUEUE_LIST.tasks.length;
      box.classList.toggle("show", !!ok);
      if(!ok){ box.innerHTML = ""; return; }
      box.innerHTML = QUEUE_LIST.tasks.map(function(t, i){
        var n = QUEUE_LIST.tasks.length;
        // idx+task ride along as the expect guard: the Lua side refuses the
        // edit if the queue changed underneath (autofeed popped the head).
        return '<div class="ql-row">'
          + '<span class="ql-text" title="' + esc(t) + '">' + (i+1) + '. ' + esc(t) + '</span>'
          + '<button onclick="queueMove(' + i + ',-1)"' + (i === 0 ? ' disabled' : '') + ' title="Move up">▲</button>'
          + '<button onclick="queueMove(' + i + ',1)"' + (i === n-1 ? ' disabled' : '') + ' title="Move down">▼</button>'
          + '<button class="ql-x" onclick="queueRemove(' + i + ')" title="Remove">✕</button>'
          + '</div>';
      }).join("");
    }
    function queueMove(i, dir){
      if(!selectedKey) return;
      send("queue-move", selectedKey, JSON.stringify({ idx: i+1, dir: dir, task: QUEUE_LIST.tasks[i] }));
    }
    function queueRemove(i){
      if(!selectedKey) return;
      send("queue-remove", selectedKey, JSON.stringify({ idx: i+1, task: QUEUE_LIST.tasks[i] }));
    }
    // 4c-E: arm/disarm project routing (per-project flag in the queue file).
    function onRouteToggle(){
      if(!selectedKey) return;
      send("queue-route", selectedKey, document.getElementById("q-route").checked ? "on" : "off");
    }

    // ---- Saved task templates (roadmap #5c) --------------------------------
    var TEMPLATES = [];
    var tplOpen = false;
    function toggleTemplates(){
      tplOpen = !tplOpen;
      if(tplOpen){ send("template-list"); }
      renderTemplates();
    }
    function ccTemplates(list){ TEMPLATES = list || []; renderTemplates(); }
    function renderTemplates(){
      var box = document.getElementById("tpl-menu"); if(!box) return;
      box.classList.toggle("show", tplOpen);
      if(!tplOpen){ box.innerHTML = ""; return; }
      var html = '<div class="tpl-row tpl-save" onclick="templateSaveCurrent()">＋ Save current input as template…</div>';
      html += TEMPLATES.map(function(t){
        return '<div class="tpl-row" onclick="templateInsert(' + JSON.stringify(t.name).replace(/"/g,"&quot;").replace(/</g,"&lt;") + ')">'
          + '<span class="tpl-name">' + esc(t.name) + '</span>'
          + '<span class="tpl-text">' + esc(t.text) + '</span>'
          + '<button onclick="event.stopPropagation();templateDelete(' + JSON.stringify(t.name).replace(/"/g,"&quot;").replace(/</g,"&lt;") + ')" title="Delete">✕</button>'
          + '</div>';
      }).join("");
      box.innerHTML = html;
    }
    function templateInsert(name){
      for(var i = 0; i < TEMPLATES.length; i++){
        if(TEMPLATES[i].name === name){
          var el = document.getElementById("nudge");
          el.value = TEMPLATES[i].text; autoGrow(el); el.focus();
          break;
        }
      }
      tplOpen = false; renderTemplates();
    }
    function templateSaveCurrent(){
      var t = (document.getElementById("nudge").value || "").trim();
      if(!t){ alert("Type the task text into the input first, then save it as a template."); return; }
      var name = prompt("Template name?");
      if(name === null) return;
      send("template-save", name, t);  // Lua validates + replies with the fresh list
    }
    function templateDelete(name){
      if(confirm('Delete template "' + name + '"?')){ send("template-delete", name); }
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
      ck("s-q-route", cv(cfg,"queue.routing.enabled",false));
      val("s-q-starve", cv(cfg,"queue.routing.starveMinutes",0));
      ck("s-br-en",  cv(cfg,"bridge.enabled",false));
      val("s-br-int", cv(cfg,"bridge.intervalSeconds",2));
      ck("s-e-en",   cv(cfg,"escalation.enabled",false));
      val("s-e-min", cv(cfg,"escalation.minutes",5));
      ck("s-e-snd",  cv(cfg,"escalation.sound",false));
      ck("s-e-push", cv(cfg,"escalation.push",false));
      val("s-e-topic", cv(cfg,"escalation.pushTopic",""));
      // Dark-config blocks (defaults must match the Lua read sites in refresh()).
      ck("s-risk-en",    cv(cfg,"risk.enabled",false));
      val("s-risk-med",  cv(cfg,"risk.thresholds.med",34));
      val("s-risk-high", cv(cfg,"risk.thresholds.high",67));
      val("s-risk-stale",cv(cfg,"risk.thresholds.staleSeconds",300));
      ck("s-coll-en",    cv(cfg,"collision.enabled",false));
      ck("s-coll-git",   cv(cfg,"collision.useGitRoot",false));
      ck("s-drain-en",   cv(cfg,"drain.enabled",false));
      ck("s-resp-en",    cv(cfg,"respawn.enabled",false));
      ck("s-resp-auto",  cv(cfg,"respawn.auto.enabled",false));
      val("s-resp-max",  cv(cfg,"respawn.auto.maxRetries",3));
      val("s-resp-stale",cv(cfg,"respawn.auto.staleSeconds",600));
      ck("s-cont-auto",  cv(cfg,"autoContinue.enabled",false));
      val("s-cont-delay",cv(cfg,"autoContinue.delaySeconds",60));
      val("s-cont-max",  cv(cfg,"autoContinue.maxAttempts",3));
      val("s-ins-block", cv(cfg,"insights.maxBlockSeconds",1800));
      var legacyPop = cv(cfg,"focus.popEditor",false);  // back-compat seeds both
      ck("s-pop-complete", cv(cfg,"focus.popOnComplete",legacyPop));
      ck("s-pop-approval", cv(cfg,"focus.popOnApproval",legacyPop));
      val("s-spawn-editor", cv(cfg,"spawn.editor","terminal"));
      val("s-spawn-vsflavor", cv(cfg,"spawn.vscodeFlavor","extension"));
      ck("s-spawn-live",  cv(cfg,"spawn.live",false));
      ck("s-kitty-remote", cv(cfg,"spawn.kittyRemote",true));
      ck("s-kitty-auto",  cv(cfg,"spawn.kittyAutoRemote",true));
      ck("s-rc-spawn",    cv(cfg,"remoteControl.onSpawn",true));
      ck("s-rc-sweep",    cv(cfg,"remoteControl.sweepOnStartup",true));
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
    // Each row MERGES onto its stored entry (via data-i): fields the card doesn't
    // render (id, ssh, contextLimit, anything future) must survive a Save, and a
    // stored id is kept as-is — regenerating it from the label would silently break
    // the spawn.provider default and any hand-edited id. Slugs are only minted for
    // entries that don't have an id yet (freshly added rows).
    function collectProviders(){
      var out = [];
      document.querySelectorAll("#s-providers .prov").forEach(function(card){
        function v(sel){ var el=card.querySelector(sel); return el? (el.value||"").trim() : ""; }
        var i = parseInt(card.getAttribute("data-i"), 10);
        var prev = (!isNaN(i) && PROVIDERS[i]) ? PROVIDERS[i] : {};
        var p = {}; for(var k in prev){ p[k] = prev[k]; }
        var label = v(".p-label"), model = v(".p-model");
        p.label = label; p.kind = card.querySelector(".p-kind").value; p.model = model;
        if(!p.id) p.id = slugify(label) || slugify(model);
        if(p.kind === "gateway"){
          p.baseUrl = v(".p-baseurl"); p.authTokenEnv = v(".p-authenv");
          p.smallFastModel = v(".p-smallfast"); p.headers = v(".p-headers");
        } else {
          // Kind switched (gateway -> claude): drop the gateway-only fields the
          // merge inherited from the stored entry. A stale baseUrl poisons
          // respawn matching (providerByModel reads it as a gateway signature),
          // silently relaunching the session as bare `claude` on the wrong model.
          delete p.baseUrl; delete p.authTokenEnv;
          delete p.smallFastModel; delete p.headers;
        }
        out.push(p);
      });
      PROVIDERS = out;
      return out;
    }
    function nonBlankProviders(){ return collectProviders().filter(function(p){ return p.label || p.model; }); }
    // Populate the default-provider select from the (non-blank) providers. `want`
    // is the value to select: showSettings passes the SAVED spawn.provider ("" =
    // bare claude) and the add/remove callers pass the live DOM value explicitly.
    // No sel.value fallback: the saved "" sentinel is falsy, so falling back to
    // the stale DOM would resurrect a CANCELLED pick on the next open -- and any
    // Save (incl. the auto-persisting Headless toggle) would silently persist it.
    function refreshProviderDefault(want){
      var list = nonBlankProviders();
      var sel = document.getElementById("s-spawn-provider");
      want = want || "";
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
        queue: { autofeed: ck("s-q-auto"), dryRun: ck("s-q-dry"),
                 routing: { enabled: ck("s-q-route"), starveMinutes: num("s-q-starve",0) } },
        escalation: { enabled: ck("s-e-en"), minutes: num("s-e-min",5), sound: ck("s-e-snd"),
                      push: ck("s-e-push"), pushTopic: txt("s-e-topic") },
        focus: { popOnComplete: ck("s-pop-complete"), popOnApproval: ck("s-pop-approval") },
        spawn: { editor: txt("s-spawn-editor"), live: ck("s-spawn-live"),
                 vscodeFlavor: txt("s-spawn-vsflavor"),
                 kittyRemote: ck("s-kitty-remote"), kittyAutoRemote: ck("s-kitty-auto"),
                 provider: txt("s-spawn-provider") },
        remoteControl: { onSpawn: ck("s-rc-spawn"), sweepOnStartup: ck("s-rc-sweep") },
        providers: nonBlankProviders(),
        gate: { tools: txt("s-gate-tools") },
        ledger: { enabled: ck("s-ledger-en"), retentionDays: num("s-ledger-days",30),
                  maxTotalMB: num("s-ledger-mb",0), captureTypes: toks("s-ledger-types") },
        policies: {
          approveRepeats: ck("s-p-rep"),
          autopilot: { enabled: ck("s-ap-en"), minutes: num("s-ap-min",15) },
          patterns: { enabled: ck("s-pat-en"), autoAllow: lines("s-pat-allow"), autoDeny: lines("s-pat-deny") }
        },
        // Dark-config blocks. risk deliberately carries NO weights key:
        // overlayConfig's SETTINGS_KEEP_SUBKEYS preserves a hand-edited
        // risk.weights across this wholesale block replace.
        risk: { enabled: ck("s-risk-en"),
                thresholds: { med: num("s-risk-med",34), high: num("s-risk-high",67),
                              staleSeconds: num("s-risk-stale",300) } },
        collision: { enabled: ck("s-coll-en"), useGitRoot: ck("s-coll-git") },
        drain: { enabled: ck("s-drain-en") },
        respawn: { enabled: ck("s-resp-en"),
                   auto: { enabled: ck("s-resp-auto"), maxRetries: num("s-resp-max",3),
                           staleSeconds: num("s-resp-stale",600) } },
        autoContinue: { enabled: ck("s-cont-auto"), delaySeconds: num("s-cont-delay",60),
                        maxAttempts: num("s-cont-max",3) },
        insights: { maxBlockSeconds: num("s-ins-block",1800) },
        // bridge carries NO staleSlackSeconds/keystrokes keys: SETTINGS_KEEP_SUBKEYS
        // preserves the hand-edited ones across this wholesale block replace.
        bridge: { enabled: ck("s-br-en"), intervalSeconds: num("s-br-int",2) }
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
    var PRESETS = [];            // saved spawn presets (roadmap #4a)
    var LAST_BY_PROJECT = {};    // folder -> {editor, permMode, provider} recall
    function showNew(cfg, recent, browse, presetState){
      cfg = cfg || {};
      setMode("existing");
      document.getElementById("n-path").value = "";
      document.getElementById("n-name").value = "";
      document.getElementById("n-task").value = "";
      document.getElementById("n-editor").value = cv(cfg, "spawn.editor", "terminal");
      fillProviderSelect("n-provider", cv(cfg,"providers",[])||[], cv(cfg,"spawn.provider",""));
      presetState = presetState || {};
      PRESETS = presetState.presets || [];
      LAST_BY_PROJECT = presetState.lastByProject || {};
      renderPresets();
      hideSuggest();
      renderRecent(recent || []);
      ccBrowse(browse || { path:"", parent:"", dirs:[] });
      document.getElementById("newsession").classList.add("show");
      document.getElementById("n-path").focus();
    }
    function ccPresets(list){ PRESETS = list || []; renderPresets(); }
    function renderPresets(){
      var box = document.getElementById("n-presets"); box.innerHTML = "";
      if(!PRESETS.length){ box.innerHTML = '<span class="n-dim">No presets yet — set up a spawn below, then "Save as preset"</span>'; return; }
      PRESETS.forEach(function(p){
        var b = document.createElement("button");
        b.className = "n-chip";
        b.title = p.folder + (p.editor ? " · " + p.editor : "") + (p.permMode ? " · " + p.permMode : "")
                + (p.provider ? " · " + p.provider : "") + "\nClick to spawn · ✕ deletes";
        b.textContent = "▶ " + p.name;
        var x = document.createElement("span");
        x.className = "chip-x"; x.textContent = "✕";
        x.onclick = function(ev){
          ev.stopPropagation();
          if(confirm('Delete preset "' + p.name + '"?')){ send("preset-delete", p.name); }
        };
        b.appendChild(x);
        b.onclick = function(){ presetSpawn(p); };
        box.appendChild(b);
      });
    }
    // One-click spawn from a preset: same payload submitNew builds, no field
    // round-trip (the saved bundle IS the form state).
    function presetSpawn(p){
      var task = (document.getElementById("n-task").value || "").trim();
      var payload = { a:"spawn", v:"", text:task, img:"", mode:"existing", dir:p.folder,
                      editor:p.editor || "", permMode:p.permMode || "", provider:p.provider || "" };
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify(payload)); } catch(e){ console.log("spawn send error", e); }
      closeNew();
    }
    function savePreset(){
      var path = (document.getElementById("n-path").value || "").trim();
      if(!path || path.charAt(0) !== "/"){ alert("Pick an absolute project folder first."); return; }
      var name = prompt("Preset name?");
      if(name === null || !(name = name.trim())) return;
      send("preset-save", "", JSON.stringify({ name: name, folder: path,
        editor: document.getElementById("n-editor").value,
        permMode: document.getElementById("n-permmode").value,
        provider: document.getElementById("n-provider").value }));
    }
    // Per-project recall: picking a known folder pre-fills its last-used options.
    function applyLastUsed(dir){
      dir = (dir || "").replace(/\/+$/, "");
      var spec = LAST_BY_PROJECT[dir];
      if(!spec) return;
      if(spec.editor) document.getElementById("n-editor").value = spec.editor;
      if(spec.permMode != null) document.getElementById("n-permmode").value = spec.permMode;
      if(spec.provider != null) document.getElementById("n-provider").value = spec.provider;
    }

    // ---- Fuzzy folder search (roadmap #4b) ----------------------------------
    // 150ms debounce -> "folder-search" against the Lua-cached index; ranking is
    // pure cc-core. Arrow keys + Enter pick; Escape hides.
    var sugTimer = null, sugItems = [], sugSel = -1;
    function onPathInput(){
      if(sugTimer) clearTimeout(sugTimer);
      var q = document.getElementById("n-path").value || "";
      if(q.trim().length < 2 || q.charAt(0) === "/"){ hideSuggest(); return; }  // absolute paths browse, not search
      sugTimer = setTimeout(function(){ send("folder-search", q); }, 150);
    }
    function ccSearchResults(paths){
      sugItems = paths || []; sugSel = -1;
      var box = document.getElementById("n-suggest");
      if(!sugItems.length){ hideSuggest(); return; }
      box.innerHTML = sugItems.map(function(p, i){
        return '<div class="n-sug" data-i="' + i + '" onclick="pickSuggest(' + i + ')" title="' + esc(p) + '">📁 ' + esc(shortPath(p)) + '</div>';
      }).join("");
      box.classList.add("show");
    }
    function hideSuggest(){
      var box = document.getElementById("n-suggest");
      box.classList.remove("show"); box.innerHTML = ""; sugItems = []; sugSel = -1;
    }
    function pickSuggest(i){
      var p = sugItems[i]; if(!p) return;
      document.getElementById("n-path").value = p;
      hideSuggest();
      applyLastUsed(p);
      browseTo(p);
    }
    function onPathKey(e){
      if(!sugItems.length) return;
      if(e.key === "ArrowDown" || e.key === "ArrowUp"){
        e.preventDefault();
        sugSel = (e.key === "ArrowDown") ? Math.min(sugSel + 1, sugItems.length - 1) : Math.max(sugSel - 1, 0);
        document.querySelectorAll("#n-suggest .n-sug").forEach(function(el, i){
          el.classList.toggle("sel", i === sugSel);
        });
      } else if(e.key === "Enter" && sugSel >= 0){
        e.preventDefault(); pickSuggest(sugSel);
      } else if(e.key === "Escape"){
        hideSuggest();
      }
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
    function pickRecent(dir){ document.getElementById("n-path").value = dir; applyLastUsed(dir); browseTo(dir); }
    function submitNew(){
      var path = (document.getElementById("n-path").value || "").trim();
      // Browsed to a folder but never clicked "Use this folder"? Use it anyway —
      // an empty path otherwise silently falls back to the native prompts.
      if(!path && browsePath){ path = browsePath; }
      if(newMode === "new" && !(document.getElementById("n-name").value || "").trim()){
        alert("Name the new project folder first (it's created inside " + (path || "the chosen folder") + ").");
        return;
      }
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
      if(key !== selectedKey){
        detailExpanded = { pending:false, activity:false };
        requestDecisions(key);  // gate decision log loads per selection, not per tick
        queueListOpen = false; renderQueueList();   // queue editor is per-session
        tplOpen = false; renderTemplates();
      }
      selectedKey = key; renderDetail(); paintSelection();
    }

    // ---- Gate decision log (roadmap #2): last-N grouped decisions ----------
    // Loaded on selection + on the selected tile's status transitions (exactly
    // when a decision likely just landed) -- NEVER on the 1s refresh tick.
    var DECISIONS = { key: null, rows: null };
    function requestDecisions(key){ if(key) send("decision-log", key); }
    window.ccDecisions = function(key, rows){
      DECISIONS = { key: key, rows: rows };
      renderDecisions();
    };
    function renderDecisions(){
      var box = document.getElementById("d-decisions"); if(!box) return;
      var rows = DECISIONS.rows;
      // Stale paint guard: only show data fetched for the CURRENT selection.
      if(DECISIONS.key !== selectedKey || !rows || !rows.length || !rows.map){
        box.style.display = "none"; box.innerHTML = ""; return;
      }
      box.innerHTML = rows.map(function(r){
        var glyph = r.outcome === "deny" ? "⛔" : (r.outcome === "fallback" ? "⚠" : "✅");
        var cls = r.outcome === "deny" ? "dec-deny" : (r.outcome === "fallback" ? "dec-fallback" : "");
        var who = r.by ? (r.by + (r.pattern ? ": " + r.pattern : "")) : "";
        return '<div class="'+cls+'" title="'+esc(r.summary || "")+'">'
          + glyph + " " + esc(r.outcome || "?") + " " + esc(r.tool || "")
          + (r.count > 1 ? " ×" + r.count : "")
          + (who ? " (" + esc(who) + ")" : "")
          + (r.lastTs ? ' <span style="opacity:.7">· ' + fmtAge(r.lastTs) + ' ago</span>' : "")
          + '</div>';
      }).join("");
      box.style.display = "block";
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
      renderDecisions();
      renderDetailUsage(it);
      var n = it.queue || 0;
      document.getElementById("q-count").textContent = n>0 ? ("Queue: " + n + " ▾") : "Queue: empty";
      document.getElementById("b-feed").style.display = n>0 ? "inline-block" : "none";
      document.getElementById("q-route").checked = !!it.routed;
      // Keep the open queue editor honest: re-fetch when the depth moved
      // (autofeed/manual feed popped a head) and fold it shut when empty.
      if(queueListOpen){
        if(n === 0){ queueListOpen = false; renderQueueList(); }
        else if(QUEUE_LIST.key === selectedKey && QUEUE_LIST.tasks.length !== n){
          send("queue-list", selectedKey);
        }
      }
      var ba = document.getElementById("b-auto");
      ba.textContent = it.autopilot ? "Autopilot: ON" : "Autopilot";
      ba.style.color = it.autopilot ? "#8fd4a3" : "#e8e9ee";
      // Remote (bridge) tiles are headless-only: grey every keystroke-shaped
      // control. Approve/Deny stay live only while the remote gate is waiting
      // (they route over ssh as decision files). Queue add/edit and the route
      // toggle stay enabled -- queues are LOCAL data (a future remote feed
      // would use them) -- but Feed next is blocked (no local window).
      var remote = !!it.remote;
      var remoteWait = remote && it.gate === "waiting";
      ["b-jump","b-stop","b-auto","b-clear","b-compact","b-improve","b-nudge","b-feed",
       "effort","mode","d-model","d-gate","nudge"].forEach(function(id){
        var el = document.getElementById(id); if(!el) return;
        el.disabled = remote;
        if(remote){ el.title = "Remote session — headless approve/deny only"; }
        else if(el.title === "Remote session — headless approve/deny only"){ el.title = ""; }
      });
      var bdeny = document.getElementById("b-deny");
      bdeny.disabled = remote && !remoteWait;
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
      // Remote: Approve works only as a headless gate decision (waiting), and
      // Continue (keystrokes) never does.
      bap.disabled = remote && (!remoteWait || st === "error");
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
    // Mirror of core.contextBand: calm <50, a band every 10% from 50, critical last-5%.
    function barLevel(f){ return f>=0.95?"b6":f>=0.90?"b5":f>=0.80?"b4":f>=0.70?"b3":f>=0.60?"b2":f>=0.50?"b1":"b0"; }
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
      return '<div class="ctx-bar '+barLevel(frac)+'" title="Context: '+tok+' ('+pct+'% to auto-compact)"><i style="width:'+pct+'%"></i><span class="pct">'+pct+'%</span></div>';
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
      document.getElementById("a-tab-alerts").classList.toggle("active", v === "alerts");
      renderAudit();
    }
    // JS twin of core.notificationEvents' predicate: panel-raised alerts plus
    // any non-human gate decision (something happened without you).
    function isNotification(e){
      if(e.type === "escalation" || e.type === "hung" || e.type === "auto_respawn" || e.type === "auto_continue") return true;
      return e.type === "decision" && e.by != null && e.by !== "human";
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
      compact:"🗜", nudge:"👉", autopilot_arm:"🛫", spawn:"✨", relabel:"🏷", redact:"🚫", purge:"🗑",
      escalation:"🔴", hung:"⏳", auto_respawn:"♻️", auto_continue:"▶️", drain_close:"⛔" };
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
      else if(e.type === "escalation") detail = "waiting > " + (e.minutes || "?") + "m" + (e.summary ? (' on "' + e.summary + '"') : "");
      else if(e.type === "hung") detail = "no progress > " + (e.minutes || "?") + "m";
      else if(e.type === "auto_respawn") detail = (e.cwd || "") + (e.attempt ? (" (attempt " + e.attempt + ")") : "");
      else if(e.type === "auto_continue") detail = "resumed after API error" + (e.attempt ? (" (attempt " + e.attempt + ")") : "");
      return em + " " + e.type + (detail ? (": " + detail) : "");
    }
    function narr(e){ return fmtTs(e.ts) + "  " + (e.name || e.session_id || "?") + "  " + evDesc(e) + (e.redacted ? " [redacted]" : ""); }
    function auditRow(e){
      var hasContent = (e.prompt || e.summary || e.task || e.text || e.message);
      var canRedact = hasContent && !e.redacted;
      var unseen = auditView === "alerts" && LAST_SEEN > 0 && (e.ts || 0) > LAST_SEEN;
      return '<div class="a-row' + (unseen ? ' unseen' : '') + '">'
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
      if(auditView === "alerts"){ evs = evs.filter(isNotification); }
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
      if(auditView === "alerts" && !evs.length){
        body.innerHTML = '<div class="s-help" style="margin-left:0;">No alerts recorded. '
          + 'Escalations, stall warnings, auto-respawns, and non-human gate decisions land here '
          + '(the audit ledger must be enabled to record them).</div>';
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
    // lastSeen: epoch of the previous 🔔 open -- alerts newer than this render
    // highlighted ("since you last looked"). 0 = no divider.
    var LAST_SEEN = 0;
    window.ccAudit = function(payload, focusSession, focusView, lastSeen){
      AUDIT = payload || { events: [], files: [], truncated: false };
      if(!Array.isArray(AUDIT.events)) AUDIT.events = [];
      if(!Array.isArray(AUDIT.files)) AUDIT.files = [];
      LAST_SEEN = (typeof lastSeen === "number") ? lastSeen : 0;
      populateAuditSessions();
      // Per-session drill-down (Timeline button): pre-select the session + view.
      if(focusSession){ var sel = document.getElementById("a-f-session"); if(sel) sel.value = focusSession; }
      document.getElementById("audit").classList.add("show");
      if(focusView){ auditTab(focusView); }  // auditTab also re-renders
      else { renderAudit(); }
    };
    // ---- Fleet-wide search (roadmap #3) -------------------------------------
    // 300ms debounce, min 3 chars; Lua runs rg/grep async and replies ccSearch.
    // The reply echoes the query -- stale (out-of-order) results are dropped
    // here too, belt-and-braces with the Lua generation guard.
    var fsTimer = null;
    function openFleetSearch(){
      document.getElementById("fsearch").classList.add("show");
      var inp = document.getElementById("fs-input");
      inp.focus(); inp.select();
    }
    function closeFleetSearch(){ document.getElementById("fsearch").classList.remove("show"); }
    function onFleetSearchInput(){
      if(fsTimer) clearTimeout(fsTimer);
      var q = (document.getElementById("fs-input").value || "").trim();
      var body = document.getElementById("fs-body");
      var info = document.getElementById("fs-info");
      if(q.length < 3){ info.textContent = ""; body.innerHTML = '<div class="s-help" style="margin-left:0;">Type at least 3 characters.</div>'; return; }
      info.textContent = "searching…";
      fsTimer = setTimeout(function(){ send("fleet-search", "", JSON.stringify({ q: q })); }, 300);
    }
    var FS_HITS = [];
    window.ccSearch = function(res){
      res = res || {};
      var cur = (document.getElementById("fs-input").value || "").trim();
      if(res.q !== cur) return;  // a newer query superseded this result
      FS_HITS = res.hits || [];
      document.getElementById("fs-info").textContent =
        FS_HITS.length + " hit(s)" + (res.truncated ? " (more not shown — narrow the search)" : "");
      var body = document.getElementById("fs-body");
      if(!FS_HITS.length){ body.innerHTML = '<div class="s-help" style="margin-left:0;">No matches.</div>'; return; }
      body.innerHTML = FS_HITS.map(function(h, i){
        var who = h.name ? h.name
                : (h.kind === "ledger" ? "📜 ledger"
                : (h.projectKey ? decodeProjectKey(h.projectKey) : "?"));
        var base = (h.file || "").split("/").pop();
        var click = h.key ? ' onclick="fsOpen(' + i + ')"' : (h.sessionId ? ' onclick="fsTimelineFor(' + i + ')"' : '');
        var cls = "fs-row" + ((h.key || h.sessionId) ? "" : " dead");
        return '<div class="' + cls + '"' + click + ' title="' + esc(h.file || "") + '">'
          + '<span class="fs-who">' + (h.key ? "● " : "") + esc(who) + '</span>'
          + '<span class="fs-file">' + esc(base) + ':' + (h.line || "?") + '</span>'
          + '<span class="fs-text">' + esc(h.text || "") + '</span>'
          + (h.key ? '<button class="fs-jump" onclick="event.stopPropagation();send(\'focus\',\'' + esc(h.key) + '\')" title="Jump to this session\'s window">Jump</button>' : '')
          + '</div>';
      }).join("");
    };
    // The encoded /projects/<ENC>/ segment reads roughly as the launch path with
    // separators folded to "-" -- show the last two segments as a readable hint.
    function decodeProjectKey(pk){
      var parts = (pk || "").split("-").filter(Boolean);
      return parts.length ? parts.slice(-2).join("/") : pk;
    }
    function fsOpen(i){
      var h = FS_HITS[i]; if(!h || !h.key) return;
      closeFleetSearch();
      selectTile(h.key);
    }
    function fsTimelineFor(i){
      var h = FS_HITS[i]; if(!h || !h.sessionId) return;
      closeFleetSearch();
      send("open-audit-for-session", h.sessionId);
    }

    // ---- Notification history (roadmap #6) ----------------------------------
    function openNotifications(){ send("open-notifications"); setNotifyBadge(0); }
    function setNotifyBadge(n){
      var b = document.getElementById("notify-badge"); if(!b) return;
      b.textContent = (n > 0) ? String(n > 99 ? "99+" : n) : "";
      b.style.display = (n > 0) ? "inline-block" : "none";
    }

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
    var lastSelectedStatus = null;
    window.ccUpdate = function(items, providers){
      lastItems = items || [];
      if(providers !== undefined) PANEL_PROVIDERS = providers || [];
      renderGrid();
      renderDetail();
      // Refresh the gate decision log exactly when the selected tile changes
      // status (a decision likely just landed) -- one cached-snapshot read per
      // transition, zero per tick.
      var sel = selectedKey ? findItem(selectedKey) : null;
      var st = sel ? (sel.status || "idle") : null;
      if(sel && lastSelectedStatus !== null && st !== lastSelectedStatus){ requestDecisions(selectedKey); }
      lastSelectedStatus = st;
    };

    // One tile's HTML. Extracted from ccUpdate so renderGrid can map the (filtered)
    // visible set without duplicating the markup.
    function tileHtml(it){
      var st = it.status || "idle";
      var label = LABELS[st] || st;
      // The elapsed-in-status age (2s/13s/11h) rides the status line -- right of the dot,
      // before the status words -- instead of taking its own meta row.
      var age = it.since ? fmtAge(it.since) : "";
      var meta = "";
      if(st === "approval" && it.pending && it.pending.summary){
        meta = "wants: " + it.pending.summary;
      } else if(st === "error"){
        meta = it.error_message || "API error — stopped";
      }
      if(it.remote){ meta = (meta ? meta + " · " : "") + "⇄ " + (it.remote.host || "remote")
                            + (it.bridgeStale ? " (bridge offline)" : ""); }
      if(it.queue > 0){ meta = (meta ? meta + " · " : "") + (it.routed ? "⇉" : "+") + it.queue + " queued"; }
      else if(it.routed){ meta = (meta ? meta + " · " : "") + "⇉ routed"; }
      if(it.starved){ meta = (meta ? meta + " · " : "") + "⌛ queue starved"; }
      if(it.autopilot){ meta = (meta ? meta + " · " : "") + "🛫 autopilot"; }
      if(it.draining){ meta = (meta ? meta + " · " : "") + "⛔ draining"; }
      if(it.collide){ meta = (meta ? meta + " · " : "") + "⚠ shared dir"; }
      if(it.hung){ meta = (meta ? meta + " · " : "") + "⏳ stalled"; }
      var cls = "tile s-" + st + (it.stale ? " stale" : "") + (it.collide ? " collide" : "") + (it.hung ? " hung" : "") + (it.escalate ? " escalate" : "") + (it.key === selectedKey ? " sel" : "");
      return '<div class="'+cls+'" data-key="'+esc(it.key)+'" onclick="selectTile(\''+esc(it.key)+'\')" ondblclick="send(\'focus\',\''+esc(it.key)+'\')" oncontextmenu="showCtx(event,\''+esc(it.key)+'\')" title="Double-click to jump · right-click for more">'
           + '<span class="dot"></span>'
           + '<span class="name">'+esc(it.label || it.name)+(it.group ? ' <span class="gtag">🏷 '+esc(it.group)+'</span>' : '')+'</span>'
           + '<span class="label">'+(age ? '<span class="age">'+esc(age)+'</span> ' : '')+label+'</span>'
           + riskBadge(it)
           + (meta ? '<span class="meta">'+esc(meta)+'</span>' : '')
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
-- LaunchServices LOWERCASES the URL host on delivery (field-proven: the event
-- arrives as "ccshepherdtoggle") and hs.urlevent matches case-sensitively, so
-- the lowercase bind is the one that actually fires; the camelCase bind stays
-- for any path that preserves case.
_G.__ccShepherdToggle = togglePanel
pcall(function()
  hs.urlevent.bind("ccshepherdtoggle", function() togglePanel() end)
  hs.urlevent.bind("ccShepherdToggle", function() togglePanel() end)
end)
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
  -- SSH status bridge (roadmap #7): merge each live host's mirror dir as
  -- host-namespaced tiles. NEVER pruned locally (rsync --delete is truth: a
  -- remote SessionEnd removes the mirror file; FX.removeStatus on a namespaced
  -- key would unlink a wrong local path and rsync would resurrect it anyway).
  -- bridgeStale marks "the BRIDGE isn't syncing" distinctly from session
  -- staleness (the mirror's `updated` freezes when rsync stalls).
  for ns, b in pairs(bridge) do
    local mdir = MIRROR_DIR .. "/" .. ns
    local mentries = {}
    for _, fname in ipairs(FX.readDir(mdir)) do
      local key = fname:match("^(.+)%.json$")
      if key then
        local content = FX.readFile(mdir .. "/" .. fname)
        if content and #content > 0 then mentries[#mentries + 1] = { key = key, content = content } end
      end
    end
    if #mentries > 0 then
      local slack = tonumber(core.config(loadConfig(), "bridge.staleSlackSeconds", 15)) or 15
      local remoteList = core.parseMirrorList({ ns = ns, host = b.host, dest = b.dest },
        mentries, now, STALE_SECONDS, { slack = slack })
      local syncStale = (now - (b.lastOkTs or 0)) > 3 * (b.interval or BRIDGE_SECONDS)
      for _, it in ipairs(remoteList) do it.bridgeStale = syncStale or nil end
      list = core.mergeStatusLists(list, remoteList)
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

-- Ledger snapshot, cached across refreshes: refresh() runs at 1 Hz
-- (timer + pathwatcher), and re-reading + re-JSON-parsing the whole ledger
-- directory every tick burns the Hammerspoon main thread. Re-read only when a
-- daily file's size/mtime changes (cheap hs.fs.attributes scan; hooks append
-- out-of-process) or the 30s TTL backstop expires (core.ledgerCacheStale).
-- Shared by risk scoring, the gate decision log, and the notification badge.
-- Returns events, changed -- `changed` is true only when this call re-read the
-- files, so per-tick consumers (the 🔔 badge) can skip recompute on cache hits.
local ledgerSnapshotCache = {}
function ledgerSnapshot()  -- assigns the forward-declared local (same as loadConfig)
  local parts = {}
  for _, fn in ipairs(FX.readDir(LEDGER_DIR)) do
    if fn:match("%.jsonl$") then
      local a = hs.fs.attributes(LEDGER_DIR .. "/" .. fn)
      parts[#parts + 1] = fn .. ":" .. tostring(a and a.size or "?")
        .. ":" .. tostring(a and a.modification or "?")
    end
  end
  table.sort(parts)  -- readDir order isn't guaranteed; the signature must be stable
  local sig = table.concat(parts, ";")
  local now = FX.now()
  local changed = false
  if core.ledgerCacheStale(ledgerSnapshotCache, sig, now, 30) then
    ledgerSnapshotCache = { events = FX.readLedger({}).events, sig = sig, ts = now }
    changed = true
  end
  return ledgerSnapshotCache.events, changed
end

-- Push current statuses into the webview + deck; run queue auto-feed and
-- stale-approval escalation; keep the heartbeat fresh.
function refresh()
  local cfg = loadConfig()
  reconcileBridge(cfg)  -- SSH bridge timers track config (cheap diff per tick)
  local list = refreshList()
  local autofeed   = core.config(cfg, "queue.autofeed", false) == true
  local queueDry   = core.config(cfg, "queue.dryRun", false) == true
  local routingOn  = core.config(cfg, "queue.routing.enabled", false) == true  -- 4c-E
  local starveMin  = tonumber(core.config(cfg, "queue.routing.starveMinutes", 0)) or 0
  local routeGroups = {}  -- queueKey -> { items }: members per project, for the dispatcher
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
  -- The respawn death threshold is deliberately MUCH larger than the 90s display
  -- staleness: no hook fires mid-tool-call, so a healthy session running one long
  -- build/test (Bash tool timeout: default 120s, max 600s) freezes its status file
  -- at `working` for minutes. Default 600s sits above that ceiling.
  local autoRespawnStale = tonumber(core.config(cfg, "respawn.auto.staleSeconds", 600)) or 600
  -- Auto-Continue (opt-in): resume a tile frozen on an API error by typing "continue" after a
  -- grace delay, capped per folder so a persistently dead connection can't loop. Off by default.
  local autoContinueOn    = core.config(cfg, "autoContinue.enabled", false) == true
  local autoContinueDelay = tonumber(core.config(cfg, "autoContinue.delaySeconds", 60)) or 60
  local autoContinueMax   = tonumber(core.config(cfg, "autoContinue.maxAttempts", 3)) or 3
  local collEnabled = core.config(cfg, "collision.enabled", false) == true
  local collGitRoot = core.config(cfg, "collision.useGitRoot", false) == true
  local riskEnabled = core.config(cfg, "risk.enabled", false) == true
  local riskOpts = riskEnabled and {
    weights    = core.config(cfg, "risk.weights", nil),
    thresholds = core.config(cfg, "risk.thresholds", nil),
  } or nil
  -- Risk scoring + the 🔔 badge share ONE cached ledger snapshot per tick (not
  -- per tile, and not a full re-parse -- see ledgerSnapshot above). A single
  -- call also keeps the `changed` edge intact: a second call in the same tick
  -- would always see the freshly-warmed cache and report false.
  local ledgerOn = ledgerEnabled()
  local ledgerEvents, ledgerChanged = nil, false
  if riskEnabled or ledgerOn then ledgerEvents, ledgerChanged = ledgerSnapshot() end
  local now = FX.now()
  local newPrev = {}  -- key -> { status, stale, escalated }: rebuilt this refresh, swapped in below
                      -- (.stale = frozen past the RESPAWN threshold, not display staleness)

  -- Collision detection (Feature B): flag tiles where 2+ active sessions share a
  -- working dir / git-root. Computed once over the whole list before the tile loop.
  local collFlags = {}
  if collEnabled then
    -- Remote (bridge) tiles are excluded: their cwd is a REMOTE path -- a
    -- same-layout local clone would read as a false collision, and FX.gitRoot
    -- would run git against whatever happens to exist locally at that path.
    local localList = {}
    for _, it in ipairs(list) do
      if not it.remote then localList[#localList + 1] = it end
    end
    local rootByCwd = nil
    if collGitRoot then
      rootByCwd = {}
      for _, it in ipairs(localList) do
        if it.cwd and it.cwd ~= "" and rootByCwd[it.cwd] == nil then
          rootByCwd[it.cwd] = FX.gitRoot(it.cwd) or ""
        end
      end
    end
    collFlags = core.collisions(localList, { rootByCwd = rootByCwd }).flags
  end

  for _, it in ipairs(list) do
    local pv = prev[it.key]  -- last refresh's snapshot for this tile (status/stale/escalated), or nil
    -- Live activity peek (non-stale sessions). Include `done` so the peek refreshes
    -- to the FINAL assistant line when a session finishes (a done transcript doesn't
    -- change, so the re-read is stable) instead of freezing mid-turn.
    -- The same tail feeds error detection below, so read it once for any `working`
    -- session (even stale -- a frozen-on-error session goes stale but must still flag)
    -- plus the non-stale peek statuses.
    -- Remote (bridge) tiles: transcript_path is a REMOTE path -- a same-layout
    -- local clone could make it exist HERE too, so never read it (peek/error/
    -- watchdog all skip). Approve/Deny route over ssh; escalation stays on
    -- (pure timestamp math -- nagging about a remote approval is the point).
    local peekable = ACTIVITY_PEEK and not it.stale and not it.remote
       and (it.status == "working" or it.status == "approval" or it.status == "done")
    local wantTail = it.transcript_path and not it.remote and (peekable or it.status == "working")
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
    if hungOn and it.transcript_path and not it.stale and not it.remote and it.status == "working" then
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
      -- Serialized (R3 #2): two drains firing in the same refresh tick would
      -- otherwise both schedule ⌘⇧W chords against the LAST-focused window.
      dispatchSerialized(it, "close", function() core.handleAction(FX, it, "close") end)
      drained = true
    end
    -- Drain badge: surface the armed in-memory intent on the tile. Set AFTER the
    -- shouldDrainClose block (which clears the flag when it fires) so a tile whose
    -- drain just fired doesn't render a stale badge on its final frame.
    it.draining = core.drainingBadge(drainOn, draining[it.key] ~= nil)

    -- Task queue: depth badge + auto-feed on a fresh done transition. Stale tiles
    -- are never fed (same invariant as selectActionable: a dead window can't act --
    -- the paste would land in whatever window the editor happens to focus).
    -- Queues are PROJECT-keyed (FX.queueKeyFor) so a respawned or /clear'd session
    -- inherits its project's pending tasks instead of stranding them on disk.
    local qk = FX.queueKeyFor(it)
    local q = FX.readQueue(qk)
    it.queue = core.queueDepth(q)
    -- 4c-E routing bookkeeping: retire a satisfied/expired in-flight marker,
    -- collect project membership for the post-loop dispatcher, and badge armed
    -- projects. An ARMED project skips the per-tile 4b autofeed below -- the
    -- single dispatcher owns its feeds (otherwise the finisher's edge-feed and
    -- the router could both fire in one tick).
    if core.routePendingDone(routePending[it.key], it.status, now, core.ROUTE_PENDING_TIMEOUT) then
      routePending[it.key] = nil
    end
    it.routed = core.queueRouted(q) or nil  -- armed flag (file truth; toggle state)
    local routedHere = routingOn and it.routed or false
    if routingOn then
      routeGroups[qk] = routeGroups[qk] or {}
      table.insert(routeGroups[qk], it)
    end
    if not drained and not it.stale and not it.remote and not routedHere
       and core.shouldFeed(pv and pv.status, it.status, q, autofeed) then
      if queueDry then
        local task = core.queuePop(q)
        print("[cc-queue] DRY-RUN would feed '" .. tostring(task) .. "' to " .. it.name)
      else
        -- Serialized on the shared injection tail (R3 #2): the paste is a
        -- multi-second keystroke ladder, and refresh() firing it mid-chain
        -- would land the task text in whichever session holds focus. The pop
        -- runs INSIDE the slot -- the queue is re-read at dispatch time (a
        -- manual feed may have consumed the head while this slot waited) --
        -- and only a DELIVERED paste pops the queue (FX.feedTask returns false
        -- when the no-window-match guard skipped it).
        dispatchSerialized(it, "queue-feed", function()
          local task, q2 = core.queuePop(FX.readQueue(qk))
          if not task then return end
          print("[cc-queue] feeding '" .. tostring(task) .. "' to " .. it.name)
          local commit = core.queueFeedCommit(FX.feedTask(winTarget(it), task))
          if commit.persist then
            FX.writeQueue(qk, q2)
            it.queue = core.queueDepth(q2)
          else
            print("[cc-queue] feed skipped (no window match) -- task kept queued")
          end
          ledgerFor(it, { type = commit.event, task = tostring(task):sub(1, 200), by = "autofeed" })
        end)
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
        -- One ledger event per escalation episode -> feeds the 🔔 notification
        -- history ("what fired while you were away"). No-op when the ledger is off.
        ledgerFor(it, { type = "escalation", minutes = escMin,
          summary = (it.pending and it.pending.summary) or nil })
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
        -- One ledger event per stall episode (🔔 notification history).
        ledgerFor(it, { type = "hung", minutes = hungMin })
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
    -- the bookkeeping (per-folder budget: reset after SUSTAINED health, increment when
    -- firing; the projectKey is folded into the gate so a keyless tile can't nil-key
    -- write). Compute respawnSpec first so cc-core can charge the budget ONLY on a real
    -- relaunch (an un-respawnable death shouldn't burn a retry). respawnSpec is pure
    -- and cheap, and only computed while the feature is on.
    local rs = (autoRespawnOn and not it.remote) and core.respawnSpec(it, cfg) or nil
    local step = core.stepAutoRespawn(respawnAttempts, it, {
      -- never auto-relaunch a session frozen on an API error: the user resumes it with
      -- Continue (same session/context), not a fresh respawn. Remote tiles are
      -- never respawned (the relaunch would target a LOCAL editor window).
      enabled = autoRespawnOn and it.status ~= "error" and not it.remote, maxRetries = autoRespawnMax,
      intentional = (draining[it.key] ~= nil) or drained,
      -- nil pv = NO prior observation (first refresh after a reload, prev is in-memory):
      -- treat it as already-frozen so a reload can't mass-fire a "fresh" edge for every
      -- currently-frozen tile -- edges require a real prior observation.
      wasStale = (pv == nil) or (pv.stale == true),
      now = now, staleSeconds = STALE_SECONDS,  -- for the sustained-health budget reset
      respawnStaleSeconds = autoRespawnStale,   -- the (much larger) death threshold
      -- strict boolean (fail-closed): a nil/absent canRespawn must NOT read as
      -- "respawnable" via stepAutoRespawn's permissive `~= false` default.
      canRespawn = rs ~= nil and rs.canRespawn == true })
    if step.spawn then  -- rs.canRespawn was true (the increment is gated on it)
      print("[cc-respawn] auto-relaunch " .. tostring(it.name)
        .. " (attempt " .. tostring(step.attempts) .. "/" .. autoRespawnMax .. ")")
      ledgerFor(it, { type = "auto_respawn", cwd = rs.project, editor = rs.editor,
        provider = rs.providerId, attempt = step.attempts })
      -- rs.providerId=nil = faithful bare claude: "" (explicit none) so the relaunch
      -- can't silently pick up the spawn.provider default gateway.
      FX.spawnSession(rs.editor, rs.project, nil, rs.permissionMode, rs.providerId or "")
      FX.removeStatus(it.key)  -- drop the dead tile; the relaunch makes a fresh one
    elseif step.wouldFire and rs and not rs.canRespawn then
      print("[cc-respawn] " .. tostring(it.name) .. " died but isn't respawnable: " .. tostring(rs.reason))
    end

    -- Auto-Continue (opt-in): a tile frozen on an API error (status=="error") is resumed by
    -- typing "continue" after a grace delay, capped per folder. cc-core owns the timing/budget
    -- (since/attempts maps); the keystroke goes through the SAME serialized chokepoint the manual
    -- Continue button uses. Remote tiles are excluded (the keystroke targets a LOCAL window).
    local cstep = core.stepAutoContinue(autoContinueState, it,
      { enabled = autoContinueOn and not it.remote, now = now,
        minSeconds = autoContinueDelay, maxAttempts = autoContinueMax })
    if cstep.fire then
      print("[cc-continue] auto-continue " .. tostring(it.name)
        .. " (attempt " .. tostring(cstep.attempts) .. "/" .. autoContinueMax .. ")")
      ledgerFor(it, { type = "auto_continue", attempt = cstep.attempts })
      dispatchSerialized(it, "continue", function() core.handleAction(FX, it, "continue") end)
    end

    newPrev[it.key] = { status = it.status, stale = step.isStale, escalated = nowEsc }
  end
  prev = newPrev

  -- 4c-E project routing dispatcher: ONE feed per armed project per tick, to
  -- whichever member is free (done, not stale/error/draining/pending). Runs
  -- AFTER the tile loop so it sees every member's final status this tick --
  -- two sessions finishing simultaneously yield exactly one deterministic
  -- pick. The pop stays inside the dispatchSerialized slot and delivery-gated
  -- (same contract as 4b); a skipped paste clears the pending marker so the
  -- session stays eligible.
  if routingOn then
    for qk, members in pairs(routeGroups) do
      local q = FX.readQueue(qk)
      local pick = core.routeTask(members, q, { globalOn = true, draining = draining,
        pending = routePending, now = now, pendingTimeout = core.ROUTE_PENDING_TIMEOUT })
      if pick then
        starvedSince[qk] = nil; starvedAlerted[qk] = nil
        local item
        for _, m in ipairs(members) do if m.key == pick.key then item = m; break end end
        if item then
          if queueDry then
            local task = core.queuePop(q)
            print("[cc-route] DRY-RUN would feed '" .. tostring(task) .. "' to " .. tostring(item.name))
          else
            routePending[item.key] = now
            dispatchSerialized(item, "queue-feed", function()
              local task, q2 = core.queuePop(FX.readQueue(qk))
              if not task then routePending[item.key] = nil; return end
              print("[cc-route] feeding '" .. tostring(task) .. "' to " .. tostring(item.name))
              local commit = core.queueFeedCommit(FX.feedTask(winTarget(item), task))
              if commit.persist then
                FX.writeQueue(qk, q2)
              else
                print("[cc-route] feed skipped (no window match) -- task kept queued")
                routePending[item.key] = nil  -- session stays eligible
              end
              ledgerFor(item, { type = commit.event, task = tostring(task):sub(1, 200), by = "router" })
            end)
          end
        end
      elseif core.queueRouted(q) and core.queueDepth(q) > 0 then
        -- Armed + work queued + nobody free: starvation clock. One ledger event
        -- + tile tint per episode when queue.routing.starveMinutes > 0.
        starvedSince[qk] = starvedSince[qk] or now
        if core.queueStarved(members, q, { minutes = starveMin, sinceTs = starvedSince[qk],
             now = now, draining = draining, pending = routePending }) then
          for _, m in ipairs(members) do m.starved = true end
          if not starvedAlerted[qk] then
            starvedAlerted[qk] = true
            print("[cc-route] " .. qk .. " starved: " .. core.queueDepth(q)
              .. " task(s) queued, no free session for " .. starveMin .. "m+")
            ledgerFor(members[1], { type = "queue_starved", depth = core.queueDepth(q) })
          end
        end
      else
        starvedSince[qk] = nil; starvedAlerted[qk] = nil
      end
    end
  end

  -- Errored tiles were detected mid-loop (status overridden to "error"); re-sort so they
  -- surface near approvals -- parseStatusList sorted before we'd read any transcript.
  core.sortByStatus(list)

  -- 🔔 unseen-notification badge. The snapshot scan is the same cheap attributes
  -- pass risk scoring pays; the filter only reruns when the snapshot actually
  -- re-read (changed) or the badge was never pushed, and JS is only poked when
  -- the count moved.
  if ledgerOn then
    if ledgerChanged or lastNotifyCount < 0 then
      local days = tonumber(core.config(cfg, "notifications.days", 7)) or 7
      local lastSeen = tonumber(hs.settings.get("ccNotifySeen")) or 0
      local n = core.unseenNotificationCount(
        core.notificationEvents(ledgerEvents, { sinceTs = now - days * 86400 }), lastSeen)
      if n ~= lastNotifyCount then
        lastNotifyCount = n
        pcall(function() wv:evaluateJavaScript("setNotifyBadge(" .. tostring(n) .. ")") end)
      end
    end
  elseif lastNotifyCount ~= 0 then
    lastNotifyCount = 0
    pcall(function() wv:evaluateJavaScript("setNotifyBadge(0)") end)
  end

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
      -- approve-front sends a window keystroke -> serialized (R3 #2/#5).
      dispatchSerialized(it, action, function() core.handleAction(FX, it, action) end)
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

-- Poll on a timer, and also react instantly to file changes. The watcher must
-- ignore the panel's OWN heartbeat (refresh writes .panel-alive into this dir
-- every tick) or each refresh would trigger the next one forever (pure check
-- in cc-core; the heartbeat can't move out of STATUS_DIR -- cc-approve reads it
-- there).
M.timer = hs.timer.doEvery(POLL_SECONDS, refresh)
M.watcher = hs.pathwatcher.new(STATUS_DIR, function(paths)
  if core.watcherShouldRefresh(paths) then refresh() end
end):start()
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

-- Auto-enable Claude Code Remote Control on already-running sessions (user request): on
-- startup, type `/rc` into each quiescent LOCAL session so a computer restart re-arms RC
-- across the whole fleet with no manual step. New Shepherd spawns get RC via the
-- --remote-control launch flag instead (see FX.spawnSession); this sweep covers sessions
-- started outside Shepherd or before it booted. cc-core picks the safe targets (idle/done,
-- never mid-turn / mid-approval); the keystroke rides the serialized chokepoint, and /rc is
-- idempotent. Delayed so the first refresh() has populated the tile map. Off via
-- remoteControl.sweepOnStartup.
do
  local cfg = loadConfig()
  if core.config(cfg, "remoteControl.sweepOnStartup", true) == true then
    after(2.5, function()
      local list = {}
      for _, it in pairs(byKey) do list[#list + 1] = it end
      local targets = core.remoteControlSweepTargets(list)
      if #targets > 0 then
        print("[cc-rc] startup sweep: /rc -> " .. #targets .. " running session(s)")
        for _, it in ipairs(targets) do
          dispatchSerialized(it, "rc", function() FX.typeIntoWindow(winTarget(it), "/rc") end)
        end
      end
    end)
  end
end

-- Keep references alive so Lua does not garbage-collect them.
_G.__ccDashboard = { webview = wv, controller = controller, module = M, core = core, fx = FX, toggle = togglePanel }
print("[cc-dashboard] loaded; watching " .. STATUS_DIR)

return M
