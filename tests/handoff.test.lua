-- handoff.test.lua : handoff notes under a STUBBED Hammerspoon (2026-09-28).
-- 2026-09-28: a fresh or respawned session started blank -- nothing told it what the session before
-- it did. On each done edge FX.stepTurnLabel now has the note written (~/.claude/cc-notes/<key>
-- .handoff.md: last result, files touched, errors, the worktree's open TODO lines, the transcript);
-- a respawn copies it to cc-notes/pending/ for the new session's SessionStart, and notes older than
-- 14 days are pruned. Drives the real FX functions over a real transcript window in a temp HOME;
-- git runs for real in a temp repo, everything else hs does is stubbed.

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

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local HOME = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(HOME ~= "", "could not mktemp a HOME")
local PROJ = HOME .. "/proj"
local NOTES = HOME .. "/.claude/cc-notes"
sh("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/.claude/cc-ledger' '" .. HOME .. "/status' '" .. PROJ .. "'")
sh("git -C '" .. PROJ .. "' init -q 2>/dev/null")

local json = dofile(HERE .. "support/json.lua")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end

-- the transcript: the real window tests/transcript-replay.test.lua labels "made progress", then one
-- readable turn (the fixture's scrubbed inputs name no file) that edits auth.ts and hits an error
local TRANSCRIPT = HOME .. "/sid-1.jsonl"
local function rec(t) return json.encode(t) .. "\n" end
writeFile(TRANSCRIPT, readAll(HERE .. "fixtures/transcripts/tail-turn-made-progress.jsonl")
  .. rec({ type = "user", origin = { kind = "human" }, message = { role = "user", content = { { type = "text", text = "fix login" } } } })
  .. rec({ type = "assistant", message = { role = "assistant", content = { { type = "tool_use", id = "tu_a", name = "Edit",
       input = { file_path = PROJ .. "/auth.ts", old_string = "a", new_string = "b" } } } } })
  .. rec({ type = "user", message = { role = "user", content = { { type = "tool_result", tool_use_id = "tu_a", content = "ok" } } } })
  .. rec({ type = "assistant", message = { role = "assistant", content = { { type = "tool_use", id = "tu_b", name = "Bash",
       input = { command = "make test" } } } } })
  .. rec({ type = "user", message = { role = "user", content = { { type = "tool_result", tool_use_id = "tu_b", is_error = true,
       content = "FAIL - login keeps the session" } } } })
  .. rec({ type = "assistant", message = { role = "assistant", content = { { type = "text", text = "Fixed the session check in auth.ts." } } } }))
writeFile(PROJ .. "/TODO.md", "# notes\n- [x] Already finished item\n- [ ] Login keeps the session after a refresh (auth.ts)\n- [ ] Second open item\n")

local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end

-- ---- the stubbed Hammerspoon surface (as tests/usage-totals.test.lua), with real git + stat ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function attributes(p, k)
  local q = "'" .. tostring(p):gsub("'", "'\\''") .. "'"
  local out = sh("stat -c '%F|%Y' " .. q .. " 2>/dev/null || stat -f '%HT|%m' " .. q .. " 2>/dev/null")
  local kind, mtime = out:match("^([^|]+)|(%d+)")
  if not kind then return nil end
  local a = { mode = kind:lower():find("directory", 1, true) and "directory" or "file", modification = tonumber(mtime) }
  if k then return a[k] end
  return a
end
local frame = { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1a "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = attributes,
    symlinkAttributes = function() return nil end,
    mkdir = function(p) sh("mkdir '" .. tostring(p):gsub("'", "'\\''") .. "' 2>/dev/null"); return true end,
  },
  settings = { get = function() return nil end, set = function() end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    if tostring(cmd):match("^git ") then return sh(cmd) end
    return ""
  end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = { new = function() return mkstub() end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
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
if not ok then print("       " .. tostring(err)); print(string.format("-- handoff.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx
local core = _G.__ccDashboard.core

eq("notes live in ~/.claude/cc-notes", FX.NOTES_DIR, NOTES)

-- ---- the done edge writes the note --------------------------------------------------------
local it = { key = "k1", name = "proj", session_id = "sid-1", status = "done", cwd = PROJ, editor = "vscode",
             session_pid = "4242", host_window = "99", transcript_path = TRANSCRIPT }
FX._turnReads = 0
FX.stepTurnLabel(it, { status = "working" }, false)
eq("the done edge labels the turn", it.turnLabel, "made progress")
local note = readAll(NOTES .. "/k1.handoff.md")
check("...and writes the session's handoff note", note ~= nil)
note = note or ""
eq("the note carries the match token a /clear looks for", note:match("^([^\n]*)"), "<!-- cc-handoff match:pid-4242-99 -->")
check("the note says how the turn ended", note:find("\nLast turn: made progress, ", 1, true) ~= nil)
check("the note names the transcript", note:find("Transcript: " .. TRANSCRIPT, 1, true) ~= nil)
check("the note has the last result", note:find("## Last result\nFixed the session check in auth.ts.\n", 1, true) ~= nil)
check("the note lists the files touched", note:find("## Files touched\n- " .. PROJ .. "/auth.ts\n", 1, true) ~= nil)
check("the note lists the errors", note:find("## Errors\n- FAIL - login keeps the session\n", 1, true) ~= nil)
check("the note's next step is the worktree's first open TODO line",
      note:find("## Next\n- [ ] Login keeps the session after a refresh (auth.ts)\n- [ ] Second open item", 1, true) ~= nil)
check("...never a finished one", not note:find("Already finished item", 1, true))
check("the note leaves no temp file behind", sh("ls -a '" .. NOTES .. "' | grep -c tmp"):match("^0") ~= nil)

-- not an edge: a done tile first seen after a reload is labelled, but writes nothing
os.remove(NOTES .. "/k1.handoff.md")
local it2 = { key = "k2", name = "proj", session_id = "sid-2", status = "done", cwd = PROJ, editor = "vscode",
              session_pid = "4243", host_window = "99", transcript_path = TRANSCRIPT }
FX._turnReads = 0
FX.stepTurnLabel(it2, nil, false)
eq("a done tile seen first after a reload is still labelled", it2.turnLabel, "made progress")
check("...but its old turn doesn't rewrite a note", not exists(NOTES .. "/k2.handoff.md"))
-- a working tile writes nothing
local it3 = { key = "k3", name = "proj", status = "working", cwd = PROJ, transcript_path = TRANSCRIPT }
FX.stepTurnLabel(it3, { status = "working" }, false)
check("a working tile writes no note", not exists(NOTES .. "/k3.handoff.md"))

-- ---- auto-continue's back-off reads whose prompt started the turn (2026-09-28) ----
-- 2026-09-28: the streak of turns that changed nothing resets on Adam's prompt, so the label step
-- keeps the turn's origin, and says while a label is still coming (the budget waits for it).
eq("the done edge records whose prompt started the turn", it.turnOrigin, "human")
eq("...and nothing is pending once the label is in", it.turnLabelPending, nil)
local UNREPLIED = HOME .. "/sid-4.jsonl"
writeFile(UNREPLIED, rec({ type = "user", origin = { kind = "human" }, message = { role = "user", content = { { type = "text", text = "go on" } } } }))
local it4 = { key = "k4", name = "proj", status = "done", cwd = PROJ, editor = "vscode", transcript_path = UNREPLIED }
FX._turnReads = 0
FX.stepTurnLabel(it4, { status = "working" }, false)
eq("a done tile whose reply isn't in the transcript yet has no label", it4.turnLabel, nil)
eq("...and says its label is still coming", it4.turnLabelPending, true)
for _ = 1, 5 do FX._turnReads = 0; FX.stepTurnLabel(it4, { status = "done" }, false) end
eq("...until the reads run out", it4.turnLabelPending, nil)
eq("a working tile has no origin", it3.turnOrigin, nil)

-- ---- a respawn leaves the note for the session that replaces it ------------------------------
writeFile(HOME .. "/status/dead1.json", json.encode({ session_id = "dead1", name = "proj", status = "working", cwd = PROJ,
  editor = "vscode", transcript_path = TRANSCRIPT, updated = os.time() - 900, since = os.time() - 900 }))
local pend = FX.writePendingHandoff("dead1", "vscode", "ignored-for-vscode", PROJ)
local want = NOTES .. "/pending/" .. core.pendingNoteId("vscode", "ignored-for-vscode", PROJ) .. ".md"
eq("a respawn writes the pending note, named by its folder", pend, want)
local pnote = readAll(want) or ""
check("...built fresh from the dead session's transcript", pnote:find("## Files touched\n- " .. PROJ .. "/auth.ts\n", 1, true) ~= nil)
check("...saying its turn was cut off", pnote:find("\nLast turn: cut off mid-turn, made progress, ", 1, true) ~= nil)
os.remove(want)
pend = FX.writePendingHandoff("dead1", "kitty", "L@unix:/tmp/kitty-1#2", PROJ)
eq("a kitty respawn's is named by its lineage", pend, NOTES .. "/pending/lineage-" .. core.cheapHash("L@unix:/tmp/kitty-1#2") .. ".md")
if pend then os.remove(pend) end
-- no transcript to read: the note the dead session left on its last done edge is copied instead
writeFile(HOME .. "/status/dead2.json", json.encode({ session_id = "dead2", name = "proj", status = "done", cwd = PROJ,
  updated = os.time(), since = os.time() }))
writeFile(NOTES .. "/dead2.handoff.md", "# Handoff: saved earlier\n")
pend = FX.writePendingHandoff("dead2", "terminal", nil, PROJ)
eq("with no transcript, the saved note is copied", pend and readAll(pend), "# Handoff: saved earlier\n")
if pend then os.remove(pend) end
eq("with neither, there is no pending note", FX.writePendingHandoff("nobody", "terminal", nil, PROJ), nil)

-- through FX.spawnSession: only a respawn that really launches leaves one
local pendPath = NOTES .. "/pending/cwd-" .. core.cheapHash(PROJ) .. ".md"
eq("a dry-run respawn launches nothing", FX.spawnSession("terminal", PROJ, nil, nil, "", { lineage = "x", except = "dead1" }, false, nil), false)
check("...and leaves no pending note", not exists(pendPath))
writeFile(HOME .. "/.claude/cc-config.json", json.encode({ spawn = { live = true } }))
eq("a live respawn launches", FX.spawnSession("terminal", PROJ, nil, nil, "", { lineage = "x", except = "dead1" }, false, nil), true)
check("...leaving the pending note for the new session", exists(pendPath))
os.remove(pendPath)
FX.spawnSession("terminal", PROJ, "a task", nil, "", nil, false, nil)
check("a plain spawn (no respawn) leaves none", not exists(pendPath))

-- ---- notes are pruned after 14 days ------------------------------------------------------------
sh("mkdir -p '" .. NOTES .. "/pending'")
writeFile(NOTES .. "/old.handoff.md", "old")
writeFile(NOTES .. "/fresh.handoff.md", "fresh")
writeFile(NOTES .. "/pending/oldpend.md", "old")
writeFile(NOTES .. "/pending/freshpend.md", "fresh")
local old = os.date("%Y%m%d%H%M", os.time() - 15 * 86400)
sh("touch -t " .. old .. " '" .. NOTES .. "/old.handoff.md' '" .. NOTES .. "/pending/oldpend.md'")
FX.pruneNotes(os.time())
check("a note older than 14 days is pruned", not exists(NOTES .. "/old.handoff.md"))
check("...and a pending one", not exists(NOTES .. "/pending/oldpend.md"))
check("a fresh note is kept", exists(NOTES .. "/fresh.handoff.md"))
check("...and a fresh pending one", exists(NOTES .. "/pending/freshpend.md"))
check("...and the pending folder itself", attributes(NOTES .. "/pending", "mode") == "directory")

sh("rm -r '" .. HOME .. "'")
print(string.format("-- handoff.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
