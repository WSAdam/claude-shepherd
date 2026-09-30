-- compat.test.lua : Claude Code compatibility alarms (build program unit 40, 2026-09-29).
-- 2026-09-29: Shepherd leans on things Claude Code never promised to keep -- the hook events it
-- wires, the env vars it sets and reads, the transcript's message.usage / origin.kind / last-prompt
-- records and interrupt marker, and the fields of ~/.claude/sessions/<pid>.json. An update that
-- drops one breaks a card silently. Once per new Claude Code version (read from the session files'
-- `version`, no process spawned) Shepherd checks each of them in the background and says so in
-- Diagnostics; a failure raises a toast and a phone push, once per version. Pure evaluation in core
-- on literal fixtures (and the real scrubbed ones); the check's shell command run for real on temp
-- files; the trigger, the once-per-version alert and Diagnostics through the real FX functions under
-- a stubbed Hammerspoon in a temp HOME.

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
  print(string.format("-- compat.test.lua: %d run, %d failed --", run, failed))
  os.exit(failed == 0 and 0 or 1)
end

local function sh(cmd) local p = io.popen(cmd); local out = p and p:read("*a") or ""; if p then p:close() end; return out end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local HOME = sh("mktemp -d 2>/dev/null"):gsub("%s+$", "")
assert(HOME ~= "", "could not mktemp a HOME")
local function writeFile(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function readAll(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = core.json or json

local function rowsText(rows)
  local t = {}
  for _, r in ipairs(rows or {}) do t[#t + 1] = r.status .. " | " .. r.label .. " | " .. tostring(r.detail or "") end
  return table.concat(t, "\n")
end
local function findRow(rows, needle)
  for _, r in ipairs(rows or {}) do
    if (r.label .. " " .. tostring(r.detail or "")):find(needle, 1, true) then return r end
  end
end
local function hasFn(name) return type(core[name]) == "function" end

check("core ships the compatibility check", type(core.CC_COMPAT) == "table" and hasFn("compatDue") and hasFn("compatChecks"))
if not (type(core.CC_COMPAT) == "table" and hasFn("compatDue") and hasFn("compatChecks")) then sh("rm -r " .. q(HOME)); finish() end

-- ---- the trigger: once per new version, from the session files (2026-09-29) ----------------------
local function entry(pid, version, extra)
  local e = { pid = pid, sessionId = "sid-" .. pid, cwd = "/Users/u/proj", name = "proj-" .. pid, version = version,
              kind = "interactive", entrypoint = "claude-vscode" }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
local reg = { ["101"] = entry(101, "2.1.284"), ["102"] = entry(102, "2.1.285"), ["103"] = entry(103, "2.1.9") }
eq("the newest version any session runs (numerically: 2.1.285 > 2.1.9)", core.compatNewestVersion(reg), "2.1.285")
local due = core.compatDue(reg, nil, 1000)
eq("new: never checked -> the newest version is due", due and due.version, "2.1.285")
eq("...as a new check", due and due.kind, "new")
due = core.compatDue(reg, { version = "2.1.284", firstAt = 1, scannedAt = 2 }, 1000)
eq("new: a version newer than the last checked is due", due and due.version, "2.1.285")
eq("same: the version already checked is not checked again",
   core.compatDue(reg, { version = "2.1.285", firstAt = 900, scannedAt = 990,
                         facts = { version = "2.1.285", transcript = { usage = true, origin = true, lastPrompt = true, interrupt = true } } }, 1000), nil)
eq("an older version than the last checked (a downgrade, or the newest session ended) is not rechecked",
   core.compatDue({ ["101"] = entry(101, "2.1.284") }, { version = "2.1.285", firstAt = 1, scannedAt = 2 }, 1000), nil)
eq("unreadable: no session files at all", core.compatDue({}, nil, 1000), nil)
eq("unreadable: a nil registry", core.compatDue(nil, nil, 1000), nil)
eq("unreadable: session files with no version", core.compatDue({ ["1"] = entry(1, nil), ["2"] = { pid = 2 } }, nil, 1000), nil)
eq("unreadable: a version that isn't one", core.compatDue({ ["1"] = entry(1, "latest"), ["2"] = entry(2, 42), ["3"] = "garbage" }, nil, 1000), nil)
eq("...and a garbled last-checked version counts as never checked",
   (core.compatDue(reg, { version = "???" }, 1000) or {}).kind, "new")
check("unreadable registry is reported (files, none with a version)", core.compatUnreadable({ ["1"] = { pid = 1 } }) == true)
check("...but no session files at all is not", core.compatUnreadable({}) == false)
check("...nor a registry with a readable version", core.compatUnreadable(reg) == false)

-- rescans: what the transcripts couldn't show yet is looked for again, for a day
local C = core.CC_COMPAT
local pending = { version = "2.1.285", firstAt = 1000, scannedAt = 1000,
                  facts = { version = "2.1.285", transcript = { usage = true, origin = true, lastPrompt = true } } }
eq("an unsettled version is not rescanned before rescanSeconds", core.compatDue(reg, pending, 1000 + C.rescanSeconds - 1), nil)
due = core.compatDue(reg, pending, 1000 + C.rescanSeconds)
eq("...then it is (the interrupt marker isn't known yet)", due and due.kind, "rescan")
eq("...for that version", due and due.version, "2.1.285")
eq("...but not once the version is a day old", core.compatDue(reg, pending, 1000 + C.settleSeconds + 1), nil)
eq("...nor when no live session runs it any more",
   core.compatDue({ ["101"] = entry(101, "2.1.284") }, pending, 1000 + C.rescanSeconds), nil)

-- ---- the session files' fields ----------------------------------------------------------------
local sf = core.compatSessionFacts(reg, "2.1.285")
eq("every field Shepherd reads is there", #sf.missing, 0)
eq("...in the one file of that version", sf.entries, 1)
local noName = { ["7"] = entry(7, "2.1.300", { name = nil }) }
noName["7"].name = nil
sf = core.compatSessionFacts(noName, "2.1.300")
eq("a session file missing `name` (the SendMessage address): flagged", table.concat(sf.missing, ","), "name")
local mixed = { ["7"] = noName["7"], ["8"] = entry(8, "2.1.300") }
eq("a field another file of that version still carries still exists", #core.compatSessionFacts(mixed, "2.1.300").missing, 0)
eq("files of other versions don't count", core.compatSessionFacts(reg, "2.1.300").entries, 0)
local rows = core.compatChecks({ state = { version = "2.1.300", facts = { version = "2.1.300", session = core.compatSessionFacts(noName, "2.1.300") } } })
local r = findRow(rows, "name")
eq("Diagnostics: a missing session field is a warning", r and r.status, "warn")
check("...saying what Shepherd reads it for", r and (r.detail or ""):find("SendMessage", 1, true) ~= nil)

-- ---- the hook events Shepherd wires -----------------------------------------------------------
local settings = { hooks = {
  Stop = { { hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-status.sh" stop' } } } },
  PreToolUse = { { matcher = "", hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-approve.sh"', timeout = 130 } } } },
  FutureEvent = { { hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-status.sh" future' } } } },
  Notification = { { hooks = { { type = "command", command = "my-own-notifier.sh" } } } },
} }
eq("the events that run one of Shepherd's scripts, sorted (a user's own hook doesn't count)",
   table.concat(core.compatHookEvents(settings), ","), "FutureEvent,PreToolUse,Stop")
eq("no settings: no events", #core.compatHookEvents(nil), 0)
local needles = core.compatNeedles({ "Stop", "FutureEvent" })
check("an event is looked for quoted, as the JS bundle names it", needles[1].needle == '"Stop"' and needles[1].kind == "event")
local envCount = 0
for _, n in ipairs(needles) do if n.kind == "env" then envCount = envCount + 1 end end
eq("...then every env var Shepherd sets or reads", envCount, #C.envVars)
local names = {}
for _, e in ipairs(C.envVars) do names[e.name] = true end
check("the env vars include the auto-compact override and the spawn's model",
      names.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE and names.ANTHROPIC_MODEL and names.CLAUDE_PROJECT_DIR)
-- grep exit codes: 0 found, 1 not found, anything else unreadable
local grep = {}
for i, n in ipairs(needles) do grep[i] = (n.name == "FutureEvent") and 1 or 0 end
local bf = core.compatGrepFacts(needles, grep)
eq("an event the binary mentions: known", bf.events.Stop, true)
eq("an unknown hook event: flagged", bf.events.FutureEvent, false)
eq("an env var it mentions: known", bf.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, true)
grep[1] = 2
eq("a grep that couldn't read the binary: unknown, not a failure", core.compatGrepFacts(needles, grep).events.Stop, nil)
local facts = { version = "2.1.300", hooks = { "FutureEvent", "Stop" },
                binary = { label = "claude CLI", path = "/b", events = bf.events, env = bf.env } }
rows = core.compatChecks({ state = { version = "2.1.300", facts = facts } })
r = findRow(rows, "FutureEvent")
eq("Diagnostics: an unknown hook event is critical", r and r.status, "crit")
check("...it names the version", r and (r.label .. (r.detail or "")):find("2.1.300", 1, true) ~= nil)
check("...and carries a fix", r and type(r.fix) == "string" and r.fix ~= "")
local envMissing = {}
for k, v in pairs(bf.env) do envMissing[k] = v end
envMissing.ANTHROPIC_MODEL = false
rows = core.compatChecks({ state = { version = "2.1.300", facts = { version = "2.1.300", hooks = { "Stop" },
  binary = { label = "claude CLI", path = "/b", events = { Stop = true }, env = envMissing } } } })
r = findRow(rows, "ANTHROPIC_MODEL")
eq("an env var the new claude no longer mentions: a warning", r and r.status, "warn")
r = findRow(rows, "env vars")
check("the ones it still mentions read ok -- marked as a mention, not proof it's honoured",
      rowsText(rows):find("can't verify", 1, true) ~= nil)
rows = core.compatChecks({ state = { version = "2.1.300", facts = { version = "2.1.300", hooks = { "Stop" },
  binary = { none = true, looked = { "/x/versions/2.1.300" } } } } })
r = findRow(rows, "can't verify")
eq("no binary of that version on this Mac: can't verify (info, not an alarm)", r and r.status, "info")
check("...never a failure", not rowsText(rows):find("crit |", 1, true) and not rowsText(rows):find("warn |", 1, true))

-- which binary runs that version: the native install, and each editor extension of that version
local cands = core.compatBinaryCandidates("2.1.285", "/Users/u", {
  { label = "VS Code extension", root = "/Users/u/.vscode/extensions",
    names = { "anthropic.claude-code-2.1.284-darwin-arm64", "anthropic.claude-code-2.1.285-darwin-arm64", "ms-python.python-1.0" } },
  { label = "Cursor extension", root = "/Users/u/.cursor/extensions", names = { "anthropic.claude-code-2.1.2850-darwin-arm64" } } })
eq("the native installer's versioned binary first", cands[1] and cands[1].path, "/Users/u/.local/share/claude/versions/2.1.285")
eq("...then the extension of exactly that version", cands[2] and cands[2].path,
   "/Users/u/.vscode/extensions/anthropic.claude-code-2.1.285-darwin-arm64/resources/native-binary/claude")
eq("...and nothing else (2.1.284 and 2.1.2850 are other versions)", #cands, 2)
eq("no version, no candidates", #core.compatBinaryCandidates(nil, "/Users/u", {}), 0)

-- ---- the transcript: message.usage, origin.kind, last-prompt, the interrupt marker -----------------
local V = "2.1.300"
local function L(s, v) return (s:gsub("@V@", v or V)) .. "\n" end
local A_USAGE = '{"parentUuid":"a","isSidechain":false,"type":"assistant","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":3,"output_tokens":9}},"uuid":"u1","timestamp":"2026-09-29T10:00:01.000Z","version":"@V@"}'
local A_NOUSAGE = '{"parentUuid":"a","isSidechain":false,"type":"assistant","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}]},"uuid":"u1","timestamp":"2026-09-29T10:00:01.000Z","version":"@V@"}'
local P_HUMAN = '{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]},"uuid":"u0","timestamp":"2026-09-29T10:00:00.000Z","origin":{"kind":"human"},"version":"@V@"}'
local P_BARE = '{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]},"uuid":"u0","timestamp":"2026-09-29T10:00:00.000Z","version":"@V@"}'
local P_PEER = '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Another Claude session sent a message"},"isMeta":true,"uuid":"u0","timestamp":"2026-09-29T10:00:00.000Z","origin":{"kind":"peer"},"version":"@V@"}'
local META = '{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":"Caveat: local command"},"isMeta":true,"uuid":"m1","timestamp":"2026-09-29T10:00:00.500Z","version":"@V@"}'
local SUMMARY = '{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation"},"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"uuid":"s1","timestamp":"2026-09-29T10:00:00.600Z","version":"@V@"}'
local TOOLRES = '{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]},"uuid":"r1","timestamp":"2026-09-29T10:00:02.000Z","version":"@V@"}'
local INTR = '{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"uuid":"i1","timestamp":"2026-09-29T10:00:03.000Z","version":"@V@"}'
local INTR_NEW = '{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Interrupted by the user]"}]},"uuid":"i1","timestamp":"2026-09-29T10:00:03.000Z","version":"@V@"}'
local LAST = '{"type":"last-prompt","lastPrompt":"fix the bug","sessionId":"sid"}'

local tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(LAST) .. L(A_USAGE) .. L(TOOLRES) .. L(INTR) }, V)
eq("a healthy transcript: message.usage is there", tf.usage, true)
eq("...origin.kind too", tf.origin, true)
eq("...a last-prompt record", tf.lastPrompt, true)
eq("...and the interrupt marker", tf.interrupt, true)
eq("...from one transcript of that version", tf.files, 1)
tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(LAST) .. L(A_NOUSAGE) .. L(A_NOUSAGE) }, V)
eq("a transcript whose assistant records carry no message.usage: flagged", tf.usage, false)
tf = core.compatTranscriptFacts({ L(P_BARE) .. L(LAST) .. L(A_USAGE) }, V)
eq("a typed prompt with no origin.kind: flagged", tf.origin, false)
tf = core.compatTranscriptFacts({ L(P_PEER) .. L(LAST) .. L(A_USAGE) }, V)
eq("a peer's message (isMeta, origin peer) is origin.kind evidence too", tf.origin, true)
tf = core.compatTranscriptFacts({ L(META) .. L(SUMMARY) .. L(TOOLRES) .. L(A_USAGE) }, V)
eq("meta lines, a compaction summary and tool results are no prompt: origin unknown, not failed", tf.origin, nil)
eq("...and no prompt means last-prompt can't be judged either", tf.lastPrompt, nil)
tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(A_USAGE) .. L(A_USAGE) }, V)
eq("a prompt and two replies but no last-prompt record: flagged", tf.lastPrompt, false)
-- 2026-09-29: of 300 real transcripts, one wrote its first reply before its first last-prompt record
-- (never a second one) -- and the check runs minutes after a new version's first session starts
tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(A_USAGE) }, V)
eq("a brand-new session's first reply before any last-prompt: unknown yet, not a false alarm", tf.lastPrompt, nil)
tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(LAST) .. L(A_USAGE) .. L(INTR_NEW) }, V)
eq("an interrupt that reads differently now: flagged", tf.interrupt, false)
eq("...keeping what it reads now", tf.interruptText, "[Interrupted by the user]")
tf = core.compatTranscriptFacts({ L(P_HUMAN) .. L(LAST) .. L(A_USAGE) }, V)
eq("no interrupted turn: the marker can't be verified yet (nil, not a failure)", tf.interrupt, nil)
tf = core.compatTranscriptFacts({ L(P_BARE, "2.1.299") .. L(A_NOUSAGE, "2.1.299") }, V)
eq("a transcript written by another version doesn't count", tf.files, 0)
eq("...so nothing is judged from it", tf.usage, nil)
tf = core.compatTranscriptFacts({ L(A_NOUSAGE, "2.1.299") .. L(P_HUMAN) .. L(LAST) .. L(A_USAGE) }, V)
eq("a session resumed on the new version: only its new records count", tf.usage, true)
local torn = L(P_HUMAN) .. L(LAST) .. L(A_USAGE) .. A_NOUSAGE:sub(1, 60)
eq("a torn last line (a live transcript) is skipped", core.compatTranscriptFacts({ "ull,\"x\":1}\n" .. torn }, V).usage, true)
eq("nothing to read: every fact unknown", core.compatTranscriptFacts({}, V).usage, nil)

-- the real scrubbed fixtures (tests/fixtures/transcripts), read by the version that wrote them
local function fixture(name) return readAll(HERE .. "fixtures/transcripts/" .. name) or "" end
tf = core.compatTranscriptFacts({ fixture("tail-interrupted-for-tool-use.jsonl") }, "2.1.270")
eq("real 2.1.270 tail: message.usage", tf.usage, true)
eq("real 2.1.270 tail: the interrupt marker", tf.interrupt, true)
eq("real 2.1.270 tail: last-prompt", tf.lastPrompt, true)
tf = core.compatTranscriptFacts({ fixture("tail-turn-committed.jsonl") }, "2.1.263")
eq("real 2.1.263 tail: origin.kind (Claude Code stamps it since 2.1.26x)", tf.origin, true)
tf = core.compatTranscriptFacts({ fixture("tail-ends-on-api-error.jsonl") }, "2.1.258")
eq("real 2.1.258 tail: its prompts carry no origin.kind -- the check flags exactly that build", tf.origin, false)

-- merging a rescan: a fact once known stays known
local merged = core.compatMergeTranscript({ usage = true, origin = true, lastPrompt = true, files = 1 },
                                          { usage = nil, origin = nil, lastPrompt = nil, interrupt = true, files = 2 })
check("a rescan keeps what the first scan knew and adds what it learned",
      merged.usage == true and merged.origin == true and merged.interrupt == true)
local seenLater = core.compatMergeTranscript({ usage = true, lastPrompt = false, files = 1 }, { usage = false, lastPrompt = true, files = 1 })
check("a record seen present beats an earlier scan that missed it (presence is proof, absence isn't)",
      seenLater.lastPrompt == true and seenLater.usage == true)
check("settled only once every transcript fact is known", core.compatSettled({ transcript = merged }) == true
      and core.compatSettled({ transcript = { usage = true } }) == false)

rows = core.compatChecks({ state = { version = V, facts = { version = V, transcript = { usage = false, origin = true, lastPrompt = true } } } })
r = findRow(rows, "message.usage")
eq("Diagnostics: a transcript missing message.usage is a warning", r and r.status, "warn")
r = findRow(rows, "interrupt")
eq("...an interrupt marker not seen yet is can't-verify info", r and r.status, "info")
check("...saying it can't verify", r and (r.label .. " " .. (r.detail or "")):find("can't verify", 1, true) ~= nil)
rows = core.compatChecks({ state = { version = V, facts = { version = V, transcript = { interrupt = false, interruptText = "[Interrupted by the user]" } } } })
r = findRow(rows, "interrupt")
eq("an interrupt marker that changed is a warning", r and r.status, "warn")
check("...quoting what it reads now", r and (r.detail or ""):find("[Interrupted by the user]", 1, true) ~= nil)

-- ---- Diagnostics: its own section -------------------------------------------------------------
rows = core.doctorChecks({ jq = true, ccCompat = { state = { version = V, facts = { version = V, transcript = { usage = true } } } } })
local inSection = 0
for _, row in ipairs(rows) do if row.section == C.section then inSection = inSection + 1 end end
check("doctorChecks carries a 'Claude Code compatibility' section", C.section == "Claude Code compatibility" and inSection > 0)
check("...after the general rows (a header groups them)", rows[#rows].section == C.section and rows[1].section == nil)
rows = core.doctorChecks({ jq = true, ccCompat = {} })
r = findRow(rows, "Not checked yet")
eq("never checked: one info row that says when it will be", r and r.status, "info")
eq("...in the section", r and r.section, C.section)
rows = core.doctorChecks({ jq = true, ccCompat = { checking = "2.1.301", state = { version = V, facts = { version = V } } } })
r = findRow(rows, "Checking Claude Code 2.1.301")
eq("a check in flight says so", r and r.status, "info")
rows = core.doctorChecks({ jq = true, ccCompat = { unreadable = true } })
r = findRow(rows, "Can't tell which Claude Code version runs")
eq("session files with no readable version: a warning (the check can't fire)", r and r.status, "warn")
eq("doctorChecks without ccCompat has no such section (other callers unchanged)",
   (function() for _, row in ipairs(core.doctorChecks({ jq = true })) do if row.section then return row.section end end end)(), nil)

-- ---- the alert: a failure, once per version; a pass is quiet ------------------------------------
local failing = { version = V, facts = { version = V, hooks = { "Stop" }, binary = { path = "/b", events = { Stop = false }, env = {} },
                                          transcript = { usage = false } } }
local msg = core.compatAlertText(failing)
check("a failure raises an alert", type(msg) == "string")
check("...naming the version and what broke", msg and msg:find(V, 1, true) and msg:find("Stop", 1, true) and msg:find("message.usage", 1, true))
check("...and where to look", msg and msg:find("Diagnostics", 1, true) ~= nil)
failing.alerted = V
eq("once per version: already alerted for it, no second alert", core.compatAlertText(failing), nil)
failing.alerted = "2.1.299"
check("...an alert for an older version doesn't count", core.compatAlertText(failing) ~= nil)
eq("a pass is quiet", core.compatAlertText({ version = V, facts = { version = V, hooks = { "Stop" },
  binary = { path = "/b", events = { Stop = true }, env = {} }, transcript = { usage = true } } }), nil)
eq("can't-verify alone is quiet", core.compatAlertText({ version = V, facts = { version = V, binary = { none = true } } }), nil)
eq("nothing checked: quiet", core.compatAlertText(nil), nil)

-- ---- the background check's shell command, run for real on temp files ---------------------------
sh("mkdir -p " .. q(HOME .. "/projects/-p-one") .. " " .. q(HOME .. "/projects/-p-two") .. " " .. q(HOME .. "/bin"))
local BIN = HOME .. "/bin/claude it's"
writeFile(BIN, 'junk\0"Stop"\0process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\0"SessionStart"\0more')
local big = string.rep("x", C.lineBytes + 10)
writeFile(HOME .. "/projects/-p-one/sid-a.jsonl",
  L(P_HUMAN) .. L(LAST) .. L(A_USAGE) .. L(TOOLRES)
  .. '{"type":"user","message":{"role":"user","content":"' .. big .. '"},"version":"' .. V .. '"}\n'
  .. '{"type":"attachment","attachment":{"type":"hook"},"version":"' .. V .. '"}\n')
writeFile(HOME .. "/projects/-p-two/sid-b.jsonl", L(P_HUMAN) .. L(INTR))
local job = { binary = BIN, needles = core.compatNeedles({ "Stop", "PreCompact" }), projectsDir = HOME .. "/projects",
              sids = { "sid-a", "sid-b", "sid-none", "bad sid; rm -rf /" } }
local cmd = core.compatCheckCmd(job)
check("the check is one shell command", type(cmd) == "string")
check("...an id that isn't one never reaches it", cmd and not cmd:find("rm -rf", 1, true))
local parsed = core.compatParseOutput(sh("/bin/sh -c " .. q(cmd or "exit 1")))
local gf = core.compatGrepFacts(job.needles, parsed.grep)
eq("run for real: the binary mentions \"Stop\"", gf.events.Stop, true)
eq("...not \"PreCompact\"", gf.events.PreCompact, false)
eq("...it mentions CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", gf.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, true)
eq("...not ANTHROPIC_MODEL", gf.env.ANTHROPIC_MODEL, false)
eq("each session's transcript is found in whichever project folder holds it", #parsed.files, 2)
check("...tool results, attachments and over-long lines are left out", parsed.files[1] and not parsed.files[1]:find("tool_result", 1, true)
      and not parsed.files[1]:find("attachment", 1, true) and not parsed.files[1]:find(big, 1, true))
tf = core.compatTranscriptFacts(parsed.files, V)
check("...and what's kept is enough for every fact", tf.usage == true and tf.origin == true and tf.lastPrompt == true and tf.interrupt == true)
job.binary = HOME .. "/bin/missing"
parsed = core.compatParseOutput(sh("/bin/sh -c " .. q(core.compatCheckCmd(job))))
eq("an unreadable binary: unknown, never 'no longer mentions'", core.compatGrepFacts(job.needles, parsed.grep).events.Stop, nil)
eq("nothing to do: no command", core.compatCheckCmd({}), nil)

-- ---- the real FX functions under a stubbed Hammerspoon -------------------------------------------
local realGetenv = os.getenv
os.getenv = function(k)
  if k == "HOME" then return HOME end
  if k == "CC_STATUS_DIR" then return HOME .. "/status" end
  if k == "CC_SESSIONS_DIR" then return HOME .. "/sessions" end
  if k == "CC_PROJECTS_DIR" then return HOME .. "/projects" end
  if k:sub(1, 3) == "CC_" then return nil end
  return realGetenv(k)
end
sh("mkdir -p " .. q(HOME .. "/.claude/cc-scratch") .. " " .. q(HOME .. "/.claude/cc-ledger") .. " "
   .. q(HOME .. "/status") .. " " .. q(HOME .. "/sessions") .. " " .. q(HOME .. "/.local/share/claude/versions"))
writeFile(HOME .. "/.claude/cc-config.json", '{"escalation":{"pushTopic":"compat-topic"}}\n')
writeFile(HOME .. "/.claude/settings.json", json.encode({ hooks = {
  SessionStart = { { hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-status.sh" sessionstart' } } } },
  Stop = { { hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-status.sh" stop' } } } },
  PreCompact = { { hooks = { { type = "command", command = 'bash "$HOME/.claude/cc-status.sh" precompact' } } } },
} }))
-- 2.1.300 dropped "PreCompact" and its transcripts carry no message.usage
writeFile(HOME .. "/.local/share/claude/versions/2.1.300", 'x"SessionStart"x"Stop"x' .. (function()
  local t = {}
  for _, e in ipairs(C.envVars) do t[#t + 1] = e.name end
  return table.concat(t, "|")
end)())
writeFile(HOME .. "/sessions/111.json", json.encode(entry(111, "2.1.300", { sessionId = "sid-live" })))
writeFile(HOME .. "/projects/-p-one/sid-live.jsonl", L(P_HUMAN) .. L(LAST) .. L(A_NOUSAGE))

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
    pathToAbsolute = function(p) return p end,
    mkdir = function(p) sh("mkdir " .. q(p) .. " 2>/dev/null"); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd) executed[#executed + 1] = cmd; return "" end,
  -- hs.task: queued, run by the test when it says so (the check is async in the panel)
  task = { new = function(bin, cb, args)
    local t = { bin = bin, cb = cb, args = args }
    t.start = function(self) tasks[#tasks + 1] = self; return self end
    t.isRunning = function() return false end
    t.terminate = function() end
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
    local c = q(t.bin)
    for _, a in ipairs(t.args or {}) do c = c .. " " .. q(a) end
    local o = sh(c .. "; echo \"@@rc:$?\"")
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
if not ok then print("       " .. tostring(err)); sh("rm -r " .. q(HOME)); finish() end
local FX = _G.__ccDashboard.fx
core = _G.__ccDashboard.core
check("the session files are read from this HOME's test dir (never the real ones)", FX.SESSIONS_DIR == HOME .. "/sessions")

local toasts, pushes = {}, {}
local realAlert = FX.alert
FX.alert = function(m, secs) toasts[#toasts + 1] = tostring(m); return realAlert(m, secs) end
FX.push = function(topic, title, m) pushes[#pushes + 1] = { topic = topic, title = title, msg = m } end
local clock = 5000000
FX.now = function() return clock end
local function step() FX._compat.nextCheck = 0; FX.stepCompat({ escalation = { pushTopic = "compat-topic" } }) end

-- a new version: the check starts in the background -- nothing spawned just to learn the version
local ex0 = #executed
step()
eq("a new Claude Code version starts one background check (hs.task)", #tasks, 1)
eq("...the version itself was read from the session files, no process run", #executed, ex0)
eq("...nothing is saved or alerted before the check finishes", toasts[1], nil)
runTasks()
local st = FX.compatState()
eq("the check is remembered for that version", st and st.version, "2.1.300")
eq("...the unknown hook event is found", st and st.facts.binary.events.PreCompact, false)
eq("...an event it still knows", st and st.facts.binary.events.Stop, true)
eq("...the transcript missing message.usage is found", st and st.facts.transcript.usage, false)
eq("...every session field is there", st and #st.facts.session.missing, 0)
eq("a failure raises one toast", #toasts, 1)
check("...naming the version, and Diagnostics", toasts[1] and toasts[1]:find("2.1.300", 1, true) and toasts[1]:find("Diagnostics", 1, true))
eq("...and one phone push", #pushes, 1)
eq("...to the escalation topic", pushes[1] and pushes[1].topic, "compat-topic")
eq("...marked alerted for that version", st and st.alerted, "2.1.300")

-- the same version again: no check, no alert
clock = clock + 120
step()
eq("same version a minute later: no new check", #tasks, 0)
-- a rescan (the interrupt marker isn't known yet) finds the same failure: no second alert
clock = clock + C.rescanSeconds + 1
step()
eq("an unsettled version is looked at again later", #tasks, 1)
runTasks()
eq("...a failure it still finds is not alerted twice", #toasts, 1)
eq("...nor pushed twice", #pushes, 1)
-- the tick throttles itself: a second call inside checkEverySeconds reads nothing
FX._compat.nextCheck = clock + 30
FX.stepCompat({})
eq("between checks the tick does nothing", #tasks, 0)

-- a newer version that passes: quiet
writeFile(HOME .. "/.local/share/claude/versions/2.1.301", 'x"SessionStart"x"Stop"x"PreCompact"x' .. (function()
  local t = {}
  for _, e in ipairs(C.envVars) do t[#t + 1] = e.name end
  return table.concat(t, "|")
end)())
writeFile(HOME .. "/sessions/112.json", json.encode(entry(112, "2.1.301", { sessionId = "sid-new" })))
writeFile(HOME .. "/projects/-p-two/sid-new.jsonl", L(P_HUMAN, "2.1.301") .. L(LAST) .. L(A_USAGE, "2.1.301") .. L(INTR, "2.1.301"))
clock = clock + 120
step()
eq("a newer version gets its own check", #tasks, 1)
runTasks()
st = FX.compatState()
eq("...remembered", st and st.version, "2.1.301")
eq("a pass raises no toast", #toasts, 1)
eq("...and no push", #pushes, 1)

-- 2026-09-29: a saved check with no facts table (hand-edited, or an older shape) was indexed as one
-- by the rescan -- an error every minute, swallowed by the tick's pcall
settingsStore[FX.COMPAT_SETTINGS_KEY] = { version = "2.1.301", firstAt = clock, scannedAt = clock - C.rescanSeconds - 1 }
clock = clock + 1
local okr, errr = pcall(step)
check("a saved check with no facts is rescanned without an error" .. (okr and "" or (" (" .. tostring(errr) .. ")")), okr)
runTasks()
st = FX.compatState()
check("...and gets its transcript facts back", st and type(st.facts) == "table" and type(st.facts.transcript) == "table")
eq("...quietly", #toasts, 1)

-- unreadable session files: nothing happens
sh("rm " .. q(HOME .. "/sessions/111.json") .. " " .. q(HOME .. "/sessions/112.json"))
writeFile(HOME .. "/sessions/113.json", "{not json")
writeFile(HOME .. "/sessions/114.json", json.encode({ pid = 114, sessionId = "x" }))
settingsStore[FX.COMPAT_SETTINGS_KEY] = nil
clock = clock + 120
step()
eq("unreadable session files start no check", #tasks, 0)

-- Diagnostics gathers the facts and shows the section
settingsStore[FX.COMPAT_SETTINGS_KEY] = st
local drows = FX.doctorStatus()
local sect = 0
for _, row in ipairs(drows) do if row.section == "Claude Code compatibility" then sect = sect + 1 end end
check("Diagnostics shows the Claude Code compatibility section", sect > 0)
check("...with the version it checked", rowsText(drows):find("2.1.301", 1, true) ~= nil)
check("...and says the session files have no readable version now", findRow(drows, "Can't tell which Claude Code version runs") ~= nil)

sh("rm -r " .. q(HOME))
finish()
