# The worktree demo

A repeatable, ten-minute proof that Shepherd's parallel worktree flow does what it says:
**two separate pieces of work, in the same project, at the same time — both landing on main.**

## Run it

```bash
make demo        # from the Shepherd repo root (or: node demo/setup.ts)
```

It checks that everything it needs is there, creates a fresh little Node app, and opens it in a new
VS Code window. In that window, open a Claude tab and type:

```
run the worktree demo
```

Then follow what it tells you: you approve the work once and click **Merge** twice.

## Read about it

- **[GUIDE.md](GUIDE.md)** — for anyone. What you'll see, what to click, and what it proves, in
  plain language.
- **[HOW-IT-WORKS.md](HOW-IT-WORKS.md)** — for engineers. The moving parts, the files they write,
  the sequence of events, why the merge conflict resolves, and how to recover when something
  goes wrong.

## What's in this folder

| File | What it is |
|---|---|
| `setup.ts` | `make demo`: checks, tidies old runs, creates and opens a fresh run |
| `check.ts` | `npm run check` inside a run: proves the result, line by line |
| `template/` | the starter app every run begins from (Node + TypeScript, no dependencies), with its `CLAUDE.md`, permissions and the driver's playbook (`.claude/skills/worktree-demo/`) |
| `setup_test.ts` | the tests for all of the above (`make demo-test`) |

Everything here runs on Node alone (22.18 or newer runs the `.ts` files as they are), which Shepherd
already needs. The demo ran on Deno until 2026-10-20.
