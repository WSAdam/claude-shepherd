-- compact.test.lua : auto-compact with notes, the panel side (build program unit 16, 2026-09-29).
-- 2026-09-29: sessions compacted at Claude Code's own threshold (~96% of a 1M window) and the summary
-- dropped whatever it didn't keep. Shepherd now sets env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in
-- ~/.claude/settings.json (FX.setClaudeSettingsEnv: that one key, atomically, through symlinks) and
-- leaves each live session a due-at (~/.claude/cc-notes/<key>.due-at) a few percent before the
-- threshold, so cc-status.sh stop has the session write its notes first. Pure maths and decisions
-- through core; the real FX functions under a stubbed Hammerspoon in a temp HOME, with the settings
-- writer run for real by bash + jq against temp files -- never the real ~/.claude/settings.json.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end
local function finish()
  print(string.format("-- compact.test.lua: %d run, %d failed --", run, failed))
  os.exit(failed == 0 and 0 or 1)
end

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local HOME = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(HOME ~= "", "could not mktemp a HOME")
local NOTES = HOME .. "/.claude/cc-notes"
sh("mkdir -p " .. q(HOME .. "/.claude/cc-scratch") .. " " .. q(HOME .. "/.claude/cc-ledger") .. " "
   .. q(HOME .. "/status") .. " " .. q(NOTES) .. " " .. q(HOME .. "/dotfiles"))
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function jqOut(filter, path) return (sh("jq -c " .. q(filter) .. " " .. q(path) .. " 2>/dev/null"):gsub("%s+$", "")) end

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = core.json or json

-- ---- compaction settings (2026-09-29) --------------------------------------------------------
local cc = core.compactConfig({})
eq("off unless compact.enabled", cc.enabled, false)
eq("compacts at 85% by default", cc.atPct, 85)
eq("notes 5 points earlier by default", cc.leadPct, 5)
cc = core.compactConfig({ compact = { enabled = true, atPct = 70, notesLeadPct = 10 } })
check("the settings are read", cc.enabled == true and cc.atPct == 70 and cc.leadPct == 10)
eq("a nonsense atPct falls back to 85", core.compactConfig({ compact = { atPct = "lots" } }).atPct, 85)
eq("...an out-of-range one too (Claude Code takes 1-100)", core.compactConfig({ compact = { atPct = 250 } }).atPct, 85)
eq("the driver's live check can go as low as 10", core.compactConfig({ compact = { atPct = 10 } }).atPct, 10)
eq("a lead that would put the notes at or below zero is cut to fit", core.compactConfig({ compact = { atPct = 10, notesLeadPct = 40 } }).leadPct, 9)
eq("a lead below 1 falls back to 5", core.compactConfig({ compact = { notesLeadPct = 0 } }).leadPct, 5)

-- ---- Claude Code's own threshold, and the due-at before it (the [1m] window too) ----
-- Claude Code 2.1: auto-compact fires at min(floor(eff * pct / 100), eff - 13000), where eff is the
-- window less its 20k output reserve -- so 85% of a 200k window is 153,000 tokens, not 170,000.
eq("200k at 85%: compaction at 153,000 tokens", core.compactThreshold(200000, 85), 153000)
eq("1M at 85%: 833,000", core.compactThreshold(1000000, 85), 833000)
eq("a pct above Claude Code's own default can't raise it (200k at 100%: 167,000)", core.compactThreshold(200000, 100), 167000)
local d = core.compactDue(core.compactConfig({ compact = { enabled = true } }), {}, "claude-opus-5-5", 50000, {})
check("a 200k session gets a due-at", type(d) == "table")
d = d or {}
eq("...the notes due at 144,000 tokens (5 points of the effective window before)", d.due, 144000)
eq("...compaction at 153,000", d.compactAt, 153000)
eq("...in a 200k window", d.window, 200000)
d = core.compactDue(core.compactConfig({ compact = { enabled = true } }), {}, "claude-opus-5-5", 50000, { oneM = true }) or {}
eq("[1m]: the notes due at 784,000 tokens", d.due, 784000)
eq("[1m]: compaction at 833,000", d.compactAt, 833000)
eq("[1m]: in a 1M window", d.window, 1000000)
d = core.compactDue(core.compactConfig({ compact = { enabled = true } }), {}, "claude-opus-4-7", 50000, {}) or {}
eq("a model Claude Code runs at 1M (opus-4) needs no [1m]", d.window, 1000000)
d = core.compactDue(core.compactConfig({ compact = { enabled = true } }), {}, "claude-haiku-4-5", 450000, {}) or {}
eq("a session already holding more than its model's window is measured against the next tier", d.window, 1000000)
d = core.compactDue(core.compactConfig({ compact = { enabled = true, atPct = 100 } }), {}, "claude-opus-5-5", 0, {}) or {}
check("at 100% the notes still come before compaction", (d.due or 0) < (d.compactAt or 0))
eq("a provider's own contextLimit is the window (as the context bar reads it)", (core.compactDue(core.compactConfig({ compact = { enabled = true } }),
  { providers = { { name = "gw", model = "gw-model", contextLimit = 1000000 } } }, "gw-model", 0, {}) or {}).window, 1000000)
eq("compaction off: no due-at", core.compactDue(core.compactConfig({}), {}, "claude-opus-5-5", 0, {}), nil)
eq("the due-at line the hook reads: due, compactAt, window", core.dueAtLine({ due = 144000, compactAt = 153000, window = 200000 }),
   "144000 153000 200000\n")

-- ---- which env change a sync makes ----
local on, off = core.compactConfig({ compact = { enabled = true } }), core.compactConfig({})
local function plan(cfg, synced, current) local p = core.compactEnvPlan(cfg, synced, current); return p.op .. "|" .. tostring(p.value) .. "|" .. tostring(p.synced) end
eq("on, nothing set: set 85", plan(on, nil, nil), "set|85|85")
eq("on, already 85: nothing to do (and it is ours now)", plan(on, nil, "85"), "none|nil|85")
eq("on, another value: Shepherd's 85 wins while it's on", plan(on, "85", "60"), "set|85|85")
eq("off, ours still there: remove it", plan(off, "85", "85"), "remove|nil|nil")
eq("off, a value someone else set: leave it alone", plan(off, "85", "60"), "none|nil|nil")
eq("off, a value Shepherd never wrote: leave it alone", plan(off, nil, "85"), "none|nil|nil")
eq("off, nothing there: nothing", plan(off, "85", nil), "none|nil|nil")

-- ---- the settings.json writer, run for real (bash + jq) against temp files ----
local SET = HOME .. "/settings-a.json"
local ORIG = '{\n  "model": "opus[1m]",\n  "env": {\n    "FOO": "1",\n    "BAR": "two"\n  },\n  "hooks": {\n    "Stop": []\n  },\n  "zeta": true\n}\n'
writeFile(SET, ORIG)
sh("chmod 600 " .. q(SET))
local inode0 = sh("stat -c %i " .. q(SET) .. " 2>/dev/null || stat -f %i " .. q(SET)):gsub("%s+$", "")
local function runCmd(cmd) return sh(cmd .. " 2>&1") end
local out = runCmd(core.settingsEnvCmd(SET, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85"))
check("the writer reports success", (core.settingsEnvResult(out)))
eq("...env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is \"85\" (a string, as env values must be)",
   jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", SET), '"85"')
eq("only that key: everything else is exactly as it was",
   jqOut("del(.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)", SET), (sh("printf %s " .. q(ORIG) .. " | jq -c ."):gsub("%s+$", "")))
eq("...in its order", jqOut("keys_unsorted", SET), '["model","env","hooks","zeta"]')
eq("...the other env keys first, in theirs", jqOut(".env | keys_unsorted", SET), '["FOO","BAR","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]')
local inode1 = sh("stat -c %i " .. q(SET) .. " 2>/dev/null || stat -f %i " .. q(SET)):gsub("%s+$", "")
check("atomic: the file is replaced by a rename, never rewritten in place", inode1 ~= "" and inode1 ~= inode0)
eq("...no temp file left behind", sh("ls -a " .. q(HOME) .. " | grep -c 'tmp'"):gsub("%s+$", ""), "0")
eq("...and its permissions are kept", sh("stat -c %a " .. q(SET) .. " 2>/dev/null || stat -f %Lp " .. q(SET)):gsub("%s+$", ""), "600")
out = runCmd(core.settingsEnvCmd(SET, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "70"))
eq("a new value replaces the old in place", jqOut(".env | keys_unsorted", SET), '["FOO","BAR","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]')
eq("...with the new value", jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", SET), '"70"')
out = runCmd(core.settingsEnvCmd(SET, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", nil))
check("removing reports success", (core.settingsEnvResult(out)))
eq("removing takes out only that key", jqOut(".", SET), (sh("printf %s " .. q(ORIG) .. " | jq -c ."):gsub("%s+$", "")))

-- through a symlink: the link stays a link, its target changes
local REAL = HOME .. "/dotfiles/claude-settings.json"
local LINK = HOME .. "/settings-link.json"
writeFile(REAL, '{"theme":"dark"}\n')
sh("ln -s dotfiles/claude-settings.json " .. q(LINK))
out = runCmd(core.settingsEnvCmd(LINK, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85"))
check("through a symlink: success", (core.settingsEnvResult(out)))
check("...the link is still a link", sh("[ -L " .. q(LINK) .. " ] && echo link"):find("link", 1, true) ~= nil)
eq("...and its target has the key", jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", REAL), '"85"')
eq("...next to what it had", jqOut(".theme", REAL), '"dark"')
eq("...the temp went beside the target, and is gone", sh("ls -a " .. q(HOME .. "/dotfiles") .. " | grep -c tmp"):gsub("%s+$", ""), "0")

-- a file it can't read as a settings object is left exactly as it is
local BAD = HOME .. "/settings-bad.json"
writeFile(BAD, '{"env": {"FOO": "1",}\n')
out = runCmd(core.settingsEnvCmd(BAD, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85"))
local okBad, whyBad = core.settingsEnvResult(out)
check("an unparsable settings.json is refused", not okBad)
check("...saying why", type(whyBad) == "string" and whyBad:find("parse", 1, true) ~= nil)
eq("...and left untouched", readAll(BAD), '{"env": {"FOO": "1",}\n')
local ENVSTR = HOME .. "/settings-envstr.json"
writeFile(ENVSTR, '{"env": "oops"}\n')
check("an env that isn't an object is refused too", not (core.settingsEnvResult(runCmd(core.settingsEnvCmd(ENVSTR, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85")))))
eq("...untouched", readAll(ENVSTR), '{"env": "oops"}\n')
-- no file yet: setting creates it; removing leaves no file
local NEW = HOME .. "/fresh/settings.json"
out = runCmd(core.settingsEnvCmd(NEW, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85"))
eq("no settings.json yet: setting creates one with just the key", jqOut(".", NEW), '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"85"}}')
local NONE = HOME .. "/none/settings.json"
check("...removing from a missing file succeeds", (core.settingsEnvResult(runCmd(core.settingsEnvCmd(NONE, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", nil)))))
check("...and creates nothing", not exists(NONE))
-- quoting: a value or a path with a quote in it goes through intact
local ODD = HOME .. "/it's settings.json"
writeFile(ODD, "{}\n")
out = runCmd(core.settingsEnvCmd(ODD, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "8'5"))
eq("a quote in the path or the value is safe", jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", ODD), [["8'5"]])
-- Hammerspoon is a GUI app: its PATH is the bare system one, with no Homebrew
local GUI = HOME .. "/settings-gui.json"
writeFile(GUI, "{}\n")
out = runCmd("env PATH=/usr/bin:/bin " .. core.settingsEnvCmd(GUI, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85"))
check("a GUI app's bare PATH still finds jq", (core.settingsEnvResult(out)))
eq("...and writes the key", jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", GUI), '"85"')
eq("a key that isn't an env var name is refused before any shell", core.settingsEnvCmd(SET, "BAD KEY; rm", "1"), nil)
eq("...an empty one too", core.settingsEnvCmd(SET, "", "1"), nil)

-- ---- Diagnostics (pure: facts in, rows out) ----
local function rowFor(facts, needle)
  for _, r in ipairs(core.doctorChecks({ compact = facts })) do
    if (r.label .. " " .. (r.detail or "")):find(needle, 1, true) then return r end
  end
end
local r = rowFor({ enabled = true, want = "85", current = "85", binaries = { { label = "claude CLI", knows = true } } }, "Auto-compact")
eq("on and in effect: ok", r and r.status, "ok")
r = rowFor({ enabled = true, want = "85", current = "85",
             binaries = { { label = "claude CLI", knows = true }, { label = "VS Code extension", knows = false } } }, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE")
eq("a claude that no longer mentions CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is a warning", r and r.status, "warn")
check("...naming which claude", r and (r.label .. " " .. r.detail):find("VS Code extension", 1, true) ~= nil)
r = rowFor({ enabled = true, want = "85", current = nil, binaries = {} }, "isn't set in settings.json")
eq("on but missing from settings.json: a warning", r and r.status, "warn")
check("...with the fix", r and type(r.fix) == "string" and r.fix ~= "")
r = rowFor({ enabled = true, want = "85", current = "85", binaries = { { label = "claude CLI" } } }, "Auto-compact")
eq("a claude still being checked: info, not a warning", r and r.status, "info")
r = rowFor({ enabled = false }, "Auto-compact")
eq("off: info", r and r.status, "info")

-- ---- the real FX functions under a stubbed Hammerspoon ----------------------------------------
local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function attributes(p, k)
  local out = sh("stat -c '%F|%Y|%s' " .. q(p) .. " 2>/dev/null || stat -f '%HT|%m|%z' " .. q(p) .. " 2>/dev/null")
  local kind, mtime, size = out:match("^([^|]+)|(%d+)|(%d+)")
  if not kind then return nil end
  local a = { mode = kind:lower():find("directory", 1, true) and "directory" or "file", modification = tonumber(mtime), size = tonumber(size) }
  if k then return a[k] end
  return a
end
local settingsStore, frame, executed, tasks = {}, { x = 0, y = 0, w = 1920, h = 1080 }, {}, {}
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen("ls -1a " .. q(path) .. " 2>/dev/null")
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = attributes,
    symlinkAttributes = function() return nil end,
    pathToAbsolute = function(p) local o = sh("cd \"$(dirname " .. q(p) .. ")\" 2>/dev/null && pwd -P"):gsub("%s+$", ""); return o ~= "" and (o .. "/" .. tostring(p):match("[^/]+$")) or nil end,
    mkdir = function(p) sh("mkdir " .. q(p) .. " 2>/dev/null"); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  -- every command the panel runs, run for real only when it is the settings writer -- and run the
  -- way Hammerspoon's own hs.execute runs it (_coresetup.lua): with user_env the command goes
  -- inside naive double quotes to `$SHELL -l -i -c "..."`, so the outer shell expands its $ and
  -- eats its quotes. (/bin/sh here: the same quoting, without the user's rc files.)
  -- 2026-09-29: the first writer went through the login shell that way and would have been
  -- mangled live -- an echo of the quoting the real one does is what caught it.
  execute = function(cmd, userEnv)
    executed[#executed + 1] = cmd
    if not tostring(cmd):find("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", 1, true) then return "" end
    if userEnv then return sh('/bin/sh -c "' .. cmd .. '" 2>&1'), true end
    return sh(cmd .. " 2>&1"), true
  end,
  -- hs.task: queued, run by the test when it says so (the CLI check is async in the panel)
  task = { new = function(bin, cb, args)
    local t = { bin = bin, cb = cb, args = args }
    t.start = function(self) tasks[#tasks + 1] = self; return self end
    t.isRunning = function() return false end
    return t
  end },
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
local function runTasks()
  while #tasks > 0 do
    local t = table.remove(tasks, 1)
    local cmd = q(t.bin)
    for _, a in ipairs(t.args or {}) do cmd = cmd .. " " .. q(a) end
    local o = sh(cmd .. "; echo \"@@rc:$?\"")
    local rc = tonumber(o:match("@@rc:(%d+)%s*$")) or 1
    if t.cb then t.cb(rc, (o:gsub("@@rc:%d+%s*$", "")), "") end
  end
end
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
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
check("the dashboard loads under the stub", ok)
if not ok then print("       " .. tostring(err)); finish() end
local FX = _G.__ccDashboard.fx
core = _G.__ccDashboard.core

eq("Claude Code's settings file is the one in this HOME", FX.CLAUDE_SETTINGS, HOME .. "/.claude/settings.json")
check("(never the real one)", not tostring(FX.CLAUDE_SETTINGS):find(tostring(realGetenv("HOME")) .. "/.claude/", 1, true))

-- FX.setClaudeSettingsEnv writes through the same command
local LIVE = HOME .. "/.claude/settings.json"
writeFile(LIVE, '{\n  "permissions": {"deny": ["Read(.env)"]},\n  "env": {"KEEP": "me"}\n}\n')
local okw = FX.setClaudeSettingsEnv("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "85")
check("FX.setClaudeSettingsEnv sets the key", okw == true)
eq("...in the settings file", jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", LIVE), '"85"')
eq("...keeping the rest", jqOut("[.permissions.deny[0], .env.KEEP]", LIVE), '["Read(.env)","me"]')
okw = FX.setClaudeSettingsEnv("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", nil)
check("...and removes it", okw == true and jqOut(".env | has(\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\")", LIVE) == "false")
eq("a bad key never reaches a shell", FX.setClaudeSettingsEnv("NOT OK", "1"), false)

-- FX.syncCompactEnv: config -> settings.json, remembering what Shepherd itself wrote
local function envNow() return jqOut(".env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE // \"none\"", LIVE) end
local n0 = #executed
FX.syncCompactEnv({})
eq("compaction off and never on: the sync writes nothing", #executed, n0)
FX.syncCompactEnv({ compact = { enabled = true } })
eq("turned on: settings.json gets 85", envNow(), '"85"')
n0 = #executed
FX.syncCompactEnv({ compact = { enabled = true } })
eq("...and an unchanged config doesn't touch it again", #executed, n0)
FX.syncCompactEnv({ compact = { enabled = true, atPct = 80 } })
eq("a new atPct is written", envNow(), '"80"')
FX.syncCompactEnv({ compact = { enabled = false, atPct = 80 } })
eq("turned off: Shepherd's value is removed", envNow(), '"none"')
eq("...leaving the rest", jqOut(".env.KEEP", LIVE), '"me"')
FX.syncCompactEnv({ compact = { enabled = true } })
sh("jq '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = \"60\"' " .. q(LIVE) .. " > " .. q(LIVE .. ".x") .. " && mv " .. q(LIVE .. ".x") .. " " .. q(LIVE))
FX.syncCompactEnv({ compact = { enabled = false } })
eq("turned off after someone set their own value: theirs stays", envNow(), '"60"')
FX.syncCompactEnv({ compact = { enabled = false } }, true)
eq("...even on a forced sync (a Settings Save)", envNow(), '"60"')
FX.syncCompactEnv({ compact = { enabled = true } }, true)
eq("a Save with it on puts 85 back", envNow(), '"85"')

-- ---- the due-at for each live session ----
sh("mkdir -p " .. q(HOME .. "/tr"))
local TR = HOME .. "/tr/s1.jsonl"
writeFile(TR, json.encode({ type = "assistant", message = { role = "assistant", model = "claude-opus-5-5",
  usage = { input_tokens = 10, cache_read_input_tokens = 40000, cache_creation_input_tokens = 0, output_tokens = 5 },
  content = { { type = "text", text = "hi" } } } }) .. "\n")
local tiles = {
  { key = "s1", name = "p", status = "working", cwd = HOME, transcript_path = TR, model = "claude-opus-5-5" },
  { key = "s2", name = "p", status = "done", cwd = HOME, transcript_path = TR, model = "claude-opus-5-5" },
  { key = "r1", name = "p", status = "done", cwd = HOME, transcript_path = TR, model = "claude-opus-5-5", remote = { host = "box" } },
  { key = "n1", name = "p", status = "idle", cwd = HOME, model = "claude-opus-5-5" },
  { key = "u1", name = "p", status = "idle", cwd = HOME, transcript_path = HOME .. "/tr/u1.jsonl" },
  { key = "e1", name = "p", status = "error", cwd = HOME, transcript_path = TR, model = "<synthetic>" },
}
FX.sessionOneM = function(it) return it.key == "s2" end   -- s2 runs opus[1m]
local writes = 0
local realAtomic = FX.writeFileAtomic
FX.writeFileAtomic = function(path, content) if tostring(path):find("%.due%-at$") then writes = writes + 1 end; return realAtomic(path, content) end
local cfgOn = { compact = { enabled = true } }
FX.stepCompact(tiles, cfgOn)
eq("a 200k session's due-at", readAll(NOTES .. "/s1.due-at"), "144000 153000 200000\n")
eq("an [1m] session's due-at", readAll(NOTES .. "/s2.due-at"), "784000 833000 1000000\n")
check("a remote tile gets none (its hooks run on another machine)", not exists(NOTES .. "/r1.due-at"))
check("a session with no transcript yet gets none", not exists(NOTES .. "/n1.due-at"))
check("a session whose model isn't known yet gets none (a 1M session must not be asked at 14%)", not exists(NOTES .. "/u1.due-at"))
check("an API error's <synthetic> model is no model: no due-at from it", not exists(NOTES .. "/e1.due-at"))
eq("the card knows the numbers", tiles[1].compact and tiles[1].compact.due, 144000)
local w0 = writes
FX.stepCompact(tiles, cfgOn)
eq("an unchanged due-at is not rewritten each tick", writes, w0)
FX.stepCompact(tiles, { compact = { enabled = true, atPct = 70 } })
eq("a new atPct rewrites it", readAll(NOTES .. "/s1.due-at"), "117000 126000 200000\n")
-- notes on disk: the 📝 chip and the detail line
writeFile(NOTES .. "/s1.notes.md", "# Notes\nthe task\n")
FX._notesSeen = {}
FX.stepCompact(tiles, cfgOn)
check("a session with notes carries them for the card", type(tiles[1].notes) == "table")
eq("...their size", tiles[1].notes and tiles[1].notes.bytes, 17)
check("...and when they were written", tiles[1].notes and type(tiles[1].notes.at) == "number")
eq("a session without notes carries none", tiles[2].notes, nil)
-- turned off: every due-at goes, so the hook stops asking
FX.stepCompact(tiles, {})
check("compaction off: the due-ats are removed", not exists(NOTES .. "/s1.due-at") and not exists(NOTES .. "/s2.due-at"))
eq("...and the card shows no numbers", tiles[1].compact, nil)
check("...but the notes the session wrote stay", exists(NOTES .. "/s1.notes.md"))
-- a due-at left by an earlier run (a reload with compaction off) is swept too
writeFile(NOTES .. "/old.due-at", "1 2 3\n")
FX._compactSwept = nil
FX.stepCompact(tiles, {})
check("a due-at from before a reload is swept once compaction is off", not exists(NOTES .. "/old.due-at"))
FX.writeFileAtomic = realAtomic

-- ---- Diagnostics: is CLAUDE_AUTOCOMPACT_PCT_OVERRIDE still in the installed claude? ----
local BIN_OK, BIN_OLD = HOME .. "/bin-ok/claude", HOME .. "/bin-old/claude"
sh("mkdir -p " .. q(HOME .. "/bin-ok") .. " " .. q(HOME .. "/bin-old"))
writeFile(BIN_OK, "junk\0process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\0more")
writeFile(BIN_OLD, "junk\0process.env.SOMETHING_ELSE\0more")
FX.compactBinaries = function() return { { label = "claude CLI", path = BIN_OK }, { label = "VS Code extension", path = BIN_OLD } } end
local facts = FX.compactFacts({ compact = { enabled = true } })
check("the check runs in the background (hs.task), never blocking the panel", #tasks >= 1)
eq("...so the first look says it's still checking", facts.binaries[1].knows, nil)
runTasks()
facts = FX.compactFacts({ compact = { enabled = true } })
eq("a claude that mentions the override: known", facts.binaries[1].knows, true)
eq("one that doesn't: flagged", facts.binaries[2].knows, false)
eq("...and remembered per binary, so it isn't grepped again", #tasks, 0)
eq("the facts carry what settings.json says", facts.current, "85")
eq("...and what it should say", facts.want, "85")

sh("rm -r " .. q(HOME))
finish()
