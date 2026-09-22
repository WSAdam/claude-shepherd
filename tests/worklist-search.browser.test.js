// worklist-search.browser.test.js - BEHAVIORAL fixture: the My List filter box,
// driven in a real (headless Chromium) browser.
//
// 2026-09-22: the 🗄 Archive tab holds 442 rows and gains ~440 every ten days, and My
// List had no filter anywhere -- a reference list you cannot search is a list you
// cannot use. ONE box filters whichever tab is selected: a project tab that project,
// MASTER the cross-project rollup, Archive all archived rows.
//
// Two things must NOT happen here, and both are pinned below:
//   * the Done drawer must stay UNFILTERED and lazily built (it is display:none until
//     expanded, and building it behind the filter cost 614 hidden rows per click);
//   * ✓ Mark all N done must step aside while a filter is on -- wlOpenCount counts the
//     UNFILTERED list, so a visible button would read "Mark all 442 done" beside three
//     rows, and do exactly that.
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

// Typing, as far as the panel is concerned: the input IS the query state, and
// `oninput` is what re-renders. Passed to page.evaluate with the query as its arg.
const TYPE = (query) => {
  document.getElementById("wl-search").value = query;
  renderWorklist();
};

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

  // The box is there, and sits outside every node renderWorklist rewrites.
  const box = await page.evaluate(() => {
    const el = document.getElementById("wl-search");
    const rebuilt = ["wl-scopes", "wl-active", "wl-done", "wl-mdone"];
    return { there: !!el,
             inRebuilt: rebuilt.some(function (id) { const n = document.getElementById(id); return !!(n && n.contains(el)); }),
             rows: document.querySelectorAll("#wl-active .wl-item").length };
  });
  check("My List has a filter box", box.there === true);
  check("...outside every node the render rewrites, so typing can't lose focus", box.inRebuilt === false);
  check("...and the unfiltered tab shows every active item  (rows=" + box.rows + ")", box.rows === 3);

  // 1. A project tab filters to the matching rows, and says how many of how many.
  await page.evaluate(TYPE, "install");
  const one = await page.evaluate(() => ({
    rows: Array.from(document.querySelectorAll("#wl-active .wl-item")).map(function (r) { return r.textContent; }),
    count: (document.getElementById("wl-search-count") || {}).textContent,
  }));
  check("filtering a project tab keeps only the matching rows  (rows=" + one.rows.length + ")", one.rows.length === 1);
  check("...the right one  (" + String(one.rows[0] || "").slice(0, 28) + ")",
        String(one.rows[0] || "").indexOf("Ship the installer fixes") >= 0);
  check("...and the count says how many of how many  (" + one.count + ")", one.count === "1 / 3 shown");

  // 2. THE DONE DRAWER IS NOT FILTERED. Opening it with a filter on shows every done row.
  const drawer = await page.evaluate(() => {
    worklistToggleDone();
    return { rows: document.querySelectorAll("#wl-done .wl-item").length,
             count: (document.getElementById("wl-donecount") || {}).textContent };
  });
  check("the Done drawer is NOT filtered  (rows=" + drawer.rows + ")", drawer.rows === 2);
  check("...and its count still reads the unfiltered total  (" + drawer.count + ")", drawer.count === "(2)");
  await page.evaluate(() => { worklistToggleDone(); });

  // 3. A filter that matches nothing reads as a filter, not as an empty list.
  await page.evaluate(TYPE, "zzzznope");
  const nobody = await page.evaluate(() => (document.getElementById("wl-active") || {}).textContent);
  check("a no-match filter says nothing matches  (" + String(nobody).slice(0, 30) + ")",
        /nothing matches/i.test(String(nobody)));
  check("...and does NOT tell you to add one above", String(nobody).indexOf("add one above") < 0);

  // 8. Mark all steps aside while the box is non-empty (wlOpenCount is unfiltered).
  const markall = await page.evaluate(() => {
    const mb = document.getElementById("wl-markall");
    return { hidden: mb.style.display, label: mb.textContent };
  });
  check("Mark all is hidden while a filter is on  (display=" + markall.hidden + ")", markall.hidden === "none");
  await page.evaluate(TYPE, "");
  const backOn = await page.evaluate(() => {
    const mb = document.getElementById("wl-markall");
    return { hidden: mb.style.display, label: mb.textContent,
             rows: document.querySelectorAll("#wl-active .wl-item").length,
             count: (document.getElementById("wl-search-count") || {}).textContent };
  });
  check("...and back once the box is cleared  (display='" + backOn.hidden + "')", backOn.hidden === "");
  check("...with its unfiltered count  (" + backOn.label + ")", backOn.label === "✓ Mark all 3 done");
  check("...the full list is back  (rows=" + backOn.rows + ")", backOn.rows === 3);
  check("...and the count blanks with an empty query  ('" + backOn.count + "')", backOn.count === "");

  // 4. MASTER filters across projects, and keeps a bucket header only for survivors.
  const master = await page.evaluate((q) => {
    worklistPick("master");
    const before = document.querySelectorAll("#wl-active .wl-item").length;
    const hdrBefore = document.querySelectorAll("#wl-active .wl-mgroup").length;
    document.getElementById("wl-search").value = q;
    renderWorklist();
    return { before: before, hdrBefore: hdrBefore,
             rows: Array.from(document.querySelectorAll("#wl-active .wl-item")).map(function (r) { return r.textContent; }),
             tags: Array.from(document.querySelectorAll("#wl-active .wl-tag")).map(function (r) { return r.textContent; }),
             headers: document.querySelectorAll("#wl-active .wl-mgroup").length };
  }, "refund");
  check("MASTER rolls up every project unfiltered  (rows=" + master.before + ")", master.before === 5);
  check("...and filters across them  (rows=" + master.rows.length + ")", master.rows.length === 1);
  check("...to the row from the other project  (" + master.tags.join("|") + ")", master.tags[0] === "Chargeback");
  check("...keeping a bucket header only where a row survived  (headers=" + master.headers + "/" + master.hdrBefore + ")",
        master.headers === 1 && master.hdrBefore === 2);

  // 7. The query survives a tab switch -- one box, filtering whatever tab you flick to.
  const survives = await page.evaluate(() => {
    worklistPick("P1");
    return { value: document.getElementById("wl-search").value,
             rows: document.querySelectorAll("#wl-active .wl-item").length };
  });
  check("the query survives a tab switch  (value=" + survives.value + ")", survives.value === "refund");
  check("...and the tab you land on is filtered by it  (rows=" + survives.rows + ")", survives.rows === 0);

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
