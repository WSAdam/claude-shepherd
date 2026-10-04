// queue-view.test.js - BEHAVIORAL: held queue lines and the fleet-wide Queue view (2026-10-03,
// mining round 2 unit D4b).
//
// ☰ → 📑 Queues lists every ~/.claude/cc-queue/*.json (core.queueViewRows): whose queue it is, each
// line held or not, the line that feeds next, and an @packet line's last drift check. Each line has
// Hold / Release, ▲ ▼ and ✕ (which asks first). The detail panel's queue editor gains the same
// Hold / Release per line. Every word came from a session or its queue, so each goes through esc();
// a click sends only what the row arrays hold (the queue file's key, the line's number and its text
// as the stale-list guard) -- never text read back out of the markup. Runs the REAL shipped
// functions sliced out of claude-dashboard.lua (the tickets-view.test.js pattern).
//
// Usage: node tests/queue-view.test.js [path/to/claude-dashboard.lua]

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
const opsSrc = slice("    var QV_OPS = ", ";\n");
const pkSrc = slice("    var QV_PK = ", ";\n");
const tipsSrc = (slice("    var QV_HOLD_TIP = ", ";\n") || "") + "\n" + (slice("    var QV_RELEASE_TIP = ", ";\n") || "");
const viewSrc = slice("    function queueViewHtml(rows){", "\n    }\n");
const actSrc = slice("    function queueViewAct(ev){", "\n    }\n");
const listSrc = slice("    function queueListRowsHtml(ql){", "\n    }\n");
const holdSrc = slice("    function queueHold(i){", "\n    }\n");
check("the panel ships queueViewHtml and queueViewAct", viewSrc !== null && actSrc !== null && opsSrc !== null && pkSrc !== null);
check("the panel ships the editor's queueListRowsHtml and queueHold", listSrc !== null && holdSrc !== null);
check("the panel ships the Hold / Release wording", tipsSrc.indexOf("var QV_HOLD_TIP") >= 0 && tipsSrc.indexOf("var QV_RELEASE_TIP") >= 0);
check("the card's meta says how many queued lines are held", src.indexOf('(it.queueHeld ? " (" + Number(it.queueHeld) + " held)" : "")') >= 0);
check("the panel has the Queues view (id queues)", src.indexOf('<div id="queues">') >= 0);
check("☰ opens it", src.indexOf("menuPick('queues')") >= 0 && src.indexOf('else if(which === "queues") openQueueView();') >= 0);
check("the editor renders through queueListRowsHtml", src.indexOf("box.innerHTML = queueListRowsHtml(QUEUE_LIST);") >= 0);
check("the Queues view tells Lua it opened and closed", src.indexOf('send("queues-open");') >= 0 && src.indexOf('send("queues-close");') >= 0);
if (!(escSrc && opsSrc && pkSrc && viewSrc && actSrc && listSrc && holdSrc)) {
  console.log("\n-- queue-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const sent = [];
const asked = [];
let answer = true;
const opened = [];
const lib = new Function("sent", "asked", "getAnswer", "opened",
  "var QUEUES = { rows: [] }; var QUEUE_LIST = { key: null, tasks: [], held: [] }; var selectedKey = 'sel-1';\n" +
  "function send(a, v, text){ sent.push([a, v, text]); }\n" +
  "function confirm(m){ asked.push(m); return getAnswer(); }\n" +
  "function fmtAge(since){ return String(Math.floor(Date.now()/1000) - since) + 's'; }\n" +
  "function closeQueueView(){ opened.push('closed'); }\n" +
  "function selectTile(k){ opened.push(k); }\n" +
  escSrc + "\n" + opsSrc + "\n" + pkSrc + "\n" + tipsSrc + "\n" + viewSrc + "\n" + actSrc + "\n" + listSrc + "\n" + holdSrc +
  "\nreturn { queueViewHtml, queueViewAct, queueListRowsHtml, queueHold," +
  " setRows: function(r){ QUEUES.rows = r; }, setList: function(l){ QUEUE_LIST = l; } };")(sent, asked, () => answer, opened);

// ---- the view's rows ----
check("no queued lines: says so", /No queued lines/.test(lib.queueViewHtml([])));
const EVIL = '<img src=x onerror="alert(1)">';
const rows = [
  { qk: "-Users-adam-Programming-alpha", project: "alpha" + EVIL,
    sessions: [{ key: "s1", name: "one" + EVIL }, { key: "s2", name: "two" }],
    lines: [
      { text: "first" + EVIL, held: true },
      { text: "@packet:p2 Fix" + EVIL, held: false,
        packet: { id: "p2", state: "moved", why: "cited code moved: src/a" + EVIL, head: "abc1234", age: 30 } },
      { text: "third", held: false, packet: { id: "p9", state: "<script>", why: "odd" } },
    ], held: 1, next: 2, routed: true },
  { qk: "-Users-adam-Programming-gone", project: "gone", sessions: [], lines: [{ text: "orphan", held: false }], held: 0, next: 1 },
  { qk: "-Users-adam-Programming-torn", project: "torn", sessions: [], lines: [], held: 0, unreadable: true },
];
const html = lib.queueViewHtml(rows);
check("no session or queue word reaches the markup raw", html.indexOf("<img") < 0 && html.indexOf("<script") < 0);
check("...each is shown escaped: project, session, line text, packet why", (html.match(/&lt;img/g) || []).length >= 6);
check("a held line says HOLD", /qv-line held/.test(html) && />HOLD</.test(html));
check("...and offers Release", />Release<\/button>/.test(html));
check("a line that isn't held offers Hold, with the hold wording", />Hold<\/button>/.test(html) && /until you release it/.test(html));
check("the line that feeds next is marked", (html.match(/qv-next/g) || []).length === 2);
check("an @packet line shows its last drift check, at its commit", /qv-pk qv-pk-moved/.test(html) && /at abc1234/.test(html));
check("an unknown packet state falls back to a known class", html.indexOf("qv-pk-<") < 0 && /qv-pk qv-pk-unchecked/.test(html));
check("routing shows", /routed/.test(html));
check("a queue no live session has says so", /no live session/.test(html));
check("an unreadable queue file says so, with no line buttons", /couldn.t be read/.test(html)
      && html.split('data-row="2"')[1].indexOf("data-act=") < 0);
check("the first line's ▲ is disabled, the last line's ▼ is disabled",
      /data-r="0" data-l="0" data-act="up" disabled/.test(html) && /data-r="0" data-l="2" data-act="down" disabled/.test(html));
check("✕ is there for every line", (html.match(/data-act="remove"/g) || []).length === 4);

// ---- a click sends only what the row array holds ----
lib.setRows(rows);
function click(r, l, act, s) {
  const el = { getAttribute: (k) => (k === "data-r" ? String(r) : k === "data-l" ? (l == null ? null : String(l))
    : k === "data-act" ? act : k === "data-s" ? (s == null ? null : String(s)) : null) };
  lib.queueViewAct({ stopPropagation() {}, target: { closest: () => el } });
}
click(0, 0, "release");
eq("Release sends the queue's key, the line's number and its text",
   JSON.stringify(sent.pop()), JSON.stringify(["queue-view-edit", "-Users-adam-Programming-alpha",
     JSON.stringify({ op: "release", idx: 1, task: "first" + EVIL })]));
click(0, 1, "hold");
eq("Hold the same way", JSON.parse(sent.pop()[2]).op, "hold");
click(0, 1, "up");
eq("▲", JSON.parse(sent.pop()[2]).op, "up");
click(1, 0, "down");
eq("▼ on another queue sends that queue's key", sent.pop()[1], "-Users-adam-Programming-gone");
answer = false;
click(0, 2, "remove");
eq("✕ asks first; No sends nothing", sent.length, 0);
check("...the question names the line", asked.length === 1 && asked[0].indexOf("third") >= 0);
answer = true;
click(0, 2, "remove");
eq("...Yes removes it", JSON.parse(sent.pop()[2]).op, "remove");
click(0, 0, "explode");
eq("an action that isn't one sends nothing", sent.length, 0);
click(9, 0, "hold");
click(0, 9, "hold");
eq("a row or line that isn't there sends nothing", sent.length, 0);
click(0, null, "open", 1);
eq("a session's name opens its card", opened.join(","), "closed,s2");
eq("...and sends nothing", sent.length, 0);

// ---- the detail panel's queue editor: Hold / Release per line ----
const EL = lib.queueListRowsHtml({ key: "sel-1", tasks: ["a" + EVIL, "b"], held: [true, false] });
check("editor: escaped", EL.indexOf("<img") < 0 && EL.indexOf("&lt;img") >= 0);
check("editor: a held line says HOLD and offers Release", /ql-row held/.test(EL) && />Release<\/button>/.test(EL));
check("editor: a line that isn't held offers Hold", />Hold<\/button>/.test(EL));
check("editor: an old list with no held array reads every line as not held",
      lib.queueListRowsHtml({ key: "sel-1", tasks: ["x"] }).indexOf(">Hold</button>") >= 0);
lib.setList({ key: "sel-1", tasks: ["a" + EVIL, "b"], held: [true, false] });
lib.queueHold(0);
eq("editor: Release sends the line's number, its text and the new state",
   JSON.stringify(sent.pop()), JSON.stringify(["queue-hold", "sel-1", JSON.stringify({ idx: 1, task: "a" + EVIL, held: false })]));
lib.queueHold(1);
eq("editor: Hold the same way", JSON.parse(sent.pop()[2]).held, true);
lib.queueHold(7);
eq("editor: a line that isn't there sends nothing", sent.length, 0);

console.log("\n-- queue-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
