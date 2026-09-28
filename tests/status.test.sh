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
# prompt-flag: a permission Notification (the dialog is genuinely up) marks the pending
# so the panel's stale-approval heal never treats it as an auto-running tool.
assert_json "notification marks pending.prompt=true (a live dialog)" "$F" '.pending.prompt' "true"

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

# 2026-09-28: a turn that ends on an API error fires StopFailure, never Stop, and nothing mapped
# it, so the file stayed "working" for good -- a rate-limited session never showed its error.
# stopfailure -> error, carrying Claude Code's own error kind and message; an idle notice after
# it keeps the error; the next prompt (or a clean stop) clears it.
LIMIT_MSG="You've hit your session limit · resets 3pm (America/New_York)"
ev userpromptsubmit "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"prompt_text\":\"go on\"}"
ev stopfailure "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"$LIMIT_MSG\"}"
assert_json "a turn stopped by a rate limit -> error" "$F" '.status' "error"
assert_json "...carrying Claude Code's error kind" "$F" '.error_kind' "rate_limit"
assert_json "...and its message, reset time included" "$F" '.error_message' "$LIMIT_MSG"
ev notification "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"idle_prompt\",\"message\":\"waiting\"}"
assert_json "an idle notice after the error keeps it an error" "$F" '.status' "error"
assert_json "...and keeps its message" "$F" '.error_message' "$LIMIT_MSG"
ev userpromptsubmit "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"prompt_text\":\"continue\"}"
assert_json "the next prompt clears the error" "$F" '.status' "working"
assert_json "...drops its kind" "$F" '.error_kind // "absent"' "absent"
assert_json "...and its message" "$F" '.error_message // "absent"' "absent"
ev stopfailure "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"error\":\"server_error\",\"error_details\":\"529 Overloaded\"}"
assert_json "no message -> the error details stand in" "$F" '.error_message' "529 Overloaded"
ev stopfailure "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"error\":\"overloaded\"}"
assert_json "no message or details -> named by its kind" "$F" '.error_message' "API error: overloaded"
ev stopfailure "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"error\":\"rate limit; rm -rf\",\"last_assistant_message\":\"line one\\nline two\"}"
assert_json "an error kind that isn't one plain word is stored as unknown" "$F" '.error_kind' "unknown"
assert_json "a multi-line message is kept on one line" "$F" '.error_message' "line one line two"
ev stop "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
assert_json "a clean stop after an error -> done" "$F" '.status' "done"
assert_json "...and drops the error" "$F" '.error_kind // "absent"' "absent"

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

# Finding-3: a SECOND PermissionRequest while status is ALREADY "approval" (a stuck/back-to-
# back prompt) must ADVANCE `since` to the new arm time. Otherwise the dashboard's
# progressed-heal compares the transcript against a STALE earlier arm time and heals the
# live newer prompt to "working" (hiding it). Simulate a stuck approval by forcing since
# to an old value, then fire a new (different) PermissionRequest; since must reset to now.
BB="bb1"; BBCWD="/srv/bb"; BBF="$TMP/$BB.json"
ev permissionrequest "{\"session_id\":\"$BB\",\"cwd\":\"$BBCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"first cmd\"}}"
jq '.since=1' "$BBF" > "$BBF.t" && mv "$BBF.t" "$BBF"   # stale earlier arm time
ev permissionrequest "{\"session_id\":\"$BB\",\"cwd\":\"$BBCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"second different cmd\"}}"
assert_json "finding-3: back-to-back stays approval" "$BBF" '.status' "approval"
assert_json "finding-3: new prompt replaces the pending summary" "$BBF" '.pending.summary' "second different cmd"
assert_eq "finding-3: new PermissionRequest advances stale since (approval->approval)" \
  "true" "$([ "$(jq -r '.since' "$BBF")" -gt 1 ] && echo true || echo false)"

# --- Phase 1: PermissionRequest gives a precise pending summary ---
P="p1"; PCWD="/srv/api-server"; PF="$TMP/$P.json"
ev pretooluse "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test -- --watch\"}}"
ev permissionrequest "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test -- --watch\"}}"
assert_json "permissionrequest -> approval" "$PF" '.status' "approval"
assert_json "permissionrequest Bash -> exact command" "$PF" '.pending.summary' "npm test -- --watch"
# a PermissionRequest alone is a permission CHECK (may auto-resolve) -> no prompt flag,
# so the heal can treat an auto-running tool as working
assert_json "permissionrequest alone does NOT mark pending.prompt" "$PF" '(.pending.prompt // false)' "false"

# a later generic Notification must NOT clobber the precise pending, but DOES mark it as
# a live dialog (the genuine "Allow this bash command?" prompt is up)
ev notification "{\"session_id\":\"$P\",\"cwd\":\"$PCWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs permission\"}"
assert_json "notification keeps precise pending" "$PF" '.pending.summary' "npm test -- --watch"
assert_json "notification marks the existing pending.prompt=true" "$PF" '.pending.prompt' "true"

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
# stdin MUST be closed: cc-status.sh reads its hook payload with
# INPUT="$(cat)", unconditionally and to EOF. The JSON below is passed as $2 and
# is never read, so this call wants EMPTY input -- but without </dev/null it
# inherits the caller's stdin and blocks forever on one that never closes (a
# backgrounded `make test`/`make deploy`, which is how this suite hung for 16
# minutes at 0% CPU). Every other cc-status.sh call in the suite pipes its JSON,
# so this was the only exposed one.
( cd "$NASTY_DIR" && PATH="$SHIMBIN" CC_STATUS_DIR="$TMP" \
    "$SHIMBIN/bash" "$CC" sessionstart '{"cwd":"'"$NASTY_DIR"'"}' >/dev/null 2>&1 </dev/null )
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

# --- #7-pin: the main status merge self-heals a CORRUPT <key>.json (the cc_merge
# retry-from-{} discipline). Invalid JSON on disk (truncated write on power loss,
# hand-edit typo, partial rsync copy) used to fail the inline jq merge on EVERY
# subsequent hook event -- the tmp file was just removed and nothing was ever
# written again, so the session was invisible on the panel until SessionEnd.
HE="heal1"; HEF="$TMP/$HE.json"
printf '{ not json' > "$HEF"
ev userpromptsubmit "{\"session_id\":\"$HE\",\"cwd\":\"/srv/heal-proj\",\"prompt_text\":\"revive me\"}"
assert_eq "#7-pin: corrupt file heals into valid JSON on the next event" \
  "true" "$(jq -e . "$HEF" >/dev/null 2>&1 && echo true || echo false)"
assert_json "#7-pin: healed tile rebuilt from the event (status)" "$HEF" '.status' "working"
assert_json "#7-pin: healed tile rebuilt from the event (identity)" "$HEF" '.session_id' "$HE"
assert_json "#7-pin: healed tile rebuilt from the event (prompt)" "$HEF" '.last_prompt' "revive me"
# and the healed file merges normally from then on (not a one-shot write)
ev stop "{\"session_id\":\"$HE\",\"cwd\":\"/srv/heal-proj\"}"
assert_json "#7-pin: post-heal events merge again (stop -> done)" "$HEF" '.status' "done"
assert_json "#7-pin: post-heal merge preserves earlier fields" "$HEF" '.last_prompt' "revive me"

# session_pid (2026-09-04): the writer publishes the session's own process pid beside
# host_window, from the same one-per-session walk. It is what lets the panel reap a
# /clear ghost on sight -- host_window cannot, since one editor window hosts many
# sessions. (The walk itself is covered in lib.test.sh; this pins the publish.)
assert_eq "status writer publishes session_pid" "yes" \
  "$(grep -qF 'session_pid:$v' "$ROOT/cc-status.sh" && echo yes || echo no)"
assert_eq "session_pid comes from the cached helper" "yes" \
  "$(grep -qF 'SESSION_PID="$(cc_session_pid "$KEY")"' "$ROOT/cc-status.sh" && echo yes || echo no)"

# ---- what the session is waiting ON (2026-09-18) ----
# The hung watchdog keys off transcript growth, and a transcript does not grow until a tool
# RETURNS -- so a nine-minute Bash read as a wedged session. Both tool events carry tool_use_id,
# which is what keeps a parallel subagent (same session_id, same status file) from clearing the
# main turn's in-flight tool.
T="$TMP/tool.json"
TSID="tooler"
tf() { printf '%s' "$2" | bash "$CC" "$1" >/dev/null 2>&1; }
TF="$CC_STATUS_DIR/$TSID.json"
tf pretooluse "{\"session_id\":\"$TSID\",\"cwd\":\"$CWD\",\"tool_name\":\"Bash\",\"tool_use_id\":\"tu_1\",\"tool_input\":{\"command\":\"make test\"}}"
assert_json "pretooluse records the tool in flight" "$TF" '.tool_name' "Bash"
assert_json "...with the id that will clear it" "$TF" '.tool_use_id' "tu_1"
got="$(jq -r '.tool_started_at | if type=="number" then "number" else "no" end' "$TF" 2>/dev/null)"
assert_eq "...and when it started, as a number" "number" "$got"

# A parallel subagent finishing its own tool must NOT clear the main turn's.
tf posttooluse "{\"session_id\":\"$TSID\",\"cwd\":\"$CWD\",\"tool_name\":\"Read\",\"tool_use_id\":\"tu_other\",\"duration_ms\":12}"
assert_json "a subagent's posttooluse leaves another tool in flight alone" "$TF" '.tool_name' "Bash"
assert_json "...and keeps its id" "$TF" '.tool_use_id' "tu_1"

# The matching posttooluse clears it.
tf posttooluse "{\"session_id\":\"$TSID\",\"cwd\":\"$CWD\",\"tool_name\":\"Bash\",\"tool_use_id\":\"tu_1\",\"duration_ms\":540000}"
got="$(jq -r '.tool_started_at // "cleared"' "$TF" 2>/dev/null)"
assert_eq "the matching posttooluse clears the in-flight tool" "cleared" "$got"
assert_json "...and the session is still working" "$TF" '.status' "working"

# ---- what a new session is told at SessionStart: handoff notes (2026-09-28) ----
# A fresh or respawned session started blank. Claude Code adds a SessionStart hook's stdout to the
# session's context, so cc-status.sh prints cc_session_context there, once, at the end. ev() above
# throws stdout away; evout() keeps it. After /clear: a one-line pointer to the note the session
# before it left (the same claude process, matched by pid). After a respawn: the whole note, once.
NOTES="$CC_NOTES_DIR"
mkdir -p "$NOTES/pending"
# The pid match is for editor tabs; pin the editor so a kitty shell running the suite can't change it.
evout() { printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$CC" "$1" 2>/dev/null; }
seed() { printf '%s' "$2" > "$CC_STATUS_DIR/$1.json"; }   # a status file the hook will merge into
hash_of() { lua - "$ROOT/cc-core.lua" "$1" <<'LUA'
io.write(dofile(arg[1]).cheapHash(arg[2]))
LUA
}
PCWD="/Users/x/Programming/handoff-proj"

got="$(evout sessionstart "{\"session_id\":\"fresh0\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
assert_eq "a plain startup with no note prints nothing" "" "$got"
got="$(evout stop "{\"session_id\":\"fresh0\",\"cwd\":\"$PCWD\"}")"
assert_eq "no other event prints to stdout" "" "$got"

# /clear: the pointer
printf '<!-- cc-handoff match:pid-4242-99 -->\n# Handoff: handoff-proj\nLast turn: made progress, 2026-09-28 17:54\n' > "$NOTES/old1.handoff.md"
printf '<!-- cc-handoff match:pid-4242-99 -->\n# Handoff: handoff-proj\nLast turn: did nothing, 2026-09-27 09:00\n' > "$NOTES/older.handoff.md"
touch -t 202609270900 "$NOTES/older.handoff.md"
printf '<!-- cc-handoff match:pid-5555-99 -->\n# Handoff: another tab in the same window\nLast turn: done, 2026-09-28 18:00\n' > "$NOTES/tab2.handoff.md"
seed clear1 '{"session_id":"clear1","session_pid":"4242","host_window":"99"}'
got="$(evout sessionstart "{\"session_id\":\"clear1\",\"cwd\":\"$PCWD\",\"source\":\"clear\"}")"
assert_eq "after /clear the part is labelled" "[Shepherd: handoff]" "$(printf '%s\n' "$got" | head -1)"
body="$(printf '%s\n' "$got" | sed 1d)"
assert_eq "...and is one line" "1" "$(printf '%s\n' "$body" | grep -c .)"
case "$body" in *"$NOTES/old1.handoff.md"*) r=yes ;; *) r="no: $body" ;; esac
assert_eq "...pointing at the newest note this claude process left" "yes" "$r"
case "$body" in *"made progress"*) r=yes ;; *) r="no: $body" ;; esac
assert_eq "...saying how that turn ended" "yes" "$r"
assert_json "the status file is still written" "$CC_STATUS_DIR/clear1.json" '.status' "idle"
seed clear2 '{"session_id":"clear2","session_pid":"7777","host_window":"99"}'
got="$(evout sessionstart "{\"session_id\":\"clear2\",\"cwd\":\"$PCWD\",\"source\":\"clear\"}")"
assert_eq "a /clear in a process that left no note gets no pointer" "" "$got"
got="$(evout sessionstart "{\"session_id\":\"clear9\",\"cwd\":\"$PCWD\",\"source\":\"clear\"}")"
assert_eq "...nor one whose claude pid is unknown" "" "$got"

# respawn: the pending note, consumed once
H="$(hash_of "$PCWD")"
printf '# Handoff: handoff-proj\nLast turn: blocked, 2026-09-28 18:10\n\n## Last result\nThe push was denied.\n' > "$NOTES/pending/cwd-$H.md"
got="$(evout sessionstart "{\"session_id\":\"resumed1\",\"cwd\":\"$PCWD\",\"source\":\"resume\"}")"
assert_eq "a resumed session is told nothing" "" "$got"
assert_eq "...and leaves the pending note for the respawn" "yes" "$([ -f "$NOTES/pending/cwd-$H.md" ] && echo yes || echo no)"
got="$(evout sessionstart "{\"session_id\":\"respawn1\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
assert_eq "a respawned session starts with the note, labelled" "[Shepherd: handoff]" "$(printf '%s\n' "$got" | head -1)"
case "$got" in *"## Last result"*"The push was denied."*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "...the whole note" "yes" "$r"
assert_absent "...which is consumed" "$NOTES/pending/cwd-$H.md"
got="$(evout sessionstart "{\"session_id\":\"respawn2\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
assert_eq "...once: the next startup there is told nothing" "" "$got"
got="$(ls "$NOTES/pending" | tr '\n' ' ')"
assert_eq "...and no claim file is left behind" "" "$got"

# a kitty respawn's note is named by its lineage (cc-status.sh publishes it as budget_lineage)
LIN="/x/handoff-proj@unix:/tmp/kitty-12#3"
printf '# Handoff: kitty\n\n## Last result\nkitty lineage note\n' > "$NOTES/pending/lineage-$(hash_of "$LIN").md"
seed kitty1 "{\"session_id\":\"kitty1\",\"budget_lineage\":\"$LIN\"}"
got="$(evout sessionstart "{\"session_id\":\"kitty1\",\"cwd\":\"/elsewhere\",\"source\":\"startup\"}")"
case "$got" in *"kitty lineage note"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "a kitty respawn finds its note by lineage" "yes" "$r"

# a pending note nobody took within the hour is stale: dropped, not shown to a later session
printf '# Handoff: stale\n' > "$NOTES/pending/cwd-$H.md"
touch -t 202609010000 "$NOTES/pending/cwd-$H.md"
got="$(evout sessionstart "{\"session_id\":\"late1\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
assert_eq "a pending note older than an hour isn't shown" "" "$got"
assert_absent "...and is dropped" "$NOTES/pending/cwd-$H.md"

# Shepherd's own internal runs never take a note
printf '# Handoff: internal\n' > "$NOTES/pending/cwd-$H.md"
got="$(CC_SHEPHERD_INTERNAL=1 evout sessionstart "{\"session_id\":\"int1\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
assert_eq "an internal run is told nothing" "" "$got"
assert_eq "...and leaves the note" "yes" "$([ -f "$NOTES/pending/cwd-$H.md" ] && echo yes || echo no)"
rm -f "$NOTES/pending/cwd-$H.md"

# the cap: the context is labelled per part and never longer than CC_CONTEXT_MAX
awk 'BEGIN { for (i = 0; i < 400; i++) print "line " i " of a very long handoff note, padded out to fifty chars" }' > "$NOTES/pending/cwd-$H.md"
got="$(evout sessionstart "{\"session_id\":\"big1\",\"cwd\":\"$PCWD\",\"source\":\"startup\"}")"
n="$(printf '%s' "$got" | wc -c | tr -d ' ')"
if [ "$n" -le 8000 ] && [ "$n" -gt 7000 ]; then r=capped; else r="$n chars"; fi
assert_eq "a long note is cut at the cap (8000 characters)" "capped" "$r"
case "$got" in *"[cut: Shepherd's session context is capped at 8000 characters]") r=yes ;; *) r=no ;; esac
assert_eq "...and says so at the end" "yes" "$r"
got="$(
  . "$ROOT/cc-lib.sh"
  _cc_ctx_extra() { printf 'second part for %s\n' "$1"; }
  _cc_ctx_huge() { awk 'BEGIN { for (i = 0; i < 100; i++) print "huge part line " i }'; }
  CC_CONTEXT_PARTS="extra huge extra" CC_CONTEXT_MAX=300 cc_session_context startup nokey /nowhere
)"
assert_eq "each part is labelled with its name" "[Shepherd: extra]" "$(printf '%s\n' "$got" | head -1)"
case "$got" in *"[Shepherd: huge]"*) r=yes ;; *) r=no ;; esac
assert_eq "...the next part too" "yes" "$r"
n="$(printf '%s' "$got" | wc -c | tr -d ' ')"
if [ "$n" -le 300 ]; then r=capped; else r="$n chars"; fi
assert_eq "the cap is on the total, across parts" "capped" "$r"
assert_eq "...and a part past the cap is left out" "1" "$(printf '%s\n' "$got" | grep -c 'Shepherd: extra')"

# the shell and Lua agree on the names (Lua writes the notes, the hook reads them)
. "$ROOT/cc-lib.sh"
for p in "$PCWD" "/Users/x/Programmierung/Büro Ω" ""; do
  assert_eq "cc_hash matches core.cheapHash for [$p]" "$(hash_of "$p")" "$(cc_hash "$p")"
done
lua_match() { lua - "$ROOT/cc-core.lua" "$@" <<'LUA'
io.write(dofile(arg[1]).handoffMatch({ editor = arg[2], session_pid = arg[3], host_window = arg[4],
  kitty_listen_on = arg[5], kitty_window_id = arg[6] }) or "")
LUA
}
assert_eq "cc_handoff_match matches core.handoffMatch for an editor tab" "$(lua_match vscode 4242 99 "" "")" "$(cc_handoff_match vscode 4242 99 "" "")"
assert_eq "...and for a kitty window" "$(lua_match kitty "" "" unix:/tmp/kitty-12 3)" "$(cc_handoff_match kitty "" "" unix:/tmp/kitty-12 3)"
assert_eq "...and neither matches without a pid" "$(lua_match vscode "" 99 "" "")" "$(cc_handoff_match vscode "" 99 "" "")"

finish
