// compact-notes.test.js - BEHAVIORAL: a card says when its session has saved notes (2026-09-29).
//
// Auto-compact with notes (build program unit 16): FX.stepCompact stamps it.notes ({ at, bytes })
// when ~/.claude/cc-notes/<key>.notes.md exists, and it.compact ({ due, at, window, atPct }) while
// compaction is on. The card shows a 📝 chip; the detail panel a Notes line. Runs the REAL shipped
// notesBadge / notesLine sliced out of claude-dashboard.lua (the resume-card.test.js pattern).
//
// Usage: node tests/compact-notes.test.js [path/to/claude-dashboard.lua]

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
const escSrc = slice("    function esc(s){", "\n    }\n");
const ageSrc = slice("    function fmtAge(since){", "\n    }\n");
const badgeSrc = slice("    function notesBadge(it){", "\n    }\n");
const lineSrc = slice("    function notesLine(it){", "\n    }\n");
check("the panel ships notesBadge", badgeSrc !== null);
check("the panel ships notesLine", lineSrc !== null);
if (!(escSrc && ageSrc && badgeSrc && lineSrc)) {
  console.log("\n-- compact-notes.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + ageSrc + "\n" + badgeSrc + "\n" + lineSrc + "\nreturn { notesBadge, notesLine };")();
const now = Math.floor(Date.now() / 1000);

// ---- the card's chip ----
eq("no notes: no chip", lib.notesBadge({ key: "k1" }), "");
const b = lib.notesBadge({ key: "k1", notes: { at: now - 300, bytes: 1234 } });
check("notes saved: a 📝 chip", b.indexOf("📝") >= 0);
check("...that says what it is on hover", /title="[^"]*notes[^"]*"/i.test(b));
check("...with nothing from the session in its markup", b.indexOf("1234") < 0);
eq("a null card: nothing", lib.notesBadge(null), "");

// ---- the detail panel's line ----
eq("compaction off, no notes: no line", lib.notesLine({ key: "k1" }), "");
eq("compaction on, no notes yet: when they're due and when it compacts",
   lib.notesLine({ compact: { due: 144000, at: 153000, window: 200000, atPct: 85 } }),
   "📝 Notes due at 144k tokens, compaction at 153k");
eq("an [1m] session's numbers",
   lib.notesLine({ compact: { due: 784000, at: 833000, window: 1000000, atPct: 85 } }),
   "📝 Notes due at 784k tokens, compaction at 833k");
eq("notes saved: how long ago and how big, then the next due-at",
   lib.notesLine({ notes: { at: now - 300, bytes: 1234 }, compact: { due: 144000, at: 153000 } }),
   "📝 Notes saved 5m ago (1.2 KB) · due at 144k tokens, compaction at 153k");
eq("small notes in bytes, and with compaction off only what was saved",
   lib.notesLine({ notes: { at: now - 30, bytes: 17 } }),
   "📝 Notes saved 30s ago (17 B)");
eq("fields that aren't numbers are left out, never printed",
   lib.notesLine({ notes: { at: "<b>", bytes: "x" }, compact: { due: "<i>", at: 1 } }), "");

console.log("\n-- compact-notes.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
