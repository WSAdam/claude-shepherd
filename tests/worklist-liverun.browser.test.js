// worklist-liverun.browser.test.js - BEHAVIORAL fixture: My List's ▶ live run filter, driven in a
// real (headless Chromium) browser.
//
// 2026-09-29 (build program unit 37): some TODO items can only be checked by a live run -- deploy,
// then look -- and My List showed them mixed in with everything else. core.parseTodoFile flags
// `- [~]` lines and `(needs live run)` / `(live check)` lines (liveRun = true); each such row shows
// a ▶ live run chip, and a ▶ live run toggle beside the filter box keeps only those rows.
//
// Pinned here:
//   * the toggle appears only where there is a live-run item to show (or while it is on), and
//     reads how many there are;
//   * on, it keeps only the live-run rows, on a project tab and on MASTER, and the count reads
//     N / M shown; it combines with the text filter; off, everything comes back;
//   * the Done drawer stays UNFILTERED (as with the text filter);
//   * ✓ Mark all N done steps aside while it is on (wlOpenCount counts the unfiltered list);
//   * the Archive, whose rows carry no flag, never shows it and is never filtered by it;
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
  console.log("skip - real-browser My List live-run filter check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
// P1: two open live-run lines (a [~] one and a marked [x] one the automation claims done), two
// plain open lines, and a done live-run line so the Done drawer has something to stay unfiltered
// about. P2 has one live-run line with hostile text, for MASTER and escaping. P3 has none.
const payload = {
  generic: [{ id: "g1", text: "Renew the domain", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd", items: [
      { id: "a1", text: "open the panel and look at the chip", src: "todo", liveRun: true, ts: NOW },
      { id: "a2", text: "Write the changelog", src: "todo", ts: NOW },
      { id: "a3", text: "shipped the probe (needs live run)", src: "todo", liveRun: true, fileDone: true, ts: NOW },
      { id: "a4", text: "Renew the certificate", ts: NOW },
      { id: "d1", text: "deployed and clicked (live check)", src: "todo", liveRun: true, done: true, doneTs: NOW - 100 },
      { id: "d2", text: "Tidy the README", done: true, doneTs: NOW - 200 },
    ] },
    { key: "P2", label: "Chargeback", items: [
      { id: "b1", text: "<img src=x onerror=window.__pwned=1> check the refund page", src: "todo", liveRun: true, ts: NOW },
      { id: "b2", text: "Refund statement layout", ts: NOW },
    ] },
    { key: "P3", label: "Quiet", items: [
      { id: "c1", text: "nothing live here", src: "todo", ts: NOW },
    ] },
  ],
};
const archiveRows = { rows: [
  { scope: "P1", label: "Shepherd", text: "shipped the installer fixes", doneTs: NOW - 11 * 86400 },
] };

const STATE = () => {
  const btn = document.getElementById("wl-liveonly");
  const mb = document.getElementById("wl-markall");
  return {
    there: !!btn,
    shown: !!btn && btn.style.display !== "none",
    on: !!btn && btn.classList.contains("on"),
    label: btn ? btn.textContent : "",
    rows: Array.from(document.querySelectorAll("#wl-active .wl-item")).map(function (r) {
      return (r.querySelector(".wl-txt") || r).textContent; }),
    chips: document.querySelectorAll("#wl-active .wl-live").length,
    count: (document.getElementById("wl-search-count") || {}).textContent,
    markall: mb ? mb.style.display : "(none)",
    empty: ((document.querySelector("#wl-active .wl-empty") || {}).textContent) || "",
  };
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser My List live-run filter check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => {
    worklistMode = true;
    document.body.classList.add("worklist-mode");
    window.ccWorklist(p); worklistPick("P1");
  }, payload);

  // 1. Off: every open row, each live-run one with its chip; the toggle offers the open live ones.
  const off = await page.evaluate(STATE);
  check("My List has a ▶ live run toggle", off.there === true);
  check("...outside every node the render rewrites", await page.evaluate(() => {
    const el = document.getElementById("wl-liveonly");
    return !!el && !["wl-scopes", "wl-active", "wl-done", "wl-mdone"].some(function (id) {
      const n = document.getElementById(id); return !!(n && n.contains(el)); });
  }));
  check("...shown on a tab with live-run items  (display shown=" + off.shown + ")", off.shown === true);
  check("...reading how many are open  (" + off.label + ")", off.label.indexOf("▶ live run") >= 0 && /\b2\b/.test(off.label));
  check("...and off to start with", off.on === false);
  check("off: every open row shows  (rows=" + off.rows.length + ")", off.rows.length === 4);
  check("...the live-run ones with their chip  (chips=" + off.chips + ")", off.chips === 2);
  check("...and no count", off.count === "");

  // 2. On: only the live-run rows, the count, Mark all out of the way, the Done drawer untouched.
  await page.evaluate(() => { document.getElementById("wl-liveonly").click(); });
  const on = await page.evaluate(STATE);
  check("on: the toggle reads as on", on.on === true);
  check("on: only the live-run rows stay  (rows=" + on.rows.join(" | ") + ")", on.rows.length === 2
        && on.rows[0].indexOf("open the panel") >= 0 && on.rows[1].indexOf("shipped the probe") >= 0);
  check("...and the count says how many of how many  (" + on.count + ")", on.count === "2 / 4 shown");
  check("...and Mark all steps aside  (display=" + on.markall + ")", on.markall === "none");
  const drawer = await page.evaluate(() => {
    worklistToggleDone();
    const n = document.querySelectorAll("#wl-done .wl-item").length;
    worklistToggleDone();
    return n;
  });
  check("...and the Done drawer is NOT filtered  (rows=" + drawer + ")", drawer === 2);

  // 3. It combines with the text filter.
  const both = await page.evaluate(() => {
    document.getElementById("wl-search").value = "probe";
    renderWorklist();
    return document.querySelectorAll("#wl-active .wl-item").length;
  });
  check("on + a text filter: both must match  (rows=" + both + ")", both === 1);
  await page.evaluate(() => { document.getElementById("wl-search").value = ""; renderWorklist(); });

  // 4. MASTER: the rollup filtered across projects; the hostile text stays text.
  const master = await page.evaluate(() => { worklistPick("master"); return {
    rows: document.querySelectorAll("#wl-active .wl-item").length,
    tags: Array.from(document.querySelectorAll("#wl-active .wl-tag")).map(function (t) { return t.textContent; }),
    count: (document.getElementById("wl-search-count") || {}).textContent,
    html: document.getElementById("wl-active").innerHTML, pwned: window.__pwned === 1,
    label: document.getElementById("wl-liveonly").textContent }; });
  check("MASTER on: only the live-run rows across projects  (rows=" + master.rows + ")", master.rows === 3);
  check("...from both projects  (" + master.tags.join("|") + ")", master.tags.indexOf("Shepherd") >= 0 && master.tags.indexOf("Chargeback") >= 0);
  check("...with the count  (" + master.count + ")", master.count === "3 / 8 shown");
  check("...and the toggle counts every project's open live runs  (" + master.label + ")", /\b3\b/.test(master.label));
  check("a live-run row's text is still escaped", master.pwned === false && master.html.indexOf("<img src=x") < 0
        && master.html.indexOf("&lt;img") >= 0);

  // 5. A tab with none, while on: the toggle stays so it can be turned off; the list says why it's empty.
  const quiet = await page.evaluate((S) => { worklistPick("P3"); return (0, eval)("(" + S + ")")(); }, STATE.toString());
  check("a tab with no live runs, while on: the toggle stays to be turned off", quiet.shown === true && quiet.on === true);
  check("...and the empty list reads as a filter  (" + quiet.empty + ")", /matches the filter/i.test(quiet.empty));

  // 6. The Archive's rows carry no flag: the toggle isn't offered there and filters nothing.
  const arch = await page.evaluate((a) => {
    worklistPick("archive");
    window.ccWorklistArchive(a);
    const btn = document.getElementById("wl-liveonly");
    return { shown: btn.style.display !== "none", rows: document.querySelectorAll("#wl-active .wl-item").length,
             count: (document.getElementById("wl-search-count") || {}).textContent };
  }, archiveRows);
  check("the Archive never offers the toggle", arch.shown === false);
  check("...and isn't filtered by it  (rows=" + arch.rows + ")", arch.rows === 1);
  check("...nor counted as filtered  ('" + arch.count + "')", arch.count === "");

  // 7. Off again: everything is back, and a tab with no live runs doesn't offer the toggle.
  const back = await page.evaluate((S) => {
    worklistPick("P1");
    document.getElementById("wl-liveonly").click();
    const p1 = (0, eval)("(" + S + ")")();
    worklistPick("P3");
    const p3 = (0, eval)("(" + S + ")")();
    return { p1: p1, p3: p3 };
  }, STATE.toString());
  check("off again: every open row is back  (rows=" + back.p1.rows.length + ")", back.p1.rows.length === 4 && back.p1.on === false);
  check("...Mark all is back", back.p1.markall === "");
  check("...and the count blanks", back.p1.count === "");
  check("a tab with no live-run items doesn't offer the toggle", back.p3.shown === false);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
