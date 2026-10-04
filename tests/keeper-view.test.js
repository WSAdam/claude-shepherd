// keeper-view.test.js - BEHAVIORAL fixture for the transcript keeper's panel side (2026-10-03,
// mining round 2 unit F3). Runs the REAL shipped functions sliced out of claude-dashboard.lua.
//
// Diagnostics shows Claude Code's cleanupPeriodDays with an offer to raise it: the row carries
// { offer: { id, label } } and renders a button whose id rides in a data- attribute (never inside
// the handler); a click sends doctor-offer with that id and can't be clicked twice. History marks a
// row whose transcript is kept (or only kept), offers "Remove kept copies" for an unstarred project
// that still has copies (never a starred one), and every ★ change goes to Lua (keep-pins), since
// the pins live in localStorage, which Lua can't read. A fleet-search hit in a kept copy says so.
//
// Usage: node tests/keeper-view.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("\n-- keeper-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const parts = {
  esc: slice("    function esc(s){", "\n    }\n"),
  doctorRowsHtml: slice("    function doctorRowsHtml(rows){", "\n    }\n"),
  doctorOffer: slice("    function doctorOffer(btn){", "\n    }\n"),
  historyKeepOffersHtml: slice("    function historyKeepOffersHtml(kept, pins){", "\n    }\n"),
  historyKeepRemove: slice("    function historyKeepRemove(btn){", "\n    }\n"),
  historyRow: slice("    function historyRow(r){", "\n    }\n"),
  syncKeepPins: slice("    function syncKeepPins(){", "\n    }\n"),
  setHistoryPin: slice("    function setHistoryPin(pk, on){", "\n    }\n"),
  fsKeptTag: slice("    function fsKeptTag(h){", "\n    }\n"),
  decodeProjectKey: slice("    function decodeProjectKey(pk){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("the panel ships " + k, parts[k] !== null);
if (Object.values(parts).some(p => p === null)) done();

let SENT = [], PINS = {}, RENDERS = 0;
const env = {
  send: (a, v, text) => SENT.push({ a: a, v: v || "", text: text || "" }),
  historyPins: () => PINS,
  fmtTs: ts => "t" + ts,
  renderHistory: () => { RENDERS++; },
  localStorage: { setItem: (k, v) => { PINS = JSON.parse(v); } },
};
const lib = new Function("send", "historyPins", "fmtTs", "renderHistory", "window",
  Object.values(parts).join("\n") +
  "\nreturn { doctorRowsHtml, doctorOffer, historyKeepOffersHtml, historyKeepRemove, historyRow, syncKeepPins, setHistoryPin, fsKeptTag };")(
  env.send, env.historyPins, env.fmtTs, env.renderHistory, { localStorage: env.localStorage });

const EVIL = "<img src=x onerror=alert(1)>";
const count = (s, needle) => s.split(needle).length - 1;
// a tiny button: what the click handler reads and changes
function button(attrs) {
  return { disabled: false, textContent: "", getAttribute: k => (k in attrs ? attrs[k] : null),
           closest: () => ({ getAttribute: k => (k in attrs ? attrs[k] : null) }) };
}

// ---- Diagnostics: the offer -------------------------------------------------------------------
let html = lib.doctorRowsHtml([
  { label: "Claude Code deletes transcripts after 30 days", status: "info", detail: "cleanupPeriodDays isn't set",
    offer: { id: "cleanup-days", label: "Keep transcripts 365 days" } },
  { label: "jq installed", status: "ok" },
]);
eq("a row with an offer renders one button", count(html, 'class="doc-offer"'), 1);
check("...labelled", html.indexOf(">Keep transcripts 365 days</button>") >= 0);
check("...its id in a data- attribute, read back by the handler (never inside it)",
      html.indexOf('data-offer="cleanup-days"') >= 0 && html.indexOf('onclick="doctorOffer(this)"') >= 0
      && html.indexOf("doctorOffer('cleanup") < 0);
check("...inside its own row", html.indexOf("after 30 days") < html.indexOf("doc-offer") && html.indexOf("doc-offer") < html.indexOf("jq installed"));
eq("a row with no offer has no button", count(lib.doctorRowsHtml([{ label: "jq installed", status: "ok" }]), "doc-offer"), 0);
html = lib.doctorRowsHtml([{ label: "x", status: "info", offer: { id: '"><script>1</script>', label: EVIL } }]);
check("a hostile offer label and id are escaped", html.indexOf(EVIL) < 0 && html.indexOf("<script>") < 0 && html.indexOf("&lt;img") >= 0);
eq("an offer with no id renders nothing", count(lib.doctorRowsHtml([{ label: "x", status: "info", offer: { label: "go" } }]), "doc-offer"), 0);

SENT = [];
const b = button({ "data-offer": "cleanup-days" });
lib.doctorOffer(b);
eq("a click sends doctor-offer with the row's id", JSON.stringify(SENT), JSON.stringify([{ a: "doctor-offer", v: "cleanup-days", text: "" }]));
check("...and the button can't be clicked twice", b.disabled === true && b.textContent !== "");
SENT = [];
lib.doctorOffer(button({}));
eq("a button with no id sends nothing", SENT.length, 0);

// ---- History: the pins reach Lua -----------------------------------------------------------------
SENT = []; PINS = { "-r-A": true };
lib.syncKeepPins();
eq("the pin set goes to Lua as a list", JSON.stringify(SENT), JSON.stringify([{ a: "keep-pins", v: "", text: '["-r-A"]' }]));
SENT = [];
lib.setHistoryPin("-r-B", true);
check("starring sends the new set", SENT.length === 1 && SENT[0].a === "keep-pins"
      && JSON.stringify(JSON.parse(SENT[0].text).sort()) === JSON.stringify(["-r-A", "-r-B"]));
SENT = [];
lib.setHistoryPin("-r-A", false);
check("...unstarring too", SENT.length === 1 && SENT[0].text === '["-r-B"]');
check("...and the list re-renders", RENDERS >= 2);

// ---- History: a row's kept copy -------------------------------------------------------------------
PINS = {};
html = lib.historyRow({ session_id: "s1", projectKey: "-r-A", name: "one", kept: true });
check("a row with a kept copy is marked", html.indexOf('class="h-kept"') >= 0 && html.indexOf("📦 kept") >= 0);
check("...not as the only copy", html.indexOf("kept copy only") < 0);
html = lib.historyRow({ session_id: "s1", projectKey: "-r-A", name: "one", kept: true, keptOnly: true });
check("a row whose original is gone says only the kept copy is left", html.indexOf("📦 kept copy only") >= 0);
eq("a row with no copy has no mark", count(lib.historyRow({ session_id: "s2", projectKey: "-r-A", name: "two" }), "h-kept"), 0);

// ---- History: unstarring offers to remove the kept copies -------------------------------------------
html = lib.historyKeepOffersHtml({ "-r-A": 3, "-r-B": 1, "-r-C": 0 }, { "-r-B": true });
eq("an offer for each unstarred project with copies, none for a starred one or one with none", count(html, 'class="h-keep-offer"'), 1);
check("...naming the project and the count", html.indexOf('data-pk="-r-A"') >= 0 && html.indexOf("3 kept") >= 0);
check("...with Remove", html.indexOf('onclick="historyKeepRemove(this)"') >= 0);
eq("no copies: no offers", lib.historyKeepOffersHtml({}, {}), "");
eq("no data yet: no offers", lib.historyKeepOffersHtml(null, {}), "");
html = lib.historyKeepOffersHtml({ ['"><img src=x onerror=alert(1)>']: 2 }, {});
check("a hostile project key is escaped", html.indexOf("<img") < 0);
SENT = [];
lib.historyKeepRemove(button({ "data-pk": "-r-A" }));
eq("Remove sends keep-remove with the project (Lua asks before removing)", JSON.stringify(SENT),
   JSON.stringify([{ a: "keep-remove", v: "-r-A", text: "" }]));

// ---- fleet search: a hit in a kept copy says so ------------------------------------------------------
check("a kept hit is tagged", lib.fsKeptTag({ kept: true }).indexOf("📦 kept") >= 0);
eq("...any other isn't", lib.fsKeptTag({ kept: false }) + lib.fsKeptTag({}) + lib.fsKeptTag(null), "");

done();
