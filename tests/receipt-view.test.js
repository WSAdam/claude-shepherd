// receipt-view.test.js - BEHAVIORAL fixture for the merge receipt in the review (2026-09-29, build
// program unit 22). Runs the REAL shipped receiptText: it is sliced straight out of
// claude-dashboard.lua, so there is no copy of the wording to drift.
//
// The receipt says what was asked and what proves it's done: the source (a batch, the REQ ids the
// request names, or the session's first prompt), the requester's words, the tests the unit changed
// by layer, the evidence Shepherd gathered, and the known issues the unit declared. Display only --
// the text is set with textContent (every part of it was written by a session or a driver).
//
// Usage: node tests/receipt-view.test.js [path/to/claude-dashboard.lua]

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
const i = src.indexOf("    function receiptText(rc){");
const j = i < 0 ? -1 : src.indexOf("\n    }\n", i);
check("the shipped receiptText is in the panel source", i >= 0 && j > i);
if (i < 0 || j < 0) { console.log("-- receipt-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(1); }
const receiptText = new Function(src.slice(i, j + 7) + "\nreturn receiptText;")();
const HEAD = "Receipt — what was asked, and what proves it's done:";

eq("no receipt: nothing to show", receiptText(null), "");
eq("an empty object: nothing to show", receiptText({}), "");

let t = receiptText({
  source: { batch: { title: "B11: REQ ids", unit: "feat/req-ids" },
            reqs: [{ id: "REQ-001", title: "Merge reviews carry a receipt" }, { id: "REQ-009", unknown: true }] },
  asked: { by: "batch", text: "Unit 22: requirements get ids" },
  tests: { count: 3, layers: [{ layer: "core", files: ["tests/reqs.test.lua"], n: 1 },
                              { layer: "bash", files: ["tests/merge.test.sh", "tests/b.test.sh"], n: 2 }] },
  evidence: { gate: "passed", gateCommand: "make lint && make test", redFirst: "red", checker: "pass" },
  knownIssues: "The tab can't edit a requirement yet",
});
eq("a batch unit's receipt, line by line", t, [
  HEAD,
  "Source: batch \"B11: REQ ids\", unit feat/req-ids · REQ-001 Merge reviews carry a receipt · REQ-009 (not minted for this repo)",
  "Asked (the driver's brief): Unit 22: requirements get ids",
  "Tests changed: 3 — core: tests/reqs.test.lua · bash: tests/merge.test.sh, tests/b.test.sh",
  "Evidence: gate passed (make lint && make test) · red-first proved red · checker pass",
  "Known issues: The tab can't edit a requirement yet",
].join("\n"));

t = receiptText({
  source: { reqs: [] }, asked: { by: "prompt", text: "Build the receipt" },
  tests: { count: 0, layers: [] }, evidence: { gate: "off", redFirst: "off", checker: "off" },
});
eq("a plain session with nothing declared says so, plainly", t, [
  HEAD,
  "Source: the session's first prompt",
  "Asked (the session's first prompt): Build the receipt",
  "Tests changed: none — no test file in the diff",
  "Evidence: gate not configured · red-first not run · checker not run",
  "Known issues: none stated",
].join("\n"));

t = receiptText({ source: { reqs: [] }, tests: { count: 0, layers: [], pending: true },
                  evidence: { gate: "running", gateCommand: "make test", redFirst: "waiting", checker: "running" } });
eq("nothing on record yet, evidence still coming", t, [
  HEAD,
  "Source: not recorded",
  "Asked: not on record",
  "Tests changed: waiting for the diff",
  "Evidence: gate running (make test) · red-first waits for the gate · checker running",
  "Known issues: none stated",
].join("\n"));

t = receiptText({ source: { reqs: [] }, tests: { count: 30, cut: true,
                  layers: [{ layer: "core", files: ["a", "b"], n: 30 }] },
                  evidence: { gate: "failed", redFirst: "notRed", checker: "fail" } });
check("a cut list and a capped layer say there's more  (" + JSON.stringify(t) + ")",
  t.indexOf("Tests changed: 30+ — core: a, b (+28 more)") >= 0);
check("...and red evidence reads as red", t.indexOf("Evidence: gate failed · red-first not red · checker fail") >= 0);
eq("the gate that couldn't run, the checker that couldn't run, a proof with no test to run",
  receiptText({ source: { reqs: [] }, tests: { count: 0, layers: [] },
                evidence: { gate: "couldntRun", redFirst: "none", checker: "couldntRun" } }).split("\n")[4],
  "Evidence: gate couldn't run · red-first had no changed test · checker couldn't run");

// markup in any part is text: the review sets it with textContent, and receiptText never builds HTML
t = receiptText({ source: { batch: { title: "<img src=x onerror=alert(1)>", unit: "feat/x" }, reqs: [] },
                  asked: { by: "batch", text: "<b>hi</b>" }, tests: { count: 0, layers: [] },
                  evidence: {}, knownIssues: "<script>x</script>" });
check("markup passes through as literal text, for textContent", t.indexOf("<script>x</script>") >= 0 && t.indexOf("<b>hi</b>") >= 0);
const setter = src.indexOf('document.getElementById("dm-receipt").textContent = ');
check("the review sets the receipt with textContent, never innerHTML", setter >= 0
  && src.indexOf('document.getElementById("dm-receipt").innerHTML') < 0);

console.log("-- receipt-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
