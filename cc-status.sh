#!/usr/bin/env bash
#
# cc-status.sh - record the live state of a Claude Code session so the
# Claude Shepherd dashboard can display and act on it. Called by Claude Code hooks.
#
# Usage: cc-status.sh <event>
#   event is the hook that fired, one of:
#     sessionstart | userpromptsubmit | pretooluse | posttooluse |
#     permissionrequest | notification | stop | sessionend
#
# The hook event JSON arrives on stdin. We key each session by its session_id
# (so two sessions in the same folder never collide), and merge only the fields
# this event knows into ~/.claude/cc-status/<key>.json, preserving the rest.
#
# Status derived per event:
#   sessionstart    -> idle
#   userpromptsubmit-> working  (+ last_prompt, clears pending)
#   pretooluse      -> working  (clears pending)
#   posttooluse     -> working  (clears pending)
#   permissionrequest -> approval (+ precise pending from tool_input)
#   notification    -> approval | done | (unchanged)  depending on type
#   stop            -> done      (clears pending)
#   sessionend      -> file removed
#
# Field names below (prompt text, notification type/message) are read with
# tolerant fallbacks because they can vary slightly by Claude Code version;
# run once with CC_STATUS_DEBUG=1 to capture raw payloads and confirm.

set -u

EVENT="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

INPUT="$(cat 2>/dev/null || true)"
cc_debug "event=$EVENT raw=$INPUT"

# Build a short, human summary of what a tool wants to do, from its tool_input.
# (PermissionRequest carries the exact tool_input; Notification only a message.)
summarize_tool() { # $1 = json, $2 = tool_name
  local j="$1" tool="$2" s=""
  case "$tool" in
    Bash) s="$(cc_get "$j" '.tool_input.command')" ;;
    Write|Edit|MultiEdit) s="$(cc_get "$j" '.tool_input.file_path')" ;;
    NotebookEdit) s="$(cc_get "$j" '.tool_input.notebook_path')" ;;
  esac
  [ -n "$s" ] || s="$(cc_get "$j" '.tool_input.command')"
  [ -n "$s" ] || s="$(cc_get "$j" '.tool_input.file_path')"
  [ -n "$s" ] || s="$tool"
  printf '%s' "$s" | cut -c1-200
}

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
NAME="$(basename "$CWD")"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

# SessionEnd: drop the tile and any leftover decision file, then we're done.
if [ "$EVENT" = "sessionend" ]; then
  cc_remove "$KEY"
  echo "[cc-status] ✅ removed session '$NAME' ($KEY)" >&2
  exit 0
fi

# Without jq we can't merge; write a minimal file so the panel still shows it.
if ! cc_have_jq; then
  case "$EVENT" in
    notification) STATUS="approval" ;;
    stop) STATUS="done" ;;
    sessionstart) STATUS="idle" ;;
    *) STATUS="working" ;;
  esac
  printf '{"session_id":"%s","name":"%s","cwd":"%s","status":"%s","updated":%s,"since":%s}\n' \
    "$SESSION_ID" "$NAME" "$CWD" "$STATUS" "$(cc_now)" "$(cc_now)" > "$(cc_file "$KEY")"
  echo "[cc-status] ⚠️  jq not found; wrote minimal $STATUS for '$NAME'" >&2
  exit 0
fi

# Detect the host editor from the inherited env (this hook runs as a child of
# `claude`), so the panel can route actions per session: Kitty remote control vs
# the VS Code/Cursor GUI. Anything not clearly Kitty defaults to vscode behavior.
EDITOR_KIND="$(cc_detect_editor)"  # shared detector in cc-lib.sh (used by cc-popup.sh too)
PERMISSION_MODE="$(cc_get "$INPUT" '.permission_mode')"
EFFORT="${CLAUDE_EFFORT:-}"
# The backend the session is running against (set by the provider profile at spawn
# via ANTHROPIC_MODEL / ANTHROPIC_BASE_URL), so the panel can show + verify it.
MODEL="${ANTHROPIC_MODEL:-}"
BASE_URL="${ANTHROPIC_BASE_URL:-}"
KITTY_WID="${KITTY_WINDOW_ID:-}"
KITTY_SOCK="${KITTY_LISTEN_ON:-}"

# Decide the new status (and any extras) from the event.
STATUS="working"
SET_PROMPT=""
SET_PENDING=""
CLEAR_PENDING="1"
PENDING_IF_ABSENT=""
PENDING_TOOL=""
PENDING_MSG=""
ASK_JSON=""

case "$EVENT" in
  sessionstart)
    STATUS="idle"
    ;;
  userpromptsubmit)
    STATUS="working"
    SET_PROMPT="$(cc_get "$INPUT" '.prompt_text')"
    [ -n "$SET_PROMPT" ] || SET_PROMPT="$(cc_get "$INPUT" '.prompt')"
    ;;
  pretooluse|posttooluse)
    STATUS="working"
    # AskUserQuestion carries the multiple-choice questions in tool_input; capture
    # them so the panel can render the options (the session is now waiting on you).
    if [ "$EVENT" = "pretooluse" ] && [ "$(cc_get "$INPUT" '.tool_name')" = "AskUserQuestion" ]; then
      ASK_JSON="$(printf '%s' "$INPUT" | jq -c '.tool_input.questions // empty' 2>/dev/null)"
      if [ -n "$ASK_JSON" ]; then
        STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""
        PENDING_TOOL="AskUserQuestion"
        PENDING_MSG="$(cc_get "$INPUT" '.tool_input.questions[0].question')"
      fi
    fi
    ;;
  permissionrequest)
    # The precise event: carries tool_name + tool_input, so we can show the
    # exact command/file being requested rather than a generic message.
    STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""
    PENDING_TOOL="$(cc_get "$INPUT" '.tool_name')"
    PENDING_MSG="$(summarize_tool "$INPUT" "$PENDING_TOOL")"
    ;;
  notification)
    NTYPE="$(cc_get "$INPUT" '.notification_type')"
    [ -n "$NTYPE" ] || NTYPE="$(cc_get "$INPUT" '.type')"
    PENDING_MSG="$(cc_get "$INPUT" '.message')"
    case "$NTYPE" in
      *permission*|*elicitation_dialog*)
        # Generic fallback: only sets pending if PermissionRequest hasn't
        # already recorded the precise command (PENDING_IF_ABSENT).
        STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""; PENDING_IF_ABSENT="1"
        PENDING_TOOL="$(cc_get "$INPUT" '.tool_name')"
        ;;
      *idle*)
        STATUS="done"
        ;;
      "")
        # Type unknown (older builds): a bare Notification usually means
        # Claude wants you. Treat as approval and surface the message.
        STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""; PENDING_IF_ABSENT="1"
        ;;
      *)
        # auth_success / elicitation_complete / etc. - don't change status,
        # just refresh the timestamp below.
        STATUS="$(cc_current_status "$KEY")"
        [ -n "$STATUS" ] || STATUS="idle"
        CLEAR_PENDING=""
        ;;
    esac
    ;;
  stop)
    STATUS="done"
    ;;
  *)
    STATUS="working"
    ;;
esac

NOW="$(cc_now)"

# since = when we entered this status. Keep it if the status is unchanged so
# the dashboard can show an accurate time-in-state.
PREV="$(cc_current_status "$KEY")"
if [ "$STATUS" != "$PREV" ]; then
  SINCE="$NOW"
else
  SINCE="$(cc_read_field "$KEY" '.since')"
  [ -n "$SINCE" ] || SINCE="$NOW"
fi

# Build the merge patch.
PATCH="$(jq -nc \
  --arg sid "$SESSION_ID" \
  --arg name "$NAME" \
  --arg cwd "$CWD" \
  --arg status "$STATUS" \
  --argjson updated "$NOW" \
  --argjson since "$SINCE" \
  '{session_id:$sid, name:$name, cwd:$cwd, status:$status, updated:$updated, since:$since}')"

if [ -n "$SET_PROMPT" ]; then
  TRIMMED="$(printf '%s' "$SET_PROMPT" | cut -c1-200)"
  PATCH="$(printf '%s' "$PATCH" | jq -c --arg lp "$TRIMMED" '. + {last_prompt:$lp}')"
fi

# Record the transcript path (for the dashboard's live activity peek).
TRANSCRIPT="$(cc_get "$INPUT" '.transcript_path')"
if [ -n "$TRANSCRIPT" ]; then
  PATCH="$(printf '%s' "$PATCH" | jq -c --arg tp "$TRANSCRIPT" '. + {transcript_path:$tp}')"
fi

# Host editor (always) + live mode/effort/kitty handles (when present), so the
# panel can route per session and display current mode/effort.
PATCH="$(printf '%s' "$PATCH" | jq -c --arg ed "$EDITOR_KIND" '. + {editor:$ed}')"
[ -n "$PERMISSION_MODE" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$PERMISSION_MODE" '. + {permission_mode:$v}')"
[ -n "$EFFORT" ]     && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$EFFORT"     '. + {effort:$v}')"
[ -n "$MODEL" ]      && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$MODEL"      '. + {model:$v}')"
[ -n "$BASE_URL" ]   && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$BASE_URL"   '. + {base_url:$v}')"
[ -n "$KITTY_WID" ]  && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$KITTY_WID"  '. + {kitty_window_id:$v}')"
[ -n "$KITTY_SOCK" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$KITTY_SOCK" '. + {kitty_listen_on:$v}')"

# Don't let a generic Notification clobber a precise pending that
# PermissionRequest already recorded this turn.
if [ -n "$SET_PENDING" ] && [ -n "$PENDING_IF_ABSENT" ]; then
  [ -n "$(cc_read_field "$KEY" '.pending.summary')" ] && SET_PENDING=""
fi

if [ -n "$SET_PENDING" ]; then
  SUMMARY="$PENDING_MSG"
  [ -n "$SUMMARY" ] || SUMMARY="$PENDING_TOOL"
  PATCH="$(printf '%s' "$PATCH" | jq -c \
    --arg tool "$PENDING_TOOL" --arg msg "$PENDING_MSG" --arg sum "$SUMMARY" \
    '. + {pending:{tool:$tool, summary:$sum, message:$msg}}')"
  # Attach the AskUserQuestion questions/options so the panel can render them.
  if [ -n "$ASK_JSON" ]; then
    PATCH="$(printf '%s' "$PATCH" | jq -c --argjson ask "$ASK_JSON" '.pending.ask = $ask')"
  fi
fi

cc_merge "$KEY" "$PATCH"
[ -n "$CLEAR_PENDING" ] && cc_del_field "$KEY" "pending"

echo "[cc-status] ✅ $EVENT -> $STATUS for '$NAME' ($KEY)" >&2
exit 0
