// done-order.test.js - BEHAVIORAL fixture for the worklist Done drawer's ordering.
//
// The panel JS has no headless runtime in the bash+lua suite, so the rest of the
// worklist coverage is source tripwires. Those pin that the comparator's TEXT is
// present; they cannot catch a comparator that is present and wrong. This runs the
// REAL shipped comparator: it slices wlDueSort + the done.sort block straight out of
// claude-dashboard.lua and executes them, so there is no copy of the rule to drift.
//
// 2026-09-02: written after the Done drawer came back in arbitrary order. It sorted
// on the due date and never read doneTs, and every TODO-imported item has no due
// date -- so all of them tied, and the comparator returned 1 (not 0) for a tie,
// which is inconsistent, so V8 scrambled the whole run.
//
// Usage: node tests/done-order.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }

// ---- slice the real functions out of the panel source -----------------------
const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const dueSrc  = slice("    function wlDueSort(due){", "\n    }\n");
// Shape-agnostic on purpose: take everything from the sort call to the line its
// `});` closes on, so a one-line comparator and a block one both extract and get
// JUDGED. (An extractor that only matched the fixed shape would "go red" on the
// old code by failing to find it -- proving nothing about how it sorted.)
const sortSrc = (function () {
  const i = src.indexOf("      done.sort(function(a, b){");
  if (i < 0) return null;
  const j = src.indexOf("});", i);
  if (j < 0) return null;
  const eol = src.indexOf("\n", j);
  return src.slice(i, eol < 0 ? src.length : eol + 1);
})();
// A refactor that removes either one must FAIL here, never pass vacuously.
check("extracted wlDueSort from the panel source", dueSrc !== null);
check("extracted the done.sort comparator from the panel source", sortSrc !== null);
if (!dueSrc || !sortSrc) {
  console.log("-- done-order.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const runSort = new Function(dueSrc + "\nreturn function(done){\n" + sortSrc + "\nreturn done;\n};")();

// ---- fixture: one frozen list exercising every ordering rule -----------------
const items = [
  { id: "a",       doneTs: 1000, due: "" },
  { id: "b",       doneTs: 3000, due: "" },
  { id: "c",       doneTs: 2000, due: "" },
  { id: "legacy1", doneTs: 0,    due: "2026-07-22" },   // finished before stamps existed
  { id: "legacy2", doneTs: 0,    due: "2026-07-24" },
  { id: "tieA",    doneTs: 2500, due: "2026-08-01" },   // same stamp, older due
  { id: "tieB",    doneTs: 2500, due: "2026-09-01" },   // same stamp, newer due
  { id: "dupA",    doneTs: 1500, due: "" },             // genuine tie: input order
  { id: "dupB",    doneTs: 1500, due: "" },
];
const order = runSort(items.slice()).map(function (i) { return i.id; }).join(",");
eq("orders the whole list newest-ticked first", order, "b,tieB,tieA,c,dupA,dupB,a,legacy2,legacy1");
eq("the most recently ticked item is first", order.split(",")[0], "b");
eq("items ticked before stamps existed sink to the bottom", order.split(",").slice(-2).join(","), "legacy2,legacy1");
eq("same stamp falls back to the newest due date", order.indexOf("tieB") < order.indexOf("tieA"), true);
eq("a genuine tie keeps the list's own order", order.indexOf("dupA") < order.indexOf("dupB"), true);

// THE BUG'S OWN SHAPE: many items, no due dates (every TODO-imported item), ticked
// on different days. The old comparator tied all of them and returned 1 per tie,
// so V8 scrambled the run instead of leaving it alone.
const undated = [];
for (let i = 0; i < 30; i++) undated.push({ id: "u" + i, doneTs: 1000 + i, due: "" });
for (let i = undated.length - 1; i > 0; i--) {           // deterministic shuffle
  const j = (i * 7 + 3) % (i + 1);
  const t = undated[i]; undated[i] = undated[j]; undated[j] = t;
}
const sorted = runSort(undated.slice());
let inversions = 0;
for (let i = 1; i < sorted.length; i++) if (sorted[i].doneTs > sorted[i - 1].doneTs) inversions++;
eq("30 undated items ticked on different days come back strictly newest-first", inversions, 0);
eq("...and none are lost or duplicated by the sort", new Set(sorted.map(function (i) { return i.id; })).size, 30);

console.log("-- done-order.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
