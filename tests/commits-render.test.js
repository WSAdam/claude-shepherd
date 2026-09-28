// commits-render.test.js - BEHAVIORAL fixture for the commit stats under the fleet block
// (2026-09-25): the Today / This week lines, the Mon–Sun strip, the pace marker and the
// drawer. It slices the REAL shipped block (between the "Commit stats" markers) plus esc and
// fmtTok out of claude-dashboard.lua and runs it, so there is no copy of the markup to drift.
//
// Usage: node tests/commits-render.test.js [path/to/claude-dashboard.lua]

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
// fmtTok is declared twice in the panel script; the LAST declaration is the one that runs.
const tokSrc2 = (function () {
  const i = src.lastIndexOf("    function fmtTok(n){");
  if (i < 0) return null;
  const j = src.indexOf("return String(Math.round(n)); }", i);
  if (j < 0) return null;
  return src.slice(i, j + "return String(Math.round(n)); }".length);
})();
const blockSrc = slice("    // ---- Commit stats (2026-09-25) ----", "    // ---- end commit stats ----");
check("extracted esc()", escSrc !== null);
check("extracted fmtTok()", tokSrc2 !== null);
check("extracted the commit stats block", blockSrc !== null);
if (escSrc === null || tokSrc2 === null || blockSrc === null) {
  console.log(`-- commits-render.test.js: ${run} run, ${failed} failed --`);
  process.exit(1);
}
const api = new Function(escSrc + "\n" + tokSrc2 + "\n" + blockSrc +
  "\nreturn { commitFootHtml: commitFootHtml, commitStrip: commitStrip, fmtLines: fmtLines };")();

const MON = 1789963200; // Mon 2026-09-21 00:00 EDT
const NOW = 1790348400; // Fri 2026-09-25 11:00 EDT
function day(i, commits, add, del) {
  return { commits: commits, add: add, del: del, dayEpoch: MON + i * 86400, isToday: i === 4, future: i > 4 };
}
const days = [day(0, 1, 1, 0), day(1, 0, 0, 0), day(2, 0, 0, 0), day(3, 2, 7, 6), day(4, 1, 10, 2), day(5, 0, 0, 0), day(6, 0, 0, 0)];
const XSS = '<img src=x onerror=alert(1)>';
const data = {
  ts: NOW - 120,
  today: { commits: 1, add: 10, del: 2 },
  week: { commits: 4, add: 4321, del: 174 },
  lastWeekSoFar: { commits: 1, add: 7, del: 0 },
  days: days,
  repos: [
    { root: "/r/alpha", name: "Alpha", today: { commits: 1, add: 10, del: 2 }, week: { commits: 3, add: 16, del: 7 },
      days: days, commits: [{ sha: "aaa1", at: NOW - 3600, subject: "feat: " + XSS, add: 10, del: 2 }] },
    { root: '/r/"quoted"', name: XSS, today: { commits: 0, add: 0, del: 0 }, week: { commits: 1, add: 2, del: 1 },
      days: days, commits: [] },
  ],
  recent: [{ repo: XSS, sha: "aaa1", at: NOW - 3600, subject: "fix " + XSS, add: 10, del: 2 }],
  emails: ["me@example.invalid"],
  repoCount: 2,
};

// ---- the two lines --------------------------------------------------------------------
let html = api.commitFootHtml(data, false, {}, NOW);
check("renders a Today line", html.indexOf("Today") >= 0);
check("renders a This week line", html.indexOf("This week") >= 0);
check("today reads '1 commit' (singular)", html.indexOf("1 commit ") >= 0 || html.indexOf("1 commit<") >= 0);
check("the week reads '4 commits'", html.indexOf("4 commits") >= 0);
check("the week's lines round to k", html.indexOf("+4.3k") >= 0 && html.indexOf("−174") >= 0);
check("pace: 3 ahead of the same point last week", html.indexOf("↑3 vs last wk") >= 0);
check("the closed drawer isn't built", html.indexOf("cf-drawer") < 0);

let behind = Object.assign({}, data, { week: { commits: 1, add: 1, del: 0 }, lastWeekSoFar: { commits: 4, add: 0, del: 0 } });
check("pace: behind reads ↓", api.commitFootHtml(behind, false, {}, NOW).indexOf("↓3 vs last wk") >= 0);
let level = Object.assign({}, data, { lastWeekSoFar: { commits: 4, add: 0, del: 0 } });
check("pace: level reads '= last wk'", api.commitFootHtml(level, false, {}, NOW).indexOf("= last wk") >= 0);

// ---- the Mon–Sun strip ----------------------------------------------------------------
const strip = api.commitStrip(days);
check("the strip has seven bars", (strip.match(/class="cf-bar/g) || []).length === 7);
check("one bar is today", (strip.match(/cf-bar[^"]*today/g) || []).length === 1);
check("the weekend is still ahead", (strip.match(/cf-bar[^"]*future/g) || []).length === 2);
check("a bar's tooltip names its day and count", strip.indexOf("Thu 9/24: 2 commits") >= 0);
check("fmtLines keeps small numbers exact", api.fmtLines(12, 3) === "+12 −3");

// ---- the drawer -----------------------------------------------------------------------
html = api.commitFootHtml(data, true, {}, NOW);
check("the open drawer lists each project", html.indexOf("Alpha") >= 0);
check("the open drawer lists recent commits", html.indexOf("fix &lt;img") >= 0);
check("a project name can't smuggle markup", html.indexOf(XSS) < 0 && html.indexOf("&lt;img src=x") >= 0);
check("a quoted root stays inside its attribute", html.indexOf('data-root="/r/&quot;quoted&quot;"') >= 0);
check("the footer names whose commits count", html.indexOf("me@example.invalid") >= 0);
check("a collapsed project doesn't list its commits", html.indexOf("feat: &lt;img") < 0);
html = api.commitFootHtml(data, true, { "/r/alpha": true }, NOW);
check("an expanded project lists its week's commits, escaped", html.indexOf("feat: &lt;img") >= 0);

// ---- the session that made each commit (2026-09-28) --------------------------------------
// core.commitWeek links a commit to the transcript that printed it; annotateCommitSessions adds
// the tile's key and name while that session is live. Only a live one offers its Transcript.
const LIVE = { id: "4e1d8fc9-435c-414e-8b97-9018cc625a56", key: 'k"1', name: "Alpha " + XSS, branch: "feat/x" };
const ENDED = { id: "9ccf71cf-40ef-4d30-9627-eaaccfb586df", branch: "main" };
const linked = Object.assign({}, data, {
  recent: [
    Object.assign({}, data.recent[0], { session: LIVE }),
    { repo: "Alpha", sha: "bbb2", at: NOW - 7200, subject: "ended one", add: 1, del: 0, session: ENDED },
    { repo: "Alpha", sha: "ccc3", at: NOW - 9000, subject: "by hand", add: 1, del: 0 },
  ],
});
html = api.commitFootHtml(linked, true, {}, NOW);
const count = (s, needle) => s.split(needle).length - 1;
check("a live session's commit offers its Transcript, keyed to its tile",
  /<button class="cf-sess live"[^>]*data-sk="k&quot;1"/.test(html));
check("...named after its tile, escaped", html.indexOf("Alpha &lt;img") >= 0 && html.indexOf(XSS) < 0);
check("...and its tooltip says it opens the Transcript", /class="cf-sess live"[^>]*title="[^"]*Transcript/.test(html));
check("an ended session shows its short id", html.indexOf(">9ccf71cf<") >= 0);
check("...with no Transcript to open", count(html, "data-sk=") === 1);
check("a commit no transcript printed shows no session", count(html, 'class="cf-sess') === 2);
html = api.commitFootHtml(Object.assign({}, linked, {
  repos: [Object.assign({}, data.repos[0], { commits: [Object.assign({}, data.repos[0].commits[0], { session: LIVE })] })],
  recent: [] }), true, { "/r/alpha": true }, NOW);
check("an expanded project's commit links its session too", count(html, 'class="cf-sess live"') === 1);

// ---- edge states ----------------------------------------------------------------------
check("before the first count it says so", api.commitFootHtml(null, false, {}, NOW).indexOf("counting") >= 0);
let threw = null;
try {
  // hs.json encodes an empty Lua table as {} -- never an array
  html = api.commitFootHtml({ today: { commits: 0, add: 0, del: 0 }, week: { commits: 0, add: 0, del: 0 },
    lastWeekSoFar: {}, days: {}, repos: {}, recent: {}, emails: {}, repoCount: 0 }, true, {}, NOW);
} catch (e) { threw = e; }
check("empty {} arrays render without throwing", threw === null);
check("no repos yet says so", threw === null && html.indexOf("No repos yet") >= 0);
const noId = api.commitFootHtml({ noIdentity: true, repoCount: 2, today: {}, week: {}, days: [], repos: [], recent: [] }, false, {}, NOW);
check("no identity says how to set one", noId.indexOf("git config --global user.email") >= 0);
check("a failed refresh is marked stale", api.commitFootHtml(Object.assign({}, data, { stale: true }), false, {}, NOW).indexOf("stale") >= 0);

console.log(`-- commits-render.test.js: ${run} run, ${failed} failed --`);
process.exit(failed === 0 ? 0 : 1);
