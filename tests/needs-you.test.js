// needs-you.test.js - BEHAVIORAL fixture for how a card says it is waiting on Adam (2026-09-11).
// 2026-09-11 live: a driver's batch waited for Adam's approval, but its session had finished its
// turn, so the card read a green "Ready for you" with only a thin ring -- Adam had no idea it was
// waiting on him. Slices the REAL bgRunning / needsYouNow / effStatus / statusWords (and LABELS)
// out of claude-dashboard.lua and runs them, then pins the tile class and its pulse.
//
// Usage: node tests/needs-you.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  return j < 0 ? null : src.slice(i, j + endNeedle.length);
}
const parts = {
  labels: slice("    var LABELS = {", "};\n"),
  bg: slice("    function bgRunning(it){", "}\n"),
  driving: slice("    function isDriving(it){", "}\n"),
  needs: slice("    function needsYouNow(it){", "}\n"),
  eff: slice("    function effStatus(it){", "}\n"),
  words: slice("    function statusWords(it){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") +
  "\nreturn { needsYouNow: needsYouNow, effStatus: effStatus, statusWords: statusWords };")();

// the live card: the driver finished its turn; its batch waits for Adam
const driver = { key: "drv", status: "done", fleet: { phase: "proposed", needsYou: true, line: "⇉ proposes 1 unit" } };
check("a batch waiting for approval: the card needs Adam", api.needsYouNow(driver));
eq("...its dot is the approval colour, not done's green", api.effStatus(driver), "approval");
eq("...and it reads Needs you, not Ready for you", api.statusWords(driver), "Needs you");
const merge = { key: "u", status: "done", merge: { phase: "requested", needsYou: true } };
eq("a merge waiting for Adam's click reads Needs you", api.statusWords(merge), "Needs you");
const ask = { key: "q", status: "approval", askHeld: true };
eq("a held question reads Needs you", api.statusWords(ask), "Needs you");
const busy = { key: "b", status: "done", bg_active: true, bg_count: 2, fleet: { needsYou: true } };
eq("waiting on Adam wins over background agents running", api.effStatus(busy), "approval");
const plain = { key: "p", status: "done" };
eq("a plain finished session still reads Ready for you", api.statusWords(plain), "Ready for you");
check("...and doesn't need Adam", !api.needsYouNow(plain));
const merging = { key: "m", status: "working", merge: { phase: "merging", needsYou: false } };
eq("a merge already running doesn't need Adam", api.effStatus(merging), "working");

// 2026-09-15 live: the Chargeback Sentinel driver handed its 2 units their tasks and ended its turn;
// its card read a green "Ready for you" while both units worked.
const driving = { key: "drv", status: "done", fleet: { phase: "approved", needsYou: false, units: [{}, {}] } };
eq("a driver whose batch is running is working, not ready", api.effStatus(driving), "working");
eq("...and says it's driving its units", api.statusWords(driving), "Driving 2 units");
eq("...one unit, singular", api.statusWords({ key: "d1", status: "idle", fleet: { phase: "approved", units: [{}] } }), "Driving 1 unit");
eq("a driver whose batch ended reads Ready for you again",
   api.statusWords({ key: "d2", status: "done", fleet: { phase: "stopped", units: [{}, {}] } }), "Ready for you");
eq("a driving session that asks Adam something still reads Needs you",
   api.statusWords({ key: "d3", status: "approval", askHeld: true, fleet: { phase: "approved", units: [{}] } }), "Needs you");

const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile pulses whenever it needs Adam (class needs)", tile.indexOf('(needsYouNow(it) ? " needs" : "")') >= 0);
check("the pulse is styled", /\.tile\.needs \{ animation:askglow/.test(src));

// 2026-09-11 live: "merged -- close its tab yourself" made the card red with nothing to press. Every
// finished merge state that needs Adam gets buttons in the review: Close tab (merged, tab open) and Dismiss.
const rm = slice("    function renderMerge(it){", "\n    }\n") || "";
// 2026-09-15 requirement change: a merged unit's leftover tab is no longer "needs you" (it's
// housekeeping), but its review keeps the buttons -- any finished merge with a note gets them.
check("the review shows its finished-state buttons for any finished merge with a note (needs you or not)",
      rm.indexOf('document.getElementById("dm-done").style.display = (!asking && (m.needsYou || m.closeNote || m.phase === "merged-dirty")) ? "flex" : "none";') >= 0);
check("...Close tab only while the merged unit's tab is still open",
      rm.indexOf('document.getElementById("dm-closetab").style.display = (m.phase === "merged" && m.closeNote) ? "" : "none";') >= 0);
check("the buttons exist and send their actions",
      src.indexOf("mergeAct('merge-close-tab')") >= 0 && src.indexOf("mergeAct('merge-dismiss')") >= 0);
check("Shepherd handles both actions",
      src.indexOf('if a == "merge-close-tab" then') >= 0 && src.indexOf('if a == "merge-dismiss" then') >= 0);

console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
