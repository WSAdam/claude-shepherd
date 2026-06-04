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
echo "== bash: editor detection =="
bash "$DIR/editor.test.sh" || fail=1
echo ""
echo "== bash: AskUserQuestion capture =="
bash "$DIR/ask.test.sh" || fail=1
echo ""
echo "== bash: approval gate =="
bash "$DIR/gate.test.sh" || fail=1
echo ""
echo "== lua: cc-core =="
lua "$DIR/core.test.lua" || fail=1
echo ""
echo "== lua: panel UX =="
lua "$DIR/ui.test.lua" || fail=1
echo ""

if [ "$fail" -eq 0 ]; then
  echo "✅ ALL GREEN"
else
  echo "❌ SOME TESTS FAILED"
fi
exit $fail
