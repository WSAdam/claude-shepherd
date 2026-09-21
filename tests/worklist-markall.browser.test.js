// worklist-markall.browser.test.js - BEHAVIORAL fixture: "Mark all done" in the shipped
// panel, driven in a real (headless Chromium) browser.
//
// 2026-09-21, Adam: "I have a shitload of unchecked stuff in my list to check off, it takes
// forever to process through them." His claude-instance-manager tab held 307 unchecked items
// and every one was its own click, round trip and write of the whole store. Marking the tab
// is one operation.
//
// It is also the one destructive-feeling button in My List -- Clear ships with no
// confirmation at all -- so this pins that it ASKS first, that saying no does nothing at all,
// and that the count in the question is the number of items that would actually change.
// On MASTER (a rollup of every project's open work) the question says so, because the answer
// reaches every project's list, not one tab's.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/worklist-markall.browser.test.js

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
  console.log("-- worklist-markall.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser mark-all check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
function mk(prefix, open, done) {
  const out = [];
  for (let i = 1; i <= open; i++) out.push({ id: prefix + "a" + i, text: prefix + " to do " + i, ts: NOW - i });
  for (let i = 1; i <= done; i++) out.push({ id: prefix + "d" + i, text: prefix + " done " + i, ts: NOW - 999, done: true, doneTs: NOW - i });
  return out;
}
const payload = {
  generic: mk("g", 2, 0),
  projects: [{ key: "P1", label: "Shepherd", items: mk("p", 7, 5) },
             { key: "P2", label: "Chargeback", items: mk("q", 3, 1) }],
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser mark-all check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
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
  await page.evaluate((p) => { worklistMode = true; window.ccWorklist(p); worklistPick("P1"); }, payload);

  const btn = await page.evaluate(() => {
    const b = document.getElementById("wl-markall");
    // The panel's own container isn't laid out in this harness, so offsetParent is null for
    // everything -- assert the display renderWorklist actually sets on the button.
    return b ? { there: true, shown: b.style.display !== "none", text: b.textContent } : { there: false };
  });
  check("the tab has a Mark all done button", btn.there === true);
  check("...it is visible on a tab with open items", btn.shown === true);
  check("...and it names how many it would mark  (" + btn.text + ")",
        String(btn.text || "").indexOf("7") >= 0);

  // Saying no does nothing at all -- not a message, not a local change.
  const declined = await page.evaluate(() => {
    window.__answer = false; window.__asked = []; window.__sent = [];
    document.getElementById("wl-markall").click();
    return { asked: window.__asked.slice(), sent: window.__sent.slice(),
             active: document.querySelectorAll("#wl-active .wl-item").length };
  });
  check("clicking it asks first  (" + (declined.asked[0] || "") + ")", declined.asked.length === 1);
  check("...and the question says how many  (7)", String(declined.asked[0] || "").indexOf("7") >= 0);
  check("...saying no sends nothing", declined.sent.length === 0);
  check("...and changes nothing  (active=" + declined.active + ")", declined.active === 7);

  // Saying yes sends exactly one message, naming THIS tab.
  const accepted = await page.evaluate(() => {
    window.__answer = true; window.__asked = []; window.__sent = [];
    document.getElementById("wl-markall").click();
    return { sent: window.__sent.map(function (s) { try { return JSON.parse(s); } catch (e) { return {}; } }) };
  });
  const msg = (accepted.sent || []).filter(function (m) { return m.a === "worklist-mark-all"; });
  check("saying yes sends one mark-all for this tab", msg.length === 1 && msg[0].v === "P1");
  check("...and sends nothing else", accepted.sent.length === 1);

  // Lua answers with the real count; the panel says what happened.
  const flashed = await page.evaluate((p) => {
    const marked = JSON.parse(JSON.stringify(p));
    marked.projects[0].items.forEach(function (it) { it.done = true; it.doneTs = it.doneTs || 1; });
    window.ccWorklist(marked);
    window.wlMarkedAll(7);
    return { active: document.querySelectorAll("#wl-active .wl-item").length,
             flash: (document.getElementById("wl-todoflash") || {}).textContent,
             shown: document.getElementById("wl-markall").style.display !== "none" };
  }, payload);
  check("the tab empties once Lua answers  (active=" + flashed.active + ")", flashed.active === 0);
  check("...the panel says how many were marked  (" + flashed.flash + ")",
        String(flashed.flash || "").indexOf("7") >= 0);
  check("...and the button goes away with nothing left to mark", flashed.shown === false);

  // MASTER: the answer reaches every project, so the question has to say so.
  const master = await page.evaluate((p) => {
    window.ccWorklist(p);
    worklistPick("master");
    const b = document.getElementById("wl-markall");
    const visible = !!b && b.style.display !== "none";
    window.__answer = true; window.__asked = []; window.__sent = [];
    if (b) b.click();
    return { visible: visible, text: b ? b.textContent : "", asked: window.__asked.slice(),
             sent: window.__sent.map(function (s) { try { return JSON.parse(s); } catch (e) { return {}; } }) };
  }, payload);
  check("MASTER offers it too", master.visible === true);
  check("...counting every project's open items  (" + master.text + ")",
        String(master.text || "").indexOf("12") >= 0);
  check("...and its question warns it covers every project  (" + (master.asked[0] || "") + ")",
        /every project|all projects/i.test(String(master.asked[0] || "")));
  const mm = (master.sent || []).filter(function (m) { return m.a === "worklist-mark-all"; });
  check("...and it sends one mark-all for master", mm.length === 1 && mm[0].v === "master");

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
