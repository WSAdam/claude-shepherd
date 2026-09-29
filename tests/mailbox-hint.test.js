// mailbox-hint.test.js - BEHAVIORAL: a card whose Shepherd message is waiting says so (2026-09-29).
//
// Runs the REAL shipped mailboxTail sliced out of claude-dashboard.lua (the backoff-hint.test.js
// pattern). FX.stepMailbox stamps it.mailboxWaiting on an idle session Shepherd may not type into
// (a VS Code window shared by several Claude tabs): its message waits for the session's next turn
// end or start, and the card says so. Anything but a positive whole count says nothing.
//
// Usage: node tests/mailbox-hint.test.js [path/to/claude-dashboard.lua]

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
const tailSrc = slice("    function mailboxTail(it){", "\n    }\n");
check("the panel ships mailboxTail", tailSrc !== null);

let mailboxTail = function () { return null; };
if (tailSrc) mailboxTail = new Function(tailSrc + "\nreturn mailboxTail;")();

eq("one message waiting", mailboxTail({ status: "done", mailboxWaiting: 1 }), " · 1 message waiting");
eq("two messages waiting", mailboxTail({ status: "done", mailboxWaiting: 2 }), " · 2 messages waiting");
eq("nothing waiting says nothing", mailboxTail({ status: "done" }), "");
eq("zero says nothing", mailboxTail({ status: "done", mailboxWaiting: 0 }), "");
eq("a non-number never reaches the card", mailboxTail({ status: "done", mailboxWaiting: "<img src=x onerror=alert(1)>" }), "");
eq("NaN says nothing", mailboxTail({ status: "done", mailboxWaiting: NaN }), "");
eq("no tile, no suffix", mailboxTail(null), "");

// the card's status line carries it, escaped like its neighbours
const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile's status line appends the escaped tail", tile.indexOf("label += esc(mailboxTail(it));") >= 0);

console.log("\n-- mailbox-hint.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
