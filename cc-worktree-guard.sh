#!/usr/bin/env bash
#
# cc-worktree-guard.sh - PreToolUse hook (matcher EnterWorktree): one worktree, one agent
# (2026-09-28). Denies entering a linked worktree another LIVE session is already working in --
# two agents in one worktree edit the same files under each other's feet. Shepherd refuses the
# same thing on its own spawns (core.worktreeOccupant); this is the session's own door.
#
# Only positive proof blocks: a status file whose cwd is inside the target worktree and whose
# session_pid is alive, is a claude process (a reused pid isn't), and isn't this session's own
# (a /clear keeps the process and mints a new session id). A status file without a pid (kitty
# sessions) never blocks, the main checkout is shared, and EnterWorktree by name makes a new
# worktree nobody can be in yet. Only the decision JSON is ever written to stdout.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

INPUT="$(cat 2>/dev/null || true)"
[ -z "${CC_SHEPHERD_INTERNAL:-}" ] || exit 0
cc_have_jq || exit 0
[ "$(cc_get "$INPUT" '.tool_name')" = "EnterWorktree" ] || exit 0

TARGET="$(cc_get "$INPUT" '.tool_input.path')"
[ -n "$TARGET" ] || exit 0                      # by name: a new worktree, nobody in it yet
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
case "$TARGET" in /*) ;; *) TARGET="$CWD/$TARGET" ;; esac
[ -d "$TARGET" ] || exit 0                       # not there: EnterWorktree says why

# The worktree's top level and its repo's main checkout, as git reports them (real paths).
FACTS="$(git -C "$TARGET" rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null)" || exit 0
TOP="$(printf '%s\n' "$FACTS" | sed -n 1p)"
COMMON="$(printf '%s\n' "$FACTS" | sed -n 2p)"
[ -n "$TOP" ] && [ -n "$COMMON" ] || exit 0
[ "$TOP" != "${COMMON%/.git}" ] || exit 0        # the main checkout is shared

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
OWN_PID="$(cc_session_pid "$(cc_key "$SESSION_ID" "$CWD")")"

HIT=""
TAB="$(printf '\t')"
while IFS="$TAB" read -r sid pid name; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac   # no pid (kitty): never proof
  [ "$sid" != "$SESSION_ID" ] || continue
  [ "$pid" != "$OWN_PID" ] || continue           # this session's own /clear ghost
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *claude*) HIT="$name"; break ;;
  esac
done <<EOF
$(for f in "$CC_DIR"/*.json; do [ -f "$f" ] && { cat "$f"; echo; }; done 2>/dev/null \
  | jq -R -r --arg top "$TOP" '(try fromjson catch null) | select(type == "object")
      | select((.cwd | type) == "string" and (.cwd == $top or (.cwd | startswith($top + "/"))))
      | [(.session_id // "" | tostring), (.session_pid // "" | tostring), (.name // "" | tostring)] | @tsv' 2>/dev/null)
EOF

[ -n "$HIT" ] || exit 0
REASON="Another live Claude session (\"$HIT\") is already working in $TOP. One worktree, one agent: pick another worktree, or finish that session first."
jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
echo "[cc-worktree-guard] 🚫 EnterWorktree into $TOP denied: \"$HIT\" is working there" >&2
exit 0
