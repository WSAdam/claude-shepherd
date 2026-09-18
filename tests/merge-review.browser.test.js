// merge-review.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a real
// (headless Chromium) browser, fills the ready-to-merge review with a long summary and a long
// file list, and measures where the Merge button lands.
//
// 2026-09-15: "I shouldn't need to scroll down to be able to click merge". Cause: #d-merge grew
// with its summary, commits and files, and the dm-acts row (Merge / note / Not yet) sat under
// all of it -- a wordy request pushed the buttons off the panel. The review's BODY now has a
// max height and its own scroll bar; the buttons row sits outside it and stays put.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/merge-review.browser.test.js

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
  console.log("-- merge-review.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser merge-review check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
  process.exit(0);
}

// ---- capture the real panel (stubbed-hs load of claude-dashboard.lua) --------
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

// The request as Shepherd's live one read on 2026-09-15: a ten-line summary, a tests line,
// two commits and a file list -- plus a long file list, since a big unit ships many files.
const files = [];
for (let i = 0; i < 40; i++) files.push({ st: i % 3 ? "M" : "A", path: "src/module-" + i + "/some/deeper/file-" + i + ".lua" });
const review = { key: "k1", merge: {
  phase: "requested", sent: false, ready: true, queued: false, base: "main", ahead: 2,
  line: "⇡ ready to merge fix/installer-fixtures → main",
  stat: "6 files changed, 279 insertions(+), 54 deletions(-)",
  summary: "Fixes the ten installer bugs from the 2026-09-15 review plus the chmod glob: the pre-flight gate now runs before any copy, node is a named requirement, a symlinked settings.json keeps its link, a fully wired file in any layout is a no-op, object-valued groups are left intact with a warning, a low cc-approve.sh timeout is raised, a commented dofile doesn't count, a missing hook script fails the install, the installer suite no longer needs the host's rg/brew, and the Dock URL is percent-encoded. Each bug has a fixture in tests/install.test.sh or the new tests/install-hermetic.test.sh.",
  tests: "make lint && make test in the worktree: ALL GREEN (installer suite 119/119, hermetic 1/1)",
  commits: [{ h: "dfb0b18", s: "Ten installer fixes: gate before copy, node, symlinks, layouts, shapes, the Dock URL" },
            { h: "331632d", s: "Red fixtures for ten installer bugs from the 2026-09-15 review" }],
  files: files, problems: [],
  // 2026-09-17: the gate Shepherd ran itself adds a line with up to 15 lines of suite output --
  // it scrolls with the body like everything else, so the buttons must still stay in view.
  gate: { state: "failed", code: 2, command: "make lint && make test",
          tail: Array.from({ length: 15 }, (_, i) =>
            "FAIL - a fairly wordy behaviour-named check that failed on line " + (i + 1)).join("\n") },
  // 2026-09-18: the claim check adds a block under the gate -- more height in the body, and the
  // evidence quotes the session's own words, so it is also where markup would try to get in.
  claims: [{ claim: "tests were added", verdict: "flagged",
             evidence: "it says \"Each bug has a <img src=x onerror=window.__pwned=1> new fixture\", but no test or fixture path is among the 40 changed files" }],
} };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser merge-review check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  // Shepherd's default panel width; tall enough that nothing here is clipped by the viewport
  // itself -- the measurement is the review box's own geometry.
  const page = await browser.newPage({ viewport: { width: 580, height: 1400 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((r) => { selectedKey = r.key; renderDetail(); renderMerge(r); }, review);

  const box = await page.locator("#d-merge").boundingBox();
  const btn = await page.locator("#dm-merge").boundingBox();
  const hold = await page.locator("#dm-hold").boundingBox();
  check("the review box and its Merge button rendered", !!(box && btn && hold));
  if (box && btn && hold) {
    const offset = Math.round(btn.y - box.y);
    // 2026-09-15 unfixed: 361px / 362px / 392px with this fixture
    check("the Merge button sits within 280px of the review's top, however long the request is  (got=" + offset + "px)", offset <= 280);
    check("...and so does Not yet  (got=" + Math.round(hold.y - box.y) + "px)", hold.y - box.y <= 280);
    check("the review box itself is capped, not as tall as its content  (got=" + Math.round(box.height) + "px)", box.height <= 320);
  }
  const scrolls = await page.evaluate(() => {
    const b = document.querySelector("#d-merge .dm-body");
    return !!b && b.scrollHeight > b.clientHeight && getComputedStyle(b).overflowY === "auto";
  });
  check("the review's body scrolls on its own, so the whole request is still readable", scrolls);
  const inside = await page.evaluate(() => {
    const b = document.querySelector("#d-merge .dm-body");
    return !!b && !!b.querySelector("#dm-files") && !!b.querySelector("#dm-diff") && !b.querySelector("#dm-acts") && !b.querySelector("#dm-done");
  });
  check("the file list and the diff scroll with the body; the buttons rows sit outside it", inside);

  // ---- the claim check (2026-09-18): shown, warn-coloured, inert, and it holds nothing ----
  const claims = await page.evaluate(() => {
    const el = document.getElementById("dm-claims");
    if (!el) return null;
    const cs = getComputedStyle(el);
    const gate = getComputedStyle(document.getElementById("dm-gate"));
    return { text: el.textContent, flagged: el.classList.contains("c-flagged"), color: cs.color, gateColor: gate.color,
             kids: el.children.length, pwned: window.__pwned === 1,
             inBody: !!document.querySelector("#d-merge .dm-body #dm-claims"),
             mergeDisabled: document.getElementById("dm-merge").disabled };
  });
  check("the review shows the claim check", !!claims && claims.text.indexOf("tests were added") >= 0
    && claims.text.indexOf("no test or fixture path") >= 0);
  if (claims) {
    check("...as a hint, in so many words", claims.text.indexOf("a hint, not a gate") >= 0);
    check("...flagged in the warn colour, not the failed gate's red  (claims=" + claims.color + " gate=" + claims.gateColor + ")",
      claims.flagged && claims.color !== claims.gateColor);
    check("...the session's words arrive as text: no element was built from them, nothing ran", claims.kids === 0 && !claims.pwned);
    check("...inside the scrolling body", claims.inBody);
    check("WARN ONLY: a flagged claim leaves the Merge button enabled", claims.mergeDisabled === false);
  }
  const quiet = await page.evaluate((r) => {
    const calm = JSON.parse(JSON.stringify(r));
    calm.merge.claims = [{ claim: "tests were added", verdict: "couldntTell", evidence: "the summary makes no claim about tests (the diff touches 0 test paths)" }];
    renderMerge(calm);
    const el = document.getElementById("dm-claims");
    const out = { unknown: el.textContent, unknownFlagged: el.classList.contains("c-flagged") };
    delete calm.merge.claims;
    renderMerge(calm);
    out.none = el.textContent;
    return out;
  }, review);
  check("no claim reads couldn't tell, unflagged", quiet.unknown.indexOf("couldn't tell") >= 0 && !quiet.unknownFlagged);
  check("a review with no claim check at all (an older record) leaves the block empty", quiet.none === "");

  await browser.close();
  finish();
})().catch((e) => { console.log("FAIL - browser run crashed: " + e.message); process.exit(1); });
