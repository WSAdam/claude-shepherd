// worklist-lanes.test.js - BEHAVIORAL: the panel's wlLane twin answers to the same table as
// core.worklistLane (2026-10-13).
//
// Adam's My List reached 262 open items, 243 of them "✓ auto" claims waiting for his check, which
// buried the ~19 that were real work. My List now splits open items into To do and To verify (an
// open item whose file claims it: [x] = fileDone, [~] = fileWait), and "✓ Mark all N done" marks
// the lane he picked. The panel filters and counts with wlLane while Lua marks with
// core.worklistLane, so both read tests/fixtures/worklist-lanes.tsv: if they ever disagreed, the
// count on the button would not be what Mark all marks. Runs the REAL shipped wlLane sliced out of
// claude-dashboard.lua (the live-run-view.test.js pattern).
//
// Usage: node tests/worklist-lanes.test.js [path/to/claude-dashboard.lua]

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
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const laneSrc = slice("    function wlLane(it){", "\n    }\n");
check("the panel ships wlLane", laneSrc !== null);
if (laneSrc === null) {
  console.log("-- worklist-lanes.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const wlLane = new Function(laneSrc + "\nreturn wlLane;")();

const table = fs.readFileSync(path.join(__dirname, "fixtures", "worklist-lanes.tsv"), "utf8");
let n = 0;
table.split("\n").forEach(function (line) {
  if (!line || line[0] === "#") return;
  const tab = line.indexOf("\t");
  if (tab < 0) return;
  const want = line.slice(0, tab), js = line.slice(tab + 1);
  n++;
  eq("worklist-lanes.tsv: " + want + "  " + js, wlLane(JSON.parse(js)), want);
});
check("the table was read (12+ cases)", n >= 12);
eq("a missing item is To do, not an error", wlLane(null), "todo");
eq("...and so is an undefined one", wlLane(undefined), "todo");

console.log("-- worklist-lanes.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
