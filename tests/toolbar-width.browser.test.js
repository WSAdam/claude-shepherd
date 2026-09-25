// toolbar-width.browser.test.js - BUG FIXTURE: the top toolbar at a narrow panel (2026-09-25), in
// the shipped panel in a real (headless Chromium) browser.
//
// 2026-09-25: at a 400px-wide panel #bar was 2px wider than the panel (42px at 360), so the whole
// panel scrolled sideways -- #bar .right's six controls never shrink (326px) and the "Claude
// sessions" title wrapped to two lines but couldn't go below its 58px min-content. Geometry, not
// screenshots: every control stays inside the viewport, the title keeps to one line or hides, and
// below the controls' own width they wrap onto a right-aligned second row with the ☰ menu still
// opening on screen.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/toolbar-width.browser.test.js

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
  console.log("-- toolbar-width.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser toolbar width check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

// The toolbar's geometry at the panel's current width.
function measure() {
  const r = (el) => el.getBoundingClientRect();
  const title = document.querySelector("#bar .t");
  const shown = getComputedStyle(title).display !== "none" && r(title).width > 0;
  let lines = 0;
  if (shown) {
    const range = document.createRange();
    range.selectNodeContents(title);
    const tops = {};
    for (const rect of range.getClientRects()) if (rect.width > 0) tops[Math.round(rect.top)] = true;
    lines = Object.keys(tops).length;
  }
  const controls = Array.from(document.querySelectorAll("#bar .right > *")).map((el) => {
    const b = r(el);
    return { id: el.id, left: b.left, right: b.right, top: b.top, bottom: b.bottom };
  });
  // group the controls into rows: a control starts a new row when it doesn't overlap the last one vertically
  const rows = [];
  for (const c of controls) {
    const row = rows.find((rw) => c.top < rw.bottom && c.bottom > rw.top);
    if (row) { row.right = Math.max(row.right, c.right); row.top = Math.min(row.top, c.top); row.bottom = Math.max(row.bottom, c.bottom); }
    else rows.push({ top: c.top, bottom: c.bottom, right: c.right });
  }
  const bar = r(document.getElementById("bar"));
  return {
    vw: window.innerWidth, pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    titleShown: shown, titleLines: lines, titleClipped: shown && title.scrollWidth > title.clientWidth,
    controls: controls, rows: rows.map((rw) => rw.right), barRight: bar.right,
    padRight: parseFloat(getComputedStyle(document.getElementById("bar")).paddingRight),
  };
}

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser toolbar width check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  for (const width of [300, 360, 400, 440, 580]) {
    const page = await browser.newPage({ viewport: { width: width, height: 900 } });
    await page.addInitScript(() => {
      window.webkit = { messageHandlers: { cc: { postMessage: () => {} } } };
    });
    await page.goto("file://" + path.join(out, "panel.html"));
    await page.evaluate((code) => { (0, eval)(code); }, update);
    const W = " @" + width + "px";
    const g = await page.evaluate(measure);

    check("the toolbar holds its six controls" + W, g.controls.length === 6);
    const outside = g.controls.filter((c) => c.left < -0.5 || c.right > g.vw + 0.5).map((c) => c.id + " " + Math.round(c.left) + "–" + Math.round(c.right));
    check("every toolbar control is fully inside the panel" + (outside.length ? " (" + outside.join(", ") + ")" : "") + W, outside.length === 0);
    if (width >= 360) check("the panel doesn't scroll sideways (" + g.pageOverflow + "px over)" + W, g.pageOverflow <= 0);
    else if (g.pageOverflow > 0) console.log("info - something at " + width + "px still overflows by " + g.pageOverflow + "px (not the toolbar)");
    check("the title never wraps to a second line (" + g.titleLines + " lines)" + W, !g.titleShown || g.titleLines === 1);
    const edge = g.vw - g.padRight;
    check("every row of controls keeps to the right edge (" + g.rows.map(Math.round).join(", ") + " vs " + edge + ")" + W,
      g.rows.every((right) => Math.abs(right - edge) <= 1));

    if (width === 580) {
      check("at the default width the title shows, whole, on one line" + W, g.titleShown && g.titleLines === 1 && !g.titleClipped);
      check("...with all six controls in one row" + W, g.rows.length === 1);
    }
    if (width === 400) {
      check("too narrow for the title: it hides" + W, !g.titleShown);
      check("...and the controls still share one row" + W, g.rows.length === 1);
    }
    if (width === 300) {
      check("narrower than the controls: they wrap onto a second row" + W, g.rows.length >= 2);
      await page.click("#menu-btn");
      const m = await page.evaluate(() => {
        const el = document.getElementById("toolmenu"), b = el.getBoundingClientRect();
        return { shown: getComputedStyle(el).display !== "none", left: b.left, right: b.right, top: b.top, bottom: b.bottom,
                 vw: window.innerWidth, vh: window.innerHeight };
      });
      check("the ☰ menu opens when the controls wrap" + W, m.shown);
      check("...and lies inside the panel (" + Math.round(m.left) + "–" + Math.round(m.right) + " of " + m.vw + ")" + W,
        m.left >= -0.5 && m.right <= m.vw + 0.5 && m.top >= -0.5 && m.bottom <= m.vh + 0.5);
    }
    await page.close();
  }
  await browser.close();
  fs.rmSync(out, { recursive: true, force: true });
  fs.rmSync(home, { recursive: true, force: true });
  finish();
})().catch((e) => { console.log("FAIL - " + (e && e.stack || e)); failed++; finish(); });
