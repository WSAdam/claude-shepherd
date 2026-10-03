// maingreen-badge.test.js - BEHAVIORAL: a project card flags a main that went red (2026-10-03, mining
// round 2 unit E1b).
//
// FX.stepMainGreen stamps every tile of a repo whose scheduled main-green check last ran red with
// it.mainRed = { label, tip } (core.mainRedView). The card's badges row shows the label; the tooltip
// carries the failing lines, which are the runner's own output, so both go through esc(). Runs the
// REAL shipped mainRedBadge / badgesHtml sliced out of claude-dashboard.lua (the
// schedlock-badge.test.js pattern).
//
// Usage: node tests/maingreen-badge.test.js [path/to/claude-dashboard.lua]

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
const badgeSrc = slice("    function mainRedBadge(it){", "\n    }\n");
const badgesSrc = slice("    function badgesHtml(it){", "\n    }\n");
check("the panel ships mainRedBadge", badgeSrc !== null);
check("the panel ships badgesHtml", badgesSrc !== null);
if (!(escSrc && badgeSrc && badgesSrc)) {
  console.log("\n-- maingreen-badge.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(
  "function talkBadge(){ return ''; } function riskBadge(){ return ''; } function prBadgeHtml(){ return ''; }\n" +
  "function holdBadge(){ return ''; }\n" +
  "function bgBadge(){ return ''; } function notesBadge(){ return ''; } function pinChipsHtml(){ return ''; }\n" +
  "function leaseBadge(){ return ''; } function ticketBadge(){ return ''; } function coachBadge(){ return ''; }\n" +
  "function schedLockBadge(){ return ''; }\n" +
  escSrc + "\n" + badgeSrc + "\n" + badgesSrc +
  "\nreturn { mainRedBadge, badgesHtml };")();

eq("a green repo: no badge", lib.mainRedBadge({ key: "k" }), "");
eq("a null card: nothing", lib.mainRedBadge(null), "");
eq("a view with no label: nothing", lib.mainRedBadge({ mainRed: { tip: "x" } }), "");
eq("a non-object view: nothing", lib.mainRedBadge({ mainRed: "main is red" }), "");

const tip = "main is red at abc1234: make lint && make test failed (2026-10-03 07:00)\nFAIL - two\n-- core.test.lua: 2 run, 1 failed --";
const h = lib.mainRedBadge({ mainRed: { label: "🔴 main is red", tip: tip } });
check("the badge says main is red", h.indexOf(">🔴 main is red</span>") >= 0);
check("...in its own class", h.indexOf('<span class="mainred-b"') === 0);
check("...its tooltip carries the failing lines", h.indexOf("FAIL - two") >= 0 && h.indexOf("make lint &amp;&amp; make test") >= 0);
check("...and keeps their line breaks", h.indexOf("\nFAIL - two") >= 0);

const evil = lib.mainRedBadge({ mainRed: { label: '🔴 <img src=x onerror=alert(1)>', tip: 'FAIL - "><script>alert(2)</script>' } });
check("a hostile label never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile failing line in the tooltip (it can't be closed)", evil.indexOf("<script>") < 0 && evil.indexOf('">') === evil.lastIndexOf('">'));

const row = lib.badgesHtml({ mainRed: { label: "🔴 main is red", tip: "t" } });
check("the card's badges row carries it", row.indexOf('<span class="badges">') === 0 && row.indexOf(">🔴 main is red</span>") >= 0);
eq("a card with no flag and no other badge gets no row", lib.badgesHtml({ key: "k" }), "");

console.log("\n-- maingreen-badge.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
