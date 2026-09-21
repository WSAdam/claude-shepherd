// worklist-checkoff.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a
// real (headless Chromium) browser and checks what happens when you tick an item off.
//
// 2026-09-21: "big delays between clicking it and it being marked as done". Two causes on the
// render side, both measured on Adam's own list (1,065 items, 683 of them done):
//
//   1. Nothing happened in the list until Lua round-tripped. The click handler only posted a
//      message; the row moved, the counts changed and the Done drawer updated when (and only
//      when) window.ccWorklist(...) came back. The store read behind that was fixed
//      separately -- this pins that the LIST does not wait for it at all.
//   2. renderWorklist() built every Done row on every render, including while the Done drawer
//      was collapsed (#wl-done is display:none until you open it). On the ChargebackSentinel
//      tab that is 614 hidden rows rebuilt per click, each with its own esc() calls and date
//      arithmetic, for a drawer nobody was looking at.
//
// The browser is the honest test here: the claim is about DOM nodes that exist or don't, and
// about an update landing with no reply from Lua -- the stub records posted messages and
// answers nothing, so anything that appears is the panel's own doing.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/worklist-checkoff.browser.test.js

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
  console.log("-- worklist-checkoff.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser check-off check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

// A tab shaped like Adam's worst one: a handful still to do, hundreds already done.
const NOW = Math.floor(Date.now() / 1000);
const items = [];
for (let i = 1; i <= 8; i++) items.push({ id: "a" + i, text: "still to do " + i, ts: NOW - i });
for (let i = 1; i <= 600; i++) items.push({ id: "d" + i, text: "already done " + i, ts: NOW - 1000 - i, done: true, doneTs: NOW - i });
const payload = { generic: [], projects: [{ key: "P1", label: "Chargeback", items: items }] };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser check-off check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);

  // Open My List on that project's tab, exactly as the panel does.
  await page.evaluate((p) => {
    worklistMode = true;
    window.ccWorklist(p);
    worklistPick("P1");
  }, payload);

  const shown = await page.evaluate(() => ({
    active: document.querySelectorAll("#wl-active .wl-item").length,
    doneRows: document.querySelectorAll("#wl-done .wl-item").length,
    count: (document.getElementById("wl-donecount") || {}).textContent,
    open: document.getElementById("wl-donewrap").classList.contains("open"),
  }));
  check("the tab shows the items still to do  (active=" + shown.active + ")", shown.active === 8);
  check("the Done drawer starts collapsed", shown.open === false);
  check("...and its 600 rows are NOT built while it is collapsed  (rows=" + shown.doneRows + ")",
        shown.doneRows === 0);
  check("...though it still says how many there are  (count=" + shown.count + ")",
        String(shown.count).indexOf("600") >= 0);

  // Opening it really does build them -- the rows are skipped, not lost.
  const opened = await page.evaluate(() => {
    worklistToggleDone();
    return { rows: document.querySelectorAll("#wl-done .wl-item").length,
             open: document.getElementById("wl-donewrap").classList.contains("open") };
  });
  check("opening the drawer builds its rows  (rows=" + opened.rows + ")", opened.open && opened.rows === 600);
  await page.evaluate(() => { worklistToggleDone(); });   // collapse again for the click test

  // ---- the click itself: the list must not wait for Lua ----------------------
  // Nothing answers the posted message, so everything asserted below is the panel acting on
  // its own. The row leaves the active list, the done count goes up, and Lua still hears.
  const clicked = await page.evaluate(() => {
    window.__sent = [];
    var cb = document.querySelector('#wl-active input.wl-cb[data-id="a3"]');
    if (!cb) return { err: "no checkbox for a3" };
    cb.click();
    return {
      active: document.querySelectorAll("#wl-active .wl-item").length,
      stillThere: !!document.querySelector('#wl-active input.wl-cb[data-id="a3"]'),
      count: (document.getElementById("wl-donecount") || {}).textContent,
      sent: window.__sent.slice(),
    };
  });
  check("clicking a checkbox doesn't error  (" + (clicked.err || "ok") + ")", !clicked.err);
  check("...the row leaves the to-do list at once, with no reply from Lua  (active=" + clicked.active + ")",
        clicked.active === 7 && clicked.stillThere === false);
  check("...the done count goes up at once  (count=" + clicked.count + ")",
        String(clicked.count).indexOf("601") >= 0);
  const msg = (clicked.sent || []).map(function (s) { try { return JSON.parse(s); } catch (e) { return {}; } })
    .filter(function (m) { return m.a === "worklist-toggle"; })[0];
  check("...and Lua is still told to toggle that id", !!msg && msg.v === "P1" && msg.text === "a3");

  // Un-ticking is the same deal, in reverse: it comes back to the to-do list at once.
  const unticked = await page.evaluate(() => {
    worklistToggleDone();                       // open Done so the row is clickable
    var cb = document.querySelector('#wl-done input.wl-cb[data-id="a3"]');
    if (!cb) return { err: "no done checkbox for a3" };
    window.__sent = [];
    cb.click();
    return { back: !!document.querySelector('#wl-active input.wl-cb[data-id="a3"]'),
             active: document.querySelectorAll("#wl-active .wl-item").length,
             sent: window.__sent.length };
  });
  check("un-ticking brings it back at once  (" + (unticked.err || "ok") + ")",
        !unticked.err && unticked.back === true && unticked.active === 8 && unticked.sent >= 1);

  // ...and the authoritative push from Lua still wins when it arrives.
  const reconciled = await page.evaluate((p) => {
    window.ccWorklist(p);
    return { active: document.querySelectorAll("#wl-active .wl-item").length };
  }, payload);
  check("a push from Lua still replaces what the panel guessed  (active=" + reconciled.active + ")",
        reconciled.active === 8);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
