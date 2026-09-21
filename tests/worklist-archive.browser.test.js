// worklist-archive.browser.test.js - BEHAVIORAL fixture: the Archive tab in My List,
// driven in a real (headless Chromium) browser.
//
// 2026-09-21, Adam: "once a day moves everything from already done that is older than 10 days
// to an archive list, that way i can keep my previous stuff for referencing etc but the main
// list stays smaller." The moving is pinned on the Lua side (worklist-perf.test.lua); this is
// the other half of the bargain -- that the work he keeps is actually reachable.
//
// The one thing that must NOT happen here is the archive joining the normal payload: the
// whole point is that the store read on every check-off stops carrying it. So the tab asks
// for it separately, the first time it is opened, and never before.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/worklist-archive.browser.test.js

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
  console.log("-- worklist-archive.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser archive check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
const payload = { generic: [], projects: [{ key: "P1", label: "Shepherd",
  items: [{ id: "a1", text: "still open", ts: NOW }] }] };
// What Lua answers with: flattened, newest-completed first, each row carrying its project.
const archiveRows = { rows: [
  { scope: "P1", label: "Shepherd", text: "shipped the installer fixes", doneTs: NOW - 11 * 86400 },
  { scope: "generic", label: "Generic", text: "renewed the domain", doneTs: NOW - 20 * 86400 },
  { scope: "P2", label: "Chargeback", text: "<img src=x onerror=alert(1)>", doneTs: NOW - 40 * 86400 },
] };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser archive check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => { worklistMode = true; window.ccWorklist(p); worklistPick("P1"); }, payload);

  const chip = await page.evaluate(() => {
    const b = document.querySelector('#wl-scopes [data-scope="archive"]');
    return { there: !!b, text: b ? b.textContent : "", asked: window.__sent.length };
  });
  check("My List offers an Archive tab", chip.there === true);
  check("...labelled as the archive  (" + chip.text + ")", /archive/i.test(chip.text));
  check("...and nothing was fetched for it while another tab was open  (sent=" + chip.asked + ")",
        chip.asked === 0);

  // Opening it asks Lua for the archive -- its own message, its own file.
  const opened = await page.evaluate(() => {
    window.__sent = [];
    worklistPick("archive");
    return { scope: worklistScope,
             sent: window.__sent.map(function (s) { try { return JSON.parse(s); } catch (e) { return {}; } }),
             body: (document.getElementById("wl-active") || {}).textContent };
  });
  check("opening the Archive tab stays on it  (scope=" + opened.scope + ")", opened.scope === "archive");
  check("...and asks for the archive separately",
        opened.sent.filter(function (m) { return m.a === "worklist-archive-load"; }).length === 1);
  check("...saying so while it waits  (" + String(opened.body || "").slice(0, 24) + ")",
        /loading/i.test(String(opened.body || "")));

  // The rows arrive and are shown, newest first, each with the project it came from.
  const shown = await page.evaluate((a) => {
    window.ccWorklistArchive(a);
    const rows = Array.from(document.querySelectorAll("#wl-active .wl-item"));
    return {
      n: rows.length,
      first: rows[0] ? rows[0].textContent : "",
      tags: rows.map(function (r) { const t = r.querySelector(".wl-tag"); return t ? t.textContent : ""; }),
      checkboxes: document.querySelectorAll("#wl-active input.wl-cb").length,
      deletes: document.querySelectorAll("#wl-active .wl-del").length,
      html: (document.getElementById("wl-active") || {}).innerHTML,
      pwned: window.__pwned === 1,
    };
  }, archiveRows);
  check("the archived work is shown  (rows=" + shown.n + ")", shown.n === 3);
  check("...in the order Lua sent  (" + String(shown.first).slice(0, 30) + ")",
        String(shown.first).indexOf("shipped the installer fixes") >= 0);
  check("...each labelled with the project it came from  (" + shown.tags.join("|") + ")",
        shown.tags[0] === "Shepherd" && shown.tags[1] === "Generic" && shown.tags[2] === "Chargeback");
  check("...read-only: no checkboxes to un-tick", shown.checkboxes === 0);
  check("...and nothing to delete", shown.deletes === 0);
  // Archived text came out of a JSON file on disk, same as every other item: it is escaped.
  check("...and an item's text can't bring markup with it",
        shown.pwned === false && String(shown.html).indexOf("<img src=x") < 0);

  // Going back to a project tab leaves the archive behind, and doesn't re-fetch it.
  const back = await page.evaluate(() => {
    window.__sent = [];
    worklistPick("P1");
    const n = document.querySelectorAll("#wl-active .wl-item").length;
    worklistPick("archive");
    return { project: n, refetched: window.__sent.filter(function (s) { return s.indexOf("archive-load") >= 0; }).length,
             rows: document.querySelectorAll("#wl-active .wl-item").length };
  });
  check("switching back shows the project's own list again  (rows=" + back.project + ")", back.project === 1);
  check("...and re-opening the archive doesn't ask again  (asked=" + back.refetched + ")", back.refetched === 0);
  check("...it just shows what it already had  (rows=" + back.rows + ")", back.rows === 3);

  // An empty archive says so rather than looking broken.
  const empty = await page.evaluate(() => {
    window.ccWorklistArchive({ rows: [] });
    return (document.getElementById("wl-active") || {}).textContent;
  });
  check("an empty archive explains itself  (" + String(empty).slice(0, 30) + ")",
        /nothing archived/i.test(String(empty)));

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
