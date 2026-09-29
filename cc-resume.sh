#!/usr/bin/env bash
#
# cc-resume.sh - resume a session stopped by a usage limit, at the limit's reset (build program
# unit 13, 2026-09-29). Called by Claude Code's StopFailure hook, matcher "rate_limit", as an
# async + asyncRewake hook (settings-hooks.json): it runs in the background, and when it exits 2
# Claude Code hands its stderr to the model as a reminder, waking the session.
#
# 1. Arm: write ~/.claude/cc-resume/<key>.json {key, nonce, pid, waiter, editor, message,
#    armedAt, state:"waiting"}. One waiter per session: a second limit while one waits leaves it
#    alone, and an arm that fired (or was cancelled, skipped, expired) is not armed again until a
#    clean Stop clears it (cc-status.sh stop) -- so a resume that hits the limit again can't loop.
#    A waiting arm whose waiter died is taken over, nonce and all.
# 2. Wait for Shepherd's plan, <key>.plan.json, bound to the arm's nonce: when the limit resets
#    (the plan meter, else the error text) and whether to wait at all (core.resumePlan). Every
#    CC_RESUME_POLL seconds it also checks the session's claude process, the arm (a clean Stop or
#    the session's end removes it) and <key>.cancel (the card's Cancel).
# 3. Fire at the reset plus jitter (at once for Resume now): record it fired, print the line to
#    stderr, exit 2. Waking an IDLE session this way is unverified, so Shepherd types the same
#    line past the reset where it may, or says so on the card (FX.stepResume).
#
# stderr is the model's input on exit 2, so this hook logs only to the debug log (cc_debug).
# Test knobs: CC_RESUME_POLL, CC_RESUME_JITTER, CC_RESUME_MAX_WAIT, CC_RESUME_SESSION_PID.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

INPUT="$(cat 2>/dev/null || true)"
# Shepherd's own headless runs are never resumed, and without jq nothing can be read or written.
[ -z "${CC_SHEPHERD_INTERNAL:-}" ] || exit 0
cc_have_jq || exit 0

LINE="[shepherd] The usage limit has reset: continue the task."
POLL="${CC_RESUME_POLL:-15}"
MAX_WAIT="${CC_RESUME_MAX_WAIT:-691200}"   # 8 days: the hook's own timeout outlasts a weekly reset

# The matcher already says rate_limit; a hook wired by hand without it must not arm on an outage.
[ "$(cc_get "$INPUT" '.error')" = "rate_limit" ] || exit 0
SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
KEY="$(cc_key "$SESSION_ID" "$CWD")"
case "$KEY" in ''|.|..|*/*) exit 0 ;; esac
MSG="$(cc_get "$INPUT" '.last_assistant_message')"
[ -n "$MSG" ] || MSG="$(cc_get "$INPUT" '.error_details')"
MSG="$(printf '%s' "$MSG" | tr '\n' ' ' | cut -c1-300)"

ARM="$CC_RESUME_DIR/$KEY.json"
PLAN="$CC_RESUME_DIR/$KEY.plan.json"
CANCEL="$CC_RESUME_DIR/$KEY.cancel"
mkdir -p "$CC_RESUME_DIR" 2>/dev/null || exit 0

# The session's claude process: the first ancestor that isn't a shell (Claude Code runs a hook
# through one). Its death ends the wait.
claude_pid() {
  local pid="$PPID" comm i=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 6 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "${comm##*/}" in
      sh|bash|zsh|dash|-sh|-bash|-zsh|env) ;;
      '') return 0 ;;
      *) printf '%s' "$pid"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
}
PID="${CC_RESUME_SESSION_PID:-$(claude_pid)}"
case "$PID" in *[!0-9]*) PID="" ;; esac

# One waiter per session, one attempt until a clean Stop.
NONCE=""
if [ -f "$ARM" ]; then
  read -r OLD_STATE OLD_WAITER OLD_NONCE <<EOF
$(jq -r '[(.state // ""), ((.waiter // 0) | tostring), (.nonce // "")] | join(" ")' "$ARM" 2>/dev/null)
EOF
  case "${OLD_STATE:-}" in
    waiting)
      if [ -n "${OLD_WAITER:-}" ] && [ "$OLD_WAITER" != "0" ] && kill -0 "$OLD_WAITER" 2>/dev/null; then
        cc_debug "resume: ⚠️ $KEY already has a waiter ($OLD_WAITER) -- leaving it"
        exit 0
      fi
      case "${OLD_NONCE:-}" in ''|*[!0-9A-Za-z]*) ;; *) NONCE="$OLD_NONCE" ;; esac
      cc_debug "resume: 🔍 $KEY's waiter is gone -- taking over (nonce $NONCE)"
      ;;
    '') ;;   # unreadable: armed afresh below
    *)
      cc_debug "resume: ⚠️ $KEY was already $OLD_STATE -- no second attempt before a clean Stop"
      exit 0
      ;;
  esac
fi
if [ -z "$NONCE" ]; then
  # a fresh arm starts clean: a plan or a cancel left from an earlier one is not for it
  rm -f "$PLAN" "$CANCEL" 2>/dev/null
  NONCE="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$NONCE" ] || NONCE="$(cc_now)$$${RANDOM}"
fi
ARMED_AT="$(cc_now)"

# Rewrite the arm atomically; set_state keeps every field and only touches our own nonce's arm.
write_arm() { # <json>
  local tmp="$ARM.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$ARM" 2>/dev/null
}
write_arm "$(jq -nc --arg key "$KEY" --arg sid "$SESSION_ID" --arg nonce "$NONCE" --arg pid "$PID" \
  --argjson waiter "$$" --arg editor "$(cc_detect_editor)" --arg msg "$MSG" --argjson at "$ARMED_AT" \
  '{key:$key, session_id:$sid, nonce:$nonce, pid:(if $pid == "" then null else ($pid|tonumber) end),
    waiter:$waiter, editor:$editor, kind:"rate_limit", message:$msg, armedAt:$at, state:"waiting"}')" || exit 0
cc_debug "resume: 🚀 armed $KEY (nonce $NONCE, pid ${PID:-?})"

set_state() { # <state> [extra fields, a JSON object]
  [ -f "$ARM" ] || return 0
  local cur extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  cur="$(jq -c --arg n "$NONCE" --arg s "$1" --argjson x "$extra" \
    'if .nonce == $n then . + {state:$s} + $x else empty end' "$ARM" 2>/dev/null)"
  [ -n "$cur" ] && write_arm "$cur"
}

JITTER="${CC_RESUME_JITTER:-$((RANDOM % 61 + 15))}"
while :; do
  sleep "$POLL"
  if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
    cc_debug "resume: ✅ $KEY's session ($PID) is gone -- stop waiting"
    exit 0
  fi
  # a clean Stop or the session's end removed the arm, or another arm replaced it
  [ "$(jq -r '.nonce // ""' "$ARM" 2>/dev/null)" = "$NONCE" ] || { cc_debug "resume: ✅ $KEY's arm was cleared"; exit 0; }
  if [ -e "$CANCEL" ]; then
    set_state cancelled
    cc_debug "resume: ✅ $KEY cancelled"
    exit 0
  fi
  NOW="$(cc_now)"
  if [ $((NOW - ARMED_AT)) -gt "${MAX_WAIT%.*}" ]; then
    set_state expired
    cc_debug "resume: ⚠️ $KEY waited its longest -- giving up"
    exit 0
  fi
  [ -f "$PLAN" ] || continue
  read -r P_VERDICT P_RESET P_NOW <<EOF
$(jq -r --arg n "$NONCE" 'if .nonce == $n then [(.verdict // ""), ((.resetAt // 0) | floor | tostring), ((.now == true) | tostring)] | join(" ") else "" end' "$PLAN" 2>/dev/null)
EOF
  case "${P_VERDICT:-}" in
    skip) set_state skipped; cc_debug "resume: ✅ Shepherd skipped $KEY"; exit 0 ;;
    cancelled) set_state cancelled; cc_debug "resume: ✅ Shepherd cancelled $KEY"; exit 0 ;;
    wait) ;;
    *) continue ;;
  esac
  case "${P_RESET:-}" in ''|*[!0-9]*) continue ;; esac
  DUE="$P_RESET"
  [ "${P_NOW:-}" = "true" ] || DUE=$((P_RESET + JITTER))
  [ "$NOW" -ge "$DUE" ] || continue
  set_state fired "{\"firedAt\":$NOW}"
  cc_debug "resume: ✅ $KEY's limit has reset -- waking it"
  printf '%s\n' "$LINE" >&2
  exit 2
done
