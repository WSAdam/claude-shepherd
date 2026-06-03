-- claude-dashboard.lua  (bootstrap)
--
-- Babysitter: a floating, always-on-top fleet console for Claude Code sessions.
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

-- ---- config -------------------------------------------------------------
-- Honor CC_STATUS_DIR like the shell scripts so tests/dev can redirect state.
local STATUS_DIR = os.getenv("CC_STATUS_DIR") or (os.getenv("HOME") .. "/.claude/cc-status")
local HEARTBEAT  = STATUS_DIR .. "/.panel-alive"
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
-- -------------------------------------------------------------------------

core.STALE_SECONDS = STALE_SECONDS

-- session key (status filename base) -> latest item, for resolving actions.
local byKey = {}
local lastJumpKey = nil  -- for the cycle-jump hotkey

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

-- Focus the editor window whose title contains the project name. Returns true if
-- a specific window was focused (switches Spaces automatically).
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

-- ---- the real effects layer (cc-core calls these; tests swap a recorder) ----
local FX = {}
function FX.now() return os.time() end
function FX.log(m) print(m) end

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

function FX.writeFile(path, content)
  local f = io.open(path, "w"); if f then f:write(content); f:close() end
end

function FX.writeDecision(key, value)
  FX.writeFile(STATUS_DIR .. "/" .. key .. ".decision", value)
  print("[cc-dashboard] decision " .. tostring(value) .. " -> " .. tostring(key))
end

function FX.focusWindow(name) return focusProject(name) end

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

function FX.typeIntoWindow(name, text)
  sendToWindow(name, function()
    hs.eventtap.keyStrokes(text)
    hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({}, "return") end)
  end)
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
    return
  end
  local item = byKey[tostring(payload.v or "")]
  if not item then
    print("[cc-dashboard] action '" .. a .. "' for unknown key " .. tostring(payload.v))
    return
  end
  core.handleAction(FX, item, a, payload.text and tostring(payload.text) or nil)
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
  local list = core.parseStatusList(entries, FX.now(), STALE_SECONDS)
  byKey = {}
  for _, it in ipairs(list) do byKey[it.key] = it end
  return list
end

-- Push current statuses into the webview + deck, and keep the heartbeat fresh.
local function refresh()
  local list = refreshList()
  FX.writeFile(HEARTBEAT, tostring(FX.now()))
  sd.blink = not sd.blink
  sdRender(list)
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
        hs.alert.show("Babysitter: nothing waiting")
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
_G.__ccDashboard = { webview = wv, controller = controller, module = M, core = core }
print("[cc-dashboard] loaded; watching " .. STATUS_DIR)

return M
