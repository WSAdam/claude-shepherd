#!/usr/bin/env bash
# merge.test.sh - ~/.claude/cc-merge.sh, a worktree tab's side of the ready-to-merge flow
# (2026-09-11). The tab asks for a merge and waits -- in the background, so Claude Code
# wakes it when the script exits -- for Adam's answer in Shepherd, delivered as a decision
# file bound to the request's nonce (the gate's claim-by-mv pattern). After merging, `done`
# confirms the branch is in main before removing the worktree and branch, never forcing.
# Side-effect-free: a throwaway repo, status and merge dirs under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status" CC_MERGE_DIR="$TMP/merge" CC_MERGE_POLL=0.1
mkdir -p "$CC_STATUS_DIR"
M="$ROOT/cc-merge.sh"
MD="$CC_MERGE_DIR"

REPO="$TMP/repo"
g() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }
git init -q -b main "$REPO"
printf '.claude/worktrees/\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/app.txt"
g "$REPO" add -A && g "$REPO" commit -qm init
unit() { # <slug> <branch> [commit?]: a worktree under .claude/worktrees/, one commit ahead unless told not to
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$1" -b "$2"
  if [ "${3:-yes}" = yes ]; then
    printf '%s\n' "$1" >> "$REPO/.claude/worktrees/$1/$1.txt"
    g "$REPO/.claude/worktrees/$1" add -A && g "$REPO/.claude/worktrees/$1" commit -qm "$1 change"
  fi
}
unit demo fix/demo
WT="$(cd "$REPO/.claude/worktrees/demo" && pwd -P)"
alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }
req() { # <dir> <session> [args...] -> stdout+stderr in $TMP/out.<session>, exit code in $TMP/rc.<session>
  local d="$1" s="$2"; shift 2
  (cd "$d" && CLAUDE_CODE_SESSION_ID="$s" CLAUDE_PID=4242 bash "$M" request --summary "Fix the demo" --tests "make test: green" "$@" \
     > "$TMP/out.$s" 2>&1; echo $? > "$TMP/rc.$s")
}
# <session> <pid>: wait until the request names a DIFFERENT waiting process than <pid>, i.e.
# until a resumed request has stamped its own. Kept local to this suite on purpose -- tests/lib.sh
# is shared by every bash suite, so a helper only this one needs doesn't belong there.
wait_for_wait_pid() { local i; for i in $(seq 1 60); do
  [ "$(jq -r .wait_pid "$MD/$1.json" 2>/dev/null)" != "$2" ] && return 0; sleep 0.1; done; return 1; }
answer() { # <session> <verdict> [note] [nonce]: what Shepherd writes
  local n="${4:-$(jq -r .nonce "$MD/$1.json")}"
  jq -n --arg n "$n" --arg v "$2" --arg note "${3:-}" '{nonce:$n, verdict:$v, note:$note}' > "$MD/$1.decision.tmp"
  mv "$MD/$1.decision.tmp" "$MD/$1.decision"
}

# ---- refusals: nothing is written, the reason is printed ----
rc=0; (cd "$WT" && env -u CLAUDE_CODE_SESSION_ID bash "$M" request --summary x --tests y > "$TMP/o" 2>&1) || rc=$?
assert_eq "outside a Claude Code session: refused" "2" "$rc"
grep -q "Claude Code session" "$TMP/o" && got=yes || got=no
assert_eq "...saying why" "yes" "$got"

alive
req "$REPO" main1
assert_eq "from the main checkout: refused (a unit merges FROM its worktree)" "2" "$(cat "$TMP/rc.main1")"
grep -q "main checkout" "$TMP/out.main1" && got=yes || got=no
assert_eq "...saying why" "yes" "$got"

git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/det"
req "$REPO/.claude/worktrees/det" det1
assert_eq "a detached HEAD: refused" "2" "$(cat "$TMP/rc.det1")"

printf 'wip\n' > "$WT/wip.txt"
req "$WT" dirty1
assert_eq "uncommitted changes: refused" "2" "$(cat "$TMP/rc.dirty1")"
grep -q "wip.txt" "$TMP/out.dirty1" && got=yes || got=no
assert_eq "...listing what's uncommitted" "yes" "$got"
rm -f "$WT/wip.txt"

unit empty fix/empty no
req "$REPO/.claude/worktrees/empty" empty1
assert_eq "nothing ahead of main: refused" "2" "$(cat "$TMP/rc.empty1")"
grep -q "nothing to merge" "$TMP/out.empty1" && got=yes || got=no
assert_eq "...saying so" "yes" "$got"

rm -f "$CC_STATUS_DIR/.panel-alive"
req "$WT" off1
assert_eq "Shepherd not running: exit 6" "6" "$(cat "$TMP/rc.off1")"
grep -q "Shepherd isn't running" "$TMP/out.off1" && got=yes || got=no
assert_eq "...telling the session to ask in chat" "yes" "$got"
[ -z "$(ls "$MD" 2>/dev/null)" ] && got=none || got=some
assert_eq "no refusal left a request behind" "none" "$got"

# ---- a request, a stranger's answer, then Merge ----
alive
req "$WT" s1 --wait-max 1 & bg=$!
wait_for "$MD/s1.json"
assert_json "the request names its session" "$MD/s1.json" .session_id s1
assert_json "...its pid" "$MD/s1.json" .pid 4242
assert_json "...its worktree" "$MD/s1.json" .worktree "$WT"
assert_json "...its branch" "$MD/s1.json" .branch fix/demo
assert_json "...the base" "$MD/s1.json" .base main
assert_json "...the summary" "$MD/s1.json" .summary "Fix the demo"
assert_json "...the test claim" "$MD/s1.json" .tests "make test: green"
assert_json "...and waits for an answer" "$MD/s1.json" .phase requested
assert_json "...bound to a nonce" "$MD/s1.json" '.nonce | length > 0' true
n_s1="$(jq -r .nonce "$MD/s1.json")"

# ---- a stranger's answer is claimed, rejected and put back (2026-09-22) ----
# 2026-09-22: this block sampled `[ -e "$MD/s1.decision" ]` ONCE, 0.6s after planting the
# answer, and read [eaten] about 1 run in 8. The file legitimately does not exist for part of
# every poll: cc-merge.sh claims it with `mv "$DEC" "$claim"` (cc-merge.sh:142) and restores a
# foreign one with `ln "$claim" "$DEC"` (cc-merge.sh:175), and the gap between those two lines
# holds a jq fork -- measured at 5.5% of instants with CC_MERGE_POLL=0.1. So never sample while
# a claimer runs: bound the waiter with --wait-max, let it EXIT, and assert when no claim window
# can exist (tests/gate.test.sh:400-416 already does this for cc-approve.sh's identical pattern).
# Planted by hand rather than through answer(): the inode has to be read BEFORE the file appears
# at the polled name, or reading it is itself a sample inside the claim window. Same tmp+mv idiom
# answer() uses (what FX.writeMergeDecision does), and the same reason gate.test.sh:405-409 plants
# its own file. GNU stat first: `stat -f` means file-system status on GNU and SUCCEEDS, so a
# BSD-first fallback reads a mount point, not an inode (the ordering gate.test.sh:417 settled).
jq -n '{nonce:"someone-else", verdict:"merge", note:""}' > "$MD/s1.decision.tmp"
dec_ino0="$(stat -c %i "$MD/s1.decision.tmp" 2>/dev/null || stat -f %i "$MD/s1.decision.tmp" 2>/dev/null)"
mv "$MD/s1.decision.tmp" "$MD/s1.decision"
wait $bg
assert_eq "an answer for another request is ignored (still waiting)" "4" "$(cat "$TMP/rc.s1")"
grep -q "Still waiting for Adam" "$TMP/out.s1" && got=yes || got=no
assert_eq "...the waiter says so and leaves the request open" "yes" "$got"
assert_json "...the request is still unanswered" "$MD/s1.json" .phase requested
[ -e "$MD/s1.decision" ] && got=kept || got=eaten
assert_eq "...and put back, never deleted" "kept" "$got"
# Present is not enough: it must be the SAME file, untouched -- the stranger's nonce verbatim,
# and the same inode, which only the `ln` put-back can give (a rewrite would mint a new one).
assert_json "...still holding the stranger's nonce, unread" "$MD/s1.decision" .nonce "someone-else"
dec_ino1="$(stat -c %i "$MD/s1.decision" 2>/dev/null || stat -f %i "$MD/s1.decision" 2>/dev/null)"
assert_eq "...put back as a hardlink, not rewritten" "same" \
  "$([ -n "$dec_ino0" ] && [ "$dec_ino0" = "$dec_ino1" ] && echo same)"
ls "$MD"/s1.decision.claim.* >/dev/null 2>&1 && got=some || got=none
assert_eq "...leaving no half-claimed copy behind" "none" "$got"
ls "$MD"/s1.decision.parked.* >/dev/null 2>&1 && got=some || got=none
assert_eq "...and nothing parked (no new answer landed mid-claim)" "none" "$got"
rm -f "$MD/s1.decision"

# The same unit asks again on the SAME request -- the nonce survives, the waiting process is new.
wp0="$(jq -r .wait_pid "$MD/s1.json")"
req "$WT" s1 & bg=$!
wait_for_wait_pid s1 "$wp0"
assert_json "asking again keeps the request (Adam's click can't be lost in between)" "$MD/s1.json" .nonce "$n_s1"
# 2026-09-17: the card said "Needs you" for merge requests nobody was waiting on any more --
# Adam's click would write a decision file that no process ever claims. The request names the
# PROCESS that is waiting, so Shepherd can check it with ps before ranking the card red.
assert_json "...and names the process waiting for the answer" "$MD/s1.json" \
  '.wait_pid | tostring | test("^[0-9]+$")' true
wp="$(jq -r .wait_pid "$MD/s1.json")"
kill -0 "$wp" 2>/dev/null && got=alive || got=gone
assert_eq "...which is alive while it waits" "alive" "$got"
answer s1 merge
wait $bg
assert_eq "Merge: the script exits 0" "0" "$(cat "$TMP/rc.s1")"
grep -q "MERGE APPROVED" "$TMP/out.s1" && got=yes || got=no
assert_eq "...printing MERGE APPROVED" "yes" "$got"
grep -q "git merge --ff-only fix/demo" "$TMP/out.s1" && grep -q "cc-merge.sh done --result merged" "$TMP/out.s1" && got=yes || got=no
assert_eq "...with the steps: ff-merge, then done" "yes" "$got"
assert_json "...the request moves to approved" "$MD/s1.json" .phase approved
assert_absent "...and the decision is consumed" "$MD/s1.decision"

# ---- Not yet, with a note ----
req "$WT" s2 & bg=$!
wait_for "$MD/s2.json"
answer s2 hold "rename the helper first"
wait $bg
assert_eq "Not yet: exit 3" "3" "$(cat "$TMP/rc.s2")"
grep -q "NOT YET: rename the helper first" "$TMP/out.s2" && got=yes || got=no
assert_eq "...passing Adam's note to the session" "yes" "$got"
assert_absent "...and the request is gone" "$MD/s2.json"

# ---- withdrawn (Shepherd removed it: the card was closed) ----
req "$WT" s3 & bg=$!
wait_for "$MD/s3.json"
rm -f "$MD/s3.json"
wait $bg
assert_eq "a withdrawn request: exit 5" "5" "$(cat "$TMP/rc.s3")"

# ---- a foreground wait that times out, then resumes on the SAME request ----
req "$WT" s4 --wait-max 1
assert_eq "--wait-max: still waiting -> exit 4" "4" "$(cat "$TMP/rc.s4")"
n1="$(jq -r .nonce "$MD/s4.json")"
wp1="$(jq -r .wait_pid "$MD/s4.json")"
req "$WT" s4 --wait-max 5 & bg=$!
sleep 0.4
assert_json "asking again keeps the same request (Adam's click can't be lost in between)" "$MD/s4.json" .nonce "$n1"
# ...but the waiting PROCESS is a new one, and the request must name it -- otherwise the card
# reads "nobody is waiting" off the dead first attempt and stops asking Adam for his click.
wp2="$(jq -r .wait_pid "$MD/s4.json")"
[ "$wp2" != "$wp1" ] && got=refreshed || got=stale
assert_eq "...while the waiting process is re-stamped on every ask" "refreshed" "$got"
answer s4 merge "" "$n1"
wait $bg
assert_eq "...and the first request's answer is honoured" "0" "$(cat "$TMP/rc.s4")"

# ---- asking from OUTSIDE the worktree (2026-09-11) ----
# 2026-09-11 E2E: Claude Code's worktree-isolation guard refused `cc-merge.sh request` run from
# inside two fenced unit tabs ("cannot be shown not to be git") -- it judges the script, which
# runs git. So a unit leaves its worktree (ExitWorktree) and asks from the main checkout, naming
# the worktree; nothing runs inside the fence.
unit outside fix/outside
WTO="$(cd "$REPO/.claude/worktrees/outside" && pwd -P)"
req "$REPO" o1 --worktree "$WTO" & bg=$!
wait_for "$MD/o1.json"
assert_json "from the main checkout, --worktree names the unit's worktree" "$MD/o1.json" .worktree "$WTO"
assert_json "...and its branch" "$MD/o1.json" .branch fix/outside
answer o1 merge
wait $bg
assert_eq "...approved: exit 0" "0" "$(cat "$TMP/rc.o1")"
grep -q "EnterWorktree with path $WTO" "$TMP/out.o1" && got=yes || got=no
assert_eq "...and the steps start by going back into the worktree to rebase" "yes" "$got"
req "$REPO" o2 --worktree "$REPO"
assert_eq "--worktree naming the main checkout is refused" "2" "$(cat "$TMP/rc.o2")"
mkdir -p "$TMP/notgit"
req "$REPO" o3 --worktree "$TMP/notgit"
assert_eq "--worktree naming a folder outside any repo is refused" "2" "$(cat "$TMP/rc.o3")"
OTHER="$TMP/other"; git init -q -b main "$OTHER"; printf 'y\n' > "$OTHER/y"
git -C "$OTHER" add -A && git -C "$OTHER" -c user.email=t@example.invalid -c user.name=t commit -qm init
git -C "$OTHER" worktree add -q "$OTHER/.claude/worktrees/x" -b fix/x
req "$REPO" o4 --worktree "$OTHER/.claude/worktrees/x"
assert_eq "--worktree of another repo than the one you're in is refused" "2" "$(cat "$TMP/rc.o4")"

# ---- done ----
done_() { (cd "$REPO" && CLAUDE_CODE_SESSION_ID="$1" bash "$M" done "${@:2}" > "$TMP/dout.$1" 2>&1; echo $? > "$TMP/drc.$1"); }
done_ s1 --result merged
assert_eq "done before the ff-merge: refused" "2" "$(cat "$TMP/drc.s1")"
grep -q "isn't in main" "$TMP/dout.s1" && got=yes || got=no
assert_eq "...saying the branch isn't in main yet" "yes" "$got"
[ -d "$WT" ] && got=kept || got=removed
assert_eq "...and the worktree is untouched" "kept" "$got"

git -C "$REPO" merge -q --ff-only fix/demo
done_ s1 --result merged
assert_eq "done after the ff-merge: exit 0" "0" "$(cat "$TMP/drc.s1")"
assert_json "...phase merged" "$MD/s1.json" .phase merged
assert_json "...recording the merged commit" "$MD/s1.json" .sha "$(git -C "$REPO" rev-parse main)"
[ -d "$WT" ] && got=kept || got=removed
assert_eq "...the worktree is removed" "removed" "$got"
git -C "$REPO" show-ref --verify --quiet refs/heads/fix/demo && got=kept || got=deleted
assert_eq "...and the branch deleted" "deleted" "$got"

unit dirty fix/dirty
req "$REPO/.claude/worktrees/dirty" s5 & bg=$!
wait_for "$MD/s5.json"; answer s5 merge; wait $bg
git -C "$REPO" merge -q --ff-only fix/dirty
printf 'scratch\n' > "$REPO/.claude/worktrees/dirty/notes.txt"
done_ s5 --result merged
assert_eq "an untracked file in the worktree: done still exits 0 (the merge happened)" "0" "$(cat "$TMP/drc.s5")"
assert_json "...phase merged-dirty" "$MD/s5.json" .phase merged-dirty
[ -f "$REPO/.claude/worktrees/dirty/notes.txt" ] && got=kept || got=lost
assert_eq "...the worktree is never forced away (the file survives)" "kept" "$got"
grep -q -i "never forced" "$TMP/dout.s5" && got=yes || got=no
assert_eq "...and it says what to do" "yes" "$got"

unit block fix/block
req "$REPO/.claude/worktrees/block" s6 & bg=$!
wait_for "$MD/s6.json"; answer s6 merge; wait $bg
done_ s6 --result blocked --note "the two branches' tests disagree"
assert_json "blocked: phase blocked" "$MD/s6.json" .phase blocked
assert_json "...with the session's reason" "$MD/s6.json" .note "the two branches' tests disagree"

done_ nobody --result merged
assert_eq "done with no request: refused" "2" "$(cat "$TMP/drc.nobody")"

# ---- SessionEnd reaps a session's merge files (cc_remove) ----
mkdir -p "$MD"
printf '{}' > "$MD/s9.json"; printf 'x' > "$MD/s9.decision"; printf 'x' > "$MD/s9.decision.claim.1"
[ -f "$MD/s9.json" ] && [ -f "$MD/s9.decision.claim.1" ] && got=yes || got=no
assert_eq "(fixture: the merge files exist before cc_remove)" "yes" "$got"
( . "$ROOT/cc-lib.sh"; cc_remove s9 )
assert_absent "cc_remove drops the merge request" "$MD/s9.json"
assert_absent "...its decision" "$MD/s9.decision"
assert_absent "...and any claimed decision" "$MD/s9.decision.claim.1"

finish
