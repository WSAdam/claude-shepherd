// cross-view.test.js - BEHAVIORAL: a crossing's review on its session's card and on the 🎫 board
// (2026-10-14).
//
// Adam, 2026-10-14: "projects should not be able to utilize having shepherd to talk to each other,
// that needs to be an approved translation between the two rather than something automatic". A
// ticket, reply or close note a session writes for ANOTHER project waits on that session's card
// (it.crossing) until Adam approves it. The detail panel shows the exact text in boxes he can edit,
// then Approve (his text goes out) or Deny (with a note). An edit in progress must survive the 1s
// refresh; a new crossing must refill the boxes; a click sends only the crossing's id and what the
// boxes hold. When the session has no card, the board carries the same review, every word escaped,
// and a re-render keeps what he typed. Runs the REAL shipped crossPayload / crossBox /
// renderCrossing / crossAct / crossRowsHtml / renderTickets / crossBoardAct sliced out of
// claude-dashboard.lua, with a small stand-in DOM.
//
// Usage: node tests/cross-view.test.js [path/to/claude-dashboard.lua]

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
function done() { console.log("-- cross-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

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
  payload: slice("    function crossPayload(kind, verdict, title, text, why){", "\n    }\n"),
  box: slice("    function crossBox(v){", "\n    }\n"),
  render: slice("    function renderCrossing(it){", "\n    }\n"),
  act: slice("    function crossAct(verdict){", "\n    }\n"),
  rows: slice("    function crossRowsHtml(cross){", "\n    }\n"),
  board: slice("    function crossBoardAct(ev){", "\n    }\n"),
  renderTickets: slice("    function renderTickets(rows){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("the panel ships " + k, parts[k] !== null);
check("the detail panel has the crossing's box, with title, text and note fields",
      src.indexOf('<div id="d-cross">') >= 0 && src.indexOf('id="dx-title"') >= 0 && src.indexOf('id="dx-text"') >= 0
      && src.indexOf('id="dx-why"') >= 0);
check("renderDetail renders it", src.indexOf("renderCrossing(it);") >= 0);
check("a card's line says what it wants to send", src.indexOf("meta = it.crossing.line;") >= 0);
if (Object.values(parts).some((p) => p === null)) done();

// ---- a stand-in DOM: elements by id, and the board's body ----
function el(id) {
  return { id, value: "", textContent: "", maxLength: 0, disabled: false, style: { display: "" },
           attrs: {}, setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k]; } };
}
const ids = {};
["d-cross", "dx-head", "dx-sub", "dx-title", "dx-text", "dx-why", "dx-approve", "dx-deny", "dx-more"].forEach((i) => { ids[i] = el(i); });
const sent = [];
const env = {
  document: { getElementById: (i) => ids[i] || null },
  send: (...a) => sent.push(a),
  fmtAge: () => "5m",
  Date,
};
const factory = new Function("document", "send", "fmtAge", "Date",
  parts.esc + parts.payload + parts.box +
  "\nvar CROSS_ID = null, CROSS_KIND = null, CROSS_SENT = null, CROSS_SENT_T = 0;\n" +
  "var TICKETS = { rows: [], latest: [], cross: [], crossShown: [], sig: '', open: false };\n" +
  "function ticketRowsHtml(){ return ''; }\n" +
  parts.render + parts.act + parts.rows + parts.board + parts.renderTickets +
  "\nreturn { crossPayload, crossBox, renderCrossing, crossAct, crossRowsHtml, crossBoardAct, renderTickets, TICKETS,\n" +
  "  get id(){ return CROSS_ID; }, sentAt(t){ CROSS_SENT_T = t; } };");
const ui = factory(env.document, env.send, env.fmtAge, env.Date);

// ---- what a click sends ----
eq("Approve on a filing sends Adam's title and body", JSON.stringify(ui.crossPayload("ticket", "approve", "T2", "B2", "x")),
   JSON.stringify({ verdict: "approve", title: "T2", body: "B2" }));
eq("...on a reply its text", JSON.stringify(ui.crossPayload("ticket-reply", "approve", "", "R2", "")),
   JSON.stringify({ verdict: "approve", text: "R2" }));
eq("...on a close its note", JSON.stringify(ui.crossPayload("ticket-close", "approve", "", "N2", "")),
   JSON.stringify({ verdict: "approve", note: "N2" }));
eq("Deny sends only Adam's note", JSON.stringify(ui.crossPayload("ticket", "deny", "T", "B", "Not now")),
   JSON.stringify({ verdict: "deny", why: "Not now" }));
eq("the big box holds a filing's body, capped at 2500", JSON.stringify(ui.crossBox({ kind: "ticket", body: "b", caps: { body: 2500 } })),
   JSON.stringify({ text: "b", max: 2500 }));
eq("...a reply's text, capped at 2000", ui.crossBox({ kind: "ticket-reply", text: "r", caps: { text: 2000 } }).max, 2000);
// 2026-10-14 (unit 2): a cc-send prompt and the reply coming back are edited as text, never as a "note"
eq("Approve on a cc-send prompt sends its text", JSON.stringify(ui.crossPayload("send", "approve", "", "P2", "")),
   JSON.stringify({ verdict: "approve", text: "P2" }));
eq("...on a reply coming back, its text", JSON.stringify(ui.crossPayload("send-reply", "approve", "", "R3", "")),
   JSON.stringify({ verdict: "approve", text: "R3" }));
eq("the big box holds a prompt, capped at 3500", JSON.stringify(ui.crossBox({ kind: "send", text: "p", caps: { text: 3500 } })),
   JSON.stringify({ text: "p", max: 3500 }));
eq("...a reply coming back, capped at 8000", JSON.stringify(ui.crossBox({ kind: "send-reply", text: "r", caps: { text: 8000 } })),
   JSON.stringify({ text: "r", max: 8000 }));

// ---- the card's review: filled once, edits kept, refilled for a new crossing ----
const view = { kind: "ticket", title: "Bump the parser", body: "alpha needs 2.x.", sub: "Nothing reaches beta until you approve it.",
               caps: { title: 200, body: 2500, text: 2000, note: 1000 } };
const it = { key: "f1", crossing: { n: 2, cid: "f1.1792100000-1", line: "↔ wants to file a ticket for beta: Bump the parser", view } };
ui.renderCrossing(it);
eq("a card with a crossing shows the box", ids["d-cross"].style.display, "block");
eq("...its line as the head", ids["dx-head"].textContent, it.crossing.line);
eq("...the title and body in the boxes", ids["dx-title"].value + "|" + ids["dx-text"].value, "Bump the parser|alpha needs 2.x.");
eq("...capped as the ticket's are", ids["dx-title"].maxLength + "|" + ids["dx-text"].maxLength, "200|2500");
eq("...and says one more waits", ids["dx-more"].textContent.indexOf("1 more") === 0, true);
ids["dx-title"].value = "Bump the parser to 2.1";
ids["dx-text"].value = "alpha needs 2.1.";
ui.renderCrossing(it);
eq("an edit in progress survives the refresh", ids["dx-title"].value + "|" + ids["dx-text"].value, "Bump the parser to 2.1|alpha needs 2.1.");
ui.crossAct("approve");
const last = sent[sent.length - 1];
eq("Approve sends the crossing's id", last[0] + " " + last[1], "cross-decide f1.1792100000-1");
eq("...and the edited text", last[2], JSON.stringify({ verdict: "approve", title: "Bump the parser to 2.1", body: "alpha needs 2.1." }));
eq("...and greys both buttons until Shepherd answers", ids["dx-approve"].disabled && ids["dx-deny"].disabled, true);
ui.sentAt(Date.now() - 5000);
ui.renderCrossing(it);
eq("...a refused click (a toast says why) frees them again", ids["dx-approve"].disabled, false);
const it2 = { key: "w1", crossing: { n: 1, cid: "w1.1792100100-1", line: "↔ wants to send alpha a reply: On it",
             view: { kind: "ticket-reply", text: "On it", caps: { text: 2000 } } } };
ui.renderCrossing(it2);
eq("a different crossing refills the box", ids["dx-text"].value, "On it");
eq("...a reply has no title box", ids["dx-title"].style.display, "none");
ui.renderCrossing({ key: "x" });
eq("a card with none hides it", ids["d-cross"].style.display, "none");
ui.renderCrossing({ key: "r", remote: { host: "h" }, crossing: it.crossing });
eq("...and a remote card never shows one", ids["d-cross"].style.display, "none");

// ---- the board: escaped, and what Adam typed survives a re-render ----
const evil = '<img src=x onerror="alert(1)">';
const crossRows = [{ cid: "z9.1792100000-1", line: "↔ wants to file a ticket for beta: " + evil, from: evil, fromRepo: "alpha", at: 1,
                     view: { kind: "ticket", title: evil, body: evil + " body", sub: "Nothing reaches beta.", caps: { title: 200, body: 2500 } } }];
const html = ui.crossRowsHtml(crossRows);
check("every word on a board row is escaped", html.indexOf("<img") < 0 && html.indexOf("&lt;img") >= 0);
check("...the title sits in a box Adam can edit", html.indexOf('data-f="title"') >= 0 && html.indexOf('data-f="text"') >= 0);
check("...with Approve and Deny", html.indexOf('data-v="approve"') >= 0 && html.indexOf('data-v="deny"') >= 0);
// a stand-in board body: the boxes renderTickets reads and rebuilds
function boardBody() {
  let fields = [];
  return {
    set innerHTML(h) {
      fields = [];
      const re = /<(input|textarea) class="dx-field" data-f="(\w+)" data-ci="(\d+)"[^>]*?(?:value="([^"]*)")?[^>]*>(?:([^<]*)<\/textarea>)?/g;
      let m;
      while ((m = re.exec(h))) {
        const f = el("f");
        f.attrs["data-f"] = m[2]; f.attrs["data-ci"] = m[3];
        f.value = m[1] === "input" ? (m[4] || "") : (m[5] || "");
        fields.push(f);
      }
    },
    querySelectorAll() { return fields; },
    querySelector(sel) {
      const m = /data-ci="(\d+)"\]\[data-f="(\w+)"/.exec(sel);
      return m ? fields.find((f) => f.attrs["data-ci"] === m[1] && f.attrs["data-f"] === m[2]) || null : null;
    },
  };
}
const body = boardBody();
ids["tk-body"] = body;
ui.TICKETS.cross = crossRows;
ui.renderTickets([]);
const titleBox = body.querySelector('.dx-field[data-ci="0"][data-f="title"]');
titleBox.value = "Adam's own title";
ui.renderTickets([]);
eq("what Adam typed on the board survives a re-render", body.querySelector('.dx-field[data-ci="0"][data-f="title"]').value, "Adam's own title");
body.querySelector('.dx-field[data-ci="0"][data-f="why"]').value = "No thanks";
ui.crossBoardAct({ stopPropagation() {}, target: { disabled: false, getAttribute: (k) => ({ "data-ci": "0", "data-v": "deny" })[k],
                   closest() { return this; } } });
const lb = sent[sent.length - 1];
eq("a board Deny sends the crossing's id and Adam's note", lb[1] + " " + lb[2], "z9.1792100000-1 " + JSON.stringify({ verdict: "deny", why: "No thanks" }));

done();
