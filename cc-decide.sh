#!/usr/bin/env bash
# cc-decide.sh - ask Adam a question the session can answer itself (build program unit 28, 2026-09-29).
#
#   cc-decide.sh ask --question "<Q>" --default "<D>" [--options "a|b|c"] [--blocking] [--wait <seconds>]
#   cc-decide.sh --help
#
# A question with a sensible default doesn't stop the session. It is recorded for Shepherd's Inbox
# (☰ → Inbox) and the session goes on:
#   non-blocking (the default): prints the default at once. If Adam answers differently later, his
#     answer reaches the session -- through its mailbox while it runs (at its next turn end), else
#     at its next start.
#   --blocking: run it in the BACKGROUND (Claude Code wakes the session when it exits). Waits for
#     Adam's answer and prints it; prints the default when --wait (decide.waitSeconds, default
#     1800s, at most 7200s) runs out, or at once when Shepherd isn't running. A question that timed
#     out stays open in the Inbox like a non-blocking one.
# Only the value to go with is printed on stdout (one line: pipe-friendly); what happened goes to
# stderr. Exit codes: 0 a value was printed, 2 refused (the reason is on stderr).
#
# The record is ~/.claude/cc-decide/<key>.<epoch>-<pid>.json (the session key is its sanitized
# CLAUDE_CODE_SESSION_ID), written temp-then-rename, bound to a fresh nonce. Adam's answer is
# <id>.answer, {"nonce","answer","at"}, which Shepherd writes with the nonce read from the record
# on disk; the waiter claims it with mv and takes it only when the nonce is the record's (cc-ask's
# pattern). core.parseDecision (cc-core.lua) reads the same record; KEEP THE FIELDS IN SYNC.
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

POLL="${CC_DECIDE_POLL:-1}"
PANEL_MAX_AGE="${CC_DECIDE_PANEL_MAX_AGE:-30}"
QUESTION_MAX=500
DEFAULT_MAX=200
OPTIONS_MAX=8
OPTION_MAX=100
WAIT_MAX=7200

usage() {
  cat <<'EOF'
cc-decide.sh ask --question "<Q>" --default "<D>" [--options "a|b|c"] [--blocking] [--wait <seconds>]

Ask Adam something you have a sensible default for, without stopping. The question goes to
Shepherd's Inbox and the value to go with is printed on stdout:
  (non-blocking)  the default, at once. Carry on with it; if Adam answers differently later, his
                  answer reaches you through the mailbox (at a turn end) or at your next start.
  --blocking      run it in the background: prints Adam's answer, or the default when --wait
                  (default 1800s) runs out, or at once when Shepherd isn't running.
--options is a |-separated list; the default must be one of them. Adam may also answer in his
own words. Must run inside a Claude Code session (CLAUDE_CODE_SESSION_ID).
EOF
}

refuse() { echo "❌ cc-decide: $*" >&2; exit 2; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"
case "${1:-}" in
  ask) shift ;;
  '') usage >&2; exit 2 ;;
  *) refuse "unknown command: $1 (see cc-decide.sh --help)" ;;
esac

QUESTION="" DEFAULT="" OPTIONS="" BLOCKING=0 WAIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --question|--default|--options|--wait)
      [ $# -ge 2 ] || refuse "$1 needs a value"
      case "$1" in
        --question) QUESTION="$2" ;;
        --default)  DEFAULT="$2" ;;
        --options)  OPTIONS="$2" ;;
        --wait)     WAIT="$2" ;;
      esac
      shift 2 ;;
    --blocking) BLOCKING=1; shift ;;
    *) refuse "unknown option: $1 (see cc-decide.sh --help)" ;;
  esac
done

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
QUESTION="$(trim "$QUESTION")"
DEFAULT="$(trim "$DEFAULT")"
[ -n "$QUESTION" ] || refuse "give the question: --question \"...\""
[ -n "$DEFAULT" ] || refuse "give the default you'll go with: --default \"...\""
[ "${#QUESTION}" -le "$QUESTION_MAX" ] || refuse "the question is longer than $QUESTION_MAX characters"
[ "${#DEFAULT}" -le "$DEFAULT_MAX" ] || refuse "the default is longer than $DEFAULT_MAX characters"
OPTS_JSON="$(printf '%s' "$OPTIONS" | jq -Rsc 'split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')" \
  || refuse "couldn't read --options"
[ "$(printf '%s' "$OPTS_JSON" | jq 'length')" -le "$OPTIONS_MAX" ] || refuse "at most $OPTIONS_MAX options"
[ "$(printf '%s' "$OPTS_JSON" | jq --argjson m "$OPTION_MAX" 'map(select(length > $m)) | length')" -eq 0 ] \
  || refuse "an option is longer than $OPTION_MAX characters"
if [ "$(printf '%s' "$OPTS_JSON" | jq 'length')" -gt 0 ] \
   && [ "$(printf '%s' "$OPTS_JSON" | jq --arg d "$DEFAULT" 'any(.[]; . == $d)')" != true ]; then
  refuse "the default ($DEFAULT) must be one of the options"
fi

KEY="$(cc_sanitize "$SID")"
NOW="$(cc_now)"
ID="$KEY.$NOW-$$"
REC="$CC_DECIDE_DIR/$ID.json"
ANS="$CC_DECIDE_DIR/$ID.answer"
CLAIM="$ANS.claim.$$"
NONCE="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -dc '0-9a-f')"
[ "${#NONCE}" -eq 16 ] || NONCE="$(printf '%08x%08x' "$NOW" "$(( ($$ << 15) ^ RANDOM ))" | tail -c 16)"

# Write the record whole (temp, then renamed into place).
save() { # <json>
  mkdir -p "$CC_DECIDE_DIR" 2>/dev/null && chmod 700 "$CC_DECIDE_DIR" 2>/dev/null
  local tmp="$REC.tmp.$$"
  if printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$REC"; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
ledger() { # <type> [jq object of extra fields]
  cc_ledger_enabled || return 0
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  cc_ledger_append "$(jq -nc --arg t "$1" --arg key "$KEY" --arg id "$ID" --argjson x "$extra" \
    '{type:$t, key:$key, session_id:$key, id:$id} + $x')"
}
go_with() { # <value> <why, for stderr>
  echo "$2" >&2
  printf '%s\n' "$1"
  exit 0
}

BASE="$(jq -nc --arg id "$ID" --arg key "$KEY" --arg sid "$SID" --arg cwd "$PWD" --arg q "$QUESTION" \
  --arg d "$DEFAULT" --argjson o "$OPTS_JSON" --arg n "$NONCE" --argjson at "$NOW" \
  '{v:1, id:$id, key:$key, session_id:$sid, cwd:$cwd, question:$q, default:$d, options:$o,
    blocking:false, nonce:$n, asked:$at}')"

shepherd_alive() {
  local hb
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  [ -n "$hb" ] && [ $(( $(cc_now) - hb )) -le "$PANEL_MAX_AGE" ]
}

if [ "$BLOCKING" -eq 0 ] || ! shepherd_alive; then
  save "$BASE" || echo "⚠️ cc-decide: couldn't record the question in $CC_DECIDE_DIR" >&2
  ledger decision_asked '{"blocking":false}'
  [ "$BLOCKING" -eq 0 ] && go_with "$DEFAULT" \
    "📨 cc-decide: going with the default ($DEFAULT). The question is in Shepherd's Inbox ($ID); if Adam answers differently, his answer reaches this session later."
  go_with "$DEFAULT" \
    "⚠️ cc-decide: Shepherd isn't running, so nobody can answer now -- going with the default ($DEFAULT). The question waits in its Inbox ($ID)."
fi

# ---- blocking: wait for Adam's answer, bound to the nonce ----
[ -n "$WAIT" ] || WAIT="${CC_DECIDE_WAIT:-$(cc_config '.decide.waitSeconds' '1800')}"
case "$WAIT" in ''|*[!0-9]*) WAIT=1800 ;; esac
[ "$WAIT" -ge 1 ] || WAIT=1
[ "$WAIT" -le "$WAIT_MAX" ] || WAIT="$WAIT_MAX"
save "$(printf '%s' "$BASE" | jq -c --argjson u "$(( NOW + WAIT ))" --argjson p "$$" '. + {blocking:true, until:$u, pid:$p}')" \
  || refuse "couldn't record the question in $CC_DECIDE_DIR"
ledger decision_asked '{"blocking":true}'
echo "⏳ cc-decide: waiting up to ${WAIT}s for Adam's answer in Shepherd's Inbox ($ID)" >&2

# The waiter lets go: the question stays open in the Inbox, no longer blocking (a later answer then
# reaches the session like a non-blocking one's). Only while the record is still this waiter's.
let_go() { # [timed_out]
  local tmp="$REC.tmp.$$"
  [ -f "$REC" ] || return 0
  if jq -c --argjson p "$$" --arg t "${1:-}" 'select(.pid == $p)
       | .blocking = false | del(.pid) | if $t == "timed_out" then .timed_out = true else . end' "$REC" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    mv "$tmp" "$REC"
  else
    rm -f "$tmp" 2>/dev/null
  fi
}
trap 'let_go; rm -f "$CLAIM" 2>/dev/null; exit 143' TERM INT HUP

ANSWER=""
take_answer() { # 0 with ANSWER set when Adam's answer for this nonce was taken
  [ -f "$ANS" ] || return 1
  mv "$ANS" "$CLAIM" 2>/dev/null || return 1
  local body a
  body="$(cat "$CLAIM" 2>/dev/null)"
  rm -f "$CLAIM" 2>/dev/null
  if [ "$(cc_get "$body" '.nonce')" != "$NONCE" ]; then
    echo "⚠️ cc-decide: an answer for another question was thrown away ($ID)" >&2
    return 1
  fi
  a="$(printf '%s' "$body" | jq -r '.answer | select(type == "string") | gsub("^\\s+|\\s+$"; "")' 2>/dev/null)"
  if [ -z "$a" ]; then echo "⚠️ cc-decide: an empty answer was ignored ($ID)" >&2; return 1; fi
  ANSWER="$a"
  return 0
}
answered() {
  trap - TERM INT HUP
  rm -f "$REC" 2>/dev/null
  ledger decision_answered '{"via":"waiter"}'
  go_with "$ANSWER" "✅ cc-decide: Adam answered ($ID)$([ "$ANSWER" = "$DEFAULT" ] && echo ' -- the default')"
}

# A real deadline (bash's own SECONDS), not a count of rounds.
SECONDS=0
while [ "$SECONDS" -lt "$WAIT" ]; do
  take_answer && answered
  [ -f "$REC" ] || { trap - TERM INT HUP; go_with "$DEFAULT" "⚠️ cc-decide: the question was closed in Shepherd -- going with the default ($DEFAULT)"; }
  sleep "$POLL"
done
take_answer && answered
let_go timed_out
trap - TERM INT HUP
ledger decision_timed_out '{}'
go_with "$DEFAULT" "⌛ cc-decide: no answer in ${WAIT}s -- going with the default ($DEFAULT). The question stays in Shepherd's Inbox; a later answer reaches this session."
