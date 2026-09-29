#!/usr/bin/env bash
# cc-ticket.sh - file work for ANOTHER repo's sessions, and get the reply back without anyone
# relaying it (build program unit 29, 2026-09-29).
#
#   cc-ticket.sh file --repo <root|name> --title "<T>" [--body "<B>"]   prints the new ticket's id
#   cc-ticket.sh take <id>                     take a ticket offered to you (or an open one); prints it
#   cc-ticket.sh reply <id> "<text>"           to the other side (a reply takes an open ticket first)
#   cc-ticket.sh close <id> --note "<note>"    closing always says what happened
#   cc-ticket.sh wait <id> [--timeout <s>]     run it in the BACKGROUND: blocks until a reply or the close
#   cc-ticket.sh show <id>                     the whole ticket
#   cc-ticket.sh list                          the tickets this session filed, holds, or its repo waits on
#
# A ticket is ~/.claude/cc-tickets/<id>.json. Shepherd offers it to the target repo's least-busy live
# session (never one waiting on you), through that session's mailbox: a busy session gets it at its
# turn end, an idle one typed where typing is safe, else it waits in its mailbox until its next turn
# end or start. The session takes it (take, reply or close) within 45 minutes, or it goes to another
# session; a ticket whose holder's session ends goes back too. With no session to take it, it shows
# on that repo's card in Shepherd with "Open a tab for it". Replies and the close come back to the
# other side the same way -- through its mailbox, at its next start, or from a `wait` running in the
# background. Every change claims the ticket's file with mv first (cc_ticket_update in cc-lib.sh),
# so two writers never both win.
#
# Only what a script wants goes to stdout (the id, the ticket, the news); everything else to stderr.
# Exit codes: 0 done; 2 refused (the arguments, a closed ticket, your own repo); 3 not yours (held
# by or offered to another session, or you filed it); 4 wait ran out; 5 no such ticket.
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

POLL="${CC_TICKET_POLL:-1}"
PANEL_MAX_AGE="${CC_TICKET_PANEL_MAX_AGE:-30}"
TITLE_MAX=200 BODY_MAX=2500 REPLY_MAX=2000 NOTE_MAX=1000   # core.TICKET: KEEP IN SYNC
CMD_PATH="~/.claude/cc-ticket.sh"

usage() {
  cat <<'EOF'
cc-ticket.sh file --repo <root|name> --title "<T>" [--body "<B>"]
cc-ticket.sh take <id> | reply <id> "<text>" | close <id> --note "<note>"
cc-ticket.sh wait <id> [--timeout <seconds>] | show <id> | list

File work for ANOTHER repo's sessions. `file` prints the ticket's id; Shepherd offers the ticket to
that repo's least-busy live session, which takes it (take, reply or close) within 45 minutes or it
goes to another session. With no session there, it waits on the repo's card ("Open a tab for it").
Replies and the close come back through your mailbox, at your next start, or from `wait` -- run
that in the background: it prints the next reply or the close. Closing always needs a note.
--repo is a repo's root (or any folder in it, or a worktree) or its name. Must run inside a Claude
Code session (CLAUDE_CODE_SESSION_ID).
Exit: 0 done, 2 refused, 3 not yours, 4 wait ran out, 5 no such ticket.
EOF
}

say() { printf '%s\n' "$*" >&2; }
refuse() { say "❌ cc-ticket: $*"; exit 2; }
not_yours() { say "❌ cc-ticket: $*"; exit 3; }
usage_error() { say "❌ cc-ticket: $*"; say "   (cc-ticket.sh --help)"; exit 2; }
bytes() { local LC_ALL=C; printf '%s' "${#1}"; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
now() { printf '%s' "${CC_TICKET_NOW:-$(date +%s)}"; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"
ME="$(cc_key "$SID" "")"
case "$ME" in ''|.|..) refuse "can't tell which session this is" ;; esac
ME_PID="$(cc_read_field "$ME" '.session_pid' | tr -dc '0-9')"
ME_NAME="$(cc_read_field "$ME" '.name' | tr -d '[:cntrl:]')"
CMD="$1"
shift

# ---- the rules this script adds to CC_TICKET_JQ (cc-lib.sh): who you are to a ticket, and take ----
# KEEP IN SYNC with core.ticketPhase / core.ticketRelease. A holder found by its pid (a /clear kept
# the process, not the key) is still the holder.
RULES='
def is_filer: .from.key == $me or ($pid != "" and (.from.pid // "") == $pid);
def is_holder: .holder != null and (.holder.key == $me or ($pid != "" and (.holder.pid // "") == $pid));
def who: .holder.name // .holder.key;
def take: phase($now) as $p
  | if $p == "closed" then {ticket: null, result: "closed"}
    elif is_filer then {ticket: null, result: "filer"}
    elif is_holder then {ticket: (.holder.taken = true | .holder.key = $me
                                  | if $pid != "" then .holder.pid = $pid else . end), result: "taken"}
    elif $p == "open" or $p == "lapsed" then
      {ticket: (release | .holder = ({key: $me, at: $now, taken: true}
                                      + (if $pid != "" then {pid: $pid} else {} end)
                                      + (if $name != "" then {name: $name} else {} end))), result: "taken"}
    else {ticket: null, result: $p, holder: who} end;
'
# update <id> <filter> [jq args]: cc_ticket_update with this session's identity bound.
update() {
  local id="$1" filter="$2"
  shift 2
  cc_ticket_update "$id" "$RULES $filter" --arg me "$ME" --arg pid "$ME_PID" --arg name "$ME_NAME" \
    --argjson now "$(now)" "$@"
}
ledger() { # <type> <jq object of extra fields>
  cc_ledger_enabled || return 0
  local x="${2:-}"
  [ -n "$x" ] || x='{}'
  cc_ledger_append "$(jq -nc --arg t "$1" --arg key "$ME" --arg cwd "$PWD" --argjson x "$x" \
    '{type:$t, key:$key, session_id:$key, cwd:$cwd} + $x')"
}
# The ticket id argument: t<epoch>-<n>, and there.
ticket_id() {
  ID="${1:-}"
  [ -n "$ID" ] || usage_error "give the ticket's id"
  [[ "$ID" =~ ^t[0-9]+-[0-9]+$ ]] || refuse "'$ID' isn't a ticket id (they look like t1790000000-4242)"
  F="$CC_TICKETS_DIR/$ID.json"
  if [ ! -e "$F" ] && ! compgen -G "$F.claim.*" > /dev/null; then say "❌ cc-ticket: no ticket $ID"; exit 5; fi
}
# The ticket as it stands (from its claim when a writer has it this instant).
snapshot() {
  local c
  cat "$F" 2>/dev/null && return 0
  for c in "$F".claim.*; do [ -f "$c" ] && cat "$c" 2>/dev/null && return 0; done
  return 1
}
# Say what an update that changed nothing came back with, and exit with its code.
refused() { # <update's output> <update's code>
  local res="$1" rc="$2" r h
  case "$rc" in
    2) say "❌ cc-ticket: no ticket $ID"; exit 5 ;;
    3) say "❌ cc-ticket: ticket $ID is busy (another writer has it) -- try again"; exit 2 ;;
  esac
  r="$(printf '%s' "$res" | jq -r '.result // empty' 2>/dev/null)"
  h="$(printf '%s' "$res" | jq -r '.holder // empty' 2>/dev/null)"
  case "$r" in
    closed)  refuse "ticket $ID is closed" ;;
    filer)   not_yours "you filed ticket $ID -- the target repo's session takes it (reply or close it as the filer)" ;;
    held)    not_yours "ticket $ID is held by $h" ;;
    offered) not_yours "ticket $ID is offered to $h -- it comes back if that session doesn't take it within 45 minutes of the offer" ;;
    *)       refuse "couldn't change ticket $ID" ;;
  esac
}
age() { # <epoch> -> "5m", "3h", "2d"
  local s=$(( $(now) - ${1:-0} ))
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 3600 ]; then printf '%sm' $(( s / 60 ))
  elif [ "$s" -lt 172800 ]; then printf '%sh' $(( s / 3600 ))
  else printf '%sd' $(( s / 86400 )); fi
}
# A ticket, for a reader: its title, who filed it for where, where it stands, the body, the replies.
render() { # stdin: the ticket
  jq -r --argjson now "$(now)" --arg age "$1" "$CC_TICKET_JQ"' norm
    | (.to.name // (.to.root | split("/") | last)) as $to
    | (.from.name // (.from.root // "" | split("/") | last)) as $fromrepo
    | (.holder.name // .holder.key // "") as $h
    | phase($now) as $p
    | "Ticket \(.id): \(.title | oneline)",
      "Filed \($age) ago by \(.from.key) in \($fromrepo) for \($to) (\(.to.root)).",
      (if $p == "closed" then "Closed by the \(.closed.by): \(.closed.note | oneline)"
       elif $p == "held" then "Held by \($h)."
       elif $p == "offered" then "Offered to \($h), not taken yet."
       else "Open: nobody has it yet." end),
      (if (.body // "") != "" then "", .body else empty end),
      (if (.thread | length) > 0 then "", "Replies:",
         (.thread[] | "- the \(.by) (\(.key)): \(.text | oneline)") else empty end)'
}

case "$CMD" in
# ---- file ----
file)
  REPO="" TITLE="" BODY="" HAVE_TITLE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--title|--body)
        [ $# -ge 2 ] || usage_error "$1 needs a value"
        case "$1" in --repo) REPO="$2" ;; --title) TITLE="$2"; HAVE_TITLE=1 ;; --body) BODY="$2" ;; esac
        shift 2 ;;
      --repo=*) REPO="${1#--repo=}"; shift ;;
      --title=*) TITLE="${1#--title=}"; HAVE_TITLE=1; shift ;;
      --body=*) BODY="${1#--body=}"; shift ;;
      *) usage_error "unknown option for file: $1" ;;
    esac
  done
  [ -n "$REPO" ] || usage_error "give the repo the work is for: --repo <its root or name>"
  [ "$HAVE_TITLE" = 1 ] || usage_error "give the work a title: --title \"...\""
  [[ "$TITLE" =~ [[:cntrl:]] ]] && refuse "the title must be one line"
  TITLE="$(trim "$TITLE")"
  [ -n "$TITLE" ] || refuse "the title is empty"
  [ "${#TITLE}" -le "$TITLE_MAX" ] || refuse "the title is longer than $TITLE_MAX characters"
  BODY="$(trim "$BODY")"
  [ "$(bytes "$BODY")" -le "$BODY_MAX" ] || refuse "the body is $(bytes "$BODY") bytes; at most $BODY_MAX go in a ticket (point at a file for more)"
  [[ "$REPO" =~ [[:cntrl:]] ]] && refuse "--repo holds a control character"

  # A folder's repo: its main checkout's root (a worktree's too), or -- not a git repo -- the folder.
  repo_root() {
    local d common top
    d="$(cd -- "$1" 2>/dev/null && pwd -P)" || return 1
    common="$(cd -- "$d" && git rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$common" ]; then
      common="$(cd -- "$d" && cd -- "$common" 2>/dev/null && pwd -P)"
      case "$common" in */.git) printf '%s' "${common%/.git}"; return 0 ;; esac
      top="$(cd -- "$d" && git rev-parse --show-toplevel 2>/dev/null)"
      [ -n "$top" ] && { printf '%s' "$top"; return 0; }
    fi
    printf '%s' "$d"
  }
  case "$REPO" in
    */*|.|..|"~"|"~/"*)
      p="$REPO"
      case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#"~/"}" ;; esac
      [ -d "$p" ] || refuse "no such folder: $p"
      TO="$(repo_root "$p")" || refuse "can't enter $p"
      ;;
    *)
      # a name: the repos of the sessions Shepherd knows (their status files' folders), by folder name
      want="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
      MATCHES=""
      while IFS= read -r cwd; do
        [ -n "$cwd" ] && [ -d "$cwd" ] || continue
        r="$(repo_root "$cwd")" || continue
        [ "$(printf '%s' "${r##*/}" | tr '[:upper:]' '[:lower:]')" = "$want" ] || continue
        case $'\n'"$MATCHES"$'\n' in *$'\n'"$r"$'\n'*) ;; *) MATCHES="$MATCHES${MATCHES:+$'\n'}$r" ;; esac
      done < <(jq -r '.cwd // empty | select(type == "string")' "$CC_DIR"/*.json 2>/dev/null | sort -u)
      n="$(printf '%s' "$MATCHES" | grep -c .)"
      if [ "$n" -eq 0 ]; then refuse "no repo called '$REPO' among the sessions Shepherd knows -- give its root (a path)"; fi
      if [ "$n" -gt 1 ]; then
        say "❌ cc-ticket: '$REPO' names $n repos -- give the root of the one you mean:"
        printf '%s\n' "$MATCHES" | sed 's/^/   - /' >&2
        exit 2
      fi
      TO="$MATCHES"
      ;;
  esac
  MINE="$(repo_root "$PWD")"
  [ "$TO" != "$MINE" ] || refuse "$TO is this session's own repo -- a ticket is work for ANOTHER repo's sessions (hand one of your own a prompt with cc-send.sh)"

  NOW="$(now)"
  ID="t$NOW-$$$RANDOM"
  mkdir -p "$CC_TICKETS_DIR" 2>/dev/null && chmod 700 "$CC_TICKETS_DIR" 2>/dev/null
  TMP="$CC_TICKETS_DIR/$ID.json.tmp.$$"
  if ! jq -n --arg id "$ID" --arg title "$TITLE" --arg body "$BODY" --arg me "$ME" --arg pid "$ME_PID" \
       --arg cwd "$PWD" --arg mine "$MINE" --arg to "$TO" --argjson now "$NOW" '
       { v: 1, id: $id, title: $title, body: $body,
         from: ({ key: $me, cwd: $cwd, root: $mine, name: ($mine | split("/") | last) }
                + (if $pid != "" then { pid: $pid } else {} end)),
         to: { root: $to, name: ($to | split("/") | last) },
         filed: $now, holder: null, passed: [], thread: [], closed: null }' > "$TMP" 2>/dev/null \
     || ! mv "$TMP" "$CC_TICKETS_DIR/$ID.json"; then
    rm -f "$TMP"
    refuse "couldn't write the ticket in $CC_TICKETS_DIR"
  fi
  ledger ticket_filed "$(jq -nc --arg id "$ID" --arg to "$TO" '{ticket:$id, repo:$to}')"
  printf '%s\n' "$ID"
  say "📮 Filed $ID for ${TO##*/} ($TO). Shepherd offers it to a live session there -- an idle one before a busy one, never one waiting on Adam; with none, it waits on that repo's card."
  say "   Replies and the close reach you through your mailbox (or at your next start); '$CMD_PATH wait $ID' in the background blocks until one comes."
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  if [ -z "$hb" ] || [ $(( $(date +%s) - hb )) -gt "$PANEL_MAX_AGE" ]; then
    say "⚠️ Shepherd isn't running, so nothing offers the ticket yet -- it waits in $CC_TICKETS_DIR until Shepherd runs."
  fi
  exit 0
  ;;

# ---- take ----
take)
  [ $# -le 1 ] || usage_error "take takes just the ticket's id"
  ticket_id "${1:-}"
  RES="$(update "$ID" 'take')"; rc=$?
  [ "$rc" -eq 0 ] || refused "$RES" "$rc"
  ledger ticket_taken "$(jq -nc --arg id "$ID" '{ticket:$id}')"
  snapshot | render "$(age "$(snapshot | jq -r '.filed // 0')")"
  say "✅ Ticket $ID is yours. Reply as you go: $CMD_PATH reply $ID \"...\"; close it with $CMD_PATH close $ID --note \"what you did\"."
  ;;

# ---- reply ----
reply)
  [ $# -eq 2 ] || usage_error "reply takes the ticket's id and the text, quoted"
  ticket_id "$1"
  TEXT="$(trim "$2")"
  [ -n "$TEXT" ] || refuse "the reply is empty"
  [ "$(bytes "$TEXT")" -le "$REPLY_MAX" ] || refuse "the reply is $(bytes "$TEXT") bytes; at most $REPLY_MAX"
  RES="$(update "$ID" '
    if phase($now) == "closed" then {ticket: null, result: "closed"}
    elif is_filer then {ticket: (.thread += [{by: "filer", key: $me, text: $text, at: $now, told: false}]), result: "replied", role: "filer"}
    else (.holder == null or (is_holder and (.holder.taken | not))) as $took | take as $r
      | if $r.ticket == null then $r
        else {ticket: ($r.ticket | .thread += [{by: "holder", key: $me, text: $text, at: $now, told: false}]),
              result: "replied", role: "holder", took: $took} end end' --arg text "$TEXT")"; rc=$?
  [ "$rc" -eq 0 ] || refused "$RES" "$rc"
  ROLE="$(printf '%s' "$RES" | jq -r '.role')"
  ledger ticket_reply "$(printf '%s' "$RES" | jq -c --arg id "$ID" '{ticket:$id, role:.role} + (if .took then {took:true} else {} end)')"
  if [ "$ROLE" = filer ]; then say "📨 Replied on $ID -- the session holding it gets it (or the next one it's offered to)."
  else say "📨 Replied on $ID -- the filer gets it. Close it with $CMD_PATH close $ID --note \"...\" when you're done."; fi
  ;;

# ---- close ----
close)
  [ $# -ge 1 ] || usage_error "close takes the ticket's id and --note \"what happened\""
  ticket_id "$1"
  shift
  NOTE="" HAVE_NOTE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) [ $# -ge 2 ] || usage_error "--note needs a value"; NOTE="$2"; HAVE_NOTE=1; shift 2 ;;
      --note=*) NOTE="${1#--note=}"; HAVE_NOTE=1; shift ;;
      *) usage_error "unknown option for close: $1" ;;
    esac
  done
  [ "$HAVE_NOTE" = 1 ] || refuse "closing needs a note: --note \"what you did, or why it isn't this repo's to do\""
  NOTE="$(trim "$NOTE")"
  [ -n "$NOTE" ] || refuse "the note is empty -- say what you did, or why not"
  [ "$(bytes "$NOTE")" -le "$NOTE_MAX" ] || refuse "the note is $(bytes "$NOTE") bytes; at most $NOTE_MAX"
  RES="$(update "$ID" '
    if phase($now) == "closed" then {ticket: null, result: "closed"}
    elif is_filer then {ticket: (.closed = {by: "filer", key: $me, note: $note, at: $now,
                                           told: (if .holder == null then "none" else false end)}), result: "closed-it", role: "filer"}
    else (.holder == null or (is_holder and (.holder.taken | not))) as $took | take as $r
      | if $r.ticket == null then $r
        else {ticket: ($r.ticket | .closed = {by: "holder", key: $me, note: $note, at: $now, told: false}),
              result: "closed-it", role: "holder", took: $took} end end' --arg note "$NOTE")"; rc=$?
  [ "$rc" -eq 0 ] || refused "$RES" "$rc"
  ledger ticket_closed "$(printf '%s' "$RES" | jq -c --arg id "$ID" '{ticket:$id, role:.role} + (if .took then {took:true} else {} end)')"
  if [ "$(printf '%s' "$RES" | jq -r '.role')" = filer ]; then say "✅ Closed $ID -- the session holding it (if any) is told to stop."
  else say "✅ Closed $ID -- the filer gets your note."; fi
  ;;

# ---- wait ----
wait)
  [ $# -ge 1 ] || usage_error "wait takes the ticket's id"
  ticket_id "$1"
  shift
  TIMEOUT=3600
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] || usage_error "--timeout takes whole seconds"; TIMEOUT="$2"; shift 2 ;;
      --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
      *) usage_error "unknown option for wait: $1" ;;
    esac
  done
  case "$TIMEOUT" in ''|*[!0-9]*) usage_error "--timeout takes whole seconds" ;; esac
  [ "$TIMEOUT" -gt 0 ] || usage_error "--timeout takes whole seconds (at least 1)"
  ROLE="$(snapshot | jq -r --arg me "$ME" --arg pid "$ME_PID" --arg name "" --argjson now "$(now)" \
    "$CC_TICKET_JQ $RULES"' norm | if is_filer then "filer" elif is_holder then "holder" else "" end' 2>/dev/null)"
  [ -n "$ROLE" ] || not_yours "ticket $ID isn't yours to wait on (you neither filed nor hold it)"
  WAIT_PID="$$"
  # Registered on the ticket, so Shepherd leaves this side's news to the waiter instead of the mailbox.
  update "$ID" '{ticket: (.waiting = ((.waiting // {}) + {($role): {pid: $wpid, at: $now}}))}' \
    --arg role "$ROLE" --arg wpid "$WAIT_PID" > /dev/null
  unregister() {
    update "$ID" 'if (.waiting // {})[$role].pid == $wpid then {ticket: (.waiting |= del(.[$role]))} else {ticket: null} end' \
      --arg role "$ROLE" --arg wpid "$WAIT_PID" > /dev/null 2>&1
  }
  trap 'unregister' EXIT
  trap 'exit 130' INT TERM HUP
  say "⏳ Waiting on ticket $ID (up to ${TIMEOUT}s) for $( [ "$ROLE" = filer ] && echo "the holder's reply or its close" || echo "the filer's reply" )..."
  SECONDS=0
  while :; do
    S="$(snapshot)"
    if [ -n "$S" ]; then
      if [ "$(printf '%s' "$S" | jq -r --arg r "$ROLE" "$CC_TICKET_JQ"' norm | hasnews($r)' 2>/dev/null)" = true ]; then
        RES="$(update "$ID" 'if hasnews($role) then {ticket: (tell($role; "wait") | if (.waiting // {})[$role].pid == $wpid then .waiting |= del(.[$role]) else . end),
                                                      text: newstext($role)} else {ticket: null} end' \
          --arg role "$ROLE" --arg wpid "$WAIT_PID")"
        if [ -n "$RES" ] && [ "$(printf '%s' "$RES" | jq -r '.ticket != null' 2>/dev/null)" = true ]; then
          printf '%s\n' "$(printf '%s' "$RES" | jq -r '.text')"
          say "✅ News on $ID."
          exit 0
        fi
      elif [ "$(printf '%s' "$S" | jq -r '(.closed | type) == "object"' 2>/dev/null)" = true ]; then
        printf '%s\n' "$(printf '%s' "$S" | jq -r --arg r "$ROLE" '"Ticket \(.id) is closed (by \(if .closed.by == $r then "you" else "the " + .closed.by end)): \(.closed.note)"')"
        exit 0
      fi
    fi
    [ "$SECONDS" -lt "$TIMEOUT" ] || { say "⌛ cc-ticket: nothing new on $ID in ${TIMEOUT}s."; exit 4; }
    sleep "$POLL"
  done
  ;;

# ---- show, list ----
show)
  [ $# -eq 1 ] || usage_error "show takes the ticket's id"
  ticket_id "$1"
  S="$(snapshot)" || { say "❌ cc-ticket: no ticket $ID"; exit 5; }
  printf '%s' "$S" | render "$(age "$(printf '%s' "$S" | jq -r '.filed // 0')")"
  ;;
list)
  [ $# -eq 0 ] || usage_error "list takes nothing"
  ROOT="$(cd -- "$PWD" && git rev-parse --git-common-dir 2>/dev/null)"
  ROOT="$( [ -n "$ROOT" ] && cd -- "$ROOT" 2>/dev/null && pwd -P)"
  ROOT="${ROOT%/.git}"
  [ -n "$ROOT" ] || ROOT="$(pwd -P)"
  OUT=""
  for f in "$CC_TICKETS_DIR"/t*.json; do
    [ -f "$f" ] || continue
    line="$(jq -r --arg me "$ME" --arg pid "$ME_PID" --arg name "" --arg root "$ROOT" --argjson now "$(now)" \
      "$CC_TICKET_JQ $RULES"' norm | phase($now) as $p
      | select(is_filer or is_holder or (.to.root == $root and ($p == "open" or $p == "lapsed" or $p == "offered")))
      | "\(.id)  \($p | if . == "lapsed" then "open" else . end)  \(.title | oneline)  (\(if is_filer then "you filed it" elif is_holder then "you hold it" else "waiting for this repo" end))"' "$f" 2>/dev/null)"
    [ -n "$line" ] && OUT="$OUT$line"$'\n'
  done
  if [ -z "$OUT" ]; then say "No tickets filed by, held by or waiting for this session."; exit 0; fi
  printf '%s' "$OUT"
  ;;
*)
  usage_error "unknown command: $CMD"
  ;;
esac
