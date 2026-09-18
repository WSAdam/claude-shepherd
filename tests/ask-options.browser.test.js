// ask-options.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a real
// (headless Chromium) browser, renders a held question whose options carry descriptions, and
// measures that each description is on the card as readable, wrapped text.
//
// 2026-09-18: answering a question in Shepherd was strictly worse than in the tab. Cause:
// renderAsk put each option's description -- the trade-off Adam is choosing between -- in the
// button's title attribute, so it only existed as a hover tooltip and he chose blind.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/ask-options.browser.test.js

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
  console.log("-- ask-options.browser.test.js: " + run + " run, " + failed + " failed --");
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
  console.log("skip - real-browser ask-options check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
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

const LONG = "Rebase the unit onto main first and run the whole suite again before asking: slower by a few "
  + "minutes, but the merge review Adam sees is against today's main and cannot go red on a conflict "
  + "that a sibling unit landed while this one was still working.";
const SHORT = "Ask now; Shepherd's own gate will catch a red suite.";
const SCRIPT = "<img src=x onerror=\"window.__pwned=1\">";
function held(ask) {
  return { key: "k1", askHeld: true, ask_nonce: "100.1", pending: { tool: "AskUserQuestion", ask: ask } };
}
const single = held([{ question: "Rebase before asking to merge?", header: "Finish", multiSelect: false,
  options: [{ label: "Rebase first", description: LONG }, { label: "Ask now", description: SHORT },
            { label: "Neither" }, { label: "Odd one", description: SCRIPT }] }]);
const multi = held([
  { question: "Which toppings?", multiSelect: true,
    options: [{ label: "Cheese", description: "the usual" }, { label: "Ham", description: "adds salt" }] },
  { question: "Which size?", multiSelect: false, options: [{ label: "Small" }, { label: "Large" }] }]);
multi.ask_nonce = "100.2";

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser ask-options check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 1400 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  // no session list here, so renderDetail() leaves the detail pane closed: open it by hand
  await page.evaluate((it) => {
    selectedKey = it.key; renderDetail(); selectedKey = it.key;
    document.getElementById("detail").classList.add("show"); setDetailTab("activity", false); renderAsk(it);
  }, single);

  // ---- an option's description is visible text, not only a tooltip (2026-09-18) ----
  const seen = await page.evaluate(() => {
    const box = document.getElementById("d-ask").getBoundingClientRect();
    return Array.prototype.map.call(document.querySelectorAll("#d-ask .ask-opt"), (b) => {
      const d = b.querySelector(".ask-desc"), l = b.querySelector(".ask-lbl");
      const r = d ? d.getBoundingClientRect() : null, cs = d ? getComputedStyle(d) : null;
      return { label: l ? l.textContent : null, desc: d ? d.textContent : null, title: b.title,
               h: r ? r.height : 0, w: r ? r.width : 0, lineH: cs ? parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2 : 0,
               fontPx: cs ? parseFloat(cs.fontSize) : 0, shown: !!(cs && cs.display !== "none" && cs.visibility !== "hidden"),
               clipped: d ? (d.scrollWidth > d.clientWidth + 1 || d.scrollHeight > d.clientHeight + 1) : false,
               insideBox: r ? (r.left >= box.left - 1 && r.right <= box.right + 1) : false,
               ellipsis: cs ? cs.textOverflow : "" };
    });
  });
  check("every option rendered", seen.length === 4);
  if (seen.length === 4) {
    check("an option's description is on the card as text  (got=" + JSON.stringify(seen[1].desc) + ")", seen[1].desc === SHORT);
    check("...under its own label  (got=" + JSON.stringify(seen[1].label) + ")", seen[1].label === "Ask now");
    check("...shown, at a readable size  (got=" + seen[1].fontPx + "px)", seen[1].shown && seen[1].h > 0 && seen[1].fontPx >= 11);
    check("a long description is all there  (got " + String(seen[0].desc || "").length + " of " + LONG.length + " chars)", seen[0].desc === LONG);
    check("...wrapped over several lines, not cut to one  (got=" + Math.round(seen[0].h) + "px of " + Math.round(seen[0].lineH) + "px lines)",
          seen[0].h > 0 && seen[0].h >= seen[0].lineH * 2.5);
    check("...never clipped or ellipsised", seen[0].h > 0 && !seen[0].clipped && seen[0].ellipsis !== "ellipsis");
    check("...and inside the card, no sideways overflow", seen[0].insideBox);
    check("an option with no description gets no empty line", seen[2].desc === null);
    check("a description goes in as text, never as markup", seen[3].desc === SCRIPT);
  }
  const pwned = await page.evaluate(() => window.__pwned === 1 || !!document.querySelector("#d-ask img"));
  check("...so a session's markup never runs", !pwned);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  check("the panel doesn't scroll sideways", !overflow);

  // ---- clicking anywhere on the option -- its description included -- still answers ----
  await page.evaluate(() => { window.__sent = []; });
  const desc = page.locator("#d-ask .ask-opt .ask-desc").first();
  if (await desc.count()) await desc.click();
  const sent = await page.evaluate(() => window.__sent.slice());
  check("a click on the description answers with that option  (sent=" + JSON.stringify(sent) + ")",
        sent.length === 1 && sent[0].indexOf("answer") >= 0 && /"0"|:0\b|\b0\b/.test(sent[0]));

  // ---- a multi-part question: picks still toggle with descriptions inside the buttons ----
  await page.evaluate((it) => { renderAsk(it); }, multi);
  await page.locator("#d-ask .ask-opt").nth(1).click();   // Ham
  const on = await page.evaluate(() => Array.prototype.map.call(document.querySelectorAll("#d-ask .ask-opt"),
    (b) => b.classList.contains("on")));
  check("multi-part: the clicked option lights up, and only it  (got=" + JSON.stringify(on) + ")",
        on.length === 4 && on[0] === false && on[1] === true && on[2] === false && on[3] === false);

  // ---- answering in Shepherd has a real checkbox (2026-09-18) ----
  // It used to be ON with no way to turn it off short of editing JSON. It was briefly made
  // opt-in the same day, then put back ON once the freeze behind that (a quadratic transcript
  // parse elsewhere, f1252be) was fixed and the options were made readable -- so what this
  // pins is the SWITCH existing and round-tripping, not which way the default happens to point.
  const box = await page.evaluate(() => {
    const el = document.getElementById("s-ask-en");
    if (!el) return null;
    showSettings({}, false, false);
    const onByDefault = el.checked === true;
    showSettings({ ask: { enabled: false } }, false, false);
    const offWhenCleared = el.checked === false;
    showSettings({ ask: { enabled: true, waitSeconds: 1200 } }, false, false);
    const onWhenSet = el.checked === true;
    let row = el; while (row && !(row.getAttribute && row.getAttribute("data-stab"))) row = row.parentElement;
    window.__sent = [];
    persistSettings();
    let saved = null;
    window.__sent.forEach((m) => { try { const o = JSON.parse(m); const c = o.text ? JSON.parse(o.text) : null;
      if (c && c.config && c.config.ask) saved = c.config.ask; else if (c && c.ask) saved = c.ask; } catch (e) { /* not it */ } });
    return { onByDefault, offWhenCleared, onWhenSet, tab: row ? row.getAttribute("data-stab") : null, saved,
             label: (el.parentElement.textContent || "").trim() };
  });
  check("Settings has an Answer questions in Shepherd checkbox", box !== null);
  if (box) {
    check("...on when the config says nothing", box.onByDefault);
    check("...off for a user who switched it off", box.offWhenCleared);
    check("...on for a user whose config has ask.enabled true", box.onWhenSet);
    check("...on the Approvals tab  (got=" + box.tab + ")", box.tab === "approvals");
    check("...saved as ask.enabled  (got=" + JSON.stringify(box.saved) + ")", !!box.saved && box.saved.enabled === true);
    check("...and never writes a waitSeconds of its own over a hand-set one", !!box.saved && !("waitSeconds" in box.saved));
  }

  await browser.close();
  finish();
})().catch((e) => { console.log("FAIL - browser run crashed: " + e.message); process.exit(1); });
