// pins-view.test.js - BEHAVIORAL: a session's pinned links show as chips (2026-09-29, build program
// unit 31).
//
// cc-pin.sh keeps up to 8 links per worktree; FX.stepPins stamps them on the session as it.pins
// ([{ url, kind, label }], already checked by core.parsePins). The card's badges row and the detail
// panel show them as chips; a click sends only the card's key and the pin's number (open-pin), and
// Lua checks the link again before it opens anything. Labels and links are a session's words, so
// both go through esc(). Runs the REAL shipped pinChipsHtml / openPin / badgesHtml sliced out of
// claude-dashboard.lua (the compact-notes.test.js pattern).
//
// Usage: node tests/pins-view.test.js [path/to/claude-dashboard.lua]

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
const chipsSrc = slice("    function pinChipsHtml(it){", "\n    }\n");
const openSrc = slice("    function openPin(ev){", "\n    }\n");
const badgesSrc = slice("    function badgesHtml(it){", "\n    }\n");
check("the panel ships pinChipsHtml", chipsSrc !== null);
check("the panel ships openPin", openSrc !== null);
if (!(escSrc && chipsSrc && openSrc && badgesSrc)) {
  console.log("\n-- pins-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const sent = [];
const lib = new Function("sent", "stubs",
  "var selectedKey = stubs.selectedKey;\n" +
  "function send(a, v, text){ sent.push([a, v, text]); }\n" +
  "function talkBadge(){ return ''; } function riskBadge(){ return ''; } function prBadgeHtml(){ return ''; }\n" +
  "function bgBadge(){ return ''; } function notesBadge(){ return ''; }\n" +
  escSrc + "\n" + chipsSrc + "\n" + openSrc + "\n" + badgesSrc +
  "\nreturn { pinChipsHtml, openPin, badgesHtml, setSel: function(k){ selectedKey = k; } };")(sent, { selectedKey: null });

// ---- the chips ----
eq("no pins: no chips", lib.pinChipsHtml({ key: "k1" }), "");
eq("an empty list: no chips", lib.pinChipsHtml({ key: "k1", pins: [] }), "");
eq("a null card: nothing", lib.pinChipsHtml(null), "");
const two = { key: "k1", pins: [
  { url: "https://github.com/o/r/pull/12", kind: "http", label: "PR #12" },
  { url: "file:///r/repo/docs/b.md", kind: "file", label: "b.md" } ] };
const h = lib.pinChipsHtml(two);
eq("one chip per pin", (h.match(/class="pin-chip"/g) || []).length, 2);
check("...numbered from 1 for the click", h.indexOf('data-pin="1"') >= 0 && h.indexOf('data-pin="2"') >= 0);
check("...each saying its label", h.indexOf("PR #12") >= 0 && h.indexOf("b.md") >= 0);
check("...with its link on hover", h.indexOf('title="https://github.com/o/r/pull/12') >= 0);
check("...a file reads as a file, a link as a link", h.indexOf("📄") >= 0 && h.indexOf("🔗") >= 0);
check("...and owns its own press (no double-click jump)", (h.match(/data-nodbl/g) || []).length === 2);
check("...the click hands Lua no link, only the event", h.indexOf('onclick="openPin(event)"') >= 0 && h.indexOf("open-pin") < 0);

const evil = lib.pinChipsHtml({ key: "k1", pins: [
  { url: 'https://x.example/"><img src=x onerror=alert(1)>', kind: "http", label: "<script>alert(1)</script>" } ] });
check("a label with markup is escaped", evil.indexOf("<script>") < 0 && evil.indexOf("&lt;script&gt;") >= 0);
check("a link with a quote can't leave its title attribute", evil.indexOf('"><img') < 0 && evil.indexOf("&quot;&gt;&lt;img") >= 0);

const nine = { key: "k1", pins: [] };
for (let i = 1; i <= 9; i++) nine.pins.push({ url: "http://localhost:" + (8000 + i) + "/", kind: "http", label: "p" + i });
eq("at most 8 chips", (lib.pinChipsHtml(nine).match(/class="pin-chip"/g) || []).length, 8);
eq("a pin with no link is skipped", (lib.pinChipsHtml({ pins: [{ kind: "http", label: "x" }, two.pins[0]] }).match(/class="pin-chip"/g) || []).length, 1);
check("a pin with no label shows its link", lib.pinChipsHtml({ pins: [{ url: "https://y.example/", kind: "http" }] }).indexOf(">🔗 https://y.example/<") >= 0);

check("the card's badges row carries the chips", lib.badgesHtml(two).indexOf('class="pin-chip"') >= 0);
eq("...and a card without pins gains no row", lib.badgesHtml({ key: "k2" }), "");

// ---- a click ----
// a chip element inside <parent>: closest() finds itself for [data-pin], else asks its parent
function chip(n, parent) {
  const c = { getAttribute: (k) => (k === "data-pin" ? n : null),
              closest: (sel) => (sel === "[data-pin]" ? c : parent.closest(sel)) };
  return c;
}
const tile = { getAttribute: (k) => (k === "data-key" ? "k-tile" : null), closest: (sel) => (sel === ".tile" ? tile : null) };
let stopped = 0;
lib.openPin({ target: chip("2", tile), stopPropagation: () => { stopped++; } });
check("a chip on a card sends open-pin with the card's key and the pin's number",
      sent.length === 1 && sent[0][0] === "open-pin" && sent[0][1] === "k-tile" && sent[0][2] === "2");
eq("...and the press goes no further (no tile select)", stopped, 1);
const panel = { getAttribute: () => null, closest: () => null };
lib.setSel("k-selected");
lib.openPin({ target: chip("1", panel), stopPropagation: () => {} });
check("a chip in the detail panel sends the selected session's key",
      sent.length === 2 && sent[1][1] === "k-selected" && sent[1][2] === "1");
lib.setSel(null);
lib.openPin({ target: chip("1", panel), stopPropagation: () => {} });
eq("no card and no selection: nothing is sent", sent.length, 2);

console.log("\n-- pins-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
