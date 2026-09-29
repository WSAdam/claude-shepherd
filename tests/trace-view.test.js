// trace-view.test.js - BEHAVIORAL: the Automation trace's rows (2026-09-29).
//
// Build program unit 14. Runs the REAL shipped traceRowHtml + traceDryLine (and the panel's own esc)
// sliced out of claude-dashboard.lua (the done-order.test.js pattern), so there is no copy of the
// rendering to drift. Lua serves the rows newest first with repeats collapsed (core.collapseTrace);
// a row says when, acted / would / refused, which automation, which session, what it does and why it
// was refused, and ×N for a repeat. Session names, summaries and reasons came from a session or its
// queue, so every one goes through esc(). Also runs Settings' dry-run switches (ensure / fill / read
// DryRunForm) over a fake document: showSettings calls them, so a throw there would keep Settings shut.
//
// Usage: node tests/trace-view.test.js [path/to/claude-dashboard.lua]

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
const clockSrc = slice("    function traceClock(at){", "\n    }\n");
const rowSrc = slice("    function traceRowHtml(tr, kinds){", "\n    }\n");
const drySrc = slice("    function traceDryLine(dry, features){", "\n    }\n");
check("the panel ships esc", escSrc !== null);
check("the panel ships traceClock", clockSrc !== null);
check("the panel ships traceRowHtml", rowSrc !== null);
check("the panel ships traceDryLine", drySrc !== null);
if (!escSrc || !clockSrc || !rowSrc || !drySrc) {
  console.log("\n-- trace-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + clockSrc + "\n" + rowSrc + "\n" + drySrc
  + "\nreturn { esc: esc, traceClock: traceClock, traceRowHtml: traceRowHtml, traceDryLine: traceDryLine };")();

const kinds = { continue: "Auto-continue", feed: "Auto-feed" };
const at = new Date(2026, 8, 29, 14, 5, 9).getTime() / 1000;

// ---- one row ----
const would = lib.traceRowHtml({ at: at, kind: "continue", key: "s1", name: "api", outcome: "would", summary: "continue", count: 1 }, kinds);
check("a would row is marked would", would.indexOf('class="tr-row tr-would"') >= 0 && would.indexOf(">would<") >= 0);
check("...names the automation by its label", would.indexOf("Auto-continue") >= 0);
check("...and the session", would.indexOf(">api<") >= 0);
check("...and says when", would.indexOf("14:05:09") >= 0);
eq("a single decision has no ×N", would.indexOf("×"), -1);

const refused = lib.traceRowHtml({ at: at, kind: "feed", key: "s2", name: "web", outcome: "refused", reason: "working", summary: "feed 'x'" }, kinds);
check("a refused row is marked refused, with why", refused.indexOf("tr-refused") >= 0 && refused.indexOf("working") >= 0
      && refused.indexOf('class="tr-why"') >= 0);
const acted = lib.traceRowHtml({ at: at, kind: "feed", key: "s2", name: "web", outcome: "acted", summary: "feed 'x'" }, kinds);
check("an acted row is marked acted and has no why", acted.indexOf("tr-acted") >= 0 && acted.indexOf("tr-why") < 0);
check("an unknown outcome reads as acted (its class can't be smuggled)",
      lib.traceRowHtml({ at: at, kind: "feed", outcome: '"><b>x', summary: "" }, kinds).indexOf("tr-acted") >= 0);
check("an unknown kind shows its raw name", lib.traceRowHtml({ at: at, kind: "respawn", outcome: "acted" }, kinds).indexOf(">respawn<") >= 0);

// ---- repeats ----
const rep = lib.traceRowHtml({ at: at, first: at - 120, kind: "continue", key: "s1", name: "api", outcome: "would", summary: "continue", count: 7 }, kinds);
check("a repeat shows ×N", rep.indexOf("×7") >= 0);
check("...and since when", rep.indexOf("since 14:03:09") >= 0);
eq("a junk count is one", lib.traceRowHtml({ at: at, kind: "feed", outcome: "acted", count: "lots" }, kinds).indexOf("×"), -1);
eq("not a row", lib.traceRowHtml(null, kinds), "");

// ---- every field through esc() ----
const evil = "<img src=x onerror=alert(1)>";
const hostile = lib.traceRowHtml({ at: at, kind: evil, key: evil, name: evil, outcome: "refused", reason: evil, summary: evil, count: 2 }, {});
check("no field reaches the HTML raw", hostile.indexOf("<img") < 0);
check("...each is entity-encoded instead", hostile.split("&lt;img").length - 1 === 4);

// ---- the dry-run banner ----
eq("no dry run -> no banner", lib.traceDryLine({ on: false, all: false, features: [] }, {}), "");
eq("no state -> no banner", lib.traceDryLine(null, {}), "");
check("all automation", lib.traceDryLine({ on: true, all: true, features: [] }, {}).indexOf("all automation") >= 0);
eq("some features, by their labels",
   lib.traceDryLine({ on: true, all: false, features: ["rules", "mailbox"] }, { rules: "Automation rules", mailbox: "Mailbox messages" }),
   "Dry run is on for: Automation rules, Mailbox messages.");
check("an empty features map from Lua ({} not []) doesn't break it",
      typeof lib.traceDryLine({ on: true, all: false, features: {} }, {}) === "string");

// ---- Settings: the dry-run switches (the shipped ensure/fill/read, over a fake document) ----
// showSettings calls fillDryRunForm first thing after the queue box: if it threw, Settings wouldn't open.
const cvSrc = slice("    function cv(o, path, def){", "\n    }\n");
const ensureSrc = slice("    function ensureDryRunForm(){", "\n    }\n");
const fillSrc = slice("    function fillDryRunForm(cfg){", "\n    }\n");
const readSrc = slice("    function readDryRunForm(){", "\n    }\n");
check("the panel ships cv and the three dry-run form helpers", !!(cvSrc && ensureSrc && fillSrc && readSrc));
if (cvSrc && ensureSrc && fillSrc && readSrc) {
  const els = {};
  const list = { children: [], _h: "" };
  Object.defineProperty(list, "innerHTML", {
    get() { return this._h; },
    set(h) {
      this._h = h; this.children = [];
      h.replace(/id="([^"]+)"/g, (m, id) => { els[id] = { checked: false }; this.children.push(els[id]); return m; });
    },
  });
  els["s-dry-all"] = { checked: false };
  els["s-dry-list"] = list;
  const doc = { getElementById: (id) => els[id] || null };
  const features = [{ feature: "autoContinue", label: "Auto-continue" }, { feature: "queue", label: "Auto-feed <b>&</b> routing" },
                    { feature: "rules", label: "Automation rules" }];
  const form = new Function("document", "DRY_FEATURES", escSrc + "\n" + cvSrc + "\n" + ensureSrc + "\n" + fillSrc + "\n" + readSrc
    + "\nreturn { fill: fillDryRunForm, read: readDryRunForm };")(doc, features);
  form.fill({ automation: { dryRun: true }, rules: { dryRun: true }, queue: { dryRun: "true" } });
  eq("one switch per feature", list.children.length, 3);
  check("...each label escaped", list.innerHTML.indexOf("<b>") < 0 && list.innerHTML.indexOf("&lt;b&gt;") >= 0);
  check("the config's switches are shown: all, and rules", els["s-dry-all"].checked === true && els["s-dry-rules"].checked === true);
  check("...a feature that's off, or not a real true, is unticked",
        els["s-dry-autoContinue"].checked === false && els["s-dry-queue"].checked === false);
  els["s-dry-all"].checked = false; els["s-dry-queue"].checked = true;
  const sent = form.read();
  check("Save sends every switch as a boolean",
        sent.automation === false && sent.queue === true && sent.rules === true && sent.autoContinue === false
        && Object.keys(sent).length === 4);
  form.fill({});
  eq("filling again keeps the one list (no duplicate boxes)", list.children.length, 3);
  check("...and an empty config unticks everything",
        !els["s-dry-all"].checked && !els["s-dry-rules"].checked && !els["s-dry-queue"].checked);
}

console.log("\n-- trace-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
