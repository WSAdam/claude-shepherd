// worklist-search.browser.test.js - BEHAVIORAL fixture: the My List filter box,
// driven in a real (headless Chromium) browser.
//
// 2026-09-22: the 🗄 Archive tab holds 442 rows and gains ~440 every ten days, and My
// List had no filter anywhere -- a reference list you cannot search is a list you
// cannot use. ONE box filtered whichever tab was selected.
// 2026-10-13 (requirement change, Adam's call): the box shows on the Archive tab only;
// every other tab filters by lane (To do / To verify / All), pinned in
// tests/worklist-lanes.browser.test.js. The Done drawer must still stay UNFILTERED and
// lazily built (it is display:none until expanded; building it cost 614 hidden rows per click).
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/worklist-search.browser.test.js

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
  console.log("-- worklist-search.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser My List filter check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
// P1 has three ACTIVE items (one matching "install") and two DONE ones, so the Done
// drawer has something to stay unfiltered about. P2 gives MASTER a second project.
const payload = {
  generic: [{ id: "g1", text: "Renew the domain", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd", items: [
      // a due date puts this one in its own MASTER bucket, so filtering it away must
      // take that bucket's header with it.
      { id: "a1", text: "Ship the installer fixes", details: "needs a chmod pass", due: "2099-01-01", ts: NOW },
      { id: "a2", text: "Renew the certificate", ts: NOW },
      { id: "a3", text: "Write the changelog", ts: NOW },
      { id: "d1", text: "installer smoke test", done: true, doneTs: NOW - 100 },
      { id: "d2", text: "Tidy the README", done: true, doneTs: NOW - 200 },
    ] },
    { key: "P2", label: "Chargeback", items: [
      { id: "b1", text: "Refund statement layout", ts: NOW },
    ] },
  ],
};
// The archive's own payload: `details` rides along but is NEVER displayed.
const archiveRows = { rows: [
  { scope: "P1", label: "Shepherd", text: "shipped the installer fixes", doneTs: NOW - 11 * 86400 },
  { scope: "generic", label: "Generic", text: "renewed the domain",
    details: "registrar was Gandi, receipt in the drive", doneTs: NOW - 20 * 86400 },
  { scope: "P2", label: "Chargeback", text: "<img src=x onerror=window.__pwned=1>",
    details: "installer", doneTs: NOW - 40 * 86400 },
] };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser My List filter check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  // The body class is what makes #worklist visible; without it the panel is still
  // display:none, and a display:none input cannot take focus (so Escape never fires).
  await page.evaluate((p) => {
    worklistMode = true;
    document.body.classList.add("worklist-mode");
    window.ccWorklist(p); worklistPick("P1");
  }, payload);

  // REQUIREMENT CHANGE 2026-10-13 (Adam: remove "Filter this list…" everywhere but the Archive):
  // the box filtered every tab; it now shows on the 🗄 Archive tab alone, and the other tabs filter
  // by lane (tests/worklist-lanes.browser.test.js). What this file still pins: the box sits outside
  // the rebuilt nodes, it is hidden off the Archive, a query left in it never filters a project tab
  // or MASTER, the Done drawer stays unfiltered, and the Archive search below.
  const box = await page.evaluate(() => {
    const el = document.getElementById("wl-search");
    const rebuilt = ["wl-scopes", "wl-active", "wl-done", "wl-mdone"];
    const row = document.getElementById("wl-searchrow");
    return { there: !!el,
             inRebuilt: rebuilt.some(function (id) { const n = document.getElementById(id); return !!(n && n.contains(el)); }),
             shown: !!row && row.style.display !== "none",
             rows: document.querySelectorAll("#wl-active .wl-item").length };
  });
  check("My List still has a filter box (for the Archive)", box.there === true);
  check("...outside every node the render rewrites, so typing can't lose focus", box.inRebuilt === false);
  check("...hidden on a project tab", box.shown === false);
  check("...where every active item shows  (rows=" + box.rows + ")", box.rows === 3);

  // A query typed on the Archive and left in the box filters nothing elsewhere.
  const left = await page.evaluate(() => {
    worklistPick("archive");
    document.getElementById("wl-search").value = "install";
    worklistPick("P1");
    const p1 = { rows: document.querySelectorAll("#wl-active .wl-item").length,
                 mark: document.getElementById("wl-markall").textContent };
    worklistPick("master");
    const m = { rows: document.querySelectorAll("#wl-active .wl-item").length,
                shown: document.getElementById("wl-searchrow").style.display !== "none" };
    return { p1: p1, m: m };
  });
  check("a query left in the box doesn't filter a project tab  (rows=" + left.p1.rows + ")", left.p1.rows === 3);
  check("...Mark all still counts the whole lane  (" + left.p1.mark + ")", left.p1.mark === "✓ Mark all 3 done");
  check("MASTER ignores it too  (rows=" + left.m.rows + ")", left.m.rows === 5);
  check("...and hides the box", left.m.shown === false);

  // THE DONE DRAWER stays unfiltered and lazily built.
  const drawer = await page.evaluate(() => {
    worklistPick("P1");
    worklistToggleDone();
    return { rows: document.querySelectorAll("#wl-done .wl-item").length,
             count: (document.getElementById("wl-donecount") || {}).textContent };
  });
  check("the Done drawer is NOT filtered  (rows=" + drawer.rows + ")", drawer.rows === 2);
  check("...and its count reads the whole total  (" + drawer.count + ")", drawer.count === "(2)");
  await page.evaluate(() => { worklistToggleDone(); });

  // 5. THE ARCHIVE, searched whole -- including `details`, which is never displayed.
  const arch = await page.evaluate((a) => {
    document.getElementById("wl-search").value = "";
    worklistPick("archive");
    window.ccWorklistArchive(a);
    const all = document.querySelectorAll("#wl-active .wl-item").length;
    document.getElementById("wl-search").value = "gandi";
    renderWorklist();
    const rows = Array.from(document.querySelectorAll("#wl-active .wl-item"));
    return { all: all, n: rows.length, text: rows[0] ? rows[0].textContent : "",
             count: (document.getElementById("wl-search-count") || {}).textContent };
  }, archiveRows);
  check("the Archive shows everything unfiltered  (rows=" + arch.all + ")", arch.all === 3);
  check("...and a term only in a row's NEVER-DISPLAYED details still finds it  (rows=" + arch.n + ")", arch.n === 1);
  check("...the row whose notes carried it  (" + String(arch.text).slice(0, 26) + ")",
        String(arch.text).indexOf("renewed the domain") >= 0);
  check("...that term is genuinely not on screen", String(arch.text).toLowerCase().indexOf("gandi") < 0);
  check("...and the count covers the whole archive  (" + arch.count + ")", arch.count === "1 / 3 shown");

  const archNone = await page.evaluate(() => {
    document.getElementById("wl-search").value = "zzzznope";
    renderWorklist();
    return (document.getElementById("wl-active") || {}).textContent;
  });
  check("an archive filter with no matches says so, not 'nothing archived yet'  (" + String(archNone).slice(0, 34) + ")",
        /matches the filter/i.test(String(archNone)) && String(archNone).indexOf("Nothing archived yet") < 0);

  // 9. XSS: a surviving archived row's text is still escaped on its way to innerHTML.
  const xss = await page.evaluate(() => {
    document.getElementById("wl-search").value = "installer";
    renderWorklist();
    const rows = Array.from(document.querySelectorAll("#wl-active .wl-item"));
    return { n: rows.length, pwned: window.__pwned === 1,
             html: (document.getElementById("wl-active") || {}).innerHTML };
  });
  check("an archived row matched only by its details survives the filter  (rows=" + xss.n + ")", xss.n === 2);
  check("...and markup in its text still can't run", xss.pwned === false && String(xss.html).indexOf("<img src=x") < 0);

  // 6. Escape clears the box and restores the list.
  const esc = await page.evaluate(() => {
    const el = document.getElementById("wl-search");
    el.focus();
    return el === document.activeElement;
  });
  check("the filter box can take focus", esc === true);
  await page.keyboard.press("Escape");
  const cleared = await page.evaluate(() => ({
    value: document.getElementById("wl-search").value,
    rows: document.querySelectorAll("#wl-active .wl-item").length,
    count: (document.getElementById("wl-search-count") || {}).textContent,
  }));
  check("Escape clears the filter  (value='" + cleared.value + "')", cleared.value === "");
  check("...and the whole list comes back  (rows=" + cleared.rows + ")", cleared.rows === 3);
  check("...with no count to show  ('" + cleared.count + "')", cleared.count === "");

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
