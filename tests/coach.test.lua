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
-- 2026-09-30: a suggestion showed the text and the evidence but not what it should change. Adam:
-- "I'd want to be able to know what we expect out of the change." Each edit now says what sessions
-- do today ("before") and what they are expected to do once it is applied ("after").
check("prompt: asks each edit for what sessions do today and what is expected after",
      P:find('"before"', 1, true) ~= nil and P:find('"after"', 1, true) ~= nil)
local pba = core.parseCoachOutput(envelope(json.encode({ summary = "s", decisions = {},
  edits = { edit(1, { before = "Sessions piped awk one-liners\nand the fence refused them.", after = "A session uses Read, Grep or Write inside a worktree." }),
            edit(2, { before = ("x"):rep(900), after = 7 }), edit(3) } })), "")
check("parse: an edit keeps its before and after, each on one line",
      pba.edits[1] and pba.edits[1].before == "Sessions piped awk one-liners and the fence refused them."
      and pba.edits[1].after == "A session uses Read, Grep or Write inside a worktree.")
check("parse: ...capped at 300 characters plus its ellipsis, and a non-string is dropped",
      pba.edits[2] and utf8.len(pba.edits[2].before) == 301 and pba.edits[2].before:sub(-3) == "…" and pba.edits[2].after == nil)
check("parse: an edit without them is still an edit", pba.edits[3] and pba.edits[3].before == nil and pba.edits[3].after == nil)
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

-- ---- a quote that only differs in line wrapping still applies (2026-09-30) ----
-- 2026-09-30: the coach quoted a ChargebackSentinel paragraph as one line; CLAUDE.md has it
-- hard-wrapped over 4 lines, so the exact find missed text that was there, in a file that had not
-- changed, and Apply was refused with "its text isn't in CLAUDE.md any more". The same happened to
-- a wrapped list item in this repo.
do   -- (its own block: the chunk is at Lua's 200-local limit)
local WPARA = "So: restart `deno task dev` before the red run AND before the green run that\n"
  .. "follows it. A browser test you never watched fail, against the code you think\n"
  .. "you changed, has proved nothing - and here it would have shipped a fix that did\n"
  .. "not work.\n"
local WRAPPED = "## Restart the dev server\n\ndev server produced the expected red.\n\n" .. WPARA .. "\n## A branch is not an environment\n\n- one\n"
local QUOTE = "So: restart `deno task dev` before the red run AND before the green run that follows it. A browser test you never"
  .. " watched fail, against the code you think you changed, has proved nothing - and here it would have shipped a fix that did not work."
local WH = core.coachHash(WRAPPED)
local function wdec(file, old, new) return core.coachApplyDecision(file, core.coachHash(file), { section = "Restart the dev server", old = old, new = new }, false) end
local w1 = wdec(WRAPPED, QUOTE, QUOTE .. "\n\nBefore any browser test, check the server first.")
check("rewrap: a paragraph quoted on one line is found in its wrapped lines  (" .. tostring(w1.error) .. ")", w1.ok == true)
check("rewrap: ...the new paragraph lands right after it, and the file's own line breaks stay",
      w1.text == "## Restart the dev server\n\ndev server produced the expected red.\n\n" .. WPARA
        .. "\nBefore any browser test, check the server first.\n\n## A branch is not an environment\n\n- one\n")
local LIST = "## Deploying\n\n- **Finishing a unit here** follows the global protocol, with one extra step:\n"
  .. "  after the ff-merge run `make deploy` from main, then flip the unit's\n  TODO lines.\n- next item\n"
local LQ = "- **Finishing a unit here** follows the global protocol, with one extra step: after the ff-merge run `make deploy` from main, then flip the unit's TODO lines."
local w2 = wdec(LIST, LQ, LQ .. " Never merge before cc-merge.sh approves.")
check("rewrap: a list item with indented continuation lines is found, and added to in place",
      w2.ok == true and w2.text == LIST:gsub("  TODO lines%.\n", "  TODO lines. Never merge before cc-merge.sh approves.\n"))
local w3 = wdec(WRAPPED, QUOTE, "Heads-up first.\n\n" .. QUOTE)
check("rewrap: new text that goes before the quoted text is put before it",
      w3.ok == true and w3.text == WRAPPED:gsub("So: restart", "Heads-up first.\n\nSo: restart"))
local w4 = wdec(WRAPPED, QUOTE, "So: always restart the dev server first.")
check("rewrap: a rewrite replaces exactly the wrapped lines",
      w4.ok == true and w4.text == "## Restart the dev server\n\ndev server produced the expected red.\n\nSo: always restart the dev server first.\n\n## A branch is not an environment\n\n- one\n")
check("rewrap: wrapped text that is there twice is ambiguous", wdec(WRAPPED .. "\n" .. WPARA, QUOTE, QUOTE .. " More.").error == "ambiguous")
local w6 = wdec(WRAPPED .. "\n" .. QUOTE .. "\n", QUOTE, QUOTE .. " More.")
check("rewrap: an exact match wins over a re-wrapped twin", w6.ok == true and w6.text == WRAPPED .. "\n" .. QUOTE .. " More.\n")
check("rewrap: text that is there in no wrapping is still not found", wdec(WRAPPED, "So: never restart anything at all.", "x").error == "not-found")
local CR = WRAPPED:gsub("\n", "\r\n")
local w8 = wdec(CR, QUOTE, QUOTE .. "\n\nCheck the server first.")
check("rewrap: a CRLF file is matched by a quote with plain newlines, and gets no bare newline",
      w8.ok == true and w8.text:find("not work.\r\n\r\nCheck the server first.\r\n\r\n## A branch", 1, true) ~= nil and not (w8.text:gsub("\r\n", "")):find("\n", 1, true))
check("rewrap: blanks around the quote that the file doesn't have don't matter", wdec(WRAPPED, "  " .. QUOTE .. " \n", QUOTE .. " More.").ok == true)
check("rewrap: a quote of nothing but blanks is not found", wdec(WRAPPED, "  \n\t ", "x").error == "not-found")
local MB = "## S\n\nCafé — naïve text\nthat wraps here\nend\n"
local w11 = wdec(MB, "Café — naïve text that wraps here", "Café — naïve text that wraps here Done.")
check("rewrap: characters of several bytes next to the span survive byte for byte", w11.ok == true and w11.text == "## S\n\nCafé — naïve text\nthat wraps here Done.\nend\n")
check("rewrap: a no-break space is text, not a blank", wdec("## S\n\na\u{00A0}b c\n", "a b c", "a b c d").error == "not-found")
local FENCE = "## S\n\n```\nfoo   bar\nbaz\n```\n\nafter\n"
check("rewrap: text inside a code fence is never matched loosely (its spacing is the code)",
      wdec(FENCE, "foo bar baz", "qux").error == "not-found" and wdec(FENCE, "foo bar baz", "foo bar baz quux").error == "not-found")
check("rewrap: an edit that would only re-wrap or re-space the text is refused", wdec(WRAPPED, QUOTE, (QUOTE:gsub("AND before", "AND\nbefore"))).error == "no-change")
check("rewrap: a quoted block's markers are text, so a half-match is not found", wdec("## S\n\n> line one\n> line two\n", "line one line two", "x").error == "not-found")
check("rewrap: the file's hash still guards it", core.coachApplyDecision(WRAPPED .. "- more\n", WH, { section = "S", old = QUOTE, new = QUOTE .. " x" }, false).error == "changed")
check("rewrap: the refusal no longer says the text was removed, and the new one has words",
      not core.coachRefusal("not-found"):find("any more", 1, true) and core.coachRefusal("not-found"):find("quoted", 1, true) ~= nil
      and not core.coachRefusal("no-change"):find("refused:", 1, true))
local lrec = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
  at = 100, doneAt = 200, lastRunAt = 200, claudeHash = H,
  edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "pending",
              error = "its text isn't in CLAUDE.md any more", errorCode = "not-found" },
            { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, status = "pending",
              error = "the commit failed: a hook said no -- CLAUDE.md is back as it was", errorCode = "commit" } }, decisions = {} }))
local lv = core.coachView(lrec) or { edits = { {}, {} } }
check("rewrap: a refusal saved with the old words is shown with today's", lv.edits[1].error == core.coachRefusal("not-found"))
check("rewrap: ...a refusal with words of its own keeps them", tostring(lv.edits[2].error):find("a hook said no", 1, true) ~= nil)
check("prompt: the quoted text is to be copied with its line breaks", P:lower():find("line breaks", 1, true) ~= nil)
end

-- ---- a suggestion that can't be placed can still be added (2026-09-30) ----
-- 2026-09-30: an addition whose quoted anchor isn't in CLAUDE.md (the coach paraphrased it) could
-- only be skipped. Add to the section anyway writes only its new part, at the end of its section --
-- additions only (Adam's call): a rewrite needs its anchor, so it gets "Run the coach again".
do
local SEC = "# P\n\n## Git\n\n- commit often\n\n## Tests\n\n- run make test\n"
local SH = core.coachHash(SEC)
local PARA = "- commit little and often"
local function any(old, new, section, file, dirty)
  file = file or SEC
  return core.coachApplyDecision(file, core.coachHash(file), { section = section or "Git", old = old, new = new }, dirty or false, true)
end
check("addBody: the rest of an edit that continues its quote", core.coachAddBody and core.coachAddBody({ section = "Git", old = "a b", new = "a b\nc d" }) == "c d")
check("addBody: ...or the head of one that ends with it", core.coachAddBody and core.coachAddBody({ section = "Git", old = "a b", new = "z y\n\na b" }) == "z y")
check("addBody: a rewrite has none", core.coachAddBody and core.coachAddBody({ section = "Git", old = "a b", new = "a c" }) == nil)
check("addBody: a quote continued mid-word is a rewrite, not an addition", core.coachAddBody and core.coachAddBody({ section = "Git", old = "a b", new = "a bc d" }) == nil)
check("addBody: no section, nowhere to add it", core.coachAddBody and core.coachAddBody({ section = "", old = "a b", new = "a b c" }) == nil)
check("addBody: a plain add needs no anyway", core.coachAddBody and core.coachAddBody({ section = "Git", old = "", new = "c" }) == nil)
check("anyway: without it the paraphrased anchor is still refused",
      core.coachApplyDecision(SEC, SH, { section = "Git", old = PARA, new = PARA .. "\n- never git push" }, false).error == "not-found")
local a1 = any(PARA, PARA .. "\n- never git push from a unit")
check("anyway: only the new part goes in, at the end of its section",
      a1.ok == true and a1.text == "# P\n\n## Git\n\n- commit often\n- never git push from a unit\n\n## Tests\n\n- run make test\n")
check("anyway: ...and it says what it wrote, in an existing section", a1.added == "- never git push from a unit" and not a1.newSection)
local a2 = any(PARA, "Before anything else, pull.\n\n" .. PARA)
check("anyway: a head addition goes in as a paragraph at the end of its section",
      a2.ok == true and a2.text == "# P\n\n## Git\n\n- commit often\n\nBefore anything else, pull.\n\n## Tests\n\n- run make test\n")
local a3 = any("- commit often", "- commit often\n- never git push")
check("anyway: when the quote IS there, the edit applies in place as usual",
      a3.ok == true and a3.added == nil and a3.text == "# P\n\n## Git\n\n- commit often\n- never git push\n\n## Tests\n\n- run make test\n")
check("anyway: the file's hash still guards it",
      core.coachApplyDecision(SEC .. "- more\n", SH, { section = "Git", old = PARA, new = PARA .. "\n- x y" }, false, true).error == "changed")
check("anyway: ...and uncommitted edits", any(PARA, PARA .. "\n- x y", nil, nil, true).error == "dirty")
check("anyway: a rewrite is never added", any(PARA, "- commit rarely").error == "not-found")
check("anyway: no section, not added", any(PARA, PARA .. "\n- x y", "").error == "not-found")
check("anyway: a new part already in CLAUDE.md is refused, with words", any(PARA, PARA .. "\n- run make test").error == "already-there"
      and not core.coachRefusal("already-there"):find("refused:", 1, true))
local a5 = any("- deploy from the main branch", "- deploy from the main branch\n- then reload", "Deploying")
check("anyway: a section that isn't there is made at the end", a5.ok == true and a5.newSection == true
      and a5.text == SEC .. "\n## Deploying\n\n- then reload\n")
local TW = "## Git\n\n- x\n- x\n"
local a6 = any("- x", "- x\n- y", "Git", TW)
check("anyway: a quote that is there twice gets its new part at the end of the section", a6.ok == true and a6.text == "## Git\n\n- x\n- x\n- y\n")
local CRF = SEC:gsub("\n", "\r\n")
local a7 = any(PARA, PARA .. "\n- one\n- two", "Git", CRF)
check("anyway: the new part takes the file's line ending", a7.ok == true and a7.text == (("# P\n\n## Git\n\n- commit often\n- one\n- two\n\n## Tests\n\n- run make test\n"):gsub("\n", "\r\n")))
-- the overlay's buttons come from the view
local function ed(old, new, code) return { section = "Git", old = old, new = new, why = "w", evidence = { "e" }, status = "pending",
  error = code and core.coachRefusal(code) or nil, errorCode = code } end
local function viewOf(edits)   -- a record keeps at most C.maxEdits (5) edits, so the rows come in two records
  return core.coachView(core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
    at = 100, doneAt = 200, lastRunAt = 200, claudeHash = SH, edits = edits, decisions = {} }))) or { edits = {} }
end
local av1 = viewOf({ ed(PARA, PARA .. "\n- x y", "not-found"), ed(PARA, PARA .. "\n- x y", "ambiguous"), ed(PARA, "- commit rarely", "not-found"),
                     ed(PARA, PARA .. "\n- x y", "changed") })
local av2 = viewOf({ ed(PARA, PARA .. "\n- x y", "dirty"), ed(PARA, PARA .. "\n- run make test", "already-there"), ed(PARA, PARA .. "\n- x y") })
local function flags(i)
  local x = (i <= 4 and av1.edits[i] or av2.edits[i - 4])
  if not x then return "missing" end
  return (x.addAnyway and "A" or "-") .. (x.rerun and "R" or "-") .. tostring(x.code)
end
check("view: an addition not found offers Add anyway and a fresh run  (" .. flags(1) .. ")", flags(1) == "ARnot-found")
check("view: ...so does one quoted twice  (" .. flags(2) .. ")", flags(2) == "ARambiguous")
check("view: a rewrite not found offers only a fresh run  (" .. flags(3) .. ")", flags(3) == "-Rnot-found")
check("view: a file that changed offers only a fresh run  (" .. flags(4) .. ")", flags(4) == "-Rchanged")
check("view: uncommitted edits offer neither  (" .. flags(5) .. ")", flags(5) == "--dirty")
check("view: a new part already there offers neither  (" .. flags(6) .. ")", flags(6) == "--already-there")
check("view: an edit never refused offers neither  (" .. flags(7) .. ")", flags(7) == "--nil")
end

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
local _, bodyBA = core.coachCommitMessage({ section = "Git", why = "Sessions pushed on their own.",
  before = "A session ran git push when its work was green.", after = "A session asks before it pushes." })
check("commit message: says what was happening and what is expected after",
      bodyBA == "Sessions pushed on their own.\n\nBefore: A session ran git push when its work was green.\nAfter: A session asks before it pushes.")
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

-- ---- the history of applied edits, and Undo (2026-09-30) ----
-- 2026-09-30: Adam asked to "track the changes we accept so we know the state before and after and
-- if I ever see something go bad we can restore back". An Apply was already its own commit, but the
-- next coach run replaced the list, so Shepherd kept no record of it and had no way back.
local hist = {}
hist = core.coachHistoryAdd(hist, { sha = "aaa1111", at = 100, section = "Git", why = "w1", before = "b1", after = "a1", old = "- x", new = "- y" })
hist = core.coachHistoryAdd(hist, { sha = "bbb2222", at = 200, section = "Tests", why = "w2", old = "", new = "- lint first" })
hist = core.coachHistoryAdd(hist, { sha = "aaa1111", at = 300, section = "Git", why = "again", old = "- x", new = "- y" })
check("history: one entry per commit, in the order they were applied", #hist == 2 and hist[1].sha == "aaa1111" and hist[1].why == "w1" and hist[2].sha == "bbb2222")
check("history: an entry without a commit is not history", #core.coachHistoryAdd(hist, { at = 1, section = "Git", why = "w", old = "a", new = "b" }) == 2
      and #core.coachHistoryAdd(hist, { sha = "not-a-sha", at = 1, section = "Git", why = "w", old = "a", new = "b" }) == 2)
local many = {}
for i = 1, core.COACH.historyMax + 3 do many = core.coachHistoryAdd(many, { sha = string.format("%07x", i), at = i, section = "S", why = "w", old = "a", new = "b" .. i }) end
check("history: capped at COACH.historyMax, newest kept", #many == core.COACH.historyMax and many[#many].sha == string.format("%07x", core.COACH.historyMax + 3))
check("history: round-trips through its file, and torn JSON is an empty history",
      #core.parseCoachHistory(json.encode(hist)) == 2 and core.parseCoachHistory(json.encode(hist))[1].before == "b1"
      and #core.parseCoachHistory("{") == 0 and #core.parseCoachHistory(json.encode({ { sha = "zz", why = "w" } })) == 0)
local hv = core.coachHistoryView(hist)
check("history view: newest first, each with its place in the list, its commit and what it changed",
      #hv == 2 and hv[1].sha == "bbb2222" and hv[1].i == 2 and hv[2].i == 1 and hv[2].old == "- x" and hv[2].new == "- y"
      and hv[2].before == "b1" and hv[2].after == "a1" and hv[2].undone ~= true)
hist[1].undone = { sha = "ccc3333", at = 400 }
check("history view: an undone entry says so, with the commit that undid it", core.coachHistoryView(hist)[2].undone == true
      and core.coachHistoryView(hist)[2].undoSha == "ccc3333")
local usub, ubody = core.coachUndoMessage({ sha = "aaa1111aaa", section = "Git", why = "Sessions pushed on their own." })
check("undo message: plain, names the commit it undoes, no attribution", usub == "CLAUDE.md: undo Git"
      and ubody == "Undoes aaa1111: Sessions pushed on their own." and not (usub .. ubody):find("Co%-Authored"))
-- the change a commit made, as one block of whole lines, and its exact inverse
local BEFORE = "# Repo\n\n## Git\n\n- commit often\n\n## Traps\n\n- trap one\n\n## Deploy\n\n- from main\n"
local A1 = BEFORE:gsub("%- trap one\n", "- trap one\n- trap two\n")            -- the edit: a bullet added to a section
local ch = core.coachChange(BEFORE, A1)
check("change: an added bullet is its whole line, nothing removed", ch.removed == "" and ch.added == "- trap two\n")
local A2 = A1:gsub("%- trap two\n", "- trap two\n- trap three\n")              -- later: another bullet right after it
local u1 = core.coachUndoDecision(A2, ch)
check("undo: takes the bullet out even with a later one added right after it",
      u1.ok == true and u1.text == BEFORE:gsub("%- trap one\n", "- trap one\n- trap three\n"))
local R1 = BEFORE:gsub("%- commit often", "- commit often; never git push")     -- the edit: a line reworded
local chR = core.coachChange(BEFORE, R1)
check("change: a reworded line is the whole old line and the whole new one",
      chR.removed == "- commit often\n" and chR.added == "- commit often; never git push\n")
check("undo: puts the old line back, keeping a later change elsewhere",
      core.coachUndoDecision(R1:gsub("%- from main", "- from main, after the suite"), chR).text == BEFORE:gsub("%- from main", "- from main, after the suite"))
check("undo: refused when its text is no longer in CLAUDE.md", core.coachUndoDecision(BEFORE, ch).ok == false and core.coachUndoDecision(BEFORE, ch).error == "undo-conflict")
check("undo: refused when its text is there twice", core.coachUndoDecision(A1 .. "- trap two\n", ch).error == "undo-conflict")
check("undo: text inside a longer line is not its line", core.coachUndoDecision(BEFORE .. "x- trap two\n", ch).error == "undo-conflict")
local D1 = BEFORE:gsub("%- trap one\n", "")                                     -- the edit: a line deleted
local chD = core.coachChange(BEFORE, D1)
check("change: a deleted line is located by the lines around it", chD.added ~= "" and chD.removed:find("- trap one\n", 1, true) ~= nil)
check("undo: puts a deleted line back", core.coachUndoDecision(D1, chD).text == BEFORE)
local chN = core.coachChange(nil, "# Repo\n\n- first rule\n")                  -- the edit created CLAUDE.md
check("undo: a CLAUDE.md the edit created is removed again", core.coachUndoDecision("# Repo\n\n- first rule\n", chN).delete == true)
check("undo: ...but only what the edit wrote is taken out once more has been added",
      core.coachUndoDecision("# Repo\n\n- first rule\n- later rule\n", chN).error == "undo-conflict")
check("undo: no change to undo is refused", core.coachUndoDecision(BEFORE, core.coachChange(BEFORE, BEFORE)).error == "undo-conflict")
check("undo: every refusal has words", core.coachRefusal("undo-conflict"):find("git revert", 1, true) ~= nil
      and core.coachRefusal("undo-gone"):find("refused:", 1, true) == nil)
-- reading a commit's two versions of CLAUDE.md from git
local U = T .. "/urepo"
sh("git init -q " .. q(U) .. " && git -C " .. q(U) .. " config user.email t@example.com && git -C " .. q(U)
   .. " config user.name Tester && git -C " .. q(U) .. " config commit.gpgsign false")
write(U .. "/CLAUDE.md", BEFORE)
sh("git -C " .. q(U) .. " add -A && git -C " .. q(U) .. " commit -q -m init")
write(U .. "/CLAUDE.md", A1)
local usha = (sh(core.coachCommitCmd(U, "CLAUDE.md: Traps", "why", false))):match("(%x+)%s*$")
check("git: a commit's CLAUDE.md before and after it are read back exactly",
      sh(core.coachShowCmd(U, usha, true)) == BEFORE and sh(core.coachShowCmd(U, usha, false)) == A1)
local _, goneCode = sh(core.coachShowCmd(U, "0123456789abcdef0123456789abcdef01234567", false))
check("git: a commit that isn't in the repo any more fails the read", goneCode ~= 0)

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

local barec = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
  at = 100, doneAt = 200, lastRunAt = 200, claudeHash = H,
  edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "pending", before = "did x", after = "does y" } },
  decisions = {} }))
local bav = core.coachView(barec) or { edits = {} }
check("record and view: an edit's before and after survive a reload and reach the overlay",
      barec and barec.edits[1].before == "did x" and bav.edits[1] and bav.edits[1].before == "did x" and bav.edits[1].after == "does y")

-- 2026-09-30: the overlay of a running coach showed one still line for minutes. The view now says
-- when the run started and when it gives up, so the panel can count.
local rv = core.coachView({ root = "/r/repo", state = "running", at = 100, edits = {}, decisions = {} }, { busy = true, timeoutSeconds = 600 })
check("view: a running coach carries its start and its time limit", rv and rv.state == "running" and rv.at == 100 and rv.timeoutSeconds == 600)
check("view: ...no limit known, none claimed", core.coachView({ root = "/r/repo", state = "running", at = 100, edits = {}, decisions = {} }, { busy = true }).timeoutSeconds == nil)

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

-- ---- the lessons ledger (2026-10-02, mining round 2 unit B1) ----
-- 2026-10-02: a skipped suggestion was gone at the next run -- FX.coachStart rebuilt the record and
-- kept only applied edits (the history) -- so nothing told the coach Adam had already said no, and
-- it could propose the same edit again, with no word on what had changed.
do
  local fns = { "coachLessonHash", "coachLessonRecord", "coachLessonsSeen", "coachLessonFold", "parseCoachLessons", "coachSkipArgs" }
  local have = true
  for _, n in ipairs(fns) do if type(core[n]) ~= "function" then have = false; print("       missing core." .. n) end end
  check("core has the lessons ledger's functions", have)
  if have then
    local E1 = { section = "## Git", old = "- commit often", new = "- commit often; never git push", why = "Units pushed on their own.", evidence = { "e" } }
    local L, id = core.coachLessonRecord({}, E1, "applied", { at = 100, run = 90 })
    check("ledger: an Apply records one lesson: an id, its section, a text hash, the verdict, why, when and the run",
          #L == 1 and type(id) == "string" and id:match("^L%x+") ~= nil and L[1].id == id and L[1].section == "Git"
          and L[1].textHash == core.coachLessonHash(E1) and L[1].verdict == "applied" and L[1].why == "Units pushed on their own."
          and L[1].at == 100 and type(L[1].runs) == "table" and #L[1].runs == 1 and L[1].runs[1] == 90)
    check("ledger: ...and what the edit says, on one line, so the coach can recognise it", tostring(L[1].text):find("never git push", 1, true) ~= nil)
    local L2, id2 = core.coachLessonRecord(L, E1, "undone", { at = 200, run = 90 })
    check("ledger: an Undo of that edit updates its lesson, never a second one",
          #L2 == 1 and id2 == id and L2[1].verdict == "undone" and L2[1].at == 200 and #L2[1].runs == 1)
    check("ledger: ...leaving the list it was given as it was", L[1].verdict == "applied" and L[1].at == 100)
    local E2 = { section = "Tests", old = "", new = "- run make lint first", why = "Lint failed late.", evidence = { "e" } }
    local L3, id3 = core.coachLessonRecord(L2, E2, "skipped", { at = 300, run = 250, reason = "  not\n  now  " })
    check("ledger: a Skip records Adam's reason, on one line", #L3 == 2 and id3 ~= id and L3[2].id == id3
          and L3[2].verdict == "skipped" and L3[2].reason == "not now")
    check("ledger: a bad verdict records nothing", #core.coachLessonRecord(L3, E2, "maybe", { at = 1 }) == 2)
    -- a reworded proposal that cites the lesson updates that lesson, adding its run
    local E2b = { section = "Tests", old = "", new = "- lint before the suite", why = "Lint still fails late.", evidence = { "e" }, lesson = id3 }
    local L4, id4 = core.coachLessonRecord(L3, E2b, "applied", { at = 400, run = 380 })
    check("ledger: an edit citing a lesson updates it, reworded or not, adding its run",
          #L4 == 2 and id4 == id3 and L4[2].verdict == "applied" and #L4[2].runs == 2 and L4[2].why == "Lint still fails late.")
    check("ledger: ...an Apply carries no skip reason", L4[2].reason == nil)
    -- a run's proposals: a cited lesson gains the run; a made-up id is dropped
    local edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, lesson = id },
                    { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, lesson = "Lfffffe" },
                    { section = "Git", old = "e", new = "f", why = "w", evidence = { "e" } } }
    local L5 = core.coachLessonsSeen(L4, edits, 500)
    local l5 = {}
    for _, x in ipairs(L5) do l5[x.id] = x end
    check("seen: a proposal citing a lesson adds this run to it  (" .. #(l5[id] and l5[id].runs or {}) .. ")",
          l5[id] and #l5[id].runs == 2 and l5[id].runs[2] == 500)
    check("seen: a citation of a lesson the ledger doesn't have is dropped", edits[2].lesson == nil and edits[1].lesson == id)
    local L6 = core.coachLessonsSeen(L5, edits, 500)
    local l6 = {}
    for _, x in ipairs(L6) do l6[x.id] = x end
    check("seen: one run counts once", l6[id] and #l6[id].runs == 2)
    -- the fold FX.coachStart runs before it replaces the record
    local orec = { at = 600, doneAt = 650, edits = {
      { section = "Docs", old = "- x", new = "- y", why = "wx", evidence = { "e" }, status = "skipped", at = 640, reason = "wrong section" },
      { section = "Docs", old = "- p", new = "- q", why = "wp", evidence = { "e" }, status = "pending" },
      { section = "Docs", old = "- m", new = "- n", why = "wm", evidence = { "e" }, status = "applied", sha = "abc1234", at = 645 } } }
    local F1, ch1 = core.coachLessonFold(L6, orec, {})
    local byWhy = {}
    for _, x in ipairs(F1) do byWhy[x.why] = x end
    check("fold: a skipped edit goes into the ledger, with Adam's reason and its run",
          byWhy.wx and byWhy.wx.verdict == "skipped" and byWhy.wx.reason == "wrong section" and byWhy.wx.at == 640
          and byWhy.wx.runs[1] == 600 and ch1 == true)
    check("fold: a pending edit does not", byWhy.wp == nil)
    check("fold: an applied edit the ledger lacks goes in too", byWhy.wm and byWhy.wm.verdict == "applied")
    local F2, ch2 = core.coachLessonFold(F1, orec, {})
    check("fold: folding the same record again changes nothing", #F2 == #F1 and ch2 == false)
    -- a lesson cited in the record, then skipped there: the newer skip wins
    local crec = { at = 700, edits = { { section = "Tests", old = "", new = "- lint now", why = "again", evidence = { "e" }, status = "skipped",
                                         at = 710, lesson = id3, reason = "still not now" } } }
    local F3 = core.coachLessonFold(F2, crec, {})
    local f3 = {}
    for _, x in ipairs(F3) do f3[x.id] = x end
    check("fold: a skip of a cited lesson, newer than its verdict, updates it",
          #F3 == #F2 and f3[id3] and f3[id3].verdict == "skipped" and f3[id3].reason == "still not now" and #f3[id3].runs == 3)
    -- edits applied before the ledger existed: seeded from the history, an undone one as undone
    local hist0 = { { sha = "aaa1111", at = 50, section = "Old", why = "old why", old = "", new = "- old rule" },
                    { sha = "bbb2222", at = 60, section = "Old", why = "gone why", old = "", new = "- gone rule", undone = { sha = "ccc3333", at = 70 } } }
    local S = core.coachLessonFold({}, nil, hist0)
    local sw = {}
    for _, x in ipairs(S) do sw[x.why] = x end
    check("fold: an applied edit from before the ledger is seeded from the history", sw["old why"] and sw["old why"].verdict == "applied" and sw["old why"].at == 50)
    check("fold: ...and an undone one reads undone", sw["gone why"] and sw["gone why"].verdict == "undone" and sw["gone why"].at == 70)
    -- capped, newest kept; round-trips through its file
    local many = {}
    for i = 1, core.COACH.lessonsMax + 4 do
      many = core.coachLessonRecord(many, { section = "S", old = "", new = "- rule " .. i, why = "w" .. i, evidence = { "e" } }, "skipped", { at = i, run = i })
    end
    check("ledger: capped at COACH.lessonsMax, the newest kept", #many == core.COACH.lessonsMax and many[#many].why == "w" .. (core.COACH.lessonsMax + 4))
    local back = core.parseCoachLessons(json.encode(F3))
    check("ledger: round-trips through its file", #back == #F3 and back[1].id == F3[1].id and back[1].textHash == F3[1].textHash)
    check("ledger: torn JSON, and an entry with a bad id or verdict, are dropped",
          #core.parseCoachLessons("{") == 0
          and #core.parseCoachLessons(json.encode({ { id = "rm -rf", verdict = "applied", section = "S", textHash = "00000000", why = "w", at = 1, runs = {} },
                                                    { id = "L0a0b0c", verdict = "meh", section = "S", textHash = "00000000", why = "w", at = 1, runs = {} } })) == 0)
    -- the history keeps the lesson an applied edit was, so Undo finds it
    local hh = core.coachHistoryAdd({}, { sha = "ddd4444", at = 1, section = "S", why = "w", old = "a", new = "b", lesson = id })
    check("history: an entry keeps its lesson id, through its file", hh[1] and hh[1].lesson == id and core.parseCoachHistory(json.encode(hh))[1].lesson == id)
    -- the model's answer: an edit may cite a lesson and say what is new
    local po = core.parseCoachOutput(envelope(json.encode({ summary = "s", decisions = {}, edits = {
      edit(1, { lesson = id3, whatsNew = "two more\nlate-lint failures this week" }), edit(2, { lesson = "rm -rf /" }) } })), "")
    check("output: an edit keeps the lesson it cites and what is new, on one line",
          po.edits[1] and po.edits[1].lesson == id3 and po.edits[1].whatsNew == "two more late-lint failures this week")
    check("output: a lesson id that isn't one is dropped", po.edits[2] and po.edits[2].lesson == nil)
    local rr = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
      at = 100, doneAt = 200, lastRunAt = 200, decisions = {},
      edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "skipped", lesson = id3, whatsNew = "new",
                  reason = "not now", at = 150 } } }))
    check("record: an edit's lesson, what is new and Adam's skip reason survive a reload",
          rr and rr.edits[1] and rr.edits[1].lesson == id3 and rr.edits[1].whatsNew == "new" and rr.edits[1].reason == "not now" and rr.edits[1].at == 150)
    -- the prompt
    local PL = core.coachPrompt("digest", "# Repo\n", nil, { name = "repo", lessons = F3 })
    local lb = PL:match("<lessons>\n(.-)\n</lessons>") or ""   -- the block itself, not the rule that names it
    check("prompt: carries a <lessons> block with each lesson's id and verdict", lb:find(id, 1, true) ~= nil and lb:find(id3, 1, true) ~= nil
          and lb:find("applied", 1, true) ~= nil and lb:find("skipped", 1, true) ~= nil)
    check("prompt: ...and Adam's reason for a skip", lb:find("still not now", 1, true) ~= nil)
    check("prompt: an applied lesson is never proposed again", PL:lower():find("applied", 1, true) ~= nil and PL:find("never propose it again", 1, true) ~= nil)
    check("prompt: a skipped or undone one only with new evidence, saying what is new", PL:find("new evidence", 1, true) ~= nil and PL:find('"whatsNew"', 1, true) ~= nil)
    check("prompt: an edit that repeats a lesson cites its id", PL:find('"lesson"', 1, true) ~= nil)
    local big = {}
    for i = 1, core.COACH.lessonsMax do
      big = core.coachLessonRecord(big, { section = "S", old = "", new = "- rule " .. i .. (" pad"):rep(30), why = ("why " .. i .. " "):rep(20), evidence = { "e" } },
                                   "skipped", { at = i, run = i, reason = ("r" .. i .. " "):rep(20) })
    end
    local PB = core.coachPrompt("digest", "# Repo\n", nil, { lessons = big })
    local bb = PB:match("<lessons>\n(.-)\n</lessons>") or ""
    check("prompt: <lessons> is capped at COACH.lessonsBytes  (" .. #bb .. ")", #bb > 0 and #bb <= core.COACH.lessonsBytes + 200)
    check("prompt: ...newest first", bb:find("why " .. core.COACH.lessonsMax .. " ", 1, true) ~= nil and bb:find("why 1 ", 1, true) == nil)
    check("prompt: no lessons, no block", not core.coachPrompt("digest", "# Repo\n", nil, {}):find("<lessons>", 1, true))
    -- the overlay's view of an edit that repeats a lesson
    local vrec = { root = "/r", state = "done", verdict = "proposals", decisions = {},
      edits = { { section = "Tests", old = "", new = "- x", why = "w", evidence = { "e" }, status = "pending", lesson = id3, whatsNew = "two more" },
                { section = "Tests", old = "", new = "- y", why = "w", evidence = { "e" }, status = "pending" } } }
    local vv = core.coachView(vrec, {}, F3)
    check("view: an edit repeating a lesson carries how many runs proposed it, the lesson's verdict and Adam's reason",
          vv and vv.edits[1].seen == 3 and vv.edits[1].was == "skipped" and vv.edits[1].reason == "still not now" and vv.edits[1].whatsNew == "two more")
    check("view: an edit with no lesson carries none", vv and vv.edits[2].seen == nil and vv.edits[2].was == nil)
    check("view: ...nor one whose lesson isn't in the ledger", core.coachView(vrec, {}, {}).edits[1].seen == nil)
    -- Skip's click: the edit's number, then an optional one-line reason
    local sn, sw2 = core.coachSkipArgs("3\n  too   broad \n")
    check("skip args: the number and a one-line reason", sn == "3" and sw2 == "too broad")
    local sn2, sw3 = core.coachSkipArgs("2")
    check("skip args: no reason is none", sn2 == "2" and sw3 == nil)
    check("skip args: a reason is capped", utf8.len((select(2, core.coachSkipArgs("1\n" .. ("x"):rep(900))))) <= 201)
  end
end

-- ---- did the edit work? (2026-10-03, mining round 2 unit B2) ----
-- 2026-10-03: an applied edit said what sessions did before it and what they were expected to do
-- after, and nothing ever looked again: no run said whether the sessions since behaved as expected.
-- Each run now judges the applied edits that at least COACH.judgeSessions digest sessions postdate
-- (working, still seen, or no data); fewer than that is "no data yet", decided in Lua, never by the
-- model. Sharpen runs the coach on one applied edit alone, for a better wording of it.
do
  local fns = { "coachEditsToJudge", "coachApplyChecks" }
  local have = true
  for _, n in ipairs(fns) do if type(core[n]) ~= "function" then have = false; print("       missing core." .. n) end end
  check("core has the edit-outcome functions", have and type(core.COACH.judgeSessions) == "number" and core.COACH.judgeSessions >= 1)
  if have then
    local K = core.COACH.judgeSessions
    -- the digest says when each session it holds last ran, newest first
    check("digest: carries each held session's time (ats), newest first",
          type(D.ats) == "table" and #D.ats == 2 and D.ats[1] == F2.at and D.ats[2] == F.at)
    check("digest: ...a session cut out of it is not counted", type(capped.ats) == "table" and #capped.ats == capped.sessions)
    -- an applied history: an old edit (judgeable), one applied after every session (too early), an undone one
    local T0 = core.isoToEpoch("2026-09-20T00:00:00.000Z")
    local ATS = {}
    for i = 1, K + 1 do ATS[i] = T0 + 1000 * (K + 2 - i) end   -- K+1 sessions after T0, newest first
    local HIST = {
      { sha = "aaa1111aaaa", at = T0, section = "Git", why = "Units pushed alone.", old = "", new = "- never push from a unit",
        before = "A unit ran git push when green.", after = "A unit asks Adam before it pushes." },
      { sha = "bbb2222bbbb", at = T0 + 1000 * (K + 1) + 1, section = "Tests", why = "Lint late.", old = "", new = "- lint first",
        before = "Lint ran last.", after = "Lint runs first." },
      { sha = "ccc3333cccc", at = T0, section = "Docs", why = "Gone.", old = "", new = "- gone", undone = { sha = "ddd4444dddd", at = T0 + 5 } },
    }
    local J = core.coachEditsToJudge(HIST, ATS)
    local byJ = {}
    for _, x in ipairs(J) do byJ[x.sha] = x end
    check("judge: an edit with K or more sessions since is judged  (" .. tostring(byJ.aaa1111aaaa and byJ.aaa1111aaaa.since) .. ")",
          byJ.aaa1111aaaa and byJ.aaa1111aaaa.since == K + 1 and byJ.aaa1111aaaa.judge == true and byJ.aaa1111aaaa.asked == true)
    check("judge: an edit no session postdates is not, and says how many there are",
          byJ.bbb2222bbbb and byJ.bbb2222bbbb.since == 0 and byJ.bbb2222bbbb.judge == false and not byJ.bbb2222bbbb.asked)
    check("judge: an undone edit is never judged", byJ.ccc3333cccc == nil)
    local ONE = { HIST[1] }
    local short = {}
    for i = 1, K - 1 do short[i] = ATS[i] end
    check("judge: one session short of K is not enough", core.coachEditsToJudge(ONE, short)[1].judge == false
          and core.coachEditsToJudge(ONE, short)[1].since == K - 1)
    check("judge: a session at the very second it was applied doesn't postdate it", core.coachEditsToJudge(ONE, { T0, T0, T0 })[1].since == 0)
    -- the prompt asks about the judgeable edits only, with what each was expected to change
    local DJ = { text = "### Session 1 of 1\n", ats = ATS, sessions = #ATS }
    local PJ = core.coachPrompt(DJ, "# Repo\n\n## Git\n\n- never push from a unit\n", nil, { name = "repo", history = HIST })
    local ab = PJ:match("<applied>\n(.-)\n</applied>") or ""
    check("prompt: an <applied> block names a judgeable edit by its commit", ab:find("aaa1111", 1, true) ~= nil)
    check("prompt: ...with what sessions did before it and what was expected after",
          ab:find("A unit ran git push when green.", 1, true) ~= nil and ab:find("A unit asks Adam before it pushes.", 1, true) ~= nil)
    check("prompt: ...and never an edit too recent to judge, or an undone one",
          not ab:find("bbb2222", 1, true) and not ab:find("ccc3333", 1, true))
    check("prompt: asks for a check per edit inside the same JSON, as working, still-seen or no-data",
          PJ:find('"checks"', 1, true) ~= nil and PJ:find("working", 1, true) ~= nil and PJ:find("still-seen", 1, true) ~= nil
          and PJ:find("no-data", 1, true) ~= nil)
    local PN = core.coachPrompt(DJ, "# Repo\n", nil, { name = "repo", history = { HIST[2], HIST[3] } })
    check("prompt: nothing to judge, no block and no checks asked for", not PN:find("<applied>", 1, true) and not PN:find('"checks"', 1, true))
    -- the answer's checks, read from the same object as its edits
    local pc = core.parseCoachOutput(envelope(json.encode({ summary = "s", edits = {}, decisions = {}, checks = {
      { sha = "aaa1111", verdict = "still-seen", evidence = { "a unit ran\n git push", "again" } },
      { sha = "bbb2222", verdict = "working", evidence = {} },
      { sha = "eee5555", verdict = "great", evidence = { "x" } },
      { sha = "rm -rf /", verdict = "working", evidence = { "x" } },
      { sha = "fff6666", verdict = "still-seen", evidence = {} },
      { sha = "abcdef0", verdict = "no-data" } } })), "")
    check("output: nothing to change is still a verdict, with its checks", pc.verdict == "none" and type(pc.checks) == "table")
    local pcs = {}
    for _, x in ipairs(pc.checks or {}) do pcs[x.sha] = x end
    check("output: a check keeps its commit, its verdict and its quotes, each on one line",
          pcs.aaa1111 and pcs.aaa1111.verdict == "still-seen" and pcs.aaa1111.evidence[1] == "a unit ran git push" and #pcs.aaa1111.evidence == 2)
    check("output: working needs no quote, no-data none either", pcs.bbb2222 and pcs.bbb2222.verdict == "working" and pcs.abcdef0 and pcs.abcdef0.verdict == "no-data")
    check("output: a made-up verdict, a sha that isn't one, and still-seen with nothing quoted are dropped",
          pcs.eee5555 == nil and pcs["rm -rf /"] == nil and pcs.fff6666 == nil and #pc.checks == 3)
    local pnc = core.parseCoachOutput(envelope(json.encode({ summary = "s", edits = {}, decisions = {}, checks = "lots" })), "")
    check("output: checks that aren't a list are none", pnc.verdict == "none" and #(pnc.checks or {}) == 0)
    -- applying them: Lua decides "no data yet", whatever the model said
    local H2 = core.coachApplyChecks(HIST, { { sha = "aaa1111", verdict = "still-seen", evidence = { "a unit ran git push" } },
                                             { sha = "bbb2222bbbb", verdict = "working", evidence = { "made up" } } }, { at = 5000, ats = ATS })
    local hb = {}
    for _, x in ipairs(H2) do hb[x.sha] = x end
    check("checks: a judged edit keeps the coach's verdict, its quotes, when and how many sessions since",
          hb.aaa1111aaaa and type(hb.aaa1111aaaa.check) == "table" and hb.aaa1111aaaa.check.verdict == "still-seen"
          and hb.aaa1111aaaa.check.evidence[1] == "a unit ran git push" and hb.aaa1111aaaa.check.at == 5000 and hb.aaa1111aaaa.check.since == K + 1)
    check("checks: an edit too recent to judge reads no data yet, though the coach called it working",
          hb.bbb2222bbbb and hb.bbb2222bbbb.check and hb.bbb2222bbbb.check.verdict == "no-data" and hb.bbb2222bbbb.check.since == 0
          and #(hb.bbb2222bbbb.check.evidence or {}) == 0)
    check("checks: an undone edit is left alone", hb.ccc3333cccc and hb.ccc3333cccc.check == nil)
    check("checks: ...the list it was given is unchanged", HIST[1].check == nil)
    local H3 = core.coachApplyChecks(HIST, {}, { at = 6000, ats = ATS })
    check("checks: a judgeable edit the coach said nothing about reads no data", H3[1].check and H3[1].check.verdict == "no-data" and H3[1].check.since == K + 1)
    -- 2026-10-04: the panel then said "the N sessions since never came near it" -- which the coach
    -- never claimed. A no-data the coach didn't give is marked unanswered, and kept that way.
    check("checks: ...marked unanswered (the coach gave no verdict), not \"never came near it\"", H3[1].check and H3[1].check.unanswered == true)
    local H4 = core.coachApplyChecks(HIST, { { sha = "aaa1111", verdict = "no-data" } }, { at = 6000, ats = ATS })
    check("checks: a no-data the coach did give isn't unanswered", H4[1].check and H4[1].check.verdict == "no-data" and H4[1].check.unanswered == nil)
    local back3 = core.parseCoachHistory(json.encode(H3))
    check("checks: unanswered survives the history file", back3[1].check and back3[1].check.unanswered == true)
    local hv3row
    for _, x in ipairs(core.coachHistoryView(H3)) do if x.sha == H3[1].sha then hv3row = x end end
    check("checks: ...and reaches the panel's view", hv3row and hv3row.check and hv3row.check.unanswered == true)
    local back = core.parseCoachHistory(json.encode(H2))
    check("checks: a verdict survives the history file", back[1].check and back[1].check.verdict == "still-seen"
          and back[1].check.evidence[1] == "a unit ran git push" and back[1].check.since == K + 1)
    check("checks: a bad verdict on disk is dropped, the entry kept",
          core.parseCoachHistory(json.encode({ { sha = "aaa1111aaaa", at = 1, section = "S", why = "w", old = "", new = "- x",
                                                 check = { verdict = "<b>", evidence = { "e" }, at = 1, since = 3 } } }))[1].check == nil)
    local hv = core.coachHistoryView(H2)
    local hvb = {}
    for _, x in ipairs(hv) do hvb[x.sha] = x end
    check("view: a history row carries its check, and how many sessions a verdict needs",
          hvb.aaa1111aaaa and hvb.aaa1111aaaa.check and hvb.aaa1111aaaa.check.verdict == "still-seen" and hvb.aaa1111aaaa.check.need == K
          and hvb.aaa1111aaaa.check.evidence[1] == "a unit ran git push")
    -- Sharpen: one applied edit, a better wording of it alone
    local SH = H2[1]
    local PS = core.coachPrompt(DJ, "# Repo\n\n## Git\n\n- never push from a unit\n", "# Decisions\n", { name = "repo", history = H2, sharpen = SH })
    local sb = PS:match("<sharpen>\n(.-)\n</sharpen>") or ""
    check("sharpen: the prompt carries the one edit, its text, why and what it was expected to change",
          sb:find("aaa1111", 1, true) ~= nil and sb:find("- never push from a unit", 1, true) ~= nil and sb:find("Units pushed alone.", 1, true) ~= nil
          and sb:find("A unit asks Adam before it pushes.", 1, true) ~= nil)
    check("sharpen: ...and what the last check quoted", sb:find("a unit ran git push", 1, true) ~= nil)
    check("sharpen: asks for ONE better wording of that edit and nothing else", PS:find("ONE", 1, true) ~= nil and PS:lower():find("better wording", 1, true) ~= nil)
    check("sharpen: no judging in a sharpen run", not PS:find("<applied>", 1, true) and not PS:find('"checks"', 1, true))
    local ps = core.parseCoachOutput(envelope(json.encode({ summary = "s", edits = { edit(1), edit(2) }, decisions = { { what = "w", why = "y" } },
                                                           checks = { { sha = "aaa1111", verdict = "working" } } })), "", { sharpen = true })
    check("sharpen: its answer keeps one edit, no DECISIONS.md entry and no checks",
          ps.verdict == "proposals" and #ps.edits == 1 and #ps.decisions == 0 and #(ps.checks or {}) == 0)
    local sr = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "proposals",
      trigger = "card", at = 100, doneAt = 200, lastRunAt = 200, sharpen = "aaa1111aaaa", edits = {}, decisions = {} }))
    check("sharpen: the run's record keeps the commit it sharpens", sr and sr.sharpen == "aaa1111aaaa")
    check("sharpen: ...and drops one that isn't a commit", core.parseCoachRecord(json.encode({ v = 1, root = "/r", state = "done",
      verdict = "none", sharpen = "$(rm)", edits = {}, decisions = {} })).sharpen == nil)
    check("sharpen: the overlay's view says which commit it sharpens", core.coachView(sr).sharpen == "aaa1111aaaa")
    -- once its better wording is applied, the old entry says so and is judged no more
    local SHD = core.parseCoachHistory(json.encode({ { sha = "aaa1111aaaa", at = T0, section = "Git", why = "w", old = "", new = "- x",
                                                      sharpened = { sha = "fff7777ffff", at = T0 + 9 } } }))
    check("sharpen: a sharpened entry keeps the commit that replaced it", SHD[1] and SHD[1].sharpened and SHD[1].sharpened.sha == "fff7777ffff")
    check("sharpen: ...is no longer judged", #core.coachEditsToJudge(SHD, ATS) == 0)
    check("sharpen: ...and its row says so", core.coachHistoryView(SHD)[1].sharpenedSha == "fff7777ffff")
  end
end

-- ---- evidence runs and filed lessons (2026-10-03, mining round 2 unit B4) ----
-- The coach ran weekly or from a card only, so a week of corrections waited for its day, and a
-- session that learned something the hard way had nowhere to file it. Now enough new evidence since
-- the last run starts one (after a cooldown, under a daily cap across repos), and cc-lesson.sh files
-- a one-line lesson that Shepherd puts in the coach's log as `learned`.
do
  local function edue(rec, ev, over)
    local e = { minItems = 5, cooldownHours = 24, dailyUsd = 3, spent = 0, count = 5 }
    for k, v in pairs(ev or {}) do e[k] = v end
    local o = { now = NOW, enabled = true, day = "mon", newest = NOW - 3600, evidence = e }
    for k, v in pairs(over or {}) do o[k] = v end
    return core.coachDue(rec, o)
  end
  local week = { state = "done", verdict = "none", trigger = "weekly", lastRunAt = SLOT + 60 }   -- this week's run, 2 days ago
  local d, why = edue(week)
  check("evidence: enough new evidence since this week's run starts another  (" .. tostring(why) .. ")", d == true and why == "evidence")
  check("evidence: ...not with fewer items than coach.evidence.minItems", edue(week, { count = 4 }) == false)
  check("evidence: ...not with the trigger off (no minItems, or 0)", edue(week, { minItems = false }) == false and edue(week, { minItems = 0 }) == false)
  check("evidence: ...not without coach.enabled", edue(week, nil, { enabled = false }) == false)
  check("evidence: ...not while a run is going", edue(week, nil, { running = true }) == false)
  local recent = { state = "done", verdict = "none", trigger = "card", lastRunAt = NOW - 23 * 3600 }
  local rd, rwhy = edue(recent, { count = 50 })
  check("evidence: ...not within the cooldown after any run  (" .. tostring(rwhy) .. ")", rd == false and rwhy == "cooldown")
  check("evidence: ...the cooldown is coach.evidence.cooldownHours", edue(recent, { count = 50, cooldownHours = 12 }) == true)
  local cd, cwhy = edue(week, { spent = 3 })
  check("evidence: ...not once today's evidence runs reached coach.evidence.dailyUsd  (" .. tostring(cwhy) .. ")", cd == false and cwhy == "daily cap")
  check("evidence: ...below the cap it runs", edue(week, { spent = 2.5 }) == true)
  local asked = 0
  edue(recent, { count = function() asked = asked + 1; return 50 end })
  edue(week, { spent = 3, count = function() asked = asked + 1; return 50 end })
  check("evidence: the count isn't asked for while the cooldown or the cap holds", asked == 0)
  local sinceAsked
  edue(week, { count = function(since) sinceAsked = since; return 5 end })
  check("evidence: the count is asked for what arrived since the last run", sinceAsked == SLOT + 60)
  check("evidence: a count not known yet (its scan in flight) is not due", edue(week, { count = function() return nil end }) == false)
  local wd, wwhy = edue({ state = "done", verdict = "none", lastRunAt = SLOT - 7 * 86400 + 60 }, { count = 50 })
  check("evidence: a weekly run that is due stays weekly (the floor)", wd == true and wwhy == "weekly")
  local fd, fwhy = edue(nil, { count = 50 }, { newest = NOW - 30 * 86400 })
  check("evidence: no run yet and no session this week -- enough filed lessons still start one  (" .. tostring(fwhy) .. ")",
        fd == true and fwhy == "evidence")
  local ld, lwhy = edue({ state = "lost", trigger = "evidence", at = NOW - core.COACH.retryLostSeconds - 1, attempts = 1, lastRunAt = SLOT + 60 })
  check("evidence: a lost evidence run is retried like a weekly one", ld == true and lwhy == "retry")
  check("evidence: ...but not with coach.enabled off", edue({ state = "lost", trigger = "evidence", at = NOW - core.COACH.retryLostSeconds - 1,
        attempts = 1, lastRunAt = SLOT + 60 }, nil, { enabled = false }) == false)

  -- the record keeps the trigger (parseCoachRecord coerced every unknown trigger to weekly)
  local er = core.parseCoachRecord(json.encode({ v = 1, repo = "/r/repo/.git", root = "/r/repo", state = "done", verdict = "none",
    trigger = "evidence", evidence = 7, at = 100, doneAt = 200, lastRunAt = 200, edits = {}, decisions = {} }))
  check("record: an evidence run keeps its trigger", er and er.trigger == "evidence")
  check("record: ...and how many new items started it", er and er.evidence == 7)
  local br = core.parseCoachRecord(json.encode({ v = 1, root = "/r/repo", state = "done", verdict = "none", trigger = "bogus" }))
  check("record: an unknown trigger still reads weekly", br and br.trigger == "weekly")
  local ev = core.coachView(er) or {}
  check("view: the overlay is told an evidence run's trigger and count", ev.trigger == "evidence" and ev.evidence == 7)

  -- the counts: Shepherd's log entries, and a transcript's corrections and interrupts, since the last run
  local since = core.isoToEpoch("2026-09-29T08:05:00.000Z")
  local function u(ts, content, human)
    return '{"type":"user","message":{"role":"user","content":' .. json.encode(content) .. '},"timestamp":"2026-09-29T' .. ts
      .. '.000Z"' .. (human and ',"origin":{"kind":"human"}' or "") .. "}"
  end
  local WIN = table.concat({
    u("08:00:00", "Fix the tick freeze", true),                         -- what it was asked: no correction
    u("08:03:00", "no, not that file", true),                           -- a correction before the last run
    u("08:10:00", "stop -- time the tick in the live VM first", true),  -- after: counts
    u("08:12:00", { { type = "text", text = "[Request interrupted by user]" } }),   -- an interrupt after: counts
    u("08:15:00", "[shepherd] Continue where you left off", true),      -- Shepherd's own prompt: never
    u("08:20:00", "use git restore, not checkout", true),               -- counts
    u("08:21:00", { { type = "tool_result", content = "boom", is_error = true, tool_use_id = "t1" } }),   -- a tool error: not a correction
    "" }, "\n")
  check("evidence: a transcript's corrections and interrupts since the last run are counted  ("
        .. tostring(core.coachTranscriptEvidence and core.coachTranscriptEvidence({ WIN }, since)) .. ")",
        type(core.coachTranscriptEvidence) == "function" and core.coachTranscriptEvidence({ WIN }, since) == 3)
  local FIRST = u("09:00:00", "Start the release notes", true) .. "\n"
  check("evidence: ...a session's first prompt is what it was asked, not a correction",
        type(core.coachTranscriptEvidence) == "function" and core.coachTranscriptEvidence({ FIRST }, since) == 0)
  check("evidence: ...summed over the transcripts", type(core.coachTranscriptEvidence) == "function"
        and core.coachTranscriptEvidence({ WIN, WIN, FIRST }, since) == 6)
  local SLOG = { { kind = "notyet", id = "a", at = since - 10 }, { kind = "learned", id = "b", at = since + 10 },
                 { kind = "checker", id = "c", at = since + 20 }, { kind = "blocked", id = "d", at = since + 30 } }
  check("evidence: Shepherd's log entries since the last run count, every kind",
        type(core.coachLogEvidence) == "function" and core.coachLogEvidence(SLOG, since) == 3)

  -- a filed lesson in the log and the digest: its own words, never read as a checker verdict
  local lg2 = core.coachLogAdd({}, { kind = "learned", id = "learned|1790000000-42", branch = "feat/x",
                                     note = "  run make lint\n before make test " }, 1790000000)
  check("log: a filed lesson is a learned entry, kept on one line", #lg2 == 1 and lg2[1].kind == "learned"
        and lg2[1].note == "run make lint before make test")
  check("log: ...and survives its file", #core.parseCoachLog(json.encode(lg2)) == 1 and core.parseCoachLog(json.encode(lg2))[1].kind == "learned")
  local dtext = core.coachDigest({}, lg2, {}).text or ""
  check("digest: a filed lesson reads as one  (" .. dtext:gsub("\n", " | ") .. ")",
        dtext:find("feat/x: lesson filed — run make lint before make test", 1, true) ~= nil and not dtext:find("feat/x: checker", 1, true))
  local ptext = core.coachPrompt(core.coachDigest({}, lg2, {}), "# R\n", "", { name = "repo" })
  check("prompt: names filed lessons among the evidence", ptext:find("cc-lesson.sh", 1, true) ~= nil)

  -- today's spend on evidence runs, across repos, from Shepherd's own file
  local okS = type(core.coachSpendAdd) == "function" and type(core.coachSpendToday) == "function" and type(core.parseCoachSpend) == "function"
  check("spend: core.coachSpendAdd, coachSpendToday and parseCoachSpend exist", okS)
  if okS then
    local sp = core.coachSpendAdd(nil, 0.4, NOW)
    sp = core.coachSpendAdd(sp, 0.35, NOW + 60)
    check("spend: today's evidence runs add up", math.abs(core.coachSpendToday(sp, NOW + 120) - 0.75) < 1e-9)
    check("spend: ...a new day starts at zero", core.coachSpendToday(sp, NOW + 86400) == 0)
    check("spend: ...and its first run starts the new day's tally",
          math.abs(core.coachSpendToday(core.coachSpendAdd(sp, 0.2, NOW + 86400), NOW + 86400) - 0.2) < 1e-9)
    check("spend: round-trips through its file; a torn one is nothing spent",
          math.abs(core.coachSpendToday(core.parseCoachSpend(json.encode(sp)), NOW) - 0.75) < 1e-9
          and core.coachSpendToday(core.parseCoachSpend("{"), NOW) == 0)
    check("spend: a run in flight counts at its budget (two repos can't both start under the cap)",
          math.abs(core.coachEvidenceSpent(sp, NOW, 2, 1) - 2.75) < 1e-9 and math.abs(core.coachEvidenceSpent(nil, NOW, 0, 1)) < 1e-9)
  end

  -- what cc-lesson.sh writes: ~/.claude/cc-lesson/<epoch>-<pid>.json
  local okL = type(core.lessonFileOf) == "function" and type(core.parseLesson) == "function"
  check("lesson: core.lessonFileOf and core.parseLesson exist", okL)
  if okL then
    check("lesson: <epoch>-<pid>.json is a lesson, its temp write a part, anything else nothing",
          (core.lessonFileOf("1790000000-42.json") or {}).kind == "json" and (core.lessonFileOf("1790000000-42.json.tmp.42") or {}).kind == "part"
          and core.lessonFileOf("notes.txt") == nil and core.lessonFileOf("x.json") == nil and core.lessonFileOf(".panel-alive") == nil)
    local function lesson(over)
      local t = { v = 1, id = "1790000000-42", commonDir = "/r/repo/.git/", toplevel = "/r/repo", branch = "feat/x",
                  text = "  run   make lint first ", at = 1790000000 }
      for k, v in pairs(over or {}) do t[k] = v end
      return core.parseLesson("1790000000-42.json", json.encode(t))
    end
    local L = lesson()
    check("lesson: what cc-lesson.sh writes is read back", L and L.id == "1790000000-42" and L.commonDir == "/r/repo/.git"
          and L.branch == "feat/x" and L.text == "run make lint first")
    check("lesson: refused -- an id that isn't its name, a relative repo, an empty line, torn JSON",
          lesson({ id = "1790000000-43" }) == nil and lesson({ commonDir = "r/.git" }) == nil and lesson({ text = "  \n " }) == nil
          and core.parseLesson("1790000000-42.json", "{") == nil)
    local LL = lesson({ text = ("x"):rep(2000) })
    check("lesson: a long line is capped", LL and utf8.len(LL.text) <= core.COACH.noteChars + 1)
  end

  -- config: the evidence trigger ships in defaults/, and a Save keeps it
  local okd2, dcfg2 = pcall(json.decode, read(ROOT .. "defaults/cc-config.json") or "")
  local ce = okd2 and type(dcfg2) == "table" and type(dcfg2.coach) == "table" and dcfg2.coach.evidence or nil
  check("config: defaults/ ships coach.evidence (minItems, cooldownHours 24, dailyUsd)", type(ce) == "table"
        and (tonumber(ce.minItems) or 0) >= 1 and ce.cooldownHours == 24 and (tonumber(ce.dailyUsd) or 0) > 0)
  local keep2 = {}
  for _, k in ipairs(core.SETTINGS_KEEP_SUBKEYS.coach or {}) do keep2[k] = true end
  check("config: SETTINGS_KEEP_SUBKEYS keeps coach.evidence", keep2.evidence == true)
end

-- ---- the coach reviews the repo's auto-memory (2026-10-03, mining round 2 unit B3) ----
-- Claude Code's auto-memory (~/.claude/projects/<main root>/memory/*.md, indexed by MEMORY.md) is
-- loaded into every session beside CLAUDE.md, and nothing ever reviewed it: a stale or wrong note
-- kept steering sessions. Now the coach reads it and may propose keep / delete / rewrite / promote;
-- Apply checks each file's hash first (live sessions write memory too), backs it up in Shepherd's
-- own folder, keeps MEMORY.md's index lines consistent, and Undo restores from the backup.
do
  check("memory: core.coachMemoryDir exists", type(core.coachMemoryDir) == "function")
  local MROOT = "/Users/me/Programming/repo"
  local MDIR = "/h/.claude/projects/" .. core.encodeProjectPath(MROOT) .. "/memory"
  check("memory: the folder is the MAIN checkout's project folder's memory/",
        type(core.coachMemoryDir) == "function" and core.coachMemoryDir("/h/.claude/projects", MROOT) == MDIR)
  check("memory: ...nil for a root that isn't absolute", type(core.coachMemoryDir) == "function" and core.coachMemoryDir("/h", "repo") == nil)
  local nameOk = type(core.coachMemoryName) == "function"
  check("memory: a plain .md name is a memory file's name", nameOk and core.coachMemoryName("shepherd-project.md") == "shepherd-project.md"
        and core.coachMemoryName("MEMORY.md") == "MEMORY.md")
  check("memory: a name that could leave the folder is none (.., a slash, a dot file, not .md, empty)", nameOk
        and core.coachMemoryName("../x.md") == nil and core.coachMemoryName("a/b.md") == nil and core.coachMemoryName(".x.md") == nil
        and core.coachMemoryName("..md") == nil and core.coachMemoryName("x.txt") == nil and core.coachMemoryName("") == nil
        and core.coachMemoryName("/etc/x.md") == nil and core.coachMemoryName(nil) == nil and core.coachMemoryName("a\nb.md") == nil)

  -- what the prompt carries: MEMORY.md first, then each file by name, whole -- one past the cap is only named
  local IDX = "# Memory Index\n\n- [Stale](stale.md) — an old fact\n- [Good](good.md) — still true\n- [Big](big.md) — long\n"
  local STALE = "---\nname: stale\ndescription: an old fact\n---\n\nThe panel uses hs.alert.show for messages.\n"
  local MB = tonumber(core.COACH.memoryBytes) or 16000
  local GOOD = "---\nname: good\ndescription: still true\n---\n\nmake deploy = lint + test + install + reload.\n"
  local files = { { name = "stale.md", text = STALE }, { name = "MEMORY.md", text = IDX }, { name = "good.md", text = GOOD },
                  { name = "big.md", text = string.rep("x", MB + 10) } }
  local B = type(core.coachMemoryBlock) == "function" and core.coachMemoryBlock(files, MB, MDIR) or nil
  check("memory: core.coachMemoryBlock builds the prompt's block", type(B) == "table" and type(B.text) == "string")
  B = B or { text = "", hashes = {}, shown = {}, omitted = {} }
  local iIdx, iGood, iStale = B.text:find("MEMORY.md", 1, true), B.text:find("good.md", 1, true), B.text:find("stale.md ---", 1, true)
  check("memory: ...MEMORY.md first, then the files by name", iIdx and iGood and iStale and iIdx < iGood and iGood < iStale and true or false)
  check("memory: ...each file whole", B.text:find("The panel uses hs.alert.show for messages.", 1, true) ~= nil
        and B.text:find("make deploy = lint + test + install + reload.", 1, true) ~= nil)
  check("memory: ...one past the cap is named, never cut  (" .. #B.text .. " bytes)", #B.text <= MB + 400
        and not B.text:find("xxxxxxxxxx", 1, true) and B.omitted[1] == "big.md" and B.text:find("big.md", 1, true) ~= nil)
  check("memory: ...with each shown file's hash, and only theirs (what Apply checks)",
        B.hashes["stale.md"] == core.coachHash(STALE) and B.hashes["MEMORY.md"] == core.coachHash(IDX) and B.hashes["big.md"] == nil)
  check("memory: no memory files: no block", type(core.coachMemoryBlock) == "function" and core.coachMemoryBlock({}, 1000, MDIR) == nil)

  local MD = { text = "evidence here\n", ats = {} }
  local PM = core.coachPrompt(MD, "# R\n", nil, { name = "repo", memory = B })
  check("memory: the prompt carries the memory block", PM:find("<memory>", 1, true) ~= nil and PM:find("The panel uses hs.alert.show", 1, true) ~= nil)
  check("memory: ...asks for keep / delete / rewrite / promote in the same object as the edits",
        PM:find('"memory"', 1, true) ~= nil and PM:find('"keep"', 1, true) ~= nil and PM:find('"delete"', 1, true) ~= nil
        and PM:find('"rewrite"', 1, true) ~= nil and PM:find('"promote"', 1, true) ~= nil)
  check("memory: ...and says MEMORY.md is never deleted, and only a shown file is proposed",
        PM:find("MEMORY.md may be rewritten", 1, true) ~= nil and PM:lower():find("only a file shown", 1, true) ~= nil)
  check("memory: no memory: no block and no memory rules", not core.coachPrompt(MD, "# R\n", nil, { name = "repo" }):find("<memory>", 1, true)
        and not core.coachPrompt(MD, "# R\n", nil, { name = "repo" }):find('"memory"', 1, true))
  local PS = core.coachPrompt(MD, "# R\n- a\n", nil, { name = "repo", memory = B,
    sharpen = { sha = "abc1234abc", at = 1, section = "Git", why = "w", old = "", new = "- a" } })
  check("memory: a Sharpen run carries no memory", not PS:find("<memory>", 1, true))

  -- the answer: memory rows, each checked; a promote is a CLAUDE.md edit row
  local function mem(over)
    local m = { file = "stale.md", action = "delete", why = "hs.alert.show is banned now", evidence = { "Messages go through FX.alert" } }
    for k, v in pairs(over or {}) do m[k] = v end
    return m
  end
  local ans = { summary = "Memory tidy.", edits = {}, decisions = {}, memory = {
    mem(),
    mem({ file = "good.md", action = "rewrite", new = "---\nname: good\n---\n\nmake deploy runs the gate first.\n", rename = "deploy.md" }),
    mem({ file = "MEMORY.md", action = "keep", evidence = {} }),
    mem({ file = "good.md", action = "promote", section = "Deploying", new = "- make deploy = lint + test + install + reload" }),
    mem({ file = "nope.md" }),                                   -- not shown: dropped
    mem({ file = "../../.zshrc.md" }),                           -- leaves the folder: dropped
    mem({ file = "big.md" }),                                    -- named, not shown: dropped
    mem({ file = "MEMORY.md", action = "delete" }),              -- the index is never deleted
    mem({ file = "stale.md", action = "rewrite" }),              -- a rewrite needs its new text
    mem({ file = "stale.md", evidence = {} }),                   -- a delete needs evidence
    mem({ file = "stale.md", action = "purge" }),                -- not an action
    mem({ file = "good.md", action = "rewrite", new = "x\n", rename = "../out.md" }),   -- a rename out of the folder
    mem({ file = "MEMORY.md", action = "rewrite", new = "# I\n", rename = "INDEX.md" }), -- the index keeps its name
    mem({ file = "MEMORY.md", action = "promote", section = "S", new = "- x" }),       -- nor is it promoted
  } }
  local MP = core.parseCoachOutput(envelope("Done.\n" .. json.encode(ans)), "", { memory = B.hashes })
  local rows = MP.memory or {}
  check("memory: the parser keeps the three good memory rows, in order  (" .. #rows .. ")",
        #rows == 3 and rows[1].file == "stale.md" and rows[1].action == "delete" and rows[2].action == "rewrite"
        and rows[2].rename == "deploy.md" and rows[2].new:find("gate first", 1, true) ~= nil and rows[3].action == "keep")
  check("memory: ...a promote becomes a CLAUDE.md edit row, from that memory file",
        #MP.edits == 1 and MP.edits[1].fromMemory == "good.md" and MP.edits[1].old == "" and MP.edits[1].section == "Deploying"
        and MP.edits[1].new == "- make deploy = lint + test + install + reload")
  check("memory: ...and the answer is proposals", MP.verdict == "proposals")
  local KP = core.parseCoachOutput(envelope(json.encode({ summary = "fine", edits = {}, decisions = {},
    memory = { mem({ file = "good.md", action = "keep", evidence = {} }) } })), "", { memory = B.hashes })
  check("memory: keeps alone are nothing to change -- the rows still come back",
        KP.verdict == "none" and #(KP.memory or {}) == 1 and KP.memory[1].action == "keep")
  local NP = core.parseCoachOutput(envelope(json.encode(ans)), "", {})
  check("memory: with no memory read, no memory row is kept", #(NP.memory or {}) == 0 and #NP.edits == 0)
  local SP = core.parseCoachOutput(envelope(json.encode(ans)), "", { memory = B.hashes, sharpen = true })
  check("memory: ...nor in a Sharpen run", #(SP.memory or {}) == 0)

  -- the record keeps them across a reload, with what Apply and Undo need
  local recM = { v = 1, root = MROOT, state = "done", verdict = "proposals", edits = {}, decisions = {}, memoryHashes = B.hashes, memory = {
    { file = "stale.md", action = "delete", why = "w", evidence = { "e" }, status = "applied", backup = "1790000000-1-stale.md",
      removed = { "- [Stale](stale.md) — an old fact" }, old = STALE, at = 5 },
    { file = "good.md", action = "rewrite", new = "n\n", why = "w", evidence = { "e" }, status = "pending", error = "x", errorCode = "changed" },
    { file = "../evil.md", action = "delete", why = "w", evidence = { "e" }, status = "pending" } } }
  for i = 1, core.COACH.maxEdits + 1 do recM.edits[i] = { section = "S", old = "", new = "- n" .. i, why = "w", evidence = { "e" }, status = "pending" } end
  recM.edits[#recM.edits].fromMemory = "good.md"
  local RR = core.parseCoachRecord(json.encode(recM)) or { memory = {}, edits = {} }
  check("memory: a record read back keeps its memory rows -- one that leaves the folder is dropped  (" .. #(RR.memory or {}) .. ")",
        #(RR.memory or {}) == 2 and RR.memory[1].status == "applied" and RR.memory[1].backup == "1790000000-1-stale.md"
        and RR.memory[1].removed and RR.memory[1].removed[1] == "- [Stale](stale.md) — an old fact" and RR.memory[2].errorCode == "changed")
  check("memory: ...the hashes the coach read", type(RR.memoryHashes) == "table" and RR.memoryHashes["stale.md"] == core.coachHash(STALE))
  check("memory: ...and a promoted edit past the edits cap, still from its file",
        #RR.edits == core.COACH.maxEdits + 1 and RR.edits[#RR.edits].fromMemory == "good.md")
  local VM = core.coachView(RR) or { memory = {} }
  check("memory: the overlay gets each memory row numbered, a changed one offering the rerun",
        VM.memory and #VM.memory == 2 and VM.memory[2].i == 2 and VM.memory[2].rerun == true and VM.memory[1].rerun == nil)
  check("memory: ...a pending memory row counts on the chip", VM.pending == core.COACH.maxEdits + 1 + 1)

  -- Apply: the file's hash first; delete drops its index lines, a rename moves its link
  local decide = core.coachMemoryDecision or function() return {} end
  local del = decide({ file = "stale.md", action = "delete" }, { current = STALE, readHash = core.coachHash(STALE), index = IDX })
  check("memory apply: a delete goes ahead, taking its index line out of MEMORY.md",
        del.ok == true and del.delete == true and del.index == "# Memory Index\n\n- [Good](good.md) — still true\n- [Big](big.md) — long\n"
        and del.removed and del.removed[1] == "- [Stale](stale.md) — an old fact")
  check("memory apply: ...refused when a session changed the file since the coach read it",
        decide({ file = "stale.md", action = "delete" }, { current = STALE .. "more\n", readHash = core.coachHash(STALE), index = IDX }).error == "changed")
  check("memory apply: ...or deleted it", decide({ file = "stale.md", action = "delete" }, { current = nil, readHash = core.coachHash(STALE) }).error == "changed")
  check("memory apply: ...or when it is a link", decide({ file = "stale.md", action = "delete" },
        { current = STALE, readHash = core.coachHash(STALE), link = true }).error == "link")
  check("memory apply: ...or when it leaves the folder", decide({ file = "../stale.md", action = "delete" },
        { current = STALE, readHash = core.coachHash(STALE) }).error == "outside")
  local NEWG = "---\nname: good\n---\n\nmake deploy runs the gate first."
  local rw = decide({ file = "good.md", action = "rewrite", new = NEWG }, { current = GOOD, readHash = core.coachHash(GOOD), index = IDX })
  check("memory apply: a rewrite writes the whole new file (ending in a newline), MEMORY.md left alone",
        rw.ok == true and rw.write == NEWG .. "\n" and rw.index == nil and rw.afterHash == core.coachHash(NEWG .. "\n"))
  check("memory apply: ...refused when it would change nothing",
        decide({ file = "good.md", action = "rewrite", new = GOOD }, { current = GOOD, readHash = core.coachHash(GOOD) }).error == "no-change")
  local rn = decide({ file = "good.md", action = "rewrite", new = NEWG, rename = "deploy.md" }, { current = GOOD, readHash = core.coachHash(GOOD), index = IDX })
  check("memory apply: a rename writes the new name and moves the index line's link to it",
        rn.ok == true and rn.renameTo == "deploy.md" and rn.index == IDX:gsub("%(good%.md%)", "(deploy.md)") and rn.indexRenamed == true)
  check("memory apply: ...refused when that name is taken", decide({ file = "good.md", action = "rewrite", new = NEWG, rename = "deploy.md" },
        { current = GOOD, readHash = core.coachHash(GOOD), targetExists = true }).error == "exists")
  check("memory apply: MEMORY.md is never deleted", decide({ file = "MEMORY.md", action = "delete" },
        { current = IDX, readHash = core.coachHash(IDX) }).error == "bad-memory")
  check("memory apply: a keep or a promote is nothing to apply here", decide({ file = "good.md", action = "keep" },
        { current = GOOD, readHash = core.coachHash(GOOD) }).error == "bad-memory")

  -- Undo: from the backup, and only over what Shepherd wrote
  local undo = core.coachMemoryUndoDecision or function() return {} end
  local applied = { file = "stale.md", action = "delete", status = "applied", backup = "1-1-stale.md", removed = del.removed }
  local IDX2 = "# Memory Index\n\n- [Good](good.md) — still true\n- [New](new.md) — a session's\n"
  local ud = undo(applied, { backup = STALE, current = nil, index = IDX2 })
  check("memory undo: a delete comes back from its backup, its index line too (after what sessions added since)",
        ud.ok == true and ud.file == "stale.md" and ud.text == STALE and ud.index == IDX2 .. "- [Stale](stale.md) — an old fact\n")
  check("memory undo: ...the line isn't added twice", undo(applied, { backup = STALE, current = nil, index = IDX }).index == nil)
  check("memory undo: ...refused when the file is back meanwhile", undo(applied, { backup = STALE, current = "x", index = IDX2 }).error == "undo-conflict")
  check("memory undo: ...or its backup is gone", undo(applied, { backup = nil, current = nil }).error == "undo-gone")
  local rwA = { file = "good.md", action = "rewrite", status = "applied", backup = "1-2-good.md", afterHash = core.coachHash(NEWG .. "\n") }
  local ur = undo(rwA, { backup = GOOD, current = NEWG .. "\n" })
  check("memory undo: a rewrite goes back to the file it replaced", ur.ok == true and ur.file == "good.md" and ur.text == GOOD and ur.remove == nil)
  check("memory undo: ...refused when a session changed it since", undo(rwA, { backup = GOOD, current = NEWG .. "more\n" }).error == "undo-conflict")
  local rnA = { file = "good.md", action = "rewrite", status = "applied", backup = "1-3-good.md", afterHash = core.coachHash(NEWG .. "\n"),
                renamedTo = "deploy.md", indexRenamed = true }
  local un = undo(rnA, { backup = GOOD, current = NEWG .. "\n", original = nil, index = rn.index })
  check("memory undo: a rename puts the old file back, drops the new name and moves the link back",
        un.ok == true and un.file == "good.md" and un.text == GOOD and un.remove == "deploy.md" and un.index == IDX)
  check("memory undo: ...refused when the old name was taken meanwhile", undo(rnA, { backup = GOOD, current = NEWG .. "\n", original = "x" }).error == "undo-conflict")
  check("memory undo: nothing applied, nothing to undo", undo({ file = "good.md", action = "rewrite", status = "pending" }, { backup = GOOD }).ok ~= true)

  -- the lessons ledger records memory decisions too
  local item = type(core.coachMemoryLessonItem) == "function" and core.coachMemoryLessonItem({ file = "stale.md", action = "delete", why = "banned now" }) or {}
  local L1, lid = core.coachLessonRecord({}, item, "applied", { at = 10, run = 9 })
  check("memory lessons: an applied memory delete is a lesson, its section naming the file",
        lid ~= nil and L1[1] and L1[1].section == "memory/stale.md" and L1[1].verdict == "applied" and L1[1].text == "delete")
  local LF = core.coachLessonFold({}, { at = 20, edits = {}, memory = {
    { file = "good.md", action = "rewrite", new = "n\n", why = "w", evidence = { "e" }, status = "skipped", reason = "still true", at = 21 },
    { file = "MEMORY.md", action = "keep", why = "w", evidence = {}, status = "keep" } } }, {})
  check("memory lessons: a skipped memory row is folded in when the next run starts (a keep is not)",
        #LF == 1 and LF[1].section == "memory/good.md" and LF[1].verdict == "skipped" and LF[1].reason == "still true")
  local PL = core.coachPrompt(MD, "# R\n", nil, { name = "repo", memory = B, lessons = L1 })
  check("memory lessons: the prompt shows them with the rest", (PL:match("<lessons>\n(.-)\n</lessons>") or ""):find("memory/stale.md", 1, true) ~= nil)
end

-- ---- lessons applied in 2+ repos go to the global CLAUDE.md (2026-10-03, mining round 2 unit B5) ----
-- Each repo's coach learned alone: a lesson Adam applied in three repos' CLAUDE.md never reached the
-- global ~/.claude/CLAUDE.md every session reads. Now one headless run (its own lane, at most daily,
-- only when 2+ repos have applied lessons it hasn't considered) groups "the same lesson" across repos
-- -- the model's call, never fuzzy Lua -- and each group is one rule for a marked, size-capped block in
-- ~/.claude/CLAUDE.md, applied only on Adam's click, refused if the file changed, with Undo from a backup.
do
  check("global: core.coachGlobalLessons exists", type(core.coachGlobalLessons) == "function")
  local ok = type(core.coachGlobalLessons) == "function" and type(core.coachGlobalDue) == "function"
    and type(core.coachGlobalPrompt) == "function" and type(core.parseCoachGlobalOutput) == "function"
    and type(core.coachGlobalApplyDecision) == "function" and type(core.coachGlobalUndoDecision) == "function"
    and type(core.coachGlobalStart) == "function" and type(core.coachGlobalFinish) == "function"
    and type(core.parseCoachGlobalRecord) == "function" and type(core.coachGlobalView) == "function"
    and type(core.coachGlobalPendingFor) == "function"
  check("global: the pure halves exist (lessons, due, prompt, parser, apply, undo, start, finish, record, view)", ok)
  if ok then
  local KA, KB, KC = core.coachFileKey("/r/alpha"), core.coachFileKey("/r/beta"), core.coachFileKey("/r/gamma")
  local function les(id, verdict, section, text, at, over)
    local l = { id = id, section = section, textHash = "a1b2c3", verdict = verdict, why = "why " .. id, text = text, at = at, runs = { at } }
    for k, v in pairs(over or {}) do l[k] = v end
    return l
  end
  local NEVER = "- never run make install from a worktree; it puts unmerged code live"
  local repos = {
    { key = KB, name = "beta", lessons = {
        les("Lb00001", "applied", "Deploying", "- never make install in a worktree", 200),
        les("Lb00002", "skipped", "Git", "- squash before merge", 210),
        les("Lb00003", "undone", "Git", "- push after every commit", 220) },
      history = {} },
    { key = KA, name = "alpha", lessons = {
        les("La00001", "applied", "Worktrees", "- never run make install from a w…", 100),
        les("La00002", "applied", "memory/stale.md", "delete", 110),
        les("La00003", "applied", "Tests", "- run the whole suite before a merge", 120) },
      -- the history keeps an applied edit's whole text; the ledger only its first 160 characters
      history = { { sha = "abc1234", at = 100, section = "Worktrees", old = "", new = NEVER, why = "w", lesson = "La00001" } } },
    { key = KC, name = "gamma", lessons = { les("Lc00001", "skipped", "Git", "- squash", 300) }, history = {} },
  }
  local G = core.coachGlobalLessons(repos, {})
  local byId = {}
  for _, l in ipairs(G.list or {}) do byId[l.id] = l end
  check("global lessons: only the applied CLAUDE.md lessons, from every repo  (" .. #(G.list or {}) .. ")",
        #(G.list or {}) == 3 and byId.La00001 and byId.La00003 and byId.Lb00001 and true or false)
  check("global lessons: ...never a skipped or undone one, nor an auto-memory change",
        not byId.Lb00002 and not byId.Lb00003 and not byId.La00002 and not byId.Lc00001)
  check("global lessons: an applied edit's whole text comes from the history", byId.La00001 and byId.La00001.text == NEVER)
  check("global lessons: ...else the ledger's", byId.Lb00001 and byId.Lb00001.text == "- never make install in a worktree")
  check("global lessons: each repo gets a tag by its key (r1, r2), each lesson a ref the model cites",
        byId.La00001 and byId.Lb00001 and byId.La00001.ref:match("^r%d/La00001$") ~= nil and byId.Lb00001.ref:match("^r%d/Lb00001$") ~= nil
        and byId.La00001.ref:sub(1, 2) ~= byId.Lb00001.ref:sub(1, 2) and byId.La00001.name == "alpha" and byId.La00001.key == KA)
  check("global lessons: 2 repos have applied lessons, both new at first  (" .. tostring(G.repos) .. ", " .. tostring(G.newRepos) .. ")",
        G.repos == 2 and G.newRepos == 2 and byId.La00001 and byId.La00001.new == true)
  local seenA = {}
  for _, l in ipairs(G.list or {}) do if l.key == KA then seenA[#seenA + 1] = l.seen end end
  local G2 = core.coachGlobalLessons(repos, seenA)
  check("global lessons: a considered lesson isn't new; only beta has new ones  (" .. tostring(G2.newRepos) .. ")",
        G2.newRepos == 1 and G2.repos == 2)
  local repos3 = { repos[1], repos[2], { key = KC, name = "gamma", lessons = { les("Lc00009", "applied", "Git", "- squash", 300) }, history = {} } }
  check("global lessons: a lesson applied again with new text is new again",
        core.coachGlobalLessons({ { key = KA, name = "alpha", lessons = { les("La00003", "applied", "Tests", "x", 1, { textHash = "ffff01" }) }, history = {} } },
          seenA).newRepos == 1)

  -- due: at most daily, only when 2+ repos have applied lessons not yet considered; enabled like the coach
  local due = core.coachGlobalDue
  local NOW = 1800000000
  local asked = 0
  local function lazy(g) return function() asked = asked + 1; return g end end
  check("global due: off without coach.enabled", not due(nil, { now = NOW, enabled = false, input = G }))
  check("global due: not while one runs", not due(nil, { now = NOW, enabled = true, running = true, input = G }))
  local d1, w1 = due(nil, { now = NOW, enabled = true, input = lazy(G) })
  check("global due: a first run, with 2 repos' lessons new  (" .. tostring(w1) .. ")", d1 == true)
  asked = 0
  local d2, w2 = due({ at = NOW - 3600, state = "done", verdict = "none" }, { now = NOW, enabled = true, input = lazy(G) })
  check("global due: not twice in a day  (" .. tostring(w2) .. ")", d2 == false)
  check("global due: ...and the repos' ledgers aren't even read then", asked == 0)
  check("global due: a day later, again", due({ at = NOW - 86401, state = "done", verdict = "none" }, { now = NOW, enabled = true, input = G }) == true)
  check("global due: a lost run waits a day from its start too", due({ at = NOW - 60, state = "lost" }, { now = NOW, enabled = true, input = G }) == false)
  local d3, w3 = due({ at = NOW - 86401 }, { now = NOW, enabled = true, input = G2 })
  check("global due: not when only one repo has new lessons  (" .. tostring(w3) .. ")", d3 == false)

  -- the prompt: every applied lesson by repo, marked new or not, the global CLAUDE.md, the rules
  local GMD = "# Global\n\n## Git\n\n- commit often\n"
  local P = core.coachGlobalPrompt(G, GMD, {})
  check("global prompt: each lesson by its ref, repo, section and text",
        P:find(byId.La00001.ref, 1, true) ~= nil and P:find(NEVER, 1, true) ~= nil and P:find("alpha", 1, true) ~= nil
        and P:find("Worktrees", 1, true) ~= nil and P:find("- never make install in a worktree", 1, true) ~= nil)
  check("global prompt: marks the lessons not considered before", P:find("(new)", 1, true) ~= nil)
  check("global prompt: carries the global CLAUDE.md", P:find("<global_claude_md>\n" .. GMD, 1, true) ~= nil)
  check("global prompt: asks for groups of lessons from 2+ different repos, as JSON",
        P:find('"groups"', 1, true) ~= nil and P:find('"lessons"', 1, true) ~= nil and P:find('"rule"', 1, true) ~= nil
        and P:lower():find("two or more different repos", 1, true) ~= nil)
  check("global prompt: the model judges the match (reworded or not)", P:lower():find("reworded or not", 1, true) ~= nil)
  local PD = core.coachGlobalPrompt(G, GMD, { decided = { { rule = "Run the whole suite before a merge", status = "skipped", reason = nil },
                                                          { rule = "Never git push", status = "applied" } } })
  check("global prompt: <decided> lists what Adam applied or skipped before",
        (PD:match("<decided>\n(.-)\n</decided>") or ""):find("Never git push", 1, true) ~= nil
        and (PD:match("<decided>\n(.-)\n</decided>") or ""):find("skipped", 1, true) ~= nil)
  local big = {}
  for i = 1, 400 do big[i] = les(string.format("L%06x", i), "applied", "S", string.rep("x", 500) .. i, i) end
  local GB = core.coachGlobalLessons({ { key = KA, name = "alpha", lessons = big, history = {} }, repos[1] }, {})
  local PB = core.coachGlobalPrompt(GB, GMD, {})
  check("global prompt: the lessons are capped  (" .. #PB .. " bytes)", #PB < core.COACH_GLOBAL.inputBytes + 8000)

  -- the parser: a group needs real lessons from 2+ repos; Lua checks the citations, the model the match
  local refA, refA3, refB = byId.La00001.ref, byId.La00003.ref, byId.Lb00001.ref
  local function grp(lessons, over)
    local gx = { lessons = lessons, rule = "Never run make install from a worktree", why = "It deployed unmerged code in two repos." }
    for k, v in pairs(over or {}) do gx[k] = v end
    return gx
  end
  local ans = { summary = "One lesson twice.", groups = {
    grp({ refA, refB }, { rule = "- Never run make install from a worktree" }),   -- a leading "- " goes
    grp({ refA, refA3 }),                                                         -- one repo only
    grp({ refA, "r9/L999999" }),                                                  -- a made-up ref
    grp({ refA, refB }, { rule = "" }),                                           -- no rule
    grp({ refA, refB }, { why = "" }),                                            -- no why
    grp({ refA, refB }, { rule = string.rep("y", core.COACH_GLOBAL.ruleChars + 1) }),   -- too long
    grp({ refA, refB, refB }, { rule = "Never make install outside main", whatsNew = "beta learned it too" }),
  } }
  local GP = core.parseCoachGlobalOutput(envelope("Compared.\n" .. json.encode(ans)), "", G)
  check("global parser: two good groups, in order  (" .. #(GP.proposals or {}) .. ")",
        GP.verdict == "proposals" and #(GP.proposals or {}) == 2)
  local p1 = (GP.proposals or {})[1] or {}
  check("global parser: ...its rule without the leading dash", p1.rule == "Never run make install from a worktree")
  check("global parser: ...each lesson resolved from the input, never the model's words",
        type(p1.lessons) == "table" and #p1.lessons == 2 and p1.lessons[1].key ~= nil and p1.lessons[1].name ~= nil
        and (p1.lessons[1].text == NEVER or p1.lessons[2].text == NEVER))
  check("global parser: ...a lesson cited twice counts once", #(((GP.proposals or {})[2] or {}).lessons or {}) == 2
        and ((GP.proposals or {})[2] or {}).whatsNew == "beta learned it too")
  check("global parser: ...pending, with the cost", p1.status == "pending" and math.abs((GP.costUsd or 0) - 0.21) < 1e-9)
  local NP = core.parseCoachGlobalOutput(envelope(json.encode({ summary = "none", groups = {} })), "", G)
  check("global parser: no groups is an answer: none", NP.verdict == "none" and #NP.proposals == 0)
  local BP = core.parseCoachGlobalOutput(envelope(json.encode({ summary = "s", groups = { grp({ refA, refA3 }) } })), "", G)
  check("global parser: only groups from one repo: couldn't run, saying why", BP.verdict == "couldntRun" and type(BP.why) == "string")
  check("global parser: no JSON: couldn't run", core.parseCoachGlobalOutput(envelope("I looked."), "", G).verdict == "couldntRun")
  local MP = { summary = "many", groups = {} }
  for i = 1, core.COACH_GLOBAL.maxProposals + 3 do MP.groups[i] = grp({ refA, refB }, { rule = "rule " .. i }) end
  check("global parser: at most maxProposals", #core.parseCoachGlobalOutput(envelope(json.encode(MP)), "", G).proposals == core.COACH_GLOBAL.maxProposals)

  -- Apply: a marked block at the end of ~/.claude/CLAUDE.md, created when absent; the rest untouched
  local apply = core.coachGlobalApplyDecision
  local A1 = apply(GMD, core.coachHash(GMD), p1)
  local S, E = core.COACH_GLOBAL_START, core.COACH_GLOBAL_END
  check("global apply: the markers are Shepherd's coach's own, never the installer's",
        type(S) == "string" and S:find("shepherd-coach:start", 1, true) ~= nil and E == "<!-- shepherd-coach:end -->"
        and not S:find("methodology", 1, true))
  check("global apply: no block yet: one is created at the end, the file before it byte for byte",
        A1.ok == true and A1.created == true and A1.text:sub(1, #GMD) == GMD and A1.text:sub(#GMD + 1, #GMD + 1) == "\n"
        and A1.text:find(S, 1, true) ~= nil and A1.text:find("\n- Never run make install from a worktree\n" .. E .. "\n", 1, true) ~= nil
        and A1.text:sub(-#E - 1) == E .. "\n")
  check("global apply: ...with its hash for Undo", A1.afterHash == core.coachHash(A1.text))
  local A2 = apply(A1.text, A1.afterHash, (GP.proposals or {})[2] or {})
  check("global apply: a second rule goes at the end of the block, the first kept",
        A2.ok == true and not A2.created and A2.text:find("- Never run make install from a worktree\n- Never make install outside main\n" .. E, 1, true) ~= nil
        and select(2, A2.text:gsub("shepherd%-coach:start", "")) == 1)
  check("global apply: refused when the file changed since the run read it",
        apply(GMD .. "- a hand edit\n", core.coachHash(GMD), p1).error == "changed")
  check("global apply: refused when the rule is in the block already", apply(A1.text, A1.afterHash, p1).error == "exists")
  local fat = { rule = string.rep("z", core.COACH_GLOBAL.ruleChars - 10) }
  local cur, okFull = A1.text, nil
  for _ = 1, 20 do
    local r = apply(cur, core.coachHash(cur), { rule = fat.rule .. tostring(math.random(1e9)) })
    if not r.ok then okFull = r.error; break end
    cur = r.text
  end
  check("global apply: the block is size-capped  (" .. tostring(okFull) .. ")", okFull == "full")
  local noNl = "# Global"
  local A3 = apply(noNl, core.coachHash(noNl), p1)
  check("global apply: a file without a last newline gets one before the block", A3.ok == true and A3.text:sub(1, #noNl + 2) == noNl .. "\n\n")
  local A4 = apply(nil, core.coachHash(nil), p1)
  check("global apply: no file yet: the block is the file", A4.ok == true and A4.created == true and A4.newFile == true and A4.text:sub(1, #S) == S)
  check("global apply: ...a file that was there is no new file", A1.newFile == nil)
  check("global apply: a start marker with no end is never guessed at",
        apply(GMD .. S .. "\n- x\n", core.coachHash(GMD .. S .. "\n- x\n"), p1).error == "bad-block")
  local two = A1.text .. S .. "\n" .. E .. "\n"
  check("global apply: ...nor two blocks", apply(two, core.coachHash(two), p1).error == "bad-block")
  local mid = "# G\n\n" .. S .. "\n## Lessons learned across repos\n\n- old rule\n" .. E .. "\n\n## After\n\n- kept\n"
  local A5 = apply(mid, core.coachHash(mid), p1)
  check("global apply: a block that isn't last is edited where it is, the text after it kept",
        A5.ok == true and A5.text == "# G\n\n" .. S .. "\n## Lessons learned across repos\n\n- old rule\n- Never run make install from a worktree\n" .. E .. "\n\n## After\n\n- kept\n")

  -- Undo: from the backup, only over what Shepherd wrote
  local undo = core.coachGlobalUndoDecision
  local applied = { status = "applied", afterHash = A1.afterHash, backup = "1-1-CLAUDE.md" }
  local U1 = undo(applied, { backup = GMD, current = A1.text })
  check("global undo: the file goes back to its backup", U1.ok == true and U1.text == GMD)
  check("global undo: refused when the file changed since Shepherd wrote it", undo(applied, { backup = GMD, current = A1.text .. "x\n" }).error == "undo-conflict")
  check("global undo: refused without its backup", undo(applied, { backup = nil, current = A1.text }).error == "undo-gone")
  check("global undo: a file the Apply created is removed again", (function()
    local r = undo({ status = "applied", afterHash = A4.afterHash, newFile = true }, { current = A4.text })
    return r.ok == true and r.delete == true end)())
  check("global undo: nothing applied, nothing to undo", undo({ status = "pending" }, { backup = GMD, current = GMD }).ok ~= true)

  -- start and finish: pending proposals don't outlive the next run, and their lessons come back as new
  local R0 = core.coachGlobalStart(nil, NOW, "auto")
  check("global start: a first run is queued, stamped now", R0.state == "queued" and R0.at == NOW and R0.trigger == "auto" and #R0.proposals == 0)
  local R1 = core.coachGlobalFinish(R0, GP, G, NOW + 60)
  check("global finish: the proposals land pending, the run done",
        R1.state == "done" and R1.verdict == "proposals" and #R1.proposals == 2 and R1.proposals[1].status == "pending" and R1.lastRunAt == NOW + 60)
  check("global finish: every lesson it was shown is considered now  (" .. #(R1.considered or {}) .. ")", #(R1.considered or {}) == #G.list)
  check("global finish: so the same lessons aren't new any more", core.coachGlobalLessons(repos, R1.considered).newRepos == 0)
  R1.proposals[1].status = "applied"
  local R2 = core.coachGlobalStart(R1, NOW + 86500, "click")
  check("global start: the next run drops the pending proposal, keeps the applied one",
        #R2.proposals == 1 and R2.proposals[1].status == "applied" and R2.trigger == "click")
  local G3 = core.coachGlobalLessons(repos, R2.considered)
  check("global start: ...and the dropped one's lessons are new again  (" .. tostring(G3.newRepos) .. ")", G3.newRepos == 2)
  local R3 = core.coachGlobalFinish(core.coachGlobalStart(R2, NOW + 90000, "auto"),
    { verdict = "proposals", proposals = { { rule = R1.proposals[1].rule, why = "w", lessons = p1.lessons, status = "pending" } } }, G, NOW + 90060)
  check("global finish: a rule already applied isn't proposed again", #R3.proposals == 1 and R3.verdict == "none")
  local RC = core.coachGlobalFinish(core.coachGlobalStart(R2, NOW, "auto"), { verdict = "couldntRun", why = "no answer", proposals = {} }, G, NOW)
  check("global finish: a run that couldn't run considers nothing", #(RC.considered or {}) == #(R2.considered or {}) and RC.verdict == "couldntRun")

  -- the record, read back (Shepherd is its only writer); a run a reload killed reads lost
  local back = core.parseCoachGlobalRecord(json.encode(R1))
  check("global record: read back with its proposals and what it considered",
        back and back.verdict == "proposals" and #back.proposals == 2 and #back.considered == #R1.considered
        and back.proposals[1].lessons[1].key ~= nil)
  local lost = core.parseCoachGlobalRecord(json.encode({ v = 1, state = "running", at = NOW, proposals = {}, considered = {} }))
  check("global record: a run Shepherd lost reads lost, never a verdict", lost and lost.state == "lost" and lost.verdict == nil)
  check("global record: junk reads nil", core.parseCoachGlobalRecord("{") == nil and core.parseCoachGlobalRecord(nil) == nil)

  -- the overlay, and the chip on the cards whose repos learned it
  local V = core.coachGlobalView(R1, {})
  check("global view: each proposal numbered, with its rule, why, repos and status",
        V and #V.proposals == 2 and V.proposals[2].i == 2 and V.proposals[1].rule ~= nil and V.proposals[1].lessons[1].name ~= nil
        and V.pending == 1)
  R1.proposals[2].error, R1.proposals[2].errorCode = "x", "changed"
  check("global view: a proposal the file changed under offers the rerun", core.coachGlobalView(R1, {}).proposals[2].rerun == true)
  check("global view: a run in flight reads running", core.coachGlobalView(R1, { busy = true }).state == "running")
  local PF = core.coachGlobalPendingFor(R1)
  check("global chip: the pending proposal counts on alpha's and beta's cards, not gamma's",
        PF[KA] == 1 and PF[KB] == 1 and PF[KC] == nil)
  check("global chip: a card's chip counts it", (core.coachTileInfo(nil, { global = 1 }) or {}).pending == 1
        and (core.coachTileInfo({ edits = {}, decisions = {} }, { global = 2 }) or {}).pending == 2
        and core.coachTileInfo(nil, {}) == nil)
  end

  -- never mirrored: the block is Adam's, in his own file; methodology/CLAUDE.md ships to coworkers
  check("global: methodology/CLAUDE.md never carries the coach's block", not (read(ROOT .. "methodology/CLAUDE.md") or ""):find("shepherd-coach", 1, true))
end

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
    -- 2026-09-30: GNU stat first, then BSD. These asked BSD `stat -f` alone, so on ubuntu (CI) every
    -- file read as missing, the coach found no transcripts and never ran, and this test crashed.
    attributes = function(path, what)
      local p = io.popen("stat -c '%Y %F' " .. q(path) .. " 2>/dev/null || stat -f '%m %HT' " .. q(path) .. " 2>/dev/null")
      local l = p and p:read("*l"); if p then p:close() end
      if not l then return nil, "no such file" end
      local m, ty = l:match("^(%d+) (.*)$")
      local t = { modification = tonumber(m), mode = (tostring(ty):lower() == "directory") and "directory" or "file" }
      if what then return t[what] end
      return t
    end,
    symlinkAttributes = function(path, what)   -- lstat: a link reports itself
      local p = io.popen("stat -c '%F' " .. q(path) .. " 2>/dev/null || stat -f '%HT' " .. q(path) .. " 2>/dev/null")
      local l = p and p:read("*l"); if p then p:close() end
      if not l then return nil end
      l = l:lower()
      local t = { mode = (l == "symbolic link") and "link" or ((l == "directory") and "directory" or "file") }
      if what then return t[what] end
      return t
    end,
    mkdir = function(path) os.execute("mkdir -p " .. q(path) .. " 2>/dev/null"); return true end,
    -- 2026-10-03: like the real one, links resolved; nil when the path isn't there
    pathToAbsolute = function(path)
      local p = io.popen("realpath " .. q(path) .. " 2>/dev/null")
      local l = p and p:read("*l"); if p then p:close() end
      return (l and l ~= "") and l or nil
    end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd or "")
    -- like the real hs.execute: output, then whether it exited 0, then "exit" and the code
    if cmd:match("^git ") or cmd:match("^cd ") then local out, code = sh(cmd); return out, code == 0, "exit", code end
    return "", true, "exit", 0
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
check("Apply refuses when CLAUDE.md is a link", okA == false and (sh("test -L " .. q(REPO .. "/CLAUDE.md") .. " && echo still-a-link")):find("still-a-link", 1, true) ~= nil
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

-- 2026-09-30: every applied edit goes into the repo's history file, and Undo restores CLAUDE.md
local HFILE = CDIR .. "/" .. core.coachFileKey(REPO) .. ".applied.json"
local savedHist = core.parseCoachHistory and core.parseCoachHistory(read(HFILE)) or {}
check("an applied edit is written to the repo's history, with its commit and both texts  (" .. #savedHist .. ")",
      #savedHist == 2 and savedHist[1].sha == rootRec.edits[1].sha and savedHist[1].old == "- commit often"
      and savedHist[1].new == "- commit often; never git push")
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local histSent = false
for _, js in ipairs(jsCalls) do if js:find("ccCoach(", 1, true) and js:find('"history":', 1, true) then histSent = true end end
check("...and the overlay is sent the history", histSent)
local beforeUndo = read(REPO .. "/CLAUDE.md")
local function commitTasks() return tasksWhere(function(t) return tostring(t.args[2] or ""):find("git commit", 1, true) end) end
local nCommits = #commitTasks()
local okU
quiet(function() okU = type(fx.coachUndo) == "function" and fx.coachUndo(REPO, 1) end)
check("Undo starts one commit  (" .. (#commitTasks() - nCommits) .. ")", okU == true and #commitTasks() == nCommits + 1)
if commitTasks()[nCommits + 1] then runFor(commitTasks()[nCommits + 1]) end
check("...with a plain message that names the commit it undoes",
      (sh("git -C " .. q(REPO) .. " log -1 --format=%s")):find("CLAUDE.md: undo", 1, true) ~= nil
      and not (sh("git -C " .. q(REPO) .. " log -1 --format=%B")):find("Co-Authored", 1, true))
local afterHist = core.parseCoachHistory and core.parseCoachHistory(read(HFILE)) or {}
check("Undo puts the first edit's text back, leaving the second edit in",
      (read(REPO .. "/CLAUDE.md") or ""):find("- commit often\n", 1, true) ~= nil and not (read(REPO .. "/CLAUDE.md") or ""):find("never git push", 1, true)
      and (read(REPO .. "/CLAUDE.md") or ""):find("- run make lint first", 1, true) ~= nil and read(REPO .. "/CLAUDE.md") ~= beforeUndo)
check("...in a commit of CLAUDE.md alone, recorded on the history entry",
      (sh("git -C " .. q(REPO) .. " show --name-only --format= HEAD")):gsub("%s+$", "") == "CLAUDE.md"
      and afterHist[1] and type(afterHist[1].undone) == "table" and type(afterHist[1].undone.sha) == "string")
check("...Shepherd's own undo isn't \"changed since the coach read it\"", rootRec.claudeHash == core.coachHash(read(REPO .. "/CLAUDE.md")))
quiet(function() okU = type(fx.coachUndo) == "function" and fx.coachUndo(REPO, 1) end)
check("an entry already undone is not undone twice", okU == false and #commitTasks() == nCommits + 1)
write(REPO .. "/CLAUDE.md", read(REPO .. "/CLAUDE.md") .. "- wip\n")
quiet(function() okU = type(fx.coachUndo) == "function" and fx.coachUndo(REPO, 2) end)
check("Undo refuses while CLAUDE.md has uncommitted edits, and says why on the entry", okU == false
      and tostring((core.parseCoachHistory and core.parseCoachHistory(read(HFILE)) or {})[2].error):find("uncommitted", 1, true) ~= nil)
sh("git -C " .. q(REPO) .. " checkout -q -- CLAUDE.md")

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
local limitSent = false
for _, js in ipairs(jsCalls) do if js:find("ccCoach(", 1, true) and js:find('"timeoutSeconds":', 1, true) then limitSent = true end end
check("...with the coach's time limit (coach.timeoutSeconds), for the overlay's timer", limitSent)

-- 2026-09-30: Adam's first applied edit (35c1a59) predated the history. It was seeded from the run's
-- record in memory only, so the next coach run -- which replaces that record -- lost it: the
-- overlay's Applied edits was empty right after the feature shipped.
local function oldRun()   -- a run from before the history: one edit applied, no history file
  os.remove(HFILE)
  fx._coach.history = {}
  fx._coach.recs[REPO] = { v = 1, repo = REPO .. "/.git", root = REPO, name = "repo", state = "done", verdict = "proposals",
    trigger = "card", at = 100, doneAt = 200, lastRunAt = 200, claudeHash = "h",
    edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "applied", sha = "abc1234abc" },
              { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, status = "pending" } },
    decisions = {} }
end
oldRun()
local seeded = fx.coachHistory(REPO)
check("an edit applied before the history existed is seeded from the run's record  (" .. #seeded .. ")", #seeded == 1 and seeded[1].sha == "abc1234abc")
check("...and written to the history file at once, not only kept in memory", #core.parseCoachHistory(read(HFILE)) == 1)
oldRun()
quiet(function() fx.coachStart(fx.coachRepoForRoot(REPO) or { root = REPO, commonDir = REPO .. "/.git", name = "repo" }, "card", CFG) end)
check("a new run saves the old record's applied edits before it replaces the record",
      #core.parseCoachHistory(read(HFILE)) == 1 and core.parseCoachHistory(read(HFILE))[1].sha == "abc1234abc")

-- 2026-09-30: Add to the section anyway on a real repo -- refused, then added, committed alone, kept
-- in the history as what was written, and undone.
do
local CURF = read(REPO .. "/CLAUDE.md")
fx._coach.recs[REPO] = { v = 1, repo = REPO .. "/.git", root = REPO, name = "repo", state = "done", verdict = "proposals",
  trigger = "card", at = 100, doneAt = 200, lastRunAt = 200, claudeHash = core.coachHash(CURF),
  edits = { { section = "Git", old = "- commit little and often", new = "- commit little and often\n- never git push from a unit",
              why = "Units pushed on their own.", evidence = { "e" }, status = "pending" } }, decisions = {} }
local arec = fx._coach.recs[REPO]
local nA = #commitTasks()
quiet(function() okA = fx.coachApply(REPO, 1) end)
check("add anyway (repo): a plain Apply is refused, and the view offers Add anyway and a fresh run",
      okA == false and arec.edits[1].errorCode == "not-found" and (core.coachView(arec).edits[1] or {}).addAnyway == true
      and (core.coachView(arec).edits[1] or {}).rerun == true)
alerts = {}
quiet(function() okA = fx.coachApply(REPO, 1, true) end)
check("add anyway (repo): starts one commit  (" .. (#commitTasks() - nA) .. ")", okA == true and #commitTasks() == nA + 1)
if commitTasks()[nA + 1] then runFor(commitTasks()[nA + 1]) end
local ADDED = CURF:gsub("%- commit often\n", "- commit often\n- never git push from a unit\n")
check("add anyway (repo): only the new part is written, at the end of its section", read(REPO .. "/CLAUDE.md") == ADDED)
check("add anyway (repo): ...in a commit of CLAUDE.md alone", (sh("git -C " .. q(REPO) .. " show --name-only --format= HEAD")):gsub("%s+$", "") == "CLAUDE.md")
check("add anyway (repo): the edit reads as what was written", arec.edits[1].status == "applied" and arec.edits[1].old == ""
      and arec.edits[1].new == "- never git push from a unit" and arec.edits[1].error == nil)
local said = false
for _, m in ipairs(alerts) do if m:find("end of its section", 1, true) then said = true end end
check("add anyway (repo): the toast says where it went", said)
local ah = core.parseCoachHistory(read(HFILE))
local last = ah[#ah] or {}
check("add anyway (repo): the history keeps what was written, with its commit", last.old == "" and last.new == "- never git push from a unit"
      and last.sha ~= nil and last.sha == arec.edits[1].sha)
nA = #commitTasks()
quiet(function() okU = fx.coachUndo(REPO, #ah) end)
if commitTasks()[nA + 1] then runFor(commitTasks()[nA + 1]) end
check("add anyway (repo): Undo takes it back out", okU == true and read(REPO .. "/CLAUDE.md") == CURF)
end

-- 2026-09-30: a skipped suggestion couldn't be brought back -- Skip was final, and Shepherd's own
-- "Deploying" edit was skipped only because of a refusal that has since been fixed.
do
fx._coach.recs[REPO] = { v = 1, repo = REPO .. "/.git", root = REPO, name = "repo", state = "done", verdict = "proposals",
  trigger = "card", at = 100, doneAt = 200, lastRunAt = 200, claudeHash = core.coachHash(read(REPO .. "/CLAUDE.md")),
  edits = { { section = "Git", old = "a", new = "b", why = "w", evidence = { "e" }, status = "skipped" },
            { section = "Git", old = "c", new = "d", why = "w", evidence = { "e" }, status = "applied", sha = "abc1234abc" } },
  decisions = { { what = "Keep bash", why = "portable", status = "skipped" }, { what = "Tabs", why = "w", status = "added" } } }
local brec = fx._coach.recs[REPO]
local p0 = core.coachView(brec).pending
local okB
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 1, "edits") end)
check("bring back: a skipped edit is pending again, and counts on the chip  (" .. tostring(p0) .. "->" .. tostring(core.coachView(brec).pending) .. ")",
      okB == true and brec.edits[1].status == "pending" and brec.edits[1].error == nil and core.coachView(brec).pending == p0 + 1)
local saved = json.decode(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json") or "{}") or {}
check("bring back: ...and that is saved", saved.edits and saved.edits[1] and saved.edits[1].status == "pending")
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 2, "edits") end)
check("bring back: an applied edit is not brought back (Undo is for that)", okB == false and brec.edits[2].status == "applied")
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 1, "edits") end)
check("bring back: a pending edit is left as it is", okB == false and brec.edits[1].status == "pending")
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 1, "decisions") end)
check("bring back: a skipped DECISIONS.md entry is pending again", okB == true and brec.decisions[1].status == "pending")
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 2, "decisions") end)
check("bring back: an added entry is not", okB == false and brec.decisions[2].status == "added")
quiet(function() okB = type(fx.coachUnskip) == "function" and fx.coachUnskip(REPO, 1, "history") end)
check("bring back: only edits and entries", okB == false)
end

-- 2026-10-02: the lessons ledger on a real repo. A skip was lost when the next run replaced the
-- record, so the coach never heard that Adam had said no (or why), and proposed it again.
-- (a function, not a do block: a do block's locals still count against the chunk's 200)
;(function()
local LFILE = CDIR .. "/" .. core.coachFileKey(REPO) .. ".lessons.json"
os.remove(LFILE)
fx._coach.lessons = nil
fx._coach.scans = {}
fx._headless["coach|" .. REPO] = nil
local CURL = read(REPO .. "/CLAUDE.md")
fx._coach.recs[REPO] = { v = 1, repo = COMMON, root = REPO, name = "repo", state = "done", verdict = "proposals",
  trigger = "card", at = 1000, doneAt = 1100, lastRunAt = 1100, claudeHash = core.coachHash(CURL),
  edits = { { section = "Git", old = "", new = "- never force-push", why = "A unit force-pushed.", evidence = { "e" }, status = "pending" },
            { section = "Tests", old = "", new = "- lint before the suite", why = "Lint failed late.", evidence = { "e" }, status = "pending" } },
  decisions = {} }
local lrec = fx._coach.recs[REPO]
local okS
quiet(function() okS = fx.coachSkip(REPO, 1, "  not now,\n too broad ") end)
check("lessons (repo): Skip keeps Adam's one-line reason on the edit, and when",
      okS == true and lrec.edits[1].status == "skipped" and lrec.edits[1].reason == "not now, too broad" and tonumber(lrec.edits[1].at) ~= nil)
local svd = json.decode(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".json") or "{}") or {}
check("lessons (repo): ...saved with the record", svd.edits and svd.edits[1] and svd.edits[1].reason == "not now, too broad")
local DSRC = read(ROOT .. "claude-dashboard.lua") or ""
check("lessons (repo): the overlay's Skip click reaches FX.coachSkip with its reason (core.coachSkipArgs)",
      DSRC:find('if a == "coach-skip" then FX.coachSkip(tostring(payload.v or ""), core.coachSkipArgs(tostring(payload.text or ""))); return end', 1, true) ~= nil)
local nC = #commitTasks()
quiet(function() okA = fx.coachApply(REPO, 2) end)
if commitTasks()[nC + 1] then runFor(commitTasks()[nC + 1]) end
local LL = core.parseCoachLessons and core.parseCoachLessons(read(LFILE)) or {}
check("lessons (repo): an Apply writes its lesson to <repo>.lessons.json at once  (" .. #LL .. ")",
      okA == true and #LL == 1 and LL[1].verdict == "applied" and LL[1].why == "Lint failed late." and lrec.edits[2].lesson == LL[1].id)
local HL = core.parseCoachHistory(read(HFILE))
check("lessons (repo): ...and its history entry names that lesson", HL[#HL] and LL[1] and HL[#HL].lesson == LL[1].id)
nC = #commitTasks()
quiet(function() okU = fx.coachUndo(REPO, #HL) end)
if commitTasks()[nC + 1] then runFor(commitTasks()[nC + 1]) end
LL = core.parseCoachLessons and core.parseCoachLessons(read(LFILE)) or {}
check("lessons (repo): Undo marks its lesson undone", okU == true and #LL == 1 and LL[1].verdict == "undone")
-- a new run replaces the record: the skip is folded into the ledger first
local nScans = #scans()
quiet(function() fx.coachStart(fx.coachRepoForRoot(REPO), "card", CFG) end)
LL = core.parseCoachLessons and core.parseCoachLessons(read(LFILE)) or {}
local skipL
for _, x in ipairs(LL) do if x.verdict == "skipped" then skipL = x end end
check("lessons (repo): a new run folds the skipped edit into the ledger before it replaces the record",
      skipL ~= nil and skipL.reason == "not now, too broad" and skipL.why == "A unit force-pushed." and #scans() == nScans + 1)
skipL = skipL or { id = "Lnone", runs = {} }
if scans()[nScans + 1] then runFor(scans()[nScans + 1]) end
local CC = claudes()
local ctl = CC[#CC] or { args = {}, cb = function() end }
local pf = tostring(ctl.args[3] or ""):match("< '([^']+)' >")
local ptext = pf and read(pf) or ""
check("lessons (repo): ...and that run's prompt carries the ledger, with Adam's reason",
      ptext:find("<lessons>", 1, true) ~= nil and ptext:find("not now, too broad", 1, true) ~= nil and ptext:find(skipL.id, 1, true) ~= nil)
answerClaude(ctl, { summary = "Again.", decisions = {},
  edits = { { section = "Git", old = "", new = "- never force-push, even your own branch", why = "Force-pushed again.", evidence = { "e" },
              lesson = skipL.id, whatsNew = "two more force-pushes this week" } } })
LL = core.parseCoachLessons and core.parseCoachLessons(read(LFILE)) or {}
local cited
for _, x in ipairs(LL) do if x.id == skipL.id then cited = x end end
check("lessons (repo): a proposal citing a lesson adds its run to it  (" .. #(cited and cited.runs or {}) .. ")", cited and #cited.runs == 2)
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local seenSent = false
for _, js in ipairs(jsCalls) do
  if js:find("ccCoach(", 1, true) and js:find('"seen":2', 1, true) and js:find("two more force-pushes this week", 1, true) then seenSent = true end
end
check("lessons (repo): ...and the overlay is told it was seen in 2 runs, with what is new", seenSent)
end)()

-- 2026-10-03: did the edit work? On a real repo: a run judges the applied edits enough sessions
-- postdate (the rest read "no data yet", whatever the model says), stores each verdict on its
-- history entry, and Sharpen runs the coach on one edit alone for a better wording of it.
;(function()
if type(core.coachEditsToJudge) ~= "function" then check("outcomes (repo): core.coachEditsToJudge exists", false); return end
local K = core.COACH.judgeSessions
for i = 2, K do write(pdir .. "/s" .. i .. ".jsonl", TR .. "\n") end   -- K sessions, each last active 2026-09-28
local CURO = "# Repo\n\n## Git\n\n- never push from a unit\n"
write(REPO .. "/CLAUDE.md", CURO); sh("git -C " .. q(REPO) .. " add -A && git -C " .. q(REPO) .. " commit -q -m outcomes")
local SHA_A = (sh("git -C " .. q(REPO) .. " rev-parse HEAD")):gsub("%s+$", "")
local SHA_B = "bbb2222bbbb2222"
os.remove(HFILE)
fx._coach.history = {}
fx._coach.recs[REPO] = nil
fx._coach.scans = {}
fx._headless["coach|" .. REPO] = nil
fx.coachHistorySave(REPO, {
  { sha = SHA_A, at = core.isoToEpoch("2026-09-27T00:00:00.000Z"), section = "Git", why = "Units pushed alone.", old = "",
    new = "- never push from a unit", before = "A unit ran git push when green.", after = "A unit asks Adam before it pushes." },
  { sha = SHA_B, at = core.isoToEpoch("2026-09-29T00:00:00.000Z"), section = "Tests", why = "Lint late.", old = "",
    new = "- lint first", before = "Lint ran last.", after = "Lint runs first." } })
local nScans = #scans()
quiet(function() fx.coachStart(fx.coachRepoForRoot(REPO), "card", CFG) end)
if scans()[nScans + 1] then runFor(scans()[nScans + 1]) end
local CC = claudes()
local ct = CC[#CC] or { args = {}, cb = function() end }
local pf = tostring(ct.args[3] or ""):match("< '([^']+)' >")
local ptext = pf and read(pf) or ""
local ab = ptext:match("<applied>\n(.-)\n</applied>") or ""
check("outcomes (repo): the run's prompt asks about the edit " .. K .. " sessions postdate, by its commit",
      ab:find(SHA_A:sub(1, 7), 1, true) ~= nil and ab:find("A unit asks Adam before it pushes.", 1, true) ~= nil)
check("outcomes (repo): ...and not the one no session postdates", not ab:find(SHA_B:sub(1, 7), 1, true))
answerClaude(ct, { summary = "Still pushing.", edits = {}, decisions = {},
  checks = { { sha = SHA_A:sub(1, 7), verdict = "still-seen", evidence = { "denied: git push origin main" } },
             { sha = SHA_B:sub(1, 7), verdict = "working", evidence = { "made up" } } } })
local OH = core.parseCoachHistory(read(HFILE))
local oh = {}
for _, x in ipairs(OH) do oh[x.sha] = x end
check("outcomes (repo): the judged edit's verdict and quotes are stored on its history entry",
      oh[SHA_A] and oh[SHA_A].check and oh[SHA_A].check.verdict == "still-seen" and oh[SHA_A].check.evidence[1] == "denied: git push origin main"
      and oh[SHA_A].check.since == K)
check("outcomes (repo): the edit too recent to judge reads no data yet, whatever the coach said",
      oh[SHA_B] and oh[SHA_B].check and oh[SHA_B].check.verdict == "no-data" and oh[SHA_B].check.since == 0)
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local verdictSent = false
for _, js in ipairs(jsCalls) do
  if js:find("ccCoach(", 1, true) and js:find('"still-seen"', 1, true) and js:find("denied: git push origin main", 1, true) then verdictSent = true end
end
check("outcomes (repo): ...and the overlay is sent them", verdictSent)
-- Sharpen: a run on that one edit
local DSRC = read(ROOT .. "claude-dashboard.lua") or ""
check("outcomes (repo): the overlay's Sharpen click reaches FX.coachSharpen with the entry's number",
      DSRC:find('if a == "coach-sharpen" then FX.coachSharpen(tostring(payload.v or ""), tostring(payload.text or "")); return end', 1, true) ~= nil)
local iA
for i, x in ipairs(OH) do if x.sha == SHA_A then iA = i end end
nScans = #scans()
local okS
quiet(function() okS = type(fx.coachSharpen) == "function" and fx.coachSharpen(REPO, tostring(iA)) end)
check("sharpen (repo): starts a run for the repo", okS == true and #scans() == nScans + 1)
local srec = fx.coachRecord(REPO)
check("sharpen (repo): ...whose record carries the commit it sharpens", srec and srec.sharpen == SHA_A)
if scans()[nScans + 1] then runFor(scans()[nScans + 1]) end
CC = claudes()
ct = CC[#CC] or { args = {}, cb = function() end }
pf = tostring(ct.args[3] or ""):match("< '([^']+)' >")
ptext = pf and read(pf) or ""
check("sharpen (repo): its prompt asks for a better wording of that edit alone, with its last check's quotes",
      (ptext:match("<sharpen>\n(.-)\n</sharpen>") or ""):find("- never push from a unit", 1, true) ~= nil
      and ptext:find("denied: git push origin main", 1, true) ~= nil and not ptext:find("<applied>", 1, true))
answerClaude(ct, { summary = "Sharper.", decisions = { { what = "Keep bash", why = "portable" } },
  edits = { { section = "Git", old = "- never push from a unit", new = "- a unit never runs git push; Adam pushes main",
              why = "Units still pushed.", evidence = { "denied: git push origin main" } },
            { section = "Git", old = "", new = "- something else", why = "w", evidence = { "e" } } },
  checks = { { sha = SHA_A:sub(1, 7), verdict = "working", evidence = { "x" } } } })
srec = fx.coachRecord(REPO)
check("sharpen (repo): its answer keeps one edit and no DECISIONS.md entry",
      srec and srec.verdict == "proposals" and #srec.edits == 1 and #srec.decisions == 0 and srec.sharpen == SHA_A)
OH = core.parseCoachHistory(read(HFILE))
oh = {}
for _, x in ipairs(OH) do oh[x.sha] = x end
check("sharpen (repo): ...and judges nothing", oh[SHA_A] and oh[SHA_A].check and oh[SHA_A].check.verdict == "still-seen")
local nC = #commitTasks()
local okA
quiet(function() okA = fx.coachApply(REPO, 1) end)
if commitTasks()[nC + 1] then runFor(commitTasks()[nC + 1]) end
OH = core.parseCoachHistory(read(HFILE))
oh = {}
for _, x in ipairs(OH) do oh[x.sha] = x end
check("sharpen (repo): applying the better wording commits it",
      okA == true and srec.edits[1].status == "applied" and (read(REPO .. "/CLAUDE.md") or ""):find("Adam pushes main", 1, true) ~= nil)
check("sharpen (repo): ...and the sharpened entry names the commit that replaced it",
      oh[SHA_A] and oh[SHA_A].sharpened and oh[SHA_A].sharpened.sha == srec.edits[1].sha and oh[srec.edits[1].sha or "?"] ~= nil)
local okU
quiet(function() okU = fx.coachSharpen(REPO, tostring(iA)) end)
check("sharpen (repo): an entry already sharpened isn't sharpened again", okU == false)
end)()

-- 2026-10-03 (mining round 2 unit B4): evidence runs and filed lessons on a real repo. A session files
-- a lesson with the real cc-lesson.sh; the tick puts it in the repo's coach log as `learned`. Then,
-- with this week's run done a day ago, enough new evidence (that lesson, plus the corrections in a
-- fresh transcript, counted by a background scan) starts an evidence run, whose cost counts toward
-- the daily cap; neither the cooldown nor a spent cap lets another start.
;(function()
if type(fx.stepLessons) ~= "function" then check("evidence (repo): FX.stepLessons exists", false); return end
local LDIR = T .. "/.claude/cc-lesson"
check("lesson (repo): FX.LESSON_DIR is ~/.claude/cc-lesson", fx.LESSON_DIR == LDIR)
local LOGF = CDIR .. "/" .. core.coachFileKey(REPO) .. ".log.json"
os.remove(LOGF)
local AROOT = (sh("cd " .. q(ROOT) .. " && pwd -P")):gsub("%s+$", "")
local out, code = sh("cd " .. q(REPO) .. " && HOME=" .. q(T) .. " CC_LESSON_DIR=" .. q(LDIR) .. " bash " .. q(AROOT .. "/cc-lesson.sh")
  .. " 'run make lint before make test'")
check("lesson (repo): cc-lesson.sh files the line  (" .. out:gsub("\n", " ") .. ")", code == 0)
-- (the panel's clock runs ahead of the real one here: each file's time is set on the panel's)
local function touchAt(path, at) sh("touch -t " .. os.date("%Y%m%d%H%M.%S", at) .. " " .. q(path)) end
write(LDIR .. "/1790000000-1.json.tmp.1", "{")   -- a write in progress: left alone
touchAt(LDIR .. "/1790000000-1.json.tmp.1", fx.now() - 5)
write(LDIR .. "/1790000000-3.json.tmp.3", "{")   -- one torn by a killed write, two minutes old: dropped
touchAt(LDIR .. "/1790000000-3.json.tmp.3", fx.now() - 120)
write(LDIR .. "/1790000000-2.json", "{not json")  -- garbage: dropped
quiet(function() fx.stepLessons() end)
local got
for _, e in ipairs(core.parseCoachLog(read(LOGF))) do if e.kind == "learned" then got = e end end
check("lesson (repo): the tick puts it in the repo's coach log as learned, with its branch",
      got ~= nil and got.note == "run make lint before make test" and got.branch == (sh("git -C " .. q(REPO) .. " branch --show-current")):gsub("%s+$", ""))
local left = (sh("ls -1 " .. q(LDIR))):gsub("%s+$", "")
check("lesson (repo): ...its file is taken, garbage dropped, a write in progress left  (" .. left:gsub("\n", " ") .. ")",
      left == "1790000000-1.json.tmp.1")
quiet(function() fx.stepLessons() end)
local n = 0
for _, e in ipairs(core.parseCoachLog(read(LOGF))) do if e.kind == "learned" then n = n + 1 end end
check("lesson (repo): ...and is logged once", n == 1)

-- the evidence trigger
local function evScans() return tasksWhere(function(t) return t.bin == "/bin/sh" and tostring(t.args[2] or ""):find("coach-evidence", 1, true) end) end
local function runScans() return tasksWhere(function(t) return t.bin == "/bin/sh" and tostring(t.args[2] or ""):find("coach-scan", 1, true) end) end
local LAST = fx.now() - 25 * 3600
local DAYN = os.date("%a", LAST):lower():sub(1, 3)   -- this week's slot is the day of the last run: the weekly run is done
local ECFG = { coach = { enabled = true, day = DAYN, maxBudgetUsd = 1, evidence = { minItems = 3, cooldownHours = 24, dailyUsd = 2 } } }
fx._coach.recs[REPO] = { v = 1, repo = COMMON, root = REPO, name = "repo", state = "done", verdict = "none", trigger = "weekly",
  at = LAST - 60, doneAt = LAST, lastRunAt = LAST, edits = {}, decisions = {} }
fx._coach.scans, fx._coach.waiting = {}, {}
fx._headless["coach|" .. REPO] = nil
-- the lesson came in AFTER the last run; so does a fresh transcript: asked, two corrections, an interrupt
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", t) end
local NOWR = fx.now()
write(pdir .. "/ev1.jsonl", table.concat({
  '{"type":"user","message":{"role":"user","content":"Tidy the coach"},"timestamp":"' .. iso(NOWR - 3000) .. '","origin":{"kind":"human"}}',
  '{"type":"user","message":{"role":"user","content":"no, keep the log section"},"timestamp":"' .. iso(NOWR - 2000) .. '","origin":{"kind":"human"}}',
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"' .. iso(NOWR - 1500) .. '"}',
  '{"type":"user","message":{"role":"user","content":"run the suite first"},"timestamp":"' .. iso(NOWR - 1000) .. '","origin":{"kind":"human"}}',
  "" }, "\n"))
local function estep() fx._coach.nextCheck = 0; stamp(); return quiet(function() fx.stepCoach(list, ECFG) end) end
local nE, nR = #evScans(), #runScans()
estep()
check("evidence (repo): the log alone isn't enough -- one count of the transcripts starts, no run  ("
      .. (#evScans() - nE) .. " count, " .. (#runScans() - nR) .. " run)", #evScans() == nE + 1 and #runScans() == nR)
estep()
check("evidence (repo): ...and isn't started twice while it runs", #evScans() == nE + 1 and #runScans() == nR)
if evScans()[nE + 1] then runFor(evScans()[nE + 1]) end
estep()
local erec = fx.coachRecord(REPO) or {}
check("evidence (repo): with the count in, an evidence run starts  (" .. tostring(erec.trigger) .. ")",
      #runScans() == nR + 1 and erec.trigger == "evidence")
check("evidence (repo): ...its record says how many new items started it (1 lesson + 3 from the transcript)  (" .. tostring(erec.evidence) .. ")",
      erec.evidence == 4)
if runScans()[nR + 1] then runFor(runScans()[nR + 1]) end
local CC = claudes()
answerClaude(CC[#CC] or { args = {}, cb = function() end }, { summary = "Nothing new.", edits = {}, decisions = {} })
erec = fx.coachRecord(REPO) or {}
local SPF = CDIR .. "/evidence-spend.json"
check("evidence (repo): it finishes like any run", erec.state == "done" and erec.verdict == "none" and erec.trigger == "evidence")
check("evidence (repo): ...and its cost counts toward today's cap  (" .. tostring(read(SPF)) .. ")",
      type(core.parseCoachSpend) == "function" and math.abs(core.coachSpendToday(core.parseCoachSpend(read(SPF)), fx.now()) - 0.21) < 1e-9)
-- three more lessons right away: the cooldown holds
for i = 1, 3 do fx.coachNote(COMMON, { kind = "learned", id = "learned|cool" .. i, branch = "main", note = "lesson " .. i }) end
nR = #runScans()
estep()
check("evidence (repo): not again within the cooldown, however much comes in", #runScans() == nR)
-- a day later, with today's cap spent: no run
OFFSET = OFFSET + 25 * 3600
for i = 1, 3 do fx.coachNote(COMMON, { kind = "learned", id = "learned|cap" .. i, branch = "main", note = "lesson " .. i }) end
write(SPF, json.encode({ day = os.date("%Y-%m-%d", fx.now()), usd = 2 }))
nE = #evScans()
estep()
check("evidence (repo): not once today's evidence runs spent coach.evidence.dailyUsd", #runScans() == nR)
os.remove(SPF)
estep()
check("evidence (repo): under the cap it runs, on the log alone -- no transcript count needed",
      #runScans() == nR + 1 and (fx.coachRecord(REPO) or {}).trigger == "evidence" and #evScans() == nE)
end)()

-- 2026-10-03 (mining round 2 unit B3): the coach reviews the repo's auto-memory, on a real folder. The
-- run reads the main checkout's memory (never through a link); Apply deletes or rewrites a file only
-- while it is as the coach read it, after backing it up in Shepherd's own folder, and keeps MEMORY.md's
-- lines in step; Undo restores from the backup; a promote is a CLAUDE.md edit; nothing outside the
-- folder is ever touched.
;(function()
if type(core.coachMemoryDir) ~= "function" or type(fx.coachMemoryApply) ~= "function" then
  check("memory (repo): core.coachMemoryDir and FX.coachMemoryApply exist", false); return
end
local MDIR = core.coachMemoryDir(PROJ, REPO)
os.execute("mkdir -p " .. q(MDIR))
local IDX = "# Memory Index\n\n- [Stale](stale.md) — an old fact\n- [Good](good.md) — still true\n- [Keep](keep.md) — fine\n"
local STALE = "---\nname: stale\n---\n\nThe panel uses hs.alert.show for messages.\n"
local GOOD = "---\nname: good\n---\n\nmake deploy = lint + test + install + reload.\n"
local KEEP = "---\nname: keep\n---\n\nTODO.md is gitignored.\n"
write(MDIR .. "/MEMORY.md", IDX); write(MDIR .. "/stale.md", STALE); write(MDIR .. "/good.md", GOOD); write(MDIR .. "/keep.md", KEEP)
local OUTSIDE = T .. "/outside.md"
local SECRET = "SECRET outside the memory folder\n"
write(OUTSIDE, SECRET)
sh("ln -s " .. q(OUTSIDE) .. " " .. q(MDIR .. "/linked.md"))
if sh("git -C " .. q(REPO) .. " status --porcelain -- CLAUDE.md"):match("%S") then sh("git -C " .. q(REPO) .. " commit -q -m wip -- CLAUDE.md") end
fx._coach.recs[REPO] = nil
fx._coach.scans, fx._coach.waiting, fx._coach.applying = {}, {}, nil
fx._headless["coach|" .. REPO] = nil
local nScans = #scans()
quiet(function() fx.coachStart(fx.coachRepoForRoot(REPO), "card", CFG) end)
if scans()[nScans + 1] then runFor(scans()[nScans + 1]) end
local CC = claudes()
local ct = CC[#CC] or { args = {}, cb = function() end }
local pf = tostring(ct.args[3] or ""):match("< '([^']+)' >")
local ptext = pf and read(pf) or ""
local mb = ptext:match("<memory>\n(.-)</memory>") or ""
check("memory (repo): the run's prompt carries the repo's auto-memory, MEMORY.md first",
      mb:find("--- MEMORY.md ---", 1, true) == 1 and mb:find("The panel uses hs.alert.show", 1, true) ~= nil and mb:find("TODO.md is gitignored.", 1, true) ~= nil)
check("memory (repo): ...never a link's target", not ptext:find("SECRET outside", 1, true) and not mb:find("linked.md", 1, true))
answerClaude(ct, { summary = "Memory.", edits = {}, decisions = {}, memory = {
  { file = "stale.md", action = "delete", why = "hs.alert.show is banned", evidence = { "Messages go through FX.alert" } },
  { file = "good.md", action = "rewrite", new = "---\nname: good\n---\n\nmake deploy = lint + test + install + reload, from main.\n",
    why = "From main only", evidence = { "deploy from main" } },
  { file = "keep.md", action = "keep", why = "still true", evidence = {} },
  { file = "keep.md", action = "promote", section = "Git", new = "- TODO.md is gitignored", why = "Every session needs it",
    evidence = { "TODO.md blocked worktree remove" } },
  { file = "linked.md", action = "delete", why = "w", evidence = { "e" } },
  { file = "../outside.md", action = "delete", why = "w", evidence = { "e" } } } })
local mrec = fx.coachRecord(REPO) or { memory = {}, edits = {} }
mrec.memory = mrec.memory or {}
check("memory (repo): the answer's memory rows land on the record -- none for a link or outside the folder  (" .. #mrec.memory .. ")",
      mrec.verdict == "proposals" and #mrec.memory == 3 and mrec.memory[1].status == "pending" and mrec.memory[3].status == "keep")
check("memory (repo): ...each with the text it read", mrec.memory[1].old == STALE)
check("memory (repo): ...a promote is a CLAUDE.md edit row, from its file", #mrec.edits == 1 and mrec.edits[1].fromMemory == "keep.md")
check("memory (repo): ...and the card counts the two changes and the edit", (core.coachTileInfo(mrec) or {}).pending == 3)

-- Apply a delete
local BDIR = CDIR .. "/" .. core.coachFileKey(REPO) .. ".memory-backup"
local nC = #commitTasks()
local okM
quiet(function() okM = fx.coachMemoryApply(REPO, 1) end)
check("memory apply (repo): a delete removes the file", okM == true and read(MDIR .. "/stale.md") == nil and mrec.memory[1].status == "applied")
check("memory apply (repo): ...backed up first, in Shepherd's own folder",
      type(mrec.memory[1].backup) == "string" and read(BDIR .. "/" .. tostring(mrec.memory[1].backup)) == STALE)
check("memory apply (repo): ...its MEMORY.md line goes, the others stay",
      read(MDIR .. "/MEMORY.md") == "# Memory Index\n\n- [Good](good.md) — still true\n- [Keep](keep.md) — fine\n")
check("memory apply (repo): ...and nothing is committed (memory isn't in git)", #commitTasks() == nC)
-- a rewrite, while a session has changed the file: refused
write(MDIR .. "/good.md", GOOD .. "A session's new line.\n")
quiet(function() okM = fx.coachMemoryApply(REPO, 2) end)
check("memory apply (repo): a rewrite is refused when a session changed the file since the coach read it",
      okM == false and read(MDIR .. "/good.md") == GOOD .. "A session's new line.\n" and mrec.memory[2].status == "pending"
      and mrec.memory[2].errorCode == "changed" and (core.coachView(mrec).memory[2] or {}).rerun == true)
write(MDIR .. "/good.md", GOOD)
quiet(function() okM = fx.coachMemoryApply(REPO, 2) end)
check("memory apply (repo): ...as the coach read it, the new text is written",
      okM == true and (read(MDIR .. "/good.md") or ""):find("from main.", 1, true) ~= nil and mrec.memory[2].status == "applied")
quiet(function() okM = fx.coachMemoryApply(REPO, 3) end)
check("memory apply (repo): a keep has nothing to apply", okM == false and read(MDIR .. "/keep.md") == KEEP)
-- Undo: the rewrite, then the delete (after a session added an index line)
quiet(function() okM = fx.coachMemoryUndo(REPO, 2) end)
check("memory undo (repo): Undo puts a rewritten file back from its backup",
      okM == true and read(MDIR .. "/good.md") == GOOD and mrec.memory[2].status == "undone")
write(MDIR .. "/MEMORY.md", read(MDIR .. "/MEMORY.md") .. "- [New](new.md) — a session's\n")
quiet(function() okM = fx.coachMemoryUndo(REPO, 1) end)
check("memory undo (repo): an undone delete brings the file back, its index line after the session's",
      okM == true and read(MDIR .. "/stale.md") == STALE and read(MDIR .. "/MEMORY.md")
      == "# Memory Index\n\n- [Good](good.md) — still true\n- [Keep](keep.md) — fine\n- [New](new.md) — a session's\n- [Stale](stale.md) — an old fact\n")
local LL = core.parseCoachLessons(read(CDIR .. "/" .. core.coachFileKey(REPO) .. ".lessons.json"))
local byS = {}
for _, l in ipairs(LL) do byS[l.section] = l end
check("memory lessons (repo): the ledger records the memory decisions",
      byS["memory/stale.md"] ~= nil and byS["memory/stale.md"].verdict == "undone" and byS["memory/good.md"] ~= nil)
-- the path check: a record changed behind Shepherd's back never reaches outside the folder, nor through a link
mrec.memory[4] = { file = "../outside.md", action = "delete", why = "w", evidence = { "e" }, status = "pending" }
quiet(function() okM = fx.coachMemoryApply(REPO, 4) end)
check("memory apply (repo): a file outside the memory folder is never touched", okM == false and read(OUTSIDE) == SECRET)
mrec.memoryHashes["linked.md"] = core.coachHash(SECRET)
mrec.memory[5] = { file = "linked.md", action = "rewrite", new = "pwned\n", why = "w", evidence = { "e" }, status = "pending" }
quiet(function() okM = fx.coachMemoryApply(REPO, 5) end)
check("memory apply (repo): ...nor a link's target", okM == false and read(OUTSIDE) == SECRET and mrec.memory[5].errorCode == "link")
-- Skip and Bring back
quiet(function() fx.coachMemorySkip(REPO, 5) end)
check("memory skip (repo): Skip puts a memory change aside", mrec.memory[5].status == "skipped")
quiet(function() fx.coachUnskip(REPO, 5, "memory") end)
check("memory skip (repo): ...Bring back puts it back", mrec.memory[5].status == "pending")
-- the promote: applied like any edit
local ok2
quiet(function() ok2 = fx.coachApply(REPO, 1) end)
if commitTasks()[nC + 1] then runFor(commitTasks()[nC + 1]) end
check("memory promote (repo): the promoted edit is applied to CLAUDE.md and committed",
      ok2 == true and mrec.edits[1].status == "applied" and (read(REPO .. "/CLAUDE.md") or ""):find("- TODO.md is gitignored", 1, true) ~= nil)
-- the overlay, and the clicks that reach the memory rows
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local sentM = false
for _, js in ipairs(jsCalls) do if js:find("ccCoach(", 1, true) and js:find('"memory"', 1, true) and js:find("stale.md", 1, true) then sentM = true end end
check("memory (repo): the overlay is sent the memory rows", sentM)
local DSRC = read(ROOT .. "claude-dashboard.lua") or ""
check("memory (repo): the overlay's memory clicks reach FX with the row's number",
      DSRC:find('if a == "coach-mem-apply" then FX.coachMemoryApply(tostring(payload.v or ""), tostring(payload.text or "")); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-mem-skip" then FX.coachMemorySkip(tostring(payload.v or ""), tostring(payload.text or "")); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-mem-unskip" then FX.coachUnskip(tostring(payload.v or ""), tostring(payload.text or ""), "memory"); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-mem-undo" then FX.coachMemoryUndo(tostring(payload.v or ""), tostring(payload.text or "")); return end', 1, true) ~= nil)
end)()

-- 2026-10-03 (mining round 2 unit B5): lessons applied in 2+ repos, on real files under a temp HOME.
-- ~/.claude/CLAUDE.md is a link here (to a dotfiles copy, as many people keep it): the write goes to its
-- target and the link stays. One grouping run in its own lane, at most daily; Apply only on a click,
-- refused once the file changed, backed up first outside any repo; Undo from that backup.
;(function()
if type(fx.coachGlobalStep) ~= "function" or type(fx.coachGlobalApply) ~= "function" then
  check("global (panel): FX.coachGlobalStep and FX.coachGlobalApply exist", false); return
end
local GDIR = T .. "/dotfiles"
os.execute("mkdir -p " .. q(GDIR))
local GTEXT = "# Global\n\n## Git\n\n- commit often\n"
write(GDIR .. "/CLAUDE.md", GTEXT)
os.remove(T .. "/.claude/CLAUDE.md")
sh("ln -s " .. q(GDIR .. "/CLAUDE.md") .. " " .. q(T .. "/.claude/CLAUDE.md"))
check("global (panel): the global CLAUDE.md is HOME's", fx.GLOBAL_CLAUDE_MD == T .. "/.claude/CLAUDE.md")
-- three repos the coach knows (their records name them): alpha, beta and this one, each with an
-- applied lesson; gamma has only a skipped one
local function L(id, text, at, th)
  return { id = id, section = "Worktrees", textHash = th or "a1b2c3", verdict = "applied", why = "w", text = text, at = at, runs = { at } }
end
local function seedRepo(root, name, lessons)
  local k = core.coachFileKey(root)
  write(CDIR .. "/" .. k .. ".json", json.encode({ v = 1, root = root, name = name, repo = root .. "/.git", state = "done", verdict = "none",
                                                   at = 1, edits = {}, decisions = {} }))
  write(CDIR .. "/" .. k .. ".lessons.json", json.encode(lessons))
end
local LA = { L("La1a1a1", "- never run make install from a worktree (alpha)", RNOW - 500) }
local LB = { L("Lb1b1b1", "- make install only from main (beta)", RNOW - 400), L("Lb2b2b2", "- run make lint before make test (beta)", RNOW - 300) }
seedRepo(T .. "/alpha", "alpha", LA)
seedRepo(T .. "/beta", "beta", LB)
seedRepo(T .. "/gamma", "gamma", { { id = "Lc1c1c1", section = "Git", textHash = "c1c1c1", verdict = "skipped", why = "w", text = "- skip me", at = 1, runs = {} } })
write(CDIR .. "/" .. core.coachFileKey(REPO) .. ".lessons.json", json.encode({ L("Ld1d1d1", "- never make install off main (repo)", RNOW - 450) }))
local function gruns() return tasksWhere(function(t) return tostring(t.args[3] or ""):find("cd '" .. CDIR .. "' ", 1, true) end) end
local function gstep(cfg) fx._coach.globalNext = 0; return quiet(function() fx.coachGlobalStep(cfg or CFG) end) end
fx._coach.global = nil
fx._headless["coach|global"] = nil
gstep({ coach = { enabled = false } })
check("global (panel): no run with the coach off", #gruns() == 0)
gstep()
local GR = gruns()
check("global (panel): with 2+ repos' applied lessons new, one grouping run starts  (" .. #GR .. ")", #GR == 1)
local gh = fx._headless["coach|global"]
check("global (panel): ...in its own lane, never a repo's", gh ~= nil and gh.lane == "coach|global")
local gcmd = tostring((GR[1] or { args = {} }).args[3] or "")
check("global (panel): ...a read-only Sonnet at a $1 cap",
      gcmd:find("claude -p --model sonnet", 1, true) ~= nil and gcmd:find("--max-budget-usd 1 ", 1, true) ~= nil)
local gpf = gcmd:match("< '([^']+)' >")
local gprompt = gpf and read(gpf) or ""
check("global (panel): its prompt carries every repo's applied lessons and the global CLAUDE.md, read through its link",
      gprompt:find("never run make install from a worktree (alpha)", 1, true) ~= nil and gprompt:find("make install only from main (beta)", 1, true) ~= nil
      and gprompt:find("never make install off main (repo)", 1, true) ~= nil and gprompt:find("- commit often", 1, true) ~= nil
      and not gprompt:find("skip me", 1, true))
gstep()
check("global (panel): not a second one while it runs", #gruns() == 1)
local rA, rR = gprompt:match("(r%d+/La1a1a1)"), gprompt:match("(r%d+/Ld1d1d1)")
local rB1, rB2 = gprompt:match("(r%d+/Lb1b1b1)"), gprompt:match("(r%d+/Lb2b2b2)")
answerClaude(GR[1] or { args = {}, cb = function() end }, { summary = "Two lessons learned twice.", groups = {
  { lessons = { rA, rB1, rR }, rule = "Never run make install from a worktree", why = "Three repos deployed unmerged code." },
  { lessons = { rB2, rA }, rule = "Run make lint before make test", why = "Lint failed late." },
  { lessons = { rB1, rB2 }, rule = "beta only", why = "one repo" } } })
local grec = fx.coachGlobalRecord() or { proposals = {} }
check("global (panel): the answer lands: two proposals, pending -- a group from one repo is dropped  (" .. #(grec.proposals or {}) .. ")",
      grec.verdict == "proposals" and #(grec.proposals or {}) == 2 and grec.proposals[1].status == "pending")
check("global (panel): ...on disk, in Shepherd's own folder", (core.parseCoachGlobalRecord(read(CDIR .. "/global.json")) or {}).verdict == "proposals")
-- the chip on a card whose repo's lesson is in one
fx._coach.scans, fx._coach.waiting = {}, {}
fx._headless["coach|" .. REPO] = nil
local base = (core.coachTileInfo(fx.coachRecord(REPO)) or { pending = 0 }).pending
stamp()
quiet(function() fx.stepCoach(list, { coach = { enabled = false } }) end)
check("global chip (panel): the card of a repo whose lesson is in a proposal counts it  (" .. tostring(c1.coach and c1.coach.pending) .. ")",
      c1.coach ~= nil and c1.coach.pending == base + 1)

-- Apply
local okG
quiet(function() okG = fx.coachGlobalApply("1") end)
local after1 = read(GDIR .. "/CLAUDE.md") or ""
check("global apply (panel): Apply writes the rule into a marked block at the end of the global CLAUDE.md",
      okG == true and after1:sub(1, #GTEXT) == GTEXT and after1:find(core.COACH_GLOBAL_START, 1, true) ~= nil
      and after1:find("- Never run make install from a worktree\n" .. core.COACH_GLOBAL_END, 1, true) ~= nil
      and grec.proposals[1].status == "applied")
check("global apply (panel): ...through the link: the link is still a link", hs.fs.symlinkAttributes(T .. "/.claude/CLAUDE.md", "mode") == "link")
local BK = CDIR .. "/global.claude-backup"
local bname = grec.proposals[1].backup
check("global apply (panel): ...backed up first, in Shepherd's own folder", type(bname) == "string" and read(BK .. "/" .. tostring(bname)) == GTEXT)
check("global apply (panel): ...and never mirrored into methodology/CLAUDE.md", not (read(ROOT .. "methodology/CLAUDE.md") or ""):find("shepherd-coach", 1, true))
-- a hand edit since: the second is refused, the file untouched
write(GDIR .. "/CLAUDE.md", after1 .. "- a hand edit\n")
quiet(function() okG = fx.coachGlobalApply("2") end)
check("global apply (panel): refused once the file changed since the run read it",
      okG == false and read(GDIR .. "/CLAUDE.md") == after1 .. "- a hand edit\n" and grec.proposals[2].errorCode == "changed"
      and grec.proposals[2].status == "pending" and core.coachGlobalView(grec, {}).proposals[2].rerun == true)
-- Undo: refused over the hand edit, then from the backup
quiet(function() okG = fx.coachGlobalUndo("1") end)
check("global undo (panel): refused while the file isn't what Shepherd wrote",
      okG == false and grec.proposals[1].status == "applied" and read(GDIR .. "/CLAUDE.md") == after1 .. "- a hand edit\n")
write(GDIR .. "/CLAUDE.md", after1)
quiet(function() okG = fx.coachGlobalUndo("1") end)
check("global undo (panel): Undo puts the file back from its backup", okG == true and read(GDIR .. "/CLAUDE.md") == GTEXT and grec.proposals[1].status == "undone")
check("global undo (panel): ...still through the link", hs.fs.symlinkAttributes(T .. "/.claude/CLAUDE.md", "mode") == "link")
quiet(function() okG = fx.coachGlobalSkip("2") end)
check("global skip (panel): Skip puts one aside", okG == true and grec.proposals[2].status == "skipped")

-- the daily clock, and new lessons
local nG = #gruns()
gstep()
check("global (panel): no new run the same day", #gruns() == nG)
OFFSET = OFFSET + 25 * 3600
gstep()
check("global (panel): a day later, with nothing new in 2+ repos: no run", #gruns() == nG)
LA[#LA + 1] = L("La3a3a3", "- a new alpha lesson", RNOW)
seedRepo(T .. "/alpha", "alpha", LA)
gstep()
check("global (panel): ...one repo's new lesson isn't enough", #gruns() == nG)
LB[#LB + 1] = L("Lb3b3b3", "- a new beta lesson", RNOW)
seedRepo(T .. "/beta", "beta", LB)
gstep()
check("global (panel): two repos' new lessons start the next run", #gruns() == nG + 1)
local p2t = gruns()[nG + 1] or { args = {}, cb = function() end }
local p2 = read(tostring(p2t.args[3] or ""):match("< '([^']+)' >") or "") or ""
check("global (panel): ...its prompt says what Adam decided before",
      (p2:match("<decided>\n(.-)\n</decided>") or ""):find("Never run make install from a worktree", 1, true) ~= nil)
answerClaude(p2t, { summary = "Nothing new across repos.", groups = {} })
check("global (panel): ...and nothing to group is an answer", (fx.coachGlobalRecord() or {}).verdict == "none")
nG = #gruns()
quiet(function() fx.coachGlobalRun() end)
check("global (panel): Run again starts one now, whatever the clock says", #gruns() == nG + 1)
answerClaude(gruns()[nG + 1] or { args = {}, cb = function() end }, { summary = "Still nothing.", groups = {} })

-- the overlay, and the clicks that reach it
jsCalls = {}
quiet(function() fx.pushCoach(REPO) end)
local sentG = false
for _, js in ipairs(jsCalls) do
  if js:find("ccCoach(", 1, true) and js:find('"global"', 1, true) and js:find("Run make lint before make test", 1, true) then sentG = true end
end
check("global (panel): the overlay is sent the Across repos section", sentG)
local DSRC = read(ROOT .. "claude-dashboard.lua") or ""
check("global (panel): the overlay's clicks reach FX with the proposal's number",
      DSRC:find('if a == "coach-global-apply" then FX.coachGlobalApply(tostring(payload.text or "")); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-global-skip" then FX.coachGlobalSkip(tostring(payload.text or "")); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-global-undo" then FX.coachGlobalUndo(tostring(payload.text or "")); return end', 1, true) ~= nil
      and DSRC:find('if a == "coach-global-run" then FX.coachGlobalRun(); return end', 1, true) ~= nil)
end)()

-- ---- across repos: a repo whose applied edits predate its lessons ledger still counts (2026-10-03) ----
-- 2026-10-03: FX.coachGlobalRepos listed only repos with a <key>.lessons.json. Edits applied before the
-- ledger existed live only in <key>.applied.json, so Adam's three repos with applied edits counted as
-- none, and no grouping run could start until each repo's own coach ran again.
;(function()
if type(fx.coachGlobalRepos) ~= "function" then check("global: FX.coachGlobalRepos exists", false); return end
local function seedHist(root, name, hist)
  local k = core.coachFileKey(root)
  write(CDIR .. "/" .. k .. ".json", json.encode({ v = 1, root = root, name = name, repo = root .. "/.git", state = "done", verdict = "none",
                                                   at = 1, edits = {}, decisions = {} }))
  write(CDIR .. "/" .. k .. ".applied.json", json.encode(hist))
  os.remove(CDIR .. "/" .. k .. ".lessons.json")
  return k
end
local kd = seedHist(T .. "/delta", "delta", { { sha = "abc1234def", at = RNOW - 900, section = "Git", why = "Units pushed.",
                                              old = "", new = "- never push from a unit (delta)" } })
local ke = seedHist(T .. "/epsilon", "epsilon", { { sha = "def5678abc", at = RNOW - 800, section = "Git", why = "Units pushed.",
                                                  old = "", new = "- never push from a unit (epsilon)" } })
local byKey = {}
for _, r in ipairs(fx.coachGlobalRepos()) do byKey[r.key] = r end
check("global: a repo with applied edits but no lessons ledger yet is listed", byKey[kd] ~= nil and byKey[ke] ~= nil)
local function applied(r) local n = 0 for _, l in ipairs(r and r.lessons or {}) do if l.verdict == "applied" then n = n + 1 end end return n end
check("global: ...its applied edits count as applied lessons  (" .. applied(byKey[kd]) .. "," .. applied(byKey[ke]) .. ")",
      applied(byKey[kd]) == 1 and applied(byKey[ke]) == 1)
local input = core.coachGlobalLessons({ byKey[kd], byKey[ke] }, {})
check("global: ...so two such repos are enough for a grouping run  (" .. tostring(input.repos) .. ")", (input.repos or 0) >= 2)
check("global: ...and nothing was written to their ledgers by listing them",
      read(CDIR .. "/" .. kd .. ".lessons.json") == nil and read(CDIR .. "/" .. ke .. ".lessons.json") == nil)
end)()

-- ---- line endings on an exact replace (2026-10-04) ----
-- 2026-10-04: an exact-match replace wrote `new` as the coach gave it, so a two-line edit put a
-- bare "\n" into a CRLF CLAUDE.md (the add and the re-wrapped paths already used the file's own).
;(function()
  local crlf = "# CLAUDE.md\r\n\r\n## Rules\r\n\r\n- old rule\r\n- keep this\r\n"
  local r = core.coachApplyDecision(crlf, core.coachHash(crlf),
    { old = "- old rule", new = "- new rule\n- another rule", section = "Rules" }, false)
  check("crlf: an exact replace into a CRLF file is applied", r.ok == true)
  check("crlf: ...in the file's own line endings, no bare newline  (" .. tostring(r.text):gsub("\r", "\\r"):gsub("\n", "\\n") .. ")",
        r.text == "# CLAUDE.md\r\n\r\n## Rules\r\n\r\n- new rule\r\n- another rule\r\n- keep this\r\n")
  local lf = "## Rules\n\n- old rule\n"
  local rl = core.coachApplyDecision(lf, core.coachHash(lf),
     { old = "- old rule", new = "- new rule\r\n- another rule", section = "Rules" }, false)
  check("crlf: ...and an LF file keeps LF", rl.text == "## Rules\n\n- new rule\n- another rule\n")
end)()

-- ---- a list item added under a wrapped last item (2026-10-04) ----
-- 2026-10-04: the add branch put a list item straight under a list only when the section's last
-- line was a list item; when that item wrapped onto an indented continuation line, the new item
-- got a blank line before it, splitting the list in two.
;(function()
  local base = "## Rules\n\n- first rule\n- second rule, long enough that it\n  wraps onto a second line\n"
  local r = core.coachApplyDecision(base, core.coachHash(base), { old = "", new = "- third rule", section = "Rules" }, false)
  check("list: an item added under a wrapped last item joins the list  (" .. tostring(r.text):gsub("\n", "\\n") .. ")",
        r.ok == true and r.text == "## Rules\n\n- first rule\n- second rule, long enough that it\n  wraps onto a second line\n- third rule\n")
  local para = "## Rules\n\nA paragraph that\n  is indented on its second line\n"
  local rp = core.coachApplyDecision(para, core.coachHash(para), { old = "", new = "- a rule", section = "Rules" }, false)
  check("list: ...but an item after a paragraph still gets its blank line",
        rp.ok == true and rp.text == "## Rules\n\nA paragraph that\n  is indented on its second line\n\n- a rule\n")
end)()

finish()
