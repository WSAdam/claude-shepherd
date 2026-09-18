// ask-form.test.js - BEHAVIORAL fixture for the detail panel's answer form (2026-09-11).
// Slices the REAL askInitPicks / askToggle / askComplete out of claude-dashboard.lua and runs
// them: a single-choice part holds one pick, a multi-select part toggles, Send answers stays
// off until every part has an answer. Then pins that renderAsk builds its DOM with
// textContent only (every question and label was written by a session).
//
// Usage: node tests/ask-form.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  return j < 0 ? null : src.slice(i, j + endNeedle.length);
}
const parts = {
  init: slice("    function askInitPicks(ask){", "}\n"),
  toggle: slice("    function askToggle(ask, picks, qi, label){", "\n    }\n"),
  complete: slice("    function askComplete(ask, picks){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- ask-form.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") +
  "\nreturn { askInitPicks: askInitPicks, askToggle: askToggle, askComplete: askComplete };")();

const ask = [
  { question: "Which toppings?", multiSelect: true, options: [{ label: "Cheese" }, { label: "Ham" }] },
  { question: "Which size?", multiSelect: false, options: [{ label: "Small" }, { label: "Large" }] },
];
const picks = api.askInitPicks(ask);
eq("one pick slot per part", picks.length, 2);
check("nothing picked: Send answers is off", !api.askComplete(ask, picks));
api.askToggle(ask, picks, 0, "Cheese");
api.askToggle(ask, picks, 0, "Ham");
eq("multi-select: both picks kept", picks[0].labels.join(","), "Cheese,Ham");
check("one part answered, one not: still off", !api.askComplete(ask, picks));
api.askToggle(ask, picks, 1, "Small");
api.askToggle(ask, picks, 1, "Large");
eq("single choice: a second pick replaces the first", picks[1].labels.join(","), "Large");
check("every part answered: Send answers is on", api.askComplete(ask, picks));
api.askToggle(ask, picks, 0, "Cheese");
eq("multi-select: a second click unpicks", picks[0].labels.join(","), "Ham");
api.askToggle(ask, picks, 1, "Large");
check("single choice: clicking the pick again clears it, and Send goes off", !api.askComplete(ask, picks));
picks[1].other = "   ";
check("blank free text doesn't count as an answer", !api.askComplete(ask, picks));
picks[1].other = "extra large";
check("free text answers a part", api.askComplete(ask, picks));
check("no parts: never complete", !api.askComplete([], []));

const render = slice("    function renderAsk(it){", "\n    }\n") || "";
check("renderAsk extracted", render.length > 0);
check("renderAsk never writes innerHTML (session text goes in as textContent)", render.indexOf("innerHTML") < 0);
check("renderAsk sends the form as JSON picks", render.indexOf('send("answer-ask", ASKF.key, JSON.stringify(ASKF.picks))') >= 0);
check("renderAsk offers Answer in the tab instead", render.indexOf('send("release-ask", ASKF.key)') >= 0);
check("renderAsk keeps picks across the 1Hz refresh (signature guard)", render.indexOf("if(ASKF.sig === sig) return;") >= 0);

// ---- an option's description is visible text, not only a tooltip (2026-09-18) ----
// 2026-09-18: renderAsk put each option's description in the button's title attribute, so the
// trade-off Adam was choosing between only existed as a hover tooltip. Runs the REAL renderAsk
// against a minimal DOM (the browser twin, ask-options.browser.test.js, measures the wrapping).
function FakeEl(tag) {
  this.tagName = tag; this.children = []; this.className = ""; this.style = {}; this.title = ""; this._text = "";
  const self = this;
  this.classList = { toggle: function (c, on) {
    const cur = self.className.split(" ").filter(Boolean).filter((x) => x !== c);
    if (on) cur.push(c);
    self.className = cur.join(" ");
  } };
}
Object.defineProperty(FakeEl.prototype, "textContent", {
  get: function () { return this._text + this.children.map((c) => c.textContent).join(""); },
  set: function (v) { this._text = String(v); this.children = []; },
});
FakeEl.prototype.appendChild = function (c) { this.children.push(c); return c; };
FakeEl.prototype.hasClass = function (c) { return this.className.split(" ").indexOf(c) >= 0; };
FakeEl.prototype.all = function (c) {
  let out = [];
  this.children.forEach((k) => { if (k.hasClass && k.hasClass(c)) out.push(k); if (k.all) out = out.concat(k.all(c)); });
  return out;
};
FakeEl.prototype.querySelectorAll = function (sel) { return this.all(sel.replace(/^\./, "")); };
const dAsk = new FakeEl("div");
const fakeDoc = {
  getElementById: function () { return dAsk; },
  createElement: function (t) { return new FakeEl(t); },
  createTextNode: function (t) { const e = new FakeEl("#text"); e._text = String(t); return e; },
};
const askElSrc = slice("    function askEl(tag, cls, text){", "\n    }\n");
check("askEl extracted", askElSrc !== null);
const sentMsgs = [];
const dom = new Function("document", "send", "answerAsk",
  "var ASKF = { sig: '' };\n" + Object.values(parts).join("\n") + "\n" + (askElSrc || "") + "\n" + render +
  "\nreturn { renderAsk: renderAsk };")(fakeDoc, function () { sentMsgs.push([].slice.call(arguments)); },
  function (qi, oi) { sentMsgs.push(["answer", qi, oi]); });
const WHY = "Slower by a few minutes, but the review is against today's main.";
dom.renderAsk({ key: "k1", askHeld: true, ask_nonce: "100.1", pending: { ask: [
  { question: "Rebase first?", multiSelect: true,
    options: [{ label: "Rebase", description: WHY }, { label: "Ask now" }] },
  { question: "Which size?", multiSelect: false, options: [{ label: "Small" }, { label: "Large" }] }] } });
const optEls = dAsk.all("ask-opt");
eq("every option is a button on the card", optEls.length, 4);
const descEls = optEls.length ? optEls[0].all("ask-desc") : [];
eq("an option's description is text inside its button", descEls.length ? descEls[0].textContent : null, WHY);
eq("...next to its label", optEls.length && optEls[0].all("ask-lbl").length ? optEls[0].all("ask-lbl")[0].textContent : null, "Rebase");
check("...not left to a hover tooltip alone", optEls.length > 0 && !(optEls[0].title && descEls.length === 0));
eq("an option with no description gets no empty description line", optEls.length > 1 ? optEls[1].all("ask-desc").length : -1, 0);
if (optEls.length === 4) {
  optEls[0].onclick();
  check("a pick lights its own button even though the button's text now carries the description",
        optEls[0].hasClass("on") && !optEls[1].hasClass("on"));
  optEls[0].onclick();
  check("...and a second click on a multi-select pick clears it", !optEls[0].hasClass("on"));
}

console.log("-- ask-form.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
