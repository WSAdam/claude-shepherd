#!/usr/bin/env bash
# cc-send.sh - hand a live Claude session a prompt from any shell, and with --wait print its reply
# (build program unit 30, 2026-09-29).
#
#   cc-send.sh <session|project> "prompt" [--wait] [--timeout <seconds>]
#
# <session> is a session's key (its session id) or its name: the one Claude Code gives it (the name
# SendMessage reaches it by) or its card's name in Shepherd. <project> is a repo's root, a worktree's
# root, a folder inside one, or a project's name: Shepherd picks its best live session -- an idle one
# before a busy one, never one waiting on you, and never the session running this command. A name
# that fits two sessions or two projects is refused with the choices listed; so is a target with no
# live session. A prompt that starts with "-" goes after `--`.
#
# Shepherd hands it over through the session mailbox (FX.deliverTo): marked [shepherd], never a
# slash command, ledgered. A busy session gets it when its current turn ends and carries on with it;
# an idle one in a kitty window or a VS Code window of its own gets it typed once it's ready; an idle
# one in a VS Code window shared with other Claude tabs keeps it in its mailbox until its next turn
# end or start. Which of those it is goes to stderr.
#
# --wait follows the session's transcript from the moment the prompt was sent until the turn that
# takes it ends, then prints the assistant's final text on stdout. Everything else -- progress and
# errors -- goes to stderr, so reply="$(cc-send.sh my-repo "..." --wait)" holds just the reply.
#
# 2026-10-14 (crossings, D-27): a send from a Claude session to a session of ANOTHER project waits for
# Adam -- held on the sending session's card, where he may edit it, then approves or denies it. Who
# sent it is read from this process's ancestry, not its environment. Without --wait it exits 0 once
# held; with --wait it waits for his decision, then for the reply he passes on (that waits for him
# too) -- Shepherd follows the other session's transcript itself. Same-project sends, and sends from
# Adam's own shell, are delivered at once as above.
#
# Exit codes: 0 sent, or held for Adam (with --wait: answered); 2 refused (the arguments, an empty
# prompt, a slash command, over 3500 bytes, no such folder); 3 no session to send it to (none,
# ambiguous, waiting on you, ended, or yourself); 4 --wait ran out (--timeout, default 1800s); 5 no
# reply to print (the turn was interrupted or died on an API error, or its transcript can't be
# followed); 6 Shepherd isn't running or didn't take the request; 7 Adam kept it -- or the reply --
# back (his note on stderr).
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

POLL="${CC_SEND_POLL:-1}"
ANSWER_WAIT="${CC_SEND_ANSWER_WAIT:-30}"
PANEL_MAX_AGE="${CC_MERGE_PANEL_MAX_AGE:-30}"
TEXT_MAX=3500     # core.SEND.textMax
TARGET_MAX=300    # core.SEND.targetMax
USAGE='usage: cc-send.sh <session|project> "prompt" [--wait] [--timeout <seconds>]'

say() { printf '%s\n' "$*" >&2; }
refuse() { say "❌ cc-send: $*"; exit 2; }
usage_error() { say "❌ cc-send: $*"; say "$USAGE"; exit 2; }
bytes() { local LC_ALL=C; printf '%s' "${#1}"; }

TARGET="" TEXT="" NPOS=0 WAIT=0 TIMEOUT=1800
positional() {
  NPOS=$((NPOS + 1))
  case "$NPOS" in
    1) TARGET="$1" ;;
    2) TEXT="$1" ;;
    *) usage_error "too many arguments -- quote the prompt" ;;
  esac
}
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --timeout) [ $# -ge 2 ] || usage_error "--timeout takes whole seconds"; TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
    -h|--help)
      printf '%s\n' "$USAGE"
      printf '%s\n' "  Hands a live session (a key or name) or a project's best live session (a repo root or name) the" \
        "  prompt through Shepherd's session mailbox. --wait prints its reply on stdout; progress goes to stderr." \
        "  A send to ANOTHER project's session waits for Adam's approval (and so does its reply); don't route around it." \
        "  Exit: 0 sent (or held for Adam), 2 refused, 3 no session to send to, 4 --wait ran out, 5 no reply," \
        "  6 Shepherd isn't running, 7 Adam kept it (or the reply) back."
      exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do positional "$1"; shift; done ;;
    -?*) usage_error "unknown option: $1" ;;
    *) positional "$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage_error "give a session (its key or name) or a project (its repo root or name)"
[ "$NPOS" -ge 2 ] || usage_error "give the prompt to send"
case "$TIMEOUT" in ''|*[!0-9]*) usage_error "--timeout takes whole seconds" ;; esac
[ "$TIMEOUT" -gt 0 ] || usage_error "--timeout takes whole seconds (at least 1)"
command -v jq >/dev/null 2>&1 || refuse "jq is required"
[[ "$TARGET" =~ [[:cntrl:]] ]] && refuse "the target holds a control character"
[ "$(bytes "$TARGET")" -le "$TARGET_MAX" ] || refuse "the target is longer than $TARGET_MAX characters"
[ -n "${TEXT//[[:space:]]/}" ] || refuse "the prompt is empty"
_cc_mailbox_slash "$TEXT" && refuse "slash commands are never sent -- a session's own tab runs those"
[ "$(bytes "$TEXT")" -le "$TEXT_MAX" ] || refuse "the prompt is $(bytes "$TEXT") bytes; at most $TEXT_MAX go through the mailbox"

# A folder target goes as its repo's (or worktree's) root, the path git and Shepherd name it by.
PATH_ARG=""
case "$TARGET" in
  */*|.|..|"~"|"~/"*)
    p="$TARGET"
    case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#"~/"}" ;; esac
    [ -d "$p" ] || refuse "no such folder: $p"
    PATH_ARG="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || PATH_ARG=""
    [ -n "$PATH_ARG" ] || PATH_ARG="$(cd -- "$p" 2>/dev/null && pwd -P)" || refuse "can't enter $p"
    ;;
esac

# Who is asking: a Claude session (never handed its own prompt) or a plain shell.
SID="${CLAUDE_CODE_SESSION_ID:-}"
OWNER="shell"
if [ -n "$SID" ]; then
  OWNER="$(cc_key "$SID" "")"
  case "$OWNER" in ''|.|..) OWNER="shell" ;; esac
fi
CPID="$(printf '%s' "${CLAUDE_PID:-}" | tr -dc '0-9')"

shepherd_alive() {
  local hb now
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  [ -n "$hb" ] && [ $((now - hb)) -le "$PANEL_MAX_AGE" ]
}
shepherd_alive || { say "⚠️ Shepherd isn't running, so nothing can hand the prompt over (~/.claude/cc-fleet.sh alive says more)."; exit 6; }

mkdir -p "$CC_SEND_DIR" && chmod 700 "$CC_SEND_DIR" 2>/dev/null
NOW="$(date +%s)"
ID="$NOW-$$$RANDOM"
NONCE="$$.$NOW.$RANDOM$RANDOM"
REQ="$CC_SEND_DIR/$OWNER.$ID.json"
ANS="$CC_SEND_DIR/$OWNER.$ID.answer"
CHUNK=""
trap 'rm -f "$REQ" "$REQ.tmp.$$" "$ANS" "$ANS.claim.$$" ${CHUNK:+"$CHUNK"}' EXIT
trap 'exit 130' INT TERM
# cli_pid (2026-10-14): this process -- Shepherd reads who really sent it from its ancestry, never from
# the session id in the environment (a send to ANOTHER project's session waits for Adam: D-27)
jq -n --arg id "$ID" --arg nonce "$NONCE" --arg target "$TARGET" --arg path "$PATH_ARG" --arg text "$TEXT" \
   --argjson wait "$([ "$WAIT" = 1 ] && echo true || echo false)" --arg key "${SID:+$OWNER}" --arg pid "$CPID" \
   --arg cwd "$PWD" --argjson at "$NOW" --arg cli "$$" '
  { v: 1, id: $id, nonce: $nonce, target: $target, text: $text, wait: $wait, at: $at, cli_pid: $cli,
    from: ({ cwd: $cwd } + (if $key != "" then { key: $key } else {} end) + (if $pid != "" then { pid: $pid } else {} end)) }
  + (if $path != "" then { path: $path } else {} end)' > "$REQ.tmp.$$" && mv "$REQ.tmp.$$" "$REQ" \
  || refuse "couldn't write the request in $CC_SEND_DIR"
say "⏳ Asked Shepherd to send it to '$TARGET'..."

# Shepherd's answer, bound to this request's nonce. 1 when none came within <seconds>.
take_answer() { # <seconds>
  local start claim
  start="$(date +%s)"
  while :; do
    if [ -f "$ANS" ]; then
      claim="$ANS.claim.$$"
      if mv "$ANS" "$claim" 2>/dev/null; then
        if [ "$(jq -r '.nonce // empty' "$claim" 2>/dev/null)" = "$NONCE" ]; then cat "$claim"; rm -f "$claim"; return 0; fi
        rm -f "$claim"   # not this request's: nothing else writes this name
      fi
    fi
    [ $(( $(date +%s) - start )) -lt "$1" ] || return 1
    sleep "$POLL"
  done
}
if ! ANSWER="$(take_answer "$ANSWER_WAIT")"; then
  # Withdraw it. If that fails, Shepherd has already claimed it (renamed it) and is sending it.
  if rm "$REQ" 2>/dev/null; then
    say "❌ cc-send: Shepherd didn't take the request within ${ANSWER_WAIT}s -- nothing was delivered."
    exit 6
  fi
  ANSWER="$(take_answer "$ANSWER_WAIT")" || {
    say "⚠️ cc-send: Shepherd took the request but hasn't said where it went -- it may have been delivered."
    exit 6
  }
fi
field() { printf '%s' "$ANSWER" | jq -r "$1 // empty" 2>/dev/null; }

if [ "$(field '.ok')" != "true" ]; then
  code="$(field '.code')"
  reason="$(field '.reason')"
  [ -n "$reason" ] || reason="Shepherd gave no reason"
  say "❌ cc-send: $reason"
  printf '%s' "$ANSWER" | jq -r '(.choices // [])[] | "   - \(.)"' >&2
  case "$code" in
    refused) exit 2 ;;
    expired) exit 6 ;;
    *) exit 3 ;;
  esac
fi
# ---- held: the target is in ANOTHER project, so Adam approves it first (2026-10-14, D-27) ----
# Shepherd held it on this session's card instead of delivering it. Without --wait that is all: it goes
# out once he approves it. With --wait: his decision (<cid>.answer), then the reply he passes on
# (<cid>.reply.answer), each bound to this request's nonce. Shepherd follows the other side's
# transcript itself -- this CLI is never told where it is.
if [ "$(field '.held')" = "true" ]; then
  CID="$(field '.cid')"
  case "$CID" in ''|*/*|.*) say "❌ cc-send: Shepherd held it but gave no crossing id"; exit 6 ;; esac
  say "⏸ Held for Adam: '$TARGET' is in another project$( [ -n "$(field '.project')" ] && printf ' (%s)' "$(field '.project')"), so nothing reaches it until he approves it on this session's card in Shepherd -- he may edit it first."
  say "   Don't resend it or route around Shepherd. If he denies it, his note reaches you through your mailbox."
  [ "$WAIT" = 1 ] || exit 0
  # cross_answer <suffix>: Shepherd's answer for this crossing, if it's there and this request's
  cross_answer() {
    local f="$CC_CROSS_DIR/$CID.$1" claim
    [ -f "$f" ] || return 1
    claim="$f.claim.$$"
    mv "$f" "$claim" 2>/dev/null || return 1
    if [ "$(jq -r '.nonce // empty' "$claim" 2>/dev/null)" = "$NONCE" ]; then cat "$claim"; rm -f "$claim"; return 0; fi
    mv "$claim" "$f" 2>/dev/null   # not this request's: leave it where it was
    return 1
  }
  say "⏳ Waiting for Adam, then for the reply he passes on (up to ${TIMEOUT}s)..."
  START="$(date +%s)" PHASE=decision
  while :; do
    if [ "$PHASE" = decision ] && A="$(cross_answer answer)"; then
      if [ "$(printf '%s' "$A" | jq -r '.ok')" != true ]; then
        say "❌ cc-send: $(printf '%s' "$A" | jq -r '.reason // "Adam didn'"'"'t pass it on"')"
        [ "$(printf '%s' "$A" | jq -r '.code // empty')" = denied ] && exit 7
        exit 3
      fi
      say "📬 Adam passed it on: sent to $(printf '%s' "$A" | jq -r '.name // "the session"'). Waiting for its reply -- Adam approves that too."
      PHASE=reply
    elif [ "$PHASE" = reply ] && A="$(cross_answer reply.answer)"; then
      case "$(printf '%s' "$A" | jq -r '.verdict // empty')" in
        approved) say "✅ Adam passed the reply on."; printf '%s\n' "$(printf '%s' "$A" | jq -r '.text // ""')"; exit 0 ;;
        denied) say "❌ cc-send: Adam kept the reply back$(w="$(printf '%s' "$A" | jq -r '.why // empty')"; [ -n "$w" ] && printf ': %s' "$w")"; exit 7 ;;
        *) say "❌ cc-send: no reply: $(printf '%s' "$A" | jq -r '.why // "none came"')"; exit 5 ;;
      esac
    fi
    if [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
      if [ "$PHASE" = decision ]; then say "⏳ cc-send: Adam hasn't decided within ${TIMEOUT}s -- it still waits on this session's card; the reply reaches you through your mailbox once he passes it."
      else say "⏳ cc-send: no reply passed on within ${TIMEOUT}s -- it reaches you through your mailbox once Adam passes it."; fi
      exit 4
    fi
    sleep "$POLL"
  done
fi
NAME="$(field '.name')"; KEY="$(field '.key')"; PROJECT="$(field '.project')"; ROUTE="$(field '.route')"
TRANSCRIPT="$(field '.transcript')"; OFFSET="$(field '.offset')"; MARKER="$(field '.marker')"; MAILBOX="$(field '.mailbox')"
NAME="${NAME:-$KEY}"
case "$ROUTE" in
  type)    how="it's idle, so Shepherd types it into its window once it's ready" ;;
  waiting) how="it's idle in a VS Code window shared with other Claude tabs, where nothing may be typed, so the prompt waits in its mailbox until the session's next turn end or start" ;;
  *)       how="it's busy, so it gets the prompt when its current turn ends and carries on with it" ;;
esac
say "📬 Sent to $NAME ($KEY)${PROJECT:+ in $PROJECT}: $how."
[ "$WAIT" = 1 ] || exit 0

# ---- --wait: follow the transcript from the send to the end of the turn that takes the prompt ----
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] || [ -z "$MARKER" ]; then
  say "❌ cc-send: can't wait for the reply -- Shepherd doesn't know $NAME's transcript (the prompt was still sent)."
  exit 5
fi
case "$OFFSET" in ''|*[!0-9]*) OFFSET=0 ;; esac
say "⏳ Waiting for $NAME's reply (up to ${TIMEOUT}s)..."

# One pass over new whole records, carrying the state across polls. The prompt arrives as the
# record carrying its marker: a prompt (typed), a Stop that handed it over (blocking the stop: the
# reason is in stop_hook_summary's hookErrors), or a SessionStart that showed it. A queued copy
# (queue-operation, queued_command) or the Stop hook's own output isn't it. From there the turn ends
# at the next stop_hook_summary; an interrupt or an API error ends it with no reply. The reply is the
# text of the last assistant message that had any (its text blocks joined).
STEP='
def text_of:
  if type == "string" then .
  elif type == "array" then [ .[] | select(type == "object" and .type == "text" and (.text | type) == "string") | .text ] | join("\n")
  else "" end;
def body: (.message? // {}) | (.content? // "") | text_of;
def summary: .type == "system" and .subtype == "stop_hook_summary";
def hands_over($m): summary and ([ (.hookErrors // [])[] | tostring | contains($m) ] | any);
reduce (inputs | fromjson? | objects) as $r ($s;
  if .done != null or $r.isSidechain == true then .
  elif (.delivered | not) then
    if ($r.type == "user" and ($r | body | contains($m))) then .delivered = true
    elif ($r | hands_over($m)) then .delivered = true
    elif ($r.type == "attachment" and (($r.attachment.hookEvent? // "") == "SessionStart")
          and ($r.attachment | tostring | contains($m))) then .delivered = true
    else . end
  elif ($r | hands_over($m)) then .reply = null | .replyId = null
  elif $r.type == "assistant" then
    if $r.isApiErrorMessage == true then .done = "error" | .error = ($r | body)
    else ($r | body) as $t
      | if ($t | test("\\S")) then
          (if .replyId != null and .replyId == ($r.message.id? // null) then .reply = .reply + "\n\n" + $t
           else .reply = $t | .replyId = ($r.message.id? // null) end)
        else . end
    end
  elif $r.type == "user" and ($r | body | startswith("[Request interrupted by user")) then .done = "interrupted"
  elif ($r | summary) then .done = "ended"
  else . end)'
STATE='{"delivered":false,"reply":null,"replyId":null,"done":null}'
POS="$OFFSET"
START="$(date +%s)"
CHUNK="$(mktemp "${TMPDIR:-/tmp}/cc-send.XXXXXX")" || { say "❌ cc-send: couldn't make a temp file"; exit 5; }
state() { printf '%s' "$STATE" | jq -r "$1 // empty"; }
while :; do
  SIZE="$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')"
  case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
  if [ "$SIZE" -lt "$POS" ]; then
    say "❌ cc-send: $NAME's transcript shrank (replaced?) -- can't follow the reply."
    exit 5
  fi
  if [ "$SIZE" -gt "$POS" ]; then
    tail -c +"$((POS + 1))" "$TRANSCRIPT" 2>/dev/null | head -c "$((SIZE - POS))" > "$CHUNK"
    n="$(wc -c < "$CHUNK" | tr -d ' ')"
    # only whole lines: the last one may be mid-write, and is read again once it's whole
    if [ "$(tail -c 1 "$CHUNK" | wc -l | tr -d ' ')" = 1 ]; then torn=0; else torn="$(tail -n 1 "$CHUNK" | wc -c | tr -d ' ')"; fi
    whole=$((n - torn))
    if [ "$whole" -gt 0 ]; then
      next="$(head -c "$whole" "$CHUNK" | jq -R -n -c --argjson s "$STATE" --arg m "$MARKER" "$STEP" 2>/dev/null)"
      [ -n "$next" ] && STATE="$next"
      POS=$((POS + whole))
    fi
  fi
  case "$(state '.done')" in
    ended)
      RTEXT="$(state '.reply')"
      if [ -z "$RTEXT" ]; then say "ℹ️ $NAME's turn ended without a text reply."; exit 0; fi
      say "✅ $NAME replied."
      printf '%s\n' "$RTEXT"
      exit 0 ;;
    interrupted)
      say "❌ cc-send: $NAME's turn was interrupted before it replied."
      exit 5 ;;
    error)
      say "❌ cc-send: $NAME's turn ended on an API error: $(state '.error')"
      exit 5 ;;
  esac
  if [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
    if [ "$(state '.delivered')" = "true" ]; then
      say "⏳ cc-send: no reply from $NAME within ${TIMEOUT}s -- it has the prompt and is still on it."
    elif [ -n "$MAILBOX" ] && [ -e "$MAILBOX" ]; then
      say "⏳ cc-send: no reply from $NAME within ${TIMEOUT}s -- the prompt is still waiting in its mailbox."
    else
      say "⏳ cc-send: no reply from $NAME within ${TIMEOUT}s -- the prompt hasn't reached its transcript yet."
    fi
    exit 4
  fi
  sleep "$POLL"
done
