#!/usr/bin/env bash
# ledger-quarantine.test.sh - tools/ledger-quarantine.sh moves the test suite's synthetic events
# out of a ledger, keeping them (never deleting) under quarantine/ (2026-09-28).
# 2026-09-28: status.test.sh, ask.test.sh and editor.test.sh wrote ~15k fake events (cwd /p,
# /U/x/proj, /srv/..., /Users/x/...) into Adam's real ~/.claude/cc-ledger. Past days' files are
# rewritten atomically; today's file is live (hooks append to it unlocked), so it's left alone.

. "$(dirname "$0")/lib.sh"
Q="$ROOT/tools/ledger-quarantine.sh"
L="$(mktemp_dir)"
trap 'rm -rf "$L"' EXIT

PAST="$L/2026-09-20.jsonl"
TODAY="$L/$(date -u +%Y-%m-%d).jsonl"
cat > "$PAST" <<'EOF'
{"v":1,"ts":1,"id":"a","type":"session_start","session_id":"0a1b2c3d-0000-0000-0000-000000000001","cwd":"/Users/adam/Programming/real"}
{"v":1,"ts":2,"id":"b","type":"session_start","session_id":"t1","cwd":"/Users/x/Programming/my-project"}
{"v":1,"ts":3,"id":"c","type":"prompt","session_id":"ask1","cwd":"/U/x/proj"}
{"v":1,"ts":4,"id":"d","type":"prompt","session_id":"vsc","cwd":"/U/x/proj-a"}
{"v":1,"ts":5,"id":"e","type":"tool_request","session_id":"p1","cwd":"/p"}
{"v":1,"ts":6,"id":"f","type":"tool_request","session_id":"x1","cwd":"/x/p"}
{"v":1,"ts":7,"id":"g","type":"session_end","session_id":"bb","cwd":"/srv/bb"}
{"v":1,"ts":8,"id":"h","type":"session_end","session_id":"o1","cwd":"/other/my-project"}
{"v":1,"ts":9,"id":"i","type":"usage_snapshot","session_id":"0a1b2c3d-0000-0000-0000-000000000002"}
{"v":1,"ts":10,"id":"j","type":"prompt","session_id":"0a1b2c3d-0000-0000-0000-000000000003","cwd":"/Users/adam/Programming/pad"}
not json at all
EOF
cat > "$TODAY" <<'EOF'
{"v":1,"ts":11,"id":"k","type":"session_start","session_id":"t1","cwd":"/Users/x/Programming/my-project"}
{"v":1,"ts":12,"id":"l","type":"session_start","session_id":"0a1b2c3d-0000-0000-0000-000000000004","cwd":"/Users/adam/Programming/real"}
EOF
cp "$TODAY" "$L/today.before"

out="$(bash "$Q" --ledger "$L" --dry-run)"
assert_eq "--dry-run reports what it would move" "yes" "$(printf '%s' "$out" | grep -q '7 synthetic' && echo yes || echo no)"
assert_eq "--dry-run changes nothing" "11" "$(wc -l < "$PAST" | tr -d ' ')"
assert_absent "--dry-run writes no quarantine" "$L/quarantine"

out="$(bash "$Q" --ledger "$L")"
assert_eq "exits 0" "0" "$?"
assert_eq "the past day keeps its 3 real events and the unparseable line" "4" "$(wc -l < "$PAST" | tr -d ' ')"
assert_eq "...in their original order" "a i j" "$(jq -r '.id' "$PAST" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the synthetic events are kept under quarantine/, not deleted" "7" "$(wc -l < "$L/quarantine/2026-09-20.jsonl" | tr -d ' ')"
assert_eq "today's live file is left exactly as it was" "same" "$(cmp -s "$TODAY" "$L/today.before" && echo same || echo changed)"
assert_eq "it says today's file waits for a later run" "yes" "$(printf '%s' "$out" | grep -qi 'today' && echo yes || echo no)"

bash "$Q" --ledger "$L" > /dev/null
assert_eq "a second run changes nothing" "4" "$(wc -l < "$PAST" | tr -d ' ')"
assert_eq "...and doesn't duplicate the quarantine" "7" "$(wc -l < "$L/quarantine/2026-09-20.jsonl" | tr -d ' ')"
assert_eq "a missing ledger folder is not an error" "0" "$(bash "$Q" --ledger "$L/nope" > /dev/null 2>&1; echo $?)"

finish
