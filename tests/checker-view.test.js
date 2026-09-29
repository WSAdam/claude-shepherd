// checker-view.test.js - BEHAVIORAL fixture for the merge checker's line in the review
// (2026-09-29, build program unit 17). Runs the REAL shipped checkerText: it is sliced straight
// out of claude-dashboard.lua, so there is no copy of the wording to drift.
//
// The checker's verdict (pass / fail / couldn't run) and the red flags Shepherd found without a
// model show in the merge review, and for a session with no merge request, under its buttons
// after Verify. The text is set with textContent: the summary and findings are a model's words.
//
// Usage: node tests/checker-view.test.js [path/to/claude-dashboard.lua]

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
const i = src.indexOf("    function checkerText(c){");
const j = i < 0 ? -1 : src.indexOf("\n    }\n", i);
check("the shipped checkerText is in the panel source", i >= 0 && j > i);
if (i < 0 || j < 0) { console.log("-- checker-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(1); }
const checkerText = new Function(src.slice(i, j + 7) + "\nreturn checkerText;")();

let r = checkerText(null);
eq("no checker: nothing to show", r.text, "");

r = checkerText({ state: "running", flags: [] });
eq("running: says a read-only review is running", r.text, "Checker: a read-only Sonnet review is running…");
eq("...styled as running", r.cls, "dm-checker c-running");

r = checkerText({ state: "queued", flags: ["stub in app.lua: -- TODO"] });
check("queued: says so, and the red flags show before the model answers",
  r.text.indexOf("Checker: queued behind another review in this repo…") === 0
  && r.text.indexOf("\nRed flags (found without a model):\n• stub in app.lua: -- TODO") > 0);

r = checkerText({ state: "done", verdict: "pass", summary: "Adds the checker.", costUsd: 0.11, flags: [], findings: [] });
eq("pass: the verdict, what it cost, its summary", r.text, "Checker: ✓ pass · $0.11 — Adds the checker.");
eq("...styled as a pass", r.cls, "dm-checker c-pass");

r = checkerText({ state: "done", verdict: "fail", summary: "Deletes a test.", flags: ["test deleted: tests/a.test.lua"],
  findings: [{ file: "tests/a.test.lua", line: 3, severity: "high", issue: "the fixture is gone" }, { file: "b.lua", issue: "nit", severity: "low" }] });
check("fail: the verdict and each finding with where it is  (" + JSON.stringify(r.text) + ")",
  r.text.indexOf("Checker: ✗ fail — Deletes a test.") === 0
  && r.text.indexOf("\n• tests/a.test.lua:3 — the fixture is gone (high)") > 0
  && r.text.indexOf("\n• b.lua — nit (low)") > 0
  && r.text.indexOf("\n• test deleted: tests/a.test.lua") > 0);
eq("...styled as a fail", r.cls, "dm-checker c-fail");

r = checkerText({ state: "done", verdict: "couldntRun", why: "it ran out of turns", attempts: 2, flags: [] });
eq("couldn't run: says why, and that nothing was proven", r.text,
  "Checker: couldn't run (it ran out of turns, 2 tries) — nothing was proven either way");
eq("...styled as couldn't-run", r.cls, "dm-checker c-couldntRun");

r = checkerText({ state: "done", verdict: "pass", summary: "ok", stale: true, flags: [] });
check("a verdict on an earlier commit says so", r.text.indexOf("Checker (an earlier commit): ✓ pass") === 0);

r = checkerText({ state: "done", verdict: "fail", summary: "<img src=x onerror=alert(1)>", flags: [] });
check("a summary is text, never markup (it goes in with textContent)", r.text.indexOf("<img src=x onerror=alert(1)>") > 0);

console.log("-- checker-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
