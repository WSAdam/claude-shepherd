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

-- A STABLE per-launch-folder identity for a session, used to key persistent
-- labels. `cwd` drifts as the agent cd's around, so it's unusable as a label key;
-- transcript_path encodes the session's LAUNCH directory (…/projects/<ENCODED>/…)
-- and never changes, so the <ENCODED> segment is stable and shared by every
-- session launched from that folder. Falls back to cwd when there's no transcript.
function M.projectKey(data)
  local tp = data and data.transcript_path
  local enc = type(tp) == "string" and tp:match("/projects/([^/]+)/[^/]+%.jsonl$")
  return (enc and enc ~= "") and enc or (data and data.cwd) or nil
end

-- Decode each {key=, content=} status entry, tag it with key + stale flag, drop
-- malformed/nameless ones, and return the list sorted approvals-first.
function M.parseStatusList(entries, now, staleSeconds)
  staleSeconds = staleSeconds or M.STALE_SECONDS
  local list = {}
  for _, e in ipairs(entries or {}) do
    local okj, data = pcall(function() return M.json.decode(e.content) end)
    if okj and type(data) == "table" and data.name then
      data.key = e.key
      data.projectKey = M.projectKey(data)
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
  elseif action == "model" then
    -- Switch model live via the `/model <id>` slash command. Works within the
    -- session's current backend (Claude tiers, or models the gateway serves); a
    -- different base URL still needs a fresh session (relaunch), not /model.
    local cmd = M.modelCommand(text)
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

-- Build the `/model <id>` slash command to switch model live within a session
-- (same provider only -- a base-URL change needs a relaunch). nil for an empty id.
function M.modelCommand(id)
  id = tostring(id or "")
  if id == "" then return nil end
  return "/model " .. id
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

-- Apply PERSISTENT display labels onto a session list, in place. Keyed by the
-- session's stable projectKey (the launch folder, immune to cd drift) so the
-- label sticks for the life of the session and a brand-new session in the same
-- folder inherits it (survives close/reopen). Legacy entries keyed by the live
-- cwd still resolve via the fallback. Like applyLabels, only .label is set.
function M.applyLabelsByCwd(list, labelsByKey)
  labelsByKey = labelsByKey or {}
  for _, it in ipairs(list or {}) do
    it.label = (it.projectKey and labelsByKey[it.projectKey])
            or (it.cwd and labelsByKey[it.cwd])   -- legacy cwd-keyed entries
            or nil
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

-- ---- Improve button (leaderboard improvement cards) ------------------------

-- Parse `git remote get-url origin` output down to "owner/repo" -- mirrors the sed
-- in the /improve command: strip a git@host: or https://host/ prefix and .git suffix.
function M.repoFromRemote(url)
  url = tostring(url or ""):gsub("%s+", "")
  -- ssh://[user@]host[:port]/owner/repo(.git): strip the scheme+authority first, so
  -- what's left (owner/repo) flows through the same scp/https handling below.
  url = url:gsub("^ssh://[^/]+/", "")
  return (url:gsub("^git@[^:]+:", ""):gsub("^https?://[^/]+/", ""):gsub("%.git$", ""))
end

-- Build the review-first prompt for the Improve button from claimed leaderboard
-- cards (each a table with .text, or a plain string). Deliberately asks for
-- SUGGESTIONS and a plan, never wholesale application -- the user approves first.
function M.improvePrompt(cards)
  cards = cards or {}
  local lines = {}
  for i, c in ipairs(cards) do
    lines[#lines + 1] = i .. ". " .. tostring((type(c) == "table" and c.text) or c)
  end
  return "We pulled " .. #cards .. " reflected improvement insight(s) from our most "
    .. "recent push (now claimed on the leaderboard). Review the reflected improvements "
    .. "from our recent commit and give suggestions where applicable for applying these "
    .. "improvements to our code. Do NOT apply them wholesale -- for each, assess it "
    .. "against our actual code, say whether it's worth doing and why, and propose the "
    .. "specific minimal change. Present it as a plan for me to approve before any edits."
    .. "\n\nInsights:\n" .. table.concat(lines, "\n")
end

-- ---- Audit/event ledger (pure parse/filter/retention + narrative) ----------
-- The ledger is append-only JSONL (one event object per line) written by the shell
-- hooks (cc-status.sh / cc-approve.sh) and the dashboard. These helpers parse and
-- shape it for the audit view + the on-demand LLM review. All pure: I/O (read /
-- append / atomic rewrite / expire) lives in the dashboard's FX layer.

-- Parse ledger JSONL text into a list of event tables. Tolerant of blank/partial
-- lines (same `^%s*{` guard as transcriptSnippet); keeps only objects carrying both
-- `ts` and `type`, so junk and partial tails never reach the view.
function M.parseLedger(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:find("^%s*{") then
      local okj, ev = pcall(function() return M.json.decode(line) end)
      if okj and type(ev) == "table" and ev.ts and ev.type then out[#out + 1] = ev end
    end
  end
  return out
end

-- Filter + sort (newest first) a list of events. opts = { session, sinceTs, untilTs,
-- types }. `types` may be a set ({decision=true}) or a list ({"decision",...}); empty
-- or nil means all. `session` matches session_id (the reliable cross-writer key).
function M.filterLedger(events, opts)
  opts = opts or {}
  local typeset
  if type(opts.types) == "table" then
    typeset = {}
    if #opts.types > 0 then
      for _, t in ipairs(opts.types) do typeset[t] = true end
    else
      for k, v in pairs(opts.types) do if v then typeset[k] = true end end
    end
    if next(typeset) == nil then typeset = nil end
  end
  local out = {}
  for _, e in ipairs(events or {}) do
    local ok = true
    if opts.session and e.session_id ~= opts.session then ok = false end
    if ok and opts.sinceTs and (tonumber(e.ts) or 0) < opts.sinceTs then ok = false end
    if ok and opts.untilTs and (tonumber(e.ts) or 0) > opts.untilTs then ok = false end
    if ok and typeset and not typeset[e.type] then ok = false end
    if ok then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return (tonumber(a.ts) or 0) > (tonumber(b.ts) or 0) end)
  return out
end

-- A daily ledger filename ("YYYY-MM-DD.jsonl") -> epoch seconds at 00:00:00Z that
-- day, reusing isoToEpoch so there's ONE civil-date implementation (matches the UTC
-- file naming in FX.appendLedger). nil if the name isn't a daily ledger file.
function M.ledgerFileEpoch(filename)
  local y, mo, d = tostring(filename or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%.jsonl$")
  if not y then return nil end
  return M.isoToEpoch(y .. "-" .. mo .. "-" .. d .. "T00:00:00Z")
end

-- Which daily files are past the retention window (older than retentionDays before
-- `now`). retentionDays <= 0 means "keep forever" -> {}. `now` is injected (pure).
function M.expiredLedgerFiles(filenames, now, retentionDays)
  local out = {}
  local days = tonumber(retentionDays) or 0
  if days <= 0 then return out end
  local cutoff = (tonumber(now) or 0) - days * 86400
  for _, fn in ipairs(filenames or {}) do
    local ep = M.ledgerFileEpoch(fn)
    if ep and ep < cutoff then out[#out + 1] = fn end
  end
  return out
end

-- Event-type -> (emoji, verb) for the human narrative. `decision` picks its emoji
-- from the outcome below, so its entry here is unused.
local NARRATE = {
  session_start = { "🟢", "session started" },
  session_end   = { "⚪", "session ended" },
  prompt        = { "📝", "prompt" },
  tool_request  = { "🔧", "requested" },
  task_feed     = { "📥", "fed task" },
  mode_change   = { "🎚", "mode" },
  model_change  = { "🤖", "model" },
  effort_change = { "🎚", "effort" },
  clear         = { "🧹", "cleared conversation" },
  compact       = { "🗜", "compacted conversation" },
  nudge         = { "👉", "nudge" },
  autopilot_arm = { "🛫", "autopilot armed" },
  spawn         = { "✨", "spawned session" },
  relabel       = { "🏷", "relabeled" },
  redact        = { "🚫", "redacted an entry" },
  purge         = { "🗑", "purged entries" },
}

-- One human-readable line for an event (no timestamp/name; the caller adds those).
function M.narrateEvent(e)
  if type(e) ~= "table" then return "" end
  local t = e.type
  if t == "decision" then
    local emoji = (e.outcome == "deny") and "⛔" or "✅"
    local by = e.by and (" (" .. tostring(e.by)
      .. (e.pattern and (": " .. tostring(e.pattern)) or "") .. ")") or ""
    return emoji .. " " .. tostring(e.outcome or "?") .. " " .. tostring(e.tool or "")
      .. (e.summary and (' "' .. tostring(e.summary) .. '"') or "") .. by
  end
  local spec = NARRATE[t]
  local emoji = (spec and spec[1]) or "•"
  local verb = (spec and spec[2]) or tostring(t)
  local detail
  if t == "mode_change" or t == "model_change" or t == "effort_change" then
    detail = (e.from and (tostring(e.from) .. " → ") or "→ ") .. tostring(e.to or "?")
  elseif t == "tool_request" then
    detail = tostring(e.tool or "") .. (e.summary and (' "' .. tostring(e.summary) .. '"') or "")
  else
    detail = e.prompt or e.summary or e.task or e.message
  end
  return emoji .. " " .. verb .. (detail and (": " .. tostring(detail)) or "")
end

-- Render events as a chronological (oldest-first) narrative string, one line per
-- event: "YYYY-MM-DD HH:MM  <name>  <event>". Pure (os.date is plain-lua safe).
-- Used by BOTH the timeline view and the on-demand LLM review prompt.
function M.renderNarrative(events, opts)
  opts = opts or {}
  local list = {}
  for _, e in ipairs(events or {}) do list[#list + 1] = e end
  table.sort(list, function(a, b) return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0) end)
  local lines = {}
  for _, e in ipairs(list) do
    local when = e.ts and os.date("%Y-%m-%d %H:%M", tonumber(e.ts)) or "????-??-?? ??:??"
    local who = e.name or e.session_id or "?"
    lines[#lines + 1] = when .. "  " .. who .. "  " .. M.narrateEvent(e)
  end
  if #lines == 0 then return "(no activity in range)" end
  return table.concat(lines, "\n")
end

-- Wrap a rendered narrative in a review-first instruction for the on-demand LLM
-- review (pasted into a session, like the Improve button). opts.scope labels the
-- slice ("session proj", "all sessions"). Read-only by construction: never edits.
function M.auditReviewPrompt(narrative, opts)
  opts = opts or {}
  local scope = opts.scope or "the fleet"
  return "Below is an audit log of recent agent activity for " .. scope .. ", pulled "
    .. "from Claude Shepherd's ledger. Review it as a governance check: flag any risky "
    .. "or destructive actions, repeated or suspicious denials, and anything that looks "
    .. "off or unexplained, then summarize what actually happened. This is a READ-ONLY "
    .. "review — do not make any changes to code or files.\n\nActivity log:\n"
    .. tostring(narrative or "")
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
-- Truncate to at most maxBytes without splitting a multibyte UTF-8 char: back off
-- over trailing continuation bytes (0x80-0xBF) so the cut lands on a codepoint
-- boundary (otherwise the appended … can render after half a glyph).
local function utf8trunc(s, maxBytes)
  if #s <= maxBytes then return s end
  local cut = maxBytes
  while cut > 0 do
    local c = s:byte(cut + 1)
    if c and c >= 0x80 and c < 0xC0 then cut = cut - 1 else break end
  end
  return s:sub(1, cut)
end

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
          -- A whitespace-only block collapses to ""; skip it and keep scanning older
          -- lines instead of returning an empty snippet.
          if #txt > 0 then
            -- reserve 3 bytes for the … ellipsis so the result stays within maxLen,
            -- truncating on a UTF-8 boundary so we never split a multibyte glyph.
            if #txt > maxLen then txt = utf8trunc(txt, maxLen - 3) .. "\226\128\166" end
            return txt
          end
        end
      end
    end
  end
  return nil
end

-- ---- Token usage (local, ZERO-COST: parsed from transcript JSONL) ----------
-- Claude Code logs every turn's token counts to the local transcript; reading it
-- costs no tokens and makes no network call. These pure helpers parse + aggregate
-- those counts; the impure side (file reads) lives in the dashboard's FX layer.
M.CONTEXT_LIMIT_DEFAULT = 200000      -- Claude Opus/Sonnet context window
M.WINDOW_5H = 5 * 3600                -- rolling 5-hour window (approx plan limit)
M.WINDOW_7D = 7 * 86400              -- rolling 7-day window

-- Convert an ISO-8601 UTC timestamp ("2026-03-16T12:29:10.850Z") to epoch seconds
-- in UTC, timezone-independent (days-from-civil formula, Howard Hinnant, so it matches os.time()
-- comparisons without DST/locale drift). nil if unparseable.
function M.isoToEpoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  h, mi, se = tonumber(h), tonumber(mi), tonumber(se)
  local yy = y - (mo <= 2 and 1 or 0)
  local era = math.floor((yy >= 0 and yy or (yy - 399)) / 400)
  local yoe = yy - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + se
end

-- Parse ONE transcript JSONL line into a usage event, or nil if it isn't an
-- assistant message with a usage block (skips user lines, blanks, partial tails --
-- same `^%s*{` guard as transcriptSnippet so it never logs a decode error).
function M.parseUsageLine(line)
  if type(line) ~= "string" or not line:find("^%s*{") then return nil end
  local okj, obj = pcall(function() return M.json.decode(line) end)
  if not okj or type(obj) ~= "table" or obj.type ~= "assistant" then return nil end
  local m = obj.message
  if type(m) ~= "table" or type(m.usage) ~= "table" then return nil end
  local u = m.usage
  return {
    model       = m.model,
    ts          = M.isoToEpoch(obj.timestamp),
    input       = tonumber(u.input_tokens) or 0,
    output      = tonumber(u.output_tokens) or 0,
    cacheRead   = tonumber(u.cache_read_input_tokens) or 0,
    cacheCreate = tonumber(u.cache_creation_input_tokens) or 0,
  }
end

-- Current context size from a usage event: the prompt side (input + both cache
-- buckets). The LAST assistant turn's value ~= how full the context window is.
function M.contextTokens(u)
  if type(u) ~= "table" then return 0 end
  return (u.input or 0) + (u.cacheRead or 0) + (u.cacheCreate or 0)
end

-- Fraction 0..1 of the context window used (clamped). limit defaults to 200k.
function M.contextFraction(tokens, limit)
  limit = tonumber(limit) or M.CONTEXT_LIMIT_DEFAULT
  if limit <= 0 then return 0 end
  local f = (tonumber(tokens) or 0) / limit
  if f < 0 then return 0 elseif f > 1 then return 1 end
  return f
end

-- Sum a list of usage events into cumulative totals + a per-model breakdown.
-- `total` is gross (incl. cache reads); `real` excludes cache_read (input + output +
-- cache_creation) -- the meaningful "tokens used" headline, since cache reads dominate
-- the gross count but are cheap and not how the plan is metered.
function M.sumUsage(events)
  local s = { input = 0, output = 0, cacheRead = 0, cacheCreate = 0, total = 0, real = 0, byModel = {} }
  for _, e in ipairs(events or {}) do
    s.input = s.input + (e.input or 0)
    s.output = s.output + (e.output or 0)
    s.cacheRead = s.cacheRead + (e.cacheRead or 0)
    s.cacheCreate = s.cacheCreate + (e.cacheCreate or 0)
    local key = e.model or "unknown"
    local bm = s.byModel[key] or { input = 0, output = 0, cacheRead = 0, cacheCreate = 0, total = 0, real = 0 }
    bm.input = bm.input + (e.input or 0)
    bm.output = bm.output + (e.output or 0)
    bm.cacheRead = bm.cacheRead + (e.cacheRead or 0)
    bm.cacheCreate = bm.cacheCreate + (e.cacheCreate or 0)
    bm.total = bm.input + bm.output + bm.cacheRead + bm.cacheCreate
    bm.real = bm.input + bm.output + bm.cacheCreate
    s.byModel[key] = bm
  end
  s.total = s.input + s.output + s.cacheRead + s.cacheCreate
  s.real = s.input + s.output + s.cacheCreate
  return s
end

-- "Real" tokens (excl. cache reads) across events whose ts falls within the last
-- `windowSec` (rolling window ending at `now`). Events without a ts are skipped. Used
-- for the 5h/7d local-approximation bars (the official % comes from the OAuth endpoint).
function M.usageInWindow(events, now, windowSec)
  local cutoff = (tonumber(now) or 0) - (tonumber(windowSec) or 0)
  local total = 0
  for _, e in ipairs(events or {}) do
    if e.ts and e.ts >= cutoff then
      total = total + (e.input or 0) + (e.output or 0) + (e.cacheCreate or 0)
    end
  end
  return total
end

-- Human-readable token count: 1.30M / 254.3k / 42.
function M.formatTokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

-- Bar color band from a 0..1 fraction: ok < .75 <= warn < .9 <= full.
function M.usageBarLevel(frac)
  frac = tonumber(frac) or 0
  if frac >= 0.9 then return "full" end
  if frac >= 0.75 then return "warn" end
  return "ok"
end

-- Does a session count against your Anthropic plan? (Native endpoint + a claude/
-- anthropic model.) Gateway sessions (a base_url is set) hit a different provider,
-- so they're excluded from the 5h/7d plan-window approximation.
function M.isAnthropicSession(model, baseUrl)
  if baseUrl and tostring(baseUrl) ~= "" then return false end
  local m = tostring(model or ""):lower()
  return m == "" or m:find("^claude") ~= nil or m:find("^anthropic") ~= nil
end

-- The last usage event in a transcript tail (scans bottom-up for the most recent
-- assistant line with a usage block). Drives the per-tile context-fullness bar off
-- the bytes the activity peek already read -- so it costs no extra I/O. nil if none.
function M.lastUsage(text)
  if not text or #text == 0 then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    local e = M.parseUsageLine(lines[i])
    if e then return e end
  end
  return nil
end

-- Context-window limit for a session's model. Precedence: a provider profile's
-- explicit `contextLimit` (gateway/local models) -> a built-in map for native Claude
-- (Opus 4.x and Sonnet 4.6 are 1M in Claude Code; older/Haiku 200k) -> the 200k default.
-- Getting this right matters: a wrong (too-small) denominator makes a session look
-- "full" when it isn't (the original bug: 437k context shown as 100% of a 200k default).
function M.contextLimitFor(cfg, model)
  local list = M.config(cfg, "providers", nil)
  if type(list) == "table" and model then
    for _, p in ipairs(list) do
      if type(p) == "table" and p.model == model and tonumber(p.contextLimit) then
        return tonumber(p.contextLimit)
      end
    end
  end
  local m = tostring(model or ""):lower()
  -- Opus 4.6/4.7/4.8 + Sonnet 4.6 have a 1M window on Claude Code paid plans.
  if m:find("opus%-4") or m:find("sonnet%-4") then return 1000000 end
  return M.CONTEXT_LIMIT_DEFAULT
end

-- Standard context-window tiers, used to self-heal an unknown/underestimated model:
-- round an observed context size up to the smallest tier that contains it, so we never
-- render a false 100% for a model the map doesn't know.
M.CONTEXT_TIERS = { 200000, 1000000, 2000000 }
function M.nextContextTier(n)
  n = tonumber(n) or 0
  for _, t in ipairs(M.CONTEXT_TIERS) do if n <= t then return t end end
  return n
end

-- The context-fullness fraction (0..1) + the effective limit used. Combines the
-- model/provider limit with the observed-size tier guard, so the denominator is right
-- for known models AND can't be smaller than what the session actually holds.
function M.contextFractionFor(cfg, model, tokens)
  local limit = math.max(M.contextLimitFor(cfg, model), M.nextContextTier(tokens))
  return M.contextFraction(tokens, limit), limit
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

-- ---- Provider profiles (multi-model / multi-provider) ----------------------
-- A "provider" is a named bundle of NON-SECRET env vars + a model id (+ optional
-- ssh host) injected into the `claude` spawn. Secrets are NEVER stored: a profile
-- names an env var (authTokenEnv) that the spawned LOGIN SHELL expands at launch,
-- so cc-config.json holds no key and Shepherd's own process never sees one.
--   kind="anthropic" (default) -> set ANTHROPIC_MODEL on the normal endpoint.
--   kind="gateway"             -> also set ANTHROPIC_BASE_URL + auth/headers, so
--                                 Claude Code talks to a LiteLLM-style gateway
--                                 (Gemini / OpenAI / local models) or a local/
--                                 remote REST server.
-- The model rides ANTHROPIC_MODEL (not `--model`) so it's inherited by the status
-- hook's env -- that's how the panel shows which model a session is running.

-- Look up a provider profile by id in a decoded config table; nil if absent.
function M.providerById(cfg, id)
  if not id or tostring(id) == "" then return nil end
  local list = M.config(cfg, "providers", nil)
  if type(list) ~= "table" then return nil end
  for _, p in ipairs(list) do
    if type(p) == "table" and tostring(p.id) == tostring(id) then return p end
  end
  return nil
end

-- Ordered env injection for a profile: a list of { name, value, secret }. A
-- secret carries a shell ref ("$VAR") that the spawned shell expands (emitted
-- double-quoted); a non-secret is a literal (single-quoted). An empty/model-less
-- anthropic profile injects nothing (-> bare `claude`, unchanged).
function M.providerEnv(profile)
  local env = {}
  if type(profile) ~= "table" then return env end
  local gateway = tostring(profile.kind or "anthropic") == "gateway"
  local function put(name, value, secret)
    if value and tostring(value) ~= "" then
      env[#env + 1] = { name = name, value = tostring(value), secret = secret == true }
    end
  end
  if gateway then put("ANTHROPIC_BASE_URL", profile.baseUrl, false) end
  put("ANTHROPIC_MODEL", profile.model, false)
  if gateway then
    put("ANTHROPIC_SMALL_FAST_MODEL", profile.smallFastModel, false)
    put("ANTHROPIC_CUSTOM_HEADERS", profile.headers, false)
    if profile.authTokenEnv and tostring(profile.authTokenEnv) ~= "" then
      put("ANTHROPIC_AUTH_TOKEN", "$" .. tostring(profile.authTokenEnv), true)
    end
  end
  return env
end

-- Render an env list (from providerEnv) into a shell command prefix ending in a
-- space ("NAME='v' NAME2=\"$VAR\" "). Empty/absent list -> "" so the no-provider
-- spawn is byte-identical to before.
function M.envPrefix(envList)
  if type(envList) ~= "table" or #envList == 0 then return "" end
  local parts = {}
  for _, e in ipairs(envList) do
    local val = e.secret and ('"' .. tostring(e.value) .. '"') or shquote(tostring(e.value))
    parts[#parts + 1] = tostring(e.name) .. "=" .. val
  end
  return table.concat(parts, " ") .. " "
end

-- Wrap a remote command for SSH (Phase 2 -- run `claude` ON another machine while
-- the terminal window stays local, so keystroke effects still target it). The whole
-- command is single-quoted so its inner `$VAR` secrets expand on the REMOTE host
-- (from the remote login shell), never locally. `-t` forces a TTY so claude's TUI
-- works. ssh = { host, user(optional), tty(default true) }.
function M.sshWrap(inner, ssh)
  if type(ssh) ~= "table" or not ssh.host or tostring(ssh.host) == "" then return inner end
  local dest = (ssh.user and tostring(ssh.user) ~= "")
    and (tostring(ssh.user) .. "@" .. tostring(ssh.host)) or tostring(ssh.host)
  local cmd = (ssh.tty == false) and "ssh" or "ssh -t"
  return cmd .. " " .. dest .. " " .. shquote(inner)
end

-- The shell command run INSIDE the spawned terminal:
--   cd <project> && [ENV=... ] claude [flags] [prompt]
-- opts: { env = providerEnv list, flags = spawnFlags list, ssh = {host,user} }. All
-- optional; with none, the output is exactly the original `cd <p> && claude [prompt]`.
-- With ssh, the whole thing is wrapped in `ssh -t <dest> '<inner>'` (remote harness).
function M.spawnInner(project, prompt, opts)
  opts = opts or {}
  local inner = "cd " .. shquote(project or ".") .. " && " .. M.envPrefix(opts.env) .. "claude"
  for _, f in ipairs(opts.flags or {}) do inner = inner .. " " .. f end
  if prompt and #prompt > 0 then inner = inner .. " " .. shquote(prompt) end
  return M.sshWrap(inner, opts.ssh)
end

-- The AppleScript to run (via hs.osascript, NOT a shell) that opens `terminal`
-- and runs the inner command in it. Running AppleScript directly avoids an extra
-- shell-quoting layer, so this only needs to escape for AppleScript + the inner
-- shell -- two well-defined levels instead of three nested ones.
function M.spawnAppleScript(project, prompt, opts)
  opts = opts or {}
  local term = opts.terminal or "Terminal"
  return "tell application " .. asquote(term)
    .. " to do script "
    .. asquote(M.spawnInner(project, prompt, { env = opts.env, flags = opts.flags, ssh = opts.ssh }))
end

-- Build claude CLI launch flags from a permission mode (+ effort, reserved). Both
-- optional. `--permission-mode <m>` is a real launch flag (Part C); effort has no
-- documented launch flag (it's set live via /effort), so it's accepted but not
-- emitted. The model is NOT a flag here -- it rides ANTHROPIC_MODEL (providerEnv)
-- so the status hook can see it. Returns a flat argv-style list (possibly empty).
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
-- opts: { terminal, kittyBin, kittyRemote(bool), kittySocket, permissionMode,
--         effort, env, shell, ssh }. env (a providerEnv list) injects provider env
--         vars (incl. ANTHROPIC_MODEL); shell (default "zsh") is the login shell used
--         to expand `$VAR` secrets in the kitty path; ssh = {host,user} runs `claude`
--         on a remote box while the terminal window stays local (Phase 2).
function M.spawnSpec(editor, project, task, opts)
  opts = opts or {}
  editor = tostring(editor or ""):lower()
  task = (task and #task > 0) and task or nil
  local flags = M.spawnFlags(opts.permissionMode, opts.effort)
  local env = opts.env
  local ssh = opts.ssh
  local hasEnv = type(env) == "table" and #env > 0
  local isSsh = type(ssh) == "table" and ssh.host and tostring(ssh.host) ~= ""
  if editor == "kitty" then
    -- A fresh kitty window with remote control on a known socket (default ON), so
    -- click-to-answer / mode-switch (Part A) work without touching global config.
    local argv = { opts.kittyBin or "kitty" }
    if opts.kittyRemote ~= false then
      for _, f in ipairs(M.kittyLaunchRemoteFlags(opts.kittySocket)) do argv[#argv + 1] = f end
    end
    argv[#argv + 1] = "--directory"; argv[#argv + 1] = project or "."
    if isSsh then
      -- Run ssh directly (no local shell): the remote login shell runs the inner
      -- and expands its `$VAR` secrets. The inner is one argv element.
      argv[#argv + 1] = "ssh"
      if ssh.tty ~= false then argv[#argv + 1] = "-t" end
      argv[#argv + 1] = (ssh.user and tostring(ssh.user) ~= "")
        and (tostring(ssh.user) .. "@" .. tostring(ssh.host)) or tostring(ssh.host)
      argv[#argv + 1] = M.spawnInner(project, task, { env = env, flags = flags })
    elseif hasEnv then
      -- Kitty argv has no shell to expand `$VAR`, so run the inner via a login
      -- shell (uniform env injection + secret expansion with the terminal path).
      argv[#argv + 1] = opts.shell or "zsh"
      argv[#argv + 1] = "-lc"
      argv[#argv + 1] = M.spawnInner(project, task, { env = env, flags = flags })
    else
      argv[#argv + 1] = "claude"
      for _, f in ipairs(flags) do argv[#argv + 1] = f end
      if task then argv[#argv + 1] = task end  -- one argv element: no shell, no quoting
    end
    return { kind = "kitty", argv = argv }
  elseif editor == "vscode" or editor == "cursor" then
    -- Open the window; "run claude" is best-effort keystrokes into a new integrated
    -- terminal (no supported API), consistent with the project's VS Code stance. For
    -- ssh, type the full `ssh -t <dest> '<inner>'` (the remote cd handles cwd).
    local post
    if isSsh then
      post = M.spawnInner(project, task, { env = env, flags = flags, ssh = ssh })
    else
      post = M.envPrefix(env) .. "claude"
      for _, f in ipairs(flags) do post = post .. " " .. f end
      if task then post = post .. " " .. shquote(task) end
    end
    return { kind = "vscode", editor = editor,
             app = (editor == "cursor") and "Cursor" or "Visual Studio Code",
             project = project, openTerminalKey = { mods = { "ctrl" }, key = "`" },
             postType = post }
  end
  return { kind = "terminal",
           applescript = M.spawnAppleScript(project, task,
             { terminal = opts.terminal, env = env, flags = flags, ssh = ssh }) }
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
