// review-open.test.js - BEHAVIORAL: double-clicking a card that shows the My List review heads-up opens
// My List on that project's tab, To verify picked (2026-10-13).
//
// Adam: "I like heads up and badge but double clicking it at that phase should pop it to that project's
// todos." Any other card -- another heads-up, a working session, a plain card -- keeps the usual
// double-click: jump to the instance that most needs you (focus-group). Also pins the 📋 badge: text
// and tooltip only, never HTML. Runs the REAL shipped tileReviewKey / tileActivate / wlOpenReview /
// setReviewBadge sliced out of claude-dashboard.lua, with send / findItem / the My List state stubbed.
//
// Usage: node tests/review-open.test.js [path/to/claude-dashboard.lua]

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
const keySrc = slice("    function tileReviewKey(it){", "\n    }\n");
const actSrc = slice("    function tileActivate(key, stack){", "\n    }\n");
const openSrc = slice("    function wlOpenReview(scope){", "\n    }\n");
const badgeSrc = slice("    function setReviewBadge(d){", "\n    }\n");
check("the panel ships tileReviewKey", keySrc !== null);
check("the panel ships tileActivate", actSrc !== null);
check("the panel ships wlOpenReview", openSrc !== null);
check("the panel ships setReviewBadge", badgeSrc !== null);
if (!keySrc || !actSrc || !openSrc || !badgeSrc) {
  console.log("-- review-open.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a minimal world for the sliced functions
function world(items) {
  const w = { sent: [], toggled: 0, rendered: 0, stored: {}, badge: { textContent: "", title: "", style: {}, classList: null } };
  const cls = new Set();
  w.badge.classList = { toggle: (c, on) => { if (on) cls.add(c); else cls.delete(c); }, contains: (c) => cls.has(c) };
  const env = {
    send: (a, v, t) => w.sent.push({ a: a, v: v, t: t }),
    findItem: (k) => items[k] || null,
    cardKeysFor: (s) => ["k1", "k2"],
    toggleWorklist: () => { w.toggled++; env.worklistMode = true; },
    renderWorklist: () => { w.rendered++; },
    document: { getElementById: (id) => (id === "mylist-badge" ? w.badge : null) },
    window: { localStorage: { setItem: (k, v) => { w.stored[k] = v; } } },
    worklistMode: false, worklistScope: "generic", worklistLane: "all",
  };
  const fn = new Function("env",
    "var send = env.send, findItem = env.findItem, cardKeysFor = env.cardKeysFor, document = env.document, window = env.window;"
    + "var worklistMode = env.worklistMode, worklistScope = env.worklistScope, worklistLane = env.worklistLane;"
    + "function toggleWorklist(){ env.toggleWorklist(); worklistMode = true; }"
    + "function renderWorklist(){ env.renderWorklist(); }"
    + keySrc + openSrc + actSrc + badgeSrc
    + "return { tileReviewKey: tileReviewKey, tileActivate: tileActivate, wlOpenReview: wlOpenReview,"
    + " setReviewBadge: setReviewBadge, state: function(){ return { scope: worklistScope, lane: worklistLane, mode: worklistMode }; } };");
  w.api = fn(env);
  return w;
}

const REVIEW = { needsYou: "fyi", needsYouSource: "mylist", wlReview: { key: "-Users-adam-Programming-ChargebackSentinel", n: 31 } };

// 1. the review heads-up: double-click opens My List on that tab, To verify
let w = world({ k1: REVIEW });
w.api.tileActivate("k1", "repo:/cs/.git");
let s = w.api.state();
eq("a review heads-up card's double-click opens My List", s.mode, true);
eq("...on that project's tab", s.scope, "-Users-adam-Programming-ChargebackSentinel");
eq("...with To verify picked", s.lane, "verify");
eq("...remembered like any lane pick", w.stored["cc-wlLane"], "verify");
check("...and doesn't jump to a session", w.sent.filter((m) => m.a === "focus-group" || m.a === "focus").length === 0);

// 2. everything else keeps the jump
w = world({ k1: { needsYou: "fyi", needsYouSource: "decide", wlReview: REVIEW.wlReview } });
w.api.tileActivate("k1", "repo:/cs/.git");
check("another heads-up still jumps (focus-group)", w.sent.length === 1 && w.sent[0].a === "focus-group" && w.api.state().mode === false);
w = world({ k1: { needsYou: "no", status: "working", wlReview: REVIEW.wlReview } });
w.api.tileActivate("k1", "repo:/cs/.git");
check("a working card carrying the stamp still jumps", w.sent.length === 1 && w.sent[0].a === "focus-group");
w = world({ k1: { needsYou: "no", status: "done" } });
w.api.tileActivate("k1", null);
check("a stackless plain card still focuses itself", w.sent.length === 1 && w.sent[0].a === "focus" && w.sent[0].v === "k1");
w = world({});
w.api.tileActivate("gone", "repo:/x/.git");
check("a card whose item is gone still jumps (never throws)", w.sent.length === 1 && w.sent[0].a === "focus-group");
eq("tileReviewKey: no key in the stamp means no review", w.api.tileReviewKey({ needsYou: "fyi", needsYouSource: "mylist", wlReview: {} }), null);

// 3. the badge: a count while something's waiting, text only
w = world({});
w.api.setReviewBadge({ n: 34, tip: "To verify: <b>Shepherd</b> 34" });
eq("the badge shows the count", w.badge.textContent, "34");
eq("...with the projects in its tooltip, as text", w.badge.title, "To verify: <b>Shepherd</b> 34");
check("...and is shown", w.badge.classList.contains("on") === true);
w.api.setReviewBadge({ n: 0, tip: "" });
check("nothing over the line: the badge goes away", w.badge.textContent === "" && w.badge.classList.contains("on") === false);
w.api.setReviewBadge(null);
check("a null push is safe", w.badge.textContent === "");
check("setReviewBadge never writes innerHTML", badgeSrc.indexOf("innerHTML") < 0);

console.log("-- review-open.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
