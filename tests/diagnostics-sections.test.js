// diagnostics-sections.test.js - BEHAVIORAL: Diagnostics groups rows under a section header
// (2026-09-29, build program unit 40).
//
// core.doctorChecks gained a "Claude Code compatibility" section: its rows carry
// section = "Claude Code compatibility" and come last. The overlay prints a header where a section
// starts; the rows before it (no section) render exactly as they always did. A row's words can
// quote a transcript or a binary path, so the header, like every other field, goes through esc().
// Runs the REAL shipped doctorRowsHtml sliced out of claude-dashboard.lua (the lease-badge pattern).
//
// Usage: node tests/diagnostics-sections.test.js [path/to/claude-dashboard.lua]

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
const rowsSrc = slice("    function doctorRowsHtml(rows){", "\n    }\n");
check("the panel ships doctorRowsHtml", rowsSrc !== null);
if (!(escSrc && rowsSrc)) {
  console.log("\n-- diagnostics-sections.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + rowsSrc + "\nreturn { doctorRowsHtml };")();
const count = (s, needle) => s.split(needle).length - 1;

const SEC = "Claude Code compatibility";
const rows = [
  { label: "jq installed", status: "ok", detail: "JSON processing available" },
  { label: "3 live sessions", status: "info", detail: "tiles currently tracked" },
  { label: "Claude Code 2.1.300 changed what Shepherd relies on", status: "warn", detail: "2 checks below failed", section: SEC },
  { label: "Hook event unknown to Claude Code 2.1.300: PreCompact", status: "crit", detail: "...", fix: "make setup", section: SEC },
];
const html = lib.doctorRowsHtml(rows);
eq("one header for the section", count(html, '<div class="doc-sec">'), 1);
check("...naming it", html.indexOf('<div class="doc-sec">Claude Code compatibility</div>') >= 0);
check("...placed where the section starts, after the general rows",
      html.indexOf("3 live sessions") < html.indexOf('class="doc-sec"')
      && html.indexOf('class="doc-sec"') < html.indexOf("changed what Shepherd relies on"));
eq("every row still renders", count(html, 'class="doc-row '), 4);
check("a critical row keeps its class", html.indexOf('class="doc-row doc-crit"') >= 0);
eq("rows with no section render no header (Diagnostics before this unit)", count(lib.doctorRowsHtml(rows.slice(0, 2)), "doc-sec"), 0);
eq("no rows: nothing (the caller shows 'No checks.')", lib.doctorRowsHtml([]), "");
eq("a missing list is no rows", lib.doctorRowsHtml(null), "");
const evil = lib.doctorRowsHtml([{ label: "x", status: "info", section: '<img src=x onerror=alert(1)>' },
                                 { label: '<b>"[Interrupted]"</b>', status: "warn", detail: "<script>alert(2)</script>", section: '<img src=x onerror=alert(1)>' }]);
check("a hostile section name never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
eq("...and is still one header", count(evil, 'class="doc-sec"'), 1);
check("a quoted transcript line in a row is escaped too", evil.indexOf("<script>") < 0 && evil.indexOf("<b>") < 0);

console.log("\n-- diagnostics-sections.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
