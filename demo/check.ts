// check.ts - does a worktree demo run show what it promised? (2026-09-12; on Node since 2026-10-20)
// Copied into every run as scripts/check.ts; `npm run check` runs it there. Each line is a plain ✅/❌
// statement; the exit code is 0 only when every line holds. Node 22.18+ runs this .ts file as is.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export interface CheckLine {
  ok: boolean;
  text: string;
}

const run = promisify(execFile);
// A `node --test` started from inside another one (this file's own suite) inherits NODE_TEST_CONTEXT
// and reports to that outer runner instead of printing its results, so children never get it.
const childEnv = { ...process.env };
delete childEnv.NODE_TEST_CONTEXT;

async function sh(cmd: string, args: string[], cwd: string): Promise<{ code: number; out: string }> {
  try {
    const r = await run(cmd, args, { cwd, env: childEnv });
    return { code: 0, out: (r.stdout + r.stderr).trim() };
  } catch (e) {
    const err = e as { code?: number; stdout?: string; stderr?: string };
    return { code: typeof err.code === "number" ? err.code : 127, out: ((err.stdout || "") + (err.stderr || "")).trim() };
  }
}

export async function checkRun(dir: string): Promise<{ ok: boolean; lines: CheckLine[] }> {
  const lines: CheckLine[] = [];
  const add = (ok: boolean, text: string) => lines.push({ ok, text });

  const branch = (await sh("git", ["branch", "--show-current"], dir)).out;
  add(branch === "main", branch === "main" ? "on main" : `not on main (on ${branch || "no branch"})`);

  let src = "";
  try {
    src = await readFile(dir + "/src/greet.ts", "utf8");
  } catch { /* reported below */ }
  for (const fn of ["shout", "whisper"]) {
    const has = src.includes(`export function ${fn}(`);
    add(has, has ? `${fn} is on main` : `${fn} is not on main (src/greet.ts has no exported ${fn})`);
  }

  const tests = await sh("npm", ["test"], dir);
  // node's test runner ends with "ℹ pass N" (spec reporter) or "# pass N" (TAP)
  const passed = tests.out.match(/^\S*\s*pass (\d+)\s*$/m);
  add(tests.code === 0, tests.code === 0 ? `the tests pass (${passed ? passed[1] : "all"})` : "the tests fail: run npm test");

  const wts = (await sh("git", ["worktree", "list", "--porcelain"], dir)).out
    .split("\n").filter((l) => l.startsWith("worktree ")).map((l) => l.slice(9));
  add(wts.length === 1, wts.length === 1 ? "no unit worktree is left" : `${wts.length - 1} worktree(s) left: ${wts.slice(1).join(", ")}`);

  const units = (await sh("git", ["branch", "--list", "feat/*", "fix/*", "ui/*", "docs/*", "--format=%(refname:short)"], dir)).out
    .split("\n").filter(Boolean);
  add(units.length === 0, units.length === 0 ? "no unit branch is left" : `unit branch(es) left: ${units.join(", ")}`);

  const dirty = (await sh("git", ["status", "--porcelain"], dir)).out;
  add(dirty === "", dirty === "" ? "main is clean" : "main has uncommitted changes");

  return { ok: lines.every((l) => l.ok), lines };
}

// run directly (`node scripts/check.ts`), not when imported; import.meta.main needs Node 24.2+
const isMain = import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  const r = await checkRun(process.cwd());
  console.log("🔍 Worktree demo check");
  for (const l of r.lines) console.log(`  ${l.ok ? "✅" : "❌"} ${l.text}`);
  console.log(r.ok ? "✅ The run did what it promised." : "❌ Not there yet: see the ❌ lines above.");
  process.exit(r.ok ? 0 : 1);
}
