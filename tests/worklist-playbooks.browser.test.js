// worklist-playbooks.browser.test.js - BEHAVIORAL fixture: playbooks as My List sources, driven in a
// real (headless Chromium) browser against the shipped panel.
//
// 2026-10-03 (mining round 2, unit D3a): a markdown checklist picked on a project's My List tab
// becomes a source. Its lines import like TODO.md's, grouped under the file's name.
//
// Pinned here:
//   * 📘 Add a playbook… shows on a project tab only (never Generic, MASTER or the Archive), and its
//     message names the tab and NOTHING else -- the file comes from the native chooser in Lua;
//   * the tab's playbooks are listed by name (path in the tooltip), each with a Remove that asks
//     first and sends only the source's id;
//   * a project tab's open rows: TODO.md lines and Adam's own items first, then each playbook's
//     lines under a header with the file's name; a removed playbook's items stay, still grouped;
//   * a filter drops a header whose rows all went;
//   * a playbook row's ✓ auto chip names the playbook, not TODO.md, and never ticks the checkbox;
//   * names and paths are escaped; ccPlaybookResult says what happened in the toast line.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like the other My List browser tests.
// Usage: node tests/worklist-playbooks.browser.test.js

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function finish() {
  console.log("-- worklist-playbooks.browser.test.js: " + run + " run, " + failed + " failed --");
  process.exit(failed ? 1 : 0);
}

function loadPlaywright() {
  const tries = [process.env.CC_PLAYWRIGHT,
    path.join(os.homedir(), ".isolate-runner", "node_modules", "playwright"), "playwright"].filter(Boolean);
  for (const t of tries) { try { return require(t); } catch (e) { /* next */ } }
  return null;
}
const pw = loadPlaywright();
if (!pw) {
  console.log("skip - real-browser My List playbooks check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
  process.exit(0);
}

const out = fs.mkdtempSync(path.join(os.tmpdir(), "cc-panel-"));
const home = fs.mkdtempSync(path.join(os.tmpdir(), "cc-home-"));
try {
  execFileSync("lua", [path.join(ROOT, "tests/support/capture-panel.lua"), ROOT, out],
    { env: Object.assign({}, process.env, { HOME: home }), stdio: ["ignore", "pipe", "inherit"] });
} catch (e) {
  check("captured the shipped panel html under a stubbed hs", false);
  finish();
}
const update = fs.readFileSync(path.join(out, "update.js"), "utf8");

const NOW = Math.floor(Date.now() / 1000);
const REL = "/Users/adam/notes/release.md";
const HOT = "/Users/adam/notes/<b>hot</b>fix.md";
const OLD = "/Users/adam/notes/old-runbook.md";
// P1: a TODO.md line and an own item, then lines from two playbooks interleaved with them (the
// order they were imported in), and an item from a playbook that has since been removed.
const payload = {
  generic: [{ id: "g1", text: "Renew the domain", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd",
      playbooks: [{ id: "pb1", name: "release.md", path: REL }, { id: "pb2", name: "<b>hot</b>fix.md", path: HOT }],
      items: [
        { id: "a1", text: "a TODO.md line", src: "todo", srcText: "a TODO.md line", ts: NOW },
        { id: "r1", text: "tag the build", src: "playbook", srcFile: REL, srcName: "release.md", ts: NOW },
        { id: "h1", text: "cherry-pick the fix", src: "playbook", srcFile: HOT, srcName: "<b>hot</b>fix.md", fileDone: true, ts: NOW },
        { id: "a2", text: "my own item", ts: NOW },
        { id: "r2", text: "write the notes", src: "playbook", srcFile: REL, srcName: "release.md", fileDone: true, ts: NOW },
        { id: "o1", text: "an old runbook step", src: "playbook", srcFile: OLD, srcName: "old-runbook.md", ts: NOW },
        { id: "r3", text: "a verified release step", src: "playbook", srcFile: REL, srcName: "release.md", done: true, doneTs: NOW - 50 },
      ] },
    { key: "P2", label: "Quiet", items: [{ id: "q1", text: "nothing from a playbook", src: "todo", ts: NOW }] },
  ],
};

const VIEW = () => {
  const add = document.getElementById("wl-pbadd");
  const rowEl = document.getElementById("wl-pbrow");
  const seq = [];
  document.querySelectorAll("#wl-active > *").forEach(function (el) {
    if (el.classList.contains("wl-pbgroup")) seq.push("# " + el.textContent);
    else if (el.classList.contains("wl-item")) seq.push((el.querySelector(".wl-txt") || el).textContent);
  });
  return {
    addThere: !!add,
    addShown: !!add && add.style.display !== "none",
    pbShown: !!rowEl && rowEl.style.display !== "none",
    pbNames: rowEl ? Array.from(rowEl.querySelectorAll(".wl-pbname")).map(function (n) { return n.textContent; }) : [],
    pbTitles: rowEl ? Array.from(rowEl.querySelectorAll(".wl-pbname")).map(function (n) { return n.getAttribute("title"); }) : [],
    pbHtml: rowEl ? rowEl.innerHTML : "",
    seq: seq,
    activeHtml: document.getElementById("wl-active").innerHTML,
  };
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser My List playbooks check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.__confirm = true;
    window.confirm = () => window.__confirm;
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => {
    worklistMode = true;
    document.body.classList.add("worklist-mode");
    window.ccWorklist(p); worklistPick("P1");
  }, payload);

  // 1. A project tab: the Add button, the playbooks listed, the rows grouped.
  const v = await page.evaluate(VIEW);
  check("My List has a 📘 Add a playbook… button", v.addThere === true);
  check("...shown on a project tab", v.addShown === true);
  check("the tab's playbooks are listed by name  (" + v.pbNames.join(" | ") + ")", v.pbShown === true
        && v.pbNames.length === 2 && v.pbNames[0] === "release.md" && v.pbNames[1] === "<b>hot</b>fix.md");
  check("...each with its path in the tooltip", v.pbTitles[0] && v.pbTitles[0].indexOf(REL) >= 0);
  check("...a name is text, never markup", v.pbHtml.indexOf("<b>hot") < 0 && v.pbHtml.indexOf("&lt;b&gt;hot") >= 0);
  const want = ["a TODO.md line", "my own item",
    "# 📘 release.md", "tag the build", "write the notes",
    "# 📘 <b>hot</b>fix.md", "cherry-pick the fix",
    "# 📘 old-runbook.md · removed", "an old runbook step"];
  check("TODO.md lines and own items first, then each playbook's lines under its name  (" + v.seq.join(" / ") + ")",
        JSON.stringify(v.seq) === JSON.stringify(want));
  check("a header's name is escaped too", v.activeHtml.indexOf("<b>hot</b>fix") < 0);

  // 2. Badges: a playbook row's ✓ auto names the playbook; the checkbox stays Adam's.
  const badge = await page.evaluate(() => {
    const row = Array.from(document.querySelectorAll("#wl-active .wl-item")).filter(function (r) {
      return (r.querySelector(".wl-txt") || {}).textContent === "write the notes"; })[0];
    const chip = row && row.querySelector(".wl-fdone");
    const cb = row && row.querySelector(".wl-cb");
    return { title: chip ? chip.getAttribute("title") : "", checked: cb ? cb.checked : null };
  });
  check("a playbook row's ✓ auto chip names the playbook  (" + badge.title + ")",
        badge.title.indexOf("release.md") >= 0 && badge.title.indexOf("TODO.md") < 0);
  check("...and never ticks the checkbox", badge.checked === false);

  // 3. A filter drops a header with no rows left under it.
  // REQUIREMENT CHANGE 2026-10-13 (Adam: the "Filter this list…" box is Archive-only now): the
  // filter here is the To verify lane, which keeps only the two ticked playbook rows (headers in the
  // order their first surviving row comes, as ever: h1 is listed before r2).
  const filtered = await page.evaluate((S) => {
    wlLanePick("verify");
    const r = (0, eval)("(" + S + ")")();
    wlLanePick("all");
    return r.seq;
  }, VIEW.toString());
  check("a lane keeps only the headers with rows  (" + filtered.join(" / ") + ")",
        JSON.stringify(filtered) === JSON.stringify(["# 📘 <b>hot</b>fix.md", "cherry-pick the fix", "# 📘 release.md", "write the notes"]));

  // 4. Add: the message names the tab, nothing else.
  const addMsg = await page.evaluate(() => {
    window.__sent = [];
    document.getElementById("wl-pbadd").click();
    return window.__sent.slice();
  });
  const am = addMsg.length === 1 ? JSON.parse(addMsg[0]) : {};
  check("Add sends worklist-playbook-add for this tab  (" + addMsg.join(" ") + ")", am.a === "worklist-playbook-add" && am.v === "P1");
  check("...and no path: the file comes from the native chooser", (am.text || "") === "" && am.path === undefined);

  // 5. Remove asks first, and sends only the id.
  const rm = await page.evaluate(() => {
    window.__sent = []; window.__confirm = false;
    const x = document.querySelector('#wl-pbrow .wl-pbdel[data-pbdel="pb1"]');
    if (x) x.click();
    const declined = window.__sent.slice();
    window.__confirm = true;
    if (x) x.click();
    return { there: !!x, declined: declined, sent: window.__sent.slice() };
  });
  check("each playbook has a Remove", rm.there === true);
  check("...that does nothing when the confirm is declined", rm.declined.length === 0);
  const rmm = rm.sent.length === 1 ? JSON.parse(rm.sent[0]) : {};
  check("...and sends worklist-playbook-remove with the tab and the id  (" + rm.sent.join(" ") + ")",
        rmm.a === "worklist-playbook-remove" && rmm.v === "P1" && rmm.text === "pb1");

  // 6. Not on Generic, MASTER or the Archive; a project tab with none shows the button but no list.
  const elsewhere = await page.evaluate((S) => {
    const f = (0, eval)("(" + S + ")");
    worklistPick("generic"); const g = f();
    worklistPick("master"); const m = f();
    worklistPick("archive"); window.ccWorklistArchive({ rows: [] }); const a = f();
    worklistPick("P2"); const q = f();
    return { g: g, m: m, a: a, q: q };
  }, VIEW.toString());
  check("never on Generic", elsewhere.g.addShown === false && elsewhere.g.pbShown === false);
  check("never on MASTER", elsewhere.m.addShown === false && elsewhere.m.pbShown === false);
  check("never on the Archive", elsewhere.a.addShown === false && elsewhere.a.pbShown === false);
  check("a project tab with no playbooks offers Add, and lists none", elsewhere.q.addShown === true && elsewhere.q.pbShown === false);
  check("...and its rows carry no header", elsewhere.q.seq.join("|") === "nothing from a playbook");

  // 7. The result line.
  const toast = await page.evaluate(() => {
    const el = document.getElementById("wl-todoflash");
    window.ccPlaybookResult({ name: "release.md", added: 3, updated: 0, missing: 0 }); const a = el.textContent;
    window.ccPlaybookResult({ error: "That playbook is already on this tab." }); const b = el.textContent;
    window.ccPlaybookResult({ removed: "release.md" }); const c = el.textContent;
    window.ccPlaybookResult({ name: "gone.md", added: 0, updated: 0, missing: 0, unreadable: true }); const d = el.textContent;
    window.ccPlaybookResult({ auto: true, name: "release.md", added: 1, updated: 2, missing: 0 }); const e = el.textContent;
    return { a: a, b: b, c: c, d: d, e: e };
  });
  check("added: names the playbook and the new lines  (" + toast.a + ")", toast.a.indexOf("release.md") >= 0 && /3 new/.test(toast.a));
  check("refused: says why  (" + toast.b + ")", toast.b.indexOf("already on this tab") >= 0);
  check("removed: says its items stay  (" + toast.c + ")", toast.c.indexOf("release.md") >= 0 && /stay/.test(toast.c));
  check("unreadable: says so  (" + toast.d + ")", /couldn.t read/i.test(toast.d));
  check("synced: says so  (" + toast.e + ")", /synced/.test(toast.e) && /1 new, 2 updated/.test(toast.e));

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
