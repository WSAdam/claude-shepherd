// audit-findings-view.test.js - BEHAVIORAL: the find-only audit preset in the panel (2026-09-29,
// build program unit 38).
//
// The New session dialog offers a built-in 🔍 Audit (find-only) chip; a click posts a spawn with
// preset "audit" for the folder in the path box (Lua builds every flag, nothing else rides the
// message). An audit's findings import into My List tagged as findings, and each row shows a chip
// with the severity and id -- read from a file a session wrote, so both go through esc(). Runs the
// REAL shipped auditSpawn / wlAuditChip / wlFileBadges sliced out of claude-dashboard.lua (the
// lease-badge.test.js pattern).
//
// Usage: node tests/audit-findings-view.test.js [path/to/claude-dashboard.lua]

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
const spawnSrc = slice("    function auditSpawn(){", "\n    }\n");
const chipSrc = slice("    function wlAuditChip(it){", "\n    }\n");
const branchSrc = slice("    function wlBranchChip(it){", "\n    }\n");
const badgesSrc = slice("    function wlFileBadges(it, isDone){", "\n    }\n");
check("the panel ships auditSpawn", spawnSrc !== null);
check("the panel ships wlAuditChip", chipSrc !== null);
check("the dialog has the 🔍 Audit (find-only) chip", src.indexOf('onclick="auditSpawn()"') >= 0
      && src.indexOf("🔍 Audit (find-only)") >= 0);
if (!(escSrc && spawnSrc && chipSrc && branchSrc && badgesSrc)) {
  console.log("\n-- audit-findings-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a stand-in document + message channel, just enough for auditSpawn
function harness(pathBox, taskBox) {
  const posted = [], alerts = [];
  let closed = 0;
  const els = { "n-path": { value: pathBox }, "n-task": { value: taskBox }, "n-editor": { value: "kitty" },
                "n-provider": { value: "" } };
  const lib = new Function("document", "window", "alert", "closeNew",
    spawnSrc + "\nreturn { auditSpawn };")(
    { getElementById: (id) => els[id] || null },
    { webkit: { messageHandlers: { cc: { postMessage: (s) => posted.push(JSON.parse(s)) } } } },
    (m) => alerts.push(m), () => { closed++; });
  lib.auditSpawn();
  return { posted, alerts, closed };
}
const h = harness(" /Users/u/Code/shop ", "  check the cart  ");
eq("a click posts one spawn", h.posted.length, 1);
const p = h.posted[0] || {};
eq("...for the preset, by name only", p.preset, "audit");
eq("...into the folder in the path box", p.dir, "/Users/u/Code/shop");
eq("...an existing folder", p.mode, "existing");
eq("...with the typed task as its focus", p.text, "check the cart");
eq("...in the chosen editor", p.editor, "kitty");
check("...carrying no flags, tools or mode of its own (Lua decides those)",
      p.allowedTools === undefined && p.settings === undefined && !p.permMode && p.agent === undefined);
eq("...and the dialog closes", h.closed, 1);
const none = harness("relative/shop", "");
eq("no absolute folder: nothing is posted", none.posted.length, 0);
eq("...and it says why", none.alerts.length, 1);

const lib = new Function(escSrc + "\n" + chipSrc + "\n" + branchSrc + "\n" + badgesSrc +
  "\nreturn { wlAuditChip, wlFileBadges };")();
eq("a TODO line: no audit chip", lib.wlAuditChip({ text: "x" }), "");
eq("a null row: nothing", lib.wlAuditChip(null), "");
const c = lib.wlAuditChip({ text: "[HIGH] AUD-001 x", audit: { sev: "HIGH", id: "AUD-001" } });
check("a finding shows 🔍 with its severity", c.indexOf("🔍 HIGH") >= 0);
check("...in its own class, tinted by severity", c.indexOf('class="wl-aud high"') >= 0);
check("...its tooltip names the id and says it came from an audit", c.indexOf("AUD-001") >= 0 && c.indexOf("find-only audit") >= 0);
const evil = lib.wlAuditChip({ audit: { sev: '<img src=x onerror=alert(1)>', id: '"><script>alert(2)</script>' } });
check("a hostile severity never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile id (the tooltip can't be closed)", evil.indexOf("<script>") < 0);
check("...and a hostile severity can't pick a class", evil.indexOf('class="wl-aud "') >= 0);
const row = lib.wlFileBadges({ audit: { sev: "LOW", id: "AUD-002" } }, false);
check("the row's badges carry the audit chip", row.indexOf("wl-aud") >= 0);
check("...and no ✓ auto (a finding is never claimed done)", row.indexOf("✓ auto") < 0);

console.log("\n-- audit-findings-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
