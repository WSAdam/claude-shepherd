#!/usr/bin/env bash
# ledger.test.sh - the audit/event ledger: cc_ledger_append gating + stamping,
# cc-approve.sh decision provenance (by:), and cc-status.sh lifecycle events.
# Side-effect-free: temp dirs only; nothing touches ~/.claude.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_LEDGER_DIR="$TMP/ledger"
export CC_CONFIG_FILE="$TMP/cfg.json"
mkdir -p "$CC_STATUS_DIR"

DAY="$(date -u +%Y-%m-%d)"
LF="$CC_LEDGER_DIR/$DAY.jsonl"

# count ledger lines matching a jq boolean filter (0 if the file is absent)
lcount() { { [ -f "$LF" ] && jq -c "select($1)" "$LF" 2>/dev/null; } | grep -c . ; }

# ---- cc_ledger_append: gating + stamping -----------------------------------
echo '{ "ledger": { "enabled": true } }' > "$CC_CONFIG_FILE"
( . "$ROOT/cc-lib.sh"; cc_ledger_append "$(jq -nc '{type:"prompt",session_id:"s1",prompt:"hi"}')" )
assert_eq "append: enabled writes one line" "1" "$( [ -f "$LF" ] && wc -l < "$LF" | tr -d ' ' || echo 0 )"
assert_eq "append: stamps v=1" "1" "$(jq -r 'select(.session_id=="s1").v' "$LF")"
assert_eq "append: stamps an id" "true" "$(jq -r 'select(.session_id=="s1").id|test("-")' "$LF")"
assert_eq "append: ts is numeric" "number" "$(jq -r 'select(.session_id=="s1").ts|type' "$LF")"

# disabled -> no write
rm -f "$LF"
echo '{ "ledger": { "enabled": false } }' > "$CC_CONFIG_FILE"
( . "$ROOT/cc-lib.sh"; cc_ledger_append "$(jq -nc '{type:"prompt",session_id:"s2"}')" )
assert_absent "append: disabled writes nothing" "$LF"

# captureTypes filter: only "decision" recorded
echo '{ "ledger": { "enabled": true, "captureTypes": ["decision"] } }' > "$CC_CONFIG_FILE"
( . "$ROOT/cc-lib.sh"
  cc_ledger_append "$(jq -nc '{type:"prompt",session_id:"s3"}')"
  cc_ledger_append "$(jq -nc '{type:"decision",session_id:"s3",outcome:"allow",by:"human"}')" )
assert_eq "captureTypes: prompt skipped" "0" "$(lcount '.session_id=="s3" and .type=="prompt"')"
assert_eq "captureTypes: decision kept"  "1" "$(lcount '.session_id=="s3" and .type=="decision"')"

# ---- cc-approve.sh decision provenance (auto policies; no panel needed) -----
rm -f "$LF"
export CC_APPROVED_DIR="$TMP/appr"
export CC_AUTOPILOT_DIR="$TMP/auto"
FLAG="$TMP/gate.enabled"; touch "$FLAG"
POL="$TMP/policy.json"
cat > "$POL" <<'JSON'
{ "ledger": { "enabled": true },
  "policies": {
    "patterns": { "enabled": true, "autoDeny": ["Bash(rm -rf*)"], "autoAllow": ["Bash(ls*)"] },
    "autopilot": { "enabled": true, "minutes": 15 },
    "approveRepeats": true } }
JSON
APP="$ROOT/cc-approve.sh"
runpol() { printf '%s' "$1" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$POL" bash "$APP" >/dev/null 2>&1; }

runpol '{"session_id":"d1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
assert_eq "decision: autoDeny -> by autoDeny + deny" "1" "$(lcount '.type=="decision" and .by=="autoDeny" and .outcome=="deny"')"
assert_eq "decision: autoDeny carries the pattern" "1" "$(lcount '.by=="autoDeny" and .pattern=="Bash(rm -rf*)"')"

runpol '{"session_id":"a1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_eq "decision: autoAllow -> by autoAllow + allow" "1" "$(lcount '.by=="autoAllow" and .outcome=="allow"')"

mkdir -p "$CC_AUTOPILOT_DIR"; echo 9999999999 > "$CC_AUTOPILOT_DIR/ap1"
runpol '{"session_id":"ap1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}'
assert_eq "decision: autopilot -> by autopilot + allow" "1" "$(lcount '.by=="autopilot" and .outcome=="allow"')"

mkdir -p "$CC_APPROVED_DIR"; printf 'Bash|git push\n' > "$CC_APPROVED_DIR/r1"
runpol '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git push"}}'
assert_eq "decision: approveRepeats -> by approveRepeats" "1" "$(lcount '.by=="approveRepeats" and .outcome=="allow"')"

# ---- cc-status.sh lifecycle events -----------------------------------------
rm -f "$LF"
STAT="$ROOT/cc-status.sh"
echo '{ "ledger": { "enabled": true } }' > "$CC_CONFIG_FILE"
printf '%s' '{"session_id":"L1","cwd":"/x/proj","transcript_path":"/h/.claude/projects/ENC/L1.jsonl"}' \
  | bash "$STAT" sessionstart >/dev/null 2>&1
assert_eq "lifecycle: sessionstart -> session_start" "1" "$(lcount '.type=="session_start" and .session_id=="L1"')"
assert_eq "lifecycle: projectKey from transcript_path" "ENC" \
  "$(jq -r 'select(.session_id=="L1" and .type=="session_start").projectKey' "$LF")"

printf '%s' '{"session_id":"L1","cwd":"/x/proj","prompt_text":"do a thing"}' \
  | bash "$STAT" userpromptsubmit >/dev/null 2>&1
assert_eq "lifecycle: userpromptsubmit -> prompt" "1" "$(lcount '.type=="prompt" and .prompt=="do a thing"')"

printf '%s' '{"session_id":"L1","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | bash "$STAT" permissionrequest >/dev/null 2>&1
assert_eq "lifecycle: permissionrequest -> tool_request" "1" "$(lcount '.type=="tool_request" and .tool=="Bash"')"

# session_end is recorded even though the status file is removed
printf '%s' '{"session_id":"L1","cwd":"/x/proj"}' | bash "$STAT" sessionend >/dev/null 2>&1
assert_eq "lifecycle: sessionend -> session_end" "1" "$(lcount '.type=="session_end" and .session_id=="L1"')"

finish
