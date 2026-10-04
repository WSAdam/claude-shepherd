// past-sessions-view.test.js - BEHAVIORAL fixture for History's past sessions (2026-10-04, mining
// round 2 unit F2). Runs the REAL shipped functions sliced out of claude-dashboard.lua.
//
// A History row now carries what its transcript says (r.past: first prompt, AI title, size), and a
// session the ledger never saw is a row of its own. Each row offers 🔮 Ask (Seance) and ↻ Resume:
// Resume only where Lua said it can (r.canResume -- an ended session with a transcript or a kept
// copy), never on a live one (● live) or one whose transcript is gone (transcript gone, and no Ask
// either: there's nothing to ask). Resume sends past-resume with the row's session id and project
// key read from data- attributes (never inside the handler), and can't be clicked twice. Every word
// from a transcript goes in through esc().
//
// Usage: node tests/past-sessions-view.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("\n-- past-sessions-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

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
  decodeProjectKey: slice("    function decodeProjectKey(pk){", "\n    }\n"),
  historyRow: slice("    function historyRow(r){", "\n    }\n"),
  historyHay: slice("    function historyHay(r){", "\n    }\n"),
  historyInfoText: slice("    function historyInfoText(n, scanning){", "\n    }\n"),
  historyResume: slice("    function historyResume(ev, btn){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("the panel ships " + k, parts[k] !== null);
if (Object.values(parts).some(p => p === null)) done();

let SENT = [];
const lib = new Function("send", "historyPins", "fmtTs",
  Object.values(parts).join("\n") + "\nreturn { historyRow, historyHay, historyInfoText, historyResume };")(
  (a, v, text) => SENT.push({ a: a, v: v || "", text: text || "" }), () => ({}), ts => "t" + ts);

const EVIL = "<img src=x onerror=alert(1)>";
const count = (s, needle) => s.split(needle).length - 1;
const PK = "-Users-adam-Programming-repo";
const SID = "913fcf84-2494-4bed-ade2-c31543c16c04";

// ---- a row with its transcript's facts ----------------------------------------------------------
let html = lib.historyRow({ session_id: SID, projectKey: PK, lastTs: 5, canResume: true, transcriptOnly: true,
  past: { prompt: "Start unit feat/past-sessions", title: "Past sessions browser", sizeHuman: "688 KB" } });
check("a transcript-only row is named by its AI title", html.indexOf(">Past sessions browser<") >= 0);
check("...shows its first prompt", html.indexOf("Start unit feat/past-sessions") >= 0);
check("...and its transcript's size instead of ledger counts", html.indexOf("688 KB") >= 0 && html.indexOf("turns") < 0);
eq("...offers Resume", count(html, 'class="h-resume"'), 1);
check("...whose handler reads the row's data- attributes (never the id inside it)",
      html.indexOf('onclick="historyResume(event, this)"') >= 0 && html.indexOf("historyResume(event, this, '") < 0
      && html.indexOf('data-sid="' + SID + '"') >= 0 && html.indexOf('data-pk="' + PK + '"') >= 0);
eq("...and Ask (Seance)", count(html, 'class="h-ask"'), 1);

html = lib.historyRow({ session_id: SID, projectKey: PK, name: "repo-ea", lastTs: 5, prompts: 3, toolRequests: 4, events: 9,
  canResume: true, past: { prompt: "fix it", title: "Fixing", sizeHuman: "2.0 KB" } });
check("a ledger row keeps its name and counts", html.indexOf(">repo-ea<") >= 0 && html.indexOf("3 turns") >= 0);
check("...and gains the prompt and size", html.indexOf("fix it") >= 0 && html.indexOf("2.0 KB") >= 0);
html = lib.historyRow({ session_id: SID, projectKey: PK, lastTs: 5, canResume: true, transcriptOnly: true, past: { prompt: "only a prompt" } });
check("no title: the prompt names it", html.indexOf(">only a prompt<") >= 0);

// ---- live, gone ---------------------------------------------------------------------------------
html = lib.historyRow({ session_id: SID, projectKey: PK, lastTs: 5, live: true, past: { prompt: "p" } });
eq("a live session has no Resume", count(html, "h-resume"), 0);
check("...it says live", html.indexOf('class="h-live"') >= 0);
html = lib.historyRow({ session_id: SID, projectKey: PK, name: "old", lastTs: 5, noTranscript: true });
eq("a session whose transcript is gone has no Resume", count(html, "h-resume"), 0);
eq("...and no Ask (nothing left to ask)", count(html, "h-ask"), 0);
check("...it says so", html.indexOf('class="h-gone"') >= 0 && html.indexOf("transcript gone") >= 0);
html = lib.historyRow({ session_id: SID, projectKey: PK, name: "plain", lastTs: 5 });
eq("a ledger row before the scan lands: no Resume yet", count(html, "h-resume"), 0);
check("...but Ask as before", count(html, "h-ask") === 1);
html = lib.historyRow({ session_id: SID, projectKey: PK, lastTs: 5, canResume: true, kept: true, keptOnly: true, past: { prompt: "kept" } });
check("a kept-only row resumes (its copy goes back first) and says so",
      count(html, "h-resume") === 1 && html.indexOf("kept copy only") >= 0 && /h-resume[^>]*title="[^"]*kept copy/.test(html));

// ---- every transcript word escaped ----------------------------------------------------------------
html = lib.historyRow({ session_id: '"><script>x</script>', projectKey: '"><b>', lastTs: 5, canResume: true, transcriptOnly: true,
  past: { prompt: EVIL, title: EVIL, sizeHuman: EVIL } });
check("a hostile prompt, title, size and ids are escaped",
      html.indexOf("<img") < 0 && html.indexOf("<script>") < 0 && html.indexOf("<b>") < 0 && html.indexOf("&lt;img") >= 0);

// ---- the filter reads the prompt and title too ----------------------------------------------------
const hay = lib.historyHay({ name: "repo-ea", projectKey: PK, past: { prompt: "Start unit feat/X", title: "Browser" } });
check("the filter matches the prompt", hay.indexOf("start unit feat/x") >= 0);
check("...the title", hay.indexOf("browser") >= 0);
check("...the name and folder as before", hay.indexOf("repo-ea") >= 0 && hay.indexOf("programming/repo") >= 0);
eq("a row with nothing is an empty haystack", lib.historyHay({}).trim(), "");

// ---- the count line while the scan runs ------------------------------------------------------------
eq("the count line", lib.historyInfoText(3, false), "3 session(s)");
check("...says when transcripts are still being read", lib.historyInfoText(3, true).indexOf("reading") >= 0);

// ---- Resume's click ---------------------------------------------------------------------------------
function button(attrs) {
  const row = { getAttribute: k => (k in attrs ? attrs[k] : null) };
  return { disabled: false, textContent: "↻ Resume", closest: () => row };
}
SENT = [];
let stopped = false;
const b = button({ "data-sid": SID, "data-pk": PK });
lib.historyResume({ stopPropagation: () => { stopped = true; } }, b);
eq("Resume sends past-resume with the row's session and project", JSON.stringify(SENT),
   JSON.stringify([{ a: "past-resume", v: "", text: JSON.stringify({ sessionId: SID, projectKey: PK }) }]));
check("...stops the click reaching the row", stopped);
check("...and can't be clicked twice", b.disabled === true && b.textContent !== "↻ Resume");
SENT = [];
lib.historyResume(null, button({}));
eq("a row with no session sends nothing", SENT.length, 0);

done();
