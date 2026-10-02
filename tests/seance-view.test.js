// seance-view.test.js - BEHAVIORAL fixture for Seance's box (2026-10-02, mining round 2 unit D1).
// Runs the REAL shipped seanceText and seanceBoxHtml: they are sliced straight out of
// claude-dashboard.lua, so there is no copy of the wording or the escaping to drift.
//
// "Ask this session" sits in the detail panel and opens under a fleet-search hit or a History row.
// The answer is a model's words and the question is Adam's, both shown with innerHTML, so every one
// of them goes through esc(); the box's session id, card key, file and project key ride in data-
// attributes (never inside an inline handler), read back with getAttribute.
//
// Usage: node tests/seance-view.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function done() { console.log("-- seance-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const escSrc = slice("    function esc(s){", "\n    }\n");
const textSrc = slice("    function seanceText(r){", "\n    }\n");
const boxSrc = slice("    function seanceBoxHtml(o){", "\n    }\n");
check("esc is in the panel source", !!escSrc);
check("the shipped seanceText is in the panel source", !!textSrc);
check("the shipped seanceBoxHtml is in the panel source", !!boxSrc);
if (!escSrc || !textSrc || !boxSrc) done();
const lib = new Function(escSrc + textSrc + boxSrc + "\nreturn { seanceText: seanceText, seanceBoxHtml: seanceBoxHtml };")();
const { seanceText, seanceBoxHtml } = lib;

const EVIL = "<img src=x onerror=alert(1)>";

check("no record: nothing shows", seanceText(null) === "" && seanceText({}) === "");

let h = seanceText({ sid: "s1", state: "running", question: "What did you " + EVIL + "?", model: "claude-opus-5-5[1m]" });
check("running: says it's asking, in which model  (" + h + ")", h.indexOf("Asking") >= 0 && h.indexOf("claude-opus-5-5[1m]") >= 0);
check("...and shows the question, escaped", h.indexOf("&lt;img src=x onerror=alert(1)&gt;") >= 0 && h.indexOf(EVIL) < 0);

h = seanceText({ sid: "s1", state: "done", outcome: "answered", question: "q?", answer: "I renamed it.\n" + EVIL,
                 costUsd: 0.04, secs: 12, model: "sonnet" });
check("answered: the answer shows  (" + h + ")", h.indexOf("I renamed it.") >= 0);
check("...escaped: a model's words are text, never markup", h.indexOf(EVIL) < 0 && h.indexOf("&lt;img") >= 0);
check("...with what it cost and how long it took", h.indexOf("$0.04") >= 0 && h.indexOf("12s") >= 0);
check("...styled as an answer", h.indexOf('class="sn-a"') >= 0);

h = seanceText({ sid: "s2", state: "done", outcome: "couldntRun", question: "q?", why: "claude gave no answer (exit 1): " + EVIL });
check("couldn't run: says why  (" + h + ")", h.indexOf("Couldn't ask") >= 0 && h.indexOf("claude gave no answer (exit 1)") >= 0);
check("...escaped too", h.indexOf(EVIL) < 0);
check("...styled as an error", h.indexOf('class="sn-err"') >= 0);

h = seanceText({ sid: "s2", state: "queued", question: "q?" });
check("queued: says it's waiting", h.indexOf("Asking") >= 0);

const box = seanceBoxHtml({ sid: 'a"b', key: "k'1", file: "/p/<x>.jsonl", pk: "-r-A" });
check("the box carries the session in data- attributes, escaped  (" + box.slice(0, 160) + "…)",
  box.indexOf('data-sid="a&quot;b"') >= 0 && box.indexOf('data-key="k&#39;1"') >= 0
  && box.indexOf('data-file="/p/&lt;x&gt;.jsonl"') >= 0 && box.indexOf('data-pk="-r-A"') >= 0);
check("...its handlers name no session (they read the data- attributes back)",
  box.indexOf("seanceAsk(this)") >= 0 && box.indexOf("a\"b") < 0 && box.indexOf("k'1") < 0);
check("...a question input and an Ask button", box.indexOf('class="sn-in"') >= 0 && box.indexOf('class="sn-go"') >= 0);
check("...and a place for the answer", box.indexOf('class="sn-out"') >= 0);
check("...it says it's read-only", /read-only/i.test(box));

done();
