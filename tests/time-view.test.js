// time-view.test.js - BEHAVIORAL: the Time view renders where the time went (2026-09-29, build
// program unit 34).
//
// Lua answers open-time-lost with window.ccTimeLost({ kind, name, sessions, days, ledger, indexing,
// view }) -- view is core.timeLostSummary: plain-sentence callouts plus the seconds behind them. The
// callouts and the name carry a session's words, so every one goes through esc() (the name as
// textContent). Runs the REAL shipped tlvDur / timeLostHtml / ccTimeLost sliced out of
// claude-dashboard.lua (the pins-view.test.js pattern).
//
// Usage: node tests/time-view.test.js [path/to/claude-dashboard.lua]

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
const durSrc = slice("    function tlvDur(s){", "\n    }\n");
const cardSrc = slice("    function tlvCard(v, k){", "}\n");
const htmlSrc = slice("    function timeLostHtml(p){", "\n    }\n");
const pushSrc = slice("    window.ccTimeLost = function(p){", "\n    };\n");
check("the panel ships tlvDur", durSrc !== null);
check("the panel ships timeLostHtml", htmlSrc !== null);
check("the panel ships window.ccTimeLost", pushSrc !== null);
if (!(escSrc && durSrc && cardSrc && htmlSrc && pushSrc)) {
  console.log("\n-- time-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a minimal DOM: the overlay, its title, body and foot
function el() { return { innerHTML: "", textContent: "", cls: new Set(["show"]), classList: null }; }
const nodes = { timelost: el(), "tlv-title": el(), "tlv-body": el(), "tlv-foot": el() };
for (const k of Object.keys(nodes)) {
  const n = nodes[k];
  n.classList = { contains: (c) => n.cls.has(c), add: (c) => n.cls.add(c), remove: (c) => n.cls.delete(c) };
}
const document = { getElementById: (id) => nodes[id] || null };
const window = {};
const lib = new Function("document", "window",
  escSrc + "\n" + durSrc + "\n" + cardSrc + "\n" + htmlSrc + "\n" + pushSrc +
  "\nreturn { tlvDur, timeLostHtml };")(document, window);

// durations read like the callouts' (core.fmtDuration)
eq("tlvDur: seconds", lib.tlvDur(45), "45s");
eq("tlvDur: minutes and seconds", lib.tlvDur(90), "1m 30s");
eq("tlvDur: whole minutes", lib.tlvDur(2280), "38m");
eq("tlvDur: hours and minutes", lib.tlvDur(3 * 3600 + 5 * 60), "3h 5m");
eq("tlvDur: nothing", lib.tlvDur(undefined), "0s");

const EVIL = '<img src=x onerror="alert(1)">';
const view = {
  lost: 5370, you: { seconds: 2280, count: 4, bySource: { approval: { seconds: 1200, count: 2 }, question: { seconds: 1080, count: 2 } } },
  limit: { seconds: 1800 }, stalls: { seconds: 1200 }, errors: { seconds: 90 }, retry: { seconds: 10 },
  callouts: ["38m waiting on you, 12m of it on one approval", "a turn named " + EVIL],
};
const html = lib.timeLostHtml({ kind: "session", ledger: true, view });
check("callouts: each is a list item", html.includes("<li>38m waiting on you, 12m of it on one approval</li>"));
check("callouts: a session's words are escaped", html.includes("&lt;img src=x onerror=") && !html.includes(EVIL));
check("cards: the time lost", html.includes('<div class="v">1h 29m</div><div class="k">lost</div>'));
check("cards: waiting on you", html.includes('<div class="v">38m</div><div class="k">waiting on you</div>'));
check("cards: errors and retries count the larger of the two", html.includes('<div class="v">1m 30s</div><div class="k">errors &amp; retries</div>'));
check("by kind: a row per kind of wait", html.includes("<td>approvals</td>") && html.includes("<td>questions</td>"));
check("ledger on: no ledger note", !html.includes("audit ledger is off"));

const off = lib.timeLostHtml({ kind: "project", ledger: false, view: { callouts: [] } });
check("ledger off: says so, and that transcript figures still count", off.includes("audit ledger is off") && off.includes("transcripts show still counts"));
check("nothing recorded: an empty state for the project", off.includes("Nothing recorded yet for this project"));
check("an empty bySource (Lua encodes it as []) draws no table", !lib.timeLostHtml({ view: { you: { bySource: [] }, callouts: [] } }).includes("<table"));

// the push: the name is text, the foot says what the view covers
window.ccTimeLost({ kind: "project", name: EVIL, sessions: 3, days: 7, ledger: true, indexing: true, view });
check("push: the title carries the name as text", nodes["tlv-title"].textContent === "⏱ Where the time went — " + EVIL
      && nodes["tlv-title"].innerHTML === "");
check("push: the body is the rendered view", nodes["tlv-body"].innerHTML.includes("<ul class=\"tlv-callouts\">"));
eq("push: the foot says how many sessions, how far back, and that reading goes on",
   nodes["tlv-foot"].textContent, "3 sessions on this card; the ledger's last 7 days · still reading transcripts…");
nodes.timelost.cls.delete("show");
nodes["tlv-body"].innerHTML = "kept";
window.ccTimeLost({ kind: "session", name: "x", view });
eq("push: a closed view isn't repainted", nodes["tlv-body"].innerHTML, "kept");

console.log("\n-- time-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
