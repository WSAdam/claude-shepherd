#!/usr/bin/env bash
# ledger-isolation.test.sh - no suite may write into the real ~/.claude ledger (2026-09-28).
# 2026-09-28: status.test.sh, ask.test.sh and editor.test.sh exported only CC_STATUS_DIR, so the
# hooks they drive read the REAL ~/.claude/cc-config.json -- Adam's has the ledger on -- and
# appended the suites' fake events (cwd /p, /U/x/proj, /srv/...) to his real cc-ledger: ~15k of
# them over a month, 40 per run, skewing Insights. Runs those suites against a fake HOME whose
# config has the ledger on, and fails if anything lands in that HOME's ledger.

. "$(dirname "$0")/lib.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"

# every suite that sources lib.sh gets its own ledger dir and an empty config by default
under_real_claude() { # <path>: yes when it's empty or inside the real ~/.claude
  case "$1" in
    "") echo yes ;;
    "$HOME"/.claude*) echo yes ;;
    *) echo no ;;
  esac
}
assert_eq "lib.sh points CC_LEDGER_DIR at a temp dir, not ~/.claude" "no" "$(under_real_claude "${CC_LEDGER_DIR:-}")"
assert_eq "lib.sh points CC_CONFIG_FILE at a temp file, not ~/.claude" "no" "$(under_real_claude "${CC_CONFIG_FILE:-}")"

FAKES=()
trap 'rm -rf "${FAKES[@]}"' EXIT
for s in status ask editor; do
  FAKE="$(mktemp_dir)"; FAKES+=("$FAKE")
  mkdir -p "$FAKE/.claude"
  printf '{"ledger":{"enabled":true}}' > "$FAKE/.claude/cc-config.json"
  # a clean environment, as tests/run.sh gives each suite (hermetic-env.sh drops CC_*)
  env -i HOME="$FAKE" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" bash "$DIR/$s.test.sh" > /dev/null 2>&1
  n="$(cat "$FAKE/.claude/cc-ledger/"*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$s.test.sh writes nothing into HOME's ledger" "0" "$n"
done

finish
