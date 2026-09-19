// audit-row-escaping.test.js - BEHAVIORAL fixture for the ledger row's redact button.
//
// 2026-09-19: every other value on an audit row went through esc() -- the timestamp, the
// who, the description, and both halves of every detail row -- but the redact button put
// e.id straight into an onclick attribute, inside a JS string literal, inside HTML. Two
// nested contexts, no escaping in either. The ids are stamped by cc_ledger_append, so
// nothing hostile was reaching it; but the ledger is a JSONL file under ~/.claude that
// every hook appends to and the panel reads back off disk, and the source tripwire in
// escaping.test.sh couldn't see it (its deny-list knows it./im./iw./mg./ak., not e.).
//
// The fix is the pattern the tile buttons already use (stackBtnHtml, prBadgeHtml): the
// identifier lives in a data- attribute and the handler reads it back with getAttribute,
// so it is never parsed as code. This runs the REAL shipped auditRow to prove it.
//
// Usage: node tests/audit-row-escaping.test.js [path/to/claude-dashboard.lua]

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
const rowSrc = slice("    function auditRow(e){", "\n    }\n");
check("auditRow extracted from the panel source", !!rowSrc);
check("esc extracted from the panel source", !!escSrc);
if (!rowSrc || !escSrc) {
  console.log("-- audit-row-escaping.test.js: " + run + " run, " + (failed + 1) + " failed --");
  process.exit(1);
}

// Stubs for what auditRow leans on. auditDetail is exercised by its own coverage; here it
// returns "" so the assertions below are about the row itself.
const harness = `
  ${escSrc}
  var auditView = "rows", LAST_SEEN = 0;
  function fmtTs(t){ return "12:00:00"; }
  function evWho(e){ return e.name || ""; }
  function evDesc(e){ return e.desc || ""; }
  function auditDetail(e){ return ""; }
  ${rowSrc}
  return auditRow;
`;
const auditRow = new Function(harness)();

// A ledger id carrying the two characters that end an attribute and a JS string literal.
const HOSTILE = `1'-alert(1)-'" onmouseover="alert(2)`;
const html = auditRow({ id: HOSTILE, ts: 1758240000, name: "repo", desc: "did a thing", prompt: "x" });

check("the row still renders its redact button", html.indexOf("a-redact") >= 0);
// The breakout: the raw id must not appear in the markup at all. If it is in a data-
// attribute it is esc()'d; if it is in a handler it is not.
check("a hostile ledger id never reaches the markup raw", html.indexOf(HOSTILE) < 0);
// The word itself may survive INSIDE an attribute value -- esc() turns its quotes into
// &quot; so it is inert text, not a second attribute. What must not exist is a real one:
// an onmouseover followed by an unescaped quote, which is what a breakout produces.
check("...and no onmouseover handler is smuggled in", !/onmouseover\s*=\s*["']/i.test(html));
// The id must not be interpolated into the onclick at all -- escaping it there would still
// be two nested contexts deep. The handler takes the event and reads the id back itself.
const onclick = (html.match(/onclick="([^"]*)"/g) || []).join(" ");
check("the redact handler carries no interpolated id  (" + onclick.slice(0, 80) + ")",
      onclick.indexOf("alert(") < 0 && /auditRedact\((this|event)\)/.test(onclick));
check("the id rides in a data- attribute instead", /data-(aid|eid|id)="/.test(html));

// The panel reads it back the way the tile buttons do.
const redactSrc = slice("    function auditRedact(", "\n    }\n") || "";
check("auditRedact reads the id with getAttribute", redactSrc.indexOf("getAttribute") >= 0);

// Same row, same class: the timestamp is a number everywhere it is used, but a ledger
// line is a file on disk -- a string ts must not become code either.
const html2 = auditRow({ id: "ok-id", ts: `0);alert(3);//`, name: "r", desc: "d", prompt: "x" });
check("a hostile ledger timestamp doesn't reach a handler either",
      (html2.match(/onclick="([^"]*)"/g) || []).join(" ").indexOf("alert(3)") < 0);

console.log("-- audit-row-escaping.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
