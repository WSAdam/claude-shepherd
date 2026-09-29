// working-on.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a real
// (headless Chromium) browser and measures the working-on line (2026-09-29, build program unit 10).
//
// The line carries two chips (the tool running, the skill in use) inside the card's one-line meta
// span, which clips with an ellipsis. Geometry, not screenshots: the chips and the label stay on
// ONE line inside the card at Shepherd's default panel width, a long label is clipped rather than
// wrapped or pushed out of the card, and the detail header shows the same line under the name.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like card-layout.browser.test.js.
// Usage: node tests/working-on.browser.test.js

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
  console.log("-- working-on.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser working-on check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
const BUSY = {
  key: "busy", session_id: "busy", name: "busy-repo", status: "working",
  since: now - 95, updated: now, editor: "vscode", tool_name: "Bash", tool_started_at: now - 4,
  sessTitle: "reworking the fleet grid",
  workingOn: { label: "Make the merge queue survive a Hammerspoon rel…", tool: "Bash", toolSecs: 4, skill: "workflow-authoring" },
  context_frac: 0.4, context_tokens: 80000,
};
const QUIET = {
  key: "quiet", session_id: "quiet", name: "quiet-repo", status: "done",
  since: now - 300, updated: now - 300, editor: "vscode",
  workingOn: { label: "unit feat/working-on-label" },
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser working-on check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 900 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((items) => { window.ccUpdate(items); }, [BUSY, QUIET]);

  const m = await page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect();
      return { x: b.x, y: b.y, w: b.width, h: b.height, right: b.right, bottom: b.bottom }; };
    const tile = (k) => document.querySelector('.tile[data-key="' + k + '"]');
    const pack = (k) => {
      const t = tile(k); if (!t) return null;
      const meta = t.querySelector(".meta");
      return { tile: r(t), meta: r(meta), tool: r(t.querySelector(".wo-tool")), skill: r(t.querySelector(".wo-skill")),
               label: r(t.querySelector(".wo-label")), text: meta ? meta.textContent : "",
               lineH: meta ? parseFloat(getComputedStyle(meta).lineHeight) || 15 : 0 };
    };
    return { busy: pack("busy"), quiet: pack("quiet") };
  });
  const b = m.busy, q = m.quiet;
  check("the busy card renders its tool and skill chips and its label", b && b.tool && b.skill && b.label);
  check("the label comes first, then the tool, then the skill",
        b && b.tool && b.skill && b.label && b.label.x < b.tool.x && b.tool.x < b.skill.x);
  check("...ahead of the chat title  (" + (b && b.text) + ")", b && b.text.indexOf("Make the merge queue") === 0
        && b.text.indexOf("reworking the fleet grid") > b.text.indexOf("workflow-authoring"));
  // 2026-09-29: the first run, with the chat title leading, clipped the whole working-on line away
  // on this doubled-up card (the ellipsis cuts the END of the line); the second, with the chips
  // leading, clipped the label. On a default-width card the label is what must show.
  check("a doubled-up card shows its label from the line's start  (label.x="
        + (b && b.label && Math.round(b.label.x)) + " meta.x=" + (b && b.meta && Math.round(b.meta.x)) + " meta.right="
        + (b && b.meta && Math.round(b.meta.right)) + ")",
        b && b.label && b.meta && Math.abs(b.label.x - b.meta.x) < 1 && b.label.x + 100 < b.meta.right);
  check("the meta line stays one line with its chips  (h=" + (b && b.meta && b.meta.h) + ")",
        b && b.meta && b.meta.h <= b.lineH * 1.6);
  check("...and inside its card  (meta.right=" + (b && b.meta && b.meta.right) + " tile.right=" + (b && b.tile.right) + ")",
        b && b.meta && b.meta.right <= b.tile.right + 0.5);
  check("the chips sit on the meta line, not below it",
        b && b.tool && b.meta && b.tool.y >= b.meta.y - 1 && b.tool.bottom <= b.meta.bottom + 1);
  check("a card with a label only has no chips", q && q.label && !q.tool && !q.skill);
  check("...and reads its unit  (" + (q && q.text) + ")", q && q.text.indexOf("unit feat/working-on-label") >= 0);

  // the detail header shows the same line under the name
  await page.evaluate(() => { selectTile("busy"); });
  if (process.env.CC_SHOT) await page.screenshot({ path: process.env.CC_SHOT });
  const d = await page.evaluate(() => {
    const el = document.getElementById("d-working"), head = document.getElementById("d-head");
    if (!el || !head) return null;
    const b = el.getBoundingClientRect(), h = head.getBoundingClientRect();
    return { shown: getComputedStyle(el).display !== "none", text: el.textContent, top: b.top, headBottom: h.bottom,
             chips: el.querySelectorAll(".wo-chip").length, h: b.height };
  });
  check("the detail header shows it", d && d.shown && d.text.indexOf("Make the merge queue") >= 0 && d.chips === 2);
  check("...under the name row, on one line", d && d.top >= d.headBottom - 1 && d.h < 30);
  await page.evaluate(() => { selectTile("quiet"); });
  const dq = await page.evaluate(() => document.getElementById("d-working").textContent);
  check("...and follows the selection", dq.indexOf("unit feat/working-on-label") >= 0 && dq.indexOf("Bash") < 0);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished (" + String(e && e.message).split("\n")[0] + ")", false); finish(); });
