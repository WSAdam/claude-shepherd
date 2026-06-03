#!/usr/bin/env bash
# gate.test.sh - exercise cc-approve.sh (the opt-in approval gate) across its
# safety paths. Side-effect-free: temp CC_STATUS_DIR, no real sessions.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"

APP="$ROOT/cc-approve.sh"
FLAG="$TMP/gate.enabled"
HB="$TMP/.panel-alive"
GATED='{"session_id":"g1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'

# 1. disabled -> silent no-op (this is what makes it safe to always wire)
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$TMP/nope" bash "$APP" 2>/dev/null)"
assert_eq "disabled: no stdout" "" "$out"

# 2. armed but panel not alive (no heartbeat) -> falls through, no decision
touch "$FLAG"
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=5 bash "$APP" 2>/dev/null)"
assert_eq "no heartbeat: no stdout (never freezes)" "" "$out"

# 3. armed + non-gated tool -> falls through (reads stay fast)
date +%s > "$HB"
READTOOL='{"session_id":"g2","cwd":"/x/p","tool_name":"Read","tool_input":{"file_path":"/x/p/a.txt"}}'
out="$(printf '%s' "$READTOOL" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "non-gated tool: no stdout" "" "$out"

# 4. armed + fresh panel + gated tool + ALLOW decision -> emits allow JSON
date +%s > "$HB"
( printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_allow" 2>/dev/null ) &
bg=$!
sleep 0.5
printf 'allow' > "$TMP/g1.decision"
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_allow" 2>/dev/null)"
assert_eq "allow decision -> permissionDecision allow" "allow" "$got"

# 5. armed + fresh panel + gated tool + DENY decision -> emits deny JSON
date +%s > "$HB"
( printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_deny" 2>/dev/null ) &
bg=$!
sleep 0.5
printf 'deny' > "$TMP/g1.decision"
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_deny" 2>/dev/null)"
assert_eq "deny decision -> permissionDecision deny" "deny" "$got"

# 6. timeout with no decision -> no stdout (falls back to native prompt)
date +%s > "$HB"
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 \
    bash "$APP" 2>/dev/null)"
assert_eq "timeout: no decision emitted" "" "$out"

finish
