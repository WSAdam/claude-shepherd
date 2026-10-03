// worklist-runner.browser.test.js - BEHAVIORAL fixture: Run selected in My List, driven in a real
// (headless Chromium) browser against the shipped panel.
//
// 2026-10-03 (mining round 2, unit D3b): on a project's My List tab, ▶ Run… lets Adam pick open
// items and Run selected sends them to Lua, which works through them one at a time in fresh sessions.
//
// Pinned here:
//   * ▶ Run… shows on a project tab with something that can run, never on Generic, MASTER or the
//     Archive, and not while the tab's run is going;
//   * picking: nothing is preselected (TODO.md lines included); an item that can't run has a disabled
//     box saying why; a row click picks instead of opening the item; the done checkboxes step aside;
//   * Run selected (N) sends the tab and the picked ids in the TAB's order, and nothing else; Cancel
//     sends nothing; switching tabs ends the picking;
//   * the run bar: what runs now, Resume on a paused run, Stop (asks first), close on an ended one --
//     each message names only the tab; every word from a session or a file is escaped;
//   * a done item checked off by a run shows "✓ by run"; unchecking it drops that at once.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it this
// prints an explicit skip, like the other My List browser tests.
// Usage: node tests/worklist-runner.browser.test.js

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
  console.log("-- worklist-runner.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser My List runner check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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
const WHY = "its box is already ticked in its file -- verify it yourself";
const base = () => ({
  generic: [{ id: "g1", text: "Renew the domain", ts: NOW }],
  projects: [
    { key: "P1", label: "Shepherd", runWhy: { t3: WHY },
      items: [
        { id: "o1", text: "my own job", ts: NOW },
        { id: "t1", text: "a TODO.md line", src: "todo", srcText: "a TODO.md line", ts: NOW },
        { id: "t3", text: "ticked in the file", src: "todo", srcText: "ticked in the file", fileDone: true, ts: NOW },
        { id: "x1", text: "<b>bold</b> job", ts: NOW },
        { id: "d1", text: "checked by a run", done: true, doneTs: NOW - 60, doneBy: "run:r1a2b3c4d" },
        { id: "d2", text: "checked by Adam", done: true, doneTs: NOW - 90 },
      ] },
    { key: "P2", label: "Quiet", runWhy: { q1: WHY }, items: [{ id: "q1", text: "only ticked ones", fileDone: true, src: "todo", ts: NOW }] },
  ],
});

const VIEW = () => {
  const sel = document.getElementById("wl-runsel"), go = document.getElementById("wl-rungo");
  const cancel = document.getElementById("wl-runcancel"), bar = document.getElementById("wl-runbar");
  const rows = Array.from(document.querySelectorAll("#wl-active .wl-item")).map(function (r) {
    const pick = r.querySelector(".wl-rpick");
    return { text: (r.querySelector(".wl-txt") || r).textContent, pick: !!pick, picked: !!(pick && pick.checked),
             disabled: !!(pick && pick.disabled), title: pick ? (pick.getAttribute("title") || "") : "",
             doneBox: !!r.querySelector(".wl-cb") };
  });
  const shown = function (el) { return !!el && el.style.display !== "none"; };
  return { selThere: !!sel, sel: shown(sel), go: shown(go), goText: go ? go.textContent : "", goDisabled: go ? go.disabled : null,
           cancel: shown(cancel), bar: shown(bar), barText: bar ? bar.textContent : "", barHtml: bar ? bar.innerHTML : "", rows: rows };
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser My List runner check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1000 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.__confirm = true;
    window.confirm = () => window.__confirm;
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((p) => {
    worklistMode = true;
    document.body.classList.add("worklist-mode");
    window.ccWorklist(p); worklistPick("P1");
  }, base());
  const view = () => page.evaluate(VIEW);

  // 1. The button, on a project tab with something to run.
  let v = await view();
  check("My List has a ▶ Run… button", v.selThere === true);
  check("...shown on a project tab with open items that can run", v.sel === true);
  check("...no picking yet: no Run selected, no Cancel, no pick boxes", v.go === false && v.cancel === false
        && v.rows.every(function (r) { return !r.pick; }));
  check("...and no run bar without a run", v.bar === false);

  // 2. Picking.
  await page.evaluate(() => { window.__sent = []; document.getElementById("wl-runsel").click(); });
  v = await view();
  check("▶ Run… starts picking: Run selected and Cancel show, the button steps aside", v.go === true && v.cancel === true && v.sel === false);
  check("...nothing is preselected, a TODO.md line included", v.rows.length === 4 && v.rows.every(function (r) { return r.pick && !r.picked; }));
  check("...Run selected says 0 and can't be clicked  (" + v.goText + ")", /\(0\)/.test(v.goText) && v.goDisabled === true);
  const t3 = v.rows.filter(function (r) { return r.text === "ticked in the file"; })[0] || {};
  check("...an item that can't run has a disabled box saying why", t3.disabled === true && t3.title.indexOf("already ticked") >= 0);
  check("...the done checkboxes step aside while picking", v.rows.every(function (r) { return !r.doneBox; }));
  const picked = await page.evaluate(() => {
    const rowOf = function (txt) { return Array.from(document.querySelectorAll("#wl-active .wl-item")).filter(function (r) {
      return (r.querySelector(".wl-txt") || {}).textContent === txt; })[0]; };
    const modalBefore = document.getElementById("wl-modal").classList.contains("open");
    rowOf("my own job").querySelector(".wl-txt").click();                  // a row click picks it
    const box = rowOf("a TODO.md line").querySelector(".wl-rpick");       // ...and so does its box
    box.click();
    rowOf("ticked in the file").querySelector(".wl-txt").click();          // can't run: a click does nothing
    return { modalBefore: modalBefore, modal: document.getElementById("wl-modal").classList.contains("open"), sent: window.__sent.slice() };
  });
  v = await view();
  check("a row click picks the row instead of opening it", picked.modal === picked.modalBefore
        && (v.rows.filter(function (r) { return r.text === "my own job"; })[0] || {}).picked === true);
  check("...its box picks it too", (v.rows.filter(function (r) { return r.text === "a TODO.md line"; })[0] || {}).picked === true);
  check("...an item that can't run isn't picked by a click", (v.rows.filter(function (r) { return r.text === "ticked in the file"; })[0] || {}).picked === false);
  check("...Run selected counts them  (" + v.goText + ")", /\(2\)/.test(v.goText) && v.goDisabled === false);
  check("...and picking sends nothing", picked.sent.length === 0);

  // 3. Run selected: the tab and the picked ids, in the tab's order.
  const goMsg = await page.evaluate(() => { window.__sent = []; document.getElementById("wl-rungo").click(); return window.__sent.slice(); });
  const gm = goMsg.length === 1 ? JSON.parse(goMsg[0]) : {};
  check("Run selected sends worklist-run for this tab  (" + goMsg.join(" ") + ")", gm.a === "worklist-run" && gm.v === "P1");
  check("...with the picked ids in the tab's order", gm.text === JSON.stringify(["o1", "t1"]));
  v = await view();
  check("...and the picking ends", v.go === false && v.cancel === false && v.rows.every(function (r) { return !r.pick; }));

  // 4. Cancel sends nothing; switching tabs ends the picking.
  const cancelled = await page.evaluate((S) => {
    window.__sent = [];
    document.getElementById("wl-runsel").click();
    const first = document.querySelector("#wl-active .wl-rpick:not([disabled])"); if (first) first.click();
    document.getElementById("wl-runcancel").click();
    const afterCancel = (0, eval)("(" + S + ")")();
    document.getElementById("wl-runsel").click();
    worklistPick("generic"); worklistPick("P1");
    const afterSwitch = (0, eval)("(" + S + ")")();
    return { sent: window.__sent.slice(), afterCancel: afterCancel, afterSwitch: afterSwitch };
  }, VIEW.toString());
  check("Cancel sends nothing and ends the picking", cancelled.sent.length === 0 && cancelled.afterCancel.go === false
        && cancelled.afterCancel.rows.every(function (r) { return !r.pick; }));
  check("switching tabs ends the picking", cancelled.afterSwitch.go === false && cancelled.afterSwitch.rows.every(function (r) { return !r.pick; }));
  const esc1 = await page.evaluate(() => document.getElementById("wl-active").innerHTML);
  check("an item's text is escaped", esc1.indexOf("<b>bold</b>") < 0 && esc1.indexOf("&lt;b&gt;bold") >= 0);

  // 5. Where the button isn't.
  const elsewhere = await page.evaluate((S) => {
    const f = (0, eval)("(" + S + ")");
    worklistPick("generic"); const g = f();
    worklistPick("master"); const m = f();
    worklistPick("archive"); window.ccWorklistArchive({ rows: [] }); const a = f();
    worklistPick("P2"); const q = f();
    worklistPick("P1");
    return { g: g.sel, m: m.sel, a: a.sel, q: q.sel };
  }, VIEW.toString());
  check("never on Generic", elsewhere.g === false);
  check("never on MASTER", elsewhere.m === false);
  check("never on the Archive", elsewhere.a === false);
  check("not on a tab where nothing open can run", elsewhere.q === false);

  // 6. ✓ by run on an item a run checked off; unchecking drops it at once.
  const byRun = await page.evaluate(() => {
    if (!worklistDoneOpen) worklistToggleDone();
    const rowOf = function (txt) { return Array.from(document.querySelectorAll("#wl-done .wl-item")).filter(function (r) {
      return (r.querySelector(".wl-txt") || {}).textContent === txt; })[0]; };
    const a = rowOf("checked by a run"), b = rowOf("checked by Adam");
    const chip = a && a.querySelector(".wl-byrun");
    const res = { chip: chip ? chip.textContent : "", title: chip ? chip.getAttribute("title") : "", adam: !!(b && b.querySelector(".wl-byrun")) };
    window.__sent = [];
    a.querySelector(".wl-cb").click();
    const it = wlScopeItems("P1").filter(function (x) { return x.id === "d1"; })[0];
    res.afterDone = it.done; res.afterBy = it.doneBy; res.sent = window.__sent.slice();
    return res;
  });
  check("a done item a run checked off shows ✓ by run  (" + byRun.chip + ")", byRun.chip === "✓ by run");
  check("...its tooltip names the run", byRun.title.indexOf("r1a2b3c4d") >= 0);
  check("...an item Adam checked shows nothing of the kind", byRun.adam === false);
  check("unchecking it works as usual (worklist-toggle) and drops the run mark at once", byRun.afterDone === false
        && byRun.afterBy === undefined && byRun.sent.length === 1 && JSON.parse(byRun.sent[0]).a === "worklist-toggle");

  // 7. The run bar.
  const RUNNING = { id: "r1a2b3c4d", phase: "running", cur: 2, total: 3, done: 1, canStop: true, canResume: false,
    items: [{ n: 1, text: "a TODO.md line", state: "done" }, { n: 2, text: "<i>my</i> own job", state: "open" },
            { n: 3, text: "third", state: "queued" }] };
  // the page rebuilds each payload from the base one and reads it with VIEW
  await page.evaluate((a) => { window.__base = a.base; window.__VIEW = a.view; }, { base: base(), view: VIEW.toString() });
  const bar2 = await page.evaluate((r) => {
    const p = JSON.parse(JSON.stringify(window.__base)); p.projects[0].run = r;
    window.ccWorklist(p); worklistPick("P1");
    const res = (0, eval)("(" + window.__VIEW + ")")();
    window.__sent = []; window.__confirm = false;
    const stop = document.getElementById("wl-runstop"), resume = document.getElementById("wl-runresume");
    res.stopThere = !!stop && stop.style.display !== "none";
    res.resumeThere = !!resume && resume.style.display !== "none";
    if (stop) stop.click();
    res.declined = window.__sent.slice();
    window.__confirm = true;
    if (stop) stop.click();
    res.sent = window.__sent.slice();
    return res;
  }, RUNNING);
  check("a running run shows its bar", bar2.bar === true);
  check("...which item runs now  (" + bar2.barText + ")", /2 of 3/.test(bar2.barText) && bar2.barText.indexOf("own job") >= 0);
  check("...its text escaped", bar2.barHtml.indexOf("<i>my</i>") < 0);
  check("...▶ Run… steps aside while the tab's run goes", bar2.sel === false);
  check("...Stop is there, Resume isn't", bar2.stopThere === true && bar2.resumeThere === false);
  check("...Stop asks first", bar2.declined.length === 0);
  const sm = bar2.sent.length === 1 ? JSON.parse(bar2.sent[0]) : {};
  check("...and sends worklist-run-stop with only the tab  (" + bar2.sent.join(" ") + ")", sm.a === "worklist-run-stop" && sm.v === "P1"
        && (sm.text || "") === "");

  const paused = await page.evaluate(() => {
    const p = JSON.parse(JSON.stringify(window.__base));
    p.projects[0].run = { id: "r1a2b3c4d", phase: "paused", why: "item 2 is blocked: <script>x</script> needs a key", cur: 2,
      total: 3, done: 1, canStop: true, canResume: true, items: [] };
    window.ccWorklist(p); worklistPick("P1");
    const res = (0, eval)("(" + window.__VIEW + ")")();
    window.__sent = [];
    const resume = document.getElementById("wl-runresume");
    res.resumeThere = !!resume && resume.style.display !== "none";
    if (resume) resume.click();
    res.sent = window.__sent.slice();
    return res;
  });
  check("a paused run says why  (" + paused.barText + ")", paused.barText.indexOf("needs a key") >= 0 && /paused/i.test(paused.barText));
  check("...escaped", paused.barHtml.indexOf("<script>") < 0);
  const rm = paused.sent.length === 1 ? JSON.parse(paused.sent[0]) : {};
  check("...Resume sends worklist-run-resume with only the tab", paused.resumeThere === true && rm.a === "worklist-run-resume" && rm.v === "P1");

  const ended = await page.evaluate(() => {
    const p = JSON.parse(JSON.stringify(window.__base));
    p.projects[0].run = { id: "r1a2b3c4d", phase: "finished", why: "2 of 3 checked off", cur: 3, total: 3, done: 2,
      canStop: false, canResume: false, items: [] };
    window.ccWorklist(p); worklistPick("P1");
    const res = (0, eval)("(" + window.__VIEW + ")")();
    window.__sent = [];
    const x = document.getElementById("wl-rundismiss");
    res.stopThere = !!document.getElementById("wl-runstop") && document.getElementById("wl-runstop").style.display !== "none";
    if (x) x.click();
    res.sent = window.__sent.slice();
    return res;
  });
  check("a finished run says how it went  (" + ended.barText + ")", /finished/i.test(ended.barText) && ended.barText.indexOf("2 of 3") >= 0);
  check("...no Stop on an ended run, and ▶ Run… is back", ended.stopThere === false && ended.sel === true);
  const dm = ended.sent.length === 1 ? JSON.parse(ended.sent[0]) : {};
  check("...its close sends worklist-run-dismiss with only the tab", dm.a === "worklist-run-dismiss" && dm.v === "P1");

  // 8. The result line.
  const toast = await page.evaluate(() => {
    const el = document.getElementById("wl-todoflash");
    window.ccRunResult({ started: 2, refused: 1 }); const a = el.textContent;
    window.ccRunResult({ error: "A run is already going in this repo" }); const b = el.textContent;
    window.ccRunResult({ stopped: true }); const c = el.textContent;
    window.ccRunResult({ resumed: true }); const d = el.textContent;
    return { a: a, b: b, c: c, d: d };
  });
  check("started: how many, and how many couldn't run  (" + toast.a + ")", /2/.test(toast.a) && /1/.test(toast.a) && /couldn.t run/.test(toast.a));
  check("refused: says why  (" + toast.b + ")", toast.b.indexOf("already going") >= 0);
  check("stopped / resumed: says so", /stopped/i.test(toast.c) && /resumed/i.test(toast.d));

  await browser.close();
  finish();
})().catch((e) => { check("the browser run finished: " + String(e.message).split("\n")[0], false); finish(); });
