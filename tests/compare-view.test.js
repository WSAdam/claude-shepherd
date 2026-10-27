// compare-view.test.js - BEHAVIORAL: the Compare tab's leaderboard (2026-10-27).
//
// Adam, 2026-10-27: "i want to get rid of the requirements tab and instead have a compare tab ... up
// to 5 github users ... commits + lines per day vs the people on the comparison list for a weekly
// leaderboard ... if i clicked a name it could do a drill into showing me which repos they were
// writing to". Runs the REAL shipped compareSorted / compareHtml / renderCompare / compareAct sliced
// out of claude-dashboard.lua, with a small stand-in DOM: the board ranks by the column clicked,
// a name opens that person's repos, This week / Last week switch, the user list edits post the whole
// new list, and every name, repo and error reaching innerHTML is escaped.
//
// Usage: node tests/compare-view.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function done() { console.log("-- compare-view.test.js: " + run + " run, " + failed + " failed --"); process.exit(failed ? 1 : 0); }

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
  sorted: slice("    function compareSorted(rows, sort){", "\n    }\n"),
  html: slice("    function compareHtml(st){", "\n    }\n"),
  render: slice("    function renderCompare(){", "\n    }\n"),
  post: slice("    function comparePost(msg){", "\n    }\n"),
  act: slice("    function compareAct(ev){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("the panel ships " + k, parts[k] !== null);
check("the Compare panel exists, and takes its clicks", src.indexOf('<div class="d-panel" data-tab="compare">') >= 0
      && src.indexOf('<div id="d-compare" onclick="compareAct(event)"></div>') >= 0);
check("the Requirements panel is gone", src.indexOf('data-tab="reqs"') < 0 && src.indexOf('id="d-reqs"') < 0);
if (Object.values(parts).some((p) => p === null)) done();

// ---- a stand-in DOM ----
function el(id) { return { id, value: "", innerHTML: "", disabled: false, onkeydown: null }; }
const els = { "d-compare": el("d-compare"), "cmp-new": el("cmp-new") };
const posted = [];
const env = {
  document: { getElementById: (id) => els[id] || null },
  window: { webkit: { messageHandlers: { cc: { postMessage: (s) => posted.push(JSON.parse(s)) } } } },
  console,
};
const COMPARE_INIT = 'var COMPARE = { data:null, week:"this", sort:"commits", open:{}, draft:"" };\n';
const body = COMPARE_INIT + Object.values(parts).join("\n")
  + "\nreturn { get: function(){ return COMPARE; }, set: function(k, v){ COMPARE[k] = v; }, compareSorted, compareHtml, renderCompare, compareAct };";
const api = new Function("document", "window", "console", body)(env.document, env.window, env.console);

function target(dataCmp) {   // a clicked element inside [data-cmp]
  const t = { getAttribute: (k) => (k === "data-cmp" ? dataCmp : null) };
  t.closest = (sel) => (sel === "[data-cmp]" ? t : null);
  return { target: t, preventDefault() {} };
}
function day(c, a, d, extra) { return Object.assign({ commits: c, add: a, del: d }, extra || {}); }
const DAYS = [0, 1, 2, 3, 4, 5, 6].map((i) => ({ dayEpoch: 1793001600 + i * 86400, future: i > 1 ? true : undefined }));
const data = {
  self: "WSAdam", users: ["jonkopp17"], running: false, runAt: 1793080800, error: null,
  weeks: {
    this: { start: 1793001600, days: DAYS, rows: [
      { login: "jonkopp17", commits: 2, add: 27, del: 7, hidden: 20, pending: 0,
        days: [day(1, 20, 5), day(1, 7, 2), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0)],
        repos: [{ repo: "Org/crm-sdk", commits: 1, add: 20, del: 5 }, { repo: "Org/<b>mail</b>", commits: 1, add: 7, del: 2 }] },
      { login: "WSAdam", you: true, commits: 1, add: 300, del: 10, pending: 0,
        days: [day(1, 300, 10), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0), day(0, 0, 0)],
        repos: [{ repo: "WSAdam/claude-shepherd", commits: 1, add: 300, del: 10 }] },
    ] },
    last: { start: 1792396800, days: DAYS, rows: [
      { login: "WSAdam", you: true, commits: 9, add: 900, del: 90, pending: 0, days: DAYS.map(() => day(0, 0, 0)), repos: [] },
      { login: "jonkopp17", commits: 0, add: 0, del: 0, pending: 0, days: DAYS.map(() => day(0, 0, 0)), repos: [] },
    ] },
  },
};
const order = (h, a, b) => h.indexOf(a) >= 0 && h.indexOf(b) >= 0 && h.indexOf(a) < h.indexOf(b);

// 1. loading
api.renderCompare();
check("before the first answer it says it's loading", /Loading|Checking/.test(els["d-compare"].innerHTML));

// 2. the board, ranked by commits
api.set("data", data);
api.renderCompare();
let h = els["d-compare"].innerHTML;
check("ranked by commits: jonkopp17 above you", order(h, ">jonkopp17<", ">WSAdam<"));
check("your row is marked", /class="cmp-row[^"]*\bcmp-you\b/.test(h));
check("lines show as +added / −deleted", h.indexOf("+27") >= 0 && h.indexOf("−7") >= 0);
check("what GitHub hides from you is a grey note", h.indexOf("+20 private elsewhere") >= 0);
check("each row has a bar per day", (h.match(/class="cmp-bar/g) || []).length === 14);
check("a name's repos stay folded until clicked", h.indexOf("Org/crm-sdk") < 0);

// 3. sort by lines
api.compareAct(target("sort:lines"));
h = els["d-compare"].innerHTML;
check("clicking Lines ranks by lines: you above jonkopp17", api.get().sort === "lines" && order(h, ">WSAdam<", ">jonkopp17<"));
api.compareAct(target("sort:commits"));

// 4. the drill-in
api.compareAct(target("open:jonkopp17"));
h = els["d-compare"].innerHTML;
check("clicking a name opens the repos they wrote to", h.indexOf("Org/crm-sdk") >= 0);
check("...a repo name is escaped", h.indexOf("Org/&lt;b&gt;mail&lt;/b&gt;") >= 0 && h.indexOf("<b>mail</b>") < 0);
check("...busiest first, with commits and lines", order(h, "Org/crm-sdk", "Org/&lt;b&gt;mail") && h.indexOf("+20") >= 0);
api.compareAct(target("open:jonkopp17"));
check("clicking it again folds it", els["d-compare"].innerHTML.indexOf("Org/crm-sdk") < 0);

// 5. last week
api.compareAct(target("week:last"));
h = els["d-compare"].innerHTML;
check("Last week shows last week's rows", api.get().week === "last" && order(h, ">WSAdam<", ">jonkopp17<") && h.indexOf(">9<") >= 0);
api.compareAct(target("week:this"));

// 6. the user list
posted.length = 0;
els["cmp-new"].value = "  HaydnFM ";
api.compareAct(target("add"));
check("Add posts the whole new list", posted.length === 1 && posted[0].a === "compare-users"
      && JSON.stringify(posted[0].users) === JSON.stringify(["jonkopp17", "HaydnFM"]));
posted.length = 0;
api.compareAct(target("rm:jonkopp17"));
check("× posts the list without them", posted.length === 1 && JSON.stringify(posted[0].users) === "[]");
posted.length = 0;
els["cmp-new"].value = "";
api.compareAct(target("add"));
check("an empty Add posts nothing", posted.length === 0);
api.set("data", Object.assign({}, data, { users: ["a", "b", "c", "d", "e"], rejected: ["bad name"] }));
api.renderCompare();
h = els["d-compare"].innerHTML;
check("at 5 people the box is closed", /id="cmp-new"[^>]*disabled/.test(h));
check("a refused name is named", h.indexOf("bad name") >= 0);

// 7. refresh, running, error, escaping
posted.length = 0;
api.set("data", data);
api.compareAct(target("refresh"));
check("Refresh asks for a check", posted.length === 1 && posted[0].a === "compare-refresh");
api.set("data", Object.assign({}, data, { running: true, progress: { done: 3, total: 9 } }));
api.renderCompare();
h = els["d-compare"].innerHTML;
check("while it checks, it says so and Refresh is off", h.indexOf("Checking GitHub") >= 0 && /data-cmp="refresh"[^>]*disabled/.test(h));
api.set("data", Object.assign({}, data, { error: "gh: <script>alert(1)</script>" }));
api.renderCompare();
h = els["d-compare"].innerHTML;
check("an error is shown, escaped", h.indexOf("&lt;script&gt;") >= 0 && h.indexOf("<script>") < 0);
const evil = JSON.parse(JSON.stringify(data));
evil.weeks.this.rows[0].login = '"><img src=x onerror=alert(1)>';
api.set("data", evil);
api.renderCompare();
h = els["d-compare"].innerHTML;
check("a login is escaped everywhere, attributes too", h.indexOf("<img") < 0 && h.indexOf("&lt;img") >= 0);

done();
