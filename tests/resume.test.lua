-- resume.test.lua : BEHAVIORAL fixture for resuming a session at its usage limit's reset, the panel
-- side (2026-09-29, build program unit 13). A turn stopped by a usage limit fires StopFailure
-- (matcher rate_limit): cc-resume.sh writes ~/.claude/cc-resume/<key>.json and waits
-- (tests/resume.test.sh). Shepherd plans the resume -- the reset from the plan meter's resets_at,
-- else from the error text (core.parseResetTime), once per window, never for a per-model limit --
-- and writes <key>.plan.json, which the hook waits on. Past the reset, a session the hook's rewake
-- didn't start gets the line typed where typing is allowed; in a VS Code window shared with other
-- Claude tabs its card says so and the phone gets a push. Loads the real claude-dashboard.lua
-- under a stubbed hs (timer beats collected and fired by hand, kitty's `kitty @` recorded).
-- Side-effect-free: HOME and every dir live in a temp dir.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function eq(name, got, want)
  check(name .. "  (got " .. tostring(got) .. ", want " .. tostring(want) .. ")", got == want)
end
local function finish() print("-- resume.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- Epoch of a civil local time at a fixed UTC offset (Hinnant's days-from-civil), so the cases
-- read the same on any machine whatever its own zone.
local function at(y, mo, d, h, mi, off)
  local yy = (mo <= 2) and (y - 1) or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (mo + ((mo > 2) and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + h * 3600 + (mi or 0) * 60 - (off or 0)
end
local EDT, EST = -4 * 3600, -5 * 3600

-- ---- the pure half: cc-core ----
local core = dofile(ROOT .. "cc-core.lua")
core.json = json   -- injected, as the dashboard injects hs.json
check("core.parseResetTime exists", type(core.parseResetTime) == "function")
if type(core.parseResetTime) ~= "function" then finish() end

-- parseResetTime: the reset Claude Code prints after "resets", read in the machine's own zone
-- (Claude Code formats it with that zone and names it in brackets). ref is when the message
-- was written: a time of day is its next occurrence from then.
local REF = at(2026, 9, 29, 13, 20, EDT)
local LIMIT = "You've hit your session limit · resets 3pm (America/New_York)"
local r, zone = core.parseResetTime(LIMIT, REF, EDT)
eq("parseResetTime: 'resets 3pm (America/New_York)' is 3pm that day", r, at(2026, 9, 29, 15, 0, EDT))
eq("...and names the zone Claude Code printed", zone, "America/New_York")
eq("parseResetTime: minutes ('3:30pm')", core.parseResetTime("You've hit your session limit · resets 3:30pm", REF, EDT),
   at(2026, 9, 29, 15, 30, EDT))
eq("parseResetTime: a time already past today is tomorrow's ('12pm' at 1:20pm)",
   core.parseResetTime("You've hit your session limit · resets 12pm", REF, EDT), at(2026, 9, 30, 12, 0, EDT))
eq("parseResetTime: '12am' is midnight, the next one", core.parseResetTime("hit your session limit · resets 12am", REF, EDT),
   at(2026, 9, 30, 0, 0, EDT))
eq("parseResetTime: '9am' said at 11:50pm is the next morning",
   core.parseResetTime("hit your session limit · resets 9am", at(2026, 9, 29, 23, 50, EDT), EDT), at(2026, 9, 30, 9, 0, EDT))
eq("parseResetTime: Claude Code drops the seconds, so '3pm' said at 3:00:30pm is still today's",
   core.parseResetTime(LIMIT, at(2026, 9, 29, 15, 0, EDT) + 30, EDT), at(2026, 9, 29, 15, 0, EDT))
eq("parseResetTime: a date more than a day out ('Oct 3, 9am')",
   core.parseResetTime("You've hit your weekly limit · resets Oct 3, 9am (America/New_York)", REF, EDT), at(2026, 10, 3, 9, 0, EDT))
eq("parseResetTime: a date with minutes ('Oct 3, 9:30am')",
   core.parseResetTime("You've hit your weekly limit · resets Oct 3, 9:30am", REF, EDT), at(2026, 10, 3, 9, 30, EDT))
eq("parseResetTime: a date without a year said in late December is next year's",
   core.parseResetTime("You've hit your weekly limit · resets Jan 2, 9am", at(2026, 12, 30, 10, 0, EST), EST), at(2027, 1, 2, 9, 0, EST))
eq("parseResetTime: an explicit year ('Jan 3, 2027, 9am')",
   core.parseResetTime("You've hit your weekly limit · resets Jan 3, 2027, 9am (America/New_York)", REF, EDT), at(2027, 1, 3, 9, 0, EDT))
eq("parseResetTime: a date alone ('your team's resets Oct 1') is its midnight",
   core.parseResetTime("You've hit your monthly spend limit · your team's resets Oct 1", REF, EDT), at(2026, 10, 1, 0, 0, EDT))
eq("parseResetTime: a trailing '· progress saved' is not part of the time",
   core.parseResetTime(LIMIT .. " · progress saved", REF, EDT), at(2026, 9, 29, 15, 0, EDT))
eq("parseResetTime: a curly apostrophe and '3 PM' read the same",
   core.parseResetTime("You’ve hit your session limit · resets 3 PM", REF, EDT), at(2026, 9, 29, 15, 0, EDT))
-- the offset can be a function of the time: a reset on the far side of a DST change is read in its own offset
local function nyOffset(e) return (e < at(2026, 11, 1, 6, 0, 0)) and EDT or EST end
eq("parseResetTime: a reset past the end of daylight saving uses the offset at the reset",
   core.parseResetTime("hit your session limit · resets 3am", at(2026, 11, 1, 0, 30, EDT), nyOffset), at(2026, 11, 1, 3, 0, EST))
for _, bad in ipairs({ "You've hit your fast limit", "resets soon", "hit your limit · resets 25pm",
                       "hit your limit · resets 13pm", "hit your limit · resets Foo 3, 9am", "hit your limit · resets 0am" }) do
  check("parseResetTime: no reset in '" .. bad .. "'", core.parseResetTime(bad, REF, EDT) == nil)
end
check("parseResetTime: nothing to read", core.parseResetTime(nil, REF, EDT) == nil and core.parseResetTime({}, REF, EDT) == nil)

-- which limit: Claude Code's own labels (session limit, weekly limit, <Model> limit)
local function lim(m) local a, b = core.resumeLimit(m); return tostring(a) .. (b and ("/" .. b) or "") end
eq("resumeLimit: the session (5h) window", lim(LIMIT), "session")
eq("resumeLimit: the weekly window", lim("You've hit your weekly limit · resets Oct 3, 9am"), "weekly")
eq("resumeLimit: a per-model limit names the model", lim("You’ve hit your Opus limit · resets Oct 3, 9am"), "model/Opus")
eq("resumeLimit: ...Fable too", lim("You've hit your Fable limit · resets Oct 3, 9am"), "model/Fable")
eq("resumeLimit: a spend limit is none of those", lim("You've hit your monthly spend limit · resets Oct 1"), "other")
eq("resumeLimit: nor is the fast-mode limit", lim("You've hit your fast limit"), "other")
eq("resumeLimit: nothing to read", lim(nil), "other")

-- stand down where Claude Code's own autoContinueAtUsageLimit resumes a terminal session itself
check("resumeStandDown: kitty with autoContinueAtUsageLimit on stands down",
      core.resumeStandDown("kitty", { autoContinueAtUsageLimit = true }) == true)
check("resumeStandDown: ...a terminal too", core.resumeStandDown("terminal", { autoContinueAtUsageLimit = true }) == true)
check("resumeStandDown: VS Code never (the setting is the terminal's)",
      core.resumeStandDown("vscode", { autoContinueAtUsageLimit = true }) == false
      and core.resumeStandDown("vscode", {}) == false)
-- 2026-09-29: Claude Code reads an absent key as ON (`autoContinueAtUsageLimit: kCt() ?? true` in
-- 2.1.284's settings panel), and neither of Adam's settings files sets it -- so only an explicit
-- false hands a terminal session to Shepherd.
check("resumeStandDown: the key absent is Claude Code's default, on: stand down",
      core.resumeStandDown("kitty", {}) == true and core.resumeStandDown("terminal", nil) == true
      and core.resumeStandDown("kitty", { autoContinueAtUsageLimit = "yes" }) == true)
check("resumeStandDown: turned off explicitly, Shepherd resumes it",
      core.resumeStandDown("kitty", { autoContinueAtUsageLimit = false }) == false
      and core.resumeStandDown("terminal", { autoContinueAtUsageLimit = false }) == false)

-- the arm the hook writes, read back
local ARM = { key = "k1", session_id = "k1", nonce = "a1b2c3d4", pid = 4242, waiter = 777, editor = "vscode",
              kind = "rate_limit", message = LIMIT, armedAt = REF, state = "waiting" }
local arm = core.parseResumeArm(json.encode(ARM))
check("parseResumeArm reads the hook's arm", arm ~= nil and arm.key == "k1" and arm.nonce == "a1b2c3d4"
      and arm.message == LIMIT and arm.armedAt == REF and arm.state == "waiting")
check("parseResumeArm refuses torn JSON", core.parseResumeArm('{"key":"k1","nonce":"a1') == nil)
check("parseResumeArm refuses a nonce that isn't plain alnum",
      core.parseResumeArm(json.encode({ key = "k1", nonce = "a/b", state = "waiting" })) == nil)
check("parseResumeArm refuses a key that could leave its folder",
      core.parseResumeArm(json.encode({ key = "..", nonce = "ab", state = "waiting" })) == nil)
check("parseResumeArm refuses a state it doesn't know",
      core.parseResumeArm(json.encode({ key = "k1", nonce = "ab", state = "<b>" })) == nil)

-- the plan: when, which window, and whether at all
local NOW = REF + 5
local function ctx(over)
  local c = { now = NOW, tz = EDT, enabled = true, standDown = false }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end
local p = core.resumePlan(arm, nil, {}, ctx())
eq("resumePlan: a session limit waits for its reset", p.verdict, "wait")
eq("...read from the error text when there is no plan meter", p.source, "message")
eq("...at 3pm", p.resetAt, at(2026, 9, 29, 15, 0, EDT))
eq("...bound to the arm's nonce", p.nonce, "a1b2c3d4")
eq("...for the session window", p.limit, "session")
local official = { five_hour = { utilization = 100, resets_at = "2026-09-29T19:00:00.534520+00:00" },
                   seven_day = { utilization = 61, resets_at = "2026-10-03T13:00:00+00:00" } }
local pm = core.resumePlan(arm, official, {}, ctx())
eq("resumePlan: the plan meter's resets_at wins for the full window", pm.source, "plan")
eq("...to the second", pm.resetAt, at(2026, 9, 29, 19, 0, 0))
eq("resumePlan: the window is the same whichever source named the reset", pm.window, p.window)
local weekArm = core.parseResumeArm(json.encode({ key = "k2", nonce = "ff01", state = "waiting", armedAt = REF,
  message = "You've hit your weekly limit · resets Oct 3, 9am (America/New_York)" }))
local pw = core.resumePlan(weekArm, official, {}, ctx())
check("resumePlan: the weekly window reads seven_day's resets_at",
      pw.verdict == "wait" and pw.source == "plan" and pw.resetAt == at(2026, 10, 3, 13, 0, 0) and pw.limit == "weekly")
local stale = { five_hour = { utilization = 100, resets_at = "2026-09-29T14:00:00+00:00" } }
local ps = core.resumePlan(arm, stale, {}, ctx())
check("resumePlan: a plan meter reset already past falls back to the error text",
      ps.source == "message" and ps.resetAt == at(2026, 9, 29, 15, 0, EDT))
local modelArm = core.parseResumeArm(json.encode({ key = "k3", nonce = "ee02", state = "waiting", armedAt = REF,
  message = "You've hit your Opus limit · resets Oct 3, 9am (America/New_York)" }))
local pmod = core.resumePlan(modelArm, official, {}, ctx())
check("resumePlan: a per-model limit never waits -- switch model instead",
      pmod.verdict == "skip" and pmod.reason == "model" and pmod.model == "Opus")
local pdown = core.resumePlan(arm, nil, {}, ctx({ standDown = true }))
check("resumePlan: stands down while Claude Code's own auto-continue is on", pdown.verdict == "skip" and pdown.reason == "claude-code")
local poff = core.resumePlan(arm, nil, {}, ctx({ enabled = false }))
check("resumePlan: resume.enabled off, nothing waits", poff.verdict == "skip" and poff.reason == "off")
local noTime = core.parseResumeArm(json.encode({ key = "k4", nonce = "dd03", state = "waiting", armedAt = REF,
  message = "You've hit your fast limit" }))
local pnt = core.resumePlan(noTime, nil, {}, ctx())
check("resumePlan: no reset time, nothing to wait for", pnt.verdict == "skip" and pnt.reason == "no reset")
local far = core.parseResumeArm(json.encode({ key = "k5", nonce = "cc04", state = "waiting", armedAt = REF,
  message = "You've hit your monthly spend limit · resets Nov 29, 9am" }))
local pfar = core.resumePlan(far, nil, {}, ctx())
check("resumePlan: a reset further out than the hook can wait isn't waited for", pfar.verdict == "skip" and pfar.reason == "too far")
local caps = {}
caps[core.resumeCapKey("k1", p.window)] = NOW - 60
local ptried = core.resumePlan(arm, nil, caps, ctx())
check("resumePlan: once per window -- a window already tried is skipped", ptried.verdict == "skip" and ptried.reason == "tried")
local capsOther = {}
capsOther[core.resumeCapKey("other", p.window)] = NOW - 60
check("resumePlan: ...per session: another session's attempt doesn't count",
      core.resumePlan(arm, nil, capsOther, ctx()).verdict == "wait")
local old = {}
old[core.resumeCapKey("k1", "session:1")] = NOW - 9 * 86400
old[core.resumeCapKey("k1", "session:2")] = NOW - 3600
eq("pruneResumeCaps drops attempts older than the longest wait", core.pruneResumeCaps(old, NOW), 1)
check("...and keeps the recent ones", old[core.resumeCapKey("k1", "session:2")] ~= nil and old[core.resumeCapKey("k1", "session:1")] == nil)

-- the route: what Shepherd does this tick
local function item(over)
  local it = { key = "k1", status = "error", editor = "vscode" }
  for k, v in pairs(over or {}) do it[k] = v end
  return it
end
local due = p.resetAt + core.RESUME.fallbackGrace
eq("resumeRoute: before the fallback is due, wait", core.resumeRoute(arm, p, item(), due - 1), "wait")
eq("resumeRoute: due, a VS Code window to itself: type", core.resumeRoute(arm, p, item(), due), "type")
eq("resumeRoute: due, kitty: type", core.resumeRoute(arm, p, item({ editor = "kitty", sharedWindow = 3 }), due), "type")
eq("resumeRoute: due, a VS Code window shared with other Claude tabs: notify (never typed)",
   core.resumeRoute(arm, p, item({ sharedWindow = 2 }), due), "notify")
eq("resumeRoute: due, but the session is working again (the rewake started it): resumed",
   core.resumeRoute(arm, p, item({ status = "working" }), due), "resumed")
check("resumeRoute: a remote session is not ours to reach", core.resumeRoute(arm, p, item({ remote = true }), due) == nil)
check("resumeRoute: no card, nothing to do", core.resumeRoute(arm, p, nil, due) == nil)
local typed = {}; for k, v in pairs(p) do typed[k] = v end; typed.typedAt = due
check("resumeRoute: never typed twice (typedAt on the plan)", core.resumeRoute(arm, typed, item(), due + 600) == nil)
local notified = {}; for k, v in pairs(p) do notified[k] = v end; notified.notifiedAt = due
check("resumeRoute: never notified twice", core.resumeRoute(arm, notified, item({ sharedWindow = 2 }), due + 600) == nil)
local wrong = {}; for k, v in pairs(p) do wrong[k] = v end; wrong.nonce = "zz"
check("resumeRoute: a plan for another arm is no plan", core.resumeRoute(arm, wrong, item(), due) == nil)
check("resumeRoute: a skipped plan does nothing", core.resumeRoute(modelArm, pmod, item({ key = "k3" }), due) == nil)
local cancelledArm = {}; for k, v in pairs(arm) do cancelledArm[k] = v end; cancelledArm.state = "cancelled"
check("resumeRoute: a cancelled arm does nothing", core.resumeRoute(cancelledArm, p, item(), due) == nil)
local nowPlan = {}; for k, v in pairs(p) do nowPlan[k] = v end; nowPlan.resetAt = NOW; nowPlan.now = true
eq("resumeRoute: Resume now is due sooner", core.resumeRoute(arm, nowPlan, item(), NOW + core.RESUME.nowGrace), "type")

-- the card
local c = core.resumeCard(arm, p, item(), NOW, EDT)
check("resumeCard: before the reset it says when  (" .. tostring(c and c.line) .. ")",
      c ~= nil and c.phase == "waiting" and c.line == "resumes at 3:00pm")
check("...with Cancel and Resume now", c ~= nil and c.cancel == true and c.now == true)
local cw = core.resumeCard(weekArm, pw, item({ key = "k2" }), NOW, EDT)
check("resumeCard: more than a day out it names the day  (" .. tostring(cw and cw.line) .. ")",
      cw ~= nil and cw.line == "resumes Oct 3 at 9:00am")
local cd = core.resumeCard(arm, p, item(), p.resetAt + 5, EDT)
check("resumeCard: past the reset it is resuming  (" .. tostring(cd and cd.line) .. ")",
      cd ~= nil and cd.phase == "due" and cd.line == "resuming now" and cd.cancel == true and not cd.now)
local cn = core.resumeCard(arm, notified, item({ sharedWindow = 2 }), due + 5, EDT)
check("resumeCard: in a shared window, once due: limit reset -- continue it  (" .. tostring(cn and cn.line) .. ")",
      cn ~= nil and cn.phase == "reset" and cn.line == "limit reset — continue it")
local cm = core.resumeCard(modelArm, pmod, item({ key = "k3" }), NOW, EDT)
check("resumeCard: a per-model limit says switch model  (" .. tostring(cm and cm.line) .. ")",
      cm ~= nil and cm.phase == "model" and cm.line == "Opus limit — switch model" and not cm.cancel)
check("resumeCard: a working session shows nothing", core.resumeCard(arm, p, item({ status = "working" }), NOW, EDT) == nil)
check("resumeCard: a typed resume shows nothing", core.resumeCard(arm, typed, item(), due + 5, EDT) == nil)
check("resumeCard: a cancelled one shows nothing", core.resumeCard(cancelledArm, p, item(), NOW, EDT) == nil)
check("resumeCard: skipped for another reason shows nothing (the error line says enough)",
      core.resumeCard(arm, ptried, item(), NOW, EDT) == nil)

-- the clock
eq("resumeClock: 3:00pm", core.resumeClock(at(2026, 9, 29, 15, 0, EDT), REF, EDT), "3:00pm")
eq("resumeClock: 12:00am", core.resumeClock(at(2026, 9, 30, 0, 0, EDT), REF, EDT), "12:00am")
eq("resumeClock: 12:30pm", core.resumeClock(at(2026, 9, 30, 12, 30, EDT), REF, EDT), "12:30pm")
eq("resumeClock: 9:05am", core.resumeClock(at(2026, 9, 30, 9, 5, EDT), REF, EDT), "9:05am")
eq("resumeClock: a day out names the day", core.resumeClock(at(2026, 10, 3, 9, 0, EDT), REF, EDT), "Oct 3 at 9:00am")
eq("the line typed and printed is one line, marked [shepherd]", core.RESUME.line,
   "[shepherd] The usage limit has reset: continue the task.")
check("the hook's wait covers the fallback: jitter + poll < the fallback grace",
      core.RESUME.jitterMax + core.RESUME.poll < core.RESUME.fallbackGrace)

-- ---- the panel half: the real dashboard under a stubbed hs ----
local T
do local p2 = io.popen("mktemp -d 2>/dev/null"); T = p2 and p2:read("*l"); if p2 then p2:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local RDIR = T .. "/.claude/cc-resume"
os.execute('mkdir -p "' .. T .. '/status" "' .. RDIR .. '" "' .. T .. '/vs" "' .. T .. '/kt" "' .. T .. '/sh" "' .. T .. '/kd"')
local START = os.time()
local CLOCK = START
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function readJson(path) local s = readFile(path); if not s then return nil end local ok, t = pcall(json.decode, s); return ok and t or nil end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end return false end
write(T .. "/.claude/cc-config.json", '{"bridge":{"enabled":false,"intervalSeconds":2},"escalation":{"pushTopic":"t0pic"}}')
-- Claude Code's own settings: kitty/terminal sessions resume themselves when this is on
write(T .. "/.claude/settings.json", '{"autoContinueAtUsageLimit":false}')
local function status(key, over)
  local s = { status = "error", session_id = key, name = key, cwd = T .. "/vs", since = START - 100,
              updated = START - 60, editor = "vscode", host_window = key .. "-host", session_pid = key .. "-pid",
              error_kind = "rate_limit" }
  for k, v in pairs(over or {}) do s[k] = v end
  write(T .. "/status/" .. key .. ".json", json.encode(s))
end
-- The reset an hour and a bit from now, on the hour, printed the way Claude Code prints it in
-- this machine's own zone: "resets 4pm (Zone)".
local RESET = (math.floor((START + 3600) / 3600) + 1) * 3600
local function clock12(e)
  local h = tonumber(os.date("%H", e)); local ap = h < 12 and "am" or "pm"
  h = h % 12; if h == 0 then h = 12 end
  local mi = os.date("%M", e)
  return tostring(h) .. (mi == "00" and "" or (":" .. mi)) .. ap
end
local MSG = "You've hit your session limit · resets " .. clock12(RESET) .. " (Local/Zone)"
local nonceN = 0
local function arm(key, over)
  nonceN = nonceN + 1
  local a = { key = key, session_id = key, nonce = string.format("n%04dabcd", nonceN), pid = 4242, waiter = 777,
              editor = "vscode", kind = "rate_limit", message = MSG, armedAt = START, state = "waiting" }
  for k, v in pairs(over or {}) do a[k] = v end
  write(RDIR .. "/" .. key .. ".json", json.encode(a))
  return a
end
status("solo1")                                                   -- a VS Code window to itself
status("kit1", { editor = "kitty", cwd = T .. "/kt", kitty_window_id = "7", kitty_listen_on = "unix:" .. T .. "/k.sock" })
status("tabA", { cwd = T .. "/sh", host_window = "4242" })        -- two Claude tabs, one window
status("tabB", { cwd = T .. "/sh", host_window = "4242", name = "tabB-proj", status = "done", error_kind = nil })
status("work1", { cwd = T .. "/kd" })                             -- the rewake will start this one
status("model1", { cwd = T .. "/kd", host_window = "m1-host" })   -- a per-model limit
status("cancel1", { cwd = T .. "/kd", host_window = "c1-host" })
status("now1", { cwd = T .. "/kd", host_window = "n1-host" })

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local beatsDue = {}
local function beats()
  local n = 0
  while #beatsDue > 0 do
    local b = table.remove(beatsDue, 1)
    n = n + 1
    b.fn()
    if n > 80 then break end
  end
  return n
end
local kittyCalls = {}
local function kittyTask(bin, cb, argv)
  local sub
  for _, a in ipairs(argv or {}) do
    if a == "ls" or a == "get-text" or a == "send-text" or a == "send-key" then sub = a; break end
  end
  return {
    start = function() kittyCalls[#kittyCalls + 1] = { sub = sub, argv = argv }; return true end,
    waitUntilExit = function()
      if cb then
        local out = (sub == "ls" and '[{"tabs":[{"windows":[{"id":7}]}]}]')
          or (sub == "get-text" and readFile(HERE .. "fixtures/kitty-screens/dim-suggestion.ansi")) or ""
        cb(0, out, "")
      end
    end,
    terminationStatus = function() return 0 end,
  }
end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p3 = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p3 then for line in p3:lines() do files[#files + 1] = line end; p3:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path)
      local h = io.open(tostring(path), "r")
      if h then h:close(); return { mode = "file" } end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function(path) os.execute('mkdir "' .. tostring(path) .. '" 2>/dev/null'); return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
  task = { new = kittyTask },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function(delay, fn) beatsDue[#beatsDue + 1] = { delay = delay, fn = fn }; return mkstub() end,
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
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "base", "console" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quietly(fn) print = function() end; local rr = { pcall(fn) }; print = realPrint; return table.unpack(rr) end
local ok, err = quietly(function() return dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
beatsDue = {}

local ledger = {}
fx.appendLedger = function(ev) ledger[#ledger + 1] = ev end
fx.now = function() return CLOCK end
local pushes = {}
fx.push = function(topic, title, msg) pushes[#pushes + 1] = { topic = topic, title = title, msg = msg } end
local pastes = {}
local realPaste = fx.pasteIntoWindow   -- kitty keeps the real path: `kitty @`, recorded above
fx.pasteIntoWindow = function(target, payload)
  if target.editor == "kitty" then return realPaste(target, payload) end
  pastes[#pastes + 1] = { key = target.key, text = payload and payload.text }
  return true
end
local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
check("every fixture session is on the panel",
      byK.solo1 and byK.kit1 and byK.tabA and byK.tabB and byK.work1 and byK.model1 and byK.cancel1 and byK.now1)
check("(fixture: the two tabs share a window)", byK.tabA and (tonumber(byK.tabA.sharedWindow) or 0) == 2)
if not (byK.solo1 and byK.kit1 and byK.tabA and byK.work1) then finish() end
local list = fx._shownItems
check("FX.stepResume exists", type(fx.stepResume) == "function")
if type(fx.stepResume) ~= "function" then finish() end
local function step() quietly(function() fx.stepResume(list) end) end
local function planOf(key) return readJson(RDIR .. "/" .. key .. ".plan.json") end

-- arming: Shepherd plans each arm once, bound to its nonce
local aSolo = arm("solo1")
arm("kit1", { editor = "kitty" })
arm("tabA")
arm("work1")
arm("model1", { message = "You've hit your Opus limit · resets Oct 3, 9am (Local/Zone)" })
arm("cancel1")
local aNow = arm("now1")
step()
local ps1 = planOf("solo1")
check("Shepherd plans an arm: wait for the reset, bound to its nonce",
      ps1 ~= nil and ps1.verdict == "wait" and ps1.nonce == aSolo.nonce and ps1.source == "message")
eq("...at the reset the error text names", ps1 and ps1.resetAt, RESET)
check("...no temp file left behind", not exists(RDIR .. "/solo1.plan.json.tmp." .. tostring(hs.processInfo and hs.processInfo.processID or "p")))
local pm1 = planOf("model1")
check("a per-model limit is planned as skip: switch model", pm1 ~= nil and pm1.verdict == "skip" and pm1.reason == "model")
check("...its card says so  (" .. tostring(byK.model1.resume and byK.model1.resume.line) .. ")",
      byK.model1.resume ~= nil and byK.model1.resume.line == "Opus limit — switch model")
check("the card says when it resumes, with Cancel and Resume now  (" .. tostring(byK.solo1.resume and byK.solo1.resume.line) .. ")",
      byK.solo1.resume ~= nil and byK.solo1.resume.line == "resumes at " .. core.resumeClock(RESET, CLOCK, core.localTzOffset(CLOCK))
      and byK.solo1.resume.cancel == true and byK.solo1.resume.now == true)
local tried = settingsStore.ccResumeTried
check("the attempt is remembered in hs.settings (survives a reload)",
      type(tried) == "table" and tried[core.resumeCapKey("solo1", ps1 and ps1.window or "")] ~= nil)
local planned = 0
for _, ev in ipairs(ledger) do if ev.type == "resume_planned" then planned = planned + 1 end end
check("the ledger records each plan (" .. planned .. ")", planned == 7)
step()
local planned2 = 0
for _, ev in ipairs(ledger) do if ev.type == "resume_planned" then planned2 = planned2 + 1 end end
check("...once: a second tick plans nothing again", planned2 == 7)
check("nothing is typed before the reset", #pastes == 0 and #kittyCalls == 0)

-- Cancel: the hook's cancel file, the plan says so, the card clears, nothing is ever typed
check("FX.resumeCancel exists", type(fx.resumeCancel) == "function")
quietly(function() fx.resumeCancel("cancel1") end)
check("Cancel leaves the hook its cancel file", exists(RDIR .. "/cancel1.cancel"))
eq("...and the plan says cancelled", (planOf("cancel1") or {}).verdict, "cancelled")
step()
check("...its card shows no resume", byK.cancel1.resume == nil)

-- Resume now: the hook fires at its next poll (resetAt = now); the fallback is due soon after
check("FX.resumeNow exists", type(fx.resumeNow) == "function")
quietly(function() fx.resumeNow("now1") end)
local pn = planOf("now1")
check("Resume now moves the reset to now, for the hook", pn ~= nil and pn.resetAt == CLOCK and pn.now == true and pn.nonce == aNow.nonce)

-- the reset passes; the rewake started work1 (its status is working again); the others still sit
CLOCK = RESET + core.RESUME.fallbackGrace + 1
status("work1", { cwd = T .. "/kd", status = "working", updated = CLOCK - 5 })
byK.work1.status = "working"
step()
quietly(beats)
local soloPaste, n = nil, 0
for _, pp in ipairs(pastes) do if pp.key == "solo1" then soloPaste = pp; n = n + 1 end end
check("past the reset, a session alone in its VS Code window has the line typed  (" .. tostring(soloPaste and soloPaste.text) .. ")",
      soloPaste ~= nil and soloPaste.text == core.RESUME.line)
check("...the plan records it typed", (planOf("solo1") or {}).typedAt ~= nil)
local kText
for _, cc in ipairs(kittyCalls) do if cc.sub == "send-text" then kText = cc.argv[#cc.argv] end end
check("a kitty session has it typed with kitty @  (" .. tostring(kText) .. ")", kText == core.RESUME.line)
local tabPaste = false
for _, pp in ipairs(pastes) do if pp.key == "tabA" or pp.key == "tabB" then tabPaste = true end end
check("a session sharing its VS Code window is never typed into", not tabPaste)
check("...its card says the limit reset  (" .. tostring(byK.tabA.resume and byK.tabA.resume.line) .. ")",
      byK.tabA.resume ~= nil and byK.tabA.resume.line == "limit reset — continue it")
check("...and the phone gets a push  (" .. tostring(pushes[1] and pushes[1].msg) .. ")",
      #pushes == 1 and pushes[1].topic == "t0pic" and tostring(pushes[1].msg):find("tabA", 1, true) ~= nil)
check("...the plan records it notified", (planOf("tabA") or {}).notifiedAt ~= nil)
local workPaste = false
for _, pp in ipairs(pastes) do if pp.key == "work1" then workPaste = true end end
check("a session the rewake already started is not typed into", not workPaste)
check("...the plan records it resumed", (planOf("work1") or {}).doneAt ~= nil)
local nowPaste = false
for _, pp in ipairs(pastes) do if pp.key == "now1" then nowPaste = true end end
check("Resume now's fallback typed the line too", nowPaste)
local cancelPaste = false
for _, pp in ipairs(pastes) do if pp.key == "cancel1" or pp.key == "model1" then cancelPaste = true end end
check("a cancelled or per-model resume is never typed", not cancelPaste)

-- never twice: more ticks, and a reload that forgets everything in memory, type nothing more
local before = #pastes
local sendsBefore = 0
for _, cc in ipairs(kittyCalls) do if cc.sub == "send-text" then sendsBefore = sendsBefore + 1 end end
fx._resume.inflight = {}
step(); quietly(beats); step(); quietly(beats)
local sendsAfter = 0
for _, cc in ipairs(kittyCalls) do if cc.sub == "send-text" then sendsAfter = sendsAfter + 1 end end
check("never typed twice: later ticks type nothing more (the plan file records it)",
      #pastes == before and sendsAfter == sendsBefore)
check("...and push nothing more", #pushes == 1)

-- once per window: a clean Stop clears the arm; the same window re-armed is not resumed again
os.remove(RDIR .. "/solo1.json"); os.remove(RDIR .. "/solo1.plan.json")
local aSolo2 = arm("solo1")
step()
local ps2 = planOf("solo1")
check("once per window: a new arm in a window already tried is skipped",
      ps2 ~= nil and ps2.nonce == aSolo2.nonce and ps2.verdict == "skip" and ps2.reason == "tried")

-- stand down: kitty with Claude Code's own autoContinueAtUsageLimit on
write(T .. "/.claude/settings.json", '{"autoContinueAtUsageLimit":true}')
os.remove(RDIR .. "/kit1.json"); os.remove(RDIR .. "/kit1.plan.json")
arm("kit1", { editor = "kitty", message = "You've hit your weekly limit · resets Oct 3, 9am (Local/Zone)" })
step()
local pk = planOf("kit1")
check("kitty stands down while Claude Code's own autoContinueAtUsageLimit is on",
      pk ~= nil and pk.verdict == "skip" and pk.reason == "claude-code")

-- FX.removeStatus reaps the session's resume files with the rest
write(RDIR .. "/tabA.cancel", "")
quietly(function() fx.removeStatus("tabA") end)
check("FX.removeStatus removes the arm, the plan and the cancel file",
      not exists(RDIR .. "/tabA.json") and not exists(RDIR .. "/tabA.plan.json") and not exists(RDIR .. "/tabA.cancel"))
check("...and leaves the others' alone", exists(RDIR .. "/work1.json"))
check("FX.RESUME_DIR is ~/.claude/cc-resume", fx.RESUME_DIR == T .. "/.claude/cc-resume")
check("ledger: typed, notified and resumed are recorded", (function()
  local seen = {}
  for _, ev in ipairs(ledger) do seen[ev.type] = true end
  return seen.resume_typed and seen.resume_notified and seen.resume_resumed and seen.resume_cancelled and seen.resume_now
end)())

os.execute('rm -r "' .. T .. '"')
finish()
