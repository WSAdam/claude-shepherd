// hookless-card.test.js - BEHAVIORAL: a grey card for a live session Shepherd has no status file
// for (2026-10-03, mining round 2 unit F1).
//
// FX.stepHookless (core.hooklessSessions) finds the live interactive sessions in
// ~/.claude/sessions/<pid>.json that no status file names -- started before Shepherd's hooks were
// installed, or with hooks off -- and the panel draws each as a grey card in its own row under the
// grid. Every field comes from Claude Code's own session file (the folder name is anyone's to pick),
// so all of it goes through esc(). The card is display only: no data-key, so no tile handler acts
// on it. Runs the REAL shipped hooklessCardHtml / ccHookless sliced out of claude-dashboard.lua
// (the maingreen-badge.test.js pattern).
//
// Usage: node tests/hookless-card.test.js [path/to/claude-dashboard.lua]

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
const cardSrc = slice("    function hooklessCardHtml(h){", "\n    }\n");
const pushSrc = slice("    window.ccHookless = function(list){", "\n    };\n");
check("the panel ships hooklessCardHtml", cardSrc !== null);
check("the panel ships window.ccHookless", pushSrc !== null);
if (!(escSrc && cardSrc && pushSrc)) {
  console.log("\n-- hookless-card.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a tiny DOM: the two elements ccHookless touches
function el() { return { innerHTML: "", style: { display: "" }, writes: 0 }; }
const box = el(), empty = el();
const document = { getElementById: (id) => (id === "hookless" ? box : id === "empty" ? empty : null) };
const window = {};
const state = { lastItems: [] };
new Function("document", "window", "state",
  "var lastItems = state.lastItems;\n" +
  "var HOOKLESS_N = 0, HOOKLESS_SIG = null;\n" +
  escSrc + "\n" + cardSrc + "\n" + pushSrc +
  "\nwindow.hooklessCardHtml = hooklessCardHtml;\nwindow.hooklessCount = function(){ return HOOKLESS_N; };\n" +
  "window.setLastItems = function(x){ lastItems = x; };")(document, window, state);

const hint = "started before Shepherd's hooks: restart it to get live status";
const card = { pid: "202", project: "shop", cwd: "/Users/a/shop", state: "idle", hint: hint, version: "2.1.286" };
const h = window.hooklessCardHtml(card);
check("a grey card: the hookless tile class", h.indexOf('<div class="tile hookless"') === 0);
check("...names the project", h.indexOf('<span class="name">shop</span>') >= 0);
check("...shows the registry's busy/idle", h.indexOf(">Idle<") >= 0);
check("...and why it is grey (escaped: the apostrophe)", h.indexOf("started before Shepherd&#39;s hooks: restart it to get live status") >= 0);
check("...its tooltip names the folder and pid", h.indexOf("pid 202") >= 0 && h.indexOf("/Users/a/shop") >= 0);
check("...and carries no data-key, so no tile handler acts on it", h.indexOf("data-key") < 0);
check("busy reads Busy", window.hooklessCardHtml({ state: "busy" }).indexOf(">Busy<") >= 0);
check("waiting reads Waiting", window.hooklessCardHtml({ state: "waiting" }).indexOf(">Waiting<") >= 0);
check("anything else reads Unknown, never raw", window.hooklessCardHtml({ state: "<b>x</b>" }).indexOf(">Unknown<") >= 0
      && window.hooklessCardHtml({ state: "<b>x</b>" }).indexOf("<b>") < 0);
check("a null card still draws", typeof window.hooklessCardHtml(null) === "string");

const evil = window.hooklessCardHtml({ pid: '1"><script>alert(1)</script>', project: "<img src=x onerror=alert(2)>",
  cwd: '/tmp/"><svg onload=alert(3)>', hint: "<i>x</i>", version: '"><b>' });
check("a hostile folder name never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile path or pid in the tooltip (it can't be closed)", evil.indexOf("<svg") < 0 && evil.indexOf("<script>") < 0
      && evil.indexOf("<b>") < 0);
check("...nor a hostile hint", evil.indexOf("<i>") < 0);

// the push: its own row, the empty-grid message steps aside, an unchanged list isn't redrawn
window.ccHookless([card]);
eq("ccHookless draws one card into #hookless", (box.innerHTML.match(/class="tile hookless"/g) || []).length, 1);
eq("...hides 'Waiting for sessions' when the grid is empty", empty.style.display, "none");
eq("...and counts it", window.hooklessCount(), 1);
const before = box.innerHTML;
box.innerHTML = "SENTINEL";
window.ccHookless([card]);
eq("an unchanged list doesn't redraw the row", box.innerHTML, "SENTINEL");
box.innerHTML = before;
window.ccHookless([]);
eq("none: the row empties", box.innerHTML, "");
eq("...and the empty-grid message comes back", empty.style.display, "block");
window.setLastItems([{ key: "k" }]);
empty.style.display = "none";
window.ccHookless([card]);
eq("with session cards on the grid, the empty-grid message is left alone", empty.style.display, "none");
window.ccHookless(null);
eq("junk payload: no cards", window.hooklessCount(), 0);

console.log("\n-- hookless-card.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
