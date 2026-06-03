#!/usr/bin/env bash
#
# cc-approve.sh - opt-in PreToolUse approval gate for babysitter.
#
# When armed, this routes a tool's permission decision to the dashboard so you
# can Approve/Deny it from the panel with no window switch. It is designed to be
# SAFE TO WIRE UNCONDITIONALLY: if the gate is disabled, the tool isn't in the
# gated set, or the panel isn't running, it returns immediately and the session
# falls back to Claude Code's normal permission flow. Sessions never freeze
# waiting on a panel that isn't there.
#
# Flow when it engages:
#   1. mark the session approval / gate:"waiting" with the pending tool
#   2. poll for ~/.claude/cc-status/<key>.decision written by the panel
#   3. emit a PreToolUse permissionDecision (allow|deny) and clear gate state
#   4. on timeout: emit nothing -> the native permission prompt appears
#
# Arming:   create the flag file  ~/.claude/cc-gate.enabled
# Scope:    CC_GATE_TOOLS (space separated) - default mutating tools only
# Timeout:  CC_GATE_TIMEOUT seconds (default 120; stays under the hook's 600s)
#
# Only the decision JSON is ever written to stdout; logs go to stderr.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

GATE_FLAG="${CC_GATE_FLAG:-${HOME}/.claude/cc-gate.enabled}"
GATE_TOOLS="${CC_GATE_TOOLS:-Bash Write Edit MultiEdit NotebookEdit}"
GATE_TIMEOUT="${CC_GATE_TIMEOUT:-120}"
HEARTBEAT_MAX_AGE="${CC_PANEL_MAX_AGE:-5}"

INPUT="$(cat 2>/dev/null || true)"

# Disabled -> normal flow.
[ -f "$GATE_FLAG" ] || exit 0
cc_have_jq || exit 0

TOOL="$(cc_get "$INPUT" '.tool_name')"

# Not a gated tool -> normal flow (reads etc. stay fast).
case " $GATE_TOOLS " in
  *" $TOOL "*) ;;
  *) exit 0 ;;
esac

# Panel must be alive (fresh heartbeat) or we'd block on nothing -> normal flow.
HB_FILE="$(cc_heartbeat_file)"
[ -f "$HB_FILE" ] || exit 0
HB="$(cat "$HB_FILE" 2>/dev/null || echo 0)"
case "$HB" in *[!0-9]*) HB=0 ;; esac
AGE=$(( $(cc_now) - HB ))
[ "$AGE" -le "$HEARTBEAT_MAX_AGE" ] || exit 0

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
NAME="$(basename "$CWD")"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

# A short human summary of what's being approved (Bash command, file path, ...).
SUMMARY="$(cc_get "$INPUT" '.tool_input.command')"
[ -n "$SUMMARY" ] || SUMMARY="$(cc_get "$INPUT" '.tool_input.file_path')"
[ -n "$SUMMARY" ] || SUMMARY="$TOOL"

DECISION_FILE="$(cc_decision_file "$KEY")"
rm -f "$DECISION_FILE" 2>/dev/null || true   # ignore any stale answer

NOW="$(cc_now)"
cc_merge "$KEY" "$(jq -nc \
  --arg sid "$SESSION_ID" --arg name "$NAME" --arg cwd "$CWD" \
  --argjson now "$NOW" --arg tool "$TOOL" --arg sum "$SUMMARY" \
  '{session_id:$sid, name:$name, cwd:$cwd, status:"approval", updated:$now, since:$now, gate:"waiting", pending:{tool:$tool, summary:$sum, message:$sum}}')"
echo "[cc-approve] ⏳ waiting on panel for $TOOL ($KEY): $SUMMARY" >&2

# Poll for the panel's decision. 0.25s cadence keeps it responsive.
ITERS=$(( GATE_TIMEOUT * 4 ))
DECISION=""
i=0
while [ "$i" -lt "$ITERS" ]; do
  if [ -f "$DECISION_FILE" ]; then
    DECISION="$(cat "$DECISION_FILE" 2>/dev/null | tr -d '[:space:]')"
    break
  fi
  sleep 0.25
  i=$(( i + 1 ))
done

cc_del_field "$KEY" "gate"
rm -f "$DECISION_FILE" 2>/dev/null || true

if [ "$DECISION" = "deny" ]; then
  cc_del_field "$KEY" "pending"
  cc_merge "$KEY" "$(jq -nc --argjson now "$(cc_now)" '{status:"working", updated:$now, since:$now}')"
  echo "[cc-approve] ❌ denied $TOOL ($KEY)" >&2
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied from the babysitter panel."}}'
  exit 0
elif [ "$DECISION" = "allow" ]; then
  cc_del_field "$KEY" "pending"
  cc_merge "$KEY" "$(jq -nc --argjson now "$(cc_now)" '{status:"working", updated:$now, since:$now}')"
  echo "[cc-approve] ✅ allowed $TOOL ($KEY)" >&2
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# Timed out with no answer: leave it to Claude Code's native prompt.
echo "[cc-approve] ⚠️  timeout after ${GATE_TIMEOUT}s, falling back to native prompt ($KEY)" >&2
exit 0
