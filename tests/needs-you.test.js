// needs-you.test.js - BEHAVIORAL fixture for how a card says it is waiting on Adam (2026-09-11).
// 2026-09-11 live: a driver's batch waited for Adam's approval, but its session had finished its
// turn, so the card read a green "Ready for you" with only a thin ring -- Adam had no idea it was
// waiting on him. Slices the REAL bgRunning / needsYouNow / effStatus / statusWords (and LABELS)
// out of claude-dashboard.lua and runs them, then pins the tile class and its pulse.
//
// Usage: node tests/needs-you.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  return j < 0 ? null : src.slice(i, j + endNeedle.length);
}
const parts = {
  labels: slice("    var LABELS = {", "};\n"),
  bg: slice("    function bgRunning(it){", "}\n"),
  driving: slice("    function isDriving(it){", "}\n"),
  needs: slice("    function needsYouNow(it){", "}\n"),
  fyi: slice("    function headsUp(it){", "}\n"),
  ring: slice("    function mergeRing(it){", "\n    }\n"),
  eff: slice("    function effStatus(it){", "}\n"),
  words: slice("    function statusWords(it){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  
  console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") +
  "\nreturn { needsYouNow: needsYouNow, headsUp: headsUp, mergeRing: mergeRing, effStatus: effStatus, statusWords: statusWords };")();

// the live card: the driver finished its turn; its batch waits for Adam
const driver = { key: "drv", status: "done", fleet: { phase: "proposed", needsYou: true, line: "⇉ proposes 1 unit" } };
check("a batch waiting for approval: the card needs Adam", api.needsYouNow(driver));
eq("...its dot is the approval colour, not done's green", api.effStatus(driver), "approval");
eq("...and it reads Needs you, not Ready for you", api.statusWords(driver), "Needs you");
const merge = { key: "u", status: "done", merge: { phase: "requested", needsYou: true } };
eq("a merge waiting for Adam's click reads Needs you", api.statusWords(merge), "Needs you");
const ask = { key: "q", status: "approval", askHeld: true };
eq("a held question reads Needs you", api.statusWords(ask), "Needs you");
const busy = { key: "b", status: "done", bg_active: true, bg_count: 2, fleet: { needsYou: true } };
eq("waiting on Adam wins over background agents running", api.effStatus(busy), "approval");
const plain = { key: "p", status: "done" };
eq("a plain finished session still reads Ready for you", api.statusWords(plain), "Ready for you");
check("...and doesn't need Adam", !api.needsYouNow(plain));
const merging = { key: "m", status: "working", merge: { phase: "merging", needsYou: false } };
eq("a merge already running doesn't need Adam", api.effStatus(merging), "working");

// 2026-09-15 live: the Chargeback Sentinel driver handed its 2 units their tasks and ended its turn;
// its card read a green "Ready for you" while both units worked.
const driving = { key: "drv", status: "done", fleet: { phase: "approved", needsYou: false, units: [{}, {}] } };
eq("a driver whose batch is running is working, not ready", api.effStatus(driving), "working");
eq("...and says it's driving its units", api.statusWords(driving), "Driving 2 units");
eq("...one unit, singular", api.statusWords({ key: "d1", status: "idle", fleet: { phase: "approved", units: [{}] } }), "Driving 1 unit");
eq("a driver whose batch ended reads Ready for you again",
   api.statusWords({ key: "d2", status: "done", fleet: { phase: "stopped", units: [{}, {}] } }), "Ready for you");
eq("a driving session that asks Adam something still reads Needs you",
   api.statusWords({ key: "d3", status: "approval", askHeld: true, fleet: { phase: "approved", units: [{}] } }), "Needs you");

const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile pulses whenever it needs Adam (class needs)", tile.indexOf('(needsYouNow(it) ? " needs" : "")') >= 0);
check("the pulse is styled", /\.tile\.needs \{ animation:askglow/.test(src));

// 2026-09-11 live: "merged -- close its tab yourself" made the card red with nothing to press. Every
// finished merge state that needs Adam gets buttons in the review: Close tab (merged, tab open) and Dismiss.
const rm = slice("    function renderMerge(it){", "\n    }\n") || "";
// 2026-09-15 requirement change: a merged unit's leftover tab is no longer "needs you" (it's
// housekeeping), but its review keeps the buttons -- any finished merge with a note gets them.
check("the review shows its finished-state buttons for any finished merge with a note (needs you or not)",
      rm.indexOf('document.getElementById("dm-done").style.display = (!asking && (m.needsYou || m.closeNote || m.phase === "merged-dirty")) ? "flex" : "none";') >= 0);
// 2026-09-22 requirement change: a closeNote is no longer proof that Close tab could do
// anything. Four of its five sources are GUARDS deliberately holding the tab open (a post-merge
// gate running, one queued behind it, main red after the merge, a merge Shepherd couldn't
// verify) and a fifth refusal can be terminal -- Adam's reloaded window had forgotten its bridge
// tags, and a batch unit's tab never gets a name, so the button re-ran the identical refusal
// every press. Lua decides (core.tabCloseVerdict -> m.canCloseTab); the panel reads THAT.
check("...Close tab only where pressing it could actually close the tab",
      rm.indexOf('document.getElementById("dm-closetab").style.display = (m.phase === "merged" && m.canCloseTab) ? "" : "none";') >= 0);
check("...and never straight off the note, which four guards also write",
      rm.indexOf('(m.phase === "merged" && m.closeNote)') < 0);
check("the buttons exist and send their actions",
      src.indexOf("mergeAct('merge-close-tab')") >= 0 && src.indexOf("mergeAct('merge-dismiss')") >= 0);
check("Shepherd handles both actions",
      src.indexOf('if a == "merge-close-tab" then') >= 0 && src.indexOf('if a == "merge-dismiss" then') >= 0);

// ---- 2026-09-17: never say "Needs you" when Adam can't act ----------------------------
// Two long-finished merges got a post-merge test gate started retroactively; both ran the same
// suite in the same checkout at once, killed each other, and reported `exited 2` about a main
// that was green. Their cards pulsed red "Needs you" for hours with only Dismiss to press --
// which trains him to dismiss reds. cc-core.needsYouKind now stamps the verdict on every tile
// ("needs" / "fyi" / "no") and the panel reads THAT, never the raw source flags.
const stamped = { key: "s", status: "done", merge: { phase: "requested", needsYou: true }, needsYou: "needs" };
check("a tile Lua stamped as needing Adam needs Adam", api.needsYouNow(stamped));
const headsUp = { key: "h", status: "done", needsYou: "fyi", needsYouSource: "merge",
                  merge: { phase: "merged", needsYou: true, closeNote: "main is red after the merge" } };
check("a merged-but-red card is NOT ranked as needing Adam", !api.needsYouNow(headsUp));
check("...it is a heads-up", api.headsUp(headsUp));
eq("...so its dot isn't the red approval one", api.effStatus(headsUp), "idle");
eq("...and it says Heads-up, not Needs you", api.statusWords(headsUp), "Heads-up");
// A blocked unit is NOT one of these: it left a note, and its tab and branch are still there for
// Adam to read, redirect or take over -- cc-core keeps it "needs" (see core.test.lua).
const blockedUnit = { key: "b", status: "done", needsYou: "needs", needsYouSource: "merge",
                      merge: { phase: "blocked", needsYou: true, line: "⚠ merge blocked: the tests disagree" } };
check("a blocked unit still needs Adam, and still pulses", api.needsYouNow(blockedUnit) && !api.headsUp(blockedUnit));
// ...a request nobody is waiting on any more IS: his click would write a decision no one claims.
const orphaned = { key: "o", status: "done", needsYou: "fyi", needsYouSource: "merge",
                   needsYouWhy: "nothing is waiting for the answer any more",
                   merge: { phase: "requested", needsYou: true } };
check("a merge request whose script has gone is a heads-up", !api.needsYouNow(orphaned) && api.headsUp(orphaned));
const noStamp = { key: "n", status: "done", needsYou: "no", merge: { phase: "merged", needsYou: true } };
check("a tile stamped 'no' needs nothing, whatever its sources say", !api.needsYouNow(noStamp) && !api.headsUp(noStamp));

// the VPN blip: a transient API error reads as retrying, not as a red Error
const blip = { key: "e", status: "error", needsYou: "fyi", needsYouSource: "error",
               error_reason: "runtime_error", error_message: "Connection error." };
check("a transient connection error doesn't need Adam", !api.needsYouNow(blip));
eq("...its dot is not the red error one", api.effStatus(blip), "idle");
eq("...and the card says it is retrying", api.statusWords(blip), "Retrying");
const outage = { key: "e2", status: "error", needsYou: "needs", needsYouSource: "error",
                 error_reason: "runtime_error" };
eq("a connection error that persisted still reads Needs you", api.statusWords(outage), "Needs you");
eq("...with the red approval dot", api.effStatus(outage), "approval");

// the ring and the pulse: red only for "needs", a quiet one for a heads-up
check("only a card that needs Adam pulses", tile.indexOf('(needsYouNow(it) ? " needs" : "")') >= 0);
check("a heads-up gets its own quiet class instead", tile.indexOf('(headsUp(it) ? " fyi" : "")') >= 0);
check("...which is styled, and does not pulse", /\.tile\.fyi \{/.test(src) && !/\.tile\.fyi \{[^}]*animation:askglow/.test(src));
check("the merge ring follows the same verdict, not the raw merge flag",
      tile.indexOf('(mergeRing(it) ? " merge" : "")') >= 0);
check("...so a merge nobody is waiting on any more loses the teal ring",
      !api.mergeRing(headsUp) && api.mergeRing(stamped));
check("...and a plain permission prompt never gains it",
      !api.mergeRing({ key: "a", status: "approval", needsYou: "needs", needsYouSource: "approval" }));
check("a heads-up never dims as stale -- it still has something to say",
      src.indexOf('function staleDim(it){ return !!(it && it.stale && effStatus(it) === "idle" && !headsUp(it)); }') >= 0);

// a heads-up says WHY it isn't yours to act on, right on the card, escaped like every other
// field that reaches innerHTML (tests/escaping.test.sh's rule)
check("the card carries the heads-up's reason", tile.indexOf("it.needsYouWhy") >= 0);
check("...escaped, like every other meta field", /esc\(meta\)/.test(tile));

// the red gate's review: the failing lines and where the whole log is
check("the review leads with the gate's failing lines, not the trailing tail",
      rm.indexOf("gt.fails") >= 0);
check("...and names the full log so Adam can open it", rm.indexOf("gt.log") >= 0);
check("...through textContent, never innerHTML", rm.indexOf("gEl.innerHTML") < 0);

console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
