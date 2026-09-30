-- coach.test.lua : BEHAVIORAL fixture for the coach (2026-09-29, build program unit 32).
-- Weekly (catching up after sleep) and on demand from a card, the coach reads a repo's last 10
-- sessions -- Adam's corrections, interrupts, tool errors, denials with a note, merge notes and
-- checker findings -- into a digest capped at ~30KB, adds the repo's CLAUDE.md and DECISIONS.md,
-- and runs a headless Sonnet (FX.runHeadless, the checker's lane, a $1 cap) that proposes up to 5
-- CLAUDE.md edits with evidence. Adam applies or skips each: Apply refuses when CLAUDE.md changed
-- since the coach read it (hash) or has uncommitted edits, and otherwise commits CLAUDE.md alone.
-- The pure half runs cc-core.lua on literal fixtures (and the commit command in a temp repo); the
-- panel half runs the real claude-dashboard.lua under a stubbed hs, with real git in a temp repo,
-- the transcript scan run for real, and the test playing claude's part.
-- Side-effect-free: HOME and every dir live in a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- coach.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
T = T:gsub("/$", "")
do local p = io.popen("cd '" .. T .. "' && pwd -P"); local r = p and p:read("*l"); if p then p:close() end; if r and r ~= "" then T = r end end
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function sh(cmd)
  local p = io.popen(cmd .. " 2>&1; echo \"@@exit=$?\"")
  local out = p and p:read("*a") or ""; if p then p:close() end
  local code = tonumber(out:match("@@exit=(%d+)%s*$")) or -1
  return out:gsub("@@exit=%d+%s*$", ""), code
end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json
check("core.coachSessionFacts exists", type(core.coachSessionFacts) == "function")
if type(core.coachSessionFacts) ~= "function" then finish() end

-- A literal window of a real-shaped transcript: the torn head a `tail -c` leaves, Adam's first
-- prompt, an assistant reply, the same tool error twice, a denial with a note and one without,
-- an interrupt, a correction, Shepherd's own prompt, a task notification, a NOT YET merge note
-- in a tool result, a plain tool result, a meta line, and the torn last line.
local TR = table.concat({
  'ser","content":"torn head"},"timestamp":"2026-09-28T09:59:00.000Z"}',
  '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Add a coach to Shepherd"},"uuid":"u1","timestamp":"2026-09-28T10:00:00.000Z","cwd":"/r/repo","sessionId":"s1","gitBranch":"feat/coach","origin":{"kind":"human"}}',
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]},"timestamp":"2026-09-28T10:00:05.000Z"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>File has not been read yet. Read it first before writing to it.</tool_use_error>","is_error":true,"tool_use_id":"t1"}]},"timestamp":"2026-09-28T10:01:00.000Z","gitBranch":"feat/coach"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>File has not been read yet. Read it first before writing to it.</tool_use_error>","is_error":true,"tool_use_id":"t1b"}]},"timestamp":"2026-09-28T10:01:30.000Z","gitBranch":"feat/coach"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn\'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). The user provided the following reason for the rejection:  never run make install from a worktree","is_error":true,"tool_use_id":"t2"}]},"timestamp":"2026-09-28T10:02:00.000Z"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn\'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true,"tool_use_id":"t2b"}]},"timestamp":"2026-09-28T10:02:30.000Z"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-09-28T10:03:00.000Z"}',
  '{"type":"user","message":{"role":"user","content":"no -- use git restore, not git checkout"},"timestamp":"2026-09-28T10:04:00.000Z","origin":{"kind":"human"}}',
  '{"type":"user","message":{"role":"user","content":"[shepherd] Continue where you left off"},"timestamp":"2026-09-28T10:04:10.000Z","origin":{"kind":"human"}}',
  '{"type":"user","message":{"role":"user","content":"<task-notification><status>completed</status></task-notification>"},"timestamp":"2026-09-28T10:04:20.000Z","origin":{"kind":"task-notification"}}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"NOT YET: the README line is too long\\nAdam isn\'t ready to merge feat/coach.","tool_use_id":"t3"}]},"timestamp":"2026-09-28T10:05:00.000Z","gitBranch":"feat/coach"}',
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"all 12 tests passed","tool_use_id":"t4"}]},"timestamp":"2026-09-28T10:05:30.000Z"}',
  -- 2026-09-29: a Read of cc-merge.sh's own source holds the words mid-line; it is no merge note
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"   212\\t          echo \\"NOT YET: ${note:-(no note)}\\"\\n   213\\t          echo done","tool_use_id":"t5"}]},"timestamp":"2026-09-28T10:05:35.000Z"}',
  '{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands."},"timestamp":"2026-09-28T10:05:40.000Z"}',
  '{"type":"user","message":{"role":"us',
}, "\n")

local F = core.coachSessionFacts(TR)
check("facts: the first prompt is what the session was asked", F.asked == "Add a coach to Shepherd")
check("facts: Adam's later prompt is a correction  (" .. tostring(F.corrections and F.corrections[1]) .. ")",
      type(F.corrections) == "table" and #F.corrections == 1 and F.corrections[1] == "no -- use git restore, not git checkout")
check("facts: Shepherd's own prompt, a task notification and a meta line are no corrections",
      #F.corrections == 1)
check("facts: the interrupt is counted", F.interrupts == 1)
check("facts: a tool error, its tags stripped, counted twice  (" .. tostring(F.errors and F.errors[1] and F.errors[1].text) .. ")",
      type(F.errors) == "table" and #F.errors == 1 and F.errors[1].text == "File has not been read yet. Read it first before writing to it."
      and F.errors[1].n == 2)
check("facts: a denial keeps Adam's note  (" .. tostring(F.denials and F.denials[1]) .. ")",
      type(F.denials) == "table" and #F.denials == 1 and F.denials[1] == "never run make install from a worktree")
check("facts: a denial with no note is counted, not quoted", F.bareDenials == 1)
check("facts: a NOT YET merge note in a tool result  (" .. tostring(F.notes and F.notes[1]) .. ")",
      type(F.notes) == "table" and #F.notes == 1 and F.notes[1] == "the README line is too long")
check("facts: the branch and the newest time", F.branch == "feat/coach" and F.at == core.isoToEpoch("2026-09-28T10:05:40.000Z"))
check("facts: a torn head and a torn tail are skipped, nothing else read  (" .. tostring(F.asked) .. ")", F.asked ~= "torn head")
local E = core.coachSessionFacts("")
check("facts: an empty window has no evidence", E.asked == nil and #E.corrections == 0 and E.interrupts == 0 and #E.errors == 0)

-- the digest: its sections, newest session first, merge notes and checker findings from Shepherd's log
local F2 = core.coachSessionFacts(table.concat({
  '{"type":"user","message":{"role":"user","content":"Fix the tick freeze"},"timestamp":"2026-09-29T08:00:00.000Z","gitBranch":"fix/tick","origin":{"kind":"human"}}',
  '{"type":"user","message":{"role":"user","content":"stop -- time the tick in the live VM first"},"timestamp":"2026-09-29T08:10:00.000Z","origin":{"kind":"human"}}',
  "" }, "\n"))
local LOG = {
  { kind = "notyet", id = "notyet|n1|1", branch = "feat/x", note = "split the README change out", at = 1790600000 },
  { kind = "blocked", id = "blocked|n2", branch = "feat/y", note = "the suite stays red on main", at = 1790600100 },
  { kind = "checker", id = "checker|n3|abc|fail", branch = "feat/z", verdict = "fail", summary = "a stub left in", at = 1790600200,
    findings = { { file = "app.lua", line = 2, severity = "high", issue = "not implemented" } } },
}
local D = core.coachDigest({ { id = "s2", facts = F2 }, { id = "s1", facts = F } }, LOG, {})
local text = D.text or ""
check("digest: Adam's corrections section", text:find("Adam's corrections", 1, true) ~= nil and text:find("no -- use git restore", 1, true) ~= nil)
check("digest: interrupts", text:find("Interrupted", 1, true) ~= nil)
check("digest: tool errors, a repeat marked ×2", text:find("Tool errors", 1, true) ~= nil and text:find("(×2)", 1, true) ~= nil)
check("digest: denials with a note", text:find("Denied with a note", 1, true) ~= nil and text:find("never run make install from a worktree", 1, true) ~= nil)
check("digest: the session's own merge note", text:find("the README line is too long", 1, true) ~= nil)
check("digest: Shepherd's merge notes and checker findings",
      text:find("Merge notes and checker findings", 1, true) ~= nil and text:find("split the README change out", 1, true) ~= nil
      and text:find("the suite stays red on main", 1, true) ~= nil and text:find("a stub left in", 1, true) ~= nil
      and text:find("app.lua:2", 1, true) ~= nil)
check("digest: newest session first", (text:find("Fix the tick freeze", 1, true) or 1e9) < (text:find("Add a coach to Shepherd", 1, true) or 0))
check("digest: counts what it read", D.sessions == 2 and D.bytes == #text and not D.cut)
-- the cap: ten sessions of long corrections stay under ~30KB, and say they were cut
local long = {}
for i = 1, 20 do
  long[#long + 1] = '{"type":"user","message":{"role":"user","content":"' .. ("correction " .. i .. " "):rep(60)
    .. '"},"timestamp":"2026-09-29T09:' .. string.format("%02d", i) .. ':00.000Z","origin":{"kind":"human"}}'
end
local big = core.coachSessionFacts(table.concat(long, "\n") .. "\n")
local many = {}
for i = 1, 10 do many[i] = { id = "s" .. i, facts = big } end
local capped = core.coachDigest(many, LOG, {})
check("digest: capped at COACH.digestBytes  (" .. tostring(capped.bytes) .. ")",
      core.COACH and capped.bytes <= core.COACH.digestBytes and #capped.text == capped.bytes)
check("digest: ...and says it was cut", capped.cut == true and capped.text:find("cut", 1, true) ~= nil)
check("digest: one item is capped too  (" .. tostring(#(big.corrections[1] or "")) .. ")",
      #(big.corrections[1] or "") <= core.COACH.promptChars + 3)
local noneD = core.coachDigest({}, {}, {})
check("digest: nothing to read is empty", noneD.empty == true)

-- which transcript folders are this repo's: its main checkout's and .claude/worktrees/*'s
local dirs = core.coachProjectDirs({ "-r-repo", "-r-repo--claude-worktrees-coach", "-r-repo2", "-r-repo-sub", "-other", ".DS_Store" }, "/r/repo")
check("project dirs: the main checkout and its .claude/worktrees  (" .. table.concat(dirs, " ") .. ")",
      #dirs == 2 and dirs[1] == "-r-repo" and dirs[2] == "-r-repo--claude-worktrees-coach")
local files = {}
for i = 1, 12 do files[i] = { path = "/p/s" .. i .. ".jsonl", mtime = 1000 + i, id = "s" .. i } end
local picked = core.coachPickTranscripts(files, 10)
check("transcripts: the newest ten, newest first", #picked == 10 and picked[1].id == "s12" and picked[10].id == "s3")

-- the scan reads only the lines that can carry evidence (run for real on a temp transcript)
os.execute("mkdir -p " .. q(T .. "/tr"))
local hugeLine = '{"type":"user","message":{"role":"user","content":"' .. ("x"):rep(20000) .. '"},"origin":{"kind":"human"}}'
write(T .. "/tr/s1.jsonl", TR:gsub('{"type":"user","message":{"role":"us$', "") .. hugeLine .. "\n")
local scmd = core.coachScanCmd({ T .. "/tr/s1.jsonl" }, T .. "/tr/out")
check("scan: a shell command", type(scmd) == "string" and scmd ~= "")
sh(scmd or "true")
local got = read(T .. "/tr/out.1") or ""
check("scan: keeps Adam's prompts, errors, denials, the interrupt and the NOT YET note",
      got:find("Add a coach to Shepherd", 1, true) and got:find("File has not been read yet", 1, true)
      and got:find("never run make install", 1, true) and got:find("Request interrupted", 1, true)
      and got:find("NOT YET: the README", 1, true) and true or false)
check("scan: drops the assistant, a plain tool result and a line past the size cap",
      not got:find("On it.", 1, true) and not got:find("all 12 tests passed", 1, true) and not got:find(("x"):rep(100), 1, true))
check("scan: what it keeps parses back to the same facts", #core.coachSessionFacts(got).corrections == 1
      and core.coachSessionFacts(got).denials[1] == "never run make install from a worktree")

-- the prompt: the digest, CLAUDE.md and DECISIONS.md, and the rule about DECISIONS.md
local P = core.coachPrompt(D, "# Repo\n\n## Git\n\n- commit often\n", "# Decisions\n\n## Keep bash\n\nWhy: portable\n", { name = "repo" })
check("prompt: carries the evidence, CLAUDE.md and DECISIONS.md",
      P:find("never run make install from a worktree", 1, true) and P:find("- commit often", 1, true)
      and P:find("## Keep bash", 1, true) and true or false)
check("prompt: never undo a DECISIONS.md entry", P:find("DECISIONS.md", 1, true) ~= nil and P:lower():find("never propose", 1, true) ~= nil)
check("prompt: asks for at most 5 edits as JSON", P:find('"edits"', 1, true) ~= nil and P:find("5", 1, true) ~= nil)
local P0 = core.coachPrompt(D, nil, nil, { name = "repo" })
check("prompt: a repo with no CLAUDE.md is told so", P0:find("no CLAUDE.md", 1, true) ~= nil)

-- the proposal parser: anything short of the edits JSON is couldn't-run
local function envelope(result, over)
  local e = { type = "result", subtype = "success", is_error = false, num_turns = 3, total_cost_usd = 0.21, result = result }
  for k, v in pairs(over or {}) do e[k] = v end
  return json.encode(e)
end
local function edit(i, over)
  local e = { section = "Git", old = "- line " .. i, new = "- line " .. i .. " sharper", why = "why " .. i, evidence = { "Adam said " .. i } }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end
local good = { summary = "Two things kept going wrong.",
  edits = { edit(1), edit(2, { evidence = {} }), edit(3, { new = "- line 3" }), edit(4), edit(5), edit(6), edit(7), edit(8) },
  decisions = { { what = "Keep bash for hooks", why = "portable" }, { what = "", why = "no what" } } }
local p = core.parseCoachOutput("Last login: Mon\n" .. envelope("Here is what I found.\n" .. json.encode(good)), "")
check("parse: proposals, after a login shell's noise  (" .. tostring(p.verdict) .. ": " .. tostring(p.why) .. ")", p.verdict == "proposals")
check("parse: at most 5 edits, dropping one without evidence and one that changes nothing  (" .. #(p.edits or {}) .. ")",
      #p.edits == 5 and p.edits[1].old == "- line 1" and p.edits[2].old == "- line 4")
check("parse: an edit's fields", p.edits[1].section == "Git" and p.edits[1].new == "- line 1 sharper" and p.edits[1].why == "why 1"
      and p.edits[1].evidence[1] == "Adam said 1")
check("parse: DECISIONS.md entries, a blank one dropped", #p.decisions == 1 and p.decisions[1].what == "Keep bash for hooks")
check("parse: cost and turns", p.costUsd == 0.21 and p.turns == 3)
local bad = core.parseCoachOutput("{not json at all", "")
check("parse: bad JSON is couldn't-run  (" .. tostring(bad.why) .. ")", bad.verdict == "couldntRun" and type(bad.why) == "string")
local nojson = core.parseCoachOutput(envelope("I looked around and have thoughts but no JSON."), "")
check("parse: an answer with no edits JSON is couldn't-run", nojson.verdict == "couldntRun")
local budget = core.parseCoachOutput(envelope("", { subtype = "error_max_budget_usd", is_error = true }), "")
check("parse: its budget ran out: couldn't-run  (" .. tostring(budget.why) .. ")", budget.verdict == "couldntRun" and tostring(budget.why):find("budget", 1, true) ~= nil)
local empty = core.parseCoachOutput(envelope(json.encode({ summary = "Nothing to change.", edits = {}, decisions = {} })), "")
check("parse: nothing to change is a verdict of its own", empty.verdict == "none")
local nothing = core.parseCoachOutput("", "zsh: command not found: claude\n")
check("parse: no answer at all is couldn't-run, naming stderr", nothing.verdict == "couldntRun" and tostring(nothing.why):find("command not found", 1, true) ~= nil)

-- Apply's decision: refused when the file moved or has uncommitted edits, else the whole new file
local CUR = "# Proj\n\n## Tests\n\n- run make test\n\n## Git\n\n- commit often\n"
local H = core.coachHash(CUR)
local e1 = { section = "Git", old = "- commit often", new = "- commit often; never git push" }
local ok1 = core.coachApplyDecision(CUR, H, e1, false)
check("apply: replaces the edit's text", ok1.ok == true and ok1.text == CUR:gsub("%- commit often", "- commit often; never git push"))
check("apply: refused when CLAUDE.md changed since the coach read it", core.coachApplyDecision(CUR .. "- more\n", H, e1, false).error == "changed")
check("apply: refused when CLAUDE.md has uncommitted edits", core.coachApplyDecision(CUR, H, e1, true).error == "dirty")
check("apply: refused when its text isn't there", core.coachApplyDecision(CUR, H, { section = "Git", old = "- nope", new = "x" }, false).error == "not-found")
local TWICE = "- x\n- x\n"
check("apply: refused when its text is there twice", core.coachApplyDecision(TWICE, core.coachHash(TWICE), { old = "- x", new = "- y" }, false).error == "ambiguous")
local add = core.coachApplyDecision(CUR, H, { section = "Tests", old = "", new = "- run make lint first" }, false)
check("apply: an add goes at the end of its section, straight under its list",
      add.ok and add.text == "# Proj\n\n## Tests\n\n- run make test\n- run make lint first\n\n## Git\n\n- commit often\n")
local newsec = core.coachApplyDecision(CUR, H, { section = "Deploy", old = "", new = "Run make deploy from main." }, false)
check("apply: an add for a section that isn't there makes it", newsec.ok and newsec.text == CUR .. "\n## Deploy\n\nRun make deploy from main.\n")
local fresh = core.coachApplyDecision(nil, core.coachHash(nil), { section = "Deploy", old = "", new = "Run make deploy from main." }, false)
check("apply: a repo with no CLAUDE.md gets one", fresh.ok and fresh.text:find("## Deploy\n\nRun make deploy from main.\n", 1, true) ~= nil)
check("apply: a malformed edit is refused", core.coachApplyDecision(CUR, H, nil, false).error == "bad-edit")
check("apply: every refusal has words", type(core.coachRefusal("changed")) == "string" and core.coachRefusal("dirty"):find("uncommitted", 1, true) ~= nil)

-- the commit touches only CLAUDE.md (run for real in a temp repo)
local R = T .. "/crepo"
sh("git init -q " .. q(R) .. " && git -C " .. q(R) .. " config user.email t@example.com && git -C " .. q(R)
   .. " config user.name Tester && git -C " .. q(R) .. " config commit.gpgsign false")
write(R .. "/CLAUDE.md", CUR); write(R .. "/other.txt", "1\n")
sh("git -C " .. q(R) .. " add -A && git -C " .. q(R) .. " commit -q -m init")
write(R .. "/other.txt", "2\n"); sh("git -C " .. q(R) .. " add other.txt")   -- someone's staged work
write(R .. "/wip.txt", "untracked\n")
write(R .. "/CLAUDE.md", ok1.text)
local subject, body = core.coachCommitMessage({ section = "Git", why = "Sessions pushed on their own." })
check("commit message: plain, no attribution", subject == "CLAUDE.md: Git" and body == "Sessions pushed on their own."
      and not (subject .. body):find("Co%-Authored") and not (subject .. body):lower():find("claude code", 1, true))
local ccmd = core.coachCommitCmd(R, subject, body, false)
local cout, ccode = sh(ccmd)
check("commit: it succeeds and prints the sha  (" .. cout:gsub("\n", " ") .. ")", ccode == 0 and cout:match("%x%x%x%x%x%x%x") ~= nil)
check("commit: HEAD changes CLAUDE.md alone", (sh("git -C " .. q(R) .. " show --name-only --format= HEAD")):gsub("%s+$", "") == "CLAUDE.md")
check("commit: someone's staged file stays staged, uncommitted", (sh("git -C " .. q(R) .. " diff --cached --name-only")):gsub("%s+$", "") == "other.txt")
check("commit: the untracked file is left alone", (sh("git -C " .. q(R) .. " status --porcelain -- wip.txt")):find("?? wip.txt", 1, true) ~= nil)
check("commit: CLAUDE.md is clean after it", (sh(core.coachDirtyCmd(R))):gsub("%s+$", "") == "")
check("commit: the message is the plain subject and body",
      (sh("git -C " .. q(R) .. " log -1 --format=%B")):gsub("%s+$", "") == "CLAUDE.md: Git\n\nSessions pushed on their own.")
-- a hook that refuses: nothing committed, the index as it was
write(R .. "/.git/hooks/pre-commit", "#!/bin/sh\nexit 1\n"); sh("chmod +x " .. q(R .. "/.git/hooks/pre-commit"))
write(R .. "/CLAUDE.md", ok1.text .. "- again\n")
local head0 = (sh("git -C " .. q(R) .. " rev-parse HEAD")):gsub("%s+$", "")
local _, fcode = sh(core.coachCommitCmd(R, subject, body, false))
check("commit: a refusing hook fails it, nothing committed", fcode ~= 0 and (sh("git -C " .. q(R) .. " rev-parse HEAD")):gsub("%s+$", "") == head0)
check("commit: ...and leaves the index as it was", (sh("git -C " .. q(R) .. " diff --cached --name-only")):gsub("%s+$", "") == "other.txt")
-- a repo with no CLAUDE.md yet: the new file is committed alone; a refused commit unstages it again
local R2 = T .. "/crepo2"
sh("git init -q " .. q(R2) .. " && git -C " .. q(R2) .. " config user.email t@example.com && git -C " .. q(R2)
   .. " config user.name Tester && git -C " .. q(R2) .. " config commit.gpgsign false")
write(R2 .. "/a.txt", "a\n"); sh("git -C " .. q(R2) .. " add -A && git -C " .. q(R2) .. " commit -q -m init")
write(R2 .. "/b.txt", "b\n"); sh("git -C " .. q(R2) .. " add b.txt")
write(R2 .. "/CLAUDE.md", fresh.text)
local _, ncode = sh(core.coachCommitCmd(R2, "CLAUDE.md: Deploy", "why", true))
check("commit: a new CLAUDE.md is committed alone", ncode == 0
      and (sh("git -C " .. q(R2) .. " show --name-only --format= HEAD")):gsub("%s+$", "") == "CLAUDE.md"
      and (sh("git -C " .. q(R2) .. " diff --cached --name-only")):gsub("%s+$", "") == "b.txt")
local R3 = T .. "/crepo3"
sh("git init -q " .. q(R3) .. " && git -C " .. q(R3) .. " config user.email t@example.com && git -C " .. q(R3)
   .. " config user.name Tester && git -C " .. q(R3) .. " config commit.gpgsign false")
write(R3 .. "/a.txt", "a\n"); sh("git -C " .. q(R3) .. " add -A && git -C " .. q(R3) .. " commit -q -m init")
write(R3 .. "/.git/hooks/pre-commit", "#!/bin/sh\nexit 1\n"); sh("chmod +x " .. q(R3 .. "/.git/hooks/pre-commit"))
write(R3 .. "/CLAUDE.md", fresh.text)
local _, rcode = sh(core.coachCommitCmd(R3, "CLAUDE.md: Deploy", "why", true))
check("commit: a refused new CLAUDE.md is unstaged again", rcode ~= 0
      and (sh("git -C " .. q(R3) .. " diff --cached --name-only")):gsub("%s+$", "") == "")

-- the weekly clock: the most recent <day> 00:00, and catching up after sleep
check("day: mon/Monday/2 cron-style/sun/0/7, default Monday",
      core.coachDay("mon") == 2 and core.coachDay("Monday") == 2 and core.coachDay(1) == 2 and core.coachDay("sun") == 1
      and core.coachDay(0) == 1 and core.coachDay(7) == 1 and core.coachDay(nil) == 2 and core.coachDay("xyz") == nil)
local base = os.time({ year = 2026, month = 9, day = 20, hour = 12, min = 0, sec = 0 })
local slotsOk = true
for h = 0, 7 * 24, 5 do
  local now = base + h * 3600
  local s = core.coachSlot(now, "wed")
  local t = os.date("*t", s)
  if not (s <= now and now - s < 7 * 86400 and t.wday == 4 and t.hour == 0 and t.min == 0) then slotsOk = false end
end
check("slot: always the latest Wednesday 00:00 at or before now", slotsOk)
local NOW = base + 3 * 86400 + 7200
local SLOT = core.coachSlot(NOW, "mon")
local function due(rec, over)
  local o = { now = NOW, enabled = true, day = "mon", newest = NOW - 3600 }
  for k, v in pairs(over or {}) do o[k] = v end
  return core.coachDue(rec, o)
end
check("due: enabled, never run, a session this week", due(nil) == true)
check("due: not while disabled", due(nil, { enabled = false }) == false)
check("due: not while it's running", due(nil, { running = true }) == false)
check("due: not twice in one week", due({ state = "done", verdict = "proposals", lastRunAt = SLOT + 60 }) == false)
check("due: a couldn't-run counts for the week", due({ state = "done", verdict = "couldntRun", lastRunAt = SLOT + 60 }) == false)
check("due: catches up after sleeping through the slot",
      due({ state = "done", verdict = "none", lastRunAt = SLOT - 7 * 86400 + 60 }, { now = SLOT + 86400 + 36000 }) == true)
check("due: not when no session ran since the last run",
      due({ state = "done", verdict = "none", lastRunAt = SLOT - 86400 }, { newest = SLOT - 2 * 86400 }) == false)
local asked = 0
due({ state = "done", verdict = "none", lastRunAt = SLOT + 60 }, { newest = function() asked = asked + 1; return NOW end })
check("due: the transcripts are only looked at when the week says so", asked == 0)
check("due: the transcripts are looked at when it does", due(nil, { newest = function() asked = asked + 1; return NOW end }) == true and asked == 1)
local lost = { state = "lost", trigger = "weekly", at = NOW - 60, attempts = 1, lastRunAt = SLOT - 7 * 86400 }
check("due: a lost run waits before its retry", due(lost) == false)
lost.at = NOW - core.COACH.retryLostSeconds - 1
check("due: ...then it's retried, whatever the week says", due(lost) == true)
lost.attempts = core.COACH.maxLost
check("due: ...but not forever", due(lost) == false)
check("due: ...a run lost that often starts over with the next week",
      due({ state = "lost", trigger = "weekly", at = SLOT - 86400, attempts = core.COACH.maxLost, lastRunAt = SLOT - 8 * 86400 }) == true)
check("due: the reason says whether it's a retry", select(2, due({ state = "lost", trigger = "weekly", at = NOW - core.COACH.retryLostSeconds - 1,
      attempts = 1 })) == "retry" and select(2, due(nil)) == "first")
check("due: a lost run from a card is retried even with the weekly run off",
      due({ state = "lost", trigger = "card", at = NOW - core.COACH.retryLostSeconds - 1, attempts = 1 }, { enabled = false }) == true)

-- the record: a run Hammerspoon's reload killed reads lost, never a verdict
local rec = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", name = "repo", state = "running",
  trigger = "weekly", at = 100, lastRunAt = 50, edits = {}, decisions = {} }))
check("record: a running record reads lost", rec and rec.state == "lost" and rec.verdict == nil)
check("record: ...keeping the last real run", rec and rec.lastRunAt == 50 and rec.at == 100)
local drec = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
  at = 100, doneAt = 200, lastRunAt = 200, claudeHash = H,
  edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "applied", sha = "abc1234" },
            { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, status = "pending" } },
  decisions = { { what = "Keep bash", why = "portable", status = "pending" } } }))
check("record: a done record keeps each edit's status", drec and drec.edits[1].status == "applied" and drec.edits[1].sha == "abc1234"
      and drec.edits[2].status == "pending" and drec.decisions[1].status == "pending")
check("record: torn or foreign JSON is nothing", core.parseCoachRecord("{") == nil and core.parseCoachRecord(json.encode({ v = 2, root = "/r" })) == nil)
local tile = core.coachTileInfo(drec)
check("tile: counts what waits for Adam (an edit and an entry)", tile and tile.pending == 2)
local view = core.coachView(drec)
check("view: every edit and entry, numbered", view and #view.edits == 2 and view.edits[2].i == 2 and #view.decisions == 1 and view.root == "/r/repo")

-- ---- a stale suggestion offers the rerun, and only a stale one (2026-09-30) ----
-- 2026-09-30: the refusal told Adam to run the coach again, but the edit had no button for it.
local CHG, DEC_CHG = core.coachRefusal("changed"), "DECISIONS.md changed since the coach read it"
local srec = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
  at = 100, doneAt = 200, lastRunAt = 200, claudeHash = H,
  edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "pending", error = CHG, errorCode = "changed" },
            { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, status = "pending", error = CHG },
            { section = "Git", old = "e", new = "f", why = "w", evidence = { "e" }, status = "pending", error = core.coachRefusal("dirty"), errorCode = "dirty" },
            { section = "Git", old = "g", new = "h", why = "w", evidence = { "e" }, status = "pending" },
            { section = "Git", old = "i", new = "j", why = "w", evidence = { "e" }, status = "skipped", error = CHG, errorCode = "changed" } },
  decisions = { { what = "Keep bash", why = "portable", status = "pending", error = DEC_CHG, errorCode = "changed" },
                { what = "Tabs", why = "w", status = "pending" } } }))
local sv = core.coachView(srec) or { edits = {}, decisions = {} }
check("view: an edit refused because CLAUDE.md changed offers to run the coach again", sv.edits[1] and sv.edits[1].rerun == true)
check("view: ...also from a record saved before the code was kept (its exact words)", sv.edits[2] and sv.edits[2].rerun == true)
check("view: a refusal a rerun can't fix offers none", sv.edits[3] and sv.edits[3].rerun ~= true)
check("view: an edit with no refusal offers none", sv.edits[4] and sv.edits[4].rerun ~= true)
check("view: an edit already skipped offers none", sv.edits[5] and sv.edits[5].rerun ~= true)
check("view: a DECISIONS.md entry refused because that file changed offers it too",
      sv.decisions[1] and sv.decisions[1].rerun == true and sv.decisions[2] and sv.decisions[2].rerun ~= true)

-- Shepherd's log of merge notes and checker findings: deduped, aged out, capped
local lg = {}
lg = core.coachLogAdd(lg, { kind = "notyet", id = "a", branch = "b", note = "n" }, 1790000000)
lg = core.coachLogAdd(lg, { kind = "notyet", id = "a", branch = "b", note = "n again" }, 1790000001)
check("log: an entry is kept once", #lg == 1 and lg[1].note == "n")
lg = core.coachLogAdd(lg, { kind = "bogus", id = "z" }, 1790000002)
check("log: an unknown kind is refused", #lg == 1)
lg = core.coachLogAdd(lg, { kind = "blocked", id = "c", branch = "b", note = "red" }, 1790000000 + (core.COACH.logDays + 1) * 86400)
check("log: an old entry ages out", #lg == 1 and lg[1].id == "c")
for i = 1, core.COACH.logMax + 5 do lg = core.coachLogAdd(lg, { kind = "notyet", id = "k" .. i, branch = "b", note = "n" }, 1791000000 + i) end
check("log: capped at COACH.logMax, newest kept", #lg == core.COACH.logMax and lg[#lg].id == "k" .. (core.COACH.logMax + 5))
check("log: round-trips through its file", #core.parseCoachLog(json.encode(lg)) == core.COACH.logMax and #core.parseCoachLog("{") == 0)

-- config: off by default, Monday, $1; a Save keeps coach.*
local fcfg = read(ROOT .. "defaults/cc-config.json")
local okd, dcfg = pcall(json.decode, fcfg or "")
local cc = okd and type(dcfg) == "table" and dcfg.coach or {}
check("config: defaults/ ships coach off, on Mondays, at $1", cc.enabled == false and cc.day == "mon" and cc.maxBudgetUsd == 1)
local keep = {}
for _, k in ipairs(core.SETTINGS_KEEP_SUBKEYS.coach or {}) do keep[k] = true end
check("config: SETTINGS_KEEP_SUBKEYS keeps coach.day and coach.maxBudgetUsd", keep.day and keep.maxBudgetUsd and keep.enabled)

-- ---- the panel half: the real claude-dashboard.lua under a stubbed hs ----
local REPO = T .. "/repo"
local COMMON = REPO .. "/.git"
local PROJ = T .. "/projects"
local CDIR = T .. "/.claude/cc-coach"
os.execute("mkdir -p " .. q(T .. "/status") .. " " .. q(T .. "/.claude/cc-scratch") .. " " .. q(PROJ) .. " " .. q(REPO))
sh("git init -q " .. q(REPO) .. " && git -C " .. q(REPO) .. " config user.email t@example.com && git -C " .. q(REPO)
   .. " config user.name Tester && git -C " .. q(REPO) .. " config commit.gpgsign false")
local ORIG = "# Repo\n\n## Tests\n\n- run make test\n\n## Git\n\n- commit often\n"
write(REPO .. "/CLAUDE.md", ORIG); write(REPO .. "/app.lua", "return 1\n")
sh("git -C " .. q(REPO) .. " add -A && git -C " .. q(REPO) .. " commit -q -m init")
local pdir = PROJ .. "/" .. core.encodeProjectPath(REPO)
os.execute("mkdir -p " .. q(pdir))
write(pdir .. "/s1.jsonl", TR .. "\n")
-- the live config has the weekly run off (the first refresh must not start one); the test's own
-- config (CFG) turns it on
write(T .. "/.claude/cc-config.json", json.encode({ coach = { enabled = false, day = "mon" } }))
local RNOW = os.time()
write(T .. "/status/c1.json", json.encode({ status = "done", session_id = "c1", name = "c1", cwd = REPO, since = RNOW - 100,
  updated = RNOW - 60, editor = "vscode", host_window = "c1-host", session_pid = "c1-pid" }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json", CC_LABELS_FILE = T .. "/labels.json",
              HOME = T, CC_PROJECTS_DIR = PROJ, CC_SCRATCH_DIR = T .. "/.claude/cc-scratch" }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, alerts = {}, {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, js)
      jsCalls[#jsCalls + 1] = js
      local m = tostring(js or ""):match("^ccToast%((.*)%)$")
      if m then alerts[#alerts + 1] = m end
    end },
    { __index = function() return function() return webviewHandle() end end })
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local TASKS, TIMERS = {}, {}
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local names, p = {}, io.popen("ls -1a " .. q(path) .. " 2>/dev/null")
      if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return names[i] end
    end,
    attributes = function(path, what)
      local p = io.popen("stat -f '%m %HT' " .. q(path) .. " 2>/dev/null")
      local l = p and p:read("*l"); if p then p:close() end
      if not l then return nil, "no such file" end
      local m, ty = l:match("^(%d+) (.*)$")
      local t = { modification = tonumber(m), mode = (ty == "Directory") and "directory" or "file" }
      if what then return t[what] end
      return t
    end,
    symlinkAttributes = function(path, what)   -- lstat: a link reports itself
      local p = io.popen("stat -f '%HT' " .. q(path) .. " 2>/dev/null")
      local l = p and p:read("*l"); if p then p:close() end
      if not l then return nil end
      local t = { mode = (l == "Symbolic Link") and "link" or ((l == "Directory") and "directory" or "file") }
      if what then return t[what] end
      return t
    end,
    mkdir = function(path) os.execute("mkdir -p " .. q(path) .. " 2>/dev/null"); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    if cmd:match("^git ") or cmd:match("^cd ") then return (sh(cmd)) end
    return ""
  end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function(s) alerts[#alerts + 1] = tostring(s) end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function(secs, fn)
    local t = { secs = secs, fn = fn, stopped = false }
    function t:stop() self.stopped = true end
    function t:start() return self end
    TIMERS[#TIMERS + 1] = t
    return t
  end,
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
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
-- Tasks are recorders: the test runs a task's shell command for real (the scan, the commit) or
-- plays claude, then fires its exit callback itself.
rawset(hs.task, "new", function(bin, cb, args)
  local t = { bin = bin, cb = cb, args = args or {}, dir = false, running = false, terminated = false }
  function t:start() self.running = true; return self end
  function t:setWorkingDirectory(d) self.dir = d; return true end
  function t:terminate() self.terminated = true; self.running = false; return true end
  function t:isRunning() return self.running end
  TASKS[#TASKS + 1] = t
  return setmetatable(t, { __index = function() return function() return nil end end })
end)
hs.reload = function() end
hs.processInfo = { processID = 10000, bundleID = "org.hammerspoon.Hammerspoon" }
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local ok, err = quiet(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local fx = rawget(_G, "__ccDashboard").fx
check("FX.stepCoach, FX.coachRun, FX.coachApply and FX.COACH_DIR exist", type(fx.stepCoach) == "function"
      and type(fx.coachRun) == "function" and type(fx.coachApply) == "function" and fx.COACH_DIR == CDIR)
if type(fx.stepCoach) ~= "function" or type(fx.coachApply) ~= "function" then finish() end
local OFFSET = 0
fx.now = function() return RNOW + OFFSET end
local CFG = { coach = { enabled = true, day = "mon", maxBudgetUsd = 1 } }
fx._coach.nextCheck = 0

local list = fx._shownItems or {}
local c1
for _, it in ipairs(list) do if it.key == "c1" then c1 = it end end
check("(fixture: the session is on the panel)", c1 ~= nil)
if not c1 then finish() end
-- the stack identity git gives a card on a real Mac (applyStackIdentity)
local function stamp() c1.repoKey, c1.mainRoot, c1.stackName, c1.stackKey = COMMON, REPO, "repo", "repo:" .. COMMON end
stamp()
local function step() stamp(); return quiet(function() fx.stepCoach(list, CFG) end) end
local function tasksWhere(fn) local out = {} for _, t in ipairs(TASKS) do if fn(t) then out[#out + 1] = t end end return out end
local function scans() return tasksWhere(function(t) return t.bin == "/bin/sh" and tostring(t.args[2] or ""):find("tail -c", 1, true) end) end
local function claudes() return tasksWhere(function(t) return tostring(t.args[3] or ""):find("cd '" .. REPO .. "' ", 1, true) end) end
local function runFor(t)   -- run a recorded task's command for real, then hand its exit to Shepherd
  local out, code = sh(t.args[#t.args])
  t.running = false
  quiet(function() t.cb(code, out, "") end)
  return code, out
end
local function answerClaude(t, obj, code)
  local _, outFile = tostring(t.args[3] or ""):match("< '([^']+)' > '([^']+)' 2> '([^']+)'")
  if obj then write(outFile, envelope("Read the sessions.\n" .. json.encode(obj))) end
  t.running = false
  quiet(function() t.cb(code or 0, "", "") end)
end

-- the repo's merge checker is running: the coach waits for it
fx._headless["checker|someone"] = { id = "checker|someone", lane = COMMON, dir = REPO, state = "running", at = RNOW }
step()
check("the weekly run waits while the repo's merge checker runs", #scans() == 0)
check("...and the card says it's waiting", c1.coach ~= nil and (c1.coach.waiting or c1.coach.state == "waiting") and true or false)
fx._headless["checker|someone"] = nil
OFFSET = OFFSET + core.COACH.checkEverySeconds + 1
step()
check("once the checker is done, the weekly run reads the repo's transcripts  (" .. #scans() .. ")", #scans() == 1)
local scan = scans()[1]
check("...the repo's own transcript", scan and tostring(scan.args[2]):find(pdir .. "/s1.jsonl", 1, true) ~= nil)
local onDisk = json.decode(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json") or "{}") or {}
check("...its record is on disk, queued, never a verdict yet", onDisk.state == "queued" and onDisk.verdict == nil and onDisk.trigger == "weekly")
if scan then runFor(scan) end
local C = claudes()
check("the scan done, a headless claude runs in the main checkout  (" .. #C .. ")", #C == 1)
local ct = C[1] or { args = {} }
local cmd = tostring(ct.args[3] or "")
check("...read-only, hooks off, no MCP, a $1 cap", cmd:find("claude -p --model sonnet", 1, true) ~= nil and cmd:find("--max-budget-usd 1 ", 1, true) ~= nil
      and cmd:find("disableAllHooks", 1, true) ~= nil and cmd:find("--strict-mcp-config", 1, true) ~= nil and not cmd:find("--bare", 1, true))
local promptFile = cmd:match("< '([^']+)' >")
local prompt = promptFile and read(promptFile) or ""
check("...its prompt carries the digest and the repo's CLAUDE.md",
      prompt:find("never run make install from a worktree", 1, true) ~= nil and prompt:find("- commit often", 1, true) ~= nil)
local tmo
for _, tm in ipairs(TIMERS) do if tm.secs == 600 then tmo = tm end end
check("...with a retained timeout timer", tmo ~= nil)
answerClaude(ct, { summary = "Two fixes.",
  edits = { { section = "Git", old = "- commit often", new = "- commit often; never git push", why = "Sessions pushed.", evidence = { "Adam: never push" } },
            { section = "Tests", old = "", new = "- run make lint first", why = "Lint failed late.", evidence = { "luacheck red at the gate" } },
            { section = "Git", old = "- nope", new = "- x", why = "stale", evidence = { "e" } } },
  decisions = { { what = "Keep the hooks in bash", why = "They run before any runtime is up." } } })
local drec2 = json.decode(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json") or "{}") or {}
check("the answer lands: proposals, stamped as this week's run", drec2.verdict == "proposals" and drec2.state == "done"
      and tonumber(drec2.lastRunAt) == RNOW + OFFSET and #(drec2.edits or {}) == 3)
check("...with the hash of the CLAUDE.md it read", drec2.claudeHash == core.coachHash(ORIG))
step()
check("the card shows the waiting proposals  (" .. tostring(c1.coach and c1.coach.pending) .. ")", c1.coach and c1.coach.pending == 4)
OFFSET = OFFSET + core.COACH.checkEverySeconds + 1
local before = #scans()
step()
check("not run again the same week", #scans() == before)

-- Apply: refused when the file has uncommitted edits
local rootRec = fx.coachRecord(REPO)
local DIRTY = ORIG .. "- wip\n"
write(REPO .. "/CLAUDE.md", DIRTY)
rootRec.claudeHash = core.coachHash(DIRTY)   -- as if the coach had read it dirty
local head0 = (sh("git -C " .. q(REPO) .. " rev-parse HEAD")):gsub("%s+$", "")
local okA
quiet(function() okA = fx.coachApply(REPO, 1) end)
check("Apply refuses while CLAUDE.md has uncommitted edits", okA == false and read(REPO .. "/CLAUDE.md") == DIRTY
      and (sh("git -C " .. q(REPO) .. " rev-parse HEAD")):gsub("%s+$", "") == head0)
check("...and says why on the edit", rootRec.edits[1].status == "pending" and tostring(rootRec.edits[1].error):find("uncommitted", 1, true) ~= nil)
check("...a refusal a rerun can't fix offers no rerun (uncommitted edits)", core.coachView(rootRec).edits[1].rerun ~= true)
-- Apply: refused when CLAUDE.md moved since the coach read it (committed meanwhile)
local MOVED = ORIG .. "- someone else's line\n"
write(REPO .. "/CLAUDE.md", MOVED); sh("git -C " .. q(REPO) .. " commit -q -am moved")
rootRec.claudeHash = core.coachHash(ORIG)
local head1 = (sh("git -C " .. q(REPO) .. " rev-parse HEAD")):gsub("%s+$", "")
quiet(function() okA = fx.coachApply(REPO, 1) end)
check("Apply refuses when CLAUDE.md changed since the coach read it", okA == false and read(REPO .. "/CLAUDE.md") == MOVED
      and (sh("git -C " .. q(REPO) .. " rev-parse HEAD")):gsub("%s+$", "") == head1)
check("...no commit task was started", #tasksWhere(function(t) return tostring(t.args[2] or ""):find("git commit", 1, true) end) == 0)
-- 2026-09-30: Adam's Apply was refused ("CLAUDE.md changed since the coach read it -- run the coach
-- again") and the edit offered only Apply and Skip: nothing on it ran the coach again.
check("...the refusal's code is on the edit, and its view offers to run the coach again",
      rootRec.edits[1].errorCode == "changed" and core.coachView(rootRec).edits[1].rerun == true)
-- 2026-09-29: a committed CLAUDE.md that is a link (to AGENTS.md): writing it would replace the link
-- with a plain file, so Apply refuses and leaves the link alone
write(REPO .. "/AGENTS.md", ORIG)
sh("rm " .. q(REPO .. "/CLAUDE.md") .. " && ln -s AGENTS.md " .. q(REPO .. "/CLAUDE.md"))
sh("git -C " .. q(REPO) .. " add -A && git -C " .. q(REPO) .. " commit -q -m link")
quiet(function() okA = fx.coachApply(REPO, 1) end)
check("Apply refuses when CLAUDE.md is a link", okA == false and (sh("stat -f '%HT' " .. q(REPO .. "/CLAUDE.md"))):find("Symbolic Link", 1, true) ~= nil
      and read(REPO .. "/AGENTS.md") == ORIG and tostring(rootRec.edits[1].error):find("link", 1, true) ~= nil)
sh("rm " .. q(REPO .. "/CLAUDE.md") .. " " .. q(REPO .. "/AGENTS.md"))
-- back to what the coach read, with someone's staged work beside it
write(REPO .. "/CLAUDE.md", ORIG); sh("git -C " .. q(REPO) .. " add -A && git -C " .. q(REPO) .. " commit -q -m back")
write(REPO .. "/app.lua", "return 2\n"); sh("git -C " .. q(REPO) .. " add app.lua")
quiet(function() okA = fx.coachApply(REPO, 1) end)
local commits = tasksWhere(function(t) return tostring(t.args[2] or ""):find("git commit", 1, true) end)
check("Apply writes CLAUDE.md and commits it  (" .. #commits .. ")", okA == true and #commits == 1
      and read(REPO .. "/CLAUDE.md") == ORIG:gsub("%- commit often", "- commit often; never git push"))
if commits[1] then runFor(commits[1]) end
check("...the commit changes CLAUDE.md alone", (sh("git -C " .. q(REPO) .. " show --name-only --format= HEAD")):gsub("%s+$", "") == "CLAUDE.md")
check("...someone's staged file stays staged", (sh("git -C " .. q(REPO) .. " diff --cached --name-only")):gsub("%s+$", "") == "app.lua")
check("...no attribution in the message", not (sh("git -C " .. q(REPO) .. " log -1 --format=%B")):find("Co-Authored", 1, true))
check("...the edit is applied, with its commit", rootRec.edits[1].status == "applied" and type(rootRec.edits[1].sha) == "string")
-- Shepherd's own commit doesn't count as "changed since": the next edit applies on top
quiet(function() okA = fx.coachApply(REPO, 2) end)
commits = tasksWhere(function(t) return tostring(t.args[2] or ""):find("git commit", 1, true) end)
if commits[2] then runFor(commits[2]) end
check("a second edit applies after the first", okA == true and rootRec.edits[2].status == "applied"
      and (read(REPO .. "/CLAUDE.md") or ""):find("- run make test\n- run make lint first\n", 1, true) ~= nil)
-- an edit whose text is gone: refused, the file untouched
quiet(function() okA = fx.coachApply(REPO, 3) end)
check("an edit whose text isn't in CLAUDE.md is refused", okA == false and rootRec.edits[3].status == "pending"
      and tostring(rootRec.edits[3].error) ~= "nil")
quiet(function() fx.coachSkip(REPO, 3) end)
check("Skip puts it aside", rootRec.edits[3].status == "skipped")
-- a proposed DECISIONS.md entry, added through the On purpose guard
quiet(function() fx.coachDecision(REPO, 1, "add") end)
check("a proposed DECISIONS.md entry is added", rootRec.decisions[1].status == "added"
      and (read(REPO .. "/DECISIONS.md") or ""):find("## Keep the hooks in bash", 1, true) ~= nil)
step()
check("nothing waits any more: the card's chip goes", not (c1.coach and (c1.coach.pending or 0) > 0))
local savedRec = json.decode(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json") or "{}") or {}
check("each outcome is saved", savedRec.edits and savedRec.edits[1].status == "applied" and savedRec.edits[3].status == "skipped")

-- Shepherd's log: a Not yet note lands in the repo's log and the next digest
quiet(function() fx.coachNote(COMMON, { kind = "notyet", id = "notyet|n9|1", branch = "feat/q", note = "split the docs out" }) end)
local lgf = core.parseCoachLog(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".log.json"))
check("a merge note lands in the repo's coach log", #lgf == 1 and lgf[1].note == "split the docs out")

-- a Hammerspoon reload kills a run: the record reads lost, and the run is retried later
write(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json", json.encode({ v = 1, repo = COMMON, root = REPO, name = "repo",
  state = "running", trigger = "weekly", at = RNOW + OFFSET, attempts = 1, lastRunAt = savedRec.lastRunAt, edits = {}, decisions = {} }))
fx._coach.recs = {}
fx._headless["coach|" .. REPO] = nil
OFFSET = OFFSET + core.COACH.checkEverySeconds + 1
before = #scans()
step()
local lostRec = fx.coachRecord(REPO)
check("after a reload the run reads lost, not a verdict", lostRec and lostRec.state == "lost" and lostRec.verdict == nil
      and lostRec.lastRunAt == savedRec.lastRunAt)
check("...and isn't retried at once", #scans() == before)
OFFSET = OFFSET + core.COACH.retryLostSeconds + 1
step()
check("...it's retried later", #scans() == before + 1)
local rescan = scans()[#scans()]
if rescan then runFor(rescan) end
local C2 = claudes()
local p2 = tostring((C2[#C2] or { args = {} }).args[3] or ""):match("< '([^']+)' >")
check("...and the retry's digest carries Shepherd's merge note", p2 and (read(p2) or ""):find("split the docs out", 1, true) ~= nil)
answerClaude(C2[#C2] or { args = {}, cb = function() end }, nil, 1)
local cr = fx.coachRecord(REPO)
check("claude giving no answer is couldn't-run, and counts for the week", cr and cr.verdict == "couldntRun" and cr.lastRunAt == RNOW + OFFSET)

-- the card button runs it on demand, weekly switch or not
alerts = {}
quiet(function() fx.coachRun("c1") end)
check("the card's Coach button starts a run at once", #scans() == before + 2)
local okNo
quiet(function() okNo = fx.coachRun("nobody") end)
check("...a session that's gone: refused", okNo == false)

-- the panel gets the view
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local pushed = false
for _, js in ipairs(jsCalls) do if js:find("ccCoach(", 1, true) then pushed = true end end
check("FX.pushCoach sends the view to the panel (ccCoach)", pushed)

finish()
