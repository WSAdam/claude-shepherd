#!/usr/bin/env bash
# cc-merge.sh - a worktree tab's side of Shepherd's ready-to-merge flow.
#
#   cc-merge.sh request --summary "<what the unit does and why>" --tests "<command>: <result>"
#                       [--base main] [--wait-max <seconds>]
#   cc-merge.sh done --result merged|blocked [--note "<why>"]
#
# request: checks the unit can merge (its own worktree, on a branch, clean, ahead of the
# base), asks Shepherd, then waits for Adam's answer. Run it in the BACKGROUND and end the
# turn: Claude Code wakes the session when it exits. Asking again from the same unit keeps
# the same request. Exit codes: 0 MERGE APPROVED (the steps follow), 3 NOT YET (Adam's note
# follows), 4 still waiting (--wait-max ran out), 5 the request was withdrawn, 6 Shepherd
# isn't running, 2 refused (the reason is printed).
#
# done: after the fast-forward merge, confirms the branch is in the base, removes the
# worktree and the branch (never forced) and tells Shepherd, which then closes the tab if it
# opened it for the unit (a batch unit or a New worktree tab); a main chat stays open.
#
# The answer is a decision file bound to the request's nonce, claimed with mv (the approval
# gate's pattern): an answer meant for another request is put back, never consumed.
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

MERGE_DIR="${CC_MERGE_DIR:-$HOME/.claude/cc-merge}"
POLL="${CC_MERGE_POLL:-1}"
PANEL_MAX_AGE="${CC_MERGE_PANEL_MAX_AGE:-30}"

refuse() { echo "❌ cc-merge: $*"; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "jq is required"

SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset) -- run it from the unit's Claude tab"
KEY="$(cc_sanitize "$SID")"
REQ="$MERGE_DIR/$KEY.json"
DEC="$MERGE_DIR/$KEY.decision"

# Rewrite the request with a jq filter, atomically.
update_req() { # <jq filter> [jq args...]
  local filter="$1"; shift
  local tmp="$REQ.tmp.$$"
  if jq "$@" "$filter" "$REQ" > "$tmp" 2>/dev/null; then mv "$tmp" "$REQ"; else rm -f "$tmp"; return 1; fi
}

cmd_request() {
  local summary="" tests="" base="main" waitmax=0 wtArg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary)  summary="${2:-}"; shift 2 ;;
      --tests)    tests="${2:-}"; shift 2 ;;
      --base)     base="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      --worktree) wtArg="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  [ -n "$summary" ] || refuse "--summary is required: what the unit does and why, in 1-3 sentences"
  [ -n "$tests" ] || refuse "--tests is required: the command you ran and its result"
  case "$waitmax" in ''|*[!0-9]*) refuse "--wait-max takes whole seconds" ;; esac

  # Where the unit's worktree is: --worktree <path> when asking from the main checkout (the
  # way a fenced tab asks: ExitWorktree first, so nothing runs inside Claude Code's worktree
  # guard), else the worktree we're standing in.
  local wt common gitdir branch
  if [ -n "$wtArg" ]; then
    [ -d "$wtArg" ] || refuse "--worktree $wtArg isn't a folder"
    wt="$(git -C "$wtArg" rev-parse --show-toplevel 2>/dev/null)" || refuse "--worktree $wtArg isn't inside a git repository"
    local here
    here="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [ -z "$here" ] || [ "$here" = "$common" ] || refuse "--worktree $wtArg belongs to another repo than the one you're in"
  else
    wt="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a git repository (ask from the main checkout with --worktree <path>)"
  fi
  g() { git -C "$wt" "$@"; }
  common="$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  gitdir="$(g rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  [ "$gitdir" != "$common" ] || refuse "that's the main checkout -- a unit merges FROM its own worktree (--worktree <its path>)"
  branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null)" || refuse "the worktree is on a detached HEAD -- commit on a branch first"
  g check-ref-format --branch "$base" >/dev/null 2>&1 && g rev-parse --verify --quiet "refs/heads/$base" >/dev/null \
    || refuse "there's no local branch '$base' to merge into (--base)"
  [ "$branch" != "$base" ] || refuse "the worktree is on $base itself"
  local inside=no
  case "$(pwd -P)/" in "$wt"/*) inside=yes ;; esac
  local dirty
  dirty="$(g status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    echo "❌ cc-merge: uncommitted changes in the worktree -- commit them (or drop them) first:"
    printf '%s\n' "$dirty" | head -n 10
    exit 2
  fi
  local ahead
  ahead="$(g rev-list --count "refs/heads/$base..HEAD" 2>/dev/null)"
  [ "${ahead:-0}" -gt 0 ] 2>/dev/null || refuse "nothing to merge: $branch has no commits that $base doesn't"

  local now hb
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  if [ -z "$hb" ] || [ $((now - hb)) -gt "$PANEL_MAX_AGE" ]; then
    echo "⚠️ Shepherd isn't running, so nobody can approve this merge there. Ask Adam in chat to approve it, then follow the manual Finish steps in CLAUDE.md."
    exit 6
  fi

  mkdir -p "$MERGE_DIR" && chmod 700 "$MERGE_DIR" 2>/dev/null
  # The same unit asking again (a foreground wait that ran out) keeps its request and nonce,
  # so an answer given in between is never lost.
  local nonce=""
  if [ -f "$REQ" ]; then
    nonce="$(jq -r --arg b "$branch" --arg w "$wt" \
      'select(.phase == "requested" and .branch == $b and .worktree == $w) | .nonce // empty' "$REQ" 2>/dev/null)"
  fi
  if [ -z "$nonce" ]; then
    nonce="$$.$now.$RANDOM"
    rm -f "$DEC"
    local tmp="$REQ.tmp.$$"
    jq -n --arg key "$KEY" --arg sid "$SID" --arg pid "${CLAUDE_PID:-}" --arg nonce "$nonce" \
       --arg wt "$wt" --arg branch "$branch" --arg base "$base" --arg common "$common" \
       --arg summary "${summary:0:1000}" --arg tests "${tests:0:300}" \
       --argjson ahead "$ahead" --argjson at "$now" --argjson waitpid "$$" \
       '{v: 1, key: $key, session_id: $sid, pid: $pid, nonce: $nonce, worktree: $wt, branch: $branch,
         base: $base, commonDir: $common, summary: $summary, tests: $tests, ahead: $ahead, at: $at,
         wait_pid: $waitpid, phase: "requested"}' > "$tmp" && mv "$tmp" "$REQ" || refuse "couldn't write the request in $MERGE_DIR"
  else
    # Re-asking on the SAME request (a foreground wait that ran out): the nonce is kept so an
    # answer given in between isn't lost, but the process waiting for it is a NEW one. Shepherd
    # checks wait_pid with ps before calling the card "Needs you" (2026-09-17), so a stale pid
    # here would read as "nobody is waiting" and quietly stop asking Adam for his click.
    update_req '.wait_pid = $p' --argjson p "$$" || true
  fi
  echo "⏳ Asked Shepherd to merge $branch into $base ($ahead commit(s) ahead). Waiting for Adam's answer..."

  local start
  start="$(date +%s)"
  while :; do
    if [ ! -f "$REQ" ] || [ "$(jq -r '.nonce // empty' "$REQ" 2>/dev/null)" != "$nonce" ]; then
      echo "↩︎ The merge request was withdrawn in Shepherd. Nothing to do unless Adam asks again."
      exit 5
    fi
    if [ -f "$DEC" ]; then
      local claim="$DEC.claim.$$"
      if mv "$DEC" "$claim" 2>/dev/null; then
        if [ "$(jq -r '.nonce // empty' "$claim" 2>/dev/null)" = "$nonce" ]; then
          local verdict note
          verdict="$(jq -r '.verdict // empty' "$claim" 2>/dev/null)"
          note="$(jq -r '.note // empty' "$claim" 2>/dev/null | head -c 500)"
          rm -f "$claim" "$DEC".parked.*
          if [ "$verdict" = "merge" ]; then
            update_req '.phase = "approved" | .approvedAt = $t' --argjson t "$(date +%s)"
            cat <<EOF
MERGE APPROVED -- Adam approved merging $branch into $base. Now, in order:
$( [ "$inside" = yes ] || echo "0. EnterWorktree with path $wt (you asked from the main checkout) -- the rebase happens there." )
1. In the worktree, rebase on $base: git rebase $base
   Conflicts: the tests are the oracle -- read both sides' tests and keep the resolution that
   satisfies both. If none does, it's a design question: run step 6's blocked form and stop.
2. Run the full suite here; it must be green.
3. ExitWorktree (action "keep") to get back to the main checkout.
4. There: git merge --ff-only $branch
   If $base moved in the meantime, EnterWorktree with path $wt and go back to step 1.
5. Run the full suite on $base; it must be green. Do the project's own post-merge steps too
   (its CLAUDE.md -- e.g. a redeploy from $base).
6. ~/.claude/cc-merge.sh done --result merged
   It confirms the merge and removes the worktree and the branch. If Shepherd opened this tab for
   the unit (a batch unit or a New worktree tab), it closes it; a main chat stays open.
   If you can't finish: ~/.claude/cc-merge.sh done --result blocked --note "<why>" -- then stop.
EOF
            exit 0
          fi
          rm -f "$REQ"
          echo "NOT YET: ${note:-(no note)}"
          echo "Adam isn't ready to merge $branch. Act on the note (EnterWorktree with path $wt to change it), then leave the worktree and ask again with the same request command."
          exit 3
        fi
        # Not ours: put it back untouched. If a new answer landed meanwhile, park this one.
        if ln "$claim" "$DEC" 2>/dev/null; then rm -f "$claim"; else mv "$claim" "$DEC.parked.$$" 2>/dev/null; fi
      fi
    fi
    if [ "$waitmax" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$waitmax" ]; then
      echo "⏳ Still waiting for Adam after ${waitmax}s. Run the same command again to keep waiting -- the request stays open."
      exit 4
    fi
    sleep "$POLL"
  done
}

cmd_done() {
  local result="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --result) result="${2:-}"; shift 2 ;;
      --note)   note="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  case "$result" in merged|blocked) ;; *) refuse "--result must be merged or blocked" ;; esac
  [ -f "$REQ" ] || refuse "there's no merge request for this session -- nothing to report"
  local now phase branch base wt common
  now="$(date +%s)"
  phase="$(jq -r '.phase // empty' "$REQ")"; branch="$(jq -r '.branch // empty' "$REQ")"
  base="$(jq -r '.base // empty' "$REQ")"; wt="$(jq -r '.worktree // empty' "$REQ")"
  common="$(jq -r '.commonDir // empty' "$REQ")"

  if [ "$result" = "blocked" ]; then
    update_req '.phase = "blocked" | .note = $n | .doneAt = $t' --arg n "${note:0:500}" --argjson t "$now" \
      || refuse "couldn't update the request"
    echo "⚠️ Told Shepherd the merge of $branch is blocked: ${note:-(no reason given)}. Adam will see it on the card."
    exit 0
  fi

  [ "$phase" = "approved" ] || refuse "this merge was never approved in Shepherd (it's '$phase')"
  git --git-dir="$common" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$base" 2>/dev/null \
    || refuse "$branch isn't in $base yet -- finish the fast-forward merge (git merge --ff-only $branch in the main checkout) first"
  local sha main err problem=""
  sha="$(git --git-dir="$common" rev-parse "refs/heads/$base")"
  main="${common%/.git}"
  if [ -d "$wt" ]; then
    err="$(git -C "$main" worktree remove "$wt" 2>&1)" || problem="the worktree wasn't removed ($err)"
  fi
  if [ -z "$problem" ]; then
    err="$(git -C "$main" branch -d "$branch" 2>&1)" || problem="the branch $branch wasn't deleted ($err)"
  fi
  if [ -z "$problem" ]; then
    update_req '.phase = "merged" | .sha = $s | .doneAt = $t' --arg s "$sha" --argjson t "$now"
    echo "✅ Merged $branch into $base; the worktree and the branch are gone. If Shepherd opened this tab for the unit, it closes it once your turn ends; a main chat stays open."
  else
    update_req '.phase = "merged-dirty" | .sha = $s | .note = $n | .doneAt = $t' \
      --arg s "$sha" --arg n "${problem:0:500}" --argjson t "$now"
    echo "⚠️ Merged $branch into $base, but $problem. It was never forced: look at what's left, then"
    echo "   remove it yourself (git worktree remove $wt / git branch -d $branch) once it's safe."
  fi
  exit 0
}

case "${1:-}" in
  request) shift; cmd_request "$@" ;;
  done)    shift; cmd_done "$@" ;;
  *) echo "usage: cc-merge.sh request --summary <text> --tests <text> [--base main] [--wait-max <s>]"
     echo "       cc-merge.sh done --result merged|blocked [--note <text>]"
     exit 2 ;;
esac
