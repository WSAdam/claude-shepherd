// redfirst-view.test.js - BEHAVIORAL fixture for the red-first proof's line in the merge review
// (2026-09-29, build program unit 20). Runs the REAL shipped redFirstText: it is sliced straight
// out of claude-dashboard.lua, so there is no copy of the wording to drift.
//
// The review says whether the unit's changed tests fail without its fix: proved red, not red
// (which files), or couldn't run -- with the failing lines, and how many already fail on main.
// It is a hint beside the gate; the text is set with textContent (the lines are the runner's).
//
// Usage: node tests/redfirst-view.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
const i = src.indexOf("    function redFirstText(rf, base){");
const j = i < 0 ? -1 : src.indexOf("\n    }\n", i);
check("the shipped redFirstText is in the panel source", i >= 0 && j > i);
if (i < 0 || j < 0) { console.log("-- redfirst-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(1); }
const redFirstText = new Function(src.slice(i, j + 7) + "\nreturn redFirstText;")();
const PRE = "Red-first (a hint, not a gate): ";

eq("no verdict: nothing to show", redFirstText(null, "main").text, "");
eq("waiting for the gate", redFirstText({ state: "waiting" }, "main").text, PRE + "waits for the test gate to pass…");
eq("queued in the lane", redFirstText({ state: "queued", files: 2 }, "main").text, PRE + "queued behind another run in this repo…");
eq("running: how many files", redFirstText({ state: "running", files: 2 }, "main").text,
  PRE + "running 2 changed test files without the fix…");
eq("running on the base tip: says which branch", redFirstText({ state: "running", files: 2, checkingBase: true }, "trunk").text,
  PRE + "checking which failures trunk already has…");
eq("no changed test file", redFirstText({ state: "none", files: 0 }, "main").text,
  PRE + "no changed test file to run — nothing was proven red");

let r = redFirstText({ state: "red", files: 2, red: ["tests/a.test.lua", "tests/b.test.sh"], notRed: [], redN: 2, notRedN: 0,
  old: 1, fails: "FAIL - a new behaviour\nFAIL - b new behaviour", log: "/s/rf.log" }, "main");
eq("proved red: says so, then what main already had, then the new failing lines", r.text,
  PRE + "✓ proved red — all 2 changed test files fail without the fix\n"
  + "1 failing line already fails on main — not counted\n"
  + "FAIL - a new behaviour\nFAIL - b new behaviour\nfull log: /s/rf.log");
eq("...styled as proved", r.cls, "dm-redfirst r-red");
eq("one file: singular", redFirstText({ state: "red", files: 1, red: ["t/a.test.lua"], notRed: [], old: 0 }, "main").text,
  PRE + "✓ proved red — the changed test file fails without the fix");

r = redFirstText({ state: "notRed", files: 3, red: ["tests/a.test.lua"], notRed: ["tests/b.test.sh", "tests/c.test.lua"],
  redN: 1, notRedN: 2, old: 2, fails: "FAIL - a new" }, "main");
eq("not red: which files have no new failure, and which do", r.text,
  PRE + "⚠ not red — no new failure without the fix in tests/b.test.sh, tests/c.test.lua\n"
  + "fails without it: tests/a.test.lua\n2 failing lines already fail on main — not counted\nFAIL - a new");
eq("...styled as a warning", r.cls, "dm-redfirst r-notRed");
r = redFirstText({ state: "notRed", files: 25, red: [], notRed: ["a"], redN: 0, notRedN: 21, old: 0 }, "main");
eq("a capped list says how many more", r.text, PRE + "⚠ not red — no new failure without the fix in a (+20 more)");
r = redFirstText({ state: "red", files: 1, red: ["a"], notRed: [], old: 0, baseUnknown: true, loose: 2 }, "main");
check("the base tip couldn't be checked, and loose lines, are said out loud  (" + JSON.stringify(r.text) + ")",
  r.text.indexOf("\ncouldn't check which failures main already has — every failure counted") > 0
  && r.text.indexOf("\n2 failing lines named no changed test file") > 0);

r = redFirstText({ state: "couldntRun", why: "it timed out", log: "/s/rf.log" }, "main");
eq("couldn't run: why, and that nothing was proven", r.text,
  PRE + "couldn't run (it timed out) — nothing was proven either way\nfull log: /s/rf.log");
eq("...styled as a warning, never red", r.cls, "dm-redfirst r-couldntRun");
eq("an unknown state shows nothing", redFirstText({ state: "bogus" }, "main").text, "");

console.log("-- redfirst-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
