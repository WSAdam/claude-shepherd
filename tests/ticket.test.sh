#!/usr/bin/env bash
# ticket.test.sh - cc-ticket.sh, the CLI half of cross-repo tickets (2026-09-29, build program unit 29).
# A session files work for ANOTHER repo's sessions: `cc-ticket.sh file --repo <root|name> --title T
# --body B` writes ~/.claude/cc-tickets/<id>.json. Shepherd offers it to that repo's least-busy live
# session (tests/ticket.test.lua); the session takes it (take / reply / close), replies, and closes it
# with a note; the filer gets the replies and the close back -- through its mailbox, at its next
# start (the [Shepherd: tickets] part), or from `cc-ticket.sh wait <id>` running in the background.
# Every change to a ticket claims its file with mv first, so two writers never both win: the claim
# race below. An offer nobody took is reclaimed after 45 minutes (an injected clock, CC_TICKET_NOW),
# and a session's tickets go back when it ends (cc_remove).
# Side-effect-free: every dir lives under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
BG=""
stop_bg() { local p; for p in $BG; do kill "$p" 2>/dev/null; done; BG=""; }
trap 'stop_bg; rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_TICKETS_DIR="$TMP/cc-tickets"
export CC_CROSS_DIR="$TMP/cc-cross"
export CC_TICKET_POLL=0.1
unset CLAUDE_CODE_SESSION_ID CC_TICKET_NOW
mkdir -p "$CC_STATUS_DIR"
TK="$ROOT/cc-ticket.sh"

mkrepo() { mkdir -p "$1" && git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$TMP/alpha"; mkrepo "$TMP/beta"; mkrepo "$TMP/x/same"; mkrepo "$TMP/y/same"
A="$(cd "$TMP/alpha" && pwd -P)"; B="$(cd "$TMP/beta" && pwd -P)"
# a worktree of beta: its sessions are beta's
git -C "$B" worktree add -q "$TMP/beta-wt" -b wt 2>/dev/null
BWT="$(cd "$TMP/beta-wt" && pwd -P)"
# the sessions Shepherd knows (a name resolves through their folders)
status() { printf '{"status":"done","session_id":"%s","cwd":"%s","updated":1}' "$1" "$2" > "$CC_STATUS_DIR/$1.json"; }
status f1 "$A"; status w1 "$B"; status w2 "$BWT"; status s1 "$TMP/x/same"; status s2 "$TMP/y/same"

# tk <session id> <folder> <args...>: cc-ticket.sh as that session, run in that folder.
# stdout -> $OUT, stderr -> $ERR, exit code -> $CODE
tk() {
  local sid="$1" dir="$2"; shift 2
  ( cd "$dir" && CLAUDE_CODE_SESSION_ID="$sid" bash "$TK" "$@" ) > "$TMP/out" 2> "$TMP/err"
  CODE=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
tf() { jq -r "$2" "$CC_TICKETS_DIR/$1.json" 2>/dev/null; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }
both() { [ "$(has "$1" "$2")" = yes ] && [ "$(has "$1" "$3")" = yes ] && echo yes || echo "no: $1"; }
lacks() { case "$1" in *"$2"*) echo "no: $1" ;; *) echo yes ;; esac; }
leftovers() { find "$CC_TICKETS_DIR" -maxdepth 1 \( -name '*.claim.*' -o -name '*.tmp.*' \) 2>/dev/null | grep -c .; }
# REQUIREMENT CHANGE 2026-10-14 (Adam: "projects should not be able to utilize having shepherd to talk
# to each other, that needs to be an approved translation between the two rather than something
# automatic"): a filing, a reply and a close note now wait in cc-cross as requests until Adam approves
# them, and Shepherd publishes them (tests/cross.test.lua, tests/cross.test.sh). This suite is about the
# CLI around a PUBLISHED ticket, so `approve` stands in for Adam's click and Shepherd's publish: every
# request waiting, as written. reqof <ticket id>: the request (if any) that names it.
reqof() { grep -lF -- "\"$1\"" "$CC_CROSS_DIR"/*.req.json 2>/dev/null | head -1; }
approve() {
  local f k t
  mkdir -p "$CC_TICKETS_DIR"   # Shepherd makes the folder when it publishes the first ticket
  for f in "$CC_CROSS_DIR"/*.req.json; do
    [ -f "$f" ] || continue
    k="$(jq -r .kind "$f")"; t="$(jq -r .ticket "$f")"
    case "$k" in
      ticket) jq '{v:1, id:.ticket, title, body, from:(.from | {key, pid, cwd, root, name}), to, filed:.at,
                   holder:null, passed:[], thread:[], closed:null, cid}' "$f" > "$CC_TICKETS_DIR/$t.json" ;;
      ticket-reply) jq --slurpfile r "$f" '.thread += [{by:$r[0].role, key:$r[0].from.key, text:$r[0].text, at:$r[0].at,
                    told:false, cid:$r[0].cid}]' "$CC_TICKETS_DIR/$t.json" > "$TMP/pub" && mv "$TMP/pub" "$CC_TICKETS_DIR/$t.json" ;;
      ticket-close) jq --slurpfile r "$f" '.closed = {by:$r[0].role, key:$r[0].from.key, note:$r[0].note, at:$r[0].at,
                    told:false, cid:$r[0].cid}' "$CC_TICKETS_DIR/$t.json" > "$TMP/pub" && mv "$TMP/pub" "$CC_TICKETS_DIR/$t.json" ;;
    esac
    rm -f "$f"
  done
}

# ---- the CLI: help, and refused outside a session ----
bash "$TK" --help > "$TMP/out" 2>&1; CODE=$?
assert_eq "--help: exit 0" "0" "$CODE"
assert_eq "...naming every command" "yes" "$(has "$(cat "$TMP/out")" "file --repo")"
( cd "$A" && bash "$TK" file --repo "$B" --title "x" ) > /dev/null 2> "$TMP/err"; CODE=$?
assert_eq "outside a Claude session: refused (exit 2)" "2" "$CODE"
assert_eq "...saying CLAUDE_CODE_SESSION_ID is unset" "yes" "$(has "$(cat "$TMP/err")" "CLAUDE_CODE_SESSION_ID")"
tk f1 "$A" bogus
assert_eq "an unknown command: exit 2" "2" "$CODE"

# ---- file: refused when it can't be routed or read ----
tk f1 "$A" file --title "Bump the parser"
assert_eq "file without --repo: exit 2" "2" "$CODE"
tk f1 "$A" file --repo "$B"
assert_eq "file without --title: exit 2" "2" "$CODE"
tk f1 "$A" file --repo "$B" --title $'two\nlines'
assert_eq "a title that isn't one line: exit 2" "2" "$CODE"
tk f1 "$A" file --repo "$B" --title "long body" --body "$(head -c 2600 /dev/zero | tr '\0' x)"
assert_eq "a body over 2500 bytes: exit 2" "2" "$CODE"
tk f1 "$A" file --repo "$TMP/nowhere" --title "x"
assert_eq "a folder that doesn't exist: exit 2" "2" "$CODE"
tk f1 "$A/." file --repo "$A" --title "x"
assert_eq "this session's own repo: exit 2 (tickets are for ANOTHER repo)" "2" "$CODE"
assert_eq "...saying so" "yes" "$(has "$ERR" "own repo")"
tk f1 "$A" file --repo nobody-has-this --title "x"
assert_eq "a name no known session's repo has: exit 2" "2" "$CODE"
tk f1 "$A" file --repo same --title "x"
assert_eq "a name two repos share: exit 2" "2" "$CODE"
assert_eq "...listing both roots" "yes" "$(both "$ERR" "/x/same" "/y/same")"
assert_eq "nothing was filed by any of them" "0" "$(find "$CC_TICKETS_DIR" -name '*.json' 2>/dev/null | grep -c .)"

# ---- file ----
tk f1 "$A" file --repo "$B" --title "Bump the parser to 2.x" --body "alpha's build needs parser 2.x -- bump it and tag a release."
assert_eq "file: exit 0" "0" "$CODE"
T1="$OUT"
assert_eq "...prints only the ticket id on stdout" "yes" "$( [[ "$T1" =~ ^t[0-9]+-[0-9]+$ ]] && echo yes || echo "no: $T1")"
# REQUIREMENT CHANGE 2026-10-14 (above): the filing waits for Adam as a request; no ticket file yet
assert_eq "...held for Adam: a request in cc-cross, no ticket file yet" "yes no" \
  "$([ -n "$(reqof "$T1")" ] && echo yes || echo no) $([ -f "$CC_TICKETS_DIR/$T1.json" ] && echo yes || echo no)"
assert_eq "...addressed to the target repo's main checkout" "$B" "$(jq -r '.to.root' "$(reqof "$T1")")"
assert_eq "...from the filing session and its repo" "f1 $A" "$(jq -r '"\(.from.key) \(.from.root)"' "$(reqof "$T1")")"
assert_eq "...carrying the title and body" "Bump the parser to 2.x" "$(jq -r '.title' "$(reqof "$T1")")"
assert_eq "...and stderr says how it gets there" "yes" "$(has "$ERR" "live session")"
tk f1 "$A" file --repo beta --title "By name"
assert_eq "a repo's name resolves through the sessions Shepherd knows" "$B" "$(jq -r '.to.root' "$(reqof "$OUT")")"
rm -f "$(reqof "$OUT")"
tk f1 "$A" file --repo "$BWT" --title "By worktree"
assert_eq "a worktree's folder files to its repo's main checkout" "$B" "$(jq -r '.to.root' "$(reqof "$OUT")")"
rm -f "$(reqof "$OUT")"
approve
assert_eq "once Adam approves it, it is open: no holder, no replies, not closed" "null 0 null" \
  "$(tf "$T1" '"\(.holder) \(.thread | length) \(.closed)"')"

# ---- take ----
tk f1 "$A" take "$T1"
assert_eq "the filer can't take its own ticket: exit 3" "3" "$CODE"
tk w1 "$B" take "$T1"
assert_eq "a session takes an open ticket: exit 0" "0" "$CODE"
assert_eq "...and reads it on stdout" "yes" "$(has "$OUT" "tag a release")"
assert_eq "...it is the holder now, taken" "w1 true" "$(tf "$T1" '"\(.holder.key) \(.holder.taken)"')"
tk w2 "$BWT" take "$T1"
assert_eq "another session can't take a held ticket: exit 3" "3" "$CODE"
assert_eq "...told who holds it" "yes" "$(has "$ERR" "w1")"
tk w1 "$B" take "$T1"
assert_eq "the holder taking it again is fine" "0" "$CODE"
tk w1 "$B" take t1-1
assert_eq "no such ticket: exit 5" "5" "$CODE"
tk w1 "$B" take "../evil"
assert_eq "an id that isn't one: exit 2" "2" "$CODE"

# ---- reply ----
tk w1 "$B" reply "$T1" "On it -- bumping now."
assert_eq "the holder replies: exit 0" "0" "$CODE"
# REQUIREMENT CHANGE 2026-10-14 (above): held for Adam until he approves it
assert_eq "...held for Adam: the thread is untouched until he approves it" "0" "$(tf "$T1" '.thread | length')"
approve
assert_eq "...then recorded as the holder's, not yet told" "holder w1 false" "$(tf "$T1" '.thread[0] | "\(.by) \(.key) \(.told)"')"
tk f1 "$A" reply "$T1" "Thanks -- 2.1 at least, please."
assert_eq "the filer replies: exit 0" "0" "$CODE"
approve
assert_eq "...recorded as the filer's (once approved)" "filer" "$(tf "$T1" '.thread[1].by')"
tk w2 "$BWT" reply "$T1" "me too"
assert_eq "a third session can't reply to a held ticket: exit 3" "3" "$CODE"
tk w1 "$B" reply "$T1" ""
assert_eq "an empty reply: exit 2" "2" "$CODE"

# ---- close ----
tk w1 "$B" close "$T1"
assert_eq "close without a note: exit 2" "2" "$CODE"
assert_eq "...closing needs a note" "yes" "$(has "$ERR" "--note")"
tk w1 "$B" close "$T1" --note "   "
assert_eq "a blank note: exit 2" "2" "$CODE"
tk w2 "$BWT" close "$T1" --note "not mine"
assert_eq "a third session can't close it: exit 3" "3" "$CODE"
tk w1 "$B" close "$T1" --note "Bumped to 2.1.0 and tagged v2.1.0."
assert_eq "the holder closes it with a note: exit 0" "0" "$CODE"
# REQUIREMENT CHANGE 2026-10-14 (above): the close note waits for Adam too
assert_eq "...held for Adam: not closed until he approves it" "null" "$(tf "$T1" '.closed')"
approve
assert_eq "...then closed by the holder, the filer not yet told" "holder false" "$(tf "$T1" '.closed | "\(.by) \(.told)"')"
tk w1 "$B" reply "$T1" "one more thing"
assert_eq "a closed ticket takes no reply: exit 2" "2" "$CODE"
tk w1 "$B" close "$T1" --note "again"
assert_eq "...and isn't closed twice" "2" "$CODE"

# ---- wait: the filer gets what it hasn't been told ----
tk f1 "$A" wait "$T1" --timeout 5
assert_eq "wait with news waiting: exit 0 at once" "0" "$CODE"
assert_eq "...prints the holder's reply" "yes" "$(has "$OUT" "On it -- bumping now.")"
assert_eq "...and the close note" "yes" "$(has "$OUT" "Bumped to 2.1.0 and tagged v2.1.0.")"
assert_eq "...not the filer's own reply" "yes" "$(lacks "$OUT" "2.1 at least")"
assert_eq "...marks both told (by wait), so no mailbox repeats them" "wait wait" "$(tf "$T1" '"\(.thread[0].told) \(.closed.told)"')"
assert_eq "...and leaves the filer's reply for the holder" "false" "$(tf "$T1" '.thread[1].told')"
tk f1 "$A" wait "$T1" --timeout 5
assert_eq "wait on a closed ticket with nothing new: exit 0 at once" "0" "$CODE"
assert_eq "...saying it's closed" "yes" "$(has "$OUT" "closed")"
tk w2 "$BWT" wait "$T1" --timeout 1
assert_eq "wait on a ticket that isn't yours: exit 3" "3" "$CODE"

# wait blocks until the reply comes
tk f1 "$A" file --repo "$B" --title "Second"
T2="$OUT"
approve
( cd "$A" && CLAUDE_CODE_SESSION_ID=f1 bash "$TK" wait "$T2" --timeout 20 > "$TMP/wait.out" 2> "$TMP/wait.err"; echo $? > "$TMP/wait.code" ) &
WPID=$!; BG="$BG $WPID"
for _ in $(seq 1 50); do [ "$(tf "$T2" '.waiting.filer.pid // empty')" != "" ] && break; sleep 0.1; done
assert_eq "a waiter registers itself on the ticket (Shepherd holds the mailbox back for it)" "yes" \
  "$([ -n "$(tf "$T2" '.waiting.filer.pid // empty')" ] && echo yes || echo no)"
tk w1 "$B" reply "$T2" "Here is the answer: 42."
approve
wait "$WPID" 2>/dev/null
assert_eq "...exits 0 once the reply comes" "0" "$(cat "$TMP/wait.code")"
assert_eq "...printing it on stdout" "yes" "$(has "$(cat "$TMP/wait.out")" "Here is the answer: 42.")"
assert_eq "...and unregisters" "" "$(tf "$T2" '.waiting.filer // empty')"
tk f1 "$A" wait "$T2" --timeout 1
assert_eq "wait that runs out: exit 4" "4" "$CODE"
tk f1 "$A" wait t1-1 --timeout 1
assert_eq "wait on no such ticket: exit 5" "5" "$CODE"

# ---- the claim race: every writer claims the file with mv first; one take wins ----
tk f1 "$A" file --repo "$B" --title "Race"
T3="$OUT"
approve
for n in 1 2 3 4 5 6; do
  status "r$n" "$B"
  ( cd "$B" && CLAUDE_CODE_SESSION_ID="r$n" bash "$TK" take "$T3" > /dev/null 2>&1; echo $? > "$TMP/race.$n" ) &
done
wait
wins=0; winner=""
for n in 1 2 3 4 5 6; do [ "$(cat "$TMP/race.$n")" = 0 ] && { wins=$((wins + 1)); winner="r$n"; }; done
assert_eq "six sessions take one ticket at once: exactly one wins" "1" "$wins"
assert_eq "...the others are told it's held (exit 3)" "5" "$(cat "$TMP"/race.* | grep -c '^3$')"
assert_eq "...the ticket names the winner" "$winner" "$(tf "$T3" '.holder.key')"
assert_eq "...and is whole JSON, with no claim or temp left behind" "ok 0" "$(jq -e . "$CC_TICKETS_DIR/$T3.json" > /dev/null && echo ok) $(leftovers)"
# a writer that finds the file claimed by another waits its turn instead of failing
# REQUIREMENT CHANGE 2026-10-14 (above): a filer's reply no longer writes the ticket (it waits for
# Adam as a request), so the writer here is the holder taking it again -- an update all the same.
mv "$CC_TICKETS_DIR/$T3.json" "$CC_TICKETS_DIR/$T3.json.claim.99999"
( sleep 0.4; mv "$CC_TICKETS_DIR/$T3.json.claim.99999" "$CC_TICKETS_DIR/$T3.json" ) &
tk "$winner" "$B" take "$T3"
wait
assert_eq "a take that meets a claimed file retries until it's back: exit 0" "0" "$CODE"
assert_eq "...and lands" "$winner true" "$(tf "$T3" '"\(.holder.key) \(.holder.taken)"')"

# ---- a writer puts the ticket back between another's two looks (2026-09-30) ----
# 2026-09-30: the six-way race above sometimes told only 4 of its 5 losers "held": the fifth got
# "no ticket" (exit 5; 1 run in 60 on a quiet machine). One claim had won -- the odd one out never
# reached the claim. "Is the ticket there?" was one look at the file and then one at its claims,
# and a writer moves the file to its claim and back: a look that finds the file claimed, followed
# by a look after it was put back, sees neither. Replayed here exactly -- compgen (the claims
# look) is wrapped so the other writer's put-back lands right before it.
putback_between_looks() { # <ticket id>: claim it as another writer, who puts it back mid-look
  mv "$CC_TICKETS_DIR/$1.json" "$CC_TICKETS_DIR/$1.json.claim.99999"
  export CC_PUTBACK="$CC_TICKETS_DIR/$1.json.claim.99999"
  compgen() {
    [ -e "$CC_PUTBACK" ] && mv "$CC_PUTBACK" "${CC_PUTBACK%.claim.99999}"
    builtin compgen "$@"
  }
  export -f compgen
}
tk f1 "$A" file --repo "$B" --title "Between two looks"
T5="$OUT"
approve
putback_between_looks "$T5"
tk w1 "$B" take "$T5"
assert_eq "a take whose two looks straddle another writer's put-back still finds the ticket: exit 0" "0" "$CODE"
assert_eq "...and never says there is no such ticket" "yes" "$(lacks "$ERR" "no ticket")"
assert_eq "...it holds the ticket" "w1 true" "$(tf "$T5" '"\(.holder.key) \(.holder.taken)"')"
# the same straddle inside the claim loop (cc_ticket_update): it waits its turn, not "no such ticket"
putback_between_looks "$T5"
( . "$ROOT/cc-lib.sh"; cc_ticket_update "$T5" '{ticket: (.title = "Looked twice")}' > /dev/null; echo $? > "$TMP/straddle.rc" )
unset -f compgen; unset CC_PUTBACK
assert_eq "an update that meets the same straddle claims the ticket once it's back: written (0)" "0" "$(cat "$TMP/straddle.rc")"
assert_eq "...and its change lands" "Looked twice" "$(tf "$T5" '.title')"
assert_eq "...with no claim or temp left behind" "0" "$(leftovers)"
tk w1 "$B" take t1-1
assert_eq "a ticket that really isn't there is still exit 5" "5" "$CODE"

# ---- reclaim: an offer nobody took goes back after 45 minutes (injected clock) ----
NOW=1790000000
fixture() { # <id> <holder json>: a ticket filed by f1 for beta, as Shepherd left it
  jq -n --arg id "$1" --arg a "$A" --arg b "$B" --argjson h "$2" --argjson now "$NOW" \
    '{v:1, id:$id, title:"Fixture", body:"", from:{key:"f1", cwd:$a, root:$a, name:"alpha"},
      to:{root:$b, name:"beta"}, filed:$now, holder:$h, passed:[], thread:[], closed:null}' \
    > "$CC_TICKETS_DIR/$1.json"
}
fixture t1790000000-1 '{"key":"w1","at":1790000000,"taken":false}'
CC_TICKET_NOW=$((NOW + 44 * 60)) tk w2 "$BWT" take t1790000000-1
assert_eq "an offer to another session, 44 minutes old: still theirs (exit 3)" "3" "$CODE"
assert_eq "...told who it's offered to" "yes" "$(has "$ERR" "w1")"
CC_TICKET_NOW=$((NOW + 46 * 60)) tk w2 "$BWT" take t1790000000-1
assert_eq "...46 minutes old and never taken: reclaimed, so another session takes it" "0" "$CODE"
assert_eq "...it holds it now" "w2 true" "$(tf t1790000000-1 '"\(.holder.key) \(.holder.taken)"')"
assert_eq "...and the one that let it lapse is passed over from now on" "w1" "$(tf t1790000000-1 '.passed | join(",")')"
fixture t1790000000-2 '{"key":"w1","at":1790000000,"taken":false}'
CC_TICKET_NOW=$((NOW + 10 * 60)) tk w1 "$B" take t1790000000-2
assert_eq "the session it was offered to takes it within the 45 minutes" "0 true" "$CODE $(tf t1790000000-2 '.holder.taken')"
fixture t1790000000-3 '{"key":"w1","at":1790000000,"taken":true}'
CC_TICKET_NOW=$((NOW + 3 * 3600)) tk w2 "$BWT" take t1790000000-3
assert_eq "a TAKEN ticket isn't reclaimed by time -- only when its holder is gone (exit 3)" "3" "$CODE"

# ---- the holder's session ends: its tickets go back (both removers; this is cc_remove's) ----
fixture t1790000000-4 '{"key":"w1","at":1790000000,"taken":true}'
fixture t1790000000-5 '{"key":"w1","at":1790000000,"taken":true}'
jq --argjson at "$(date +%s)" '.closed = {by:"holder", key:"w1", note:"done", at:$at, told:false}' "$CC_TICKETS_DIR/t1790000000-5.json" > "$TMP/c" \
  && mv "$TMP/c" "$CC_TICKETS_DIR/t1790000000-5.json"
( . "$ROOT/cc-lib.sh"; cc_remove w1 )
assert_eq "SessionEnd: the ended session's open ticket goes back, unheld" "null" "$(tf t1790000000-4 '.holder')"
assert_eq "...passing it over from now on" "w1" "$(tf t1790000000-4 '.passed | join(",")')"
assert_eq "...a closed one keeps its record" "w1" "$(tf t1790000000-5 '.holder.key')"
( . "$ROOT/cc-lib.sh"; cc_remove f1 )
assert_eq "...and the tickets a session FILED stay, for its next start" "yes" "$([ -f "$CC_TICKETS_DIR/$T1.json" ] && echo yes || echo no)"

# ---- the filer's next start: news it hasn't been told ([Shepherd: tickets]) ----
tk f1 "$A" file --repo "$B" --title "Third"
T4="$OUT"
approve
tk w1 "$B" reply "$T4" "Done in 5 minutes."
approve
CTX="$( . "$ROOT/cc-lib.sh"; cc_session_context startup f1 "$A" 2>/dev/null )"
assert_eq "SessionStart shows the filer a reply it wasn't told" "yes" "$(has "$CTX" "[Shepherd: tickets]")"
assert_eq "...the reply itself, with the ticket's id" "yes" "$(both "$CTX" "$T4" "Done in 5 minutes.")"
assert_eq "...and marks it told (start)" "start" "$(tf "$T4" '.thread[0].told')"
CTX="$( . "$ROOT/cc-lib.sh"; cc_session_context startup f1 "$A" 2>/dev/null )"
assert_eq "...once" "yes" "$(lacks "$CTX" "Shepherd: tickets")"
CTX="$( . "$ROOT/cc-lib.sh"; cc_session_context startup w1 "$B" 2>/dev/null )"
assert_eq "the holder's start doesn't get its own reply back" "yes" "$(lacks "$CTX" "Done in 5 minutes")"

# ---- show, list ----
# REQUIREMENT CHANGE 2026-10-14 (above): show was open to anyone; now only to the filer, the holder
# and the target repo's sessions (a third repo is refused: tests/cross.test.sh). w2 is beta's.
tk w2 "$BWT" show "$T4"
assert_eq "show prints a ticket to a session of the repo it's for" "0" "$CODE"
assert_eq "...its title and thread" "yes" "$(both "$OUT" "Third" "Done in 5 minutes.")"
tk f1 "$A" list
assert_eq "list shows the tickets the session filed" "yes" "$(both "$OUT" "$T1" "$T4")"

# ---- the ledger ----
echo '{"ledger":{"enabled":true}}' > "$CC_CONFIG_FILE"
tk f1 "$A" file --repo "$B" --title "Ledgered"
T5="$OUT"
approve
tk w1 "$B" close "$T5" --note "Not ours: it's gamma's parser."
# REQUIREMENT CHANGE 2026-10-14 (above): the CLI records the REQUESTS; ticket_filed and ticket_closed
# are Shepherd's now, written when it publishes them (tests/cross.test.lua)
assert_eq "the ledger records the filing and the close as requests (crossing_requested)" "ticket ticket-close" \
  "$(cat "$CC_LEDGER_DIR"/*.jsonl | jq -r --arg id "$T5" 'select(.ticket == $id and .type == "crossing_requested") | .kind' | paste -sd' ' -)"
echo '{}' > "$CC_CONFIG_FILE"

# ---- prune: old closed tickets and stale parts go ----
fixture t1780000000-6 'null'
jq '.filed = 1780000000 | .closed = {by:"filer", key:"f1", note:"old", at:1780000000, told:true}' \
  "$CC_TICKETS_DIR/t1780000000-6.json" > "$TMP/c" && mv "$TMP/c" "$CC_TICKETS_DIR/t1780000000-6.json"
touch -t 202605280000 "$CC_TICKETS_DIR/t1780000000-6.json"   # ...and was last written when it closed
fixture t1790000000-7 'null'
mv "$CC_TICKETS_DIR/t1790000000-7.json" "$CC_TICKETS_DIR/t1790000000-7.json.claim.4242"
touch -t 202001010000 "$CC_TICKETS_DIR/t1790000000-7.json.claim.4242"
( . "$ROOT/cc-lib.sh"; cc_ticket_prune )
assert_eq "a ticket closed over a week ago is pruned" "no" "$([ -f "$CC_TICKETS_DIR/t1780000000-6.json" ] && echo yes || echo no)"
assert_eq "a writer's claim left over a minute (it died) is put back" "yes 0" \
  "$([ -f "$CC_TICKETS_DIR/t1790000000-7.json" ] && echo yes || echo no) $(leftovers)"
assert_eq "an open ticket is kept" "yes" "$([ -f "$CC_TICKETS_DIR/$T4.json" ] && echo yes || echo no)"

finish
