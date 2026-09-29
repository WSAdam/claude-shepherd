-- overlap.test.lua : the overlap radar and a batch's blockedBy order (2026-09-29, build program
-- unit 24). Pure core logic, plus one section that runs the radar's real shell program against a
-- real temp git repo with two linked worktrees.
--
-- blockedBy: a batch unit may name the units it waits for. The proposal is refused when it names
-- an unknown unit or goes in a circle; a waiting unit's tab doesn't open ("waits for X") and its
-- merge isn't ready until every blocker has merged; a unit whose blocker ended blocked counts as
-- "blocked by a blocked unit", so the batch can still finish. covers and packet ride along.
--
-- Radar: per repo, each linked worktree's changed files (its branch diff + dirty + untracked)
-- and, per pair, `git merge-tree --write-tree --name-only` conflicts. Overlap pairs and a
-- merge-order hint go to the tiles, Instances and the merge review.
--
-- Usage: lua tests/overlap.test.lua

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
local function finish() print("-- overlap.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end
local function join(t) return table.concat(t or {}, ",") end

-- ---- blockedBy, covers and packet in a batch file (2026-09-29) ----
-- A proposal as cc-fleet.sh writes it; `units` overrides the three default units.
local function bj(units, over)
  local t = { v = 1, id = "b1757", nonce = "n1", driver = { session_id = "drv", pid = "4242", name = "repo-drv" },
              repo = "/r/main", commonDir = "/r/main/.git", title = "Three steps", mergeWhenGreen = true,
              units = units or {
                { type = "feat", slug = "alpha", task = "Add alpha.", branch = "feat/alpha" },
                { type = "feat", slug = "beta", task = "Build on alpha.", branch = "feat/beta", blockedBy = { "alpha" },
                  covers = { "BUG-3", "REQ-001" }, packet = "p1" },
                { type = "fix", slug = "gamma", task = "Fix gamma.", branch = "fix/gamma", blockedBy = { "beta" } } },
              at = 100, phase = "approved" }
  for k, v in pairs(over or {}) do t[k] = v end
  return core.json.encode(t)
end
local function unit(slug, blockedBy)
  return { type = "feat", slug = slug, task = "t", branch = "feat/" .. slug, blockedBy = blockedBy }
end

do
  local b = core.parseBatch(bj())
  check("batch: a proposal with blockedBy, covers and packet parses", b ~= nil)
  if not b then finish() end
  eq("batch: a unit keeps its blockers", join(b.units[2].blockedBy), "alpha")
  eq("batch: ...and what it covers", join(b.units[2].covers), "BUG-3,REQ-001")
  eq("batch: ...and its packet", b.units[2].packet, "p1")
  eq("batch: a unit with no blockers has an empty list", #b.units[1].blockedBy, 0)
  check("batch: ...and no covers or packet", b.units[1].covers == nil and b.units[1].packet == nil)

  -- 2026-09-29: batch files written before unit 24 have none of the three fields; they must parse
  local old = core.parseBatch(core.json.encode({ v = 1, id = "b1", nonce = "n1", driver = { session_id = "drv" },
    repo = "/r/main", commonDir = "/r/main/.git", title = "Old", phase = "approved", at = 1,
    units = { { type = "feat", slug = "alpha", task = "t", branch = "feat/alpha" },
              { type = "fix", slug = "beta", task = "t", branch = "fix/beta" } } }))
  check("batch: an old batch file without the new fields still parses", old ~= nil and #old.units == 2)
  check("batch: ...and nothing in it waits", old and #old.units[1].blockedBy == 0 and #old.units[2].blockedBy == 0)

  for what, units in pairs({
    ["a blocker that isn't one of its units"] = { unit("alpha"), unit("beta", { "zeta" }) },
    ["a unit waiting for itself"] = { unit("alpha", { "alpha" }) },
    ["a two-unit cycle"] = { unit("alpha", { "beta" }), unit("beta", { "alpha" }) },
    ["a three-unit cycle"] = { unit("alpha", { "gamma" }), unit("beta", { "alpha" }), unit("gamma", { "beta" }) },
    ["a blockedBy that isn't a list"] = { unit("alpha"), unit("beta", "alpha") },
    ["a blocker that isn't a slug"] = { unit("alpha"), unit("beta", { "Alpha Unit" }) },
  }) do
    check("batch: refuses " .. what, core.parseBatch(bj(units)) == nil)
  end
  local badCovers = unit("alpha"); badCovers.covers = "BUG-3"
  check("batch: refuses covers that aren't a list", core.parseBatch(bj({ badCovers })) == nil)
  local badPacket = unit("alpha"); badPacket.packet = "p1; rm -rf /"
  check("batch: refuses a packet id with shell characters in it", core.parseBatch(bj({ badPacket })) == nil)

  eq("order: no problem in a chain", core.batchOrderProblem(b.units), nil)
  local why = core.batchOrderProblem({ unit("alpha"), unit("beta", { "zeta" }) })
  check("order: an unknown blocker is named  (" .. tostring(why) .. ")", why and why:find("zeta", 1, true) ~= nil)
  why = core.batchOrderProblem({ unit("alpha", { "beta" }), unit("beta", { "alpha" }), unit("gamma", { "alpha" }) })
  check("order: a cycle names the units in it  (" .. tostring(why) .. ")",
        why and why:find("circle", 1, true) and why:find("alpha", 1, true) and why:find("beta", 1, true))
  check("order: ...and not a unit that only waits on the cycle", why and not why:find("gamma", 1, true))
end

-- ---- a waiting unit's tab, its merge, and the batch's end (2026-09-29) ----
do
  local b = core.parseBatch(bj())
  local grant = { approved = true, grantMerge = true }
  local function st(units) return { units = units } end
  local function req(slug) return { session_id = "drv", slug = slug } end

  check("tab: a unit with no blockers opens", core.fleetTabVerdict(b, grant, st({}), req("alpha")) == true)
  local ok, why, waits = core.fleetTabVerdict(b, grant, st({}), req("beta"))
  check("tab: a unit whose blocker hasn't merged waits  (" .. tostring(why) .. ")",
        ok == false and why == "waits for alpha to merge first")
  eq("tab: ...and says which units it waits for", join(waits), "alpha")
  ok, why = core.fleetTabVerdict(b, grant, st({ alpha = { session = { id = "sa" } } }), req("beta"))
  check("tab: a blocker that is still working still holds it  (" .. tostring(why) .. ")", ok == false and why:find("waits for alpha", 1, true))
  check("tab: once its blocker merged, it opens",
        core.fleetTabVerdict(b, grant, st({ alpha = { session = { id = "sa" }, result = "merged" } }), req("beta")) == true)
  check("tab: merged-dirty counts as merged",
        core.fleetTabVerdict(b, grant, st({ alpha = { session = { id = "sa" }, result = "merged-dirty" } }), req("beta")) == true)
  ok, why, waits = core.fleetTabVerdict(b, grant, st({ alpha = { session = { id = "sa" }, result = "blocked" } }), req("beta"))
  check("tab: a blocker that ended blocked -> blocked by a blocked unit, not a wait  (" .. tostring(why) .. ")",
        ok == false and why:find("blocked by a blocked unit", 1, true) and why:find("alpha", 1, true) and waits == nil)
  ok, why = core.fleetTabVerdict(b, grant, st({ alpha = { session = { id = "sa" }, result = "blocked" } }), req("gamma"))
  check("tab: ...through a chain, naming the unit that blocked  (" .. tostring(why) .. ")",
        ok == false and why:find("blocked by a blocked unit", 1, true) and why:find("alpha", 1, true))

  local blockedAlpha = st({ alpha = { session = { id = "sa" }, result = "blocked" } })
  local o = core.batchOutcomes(b, blockedAlpha)
  eq("outcomes: the blocked unit and every unit waiting on it are blocked", join(o.blocked), "alpha,beta,gamma")
  local fin, fwhy = core.batchFinished(b, grant, blockedAlpha, false)
  check("finished: so the batch can still finish  (" .. tostring(fwhy) .. ")", fin == true and fwhy == "3 blocked")
  local partly = st({ alpha = { session = { id = "sa" }, result = "merged" }, beta = { session = { id = "sb" }, result = "blocked" } })
  o = core.batchOutcomes(b, partly)
  check("outcomes: a merged blocker passes nothing on", join(o.merged) == "alpha" and join(o.blocked) == "beta,gamma")
  check("finished: 1 merged, 2 blocked", select(2, core.batchFinished(b, grant, partly, false)) == "1 merged, 2 blocked")
  o = core.batchOutcomes(b, st({}))
  eq("outcomes: waiting is not blocked -- nothing has failed yet", join(o.unopened), "alpha,beta,gamma")

  local waitsOf, via = core.batchUnitWaits(b, st({}), "gamma")
  check("waits: gamma waits for beta only (its own blockers, not theirs)", join(waitsOf) == "beta" and via == nil)

  -- merge readiness: the same rule, by branch, while the batch runs
  local r = { branch = "feat/beta", session_id = "sb", commonDir = "/r/main/.git" }
  local p = core.fleetMergeWaits(b, grant, st({ beta = { session = { id = "sb" } } }), r)
  check("merge: a unit whose blocker hasn't merged isn't ready  (" .. tostring(p) .. ")", p and p:find("waits for alpha", 1, true))
  eq("merge: once its blocker merged, nothing holds it",
     core.fleetMergeWaits(b, grant, st({ alpha = { result = "merged" }, beta = { session = { id = "sb" } } }), r), nil)
  eq("merge: a branch that isn't a unit's is none of the batch's business",
     core.fleetMergeWaits(b, grant, st({}), { branch = "feat/other" }), nil)
  eq("merge: a stopped batch's order no longer holds Adam's merge",
     core.fleetMergeWaits(b, { approved = true, stopped = true }, st({}), r), nil)
  eq("merge: nor does an unapproved one", core.fleetMergeWaits(b, nil, st({}), r), nil)

  local facts = { listed = true, head = "feat/beta", clean = true, ahead = 1, markers = 0 }
  local rq = { branch = "feat/beta", base = "main" }
  check("readiness: ready with no order problem", core.mergeReadiness(rq, facts, {}, nil, nil).ready == true)
  local rd = core.mergeReadiness(rq, facts, {}, nil, "waits for alpha to merge first")
  check("readiness: the batch's order refuses the merge  (" .. tostring(rd.problems[1]) .. ")",
        rd.ready == false and rd.problems[1] == "waits for alpha to merge first")
  rd = core.mergeReadiness(rq, facts, {}, { state = "passed", code = 0, command = "make test" }, "waits for alpha to merge first")
  check("readiness: ...even with a green gate", rd.ready == false)

  local v = core.batchView(b, grant, st({}))
  eq("view: a unit shows its blockers", join(v.units[2].blockedBy), "alpha")
  eq("view: ...and that it waits", v.units[2].note, "waits for alpha")
  eq("view: ...what it covers and its packet", join(v.units[2].covers) .. " " .. tostring(v.units[2].packet), "BUG-3,REQ-001 p1")
  v = core.batchView(b, grant, blockedAlpha)
  eq("view: a unit behind a blocked one says so", v.units[3].note, "blocked by a blocked unit (alpha)")
  eq("view: ...and is in the blocked bucket", v.units[3].outcome, "blocked")

  local msg = core.fleetUnitMessage(b, b.units[2])
  check("unit message: says what it comes after", msg:find("feat/alpha", 1, true) ~= nil)
  check("unit message: ...what it covers and its packet", msg:find("BUG-3, REQ-001", 1, true) and msg:find("p1", 1, true))
  local msg1 = core.fleetUnitMessage(b, b.units[1])
  check("unit message: a unit with nothing of the kind says nothing about it",
        not msg1:find("comes after", 1, true) and not msg1:find("covers", 1, true))
end

-- ---- the radar's parser, on literal git output (2026-09-29) ----
-- The @@pair bodies are literal `git merge-tree --write-tree --name-only --no-messages` output
-- (git 2.51): the merged tree's OID, then one conflicted path per line; exit 1 = conflicts.
local SCAN = table.concat({
  "@@base\tmain\t1111111111111111111111111111111111111111",
  "@@wt\t/r/main/.claude/worktrees/a\tfeat/a\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "@@committed", "app.lua", "README.md",
  "@@dirty", "notes.md",
  "@@untracked", "scratch.lua",
  "@@wt\t/r/main/.claude/worktrees/b\tfeat/b\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "@@committed", "app.lua", "other.lua", "lib/x.lua", "lib/y.lua", "notes.md",
  "@@dirty",
  "@@untracked",
  "@@wt\t/r/main/.claude/worktrees/c\t\tcccccccccccccccccccccccccccccccccccccccc",
  "@@committed", "q.lua",
  "@@dirty",
  "@@untracked",
  "@@wt\t/r/main/redfirst-abc123\t\tdddddddddddddddddddddddddddddddddddddddd",
  "@@committed", "app.lua",
  "@@dirty", "@@untracked",
  "@@pair\t/r/main/.claude/worktrees/a\t/r/main/.claude/worktrees/b",
  "cb1d25b3182699adc66e7ac1ecfdc3ebe8a44cce",
  "app.lua",
  "@@rc\t1",
  "@@pair\t/r/main/.claude/worktrees/a\t/r/main/.claude/worktrees/c",
  "e30012bf0c489645c2b58968bd5d13249d4cf9ba",
  "@@rc\t0",
  "@@pair\t/r/main/.claude/worktrees/b\t/r/main/.claude/worktrees/c",
  "@@rc\t129",
  "@@pair\t/r/main/.claude/worktrees/a\t/r/main/redfirst-abc123",
  "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "app.lua",
  "@@rc\t1",
  "" }, "\n")

do
  local scan = core.parseRadarScan(SCAN)
  eq("parse: the base branch", scan.base and scan.base.branch, "main")
  eq("parse: three linked worktrees (a red-first scratch one is never counted)", #scan.worktrees, 3)
  local a = scan.worktrees[1]
  eq("parse: a worktree's branch diff", join(a.committed), "app.lua,README.md")
  eq("parse: ...its dirty files", join(a.dirty), "notes.md")
  eq("parse: ...and its untracked ones", join(a.untracked), "scratch.lua")
  eq("parse: a detached worktree has no branch", scan.worktrees[3].branch, nil)
  eq("parse: three pairs (none with the scratch worktree)", #scan.pairs, 3)
  eq("parse: merge-tree's conflicted paths, not its tree OID", join(scan.pairs[1].conflicts), "app.lua")
  eq("parse: exit 1 = conflicts", scan.pairs[1].rc, 1)
  check("parse: a clean merge has no conflicts", #scan.pairs[2].conflicts == 0 and scan.pairs[2].rc == 0)
  check("parse: an exit merge-tree can't explain (an old git) is unknown, not clean",
        scan.pairs[3].unknown == true and #scan.pairs[3].conflicts == 0)
  -- the output as git prints it WITH its messages: a blank line, then prose -- never a path
  local noisy = core.parseRadarScan(table.concat({
    "@@pair\t/r/w/a\t/r/w/b", "cb1d25b3182699adc66e7ac1ecfdc3ebe8a44cce", "app.lua", "",
    "Auto-merging app.lua", "CONFLICT (content): Merge conflict in app.lua", "@@rc\t1" }, "\n"))
  eq("parse: merge-tree's informational messages are not paths", join(noisy.pairs[1].conflicts), "app.lua")
  local torn = core.parseRadarScan("@@wt\t/r/w/a\tfeat/a\taaaa\n@@committed\napp.lua\nlib/torn-at-the-end")
  eq("parse: a torn last line is still a path", join(torn.worktrees[1].committed), "app.lua,lib/torn-at-the-end")
  check("parse: garbage is an empty scan, never an error",
        #core.parseRadarScan("junk\n@@nonsense\n").worktrees == 0 and #core.parseRadarScan(nil).pairs == 0)

  local v = core.radarView(scan, {})
  eq("view: one overlapping pair (a and b share app.lua and notes.md)", #v.pairs, 1)
  local p = v.pairs[1]
  eq("view: the shared files, dirty ones included", join(p.shared), "app.lua,notes.md")
  eq("view: the conflicts", join(p.conflicts), "app.lua")
  eq("view: the smaller change merges first", p.first, "feat/a")
  eq("view: the hint", p.hint, "merge feat/a first (4 files vs 5), then rebase feat/b")
  local wa = v.byPath["/r/main/.claude/worktrees/a"]
  eq("view: a's tile line", wa and wa.line, "⚠ overlaps feat/b: 2 shared files, 1 conflict · merge feat/a first")
  eq("view: b's tile line", v.byPath["/r/main/.claude/worktrees/b"].line,
     "⚠ overlaps feat/a: 2 shared files, 1 conflict · merge feat/a first")
  eq("view: c overlaps nothing", v.byPath["/r/main/.claude/worktrees/c"], nil)
  eq("view: the review's detail line", wa.lines[1],
     "feat/b: 2 shared files (app.lua, notes.md); 1 conflict (app.lua) -- merge feat/a first (4 files vs 5), then rebase feat/b")
  eq("view: the merge order", v.orderLine, "merge order: feat/a → feat/b")

  local v2 = core.radarView(scan, { first = { ["/r/main/.claude/worktrees/b"] = true } })
  eq("view: a worktree that already asked to merge goes first", v2.pairs[1].first, "feat/b")
  eq("view: ...and the hint says why", v2.pairs[1].hint, "merge feat/b first (it asked to merge), then rebase feat/a")

  local quiet = core.radarView(core.parseRadarScan(table.concat({
    "@@wt\t/r/w/a\tfeat/a\taaaa", "@@committed", "a.lua",
    "@@wt\t/r/w/b\tfeat/b\tbbbb", "@@committed", "b.lua",
    "@@pair\t/r/w/a\t/r/w/b", "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "@@rc\t0" }, "\n")), {})
  check("view: two worktrees that touch different files overlap nothing",
        #quiet.pairs == 0 and next(quiet.byPath) == nil and quiet.orderLine == nil)

  -- three worktrees on one file: the tile names every other one
  local three = core.radarView(core.parseRadarScan(table.concat({
    "@@wt\t/r/w/a\tfeat/a\taaaa", "@@committed", "x.lua",
    "@@wt\t/r/w/b\tfeat/b\tbbbb", "@@committed", "x.lua", "y.lua",
    "@@wt\t/r/w/c\tfix/c\tcccc", "@@committed", "x.lua", "y.lua", "z.lua",
    "@@pair\t/r/w/a\t/r/w/b", "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "x.lua", "@@rc\t1",
    "@@pair\t/r/w/a\t/r/w/c", "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "@@rc\t0",
    "@@pair\t/r/w/b\t/r/w/c", "e30012bf0c489645c2b58968bd5d13249d4cf9ba", "@@rc\t0" }, "\n")), {})
  eq("view: several overlaps on one tile", three.byPath["/r/w/a"].line, "⚠ overlaps 2 worktrees: feat/b (1 conflict), fix/c (1 file)")
  eq("view: the order over all of them", three.orderLine, "merge order: feat/a → feat/b → fix/c")

  -- which repos to scan: every local repo a tile is in, once
  local repos = core.radarRepos({
    { key = "1", repoKey = "/r/main/.git", mainRoot = "/r/main", wtRoot = "/r/main" },
    { key = "2", repoKey = "/r/main/.git", mainRoot = "/r/main", wtRoot = "/r/main/.claude/worktrees/a" },
    { key = "3", repoKey = "/r/other/.git", mainRoot = "/r/other" },
    { key = "4", remote = { host = "box" }, repoKey = "/r/far/.git", mainRoot = "/r/far" },
    { key = "5", projectKey = "-plain" } })
  check("repos: each local repo once, keyed by its git dir", repos["/r/main/.git"] == "/r/main" and repos["/r/other/.git"] == "/r/other")
  check("repos: never a remote tile's", repos["/r/far/.git"] == nil)

  -- Instances: members and idle worktrees carry their line; the view carries the order
  local ip = core.instancesPayload("repo:/r/main/.git",
    { { key = "s1", wtRoot = "/r/main/.claude/worktrees/a", branch = "feat/a", status = "working",
        overlap = { line = wa.line } } }, {},
    { { path = "/r/main" }, { path = "/r/main/.claude/worktrees/b", branch = "feat/b" } },
    { mainRoot = "/r/main", radar = v })
  eq("instances: a member row carries its overlap line", ip.members[1].overlap, wa.line)
  local idleB
  for _, w in ipairs(ip.worktrees) do if w.branch == "feat/b" then idleB = w end end
  eq("instances: ...so does a worktree with no session", idleB and idleB.overlap, v.byPath["/r/main/.claude/worktrees/b"].line)
  eq("instances: the merge order for the project", ip.mergeOrder, "merge order: feat/a → feat/b")

  -- the merge review
  local mreq = { phase = "requested", branch = "feat/a", base = "main", worktree = "/r/main/.claude/worktrees/a", at = 1 }
  local mv = core.mergeView(mreq, { ready = true, problems = {} }, nil, { overlap = core.radarReview(v, mreq.worktree) })
  check("review: the overlap lines and the order reach the review",
        mv.overlap and mv.overlap.lines[1] == wa.lines[1] and mv.overlap.order == "merge order: feat/a → feat/b")
  eq("review: a worktree that overlaps nothing gets nothing", core.radarReview(v, "/r/main/.claude/worktrees/c"), nil)
  check("review: overlap is a hint -- the request stays ready", mv.ready == true)
end

-- ---- the real shell program, against a real repo (2026-09-29) ----
do
  local T
  do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
  T = (T or ""):gsub("/+$", "")
  local function sh(cmd) local ok = os.execute(cmd .. " >/dev/null 2>&1"); return ok == true or ok == 0 end
  local R = T .. "/repo"
  local G = "git -C '" .. R .. "' -c user.email=t@example.invalid -c user.name=t "
  local okSetup = sh("git init -q -b main '" .. R .. "'")
    and sh("printf 'a\\nb\\nc\\n' > '" .. R .. "/app.lua' && printf 'x\\n' > '" .. R .. "/README.md'")
    and sh(G .. "add -A") and sh(G .. "commit -qm base")
    and sh(G .. "worktree add -q -b feat/a '" .. R .. "/.claude/worktrees/a'")
    and sh(G .. "worktree add -q -b feat/b '" .. R .. "/.claude/worktrees/b'")
  local A, B = R .. "/.claude/worktrees/a", R .. "/.claude/worktrees/b"
  local GA = "git -C '" .. A .. "' -c user.email=t@example.invalid -c user.name=t "
  local GB = "git -C '" .. B .. "' -c user.email=t@example.invalid -c user.name=t "
  okSetup = okSetup
    and sh("printf 'a\\nB1\\nc\\n' > '" .. A .. "/app.lua'") and sh(GA .. "commit -qam a")
    and sh("printf 'a\\nB2\\nc\\n' > '" .. B .. "/app.lua' && printf 'z\\n' > '" .. B .. "/other.lua'")
    and sh(GB .. "add -A") and sh(GB .. "commit -qm b")
    and sh("printf 'y\\n' >> '" .. A .. "/README.md' && printf 'n\\n' > '" .. A .. "/new.lua'")
  check("real repo: two linked worktrees set up", okSetup)
  local out = T .. "/radar.out"
  local cmd = core.folderScanShellCommand(core.radarScanArgv(R, core.RADAR_MAX_WORKTREES), out)
  sh("/bin/sh -c " .. "'" .. cmd:gsub("'", "'\\''") .. "'")
  local f = io.open(out, "r"); local text = f and f:read("*a") or ""; if f then f:close() end
  local scan = core.parseRadarScan(text)
  eq("real repo: both worktrees scanned", #scan.worktrees, 2)
  local byPath = {}
  for _, w in ipairs(scan.worktrees) do byPath[w.path] = w end
  local pa = io.popen("cd '" .. A .. "' && pwd -P"); local AP = pa:read("*l"); pa:close()
  local pb = io.popen("cd '" .. B .. "' && pwd -P"); local BP = pb:read("*l"); pb:close()
  local wa, wb = byPath[core.normDir(A)] or byPath[core.normDir(AP)], byPath[core.normDir(B)] or byPath[core.normDir(BP)]
  eq("real repo: a's branch diff", wa and join(wa.committed), "app.lua")
  eq("real repo: ...its dirty file", wa and join(wa.dirty), "README.md")
  eq("real repo: ...its untracked file", wa and join(wa.untracked), "new.lua")
  eq("real repo: b's branch diff", wb and join(wb.committed), "app.lua,other.lua")
  eq("real repo: one pair, conflicting in app.lua", #scan.pairs == 1 and join(scan.pairs[1].conflicts), "app.lua")
  local v = core.radarView(scan, {})
  eq("real repo: the pair overlaps", #v.pairs, 1)
  os.execute("rm -r '" .. T .. "' 2>/dev/null")
end

finish()
