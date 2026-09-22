// detail-chrome.browser.test.js - BEHAVIORAL fixture: Appearance > "Hide the detail panel's
// controls", driven in a real (headless Chromium) browser so the CASCADE is what is tested,
// not the source text.
//
// 2026-09-22, Adam: he does not want to see the detail panel's buttons or nudge box. The
// catch is that hiding them outright takes away the panel's ONLY Deny -- the hotkey approves
// the front-most session and there is no Deny binding -- so a waiting gate has to bring
// Approve/Deny/the reason/Stop back on its own, and hide them again once it is answered.
//
// The rules are pure CSS over a body class plus a state class renderDetail stamps on
// #d-actions each tick; #d-actions' markup is pinned byte for byte by tests/ui.test.lua, so
// nothing may be added to it. That makes SOURCE ORDER the whole game: `body.mctl #d-controls
// { display:flex }` has equal specificity, so a hiding rule written above it loses.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/detail-chrome.browser.test.js

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
  console.log("-- detail-chrome.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser detail-chrome check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
// One plain working session, in a kitty window so nothing is locked out as shared/remote.
const WORKING = { key: "k1", name: "alpha", label: "alpha", status: "working", editor: "kitty",
                  since: NOW - 60, updated: NOW, cwd: "/tmp/alpha" };
// The rows the toggle is about, and the ones a waiting gate has to bring back.
const HIDDEN_ROWS = ["#d-actions", "#d-controls", "#nudge-row", "#tpl-menu", "#nudge-chip"];
const GATE_KEEPS = ["b-approve", "b-deny", "deny-note", "b-stop"];
const GATE_DROPS = ["b-jump", "b-auto", "b-clear", "b-compact", "b-improve", "b-score", "b-timeline", "b-export"];

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser detail-chrome check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1200 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);

  // Helper installed in the page: push one item, select it, render, and read back what
  // is actually on screen. `ap` goes through applyAppearance, the real settings path.
  await page.evaluate(() => {
    window.__show = function (item, ap) {
      applyAppearance(ap || {});
      window.ccUpdate([item]);
      selectedKey = item.key;
      renderDetail();
      const disp = {};
      ["#d-actions", "#d-controls", "#nudge-row", "#tpl-menu", "#nudge-chip", "#d-ask", "#d-plan",
       "#b-jump", "#b-approve", "#b-deny", "#deny-note", "#b-stop", "#b-auto", "#b-clear",
       "#b-compact", "#b-improve", "#b-score", "#b-timeline", "#b-export"].forEach(function (sel) {
        const el = document.querySelector(sel);
        disp[sel] = el ? getComputedStyle(el).display : "(missing)";
      });
      const sep = document.querySelector("#d-actions .sep");
      disp[".sep"] = sep ? getComputedStyle(sep).display : "(missing)";
      return { disp: disp, body: document.body.className,
               dact: (document.getElementById("d-actions") || {}).className,
               approve: (document.getElementById("b-approve") || {}).textContent };
    };
  });

  // ---- 1. baseline: nothing hidden, model controls on, everything where it always was ----
  const base = await page.evaluate((it) => window.__show(it, { modelControls: true }), WORKING);
  check("baseline: the panel carries no nochrome class  (" + base.body + ")",
        base.body.indexOf("nochrome") < 0);
  check("baseline: the action row is there  (" + base.disp["#d-actions"] + ")",
        base.disp["#d-actions"] === "flex");
  check("baseline: the model-control row is there  (" + base.disp["#d-controls"] + ")",
        base.disp["#d-controls"] === "flex");
  check("baseline: the nudge box is there  (" + base.disp["#nudge-row"] + ")",
        base.disp["#nudge-row"] === "flex");

  // ---- 2. the toggle on, a plain working session: the whole bottom chrome goes ----
  const hid = await page.evaluate((it) => window.__show(it, { modelControls: true, hideDetailChrome: true }), WORKING);
  check("hidden: the body carries the class  (" + hid.body + ")", hid.body.indexOf("nochrome") >= 0);
  HIDDEN_ROWS.forEach(function (sel) {
    check("hidden: " + sel + " is gone  (" + hid.disp[sel] + ")", hid.disp[sel] === "none");
  });
  // The trap: model controls are ON here, so `body.mctl #d-controls { display:flex }` is
  // matching too. Only source order makes the hiding rule win.
  check("hidden: ...#d-controls stays gone even with Model controls turned on",
        hid.disp["#d-controls"] === "none");
  check("hidden: no state class is stamped on a plain working session  (" + hid.dact + ")",
        String(hid.dact).indexOf("dc-gate") < 0 && String(hid.dact).indexOf("dc-err") < 0);

  // #d-ask and #d-plan are CONTENT, above the cut line -- a held question keeps its own
  // answer buttons and the plan box keeps showing the session's TODOs.
  const content = await page.evaluate((it) => {
    const asking = Object.assign({}, it, { askHeld: true, ask_nonce: "n1",
      pending: { ask: [{ header: "Approach", question: "Which way?", options: [{ label: "A", description: "first" }, { label: "B", description: "second" }] }] } });
    applyAppearance({ hideDetailChrome: true });
    window.ccUpdate([asking]);
    selectedKey = asking.key;
    renderDetail(); setDetailTab("activity", false); renderAsk(asking);
    window.ccPlan(asking.key, { todos: [{ content: "write the test", status: "in_progress" }] });
    return { ask: getComputedStyle(document.getElementById("d-ask")).display,
             plan: getComputedStyle(document.getElementById("d-plan")).display,
             opts: document.querySelectorAll("#d-ask .ask-opt").length };
  }, WORKING);
  check("hidden: a held question is still on screen  (" + content.ask + ")", content.ask !== "none");
  check("hidden: ...with its answer buttons  (opts=" + content.opts + ")", content.opts >= 2);
  check("hidden: the plan / TODO box is still on screen  (" + content.plan + ")", content.plan !== "none");

  // ---- 3. a waiting gate brings back exactly Approve / Deny / the reason / Stop ----
  const gate = await page.evaluate((it) => window.__show(Object.assign({}, it, { gate: "waiting" }),
    { modelControls: true, hideDetailChrome: true }), WORKING);
  check("waiting: the action row comes back  (" + gate.disp["#d-actions"] + ")",
        gate.disp["#d-actions"] === "flex");
  check("waiting: ...stamped as a gate  (" + gate.dact + ")", String(gate.dact).indexOf("dc-gate") >= 0);
  GATE_KEEPS.forEach(function (id) {
    check("waiting: #" + id + " is available  (" + gate.disp["#" + id] + ")", gate.disp["#" + id] !== "none");
  });
  GATE_DROPS.forEach(function (id) {
    check("waiting: #" + id + " stays hidden  (" + gate.disp["#" + id] + ")", gate.disp["#" + id] === "none");
  });
  check("waiting: the row's spacer stays hidden too  (" + gate.disp[".sep"] + ")",
        gate.disp[".sep"] === "none");
  check("waiting: the nudge box is still gone  (" + gate.disp["#nudge-row"] + ")",
        gate.disp["#nudge-row"] === "none");

  // ---- 4. the same session once the gate is answered: the chrome hides itself again ----
  const answered = await page.evaluate((it) => window.__show(Object.assign({}, it, { gate: "none" }),
    { modelControls: true, hideDetailChrome: true }), WORKING);
  check("answered: the action row goes away again  (" + answered.disp["#d-actions"] + ")",
        answered.disp["#d-actions"] === "none");
  check("answered: ...and the gate stamp is off  (" + answered.dact + ")",
        String(answered.dact).indexOf("dc-gate") < 0);

  // ---- 5. an errored session with no gate: Continue alone ----
  const err = await page.evaluate((it) => window.__show(Object.assign({}, it, { status: "error" }),
    { hideDetailChrome: true }), WORKING);
  check("errored: the action row comes back  (" + err.disp["#d-actions"] + ")",
        err.disp["#d-actions"] === "flex");
  check("errored: ...stamped as an error  (" + err.dact + ")", String(err.dact).indexOf("dc-err") >= 0);
  check("errored: the one button reads Continue  (" + err.approve + ")", err.approve === "Continue");
  check("errored: ...and is the only one showing  (" + err.disp["#b-approve"] + ")",
        err.disp["#b-approve"] !== "none");
  ["b-deny", "b-stop", "deny-note", "b-jump", "b-clear"].forEach(function (id) {
    check("errored: #" + id + " stays hidden  (" + err.disp["#" + id] + ")", err.disp["#" + id] === "none");
  });

  // A waiting gate outranks the error: an errored session Adam can still Deny gets the
  // full gate set, not the lone Continue.
  const both = await page.evaluate((it) => window.__show(Object.assign({}, it, { status: "error", gate: "waiting" }),
    { hideDetailChrome: true }), WORKING);
  check("errored + waiting: the gate wins  (" + both.dact + ")",
        String(both.dact).indexOf("dc-gate") >= 0 && String(both.dact).indexOf("dc-err") < 0);
  check("errored + waiting: ...so Deny is reachable  (" + both.disp["#b-deny"] + ")",
        both.disp["#b-deny"] !== "none");

  // ---- 6. turning it back off restores the panel exactly ----
  const off = await page.evaluate((it) => window.__show(it, { modelControls: true }), WORKING);
  check("off again: the class is dropped  (" + off.body + ")", off.body.indexOf("nochrome") < 0);
  HIDDEN_ROWS.filter(function (s) { return s !== "#tpl-menu" && s !== "#nudge-chip"; }).forEach(function (sel) {
    check("off again: " + sel + " is back  (" + off.disp[sel] + ")", off.disp[sel] !== "none");
  });
  GATE_DROPS.forEach(function (id) {
    check("off again: #" + id + " is back  (" + off.disp["#" + id] + ")", off.disp["#" + id] !== "none");
  });

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
