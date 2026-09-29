// pins-layout.browser.test.js - BEHAVIORAL: pinned links' chips in a real (headless Chromium)
// browser (2026-09-29, build program unit 31). Replays the SHIPPED panel HTML (the
// card-layout.browser.test.js harness) with a card carrying the full 8 pins, long labels included,
// and measures: every chip stays inside its card and the card never scrolls sideways (cards and
// contrast themes); the one-line bar and dots themes leave the chips to the detail panel; a click
// on a chip sends open-pin with the card's key and the chip's number and selects nothing; and the
// detail panel shows the same chips for the selected session.
//
// Geometry, not screenshots. Needs Playwright (the isolate runner's copy, or
// CC_PLAYWRIGHT=<module path>); without it this prints an explicit skip.
// Usage: node tests/pins-layout.browser.test.js

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
  console.log("-- pins-layout.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser pinned-links check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

const now = Math.floor(Date.now() / 1000);
const PINS = [
  { url: "http://localhost:5173/isolate/card/empty", kind: "http", label: "Preview of the empty card state, dark theme" },
  { url: "https://github.com/org/repo/pull/1234", kind: "http", label: "PR #1234" },
  { url: "file:///r/repo/docs/controls.md", kind: "file", label: "controls.md" },
  { url: "file:///r/repo/spec/product/a-very-long-spec-file-name-that-goes-on.md", kind: "file",
    label: "a-very-long-spec-file-name-that-goes-on.md" },
  { url: "http://localhost:8000/", kind: "http", label: "localhost:8000" },
  { url: "https://example.com/report", kind: "http", label: "example.com/report" },
  { url: "file:///r/repo/TODO.md", kind: "file", label: "TODO.md" },
  { url: "https://gitlab.com/o/r/-/merge_requests/7", kind: "http", label: "PR #7" },
];
const PINNED = { key: "pinned", session_id: "pinned", name: "pinned-repo", status: "working",
  since: now - 30, updated: now, editor: "vscode", context_frac: 0.4, context_tokens: 80000, pins: PINS };
const PLAIN = { key: "plain", session_id: "plain", name: "plain-repo", status: "done",
  since: now - 60, updated: now - 60, editor: "vscode", context_frac: 0.2, context_tokens: 40000 };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser pinned-links check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 900 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);

  // Render the two cards under <theme> and measure the pinned one's chips.
  const measure = (theme) => page.evaluate(([th, items]) => {
    document.body.className = document.body.className.replace(/(^|\s)theme-\S+/g, "").trim();
    document.body.classList.add("theme-" + th);
    lastGridSig = null;
    window.ccUpdate(items);
    const t = document.querySelector('.tile[data-key="pinned"]');
    if (!t) return null;
    const tb = t.getBoundingClientRect();
    const chips = Array.prototype.slice.call(t.querySelectorAll(".pin-chip"));
    const shown = chips.filter((c) => getComputedStyle(c).display !== "none");
    const boxes = shown.map((c) => c.getBoundingClientRect());
    return {
      count: chips.length, shown: shown.length,
      tileLeft: tb.left, tileRight: tb.right, tileW: tb.width,
      maxRight: boxes.length ? Math.max.apply(null, boxes.map((b) => b.right)) : 0,
      minLeft: boxes.length ? Math.min.apply(null, boxes.map((b) => b.left)) : 0,
      widest: boxes.length ? Math.max.apply(null, boxes.map((b) => b.width)) : 0,
      rows: new Set(boxes.map((b) => Math.round(b.top))).size,
      overflowX: t.scrollWidth - t.clientWidth,
      plainChips: document.querySelectorAll('.tile[data-key="plain"] .pin-chip').length,
    };
  }, [theme, [PINNED, PLAIN]]);

  for (const theme of ["cards", "contrast"]) {
    const g = await measure(theme);
    check(theme + ": the card rendered", !!g);
    if (!g) continue;
    check(theme + ": all 8 chips are on the card  (shown=" + g.shown + ")", g.shown === 8);
    check(theme + ": every chip stays inside the card  (chips right=" + Math.round(g.maxRight)
      + " card right=" + Math.round(g.tileRight) + ", left " + Math.round(g.minLeft) + " vs " + Math.round(g.tileLeft) + ")",
      g.maxRight <= g.tileRight + 0.5 && g.minLeft >= g.tileLeft - 0.5);
    check(theme + ": a long label is cut, not the card widened  (widest chip=" + Math.round(g.widest)
      + " card=" + Math.round(g.tileW) + ")", g.widest < g.tileW);
    check(theme + ": the chips wrap onto more rows instead  (rows=" + g.rows + ")", g.rows >= 2);
    check(theme + ": the card never scrolls sideways  (overflow=" + g.overflowX + "px)", g.overflowX <= 0);
    check(theme + ": a card without pins has no chips", g.plainChips === 0);
  }
  for (const theme of ["bar", "dots"]) {
    const g = await measure(theme);
    check(theme + ": the one-line layout leaves the chips to the detail panel  (shown=" + (g && g.shown) + ")",
      !!g && g.count === 8 && g.shown === 0);
  }

  // A click on a chip: open-pin with the card's key and the chip's number, and no select.
  await measure("cards");
  await page.evaluate(() => { window.__sent = []; });
  await page.click('.tile[data-key="pinned"] .pin-chip[data-pin="2"]');
  const sent = await page.evaluate(() => window.__sent.map((m) => JSON.parse(m)));
  const open = sent.filter((m) => m.a === "open-pin");
  check("a click on a chip sends open-pin for that card and chip  (sent=" + JSON.stringify(open) + ")",
    open.length === 1 && open[0].v === "pinned" && open[0].text === "2");
  check("...and never the link itself", JSON.stringify(sent).indexOf("github.com") < 0);
  check("...nor a select or a jump", !sent.some((m) => m.a === "select" || m.a === "focus" || m.a === "focus-group"));

  // The detail panel shows the selected session's chips.
  await page.click('.tile[data-key="pinned"] .name');
  const panel = await page.evaluate(() => {
    const el = document.getElementById("d-pins");
    return el ? { display: getComputedStyle(el).display, chips: el.querySelectorAll(".pin-chip").length } : null;
  });
  check("the detail panel shows the selected session's chips  (" + JSON.stringify(panel) + ")",
    !!panel && panel.display !== "none" && panel.chips === 8);
  await page.evaluate(() => { window.__sent = []; });
  await page.click('#d-pins .pin-chip[data-pin="3"]');
  const sent2 = await page.evaluate(() => window.__sent.map((m) => JSON.parse(m)).filter((m) => m.a === "open-pin"));
  check("a chip in the detail panel opens for the selected session  (sent=" + JSON.stringify(sent2) + ")",
    sent2.length === 1 && sent2[0].v === "pinned" && sent2[0].text === "3");
  await page.click('.tile[data-key="plain"] .name');
  const empty = await page.evaluate(() => getComputedStyle(document.getElementById("d-pins")).display);
  check("...and none for a session without pins  (display=" + empty + ")", empty === "none");

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished  (" + String(e && e.message).split("\n")[0] + ")", false); finish(); });
