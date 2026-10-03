// hold-view.test.js - BEHAVIORAL: the hands-off hold on the card and in the detail panel (2026-10-03,
// mining round 2 unit D2).
//
// Runs the REAL shipped holdBadge, holdPanelHtml, setFreeze and mailboxTail sliced out of
// claude-dashboard.lua (the mailbox-hint.test.js pattern). FX.annotateHolds stamps it.hold =
// { scope, skipped }: a HOLD badge for the session's own hold, FROZEN for the fleet freeze; the detail
// panel says so and lists the sends Shepherd skipped meanwhile, each once with ×N, never replayed --
// and keeps the list readable after the hold is lifted, with Clear. A skipped send's summary came
// from a session or its queue, so every field goes through esc().
//
// Usage: node tests/hold-view.test.js [path/to/claude-dashboard.lua]

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
const clockSrc = slice("    function traceClock(at){", "\n    }\n");
const badgeSrc = slice("    function holdBadge(it){", "\n    }\n");
const panelSrc = slice("    function holdPanelHtml(h){", "\n    }\n");
const tailSrc = slice("    function mailboxTail(it){", "\n    }\n");
const freezeSrc = slice("    function setFreeze(on){", "\n    }\n");
check("the panel ships esc, traceClock, holdBadge, holdPanelHtml, mailboxTail and setFreeze",
      !!(escSrc && clockSrc && badgeSrc && panelSrc && tailSrc && freezeSrc));
if (!(escSrc && clockSrc && badgeSrc && panelSrc && tailSrc && freezeSrc)) {
  console.log("\n-- hold-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const els = { freeze: { textContent: "", classList: { on: false, toggle(c, v) { this.on = !!v; } } } };
const document = { getElementById: (id) => els[id] || null };
const lib = new Function("document", escSrc + "\n" + clockSrc + "\n" + badgeSrc + "\n" + panelSrc + "\n" + tailSrc
  + "\nvar freezeOn = false;\n" + freezeSrc
  + "\nreturn { holdBadge: holdBadge, holdPanelHtml: holdPanelHtml, mailboxTail: mailboxTail, setFreeze: setFreeze };")(document);

// ---- the badge ----
check("a session on hold shows HOLD", lib.holdBadge({ hold: { scope: "session", skipped: [] } }).indexOf(">HOLD<") >= 0
      && lib.holdBadge({ hold: { scope: "session" } }).indexOf('class="hold"') >= 0);
check("a frozen fleet shows FROZEN on every card", lib.holdBadge({ hold: { scope: "fleet" } }).indexOf(">FROZEN<") >= 0);
eq("no hold, no badge", lib.holdBadge({}), "");
eq("a released session with skipped sends to read shows no badge", lib.holdBadge({ hold: { skipped: [{ kind: "feed" }] } }), "");
eq("an unknown scope never reaches the card", lib.holdBadge({ hold: { scope: "<img src=x onerror=alert(1)>" } }), "");

// ---- the detail panel's block ----
const at = Math.floor(new Date(2026, 9, 3, 14, 5, 9).getTime() / 1000);
const skipped = [
  { at: at - 60, kind: "feed", label: "Auto-feed", summary: "feed 'fix the tests'", count: 1 },
  { at: at, kind: "continue", label: "Auto-continue", summary: "continue", count: 3 },
];
const onHold = lib.holdPanelHtml({ scope: "session", skipped: skipped });
check("on hold: says so, and that its mail waits", onHold.indexOf("On hold") >= 0 && onHold.indexOf("mail waits") >= 0);
check("...lists each skipped send by its label and what it would have done",
      onHold.indexOf("Auto-feed: feed &#39;fix the tests&#39;") >= 0 || onHold.indexOf("Auto-feed: feed 'fix the tests'") >= 0);
check("...newest first", onHold.indexOf("Auto-continue") < onHold.indexOf("Auto-feed"));
check("...a repeat as ×N", onHold.indexOf("×3") >= 0);
check("...says when", onHold.indexOf("14:05:09") >= 0);
check("...and says they are never replayed", onHold.indexOf("never replayed") >= 0);
check("...no Clear while it is still held", onHold.indexOf("hold-clear") < 0);
const frozen = lib.holdPanelHtml({ scope: "fleet", skipped: [] });
check("frozen: says the fleet is frozen", frozen.indexOf("The fleet is frozen") >= 0);
const after = lib.holdPanelHtml({ skipped: skipped });
check("lifted: the list stays readable", after.indexOf("While it was on hold") >= 0 && after.indexOf("Auto-feed") >= 0);
check("...with Clear", after.indexOf("act('hold-clear')") >= 0);
eq("nothing held, nothing listed: no block", lib.holdPanelHtml({ skipped: [] }), "");
eq("no hold at all: no block", lib.holdPanelHtml(null), "");
check("Lua's empty table ({} not []) doesn't break it", typeof lib.holdPanelHtml({ scope: "session", skipped: {} }) === "string");
const evil = "<img src=x onerror=alert(1)>";
const hostile = lib.holdPanelHtml({ scope: "session", skipped: [{ at: at, kind: evil, label: evil, summary: evil, count: 2 }] });
check("no field reaches the HTML raw", hostile.indexOf("<img") < 0);
check("...each is entity-encoded instead", hostile.split("&lt;img").length - 1 === 2);

// ---- the mail a held session keeps ----
eq("a held session's waiting mail says it waits on the hold", lib.mailboxTail({ mailboxWaiting: 1, mailboxHeld: true }),
   " · 1 message waiting (on hold)");
eq("...and without the hold, as before", lib.mailboxTail({ mailboxWaiting: 2 }), " · 2 messages waiting");

// ---- the toolbar's ❄ Freeze follows the state Lua pushes ----
lib.setFreeze(true);
check("frozen: the button is lit and says so", els.freeze.classList.on === true && els.freeze.textContent === "❄ Frozen");
lib.setFreeze(false);
check("thawed: it goes back", els.freeze.classList.on === false && els.freeze.textContent === "❄");

// ---- wiring: the card's badges row and the detail panel use them ----
check("the card's badges row carries the HOLD badge", src.indexOf("riskBadge(it) + holdBadge(it) + prBadgeHtml(it)") >= 0);
check("the detail panel renders the block through holdPanelHtml",
      src.indexOf("var hh = holdPanelHtml(it && it.hold);") >= 0 && src.indexOf("renderHold(it);") >= 0);
check("the toolbar has the ❄ Freeze button", src.indexOf('<button id="freeze" onclick="toggleFreeze()"') >= 0);
check("the detail panel has the Hold button", src.indexOf('<button id="b-hold"    onclick="act(\'hold\')"') >= 0);

console.log("\n-- hold-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
