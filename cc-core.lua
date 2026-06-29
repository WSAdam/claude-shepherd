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

-- The known, trusted status set. parseStatusList clamps any value not in here to
-- "idle" so a hand-edited/rsync-mirrored/hostile status string can never reach the
-- panel's innerHTML sink raw (R2-17). Mirror of RANK's keys; exposed for tests.
M.STATUSES = { approval = true, error = true, done = true, working = true, idle = true }

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
      -- R3-01: coerce name to a string at the parse chokepoint, mirroring the
      -- updated/since/status hardening below. A non-string name (JSON number/bool,
      -- legal to hand-write or rsync-mirror) would otherwise tie on status with a
      -- string-named tile and throw `attempt to compare number with string` inside
      -- sortByStatus's `<` comparator, aborting the (un-pcall'd) refresh tick.
      data.name = tostring(data.name)
      data.projectKey = M.projectKey(data)
      -- Coerce time fields to numbers at the parse chokepoint. A status file with a
      -- non-numeric `updated`/`since` (boolean, "soon", a date string -- all legal to
      -- hand-write or rsync-mirror) would otherwise reach the raw arithmetic in stale/
      -- approvalStale/stepAutoRespawn/shouldPrune OUTSIDE the decode pcall and throw,
      -- permanently aborting the 1Hz refresh tick. tonumber yields nil for garbage,
      -- which every downstream `~= nil`/`and ...` guard already handles as "no timestamp".
      data.updated = tonumber(data.updated)
      data.since = tonumber(data.since)
      -- R2-17: clamp status to the known set at the parse chokepoint. status is later
      -- interpolated UNESCAPED into the tile innerHTML (class + label) on the LOCAL
      -- panel, so a hostile/compromised bridged host (parseMirrorList delegates here)
      -- could ship status='<img src=x onerror=...>' as stored XSS. Unknown -> "idle".
      if not M.STATUSES[data.status] then data.status = "idle" end
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
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return list
end

-- F8 (incremental render): a tile's rendered HTML is a pure function of its item
-- fields -- the live "age" (2s/5m) is derived from `since` at render time, not stored
-- on the item -- so a tile only needs re-rendering when its data actually changes.
-- tileSignature is a stable, key-SORTED canonical serialization (independent of the
-- JSON encoder's key order) and gridSignature folds the visible list, capturing both
-- content AND order. When the grid signature is unchanged between 1Hz ticks the webview
-- skips the whole innerHTML rebuild and only refreshes the churning age text. Selection
-- (selectedKey) is a UI-only concern handled separately, so it is intentionally not an
-- item field and never part of the signature. The webview keeps a byte-for-byte twin of
-- these (pinned in ui.test); they need only be internally stable, not cross-language.
function M.tileSignature(it)
  local t = type(it)
  if t == "table" then
    local keys = {}
    for k in pairs(it) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = tostring(k) .. ":" .. M.tileSignature(it[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "number" then
    return string.format("%.14g", it)
  end
  return tostring(it)
end

function M.gridSignature(list)
  if type(list) ~= "table" then return "" end
  local parts = {}
  for i = 1, #list do parts[i] = M.tileSignature(list[i]) end
  return table.concat(parts, "\n")
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

-- Delivery contract for window effects that report it: an EXPLICIT false means
-- "positively not delivered" (the no-window-match guard skipped the injection);
-- nil/anything-else is success -- fx fakes and effect paths that return nothing
-- must stay on the success path. Defining the strict == false check ONCE keeps
-- the two call sites (nudge paste, set-mode keys) from drifting apart.
local function delivered(fx, sent, msg)
  if sent == false then
    fx.log("[cc-core] " .. msg)
    return false
  end
  return true
end

-- R1-26: shared approve/deny decision path so the two can't drift (someone fixing
-- the remote rule for one and forgetting the other). Order is GATE-FIRST: a remote
-- (bridge) tile may still answer headlessly via the decision file while its gate is
-- waiting, but a non-waiting remote tile must fail closed -- never fall through to
-- actOnWindow, which would focus a LOCAL window matching the remote name and press a
-- key. Returns true when it acted (caller keeps the action) or nil to bail (no ledger).
local function gatedDecision(fx, item, tgt, verb, keyConst)
  if item.gate == "waiting" then
    fx.writeDecision(item.key, verb)  -- headless: write "allow"/"deny <nonce>"
    return true
  elseif item.remote then
    return nil                        -- remote + not waiting: never touch a local window
  else
    fx.actOnWindow(tgt, keyConst)     -- local (kitty): headless send-key
    return true
  end
end

-- Perform an action on a session via the injected fx (the only side effects).
-- Returns the action actually taken (handy for tests/logging).
function M.handleAction(fx, item, action, text)
  if not item then return nil end
  -- R2-07: fail closed for remote (bridge) tiles on EVERY window-effect action.
  -- R1-26 only hardened approve/deny, but the rule engine, Stream Deck button, and
  -- the jump/cycle hotkey all reach focus/stop/nudge/continue/etc WITHOUT pre-gating
  -- via core.remoteActionAllowed -- and those branches build a local `tgt` (dropping
  -- item.remote) that focuses/keystrokes a LOCAL window matching the remote name.
  -- Only the decision-file approve/deny (headless, self-gated on gate=="waiting"
  -- below) may proceed for a remote tile. This single chokepoint covers all callers,
  -- matching the R1-26 comment's claim and actionIsHeadless / remoteActionAllowed.
  if item.remote and action ~= "approve" and action ~= "deny" then return nil end
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
    -- R1-26: approve only via the decision file for a remote tile, and only while
    -- the gate is waiting -- never fall through to actOnWindow on a local window
    -- matching the remote name. gatedDecision enforces this for approve+deny alike
    -- (protects ALL callers: the single-approve hotkey + Stream Deck don't pre-gate
    -- via remoteActionAllowed the way the webview/bulk paths do).
    if not gatedDecision(fx, item, tgt, "allow", M.KEY_APPROVE) then return nil end
  elseif action == "deny" then
    if not gatedDecision(fx, item, tgt, "deny", M.KEY_DENY) then return nil end
  elseif action == "stop" then
    fx.actOnWindow(tgt, M.KEY_STOP)
  elseif action == "nudge" then
    -- Inject via the clipboard (one ⌘V), not char-by-char keystrokes: that's
    -- newline-safe (a multi-line list pastes as one block instead of each line
    -- submitting early) and more reliable in the VS Code extension.
    if not (text and #text > 0) then return nil end
    -- pasteIntoWindow reports delivery (see `delivered` above): a skipped paste
    -- returns nil so the caller never ledgers a nudge the session didn't receive.
    if not delivered(fx, fx.pasteIntoWindow(tgt, { text = text }),
        "nudge paste not delivered for " .. tostring(item.name) .. " -- not recorded") then
      return nil
    end
  elseif action == "continue" then
    -- Resume a session frozen on an API error (e.g. ECONNRESET): type the literal word
    -- "continue" + Enter, exactly as the user would, to restart the aborted turn. Gated
    -- on delivery (skip-on-no-match) so the caller can record an accurate outcome.
    if not delivered(fx, fx.typeIntoWindow(tgt, "continue"),
        "continue keystroke not delivered for " .. tostring(item.name)) then
      return nil
    end
  elseif action == "close" then
    -- Best-effort close the editor window, then drop its dashboard tile.
    fx.closeWindow(tgt)
    fx.removeStatus(item.key)
  elseif action == "effort" then
    -- Change effort live via the `/effort <level>` slash command. Gated on delivery
    -- (skip-on-no-window-match) so the caller never ledgers a change the session
    -- never received -- matching nudge/continue/set-mode.
    local cmd = M.effortCommand(text)
    if not cmd then return nil end
    if not delivered(fx, fx.typeIntoWindow(tgt, cmd),
        "effort keystroke not delivered for " .. tostring(item.name)) then
      return nil
    end
  elseif action == "model" then
    -- Switch model live via the `/model <id>` slash command. Works within the
    -- session's current backend (Claude tiers, or models the gateway serves); a
    -- different base URL still needs a fresh session (relaunch), not /model.
    -- Gated on delivery like effort/nudge/continue.
    local cmd = M.modelCommand(text)
    if not cmd then return nil end
    if not delivered(fx, fx.typeIntoWindow(tgt, cmd),
        "model keystroke not delivered for " .. tostring(item.name)) then
      return nil
    end
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
    -- A skipped send returns nil (see `delivered`) so the caller never persists
    -- a mode the session isn't in.
    if not delivered(fx, fx.sendKeys(tgt, keys),
        "set-mode keys not delivered for " .. tostring(item.name) .. " -- mode NOT re-based") then
      return nil
    end
  elseif action == "answer" then
    -- Select option #text (0-based) in a pending single-select AskUserQuestion:
    -- only a terminal TUI (kitty) responds to synthesized arrow/Enter; the VS Code
    -- extension's picker is mouse-only. A MULTI-select picker can't be driven by
    -- down*N+Enter (it needs toggle-then-confirm), so for it -- and for non-kitty --
    -- we JUMP so the user finishes it by hand.
    -- R2-16: only fire key-synthesis for a SINGLE single-select question, where
    -- the option index unambiguously drives the one picker. For a multi-QUESTION
    -- ask, answerAsk passes only the option index (not the question index), so
    -- down*N would drive question 1's picker by an option meant for question 2 --
    -- a confidently-wrong selection. Jump instead so the operator finishes by hand.
    if item.editor == "kitty" and not M.askIsMulti(item) and not M.askIsMultiQuestion(item) then
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

-- Does the pending AskUserQuestion contain MORE THAN ONE question? answerAsk only
-- sends the option index (not the question index), so down*N+Enter can't target a
-- specific question -- the key-synth path is restricted to single-question asks.
function M.askIsMultiQuestion(item)
  local ask = item and item.pending and item.pending.ask
  return type(ask) == "table" and #ask > 1
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

-- ---- DR6: per-session model auto-routing (heuristic, OFF by default) --------
-- Pick a model TIER for a task by difficulty, then map the tier to a model id, so a
-- cheap task can run on Haiku and a hard one on Opus. PURE + deterministic (no clock,
-- no network) -- the per-session opt-in, the /model switch, and the delivery gating
-- all live in the dashboard. Heuristic, most-specific first:
--   1) any "hard" keyword  -> hard
--   2) else any "cheap" keyword -> cheap
--   3) else by word count: <= cheapMax -> cheap; >= hardMin -> hard; else standard
-- Keywords beat length (a short "refactor the auth" is still hard). Returns
-- { tier, model, reason } or nil for an empty task. Everything is config-overridable
-- (automodel.models / .cheapMax / .hardMin / .cheapWords / .hardWords) -- but the
-- ENABLE is per-session only, never a fleet default.
M.AUTOMODEL_DEFAULTS = {
  models   = { cheap = "haiku", standard = "sonnet", hard = "opus" },
  cheapMax = 6,    -- <= this many words (and no keyword) -> cheap
  hardMin  = 40,   -- >= this many words (and no keyword) -> hard
  cheapWords = { "typo", "rename", "format", "lint", "bump", "comment", "docstring",
                 "readme", "changelog", "whitespace", "spelling", "gitignore", "tweak" },
  hardWords  = { "refactor", "architect", "design", "debug", "investigate", "root cause",
                 "security", "audit", "migrate", "rewrite", "optimize", "concurren",
                 "race condition", "deadlock", "algorithm", "regression", "complex" },
}
local function countWords(s)
  local n = 0
  for _ in tostring(s):gmatch("%S+") do n = n + 1 end
  return n
end
local function anyKeyword(haystack, words)
  if type(words) ~= "table" then return nil end
  for _, w in ipairs(words) do
    w = tostring(w):lower()
    if w ~= "" and haystack:find(w, 1, true) then return w end
  end
  return nil
end
function M.suggestModel(task, cfg)
  task = tostring(task or "")
  local trimmed = task:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return nil end
  local D = M.AUTOMODEL_DEFAULTS
  -- R1-33: merge the models override PER-TIER over the defaults, not wholesale. M.config
  -- returns the user's node as-is, so overriding only one tier (e.g. { cheap = "x" })
  -- would leave standard/hard nil and silently disable routing for them. Per-tier merge
  -- keeps the un-overridden tiers working.
  local mv = M.config(cfg, "automodel.models", nil)
  local models = {
    cheap    = (type(mv) == "table" and mv.cheap)    or D.models.cheap,
    standard = (type(mv) == "table" and mv.standard) or D.models.standard,
    hard     = (type(mv) == "table" and mv.hard)     or D.models.hard,
  }
  local cheapMax = tonumber(M.config(cfg, "automodel.cheapMax", D.cheapMax)) or D.cheapMax
  local hardMin  = tonumber(M.config(cfg, "automodel.hardMin",  D.hardMin))  or D.hardMin
  -- R2-28: enforce the low<high invariant. The tier test below checks `n <= cheapMax`
  -- FIRST, so an inverted/overlapping config (cheapMax >= hardMin, via typo/swap)
  -- would silently classify long tasks in [hardMin, cheapMax] as cheap and route them
  -- to Haiku. Reject the bad pair back to the safe defaults rather than honor it.
  if cheapMax >= hardMin then cheapMax, hardMin = D.cheapMax, D.hardMin end
  local cheapW   = M.config(cfg, "automodel.cheapWords", D.cheapWords) or D.cheapWords
  local hardW    = M.config(cfg, "automodel.hardWords",  D.hardWords)  or D.hardWords
  local lc = trimmed:lower()
  local tier, reason
  local hk = anyKeyword(lc, hardW)
  if hk then
    tier, reason = "hard", "keyword: " .. hk
  else
    local ck = anyKeyword(lc, cheapW)
    if ck then
      tier, reason = "cheap", "keyword: " .. ck
    else
      local n = countWords(trimmed)
      if n <= cheapMax then tier, reason = "cheap", "short task (" .. n .. " words)"
      elseif n >= hardMin then tier, reason = "hard", "long task (" .. n .. " words)"
      else tier, reason = "standard", "default (" .. n .. " words)" end
    end
  end
  local model = models[tier]
  if type(model) ~= "string" or model == "" then return nil end
  return { tier = tier, model = model, reason = reason }
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

-- Schedule a flat list of { delay, fn } beats through an injected scheduler
-- (`schedule(delaySeconds, fn) -> handle`; the dashboard passes its GC-safe
-- `after`). Delays are RELATIVE to the previous beat, so a keystroke ladder's
-- timings read as one tunable column instead of a nested-callback pyramid.
-- Every beat runs in its own pcall: one failed beat logs and the remaining
-- beats still fire (deliberately NOT one chain-wide pcall, which would abort
-- the rest of the ladder on a mid-beat throw). Returns the scheduler handles
-- (one per beat) so a caller can cancel a superseded ladder (hs.timer:stop()).
function M.runSequence(steps, schedule)
  local t, handles = 0, {}
  for i, s in ipairs(steps or {}) do
    t = t + (tonumber(s.delay) or 0)
    handles[#handles + 1] = schedule(t, function()
      local ok, err = pcall(s.fn)
      if not ok then print("[cc-seq] beat " .. i .. " failed: " .. tostring(err)) end
    end)
  end
  return handles
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

-- Filter + sort (newest first) a list of events. opts = { session, projectKey,
-- sinceTs, untilTs, types }. `types` may be a set ({decision=true}) or a list
-- ({"decision",...}); empty or nil means all. `session` matches session_id (the
-- reliable cross-writer key); `projectKey` matches the launch-folder identity
-- (stamped on every event by ledgerFor) so a project's whole lineage -- across
-- the session_ids a respawn/clear mints -- can be sliced in one call.
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
  -- multi-session filter (bulk history delete): opts.sessions = list of session_ids.
  -- ANDs with opts.session (a lone session_id) if both are somehow given.
  local sessionset
  if type(opts.sessions) == "table" and #opts.sessions > 0 then
    sessionset = {}
    for _, s in ipairs(opts.sessions) do sessionset[s] = true end
  end
  local out = {}
  for _, e in ipairs(events or {}) do
    local ok = true
    if opts.session and e.session_id ~= opts.session then ok = false end
    if ok and sessionset and not sessionset[e.session_id] then ok = false end
    if ok and opts.projectKey and e.projectKey ~= opts.projectKey then ok = false end
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
  if type(f.sessions) == "table" and #f.sessions > 0 then return true end  -- bulk history delete
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

-- ---- #7: session-history browser + bulk history management -----------------
-- Derive per-session HISTORY records from the ledger (NOT a parallel store) for the
-- history browser. Groups events by session_id, summarizes activity, and sorts.
-- opts.sort ("recent" (default, newest lastTs first) | "oldest" | "active" (most
-- prompts+toolRequests)). Pure. Each record:
--   { session_id, name, projectKey, firstTs, lastTs, lastType, events, prompts,
--     toolRequests, allow, deny }. Events without a session_id are ignored (no key).
function M.sessionHistory(events, opts)
  opts = opts or {}
  local by, order = {}, {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" and e.session_id and e.session_id ~= "" then
      local sid = e.session_id
      local r = by[sid]
      if not r then
        r = { session_id = sid, name = nil, projectKey = nil,
              firstTs = nil, lastTs = nil, lastType = nil,
              events = 0, prompts = 0, toolRequests = 0, allow = 0, deny = 0,
              _nameTs = nil, _pkTs = nil }
        by[sid] = r; order[#order + 1] = sid
      end
      -- R1-12: name/projectKey selection must be ORDER-INDEPENDENT. The only caller
      -- feeds events NEWEST-first (filterLedger sorts ts desc), so the old
      -- unconditional-overwrite picked the OLDEST name and a not-set guard kept the
      -- NEWEST projectKey -- both inverted from the documented intent. Track each
      -- field's source ts instead so the LATEST non-empty name and the EARLIEST
      -- projectKey (the stable pin) win regardless of iteration order.
      do
        local nts = tonumber(e.ts) or -math.huge
        if e.name and e.name ~= "" and (not r._nameTs or nts >= r._nameTs) then
          r.name = e.name; r._nameTs = nts
        end
        local pts = tonumber(e.ts) or math.huge
        if e.projectKey and (not r._pkTs or pts < r._pkTs) then
          r.projectKey = e.projectKey; r._pkTs = pts
        end
      end
      local ts = tonumber(e.ts)
      if ts then
        if not r.firstTs or ts < r.firstTs then r.firstTs = ts end
        if not r.lastTs or ts >= r.lastTs then r.lastTs = ts; r.lastType = e.type end
      end
      r.events = r.events + 1
      if e.type == "prompt" then r.prompts = r.prompts + 1
      elseif e.type == "tool_request" then r.toolRequests = r.toolRequests + 1
      elseif e.type == "decision" then
        if e.outcome == "allow" then r.allow = r.allow + 1
        elseif e.outcome == "deny" then r.deny = r.deny + 1 end
      end
    end
  end
  local list = {}
  for _, sid in ipairs(order) do
    local r = by[sid]
    r._nameTs = nil; r._pkTs = nil  -- internal ts trackers; don't leak into the record
    list[#list + 1] = r
  end
  local sort = opts.sort or "recent"
  if sort == "oldest" then
    table.sort(list, function(a, b) return (a.lastTs or 0) < (b.lastTs or 0) end)
  elseif sort == "active" then
    table.sort(list, function(a, b)
      local aa, bb = a.prompts + a.toolRequests, b.prompts + b.toolRequests
      if aa ~= bb then return aa > bb end
      return (a.lastTs or 0) > (b.lastTs or 0)
    end)
  else  -- recent (default)
    table.sort(list, function(a, b) return (a.lastTs or 0) > (b.lastTs or 0) end)
  end
  return list
end

-- Format a storage readout for the ⚙ Settings "Storage" section from raw {name, bytes}
-- entries the FX layer measured (ledger / queue / state-file dirs). Returns
-- { items = <entries sorted desc by bytes, each + human=fmtBytes(bytes)>, totalBytes,
--   totalHuman }. Skips non-table / nil-byte entries. Pure.
function M.localStorageReport(entries)
  local items, total = {}, 0
  for _, e in ipairs(entries or {}) do
    local b = type(e) == "table" and tonumber(e.bytes) or nil
    if b and b >= 0 then
      items[#items + 1] = { name = tostring(e.name or "?"), bytes = b, human = M.fmtBytes(b) }
      total = total + b
    end
  end
  table.sort(items, function(a, b) return a.bytes > b.bytes end)
  return { items = items, totalBytes = total, totalHuman = M.fmtBytes(total) }
end

-- Sum the byte sizes of directory entries for the #7 storage readout, SKIPPING the "." /
-- ".." self-entries (whose inode sizes would inflate the total) and any entry without a
-- numeric size. Pure.
function M.sumDirBytes(entries)
  local total = 0
  for _, e in ipairs(entries or {}) do
    if type(e) == "table" and e.name ~= "." and e.name ~= ".." then
      local s = tonumber(e.size)
      if s and s >= 0 then total = total + s end
    end
  end
  return total
end

-- Filter a list of filenames to Shepherd's own `cc-*.json` state files (the storage
-- readout's "State files" group). Pure.
function M.matchStateFiles(names)
  local out = {}
  for _, fn in ipairs(names or {}) do
    if type(fn) == "string" and fn:match("^cc%-.*%.json$") then out[#out + 1] = fn end
  end
  return out
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
  model_skipped = { "🤖", "model NOT switched (no window)" },
  effort_change = { "🎚", "effort" },
  effort_skipped = { "🎚", "effort NOT changed (no window)" },
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
  error         = { "❌", "errored" },
  loop          = { "⟳", "repeating the same action" },
  auto_respawn  = { "♻️", "auto-respawned" },
  auto_respawn_blocked = { "🚫", "death not respawnable" },
  auto_continue = { "▶️", "auto-continued" },
  rule          = { "📐", "rule fired" },
  schedule_fire = { "⏰", "scheduled routine fired" },
  drain_close   = { "⛔", "drained (finished turn, closed)" },
  queue_edit    = { "🧾", "edited the queue" },
  route_arm     = { "🔀", "project routing toggled" },
  queue_starved = { "⌛", "queued work waiting (no free session)" },
  remote_decision = { "📡", "remote decision sent" },
  rewind_open   = { "↶", "opened the rewind picker" },
  mode_skipped  = { "🎚", "mode NOT changed (no window)" },
}
-- R3-10: expose NARRATE so the dashboard can inject it as data (__NARRATE__) and the JS
-- evDesc twin derives BOTH its emoji and verb label from this single source -- otherwise
-- the hand-maintained EV_VERB/EV_EMOJI partial maps drift and ~21 types render the raw
-- e.type in Rows/Timeline while Review/Shift shows the rich verb.
M.NARRATE = NARRATE

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
  if t == "mode_change" or t == "model_change" or t == "effort_change"
     or t == "model_skipped" or t == "effort_skipped" or t == "mode_skipped" then
    detail = (e.from and (tostring(e.from) .. " → ") or "→ ") .. tostring(e.to or "?")
  elseif t == "tool_request" then
    detail = tostring(e.tool or "") .. (e.summary and (' "' .. tostring(e.summary) .. '"') or "")
  elseif t == "auto_continue" then
    -- mirror the JS evDesc twin (resumed after API error, attempt-aware)
    detail = "resumed after API error"
      .. (e.attempt and (" (attempt " .. tostring(e.attempt) .. ")") or "")
  -- R3-10: these types carry their detail in NON-default fields, so the generic
  -- e.prompt/.summary/.task/.text/.message fallback below rendered a bare verb. Match
  -- the JS evDesc twin's per-type detail so Review/Shift == Rows/Timeline.
  elseif t == "rule" then
    detail = e.rule or e.kind
  elseif t == "loop" then
    detail = (e.repeats ~= nil) and (tostring(e.repeats) .. "x") or nil
  elseif t == "queue_starved" then
    detail = (e.depth ~= nil) and (tostring(e.depth) .. " queued") or nil
  elseif t == "error" then
    detail = e.reason or e.message
  elseif t == "auto_respawn_blocked" then
    detail = e.reason or e.outcome
  else
    -- R2-14: include e.text (matches the JS evDesc twin) -- nudge/nudge_skipped
    -- ledger events carry their operator/broadcast content ONLY in .text, so
    -- omitting it rendered a bare "👉 nudge" and hid the content from the LLM review.
    detail = e.prompt or e.summary or e.task or e.text or e.message
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
M.NOTIFY_TYPES = { escalation = true, hung = true, auto_respawn = true, auto_continue = true }
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

-- ---- #6: host stats + fleet idle-since (read-only, off by default) ----------
-- Human-readable bytes (binary units): 1536 -> "1.5 KB", 2*1024^3 -> "2.0 GB".
-- nil / negative -> "—" (so a missing reading renders cleanly). Pure.
function M.fmtBytes(n)
  n = tonumber(n)
  if not n or n < 0 then return "—" end
  local units = { "B", "KB", "MB", "GB", "TB", "PB" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", math.floor(n), units[i]) end  -- whole bytes
  return string.format("%.1f %s", n, units[i])
end

-- Compact uptime: 350000s -> "4d 1h"; under a day falls back to fmtDuration (h/m/s). Pure.
function M.fmtUptime(seconds)
  local s = math.floor(tonumber(seconds) or 0)
  if s < 0 then s = 0 end
  local d = math.floor(s / 86400)
  if d >= 1 then
    local h = math.floor((s % 86400) / 3600)
    return (h == 0) and (d .. "d") or (d .. "d " .. h .. "h")
  end
  return M.fmtDuration(s)
end

-- Normalize the raw host readings the FX layer gathered into a render-ready view. EVERY raw
-- field may be nil (the reading was unavailable) -> degrade to nil, never crash. `pressure`
-- is the joined reason string the starvation note consumes. opts: pressure thresholds
-- (percent, default 90). Pure.
function M.hostHealth(raw, opts)
  raw = raw or {}; opts = opts or {}
  local cpuTh  = tonumber(opts.cpuThreshold)  or 90
  local memTh  = tonumber(opts.memThreshold)  or 90
  local diskTh = tonumber(opts.diskThreshold) or 90
  -- single definition of the 0-100 round+clamp (shared by the cpu passthrough + pct)
  local function clampPct(p) p = math.floor(p + 0.5); if p < 0 then return 0 elseif p > 100 then return 100 end; return p end
  local function pct(used, total)
    used, total = tonumber(used), tonumber(total)
    if not used or not total or total <= 0 then return nil end
    return clampPct((used / total) * 100)
  end
  local cpu = tonumber(raw.cpuPct); if cpu then cpu = clampPct(cpu) end
  local memPct  = pct(raw.memUsedBytes,  raw.memTotalBytes)
  local diskPct = pct(raw.diskUsedBytes, raw.diskTotalBytes)
  local reasons = {}
  if cpu     and cpu     >= cpuTh  then reasons[#reasons + 1] = "CPU "  .. cpu     .. "%" end
  if memPct  and memPct  >= memTh  then reasons[#reasons + 1] = "mem "  .. memPct  .. "%" end
  if diskPct and diskPct >= diskTh then reasons[#reasons + 1] = "disk " .. diskPct .. "%" end
  return {
    cpu = cpu,
    memPct   = memPct,
    memUsed  = raw.memUsedBytes  and M.fmtBytes(raw.memUsedBytes)  or nil,
    memTotal = raw.memTotalBytes and M.fmtBytes(raw.memTotalBytes) or nil,
    diskPct   = diskPct,
    diskUsed  = raw.diskUsedBytes  and M.fmtBytes(raw.diskUsedBytes)  or nil,
    diskTotal = raw.diskTotalBytes and M.fmtBytes(raw.diskTotalBytes) or nil,
    uptime = raw.uptimeSeconds and M.fmtUptime(raw.uptimeSeconds) or nil,
    load1  = tonumber(raw.loadAvg1),
    pressured = #reasons > 0,
    pressure  = (#reasons > 0) and table.concat(reasons, ", ") or nil,
  }
end

-- How long the whole fleet has been idle. Two non-obvious rules: working/approval/error
-- count as ACTIVE (so the fleet is not idle), and when fully idle `sinceTs` is the MOST
-- RECENT `since`/`updated` among the quiet tiles (when the last busy session went quiet).
-- An empty fleet is neither active nor idle. Pure (injected `now`).
function M.fleetIdleSince(tiles, now)
  now = tonumber(now) or 0
  local ACTIVE = { working = true, approval = true, error = true }
  local any, active, latest = false, false, nil
  for _, it in ipairs(tiles or {}) do
    if type(it) == "table" then
      any = true
      if ACTIVE[it.status] then
        active = true
      else
        local ts = tonumber(it.since) or tonumber(it.updated)
        if ts and (not latest or ts > latest) then latest = ts end
      end
    end
  end
  if not any then return { active = false, idle = false } end
  if active then return { active = true, idle = false } end
  return { active = false, idle = true, sinceTs = latest,
           seconds = latest and math.max(0, now - latest) or nil }
end

-- The off-by-default gate for the #6 insights host strip, expressed as a PURE decision so
-- the "off -> omit the strip" guarantee is behavior-testable (not just source-pinned).
-- Returns the keys to merge into the insights payload: {} when insights.hostStats is off,
-- else { host = host, fleetIdle = fleetIdle }. Pure.
function M.insightsHostAttach(cfg, host, fleetIdle)
  if not M.config(cfg, "insights.hostStats", false) then return {} end
  return { host = host, fleetIdle = fleetIdle }
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

-- ---- Session lineage (respawn / clear churn made legible) -------------------
-- Make the otherwise-invisible respawn/clear/continue CHURN for one project
-- legible: count the distinct sessions and the lifecycle events recorded for a
-- projectKey within a window. The caller passes sinceTs (e.g. local midnight) --
-- a pure fn has no clock. Pure read over ledger events already stamped with
-- projectKey by ledgerFor; deliberately NO new persisted "lineage chain" and NO
-- sessionRisk wiring (the synthesis kept this to the narrow read). Returns
-- nil-safe zeros so the caller can render "Nth session today (K auto-respawns)".
local LINEAGE_TYPES = { spawn = 0, auto_respawn = 0, respawn = 0, clear = 0,
                        continue = 0, auto_continue = 0, drain_close = 0 }
local function lineageRollup(l)
  local c = l.counts
  l.autoRespawns, l.manualRespawns = c.auto_respawn, c.respawn
  l.clears, l.continues = c.clear, c.continue + c.auto_continue
  l.spawns, l.drains = c.spawn, c.drain_close
  return l
end

-- One pass over the ledger building a map projectKey -> lineage table for EVERY
-- project in the window, so the dashboard can annotate all tiles in a single
-- ledger pass per tick (not one pass per session). Same shape as projectLineage.
function M.lineageByProject(events, sinceTs)
  sinceTs = tonumber(sinceTs) or 0
  local out, seenByKey = {}, {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" and e.projectKey and (tonumber(e.ts) or 0) >= sinceTs then
      local pk = e.projectKey
      local l = out[pk]
      if not l then
        local c = {}
        for k, v in pairs(LINEAGE_TYPES) do c[k] = v end
        l = { projectKey = pk, sessionCount = 0, counts = c }
        out[pk] = l; seenByKey[pk] = {}
      end
      local sid = e.session_id or e.key
      if sid and not seenByKey[pk][sid] then seenByKey[pk][sid] = true; l.sessionCount = l.sessionCount + 1 end
      if l.counts[e.type] ~= nil then l.counts[e.type] = l.counts[e.type] + 1 end
    end
  end
  for _, l in pairs(out) do lineageRollup(l) end
  return out
end

-- Lineage for ONE project (delegates to lineageByProject so the per-tick map and
-- the per-session read can never disagree). nil projectKey -> nil.
function M.projectLineage(events, projectKey, opts)
  if not projectKey then return nil end
  opts = opts or {}
  local m = M.lineageByProject(events, opts.sinceTs)
  if m[projectKey] then return m[projectKey] end
  local c = {}
  for k, v in pairs(LINEAGE_TYPES) do c[k] = v end
  return lineageRollup({ projectKey = projectKey, sessionCount = 0, counts = c })
end

-- One-line lineage summary for the detail panel, e.g.
-- "3rd session today · 2 auto-respawns · 1 clear". Returns nil when there's
-- nothing notable (a single session with no churn) so the panel omits the row.
function M.lineageSummary(lin)
  if not lin then return nil end
  local n = lin.sessionCount or 0
  local churn = (lin.autoRespawns or 0) + (lin.manualRespawns or 0)
             + (lin.clears or 0) + (lin.continues or 0)
  if n <= 1 and churn == 0 then return nil end
  local function ord(k)
    local m100 = k % 100
    if m100 >= 11 and m100 <= 13 then return k .. "th" end
    local suf = ({ "st", "nd", "rd" })[k % 10] or "th"
    return k .. suf
  end
  local parts = {}
  if n >= 1 then parts[#parts + 1] = ord(n) .. " session today" end
  local function add(num, one, many)
    if num and num > 0 then parts[#parts + 1] = num .. " " .. (num == 1 and one or many) end
  end
  add(lin.autoRespawns,   "auto-respawn", "auto-respawns")
  add(lin.manualRespawns, "respawn",      "respawns")
  add(lin.clears,         "clear",        "clears")
  add(lin.continues,      "continue",     "continues")
  return table.concat(parts, " · ")
end

-- ---- Fleet shift report (the "what did the fleet do while I was away" read) --
-- Operations shift report for the audit overlay's 📋 Shift tab: what the fleet
-- DID over a window. Pure aggregation -- reuses fleetStats for decisions /
-- provenance / blocked-time, then a second pass tallies lifecycle + auto-action
-- + problem events grouped by project. Reports OPERATIONS ONLY: there is NO
-- "what shipped" changelog, by design -- a prompt is an instruction, not an
-- outcome, and Shepherd has no git/CI/diff ground truth, so the honest signal
-- for error-recovery is the continue/auto_continue count, not a claimed outcome.
-- opts = { sinceTs, untilTs, topN }. `empty` flags a window with no events so the
-- UI can show the enable-the-ledger / nothing-happened state.
local STANDUP_LIFE   = { spawn = true, auto_respawn = true, respawn = true,
                         clear = true, continue = true, auto_continue = true,
                         drain_close = true }
local STANDUP_PROBLEM = { escalation = true, hung = true, queue_starved = true }
function M.fleetStandup(events, opts)
  opts = opts or {}
  local slice = M.filterLedger(events, { sinceTs = opts.sinceTs, untilTs = opts.untilTs })
  local stats = M.fleetStats(slice, { topN = opts.topN or 8 })
  local life = { spawn = 0, auto_respawn = 0, respawn = 0, clear = 0,
                 continue = 0, auto_continue = 0, drain_close = 0 }
  local problems = { escalation = 0, hung = 0, queue_starved = 0 }
  local routed = 0
  local tasksDone, taskSecs = 0, 0   -- L4 per-task timing rollup (task_done events)
  local byKey = {}   -- projectKey -> rollup
  local function proj(e)
    local k = e.projectKey or e.cwd or e.name or "?"
    local p = byKey[k]
    if not p then
      p = { projectKey = k, name = e.name or k, prompts = 0, allow = 0, deny = 0,
            autoRespawns = 0, escalations = 0, hangs = 0 }
      byKey[k] = p
    end
    if e.name and (not p.name or p.name == k) then p.name = e.name end
    return p
  end
  for _, e in ipairs(slice) do
    local t = e.type
    if STANDUP_LIFE[t] then life[t] = (life[t] or 0) + 1 end
    if STANDUP_PROBLEM[t] then problems[t] = (problems[t] or 0) + 1 end
    -- R2-13: routed feeds are DELIVERED 'task_feed' events with by='router' (written
    -- by the dispatcher), NOT 'decision' events -- the gate never sets by='router'.
    -- Count only delivered feeds (task_feed), not task_feed_skipped (no delivery).
    if t == "task_feed" and e.by == "router" then routed = routed + 1 end
    if t == "prompt" then local p = proj(e); p.prompts = p.prompts + 1
    elseif t == "auto_respawn" then local p = proj(e); p.autoRespawns = p.autoRespawns + 1
    elseif t == "escalation" then local p = proj(e); p.escalations = p.escalations + 1
    elseif t == "hung" then local p = proj(e); p.hangs = p.hangs + 1
    elseif t == "task_done" then
      tasksDone = tasksDone + 1; taskSecs = taskSecs + (tonumber(e.durationS) or 0)
    elseif t == "decision" then
      local p = proj(e)
      if e.outcome == "deny" then p.deny = p.deny + 1
      elseif e.outcome == "allow" then p.allow = p.allow + 1 end
    end
  end
  local byProject = {}
  for _, p in pairs(byKey) do byProject[#byProject + 1] = p end
  table.sort(byProject, function(a, b)
    local aw = a.prompts + a.allow + a.deny + a.autoRespawns + a.escalations
    local bw = b.prompts + b.allow + b.deny + b.autoRespawns + b.escalations
    if aw ~= bw then return aw > bw end
    return (a.name or "") < (b.name or "")
  end)
  return {
    sinceTs = opts.sinceTs, untilTs = opts.untilTs,
    empty = (#slice == 0),
    totals = stats.totals,            -- events, sessions, prompts, toolRequests, spawns, decisions
    decisions = stats.decisions,      -- allow / deny / fallback / total
    provenance = stats.provenance,    -- who decided: by -> count
    blockedSeconds = stats.approvalBlockedSeconds,
    lifecycle = life,                 -- spawn / respawn / clear / continue counts
    autoActions = { auto_respawn = life.auto_respawn, auto_continue = life.auto_continue,
                    drain_close = life.drain_close, routed = routed },
    problems = problems,              -- escalation / hung / queue_starved
    continues = life.continue + life.auto_continue,  -- error-recovery signal (honest stand-in for "errors")
    tasks = { done = tasksDone, totalSeconds = taskSecs,   -- L4 per-task timing rollup
              avgSeconds = tasksDone > 0 and math.floor(taskSecs / tasksDone + 0.5) or 0 },
    byProject = byProject,
    mostActive = stats.mostActive,
  }
end

-- Render a fleetStandup report as a readable plain-text/markdown block -- used
-- BOTH for the 📋 Shift tab body (shown in a <pre>, mirroring the timeline view)
-- and the Copy button, so the on-screen text and the copied text can't diverge.
-- Pure; opts.windowLabel is the human window ("since Shepherd opened" / "8h").
function M.standupMarkdown(report, opts)
  opts = opts or {}
  local label = opts.windowLabel or "the selected window"
  local L = { "Fleet shift report — " .. label }
  L[#L + 1] = string.rep("─", math.min(#L[1], 48))
  if not report or report.empty then
    L[#L + 1] = "No fleet activity recorded in this window."
    L[#L + 1] = "(The audit ledger must be enabled to record activity — it's off by default.)"
    return table.concat(L, "\n")
  end
  local t, d, a, p = report.totals, report.decisions, report.autoActions, report.problems
  L[#L + 1] = string.format("Sessions active: %d   ·   Prompts: %d   ·   Tool requests: %d",
    t.sessions or 0, t.prompts or 0, t.toolRequests or 0)
  L[#L + 1] = string.format("Spawns: %d   ·   Auto-respawns: %d   ·   Auto-continues: %d   ·   Drained: %d   ·   Routed feeds: %d",
    t.spawns or 0, a.auto_respawn or 0, a.auto_continue or 0, a.drain_close or 0, a.routed or 0)
  L[#L + 1] = string.format("Approvals: %d allow / %d deny (of %d)   ·   You were the bottleneck for %s",
    d.allow or 0, d.deny or 0, d.total or 0, M.fmtDuration(report.blockedSeconds or 0))
  L[#L + 1] = string.format("Escalations: %d   ·   Stalls: %d   ·   Error recoveries: %d",
    p.escalation or 0, p.hung or 0, report.continues or 0)
  if report.tasks and (report.tasks.done or 0) > 0 then
    L[#L + 1] = string.format("Routed tasks completed: %d   ·   avg %s   ·   total %s",
      report.tasks.done, M.fmtDuration(report.tasks.avgSeconds or 0), M.fmtDuration(report.tasks.totalSeconds or 0))
  end
  -- who made the gate decisions (human vs automation), most-common first
  local prov = {}
  for by, n in pairs(report.provenance or {}) do prov[#prov + 1] = { by = by, n = n } end
  table.sort(prov, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.by < y.by end)
  if #prov > 0 then
    local parts = {}
    for _, e in ipairs(prov) do parts[#parts + 1] = e.by .. " " .. e.n end
    L[#L + 1] = "Decided by: " .. table.concat(parts, ", ")
  end
  if report.byProject and #report.byProject > 0 then
    L[#L + 1] = ""
    L[#L + 1] = "By project:"
    for _, pr in ipairs(report.byProject) do
      local bits = {}
      if (pr.prompts or 0) > 0 then bits[#bits + 1] = pr.prompts .. " prompt" .. ((pr.prompts == 1) and "" or "s") end
      if (pr.allow or 0) > 0 then bits[#bits + 1] = pr.allow .. " allow" end
      if (pr.deny or 0) > 0 then bits[#bits + 1] = pr.deny .. " deny" end
      if (pr.autoRespawns or 0) > 0 then bits[#bits + 1] = pr.autoRespawns .. " auto-respawn" .. ((pr.autoRespawns == 1) and "" or "s") end
      if (pr.escalations or 0) > 0 then bits[#bits + 1] = pr.escalations .. " escalation" .. ((pr.escalations == 1) and "" or "s") end
      if (pr.hangs or 0) > 0 then bits[#bits + 1] = pr.hangs .. " stall" .. ((pr.hangs == 1) and "" or "s") end
      L[#L + 1] = "  • " .. (pr.name or pr.projectKey or "?")
        .. (#bits > 0 and ("  —  " .. table.concat(bits, " · ")) or "  —  (no recorded activity)")
    end
  end
  return table.concat(L, "\n")
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

-- Plan an INCREMENTAL ledger re-parse so refresh() never re-decodes the whole
-- 30-day corpus every tick (the main-thread stall that froze typing). Pure: the
-- caller does the I/O. `oldByFile` is the prior per-file cache { [name] = { sig,
-- events } }; `files` is the sorted list of files now on disk, each { name, sig }
-- where sig is a "size:mtime" fingerprint. Returns { changed, reparse, present }:
--   reparse[name] = true   -> file is new or its sig moved (append / redact / purge
--                             / shrink / rotation), so the caller must re-read it
--   present[name] = true   -> file still exists (drop cache entries not present)
--   changed                -> any file was added/modified OR a cached file vanished,
--                             i.e. the assembled snapshot (and its consumers) must
--                             recompute; false means reuse the prior slice verbatim.
-- A real append always grows size, and an atomic redact/purge rewrite bumps mtime,
-- so the size:mtime sig catches every mutation without byte-offset bookkeeping.
function M.ledgerCachePlan(oldByFile, files)
  oldByFile = oldByFile or {}
  local reparse, present = {}, {}
  local changed = false
  for _, f in ipairs(files or {}) do
    present[f.name] = true
    local old = oldByFile[f.name]
    if not old or old.sig ~= f.sig then
      reparse[f.name] = true
      changed = true
    end
  end
  for name in pairs(oldByFile) do
    if not present[name] then changed = true end  -- a daily file was expired/purged
  end
  return { changed = changed, reparse = reparse, present = present }
end

-- Assemble the ledger snapshot from the per-file cache: concat each file's parsed
-- events in chronological FILE order (filesInOrder is name-sorted), then globally
-- filter (newest-first) + cap. Pure counterpart to ledgerCachePlan's decision --
-- the impure ledgerSnapshot reads/parses the changed files, this stitches them.
-- Only files in filesInOrder contribute, so a vanished (expired/purged) file is
-- dropped automatically. opts.limit defaults to the capLedgerSlice newest-2000,
-- matching the old FX.readLedger({}) slice every ledger consumer expects.
function M.assembleLedger(filesInOrder, byFile, opts)
  opts = opts or {}
  byFile = byFile or {}
  local all = {}
  for _, f in ipairs(filesInOrder or {}) do
    local entry = f and f.name and byFile[f.name]
    if entry and type(entry.events) == "table" then
      for _, e in ipairs(entry.events) do all[#all + 1] = e end
    end
  end
  return (M.capLedgerSlice(M.filterLedger(all, {}), opts.limit))
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
      -- R3-11: a policy-bundle auto-deny carries by='bundle:<name>' (cc-approve.sh),
      -- not the literal 'autoDeny', so the "safety net fired" signal was permanently 0
      -- for bundle sessions. Count it too (gated on outcome=='deny' so a bundle auto-
      -- ALLOW isn't miscounted as a safety-net trip).
      if e.by == "autoDeny"
         or (type(e.by) == "string" and e.by:sub(1, 7) == "bundle:" and e.outcome == "deny") then
        autoDenyHits = autoDenyHits + 1
      end
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

-- Map the sorted session list onto a deck of `count` keys (row-major), SKIPPING any key
-- index in `reserved` (a {[idx]=true} set used for the global action keys). Returns
-- items[1..count] (nil for empty/reserved keys) and how many sessions didn't fit the
-- non-reserved slots. `reserved` is optional -- omitted = the original plain fill.
function M.deckLayout(count, list, reserved)
  reserved = reserved or {}
  list = list or {}
  local items = {}
  local li, slots = 1, 0
  for i = 1, count do
    if reserved[i] then
      items[i] = nil
    else
      items[i] = list[li]; li = li + 1; slots = slots + 1
    end
  end
  local overflow = #list - slots
  if overflow < 0 then overflow = 0 end
  return { items = items, overflow = overflow }
end

-- The key indices for the global action row: the bottom row's leftmost `n` keys on a
-- cols x rows deck (1-based, row-major). e.g. an 8x4 Stream Deck XL -> {25,26,27,28}.
-- Returns {} if the geometry can't host them (a tiny deck just shows sessions).
function M.deckActionKeys(cols, rows, n)
  cols = tonumber(cols) or 0; rows = tonumber(rows) or 0; n = tonumber(n) or 0
  if cols < 1 or rows < 1 or n < 1 then return {} end
  local base = (rows - 1) * cols  -- 0-based index of the last row's first key
  local take = math.min(n, cols)
  local out = {}
  for i = 1, take do out[i] = base + i end
  return out
end

-- Compute every global action-key reservation for a cols x rows deck (count = cols*rows). The
-- `actionOrder` names fill the bottom row's leftmost keys (via deckActionKeys); the `tail` names
-- are placed on the bottom-RIGHT, walking leftward from the last key (count, count-1, ...), each
-- ONLY if its slot is still free -- so on a deck too narrow to spare them (the left row already
-- reaches the right edge) they're silently skipped rather than overwriting a row action. Decks
-- smaller than 4x2 host no action keys at all (sessions get every key). Returns { reserved = a
-- {[idx]=true} set, actionByKey = {[idx]=name}, actionCount = N }. Pure: the dashboard feeds deck
-- geometry in and copies the result onto `sd`, so both the happy path and the skip branch are
-- pinned by value tests instead of a source grep.
function M.deckReservations(cols, rows, count, actionOrder, tail)
  local reserved, actionByKey, n = {}, {}, 0
  actionOrder = actionOrder or {}
  tail = tail or {}
  count = tonumber(count) or 0
  if (tonumber(cols) or 0) < 4 or (tonumber(rows) or 0) < 2 then
    return { reserved = reserved, actionByKey = actionByKey, actionCount = 0 }
  end
  for i, kidx in ipairs(M.deckActionKeys(cols, rows, #actionOrder)) do
    reserved[kidx] = true; actionByKey[kidx] = actionOrder[i]; n = n + 1
  end
  for i, name in ipairs(tail) do
    local kidx = count - (i - 1)  -- count, count-1, ... walking left from the bottom-right corner
    if kidx >= 1 and not reserved[kidx] then
      reserved[kidx] = true; actionByKey[kidx] = name; n = n + 1
    end
  end
  return { reserved = reserved, actionByKey = actionByKey, actionCount = n }
end

-- Hotkey helpers (used in Phase 2).
function M.nextApproval(list)
  for _, it in ipairs(list or {}) do
    if it.status == "approval" then return it end
  end
  return nil
end

function M.frontSession(list) return (list or {})[1] end

-- The single session that most needs the operator RIGHT NOW, in hard-attention
-- order: a pending approval first, then a session frozen on an API error (the
-- magenta "Error" state -- you must resume it), then one the watchdog flagged
-- hung. Returns nil when nothing is wedged, so the jump hotkey can fall back to
-- frontSession. Reads only fields already on the parsed item (status + the
-- it.hung flag the refresh sets), so it stays pure/testable -- this generalizes
-- nextApproval, which the ⌘⌥J "jump to who needs you" key used to call. The
-- tiers are deliberately HARD signals only: context-band and stale-approval are
-- softer and would make the global key teleport to sessions that don't yet need
-- a human. The list is already RANK-sorted (approval=0, error=1), so the first
-- match in each pass is the front-most of its kind.
function M.nextAttention(list)
  for _, it in ipairs(list or {}) do
    if it.status == "approval" then return it end
  end
  for _, it in ipairs(list or {}) do
    if it.status == "error" then return it end
  end
  for _, it in ipairs(list or {}) do
    if it.hung then return it end
  end
  return nil
end

-- Hotkey legend (the ⌨ popup) ------------------------------------------------
-- Mac modifier glyphs and their canonical render order (⌃⌥⇧⌘), so a combo reads
-- the way the OS prints it regardless of how the binding listed its mods.
local MOD_SYM   = { ctrl = "⌃", control = "⌃", alt = "⌥", option = "⌥", shift = "⇧", cmd = "⌘", command = "⌘" }
local MOD_ORDER = { ctrl = 1, control = 1, alt = 2, option = 2, shift = 3, cmd = 4, command = 4 }

-- Format a {mods, key} binding as a display combo like "⌘⌥J". Pure; used to build
-- the legend from the dashboard's real HOTKEY_* constants so the displayed combo
-- can never drift from the actual binding.
function M.fmtHotkey(mods, key)
  local ms = {}
  for _, m in ipairs(mods or {}) do ms[#ms + 1] = m end
  table.sort(ms, function(a, b) return (MOD_ORDER[a] or 9) < (MOD_ORDER[b] or 9) end)
  local out = ""
  for _, m in ipairs(ms) do out = out .. (MOD_SYM[m] or ("?" .. tostring(m))) end
  local k = tostring(key or "")
  -- single letters/digits render upper-case; named keys (space, tab) title-cased
  if #k == 1 then k = k:upper() else k = k:sub(1, 1):upper() .. k:sub(2) end
  return out .. k
end

-- Build the legend rows for the ⌨ popup. `globals` is a list of
-- { mods, key, desc } passed straight from the dashboard's HOTKEY_* consts (so
-- the legend is sourced from the real bindings, not a hand-kept copy);
-- `panelKeys` is the static in-panel list of { combo, desc } (Enter to send,
-- Esc to close, etc.). Returns sections [{ title, rows = {{ combo, desc }} }],
-- skipping any empty section.
function M.hotkeyLegend(globals, panelKeys)
  local g = {}
  for _, b in ipairs(globals or {}) do
    g[#g + 1] = { combo = M.fmtHotkey(b.mods, b.key), desc = b.desc or "" }
  end
  local out = {}
  if #g > 0 then out[#out + 1] = { title = "Global — work from any app", rows = g } end
  if panelKeys and #panelKeys > 0 then
    out[#out + 1] = { title = "In the panel", rows = panelKeys }
  end
  return out
end

-- The five configurable global hotkeys, in the dashboard's HOTKEY_* shape ([1]=mods, [2]=key).
-- These are the ⌘⌥ defaults; cc-config.json's `hotkeys` block overrides any of them.
local HOTKEY_DEFAULTS = {
  approveFront = { { "cmd", "alt" }, "a" },
  jumpNeedy    = { { "cmd", "alt" }, "j" },
  cycle        = { { "cmd", "alt" }, "n" },
  spawn        = { { "cmd", "alt" }, "s" },
  toggle       = { { "cmd", "alt" }, "b" },
}
local HOTKEY_ACTIONS  = { "approveFront", "jumpNeedy", "cycle", "spawn", "toggle" }
-- Modifier names hs.hotkey.bind accepts (both spellings). Anything else is rejected so a
-- typo can't half-bind a key or throw at bind time -- the action reverts to its default.
local HOTKEY_MODS_OK  = { cmd = true, command = true, ctrl = true, control = true,
                          alt = true, option = true, shift = true, fn = true }

local function normalizeMods(mods)
  if type(mods) ~= "table" then return nil end
  local out, seen = {}, {}
  for _, m in ipairs(mods) do
    if type(m) ~= "string" then return nil end
    local lm = m:lower()
    if not HOTKEY_MODS_OK[lm] then return nil end
    if not seen[lm] then seen[lm] = true; out[#out + 1] = lm end
  end
  return out  -- may be empty (only valid for F-keys; see resolveOneHotkey)
end

-- Resolve one hotkey entry (a cc-config `{ mods = {...}, key = "x" }` object) against its
-- default {mods, key}. ANY rejection returns a fresh COPY of the default (never the shared
-- table) so a malformed config can't crash hs.hotkey.bind or leave a key half-bound:
--   * key must be a non-empty string
--   * mods, if present, must all be known modifier names (else revert)
--   * empty mods are allowed ONLY for an F-key (f1..f20) -- Hammerspoon can't bind a bare
--     letter globally, so a no-modifier letter reverts to the default rather than no-op'ing.
function M.resolveOneHotkey(entry, default)
  local function dflt()
    local m = {}
    for _, x in ipairs(default[1]) do m[#m + 1] = x end
    return { m, default[2] }
  end
  if type(entry) ~= "table" then return dflt() end
  local key = entry.key
  if type(key) ~= "string" or key == "" then return dflt() end
  local mods
  if entry.mods == nil then
    mods = {}
  else
    mods = normalizeMods(entry.mods)
    if not mods then return dflt() end
  end
  -- A bare (no-modifier) key is legal ONLY for a real function key F1..F20. Match the digits and
  -- range-check them: `^f%d+$` alone would accept f0 / f21..f99 (keys macOS has no scancode for),
  -- which then bind to nothing and silently leave the action dead instead of reverting to default.
  local fn = key:lower():match("^f(%d+)$")
  local isFkey = fn ~= nil and tonumber(fn) >= 1 and tonumber(fn) <= 20
  if #mods == 0 and not isFkey then return dflt() end
  return { mods, key }
end

-- Resolve all five global hotkeys from cc-config.json's `hotkeys` block, each falling back
-- to its ⌘⌥ default. Pure; the dashboard feeds the result to BOTH hs.hotkey.bind and the
-- ⌨ legend, so the displayed combos can't drift from what's actually bound.
function M.resolveHotkeys(cfg)
  local hk = M.config(cfg, "hotkeys", nil)
  if type(hk) ~= "table" then hk = {} end
  local out = {}
  for _, name in ipairs(HOTKEY_ACTIONS) do
    out[name] = M.resolveOneHotkey(hk[name], HOTKEY_DEFAULTS[name])
  end
  return out
end

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

-- DR1 drill-in: up to `n` most-recent assistant text snippets from a transcript tail,
-- chronological (oldest->newest), each whitespace-collapsed + truncated. Used when you
-- click a subagent row to "see what it's working on". Pure (reuses the json decoder).
function M.transcriptRecent(text, n, maxLen)
  n = tonumber(n) or 12; maxLen = tonumber(maxLen) or 200
  if not text or #text == 0 then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local newest = {}
  for i = #lines, 1, -1 do
    if #newest >= n then break end
    local line = lines[i]
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "assistant"
         and obj.message and type(obj.message.content) == "table" then
        for _, c in ipairs(obj.message.content) do
          if #newest < n and type(c) == "table" and c.type == "text" and c.text and #c.text > 0 then
            local t = c.text:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
            if #t > 0 then
              if #t > maxLen then t = t:sub(1, maxLen - 1) .. "\226\128\166" end
              newest[#newest + 1] = t
            end
          end
        end
      end
    end
  end
  local out = {}                       -- reverse newest-first -> chronological
  for i = #newest, 1, -1 do out[#out + 1] = newest[i] end
  return out
end

-- F4 (transcript peek): the last N human-readable turns of a session's transcript, as
-- { role = "user"|"assistant", ts, text } rows in chronological order (oldest first). Pulls
-- assistant TEXT blocks and genuine human prompts (via userHasHumanText -- skips IDE
-- file-open injections, tool-result-only user lines, and meta/snapshot lines), so the
-- panel shows the actual conversation, not tool plumbing. Pure: the dashboard reads a
-- bounded transcript tail and hands it here; the panel renders + searches client-side.
function M.transcriptPeek(text, opts)
  opts = (type(opts) == "table") and opts or {}
  local n = tonumber(opts.n) or 40
  local maxLen = tonumber(opts.maxLen) or 600
  if type(text) ~= "string" or #text == 0 then return {} end
  local function clean(s)
    s = s:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
    if #s > maxLen then s = s:sub(1, maxLen - 1) .. "\226\128\166" end
    return s
  end
  local function textOf(content)
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return "" end
    local buf = {}
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "text" and type(part.text) == "string" and #part.text > 0 then
        buf[#buf + 1] = part.text
      end
    end
    return table.concat(buf, " ")
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local rows = {}                      -- collected newest-first, reversed at the end
  for i = #lines, 1, -1 do
    if #rows >= n then break end
    local line = lines[i]
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" then
        local role, raw
        if obj.type == "assistant" and obj.message then
          role, raw = "assistant", textOf(obj.message.content)
        elseif obj.type == "user" and M.userHasHumanText(obj) then
          role, raw = "user", textOf(obj.message and obj.message.content)
        end
        if role then
          local t = clean(raw or "")
          if #t > 0 then rows[#rows + 1] = { role = role, ts = obj.timestamp, text = t } end
        end
      end
    end
  end
  local out = {}
  for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
  return out
end

-- Detect a session frozen on an API error. When a turn aborts on an API error (e.g.
-- ECONNRESET) WITHOUT firing a Stop hook, the session sits in "working" forever; Claude
-- Code records the failure as a { type = "system", subtype = "api_error" } transcript
-- line. Scanning the tail backwards, return the error's display text IF that error is the
-- LATEST significant event -- a later `assistant`/`user` line means it recovered (or the
-- user already typed continue), so return nil. Meta lines (snapshots, stop_hook_summary)
-- are skipped. Pure; the caller (refresh) reads the tail and overrides the status.
-- R3-04: is this transcript `user` line a genuine human-typed prompt (vs an IDE
-- file-open injection, a meta line, or a tool-result-only user line)? A real prompt
-- carries non-empty text/string content and is not flagged isMeta. Pure helper.
function M.userHasHumanText(obj)
  if type(obj) ~= "table" then return false end
  if obj.isMeta then return false end
  local m = obj.message
  if type(m) ~= "table" then return false end
  local c = m.content
  if type(c) == "string" then
    return c:gsub("%s+", "") ~= ""
  end
  if type(c) == "table" then
    for _, part in ipairs(c) do
      if type(part) == "table" then
        -- a tool_result block is not a human prompt; only text blocks count
        if part.type == "text" and type(part.text) == "string"
           and part.text:gsub("%s+", "") ~= "" then
          return true
        end
      end
    end
  end
  return false
end

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
        if t == "assistant" then
          return nil  -- a model turn after the error -> recovered / no longer stuck
        elseif t == "user" then
          -- R3-04: symmetric with transcriptResumed -- the IDE injects spurious `user`
          -- lines (file-open context, tool-results, meta) that are NOT real activity,
          -- so a lone such line during a freeze must NOT read as recovery. Treat a user
          -- line as recovery ONLY when it is a genuine human-typed prompt: non-meta,
          -- carrying actual text content. Otherwise keep scanning past it.
          if M.userHasHumanText(obj) then
            return nil
          end
          -- else: IDE/meta/tool-result injection -> not recovery, keep scanning back
        elseif t == "system" and obj.subtype == "api_error" then
          local e = obj.error
          local msg = (type(e) == "table" and (e.formatted or e.message)) or "API error"
          return { message = tostring(msg), reason = M.classifyError(msg) }  -- L5 cause taxonomy
        end
      end
    end
  end
  return nil
end

-- Stale-"done" self-heal (symmetric to transcriptError's working->error override).
-- A tile's status is hook-driven: "done" is set by a Stop hook (or an idle
-- Notification) and nothing flips it back until the next *working* hook fires. In
-- Auto mode -- or whenever UserPromptSubmit / Pre/PostToolUse is missed (a text-only
-- reply fires no tool hooks; remote-control / auto-continued prompts can skip
-- UserPromptSubmit) -- the session resumes work but the tile keeps showing "Ready
-- for you". Detect resumption from the transcript tail: the model only writes
-- `assistant` lines while working, so a NEWEST assistant line timestamped AFTER the
-- status was last written (`updatedEpoch`, when Stop recorded "done") means the turn
-- restarted -> override done -> working. Keyed on assistant lines so IDE file-open
-- injections (user lines) and file-history snapshots never false-trigger; a
-- genuinely-done turn's own final assistant line is <= updatedEpoch (Stop fires after
-- it). `slack` (default 2s) absorbs same-second jitter. Pure (reuses isoToEpoch).
function M.transcriptResumed(text, updatedEpoch, slack)
  updatedEpoch = tonumber(updatedEpoch)
  if not text or #text == 0 or not updatedEpoch then return false end
  slack = tonumber(slack) or 2
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "assistant" and obj.timestamp then
        local ts = M.isoToEpoch(obj.timestamp)
        return (ts ~= nil) and (ts > updatedEpoch + slack) or false
      end
    end
  end
  return false
end

-- Classify an error message into a coarse CAUSE (L5 error-reason taxonomy): pure
-- keyword match over the lowercased text, most-specific first. The caller may
-- override from non-message signals (a usage-limit autoDeny -> budget_exceeded, the
-- watchdog -> timeout). Returns one of M.ERROR_REASONS.
M.ERROR_REASONS = { "budget_exceeded", "timeout", "runtime_error", "model_error",
                    "user_cancelled", "unknown" }
function M.classifyError(message)
  local s = tostring(message or ""):lower()
  if s == "" then return "unknown" end
  local rules = {
    -- HTTP codes are bucketed by FAILURE FAMILY, not numeric range: 429 rate-limit +
    -- 402 payment are quota/billing walls; 504/408 are timeouts; 500/502/503 are
    -- transient infra; 529 (below) is Anthropic "Overloaded", NOT a generic 5xx.
    -- "insufficient" is billing-scoped (not bare, which mis-hit "insufficient permissions").
    { "budget_exceeded", { "usage limit", "rate limit", "ratelimit", "quota", "insufficient quota",
                           "insufficient credit", "insufficient funds", "billing", "credit balance",
                           "exceeded your", "payment", "429", "402" } },
    { "timeout",         { "timeout", "timed out", "etimedout", "deadline exceeded", "504", "408" } },
    -- "connection aborted"/econnaborted are network faults -> must win before user_cancelled's "abort".
    { "runtime_error",   { "econnreset", "econnrefused", "enotfound", "epipe", "socket hang",
                           "network", "connection error", "connection reset", "connection aborted",
                           "econnaborted", "fetch failed", "503", "502", "500", "bad gateway" } },
    { "model_error",     { "overloaded", "529", "context length", "context_length", "too many tokens",
                           "max tokens", "invalid_request", "invalid request", "prompt is too long" } },
    { "user_cancelled",  { "cancel", "aborted", "abort", "interrupted", "user rejected" } },
  }
  for _, rule in ipairs(rules) do
    for _, kw in ipairs(rule[2]) do
      if s:find(kw, 1, true) then return rule[1] end
    end
  end
  return "unknown"
end

-- L5: surface the agent's current plan / TODO from the transcript tail. Scans
-- backwards for the latest TodoWrite todos and/or ExitPlanMode plan (tool_use blocks
-- inside assistant messages). Returns { todos = {{content, status}, ...}, plan = "..." }
-- (either may be absent) or nil when neither is present. Pure (operates on tail text;
-- the caller reads the tail on SELECTION, not every tick -- it parses the whole tail).
function M.planFromTranscript(text)
  if not text or #text == 0 then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local todos, plan
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "assistant"
         and type(obj.message) == "table" and type(obj.message.content) == "table" then
        for _, c in ipairs(obj.message.content) do
          if type(c) == "table" and c.type == "tool_use" and type(c.input) == "table" then
            if not todos and c.name == "TodoWrite" and type(c.input.todos) == "table" then
              local out = {}
              for _, td in ipairs(c.input.todos) do
                if type(td) == "table" and type(td.content) == "string" and td.content ~= "" then
                  out[#out + 1] = { content = td.content, status = tostring(td.status or "") }
                end
              end
              if #out > 0 then todos = out end
            elseif not plan and c.name == "ExitPlanMode" and type(c.input.plan) == "string"
                   and c.input.plan ~= "" then
              plan = c.input.plan
            end
          end
        end
      end
      if todos and plan then break end  -- newest-first; both found -> stop
    end
  end
  if not todos and not plan then return nil end
  return { todos = todos, plan = plan }
end

-- ---- DR3: checkpoint / rewind timeline -------------------------------------
-- Claude Code records restore points as `file-history-snapshot` transcript lines.
-- Per user-prompt turn it writes an ESTABLISHING snapshot (isSnapshotUpdate falsy;
-- its snapshot.messageId == that user line's `uuid`, verified against real local
-- transcripts 2026-06-18) carrying the CUMULATIVE
-- snapshot.trackedFileBackups = { <absPath> = {backupFileName, version, backupTime} }
-- as captured when the turn began, plus zero+ UPDATE lines (isSnapshotUpdate true,
-- SAME snapshot.messageId) appended as files change during the turn. Shepherd READS
-- this to show "where we are / where we can rewind to"; the rewind ACTION just types
-- /rewind into the session (Claude Code's own picker confirms the destructive part).
--
-- core.checkpointTimeline(snapText, opts) -> NEWEST-first list of restore points:
--   { messageId, ts (epoch|nil), iso, fileCount, filesChanged, changed = {{path,name,version}, ...} }
-- `snapText` is the transcript reduced to ONLY its file-history-snapshot lines (the
-- caller streams the multi-MB transcript and keeps just those ~hundreds of KB). Prompt
-- LABELS are attached by the caller (core.userPromptSnippet over the few user lines
-- that ARE restore points) -- kept out of here so this stays a pure function of the
-- snapshot lines. "Files changed this turn" = a diff of THIS turn's establishing
-- baseline against the NEXT turn's establishing baseline (its committed end state),
-- falling back to this turn's own last cumulative map for the most-recent turn (whose
-- committed changes aren't captured until the next prompt). opts.limit caps the result
-- (default 80, most-recent kept). Pure + deterministic.
function M.checkpointTimeline(snapText, opts)
  opts = opts or {}
  local limit = tonumber(opts.limit) or 80
  if type(snapText) ~= "string" or #snapText == 0 then return {} end
  local order, seen = {}, {}     -- messageIds in establishing-first order
  local establishing = {}        -- messageId -> { iso, ts, map = {path -> {version, backupTime}} }
  local final = {}               -- messageId -> last-seen cumulative map for that mid
  for line in (snapText .. "\n"):gmatch("(.-)\n") do
    if line:find("^%s*{") and line:find("file%-history%-snapshot", 1, false) then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "file-history-snapshot"
         and type(obj.snapshot) == "table" then
        local s = obj.snapshot
        local mid = s.messageId
        if type(mid) == "string" and mid ~= "" then
          local map = {}
          if type(s.trackedFileBackups) == "table" then
            for path, info in pairs(s.trackedFileBackups) do
              if type(path) == "string" and type(info) == "table" then
                map[path] = { version = tonumber(info.version) or 0,
                              backupTime = type(info.backupTime) == "string" and info.backupTime or "" }
              end
            end
          end
          if not seen[mid] then
            seen[mid] = true
            order[#order + 1] = mid
            establishing[mid] = { iso = s.timestamp, ts = M.isoToEpoch(s.timestamp), map = map }
          end
          final[mid] = map        -- last line wins (updates come after the establishing line)
        end
      end
    end
  end
  local points = {}
  for i = 1, #order do
    local mid = order[i]
    local est = establishing[mid]
    local base = est.map
    local endMap = (i < #order and establishing[order[i + 1]].map) or final[mid] or base
    local changed = {}
    for path, info in pairs(endMap) do
      local b = base[path]
      if (not b) or b.version ~= info.version or b.backupTime ~= info.backupTime then
        changed[#changed + 1] = { path = path, name = path:match("([^/]+)$") or path, version = info.version }
      end
    end
    table.sort(changed, function(a, b) return a.path < b.path end)
    local total = 0; for _ in pairs(endMap) do total = total + 1 end
    points[#points + 1] = { messageId = mid, iso = est.iso, ts = est.ts,
                            fileCount = total, filesChanged = #changed, changed = changed }
  end
  local out = {}                  -- newest-first, capped
  for i = #points, 1, -1 do
    if #out >= limit then break end
    out[#out + 1] = points[i]
  end
  return out
end

-- DR3 label helper: extract a short prompt snippet from ONE raw `user` transcript
-- JSONL line. message.content is either a string or an array of blocks (text +
-- tool_result + …); we take the first text. The caller passes only the handful of
-- user lines that ARE restore points (matched by uuid), so decoding a large
-- pasted-prompt line here is bounded. Returns "" for a tool_result-only turn / no
-- user text. Pure (reuses the json decoder + utf8trunc).
function M.userPromptSnippet(line, maxLen)
  maxLen = tonumber(maxLen) or 140
  if type(line) ~= "string" or not line:find("^%s*{") then return "" end
  local okj, obj = pcall(function() return M.json.decode(line) end)
  if not okj or type(obj) ~= "table" or obj.type ~= "user" or type(obj.message) ~= "table" then return "" end
  local content, txt = obj.message.content, nil
  if type(content) == "string" then
    txt = content
  elseif type(content) == "table" then
    for _, c in ipairs(content) do
      if type(c) == "table" and c.type == "text" and type(c.text) == "string" and #c.text > 0 then
        txt = c.text; break
      elseif type(c) == "string" and #c > 0 then
        txt = c; break
      end
    end
  end
  if type(txt) ~= "string" then return "" end
  local first
  for ln in (txt .. "\n"):gmatch("(.-)\n") do
    local t = ln:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then first = t; break end
  end
  if not first then return "" end
  first = first:gsub("%s+", " ")
  if #first > maxLen then first = utf8trunc(first, maxLen - 3) .. "\226\128\166" end
  return first
end

-- L5 auto-title: a short tile title derived from a session's first prompt (the
-- cc-status last_prompt seed). First non-blank line, with markdown header / list /
-- quote markers stripped, whitespace collapsed, UTF-8-truncated to maxLen. Returns
-- nil for a blank seed. Pure; the precedence (manual relabel > auto-title > folder)
-- and the per-projectKey cache live in the caller; esc() applies at the render sink.
function M.deriveAutoTitle(seed, maxLen)
  maxLen = tonumber(maxLen) or 48
  local first
  for line in (tostring(seed or "") .. "\n"):gmatch("(.-)\n") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then first = t; break end
  end
  if not first then return nil end
  first = first:gsub("^[#>%*%-%s]+", ""):gsub("^%d+[.%)]%s*", "")  -- strip md/list/quote markers
  first = first:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if first == "" then return nil end
  if #first > maxLen then first = utf8trunc(first, maxLen - 3) .. "\226\128\166" end
  return first
end

-- L5 loop-detection: a stable signature for a tool_use block = name + its primary
-- argument (the field that identifies WHAT it's doing), so re-running the same Bash
-- command / re-Reading the same file produces an equal signature. Deterministic
-- (no json re-encode, whose key order isn't stable). Pure.
local LOOP_PRIMARY = { "command", "file_path", "path", "pattern", "url", "query", "prompt" }
function M.toolCallSig(name, input)
  local arg = ""
  if type(input) == "table" then
    for _, f in ipairs(LOOP_PRIMARY) do
      if type(input[f]) == "string" and input[f] ~= "" then arg = input[f]; break end
    end
  end
  return tostring(name or "") .. "\1" .. arg
end

-- Ordered (oldest->newest) list of the last `limit` tool-call signatures in the
-- transcript tail. Pure; the caller reads the tail (already read for working tiles).
function M.transcriptToolSigs(text, limit)
  limit = tonumber(limit) or 12
  local sigs = {}
  if not text or #text == 0 then return sigs end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:find("^%s*{") then
      local okj, obj = pcall(function() return M.json.decode(line) end)
      if okj and type(obj) == "table" and obj.type == "assistant"
         and type(obj.message) == "table" and type(obj.message.content) == "table" then
        for _, c in ipairs(obj.message.content) do
          if type(c) == "table" and c.type == "tool_use" then
            sigs[#sigs + 1] = M.toolCallSig(c.name, c.input)
          end
        end
      end
    end
  end
  -- keep only the last `limit`
  if #sigs > limit then
    local trimmed = {}
    for i = #sigs - limit + 1, #sigs do trimmed[#trimmed + 1] = sigs[i] end
    return trimmed
  end
  return sigs
end

-- True when the last `n` tool-call signatures are identical (the agent is repeating
-- the same action) -- the loop-detection watchdog. n>=2; pure.
function M.isLooping(sigs, n)
  n = tonumber(n) or 3
  if n < 2 or type(sigs) ~= "table" or #sigs < n then return false end
  local last = sigs[#sigs]
  -- ignore an arg-less signature ("Name\1" -- no primary arg, e.g. TodoWrite/ExitPlanMode):
  -- normal repeated todo updates shouldn't read as a loop. Only a name+arg repeat counts.
  if type(last) ~= "string" or last == "" or last:sub(-1) == "\1" then return false end
  for i = #sigs - n + 1, #sigs do
    if sigs[i] ~= last then return false end
  end
  return true
end

-- L5 OS-native banner decision: on a FRESH rising edge into approval/done (gated by
-- notifications.banner.{onApproval,onDone}), return {kind, title, text} for FX.notify,
-- else nil. Pure; prevStatus is last tick's status (nil = no prior observation = no
-- edge, so a reload can't fire a banner for every existing tile).
function M.notifyDecision(prevStatus, item, cfg)
  if type(item) ~= "table" or prevStatus == nil then return nil end
  local cur = item.status
  if cur == prevStatus then return nil end  -- not a transition
  local name = item.label or item.name or "session"
  if cur == "approval" and M.config(cfg, "notifications.banner.onApproval", false) == true then
    local sum = (type(item.pending) == "table" and item.pending.summary) or ""
    return { kind = "approval", title = "Needs you — " .. name,
             text = (sum ~= "" and ("wants: " .. sum)) or "waiting for approval" }
  elseif cur == "done" and M.config(cfg, "notifications.banner.onDone", false) == true then
    return { kind = "done", title = "Done — " .. name,
             text = (type(item.activity) == "string" and item.activity ~= "" and item.activity) or "finished its turn" }
  end
  return nil
end

-- ---- Token usage (local, ZERO-COST: parsed from transcript JSONL) ----------
-- Claude Code logs every turn's token counts to the local transcript; reading it
-- costs no tokens and makes no network call. These pure helpers parse + aggregate
-- those counts; the impure side (file reads) lives in the dashboard's FX layer.
M.CONTEXT_LIMIT_DEFAULT = 200000      -- Claude Opus/Sonnet context window
-- Claude Code measures "% context used / until auto-compact" against the window MINUS an
-- output reserve, so its number runs higher than tokens/rawWindow. We model that reserve
-- as a fraction of the window so the per-tile bar tracks the editor's reading. The exact
-- threshold is undocumented; ~0.92 was calibrated against a live 1M session (Shepherd's
-- ~90% lined up with the editor's ~98%). Hand-tunable via config `context.autoCompactFraction`.
M.CONTEXT_AUTOCOMPACT_DEFAULT = 0.92
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

-- The auto-compact fraction from config, clamped to a SANE range [0.5, 1]. The output
-- reserve is small (a 1M window reserves well under half for output), so anything below
-- ~0.5 is a typo, not a real reserve -- and a tiny value (e.g. 0.01) would shrink the
-- denominator to ~0 and pin every tile to a false 100% b6. Off-range / non-numeric falls
-- back to the default so a bad Settings value can't break the bar.
function M.autoCompactFraction(cfg)
  local f = tonumber(M.config(cfg, "context.autoCompactFraction", M.CONTEXT_AUTOCOMPACT_DEFAULT))
  if not f or f < 0.5 or f > 1 then return M.CONTEXT_AUTOCOMPACT_DEFAULT end
  return f
end

-- The context-fullness fraction (0..1) + the effective limit used. Combines the
-- model/provider limit with the observed-size tier guard, then applies the auto-compact
-- reserve so the bar matches Claude Code's "% until auto-compact" reading. The denominator
-- is right for known models, can't be smaller than what the session actually holds, and
-- accounts for the output reserve the editor measures against.
function M.contextFractionFor(cfg, model, tokens)
  local window = math.max(M.contextLimitFor(cfg, model), M.nextContextTier(tokens))
  local limit = window * M.autoCompactFraction(cfg)
  return M.contextFraction(tokens, limit), limit
end

-- Per-tile context bar color band. Calm below 50%, then a new band every 10% (50/60/70/80/90),
-- with a distinct critical band for the last 5% (95-100%). b0..b6. TWIN: the same thresholds
-- live in the embedded-JS `barLevel` function in claude-dashboard.lua (search "Mirror of
-- core.contextBand"); the ui.test.lua pin "js-pin: barLevel mirrors the 7-band contextBand
-- ramp" fails the build if they drift -- edit both.
function M.contextBand(frac)
  local f = tonumber(frac) or 0
  if f >= 0.95 then return "b6" end
  if f >= 0.90 then return "b5" end
  if f >= 0.80 then return "b4" end
  if f >= 0.70 then return "b3" end
  if f >= 0.60 then return "b2" end
  if f >= 0.50 then return "b1" end
  return "b0"
end

-- Stream Deck context-fill bucket: quantize a context fraction into ~2.5% steps (0..40) so the
-- per-key repaint signature changes as the bar grows but not on every sub-pixel tick. Clamps to
-- [0,1] first (a frac >1 from a stale aggregate would otherwise overflow the bucket). Returns nil
-- for nil / non-numeric input -- the deck uses that as the "no bar drawn" sentinel (distinct from a
-- real 0 bucket, which draws an empty bar). TWIN: sdButtonImage/sdRender in claude-dashboard.lua
-- call this; the ui.test pin fails the build if a site stops using it.
function M.contextBucket(frac)
  local f = tonumber(frac)
  if not f then return nil end
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return math.floor(f * 40)
end

-- Voice dictation hard cap (seconds), read from cc-config `voice.maxSeconds`. Anti-runaway: a
-- non-positive or non-numeric override falls back to the 120s default so ffmpeg never gets `-t 0`
-- (which would record unbounded). Pure so the clamp is pinned by a test rather than a source grep.
function M.voiceMaxSeconds(cfg)
  local n = tonumber(M.config(cfg, "voice.maxSeconds", 120))
  if not n or n <= 0 then return 120 end
  return n
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
  if type(q) == "table" then
    if q.routing == true then out.routing = true end
    -- L4 process mode rides the queue file like `routing`; carry it through every
    -- rebuild so a pop/move/push can't silently revert a sequential queue.
    if q.mode == "sequential" then out.mode = "sequential" end
  end
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

-- The front task without removing it. The router peeks the head to resolve a
-- routed task's @role: before choosing a target (the dispatcher then pops it).
function M.queuePeek(q) return qtasks(q)[1] end

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
  if M.queueRouteMode(q) == "sequential" then out.mode = "sequential" end  -- preserve mode
  return out
end

-- Process mode (L4): "distribute" (default) fans the queue across whichever member
-- is free (today's routePick); "sequential" serializes -- at most ONE routed task
-- in flight per project, the next starting only after the current finishes (other
-- members are held). Rides the queue file like `routing` (absent = distribute).
function M.queueRouteMode(q)
  return (type(q) == "table" and q.mode == "sequential") and "sequential" or "distribute"
end
function M.queueSetMode(q, mode)
  local out = { tasks = qtasks(q) }
  if type(q) == "table" and q.routing == true then out.routing = true end  -- preserve arm
  if mode == "sequential" then out.mode = "sequential" end  -- absent = distribute (legacy shape)
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

-- Does the project have a routed task IN FLIGHT? (sequential mode holds the queue
-- until the current one finishes.) True if any member is mid-turn (working/approval)
-- or carries a FRESH pending routed-feed marker. opts = { pending = map key->ts,
-- now, pendingTimeout }.
-- R2-19: a STALE (dead/frozen) member must NOT count as in-flight -- a session that
-- died/froze mid-turn keeps status=='working' and would otherwise hold a sequential
-- queue forever behind a corpse, with no starvation alert (queueStarved suppresses
-- on the sequential-busy branch). Mirrors the `not it.stale` discipline in
-- sessionFree/routeBarrierMet (the PICK side already excludes stale).
function M.projectBusy(members, opts)
  opts = opts or {}
  local pending = opts.pending or {}
  for _, it in ipairs(members or {}) do
    if type(it) == "table" then
      if not it.stale and (it.status == "working" or it.status == "approval") then return true end
      local ts = pending[it.key]
      if ts ~= nil then
        local expired = ((tonumber(opts.now) or 0) - (tonumber(ts) or 0))
          > (tonumber(opts.pendingTimeout) or M.ROUTE_PENDING_TIMEOUT)
        if not expired then return true end
      end
    end
  end
  return false
end

-- ---- L4 conditional routing: @role: labels ---------------------------------
-- A queued task may carry a leading "@role:" prefix addressing it to a session
-- ROLE (the DECIDED affinity source). Returns (role|nil, bareText): the role
-- lowercased, and the task with the prefix stripped -- the bare text is what gets
-- TYPED (the session never sees the routing scaffolding). A prefix with nothing
-- after it is treated as literal text (no role), so a stray "@x:" can't blank a task.
function M.taskRoute(task)
  -- R3-06: strip leading whitespace at the parse chokepoint so a task like
  -- " @review: x" (queue-add bridge / L6 feed don't pre-trim) is still recognized
  -- as routed and the scaffolding is stripped (renderFeed types the trimmed bare text).
  task = tostring(task or ""):gsub("^%s+", "")
  local role, rest = task:match("^@([%w._%-]+):%s*(.*)$")
  if role and rest and rest:gsub("%s+$", "") ~= "" then return role:lower(), rest end
  return nil, task
end

-- A member's role axis for @role: matching: its session GROUP (the shipped per-tile
-- cohort tag), lowercased. nil/blank -> nil. An UNLABELED task matches any member;
-- a LABELED task matches only members whose group equals the role.
function M.memberRole(item)
  local g = item and item.group
  if type(g) == "string" then
    g = g:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if g ~= "" then return g end
  end
  return nil
end

-- A queued task may be a JOIN BARRIER (L4): a leading "@all:" waits until ALL of
-- the project's members have finished, "@any:" until AT LEAST ONE has, before it
-- routes. Returns (mode|nil, rest). "all"/"any" are reserved (a group so named
-- can't be @-addressed); a barrier composes with a role -- "@all: @review: x" is a
-- join THEN a role. A prefix with no body after it is literal text (no barrier).
function M.taskBarrier(task)
  -- R3-06: strip leading whitespace (untrimmed callers: queue-add bridge, L6 feed).
  task = tostring(task or ""):gsub("^%s+", "")
  -- R3-05: lowercase the matched keyword before the reserved-word test, mirroring
  -- taskRoute's role:lower(), so @ALL:/@Any:/etc. are recognized as barriers (and thus
  -- excluded from role routing) -- otherwise an uppercase barrier silently degrades to
  -- a role filter (group=='all') and the task stalls forever.
  local kw, rest = task:match("^@(%a+):%s*(.*)$")
  kw = kw and kw:lower() or kw
  if (kw == "all" or kw == "any") and rest and rest:gsub("%s+$", "") ~= "" then
    return kw, rest
  end
  return nil, task
end

-- Is a join barrier satisfied? "all" = every DRIVABLE member settled (done);
-- "any" = at least one settled. Flat AND/OR over done-state -- no nested tree.
-- nil/unknown mode -> true (not a barrier). Empty (or all-non-drivable) -> false.
-- R2-18: stale/remote members are EXCLUDED from the requirement, not permanent
-- blockers. They can never become `settled` (the PICK side, sessionFree, excludes
-- them), so counting them in `total` made "all" forever-unsatisfiable whenever any
-- sibling was dead/frozen/remote -- a silent permanent stall (routeTask returns nil
-- and queueStarved is suppressed). Matches sessionFree's drivable notion.
function M.routeBarrierMet(members, mode)
  if mode ~= "all" and mode ~= "any" then return true end
  local settled, total = 0, 0
  for _, it in ipairs(members or {}) do
    if type(it) == "table" and not it.stale and not it.remote then
      total = total + 1
      if it.status == "done" then settled = settled + 1 end
    end
  end
  if total == 0 then return false end
  if mode == "all" then return settled == total end
  return settled >= 1
end

-- Pick the target for one project's next task. Deterministic: longest-free
-- first (smallest `since` -- the status file stamps it on each status change),
-- key ascending as the tiebreak; a missing `since` reads as "just changed"
-- (lowest priority). members = parsed items sharing one queueKey. opts =
-- { draining = map key->bool, pending = map key->ts, now, pendingTimeout,
-- role = label|nil }. With a role set, only members whose memberRole matches are
-- eligible (conditional routing). Returns the chosen tile key, or nil when none free.
function M.routePick(members, opts)
  opts = opts or {}
  local draining = opts.draining or {}
  local pending = opts.pending or {}
  local role = opts.role
  local best, bestSince
  for _, it in ipairs(members or {}) do
    if (role == nil or M.memberRole(it) == role)
       and M.sessionFree(it, { draining = draining[it.key], pending = pending[it.key],
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
  -- sequential mode: hold while a routed task is still in flight (one at a time)
  if M.queueRouteMode(q) == "sequential"
     and M.projectBusy(members, { pending = opts.pending, now = opts.now,
                                  pendingTimeout = opts.pendingTimeout }) then
    return nil
  end
  local barrier, afterB = M.taskBarrier(M.queuePeek(q))  -- @all:/@any: join on the head
  if barrier and not M.routeBarrierMet(members, barrier) then return nil end  -- hold until met
  local role = select(1, M.taskRoute(afterB))  -- @role: (possibly after the barrier)
  local key = M.routePick(members, { draining = opts.draining, pending = opts.pending,
    now = opts.now, pendingTimeout = opts.pendingTimeout, role = role })
  if not key then return nil end
  return { key = key, role = role, barrier = barrier }
end

-- R1-18: re-validate a routed feed AFTER the pop, before committing. routeTask peeks
-- the head and picks a member for that head's @role:/barrier; the actual pop happens
-- later inside the dispatchSerialized slot and re-reads the file FIFO. If the operator
-- reorders the queue (queue-move) during the sub-second stagger, the popped task may
-- carry a DIFFERENT @role: than the chosen member -> a role-addressed task lands in a
-- non-matching member. This recomputes barrier + role from the freshly-popped task and
-- the chosen item, returning true only when both still hold (so the caller can refuse
-- the feed and leave the task queued for the next tick to re-pick). Pure.
function M.routeFeedMatches(item, task, members)
  if type(item) ~= "table" then return false end
  local barrier, afterB = M.taskBarrier(task)
  if barrier and not M.routeBarrierMet(members, barrier) then return false end
  local role = select(1, M.taskRoute(afterB))
  if role ~= nil and M.memberRole(item) ~= role then return false end
  return true
end

-- Starvation check: an armed project with queued work and NO free session for
-- longer than `minutes`. sinceTs = when the caller first observed the starved
-- condition (it keeps the clock; pure here). minutes <= 0 disables.
function M.queueStarved(members, q, opts)
  opts = opts or {}
  local minutes = tonumber(opts.minutes) or 0
  if minutes <= 0 then return false end
  if not M.queueRouted(q) or M.queueDepth(q) == 0 then return false end
  -- R1-16: a sequential queue with a task in flight is PROGRESSING one-at-a-time, not
  -- starved. routeTask already holds (returns nil) for sequential-busy; mirror that
  -- here so the dispatcher's starvation branch doesn't fire queue_starved on a queue
  -- working exactly as designed. projectBusy defaults pendingTimeout when nil.
  if M.queueRouteMode(q) == "sequential"
     and M.projectBusy(members, { pending = opts.pending, now = opts.now,
                                  pendingTimeout = opts.pendingTimeout }) then
    return false
  end
  -- a head waiting on an unmet join barrier is WAITING, not starved
  local barrier, afterB = M.taskBarrier(M.queuePeek(q))
  if barrier and not M.routeBarrierMet(members, barrier) then return false end
  -- starved = the FIFO head can't be routed (its @role: has no free matching member)
  local role = select(1, M.taskRoute(afterB))
  if M.routePick(members, { draining = opts.draining, pending = opts.pending,
       now = opts.now, pendingTimeout = opts.pendingTimeout, role = role }) ~= nil then return false end
  local sinceTs = tonumber(opts.sinceTs)
  if not sinceTs then return false end
  return ((tonumber(opts.now) or 0) - sinceTs) > minutes * 60
end

-- L4 per-task timing: a fed queue task completes on the FIRST done edge after it
-- was fed. Given the recorded start ({ts=...}) and the tile's prev/cur status,
-- returns { durationS } on that edge, else nil. Same edge discipline as shouldFeed
-- (a nil prev = no prior observation, not a completion; prev==done already handled).
function M.stepTaskDone(start, prev, cur, now)
  if type(start) ~= "table" or start.ts == nil then return nil end
  if cur ~= "done" then return nil end
  if prev == nil or prev == "done" then return nil end
  return { durationS = math.max(0, (tonumber(now) or 0) - (tonumber(start.ts) or 0)) }
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
-- R2-21: the retry-budget key. projectKey alone is the LAUNCH FOLDER, so two
-- parallel sessions in one folder share ONE budget -- a healthy/recovered sibling
-- then zeroes a crash-looper's budget each reset tick and the cap never binds.
-- Key per terminal WINDOW (kitty socket#window, stable across a respawn that reuses
-- the window but distinct per genuine sibling) when available; fall back to
-- projectKey/cwd for non-kitty editors with no terminal identity (accepting
-- per-folder sharing only there -- the same safe side staleDuplicateKeys takes).
-- MUST NOT key by session_id: a respawn deliberately gives a NEW session_id but the
-- SAME window, and the count must carry across respawns toward the cap.
function M.budgetKey(item)
  item = item or {}
  local pk = item.projectKey or item.cwd
  local sock, wid = item.kitty_listen_on, item.kitty_window_id
  if pk and sock ~= nil and sock ~= "" and wid ~= nil and wid ~= "" then
    return pk .. "@" .. tostring(sock) .. "#" .. tostring(wid)
  end
  return pk
end

function M.stepAutoRespawn(attempts, item, opts)
  attempts = attempts or {}
  opts = opts or {}
  item = item or {}
  local pk = M.budgetKey(item)
  -- Healthy -> reset the folder budget, but ONLY after sustained health. A freshly
  -- relaunched tile is non-stale by construction (SessionStart just wrote it), so
  -- resetting on first sight would wipe the budget ~90s before the relaunch could
  -- possibly re-edge -- maxRetries would never bind and a crash loop respawns
  -- forever. `since` is when the tile entered its current status (cc-status.sh
  -- keeps it across same-status updates); require it to have survived a full stale
  -- window. No now/since/staleSeconds -> fail closed (keep the budget).
  local since = tonumber(item.since)
  if not (item.stale or false) and pk and opts.now and opts.staleSeconds and since
    and (opts.now - since) > opts.staleSeconds then
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
  local updated = tonumber(item.updated)
  local frozen = (opts.now ~= nil and updated ~= nil and rss ~= nil
    and (opts.now - updated) > rss) or false
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

-- ---- Auto-Continue on a frozen API error (opt-in, bounded) -----------------
-- A session frozen on an API error (e.g. ECONNRESET) renders as status=="error" and is
-- normally resumed by the operator clicking Continue (types "continue" + Enter). This pure
-- gate decides whether to do that automatically: only for an errored tile, only once a grace
-- delay has elapsed since the error appeared, and only under a per-folder attempt cap so a
-- persistently dead connection can't loop forever. Pure "is it time?" gate; stepAutoContinue
-- owns the timers/budget and the dashboard fires the keystroke. args =
--   { status, elapsed (since error first seen), minSeconds, attempts, maxAttempts }
function M.shouldAutoContinue(args)
  args = args or {}
  if args.status ~= "error" then return false end                    -- only a frozen API error
  if (tonumber(args.elapsed) or 0) < (tonumber(args.minSeconds) or 0) then return false end
  local cap = tonumber(args.maxAttempts) or 0
  if cap <= 0 then return false end                                  -- 0/absent = disabled
  return (tonumber(args.attempts) or 0) < cap                        -- under the per-folder budget
end

-- Advance auto-continue bookkeeping for one tile per tick; return whether to fire "continue"
-- now. Mutates `state` = { since = {key->ts}, attempts = {projectKey->count} } in place:
--   * stamp `since[key]` on the first error sighting (the grace clock starts here);
--   * a fire restarts that clock (since=now) so retries are spaced ~minSeconds apart rather
--     than firing maxAttempts times on consecutive ticks while the tile is still "error";
--   * leaving error clears the tile's clock, and reaching a CLEAN completion (done/idle) --
--     never the `working` the continue itself produces -- resets the folder budget, so a
--     still-dead connection that re-errors keeps counting toward the cap instead of looping.
--   item : { key, projectKey, cwd, status }
--   opts : { enabled, minSeconds, maxAttempts, now }
-- returns: { fire, elapsed, attempts }
function M.stepAutoContinue(state, item, opts)
  state = state or {}; state.since = state.since or {}; state.attempts = state.attempts or {}
  opts = opts or {}; item = item or {}
  local key = item.key
  local pk = M.budgetKey(item) or key  -- R2-21: per-window budget (see budgetKey)
  if not key then return { fire = false } end
  if item.status ~= "error" then
    -- R3-23: distinguish "left the error state" from "couldn't determine status this
    -- tick". The dashboard derives status=='error' from a fresh transcript-tail read;
    -- a momentary read failure (io.open flap) makes status fall back to 'working', and
    -- naively wiping the grace clock here would restart the full delaySeconds countdown
    -- on every flicker, indefinitely delaying resume of a genuinely-frozen session.
    -- statusKnown defaults true (callers passing real statuses are unaffected); only a
    -- FAILED-read tick (statusKnown==false) preserves an already-running grace clock and
    -- does not fire (we can't confirm the session is still errored).
    if opts.statusKnown == false and state.since[key] ~= nil then
      return { fire = false }
    end
    state.since[key] = nil
    if item.status == "done" or item.status == "idle" then state.attempts[pk] = nil end
    return { fire = false }
  end
  if state.since[key] == nil then state.since[key] = opts.now end
  local elapsed = (tonumber(opts.now) or 0) - (tonumber(state.since[key]) or 0)
  local n = state.attempts[pk] or 0
  local fire = (opts.enabled == true) and M.shouldAutoContinue({
    status = item.status, elapsed = elapsed,
    minSeconds = opts.minSeconds, attempts = n, maxAttempts = opts.maxAttempts }) or false
  -- R2-22: restart the grace clock on a fired attempt (so a fired-but-undelivered
  -- tile re-spaces instead of re-firing every tick), but DO NOT charge the budget
  -- here -- the charge happens on CONFIRMED delivery via chargeAutoContinue. A
  -- session whose window can't be matched would otherwise burn maxAttempts without
  -- ever typing "continue" (handleAction returns nil / ledgers skipped on a miss).
  if fire then state.since[key] = opts.now end
  return { fire = fire, elapsed = elapsed, attempts = pk and state.attempts[pk] or nil,
           budgetKey = pk }
end

-- R2-22: charge one auto-continue attempt against the per-window budget. Called by
-- the dashboard ONLY after a "continue" keystroke actually landed (handleAction
-- returned "continue"), so an undelivered attempt never advances the cap.
function M.chargeAutoContinue(state, pk)
  if not (state and pk) then return end
  state.attempts = state.attempts or {}
  state.attempts[pk] = (state.attempts[pk] or 0) + 1
end

-- ---- Auto-enable Remote Control on already-running sessions -----------------
-- Which live tiles should receive an automatic `/rc` (remote-control) keystroke on Shepherd
-- startup. Shepherd-SPAWNED sessions get RC via the --remote-control launch flag, and after a
-- computer restart a relaunched session comes up fresh; this sweep covers the gap -- sessions
-- that were ALREADY running (started outside Shepherd, or before Shepherd booted). Targets are
-- real, LOCAL, non-stale sessions in a quiescent state (idle/done) where typing a slash command
-- runs cleanly; working/approval/error tiles are skipped so we never inject mid-turn or over a
-- pending permission prompt. Pure filter; the dashboard fires the keystrokes through the
-- serialized chokepoint. (/rc is idempotent -- a second run just opens the status panel.)
function M.remoteControlSweepTargets(list)
  local out = {}
  for _, it in ipairs(list or {}) do
    if it and not it.remote and not it.stale
       and (it.status == "idle" or it.status == "done")
       and it.session_id ~= nil and tostring(it.session_id) ~= ""
       -- RC needs claude.ai auth and rejects gateway/third-party providers, so /rc would
       -- just error in a gateway session -- skip those (a base_url marks a gateway tile).
       and M.isAnthropicSession(it.model, it.base_url) then
      out[#out + 1] = it
    end
  end
  return out
end

-- Should this tile be pruned? Orphans = stale tiles with no session_id (a hook
-- fire that lacked one, keyed by folder name, that SessionEnd can't clean), plus
-- a ghost backstop for anything older than opts.pruneSeconds.
function M.shouldPrune(item, now, opts)
  opts = opts or {}
  if not item then return false end
  local updated = tonumber(item.updated)
  local age = updated and (now - updated) or 0
  local orphan = opts.pruneNoSid and item.stale
    and (not item.session_id or item.session_id == "")
  local ghost = opts.pruneSeconds and opts.pruneSeconds > 0
    and updated and age > opts.pruneSeconds
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
-- it sits alive holding its result. The shared WINDOW is the evidence: a /clear
-- reuses the same window, while genuine parallel sessions occupy distinct windows.
-- The per-window id is kitty's socket+window pair, or (non-kitty editors like VS
-- Code/Cursor) the `host_window` pid cc-status.sh captures -- the claude session
-- process's parent, which a /clear keeps (a new session_id spawns a fresh claude
-- under the SAME editor window) and which differs per window. Tiles with NO window
-- identity at all are never pruned here; the 24h shouldPrune backstop owns those.
function M.staleDuplicateKeys(list)
  local function projKey(it) return it.projectKey or it.cwd end
  local function termId(it)  -- a STABLE per-window id; nil when unknown
    local sock, wid = it.kitty_listen_on, it.kitty_window_id
    -- kitty: need BOTH socket+window id -- a bare window id is a per-instance counter
    -- (two default kitty instances both yield "1"), so a half identity falls through to
    -- host_window / the safe side (full rationale in the header comment above).
    if sock ~= nil and sock ~= "" and wid ~= nil and wid ~= "" then
      return "kitty:" .. tostring(sock) .. "#" .. tostring(wid)
    end
    -- non-kitty editors have no kitty handles: use the host-window pid (the claude
    -- session process's parent -- stable across /clear, distinct per editor window).
    local hw = it.host_window
    if hw ~= nil and tostring(hw) ~= "" then return "host:" .. tostring(hw) end
    return nil
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
  if not item or item.status ~= "approval" then return false end
  local since = tonumber(item.since)
  if not since then return false end
  return (now - since) > thresholdSec
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
  spawn = { "kittyBin", "kittySocket", "searchRoots", "searchDepth", "fdBin", "claudeBin",
            "coldWindowWaitSeconds", "coldActivateSeconds" },
  escalation = { "hung" },
  risk = { "weights" },
  bridge = { "staleSlackSeconds", "keystrokes" },
  context = { "autoCompactFraction" },
  -- The L5 banner toggles made `notifications` a form-managed block; its
  -- hand-edited `days` (the 🔔 history lookback window, no UI input) must survive
  -- a Save just like escalation.hung does. `banner` is form-managed -> not kept.
  notifications = { "days", "_comment" },
  -- #6 host stats: maxBlockSeconds + hostStats are form-managed; the hand-edited
  -- hostPressure.{cpu,mem,disk} thresholds (no UI input) must survive a Save.
  insights = { "hostPressure" },
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

-- L5 hooks inspector: flatten a settings.json `hooks` table into per-hook rows
-- {event, matcher, command, timeout, isOurs, script} for a read-only inventory.
-- Pure. `script` = the matching OUR_HOOK_SCRIPTS basename (or nil). Events sorted.
function M.parseHookInventory(settings)
  local out = {}
  local hooks = (type(settings) == "table" and type(settings.hooks) == "table") and settings.hooks or {}
  local events = {}
  for ev in pairs(hooks) do events[#events + 1] = tostring(ev) end
  table.sort(events)
  for _, ev in ipairs(events) do
    local groups = hooks[ev]
    if type(groups) == "table" then
      for _, g in ipairs(groups) do
        if type(g) == "table" and type(g.hooks) == "table" then
          local matcher = (type(g.matcher) == "string" and g.matcher ~= "") and g.matcher or "*"
          for _, h in ipairs(g.hooks) do
            if type(h) == "table" then
              local cmd = type(h.command) == "string" and h.command or ""
              local script
              for _, name in ipairs(M.OUR_HOOK_SCRIPTS) do
                if cmd:find(name, 1, true) then script = name; break end
              end
              out[#out + 1] = { event = ev, matcher = matcher, command = cmd,
                                timeout = tonumber(h.timeout), isOurs = script ~= nil, script = script }
            end
          end
        end
      end
    end
  end
  return out
end

-- The gate hook (cc-approve.sh) needs its long timeout: the nonce-bound atomic
-- claim runs well past Claude Code's default. Returns { present, timeout, ok }.
-- minTimeout defaults to 130 (what install.sh sets).
function M.gateHookTimeoutOk(inventory, minTimeout)
  minTimeout = tonumber(minTimeout) or 130
  for _, h in ipairs(type(inventory) == "table" and inventory or {}) do
    if h.script == "cc-approve.sh" then
      local t = tonumber(h.timeout)
      return { present = true, timeout = t, ok = (t ~= nil and t >= minTimeout) }
    end
  end
  return { present = false, ok = false }
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
    -- R1-24: a raw per-variant ANTHROPIC_MODEL (DR7 native A/B, no provider profile)
    -- is recorded on the tile but matches no providers entry, so providerByModel
    -- returns nil and the relaunch would otherwise run the account DEFAULT model.
    -- Carry the raw model so the relaunch faithfully reuses it. Only for a base-less
    -- (native Anthropic) session with NO matched profile -- a profile match (its
    -- model wins via env) or a gateway session (base_url set) leaves this nil.
    model = (not profile and not hasBase and item.model and tostring(item.model) ~= "")
            and tostring(item.model) or nil,
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
    -- R1-11: authTokenEnv is an env-var NAME, emitted RAW between double quotes as
    -- ANTHROPIC_AUTH_TOKEN="$<name>" so the spawned shell expands it. A shell var
    -- name can ONLY be [A-Za-z_][A-Za-z0-9_]* anyway, so constrain to that and fail
    -- closed on anything else: a name with $(...)/backtick/"/; would otherwise run
    -- arbitrary substitution in the spawn shell. A dropped token just 401s (the same
    -- as today's empty-name case) -- correct fail-closed, never code execution.
    local atok = profile.authTokenEnv and tostring(profile.authTokenEnv) or ""
    if atok:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      put("ANTHROPIC_AUTH_TOKEN", "$" .. atok, true)
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
  -- R1-34: dest is interpolated UNQUOTED into the spawn shell string in sshWrap
  -- (between `ssh -t` and the single-quoted inner). Validate host/user to a
  -- hostname/user charset and fail SAFE (nil) on anything else, so a host/user with
  -- shell metacharacters ($(...), backtick, ;, ") can't inject. This is the ONE
  -- place dest is built, so every consumer (sshWrap, spawnSpec, the kitty argv path,
  -- the bridge) is protected. nil aborts the spawn rather than running a bad command.
  local host = tostring(ssh.host)
  if not host:match("^[%w._%-]+$") then return nil end
  -- R2-24: the charset above ALLOWS dots, so "." / ".." / "a..b" pass -- but the
  -- bridge derives a mirror-dir name from the dest (sshHosts.ns), and
  -- `rsync -az --delete REMOTE:.claude/cc-status/ MIRROR_DIR/<ns>/` would then run
  -- --delete against a traversed path (e.g. ns=".." -> ~/.claude). Reject any
  -- dot-traversal component at this single chokepoint so no consumer can build one.
  if host == "." or host == ".." or host:find("%.%.") then return nil end
  if ssh.user and tostring(ssh.user) ~= "" then
    local user = tostring(ssh.user)
    if not user:match("^[%w._%-]+$") then return nil end
    if user == "." or user == ".." or user:find("%.%.") then return nil end
    return user .. "@" .. host
  end
  return host
end

function M.sshWrap(inner, ssh, env)
  local dest = M.sshDest(ssh)
  if not dest then return inner end
  local cmd = (ssh.tty == false) and "ssh" or "ssh -t"
  -- dest is now validated to a hostname/user charset in sshDest (returns nil on any
  -- shell metacharacter -> spawn aborts), so the unquoted interpolation here is safe.
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
      -- R2-24 defense-in-depth: even though sshDest now blocks dot-traversal at the
      -- source, skip any host whose derived ns is unsafe as a dir component, so a
      -- future ns-derivation change can't reintroduce a traversal into the rsync dir.
      local ns = dest and (dest:gsub("[^%w.-]", "_")) or nil
      if dest and not seen[dest]
         and ns ~= "" and ns ~= "." and ns ~= ".." and not ns:find("%.%.") then
        seen[dest] = true
        out[#out + 1] = {
          host = tostring(p.ssh.host),
          user = p.ssh.user and tostring(p.ssh.user) or nil,
          dest = dest,
          -- R1-25: namespace from DEST (user@host), not host alone. Two providers on
          -- one host with different users pass the dest-dedup (distinct dests) but
          -- would collide to one ns if derived from host only -- reconcileBridge keys
          -- want[ns]=h, so the second host would silently overwrite the first and
          -- never be bridged. dest is already validated to a safe charset by sshDest;
          -- "@" -> "_" keeps it a clean dir name + key prefix.
          ns = ns,
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
    if type(st) ~= "table" then return end
    if type(st.pending) == "table" and type(st.pending.nonce) == "string"
       and st.pending.nonce ~= "" then
      nonce = st.pending.nonce
    -- R1-36: fall back to the top-level gate_nonce when the parallel cc-status.sh hook
    -- cleared the pending block (and its nonce) in the same event. cc-approve writes
    -- both; gate_nonce survives a pending-clear so a same-second answer still binds.
    elseif type(st.gate_nonce) == "string" and st.gate_nonce ~= "" then
      nonce = st.gate_nonce
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
  -- R3-09: remote tiles permit ONLY headless approve/deny. There is no remote-keystroke
  -- transport (only the writeDecision allow/deny ssh path exists), and handleAction's
  -- R2-07 guard hard-refuses every non-approve/deny action for a remote tile -- so a
  -- keystrokes branch here advertised nudge/stop/clear/compact that the dispatcher would
  -- count + ledger as delivered while the remote session received nothing.
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

-- Pick the newest Claude Code EXTENSION dir from a VS Code/Cursor extensions
-- listing -- the fallback claude binary when no CLI is installed at all (the
-- extension bundles the full CLI at <dir>/resources/native-binary/claude).
-- Folder names are version-pinned ("anthropic.claude-code-2.1.173-darwin-arm64")
-- and lexicographic order lies (2.1.9 > 2.1.173), so compare numerically.
function M.newestClaudeExtension(dirNames)
  local best, bestV
  for _, n in ipairs(dirNames or {}) do
    local a, b, c = tostring(n):match("^anthropic%.claude%-code%-(%d+)%.(%d+)%.(%d+)")
    if a then
      local v = tonumber(a) * 1e8 + tonumber(b) * 1e4 + tonumber(c)
      if not bestV or v > bestV then best, bestV = n, v end
    end
  end
  return best
end

-- Quote a launch flag/value ONLY when it isn't already shell-safe, so existing
-- no-space flags (--permission-mode default, /abs/path) emit byte-identical to
-- before while value-bearing L1 flags (--append-system-prompt "<persona>") are
-- quoted for the shell sinks. The kitty path keeps flags RAW (argv elements, no
-- shell), so this is only used where a flag joins a shell command string.
local function shArg(s)
  s = tostring(s)
  if s:match("^[%w@%%+=:,./_-]+$") then return s end
  return shquote(s)
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
  for _, f in ipairs(opts.flags or {}) do inner = inner .. " " .. shArg(f) end
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
-- emitted. `--remote-control` (rc=true) starts the interactive session with Remote
-- Control registered (drive it from claude.ai / the Claude app) -- the documented,
-- reliable way to auto-enable RC on a Shepherd-spawned session (vs. typing /rc).
-- The model is NOT a flag here -- it rides ANTHROPIC_MODEL (providerEnv) so the
-- status hook can see it. Returns a flat argv-style list (possibly empty).
function M.spawnFlags(mode, effort, rc)  -- luacheck: ignore effort (reserved)
  local flags = {}
  if mode and tostring(mode) ~= "" then
    flags[#flags + 1] = "--permission-mode"
    flags[#flags + 1] = tostring(mode)
  end
  if rc == true then flags[#flags + 1] = "--remote-control" end
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
-- The `open(1)` argv tail for a VS Code / Cursor spawn. A brand-new project folder
-- (spec.coldStart) pops VS Code's Workspace Trust modal, which steals focus and
-- swallows the extension keystrokes that should start the session -- so for a cold
-- start we add `--disable-workspace-trust` to skip it for this launch. Pure.
function M.vscodeOpenArgs(spec)
  spec = spec or {}
  local args = { "-na", spec.app, "--args" }
  if spec.coldStart then args[#args + 1] = "--disable-workspace-trust" end
  args[#args + 1] = spec.project
  return args
end

function M.spawnSpec(editor, project, task, opts)
  opts = opts or {}
  editor = tostring(editor or ""):lower()
  task = (task and #task > 0) and task or nil
  local env = opts.env
  local ssh = opts.ssh
  local hasEnv = type(env) == "table" and #env > 0
  local isSsh = type(ssh) == "table" and ssh.host and tostring(ssh.host) ~= ""
  -- Remote Control rides the launch flag only for a LOCAL session (an ssh-remote box
  -- registers RC to its own claude.ai window, defeating the "window into my local
  -- session" model); the gateway/native gate is the caller's (FX.spawnSession).
  local flags = M.spawnFlags(opts.permissionMode, opts.effort, opts.remoteControl == true and not isSsh)
  -- L1 "spawn from a saved agent": append profile-derived flags (persona, MCP
  -- config, --agent, --add-dir knowledge, --plugin-dir). All optional -> a
  -- non-agent spawn is byte-identical (spawnExtraFlags returns {}).
  for _, f in ipairs(M.spawnExtraFlags(opts)) do flags[#flags + 1] = f end
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
      -- R3-02: compute the dest once and abort cleanly on nil. sshDest is a
      -- fail-CLOSED control (nil for a host/user with shell metacharacters or
      -- dot-traversal), but isSsh is gated only on a non-empty ssh.host. Assigning
      -- nil to argv[#argv+1] is a no-op in Lua, so without this guard the next
      -- assignment would write the inner remote command into the dest's slot and
      -- ssh would interpret it as the hostname -- silently dropping the dest and
      -- defeating the "nil aborts the spawn" contract.
      local dest = M.sshDest(ssh)
      if not dest then
        return { kind = "kitty", argv = nil, error = "invalid ssh dest" }
      end
      argv[#argv + 1] = "ssh"
      if ssh.tty ~= false then argv[#argv + 1] = "-t" end
      argv[#argv + 1] = dest
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
    -- Two best-effort keystroke flavors (no supported API; Kitty/Terminal stay
    -- the reliable spawns):
    --   "extension" (DEFAULT): ⌘Esc opens the Claude Code extension panel (the
    --     resume/new-session UI the operator works in); optional task typed
    --     into the focused Claude input.
    --   "terminal": new integrated terminal + typed launch line (embedding the
    --     resolved claude path -- the terminal's PATH often lacks `claude`).
    --     FORCED for ssh spawns (the extension can't run a remote claude) and
    --     provider env (ANTHROPIC_* can only ride the typed line).
    local app = (editor == "cursor") and "Cursor" or "Visual Studio Code"
    if not isSsh and not hasEnv and opts.vscodeFlavor ~= "terminal" then
      return { kind = "vscode", editor = editor, app = app, project = project,
               flavor = "extension", task = task, coldStart = opts.isNew == true }
    end
    local post
    if isSsh then
      post = M.spawnInner(project, task, { env = env, flags = flags, ssh = ssh })
    else
      post = M.envPrefix(env) .. claudeRef(opts.claudeBin)
      for _, f in ipairs(flags) do post = post .. " " .. shArg(f) end
      if task then post = post .. " " .. shquote(task) end
    end
    return { kind = "vscode", editor = editor, app = app, project = project,
             flavor = "terminal", openTerminalKey = { mods = { "ctrl" }, key = "`" },
             postType = post, coldStart = opts.isNew == true }
  end
  return { kind = "terminal",
           applescript = M.spawnAppleScript(project, task,
             { terminal = opts.terminal, env = env, flags = flags, ssh = ssh,
               claudeBin = opts.claudeBin }) }
end

-- One-line human description of a spawn spec, for dry-run logging (what
-- `spawn.live = false` prints instead of launching).
function M.describeSpec(spec)
  if type(spec) ~= "table" then return tostring(spec) end
  if spec.kind == "kitty" then return table.concat(spec.argv or {}, " ") end
  if spec.kind == "vscode" then
    if spec.flavor == "extension" then
      return "open " .. tostring(spec.app) .. " @ " .. tostring(spec.project)
        .. " + ⌘Esc (Claude Code extension)"
        .. (spec.task and (" + task: " .. spec.task) or "")
    end
    return "open " .. tostring(spec.app) .. " @ " .. tostring(spec.project)
      .. " + type: " .. tostring(spec.postType)
  end
  return tostring(spec.applescript)
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
  elseif action == "ls" then
    -- R1-15: liveness probe. `@ ls --match <sel>` lists matching windows as JSON;
    -- an empty/no-window result means the target window is gone, so a feed must NOT
    -- report delivered (the queued task would be popped + lost).
    argv[#argv + 1] = "ls"; argv[#argv + 1] = "--match"; argv[#argv + 1] = sel
  else
    return nil
  end
  return argv
end

-- R1-15: parse `kitty @ ls` JSON output and report whether ANY window is present
-- (the --match filter already narrows it to the target). Pure: the dashboard runs
-- the probe (FX) and passes the captured stdout here. A window has a numeric "id"
-- field; we only need to know the matched set is non-empty. Empty/garbage -> false
-- (fail-closed: treat an unparseable/empty probe as "window gone", keep the task).
function M.kittyWindowAlive(lsOutput)
  local s = tostring(lsOutput or "")
  if s:match("^%s*$") then return false end
  local ok, data = pcall(function() return M.json.decode(s) end)
  if not ok or type(data) ~= "table" then return false end
  -- kitty @ ls returns a JSON ARRAY of OS-windows, each with a "tabs" array of
  -- tabs, each with a "windows" array. With --match it still returns the nested
  -- shape but only including matching windows; the simplest robust signal is "is
  -- there at least one window object with an id anywhere in the tree".
  local function hasWindow(node)
    if type(node) ~= "table" then return false end
    -- a window object: has a numeric id and is inside a "windows" list
    for _, osw in ipairs(node) do
      if type(osw) == "table" then
        local tabs = osw.tabs
        if type(tabs) == "table" then
          for _, tab in ipairs(tabs) do
            local wins = type(tab) == "table" and tab.windows or nil
            if type(wins) == "table" and #wins > 0 then return true end
          end
        end
      end
    end
    return false
  end
  return hasWindow(data)
end

-- ---- Window focus matching (extracted from focusProject; review #4) --------
-- Generic path components that must never be used as a focus candidate (too
-- ambiguous -- they'd grab the wrong window).
M.FOCUS_SKIP = { users = true, programming = true, desktop = true, documents = true,
  projects = true, project = true, src = true, code = true, repos = true, repo = true,
  dev = true, home = true, [""] = true }

-- Rank a window title's folder segment (after the last em-dash) against a
-- focus candidate. VS Code titles are "<file> — <folder>"; matching the folder
-- avoids grabbing a window whose task title merely mentions the word.
--   2 = the segment IS the candidate (exact, trimmed)
--   1 = the segment merely CONTAINS it
--   nil = no match
-- The two tiers exist because prefix-named sibling projects collide under a
-- bare substring test (field-proven: "Dialer-info"'s Jump matched the
-- "… — Dialer-info-Five9" window, and the cwd-ancestor candidate "dialer"
-- matched "… — Dialer-scraper"). Callers must prefer rank 2 across ALL
-- windows before settling for a rank-1 contains-match (decorated titles like
-- "proj (Workspace)" still need the fallback) -- bestWindowFor below does that.
-- Case-insensitive on BOTH sides (self-contained: callers historically
-- pre-lowercased, but the function must not silently depend on it).
function M.titleFolderRank(title, needle)
  if not title or not needle or needle == "" then return nil end
  title = string.lower(title)
  needle = string.lower(needle)
  local seg = title:match(".*—%s*(.+)$") or title
  seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
  if seg == needle then return 2 end
  if seg:find(needle, 1, true) then return 1 end
  return nil
end

-- Boolean convenience over titleFolderRank (legacy shape).
function M.titleFolderMatch(title, needle)
  return M.titleFolderRank(title, needle) ~= nil
end

-- The cross-window preference: best-ranked title for a candidate over a whole
-- window list -- an exact (rank 2) ANYWHERE beats a contains (rank 1) seen
-- earlier. Returns index, rank; nil when nothing matches. focusProject feeds
-- it live window titles; pure here so the preference is pinned by tests.
function M.bestWindowFor(titles, needle)
  local best, bestRank
  for i, t in ipairs(titles or {}) do
    local r = M.titleFolderRank(t, needle)
    if r and (not bestRank or r > bestRank) then
      best, bestRank = i, r
      if r == 2 then break end  -- nothing beats exact
    end
  end
  return best, bestRank
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

-- Reverse window match: which session owns the window titled `title`? Used by the deck's
-- Voice key to route dictation to the project you're looking at. Scores every session's
-- focusCandidates against the title via bestWindowFor (exact folder segment beats contains)
-- and returns the best-ranked session, or nil if nothing matches. Pure; `user` is skipped
-- as a candidate (same as focusProject). Callers can pre-filter `list` by editor app.
function M.sessionForTitle(list, title, user)
  if type(title) ~= "string" or title == "" then return nil end
  local titles = { title }
  local best, bestRank = nil, 0
  for _, it in ipairs(list or {}) do
    if type(it) == "table" then
      for _, needle in ipairs(M.focusCandidates(it.name, it.cwd, user)) do
        local idx, rank = M.bestWindowFor(titles, needle)
        if idx and (rank or 0) > bestRank then best, bestRank = it, rank or 0 end
      end
    end
  end
  return best
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

-- Join a scanner argv into a `/bin/sh -c` command that REDIRECTS stdout to a file. Direct-exec
-- hs.task DEADLOCKS once a scan's stdout exceeds the OS pipe buffer (~64KB) over a large tree:
-- the task waits for the child to exit while the child blocks writing into a full pipe nobody
-- drains (the login-shell path already worked precisely because it reads to completion).
-- Redirecting to a file keeps the task's own stdout empty, so there's no pipe to stall. Every
-- argv element AND the outFile are POSIX single-quoted; stderr is discarded.
function M.folderScanShellCommand(argv, outFile)
  local parts = {}
  for _, a in ipairs(argv or {}) do parts[#parts + 1] = shquote(tostring(a)) end
  return table.concat(parts, " ") .. " > " .. shquote(tostring(outFile)) .. " 2>/dev/null"
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

-- ---- Saved task templates (roadmap #5c; L3 enriches) ------------------------
-- Operator data, stored OUTSIDE cc-config.json (a separate cc-templates.json,
-- like labels/recents) so the Settings overlay round-trip can never clobber it.
-- Back-compat record: { name, text }. L3 widens it (all but `name` optional):
--   { name, text?, description?, expected_output?, vars?, version?, versions?,
--     createdAt?, updatedAt? }
-- A STRUCTURED template composes its body from description (+ expected_output);
-- a LEGACY template keeps using `text` (the back-compat fallback). Body vars are
-- {{name}} (required) / {{name?}} (optional) placeholders, plus the built-ins
-- date/today/now/prev_output (auto-filled at render time). The validate ->
-- fail-safe load -> list family mirrors the L1 agent registry (~3877) so a bad
-- record is dropped (with a reason) instead of breaking the whole file.
M.TEMPLATE_CAP = 50
M.TEMPLATE_VERSION_CAP = 20

-- Built-in interpolation vars: auto-filled at render time, never prompted for.
M.TEMPLATE_BUILTINS = { date = true, today = true, now = true, prev_output = true }
function M.isBuiltinVar(name) return M.TEMPLATE_BUILTINS[tostring(name or "")] == true end

-- Known record fields. Unknown keys are FLAGGED by validateTemplate (a typo'd key
-- is a dead no-op otherwise) and drop the record at load -- same posture as agents.
M.TEMPLATE_FIELDS = { name = true, text = true, description = true,
  expected_output = true, vars = true, version = true, versions = true,
  createdAt = true, updatedAt = true }

local function tplTrim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function tplStr(x) return type(x) == "string" and x or nil end

local function ttpl(state)
  if type(state) == "table" and type(state.templates) == "table" then return state.templates end
  return {}
end

-- Normalize the optional vars schema into a list of {name, required, label?,
-- default?}. Accepts bare strings (name only, required) or objects; drops entries
-- without a usable name, dedupes by name (first wins).
local function tplVarSchema(v)
  local out, seen = {}, {}
  if type(v) ~= "table" then return out end
  for _, item in ipairs(v) do
    local name, required, label, default
    if type(item) == "string" then
      name, required = tplTrim(item), true
    elseif type(item) == "table" then
      name = tplTrim(item.name)
      required = item.required ~= false
      label = (type(item.label) == "string" and item.label ~= "") and item.label or nil
      default = (type(item.default) == "string") and item.default or nil
    end
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, required = required, label = label, default = default }
    end
  end
  return out
end

-- Pre-flight validator (L3): returns { ok, errors[] } collecting ALL problems.
-- A valid record has a non-blank name and at least one of text/description.
function M.validateTemplate(rec)
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if tplTrim(rec.name) == "" then errs[#errs + 1] = "missing required field: name" end
  for _, f in ipairs({ "text", "description", "expected_output" }) do
    if rec[f] ~= nil and type(rec[f]) ~= "string" then errs[#errs + 1] = f .. " must be a string" end
  end
  if rec.vars ~= nil and type(rec.vars) ~= "table" then errs[#errs + 1] = "vars must be a list" end
  if rec.versions ~= nil and type(rec.versions) ~= "table" then errs[#errs + 1] = "versions must be a list" end
  if rec.version ~= nil and type(rec.version) ~= "number" then errs[#errs + 1] = "version must be a number" end
  if tplTrim(rec.text) == "" and tplTrim(rec.description) == "" then
    errs[#errs + 1] = "needs text or description"
  end
  for k in pairs(rec) do
    if not M.TEMPLATE_FIELDS[k] then errs[#errs + 1] = "unknown field: " .. tostring(k) end
  end
  return { ok = #errs == 0, errors = errs }
end

-- Normalize a record to the canonical shape (absent fields stay absent, so a
-- legacy {name, text} round-trips byte-identically).
local function tplNorm(rec)
  local versions
  if type(rec.versions) == "table" then
    versions = {}
    for _, s in ipairs(rec.versions) do
      if type(s) == "table" then
        versions[#versions + 1] = {
          version = tonumber(s.version), ts = tonumber(s.ts),
          text = tplStr(s.text), description = tplStr(s.description),
          expected_output = tplStr(s.expected_output),
          vars = s.vars ~= nil and tplVarSchema(s.vars) or nil,
        }
      end
    end
  end
  return {
    name = tplTrim(rec.name),
    text = tplStr(rec.text),
    description = tplStr(rec.description),
    expected_output = tplStr(rec.expected_output),
    vars = rec.vars ~= nil and tplVarSchema(rec.vars) or nil,
    version = tonumber(rec.version),
    versions = versions,
    createdAt = tonumber(rec.createdAt),
    updatedAt = tonumber(rec.updatedAt),
  }
end

-- Fail-safe load (mirrors agentLoad): validate each record, keep the valid
-- (normalized), DROP only the bad, and RETURN the dropped names+reasons so the FX
-- glue can surface them once. Duplicates keep the first. Returns {valid, errors}.
function M.templateLoad(state)
  local valid, errors, seen = {}, {}, {}
  for _, rec in ipairs(ttpl(state)) do
    local v = M.validateTemplate(rec)
    local nm = (type(rec) == "table") and tplTrim(rec.name) or ""
    if not v.ok then
      errors[#errors + 1] = { name = nm ~= "" and nm or "(unnamed)",
                              reason = table.concat(v.errors, "; ") }
    elseif seen[nm] then
      errors[#errors + 1] = { name = nm, reason = "duplicate name (kept first)" }
    else
      seen[nm] = true; valid[#valid + 1] = tplNorm(rec)
    end
  end
  return { valid = valid, errors = errors }
end

-- Clean list (common path): all valid, normalized records.
function M.templateList(state) return M.templateLoad(state).valid end

-- The renderable body for a record: STRUCTURED (description, then an "Expected
-- output:" block when set) once a description is present, else the legacy `text`.
-- Returns nil for a nil/contentless record.
function M.composeTemplate(rec)
  if type(rec) ~= "table" then return nil end
  if tplTrim(rec.description) ~= "" then
    local body = rec.description
    if tplTrim(rec.expected_output) ~= "" then
      body = body .. "\n\nExpected output:\n" .. rec.expected_output
    end
    return body
  end
  if type(rec.text) == "string" and rec.text ~= "" then return rec.text end
  return nil
end

-- The full normalized record for a name, or nil.
function M.templateGetRecord(state, name)
  for _, t in ipairs(M.templateList(state)) do
    if t.name == name then return t end
  end
  return nil
end

-- Renderable body for a named template, or nil. (Back-compat: legacy `text`.)
function M.templateGet(state, name)
  return M.composeTemplate(M.templateGetRecord(state, name))
end

-- Structured upsert: validate, replace same-name IN PLACE / prepend, cap. Returns
-- newState, saved, errors. Pure (no clock; versioning/timestamps belong to
-- templatePushVersioned).
function M.templatePushRecord(state, rec, cap)
  cap = tonumber(cap) or M.TEMPLATE_CAP
  local list = M.templateList(state)
  rec = type(rec) == "table" and rec or {}
  local v = M.validateTemplate(rec)
  if not v.ok then return { templates = list }, false, v.errors end
  local entry = tplNorm(rec)
  local out, replaced = {}, false
  for _, t in ipairs(list) do
    if t.name == entry.name then out[#out + 1] = entry; replaced = true
    else out[#out + 1] = t end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { templates = out }, true
end

-- Back-compat save: trim name+text, reject blanks, replace in place / prepend,
-- cap. Delegates to templatePushRecord. Returns newState, saved.
function M.templatePush(state, name, text, cap)
  local st, saved = M.templatePushRecord(state, { name = tplTrim(name), text = tplTrim(text) }, cap)
  return st, saved
end

-- Delete by name (no-op copy on miss).
function M.templateRemove(state, name)
  local out = {}
  for _, t in ipairs(M.templateList(state)) do
    if t.name ~= name then out[#out + 1] = t end
  end
  return { templates = out }
end

-- Rename a template, PRESERVING its full record incl. version history (so the
-- editor's rename can't drop it the way delete+re-add would). A same-newName
-- record is dropped (overwrite -- the caller confirms first). No-op if oldName
-- is missing or newName is blank. Returns newState, ok.
function M.templateRename(state, oldName, newName)
  local rec = M.templateGetRecord(state, oldName)
  newName = tplTrim(newName)
  if not rec or newName == "" or newName == oldName then return state, false end
  local out = {}
  for _, t in ipairs(M.templateList(state)) do
    if t.name == oldName then
      local c = {}; for k, v in pairs(t) do c[k] = v end
      c.name = newName
      out[#out + 1] = c
    elseif t.name ~= newName then  -- overwrite any same-newName record
      out[#out + 1] = t
    end
  end
  return { templates = out }, true
end

-- Content signature (what defines an "edit"): the COMPOSED body -- so a change to
-- a field composeTemplate shadows (e.g. `text` when a description is set, or
-- expected_output with no description) is correctly a no-op, since the rendered
-- result is unchanged -- plus the vars schema. Trimmed, so a whitespace-only edit
-- is a no-op too. Used to skip a redundant version bump.
local function tplContentSig(rec)
  local parts = { tplTrim(M.composeTemplate(rec) or "") }
  for _, vv in ipairs(tplVarSchema(rec.vars)) do
    parts[#parts + 1] = vv.name .. "\1" .. (vv.required and "1" or "0") ..
      "\1" .. (vv.default or "") .. "\1" .. (vv.label or "")
  end
  return table.concat(parts, "\2")
end

-- Versioned upsert (duplicate-on-edit): on a real content change to an EXISTING
-- template, snapshot the previous head into versions[] (capped at versionCap) and
-- bump `version`, instead of overwriting. A new template starts at version 1; an
-- unchanged push is a no-op (no version churn). Timestamps come from opts.now
-- (injected -> pure). opts = {cap, versionCap, now}. Returns newState, saved, errors.
function M.templatePushVersioned(state, rec, opts)
  opts = type(opts) == "table" and opts or {}
  local now = tonumber(opts.now)
  local vcap = tonumber(opts.versionCap) or M.TEMPLATE_VERSION_CAP
  rec = type(rec) == "table" and rec or {}
  local v = M.validateTemplate(rec)
  if not v.ok then return { templates = M.templateList(state) }, false, v.errors end
  local entry = tplNorm(rec)
  local prev = M.templateGetRecord(state, entry.name)
  if prev and tplContentSig(prev) == tplContentSig(entry) then
    return { templates = M.templateList(state) }, true  -- unchanged: no churn
  end
  if prev then
    local snap = { version = prev.version or 1, ts = prev.updatedAt or now,
      text = prev.text, description = prev.description,
      expected_output = prev.expected_output, vars = prev.vars }
    local hist = { snap }
    for _, s in ipairs(prev.versions or {}) do hist[#hist + 1] = s end
    while #hist > vcap do table.remove(hist) end
    entry.versions = hist
    entry.version = (prev.version or 1) + 1
    entry.createdAt = prev.createdAt or now
    entry.updatedAt = now
  else
    entry.versions = {}
    entry.version = 1
    entry.createdAt = now
    entry.updatedAt = now
  end
  return M.templatePushRecord(state, entry, tonumber(opts.cap) or M.TEMPLATE_CAP)
end

-- Version history for the revert view: the current head first (current=true), then
-- prior snapshots, all newest-first. Empty list for an unknown template.
function M.templateVersions(state, name)
  local rec = M.templateGetRecord(state, name)
  if not rec then return {} end
  local out = { { version = rec.version or 1, ts = rec.updatedAt,
    text = rec.text, description = rec.description,
    expected_output = rec.expected_output, current = true } }
  for _, s in ipairs(rec.versions or {}) do
    out[#out + 1] = { version = s.version, ts = s.ts, text = s.text,
      description = s.description, expected_output = s.expected_output, current = false }
  end
  return out
end

-- Revert a template to a prior version: NON-DESTRUCTIVE -- snapshots the current
-- head and bumps version forward (via templatePushVersioned) with the chosen
-- version's content. Returns newState, ok. Unknown name/version -> no-op.
function M.templateRevert(state, name, version, opts)
  local rec = M.templateGetRecord(state, name)
  if not rec then return state, false end
  version = tonumber(version)
  local target
  if version == (rec.version or 1) then
    target = rec
  else
    for _, s in ipairs(rec.versions or {}) do
      if tonumber(s.version) == version then target = s; break end
    end
  end
  if not target then return state, false end
  local st, saved = M.templatePushVersioned(state,
    { name = name, text = target.text, description = target.description,
      expected_output = target.expected_output, vars = target.vars }, opts)
  return st, saved == true
end

-- Ordered, deduped list of USER-facing placeholders in `text`: {{name}} (required)
-- / {{name?}} (optional). Built-ins (date/today/now/prev_output) are excluded --
-- they auto-fill at render time. A name is required unless EVERY occurrence is
-- marked optional. Returns { {name, required}, ... }.
function M.templateVars(text)
  text = type(text) == "string" and text or ""
  local order, req = {}, {}
  for name, opt in text:gmatch("{{%s*([%w_%.%-]+)%s*(%??)%s*}}") do
    if not M.isBuiltinVar(name) then
      local isReq = (opt ~= "?")
      if req[name] == nil then order[#order + 1] = name; req[name] = isReq
      else req[name] = req[name] or isReq end
    end
  end
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = { name = name, required = req[name] } end
  return out
end

-- Interpolate {{name}} / {{name?}} placeholders + the built-ins. `vars` is a
-- name->value map; `opts` carries {now=<epoch>, prevOutput=<string>} for the
-- built-ins. Returns (rendered, missing[]): a missing REQUIRED var (no value at a
-- non-optional occurrence) REFUSES the render -> (nil, {names...}); an optional
-- placeholder blanks out; built-ins resolve from opts (an absent clock -> blank
-- date). With opts.keepMissing=true (the AUTONOMOUS feed path -- no human to
-- prompt), a missing required var is LEFT VERBATIM instead, and the render never
-- refuses: only built-ins + {{prev_output}} + supplied vars resolve, so a queued
-- task with no placeholders is returned unchanged. Pure (clock injected).
function M.renderTemplate(text, vars, opts)
  text = type(text) == "string" and text or ""
  vars = type(vars) == "table" and vars or {}
  opts = type(opts) == "table" and opts or {}
  local now = tonumber(opts.now)
  local keep = opts.keepMissing == true
  local prevOut = type(opts.prevOutput) == "string" and opts.prevOutput or ""
  local missing, seenMissing = {}, {}
  local function dateFmt(fmt) return now and os.date(fmt, now) or "" end
  local rendered = text:gsub("{{%s*([%w_%.%-]+)%s*(%??)%s*}}", function(name, opt)
    if name == "date" or name == "today" then return dateFmt("%Y-%m-%d") end
    if name == "now" then return dateFmt("%Y-%m-%d %H:%M") end
    if name == "prev_output" then return prevOut end
    local val = vars[name]
    if val ~= nil then val = tostring(val) end
    if val ~= nil and tplTrim(val) ~= "" then return val end
    if opt == "?" then return "" end
    if keep then return nil end  -- leave the placeholder verbatim; never refuse
    if not seenMissing[name] then seenMissing[name] = true; missing[#missing + 1] = name end
    return ""
  end)
  if #missing > 0 then return nil, missing end
  return rendered, {}
end

-- The effective var list for a record: the declared schema (in order, with its
-- required/label/default metadata) first, then any placeholders parsed from the
-- composed body that the schema didn't declare. Feeds the New-Session var grid.
function M.effectiveVars(rec)
  if type(rec) ~= "table" then return {} end
  local out, seen = {}, {}
  for _, d in ipairs(tplVarSchema(rec.vars)) do
    if not seen[d.name] then
      seen[d.name] = true
      out[#out + 1] = { name = d.name, required = d.required, label = d.label, default = d.default }
    end
  end
  for _, p in ipairs(M.templateVars(M.composeTemplate(rec) or "")) do
    if not seen[p.name] then
      seen[p.name] = true
      out[#out + 1] = { name = p.name, required = p.required }
    end
  end
  return out
end

-- Fill missing/blank var values from the schema's defaults. Pure; new map.
function M.fillDefaults(schema, vars)
  local out = {}
  if type(vars) == "table" then for k, vv in pairs(vars) do out[k] = vv end end
  for _, d in ipairs(type(schema) == "table" and schema or {}) do
    if type(d) == "table" and type(d.name) == "string" and d.default ~= nil then
      local cur = out[d.name]
      if cur == nil or tplTrim(cur) == "" then out[d.name] = d.default end
    end
  end
  return out
end

-- Parse a .prompt / .md prompt definition into a template record. Strips an
-- optional leading `---`...`---` frontmatter (reads `name`); the body after it is
-- the prompt text, which may carry {{vars}}. Name falls back to the file stem. No
-- YAML/Jinja -- just frontmatter + body, like parseSkillFrontmatter. Pure (runs on
-- text the FX layer reads); validate the result before storing.
function M.parsePromptFile(text, stem)
  text = tostring(text or "")
  local name = tplTrim(stem)
  local body = text
  local fm, rest = text:match("^%s*%-%-%-%s*\n(.-)\n%s*%-%-%-%s*\n?(.*)$")
  if fm then
    body = rest
    for line in (fm .. "\n"):gmatch("(.-)\n") do
      local k, v = line:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
      if k and k:lower() == "name" then
        v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        if tplTrim(v) ~= "" then name = tplTrim(v) end
      end
    end
  end
  return { name = name, text = tplTrim(body) }
end

-- Import parsed prompt-definition files into the template store (versioned, so a
-- re-import snapshots the prior body). `files` = { {stem, text}, ... } the FX layer
-- read from the definitions dir. Returns newState, summary{imported, skipped,
-- names[], errors[]}. Pure (clock via opts.now).
function M.promptImport(state, files, opts)
  opts = type(opts) == "table" and opts or {}
  local summary = { imported = 0, skipped = 0, names = {}, errors = {} }
  local st = state
  for _, f in ipairs(type(files) == "table" and files or {}) do
    local rec = M.parsePromptFile(type(f) == "table" and f.text or "",
                                  type(f) == "table" and f.stem or "")
    local v = M.validateTemplate(rec)
    if not v.ok then
      summary.skipped = summary.skipped + 1
      summary.errors[#summary.errors + 1] = {
        name = rec.name ~= "" and rec.name or "(unnamed)",
        reason = table.concat(v.errors, "; ") }
    else
      local nst, saved = M.templatePushVersioned(st, rec, opts)
      st = nst
      if saved then
        summary.imported = summary.imported + 1
        summary.names[#summary.names + 1] = rec.name
      else
        summary.skipped = summary.skipped + 1
      end
    end
  end
  return st, summary
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

-- Full path for a new project under `parent`, or nil, reason when rejected
-- (unsafe name / non-absolute parent). The REASON comes from here -- the one
-- place that runs the checks -- so the UI's rejection alert can never disagree
-- with the check that actually fired (re-deriving it at the call site
-- mislabels any future rejection path). A relative parent is never right:
-- mkdir would resolve it against Hammerspoon's process cwd while the spawned
-- shell's `cd` resolves it against $HOME -- folder created one place, session
-- elsewhere.
function M.newProjectPath(parent, name)
  local safe = M.safeFolderName(name)
  if not safe then
    return nil, "project name " .. string.format("%q", tostring(name or ""))
      .. " is empty or has unsupported characters (letters/digits/-_. and spaces only)"
  end
  if M.normDir(parent):sub(1, 1) ~= "/" then
    return nil, "parent folder " .. string.format("%q", tostring(parent or ""))
      .. " must be an absolute path — pick a suggestion, a Recent chip, or Browse to it"
  end
  return M.pathJoin(parent, safe)
end

-- ===========================================================================
-- L1 — Agent Profiles registry + "spawn from a saved agent"
-- ===========================================================================
-- A saved agent profile extends a spawn preset with a persona + capability
-- refs. Stored in cc-agents.json (operator data, same posture as cc-presets).
-- DECLARATIVE: Shepherd only emits launch flags/files; native Claude Code owns
-- the actual agent/skill/MCP execution. Profile shape (all but `name` optional):
--   { name, folder, provider, model, permMode, seedPrompt, role, goal, backstory,
--     skills[], mcpServers[], knowledge[], plugins[], policyBundle, requiredEnv[],
--     folderGlobs[], modelByMode, category, favorite, hidden, archived, deleted,
--     forkedFrom, lastSpawnedAt, versions[] }
-- MCP registry lives in cc-mcp.json: { servers = { {id, label, transport, command,
--   args[], url, allowedTools[], authTokenEnv, description}, ... } }.
M.AGENT_CAP = 50
M.MCP_CAP = 30

local function agTrim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
-- Normalize an optional array-of-strings field: drop non-strings/blanks, dedupe.
local function agStrList(v)
  local out, seen = {}, {}
  if type(v) == "table" then
    for _, x in ipairs(v) do
      if type(x) == "string" then
        local s = agTrim(x)
        if s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end
      end
    end
  end
  return out
end
local function aglist(state)
  if type(state) == "table" and type(state.agents) == "table" then return state.agents end
  return {}
end

-- Known top-level profile fields. Unknown keys are FLAGGED by validateAgent (a
-- typo'd key is a dead no-op otherwise) but don't block loading on their own.
M.AGENT_FIELDS = { name = true, folder = true, provider = true, model = true,
  permMode = true, seedPrompt = true, role = true, goal = true, backstory = true,
  skills = true, mcpServers = true, knowledge = true, plugins = true,
  policyBundle = true, requiredEnv = true, folderGlobs = true, modelByMode = true,
  agentName = true, category = true, favorite = true, hidden = true, archived = true,
  deleted = true, forkedFrom = true, lastSpawnedAt = true, versions = true }

-- Pre-flight validator (L1): returns { ok, errors[] } collecting ALL problems.
-- `refs` (optional) enables cross-reference checks: { providers=set, bundles=set,
-- skills=set, mcp=set } — pass nil/{} at load time (cross-refs are a spawn-time
-- concern, not a reason to drop a stored record).
function M.validateAgent(rec, refs)
  refs = refs or {}
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if agTrim(rec.name) == "" then errs[#errs + 1] = "missing required field: name" end
  if rec.folder ~= nil and not (type(rec.folder) == "string" and rec.folder:sub(1, 1) == "/") then
    errs[#errs + 1] = "folder must be an absolute path"
  end
  for _, f in ipairs({ "skills", "mcpServers", "knowledge", "plugins", "requiredEnv",
                       "folderGlobs", "versions" }) do
    if rec[f] ~= nil and type(rec[f]) ~= "table" then errs[#errs + 1] = f .. " must be a list" end
  end
  for k in pairs(rec) do
    if not M.AGENT_FIELDS[k] then errs[#errs + 1] = "unknown field: " .. tostring(k) end
  end
  if refs.providers and agTrim(rec.provider) ~= "" and not refs.providers[tostring(rec.provider)] then
    errs[#errs + 1] = "provider not found: " .. tostring(rec.provider)
  end
  if refs.bundles and agTrim(rec.policyBundle) ~= "" and not refs.bundles[tostring(rec.policyBundle)] then
    errs[#errs + 1] = "policy bundle not found: " .. tostring(rec.policyBundle)
  end
  if refs.mcp then
    for _, id in ipairs(agStrList(rec.mcpServers)) do
      if not refs.mcp[id] then errs[#errs + 1] = "MCP server not found: " .. id end
    end
  end
  if refs.skills then
    for _, s in ipairs(agStrList(rec.skills)) do
      if not refs.skills[s] then errs[#errs + 1] = "skill not found: " .. s end
    end
  end
  return { ok = #errs == 0, errors = errs }
end

local function agNorm(rec)
  return {
    name = agTrim(rec.name),
    folder = (type(rec.folder) == "string" and rec.folder:sub(1, 1) == "/") and M.normDir(rec.folder) or nil,
    provider = rec.provider, model = rec.model, permMode = rec.permMode,
    seedPrompt = rec.seedPrompt, role = rec.role, goal = rec.goal, backstory = rec.backstory,
    skills = agStrList(rec.skills), mcpServers = agStrList(rec.mcpServers),
    knowledge = agStrList(rec.knowledge), plugins = agStrList(rec.plugins),
    policyBundle = rec.policyBundle,
    requiredEnv = type(rec.requiredEnv) == "table" and rec.requiredEnv or nil,
    folderGlobs = agStrList(rec.folderGlobs),
    modelByMode = type(rec.modelByMode) == "table" and rec.modelByMode or nil,
    agentName = rec.agentName, category = rec.category, favorite = rec.favorite == true,
    hidden = rec.hidden == true, archived = rec.archived == true, deleted = rec.deleted == true,
    forkedFrom = rec.forkedFrom, lastSpawnedAt = rec.lastSpawnedAt,
    versions = type(rec.versions) == "table" and rec.versions or nil,
  }
end

-- Load the registry with the fail-safe discipline (cline/AutoGPT enrichment):
-- validate EACH record, keep the valid (normalized), DROP only the bad, and
-- RETURN the dropped names+reasons so the FX glue can surface them once (instead
-- of presetList's silent drop). Duplicates keep the first. Returns {valid, errors}.
function M.agentLoad(state)
  local valid, errors, seen = {}, {}, {}
  for _, rec in ipairs(aglist(state)) do
    local v = M.validateAgent(rec, {})
    local nm = (type(rec) == "table") and agTrim(rec.name) or ""
    if not v.ok then
      errors[#errors + 1] = { name = nm ~= "" and nm or "(unnamed)",
                              reason = table.concat(v.errors, "; ") }
    elseif seen[nm] then
      errors[#errors + 1] = { name = nm, reason = "duplicate name (kept first)" }
    else
      seen[nm] = true; valid[#valid + 1] = agNorm(rec)
    end
  end
  return { valid = valid, errors = errors }
end

-- Clean list (common path) — all valid records incl. hidden/archived/deleted
-- (the UI filters those for the spawn picker; the registry view shows them).
function M.agentList(state) return M.agentLoad(state).valid end

-- Strict save: reject an invalid profile (returns state-unchanged + false +
-- errors), else replace same-name in place / prepend, capped. Mirrors presetPush.
function M.agentPush(state, profile, cap)
  cap = tonumber(cap) or M.AGENT_CAP
  local list = M.agentList(state)
  profile = type(profile) == "table" and profile or {}
  local v = M.validateAgent(profile, {})
  if not v.ok then return { agents = list }, false, v.errors end
  local entry = agNorm(profile)
  local out, replaced = {}, false
  for _, p in ipairs(list) do
    if p.name == entry.name then out[#out + 1] = entry; replaced = true
    else out[#out + 1] = p end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { agents = out }, true
end

function M.agentRemove(state, name)
  local out = {}
  for _, p in ipairs(M.agentList(state)) do
    if p.name ~= name then out[#out + 1] = p end
  end
  return { agents = out }
end

function M.agentGet(state, name)
  for _, p in ipairs(M.agentList(state)) do
    if p.name == name then return p end
  end
  return nil
end

-- Fork/duplicate with lineage: deep-copies the named profile to a unique
-- "<name> (copy)[ N]", stamps forkedFrom, clears favorite. No secret-strip needed
-- (only env-var NAMES are ever stored). Returns newState, ok.
function M.agentFork(state, name)
  local src = M.agentGet(state, name)
  if not src then return state, false end
  local copy = {}
  for k, vv in pairs(src) do copy[k] = vv end
  local base = src.name .. " (copy)"
  local nm, n = base, 2
  while M.agentGet(state, nm) do nm = base .. " " .. n; n = n + 1 end
  copy.name = nm; copy.forkedFrom = src.name; copy.favorite = false
  local st = M.agentPush(state, copy)
  return st, true
end

-- Bounded sort for the registry list. key in {name, favorite, lastUsed, updated}.
function M.agentSort(list, key)
  local out = {}
  for _, p in ipairs(list or {}) do out[#out + 1] = p end
  local k = tostring(key or "name")
  local function lc(s) return tostring(s or ""):lower() end
  table.sort(out, function(a, b)
    if k == "favorite" then
      local fa, fb = a.favorite and 1 or 0, b.favorite and 1 or 0
      if fa ~= fb then return fa > fb end
      return lc(a.name) < lc(b.name)
    elseif k == "lastUsed" then
      local la, lb = tonumber(a.lastSpawnedAt) or 0, tonumber(b.lastSpawnedAt) or 0
      if la ~= lb then return la > lb end
      return lc(a.name) < lc(b.name)
    end
    return lc(a.name) < lc(b.name)
  end)
  return out
end

-- The management flags the registry UI toggles per agent.
M.AGENT_FLAGS = { favorite = true, hidden = true, archived = true, deleted = true }

-- Toggle a boolean management flag (favorite/hidden/archived/deleted) on an agent,
-- preserving EVERY other field (operates on RAW state, like scheduleSetEnabled) so
-- a flag flip can't drop the profile's skills/mcp/knowledge/etc. Unknown flag or
-- missing name -> unchanged copy. Pure.
function M.agentSetFlag(state, name, flag, value)
  local out, target, fl = {}, agTrim(name), tostring(flag)
  for _, p in ipairs(aglist(state)) do
    if type(p) == "table" and agTrim(p.name) == target and M.AGENT_FLAGS[fl] then
      local c = {}; for k, v in pairs(p) do c[k] = v end
      c[fl] = value == true
      out[#out + 1] = c
    else
      out[#out + 1] = p
    end
  end
  return { agents = out }
end

-- ---- MCP server registry (cc-mcp.json) -------------------------------------
M.MCP_TRANSPORTS = { stdio = true, sse = true, http = true }
local function mcplist(state)
  if type(state) == "table" and type(state.servers) == "table" then return state.servers end
  return {}
end

function M.validateMcp(rec)
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if agTrim(rec.id) == "" then errs[#errs + 1] = "missing required field: id" end
  local tr = agTrim(rec.transport):lower()
  if not M.MCP_TRANSPORTS[tr] then
    errs[#errs + 1] = "transport must be stdio|sse|http"
  elseif tr == "stdio" then
    if agTrim(rec.command) == "" then errs[#errs + 1] = "stdio transport needs a command" end
  else
    if agTrim(rec.url) == "" then errs[#errs + 1] = tr .. " transport needs a url" end
  end
  return { ok = #errs == 0, errors = errs }
end

local function mcNorm(rec)
  return { id = agTrim(rec.id), label = rec.label, transport = agTrim(rec.transport):lower(),
           command = rec.command, args = agStrList(rec.args), url = rec.url,
           allowedTools = agStrList(rec.allowedTools), authTokenEnv = rec.authTokenEnv,
           description = rec.description }
end

function M.mcpLoad(state)
  local valid, errors, seen = {}, {}, {}
  for _, rec in ipairs(mcplist(state)) do
    local v = M.validateMcp(rec)
    local id = (type(rec) == "table") and agTrim(rec.id) or ""
    if not v.ok then
      errors[#errors + 1] = { id = id ~= "" and id or "(no id)",
                              reason = table.concat(v.errors, "; ") }
    elseif seen[id] then
      errors[#errors + 1] = { id = id, reason = "duplicate id (kept first)" }
    else
      seen[id] = true; valid[#valid + 1] = mcNorm(rec)
    end
  end
  return { valid = valid, errors = errors }
end

function M.mcpList(state) return M.mcpLoad(state).valid end

function M.mcpPush(state, rec, cap)
  cap = tonumber(cap) or M.MCP_CAP
  local list = M.mcpList(state)
  rec = type(rec) == "table" and rec or {}
  local v = M.validateMcp(rec)
  if not v.ok then return { servers = list }, false, v.errors end
  local entry = mcNorm(rec)
  local out, replaced = {}, false
  for _, s in ipairs(list) do
    if s.id == entry.id then out[#out + 1] = entry; replaced = true
    else out[#out + 1] = s end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { servers = out }, true
end

function M.mcpRemove(state, id)
  local out = {}
  for _, s in ipairs(M.mcpList(state)) do
    if s.id ~= id then out[#out + 1] = s end
  end
  return { servers = out }
end

function M.mcpGet(state, id)
  for _, s in ipairs(M.mcpList(state)) do
    if s.id == id then return s end
  end
  return nil
end

-- Build the claude `--mcp-config` object from resolved MCP records. stdio ->
-- {command,args,env?}; sse/http -> {type,url,headers?}. Secrets ride as ${VAR}
-- refs (Claude Code expands them at launch) — Shepherd never stores the value.
function M.mcpConfig(servers)
  local mcp = {}
  for _, s in ipairs(servers or {}) do
    local id = agTrim(s.id)
    if id ~= "" then
      local tr = agTrim(s.transport):lower()
      -- R1-11: authTokenEnv names an env var expanded as ${...} into an MCP env key /
      -- Bearer header. Constrain to a POSIX shell identifier (the only valid var-name
      -- charset) so a crafted name can't inject; a non-matching name drops the token.
      local atok = s.authTokenEnv and agTrim(s.authTokenEnv) or ""
      local hasTok = atok:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
      if tr == "stdio" then
        local e = { command = s.command, args = agStrList(s.args) }
        if hasTok then e.env = { [atok] = "${" .. atok .. "}" } end
        mcp[id] = e
      elseif tr == "sse" or tr == "http" then
        local e = { type = tr, url = s.url }
        if hasTok then e.headers = { Authorization = "Bearer ${" .. atok .. "}" } end
        mcp[id] = e
      end
    end
  end
  return { mcpServers = mcp }
end

-- Compose a profile's persona (role/goal/backstory) for --append-system-prompt.
-- nil when there are no persona fields (so the spawn stays byte-identical).
function M.personaPrompt(profile)
  if type(profile) ~= "table" then return nil end
  local parts = {}
  local role, goal, back = agTrim(profile.role), agTrim(profile.goal), agTrim(profile.backstory)
  if role ~= "" then parts[#parts + 1] = "You are " .. role .. "." end
  if goal ~= "" then parts[#parts + 1] = "Your goal: " .. goal end
  if back ~= "" then parts[#parts + 1] = back end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n")
end

-- Which required env-var NAMES are unset/blank in the spawned shell env.
-- requiredEnv: list of { name, required? } or bare strings (required by default).
function M.missingEnv(profile, shellEnv)
  shellEnv = type(shellEnv) == "table" and shellEnv or {}
  local missing = {}
  local req = (type(profile) == "table") and profile.requiredEnv or nil
  for _, e in ipairs(type(req) == "table" and req or {}) do
    local name = (type(e) == "table") and agTrim(e.name) or agTrim(e)
    local isReq = (type(e) ~= "table") or (e.required ~= false)
    if name ~= "" and isReq then
      local val = shellEnv[name]
      if val == nil or tostring(val) == "" then missing[#missing + 1] = name end
    end
  end
  return missing
end

-- Profile-derived launch flags (L1), appended after the base spawnFlags inside
-- spawnSpec. All optional -> {} (a non-agent spawn is byte-identical). The shell
-- sinks shArg-quote value-bearing flags; the kitty argv path keeps them raw.
-- opts: { appendSystemPrompt, mcpConfigPath, strictMcp, agentName, addDirs[], pluginDirs[] }
function M.spawnExtraFlags(opts)
  opts = opts or {}
  local f = {}
  if opts.appendSystemPrompt and agTrim(opts.appendSystemPrompt) ~= "" then
    f[#f + 1] = "--append-system-prompt"; f[#f + 1] = tostring(opts.appendSystemPrompt)
  end
  if opts.mcpConfigPath and agTrim(opts.mcpConfigPath) ~= "" then
    f[#f + 1] = "--mcp-config"; f[#f + 1] = tostring(opts.mcpConfigPath)
    if opts.strictMcp then f[#f + 1] = "--strict-mcp-config" end
  end
  if opts.agentName and agTrim(opts.agentName) ~= "" then
    f[#f + 1] = "--agent"; f[#f + 1] = tostring(opts.agentName)
  end
  for _, d in ipairs(opts.addDirs or {}) do
    if agTrim(d) ~= "" then f[#f + 1] = "--add-dir"; f[#f + 1] = tostring(d) end
  end
  for _, p in ipairs(opts.pluginDirs or {}) do
    if agTrim(p) ~= "" then f[#f + 1] = "--plugin-dir"; f[#f + 1] = tostring(p) end
  end
  return f
end

-- Resolve a saved agent profile into a concrete spawn intent. ctx = { mcpState }
-- (the MCP registry to dereference mcpServers names against). Returns the pieces
-- the FX layer turns into spawnSpec opts + an mcp-config file:
--   { folder, permMode, providerId, seedPrompt, appendSystemPrompt, agentName,
--     addDirs[], pluginDirs[], mcpServers[](resolved), mcpConfig(table|nil),
--     policyBundle, errors[] }.
function M.resolveAgent(profile, ctx)
  ctx = ctx or {}
  local res = { errors = {}, addDirs = {}, pluginDirs = {}, mcpServers = {} }
  if type(profile) ~= "table" then res.errors[#res.errors + 1] = "no profile"; return res end
  res.folder = profile.folder
  res.permMode = profile.permMode
  res.providerId = (agTrim(profile.provider) ~= "") and profile.provider or nil
  res.seedPrompt = (agTrim(profile.seedPrompt) ~= "") and profile.seedPrompt or nil
  res.appendSystemPrompt = M.personaPrompt(profile)
  res.agentName = (agTrim(profile.agentName) ~= "") and profile.agentName or nil
  res.policyBundle = profile.policyBundle
  res.addDirs = agStrList(profile.knowledge)
  res.pluginDirs = agStrList(profile.plugins)
  local servers = {}
  for _, id in ipairs(agStrList(profile.mcpServers)) do
    local rec = M.mcpGet(ctx.mcpState, id)
    if rec then servers[#servers + 1] = rec
    else res.errors[#res.errors + 1] = "MCP server not found: " .. id end
  end
  res.mcpServers = servers
  if #servers > 0 then res.mcpConfig = M.mcpConfig(servers) end
  return res
end

-- Profiles whose folderGlobs match `dir` (folder-scoped auto-attach). A profile
-- with no folderGlobs never auto-matches; a malformed glob fails open (skipped,
-- never errors). Glob syntax: `*` within a path segment, `**` across segments;
-- a leading `~` expands to $HOME.
function M.profilesForFolder(profiles, dir)
  local d = M.normDir(tostring(dir or ""))
  local out = {}
  if d == "" then return out end
  local home = os.getenv("HOME") or "~"
  for _, p in ipairs(profiles or {}) do
    for _, g in ipairs(agStrList(p.folderGlobs)) do
      local glob = g:gsub("^~", home)
      -- escape Lua-pattern magic (NOT `*`), then map `**`->`.*`, `*`->`[^/]*`.
      local pat = "^" .. glob:gsub("[%^%$%(%)%.%[%]%+%-%%]", "%%%1")
                              :gsub("%*%*", "\1"):gsub("%*", "[^/]*"):gsub("\1", ".*") .. "$"
      local ok, m = pcall(string.match, d, pat)
      if ok and m then out[#out + 1] = p; break end
    end
  end
  return out
end

-- ---- Skills enumerator (L1 skills card) ------------------------------------
-- Parse a SKILL.md / microagent .md leading YAML frontmatter into a card. Strips
-- a `---`...`---` fence and reads name/display_title/description; falls back to
-- the file stem for name. Pure (operates on file text the FX layer reads).
function M.parseSkillFrontmatter(text, stem)
  local out = { name = agTrim(stem), display_title = nil, description = nil }
  text = tostring(text or "")
  local fm = text:match("^%s*%-%-%-%s*\n(.-)\n%s*%-%-%-")
  if fm then
    local lines = {}
    for line in (fm .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local i = 1
    while i <= #lines do
      local indent, k, v = lines[i]:match("^(%s*)([%w_]+)%s*:%s*(.-)%s*$")
      if k then
        -- YAML block/folded scalar ("key: >" / ">-" / "|" / "|-" + chomp variants):
        -- the value is the following MORE-indented lines, not the indicator itself.
        -- Gather them and fold to a single line (what the cards display). Without
        -- this the value was literally ">-" (e.g. rune / deno-fresh2 SKILL.md).
        if v == ">" or v == ">-" or v == ">+" or v == "|" or v == "|-" or v == "|+" then
          local base, parts, j = #indent, {}, i + 1
          while j <= #lines do
            local cur = lines[j]
            if cur:match("^%s*$") then
              parts[#parts + 1] = ""                      -- blank line inside the block
            elseif #(cur:match("^(%s*)")) > base then
              parts[#parts + 1] = agTrim(cur)             -- a more-indented body line
            else
              break                                        -- de-dent: end of the block (not consumed)
            end
            j = j + 1                                       -- both gather arms advance; only break stops
          end
          v = agTrim((table.concat(parts, " "):gsub("%s+", " ")))
          i = j - 1   -- rewind: the de-dent line wasn't consumed, the loop's i+1 re-reads it as a key
        else
          v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        end
        local lk = k:lower()
        if lk == "name" and agTrim(v) ~= "" then out.name = agTrim(v)
        elseif lk == "display_title" or lk == "title" then out.display_title = agTrim(v)
        elseif lk == "description" then out.description = agTrim(v) end
      end
      i = i + 1
    end
  end
  if out.name == "" then out.name = agTrim(stem) end
  return out
end

-- The /<name> slash command a skill exposes (lowercased, spaces -> "-").
function M.skillCommand(name)
  local n = agTrim(name):lower():gsub("%s+", "-")
  if n == "" then return nil end
  return "/" .. n
end

-- ---- Installed MCP + skills INVENTORY (read-only 🔌 viewer) -----------------
-- Distinct from the cc-mcp.json agent registry above: this surfaces what is
-- ACTUALLY installed for Claude Code -- the user + per-project mcpServers in
-- ~/.claude.json, the live `claude mcp list` health/connectors, and the slash
-- commands + built-in skills. All pure; the FX layer does the reads/subprocess.

-- A server's display detail, NEVER exposing env values (those are secrets):
-- "command arg arg…" for stdio, or the url for http/sse.
local function mcpDetail(rec)
  if type(rec) ~= "table" then return "?" end
  if type(rec.command) == "string" then
    local parts = { rec.command }
    if type(rec.args) == "table" then
      for _, a in ipairs(rec.args) do parts[#parts + 1] = tostring(a) end
    end
    return table.concat(parts, " ")
  elseif type(rec.url) == "string" then
    return rec.url
  end
  return "?"
end
local function mcpTransport(rec)
  if type(rec) ~= "table" then return "stdio" end
  if rec.type and rec.type ~= "" then return tostring(rec.type) end
  if rec.url then return "http" end
  return "stdio"
end

-- Extract installed MCP servers from a decoded ~/.claude.json. Walks user-scope
-- `mcpServers` + every project's `mcpServers`, dedups by name (defined in both ->
-- scope "user+project"), and NEVER includes env. Returns a name-sorted list of
-- { name, scope, transport, detail }.
function M.extractInstalledMcp(claudeJson)
  claudeJson = type(claudeJson) == "table" and claudeJson or {}
  local byName, order = {}, {}
  local function add(name, rec, scope)
    if type(name) ~= "string" or name == "" then return end
    local e = byName[name]
    if not e then
      e = { name = name, scope = scope, transport = mcpTransport(rec), detail = mcpDetail(rec) }
      byName[name] = e; order[#order + 1] = name
    elseif not (e.scope == scope or e.scope:find(scope, 1, true)) then
      e.scope = e.scope .. "+" .. scope  -- same server defined in multiple scopes
    end
  end
  if type(claudeJson.mcpServers) == "table" then
    for name, rec in pairs(claudeJson.mcpServers) do add(name, rec, "user") end
  end
  if type(claudeJson.projects) == "table" then
    for _, proj in pairs(claudeJson.projects) do
      if type(proj) == "table" and type(proj.mcpServers) == "table" then
        for name, rec in pairs(proj.mcpServers) do add(name, rec, "project") end
      end
    end
  end
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = byName[name] end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- Parse `claude mcp list` stdout. Each server line is
--   "<name>: <detail> - <glyph> <status text>"
-- (✔ Connected / ✘ Failed to connect / ! Needs authentication / ⏸ Pending
-- approval). Connectors are prefixed "claude.ai ". Skips the health-check header,
-- blanks, and everything from "MCP Config Diagnostics" on. Returns a list of
-- { name, detail, status, connector } with status in
-- connected|failed|needs-auth|pending|unknown.
function M.parseMcpListOutput(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^MCP Config Diagnostics") then break end
    local name, rest = line:match("^(.-): (.+)$")
    if name and rest then
      local detail, status = rest:match("^(.*) %- (.+)$")  -- greedy: split last " - "
      if detail and status then
        local st = "unknown"
        if status:find("Connected") then st = "connected"
        elseif status:find("Failed") then st = "failed"
        elseif status:find("[Aa]uthenticat") then st = "needs-auth"
        elseif status:find("Pending") then st = "pending" end
        local connector = line:match("^claude%.ai ") ~= nil
        out[#out + 1] = {
          name = connector and (name:gsub("^claude%.ai ", "")) or name,
          detail = detail, status = st, connector = connector,
        }
      end
    end
  end
  return out
end

-- Merge config-derived servers (scope/transport/detail, no status) with live
-- `claude mcp list` results (status + connectors). Config entries gain status by
-- name; live-only servers (connectors, approved .mcp.json not in ~/.claude.json)
-- are appended (scope "connector"/"other"). liveList nil -> status "unknown".
-- Returns a list sorted by scope then name: { name, scope, transport, detail, status }.
function M.mergeMcpStatus(configList, liveList)
  local liveByName = {}
  for _, l in ipairs(liveList or {}) do liveByName[l.name] = l end
  local out, seen = {}, {}
  for _, c in ipairs(configList or {}) do
    local l = liveByName[c.name]
    out[#out + 1] = { name = c.name, scope = c.scope, transport = c.transport,
                      detail = c.detail, status = (l and l.status) or "unknown" }
    seen[c.name] = true
  end
  for _, l in ipairs(liveList or {}) do
    if not seen[l.name] then
      out[#out + 1] = { name = l.name, scope = l.connector and "connector" or "other",
                        transport = (l.detail or ""):match("^https?://") and "http" or "stdio",
                        detail = l.detail, status = l.status }
    end
  end
  table.sort(out, function(a, b)
    if (a.scope or "") ~= (b.scope or "") then return (a.scope or "") < (b.scope or "") end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

-- Built-in slash-command skills that ship INSIDE the `claude` binary -- they have
-- no file on disk and there is no `claude skill list` to enumerate them, so this
-- is maintained by hand and pinned to the CLI version. Update on a CLI bump.
M.BUILTIN_SKILLS_VERSION = "2.1.175"
M.BUILTIN_SKILLS = {
  { name = "code-review", description = "Review the current diff for bugs and reuse/efficiency cleanups at a chosen effort level." },
  { name = "security-review", description = "Security review of the pending changes on the current branch." },
  { name = "review", description = "Review a pull request." },
  { name = "simplify", description = "Apply reuse / simplification / efficiency / altitude cleanups to the changed code." },
  { name = "verify", description = "Run the app and observe behavior to confirm a change actually works." },
  { name = "run", description = "Launch and drive this project's app to see a change working." },
  { name = "deep-research", description = "Fan-out web research, adversarially verify claims, synthesize a cited report." },
  { name = "loop", description = "Run a prompt or slash command on a recurring interval." },
  { name = "schedule", description = "Create / manage scheduled cloud agents (cron routines)." },
  { name = "update-config", description = "Configure the Claude Code harness via settings.json (hooks, permissions, env)." },
  { name = "keybindings-help", description = "Customize keyboard shortcuts / keybindings.json." },
  { name = "fewer-permission-prompts", description = "Add a read-only allowlist to settings to cut permission prompts." },
  { name = "claude-api", description = "Reference for the Claude API / Anthropic SDK (models, pricing, tools)." },
  { name = "init", description = "Initialize a new CLAUDE.md with codebase documentation." },
}

-- The built-in skills as viewer cards { name, description, command, builtin }.
function M.builtinSkillCards()
  local out = {}
  for _, s in ipairs(M.BUILTIN_SKILLS) do
    out[#out + 1] = { name = s.name, description = s.description,
                      command = M.skillCommand(s.name), builtin = true }
  end
  return out
end

-- External CLI tools Shepherd shells out to, surfaced read-only in the 🔌 viewer
-- so a glance shows what's installed vs. degraded. Each: name + `bin` (what we
-- resolve on PATH), `role` (what it powers), and either `fallback` (the POSIX
-- tool it degrades to), `required` (jq -- the one hard dep), or `optional` (a
-- subsystem you may not use). Hand-maintained; pure data. The FX layer resolves
-- real paths (resolveBin) and M.cliToolCards turns that into cards.
M.CLI_TOOLS = {
  { name = "jq",          bin = "jq",          role = "rich session tiles (parses each session's status JSON)", required = true },
  { name = "ripgrep",     bin = "rg",          role = "fleet-wide search across sessions",          fallback = "grep" },
  { name = "fd",          bin = "fd",          role = "New-session folder scan (gitignore-aware)",  fallback = "find" },
  { name = "rsync",       bin = "rsync",       role = "SSH status bridge (pulls remote fleets)" },
  { name = "ffmpeg",      bin = "ffmpeg",      role = "Stream Deck voice capture",        optional = true },
  { name = "whisper-cli", bin = "whisper-cli", role = "Stream Deck voice transcription",  optional = true },
}

-- Shape the CLI-tool catalog into viewer cards given a { bin = resolvedPath } map
-- (FX resolves the paths). A tool counts as INSTALLED only when its resolved value
-- is an ABSOLUTE path -- resolveBin returns the bare name when nothing is found, so
-- a non-"/"-prefixed value means missing. Missing tools surface their fallback
-- instead of a path. Pure.
-- The install rule, owned HERE as the single source of truth: a tool counts as
-- installed iff its resolved value is an ABSOLUTE path. Pure, so it can't touch the
-- filesystem -- a caller that resolves via PATH (FX.cliToolStatus) pre-filters to
-- absolute paths that ALSO exist (hs.fs.attributes) before passing the map in. That
-- existence layer sits ON TOP of this rule; it doesn't replace it, so this predicate
-- stays authoritative for any caller (incl. ones that pass a raw resolveBin map).
function M.isInstalledPath(p)
  return type(p) == "string" and p:sub(1, 1) == "/"
end

function M.cliToolCards(resolved)
  resolved = type(resolved) == "table" and resolved or {}
  local out = {}
  for _, t in ipairs(M.CLI_TOOLS) do
    local path = resolved[t.bin]
    local installed = M.isInstalledPath(path)
    out[#out + 1] = {
      name = t.name, bin = t.bin, role = t.role,
      required = t.required == true, optional = t.optional == true,
      fallback = t.fallback,
      installed = installed,
      path = installed and path or nil,
    }
  end
  return out
end

-- ---- In-app worklist (project + generic checklists; NO code hooks) ----------
-- A dead-simple checklist surfaced in the panel. state.generic is the global
-- list; state.byProject[projectKey] is a per-folder list keyed by the SAME stable
-- launch-folder identity as labels/groups, so a list sticks across cd-drift /
-- respawn / close-and-reopen. Items: { id, text, done, ts }. All pure -- the FX
-- layer does I/O and mints ids. scope == "generic" (or nil) -> the global list;
-- any other string -> that projectKey's list.

-- The live array for a scope (the actual reference, so mutations write through).
function M.worklistScopeList(state, scope)
  if type(state) ~= "table" then return {} end
  if scope == nil or scope == "generic" then return state.generic or {} end
  return (state.byProject or {})[scope] or {}
end

-- Append a trimmed item to a scope (empty/whitespace text is ignored). The caller
-- supplies a unique id (FX mints it) + now; pure here for deterministic tests.
function M.worklistAdd(state, scope, text, id, now)
  state = type(state) == "table" and state or {}
  text = type(text) == "string" and (text:gsub("^%s+", ""):gsub("%s+$", "")) or ""
  if text == "" then return state end
  local item = { id = tostring(id or ""), text = text, done = false, ts = tonumber(now) or 0 }
  if scope == nil or scope == "generic" then
    if type(state.generic) ~= "table" then state.generic = {} end
    state.generic[#state.generic + 1] = item
  else
    if type(state.byProject) ~= "table" then state.byProject = {} end
    if type(state.byProject[scope]) ~= "table" then state.byProject[scope] = {} end
    local l = state.byProject[scope]; l[#l + 1] = item
  end
  return state
end

-- Flip an item's done flag by id within a scope (checking moves it to the Done
-- area in the UI; unchecking brings it back).
function M.worklistToggle(state, scope, id)
  for _, it in ipairs(M.worklistScopeList(state, scope)) do
    if it.id == id then it.done = not it.done; break end
  end
  return state
end

-- Remove one item by id from a scope (the per-item ✕ delete). Rebuilds the scope
-- list without the matching id; an unknown id is a no-op. Mirrors clearDone's
-- write-through (assign the kept list back to the right container). Pure.
function M.worklistRemove(state, scope, id)
  if type(state) ~= "table" then return state or {} end
  local kept = {}
  for _, it in ipairs(M.worklistScopeList(state, scope)) do
    if it.id ~= id then kept[#kept + 1] = it end
  end
  if scope == nil or scope == "generic" then state.generic = kept
  else state.byProject = state.byProject or {}; state.byProject[scope] = kept end
  return state
end

-- Replace an item's text by id within a scope (the double-click inline edit). Trims;
-- an empty/whitespace new text is IGNORED (keeps the original) so an accidental
-- blank save can't erase an item. Unknown id is a no-op. Pure.
function M.worklistEdit(state, scope, id, text)
  text = type(text) == "string" and (text:gsub("^%s+", ""):gsub("%s+$", "")) or ""
  if text == "" then return state end
  for _, it in ipairs(M.worklistScopeList(state, scope)) do
    if it.id == id then it.text = text; break end
  end
  return state
end

-- Drop the done items from a scope (the "Clear" on the Done area).
function M.worklistClearDone(state, scope)
  if type(state) ~= "table" then return state or {} end
  local kept = {}
  for _, it in ipairs(M.worklistScopeList(state, scope)) do
    if not it.done then kept[#kept + 1] = it end
  end
  if scope == nil or scope == "generic" then state.generic = kept
  else state.byProject = state.byProject or {}; state.byProject[scope] = kept end
  return state
end

-- Split a scope's items into active + done lists (UI helper; pure).
function M.worklistSplit(items)
  local active, done = {}, {}
  for _, it in ipairs(items or {}) do
    if it.done then done[#done + 1] = it else active[#active + 1] = it end
  end
  return active, done
end

-- Normalize a decoded worklist into DISTINCT, correctly-shaped containers:
-- generic = a fresh LIST, byProject = a fresh MAP of string-key -> list. This is
-- load-bearing: hs.json.decode INTERNS empty {} into a single shared table, so a
-- fresh file's generic and byProject decode to the SAME table -- adding to one
-- then pollutes the other. Rebuilding into separate tables breaks that alias.
-- Also drops stray non-string keys / non-table items, which self-heals a file
-- already corrupted by the old aliasing bug (its byProject is a numeric-keyed
-- array). Pure.
function M.worklistNormalize(t)
  t = type(t) == "table" and t or {}
  local generic = {}
  if type(t.generic) == "table" then
    for _, it in ipairs(t.generic) do if type(it) == "table" then generic[#generic + 1] = it end end
  end
  local byProject = {}
  if type(t.byProject) == "table" then
    for k, v in pairs(t.byProject) do
      if type(k) == "string" and type(v) == "table" then
        local list = {}
        for _, it in ipairs(v) do if type(it) == "table" then list[#list + 1] = it end end
        byProject[k] = list
      end
    end
  end
  return { generic = generic, byProject = byProject }
end

-- ---- User stories editor (spec/product/user-stories.md) -------------------
-- Parse / edit / serialize a project's user-stories.md so the panel can show its
-- stories (grouped by capability area) and add/edit/save them WITHOUT clobbering
-- the file's non-story content. Model = "anchored blocks": every non-story line
-- (the # title, intro prose, ## headings, blanks, trailing notes) is kept VERBATIM
-- as a `raw` block; each bullet is a `story` block tagged with its `area` (the
-- nearest preceding ## heading). The invariant the round-trip rests on: the
-- concatenation of every block's raw/src text == the original file byte-for-byte,
-- so serialize(parse(x)) == x exactly. Serialize re-emits a story as its original
-- `src` when unchanged (zero churn) or `- <text>` when added/edited (`dirty`).

-- A story bullet: up to 3 leading spaces, then - or * , a space, then the text.
-- Returns the text (possibly "") or nil. A bare "-" / "---" rule / "***" is NOT a
-- bullet (no required space after the marker).
local function uslBullet(line)
  return line:match("^ ? ? ?([%-%*]) (.*)$")   -- returns marker ("-"/"*"), text  (or nil)
end
-- An H2 heading's area name (trimmed), or nil. (Only ## -- the # title stays raw.)
local function uslHeadingArea(line)
  local h = line:match("^##%s+(.*)$")
  return h and (h:gsub("%s+$", "")) or nil
end
-- A fenced-code delimiter (``` or ~~~, >=3, optional indent + info string).
local function uslFence(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end
-- A continuation line of a bullet: indented (>=2 spaces / a tab) + non-blank, and
-- not itself a bullet or heading -- i.e. a wrapped tail of the bullet above it.
local function uslIsContinuation(line)
  if line:match("^%s*$") then return false end
  if uslHeadingArea(line) or uslBullet(line) then return false end
  return line:match("^  ") ~= nil or line:match("^\t") ~= nil
end

-- parseUserStories(text) -> { blocks, stories, areas }
--   blocks  : ordered { {raw=".."[,headingArea]} | {id,area,marker,text,src} }
--   stories : the story blocks, in order (same table refs as in blocks)
--   areas   : ordered distinct non-empty area names (## headings), for grouping
-- Round-trip: serialize(parse(x).blocks) == x byte-for-byte when x ends in a newline
-- (the normal case); a file with no final newline gains one (a safe POSIX-text
-- normalization -- the old trailing-newline strip caused appends to glue onto the last
-- line, silently corrupting the file). Lines inside ```/~~~ fences are kept RAW (never
-- parsed as stories), and each ## heading anchors its own raw block (tagged headingArea)
-- so an add can be placed under the exact area even when it has no stories yet.
function M.parseUserStories(text)
  text = type(text) == "string" and text or ""
  local blocks, stories, areas, seen = {}, {}, {}, {}
  if text == "" then return { blocks = blocks, stories = stories, areas = areas } end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if text:sub(-1) == "\n" then lines[#lines] = nil end   -- drop the phantom empty

  local rawbuf, pendingHeadingArea
  local function flushRaw()
    if rawbuf then
      local blk = { raw = rawbuf }
      if pendingHeadingArea ~= nil then blk.headingArea = pendingHeadingArea; pendingHeadingArea = nil end
      blocks[#blocks + 1] = blk; rawbuf = nil
    end
  end
  local curArea, sid, i, inFence = "", 0, 1, false
  while i <= #lines do
    local line = lines[i]
    if uslFence(line) then            -- fence delimiter: toggle, keep raw
      inFence = not inFence
      rawbuf = (rawbuf or "") .. line .. "\n"; i = i + 1
    elseif inFence then               -- inside a code fence: raw, never a story
      rawbuf = (rawbuf or "") .. line .. "\n"; i = i + 1
    else
      local marker, bt = uslBullet(line)
      if marker ~= nil then
        flushRaw()
        local src, parts, j = line .. "\n", { (bt:gsub("%s+$", "")) }, i + 1
        while j <= #lines and uslIsContinuation(lines[j]) do
          src = src .. lines[j] .. "\n"
          parts[#parts + 1] = (lines[j]:gsub("^%s+", ""):gsub("%s+$", ""))
          j = j + 1
        end
        sid = sid + 1
        local st = { id = "s" .. sid, area = curArea, marker = marker,
                     text = table.concat(parts, " "), src = src }
        blocks[#blocks + 1] = st; stories[#stories + 1] = st
        i = j
      else
        local area = uslHeadingArea(line)
        if area ~= nil then
          flushRaw()                  -- close the prior run so this heading anchors its own block
          curArea = area; pendingHeadingArea = area
          if area ~= "" and not seen[area] then seen[area] = true; areas[#areas + 1] = area end
        end
        rawbuf = (rawbuf or "") .. line .. "\n"; i = i + 1
      end
    end
  end
  flushRaw()
  return { blocks = blocks, stories = stories, areas = areas }
end

-- serializeUserStories(blocks) -> text. raw verbatim; a story emits its original `src`
-- unless `dirty` (or it has no src -- a freshly-added story), in which case it emits a
-- single-line `<marker> <text>` (marker preserved, default "-"). A story is ONE line:
-- embedded newlines (a Shift+Enter / multi-line paste) collapse to spaces so an edit
-- can't inject fake structure. A blank added story is dropped (not written as a bare
-- "- "). New/edited lines use the file's PREVAILING newline (CRLF vs LF) so a save
-- never mixes line endings.
function M.serializeUserStories(blocks)
  blocks = blocks or {}
  local eol = "\n"
  for _, b in ipairs(blocks) do
    local s = type(b) == "table" and (b.raw or b.src) or nil
    if type(s) == "string" and s:find("\r\n", 1, true) then eol = "\r\n"; break end
  end
  local out = {}
  for _, b in ipairs(blocks) do
    if type(b) ~= "table" then  -- skip junk
    elseif b.raw ~= nil then
      out[#out + 1] = tostring(b.raw)
    else
      local txt = type(b.text) == "string" and b.text or ""
      if b.dirty or b.src == nil or b.src == "" then
        local oneLine = txt:gsub("%s*[\r\n]+%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
        oneLine = oneLine:gsub("^[%-%*]%s+", "")   -- a user-typed/pasted leading "- "/"* " must not double the marker
        if oneLine ~= "" then
          local mk = (b.marker == "*") and "*" or "-"
          out[#out + 1] = mk .. " " .. oneLine .. eol
        end
      else
        out[#out + 1] = tostring(b.src)
      end
    end
  end
  return table.concat(out)
end

-- Does a story line satisfy the team convention "As a <role>, I want <cap>, so that
-- <benefit>" -- specifically the MANDATORY "so that"? Lenient + case-insensitive;
-- used only for a soft UI hint, never to block a save. Empty -> false.
function M.userStoryWellFormed(text)
  local s = tostring(text or ""):lower()
  if s:gsub("%s+", "") == "" then return false end
  return s:find("as a", 1, true) ~= nil
     and (s:find("i want", 1, true) ~= nil or s:find("i'd like", 1, true) ~= nil)
     and s:find("so that", 1, true) ~= nil
end

-- A cheap, stable content hash (djb2) for the on-disk file -- the panel echoes the
-- hash it loaded and the save handler refuses to write if the file changed underneath
-- (an external edit), so a stale panel can't silently clobber it. Pure.
function M.cheapHash(s)
  s = tostring(s or "")
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

-- ===========================================================================
-- L2 — Named policy / guardrail bundles + attachments
-- ===========================================================================
-- Turn the flat fleet policy (policies.patterns.autoAllow/autoDeny + gate.tools)
-- into NAMED, attachable bundles. A session's EFFECTIVE policy is resolved here
-- (pure) with precedence: per-session override > attached bundle (matched by
-- project/group/provider/key) > fleet default. The dashboard resolves each session
-- and writes a per-session policy file the gate (cc-approve.sh) reads -- KEEP IN
-- SYNC (the shell wiring mirrors this resolution / consumes its output).
-- Config: policies.bundles = { [name] = { autoAllow[], autoDeny[], gateTools,
--   autopilot, lockedPermMode, toolLimits{tool=N}, disableGlobal } };
--   policies.attachments = [ { match = {project,group,providerId,key}, bundle } ].

-- Glob-equality for one match field: nil/"" pattern = wildcard; supports * and ?.
function M.globEq(pat, val)
  if pat == nil or pat == "" then return true end
  pat = tostring(pat); val = tostring(val or "")
  local rx = "^" .. pat:gsub("[%^%$%(%)%.%[%]%+%-%%]", "%%%1")
                       :gsub("%*", ".*"):gsub("%?", ".") .. "$"
  local ok, m = pcall(string.match, val, rx)
  return ok and m ~= nil
end

function M.policyBundles(cfg)
  local b = M.config(cfg, "policies.bundles", nil)
  return type(b) == "table" and b or {}
end
function M.policyBundle(cfg, name)
  if not name or tostring(name) == "" then return nil end
  local b = M.policyBundles(cfg)[tostring(name)]
  return type(b) == "table" and b or nil
end

-- First attachment whose match matches the session -> its bundle name, or nil.
-- session = { project|projectKey, group, providerId, key }. An absent/"" match
-- field is a wildcard; all present fields must glob-match.
function M.matchAttachment(cfg, session)
  session = session or {}
  local atts = M.config(cfg, "policies.attachments", nil)
  if type(atts) ~= "table" then return nil end
  for _, a in ipairs(atts) do
    if type(a) == "table" and type(a.match) == "table" and a.bundle then
      local m = a.match
      if M.globEq(m.project, session.project or session.projectKey)
         and M.globEq(m.group, session.group)
         and M.globEq(m.providerId, session.providerId)
         and M.globEq(m.key, session.key) then
        return tostring(a.bundle)
      end
    end
  end
  return nil
end

-- Resolve a session's EFFECTIVE policy. override (optional) = a bundle name, or
-- { bundle, disableGlobal }. Precedence: override > attachment > fleet. autoDeny
-- and autoAllow are the bundle's UNION the fleet's (unless disableGlobal drops the
-- fleet lists); gateTools reuses resolveGateTools precedence. Pure + deterministic.
function M.resolvePolicy(cfg, session, override)
  local ovName, ovDisable
  if type(override) == "table" then ovName = override.bundle; ovDisable = override.disableGlobal
  elseif type(override) == "string" and override ~= "" then ovName = override end
  local bundleName = (ovName and tostring(ovName) ~= "" and ovName) or M.matchAttachment(cfg, session)
  local bundle = M.policyBundle(cfg, bundleName) or {}
  local source = (ovName and "session") or (bundleName and "attachment") or "fleet"
  local disableGlobal = ovDisable
  if disableGlobal == nil then disableGlobal = bundle.disableGlobal == true end
  local function arr(v) return type(v) == "table" and v or {} end
  local function union(a, b)
    local out, seen = {}, {}
    for _, x in ipairs(a) do local s = tostring(x); if not seen[s] then seen[s] = true; out[#out + 1] = x end end
    for _, x in ipairs(b) do local s = tostring(x); if not seen[s] then seen[s] = true; out[#out + 1] = x end end
    return out
  end
  local fleetAllow = disableGlobal and {} or arr(M.config(cfg, "policies.patterns.autoAllow", nil))
  local fleetDeny  = disableGlobal and {} or arr(M.config(cfg, "policies.patterns.autoDeny", nil))
  return {
    bundle = bundleName, source = source, disableGlobal = disableGlobal,
    autoAllow = union(arr(bundle.autoAllow), fleetAllow),
    autoDeny  = union(arr(bundle.autoDeny), fleetDeny),
    gateTools = M.resolveGateTools(bundle.gateTools, nil, M.config(cfg, "gate.tools", nil)),
    autopilot = bundle.autopilot == true,
    lockedPermMode = bundle.lockedPermMode,
    toolLimits = type(bundle.toolLimits) == "table" and bundle.toolLimits or nil,
  }
end

-- Starter bundles the UI offers (the operator copies one into policies.bundles).
-- read-only = gate everything that mutates; mind the escalation semantics (these
-- are autoDeny rules, NOT an allow-list).
M.DEFAULT_POLICY_BUNDLES = {
  ["read-only"]  = { autoDeny = { "Bash", "Write", "Edit", "MultiEdit", "NotebookEdit" } },
  ["no-bash"]    = { autoDeny = { "Bash" } },
  ["no-network"] = { autoDeny = { "Bash(curl*)", "Bash(wget*)", "WebFetch" } },
}

-- Tools at/over their per-bundle usage ceiling, given a counts map {tool=n}.
-- Returns a list of { tool, used, limit }. (Soft/next-request limit; the ledger
-- supplies the counts -- Claude Code owns true enforcement.)
function M.overToolLimit(toolLimits, counts)
  local out = {}
  if type(toolLimits) ~= "table" then return out end
  counts = type(counts) == "table" and counts or {}
  for tool, lim in pairs(toolLimits) do
    local n = tonumber(counts[tool]) or 0
    local L = tonumber(lim)
    if L and n >= L then out[#out + 1] = { tool = tool, used = n, limit = L } end
  end
  return out
end

-- ---- L2 bundle/attachment EDITOR — pure CRUD on the policies subtree --------
-- The L2 editor authors policies.bundles (a name->bundle MAP) + policies.attachments
-- (an ORDERED array; first match wins) inside cc-config.json. These pure ops take
-- the `policies` subtree and return a NEW one (policies.patterns rides through
-- untouched); the dashboard reads cfg, applies, writes cfg back. No clock, no hs.*.

function M.validatePolicyBundle(rec)
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  for _, f in ipairs({ "autoAllow", "autoDeny" }) do
    if rec[f] ~= nil and type(rec[f]) ~= "table" then errs[#errs + 1] = f .. " must be a list" end
  end
  if rec.lockedPermMode ~= nil and tostring(rec.lockedPermMode) ~= "" then
    local pm = tostring(rec.lockedPermMode)
    if pm ~= "default" and pm ~= "acceptEdits" and pm ~= "plan" then
      errs[#errs + 1] = "lockedPermMode must be default|acceptEdits|plan"
    end
  end
  if rec.toolLimits ~= nil and type(rec.toolLimits) ~= "table" then errs[#errs + 1] = "toolLimits must be a map" end
  return { ok = #errs == 0, errors = errs }
end

-- Normalize a bundle to only its SET fields (so an empty field doesn't persist).
function M.policyBundleNorm(rec)
  rec = type(rec) == "table" and rec or {}
  local out = {}
  if type(rec.autoAllow) == "table" then local l = agStrList(rec.autoAllow); if #l > 0 then out.autoAllow = l end end
  if type(rec.autoDeny) == "table" then local l = agStrList(rec.autoDeny); if #l > 0 then out.autoDeny = l end end
  -- gateTools is a normalized STRING (space-separated, like gate.tools) -- parseToolList
  -- dedupes + joins; drop it if it ends up empty.
  if rec.gateTools ~= nil and tostring(rec.gateTools) ~= "" then
    local g = M.parseToolList(rec.gateTools); if g ~= "" then out.gateTools = g end
  end
  if rec.autopilot == true then out.autopilot = true end
  if rec.disableGlobal == true then out.disableGlobal = true end
  if type(rec.lockedPermMode) == "string" and rec.lockedPermMode ~= "" then out.lockedPermMode = rec.lockedPermMode end
  if type(rec.toolLimits) == "table" then
    local tl = {}
    for k, v in pairs(rec.toolLimits) do local n = tonumber(v); if n and agTrim(k) ~= "" then tl[agTrim(k)] = n end end
    if next(tl) then out.toolLimits = tl end
  end
  return out
end

local function polCopy(policies)
  local out = {}
  if type(policies) == "table" then for k, v in pairs(policies) do out[k] = v end end
  return out
end

-- Upsert a named bundle. Returns newPolicies, ok, errors. Validated + normalized.
function M.policySetBundle(policies, name, rec)
  name = agTrim(name)
  local v = M.validatePolicyBundle(rec)
  if name == "" then v.ok = false; v.errors = v.errors or {}; v.errors[#v.errors + 1] = "bundle needs a name" end
  if not v.ok then return policies, false, v.errors end
  local out = polCopy(policies)
  local bundles = {}
  if type(out.bundles) == "table" then for k, vv in pairs(out.bundles) do bundles[k] = vv end end
  bundles[name] = M.policyBundleNorm(rec)
  out.bundles = bundles
  return out, true
end

function M.policyRemoveBundle(policies, name)
  name = agTrim(name)
  local out = polCopy(policies)
  local bundles = {}
  if type(out.bundles) == "table" then for k, vv in pairs(out.bundles) do if k ~= name then bundles[k] = vv end end end
  out.bundles = bundles
  return out
end

function M.validateAttachment(att)
  if type(att) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if att.bundle == nil or agTrim(att.bundle) == "" then errs[#errs + 1] = "attachment needs a bundle" end
  if att.match ~= nil and type(att.match) ~= "table" then errs[#errs + 1] = "match must be an object" end
  return { ok = #errs == 0, errors = errs }
end

-- Keep only the present match fields (blank = wildcard, so drop it).
function M.attachmentNorm(att)
  local m = type(att.match) == "table" and att.match or {}
  local match = {}
  for _, k in ipairs({ "project", "group", "providerId", "key" }) do
    if type(m[k]) == "string" and agTrim(m[k]) ~= "" then match[k] = agTrim(m[k]) end
  end
  return { match = match, bundle = agTrim(att.bundle) }
end

local function attArr(policies)
  local a = (type(policies) == "table" and type(policies.attachments) == "table") and policies.attachments or {}
  local out = {}; for _, x in ipairs(a) do out[#out + 1] = x end; return out
end

function M.policyAddAttachment(policies, att)
  local v = M.validateAttachment(att)
  if not v.ok then return policies, false, v.errors end
  local out = polCopy(policies)
  local arr = attArr(policies); arr[#arr + 1] = M.attachmentNorm(att)
  out.attachments = arr
  return out, true
end

function M.policySetAttachment(policies, index, att)
  local v = M.validateAttachment(att)
  if not v.ok then return policies, false, v.errors end
  local arr = attArr(policies); index = tonumber(index)
  if not index or index < 1 or index > #arr then return policies, false, { "bad attachment index" } end
  local out = polCopy(policies)
  arr[index] = M.attachmentNorm(att); out.attachments = arr
  return out, true
end

function M.policyRemoveAttachment(policies, index)
  local out = polCopy(policies)
  local arr, res = attArr(policies), {}
  index = tonumber(index)
  for i, x in ipairs(arr) do if i ~= index then res[#res + 1] = x end end
  out.attachments = res
  return out
end

-- Reorder an attachment (dir -1 up / +1 down). First-match-wins, so order matters.
function M.policyMoveAttachment(policies, index, dir)
  local out = polCopy(policies)
  local arr = attArr(policies)
  index = tonumber(index); dir = tonumber(dir)
  local j = (index and dir) and (index + dir) or nil
  if index and j and index >= 1 and index <= #arr and j >= 1 and j <= #arr then
    arr[index], arr[j] = arr[j], arr[index]
  end
  out.attachments = arr
  return out
end

-- ===========================================================================
-- L6 — Event-callback rule engine (cc-rules.json)
-- ===========================================================================
-- Declarative, OPT-IN rules that react to a session edge with a safe effect --
-- generalizing the hard-coded auto-respawn/continue/escalation onto the existing
-- level-triggered dispatcher (NOT a new event bus). A rule = { name, enabled,
-- trigger = { kind, match? }, processor = { kind, text?, label? }, once? }. The
-- dashboard detects the edge each tick and runs ALL matching rules' processors in
-- declared order (rulesForEdge returns every match, not first-wins);
-- `once` self-mutates a fired-marker through fx (like routePending). Off unless the
-- global rules.enabled is set AND the rule is enabled. Validate -> fail-safe load ->
-- list mirrors the L1 agent registry.
M.RULE_CAP = 50
-- Triggers: the three status EDGES (done/error/approval) fire per-tile in the refresh
-- loop; hung/loop/starved fire at their OWN detection sites (the watchdog / loop
-- watchdog / routing starvation clock) -- the engine calls runRules there on the
-- rising edge. Processors map onto present SAFE effects: log->ledger, relabel->setLabel,
-- nudge/feed/continue->the delivery-gated keystroke/queue paths.
M.RULE_TRIGGERS = { done = true, error = true, approval = true, hung = true, loop = true, starved = true }
M.RULE_PROCESSORS = { log = true, relabel = true, nudge = true, feed = true, continue = true }
M.RULE_FIELDS = { name = true, enabled = true, trigger = true, processor = true, once = true }

local function rlist(state)
  if type(state) == "table" and type(state.rules) == "table" then return state.rules end
  return {}
end

-- Validate a rule: returns { ok, errors[] }. name non-blank; trigger.kind in
-- RULE_TRIGGERS; processor.kind in RULE_PROCESSORS; processor-specific required
-- fields (nudge needs text; relabel needs label). Unknown fields flagged.
function M.validateRule(rec)
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if agTrim(rec.name) == "" then errs[#errs + 1] = "missing required field: name" end
  local tr = rec.trigger
  if type(tr) ~= "table" then errs[#errs + 1] = "trigger must be an object"
  elseif not M.RULE_TRIGGERS[tostring(tr.kind)] then
    errs[#errs + 1] = "unknown trigger kind: " .. tostring(tr.kind)
  elseif tr.match ~= nil and type(tr.match) ~= "table" then
    errs[#errs + 1] = "trigger.match must be an object"
  end
  local pr = rec.processor
  if type(pr) ~= "table" then errs[#errs + 1] = "processor must be an object"
  elseif not M.RULE_PROCESSORS[tostring(pr.kind)] then
    errs[#errs + 1] = "unknown processor kind: " .. tostring(pr.kind)
  else
    if pr.kind == "nudge" and agTrim(pr.text) == "" then errs[#errs + 1] = "nudge processor needs text" end
    if pr.kind == "feed" and agTrim(pr.text) == "" then errs[#errs + 1] = "feed processor needs text" end
    if pr.kind == "relabel" and agTrim(pr.label) == "" then errs[#errs + 1] = "relabel processor needs label" end
  end
  for k in pairs(rec) do
    if not M.RULE_FIELDS[k] then errs[#errs + 1] = "unknown field: " .. tostring(k) end
  end
  return { ok = #errs == 0, errors = errs }
end

local function ruleNorm(rec)
  local tr = type(rec.trigger) == "table" and rec.trigger or {}
  local pr = type(rec.processor) == "table" and rec.processor or {}
  return {
    name = agTrim(rec.name),
    enabled = rec.enabled ~= false,  -- default ON (the global rules.enabled gates the engine)
    trigger = { kind = tostring(tr.kind),
                match = type(tr.match) == "table" and tr.match or nil },
    processor = { kind = tostring(pr.kind), text = tplStr(pr.text), label = tplStr(pr.label) },
    once = rec.once == true,
  }
end

-- Fail-safe load (mirrors agentLoad/templateLoad): validate each, keep valid
-- (normalized), drop bad with reasons, dedupe by name. Returns {valid, errors}.
function M.ruleLoad(state)
  local valid, errors, seen = {}, {}, {}
  for _, rec in ipairs(rlist(state)) do
    local v = M.validateRule(rec)
    local nm = (type(rec) == "table") and agTrim(rec.name) or ""
    if not v.ok then
      errors[#errors + 1] = { name = nm ~= "" and nm or "(unnamed)", reason = table.concat(v.errors, "; ") }
    elseif seen[nm] then
      errors[#errors + 1] = { name = nm, reason = "duplicate name (kept first)" }
    else
      seen[nm] = true; valid[#valid + 1] = ruleNorm(rec)
    end
  end
  return { valid = valid, errors = errors }
end

function M.ruleList(state) return M.ruleLoad(state).valid end

-- Does a rule's scope match this tile? match fields (project/group/sessionKey/
-- provider) are wildcard-globbed; an absent/"" field matches anything; nil match =
-- fleet-wide. Reuses the L2 globEq.
local function ruleScopeMatch(match, item)
  if type(match) ~= "table" then return true end
  item = type(item) == "table" and item or {}
  return M.globEq(match.project, item.projectKey) and M.globEq(match.group, item.group)
     and M.globEq(match.sessionKey, item.key) and M.globEq(match.provider, item.providerId)
end

-- Does this rule fire for an `edgeKind` event on `item`? enabled + trigger kind +
-- scope. Pure; the caller detects the edge (done/error/hung/approval/starved/loop)
-- and the `once`/fired bookkeeping.
function M.ruleFires(rule, edgeKind, item)
  if type(rule) ~= "table" or rule.enabled == false then return false end
  if type(rule.trigger) ~= "table" or rule.trigger.kind ~= edgeKind then return false end
  return ruleScopeMatch(rule.trigger.match, item)
end

-- All rules (in order) that fire for an edge on a tile -- sequential execution is
-- the caller running them in order (one dispatcher per tick).
function M.rulesForEdge(rules, edgeKind, item)
  local out = {}
  for _, r in ipairs(type(rules) == "table" and rules or {}) do
    if M.ruleFires(r, edgeKind, item) then out[#out + 1] = r end
  end
  return out
end

-- ---- L6 rule CRUD (editor) — mirrors the agent registry --------------------
function M.ruleGet(state, name)
  for _, r in ipairs(M.ruleList(state)) do if r.name == agTrim(name) then return r end end
  return nil
end

-- Upsert a rule: validate -> replace same-name in place / prepend -> cap. Returns
-- newState, ok, errors.
function M.rulePush(state, rec, cap)
  cap = tonumber(cap) or M.RULE_CAP
  rec = type(rec) == "table" and rec or {}
  local v = M.validateRule(rec)
  if not v.ok then return { rules = M.ruleList(state) }, false, v.errors end
  local entry = ruleNorm(rec)
  local out, replaced = {}, false
  for _, r in ipairs(M.ruleList(state)) do
    if r.name == entry.name then out[#out + 1] = entry; replaced = true
    else out[#out + 1] = r end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { rules = out }, true
end

function M.ruleRemove(state, name)
  local out, target = {}, agTrim(name)
  for _, r in ipairs(M.ruleList(state)) do if r.name ~= target then out[#out + 1] = r end end
  return { rules = out }
end

-- Toggle a rule's enabled flag on RAW state (preserve every field). Pure.
function M.ruleSetEnabled(state, name, on)
  local out, target = {}, agTrim(name)
  for _, r in ipairs(rlist(state)) do
    if type(r) == "table" and agTrim(r.name) == target then
      local c = {}; for k, v in pairs(r) do c[k] = v end
      c.enabled = on == true
      out[#out + 1] = c
    else
      out[#out + 1] = r
    end
  end
  return { rules = out }
end

-- ===========================================================================
-- L7 — Scheduled spawns / routines (cc-schedules.json)
-- ===========================================================================
-- A routine fires the NORMAL spawn/nudge effects on a schedule (NOT a second
-- executor). A record = { name, kind = cron|oneShot, cron? (5-field), at? (epoch),
-- folder, editor?, provider?, model?, permMode?, prompt?|templateRef?|agentRef?,
-- enabled = false, tags?, lastFiredAt? }. All scheduling is PURE on an injected
-- `now` (local-tz via os.date, which is plain-lua safe). Off by default (enabled).
M.SCHEDULE_CAP = 50
M.SCHEDULE_FIELDS = { name = true, kind = true, cron = true, at = true, folder = true,
  editor = true, provider = true, model = true, permMode = true, prompt = true,
  templateRef = true, agentRef = true, enabled = true, tags = true, lastFiredAt = true,
  action = true, digestHours = true, pushTopic = true }
M.SCHEDULE_ACTIONS = { spawn = true, digest = true }

local function slist(state)
  if type(state) == "table" and type(state.schedules) == "table" then return state.schedules end
  return {}
end

-- Match one cron field spec against an integer value within [lo,hi]. Supports
-- "*", "N", "A-B", "A,B,C", "*/S", "A-B/S" (and lists of those). Pure.
local function cronFieldMatch(spec, value, lo, hi)
  for part in (tostring(spec or "*") .. ","):gmatch("([^,]*),") do
    part = part:gsub("%s", "")
    if part ~= "" then
      local base, step = part, 1
      local b, s = part:match("^(.-)/(%d+)$")
      if b then base = b; step = tonumber(s) or 1 end
      local rlo, rhi
      if base == "*" then rlo, rhi = lo, hi
      else
        local a, z = base:match("^(%d+)%-(%d+)$")
        if a then rlo, rhi = tonumber(a), tonumber(z)
        else local n = tonumber(base); if n then rlo, rhi = n, n end end
      end
      if rlo and rhi and step >= 1 and value >= rlo and value <= rhi
         and ((value - rlo) % step == 0) then return true end
    end
  end
  return false
end

-- Does a 5-field cron ("min hour dom month dow") match a time table t =
-- {min, hour, day, month, wday}? wday is os.date's 1=Sun..7=Sat. Cron dow is
-- 0-6 (0=Sun, also 7=Sun). Standard rule: when BOTH dom and dow are restricted,
-- match if EITHER matches; otherwise AND. Pure.
function M.cronMatches(cron, t)
  local f = {}
  for w in tostring(cron or ""):gmatch("%S+") do f[#f + 1] = w end
  if #f ~= 5 then return false end
  if type(t) ~= "table" then return false end
  local minOk = cronFieldMatch(f[1], t.min, 0, 59)
  local hourOk = cronFieldMatch(f[2], t.hour, 0, 23)
  local monOk = cronFieldMatch(f[4], t.month, 1, 12)
  local domStar = (f[3]:gsub("%s", "") == "*")
  local dowStar = (f[5]:gsub("%s", "") == "*")
  local cronDow = (tonumber(t.wday) or 1) - 1  -- 0=Sun..6=Sat
  local domOk = cronFieldMatch(f[3], t.day, 1, 31)
  local dowOk = cronFieldMatch(f[5], cronDow, 0, 6)
             or (cronDow == 0 and cronFieldMatch(f[5], 7, 0, 7))  -- 7 = Sunday alias
  local dayOk
  if domStar and dowStar then dayOk = true
  elseif domStar then dayOk = dowOk
  elseif dowStar then dayOk = domOk
  else dayOk = domOk or dowOk end
  return minOk and hourOk and monOk and dayOk
end

-- The next epoch (>= the next whole minute after `now`) a cron matches, or nil if
-- none within ~366 days. Display-only (the board's "next run") -- the firing path
-- uses dueSchedules, which only checks the CURRENT minute. Pure (now injected).
function M.nextRunAt(cron, now)
  now = tonumber(now)
  if not now then return nil end
  local t = now - (now % 60) + 60  -- next whole minute
  local horizon = t + 366 * 86400
  while t <= horizon do
    local dt = os.date("*t", t)
    if M.cronMatches(cron, { min = dt.min, hour = dt.hour, day = dt.day, month = dt.month, wday = dt.wday }) then
      return t
    end
    t = t + 60
  end
  return nil
end

-- Schedules due to fire at `now`: enabled, and either a cron matching the CURRENT
-- minute (and not already fired this minute) or a oneShot whose `at` has passed and
-- never fired. Pure (now injected); the caller stamps lastFiredAt + deletes one-shots.
function M.dueSchedules(list, now)
  now = tonumber(now)
  local out = {}
  if not now or type(list) ~= "table" then return out end
  local dt = os.date("*t", now)
  local curMin = now - (now % 60)
  for _, s in ipairs(list) do
    if type(s) == "table" and s.enabled then
      local last = tonumber(s.lastFiredAt) or 0
      local due = false
      if s.kind == "oneShot" then
        local at = tonumber(s.at)
        due = at ~= nil and at <= now and last == 0
      elseif s.kind == "cron" then
        due = (last < curMin) and M.cronMatches(s.cron,
          { min = dt.min, hour = dt.hour, day = dt.day, month = dt.month, wday = dt.wday })
      end
      if due then out[#out + 1] = s end
    end
  end
  return out
end

-- Best-effort human rendering of a 5-field cron for the routine board. Pure.
function M.humanizeCron(cron)
  local f = {}
  for w in tostring(cron or ""):gmatch("%S+") do f[#f + 1] = w end
  if #f ~= 5 then return tostring(cron or "") end
  local mi, h, dom, mon, dow = f[1], f[2], f[3], f[4], f[5]
  local DOW = { ["0"] = "Sun", ["1"] = "Mon", ["2"] = "Tue", ["3"] = "Wed",
                ["4"] = "Thu", ["5"] = "Fri", ["6"] = "Sat", ["7"] = "Sun" }
  local function hhmm()
    local hn, mn = tonumber(h), tonumber(mi)
    return (hn and mn) and string.format("%02d:%02d", hn, mn) or nil
  end
  if mi == "*" and h == "*" and dom == "*" and mon == "*" and dow == "*" then return "every minute" end
  local everyN = mi:match("^%*/(%d+)$")
  if everyN and h == "*" and dom == "*" and mon == "*" and dow == "*" then return "every " .. everyN .. " min" end
  if mi == "0" and h == "*" and dom == "*" and mon == "*" and dow == "*" then return "hourly" end
  local t = hhmm()
  if t and dom == "*" and mon == "*" and dow == "*" then return "daily at " .. t end
  if t and dom == "*" and mon == "*" and DOW[dow] then return DOW[dow] .. " at " .. t end
  if t and tonumber(dom) and mon == "*" and dow == "*" then return "monthly on day " .. dom .. " at " .. t end
  return tostring(cron)
end

-- Pre-flight validator (L7): returns { ok, errors[] }. name + folder required; cron
-- needs 5 fields; oneShot needs a numeric `at`; unknown fields flagged.
function M.validateSchedule(rec)
  if type(rec) ~= "table" then return { ok = false, errors = { "not an object" } } end
  local errs = {}
  if agTrim(rec.name) == "" then errs[#errs + 1] = "missing required field: name" end
  local kind = tostring(rec.kind)
  if kind ~= "cron" and kind ~= "oneShot" then errs[#errs + 1] = "kind must be cron or oneShot"
  elseif kind == "cron" then
    local n = 0; for _ in tostring(rec.cron or ""):gmatch("%S+") do n = n + 1 end
    if n ~= 5 then errs[#errs + 1] = "cron must have 5 fields" end
  elseif kind == "oneShot" and tonumber(rec.at) == nil then
    errs[#errs + 1] = "oneShot needs an `at` epoch"
  end
  local action = rec.action == nil and "spawn" or tostring(rec.action)
  if not M.SCHEDULE_ACTIONS[action] then errs[#errs + 1] = "action must be spawn or digest" end
  -- a `spawn` routine needs a folder; a `digest` routine doesn't (it pushes a report)
  if action ~= "digest" and agTrim(rec.folder) == "" then
    errs[#errs + 1] = "missing required field: folder"
  end
  for k in pairs(rec) do
    if not M.SCHEDULE_FIELDS[k] then errs[#errs + 1] = "unknown field: " .. tostring(k) end
  end
  return { ok = #errs == 0, errors = errs }
end

local function scheduleNorm(rec)
  return {
    name = agTrim(rec.name), kind = tostring(rec.kind),
    cron = tplStr(rec.cron), at = tonumber(rec.at),
    folder = tplStr(rec.folder), editor = tplStr(rec.editor), provider = tplStr(rec.provider),
    model = tplStr(rec.model), permMode = tplStr(rec.permMode),
    prompt = tplStr(rec.prompt), templateRef = tplStr(rec.templateRef), agentRef = tplStr(rec.agentRef),
    enabled = rec.enabled == true,  -- default OFF (a routine must be explicitly enabled)
    tags = type(rec.tags) == "table" and rec.tags or nil,
    lastFiredAt = tonumber(rec.lastFiredAt),
    action = (rec.action == "digest") and "digest" or "spawn",  -- default: spawn a session
    digestHours = tonumber(rec.digestHours), pushTopic = tplStr(rec.pushTopic),
  }
end

-- Fail-safe load (mirrors agentLoad/ruleLoad): keep valid (normalized), drop bad
-- with reasons, dedupe by name. Returns {valid, errors}.
function M.scheduleLoad(state)
  local valid, errors, seen = {}, {}, {}
  for _, rec in ipairs(slist(state)) do
    local v = M.validateSchedule(rec)
    local nm = (type(rec) == "table") and agTrim(rec.name) or ""
    if not v.ok then
      errors[#errors + 1] = { name = nm ~= "" and nm or "(unnamed)", reason = table.concat(v.errors, "; ") }
    elseif seen[nm] then
      errors[#errors + 1] = { name = nm, reason = "duplicate name (kept first)" }
    else
      seen[nm] = true; valid[#valid + 1] = scheduleNorm(rec)
    end
  end
  return { valid = valid, errors = errors }
end

function M.scheduleList(state) return M.scheduleLoad(state).valid end

-- After a routine fires: stamp its lastFiredAt (cron) or REMOVE it (a oneShot
-- self-deletes after a delivered fire). Operates on the RAW state (preserves any
-- extra fields) so the persisted file isn't lossily normalized. Returns newState. Pure.
function M.scheduleMarkFired(state, name, now)
  local out, target = {}, agTrim(name)
  for _, s in ipairs(slist(state)) do
    if type(s) == "table" and agTrim(s.name) == target then
      if s.kind ~= "oneShot" then
        local c = {}; for k, v in pairs(s) do c[k] = v end
        c.lastFiredAt = tonumber(now)
        out[#out + 1] = c
      end  -- oneShot: dropped (self-delete)
    else
      out[#out + 1] = s
    end
  end
  return { schedules = out }
end

-- Backpressure: skip firing new routines when the live fleet is at/over `cap`
-- (cap <= 0 disables the limit). Pure.
function M.scheduleBackpressure(liveTiles, cap)
  cap = tonumber(cap) or 0
  if cap <= 0 then return false end
  return (tonumber(liveTiles) or 0) >= cap
end

-- ---- L7 routine-board CRUD + cron builder (UI layer) -----------------------
-- These power the routine board (Add/run-now/pause/resume) so routines no longer
-- have to be hand-edited in cc-schedules.json. All pure; the firing engine above
-- is untouched.

-- Assemble a 5-field cron from the Add-Routine picker state. Pure; HAND-MIRRORED
-- in the panel JS (`cronBuildJS`) for the live preview -- keep them in sync.
-- spec = { freq = minute|hour|day|week|month, every?, minute?, hour?, weekdays?[], dom? }.
-- Always returns a valid 5-field cron (validateSchedule/cronMatches accept it).
function M.cronBuild(spec)
  spec = type(spec) == "table" and spec or {}
  local function clamp(v, lo, hi, dflt)
    v = tonumber(v); if not v then return dflt end
    v = math.floor(v)
    if v < lo then return lo elseif v > hi then return hi else return v end
  end
  local freq = tostring(spec.freq or "day")
  local mi = clamp(spec.minute, 0, 59, 0)
  local hr = clamp(spec.hour, 0, 23, 9)
  if freq == "minute" then
    local n = clamp(spec.every, 1, 59, 5)
    return "*/" .. n .. " * * * *"
  elseif freq == "hour" then
    return mi .. " * * * *"
  elseif freq == "week" then
    local seen, days = {}, {}
    for _, d in ipairs(type(spec.weekdays) == "table" and spec.weekdays or {}) do
      local n = tonumber(d)
      if n and n >= 0 and n <= 6 and not seen[n] then seen[n] = true; days[#days + 1] = n end
    end
    table.sort(days)
    local dow = (#days > 0) and table.concat(days, ",") or "*"
    return mi .. " " .. hr .. " * * " .. dow
  elseif freq == "month" then
    local dom = clamp(spec.dom, 1, 31, 1)
    return mi .. " " .. hr .. " " .. dom .. " * *"
  else  -- day (default)
    return mi .. " " .. hr .. " * * *"
  end
end

-- Save a routine: validates (validateSchedule), replaces same-name in place,
-- else prepends; caps (oldest dropped). On a replace, carries forward the old
-- lastFiredAt unless the new record sets one -- so editing a routine via the
-- board can't resurface an already-fired oneShot or re-fire a cron this minute.
-- Returns newState, ok, errors. Mirrors agentPush.
function M.schedulePush(state, rec, cap)
  cap = tonumber(cap) or M.SCHEDULE_CAP
  rec = type(rec) == "table" and rec or {}
  local v = M.validateSchedule(rec)
  if not v.ok then return { schedules = M.scheduleList(state) }, false, v.errors end
  local entry = scheduleNorm(rec)
  local out, replaced = {}, false
  for _, s in ipairs(M.scheduleList(state)) do
    if s.name == entry.name then
      if entry.lastFiredAt == nil then entry.lastFiredAt = s.lastFiredAt end
      out[#out + 1] = entry; replaced = true
    else out[#out + 1] = s end
  end
  if not replaced then table.insert(out, 1, entry) end
  while #out > cap do table.remove(out) end
  return { schedules = out }, true
end

-- Delete a routine by name (no-op copy on miss).
function M.scheduleRemove(state, name)
  local out, target = {}, agTrim(name)
  for _, s in ipairs(M.scheduleList(state)) do
    if s.name ~= target then out[#out + 1] = s end
  end
  return { schedules = out }
end

-- Get one normalized routine by name, or nil.
function M.scheduleGet(state, name)
  local target = agTrim(name)
  for _, s in ipairs(M.scheduleList(state)) do
    if s.name == target then return s end
  end
  return nil
end

-- Toggle a routine's enabled flag (board pause/resume). Operates on the RAW
-- state (like scheduleMarkFired) so every field -- incl. lastFiredAt + any
-- hand-added extras -- rides through untouched. Pure.
function M.scheduleSetEnabled(state, name, on)
  local out, target = {}, agTrim(name)
  for _, s in ipairs(slist(state)) do
    if type(s) == "table" and agTrim(s.name) == target then
      local c = {}; for k, val in pairs(s) do c[k] = val end
      c.enabled = on == true
      out[#out + 1] = c
    else
      out[#out + 1] = s
    end
  end
  return { schedules = out }
end

-- Annotate the routine list for the board: each row gets a human-readable
-- schedule string (`human`) + the next epoch it'll fire (`nextRunAt`,
-- display-only -- the firing path uses dueSchedules). Pure (now injected).
function M.scheduleBoard(list, now)
  local out = {}
  for _, s in ipairs(type(list) == "table" and list or {}) do
    local row = {}
    for k, v in pairs(s) do row[k] = v end
    if s.kind == "oneShot" then
      row.human = "once"
      -- not yet fired -> its scheduled epoch; fired oneShots are gone from disk
      row.nextRunAt = (s.lastFiredAt == nil) and tonumber(s.at) or nil
    else
      row.human = M.humanizeCron(s.cron)
      row.nextRunAt = M.nextRunAt(s.cron, now)
    end
    out[#out + 1] = row
  end
  return out
end

-- ---- L5: detail-panel tab strip ------------------------------------------
-- Canonical ordered tab list for the detail panel. Injected into the panel JS
-- as __DETAIL_TABS__ (like __BULK_RULES__) so the strip and the pure state
-- normalizer share ONE source of truth -- no drift. 'activity' is the default
-- and can NEVER be unpinned (it's the always-available fallback view).
--
-- ADDING A TAB -- checklist (most sites are data-driven and need NO edit):
--   auto-flows from this list (no change): renderTabBar (built from
--     __DETAIL_TABS__), M.detailTabIds, M.normalizeTabState + normalizeTabStateJS.
--   MANUAL edits required:
--     (a) a matching <div class="d-panel" data-tab="ID"> in the HTML block --
--         the strip only toggles .active on panels that already exist;
--     (b) for a LAZY/expensive tab, a `detail-ID` action in the bridge handler
--         + a maybeLoadActiveTab case (see how 'timeline'/'changes' wire a
--         detail-* action -> ccDetail* callback, stale-guarded);
--     (c) a per-id branch in maybeLoadActiveTab only if it needs special load
--         behavior (cheap always-rendered tabs need nothing).
M.DETAIL_TABS = {
  { id = "activity",   label = "Activity" },
  { id = "transcript", label = "Transcript" },  -- F4: recent conversation peek + search
  { id = "rewind",     label = "Rewind" },
  { id = "decisions",  label = "Decisions" },
  { id = "usage",      label = "Usage" },
  { id = "changes",    label = "Changes" },
  { id = "stories",    label = "User Stories" },  -- gated: shows only when spec/product/user-stories.md exists
  { id = "subagents",  label = "Agents" },
  { id = "queue",      label = "Queue" },
}
M.DETAIL_TAB_DEFAULT = "activity"

-- Set of valid tab ids (derived once from M.DETAIL_TABS, or an injected list for
-- tests). Returns a { [id]=true } map.
function M.detailTabIds(tabs)
  local set = {}
  for _, t in ipairs(tabs or M.DETAIL_TABS) do
    if type(t) == "table" and t.id then set[t.id] = true
    elseif type(t) == "string" then set[t] = true end
  end
  return set
end

-- normalizeTabState(raw [, tabs]) -> { selectedTab, unpinned }
-- Sanitize a stored/over-the-wire tab-state blob so the panel can trust it:
--   * unpinned: keep only entries whose id is a KNOWN tab AND not the default
--     (the default tab can never be hidden); returned as a { [id]=true } map.
--   * selectedTab: kept only if it's a known tab that is NOT unpinned (so the
--     active tab is always visible); otherwise falls back to the default.
-- Pure + deterministic. Mirrored by normalizeTabStateJS in the panel JS.
function M.normalizeTabState(raw, tabs)
  local valid = M.detailTabIds(tabs)
  local def = M.DETAIL_TAB_DEFAULT
  raw = type(raw) == "table" and raw or {}

  local unpinned = {}
  local rawUnp = raw.unpinned
  if type(rawUnp) == "table" then
    -- canonical form is a { id=true } map (the only shape the panel JS ever
    -- writes); keep only known, non-default ids.
    for id, v in pairs(rawUnp) do
      if v == true and type(id) == "string" and valid[id] and id ~= def then
        unpinned[id] = true
      end
    end
  end

  local sel = raw.selectedTab
  if type(sel) ~= "string" or not valid[sel] or unpinned[sel] then
    sel = def
  end
  return { selectedTab = sel, unpinned = unpinned }
end

-- ---- L5: per-session git Changes tab -------------------------------------
-- Split a NUL-separated string (git's -z output) with a plain find -- no
-- pattern-class ambiguity, works on any byte-clean Lua string.
local function splitNul(s)
  local out, start = {}, 1
  while true do
    local p = s:find("\0", start, true)
    if not p then if start <= #s then out[#out + 1] = s:sub(start) end break end
    out[#out + 1] = s:sub(start, p - 1)
    start = p + 1
  end
  return out
end

-- parseGitStatus(out) : parse `git status --porcelain=v1 -z` into a normalized
-- file list + a per-class summary. Pure. The -z format is NUL-terminated records
-- `XY<space>path`; renamed/copied records are followed by an extra NUL token
-- holding the ORIGINAL path. Returns { files = {{status,mark,cls,path,orig}}, summary }.
function M.parseGitStatus(out)
  local sum = { modified = 0, added = 0, deleted = 0, renamed = 0, untracked = 0, total = 0 }
  local files = {}
  if type(out) ~= "string" or out == "" then return { files = files, summary = sum } end
  local toks = splitNul(out)
  local i = 1
  while i <= #toks do
    local entry = toks[i]; i = i + 1
    if entry ~= nil and #entry >= 3 then
      local code = entry:sub(1, 2)
      local path = entry:sub(4)            -- skip the space at position 3
      local x, y = code:sub(1, 1), code:sub(2, 2)
      local orig = nil
      if x == "R" or x == "C" or y == "R" or y == "C" then
        orig = toks[i]; i = i + 1           -- the next token is the original path
      end
      local mark, cls
      if code == "??" then
        mark, cls = "?", "untracked"; sum.untracked = sum.untracked + 1
      else
        local m = (x ~= " " and x ~= "?") and x or y
        if m == "M" or m == "U" then mark, cls = "M", "mod"; sum.modified = sum.modified + 1
        elseif m == "A" then mark, cls = "A", "add"; sum.added = sum.added + 1
        elseif m == "D" then mark, cls = "D", "del"; sum.deleted = sum.deleted + 1
        elseif m == "R" then mark, cls = "R", "ren"; sum.renamed = sum.renamed + 1
        elseif m == "C" then mark, cls = "C", "ren"; sum.renamed = sum.renamed + 1
        else mark, cls = (m ~= " " and m or "?"), "other" end
      end
      files[#files + 1] = { status = code, mark = mark, cls = cls, path = path, orig = orig }
      sum.total = sum.total + 1
    end
  end
  return { files = files, summary = sum }
end

-- Resolve a detail-diff request against the authoritative file set from the last
-- parseGitStatus (the security boundary: a bridge-supplied path that ISN'T a real
-- status entry is refused, so the --no-index fallback can't read an arbitrary
-- file). `allowed` maps path -> orig|false (orig present for a rename). Returns
-- (ok, orig): ok=false when the path isn't in the set; orig is the rename source
-- string or nil. Pure -- unit-tested directly (the source-grep can't exercise it).
function M.resolveDiffTarget(allowed, file)
  if type(allowed) ~= "table" or allowed[file] == nil then return false, nil end
  local orig = allowed[file]
  return true, (orig ~= false and orig ~= "" and orig) or nil
end

-- ---- L5: export session archive ------------------------------------------
-- Slug a string into a filesystem-safe fragment for the export folder name, in
-- two passes (the parens truncate each gsub's (string,count) to the string):
--   squeezeSep: map unsafe-char runs -> '-', collapse + trim hyphens. Keeps '.'
--     (it's in the allowed set), so dot hygiene must run AFTER this.
--   dotHygiene: no leading/trailing/repeated dots.
local function squeezeSep(x) return (x:gsub("[^%w%._%-]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")) end
local function dotHygiene(x) return (x:gsub("%.+", "."):gsub("^%.", ""):gsub("%.$", "")) end  -- run AFTER squeezeSep (it preserves '.')
local function exportSlug(s)
  local out = dotHygiene(squeezeSep(tostring(s or "")))
  if out == "" then out = "session" end
  return out:sub(1, 60)
end

-- Resolve a collision-free name by appending -2, -3, ... while `exists(name)` is
-- true. Pure (existence injected) so the export uniquify math is unit-testable
-- without touching the filesystem.
function M.uniquifyName(base, exists)
  if type(exists) ~= "function" then return base end
  local n, cand = 1, base
  while exists(cand) do n = n + 1; cand = base .. "-" .. n end
  return cand
end

-- sessionExportBasename(item, now) : a unique, filesystem-safe export folder name
-- like "session-my-label-20260615T143000Z". Pure (now injected; UTC stamp).
function M.sessionExportBasename(item, now)
  item = type(item) == "table" and item or {}
  local label = item.label or item.name or item.projectKey or item.key or "session"
  local stamp = now and os.date("!%Y%m%dT%H%M%SZ", tonumber(now)) or "export"
  return "session-" .. exportSlug(label) .. "-" .. stamp
end

-- Per-session activity tally from this session's ledger events (pure).
function M.sessionExportCounters(events)
  local c = { prompts = 0, toolRequests = 0, approvals = 0, denials = 0,
              errors = 0, escalations = 0, total = 0 }
  for _, e in ipairs(type(events) == "table" and events or {}) do
    c.total = c.total + 1
    local t = e.type
    if t == "prompt" then c.prompts = c.prompts + 1
    elseif t == "tool_request" then c.toolRequests = c.toolRequests + 1
    elseif t == "decision" then
      if e.outcome == "deny" then c.denials = c.denials + 1 else c.approvals = c.approvals + 1 end
    elseif t == "error" then c.errors = c.errors + 1
    elseif t == "escalation" then c.escalations = c.escalations + 1 end
  end
  return c
end

-- sessionExportMeta(item, events, opts) : assemble the meta.json DTO. Pure -- the
-- timestamp + transcript filename arrive via opts. Carries label/provider/model +
-- lineage (respawn/clear churn) + a per-session activity tally. Deliberately NOT
-- prompt bodies: those live in the copied transcript (the operator's own data).
function M.sessionExportMeta(item, events, opts)
  item = type(item) == "table" and item or {}
  opts = type(opts) == "table" and opts or {}
  local meta = {
    schema = "cc-session-export/1",
    label = item.label or item.name,
    projectKey = item.projectKey,
    sessionId = item.session_id,
    cwd = item.cwd,
    provider = item.provider or item.providerId,
    model = item.model,
    status = item.status,
    exportedAt = opts.exportedAt,
    transcript = opts.transcriptName,
  }
  if item.projectKey and type(events) == "table" then
    meta.lineage = M.projectLineage(events, item.projectKey, { sinceTs = opts.sinceTs or 0 })
  end
  local sid = item.session_id
  if sid and type(events) == "table" then
    meta.activity = M.sessionExportCounters(M.filterLedger(events, { session = sid }))
  end
  return meta
end

-- ---- L5: post-run self-summary callback ----------------------------------
-- A review-first prompt Shepherd OPTIONALLY types into a session on a fresh done
-- edge (off by default). Framed strictly as a status note for the human watching,
-- NOT a new task -- and it explicitly forbids further edits so it can't run away.
-- Sibling to improvePrompt / auditReviewPrompt. Pure (no transcript interpolation).
function M.summaryPrompt(item)
  return "Before we move on, jot a brief self-summary of the turn you just finished, "
    .. "for the log the human is watching: (1) what you changed or accomplished, "
    .. "(2) anything still open, blocked, or uncertain, and (3) the single most useful "
    .. "next step. A few lines is plenty. Do NOT make further changes or start new "
    .. "work -- just summarize what already happened."
end

-- Is this tile a valid self-summary target? done, real local session, not stale.
function M.shouldSummarize(item)
  if type(item) ~= "table" then return false end
  if item.status ~= "done" then return false end
  if item.remote or item.stale then return false end
  if not item.session_id or tostring(item.session_id) == "" then return false end
  return true
end

-- Advance self-summary bookkeeping for one tile per tick; returns whether to type
-- the summary prompt now. Two key->true guards: `pending` is armed here on a fire;
-- the dashboard promotes it to `fired` only when the paste lands (else clears it to
-- retry) via M.promoteSummary. The skip path checks both. Truth table:
--   item : { key, status, session_id, remote, stale };  opts : { enabled, prevStatus }
--   prev      status         pending/fired   -> action
--   not done  done           neither         -> FIRE (if enabled & eligible), arm pending
--   not done  done           either set      -> skip (summary's own done), clear both
--   *         not done/work   *               -> clear both (a later real done can summarize)
--   done      done           *               -> no fresh edge, no-op
function M.stepSelfSummary(state, item, opts)
  state = state or {}; state.fired = state.fired or {}; state.pending = state.pending or {}
  opts = opts or {}; item = item or {}
  local key = item.key
  if not key then return { fire = false } end
  local function clear() state.fired[key] = nil; state.pending[key] = nil end
  local prev = opts.prevStatus
  local freshDone = (prev ~= nil and prev ~= "done" and item.status == "done")
  if not freshDone then
    if item.status ~= "done" and item.status ~= "working" then clear() end
    return { fire = false }
  end
  if state.fired[key] or state.pending[key] then  -- summary's own done (landed or in-flight) -> skip
    clear()
    return { fire = false }
  end
  local fire = (opts.enabled == true) and M.shouldSummarize(item)
  if fire then state.pending[key] = true end      -- the dashboard promotes pending->fired ON DELIVERY
  return { fire = fire }
end

-- Promote a self-summary guard after a delivery ATTEMPT (the dashboard calls this
-- from the dispatchSerialized callback): pending->fired when the paste LANDED (so
-- the summary's own done is skipped), else just clear pending so the next real done
-- retries instead of being orphaned. Pure -- behavior-tested directly.
function M.promoteSummary(state, key, landed)
  state = state or {}; state.fired = state.fired or {}; state.pending = state.pending or {}
  if not key then return end
  if landed then state.fired[key] = true end
  state.pending[key] = nil
end

-- Pure one-step decision for the official-usage poll, given the previous fetch status
-- `prev`, this fetch's HTTP `status`, and whether the body decoded (`bodyOk`). Returns
-- (shouldLog, recovered, newPrev). The non-obvious rule: a 200 with an UNUSABLE body
-- (garbage/undecodable/empty) is a NO-OP -- prev is left unchanged so a later good 200 still
-- counts as the recovery (recovery is gated on a decodable payload, not status 200 alone).
function M.officialUsageStep(prev, status, bodyOk)
  if status == 200 then
    if not bodyOk then return false, false, prev end   -- garbage/empty 200: don't flip prev
    return false, (prev ~= nil and prev ~= 200), 200
  end
  if status ~= prev then return true, false, status end
  return false, false, prev
end

-- ---- L5: PR/MR status per tile (gh-backed, status-only) -------------------
-- Parse `gh pr view --json number,state,url,title,isDraft` output (a single JSON
-- object for the current branch's PR) into a normalized { number, state, url,
-- title }. state is lowercased (open|merged|closed|draft). nil on empty / no PR /
-- garbage. Pure (decode via the injected M.json).
function M.parsePrStatus(jsonStr)
  if type(jsonStr) ~= "string" or not jsonStr:find("{", 1, true) then return nil end
  local ok, j = pcall(function() return M.json.decode(jsonStr) end)
  if not ok or type(j) ~= "table" or j.number == nil then return nil end
  local number = tonumber(j.number)   -- gh's --json number is an int, but a present-but-
  if number == nil then return nil end -- non-numeric value (decoded "x"/true) would null the
                                       -- badge (prBadge guards number==nil) -> treat as no PR
  local state = tostring(j.state or ""):lower()
  if j.isDraft == true and state == "open" then state = "draft" end
  if state == "" then state = "unknown" end   -- never a trailing-space badge / empty pr- class
  return {
    number = number,
    state = state,
    url = (type(j.url) == "string") and j.url or nil,
    title = (type(j.title) == "string") and j.title or nil,
  }
end

-- Compact tile badge for a parsed PR status, e.g. "PR #123 merged". nil if no PR.
function M.prBadge(pr)
  if type(pr) ~= "table" or pr.number == nil then return nil end
  return "PR #" .. tostring(pr.number) .. " " .. tostring(pr.state or "")
end

-- True only for an http(s) url WITH a host -- the open-url scheme guard, so a crafted PR
-- url can't smuggle a file:// / javascript: / data: scheme into hs.urlevent.openURL. The
-- scheme is matched case-INSENsitively (RFC 3986 schemes are; only the scheme, so path/query
-- case is untouched), and `[^%s/]` requires a non-whitespace host char (rejecting "https://",
-- "https:///path", and "https:// x"). Pure.
function M.isOpenableUrl(url)
  return type(url) == "string" and url:match("^[Hh][Tt][Tt][Pp][Ss]?://[^%s/]") ~= nil
end

-- ---- L5: gh PR-status poll planner (hung-task aware) ----------------------
-- Pure decision for whether to (re)launch a gh PR-status poll for a repo root. cached =
-- { ts, data=<pr|false|nil> } or nil; inflight = { ts } or nil (the in-flight task latch);
-- now = epoch. opts: ttl (full TTL once we have data, default 180), retryTtl (short window
-- while data is still nil, default 20), deadline (an in-flight task older than this is
-- presumed HUNG, default retryTtl). The hung check runs BEFORE the cache-freshness skip, so
-- a refresh poll that hangs while we already have data is reclaimed at `deadline` rather than
-- held for the full cache TTL (the skip would otherwise dominate). killStale=true means the
-- stale in-flight task must be TERMINATED before the fresh poll -- else a hung gh whose
-- callback never fires latches the slot forever and the retry is dead code (the bug both
-- leaderboard reviews flagged). Pure (injected `now`).
function M.prPollPlan(cached, inflight, now, opts)
  opts = opts or {}
  local effTtl = (cached and cached.data ~= nil) and (opts.ttl or 180) or (opts.retryTtl or 20)
  local hungDeadline = opts.deadline or opts.retryTtl or 20
  -- a hung in-flight task is reclaimed even within the cache window
  if inflight and (now - inflight.ts) >= hungDeadline then return { act = "start", killStale = true } end
  -- cache still fresh -> nothing to do
  if cached and (now - cached.ts) < effTtl then return { act = "skip", killStale = false } end
  -- a still-alive in-flight poll (age < deadline) -> don't pile on a second
  if inflight then return { act = "skip", killStale = false } end
  return { act = "start", killStale = false }
end

-- True iff `inflight` (the in-flight poll latch {task=...}) is non-nil and still holds
-- `task` -- i.e. this callback still owns its root's slot, so its result should be painted.
-- False once a stale-kill replaced the latch with a newer poll, or a vanished-root reap
-- cleared it: the late (often SIGTERM'd) callback must then DROP its result rather than
-- clobber the fresh poll's data or re-populate a reaped root. Pure reference comparison.
function M.prCallbackOwns(inflight, task)
  return inflight ~= nil and inflight.task == task
end

-- Prune every entry of `cache` whose key is NOT present (truthy) in `liveKeys`, in place
-- (so existing references stay valid), returning `cache`. The shared shape behind the
-- per-key refresh caches (taskStart / loopAlerted / autoApproveFired / summaryState.* /
-- gitChangeFiles / prStatusByRoot): a vanished tile or root must never leave an orphan, so
-- the unbounded-growth guard is single-sourced here instead of re-written per table. A
-- non-table `cache` is returned untouched (never crashes a reap over an uninitialized one).
function M.reapUnbacked(cache, liveKeys)
  if type(cache) ~= "table" then return cache end
  liveKeys = liveKeys or {}
  for k in pairs(cache) do
    if not liveKeys[k] then cache[k] = nil end
  end
  return cache
end

-- Newest auto-approve decision ts for a session (an "automated allow" = an `allow`
-- decision whose `by` is anything other than the manual "human"; mirrors the
-- automated-decision test at the narrative builder). nil when there is none. Used
-- by the optional onAutoApproved banner edge. Pure.
function M.newestAutoApprove(events, sid)
  if not sid or tostring(sid) == "" then return nil end
  local newest = nil
  for _, e in ipairs(type(events) == "table" and events or {}) do
    if type(e) == "table" and e.type == "decision" and e.session_id == sid
       and e.outcome == "allow" and e.by ~= nil and e.by ~= "human" then
      local ts = tonumber(e.ts) or 0
      if not newest or ts > newest then newest = ts end
    end
  end
  return newest
end

-- ============================================================================
-- ============================================================================
-- DR4: run quality scoring + regression trend, computed from the audit ledger
-- (the empirical-scoring direction). `runScore` is a 0-100 heuristic for one
-- session: starts at 100 and subtracts for the rough edges (api errors, denied
-- tools, loop episodes, forced respawns). `scoreTrend` scores each session over
-- time and flags a downward run. Weights hand-tunable via cc-config `score.weights`.
-- Pure (no clock, no IO). A deeper LLM-as-a-judge pass can reuse the paste path.
-- ============================================================================
function M.runScore(events, sid, opts)
  opts = opts or {}
  local w = type(opts.weights) == "table" and opts.weights or {}
  local W = { error = tonumber(w.error) or 18, deny = tonumber(w.deny) or 6,
              loop = tonumber(w.loop) or 12, respawn = tonumber(w.respawn) or 14 }
  local n = { error = 0, deny = 0, loop = 0, respawn = 0, allow = 0, events = 0 }
  for _, e in ipairs(type(events) == "table" and events or {}) do
    if type(e) == "table" and (sid == nil or e.session_id == sid) then
      n.events = n.events + 1
      local t = e.type
      if t == "error" then n.error = n.error + 1
      elseif t == "loop" then n.loop = n.loop + 1
      elseif t == "auto_respawn" then n.respawn = n.respawn + 1
      elseif t == "decision" then
        if e.outcome == "deny" then n.deny = n.deny + 1
        elseif e.outcome == "allow" then n.allow = n.allow + 1 end
      end
    end
  end
  local score = 100 - n.error * W.error - n.deny * W.deny - n.loop * W.loop - n.respawn * W.respawn
  if score < 0 then score = 0 elseif score > 100 then score = 100 end
  return { score = score, factors = n, hadData = n.events > 0 }
end

-- Per-session run scores oldest->newest (by each session's latest event ts) + a
-- regression flag: the last `window` (default 3) scores are non-increasing AND the
-- drop across that window is >= `drop` (default 12). Pure.
function M.scoreTrend(events, opts)
  opts = opts or {}
  local window = tonumber(opts.window) or 3
  local drop = tonumber(opts.drop) or 12
  local bySid, lastTs = {}, {}
  for _, e in ipairs(type(events) == "table" and events or {}) do
    if type(e) == "table" and e.session_id and e.session_id ~= "" then
      local sid = e.session_id
      bySid[sid] = bySid[sid] or {}
      bySid[sid][#bySid[sid] + 1] = e
      local ts = tonumber(e.ts) or 0
      if not lastTs[sid] or ts > lastTs[sid] then lastTs[sid] = ts end
    end
  end
  local series = {}
  for sid, evs in pairs(bySid) do
    local r = M.runScore(evs, sid, opts)
    series[#series + 1] = { sid = sid, score = r.score, ts = lastTs[sid] or 0 }
  end
  table.sort(series, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
  local regression = false
  if #series >= window then
    regression = true
    local startIdx = #series - window + 1
    for i = startIdx + 1, #series do
      if series[i].score > series[i - 1].score then regression = false; break end
    end
    if regression and (series[startIdx].score - series[#series].score) < drop then regression = false end
  end
  return { series = series, regression = regression }
end

-- ============================================================================
-- DR5: dollar estimate for the fleet token footer. Default Anthropic API LIST
-- prices in $ per MILLION tokens (cache-write = the 5-minute-TTL rate, 1.25x input;
-- cache-read ≈ 0.1x input). Subscription cost is flat, so this is an "est. API-
-- equivalent" figure; gateway/local models have unknown pricing and are skipped.
-- Hand-tunable via cc-config `pricing.<family>`. Source: Anthropic pricing
-- (Opus 4.x 5/25, Sonnet 4.6 3/15, Haiku 4.5 1/5, Fable 5 10/50), 2026-06-18.
-- ============================================================================
M.PRICING = {
  opus   = { input = 5.0,  output = 25.0, cacheWrite = 6.25, cacheRead = 0.50 },
  sonnet = { input = 3.0,  output = 15.0, cacheWrite = 3.75, cacheRead = 0.30 },
  haiku  = { input = 1.0,  output = 5.0,  cacheWrite = 1.25, cacheRead = 0.10 },
  fable  = { input = 10.0, output = 50.0, cacheWrite = 12.5, cacheRead = 1.00 },
}

-- Map a model id to its price FAMILY (opus/sonnet/haiku/fable), or nil for a
-- non-Anthropic / unknown model (gateway/local pricing is unknown). Pure.
function M.priceFamily(model)
  local m = tostring(model or ""):lower()
  if m:find("opus", 1, true) then return "opus" end
  if m:find("sonnet", 1, true) then return "sonnet" end
  if m:find("haiku", 1, true) then return "haiku" end
  if m:find("fable", 1, true) or m:find("mythos", 1, true) then return "fable" end
  return nil
end

-- The price entry for a model: cc-config `pricing.<family>` overrides merged over
-- the default, or nil for an unpriced model. Pure.
function M.priceFor(model, pricing)
  local fam = M.priceFamily(model)
  if not fam then return nil end
  local base = M.PRICING[fam]
  local over = type(pricing) == "table" and pricing[fam] or nil
  if type(over) ~= "table" then return base end
  return {
    input      = tonumber(over.input) or base.input,
    output     = tonumber(over.output) or base.output,
    cacheWrite = tonumber(over.cacheWrite) or base.cacheWrite,
    cacheRead  = tonumber(over.cacheRead) or base.cacheRead,
  }
end

-- Estimate $ for a per-model usage map { <model> = {input, output, cacheRead,
-- cacheCreate} }. Prices Anthropic families only -> { usd, priced (any matched),
-- unpriced = {model,…} }. Pure.
function M.estimateCost(byModel, pricing)
  local usd, priced, unpriced = 0, false, {}
  for model, u in pairs(type(byModel) == "table" and byModel or {}) do
    local p = type(u) == "table" and M.priceFor(model, pricing) or nil
    if p then
      priced = true
      usd = usd
        + (tonumber(u.input) or 0)       / 1e6 * p.input
        + (tonumber(u.output) or 0)      / 1e6 * p.output
        + (tonumber(u.cacheCreate) or 0) / 1e6 * p.cacheWrite
        + (tonumber(u.cacheRead) or 0)   / 1e6 * p.cacheRead
    elseif type(u) == "table" then
      unpriced[#unpriced + 1] = tostring(model)
    end
  end
  return { usd = usd, priced = priced, unpriced = unpriced }
end

-- F7 (cost analytics): aggregate durable `usage_snapshot` ledger events (each a
-- CUMULATIVE per-session reading written periodically by FX.writeUsageSnapshots) into a
-- fleet cost summary -- the LATEST snapshot per session, summed. Pure; the dashboard reads
-- the ledger and the Cost overlay renders this.
function M.costSummary(events)
  local latest = {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" and e.type == "usage_snapshot" and e.session_id then
      local cur = latest[e.session_id]
      if not cur or (tonumber(e.ts) or 0) >= (tonumber(cur.ts) or 0) then latest[e.session_id] = e end
    end
  end
  local sum = { sessions = 0, real = 0, input = 0, output = 0, cacheRead = 0, cacheCreate = 0, usd = 0, perSession = {} }
  for sid, e in pairs(latest) do
    sum.sessions = sum.sessions + 1
    sum.real = sum.real + (tonumber(e.real) or 0)
    sum.input = sum.input + (tonumber(e.input) or 0)
    sum.output = sum.output + (tonumber(e.output) or 0)
    sum.cacheRead = sum.cacheRead + (tonumber(e.cacheRead) or 0)
    sum.cacheCreate = sum.cacheCreate + (tonumber(e.cacheCreate) or 0)
    sum.usd = sum.usd + (tonumber(e.estCostUsd) or 0)
    sum.perSession[#sum.perSession + 1] = { session_id = sid, name = e.name, projectKey = e.projectKey,
      model = e.model, real = tonumber(e.real) or 0, usd = tonumber(e.estCostUsd) or 0 }
  end
  table.sort(sum.perSession, function(a, b) return a.usd > b.usd end)
  return sum
end

-- Daily cost/token series from the cumulative snapshots: for each day, the sum over
-- sessions of (cumulative-at-end-of-day - cumulative-at-end-of-previous-day). A drop
-- (transcript compaction/reset) clamps that session's delta to 0 for the day rather than
-- going negative. opts.tzOffset (seconds east of UTC) buckets by LOCAL day; opts.now +
-- opts.days bound the window. Returns ascending { dayEpoch, real, usd } rows. Pure.
function M.costSeries(events, opts)
  opts = (type(opts) == "table") and opts or {}
  local days = math.max(1, math.floor(tonumber(opts.days) or 14))
  local tz = tonumber(opts.tzOffset) or 0
  local now = tonumber(opts.now) or 0
  local function dayOf(ts) return math.floor(((tonumber(ts) or 0) + tz) / 86400) end
  local today = dayOf(now)
  local startDay = today - days + 1
  local bySession = {}
  for _, e in ipairs(events or {}) do
    if type(e) == "table" and e.type == "usage_snapshot" and e.session_id then
      bySession[e.session_id] = bySession[e.session_id] or {}
      local g = bySession[e.session_id]
      g[#g + 1] = { ts = tonumber(e.ts) or 0, real = tonumber(e.real) or 0,
                    usd = tonumber(e.estCostUsd) or 0, day = dayOf(e.ts) }
    end
  end
  local realByDay, usdByDay = {}, {}
  for d = startDay, today do realByDay[d] = 0; usdByDay[d] = 0 end
  for _, snaps in pairs(bySession) do
    table.sort(snaps, function(a, b) return a.ts < b.ts end)
    local function cumAt(d)
      local real, usd = 0, 0
      for _, s in ipairs(snaps) do
        if s.day <= d then real, usd = s.real, s.usd else break end
      end
      return real, usd
    end
    local prevReal, prevUsd = cumAt(startDay - 1)
    for d = startDay, today do
      local cr, cu = cumAt(d)
      local dr = cr - prevReal; if dr < 0 then dr = 0 end
      local du = cu - prevUsd; if du < 0 then du = 0 end
      realByDay[d] = realByDay[d] + dr
      usdByDay[d] = usdByDay[d] + du
      prevReal, prevUsd = cr, cu
    end
  end
  local out = {}
  for d = startDay, today do
    out[#out + 1] = { dayEpoch = d * 86400 - tz, real = realByDay[d], usd = usdByDay[d] }
  end
  return out
end

-- ============================================================================
-- Custom in-app screen lock: salted-hash password. NEVER stores plaintext. The
-- hasher (hs.hash.SHA256 in prod, a fake in tests) is injected so the salt+compare
-- logic is pure and testable; the FX layer owns the real hash + cc-lock.json IO.
-- ============================================================================

-- The exact string that gets hashed: salt + ":" + password. Pure.
function M.lockSaltedInput(salt, pw)
  return tostring(salt or "") .. ":" .. tostring(pw or "")
end

-- Build a stored record { salt, hash } for a new password. nil if no hasher. Pure.
function M.lockRecord(salt, pw, hasher)
  if type(hasher) ~= "function" then return nil end
  return { salt = tostring(salt or ""), hash = hasher(M.lockSaltedInput(salt, pw)) }
end

-- Verify a typed `input` against a stored { salt, hash } record. Pure.
function M.lockVerify(record, input, hasher)
  if type(record) ~= "table" or not record.hash or type(hasher) ~= "function" then return false end
  return hasher(M.lockSaltedInput(record.salt, input)) == record.hash
end

-- DR1/DR2: Subagent fan-out trace + background-activity indicator.
-- Claude Code writes one transcript per spawned subagent BESIDE the session
-- transcript: …/projects/<ENC>/<sessionUuid>/subagents/agent-<id>.jsonl (the
-- first line carries `agentId` + a human-ish `slug` derived from the agent's
-- first prompt, e.g. "do-a-full-scan-sunny-panda"), plus per-Workflow fleets
-- under …/subagents/workflows/wf_<id>/agent-*.jsonl. These pure helpers
-- structure FX-provided file descriptors; the FX layer owns the directory read.
-- ============================================================================

-- The subagents directory for a session, derived from its transcript_path
-- (…/<sessionUuid>.jsonl -> …/<sessionUuid>/subagents). nil without a path.
function M.subagentsDir(transcriptPath)
  if type(transcriptPath) ~= "string" then return nil end
  local base = transcriptPath:match("^(.*)%.jsonl$")
  if not base or base == "" then return nil end
  return base .. "/subagents"
end

-- Parse a subagent transcript's FIRST line -> { agentId, slug, prompt }. nil for
-- non-JSON / no agentId. The slug is an auto-generated fleet name; `prompt` is the
-- agent's first user message (the actual task it was handed) -- a much better label,
-- since workflow agents all share a random slug ("great-prancy-hippo").
function M.subagentMeta(firstLine)
  if type(firstLine) ~= "string" or not firstLine:find("^%s*{") then return nil end
  local okj, obj = pcall(function() return M.json.decode(firstLine) end)
  if not okj or type(obj) ~= "table" then return nil end
  local id = obj.agentId or obj.agent_id
  if not id or tostring(id) == "" then return nil end
  local slug = obj.slug
  -- The first line is the agent's first user message; pull its text as the prompt.
  -- content is either a bare string or an array of blocks -- take the first text block.
  local prompt
  local msg = obj.message
  if type(msg) == "table" then
    local c = msg.content
    if type(c) == "string" then prompt = c
    elseif type(c) == "table" then
      for _, blk in ipairs(c) do
        if type(blk) == "table" and blk.type == "text" and type(blk.text) == "string" and blk.text ~= "" then
          prompt = blk.text; break
        end
      end
    end
  end
  return { agentId = tostring(id), slug = (type(slug) == "string" and slug ~= "") and slug or nil,
           prompt = (type(prompt) == "string" and prompt ~= "") and prompt or nil }
end

-- A display label for a subagent row. Prefers the agent's first PROMPT (the real
-- task) -- collapsed to one line and truncated -- because the auto-slug is often a
-- random fleet name shared across a whole Workflow fan-out. Falls back to a humanized
-- slug, then a short agentId. Pure.
function M.subagentLabel(slug, agentId, prompt)
  if type(prompt) == "string" then
    local s = prompt:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
    if #s > 80 then s = s:sub(1, 80):gsub("%s+%S*$", "") .. "…" end
    if s ~= "" then return s end
  end
  if type(slug) == "string" and slug ~= "" then
    return (slug:gsub("%-+", " "))
  end
  local id = tostring(agentId or "")
  return id ~= "" and ("agent " .. id:sub(1, 8)) or "subagent"
end

-- Validate a subagent file name supplied by the client before it's joined onto the
-- session's subagents dir (the drill-in security boundary): agent-<id>.jsonl, or one
-- workflows/wf_<id>/agent-<id>.jsonl level. Rejects traversal / absolute paths. Pure.
function M.subagentNameOk(name)
  if type(name) ~= "string" or name == "" then return false end
  if name:find("%.%.") or name:find("^/") then return false end
  if name:match("^agent%-%w+%.jsonl$") then return true end
  if name:match("^workflows/wf[_%-][%w_%-]+/agent%-%w+%.jsonl$") then return true end
  return false
end

-- Structure FX-provided subagent file descriptors into a fan-out tree.
-- `files` = list of { name, mtime, firstLine?, tail? } where `name` is the path
-- RELATIVE to the subagents dir (workflow agents look like
-- "workflows/wf_<id>/agent-<x>.jsonl"). opts.activeWindow (default 45s): an
-- mtime within now-window => "running". Returns { agents = { {agentId, slug,
-- label, kind, wfId?, mtime, running, lastLine} (newest first) }, count,
-- runningCount, active, workflows = { wfId -> {running, count} } }.
function M.subagentTree(files, now, opts)
  opts = opts or {}
  now = tonumber(now) or 0
  local win = tonumber(opts.activeWindow) or 45
  local out = { agents = {}, count = 0, runningCount = 0, active = false, workflows = {} }
  for _, f in ipairs(type(files) == "table" and files or {}) do
    local name = type(f) == "table" and f.name
    if type(name) == "string" and name:match("agent%-[^/]+%.jsonl$") then
      local wfId = name:match("workflows/(wf[_%-][%w_%-]+)/")
      local meta = f.firstLine and M.subagentMeta(f.firstLine) or nil
      local agentId = (meta and meta.agentId) or name:match("(agent%-%w+)%.jsonl$") or name
      local slug = meta and meta.slug
      local mtime = tonumber(f.mtime) or 0
      local running = (now > 0) and (now - mtime <= win) or false
      local lastLine = f.tail and M.transcriptSnippet(f.tail, opts.snippetLen or 120) or nil
      out.agents[#out.agents + 1] = {
        agentId = agentId, slug = slug, label = M.subagentLabel(slug, agentId, meta and meta.prompt),
        kind = wfId and "workflow" or "agent", wfId = wfId, name = name,
        mtime = mtime, running = running, lastLine = lastLine,
      }
      out.count = out.count + 1
      if running then out.runningCount = out.runningCount + 1; out.active = true end
      if wfId then
        local w = out.workflows[wfId] or { running = false, count = 0 }
        w.count = w.count + 1
        if running then w.running = true end
        out.workflows[wfId] = w
      end
    end
  end
  table.sort(out.agents, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
  return out
end

-- DR2: cheap background-activity check for the hot tile loop. Any subagent file
-- touched within the window => background work is running (a Workflow fleet or a
-- delegated subagent). Independent of full-tree parsing so it can run every tick.
function M.backgroundActivity(files, now, opts)
  opts = opts or {}
  now = tonumber(now) or 0
  local win = tonumber(opts.activeWindow) or 45
  local count, newest = 0, 0
  for _, f in ipairs(type(files) == "table" and files or {}) do
    local name = type(f) == "table" and f.name
    if type(name) == "string" and name:match("agent%-[^/]+%.jsonl$") then
      local mtime = tonumber(f.mtime) or 0
      if now > 0 and now - mtime <= win then
        count = count + 1
        if mtime > newest then newest = mtime end
      end
    end
  end
  return { active = count > 0, count = count, newest = newest }
end

-- ---- DR7: A/B fork-to-compare (explicitly-invoked, operator-aware) ----------
-- "Build both pathways, keep the best." An operator launches the SAME task into 2+
-- isolated variants (differing by model and/or prompt), each running in its OWN git
-- worktree (branch ab/<cohort>/<label>) so parallel builds never clobber each other;
-- they run as normal tiles; at the end a side-by-side compare (DR4 scores + optional
-- LLM-judge) helps keep the winner (losers' worktrees removed). This module is the PURE
-- planning + comparison; the worktree/spawn/close effects live in the dashboard.

-- Sanitize one path/branch component: lowercase, non-alnum -> "-", collapse, trim, cap.
function M.abSlug(s)
  s = tostring(s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if #s > 24 then s = s:sub(1, 24):gsub("%-+$", "") end
  return s
end

-- Branch + worktree path for a variant (deterministic). Worktrees live under a
-- `.cc-ab/` dir BESIDE the repo (a sibling, never inside the tracked tree).
function M.abBranchName(cohort, label) return "ab/" .. M.abSlug(cohort) .. "/" .. M.abSlug(label) end
function M.abWorktreePath(repoRoot, cohort, label)
  repoRoot = tostring(repoRoot or ""):gsub("/+$", "")
  local parent = repoRoot:match("^(.*)/[^/]+$") or "."
  local name = repoRoot:match("([^/]+)$") or "repo"
  return parent .. "/.cc-ab/" .. name .. "-" .. M.abSlug(cohort) .. "-" .. M.abSlug(label)
end

-- Validate + build a cohort plan from a spec:
--   { cohort, repoRoot, base="HEAD", task, variants = { {label, model?, provider?, prompt?} ... } }
-- Each variant's task = its own `prompt` (if set) else the base task; model/provider are
-- the per-variant overrides. Returns { ok=false, error } or
--   { ok=true, cohort, repoRoot, base, variants = [{ id,label,branch,worktreePath,task,model,provider }] }.
-- Requires >= 2 variants with non-empty, DISTINCT (post-slug) labels and a task to run.
function M.abCohortPlan(spec)
  if type(spec) ~= "table" then return { ok = false, error = "no spec" } end
  local repoRoot = tostring(spec.repoRoot or "")
  if repoRoot == "" then return { ok = false, error = "no repo root (A/B needs a git repo)" } end
  local baseTask = tostring(spec.task or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local vs = spec.variants
  if type(vs) ~= "table" or #vs < 2 then return { ok = false, error = "need at least 2 variants" } end
  local cohort = M.abSlug(spec.cohort ~= nil and spec.cohort or "")
  if cohort == "" then return { ok = false, error = "no cohort id" } end
  local base = (spec.base ~= nil and tostring(spec.base) ~= "") and tostring(spec.base) or "HEAD"
  local out, seen = {}, {}
  for _, v in ipairs(vs) do
    if type(v) ~= "table" then return { ok = false, error = "bad variant" } end
    local label = tostring(v.label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id = M.abSlug(label)
    if label == "" or id == "" then return { ok = false, error = "every variant needs a label" } end
    if seen[id] then return { ok = false, error = "duplicate variant label: " .. label } end
    seen[id] = true
    local task = tostring(v.prompt or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if task == "" then task = baseTask end
    if task == "" then return { ok = false, error = "variant " .. label .. " has no task (set a base task or a per-variant prompt)" } end
    out[#out + 1] = {
      id = id, label = label,
      branch = M.abBranchName(cohort, label),
      worktreePath = M.abWorktreePath(repoRoot, cohort, label),
      task = task,
      model = (v.model ~= nil and tostring(v.model) ~= "") and tostring(v.model) or nil,
      provider = (v.provider ~= nil and tostring(v.provider) ~= "") and tostring(v.provider) or nil,
    }
  end
  return { ok = true, cohort = cohort, repoRoot = repoRoot, base = base, variants = out }
end

-- Quoted git commands the dashboard runs via /bin/sh (same posture as
-- folderScanShellCommand). `add` creates the variant's worktree+branch off `base`;
-- `remove --force` drops a loser's worktree (its branch is left for you to delete/merge).
function M.gitWorktreeAddCmd(repoRoot, worktreePath, branch, base)
  return "git -C " .. shArg(repoRoot) .. " worktree add -b " .. shArg(branch)
    .. " " .. shArg(worktreePath) .. " " .. shArg(base or "HEAD")
end
function M.gitWorktreeRemoveCmd(repoRoot, worktreePath)
  return "git -C " .. shArg(repoRoot) .. " worktree remove --force " .. shArg(worktreePath)
end
-- Delete a variant's branch (after its worktree is removed, which frees the branch).
-- Used to leave NO trace on a rolled-back launch + to fully discard a loser on keep.
function M.gitBranchDeleteCmd(repoRoot, branch)
  return "git -C " .. shArg(repoRoot) .. " branch -D " .. shArg(branch)
end

-- Side-by-side comparison: rank the variants by DR4 run score (scored variants first,
-- highest score wins; ties broken by original order). scoresByLabel[label] = {score, hadData}.
-- Returns { rows = [{label, model, score, hadData, rank}], winner = label|nil }.
function M.abCompare(variants, scoresByLabel)
  scoresByLabel = type(scoresByLabel) == "table" and scoresByLabel or {}
  local rows = {}
  for i, v in ipairs(variants or {}) do
    local s = scoresByLabel[v.label] or {}
    rows[#rows + 1] = { label = v.label, model = v.model, idx = i,
                        score = tonumber(s.score), hadData = s.hadData == true }
  end
  table.sort(rows, function(a, b)
    if a.hadData ~= b.hadData then return a.hadData end        -- scored before unscored
    if a.hadData and a.score ~= b.score then return (a.score or 0) > (b.score or 0) end
    return a.idx < b.idx                                       -- stable tie-break
  end)
  local winner
  for i, r in ipairs(rows) do r.rank = i; r.idx = nil; if i == 1 and r.hadData then winner = r.label end end
  return { rows = rows, winner = winner }
end

-- LLM-judge rubric prompt (pasted into a session via the Improve/audit-review path) to
-- get a qualitative pick across the variants' outputs. Pure string assembly.
function M.abJudgePrompt(taskText, entries)
  local parts = {
    "Compare these approaches to the SAME task and pick the single best one. Be decisive.",
    "", "TASK:", tostring(taskText or "(no task recorded)"), "",
  }
  for _, e in ipairs(entries or {}) do
    if type(e) == "table" then
      parts[#parts + 1] = "## Variant " .. tostring(e.label or "?")
        .. (e.model and (" (model: " .. tostring(e.model) .. ")") or "")
      parts[#parts + 1] = tostring(e.output or "(no output captured)")
      parts[#parts + 1] = ""
    end
  end
  parts[#parts + 1] = "Judge on correctness, completeness, and code quality. Name the WINNING variant"
    .. " by its label and justify the pick in 3-4 sentences; then list each loser's single biggest weakness."
  return table.concat(parts, "\n")
end

-- ---- Appearance: design-token themes + per-token overrides -----------------
-- The panel's whole stylesheet references CSS custom properties (--bg, --surface,
-- --accent, --st-working, ...) declared in :root. Appearance lets the operator pick
-- a built-in THEME (a full token bundle) and layer per-token OVERRIDES on top
-- (accent / palette / status colors) plus SIZING (ui scale, density, tile width).
-- Pure here: resolveAppearance merges defaults<-theme<-overrides and validates;
-- appearanceCss renders the resolved :root block injected as __APPEARANCE_CSS__.
-- A small JS twin (applyAppearance) mirrors this for instant live-preview. The DATA
-- can't drift -- the twin iterates the SAME injected APPEARANCE (vars/defaults/themes/
-- fonts), so APPEARANCE_VARS below is the single source for both the SSR appearanceCss
-- AND the JS setProperty loop (there is NO second token list). Only the small merge
-- logic (defaults<-theme<-overrides) is duplicated in the twin -- keep THAT in sync
-- (the contextBand<->barLevel pattern), and the live-preview iteration is pinned in ui.test.

-- Ordered {stateKey, cssVar} -- also the emit order in appearanceCss.
M.APPEARANCE_VARS = {
  { "bg", "--bg" }, { "bgOverlay", "--bg-overlay" }, { "surface", "--surface" },
  { "surface2", "--surface-2" }, { "surface3", "--surface-3" }, { "surfaceHover", "--surface-hover" },
  { "border", "--border" }, { "borderWeak", "--border-weak" },
  { "text", "--text" }, { "text2", "--text-2" }, { "text3", "--text-3" },
  { "muted", "--muted" }, { "dim", "--dim" }, { "textStrong", "--text-strong" },
  { "accent", "--accent" }, { "accent2", "--accent-2" }, { "accentText", "--accent-text" }, { "accentBg", "--accent-bg" },
  { "stIdle", "--st-idle" }, { "stWorking", "--st-working" }, { "stDone", "--st-done" },
  { "stApproval", "--st-approval" }, { "stError", "--st-error" },
  { "ok", "--ok" }, { "danger", "--danger" }, { "warn", "--warn" }, { "purple", "--purple" },
}

-- Refined Midnight = the baseline palette (== today's hand-tuned dark look, lightly
-- polished). Every theme below is a DELTA over these defaults.
M.APPEARANCE_DEFAULTS = {
  bg = "#15161b", bgOverlay = "#14161b", surface = "#21232c", surface2 = "#1b1d24",
  surface3 = "#191b22", surfaceHover = "#272a35", border = "#2c2f3a", borderWeak = "#23262f",
  text = "#e8e9ee", text2 = "#cfd2db", text3 = "#aeb1bd", muted = "#8a8d99", dim = "#6b7280", textStrong = "#ffffff",
  accent = "#6ea8fe", accent2 = "#5b6cff", accentText = "#9fc1ff", accentBg = "#1c2536",
  stIdle = "#6b7280", stWorking = "#f5b50a", stDone = "#22c55e", stApproval = "#ef4444", stError = "#ec4899",
  ok = "#5ad67f", danger = "#ef4444", warn = "#f5b50a", purple = "#a98bff",
}

M.APPEARANCE_DEFAULT_THEME = "midnight"

-- theme = { label, scheme:"dark"|"light", look:"card"|"slate"|"flat", tokens={delta} }.
-- `look` drives static shape rules in the stylesheet (body[data-look=...]).
M.APPEARANCE_THEMES = {
  midnight = { label = "Refined Midnight", scheme = "dark", look = "card", tokens = {} },
  slate = { label = "Modern Slate", scheme = "dark", look = "slate", tokens = {
    bg = "#0f1420", bgOverlay = "#0d111b", surface = "#1b2333", surface2 = "#161d2b",
    surface3 = "#19212f", surfaceHover = "#24304a", border = "#2b3650", borderWeak = "#222c40",
    text = "#eef1f7", text2 = "#cdd6e6", text3 = "#9fabc2", muted = "#8893a8", dim = "#67718a",
    accent = "#7c9cff", accent2 = "#6d7bff", accentText = "#aebfff", accentBg = "#1e2a44",
  } },
  flat = { label = "Minimal Flat", scheme = "dark", look = "flat", tokens = {
    bg = "#16171a", bgOverlay = "#141518", surface = "#16171a", surface2 = "#1c1e22",
    surface3 = "#1a1c20", surfaceHover = "#212329", border = "#26282e", borderWeak = "#202227",
    text = "#e6e7ea", text2 = "#bcbfc7", text3 = "#9499a3", muted = "#7f838d", dim = "#5e626b",
    accent = "#8ab4ff", accentText = "#bcd0ff",
  } },
  nord = { label = "Nord", scheme = "dark", look = "card", tokens = {
    bg = "#2e3440", bgOverlay = "#272c38", surface = "#3b4252", surface2 = "#353c4a",
    surface3 = "#39414f", surfaceHover = "#434c5e", border = "#4c566a", borderWeak = "#3b4252",
    text = "#eceff4", text2 = "#d8dee9", text3 = "#abb2bf", muted = "#9aa3b5", dim = "#6f7a8d",
    accent = "#88c0d0", accent2 = "#81a1c1", accentText = "#8fbcbb", accentBg = "#3b4a52",
    stIdle = "#6f7a8d", stWorking = "#ebcb8b", stDone = "#a3be8c", stApproval = "#bf616a", stError = "#b48ead",
    ok = "#a3be8c", danger = "#bf616a", warn = "#ebcb8b", purple = "#b48ead",
  } },
  contrast = { label = "High Contrast", scheme = "dark", look = "card", tokens = {
    bg = "#000000", bgOverlay = "#000000", surface = "#0d0d10", surface2 = "#141418",
    surface3 = "#111114", surfaceHover = "#1d1d22", border = "#5a5f6b", borderWeak = "#3a3d47",
    text = "#ffffff", text2 = "#eef0f5", text3 = "#cfd3dc", muted = "#aab0bd", dim = "#7e8694",
    accent = "#5ea0ff", accent2 = "#7c9cff", accentText = "#bcd4ff", accentBg = "#10243f",
    stIdle = "#9aa1ae", stWorking = "#ffc21a", stDone = "#2ee06a", stApproval = "#ff4d4d", stError = "#ff5cc8",
    ok = "#2ee06a", danger = "#ff4d4d", warn = "#ffc21a", purple = "#c79bff",
  } },
  light = { label = "Light", scheme = "light", look = "card", tokens = {
    bg = "#f4f6f9", bgOverlay = "#eef1f5", surface = "#ffffff", surface2 = "#f1f3f7",
    surface3 = "#f7f8fb", surfaceHover = "#e9edf3", border = "#d6dbe3", borderWeak = "#e4e8ee",
    text = "#1b1f27", text2 = "#39414f", text3 = "#5b6373", muted = "#6b7280", dim = "#98a0ad", textStrong = "#0b0e14",
    accent = "#2563eb", accent2 = "#4f46e5", accentText = "#1d4ed8", accentBg = "#dfe8fd",
    stIdle = "#9ca3af", stWorking = "#d97706", stDone = "#16a34a", stApproval = "#dc2626", stError = "#db2777",
    ok = "#16a34a", danger = "#dc2626", warn = "#d97706", purple = "#7c3aed",
  } },
  dracula = { label = "Dracula", scheme = "dark", look = "card", tokens = {
    bg = "#282a36", bgOverlay = "#21222c", surface = "#343746", surface2 = "#21222c",
    surface3 = "#2b2e3b", surfaceHover = "#424458", border = "#44475a", borderWeak = "#343746",
    text = "#f8f8f2", text2 = "#e2e2dc", text3 = "#b9b9c4", muted = "#8a8ca3", dim = "#6272a4",
    accent = "#bd93f9", accent2 = "#ff79c6", accentText = "#8be9fd", accentBg = "#343a52",
    stWorking = "#f1fa8c", stDone = "#50fa7b", stApproval = "#ff5555", stError = "#ff79c6",
    ok = "#50fa7b", danger = "#ff5555", warn = "#f1fa8c", purple = "#bd93f9",
  } },
  tokyonight = { label = "Tokyo Night", scheme = "dark", look = "card", tokens = {
    bg = "#1a1b26", bgOverlay = "#16161e", surface = "#24283b", surface2 = "#1f2335",
    surface3 = "#222538", surfaceHover = "#2f344d", border = "#2f3549", borderWeak = "#292e42",
    text = "#c0caf5", text2 = "#a9b1d6", text3 = "#828bb8", muted = "#6b7394", dim = "#565f89",
    accent = "#7aa2f7", accent2 = "#bb9af7", accentText = "#7dcfff", accentBg = "#283457",
    stWorking = "#e0af68", stDone = "#9ece6a", stApproval = "#f7768e", stError = "#bb9af7",
    ok = "#9ece6a", danger = "#f7768e", warn = "#e0af68", purple = "#bb9af7",
  } },
  gruvbox = { label = "Gruvbox", scheme = "dark", look = "card", tokens = {
    bg = "#282828", bgOverlay = "#1d2021", surface = "#3c3836", surface2 = "#32302f",
    surface3 = "#3a3735", surfaceHover = "#504945", border = "#504945", borderWeak = "#3c3836",
    text = "#ebdbb2", text2 = "#d5c4a1", text3 = "#bdae93", muted = "#a89984", dim = "#928374",
    accent = "#83a598", accent2 = "#d3869b", accentText = "#8ec07c", accentBg = "#3b4a45",
    stWorking = "#fabd2f", stDone = "#b8bb26", stApproval = "#fb4934", stError = "#d3869b",
    ok = "#b8bb26", danger = "#fb4934", warn = "#fabd2f", purple = "#d3869b",
  } },
  solarized = { label = "Solarized Dark", scheme = "dark", look = "card", tokens = {
    bg = "#002b36", bgOverlay = "#00252e", surface = "#073642", surface2 = "#053742",
    surface3 = "#06303a", surfaceHover = "#0a4a59", border = "#134552", borderWeak = "#073642",
    text = "#93a1a1", text2 = "#839496", text3 = "#768e96", muted = "#657b83", dim = "#586e75", textStrong = "#fdf6e3",
    accent = "#268bd2", accent2 = "#6c71c4", accentText = "#2aa198", accentBg = "#093f4d",
    stWorking = "#b58900", stDone = "#859900", stApproval = "#dc322f", stError = "#d33682",
    ok = "#859900", danger = "#dc322f", warn = "#b58900", purple = "#6c71c4",
  } },
  solarizedlight = { label = "Solarized Light", scheme = "light", look = "card", tokens = {
    bg = "#fdf6e3", bgOverlay = "#eee8d5", surface = "#ffffff", surface2 = "#f7f1de",
    surface3 = "#faf3e0", surfaceHover = "#eee8d5", border = "#d9d2bf", borderWeak = "#e7e0cd",
    text = "#586e75", text2 = "#657b83", text3 = "#839496", muted = "#93a1a1", dim = "#9aa79f", textStrong = "#073642",
    accent = "#268bd2", accent2 = "#6c71c4", accentText = "#1c6a9c", accentBg = "#d7e6f0",
    stWorking = "#b58900", stDone = "#859900", stApproval = "#dc322f", stError = "#d33682",
    ok = "#859900", danger = "#dc322f", warn = "#b58900", purple = "#6c71c4",
  } },
  rosepine = { label = "Rosé Pine", scheme = "dark", look = "card", tokens = {
    bg = "#191724", bgOverlay = "#16141f", surface = "#1f1d2e", surface2 = "#26233a",
    surface3 = "#21202e", surfaceHover = "#2a283e", border = "#403d52", borderWeak = "#2a273f",
    text = "#e0def4", text2 = "#cdcbe0", text3 = "#908caa", muted = "#6e6a86", dim = "#6e6a86",
    accent = "#c4a7e7", accent2 = "#ebbcba", accentText = "#9ccfd8", accentBg = "#2a283e",
    stWorking = "#f6c177", stDone = "#9ccfd8", stApproval = "#eb6f92", stError = "#ebbcba",
    ok = "#9ccfd8", danger = "#eb6f92", warn = "#f6c177", purple = "#c4a7e7",
  } },
  catppuccin = { label = "Catppuccin", scheme = "dark", look = "card", tokens = {
    bg = "#1e1e2e", bgOverlay = "#181825", surface = "#313244", surface2 = "#181825",
    surface3 = "#292c3c", surfaceHover = "#45475a", border = "#45475a", borderWeak = "#313244",
    text = "#cdd6f4", text2 = "#bac2de", text3 = "#a6adc8", muted = "#9399b2", dim = "#6c7086",
    accent = "#89b4fa", accent2 = "#cba6f7", accentText = "#94e2d5", accentBg = "#2a2b40",
    stWorking = "#f9e2af", stDone = "#a6e3a1", stApproval = "#f38ba8", stError = "#f5c2e7",
    ok = "#a6e3a1", danger = "#f38ba8", warn = "#f9e2af", purple = "#cba6f7",
  } },
  gruvboxlight = { label = "Gruvbox Light", scheme = "light", look = "card", tokens = {
    bg = "#fbf1c7", bgOverlay = "#f2e5bc", surface = "#ffffff", surface2 = "#f4e8be",
    surface3 = "#f9f0d0", surfaceHover = "#ebdbb2", border = "#d5c4a1", borderWeak = "#ece0bf",
    text = "#3c3836", text2 = "#504945", text3 = "#665c54", muted = "#7c6f64", dim = "#928374", textStrong = "#282828",
    accent = "#458588", accent2 = "#b16286", accentText = "#076678", accentBg = "#d6e5e5",
    stWorking = "#d79921", stDone = "#98971a", stApproval = "#cc241d", stError = "#b16286",
    ok = "#98971a", danger = "#cc241d", warn = "#d79921", purple = "#b16286",
  } },
  monokai = { label = "Monokai", scheme = "dark", look = "card", tokens = {
    bg = "#272822", bgOverlay = "#1e1f1c", surface = "#3e3d32", surface2 = "#2d2e27",
    surface3 = "#383830", surfaceHover = "#49483e", border = "#49483e", borderWeak = "#3e3d32",
    text = "#f8f8f2", text2 = "#e6e6dc", text3 = "#cfcfc2", muted = "#a6a28c", dim = "#75715e",
    accent = "#66d9ef", accent2 = "#ae81ff", accentText = "#a6e22e", accentBg = "#2b3a3f",
    stWorking = "#e6db74", stDone = "#a6e22e", stApproval = "#f92672", stError = "#ae81ff",
    ok = "#a6e22e", danger = "#f92672", warn = "#fd971f", purple = "#ae81ff",
  } },
  oled = { label = "OLED Black", scheme = "dark", look = "card", tokens = {
    bg = "#000000", bgOverlay = "#000000", surface = "#0a0a0a", surface2 = "#121212",
    surface3 = "#0e0e0e", surfaceHover = "#1a1a1a", border = "#262626", borderWeak = "#1c1c1c",
    text = "#f2f2f2", text2 = "#d4d4d4", text3 = "#a3a3a3", muted = "#8a8a8a", dim = "#5c5c5c", textStrong = "#ffffff",
    accent = "#4ea3ff", accent2 = "#7c9cff", accentText = "#8fc0ff", accentBg = "#06243f",
    stWorking = "#f5b50a", stDone = "#22c55e", stApproval = "#ef4444", stError = "#ec4899",
    ok = "#22c55e", danger = "#ef4444", warn = "#f5b50a", purple = "#a98bff",
  } },
}

-- Font-family stacks the Appearance > Font picker maps to (--font token). Keys are
-- the stored enum; values are the CSS stack. system = the original panel font.
M.APPEARANCE_FONTS = {
  system  = "-apple-system,system-ui,sans-serif",
  rounded = "ui-rounded,'SF Pro Rounded','Nunito',system-ui,sans-serif",
  mono    = "ui-monospace,'SF Mono',Menlo,monospace",
  serif   = "ui-serif,Georgia,'Iowan Old Style',serif",
}
M.APPEARANCE_DEFAULT_FONT = "system"

-- An accepts #rgb or #rrggbb (the only forms the color inputs + presets emit).
local function appearanceIsHex(s)
  return type(s) == "string" and (s:match("^#%x%x%x$") ~= nil or s:match("^#%x%x%x%x%x%x$") ~= nil)
end
M.appearanceIsHex = appearanceIsHex

local function appearanceClamp(v, lo, hi, dflt)
  -- R2-26: reject hex / non-decimal string literals so this Lua side matches the JS
  -- apClamp twin (which gates strings through a base-10 regex). tonumber("0x96")==150
  -- and tonumber("0x1.2")==1.125, so a hex string would give SSR CSS a value the
  -- live preview computes differently. Numbers pass straight through.
  if type(v) == "string" then
    if not v:match("^%s*[-+]?%d*%.?%d+%s*$") and not v:match("^%s*[-+]?%d+%.?%d*%s*$") then
      return dflt
    end
  end
  v = tonumber(v); if not v then return dflt end
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- Merge DEFAULTS <- theme delta <- user overrides (palette/accent/status); validate
-- + clamp sizing. `ap` is cfg.appearance (any shape -> safe). Returns the resolved
-- view the dashboard body + appearanceCss + the JS twin consume.
function M.resolveAppearance(ap)
  ap = type(ap) == "table" and ap or {}
  local themeKey = (type(ap.theme) == "string" and M.APPEARANCE_THEMES[ap.theme]) and ap.theme
    or M.APPEARANCE_DEFAULT_THEME
  local theme = M.APPEARANCE_THEMES[themeKey]
  local tokens = {}
  for k, v in pairs(M.APPEARANCE_DEFAULTS) do tokens[k] = v end
  for k, v in pairs(theme.tokens or {}) do tokens[k] = v end
  if type(ap.colors) == "table" then            -- palette overrides: known keys, valid hex only
    for k, v in pairs(ap.colors) do
      if tokens[k] ~= nil and appearanceIsHex(v) then tokens[k] = v end
    end
  end
  if appearanceIsHex(ap.accent) then tokens.accent = ap.accent end
  if type(ap.status) == "table" then
    local map = { working = "stWorking", done = "stDone", approval = "stApproval", error = "stError", idle = "stIdle" }
    for k, tk in pairs(map) do if appearanceIsHex(ap.status[k]) then tokens[tk] = ap.status[k] end end
  end
  return {
    theme = themeKey,
    scheme = theme.scheme or "dark",
    look = theme.look or "card",
    tokens = tokens,
    scale = appearanceClamp(ap.scale, 0.8, 1.4, 1.0),
    tileMin = math.floor(appearanceClamp(ap.tileMin, 120, 320, 170) + 0.5),
    density = (ap.density == "dense") and "dense" or "comfortable",
    font = (type(ap.font) == "string" and M.APPEARANCE_FONTS[ap.font]) and ap.font or M.APPEARANCE_DEFAULT_FONT,
    reduceMotion = ap.reduceMotion == true,
  }
end

-- Render the resolved appearance as the :root override block injected after the
-- main stylesheet (cascades over the static Midnight defaults). Pure string; emits
-- only valid-hex tokens so a malformed override silently falls back to the default.
function M.appearanceCss(resolved)
  resolved = type(resolved) == "table" and resolved or M.resolveAppearance({})
  local t = resolved.tokens or {}
  local parts = { ":root{", "color-scheme:" .. (resolved.scheme == "light" and "light" or "dark") .. ";" }
  for _, pair in ipairs(M.APPEARANCE_VARS) do
    if appearanceIsHex(t[pair[1]]) then parts[#parts + 1] = pair[2] .. ":" .. t[pair[1]] .. ";" end
  end
  parts[#parts + 1] = "--ui-scale:" .. tostring(resolved.scale or 1) .. ";"
  parts[#parts + 1] = "--tile-min:" .. tostring(resolved.tileMin or 170) .. "px;"
  parts[#parts + 1] = "--font:" .. (M.APPEARANCE_FONTS[resolved.font] or M.APPEARANCE_FONTS.system) .. ";"
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

-- F3 (theme editor): a portable theme = the full resolved palette (all 26 color
-- tokens) plus the non-color knobs, so it round-trips through export/import and can be
-- saved under a name. exportTheme reads the colors off a RESOLVED appearance, so even a
-- partial config exports the fully-resolved palette the user actually sees.
function M.exportTheme(resolved)
  resolved = (type(resolved) == "table") and resolved or M.resolveAppearance({})
  local tok = (type(resolved.tokens) == "table") and resolved.tokens or {}
  local colors = {}
  for _, pair in ipairs(M.APPEARANCE_VARS) do
    if appearanceIsHex(tok[pair[1]]) then colors[pair[1]] = tok[pair[1]] end
  end
  return {
    v = 1,
    scheme = resolved.scheme or "dark",
    look = resolved.look or "card",
    font = resolved.font or M.APPEARANCE_DEFAULT_FONT,
    scale = resolved.scale or 1.0,
    tileMin = resolved.tileMin or 170,
    density = resolved.density or "comfortable",
    reduceMotion = resolved.reduceMotion == true,
    colors = colors,
  }
end

-- importTheme validates EVERY supplied color is a known token + valid hex and returns a
-- ready-to-apply appearance config (theme stays the base; colors carry the full override),
-- or { ok=false, error }. It never returns a half-valid palette -- one bad token rejects
-- the whole import so the live preview can't land in a broken state.
function M.importTheme(obj)
  if type(obj) ~= "table" then return { ok = false, error = "not a theme object" } end
  local known = {}
  for _, pair in ipairs(M.APPEARANCE_VARS) do known[pair[1]] = true end
  local colors = (type(obj.colors) == "table") and obj.colors or {}
  local out, n = {}, 0
  for k, v in pairs(colors) do
    if not known[k] then return { ok = false, error = "unknown color token: " .. tostring(k) } end
    if not appearanceIsHex(v) then return { ok = false, error = "invalid hex for " .. tostring(k) .. ": " .. tostring(v) } end
    out[k] = v; n = n + 1
  end
  if n == 0 then return { ok = false, error = "theme has no colors" } end
  return { ok = true, appearance = {
    theme = (type(obj.theme) == "string") and obj.theme or M.APPEARANCE_DEFAULT_THEME,
    colors = out,
    font = obj.font, scale = obj.scale, tileMin = obj.tileMin,
    density = obj.density, reduceMotion = obj.reduceMotion == true,
  } }
end

-- F6 (self-diagnostics): turn observed environment FACTS into an ordered list of health
-- rows { label, status = "ok"|"warn"|"crit"|"info", detail, fix? }. Pure so the whole
-- classification is unit-tested; the dashboard's FX.doctorStatus gathers the facts (tool
-- presence, hook inventory, heartbeat age, ledger size) and feeds them in.
local function fmtBytesShort(n)
  n = tonumber(n) or 0
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.0f KB", n / 1024) end
  return tostring(math.floor(n)) .. " B"
end

function M.doctorChecks(facts)
  facts = (type(facts) == "table") and facts or {}
  local rows = {}
  local function add(label, status, detail, fix)
    rows[#rows + 1] = { label = label, status = status, detail = detail, fix = fix }
  end

  if facts.jq then add("jq installed", "ok", "JSON processing available")
  else add("jq missing", "crit", "the hook scripts need jq to write session status", "brew install jq") end

  local hw, ht = tonumber(facts.hooksWired) or 0, tonumber(facts.hooksTotal) or 0
  if ht > 0 and hw >= ht then add("Claude Code hooks wired", "ok", hw .. "/" .. ht .. " hook scripts active")
  elseif hw > 0 then add("Some hooks not wired", "warn", hw .. "/" .. ht .. " hook scripts active", "run: make setup")
  else add("Hooks not installed", "crit", "no Shepherd hooks found in settings.json", "run: make setup") end

  if facts.scriptsInstalled == false then
    add("Hook scripts missing on disk", "crit", "cc-status.sh / cc-approve.sh not in ~/.claude", "run: make setup")
  elseif facts.scriptsInstalled == true then
    add("Hook scripts installed", "ok", "cc-status.sh / cc-approve.sh present")
  end

  local hb = facts.heartbeatAgeSec
  if hb == nil then add("Panel heartbeat missing", "warn", "the panel hasn't written a heartbeat yet")
  elseif tonumber(hb) and tonumber(hb) <= 10 then add("Panel live", "ok", "heartbeat " .. math.floor(tonumber(hb)) .. "s ago")
  else add("Panel heartbeat stale", "warn", "last heartbeat " .. math.floor(tonumber(hb) or 0) .. "s ago") end

  if facts.gateArmed then add("Headless approvals armed", "ok", "tool requests gate through this panel")
  else add("Gate disarmed", "info", "auto-approve policies apply; arm it in Settings") end

  if facts.ledgerEnabled then
    add("Audit ledger on", "ok", fmtBytesShort(facts.ledgerBytes) .. " recorded")
    if (tonumber(facts.ledgerBytes) or 0) > 52428800 then
      add("Ledger is large", "warn", fmtBytesShort(facts.ledgerBytes) .. " — consider a shorter retention", "lower ledger.retentionDays")
    end
  else
    add("Audit ledger off", "info", "enable it in Settings for history + cost trends")
  end

  local n = tonumber(facts.sessions) or 0
  add(n .. " live session" .. ((n == 1) and "" or "s"), "info", "tiles currently tracked")
  return rows
end

-- F9: the in-app "Features" list (☰ menu). Plain-language what + why for each headline
-- capability, so the panel documents itself. Single-sourced here (pure data) so the
-- overlay renders it and tests can pin the shape. `kind` tags the flavor for the chip.
-- F9: the in-app "Features" list (☰ menu). Plain-language what + why for every USER-FACING
-- capability, grouped by `cat` (the overlay renders a header per category, in first-seen
-- order, so keep each category's entries contiguous). `new = true` flags this batch's
-- additions for the chip. A self-documenting tour of what the app can do.
M.FEATURE_CATEGORIES = { "Core", "Control", "Automate", "See what's happening", "Make it yours", "Connect & extend", "Power tools" }
M.FEATURES = {
  -- ---- Core ----
  { key = "fleet", cat = "Core", title = "Fleet dashboard",
    what = "Every running Claude Code session shows up as a live tile — working, waiting on you, done, or errored.",
    why = "An air-traffic screen for your AI helpers: see who needs attention at a glance instead of hunting through windows." },
  { key = "spawn", cat = "Core", title = "Spawn new sessions",
    what = "Launch a session into any project — choose editor, permission mode, model/provider, and a first task, with saved presets.",
    why = "Start work from the dashboard instead of wiring up each terminal by hand." },
  { key = "search", cat = "Core", title = "Find in fleet",
    what = "Search across every session's recent activity to locate the one you mean.",
    why = "Jump straight to the session doing the thing you care about, even with dozens running." },
  { key = "groups", cat = "Core", title = "Groups & labels",
    what = "Rename tiles and bucket them into cohorts, then scope the grid to one group.",
    why = "Keep a big fleet organized and filter down to just what you're working on." },

  -- ---- Control ----
  { key = "gate", cat = "Control", title = "Headless approvals",
    what = "When a session wants a risky tool it pauses, and you approve or deny right from the panel; unanswered, it safely falls back.",
    why = "You stay in control without editor windows popping up — and it never silently auto-runs." },
  { key = "actions", cat = "Control", title = "Jump, nudge, stop, clear",
    what = "Act on any session from its tile — focus its window, send it a message, stop it, or clear its context.",
    why = "Drive a session without switching to it." },
  { key = "transcript", cat = "Control", new = true, title = "Transcript peek",
    what = "Read a session's recent back-and-forth, with a search box, right inside the panel.",
    why = "Triage what a session is actually doing in a glance instead of switching windows." },
  { key = "rewind", cat = "Control", title = "Rewind & checkpoints",
    what = "Open Claude Code's restore-point picker for a session and roll back its file edits.",
    why = "Undo a wrong turn (with confirmation) without leaving the dashboard." },
  { key = "worklist", cat = "Control", title = "Worklist (My List)",
    what = "A personal checklist of things to hand to sessions.",
    why = "Keep your own to-dos right next to the fleet that does them." },
  { key = "stories", cat = "Control", new = true, title = "User stories",
    what = "When a project has spec/product/user-stories.md, a gated tab shows its stories by capability area — add, edit, and save them in place.",
    why = "Curate the product's user stories next to the sessions building it, without leaving the panel." },
  { key = "remote", cat = "Control", title = "Remote control",
    what = "New sessions can be driven from claude.ai or the Claude app, not just this Mac.",
    why = "Continue a local session from your phone or another machine." },

  -- ---- Automate ----
  { key = "queue", cat = "Automate", title = "Task queue & auto-feed",
    what = "Line up tasks per session, auto-feed the next when one finishes, and route work to whichever session is free.",
    why = "Keep sessions busy without babysitting each handoff." },
  { key = "recover", cat = "Automate", title = "Auto-respawn & auto-continue",
    what = "Respawn a stuck session and nudge one frozen on an API error to continue — within safe retry budgets.",
    why = "A long-running fleet heals itself instead of silently stalling overnight." },
  { key = "policies", cat = "Automate", title = "Policy bundles & autopilot",
    what = "Reusable auto-allow/deny rules per session or fleet, plus a timed autopilot that approves everything for a while.",
    why = "Pre-decide the routine calls so you only ever see the ones that matter." },
  { key = "automodel", cat = "Automate", title = "Model auto-routing",
    what = "Automatically pick a cheap, standard, or strong model based on how hard the task looks.",
    why = "Spend the expensive model only where the work actually needs it." },
  { key = "rules", cat = "Automate", title = "Automation rules",
    what = "Run a chosen action when an event fires — e.g. on error, on done, on a starved queue.",
    why = "Encode your own reflexes so the fleet reacts without you." },
  { key = "routines", cat = "Automate", title = "Routines",
    what = "Scheduled actions that fire on a cron-like timetable.",
    why = "Standups, sweeps, or kickoffs happen on their own." },

  -- ---- See what's happening ----
  { key = "ledger", cat = "See what's happening", title = "Audit ledger & insights",
    what = "An optional local log of everything that happens, powering fleet insights, risk scoring, and decision provenance.",
    why = "Forensics and trends when you want them, off by default when you don't." },
  { key = "cost", cat = "See what's happening", new = true, title = "Cost & token analytics",
    what = "Per-session and fleet token use and estimated dollar cost, plus a daily trend chart.",
    why = "See where the money goes so you can put cheap work on a cheaper model." },
  { key = "usage", cat = "See what's happening", title = "Plan usage meter",
    what = "Your real Claude plan's 5-hour and 7-day usage windows, read live.",
    why = "Know how close you are to your plan limits at a glance." },
  { key = "shift", cat = "See what's happening", title = "Shift report",
    what = "A narrative end-of-shift summary of what the whole fleet did.",
    why = "A readable recap instead of scrolling raw logs." },
  { key = "doctor", cat = "See what's happening", new = true, title = "Diagnostics",
    what = "A one-screen health check — hooks, gate, jq, panel heartbeat, ledger size — with fix hints.",
    why = "Turns a silent setup problem into a glance." },
  { key = "notify", cat = "See what's happening", title = "Notifications & escalation",
    what = "Alerts — including phone push — when a session has been waiting on you too long.",
    why = "Don't leave a session blocked while you're away from the desk." },

  -- ---- Make it yours ----
  { key = "theme", cat = "Make it yours", new = true, title = "Visual theme editor",
    what = "14 themes, an editor for every color with live preview, plus theme export and import.",
    why = "The look is yours — and you can save or share a palette as a file." },
  { key = "layout", cat = "Make it yours", title = "Layout & density",
    what = "Choose how tiles are arranged, their size, density, font, and reduced motion.",
    why = "Tune the panel to your screen and taste." },

  -- ---- Connect & extend ----
  { key = "agents", cat = "Connect & extend", title = "Agent profiles",
    what = "Save agent configs — role, skills, MCP servers, knowledge — and spawn with them.",
    why = "Launch a specialized agent in one click instead of re-typing flags." },
  { key = "mcp", cat = "Connect & extend", title = "MCPs & Skills",
    what = "See and manage the MCP servers and skills available to your sessions.",
    why = "Know exactly what tools your agents can reach." },
  { key = "templates", cat = "Connect & extend", title = "Prompt templates",
    what = "Reusable task templates with variables you fill in at send time.",
    why = "Stop re-writing the same prompts." },
  { key = "providers", cat = "Connect & extend", title = "Providers & models",
    what = "Use Claude tiers, other companies' models, or local models through a gateway.",
    why = "Route work to whatever model fits, all from one place." },
  { key = "bridge", cat = "Connect & extend", title = "SSH status bridge",
    what = "Mirror and monitor sessions running on remote machines.",
    why = "Watch your whole fleet, not just the one in front of you." },

  -- ---- Power tools ----
  { key = "ab", cat = "Power tools", title = "A/B compare",
    what = "Fork a task into variants, run them side by side, score them, and keep the winner.",
    why = "Try multiple approaches at once and pick the best." },
  { key = "hotkeys", cat = "Power tools", title = "Global hotkeys",
    what = "Approve, jump to who needs you, cycle, spawn, and toggle the panel from anywhere.",
    why = "Drive the fleet without reaching for the mouse." },
  { key = "streamdeck", cat = "Power tools", title = "Stream Deck",
    what = "Map sessions and actions onto physical buttons.",
    why = "Tactile control for a busy fleet." },
  { key = "awake", cat = "Power tools", title = "Keep awake & screen lock",
    what = "Keep the Mac from sleeping while sessions run, and lock the screen without pausing them.",
    why = "Long jobs finish overnight, safely." },
  { key = "render", cat = "Power tools", new = true, title = "Faster rendering",
    what = "The grid updates only the tiles that actually changed each second.",
    why = "Less CPU and battery, especially with a big fleet." },
}

-- ---- Cold-start spawn ladder: the bounded poll decision (pure) --------------
-- The new-project extension ladder polls until the project window appears, then
-- opens the Claude panel. This is the regression-prone branch (an unbounded poll
-- would hang the spawn on a window that never title-matches). Pure so the bound +
-- give-up are unit-tested; the dashboard ladder executes the returned action.
--   windowSeen -> "open"  (the window matched -> open the panel after the buffer)
--   not seen, elapsed < waitMax -> "wait"   (poll another tick)
--   not seen, elapsed >= waitMax -> "giveup" (open best-effort + deliver, don't hang)
function M.coldStartStep(windowSeen, elapsed, waitMax)
  if windowSeen then return "open" end
  if (tonumber(elapsed) or 0) < (tonumber(waitMax) or 25) then return "wait" end
  return "giveup"
end

-- ---- Per-spawn cold-start ladder key (R1-09) -------------------------------
-- Each concurrent spawn (notably an A/B cohort, which spawns N variants in a
-- synchronous loop) needs its OWN cold-start ladder storage slot. A single shared
-- module-level slot lets variant 2 cancel variant 1's just-scheduled ladder, so
-- R3-07: worst-case wall-clock duration (seconds) of a spawn's keystroke ladder,
-- so spawnEditorWindow can reserve that long a slot on the shared injectionTailAt
-- (the same tail dispatchSerialized uses) and a concurrent dispatched paste queues
-- BEHIND the spawn ladder instead of cross-clobbering its clipboard/focus. Pure so
-- it's unit-testable; the dashboard passes the resolved spec. The numbers mirror
-- the beat delays in spawnEditorWindow's three branches:
--   warm extension : 3.0 + 1.0 + 2.0 + 0.3                   = 6.3s
--   terminal       : 3.0 + 0.8 + 0.6 + 0.4 + 2.0 + 0.3       = 7.1s
--   cold-start     : 2.0 head start + coldWindowWait + coldActivate + drive(7.1)
-- A generous over-reservation is safe: it only delays a *concurrent* dispatch, and
-- staggerSlot collapses to ~0 once the tail is in the past.
function M.spawnLadderWorst(spec)
  spec = spec or {}
  if spec.flavor == "extension" and spec.coldStart ~= true then
    return 6.3  -- warm extension ladder
  end
  local terminalDrive = 7.1  -- terminal/warm drive ladder
  if spec.coldStart == true then
    local waitMax  = tonumber(spec.coldWindowWait) or 25
    local activate = tonumber(spec.coldActivate) or 6
    -- 2.0s head start before polling + the bounded window wait + activation buffer
    -- + the drive ladder that runs once the window is seen.
    return 2.0 + waitMax + activate + terminalDrive
  end
  return terminalDrive  -- warm terminal ladder
end

-- only the LAST variant ever gets its task. This returns a stable, normalized key
-- for the spawn's target window (the worktree project path, falling back to the
-- resolved window `name`) so the dashboard can key its handle map per-window:
-- distinct variants -> distinct keys (all ladders survive); a repeat manual spawn
-- of the SAME project -> same key (it correctly supersedes its own prior ladder).
function M.spawnLadderKey(spec)
  spec = spec or {}
  local p = spec.project
  if p ~= nil and tostring(p) ~= "" then return tostring(p) end
  local n = spec.name
  if n ~= nil and tostring(n) ~= "" then return tostring(n) end
  return "__default__"
end

return M
