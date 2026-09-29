// resume-card.test.js - BEHAVIORAL: a card stopped by a usage limit says when it resumes (2026-09-29).
//
// Runs the REAL shipped resumeTail / resumeBtnsHtml / resumeAct sliced out of claude-dashboard.lua
// (the mailbox-hint.test.js pattern). FX.stepResume stamps it.resume from core.resumeCard: "resumes
// at 3:00pm" with Cancel and Resume now while it waits, "limit reset — continue it" where nothing
// may be typed, "Opus limit — switch model" for a per-model limit. The buttons read the session
// from the card's data-key, never from interpolated text.
//
// Usage: node tests/resume-card.test.js [path/to/claude-dashboard.lua]

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
const tailSrc = slice("    function resumeTail(it){", "\n    }\n");
const btnSrc = slice("    function resumeBtnsHtml(it){", "\n    }\n");
const actSrc = slice("    function resumeAct(ev, what){", "\n    }\n");
check("the panel ships resumeTail", tailSrc !== null);
check("the panel ships resumeBtnsHtml", btnSrc !== null);
check("the panel ships resumeAct", actSrc !== null);
if (!(escSrc && tailSrc && btnSrc && actSrc)) {
  console.log("\n-- resume-card.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

const sent = [];
const lib = new Function("send",
  escSrc + "\n" + tailSrc + "\n" + btnSrc + "\n" + actSrc + "\nreturn { resumeTail, resumeBtnsHtml, resumeAct };")(
  function (a, v) { sent.push([a, v]); });

eq("waiting: the status line says when",
   lib.resumeTail({ status: "error", resume: { phase: "waiting", line: "resumes at 3:00pm", cancel: true, now: true } }),
   " · resumes at 3:00pm");
eq("a shared window past the reset: continue it",
   lib.resumeTail({ status: "error", resume: { phase: "reset", line: "limit reset — continue it" } }),
   " · limit reset — continue it");
eq("a per-model limit: switch model",
   lib.resumeTail({ status: "error", resume: { phase: "model", line: "Opus limit — switch model" } }),
   " · Opus limit — switch model");
eq("no resume says nothing", lib.resumeTail({ status: "error" }), "");
eq("no tile, no suffix", lib.resumeTail(null), "");
eq("a non-string line never reaches the card", lib.resumeTail({ resume: { line: { toString: () => "<b>" } } }), "");

const both = lib.resumeBtnsHtml({ key: "k1", resume: { phase: "waiting", line: "resumes at 3:00pm", cancel: true, now: true } });
check("waiting: Resume now and Cancel buttons", both.indexOf(">Resume now</button>") >= 0 && both.indexOf(">Cancel</button>") >= 0);
check("...each its own control on the card (data-nodbl: a press never selects or jumps)",
      (both.match(/data-nodbl/g) || []).length === 2);
check("...never carrying the session key in the markup", both.indexOf("k1") < 0);
const cancelOnly = lib.resumeBtnsHtml({ resume: { phase: "due", line: "resuming now", cancel: true } });
check("past the reset: Cancel only", cancelOnly.indexOf(">Cancel</button>") >= 0 && cancelOnly.indexOf("Resume now") < 0);
eq("no buttons for a line alone", lib.resumeBtnsHtml({ resume: { phase: "reset", line: "limit reset — continue it" } }), "");
eq("no buttons without a resume", lib.resumeBtnsHtml({}), "");

// the press: the key comes from the enclosing card's data-key
function press(what, key) {
  let stopped = false;
  const tile = { getAttribute: (a) => (a === "data-key" ? key : null) };
  lib.resumeAct({ stopPropagation: () => { stopped = true; }, target: { closest: () => tile } }, what);
  return stopped;
}
check("Resume now sends resume-now for the card's session", press("now", "k-now") && JSON.stringify(sent.pop()) === '["resume-now","k-now"]');
check("Cancel sends resume-cancel", press("cancel", "k-c") && JSON.stringify(sent.pop()) === '["resume-cancel","k-c"]');
lib.resumeAct({ stopPropagation: () => {}, target: { closest: () => null } }, "now");
eq("a press outside a card sends nothing", sent.length, 0);

// the card carries both, escaped like its neighbours
const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile's status line appends the escaped tail", tile.indexOf("label += esc(resumeTail(it));") >= 0);
check("the tile draws the buttons", tile.indexOf("+ resumeBtnsHtml(it)") >= 0);

console.log("\n-- resume-card.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
