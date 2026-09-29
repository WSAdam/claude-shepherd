-- onpurpose.test.lua : a project's DECISIONS.md -- what it does on purpose (2026-09-29, build
-- program unit 33). Sessions and reviews kept "fixing" deliberate choices, because nothing said
-- they were deliberate. The "On purpose" detail tab shows FX.gitRoot(cwd)/DECISIONS.md and adds an
-- entry (what, why, date) through the same hash-guarded save as User Stories: re-read, refuse if the
-- file changed since the panel read it, write atomically. It is offered even before the file exists
-- (adding creates it). The merge checker reads the BASE branch's copy (a change can't exempt
-- itself), and the handoff note names the file. Pure logic first, then the real FX block under a
-- STUBBED Hammerspoon, with git run for real in a temp repo.

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
local REPO = HOME .. "/proj"
local SUB = REPO .. "/server/src"
local PLAIN = HOME .. "/not-a-repo"
sh("mkdir -p '" .. HOME .. "/.claude/cc-scratch' '" .. HOME .. "/.claude/cc-ledger' '" .. HOME .. "/status' '"
   .. SUB .. "' '" .. PLAIN .. "'")
sh("git -C '" .. REPO .. "' init -q 2>/dev/null")
REPO = sh("git -C '" .. REPO .. "' rev-parse --show-toplevel"):gsub("%s+$", "")   -- /private/var on macOS
SUB = REPO .. "/server/src"
local FILE = REPO .. "/DECISIONS.md"

local json = dofile(HERE .. "support/json.lua")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local core = dofile(ROOT .. "cc-core.lua")

-- ---- the file's entries (pure) -------------------------------------------------------------------
local DOC = table.concat({
  "# Decisions",
  "",
  "What this project does on purpose.",
  "",
  "## The panel HTML lives in a Lua long string",
  "",
  "Why: one file to deploy, and Hammerspoon has no bundler.",
  "Date: 2026-06-01",
  "",
  "## No `hs.alert.show` anywhere",
  "",
  "- **Why:** its overlay covered every window.",
  "- **Date:** 2026-07-02",
  "Callers go through FX.alert.",
  "",
  "```md",
  "## not an entry: inside a fence",
  "```",
  "",
}, "\n")
local doc = core.parseDecisions(DOC)
eq("parseDecisions: one entry per ## heading, fences skipped", #doc.entries, 2)
eq("parseDecisions: an entry's what is its heading", doc.entries[1].what, "The panel HTML lives in a Lua long string")
eq("parseDecisions: ...its why", doc.entries[1].why, "one file to deploy, and Hammerspoon has no bundler.")
eq("parseDecisions: ...its date", doc.entries[1].date, "2026-06-01")
eq("parseDecisions: bulleted, bold labels read the same", doc.entries[2].why, "its overlay covered every window.")
eq("parseDecisions: ...date too", doc.entries[2].date, "2026-07-02")
eq("parseDecisions: other lines are the entry's notes", doc.entries[2].notes, "Callers go through FX.alert.\n```md\n## not an entry: inside a fence\n```")
eq("parseDecisions: nothing is no entries", #core.parseDecisions(nil).entries, 0)
eq("parseDecisions: CRLF reads the same", core.parseDecisions(DOC:gsub("\n", "\r\n")).entries[1].why,
   "one file to deploy, and Hammerspoon has no bundler.")

-- ---- the save guard (pure): refuse if the file changed since it was read ------------------------
eq("decisionsHash: a missing file has its own hash", core.decisionsHash(nil), core.DECISIONS_ABSENT)
check("decisionsHash: an empty file is not a missing one", core.decisionsHash("") ~= core.DECISIONS_ABSENT)
eq("decisionsHash: a file's is cheapHash", core.decisionsHash(DOC), core.cheapHash(DOC))

local entry = { what = "Tests shell out to the real make", why = "install.test.sh proves the Makefile itself", date = "2026-09-29" }
local dec = core.decisionsSaveDecision(nil, core.DECISIONS_ABSENT, entry, "2026-09-30")
check("save: a missing file is created", dec.ok == true)
local made = dec.text or ""
check("save: ...with a title and what the file is for", made:find("^# Decisions\n\n") ~= nil and made:find("on purpose", 1, true) ~= nil)
local tail = "\n## Tests shell out to the real make\n\nWhy: install.test.sh proves the Makefile itself\nDate: 2026-09-29\n"
check("save: ...and the entry, at its end", made:sub(-#tail) == tail)
eq("save: the file it makes reads back as that one entry", core.parseDecisions(made).entries[1].why, entry.why)

dec = core.decisionsSaveDecision(DOC, core.cheapHash(DOC), entry, "2026-09-30")
check("save: an existing file gains the entry at its end", dec.ok and dec.text:sub(1, #DOC) == DOC)
check("save: ...everything before it byte for byte", dec.ok and dec.text:find("\n\n## Tests shell out to the real make\n", #DOC - 1, true) ~= nil)
eq("save: ...and reads back with three entries", dec.ok and #core.parseDecisions(dec.text).entries, 3)

-- 2026-09-29: the guard is the point -- a panel that read the file before someone else edited it
-- must never write its stale copy back over theirs.
dec = core.decisionsSaveDecision(DOC .. "## Added by hand\n", core.cheapHash(DOC), entry, "2026-09-30")
eq("save guard: the file changed since it was read -> refused", dec.error, "changed")
check("save guard: ...and nothing to write", dec.ok == false and dec.text == nil)
eq("save guard: created by someone else since it was read missing -> refused",
   core.decisionsSaveDecision("# theirs\n", core.DECISIONS_ABSENT, entry, "2026-09-30").error, "changed")
eq("save guard: deleted since it was read -> refused",
   core.decisionsSaveDecision(nil, core.cheapHash(DOC), entry, "2026-09-30").error, "changed")
eq("save guard: no hash at all -> refused", core.decisionsSaveDecision(DOC, nil, entry, "2026-09-30").error, "changed")

eq("save: an entry with no what is refused", core.decisionsSaveDecision(nil, "absent", { what = "  ", why = "x" }, "2026-09-30").error, "no-what")
eq("save: ...or no why", core.decisionsSaveDecision(nil, "absent", { what = "x", why = "" }, "2026-09-30").error, "no-why")
eq("save: ...or no entry", core.decisionsSaveDecision(nil, "absent", "x", "2026-09-30").error, "bad-payload")
eq("save: a what past 200 characters is refused", core.decisionsSaveDecision(nil, "absent", { what = ("w"):rep(201), why = "x" }, "2026-09-30").error, "too-long")
dec = core.decisionsSaveDecision(nil, "absent", { what = "One\n## Injected heading", why = "a\n\nb" }, "2026-09-30")
check("save: a line break can't start a heading of its own", dec.ok and dec.text:find("\n## One ## Injected heading\n", 1, true) ~= nil
      and #core.parseDecisions(dec.text).entries == 1)
check("save: ...or split the why", dec.ok and dec.text:find("\nWhy: a b\n", 1, true) ~= nil)
dec = core.decisionsSaveDecision(nil, "absent", { what = "x", why = "y", date = "yesterday; rm -rf" }, "2026-09-30")
check("save: a date that isn't YYYY-MM-DD is today's", dec.ok and dec.text:find("\nDate: 2026-09-30\n", 1, true) ~= nil)
dec = core.decisionsSaveDecision(nil, "absent", { what = "x", why = "y" }, "2026-09-30")
check("save: ...and so is no date", dec.ok and dec.text:find("\nDate: 2026-09-30\n", 1, true) ~= nil)
local crlf = "# D\r\n\r\n## a\r\nWhy: b\r\n"
dec = core.decisionsSaveDecision(crlf, core.cheapHash(crlf), entry, "2026-09-30")
check("save: a CRLF file gains CRLF lines", dec.ok and dec.text == crlf .. "\r\n## Tests shell out to the real make\r\n\r\nWhy: install.test.sh proves the Makefile itself\r\nDate: 2026-09-29\r\n")
local bare = "# D\n\n## a\nWhy: b"
dec = core.decisionsSaveDecision(bare, core.cheapHash(bare), entry, "2026-09-30")
check("save: a file with no final newline doesn't glue the entry onto its last line",
      dec.ok and dec.text:find("Why: b\n\n## Tests shell out", 1, true) ~= nil)

-- ---- the tab ------------------------------------------------------------------------------------
local ids, afterStories = {}, nil
for i, t in ipairs(core.DETAIL_TABS) do ids[t.id] = t; if t.id == "stories" then afterStories = core.DETAIL_TABS[i + 1] end end
check("DETAIL_TABS: an On purpose tab, id onpurpose", ids.onpurpose and ids.onpurpose.label == "On purpose")
check("DETAIL_TABS: ...next to User Stories", afterStories and afterStories.id == "onpurpose")

-- ---- the readers --------------------------------------------------------------------------------
local reqT = { dir = "/r/A/wt", commonDir = "/r/A/.git", branch = "feat/x", base = "main", sha = "abc123", range = "main...abc123" }
local p = core.checkerPrompt(reqT, {})
check("checkerPrompt: tells the checker to read the base branch's DECISIONS.md", p:find("git show main:DECISIONS.md", 1, true) ~= nil)
check("checkerPrompt: ...and not to flag what it lists", p:find("Never flag a choice it lists", 1, true) ~= nil)
check("checkerPrompt: ...and that an entry the change adds exempts nothing", p:find("not an exemption", 1, true) ~= nil)
check("checkerPrompt: Verify reads it from its base too",
      core.checkerPrompt({ dir = "/r/A", from = "fff000", base = "master", branch = "x" }, {}):find("git show master:DECISIONS.md", 1, true) ~= nil)

local note = core.handoffNote({ key = "k1", cwd = REPO }, {}, { label = "done", now = 0, decisions = FILE })
check("handoffNote: names the repo's DECISIONS.md", note:find("\nOn purpose: " .. FILE .. " -- read it before changing anything it lists.\n", 1, true) ~= nil)
check("handoffNote: ...only when there is one", not core.handoffNote({ key = "k1", cwd = REPO }, {}, { label = "done", now = 0 }):find("On purpose", 1, true))

-- ---- the real FX block, stubbed Hammerspoon, real git --------------------------------------------
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
local function attributes(path, k)
  local q = "'" .. tostring(path):gsub("'", "'\\''") .. "'"
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
      local files, pp = {}, io.popen('ls -1a "' .. tostring(path) .. '" 2>/dev/null')
      if pp then for line in pp:lines() do files[#files + 1] = line end; pp:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = attributes,
    symlinkAttributes = function() return nil end,
    mkdir = function(d) sh("mkdir '" .. tostring(d):gsub("'", "'\\''") .. "' 2>/dev/null"); return true end,
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
if not ok then print("       " .. tostring(err)); print(string.format("-- onpurpose.test.lua: %d run, %d failed --", run, failed)); os.exit(1) end
local FX = _G.__ccDashboard.fx

local it = { key = "k1", cwd = SUB }                 -- a session in a subfolder of the repo
local plain = { key = "k2", cwd = PLAIN }
local remote = { key = "k3", cwd = SUB, remote = true }

eq("offered: a local session in a git repo", FX.onPurposeOffered(it), true)
eq("offered: ...even before DECISIONS.md exists", readAll(FILE), nil)
eq("offered: not outside a repo", FX.onPurposeOffered(plain), false)
eq("offered: not for a remote session (its cwd is on another machine)", FX.onPurposeOffered(remote), false)
eq("offered: not without a cwd", FX.onPurposeOffered({ key = "k4" }), false)

local d = FX.onPurposeLoad(it)
eq("load: the file is at the repo's root, not the session's folder", d.path, FILE)
eq("load: no file yet", d.exists, false)
eq("load: ...read as the missing file's hash", d.hash, core.DECISIONS_ABSENT)
eq("load: ...and no entries", #d.entries, 0)
eq("load: outside a repo there's nothing to show", FX.onPurposeLoad(plain).norepo, true)
eq("load: ...nor for a remote session", FX.onPurposeLoad(remote).norepo, true)

local r = FX.onPurposeSave(it, { hash = d.hash, what = "Tests shell out to the real make", why = "they prove the Makefile", date = "2026-09-29" })
eq("add: the first entry creates DECISIONS.md", r.ok, true)
check("add: ...at the repo root", (readAll(FILE) or ""):find("\n## Tests shell out to the real make\n", 1, true) ~= nil)
eq("add: ...and hands back the file as it now reads", r.data and r.data.entries and r.data.entries[1] and r.data.entries[1].what, "Tests shell out to the real make")
eq("add: ...with its new hash", r.data and r.data.hash, core.cheapHash(readAll(FILE) or ""))
eq("add: no temp file is left behind", sh("ls -a '" .. REPO .. "' | grep -c tmp"):match("^(%d+)"), "0")

-- 2026-09-29: the stale-panel case the guard exists for -- a hand edit lands after the panel read
-- the file; the panel's add must be refused and the hand edit kept.
local stale = r.data.hash
local handEdit = readAll(FILE) .. "\n## Added by hand in the editor\n\nWhy: because\n"
writeFile(FILE, handEdit)
r = FX.onPurposeSave(it, { hash = stale, what = "From the stale panel", why = "x" })
eq("save guard: a file changed since it was read is not written", r.error, "changed")
eq("save guard: ...and the hand edit is kept, byte for byte", readAll(FILE), handEdit)
r = FX.onPurposeSave(it, { hash = FX.onPurposeLoad(it).hash, what = "After a reload", why = "y", date = "2026-09-30" })
eq("save guard: after a reload the add goes through", r.ok, true)
eq("save guard: ...keeping the hand edit too", #FX.onPurposeLoad(it).entries, 3)
os.remove(FILE)
eq("save guard: deleted since it was read -> refused", FX.onPurposeSave(it, { hash = r.data.hash, what = "a", why = "b" }).error, "changed")
eq("save guard: ...and not recreated", readAll(FILE), nil)
eq("save: outside a repo nothing is written", FX.onPurposeSave(plain, { hash = "absent", what = "a", why = "b" }).error, "no-repo")
eq("save: ...nor for a remote session", FX.onPurposeSave(remote, { hash = "absent", what = "a", why = "b" }).error, "no-repo")
eq("save: ...and no stray file appears outside the repo", readAll(PLAIN .. "/DECISIONS.md"), nil)
eq("save: a bad entry is refused before anything is written",
   FX.onPurposeSave(it, { hash = core.DECISIONS_ABSENT, what = "", why = "b" }).error, "no-what")
eq("save: ...so the file is still missing", readAll(FILE), nil)

-- a big hand-kept file that has no ## entries still shows, cut
writeFile(FILE, ("free-form line\n"):rep(1000))
d = FX.onPurposeLoad(it)
eq("load: a file with no ## entries has none", #d.entries, 0)
check("load: ...and shows its text instead, cut to 4000 characters", type(d.preview) == "string" and #d.preview == 4000)
os.remove(FILE)

-- the handoff note names the file when the repo has one
eq("decisionsFile: nothing while the repo has no DECISIONS.md", FX.decisionsFile(SUB), nil)
writeFile(FILE, "# Decisions\n")
eq("decisionsFile: the root's file once it exists", FX.decisionsFile(SUB), FILE)
eq("decisionsFile: nothing outside a repo", FX.decisionsFile(PLAIN), nil)
local noteDir = HOME .. "/.claude/cc-notes"
FX.writeHandoff({ key = "k1", cwd = SUB }, {}, "made progress")
check("writeHandoff: the note points at the repo's DECISIONS.md",
      (readAll(noteDir .. "/k1.handoff.md") or ""):find("\nOn purpose: " .. FILE .. " -- read it before", 1, true) ~= nil)

sh("rm -r '" .. HOME .. "'")
print(string.format("-- onpurpose.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
