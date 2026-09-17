// extension.js - the Shepherd bridge: runs inside this VS Code window's extension host
// (the same process as the window's Claude tabs, so process.pid == Shepherd's
// host_window) and lets Shepherd close ONE Claude tab by name, or bring it to the front
// (select), with no keystrokes.
//
//   <dir>/<pid>.json        registry: this window's Claude tabs (on change + every 15s)
//   <dir>/<pid>.in/<id>.json   commands from Shepherd ("close" or "select", both by name)
//   <dir>/<pid>.out/<id>.json  results for Shepherd
//
// <dir> is ~/.claude/cc-bridge (CC_BRIDGE_DIR overrides it for tests).
"use strict";

const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");
const lib = require("./lib");

const DIR = process.env.CC_BRIDGE_DIR || path.join(os.homedir(), ".claude", "cc-bridge");
const PID = process.pid;
const REGISTRY = path.join(DIR, PID + ".json");
const INBOX = path.join(DIR, PID + ".in");
const OUTBOX = path.join(DIR, PID + ".out");
const HEARTBEAT_MS = 15000;
const POLL_MS = 2000;

let version = "0";
let out = null;
let writeTimer = null, heartbeat = null, poller = null, watcher = null;
let busy = false;
const EXPECT_MS = 90000;
const unitTags = new WeakMap();   // tab -> unit tag ("<batch>:<slug>"): tabs this bridge saw open for a unit
let expecting = null;             // { unit, until }: tag the next Claude tab that opens
const openedAt = new WeakMap();   // tab -> ms it was seen opening (a unit's tab may open before its expect is read)
const EXPECT_EARLY_MS = 2000;     // a tab that opened this long before the expect was written can still be the unit's

function log(msg) { if (out) out.appendLine(new Date().toISOString() + " " + msg); }

function writeAtomic(file, text) {
  const tmp = file + ".tmp." + PID;
  fs.writeFileSync(tmp, text, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function snapshot() { return lib.claudeTabs(vscode.window.tabGroups.all, (t) => unitTags.get(t)); }

// A tab opened while Shepherd is expecting one becomes that unit's tab (it never gets a name).
function onTabsChanged(e) {
  if (e && Array.isArray(e.opened)) {
    for (const tab of e.opened) if (lib.isClaudeTab(tab)) openedAt.set(tab, Date.now());
  }
  if (expecting && e && Array.isArray(e.opened)) {
    if (Date.now() > expecting.until) expecting = null;
    for (const tab of e.opened) {
      if (expecting && lib.isClaudeTab(tab) && !unitTags.has(tab)) {
        unitTags.set(tab, expecting.unit);
        log("✅ the new Claude tab is unit " + expecting.unit);
        expecting = null;
      }
    }
  }
  scheduleWrite();
}

function writeRegistry() {
  try {
    const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
    writeAtomic(REGISTRY, JSON.stringify(lib.registryFor(PID, snapshot(), folders, version, Date.now())));
  } catch (e) {
    log("❌ registry write failed: " + e.message);
  }
}

function scheduleWrite() {
  clearTimeout(writeTimer);
  writeTimer = setTimeout(writeRegistry, 300);
}

function answer(id, result) {
  if (!id) return;
  try {
    writeAtomic(path.join(OUTBOX, id + ".json"),
      JSON.stringify(Object.assign({ v: 1, id, at: Math.floor(Date.now() / 1000) }, result)));
  } catch (e) {
    log("❌ couldn't write the result for " + id + ": " + e.message);
  }
}

// Claim each command by unlinking it (so a retry never runs twice), validate, re-check
// the tabs at execution time, close, answer.
async function processInbox() {
  if (busy) return;
  busy = true;
  try {
    let names = [];
    try { names = fs.readdirSync(INBOX).filter((n) => n.endsWith(".json")); } catch (e) { return; }
    for (const name of names) {
      const file = path.join(INBOX, name);
      let raw;
      try { raw = fs.readFileSync(file, "utf8"); fs.unlinkSync(file); } catch (e) { continue; }
      let cmd = null;
      try { cmd = JSON.parse(raw); } catch (e) { cmd = null; }
      const id = cmd && typeof cmd.id === "string" && lib.ID_RE.test(cmd.id) ? cmd.id : null;
      const v = lib.validateCommand(cmd, Date.now());
      if (!v.ok) {
        log("⚠️ refused a command (" + v.error + ")");
        answer(id, { ok: false, reason: v.error });
        continue;
      }
      if (v.cmd.op === "expect") {
        // 2026-09-17: the unit's tab may already have opened (Shepherd writes the expect, then opens
        // the tab; a window that's just starting reads its inbox late). Exactly one untagged Claude
        // tab seen opening since just before the expect was written is the unit's.
        const since = Number(cmd.at) * 1000 - EXPECT_EARLY_MS;   // validateCommand checked cmd.at
        const early = [];
        for (const g of vscode.window.tabGroups.all) {
          for (const t of g.tabs) {
            if (lib.isClaudeTab(t) && !unitTags.has(t) && (openedAt.get(t) || 0) >= since) early.push(t);
          }
        }
        if (early.length === 1) {
          unitTags.set(early[0], v.cmd.unit);
          expecting = null;
          log("✅ the Claude tab that just opened is unit " + v.cmd.unit);
          answer(id, { ok: true });
          scheduleWrite();
          continue;
        }
        expecting = { unit: v.cmd.unit, until: Date.now() + EXPECT_MS };
        log("🔍 expecting a new Claude tab for unit " + v.cmd.unit);
        answer(id, { ok: true });
        continue;
      }
      const pick = v.cmd.unit ? lib.pickUnit(snapshot(), v.cmd.unit)
        : (v.cmd.empty ? lib.pickEmpty(snapshot(), v.cmd.empty) : lib.pickExactlyOne(snapshot(), v.cmd.label));
      if (!pick.hit) {
        log("⚠️ didn't " + v.cmd.op + " \"" + (v.cmd.unit || v.cmd.label) + "\": " + pick.reason);
        answer(id, { ok: false, reason: pick.reason });
        continue;
      }
      if (v.cmd.op === "select") {
        const cmds = lib.selectCommands(pick.hit.gi, pick.hit.ti);
        if (!cmds) { answer(id, { ok: false, reason: "the tab is in an editor group past the eighth" }); continue; }
        try {
          for (const c of cmds) await vscode.commands.executeCommand(c.id, ...c.args);
          const g = vscode.window.tabGroups.activeTabGroup;
          const front = !!(g && g.activeTab && (g.activeTab === pick.hit.tab || (!v.cmd.unit && g.activeTab.label === v.cmd.label)));
          log((front ? "✅ brought forward" : "⚠️ couldn't bring forward") + " the Claude tab \"" + (v.cmd.unit || v.cmd.label) + "\"");
          answer(id, front ? { ok: true } : { ok: false, reason: "VS Code didn't bring the tab to the front" });
        } catch (e) {
          answer(id, { ok: false, reason: "select failed: " + e.message });
        }
        continue;
      }
      try {
        const closed = await vscode.window.tabGroups.close(pick.hit.tab);
        log((closed ? "✅ closed" : "⚠️ VS Code kept") + " the Claude tab \"" + (v.cmd.unit || v.cmd.label) + "\"");
        answer(id, closed ? { ok: true } : { ok: false, reason: "VS Code kept the tab open" });
      } catch (e) {
        log("❌ close failed for \"" + (v.cmd.unit || v.cmd.label) + "\": " + e.message);
        answer(id, { ok: false, reason: "close failed: " + e.message });
      }
    }
  } finally {
    busy = false;
  }
}

function stop() {
  clearTimeout(writeTimer);
  clearInterval(heartbeat);
  clearInterval(poller);
  if (watcher) { try { watcher.close(); } catch (e) { /* already closed */ } }
  writeTimer = heartbeat = poller = watcher = null;
  try { fs.unlinkSync(REGISTRY); } catch (e) { /* never written */ }
}

function activate(context) {
  version = (context.extension && context.extension.packageJSON && context.extension.packageJSON.version) || "0";
  out = vscode.window.createOutputChannel("Shepherd Bridge");
  context.subscriptions.push(out);
  try {
    for (const d of [DIR, INBOX, OUTBOX]) {
      fs.mkdirSync(d, { recursive: true, mode: 0o700 });
      fs.chmodSync(d, 0o700);
    }
  } catch (e) {
    log("❌ can't create " + DIR + ": " + e.message);
    return;
  }
  log("🚀 Shepherd bridge " + version + " up in extension host " + PID);
  writeRegistry();
  context.subscriptions.push(
    vscode.window.tabGroups.onDidChangeTabs(onTabsChanged),
    vscode.window.tabGroups.onDidChangeTabGroups(scheduleWrite),
    vscode.workspace.onDidChangeWorkspaceFolders(scheduleWrite),
    { dispose: stop },
  );
  heartbeat = setInterval(writeRegistry, HEARTBEAT_MS);
  poller = setInterval(processInbox, POLL_MS);
  try { watcher = fs.watch(INBOX, () => { processInbox(); }); } catch (e) { log("⚠️ no file watch, polling only: " + e.message); }
  processInbox();
}

function deactivate() { stop(); }

module.exports = { activate, deactivate, _test: { processInbox, writeRegistry, stop } };
