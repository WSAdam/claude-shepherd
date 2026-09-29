-- skill-outcomes.test.lua : how often each skill works (2026-09-29, build program unit 35). Pure
-- cc-core, on literal transcript lines in the order and key order Claude Code writes them:
--   * the time index (unit 34, core.timeIndexFold) emits one episode per skill run -- a Skill
--     tool_use or a slash-skill prompt -- with its goal (the prompt that started the turn), its span
--     (the records carrying that attributionSkill) and its outcome (unit 9's turn label,
--     core.turnOutcome, over what the turn did from the invocation on), incrementally;
--   * core.skillOutcomes -- runs, ok, not ok and the ok-rate per skill, hand labels overriding;
--   * core.skillLabelsParse / skillLabelSet -- Adam's labels file (cc-skill-labels.json).
-- Run with plain `lua`. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"

local core = dofile(ROOT .. "cc-core.lua")
local json = dofile(HERE .. "support/json.lua")
core.json = json

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

-- ---- literal transcript records. T(n) = 2026-09-29T10:00:00Z + n seconds ----
local function T(n)
  local s = 36000 + n
  return string.format("2026-09-29T%02d:%02d:%02d.000Z", s // 3600, (s % 3600) // 60, s % 60)
end
local T0 = core.isoToEpoch(T(0))
local function attr(skill) return skill and ('"attributionSkill":"' .. skill .. '",') or "" end
local function side(sub) return sub and "true" or "false" end
-- a prompt: Adam's (kind "human"), another session's (kind "peer", isMeta) or a subagent's task
local function prompt(n, text, kind, sub)
  return '{"parentUuid":null,"isSidechain":' .. side(sub) .. ',"promptId":"p' .. n .. '","type":"user","message":{"role":"user","content":'
    .. json.encode(text) .. '},' .. (kind and ('"origin":{"kind":"' .. kind .. '"},') or "")
    .. (kind == "peer" and '"isMeta":true,' or "") .. '"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '","cwd":"/r"}'
end
-- a slash-skill as Claude Code writes it: <command-message> first, then the skill's body as a meta record
local function slash(n, name, args)
  local text = "<command-message>" .. name .. "</command-message>\n<command-name>/" .. name .. "</command-name>"
    .. (args and ("\n<command-args>" .. args .. "</command-args>") or "")
  return '{"parentUuid":"x","isSidechain":false,"promptId":"p' .. n .. '","type":"user","message":{"role":"user","content":'
    .. json.encode(text) .. '},"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '","origin":{"kind":"human"},"cwd":"/r"}'
end
-- a built-in command (/compact, /model): <command-name> first, no skill body after it
local function builtinSlash(n, name)
  local text = "<command-name>/" .. name .. "</command-name>\n            <command-message>" .. name
    .. "</command-message>\n            <command-args></command-args>"
  return '{"parentUuid":"x","isSidechain":false,"promptId":"p' .. n .. '","type":"user","message":{"role":"user","content":'
    .. json.encode(text) .. '},"uuid":"u' .. n .. '","timestamp":"' .. T(n) .. '","cwd":"/r"}'
end
local function meta(n, text, sub)
  return '{"parentUuid":"x","isSidechain":' .. side(sub) .. ',"promptId":"p","type":"user","message":{"role":"user","content":[{"type":"text","text":'
    .. json.encode(text or "skill body") .. '}]},"isMeta":true,"uuid":"m' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function assistantWith(n, content, skill, sub, stop)
  return '{"parentUuid":"x","isSidechain":' .. side(sub) .. ',"message":{"model":"claude-opus-5","id":"msg' .. n
    .. '","type":"message","role":"assistant","content":[' .. content .. '],"stop_reason":"' .. (stop or "tool_use")
    .. '","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}},'
    .. '"requestId":"r",' .. attr(skill) .. '"type":"assistant","uuid":"a' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function say(n, text, skill, sub, stop)
  return assistantWith(n, '{"type":"text","text":' .. json.encode(text) .. '}', skill, sub, stop or "end_turn")
end
local function use(n, id, name, input, skill, sub)
  return assistantWith(n, '{"type":"tool_use","id":"' .. id .. '","name":"' .. name .. '","input":' .. json.encode(input) .. ',"caller":{"type":"direct"}}', skill, sub)
end
local function skillUse(n, id, skill, attrSkill, sub) return use(n, id, "Skill", { skill = skill }, attrSkill, sub) end
local function result(n, id, text, isError, sub, extra)
  return '{"parentUuid":"x","isSidechain":' .. side(sub) .. ',"promptId":"p","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"'
    .. id .. '","content":' .. json.encode(text) .. (isError and ',"is_error":true' or "") .. '}]},"uuid":"t' .. n .. '","timestamp":"' .. T(n) .. '"'
    .. (extra or "") .. '}'
end
local function launched(n, id, skill, sub)
  return result(n, id, "Launching skill: " .. skill, false, sub, ',"toolUseResult":{"success":true,"commandName":"' .. skill .. '"}')
end
local function stopHook(n)
  return '{"parentUuid":"x","isSidechain":false,"type":"system","subtype":"stop_hook_summary","hookCount":3,"hookErrors":[],"preventedContinuation":false,"stopReason":"","hasOutput":true,"level":"suggestion","timestamp":"' .. T(n) .. '","uuid":"s' .. n .. '"}'
end
local function interrupt(n)
  return '{"parentUuid":"x","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"i' .. n .. '","timestamp":"' .. T(n) .. '"}'
end
local function lines(t) return table.concat(t, "\n") .. "\n" end
local function fold(text, sub)
  local e = core.timeIndexBlank(sub)
  e = core.timeIndexFold(e, text)
  return e
end
local function edit(n, id, skill, sub) return use(n, id, "Edit", { file_path = "/r/a.lua", old_string = "a", new_string = "b" }, skill, sub) end

-- ---- skill episodes (2026-09-29) ----

-- 1. a Skill tool_use: one episode, its goal the prompt that started the turn
local A = lines({
  prompt(0, "tidy the login module", "human"),
  say(2, "Let me load the skill first.", nil, false, "tool_use"),
  skillUse(3, "toolu_s1", "simplify"),
  launched(4, "toolu_s1", "simplify"),
  meta(4, "Review the changed code for reuse..."),
  edit(10, "toolu_e1", "simplify"),
  result(11, "toolu_e1", "The file has been updated."),
  say(20, "Tidied the module.", "simplify"),
  stopHook(21),
})
local e = fold(A)
local ep = e.episodes and e.episodes[1]
eq("a Skill tool_use is one episode", e.episodes and #e.episodes, 1)
eq("...of that skill", ep and ep.skill, "simplify")
eq("...invoked through the tool", ep and ep.via, "tool")
eq("...its id is the tool_use's", ep and ep.id, "toolu_s1")
eq("...its goal is the prompt that started the turn", ep and ep.goal, "tidy the login module")
eq("...it starts at the invocation", ep and ep.ts, T0 + 3)
eq("...its span ends at the last record carrying the skill", ep and ep.lastTs, T0 + 20)
eq("...which is two records", ep and ep.records, 2)
eq("...its outcome is the turn's label from the invocation on", ep and ep.outcome, "made progress")
eq("...the turn ended normally", ep and ep.exit, "done")
eq("...so it counts as ok", core.skillVerdict(ep), "ok")
eq("the index's own count is unchanged: one turn", e.turns, 1)
check("nothing is left open once the turn is labelled", e.skillOpen == nil)
check("...and the episode keeps no evidence", ep and ep.ev == nil and ep.evSt == nil)

-- 2. a slash-skill, interrupted: its goal is what was typed after the command
local B = lines({
  prompt(0, "earlier", "human"), say(1, "Sure."), stopHook(2),
  slash(10, "deep-research", "find a billing api"),
  meta(10, 'Run the "deep-research" workflow.'),
  say(15, "Researching.", "deep-research", false, "tool_use"),
  use(16, "toolu_w", "Workflow", { name = "deep-research", args = "billing api" }, "deep-research"),
  interrupt(20),
})
e = fold(B)
ep = e.episodes and e.episodes[1]
eq("a slash-skill is one episode", e.episodes and #e.episodes, 1)
eq("...of that skill", ep and ep.skill, "deep-research")
eq("...typed as a slash command", ep and ep.via, "slash")
eq("...its id is the prompt record's", ep and ep.id, "u10")
eq("...its goal is the command's arguments", ep and ep.goal, "find a billing api")
eq("...it starts at the prompt", ep and ep.ts, T0 + 10)
eq("...the turn was interrupted", ep and ep.exit, "interrupted")
eq("...its label still comes from what it did", ep and ep.outcome, "made progress")
eq("...but an interrupted run is not ok", core.skillVerdict(ep), "not ok")

-- 3. a slash-skill with no arguments reads as its command; a built-in command is no skill run
e = fold(lines({ slash(0, "improve"), meta(0, "Pull this repo's cards"), say(4, "Done.", "improve"), stopHook(5),
                 builtinSlash(10, "compact"), builtinSlash(20, "model") }))
eq("a built-in command (/compact, /model) is no episode", #e.episodes, 1)
eq("a slash-skill with no arguments: its goal is the command", e.episodes[1].goal, "/improve")

-- 4. no outcome yet: the turn is still running
e = fold(lines({ prompt(0, "draw the chart", "human"), skillUse(1, "toolu_d", "dataviz"), launched(2, "toolu_d", "dataviz"),
                 say(5, "Choosing the form.", "dataviz", false, "tool_use") }))
ep = e.episodes[1]
check("a run whose turn hasn't ended has no outcome yet", ep ~= nil and ep.outcome == nil and ep.exit == nil)
eq("...and no verdict", core.skillVerdict(ep), nil)
eq("...it stays open", e.skillOpen and #e.skillOpen, 1)

-- 5. nested: a skill invoked inside another skill's span -- each is its own run
e = fold(lines({
  prompt(0, "build the whole thing", "human"),
  skillUse(1, "toolu_outer", "rune:diamond"), launched(2, "toolu_outer", "rune:diamond"), meta(2),
  say(5, "Scoping first.", "rune:diamond", false, "tool_use"),
  skillUse(6, "toolu_inner", "rune:spec", "rune:diamond"), launched(7, "toolu_inner", "rune:spec"), meta(7),
  edit(10, "toolu_e2", "rune:spec"), result(11, "toolu_e2", "ok"),
  say(12, "Spec written.", "rune:spec"),
  stopHook(13),
}))
local outer, inner = e.episodes[1], e.episodes[2]
eq("a skill run inside another is its own episode", #e.episodes, 2)
check("...the outer one is the first invoked", outer and outer.skill == "rune:diamond" and inner and inner.skill == "rune:spec")
eq("...the outer span stops where the inner skill takes over", outer and outer.lastTs, T0 + 6)
eq("...the outer span is its own records", outer and outer.records, 2)
eq("...the inner span", inner and inner.records, 2)
eq("...the inner goal is the same prompt", inner and inner.goal, "build the whole thing")
check("...both are labelled at the turn's end", outer and outer.outcome == "made progress" and inner and inner.outcome == "made progress")

-- 6. a subagent's records carrying the parent's attributionSkill start no run of their own
e = fold(lines({ prompt(0, "search the web for billing APIs", nil, true),
                 say(1, "Searching.", "deep-research", true, "tool_use"),
                 use(2, "toolu_x", "WebSearch", { query = "q" }, "deep-research", true), result(3, "toolu_x", "hits", false, true),
                 say(4, "Found three.", "deep-research", true) }), true)
eq("a subagent inheriting the parent's skill starts no episode", #e.episodes, 0)

-- ...but a skill a subagent invokes itself is a run, labelled when the subagent answers
local SUB = lines({ prompt(0, "audit the checkout page", nil, true),
                    skillUse(1, "toolu_sub", "artifact-design", nil, true), launched(2, "toolu_sub", "artifact-design", true),
                    meta(2, "design lead", true),
                    say(3, "Reading the page.", "artifact-design", true, "tool_use"),
                    edit(4, "toolu_se", "artifact-design", true), result(5, "toolu_se", "ok", false, true) })
e = fold(SUB, true)
ep = e.episodes[1]
check("a subagent's own Skill tool_use is an episode", ep ~= nil and ep.skill == "artifact-design" and ep.sub == true)
eq("...its goal is the subagent's task", ep and ep.goal, "audit the checkout page")
eq("...no outcome while the subagent works", ep and ep.outcome, nil)
e = core.timeIndexFold(e, say(9, "Here is the audit.", "artifact-design", true, "end_turn") .. "\n")
eq("...labelled when the subagent gives its final answer", ep and ep.outcome, "made progress")
eq("...its span reaches that answer", ep and ep.lastTs, T0 + 9)

-- 7. things that only look like a skill run
e = fold(lines({
  prompt(0, "which tools are there", "human"),
  use(1, "toolu_ts", "ToolSearch", { query = "select:Skill" }),
  '{"parentUuid":"x","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ts","content":[{"type":"tool_reference","tool_name":"Skill"}]}]},"uuid":"t2","timestamp":"' .. T(2) .. '"}',
  say(3, 'The Skill tool takes {"name":"Skill","input":{"skill":"x"}} -- see above.'),
  use(4, "toolu_bad", "Skill", {}),
  stopHook(5),
}))
eq("a ToolSearch, a quoted tool call and a Skill call naming no skill are no runs", #e.episodes, 0)

-- 8. goals: a batch unit's turn is named for its unit; a long prompt is cut
e = fold(lines({ prompt(0, '<cross-session-message from="uds:/tmp/x.sock">Start unit feat/skill-outcomes in its own worktree: call EnterWorktree with name "skill-outcomes"</cross-session-message>', "peer"),
                 skillUse(1, "toolu_p", "simplify"), stopHook(2) }))
eq("a run in a turn another session started: its goal names the unit", e.episodes[1] and e.episodes[1].goal, "unit feat/skill-outcomes")
local long = string.rep("word ", 100)
e = fold(lines({ prompt(0, long, "human"), skillUse(1, "toolu_l", "simplify"), stopHook(2) }))
check("a long goal is cut to SKILL_GOAL_CHARS  (" .. tostring(e.episodes[1] and #e.episodes[1].goal) .. ")",
      e.episodes[1] and #e.episodes[1].goal <= core.SKILL_GOAL_CHARS)

-- 9. a transcript keeps its newest SKILL_EPISODES_PER_FILE runs
do
  local cap = core.SKILL_EPISODES_PER_FILE
  core.SKILL_EPISODES_PER_FILE = 3
  local recs = {}
  for i = 1, 5 do
    local n = i * 10
    recs[#recs + 1] = prompt(n, "goal " .. i, "human")
    recs[#recs + 1] = skillUse(n + 1, "toolu_c" .. i, "simplify")
    recs[#recs + 1] = say(n + 2, "ok", "simplify")
    recs[#recs + 1] = stopHook(n + 3)
  end
  e = fold(lines(recs))
  core.SKILL_EPISODES_PER_FILE = cap
  eq("a transcript keeps only its newest runs", #e.episodes, 3)
  eq("...the oldest go first", e.episodes[1].id, "toolu_c3")
end

-- 10. incremental: read in pieces (torn lines, a split mid-episode) it indexes what one read does
local function sig(entry)
  local out = {}
  for _, x in ipairs(entry.episodes) do
    out[#out + 1] = table.concat({ x.id, x.skill, x.via, tostring(x.goal), x.ts, x.lastTs, x.records, tostring(x.outcome), tostring(x.exit) }, "|")
  end
  return table.concat(out, "\n")
end
local ALL = A .. B .. lines({ prompt(40, "draw it", "human"), skillUse(41, "toolu_z", "dataviz"), launched(42, "toolu_z", "dataviz"),
                              say(43, "Drawing.", "dataviz", false, "tool_use") })
local whole = fold(ALL)
for _, chunk in ipairs({ 57, 300, 1024 }) do
  local ent, guard = nil, 0
  local offset = 0
  while offset < #ALL and guard < 10000 do
    guard = guard + 1
    local len = chunk
    local before = offset
    while true do
      local text = ALL:sub(offset + 1, offset + len)
      local read = { from = offset, size = #ALL, mtime = 1, fresh = (ent == nil) or nil, cap = core.TIME_INDEX_FILE_BYTES }
      local nextE = core.timeIndexApply(ent, read, text)
      if nextE.offset > before or offset + len >= #ALL then ent = nextE; offset = nextE.offset; break end
      len = len * 2
    end
    if offset == before then break end
  end
  check("read " .. chunk .. " bytes at a time: the same runs as one read", ent ~= nil and sig(ent) == sig(whole))
end
check("...(the whole read holds all three runs, the last still open)", #whole.episodes == 3 and whole.episodes[3].outcome == nil)
local fresh = core.timeIndexApply(whole, { from = 0, size = 10, mtime = 2, fresh = true }, "")
eq("a rewritten transcript starts its runs over", #fresh.episodes, 0)

-- ---- the ok-rate (2026-09-29) ----
local function run_(id, outcome, exit, ts)
  return { id = id, skill = "simplify", via = "tool", goal = "g " .. id, ts = T0 + ts, lastTs = T0 + ts + 30, records = 2,
           outcome = outcome, exit = exit }
end
local EPS = {
  run_("r1", "done", "done", 1), run_("r2", "made progress", "done", 2), run_("r3", "blocked", "done", 3),
  run_("r4", "needs follow-up", "done", 4), run_("r5", nil, nil, 5), run_("r6", "made progress", "interrupted", 6),
}
local out = core.skillOutcomes({ { key = "k1", session = "one", episodes = EPS } }, nil)
local s = out.bySkill.simplify
eq("every run counts", s and s.runs, 6)
eq("done and made progress are ok", s and s.ok, 2)
eq("blocked and an interrupted run are not ok", s and s.notOk, 2)
eq("the rate is over the judged runs", s and s.rate, 50)
eq("...a running one and one that asked for follow-up aren't judged", s and s.open, 2)
eq("the viewer's words", s and s.text, "6 runs · 50% ok")
eq("rows are newest first", s and s.rows[1].id, "r6")
eq("...with the session they ran in", s and s.rows[1].session, "one")
eq("...and their duration", s and s.rows[1].seconds, 30)

local LABELS = { r4 = { verdict = "ok" }, r3 = { verdict = "ok" }, nope = { verdict = "not ok" }, r2 = { verdict = "maybe" } }
out = core.skillOutcomes({ { key = "k1", session = "one", episodes = EPS } }, LABELS)
s = out.bySkill.simplify
eq("a hand label overrides the derived outcome", s and s.ok, 4)
eq("...not ok is what's left", s and s.notOk, 1)
eq("...the rate follows", s and s.rate, 80)
eq("...two runs carry a hand label (an unknown id and a bad verdict are ignored)", s and s.labelled, 2)
local r3
for _, r in ipairs(s and s.rows or {}) do if r.id == "r3" then r3 = r end end
check("...a row shows both the label and what it would have been", r3 and r3.label == "ok" and r3.derived == "not ok" and r3.verdict == "ok")

out = core.skillOutcomes({ { key = "k1", session = "one", episodes = { EPS[1] } }, { key = "k2", session = "two", episodes = { EPS[1], EPS[5] } } }, nil)
eq("a run copied into a resumed session's transcript counts once", out.bySkill.simplify.runs, 2)
eq("...and in the rate once", out.bySkill.simplify.rate, 100)
out = core.skillOutcomes({ { episodes = { EPS[5] } } }, nil)
eq("one running run reads as such", out.bySkill.simplify.text, "1 run · running")
out = core.skillOutcomes({ { episodes = { EPS[4] } } }, nil)
eq("runs none of which is judged", out.bySkill.simplify.text, "1 run · not judged")
eq("...and have no rate", out.bySkill.simplify.rate, nil)
do
  local many = {}
  for i = 1, core.SKILL_RUNS_SHOWN + 5 do many[#many + 1] = run_("m" .. i, "done", "done", i) end
  out = core.skillOutcomes({ { episodes = many } }, nil)
  eq("the runs list is capped", #out.bySkill.simplify.rows, core.SKILL_RUNS_SHOWN)
  eq("...but every run is counted", out.bySkill.simplify.runs, core.SKILL_RUNS_SHOWN + 5)
end

-- ---- Adam's labels file (2026-09-29) ----
local st = core.skillLabelsParse(nil)
check("no labels file reads as no labels", type(st) == "table" and st.v == 1 and next(st.labels) == nil)
check("a garbled one too", next(core.skillLabelsParse("{not json").labels) == nil)
st = core.skillLabelsParse('{"v":1,"labels":{"toolu_a":{"verdict":"ok","skill":"simplify","ts":5},"toolu_b":{"verdict":"meh"},"../x":{"verdict":"ok"}}}')
check("a label with an unknown verdict or a bad id is dropped", st.labels.toolu_a and st.labels.toolu_a.verdict == "ok"
      and st.labels.toolu_b == nil and st.labels["../x"] == nil)
local ok = core.skillLabelSet(st, "toolu_c", "not ok", "dataviz", 100)
check("a label is set", ok == true and st.labels.toolu_c.verdict == "not ok" and st.labels.toolu_c.skill == "dataviz" and st.labels.toolu_c.ts == 100)
ok = core.skillLabelSet(st, "toolu_c", "clear", "dataviz", 101)
check("...and cleared", ok == true and st.labels.toolu_c == nil)
local bad, why = core.skillLabelSet(st, "toolu_c", "maybe", "x", 1)
check("an unknown verdict is refused  (" .. tostring(why) .. ")", bad == false and st.labels.toolu_c == nil)
check("an id that isn't one is refused", core.skillLabelSet(st, "../../etc", "ok", "x", 1) == false
      and core.skillLabelSet(st, "", "ok", "x", 1) == false and core.skillLabelSet(st, string.rep("a", 200), "ok", "x", 1) == false)
local round = core.skillLabelsParse(json.encode(st))
check("the file round-trips", round.labels.toolu_a and round.labels.toolu_a.verdict == "ok")

print(string.format("-- skill-outcomes.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
