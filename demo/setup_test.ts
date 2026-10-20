// setup_test.ts - the worktree demo's setup and check (2026-09-12; on Node since 2026-10-20).
// `make demo` creates a FRESH demo repo per run (a new path, so VS Code has no old Claude tabs to
// restore -- the 2026-09-11 runs tripped on exactly that), and `npm run check` in a run proves the
// result: both features on main, tests green, no worktrees or unit branches left.
// 2026-10-20: Deno is being retired, so the demo runs on Node alone (already a Shepherd prerequisite);
// tests/run.sh runs this file with every Deno directory taken off PATH.
//
// Run: make demo-test   (from the Shepherd repo root)

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { access, appendFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRun, findOldRuns, openFolders, preflight, runName } from "./setup.ts";
import { checkRun } from "./check.ts";

const HERE = import.meta.dirname + "/";
const run = promisify(execFile);

async function sh(cmd: string, args: string[], cwd?: string): Promise<{ code: number; out: string }> {
  try {
    const r = await run(cmd, args, { cwd });
    return { code: 0, out: (r.stdout + r.stderr).trim() };
  } catch (e) {
    const err = e as { code?: number; stdout?: string; stderr?: string };
    return { code: typeof err.code === "number" ? err.code : 127, out: ((err.stdout || "") + (err.stderr || "")).trim() };
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

async function newRun(stamp = "20260912-1030") {
  const runsDir = await mkdtemp(join(tmpdir(), "wt-demo-runs-"));
  const r = await createRun({
    template: HERE + "template",
    checkScript: HERE + "check.ts",
    runsDir,
    stamp,
    home: "/Users/test",
    runTests: true,
  });
  return { runsDir, ...r };
}

// what the two units do, written straight onto main (a merged run, for the check's pass case)
async function mergeBothFeatures(dir: string): Promise<void> {
  await appendFile(
    dir + "/src/greet.ts",
    "\nexport function shout(name: string): string {\n  return `HELLO, ${name.toUpperCase()}!`;\n}\n" +
      "\nexport function whisper(name: string): string {\n  return `(hello, ${name.toLowerCase()}…)`;\n}\n",
  );
  await appendFile(
    dir + "/src/greet_test.ts",
    '\nimport { shout, whisper } from "./greet.ts";\n' +
      'test("shout greets loudly", () => {\n  assert.equal(shout("Adam"), "HELLO, ADAM!");\n});\n' +
      'test("whisper greets quietly", () => {\n  assert.equal(whisper("Adam"), "(hello, adam…)");\n});\n',
  );
  await sh("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "Add shout and whisper"]);
}

test("a run is a fresh repo: one clean commit, green tests, the driver's skill and the check script", async () => {
  const { dir, testsPassed } = await newRun();
  assert.ok(dir.endsWith("/" + runName("20260912-1030")), `run folder named after the stamp: ${dir}`);
  const log = await sh("git", ["-C", dir, "log", "--format=%s"]);
  assert.equal(log.out, "Starter app", "exactly one commit, \"Starter app\"");
  assert.equal((await sh("git", ["-C", dir, "status", "--porcelain"])).out, "", "the tree is clean");
  assert.equal((await sh("git", ["-C", dir, "branch", "--show-current"])).out, "main", "on main");
  for (const f of [".claude/skills/worktree-demo/SKILL.md", "scripts/check.ts", "CLAUDE.md", ".gitignore", "src/greet_test.ts"]) {
    assert.ok(await exists(dir + "/" + f), `the run carries ${f}`);
  }
  const settings = await readFile(dir + "/.claude/settings.json", "utf8");
  assert.ok(settings.includes("/Users/test/.claude/cc-merge.sh"), "the allow list names this machine's cc-merge.sh");
  assert.ok(!settings.includes("__HOME__"), "no placeholder left in the settings");
  assert.equal(testsPassed, true, "the starter app's tests pass");
});

// 2026-10-20: Deno is being retired; the app every run starts from is a plain Node project.
test("the run's app is a dependency-free Node + TypeScript project: npm test and npm run check, no Deno", async () => {
  const { dir } = await newRun();
  assert.ok(!await exists(dir + "/deno.json"), "no deno.json in the run");
  const pkg = JSON.parse(await readFile(dir + "/package.json", "utf8"));
  assert.equal(pkg.type, "module", "ES modules, so the .ts files import each other");
  assert.equal(pkg.scripts?.test, "node --test", "npm test runs node's own test runner");
  assert.equal(pkg.scripts?.check, "node scripts/check.ts", "npm run check runs the check script");
  assert.equal(pkg.dependencies, undefined, "no dependencies");
  assert.equal(pkg.devDependencies, undefined, "no dev dependencies");
  const settings = await readFile(dir + "/.claude/settings.json", "utf8");
  assert.ok(settings.includes("Bash(npm test)") && settings.includes("Bash(npm run check)"), "the allow list runs npm test and npm run check");
  assert.ok(!/deno/i.test(settings), "the allow list names no Deno command");
  for (const f of ["CLAUDE.md", ".claude/skills/worktree-demo/SKILL.md", "src/greet_test.ts"]) {
    assert.ok(!/deno/i.test(await readFile(dir + "/" + f, "utf8")), `${f} names no Deno command`);
  }
});

test("check fails on a fresh run: the two features aren't there yet", async () => {
  const { dir } = await newRun();
  const r = await checkRun(dir);
  assert.equal(r.ok, false, "a fresh run doesn't pass the check");
  assert.ok(r.lines.some((l) => !l.ok && l.text.includes("shout")), "it names the missing shout");
  assert.ok(r.lines.some((l) => !l.ok && l.text.includes("whisper")), "it names the missing whisper");
});

test("check passes once both features are on main, and fails with a worktree or unit branch left", async () => {
  const { dir } = await newRun();
  await mergeBothFeatures(dir);
  const good = await checkRun(dir);
  assert.equal(good.ok, true, "both features merged, tests green, nothing left over: " + JSON.stringify(good.lines));
  assert.ok(good.lines.some((l) => l.ok && l.text.includes("the tests pass (3)")), "it counts the three passing tests: " + JSON.stringify(good.lines));
  await sh("git", ["-C", dir, "worktree", "add", "-q", dir + "/.claude/worktrees/extra", "-b", "feat/extra"]);
  const bad = await checkRun(dir);
  assert.equal(bad.ok, false, "a leftover worktree fails the check");
  assert.ok(bad.lines.some((l) => !l.ok && l.text.includes("worktree")), "it says a worktree is left");
  assert.ok(bad.lines.some((l) => !l.ok && l.text.includes("feat/extra")), "it names the leftover unit branch");
});

test("old runs whose window is closed are for the Trash; open runs and other folders stay", async () => {
  const runsDir = await mkdtemp(join(tmpdir(), "wt-demo-old-"));
  const a = runsDir + "/" + runName("20260101-0900");
  const b = runsDir + "/" + runName("20260102-0900");
  for (const d of [a, b, runsDir + "/notes"]) await mkdir(d);
  const r = await findOldRuns(runsDir, [b]);
  assert.deepEqual(r.trash, [a], "the closed run goes");
  assert.deepEqual(r.keep, [b], "the open run stays");
});

test("open folders come from fresh tab-bridge registries only", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wt-demo-bridge-"));
  const now = Math.floor(Date.now() / 1000);
  await writeFile(dir + "/101.json", JSON.stringify({ v: 1, pid: 101, folders: ["/r/open"], tabs: [], at: now }));
  await writeFile(dir + "/102.json", JSON.stringify({ v: 1, pid: 102, folders: ["/r/crashed"], tabs: [], at: now - 600 }));
  await writeFile(dir + "/.installed", "0.4.0");
  assert.deepEqual(await openFolders(dir, now), ["/r/open"], "only the live window's folder");
});

test("preflight names each missing piece, with a fix", async () => {
  const home = await mkdtemp(join(tmpdir(), "wt-demo-home-"));
  const problems = await preflight({ home, now: Math.floor(Date.now() / 1000), codeCli: null });
  const all = problems.join("\n");
  assert.ok(all.includes("Shepherd isn't running"), "Shepherd's heartbeat is missing: " + all);
  assert.ok(all.includes("cc-fleet.sh"), "the batch script is missing");
  assert.ok(all.includes("tab bridge"), "the tab bridge isn't installed");
  assert.ok(all.includes("VS Code"), "VS Code's command-line tool wasn't found");
});
