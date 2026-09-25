// commits-layout.browser.test.js - BEHAVIORAL fixture: the commit stats under the fleet block
// (2026-09-25), in the shipped panel in a real (headless Chromium) browser.
//
// Adam: "a block of lines below the fleet section ... daily and recent mon-sun github commits, as
// well as a secondary number ... a total day total week line and then if we click it it opens a
// drawer holding all of the additional details". Geometry, not screenshots: at the panel's narrow
// width the week line (count, lines, pace) and its Mon–Sun strip fit without pushing the page
// sideways; the lines sit between the plan bars and the detail panel; a click opens the drawer,
// which stays open through the 1s tick and the 60s push, scrolls inside itself, and asks Lua for a
// fresh count; a project row expands its commits.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/commits-layout.browser.test.js

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
  console.log("-- commits-layout.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser commit stats check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

// A heavy real week (this machine's on 2026-09-25): the longest numbers the lines will carry.
const NOW = Math.floor(Date.now() / 1000);
const MON = NOW - 4 * 86400;
function days(counts) {
  return counts.map((n, i) => ({ commits: n, add: n * 300, del: n * 20, dayEpoch: MON + i * 86400,
    isToday: i === 4 || undefined, future: i > 4 || undefined }));
}
const week = days([8, 95, 70, 36, 32, 0, 0]);
const payload = {
  ts: NOW - 60,
  today: { commits: 32, add: 21130, del: 2072 },
  week: { commits: 241, add: 94068, del: 6988 },
  lastWeekSoFar: { commits: 89, add: 30000, del: 2000 },
  days: week,
  repos: [
    { root: "/Users/me/Programming/ChargebackSentinel", name: "ChargebackSentinel", today: { commits: 20, add: 9000, del: 900 },
      week: { commits: 121, add: 28918, del: 3471 }, days: week,
      commits: [{ sha: "6f24201", at: NOW - 600, subject: "Docs: the ReceiptSource family and the portal/processor axes, spelled out in full so the line must truncate", add: 120, del: 4 }] },
    { root: "/Users/me/Programming/sms-bot", name: "sms-bot", today: { commits: 0, add: 0, del: 0 },
      week: { commits: 0, add: 0, del: 0 }, days: days([0, 0, 0, 0, 0, 0, 0]), commits: [] },
  ],
  recent: Array.from({ length: 15 }, (_, i) => ({ repo: "ChargebackSentinel", sha: "a" + i, at: NOW - i * 900,
    subject: "A commit subject long enough to need the ellipsis in a narrow panel, number " + i, add: 40, del: 3 })),
  emails: ["me@example.invalid"],
  repoCount: 2,
  lookbackDays: 14,
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser commit stats check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  for (const width of [400, 580]) {
    const page = await browser.newPage({ viewport: { width: width, height: 900 } });
    await page.addInitScript(() => {
      window.__sent = [];
      window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
      try { localStorage.removeItem("cc-commitsOpen"); } catch (e) { /* file:// may refuse */ }
    });
    await page.goto("file://" + path.join(out, "panel.html"));
    await page.evaluate((code) => { (0, eval)(code); }, update);
    const W = " @" + width + "px";

    const hidden = await page.evaluate(() => getComputedStyle(document.getElementById("commit-foot")).display);
    check("before the first count the block takes no space" + W, hidden === "none");
    // The toolbar's own sideways overflow (the #theme select pokes 2px past 400px) is not this
    // block's: judge the block against the page as it was before it rendered.
    const base = await page.evaluate(() => Math.max(0, document.documentElement.scrollWidth - window.innerWidth));

    await page.evaluate((p) => window.ccCommits(p), payload);
    const g = await page.evaluate(() => {
      const foot = document.getElementById("commit-foot");
      const rows = foot.querySelectorAll(".cf-row");
      const wk = rows[1], strip = wk && wk.querySelector(".cf-strip"), val = wk && wk.querySelector(".cf-val");
      const r = (el) => el.getBoundingClientRect();
      const usage = r(document.getElementById("usage-foot")), detail = r(document.getElementById("detail"));
      return {
        rows: rows.length, pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
        rowOverflow: wk.scrollWidth - wk.clientWidth, stripRight: r(strip).right, rowRight: r(wk).right,
        stripW: r(strip).width, bars: strip.querySelectorAll(".cf-bar").length, valW: r(val).width,
        valClipped: val.scrollWidth > val.clientWidth + 1, footTop: r(foot).top, usageBottom: usage.bottom,
        detailTop: detail.height ? detail.top : Infinity, footBottom: r(foot).bottom,
        todayBar: strip.querySelector(".cf-bar.today") ? r(strip.querySelector(".cf-bar.today > i")).height : 0,
      };
    });
    check("two lines: Today and This week" + W, g.rows === 2);
    check("the block adds no sideways scroll" + W, g.pageOverflow <= base);
    check("the week line doesn't overflow its row" + W, g.rowOverflow <= 0);
    check("the Mon–Sun strip stays inside the row, all seven bars" + W, g.stripRight <= g.rowRight + 0.5 && g.bars === 7 && g.stripW >= 40);
    check("the week's text keeps real room beside the strip (" + Math.round(g.valW) + "px)" + W, g.valW >= 200);
    if (width >= 580) check("at the default width the whole week line reads without an ellipsis" + W, !g.valClipped);
    check("the block sits under the plan bars" + W, g.footTop >= g.usageBottom - 0.5);
    check("...and above the detail panel" + W, g.footBottom <= g.detailTop + 0.5);
    check("today's bar is drawn" + W, g.todayBar >= 2);

    // open the drawer: it asks for a fresh count and scrolls inside itself
    await page.click("#commit-foot .cf-row");
    const d = await page.evaluate(() => {
      const dr = document.querySelector("#commit-foot .cf-drawer");
      return { open: !!dr, sent: window.__sent.slice(), maxH: dr ? parseFloat(getComputedStyle(dr).maxHeight) : 0,
               overflowY: dr ? getComputedStyle(dr).overflowY : "", h: dr ? dr.getBoundingClientRect().height : 0,
               pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
               stored: (function () { try { return localStorage.getItem("cc-commitsOpen"); } catch (e) { return "n/a"; } })() };
    });
    check("a click opens the drawer" + W, d.open);
    check("...and asks Lua for a fresh count" + W, d.sent.some((m) => m.indexOf('"a":"commits-open"') >= 0));
    check("the drawer scrolls inside itself, capped under half the window" + W, d.overflowY === "auto" && d.h <= 900 * 0.45 + 1);
    check("the open drawer adds no sideways scroll" + W, d.pageOverflow <= base);
    check("the open state is remembered" + W, d.stored === "1" || d.stored === "n/a");

    // the 1s tick and the 60s push both leave it open
    await page.evaluate((code) => { (0, eval)(code); }, update);
    await page.evaluate((p) => window.ccCommits(p), payload);
    check("the drawer survives the tick and the push" + W,
      await page.evaluate(() => !!document.querySelector("#commit-foot .cf-drawer")));

    // a project row expands its commits
    await page.click("#commit-foot .cf-repo");
    const sub = await page.evaluate(() => {
      const s = document.querySelector("#commit-foot .cf-sub .cf-subj");
      return s ? { text: s.textContent, clipped: s.scrollWidth > s.clientWidth } : null;
    });
    check("a project row lists its commits" + W, sub !== null && sub.text.indexOf("ReceiptSource") >= 0);
    check("...a long subject ellipsizes rather than wrapping the row" + W, sub !== null && sub.clipped);

    // and a click on the lines closes it again
    await page.click("#commit-foot .cf-row");
    check("a second click closes the drawer" + W,
      await page.evaluate(() => !document.querySelector("#commit-foot .cf-drawer")));

    await page.evaluate(() => window.ccCommits({ enabled: false }));
    check("commits.enabled=false hides the block" + W,
      await page.evaluate(() => getComputedStyle(document.getElementById("commit-foot")).display === "none"));
    await page.close();
  }
  await browser.close();
  fs.rmSync(out, { recursive: true, force: true });
  fs.rmSync(home, { recursive: true, force: true });
  finish();
})().catch((e) => { console.log("FAIL - " + (e && e.stack || e)); failed++; finish(); });
