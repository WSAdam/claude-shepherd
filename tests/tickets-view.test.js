// tickets-view.test.js - BEHAVIORAL: the Tickets board and the card's ticket badge (2026-09-29,
// build program unit 29).
//
// ☰ → 🎫 Tickets lists every cross-repo ticket (core.ticketRows), the ones no session can take first,
// with "Open a tab for it"; a card whose repo has such tickets carries a 🎫 badge with the same
// button. Titles, bodies, replies, notes, names and ids come from sessions, so every one goes
// through esc(). A click sends only what the row array holds (the ticket's id) or the card's key --
// never text read back out of the markup. Runs the REAL shipped ticketRowsHtml / ticketAct /
// ticketBadge / ticketTabCard sliced out of claude-dashboard.lua (the inbox-view.test.js pattern).
//
// Usage: node tests/tickets-view.test.js [path/to/claude-dashboard.lua]

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
const rowsSrc = slice("    function ticketRowsHtml(rows){", "\n    }\n");
const actSrc = slice("    function ticketAct(ev){", "\n    }\n");
const badgeSrc = slice("    function ticketBadge(it){", "\n    }\n");
const cardSrc = slice("    function ticketTabCard(ev){", "\n    }\n");
const phasesSrc = slice("    var TK_PHASES = ", ";\n");
check("the panel ships ticketRowsHtml", rowsSrc !== null);
check("the panel ships ticketAct", actSrc !== null);
check("the panel ships ticketBadge and ticketTabCard", badgeSrc !== null && cardSrc !== null);
check("the panel has the Tickets board (id tickets)", src.indexOf('<div id="tickets">') >= 0);
check("☰ opens it", src.indexOf("menuPick('tickets')") >= 0 && src.indexOf('else if(which === "tickets") openTickets();') >= 0);
check("the card's badges row carries the ticket badge", src.indexOf("b += ticketBadge(it);") >= 0);
if (!(escSrc && rowsSrc && actSrc && badgeSrc && cardSrc && phasesSrc)) {
  console.log("\n-- tickets-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const sent = [];
const lib = new Function("sent",
  "var TICKETS = { rows: [] }; var selectedKey = null;\n" +
  "function send(a, v, text){ sent.push([a, v, text]); }\n" +
  "function fmtAge(){ return '3m'; }\n" +
  escSrc + "\n" + phasesSrc + "\n" + rowsSrc + "\n" + actSrc + "\n" + badgeSrc + "\n" + cardSrc +
  "\nreturn { ticketRowsHtml, ticketAct, ticketBadge, ticketTabCard, setRows: function(r){ TICKETS.rows = r; } };")(sent);

// ---- the board's rows ----
eq("no tickets: says so, and how they're filed", /cc-ticket\.sh/.test(lib.ticketRowsHtml([])), true);
const EVIL = '<img src=x onerror="alert(1)">';
const rows = [
  { id: "t1790000000-1", title: "Bump the parser" + EVIL, body: "alpha needs 2.x" + EVIL, from: "filer" + EVIL,
    fromRepo: "alpha" + EVIL, to: "gamma" + EVIL, toRoot: "/r/gamma", phase: "waiting", filed: 1790000000,
    replies: 0, canTab: true },
  { id: "t1790000000-2", title: "Offered", from: "f1", fromRepo: "alpha", to: "beta", phase: "offered",
    holder: "worker" + EVIL, route: "waiting", filed: 1790000000, replies: 2,
    last: { by: "the filer" + EVIL, text: "any news?" + EVIL }, canTab: false },
  { id: "t1790000000-3", title: "Done", from: "f1", fromRepo: "alpha", to: "beta", phase: "closed",
    holder: "worker", note: "Tagged v2.1.0" + EVIL, filed: 1790000000, replies: 1, canTab: false },
  { id: "t1790000000-4" + EVIL, title: "Weird phase", from: "f1", fromRepo: "alpha", to: "beta",
    phase: "<script>" , filed: 1790000000, replies: 0, canTab: false },
];
const html = lib.ticketRowsHtml(rows);
check("no session word reaches the markup raw", html.indexOf("<img") < 0 && html.indexOf("<script") < 0);
check("...each is shown escaped: title, body, names, repos, the reply, the note",
      (html.match(/&lt;img/g) || []).length >= 9);
check("a ticket nobody can take says so, with Open a tab for it", /no session there can take it/.test(html) && /Open a tab for it/.test(html));
check("...only that one has the button", (html.match(/Open a tab for it<\/button>/g) || []).length === 1);
check("an offered ticket waiting in a shared window's mailbox says so plainly", /waiting in its mailbox/.test(html));
check("a closed ticket shows its note", /Closing note: Tagged v2\.1\.0/.test(html));
check("an unknown phase falls back to a known class", html.indexOf('tk-<') < 0 && html.indexOf('class="ib-row tk-open"') >= 0);

// ---- a click sends only the row array's id ----
lib.setRows(rows);
const btn = { getAttribute: (k) => (k === "data-i" ? "0" : null) };
lib.ticketAct({ stopPropagation() {}, target: { closest: () => btn } });
eq("Open a tab for it sends the row's id from the array", JSON.stringify(sent.pop()), JSON.stringify(["ticket-tab", "t1790000000-1", undefined]));
lib.ticketAct({ stopPropagation() {}, target: { closest: () => ({ getAttribute: () => "99" }) } });
eq("...a row that isn't there sends nothing", sent.length, 0);

// ---- the card's badge ----
eq("no tickets waiting: no badge", lib.ticketBadge({ key: "k" }), "");
eq("...nor for a count of 0", lib.ticketBadge({ tickets: { waiting: 0 } }), "");
const badge = lib.ticketBadge({ key: "k", tickets: { waiting: 2, id: "t1-1", title: "Bump" + EVIL } });
check("a card whose repo has tickets waiting shows how many", /🎫 2/.test(badge));
check("...its tooltip's title escaped", badge.indexOf("<img") < 0 && badge.indexOf("&lt;img") >= 0);
check("...and Open a tab for it, which never selects the card", /data-nodbl/.test(badge) && /Open a tab for it/.test(badge));
const tile = { getAttribute: (k) => (k === "data-key" ? "card-7" : null) };
lib.ticketTabCard({ stopPropagation() {}, target: { closest: () => tile } });
eq("...a click sends only the card's key", JSON.stringify(sent.pop()), JSON.stringify(["ticket-tab-card", "card-7", undefined]));

console.log("\n-- tickets-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
