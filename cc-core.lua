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

-- Sort priority: approvals first (they need you), then errored sessions (frozen on an
-- API error -- you must resume them), then the rest; ties broken by name for stability.
local RANK = { approval = 0, error = 1, done = 2, working = 3, idle = 4 }

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
  return M.sortByStatus(list)
end

-- Sort a parsed session list in place by status priority (approvals/errors first), ties
-- by name. Exposed so the dashboard can RE-sort after it derives the "error" status from
-- the transcript -- parseStatusList runs before any transcript is read, so it can't see it.
function M.sortByStatus(list)
  table.sort(list or {}, function(a, b)
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
    if not (text and #text > 0) then return nil end
    -- pasteIntoWindow reports delivery: an explicit false means the no-window-
    -- match guard skipped the paste, so report nil and the caller never ledgers
    -- a nudge the session didn't receive (same contract as set-mode below;
    -- strict == false keeps fx fakes that return nothing on the success path).
    if fx.pasteIntoWindow(tgt, { text = text }) == false then
      fx.log("[cc-core] nudge paste not delivered for " .. tostring(item.name) .. " -- not recorded")
      return nil
    end
  elseif action == "continue" then
    -- Resume a session frozen on an API error (e.g. ECONNRESET): type the literal word
    -- "continue" + Enter, exactly as the user would, to restart the aborted turn.
    fx.typeIntoWindow(tgt, "continue")
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
    -- The dashboard optimistically re-bases permission_mode when this returns
    -- "set-mode" -- but sendKeys can SKIP (no window match / dead kitty target).
    -- An explicit false means "nothing was sent": report nil so the caller never
    -- persists a mode the session isn't in. Strict == false keeps fx fakes (and
    -- the answer path) that return nothing on the success contract.
    if fx.sendKeys(tgt, keys) == false then
      fx.log("[cc-core] set-mode keys not delivered for " .. tostring(item.name) .. " -- mode NOT re-based")
      return nil
    end
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
-- folder inherits it (survives close/reopen). A legacy cwd-keyed entry resolves
-- ONLY for a session with no projectKey, so a projectKey'd-but-unlabeled session
-- can't inherit a stale cwd label. Like applyLabels, only .label is set.
function M.applyLabelsByCwd(list, labelsByKey)
  labelsByKey = labelsByKey or {}
  for _, it in ipairs(list or {}) do
    it.label = (it.projectKey and labelsByKey[it.projectKey])
            or (not it.projectKey and it.cwd and labelsByKey[it.cwd])  -- legacy cwd-keyed (ONLY when no projectKey)
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

-- ---- Tile filter / search (free-text) --------------------------------------
-- Filter a session list by a free-text query (case-insensitive, token-AND). The
-- searchable text is label + name + cwd + projectKey + status + group, in that order
-- -- MIRRORED in the panel JS, which must stay in sync. A blank query is a pass-through.
-- Used by the search bar (via the JS twin) and the bulk-action path (Lua side, to
-- scope actions to what the operator currently sees).
function M.filterTiles(list, query)
  local toks = {}
  for tok in tostring(query or ""):lower():gmatch("%S+") do toks[#toks + 1] = tok end
  if #toks == 0 then return list or {} end
  local out = {}
  for _, it in ipairs(list or {}) do
    local hay = string.lower(table.concat({
      it.label or "", it.name or "", it.cwd or "", it.projectKey or "",
      it.status or "", it.group or "",
    }, " "))
    local all = true
    for _, t in ipairs(toks) do
      if not hay:find(t, 1, true) then all = false; break end
    end
    if all then out[#out + 1] = it end
  end
  return out
end

-- ---- Session groups / tags -------------------------------------------------
-- Groups let the operator cohort sessions (e.g. "backend", "refactor") and filter
-- or act on a whole group at once. Like relabels, a group is keyed by the session's
-- STABLE projectKey (launch folder, immune to cd drift) so it sticks across
-- close/reopen and a brand-new session in the same folder inherits it. Persistence
-- (cc-groups.json) + group-scoped bulk actions live in the dashboard; pure bits here.

-- Tag each session with its group (in place), keyed by projectKey; a legacy cwd-keyed
-- entry resolves ONLY when the session has no projectKey (mirrors applyLabelsByCwd).
function M.applyGroups(list, groupsByKey)
  groupsByKey = groupsByKey or {}
  for _, it in ipairs(list or {}) do
    it.group = (it.projectKey and groupsByKey[it.projectKey])
            or (not it.projectKey and it.cwd and groupsByKey[it.cwd])  -- legacy cwd-keyed (ONLY when no projectKey)
            or nil
  end
  return list
end

-- Distinct, sorted group names present in a (tagged) list. Ungrouped sessions are
-- ignored. Drives the header filter chips.
function M.groupNames(list)
  local seen, out = {}, {}
  for _, it in ipairs(list or {}) do
    local g = it.group
    if type(g) == "string" and g ~= "" and not seen[g] then
      seen[g] = true; out[#out + 1] = g
    end
  end
  table.sort(out)
  return out
end

-- Set or clear a session's group assignment, immutably (returns a NEW table; the
-- input is never mutated, like setLabel). A blank/whitespace value CLEARS the entry;
-- a nil/empty key is a no-op.
function M.setGroup(groupsByKey, key, value)
  local out = {}
  for k, v in pairs(groupsByKey or {}) do out[k] = v end
  if not key or key == "" then return out end
  local txt = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- explicit if/else: the (cond and nil or x) idiom can't return nil when txt=="".
  if txt == "" then out[key] = nil else out[key] = txt end
  return out
end

-- ---- Bulk fleet actions ----------------------------------------------------
-- Per-action targeting rule -- the SINGLE source of truth shared with the panel JS,
-- which reads the same table injected into the HTML as __BULK_RULES__. Keeping one
-- table means the bulk-bar count (JS-derived) can't drift from what Lua re-derives
-- and acts on. `match` = only sessions with that status; `exclude` = any status but
-- that one. nudge excludes `approval` because handleAction's nudge pastes text AND
-- submits, so broadcasting into a session sitting at its y/n approval prompt would
-- corrupt that decision -- a waiter needs a decision, not a prompt.
M.BULK_RULES = {
  approve = { match = "approval" },
  stop    = { match = "working" },
  nudge   = { exclude = "approval" },
}

-- Which session keys a fleet-wide bulk action targets, drawn from an ALREADY-VISIBLE
-- list (the panel passes the keys currently shown, post search/group filter, so a
-- bulk action is WYSIWYG). Stale tiles are never targeted (a dead window can't act).
-- Unknown action -> {}. Routes through handleAction on the dashboard side.
function M.selectActionable(list, action, opts)
  local rule = M.BULK_RULES[action]
  local out = {}
  if not rule then return out end
  for _, it in ipairs(list or {}) do
    if it.key and not it.stale
       and M.remoteActionAllowed(it, action, opts) then  -- remote tiles: headless approve/deny only
      local ok
      if rule.match ~= nil then ok = (it.status == rule.match)
      else ok = (it.status ~= rule.exclude) end
      if ok then out[#out + 1] = it.key end
    end
  end
  return out
end

-- Does dispatching `action` on this session skip window focus entirely? kitty
-- routes through `kitty @` (headless) and an armed-gate approve/deny is a
-- decision-file write. Everything ELSE focuses a window and injects keystrokes
-- on timers, so the bulk dispatcher must stagger those: N synchronous dispatches
-- would all fire after the LAST focus and land every key in one window.
function M.actionIsHeadless(item, action)
  if not item then return false end
  if item.remote then return true end  -- bridge tiles never focus a local window
  if item.editor == "kitty" then return true end
  return (action == "approve" or action == "deny") and item.gate == "waiting"
end

-- Reserve the next slot in the SHARED injection-chain schedule. The stagger
-- must hold across dispatches, not just within one bulk message: a second bulk
-- click (or a single window action during the stagger window) would otherwise
-- start its chain at t=0 and interleave with the in-flight ones, landing keys
-- in the wrong session. `tailAt` is the absolute deadline of the last reserved
-- chain (module state on the dashboard side); returns the delay (s) to schedule
-- the next chain and the advanced tail.
function M.staggerSlot(tailAt, now, gap)
  now = tonumber(now) or 0
  local startAt = math.max(tonumber(tailAt) or 0, now)
  return startAt - now, startAt + (tonumber(gap) or 0)
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

-- Cap a filtered slice (newest-first) so a huge ledger can't bloat the webview
-- payload. limit <= 0 means NO cap -- export/review are documented as "full
-- data, not the capped slice", so they must be able to bypass the webview
-- default. Returns the (possibly sliced) list + a truncated flag.
function M.capLedgerSlice(events, limit)
  events = events or {}
  local cap = tonumber(limit) or 2000
  if cap <= 0 or #events <= cap then return events, false end
  local t = {}
  for i = 1, cap do t[i] = events[i] end
  return t, true
end

-- Split events into kept/purged under a purge filter (session AND types AND
-- time window -- the EXACT filter the audit UI confirmed; matching a superset
-- would irreversibly delete events the operator never approved). Reuses
-- filterLedger so purge can never disagree with export/review about what a
-- filter selects. Order of both lists follows the input (file order).
function M.splitLedgerEvents(events, filter)
  local matched = {}
  for _, e in ipairs(M.filterLedger(events, filter)) do matched[e] = true end
  local kept, purged = {}, {}
  for _, e in ipairs(events or {}) do
    if matched[e] then purged[#purged + 1] = e else kept[#kept + 1] = e end
  end
  return kept, purged
end

-- Is a purge filter SCOPED (vs "delete everything")? Drives both the
-- confirmation dialog wording and whether the purge escalates to filter.all.
-- `types` counts: a type-only purge must not silently widen to every file.
function M.purgeFilterIsScoped(f)
  if type(f) ~= "table" then return false end
  if f.session or f.sinceTs or f.untilTs then return true end
  return type(f.types) == "table" and #f.types > 0
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

-- Is `day` (UTC "YYYY-MM-DD") strictly before the current UTC day at epoch `now`?
-- Redact may only rewrite PAST days: today's file is hot with O_APPEND hook writes,
-- and a read->rewrite->rename would silently destroy a concurrent append. ISO
-- dates compare lexicographically, so plain string `<` is the civil-date compare;
-- a malformed/missing day fails closed (false -> not redactable).
function M.ledgerDayIsPast(day, now)
  day = tostring(day or "")
  if not day:match("^%d%d%d%d%-%d%d%-%d%d$") then return false end
  return day < os.date("!%Y-%m-%d", tonumber(now) or 0)
end

-- Size-cap GC decision (pure): given the live daily files sorted OLDEST-FIRST and
-- a filename->bytes map, return the files to delete to get under capBytes. NEVER
-- selects the newest file -- that's the hot current day the hooks are appending to
-- (age-based expiry above can't pick today either); the cap shaves history, not
-- the in-progress day. capBytes <= 0 -> {}.
function M.ledgerCapVictims(live, sizes, capBytes)
  local out = {}
  local cap = tonumber(capBytes) or 0
  if cap <= 0 or type(live) ~= "table" then return out end
  local function size(fn) return (type(sizes) == "table" and tonumber(sizes[fn])) or 0 end
  local total = 0
  for _, fn in ipairs(live) do total = total + size(fn) end
  local i = 1
  while total > cap and i < #live do  -- i < #live: stop BEFORE the newest file
    total = total - size(live[i])
    out[#out + 1] = live[i]; i = i + 1
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
  escalation    = { "🔴", "approval waiting too long" },
  hung          = { "⏳", "stalled (no transcript progress)" },
  auto_respawn  = { "♻️", "auto-respawned" },
  drain_close   = { "⛔", "drained (finished turn, closed)" },
  queue_edit    = { "🧾", "edited the queue" },
  route_arm     = { "🔀", "project routing toggled" },
  queue_starved = { "⌛", "queued work waiting (no free session)" },
  remote_decision = { "📡", "remote decision sent" },
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

-- Chronological (oldest-first) slice of ONE session's ledger events, for the
-- per-session timeline drill-down (the detail-panel "Timeline" button). Scopes via
-- filterLedger by session_id, keeps the newest `opts.limit` (default 500) so a very
-- long-lived session can't flood the view, then flips ascending for reading. A
-- nil/empty sessionId returns {} (never "all"). Pure; the audit overlay's
-- session-filtered timeline view is the JS twin.
function M.sessionTimeline(events, sessionId, opts)
  opts = opts or {}
  if not sessionId or tostring(sessionId) == "" then return {} end
  local limit = tonumber(opts.limit) or 500
  local scoped = M.filterLedger(events, { session = sessionId })  -- newest-first
  local kept = {}
  for i = 1, math.min(#scoped, limit) do kept[#kept + 1] = scoped[i] end
  table.sort(kept, function(a, b) return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0) end)
  return kept
end

-- Last-N gate decisions for ONE session, grouped for the detail panel: a burst of
-- identical CONSECUTIVE decisions ("policy denied Bash ×4") collapses to one row
-- with a count, so the widget reads as "what's the gate been doing to this
-- session" rather than a raw event dump. Group key = (tool, outcome, by, pattern);
-- only adjacent events merge -- an interleaved different decision splits the run
-- (A A B A = three groups), preserving the actual order of what happened.
-- Returns newest-first groups: { tool, outcome, by, pattern, summary, count,
-- lastTs, firstTs } -- summary is the NEWEST member's. opts = { limit (default 5
-- groups), sinceTs }. nil/empty sessionId -> {} (never "all sessions").
function M.gateDecisionSummary(events, sessionId, opts)
  opts = opts or {}
  if not sessionId or tostring(sessionId) == "" then return {} end
  local limit = tonumber(opts.limit) or 5
  local scoped = M.filterLedger(events,
    { session = sessionId, types = { "decision" }, sinceTs = opts.sinceTs })  -- newest-first
  local groups = {}
  local function keyOf(e)
    return tostring(e.tool or "") .. "\0" .. tostring(e.outcome or "") .. "\0"
      .. tostring(e.by or "") .. "\0" .. tostring(e.pattern or "")
  end
  local cur, curKey = nil, nil
  for _, e in ipairs(scoped) do
    local k = keyOf(e)
    if cur and k == curKey then
      cur.count = cur.count + 1
      cur.firstTs = tonumber(e.ts) or cur.firstTs  -- walking newest->oldest
    else
      if #groups >= limit then break end
      cur = { tool = e.tool, outcome = e.outcome, by = e.by, pattern = e.pattern,
              summary = e.summary, count = 1,
              lastTs = tonumber(e.ts), firstTs = tonumber(e.ts) }
      curKey = k
      groups[#groups + 1] = cur
    end
  end
  return groups
end

-- Which ledger events count as "a notification fired" (🔔 history): the alert
-- types the panel raises on its own (escalation / hung / auto_respawn) plus any
-- gate decision NOT made by a human (autoAllow/autoDeny/autopilot/approveRepeats/
-- timeout-*) -- exactly the set of things that happened without you. opts =
-- { sinceTs, limit (default 200) }. Newest-first (filterLedger order).
M.NOTIFY_TYPES = { escalation = true, hung = true, auto_respawn = true }
function M.notificationEvents(events, opts)
  opts = opts or {}
  local out = {}
  for _, e in ipairs(M.filterLedger(events, { sinceTs = opts.sinceTs })) do
    if M.NOTIFY_TYPES[e.type]
       or (e.type == "decision" and e.by ~= nil and e.by ~= "human") then
      out[#out + 1] = e
    end
  end
  return M.capLedgerSlice(out, tonumber(opts.limit) or 200)
end

-- How many of a newest-first notification list are newer than lastSeenTs.
-- nil/0 lastSeenTs counts everything (window-bounded by the caller's sinceTs).
function M.unseenNotificationCount(notifs, lastSeenTs)
  local seen = tonumber(lastSeenTs) or 0
  local n = 0
  for _, e in ipairs(notifs or {}) do
    if (tonumber(e.ts) or 0) > seen then n = n + 1 else break end  -- newest-first
  end
  return n
end

-- ---- Fleet-wide transcript/ledger search (roadmap #3, ripgrep-backed) -------
-- "Which session touched auth.ts?" across every transcript JSONL + the ledger.
-- rg when installed, grep -r fallback; both invocations are built HERE (pure,
-- tested) and executed via hs.task in the dashboard.

-- Escape a user query so rg and `grep -E` (shared ERE syntax) treat it as a
-- literal string.
function M.escapeSearchPattern(q)
  return (tostring(q or ""):gsub("[\\%.%[%]%(%)%{%}%*%+%?%^%$|]", "\\%0"))
end

M.SEARCH_MIN_QUERY = 3
M.SEARCH_CTX = 60  -- chars of context captured around the match

-- Build the ARGUMENT list for one fleet search (binary EXCLUDED -- hs.task.new
-- takes the resolved path separately). kind = "rg"|"grep".
-- The match is wrapped as .{0,CTX}<literal>.{0,CTX} and emitted with -o:
-- transcript lines are multi-KB JSON, so emitting ONLY the wrapped match keeps
-- the output tiny by construction (no --json parsing, no giant lines).
-- Returns nil for a too-short query (< SEARCH_MIN_QUERY after trim).
function M.searchArgv(kind, query, paths, opts)
  opts = opts or {}
  local q = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #q < M.SEARCH_MIN_QUERY then return nil end
  local ctx = tostring(tonumber(opts.ctx) or M.SEARCH_CTX)
  local maxPerFile = tostring(tonumber(opts.maxPerFile) or 3)
  local wrapped = ".{0," .. ctx .. "}" .. M.escapeSearchPattern(q) .. ".{0," .. ctx .. "}"
  local argv
  if kind == "rg" then
    argv = { "--no-config", "-i", "-n", "-o", "--no-heading", "--with-filename",
             "--max-count", maxPerFile, "--max-filesize", "50M", "-g", "*.jsonl",
             "-e", wrapped }
  else
    argv = { "-r", "-I", "-i", "-n", "-o", "-H", "-E", "-m", maxPerFile,
             "--include=*.jsonl", "-e", wrapped }
  end
  for _, p in ipairs(paths or {}) do argv[#argv + 1] = tostring(p) end
  return argv
end

-- Parse `file:line:matchtext` output lines -> { hits = {{file,line,text}},
-- truncated }. Splits on the FIRST two colons only (the match text may contain
-- colons); malformed lines are skipped. opts = { limit (default 200), maxLen
-- (default 200, display backstop) }.
function M.parseSearchResults(output, opts)
  opts = opts or {}
  local limit = tonumber(opts.limit) or 200
  local maxLen = tonumber(opts.maxLen) or 200
  local hits, truncated = {}, false
  for line in (tostring(output or "") .. "\n"):gmatch("(.-)\n") do
    local file, ln, text = line:match("^(/[^:]+):(%d+):(.*)$")
    if file then
      if #hits >= limit then truncated = true; break end
      if #text > maxLen then text = text:sub(1, maxLen) .. "…" end
      hits[#hits + 1] = { file = file, line = tonumber(ln), text = text }
    end
  end
  return { hits = hits, truncated = truncated }
end

-- Tag each hit with provenance + map it back to a session. items = the parsed
-- live status list. Adds per hit: kind ("transcript"|"ledger"), sessionId (the
-- transcript basename sans .jsonl), projectKey (the /projects/<ENC>/ segment --
-- same match as M.projectKey), and key/name when the file IS a live session's
-- transcript. Ledger hits only get kind = "ledger".
function M.annotateSearchHits(hits, items, ledgerDir)
  local byTranscript = {}
  for _, it in ipairs(items or {}) do
    if it.transcript_path then byTranscript[it.transcript_path] = it end
  end
  ledgerDir = tostring(ledgerDir or "")
  for _, h in ipairs(hits or {}) do
    local f = tostring(h.file or "")
    if ledgerDir ~= "" and f:sub(1, #ledgerDir) == ledgerDir then
      h.kind = "ledger"
    else
      h.kind = "transcript"
      h.projectKey = f:match("/projects/([^/]+)/[^/]+%.jsonl$")
      h.sessionId = f:match("/([^/]+)%.jsonl$")
      local live = byTranscript[f]
      if live then h.key = live.key; h.name = live.label or live.name end
    end
  end
  return hits
end

-- ---- Fleet insights (pure aggregation over the ledger) ---------------------
-- Both fleetStats and sessionRisk read ALREADY-PARSED ledger events (the caller
-- passes FX.readLedger(...).events) -- zero file I/O, zero model cost. The whole
-- feature is descriptive analytics over events the hooks already write.

-- Human-readable duration: 45s / 1m 30s / 2h 5m. Pure (no os.* needed).
function M.fmtDuration(seconds)
  local s = math.floor(tonumber(seconds) or 0)
  if s < 0 then s = 0 end
  if s < 60 then return s .. "s" end
  local m = math.floor(s / 60)
  if m < 60 then
    local rs = s % 60
    return (rs == 0) and (m .. "m") or (m .. "m " .. rs .. "s")
  end
  local h = math.floor(m / 60)
  local rm = m % 60
  return (rm == 0) and (h .. "h") or (h .. "h " .. rm .. "m")
end

-- Time a human was the bottleneck for one session: the gap from each tool_request to
-- its resolving decision, summed. ANY decision resolves the pending request (an
-- auto-allow/deny still clears it) -- but only a human/timeout-fallback decision
-- CREDITS the gap as your wait, so an auto-decision between a request and a later
-- human decision can't mis-attribute time. Gaps over maxBlock are dropped (an idle
-- overnight gap between a request and its answer isn't "blocked time"). Pure; sorts a
-- COPY by ts so callers needn't pre-sort. Shared by fleetStats (the per-session loop).
function M.blockedSeconds(events, maxBlock)
  maxBlock = tonumber(maxBlock) or 1800
  local evs = {}
  for _, e in ipairs(events or {}) do evs[#evs + 1] = e end
  table.sort(evs, function(a, b) return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0) end)
  local blocked, lastReqTs = 0, nil
  for _, e in ipairs(evs) do
    if e.type == "tool_request" then
      lastReqTs = tonumber(e.ts) or 0
    elseif e.type == "decision" then
      if lastReqTs and (e.by == "human" or e.by == "timeout-fallback") then
        local gap = (tonumber(e.ts) or 0) - lastReqTs
        if gap > 0 and gap <= maxBlock then blocked = blocked + gap end
      end
      lastReqTs = nil  -- ANY decision resolves the pending request
    end
  end
  return blocked
end

-- Aggregate a list of ledger events into fleet-wide stats for the insights view.
-- opts = { topN (mostActive cap, default 5), maxBlock (cap a single blocked gap,
-- default 1800s, so an overnight idle between a request and its answer isn't
-- counted) }. Pure + deterministic.
--   * decision buckets: allow / deny / fallback -- `fallback` (timeout) is its OWN
--     bucket and NEVER counts as a denial.
--   * provenance: counts keyed by the decision `by` (autoDeny/autoAllow/autopilot/
--     approveRepeats/human/timeout-fallback/other).
--   * perSession: turn counts (prompts), tool requests, decision split, denialRate.
--   * approvalBlockedSeconds: fleet time a human was the bottleneck -- the gap from
--     each tool_request to its resolving human/timeout-fallback decision.
function M.fleetStats(events, opts)
  opts = opts or {}
  local topN = tonumber(opts.topN) or 5
  local maxBlock = tonumber(opts.maxBlock) or 1800
  local totals = { events = 0, sessions = 0, prompts = 0, toolRequests = 0,
                   spawns = 0, decisions = 0 }
  local decisions = { allow = 0, deny = 0, fallback = 0, total = 0 }
  local provenance = {}
  local bySession, order = {}, {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" then
      totals.events = totals.events + 1
      local sid = e.session_id or e.key or "?"
      local agg = bySession[sid]
      if not agg then
        agg = { session_id = sid, name = e.name, projectKey = e.projectKey,
                prompts = 0, toolRequests = 0,
                decisions = { allow = 0, deny = 0, fallback = 0 }, events = {} }
        bySession[sid] = agg
        order[#order + 1] = sid
      end
      if e.name and not agg.name then agg.name = e.name end
      agg.events[#agg.events + 1] = e
      local t = e.type
      if t == "prompt" then
        totals.prompts = totals.prompts + 1; agg.prompts = agg.prompts + 1
      elseif t == "tool_request" then
        totals.toolRequests = totals.toolRequests + 1
        agg.toolRequests = agg.toolRequests + 1
      elseif t == "spawn" then
        totals.spawns = totals.spawns + 1
      elseif t == "decision" then
        totals.decisions = totals.decisions + 1
        local out = e.outcome
        if out == "allow" then
          decisions.allow = decisions.allow + 1; agg.decisions.allow = agg.decisions.allow + 1
        elseif out == "deny" then
          decisions.deny = decisions.deny + 1; agg.decisions.deny = agg.decisions.deny + 1
        elseif out == "fallback" then
          decisions.fallback = decisions.fallback + 1
          agg.decisions.fallback = agg.decisions.fallback + 1
        end
        provenance[e.by or "other"] = (provenance[e.by or "other"] or 0) + 1
      end
    end
  end
  decisions.total = decisions.allow + decisions.deny + decisions.fallback

  local approvalBlockedSeconds = 0
  local perSession = {}
  for _, sid in ipairs(order) do
    local agg = bySession[sid]
    local lastTs = 0
    for _, e in ipairs(agg.events) do
      local ts = tonumber(e.ts) or 0
      if ts > lastTs then lastTs = ts end
    end
    local blocked = M.blockedSeconds(agg.events, maxBlock)
    approvalBlockedSeconds = approvalBlockedSeconds + blocked
    local d = agg.decisions
    local dTotal = d.allow + d.deny + d.fallback
    perSession[#perSession + 1] = {
      session_id = sid, name = agg.name or sid, projectKey = agg.projectKey,
      prompts = agg.prompts, toolRequests = agg.toolRequests,
      decisions = { allow = d.allow, deny = d.deny, fallback = d.fallback },
      denialRate = dTotal > 0 and (d.deny / dTotal) or 0,
      blockedSeconds = blocked, lastTs = lastTs,
    }
  end
  totals.sessions = #perSession
  table.sort(perSession, function(a, b)
    if a.prompts ~= b.prompts then return a.prompts > b.prompts end
    return (a.name or "") < (b.name or "")
  end)
  local mostActive = {}
  for i = 1, math.min(topN, #perSession) do mostActive[i] = perSession[i] end

  return {
    totals = totals, decisions = decisions, provenance = provenance,
    approvalRate = decisions.total > 0 and (decisions.allow / decisions.total) or 0,
    denialRate = decisions.total > 0 and (decisions.deny / decisions.total) or 0,
    perSession = perSession, mostActive = mostActive,
    approvalBlockedSeconds = approvalBlockedSeconds,
  }
end

-- ---- Time-series buckets (sparkline trends over the ledger) -----------------
-- Per-metric accumulators for bucketEvents. Each writes into the shared `series`
-- (indexed via `idx`); a dispatch table (not an if/elseif chain) keeps each metric's
-- state isolated and makes a 5th metric a one-key addition. ctx = { nB, opts }.
-- The non-obvious ones: `active` counts work-DRIVING sessions using the SAME event set
-- as `activity` (a trailing decision alone isn't "running" that hour); `blocked` pairs
-- each tool_request -> its resolving human/timeout decision PER SESSION (the feed is
-- fleet-wide, like fleetStats) and credits the gap (<= maxBlock) to the bucket where
-- the wait STARTED.
local BUCKET_METRICS = {
  activity = function(evs, series, idx)
    for _, e in ipairs(evs) do
      if e.type == "prompt" or e.type == "tool_request" then
        local i = idx(e.ts); series[i].value = series[i].value + 1
      end
    end
  end,
  active = function(evs, series, idx)
    local seen = {}
    for _, e in ipairs(evs) do
      if (e.type == "prompt" or e.type == "tool_request") and e.session_id then
        local i = idx(e.ts)
        seen[i] = seen[i] or {}
        if not seen[i][e.session_id] then seen[i][e.session_id] = true; series[i].value = series[i].value + 1 end
      end
    end
  end,
  denialRate = function(evs, series, idx, ctx)
    local denom = {}
    for _, e in ipairs(evs) do
      if e.type == "decision" then
        local i = idx(e.ts)
        denom[i] = (denom[i] or 0) + 1                              -- all decisions
        if e.outcome == "deny" then series[i].value = series[i].value + 1 end
      end
    end
    for i = 1, ctx.nB do
      local d = denom[i] or 0
      series[i].value = (d > 0) and (series[i].value / d) or 0
    end
  end,
  blocked = function(evs, series, idx, ctx)
    local maxBlock = tonumber(ctx.opts.maxBlock) or 1800
    -- Pair PER SESSION. The insights feed is fleet-wide (filterLedger with no session
    -- filter), so a single pending-request slot would let one session's request
    -- overwrite another's and mis-credit the gap -- under-reporting blocked time and
    -- disagreeing with the per-session approvalBlockedSeconds headline. Keying by
    -- session_id mirrors fleetStats, which runs blockedSeconds once per isolated session.
    local lastReq = {}
    for _, e in ipairs(evs) do
      local sid = e.session_id or "?"
      if e.type == "tool_request" then
        lastReq[sid] = tonumber(e.ts)
      elseif e.type == "decision" then
        local req = lastReq[sid]
        if req and (e.by == "human" or e.by == "timeout-fallback") then
          local gap = (tonumber(e.ts) or 0) - req
          if gap > 0 and gap <= maxBlock then
            series[idx(req)].value = series[idx(req)].value + gap
          end
        end
        lastReq[sid] = nil  -- ANY decision resolves THIS session's pending request
      end
    end
  end,
}

-- Bucket events into a fixed-width time series for one metric (the insights
-- sparklines). Returns a dense array (no gaps) of { ts = bucket start, value }, one
-- bucket per `bucketSec` from the first to the last event's bucket. The caller
-- windows the events first (e.g. last 24h) and picks bucketSec, so the series stays
-- small -- for the `blocked` metric the caller should add a maxBlock lookback to the
-- window so a wait that started just before it but resolved inside is still paired.
-- Pure + deterministic. Unknown metric -> {}.
function M.bucketEvents(events, bucketSec, metric, opts)
  opts = opts or {}
  bucketSec = tonumber(bucketSec) or 3600
  if bucketSec <= 0 then bucketSec = 3600 end
  local handler = BUCKET_METRICS[metric]
  if not handler then return {} end
  local evs = {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" and tonumber(e.ts) then evs[#evs + 1] = e end
  end
  if #evs == 0 then return {} end
  table.sort(evs, function(a, b) return tonumber(a.ts) < tonumber(b.ts) end)
  local startB = math.floor(tonumber(evs[1].ts) / bucketSec) * bucketSec
  local endB   = math.floor(tonumber(evs[#evs].ts) / bucketSec) * bucketSec
  local nB = math.floor((endB - startB) / bucketSec) + 1
  local series = {}
  for i = 1, nB do series[i] = { ts = startB + (i - 1) * bucketSec, value = 0 } end
  local function idx(ts) return math.floor((tonumber(ts) - startB) / bucketSec) + 1 end
  handler(evs, series, idx, { nB = nB, opts = opts })
  return series
end

-- ---- Empirical per-session risk score (indicator only; no enforcement) -----
-- Default weights/thresholds (overridable via opts). Score is a weighted sum of
-- ledger-observed signals, normalized to 0..100; each signal capped so one noisy
-- dimension can't peg the score on its own.
M.RISK_WEIGHTS = {
  denyRate = 40,                              -- full deny rate -> +40
  autoDenyHit = 8, autoDenyCap = 24,         -- safety net firing = elevated risk
  timeoutFallback = 6, timeoutCap = 18,      -- requests left unsupervised
  staleApproval = 4, staleCap = 12,          -- you were a slow bottleneck
  volume = 3, volumeCap = 6,                  -- log-scaled tool exposure
}
M.RISK_THRESHOLDS = { med = 34, high = 67, staleSeconds = 300 }

-- Should the risk-scoring ledger snapshot be re-read? refresh() runs at 1 Hz
-- (timer + pathwatcher), and a full ledger re-read + per-line JSON parse every
-- tick burns the Hammerspoon main thread forever. Re-read only when the files'
-- identity signature changed (a hook appended / a day rolled over / a purge) or
-- the TTL backstop expired (size+mtime can miss a same-second same-size
-- rewrite). cache = { events, sig, ts }; nil/empty cache is always stale.
function M.ledgerCacheStale(cache, sig, now, ttl)
  if type(cache) ~= "table" or cache.events == nil then return true end
  if sig ~= cache.sig then return true end
  return (tonumber(now) or 0) - (tonumber(cache.ts) or 0) >= (tonumber(ttl) or 30)
end

-- Score one session's risk from its ledger events (caller filters to the session
-- via core.filterLedger(all, {session=sid})). Returns { score, band, signals }.
-- Pure + deterministic; no quarantine, no side effects -- purely an indicator.
function M.sessionRisk(events, opts)
  opts = opts or {}
  local function wv(k)
    local v = opts.weights and opts.weights[k]
    if v == nil then v = M.RISK_WEIGHTS[k] end
    return tonumber(v) or 0
  end
  local th = {}
  for k, v in pairs(M.RISK_THRESHOLDS) do th[k] = v end
  if type(opts.thresholds) == "table" then
    -- Coerce like the weights (wv does `tonumber(v) or 0`): a stringified threshold
    -- from cc-config.json (a quoted JSON number) must not reach the numeric compares
    -- below and throw "compare string with number", which would freeze the 1s refresh
    -- loop. Keep the default when a value isn't a number.
    for k, v in pairs(opts.thresholds) do th[k] = tonumber(v) or th[k] end
  end

  local evs = {}
  for _, e in ipairs(events or {}) do if type(e) == "table" then evs[#evs + 1] = e end end
  table.sort(evs, function(a, b) return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0) end)

  local decisionCount, denyCount = 0, 0
  local autoDenyHits, timeoutFallbacks, toolRequests, staleApprovals = 0, 0, 0, 0
  local lastReqTs = nil
  for _, e in ipairs(evs) do
    local t = e.type
    if t == "tool_request" then
      toolRequests = toolRequests + 1
      lastReqTs = tonumber(e.ts)
    elseif t == "decision" then
      decisionCount = decisionCount + 1
      if e.outcome == "deny" then denyCount = denyCount + 1 end
      if e.by == "autoDeny" then autoDenyHits = autoDenyHits + 1 end
      if e.by == "timeout-fallback" then timeoutFallbacks = timeoutFallbacks + 1 end
      -- Only a human/timeout decision counts as a slow approval, but ANY decision
      -- resolves the pending request -- so an auto-decision can't leave a stale
      -- lastReqTs that a later human decision would mis-pair (mirrors blockedSeconds).
      if lastReqTs and (e.by == "human" or e.by == "timeout-fallback")
         and ((tonumber(e.ts) or 0) - lastReqTs) > th.staleSeconds then
        staleApprovals = staleApprovals + 1
      end
      lastReqTs = nil
    end
  end

  local denyRate = decisionCount > 0 and (denyCount / decisionCount) or 0
  local function capped(n, per, cap) local v = n * per; return (v > cap) and cap or v end
  local score = denyRate * wv("denyRate")
    + capped(autoDenyHits, wv("autoDenyHit"), wv("autoDenyCap"))
    + capped(timeoutFallbacks, wv("timeoutFallback"), wv("timeoutCap"))
    + capped(staleApprovals, wv("staleApproval"), wv("staleCap"))
  local volScore = (math.log(toolRequests + 1) / math.log(10)) * wv("volume")
  if volScore > wv("volumeCap") then volScore = wv("volumeCap") end
  score = score + volScore
  if score < 0 then score = 0 elseif score > 100 then score = 100 end
  -- Band from the DISPLAYED (rounded) score, not the raw one, so the number and its
  -- colored band can't disagree at a boundary (a raw 33.6 shows "34" -> must be med).
  local shown = math.floor(score + 0.5)
  local band = "low"
  if shown >= th.high then band = "high" elseif shown >= th.med then band = "med" end
  return {
    score = shown,
    rawScore = score,  -- unrounded (clamped) score; lets tests pin a boundary the rounding hides
    band = band,
    signals = {
      decisionCount = decisionCount, denyCount = denyCount, denyRate = denyRate,
      autoDenyHits = autoDenyHits, timeoutFallbacks = timeoutFallbacks,
      staleApprovals = staleApprovals, toolRequests = toolRequests,
    },
  }
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

-- Detect a session frozen on an API error. When a turn aborts on an API error (e.g.
-- ECONNRESET) WITHOUT firing a Stop hook, the session sits in "working" forever; Claude
-- Code records the failure as a { type = "system", subtype = "api_error" } transcript
-- line. Scanning the tail backwards, return the error's display text IF that error is the
-- LATEST significant event -- a later `assistant`/`user` line means it recovered (or the
-- user already typed continue), so return nil. Meta lines (snapshots, stop_hook_summary)
-- are skipped. Pure; the caller (refresh) reads the tail and overrides the status.
function M.transcriptError(text)
  if not text or #text == 0 then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" then
        local t = obj.type
        if t == "assistant" or t == "user" then
          return nil  -- activity after any error -> recovered / no longer stuck
        elseif t == "system" and obj.subtype == "api_error" then
          local e = obj.error
          local msg = (type(e) == "table" and (e.formatted or e.message)) or "API error"
          return { message = tostring(msg) }
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
-- A queue is { tasks = { "task1", "task2", ... } }; nil/missing is empty. The
-- 4c-E arm flag (routing = true) rides in the same file, so EVERY function that
-- rebuilds a queue must carry it through `qkeep` -- a pop/move/push that
-- dropped it would silently disarm the project on the next write.
local function qtasks(q)
  if type(q) == "table" and type(q.tasks) == "table" then return q.tasks end
  return {}
end
local function qkeep(q, out)
  if type(q) == "table" and q.routing == true then out.routing = true end
  return out
end

function M.queueDepth(q) return #qtasks(q) end

function M.queuePush(q, task)
  local t = {}
  for _, x in ipairs(qtasks(q)) do t[#t + 1] = x end
  if task and #task > 0 then t[#t + 1] = task end
  return qkeep(q, { tasks = t })
end

-- Returns the front task and the queue without it.
function M.queuePop(q)
  local src = qtasks(q)
  if #src == 0 then return nil, qkeep(q, { tasks = {} }) end
  local rest = {}
  for i = 2, #src do rest[#rest + 1] = src[i] end
  return src[1], qkeep(q, { tasks = rest })
end

-- Concatenate two queues (a's tasks first). Used when adopting a legacy
-- session-keyed queue file into the project-keyed one -- `a` is the DESTINATION
-- (project) queue, so its arm flag wins.
function M.queueMerge(a, b)
  local t = {}
  for _, x in ipairs(qtasks(a)) do t[#t + 1] = x end
  for _, x in ipairs(qtasks(b)) do t[#t + 1] = x end
  return qkeep(a, { tasks = t })
end

-- Move tasks[idx] by dir (-1 = up toward the front, +1 = down). The panel's
-- rendered list can be STALE (the 1s autofeed loop pops heads asynchronously),
-- so `expect` -- the task text the operator clicked -- must match tasks[idx] or
-- the move is refused; the caller replies with the fresh list so the UI
-- self-heals. Returns newQueue, moved(boolean); refusals return an unchanged
-- copy in the standard { tasks = ... } shape.
function M.queueMove(q, idx, dir, expect)
  local src = qtasks(q)
  local t = {}
  for _, x in ipairs(src) do t[#t + 1] = x end
  idx = tonumber(idx)
  dir = tonumber(dir)
  if not idx or not dir or (dir ~= -1 and dir ~= 1) then return qkeep(q, { tasks = t }), false end
  local j = idx + dir
  if idx < 1 or idx > #t or j < 1 or j > #t then return qkeep(q, { tasks = t }), false end
  if expect ~= nil and t[idx] ~= expect then return qkeep(q, { tasks = t }), false end
  t[idx], t[j] = t[j], t[idx]
  return qkeep(q, { tasks = t }), true
end

-- Remove tasks[idx] (same expect guard as queueMove). Returns newQueue,
-- removedTask|nil -- nil means the remove was refused/out of range.
function M.queueRemoveAt(q, idx, expect)
  local src = qtasks(q)
  local t = {}
  for _, x in ipairs(src) do t[#t + 1] = x end
  idx = tonumber(idx)
  if not idx or idx < 1 or idx > #t then return qkeep(q, { tasks = t }), nil end
  if expect ~= nil and t[idx] ~= expect then return qkeep(q, { tasks = t }), nil end
  local removed = table.remove(t, idx)
  return qkeep(q, { tasks = t }), removed
end

-- Split a multi-line queue input into tasks: one per line, CRLF-tolerant,
-- trimmed, blanks dropped, leading list markers stripped ("- x", "* x",
-- "3. x", "3) x" -> "x"). The splitting authority lives HERE (not in JS) so
-- the bulk-add bridge action and its tests agree on the rules.
function M.queueSplitLines(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    line = line:gsub("^[-*]%s+", ""):gsub("^%d+[.%)]%s+", "")
    -- a line that was ONLY a marker ("- ", "3.") trims to the bare marker --
    -- drop it (it's list scaffolding, not a task). "-x flag" stays a task.
    if line:match("^[-*]$") or line:match("^%d+[.%)]$") then line = "" end
    if #line > 0 then out[#out + 1] = line end
  end
  return out
end

-- One read-modify-write for a bulk add (queuePush semantics over a list:
-- empties dropped, order preserved). Returns the new queue.
function M.queuePushAll(q, tasks)
  local out = q
  for _, task in ipairs(tasks or {}) do out = M.queuePush(out, task) end
  -- normalize shape even when nothing was added (queuePush carried the arm flag)
  return qkeep(out ~= nil and out or q, { tasks = qtasks(out) })
end

-- The on-disk key for a session's task queue. Queues are keyed by the STABLE
-- projectKey (launch folder, falling back to cwd) rather than the per-session
-- tile key: a respawn or /clear gives the project a NEW session_id, so a
-- session-keyed queue file would be stranded forever (invisible to the successor
-- tile) the moment auto-respawn or ghost-prune replaces the session. Project
-- keying means the successor inherits the pending tasks automatically (and
-- parallel sessions in one folder deliberately share the queue). Sanitized the
-- same way cc_sanitize does (anything outside [A-Za-z0-9._-] -> "_") so it's a
-- safe filename. Falls back to the tile key when there's no project identity.
function M.queueKey(item)
  local pk = item and (item.projectKey or item.cwd)
  if type(pk) == "string" and pk ~= "" then
    return (pk:gsub("[^%w._%-]", "_"))
  end
  return item and item.key or nil
end

-- After ATTEMPTING to feed a queued task, decide what to persist/record. The FX
-- paste path reports delivery (false = the no-window-match guard skipped the
-- paste); only a DELIVERED feed may pop the queue -- persisting the shortened
-- queue after a skipped paste silently destroys the operator's queued task and
-- writes a false task_feed audit event.
function M.queueFeedCommit(delivered)
  if delivered then return { persist = true, event = "task_feed" } end
  return { persist = false, event = "task_feed_skipped" }
end

-- Feed the next task only on a FRESH transition into `done`, when the queue is
-- non-empty and auto-feed is on. (prev==done means we already handled it. prev==nil
-- means NO prior observation -- the first refresh after a Hammerspoon reload, since
-- the prev snapshot is in-memory while queue files persist on disk -- so it can't
-- be a fresh transition either: counting it would re-feed on every reload.)
function M.shouldFeed(prev, cur, q, autoOn)
  if not autoOn then return false end
  if M.queueDepth(q) == 0 then return false end
  return cur == "done" and prev ~= nil and prev ~= "done"
end

-- ---- Project routing (4c-E, roadmap orchestrator) ---------------------------
-- With routing armed, a project's queue feeds WHICHEVER session of that project
-- is free -- not just the one that finished (4b's edge trigger can't reach a
-- session that was already done when the task was queued). Level-triggered: a
-- single dispatcher per refresh tick picks at most ONE target per project; an
-- in-memory routePending marker keeps the next tick from double-feeding the
-- same session while its status file still says `done` (the paste hasn't
-- flipped it to `working` yet). Double opt-in: queue.routing.enabled (global)
-- AND routing:true in the project's queue file. All off by default.

-- The per-project arm flag rides INSIDE the queue file so it inherits the
-- projectKey keying + respawn survival for free. Accessors keep the file-shape
-- knowledge in one place; queueSetRouted preserves tasks.
function M.queueRouted(q)
  return type(q) == "table" and q.routing == true
end
function M.queueSetRouted(q, on)
  local out = { tasks = qtasks(q) }
  if on then out.routing = true end  -- absent (not false) when off: legacy shape
  return out
end

-- Has a pending routed feed resolved? satisfied = the session left done/idle
-- (the paste landed: working/approval/...); expired = the marker outlived
-- `timeout` seconds (lost feed -- no-window-match, kill, etc). Caller clears
-- the map entry when true.
function M.routePendingDone(ts, status, now, timeout)
  if ts == nil then return false end
  if status ~= "done" and status ~= "idle" then return true end
  return ((tonumber(now) or 0) - (tonumber(ts) or 0)) > (tonumber(timeout) or 45)
end

M.ROUTE_PENDING_TIMEOUT = 45

-- Is this session eligible to receive routed work? v1 is deliberately
-- done-only: an `idle` session may be one the operator is actively typing
-- into, and a routed paste would land in their prompt (idle-inclusion is a
-- flagged follow-up). Excludes stale/error/remote/draining sessions and ones
-- with a FRESH pending routed feed (an expired marker no longer blocks).
function M.sessionFree(item, opts)
  opts = opts or {}
  if type(item) ~= "table" then return false end
  if item.status ~= "done" then return false end
  if item.stale then return false end
  if item.remote then return false end
  if opts.draining then return false end
  if opts.pending ~= nil then
    local expired = ((tonumber(opts.now) or 0) - (tonumber(opts.pending) or 0))
      > (tonumber(opts.pendingTimeout) or M.ROUTE_PENDING_TIMEOUT)
    if not expired then return false end
  end
  return true
end

-- Pick the target for one project's next task. Deterministic: longest-free
-- first (smallest `since` -- the status file stamps it on each status change),
-- key ascending as the tiebreak; a missing `since` reads as "just changed"
-- (lowest priority). members = parsed items sharing one queueKey. opts =
-- { draining = map key->bool, pending = map key->ts, now, pendingTimeout }.
-- Returns the chosen tile key, or nil when no member is free.
function M.routePick(members, opts)
  opts = opts or {}
  local draining = opts.draining or {}
  local pending = opts.pending or {}
  local best, bestSince
  for _, it in ipairs(members or {}) do
    if M.sessionFree(it, { draining = draining[it.key], pending = pending[it.key],
                           now = opts.now, pendingTimeout = opts.pendingTimeout }) then
      local since = tonumber(it.since) or math.huge
      if best == nil or since < bestSince
         or (since == bestSince and tostring(it.key) < tostring(best)) then
        best, bestSince = it.key, since
      end
    end
  end
  return best
end

-- The whole per-project decision: should the dispatcher feed this tick?
-- Requires opts.globalOn AND the queue file armed AND depth > 0 AND a free
-- pick. Returns { key = <tile key> } or nil.
function M.routeTask(members, q, opts)
  opts = opts or {}
  if not opts.globalOn then return nil end
  if not M.queueRouted(q) then return nil end
  if M.queueDepth(q) == 0 then return nil end
  local key = M.routePick(members, opts)
  if not key then return nil end
  return { key = key }
end

-- Starvation check: an armed project with queued work and NO free session for
-- longer than `minutes`. sinceTs = when the caller first observed the starved
-- condition (it keeps the clock; pure here). minutes <= 0 disables.
function M.queueStarved(members, q, opts)
  opts = opts or {}
  local minutes = tonumber(opts.minutes) or 0
  if minutes <= 0 then return false end
  if not M.queueRouted(q) or M.queueDepth(q) == 0 then return false end
  if M.routePick(members, opts) ~= nil then return false end
  local sinceTs = tonumber(opts.sinceTs)
  if not sinceTs then return false end
  return ((tonumber(opts.now) or 0) - sinceTs) > minutes * 60
end

-- ---- Graceful drain (Feature F) --------------------------------------------
-- Close a session only AFTER it finishes the in-flight turn: fire on the same
-- fresh transition into `done` that shouldFeed uses (prev==done means we already
-- handled it), but only when the operator armed drain for this tile. The draining
-- flag is an in-memory panel intent (not a file) -- a Hammerspoon reload clears it
-- so a stale "close on next done" can't fire on a session you've since resumed.
function M.shouldDrainClose(draining, prev, cur)
  if not draining then return false end
  return cur == "done" and prev ~= "done"
end

-- The tile's "draining" badge: visible only while the feature is on AND the
-- operator armed drain for this tile (the in-memory panel intent). Returns nil
-- (not false) when hidden so the encoded tile payload omits the field entirely.
function M.drainingBadge(drainOn, armed)
  return (drainOn and armed) and true or nil
end

-- ---- Auto-respawn on unexpected death (opt-in, bounded) --------------------
-- Should we relaunch a session that appears to have died unexpectedly? Fires ONCE
-- on the fresh transition into frozen (wasStale=false -> isStale=true, where the
-- caller computes the flag against the RESPAWN threshold -- see stepAutoRespawn --
-- not the 90s display staleness) for a real session (one that has a session_id,
-- so respawnSpec can faithfully rebuild it), as long as the operator didn't
-- intentionally close/drain it and we're under the per-folder retry cap. The
-- threshold latency is the natural backoff between attempts (a relaunch that also
-- dies is a fresh edge -> the next attempt, until the cap), so no separate timer
-- is needed. Pure gate; the dashboard owns the attempt bookkeeping + the actual
-- spawn. args =
--   { wasStale, isStale, status, hasSession, intentional, attempts, maxRetries }
function M.shouldAutoRespawn(args)
  args = args or {}
  if args.intentional then return false end                     -- user closed/drained it
  if not args.hasSession then return false end                  -- orphan: nothing to relaunch faithfully
  -- Only a session frozen at `working` reads as dead. Status files are written
  -- only by hook events (no heartbeat), so stale done/idle is the NORMAL
  -- between-turns state, never a death; a clean exit fires SessionEnd (which
  -- deletes the tile); an API-error freeze is resumed via Continue instead. And
  -- a stale `approval` is by definition waiting on a HUMAN (escalation expects
  -- multi-minute waits) -- stale-approval escalation owns that case, never a
  -- respawn that would destroy the tile the user was about to Approve on.
  if args.status ~= "working" then return false end
  if args.wasStale or not args.isStale then return false end    -- only the fresh false->true edge
  local cap = tonumber(args.maxRetries) or 0
  if cap <= 0 then return false end                             -- 0/absent = disabled
  return (tonumber(args.attempts) or 0) < cap                   -- under the per-folder budget
end

-- Advance auto-respawn bookkeeping for one tile per tick; return whether to relaunch
-- now. Mutates `attempts` (projectKey -> count) in place; the projectKey is folded
-- into the gate so a keyless tile can't nil-key write. A retry is charged ONLY when
-- the tile fires the death edge AND is actually rebuildable (opts.canRespawn), so an
-- un-respawnable death doesn't burn the folder budget. The caller stores the returned
-- `isStale` for next tick's wasStale (the edge contract); the spawn / removeStatus /
-- "not respawnable" logging stay in the dashboard, which holds the respawnSpec.
--   attempts : table (mutated)
--   item     : { projectKey, cwd, status, stale, updated, session_id, since }
--   opts     : { enabled, maxRetries, intentional, wasStale, canRespawn, now,
--                staleSeconds, respawnStaleSeconds }
-- returns:
--   spawn     = edge fired AND canRespawn ~= false (a real relaunch; budget charged)
--   wouldFire = edge fired (under cap, not intentional), regardless of canRespawn
--   isStale, attempts (this folder's count or nil)
function M.stepAutoRespawn(attempts, item, opts)
  attempts = attempts or {}
  opts = opts or {}
  item = item or {}
  local pk = item.projectKey or item.cwd
  -- Healthy -> reset the folder budget, but ONLY after sustained health. A freshly
  -- relaunched tile is non-stale by construction (SessionStart just wrote it), so
  -- resetting on first sight would wipe the budget ~90s before the relaunch could
  -- possibly re-edge -- maxRetries would never bind and a crash loop respawns
  -- forever. `since` is when the tile entered its current status (cc-status.sh
  -- keeps it across same-status updates); require it to have survived a full stale
  -- window. No now/since/staleSeconds -> fail closed (keep the budget).
  if not (item.stale or false) and pk and opts.now and opts.staleSeconds and item.since
    and (opts.now - item.since) > opts.staleSeconds then
    attempts[pk] = nil
  end
  -- Death evidence needs MUCH more silence than the 90s display staleness: no
  -- hook fires between PreToolUse and PostToolUse (nor during a long no-tool
  -- reasoning segment), so a perfectly healthy session running one long build/
  -- test command (Bash defaults to 120s, max 600s) freezes `updated` at
  -- status=working for minutes. The respawn arm therefore uses its own, much
  -- larger threshold (respawn.auto.staleSeconds, default 600s -- above the
  -- tool-timeout ceiling) computed from the status file's `updated` stamp.
  -- Missing clock/updated/threshold -> fail closed (no death evidence, no fire).
  local rss = tonumber(opts.respawnStaleSeconds)
  local frozen = (opts.now ~= nil and item.updated ~= nil and rss ~= nil
    and (opts.now - item.updated) > rss) or false
  local wouldFire, spawn = false, false
  if opts.enabled and pk then
    local n = attempts[pk] or 0
    wouldFire = M.shouldAutoRespawn({
      wasStale = opts.wasStale or false, isStale = frozen, status = item.status,
      hasSession = (item.session_id ~= nil and item.session_id ~= ""),
      intentional = opts.intentional and true or false,
      attempts = n, maxRetries = opts.maxRetries })
    if wouldFire and opts.canRespawn ~= false then             -- only charge on a real relaunch
      spawn = true
      attempts[pk] = n + 1
    end
  end
  return { spawn = spawn, wouldFire = wouldFire, isStale = frozen, attempts = pk and attempts[pk] or nil }
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
-- the project a NEW session_id (a new tile) while the old session_id's status file
-- lingers with no SessionEnd. Returns the keys of tiles that are stale AND share a
-- live twin IN THE SAME PROJECT *and the same terminal window*. The live twin is
-- matched by the STABLE projectKey (launch folder, falling back to cwd), NOT the
-- basename `name`: two sessions in DIFFERENT folders that merely share a basename
-- have the same name but different projectKeys, so name-keying would cross-prune an
-- unrelated stale tile -- which also silently swallows that session's auto-respawn
-- (it's removed before the respawn loop).
-- Staleness alone is NOT death evidence: status files only change on hook events,
-- so every alive session goes stale ~90s after finishing its turn -- with two
-- parallel sessions in one folder, the resting one would otherwise be pruned while
-- it sits alive holding its result. The shared terminal IS the evidence: a /clear
-- reuses the same window (matching kitty identity), while genuine parallel sessions
-- occupy distinct windows. Tiles with no terminal identity (non-kitty editors) are
-- never pruned here; the 24h shouldPrune backstop owns that cleanup.
function M.staleDuplicateKeys(list)
  local function projKey(it) return it.projectKey or it.cwd end
  local function termId(it)  -- kitty socket+window pair; nil when unknown
    local sock, wid = it.kitty_listen_on, it.kitty_window_id
    -- A HALF identity is NO identity: kitty exports KITTY_WINDOW_ID always but
    -- KITTY_LISTEN_ON only when remote control is configured, and window ids are
    -- a per-INSTANCE counter from 1 -- so two default-config kitty instances both
    -- yield window "1". Without the instance-disambiguating socket, matching on
    -- the bare wid would prune a live parallel session as a false twin; fall to
    -- the never-prune-here safe side instead (24h shouldPrune backstop cleans up).
    if sock == nil or sock == "" or wid == nil or wid == "" then return nil end
    return tostring(sock) .. "#" .. tostring(wid)
  end
  local liveTerms = {}  -- projectKey -> { [termId] = true } for non-stale tiles
  for _, it in ipairs(list or {}) do
    local pk, tid = projKey(it), termId(it)
    if not it.stale and pk and tid then
      liveTerms[pk] = liveTerms[pk] or {}
      liveTerms[pk][tid] = true
    end
  end
  local keys = {}
  for _, it in ipairs(list or {}) do
    local pk, tid = projKey(it), termId(it)
    if it.stale and pk and tid and liveTerms[pk] and liveTerms[pk][tid] then
      keys[#keys + 1] = it.key
    end
  end
  return keys
end

-- ---- Same-directory collision warning (Feature B) --------------------------
-- Flag tiles where 2+ ACTIVE sessions (working/approval, not stale -- i.e. the
-- ones that could be writing right now) share a working dir, so two agents editing
-- the same repo don't silently clobber each other. Detection only (we can't lock
-- another process's writes). Grouping key is opts.rootByCwd[cwd] (a precomputed
-- git-root, injected so this stays pure -- never shells out), falling back to the
-- raw cwd when there's no resolved root. Returns { flags = {[key]=true}, groups =
-- {[groupKey]={key,...}} } for groups of size >= 2.
function M.collisions(items, opts)
  opts = opts or {}
  local rootByCwd = opts.rootByCwd
  local groups = {}
  for _, it in ipairs(items or {}) do
    local active = (it.status == "working" or it.status == "approval") and not it.stale
    if active and it.cwd and it.cwd ~= "" then
      local root = rootByCwd and rootByCwd[it.cwd]
      local gk = (type(root) == "string" and root ~= "") and root or it.cwd
      local g = groups[gk]
      if not g then g = {}; groups[gk] = g end
      g[#g + 1] = it.key
    end
  end
  local flags, outGroups = {}, {}
  for gk, keys in pairs(groups) do
    if #keys >= 2 then
      table.sort(keys)
      outGroups[gk] = keys
      for _, k in ipairs(keys) do flags[k] = true end
    end
  end
  return { flags = flags, groups = outGroups }
end

-- ---- Policy A: stale-approval escalation -----------------------------------
-- True when a session has been waiting for you (status "approval") longer than
-- thresholdSec. (`since` is when it entered the approval state.)
function M.approvalStale(item, now, thresholdSec)
  if not item or item.status ~= "approval" or not item.since then return false end
  return (now - item.since) > thresholdSec
end

-- ---- Stuck-session watchdog (working-stall escalation) ---------------------
-- Is a session stuck mid-turn? True when it's `working`, not stale, and its
-- transcript hasn't grown for longer than thresholdSec. lastProgressTs is when the
-- caller last saw the transcript grow (tracked in the dashboard from the bytes the
-- activity peek already reads). A session with no recorded progress yet
-- (lastProgressTs nil) isn't flagged -- we only flag a stall we can actually time.
-- Complements approvalStale: that covers a session waiting on YOU; this covers one
-- wedged on its own (an infinite tool loop, a hung command) that never escalates.
function M.isHung(item, lastProgressTs, now, thresholdSec)
  if not item or item.status ~= "working" or item.stale then return false end
  if not lastProgressTs then return false end
  return ((tonumber(now) or 0) - (tonumber(lastProgressTs) or 0)) > (tonumber(thresholdSec) or 0)
end

-- Transcript-progress tracker for the watchdog (pure; the dashboard holds the state
-- and feeds the current file size). Returns the new { size, ts }: any size change
-- rebases the stall timer to `now`. A SHRINK counts as progress too -- it means the
-- transcript was rotated/truncated, and a stale larger size must not freeze the timer
-- and falsely trip the watchdog. The inline cases cover seed / hold / nil-hold.
function M.trackProgress(prevSize, prevTs, sz, now)
  if sz == nil then return { size = prevSize, ts = prevTs } end
  if prevSize == nil then return { size = sz, ts = now } end       -- first sight: seed
  if sz ~= prevSize then return { size = sz, ts = now } end        -- grew or rotated: progress
  return { size = prevSize, ts = prevTs }                          -- unchanged: keep timing
end

-- Merge a trackProgress update onto a watchdog entry. The dashboard stores the
-- result back at watchdog[key]. Mutates-and-returns `w` when it exists (allocating a
-- fresh { size, ts } when nil). The stall-alert flag is RE-ARMED on progress: when
-- trackProgress rebases the timer (a size change == the stall ended), `alerted` is
-- cleared so a LATER stall in the same working stint nags again ("once per stall",
-- not "once per working stint"); on a held tick (no change) `alerted` survives so a
-- continuous stall isn't re-nagged every second. NOTE: unlike trackProgress, this
-- MUTATES its first arg.
function M.applyProgress(w, sz, now)
  local p = M.trackProgress(w and w.size, w and w.ts, sz, now)
  if w then
    if p.ts ~= w.ts then w.alerted = nil end  -- progress -> stall ended: re-arm
    w.size, w.ts = p.size, p.ts
    return w
  end
  return { size = p.size, ts = p.ts }
end

-- Should the watchdog state for a session be cleared this tick? Reset when it isn't
-- actively `working`, and also while it's stale: the growth path is skipped during
-- stale, so a frozen lastProgressTs must not survive to flag hung the instant it
-- un-stales (each working stint then times its own stall from scratch).
function M.watchdogShouldReset(status, stale)
  return status ~= "working" or stale == true
end

-- Should a pathwatcher event batch trigger a refresh? false when every changed
-- path is the panel's own heartbeat: refresh() writes .panel-alive INTO the
-- watched status dir each tick, so reacting to it would make every refresh
-- schedule the next one (a self-sustaining loop at FSEvents latency).
function M.watcherShouldRefresh(paths)
  for _, p in ipairs(paths or {}) do
    if not tostring(p):find("/.panel-alive", 1, true) then return true end
  end
  return false
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

-- Overlay the Settings-managed keys onto an existing config, per TOP-LEVEL key,
-- so hand-edited blocks the UI doesn't expose survive a Save. Also carries
-- forward the UI-unmanaged SUBKEYS inside blocks the form rebuilds wholesale --
-- spawn.kittyBin / spawn.kittySocket, escalation.hung, and risk.weights (the
-- 9-key tuning map stays hand-edit-only; the form manages risk.enabled +
-- risk.thresholds) would otherwise be silently deleted by every Save (including
-- the auto-persisting Headless toggle). A generic deep merge is deliberately
-- avoided: array-valued keys (providers, policies.patterns.*) must be REPLACED,
-- not index-merged. Mutates + returns cfg.
M.SETTINGS_KEEP_SUBKEYS = {
  spawn = { "kittyBin", "kittySocket", "searchRoots", "searchDepth", "fdBin", "claudeBin" },
  escalation = { "hung" },
  risk = { "weights" },
  bridge = { "staleSlackSeconds", "keystrokes" },
}
function M.overlayConfig(cfg, incoming)
  cfg = type(cfg) == "table" and cfg or {}
  if type(incoming) ~= "table" then return cfg end
  for block, subs in pairs(M.SETTINGS_KEEP_SUBKEYS) do
    if type(cfg[block]) == "table" and type(incoming[block]) == "table" then
      for _, k in ipairs(subs) do
        if incoming[block][k] == nil then incoming[block][k] = cfg[block][k] end
      end
    end
  end
  for k, v in pairs(incoming) do cfg[k] = v end
  return cfg
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

-- Resolve a session's EFFECTIVE gated-tools list (Feature D: per-session least
-- privilege). Precedence: per-session override > provider/mode default > fleet
-- `gate.tools` > the built-in default. The override may be the sentinel "-"/"NONE"
-- meaning "gate NOTHING for this session" (returns ""), distinct from no override
-- (absent file -> falls through to the fleet default). A blank string is NOT an
-- override (it falls back to the fleet default too). providerDefault is reserved for a
-- future per-provider layer (pass nil for v1). Output is normalized via parseToolList.
-- KEEP IN SYNC with the per-session override `case` block in cc-approve.sh (the shell
-- hot path): both must agree that `-`/`none` gates nothing AND that an empty/whitespace
-- value is NOT an override (falls back to the fleet default, not "gate nothing").
function M.resolveGateTools(override, providerDefault, fleetDefault)
  local function present(s) return type(s) == "string" and s:match("%S") ~= nil end
  if present(override) then
    local t = override:gsub("%s+", "")
    if t == "-" or t:upper() == "NONE" then return "" end
    return M.parseToolList(override)
  end
  if present(providerDefault) then return M.parseToolList(providerDefault) end
  if present(fleetDefault) then return M.parseToolList(fleetDefault) end
  return M.DEFAULT_GATE_TOOLS
end

-- ---- Installer: merge our hooks into the user's settings (Part E) ----------
-- Merge `template.hooks` into `existing` settings, idempotently. Per event: if no
-- cc-*.sh hook is wired yet we add the template's group(s) (appending after any
-- of the user's own hooks for that event); if ours are already present (re-run),
-- leave it untouched. All other settings keys are preserved. Returns newSettings,
-- changed(bool) -- so the installer can skip a no-op write.
-- Shepherd's own hook scripts. hasOurs matches these EXACT basenames (not a bare
-- "cc-" substring) so a user's own cc-prefixed hook doesn't suppress wiring. The
-- match is an UNANCHORED substring -- commands appear both bare (`bash cc-status.sh`)
-- and pathed (`/x/cc-status.sh`), so we can't anchor on a leading `/`; a contrived
-- user hook whose basename ENDS in one of these (e.g. my-cc-status.sh) is a false
-- positive, acceptable next to the old bare-"cc-" net. KEEP IN SYNC with install.sh's
-- jq `any(test("cc-(status|approve|popup)\\.sh"))`.
M.OUR_HOOK_SCRIPTS = { "cc-status.sh", "cc-approve.sh", "cc-popup.sh" }
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
          if type(h) == "table" and type(h.command) == "string" then
            -- Match Shepherd's OWN script basenames, not a bare "cc-" substring: a
            -- user's own cc-prefixed hook (cc-notify.sh, the natural Claude Code "cc-"
            -- convention) must NOT count as "already wired" and make us skip this event.
            for _, name in ipairs(M.OUR_HOOK_SCRIPTS) do
              if h.command:find(name, 1, true) then return true end
            end
          end
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

-- Which provider key should a spawn resolve? nil providerId = NO pick at all
-- (hotkey/dialog path) -> the spawn.provider default; "" = the EXPLICIT
-- "(none -- bare claude)" pick (the modal's first option, and the sentinel the
-- respawn paths pass for a faithful bare relaunch) -> no provider at all. The
-- two must not collapse, or an explicit bare pick silently runs on the default
-- gateway (wrong endpoint/auth/model).
function M.spawnProviderKey(cfg, providerId)
  if providerId == nil then return M.config(cfg, "spawn.provider", nil) end
  if tostring(providerId) == "" then return nil end
  return providerId
end

-- Find a provider profile by its running model (+ base URL), for Feature F's
-- respawn -- a tile records `model`/`base_url` but not the provider id it launched
-- from. Anthropic sessions (no base_url) match a profile by model alone; gateway
-- sessions (base_url set) require BOTH model and baseUrl to match, so a respawn
-- reconstructs the right endpoint + auth env. nil if nothing matches.
function M.providerByModel(cfg, model, baseUrl)
  local list = M.config(cfg, "providers", nil)
  if type(list) ~= "table" or not model then return nil end
  local hasBase = baseUrl ~= nil and tostring(baseUrl) ~= ""
  for _, p in ipairs(list) do
    if type(p) == "table" and tostring(p.model) == tostring(model) then
      -- Only a GATEWAY profile has a base-URL signature: a claude/anthropic
      -- profile never exports ANTHROPIC_BASE_URL, so a stale baseUrl left over
      -- from a kind switch must not defeat the base-less match (it would turn
      -- a faithful respawn into a bare `claude` on the wrong model).
      local isGateway = tostring(p.kind or "anthropic") == "gateway"
      local pBase = (isGateway and p.baseUrl ~= nil and tostring(p.baseUrl) ~= "") and tostring(p.baseUrl) or nil
      if hasBase then
        if pBase == tostring(baseUrl) then return p end
      elseif not pBase then
        return p
      end
    end
  end
  return nil
end

-- Reconstruct the spawn arguments to relaunch a dead/stale session (Feature F).
-- Pure: returns the structured args FX.spawnSession needs, NOT a side effect.
-- editor/permission_mode/cwd come straight off the tile; the provider is matched
-- from model(+base_url) via providerByModel. A bare-Anthropic session yields
-- providerId=nil (faithful bare `claude`). A gateway session whose profile is no
-- longer in `providers` can't be rebuilt (its auth env is unknown) -> canRespawn
-- false with a reason the UI can surface. No initial task: it's a relaunch.
function M.respawnSpec(item, cfg)
  if type(item) ~= "table" then return { canRespawn = false, reason = "no session" } end
  local project = item.cwd
  if not project or tostring(project) == "" then
    return { canRespawn = false, reason = "unknown working dir" }
  end
  local editor = item.editor
  if not editor or tostring(editor) == "" then editor = M.config(cfg, "spawn.editor", "terminal") end
  local hasBase = item.base_url ~= nil and tostring(item.base_url) ~= ""
  local profile = M.providerByModel(cfg, item.model, item.base_url)
  if hasBase and not profile then
    return { canRespawn = false, reason = "unknown gateway provider" }
  end
  return {
    canRespawn = true,
    editor = tostring(editor),
    project = project,
    permissionMode = item.permission_mode,
    providerId = profile and profile.id or nil,
  }
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

-- Run `inner` under an INTERACTIVE login zsh when it carries provider env.
-- Command shells (kitty argv, sshd's `shell -c`) are non-interactive and never
-- source ~/.zshrc -- where the README tells users to export the authTokenEnv
-- secret -- so plain execution expands `$MY_KEY` to "" and every gateway call
-- 401s. `-lic` sources .zshenv/.zprofile/.zshrc before exec'ing the command.
-- No env to expand -> inner unchanged (the no-provider spawn keeps its shape).
function M.loginShellWrap(inner, env, shell)
  if type(env) ~= "table" or #env == 0 then return inner end
  return tostring(shell or "zsh") .. " -lic " .. shquote(inner)
end

-- Wrap a remote command for SSH (Phase 2 -- run `claude` ON another machine while
-- the terminal window stays local, so keystroke effects still target it). The whole
-- command is single-quoted so its inner `$VAR` secrets expand on the REMOTE host,
-- never locally. sshd runs a supplied command via `shell -c` -- NON-login,
-- NON-interactive, so neither remote .zshrc nor .zprofile is sourced -- so when
-- the inner carries provider env, run it under an interactive login zsh there
-- (loginShellWrap; the remote ~/.zshrc is the README-documented home for the
-- secret). `-t` forces a TTY so claude's TUI works.
-- ssh = { host, user(optional), tty(default true) }.
-- "user@host" (or bare "host") for an ssh spec; nil when there's no usable host.
-- The ONE place dest formatting lives (sshWrap, spawnSpec, and the status
-- bridge all build from it).
function M.sshDest(ssh)
  if type(ssh) ~= "table" or not ssh.host or tostring(ssh.host) == "" then return nil end
  return (ssh.user and tostring(ssh.user) ~= "")
    and (tostring(ssh.user) .. "@" .. tostring(ssh.host)) or tostring(ssh.host)
end

function M.sshWrap(inner, ssh, env)
  local dest = M.sshDest(ssh)
  if not dest then return inner end
  local cmd = (ssh.tty == false) and "ssh" or "ssh -t"
  return cmd .. " " .. dest .. " " .. shquote(M.loginShellWrap(inner, env))
end

-- ---- SSH status bridge (roadmap #7, Phase 2) --------------------------------
-- Remote sessions (spawned via ssh providers) write status JSON in the REMOTE
-- ~/.claude/cc-status/ -- invisible locally. The bridge rsync-pulls each ssh
-- host's dir into a local mirror, merges those entries into refreshList with
-- HOST-NAMESPACED keys, and routes headless Approve/Deny back over ssh as
-- nonce-bound decision files. Everything here is pure (argv builders, key
-- namespacing, merge); the rsync/ssh executions are FX effects. Off unless
-- bridge.enabled AND a provider declares ssh. Remote tiles are HEADLESS-ONLY
-- in v1: ssh -t forwards TERM (so the remote hook detects "kitty") but not
-- KITTY_WINDOW_ID -- keystroke actions would silently no-op, so they're gated
-- off explicitly via remoteActionAllowed.

-- Namespace separator ":" can never appear in a local key (cc_sanitize strips
-- to [A-Za-z0-9._-]), so host:key is unambiguous and reversible. Namespaced
-- keys live IN MEMORY only -- mirror files keep their raw remote names, and
-- anything key->filename (queueKey) sanitizes ":" to "_" deterministically.
function M.namespaceKey(ns, key)
  return tostring(ns or "") .. ":" .. tostring(key or "")
end
-- Returns ns, rest for a namespaced key; nil, key for a local one.
function M.splitNamespacedKey(key)
  key = tostring(key or "")
  local ns, rest = key:match("^([^:]+):(.+)$")
  if ns then return ns, rest end
  return nil, key
end

-- Unique bridge targets from config: providers carrying ssh:{host,user}, deduped
-- by dest. Gated on bridge.enabled (default OFF -- the bridge never runs from
-- config alone). ns = host label sanitized for use as a dir name + key prefix.
function M.sshHosts(cfg)
  if M.config(cfg, "bridge.enabled", false) ~= true then return {} end
  local out, seen = {}, {}
  for _, p in ipairs(M.config(cfg, "providers", nil) or {}) do
    if type(p) == "table" and type(p.ssh) == "table" then
      local dest = M.sshDest(p.ssh)
      if dest and not seen[dest] then
        seen[dest] = true
        out[#out + 1] = {
          host = tostring(p.ssh.host),
          user = p.ssh.user and tostring(p.ssh.user) or nil,
          dest = dest,
          ns = (tostring(p.ssh.host):gsub("[^%w.-]", "_")),
        }
      end
    end
  end
  return out
end

-- argv for one mirror pull (binary "rsync" first -- resolveBin'd by FX).
-- BatchMode=yes is load-bearing: without it a passphrase prompt hangs the task
-- forever and the skip-if-running guard then starves the host. The remote path
-- is home-relative (".claude/...") to dodge ~-expansion differences; --delete
-- makes the mirror track remote truth (a remote SessionEnd removes the tile).
function M.rsyncArgv(dest, mirrorDir, opts)
  if not dest or tostring(dest) == "" then return nil end
  opts = opts or {}
  return { "rsync", "-az", "--delete",
           "--timeout=" .. tostring(tonumber(opts.timeout) or 5),
           "-e", "ssh -oBatchMode=yes -oConnectTimeout=" .. tostring(tonumber(opts.connectTimeout) or 3),
           tostring(dest) .. ":.claude/cc-status/",
           tostring(mirrorDir) .. "/" }
end

-- Parse ONE host's mirror entries into status items: parseStatusList plus, per
-- item: key namespaced (host:key, raw key kept as remoteKey), remote = the host
-- spec, projectKey namespaced too (the same repo cloned at the same path on two
-- boxes yields an IDENTICAL /projects/<ENC>/ segment -- un-namespaced it would
-- silently share queues/labels/respawn budgets with the local clone), and
-- staleness widened by opts.slack (rsync lag + clock skew).
function M.parseMirrorList(hostSpec, entries, now, staleSeconds, opts)
  opts = opts or {}
  local slack = tonumber(opts.slack) or 15
  local list = M.parseStatusList(entries, now, (tonumber(staleSeconds) or M.STALE_SECONDS) + slack)
  for _, it in ipairs(list) do
    it.remoteKey = it.key
    it.key = M.namespaceKey(hostSpec.ns, it.key)
    it.remote = { host = hostSpec.host, dest = hostSpec.dest, ns = hostSpec.ns }
    if it.projectKey then it.projectKey = M.namespaceKey(hostSpec.ns, it.projectKey) end
  end
  return list
end

-- Merge local + mirror lists and re-sort. Collisions are impossible by
-- construction (every remote key carries ":", no local key can).
function M.mergeStatusLists(a, b)
  local out = {}
  for _, it in ipairs(a or {}) do out[#out + 1] = it end
  for _, it in ipairs(b or {}) do out[#out + 1] = it end
  return M.sortByStatus(out)
end

-- The decision-file content for a verb, nonce-bound when the status JSON (text)
-- carries a pending nonce. Extracted from FX.writeDecision so the LOCAL write
-- and the REMOTE ssh write share one implementation: garbled/missing JSON
-- degrades to the bare verb (cc-approve.sh accepts both; a mismatched nonce is
-- ignored there, so the worst case is a no-op).
function M.decisionContent(value, statusText)
  local nonce
  pcall(function()
    local st = M.json.decode(tostring(statusText or ""))
    if type(st) == "table" and type(st.pending) == "table"
       and type(st.pending.nonce) == "string" and st.pending.nonce ~= "" then
      nonce = st.pending.nonce
    end
  end)
  return nonce and (tostring(value) .. " " .. nonce) or tostring(value)
end

-- argv for routing a decision back to the remote box. The remote write keeps
-- the temp+mv atomicity cc-approve.sh's poller relies on. Validation is the
-- injection guard -- the key and content are embedded in a remote shell line,
-- so anything outside the known-good shapes returns nil (never "best effort"):
--   remoteKey: ^[A-Za-z0-9._-]+$ (cc_sanitize's alphabet)
--   content:   ^(allow|deny)( <nonce in the same alphabet>)?$
function M.decisionSshArgv(dest, remoteKey, content)
  if not dest or tostring(dest) == "" then return nil end
  remoteKey = tostring(remoteKey or "")
  content = tostring(content or "")
  if not remoteKey:match("^[%w._%-]+$") then return nil end
  if not content:match("^allow$") and not content:match("^deny$")
     and not content:match("^allow [%w._%-]+$") and not content:match("^deny [%w._%-]+$") then
    return nil
  end
  local f = ".claude/cc-status/" .. remoteKey .. ".decision"
  return { "ssh", "-oBatchMode=yes", "-oConnectTimeout=3", tostring(dest),
           "printf %s '" .. content .. "' > '" .. f .. ".tmp' && mv '" .. f .. ".tmp' '" .. f .. "'" }
end

-- Which actions work on a remote tile. v1: headless approve/deny only (and only
-- while the remote gate is actually waiting -- there's no decision file to
-- consume otherwise). Keystroke actions (nudge/stop/clear/compact/focus/...)
-- need a local window the tile can't name; opts.keystrokes (bridge.keystrokes,
-- hardware-verify) is the future unlock. Autopilot/gate-tools arming is also
-- blocked: those are REMOTE-gate files -- arming them locally would lie.
function M.remoteActionAllowed(item, action, opts)
  if type(item) ~= "table" or not item.remote then return true end  -- local: no gate here
  opts = opts or {}
  if action == "approve" or action == "deny" then
    return item.gate == "waiting"
  end
  if opts.keystrokes then
    return action == "nudge" or action == "stop" or action == "clear" or action == "compact"
  end
  return false
end

-- How `claude` is referenced in a SHELL-STRING spawn. A bare `claude` breaks in
-- terminals whose PATH/aliases don't carry it (the VS Code integrated terminal
-- is the proven case: `zsh: command not found: claude` -- the alias lives in an
-- interactive zsh's rc, which that typed command line may not have). When the
-- caller resolved an absolute path (FX.claudeBin), embed it single-quoted
-- (paths can contain spaces); nil keeps the legacy bare word.
local function claudeRef(claudeBin)
  if claudeBin and tostring(claudeBin) ~= "" and tostring(claudeBin) ~= "claude" then
    return shquote(claudeBin)
  end
  return "claude"
end

-- The shell command run INSIDE the spawned terminal:
--   cd <project> && [ENV=... ] claude [flags] [prompt]
-- opts: { env = providerEnv list, flags = spawnFlags list, ssh = {host,user},
-- claudeBin = locally-resolved absolute path }. All optional; with none, the
-- output is exactly the original `cd <p> && claude [prompt]`. With ssh, the
-- whole thing is wrapped in `ssh -t <dest> '<inner>'` (remote harness) and
-- claudeBin is IGNORED -- the remote box resolves its own `claude`; a local
-- absolute path would be wrong there.
function M.spawnInner(project, prompt, opts)
  opts = opts or {}
  local isSsh = type(opts.ssh) == "table" and opts.ssh.host and tostring(opts.ssh.host) ~= ""
  local bin = isSsh and "claude" or claudeRef(opts.claudeBin)
  local inner = "cd " .. shquote(project or ".") .. " && " .. M.envPrefix(opts.env) .. bin
  for _, f in ipairs(opts.flags or {}) do inner = inner .. " " .. f end
  if prompt and #prompt > 0 then inner = inner .. " " .. shquote(prompt) end
  return M.sshWrap(inner, opts.ssh, opts.env)
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
    .. asquote(M.spawnInner(project, prompt, { env = opts.env, flags = opts.flags,
                                               ssh = opts.ssh, claudeBin = opts.claudeBin }))
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

-- Merge fields into a session's status JSON text (pure; the FX layer does the
-- read + atomic write). Needed after a successful set-mode: Shift+Tab fires no
-- hook, so the stored permission_mode stays stale -- the dropdown snaps back and
-- a re-pick would compute the cycle count from the WRONG base, landing past the
-- target mode. Returns the patched JSON text, or nil when the input doesn't
-- decode to an object. The session's next real hook write restores ground truth.
function M.patchedStatus(text, fields)
  local ok, data = pcall(function() return M.json.decode(text) end)
  if not ok or type(data) ~= "table" then return nil end
  for k, v in pairs(fields or {}) do data[k] = v end
  return M.json.encode(data)
end

-- Editor-aware spawn spec (F3-F5). Returns a STRUCTURED intent, not a string, that
-- the impure FX layer dispatches on -- so the editor->command mapping is testable.
--   kitty    -> { kind="kitty",    argv={...} }            run via hs.task
--   vscode   -> { kind="vscode",   app, project, openTerminalKey, postType }
--   cursor   -> same as vscode with app="Cursor"
--   else     -> { kind="terminal", applescript=... }        the reliable fallback
-- opts: { terminal, kittyBin, kittyRemote(bool), kittySocket, permissionMode,
--         effort, env, shell, ssh, claudeBin }. env (a providerEnv list) injects
--         provider env vars (incl. ANTHROPIC_MODEL); shell (default "zsh") is the
--         interactive login shell (-lic, sources ~/.zshrc) that expands `$VAR`
--         secrets in the kitty path; ssh = {host,user} runs `claude` on a remote
--         box while the terminal window stays local (Phase 2); claudeBin is the
--         locally-resolved absolute claude path (ignored for ssh -- the remote
--         box resolves its own).
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
      -- Run ssh directly (no local shell). sshd executes the remote command via
      -- `shell -c` (non-login, non-interactive), so the inner's `$VAR` secrets
      -- need an interactive login zsh on the remote (loginShellWrap sources the
      -- remote ~/.zshrc). The whole remote command is one argv element.
      argv[#argv + 1] = "ssh"
      if ssh.tty ~= false then argv[#argv + 1] = "-t" end
      argv[#argv + 1] = M.sshDest(ssh)
      argv[#argv + 1] = M.loginShellWrap(
        M.spawnInner(project, task, { env = env, flags = flags }), env)
    elseif hasEnv then
      -- Kitty argv has no shell to expand `$VAR`, so run the inner via an
      -- INTERACTIVE login shell: `-lic` sources ~/.zshrc, the README-documented
      -- home for the authTokenEnv secret. Plain `-lc` (login, non-interactive)
      -- skips ~/.zshrc, expanding the secret to "" -- every gateway call 401s.
      argv[#argv + 1] = opts.shell or "zsh"
      argv[#argv + 1] = "-lic"
      argv[#argv + 1] = M.spawnInner(project, task, { env = env, flags = flags,
                                                      claudeBin = opts.claudeBin })
    else
      -- No shell at all here, so a PATH lookup is kitty's (launchd env, which
      -- often lacks user bins) -- prefer the locally-resolved absolute path.
      argv[#argv + 1] = opts.claudeBin or "claude"
      for _, f in ipairs(flags) do argv[#argv + 1] = f end
      if task then argv[#argv + 1] = task end  -- one argv element: no shell, no quoting
    end
    return { kind = "kitty", argv = argv }
  elseif editor == "vscode" or editor == "cursor" then
    -- Open the window; "run claude" is best-effort keystrokes into a new integrated
    -- terminal (no supported API), consistent with the project's VS Code stance. For
    -- ssh, type the full `ssh -t <dest> '<inner>'` (the remote cd handles cwd).
    -- The integrated terminal's PATH/aliases often DON'T carry `claude` (proven:
    -- `zsh: command not found: claude`), so type the resolved absolute path.
    local post
    if isSsh then
      post = M.spawnInner(project, task, { env = env, flags = flags, ssh = ssh })
    else
      post = M.envPrefix(env) .. claudeRef(opts.claudeBin)
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
             { terminal = opts.terminal, env = env, flags = flags, ssh = ssh,
               claudeBin = opts.claudeBin }) }
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
--   key   -> @ [--to S] send-key   --match SEL <token...>
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
    -- payload.tokens batches several keys into ONE send-key process: ordering is
    -- guaranteed inside a single invocation, unlike N concurrent processes racing
    -- to the control socket (an early Return would pick the wrong answer option).
    local toks = payload.tokens or { payload.token }  -- ready kitty tokens (M.kittyKeyToken)
    local clean = {}
    for _, tok in ipairs(toks) do
      if tok and tok ~= "" then clean[#clean + 1] = tok end
    end
    if #clean == 0 then return nil end
    argv[#argv + 1] = "send-key"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
    for _, tok in ipairs(clean) do argv[#argv + 1] = tok end
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

-- Ordered bundle-id candidates for a session's editor kind. A 'cursor' session
-- must NEVER search VS Code's windows (and vice versa): with both editors
-- running, a fixed-order walk either injects keystrokes into the wrong app's
-- matching window or skips a perfectly matchable one. The status file carries
-- the editor kind (cc_detect_editor), so the right app is always knowable.
-- nil/unknown editor -> `fallback` (the legacy full walk).
M.EDITOR_BUNDLE_IDS = {
  vscode   = { "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders" },
  cursor   = { "com.todesktop.230313mzl4w4u92" },
  terminal = { "com.apple.Terminal" },
}

function M.editorBundleIds(editor, fallback)
  return M.EDITOR_BUNDLE_IDS[tostring(editor or "")] or fallback or {}
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

-- ---- Fuzzy folder search (roadmap #4b, fd-backed) ---------------------------
-- The modal scans the project roots ONCE per open (async hs.task, cached); each
-- keystroke filters the cached index here -- so the ranking is pure + tested and
-- no process is ever spawned per keystroke. fd is preferred (fast, honors
-- .gitignore so node_modules vanishes in repos); plain `find` is the fallback.

-- argv for an fd directory scan (binary first, hs.task shape).
function M.folderScanArgv(fdPath, roots, depth)
  local argv = { tostring(fdPath or "fd"), "--type", "d",
                 "--max-depth", tostring(tonumber(depth) or 4), "--absolute-path", "." }
  for _, r in ipairs(roots or {}) do argv[#argv + 1] = tostring(r) end
  return argv
end

-- argv for the `find` fallback: same shape of output (one absolute dir per
-- line). Skips dotdirs + node_modules explicitly (fd gets that for free).
function M.folderScanFallbackArgv(roots, depth)
  local argv = { "/usr/bin/find" }
  for _, r in ipairs(roots or {}) do argv[#argv + 1] = tostring(r) end
  argv[#argv + 1] = "-maxdepth"; argv[#argv + 1] = tostring(tonumber(depth) or 4)
  argv[#argv + 1] = "-type"; argv[#argv + 1] = "d"
  argv[#argv + 1] = "-not"; argv[#argv + 1] = "-path"; argv[#argv + 1] = "*/.*"
  argv[#argv + 1] = "-not"; argv[#argv + 1] = "-path"; argv[#argv + 1] = "*node_modules*"
  return argv
end

-- Scanner stdout -> deduped list of normalized absolute dirs, capped (a runaway
-- depth over a huge tree must not balloon the in-memory index). CRLF-tolerant.
function M.parseDirList(stdout, cap)
  cap = tonumber(cap) or 5000
  local out, seen = {}, {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    line = M.normDir(line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if #line > 0 and not seen[line] then
      seen[line] = true
      out[#out + 1] = line
      if #out >= cap then break end
    end
  end
  return out
end

-- Rank the cached index against a typed query. Tokenized AND-substring match
-- (every whitespace-separated token must appear somewhere in the lowercased
-- path; plain find -- `(`/`%` in a query can't inject a Lua pattern). Score:
-- basename starts with the LAST token (3) > basename contains it (2) > path
-- match only (1); ties break shorter-path-first then lexicographic, so the
-- result is total + deterministic. Empty/whitespace query -> {}.
function M.fuzzyFilter(query, paths, limit)
  limit = tonumber(limit) or 12
  local toks = {}
  for tok in tostring(query or ""):lower():gmatch("%S+") do toks[#toks + 1] = tok end
  if #toks == 0 then return {} end
  local lastTok = toks[#toks]
  local scored = {}
  for _, p in ipairs(paths or {}) do
    local lp = tostring(p):lower()
    local all = true
    for _, tok in ipairs(toks) do
      if not lp:find(tok, 1, true) then all = false; break end
    end
    if all then
      local base = lp:match("([^/]+)$") or lp
      local score
      if base:sub(1, #lastTok) == lastTok then score = 3
      elseif base:find(lastTok, 1, true) then score = 2
      else score = 1 end
      scored[#scored + 1] = { p = p, s = score }
    end
  end
  table.sort(scored, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    if #a.p ~= #b.p then return #a.p < #b.p end
    return a.p < b.p
  end)
  local out = {}
  for i = 1, math.min(#scored, limit) do out[i] = scored[i].p end
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

-- ---- Saved task templates (roadmap #5c) -------------------------------------
-- Operator data, stored OUTSIDE cc-config.json (a separate cc-templates.json,
-- like labels/recents) so the Settings overlay round-trip can never clobber it.
-- State shape: { templates = { { name = "...", text = "..." }, ... } }.
M.TEMPLATE_CAP = 50

local function ttpl(state)
  if type(state) == "table" and type(state.templates) == "table" then return state.templates end
  return {}
end

-- Safe copy of the templates list; tolerates nil/garbage state and drops
-- malformed entries (missing/blank name or text).
function M.templateList(state)
  local out = {}
  for _, t in ipairs(ttpl(state)) do
    if type(t) == "table" and type(t.name) == "string" and t.name ~= ""
       and type(t.text) == "string" and t.text ~= "" then
      out[#out + 1] = { name = t.name, text = t.text }
    end
  end
  return out
end

-- Save a template: trim both fields, reject blanks (returns state unchanged +
-- false), replace an existing same-name entry IN PLACE (rename-free update),
-- else prepend. Caps at `cap` (default TEMPLATE_CAP), dropping the oldest.
function M.templatePush(state, name, text, cap)
  cap = tonumber(cap) or M.TEMPLATE_CAP
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local list = M.templateList(state)
  if name == "" or text == "" then return { templates = list }, false end
  local out, replaced = {}, false
  for _, t in ipairs(list) do
    if t.name == name then
      out[#out + 1] = { name = name, text = text }; replaced = true
    else
      out[#out + 1] = t
    end
  end
  if not replaced then table.insert(out, 1, { name = name, text = text }) end
  while #out > cap do table.remove(out) end
  return { templates = out }, true
end

-- Delete by name (no-op copy on miss).
function M.templateRemove(state, name)
  local out = {}
  for _, t in ipairs(M.templateList(state)) do
    if t.name ~= name then out[#out + 1] = t end
  end
  return { templates = out }
end

-- Body text for a named template, or nil.
function M.templateGet(state, name)
  for _, t in ipairs(M.templateList(state)) do
    if t.name == name then return t.text end
  end
  return nil
end

-- ---- Spawn presets (roadmap #4a) --------------------------------------------
-- "Save this setup" for the New Session modal: a named {folder, editor,
-- permMode, provider} bundle, plus per-project last-used recall. Stored in a
-- separate cc-presets.json (operator data, same reasoning as templates).
-- State: { presets = { {name, folder, editor, permMode, provider}, ... },
--          lastByProject = { [normDir(folder)] = {editor, permMode, provider} } }.
M.PRESET_CAP = 20

local function plist(state)
  if type(state) == "table" and type(state.presets) == "table" then return state.presets end
  return {}
end
local function plast(state)
  if type(state) == "table" and type(state.lastByProject) == "table" then return state.lastByProject end
  return {}
end

-- Safe copy of the presets list; drops entries without a name or an absolute folder.
function M.presetList(state)
  local out = {}
  for _, p in ipairs(plist(state)) do
    if type(p) == "table" and type(p.name) == "string" and p.name ~= ""
       and type(p.folder) == "string" and p.folder:sub(1, 1) == "/" then
      out[#out + 1] = { name = p.name, folder = M.normDir(p.folder),
                        editor = p.editor, permMode = p.permMode, provider = p.provider }
    end
  end
  return out
end

-- Save a preset: validates name (nonblank after trim) + folder (absolute),
-- replaces same-name in place, else prepends; caps (oldest dropped). Returns
-- newState, saved(boolean). lastByProject rides through untouched.
function M.presetPush(state, preset, cap)
  cap = tonumber(cap) or M.PRESET_CAP
  local list = M.presetList(state)
  local last = {}
  for k, v in pairs(plast(state)) do last[k] = v end
  preset = type(preset) == "table" and preset or {}
  local name = tostring(preset.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local folder = M.normDir(tostring(preset.folder or ""))
  if name == "" or folder:sub(1, 1) ~= "/" then
    return { presets = list, lastByProject = last }, false
  end
  local entry = { name = name, folder = folder, editor = preset.editor,
                  permMode = preset.permMode, provider = preset.provider }
  local out, replaced = {}, false
  for _, p in ipairs(list) do
    if p.name == name then out[#out + 1] = entry; replaced = true
    else out[#out + 1] = p end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { presets = out, lastByProject = last }, true
end

-- Delete by name (no-op copy on miss).
function M.presetRemove(state, name)
  local out = {}
  for _, p in ipairs(M.presetList(state)) do
    if p.name ~= name then out[#out + 1] = p end
  end
  local last = {}
  for k, v in pairs(plast(state)) do last[k] = v end
  return { presets = out, lastByProject = last }
end

-- Record the spawn options last used for a project (per-project recall).
-- nil/relative folder or no options -> unchanged copy.
function M.presetMarkUsed(state, folder, spec)
  local out = { presets = M.presetList(state), lastByProject = {} }
  for k, v in pairs(plast(state)) do out.lastByProject[k] = v end
  folder = M.normDir(tostring(folder or ""))
  if folder:sub(1, 1) ~= "/" or type(spec) ~= "table" then return out end
  out.lastByProject[folder] = { editor = spec.editor, permMode = spec.permMode,
                                provider = spec.provider }
  return out
end

-- The last-used spawn options for a project, or nil.
function M.presetForProject(state, folder)
  return plast(state)[M.normDir(tostring(folder or ""))]
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

-- Full path for a new project under `parent`, or nil if the name is unsafe or
-- the parent isn't an ABSOLUTE path. A relative result is never right: mkdir
-- would resolve it against Hammerspoon's process cwd while the spawned shell's
-- `cd` resolves it against $HOME -- folder created one place, session elsewhere.
function M.newProjectPath(parent, name)
  local safe = M.safeFolderName(name)
  if not safe then return nil end
  if M.normDir(parent):sub(1, 1) ~= "/" then return nil end
  return M.pathJoin(parent, safe)
end

return M
