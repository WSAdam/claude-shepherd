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

# sessionend removes the file
ev sessionend "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
assert_absent "sessionend removes the tile" "$F"

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

finish
