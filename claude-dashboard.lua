-- claude-dashboard.lua
--
-- Babysitter: a floating, always-on-top fleet console for Claude Code sessions.
-- One tile per running session with a live status (idle / working / approval /
-- done). Select a tile to open a detail panel where you can Jump to its window,
-- Approve / Deny a pending action, send a Nudge, or Stop the turn.
--
-- Sessions are keyed by session_id, so two sessions in the same folder never
-- collide. Tiles disappear when a session ends (SessionEnd) and dim if a session
-- goes stale (no hook updates for a while).
--
-- Control mechanisms (see README):
--   * Keystroke injection - focuses the target window and types into the
--     integrated terminal (the universal primitive; the only option for nudge
--     and stop, and the default for approve/deny).
--   * Hook approval gate  - when a session is gate:"waiting", Approve/Deny
--     instead write a decision file the PreToolUse gate is polling, so you
--     answer hands-free with no window switch.
--
-- Load it from ~/.hammerspoon/init.lua with:
--   dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")
-- then pick "Reload Config" from the Hammerspoon menu.

local M = {}

-- ---- config -------------------------------------------------------------
local STATUS_DIR = os.getenv("HOME") .. "/.claude/cc-status"
local HEARTBEAT  = STATUS_DIR .. "/.panel-alive"
-- Bundle ids to search, in order. Cursor and Insiders included as fallbacks.
local EDITOR_BUNDLES = {
  "com.microsoft.VSCode",
  "com.microsoft.VSCodeInsiders",
  "com.todesktop.230313mzl4w4u92", -- Cursor
}
local POLL_SECONDS  = 1.0
local PANEL_W       = 580
local DEFAULT_THEME = "cards"  -- cards | bar | contrast | dots
local STALE_SECONDS = 90       -- dim a tile after this long with no updates
local FOCUS_DELAY   = 0.12     -- wait after focusing before sending keystrokes
local RESTORE_FOCUS = true     -- return focus to where you were after acting

-- Keystrokes the Claude Code permission TUI expects. Verify once on your build
-- (Step 0/3 in the plan) and adjust here if your version differs.
local KEY_APPROVE = { mods = {},       key = "return" } -- accept highlighted "Yes"
local KEY_DENY    = { mods = {},       key = "escape" } -- cancel the prompt
local KEY_STOP    = { mods = {},       key = "escape" } -- interrupt the turn

-- Stream Deck (optional). If an Elgato Stream Deck is plugged in AND the
-- official Elgato app is NOT running, babysitter paints one session per key and
-- reuses the same actions as the panel. Adapts to any size (Mini/Standard/XL)
-- by asking the device for its key count; falls back to 15 if that fails.
local STREAMDECK_ENABLED  = true
local SD_LONG_PRESS       = 0.7    -- seconds held to count as a "long press"
local SD_LONG_PRESS_STOPS = false  -- if true, long-press a normal tile = Stop
local SD_FALLBACK_KEYS    = 15     -- assume a standard deck if detection fails
local SD_BRIGHTNESS       = 70
-- -------------------------------------------------------------------------

-- session key (status filename base) -> latest item, for resolving actions.
local byKey = {}

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

-- Focus the editor window whose title contains the project name. Returns true
-- if a specific window was focused. Focusing a window on another Space switches
-- to that Space automatically.
local function focusProject(name)
  print("[cc-dashboard] focus request: " .. tostring(name))
  local app = findEditorApp()
  if not app then
    print("[cc-dashboard] editor app not found")
    hs.alert.show("No VS Code window found")
    return false
  end
  local needle = string.lower(name or "")
  for _, w in ipairs(app:allWindows()) do
    local title = string.lower(w:title() or "")
    if title ~= "" and needle ~= "" and string.find(title, needle, 1, true) then
      w:focus()
      print("[cc-dashboard] focused: " .. (w:title() or "?"))
      return true
    end
  end
  app:activate()
  print("[cc-dashboard] no title match for '" .. tostring(name) .. "', activated app")
  return false
end

-- Focus a session's window, then run sendFn after a short delay so the focus
-- change has settled, optionally restoring the previously focused window.
local function actOnProject(item, sendFn)
  if not item then return end
  local prev = RESTORE_FOCUS and hs.window.focusedWindow() or nil
  focusProject(item.name)
  hs.timer.doAfter(FOCUS_DELAY, function()
    pcall(sendFn)
    if prev then
      hs.timer.doAfter(FOCUS_DELAY, function() pcall(function() prev:focus() end) end)
    end
  end)
end

-- Write the panel's answer for the hook approval gate to pick up.
local function writeDecision(key, value)
  local path = STATUS_DIR .. "/" .. key .. ".decision"
  local f = io.open(path, "w")
  if f then
    f:write(value)
    f:close()
    print("[cc-dashboard] decision " .. value .. " -> " .. path)
  else
    print("[cc-dashboard] could not write decision file: " .. path)
  end
end

-- Dispatch a panel action against a session.
local function handleAction(action, key, text)
  local item = byKey[key]
  if action == "focus" then
    if item then focusProject(item.name) end
    return
  end
  if not item then
    print("[cc-dashboard] action '" .. tostring(action) .. "' for unknown key " .. tostring(key))
    return
  end

  if action == "approve" then
    if item.gate == "waiting" then
      writeDecision(key, "allow")            -- hands-free, no window switch
    else
      actOnProject(item, function() hs.eventtap.keyStroke(KEY_APPROVE.mods, KEY_APPROVE.key) end)
    end
  elseif action == "deny" then
    if item.gate == "waiting" then
      writeDecision(key, "deny")
    else
      actOnProject(item, function() hs.eventtap.keyStroke(KEY_DENY.mods, KEY_DENY.key) end)
    end
  elseif action == "stop" then
    actOnProject(item, function() hs.eventtap.keyStroke(KEY_STOP.mods, KEY_STOP.key) end)
  elseif action == "nudge" then
    if text and #text > 0 then
      actOnProject(item, function()
        hs.eventtap.keyStrokes(text)
        hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({}, "return") end)
      end)
    end
  end
end

-- Single message bridge. JS posts JSON: {a=action, v=key, text=optional}.
local controller = hs.webview.usercontent.new("cc")
controller:setCallback(function(msg)
  local okj, payload = pcall(hs.json.decode, msg.body)
  if not okj or not payload then
    print("[cc-dashboard] bad message: " .. tostring(msg.body))
    return
  end
  local a = tostring(payload.a or "")
  if a == "theme" then
    hs.settings.set("ccDashboardTheme", tostring(payload.v))
    print("[cc-dashboard] theme saved: " .. tostring(payload.v))
  else
    handleAction(a, tostring(payload.v or ""), payload.text and tostring(payload.text) or nil)
  end
end)

-- Read every status file into a list, tagging each with its key (filename base)
-- and a stale flag. Decision / heartbeat files are skipped (not .json).
local function readStatuses()
  local list = {}
  local now = os.time()
  local ok, iterFn, dirObj = pcall(hs.fs.dir, STATUS_DIR)
  if not ok or type(iterFn) ~= "function" then return list end
  for file in iterFn, dirObj do
    local key = file:match("^(.+)%.json$")
    if key then
      local path = STATUS_DIR .. "/" .. file
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        if content and #content > 0 then
          local okj, data = pcall(hs.json.decode, content)
          if okj and data and data.name then
            data.key = key
            data.stale = (data.updated ~= nil) and ((now - data.updated) > STALE_SECONDS) or false
            table.insert(list, data)
          end
        end
      end
    end
  end
  -- Approvals first (they need you), then by name for stability.
  local rank = { approval = 0, done = 1, working = 2, idle = 3 }
  table.sort(list, function(a, b)
    local ra, rb = rank[a.status] or 9, rank[b.status] or 9
    if ra ~= rb then return ra < rb end
    return (a.name or "") < (b.name or "")
  end)
  return list
end

-- ---- Stream Deck support (optional, plug-and-play) ----------------------
-- Mirrors the on-screen panel onto a physical Elgato Stream Deck and reuses the
-- exact same actions (handleAction/focusProject). One session per key, colored
-- by status; short-press jumps (or approves a gate-waiting session), long-press
-- denies a waiting gate (or stops, if SD_LONG_PRESS_STOPS). Adapts to any deck.
local sd = { deck = nil, count = SD_FALLBACK_KEYS, size = { w = 72, h = 72 },
             buttons = {}, downAt = {}, blink = false }

local SD_COLORS = {
  idle     = { red = 0.42, green = 0.45, blue = 0.50 },
  working  = { red = 0.96, green = 0.71, blue = 0.04 },
  done     = { red = 0.13, green = 0.77, blue = 0.37 },
  approval = { red = 0.94, green = 0.27, blue = 0.27 },
}
local SD_LABELS = { idle = "idle", working = "working", done = "ready", approval = "NEEDS YOU" }

-- Render a key image for a session (or a blank dark key when item is nil).
local function sdButtonImage(item)
  local w, h = sd.size.w, sd.size.h
  local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
  if not item then
    c[1] = { type = "rectangle", action = "fill", fillColor = { red = 0.07, green = 0.07, blue = 0.09 } }
    local img = c:imageFromCanvas(); c:delete(); return img
  end
  local st = item.status or "idle"
  local col = SD_COLORS[st] or SD_COLORS.idle
  if st == "approval" and sd.blink then  -- blink the urgent ones
    col = { red = col.red * 0.35, green = col.green * 0.35, blue = col.blue * 0.35 }
  end
  c[1] = { type = "rectangle", action = "fill", fillColor = col,
           roundedRectRadii = { xRadius = 10, yRadius = 10 } }
  local name = item.name or "?"
  if #name > 12 then name = name:sub(1, 11) .. "\226\128\166" end
  c[2] = { type = "text", text = name, textColor = { white = 1.0 }, textSize = h * 0.18,
           frame = { x = 3, y = h * 0.12, w = w - 6, h = h * 0.42 }, textAlignment = "center" }
  c[3] = { type = "text", text = SD_LABELS[st] or st, textColor = { white = 0.0, alpha = 0.75 },
           textSize = h * 0.13, frame = { x = 3, y = h * 0.60, w = w - 6, h = h * 0.3 },
           textAlignment = "center" }
  local img = c:imageFromCanvas(); c:delete(); return img
end

-- Paint every key from the current (already sorted) session list.
local function sdRender(list)
  if not sd.deck then return end
  for i = 1, sd.count do
    local item = list[i]
    sd.buttons[i] = item and item.key or nil
    local ok, img = pcall(sdButtonImage, item)
    if ok and img then pcall(function() sd.deck:setButtonImage(i, img) end) end
  end
  if #list > sd.count then
    print("[cc-streamdeck] " .. (#list - sd.count) .. " session(s) beyond the "
          .. sd.count .. " keys aren't on the deck (still on the panel)")
  end
end

-- Short press = Jump (or Approve if a gate is waiting).
-- Long press  = Deny (gate waiting) or Stop (only if SD_LONG_PRESS_STOPS).
local function sdOnButton(deck, button, isDown)
  if isDown then sd.downAt[button] = hs.timer.secondsSinceEpoch(); return end
  local t0 = sd.downAt[button]; sd.downAt[button] = nil
  local held = t0 and (hs.timer.secondsSinceEpoch() - t0) or 0
  local key = sd.buttons[button]
  if not key or not byKey[key] then return end
  local item = byKey[key]
  local long = held >= SD_LONG_PRESS
  local action
  if item.gate == "waiting" then
    action = long and "deny" or "approve"
  elseif long and SD_LONG_PRESS_STOPS then
    action = "stop"
  else
    action = "focus"
  end
  print("[cc-streamdeck] key " .. button .. " " .. (long and "long" or "short")
        .. " -> " .. action .. " " .. tostring(key))
  handleAction(action, key)
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
        sdRender(readStatuses())
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
  #theme { background:#21232c; color:#e8e9ee; border:1px solid #2c2f3a;
           border-radius:8px; font-size:12px; padding:3px 6px; }

  /* shared bits */
  #grid { display:grid; gap:8px; padding:10px; }
  .tile { cursor:pointer; position:relative; }
  .tile.sel { outline:2px solid #6ea8fe; outline-offset:1px; }
  .tile.stale { opacity:.45; }
  .name { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .dot  { border-radius:50%; flex:0 0 auto; }
  .meta { font-size:11px; color:#8a8d99; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  #empty { color:#6b7280; font-size:13px; padding:18px; text-align:center; }

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
  #d-pending { font-size:12px; color:#f3b1b1; margin:6px 0 0; }
  #d-actions { display:flex; flex-wrap:wrap; gap:6px; margin-top:10px; }
  #d-actions button { background:#21232c; color:#e8e9ee; border:1px solid #2c2f3a;
                      border-radius:8px; font-size:12px; padding:5px 10px; cursor:pointer; }
  #d-actions button:hover { background:#2b2e39; }
  #b-approve { border-color:#22c55e; color:#7ee2a0; }
  #b-deny, #b-stop { border-color:#ef4444; color:#f3a1a1; }
  #nudge-row { display:flex; gap:6px; margin-top:8px; }
  #nudge { flex:1; background:#1b1d24; color:#e8e9ee; border:1px solid #2c2f3a;
           border-radius:8px; font-size:12px; padding:5px 8px; }
  #b-nudge { background:#21232c; color:#cfd2db; border:1px solid #2c2f3a;
             border-radius:8px; font-size:12px; padding:5px 10px; cursor:pointer; }
</style></head>
<body class="theme-__INIT_THEME__" data-theme="__INIT_THEME__">
  <div id="bar">
    <span class="t">Claude sessions</span>
    <select id="theme" onchange="onThemeChange()">
      <option value="cards">Cards</option>
      <option value="bar">Bar</option>
      <option value="contrast">Contrast</option>
      <option value="dots">Dots</option>
    </select>
  </div>
  <div id="grid"></div>
  <div id="empty">Waiting for Claude Code sessions...<br>Start a session in any project.</div>

  <div id="detail">
    <div id="d-head">
      <span id="d-dot"></span>
      <span id="d-name"></span>
      <span id="d-status"></span>
    </div>
    <div id="d-pending"></div>
    <div id="d-prompt"></div>
    <div id="d-actions">
      <button id="b-jump"    onclick="act('focus')">Jump</button>
      <button id="b-approve" onclick="act('approve')">Approve</button>
      <button id="b-deny"    onclick="act('deny')">Deny</button>
      <button id="b-stop"    onclick="act('stop')">Stop</button>
    </div>
    <div id="nudge-row">
      <input id="nudge" placeholder="Type a nudge and press Enter..." onkeydown="onNudgeKey(event)">
      <button id="b-nudge" onclick="sendNudge()">Send</button>
    </div>
  </div>

  <script>
    var LABELS = { idle:"Idle", working:"Working",
                   approval:"Needs you", done:"Ready for you" };
    var COLORS = { idle:"#6b7280", working:"#f5b50a", done:"#22c55e", approval:"#ef4444" };
    var lastItems = [];
    var selectedKey = null;

    function send(a, v, text){
      try { window.webkit.messageHandlers.cc.postMessage(JSON.stringify({a:a, v:v||"", text:text||""})); }
      catch(e){ console.log("send error", e); }
    }
    function act(a){ if(selectedKey) send(a, selectedKey); }
    function sendNudge(){
      var el = document.getElementById("nudge");
      var t = (el.value || "").trim();
      if(selectedKey && t){ send("nudge", selectedKey, t); el.value=""; }
    }
    function onNudgeKey(e){ if(e.key === "Enter"){ e.preventDefault(); sendNudge(); } }

    function onThemeChange(){
      var t = document.getElementById("theme").value;
      document.body.className = "theme-" + t;
      send("theme", t);
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
    function selectTile(key){ selectedKey = key; renderDetail(); paintSelection(); }
    function paintSelection(){
      var tiles = document.querySelectorAll(".tile");
      tiles.forEach(function(t){ t.classList.toggle("sel", t.dataset.key === selectedKey); });
    }

    function renderDetail(){
      var d = document.getElementById("detail");
      var it = selectedKey ? findItem(selectedKey) : null;
      if(!it){ d.classList.remove("show"); selectedKey=null; return; }
      d.classList.add("show");
      var st = it.status || "idle";
      document.getElementById("d-dot").style.setProperty("--dc", COLORS[st] || "#6b7280");
      document.getElementById("d-dot").style.background = COLORS[st] || "#6b7280";
      document.getElementById("d-name").textContent = it.name || "?";
      document.getElementById("d-status").textContent =
        (LABELS[st] || st) + (it.since ? " - " + fmtAge(it.since) : "") + (it.stale ? " - stale" : "");
      var pend = document.getElementById("d-pending");
      if(it.pending && it.pending.summary){
        pend.textContent = "Wants: " + it.pending.summary + (it.gate === "waiting" ? "  (hands-free approve)" : "");
        pend.style.display = "block";
      } else { pend.style.display = "none"; }
      var pr = document.getElementById("d-prompt");
      if(it.last_prompt){ pr.textContent = "Last: " + it.last_prompt; pr.style.display="block"; }
      else { pr.style.display="none"; }
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
        var cls = "tile s-" + st + (it.stale ? " stale" : "") + (it.key === selectedKey ? " sel" : "");
        return '<div class="'+cls+'" data-key="'+esc(it.key)+'" onclick="selectTile(\''+esc(it.key)+'\')">'
             + '<span class="dot"></span>'
             + '<span class="name">'+esc(it.name)+'</span>'
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

-- Build and show the panel in the top-right of the main screen.
local screen = hs.screen.mainScreen():frame()
local rect = { x = screen.x + screen.w - PANEL_W - 20, y = screen.y + 40, w = PANEL_W, h = 320 }

local wv = hs.webview.new(rect, { developerExtrasEnabled = true }, controller)
wv:windowStyle(
  hs.webview.windowMasks.titled |
  hs.webview.windowMasks.closable |
  hs.webview.windowMasks.resizable |
  hs.webview.windowMasks.utility |
  hs.webview.windowMasks.nonactivating
)
wv:windowTitle("Claude Sessions")
wv:level(hs.drawing.windowLevels.floating)
wv:behavior(hs.drawing.windowBehaviors.canJoinAllSpaces | hs.drawing.windowBehaviors.stationary)
wv:html(HTML)
wv:show()
print("[cc-dashboard] panel shown")

-- Heartbeat so the approval gate knows the panel is alive (and won't block a
-- session waiting on a panel that isn't running).
local function writeHeartbeat()
  local f = io.open(HEARTBEAT, "w")
  if f then f:write(tostring(os.time())); f:close() end
end

-- Push current statuses into the webview and refresh the action lookup table.
local function refresh()
  local list = readStatuses()
  byKey = {}
  for _, it in ipairs(list) do byKey[it.key] = it end
  writeHeartbeat()
  sd.blink = not sd.blink
  sdRender(list)
  local json = (#list == 0) and "[]" or hs.json.encode(list)
  wv:evaluateJavaScript("window.ccUpdate(" .. json .. ")")
end

-- Ensure the status dir exists so the watcher has something to watch.
hs.fs.mkdir(STATUS_DIR)

-- Poll on a timer, and also react instantly to file changes.
M.timer = hs.timer.doEvery(POLL_SECONDS, refresh)
M.watcher = hs.pathwatcher.new(STATUS_DIR, function() refresh() end):start()
sdStart()  -- begin Stream Deck discovery (no-op if none plugged in)
refresh()

-- Keep references alive so Lua does not garbage-collect them.
_G.__ccDashboard = { webview = wv, controller = controller, module = M }
print("[cc-dashboard] loaded; watching " .. STATUS_DIR)

return M
