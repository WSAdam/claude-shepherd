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
// 2026-09-30: an addition whose quote isn't in CLAUDE.md could only be skipped. The view marks one
// `addAnyway`; its row offers "Add to the section anyway" after Skip, and the rerun's tooltip says
// what is actually wrong (a quote that doesn't match is not a file that changed).
const addV = lib.coachRowsHtml({ root: "/r/repo", state: "done", verdict: "proposals", decisions: [],
  edits: [
    { i: 1, section: "Git", old: "a", new: "a b", why: "w", evidence: ["e"], status: "pending", error: "not quoted", code: "not-found", addAnyway: true, rerun: true },
    { i: 2, section: "Git", old: "a", new: "c", why: "w", evidence: ["e"], status: "pending", error: "not quoted", code: "not-found", rerun: true },
    { i: 3, section: "Git", old: "a", new: "a b", why: "w", evidence: ["e"], status: "pending", error: "changed", code: "changed", rerun: true },
    { i: 4, section: "Git", old: "a", new: "a b", why: "w", evidence: ["e"], status: "pending" },
  ] });
const addRows = addV.split('<div class="ib-row co-row').slice(1);
eq("an addition that can't be placed offers Add to the section anyway, right after Skip",
  /data-act="skip" data-i="0"[^>]*>Skip<\/button><button class="ib-btn" data-act="add" data-i="0"[^>]*>Add to the section anyway<\/button>/.test(addRows[0]), true);
eq("...then Run the coach again", /Add to the section anyway<\/button><button class="ib-btn" data-act="rerun"/.test(addRows[0]), true);
eq("...its tooltip says only the new part goes in", /data-act="add"[^>]*title="[^"]*new part/.test(addRows[0]), true);
eq("a rewrite that can't be placed offers no Add anyway", /data-act="add"/.test(addRows[1]), false);
eq("...its rerun doesn't claim the file changed", /data-act="rerun"[^>]*title="[^"]*changed since/.test(addRows[1]), false);
eq("...it says the quote doesn't match", /data-act="rerun"[^>]*title="[^"]*quote/.test(addRows[1]), true);
eq("a stale edit's rerun still says the file changed", /data-act="rerun"[^>]*title="[^"]*changed since/.test(addRows[2]), true);
eq("...and offers no Add anyway", /data-act="add"/.test(addRows[2]), false);
eq("an edit never refused offers neither", /data-act="(add|rerun)"/.test(addRows[3]), false);
// 2026-09-30: Skip was final. A skipped row now offers Bring back, and only a skipped one.
const bb = lib.coachRowsHtml({ root: "/r/repo", state: "done", verdict: "proposals",
  edits: [
    { i: 1, section: "Git", old: "a", new: "b", why: "w", evidence: ["e"], status: "skipped" },
    { i: 2, section: "Git", old: "c", new: "d", why: "w", evidence: ["e"], status: "applied", sha: "abc1234" },
    { i: 3, section: "Git", old: "e", new: "f", why: "w", evidence: ["e"], status: "pending" },
  ],
  decisions: [{ i: 1, what: "Keep bash", why: "portable", status: "skipped" }, { i: 2, what: "Tabs", why: "w", status: "added" }] });
const bbRows = bb.split('<div class="ib-row co-row').slice(1);
eq("a skipped edit offers Bring back", /Skipped/.test(bbRows[0]) && /<button class="ib-btn" data-act="unskip" data-i="0"[^>]*>Bring back<\/button>/.test(bbRows[0]), true);
eq("...an applied edit does not", /data-act="unskip"/.test(bbRows[1]), false);
eq("...nor a pending one", /data-act="unskip"/.test(bbRows[2]), false);
eq("a skipped DECISIONS.md entry offers it too", /<button class="ib-btn" data-act="dec-unskip" data-i="0"[^>]*>Bring back<\/button>/.test(bbRows[3]), true);
eq("...an added entry does not", /unskip/.test(bbRows[4]), false);
const nv = lib.coachRowsHtml({ root: "/r", state: "new", edits: [], decisions: [] });
eq("a repo the coach never read offers to run it", /hasn't read/.test(nv) && /data-act="rerun"/.test(nv), true);

// ---- the lessons ledger (2026-10-02, mining round 2 unit B1) ----
// 2026-10-02: a skip was lost at the next run, so the coach could propose the same edit again with
// nothing on the row saying it had been seen before, or what was new. The row now says how many runs
// proposed it, what Adam did with it last time and why, and what the coach says is new; and a pending
// row takes an optional one-line reason for its Skip.
const les = lib.coachRowsHtml({ root: "/r/repo", state: "done", verdict: "proposals", decisions: [],
  edits: [
    { i: 1, section: "Git", old: "", new: "- never force-push", why: "w", evidence: ["e"], status: "pending",
      lesson: "L0a1b2c", seen: 3, was: "skipped", reason: "too broad" + EVIL, whatsNew: "two more force-pushes" + EVIL },
    { i: 2, section: "Git", old: "", new: "- y", why: "w", evidence: ["e"], status: "pending", lesson: "L0d0e0f", seen: 2, was: "undone" },
    { i: 3, section: "Git", old: "", new: "- z", why: "w", evidence: ["e"], status: "pending" },
    { i: 4, section: "Git", old: "", new: "- s", why: "w", evidence: ["e"], status: "skipped", reason: "not now" + EVIL },
  ] });
const lesRows = les.split('<div class="ib-row co-row').slice(1);
eq("a suggestion that repeats a lesson says how many runs proposed it", /seen in 3 runs/.test(lesRows[0]), true);
eq("...what Adam did with it before, and his reason", /[Ss]kipped before/.test(lesRows[0]) && lesRows[0].indexOf("too broad") >= 0, true);
eq("...and what the coach says is new", /new[\s\S]*two more force-pushes/i.test(lesRows[0]), true);
eq("...every field escaped", les.indexOf("<img") < 0, true);
eq("an undone lesson says so", /[Uu]ndone before/.test(lesRows[1]) && /seen in 2 runs/.test(lesRows[1]), true);
eq("a suggestion with no lesson says nothing of the kind", /seen in|before ·|before:/.test(lesRows[2]), false);
eq("a pending row has a one-line reason box for its Skip, before the Skip button",
  /<input class="co-skip-why"[^>]*maxlength="200"[^>]*>/.test(lesRows[2]) && lesRows[2].indexOf('class="co-skip-why"') < lesRows[2].indexOf('data-act="skip"'), true);
eq("...an applied or skipped row has none", /co-skip-why/.test(lesRows[3]), false);
eq("a skipped row shows the reason it was skipped for, escaped", lesRows[3].indexOf("not now") >= 0 && lesRows[3].indexOf("<img") < 0, true);

// ---- what a suggestion is expected to change (2026-09-30) ----
// 2026-09-30: a row showed the text and the evidence, not the behaviour it should change. Each edit
// now carries what sessions do today and what is expected once it is applied.
const exp = lib.coachRowsHtml({ root: "/r/repo", state: "done", verdict: "proposals", decisions: [],
  edits: [
    { i: 1, section: "Git", old: "a", new: "b", why: "w", evidence: ["e"], status: "pending",
      before: "A session ran git push when green" + EVIL, after: "A session asks before it pushes" + EVIL },
    { i: 2, section: "Git", old: "c", new: "d", why: "w", evidence: ["e"], status: "pending" },
    { i: 3, section: "Git", old: "e", new: "f", why: "w", evidence: ["e"], status: "applied", sha: "abc1234", after: "only an after" },
  ] });
const expRows = exp.split('<div class="ib-row co-row').slice(1);
eq("a suggestion says what sessions do today", /class="co-expect"[\s\S]*Today[\s\S]*A session ran git push when green/.test(expRows[0]), true);
eq("...and what is expected once it is applied", /Expected[\s\S]*A session asks before it pushes/.test(expRows[0]), true);
eq("...escaped like every other field", expRows[0].indexOf("<img") < 0, true);
eq("...above the text it changes", expRows[0].indexOf('class="co-expect"') < expRows[0].indexOf('class="co-new"'), true);
eq("a suggestion from before the coach said so shows no empty block", /co-expect/.test(expRows[1]), false);
eq("an applied suggestion keeps its expectation on show", /Expected[\s\S]*only an after/.test(expRows[2]) && !/Today/.test(expRows[2]), true);

// ---- the history of applied edits, with Undo (2026-09-30) ----
// 2026-09-30: an applied edit vanished from the overlay at the next run, and nothing could undo it.
const histView = { root: "/r/repo", state: "done", verdict: "none", edits: [], decisions: [],
  history: [
    { i: 2, sha: "bbb2222bbb", at: 1000, section: "Tests" + EVIL, why: "Late lint" + EVIL, before: "lint ran last" + EVIL, after: "lint runs first" + EVIL, old: "", new: "- lint first" + EVIL },
    { i: 1, sha: "aaa1111aaa", at: 900, section: "Git", why: "Pushed alone", old: "- commit often", new: "- never push", undone: true, undoSha: "ccc3333ccc" },
    { i: 3, sha: "ddd4444ddd", at: 800, section: "Docs", why: "w", old: "- x", new: "- y", error: "CLAUDE.md has uncommitted edits" + EVIL },
  ] };
const hh = lib.coachRowsHtml(histView);
eq("the overlay lists what was applied before, under its own heading with the count", /Applied edits · 3/.test(hh), true);
const hrows = hh.split('class="ib-row co-row co-hist').slice(1);
eq("one row per applied edit", hrows.length, 3);
eq("an applied edit shows its commit, what it replaced and what it added", hrows[1].indexOf("aaa1111") >= 0 && hrows[1].indexOf("- commit often") >= 0 && hrows[1].indexOf("- never push") >= 0, true);
eq("...and what it was expected to change", /Expected[\s\S]*lint runs first/.test(hrows[0]) && /Today[\s\S]*lint ran last/.test(hrows[0]), true);
eq("...every field escaped", hh.indexOf("<img") < 0, true);
eq("an applied edit offers Undo, carrying only its number", /data-act="undo" data-i="0"/.test(hrows[0]) && !/data-sha=|data-old=|data-new=/.test(hh), true);
eq("an undone edit says so, with the commit that undid it, and offers no Undo", /Undone/.test(hrows[1]) && hrows[1].indexOf("ccc3333") >= 0 && !/data-act="undo"/.test(hrows[1]), true);
eq("a refused Undo says why on its row, and can be tried again", hrows[2].indexOf("uncommitted edits") >= 0 && /data-act="undo" data-i="2"/.test(hrows[2]), true);
eq("no history: no heading", /Applied edits/.test(h), false);
lib.setView(histView);
sent.length = 0;
lib.coachAct({ target: { closest: function(){ return { getAttribute: function(k){ return { "data-act": "undo", "data-i": "0" }[k]; } }; } }, stopPropagation: function(){} });
eq("Undo sends the repo's root and the entry's own number, never text", JSON.stringify(sent.pop()), JSON.stringify(["coach-undo", "/r/repo", "2"]));
lib.setView(null);

// ---- did the edit work? (2026-10-03, mining round 2 unit B2) ----
// 2026-10-03: an applied edit said what it was expected to change, and nothing ever said whether it
// did. Each history row now shows the coach's verdict on the sessions since (working, still seen,
// no data yet), with its quotes, and offers Sharpen (a run on that edit alone) beside Undo.
const outView = { root: "/r/repo", state: "done", verdict: "none", edits: [], decisions: [],
  history: [
    { i: 4, sha: "aaa1111aaa", at: 1000, section: "Git", why: "w", old: "", new: "- a",
      check: { verdict: "working", evidence: ["no push since" + EVIL], at: 2000, since: 4, need: 3 } },
    { i: 3, sha: "bbb2222bbb", at: 900, section: "Git", why: "w", old: "", new: "- b",
      check: { verdict: "still-seen", evidence: ["denied: git push" + EVIL, "pushed again"], at: 2000, since: 5, need: 3 } },
    { i: 2, sha: "ccc3333ccc", at: 800, section: "Git", why: "w", old: "", new: "- c",
      check: { verdict: "no-data", evidence: [], at: 2000, since: 1, need: 3 } },
    { i: 1, sha: "ddd4444ddd", at: 700, section: "Git", why: "w", old: "", new: "- d",
      check: { verdict: "no-data", evidence: [], at: 2000, since: 6, need: 3 } },
    { i: 5, sha: "eee5555eee", at: 600, section: "Git", why: "w", old: "", new: "- e" },
    { i: 6, sha: "fff6666fff", at: 500, section: "Git", why: "w", old: "", new: "- f", undone: true, undoSha: "1231231",
      check: { verdict: "working", evidence: ["old"], at: 400, since: 3, need: 3 } },
    { i: 7, sha: "abcabc1abc", at: 450, section: "Git", why: "w", old: "", new: "- g", sharpenedSha: "9879879aaa",
      check: { verdict: "still-seen", evidence: ["was bad"], at: 400, since: 3, need: 3 } },
  ] };
const oh = lib.coachRowsHtml(outView);
const orows = oh.split('class="ib-row co-row co-hist').slice(1);
eq("one row per applied edit", orows.length, 7);
eq("a working edit says so, with what shows it", /class="co-check[^"]*working[^"]*"[\s\S]*Working/.test(orows[0]) && orows[0].indexOf("no push since") >= 0, true);
eq("...judged on how many sessions since", /4 sessions since/.test(orows[0]), true);
eq("an edit whose problem is still seen says so, quoting it", /Still seen/.test(orows[1]) && orows[1].indexOf("denied: git push") >= 0 && orows[1].indexOf("pushed again") >= 0, true);
eq("...every quote escaped", oh.indexOf("<img") < 0, true);
eq("an edit too few sessions postdate says no data yet, and how many there are of how many",
  /No data yet/.test(orows[2]) && /1 of 3 sessions/.test(orows[2]), true);
eq("an edit the sessions since never touched says no data, not \"yet\"", /No data/.test(orows[3]) && !/No data yet/.test(orows[3]), true);
eq("an edit never judged shows no verdict", /co-check/.test(orows[4]), false);
eq("a live edit offers Sharpen and Undo, each carrying only its row number",
  /data-act="sharpen" data-i="1"/.test(orows[1]) && /data-act="undo" data-i="1"/.test(orows[1]), true);
eq("an edit never judged can be sharpened too", /data-act="sharpen" data-i="4"/.test(orows[4]), true);
eq("an undone edit offers neither, and shows no verdict", !/data-act="sharpen"/.test(orows[5]) && !/data-act="undo"/.test(orows[5]) && !/co-check/.test(orows[5]), true);
eq("a sharpened edit names the commit that replaced it, and offers neither",
  /Sharpened/.test(orows[6]) && orows[6].indexOf("9879879") >= 0 && !/data-act="sharpen"/.test(orows[6]) && !/data-act="undo"/.test(orows[6]), true);
lib.setView(outView);
sent.length = 0;
lib.coachAct({ target: { closest: function(){ return { getAttribute: function(k){ return { "data-act": "sharpen", "data-i": "1" }[k]; } }; } }, stopPropagation: function(){} });
eq("Sharpen sends the repo's root and the entry's own number, never text", JSON.stringify(sent.pop()), JSON.stringify(["coach-sharpen", "/r/repo", "3"]));
lib.setView(null);
eq("a sharpen run says what it is doing", /sharpen/i.test(lib.coachRowsHtml({ root: "/r", state: "running", at: 1000, sharpen: "aaa1111aaa", edits: [], decisions: [] }))
  && lib.coachRowsHtml({ root: "/r", state: "running", at: 1000, sharpen: "aaa1111aaa", edits: [], decisions: [] }).indexOf("aaa1111") >= 0, true);
eq("...and so does its answer", /sharpen/i.test(lib.coachRowsHtml({ root: "/r", state: "done", verdict: "proposals", sharpen: "aaa1111aaa", summary: "s", decisions: [],
  edits: [{ i: 1, section: "Git", old: "a", new: "b", why: "w", evidence: ["e"], status: "pending" }] })), true);

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
// 2026-10-02: the reason typed in the row's box goes after the number, on one line
function skipWith(value) {
  const b = { getAttribute: (k) => ({ "data-act": "skip", "data-i": "0" })[k] || null };
  const row = { querySelector: (sel) => (sel === "input.co-skip-why" ? { value: value } : null) };
  b.closest = (sel) => (sel === "[data-act]" ? b : (sel === ".co-row" ? row : null));
  return { target: b, stopPropagation() {} };
}
lib.coachAct(skipWith("  too\n broad  "));
eq("Skip sends the reason typed in its row, on one line, after the number", JSON.stringify(sent.pop()), JSON.stringify(["coach-skip", "/r/repo", "1\ntoo broad"]));
lib.coachAct(skipWith("   "));
eq("...a blank reason sends the number alone", JSON.stringify(sent.pop()), JSON.stringify(["coach-skip", "/r/repo", "1"]));
lib.coachAct(skipWith("x".repeat(500)));
eq("...a long reason is capped at 200 characters", (sent.pop()[2] || "").length, 2 + 200);
lib.coachAct(btn({ "data-act": "dec-add", "data-i": 0 }));
eq("Add sends the entry's number", JSON.stringify(sent.pop()), JSON.stringify(["coach-dec-add", "/r/repo", "1"]));
lib.coachAct(btn({ "data-act": "add", "data-i": 0 }));
eq("Add anyway sends the view's root and the edit's number", JSON.stringify(sent.pop()), JSON.stringify(["coach-add", "/r/repo", "1"]));
lib.coachAct(btn({ "data-act": "unskip", "data-i": 2 }));
eq("Bring back sends the edit's number", JSON.stringify(sent.pop()), JSON.stringify(["coach-unskip", "/r/repo", "3"]));
lib.coachAct(btn({ "data-act": "dec-unskip", "data-i": 0 }));
eq("...and an entry's", JSON.stringify(sent.pop()), JSON.stringify(["coach-dec-unskip", "/r/repo", "1"]));
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

// ---- an evidence run says what started it (2026-10-03, mining round 2 unit B4) ----
// A run nobody clicked, on no weekly day, read as if it came from nowhere.
const evNone = lib.coachRowsHtml({ root: "/r", state: "done", verdict: "none", trigger: "evidence", evidence: 12, sessions: 4, edits: [], decisions: [] });
eq("an evidence run with nothing to change says enough new evidence started it, and how much",
  /new evidence/i.test(evNone) && evNone.indexOf("12") >= 0, true);
const evProp = lib.coachRowsHtml({ root: "/r", state: "done", verdict: "proposals", trigger: "evidence", evidence: 7, summary: "s", sessions: 4,
  edits: [{ i: 1, section: "Git", old: "a", new: "b", why: "w", evidence: ["e"], status: "pending" }], decisions: [] });
eq("...and so does one with suggestions", /new evidence/i.test(evProp) && evProp.indexOf("7") >= 0, true);
const evRun = lib.coachRowsHtml({ root: "/r", state: "running", at: 1000, trigger: "evidence", evidence: 9, edits: [], decisions: [] });
eq("...and one still reading", /new evidence/i.test(evRun) && evRun.indexOf("9") >= 0, true);
eq("a weekly run says nothing of the kind", /new evidence/i.test(lib.coachRowsHtml({ root: "/r", state: "done", verdict: "none", trigger: "weekly",
  sessions: 4, edits: [], decisions: [] })), false);
eq("the count is escaped like every field", lib.coachRowsHtml({ root: "/r", state: "done", verdict: "none", trigger: "evidence", evidence: "<b>x</b>",
  sessions: 4, edits: [], decisions: [] }).indexOf("<b>x</b>") < 0, true);

console.log("\n-- coach-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
