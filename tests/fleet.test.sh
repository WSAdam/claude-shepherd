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

# ---- `alive`: the one honest way to ask whether Shepherd is up (2026-09-22) ----
# 2026-09-22: a session checked with `pgrep -fl -i shepherd`, found nothing, and told Adam
# "Shepherd isn't running" -- while he was looking at its question ON the card. There is no
# process called Shepherd: it is Lua running inside Hammerspoon, and the only true signal is
# the panel's heartbeat. Nothing documented how to ask, so the session guessed.
# It answers WITHOUT a Claude session id too: a session that can't run the panel's other
# commands must still be able to find out why.
alive
(cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$F" alive > "$TMP/al.out" 2>&1; echo $? > "$TMP/al.rc")
assert_eq "alive: a fresh heartbeat exits 0" "0" "$(cat "$TMP/al.rc")"
case "$(cat "$TMP/al.out")" in *"is running"*) got=yes ;; *) got=no ;; esac
assert_eq "alive: ...and says so in words" "yes" "$got"
case "$(cat "$TMP/al.out")" in *Hammerspoon*) got=yes ;; *) got=no ;; esac
assert_eq "alive: ...naming what actually hosts it, so pgrep is never the next idea" "yes" "$got"

# A heartbeat older than the window reads as down -- and says what to do about it.
printf '%s' "$(( $(date +%s) - 600 ))" > "$CC_STATUS_DIR/.panel-alive"
(cd "$REPO" && bash "$F" alive > "$TMP/al2.out" 2>&1; echo $? > "$TMP/al2.rc")
assert_eq "alive: a stale heartbeat exits 6, like the other commands" "6" "$(cat "$TMP/al2.rc")"
case "$(cat "$TMP/al2.out")" in *"isn't running"*) got=yes ;; *) got=no ;; esac
assert_eq "alive: ...and says that plainly" "yes" "$got"
case "$(cat "$TMP/al2.out")" in *600*|*"10m"*|*"10 m"*) got=yes ;; *) got=no ;; esac
assert_eq "alive: ...with how stale the heartbeat is, not just a verdict" "yes" "$got"

# No heartbeat file at all (Shepherd never started on this machine) is down, not a crash.
rm -f "$CC_STATUS_DIR/.panel-alive"
(cd "$REPO" && bash "$F" alive > "$TMP/al3.out" 2>&1; echo $? > "$TMP/al3.rc")
assert_eq "alive: no heartbeat at all exits 6" "6" "$(cat "$TMP/al3.rc")"
case "$(cat "$TMP/al3.out")" in *"isn't running"*|*"never"*) got=yes ;; *) got=no ;; esac
assert_eq "alive: ...and still explains itself" "yes" "$got"
# A garbled heartbeat (a torn write) is down, never a pass or a crash.
printf 'not-a-number' > "$CC_STATUS_DIR/.panel-alive"
(cd "$REPO" && bash "$F" alive > "$TMP/al4.out" 2>&1; echo $? > "$TMP/al4.rc")
assert_eq "alive: a garbled heartbeat exits 6" "6" "$(cat "$TMP/al4.rc")"
alive

# ---- `wait`: the driver hears what its units do from one stream (2026-09-29) ----
# Build program unit 23. The driver stitched idle notices, unit messages and status polls
# together to learn what a unit had done. Shepherd now appends each unit's events to
# <id>.events.jsonl, numbered; `wait` prints the ones after --after and exits, so the driver runs
# it in the background and is woken by it. The Shepherd side is played here by writing that file.
WB="bwait1"
jq -n --arg repo "$REPOP" '{v:1, id:"bwait1", nonce:"n-w", driver:{session_id:"drv", pid:"4242", name:"repo-drv"},
  repo:$repo, commonDir:($repo + "/.git"), title:"Relay", mergeWhenGreen:true, at:1, phase:"approved",
  units:[{type:"feat", slug:"alpha", task:"t", branch:"feat/alpha"}, {type:"fix", slug:"beta", task:"t", branch:"fix/beta"}]}' > "$FD/$WB.json"
EV="$FD/$WB.events.jsonl"
ev() { # <seq> <unit> <event> <text>
  jq -nc --argjson s "$1" --arg u "$2" --arg e "$3" --arg t "$4" \
    '{v:1, seq:$s, at:1, batch:"bwait1", unit:$u, event:$e, key:($e + ":" + ($s | tostring)), session:"repo-a1", text:$t}' >> "$EV"
}
alive
(cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$F" wait --batch "$WB" > "$TMP/w0.out" 2>&1; echo $? > "$TMP/w0.rc")
assert_eq "wait: outside a Claude Code session -> refused" "2" "$(cat "$TMP/w0.rc")"
fleet other w1 wait --batch "$WB" --wait-max 1
assert_eq "wait: only the driving session may wait on its units" "2" "$(cat "$TMP/w1.rc")"
fleet drv w2 wait --batch "$WB" --after x
assert_eq "wait: --after takes a number" "2" "$(cat "$TMP/w2.rc")"
fleet drv w3 wait --batch nosuch --wait-max 1
assert_eq "wait: an unknown batch is refused" "2" "$(cat "$TMP/w3.rc")"

fleet drv w4 wait --batch "$WB" --wait-max 1
assert_eq "wait: nothing relayed yet, wait-max runs out -> exit 4" "4" "$(cat "$TMP/w4.rc")"

ev 1 alpha tab_opened "its tab is open: session repo-a1"
ev 2 alpha turn_finished "finished its turn"
ev 3 beta asked "Keep the old name?"
fleet drv w5 wait --batch "$WB"
assert_eq "wait: events waiting -> exit 0 at once" "0" "$(cat "$TMP/w5.rc")"
assert_eq "wait: ...one line per event, numbered, with its unit and event" "3" \
  "$(grep -c -E '^#[0-9]+ (alpha|beta) [a-z_]+: ' "$TMP/w5.out")"
grep -q '^#3 beta asked: Keep the old name?$' "$TMP/w5.out" && got=yes || got=no
assert_eq "wait: ...the event's text as Shepherd wrote it" "yes" "$got"
grep -q -- "--after 3" "$TMP/w5.out" && got=yes || got=no
assert_eq "wait: ...and how to wait for the next ones (--after the last number)" "yes" "$got"

fleet drv w6 wait --batch "$WB" --after 2
assert_eq "wait: --after N prints only the events after N" "#3" "$(grep -o -E '^#[0-9]+' "$TMP/w6.out" | tr '\n' ' ' | sed 's/ $//')"

fleet drv w7 wait --batch "$WB" --after 3 --wait-max 1
assert_eq "wait: none after N -> waits, and wait-max runs out -> exit 4" "4" "$(cat "$TMP/w7.rc")"

fleet drv w8 wait --batch "$WB" --after 3 & bg=$!
sleep 0.4
[ -e "$TMP/w8.rc" ] && got=exited || got=waiting
assert_eq "wait: in the background it waits for the next event" "waiting" "$got"
ev 4 alpha merge_requested "asked to merge feat/alpha at abc1234"
wait $bg
assert_eq "wait: ...and wakes the driver when one lands (exit 0)" "0" "$(cat "$TMP/w8.rc")"
assert_eq "wait: ...printing just that one" "#4" "$(grep -o -E '^#[0-9]+' "$TMP/w8.out" | tr '\n' ' ' | sed 's/ $//')"

printf '{"v":1,"seq":5,"unit":"al' >> "$EV"
fleet drv w9 wait --batch "$WB" --after 4 --wait-max 1
assert_eq "wait: a torn last line (Shepherd mid-write) is not an event yet" "4" "$(cat "$TMP/w9.rc")"
printf '\n' >> "$EV"

printf '%s' "$(( $(date +%s) - 600 ))" > "$CC_STATUS_DIR/.panel-alive"
fleet drv w10 wait --batch "$WB" --after 4
assert_eq "wait: Shepherd stopped (stale heartbeat) -> exit 6" "6" "$(cat "$TMP/w10.rc")"
fleet drv w11 wait --batch "$WB" --after 3
assert_eq "wait: ...but events already relayed are still printed first (exit 0)" "0" "$(cat "$TMP/w11.rc")"
alive

ev 6 alpha merged "merged into main"
: > "$FD/$WB.stop"
fleet drv w12 wait --batch "$WB" --after 4
assert_eq "wait: the batch stopped with events still unread -> they come first (exit 0)" "0" "$(cat "$TMP/w12.rc")"
grep -q '^#6 alpha merged' "$TMP/w12.out" && got=yes || got=no
assert_eq "wait: ...the last unit's merge included" "yes" "$got"
fleet drv w13 wait --batch "$WB" --after 6
assert_eq "wait: the batch stopped and nothing left -> exit 5" "5" "$(cat "$TMP/w13.rc")"
rm -f "$FD/$WB.stop"
update_phase() { jq --arg p "$1" '.phase = $p' "$FD/$WB.json" > "$FD/$WB.json.tmp" && mv "$FD/$WB.json.tmp" "$FD/$WB.json"; }
update_phase stopped
fleet drv w14 wait --batch "$WB" --after 6
assert_eq "wait: cc-fleet.sh stop's own phase counts as stopped too -> exit 5" "5" "$(cat "$TMP/w14.rc")"
update_phase approved
# 2026-09-29: pinned with the session id set -- Shepherd's merge gate runs the suite with none, and
# a bare `bash "$F"` there is refused before the usage line (green in a Claude tab, red in the gate).
case "$(CLAUDE_CODE_SESSION_ID=drv bash "$F" 2>&1)" in *"wait --batch"*) got=yes ;; *) got=no ;; esac
assert_eq "wait: the usage line names it" "yes" "$got"

# ---- a stopped batch's files, events included, are pruned a week after its stop (2026-09-29) ----
# The events file is one more file per batch; nothing ever removed a batch's files. cc-fleet.sh
# prunes the batches whose stop marker is over a week old when it proposes a new one (Shepherd's
# FX.removeBatch does the same in its tick) -- every file of the batch, and no other batch's.
OLD_TS="$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)"
for f in bold1.json bold1.state.json bold1.events.jsonl bold1.tab-alpha.answer bold1.stop \
         bold12.json bold12.events.jsonl brecent.json brecent.events.jsonl brecent.stop; do
  printf '{}' > "$FD/$f"
done
touch -t "$OLD_TS" "$FD/bold1.stop"
batch '{"title":"Later","units":[{"type":"docs","slug":"prune-probe","task":"t"}]}'
fleet drv pr propose --file "$TMP/batch.json" --wait-max 1
assert_eq "prune: a proposal still goes out (exit 4 at wait-max)" "4" "$(cat "$TMP/pr.rc")"
left="$(cd "$FD" && ls bold1.* 2>/dev/null | tr '\n' ' ')"
assert_eq "prune: every file of a batch stopped over a week ago is gone, its events too" "" "$left"
assert_eq "prune: ...never another batch's that shares its prefix" "bold12.events.jsonl bold12.json" \
  "$(cd "$FD" && ls bold12.* | tr '\n' ' ' | sed 's/ $//')"
assert_eq "prune: ...nor a batch stopped since" "brecent.events.jsonl brecent.json brecent.stop" \
  "$(cd "$FD" && ls brecent.* | tr '\n' ' ' | sed 's/ $//')"
# the same file set is cc-lib.sh's cc_fleet_remove_batch, the bash twin of FX.removeBatch
( export CC_FLEET_DIR="$FD"; . "$ROOT/cc-lib.sh"; cc_fleet_remove_batch brecent; cc_fleet_remove_batch '../x'; cc_fleet_remove_batch '' )
assert_eq "cc_fleet_remove_batch: removes the batch's files" "" "$(cd "$FD" && ls brecent.* 2>/dev/null | tr '\n' ' ')"
assert_eq "cc_fleet_remove_batch: ...a bad id removes nothing" "bold12.events.jsonl bold12.json" \
  "$(cd "$FD" && ls bold12.* | tr '\n' ' ' | sed 's/ $//')"

finish
