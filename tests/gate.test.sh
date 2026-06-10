#!/usr/bin/env bash
# gate.test.sh - exercise cc-approve.sh (the opt-in approval gate) across its
# safety paths. Side-effect-free: temp CC_STATUS_DIR, no real sessions.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"
# Keep the base tests hermetic: no policy config, isolated policy dirs.
export CC_CONFIG_FILE="$TMP/none.json"
export CC_APPROVED_DIR="$TMP/appr"
export CC_AUTOPILOT_DIR="$TMP/auto"
export CC_GATE_TOOLS_DIR="$TMP/gtools"

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

# ---- Phase 4c policies (decide WITHOUT a panel; no heartbeat needed) ----
# Remove the heartbeat left by earlier tests so the "no decision" cases fall
# through immediately instead of polling for a panel that isn't answering.
rm -f "$HB"
POL="$TMP/policy.json"
cat > "$POL" <<'JSON'
{ "policies": {
    "patterns": { "enabled": true, "autoDeny": ["Bash(rm -rf*)"], "autoAllow": ["Read", "Bash(ls*)"] },
    "autopilot": { "enabled": true, "minutes": 15 },
    "approveRepeats": true } }
JSON
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null; }
runpol() { printf '%s' "$2" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$POL" bash "$APP" 2>/dev/null; }

# D: pattern auto-deny (safety) wins, even though the panel isn't running
out="$(runpol x '{"session_id":"d1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
assert_eq "policy autoDeny -> deny" "deny" "$(decision "$out")"

# D: pattern auto-allow
out="$(runpol x '{"session_id":"a1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
assert_eq "policy autoAllow -> allow" "allow" "$(decision "$out")"

# C: per-session autopilot (future expiry) -> allow anything gated
mkdir -p "$CC_AUTOPILOT_DIR"; echo 9999999999 > "$CC_AUTOPILOT_DIR/ap1"
out="$(runpol x '{"session_id":"ap1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}')"
assert_eq "autopilot -> allow" "allow" "$(decision "$out")"

# C: expired autopilot does NOT auto-allow (no panel -> no output)
echo 1 > "$CC_AUTOPILOT_DIR/ap2"
out="$(runpol x '{"session_id":"ap2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}')"
assert_eq "expired autopilot -> no decision" "" "$out"

# B: approve-repeats (pre-seeded approved-set) -> allow
mkdir -p "$CC_APPROVED_DIR"; printf 'Bash|git push\n' > "$CC_APPROVED_DIR/r1"
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git push"}}')"
assert_eq "approveRepeats -> allow" "allow" "$(decision "$out")"

# B: an unseen command is NOT auto-allowed (no panel -> no output)
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}')"
assert_eq "unseen command -> no decision" "" "$out"

# ---- gate.tools: the gated-tool list is panel-editable via config ----
date +%s > "$HB"
TOOLSCFG="$TMP/tools.json"
echo '{"gate":{"tools":"WebFetch"}}' > "$TOOLSCFG"
# a tool in the custom list is now gated (waits -> ALLOW decision -> allow)
( printf '%s' '{"session_id":"t1","cwd":"/x/p","tool_name":"WebFetch","tool_input":{"url":"https://x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$TOOLSCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_tools" 2>/dev/null ) &
bg=$!
sleep 0.5
printf 'allow' > "$TMP/t1.decision"
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_tools" 2>/dev/null)"
assert_eq "config gate.tools: custom tool is gated -> allow" "allow" "$got"
# a tool OUTSIDE the custom list falls straight through (Bash isn't gated here)
out="$(printf '%s' '{"session_id":"t2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$TOOLSCFG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "config gate.tools: tool outside list falls through" "" "$out"

# ---- precedence + approveRepeats write path (improve cards) ----
# A command matching BOTH autoDeny and autoAllow must be DENIED (safety first).
BOTH="$TMP/both.json"
cat > "$BOTH" <<'JSON'
{ "policies": { "patterns": { "enabled": true,
    "autoDeny": ["Bash(rm*)"], "autoAllow": ["Bash(rm*)"] } } }
JSON
out="$(printf '%s' '{"session_id":"p1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm x"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$BOTH" bash "$APP" 2>/dev/null)"
assert_eq "precedence: autoDeny beats autoAllow" "deny" "$(decision "$out")"

# approveRepeats: a panel ALLOW must append the SIG so the next identical request
# auto-allows (previously only the pre-seeded read path was covered).
rm -f "$CC_APPROVED_DIR"/* 2>/dev/null
REPCFG="$TMP/rep.json"; echo '{"policies":{"approveRepeats":true}}' > "$REPCFG"
date +%s > "$HB"
REQ='{"session_id":"rep1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"npm run build"}}'
( printf '%s' "$REQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" >/dev/null 2>&1 ) &
bg=$!; sleep 0.5; printf 'allow' > "$TMP/rep1.decision"; wait $bg
assert_eq "approveRepeats: panel allow records the SIG" "Bash|npm run build" "$(cat "$CC_APPROVED_DIR/rep1" 2>/dev/null)"
# the 2nd identical request now auto-allows with NO panel (approveRepeats fires first)
rm -f "$HB"
out="$(printf '%s' "$REQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "approveRepeats: 2nd identical request auto-allows" "allow" "$(decision "$out")"

# ---- Feature D: per-session gated-tools override (least-privilege) ----
mkdir -p "$CC_GATE_TOOLS_DIR"
# Poll for the per-key status file the gate writes right before it begins waiting for
# a decision, so we write the decision only once the hook is actually blocked — robust
# on slow boxes (no fixed sleep that could race the hook's startup). ~5s timeout.
wait_block() { # $1 = status json path
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -f "$1" ] && return 0
    sleep 0.05; i=$((i+1))
  done
  return 1
}

# A) override that gates a tool NOT in the fleet default -> that tool is now gated
date +%s > "$HB"
printf 'WebFetch\n' > "$CC_GATE_TOOLS_DIR/ov1"
( printf '%s' '{"session_id":"ov1","cwd":"/x/p","tool_name":"WebFetch","tool_input":{"url":"https://x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov1.json"; printf 'allow' > "$TMP/ov1.decision"; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov1" 2>/dev/null)"
assert_eq "per-session override: added tool is gated -> allow" "allow" "$got"

# B) "-" override gates NOTHING: a normally-gated Bash falls straight through
printf -- '-\n' > "$CC_GATE_TOOLS_DIR/ov2"
out="$(printf '%s' '{"session_id":"ov2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "per-session override: '-' gates nothing (Bash falls through)" "" "$out"

# C) NO override -> Bash is still gated exactly as before (no regression)
date +%s > "$HB"
( printf '%s' '{"session_id":"ov3","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov3" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov3.json"; printf 'deny' > "$TMP/ov3.decision"; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov3" 2>/dev/null)"
assert_eq "no override: Bash still gated (no regression)" "deny" "$got"

# D) key isolation: ov2's "-" override does NOT disable gating for a different key
date +%s > "$HB"
( printf '%s' '{"session_id":"ov4","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov4" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov4.json"; printf 'allow' > "$TMP/ov4.decision"; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov4" 2>/dev/null)"
assert_eq "key isolation: another session still gates Bash" "allow" "$got"

# E) EMPTY override file is NOT a sentinel: it falls back to the fleet default, so Bash
# is STILL gated (B1: a blank/half-written file must not silently disable the gate).
date +%s > "$HB"
: > "$CC_GATE_TOOLS_DIR/ov5"
( printf '%s' '{"session_id":"ov5","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov5" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov5.json"; printf 'deny' > "$TMP/ov5.decision"; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov5" 2>/dev/null)"
assert_eq "empty override file: Bash still gated (empty = fleet default)" "deny" "$got"

finish
