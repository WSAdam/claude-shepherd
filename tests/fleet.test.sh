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

# ---- blockedBy, covers and packet (2026-09-29, build program unit 24) ----
# A unit may name the units it waits for: its tab doesn't open and its merge isn't ready until
# they have merged. The proposal is refused when a blocker isn't one of its units or they go in
# a circle; covers (issue ids) and packet (a task packet id) ride along; an old batch file
# without any of the three still works.
u3() { # <beta's extra fields> <gamma's extra fields> -> a three-unit batch
  printf '{"title":"Order","mergeWhenGreen":true,"units":[{"type":"feat","slug":"one","task":"t"},{"type":"feat","slug":"two","task":"t"%s},{"type":"fix","slug":"three","task":"t"%s}]}' "$1" "$2"
}
i=0
for bad in "$(u3 ',"blockedBy":["zeta"]' '')" \
           "$(u3 ',"blockedBy":["two"]' '')" \
           "$(u3 ',"blockedBy":["three"]' ',"blockedBy":["two"]')" \
           "$(u3 ',"blockedBy":["three"]' ',"blockedBy":["one","two"]')" \
           "$(u3 ',"blockedBy":"one"' '')" \
           "$(u3 ',"covers":"BUG-1"' '')" \
           "$(u3 ',"covers":["bad id; rm"]' '')" \
           "$(u3 ',"packet":"p1 && curl x"' '')"; do
  i=$((i + 1))
  batch "$bad"; fleet drv ob$i propose --file "$TMP/batch.json" --wait-max 1   # (a let-through waits: exit 4)
  assert_eq "blockedBy: a bad order/covers/packet is refused ($i): $(printf '%s' "$bad" | cut -c75-150)" "2" "$(cat "$TMP/ob$i.rc")"
done
grep -q "zeta" "$TMP/ob1.out" && got=yes || got=no
assert_eq "blockedBy: an unknown blocker is named" "yes" "$got"
grep -q "itself" "$TMP/ob2.out" && got=yes || got=no
assert_eq "blockedBy: a unit waiting for itself is told so" "yes" "$got"
grep -q "circle" "$TMP/ob3.out" && grep -q "two" "$TMP/ob3.out" && grep -q "three" "$TMP/ob3.out" && got=yes || got=no
assert_eq "blockedBy: a cycle is refused, naming its units" "yes" "$got"
grep -q "circle" "$TMP/ob4.out" && ! grep -q "circle: one" "$TMP/ob4.out" && got=yes || got=no
assert_eq "blockedBy: ...but not the unit the cycle only waits on" "yes" "$got"
[ -z "$(ls "$FD"/b*.json 2>/dev/null | xargs -n1 jq -r 'select(.title == "Order") | .id' 2>/dev/null)" ] && got=none || got=some
assert_eq "blockedBy: no refused order left a proposal behind" "none" "$got"

batch "$(u3 ',"blockedBy":["one"],"covers":["BUG-3","REQ-001"],"packet":"p1"' ',"blockedBy":["two","two"]')"
fleet drv po propose --file "$TMP/batch.json" & bg=$!
for i in $(seq 1 60); do BO="$(newest_batch)"; [ -n "$BO" ] && [ "$(jq -r .title "$BO")" = "Order" ] && break; sleep 0.1; done
assert_json "projection: a unit keeps its blockers" "$BO" '.units[1].blockedBy | join(",")' "one"
assert_json "projection: ...deduped" "$BO" '.units[2].blockedBy | join(",")' "two"
assert_json "projection: ...what it covers and its packet" "$BO" '(.units[1].covers | join(",")) + " " + .units[1].packet' "BUG-3,REQ-001 p1"
assert_json "projection: a unit without them has none of the three keys" "$BO" '.units[0] | (has("blockedBy") or has("covers") or has("packet"))' false
decide "$BO" approve true
wait $bg
assert_eq "approved: exit 0" "0" "$(cat "$TMP/po.rc")"
grep -q -- "--unit two .*waits for one" "$TMP/po.out" && got=yes || got=no
assert_eq "approved: the tab list says which units wait, and for what" "yes" "$got"
IO="$(jq -r .id "$BO")"

fleet drv tw tab --batch "$IO" --unit two & bg=$!
wait_for "$FD/$IO.tab-two.json"
jq -n --arg n "$(jq -r .nonce "$FD/$IO.tab-two.json")" \
  '{nonce:$n, ok:false, reason:"waits for one to merge first", waits:["one"]}' > "$FD/$IO.tab-two.answer"
wait $bg
assert_eq "tab: a unit that waits for its blockers exits 7, not 2 (ask again later)" "7" "$(cat "$TMP/tw.rc")"
grep -q "waits for one" "$TMP/tw.out" && got=yes || got=no
assert_eq "tab: ...saying what it waits for" "yes" "$got"
grep -q "✅" "$TMP/tw.out" && got=opened || got=not
assert_eq "tab: ...and nothing was opened" "not" "$got"

jq -n '{grant: {approved: true, grantMerge: true}, units: {one: {session: {id: "s1", name: "r-1"}, result: "blocked"}}}' > "$FD/$IO.state.json"
fleet drv so status --batch "$IO"
assert_eq "status: every unit behind a blocked one is blocked too, so the batch can finish" "one,two,three" \
  "$(jq -r '.outcomes.blocked | join(",")' "$TMP/so.out")"
assert_eq "status: ...saying why" "blocked by a blocked unit (one)" "$(jq -r '.units[2].note' "$TMP/so.out")"
jq -n '{grant: {approved: true, grantMerge: true}, units: {one: {session: {id: "s1", name: "r-1"}}}}' > "$FD/$IO.state.json"
fleet drv so2 status --batch "$IO"
assert_eq "status: while a blocker works, the units behind it wait (unopened, not blocked)" "two,three" \
  "$(jq -r '.outcomes.unopened | join(",")' "$TMP/so2.out")"
assert_eq "status: ...and say for what" "waits for one" "$(jq -r '.units[1].note' "$TMP/so2.out")"
assert_eq "status: ...a unit with nothing to wait for has no note" "null" "$(jq -r '.units[0].note' "$TMP/so2.out")"
fleet drv sto stop --batch "$IO"

# ---- coverage index (2026-09-29, build program unit 25) ----
# A batch built from an issue list carries it (issues[{id,title}]), with triage[{id,as,note}] for
# what it won't build. propose refuses a covers or triage id that isn't in the list, and a batch
# that leaves an issue uncovered: it prints the uncovered ids so the driver fixes the file before
# Adam ever sees it. A covered one goes out with its issues and triage in the proposal.
ISS='"issues":[{"id":"BUG-1","title":"Paste drops the last line"},{"id":"BUG-2","title":"Toast covers Approve"},{"id":"REQ-3","title":"Export the ledger as CSV"}]'
cv() { # <top-level extra> <unit one extra> <unit two extra> -> a two-unit batch with the issue list
  printf '{"title":"Sweep","mergeWhenGreen":true%s,"units":[{"type":"fix","slug":"paste","task":"t"%s},{"type":"fix","slug":"toast","task":"t"%s}]}' "$1" "$2" "$3"
}
i=0
for bad in "$(cv ",$ISS" ',"covers":["BUG-1","BUG-9"]' ',"covers":["BUG-2","REQ-3"]')" \
           "$(cv ",$ISS"',"triage":[{"id":"BUG-9","as":"dup","note":"n"}]' ',"covers":["BUG-1"]' ',"covers":["BUG-2","REQ-3"]')" \
           "$(cv ',"triage":[{"id":"BUG-1","as":"dup","note":"n"}]' '' '')" \
           "$(cv ",$ISS"',"triage":[{"id":"REQ-3","as":"maybe","note":"n"}]' ',"covers":["BUG-1"]' ',"covers":["BUG-2"]')" \
           "$(cv ",$ISS"',"triage":[{"id":"REQ-3","as":"later"}]' ',"covers":["BUG-1"]' ',"covers":["BUG-2"]')" \
           "$(cv ",$ISS"',"triage":[{"id":"REQ-3","as":"later","note":""}]' ',"covers":["BUG-1"]' ',"covers":["BUG-2"]')" \
           "$(cv ',"issues":[{"id":"BUG-1","title":"a"},{"id":"BUG-1","title":"b"}]' ',"covers":["BUG-1"]' '')" \
           "$(cv ',"issues":[{"id":"X; rm","title":"a"}]' '' '')" \
           "$(cv ',"issues":[{"id":"BUG-1"}]' ',"covers":["BUG-1"]' '')" \
           "$(cv ',"issues":{"id":"BUG-1","title":"a"}' '' '')" \
           "$(cv ',"issues":[]' '' '')"; do
  i=$((i + 1))
  batch "$bad"; fleet drv cb$i propose --file "$TMP/batch.json" --wait-max 1   # (a let-through waits: exit 4)
  assert_eq "coverage: a bad issue list / covers / triage is refused ($i): $(printf '%s' "$bad" | cut -c40-150)" "2" "$(cat "$TMP/cb$i.rc")"
done
grep -q "BUG-9" "$TMP/cb1.out" && grep -q "paste" "$TMP/cb1.out" && got=yes || got=no
assert_eq "coverage: a unit covering an id that isn't in the list is named, with the id" "yes" "$got"
grep -q "triage names 'BUG-9'" "$TMP/cb2.out" && got=yes || got=no
assert_eq "coverage: a triage id that isn't in the list is named" "yes" "$got"

# REQ-3 is neither covered nor triaged: refused, and every uncovered id is printed with its title
batch "$(cv ",$ISS" ',"covers":["BUG-1"]' '')"
fleet drv cu propose --file "$TMP/batch.json" --wait-max 1
assert_eq "coverage: a batch that leaves issues uncovered is refused before Adam sees it" "2" "$(cat "$TMP/cu.rc")"
grep -q "2 issues" "$TMP/cu.out" && grep -q "BUG-2.*Toast covers Approve" "$TMP/cu.out" && grep -q "REQ-3.*Export the ledger as CSV" "$TMP/cu.out" && got=yes || got=no
assert_eq "coverage: ...printing each uncovered id and its title" "yes" "$got"
grep -q "BUG-1.*Paste" "$TMP/cu.out" && got=listed || got=not
assert_eq "coverage: ...never a covered one" "not" "$got"
grep -q "triage" "$TMP/cu.out" && grep -q "covers" "$TMP/cu.out" && got=yes || got=no
assert_eq "coverage: ...and saying how to fix it (covers, or triage)" "yes" "$got"
[ -z "$(ls "$FD"/b*.json 2>/dev/null | xargs -n1 jq -r 'select(.title == "Sweep") | .id' 2>/dev/null)" ] && got=none || got=some
assert_eq "coverage: no refused batch left a proposal behind" "none" "$got"

# every issue covered or triaged: it goes out, carrying the list and the triage
batch "$(cv ",$ISS"',"triage":[{"id":"REQ-3","as":"later","note":"Needs Adam on the columns"}]' ',"covers":["BUG-1"]' ',"covers":["BUG-2","BUG-1"]')"
fleet drv cok propose --file "$TMP/batch.json" --wait-max 30 & bg=$!   # bounded: a red run must not hang
for i in $(seq 1 60); do BC="$(newest_batch)"; [ -n "$BC" ] && [ "$(jq -r .title "$BC")" = "Sweep" ] && break; sleep 0.1; done
assert_json "coverage: the proposal carries the issue list" "$BC" '[.issues[].id] | join(",")' "BUG-1,BUG-2,REQ-3"
assert_json "coverage: ...with titles" "$BC" '.issues[1].title' "Toast covers Approve"
assert_json "coverage: ...and the triage" "$BC" '.triage[0] | "\(.id) \(.as) \(.note)"' "REQ-3 later Needs Adam on the columns"
decide "$BC" approve true
wait $bg
assert_eq "coverage: a covered batch is approved as usual" "0" "$(cat "$TMP/cok.rc")"
grep -q "3 issues: 2 covered by units, 1 triaged" "$TMP/cok.out" && got=yes || got=no
assert_eq "coverage: ...and propose says what it covers" "yes" "$got"
fleet drv cst stop --batch "$(jq -r .id "$BC")"

# ---- tab: the wait outlasts Shepherd, and a late answer isn't lost (2026-09-30) ----
# 2026-09-30: `tab` gave up after 120s while Shepherd keeps opening a tab for up to 225s (135s for
# the tab, 90s for its session). The driver was told "didn't open the tab", Shepherd opened it
# anyway, and the retry was refused as "already has its tab" -- the driver never got the message
# to send the unit. The default wait is now above Shepherd's own limit (core.fleetTabMaxSeconds),
# and a retry prints the answer an earlier wait missed.
TAB_MAX="$(lua -e 'local c = dofile("'"$ROOT"'/cc-core.lua") io.write(tostring(c.fleetTabMaxSeconds()))' 2>/dev/null)"
TAB_DEFAULT="$(sed -n 's/^TAB_WAIT_MAX=\([0-9][0-9]*\)$/\1/p' "$F")"
[ -n "$TAB_MAX" ] && [ -n "$TAB_DEFAULT" ] && [ "$TAB_DEFAULT" -gt "$TAB_MAX" ] && got=yes || got="no: the script waits ${TAB_DEFAULT:-?}s, Shepherd up to ${TAB_MAX:-?}s"
assert_eq "tab: the default wait outlasts Shepherd's longest tab open" "yes" "$got"
grep -q 'local id="" slug="" waitmax="\$TAB_WAIT_MAX"' "$F" && got=yes || got=no
assert_eq "tab: ...and is what tab waits when --wait-max isn't given" "yes" "$got"

alive
batch '{"title":"Late","mergeWhenGreen":false,"units":[{"type":"feat","slug":"late","task":"Add late."},{"type":"feat","slug":"warned","task":"Add warned."}]}'
fleet drv pl propose --file "$TMP/batch.json" --wait-max 30 & bg=$!   # bounded: a red run must not hang
for i in $(seq 1 60); do BL="$(newest_batch)"; [ -n "$BL" ] && [ "$(jq -r .title "$BL")" = "Late" ] && break; sleep 0.1; done
decide "$BL" approve false
wait $bg
IDL="$(jq -r .id "$BL")"
fleet drv tl1 tab --batch "$IDL" --unit late --wait-max 1
assert_eq "tab: a wait that runs out is refused (exit 2)" "2" "$(cat "$TMP/tl1.rc")"
grep -q "run the same command again" "$TMP/tl1.out" && got=yes || got=no
assert_eq "tab: ...saying the tab may still open, and to run it again" "yes" "$got"
# Shepherd opens it after all: its answer (bound to the request that gave up) and its own record
WARN="/r/A's VS Code window runs tab bridge 0.4.0, which forgets a unit's tab at the first tab switch -- Developer: Reload Window there"
jq -n --arg w "$WARN" '{nonce:"the-request-that-gave-up", ok:true, name:"repo-l1", sessionId:"s-l1", message:"Start unit feat/late in its own worktree", warn:$w}' > "$FD/$IDL.tab-late.answer"
printf '{"grant":{"approved":true},"units":{"late":{"session":{"id":"s-other","name":"repo-x","pid":"8"}}}}' > "$FD/$IDL.state.json"
fleet drv tl0 tab --batch "$IDL" --unit late
assert_eq "tab: an answer for a session Shepherd didn't record as the unit's is never handed over" "2" "$(cat "$TMP/tl0.rc")"
[ -f "$FD/$IDL.tab-late.answer" ] && got=kept || got=gone
assert_eq "tab: ...and stays where it is" "kept" "$got"
printf '{"grant":{"approved":true},"units":{"late":{"session":{"id":"s-l1","name":"repo-l1","pid":"9"}}}}' > "$FD/$IDL.state.json"
fleet drv tl2 tab --batch "$IDL" --unit late
assert_eq "tab: a retry after the tab opened late gets the answer it missed (exit 0)" "0" "$(cat "$TMP/tl2.rc")"
grep -q "repo-l1" "$TMP/tl2.out" && grep -q "Start unit feat/late" "$TMP/tl2.out" && got=yes || got=no
assert_eq "tab: ...the session's name and the message to send it" "yes" "$got"
assert_absent "tab: ...and the answer is used up" "$FD/$IDL.tab-late.answer"
fleet drv tl3 tab --batch "$IDL" --unit late
assert_eq "tab: with no answer left, a unit that has its tab is refused as before" "2" "$(cat "$TMP/tl3.rc")"

# ---- tab: Shepherd's warning about an old tab bridge reaches the driver (2026-09-30) ----
# 2026-09-30: a window whose tab bridge is older than 0.6.0 forgets a unit's tag at the first tab
# switch, and a batch opened its tabs there without a word. Shepherd's answer now carries `warn`.
grep -q "⚠️ .*tab bridge 0.4.0.*Reload Window" "$TMP/tl2.out" && got=yes || got=no
assert_eq "tab: the late answer's warning is printed" "yes" "$got"
fleet drv tw1 tab --batch "$IDL" --unit warned & bg=$!
wait_for "$FD/$IDL.tab-warned.json"
jq -n --arg n "$(jq -r .nonce "$FD/$IDL.tab-warned.json")" --arg w "$WARN" \
  '{nonce:$n, ok:true, name:"repo-w1", sessionId:"s-w1", message:"Start unit feat/warned in its own worktree", warn:$w}' > "$FD/$IDL.tab-warned.answer"
wait $bg
assert_eq "tab: an answer that carries a warning still succeeds" "0" "$(cat "$TMP/tw1.rc")"
grep -q "⚠️ .*tab bridge 0.4.0.*Reload Window" "$TMP/tw1.out" && got=yes || got=no
assert_eq "tab: ...and prints the warning with the session's name" "yes" "$got"
[ "$(grep -c "⚠️" "$TMP/t2.out")" = "0" ] && got=none || got=some
assert_eq "tab: an answer with no warning prints none" "none" "$got"
fleet drv lst stop --batch "$IDL"

finish
