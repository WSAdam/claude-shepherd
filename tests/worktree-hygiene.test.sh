#!/usr/bin/env bash
# worktree-hygiene.test.sh - the repo's .gitignore keeps the parallel-worktree workflow
# unblocked. Side-effect-free: builds a throwaway repo in a temp dir using THIS repo's
# .gitignore and never touches the real checkout's worktrees.
#
# 2026-09-10: TODO.md is untracked here (Shepherd's My List reads it; it is never committed),
# and `git worktree remove` refuses any worktree holding an untracked file -- so a worktree
# session writing its TODO.md made the workflow's cleanup step need --force. Ignored files
# don't count as untracked for that check, so the fix is to gitignore TODO.md.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
WT="$TMP/repo-fix-demo"
git init -q "$REPO"
cp "$ROOT/.gitignore" "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm init
git -C "$REPO" worktree add -q "$WT" -b fix/demo 2>/dev/null

# A worktree session writes its own TODO.md, then the unit merges and the worktree goes.
printf -- '- [ ] demo item (worktree-hygiene)\n' > "$WT/TODO.md"
if git -C "$REPO" worktree remove "$WT" 2>/dev/null; then got=removed; else got=refused; fi
assert_eq "a worktree holding its TODO.md removes cleanly without --force" "removed" "$got"

# Worktrees Claude Code creates itself live under .claude/worktrees/ -- never untracked noise.
if git -C "$REPO" check-ignore -q .claude/worktrees/anything; then got=ignored; else got=untracked; fi
assert_eq "Claude-made worktrees under .claude/worktrees/ are gitignored" "ignored" "$got"

# 2026-09-17: the public repo tracked 31 Scratch-pad/ files -- Chargeback portal pages, design
# mockups and Playwright snapshots from other work -- plus notes only our own work on Shepherd
# uses. A fresh install gets what it runs on (code, README, CLAUDE.md, context.md, spec, demo);
# these stay local only.
for p in Scratch-pad docs/feature-mining docs/orchestrator-next.md docs/hardware-verification.md todos.md; do
  got="$(git -C "$ROOT" ls-files -- "$p" | wc -l | tr -d ' ')"
  assert_eq "$p is not tracked in this (public) repo" "0" "$got"
done
for p in Scratch-pad/anything.html docs/feature-mining/x.md docs/orchestrator-next.md docs/hardware-verification.md todos.md; do
  if git -C "$REPO" check-ignore -q "$p"; then got=ignored; else got=untracked; fi
  assert_eq "$p is gitignored" "ignored" "$got"
done

finish
