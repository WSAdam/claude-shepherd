#!/usr/bin/env bash
# send-cross.test.sh - cc-send.sh when a send crosses projects (2026-10-14, crossings unit 2, D-27).
# Adam: "projects should not be able to utilize having shepherd to talk to each other, that needs to
# be an approved translation between the two rather than something automatic" -- cc-send gets the same
# approval as tickets. When Shepherd answers that a send is HELD (it goes to another project's
# session), the CLI says so and, without --wait, exits 0: it goes out once Adam approves it. With
# --wait it waits for Adam's decision (~/.claude/cc-cross/<cid>.answer), then for the reply he passes
# on (<cid>.reply.answer) -- both bound to the request's nonce -- and prints only that. A Deny of either
# exits 7 with his note. The CLI never follows the other project's transcript itself: Shepherd does.
# Same-project sends are tests/send.test.sh's, unchanged. Shepherd is faked as there.
# Side-effect-free: every dir lives under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
BG=""
stop_bg() { local p; for p in $BG; do kill "$p" 2>/dev/null; done; BG=""; }
bg_started() { BG="$BG $1"; disown "$1" 2>/dev/null; }
trap 'stop_bg; rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_SEND_DIR="$TMP/cc-send"
export CC_CROSS_DIR="$TMP/cc-cross"
export CC_SEND_POLL=0.1
export CC_SEND_ANSWER_WAIT=5
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
mkdir -p "$CC_STATUS_DIR" "$CC_CROSS_DIR"
S="$ROOT/cc-send.sh"
date +%s > "$CC_STATUS_DIR/.panel-alive"

send() { bash "$S" "$@" > "$TMP/out" 2> "$TMP/err"; CODE=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }
# fake_shepherd <cid> [<jq for the delivered answer> <jq for the reply answer>]: take the request,
# answer it HELD with <cid>, then (when given) write Adam's decision and the reply he passed on into
# cc-cross, each bound to the request's nonce -- the way Shepherd does after his clicks.
fake_shepherd() {
  stop_bg
  rm -f "$TMP/req.json" "$CC_CROSS_DIR"/*
  (
    for _ in $(seq 1 100); do
      for f in "$CC_SEND_DIR"/*.json; do
        [ -f "$f" ] || continue
        mv "$f" "$f.claim.shepherd" 2>/dev/null || continue
        cp "$f.claim.shepherd" "$TMP/req.json"
        base="${f%.json}"
        jq -c --arg cid "$1" '{nonce: .nonce, ok: true, held: true, cid: $cid, project: "beta", name: "worker-7"}' \
          "$f.claim.shepherd" > "$base.answer.tmp" && mv "$base.answer.tmp" "$base.answer"
        rm -f "$f.claim.shepherd"
        if [ -n "${2:-}" ]; then
          sleep 0.4
          jq -c "{nonce: .nonce} + ($2)" "$TMP/req.json" > "$CC_CROSS_DIR/$1.answer.tmp" && mv "$CC_CROSS_DIR/$1.answer.tmp" "$CC_CROSS_DIR/$1.answer"
        fi
        if [ -n "${3:-}" ]; then
          sleep 0.4
          jq -c "{nonce: .nonce} + ($3)" "$TMP/req.json" > "$CC_CROSS_DIR/$1.reply.answer.tmp" \
            && mv "$CC_CROSS_DIR/$1.reply.answer.tmp" "$CC_CROSS_DIR/$1.reply.answer"
        fi
        exit 0
      done
      sleep 0.1
    done
  ) &
  bg_started $!
}
DELIVERED='{ok: true, phase: "delivered", key: "w1", name: "worker-7", project: "beta", route: "turn-end"}'

# ---- held, without --wait: told, exit 0 ----
fake_shepherd "f1.1792100000-1"
send beta "How many tests?"
assert_eq "a held send without --wait: exit 0" "0" "$CODE"
assert_eq "...nothing on stdout" "" "$OUT"
assert_eq "...stderr says Adam approves it first" "yes" "$(has "$ERR" "Held for Adam")"
assert_eq "...and not to route around it" "yes" "$(has "$ERR" "route around")"
assert_eq "the request says which process sent it (cli_pid), so Shepherd reads its ancestry" "yes" \
  "$(jq -r '.cli_pid // empty' "$TMP/req.json" | grep -qE '^[0-9]+$' && echo yes || echo no)"

# ---- held, --wait: Adam's decision, then the reply he passed on ----
fake_shepherd "f1.1792100000-2" "$DELIVERED" '{verdict: "approved", text: "412 pass.\n\n(edited by Adam)"}'
send beta "How many tests pass?" --wait --timeout 20
assert_eq "a held --wait send: exit 0 once Adam passes the reply on" "0" "$CODE"
assert_eq "...printing only that reply" "$(printf '412 pass.\n\n(edited by Adam)')" "$OUT"
assert_eq "...after saying it went out" "yes" "$(has "$ERR" "passed it on")"
assert_eq "...and taking both answers" "0" "$(find "$CC_CROSS_DIR" -name '*.answer*' | grep -c .)"

# ---- denied ----
fake_shepherd "f1.1792100000-3" '{ok: false, code: "denied", reason: "Adam didn'"'"'t pass it on: Ask beta yourself."}'
send beta "Tell beta to stop." --wait --timeout 20
assert_eq "a send Adam denies: exit 7" "7" "$CODE"
assert_eq "...with his note on stderr" "yes" "$(has "$ERR" "Ask beta yourself.")"
fake_shepherd "f1.1792100000-4" "$DELIVERED" '{verdict: "denied", why: "Not that number."}'
send beta "How many?" --wait --timeout 20
assert_eq "a reply Adam keeps back: exit 7" "7" "$CODE"
assert_eq "...with his note" "yes" "$(has "$ERR" "Not that number.")"
fake_shepherd "f1.1792100000-5" "$DELIVERED" '{verdict: "none", why: "its turn was interrupted"}'
send beta "How many?" --wait --timeout 20
assert_eq "no reply to pass on (an interrupt): exit 5" "5" "$CODE"

# ---- answers bound to the nonce; the wait runs out ----
fake_shepherd "f1.1792100000-6"
( sleep 0.5; printf '{"nonce":"someone-else","ok":true,"phase":"delivered"}' > "$CC_CROSS_DIR/f1.1792100000-6.answer" ) &
bg_started $!
send beta "How many?" --wait --timeout 2
assert_eq "an answer bound to another request is never taken, so the wait runs out: exit 4" "4" "$CODE"
assert_eq "...saying the reply reaches the mailbox once Adam passes it" "yes" "$(has "$ERR" "mailbox")"

# ---- the removers: an answer nobody took (the CLI gave up) goes after an hour ----
stop_bg
printf '{}' > "$CC_CROSS_DIR/f1.1792100000-9.reply.answer"
printf '{}' > "$CC_CROSS_DIR/f1.1792100000-10.answer"
touch -t 202001010000 "$CC_CROSS_DIR/f1.1792100000-9.reply.answer"
( . "$ROOT/cc-lib.sh"; cc_cross_prune )
assert_eq "an answer nobody took in an hour is pruned; a fresh one stays" "no yes" \
  "$([ -f "$CC_CROSS_DIR/f1.1792100000-9.reply.answer" ] && echo yes || echo no) $([ -f "$CC_CROSS_DIR/f1.1792100000-10.answer" ] && echo yes || echo no)"

finish
