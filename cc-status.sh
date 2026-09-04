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
  # Fallbacks for tools with no case arm above (the case arms are the source of
  # truth for known tools): try a generic command/file, else the tool name.
  [ -n "$s" ] || s="$(cc_get "$j" '.tool_input.command')"
  [ -n "$s" ] || s="$(cc_get "$j" '.tool_input.file_path')"
  [ -n "$s" ] || s="$tool"
  # Collapse newlines so a multi-line command stays one line in the tile, then cap.
  printf '%s' "$s" | tr '\n' ' ' | cut -c1-200
}

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
NAME="$(basename "$CWD")"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

# SessionEnd: drop the tile and any leftover decision file, then we're done.
if [ "$EVENT" = "sessionend" ]; then
  cc_ledger_enabled && cc_ledger_append "$(jq -nc \
    --arg sid "$SESSION_ID" --arg key "$KEY" --arg name "$NAME" --arg cwd "$CWD" \
    '{type:"session_end", session_id:$sid, key:$key, name:$name, cwd:$cwd}')"
  cc_remove "$KEY"
  echo "[cc-status] ✅ removed session '$NAME' ($KEY)" >&2
  exit 0
fi

# Without jq we can't merge; write a minimal file so the panel still shows it.
if ! cc_have_jq; then
  # permissionrequest maps to approval like the jq path (line ~152) -- the fallback
  # predates the PermissionRequest hook; defaulting it to "working" showed a session
  # blocked on the permission prompt as busy (the opposite of the panel's purpose).
  case "$EVENT" in
    notification|permissionrequest) STATUS="approval" ;;
    stop) STATUS="done" ;;
    sessionstart) STATUS="idle" ;;
    *) STATUS="working" ;;
  esac
  # JSON-escape the interpolated string values (cwd/name can legally contain a
  # double-quote, backslash, or control char on Unix/macOS); STATUS is one of our
  # own literals so it needs no escaping. Without this the file would be malformed
  # and parseStatusList would silently drop the tile.
  # Emit `editor` even here (cc_detect_editor is pure shell, no jq): the R1-31
  # kitty/terminal auto-model guard and focusProject routing depend on it; omitting
  # it makes the auto-model gate fail OPEN, pasting VS Code chat keystrokes into a
  # real terminal/Kitty window.
  FB_EDITOR="$(cc_detect_editor)"
  # R3-25: write atomically (temp + mv, the cc_merge/cc_del_field idiom) so a concurrent
  # 1Hz dashboard poll never observes an empty/partial file (which the JSON decode drops,
  # flickering the tile for a tick). Capture cc_now ONCE so updated==since on a fresh write
  # (two separate $(cc_now) calls could skew by 1s).
  NOW="$(cc_now)"
  FB="$(cc_file "$KEY")"
  FBTMP="${FB}.tmp.$$"
  printf '{"session_id":"%s","name":"%s","cwd":"%s","status":"%s","editor":"%s","updated":%s,"since":%s}\n' \
    "$(cc_json_str "$SESSION_ID")" "$(cc_json_str "$NAME")" "$(cc_json_str "$CWD")" \
    "$STATUS" "$(cc_json_str "$FB_EDITOR")" "$NOW" "$NOW" > "$FBTMP" && mv "$FBTMP" "$FB"
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
PROMPT_ACTIVE=""   # a genuine native prompt is up (Notification) -> mark pending.prompt
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
    # AskUserQuestion can arrive as a PermissionRequest too (not only PreToolUse).
    # Capture its questions/options like the PreToolUse arm so the summary is the
    # QUESTION (not the bare tool name) and the panel can render the choices --
    # summarize_tool has no AskUserQuestion case, so it would otherwise fall through
    # to the tool name and leave an option-less "wants: AskUserQuestion" tile.
    if [ "$PENDING_TOOL" = "AskUserQuestion" ]; then
      ASK_JSON="$(printf '%s' "$INPUT" | jq -c '.tool_input.questions // empty' 2>/dev/null)"
      PENDING_MSG="$(cc_get "$INPUT" '.tool_input.questions[0].question')"
    fi
    [ -n "$PENDING_MSG" ] || PENDING_MSG="$(summarize_tool "$INPUT" "$PENDING_TOOL")"
    ;;
  notification)
    NTYPE="$(cc_get "$INPUT" '.notification_type')"
    [ -n "$NTYPE" ] || NTYPE="$(cc_get "$INPUT" '.type')"
    PENDING_MSG="$(cc_get "$INPUT" '.message')"
    case "$NTYPE" in
      *permission*|*elicitation_dialog*)
        # Generic fallback: only sets pending if PermissionRequest hasn't
        # already recorded the precise command (PENDING_IF_ABSENT). A Notification
        # means Claude Code is GENUINELY prompting (the "Allow this bash command?"
        # dialog is up), not just a permission CHECK that may auto-resolve -- mark
        # the pending so the panel's stale-approval heal never hides it as "working".
        STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""; PENDING_IF_ABSENT="1"; PROMPT_ACTIVE="1"
        PENDING_TOOL="$(cc_get "$INPUT" '.tool_name')"
        ;;
      *idle*)
        STATUS="done"
        ;;
      "")
        # Type unknown (older builds): a bare Notification usually means
        # Claude wants you. Treat as approval and surface the message.
        STATUS="approval"; SET_PENDING="1"; CLEAR_PENDING=""; PENDING_IF_ABSENT="1"; PROMPT_ACTIVE="1"
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

# since = when we entered this status OR when a fresh prompt was armed. Keep it if the
# status is unchanged so the dashboard shows an accurate time-in-state -- EXCEPT when a new
# pending is being armed (SET_PENDING): a back-to-back approval->approval (a stuck earlier
# prompt whose resolution event was missed, then a NEW PermissionRequest) must advance
# `since` to the new prompt's arm time. The dashboard's progressed-heal compares the
# transcript against `since`; a preserved EARLIER arm time would read the live newer prompt
# as "already moved past" and heal it to "working", hiding a session actually blocked on
# you. A bg-agent SIBLING merge never sets SET_PENDING (it is NATIVE_GUARDED below), so this
# does NOT restart the escalation clock every tick (the R3-15 concern still holds).
PREV="$(cc_current_status "$KEY")"
if [ "$STATUS" != "$PREV" ] || [ -n "$SET_PENDING" ]; then
  SINCE="$NOW"
else
  SINCE="$(cc_read_field "$KEY" '.since')"
  # Coerce a non-numeric/empty .since (hand-edit, rsync-mirror, partial write) to
  # NOW: --argjson below requires valid JSON, so a non-numeric value would wedge
  # every further update for this tile. Mirrors core.parseStatusList's tonumber
  # hardening on the reader side (cc-core.lua).
  case "$SINCE" in ''|*[!0-9]*) SINCE="$NOW" ;; esac
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
# Sticky cycle membership: once a session is ever observed in an OPTIONAL mode
# (bypassPermissions/auto), that mode is in its real Shift+Tab rotation for the
# session's lifetime. Record it under mode_cycle -- the final apply below uses
# jq's RECURSIVE `. * $patch` merge, so memberships accumulate and every later
# event that omits mode_cycle preserves it. cc-core's parseStatusList lifts this
# onto item.modeCycle and handleAction sizes the set-mode press count from it;
# without the record the dashboard computes wrap-arounds over the 3-mode cycle
# while the session cycles through 4+, landing set-mode on the wrong (and
# possibly permission-free) mode.
case "$PERMISSION_MODE" in
  bypassPermissions|auto)
    PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$PERMISSION_MODE" '.mode_cycle = {($v): true}')" ;;
esac
# #16: effort/model come from the spawn-time env ($CLAUDE_EFFORT / ANTHROPIC_MODEL),
# which does NOT track a live /effort or /model switch -- but the dashboard's
# set-effort/set-model DO persist the switched value into this file (FX.patchStatus).
# Re-patching from env on every hook event stomped that back to the stale spawn-time
# value one event later (the Effort/Model dropdowns snapped back within ~1s). Write
# each only when the file doesn't carry one yet (first event of a session, incl. the
# fresh file a /clear mints): the spawn-time value still lands, a live switch survives.
[ -n "$EFFORT" ] && [ -z "$(cc_read_field "$KEY" '.effort')" ] \
  && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$EFFORT" '. + {effort:$v}')"
[ -n "$MODEL" ] && [ -z "$(cc_read_field "$KEY" '.model')" ] \
  && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$MODEL" '. + {model:$v}')"
[ -n "$BASE_URL" ]   && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$BASE_URL"   '. + {base_url:$v}')"
# Record kitty handles ONLY for sessions the detector classifies as kitty:
# KITTY_WINDOW_ID/KITTY_LISTEN_ON are ordinary inherited env vars, so a VS Code/
# Cursor cold-started from a kitty shell (`code .`) hands every hosted session
# the launching kitty window's identity. Publishing that forged pair made
# core.staleDuplicateKeys' termId (which prefers kitty sock#wid over host_window)
# identical across ALL editor windows -- cross-window false prunes of live tiles,
# a shared respawn budget, and dashboard keystrokes routed via `kitty @` into the
# launching shell instead of the session.
if [ "$EDITOR_KIND" = "kitty" ]; then
  [ -n "$KITTY_WID" ]  && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$KITTY_WID"  '. + {kitty_window_id:$v}')"
  [ -n "$KITTY_SOCK" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$KITTY_SOCK" '. + {kitty_listen_on:$v}')"
  # #19: a Shepherd kitty RESPAWN carries its predecessor's retry-budget key in
  # CC_SHEPHERD_LINEAGE (set by FX.spawnSession). Publish it so core.budgetKey
  # keys the successor's budget to the SAME lineage -- the relaunch's own
  # socket/window ids are brand new, so without this the respawn cap never binds.
  # Kitty-gated like the handles above: a VS Code session cold-started from that
  # kitty window's shell must not inherit the lineage (same forged-env threat).
  [ -n "${CC_SHEPHERD_LINEAGE:-}" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$CC_SHEPHERD_LINEAGE" '. + {budget_lineage:$v}')"
fi

# Non-Kitty per-window host id (VS Code/Cursor) so the panel can auto-prune /clear
# ghosts (kitty uses its window id above). Computed once per session: reuse the value
# already in the file; only walk the process tree when it's absent (≈first event of a
# session, incl. the fresh session a /clear mints) so the hot hook path stays cheap.
if [ "$EDITOR_KIND" != "kitty" ]; then
  HOST_WINDOW="$(cc_host_window "$KEY")"   # reuse stored id; walk the tree only when absent
  [ -n "$HOST_WINDOW" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$HOST_WINDOW" '. + {host_window:$v}')"
  # The session's OWN process pid, from the same walk. host_window cannot tell a
  # /clear ghost from a live sibling -- one editor window hosts many sessions -- but
  # /clear keeps the SAME process and mints a new session id, so a shared pid means
  # one of the two tiles is a retired session. Cached in the file like host_window.
  SESSION_PID="$(cc_session_pid "$KEY")"
  [ -n "$SESSION_PID" ] && PATCH="$(printf '%s' "$PATCH" | jq -c --arg v "$SESSION_PID" '. + {session_pid:$v}')"
fi

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

# A genuine native prompt is up (a Notification fired -- the "Allow this bash command?"
# dialog -- not just a permission CHECK that may auto-resolve): mark the pending so the
# panel's stale-approval heal keeps showing "needs you" instead of treating an
# auto-running tool as working. Marks the NEW pending just written OR the precise one a
# PermissionRequest already recorded this turn (PENDING_IF_ABSENT kept it): the recursive
# `*` merge below adds .pending.prompt without clobbering tool/summary.
if [ -n "$PROMPT_ACTIVE" ]; then
  PATCH="$(printf '%s' "$PATCH" | jq -c '.pending = ((.pending // {}) + {prompt:true})')"
fi

# R1-36: cc-approve.sh (the gate) and THIS hook run in parallel under the same
# PreToolUse matcher group, both read-modify-writing <key>.json. While the gate is
# armed (gate=="waiting") it OWNS the tile's status/since/pending: a sibling event's
# {status:working}+pending-clear would revert the approval status and delete the
# pending block (incl. its nonce), and a sibling PermissionRequest/AskUserQuestion
# would REPLACE the gate's pending with a nonce-less one -- the panel then shows one
# request while Approve answers another (the decision still binds via gate_nonce).
# So EVERY event that writes status/pending is guarded, not just pre/posttooluse;
# the notification arms are already covered by PENDING_IF_ABSENT above.
# R3-15: `since` is stripped too -- the gate recorded since:T1 (when the approval
# started) and the dashboard's stale-approval escalation measures (now - since); a
# sibling merge of since:$NOW would restart that clock every tick so the threshold
# never trips. `updated` still flows (tile stays fresh).
GATE_GUARDED=""
case "$EVENT" in
  pretooluse|posttooluse|userpromptsubmit|stop|permissionrequest) GATE_GUARDED="1" ;;
esac

# The NATIVE permission prompt (gate not armed -- the default install) needs the
# same shielding: once permissionrequest publishes {status:approval, pending}, a
# concurrent sibling pretooluse/posttooluse (parallel subagents share the parent
# session_id) must not wipe it -- no further hook fires while the prompt sits, so
# the tile would show "working" forever on a session actually blocked on you. The
# one event that legitimately resolves it is the approved tool's own PostToolUse:
# same tool_name AND the same summary the pending was recorded with (recomputed by
# the same rules). userpromptsubmit/stop still clear (the prompt is gone once the
# turn moves on -- also the recovery path after a native deny), and a SET_PENDING
# event (a fresh PermissionRequest/AskUserQuestion) still replaces: newest wins.
NATIVE_GUARDED=""
case "$EVENT" in
  pretooluse|posttooluse)
    if [ -z "$SET_PENDING" ]; then
      NATIVE_GUARDED="1"
      if [ "$EVENT" = "posttooluse" ]; then
        P_TOOL="$(cc_read_field "$KEY" '.pending.tool')"
        if [ -n "$P_TOOL" ] && [ "$P_TOOL" = "$(cc_get "$INPUT" '.tool_name')" ]; then
          if [ "$P_TOOL" = "AskUserQuestion" ]; then
            # AskUserQuestion is answered SEQUENTIALLY (one in flight per turn), so its
            # OWN PostToolUse IS the resolution -- a tool-name match is enough. Requiring
            # the incoming question to equal the recorded summary wrongly pinned the tile
            # on "approval" forever whenever the pending was armed via a PermissionRequest
            # (summary = the bare tool name -- summarize_tool has no Ask arm), so the
            # answered session showed "needs you" while it worked on. The summary check
            # still guards every OTHER tool (a pending Bash vs a different Bash completing).
            NATIVE_GUARDED=""
          else
            EV_SUM="$(summarize_tool "$INPUT" "$P_TOOL")"
            [ -n "$EV_SUM" ] || EV_SUM="$P_TOOL"
            [ "$EV_SUM" = "$(cc_read_field "$KEY" '.pending.summary')" ] && NATIVE_GUARDED=""
          fi
        fi
      fi
    fi ;;
esac

# Apply the patch in ONE atomic read-modify-write (the cc_merge temp+mv idiom) with
# the guard decided INSIDE the same jq pass on the same snapshot. The previous
# read-.gate-then-merge left a TOCTOU window: cc-approve's arming merge could land
# between the `.gate` read and our write, so the {status:working} merge + pending
# delete reverted the freshly armed gate and the panel never showed the approval
# for the whole GATE_TIMEOUT poll.
# A new pending also fully REPLACES the old one here: jq's recursive `*` preserves
# an object key the patch doesn't carry, so a new pending WITHOUT an `ask` (e.g. a
# Write PermissionRequest following an AskUserQuestion) would otherwise leave the
# stale `pending.ask` behind, leaking dead option buttons onto an unrelated
# approval tile -- the old pending is dropped first so the fresh one is authoritative.
# #28: the snapshot->jq->mv itself was still a lost-update window: cc-approve's
# arming cc_merge (gate:"waiting" + gate_nonce + pending) can land between our
# `cat` and our `mv` -- both hooks run in parallel for the same PreToolUse event --
# and the mv then replaced the file with output computed from the PRE-ARM snapshot,
# dropping gate, pending AND gate_nonce (unlike the jq-level clear R1-36 covers, a
# full-file clobber loses the top-level nonce too: the panel never shows the request
# and the waiter polls blind for the whole GATE_TIMEOUT). Optimistic-concurrency
# commit: after computing the merge, re-read the file and only mv if it is still the
# snapshot we computed from; otherwise recompute from the fresh content -- the
# retried jq pass then sees gate=="waiting" and takes the guard branch, preserving
# the arming. Bounded tries keep the hook from livelocking; the residual race
# (re-check -> mv, a few syscalls, no jq spawn inside) is orders of magnitude
# narrower than the ~15-30ms jq window it closes, and the exhausted-tries commit
# equals the old behavior. Full closure needs the writers to share a lock or the
# gate to verify/replay its arming (a cc-approve.sh change).
MF="$(cc_file "$KEY")"
MTMP="${MF}.tmp.$$"
MERGE_JQ='
   if ($gg != "" and .gate == "waiting")
      or ($ng != "" and .status == "approval" and (.pending | type) == "object") then
     # a live approval owns status/since/pending; only refresh the rest
     . * ($patch | del(.status, .since, .pending))
   else
     (if $setp != "" then del(.pending) else . end) * $patch
     | (if $clrp != "" then del(.pending) else . end)
   end'
APPLY_TRIES=0
while :; do
  CUR="$(cat "$MF" 2>/dev/null)"
  [ -n "$CUR" ] || CUR='{}'
  if printf '%s' "$CUR" | jq -c \
       --argjson patch "$PATCH" \
       --arg gg "$GATE_GUARDED" --arg ng "$NATIVE_GUARDED" \
       --arg setp "$SET_PENDING" --arg clrp "$CLEAR_PENDING" \
       "$MERGE_JQ" > "$MTMP" 2>/dev/null; then
    :
  # Self-heal a corrupt status file, same as cc_merge (cc-lib.sh): invalid JSON on
  # disk fails the merge above on EVERY subsequent hook event, so the tile vanishes
  # from the panel -- approvals included -- and the session can never republish
  # itself until SessionEnd. Retry from {}: it succeeds iff the PATCH is valid
  # (i.e. the failure was the file), rebuilding the tile from this event's fields.
  # The guards read .gate/.status of the input, so from {} they simply don't fire.
  # The #28 re-check below covers this branch too: if cc-approve's arming healed
  # the file first, the next iteration merges into it instead of clobbering it.
  elif printf '{}' | jq -c \
       --argjson patch "$PATCH" \
       --arg gg "$GATE_GUARDED" --arg ng "$NATIVE_GUARDED" \
       --arg setp "$SET_PENDING" --arg clrp "$CLEAR_PENDING" \
       "$MERGE_JQ" > "$MTMP" 2>/dev/null; then
    :
  else
    rm -f "$MTMP" 2>/dev/null || true
    break
  fi
  RECHECK="$(cat "$MF" 2>/dev/null)"
  [ -n "$RECHECK" ] || RECHECK='{}'
  if [ "$RECHECK" = "$CUR" ] || [ "$APPLY_TRIES" -ge 3 ]; then
    mv "$MTMP" "$MF"
    break
  fi
  APPLY_TRIES=$(( APPLY_TRIES + 1 ))
done

# ---- Audit ledger: record the governance-relevant lifecycle event ----------
# Tool usage is logged only when it needed a decision (PermissionRequest) or is an
# AskUserQuestion (the session is waiting on you) — not every Read/Grep/etc. When
# the gate is armed the resolved allow/deny is logged separately by cc-approve.sh.
if cc_ledger_enabled; then
  # Stable per-launch-folder id from transcript_path (…/projects/<ENC>/…), to
  # mirror cc-core's projectKey; empty until the first transcript path arrives.
  PROJECT_KEY=""
  case "$TRANSCRIPT" in
    */projects/*/*.jsonl)
      PROJECT_KEY="${TRANSCRIPT##*/projects/}"; PROJECT_KEY="${PROJECT_KEY%%/*}" ;;
  esac
  LBASE="$(jq -nc \
    --arg sid "$SESSION_ID" --arg key "$KEY" --arg name "$NAME" \
    --arg pk "$PROJECT_KEY" --arg cwd "$CWD" \
    '{session_id:$sid, key:$key, name:$name, projectKey:$pk, cwd:$cwd}')"
  case "$EVENT" in
    sessionstart)
      cc_ledger_append "$(printf '%s' "$LBASE" | jq -c '. + {type:"session_start"}')" ;;
    userpromptsubmit)
      LP="$(printf '%s' "$SET_PROMPT" | cut -c1-200)"
      cc_ledger_append "$(printf '%s' "$LBASE" | jq -c --arg p "$LP" '. + {type:"prompt", prompt:$p}')" ;;
    permissionrequest)
      cc_ledger_append "$(printf '%s' "$LBASE" | jq -c \
        --arg t "$PENDING_TOOL" --arg s "$PENDING_MSG" '. + {type:"tool_request", tool:$t, summary:$s}')" ;;
    pretooluse)
      [ "$PENDING_TOOL" = "AskUserQuestion" ] && cc_ledger_append "$(printf '%s' "$LBASE" | jq -c \
        --arg t "$PENDING_TOOL" --arg s "$PENDING_MSG" '. + {type:"tool_request", tool:$t, summary:$s}')" ;;
  esac
fi

echo "[cc-status] ✅ $EVENT -> $STATUS for '$NAME' ($KEY)" >&2
exit 0
