#!/usr/bin/env bash
# ask.test.sh - cc-status.sh captures AskUserQuestion's questions/options into
# pending.ask (so the panel can render them) and flips the session to "approval".
# Writes only to a throwaway CC_STATUS_DIR.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"
CC="$ROOT/cc-status.sh"
SID="ask1"; CWD="/U/x/proj"; F="$TMP/$SID.json"

ev() { printf '%s' "$2" | bash "$CC" "$1" >/dev/null 2>&1; }

ASK='{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick a mode","header":"Mode","multiSelect":false,"options":[{"label":"Plan","description":"read only"},{"label":"Edit","description":"accept edits"}]}]}}'

ev pretooluse "$ASK"
assert_json "AskUserQuestion -> approval"        "$F" '.status' "approval"
assert_json "pending tool is AskUserQuestion"    "$F" '.pending.tool' "AskUserQuestion"
assert_json "summary is the first question"      "$F" '.pending.summary' "Pick a mode"
assert_json "ask header captured"                "$F" '.pending.ask[0].header' "Mode"
assert_json "ask option 1 label captured"        "$F" '.pending.ask[0].options[0].label' "Plan"
assert_json "ask option 2 label captured"        "$F" '.pending.ask[0].options[1].label' "Edit"
assert_json "ask single-select multiSelect=false" "$F" '.pending.ask[0].multiSelect' "false"

# A multi-select, multi-question payload: the multiSelect flag and the 2nd question
# are both captured (the panel guards multi-select: it jumps instead of driving keys).
MULTI='{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick features","header":"Feat","multiSelect":true,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]},{"question":"Which env","header":"Env","multiSelect":false,"options":[{"label":"Prod","description":"p"}]}]}}'
ev pretooluse "$MULTI"
assert_json "ask multiSelect captured"           "$F" '.pending.ask[0].multiSelect' "true"
assert_json "ask 2nd question header captured"   "$F" '.pending.ask[1].header' "Env"

# Corrected behavior (native-approval shield in cc-status.sh): while an ask/approval
# pending is LIVE, a sibling plain pretooluse (parallel subagents share the parent
# session_id) must NOT wipe it back to "working" -- no further hook fires while the
# prompt sits, so the wipe left a blocked session showing busy forever. The live
# approval owns status/pending until its own resolution event.
ev pretooluse '{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_json "sibling pretooluse keeps approval"  "$F" '.status' "approval"
assert_json "sibling pretooluse keeps the ask"   "$F" '.pending.ask[0].header' "Feat"

# The ask's own PostToolUse (same tool_name + same first question as the recorded
# pending.summary) is the legitimate resolution: the answer was given, the tile
# returns to working and the pending clears.
ev posttooluse "$MULTI"
assert_json "matching posttooluse -> working"     "$F" '.status' "working"
assert_json "matching posttooluse clears pending" "$F" '.pending' "null"

# With no live approval, a plain (non-AskUserQuestion) pretooluse stays working
# with no ask payload.
ev pretooluse '{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_json "plain pretooluse -> working"         "$F" '.status' "working"
assert_json "plain pretooluse leaves no pending"  "$F" '.pending' "null"

# F-001 (bug sweep): a new pending that has NO ask (a Write PermissionRequest) must
# fully REPLACE a prior AskUserQuestion pending, not inherit its stale .pending.ask
# via jq's recursive merge (which would leak dead option buttons onto the Write tile).
ev pretooluse "$ASK"                              # re-arm an Ask pending
assert_json "re-armed ask is present"            "$F" '.pending|has("ask")' "true"
ev permissionrequest '{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"Write","tool_input":{"file_path":"/U/x/y.txt"}}'
# Pin the POSITIVE shape of the replacement (a full replace, not a partial merge):
# the tile now carries the Write tool + summary, and NO leftover ask.
assert_json "F-001: pending tool is now the Write"        "$F" '.pending.tool' "Write"
assert_json "F-001: pending summary replaced by the Write" "$F" '.pending.summary' "/U/x/y.txt"
assert_json "F-001: stale ask dropped on pending replace"  "$F" '.pending|has("ask")' "false"

# --- stuck-approval regression (the "canary" bug): an AskUserQuestion armed via a
# PermissionRequest recorded summary = the bare tool name (summarize_tool has no Ask
# arm), and the resolve required the incoming QUESTION to equal that summary -- so the
# ask's own PostToolUse never cleared it and the answered session showed "needs you"
# forever while it worked on. Two fixes: the PermissionRequest arm now captures the
# question + options, and the posttooluse resolve clears an AskUserQuestion on a
# tool-name match (its own PostToolUse == the answer). ---
SID2="ask2"; F2="$TMP/$SID2.json"
PRQ='{"session_id":"ask2","cwd":"/U/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"Go","multiSelect":false,"options":[{"label":"Yes","description":"go"},{"label":"No","description":"stop"}]}]}}'
ev permissionrequest "$PRQ"
assert_json "PRQ ask -> approval"                       "$F2" '.status' "approval"
assert_json "PRQ ask summary is the QUESTION (not the tool name)" "$F2" '.pending.summary' "Ship it?"
assert_json "PRQ ask captures options for the panel"    "$F2" '.pending.ask[0].options[0].label' "Yes"
# a sibling Bash posttooluse must STILL keep the live approval (guard intact)
ev posttooluse '{"session_id":"ask2","cwd":"/U/x/proj","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_json "PRQ ask: sibling Bash keeps approval"      "$F2" '.status' "approval"
# the ask's OWN posttooluse clears it even though the question text differs from a
# tool-name summary (this is the exact clear that was broken)
ev posttooluse "$PRQ"
assert_json "PRQ ask: own posttooluse -> working"       "$F2" '.status' "working"
assert_json "PRQ ask: own posttooluse clears pending"   "$F2" '.pending' "null"

# And the pre-existing malformed shape (summary == the tool name, no ask -- the shape
# already on disk for the stuck tile) still clears on the ask's PostToolUse.
SID3="ask3"; F3="$TMP/$SID3.json"
printf '{"session_id":"ask3","name":"c","cwd":"/U/x/proj","status":"approval","updated":1,"since":1,"pending":{"tool":"AskUserQuestion","summary":"AskUserQuestion","message":"AskUserQuestion"}}\n' > "$F3"
ev posttooluse '{"session_id":"ask3","cwd":"/U/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Whatever?","header":"H","multiSelect":false,"options":[{"label":"X","description":"x"}]}]}}'
assert_json "legacy tool-name-summary pending clears on ask posttooluse" "$F3" '.status' "working"
assert_json "legacy tool-name-summary pending is removed"                "$F3" '.pending' "null"

finish
