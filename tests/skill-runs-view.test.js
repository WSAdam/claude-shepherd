// skill-runs-view.test.js - BEHAVIORAL: the 🔌 viewer shows how often each skill works (2026-09-29,
// build program unit 35).
//
// Lua answers open-mcpskills-view with window.ccMcpSkills(d), d.runs = FX.skillRunsPayload()
// ({ bySkill, order, enabled, indexing } -- core.skillOutcomes), and pushes window.ccSkillRuns(runs)
// when a label changes or an index pass lands while the viewer is open. A skill's card shows
// "N runs · x% ok" as a toggle; open, its newest runs, each labelled ok / not ok by a click
// (send("skill-label", id, verdict); a click on the label already set clears it). Goals, session
// names and skill names are a session's words, so every one goes through esc(). Runs the REAL
// shipped functions sliced out of claude-dashboard.lua (the time-view.test.js pattern).
//
// Usage: node tests/skill-runs-view.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const parts = {
  esc: slice("    function esc(s){", "\n    }\n"),
  tlvDur: slice("    function tlvDur(s){", "\n    }\n"),
  commitAgo: slice("    function commitAgo(ts, nowSec){", "\n    }\n"),
  state: slice("    var MK_LAST = null;", "\n"),
  open: slice("    function openMcpSkills(){", "\n"),
  close: slice("    function closeMcpSkills(){", "\n"),
  runsOf: slice("    function mkRunsOf(name){", "\n    }\n"),
  runRow: slice("    function mkRunRow(x, now){", "\n    }\n"),
  runsHtml: slice("    function mkRunsHtml(name){", "\n    }\n"),
  toggle: slice("    function mkToggleRuns(b){", "\n    }\n"),
  label: slice("    function mkLabel(b){", "\n    }\n"),
  skillRow: slice("    function mkSkillRow(s){", "\n    }\n"),
  toolRow: slice("    function mkToolRow(t){", "\n    }\n"),
  render: slice("    function mkRender(){", "\n    }\n"),
  push: slice("    window.ccMcpSkills = function(d){", "\n    };\n"),
  pushRuns: slice("    window.ccSkillRuns = function(r){", "\n    };\n"),
};
for (const k of Object.keys(parts)) check("the panel ships " + k, parts[k] !== null);
if (Object.values(parts).some((p) => p === null)) {
  console.log("\n-- skill-runs-view.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a minimal DOM: the overlay, its body and info line
function el() { return { innerHTML: "", textContent: "", cls: new Set(), classList: null }; }
const nodes = { mcpskills: el(), "mk-body": el(), "mk-info": el() };
for (const k of Object.keys(nodes)) {
  const n = nodes[k];
  n.classList = { contains: (c) => n.cls.has(c), add: (c) => n.cls.add(c), remove: (c) => n.cls.delete(c) };
}
const document = { getElementById: (id) => nodes[id] || null };
const window = {};
const sent = [];
function send(a, v, text) { sent.push([a, v, text]); }
const lib = new Function("document", "window", "send",
  Object.values(parts).join("\n") +
  "\nreturn { mkRunsHtml, mkRunRow, mkToggleRuns, mkLabel, closeMcpSkills, state: function(){ return { MK_LAST: MK_LAST, MK_OPEN: MK_OPEN }; } };")(document, window, send);

// a button the way the DOM hands one to its onclick
function button(html, attr, value) {
  const re = new RegExp('<button[^>]*' + attr + '="' + value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + '"[^>]*>');
  const m = html.match(re);
  if (!m) return null;
  const attrs = {};
  m[0].replace(/([a-z-]+)="([^"]*)"/g, (_, k, v) => { attrs[k] = v.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"); });
  return { getAttribute: (k) => (k in attrs ? attrs[k] : null) };
}

const now = Math.floor(Date.now() / 1000);
const EVIL = '<img src=x onerror="alert(1)">';
const runs = {
  enabled: true, indexing: false,
  order: ["simplify", "rune:build", EVIL],
  bySkill: {
    simplify: { skill: "simplify", runs: 3, ok: 2, notOk: 1, open: 0, running: 0, labelled: 1, rate: 67, text: "3 runs · 67% ok",
      rows: [
        { id: "toolu_a", skill: "simplify", via: "tool", goal: "tidy " + EVIL, ts: now - 7200, seconds: 95, outcome: "made progress", exit: "done",
          derived: "ok", verdict: "ok", session: "sess " + EVIL },
        { id: "toolu_b", skill: "simplify", via: "tool", goal: "second", ts: now - 60, seconds: 10, outcome: "blocked", exit: "interrupted",
          derived: "not ok", label: "not ok", verdict: "not ok", session: "one" },
      ] },
    "rune:build": { skill: "rune:build", runs: 1, ok: 0, notOk: 0, open: 1, running: 1, labelled: 0, text: "1 run · running",
      rows: [{ id: "u1", skill: "rune:build", via: "slash", goal: "build it", ts: now - 5, seconds: 0, session: "two" }] },
  },
};
runs.bySkill[EVIL] = { skill: EVIL, runs: 1, ok: 1, notOk: 0, open: 0, running: 0, labelled: 0, rate: 100, text: "1 run · 100% ok",
  rows: [{ id: "x1", skill: EVIL, goal: "g", ts: now, outcome: "done", exit: "done", verdict: "ok", derived: "ok" }] };
const payload = {
  mcp: [], tools: [],
  skills: { user: [{ name: "simplify", command: "/simplify", description: "Review" }, { name: "never-run", description: "Idle" }],
            builtin: [{ name: "loop", command: "/loop" }] },
  runs: runs,
};

// 1. the card's chip
window.ccMcpSkills(payload);
let body = nodes["mk-body"].innerHTML;
check("the viewer opens", nodes.mcpskills.cls.has("show"));
check("a skill with runs shows how often it works", body.includes("3 runs · 67% ok"));
check("...and how many runs carry your label", body.includes("1 labelled"));
// one card's html: from its name to the next card
function rowOf(html, name) {
  const at = html.indexOf('<div class="mk-name">' + name);
  if (at < 0) return "";
  const next = html.indexOf('<div class="mk-row">', at);
  return html.slice(at, next < 0 ? html.length : next);
}
check("a skill never run shows no chip", rowOf(body, "never-run") !== "" && !rowOf(body, "never-run").includes("mk-runs-chip"));
check("...a skill that ran does", rowOf(body, "simplify").includes("mk-runs-chip"));
check("the runs list starts closed", !body.includes("tidy "));

// 2. skills with runs but no card are listed apart, their names escaped
check("a skill with runs but no card is listed apart", body.includes("Skills · other runs") && body.includes("rune:build"));
check("...its name escaped", !body.includes("<img") && body.includes("&lt;img"));

// 3. open the list: goals, sessions, outcomes -- all escaped
const chip = button(body, "data-skill", "simplify");
check("the chip toggles the list", chip !== null);
lib.mkToggleRuns(chip);
body = nodes["mk-body"].innerHTML;
check("open, it lists the runs' goals", body.includes("tidy &lt;img") && body.includes("second"));
check("...the session each ran in", body.includes("sess &lt;img") && body.includes("one"));
check("...what each did", body.includes("made progress") && body.includes("blocked, interrupted"));
check("...how long", body.includes("1m 35s"));
check("...never a raw tag from a session", !body.includes("<img"));
check("...newest-first order is Lua's", body.indexOf("tidy &lt;img") < body.indexOf("second"));

// 4. labelling: a click sends the run's id and the verdict; the label already set clears
sent.length = 0;
lib.mkLabel(button(body, "data-v", "ok"));
eq("labelling a run ok sends its id", JSON.stringify(sent[0]), JSON.stringify(["skill-label", "toolu_a", "ok"]));
const clearBtn = button(body.slice(body.indexOf("second")), "data-v", "clear");
check("a run you labelled offers to clear it", clearBtn !== null && clearBtn.getAttribute("data-id") === "toolu_b");
lib.mkLabel(clearBtn);
eq("...and the click clears it", JSON.stringify(sent[1]), JSON.stringify(["skill-label", "toolu_b", "clear"]));

// 5. pushed runs: ignored while closed, re-rendered while open (the list stays open)
const again = JSON.parse(JSON.stringify(runs));
again.bySkill.simplify.text = "3 runs · 100% ok";
window.ccSkillRuns(again);
body = nodes["mk-body"].innerHTML;
check("a push while open re-renders the runs", body.includes("3 runs · 100% ok"));
check("...and keeps the list open", body.includes("tidy &lt;img"));
nodes.mcpskills.cls.delete("show");
again.bySkill.simplify.text = "3 runs · 0% ok";
window.ccSkillRuns(again);
check("a push while closed is ignored", !nodes["mk-body"].innerHTML.includes("3 runs · 0% ok")
      && nodes["mk-body"].innerHTML.includes("3 runs · 100% ok"));

// 6. closing tells Lua; the index off says so
sent.length = 0;
lib.closeMcpSkills();
check("closing the viewer tells Lua", sent.length === 1 && sent[0][0] === "close-mcpskills-view");
window.ccMcpSkills({ mcp: [], tools: [], skills: { user: [{ name: "simplify" }], builtin: [] }, runs: { enabled: false, bySkill: [], order: [] } });
check("with the time index off the viewer says where runs come from", nodes["mk-body"].innerHTML.includes("timeLost.enabled"));
window.ccMcpSkills({ mcp: [], tools: [], skills: { user: [{ name: "__proto__" }, { name: "simplify" }], builtin: [] } });
check("no runs at all: no chip, no crash", !nodes["mk-body"].innerHTML.includes("mk-runs-chip"));

console.log("\n-- skill-runs-view.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
