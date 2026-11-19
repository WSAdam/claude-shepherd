// change-diff.test.js - BEHAVIORAL: an approval card shows the change an Edit / Write / MultiEdit asks
// to make, as a capped line diff under "Wants:" (2026-11-19, mining round 4 #3, Adam picked it).
//
// The card said only "Wants: <path>", so an Approve -- a gate Approve, and soon a native prompt's --
// authorized text Adam never saw. The hooks put a capped copy of the change on pending.change
// (cc_pending_change); the panel draws it. Runs the REAL shipped changeLineDiff / changeDiffHtml sliced
// out of claude-dashboard.lua, with the panel's own esc().
//
// Usage: node tests/change-diff.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("-- change-diff.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const escSrc = slice("    function esc(s){", "\n    }\n");
const diffSrc = slice("    function changeLineDiff(a, b){", "\n    }\n");
const htmlSrc = slice("    function changeDiffHtml(ch){", "\n    }\n");
check("the panel ships changeLineDiff", diffSrc !== null);
check("the panel ships changeDiffHtml", htmlSrc !== null);
if (!escSrc || !diffSrc || !htmlSrc) done();

// eslint-disable-next-line no-new-func
const api = new Function(escSrc + "\n" + diffSrc + "\n" + htmlSrc + "\nreturn { changeLineDiff: changeLineDiff, changeDiffHtml: changeDiffHtml };")();

// ---- the line diff ----
const d = api.changeLineDiff("let x = 1;\nkeep();\ngone();", "let x = 2;\nkeep();\nadded();");
const marks = d.rows.map(function (r) { return r.t + r.s; }).join("|");
check("an edit's diff: the changed line out and in, the kept line as context  (" + marks + ")",
      marks.indexOf("-let x = 1;") >= 0 && marks.indexOf("+let x = 2;") >= 0 && marks.indexOf(" keep();") >= 0
      && marks.indexOf("-gone();") >= 0 && marks.indexOf("+added();") >= 0);
check("...the removed line comes before the added one", marks.indexOf("-let x = 1;") < marks.indexOf("+let x = 2;"));
eq("identical text has no added or removed lines",
   api.changeLineDiff("a\nb", "a\nb").rows.filter(function (r) { return r.t !== " "; }).length, 0);
const big = api.changeLineDiff(Array(600).fill("x").join("\n"), Array(600).fill("y").join("\n"));
check("a very long change is capped in lines, and says how many it left out  (" + big.rows.length + ", " + big.more + ")",
      big.rows.length <= 400 && big.more > 0);

// ---- the card's html ----
const h = api.changeDiffHtml({ kind: "edit", old: "<b>old</b>", new: "<i>new</i>", cut: false, all: false });
check("every line is escaped (no tag from the change reaches innerHTML)",
      h.indexOf("<b>") < 0 && h.indexOf("<i>") < 0 && h.indexOf("&lt;b&gt;old&lt;/b&gt;") >= 0 && h.indexOf("&lt;i&gt;new&lt;/i&gt;") >= 0);
check("a removed line and an added line are marked apart", h.indexOf('class="dc-del"') >= 0 && h.indexOf('class="dc-add"') >= 0);
const w = api.changeDiffHtml({ kind: "write", new: "line one\nline two", cut: false });
check("a Write shows its whole new file as added lines, nothing removed",
      (w.match(/class="dc-add"/g) || []).length === 2 && w.indexOf('class="dc-del"') < 0);
const m = api.changeDiffHtml({ kind: "multi", n: 3, edits: [{ old: "a", new: "b" }, { old: "c", new: "d" }], cut: true });
check("a MultiEdit shows each edit under its own heading", m.indexOf("edit 1 of 3") >= 0 && m.indexOf("edit 2 of 3") >= 0);
check("a cut change says the card doesn't show all of it", m.indexOf("not all of it is shown") >= 0);
const all = api.changeDiffHtml({ kind: "edit", old: "foo", new: "bar", cut: false, all: true });
check("a replace-all edit says it changes every occurrence", all.indexOf("every occurrence") >= 0);
eq("no change, nothing drawn", api.changeDiffHtml(null), "");
eq("an unknown kind, nothing drawn", api.changeDiffHtml({ kind: "other" }), "");

// ---- the wiring: the Activity tab draws it under Wants, only for a pending change ----
check("the Activity tab has a change box right under Wants",
      src.indexOf('<div id="d-pending"></div>\n      <div id="d-change"></div>') >= 0);
check("renderDetail draws it from it.pending.change through changeDiffHtml",
      src.indexOf("renderChange(it);") >= 0 && src.indexOf("ch.innerHTML = changeDiffHtml(it.pending && it.pending.change);") >= 0);
check("the box is capped in height and scrolls", /#d-change \{[^}]*max-height:[^}]*overflow:auto/.test(src));

done();
