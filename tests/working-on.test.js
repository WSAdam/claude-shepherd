// working-on.test.js - BEHAVIORAL: each card says what its session is working on (2026-09-29).
//
// Build program unit 10. Runs the REAL shipped workingOnHtml + metaHtml (and the panel's own esc)
// sliced out of claude-dashboard.lua (the done-order.test.js pattern), so there is no copy of the
// rendering to drift. The Lua tick stamps it.workingOn = { label, tool, toolSecs, skill }
// (core.workingOnView); the card's meta line leads with it when nothing more urgent -- a held
// question, an approval, an error, a merge, a batch or a missing tab -- claims the line, and the
// detail header always shows it. Every field was written by a session or its transcript, so every
// one goes through esc().
//
// Usage: node tests/working-on.test.js [path/to/claude-dashboard.lua]

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
const woSrc = slice("    function workingOnHtml(it){", "\n    }\n");
const metaSrc = slice("    function metaHtml(meta, wo){", "\n    }\n");
check("the panel ships esc", escSrc !== null);
check("the panel ships workingOnHtml", woSrc !== null);
check("the panel ships metaHtml", metaSrc !== null);
if (!escSrc || !woSrc || !metaSrc) {
  console.log("\n-- working-on.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + woSrc + "\n" + metaSrc + "\nreturn { esc: esc, workingOnHtml: workingOnHtml, metaHtml: metaHtml };")();

// ---- the chips and the label ----
const full = lib.workingOnHtml({ workingOn: { label: "Fix the tile layout", tool: "Bash", toolSecs: 12, skill: "dataviz" } });
check("the tool running now is a chip", full.indexOf('class="wo-chip wo-tool"') >= 0 && full.indexOf("Bash") >= 0);
check("the skill in use is a chip", full.indexOf('class="wo-chip wo-skill"') >= 0 && full.indexOf("dataviz") >= 0);
check("the label leads, then the tool, then the skill",
      full.indexOf("Fix the tile layout") < full.indexOf("Bash") && full.indexOf("Bash") < full.indexOf("dataviz"));
check("the label is marked as what it's working on", full.indexOf('class="wo-label"') >= 0);
eq("a label alone is just the label", lib.workingOnHtml({ workingOn: { label: "Ship it" } }).indexOf("wo-chip"), -1);
eq("no workingOn says nothing", lib.workingOnHtml({}), "");
eq("an empty workingOn says nothing", lib.workingOnHtml({ workingOn: {} }), "");
eq("a non-object says nothing", lib.workingOnHtml({ workingOn: "<b>x</b>" }), "");
eq("no tile says nothing", lib.workingOnHtml(null), "");

// every field was written by a session or its transcript: none reaches innerHTML raw
const evil = "<img src=x onerror=alert(1)>";
const hostile = lib.workingOnHtml({ workingOn: { label: evil, tool: evil, skill: '"><script>1</script>' } });
check("a hostile label, tool or skill is escaped  (" + hostile + ")",
      hostile.indexOf("<img") < 0 && hostile.indexOf("<script") < 0 && hostile.indexOf("&lt;img") >= 0);

// ---- the meta line: it leads, ahead of the chat title and the extras ----
// On a narrow card the ellipsis clips the END of the line. With the chat title leading, a doubled-up
// project's card clipped the working-on line away whole (working-on.browser.test.js, first run).
const wo = lib.workingOnHtml({ workingOn: { label: "Fix it" } });
eq("no working-on: the meta line is the escaped text as before", lib.metaHtml("a <b> · 2 queued", ""), "a &lt;b&gt; · 2 queued");
eq("working-on alone", lib.metaHtml("", wo), wo);
eq("working-on leads the chat title", lib.metaHtml("💬 Rework grid", wo), wo + " · 💬 Rework grid");
eq("...and the extras", lib.metaHtml("💬 T · +2 queued · ⏳ stalled", wo), wo + " · 💬 T · +2 queued · ⏳ stalled");
eq("the text after it is still escaped", lib.metaHtml("💬 <T> · <x>", wo), wo + " · 💬 &lt;T&gt; · &lt;x&gt;");

// ---- where it shows ----
const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile's meta chain gives the line to working-on only after the tab-less line",
      /else if\(it\.tabless\)\{\s*meta = TABLESS_T;[^\n]*\n\s*\} else \{\s*wo = workingOnHtml\(it\);\s*\}/.test(tile));
check("the tile renders the meta line through metaHtml when it has one", tile.indexOf("(wo ? metaHtml(meta, wo) : esc(meta))") >= 0);
const detail = slice("    function renderDetail(){", "\n    }\n") || "";
const working = slice("    function renderWorking(it){", "\n    }\n") || "";
check("the detail header shows it", detail.indexOf("renderWorking(it);") >= 0
      && working.indexOf('getElementById("d-working")') >= 0 && working.indexOf("workingOnHtml(it)") >= 0);
check("the detail header has its slot under the name row",
      /<div id="d-head">[\s\S]*?<\/div>\s*<div id="d-working"><\/div>/.test(src));

console.log("\n-- working-on.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
