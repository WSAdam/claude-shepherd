-- brief-flags.test.lua : the brief pre-flight -- a batch's briefs are scanned for risky asks
-- before Adam approves (2026-10-03, mining round 2 unit E3). Pure core logic.
--
-- core.briefFlags(task) reads a unit's FULL brief (parseBatch keeps 4000 characters; the review
-- shows 300) for force push, push to main, deleting or skipping tests, rm -rf, secrets, and CI or
-- deploy files. It is negation-aware like the merge claim check (CLAIM_NEG): "never git push" and
-- "don't skip tests" are not asks. core.batchBriefFlags adds what only the whole batch shows: two
-- units citing the same file, and more than one unit changing hook wiring. core.batchView puts it
-- all in the review while the batch is proposed. Advisory only: Approve is never held by it.
--
-- tests/fixtures/brief-flags.tsv is the one table both scanners answer to (cc-fleet.sh's jq
-- mirror reads it in tests/fleet.test.sh).
--
-- Usage: lua tests/brief-flags.test.lua

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local core = dofile(ROOT .. "cc-core.lua")
core.json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want) check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want) end
local function finish() print("-- brief-flags.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

check("core.briefFlags and core.batchBriefFlags exist", type(core.briefFlags) == "function" and type(core.batchBriefFlags) == "function")
if type(core.briefFlags) ~= "function" or type(core.batchBriefFlags) ~= "function" then finish() end

local function ids(flags)
  local t = {}
  for _, f in ipairs(flags or {}) do t[#t + 1] = f.id end
  return #t > 0 and table.concat(t, ",") or "-"
end

-- ---- the shared table (2026-10-03) ----
do
  local fh = io.open(HERE .. "fixtures/brief-flags.tsv", "r")
  check("tests/fixtures/brief-flags.tsv is there", fh ~= nil)
  local n = 0
  for line in (fh and fh:lines() or function() return nil end) do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local want, brief = line:match("^([^\t]+)\t(.*)$")
      if want then
        n = n + 1
        brief = brief:gsub("\\n", "\n")
        eq("brief-flags.tsv: " .. want .. "  " .. line:match("\t(.*)$"), ids(core.briefFlags(brief)), want)
      end
    end
  end
  if fh then fh:close() end
  check("...and holds a real number of cases (" .. n .. ")", n >= 40)
end

-- ---- a flag says what it is and quotes the brief (2026-10-03) ----
do
  local f = core.briefFlags("Implement the thing.\nWhen it's done, rebase and git push --force origin feat/x so CI reruns.")
  eq("a flag has its id", f[1] and f[1].id, "force-push")
  eq("...a label Adam reads", f[1] and f[1].label, "force push")
  check("...and quotes the words that raised it  (" .. tostring(f[1] and f[1].quote) .. ")",
        f[1] and f[1].quote:find("git push --force origin feat/x", 1, true) ~= nil)
  -- the scan reads the whole brief, never the review's 300-character cut
  local long = string.rep("Read the plan and the repo notes first. ", 20) .. "Then rm -rf build/ before you start."
  check("the full brief is scanned, past the review's 300-character cut (" .. #long .. " chars)", #long > 300 and ids(core.briefFlags(long)) == "rm-rf")
  local q = core.briefFlags(long)[1]
  check("...a quote from deep in a long brief is a short window around the words  (" .. tostring(q and q.quote) .. ")",
        q and q.quote:find("rm -rf build/", 1, true) ~= nil and #q.quote <= 160)
  eq("a brief with nothing risky has no flags", #core.briefFlags("Add a toggle to the settings panel, with tests."), 0)
  eq("...nor does an empty or missing one", #core.briefFlags("") + #core.briefFlags(nil), 0)
  -- one flag per kind, however often the brief says it
  eq("one flag per kind", ids(core.briefFlags("rm -rf a. Then rm -rf b. Then rm -fr c.")), "rm-rf")
end

-- ---- what only the whole batch shows (2026-10-03) ----
local UNITS = {
  { slug = "alpha", task = "Add the hook in settings-hooks.json and cc-core.lua:2933. Extend tests/fleet.test.sh. Read ~/.claude/plans/p.md first." },
  { slug = "beta",  task = "Wire install.sh; extend cc-core.lua and tests/core.test.lua. Update TODO.md and CHANGELOG.md, and fleet.test.sh. Read ~/.claude/plans/p.md first." },
  { slug = "gamma", task = "Docs only: docs/fleet.md. Don't touch cc-core.lua. Follow the tests/*.test.lua pattern." },
}
do
  local bf = core.batchBriefFlags(UNITS)
  local byFile, hook = {}, nil
  for _, f in ipairs(bf) do
    if f.id == "same-file" then byFile[f.file] = table.concat(f.units, ",") end
    if f.id == "hook-wiring" then hook = f end
  end
  eq("same file: cc-core.lua is cited by alpha and beta (gamma says not to touch it)", byFile["cc-core.lua"], "alpha,beta")
  eq("same file: fleet.test.sh and tests/fleet.test.sh are one file, named the longer way", byFile["tests/fleet.test.sh"], "alpha,beta")
  eq("same file: a file only one unit cites isn't flagged", byFile["tests/core.test.lua"], nil)
  eq("same file: TODO.md and CHANGELOG.md are shared by every unit on purpose", byFile["TODO.md"] or byFile["CHANGELOG.md"], nil)
  eq("same file: a path outside the repo (the plan) isn't the repo's file", byFile["~/.claude/plans/p.md"] or byFile["p.md"], nil)
  eq("same file: a glob isn't a file", byFile["*.test.lua"] or byFile[".test.lua"], nil)
  check("hook wiring: two units changing it is flagged", hook ~= nil)
  eq("...naming both", hook and table.concat(hook.units, ","), "alpha,beta")
  check("...and the hook files say so once, not again as a same-file flag", byFile["install.sh"] == nil and byFile["settings-hooks.json"] == nil)
  check("...its line says a batch takes one  (" .. tostring(hook and hook.line) .. ")",
        hook and hook.line:find("hook wiring", 1, true) and hook.line:find("settings-hooks.json", 1, true) and hook.line:find("install.sh", 1, true))
  local one = core.batchBriefFlags({ UNITS[1], UNITS[3] })
  local anyHook = false
  for _, f in ipairs(one) do if f.id == "hook-wiring" then anyHook = true end end
  check("hook wiring: one unit alone is fine", not anyHook)
  eq("a lone unit has no batch flags", #core.batchBriefFlags({ UNITS[1] }), 0)
end

-- 2026-10-04: every batch's review said "cc-merge.sh is cited by <every unit>": each brief ends with
-- the same merge steps ("... run `cc-merge.sh done --result merged` ..."). A sentence every unit's
-- brief says word for word is boilerplate; a file it names isn't a file the units share.
do
  local TAIL = " After the ff, run `cc-merge.sh done --result merged`, then report the sha."
  local function sameFiles(units)
    local out = {}
    for _, f in ipairs(core.batchBriefFlags(units)) do if f.id == "same-file" then out[#out + 1] = f.file end end
    table.sort(out); return table.concat(out, ",")
  end
  eq("boilerplate: a file only the shared merge steps name isn't flagged", sameFiles({
    { slug = "alpha", task = "Change cc-core.lua for the badge." .. TAIL },
    { slug = "beta",  task = "Docs only: docs/fleet.md." .. TAIL } }), "")
  eq("...nor when one unit also edits it, while the other only has the boilerplate", sameFiles({
    { slug = "alpha", task = "Fix the refusal in cc-merge.sh." .. TAIL },
    { slug = "beta",  task = "Docs only: docs/fleet.md." .. TAIL } }), "")
  eq("...and a unit's own words count even after the boilerplate named the file first", sameFiles({
    { slug = "alpha", task = TAIL .. " Then fix the refusal in cc-merge.sh." },
    { slug = "beta",  task = TAIL .. " Then add a --dry-run flag to cc-merge.sh." } }), "cc-merge.sh")
  eq("...but two units naming it in their own words still are", sameFiles({
    { slug = "alpha", task = "Fix the refusal in cc-merge.sh." .. TAIL },
    { slug = "beta",  task = "Add a --dry-run flag to cc-merge.sh." .. TAIL } }), "cc-merge.sh")
  eq("...and a shared sentence only SOME units say is no boilerplate", sameFiles({
    { slug = "alpha", task = "Extend cc-core.lua." },
    { slug = "beta",  task = "Extend cc-core.lua." },
    { slug = "gamma", task = "Docs only: docs/fleet.md." } }), "cc-core.lua")
end

-- ---- in the batch review (2026-10-03) ----
local function bj(units, phase)
  local us = {}
  for _, u in ipairs(units) do us[#us + 1] = { type = "feat", slug = u.slug, task = u.task, branch = "feat/" .. u.slug } end
  return core.json.encode({ v = 1, id = "b1", nonce = "n1", driver = { session_id = "drv", pid = "4242", name = "A-drv" },
    repo = "/r/A", commonDir = "/r/A/.git", title = "Three", mergeWhenGreen = true, at = 100, phase = phase or "proposed", units = us })
end
do
  local risky = { { slug = "alpha", task = UNITS[1].task .. " When green, git push --force." }, UNITS[2],
                  { slug = "gamma", task = UNITS[3].task .. " Never rm -rf anything." } }
  local b = core.parseBatch(bj(risky))
  check("parse: a batch with risky briefs still parses", b ~= nil)
  if not b then finish() end
  local v = core.batchView(b, nil, {})
  local pf = v.preflight
  check("view: a proposed batch carries its pre-flight", type(pf) == "table")
  pf = pf or {}
  eq("view: it counts every flag, per brief and across the batch", pf.count, 4)
  check("view: its line says advisory  (" .. tostring(pf.line) .. ")", type(pf.line) == "string" and pf.line:find("advisory", 1, true) ~= nil)
  local rows = table.concat(pf.rows or {}, "\n")
  check("view: a brief's flag names its unit, the flag and the words  (" .. rows .. ")",
        rows:find("alpha: force push", 1, true) and rows:find("git push --force", 1, true))
  check("view: a negated ask isn't listed (gamma says never rm -rf, and not to touch cc-core.lua)", not rows:find("gamma", 1, true))
  check("view: the batch flags are listed too", rows:find("cc-core.lua", 1, true) and rows:find("hook wiring", 1, true))
  eq("view: advisory only -- the batch stays approvable", v.approvable, true)
  check("view: the card line counts the flags  (" .. tostring(v.line) .. ")", v.line:find("4 pre-flight flags", 1, true) ~= nil)
  -- once approved, the scan has done its job
  local va = core.batchView(b, { approved = true }, {})
  eq("view: an approved batch shows no pre-flight", va.preflight, nil)
  -- a clean batch says the scan ran
  local clean = core.parseBatch(bj({ { slug = "one", task = "Add a toggle, with tests." }, { slug = "two", task = "Fix the tooltip in docs/fleet.md." } }))
  local vc = clean and core.batchView(clean, nil, {})
  check("view: a clean batch's line says nothing risky was found  (" .. tostring(vc and vc.preflight and vc.preflight.line) .. ")",
        vc and vc.preflight and vc.preflight.count == 0 and vc.preflight.line:find("no risky", 1, true) ~= nil)
  check("view: ...and its card line has no flag count", vc and not vc.line:find("pre-flight", 1, true))
end

-- ---- it stays cheap: 8 briefs of 4000 characters (2026-10-03) ----
-- parseBatch runs when a proposal file changes, never every tick; still, a Lua pattern over
-- text can go quadratic (the 2026-09 firstPromptFromTranscript freeze). A generous bound.
do
  local chunk = "Read cc-core.lua and claude-dashboard.lua, then never git push, rm -rf, reset --hard; add tests/x.test.lua. "
  local brief = string.rep(chunk, math.floor(4000 / #chunk))
  local units = {}
  for i = 1, 8 do units[i] = { slug = "u" .. i, task = brief } end
  local t0 = os.clock()
  for _, u in ipairs(units) do core.briefFlags(u.task) end
  core.batchBriefFlags(units)
  local ms = (os.clock() - t0) * 1000
  check(string.format("8 full briefs scan in well under a tick (%.1f ms)", ms), ms < 250)
end

finish()
