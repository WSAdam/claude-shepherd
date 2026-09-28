#!/usr/bin/env bash
# worktree-guard.test.sh - cc-worktree-guard.sh (PreToolUse, matcher EnterWorktree) denies entering
# a linked worktree another LIVE session is working in: one worktree, one agent (2026-09-28).
# 2026-09-28: nothing stopped a session from EnterWorktree'ing into a worktree a second agent was
# already editing -- two agents on the same files under each other's feet. Only positive proof
# blocks: a status file in that worktree whose claude process is alive and isn't this session's.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
export CC_STATUS_DIR="$TMP/status"
mkdir -p "$CC_STATUS_DIR"
G="$ROOT/cc-worktree-guard.sh"

# A repo with one linked worktree, the way EnterWorktree makes them.
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/unit" -b feat/unit 2>/dev/null
REPO="$(cd "$REPO" && pwd -P)"          # macOS: /var/folders -> /private/var/folders
WT="$REPO/.claude/worktrees/unit"
mkdir -p "$WT/sub"

# Processes that look like claude sessions: the guard checks the command line, so a reused pid
# that belongs to some other program never counts.
(exec -a claude-test-session sleep 120) & OTHER=$!; disown "$OTHER"
(exec -a claude-test-session sleep 120) & ME=$!; disown "$ME"
(exec -a some-other-program sleep 120) & NOTCLAUDE=$!; disown "$NOTCLAUDE"
PIDS="$OTHER $ME $NOTCLAUDE"
for p in $OTHER $ME $NOTCLAUDE; do
  for _ in $(seq 1 50); do ps -o command= -p "$p" 2>/dev/null | grep -q -- '-session\|-program' && break; sleep 0.05; done
done

status() { # <session_id> <cwd> [session_pid]
  if [ -n "${3:-}" ]; then
    jq -nc --arg s "$1" --arg c "$2" --arg p "$3" '{session_id:$s, name:($c|split("/")|last), cwd:$c, status:"working", session_pid:$p}'
  else
    jq -nc --arg s "$1" --arg c "$2" '{session_id:$s, name:($c|split("/")|last), cwd:$c, status:"working"}'
  fi > "$CC_STATUS_DIR/$1.json"
}
guard() { # <cwd> <tool_input json> -> the hook's stdout
  jq -nc --arg c "$1" --argjson ti "$2" \
    '{session_id:"me", cwd:$c, hook_event_name:"PreToolUse", tool_name:"EnterWorktree", tool_input:$ti}' \
    | bash "$G" 2>/dev/null
}
decision() { # the permissionDecision in a hook's stdout, or "none"
  [ -n "$1" ] || { echo none; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo none
}

status me "$REPO" "$ME"
status other "$WT" "$OTHER"

out="$(guard "$REPO" "{\"path\":\"$WT\"}")"
assert_eq "entering a worktree another live session is working in is denied" "deny" "$(decision "$out")"
assert_eq "...the reason names that session" "yes" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '"unit"' && echo yes || echo no)"
assert_eq "a folder inside that worktree is the same worktree" "deny" "$(decision "$(guard "$REPO" "{\"path\":\"$WT/sub\"}")")"
assert_eq "a path relative to the session's folder resolves too" "deny" \
  "$(decision "$(guard "$REPO" '{"path":".claude/worktrees/unit"}')")"

assert_eq "a new worktree by name is never denied (nobody can be in it yet)" "none" \
  "$(decision "$(guard "$REPO" '{"name":"another"}')")"
assert_eq "a path that isn't a worktree is left to EnterWorktree" "none" \
  "$(decision "$(guard "$REPO" '{"path":"/nonexistent/place"}')")"

status other "$REPO" "$OTHER"
assert_eq "the main checkout is shared: never denied" "none" "$(decision "$(guard "$REPO" "{\"path\":\"$REPO\"}")")"

status other "$WT"
assert_eq "a status file with no process id never blocks (fail open)" "none" "$(decision "$(guard "$REPO" "{\"path\":\"$WT\"}")")"
status other "$WT" "$ME"
assert_eq "this session's own earlier incarnation never blocks (a /clear keeps the process)" "none" \
  "$(decision "$(guard "$REPO" "{\"path\":\"$WT\"}")")"
status other "$WT" "$NOTCLAUDE"
assert_eq "a pid reused by some other program holds nothing" "none" "$(decision "$(guard "$REPO" "{\"path\":\"$WT\"}")")"
kill "$OTHER" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$OTHER" 2>/dev/null || break; sleep 0.05; done
status other "$WT" "$OTHER"
assert_eq "a session whose process is gone holds nothing" "none" "$(decision "$(guard "$REPO" "{\"path\":\"$WT\"}")")"

(exec -a claude-test-session sleep 120) & OTHER2=$!; disown "$OTHER2"
PIDS="$PIDS $OTHER2"
for _ in $(seq 1 50); do ps -o command= -p "$OTHER2" 2>/dev/null | grep -q -- '-session' && break; sleep 0.05; done
status other "$WT" "$OTHER2"
assert_eq "other tools pass straight through" "" \
  "$(jq -nc --arg c "$REPO" '{session_id:"me", cwd:$c, tool_name:"Bash", tool_input:{command:"ls"}}' | bash "$G" 2>/dev/null)"
assert_eq "Shepherd's own headless runs are never guarded" "" \
  "$(jq -nc --arg c "$REPO" --arg p "$WT" '{session_id:"me", cwd:$c, tool_name:"EnterWorktree", tool_input:{path:$p}}' \
     | CC_SHEPHERD_INTERNAL=1 bash "$G" 2>/dev/null)"
assert_eq "...while a live session there is denied again" "deny" "$(decision "$(guard "$REPO" "{\"path\":\"$WT\"}")")"

finish
