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

# A plain (non-AskUserQuestion) pretooluse stays working with no ask payload.
ev pretooluse '{"session_id":"ask1","cwd":"/U/x/proj","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_json "plain pretooluse -> working"        "$F" '.status' "working"
assert_json "plain pretooluse clears ask"        "$F" '.pending' "null"

finish
