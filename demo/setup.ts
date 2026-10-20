// setup.ts - `make demo`: start a fresh run of Shepherd's parallel worktree demo (2026-09-12).
//
//   make demo                              check the prerequisites, tidy old runs, create a fresh run, open it
//   node demo/setup.ts --no-open           ...but don't open VS Code
//   node demo/setup.ts --dir <path>        keep runs somewhere other than ~/Programming/worktree-demo-runs
//
// Every run is a NEW folder (worktree-demo-<date>-<time>): VS Code remembers tabs per folder path,
// and reopening a folder restores its old Claude tabs -- which the 2026-09-11 runs tripped on.
// Old runs whose window is closed go to the Trash (never deleted outright).
// On Node since 2026-10-20 (Deno is being retired): Node 22.18+ runs this .ts file as is, and Node is
// already a Shepherd prerequisite, so the demo needs nothing else installed.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { access, copyFile, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = import.meta.dirname + "/";
const execFileP = promisify(execFile);
// A `node --test` started from inside another one (the demo's own suite) inherits NODE_TEST_CONTEXT
// and reports to that outer runner instead of printing its results, so children never get it.
const childEnv = { ...process.env };
delete childEnv.NODE_TEST_CONTEXT;
const HEARTBEAT_MAX_AGE = 30;   // seconds, as cc-fleet.sh judges Shepherd alive
const BRIDGE_FRESH = 45;        // seconds, as Shepherd judges a tab-bridge registry live
const BRIDGE_MIN = "0.4.0";     // closes empty chats; unit tags since 0.3.0
const RUN_RE = /^worktree-demo-\d{8}-\d{4,6}$/;

async function sh(cmd: string, args: string[], cwd?: string): Promise<{ code: number; out: string }> {
  try {
    const r = await execFileP(cmd, args, { cwd, env: childEnv });
    return { code: 0, out: (r.stdout + r.stderr).trim() };
  } catch (e) {
    // a command that ran and failed carries its exit code; one that couldn't start (ENOENT) is 127
    const err = e as { code?: number | string; stdout?: string; stderr?: string };
    if (typeof err.code !== "number") return { code: 127, out: String(e) };
    return { code: err.code, out: ((err.stdout || "") + (err.stderr || "")).trim() };
  }
}

async function exists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

function versionAtLeast(v: string, want: string): boolean {
  const a = (v.match(/\d+/g) || []).map(Number), b = (want.match(/\d+/g) || []).map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  }
  return true;
}

export function runName(stamp: string): string {
  return `worktree-demo-${stamp}`;
}

export function stampNow(d = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// VS Code's command-line tool, found the way vscode-bridge/install-vsix.sh finds it.
export async function findCodeCli(): Promise<string | null> {
  const env = process.env.CC_CODE_CLI;
  if (env && await exists(env)) return env;
  const which = await sh("which", ["code"]);
  if (which.code === 0 && which.out) return which.out.split("\n")[0];
  const md = await sh("mdfind", ["kMDItemCFBundleIdentifier == 'com.microsoft.VSCode'"]);
  const app = md.out.split("\n").find((l) => l.endsWith(".app"));
  const cli = app ? app + "/Contents/Resources/app/bin/code" : "";
  return cli && await exists(cli) ? cli : null;
}

// Everything the run relies on, each missing piece named with its fix. [] = ready.
export async function preflight(o: { home: string; now: number; codeCli: string | null }): Promise<string[]> {
  const problems: string[] = [];
  const statusDir = process.env.CC_STATUS_DIR || o.home + "/.claude/cc-status";
  let hb = 0;
  try {
    hb = Number((await readFile(statusDir + "/.panel-alive", "utf8")).trim()) || 0;
  } catch { /* no heartbeat */ }
  if (o.now - hb > HEARTBEAT_MAX_AGE) problems.push("Shepherd isn't running: open Hammerspoon so the Shepherd panel is up, then try again.");
  for (const s of ["cc-fleet.sh", "cc-merge.sh", "cc-ask.sh"]) {
    if (!await exists(o.home + "/.claude/" + s)) problems.push(`~/.claude/${s} is missing: run \`make setup\` in the Shepherd repo.`);
  }
  let bridge = "";
  try {
    bridge = (await readFile(o.home + "/.claude/cc-bridge/.installed", "utf8")).trim();
  } catch { /* not installed */ }
  if (!bridge || !versionAtLeast(bridge, BRIDGE_MIN)) {
    problems.push(`The Shepherd tab bridge ${BRIDGE_MIN}+ isn't installed (found: ${bridge || "none"}): run \`make install\` in the Shepherd repo.`);
  }
  if (!o.codeCli) problems.push("VS Code's command-line tool wasn't found: set CC_CODE_CLI to …/Visual Studio Code.app/Contents/Resources/app/bin/code.");
  for (const tool of ["git", "jq"]) {
    if ((await sh("which", [tool])).code !== 0) problems.push(`${tool} isn't installed: brew install ${tool}.`);
  }
  return problems;
}

// Folders open in VS Code right now: every live tab-bridge registry lists its window's folders.
export async function openFolders(bridgeDir: string, now: number): Promise<string[]> {
  const out: string[] = [];
  try {
    for (const e of await readdir(bridgeDir, { withFileTypes: true })) {
      if (!e.isFile() || !/^\d+\.json$/.test(e.name)) continue;
      try {
        const reg = JSON.parse(await readFile(bridgeDir + "/" + e.name, "utf8"));
        if (now - Number(reg.at || 0) <= BRIDGE_FRESH && Array.isArray(reg.folders)) out.push(...reg.folders.map(String));
      } catch { /* a half-written registry: skip */ }
    }
  } catch { /* no bridge dir */ }
  return out.sort();
}

// Earlier runs: the ones whose window is closed can go; open ones stay. Other folders are ignored.
export async function findOldRuns(runsDir: string, open: string[]): Promise<{ trash: string[]; keep: string[] }> {
  const trash: string[] = [], keep: string[] = [];
  try {
    for (const e of await readdir(runsDir, { withFileTypes: true })) {
      if (!e.isDirectory() || !RUN_RE.test(e.name)) continue;
      const p = runsDir + "/" + e.name;
      (open.includes(p) ? keep : trash).push(p);
    }
  } catch { /* no runs yet */ }
  return { trash: trash.sort(), keep: keep.sort() };
}

// A fresh run: the template, this machine's paths in its allow list, the check script, one commit.
export async function createRun(o: {
  template: string;
  checkScript: string;
  runsDir: string;
  stamp: string;
  home: string;
  runTests: boolean;
}): Promise<{ dir: string; testsPassed: boolean }> {
  const dir = o.runsDir + "/" + runName(o.stamp);
  if (await exists(dir)) throw new Error(`${dir} already exists`);
  await mkdir(dir, { recursive: true });
  const cp = await sh("cp", ["-R", o.template.replace(/\/$/, "") + "/.", dir]);
  if (cp.code !== 0) throw new Error("couldn't copy the template: " + cp.out);
  const settings = dir + "/.claude/settings.json";
  await writeFile(settings, (await readFile(settings, "utf8")).replaceAll("__HOME__", o.home));
  await mkdir(dir + "/scripts", { recursive: true });
  await copyFile(o.checkScript, dir + "/scripts/check.ts");
  for (const args of [["init", "-q", "-b", "main"], ["add", "-A"],
                      ["-c", "user.name=Worktree demo", "-c", "user.email=demo@localhost", "commit", "-qm", "Starter app"]]) {
    const r = await sh("git", args, dir);
    if (r.code !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.out}`);
  }
  const testsPassed = o.runTests ? (await sh("npm", ["test"], dir)).code === 0 : true;
  return { dir, testsPassed };
}

async function moveToTrash(p: string): Promise<boolean> {
  const script = `tell application "Finder" to delete POSIX file "${p.replaceAll('"', '\\"')}"`;
  return (await sh("osascript", ["-e", script])).code === 0;
}

async function main(args: string[]): Promise<number> {
  const home = process.env.HOME || "";
  const dirIdx = args.indexOf("--dir");
  const runsDir = (dirIdx >= 0 && args[dirIdx + 1]) ? args[dirIdx + 1] : home + "/Programming/worktree-demo-runs";
  const open = !args.includes("--no-open");
  const now = Math.floor(Date.now() / 1000);
  console.log("🚀 Shepherd worktree demo: starting a fresh run");

  const codeCli = await findCodeCli();
  if (process.env.CC_DEMO_SKIP_PREFLIGHT !== "1") {
    const problems = await preflight({ home, now, codeCli: open ? codeCli : "skipped" });
    if (problems.length) {
      console.log("❌ Not ready yet:");
      for (const p of problems) console.log("   • " + p);
      return 1;
    }
    console.log("✅ Shepherd, its scripts, the tab bridge and VS Code are all there");
  }

  await mkdir(runsDir, { recursive: true });
  const old = await findOldRuns(runsDir, await openFolders(home + "/.claude/cc-bridge", now));
  for (const p of old.trash) console.log((await moveToTrash(p) ? "🧹 moved an old run to the Trash: " : "⚠️ couldn't move to the Trash: ") + p);
  for (const p of old.keep) console.log("ℹ️  left an old run alone (its VS Code window is open): " + p);

  const run = await createRun({ template: HERE + "template", checkScript: HERE + "check.ts", runsDir, stamp: stampNow(), home, runTests: true });
  if (!run.testsPassed) {
    console.log(`❌ The starter app's tests failed in ${run.dir}: run \`npm test\` there to see why.`);
    return 1;
  }
  console.log(`✅ Fresh run ready (starter app committed, tests green): ${run.dir}`);

  if (open && codeCli) {
    const r = await sh(codeCli, ["--new-window", run.dir]);
    console.log(r.code === 0 ? "✅ Opened it in a new VS Code window" : "⚠️ Couldn't open VS Code: " + r.out);
  }
  console.log("");
  console.log("👉 Next: in that VS Code window, open a Claude tab and type:   run the worktree demo");
  console.log("   Then follow what it tells you. You'll approve once and click Merge twice.");
  console.log("   Walkthrough: demo/GUIDE.md   ·   How it works: demo/HOW-IT-WORKS.md");
  return 0;
}

// run directly (`node demo/setup.ts`), not when imported; import.meta.main needs Node 24.2+
const isMain = import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) process.exit(await main(process.argv.slice(2)));
