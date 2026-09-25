// instances-select.browser.test.js - BEHAVIORAL fixture: Close selected in the Instances view,
// driven in the shipped panel in a real (headless Chromium) browser.
//
// 2026-09-25, Adam: "how and why do i have 37 open tabs for wgs ultra here when several have gone
// 43 or 22hrs since usage. can we find some way to clear them out ... with a checkbox". 34 merged
// batch-unit tabs had piled up (their bridge tags were lost, so no post-merge close ever ran) and
// Instances offered no way to close them. Each row now has a checkbox; Select finished checks what
// Lua marked finished; Close selected asks first, then sends the keys -- Lua re-vets every one.
// A card with two or more finished sessions says "N finished" and opens Instances with them checked.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/instances-select.browser.test.js

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
  console.log("-- instances-select.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser Close selected check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

const SK = "repo:/r/wgsUltra/.git";
const NOW = Math.floor(Date.now() / 1000);
// the wgsUltra shape, small: a merged unit (finished), a done chat (not finished yet), a working unit
function payload(extra) {
  const p = {
    stackKey: SK, stackName: "wgsUltra", mainRoot: "/r/wgsUltra", members: [
      { key: "u1", folder: "wgsUltra", branch: "main", isMainWt: true, status: "done", stale: true, since: NOW - 43 * 3600,
        selectable: true, finished: true, merge: { phase: "merged", line: "✓ merged fix/scan-page-title into main" } },
      { key: "c1", folder: "wgsUltra", branch: "main", isMainWt: true, status: "done", since: NOW - 3600,
        selectable: true },
      { key: "w1", folder: "listing-tip-matches", branch: "feat/listing-tip-matches", status: "working", since: NOW - 60,
        cleanWhy: "it isn't finished (working)" },
    ], worktrees: [], finishedN: 1,
  };
  return Object.assign(p, extra || {});
}

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser Close selected check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
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
  await page.evaluate((code) => { (0, eval)(code); }, update);

  const state = () => page.evaluate(() => {
    const boxes = {};
    document.querySelectorAll("#inst-body .in-ck").forEach(function (b) {
      boxes[b.getAttribute("data-ck")] = { checked: b.checked, disabled: b.disabled, title: b.title };
    });
    const bar = document.getElementById("inst-clean");
    return { boxes: boxes, bar: !!bar && bar.classList.contains("show"),
             selfin: (document.getElementById("inst-selfin") || {}).textContent,
             selfinOff: !!(document.getElementById("inst-selfin") || {}).disabled,
             closesel: (document.getElementById("inst-closesel") || {}).textContent,
             closeselOff: !!(document.getElementById("inst-closesel") || {}).disabled };
  });

  await page.evaluate((a) => { openInstancesFor(a.sk); window.ccInstances(a.p); }, { sk: SK, p: payload() });
  let s = await state();
  check("every session row has a checkbox", !!(s.boxes.u1 && s.boxes.c1 && s.boxes.w1));
  check("...a working unit's is disabled, saying why  (" + (s.boxes.w1 || {}).title + ")",
        s.boxes.w1 && s.boxes.w1.disabled === true && /working/.test(s.boxes.w1.title));
  check("...none is checked to begin with", !s.boxes.u1.checked && !s.boxes.c1.checked);
  check("the bar shows, with Select finished counting 1  (" + s.selfin + ")", s.bar === true && /\(1\)/.test(s.selfin));
  check("...and Close selected is off until something is checked", s.closeselOff === true);

  // a check survives the next push (Lua re-pushes whenever anything on the card changes)
  await page.evaluate(() => { document.querySelector('#inst-body .in-ck[data-ck="c1"]').click(); });
  check("clicking a checkbox never fires a row action",
        (await page.evaluate(() => window.__sent.map((m) => JSON.parse(m).a))).indexOf("focus") < 0);
  await page.evaluate((p) => { window.ccInstances(p); }, payload({ stackName: "wgsUltra (renamed)" }));
  s = await state();
  check("a checked row stays checked across a re-render", s.boxes.c1 && s.boxes.c1.checked === true);
  check("...and Close selected counts it  (" + s.closesel + ")", /\(1\)/.test(s.closesel) && s.closeselOff === false);

  await page.evaluate(() => { document.getElementById("inst-selfin").click(); });
  s = await state();
  check("Select finished checks the finished row", s.boxes.u1.checked === true);
  check("...keeps what was already checked", s.boxes.c1.checked === true);
  check("...and never a row that can't be closed", s.boxes.w1.checked === false);

  // a key that leaves the view drops out of the selection
  await page.evaluate((p) => { window.ccInstances(p); },
    Object.assign(payload(), { members: payload().members.filter((m) => m.key !== "c1") }));
  s = await state();
  check("a session that ends drops out of the selection  (" + s.closesel + ")", /\(1\)/.test(s.closesel));
  await page.evaluate((p) => { window.ccInstances(p); }, payload());

  // Close selected asks first; no sends nothing
  const declined = await page.evaluate(() => {
    window.__answer = false; window.__asked = []; window.__sent = [];
    document.getElementById("inst-closesel").click();
    return { asked: window.__asked.slice(), sent: window.__sent.slice() };
  });
  check("Close selected asks first, naming how many  (" + (declined.asked[0] || "") + ")",
        declined.asked.length === 1 && /Close 1 Claude tab\b/.test(declined.asked[0]));
  check("...saying no sends nothing", declined.sent.length === 0);
  const accepted = await page.evaluate(() => {
    window.__answer = true; window.__asked = []; window.__sent = [];
    document.getElementById("inst-closesel").click();
    const boxes = [];
    document.querySelectorAll("#inst-body .in-ck:checked").forEach(function (b) { boxes.push(b.getAttribute("data-ck")); });
    return { sent: window.__sent.map((m) => JSON.parse(m)), checked: boxes };
  });
  const cs = accepted.sent.filter((m) => m.a === "close-sessions");
  check("saying yes sends one close-sessions for this card", cs.length === 1 && cs[0].v === SK && accepted.sent.length === 1);
  check("...carrying exactly the checked keys  (" + (cs[0] && cs[0].text) + ")",
        cs.length === 1 && JSON.stringify(JSON.parse(cs[0].text).sort()) === JSON.stringify(["u1"]));
  check("...and the selection clears", accepted.checked.length === 0);

  // the card: "N finished" only from two up, and it opens Instances with them already checked
  const chip = await page.evaluate(() => ({
    three: stackAlsoHtml({ stackFinished: 3, stackAlso: [{ b: "ready", n: 27 }] }),
    one: stackAlsoHtml({ stackFinished: 1, stackAlso: [{ b: "ready", n: 27 }] }),
    none: stackAlsoHtml({ stackFinished: 2, stackAlso: [] }),
  }));
  check("a card with 3 finished sessions says so, as its own control  (" + chip.three + ")",
        /3 finished/.test(chip.three) && /data-nodbl/.test(chip.three) && /also: 27 ready for you/.test(chip.three));
  check("...one finished session is no pile: no chip", !/finished/.test(chip.one));
  check("...and the chip shows even with nothing else to say", /2 finished/.test(chip.none));
  await page.evaluate((a) => { closeInstances(); openInstancesFor(a.sk, false, true); window.ccInstances(a.p); }, { sk: SK, p: payload() });
  s = await state();
  check("opened from the chip, the finished rows arrive checked", s.boxes.u1.checked === true && s.boxes.c1.checked === false);
  await page.evaluate(() => { document.querySelector('#inst-body .in-ck[data-ck="u1"]').click(); });
  await page.evaluate((p) => { window.ccInstances(p); }, payload({ stackName: "again" }));
  s = await state();
  check("...once: a later push doesn't re-check what Adam unchecked", s.boxes.u1.checked === false);

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
