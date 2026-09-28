// readme-screenshots.js - regenerate the README's screenshots (docs/img/*.png) from FIXTURES,
// never the live panel: it loads the SHIPPED claude-dashboard.lua under a stubbed hs
// (capture-panel.lua, as the browser tests do), replays the panel HTML in headless Chromium and
// feeds it the made-up sessions below through the panel's own window.ccUpdate. Nothing here is a
// real session, path or person, because the repo is public.
//   node tests/support/readme-screenshots.js [out-dir]     (default: docs/img)
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>).

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const OUT = path.resolve(process.argv[2] || path.join(ROOT, "docs", "img"));

function loadPlaywright() {
  const tries = [process.env.CC_PLAYWRIGHT,
    path.join(os.homedir(), ".isolate-runner", "node_modules", "playwright"), "playwright"].filter(Boolean);
  for (const t of tries) { try { return require(t); } catch (e) { /* next */ } }
  return null;
}
const pw = loadPlaywright();
if (!pw) { console.error("❌ Playwright not found (set CC_PLAYWRIGHT or install the isolate runner)"); process.exit(1); }

const cap = fs.mkdtempSync(path.join(os.tmpdir(), "cc-panel-"));
const home = fs.mkdtempSync(path.join(os.tmpdir(), "cc-home-"));
execFileSync("lua", [path.join(ROOT, "tests/support/capture-panel.lua"), ROOT, cap],
  { env: Object.assign({}, process.env, { HOME: home }), stdio: ["ignore", "pipe", "inherit"] });
const update = fs.readFileSync(path.join(cap, "update.js"), "utf8");

const now = Math.floor(Date.now() / 1000);
const base = { editor: "vscode", updated: now };
// One card per state a reader should recognise: needs you, a held question, ready to merge,
// working (a project with worktrees), errored and finished.
const FLEET = [
  Object.assign({}, base, { key: "f1", session_id: "f1", name: "checkout-api", status: "approval", since: now - 42,
    pending: { tool: "Bash", summary: "npm test -- --watch" }, needsYou: "needs", needsYouSource: "approval",
    context_frac: 0.38 }),
  Object.assign({}, base, { key: "f2", session_id: "f2", name: "web-app", status: "working", since: now - 610,
    branch: "feat/search-filters", isMainWt: false, stackSize: 3, stackKey: "web-app", stackRank: 1,
    stackAlso: [{ b: "done", n: 1 }, { b: "working", n: 1 }], bg_active: true, bg_count: 2, context_frac: 0.57 }),
  Object.assign({}, base, { key: "f3", session_id: "f3", name: "docs-site", status: "done", since: now - 95,
    branch: "docs/getting-started", isMainWt: false, stackSize: 2, stackKey: "docs-site", stackRank: 1,
    merge: { phase: "requested", ready: true, line: "⇡ ready to merge docs/getting-started → main" },
    needsYou: "needs", needsYouSource: "merge", context_frac: 0.21 }),
  Object.assign({}, base, { key: "f4", session_id: "f4", name: "mobile-client", status: "approval", since: now - 18,
    askHeld: true, askLine: "❓ asks you: Which date format should the export use?", needsYou: "needs",
    needsYouSource: "ask", context_frac: 0.44 }),
  Object.assign({}, base, { key: "f5", session_id: "f5", name: "data-jobs", status: "working", since: now - 1500,
    sessTitle: "nightly import retries", queue: 2, context_frac: 0.83 }),
  Object.assign({}, base, { key: "f6", session_id: "f6", name: "infra", status: "done", since: now - 3600,
    context_frac: 0.12 }),
];

// The footer: plan windows, the fleet's tokens and the commit lines, all made up.
const iso = (secs) => new Date((now + secs) * 1000).toISOString();
const USAGE = { fleet: { real: 4820000, output: 612000, total: 51200000, costPriced: true, costUsd: 38.4 },
  official: { five_hour: { utilization: 34, resets_at: iso(2 * 3600 + 900) },
              seven_day: { utilization: 61, resets_at: iso(3 * 86400 + 5 * 3600) } } };
const monday = now - 3 * 86400;
const COMMITS = { today: { commits: 6, add: 412, del: 97 }, week: { commits: 23, add: 3100, del: 870 },
  lastWeekSoFar: { commits: 17, add: 2200, del: 640 },
  days: [5, 7, 5, 6, 0, 0, 0].map((n, i) => ({ commits: n, add: n * 120, del: n * 30, dayEpoch: monday + i * 86400,
    isToday: i === 3, future: i > 3 })), repos: [], recent: [], emails: [] };

const files = [
  { st: "A", path: "docs/getting-started.md" }, { st: "M", path: "README.md" },
  { st: "A", path: "tests/docs-links.test.sh" }, { st: "M", path: "tests/run.sh" },
];
const REVIEW = { key: "f3", merge: {
  phase: "requested", sent: false, ready: true, queued: false, base: "main", ahead: 2,
  line: "⇡ ready to merge docs/getting-started → main",
  stat: "4 files changed, 212 insertions(+), 38 deletions(-)",
  summary: "Adds a getting-started guide and links it from the README. A new link check keeps every relative link in the docs resolving; it is wired into the suite.",
  tests: "make test in the worktree: all green",
  commits: [{ h: "4e1c9a2", s: "Getting-started guide, linked from the README" },
            { h: "b07d315", s: "Link check for the docs, red before the guide existed" }],
  files: files, problems: [],
  gate: { state: "passed", code: 0, command: "make test", tail: "ok   - every relative link resolves\n-- 214 run, 0 failed --" },
  claims: [{ claim: "tests were added", verdict: "ok", evidence: "tests/docs-links.test.sh" }],
} };

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await pw.chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 560, height: 640 }, deviceScaleFactor: 2 });
  await page.addInitScript(() => {
    window.webkit = { messageHandlers: { cc: { postMessage: () => {} } } };
  });
  await page.goto("file://" + path.join(cap, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((items) => { window.ccUpdate(items); }, FLEET);
  await page.evaluate((a) => { window.ccUsage(a.u); window.ccCommits(a.c); }, { u: USAGE, c: COMMITS });
  await page.waitForTimeout(300);
  // The panel down to the end of its footer (the commit lines), not the empty viewport under it.
  const foot = await page.evaluate(() => {
    const rows = document.querySelectorAll(".cf-row");
    return rows.length ? Math.ceil(rows[rows.length - 1].getBoundingClientRect().bottom) : 628;
  });
  await page.screenshot({ path: path.join(OUT, "panel.png"),
    clip: { x: 0, y: 0, width: 560, height: Math.min(640, foot + 12) } });
  console.log("✅ wrote " + path.relative(ROOT, path.join(OUT, "panel.png")));

  await page.setViewportSize({ width: 560, height: 900 });
  await page.evaluate((r) => {
    Object.assign(findItem(r.key), r);
    selectedKey = r.key; renderGrid(); renderDetail();
  }, REVIEW);
  await page.waitForTimeout(300);
  // The review box and the detail header row above it (name, branch, status).
  const detail = await page.locator("#d-merge").boundingBox();
  const top = Math.max(0, Math.floor(detail.y) - 38);
  await page.screenshot({ path: path.join(OUT, "merge-review.png"),
    clip: { x: 0, y: top, width: 560, height: Math.ceil(detail.y + detail.height) + 10 - top } });
  console.log("✅ wrote " + path.relative(ROOT, path.join(OUT, "merge-review.png")));
  await browser.close();
})().catch((e) => { console.error("❌ " + e.message); process.exit(1); });
