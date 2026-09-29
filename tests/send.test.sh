#!/usr/bin/env bash
# send.test.sh - cc-send.sh, the CLI half (2026-09-29, build program unit 30).
# `cc-send.sh <project|session> "prompt" [--wait]` leaves a request in ~/.claude/cc-send/ for
# Shepherd, which picks the session and leaves the prompt in its mailbox (tests/send.test.lua), and
# answers with where it went. With --wait the CLI follows that session's transcript from the moment
# of delivery until the turn ends and prints the assistant's final text: the reply alone on stdout,
# everything else on stderr. Shepherd is faked here by a background loop that takes the request and
# writes the answer; the transcripts are the literal fixtures in tests/fixtures/send/.
# Side-effect-free: every dir lives under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
BG=""
# the background fakes and feeders; a leftover fake would take the next test's request
stop_bg() { local p; for p in $BG; do kill "$p" 2>/dev/null; done; BG=""; }
bg_started() { BG="$BG $1"; disown "$1" 2>/dev/null; }
trap 'stop_bg; rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_SEND_DIR="$TMP/cc-send"
export CC_SEND_POLL=0.1
export CC_SEND_ANSWER_WAIT=5
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
mkdir -p "$CC_STATUS_DIR"
S="$ROOT/cc-send.sh"
FXD="$ROOT/tests/fixtures/send"
MARK="cc-send #1790000000-4242"

alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }
dead() { rm -f "$CC_STATUS_DIR/.panel-alive"; }
# run cc-send.sh: stdout -> $OUT, stderr -> $ERR, exit code -> $CODE
send() { bash "$S" "$@" > "$TMP/out" 2> "$TMP/err"; CODE=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"; }
requests() { find "$CC_SEND_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }

# fake_shepherd <jq object>: take the first request that shows up (claimed by rename, as Shepherd
# does), keep a copy in $TMP/req.json and answer it: {nonce} + the object, with $tr / $off / $mark
# bound to FAKE_TRANSCRIPT / FAKE_OFFSET / MARK.
fake_shepherd() {
  stop_bg
  rm -f "$TMP/req.json"
  (
    for _ in $(seq 1 100); do
      for f in "$CC_SEND_DIR"/*.json; do
        [ -f "$f" ] || continue
        mv "$f" "$f.claim.shepherd" 2>/dev/null || continue
        cp "$f.claim.shepherd" "$TMP/req.json"
        base="${f%.json}"
        jq -c --arg tr "${FAKE_TRANSCRIPT:-}" --argjson off "${FAKE_OFFSET:-0}" --arg mark "$MARK" \
          "{nonce: .nonce} + ($1)" "$f.claim.shepherd" > "$base.answer.tmp" && mv "$base.answer.tmp" "$base.answer"
        rm -f "$f.claim.shepherd"
        exit 0
      done
      sleep 0.1
    done
  ) &
  bg_started $!
}
# feed <fixture> <transcript>: append the fixture's lines to the transcript, one at a time
feed() {
  ( sleep 0.3; while IFS= read -r line; do printf '%s\n' "$line" >> "$2"; sleep 0.05; done < "$1" ) &
  bg_started $!
}
# a fresh transcript holding before.jsonl; FAKE_TRANSCRIPT/FAKE_OFFSET point the answer at it
fresh_transcript() {
  FAKE_TRANSCRIPT="$TMP/transcript-$1.jsonl"
  cp "$FXD/before.jsonl" "$FAKE_TRANSCRIPT"
  FAKE_OFFSET="$(wc -c < "$FAKE_TRANSCRIPT" | tr -d ' ')"
}
OK_TURN_END='{ok: true, key: "sess-1", name: "worker-7", project: "parser", route: "turn-end", transcript: $tr, offset: $off, marker: $mark}'

# ---- arguments: refused before anything is written ----
alive
send
assert_eq "no arguments: exit 2" "2" "$CODE"
assert_eq "...with the usage on stderr" "yes" "$(has "$ERR" "usage: cc-send.sh")"
assert_eq "...and nothing on stdout" "" "$OUT"
send alpha
assert_eq "a target without a prompt: exit 2" "2" "$CODE"
send alpha "hi" --bogus
assert_eq "an unknown option: exit 2" "2" "$CODE"
send alpha "hi" --wait --timeout soon
assert_eq "--timeout that isn't whole seconds: exit 2" "2" "$CODE"
send alpha "hi" extra
assert_eq "a third argument (an unquoted prompt): exit 2" "2" "$CODE"
send alpha "   "
assert_eq "an empty prompt: exit 2" "2" "$CODE"
send alpha "/clear"
assert_eq "a slash command: exit 2" "2" "$CODE"
assert_eq "...saying why" "yes" "$(has "$ERR" "slash command")"
send alpha "[shepherd]  /compact"
assert_eq "...marked [shepherd] or not" "2" "$CODE"
send alpha "$(printf 'x%.0s' $(seq 1 3501))"
assert_eq "a prompt over 3500 bytes: exit 2" "2" "$CODE"
send "$TMP/no/such/folder" "hi"
assert_eq "a folder that doesn't exist: exit 2" "2" "$CODE"
assert_eq "...and none of those wrote a request" "0" "$(requests)"
send --help
assert_eq "--help: exit 0" "0" "$CODE"
assert_eq "...the usage on stdout (asked for)" "yes" "$(has "$OUT" "usage: cc-send.sh")"

# ---- Shepherd not there, or not taking it ----
dead
send alpha "hi"
assert_eq "Shepherd not running: exit 6" "6" "$CODE"
assert_eq "...saying so on stderr" "yes" "$(has "$ERR" "Shepherd isn't running")"
assert_eq "...leaving no request behind" "0" "$(requests)"
alive
CC_SEND_ANSWER_WAIT=1 send alpha "hi"
assert_eq "Shepherd up but never takes the request: exit 6" "6" "$CODE"
assert_eq "...which is withdrawn, so it can't be delivered later" "0" "$(requests)"
assert_eq "...and says nothing was delivered" "yes" "$(has "$ERR" "nothing was delivered")"

# ---- delivered, no --wait ----
fake_shepherd "$OK_TURN_END"
send alpha "Summarise what you did."
assert_eq "delivered: exit 0" "0" "$CODE"
assert_eq "...nothing on stdout without --wait" "" "$OUT"
assert_eq "...stderr says who got it and how it arrives" "yes" "$(has "$ERR" "worker-7")"
assert_eq "...(a busy session: at its turn end)" "yes" "$(has "$ERR" "turn ends")"
assert_json "the request names the target" "$TMP/req.json" '.target' "alpha"
assert_json "...carries the prompt as given" "$TMP/req.json" '.text' "Summarise what you did."
assert_json "...no reply awaited" "$TMP/req.json" '.wait' "false"
assert_json "...from a plain shell: no caller key" "$TMP/req.json" '.from.key // "none"' "none"
assert_eq "...in a file named for a plain shell" "yes" \
  "$(jq -r '.id' "$TMP/req.json" | grep -Eq '^[0-9]+-[0-9]+$' && echo yes)"

fake_shepherd '{ok: true, key: "k2", name: "tabbed", route: "waiting"}'
CLAUDE_CODE_SESSION_ID="caller-uuid" CLAUDE_PID=4242 send tabbed "Check in."
assert_eq "from a Claude session: delivered" "0" "$CODE"
assert_json "...the request carries the caller's key (never deliver to itself)" "$TMP/req.json" '.from.key' "caller-uuid"
assert_json "...and its pid (a /clear keeps the process)" "$TMP/req.json" '.from.pid' "4242"
assert_eq "...a message that can't be typed yet is said plainly" "yes" "$(has "$ERR" "waits in its mailbox")"

REPO="$TMP/repo"
git init -q "$REPO" && mkdir -p "$REPO/src"
fake_shepherd '{ok: true, key: "k3", name: "repo", route: "type"}'
send "$REPO/src" "By folder."
assert_json "a folder inside a repo is sent as the repo's root" "$TMP/req.json" '.path' "$(git -C "$REPO" rev-parse --show-toplevel)"
assert_eq "...an idle session: typed once it's ready" "yes" "$(has "$ERR" "types")"

# ---- refused by Shepherd ----
fake_shepherd '{ok: false, code: "ambiguous", reason: "twin names 2 sessions", choices: ["t-one (twin) in one", "t-two (twin) in two"]}'
send twin "hi"
assert_eq "an ambiguous target: exit 3" "3" "$CODE"
assert_eq "...listing the choices on stderr" "yes" "$(has "$ERR" "t-two (twin) in two")"
assert_eq "...nothing on stdout" "" "$OUT"
fake_shepherd '{ok: false, code: "none", reason: "no session or project is called nope"}'
send nope "hi"
assert_eq "no such target: exit 3" "3" "$CODE"
fake_shepherd '{ok: false, code: "refused", reason: "slash command"}'
send alpha "hi"
assert_eq "a request Shepherd refuses as bad: exit 2" "2" "$CODE"

# ---- --wait: the reply, from the transcript ----
fresh_transcript turn
fake_shepherd "$OK_TURN_END"
feed "$FXD/turn-end.jsonl" "$FAKE_TRANSCRIPT"
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait, handed over at the turn end: exit 0" "0" "$CODE"
assert_eq "...stdout is the final reply, both of its text blocks, and nothing else" \
  "There are 412 tests, all green.

Nothing failed." "$OUT"
assert_eq "...progress went to stderr" "yes" "$(has "$ERR" "Waiting for worker-7")"
assert_json "...and the request said a reply is awaited" "$TMP/req.json" '.wait' "true"

fresh_transcript queued
fake_shepherd "$OK_TURN_END"
feed "$FXD/queued-prompt.jsonl" "$FAKE_TRANSCRIPT"
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait, a prompt queued behind a running turn: the running turn's end isn't the reply" \
  "0|There are 412 tests." "$CODE|$OUT"

fresh_transcript start
fake_shepherd "$OK_TURN_END"
feed "$FXD/session-start.jsonl" "$FAKE_TRANSCRIPT"
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait, handed over at the session's start: its next turn's reply" "0|There are 412 tests." "$CODE|$OUT"

fresh_transcript interrupted
fake_shepherd "$OK_TURN_END"
feed "$FXD/interrupted.jsonl" "$FAKE_TRANSCRIPT"
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait, the turn interrupted: exit 5, nothing on stdout" "5|" "$CODE|$OUT"
assert_eq "...saying so" "yes" "$(has "$ERR" "interrupted")"

fresh_transcript apierror
fake_shepherd "$OK_TURN_END"
feed "$FXD/api-error.jsonl" "$FAKE_TRANSCRIPT"
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait, the turn died on an API error: exit 5, nothing on stdout" "5|" "$CODE|$OUT"
assert_eq "...quoting the error" "yes" "$(has "$ERR" "529 Overloaded")"

fresh_transcript quiet
fake_shepherd "$OK_TURN_END"
send worker-7 "How many tests are there?" --wait --timeout 1
assert_eq "--wait with no turn end in time: exit 4, nothing on stdout" "4|" "$CODE|$OUT"
assert_eq "...saying it ran out" "yes" "$(has "$ERR" "1s")"

fake_shepherd '{ok: true, key: "k5", name: "blind", route: "turn-end", marker: $mark}'
send blind "hi" --wait --timeout 5
assert_eq "--wait when Shepherd knows no transcript: exit 5 (delivered, but nothing to follow)" "5" "$CODE"

# The turn's end is written in two pieces: the CLI must not read the first as a whole record.
fresh_transcript torn
fake_shepherd "$OK_TURN_END"
head -n 10 "$FXD/turn-end.jsonl" > "$TMP/torn-head.jsonl"
last="$(sed -n 11p "$FXD/turn-end.jsonl")"
(
  sleep 0.3; cat "$TMP/torn-head.jsonl" >> "$FAKE_TRANSCRIPT"
  printf '%s' "${last:0:60}" >> "$FAKE_TRANSCRIPT"; sleep 0.8
  printf '%s\n' "${last:60}" >> "$FAKE_TRANSCRIPT"
) &
bg_started $!
send worker-7 "How many tests are there?" --wait --timeout 20
assert_eq "--wait reads only whole lines: a record half-written when polled is read once it's whole" \
  "0|There are 412 tests, all green.

Nothing failed." "$CODE|$OUT"

# ---- cleanup: the removers (cc_remove; FX.removeStatus is in tests/send.test.lua) ----
stop_bg
mkdir -p "$CC_SEND_DIR"
now="$(date +%s)"
: > "$CC_SEND_DIR/sess-a.$now-1.json"; : > "$CC_SEND_DIR/sess-a.$now-1.answer"
: > "$CC_SEND_DIR/sess-b.$now-2.json"
: > "$CC_SEND_DIR/shell.$((now - 3600))-3.answer"   # its name says it's an hour old
( . "$ROOT/cc-lib.sh"; cc_remove sess-a )
assert_absent "cc_remove drops the requests the session made" "$CC_SEND_DIR/sess-a.$now-1.json"
assert_absent "...and their answers" "$CC_SEND_DIR/sess-a.$now-1.answer"
assert_eq "...leaves another session's alone" "yes" "$([ -e "$CC_SEND_DIR/sess-b.$now-2.json" ] && echo yes)"
assert_absent "...and drops a stale file anyone left" "$CC_SEND_DIR/shell.$((now - 3600))-3.answer"
( . "$ROOT/cc-lib.sh"; cc_remove ".."; cc_remove "." ; cc_remove "" ) 2>/dev/null
assert_eq "...never reaching outside the folder" "yes" "$([ -d "$CC_STATUS_DIR" ] && [ -e "$CC_SEND_DIR/sess-b.$now-2.json" ] && echo yes)"

finish
