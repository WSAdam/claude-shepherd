// bulk-actionable.test.js - BEHAVIORAL: the panel's actionableKeys twin answers to the same table as
// core.selectActionable (2026-10-13).
//
// The fleet bar read "✅ Approve all (1)" for a `git push` waiting in Claude Code's own prompt, in a
// VS Code window shared by three sessions. Shepherd types into a window, not a tab, so
// core.handleAction refuses that approve, and the click only toasted a refusal. The bar counts with
// actionableKeys while Lua acts with core.selectActionable, so both read
// tests/fixtures/bulk-shared-window.tsv: if they ever disagreed, the number on the button would not
// be what the click does. Runs the REAL shipped actionableKeys sliced out of claude-dashboard.lua,
// with BULK_RULES read from cc-core.lua as the panel injects them.
//
// Usage: node tests/bulk-actionable.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const ROOT = path.join(__dirname, "..");
const DASH = process.argv[2] || path.join(ROOT, "claude-dashboard.lua");

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
const keysSrc = slice("    function actionableKeys(action, items){", "\n    }\n");
check("the panel ships actionableKeys", keysSrc !== null);
if (keysSrc === null) {
  console.log("-- bulk-actionable.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
// the panel's BULK_RULES is core.BULK_RULES, injected at load (__BULK_RULES__)
const rules = JSON.parse(execFileSync("lua", ["-e",
  "local c = dofile(" + JSON.stringify(path.join(ROOT, "cc-core.lua")) + ")" +
  " local j = dofile(" + JSON.stringify(path.join(ROOT, "tests", "support", "json.lua")) + ")" +
  " io.write(j.encode(c.BULK_RULES))"]).toString());
check("BULK_RULES came from cc-core.lua", rules && rules.approve && rules.approve.match === "approval");
const actionableKeys = new Function("BULK_RULES", keysSrc + "\nreturn actionableKeys;")(rules);

const table = fs.readFileSync(path.join(__dirname, "fixtures", "bulk-shared-window.tsv"), "utf8");
let n = 0;
table.split("\n").forEach(function (line) {
  if (!line || line[0] === "#") return;
  const parts = line.split("\t");
  if (parts.length < 3) return;
  const action = parts[0], want = parts[1], js = parts.slice(2).join("\t");
  n++;
  const got = actionableKeys(action, [JSON.parse(js)]).length === 1 ? "in" : "out";
  eq("bulk-shared-window.tsv: " + action + " " + want + "  " + js, got, want);
});
check("the table was read (15+ cases)", n >= 15);
eq("an unknown action counts nothing", actionableKeys("bogus", [{ key: "a", status: "approval" }]).length, 0);

console.log("-- bulk-actionable.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
