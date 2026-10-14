#!/usr/bin/env bash
# cross.test.sh - crossings, the CLI and hook half (2026-10-14).
# Adam, 2026-10-14: "projects should not be able to utilize having shepherd to talk to each other,
# that needs to be an approved translation between the two rather than something automatic".
# cc-ticket.sh now leaves what a session writes for ANOTHER project -- a filing, a reply, a close
# note -- as a request in ~/.claude/cc-cross/ for Adam to approve (Shepherd's half:
# tests/cross.test.lua). Here: the requests it leaves, the places a ticket was reachable from a third
# repo (take and show by id), a session's project read from where it LAUNCHED (a `cd` doesn't move
# it), a filing still waiting (wait, list, show, withdraw), the notes Shepherd leaves for a session
# that wasn't live (its next start), and the removers.
# Side-effect-free: every dir lives under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_TICKETS_DIR="$TMP/cc-tickets"
export CC_CROSS_DIR="$TMP/cc-cross"
export CC_TICKET_POLL=0.1
unset CLAUDE_CODE_SESSION_ID CC_TICKET_NOW
mkdir -p "$CC_STATUS_DIR" "$CC_TICKETS_DIR" "$TMP/projects"
TK="$ROOT/cc-ticket.sh"

mkrepo() { mkdir -p "$1" && git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$TMP/alpha"; mkrepo "$TMP/beta"; mkrepo "$TMP/gamma"
A="$(cd "$TMP/alpha" && pwd -P)"; B="$(cd "$TMP/beta" && pwd -P)"; G="$(cd "$TMP/gamma" && pwd -P)"
git -C "$B" worktree add -q "$TMP/beta-wt" -b wt 2>/dev/null
BWT="$(cd "$TMP/beta-wt" && pwd -P)"
enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
# status <key> <launch folder> <pid> [cwd now]: a session Shepherd knows, its transcript under the
# projects folder its launch folder names (as Claude Code keeps it), its first record there.
status() {
  local tp="$TMP/projects/$(enc "$2")/$1.jsonl"
  mkdir -p "${tp%/*}"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$2" "$1" > "$tp"
  jq -n --arg k "$1" --arg cwd "${4:-$2}" --arg tp "$tp" --arg pid "$3" \
    '{status:"done", session_id:$k, cwd:$cwd, transcript_path:$tp, session_pid:$pid, updated:1}' > "$CC_STATUS_DIR/$1.json"
}
status f1 "$A" 4242; status w1 "$B" 5151; status w2 "$BWT" 5252; status g1 "$G" 7171

tk() { # <session> <folder> <args...>: cc-ticket.sh as that session, there. -> $OUT $ERR $CODE
  local sid="$1" dir="$2"; shift 2
  ( cd "$dir" && CLAUDE_CODE_SESSION_ID="$sid" bash "$TK" "$@" ) > "$TMP/out" 2> "$TMP/err"
  CODE=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }
lacks() { case "$1" in *"$2"*) echo "no: $1" ;; *) echo yes ;; esac; }
reqs() { find "$CC_CROSS_DIR" -maxdepth 1 -name '*.req.json' 2>/dev/null | grep -c .; }
lastreq() { ls -t "$CC_CROSS_DIR"/*.req.json 2>/dev/null | head -1; }
rq() { jq -r "$1" "$(lastreq)" 2>/dev/null; }
tf() { jq -r "$2" "$CC_TICKETS_DIR/$1.json" 2>/dev/null; }
# published <id> <holder json>: a ticket filed by f1 for beta, as Shepherd publishes it (with a cid)
published() {
  jq -n --arg id "$1" --arg a "$A" --arg b "$B" --argjson h "$2" \
    '{v:1, id:$id, title:"Published", body:"Do the thing.", from:{key:"f1", pid:"4242", cwd:$a, root:$a, name:"alpha"},
      to:{root:$b, name:"beta"}, filed:1792100000, holder:$h, passed:[], thread:[], closed:null, cid:"f1.1792100000-1"}' \
    > "$CC_TICKETS_DIR/$1.json"
}
# record <cid> <state> <kind> <ticket> [role]: Shepherd's record of a crossing
record() {
  jq -n --arg cid "$1" --arg st "$2" --arg k "$3" --arg t "$4" --arg role "${5:-}" --arg b "$B" \
    '{v:1, cid:$cid, kind:$k, state:$st, nonce:"n", at:1792100000, ticket:$t,
      from:{key:($cid | sub("\\.[0-9]+-[0-9]+$"; ""))}, to:{root:$b, name:"beta"}, original:{title:"Held", text:"held"}}
     + (if $role == "" then {} else {role:$role} end)
     + (if $st == "denied" then {decided:{verdict:"deny", note:"Not now."}} else {} end)' > "$CC_CROSS_DIR/$1.json"
}

# ---- file: a request for Adam, never a ticket ----
tk f1 "$A" file --repo "$B" --title "Bump the parser" --body "alpha needs parser 2.x."
assert_eq "file: exit 0" "0" "$CODE"
T1="$OUT"
assert_eq "...prints only the ticket's id" "yes" "$( [[ "$T1" =~ ^t[0-9]+-[0-9]+$ ]] && echo yes || echo "no: $T1")"
assert_eq "...writes no ticket" "0" "$(find "$CC_TICKETS_DIR" -name '*.json' | grep -c .)"
named_f1() { [[ "$(basename "$(lastreq)")" =~ ^f1\.[0-9]+-[0-9]+\.req\.json$ ]] && echo yes || echo "no: $(lastreq)"; }
assert_eq "...but a request in cc-cross, named for its author" "1 yes" "$(reqs) $(named_f1)"
assert_eq "...a filing of that ticket, for beta's main checkout, from f1" "ticket $T1 $B f1 4242" \
  "$(rq '"\(.kind) \(.ticket) \(.to.root) \(.from.key) \(.from.pid)"')"
assert_eq "...carrying the title and body exactly" "Bump the parser|alpha needs parser 2.x." "$(rq '"\(.title)|\(.body)"')"
assert_eq "...its cid matching its file, with a nonce" "yes" \
  "$( [ "$(rq '.cid').req.json" = "$(basename "$(lastreq)")" ] && [ -n "$(rq '.nonce // empty')" ] && echo yes || echo no)"
assert_eq "...stderr says Adam approves it first" "yes" "$(has "$ERR" "Adam")"
assert_eq "...and not to route around it" "yes" "$(has "$ERR" "route around")"
F1REQ="$(lastreq)"

# ---- the filer's own pending filing: list, show, wait, close ----
tk f1 "$A" list
assert_eq "list shows the filing that waits for Adam" "yes" "$(has "$OUT" "$T1")"
assert_eq "...saying so" "yes" "$(has "$OUT" "waiting for Adam")"
tk f1 "$A" show "$T1"
assert_eq "show prints the filer's pending filing" "0" "$CODE"
assert_eq "...its title and that it waits for Adam" "yes yes" "$(has "$OUT" "Bump the parser") $(has "$OUT" "waiting for Adam")"
tk w1 "$B" show "$T1"
assert_eq "...nobody else can see it (no such ticket yet): exit 5" "5" "$CODE"
tk w1 "$B" take "$T1"
assert_eq "...or take it: exit 5" "5" "$CODE"
CID1="$(jq -r '.cid' "$F1REQ")"
record "$CID1" denied ticket "$T1"; rm -f "$F1REQ"
tk f1 "$A" wait "$T1" --timeout 5
assert_eq "wait on a filing Adam denied: exit 0 at once" "0" "$CODE"
assert_eq "...saying it was not filed" "yes" "$(has "$OUT" "not filed")"
tk f1 "$A" file --repo "$B" --title "Withdraw me"
T2="$OUT"
tk f1 "$A" close "$T2" --note "Never mind."
assert_eq "the filer closing a filing that still waits: exit 0" "0" "$CODE"
assert_eq "...leaves a withdraw request for it" "withdraw $T2" "$(rq '"\(.kind) \(.ticket)"')"
rm -f "$CC_CROSS_DIR"/*.req.json

# ---- reply and close on a published ticket: requests too ----
published t1792100000-10 '{"key":"w1","pid":"5151","at":1792100000,"taken":true}'
tk w1 "$B" reply t1792100000-10 "On it -- bumping now."
assert_eq "the holder replies: exit 0" "0" "$CODE"
assert_eq "...a held reply, as the holder" "ticket-reply t1792100000-10 holder On it -- bumping now." \
  "$(rq '"\(.kind) \(.ticket) \(.role) \(.text)"')"
assert_eq "...the thread is untouched" "0" "$(tf t1792100000-10 '.thread | length')"
assert_eq "...stderr says Adam approves it first" "yes" "$(has "$ERR" "Adam")"
tk f1 "$A" reply t1792100000-10 "Thanks -- 2.1 at least."
assert_eq "the filer replies: a held reply, as the filer" "0 filer" "$CODE $(rq '.role')"
tk w1 "$B" close t1792100000-10 --note "Bumped to 2.1.0."
assert_eq "the holder closes it: exit 0" "0" "$CODE"
assert_eq "...a held close note" "ticket-close holder Bumped to 2.1.0." "$(rq '"\(.kind) \(.role) \(.note)"')"
assert_eq "...the ticket isn't closed yet" "null" "$(tf t1792100000-10 '.closed')"
rm -f "$CC_CROSS_DIR"/*.req.json
published t1792100000-11 'null'
tk w1 "$B" reply t1792100000-11 "Taking it."
assert_eq "a reply to an open ticket takes it at once (no text crosses in a take)" "w1 true" \
  "$(tf t1792100000-11 '"\(.holder.key) \(.holder.taken)"')"
assert_eq "...while the reply itself waits for Adam" "ticket-reply 0" "$(rq '.kind') $(tf t1792100000-11 '.thread | length')"
published t1792100000-12 'null'
tk f1 "$A" close t1792100000-12 --note "Withdrawn -- not needed."
assert_eq "the filer closing a ticket nobody has: closed at once (nothing crosses)" "filer none" \
  "$(tf t1792100000-12 '"\(.closed.by) \(.closed.told)"')"

# ---- a third repo can't reach a ticket by its id ----
rm -f "$CC_CROSS_DIR"/*.req.json
published t1792100000-20 'null'
tk g1 "$G" take t1792100000-20
assert_eq "a session in a third repo can't take beta's ticket: exit 3" "3" "$CODE"
assert_eq "...told it isn't its repo's" "yes" "$(has "$ERR" "beta")"
tk g1 "$B" take t1792100000-20
assert_eq "...nor after a cd into beta (its project is where it launched)" "3" "$CODE"
tk g1 "$G" show t1792100000-20
assert_eq "...nor show it: exit 3" "3" "$CODE"
tk g1 "$G" reply t1792100000-20 "hello from gamma"
assert_eq "...nor reply to it: exit 3" "3" "$CODE"
assert_eq "...leaving no request" "0" "$(reqs)"
tk w2 "$BWT" take t1792100000-20
assert_eq "a session in beta's worktree takes it: exit 0" "0" "$CODE"
tk w1 "$B" show t1792100000-20
assert_eq "beta's other session can show it" "0" "$CODE"

# ---- a close that waits for Adam: nobody takes the ticket meanwhile ----
published t1792100000-30 'null'
record "w9.1792100100-1" pending ticket-close t1792100000-30 holder
tk w1 "$B" take t1792100000-30
assert_eq "a ticket whose close waits for Adam can't be taken: exit 3" "3" "$CODE"
assert_eq "...saying why" "yes" "$(has "$ERR" "waiting for Adam")"

# ---- a private close note: the filer's, with nobody holding the ticket ----
published t1792100000-40 'null'
tk f1 "$A" close t1792100000-40 --note "Private: alpha's roadmap changed."
tk w1 "$B" show t1792100000-40
assert_eq "beta sees the ticket is closed" "yes" "$(has "$OUT" "Closed")"
assert_eq "...never the filer's note that went to no one" "yes" "$(lacks "$OUT" "roadmap")"

# ---- only published tickets exist for the CLI ----
jq -n --arg a "$A" --arg b "$B" '{v:1, id:"t1792200000-1", title:"Around Shepherd", body:"", from:{key:"f1", root:$a},
  to:{root:$b, name:"beta"}, filed:1792200000, holder:null, passed:[], thread:[], closed:null}' > "$CC_TICKETS_DIR/t1792200000-1.json"
tk w1 "$B" take t1792200000-1
assert_eq "a ticket written into the folder with no crossing doesn't exist: exit 5" "5" "$CODE"
tk w1 "$B" list
assert_eq "...nor does list show it" "yes" "$(lacks "$OUT" "t1792200000-1")"
jq -n --arg a "$A" --arg b "$B" '{v:1, id:"t1791900000-1", title:"Before the gate", body:"", from:{key:"f1", root:$a},
  to:{root:$b, name:"beta"}, filed:1791900000, holder:null, passed:[], thread:[], closed:null}' > "$CC_TICKETS_DIR/t1791900000-1.json"
tk w1 "$B" take t1791900000-1
assert_eq "a ticket filed before the gate shipped is taken as before (Adam: let them through)" "0" "$CODE"

# ---- Shepherd's notes for a session that wasn't live: its next start, once ----
printf '{"cid":"f1.1792100500-1","key":"f1","text":"[shepherd] Adam did not pass on your reply: Not now.","at":1}' \
  > "$CC_CROSS_DIR/f1.1792100500-1.notice"
printf '{"cid":"f1x.1792100500-2","key":"f1x","text":"for another key","at":1}' > "$CC_CROSS_DIR/f1x.1792100500-2.notice"
CTX="$( . "$ROOT/cc-lib.sh"; cc_session_context startup f1 "$A" 2>/dev/null )"
assert_eq "a session's start shows Shepherd's note on its crossing" "yes yes" \
  "$(has "$CTX" "[Shepherd: crossings]") $(has "$CTX" "Not now.")"
assert_eq "...never another session's" "yes" "$(lacks "$CTX" "for another key")"
assert_eq "...and takes it" "no yes" \
  "$([ -f "$CC_CROSS_DIR/f1.1792100500-1.notice" ] && echo yes || echo no) $([ -f "$CC_CROSS_DIR/f1x.1792100500-2.notice" ] && echo yes || echo no)"
CTX="$( . "$ROOT/cc-lib.sh"; cc_session_context startup f1 "$A" 2>/dev/null )"
assert_eq "...once" "yes" "$(lacks "$CTX" "Shepherd: crossings")"

# ---- a session's project: where it launched, not where it cd'd ----
assert_eq "a session's project is its launch folder's repo" "$B" "$( . "$ROOT/cc-lib.sh"; cc_session_project w1 )"
assert_eq "...a worktree's is its repo's main checkout" "$B" "$( . "$ROOT/cc-lib.sh"; cc_session_project w2 )"
status g2 "$G" 7272 "$B"   # launched in gamma, cd'd into beta since
assert_eq "...a cd into another repo doesn't move it" "$G" "$( . "$ROOT/cc-lib.sh"; cc_session_project g2 )"
mkdir -p "$G/sub/deeper"
status g3 "$G" 7373 "$G/sub/deeper"
assert_eq "...nor working in a subfolder" "$G" "$( . "$ROOT/cc-lib.sh"; cc_session_project g3 )"

# ---- the removers: a SessionEnd keeps the crossings; stale parts go ----
record "f1.1792100600-1" pending ticket t1792100600-1
( . "$ROOT/cc-lib.sh"; cc_remove f1 )
assert_eq "a SessionEnd keeps the session's pending crossing (Adam still decides it)" "yes" \
  "$([ -f "$CC_CROSS_DIR/f1.1792100600-1.json" ] && echo yes || echo no)"
printf '{}' > "$CC_CROSS_DIR/f1.1792100700-1.req.json.claim.shepherd"
printf '{}' > "$CC_CROSS_DIR/f1.1792100700-2.json.tmp.77"
touch -t 202001010000 "$CC_CROSS_DIR/f1.1792100700-1.req.json.claim.shepherd" "$CC_CROSS_DIR/f1.1792100700-2.json.tmp.77"
( . "$ROOT/cc-lib.sh"; cc_cross_prune )
assert_eq "a claim of a request Shepherd never recorded goes back into place" "yes" \
  "$([ -f "$CC_CROSS_DIR/f1.1792100700-1.req.json" ] && echo yes || echo no)"
assert_eq "...a dead writer's temp goes" "no" "$([ -f "$CC_CROSS_DIR/f1.1792100700-2.json.tmp.77" ] && echo yes || echo no)"
assert_eq "...a pending record stays" "yes" "$([ -f "$CC_CROSS_DIR/f1.1792100600-1.json" ] && echo yes || echo no)"

# ---- the ledger ----
echo '{"ledger":{"enabled":true}}' > "$CC_CONFIG_FILE"
tk f1 "$A" file --repo "$B" --title "Ledgered"
assert_eq "the ledger records the request, never its text" "crossing_requested ticket null" \
  "$(cat "$CC_LEDGER_DIR"/*.jsonl | jq -r 'select(.type == "crossing_requested") | "\(.type) \(.kind) \(.title)"' | tail -1)"
echo '{}' > "$CC_CONFIG_FILE"

finish
