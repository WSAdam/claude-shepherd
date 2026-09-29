// inbox-view.test.js - BEHAVIORAL: the fleet-wide Inbox (2026-09-29, build program unit 28).
//
// ☰ → Inbox lists every open cc-decide.sh question and every AskUserQuestion cc-ask.sh is
// holding, answerable in place. Questions, defaults, options and session names are a session's
// words, so every one goes through esc(). A click sends only what the row array holds (the
// question's id, or the held ask's key, and the option's text from the array) -- never text read
// back out of the markup. Runs the REAL shipped inboxRowsHtml / inboxAct sliced out of
// claude-dashboard.lua (the pins-view.test.js pattern).
//
// Usage: node tests/inbox-view.test.js [path/to/claude-dashboard.lua]

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
const rowsSrc = slice("    function inboxRowsHtml(rows){", "\n    }\n");
const actSrc = slice("    function inboxAct(ev){", "\n    }\n");
check("the panel ships inboxRowsHtml", rowsSrc !== null);
check("the panel ships inboxAct", actSrc !== null);
check("the panel has the Inbox view (id inbox)", src.indexOf('<div id="inbox">') >= 0);
check("☰ opens it", src.indexOf("menuPick('inbox')") >= 0);
if (!(escSrc && rowsSrc && actSrc)) {
  console.log("\n-- inbox-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const sent = [], selected = [];
const inputs = {};
const lib = new Function("sent", "selected", "inputs",
  "var INBOX = { rows: [] };\n" +
  "function send(a, v, text){ sent.push([a, v, text]); }\n" +
  "function selectTile(k){ selected.push(k); } function closeInbox(){}\n" +
  "function fmtAge(){ return '3m'; }\n" +
  "var document = { getElementById: function(id){ return inputs[id] || null; } };\n" +
  escSrc + "\n" + rowsSrc + "\n" + actSrc +
  "\nreturn { inboxRowsHtml, inboxAct, setRows: function(r){ INBOX.rows = r; } };")(sent, selected, inputs);

// ---- the rows ----
eq("no rows: says there is nothing waiting", /nothing/i.test(lib.inboxRowsHtml([])), true);
const EVIL = '<img src=x onerror="alert(1)">';
const rows = [
  { kind: "decide", id: "k1.1790000000-11", key: "k1", session: "alpha" + EVIL, project: "proj" + EVIL,
    question: "Which port?" + EVIL, default: "4100" + EVIL, options: ["4100" + EVIL, "4200"], blocking: true,
    asked: 1790000000 },
  { kind: "ask", key: "k5", session: "gamma", project: "proj-c", question: "Pick a colour", options: ["red", "blue"],
    simple: true, asked: 1790000000 },
  { kind: "ask", key: "k6", session: "delta", project: "proj-d", question: "Two parts", options: ["x"],
    simple: false, count: 2, asked: 1790000000 },
  { kind: "decide", id: "k2.1790000000-12", key: "k2", session: "beta", project: "proj-b",
    question: "Tabs or spaces?", default: "spaces", options: [], blocking: false, asked: 1790000000 },
];
const h = lib.inboxRowsHtml(rows);
eq("every field is escaped: no raw tag from a session reaches the markup", h.indexOf("<img") < 0, true);
eq("...its text is still there, escaped", h.indexOf("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;") >= 0, true);
eq("one row per item", (h.match(/class="ib-row/g) || []).length, 4);
eq("a blocking question is marked as holding its session", /ib-row[^"]*blocking/.test(h), true);
eq("its default is marked among its options", /ib-opt[^"]*def/.test(h), true);
eq("a question offers Keep the default", /data-act="keep"/.test(h), true);
eq("a question with no options still takes free text", (h.match(/class="ib-text"/g) || []).length >= 2, true);
eq("a held ask that needs its full form offers Open instead of buttons", /data-act="open"/.test(h), true);
eq("buttons carry only row and option numbers, never the text", /data-v=|data-answer=/.test(h), false);

// ---- the clicks: values come from the row array, not the markup ----
lib.setRows(rows);
function btn(attrs) {
  const b = { getAttribute: (k) => (k in attrs ? String(attrs[k]) : null) };
  b.closest = () => b;
  return { target: b, stopPropagation() {} };
}
lib.inboxAct(btn({ "data-i": 0, "data-o": 1 }));
eq("an option answers the question by its id, with the option's own text",
   JSON.stringify(sent.pop()), JSON.stringify(["decide-answer", "k1.1790000000-11", "4200"]));
lib.inboxAct(btn({ "data-i": 0, "data-act": "keep" }));
eq("Keep answers with the default", JSON.stringify(sent.pop()),
   JSON.stringify(["decide-answer", "k1.1790000000-11", "4100" + EVIL]));
inputs["ib-text-3"] = { value: "  tabs, actually  " };
lib.inboxAct(btn({ "data-i": 3, "data-act": "send" }));
eq("free text is sent trimmed", JSON.stringify(sent.pop()), JSON.stringify(["decide-answer", "k2.1790000000-12", "tabs, actually"]));
inputs["ib-text-3"] = { value: "   " };
lib.inboxAct(btn({ "data-i": 3, "data-act": "send" }));
eq("...empty free text sends nothing", sent.length, 0);
lib.inboxAct(btn({ "data-i": 1, "data-o": 1 }));
const a = sent.pop() || [];
eq("a held ask's option answers it through the card's own path (answer-ask, its key)", a[0] + "|" + a[1], "answer-ask|k5");
eq("...with the picks the card's form would send", a[2], JSON.stringify([{ labels: ["blue"], other: "" }]));
inputs["ib-text-1"] = { value: "green" };
lib.inboxAct(btn({ "data-i": 1, "data-act": "send" }));
eq("...and free text as its Other", (sent.pop() || [])[2], JSON.stringify([{ labels: [], other: "green" }]));
lib.inboxAct(btn({ "data-i": 2, "data-act": "open" }));
eq("Open selects that session's card, where its full form is", selected.pop(), "k6");
eq("...and sends nothing", sent.length, 0);
lib.inboxAct(btn({ "data-i": 9, "data-o": 0 }));
eq("a row that isn't there sends nothing", sent.length, 0);
lib.inboxAct(btn({ "data-i": 0, "data-o": 7 }));
eq("an option that isn't there sends nothing", sent.length, 0);

console.log("\n-- inbox-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
