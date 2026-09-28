// turn-label.test.js - BEHAVIORAL: a finished card says how its last turn ended (2026-09-28).
//
// Runs the REAL shipped turnTail (and its TURN_LABELS whitelist) sliced out of
// claude-dashboard.lua, the done-order.test.js pattern, so there is no copy of the rule to drift.
// core.turnOutcome names the turn in Lua; this is the half that decides what reaches the card:
// only a finished tile, and only a label from the known set (the text lands in innerHTML).
//
// Usage: node tests/turn-label.test.js [path/to/claude-dashboard.lua]

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
const labelsSrc = slice("    var TURN_LABELS = ", ";\n");
const tailSrc = slice("    function turnTail(it){", "\n    }\n");
check("the panel ships TURN_LABELS", labelsSrc !== null);
check("the panel ships turnTail", tailSrc !== null);

let turnTail = function () { return null; };
if (labelsSrc && tailSrc) {
  turnTail = new Function(labelsSrc + "\n" + tailSrc + "\nreturn turnTail;")();
}

for (const label of ["done", "made progress", "only planned", "did nothing", "blocked", "needs follow-up"]) {
  eq("a finished card says '" + label + "'", turnTail({ status: "done", turnLabel: label }), " · " + label);
}
eq("a card still working says nothing", turnTail({ status: "working", turnLabel: "made progress" }), "");
eq("a finished card with no label yet says nothing", turnTail({ status: "done" }), "");
eq("an unknown label never reaches the card", turnTail({ status: "done", turnLabel: "<img src=x onerror=alert(1)>" }), "");
eq("no tile, no suffix", turnTail(null), "");

console.log("\n-- turn-label.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
