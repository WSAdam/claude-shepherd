// detail-wants.browser.test.js - BEHAVIORAL fixture: the detail panel's "Wants:" box (and the
// "Why:"/"Doing:" line under it) is at most five lines tall and scrolls, measured in a real
// (headless Chromium) browser on the shipped panel.
//
// 2026-11-19, Adam: "instead of this giant ass red brick of wants are we able to compress that window
// to like 5 lines and add a scroll bar in there so it takes less space?" Cause: #d-pending and
// #d-activity were meant to clamp at 2 lines (display:-webkit-box + line-clamp), but renderDetail
// sets their inline display to "block", which drops the clamp, so a long pending command (a 1,800-
// character commit heredoc) filled the whole panel.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/detail-wants.browser.test.js

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
  console.log("-- detail-wants.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser Wants box check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
// The live case, shortened only by repetition: a commit heredoc held for approval.
const LONG = "cd \"/Users/adam/Programming/CB Sentinel Astro\" && git add -A && cat > $TMPDIR/msg-s2.txt <<'EOF' "
  + "Sync slice 2: the old app to b5c2149 (2026-11-04) Twenty-two upstream commits: the Elevate read walks every page, "
  + "asks only for what changed, spends no upload call on an answered case and paces its calls a second apart. ".repeat(12)
  + "EOF git commit -q -F $TMPDIR/msg-s2.txt && git log --oneline -3 && git push -q origin main 2>&1 | tail -2";
const WAITING = { key: "k1", name: "astro", label: "CB Sentinel Astro", status: "approval", editor: "kitty",
                  since: NOW - 60, updated: NOW, cwd: "/tmp/astro", gate: "waiting",
                  pending: { summary: LONG }, activity: "Bash: " + LONG };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser Wants box check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  // Adam's panel is narrow (about 450 css px), which is what makes the box tall
  const page = await browser.newPage({ viewport: { width: 460, height: 1400 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);

  await page.evaluate(() => {
    window.__measure = function (item) {
      window.ccUpdate([item]);
      selectedKey = item.key;
      renderDetail(); setDetailTab("activity", false);
      const m = {};
      ["d-pending", "d-activity"].forEach(function (id) {
        const el = document.getElementById(id);
        const cs = getComputedStyle(el);
        const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
        m[id] = { h: el.getBoundingClientRect().height, lh: lh, scrollH: el.scrollHeight, overflowY: cs.overflowY,
                  display: cs.display, text: el.textContent.length };
      });
      return m;
    };
  });

  const long = await page.evaluate((it) => window.__measure(it), WAITING);
  for (const id of ["d-pending", "d-activity"]) {
    const m = long[id];
    check(id + ": a long one is at most five lines tall  (h=" + m.h.toFixed(1) + " line=" + m.lh.toFixed(1) + ")",
          m.h > 0 && m.h <= m.lh * 5 + 1);
    check(id + ": ...and at least four, so it isn't clipped to a sliver", m.h >= m.lh * 4 - 1);
    check(id + ": ...it scrolls, with the whole text inside  (scroll " + m.scrollH + " > " + m.h.toFixed(0) + ", overflow-y " + m.overflowY + ")",
          m.scrollH > m.h + 1 && (m.overflowY === "auto" || m.overflowY === "scroll") && m.text > 1000);
  }

  // 2026-11-19 (round 4 #3): an Edit's change is drawn under Wants, capped at 14 lines, and scrolls
  const OLD = Array.from({ length: 40 }, (_, i) => "line " + i).join("\n");
  const NEW = OLD.replace("line 3", "line three").replace("line 30", "<b>line thirty</b>");
  const ch = await page.evaluate((it) => {
    window.ccUpdate([it]);
    selectedKey = it.key;
    renderDetail(); setDetailTab("activity", false);
    const el = document.getElementById("d-change");
    const cs = getComputedStyle(el);
    return { display: cs.display, h: el.getBoundingClientRect().height, scrollH: el.scrollHeight,
             lh: parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.4, bold: el.querySelectorAll("b").length,
             dels: el.querySelectorAll(".dc-del").length, adds: el.querySelectorAll(".dc-add").length };
  }, Object.assign({}, WAITING, { pending: { summary: "/tmp/astro/a.js", tool: "Edit",
      change: { kind: "edit", old: OLD, new: NEW, cut: false } }, activity: "Edit: /tmp/astro/a.js" }));
  check("an Edit's change shows under Wants  (display " + ch.display + ")", ch.display === "block");
  check("...with its removed and added lines  (" + ch.dels + " out, " + ch.adds + " in)", ch.dels === 2 && ch.adds === 2);
  check("...the change's own markup is text, never html", ch.bold === 0);
  check("...at most 14 lines tall, then it scrolls  (h=" + ch.h.toFixed(1) + " line=" + ch.lh.toFixed(1) + ")",
        ch.h <= ch.lh * 14 + 12 && ch.scrollH > ch.h + 1);

  const short = await page.evaluate((it) => window.__measure(Object.assign({}, it, {
    pending: { summary: "git status" }, activity: "Bash: git status" })), WAITING);
  for (const id of ["d-pending", "d-activity"]) {
    const m = short[id];
    check(id + ": a one-line one stays one line tall  (h=" + m.h.toFixed(1) + ")", m.h > 0 && m.h <= m.lh * 1.5);
  }

  await browser.close();
  finish();
})().catch((e) => { console.log("FAIL - " + String(e && e.stack || e)); process.exit(1); });
