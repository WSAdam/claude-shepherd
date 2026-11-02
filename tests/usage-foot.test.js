// usage-foot.test.js - BEHAVIORAL: the usage footer's plan bars (2026-11-02).
//
// FX.fetchOfficialUsage reads Anthropic's /api/oauth/usage (the numbers claude.ai/settings/usage
// shows) and pushes it as LAST_OFFICIAL; without it the footer draws a local approximation from
// the transcripts. Runs the REAL shipped renderUsageFoot (with pctBarRow, resetsIn, fmtTok, esc)
// sliced out of claude-dashboard.lua against a stand-in DOM (the compact-notes.test.js pattern).
//
// 2026-11-02: Anthropic began answering five_hour: null with the weekly window still there; the
// footer required five_hour, so it fell back to the approximation and blamed a missing login token.
//
// Usage: node tests/usage-foot.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function has(name, html, text) { check(name + "  (in " + JSON.stringify(html) + ")", html.indexOf(text) >= 0); }
function hasNot(name, html, text) { check(name + "  (in " + JSON.stringify(html) + ")", html.indexOf(text) < 0); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const parts = [
  slice("    function esc(s){", "\n    }\n"),
  slice("    function fmtTok(n){", "\n    }\n"),
  slice("    function pctBarRow(lbl, pct, valText){", "\n    }\n"),
  slice("    function resetsIn(iso){", "\n    }\n"),
  slice("    function renderUsageFoot(){", "\n    }\n"),
];
check("the panel ships renderUsageFoot and its helpers", parts.every(Boolean));
if (!parts.every(Boolean)) {
  console.log("\n-- usage-foot.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

const els = { "uf-total": {}, "uf-windows": {} };
const document = { getElementById: (id) => els[id] || null };
const lib = new Function("document",
  "var LAST_USAGE = null, LAST_OFFICIAL = null;\n" + parts.join("\n") +
  "\nreturn function(u, o){ LAST_USAGE = u; LAST_OFFICIAL = o; renderUsageFoot(); };")(document);

const now = Date.now();
const inHours = (h) => new Date(now + h * 3600e3).toISOString();
const usage = (why) => ({ fleet: { real: 44e6, output: 6.2e6 }, window: { w5h: 593200, w7d: 9.5e6 }, officialWhy: why });

// ---- the reply Anthropic sent on 2026-11-02: no 5-hour window, the weekly one at 20% ----
lib(usage(), { five_hour: null, seven_day: { utilization: 20, resets_at: inHours(26) },
  seven_day_sonnet: null, modelRows: [] });
let html = els["uf-windows"].innerHTML;
has("no 5-hour window: the official weekly bar shows", html, ">Weekly<");
has("...at Anthropic's 20%", html, ">20%<");
has("...marked official, with when it resets", html, "official · weekly resets in 1d");
hasNot("...with no Session row", html, "Session (5h)");
hasNot("...and no approximation", html, "(approx)");

// ---- both windows: as before ----
lib(usage(), { five_hour: { utilization: 41, resets_at: inHours(2) }, seven_day: { utilization: 20, resets_at: inHours(26) } });
html = els["uf-windows"].innerHTML;
has("both windows: the Session bar", html, ">Session (5h)<");
has("...at 41%", html, ">41%<");
has("...and the weekly one", html, ">Weekly<");
has("...both resets", html, "official · 5h resets in 2h");

// ---- no official numbers: the approximation, saying why ----
lib(usage("can't reach Anthropic"), null);
html = els["uf-windows"].innerHTML;
has("no official numbers: the approximation", html, "5h (approx)");
has("...saying why", html, "official % unavailable (can&#39;t reach Anthropic)");
hasNot("...and never blaming a token it has", html, "no Claude login token found");

lib(usage("no Claude login token found"), null);
has("no token: says so", els["uf-windows"].innerHTML, "official % unavailable (no Claude login token found)");

lib(usage("Anthropic's reply had no usage window"), { five_hour: null, seven_day: null, limits: [] });
html = els["uf-windows"].innerHTML;
has("a reply with no window at all: the approximation", html, "7d (approx)");
has("...saying why", html, "Anthropic&#39;s reply had no usage window");

lib(usage(), null);
has("no reason sent (an older Lua): a plain fallback", els["uf-windows"].innerHTML, "official % unavailable</span>");

lib(usage("<b>x</b>"), null);
hasNot("the reason is escaped", els["uf-windows"].innerHTML, "<b>x</b>");

console.log("\n-- usage-foot.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
