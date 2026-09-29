// onpurpose-view.test.js - BEHAVIORAL: the "On purpose" detail tab (2026-09-29, build program
// unit 33).
//
// The tab shows the repo's DECISIONS.md -- each entry's what, why and date -- and a form that adds
// one. Everything in the file is someone's text, so every field goes through esc(). With no file
// yet the tab says adding creates it; outside a repo it says there's nothing to show. The form's
// draft survives a repaint. Runs the REAL shipped onPurposeHtml sliced out of claude-dashboard.lua
// (the pins-view.test.js pattern).
//
// Usage: node tests/onpurpose-view.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const escSrc = slice("    function esc(s){", "\n    }\n");
const htmlSrc = slice("    function onPurposeHtml(d, flash, draft){", "\n    }\n");
check("the panel ships onPurposeHtml", htmlSrc !== null);
if (!(escSrc && htmlSrc)) {
  console.log("\n-- onpurpose-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + htmlSrc + "\nreturn { onPurposeHtml };")();
const H = lib.onPurposeHtml;

check("loading: says so", H(null, null, null).indexOf("Loading") >= 0);
const norepo = H({ norepo: true }, null, null);
check("outside a repo: says DECISIONS.md lives at a repo's root", norepo.indexOf("repo") >= 0);
check("...and offers no form", norepo.indexOf('id="op-what"') < 0);

const fresh = H({ exists: false, path: "/r/proj/DECISIONS.md", hash: "absent", entries: [] }, null, null);
check("no file yet: says adding the first entry creates it", /creates? it/.test(fresh));
check("...names where", fresh.indexOf("/r/proj/DECISIONS.md") >= 0);
check("...and offers the form: what, why, date, Add",
  fresh.indexOf('id="op-what"') >= 0 && fresh.indexOf('id="op-why"') >= 0 && fresh.indexOf('id="op-date"') >= 0
  && fresh.indexOf("onPurposeAdd()") >= 0);

const d = { exists: true, path: "/r/proj/DECISIONS.md", hash: "0badf00d", entries: [
  { what: "Tests shell out to the real make", why: "they prove the Makefile", date: "2026-09-29" },
  { what: "No hs.alert.show", why: "", date: "", notes: "Callers go through FX.alert." } ] };
const h = H(d, null, null);
check("one row per entry", (h.match(/class="op-row"/g) || []).length === 2);
check("...its what, why and date", h.indexOf("Tests shell out to the real make") >= 0
  && h.indexOf("they prove the Makefile") >= 0 && h.indexOf("2026-09-29") >= 0);
check("...and its notes", h.indexOf("Callers go through FX.alert.") >= 0);
check("a Reload button", h.indexOf("onPurposeReload()") >= 0);

const evil = H({ exists: true, path: '/r/<b>x</b>/DECISIONS.md', hash: "1", entries: [
  { what: "<script>alert(1)</script>", why: '"><img src=x onerror=alert(2)>', date: "<i>d</i>", notes: "<u>n</u>" } ] },
  "<b>flash</b>", { what: '"><svg onload=alert(3)>', why: "</textarea><script>alert(4)</script>", date: '"><x' });
check("a what with markup is escaped", evil.indexOf("<script>alert(1)") < 0 && evil.indexOf("&lt;script&gt;alert(1)") >= 0);
check("a why with markup is escaped", evil.indexOf("<img") < 0);
check("a date, the notes, the path and the flash are escaped",
  evil.indexOf("<i>d</i>") < 0 && evil.indexOf("<u>n</u>") < 0 && evil.indexOf("<b>x</b>") < 0 && evil.indexOf("<b>flash</b>") < 0);
check("the draft can't leave its input or textarea",
  evil.indexOf("<svg") < 0 && evil.indexOf("</textarea><script>") < 0 && evil.indexOf('value=""><x') < 0);

const kept = H(d, "⚠ Not added: changed", { what: "half-typed", why: "because", date: "2026-01-02" });
check("a repaint keeps the draft's what", kept.indexOf('value="half-typed"') >= 0);
check("...its why", kept.indexOf(">because</textarea>") >= 0);
check("...and its date", kept.indexOf('value="2026-01-02"') >= 0);
check("the flash shows", kept.indexOf("Not added: changed") >= 0);

const raw = H({ exists: true, path: "/r/p/DECISIONS.md", hash: "2", entries: [], preview: "free <form> text" }, null, null);
check("a file with no ## entries shows its text, escaped", raw.indexOf("free &lt;form&gt; text") >= 0 && raw.indexOf("<form>") < 0);

console.log("\n-- onpurpose-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
