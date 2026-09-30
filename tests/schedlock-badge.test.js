// schedlock-badge.test.js - BEHAVIORAL: a project card flags a bad scheduled-tasks lock (2026-09-29,
// build program unit 39).
//
// FX.annotateSchedLocks stamps every tile of a card whose launch folder's
// .claude/scheduled_tasks.lock is dead, committed to git or held by another card with
// it.schedLock = { label, tip } (core.schedLockView). The card's badges row shows the label; the
// tooltip says what's wrong and the fix, which Shepherd never runs. Folder paths and card names are
// anyone's text, so both go through esc(). Runs the REAL shipped schedLockBadge / badgesHtml sliced
// out of claude-dashboard.lua (the lease-badge.test.js pattern).
//
// Usage: node tests/schedlock-badge.test.js [path/to/claude-dashboard.lua]

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
const badgeSrc = slice("    function schedLockBadge(it){", "\n    }\n");
const badgesSrc = slice("    function badgesHtml(it){", "\n    }\n");
check("the panel ships schedLockBadge", badgeSrc !== null);
check("the panel ships badgesHtml", badgesSrc !== null);
if (!(escSrc && badgeSrc && badgesSrc)) {
  console.log("\n-- schedlock-badge.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(
  "function talkBadge(){ return ''; } function riskBadge(){ return ''; } function prBadgeHtml(){ return ''; }\n" +
  "function bgBadge(){ return ''; } function notesBadge(){ return ''; } function pinChipsHtml(){ return ''; }\n" +
  "function leaseBadge(){ return ''; } function ticketBadge(){ return ''; } function coachBadge(){ return ''; }\n" +
  escSrc + "\n" + badgeSrc + "\n" + badgesSrc +
  "\nreturn { schedLockBadge, badgesHtml };")();

eq("a healthy card: no badge", lib.schedLockBadge({ key: "k" }), "");
eq("a null card: nothing", lib.schedLockBadge(null), "");
eq("a view with no label: nothing", lib.schedLockBadge({ schedLock: { tip: "x" } }), "");
eq("a non-object view: nothing", lib.schedLockBadge({ schedLock: "🔒 lock dead" }), "");

const tip = "Scheduled-tasks lock: /Users/u/qb/.claude/scheduled_tasks.lock\n• Committed to git.\nFix it yourself (Shepherd never runs these), in /Users/u/qb:\n  git rm --cached .claude/scheduled_tasks.lock";
const h = lib.schedLockBadge({ schedLock: { label: "🔒 lock in git", tip: tip } });
check("the badge shows what's wrong", h.indexOf(">🔒 lock in git</span>") >= 0);
check("...in its own class", h.indexOf('<span class="slock-b"') === 0);
check("...its tooltip carries the fix", h.indexOf("git rm --cached .claude/scheduled_tasks.lock") >= 0);
check("...and keeps its line breaks", h.indexOf("\n  git rm --cached") >= 0);

const evil = lib.schedLockBadge({ schedLock: { label: '🔒 <img src=x onerror=alert(1)>', tip: 'held by "><script>alert(2)</script>' } });
check("a hostile label never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile card name in the tooltip (it can't be closed)", evil.indexOf("<script>") < 0 && evil.indexOf('">') === evil.lastIndexOf('">'));

const row = lib.badgesHtml({ schedLock: { label: "🔒 lock dead", tip: "t" } });
check("the card's badges row carries it", row.indexOf('<span class="badges">') === 0 && row.indexOf(">🔒 lock dead</span>") >= 0);
eq("a card with no lock and no other badge gets no row", lib.badgesHtml({ key: "k" }), "");

console.log("\n-- schedlock-badge.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
