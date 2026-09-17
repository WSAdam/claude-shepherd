// bridge.test.js - BEHAVIORAL fixture for the Shepherd companion VS Code extension
// (vscode-bridge/, 2026-09-11). Shepherd types into a WINDOW, not a tab, and nothing
// outside VS Code can close one specific tab: ⌘W hits whichever tab is in front and the
// Claude extension's URI has no close. The bridge runs inside each window's extension
// host and closes a Claude tab through VS Code's own tab API -- but only when exactly one
// Claude tab in that window carries the requested name.
//
// Runs the pure helpers (vscode-bridge/lib.js), then the REAL extension.js against a fake
// `vscode` module in a temp CC_BRIDGE_DIR: registry, inbox, close, refusals, cleanup.
//
// Usage: node tests/bridge.test.js

const fs = require("fs");
const os = require("os");
const path = require("path");
const Module = require("module");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }
function done() {
  console.log("-- bridge.test.js: " + run + " run, " + failed + " failed --");
  process.exit(failed === 0 ? 0 : 1);
}

const LIB = path.join(__dirname, "..", "vscode-bridge", "lib.js");
const EXT = path.join(__dirname, "..", "vscode-bridge", "extension.js");
check("the bridge's pure helpers exist (vscode-bridge/lib.js)", fs.existsSync(LIB));
check("the bridge's extension entry exists (vscode-bridge/extension.js)", fs.existsSync(EXT));
if (!fs.existsSync(LIB) || !fs.existsSync(EXT)) done();
const lib = require(LIB);

// ---- fakes: a Claude tab is a webview tab whose viewType names claudeVSCodePanel ----
class TabInputWebview { constructor(viewType) { this.viewType = viewType; } }
class TabInputText { constructor(uri) { this.uri = uri; } }
const claudeTab = (label, active) => ({ label, isActive: !!active, input: new TabInputWebview("mainThreadWebview-claudeVSCodePanel") });

// ---- pure helpers ----
check("a Claude panel tab is a Claude tab", lib.isClaudeTab(claudeTab("x")));
check("a text editor tab is not", !lib.isClaudeTab({ label: "main.lua", input: new TabInputText("/r/main.lua") }));
check("another extension's webview is not", !lib.isClaudeTab({ label: "Preview", input: new TabInputWebview("mainThreadWebview-markdown.preview") }));
check("a tab with no input is not", !lib.isClaudeTab({ label: "Settings" }));

const groups = [
  { viewColumn: 1, tabs: [claudeTab("Fix sibling window", true), { label: "main.lua", input: new TabInputText("/r/main.lua") }] },
  { viewColumn: 2, tabs: [claudeTab("Claude Code"), claudeTab("Claude Code")] },
];
const tabs = lib.claudeTabs(groups);
eq("claudeTabs keeps only the Claude tabs, across every group", tabs.length, 3);
eq("...with each tab's label", tabs[0].label, "Fix sibling window");
eq("...its group", tabs[1].group, 2);
eq("...and whether it's the active tab of its group", tabs[0].active, true);

const reg = lib.registryFor(1057, tabs, ["/r/main"], "0.1.0", 1757600000123);
eq("registry: versioned", reg.v, 1);
eq("registry: names the extension host pid (Shepherd's host_window)", reg.pid, 1057);
eq("registry: stamped in whole seconds", reg.at, 1757600000);
eq("registry: lists the window's folders", reg.folders[0], "/r/main");
check("registry: carries labels, never the live tab objects",
      reg.tabs.length === 3 && reg.tabs[0].label === "Fix sibling window" && reg.tabs[0].input === undefined);

const now = 1757600000000;
const good = { v: 1, id: "a1-1757600000", op: "close", label: "Fix sibling window", at: 1757600000 };
check("command: a fresh close with a label is accepted", lib.validateCommand(good, now).ok === true);
const bad = [
  ["not an object", "close"],
  ["an unknown version", Object.assign({}, good, { v: 2 })],
  ["any op but close", Object.assign({}, good, { op: "exec" })],
  ["a missing id", Object.assign({}, good, { id: undefined })],
  ["an id that could leave the outbox", Object.assign({}, good, { id: "../x" })],
  ["an empty label", Object.assign({}, good, { label: "" })],
  ["a runaway label", Object.assign({}, good, { label: "x".repeat(201) })],
  ["a command older than 30s", Object.assign({}, good, { at: 1757600000 - 31 })],
  ["a command from the future", Object.assign({}, good, { at: 1757600000 + 60 })],
];
for (const [what, cmd] of bad) check("command: refuses " + what, !lib.validateCommand(cmd, now).ok);

// 2026-09-11: a second op, select -- Focus lands on the session's own tab
check("command: select by name is accepted too", lib.validateCommand(Object.assign({}, good, { op: "select" }), now).ok === true);
check("tabs carry their group and index (what select needs)", tabs[2].gi === 1 && tabs[2].ti === 1 && tabs[0].gi === 0 && tabs[0].ti === 0);
const sc = lib.selectCommands(1, 2);
check("select: focus the tab's group, then open the tab at its index",
      sc.length === 2 && sc[0].id === "workbench.action.focusSecondEditorGroup"
      && sc[1].id === "workbench.action.openEditorAtIndex" && sc[1].args[0] === 2);
check("select: a group past the eighth can't be focused by command -> refused", lib.selectCommands(8, 0) === null);

check("pick: exactly one tab with the name is picked", lib.pickExactlyOne(tabs, "Fix sibling window").hit === tabs[0]);
const none = lib.pickExactlyOne(tabs, "Nope");
check("pick: no tab with the name -> a reason naming it", !none.hit && /no Claude tab named "Nope"/.test(none.reason));
const two = lib.pickExactlyOne(tabs, "Claude Code");
check("pick: two tabs share the name -> refused, never the first one", !two.hit && /2 Claude tabs share the name/.test(two.reason));

// 2026-09-11: never-used chats all read "Claude Code", so no name picks one. They're
// interchangeable, so Shepherd may close ANY of them -- but only when the count it checked
// (its empty sessions in this window) still matches the untagged "Claude Code" tabs here.
const nowS = Math.floor(Date.now() / 1000);
const emptyCmd = { v: 1, id: "e1", op: "close", label: "Claude Code", empty: 2, at: nowS };
check("command: close an empty chat (\"Claude Code\", with Shepherd's count) is accepted", lib.validateCommand(emptyCmd, Date.now()).ok === true);
eq("command: ...and keeps the count", lib.validateCommand(emptyCmd, Date.now()).cmd.empty, 2);
check("command: 'empty' only for the name \"Claude Code\"", !lib.validateCommand(Object.assign({}, emptyCmd, { label: "Fix sibling window" }), Date.now()).ok);
check("command: 'empty' only for close", !lib.validateCommand(Object.assign({}, emptyCmd, { op: "select" }), Date.now()).ok);
check("command: 'empty' must be a count from 1 to 20", !lib.validateCommand(Object.assign({}, emptyCmd, { empty: 0 }), Date.now()).ok
      && !lib.validateCommand(Object.assign({}, emptyCmd, { empty: "2" }), Date.now()).ok);
const eTabs = [{ label: "Claude Code", active: true }, { label: "Claude Code", unit: "b1:x" }, { label: "Fix" }, { label: "Claude Code" }];
const pe = lib.pickEmpty(eTabs, 2);
check("pick empty: one untagged \"Claude Code\" tab, preferring one not in front", pe.hit === eTabs[3]);
const pe3 = lib.pickEmpty(eTabs, 3);
check("pick empty: the count doesn't match -> refused (a tagged unit's tab never counts)", !pe3.hit && /2 untagged/.test(pe3.reason));

// ---- the real extension.js against a fake vscode, in a temp bridge dir ----
const DIR = fs.mkdtempSync(path.join(os.tmpdir(), "cc-bridge-"));
process.env.CC_BRIDGE_DIR = DIR;
const liveGroups = [
  { viewColumn: 1, tabs: [claudeTab("Fix sibling window", true), claudeTab("Claude Code"), claudeTab("Claude Code"),
                          { label: "main.lua", input: new TabInputText("/r/main.lua") }] },
];
const closed = [];
const subs = [];
const executed = [];
const tabListeners = [];
const GROUP_CMDS = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]
  .map((n) => "workbench.action.focus" + n + "EditorGroup");
let focusedGroup = 0;
const groupOf = (g) => Object.defineProperty(g, "activeTab", { get() { return this.tabs.find((t) => t.isActive); } });
groupOf(liveGroups[0]);
const fakeVscode = {
  TabInputWebview, TabInputText,
  commands: {
    executeCommand: async (id, ...args) => {
      executed.push([id].concat(args).join(":"));
      const gi = GROUP_CMDS.indexOf(id);
      if (gi >= 0) focusedGroup = gi;
      if (id === "workbench.action.openEditorAtIndex") {
        const g = liveGroups[focusedGroup];
        if (g) g.tabs.forEach((t, i) => { t.isActive = (i === args[0]); });
      }
    },
  },
  window: {
    tabGroups: {
      get all() { return liveGroups; },
      get activeTabGroup() { return liveGroups[focusedGroup]; },
      close: async (tab) => {
        closed.push(tab.label);
        liveGroups[0].tabs = liveGroups[0].tabs.filter((t) => t !== tab);
        return true;
      },
      onDidChangeTabs: (cb) => { tabListeners.push(cb); return { dispose() {} }; },
      onDidChangeTabGroups: () => ({ dispose() {} }),
    },
    createOutputChannel: () => ({ appendLine() {}, dispose() {} }),
  },
  workspace: { workspaceFolders: [{ uri: { fsPath: "/r/main" } }], onDidChangeWorkspaceFolders: () => ({ dispose() {} }) },
};
const realLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === "vscode") return fakeVscode;
  return realLoad.apply(this, arguments);
};
const ext = require(EXT);
Module._load = realLoad;

(async () => {
  const pkg = require(path.join(__dirname, "..", "vscode-bridge", "package.json"));
  const ctx = { subscriptions: subs, extension: { packageJSON: pkg } };
  ext.activate(ctx);
  const regFile = path.join(DIR, process.pid + ".json");
  const regTabs0 = () => JSON.parse(fs.readFileSync(regFile, "utf8")).tabs;
  check("activate writes this window's registry, named by the extension host pid", fs.existsSync(regFile));
  const r = JSON.parse(fs.readFileSync(regFile, "utf8"));
  eq("...listing its Claude tabs only", r.tabs.length, 3);
  eq("...and its version (from package.json)", r.version, pkg.version);
  const inbox = path.join(DIR, process.pid + ".in"), outbox = path.join(DIR, process.pid + ".out");
  check("the inbox and outbox exist", fs.existsSync(inbox) && fs.existsSync(outbox));
  eq("...private to this user (0700)", (fs.statSync(inbox).mode & 0o777).toString(8), "700");

  const send = (cmd) => fs.writeFileSync(path.join(inbox, cmd.id + ".json"), JSON.stringify(cmd));
  const result = (id) => { try { return JSON.parse(fs.readFileSync(path.join(outbox, id + ".json"), "utf8")); } catch (e) { return null; } };
  const at = () => Math.floor(Date.now() / 1000);

  send({ v: 1, id: "c1", op: "close", label: "Fix sibling window", at: at() });
  await ext._test.processInbox();
  eq("close: the one tab with that name closes", closed.join(","), "Fix sibling window");
  check("close: the result says so", (result("c1") || {}).ok === true);
  check("close: the command is consumed", !fs.existsSync(path.join(inbox, "c1.json")));

  send({ v: 1, id: "c2", op: "close", label: "Claude Code", at: at() });
  await ext._test.processInbox();
  eq("close: two tabs sharing a name -> nothing closes", closed.length, 1);
  const r2 = result("c2") || {};
  check("close: ...and the result explains it", r2.ok === false && /2 Claude tabs share/.test(r2.reason || ""));

  send({ v: 1, id: "c3", op: "exec", label: "Claude Code", at: at() });
  send({ v: 1, id: "c4", op: "close", label: "Claude Code", at: at() - 120 });
  await ext._test.processInbox();
  check("an unknown op is refused and nothing closes", (result("c3") || {}).ok === false && closed.length === 1);
  check("a stale command is refused and nothing closes", (result("c4") || {}).ok === false && closed.length === 1);

  fs.writeFileSync(path.join(inbox, "junk.json"), "{not json");
  await ext._test.processInbox();
  check("garbage in the inbox is dropped, not retried forever", !fs.existsSync(path.join(inbox, "junk.json")));

  ext._test.writeRegistry();
  eq("the registry follows the closed tab", JSON.parse(fs.readFileSync(regFile, "utf8")).tabs.length, 2);

  // select: two groups, the wanted tab second in the second group
  liveGroups.length = 0;
  liveGroups.push(groupOf({ viewColumn: 1, tabs: [claudeTab("Alpha", true)] }));
  liveGroups.push(groupOf({ viewColumn: 2, tabs: [claudeTab("Beta", true), claudeTab("Gamma")] }));
  send({ v: 1, id: "s1", op: "select", label: "Gamma", at: at() });
  await ext._test.processInbox();
  eq("select: focuses the second group, then opens tab index 1",
     executed.join(" > "), "workbench.action.focusSecondEditorGroup > workbench.action.openEditorAtIndex:1");
  check("select: ...and reports it's in front", (result("s1") || {}).ok === true && liveGroups[1].tabs[1].isActive === true);
  check("select: nothing was closed", closed.length === 1);
  executed.length = 0;
  liveGroups[0].tabs.push(claudeTab("Beta"));
  send({ v: 1, id: "s2", op: "select", label: "Beta", at: at() });
  send({ v: 1, id: "s3", op: "select", label: "Nope", at: at() });
  await ext._test.processInbox();
  check("select: two tabs sharing the name -> refused, no command run", (result("s2") || {}).ok === false && executed.length === 0);
  check("select: no tab with the name -> refused", (result("s3") || {}).ok === false);
  eq("the registry reports the bridge's version", JSON.parse(fs.readFileSync(regFile, "utf8")).version, "0.5.0");   // 2026-09-11: 0.4.0 closes empty chats; 2026-09-17: 0.5.0 tags a unit tab that opened just before its expect

  // 2026-09-11: a tab Shepherd opens for a batch unit never gets a name (its task arrives by
  // message, so no chat title) -- every such tab reads "Claude Code". The bridge remembers the
  // tab it opened for the unit instead: "expect" tags the next Claude tab that opens.
  liveGroups.length = 0;
  liveGroups.push(groupOf({ viewColumn: 1, tabs: [claudeTab("Claude Code", true)] }));
  send({ v: 1, id: "e1", op: "expect", unit: "b1:cheer", at: at() });
  await ext._test.processInbox();
  check("expect: accepted", (result("e1") || {}).ok === true);
  const fresh = claudeTab("Claude Code");
  liveGroups[0].tabs.push(fresh);
  tabListeners.forEach((cb) => cb({ opened: [fresh], closed: [], changed: [] }));
  ext._test.writeRegistry();
  const tagged = JSON.parse(fs.readFileSync(regFile, "utf8")).tabs.filter((t) => t.unit === "b1:cheer");
  check("expect: the next Claude tab to open is remembered as that unit's", tagged.length === 1);
  const later = claudeTab("Claude Code");
  liveGroups[0].tabs.push(later);
  tabListeners.forEach((cb) => cb({ opened: [later], closed: [], changed: [] }));
  ext._test.writeRegistry();
  eq("expect: ...only that one tab", JSON.parse(fs.readFileSync(regFile, "utf8")).tabs.filter((t) => t.unit).length, 1);
  executed.length = 0;
  send({ v: 1, id: "u1", op: "select", unit: "b1:cheer", at: at() });
  await ext._test.processInbox();
  check("select by unit: brings that exact tab forward though three tabs share the name",
        (result("u1") || {}).ok === true && fresh.isActive === true && executed.length === 2);
  const closedBefore = closed.length;
  send({ v: 1, id: "u2", op: "close", unit: "b1:cheer", at: at() });
  await ext._test.processInbox();
  check("close by unit: closes that exact tab", (result("u2") || {}).ok === true && closed.length === closedBefore + 1
        && liveGroups[0].tabs.indexOf(fresh) < 0 && liveGroups[0].tabs.indexOf(later) >= 0);
  send({ v: 1, id: "u3", op: "close", unit: "b1:cheer", at: at() });
  await ext._test.processInbox();
  check("close by unit: once it's gone, refused", (result("u3") || {}).ok === false);
  // 2026-09-17: Shepherd writes the expect and opens the tab a moment later; if the tab opens
  // before the bridge reads its inbox (a window just starting), the old bridge waited for a
  // NEXT tab -- the unit's own stayed untagged and could never be closed by its tag.
  liveGroups[0].tabs.splice(liveGroups[0].tabs.indexOf(later), 1);   // closed: no other tab just opened
  const early = claudeTab("Claude Code");
  liveGroups[0].tabs.push(early);
  tabListeners.forEach((cb) => cb({ opened: [early], closed: [], changed: [] }));
  send({ v: 1, id: "e3", op: "expect", unit: "b1:wave", at: at() });
  await ext._test.processInbox();
  ext._test.writeRegistry();
  check("expect: a Claude tab that opened just before the expect arrived is that unit's",
        (result("e3") || {}).ok === true && regTabs0().filter((t) => t.unit === "b1:wave").length === 1);
  const after = claudeTab("Claude Code");
  liveGroups[0].tabs.push(after);
  tabListeners.forEach((cb) => cb({ opened: [after], closed: [], changed: [] }));
  ext._test.writeRegistry();
  eq("expect: ...and the next tab to open is not tagged too", regTabs0().filter((t) => t.unit === "b1:wave").length, 1);
  const older = claudeTab("Claude Code");
  liveGroups[0].tabs.push(older);
  tabListeners.forEach((cb) => cb({ opened: [older], closed: [], changed: [] }));
  send({ v: 1, id: "e4", op: "expect", unit: "b1:bye", at: at() + 4 });
  await ext._test.processInbox();
  ext._test.writeRegistry();
  check("expect: a tab that opened well before the expect was written is not the unit's",
        (result("e4") || {}).ok === true && regTabs0().filter((t) => t.unit === "b1:bye").length === 0);
  const unitTab = claudeTab("Claude Code");
  liveGroups[0].tabs.push(unitTab);
  tabListeners.forEach((cb) => cb({ opened: [unitTab], closed: [], changed: [] }));
  ext._test.writeRegistry();
  check("expect: ...it waits for the unit's tab to open instead", regTabs0().filter((t) => t.unit === "b1:bye").length === 1);
  liveGroups[0].tabs.splice(liveGroups[0].tabs.indexOf(early), 1);
  liveGroups[0].tabs.splice(liveGroups[0].tabs.indexOf(after), 1);
  liveGroups[0].tabs.splice(liveGroups[0].tabs.indexOf(older), 1);
  liveGroups[0].tabs.splice(liveGroups[0].tabs.indexOf(unitTab), 1);
  ext._test.writeRegistry();
  // an empty chat: any untagged "Claude Code" tab, when Shepherd's count matches
  liveGroups[0].tabs.push(claudeTab("Claude Code"), claudeTab("Claude Code"));
  ext._test.writeRegistry();
  const regTabs = () => JSON.parse(fs.readFileSync(regFile, "utf8")).tabs;
  const emptyNow = () => regTabs().filter((t) => t.label === "Claude Code" && !t.unit).length;
  const taggedNow = () => regTabs().filter((t) => t.unit).length;
  const n0 = emptyNow(), tagged0 = taggedNow(), before2 = closed.length;
  send({ v: 1, id: "e9", op: "close", label: "Claude Code", empty: n0 + 1, at: at() });
  await ext._test.processInbox();
  check("close empty: a count that doesn't match -> refused, nothing closed", (result("e9") || {}).ok === false && closed.length === before2);
  send({ v: 1, id: "e2", op: "close", label: "Claude Code", empty: n0, at: at() });
  await ext._test.processInbox();
  ext._test.writeRegistry();
  check("close empty: the count matches -> one of them is closed  (" + n0 + " -> " + emptyNow() + ")",
        (result("e2") || {}).ok === true && closed.length === before2 + 1 && emptyNow() === n0 - 1);
  check("close empty: a unit's tagged tab is never one of them", taggedNow() === tagged0);
  check("command: expect needs a unit", !lib.validateCommand({ v: 1, id: "x", op: "expect", at: Math.floor(Date.now() / 1000) }, Date.now()).ok);
  check("command: close by unit is accepted without a label",
        lib.validateCommand({ v: 1, id: "x", op: "close", unit: "b1:cheer", at: Math.floor(Date.now() / 1000) }, Date.now()).ok === true);
  check("command: a unit tag with odd characters is refused",
        !lib.validateCommand({ v: 1, id: "x", op: "close", unit: "b1 cheer/..", at: Math.floor(Date.now() / 1000) }, Date.now()).ok);

  ext.deactivate();
  check("deactivate removes the registry (Shepherd stops trusting this window)", !fs.existsSync(regFile));
  fs.rmSync(DIR, { recursive: true, force: true });
  done();
})().catch((e) => { console.log("FAIL - the extension threw: " + (e && e.stack || e)); failed++; done(); });
