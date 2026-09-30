-- audit-preset.test.lua : BEHAVIORAL fixture (2026-09-29, build program unit 38) for the find-only
-- audit preset. Loads the real claude-dashboard.lua under a stubbed hs (the ask.test.lua stubs:
-- the panel's message channel kept, hs.task.new recorded) and:
--   1. lets the load-time refresh auto-sync an enrolled project whose audit findings file just
--      changed, and reads the My List push: findings are tagged, never done, Already works left out;
--   2. posts what the 🔍 Audit (find-only) chip posts, and reads the kitty argv the spawn built and
--      the settings / MCP files it wrote under ~/.claude/cc-audit/<project>/.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- audit-preset.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: an enrolled project (no git), a TODO.md and an audit's findings file -----------
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local PROJ = T .. "/shop"
local SLUG = PROJ:gsub("[^%w]", "-")
local ADIR = T .. "/.claude/cc-audit/" .. SLUG            -- the launch files (settings, MCP config)
local FDIR = T .. "/.cc-audit/" .. SLUG                   -- the findings, outside any .claude folder
local FINDINGS = FDIR .. "/AUDIT-FINDINGS.md"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. PROJ .. '" "' .. FDIR .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function read(path) local f = io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
write(T .. "/status/w1.json", string.format(
  '{"status":"idle","session_id":"w1","name":"shop","cwd":"%s","since":%d,"updated":%d,"editor":"kitty"}', PROJ, now, now))
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = {},
  todoMeta = { [PROJ] = { cwd = PROJ, mtime = 1, seen = {} } } }))
write(PROJ .. "/TODO.md", "- [ ] a line from TODO.md\n")
write(FINDINGS, table.concat({
  "# Audit findings — " .. PROJ,
  "- [ ] [HIGH] AUD-001 Checkout button does nothing on /cart",
  "- [x] [LOW] AUD-002 Footer link 404s",
  "## Already works",
  "- Login with a valid account",
}, "\n") .. "\n")
write(T .. "/.claude/cc-config.json", json.encode({ spawn = { live = true, editor = "kitty" },
  remoteControl = { onSpawn = false } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs -----------------------------------------------------------------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, tasks, panelCb = {}, {}, nil
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local function under(path, dir) return path == dir or path:sub(1, #dir + 1) == dir .. "/" end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    -- the two watched files changed 10s ago (past auto-sync's 2s settle guard); the audit folder
    -- answers for real, so the spawn's mkdir -p and writes land; everything else is absent
    attributes = function(path, attr)
      path = tostring(path)
      if path == PROJ .. "/TODO.md" or path == FINDINGS then
        if attr == "modification" then return now - 10 end
        return { mode = "file", modification = now - 10 }
      end
      if under(path, T .. "/.claude/cc-audit") then
        local ok = os.execute('test -e "' .. path .. '"')
        if ok == true or ok == 0 then return attr and "directory" or { mode = "directory" } end
      end
      return nil, "cannot obtain information from file '" .. path .. "': No such file or directory"
    end,
    mkdir = function(path)
      if under(tostring(path), T) then os.execute('mkdir -p "' .. tostring(path) .. '"') end
      return true
    end,
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
    return setmetatable({ setCallback = function(_, fn) panelCb = fn end }, { __index = function() return function() return mkstub() end end })
  end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
rawset(hs.task, "new", function(bin, _, args)
  tasks[#tasks + 1] = { bin = bin, args = args }
  return { start = function() end }
end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end

-- ---- 1. the findings file imports into My List ---------------------------------------------
local payload
for _, s in ipairs(jsCalls) do
  local body = s:match("^window%.ccWorklist%((.*)%)$")
  if body then payload = json.decode(body) end
end
check("auto-sync read the changed findings file and pushed My List", payload ~= nil)
local items = {}
for _, p in ipairs((payload or {}).projects or {}) do
  if p.key == PROJ then for _, it in ipairs(p.items or {}) do items[it.text] = it end end
end
local f1 = items["[HIGH] AUD-001 Checkout button does nothing on /cart"]
check("a finding is in the project's list", f1 ~= nil)
check("...tagged as an audit finding, with its severity and id",
      f1 and type(f1.audit) == "table" and f1.audit.sev == "HIGH" and f1.audit.id == "AUD-001")
check("...and open, with no automation claim", f1 and f1.done == false and f1.fileDone == nil)
local f2 = items["[LOW] AUD-002 Footer link 404s"]
check("an [x] finding imports open too (an auditor fixes nothing)", f2 and f2.done == false and f2.fileDone == nil)
check("the TODO.md line is there as before", items["a line from TODO.md"] ~= nil)
check("Already works lines never become items", items["Login with a valid account"] == nil)

-- ---- 2. the Audit (find-only) chip spawns the find-only session ------------------------------
check("the panel's message channel is wired", type(panelCb) == "function")
if type(panelCb) ~= "function" then finish() end
quiet(function() panelCb({ body = json.encode({ a = "spawn", v = "", text = "", img = "", mode = "existing",
  dir = PROJ, editor = "kitty", permMode = "acceptEdits", provider = "", preset = "audit" }) }) end)
local t = tasks[#tasks]
check("the chip launched one kitty session", t ~= nil)
if not t then finish() end
local argv = t.args
local joined = table.concat(argv, "\n")
local function has(s) return joined:find(s, 1, true) ~= nil end
local function after(flag) for i, a in ipairs(argv) do if a == flag then return argv[i + 1] end end end
check("in dontAsk mode, whatever the dialog's mode said", after("--permission-mode") == "dontAsk" and not has("acceptEdits"))
check("allowed: Read Grep Glob, playwright, and one Edit rule -- the findings file",
      has("--allowedTools=Read Grep Glob mcp__playwright__* Edit(/" .. FINDINGS .. ")"))
local ST, MC = ADIR .. "/settings.json", ADIR .. "/mcp.json"
check("--settings names the settings file it wrote", after("--settings") == ST)
-- 2026-09-30 requirement change: --mcp-config is variadic, so its value rides the = form (one element)
check("--mcp-config names the MCP config it wrote, strict", has("\n--mcp-config=" .. MC .. "\n") and has("--strict-mcp-config"))
check("no --add-dir (a variadic flag before the task would eat it)", not has("--add-dir"))
check("the seed prompt is the last argument and names the findings file",
      tostring(argv[#argv]):find("Audit this project", 1, true) == 1 and tostring(argv[#argv]):find(FINDINGS, 1, true) ~= nil)
local settings = json.decode(read(ST) or "null")
local deny = {}
for _, d in ipairs(type(settings) == "table" and settings.permissions and settings.permissions.deny or {}) do deny[d] = true end
check("the settings file denies Bash and every edit in the project, whatever a hook allows",
      deny.Bash and deny["Edit(/" .. PROJ .. "/**)"])
local mcp = json.decode(read(MC) or "null")
check("the MCP config runs playwright, its files in the audit folder",
      type(mcp) == "table" and mcp.mcpServers and mcp.mcpServers.playwright
      and table.concat(mcp.mcpServers.playwright.args, " "):find("--output-dir " .. ADIR .. "/playwright", 1, true) ~= nil)
check("the project folder itself got nothing (the audit never writes the repo)",
      read(PROJ .. "/settings.json") == nil and read(PROJ .. "/AUDIT-FINDINGS.md") == nil)
finish()
