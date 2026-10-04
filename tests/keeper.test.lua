-- keeper.test.lua : the transcript keeper, its pure half (2026-10-03, mining round 2 unit F3).
-- Claude Code deletes a transcript once it is cleanupPeriodDays old (unset = 30 days), and with it
-- the only record of what a session did. Shepherd now keeps a copy of every transcript of the
-- projects Adam starred in 🗂 History: once the session has ended, with an APFS clone (`cp -c`) into
-- ~/.claude/cc-keep/<project>/<session>.jsonl (mode 700), and again whenever the original grows.
-- Readers (History, fleet search, Seance) fall back to the copy when the original is gone, and
-- Diagnostics shows cleanupPeriodDays with an offer to raise it that writes only that key.
-- Pure decisions through core; the copy script and the settings.json writer run for real (sh, cp,
-- jq) against temp files -- never the real ~/.claude.

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
  print(string.format("-- keeper.test.lua: %d run, %d failed --", run, failed))
  os.exit(failed == 0 and 0 or 1)
end

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local T = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(T ~= "", "could not mktemp a fixture dir")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function jqOut(filter, path) return (sh("jq -c " .. q(filter) .. " " .. q(path) .. " 2>/dev/null"):gsub("%s+$", "")) end
local function modeOf(path) return (sh("stat -c %a " .. q(path) .. " 2>/dev/null || stat -f %Lp " .. q(path)):gsub("%s+$", "")) end

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = core.json or json

check("core has the keeper", type(core.KEEPER) == "table" and type(core.keeperWants) == "function")
if type(core.KEEPER) ~= "table" or type(core.keeperWants) ~= "function" then finish() end

-- ---- which projects can be kept (2026-10-03) ----
check("a project key is the encoded folder name Claude Code uses", core.keeperProjectKeyOk("-Users-adam-Programming-x"))
check("...never a path", not core.keeperProjectKeyOk("/Users/adam/x"))
check("...nor a way out of the keep folder", not core.keeperProjectKeyOk("..") and not core.keeperProjectKeyOk("a/b")
      and not core.keeperProjectKeyOk("a/../b") and not core.keeperProjectKeyOk(""))
check("...nor something that isn't a string", not core.keeperProjectKeyOk(nil) and not core.keeperProjectKeyOk(42))

-- the panel sends its pins (localStorage's map, or a list); only keepable keys stay, once, sorted
local pins = core.keeperPins({ "-r-B", "-r-A", "../evil", "-r-A", "/r/C", 7 })
eq("the pin list: keepable keys only, once each, sorted", table.concat(pins, ","), "-r-A,-r-B")
pins = core.keeperPins({ ["-r-A"] = true, ["-r-Z"] = true, ["/cwd/key"] = true })
eq("...from the panel's map too", table.concat(pins, ","), "-r-A,-r-Z")
eq("...junk is no pins", #core.keeperPins("nope") + #core.keeperPins(nil), 0)
local many = {}
for i = 1, core.KEEPER.maxPins + 50 do many[#many + 1] = string.format("-p%04d", i) end
eq("...and the list is capped", #core.keeperPins(many), core.KEEPER.maxPins)
-- pins.json round-trips
local text = core.keeperPinsJson({ "-r-A", "-r-B" })
eq("pins.json: the list, as written", table.concat(core.keeperPinsParse(text), ","), "-r-A,-r-B")
eq("pins.json: junk on disk is no pins", #core.keeperPinsParse("{oops") + #core.keeperPinsParse(nil), 0)
eq("pins.json: a hand-edited bad key is dropped", table.concat(core.keeperPinsParse('{"pins":["-r-A","../x"]}'), ","), "-r-A")

-- ---- which transcripts need a copy: ended, and missing or grown (2026-10-03) ----
local NOW = 1790000000
local S1 = "aaaa1111-0000-4000-8000-000000000001"
local S2 = "bbbb2222-0000-4000-8000-000000000002"
local S3 = "cccc3333-0000-4000-8000-000000000003"
local S4 = "dddd4444-0000-4000-8000-000000000004"
local S5 = "eeee5555-0000-4000-8000-000000000005"
local S6 = "ffff6666-0000-4000-8000-000000000006"
local function want(files, kept, live)
  local out = {}
  for _, w in ipairs(core.keeperWants({ files = files, kept = kept or {}, live = live or {}, now = NOW })) do
    out[#out + 1] = w.sid:sub(1, 4) .. ":" .. w.why
  end
  return table.concat(out, " ")
end
local hour, day = 3600, 86400
eq("an ended session with no copy yet: copied", want({ { pk = "-r-A", sid = S1, size = 100, mtime = NOW - day } }), "aaaa:missing")
eq("...its copy as big as it: nothing to do",
   want({ { pk = "-r-A", sid = S1, size = 100, mtime = NOW - day } }, { ["-r-A/" .. S1] = { size = 100 } }), "")
eq("...the original grew since: copied again",
   want({ { pk = "-r-A", sid = S1, size = 150, mtime = NOW - day } }, { ["-r-A/" .. S1] = { size = 100 } }), "aaaa:grown")
eq("...a copy BIGGER than the original is never replaced by the smaller one",
   want({ { pk = "-r-A", sid = S1, size = 80, mtime = NOW - day } }, { ["-r-A/" .. S1] = { size = 100 } }), "")
eq("a live session isn't copied yet",
   want({ { pk = "-r-A", sid = S2, size = 100, mtime = NOW - hour } }, {}, { [S2] = true }), "")
eq("...unless its transcript hasn't moved in a day (a crashed claude's leftover registry entry)",
   want({ { pk = "-r-A", sid = S2, size = 100, mtime = NOW - day - 60 } }, {}, { [S2] = true }), "bbbb:missing")
eq("a transcript written in the last minutes waits (its session may still be writing it)",
   want({ { pk = "-r-A", sid = S3, size = 100, mtime = NOW - 60 } }), "")
eq("...and is copied once it has been quiet for quietSeconds",
   want({ { pk = "-r-A", sid = S3, size = 100, mtime = NOW - core.KEEPER.quietSeconds } }), "cccc:missing")
eq("a file that isn't a session's transcript is left alone",
   want({ { pk = "-r-A", sid = "not a session; rm", size = 100, mtime = NOW - day },
          { pk = "../x", sid = S4, size = 100, mtime = NOW - day } }), "")
eq("the oldest first: Claude Code's cleanup deletes the oldest first",
   want({ { pk = "-r-A", sid = S5, size = 1, mtime = NOW - 2 * day }, { pk = "-r-B", sid = S6, size = 1, mtime = NOW - 20 * day },
          { pk = "-r-A", sid = S4, size = 1, mtime = NOW - 9 * day } }), "ffff:missing dddd:missing eeee:missing")
local w1 = core.keeperWants({ files = { { pk = "-r-A", sid = S1, size = 7, mtime = NOW - day } }, kept = {}, live = {}, now = NOW })[1]
check("a wanted copy names its project, session and size", w1 and w1.pk == "-r-A" and w1.sid == S1 and w1.size == 7)

-- ---- the copy: an async cp -c (APFS clone), atomic, into a mode-700 folder (run for real) ----
local PROJ, KEEP = T .. "/projects", T .. "/cc-keep"
sh("mkdir -p " .. q(PROJ .. "/-r-A"))
local ORIG = PROJ .. "/-r-A/" .. S1 .. ".jsonl"
writeFile(ORIG, '{"type":"user","message":{"content":"one"}}\n')
local DEST = KEEP .. "/-r-A/" .. S1 .. ".jsonl"
local argv = core.keeperCopyArgv(ORIG, DEST, KEEP)
check("the copy runs through /bin/sh with the paths as positional arguments, never pasted into the script",
      type(argv) == "table" and argv[1] == "-c" and argv[4] == ORIG and argv[5] == DEST and argv[6] == KEEP
      and not tostring(argv[2]):find(ORIG, 1, true))
check("...cloning first (cp -c), with a plain copy when the volume can't clone",
      argv and tostring(argv[2]):find("cp -c", 1, true) ~= nil and tostring(argv[2]):find("|| cp -p", 1, true) ~= nil)
local function runArgv(a)
  local parts = { "/bin/sh" }
  for _, x in ipairs(a) do parts[#parts + 1] = q(x) end
  local p = io.popen(table.concat(parts, " ") .. " 2>&1; echo \"@@rc $?\"")
  local out = p:read("*a"); p:close()
  return tonumber(out:match("@@rc (%d+)")), out
end
local code, out = runArgv(argv)
local okc, bytes = core.keeperCopyResult(code, out)
check("the copy succeeds", okc == true)
eq("...reports the copy's size", bytes, #'{"type":"user","message":{"content":"one"}}\n')
eq("...the copy is the transcript", readAll(DEST), readAll(ORIG))
eq("...the keep folder is mode 700", modeOf(KEEP), "700")
eq("...and so is the project's folder in it", modeOf(KEEP .. "/-r-A"), "700")
eq("...no part file is left behind", sh("ls -a " .. q(KEEP .. "/-r-A") .. " | grep -c part"):gsub("%s+$", ""), "0")
eq("...the original is untouched", readAll(ORIG), '{"type":"user","message":{"content":"one"}}\n')
-- grown: the copy is replaced by a rename, so a reader never sees half of it
local inode0 = sh("stat -c %i " .. q(DEST) .. " 2>/dev/null || stat -f %i " .. q(DEST)):gsub("%s+$", "")
local f = io.open(ORIG, "a"); f:write('{"type":"assistant","message":{"content":"two"}}\n'); f:close()
code, out = runArgv(core.keeperCopyArgv(ORIG, DEST, KEEP))
check("copied again once it grew", (core.keeperCopyResult(code, out)))
eq("...the copy has the new lines", readAll(DEST), readAll(ORIG))
local inode1 = sh("stat -c %i " .. q(DEST) .. " 2>/dev/null || stat -f %i " .. q(DEST)):gsub("%s+$", "")
check("...replaced by a rename, never rewritten in place", inode1 ~= "" and inode1 ~= inode0)
-- a missing original fails, saying so, and leaves the copy as it was
local before = readAll(DEST)
code, out = runArgv(core.keeperCopyArgv(PROJ .. "/-r-A/" .. S2 .. ".jsonl", KEEP .. "/-r-A/" .. S2 .. ".jsonl", KEEP))
local okf, why = core.keeperCopyResult(code, out)
check("a copy whose original is gone fails", okf == false)
check("...saying why", type(why) == "string" and why:find(S2, 1, true) ~= nil)
check("...and leaves nothing behind", not exists(KEEP .. "/-r-A/" .. S2 .. ".jsonl")
      and sh("ls -a " .. q(KEEP .. "/-r-A") .. " | grep -c part"):gsub("%s+$", "") == "0")
eq("...nor touches another copy", readAll(DEST), before)
-- a quote in a path is safe (positional arguments)
local ODDP = T .. "/it's projects/-r-Q"
sh("mkdir -p " .. q(ODDP))
writeFile(ODDP .. "/" .. S3 .. ".jsonl", "{}\n")
local ODDK = T .. "/it's keep"
code, out = runArgv(core.keeperCopyArgv(ODDP .. "/" .. S3 .. ".jsonl", ODDK .. "/-r-Q/" .. S3 .. ".jsonl", ODDK))
check("a quote in a path goes through intact", (core.keeperCopyResult(code, out)) and readAll(ODDK .. "/-r-Q/" .. S3 .. ".jsonl") == "{}\n")
-- what the copy refuses before any shell
eq("a relative path is refused", core.keeperCopyArgv("x.jsonl", DEST, KEEP), nil)
eq("a destination outside the keep folder is refused", core.keeperCopyArgv(ORIG, T .. "/elsewhere/" .. S1 .. ".jsonl", KEEP), nil)
eq("...or one that climbs out of it", core.keeperCopyArgv(ORIG, KEEP .. "/../" .. S1 .. ".jsonl", KEEP), nil)
eq("...or one that isn't a transcript", core.keeperCopyArgv(ORIG, KEEP .. "/-r-A/x.sh", KEEP), nil)
eq("an unreadable result is a failure", (core.keeperCopyResult(0, "")), false)

-- ---- readers fall back to the kept copy when the original is gone (2026-10-03) ----
eq("the kept copy of a transcript", core.keptCopyOf(ORIG, PROJ, KEEP), DEST)
eq("...a subagent's transcript has none", core.keptCopyOf(PROJ .. "/-r-A/" .. S1 .. "/subagents/agent-1.jsonl", PROJ, KEEP), nil)
eq("...nor a file outside the projects folder", core.keptCopyOf("/tmp/" .. S1 .. ".jsonl", PROJ, KEEP), nil)
local present = { [ORIG] = true, [DEST] = true }
local function ex(p) return present[p] == true end
local path, kept = core.keeperReadPath(ORIG, PROJ, KEEP, ex)
check("the original while it exists", path == ORIG and kept == false)
present[ORIG] = nil
path, kept = core.keeperReadPath(ORIG, PROJ, KEEP, ex)
check("...the kept copy once Claude Code deleted it", path == DEST and kept == true)
present[DEST] = nil
eq("...nothing when neither exists", (core.keeperReadPath(ORIG, PROJ, KEEP, ex)), nil)
eq("a path outside the projects folder reads as itself when it exists",
   (core.keeperReadPath("/elsewhere/" .. S1 .. ".jsonl", PROJ, KEEP, function() return true end)), "/elsewhere/" .. S1 .. ".jsonl")

-- fleet search: a hit in a kept copy counts only when the original is gone (else it'd come back twice)
local K2 = KEEP .. "/-r-A/" .. S2 .. ".jsonl"
local hits = {
  { file = ORIG, line = 1, text = "one" },
  { file = DEST, line = 1, text = "one" },
  { file = K2, line = 3, text = "three" },
}
local res = core.keeperSearchHits(hits, PROJ, KEEP, function(p) return p == ORIG end)
eq("a kept copy's hit is dropped while its original exists", #res, 2)
check("...the original's own hit stays", res[1].file == ORIG and not res[1].kept)
check("...and a copy whose original is gone is a hit, marked kept", res[2].file == K2 and res[2].kept == true)
local ann = core.annotateSearchHits({ { file = K2, line = 3, text = "three" } }, {}, T .. "/cc-ledger")
check("a kept copy's hit maps back to its session and project",
      ann[1].kind == "transcript" and ann[1].sessionId == S2 and ann[1].projectKey == "-r-A")

-- History: which rows have a kept copy, and which have only that
local recs = core.keeperAnnotateHistory({ { session_id = S1, projectKey = "-r-A" }, { session_id = S2, projectKey = "-r-A" },
                                         { session_id = S3, projectKey = "/cwd/only" } },
  { ["-r-A/" .. S1] = { size = 1 }, ["-r-A/" .. S2] = { size = 1 } },
  function(pk, sid) return sid == S1 end)
check("History: a row with a kept copy says so", recs[1].kept == true and not recs[1].keptOnly)
check("...and one whose original is gone says only the copy is left", recs[2].kept == true and recs[2].keptOnly == true)
check("...a row with no copy says nothing", recs[3].kept == nil and recs[3].keptOnly == nil)
local counts = core.keeperProjectCounts({ ["-r-A/" .. S1] = { size = 1 }, ["-r-A/" .. S2] = { size = 1 }, ["-r-B/" .. S3] = { size = 1 } })
check("the kept copies per project (for unstarring's offer)", counts["-r-A"] == 2 and counts["-r-B"] == 1)

-- ---- Diagnostics: cleanupPeriodDays, and an offer to raise it (2026-10-03) ----
local function fact(s) return core.cleanupDaysFact(s) end
check("settings.json without the key: unset", fact('{"model":"opus"}').readable == true and fact('{"model":"opus"}').set == false)
eq("...a number", fact('{"cleanupPeriodDays":90}').value, 90)
check("...an unreadable file", fact("{oops").readable == false and fact(nil).readable == false)
eq("raise: unset goes to 365", core.cleanupDaysPlan(fact("{}")), 365)
eq("raise: 90 goes to 365", core.cleanupDaysPlan(fact('{"cleanupPeriodDays":90}')), 365)
eq("raise: 400 is left alone", core.cleanupDaysPlan(fact('{"cleanupPeriodDays":400}')), nil)
eq("raise: a bad value is replaced", core.cleanupDaysPlan(fact('{"cleanupPeriodDays":"soon"}')), 365)
eq("raise: an unreadable file is never written", core.cleanupDaysPlan(fact("{oops")), nil)

local function rowsFor(k)
  local out = {}
  for _, r in ipairs(core.doctorChecks({ keeper = k })) do
    if (r.label .. " " .. (r.detail or "")):find("cleanupPeriodDays", 1, true) or r.label:find("ranscript", 1, true) then
      out[#out + 1] = r
    end
  end
  return out
end
local function rowWith(rows, needle) for _, r in ipairs(rows) do if r.label:find(needle, 1, true) then return r end end end
local r = rowWith(rowsFor({ cleanup = fact("{}"), pins = 0, kept = 0, bytes = 0 }), "30 days")
check("unset: 'Claude Code deletes transcripts after 30 days'", r ~= nil and r.label == "Claude Code deletes transcripts after 30 days")
check("...info, not a warning (it's Claude Code's default)", r and r.status == "info")
check("...names the setting", r and r.detail:find("cleanupPeriodDays", 1, true) ~= nil)
check("...with an offer to keep them 365 days", r and type(r.offer) == "table" and r.offer.id == "cleanup-days"
      and r.offer.label:find("365", 1, true) ~= nil)
r = rowWith(rowsFor({ cleanup = fact('{"cleanupPeriodDays":7}') }), "7 days")
check("7 days: says so, with the offer", r ~= nil and r.status == "info" and r.offer ~= nil)
r = rowWith(rowsFor({ cleanup = fact('{"cleanupPeriodDays":1}') }), "1 day")
check("1 day: singular", r ~= nil and r.label == "Claude Code deletes transcripts after 1 day")
r = rowWith(rowsFor({ cleanup = fact('{"cleanupPeriodDays":400}') }), "400 days")
check("400 days: ok, no offer", r ~= nil and r.status == "ok" and r.offer == nil and r.label == "Claude Code keeps transcripts 400 days")
r = rowWith(rowsFor({ cleanup = fact('{"cleanupPeriodDays":0}') }), "cleanupPeriodDays")
check("0: a warning (below Claude Code's minimum of 1), with the offer", r ~= nil and r.status == "warn" and r.offer ~= nil
      and r.detail:find("minimum", 1, true) ~= nil)
r = rowWith(rowsFor({ cleanup = fact('{"cleanupPeriodDays":"soon"}') }), "cleanupPeriodDays")
check("a string: a warning, with the offer", r ~= nil and r.status == "warn" and r.offer ~= nil)
r = rowWith(rowsFor({ cleanup = fact("{oops") }), "cleanupPeriodDays")
check("unreadable settings.json: says it can't read it, and offers nothing", r ~= nil and r.status == "info" and r.offer == nil)
-- the keeper's own row
r = rowWith(rowsFor({ cleanup = fact("{}"), pins = 0, kept = 0, bytes = 0 }), "Transcript keeper")
check("no ★ project: the keeper says how to start", r ~= nil and r.status == "info" and r.detail:find("★", 1, true) ~= nil)
r = rowWith(rowsFor({ cleanup = fact("{}"), pins = 2, kept = 5, bytes = 3 * 1048576 }), "Transcript keeper")
check("★ projects: ok, with the copies and their size", r ~= nil and r.status == "ok" and r.label:find("5 kept", 1, true) ~= nil
      and r.label:find("2 ★", 1, true) ~= nil and r.label:find("MB", 1, true) ~= nil)
r = rowWith(rowsFor({ cleanup = fact("{}"), pins = 0, kept = 3, bytes = 100 }), "Transcript keeper")
check("copies left from unstarred projects: info, saying they stay", r ~= nil and r.status == "info" and r.detail:find("remove", 1, true) ~= nil)
r = rowWith(rowsFor({ cleanup = fact("{}"), pins = 1, kept = 0, bytes = 0,
                      lastError = { file = KEEP .. "/-r-A/" .. S1 .. ".jsonl", why = "No space left on device" } }), "couldn't copy")
check("a failed copy: a warning naming the file and why", r ~= nil and r.status == "warn" and r.label:find(S1, 1, true) ~= nil
      and r.detail:find("No space", 1, true) ~= nil)
check("no keeper facts: no keeper rows (Diagnostics before this unit)", #rowsFor(nil) == 0)

-- ---- the settings.json writer for a top-level key, run for real (bash + jq) ----
local SET = T .. "/settings-a.json"
local SETORIG = '{\n  "model": "opus[1m]",\n  "env": {\n    "FOO": "1"\n  },\n  "hooks": {\n    "Stop": []\n  },\n  "zeta": true\n}\n'
writeFile(SET, SETORIG)
sh("chmod 600 " .. q(SET))
local ino0 = sh("stat -c %i " .. q(SET) .. " 2>/dev/null || stat -f %i " .. q(SET)):gsub("%s+$", "")
local function runCmd(cmd) return sh(cmd .. " 2>&1") end
out = runCmd(core.settingsNumberCmd(SET, "cleanupPeriodDays", 365))
check("the writer reports success", (core.settingsEnvResult(out)))
eq("...cleanupPeriodDays is 365 (a number)", jqOut(".cleanupPeriodDays", SET), "365")
eq("only that key: everything else is exactly as it was",
   jqOut("del(.cleanupPeriodDays)", SET), (sh("printf %s " .. q(SETORIG) .. " | jq -c ."):gsub("%s+$", "")))
eq("...in its order, the new key last", jqOut("keys_unsorted", SET), '["model","env","hooks","zeta","cleanupPeriodDays"]')
local ino1 = sh("stat -c %i " .. q(SET) .. " 2>/dev/null || stat -f %i " .. q(SET)):gsub("%s+$", "")
check("atomic: replaced by a rename", ino1 ~= "" and ino1 ~= ino0)
eq("...its permissions kept", modeOf(SET), "600")
eq("...no temp file left behind", sh("ls -a " .. q(T) .. " | grep -c 'settings.json.tmp'"):gsub("%s+$", ""), "0")
out = runCmd(core.settingsNumberCmd(SET, "cleanupPeriodDays", 400))
eq("a new value replaces the old in place", jqOut("keys_unsorted", SET), '["model","env","hooks","zeta","cleanupPeriodDays"]')
eq("...with the new value", jqOut(".cleanupPeriodDays", SET), "400")
-- through a symlink: the link stays a link, its target changes
sh("mkdir -p " .. q(T .. "/dotfiles"))
writeFile(T .. "/dotfiles/claude-settings.json", '{"theme":"dark"}\n')
sh("ln -s dotfiles/claude-settings.json " .. q(T .. "/settings-link.json"))
out = runCmd(core.settingsNumberCmd(T .. "/settings-link.json", "cleanupPeriodDays", 365))
check("through a symlink: success", (core.settingsEnvResult(out)))
check("...the link is still a link", sh("[ -L " .. q(T .. "/settings-link.json") .. " ] && echo link"):find("link", 1, true) ~= nil)
eq("...and its target has the key", jqOut(".cleanupPeriodDays", T .. "/dotfiles/claude-settings.json"), "365")
eq("...next to what it had", jqOut(".theme", T .. "/dotfiles/claude-settings.json"), '"dark"')
-- a file it can't read as a settings object is left exactly as it is
local BAD = T .. "/settings-bad.json"
writeFile(BAD, '{"env": {"FOO": "1",}\n')
local okBad, whyBad = core.settingsEnvResult(runCmd(core.settingsNumberCmd(BAD, "cleanupPeriodDays", 365)))
check("an unparsable settings.json is refused", not okBad and type(whyBad) == "string" and whyBad:find("parse", 1, true) ~= nil)
eq("...and left untouched", readAll(BAD), '{"env": {"FOO": "1",}\n')
local ARR = T .. "/settings-arr.json"
writeFile(ARR, '[1,2]\n')
check("a settings.json that isn't an object is refused too", not (core.settingsEnvResult(runCmd(core.settingsNumberCmd(ARR, "cleanupPeriodDays", 365)))))
eq("...untouched", readAll(ARR), '[1,2]\n')
-- no file yet: it is created with just the key
local NEW = T .. "/fresh/settings.json"
out = runCmd(core.settingsNumberCmd(NEW, "cleanupPeriodDays", 365))
eq("no settings.json yet: one with just the key", jqOut(".", NEW), '{"cleanupPeriodDays":365}')
-- Hammerspoon is a GUI app: its PATH is the bare system one, with no Homebrew
local GUI = T .. "/settings-gui.json"
writeFile(GUI, "{}\n")
out = runCmd("env PATH=/usr/bin:/bin " .. core.settingsNumberCmd(GUI, "cleanupPeriodDays", 365))
check("a GUI app's bare PATH still finds jq", (core.settingsEnvResult(out)))
-- refused before any shell
eq("a key that isn't a plain name is refused", core.settingsNumberCmd(SET, "BAD KEY; rm", 1), nil)
eq("...a value that isn't a whole number too", core.settingsNumberCmd(SET, "cleanupPeriodDays", "365; rm"), nil)
eq("...or a fraction", core.settingsNumberCmd(SET, "cleanupPeriodDays", 1.5), nil)
eq("...or an absurd one", core.settingsNumberCmd(SET, "cleanupPeriodDays", 10 ^ 12), nil)
-- the env writer still works after sharing the script with it
out = runCmd(core.settingsEnvCmd(SET, "FOO", "2"))
check("the env writer still writes env.<key>", (core.settingsEnvResult(out)) and jqOut(".env.FOO", SET) == '"2"'
      and jqOut(".cleanupPeriodDays", SET) == "400")

-- ---- the feature list ----
local fk = {}; for _, ft in ipairs(core.FEATURES) do fk[ft.key] = ft end
check("FEATURES lists Kept transcripts, flagged new", fk.keeper ~= nil and fk.keeper.new == true
      and fk.keeper.title == "Kept transcripts")

sh("rm -r " .. q(T))
finish()
