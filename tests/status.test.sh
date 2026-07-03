#!/usr/bin/env bash
# status.test.sh - drive cc-status.sh through every hook event and assert the
# resulting status JSON. Writes only to a throwaway CC_STATUS_DIR.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"

CC="$ROOT/cc-status.sh"
SID="t1"
CWD="/Users/x/Programming/my-project"
F="$TMP/$SID.json"

ev() { printf '%s' "$2" | bash "$CC" "$1" >/dev/null 2>&1; }

# sessionstart -> idle, identity captured
ev sessionstart "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
assert_json "sessionstart -> idle" "$F" '.status' "idle"
assert_json "name is folder basename" "$F" '.name' "my-project"
assert_json "session_id captured" "$F" '.session_id' "$SID"

# userpromptsubmit -> working + last_prompt
ev userpromptsubmit "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"prompt_text\":\"Fix the login bug\"}"
assert_json "userpromptsubmit -> working" "$F" '.status' "working"
assert_json "last_prompt captured" "$F" '.last_prompt' "Fix the login bug"

# pretooluse -> working
ev pretooluse "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
assert_json "pretooluse -> working" "$F" '.status' "working"

# notification permission_prompt -> approval + pending, last_prompt preserved
ev notification "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Allow Bash: ls\"}"
assert_json "notification -> approval" "$F" '.status' "approval"
assert_json "pending summary set" "$F" '.pending.summary' "Allow Bash: ls"
assert_json "last_prompt preserved across merge" "$F" '.last_prompt' "Fix the login bug"

# notification idle_prompt -> done
ev notification "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"idle_prompt\",\"message\":\"waiting\"}"
assert_json "notification idle -> done" "$F" '.status' "done"

# stop -> done, pending cleared
ev notification "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"permission_prompt\",\"message\":\"x\"}"
ev stop "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
assert_json "stop -> done" "$F" '.status' "done"
assert_json "stop clears pending" "$F" '.pending' "null"

# since holds while status unchanged, resets when it changes
ev stop "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
since1="$(jq -r '.since' "$F")"
ev stop "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
since2="$(jq -r '.since' "$F")"
assert_eq "since stable while status unchanged" "$since1" "$since2"

# collision: same basename, different session_id -> two files
ev sessionstart "{\"session_id\":\"t2\",\"cwd\":\"/other/my-project\"}"
count="$(ls -1 "$TMP"/*.json | wc -l | tr -d ' ')"
assert_eq "distinct session_ids -> distinct files" "2" "$count"

# sessionend removes the file, plus the session's per-key policy orphans
# (approveRepeats memo, autopilot expiry, gated-tools override — see cc_remove)
export CC_APPROVED_DIR="$TMP/appr" CC_AUTOPILOT_DIR="$TMP/auto" CC_GATE_TOOLS_DIR="$TMP/gtools"
export CC_POLICY_DIR="$TMP/policy" CC_POLICY_OVERRIDE_DIR="$TMP/policy-ovr"
mkdir -p "$CC_APPROVED_DIR" "$CC_AUTOPILOT_DIR" "$CC_GATE_TOOLS_DIR" "$CC_POLICY_DIR" "$CC_POLICY_OVERRIDE_DIR"
printf 'Bash|ls\n' > "$CC_APPROVED_DIR/$SID"
echo 9999999999 > "$CC_AUTOPILOT_DIR/$SID"
printf 'Bash\n' > "$CC_GATE_TOOLS_DIR/$SID"
printf '{"autoDeny":["Bash"]}\n' > "$CC_POLICY_DIR/$SID"
printf 'read-only\n' > "$CC_POLICY_OVERRIDE_DIR/$SID"
ev sessionend "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
assert_absent "sessionend removes the tile" "$F"
assert_absent "sessionend removes the approveRepeats memo" "$CC_APPROVED_DIR/$SID"
assert_absent "sessionend removes the autopilot expiry" "$CC_AUTOPILOT_DIR/$SID"
assert_absent "sessionend removes the L2 resolved policy" "$CC_POLICY_DIR/$SID"
assert_absent "sessionend removes the L2 policy override" "$CC_POLICY_OVERRIDE_DIR/$SID"
assert_absent "sessionend removes the gated-tools override" "$CC_GATE_TOOLS_DIR/$SID"

# R2-01: a same-status event whose existing .since is non-numeric (hand-edit /
# rsync-mirror / partial write) must NOT wedge the tile. The writer must coerce
# .since to numeric before --argjson, so the merge still advances `updated`.
R201="r201"; R201CWD="/srv/r201"; R201F="$TMP/$R201.json"
ev stop "{\"session_id\":\"$R201\",\"cwd\":\"$R201CWD\"}"
# corrupt .since to a non-numeric value, then fire another same-status (stop) event
jq '.since="soon" | .updated=1' "$R201F" > "$R201F.t" && mv "$R201F.t" "$R201F"
ev stop "{\"session_id\":\"$R201\",\"cwd\":\"$R201CWD\"}"
assert_eq "R2-01: non-numeric since does not wedge tile (updated advanced)" \
  "true" "$([ "$(jq -r '.updated' "$R201F")" -gt 1 ] && echo true || echo false)"
assert_eq "R2-01: since coerced to numeric" \
  "true" "$(jq -r '(.since|type)=="number"' "$R201F")"

# --- Phase 1: PermissionRequest gives a precise pending summary ---
P="p1"; PCWD="/srv/api-server"; PF="$TMP/$P.json"
ev pretooluse "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test -- --watch\"}}"
ev permissionrequest "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test -- --watch\"}}"
assert_json "permissionrequest -> approval" "$PF" '.status' "approval"
assert_json "permissionrequest Bash -> exact command" "$PF" '.pending.summary' "npm test -- --watch"

# a later generic Notification must NOT clobber the precise pending
ev notification "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs permission\"}"
assert_json "notification keeps precise pending" "$PF" '.pending.summary' "npm test -- --watch"

# Write tool -> file_path summary
W="p2"; WCWD="/srv/web"; WF="$TMP/$W.json"
ev permissionrequest "{\"session_id\":\"$W\",\"cwd\":\"$WCWD\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/srv/web/index.html\"}}"
assert_json "permissionrequest Write -> file_path" "$WF" '.pending.summary' "/srv/web/index.html"

# generic notification still sets pending when none exists yet
G="p3"; GCWD="/srv/x"; GF="$TMP/$G.json"
ev sessionstart "{\"session_id\":\"$G\",\"cwd\":\"$GCWD\"}"
ev notification "{\"session_id\":\"$G\",\"cwd\":\"$GCWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Allow something\"}"
assert_json "generic notification sets pending when absent" "$GF" '.pending.summary' "Allow something"

# --- Phase 3: transcript_path captured (for live activity peek) ---
T="t3"; TCWD="/srv/app"; TF="$TMP/$T.json"
ev userpromptsubmit "{\"session_id\":\"$T\",\"cwd\":\"$TCWD\",\"transcript_path\":\"/U/x/.claude/projects/app/s.jsonl\",\"prompt_text\":\"hi\"}"
assert_json "transcript_path captured" "$TF" '.transcript_path' "/U/x/.claude/projects/app/s.jsonl"

# --- summarize_tool: fallback, truncation, multi-line collapse (improve cards) ---
S="sm"; SF="$TMP/$S.json"
# an unlisted tool with no command/file_path -> falls back to the tool name
ev permissionrequest "{\"session_id\":\"$S\",\"cwd\":\"/x/p\",\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://x\"}}"
assert_json "summarize: unlisted tool -> tool name" "$SF" '.pending.summary' "WebFetch"
# a long command is capped at 200 chars
LONG="echo $(printf 'X%.0s' $(seq 1 400))"
ev permissionrequest "{\"session_id\":\"$S\",\"cwd\":\"/x/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$LONG" | jq -Rs .)}}"
assert_eq "summarize: long command capped at 200" "200" "$(jq -r '.pending.summary|length' "$SF")"
# a multi-line command collapses to a single line (no embedded newline breaks the tile)
ML="$(printf 'line1\nline2')"
ev permissionrequest "{\"session_id\":\"$S\",\"cwd\":\"/x/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$ML" | jq -Rs .)}}"
assert_eq "summarize: multi-line command collapsed to one line" "line1 line2" "$(jq -r '.pending.summary' "$SF")"

# --- R1-03: jq-absent fallback must emit valid JSON even for nasty cwd paths ---
# Run cc-status.sh with jq genuinely absent from PATH (a shimmed bin dir holding
# only the coreutils cc-status needs, no jq), from a directory whose path contains
# a double-quote and a backslash, and assert the written file is decodable JSON.
# Without jq, cc_get returns "" so SESSION_ID is empty and the KEY falls back to
# the sanitized cwd basename -- that's the only injection vector on this path.
# R2-02: include raw C0 control bytes (ESC 0x1b, VT 0x0b) in the cwd so the
# escaper's \uXXXX catch-all is exercised -- without it the file is malformed JSON
# (control chars U+0000-U+001F must be escaped) and the tile is silently dropped.
NASTY_DIR="$(printf '%s/we"ir\\d-%b%b-proj' "$TMP" '\033' '\013')"
mkdir -p "$NASTY_DIR"
SHIMBIN="$TMP/nojqbin"
mkdir -p "$SHIMBIN"
for b in bash sh date basename dirname mkdir mv rm cat printf sed awk tr cut grep ls cp env; do
  src="$(command -v "$b" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$SHIMBIN/$b"
done
NF="$TMP/$(printf '%s' "$(basename "$NASTY_DIR")" | tr -c 'A-Za-z0-9._-' '_').json"
( cd "$NASTY_DIR" && PATH="$SHIMBIN" CC_STATUS_DIR="$TMP" \
    "$SHIMBIN/bash" "$CC" sessionstart '{"cwd":"'"$NASTY_DIR"'"}' >/dev/null 2>&1 )
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$NF" >/dev/null 2>&1; then
    assert_eq "no-jq fallback with quote+backslash cwd -> valid JSON" "ok" "ok"
  else
    assert_eq "no-jq fallback with quote+backslash cwd -> valid JSON" "ok" "INVALID-JSON"
  fi
  # the decoded cwd round-trips intact through the escaper
  GOT_CWD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cwd"])' "$NF" 2>/dev/null)"
  assert_eq "no-jq fallback preserves the raw cwd" "$NASTY_DIR" "$GOT_CWD"
  # R2-27: the no-jq fallback must still emit `editor` (the auto-model guard and
  # focusProject routing depend on it; omitting it fails the guard open).
  HAS_ED="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if d.get("editor") else "no")' "$NF" 2>/dev/null)"
  assert_eq "R2-27: no-jq fallback emits editor field" "yes" "$HAS_ED"
  # R3-25: the no-jq fallback writes atomically (temp + mv) and captures cc_now ONCE,
  # so updated==since on a fresh write and no .tmp.$$ scratch file is left behind (a
  # concurrent dashboard poll must see the complete file or the old one, never a torn one).
  U="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["updated"])' "$NF" 2>/dev/null)"
  S="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["since"])' "$NF" 2>/dev/null)"
  assert_eq "R3-25: no-jq fresh write has updated==since (single cc_now)" "$U" "$S"
  LEFT="$(ls "$TMP"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "R3-25: no-jq atomic write leaves no .tmp scratch file" "0" "$LEFT"
else
  echo "ok   - no-jq fallback test skipped (no python3 to validate JSON)"
fi

# R3-15: while the gate is armed (gate=="waiting"), a concurrent sibling pretooluse/
# posttooluse on the SAME key must NOT advance `since` (the stale-approval escalation
# clock) -- only del(.status, .since) in the gate-waiting branch keeps T1 owned by the
# gate. `updated` still flows so the tile stays fresh.
GK="gw1"
GF="$TMP/$GK.json"
T1=100000
# Seed an armed-gate approval tile with since:T1.
printf '{"session_id":"%s","name":"p","cwd":"/p","status":"approval","updated":%s,"since":%s,"gate":"waiting","gate_nonce":"n1","pending":{"tool":"Bash","summary":"x"}}\n' \
  "$GK" "$T1" "$T1" > "$GF"
sleep 1
# A sibling posttooluse lands while the gate is still waiting.
ev posttooluse "{\"session_id\":\"$GK\",\"cwd\":\"/p\",\"tool_name\":\"Read\",\"tool_input\":{}}"
assert_json "R3-15: gate-waiting posttooluse preserves since (escalation clock)" "$GF" '.since' "$T1"
assert_json "R3-15: gate-waiting posttooluse preserves status=approval" "$GF" '.status' "approval"
GUP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["updated"])' "$GF" 2>/dev/null || echo "")"
if [ -n "$GUP" ]; then
  if [ "$GUP" -gt "$T1" ]; then
    assert_eq "R3-15: gate-waiting posttooluse still advances updated (tile fresh)" "fresh" "fresh"
  else
    assert_eq "R3-15: gate-waiting posttooluse still advances updated (tile fresh)" "fresh" "STALE"
  fi
fi

# --- #1: the gate-waiting guard covers the SET_PENDING writers too. While the
# gate is armed, a concurrent PermissionRequest / AskUserQuestion pretooluse must
# NOT replace the armed gate's pending block (nonce + tool + summary) with a
# nonce-less one -- the panel would show one request while Approve answers another.
AG="ag1"; AGF="$TMP/$AG.json"; AGT=100000
printf '{"session_id":"%s","name":"p","cwd":"/p","status":"approval","updated":%s,"since":%s,"gate":"waiting","gate_nonce":"g-n","pending":{"nonce":"n1","tool":"Bash","summary":"rm -rf build"}}\n' \
  "$AG" "$AGT" "$AGT" > "$AGF"
ev permissionrequest "{\"session_id\":\"$AG\",\"cwd\":\"/p\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/p/other.txt\"}}"
assert_json "#1: permissionrequest keeps the gate's pending nonce"   "$AGF" '.pending.nonce'   "n1"
assert_json "#1: permissionrequest keeps the gate's pending summary" "$AGF" '.pending.summary' "rm -rf build"
assert_json "#1: permissionrequest keeps status=approval"            "$AGF" '.status' "approval"
ev pretooluse "{\"session_id\":\"$AG\",\"cwd\":\"/p\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Pick one\",\"header\":\"Q\"}]}}"
assert_json "#1: AskUserQuestion keeps the gate's pending nonce" "$AGF" '.pending.nonce' "n1"
assert_json "#1: AskUserQuestion does not graft its ask block"   "$AGF" '.pending.ask' "null"
# ...and the armed-gate guard now covers userpromptsubmit/stop as well (#17's
# armed-gate extension): neither may strip the gate's pending mid-wait.
ev userpromptsubmit "{\"session_id\":\"$AG\",\"cwd\":\"/p\",\"prompt_text\":\"unrelated sibling prompt\"}"
assert_json "#1: userpromptsubmit keeps the gate's pending" "$AGF" '.pending.nonce' "n1"
assert_json "#1: userpromptsubmit keeps status=approval"    "$AGF" '.status' "approval"
ev stop "{\"session_id\":\"$AG\",\"cwd\":\"/p\"}"
assert_json "#1: stop keeps the gate's pending"       "$AGF" '.pending.nonce' "n1"
assert_json "#1: stop keeps status=approval"          "$AGF" '.status' "approval"
assert_json "#1: the escalation clock stays the gate's T1" "$AGF" '.since' "$AGT"

# --- #17: the native permission prompt (gate NOT armed -- the default install)
# gets the same shielding. Once permissionrequest publishes {status:approval,
# pending}, a concurrent sibling tool event (parallel subagents share the parent
# session_id) must not wipe it back to "working"; the only tool event that clears
# it is the approved tool's own PostToolUse (same tool + same recomputed summary).
NP="np1"; NPF="$TMP/$NP.json"
ev permissionrequest "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\"}}"
assert_json "#17: permissionrequest arms the native pending" "$NPF" '.status' "approval"
ev posttooluse "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/p/a.txt\"}}"
assert_json "#17: sibling posttooluse keeps status=approval" "$NPF" '.status' "approval"
assert_json "#17: sibling posttooluse keeps the pending"     "$NPF" '.pending.summary' "rm -rf build"
ev pretooluse "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
assert_json "#17: sibling pretooluse keeps status=approval"  "$NPF" '.status' "approval"
assert_json "#17: sibling pretooluse keeps the pending"      "$NPF" '.pending.summary' "rm -rf build"
# same tool but a DIFFERENT command is another subagent's call, not the resolution
ev posttooluse "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build2\"}}"
assert_json "#17: same-tool different-summary posttooluse keeps the pending" "$NPF" '.pending.summary' "rm -rf build"
# the approved tool's own PostToolUse (same tool + same summary) resolves it
ev posttooluse "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\"}}"
assert_json "#17: the approved tool's own posttooluse -> working" "$NPF" '.status' "working"
assert_json "#17: the approved tool's own posttooluse clears pending" "$NPF" '.pending' "null"
# a FRESH PermissionRequest replaces a live native pending (newest wins)...
ev permissionrequest "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make deploy\"}}"
ev permissionrequest "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/p/z.txt\"}}"
assert_json "#17: a fresh permissionrequest still replaces (tool)"    "$NPF" '.pending.tool' "Write"
assert_json "#17: a fresh permissionrequest still replaces (summary)" "$NPF" '.pending.summary' "/p/z.txt"
# ...and userpromptsubmit / stop still clear (the native-deny recovery path)
ev userpromptsubmit "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"prompt_text\":\"try another way\"}"
assert_json "#17: userpromptsubmit clears a native pending" "$NPF" '.pending' "null"
assert_json "#17: userpromptsubmit -> working"              "$NPF" '.status' "working"
ev permissionrequest "{\"session_id\":\"$NP\",\"cwd\":\"/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make x\"}}"
ev stop "{\"session_id\":\"$NP\",\"cwd\":\"/p\"}"
assert_json "#17: stop clears a native pending" "$NPF" '.pending' "null"
assert_json "#17: stop -> done"                 "$NPF" '.status' "done"

# --- #7 (writer half): sticky mode_cycle membership. Once a session is observed
# in an OPTIONAL permission mode (bypassPermissions/auto), the recorded membership
# must accumulate and survive every later event that omits mode_cycle -- the
# dashboard sizes set-mode's Shift+Tab press count from it.
MC="mc1"; MCF="$TMP/$MC.json"
ev userpromptsubmit "{\"session_id\":\"$MC\",\"cwd\":\"/p\",\"permission_mode\":\"bypassPermissions\",\"prompt_text\":\"go\"}"
assert_json "#7: bypassPermissions observed -> mode_cycle records it" "$MCF" '.mode_cycle.bypassPermissions' "true"
ev pretooluse "{\"session_id\":\"$MC\",\"cwd\":\"/p\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
assert_json "#7: cycling back to default keeps the membership" "$MCF" '.mode_cycle.bypassPermissions' "true"
assert_json "#7: current mode still tracked"                   "$MCF" '.permission_mode' "default"
ev posttooluse "{\"session_id\":\"$MC\",\"cwd\":\"/p\",\"permission_mode\":\"auto\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
assert_json "#7: auto observed -> membership accumulates (auto)"   "$MCF" '.mode_cycle.auto' "true"
assert_json "#7: auto observed -> membership accumulates (bypass)" "$MCF" '.mode_cycle.bypassPermissions' "true"
# a non-optional mode records no membership (base modes are always in the cycle)
ev pretooluse "{\"session_id\":\"$MC\",\"cwd\":\"/p\",\"permission_mode\":\"plan\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
assert_json "#7: non-optional modes add no membership" "$MCF" '.mode_cycle | length' "2"

# --- #25: the no-jq degraded fallback must map permissionrequest -> approval
# (the one state the panel exists to surface; it defaulted to "working"). Reuses
# the jq-less SHIMBIN built for the R1-03 case above.
NJ_DIR="$TMP/nojq-pr-proj"
mkdir -p "$NJ_DIR"
NJF="$TMP/nojq-pr-proj.json"
( cd "$NJ_DIR" && PATH="$SHIMBIN" CC_STATUS_DIR="$TMP" \
    "$SHIMBIN/bash" "$CC" permissionrequest </dev/null >/dev/null 2>&1 )
assert_json "#25: no-jq permissionrequest -> approval" "$NJF" '.status' "approval"
# the sibling degraded mappings are unchanged
( cd "$NJ_DIR" && PATH="$SHIMBIN" CC_STATUS_DIR="$TMP" \
    "$SHIMBIN/bash" "$CC" stop </dev/null >/dev/null 2>&1 )
assert_json "#25: no-jq stop still -> done" "$NJF" '.status' "done"
( cd "$NJ_DIR" && PATH="$SHIMBIN" CC_STATUS_DIR="$TMP" \
    "$SHIMBIN/bash" "$CC" pretooluse </dev/null >/dev/null 2>&1 )
assert_json "#25: no-jq pretooluse still -> working" "$NJF" '.status' "working"

finish
