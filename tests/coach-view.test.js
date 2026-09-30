// coach-view.test.js - BEHAVIORAL: the Coach overlay and the card's chip (2026-09-29, build program
// unit 32).
//
// The coach proposes CLAUDE.md edits from a repo's recent sessions; each shows its section, why,
// the text it replaces and the new text, and its evidence, with Apply and Skip. A headless model
// wrote every one of those strings from transcripts anyone could have typed into, so each goes
// through esc(). A click sends only the repo's root the view came with and the edit's number --
// never text read back out of the markup. Runs the REAL shipped coachRowsHtml / coachAct /
// coachBadge sliced out of claude-dashboard.lua (the inbox-view.test.js pattern).
//
// Usage: node tests/coach-view.test.js [path/to/claude-dashboard.lua]

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
const rowsSrc = slice("    function coachRowsHtml(v){", "\n    }\n");
const actSrc = slice("    function coachAct(ev){", "\n    }\n");
const badgeSrc = slice("    function coachBadge(it){", "\n    }\n");
const elapsedSrc = slice("    function coachElapsedText(at, now){", "\n    }\n");
const tickSrc = slice("    function coachTick(){", "\n    }\n");
const tickStopSrc = slice("    function coachTickStop(){", "\n    }\n");
const renderSrc = slice("    function renderCoach(){", "\n    }\n");
check("the panel ships coachElapsedText, coachTick and coachTickStop", elapsedSrc !== null && tickSrc !== null && tickStopSrc !== null);
check("the panel reads the clock in one place (coachNow)", src.indexOf("    function coachNow(){ return Date.now() / 1000; }") >= 0);
check("the panel ships coachRowsHtml", rowsSrc !== null);
check("the panel ships coachAct", actSrc !== null);
check("the panel ships coachBadge", badgeSrc !== null);
check("the panel has the Coach overlay (id coach)", src.indexOf('<div id="coach">') >= 0);
check("the card's badges row carries the coach chip", src.indexOf("b += coachBadge(it);") >= 0);
if (!(escSrc && rowsSrc && actSrc && badgeSrc)) {
  console.log("\n-- coach-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const sent = [];
// The clock, the document and the timers are the test's: NOW is "now" in seconds, EL the elements
// by id, TIMERS what setInterval / clearInterval were asked for.
const clock = { now: 1000 };
const EL = {};
const TIMERS = { set: [], cleared: [], next: 1 };
const lib = new Function("sent", "clock", "EL", "TIMERS",
  "var COACH = { view: null, key: null, open: false, timer: null };\n" +
  "function send(a, v, text){ sent.push([a, v, text]); }\n" +
  "function fmtAge(){ return '3m'; }\n" +
  "function coachNow(){ return clock.now; }\n" +
  "var document = { getElementById: function(id){ return EL[id] || null; } };\n" +
  "function setInterval(fn, ms){ var id = TIMERS.next++; TIMERS.set.push({ id: id, fn: fn, ms: ms }); return id; }\n" +
  "function clearInterval(id){ TIMERS.cleared.push(id); }\n" +
  escSrc + "\n" + (elapsedSrc || "") + "\n" + rowsSrc + "\n" + actSrc + "\n" + badgeSrc + "\n" + (tickSrc || "") + "\n" + (tickStopSrc || "") + "\n" + (renderSrc || "") +
  "\nreturn { coachRowsHtml, coachAct, coachBadge, setView: function(v){ COACH.view = v; }, COACH: COACH," +
  " coachElapsedText: typeof coachElapsedText === 'function' ? coachElapsedText : null," +
  " coachTick: typeof coachTick === 'function' ? coachTick : null, renderCoach: renderCoach };")(sent, clock, EL, TIMERS);

// ---- the rows ----
const EVIL = '<img src=x onerror="alert(1)">';
const view = {
  root: "/r/repo", name: "repo" + EVIL, state: "done", verdict: "proposals", summary: "Two things" + EVIL,
  edits: [
    { i: 1, section: "Git" + EVIL, old: "- commit often" + EVIL, new: "- never push" + EVIL, why: "Pushed alone" + EVIL,
      evidence: ["Adam: stop pushing" + EVIL, "denied: git push"], status: "pending", error: "CLAUDE.md changed" + EVIL },
    { i: 2, section: "Tests", old: "", new: "- lint first", why: "Late lint", evidence: ["luacheck red"], status: "applied", sha: "abc1234def" },
    { i: 3, section: "Docs", old: "- x", new: "- y", why: "w", evidence: ["e"], status: "skipped" },
  ],
  decisions: [
    { i: 1, what: "Keep bash" + EVIL, why: "portable" + EVIL, status: "pending" },
    { i: 2, what: "Tabs", why: "w", status: "added" },
  ],
};
const h = lib.coachRowsHtml(view);
eq("every field is escaped: no raw tag reaches the markup", h.indexOf("<img") < 0, true);
eq("...its text is still there, escaped", h.indexOf("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;") >= 0, true);
eq("one row per edit and per entry", (h.match(/class="ib-row co-row/g) || []).length, 5);
eq("a pending edit offers Apply and Skip", /data-act="apply" data-i="0"/.test(h) && /data-act="skip" data-i="0"/.test(h), true);
eq("...shows the text it replaces and the new text", h.indexOf("- commit often") >= 0 && h.indexOf("- never push") >= 0, true);
eq("...and its evidence", h.indexOf("Adam: stop pushing") >= 0 && h.indexOf("denied: git push") >= 0, true);
eq("...and why its last Apply was refused", h.indexOf("CLAUDE.md changed") >= 0, true);
eq("an add says where it goes", /end of (this|its) section/i.test(h), true);
eq("an applied edit names its commit, with no buttons", h.indexOf("abc1234") >= 0 && !/data-act="apply" data-i="1"/.test(h), true);
eq("a skipped edit has no buttons", !/data-act="apply" data-i="2"/.test(h) && /Skipped/.test(h), true);
eq("a pending DECISIONS.md entry offers Add and Skip", /data-act="dec-add" data-i="0"/.test(h) && /data-act="dec-skip" data-i="0"/.test(h), true);
eq("buttons carry only numbers, never the text", /data-v=|data-old=|data-new=|data-root=/.test(h), false);
eq("a run with nothing to change says so", /nothing/i.test(lib.coachRowsHtml({ root: "/r", state: "done", verdict: "none", edits: [], decisions: [] })), true);
const cr = lib.coachRowsHtml({ root: "/r", state: "done", verdict: "couldntRun", why: "it hit its budget" + EVIL, edits: [], decisions: [] });
eq("a couldn't-run says why, escaped", cr.indexOf("it hit its budget") >= 0 && cr.indexOf("<img") < 0, true);
eq("...and offers to run it again", /data-act="rerun"/.test(cr), true);
eq("a running coach says so", /reading/i.test(lib.coachRowsHtml({ root: "/r", state: "running", edits: [], decisions: [] })), true);
eq("no view yet: a placeholder", typeof lib.coachRowsHtml(null) === "string", true);
// 2026-09-30: the refusal "CLAUDE.md changed since the coach read it -- run the coach again" showed
// on an edit with only Apply and Skip under it. The view marks such an edit `rerun`; the row then
// offers the button next to Skip, and no other row does.
eq("a plain refusal has no Run again button on its row", (h.match(/data-act="rerun"/g) || []).length, 0);
const stale = lib.coachRowsHtml({ root: "/r/repo", state: "done", verdict: "proposals",
  edits: [
    { i: 1, section: "Git", old: "a", new: "b", why: "w", evidence: ["e"], status: "pending", error: "CLAUDE.md changed since the coach read it -- run the coach again", rerun: true },
    { i: 2, section: "Git", old: "c", new: "d", why: "w", evidence: ["e"], status: "pending", error: "CLAUDE.md has uncommitted edits" },
    { i: 3, section: "Git", old: "e", new: "f", why: "w", evidence: ["e"], status: "pending" },
  ],
  decisions: [{ i: 1, what: "Keep bash", why: "portable", status: "pending", error: "DECISIONS.md changed since the coach read it", rerun: true },
              { i: 2, what: "Tabs", why: "w", status: "pending" }] });
const staleRows = stale.split('<div class="ib-row co-row').slice(1);
eq("a stale edit offers Run the coach again, after its Skip",
  /data-act="skip" data-i="0"[^>]*>Skip<\/button><button class="ib-btn" data-act="rerun"[^>]*>Run the coach again<\/button>/.test(staleRows[0]), true);
eq("...an edit refused for another reason does not", /data-act="rerun"/.test(staleRows[1]), false);
eq("...nor an edit with no refusal", /data-act="rerun"/.test(staleRows[2]), false);
eq("a stale DECISIONS.md entry offers it too, after its Skip",
  /data-act="dec-skip" data-i="0"[^>]*>Skip<\/button><button class="ib-btn" data-act="rerun"/.test(staleRows[3]) && !/data-act="rerun"/.test(staleRows[4]), true);
const nv = lib.coachRowsHtml({ root: "/r", state: "new", edits: [], decisions: [] });
eq("a repo the coach never read offers to run it", /hasn't read/.test(nv) && /data-act="rerun"/.test(nv), true);

// ---- a running coach shows how long it has been at it (2026-09-30) ----
// 2026-09-30: Adam ran the coach again and the overlay read "The coach is reading this repo's last
// sessions…" for minutes with nothing moving: no way to tell a slow run from a dead one.
const et = lib.coachElapsedText || function(){ return null; };
eq("elapsed: seconds", et(100, 100), "0s");
eq("elapsed: minutes and padded seconds", et(100, 165), "1m 05s");
eq("elapsed: long runs stay in minutes", et(100, 100 + 3599), "59m 59s");
eq("elapsed: no start, or a clock behind it, says nothing", et(undefined, 100) + "|" + et(0, 100) + "|" + et(200, 100), "||");
clock.now = 1000 + 188;
const runView = { root: "/r/repo", name: "repo", state: "running", at: 1000, timeoutSeconds: 600, edits: [], decisions: [] };
const rh = lib.coachRowsHtml(runView);
eq("a running coach shows its elapsed time in its own element", /<span id="co-elapsed">3m 08s<\/span>/.test(rh), true);
eq("...and when it gives up", /gives up (at|after) 10m/.test(rh), true);
eq("a queued coach counts too", /id="co-elapsed"/.test(lib.coachRowsHtml({ root: "/r", state: "queued", at: 1000, edits: [], decisions: [] })), true);
eq("a run with no start time shows no timer", /co-elapsed/.test(lib.coachRowsHtml({ root: "/r", state: "running", edits: [], decisions: [] })), false);
eq("a finished coach has no timer", /co-elapsed/.test(h), false);
// the overlay re-renders only when Lua pushes a view, so the element ticks by itself
EL["co-body"] = { innerHTML: "" }; EL["co-title"] = { textContent: "" }; EL["co-elapsed"] = { textContent: "" };
lib.COACH.open = true; lib.COACH.view = runView;
if (lib.renderCoach) lib.renderCoach();
eq("rendering a running coach starts one 1-second ticker", TIMERS.set.length + ":" + (TIMERS.set[0] && TIMERS.set[0].ms), "1:1000");
clock.now = 1000 + 189;
if (lib.coachTick) lib.coachTick();
eq("each tick rewrites the elapsed time", EL["co-elapsed"].textContent, "3m 09s");
if (lib.renderCoach) lib.renderCoach();
eq("a re-render replaces the ticker, never stacks a second one", TIMERS.set.length + ":" + TIMERS.cleared.length, "2:1");
lib.COACH.view = view;
if (lib.renderCoach) lib.renderCoach();
eq("rendering a finished run stops the ticker and starts none", TIMERS.set.length + ":" + TIMERS.cleared.length + ":" + lib.COACH.timer, "2:2:null");
lib.COACH.view = runView; lib.COACH.timer = 99; lib.COACH.open = false;
if (lib.coachTick) lib.coachTick();
eq("a tick with the overlay closed stops the ticker", TIMERS.cleared[TIMERS.cleared.length - 1] + ":" + lib.COACH.timer, "99:null");
lib.COACH.view = null; lib.COACH.open = false;

// ---- the clicks: the repo comes from the view Lua pushed, the edit is a number ----
lib.setView(view);
function btn(attrs) {
  const b = { getAttribute: (k) => (k in attrs ? String(attrs[k]) : null) };
  b.closest = () => b;
  return { target: b, stopPropagation() {} };
}
lib.coachAct(btn({ "data-act": "apply", "data-i": 0 }));
eq("Apply sends the view's root and the edit's number", JSON.stringify(sent.pop()), JSON.stringify(["coach-apply", "/r/repo", "1"]));
lib.coachAct(btn({ "data-act": "skip", "data-i": 0 }));
eq("Skip likewise", JSON.stringify(sent.pop()), JSON.stringify(["coach-skip", "/r/repo", "1"]));
lib.coachAct(btn({ "data-act": "dec-add", "data-i": 0 }));
eq("Add sends the entry's number", JSON.stringify(sent.pop()), JSON.stringify(["coach-dec-add", "/r/repo", "1"]));
lib.coachAct(btn({ "data-act": "rerun" }));
eq("Run again sends the root", JSON.stringify(sent.pop()), JSON.stringify(["coach-rerun", "/r/repo", undefined]));
lib.coachAct(btn({ "data-act": "apply", "data-i": 9 }));
eq("an edit that isn't there sends nothing", sent.length, 0);
lib.coachAct(btn({ "data-act": "rm -rf", "data-i": 0 }));
eq("an action that isn't one sends nothing", sent.length, 0);
lib.setView(null);
lib.coachAct(btn({ "data-act": "apply", "data-i": 0 }));
eq("no view: nothing is sent", sent.length, 0);

// ---- the chip ----
eq("no coach state: no chip", lib.coachBadge({}), "");
const chip = lib.coachBadge({ coach: { pending: 3 } });
eq("proposals waiting: a chip with their count", /🧭/.test(chip) && /3/.test(chip), true);
eq("...that opens the overlay without jumping", /data-nodbl/.test(chip) && /onclick="coachCard\(event\)"/.test(chip), true);
eq("a running coach shows a quiet chip", lib.coachBadge({ coach: { pending: 0, state: "running" } }) !== "", true);
eq("nothing waiting and idle: no chip", lib.coachBadge({ coach: { pending: 0, state: "done", verdict: "none" } }), "");

console.log("\n-- coach-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
