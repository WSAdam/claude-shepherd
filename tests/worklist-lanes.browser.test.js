// worklist-lanes.browser.test.js - BEHAVIORAL fixture: My List's To do / To verify / All lanes in
// the shipped panel, driven in a real (headless Chromium) browser (2026-10-13).
//
// Adam's My List reached 262 open items before he looked at it; 243 were "✓ auto" claims waiting
// for his check, burying the ~19 that were real work. He asked for three lane chips in a row under
// "⇪ All projects" / "✓ Mark all N done", with Mark all acting on what the lane shows, and for the
// "Filter this list…" box (except on the Archive) and the "▶ live run" toggle to go.
// To verify = an open item whose file claims it ([x] = fileDone, [~] = fileWait); To do = the rest.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/worklist-lanes.browser.test.js

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
  console.log("-- worklist-lanes.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser lanes check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
const payload = {
  generic: [{ id: "g1", text: "own errand", ts: NOW }, { id: "g2", text: "another errand", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd", items: [
      { id: "t1", text: "work one", ts: NOW, src: "todo" },
      { id: "t2", text: "work two", ts: NOW, src: "todo" },
      { id: "t3", text: "my own note", ts: NOW },
      { id: "t4", text: "deploy then look (needs live run)", ts: NOW, src: "todo", liveRun: true },
      { id: "v1", text: "ticked one", ts: NOW, src: "todo", fileDone: true },
      { id: "v2", text: "ticked two", ts: NOW, src: "todo", fileDone: true },
      { id: "v3", text: "waits on a live run", ts: NOW, src: "todo", fileWait: true, liveRun: true },
      { id: "d1", text: "already checked", ts: NOW, done: true, doneTs: NOW - 5, fileDone: true },
      { id: "d2", text: "checked by hand", ts: NOW, done: true, doneTs: NOW - 9 } ] },
    { key: "P2", label: "Chargeback", items: [
      { id: "w1", text: "chargeback work", ts: NOW, src: "todo" },
      { id: "c1", text: "chargeback ticked", ts: NOW, src: "todo", fileDone: true } ] },
    { key: "P3", label: "Empty-ish", items: [
      { id: "e1", text: "only work here", ts: NOW } ] } ],
};

function state() {
  const chips = Array.from(document.querySelectorAll("#wl-lanerow .wl-lane"));
  const row = document.getElementById("wl-lanerow");
  const todo = document.getElementById("wl-todorow");
  const sr = document.getElementById("wl-searchrow");
  const mb = document.getElementById("wl-markall");
  return {
    rowThere: !!row,
    afterTodoRow: !!row && !!todo && todo.nextElementSibling === row,
    rowShown: !!row && row.style.display !== "none",
    chips: chips.map(function (c) { return c.textContent.replace(/\s+/g, " ").trim(); }),
    on: chips.filter(function (c) { return c.classList.contains("on"); }).map(function (c) { return c.getAttribute("data-lane"); }),
    rows: Array.from(document.querySelectorAll("#wl-active .wl-item .wl-txt")).map(function (e) { return e.textContent; }),
    groups: Array.from(document.querySelectorAll("#wl-active .wl-mgroup")).map(function (e) { return e.textContent; }),
    empty: (document.querySelector("#wl-active .wl-empty") || {}).textContent || "",
    markShown: !!mb && mb.style.display !== "none",
    markText: mb ? mb.textContent : "",
    searchShown: !!sr && sr.style.display !== "none",
    liveToggle: !!document.getElementById("wl-liveonly"),
    doneCount: (document.getElementById("wl-donecount") || {}).textContent || "",
  };
}

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser lanes check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.__asked = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
    window.confirm = (msg) => { window.__asked.push(String(msg)); return window.__answer === true; };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate(() => { try { localStorage.clear(); } catch (e) { /* no storage */ } });
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => { worklistMode = true; window.ccWorklist(p); worklistPick("P1"); }, payload);
  const pick = (lane) => page.evaluate((l) => {
    const c = document.querySelector('#wl-lanerow .wl-lane[data-lane="' + l + '"]');
    if (c) c.click();
  }, lane);
  const mark = () => page.evaluate(() => {
    window.__answer = true; window.__asked = []; window.__sent = [];
    document.getElementById("wl-markall").click();
    return { asked: window.__asked.slice(),
             sent: window.__sent.map(function (s) { try { return JSON.parse(s); } catch (e) { return {}; } }) };
  });

  // 1. the row, where Adam asked for it, defaulting to All
  let s = await page.evaluate(state);
  check("the lane row is there", s.rowThere === true);
  check("...right below the ⇪ All projects / ✓ Mark all row", s.afterTodoRow === true);
  check("...shown on a project tab", s.rowShown === true);
  check("...with To do, To verify and All, counted  (" + s.chips.join(" | ") + ")",
        s.chips.join("|") === "To do 4|To verify 3|All 7");
  check("...All is the default", s.on.join(",") === "all");
  check("...which shows every open row  (" + s.rows.length + ")", s.rows.length === 7);
  check("...and Mark all counts all of them  (" + s.markText + ")", s.markText === "✓ Mark all 7 done");

  // 2. the controls that went
  check("the ▶ live run toggle is gone", s.liveToggle === false);
  check("the filter box is hidden on a project tab", s.searchShown === false);

  // 3. To verify: the claimed rows, [~] included; Mark all marks just those
  await pick("verify");
  s = await page.evaluate(state);
  check("To verify is now the one picked", s.on.join(",") === "verify");
  check("...it shows the ✓ auto rows and the [~] row  (" + s.rows.join(", ") + ")",
        s.rows.length === 3 && s.rows.indexOf("ticked one") >= 0 && s.rows.indexOf("ticked two") >= 0
        && s.rows.indexOf("waits on a live run") >= 0);
  check("...a (needs live run) line that isn't ticked stays out", s.rows.indexOf("deploy then look (needs live run)") < 0);
  check("...Mark all counts the lane  (" + s.markText + ")", s.markText === "✓ Mark all 3 done");
  check("...the Done drawer still counts every done item  (" + s.doneCount + ")", s.doneCount === "(2)");
  let m = await mark();
  check("...Mark all asks, naming the count and the lane  (" + (m.asked[0] || "") + ")",
        m.asked.length === 1 && /\b3\b/.test(m.asked[0]) && /to verify/i.test(m.asked[0]));
  const mv = m.sent.filter(function (x) { return x.a === "worklist-mark-all"; });
  check("...and sends one mark-all for this tab's To verify lane",
        mv.length === 1 && mv[0].v === "P1" && mv[0].text === "verify" && m.sent.length === 1);

  // 4. To do: the rest
  await pick("todo");
  s = await page.evaluate(state);
  check("To do shows the four rows nobody has claimed  (" + s.rows.join(", ") + ")",
        s.rows.length === 4 && s.rows.indexOf("work one") >= 0 && s.rows.indexOf("my own note") >= 0
        && s.rows.indexOf("deploy then look (needs live run)") >= 0);
  check("...and Mark all counts four  (" + s.markText + ")", s.markText === "✓ Mark all 4 done");
  m = await mark();
  const mt = m.sent.filter(function (x) { return x.a === "worklist-mark-all"; });
  check("...and sends the To do lane", mt.length === 1 && mt[0].text === "todo");

  // 5. the lane carries across a tab switch
  await page.evaluate(() => { worklistPick("P2"); });
  s = await page.evaluate(state);
  check("the lane stays To do on another tab  (" + s.rows.join(", ") + ")",
        s.on.join(",") === "todo" && s.rows.length === 1 && s.rows[0] === "chargeback work");
  check("...its chips count that tab  (" + s.chips.join(" | ") + ")", s.chips.join("|") === "To do 1|To verify 1|All 2");

  // 6. an empty lane says so, and Mark all steps aside
  await page.evaluate(() => { worklistPick("P3"); });
  await pick("verify");
  s = await page.evaluate(state);
  check("a tab with nothing to verify says so  (" + s.empty + ")", s.empty === "Nothing to verify on this tab.");
  check("...and offers no Mark all", s.markShown === false);
  await page.evaluate(() => { worklistPick("generic"); });
  await pick("todo");
  await page.evaluate((p) => {
    const q = JSON.parse(JSON.stringify(p));
    q.generic.forEach(function (it) { it.done = true; it.doneTs = 1; });
    window.ccWorklist(q);
  }, payload);
  s = await page.evaluate(state);
  check("a tab with no work left says so  (" + s.empty + ")", s.empty === "Nothing left to do on this tab.");
  await page.evaluate((p) => { window.ccWorklist(p); }, payload);

  // 7. MASTER: the lane filters the rollup before its date headers, and Mark all reaches every project
  await page.evaluate(() => { worklistPick("master"); });
  await pick("verify");
  s = await page.evaluate(state);
  check("MASTER's To verify rolls up every project's claims  (" + s.rows.join(", ") + ")",
        s.rows.length === 4 && s.rows.indexOf("chargeback ticked") >= 0 && s.rows.indexOf("own errand") < 0);
  check("...under one date header, none left over empty  (" + s.groups.join(", ") + ")", s.groups.length === 1);
  check("...its chips count every list  (" + s.chips.join(" | ") + ")", s.chips.join("|") === "To do 8|To verify 4|All 12");
  check("...the filter box is hidden on MASTER", s.searchShown === false);
  m = await mark();
  const mm = m.sent.filter(function (x) { return x.a === "worklist-mark-all"; });
  check("...Mark all asks, saying it reaches every project  (" + (m.asked[0] || "") + ")",
        m.asked.length === 1 && /every project/i.test(m.asked[0]) && /\b4\b/.test(m.asked[0]));
  check("...and sends one mark-all for master's To verify lane", mm.length === 1 && mm[0].v === "master" && mm[0].text === "verify");

  // 8. the Archive keeps its search and has no lanes
  await page.evaluate(() => { worklistPick("archive"); window.ccWorklistArchive({ rows: [] }); });
  s = await page.evaluate(state);
  check("the Archive keeps the filter box", s.searchShown === true);
  check("...and shows no lane row", s.rowShown === false);
  await page.evaluate(() => { worklistPick("generic"); });
  s = await page.evaluate(state);
  check("Generic hides the filter box again", s.searchShown === false);

  // 9. the lane is remembered across a panel reload
  await page.evaluate(() => { worklistPick("P1"); });
  await pick("verify");
  await page.reload();
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => { worklistMode = true; window.ccWorklist(p); worklistPick("P1"); }, payload);
  s = await page.evaluate(state);
  check("after a reload the panel opens on the lane last picked  (" + s.on.join(",") + ")",
        s.on.join(",") === "verify" && s.rows.length === 3);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
