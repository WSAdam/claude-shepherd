#!/usr/bin/env bash
# fleet.test.sh - ~/.claude/cc-fleet.sh, a driving session's side of batch driving (2026-09-11).
# A Claude session proposes a batch of worktree units; Adam approves it ONCE in Shepherd (a
# decision bound to the proposal's nonce); the driver then asks Shepherd to open each unit's
# tab and gets back the new session's name and the message to hand it. Status and stop too.
# Side-effect-free: a throwaway repo; fleet, status and sessions dirs under a temp dir; the
# Shepherd side is played by this test writing its decision and answer files.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status" CC_FLEET_DIR="$TMP/fleet" CC_SESSIONS_DIR="$TMP/sessions" CC_FLEET_POLL=0.1
mkdir -p "$CC_STATUS_DIR" "$CC_SESSIONS_DIR"
F="$ROOT/cc-fleet.sh"
FD="$CC_FLEET_DIR"

REPO="$TMP/repo"
git init -q -b main "$REPO"
printf 'x\n' > "$REPO/a.txt"
git -C "$REPO" add -A && git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm init
REPOP="$(cd "$REPO" && pwd -P)"
printf '{"pid":4242,"sessionId":"drv","name":"repo-drv"}' > "$CC_SESSIONS_DIR/4242.json"
alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }
batch() { printf '%s' "$1" > "$TMP/batch.json"; }
fleet() { # <session> <out-name> args... -> $TMP/<out>.out and $TMP/<out>.rc
  local s="$1" o="$2"; shift 2
  (cd "$REPO" && CLAUDE_CODE_SESSION_ID="$s" CLAUDE_PID=4242 bash "$F" "$@" > "$TMP/$o.out" 2>&1; echo $? > "$TMP/$o.rc")
}
wait_for() { local i; for i in $(seq 1 60); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
newest_batch() { ls -t "$FD"/b*.json 2>/dev/null | grep -v -E '\.(state|tab-)' | head -n 1; }
decide() { # <batch file> <verdict> <grantMerge> [note] [nonce]
  local id n; id="$(jq -r .id "$1")"; n="${5:-$(jq -r .nonce "$1")}"
  jq -n --arg n "$n" --arg v "$2" --argjson g "$3" --arg note "${4:-}" '{nonce:$n, verdict:$v, grantMerge:$g, note:$note}' > "$FD/$id.decision.tmp"
  mv "$FD/$id.decision.tmp" "$FD/$id.decision"
}
GOOD='{"title":"Two helpers","mergeWhenGreen":true,"units":[{"type":"feat","slug":"alpha","task":"Add alpha."},{"type":"fix","slug":"beta","task":"Fix beta."}]}'

# ---- refusals ----
batch "$GOOD"
rc=0; (cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$F" propose --file "$TMP/batch.json" > "$TMP/o" 2>&1) || rc=$?
assert_eq "outside a Claude Code session: refused" "2" "$rc"
alive
for bad in '{"title":"x","units":[' \
           '{"title":"x","units":[]}' \
           '{"title":"x","units":[{"type":"chore","slug":"a","task":"t"}]}' \
           '{"title":"x","units":[{"type":"feat","slug":"Bad Slug","task":"t"}]}' \
           '{"title":"x","units":[{"type":"feat","slug":"a","task":"t"},{"type":"fix","slug":"a","task":"t"}]}' \
           '{"title":"x","units":[{"type":"feat","slug":"a"}]}' \
           "$(jq -nc '{title:"x", units:[range(9) | {type:"feat", slug:("u\(.)"), task:"t"}]}')"; do
  batch "$bad"; fleet drv bad propose --file "$TMP/batch.json"
  assert_eq "a malformed batch is refused: $(printf '%s' "$bad" | cut -c1-60)" "2" "$(cat "$TMP/bad.rc")"
done
git -C "$REPO" branch feat/taken
batch '{"title":"x","units":[{"type":"feat","slug":"taken","task":"t"}]}'
fleet drv taken propose --file "$TMP/batch.json"
assert_eq "a unit whose branch already exists is refused" "2" "$(cat "$TMP/taken.rc")"
grep -q "feat/taken" "$TMP/taken.out" && got=yes || got=no
assert_eq "...naming it" "yes" "$got"
rm -f "$CC_STATUS_DIR/.panel-alive"
batch "$GOOD"; fleet drv off propose --file "$TMP/batch.json"
assert_eq "Shepherd not running: exit 6" "6" "$(cat "$TMP/off.rc")"
[ -z "$(ls "$FD" 2>/dev/null)" ] && got=none || got=some
assert_eq "no refusal left a proposal behind" "none" "$got"

# ---- propose, a stranger's answer, then approve with merge permission ----
alive
fleet drv p1 propose --file "$TMP/batch.json" & bg=$!
for i in $(seq 1 60); do B="$(newest_batch)"; [ -n "$B" ] && break; sleep 0.1; done
assert_json "the proposal names its driver session" "$B" .driver.session_id drv
assert_json "...and the driver's SendMessage name" "$B" .driver.name repo-drv
assert_json "...the repo's main checkout" "$B" .repo "$REPOP"
assert_json "...each unit's branch" "$B" '.units[0].branch + " " + .units[1].branch' "feat/alpha fix/beta"
assert_json "...what it asks for merges" "$B" .mergeWhenGreen true
assert_json "...and waits" "$B" .phase proposed
decide "$B" approve true "" "someone-else"
sleep 0.5
[ -e "$TMP/p1.rc" ] && got=exited || got=waiting
assert_eq "an answer for another proposal is ignored" "waiting" "$got"
rm -f "$FD/$(jq -r .id "$B").decision"
decide "$B" approve true
wait $bg
assert_eq "approved: exit 0" "0" "$(cat "$TMP/p1.rc")"
grep -q "BATCH APPROVED" "$TMP/p1.out" && grep -q "cc-fleet.sh tab --batch" "$TMP/p1.out" && got=yes || got=no
assert_eq "...printing BATCH APPROVED and how to open each tab" "yes" "$got"
grep -q "Merges are delegated" "$TMP/p1.out" && got=yes || got=no
assert_eq "...and that merges are delegated (Adam kept the box ticked)" "yes" "$got"
assert_json "...the proposal moves to approved" "$B" .phase approved
ID="$(jq -r .id "$B")"

# ---- tab ----
fleet other t0 tab --batch "$ID" --unit alpha
assert_eq "tab: only the driving session may open the batch's tabs" "2" "$(cat "$TMP/t0.rc")"
fleet drv t1 tab --batch "$ID" --unit gamma
assert_eq "tab: an unknown unit is refused" "2" "$(cat "$TMP/t1.rc")"
fleet drv t2 tab --batch "$ID" --unit alpha & bg=$!
wait_for "$FD/$ID.tab-alpha.json"
assert_json "tab: the request names the unit and the driver" "$FD/$ID.tab-alpha.json" '.slug + " " + .session_id' "alpha drv"
TN="$(jq -r .nonce "$FD/$ID.tab-alpha.json")"
jq -n --arg n "$TN" '{nonce:$n, ok:true, name:"repo-a1", sessionId:"s-a1", message:"Start unit feat/alpha in its own worktree"}' > "$FD/$ID.tab-alpha.answer"
wait $bg
assert_eq "tab: Shepherd's answer -> exit 0" "0" "$(cat "$TMP/t2.rc")"
grep -q "repo-a1" "$TMP/t2.out" && grep -q "Start unit feat/alpha" "$TMP/t2.out" && got=yes || got=no
assert_eq "tab: prints the new session's name and the message to send it" "yes" "$got"
assert_absent "tab: the request is cleaned up" "$FD/$ID.tab-alpha.json"
printf '{"units":{"alpha":{"session":{"name":"repo-a1"}}}}' > "$FD/$ID.state.json"
fleet drv t3 tab --batch "$ID" --unit alpha
assert_eq "tab: a unit that already has its tab is refused" "2" "$(cat "$TMP/t3.rc")"
fleet drv t4 tab --batch "$ID" --unit beta & bg=$!
wait_for "$FD/$ID.tab-beta.json"
jq -n --arg n "$(jq -r .nonce "$FD/$ID.tab-beta.json")" '{nonce:$n, ok:false, reason:"the repo window never appeared"}' > "$FD/$ID.tab-beta.answer"
wait $bg
assert_eq "tab: Shepherd refusing -> exit 2" "2" "$(cat "$TMP/t4.rc")"
grep -q "never appeared" "$TMP/t4.out" && got=yes || got=no
assert_eq "...with its reason" "yes" "$got"

# ---- status, stop ----
fleet drv s1 status --batch "$ID"
grep -q "repo-a1" "$TMP/s1.out" && got=yes || got=no
assert_eq "status prints Shepherd's view of the units" "yes" "$got"

# ---- status groups the units by outcome (2026-09-18) ----
# It used to print four scalars plus Shepherd's ENTIRE raw state file: no grouping, and the
# proposal's units (their branches) never appeared. The unit of analysis is the outcome.
sj() { jq -r "$1" "$TMP/$2.out" 2>/dev/null; }
assert_eq "status: valid JSON (driver sessions parse it)" "yes" "$(jq -e . "$TMP/s1.out" >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "status: a unit with its session and no result is working" "alpha" "$(sj '.outcomes.working | join(",")' s1)"
assert_eq "status: a unit with no tab yet is unopened" "beta" "$(sj '.outcomes.unopened | join(",")' s1)"
assert_eq "status: counts for all four buckets, the empty ones too" "0 0 1 1" \
  "$(sj '.counts | "\(.merged) \(.blocked) \(.working) \(.unopened)"' s1)"
assert_eq "status: each unit shows its branch, outcome and session" "feat/alpha working repo-a1 | fix/beta unopened -" \
  "$(sj '[.units[] | "\(.branch) \(.outcome) \(.session // "-")"] | join(" | ")' s1)"
assert_eq "status: the raw state dump is gone" "null" "$(sj '.shepherd' s1)"
jq -n '{grant: {approved: true, grantMerge: true, at: 5}, before: {"1": {}},
        units: {alpha: {session: {id: "s-a1", name: "repo-a1", pid: 7}, result: "merged-dirty"},
                beta:  {session: {id: "s-b1", name: "repo-b1", pid: 8}, result: "blocked"}}}' > "$FD/$ID.state.json"
fleet drv s2 status --batch "$ID"
assert_eq "status: merged-dirty counts as merged, blocked is blocked" "alpha / beta" \
  "$(sj '(.outcomes.merged | join(",")) + " / " + (.outcomes.blocked | join(","))' s2)"
assert_eq "status: ...and the unit keeps its exact result" "merged-dirty" "$(sj '.units[0].result' s2)"
assert_eq "status: Adam's grant as Shepherd recorded it" "true true" "$(sj '"\(.grant.approved) \(.grant.grantMerge)"' s2)"
assert_eq "status: none of Shepherd's bookkeeping (pids, the before snapshot)" "clean" \
  "$(grep -q -e '"pid"' -e '"before"' "$TMP/s2.out" && echo leaked || echo clean)"
rm -f "$FD/$ID.state.json"
fleet drv s3 status --batch "$ID"
assert_eq "status: no state file yet = every unit unopened" "alpha,beta 2" \
  "$(sj '(.outcomes.unopened | join(",")) + " " + (.counts.unopened | tostring)' s3)"
assert_eq "status: ...and no grant" "null" "$(sj '.grant' s3)"
printf '{"units":{"alpha":{"session":{"name":"repo-a1"}}}}' > "$FD/$ID.state.json"
printf 'garbage{' > "$TMP/keep.state"; cp "$FD/$ID.state.json" "$TMP/good.state"; cp "$TMP/keep.state" "$FD/$ID.state.json"
fleet drv s4 status --batch "$ID"
assert_eq "status: a torn state file still answers, every unit unopened" "0 alpha,beta" \
  "$(echo "$(cat "$TMP/s4.rc") $(sj '.outcomes.unopened | join(",")' s4)")"
cp "$TMP/good.state" "$FD/$ID.state.json"

fleet drv st stop --batch "$ID"
assert_eq "stop: exit 0" "0" "$(cat "$TMP/st.rc")"
assert_json "stop: the proposal is stopped" "$B" .phase stopped
fleet drv t5 tab --batch "$ID" --unit beta
assert_eq "tab: refused once the batch is stopped" "2" "$(cat "$TMP/t5.rc")"

# ---- deny, and a foreground wait that runs out ----
batch '{"title":"Nope","mergeWhenGreen":false,"units":[{"type":"docs","slug":"gamma","task":"t"}]}'
fleet drv p2 propose --file "$TMP/batch.json" & bg=$!
sleep 0.5; B2="$(newest_batch)"
decide "$B2" deny false "not today"
wait $bg
assert_eq "denied: exit 3" "3" "$(cat "$TMP/p2.rc")"
grep -q "DENIED: not today" "$TMP/p2.out" && got=yes || got=no
assert_eq "...with Adam's note" "yes" "$got"
fleet drv t6 tab --batch "$(jq -r .id "$B2")" --unit gamma
assert_eq "tab: refused on a denied batch" "2" "$(cat "$TMP/t6.rc")"
batch '{"title":"Slow","units":[{"type":"docs","slug":"delta","task":"t"}]}'
fleet drv p3 propose --file "$TMP/batch.json" --wait-max 1
assert_eq "--wait-max: still waiting -> exit 4" "4" "$(cat "$TMP/p3.rc")"

finish
