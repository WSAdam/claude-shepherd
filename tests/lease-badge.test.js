// lease-badge.test.js - BEHAVIORAL: a card shows its worktree's leased port (2026-09-29, build
// program unit 27).
//
// Shepherd leases each worktree it starts a session for its own PORT and DB path; FX.stepLeases
// stamps it on the session as it.lease ({ port, db }). The card's badges row shows ":PORT", with the
// database path in its tooltip. Both come from a file on disk, so both go through esc(). Runs the
// REAL shipped leaseTitle / leaseBadge / badgesHtml sliced out of claude-dashboard.lua (the
// pins-view.test.js pattern).
//
// Usage: node tests/lease-badge.test.js [path/to/claude-dashboard.lua]

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
const titleSrc = slice("    function leaseTitle(ls){", "\n    }\n");
const badgeSrc = slice("    function leaseBadge(it){", "\n    }\n");
const badgesSrc = slice("    function badgesHtml(it){", "\n    }\n");
check("the panel ships leaseTitle", titleSrc !== null);
check("the panel ships leaseBadge", badgeSrc !== null);
if (!(escSrc && titleSrc && badgeSrc && badgesSrc)) {
  console.log("\n-- lease-badge.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(
  "function talkBadge(){ return ''; } function riskBadge(){ return ''; } function prBadgeHtml(){ return ''; }\n" +
  "function bgBadge(){ return ''; } function notesBadge(){ return ''; } function pinChipsHtml(){ return ''; }\n" +
  escSrc + "\n" + titleSrc + "\n" + badgeSrc + "\n" + badgesSrc +
  "\nreturn { leaseBadge, badgesHtml };")();

eq("no lease: no badge", lib.leaseBadge({ key: "k" }), "");
eq("a null card: nothing", lib.leaseBadge(null), "");
eq("a lease with no port: nothing", lib.leaseBadge({ lease: { db: "/d/x.db" } }), "");
const h = lib.leaseBadge({ lease: { port: 4107, db: "/Users/u/.claude/cc-lease/db/main-a-4107.db" } });
check("the badge reads :PORT", h.indexOf(">:4107</span>") >= 0);
check("...in its own class", h.indexOf('class="lease-b"') === 0 || h.indexOf('<span class="lease-b"') === 0);
check("...its tooltip names the database path", h.indexOf("/Users/u/.claude/cc-lease/db/main-a-4107.db") >= 0);
check("...and the env file", h.indexOf("shepherd-lease.env") >= 0);
const evil = lib.leaseBadge({ lease: { port: '<img src=x onerror=alert(1)>', db: '/d/"><script>alert(2)</script>.db' } });
check("a hostile port never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile database path (the tooltip can't be closed)", evil.indexOf("<script>") < 0 && evil.indexOf('">') === evil.lastIndexOf('">'));
const row = lib.badgesHtml({ lease: { port: 4101, db: "/d/b.db" } });
check("the card's badges row carries it", row.indexOf('<span class="badges">') === 0 && row.indexOf(">:4101</span>") >= 0);
eq("a card with no lease and no other badge gets no row", lib.badgesHtml({ key: "k" }), "");

console.log("\n-- lease-badge.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
