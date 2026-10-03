// brief-flags-view.test.js - BEHAVIORAL fixture for the brief pre-flight in the batch review
// (2026-10-03, mining round 2 unit E3). Runs the REAL shipped renderBatch and mergeFillList:
// they are sliced straight out of claude-dashboard.lua and driven against a small stub DOM.
//
// While a batch is proposed, the review shows core.batchView's pre-flight: one line, then a row
// per flag (a brief's risky words, two units citing one file, two units changing hook wiring).
// Every row is the driver's own words, so it goes in through textContent. Advisory only: a
// flagged batch's Approve stays enabled. Once approved, the pre-flight is gone.
//
// Usage: node tests/brief-flags-view.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("-- brief-flags-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed === 0 ? 0 : 1); }

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
check("the panel has the pre-flight's line and list", src.includes('id="db-preflight"') && src.includes('id="db-flags"'));

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
function draw(fleet) {
  els = {}; renderBatch({ fleet: fleet });
  return new Proxy({}, { get(_, id) { return document.getElementById(id); } });
}
function lines(el) { return (el.children || []).map(function(c){ return c.textContent; }); }

const UNITS = [{ type: "feat", slug: "alpha", branch: "feat/alpha", task: "Add alpha." },
               { type: "feat", slug: "beta", branch: "feat/beta", task: "Add beta." }];
const FLAGGED = {
  count: 3,
  line: "⚑ Pre-flight: 3 flags — 1 in the briefs, 2 across the batch. Advisory: Approve isn't held.",
  rows: ["alpha: force push — “…rebase and git push --force origin feat/x…”",
         "batch: cc-core.lua is cited by alpha, beta",
         "batch: <img src=x onerror=alert(1)> is cited by alpha, beta"],
};

// ---- proposed, with flags: the line and every row, as text; Approve stays live ----
let e = draw({ id: "b1", phase: "proposed", title: "Two", line: "⇉ proposes 2 units in A · ⚑ 3 pre-flight flags", repo: "A",
  units: UNITS, approvable: true, preflight: FLAGGED });
eq("flagged: the pre-flight line is shown", e["db-preflight"].textContent, FLAGGED.line);
eq("...visible", e["db-preflight"].style.display, "");
const got = lines(e["db-flags"]);
eq("...a row per flag, in order", got.length, 3);
eq("...a brief's flag names the unit, the flag and the words", got[0], FLAGGED.rows[0]);
eq("...a batch flag", got[1], "batch: cc-core.lua is cited by alpha, beta");
eq("...markup in a row goes in as text, untouched", got[2], "batch: <img src=x onerror=alert(1)> is cited by alpha, beta");
eq("...and the list is shown", e["db-flags"].style.display, "");
eq("advisory: a flagged batch's Approve stays enabled", e["db-approve"].disabled, false);

// ---- proposed, clean: the line says the scan ran, no list ----
e = draw({ id: "b2", phase: "proposed", title: "Two", line: "⇉ proposes 2 units in A", repo: "A", units: UNITS, approvable: true,
  preflight: { count: 0, line: "✓ Pre-flight: no risky phrasing in the briefs.", rows: [] } });
eq("clean: the line says so", e["db-preflight"].textContent, "✓ Pre-flight: no risky phrasing in the briefs.");
eq("...and there is no list", e["db-flags"].style.display, "none");

// ---- approved: the pre-flight has done its job ----
e = draw({ id: "b3", phase: "approved", title: "Two", line: "⇉ driving 2 units in A", repo: "A", units: UNITS, approvable: true,
  preflight: FLAGGED });
eq("approved: no pre-flight line", e["db-preflight"].style.display, "none");
eq("...and no list", e["db-flags"].style.display, "none");

// ---- an older view with no pre-flight at all: nothing shown, nothing breaks ----
e = draw({ id: "b4", phase: "proposed", title: "Two", line: "⇉ proposes 2 units in A", repo: "A", units: UNITS, approvable: true });
eq("no pre-flight: no line", e["db-preflight"].style.display, "none");
eq("...no list", e["db-flags"].style.display, "none");

done();
