// worklist-liverun.browser.test.js - BEHAVIORAL fixture: My List's ▶ live run lines, driven in a
// real (headless Chromium) browser.
//
// 2026-09-29 (build program unit 37): some TODO items can only be checked by a live run -- deploy,
// then look -- and My List showed them mixed in with everything else. core.parseTodoFile flags
// `- [~]` lines and `(needs live run)` / `(live check)` lines (liveRun = true), and each such row
// shows a ▶ live run chip.
//
// REQUIREMENT CHANGE 2026-10-13 (Adam: remove the "▶ live run" toggle): the toggle beside the filter
// box that kept only these rows is gone. My List's lanes replace it: a `[~]` line (fileWait) is To
// verify, because the work is in and only Adam's live run is left, while a `[ ] … (needs live run)`
// line is still unfinished work and stays in To do. Pinned here:
//   * no toggle exists anywhere, and the Archive shows none;
//   * every open live-run row still carries its ▶ chip, on a project tab and on MASTER;
//   * the [~] row and a ticked marked row are in To verify, the open marked row in To do;
//   * a live-run row's text still goes through esc().
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like the other My List browser tests.
// Usage: node tests/worklist-liverun.browser.test.js

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
  console.log("-- worklist-liverun.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser My List live-run check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
// P1: a [~] line (fileWait), an open line with the marker, a ticked line with the marker, two plain
// open lines, and a done live-run line. P2 has one [~] line with hostile text, for MASTER and escaping.
const payload = {
  generic: [{ id: "g1", text: "Renew the domain", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd", items: [
      { id: "a1", text: "open the panel and look at the chip", src: "todo", liveRun: true, fileWait: true, ts: NOW },
      { id: "a2", text: "Write the changelog", src: "todo", ts: NOW },
      { id: "a3", text: "shipped the probe (needs live run)", src: "todo", liveRun: true, fileDone: true, ts: NOW },
      { id: "a4", text: "Renew the certificate", ts: NOW },
      { id: "a5", text: "deploy, then click Sync (needs live run)", src: "todo", liveRun: true, ts: NOW },
      { id: "d1", text: "deployed and clicked (live check)", src: "todo", liveRun: true, done: true, doneTs: NOW - 100 },
    ] },
    { key: "P2", label: "Chargeback", items: [
      { id: "b1", text: "<img src=x onerror=window.__pwned=1> check the refund page", src: "todo", liveRun: true, fileWait: true, ts: NOW },
      { id: "b2", text: "Refund statement layout", ts: NOW },
    ] },
  ],
};
const archiveRows = { rows: [
  { scope: "P1", label: "Shepherd", text: "shipped the installer fixes", doneTs: NOW - 11 * 86400 },
] };

const STATE = () => ({
  toggle: !!document.getElementById("wl-liveonly"),
  rows: Array.from(document.querySelectorAll("#wl-active .wl-item")).map(function (r) {
    return (r.querySelector(".wl-txt") || r).textContent; }),
  chips: document.querySelectorAll("#wl-active .wl-live").length,
});

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser My List live-run check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate(() => { try { localStorage.clear(); } catch (e) { /* no storage */ } });
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => {
    worklistMode = true;
    document.body.classList.add("worklist-mode");
    window.ccWorklist(p); worklistPick("P1");
  }, payload);
  const lane = (l) => page.evaluate((x) => { wlLanePick(x); }, l);

  // 1. No toggle; every open row shows, each live-run one with its chip.
  const all = await page.evaluate(STATE);
  check("the ▶ live run toggle is gone", all.toggle === false);
  check("every open row shows  (rows=" + all.rows.length + ")", all.rows.length === 5);
  check("...the live-run ones with their ▶ chip  (chips=" + all.chips + ")", all.chips === 3);

  // 2. The lanes sort them: the [~] row and the ticked marked row wait on Adam; the open marked row is work.
  await lane("verify");
  const verify = await page.evaluate(STATE);
  check("To verify holds the [~] row and the ticked marked row  (" + verify.rows.join(" | ") + ")",
        verify.rows.length === 2 && verify.rows.indexOf("open the panel and look at the chip") >= 0
        && verify.rows.indexOf("shipped the probe (needs live run)") >= 0);
  check("...each still with its chip  (chips=" + verify.chips + ")", verify.chips === 2);
  await lane("todo");
  const todo = await page.evaluate(STATE);
  check("To do keeps the open marked row  (" + todo.rows.join(" | ") + ")",
        todo.rows.length === 3 && todo.rows.indexOf("deploy, then click Sync (needs live run)") >= 0);
  check("...with its chip  (chips=" + todo.chips + ")", todo.chips === 1);

  // 3. MASTER: the chips across projects; the hostile text stays text.
  await lane("verify");
  const master = await page.evaluate(() => { worklistPick("master"); return {
    rows: document.querySelectorAll("#wl-active .wl-item").length,
    chips: document.querySelectorAll("#wl-active .wl-live").length,
    html: document.getElementById("wl-active").innerHTML, pwned: window.__pwned === 1 }; });
  check("MASTER's To verify holds every project's [~] rows  (rows=" + master.rows + ")", master.rows === 3);
  check("...with their chips  (chips=" + master.chips + ")", master.chips === 3);
  check("a live-run row's text is still escaped", master.pwned === false && master.html.indexOf("<img src=x") < 0
        && master.html.indexOf("&lt;img") >= 0);

  // 4. The Archive: no toggle, no lanes, nothing filtered.
  const arch = await page.evaluate((a) => {
    worklistPick("archive");
    window.ccWorklistArchive(a);
    return { toggle: !!document.getElementById("wl-liveonly"),
             rows: document.querySelectorAll("#wl-active .wl-item").length };
  }, archiveRows);
  check("the Archive shows no toggle", arch.toggle === false);
  check("...and every archived row  (rows=" + arch.rows + ")", arch.rows === 1);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
