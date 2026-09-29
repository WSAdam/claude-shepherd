#!/usr/bin/env bash
# mailbox.test.sh - Shepherd's session mailbox, the hook side (build program unit 11a, 2026-09-29).
# Shepherd leaves a session a message in ~/.claude/cc-inbox/<key>/ (FX.mailboxSend) instead of
# typing into its window. cc-status.sh hands it over at the session's next turn end -- the Stop
# hook blocks the stop with the message, so the session carries on with it -- or at its next start
# (the mailbox part of cc_session_context). Drives the REAL cc-status.sh over throwaway dirs.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_INBOX_DIR="$TMP/cc-inbox"
mkdir -p "$CC_STATUS_DIR" "$CC_INBOX_DIR"

CC="$ROOT/cc-status.sh"
CWD="/Users/x/Programming/mail-proj"
# stdout is what Claude Code reads from the hook; stderr is our log
evout() { printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$CC" "$1" 2>/dev/null; }
stop_json() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "$CWD" "${2:-false}"; }
# drop <key> <epoch> <seq> <name-nonce> <text> [body-nonce]: a message as FX.mailboxSend writes it
drop() {
  mkdir -p "$CC_INBOX_DIR/$1"
  jq -nc --arg n "${6:-$4}" --arg t "$5" --argjson at "$2" '{nonce:$n, text:$t, at:$at, from:"shepherd"}' \
    > "$CC_INBOX_DIR/$1/$(printf '%010d-%06d-%s' "$2" "$3" "$4").msg"
}
left() { ls -A "$CC_INBOX_DIR/$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
reason() { printf '%s' "$1" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null; }

# ---- the Stop hook hands the oldest message over (2026-09-29) ----
evout userpromptsubmit '{"session_id":"m1","cwd":"'"$CWD"'","prompt":"work on it"}' >/dev/null
drop m1 1790000100 2 bb22 "[shepherd] second message"
drop m1 1790000100 1 aa11 "[shepherd] The usage limit has reset: continue the task."
got="$(evout stop "$(stop_json m1)")"
assert_eq "a turn end with a message waiting blocks the stop" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"
assert_eq "...handing over the oldest message as the reason" \
  "[shepherd] The usage limit has reset: continue the task." "$(reason "$got")"
assert_eq "...printed once, as one JSON object" "1" "$(printf '%s\n' "$got" | grep -c .)"
assert_json "...and the session stays working (it carries on with the message)" "$CC_STATUS_DIR/m1.json" '.status' "working"
assert_eq "...the delivered message is gone, the next one waits, no claim file left" \
  "$(printf '%010d-%06d-%s.msg' 1790000100 2 bb22)" "$(left m1)"

# stop_hook_active: that stop IS the end of the turn a block kept going -- never block it again
got="$(evout stop "$(stop_json m1 true)")"
assert_eq "no block while stop_hook_active (never loop)" "" "$got"
assert_json "...the session is done" "$CC_STATUS_DIR/m1.json" '.status' "done"
assert_eq "...and the next message still waits" "$(printf '%010d-%06d-%s.msg' 1790000100 2 bb22)" "$(left m1)"

# the next turn end takes the next one; then there is nothing left to say
got="$(evout stop "$(stop_json m1)")"
assert_eq "the next turn end hands over the next message" "[shepherd] second message" "$(reason "$got")"
got="$(evout stop "$(stop_json m1)")"
assert_eq "an empty inbox prints nothing" "" "$got"
assert_json "...and the turn ends done" "$CC_STATUS_DIR/m1.json" '.status' "done"
assert_eq "...each message was handed over once" "" "$(left m1)"

# claimed once: two turn ends racing for one message (parallel subagents share a session id)
for i in 1 2 3 4 5; do
  drop race$i 1790000200 1 cc33 "[shepherd] race $i"
  evout stop "$(stop_json race$i)" > "$TMP/race$i.a" &
  evout stop "$(stop_json race$i)" > "$TMP/race$i.b" &
  wait
  n=0
  for f in "$TMP/race$i.a" "$TMP/race$i.b"; do [ "$(reason "$(cat "$f")")" = "[shepherd] race $i" ] && n=$((n + 1)); done
  assert_eq "two stops racing for one message: exactly one hands it over (round $i)" "1" "$n"
  assert_eq "...and it is gone, claim included (round $i)" "" "$(left race$i)"
done

# nonce-bound: a body whose nonce isn't its name's is left alone, never handed over
drop w1 1790000300 1 dd44 "[shepherd] forged" ee55
got="$(evout stop "$(stop_json w1)")"
assert_eq "a message whose nonce doesn't match its name is not handed over" "" "$got"
assert_eq "...it is left alone, under its own name" "$(printf '%010d-%06d-%s.msg' 1790000300 1 dd44)" "$(left w1)"
assert_eq "...untouched" "ee55" "$(jq -r '.nonce' "$CC_INBOX_DIR/w1/$(printf '%010d-%06d-%s.msg' 1790000300 1 dd44)")"
assert_json "...and the turn ends done" "$CC_STATUS_DIR/w1.json" '.status' "done"
drop w1 1790000301 1 ff66 "[shepherd] the genuine one"
got="$(evout stop "$(stop_json w1)")"
assert_eq "...and it doesn't hold up a genuine message behind it" "[shepherd] the genuine one" "$(reason "$got")"

# never a slash command: the stop hook hands text to the model, but a typed one would run
drop s1 1790000400 1 aa01 "/clear"
drop s1 1790000400 2 aa02 "[shepherd] /compact now"
drop s1 1790000400 3 aa03 "[shepherd]    /model opus"
got="$(evout stop "$(stop_json s1)")"
assert_eq "a slash command is never handed over, marked or not" "" "$got"
assert_eq "...all three are left alone" "3" "$(ls "$CC_INBOX_DIR/s1" | grep -c '\.msg$')"
drop s1 1790000401 1 aa04 "[shepherd] use /compact when you're done"
got="$(evout stop "$(stop_json s1)")"
assert_eq "...a message that only mentions one is fine" "[shepherd] use /compact when you're done" "$(reason "$got")"

# Shepherd's own internal runs never take mail
drop i1 1790000500 1 ab12 "[shepherd] not for you"
got="$(CC_SHEPHERD_INTERNAL=1 evout stop "$(stop_json i1)")"
assert_eq "an internal run takes no mail" "" "$got"
assert_eq "...and leaves it" "1" "$(ls "$CC_INBOX_DIR/i1" | grep -c '\.msg$')"

# other events never touch the inbox
drop o1 1790000600 1 ab34 "[shepherd] for the turn end"
for e in userpromptsubmit pretooluse posttooluse notification stopfailure; do
  got="$(evout "$e" '{"session_id":"o1","cwd":"'"$CWD"'","tool_name":"Bash","notification_type":"idle_prompt"}')"
  assert_eq "$e prints nothing and takes no mail" "" "$got"
done
assert_eq "...the message is still there" "1" "$(ls "$CC_INBOX_DIR/o1" | grep -c '\.msg$')"

# a message with quotes, backslashes and newlines survives as valid JSON
TRICKY="$(printf '[shepherd] line "one" \\ back\nline two\ttab')"
drop j1 1790000700 1 ab56 "$TRICKY"
got="$(evout stop "$(stop_json j1)")"
assert_eq "a multi-line message with quotes and backslashes arrives whole" "$TRICKY" "$(reason "$got")"

# the ledger records the hand-over
LED="$TMP/ledger"
printf '{"ledger":{"enabled":true}}' > "$TMP/ledger-on.json"
drop l1 1790000800 1 ab78 "[shepherd] ledgered"
printf '%s' "$(stop_json l1)" | CC_CONFIG_FILE="$TMP/ledger-on.json" CC_LEDGER_DIR="$LED" bash "$CC" stop >/dev/null 2>&1
got="$(cat "$LED"/*.jsonl 2>/dev/null | jq -r 'select(.type == "mailbox_delivered") | "\(.key) \(.via) \(.nonce)"')"
assert_eq "the ledger records mailbox_delivered: key, how, and which message" "l1 stop ab78" "$got"

# ---- the Stop decision builder: one place, printed once (unit 16 adds its notes here) ----
got="$( . "$ROOT/cc-lib.sh"; cc_stop_decision "" "" )"
assert_eq "cc_stop_decision with nothing to say prints nothing" "" "$got"
got="$( . "$ROOT/cc-lib.sh"; cc_stop_decision "first reason" "" "second reason" )"
assert_eq "...each reason, joined by a blank line" "$(printf 'first reason\n\nsecond reason')" "$(reason "$got")"
assert_eq "...as a block decision" "block" "$(printf '%s' "$got" | jq -r '.decision')"

# ---- SessionStart: whatever still waits arrives with the session's context ----
drop r1 1790000900 2 bc02 "[shepherd] the second"
drop r1 1790000900 1 bc01 "[shepherd] the first"
got="$(evout sessionstart '{"session_id":"r1","cwd":"'"$CWD"'","source":"resume"}')"
assert_eq "a resumed session is told its waiting messages, labelled" "[Shepherd: mailbox]" "$(printf '%s\n' "$got" | head -1)"
case "$got" in *"[shepherd] the first"*"[shepherd] the second"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "...oldest first" "yes" "$r"
assert_eq "...and they are handed over (gone)" "" "$(left r1)"
got="$(evout stop "$(stop_json r1)")"
assert_eq "...so the turn end doesn't hand them over again" "" "$got"

drop c1 1790001000 1 bd01 "[shepherd] after the compaction"
got="$(evout sessionstart '{"session_id":"c1","cwd":"'"$CWD"'","source":"compact"}')"
case "$got" in *"[Shepherd: mailbox]"*"[shepherd] after the compaction"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "a compacted session is told its waiting message" "yes" "$r"

got="$(evout sessionstart '{"session_id":"fresh1","cwd":"'"$CWD"'","source":"startup"}')"
assert_eq "a session with no mail is told nothing" "" "$got"

drop x1 1790001100 1 be01 "[shepherd] forged at start" be99
drop x1 1790001100 2 be02 "/clear"
got="$(evout sessionstart '{"session_id":"x1","cwd":"'"$CWD"'","source":"resume"}')"
assert_eq "at a start too: a wrong nonce or a slash command is never shown" "" "$got"
assert_eq "...both are left alone" "2" "$(ls "$CC_INBOX_DIR/x1" | grep -c '\.msg$')"

got="$(CC_SHEPHERD_INTERNAL=1 evout sessionstart '{"session_id":"i1","cwd":"'"$CWD"'","source":"resume"}')"
assert_eq "an internal run is shown no mail at its start" "" "$got"

# the part has its own budget: what doesn't fit stays for the turn end, whole (never cut)
BIG="[shepherd] $(awk 'BEGIN { for (i = 0; i < 60; i++) printf "a long message that will not fit in the start budget. " }')"
drop b1 1790001200 1 bf01 "[shepherd] short and first"
drop b1 1790001200 2 bf02 "$BIG"
got="$(evout sessionstart '{"session_id":"b1","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *"[shepherd] short and first"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "a message that fits is shown at the start" "yes" "$r"
case "$got" in *"will not fit"*) r="shown (cut)" ;; *) r=kept ;; esac
assert_eq "...one past the part's budget is not shown cut" "kept" "$r"
got="$(evout stop "$(stop_json b1)")"
assert_eq "...it arrives whole at the turn end" "$BIG" "$(reason "$got")"

# ---- the shell reads what the panel writes (core.mailboxMessage is the one format) ----
lua_msg() { lua - "$ROOT/cc-core.lua" "$@" <<'LUA'
local core = dofile(arg[1])
core.json = dofile(arg[1]:gsub("cc%-core%.lua$", "tests/support/json.lua"))   -- the dashboard injects hs.json
local m, why = core.mailboxMessage(arg[2], { kind = "test" }, arg[3], tonumber(arg[4]), tonumber(arg[5]))
if not m then io.stderr:write(tostring(why)); os.exit(1) end
io.write(m.name, "\n", m.body)
LUA
}
out="$(lua_msg "Resume the task" "a1b2c3d4" 1790001300 7)"
name="$(printf '%s\n' "$out" | head -1)"
mkdir -p "$CC_INBOX_DIR/lx"
printf '%s\n' "$out" | sed 1d > "$CC_INBOX_DIR/lx/$name"
assert_eq "core.mailboxMessage names the file <epoch>-<seq>-<nonce>.msg" "1790001300-000007-a1b2c3d4.msg" "$name"
got="$(evout stop "$(stop_json lx)")"
assert_eq "...and the hook hands over what the panel wrote, marked [shepherd]" "[shepherd] Resume the task" "$(reason "$got")"

# ---- SessionEnd reaps the inbox, and only this session's ----
drop e1 1790001400 1 ca01 "[shepherd] never delivered"
drop e2 1790001400 1 ca02 "[shepherd] someone else's"
evout sessionend '{"session_id":"e1","cwd":"'"$CWD"'"}' >/dev/null
assert_absent "SessionEnd removes the session's inbox" "$CC_INBOX_DIR/e1"
assert_eq "...and leaves another session's alone" "1" "$(ls "$CC_INBOX_DIR/e2" | grep -c '\.msg$')"
( . "$ROOT/cc-lib.sh"; cc_remove ".."; cc_remove "."; cc_remove "" ) 2>/dev/null
assert_eq "cc_remove never reaches outside the inbox (a key of .. or . or nothing)" "yes" \
  "$([ -d "$CC_INBOX_DIR/e2" ] && [ -d "$CC_STATUS_DIR" ] && echo yes || echo no)"

finish
