-- worklist-playbooks.test.lua : BEHAVIORAL fixture for playbooks as My List sources.
--
-- 2026-10-03 (mining round 2, unit D3a): "📘 Add a playbook…" on a project's My List tab picks a
-- markdown file through a NATIVE chooser (hs.dialog.chooseFileOrFolder via FX.choosePlaybookFile,
-- never a path typed into the webview), and its `- [ ]` lines import like TODO.md's. The badges
-- follow the file as it changes (a per-tick mtime watch, like TODO.md's), and "Remove playbook"
-- stops the import while its items stay to be verified.
--
-- Loads the real claude-dashboard.lua under the stubbed hs, capturing the webview controller's
-- callback so the test posts real bridge messages, with the chooser stubbed to answer a path.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish()
  print("-- worklist-playbooks.test.lua: " .. run .. " run, " .. failed .. " failed --")
  os.exit(failed == 0 and 0 or 1)
end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/proj" "' .. T .. '/notes" "' .. T .. '/.claude"')
local PROJ = T .. "/proj"                 -- no transcript_path, so projectKey == cwd
local PB = T .. "/notes/release-checklist.md"
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readf(path) local h = io.open(path, "r"); if not h then return nil end
  local s = h:read("*a"); h:close(); return s end

write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"proj","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
  PROJ, now, now))
write(PROJ .. "/TODO.md", "- [ ] a TODO.md line\n")
local PB_TEXT = "# Release\n\nSome prose.\n- [ ] tag the build\n- [x] write the notes\n- [~] look at the store page\n"
write(PB, PB_TEXT)
local WL = T .. "/worklist.json"
write(WL, json.encode({ generic = {}, byProject = {}, todoMeta = {} }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_LABELS_FILE = T .. "/labels.json",
              CC_WORKLIST_FILE = WL, HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end; return realGetenv(k) end

-- ---- stubbed hs, with the controller callback and the chooser captured -------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, CALLBACK = {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
-- mtimes are served from a table the test controls, so "the file changed" is exact
local MTIME = {}
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      local h = io.open(path, "r")
      if not h then return nil, "cannot obtain information from file '" .. tostring(path) .. "'" end
      local sz = #(h:read("*a")); h:close()
      local m = MTIME[path] or (now - 100)
      if attr == "modification" then return m end
      if attr == "size" then return sz end
      return { mode = "file", modification = m, size = sz }
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,
  new = function() return mkstub() end, usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
hs.webview = setmetatable({
  windowMasks  = setmetatable({}, { __index = function() return 0 end }),
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return webviewHandle() end,
  usercontent = { new = function()
    return setmetatable({ setCallback = function(_, fn) CALLBACK = fn end },
      { __index = function() return function() return mkstub() end end })
  end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
-- The native chooser: records how it was asked, answers CHOOSE (Hammerspoon's real shape is a
-- table keyed "1", "2", ... -- string keys), or nil for Cancel.
local CHOOSE, chooserCalls, MODAL_DURING = nil, {}, nil
local dash
hs.dialog = setmetatable({
  chooseFileOrFolder = function(...)
    chooserCalls[#chooserCalls + 1] = { ... }
    MODAL_DURING = dash and dash.fx._modalActive
    if CHOOSE == nil then return nil end
    return { ["1"] = CHOOSE }
  end,
}, { __index = function() return function() return mkstub() end end })
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads" .. (ok and "" or ("  (" .. tostring(err) .. ")")), ok)
if not ok then finish() end
dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
check("the controller callback was captured, so the test can post real messages", type(CALLBACK) == "function")
if type(CALLBACK) ~= "function" then finish() end

local function post(tbl) quiet(function() CALLBACK({ body = json.encode(tbl) }) end) end
local function store() return json.decode(readf(WL) or "{}") or {} end
local function lastCall(fnName)
  local pat = "^window%." .. fnName .. "%((.*)%)$"
  for i = #jsCalls, 1, -1 do
    local body = jsCalls[i]:match(pat)
    if body then return json.decode(body) end
  end
end
local function projOf(payload)
  for _, p in ipairs((payload or {}).projects or {}) do if p.key == PROJ then return p end end
end
local function pbItems(st)
  local out = {}
  for _, it in ipairs(((st or {}).byProject or {})[PROJ] or {}) do
    if it.src == "playbook" then out[#out + 1] = it end
  end
  return out
end

-- ---- 1. Cancel: nothing is added ------------------------------------------
jsCalls, CHOOSE = {}, nil
post({ a = "worklist-playbook-add", v = PROJ })
check("Add a playbook opens the native chooser", #chooserCalls == 1)
local args = chooserCalls[1] or {}
check("...starting in the project's folder  (" .. tostring(args[2]) .. ")", args[2] == PROJ)
check("...files only, one at a time", args[3] == true and args[4] == false and args[5] == false)
local types = type(args[6]) == "table" and table.concat(args[6], ",") or ""
check("...markdown only  (" .. types .. ")", types:find("md", 1, true) ~= nil)
check("...inside FX.runModal, so a keystroke chain can't press the dialog's default button", MODAL_DURING == true)
check("Cancel adds nothing", next((store().playbooks or {})) == nil and #pbItems(store()) == 0)

-- ---- 2. A path in the message is never used: only the chooser names the file ----
post({ a = "worklist-playbook-add", v = PROJ, text = PB, path = PB })
check("a path carried in the webview message is ignored", next((store().playbooks or {})) == nil)

-- ---- 3. Pick the playbook: its lines import, grouped under its name ----
jsCalls, CHOOSE = {}, PB
post({ a = "worklist-playbook-add", v = PROJ })
local st = store()
local sources = ((st.playbooks or {})[PROJ]) or {}
check("picking a file adds it as the tab's source", #sources == 1 and sources[1].path == PB)
local items = pbItems(st)
check("its checkbox lines import  (n=" .. #items .. ")", #items == 3)
check("...tagged with the file's path and name", items[1] and items[1].srcFile == PB
      and items[1].srcName == "release-checklist.md")
check("...the [x] line as the ✓ auto badge", items[2] and items[2].fileDone == true)
check("...the [~] line as ▶ live run", items[3] and items[3].liveRun == true)
check("HARD RULE: importing a playbook checks nothing off", items[2] and items[2].done == false and items[2].doneTs == nil)
check("the tab is NOT enrolled in TODO.md sync by a playbook", ((st.todoMeta or {})[PROJ]) == nil)
local payload = lastCall("ccWorklist")
local p = projOf(payload)
check("the panel is told: the tab lists the playbook", p and type(p.playbooks) == "table" and #p.playbooks == 1
      and p.playbooks[1].name == "release-checklist.md" and type(p.playbooks[1].id) == "string")
local res = lastCall("ccPlaybookResult")
check("...and gets a result to show  (" .. json.encode(res or {}) .. ")", res and res.name == "release-checklist.md" and res.added == 3)
check("the playbook file is never written", readf(PB) == PB_TEXT)

-- ---- 4. The same file again is refused, and so is the project's own TODO.md ----
jsCalls = {}
post({ a = "worklist-playbook-add", v = PROJ })
res = lastCall("ccPlaybookResult")
check("the same playbook twice is refused, with a reason", res and type(res.error) == "string" and res.error ~= "")
check("...and still listed once", #(((store().playbooks or {})[PROJ]) or {}) == 1)
jsCalls, CHOOSE = {}, PROJ .. "/TODO.md"
post({ a = "worklist-playbook-add", v = PROJ })
res = lastCall("ccPlaybookResult")
check("the project's own TODO.md is refused (it already imports)", res and type(res.error) == "string"
      and #(((store().playbooks or {})[PROJ]) or {}) == 1)
jsCalls, CHOOSE = {}, PB
post({ a = "worklist-playbook-add", v = "generic" })
check("never on the Generic tab", #(((store().playbooks or {}).generic) or {}) == 0)

-- ---- 5. The badges follow the file: the per-tick watch re-imports a changed playbook ----
write(PB, "- [x] tag the build\n- [ ] write the notes\n- [x] look at the store page\n- [ ] a new step\n")
MTIME[PB] = os.time()             -- changed this second: inside the 2s settle guard
jsCalls = {}
quiet(function() fx.playbookSyncTick() end)
check("a file changed under 2s ago waits (an automation may be mid-write)", pbItems(store())[1].fileDone ~= true)
MTIME[PB] = os.time() - 10
quiet(function() fx.playbookSyncTick() end)
items = pbItems(store())
check("a settled change re-imports: fileDone follows the file, on", items[1] and items[1].fileDone == true)
check("...and off", items[2] and items[2].fileDone == nil)
check("...liveRun too", items[3] and items[3].liveRun == nil)
check("...and a new line arrives  (n=" .. #items .. ")", #items == 4 and items[4].text == "a new step")
check("HARD RULE: the sync checks nothing off", items[1].done == false and items[1].doneTs == nil)
check("...and the panel is told", lastCall("ccWorklist") ~= nil)
jsCalls = {}
quiet(function() fx.playbookSyncTick() end)
check("an unchanged file costs no re-import or push", lastCall("ccWorklist") == nil)

-- ---- 6. Remove playbook: the import stops, the items stay ----
local id = (((store().playbooks or {})[PROJ]) or {})[1].id
jsCalls = {}
post({ a = "worklist-playbook-remove", v = PROJ, text = id })
p = projOf(lastCall("ccWorklist"))
check("Remove playbook drops it from the tab's list", p and (p.playbooks == nil or #p.playbooks == 0))
check("...and every item stays, to be verified  (n=" .. #pbItems(store()) .. ")", #pbItems(store()) == 4)
res = lastCall("ccPlaybookResult")
check("...with a result to show", res and res.removed == "release-checklist.md")
write(PB, "- [ ] tag the build\n- [ ] write the notes\n- [ ] look at the store page\n- [ ] a new step\n- [ ] later\n")
MTIME[PB] = os.time() - 5
quiet(function() fx.playbookSyncTick() end)
items = pbItems(store())
check("a removed playbook is no longer synced", #items == 4 and items[1].fileDone == true)

os.execute('rm -r "' .. T .. '"')
finish()
