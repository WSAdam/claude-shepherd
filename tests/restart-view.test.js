// restart-view.test.js - BEHAVIORAL: the Restart fleet preview's rows (2026-09-30, build program
// unit 41).
//
// ☰ → Restart fleet shows core.restartPlan's rows before anything reopens: what would reopen (a
// ticked checkbox carrying the session id), what was closed before the last wave (listed, not
// ticked) and what is left alone, with why. Reopen sends only the ticked ids, so the checkbox's
// value IS the request -- and every word of a row (a session's relabel, its folder, a reason
// quoting a path) came from a status file or the snapshot on disk, so each goes through esc().
// Runs the REAL shipped restartRowHtml / restartRowsHtml sliced out of claude-dashboard.lua (the
// diagnostics-sections pattern).
//
// Usage: node tests/restart-view.test.js [path/to/claude-dashboard.lua]

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
const agoSrc = slice("    function restartAgo(sec){", "\n    }\n");
const rowSrc = slice("    function restartRowHtml(r, now){", "\n    }\n");
const rowsSrc = slice("    function restartRowsHtml(plan){", "\n    }\n");
check("the panel ships restartRowHtml and restartRowsHtml", rowSrc !== null && rowsSrc !== null && agoSrc !== null);
if (!(escSrc && agoSrc && rowSrc && rowsSrc)) {
  console.log("\n-- restart-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const lib = new Function(escSrc + "\n" + agoSrc + "\n" + rowSrc + "\n" + rowsSrc + "\nreturn { restartRowHtml, restartRowsHtml, restartAgo };")();
const count = (s, needle) => s.split(needle).length - 1;

const A = "11111111-aaaa-4bbb-8ccc-000000000001";
const C = "33333333-aaaa-4bbb-8ccc-000000000003";
const D = "44444444-aaaa-4bbb-8ccc-000000000004";
const NOW = 1790800000;
const plan = { now: NOW, reopen: 2, older: 1, skipped: 1, rows: [
  { id: A, name: "shop", editor: "vscode", verdict: "reopen", how: "tab", turn: true, mode: "acceptEdits",
    where: "its tab in shop's VS Code window", command: "the Claude extension's link for session " + A, ended: NOW - 60 },
  { id: C, name: "api", editor: "kitty", verdict: "reopen", how: "kitty-new", turn: true, "continue": true,
    where: "a new kitty window", command: "claude -r " + C, model: "claude-opus-5-5[1m]", ended: NOW - 65 },
  { id: D, name: "docs", editor: "terminal", verdict: "reopen", how: "terminal-new", older: true, turn: false,
    where: "a new Terminal window", command: "claude -r " + D, ended: NOW - 6 * 3600 },
  { id: "55555555-aaaa-4bbb-8ccc-000000000005", name: "live one", editor: "vscode", verdict: "skip", reason: "alive",
    why: "it is running (pid 611)" },
] };
const html = lib.restartRowsHtml(plan);
eq("one row per session", count(html, 'class="rs-row '), 4);
eq("three sections, in order: would reopen, closed earlier, left alone", count(html, 'class="rs-sec"'), 3);
check("...in that order", html.indexOf("Would reopen") < html.indexOf("Closed earlier") && html.indexOf("Closed earlier") < html.indexOf("Left alone"));
eq("a session that would reopen has a ticked checkbox", count(html, '" checked onchange="restartCount()">'), 2);
check("...whose value is its session id (what Reopen sends)", html.indexOf('class="rs-pick" value="' + A + '" checked') >= 0);
check("a session closed before the last wave is listed with its checkbox NOT ticked",
      html.indexOf('class="rs-pick" value="' + D + '" onchange="restartCount()">') >= 0);
eq("a session left alone has no checkbox at all (it can't be picked)", count(html, 'class="rs-pick"'), 3);
check("...and says why", html.indexOf("it is running (pid 611)") >= 0);
check("a reopen row says where and how", html.indexOf("a new kitty window: <code>claude -r " + C + "</code>, then Continue") >= 0);
check("a tab gets no 'then Continue' (nothing is typed into VS Code)...",
      html.indexOf("its tab in shop&#39;s VS Code window: <code>the Claude extension&#39;s link for session " + A + "</code> ") >= 0);
check("...but says a turn was in progress", /session 11111111[^<]*<\/code> <i class="rs-bits">· a turn was in progress · acceptEdits · ended 60s ago<\/i>/.test(html));
check("a session whose Continue follows doesn't repeat that", !/then Continue <i class="rs-bits">· a turn was in progress/.test(html));
check("the model the snapshot recorded shows", html.indexOf("claude-opus-5-5[1m]") >= 0);
check("how long ago it ended", html.indexOf("ended 6h ago") >= 0);
eq("restartAgo: seconds", lib.restartAgo(45), "45s");
eq("restartAgo: minutes", lib.restartAgo(600), "10m");
eq("restartAgo: days", lib.restartAgo(3 * 86400), "3d");
eq("no rows: nothing (the caller shows the empty line)", lib.restartRowsHtml({ rows: [] }), "");
eq("a missing plan is no rows", lib.restartRowsHtml(null), "");
eq("junk rows are skipped", lib.restartRowsHtml({ rows: ["x", 7, null] }), "");

// every word came from disk: a relabel, a folder, a reason
const evil = lib.restartRowsHtml({ now: NOW, rows: [
  { id: '"><img src=x onerror=alert(1)>', name: '<img src=x onerror=alert(2)>', editor: '<b>vscode</b>', verdict: "reopen",
    where: '<script>alert(3)</script>', command: '</code><script>alert(4)</script>', mode: '<i>plan</i>', model: '<u>m</u>', ended: NOW - 5 },
  { id: "x", name: "n", editor: "kitty", verdict: "skip", why: 'its folder is gone: /tmp/<img src=x onerror=alert(5)>' },
] });
check("a hostile session name never reaches the HTML raw", evil.indexOf("<img") < 0 && evil.indexOf("&lt;img") >= 0);
check("...nor a hostile id in the checkbox's value", evil.indexOf('value=""><img') < 0 && evil.indexOf("onerror=alert(1)>") < 0);
check("...nor where, the command, the mode or the model", evil.indexOf("<script>") < 0 && evil.indexOf("<i>plan") < 0 && evil.indexOf("<u>") < 0 && evil.indexOf("<b>") < 0);
check("...nor a reason quoting a path", evil.indexOf("alert(5)>") < 0);
eq("...and both rows still render", count(evil, 'class="rs-row '), 2);

console.log("\n-- restart-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
