# Worktree demo app

A tiny Node + TypeScript app (no dependencies; Node 22.18+ runs the `.ts` files as they are) that
exists to demonstrate Shepherd's parallel worktree flow: two units change it at the same time in two
worktrees, and both land on main. The walkthrough is `demo/GUIDE.md` in the Shepherd repo; the
mechanics are `demo/HOW-IT-WORKS.md`.

- **Tests:** `npm test` runs the whole suite (Node's own test runner, `node:test`). It must pass in
  a unit's worktree, again after rebasing on main, and on main after the merge.
- **Units** follow the global worktree and ready-to-merge flow: `EnterWorktree` with the unit's
  name, rename the branch to `feat/<name>`, and finish with `~/.claude/cc-merge.sh request
  --worktree <path>` from the main checkout, in the background.
- **Merge conflicts: the tests are the oracle.** Both units add to the end of the same two files, so
  the second merge conflicts on purpose. Keep both sides — both functions and both tests — and the
  merge is done when `npm test` passes on the merged result.
- There are no post-merge deploy steps.
- **Driving a run:** the `worktree-demo` skill (say "run the worktree demo"). `npm run check`
  verifies a finished run.
