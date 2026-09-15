#!/usr/bin/env bash
# run.sh - run Claude Shepherd's whole test suite (bash + standalone lua).
# Side-effect-free: every suite uses temp dirs and recorder doubles. Never
# touches ~/.claude/cc-status, never fires keystrokes, never spawns a session.

DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0

echo "== bash: config =="
bash "$DIR/config.test.sh" || fail=1
echo ""
echo "== bash: status writer =="
bash "$DIR/status.test.sh" || fail=1
echo ""
echo "== bash: cc-lib helpers =="
bash "$DIR/lib.test.sh" || fail=1
echo ""
echo "== bash: GC-unsafe timer guard =="
bash "$DIR/lint-timers.sh" || fail=1
echo ""
echo "== bash: editor detection =="
bash "$DIR/editor.test.sh" || fail=1
echo ""
echo "== bash: AskUserQuestion capture =="
bash "$DIR/ask.test.sh" || fail=1
echo ""
echo "== bash: approval gate =="
bash "$DIR/gate.test.sh" || fail=1
echo ""
echo "== bash: ready-to-merge requests (cc-merge.sh) =="
bash "$DIR/merge.test.sh" || fail=1
echo ""
echo "== bash: batch driving (cc-fleet.sh) =="
bash "$DIR/fleet.test.sh" || fail=1
echo ""
echo "== bash: questions held for Shepherd (cc-ask.sh) =="
bash "$DIR/ask-hold.test.sh" || fail=1
echo ""
echo "== bash: audit ledger =="
bash "$DIR/ledger.test.sh" || fail=1
echo ""
echo "== bash: installer =="
bash "$DIR/install.test.sh" || fail=1
echo ""
echo "== bash: installer suite without the optional tools (no rg/fd/Homebrew) =="
bash "$DIR/install-hermetic.test.sh" || fail=1
echo ""
echo "== bash: xss escaping tripwire =="
bash "$DIR/escaping.test.sh" || fail=1
echo ""
echo "== bash: worklist UI wiring tripwire =="
bash "$DIR/worklist-ui.test.sh" || fail=1
echo ""
echo "== node: Done-drawer ordering (behavioral, runs the shipped comparator) =="
node "$DIR/done-order.test.js" || fail=1
echo ""
echo "== node: tile presses (behavioral, runs the shipped press logic) =="
node "$DIR/tile-dblclick.test.js" || fail=1
echo ""
echo "== node: tile presses in a real browser (skips without Playwright) =="
node "$DIR/tile-press.browser.test.js" || fail=1
echo ""
echo "== node: the merge review keeps its buttons in view in a real browser (skips without Playwright) =="
node "$DIR/merge-review.browser.test.js" || fail=1
echo ""
echo "== node: project cards (behavioral, runs the shipped fold + card extras) =="
node "$DIR/stack-fold.test.js" || fail=1
echo ""
echo "== node: the New worktree tab form (behavioral, runs the shipped form helpers) =="
node "$DIR/new-tab-form.test.js" || fail=1
echo ""
echo "== node: the Shepherd companion VS Code extension (behavioral, the real extension against a fake vscode) =="
node "$DIR/bridge.test.js" || fail=1
echo ""
echo "== bash: the companion extension packages and installs locally (fake VS Code CLI) =="
bash "$DIR/bridge-build.test.sh" || fail=1
echo ""
echo "== bash: CLI-tools viewer wiring tripwire =="
bash "$DIR/mcpskills-tools.test.sh" || fail=1
echo ""
echo "== bash: prune UI wiring tripwire =="
bash "$DIR/prune-ui.test.sh" || fail=1
echo ""
echo "== bash: worktree hygiene (.gitignore keeps git worktree remove unblocked) =="
bash "$DIR/worktree-hygiene.test.sh" || fail=1
echo ""
echo "== lua: cc-core =="
lua "$DIR/core.test.lua" || fail=1
echo ""
echo "== lua: panel UX =="
lua "$DIR/ui.test.lua" || fail=1
echo ""

echo "== lua: dashboard smoke (load + first refresh under a stubbed hs) =="
# Redirect HOME so a stray read/write can't touch the real ~/.claude.
HOME="$(mktemp -d)" lua "$DIR/smoke.test.lua" || fail=1
echo ""
echo "== lua: My List auto-sync keeps renamed tabs (behavioral, stubbed hs) =="
HOME="$(mktemp -d)" lua "$DIR/worklist-autosync.test.lua" || fail=1
echo ""
echo "== lua: My List -- one tab per project across worktrees (behavioral, stubbed hs + git) =="
HOME="$(mktemp -d)" lua "$DIR/worklist-worktrees.test.lua" || fail=1
echo ""
echo "== lua: a session working in another worktree (behavioral, stubbed hs + git) =="
HOME="$(mktemp -d)" lua "$DIR/tab-worktree.test.lua" || fail=1
echo ""
echo "== lua: no keystrokes into a window shared by several sessions (behavioral, stubbed hs) =="
HOME="$(mktemp -d)" lua "$DIR/shared-window.test.lua" || fail=1
echo ""
echo "== lua: a leftover claude process with no tab is marked, and End stops only it (behavioral, stubbed hs + ps) =="
HOME="$(mktemp -d)" lua "$DIR/tabless.test.lua" || fail=1
echo ""
echo "== lua: batch driving -- one approval, unit tabs, merges on the grant (behavioral, stubbed hs + git) =="
HOME="$(mktemp -d)" lua "$DIR/fleet.test.lua" || fail=1
echo ""
echo "== lua: ready to merge -- review, one merge per repo, Not yet (behavioral, stubbed hs + git) =="
HOME="$(mktemp -d)" lua "$DIR/merge-request.test.lua" || fail=1
echo ""
echo "== lua: Shepherd answers -- a held question answered from the card (behavioral, stubbed hs) =="
HOME="$(mktemp -d)" lua "$DIR/ask.test.lua" || fail=1
echo ""
echo "== node: the answer form (behavioral, runs the shipped form helpers) =="
node "$DIR/ask-form.test.js" || fail=1
echo ""
echo "== node: a card waiting on Adam says Needs you (behavioral, runs the shipped status helpers) =="
node "$DIR/needs-you.test.js" || fail=1
echo ""
echo "== node: ⌘V lands in the focused field, not the nudge box (behavioral, runs the shipped paste helpers) =="
node "$DIR/paste-target.test.js" || fail=1
echo ""
echo "== deno: the worktree demo's setup and check (demo/) =="
if command -v deno >/dev/null 2>&1; then
  (cd "$DIR/.." && deno test -A --quiet demo/) || fail=1
else
  echo "skipped: deno isn't installed (the demo needs it; https://deno.com)"
fi
echo ""
echo "== lua: New worktree tab opens a prefilled Claude tab, never a keystroke (behavioral, stubbed hs + git) =="
HOME="$(mktemp -d)" lua "$DIR/new-worktree-tab.test.lua" || fail=1
echo ""
echo "== lua: a new session in a window that already has a Claude tab gets its own tab (behavioral, stubbed hs) =="
HOME="$(mktemp -d)" lua "$DIR/spawn-open-window.test.lua" || fail=1
echo ""

if [ "$fail" -eq 0 ]; then
  echo "✅ ALL GREEN"
else
  echo "❌ SOME TESTS FAILED"
fi
exit $fail
