// backoff-hint.test.js - BEHAVIORAL: a card waiting out auto-continue's back-off says so (2026-09-28).
//
// Runs the REAL shipped backoffTail sliced out of claude-dashboard.lua (the turn-label.test.js
// pattern), so there is no copy of the rule to drift. core.stepAutoContinue decides how long the
// next continue still waits (it.backoffSeconds); this is the half that turns it into the card's
// "backing off · 4m": whole minutes, rounded up, and nothing at all for anything but a positive
// number of seconds.
//
// Usage: node tests/backoff-hint.test.js [path/to/claude-dashboard.lua]

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
const tailSrc = slice("    function backoffTail(it){", "\n    }\n");
check("the panel ships backoffTail", tailSrc !== null);

let backoffTail = function () { return null; };
if (tailSrc) backoffTail = new Function(tailSrc + "\nreturn backoffTail;")();

eq("four minutes left reads 4m", backoffTail({ status: "error", backoffSeconds: 240 }), " · backing off · 4m");
eq("a part minute rounds up", backoffTail({ status: "error", backoffSeconds: 181 }), " · backing off · 4m");
eq("under a minute reads 1m, never 0m", backoffTail({ status: "done", backoffSeconds: 12 }), " · backing off · 1m");
eq("the 30-minute cap reads 30m", backoffTail({ status: "done", backoffSeconds: 1800 }), " · backing off · 30m");
eq("not backing off says nothing", backoffTail({ status: "error" }), "");
eq("a wait that's over says nothing", backoffTail({ status: "error", backoffSeconds: 0 }), "");
eq("a non-number never reaches the card", backoffTail({ status: "error", backoffSeconds: "<img src=x onerror=alert(1)>" }), "");
eq("NaN says nothing", backoffTail({ status: "error", backoffSeconds: NaN }), "");
eq("no tile, no suffix", backoffTail(null), "");

console.log("\n-- backoff-hint.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
