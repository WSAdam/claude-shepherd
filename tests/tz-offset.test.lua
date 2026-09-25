-- tz-offset.test.lua : core.localTzOffset under pinned time zones. Run with plain `lua`.
-- Every case runs in a child `lua` with TZ set, at a fixed epoch, so the answer never depends
-- on the machine's zone or today's date. Exits nonzero if any check fails.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local LUA = arg and arg[-1] or "lua"

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then
    print("ok   - " .. name)
  else
    failed = failed + 1
    print("FAIL - " .. name)
  end
end
local function eq(name, got, want)
  check(name .. "  (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

-- core.localTzOffset(epoch) as a child `lua` computes it with TZ=zone.
local function offsetIn(zone, epoch)
  local code = string.format("local core = dofile(%q); io.write(tostring(core.localTzOffset(%d)))",
    ROOT .. "cc-core.lua", epoch)
  assert(not code:find("'", 1, true), "cc-core.lua path holds a single quote")
  local p = io.popen("TZ='" .. zone .. "' '" .. LUA .. "' -e '" .. code .. "' 2>&1")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  return tonumber(out) or out
end

local JUL15 = 1784116800   -- 2026-07-15 12:00:00Z
local JAN15 = 1768478400   -- 2026-01-15 12:00:00Z

-- ---- Local UTC offset follows daylight saving (2026-09-25) ----
do
  -- 2026-09-25: open-cost-view used os.difftime(now, os.time(os.date("!*t", now))); os.time reads that UTC table as standard time, so EDT came out -5h and the cost chart's days sat an hour late.
  eq("tz: New York in July (EDT) is 4h west of UTC", offsetIn("America/New_York", JUL15), -14400)
  eq("tz: New York in January (EST) is 5h west of UTC", offsetIn("America/New_York", JAN15), -18000)
  eq("tz: Kolkata is 5h30 east of UTC", offsetIn("Asia/Kolkata", JUL15), 19800)
  eq("tz: UTC is 0", offsetIn("UTC", JUL15), 0)
  eq("tz: Lord Howe in January (+11:00 DST) is 11h east of UTC", offsetIn("Australia/Lord_Howe", JAN15), 39600)
  eq("tz: Lord Howe in July (+10:30; its DST moves only half an hour) is 10h30 east of UTC", offsetIn("Australia/Lord_Howe", JUL15), 37800)
end

print(string.format("-- tz-offset.test.lua: %d run, %d failed --", run, failed))
os.exit(failed == 0 and 0 or 1)
