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
local AUTOTITLE_FILE = os.getenv("CC_AUTOTITLE_FILE") or (os.getenv("HOME") .. "/.claude/cc-autotitles.json")
local RULES_FILE    = os.getenv("CC_RULES_FILE") or (os.getenv("HOME") .. "/.claude/cc-rules.json")
local SCHEDULES_FILE = os.getenv("CC_SCHEDULES_FILE") or (os.getenv("HOME") .. "/.claude/cc-schedules.json")
local GROUPS_FILE   = os.getenv("CC_GROUPS_FILE") or (os.getenv("HOME") .. "/.claude/cc-groups.json")
local RECENT_FILE   = os.getenv("CC_RECENT_FILE") or (os.getenv("HOME") .. "/.claude/cc-recent-dirs.json")
local TEMPLATE_FILE = os.getenv("CC_TEMPLATE_FILE") or (os.getenv("HOME") .. "/.claude/cc-templates.json")
local PRESET_FILE   = os.getenv("CC_PRESET_FILE") or (os.getenv("HOME") .. "/.claude/cc-presets.json")
local AGENT_FILE    = os.getenv("CC_AGENT_FILE") or (os.getenv("HOME") .. "/.claude/cc-agents.json")
local MCP_FILE      = os.getenv("CC_MCP_FILE") or (os.getenv("HOME") .. "/.claude/cc-mcp.json")
local MCP_CONFIG_DIR = os.getenv("CC_MCP_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude/cc-mcp-configs")
local SKILLS_DIR    = os.getenv("CC_SKILLS_DIR") or (os.getenv("HOME") .. "/.claude/skills")
-- L3 definition source: a local dir of *.prompt / *.md prompt definitions imported
-- into cc-templates.json (config `templates.sourceDir` overrides; strictly local).
local PROMPTS_DIR   = os.getenv("CC_PROMPTS_DIR") or (os.getenv("HOME") .. "/.claude/cc-prompts")
-- L2 named policy bundles: POLICY_DIR holds the resolved per-session policy the
-- gate reads (MUST match cc-approve.sh's CC_POLICY_DIR default); POLICY_OVERRIDE_DIR
-- holds each session's chosen bundle name (the detail-panel Policy dropdown).
local POLICY_DIR    = os.getenv("CC_POLICY_DIR") or (os.getenv("HOME") .. "/.claude/cc-policy")
local POLICY_OVERRIDE_DIR = os.getenv("CC_POLICY_OVERRIDE_DIR") or (os.getenv("HOME") .. "/.claude/cc-policy-override")
-- Change-gate for the per-session resolved-policy file writes (avoid 1s churn):
-- key -> last-written JSON. Cleared when a session resolves back to the fleet.
local policyCache = {}
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
local HOTKEY_JUMP_NEEDY    = { { "cmd", "alt" }, "j" } -- jump to the session that most needs you (approval > error > hung), from any app
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
local autoTitles = {}    -- projectKey -> derived tile title (L5; cached once per project)
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
local lastLedgerOn = nil    -- last ledger-on state pushed to JS (gates the 📋 Shift UI)
local PANEL_START_TS = nil  -- when this panel process started (set at show); the
                            -- 📋 Shift report's "since opened" window anchors here.
local lineageMap = {}       -- projectKey -> lineage (respawn/clear churn since local
local lineageDayStart = nil -- midnight); recomputed only on ledger change / day roll.
local lastRenderList = nil  -- the last fully-annotated+sorted tick list (error status,
                            -- .hung, .escalate). The ⌘⌥J jump hotkey reads THIS, not a
                            -- fresh refreshList(): error/hung are derived in the render
                            -- loop, so a re-parse would only ever see approvals.
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
local taskStart     = {} -- tile key -> { ts, role, projectKey, by }: a fed queue task in
                         -- flight (L4 per-task timing); consumed on the next done edge
local loopAlerted   = {} -- tile key -> true once a loop ledger event fired this episode (L5)
local ruleFired     = {} -- "ruleName\1tileKey" -> true: a `once` L6 rule already fired for this tile
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
-- L5 auto-titles: projectKey -> derived tile title (cc-autotitles.json). Computed
-- once per project (from its first prompt) and cached so the title is stable.
function FX.loadAutoTitles()
  local c = FX.readFile(AUTOTITLE_FILE)
  if not c or #c == 0 then return {} end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or {}
end
function FX.saveAutoTitles(map)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(AUTOTITLE_FILE, core.json.encode(map or {}))
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
-- L6 event-callback rules (cc-rules.json). Missing/garbled -> empty.
function FX.readRules()
  local c = FX.readFile(RULES_FILE)
  if not c or #c == 0 then return { rules = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { rules = {} }
end
-- L6 rules editor writes cc-rules.json (the engine read it before; now it's editable).
function FX.writeRules(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(RULES_FILE, core.json.encode(state or { rules = {} }))
end
-- L7 scheduled routines (cc-schedules.json). Missing/garbled -> empty.
function FX.readSchedules()
  local c = FX.readFile(SCHEDULES_FILE)
  if not c or #c == 0 then return { schedules = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { schedules = {} }
end
function FX.writeSchedules(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(SCHEDULES_FILE, core.json.encode(state or { schedules = {} }))
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

-- L1 Agent Profiles registry (cc-agents.json) + MCP registry (cc-mcp.json).
-- Operator data, same posture as presets/templates. Missing/garbled -> empty.
function FX.readAgents()
  local c = FX.readFile(AGENT_FILE)
  if not c or #c == 0 then return { agents = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { agents = {} }
end
function FX.writeAgents(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(AGENT_FILE, core.json.encode(state or { agents = {} }))
end
function FX.readMcp()
  local c = FX.readFile(MCP_FILE)
  if not c or #c == 0 then return { servers = {} } end
  local ok, t = pcall(function() return core.json.decode(c) end)
  return (ok and type(t) == "table") and t or { servers = {} }
end
function FX.writeMcp(state)
  hs.fs.mkdir(CLAUDE_DIR)
  FX.writeFile(MCP_FILE, core.json.encode(state or { servers = {} }))
end

-- Enumerate ~/.claude/skills (dual-shape: directory SKILL.md AND flat *.md) into
-- read-only cards { name, display_title, description, command, shape, path }.
-- Parsing is pure (core.parseSkillFrontmatter); native Claude Code owns auto-load.
function FX.listSkills()
  local out, seen = {}, {}
  local function add(path, stem, shape)
    local txt = FX.readFile(path)
    if not txt then return end
    local card = core.parseSkillFrontmatter(txt, stem)
    if card.name == "" or seen[card.name] then return end
    seen[card.name] = true
    out[#out + 1] = { name = card.name, display_title = card.display_title,
                      description = card.description, command = core.skillCommand(card.name),
                      shape = shape, path = path }
  end
  for _, name in ipairs(FX.readDir(SKILLS_DIR)) do
    if name ~= "." and name ~= ".." then
      local p = SKILLS_DIR .. "/" .. name
      local mode = hs.fs.attributes(p, "mode")
      if mode == "directory" then
        local sk = p .. "/SKILL.md"
        if hs.fs.attributes(sk) then add(sk, name, "agentskills") end
      elseif name:match("%.md$") and name:lower() ~= "readme.md" then
        add(p, (name:gsub("%.md$", "")), "flat")
      end
    end
  end
  table.sort(out, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
  return out
end

-- L3 definition source: enumerate prompt-definition files (*.prompt / *.md, skip
-- README) in `dir` -> { {stem, text}, ... }. Synchronous readDir+readFile (a flat,
-- bounded dir, like FX.listSkills -- not the async folder-scan). Missing dir -> {}.
function FX.listPromptFiles(dir)
  local out = {}
  for _, name in ipairs(FX.readDir(dir)) do
    if name ~= "." and name ~= ".." and (name:match("%.prompt$") or name:match("%.md$"))
       and name:lower() ~= "readme.md" then
      local txt = FX.readFile(dir .. "/" .. name)
      if txt then
        out[#out + 1] = { stem = (name:gsub("%.prompt$", ""):gsub("%.md$", "")), text = txt }
      end
    end
  end
  return out
end

-- Write a resolved agent's --mcp-config JSON to a per-agent file; returns the path.
function FX.writeMcpConfig(agentName, cfgTable)
  hs.fs.mkdir(MCP_CONFIG_DIR)
  local safe = tostring(agentName or "agent"):gsub("[^%w%-_.]", "_")
  local path = MCP_CONFIG_DIR .. "/" .. safe .. ".json"
  FX.writeFile(path, core.json.encode(cfgTable or { mcpServers = {} }))
  return path
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
local folderScanTimer = nil  -- retained timeout backstop for a wedged scan (GC-safe)
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
  local argv, usedFd
  if hs.fs.attributes(fd) then argv = core.folderScanArgv(fd, expanded, depth); usedFd = true
  else argv = core.folderScanFallbackArgv(expanded, depth); usedFd = false end
  -- Make the accelerator visible: which engine actually ran (fd when installed, find else).
  local engine = usedFd and ("fd " .. fd) or "find  (install fd for faster, gitignore-aware scans)"
  -- Run the scanner via /bin/sh with stdout REDIRECTED to a temp file, then read the file on
  -- exit. Direct-exec hs.task DEADLOCKS once a scan's stdout exceeds the OS pipe buffer (~64KB)
  -- over a large tree (the task waits for exit while the child blocks on a full pipe) -- a file
  -- keeps the task's pipe empty. core.folderScanShellCommand single-quotes argv + outFile.
  local outFile = os.tmpname()
  local cmd = core.folderScanShellCommand(argv, outFile)
  local ok = pcall(function()
    folderScanTask = hs.task.new("/bin/sh", function()
      if folderScanTimer then pcall(function() folderScanTimer:stop() end); folderScanTimer = nil end
      folderScanTask = nil
      local out = FX.readFile(outFile) or ""
      pcall(os.remove, outFile)
      folderIndex = { paths = core.parseDirList(out), ts = hs.timer.secondsSinceEpoch() }
      print("[cc-spawn] folder scan: " .. engine .. " -> " .. #folderIndex.paths .. " dir(s)")
    end, { "-c", cmd })
    if not folderScanTask then error("task create failed") end
    folderScanTask:start()
    -- Backstop: a wedged scan (a stuck mount, a hung fs) must never pin the slot forever.
    -- Retain the timer in a module global so GC can't eat it before it fires (the after()
    -- lesson). 15s << the 60s scan cache, so it can never collide with a later scan.
    folderScanTimer = hs.timer.doAfter(15, function()
      folderScanTimer = nil
      if folderScanTask then
        pcall(function() folderScanTask:terminate() end)
        folderScanTask = nil
        pcall(os.remove, outFile)
        print("[cc-spawn] folder scan timed out (15s) — index left as-is")
      end
    end)
  end)
  if not ok then folderScanTask = nil; pcall(os.remove, outFile) end
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

-- L2 named policy bundles. The override file = the session's chosen bundle name
-- (detail-panel Policy dropdown); the resolved file = core.resolvePolicy output
-- the gate (cc-approve.sh) reads. KEEP IN SYNC: cc-approve.sh reads POLICY_DIR/<key>.
function FX.policyOverride(key) return FX.readFile(POLICY_OVERRIDE_DIR .. "/" .. key) end
function FX.setPolicyOverride(key, name)
  hs.fs.mkdir(POLICY_OVERRIDE_DIR)
  FX.writeFile(POLICY_OVERRIDE_DIR .. "/" .. key, name)
end
function FX.clearPolicyOverride(key) os.remove(POLICY_OVERRIDE_DIR .. "/" .. key) end
function FX.writeResolvedPolicy(key, str)
  hs.fs.mkdir(POLICY_DIR)
  -- Atomic (temp + rename) like FX.patchStatus/writeDecision: cc-approve.sh reads
  -- this file on the gated hot path, so a torn truncate-then-write could briefly
  -- drop the bundle's deny rules. os.rename is atomic on the same filesystem.
  local path = POLICY_DIR .. "/" .. key
  local tmp = path .. ".tmp." .. tostring(FX.now())
  local f = io.open(tmp, "w")
  if f then f:write(str); f:close(); os.rename(tmp, path) end
end
function FX.clearResolvedPolicy(key) os.remove(POLICY_DIR .. "/" .. key) end

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
-- L5 OS-native banner (hs.notify). Click jumps to the session (best-effort focus via
-- focusProject). Local-only, no network; off by default (gated by the caller).
function FX.notify(title, text, opts)
  opts = opts or {}
  pcall(function()
    local n = hs.notify.new(function()
      local it = opts.key and byKey[opts.key]
      if it then pcall(function() focusProject(it.name, it.cwd, it.editor, true) end) end
    end, { title = tostring(title or "Claude Shepherd"), informativeText = tostring(text or ""),
           withdrawAfter = 0 })
    n:send()
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
function FX.spawnSession(editor, project, task, permissionMode, providerId, agentOpts)
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
  -- L1 "spawn from a saved agent": profile-derived launch flags (persona, MCP
  -- config, --agent, --add-dir knowledge, --plugin-dir). Absent -> byte-identical.
  if type(agentOpts) == "table" then
    opts.appendSystemPrompt = agentOpts.appendSystemPrompt
    opts.mcpConfigPath = agentOpts.mcpConfigPath
    opts.strictMcp = agentOpts.strictMcp == true
    opts.agentName = agentOpts.agentName
    opts.addDirs = agentOpts.addDirs
    opts.pluginDirs = agentOpts.pluginDirs
  end
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

-- Enriched template list for the panel: each {name, body, vars[], version,
-- versionCount}. Surfaces any dropped (corrupt/hand-edited) records to the console
-- so a save/delete can't silently reap them (mirrors the L1 agent-load posture).
-- Shared by the nudge "Tpl ▾" menu reply and the New-Session modal picker.
local function enrichedTemplates()
  local loaded = core.templateLoad(FX.readTemplates())
  if #loaded.errors > 0 then
    local names = {}
    for _, e in ipairs(loaded.errors) do names[#names + 1] = e.name end
    print("[cc-tpl] dropped " .. #loaded.errors .. " invalid template(s): " .. table.concat(names, ", "))
  end
  local out = {}
  for _, r in ipairs(loaded.valid) do
    out[#out + 1] = { name = r.name, body = core.composeTemplate(r) or "",
      vars = core.effectiveVars(r), version = r.version or 1,
      versionCount = (r.versions and #r.versions) or 0 }
  end
  return out
end

-- Richer reply for the Templates EDITOR (L3 deferred-polish): the structured
-- fields (description / expected_output / legacy text) the inline Tpl menu hides,
-- plus the composed body + detected vars + version count. A superset of
-- enrichedTemplates (which sends only the composed body for the insert menu).
local function editorTemplates()
  local out = {}
  for _, r in ipairs(core.templateList(FX.readTemplates())) do
    out[#out + 1] = { name = r.name, description = r.description or "",
      expected_output = r.expected_output or "", text = r.text or "",
      body = core.composeTemplate(r) or "", vars = core.effectiveVars(r),
      version = r.version or 1, versionCount = (r.versions and #r.versions) or 0 }
  end
  return out
end

-- L3: render a queued task just before it's typed in. Fills {{prev_output}} (the
-- target's latest output, which on the feed's done edge IS the turn that just
-- finished) + the date built-ins; user {{vars}} that can't be auto-resolved
-- without a human are left VERBATIM (keepMissing), and a task with NO placeholders
-- is returned unchanged -- so existing non-template queues are byte-unaffected.
-- The raw queued task is still what gets popped/persisted/ledgered; only the typed
-- text is rendered.
local function renderFeed(task, item)
  -- strip the L4 routing scaffolding so the session never sees it: a leading
  -- @all:/@any: join barrier, then an @role: prefix (the dispatcher already used
  -- them to gate + choose the target). Only the bare text is typed.
  local _, afterBarrier = core.taskBarrier(tostring(task or ""))
  local _, bare = core.taskRoute(afterBarrier)
  local prevOut = (item and type(item.activity) == "string") and item.activity or ""
  local r = core.renderTemplate(bare, {},
    { now = os.time(), prevOutput = prevOut, keepMissing = true })
  return r or bare
end

-- L4 per-task timing: record when a queue task was fed to a session (its role +
-- source), so the next done edge can ledger a task_done with the duration.
local function stampTaskStart(item, task, by)
  if not (item and item.key) then return end
  local _, afterB = core.taskBarrier(tostring(task or ""))
  taskStart[item.key] = { ts = os.time(), role = select(1, core.taskRoute(afterB)),
                          projectKey = item.projectKey, by = by }
end

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
  -- L5 hooks inspector: read ~/.claude/settings.json, flatten its hooks into a
  -- read-only inventory + a gate-timeout check, and render into the ⚙ Hooks section.
  if a == "inspect-hooks" then
    local path = (os.getenv("HOME") or "") .. "/.claude/settings.json"
    local sraw = FX.readFile(path)
    local settings = {}
    if sraw and #sraw > 0 then
      local ok, parsed = pcall(function() return hs.json.decode(sraw) end)
      if ok and type(parsed) == "table" then settings = parsed end
    end
    local inv = core.parseHookInventory(settings)
    local gate = core.gateHookTimeoutOk(inv, 130)
    pcall(function() wv:evaluateJavaScript("ccHooks("
      .. ((#inv > 0) and hs.json.encode(inv) or "[]") .. ", "
      .. hs.json.encode(gate) .. ", " .. jsString(path) .. ")") end)
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
    local agentState = { agents = core.agentList(FX.readAgents()),
                         mcp = core.mcpList(FX.readMcp()), skills = FX.listSkills() }
    local tpls = enrichedTemplates()
    local tplJson = (#tpls > 0) and hs.json.encode(tpls) or "[]"
    FX.scanFolders()
    pcall(function()
      wv:evaluateJavaScript("showNew(" .. hs.json.encode(cfg) .. ", "
        .. hs.json.encode(recent.dirs) .. ", " .. hs.json.encode(browse) .. ", "
        .. hs.json.encode({ presets = core.presetList(pstate),
                            lastByProject = pstate.lastByProject or {} }) .. ", "
        .. hs.json.encode(agentState) .. ", " .. tplJson .. ")")
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
  -- L1 Agent Profiles: save / delete / fork; reply with the fresh list.
  if a == "agent-save" or a == "agent-delete" or a == "agent-fork" then
    if a == "agent-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local st, saved, errs = core.agentPush(FX.readAgents(), (okp and type(p) == "table") and p or {})
      if saved then FX.writeAgents(st)
      else pcall(function() hs.alert.show("Claude Shepherd: agent invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "agent-fork" then
      local st, ok = core.agentFork(FX.readAgents(), tostring(payload.v or ""))
      if ok then FX.writeAgents(st) end
    else
      FX.writeAgents(core.agentRemove(FX.readAgents(), tostring(payload.v or "")))
    end
    local list = core.agentList(FX.readAgents())
    pcall(function() wv:evaluateJavaScript("ccAgents("
      .. ((#list > 0) and hs.json.encode(list) or "[]") .. ")") end)
    return
  end
  -- L1 MCP registry: save / delete; reply with the fresh list.
  if a == "mcp-save" or a == "mcp-delete" then
    if a == "mcp-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local st, saved, errs = core.mcpPush(FX.readMcp(), (okp and type(p) == "table") and p or {})
      if saved then FX.writeMcp(st)
      else pcall(function() hs.alert.show("Claude Shepherd: MCP server invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    else
      FX.writeMcp(core.mcpRemove(FX.readMcp(), tostring(payload.v or "")))
    end
    local list = core.mcpList(FX.readMcp())
    pcall(function() wv:evaluateJavaScript("ccMcp("
      .. ((#list > 0) and hs.json.encode(list) or "[]") .. ")") end)
    return
  end
  -- L1 Agents registry EDITOR (deferred-polish): full-field authoring + skills/MCP/
  -- knowledge attach + favorite/fork/archive + an MCP-registry surface. Every action
  -- replies with the full editor bundle (ccAgentEd) so one round-trip refreshes it all.
  if a == "open-agents-editor" or a == "agent-ed-save" or a == "agent-ed-delete"
     or a == "agent-ed-fork" or a == "agent-ed-flag"
     or a == "mcp-ed-save" or a == "mcp-ed-delete" then
    if a == "agent-ed-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      -- a rename carries the old name; look up the prior record under it
      local oldName = tostring(p.oldName or "")
      local lookup = (oldName ~= "") and oldName or tostring(p.name or "")
      local prior = core.agentGet(FX.readAgents(), lookup)
      -- carry forward the fields the form doesn't expose, so an edit can't drop
      -- them (modelByMode/requiredEnv/versions + the management flags + lineage).
      if prior then
        for _, k in ipairs({ "modelByMode", "requiredEnv", "versions", "forkedFrom",
                             "lastSpawnedAt", "agentName", "favorite", "hidden", "archived", "deleted" }) do
          if p[k] == nil and prior[k] ~= nil then p[k] = prior[k] end
        end
      end
      p.oldName = nil  -- not an AGENT_FIELD; strip before validate (would flag unknown)
      local st0 = FX.readAgents()
      if oldName ~= "" and oldName ~= tostring(p.name or "") then
        st0 = core.agentRemove(st0, oldName)  -- name-keyed push won't replace a renamed record
      end
      local st, saved, errs = core.agentPush(st0, p)
      if saved then FX.writeAgents(st)
      else pcall(function() hs.alert.show("Claude Shepherd: agent invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "agent-ed-delete" then
      FX.writeAgents(core.agentRemove(FX.readAgents(), tostring(payload.v or "")))
    elseif a == "agent-ed-fork" then
      local st, ok = core.agentFork(FX.readAgents(), tostring(payload.v or ""))
      if ok then FX.writeAgents(st) end
    elseif a == "agent-ed-flag" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      FX.writeAgents(core.agentSetFlag(FX.readAgents(), tostring(payload.v or ""), p.flag, p.value == true))
    elseif a == "mcp-ed-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local st, saved, errs = core.mcpPush(FX.readMcp(), (okp and type(p) == "table") and p or {})
      if saved then FX.writeMcp(st)
      else pcall(function() hs.alert.show("Claude Shepherd: MCP server invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "mcp-ed-delete" then
      FX.writeMcp(core.mcpRemove(FX.readMcp(), tostring(payload.v or "")))
    end
    local lc = loadConfig()
    local bundleNames = {}
    for name in pairs(core.policyBundles(lc)) do bundleNames[#bundleNames + 1] = name end
    table.sort(bundleNames)
    local bundle = {
      agents = core.agentList(FX.readAgents()), mcp = core.mcpList(FX.readMcp()),
      skills = FX.listSkills(), providers = core.config(lc, "providers", {}) or {},
      bundles = bundleNames,
    }
    pcall(function() wv:evaluateJavaScript("ccAgentEd(" .. hs.json.encode(bundle) .. ")") end)
    return
  end
  -- L2 policy bundle/attachment EDITOR (deferred-polish): author policies.bundles
  -- (a name->bundle MAP) + policies.attachments (an ORDERED array, first match wins)
  -- INSIDE cc-config.json. Reads the RAW config file, applies a pure cc-core op to
  -- the policies subtree (the rest of the file rides through), writes it back.
  if a == "open-policy-editor" or a == "policy-bundle-save" or a == "policy-bundle-delete"
     or a == "policy-att-add" or a == "policy-att-save" or a == "policy-att-delete"
     or a == "policy-att-move" then
    local raw = FX.readFile(CONFIG_FILE)
    local cfg, malformed = {}, false
    if raw and #raw > 0 then
      local ok, parsed = pcall(function() return hs.json.decode(raw) end)
      if ok and type(parsed) == "table" then cfg = parsed
      else malformed = true end
    end
    -- A non-empty file that won't parse: NEVER write (we'd clobber the user's
    -- file, losing whatever else is in it). A read (open) still replies with the
    -- defaults view so the overlay opens, but every mutation bails here.
    if malformed then
      pcall(function() hs.alert.show("Claude Shepherd: cc-config.json is malformed — fix it before editing policies") end)
      if a ~= "open-policy-editor" then return end
    end
    local policies = type(cfg.policies) == "table" and cfg.policies or {}
    local changed = false
    local function badAlert(errs) pcall(function() hs.alert.show("Claude Shepherd: invalid — "
      .. table.concat(errs or { "?" }, "; ")) end) end
    if a == "policy-bundle-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      local name, oldName = tostring(p.name or ""), tostring(p.oldName or "")
      p.name = nil; p.oldName = nil  -- not bundle fields
      if oldName ~= "" and oldName ~= name then policies = core.policyRemoveBundle(policies, oldName) end
      local np, ok, errs = core.policySetBundle(policies, name, p)
      if ok then policies = np; changed = true else badAlert(errs) end
    elseif a == "policy-bundle-delete" then
      policies = core.policyRemoveBundle(policies, tostring(payload.v or "")); changed = true
    elseif a == "policy-att-add" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local np, ok, errs = core.policyAddAttachment(policies, (okp and type(p) == "table") and p or {})
      if ok then policies = np; changed = true else badAlert(errs) end
    elseif a == "policy-att-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      local np, ok, errs = core.policySetAttachment(policies, p.index, p)
      if ok then policies = np; changed = true else badAlert(errs) end
    elseif a == "policy-att-delete" then
      policies = core.policyRemoveAttachment(policies, tonumber(payload.v)); changed = true
    elseif a == "policy-att-move" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      policies = core.policyMoveAttachment(policies, p.index, p.dir); changed = true
    end
    if changed then
      cfg.policies = policies
      FX.writeFile(CONFIG_FILE, hs.json.encode(cfg, true))
    end
    -- reply with the editor bundle (read fresh so it reflects the write)
    local nc = loadConfig()
    local atts = core.config(nc, "policies.attachments", {}) or {}
    local reply = "{\"bundles\":" .. hs.json.encode(core.policyBundles(nc))
      .. ",\"attachments\":" .. ((#atts > 0) and hs.json.encode(atts) or "[]")
      .. ",\"starters\":" .. hs.json.encode(core.DEFAULT_POLICY_BUNDLES)
      .. ",\"armed\":" .. ((FX.readFile(GATE_FLAG) ~= nil) and "true" or "false") .. "}"
    pcall(function() wv:evaluateJavaScript("ccPolicyEd(" .. reply .. ")") end)
    return
  end
  -- L6 rules EDITOR (deferred-polish): author cc-rules.json (the engine read it
  -- before; now it's editable). Each action replies with the fresh rule list +
  -- the rules.enabled master-switch state.
  if a == "open-rules-editor" or a == "rule-ed-save" or a == "rule-ed-delete" or a == "rule-ed-toggle" then
    if a == "rule-ed-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      local oldName = tostring(p.oldName or ""); p.oldName = nil  -- not a RULE_FIELD
      local st0 = FX.readRules()
      if oldName ~= "" and oldName ~= tostring(p.name or "") then st0 = core.ruleRemove(st0, oldName) end
      local st, saved, errs = core.rulePush(st0, p)
      if saved then FX.writeRules(st)
      else pcall(function() hs.alert.show("Claude Shepherd: rule invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "rule-ed-delete" then
      FX.writeRules(core.ruleRemove(FX.readRules(), tostring(payload.v or "")))
    elseif a == "rule-ed-toggle" then
      local on = (payload.text == "true" or payload.text == true)
      FX.writeRules(core.ruleSetEnabled(FX.readRules(), tostring(payload.v or ""), on))
    end
    local rulesEnabled = core.config(loadConfig(), "rules.enabled", false) == true
    local list = core.ruleList(FX.readRules())
    pcall(function() wv:evaluateJavaScript("ccRuleEd("
      .. ((#list > 0) and hs.json.encode(list) or "[]") .. ", " .. tostring(rulesEnabled) .. ")") end)
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
    -- L1 "spawn from a saved agent": resolve the profile -> persona / MCP-config /
    -- knowledge / plugin flags, write its --mcp-config file, and pass the extra opts.
    local agentOpts = nil
    local agentName = payload.agent and tostring(payload.agent) or nil
    if agentName and agentName ~= "" then
      local profile = core.agentGet(FX.readAgents(), agentName)
      if profile then
        local res = core.resolveAgent(profile, { mcpState = FX.readMcp() })
        if #res.errors > 0 then
          print("[cc-orch] agent '" .. agentName .. "' resolve warnings: " .. table.concat(res.errors, "; "))
        end
        local mcpPath = res.mcpConfig and FX.writeMcpConfig(profile.name, res.mcpConfig) or nil
        -- selected skills ride the appended system prompt (native auto-load also applies)
        local persona = res.appendSystemPrompt
        if profile.skills and #profile.skills > 0 then
          local cmds = {}
          for _, s in ipairs(profile.skills) do cmds[#cmds + 1] = core.skillCommand(s) or s end
          persona = (persona and (persona .. "\n") or "") .. "Skills available to you: " .. table.concat(cmds, ", ")
        end
        agentOpts = { appendSystemPrompt = persona, mcpConfigPath = mcpPath, strictMcp = false,
                      agentName = res.agentName, addDirs = res.addDirs, pluginDirs = res.pluginDirs }
        if (not task or task == "") and res.seedPrompt then task = res.seedPrompt end
        FX.appendLedger({ type = "spawn_agent", name = profile.name, cwd = dir, by = "agent" })
        -- record lastSpawnedAt for the registry's "last used" sort
        local pp = {}; for k, v in pairs(profile) do pp[k] = v end; pp.lastSpawnedAt = os.time()
        FX.writeAgents((core.agentPush(FX.readAgents(), pp)))
      else
        print("[cc-orch] spawn-agent: no saved agent named '" .. agentName .. "'")
      end
    end
    FX.spawnSession(editor, dir, task, payload.permMode and tostring(payload.permMode) or nil,
      payload.provider and tostring(payload.provider) or nil, agentOpts)
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
          local commit = core.queueFeedCommit(FX.feedTask(winTarget(item), renderFeed(task, item)))
          if commit.persist then FX.writeQueue(qk, q2); stampTaskStart(item, task, "manual")
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
  if a == "queue-route-mode" then
    -- L4 process mode: distribute (default, fan out) vs sequential (one routed
    -- task in flight at a time). Rides the queue file like the arm flag.
    local item = byKey[tostring(payload.v or "")]
    if not item then return end
    local qk = FX.queueKeyFor(item)
    local seq = tostring(payload.text or "") == "sequential"
    FX.writeQueue(qk, core.queueSetMode(FX.readQueue(qk), seq and "sequential" or "distribute"))
    print("[cc-route] " .. qk .. " mode " .. (seq and "sequential" or "distribute"))
    ledgerFor(item, { type = "route_mode", mode = seq and "sequential" or "distribute" })
    return
  end
  -- Saved task templates (roadmap #5c; L3): named reusable task strings in
  -- cc-templates.json (operator data, outside the Settings round-trip). L3 adds
  -- structured/versioned records + {{var}} interpolation -- cc-core stays the
  -- authoritative renderer (no JS render twin to drift).
  if a == "template-render" then
    -- Resolve a template to its rendered body: compose, then interpolate the
    -- operator-supplied vars + built-ins (date/now, and {{prev_output}} = the
    -- selected tile's latest output) and hand it back to drop into the input
    -- (NEVER auto-sent). A missing required var alerts instead of rendering.
    local rec = core.templateGetRecord(FX.readTemplates(), tostring(payload.v or ""))
    if rec then
      local opts = {}
      pcall(function() opts = hs.json.decode(tostring(payload.text or "")) or {} end)
      local sel = byKey[tostring(opts.key or "")]
      local prevOut = (sel and type(sel.activity) == "string") and sel.activity or ""
      local rendered, missing = core.renderTemplate(core.composeTemplate(rec) or "",
        type(opts.vars) == "table" and opts.vars or {}, { now = os.time(), prevOutput = prevOut })
      if rendered then
        pcall(function() wv:evaluateJavaScript("ccTemplateRendered(" .. hs.json.encode({ text = rendered }) .. ")") end)
      else
        pcall(function() hs.alert.show("Claude Shepherd: fill required variables: " .. table.concat(missing or {}, ", ")) end)
      end
    end
    return
  end
  if a == "template-import" then
    -- L3 definition source: import *.prompt / *.md files from the local prompts dir
    -- (config templates.sourceDir, default ~/.claude/cc-prompts) into the template
    -- store (versioned via cc-core; strictly local-disk, no network).
    local dir = core.config(loadConfig(), "templates.sourceDir", nil)
    dir = (type(dir) == "string" and dir ~= "") and dir or PROMPTS_DIR
    local files = FX.listPromptFiles(dir)
    local st, summary = core.promptImport(FX.readTemplates(), files, { now = os.time() })
    if summary.imported > 0 then FX.writeTemplates(st) end
    pcall(function() hs.alert.show("Claude Shepherd: imported " .. summary.imported ..
      " template(s) from " .. dir .. (summary.skipped > 0 and (" (" .. summary.skipped .. " skipped)") or "")) end)
    local out = enrichedTemplates()
    local listJson = (#out > 0) and hs.json.encode(out) or "[]"
    pcall(function() wv:evaluateJavaScript("ccTemplates(" .. listJson .. ")") end)
    return
  end
  if a == "template-list" or a == "template-save" or a == "template-delete" then
    if a == "template-save" then
      -- versioned save (duplicate-on-edit): re-saving a name snapshots the prior
      -- body into its history and bumps the version; an identical save is a no-op.
      local nm = tostring(payload.v or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local tx = tostring(payload.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local st, saved = core.templatePushVersioned(FX.readTemplates(), { name = nm, text = tx }, { now = os.time() })
      if saved then FX.writeTemplates(st)
      else pcall(function() hs.alert.show("Claude Shepherd: template needs a name and text") end) end
    elseif a == "template-delete" then
      FX.writeTemplates(core.templateRemove(FX.readTemplates(), tostring(payload.v or "")))
    end
    -- enriched reply: each {name, body, vars[], version, versionCount} so the
    -- panel renders the menu + knows which templates need a var prompt.
    local out = enrichedTemplates()
    local listJson = (#out > 0) and hs.json.encode(out) or "[]"
    pcall(function() wv:evaluateJavaScript("ccTemplates(" .. listJson .. ")") end)
    return
  end
  -- L3 Templates EDITOR (deferred-polish): authoring (description/expected_output
  -- structured fields, not just the legacy text the Tpl menu saves) + a versioned
  -- save + revert. Replies with editorTemplates() (the structured list).
  if a == "template-editor-list" or a == "template-editor-save"
     or a == "template-editor-delete" or a == "template-revert" then
    if a == "template-editor-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      p = (okp and type(p) == "table") and p or {}
      local rec = { name = tostring(p.name or ""), description = tostring(p.description or ""),
        expected_output = tostring(p.expected_output or ""), text = tostring(p.text or "") }
      local stt = FX.readTemplates()
      -- a rename: move the record under the new name FIRST (preserves version
      -- history), then the versioned save below snapshots the prior body + bumps.
      local oldName = tostring(p.oldName or "")
      if oldName ~= "" and oldName ~= rec.name then
        local rn, ok = core.templateRename(stt, oldName, rec.name)
        if ok then stt = rn end
      end
      -- carry forward a hand-authored vars schema (labels/defaults) the editor
      -- doesn't expose, so editing the body can't silently drop it (L7's lesson).
      local prior = core.templateGetRecord(stt, rec.name)
      if prior and prior.vars then rec.vars = prior.vars end
      local st, saved, errs = core.templatePushVersioned(stt, rec, { now = os.time() })
      if saved then FX.writeTemplates(st)
      else pcall(function() hs.alert.show("Claude Shepherd: template invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "template-editor-delete" then
      FX.writeTemplates(core.templateRemove(FX.readTemplates(), tostring(payload.v or "")))
    elseif a == "template-revert" then
      local st, ok = core.templateRevert(FX.readTemplates(), tostring(payload.v or ""),
        tonumber(payload.text), { now = os.time() })
      if ok then FX.writeTemplates(st) end
    end
    local out = editorTemplates()
    pcall(function() wv:evaluateJavaScript("ccTplEditor("
      .. ((#out > 0) and hs.json.encode(out) or "[]") .. ")") end)
    return
  end
  -- Version history for the revert view (current head first, then prior snapshots).
  if a == "template-versions" then
    local name = tostring(payload.v or "")
    local vers = core.templateVersions(FX.readTemplates(), name)
    pcall(function() wv:evaluateJavaScript("ccTplVersions(" .. jsString(name) .. ", "
      .. ((#vers > 0) and hs.json.encode(vers) or "[]") .. ")") end)
    return
  end
  -- L7 routine board (deferred-polish): open / save / delete / pause-resume. The
  -- routines live in cc-schedules.json (operator data); the FIRING engine in
  -- refresh() is untouched -- this is just the editor that replaces hand-editing JSON.
  if a == "open-routines" or a == "schedule-save" or a == "schedule-delete"
     or a == "schedule-toggle" then
    if a == "schedule-save" then
      local okp, p = pcall(hs.json.decode, payload.text or "{}")
      local st, saved, errs = core.schedulePush(FX.readSchedules(), (okp and type(p) == "table") and p or {})
      if saved then FX.writeSchedules(st)
      else pcall(function() hs.alert.show("Claude Shepherd: routine invalid — "
        .. table.concat(errs or { "?" }, "; ")) end) end
    elseif a == "schedule-delete" then
      FX.writeSchedules(core.scheduleRemove(FX.readSchedules(), tostring(payload.v or "")))
    elseif a == "schedule-toggle" then
      local on = (payload.text == "true" or payload.text == true)
      FX.writeSchedules(core.scheduleSetEnabled(FX.readSchedules(), tostring(payload.v or ""), on))
    end
    local board = core.scheduleBoard(core.scheduleList(FX.readSchedules()), os.time())
    local lc = loadConfig()
    local sOn = core.config(lc, "schedules.enabled", false) == true
    local live = core.config(lc, "spawn.live", false) == true
    pcall(function() wv:evaluateJavaScript("ccSchedules("
      .. ((#board > 0) and hs.json.encode(board) or "[]") .. ", "
      .. tostring(sOn) .. ", " .. tostring(live) .. ")") end)
    return
  end
  -- Run a routine NOW (manual trigger from the board): fire the spawn/digest
  -- effect immediately, bypassing cron/enabled. Does NOT mutate schedule state --
  -- the natural firing stays intact (the user explicitly clicked it). Spawns still
  -- respect spawn.live's dry-run (FX.spawnSession), so this is safe by default.
  if a == "schedule-run-now" then
    local r = core.scheduleGet(FX.readSchedules(), tostring(payload.v or ""))
    if not r then pcall(function() hs.alert.show("Claude Shepherd: routine not found") end); return end
    local cfg = loadConfig()
    if r.action == "digest" then
      local hours = tonumber(r.digestHours) or 24
      local report = core.fleetStandup(ledgerSnapshot(), { sinceTs = os.time() - hours * 3600 })
      local topic = (r.pushTopic and r.pushTopic ~= "") and r.pushTopic
        or tostring(core.config(cfg, "escalation.pushTopic", ""))
      if topic and topic ~= "" then
        FX.push(topic, "Claude Shepherd: shift report (" .. hours .. "h)",
          core.standupMarkdown(report, { windowLabel = hours .. "h" }):sub(1, 800))
        pcall(function() hs.alert.show("Claude Shepherd: pushed '" .. tostring(r.name) .. "' digest") end)
      else
        pcall(function() hs.alert.show("Claude Shepherd: no push topic (set escalation.pushTopic)") end)
      end
    else
      FX.spawnSession(r.editor or core.config(cfg, "spawn.editor", "terminal"),
        r.folder, r.prompt, r.permMode, r.provider or "")
    end
    if ledgerEnabled() then ledgerFor({ name = r.name, projectKey = r.folder, cwd = r.folder },
      { type = "schedule_fire", routine = r.name, kind = r.kind, by = "manual",
        action = r.action or "spawn" }) end
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
  -- L2: per-session policy bundle. "" clears (back to attachment/fleet); a name
  -- attaches that bundle. Resolve + write the gate's per-session file immediately
  -- so it applies without waiting a tick; refresh() re-resolves with full context.
  if a == "set-policy" then
    local key  = tostring(payload.v or "")
    local name = tostring(payload.text or "")
    if key ~= "" then
      if name == "" then
        FX.clearPolicyOverride(key); FX.clearResolvedPolicy(key); policyCache[key] = nil
      else
        FX.setPolicyOverride(key, name)
        local cfg = loadConfig()
        local it = byKey[key]
        local prov = it and core.providerByModel(cfg, it.model, it.base_url) or nil
        local resolved = core.resolvePolicy(cfg,
          { project = it and it.projectKey, projectKey = it and it.projectKey,
            group = it and it.group, providerId = prov and prov.id or nil, key = key }, name)
        if resolved.source ~= "fleet" then
          local enc = core.json.encode({ autoAllow = resolved.autoAllow,
            autoDeny = resolved.autoDeny, bundle = resolved.bundle })
          FX.writeResolvedPolicy(key, enc); policyCache[key] = enc
        else
          FX.clearResolvedPolicy(key); policyCache[key] = nil
        end
      end
      ledgerFor(byKey[key], { type = "policy_set", scope = name })
      print("[cc-policy] per-session bundle for " .. key .. " -> " .. (name == "" and "(default)" or name))
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
  -- 📋 Shift report: ops-only summary of what the fleet DID over a window. Pure
  -- aggregation in cc-core (fleetStandup + standupMarkdown) over the ledger; the
  -- markdown is rendered in a <pre> AND fed to the Copy button (one source).
  -- "Since opened" uses the panel's start ts (what the fleet did while you were
  -- away since you launched Shepherd); 8h/24h are rolling windows.
  if a == "open-shift" then
    local okj2, req = pcall(hs.json.decode, payload.text or "{}")
    local win = (okj2 and type(req) == "table") and tostring(req.window or "open") or "open"
    local now = FX.now()
    local sinceTs, label
    if win == "8h" then sinceTs = now - 8 * 3600; label = "the last 8 hours"
    elseif win == "24h" then sinceTs = now - 24 * 3600; label = "the last 24 hours"
    else win = "open"; sinceTs = PANEL_START_TS or (now - 24 * 3600); label = "Shepherd opened" end
    local report = core.fleetStandup(ledgerSnapshot(), { sinceTs = sinceTs, untilTs = now })
    local md = core.standupMarkdown(report, { windowLabel = label })
    pcall(function() wv:evaluateJavaScript("window.ccShift("
      .. jsString(md) .. ", " .. hs.json.encode({ window = win }) .. ")") end)
    return
  end
  -- Copy a block of text (the Shift report) to the system clipboard. The Shift
  -- report is pure aggregate counts -- no prompt bodies -- so there's nothing to
  -- redact; this is a plain pasteboard write.
  if a == "copy-text" then
    local txt = tostring(payload.text or "")
    if txt ~= "" then
      pcall(function() hs.pasteboard.setContents(txt) end)
      pcall(function() hs.alert.show("Claude Shepherd: copied to clipboard") end)
    end
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
    -- Make the accelerator visible: which engine actually ran (rg when installed, grep else).
    print("[cc-search] engine=" .. kind .. " " .. bin
      .. (kind ~= "rg" and "  (install ripgrep for faster fleet search)" or ""))
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
  if a == "detail-timeline" then
    -- L5 inline Timeline tab: the selected session's chronological history,
    -- rendered compactly in the detail panel (reuses core.sessionTimeline + the
    -- cached ledger). Selection/tab-triggered, NEVER on the 1s tick. Replies an
    -- empty array when there's nothing to show (the JS renders an empty note).
    local key = tostring(payload.v or "")
    local it = byKey[key]
    local sid = it and it.session_id
    if not ledgerEnabled() or not sid or tostring(sid) == "" then
      pcall(function() wv:evaluateJavaScript("window.ccDetailTimeline(" .. jsString(key) .. ", [])") end)
      return
    end
    local res = FX.readLedger({})
    local events = core.sessionTimeline(res.events, sid, { limit = 200 })
    pcall(function() wv:evaluateJavaScript("window.ccDetailTimeline("
      .. jsString(key) .. ", " .. hs.json.encode(events) .. ")") end)
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
  if a == "plan" then
    -- L5 detail-panel agent plan/TODO: parse the selected session's transcript tail
    -- for the latest TodoWrite/ExitPlanMode (selection-triggered, NEVER the 1s tick --
    -- it parses the whole tail). Replies null when there's nothing to show.
    local key = tostring(payload.v or "")
    local it = byKey[key]
    local path = it and it.transcript_path
    local plan = nil
    if path and path ~= "" and not it.remote then
      local tail = FX.readTail(path, 262144)
      if tail then plan = core.planFromTranscript(tail) end
    end
    local payloadJson = plan and hs.json.encode(plan) or "null"
    pcall(function() wv:evaluateJavaScript("window.ccPlan(" .. jsString(key) .. ", " .. payloadJson .. ")") end)
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
  end
  -- NOTE: `continue` is ledgered POST-dispatch (gated on delivery) inside dispatch()
  -- below -- L6 made handleAction("continue") delivery-gated, so an eager pre-dispatch
  -- log would falsely record a skipped (no-window-match) resume as a success.
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
    -- continue: resumed a session frozen on an API error. Ledger gated on DELIVERY
    -- (handleAction returns nil on a no-window-match skip) so the audit trail can't
    -- record a resume that never landed. type stays "continue" (lineage counts it).
    if a == "continue" then
      ledgerFor(item, { type = "continue", outcome = (acted == "continue") and "ok" or "skipped" })
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
  /* L5 detail-panel tab strip */
  #d-tabs { display:flex; align-items:center; gap:2px; margin:8px 0 6px; border-bottom:1px solid #2c2f3a; flex-wrap:wrap; }
  .d-tab { font-size:11px; color:#8a8d99; background:transparent; border:none; border-bottom:2px solid transparent;
    padding:4px 9px; cursor:pointer; font-family:inherit; line-height:1.4; }
  .d-tab:hover { color:#cfd2db; }
  .d-tab.active { color:#fff; border-bottom-color:#5a7fd6; }
  .d-tab-cog { margin-left:auto; color:#6b7280; font-size:12px; padding:2px 6px; border:none; background:transparent;
    cursor:pointer; font-family:inherit; }
  .d-tab-cog:hover { color:#cfd2db; }
  #d-tab-menu { display:none; margin:0 0 6px; padding:6px 8px; background:#1a1c24; border:1px solid #2c2f3a; border-radius:8px; }
  #d-tab-menu.show { display:block; }
  #d-tab-menu .tm-h { font-size:10px; color:#6b7280; text-transform:uppercase; letter-spacing:.04em; margin-bottom:4px; }
  #d-tab-menu label { display:flex; align-items:center; gap:6px; font-size:11px; color:#cfd2db; padding:2px 0; cursor:pointer; }
  #d-tab-menu label.locked { color:#6b7280; cursor:default; }
  .d-panel { display:none; }
  .d-panel.active { display:block; }
  #d-timeline { font-size:11px; }
  #d-timeline .tl-pre { white-space:pre-wrap; color:#cfd2db; font-family:ui-monospace,Menlo,monospace; font-size:11px; line-height:1.5; margin:0; }
  #d-timeline .tl-empty { color:#6b7280; font-size:11px; }
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
  #d-lineage { display:none; font-size:11px; color:#8a8d99; margin:4px 0 0; }
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
  .tpl-badge { color:#c7a9f0; font-size:10px; margin-left:5px; opacity:0.85; }
  .tpl-ver { color:#7f93b8; font-size:10px; margin-left:5px; }
  .tpl-form { padding:8px; font-size:12px; }
  .tpl-form-head { color:#cfd2db; font-weight:600; margin-bottom:6px; }
  .tpl-var { display:flex; flex-direction:column; gap:2px; margin-bottom:6px; }
  .tpl-var > span { color:#8a8d99; font-size:11px; }
  .tpl-var input { background:#101218; border:1px solid #2a2d36; color:#dfe2ea;
                   border-radius:5px; padding:4px 6px; font-size:12px; }
  .tpl-req { color:#e88; }
  .tpl-form-foot { display:flex; justify-content:flex-end; gap:6px; margin-top:4px; }
  .tpl-form-foot button { background:#21232c; color:#cfd2db; border:1px solid #3a3d47;
                          border-radius:6px; padding:3px 10px; cursor:pointer; font-size:12px; }
  .tpl-form-foot button#tpl-var-go, .tpl-form-foot button#m-tpl-go { color:#8fd4a3; border-color:#2c5; }
  .tpl-form-foot button:disabled { opacity:0.4; cursor:default; }
  #d-plan { display:none; margin-top:6px; }
  .d-plan-h { color:#9aa0ad; font-size:11px; text-transform:uppercase; letter-spacing:.04em; margin:4px 0 2px; }
  .todo-row { font-size:12px; color:#c9ccd6; padding:1px 0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .todo-row.todo-done { color:#6f7787; text-decoration:line-through; }
  .todo-row.todo-active { color:#8fd4ff; font-weight:600; }
  .d-plan-pre { white-space:pre-wrap; font-size:11px; color:#aeb3c0; background:#15171d; border:1px solid #23262f;
                border-radius:5px; padding:5px 7px; margin:2px 0 0; max-height:160px; overflow-y:auto; }
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
/* 📋 Shift report: window-preset bar + Copy (rendered into #a-body) */
.sh-wins{ display:flex; gap:6px; align-items:center; margin-bottom:8px; }
.sh-win{ background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:6px; padding:2px 8px; cursor:pointer; font-size:11px; }
.sh-win.active{ color:#fff; border-color:#4b5563; background:#23262f; }
.sh-copy{ margin-left:auto; background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:6px; padding:2px 8px; cursor:pointer; font-size:11px; }
.sh-copy:hover{ color:#fff; background:#23262f; }
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
/* collapsed toolbar: one list button (☰) opens a drawer of the views */
#menu-wrap{ position:relative; display:inline-flex; }
#menu-btn{ background:#21232c; color:#cfd2db; border:1px solid #2c2f3a; border-radius:8px;
           font-size:14px; line-height:1; padding:4px 9px; cursor:pointer; position:relative; }
#menu-btn:hover{ background:#272a34; }
#toolmenu{ display:none; position:absolute; top:calc(100% + 5px); right:0; z-index:30;
           background:#1b1d24; border:1px solid #2c2f3a; border-radius:10px; padding:5px;
           box-shadow:0 8px 24px rgba(0,0,0,.5); min-width:188px; }
#toolmenu.show{ display:block; }
#toolmenu .tm-item{ display:flex; align-items:center; gap:9px; width:100%; box-sizing:border-box;
           text-align:left; background:transparent; border:0; color:#e8e9ee; font-size:13px;
           padding:7px 9px; border-radius:7px; cursor:pointer; white-space:nowrap; }
#toolmenu .tm-item:hover{ background:#262a36; }
#toolmenu .tm-ic{ font-size:14px; width:18px; text-align:center; flex:0 0 auto; }
#notify-badge{ display:none; background:#ef4444; color:#fff; border-radius:8px; font-size:9px;
               padding:0 4px; margin-left:3px; vertical-align:top; font-variant-numeric:tabular-nums; }
#tm-notify-badge{ display:none; background:#ef4444; color:#fff; border-radius:8px; font-size:9px;
               padding:0 4px; margin-left:auto; font-variant-numeric:tabular-nums; }
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
/* L7 routine board overlay (modeled on #audit). Edits cc-schedules.json. */
#routines{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#routines.show{ display:flex; }
#r-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; }
#r-head .s-x{ margin-left:auto; }
#r-warn{ padding:6px 10px; background:#2a2410; color:#e4c463; border-bottom:1px solid #3a3320; font-size:11px; display:none; }
#r-warn.show{ display:block; }
#r-body{ flex:1; overflow:auto; padding:8px 10px; }
.r-row{ display:flex; gap:10px; align-items:center; padding:7px 8px; border:1px solid #23262f; border-radius:8px; margin-bottom:6px; background:#191b22; }
.r-dot{ width:9px; height:9px; border-radius:50%; flex:0 0 auto; background:#3a3f4b; }
.r-dot.on{ background:#22c55e; }
.r-main{ flex:1; min-width:0; }
.r-name{ color:#e8e9ee; font-weight:600; }
.r-sub{ color:#8a8d99; font-size:11px; margin-top:1px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.r-badge{ display:inline-block; background:#23262f; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:5px; padding:0 5px; font-size:10px; margin-right:4px; }
.r-badge.digest{ color:#9fb6d6; border-color:#34435a; }
.r-next{ color:#6b7280; font-size:11px; white-space:nowrap; font-variant-numeric:tabular-nums; }
.r-acts{ display:flex; gap:5px; flex:0 0 auto; }
.r-btn{ background:none; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:5px; padding:2px 7px; cursor:pointer; font-size:11px; }
.r-btn:hover{ color:#fff; background:#23262f; }
.r-btn.danger{ border-color:#3a2c2c; color:#d08; }
.r-empty{ color:#6b7280; font-style:italic; padding:12px 4px; }
#r-foot{ display:flex; gap:8px; align-items:center; padding:8px 10px; border-top:1px solid #2c2f3a; }
/* Add/Edit Routine form (slides over #r-body) */
#r-form{ display:none; flex-direction:column; gap:7px; padding:4px 2px; }
#r-form.show{ display:flex; }
#r-form label{ display:flex; flex-direction:column; gap:3px; color:#9aa0ad; font-size:11px; }
#r-form input, #r-form select, #r-form textarea{ background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 7px; font-size:12px; }
#r-form textarea{ resize:vertical; min-height:48px; font-family:inherit; }
.r-grid{ display:flex; gap:8px; flex-wrap:wrap; }
.r-grid > label{ flex:1; min-width:120px; }
.r-cron{ background:#15171d; border:1px solid #23262f; border-radius:8px; padding:8px; }
.r-cron-row{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
.r-wd{ display:flex; gap:4px; flex-wrap:wrap; }
.r-wd button{ background:#1a1c22; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:5px; padding:2px 7px; cursor:pointer; font-size:11px; }
.r-wd button.on{ background:#23314a; border-color:#3b6; color:#fff; }
#r-preview{ color:#9fb6d6; font-size:11px; margin-top:6px; font-family:ui-monospace,Menlo,monospace; }
/* L3 Templates editor overlay (modeled on #routines). Edits cc-templates.json. */
#tpleditor{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#tpleditor.show{ display:flex; }
#te-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; }
#te-head .s-x{ margin-left:auto; }
#te-body{ flex:1; overflow:auto; padding:8px 10px; }
.te-row{ display:flex; gap:10px; align-items:center; padding:7px 8px; border:1px solid #23262f; border-radius:8px; margin-bottom:6px; background:#191b22; }
.te-main{ flex:1; min-width:0; }
.te-name{ color:#e8e9ee; font-weight:600; }
.te-sub{ color:#8a8d99; font-size:11px; margin-top:1px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.te-badge{ display:inline-block; background:#23262f; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:5px; padding:0 5px; font-size:10px; margin-right:4px; }
.te-badge.var{ color:#c3a3e8; border-color:#43345a; }
.te-acts{ display:flex; gap:5px; flex:0 0 auto; }
.te-empty{ color:#6b7280; font-style:italic; padding:12px 4px; }
#te-form{ display:none; flex-direction:column; gap:7px; padding:4px 2px; }
#te-form.show{ display:flex; }
#te-form label{ display:flex; flex-direction:column; gap:3px; color:#9aa0ad; font-size:11px; }
#te-form input, #te-form select, #te-form textarea{ background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 7px; font-size:12px; }
#te-form textarea{ resize:vertical; min-height:60px; font-family:inherit; }
#te-vars{ color:#c3a3e8; font-size:11px; font-family:ui-monospace,Menlo,monospace; }
#te-versions{ display:none; flex-direction:column; gap:6px; padding:4px 2px; }
#te-versions.show{ display:flex; }
.te-ver-row{ display:flex; gap:10px; align-items:flex-start; padding:7px 8px; border:1px solid #23262f; border-radius:8px; background:#191b22; }
.te-ver-row.cur{ border-color:#34507a; }
.te-ver-meta{ flex:0 0 92px; color:#8a8d99; font-size:11px; }
.te-ver-body{ flex:1; min-width:0; color:#cfd2db; font-family:ui-monospace,Menlo,monospace; font-size:11px; white-space:pre-wrap; word-break:break-word; max-height:120px; overflow:auto; }
/* L1 Agents registry editor overlay (modeled on #tpleditor). Edits cc-agents.json / cc-mcp.json. */
#agented{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#agented.show{ display:flex; }
#ae-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; flex-wrap:wrap; }
#ae-head select, #ae-head label{ font-weight:400; color:#9aa0ad; font-size:11px; }
#ae-head select{ background:#1a1c22; border:1px solid #2c2f3a; color:#cfd2db; border-radius:6px; padding:2px 6px; }
#ae-head .s-x{ margin-left:auto; }
#ae-body{ flex:1; overflow:auto; padding:8px 10px; }
.ae-row{ display:flex; gap:10px; align-items:center; padding:7px 8px; border:1px solid #23262f; border-radius:8px; margin-bottom:6px; background:#191b22; }
.ae-row.arch{ opacity:.55; }
.ae-star{ flex:0 0 auto; cursor:pointer; font-size:14px; color:#6b7280; background:none; border:0; }
.ae-star.on{ color:#f5b50a; }
.ae-main{ flex:1; min-width:0; }
.ae-name{ color:#e8e9ee; font-weight:600; }
.ae-sub{ color:#8a8d99; font-size:11px; margin-top:1px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.ae-badge{ display:inline-block; background:#23262f; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:5px; padding:0 5px; font-size:10px; margin-right:4px; }
.ae-badge.cat{ color:#9fb6d6; border-color:#34435a; }
.ae-badge.sk{ color:#c3a3e8; border-color:#43345a; }
.ae-acts{ display:flex; gap:5px; flex:0 0 auto; flex-wrap:wrap; }
.ae-empty{ color:#6b7280; font-style:italic; padding:12px 4px; }
#ae-form, #ae-mcp{ display:none; flex-direction:column; gap:7px; padding:4px 2px; }
#ae-form.show, #ae-mcp.show{ display:flex; }
#ae-form label, #ae-mcp label{ display:flex; flex-direction:column; gap:3px; color:#9aa0ad; font-size:11px; }
#ae-form input, #ae-form select, #ae-form textarea, #ae-mcp input, #ae-mcp select{ background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 7px; font-size:12px; }
#ae-form textarea{ resize:vertical; min-height:46px; font-family:inherit; }
.ae-grid{ display:flex; gap:8px; flex-wrap:wrap; }
.ae-grid > label{ flex:1; min-width:130px; }
.ae-sec{ font-weight:600; color:#cfd2db; margin:6px 0 2px; font-size:11px; }
.ae-chips{ display:flex; gap:5px; flex-wrap:wrap; }
.ae-chip{ background:#1a1c22; border:1px solid #2c2f3a; color:#9aa0ad; border-radius:6px; padding:2px 8px; cursor:pointer; font-size:11px; }
.ae-chip.on{ background:#23314a; border-color:#3b6; color:#fff; }
.ae-list{ display:flex; flex-direction:column; gap:4px; }
.ae-list-row{ display:flex; gap:5px; align-items:center; }
.ae-list-row input{ flex:1; }
/* L2 policy bundle/attachment editor overlay (modeled on #agented). Edits cc-config.json policies. */
#policyed{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#policyed.show{ display:flex; }
#pe-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; flex-wrap:wrap; }
#pe-head .s-x{ margin-left:auto; }
#pe-warn{ padding:6px 10px; background:#2a2410; color:#e4c463; border-bottom:1px solid #3a3320; font-size:11px; display:none; }
#pe-warn.show{ display:block; }
#pe-body{ flex:1; overflow:auto; padding:8px 10px; }
.pe-sec{ font-weight:600; color:#cfd2db; margin:8px 0 5px; display:flex; align-items:center; gap:8px; }
.pe-row{ display:flex; gap:10px; align-items:center; padding:7px 8px; border:1px solid #23262f; border-radius:8px; margin-bottom:6px; background:#191b22; }
.pe-main{ flex:1; min-width:0; }
.pe-name{ color:#e8e9ee; font-weight:600; }
.pe-sub{ color:#8a8d99; font-size:11px; margin-top:1px; word-break:break-word; }
.pe-badge{ display:inline-block; background:#23262f; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:5px; padding:0 5px; font-size:10px; margin-right:4px; }
.pe-badge.deny{ color:#e08; border-color:#5a3340; }
.pe-badge.allow{ color:#8fd4a3; border-color:#2c5a3a; }
.pe-acts{ display:flex; gap:5px; flex:0 0 auto; }
.pe-empty{ color:#6b7280; font-style:italic; padding:6px 4px; }
.pe-starter{ background:#1a1c22; border:1px dashed #3a4a5a; color:#9fb6d6; border-radius:6px; padding:2px 8px; cursor:pointer; font-size:11px; }
#pe-bform, #pe-aform{ display:none; flex-direction:column; gap:7px; padding:4px 2px; border:1px solid #23262f; border-radius:8px; margin:6px 0; background:#15171d; padding:10px; }
#pe-bform.show, #pe-aform.show{ display:flex; }
#pe-bform label, #pe-aform label{ display:flex; flex-direction:column; gap:3px; color:#9aa0ad; font-size:11px; }
#pe-bform input, #pe-bform select, #pe-bform textarea, #pe-aform input, #pe-aform select{ background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 7px; font-size:12px; }
#pe-bform textarea{ resize:vertical; min-height:42px; font-family:ui-monospace,Menlo,monospace; }
.pe-grid{ display:flex; gap:8px; flex-wrap:wrap; }
.pe-grid > label{ flex:1; min-width:120px; }
.pe-check{ flex-direction:row !important; align-items:center; gap:6px; }
/* L6 rules editor overlay (modeled on #routines). Edits cc-rules.json. */
#ruleed{ position:fixed; inset:0; background:#14161b; z-index:11; display:none; flex-direction:column; font-size:12px; }
#ruleed.show{ display:flex; }
#re-head{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-bottom:1px solid #2c2f3a; font-weight:600; flex-wrap:wrap; }
#re-head .s-x{ margin-left:auto; }
#re-warn{ padding:6px 10px; background:#2a2410; color:#e4c463; border-bottom:1px solid #3a3320; font-size:11px; display:none; }
#re-warn.show{ display:block; }
#re-body{ flex:1; overflow:auto; padding:8px 10px; }
.re-row{ display:flex; gap:10px; align-items:center; padding:7px 8px; border:1px solid #23262f; border-radius:8px; margin-bottom:6px; background:#191b22; }
.re-dot{ width:9px; height:9px; border-radius:50%; flex:0 0 auto; background:#3a3f4b; }
.re-dot.on{ background:#22c55e; }
.re-main{ flex:1; min-width:0; }
.re-name{ color:#e8e9ee; font-weight:600; }
.re-sub{ color:#8a8d99; font-size:11px; margin-top:1px; word-break:break-word; }
.re-badge{ display:inline-block; background:#23262f; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:5px; padding:0 5px; font-size:10px; margin-right:4px; }
.re-badge.trig{ color:#9fb6d6; border-color:#34435a; }
.re-badge.proc{ color:#c3a3e8; border-color:#43345a; }
.re-acts{ display:flex; gap:5px; flex:0 0 auto; }
.re-empty{ color:#6b7280; font-style:italic; padding:12px 4px; }
#re-form{ display:none; flex-direction:column; gap:7px; padding:4px 2px; }
#re-form.show{ display:flex; }
#re-form label{ display:flex; flex-direction:column; gap:3px; color:#9aa0ad; font-size:11px; }
#re-form input, #re-form select, #re-form textarea{ background:#1a1c22; border:1px solid #2c2f3a; color:#e8e9ee; border-radius:6px; padding:4px 7px; font-size:12px; }
.re-grid{ display:flex; gap:8px; flex-wrap:wrap; }
.re-grid > label{ flex:1; min-width:120px; }
.re-check{ flex-direction:row !important; align-items:center; gap:6px; }
.re-sec{ font-weight:600; color:#cfd2db; margin:4px 0 0; font-size:11px; }
/* insights sparklines (Feature 6): trend lines over the ledger */
.spark-row{ display:flex; align-items:center; gap:8px; padding:4px 0; }
.spark-lbl{ width:110px; flex:0 0 auto; color:#9aa0ad; font-size:11px; }
.spark{ flex:1; min-width:0; background:#191b22; border:1px solid #23262f; border-radius:4px; }
.spark-val{ width:160px; flex:0 0 auto; text-align:right; color:#8a8d99; font-size:11px; font-variant-numeric:tabular-nums; }
.spark-empty{ flex:1; color:#6b7280; font-size:11px; font-style:italic; }
/* ⌨ hotkey legend: a subtle bottom-right button whose popup opens UPWARD */
#keyhelp-wrap{ position:fixed; right:8px; bottom:8px; z-index:31; }
#keyhelp-btn{ background:#21232c; color:#9aa0ad; border:1px solid #2c2f3a; border-radius:8px;
              font-size:13px; line-height:1; padding:4px 8px; cursor:pointer; opacity:.7; }
#keyhelp-btn:hover{ opacity:1; background:#272a34; }
#keymenu{ display:none; position:absolute; right:0; bottom:calc(100% + 6px); z-index:32;
          background:#1b1d24; border:1px solid #2c2f3a; border-radius:10px; padding:8px;
          box-shadow:0 8px 24px rgba(0,0,0,.5); min-width:250px; max-width:320px;
          max-height:62vh; overflow:auto; }
#keymenu.show{ display:block; }
#keymenu .kh-sec{ font-size:10px; text-transform:uppercase; letter-spacing:.04em;
                  color:#8a8d99; margin:7px 4px 3px; }
#keymenu .kh-sec:first-child{ margin-top:0; }
#keymenu .kh-row{ display:flex; align-items:baseline; gap:10px; padding:3px 4px; }
#keymenu .kh-combo{ flex:0 0 auto; min-width:52px; text-align:center; font-size:12px;
                    font-family:ui-monospace,Menlo,monospace; color:#e8e9ee; background:#262a36;
                    border:1px solid #2c2f3a; border-radius:5px; padding:1px 6px; }
#keymenu .kh-desc{ flex:1; color:#cfd2db; font-size:12px; }
</style></head>
<body class="theme-__INIT_THEME__" data-theme="__INIT_THEME__">
  <div id="bar">
    <span class="t">Claude sessions</span>
    <span class="right">
      <button id="spawn" onclick="openNew()" title="Spawn a new Claude session">New</button>
      <button id="caffeine" onclick="toggleCaffeine()" title="Keep this Mac awake — pmset disablesleep (asks for your password)">☕ Sleep ok</button>
      <span id="menu-wrap">
        <button id="menu-btn" onclick="toggleMenu(event)" title="Views — search, insights, audit, notifications">☰<span id="notify-badge"></span></button>
        <div id="toolmenu">
          <button class="tm-item" onclick="menuPick('search')"><span class="tm-ic">🔍</span> Filter sessions</button>
          <button class="tm-item" onclick="menuPick('fsearch')"><span class="tm-ic">🔎</span> Find in fleet</button>
          <button class="tm-item" onclick="menuPick('insights')"><span class="tm-ic">📊</span> Fleet insights</button>
          <button class="tm-item" onclick="menuPick('audit')"><span class="tm-ic">📜</span> Audit ledger</button>
          <button class="tm-item" onclick="menuPick('routines')"><span class="tm-ic">⏰</span> Routines</button>
          <button class="tm-item" onclick="menuPick('templates')"><span class="tm-ic">📝</span> Templates</button>
          <button class="tm-item" onclick="menuPick('agents')"><span class="tm-ic">✦</span> Agents</button>
          <button class="tm-item" onclick="menuPick('policies')"><span class="tm-ic">🛡</span> Policy bundles</button>
          <button class="tm-item" onclick="menuPick('rules')"><span class="tm-ic">⚙️</span> Automation rules</button>
          <button id="tm-shift" class="tm-item" style="display:none" onclick="menuPick('shift')"><span class="tm-ic">📋</span> Shift report</button>
          <button class="tm-item" onclick="menuPick('notify')"><span class="tm-ic">🔔</span> Notifications<span id="tm-notify-badge"></span></button>
        </div>
      </span>
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
    <!-- L5 tab strip: groups the views Shepherd already renders. The bar is
         built in JS from __DETAIL_TABS__ (single source w/ core.DETAIL_TABS);
         only the active panel shows. Renderers keep writing into the same div
         IDs below -- the strip only gates visibility + lazy-loads Timeline. -->
    <div id="d-tabs"></div>
    <div id="d-tab-menu"></div>
    <div class="d-panel" data-tab="activity">
      <div id="d-pending" onclick="toggleExpand('pending')"></div>
      <div id="d-ask"></div>
      <div id="d-activity" onclick="toggleExpand('activity')"></div>
      <div id="d-prompt"></div>
      <div id="d-meta"></div>
      <div id="d-lineage" title="Respawn / clear / continue churn for this project since midnight (needs the audit ledger)."></div>
      <div id="d-plan"></div>
    </div>
    <div class="d-panel" data-tab="timeline">
      <div id="d-timeline"></div>
    </div>
    <div class="d-panel" data-tab="decisions">
      <div id="d-decisions"></div>
    </div>
    <div class="d-panel" data-tab="usage">
      <div id="d-usage"></div>
    </div>
    <div class="d-panel" data-tab="queue">
      <div id="queue-row">
        <span id="q-count" onclick="toggleQueueList()" title="Click to view / reorder / remove queued tasks"></span>
        <label id="route-lbl" title="4c-E project routing: feed this project's queue to WHICHEVER of its sessions is free (not just the one that finished). Per-project flag; also needs Settings &rarr; Queue &rarr; project routing enabled. Logged as by:'router'."><input type="checkbox" id="q-route" onchange="onRouteToggle()"> route</label>
        <label id="route-seq-lbl" title="L4 process mode. Sequential: run this project's queue ONE routed task at a time (the next starts only after the current finishes) &mdash; serialize through the fleet. Off = distribute: fan tasks out across whichever sessions are free."><input type="checkbox" id="q-route-seq" onchange="onRouteModeToggle()"> seq</label>
        <button id="b-feed" onclick="act('queue-feed')">Feed next</button>
      </div>
      <div id="queue-list"></div>
    </div>
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
      <label class="ctl">Policy
        <select id="d-policy" onchange="onPolicyChange()" title="Attach a named policy/guardrail bundle (policies.bundles in config) to this session. Its autoAllow/autoDeny rules apply on top of the fleet policy (or replace it if the bundle sets disableGlobal). Default = no per-session bundle (attachment/fleet policy applies). Only enforced while headless approvals are armed.">
          <option value="">Default</option>
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

      <div class="s-sec">Observability (L5)</div>
      <label class="s-row"><input type="checkbox" id="s-autotitle"> Auto-title tiles from the session's first prompt</label>
      <div class="s-help">When a session has no manual relabel, derive a short title from its opening prompt (cached per project). Precedence: your relabel &gt; auto-title &gt; folder name.</div>
      <label class="s-row"><input type="checkbox" id="s-loop-en"> Loop watchdog — flag a session repeating the same tool call</label>
      <div class="s-help">A ⟳ badge + one ledger event per episode when the same command repeats <input type="number" id="s-loop-rep" class="s-num" min="2"> times in a row (default 3). Detection only — pair it with an Automation rule (loop trigger) to nudge.</div>
      <label class="s-row"><input type="checkbox" id="s-banner-approval"> macOS banner when a session needs you</label>
      <label class="s-row"><input type="checkbox" id="s-banner-done"> macOS banner when a session finishes a turn</label>
      <div class="s-help">Native notification banners (click to jump to the session). Off by default; fire on the rising edge so you're not spammed.</div>

      <div class="s-sec">Hooks <button class="s-x" style="border:1px solid #2c2f3a;border-radius:6px;padding:2px 7px;color:#cfd2db;margin-left:6px;" onclick="inspectHooks()">Inspect ~/.claude/settings.json</button></div>
      <div class="s-help">Read-only inventory of the Claude Code hooks wired in your settings (Shepherd's own are highlighted). Warns if the gate hook (cc-approve.sh) is missing its required timeout.</div>
      <div id="s-hooks"></div>

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
      <div class="s-help">Distinct from Kitty remote control above (that lets Shepherd drive the window). This is Claude Code's own Remote Control — continue a local session from claude.ai or the Claude app. New Shepherd spawns get the <code>--remote-control</code> flag (native-Anthropic, local sessions only — RC rejects gateway/ssh providers); the startup sweep covers sessions started outside Shepherd. To auto-enable RC for sessions you start in a terminal yourself, run <code>/config</code> in Claude Code and set <b>Enable Remote Control for all sessions</b> (no settings.json key is documented for it).<br><b>⚠ On by default:</b> a session with Remote Control can be driven from your claude.ai account, so anyone with access to that account (or the Claude app) can type into a <i>local</i> shell session — this widens the trust boundary from "whoever is at this machine" to "whoever can reach my claude.ai". Turn it off if that's broader than you want.</div>

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
      <div class="s-lbl">Agents <span class="n-dim">— saved profiles you hand work off to (persona · skills · MCP)</span></div>
      <div id="n-agents" class="n-recent"></div>
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
      <div class="s-lbl">Templates <span class="n-dim">— seed the task; any {{vars}} are filled in before spawn</span></div>
      <div id="n-templates" class="n-recent"></div>
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
      <div class="s-lbl">Skills available (<span id="n-skills-count">0</span>) <span class="n-dim" id="n-skills-tog" onclick="toggleSkills()" style="cursor:pointer;text-decoration:underline;">show</span></div>
      <div id="n-skills" class="n-recent" style="display:none;"></div>
    </div>
    <div id="n-foot">
      <button id="n-spawn" onclick="submitNew()">Spawn</button>
      <button onclick="savePreset()" title="Save the current folder + editor + mode + provider as a one-click preset">Save as preset</button>
      <button onclick="saveAgent()" title="Save the current setup (folder/editor/mode/provider/task + a persona role) as a reusable agent you can spawn from">Save as agent</button>
      <button onclick="closeNew();openAgentEd()" title="Open the Agents editor: full-field authoring, skills/MCP/knowledge attach, fork/favorite/archive">Manage agents…</button>
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
      <button id="a-tab-shift" class="a-tab" style="display:none" onclick="auditTab('shift')">📋 Shift</button>
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

  <div id="routines">
    <div id="r-head">
      <span>⏰ Routines</span>
      <button class="r-btn" onclick="routineNew()">+ Add routine</button>
      <button class="s-x" onclick="closeRoutines()">✕</button>
    </div>
    <div id="r-warn"></div>
    <div id="r-body"></div>
    <div id="r-form">
      <label>Name<input type="text" id="rf-name" placeholder="e.g. Morning standup digest"></label>
      <div class="r-grid">
        <label>Action
          <select id="rf-action" onchange="routineFormVis()">
            <option value="spawn">Spawn a session</option>
            <option value="digest">Push a shift-report digest</option>
          </select>
        </label>
        <label>Kind
          <select id="rf-kind" onchange="routineFormVis()">
            <option value="cron">Recurring (cron)</option>
            <option value="oneShot">Once (one-shot)</option>
          </select>
        </label>
      </div>
      <div class="r-cron" id="rf-cron-wrap">
        <div class="r-cron-row" id="rf-cron-build">
          <label style="flex-direction:row;align-items:center;gap:6px;">Every
            <select id="rf-freq" onchange="routineFormSync()">
              <option value="minute">N minutes</option>
              <option value="hour">hour</option>
              <option value="day" selected>day</option>
              <option value="week">week</option>
              <option value="month">month</option>
            </select>
          </label>
          <label id="rf-every-wrap" style="flex-direction:row;align-items:center;gap:4px;display:none;">N=<input type="number" id="rf-every" min="1" max="59" value="5" style="width:54px;" oninput="routineFormSync()"></label>
          <label id="rf-hm-wrap" style="flex-direction:row;align-items:center;gap:4px;">at <input type="number" id="rf-hour" min="0" max="23" value="9" style="width:48px;" oninput="routineFormSync()">:<input type="number" id="rf-min" min="0" max="59" value="0" style="width:48px;" oninput="routineFormSync()"></label>
          <label id="rf-dom-wrap" style="flex-direction:row;align-items:center;gap:4px;display:none;">day <input type="number" id="rf-dom" min="1" max="31" value="1" style="width:54px;" oninput="routineFormSync()"></label>
        </div>
        <div class="r-wd" id="rf-wd-wrap" style="margin-top:6px;display:none;"></div>
        <label style="flex-direction:row;align-items:center;gap:6px;margin-top:6px;">cron <input type="text" id="rf-cron-raw" value="0 9 * * *" style="flex:1;font-family:ui-monospace,Menlo,monospace;" oninput="routinePreview()"></label>
        <div id="r-preview"></div>
      </div>
      <label id="rf-at-wrap" style="display:none;">Run at (local, YYYY-MM-DD HH:MM)<input type="text" id="rf-at" placeholder="2026-06-15 14:30" oninput="routineFormSync()"></label>
      <div class="r-grid" id="rf-spawn-fields">
        <label>Folder<input type="text" id="rf-folder" placeholder="/Users/you/Programming/project"></label>
        <label>Editor
          <select id="rf-editor"><option value="">(default)</option><option value="terminal">Terminal</option><option value="kitty">Kitty</option><option value="vscode">VS Code</option><option value="cursor">Cursor</option></select>
        </label>
      </div>
      <div class="r-grid" id="rf-spawn-fields2">
        <label>Provider<input type="text" id="rf-provider" placeholder="(default — blank for bare claude)"></label>
        <label>Perm mode
          <select id="rf-permmode"><option value="">(default)</option><option value="default">default</option><option value="acceptEdits">acceptEdits</option><option value="plan">plan</option></select>
        </label>
      </div>
      <label id="rf-prompt-wrap">Initial prompt (optional)<textarea id="rf-prompt" placeholder="Seed task typed into the new session…"></textarea></label>
      <div class="r-grid" id="rf-digest-wrap" style="display:none;">
        <label>Digest window (hours)<input type="number" id="rf-digesthours" min="1" max="168" value="24" style="width:80px;"></label>
        <label>Push topic (blank = default escalation.pushTopic)<input type="text" id="rf-pushtopic" placeholder="ntfy topic"></label>
      </div>
      <div class="r-grid">
        <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="routineSave()">Save routine</button>
        <button class="r-btn" onclick="routineCancel()">Cancel</button>
      </div>
    </div>
    <div id="r-foot"><span class="n-dim" id="r-info"></span></div>
  </div>

  <div id="tpleditor">
    <div id="te-head">
      <span id="te-title">📝 Templates</span>
      <button class="r-btn" onclick="tplEditNew()">+ New template</button>
      <button class="s-x" onclick="closeTplEditor()">✕</button>
    </div>
    <div id="te-body"></div>
    <div id="te-form">
      <label>Name<input type="text" id="te-name" placeholder="e.g. Bug triage"></label>
      <div class="r-grid">
        <label style="flex-direction:row;align-items:center;gap:6px;">Body
          <select id="te-mode" onchange="tplEditModeSync()">
            <option value="structured">Structured (description + expected output)</option>
            <option value="text">Raw text</option>
          </select>
        </label>
      </div>
      <label id="te-desc-wrap">Description / task<textarea id="te-desc" placeholder="What the session should do. Use {{var}} for required vars, {{var?}} optional." oninput="tplEditVarsSync()"></textarea></label>
      <label id="te-exp-wrap">Expected output (optional)<textarea id="te-exp" placeholder="What a good result looks like (appended under “Expected output:”)." oninput="tplEditVarsSync()"></textarea></label>
      <label id="te-text-wrap" style="display:none;">Text<textarea id="te-text" placeholder="The raw template body. Use {{var}} / {{var?}} for variables." oninput="tplEditVarsSync()"></textarea></label>
      <div>Variables: <span id="te-vars">none</span></div>
      <div class="r-grid">
        <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="tplEditSave()">Save template</button>
        <button class="r-btn" onclick="tplEditCancel()">Cancel</button>
      </div>
    </div>
    <div id="te-versions">
      <div class="r-grid"><button class="r-btn" onclick="tplVersionsBack()">← Back</button><span class="n-dim" id="te-ver-info"></span></div>
      <div id="te-ver-list"></div>
    </div>
    <div id="r-foot" style="border-top:1px solid #2c2f3a;"><span class="n-dim" id="te-info"></span></div>
  </div>

  <div id="agented">
    <div id="ae-head">
      <span id="ae-title">✦ Agents</span>
      <button class="r-btn" onclick="agentEdNew()">+ New agent</button>
      <label>Sort <select id="ae-sort" onchange="renderAgentEd()">
        <option value="name">name</option><option value="favorite">favorite</option><option value="lastUsed">last used</option>
      </select></label>
      <label><input type="checkbox" id="ae-show-arch" onchange="renderAgentEd()"> show archived</label>
      <button class="r-btn" onclick="mcpEdOpen()">⚙ MCP servers</button>
      <button class="s-x" onclick="closeAgentEd()">✕</button>
    </div>
    <div id="ae-body"></div>
    <div id="ae-form">
      <div class="ae-grid">
        <label>Name<input type="text" id="af-name" placeholder="e.g. code-reviewer"></label>
        <label>Category<input type="text" id="af-category" placeholder="e.g. review (groups in the list)"></label>
      </div>
      <label>Folder (absolute — the launch dir)<input type="text" id="af-folder" placeholder="/Users/you/Programming/project"></label>
      <div class="ae-grid">
        <label>Provider<select id="af-provider"></select></label>
        <label>Model<input type="text" id="af-model" placeholder="(provider default)"></label>
        <label>Perm mode<select id="af-permmode"><option value="">(default)</option><option value="default">default</option><option value="acceptEdits">acceptEdits</option><option value="plan">plan</option></select></label>
      </div>
      <div class="ae-sec">Persona (→ --append-system-prompt)</div>
      <div class="ae-grid">
        <label>Role<input type="text" id="af-role" placeholder="a senior code reviewer"></label>
        <label>Goal<input type="text" id="af-goal" placeholder="find correctness bugs"></label>
      </div>
      <label>Backstory<textarea id="af-backstory" placeholder="Background/context for the persona block."></textarea></label>
      <label>Seed prompt (first task queued on spawn)<textarea id="af-seed" placeholder="Optional initial task."></textarea></label>
      <div class="ae-sec">Skills (→ --append-system-prompt) <span class="n-dim" id="af-skills-n"></span></div>
      <div class="ae-chips" id="af-skills"></div>
      <div class="ae-sec">MCP servers (→ --mcp-config) <span class="n-dim" id="af-mcp-n"></span></div>
      <div class="ae-chips" id="af-mcp"></div>
      <div class="ae-sec">Knowledge dirs (→ --add-dir)</div>
      <div class="ae-list" id="af-knowledge"></div>
      <button class="r-btn" style="align-self:flex-start;" onclick="aeListAdd('knowledge','')">+ knowledge path</button>
      <div class="ae-sec">Plugins (→ --plugin-dir; gated by spawn.live)</div>
      <div class="ae-list" id="af-plugins"></div>
      <button class="r-btn" style="align-self:flex-start;" onclick="aeListAdd('plugins','')">+ plugin dir</button>
      <div class="ae-sec">Folder globs (auto-attach this agent in the modal when the chosen dir matches)</div>
      <div class="ae-list" id="af-globs"></div>
      <button class="r-btn" style="align-self:flex-start;" onclick="aeListAdd('globs','')">+ glob</button>
      <div class="ae-grid">
        <label>Policy bundle (L2)<select id="af-bundle"></select></label>
      </div>
      <div class="ae-grid">
        <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="agentEdSave()">Save agent</button>
        <button class="r-btn" onclick="agentEdCancel()">Cancel</button>
        <span class="n-dim" id="af-note" style="align-self:center;">Per-mode model binding (modelByMode) + requiredEnv are preserved on edit; hand-edit those in cc-agents.json.</span>
      </div>
    </div>
    <div id="ae-mcp">
      <div class="ae-sec">MCP server registry (cc-mcp.json) — attachable to any agent above</div>
      <div id="ae-mcp-list" class="ae-list"></div>
      <div class="ae-sec">Add / edit a server</div>
      <div class="ae-grid">
        <label>ID<input type="text" id="mf-id" placeholder="e.g. linear"></label>
        <label>Label<input type="text" id="mf-label" placeholder="optional display name"></label>
        <label>Transport<select id="mf-transport" onchange="mcpFormSync()"><option value="stdio">stdio</option><option value="sse">sse</option><option value="http">http</option></select></label>
      </div>
      <label id="mf-cmd-wrap">Command (stdio)<input type="text" id="mf-command" placeholder="npx"></label>
      <label id="mf-args-wrap">Args (space-separated)<input type="text" id="mf-args" placeholder="-y @scope/server"></label>
      <label id="mf-url-wrap" style="display:none;">URL (sse/http)<input type="text" id="mf-url" placeholder="https://mcp.example.com/sse"></label>
      <div class="ae-grid">
        <label>Allowed tools (space-separated, optional)<input type="text" id="mf-tools" placeholder=""></label>
        <label>Auth token ENV var (name only — never the value)<input type="text" id="mf-tokenenv" placeholder="MY_MCP_TOKEN"></label>
      </div>
      <div class="ae-grid">
        <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="mcpEdSave()">Save server</button>
        <button class="r-btn" onclick="mcpEdReset()">Clear form</button>
        <button class="r-btn" onclick="mcpEdBack()">← Back to agents</button>
      </div>
    </div>
    <div id="r-foot" style="border-top:1px solid #2c2f3a;"><span class="n-dim" id="ae-info"></span></div>
  </div>

  <div id="policyed">
    <div id="pe-head">
      <span>🛡 Policy bundles &amp; attachments</span>
      <button class="s-x" onclick="closePolicyEd()">✕</button>
    </div>
    <div id="pe-warn"></div>
    <div id="pe-body">
      <div class="pe-sec">Bundles <button class="r-btn" onclick="peBundleNew()">+ New bundle</button>
        <span class="n-dim">starters:</span>
        <button class="pe-starter" onclick="peStarter('read-only')">read-only</button>
        <button class="pe-starter" onclick="peStarter('no-bash')">no-bash</button>
        <button class="pe-starter" onclick="peStarter('no-network')">no-network</button>
      </div>
      <div id="pe-bform">
        <label>Name<input type="text" id="bf-name" placeholder="e.g. tight"></label>
        <label>autoDeny — patterns to HOLD/escalate, one per line (e.g. Bash, Bash(rm*), Write)<textarea id="bf-deny" placeholder="Bash&#10;Write&#10;Edit"></textarea></label>
        <label>autoAllow — patterns to auto-approve, one per line<textarea id="bf-allow" placeholder="Read&#10;Bash(ls*)"></textarea></label>
        <label>gateTools — per-bundle hold-for-approval list (space-separated; overrides fleet gate.tools)<input type="text" id="bf-gate" placeholder="(blank = inherit fleet gate.tools)"></label>
        <div class="pe-grid">
          <label>Locked perm mode<select id="bf-lockmode"><option value="">(none)</option><option value="default">default</option><option value="acceptEdits">acceptEdits</option><option value="plan">plan</option></select></label>
          <label>toolLimits — soft per-tool ceilings, "Tool=N" space-separated<input type="text" id="bf-limits" placeholder="Bash=5 Write=10"></label>
        </div>
        <div class="pe-grid">
          <label class="pe-check"><input type="checkbox" id="bf-autopilot"> autopilot (auto-approve everything not denied)</label>
          <label class="pe-check"><input type="checkbox" id="bf-disable"> disableGlobal (ignore the fleet policy for this session)</label>
        </div>
        <div class="pe-grid">
          <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="peBundleSave()">Save bundle</button>
          <button class="r-btn" onclick="peBundleCancel()">Cancel</button>
        </div>
      </div>
      <div id="pe-bundles"></div>
      <div class="pe-sec" style="margin-top:14px;">Attachments <button class="r-btn" onclick="peAttNew()">+ New attachment</button>
        <span class="n-dim">first match wins → its bundle applies</span>
      </div>
      <div id="pe-aform">
        <div class="pe-grid">
          <label>Match project (glob; blank = any)<input type="text" id="af2-project" placeholder="shepherd* or *"></label>
          <label>Match group<input type="text" id="af2-group" placeholder="(any)"></label>
        </div>
        <div class="pe-grid">
          <label>Match providerId<input type="text" id="af2-provider" placeholder="(any)"></label>
          <label>Match session key<input type="text" id="af2-key" placeholder="(any)"></label>
        </div>
        <label>Bundle to apply<select id="af2-bundle"></select></label>
        <div class="pe-grid">
          <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="peAttSave()">Save attachment</button>
          <button class="r-btn" onclick="peAttCancel()">Cancel</button>
        </div>
      </div>
      <div id="pe-atts"></div>
    </div>
    <div id="r-foot" style="border-top:1px solid #2c2f3a;"><span class="n-dim" id="pe-info"></span></div>
  </div>

  <div id="ruleed">
    <div id="re-head">
      <span>⚙️ Automation rules</span>
      <button class="r-btn" onclick="ruleEdNew()">+ New rule</button>
      <button class="s-x" onclick="closeRuleEd()">✕</button>
    </div>
    <div id="re-warn"></div>
    <div id="re-body"></div>
    <div id="re-form">
      <label>Name<input type="text" id="rlf-name" placeholder="e.g. nudge-on-loop"></label>
      <div class="re-sec">When (trigger)</div>
      <label>On edge
        <select id="rlf-trigger">
          <option value="done">done (turn finished)</option>
          <option value="error">error (API error / frozen)</option>
          <option value="approval">approval (needs you)</option>
          <option value="hung">hung (stalled — no progress)</option>
          <option value="loop">loop (repeating the same tool)</option>
          <option value="starved">starved (queue has work, no free session)</option>
        </select>
      </label>
      <div class="re-grid">
        <label>Match project (glob; blank = any)<input type="text" id="rlf-m-project" placeholder="(any)"></label>
        <label>Match group<input type="text" id="rlf-m-group" placeholder="(any)"></label>
      </div>
      <div class="re-grid">
        <label>Match session key<input type="text" id="rlf-m-key" placeholder="(any)"></label>
        <label>Match providerId<input type="text" id="rlf-m-provider" placeholder="(any)"></label>
      </div>
      <div class="re-sec">Do (processor)</div>
      <label>Action
        <select id="rlf-proc" onchange="ruleEdProcSync()">
          <option value="log">log (audit-only note)</option>
          <option value="relabel">relabel the tile</option>
          <option value="nudge">nudge (type a message)</option>
          <option value="feed">feed (queue a task)</option>
          <option value="continue">continue (resume an errored session)</option>
        </select>
      </label>
      <label id="rlf-text-wrap">Text<textarea id="rlf-text" placeholder="The message / task / note."></textarea></label>
      <label id="rlf-label-wrap" style="display:none;">New label<input type="text" id="rlf-label" placeholder="e.g. ⚠ review me"></label>
      <div class="re-grid">
        <label class="re-check"><input type="checkbox" id="rlf-once" checked> once (fire at most once per session)</label>
        <label class="re-check"><input type="checkbox" id="rlf-enabled" checked> enabled</label>
      </div>
      <div class="re-grid">
        <button class="r-btn" style="border-color:#3b6;color:#bdf;" onclick="ruleEdSave()">Save rule</button>
        <button class="r-btn" onclick="ruleEdCancel()">Cancel</button>
        <span class="n-dim" style="align-self:center;">nudge/feed/continue are delivery-gated (skip if no window matches); all safe + opt-in.</span>
      </div>
    </div>
    <div id="r-foot" style="border-top:1px solid #2c2f3a;"><span class="n-dim" id="re-info"></span></div>
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
    // L4: distribute (default) vs sequential (one routed task in flight at a time).
    function onRouteModeToggle(){
      if(!selectedKey) return;
      send("queue-route-mode", selectedKey, document.getElementById("q-route-seq").checked ? "sequential" : "distribute");
    }

    // ---- Saved task templates (roadmap #5c; L3) ----------------------------
    // Records carry a composed `body`, an effective `vars` list, and a version.
    // A template with vars (or built-ins like {{today}}) is RENDERED by cc-core
    // before insert: collect values in an inline form, round-trip to Lua, drop the
    // rendered text into the input (never auto-sent). cc-core owns the render — no
    // JS render twin to drift.
    var TEMPLATES = [];
    var tplOpen = false;
    var tplVarForm = null;   // {name, vars:[{name,required,label,default}], values:{}}
    function toggleTemplates(){
      tplOpen = !tplOpen;
      if(tplOpen){ tplVarForm = null; send("template-list"); }
      renderTemplates();
    }
    function ccTemplates(list){ TEMPLATES = list || []; renderTemplates(); }
    function tplFind(name){ for(var i=0;i<TEMPLATES.length;i++){ if(TEMPLATES[i].name===name) return TEMPLATES[i]; } return null; }
    function tplQuote(s){ return JSON.stringify(s).replace(/"/g,"&quot;").replace(/</g,"&lt;"); }
    function renderTemplates(){
      var box = document.getElementById("tpl-menu"); if(!box) return;
      box.classList.toggle("show", tplOpen);
      if(!tplOpen){ box.innerHTML = ""; return; }
      if(tplVarForm){ box.innerHTML = renderVarForm(); tplVarCheck(); return; }
      var html = '<div class="tpl-row tpl-save" onclick="templateSaveCurrent()">＋ Save current input as template…</div>';
      html += '<div class="tpl-row tpl-save" onclick="templateImport()">⤓ Import from prompts folder…</div>';
      html += '<div class="tpl-row tpl-save" onclick="tplOpen=false;renderTemplates();openTplEditor()">📝 Manage templates… (author / versions)</div>';
      html += TEMPLATES.map(function(t){
        var nm = tplQuote(t.name);
        var badge = (t.vars && t.vars.length) ? '<span class="tpl-badge" title="has variables">{{ }}</span>' : '';
        var ver = (t.version && t.version > 1) ? '<span class="tpl-ver">v' + t.version + '</span>' : '';
        return '<div class="tpl-row" onclick="templateInsert(' + nm + ')">'
          + '<span class="tpl-name">' + esc(t.name) + badge + ver + '</span>'
          + '<span class="tpl-text">' + esc(t.body || "") + '</span>'
          + '<button onclick="event.stopPropagation();templateDelete(' + nm + ')" title="Delete">✕</button>'
          + '</div>';
      }).join("");
      box.innerHTML = html;
    }
    function renderVarForm(){
      var f = tplVarForm;
      var rows = f.vars.map(function(v){
        var lab = esc(v.label || v.name) + (v.required ? ' <span class="tpl-req">*</span>' : '');
        return '<label class="tpl-var"><span>' + lab + '</span>'
          + '<input type="text" value="' + esc(f.values[v.name] || "") + '" oninput="tplVarInput(' + tplQuote(v.name) + ', this.value)"></label>';
      }).join("");
      return '<div class="tpl-form"><div class="tpl-form-head">Fill variables for “' + esc(f.name) + '”</div>'
        + rows
        + '<div class="tpl-form-foot"><button onclick="tplVarCancel()">Cancel</button>'
        + '<button id="tpl-var-go" onclick="tplVarGo()">Insert</button></div></div>';
    }
    function templateInsert(name){
      var t = tplFind(name); if(!t) return;
      var vars = (t.vars && t.vars.length) ? t.vars : [];
      if(vars.length){   // collect values, then render
        tplVarForm = { name: name, vars: vars, values: {} };
        vars.forEach(function(v){ if(v.default) tplVarForm.values[v.name] = v.default; });
        renderTemplates(); return;
      }
      if(/\{\{/.test(t.body || "")){   // built-ins only (date/now/prev_output)
        send("template-render", name, JSON.stringify({ vars: {}, key: selectedKey || "" }));
        tplOpen = false; renderTemplates(); return;
      }
      var el = document.getElementById("nudge");
      el.value = t.body || ""; autoGrow(el); el.focus();
      tplOpen = false; renderTemplates();
    }
    function tplVarInput(name, val){ if(tplVarForm){ tplVarForm.values[name] = val; tplVarCheck(); } }
    function tplVarCheck(){
      if(!tplVarForm) return;
      var ok = true;
      tplVarForm.vars.forEach(function(v){
        if(v.required && !((tplVarForm.values[v.name] || "").trim())) ok = false;
      });
      var btn = document.getElementById("tpl-var-go"); if(btn) btn.disabled = !ok;
    }
    function tplVarCancel(){ tplVarForm = null; renderTemplates(); }
    function tplVarGo(){
      if(!tplVarForm) return;
      send("template-render", tplVarForm.name, JSON.stringify({ vars: tplVarForm.values, key: selectedKey || "" }));
      tplVarForm = null; tplOpen = false; renderTemplates();
    }
    // cc-core hands back the rendered body; it lands in whichever input started the
    // flow (the nudge box, or the New-Session modal's task field). Never auto-sent.
    var tplRenderTarget = "nudge";
    function ccTemplateRendered(o){
      var id = (tplRenderTarget === "n-task") ? "n-task" : "nudge";
      tplRenderTarget = "nudge";   // reset to the default sink
      var el = document.getElementById(id); if(!el) return;
      el.value = (o && o.text) || "";
      if(id === "nudge"){ autoGrow(el); } else { renderModalTpls(); }
      el.focus();
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
    // L3 definition source: import *.prompt / *.md files from the local prompts
    // folder (config templates.sourceDir, default ~/.claude/cc-prompts).
    function templateImport(){ send("template-import"); }
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
      // L5 observability toggles (were config-only).
      ck("s-autotitle",      cv(cfg,"autoTitle.enabled",false));
      ck("s-loop-en",        cv(cfg,"escalation.loop.enabled",false));
      val("s-loop-rep",      cv(cfg,"escalation.loop.repeats",3));
      ck("s-banner-approval",cv(cfg,"notifications.banner.onApproval",false));
      ck("s-banner-done",    cv(cfg,"notifications.banner.onDone",false));
      document.getElementById("s-hooks").innerHTML = "";  // lazy: load on Inspect
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
                      push: ck("s-e-push"), pushTopic: txt("s-e-topic"),
                      loop: { enabled: ck("s-loop-en"), repeats: num("s-loop-rep",3) } },
        autoTitle: { enabled: ck("s-autotitle") },
        // onAutoApproved is intentionally NOT exposed: notifyDecision only consumes
        // onApproval/onDone (auto-approve banners would need a gate-decision firing
        // site — deferred). Don't surface a toggle that does nothing.
        notifications: { banner: { onApproval: ck("s-banner-approval"), onDone: ck("s-banner-done") } },
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
    // ---- L5 hooks inspector (read-only) --------------------------------------
    function inspectHooks(){ send("inspect-hooks"); }
    function ccHooks(inv, gate, path){
      var box = document.getElementById("s-hooks"); if(!box) return; box.innerHTML = "";
      var g = document.createElement("div"); g.className = "s-help"; g.style.marginLeft = "0";
      if(gate && gate.present){
        g.textContent = gate.ok
          ? ("✓ Gate hook cc-approve.sh timeout = " + gate.timeout + "s (≥130 — OK).")
          : ("⚠ Gate hook cc-approve.sh timeout = " + (gate.timeout||"unset") + "s — needs ≥130s. Run make install to fix.");
        g.style.color = gate.ok ? "#8fd4a3" : "#e4c463";
      } else {
        g.textContent = "⚠ Gate hook cc-approve.sh is NOT wired in settings.json — headless approvals won't work (run make setup).";
        g.style.color = "#e4c463";
      }
      box.appendChild(g);
      if(!inv || !inv.length){ var e=document.createElement("div"); e.className="s-help"; e.style.marginLeft="0";
        e.textContent = "No hooks found in " + (path||"settings.json") + "."; box.appendChild(e); return; }
      var byEvent = {};
      inv.forEach(function(h){ (byEvent[h.event] = byEvent[h.event] || []).push(h); });
      Object.keys(byEvent).forEach(function(ev){
        var sec = document.createElement("div"); sec.className = "s-lbl"; sec.textContent = ev; box.appendChild(sec);
        byEvent[ev].forEach(function(h){
          var row = document.createElement("div"); row.className = "s-help"; row.style.marginLeft = "12px";
          var to = (h.timeout != null) ? (" [" + h.timeout + "s]") : "";
          var mt = (h.matcher && h.matcher !== "*") ? (h.matcher + ": ") : "";
          row.textContent = (h.isOurs ? "● " : "○ ") + mt + h.command + to + (h.isOurs ? "  (Shepherd)" : "");
          row.style.color = h.isOurs ? "#9fb6d6" : "#8a8d99";
          box.appendChild(row);
        });
      });
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
    var AGENTS = [];             // saved agent profiles (L1)
    var MCPS = [];               // saved MCP servers (L1)
    var SKILLS = [];             // ~/.claude/skills cards (L1, read-only)
    function showNew(cfg, recent, browse, presetState, agentState, templates){
      cfg = cfg || {};
      setMode("existing");
      document.getElementById("n-path").value = "";
      document.getElementById("n-name").value = "";
      document.getElementById("n-task").value = "";
      mTplForm = null; ccModalTemplates(templates);
      document.getElementById("n-editor").value = cv(cfg, "spawn.editor", "terminal");
      fillProviderSelect("n-provider", cv(cfg,"providers",[])||[], cv(cfg,"spawn.provider",""));
      presetState = presetState || {};
      PRESETS = presetState.presets || [];
      LAST_BY_PROJECT = presetState.lastByProject || {};
      renderPresets();
      agentState = agentState || {};
      AGENTS = agentState.agents || []; MCPS = agentState.mcp || [];
      renderAgents();
      ccSkills(agentState.skills || []);
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
    // ---- L1 Agent Profiles --------------------------------------------------
    function ccAgents(list){ AGENTS = list || []; renderAgents(); }
    function ccMcp(list){ MCPS = list || []; }
    function renderAgents(){
      var box = document.getElementById("n-agents"); if(!box) return; box.innerHTML = "";
      var shown = (AGENTS||[]).filter(function(p){ return !p.hidden && !p.archived && !p.deleted; });
      if(!shown.length){ box.innerHTML = '<span class="n-dim">No saved agents — set up a spawn below, then "Save as agent"</span>'; return; }
      shown.forEach(function(p){
        var b = document.createElement("button"); b.className = "n-chip";
        var bits = [p.role||"", p.provider?("· "+p.provider):"",
                    (p.skills&&p.skills.length)?("· "+p.skills.length+" skills"):"",
                    (p.mcpServers&&p.mcpServers.length)?("· "+p.mcpServers.length+" mcp"):""].filter(Boolean).join(" ");
        b.title = (p.folder||"(no saved folder — pick one first)") + (bits?("\n"+bits):"")
                + "\nClick to spawn from this agent · ✕ deletes";
        b.textContent = (p.favorite?"★ ":"") + "✦ " + p.name;
        var x = document.createElement("span"); x.className = "chip-x"; x.textContent = "✕";
        x.onclick = function(ev){ ev.stopPropagation();
          if(confirm('Delete agent "'+p.name+'"?')){ send("agent-delete", p.name); } };
        b.appendChild(x);
        b.onclick = function(){ agentSpawn(p); };
        box.appendChild(b);
      });
    }
    // One-click spawn from a saved agent: carries the profile name so Lua resolves
    // its persona/skills/MCP/knowledge into launch flags. Folder = the profile's
    // saved folder, else whatever's in the path box.
    function agentSpawn(p){
      var folder = p.folder || (document.getElementById("n-path").value||"").trim();
      if(!folder || folder.charAt(0) !== "/"){
        alert('Agent "'+p.name+'" has no saved folder — pick a project folder first, then click it again.'); return;
      }
      var task = (document.getElementById("n-task").value||"").trim();
      var payload = { a:"spawn", v:"", text:task, img:"", mode:"existing", dir:folder,
        editor:p.editor||document.getElementById("n-editor").value||"",
        permMode:p.permMode||"", provider:p.provider||"", agent:p.name };
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify(payload)); }
      catch(e){ console.log("spawn-agent send error", e); }
      closeNew();
    }
    function saveAgent(){
      var name = prompt("Agent name?"); if(name === null || !(name = name.trim())) return;
      var role = prompt("Role (optional, e.g. \"a senior code reviewer\"):"); role = role ? role.trim() : "";
      var path = (document.getElementById("n-path").value||"").trim();
      var rec = { name:name, editor:document.getElementById("n-editor").value,
        permMode:document.getElementById("n-permmode").value,
        provider:document.getElementById("n-provider").value,
        seedPrompt:(document.getElementById("n-task").value||"").trim(), role:role };
      if(path && path.charAt(0) === "/") rec.folder = path;
      send("agent-save", "", JSON.stringify(rec));
      alert('Saved agent "'+name+'". Attach skills / MCP / knowledge and edit every field in the ✦ Agents editor (☰ menu → Agents).');
    }
    // ---- L3 template picker in the New-Session modal (render-before-spawn) ---
    // Picking a template SEEDS the Initial-task field. A template with vars opens
    // an inline form (required vars gate "Use"); cc-core renders it and the result
    // lands in #n-task -- so the spawn task is fully resolved BEFORE spawn. Shares
    // the template-render round-trip with the nudge menu (cc-core owns the render).
    var MTEMPLATES = [];
    var mTplForm = null;   // {name, vars:[{name,required,label,default}], values:{}}
    function ccModalTemplates(list){ MTEMPLATES = Array.isArray(list) ? list : []; renderModalTpls(); }
    function mTplFind(name){ for(var i=0;i<MTEMPLATES.length;i++){ if(MTEMPLATES[i].name===name) return MTEMPLATES[i]; } return null; }
    function renderModalTpls(){
      var box = document.getElementById("n-templates"); if(!box) return;
      if(mTplForm){ box.innerHTML = renderMTplForm(); mTplCheck(); return; }
      if(!MTEMPLATES.length){ box.innerHTML = '<span class="n-dim">No templates yet — save one from the input’s “Tpl ▾” menu</span>'; return; }
      box.innerHTML = MTEMPLATES.map(function(t){
        var badge = (t.vars && t.vars.length) ? '<span class="tpl-badge" title="has variables">{{ }}</span>' : '';
        return '<button class="n-chip" title="Seed the task from this template" onclick="modalTplPick(' + tplQuote(t.name) + ')">'
          + '◆ ' + esc(t.name) + badge + '</button>';
      }).join("");
    }
    function renderMTplForm(){
      var f = mTplForm;
      var rows = f.vars.map(function(v){
        var lab = esc(v.label || v.name) + (v.required ? ' <span class="tpl-req">*</span>' : '');
        return '<label class="tpl-var"><span>' + lab + '</span>'
          + '<input type="text" value="' + esc(f.values[v.name] || "") + '" oninput="mTplInput(' + tplQuote(v.name) + ', this.value)"></label>';
      }).join("");
      return '<div class="tpl-form"><div class="tpl-form-head">Fill variables for “' + esc(f.name) + '” → seeds the task</div>'
        + rows
        + '<div class="tpl-form-foot"><button onclick="mTplCancel()">Cancel</button>'
        + '<button id="m-tpl-go" onclick="mTplGo()">Use</button></div></div>';
    }
    function modalTplPick(name){
      var t = mTplFind(name); if(!t) return;
      var vars = (t.vars && t.vars.length) ? t.vars : [];
      if(vars.length){
        mTplForm = { name: name, vars: vars, values: {} };
        vars.forEach(function(v){ if(v.default) mTplForm.values[v.name] = v.default; });
        renderModalTpls(); return;
      }
      if(/\{\{/.test(t.body || "")){   // built-ins only (date/now/prev_output)
        tplRenderTarget = "n-task";
        send("template-render", name, JSON.stringify({ vars: {}, key: selectedKey || "" }));
        return;
      }
      var el = document.getElementById("n-task"); el.value = t.body || ""; el.focus();
    }
    function mTplInput(name, val){ if(mTplForm){ mTplForm.values[name] = val; mTplCheck(); } }
    function mTplCheck(){
      if(!mTplForm) return;
      var ok = true;
      mTplForm.vars.forEach(function(v){ if(v.required && !((mTplForm.values[v.name]||"").trim())) ok = false; });
      var btn = document.getElementById("m-tpl-go"); if(btn) btn.disabled = !ok;
    }
    function mTplCancel(){ mTplForm = null; renderModalTpls(); }
    function mTplGo(){
      if(!mTplForm) return;
      tplRenderTarget = "n-task";
      send("template-render", mTplForm.name, JSON.stringify({ vars: mTplForm.values, key: selectedKey || "" }));
      mTplForm = null; renderModalTpls();
    }
    // ---- L1 Skills card (read-only) -----------------------------------------
    function ccSkills(list){ SKILLS = list || [];
      var c = document.getElementById("n-skills-count"); if(c) c.textContent = SKILLS.length; renderSkills(); }
    function toggleSkills(){ var b = document.getElementById("n-skills"), t = document.getElementById("n-skills-tog");
      if(!b) return; var sh = (b.style.display === "none"); b.style.display = sh ? "flex" : "none"; if(t) t.textContent = sh ? "hide" : "show"; }
    function renderSkills(){
      var box = document.getElementById("n-skills"); if(!box) return; box.innerHTML = "";
      if(!SKILLS.length){ box.innerHTML = '<span class="n-dim">No skills in ~/.claude/skills</span>'; return; }
      SKILLS.forEach(function(s){
        var d = document.createElement("span"); d.className = "n-chip"; d.style.cursor = "default";
        d.title = (s.description||"") + (s.path?("\n"+s.path):"") + (s.shape?("\n["+s.shape+"]"):"");
        d.textContent = (s.command || ("/"+s.name)) + (s.display_title?(" — "+s.display_title):"");
        box.appendChild(d);
      });
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
        TIMELINE = { key:null, events:null };       // L5: inline timeline is per-session, lazy
        closeTabMenu();
        loadTabState(key);          // restore this project's {selectedTab, unpinned}
      }
      selectedKey = key; renderDetail(); paintSelection();
      renderTabBar(); applyTabVisibility();  // built per-selection, NOT on the 1s tick
      maybeLoadActiveTab();         // lazy-fetch Timeline/Queue if that's the restored tab
    }

    // ---- L5 detail-panel tab strip -----------------------------------------
    // The bar groups the views Shepherd already renders (Activity / Timeline /
    // Decisions / Usage / Queue). DETAIL_TABS is injected from core.DETAIL_TABS
    // (single source). Per-project state {selectedTab, unpinned} persists to
    // localStorage keyed by the STABLE projectKey, so it survives cd-drift and
    // reopen. Renderers keep populating their div IDs every tick; the strip only
    // gates which panel shows + lazy-loads the expensive Timeline tab.
    var DETAIL_TABS = __DETAIL_TABS__;     // [{id,label}], canonical order
    var detailTab = "activity";            // active tab id for the current selection
    var detailUnpinned = {};               // { id:true } hidden tabs for the current project
    var TIMELINE = { key:null, events:null };  // inline timeline cache (lazy, per-session)

    function projectKeyOf(it){ return (it && (it.projectKey || it.cwd || it.key)) || null; }
    function tabStorageKey(pk){ return "cc-detailTabs-" + pk; }

    // Mirror of core.normalizeTabState (KEEP-IN-SYNC). Clamps selectedTab to a
    // known+pinned tab (default 'activity', which can never be unpinned) and
    // drops unknown/default entries from unpinned.
    function normalizeTabStateJS(raw){
      var valid = {}; for(var i=0;i<DETAIL_TABS.length;i++) valid[DETAIL_TABS[i].id] = true;
      var def = "activity";
      raw = (raw && typeof raw === "object") ? raw : {};
      var unp = {};
      var ru = raw.unpinned;
      if(ru && typeof ru === "object"){
        if(ru.length !== undefined){          // array of ids
          for(var j=0;j<ru.length;j++){ var id=ru[j]; if(valid[id] && id!==def) unp[id]=true; }
        } else {
          // map form { id:true }, OR (mirroring core.normalizeTabState) a
          // numeric-keyed { "1":"decisions" } whose VALUE is the id.
          for(var k in ru){
            var idk = (ru[k]===true) ? k : (typeof ru[k]==="string" ? ru[k] : null);
            if(idk && valid[idk] && idk!==def) unp[idk]=true;
          }
        }
      }
      var sel = raw.selectedTab;
      if(typeof sel !== "string" || !valid[sel] || unp[sel]) sel = def;
      return { selectedTab: sel, unpinned: unp };
    }
    function loadTabState(key){
      var it = findItem(key); var pk = projectKeyOf(it);
      var st = { selectedTab:"activity", unpinned:{} };
      if(pk){ try { var raw = window.localStorage.getItem(tabStorageKey(pk));
        if(raw) st = normalizeTabStateJS(JSON.parse(raw)); } catch(e){} }
      detailTab = st.selectedTab; detailUnpinned = st.unpinned;
    }
    function saveTabState(){
      var it = findItem(selectedKey); var pk = projectKeyOf(it); if(!pk) return;
      try { window.localStorage.setItem(tabStorageKey(pk),
        JSON.stringify({ selectedTab: detailTab, unpinned: detailUnpinned })); } catch(e){}
    }
    function renderTabBar(){
      var bar = document.getElementById("d-tabs"); if(!bar) return;
      bar.innerHTML = "";
      DETAIL_TABS.forEach(function(t){
        if(detailUnpinned[t.id]) return;           // hidden for this project
        var b = document.createElement("button");
        b.className = "d-tab" + (t.id === detailTab ? " active" : "");
        b.textContent = t.label; b.title = t.label;
        b.onclick = function(){ setDetailTab(t.id, true); };
        bar.appendChild(b);
      });
      var cog = document.createElement("button");
      cog.className = "d-tab-cog"; cog.textContent = "⋯";
      cog.title = "Show / hide tabs for this project";
      cog.setAttribute("aria-label", "Show or hide tabs for this project");
      cog.onclick = toggleTabMenu;
      bar.appendChild(cog);
    }
    function applyTabVisibility(){
      var panels = document.querySelectorAll("#detail .d-panel");
      for(var i=0;i<panels.length;i++){
        panels[i].classList.toggle("active", panels[i].getAttribute("data-tab") === detailTab);
      }
    }
    function setDetailTab(id, persist){
      detailTab = id; applyTabVisibility(); renderTabBar();
      if(persist) saveTabState();
      maybeLoadActiveTab();
    }
    // Lazy-load discipline: Activity/Decisions/Usage already render into their
    // divs every tick (cheap text). Only the expensive views fetch on demand --
    // Timeline pulls the ledger, Queue pulls the task file -- and only when their
    // tab is the active one.
    function maybeLoadActiveTab(){
      if(!selectedKey) return;
      if(detailTab === "timeline"){
        if(TIMELINE.key !== selectedKey){
          var it = findItem(selectedKey);
          if(it && it.session_id){
            // Mark pending (key set, events=null) BEFORE the async send so a
            // second tab-click before the reply arrives won't re-fetch.
            TIMELINE = { key: selectedKey, events: null };
            send("detail-timeline", selectedKey);   // ccDetailTimeline repaints
          } else { TIMELINE = { key: selectedKey, events: [] }; }
        }
        renderDetailTimeline();   // clears stale (key mismatch) or paints cache/pending
      } else if(detailTab === "queue"){
        if(!queueListOpen){ var it2 = findItem(selectedKey); if(it2 && (it2.queue||0) > 0){ toggleQueueList(); } }
      }
    }
    window.ccDetailTimeline = function(key, events){
      TIMELINE = { key: key, events: events || [] };
      renderDetailTimeline();
    };
    function renderDetailTimeline(){
      var box = document.getElementById("d-timeline"); if(!box) return;
      // Stale paint guard: only show data fetched for the CURRENT selection.
      if(TIMELINE.key !== selectedKey){ box.innerHTML = ""; return; }
      var evs = TIMELINE.events;
      if(evs === null){ box.innerHTML = '<div class="tl-empty">Loading activity…</div>'; return; }  // fetch in flight
      if(!evs.length){ box.innerHTML = '<div class="tl-empty">No recorded activity for this session yet (the ledger is off, or this session has no id).</div>'; return; }
      box.innerHTML = '<pre class="tl-pre">' + esc(evs.map(narr).join("\n")) + '</pre>';
    }
    // ⋯ menu: per-project tab show/hide (pin/unpin). 'activity' is always shown.
    function toggleTabMenu(){
      var m = document.getElementById("d-tab-menu");
      if(m.classList.contains("show")){ closeTabMenu(); return; }
      renderTabMenu(); m.classList.add("show");
    }
    function closeTabMenu(){ var m = document.getElementById("d-tab-menu"); if(m) m.classList.remove("show"); }
    function renderTabMenu(){
      var m = document.getElementById("d-tab-menu"); if(!m) return;
      // Built with createElement (not innerHTML concatenation) so the tab id is
      // never interpolated into an inline handler string -- the id rides a
      // closure and the label rides a text node, both injection-safe even if
      // DETAIL_TABS later grows dynamic entries.
      m.innerHTML = "";
      var h = document.createElement("div"); h.className = "tm-h";
      h.textContent = "Tabs for this project"; m.appendChild(h);
      DETAIL_TABS.forEach(function(t){
        var locked = (t.id === "activity");
        var lab = document.createElement("label"); if(locked) lab.className = "locked";
        var cb = document.createElement("input"); cb.type = "checkbox";
        cb.checked = !detailUnpinned[t.id]; cb.disabled = locked;
        if(!locked) cb.onchange = function(){ toggleTabPinned(t.id); };
        lab.appendChild(cb); lab.appendChild(document.createTextNode(" " + t.label));
        m.appendChild(lab);
      });
    }
    function toggleTabPinned(id){
      if(id === "activity") return;             // the default tab can't be hidden
      if(detailUnpinned[id]){ delete detailUnpinned[id]; }
      else {
        detailUnpinned[id] = true;
        if(detailTab === id) detailTab = "activity";   // can't sit on a hidden tab
      }
      saveTabState(); renderTabBar(); applyTabVisibility(); renderTabMenu(); maybeLoadActiveTab();
    }

    // ---- Gate decision log (roadmap #2): last-N grouped decisions ----------
    // Loaded on selection + on the selected tile's status transitions (exactly
    // when a decision likely just landed) -- NEVER on the 1s refresh tick.
    var DECISIONS = { key: null, rows: null };
    function requestDecisions(key){ if(key) send("decision-log", key); if(key) send("plan", key); }
    window.ccDecisions = function(key, rows){
      DECISIONS = { key: key, rows: rows };
      renderDecisions();
    };
    // L5: agent plan/TODO, loaded on selection (+ on the selected tile's status change).
    var PLAN = { key: null, data: null };
    window.ccPlan = function(key, data){ PLAN = { key: key, data: data }; renderPlan(); };
    function renderPlan(){
      var box = document.getElementById("d-plan"); if(!box) return;
      var d = PLAN.data;
      if(PLAN.key !== selectedKey || !d){ box.style.display = "none"; box.innerHTML = ""; return; }
      var html = "";
      if(d.todos && d.todos.length){
        html += '<div class="d-plan-h">Plan / TODO</div>';
        html += d.todos.map(function(t){
          var mark = t.status === "completed" ? "✓" : (t.status === "in_progress" ? "▸" : "○");
          var cls = t.status === "completed" ? "todo-done" : (t.status === "in_progress" ? "todo-active" : "");
          return '<div class="todo-row ' + cls + '">' + mark + ' ' + esc(t.content) + '</div>';
        }).join("");
      }
      if(d.plan){
        html += '<div class="d-plan-h">Plan</div><pre class="d-plan-pre">' + esc(d.plan) + '</pre>';
      }
      box.innerHTML = html; box.style.display = html ? "block" : "none";
    }
    function renderDecisions(){
      var box = document.getElementById("d-decisions"); if(!box) return;
      // Visibility is gated by the parent .d-panel (Decisions tab); this div just
      // holds content. display:block overrides the #d-decisions{display:none} CSS
      // default so an ACTIVE Decisions tab isn't blank when empty.
      box.style.display = "block";
      var rows = DECISIONS.rows;
      // Stale paint guard: nothing until the decision-log reply for THIS selection.
      if(DECISIONS.key !== selectedKey){ box.innerHTML = ""; return; }
      if(!rows || !rows.length || !rows.map){
        box.innerHTML = '<div class="tl-empty">No gate decisions recorded for this session yet.</div>'; return;
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
    // L2: per-session policy bundle. "" = Default (no bundle); a name attaches it.
    function onPolicyChange(){
      if(!selectedKey) return;
      send("set-policy", selectedKey, document.getElementById("d-policy").value);
    }
    // Populate the Policy dropdown from the configured bundle names + reflect the
    // session's current attachment (override file -> the live resolved bundle).
    function syncPolicySelect(it){
      var sel = document.getElementById("d-policy"); if(!sel || !it) return;
      var names = PANEL_BUNDLES || [];
      var cur = (it.policy_override != null && String(it.policy_override).trim() !== "")
                ? String(it.policy_override).trim() : "";
      sel.innerHTML = '<option value="">Default</option>'
        + names.map(function(n){ return '<option value="'+esc(n)+'">'+esc(n)+'</option>'; }).join("");
      sel.value = cur;
      var eff = it.policy_bundle ? ("bundle: " + it.policy_bundle) : "fleet policy";
      sel.title = "Effective policy for this session: " + eff
        + " — named bundles live in policies.bundles; only enforced while headless approvals are armed.";
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
      // 📋 Lineage: respawn/clear churn for this project since midnight (one line).
      var lg = document.getElementById("d-lineage");
      if(it.lineage){ lg.textContent = "♻️ " + it.lineage; lg.style.display="block"; }
      else { lg.style.display="none"; lg.textContent=""; }
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
      syncPolicySelect(it);
      renderDecisions();
      renderDetailUsage(it);
      var n = it.queue || 0;
      document.getElementById("q-count").textContent = n>0 ? ("Queue: " + n + " ▾") : "Queue: empty";
      document.getElementById("b-feed").style.display = n>0 ? "inline-block" : "none";
      document.getElementById("q-route").checked = !!it.routed;
      var seqEl = document.getElementById("q-route-seq"); if(seqEl) seqEl.checked = !!it.routeSeq;
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
       "effort","mode","d-model","d-gate","d-policy","nudge"].forEach(function(id){
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
      // NB: the tab bar + inline timeline are (re)built on selection / tab-click /
      // pin-toggle -- NOT here. renderDetail runs every 1s tick for the selected
      // tile; rebuilding the bar or re-painting the timeline <pre> each tick would
      // waste work and reset the timeline's scroll position.
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
    // Mirror of core.contextBand (cc-core.lua) -- keep these seven thresholds in sync; the
    // ui.test.lua pin "barLevel mirrors the 7-band contextBand ramp" guards the twin.
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
    // Drawer "Shift report": open the audit overlay (loads events so the other
    // tabs work) and switch straight to the Shift tab once ccAudit replies.
    var pendingShiftView = false;
    function openShiftReport(){ pendingShiftView = true; openAudit(); }
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

    // ---- L7 routine board (⏰): edit cc-schedules.json without hand-editing ----
    var ROUTINES = [];          // last board rows from ccSchedules()
    var SCHED_ON = false;       // schedules.enabled (engine master switch)
    var SPAWN_LIVE = false;     // spawn.live (else spawn routines dry-run)
    var rfWeekdays = [];        // selected weekday indices (0=Sun..6=Sat) in the form
    var rfEditing = null;       // name being edited, or null for a brand-new routine
    var WD_LABELS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

    function openRoutines(){ send("open-routines"); routineFormHide();
      document.getElementById("routines").classList.add("show"); }
    function closeRoutines(){ document.getElementById("routines").classList.remove("show"); }
    // Server reply: ([rows], schedules.enabled, spawn.live)
    function ccSchedules(list, schedOn, live){
      ROUTINES = list || []; SCHED_ON = !!schedOn; SPAWN_LIVE = !!live; renderRoutines();
    }
    function pad2(n){ return (n < 10 ? "0" : "") + n; }
    function fmtNextRun(ts){
      if(!ts) return "—";
      var d = new Date(ts * 1000), now = new Date();
      var hm = pad2(d.getHours()) + ":" + pad2(d.getMinutes());
      if(d.toDateString() === now.toDateString()) return "today " + hm;
      return (d.getMonth()+1) + "/" + d.getDate() + " " + hm;
    }
    function mkRBtn(label, fn, cls){
      var b = document.createElement("button"); b.className = "r-btn" + (cls ? " "+cls : "");
      b.textContent = label; b.onclick = fn; return b;
    }
    function renderRoutines(){
      var warn = document.getElementById("r-warn"); var notes = [];
      if(!SCHED_ON) notes.push("Scheduling is OFF (schedules.enabled in ⚙ Settings) — routines won't auto-fire. “Run” still works.");
      if(!SPAWN_LIVE) notes.push("spawn.live is OFF — spawn routines are DRY-RUN (no real session).");
      warn.textContent = notes.join("   "); warn.classList.toggle("show", notes.length > 0);
      var body = document.getElementById("r-body"); body.innerHTML = "";
      if(!ROUTINES.length){
        var e = document.createElement("div"); e.className = "r-empty";
        e.textContent = "No routines yet. “+ Add routine” schedules a session spawn or a shift-report digest.";
        body.appendChild(e); document.getElementById("r-info").textContent = ""; return;
      }
      ROUTINES.forEach(function(r){
        var row = document.createElement("div"); row.className = "r-row";
        var dot = document.createElement("div"); dot.className = "r-dot" + (r.enabled ? " on" : "");
        dot.title = r.enabled ? "enabled" : "paused"; row.appendChild(dot);
        var main = document.createElement("div"); main.className = "r-main";
        var nm = document.createElement("div"); nm.className = "r-name"; nm.textContent = r.name || "(unnamed)";
        main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "r-sub";
        var bAct = document.createElement("span"); bAct.className = "r-badge" + (r.action==="digest" ? " digest" : "");
        bAct.textContent = (r.action === "digest") ? "digest" : "spawn"; sub.appendChild(bAct);
        var bSch = document.createElement("span"); bSch.className = "r-badge";
        bSch.textContent = (r.kind === "oneShot") ? "once" : (r.human || r.cron || ""); sub.appendChild(bSch);
        var tail = document.createElement("span"); var bits = [];
        if(r.action !== "digest" && r.folder) bits.push(r.folder.replace(/^.*\//, ""));
        if(r.provider) bits.push(r.provider);
        tail.textContent = bits.join(" · "); sub.appendChild(tail);
        main.appendChild(sub); row.appendChild(main);
        var next = document.createElement("div"); next.className = "r-next";
        next.textContent = r.enabled ? ("next " + fmtNextRun(r.nextRunAt)) : "paused";
        row.appendChild(next);
        var acts = document.createElement("div"); acts.className = "r-acts";
        acts.appendChild(mkRBtn("Run", function(){ routineRunNow(r.name); }, ""));
        acts.appendChild(mkRBtn(r.enabled ? "Pause" : "Resume", function(){ routineToggle(r.name, !r.enabled); }, ""));
        acts.appendChild(mkRBtn("Edit", function(){ routineEdit(r); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ routineDelete(r.name); }, "danger"));
        row.appendChild(acts); body.appendChild(row);
      });
      document.getElementById("r-info").textContent = ROUTINES.length + " routine" + (ROUTINES.length===1?"":"s");
    }
    // --- Add/Edit form ---
    function gv(id){ var el = document.getElementById(id); return el ? el.value : ""; }
    function sv(id, val){ var el = document.getElementById(id); if(el) el.value = (val==null?"":val); }
    function show(id, on){ var el = document.getElementById(id); if(el) el.style.display = on ? "" : "none"; }
    function buildWeekdayBtns(){
      var wrap = document.getElementById("rf-wd-wrap"); wrap.innerHTML = "";
      WD_LABELS.forEach(function(lbl, i){
        var b = document.createElement("button"); b.type = "button"; b.textContent = lbl;
        b.onclick = function(){ toggleWeekday(i, b); };
        b.className = (rfWeekdays.indexOf(i) >= 0) ? "on" : "";
        wrap.appendChild(b);
      });
    }
    function toggleWeekday(i, btn){
      var at = rfWeekdays.indexOf(i);
      if(at >= 0) rfWeekdays.splice(at, 1); else rfWeekdays.push(i);
      btn.className = (rfWeekdays.indexOf(i) >= 0) ? "on" : "";
      routineFormSync();
    }
    // HAND-MIRRORED twin of core.cronBuild (cc-core.lua) — keep in sync.
    function cronBuildJS(spec){
      spec = spec || {};
      function clamp(v, lo, hi, dflt){ v = parseInt(v,10); if(isNaN(v)) return dflt;
        return v < lo ? lo : (v > hi ? hi : v); }
      var freq = spec.freq || "day";
      var mi = clamp(spec.minute, 0, 59, 0), hr = clamp(spec.hour, 0, 23, 9);
      if(freq === "minute"){ return "*/" + clamp(spec.every, 1, 59, 5) + " * * * *"; }
      if(freq === "hour"){ return mi + " * * * *"; }
      if(freq === "week"){
        var seen = {}, days = [];
        (spec.weekdays || []).forEach(function(d){ d = parseInt(d,10);
          if(!isNaN(d) && d>=0 && d<=6 && !seen[d]){ seen[d] = 1; days.push(d); } });
        days.sort(function(a,b){ return a-b; });
        return mi + " " + hr + " * * " + (days.length ? days.join(",") : "*");
      }
      if(freq === "month"){ return mi + " " + hr + " " + clamp(spec.dom, 1, 31, 1) + " * *"; }
      return mi + " " + hr + " * * *";
    }
    // Visibility + preview ONLY — never rebuilds the raw cron (so opening the
    // form to edit, or flipping action/kind, can't clobber a hand-written cron
    // that decomposeCron couldn't fully reverse). Called on form open + by the
    // action/kind selects.
    function routineFormVis(){
      var action = gv("rf-action"), kind = gv("rf-kind"), freq = gv("rf-freq");
      var isDigest = (action === "digest"), isOnce = (kind === "oneShot");
      show("rf-spawn-fields", !isDigest); show("rf-spawn-fields2", !isDigest);
      show("rf-prompt-wrap", !isDigest); show("rf-digest-wrap", isDigest);
      show("rf-cron-wrap", !isOnce); show("rf-at-wrap", isOnce);
      // cron sub-fields by freq
      show("rf-every-wrap", freq === "minute");
      show("rf-hm-wrap", freq !== "minute");
      show("rf-dom-wrap", freq === "month");
      show("rf-wd-wrap", freq === "week");
      routinePreview();
    }
    // A cron PICKER changed -> rebuild the raw cron from the pickers (the raw
    // field is the source of truth on save; pickers write into it). Called only
    // by the cron freq/every/hour/min/dom selects + weekday buttons.
    function routineFormSync(){
      routineFormVis();
      if(gv("rf-kind") !== "oneShot"){
        sv("rf-cron-raw", cronBuildJS({ freq: gv("rf-freq"), every: gv("rf-every"), minute: gv("rf-min"),
                                        hour: gv("rf-hour"), dom: gv("rf-dom"), weekdays: rfWeekdays }));
        routinePreview();
      }
    }
    function routinePreview(){
      var kind = gv("rf-kind"), p = document.getElementById("r-preview");
      if(kind === "oneShot"){
        var ep = localToEpoch(gv("rf-at"));
        p.textContent = ep ? ("Fires once at " + new Date(ep*1000).toLocaleString()) : "Enter a date/time (YYYY-MM-DD HH:MM)";
      } else {
        p.textContent = "Cron: " + (gv("rf-cron-raw") || "(empty)");
      }
    }
    function localToEpoch(s){
      s = (s || "").trim(); if(!s) return null;
      var d = new Date(s.replace(" ", "T"));
      var t = d.getTime(); return isNaN(t) ? null : Math.floor(t / 1000);
    }
    function epochToLocal(ep){
      var d = new Date(ep * 1000);
      return d.getFullYear() + "-" + pad2(d.getMonth()+1) + "-" + pad2(d.getDate()) +
             " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes());
    }
    function routineFormShow(){
      document.getElementById("r-body").style.display = "none";
      document.getElementById("r-form").classList.add("show");
      buildWeekdayBtns(); routineFormVis();  // visibility only — preserves rf-cron-raw
    }
    function routineFormHide(){
      document.getElementById("r-form").classList.remove("show");
      document.getElementById("r-body").style.display = "";
    }
    function routineFormReset(){
      rfWeekdays = []; sv("rf-name",""); sv("rf-action","spawn"); sv("rf-kind","cron");
      sv("rf-freq","day"); sv("rf-every","5"); sv("rf-hour","9"); sv("rf-min","0"); sv("rf-dom","1");
      sv("rf-cron-raw","0 9 * * *"); sv("rf-at","");
      sv("rf-folder",""); sv("rf-editor",""); sv("rf-provider",""); sv("rf-permmode","");
      sv("rf-prompt",""); sv("rf-digesthours","24"); sv("rf-pushtopic","");
    }
    function routineNew(){ rfEditing = null; routineFormReset(); routineFormShow(); }
    function routineCancel(){ routineFormHide(); }
    function routineEdit(r){
      rfEditing = r.name; routineFormReset();
      sv("rf-name", r.name); sv("rf-action", r.action || "spawn"); sv("rf-kind", r.kind || "cron");
      sv("rf-folder", r.folder || ""); sv("rf-editor", r.editor || "");
      sv("rf-provider", r.provider || ""); sv("rf-permmode", r.permMode || "");
      sv("rf-prompt", r.prompt || ""); if(r.digestHours) sv("rf-digesthours", r.digestHours);
      sv("rf-pushtopic", r.pushTopic || "");
      // raw cron is the source of truth on save; pickers are best-effort decompose
      if(r.kind === "cron" && r.cron){ sv("rf-cron-raw", r.cron); decomposeCron(r.cron); }
      if(r.kind === "oneShot" && r.at) sv("rf-at", epochToLocal(r.at));
      routineFormShow();
    }
    // Best-effort: set the pickers from a cron so editing common shapes feels right.
    // Unknown shapes leave the pickers at defaults; the raw field still has the truth.
    function decomposeCron(cron){
      var f = (cron || "").trim().split(/\s+/); if(f.length !== 5) return;
      var mi = f[0], hr = f[1], dom = f[2], dow = f[4];
      var ev = mi.match(/^\*\/(\d+)$/);
      if(ev && hr==="*" && dom==="*" && dow==="*"){ sv("rf-freq","minute"); sv("rf-every", ev[1]); return; }
      if(hr==="*" && dom==="*" && dow==="*" && /^\d+$/.test(mi)){ sv("rf-freq","hour"); sv("rf-min", mi); return; }
      if(/^\d+$/.test(mi) && /^\d+$/.test(hr)){
        sv("rf-min", mi); sv("rf-hour", hr);
        if(dom==="*" && dow!=="*"){ sv("rf-freq","week");
          rfWeekdays = dow.split(",").map(function(x){ return parseInt(x,10); }).filter(function(x){ return !isNaN(x) && x>=0 && x<=6; }); return; }
        if(dom!=="*" && /^\d+$/.test(dom) && dow==="*"){ sv("rf-freq","month"); sv("rf-dom", dom); return; }
        if(dom==="*" && dow==="*"){ sv("rf-freq","day"); return; }
      }
    }
    function routineSave(){
      var name = gv("rf-name").trim();
      if(!name){ alert("Routine needs a name."); return; }
      var action = gv("rf-action"), kind = gv("rf-kind");
      var rec = { name: name, kind: kind, action: action, enabled: false };
      // Carry forward the prior record's fields the form has NO input for, so an
      // edit (esp. a rename, which prepends a fresh record) can't silently drop
      // them: enabled (don't re-pause), lastFiredAt (else a renamed cron re-fires
      // the same minute), and model/templateRef/agentRef/tags. pushTopic has its
      // own input below. We copy ONLY these known keys -- never the whole board
      // row, which also carries human/nextRunAt annotations validateSchedule rejects.
      var prev = rfEditing ? ROUTINES.filter(function(r){ return r.name === rfEditing; })[0] : null;
      if(prev){
        rec.enabled = !!prev.enabled;
        if(prev.lastFiredAt != null) rec.lastFiredAt = prev.lastFiredAt;
        ["model","templateRef","agentRef","tags"].forEach(function(k){ if(prev[k] != null) rec[k] = prev[k]; });
      }
      if(kind === "oneShot"){
        var ep = localToEpoch(gv("rf-at"));
        if(!ep){ alert("Enter a valid date/time (YYYY-MM-DD HH:MM)."); return; }
        rec.at = ep;
      } else { rec.cron = gv("rf-cron-raw").trim(); }
      if(action === "digest"){
        rec.digestHours = parseInt(gv("rf-digesthours"),10) || 24;
        var pt = gv("rf-pushtopic").trim();
        if(pt) rec.pushTopic = pt; else delete rec.pushTopic;  // a cleared field clears it
      } else {
        delete rec.pushTopic;  // spawn routines don't push
        var folder = gv("rf-folder").trim();
        if(!folder){ alert("A spawn routine needs a folder."); return; }
        rec.folder = folder;
        if(gv("rf-editor")) rec.editor = gv("rf-editor");
        if(gv("rf-provider").trim()) rec.provider = gv("rf-provider").trim();
        if(gv("rf-permmode")) rec.permMode = gv("rf-permmode");
        if(gv("rf-prompt").trim()) rec.prompt = gv("rf-prompt");
      }
      // Name collision (new routine OR rename) silently overwrites a same-name
      // record (schedulePush is name-keyed) -- confirm before clobbering another.
      if(ROUTINES.some(function(r){ return r.name === name && r.name !== rfEditing; })){
        if(!confirm("A routine named “" + name + "” already exists — overwrite it?")) return;
      }
      // a rename: drop the old record first (push is keyed by name)
      if(rfEditing && rfEditing !== name) send("schedule-delete", rfEditing);
      send("schedule-save", name, JSON.stringify(rec));
      rfEditing = null; routineFormHide();
    }
    function routineDelete(name){
      if(!confirm("Delete routine “" + name + "”?")) return;
      send("schedule-delete", name);
    }
    function routineToggle(name, on){ send("schedule-toggle", name, on ? "true" : "false"); }
    function routineRunNow(name){
      var msg = SPAWN_LIVE ? ("Run “" + name + "” now?")
                           : ("Run “" + name + "” now?\n(spawn.live is OFF — a spawn routine will DRY-RUN.)");
      if(!confirm(msg)) return;
      send("schedule-run-now", name);
    }

    // ---- L3 Templates editor (📝): structured authoring + version/revert -------
    var TPL_EDIT = [];        // editor records from ccTplEditor()
    var teEditing = null;     // name being edited, or null for a new template
    var teVersionsFor = null; // template whose version history is showing, or null
    var BUILTIN_VARS = { date:1, today:1, now:1, prev_output:1 };

    function openTplEditor(){ send("template-editor-list"); tplEditFormHide(); tplVersionsHide();
      document.getElementById("tpleditor").classList.add("show"); }
    function closeTplEditor(){ document.getElementById("tpleditor").classList.remove("show"); }
    function ccTplEditor(list){ TPL_EDIT = list || []; renderTplEditor(); }
    function renderTplEditor(){
      var body = document.getElementById("te-body"); body.innerHTML = "";
      if(!TPL_EDIT.length){
        var e = document.createElement("div"); e.className = "te-empty";
        e.textContent = "No templates yet. “+ New template” authors one (or import from the prompts folder via the Tpl menu).";
        body.appendChild(e); document.getElementById("te-info").textContent = ""; return;
      }
      TPL_EDIT.forEach(function(t){
        var row = document.createElement("div"); row.className = "te-row";
        var main = document.createElement("div"); main.className = "te-main";
        var nm = document.createElement("div"); nm.className = "te-name"; nm.textContent = t.name;
        main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "te-sub";
        if(t.version > 1){ var bv = document.createElement("span"); bv.className = "te-badge"; bv.textContent = "v"+t.version; sub.appendChild(bv); }
        if(t.vars && t.vars.length){ var bx = document.createElement("span"); bx.className = "te-badge var";
          bx.textContent = t.vars.length + " var" + (t.vars.length===1?"":"s"); sub.appendChild(bx); }
        var prev = document.createElement("span"); prev.textContent = (t.body || "").replace(/\s+/g," ").slice(0,90);
        sub.appendChild(prev); main.appendChild(sub); row.appendChild(main);
        var acts = document.createElement("div"); acts.className = "te-acts";
        acts.appendChild(mkRBtn("Edit", function(){ tplEditOpen(t); }, ""));
        var vlabel = (t.versionCount > 0) ? ("Versions ("+(t.versionCount+1)+")") : "Versions";
        acts.appendChild(mkRBtn(vlabel, function(){ tplVersionsOpen(t.name); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ tplEditDelete(t.name); }, "danger"));
        row.appendChild(acts); body.appendChild(row);
      });
      document.getElementById("te-info").textContent = TPL_EDIT.length + " template" + (TPL_EDIT.length===1?"":"s");
    }
    // --- author form ---
    function tplEditShow(){ document.getElementById("te-body").style.display="none";
      tplVersionsHide(); document.getElementById("te-form").classList.add("show");
      tplEditModeSync(); }
    function tplEditFormHide(){ document.getElementById("te-form").classList.remove("show");
      document.getElementById("te-body").style.display=""; }
    function tplEditReset(){ sv("te-name",""); sv("te-mode","structured"); sv("te-desc",""); sv("te-exp",""); sv("te-text",""); }
    function tplEditNew(){ teEditing = null; tplEditReset(); tplEditShow(); }
    function tplEditCancel(){ tplEditFormHide(); }
    function tplEditOpen(t){
      teEditing = t.name; tplEditReset(); sv("te-name", t.name);
      if((t.description || "").trim()){ sv("te-mode","structured"); sv("te-desc", t.description||""); sv("te-exp", t.expected_output||""); }
      else { sv("te-mode","text"); sv("te-text", t.text || t.body || ""); }
      tplEditShow();
    }
    function tplEditModeSync(){
      var structured = (gv("te-mode") === "structured");
      show("te-desc-wrap", structured); show("te-exp-wrap", structured); show("te-text-wrap", !structured);
      tplEditVarsSync();
    }
    // Display-only var detection — a convenience readout. cc-core (templateVars/
    // effectiveVars) is the authoritative parser on save; this just mirrors its
    // {{name}} / {{name?}} grammar (built-ins excluded) for the editor.
    function detectVars(text){
      var seen = {}, out = [], re = /\{\{\s*([\w.\-]+)\s*(\??)\s*\}\}/g, m;
      while((m = re.exec(text)) !== null){
        var name = m[1]; if(BUILTIN_VARS[name]) continue;
        if(seen[name] === undefined){ seen[name] = (m[2] === "?"); out.push(name); }
        else if(m[2] !== "?"){ seen[name] = false; }
      }
      return out.map(function(n){ return seen[n] ? (n + "?") : n; });
    }
    function tplEditVarsSync(){
      var body = (gv("te-mode") === "structured") ? (gv("te-desc") + "\n" + gv("te-exp")) : gv("te-text");
      var found = detectVars(body);
      document.getElementById("te-vars").textContent = found.length ? found.join(", ") : "none";
    }
    function tplEditSave(){
      var name = gv("te-name").trim();
      if(!name){ alert("Template needs a name."); return; }
      var rec = { name: name };
      if(gv("te-mode") === "structured"){
        rec.description = gv("te-desc"); rec.expected_output = gv("te-exp"); rec.text = "";
        if(!rec.description.trim()){ alert("Add a description (or switch to Raw text)."); return; }
      } else {
        rec.text = gv("te-text"); rec.description = ""; rec.expected_output = "";
        if(!rec.text.trim()){ alert("Add the template text."); return; }
      }
      if(TPL_EDIT.some(function(t){ return t.name === name && t.name !== teEditing; })){
        if(!confirm('A template named "' + name + '" already exists — overwrite it?')) return;
      }
      // pass oldName so the server renames (preserving version history) before the
      // versioned save -- no client-side delete+re-add (which would drop history).
      if(teEditing && teEditing !== name) rec.oldName = teEditing;
      send("template-editor-save", name, JSON.stringify(rec));
      teEditing = null; tplEditFormHide();
    }
    function tplEditDelete(name){
      if(confirm('Delete template "' + name + '"? (its version history is also removed)')) send("template-editor-delete", name);
    }
    // --- version history / revert ---
    function tplVersionsOpen(name){ teVersionsFor = name; send("template-versions", name);
      document.getElementById("te-body").style.display="none";
      document.getElementById("te-form").classList.remove("show");
      document.getElementById("te-versions").classList.add("show"); }
    function tplVersionsHide(){ document.getElementById("te-versions").classList.remove("show"); teVersionsFor = null; }
    function tplVersionsBack(){ tplVersionsHide(); document.getElementById("te-body").style.display=""; }
    function ccTplVersions(name, versions){
      if(teVersionsFor !== name) return;  // a stale reply (user moved on)
      document.getElementById("te-ver-info").textContent = 'Version history — “' + name + '”';
      var box = document.getElementById("te-ver-list"); box.innerHTML = "";
      versions = versions || [];
      if(!versions.length){ box.innerHTML = '<div class="te-empty">No version history.</div>'; return; }
      versions.forEach(function(v){
        var row = document.createElement("div"); row.className = "te-ver-row" + (v.current ? " cur" : "");
        var meta = document.createElement("div"); meta.className = "te-ver-meta";
        meta.textContent = "v" + v.version + (v.current ? " · current" : "") + (v.ts ? (" · " + fmtNextRun(v.ts)) : "");
        row.appendChild(meta);
        var bodyd = document.createElement("div"); bodyd.className = "te-ver-body";
        var hasDesc = v.description && v.description.trim();
        bodyd.textContent = hasDesc ? (v.description + (v.expected_output ? ("\n\nExpected output:\n"+v.expected_output) : "")) : (v.text || "");
        row.appendChild(bodyd);
        if(!v.current){ row.appendChild(mkRBtn("Revert to this",
          (function(ver){ return function(){ tplRevert(name, ver); }; })(v.version), "")); }
        box.appendChild(row);
      });
    }
    function tplRevert(name, version){
      if(!confirm("Revert “" + name + "” to v" + version + "?\n(non-destructive — the current body is snapshotted first)")) return;
      send("template-revert", name, String(version));  // reply refreshes the list
      send("template-versions", name);                 // refresh this versions view
    }

    // ---- L1 Agents registry editor (✦): full-field authoring + attach + MCP ----
    var AGENTS_ED = [], AE_MCP = [], AE_SKILLS = [], AE_PROVIDERS = [], AE_BUNDLES = [];
    var aeEditing = null;        // agent name being edited, or null for new
    var afSkills = {}, afMcp = {};  // attach selection sets (name/id -> true)

    function openAgentEd(){ send("open-agents-editor"); agentEdFormHide(); mcpEdBack();
      document.getElementById("agented").classList.add("show"); }
    function closeAgentEd(){ document.getElementById("agented").classList.remove("show"); }
    function ccAgentEd(b){
      b = b || {};
      AGENTS_ED = b.agents || []; AE_MCP = b.mcp || []; AE_SKILLS = b.skills || [];
      AE_PROVIDERS = b.providers || []; AE_BUNDLES = b.bundles || [];
      renderAgentEd();
      if(document.getElementById("ae-mcp").classList.contains("show")) renderMcpList();
    }
    function aeSorted(){
      var list = (AGENTS_ED||[]).slice(), key = gv("ae-sort");
      list.sort(function(a,b){
        if(key==="favorite"){ var fa=a.favorite?1:0, fb=b.favorite?1:0; if(fa!==fb) return fb-fa; }
        else if(key==="lastUsed"){ var la=a.lastSpawnedAt||0, lb=b.lastSpawnedAt||0; if(la!==lb) return lb-la; }
        var an=(a.name||"").toLowerCase(), bn=(b.name||"").toLowerCase();
        return an < bn ? -1 : (an > bn ? 1 : 0);
      });
      return list;
    }
    function renderAgentEd(){
      var body = document.getElementById("ae-body"); body.innerHTML = "";
      var showArch = document.getElementById("ae-show-arch").checked;
      var list = aeSorted().filter(function(p){ return !p.deleted && (showArch || (!p.archived && !p.hidden)); });
      if(!list.length){ var e=document.createElement("div"); e.className="ae-empty";
        e.textContent = "No agents yet. “+ New agent” authors one (or use “Save as agent” in the New-session modal).";
        body.appendChild(e); document.getElementById("ae-info").textContent=""; return; }
      list.forEach(function(p){
        var row = document.createElement("div"); row.className = "ae-row" + (p.archived?" arch":"");
        var star = document.createElement("button"); star.className = "ae-star" + (p.favorite?" on":"");
        star.textContent = p.favorite ? "★" : "☆"; star.title = "favorite";
        star.onclick = function(){ agentEdFlag(p.name, "favorite", !p.favorite); };
        row.appendChild(star);
        var main = document.createElement("div"); main.className = "ae-main";
        var nm = document.createElement("div"); nm.className = "ae-name"; nm.textContent = p.name; main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "ae-sub";
        if(p.category){ var bc=document.createElement("span"); bc.className="ae-badge cat"; bc.textContent=p.category; sub.appendChild(bc); }
        var counts = [];
        if(p.skills&&p.skills.length) counts.push(p.skills.length+" skills");
        if(p.mcpServers&&p.mcpServers.length) counts.push(p.mcpServers.length+" mcp");
        if(p.knowledge&&p.knowledge.length) counts.push(p.knowledge.length+" kb");
        if(counts.length){ var bk=document.createElement("span"); bk.className="ae-badge sk"; bk.textContent=counts.join(" · "); sub.appendChild(bk); }
        if(p.archived){ var bx=document.createElement("span"); bx.className="ae-badge"; bx.textContent="archived"; sub.appendChild(bx); }
        var rl=document.createElement("span");
        rl.textContent=[p.role||"", p.provider?("· "+p.provider):"", p.folder?("· "+p.folder.replace(/^.*\//,"")):""].filter(Boolean).join(" ");
        sub.appendChild(rl); main.appendChild(sub); row.appendChild(main);
        var acts = document.createElement("div"); acts.className = "ae-acts";
        acts.appendChild(mkRBtn("Spawn", function(){ agentEdSpawn(p); }, ""));
        acts.appendChild(mkRBtn("Edit", function(){ agentEdOpen(p); }, ""));
        acts.appendChild(mkRBtn("Fork", function(){ send("agent-ed-fork", p.name); }, ""));
        acts.appendChild(mkRBtn(p.archived?"Unarchive":"Archive", function(){ agentEdFlag(p.name,"archived",!p.archived); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ agentEdDelete(p.name); }, "danger"));
        row.appendChild(acts); body.appendChild(row);
      });
      document.getElementById("ae-info").textContent = list.length + " agent" + (list.length===1?"":"s");
    }
    function agentEdFlag(name, flag, value){ send("agent-ed-flag", name, JSON.stringify({ flag: flag, value: value })); }
    function agentEdDelete(name){ if(confirm('Delete agent "'+name+'"? (removes the saved profile)')) send("agent-ed-delete", name); }
    function agentEdSpawn(p){
      if(!p.folder || p.folder.charAt(0) !== "/"){ alert('Agent "'+p.name+'" has no saved folder — Edit it and set one first.'); return; }
      var payload = { a:"spawn", v:"", text:"", img:"", mode:"existing", dir:p.folder,
        editor:"", permMode:p.permMode||"", provider:p.provider||"", agent:p.name };
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify(payload)); } catch(e){ console.log("spawn-agent err", e); }
      closeAgentEd();
    }
    // --- option lists + selects ---
    function setSelect(id, val){
      var el = document.getElementById(id); if(!el) return;
      var has = false; for(var i=0;i<el.options.length;i++){ if(el.options[i].value===val){ has=true; break; } }
      if(!has && val){ var o=document.createElement("option"); o.value=val; o.textContent=val+" (missing)"; el.appendChild(o); }
      el.value = val;
    }
    function populateAeSelects(){
      var ps = document.getElementById("af-provider"); ps.innerHTML = "";
      var none = document.createElement("option"); none.value=""; none.textContent="(none — bare claude)"; ps.appendChild(none);
      AE_PROVIDERS.forEach(function(pr){ var id=(pr&&pr.id)?pr.id:pr; if(!id) return;
        var o=document.createElement("option"); o.value=id; o.textContent=id; ps.appendChild(o); });
      var bs = document.getElementById("af-bundle"); bs.innerHTML = "";
      var bn = document.createElement("option"); bn.value=""; bn.textContent="(none)"; bs.appendChild(bn);
      AE_BUNDLES.forEach(function(b){ var o=document.createElement("option"); o.value=b; o.textContent=b; bs.appendChild(o); });
    }
    // --- attach chips (skills + MCP): render the UNION of available + selected so a
    //     selection for a now-missing skill/server isn't silently dropped on save ---
    function skillByName(n){ for(var i=0;i<AE_SKILLS.length;i++){ if(AE_SKILLS[i].name===n) return AE_SKILLS[i]; } return null; }
    function renderSkillChips(){
      var box = document.getElementById("af-skills"); box.innerHTML = "";
      var names = AE_SKILLS.map(function(s){ return s.name; });
      Object.keys(afSkills).forEach(function(n){ if(names.indexOf(n)<0) names.push(n); });
      if(!names.length){ box.innerHTML = '<span class="n-dim">No skills in ~/.claude/skills</span>'; updateAttachCounts(); return; }
      names.forEach(function(n){
        var s = skillByName(n);
        var c = document.createElement("button"); c.type="button";
        c.className = "ae-chip" + (afSkills[n]?" on":"");
        c.textContent = n + (s?"":" (missing)"); c.title = s ? (s.description||"") : "not found in ~/.claude/skills";
        c.onclick = function(){ if(afSkills[n]) delete afSkills[n]; else afSkills[n]=true;
          c.className = "ae-chip"+(afSkills[n]?" on":""); updateAttachCounts(); };
        box.appendChild(c);
      });
      updateAttachCounts();
    }
    function renderMcpChips(){
      var box = document.getElementById("af-mcp"); box.innerHTML = "";
      var ids = AE_MCP.map(function(m){ return m.id; });
      Object.keys(afMcp).forEach(function(n){ if(ids.indexOf(n)<0) ids.push(n); });
      if(!ids.length){ box.innerHTML = '<span class="n-dim">No MCP servers — add some via “⚙ MCP servers”</span>'; updateAttachCounts(); return; }
      ids.forEach(function(n){
        var known = AE_MCP.some(function(m){ return m.id===n; });
        var c = document.createElement("button"); c.type="button";
        c.className = "ae-chip" + (afMcp[n]?" on":"");
        c.textContent = n + (known?"":" (missing)");
        c.onclick = function(){ if(afMcp[n]) delete afMcp[n]; else afMcp[n]=true;
          c.className = "ae-chip"+(afMcp[n]?" on":""); updateAttachCounts(); };
        box.appendChild(c);
      });
      updateAttachCounts();
    }
    function updateAttachCounts(){
      document.getElementById("af-skills-n").textContent = Object.keys(afSkills).length ? (Object.keys(afSkills).length+" selected") : "";
      document.getElementById("af-mcp-n").textContent = Object.keys(afMcp).length ? (Object.keys(afMcp).length+" selected") : "";
    }
    // --- list fields (knowledge / plugins / globs): editable input rows ---
    function aeListAdd(kind, val){
      var box = document.getElementById("af-"+kind); if(!box) return;
      var row = document.createElement("div"); row.className = "ae-list-row";
      var inp = document.createElement("input"); inp.type="text"; inp.value = val||"";
      inp.placeholder = (kind==="knowledge") ? "/path/to/dir" : (kind==="plugins") ? "/path/to/plugin-dir" : "src/**/*.ts";
      var x = document.createElement("button"); x.className="r-btn danger"; x.textContent="✕";
      x.onclick = function(){ box.removeChild(row); };
      row.appendChild(inp); row.appendChild(x); box.appendChild(row);
    }
    function aeListClear(kind){ var box=document.getElementById("af-"+kind); if(box) box.innerHTML=""; }
    function aeListRead(kind){
      var box=document.getElementById("af-"+kind), out=[];
      if(box) box.querySelectorAll("input").forEach(function(inp){ var v=inp.value.trim(); if(v) out.push(v); });
      return out;
    }
    // --- agent form ---
    function agentEdShow(){
      document.getElementById("ae-body").style.display="none";
      document.getElementById("ae-mcp").classList.remove("show");
      populateAeSelects();
      document.getElementById("ae-form").classList.add("show");
    }
    function agentEdFormHide(){ document.getElementById("ae-form").classList.remove("show"); document.getElementById("ae-body").style.display=""; }
    function agentEdReset(){
      ["af-name","af-category","af-folder","af-model","af-role","af-goal","af-backstory","af-seed"].forEach(function(id){ sv(id,""); });
      setSelect("af-provider",""); setSelect("af-permmode",""); setSelect("af-bundle","");
      afSkills={}; afMcp={}; aeListClear("knowledge"); aeListClear("plugins"); aeListClear("globs");
    }
    function agentEdNew(){ aeEditing=null; agentEdShow(); agentEdReset(); renderSkillChips(); renderMcpChips(); }
    function agentEdCancel(){ agentEdFormHide(); }
    function agentEdOpen(p){
      aeEditing = p.name; agentEdShow(); agentEdReset();
      sv("af-name",p.name); sv("af-category",p.category||""); sv("af-folder",p.folder||""); sv("af-model",p.model||"");
      setSelect("af-provider",p.provider||""); setSelect("af-permmode",p.permMode||""); setSelect("af-bundle",p.policyBundle||"");
      sv("af-role",p.role||""); sv("af-goal",p.goal||""); sv("af-backstory",p.backstory||""); sv("af-seed",p.seedPrompt||"");
      (p.skills||[]).forEach(function(s){ afSkills[s]=true; });
      (p.mcpServers||[]).forEach(function(m){ afMcp[m]=true; });
      (p.knowledge||[]).forEach(function(k){ aeListAdd("knowledge",k); });
      (p.plugins||[]).forEach(function(k){ aeListAdd("plugins",k); });
      (p.folderGlobs||[]).forEach(function(k){ aeListAdd("globs",k); });
      renderSkillChips(); renderMcpChips();
    }
    function agentEdSave(){
      var name = gv("af-name").trim();
      if(!name){ alert("Agent needs a name."); return; }
      var folder = gv("af-folder").trim();
      if(folder && folder.charAt(0) !== "/"){ alert("Folder must be an absolute path (or blank)."); return; }
      var rec = { name: name };
      if(gv("af-category").trim()) rec.category = gv("af-category").trim();
      if(folder) rec.folder = folder;
      if(gv("af-provider")) rec.provider = gv("af-provider");
      if(gv("af-model").trim()) rec.model = gv("af-model").trim();
      if(gv("af-permmode")) rec.permMode = gv("af-permmode");
      if(gv("af-role").trim()) rec.role = gv("af-role").trim();
      if(gv("af-goal").trim()) rec.goal = gv("af-goal").trim();
      if(gv("af-backstory").trim()) rec.backstory = gv("af-backstory");
      if(gv("af-seed").trim()) rec.seedPrompt = gv("af-seed");
      var sk = Object.keys(afSkills); if(sk.length) rec.skills = sk;
      var mc = Object.keys(afMcp); if(mc.length) rec.mcpServers = mc;
      var kn = aeListRead("knowledge"); if(kn.length) rec.knowledge = kn;
      var pl = aeListRead("plugins"); if(pl.length) rec.plugins = pl;
      var gl = aeListRead("globs"); if(gl.length) rec.folderGlobs = gl;
      if(gv("af-bundle")) rec.policyBundle = gv("af-bundle");
      if(AGENTS_ED.some(function(p){ return p.name === name && p.name !== aeEditing; })){
        if(!confirm('An agent named "'+name+'" already exists — overwrite it?')) return;
      }
      if(aeEditing && aeEditing !== name) rec.oldName = aeEditing;  // server renames + carries hidden fields
      send("agent-ed-save", "", JSON.stringify(rec));
      aeEditing = null; agentEdFormHide();
    }
    // --- MCP registry surface ---
    function mcpEdOpen(){ document.getElementById("ae-body").style.display="none";
      document.getElementById("ae-form").classList.remove("show");
      document.getElementById("ae-mcp").classList.add("show"); mcpEdReset(); renderMcpList(); }
    function mcpEdBack(){ document.getElementById("ae-mcp").classList.remove("show"); document.getElementById("ae-body").style.display=""; }
    function renderMcpList(){
      var box = document.getElementById("ae-mcp-list"); box.innerHTML = "";
      if(!AE_MCP.length){ box.innerHTML = '<span class="n-dim">No MCP servers yet.</span>'; return; }
      AE_MCP.forEach(function(m){
        var row = document.createElement("div"); row.className = "ae-list-row";
        var info = document.createElement("span"); info.style.flex="1";
        info.textContent = m.id + " · " + m.transport + " · " + (m.command || m.url || "");
        row.appendChild(info);
        row.appendChild(mkRBtn("Edit", function(){ mcpEdEdit(m); }, ""));
        row.appendChild(mkRBtn("Delete", function(){ if(confirm('Delete MCP server "'+m.id+'"?')) send("mcp-ed-delete", m.id); }, "danger"));
        box.appendChild(row);
      });
    }
    function mcpFormSync(){ var t = gv("mf-transport");
      show("mf-cmd-wrap", t==="stdio"); show("mf-args-wrap", t==="stdio"); show("mf-url-wrap", t!=="stdio"); }
    function mcpEdReset(){ sv("mf-id",""); sv("mf-label",""); sv("mf-transport","stdio"); sv("mf-command","");
      sv("mf-args",""); sv("mf-url",""); sv("mf-tools",""); sv("mf-tokenenv",""); mcpFormSync(); }
    function mcpEdEdit(m){ sv("mf-id",m.id); sv("mf-label",m.label||""); sv("mf-transport",m.transport||"stdio");
      sv("mf-command",m.command||""); sv("mf-args",(m.args||[]).join(" ")); sv("mf-url",m.url||"");
      sv("mf-tools",(m.allowedTools||[]).join(" ")); sv("mf-tokenenv",m.authTokenEnv||""); mcpFormSync(); }
    function mcpEdSave(){
      var id = gv("mf-id").trim(); if(!id){ alert("MCP server needs an id."); return; }
      var rec = { id:id, transport:gv("mf-transport") };
      if(gv("mf-label").trim()) rec.label = gv("mf-label").trim();
      if(gv("mf-command").trim()) rec.command = gv("mf-command").trim();
      var args = gv("mf-args").trim(); if(args) rec.args = args.split(/\s+/);
      if(gv("mf-url").trim()) rec.url = gv("mf-url").trim();
      var tools = gv("mf-tools").trim(); if(tools) rec.allowedTools = tools.split(/\s+/);
      if(gv("mf-tokenenv").trim()) rec.authTokenEnv = gv("mf-tokenenv").trim();
      // Pre-validate the transport requirement (mirrors core.validateMcp) BEFORE
      // the optimistic mcpEdReset() below -- else a server-side reject would wipe
      // the form and lose the typed id/label/token (the agent form pre-checks too).
      if(rec.transport === "stdio" && !rec.command){ alert("stdio transport needs a command."); return; }
      if(rec.transport !== "stdio" && !rec.url){ alert(rec.transport + " transport needs a url."); return; }
      send("mcp-ed-save", "", JSON.stringify(rec));
      mcpEdReset();
    }

    // ---- L2 policy bundle / attachment editor (🛡) ----------------------------
    var PE_BUNDLES = {}, PE_ATTS = [], PE_STARTERS = {}, PE_ARMED = false;
    var peBundleEditing = null;   // bundle name being edited, or null for new
    var peAttEditing = null;      // 0-based attachment index being edited, or null

    function openPolicyEd(){ send("open-policy-editor"); peBundleHide(); peAttHide();
      document.getElementById("policyed").classList.add("show"); }
    function closePolicyEd(){ document.getElementById("policyed").classList.remove("show"); }
    function ccPolicyEd(o){
      o = o || {};
      PE_BUNDLES = o.bundles && !Array.isArray(o.bundles) ? o.bundles : {};
      PE_ATTS = Array.isArray(o.attachments) ? o.attachments : [];
      PE_STARTERS = o.starters && !Array.isArray(o.starters) ? o.starters : {};
      PE_ARMED = !!o.armed;
      renderPolicyEd();
    }
    function bundleNames(){ return Object.keys(PE_BUNDLES).sort(); }
    function renderPolicyEd(){
      var warn = document.getElementById("pe-warn");
      if(!PE_ARMED){ warn.textContent = "Headless approvals are NOT armed — bundles are only ENFORCED while the gate is armed (⚙ Settings). They still resolve + show here."; warn.classList.add("show"); }
      else warn.classList.remove("show");
      // bundles
      var bb = document.getElementById("pe-bundles"); bb.innerHTML = "";
      var names = bundleNames();
      if(!names.length){ var e=document.createElement("div"); e.className="pe-empty"; e.textContent="No bundles yet. “+ New bundle”, or copy a starter above."; bb.appendChild(e); }
      names.forEach(function(name){
        var b = PE_BUNDLES[name] || {};
        var row = document.createElement("div"); row.className = "pe-row";
        var main = document.createElement("div"); main.className = "pe-main";
        var nm = document.createElement("div"); nm.className = "pe-name"; nm.textContent = name; main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "pe-sub";
        if(b.autoDeny && b.autoDeny.length){ var bd=document.createElement("span"); bd.className="pe-badge deny"; bd.textContent="deny "+b.autoDeny.length; sub.appendChild(bd); }
        if(b.autoAllow && b.autoAllow.length){ var ba=document.createElement("span"); ba.className="pe-badge allow"; ba.textContent="allow "+b.autoAllow.length; sub.appendChild(ba); }
        if(b.gateTools){ var bg=document.createElement("span"); bg.className="pe-badge"; bg.textContent="gate: "+b.gateTools; sub.appendChild(bg); }
        if(b.autopilot){ var bp=document.createElement("span"); bp.className="pe-badge"; bp.textContent="autopilot"; sub.appendChild(bp); }
        if(b.disableGlobal){ var bx=document.createElement("span"); bx.className="pe-badge"; bx.textContent="disableGlobal"; sub.appendChild(bx); }
        if(b.lockedPermMode){ var bl=document.createElement("span"); bl.className="pe-badge"; bl.textContent="lock:"+b.lockedPermMode; sub.appendChild(bl); }
        if(b.toolLimits){ var lk=Object.keys(b.toolLimits); if(lk.length){ var bt=document.createElement("span"); bt.className="pe-badge"; bt.textContent="limits "+lk.length; sub.appendChild(bt); } }
        var det=document.createElement("span"); det.textContent = " " + ((b.autoDeny||[]).concat(b.autoAllow||[]).slice(0,4).join(", "));
        sub.appendChild(det);
        main.appendChild(sub); row.appendChild(main);
        var acts = document.createElement("div"); acts.className = "pe-acts";
        acts.appendChild(mkRBtn("Edit", function(){ peBundleOpen(name); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ peBundleDelete(name); }, "danger"));
        row.appendChild(acts); bb.appendChild(row);
      });
      // attachments (ordered)
      var ab = document.getElementById("pe-atts"); ab.innerHTML = "";
      if(!PE_ATTS.length){ var e2=document.createElement("div"); e2.className="pe-empty"; e2.textContent="No attachments. Without one, a session uses the fleet policy unless you attach a bundle from its detail panel."; ab.appendChild(e2); }
      PE_ATTS.forEach(function(at, i){
        var row = document.createElement("div"); row.className = "pe-row";
        var main = document.createElement("div"); main.className = "pe-main";
        var nm = document.createElement("div"); nm.className = "pe-name"; nm.textContent = (i+1) + ". → " + (at.bundle||"(none)"); main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "pe-sub";
        var m = at.match || {}; var parts = [];
        ["project","group","providerId","key"].forEach(function(k){ if(m[k]) parts.push(k+"="+m[k]); });
        sub.textContent = parts.length ? parts.join("  ") : "matches ANY session";
        main.appendChild(sub); row.appendChild(main);
        var acts = document.createElement("div"); acts.className = "pe-acts";
        acts.appendChild(mkRBtn("▲", function(){ peAttMove(i,-1); }, ""));
        acts.appendChild(mkRBtn("▼", function(){ peAttMove(i, 1); }, ""));
        acts.appendChild(mkRBtn("Edit", function(){ peAttOpen(i); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ if(confirm("Delete attachment #"+(i+1)+"?")) send("policy-att-delete", String(i+1)); }, "danger"));
        row.appendChild(acts); ab.appendChild(row);
      });
      document.getElementById("pe-info").textContent = names.length + " bundle" + (names.length===1?"":"s") + " · " + PE_ATTS.length + " attachment" + (PE_ATTS.length===1?"":"s");
    }
    // --- bundle form ---
    function peBundleShow(){ document.getElementById("pe-bform").classList.add("show"); }
    function peBundleHide(){ document.getElementById("pe-bform").classList.remove("show"); }
    function peBundleReset(){ sv("bf-name",""); sv("bf-deny",""); sv("bf-allow",""); sv("bf-gate","");
      sv("bf-lockmode",""); sv("bf-limits",""); document.getElementById("bf-autopilot").checked=false; document.getElementById("bf-disable").checked=false; }
    function peBundleNew(){ peBundleEditing=null; peBundleReset(); peAttHide(); peBundleShow(); }
    function peBundleCancel(){ peBundleHide(); }
    function peBundleOpen(name){
      peBundleEditing=name; peBundleReset(); peAttHide();
      var b = PE_BUNDLES[name] || {};
      sv("bf-name",name); sv("bf-deny",(b.autoDeny||[]).join("\n")); sv("bf-allow",(b.autoAllow||[]).join("\n"));
      sv("bf-gate", b.gateTools||""); setSelect("bf-lockmode", b.lockedPermMode||"");
      sv("bf-limits", b.toolLimits ? Object.keys(b.toolLimits).map(function(k){ return k+"="+b.toolLimits[k]; }).join(" ") : "");
      document.getElementById("bf-autopilot").checked = !!b.autopilot;
      document.getElementById("bf-disable").checked = !!b.disableGlobal;
      peBundleShow();
    }
    function peStarter(name){
      var s = PE_STARTERS[name]; if(!s){ alert("starter not available"); return; }
      peBundleEditing=null; peBundleReset();
      sv("bf-name", name); sv("bf-deny",(s.autoDeny||[]).join("\n")); sv("bf-allow",(s.autoAllow||[]).join("\n"));
      peAttHide(); peBundleShow();
    }
    function parseLimits(str){
      var m = {}; (str||"").trim().split(/\s+/).forEach(function(t){ if(!t) return;
        var kv = t.split("="); if(kv.length===2 && kv[0].trim() && kv[1].trim() && !isNaN(Number(kv[1]))) m[kv[0].trim()] = Number(kv[1]); });
      return m;
    }
    function splitLines(str){ return (str||"").split("\n").map(function(s){ return s.trim(); }).filter(Boolean); }
    function peBundleSave(){
      var name = gv("bf-name").trim(); if(!name){ alert("Bundle needs a name."); return; }
      if(Object.keys(PE_BUNDLES).some(function(n){ return n===name && n!==peBundleEditing; })){
        if(!confirm('A bundle named "'+name+'" already exists — overwrite it?')) return;
      }
      var rec = { name: name,
        autoDeny: splitLines(gv("bf-deny")), autoAllow: splitLines(gv("bf-allow")),
        gateTools: gv("bf-gate").trim(), lockedPermMode: gv("bf-lockmode"),
        toolLimits: parseLimits(gv("bf-limits")),
        autopilot: document.getElementById("bf-autopilot").checked,
        disableGlobal: document.getElementById("bf-disable").checked };
      if(peBundleEditing && peBundleEditing !== name) rec.oldName = peBundleEditing;
      send("policy-bundle-save", "", JSON.stringify(rec));
      peBundleEditing=null; peBundleHide();
    }
    function peBundleDelete(name){
      var used = PE_ATTS.filter(function(a){ return a.bundle===name; }).length;
      var msg = 'Delete bundle "'+name+'"?' + (used ? ("\n"+used+" attachment(s) reference it and will then point at a missing bundle.") : "");
      if(confirm(msg)) send("policy-bundle-delete", name);
    }
    // --- attachment form ---
    function peAttShow(){ populateAttBundleSelect(); document.getElementById("pe-aform").classList.add("show"); }
    function peAttHide(){ document.getElementById("pe-aform").classList.remove("show"); }
    function populateAttBundleSelect(){
      var sel = document.getElementById("af2-bundle"); sel.innerHTML = "";
      var names = bundleNames();
      if(!names.length){ var o=document.createElement("option"); o.value=""; o.textContent="(no bundles — create one first)"; sel.appendChild(o); return; }
      names.forEach(function(n){ var o=document.createElement("option"); o.value=n; o.textContent=n; sel.appendChild(o); });
    }
    function peAttReset(){ sv("af2-project",""); sv("af2-group",""); sv("af2-provider",""); sv("af2-key",""); }
    function peAttNew(){ peAttEditing=null; peAttReset(); peBundleHide(); peAttShow(); }
    function peAttCancel(){ peAttHide(); }
    function peAttOpen(i){
      peAttEditing=i; peAttReset(); peBundleHide();
      var at = PE_ATTS[i] || {}; var m = at.match || {};
      sv("af2-project", m.project||""); sv("af2-group", m.group||""); sv("af2-provider", m.providerId||""); sv("af2-key", m.key||"");
      peAttShow(); setSelect("af2-bundle", at.bundle||"");
    }
    function peAttSave(){
      var bundle = gv("af2-bundle").trim();
      if(!bundle){ alert("Pick a bundle (create one first if the list is empty)."); return; }
      var rec = { bundle: bundle, match: {
        project: gv("af2-project").trim(), group: gv("af2-group").trim(),
        providerId: gv("af2-provider").trim(), key: gv("af2-key").trim() } };
      if(peAttEditing != null){ rec.index = peAttEditing + 1; send("policy-att-save", "", JSON.stringify(rec)); }
      else send("policy-att-add", "", JSON.stringify(rec));
      peAttEditing=null; peAttHide();
    }
    function peAttMove(i, dir){ send("policy-att-move", "", JSON.stringify({ index: i+1, dir: dir })); }

    // ---- L6 automation rules editor (⚙️) -------------------------------------
    var RULES_ED = [], RULES_ON = false, rleEditing = null;
    function openRuleEd(){ send("open-rules-editor"); ruleEdHide();
      document.getElementById("ruleed").classList.add("show"); }
    function closeRuleEd(){ document.getElementById("ruleed").classList.remove("show"); }
    function ccRuleEd(list, on){ RULES_ED = list || []; RULES_ON = !!on; renderRuleEd(); }
    function renderRuleEd(){
      var warn = document.getElementById("re-warn");
      if(!RULES_ON){ warn.textContent = "The rule engine is OFF (rules.enabled in cc-config.json) — rules won't fire until you turn it on. They're listed/editable here regardless."; warn.classList.add("show"); }
      else warn.classList.remove("show");
      var body = document.getElementById("re-body"); body.innerHTML = "";
      if(!RULES_ED.length){ var e=document.createElement("div"); e.className="re-empty";
        e.textContent = "No rules yet. “+ New rule” reacts to a session edge (done/error/hung/loop/…) with a safe action (log/relabel/nudge/feed/continue).";
        body.appendChild(e); document.getElementById("re-info").textContent=""; return; }
      RULES_ED.forEach(function(r){
        var tr = r.trigger||{}, pr = r.processor||{};
        var row = document.createElement("div"); row.className = "re-row";
        var dot = document.createElement("div"); dot.className = "re-dot" + (r.enabled?" on":""); dot.title = r.enabled?"enabled":"disabled";
        dot.style.cursor="pointer"; dot.onclick = function(){ send("rule-ed-toggle", r.name, r.enabled?"false":"true"); };
        row.appendChild(dot);
        var main = document.createElement("div"); main.className = "re-main";
        var nm = document.createElement("div"); nm.className = "re-name"; nm.textContent = r.name; main.appendChild(nm);
        var sub = document.createElement("div"); sub.className = "re-sub";
        var bt=document.createElement("span"); bt.className="re-badge trig"; bt.textContent="on "+(tr.kind||"?"); sub.appendChild(bt);
        var bp=document.createElement("span"); bp.className="re-badge proc"; bp.textContent="do "+(pr.kind||"?"); sub.appendChild(bp);
        if(r.once){ var bo=document.createElement("span"); bo.className="re-badge"; bo.textContent="once"; sub.appendChild(bo); }
        var det = document.createElement("span");
        var m = tr.match||{}; var parts=[];
        ["project","group","sessionKey","provider"].forEach(function(k){ if(m[k]) parts.push(k+"="+m[k]); });
        det.textContent = (pr.text? ('“'+String(pr.text).slice(0,40)+'” ') : (pr.label? ('→ '+pr.label+' ') : "")) + (parts.length? ("· "+parts.join(" ")) : "· any session");
        sub.appendChild(det); main.appendChild(sub); row.appendChild(main);
        var acts = document.createElement("div"); acts.className = "re-acts";
        acts.appendChild(mkRBtn("Edit", function(){ ruleEdOpen(r); }, ""));
        acts.appendChild(mkRBtn(r.enabled?"Disable":"Enable", function(){ send("rule-ed-toggle", r.name, r.enabled?"false":"true"); }, ""));
        acts.appendChild(mkRBtn("Delete", function(){ if(confirm('Delete rule "'+r.name+'"?')) send("rule-ed-delete", r.name); }, "danger"));
        row.appendChild(acts); body.appendChild(row);
      });
      document.getElementById("re-info").textContent = RULES_ED.length + " rule" + (RULES_ED.length===1?"":"s");
    }
    function ruleEdProcSync(){
      var k = gv("rlf-proc");
      show("rlf-text-wrap", k==="log" || k==="nudge" || k==="feed");
      show("rlf-label-wrap", k==="relabel");
    }
    function ruleEdShow(){ document.getElementById("re-body").style.display="none";
      document.getElementById("re-form").classList.add("show"); ruleEdProcSync(); }
    function ruleEdHide(){ document.getElementById("re-form").classList.remove("show");
      document.getElementById("re-body").style.display=""; }
    function ruleEdReset(){
      sv("rlf-name",""); sv("rlf-trigger","done"); sv("rlf-proc","log");
      sv("rlf-m-project",""); sv("rlf-m-group",""); sv("rlf-m-key",""); sv("rlf-m-provider","");
      sv("rlf-text",""); sv("rlf-label","");
      document.getElementById("rlf-once").checked = true; document.getElementById("rlf-enabled").checked = true;
    }
    function ruleEdNew(){ rleEditing=null; ruleEdReset(); ruleEdShow(); }
    function ruleEdCancel(){ ruleEdHide(); }
    function ruleEdOpen(r){
      rleEditing = r.name; ruleEdReset();
      var tr=r.trigger||{}, pr=r.processor||{}, m=tr.match||{};
      sv("rlf-name", r.name); setSelect("rlf-trigger", tr.kind||"done"); setSelect("rlf-proc", pr.kind||"log");
      sv("rlf-m-project", m.project||""); sv("rlf-m-group", m.group||""); sv("rlf-m-key", m.sessionKey||""); sv("rlf-m-provider", m.provider||"");
      sv("rlf-text", pr.text||""); sv("rlf-label", pr.label||"");
      document.getElementById("rlf-once").checked = !!r.once;
      document.getElementById("rlf-enabled").checked = r.enabled !== false;
      ruleEdShow();
    }
    function ruleEdSave(){
      var name = gv("rlf-name").trim(); if(!name){ alert("Rule needs a name."); return; }
      var proc = gv("rlf-proc"), text = gv("rlf-text"), label = gv("rlf-label").trim();
      // pre-validate (mirror core.validateRule) so a reject doesn't strand the form
      if((proc==="nudge" || proc==="feed") && !text.trim()){ alert(proc+" needs text."); return; }
      if(proc==="relabel" && !label){ alert("relabel needs a new label."); return; }
      var match = {};
      var mp=gv("rlf-m-project").trim(), mg=gv("rlf-m-group").trim(), mk=gv("rlf-m-key").trim(), mv=gv("rlf-m-provider").trim();
      if(mp) match.project=mp; if(mg) match.group=mg; if(mk) match.sessionKey=mk; if(mv) match.provider=mv;
      var trigger = { kind: gv("rlf-trigger") };
      if(Object.keys(match).length) trigger.match = match;
      var processor = { kind: proc };
      if(proc==="relabel") processor.label = label; else if(proc!=="continue") processor.text = text;
      var rec = { name: name, enabled: document.getElementById("rlf-enabled").checked,
        once: document.getElementById("rlf-once").checked, trigger: trigger, processor: processor };
      if(RULES_ED.some(function(x){ return x.name===name && x.name!==rleEditing; })){
        if(!confirm('A rule named "'+name+'" already exists — overwrite it?')) return;
      }
      if(rleEditing && rleEditing !== name) rec.oldName = rleEditing;
      send("rule-ed-save", "", JSON.stringify(rec));
      rleEditing=null; ruleEdHide();
    }
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
      var shiftTab = document.getElementById("a-tab-shift"); if(shiftTab) shiftTab.classList.toggle("active", v === "shift");
      // The Shift report has its own window selector + no per-row filters/actions,
      // so hide the filter row + Review/Export/Purge footer while it's showing.
      var isShift = (v === "shift");
      document.getElementById("a-filters").style.display = isShift ? "none" : "";
      document.getElementById("a-foot").style.display = isShift ? "none" : "";
      if(isShift){ openShift(); return; }
      renderAudit();
    }
    // ---- 📋 Shift report (ops-only "what the fleet did") --------------------
    // Lua computes core.fleetStandup + core.standupMarkdown over the chosen window
    // and replies ccShift; we render the markdown in a <pre> (same as Timeline) so
    // the on-screen text and the Copy text can't diverge.
    var shiftWindow = "open", shiftMarkdown = "";
    function openShift(){
      document.getElementById("a-body").innerHTML = '<div class="s-help" style="margin-left:0;">Loading shift report…</div>';
      send("open-shift", "", JSON.stringify({ window: shiftWindow }));
    }
    function setShiftWindow(w){ shiftWindow = w; openShift(); }
    function shiftWinBtn(w, label){
      return '<button class="sh-win' + (shiftWindow === w ? ' active' : '') + '" onclick="setShiftWindow(\'' + w + '\')">' + esc(label) + '</button>';
    }
    function copyShift(){ if(shiftMarkdown) send("copy-text", "", shiftMarkdown); }
    window.ccShift = function(markdown, meta){
      if(auditView !== "shift") return;   // user switched tabs before the reply landed
      shiftMarkdown = markdown || "";
      if(meta && meta.window) shiftWindow = meta.window;
      var bar = '<div class="sh-wins">'
        + shiftWinBtn("open", "Since opened") + shiftWinBtn("8h", "Last 8h") + shiftWinBtn("24h", "Last 24h")
        + '<button class="sh-copy" onclick="copyShift()">Copy</button></div>';
      document.getElementById("a-body").innerHTML = bar + '<pre class="a-narr">' + esc(shiftMarkdown) + '</pre>';
    };
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
      if(pendingShiftView){ pendingShiftView = false; auditTab("shift"); }
      else if(focusView){ auditTab(focusView); }  // auditTab also re-renders
      else if(auditView === "shift"){ auditTab("rows"); }  // a normal open after Shift: restore filters/foot
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

    // ---- Toolbar views drawer (☰): collapses search/insights/audit/notify ---
    function toggleMenu(e){ if(e) e.stopPropagation();
      document.getElementById("toolmenu").classList.toggle("show"); }
    function closeMenu(){ var m = document.getElementById("toolmenu"); if(m) m.classList.remove("show"); }
    function menuPick(which){
      closeMenu();
      if(which === "search") toggleSearch();
      else if(which === "fsearch") openFleetSearch();
      else if(which === "insights") openInsights();
      else if(which === "audit") openAudit();
      else if(which === "routines") openRoutines();
      else if(which === "templates") openTplEditor();
      else if(which === "agents") openAgentEd();
      else if(which === "policies") openPolicyEd();
      else if(which === "rules") openRuleEd();
      else if(which === "shift"){ if(LEDGER_ON) openShiftReport(); }
      else if(which === "notify") openNotifications();
    }
    // Close the drawer on any click outside it (the button's onclick stops propagation,
    // so opening doesn't immediately re-close).
    document.addEventListener("click", function(e){
      var w = document.getElementById("menu-wrap");
      if(w && !w.contains(e.target)) closeMenu();
    });

    // ---- ⌨ Hotkey legend (bottom-right) -------------------------------------
    // HOTKEY_LEGEND is injected from Lua, built from the real HOTKEY_* bindings
    // (core.hotkeyLegend), so the displayed combos can't drift from what's bound.
    // Rendered via textContent only -- the content is operator constants, but
    // textContent keeps the no-untrusted-HTML discipline anyway.
    window.HOTKEY_LEGEND = __HOTKEY_LEGEND__;
    var keyhelpRendered = false;
    function renderKeyhelp(){
      var menu = document.getElementById("keymenu");
      menu.innerHTML = "";
      (window.HOTKEY_LEGEND || []).forEach(function(sec){
        var h = document.createElement("div"); h.className = "kh-sec";
        h.textContent = sec.title; menu.appendChild(h);
        (sec.rows || []).forEach(function(r){
          var row = document.createElement("div"); row.className = "kh-row";
          var c = document.createElement("span"); c.className = "kh-combo"; c.textContent = r.combo;
          var d = document.createElement("span"); d.className = "kh-desc"; d.textContent = r.desc;
          row.appendChild(c); row.appendChild(d); menu.appendChild(row);
        });
      });
    }
    function closeKeyhelp(){ var m = document.getElementById("keymenu"); if(m) m.classList.remove("show"); }
    function toggleKeyhelp(e){
      if(e) e.stopPropagation();
      var menu = document.getElementById("keymenu");
      var show = !menu.classList.contains("show");
      if(show && !keyhelpRendered){ renderKeyhelp(); keyhelpRendered = true; }
      menu.classList.toggle("show", show);
    }
    document.addEventListener("click", function(e){
      var w = document.getElementById("keyhelp-wrap");
      if(w && !w.contains(e.target)) closeKeyhelp();
    });
    document.addEventListener("keydown", function(e){
      if(e.key === "Escape" && document.getElementById("keymenu").classList.contains("show")) closeKeyhelp();
    });
    // Esc in the routine board: close the form first, then the overlay.
    document.addEventListener("keydown", function(e){
      if(e.key !== "Escape") return;
      var ov = document.getElementById("routines");
      if(!ov || !ov.classList.contains("show")) return;
      if(document.getElementById("r-form").classList.contains("show")){ routineFormHide(); }
      else { closeRoutines(); }
    });
    // Esc in the templates editor: close the form/versions view first, then the overlay.
    document.addEventListener("keydown", function(e){
      if(e.key !== "Escape") return;
      var ov = document.getElementById("tpleditor");
      if(!ov || !ov.classList.contains("show")) return;
      if(document.getElementById("te-form").classList.contains("show")){ tplEditFormHide(); }
      else if(document.getElementById("te-versions").classList.contains("show")){ tplVersionsBack(); }
      else { closeTplEditor(); }
    });
    // Esc in the agents editor: close the form/MCP surface first, then the overlay.
    document.addEventListener("keydown", function(e){
      if(e.key !== "Escape") return;
      var ov = document.getElementById("agented");
      if(!ov || !ov.classList.contains("show")) return;
      if(document.getElementById("ae-form").classList.contains("show")){ agentEdFormHide(); }
      else if(document.getElementById("ae-mcp").classList.contains("show")){ mcpEdBack(); }
      else { closeAgentEd(); }
    });
    // Esc in the policy editor: close an open form first, then the overlay.
    document.addEventListener("keydown", function(e){
      if(e.key !== "Escape") return;
      var ov = document.getElementById("policyed");
      if(!ov || !ov.classList.contains("show")) return;
      if(document.getElementById("pe-bform").classList.contains("show")){ peBundleHide(); }
      else if(document.getElementById("pe-aform").classList.contains("show")){ peAttHide(); }
      else { closePolicyEd(); }
    });
    // Esc in the rules editor: close the form first, then the overlay.
    document.addEventListener("keydown", function(e){
      if(e.key !== "Escape") return;
      var ov = document.getElementById("ruleed");
      if(!ov || !ov.classList.contains("show")) return;
      if(document.getElementById("re-form").classList.contains("show")){ ruleEdHide(); }
      else { closeRuleEd(); }
    });

    // ---- Notification history (roadmap #6) ----------------------------------
    function openNotifications(){ send("open-notifications"); setNotifyBadge(0); }
    function setNotifyBadge(n){
      var txt = (n > 0) ? String(n > 99 ? "99+" : n) : "";
      // badge on the collapsed ☰ button (visible while closed) + the drawer's Notifications row
      ["notify-badge", "tm-notify-badge"].forEach(function(id){
        var b = document.getElementById(id); if(!b) return;
        b.textContent = txt;
        b.style.display = (n > 0) ? "inline-block" : "none";
      });
    }
    // The 📋 Shift report only exists when the audit ledger is on (it's pure
    // ledger aggregation -- nothing to show otherwise), so the refresh tick pokes
    // this on change to show/hide its tab + drawer row entirely. Live with the
    // Settings toggle; no reload needed. (Lineage self-gates: it just isn't
    // computed when the ledger is off, so no detail line / tile badge appears.)
    var LEDGER_ON = true;
    function setLedgerOn(on){
      LEDGER_ON = !!on;
      var tab = document.getElementById("a-tab-shift"); if(tab) tab.style.display = LEDGER_ON ? "" : "none";
      var row = document.getElementById("tm-shift");    if(row) row.style.display = LEDGER_ON ? "" : "none";
      if(!LEDGER_ON && auditView === "shift") auditTab("rows");  // ledger turned off mid-view
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
      du.style.display = "block";   // visibility gated by the parent .d-panel (Usage tab)
      var ps = (LAST_USAGE && LAST_USAGE.perSession) ? LAST_USAGE.perSession[it.key] : null;
      if(!ps){ du.innerHTML = '<div class="tl-empty">No token usage recorded for this session yet.</div>'; return; }
      var rows = '<div class="um-row"><span>Session total</span><span title="excl. cache reads; gross '+fmtTok(ps.total)+'">'+fmtTok(ps.real != null ? ps.real : ps.total)+'</span></div>'
        + '<div class="um-row"><span>output / input</span><span>'+fmtTok(ps.output)+' / '+fmtTok(ps.input)+'</span></div>';
      if(ps.byModel){ Object.keys(ps.byModel).forEach(function(m){
        rows += '<div class="um-row"><span>'+esc(m)+'</span><span>'+fmtTok(ps.byModel[m].total)+'</span></div>';
      }); }
      du.innerHTML = rows; du.style.display="block";
    }

    var PANEL_PROVIDERS = [];
    var PANEL_BUNDLES = [];   // L2 policy-bundle names (detail-panel Policy dropdown)
    var lastSelectedStatus = null;
    window.ccUpdate = function(items, providers, bundles){
      lastItems = items || [];
      if(providers !== undefined) PANEL_PROVIDERS = providers || [];
      if(bundles !== undefined) PANEL_BUNDLES = bundles || [];
      renderGrid();
      renderDetail();
      // Refresh the gate decision log exactly when the selected tile changes
      // status (a decision likely just landed) -- one cached-snapshot read per
      // transition, zero per tick.
      var sel = selectedKey ? findItem(selectedKey) : null;
      var st = sel ? (sel.status || "idle") : null;
      if(sel && lastSelectedStatus !== null && st !== lastSelectedStatus){
        requestDecisions(selectedKey);
        // A status edge likely just appended an event -- refresh the inline
        // Timeline too, but ONLY while that tab is the active view (still lazy:
        // a status change is an edge, not the 1s tick).
        if(detailTab === "timeline"){ TIMELINE = { key:null, events:null }; maybeLoadActiveTab(); }
      }
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
        meta = (it.error_reason && it.error_reason !== "unknown" ? "[" + it.error_reason.replace(/_/g," ") + "] " : "")
             + (it.error_message || "API error — stopped");
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
      if(it.looping){ meta = (meta ? meta + " · " : "") + "⟳ looping"; }   // L5 loop watchdog
      if(it.churn){ meta = (meta ? meta + " · " : "") + "♻️" + it.churn; }   // respawn/clear churn today
      var cls = "tile s-" + st + (it.stale ? " stale" : "") + (it.collide ? " collide" : "") + (it.hung ? " hung" : "") + (it.escalate ? " escalate" : "") + (it.key === selectedKey ? " sel" : "");
      return '<div class="'+cls+'" data-key="'+esc(it.key)+'" onclick="selectTile(\''+esc(it.key)+'\')" ondblclick="send(\'focus\',\''+esc(it.key)+'\')" oncontextmenu="showCtx(event,\''+esc(it.key)+'\')" title="Double-click to jump · right-click for more">'
           + '<span class="dot"></span>'
           + '<span class="name">'+esc(it.label || it.autoTitle || it.name)+(it.group ? ' <span class="gtag">🏷 '+esc(it.group)+'</span>' : '')+'</span>'
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
  <div id="keyhelp-wrap">
    <button id="keyhelp-btn" onclick="toggleKeyhelp(event)" title="Keyboard shortcuts">⌨</button>
    <div id="keymenu"></div>
  </div>
</body></html>
]]

-- Apply the saved theme (or default) to the markup before showing.
local savedTheme = hs.settings.get("ccDashboardTheme") or DEFAULT_THEME
HTML = HTML:gsub("__INIT_THEME__", savedTheme)
-- Inject the bulk-action targeting rules so the panel JS shares cc-core's single
-- source of truth (the bulk-bar count can't drift from what selectActionable acts on).
HTML = HTML:gsub("__BULK_RULES__", hs.json.encode(core.BULK_RULES))
-- Inject the L5 detail-panel tab list so the strip shares core.DETAIL_TABS (the
-- normalizeTabState mirror + per-tab dispatch can't drift from the canonical ids).
HTML = HTML:gsub("__DETAIL_TABS__", (hs.json.encode(core.DETAIL_TABS):gsub("%%", "%%%%")))
-- Inject the ⌨ hotkey legend, sourced from the real HOTKEY_* bindings (so the
-- displayed combos can't drift from what's actually bound) via core.hotkeyLegend.
local legendGlobals = {
  { mods = HOTKEY_APPROVE_FRONT[1], key = HOTKEY_APPROVE_FRONT[2], desc = "Approve the front-most pending approval" },
  { mods = HOTKEY_JUMP_NEEDY[1],    key = HOTKEY_JUMP_NEEDY[2],    desc = "Jump to the session that most needs you (approval › error › stalled)" },
  { mods = HOTKEY_CYCLE[1],         key = HOTKEY_CYCLE[2],         desc = "Jump to the next session" },
  { mods = HOTKEY_SPAWN[1],         key = HOTKEY_SPAWN[2],         desc = "Spawn a new Claude session" },
  { mods = HOTKEY_TOGGLE[1],        key = HOTKEY_TOGGLE[2],        desc = "Show / hide this panel" },
}
local legendPanel = {
  { combo = "Enter",  desc = "Send the nudge to the selected session" },
  { combo = "⇧Enter", desc = "New line in the nudge box" },
  { combo = "Esc",    desc = "Close the open overlay or popup" },
}
-- gsub treats % in the replacement specially; escape any in the JSON (defensive --
-- the legend is constant text, but keeps the substitution faithful regardless).
local legendJson = hs.json.encode(core.hotkeyLegend(legendGlobals, legendPanel)):gsub("%%", "%%%%")
HTML = HTML:gsub("__HOTKEY_LEGEND__", legendJson)
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
PANEL_START_TS = FX.now()  -- anchor the Shift report's "since opened" window
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

-- L6: run the OPT-IN event-callback rules for an edge on a tile. Sequential -- every
-- matching rule (cc-core orders them) runs; a `once` rule fires at most once per
-- (rule, tile) via ruleFired. Processors map onto existing SAFE effects: log -> a
-- ledger note, relabel -> setLabel, nudge -> the delivery-gated nudge path. Each fire
-- ledgers a by:"rule" event. ruleSet is loaded once per refresh (off unless rules.enabled).
local function runRules(ruleSet, it, edgeKind)
  if not ruleSet or #ruleSet == 0 then return end
  for _, r in ipairs(core.rulesForEdge(ruleSet, edgeKind, it)) do
    local mark = r.name .. "\1" .. tostring(it.key)
    if not (r.once and ruleFired[mark]) then
      if r.once then ruleFired[mark] = true end
      local p = r.processor or {}
      if p.kind == "log" then
        ledgerFor(it, { type = "rule", rule = r.name, kind = edgeKind, by = "rule",
                        processor = "log", note = p.text })
      elseif p.kind == "relabel" and p.label and p.label ~= "" then
        local lkey = it.projectKey or it.cwd
        if lkey then
          labels = core.setLabel(labels, lkey, p.label, it.name); FX.saveLabels(labels); it.label = p.label
        end
        ledgerFor(it, { type = "rule", rule = r.name, kind = edgeKind, by = "rule",
                        processor = "relabel", to = p.label })
      elseif p.kind == "nudge" and p.text and p.text ~= "" then
        local target = it
        dispatchSerialized(target, "rule-nudge", function()
          local acted = core.handleAction(FX, target, "nudge", p.text)
          ledgerFor(target, { type = "rule", rule = r.name, kind = edgeKind, by = "rule",
                              processor = (acted == "nudge") and "nudge" or "nudge_skipped",
                              text = tostring(p.text):sub(1, 200) })
        end)
      elseif p.kind == "feed" and p.text and p.text ~= "" then
        -- Enqueue a task onto the tile's queue; the existing auto-feed delivers it
        -- when the session next reaches done/idle (no direct keystroke). Resolve the
        -- key EXACTLY as the reader does -- FX.queueKeyFor -> core.queueKey SANITIZES
        -- it (a raw projectKey/cwd has slashes, which both break the write path and
        -- diverge from the key auto-feed/router read; review-caught silent data loss).
        local qk = FX.queueKeyFor(it)
        if qk then
          FX.writeQueue(qk, core.queuePush(FX.readQueue(qk), tostring(p.text)))
          ledgerFor(it, { type = "rule", rule = r.name, kind = edgeKind, by = "rule",
                          processor = "feed", text = tostring(p.text):sub(1, 200) })
        end
      elseif p.kind == "continue" then
        -- Resume an errored/stuck session by typing "continue" (delivery-gated,
        -- same path as the manual Continue button + Auto-Continue).
        local target = it
        dispatchSerialized(target, "rule-continue", function()
          local acted = core.handleAction(FX, target, "continue")
          ledgerFor(target, { type = "rule", rule = r.name, kind = edgeKind, by = "rule",
                              processor = (acted == "continue") and "continue" or "continue_skipped" })
        end)
      end
    end
  end
end

-- Push current statuses into the webview + deck; run queue auto-feed and
-- stale-approval escalation; keep the heartbeat fresh.
function refresh()
  local cfg = loadConfig()
  reconcileBridge(cfg)  -- SSH bridge timers track config (cheap diff per tick)
  local list = refreshList()
  -- Cohort tag (.group) MUST be applied before the routing dispatcher below: L4
  -- @role: routing matches a task's role against a member's GROUP, and routeGroups
  -- holds references to these same tiles. (Also feeds the filter chips, group-scoped
  -- bulk actions, and L2 attachment matching — all later in the tick.)
  core.applyGroups(list, groups)
  local autofeed   = core.config(cfg, "queue.autofeed", false) == true
  local queueDry   = core.config(cfg, "queue.dryRun", false) == true
  local routingOn  = core.config(cfg, "queue.routing.enabled", false) == true  -- 4c-E
  local autoTitleOn = core.config(cfg, "autoTitle.enabled", false) == true  -- L5 derived tile titles
  local loopOn      = core.config(cfg, "escalation.loop.enabled", false) == true  -- L5 loop watchdog
  local loopRepeats = tonumber(core.config(cfg, "escalation.loop.repeats", 3)) or 3
  local bannerOn    = (core.config(cfg, "notifications.banner.onApproval", false) == true)  -- L5 OS banners
                   or (core.config(cfg, "notifications.banner.onDone", false) == true)
  local rulesOn     = core.config(cfg, "rules.enabled", false) == true  -- L6 event-callback rules
  local ruleSet     = rulesOn and core.ruleList(FX.readRules()) or nil  -- loaded once per refresh
  local schedulesOn = core.config(cfg, "schedules.enabled", false) == true  -- L7 scheduled routines
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

  -- 📋 Session lineage: per-project respawn/clear/continue churn since local
  -- midnight, made legible on the tile + detail. One ledger pass per tick, cached
  -- like the 🔔 badge -- recompute only when the ledger changed or the day rolled.
  if ledgerOn then
    local dt = os.date("*t", now); dt.hour, dt.min, dt.sec = 0, 0, 0
    local midnight = os.time(dt)
    if ledgerChanged or lineageDayStart ~= midnight then
      lineageMap = core.lineageByProject(ledgerEvents, midnight)
      lineageDayStart = midnight
    end
  elseif next(lineageMap) ~= nil then
    lineageMap = {}; lineageDayStart = nil  -- ledger off: drop any stale annotations
  end

  for _, it in ipairs(list) do
    local pv = prev[it.key]  -- last refresh's snapshot for this tile (status/stale/escalated), or nil
    -- Lineage annotation: .lineage (one-line detail summary) + .churn (count) for
    -- the tile badge -- both omitted unless notable, like the other optional flags.
    local lin = it.projectKey and lineageMap[it.projectKey] or nil
    if lin then
      local summary = core.lineageSummary(lin)
      if summary then it.lineage = summary end
      local churn = (lin.autoRespawns or 0) + (lin.manualRespawns or 0)
                  + (lin.clears or 0) + (lin.continues or 0)
      if churn >= 2 then it.churn = churn end
    end
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
      if err then it.status = "error"; it.error_message = err.message; it.error_reason = err.reason end
    end

    -- L5 loop watchdog (off by default): flag a working session repeating the SAME
    -- tool call (e.g. re-running a failing command). Reuses the tail already read; a
    -- ⟳ tile badge + ONE ledger event per episode (reset when it stops). Detection only.
    if loopOn and tail and it.status == "working"
       and core.isLooping(core.transcriptToolSigs(tail, loopRepeats + 2), loopRepeats) then
      it.looping = true
      if not loopAlerted[it.key] then
        loopAlerted[it.key] = true
        if ledgerOn then ledgerFor(it, { type = "loop", repeats = loopRepeats }) end
        runRules(ruleSet, it, "loop")  -- L6 loop trigger (rising edge, once per episode)
      end
    else
      loopAlerted[it.key] = nil
    end

    -- L5 OS-native banner on a fresh rising edge into approval/done (off by default;
    -- gated by bannerOn so we don't even build the decision when disabled).
    if bannerOn and pv ~= nil then
      local nb = core.notifyDecision(pv.status, it, cfg)
      if nb then FX.notify(nb.title, nb.text, { key = it.key }) end
    end

    -- L6 event-callback rules on a FRESH status edge (done/error/approval). pv==nil
    -- (post-reload) is no edge. Off unless rules.enabled (ruleSet is nil otherwise).
    if ruleSet and pv ~= nil and it.status ~= pv.status
       and (it.status == "done" or it.status == "error" or it.status == "approval") then
      runRules(ruleSet, it, it.status)
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

    -- L5 error-reason taxonomy: ledger the CAUSE once, on the fresh transition into
    -- the error state (errors-by-cause shows up in the audit timeline + search). pv==nil
    -- (post-reload) is no edge, so a reload can't re-ledger every frozen tile.
    if ledgerOn and it.status == "error" and pv ~= nil and pv.status ~= "error" then
      ledgerFor(it, { type = "error", reason = it.error_reason or "unknown",
                      message = it.error_message })
    end

    -- L4 per-task timing: a fed queue task finishes on its first done edge -- ledger
    -- the duration + role, then clear the marker (the autofeed below may re-stamp the
    -- next task). Fires before drain/feed so a completing task is always recorded.
    local started = taskStart[it.key]
    if started then
      if it.stale then
        taskStart[it.key] = nil  -- abandon: a frozen session's in-flight task can't be timed
      else
        local td = core.stepTaskDone(started, pv and pv.status, it.status, now)
        if td then
          ledgerFor(it, { type = "task_done", durationS = td.durationS,
                          role = started.role, by = started.by or "queue" })
          taskStart[it.key] = nil
        end
      end
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
    it.routeSeq = (core.queueRouteMode(q) == "sequential") or nil  -- L4 process mode
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
          local commit = core.queueFeedCommit(FX.feedTask(winTarget(it), renderFeed(task, it)))
          if commit.persist then
            FX.writeQueue(qk, q2)
            it.queue = core.queueDepth(q2)
            stampTaskStart(it, task, "autofeed")
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
        runRules(ruleSet, it, "hung")  -- L6 hung trigger (rising edge, once per stall)
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
      ledgerFor(it, { type = "auto_respawn", outcome = "ok", cwd = rs.project, editor = rs.editor,
        provider = rs.providerId, attempt = step.attempts })
      -- rs.providerId=nil = faithful bare claude: "" (explicit none) so the relaunch
      -- can't silently pick up the spawn.provider default gateway.
      FX.spawnSession(rs.editor, rs.project, nil, rs.permissionMode, rs.providerId or "")
      FX.removeStatus(it.key)  -- drop the dead tile; the relaunch makes a fresh one
    elseif step.wouldFire and rs and not rs.canRespawn then
      -- L6: a death that WOULD auto-respawn but can't -- previously a silent print.
      -- Ledger it once (the edge is debounced by stepAutoRespawn) so "failed
      -- automations" are auditable, carrying why (rs.reason).
      print("[cc-respawn] " .. tostring(it.name) .. " died but isn't respawnable: " .. tostring(rs.reason))
      if ledgerOn then ledgerFor(it, { type = "auto_respawn_blocked", outcome = "skipped",
        reason = tostring(rs.reason or "not respawnable") }) end
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
      -- L6: ledger INSIDE the serialized closure so the outcome reflects DELIVERY
      -- (handleAction returns "continue" only when the keystroke actually landed).
      local ct = it
      dispatchSerialized(ct, "continue", function()
        local acted = core.handleAction(FX, ct, "continue")
        ledgerFor(ct, { type = "auto_continue", attempt = cstep.attempts,
                        outcome = (acted == "continue") and "ok" or "skipped" })
      end)
    end

    newPrev[it.key] = { status = it.status, stale = step.isStale, escalated = nowEsc }
  end
  prev = newPrev
  -- Reap per-task timers whose session vanished from the fleet (pruned / respawned /
  -- removeStatus) without a done edge -- the loop above only visits live tiles, so a
  -- gone key would leak forever (mirrors the usageState seen-set reap).
  for k in pairs(taskStart) do if not newPrev[k] then taskStart[k] = nil end end
  for k in pairs(loopAlerted) do if not newPrev[k] then loopAlerted[k] = nil end end
  -- ruleFired keys are "ruleName\1tileKey"; reap when the tile vanishes (L6 once-state)
  for k in pairs(ruleFired) do local tk = k:match("\1(.*)$"); if tk and not newPrev[tk] then ruleFired[k] = nil end end

  -- L7 scheduled routines (off unless schedules.enabled): fire each due routine
  -- through the NORMAL spawn fx (which itself respects spawn.live's dry-run). cc-core
  -- gates by minute + lastFiredAt so a routine fires at most once per matching minute;
  -- one-shots self-delete after firing; backpressure defers when the fleet is at cap.
  if schedulesOn then
    local sstate = FX.readSchedules()
    local due = core.dueSchedules(core.scheduleList(sstate), os.time())
    if #due > 0 then
      local cap = tonumber(core.config(cfg, "schedules.maxConcurrent", 0)) or 0
      local liveCount = #list
      for _, r in ipairs(due) do
        if r.action == "digest" then
          -- L7 periodic digest: push a fleet shift report over a window (the first
          -- concrete consumer of the scheduling primitive). No spawn -> no backpressure.
          print("[cc-sched] firing digest routine '" .. tostring(r.name) .. "'")
          local hours = tonumber(r.digestHours) or 24
          local report = core.fleetStandup(ledgerSnapshot(), { sinceTs = os.time() - hours * 3600 })
          local topic = (r.pushTopic and r.pushTopic ~= "") and r.pushTopic or escTopic
          if topic and topic ~= "" then
            FX.push(topic, "Claude Shepherd: shift report (" .. hours .. "h)",
              core.standupMarkdown(report, { windowLabel = hours .. "h" }):sub(1, 800))
          end
          if ledgerOn then ledgerFor({ name = r.name },
            { type = "schedule_fire", routine = r.name, kind = r.kind, action = "digest" }) end
          sstate = core.scheduleMarkFired(sstate, r.name, os.time())
        elseif core.scheduleBackpressure(liveCount, cap) then
          print("[cc-sched] backpressure (" .. liveCount .. "/" .. cap .. "): deferring '" .. tostring(r.name) .. "'")
        else
          print("[cc-sched] firing routine '" .. tostring(r.name) .. "' (" .. tostring(r.kind) .. ")")
          FX.spawnSession(r.editor or core.config(cfg, "spawn.editor", "terminal"),
            r.folder, r.prompt, r.permMode, r.provider or "")
          if ledgerOn then ledgerFor({ name = r.name, projectKey = r.folder, cwd = r.folder },
            { type = "schedule_fire", routine = r.name, kind = r.kind }) end
          liveCount = liveCount + 1
          sstate = core.scheduleMarkFired(sstate, r.name, os.time())
        end
      end
      FX.writeSchedules(sstate)
    end
  end

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
              local commit = core.queueFeedCommit(FX.feedTask(winTarget(item), renderFeed(task, item)))
              if commit.persist then
                FX.writeQueue(qk, q2)
                stampTaskStart(item, task, "router")
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
            runRules(ruleSet, members[1], "starved")  -- L6 starved trigger (rising edge, once per episode)
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
  -- Hand the fully-annotated list to the jump hotkey (it.hung / error status / sorted).
  lastRenderList = list

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

  -- Show/hide the 📋 Shift report UI (tab + drawer row) live with the ledger
  -- toggle -- it's pure ledger aggregation, so there's nothing to show when off.
  -- Poked only on change, like the notify badge.
  if ledgerOn ~= lastLedgerOn then
    lastLedgerOn = ledgerOn
    pcall(function() wv:evaluateJavaScript("setLedgerOn(" .. tostring(ledgerOn) .. ")") end)
  end

  FX.writeFile(HEARTBEAT, tostring(now))
  sd.blink = not sd.blink
  sdRender(list)
  -- Overlay persistent relabels by project path (display-only; .name stays the
  -- real target). A new session in a labeled folder inherits the name (F1).
  core.applyLabelsByCwd(list, labels)
  -- L5 auto-title (off by default): for an UNLABELED tile, derive a stable title from
  -- its first prompt and cache it per projectKey (computed once -- titles don't change).
  -- Runs after applyLabelsByCwd so it.label (the manual relabel) is known; precedence
  -- is manual relabel > auto-title > folder basename (the panel reads it.autoTitle).
  if autoTitleOn then
    local dirty = false
    for _, it in ipairs(list) do
      if (not it.label or it.label == "") and it.projectKey and it.projectKey ~= "" then
        local cached = autoTitles[it.projectKey]
        if type(cached) == "string" and cached ~= "" then
          it.autoTitle = cached
        elseif type(it.last_prompt) == "string" and it.last_prompt ~= "" then
          local title = core.deriveAutoTitle(it.last_prompt, 48)
          if title then autoTitles[it.projectKey] = title; it.autoTitle = title; dirty = true end
        end
      end
    end
    if dirty then FX.saveAutoTitles(autoTitles) end
  end
  -- (.group is applied earlier in the tick — see the comment after refreshList() —
  -- so the routing dispatcher can match @role: against a member's group.)

  -- L2: resolve each session's effective policy bundle (attachments apply
  -- fleet-wide; a per-session override wins) and CHANGE-GATED-write the per-session
  -- file the gate reads. Placed AFTER applyGroups so .group is available for
  -- attachment matching. The RESOLVE+WRITE half is gated to the no-cost case
  -- (skip when no attachments AND no overrides), but the ORPHAN SWEEP below runs
  -- UNCONDITIONALLY so removing the last attachment (or a session ending) always
  -- tears down its resolved file within a tick — the gate enforces that file
  -- authoritatively, so a stale one would keep auto-allowing/denying silently.
  do
    local attList = core.config(cfg, "policies.attachments", nil)
    local hasAtt = type(attList) == "table" and #attList > 0
    local hasOvr = false
    for _, n in ipairs(FX.readDir(POLICY_OVERRIDE_DIR)) do
      if n ~= "." and n ~= ".." then hasOvr = true; break end
    end
    local wrote = {}  -- keys (re)written this tick; everything else on disk is stale
    if hasAtt or hasOvr then
      for _, it in ipairs(list) do
        if it.key and not it.remote then
          local ovr = FX.policyOverride(it.key)
          local prov = core.providerByModel(cfg, it.model, it.base_url)
          local resolved = core.resolvePolicy(cfg,
            { project = it.projectKey, projectKey = it.projectKey, group = it.group,
              providerId = prov and prov.id or nil, key = it.key },
            (ovr and ovr ~= "") and ovr or nil)
          it.policy_override = ovr
          it.policy_bundle = resolved.bundle
          if resolved.source ~= "fleet" then
            local enc = core.json.encode({ autoAllow = resolved.autoAllow,
              autoDeny = resolved.autoDeny, bundle = resolved.bundle })
            if policyCache[it.key] ~= enc then
              FX.writeResolvedPolicy(it.key, enc); policyCache[it.key] = enc
            end
            wrote[it.key] = true
          end
        end
      end
    end
    -- Sweep: any resolved-policy file NOT (re)written this tick is stale — its
    -- attachment was removed, its per-session override was cleared, or the session
    -- ended. One readDir/tick; in the clean case the dir is empty (no-op). Decoupled
    -- from hasAtt/hasOvr so a removed attachment can't leave an enforcing orphan.
    for _, n in ipairs(FX.readDir(POLICY_DIR)) do
      if n ~= "." and n ~= ".." and not n:find("%.tmp%.", 1, false) and not wrote[n] then
        FX.clearResolvedPolicy(n); policyCache[n] = nil
      end
    end
  end

  local payload = (#list == 0) and "[]" or hs.json.encode(list)
  local provs = core.config(cfg, "providers", nil)  -- reuse the cfg loaded above
  local provJson = (type(provs) == "table") and hs.json.encode(provs) or "[]"
  local bundleNames = {}
  for name in pairs(core.policyBundles(cfg)) do bundleNames[#bundleNames + 1] = name end
  table.sort(bundleNames)
  local bundleJson = hs.json.encode(bundleNames)
  wv:evaluateJavaScript("window.ccUpdate(" .. payload .. ", " .. provJson .. ", " .. bundleJson .. ")")

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
    local it = selector(lastRenderList or refreshList())
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
      hotkeyAct("jump-priority", function(l) return core.nextAttention(l) or core.frontSession(l) end,
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
autoTitles = FX.loadAutoTitles()

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
