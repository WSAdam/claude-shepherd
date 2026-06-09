#!/usr/bin/env bash
#
# cc-approve.sh - opt-in PreToolUse approval gate for Claude Shepherd, with policies.
#
# When armed (~/.claude/cc-gate.enabled), a permission request for a gated tool is
# first run through automatic policies (all OFF by default, configured in
# ~/.claude/cc-config.json); if none decides, it's routed to the panel for a human
# Approve/Deny. SAFE TO WIRE UNCONDITIONALLY: disabled gate, non-gated tool, or no
# decision + dead panel all fall straight back to Claude Code's native flow.
#
# Policy order (auto-decisions fire even if the panel isn't running):
#   1. policies.patterns.autoDeny   -> deny   (safety first)
#   2. policies.autopilot           -> allow  (this session, time-boxed)
#   3. policies.patterns.autoAllow  -> allow
#   4. policies.approveRepeats      -> allow  (same request approved before)
#   else -> panel; on a human "allow", remember it for approveRepeats.
#
# Only the decision JSON is ever written to stdout; logs go to stderr.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

GATE_FLAG="${CC_GATE_FLAG:-${HOME}/.claude/cc-gate.enabled}"
# Gated tools: env override (tests) wins, else the panel-editable `gate.tools`
# config string, else the default 5. Commas tolerated (normalized to spaces).
GATE_TOOLS="${CC_GATE_TOOLS:-$(cc_config '.gate.tools' 'Bash Write Edit MultiEdit NotebookEdit')}"
GATE_TOOLS="$(printf '%s' "$GATE_TOOLS" | tr ',' ' ')"
GATE_TIMEOUT="${CC_GATE_TIMEOUT:-120}"
HEARTBEAT_MAX_AGE="${CC_PANEL_MAX_AGE:-5}"
APPROVED_DIR="${CC_APPROVED_DIR:-${HOME}/.claude/cc-approved}"
AUTOPILOT_DIR="${CC_AUTOPILOT_DIR:-${HOME}/.claude/cc-autopilot}"

emit_allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
}
emit_deny() { # $1 = reason. Built via jq so a reason with quotes/backslashes can't
  # produce invalid JSON (jq is guaranteed here: the script exits early without it).
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# Match a request against a policy pattern. "Tool" matches by tool name;
# "Tool(glob)" also requires the command/summary to match the shell glob.
pattern_match() { # $1 tool, $2 summary, $3 pattern  -> 0 if match
  local tool="$1" cmd="$2" pat="$3" ptool inner
  case "$pat" in
    *"("*")")
      ptool="${pat%%(*}"
      inner="${pat#*(}"; inner="${inner%)}"
      [ "$tool" = "$ptool" ] || return 1
      case "$cmd" in $inner) return 0 ;; *) return 1 ;; esac
      ;;
    *)
      [ "$tool" = "$pat" ] && return 0 || return 1
      ;;
  esac
}

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

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
NAME="$(basename "$CWD")"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

# A short summary of what's being approved (Bash command, file path, ...).
SUMMARY="$(cc_get "$INPUT" '.tool_input.command')"
[ -n "$SUMMARY" ] || SUMMARY="$(cc_get "$INPUT" '.tool_input.file_path')"
[ -n "$SUMMARY" ] || SUMMARY="$TOOL"
SIG="$(printf '%s|%s' "$TOOL" "$SUMMARY" | tr '\n' ' ')"

# transcript_path -> stable projectKey (mirrors cc-core), for ledger lines.
TRANSCRIPT="$(cc_get "$INPUT" '.transcript_path')"
PROJECT_KEY=""
case "$TRANSCRIPT" in
  */projects/*/*.jsonl) PROJECT_KEY="${TRANSCRIPT##*/projects/}"; PROJECT_KEY="${PROJECT_KEY%%/*}" ;;
esac

# Append a `decision` event to the audit ledger. The gate branch IS the provenance.
# $1=outcome (allow|deny|fallback)  $2=by  $3=pattern (optional)
ledger_decision() {
  cc_ledger_enabled || return 0
  cc_ledger_append "$(jq -nc \
    --arg sid "$SESSION_ID" --arg key "$KEY" --arg name "$NAME" \
    --arg pk "$PROJECT_KEY" --arg cwd "$CWD" --arg tool "$TOOL" --arg sum "$SUMMARY" \
    --arg out "$1" --arg by "$2" --arg pat "${3:-}" \
    '{type:"decision", session_id:$sid, key:$key, name:$name, projectKey:$pk, cwd:$cwd,
      tool:$tool, summary:$sum, outcome:$out, by:$by}
     + (if $pat == "" then {} else {pattern:$pat} end)')"
}

# ---- Policy evaluation (Phase 4c) -----------------------------------------
PAT_ENABLED="$(cc_config '.policies.patterns.enabled' 'false')"

# Run the request against a config pattern list; on the FIRST match, log + record
# the ledger decision + emit it + exit. Shared by autoDeny and autoAllow (the two
# loops were byte-identical apart from the verb). $1 = jq path to the list,
# $2 = outcome (deny|allow), $3 = "by" label. No-op when patterns are disabled.
match_patterns() {
  [ "$PAT_ENABLED" = "true" ] || return 0
  local pats pat; pats="$(cc_config_array "$1")"
  [ -n "$pats" ] || return 0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if pattern_match "$TOOL" "$SUMMARY" "$pat"; then
      if [ "$2" = "deny" ]; then
        echo "[cc-approve] ⛔ policy auto-deny ($pat): $TOOL ($KEY)" >&2
        ledger_decision deny "$3" "$pat"
        emit_deny "Auto-denied by Claude Shepherd policy."
      else
        echo "[cc-approve] ✅ policy auto-allow ($pat): $TOOL ($KEY)" >&2
        ledger_decision allow "$3" "$pat"
        emit_allow
      fi
      exit 0
    fi
  done <<< "$pats"
}

# 1. autoDeny (safety first)
match_patterns '.policies.patterns.autoDeny' deny autoDeny

# 2. autopilot: this session is trusted for a time-boxed window
if [ "$(cc_config '.policies.autopilot.enabled' 'false')" = "true" ] && [ -f "$AUTOPILOT_DIR/$KEY" ]; then
  EXP="$(cat "$AUTOPILOT_DIR/$KEY" 2>/dev/null || echo 0)"
  case "$EXP" in *[!0-9]*) EXP=0 ;; esac
  if [ "$(cc_now)" -lt "$EXP" ]; then
    echo "[cc-approve] 🛫 autopilot auto-allow: $TOOL ($KEY)" >&2
    ledger_decision allow autopilot
    emit_allow
    exit 0
  fi
fi

# 3. autoAllow patterns
# SECURITY: an autoAllow glob is a PREFIX/shell-glob match on the command, so
# `Bash(ls*)` also auto-allows `ls; rm -rf /` or `ls && curl … | sh`. Keep
# autoAllow patterns tight (prefer exact tools like `Read`, or anchored commands)
# — autoDeny runs first and always wins, so deny dangerous shapes there.
match_patterns '.policies.patterns.autoAllow' allow autoAllow

# 4. approveRepeats: identical request already approved this session
if [ "$(cc_config '.policies.approveRepeats' 'false')" = "true" ]; then
  if [ -f "$APPROVED_DIR/$KEY" ] && grep -Fxq "$SIG" "$APPROVED_DIR/$KEY" 2>/dev/null; then
    echo "[cc-approve] 🔁 auto-allow (approved before): $TOOL ($KEY)" >&2
    ledger_decision allow approveRepeats
    emit_allow
    exit 0
  fi
fi

# ---- No policy decided: route to the panel --------------------------------
# Panel must be alive (fresh heartbeat) or we'd block on nothing -> normal flow.
HB_FILE="$(cc_heartbeat_file)"
[ -f "$HB_FILE" ] || exit 0
HB="$(cat "$HB_FILE" 2>/dev/null || echo 0)"
case "$HB" in *[!0-9]*) HB=0 ;; esac
AGE=$(( $(cc_now) - HB ))
[ "$AGE" -le "$HEARTBEAT_MAX_AGE" ] || exit 0

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
  ledger_decision deny human
  emit_deny "Denied from the Claude Shepherd panel."
  exit 0
elif [ "$DECISION" = "allow" ]; then
  cc_del_field "$KEY" "pending"
  cc_merge "$KEY" "$(jq -nc --argjson now "$(cc_now)" '{status:"working", updated:$now, since:$now}')"
  # Remember this approval so approveRepeats can auto-allow it next time.
  if [ "$(cc_config '.policies.approveRepeats' 'false')" = "true" ]; then
    mkdir -p "$APPROVED_DIR"
    grep -Fxq "$SIG" "$APPROVED_DIR/$KEY" 2>/dev/null || printf '%s\n' "$SIG" >> "$APPROVED_DIR/$KEY"
  fi
  echo "[cc-approve] ✅ allowed $TOOL ($KEY)" >&2
  ledger_decision allow human
  emit_allow
  exit 0
fi

# Timed out with no answer: leave it to Claude Code's native prompt.
echo "[cc-approve] ⚠️  timeout after ${GATE_TIMEOUT}s, falling back to native prompt ($KEY)" >&2
ledger_decision fallback timeout-fallback
exit 0
