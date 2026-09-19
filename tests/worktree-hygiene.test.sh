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

# 2026-09-19: half of this file asserts against the REAL checkout's git index -- what a clone
# ships, and what it must not. Outside a git repo `git ls-files` exits 128 with empty output,
# so every one of those read 0 and the suite went red: the README offers a ZIP download as the
# first install step, and install.sh gates on this suite, so an unzipped copy aborted its own
# install. There is nothing to assert about an index that isn't there, so those checks skip --
# loudly, naming the reason -- and everything else (the throwaway repo below, the fixture
# scrubbing) still runs. In a real checkout nothing changes.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then HAVE_INDEX=yes; else HAVE_INDEX=no; fi
skip_index() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "skip - $1 (no git index here -- a ZIP download, not a clone)"
}

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
  if [ "$HAVE_INDEX" = no ]; then skip_index "$p is not tracked in this (public) repo"; continue; fi
  got="$(git -C "$ROOT" ls-files -- "$p" | wc -l | tr -d ' ')"
  assert_eq "$p is not tracked in this (public) repo" "0" "$got"
done
# 2026-09-17 live: a coworker's clone had no defaults/cc-config.json -- the `cc-config.json` ignore
# rule (for personal configs) silently kept it out of the commit, so his install lacked Adam's
# settings and its test gate failed. Every file the installers read must be in a clone.
for p in install.sh bootstrap.sh uninstall.sh "Install Shepherd.command" "Uninstall Shepherd.command" \
         settings-hooks.json defaults/cc-config.json defaults/claude-settings.json methodology/CLAUDE.md \
         cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-core.lua \
         claude-dashboard.lua app/build-app.sh vscode-bridge/package.json vscode-bridge/extension.js \
         vscode-bridge/lib.js vscode-bridge/build-vsix.sh vscode-bridge/install-vsix.sh Makefile tests/run.sh \
         .github/workflows/ci.yml; do
  if [ "$HAVE_INDEX" = no ]; then skip_index "$p is tracked, so a clone can install"; continue; fi
  got="$(git -C "$ROOT" ls-files -- "$p" | wc -l | tr -d ' ')"
  assert_eq "$p is tracked, so a clone can install" "1" "$got"
done
for p in Scratch-pad/anything.html docs/feature-mining/x.md docs/orchestrator-next.md docs/hardware-verification.md todos.md; do
  if git -C "$REPO" check-ignore -q "$p"; then got=ignored; else got=untracked; fi
  assert_eq "$p is gitignored" "ignored" "$got"
done

# 2026-09-18: tests/fixtures/transcripts/ holds windows cut from REAL session transcripts, for
# tests/transcript-replay.test.lua. It is tracked on purpose, and only ever scrubbed: a raw
# transcript carries prompts, paths and client names, and this repo is public. Every tracked
# fixture is small (no LFS here), has no CRLF (CI replays it on Linux, byte for byte) and holds
# no word outside vocabulary.txt (check-scrubbed.js); nothing else may live in that folder.
FXT="tests/fixtures/transcripts"
if [ "$HAVE_INDEX" = no ]; then
  skip_index "transcript fixtures are tracked, so a clone can replay them"
  skip_index "nothing but fixtures, the scrubber, its checker and their notes is tracked in $FXT"
else
  got="$(git -C "$ROOT" ls-files -- "$FXT" | grep -c '\.jsonl$')"
  if [ "$got" -ge 1 ]; then got=yes; else got=no; fi
  assert_eq "transcript fixtures are tracked, so a clone can replay them" "yes" "$got"
  got="$(git -C "$ROOT" ls-files -- "$FXT" | grep -v -e '\.jsonl$' -e '/scrub\.js$' -e '/check-scrubbed\.js$' -e '/vocabulary\.txt$' -e '/README\.md$' | wc -l | tr -d ' ')"
  assert_eq "nothing but fixtures, the scrubber, its checker and their notes is tracked in $FXT" "0" "$got"
fi
# The per-fixture checks below read the files themselves, not the index, so they run either
# way: outside a repo the list comes from the folder instead of `git ls-files`.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  size="$(wc -c < "$ROOT/$f" | tr -d ' ')"
  if [ "$size" -le 102400 ]; then got=small; else got="$size bytes"; fi
  assert_eq "$f is under 100KB" "small" "$got"
  if LC_ALL=C grep -q "$(printf '\r')" "$ROOT/$f"; then got=crlf; else got=lf; fi
  assert_eq "$f has no carriage returns" "lf" "$got"
  if node "$ROOT/$FXT/check-scrubbed.js" "$ROOT/$f" >/dev/null 2>&1; then got=scrubbed; else got=readable; fi
  assert_eq "$f holds no readable text" "scrubbed" "$got"
done <<EOF
$(if [ "$HAVE_INDEX" = yes ]; then git -C "$ROOT" ls-files -- "$FXT" | grep '\.jsonl$'
   else (cd "$ROOT" && ls -1 "$FXT"/*.jsonl 2>/dev/null); fi)
EOF
# ...and the checker itself goes red on the real thing: one unscrubbed record among scrubbed ones.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"xxxx xxx"}}' \
  '{"type":"user","message":{"role":"user","content":"please fix the refund page"}}' > "$TMP/raw.jsonl"
if node "$ROOT/$FXT/check-scrubbed.js" "$TMP/raw.jsonl" >/dev/null 2>&1; then got=passed; else got=refused; fi
assert_eq "a fixture with one unscrubbed prompt in it is refused" "refused" "$got"

finish
