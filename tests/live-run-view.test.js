// live-run-view.test.js - BEHAVIORAL: the ▶ live run chip on My List (2026-09-29, build program
// unit 37).
//
// Some TODO items can only be checked by a live run. core.parseTodoFile flags `- [~]` lines and
// lines carrying `(needs live run)` / `(live check)` with liveRun = true, and each such row shows
// a ▶ live run chip. The chip is a fixed string: nothing a session wrote reaches it, and only a
// real `true` shows it (a tampered worklist file can't smuggle markup in through the flag). It is
// never a done claim -- `[~]` is never done, and the row's checkbox stays Adam's own. Runs the REAL
// shipped wlLiveRunChip / wlIsLiveRun / wlFileBadges sliced out of claude-dashboard.lua (the
// audit-findings-view.test.js pattern).
//
// Usage: node tests/live-run-view.test.js [path/to/claude-dashboard.lua]

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
const isLiveSrc = slice("    function wlIsLiveRun(it){", "\n    }\n");
const chipSrc = slice("    function wlLiveRunChip(it){", "\n    }\n");
const auditSrc = slice("    function wlAuditChip(it){", "\n    }\n");
const branchSrc = slice("    function wlBranchChip(it){", "\n    }\n");
const badgesSrc = slice("    function wlFileBadges(it, isDone){", "\n    }\n");
check("the panel ships wlIsLiveRun", isLiveSrc !== null);
check("the panel ships wlLiveRunChip", chipSrc !== null);
if (!(escSrc && isLiveSrc && chipSrc && auditSrc && branchSrc && badgesSrc)) {
  console.log("\n-- live-run-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

const lib = new Function(escSrc + "\n" + isLiveSrc + "\n" + chipSrc + "\n" + auditSrc + "\n" + branchSrc + "\n" + badgesSrc +
  "\nreturn { wlIsLiveRun, wlLiveRunChip, wlFileBadges };")();

eq("a plain TODO line: no live-run chip", lib.wlLiveRunChip({ text: "x" }), "");
eq("a null row: nothing", lib.wlLiveRunChip(null), "");
const chip = lib.wlLiveRunChip({ text: "open the panel", liveRun: true });
check("a live-run line shows ▶ live run", chip.indexOf("▶ live run") >= 0);
check("...in its own class", chip.indexOf('class="wl-live"') >= 0);
check("...its tooltip says only a live run can check it", /live run/i.test(chip) && chip.indexOf("title=") >= 0);
check("...and it never carries the line's own text", chip.indexOf("open the panel") < 0);

// only a real true shows the chip: the flag is never rendered, so a string can't inject markup
eq("a string flag is not a live run", lib.wlLiveRunChip({ liveRun: '"><img src=x onerror=alert(1)>' }), "");
eq("...nor a number", lib.wlLiveRunChip({ liveRun: 1 }), "");
eq("wlIsLiveRun: true only for a real true", [lib.wlIsLiveRun({ liveRun: true }), lib.wlIsLiveRun({ liveRun: "true" }),
   lib.wlIsLiveRun({}), lib.wlIsLiveRun(null)].join(","), "true,false,false,false");

const open = lib.wlFileBadges({ text: "x", liveRun: true }, false);
check("an open [~] row's badges carry the chip", open.indexOf("wl-live") >= 0);
check("...and no ✓ auto: a [~] line is never claimed done", open.indexOf("✓ auto") < 0);
const claimed = lib.wlFileBadges({ text: "x (needs live run)", liveRun: true, fileDone: true }, false);
check("a marked [x] row keeps its ✓ auto badge", claimed.indexOf("✓ auto") >= 0);
check("...and gains the chip", claimed.indexOf("wl-live") >= 0);
check("...the chip before the done claim, like the other file chips", claimed.indexOf("wl-live") < claimed.indexOf("wl-fdone"));
check("a plain row's badges carry no chip", lib.wlFileBadges({ text: "x", fileDone: true }, false).indexOf("wl-live") < 0);

console.log("\n-- live-run-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
