// coverage-view.test.js - BEHAVIORAL fixture for the coverage index in the batch review
// (2026-09-29, build program unit 25). Runs the REAL shipped renderBatch and mergeFillList: they
// are sliced straight out of claude-dashboard.lua and driven against a small stub DOM.
//
// A batch built from an issue list can't be approved until every issue is covered by a unit or
// triaged: the review lists the uncovered issues (id and title, through textContent -- the
// driver wrote them) and disables Approve. Deny stays enabled. A batch with no issue list shows
// no coverage block and a live Approve, as before.
//
// Usage: node tests/coverage-view.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("-- coverage-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed === 0 ? 0 : 1); }

const src = fs.readFileSync(DASH, "utf8");
function slice(head) {
  const i = src.indexOf(head);
  const j = i < 0 ? -1 : src.indexOf("\n    }\n", i);
  return (i >= 0 && j > i) ? src.slice(i, j + 7) : null;
}
const renderSrc = slice("    function renderBatch(it){");
const fillSrc = slice("    function mergeFillList(el, rows, fmt){");
check("the shipped renderBatch and mergeFillList are in the panel source", !!renderSrc && !!fillSrc);
if (!renderSrc || !fillSrc) done();

// A stub DOM: every element exists on first use; innerHTML is a trap (the review never uses it).
let els = {};
function node(tag) {
  const n = { tag: tag, style: {}, textContent: "", disabled: false, checked: false, title: "", attrs: {}, children: [],
              setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
              appendChild(c) { this.children.push(c); return c; },
              removeChild(c) { this.children.splice(this.children.indexOf(c), 1); return c; },
              get firstChild() { return this.children[0] || null; } };
  Object.defineProperty(n, "innerHTML", { set() { throw new Error("innerHTML used in the batch review"); }, get() { return ""; } });
  return n;
}
const document = {
  getElementById(id) { return els[id] || (els[id] = node("#" + id)); },
  createElement(tag) { return node(tag); },
};
const renderBatch = new Function("document", "var BATCH_ID = null;\n" + fillSrc + renderSrc + "\nreturn renderBatch;")(document);
// an element renderBatch never touched reads as a fresh one, so a missing feature FAILs, not crashes
function draw(fleet) {
  els = {}; renderBatch({ fleet: fleet });
  return new Proxy({}, { get(_, id) { return document.getElementById(id); } });
}
function lines(el) { return (el.children || []).map(function(c){ return c.textContent; }); }

const UNITS = [{ type: "fix", slug: "paste", branch: "fix/paste", task: "Fix paste.", covers: ["BUG-1"] }];

// ---- uncovered: Approve is disabled, the uncovered issues listed ----
let e = draw({ id: "b1", phase: "proposed", title: "Sweep", line: "⇉ proposes 1 unit in A · 2 issues uncovered", repo: "A",
  units: UNITS, approvable: false,
  coverage: { total: 3, line: "⚠ 2 of 3 issues aren't covered by a unit or triaged — Approve waits until they are",
              uncovered: [{ id: "BUG-2", title: "Toast covers Approve" }, { id: "REQ-3", title: "<img src=x onerror=alert(1)>" }] } });
eq("uncovered: Approve is disabled", e["db-approve"].disabled, true);
check("...and its tooltip says why  (" + e["db-approve"].title + ")", /cover/i.test(e["db-approve"].title));
eq("...Deny stays enabled", e["db-deny"].disabled, false);
eq("the coverage line is shown", e["db-cover"].textContent, "⚠ 2 of 3 issues aren't covered by a unit or triaged — Approve waits until they are");
eq("...visible", e["db-cover"].style.display, "");
const got = lines(e["db-uncovered"]);
eq("each uncovered issue is listed, id then title", got[0], "BUG-2 — Toast covers Approve");
eq("...a title with markup goes in as text, untouched", got[1], "REQ-3 — <img src=x onerror=alert(1)>");
eq("...and the list is shown", e["db-uncovered"].style.display, "");

// ---- covered: Approve enabled, the line still says what the batch covers, no list ----
e = draw({ id: "b2", phase: "proposed", title: "Sweep", line: "⇉ proposes 1 unit in A", repo: "A", units: UNITS, approvable: true,
  coverage: { total: 3, line: "✓ all 3 issues accounted for: 2 covered by units, 1 triaged", uncovered: [] } });
eq("covered: Approve is enabled", e["db-approve"].disabled, false);
eq("...the coverage line says so", e["db-cover"].textContent, "✓ all 3 issues accounted for: 2 covered by units, 1 triaged");
eq("...and there is no uncovered list", e["db-uncovered"].style.display, "none");

// ---- no issue list: as before ----
e = draw({ id: "b3", phase: "proposed", title: "Two helpers", line: "⇉ proposes 1 unit in A", repo: "A", units: UNITS, approvable: true });
eq("no issue list: Approve is enabled", e["db-approve"].disabled, false);
eq("...no coverage line", e["db-cover"].style.display, "none");
eq("...no uncovered list", e["db-uncovered"].style.display, "none");

// ---- a batch the view marks unapprovable but that isn't proposed any more: nothing to disable ----
e = draw({ id: "b4", phase: "approved", title: "Sweep", line: "⇉ driving 1 unit in A", repo: "A", units: UNITS, approvable: false,
  coverage: { total: 1, line: "⚠ 1 of 1 issues isn't covered", uncovered: [{ id: "BUG-2", title: "t" }] } });
eq("approved: the (hidden) Approve isn't left disabled for the next proposal", e["db-approve"].disabled, false);

done();
