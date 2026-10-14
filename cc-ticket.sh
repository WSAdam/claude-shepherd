#!/usr/bin/env bash
# cc-ticket.sh - file work for ANOTHER repo's sessions, and get the reply back -- every word that
# crosses approved by Adam first (build program unit 29, 2026-09-29; crossings 2026-10-14).
#
#   cc-ticket.sh file --repo <root|name> --title "<T>" [--body "<B>"]   prints the new ticket's id
#   cc-ticket.sh take <id>                     take a ticket offered to you (or an open one); prints it
#   cc-ticket.sh reply <id> "<text>"           to the other side (a reply takes an open ticket first)
#   cc-ticket.sh close <id> --note "<note>"    closing always says what happened
#   cc-ticket.sh wait <id> [--timeout <s>]     run it in the BACKGROUND: blocks until a reply or the close
#   cc-ticket.sh show <id>                     the whole ticket
#   cc-ticket.sh list                          the tickets this session filed, holds, or its repo waits on
#
# 2026-10-14 (Adam: "projects should not be able to utilize having shepherd to talk to each other,
# that needs to be an approved translation between the two rather than something automatic"): what
# a session writes for the other repo -- the filing, every reply, a close note -- is left as a request
# in ~/.claude/cc-cross/ (cc_cross_request). Adam sees it on the session's card in Shepherd, may edit
# it, and approves or denies it; only Shepherd publishes the approved text into the ticket
# (~/.claude/cc-tickets/<id>.json). A Deny's note reaches the session through its mailbox (or at its
# next start). Taking a ticket carries no text, so it happens at once.
#
# Once published, Shepherd offers a ticket to the target repo's least-busy live session (never one
# waiting on you), through that session's mailbox. The session takes it (take, reply or close)
# within 45 minutes, or it goes to another session; a ticket whose holder's session ends goes back
# too. With no session to take it, it shows on that repo's card in Shepherd with "Open a tab for
# it". Replies and the close come back to the other side the same way -- through its mailbox, at its
# next start, or from a `wait` running in the background. A ticket is only ever taken or shown by
# its filer, its holder, or a session of the repo it's for: a session's repo is where it LAUNCHED
# (cc_session_project), not where it has cd'd to. Every change claims the ticket's file with mv
# first (cc_ticket_update in cc-lib.sh), so two writers never both win.
#
# Only what a script wants goes to stdout (the id, the ticket, the news); everything else to stderr.
# Exit codes: 0 done; 2 refused (the arguments, a closed ticket, your own repo); 3 not yours (held
# by or offered to another session, you filed it, or another repo's); 4 wait ran out; 5 no such ticket.
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

File work for ANOTHER repo's sessions. Adam approves every word that crosses -- the filing, each
reply, the close note -- on this session's card in Shepherd first, and may edit it; nothing reaches
the other repo before he does. Don't resend or route around a held one. Once he passes a filing,
Shepherd offers the ticket to that repo's least-busy live session, which takes it (take, reply or
close) within 45 minutes or it goes to another session; with no session there, it waits on the
repo's card ("Open a tab for it"). Replies and the close come back through your mailbox, at your
next start, or from `wait` -- run that in the background: it prints the next reply or the close.
Closing always needs a note. --repo is a repo's root (or any folder in it, or a worktree) or its
name. Must run inside a Claude Code session (CLAUDE_CODE_SESSION_ID).
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
# This session's project: the repo it launched in (cc_session_project), else -- a session Shepherd
# doesn't know yet -- the repo of the folder it runs in. Cached for the run.
MY_PROJECT=""
my_project() {
  [ -n "$MY_PROJECT" ] || MY_PROJECT="$(cc_session_project "$ME" 2>/dev/null)"
  [ -n "$MY_PROJECT" ] || MY_PROJECT="$(cc_repo_root "$PWD" 2>/dev/null)"
  printf '%s' "$MY_PROJECT"
}
# my_filing <id>: this session's filing of ticket <id> that isn't a published ticket: "<state> <file>"
# (state pending | approved | denied | withdrawn | void), or nothing.
my_filing() {
  local st kind k p file
  while IFS=' ' read -r st kind k p file; do
    [ "$kind" = ticket ] || continue
    if [ "$k" = "$ME" ] || { [ -n "$ME_PID" ] && [ "$p" = "$ME_PID" ]; }; then printf '%s %s' "$st" "$file"; return 0; fi
  done <<EOF
$(cc_cross_for_ticket "$1")
EOF
  return 1
}
# Does a close for ticket <id> wait for Adam (anyone's)?
closing_waits() {
  local st kind rest
  while IFS=' ' read -r st kind rest; do
    [ "$kind" = ticket-close ] && [ "$st" = pending ] && return 0
  done <<EOF
$(cc_cross_for_ticket "$1")
EOF
  return 1
}
# Leave Adam a request (cc_cross_request), or refuse. Prints the cid.
cross() { # <json object of the kind's fields>
  cc_cross_request "$ME" "$ME_PID" "$1" || refuse "couldn't leave the request for Adam in $CC_CROSS_DIR"
}
held() { # <what> <where>
  say "⏸ Held for Adam: $1 reaches nobody in $2 until he approves it on this session's card in Shepherd -- he may edit it first."
  say "   Don't resend it or route around Shepherd. If he denies it, his note reaches you through your mailbox."
}
# The ticket id argument: t<epoch>-<n>, and there -- a published ticket (cc-lib.sh's `published`),
# or this session's own filing that Adam hasn't passed yet (FILING: "<state> <file>").
ticket_id() {
  ID="${1:-}"
  [ -n "$ID" ] || usage_error "give the ticket's id"
  [[ "$ID" =~ ^t[0-9]+-[0-9]+$ ]] || refuse "'$ID' isn't a ticket id (they look like t1790000000-4242)"
  F="$CC_TICKETS_DIR/$ID.json"
  FILING=""
  # cc_ticket_there, not one look at the file and one at its claims: a writer can put the file
  # back between the two (2026-09-30, the six-way take).
  if cc_ticket_there "$ID" && [ "$(snapshot | jq -r "$CC_TICKET_JQ"' published' 2>/dev/null)" = true ]; then return 0; fi
  FILING="$(my_filing "$ID")" && return 0
  say "❌ cc-ticket: no ticket $ID"; exit 5
}
# Commands that need the published ticket refuse a filing Adam hasn't passed.
need_ticket() {
  [ -n "$FILING" ] || return 0
  case "${FILING%% *}" in
    pending|approved) refuse "ticket $ID is still waiting for Adam's approval -- it can't take that until he passes it" ;;
    *) refuse "ticket $ID was never filed -- Adam didn't pass it on (his note reached your mailbox)" ;;
  esac
}
# The ticket as it stands (from its claim when a writer has it this instant). A writer can put the
# file back between the two reads, so they are tried again before giving up (as cc_ticket_there).
snapshot() {
  local c n
  for n in 1 2 3; do
    cat "$F" 2>/dev/null && return 0
    for c in "$F".claim.*; do [ -f "$c" ] && cat "$c" 2>/dev/null && return 0; done
    [ "$n" = 3 ] || sleep 0.05
  done
  return 1
}
# Who this session is to ticket JSON $1: filer | holder (offered or taken) | "".
role_of() {
  printf '%s' "$1" | jq -r --arg me "$ME" --arg pid "$ME_PID" --arg name "" --argjson now "$(now)" \
    "$CC_TICKET_JQ $RULES"' norm | if is_filer then "filer" elif is_holder then "holder" else "" end' 2>/dev/null
}
# Is this session one of the repo ticket JSON $1 is for? (Its launch project, not where it cd'd.)
in_target_repo() {
  local root mine
  root="$(printf '%s' "$1" | jq -r '.to.root // empty' 2>/dev/null)"
  mine="$(my_project)"
  [ -n "$root" ] && [ -n "$mine" ] && [ "$root" = "$mine" ]
}
target_name() { printf '%s' "$1" | jq -r '.to.name // (.to.root | split("/") | last)' 2>/dev/null; }
other_name() { # <ticket json> <role>: the repo a reply or close from <role> goes to
  if [ "$2" = holder ]; then printf '%s' "$1" | jq -r '.from.name // (.from.root // "" | split("/") | last)' 2>/dev/null
  else target_name "$1"; fi
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
# Take ticket JSON $1 for this session before it writes on it (a reply or close takes an open
# ticket first): only a session it is offered to, or one of the repo it's for, and never while a
# close waits for Adam. Sets TOOK. Taking carries no text, so it happens at once.
take_it() {
  local res rc
  TOOK=""
  if [ "$(role_of "$1")" != holder ]; then
    in_target_repo "$1" || not_yours "ticket $ID is for $(target_name "$1") -- only a session of that repo can take it"
    closing_waits "$ID" && not_yours "a close for ticket $ID is waiting for Adam -- nobody takes it meanwhile"
  fi
  res="$(update "$ID" '(.holder == null or (is_holder and (.holder.taken | not))) as $took | take | . + {took: $took}')"; rc=$?
  [ "$rc" -eq 0 ] || refused "$res" "$rc"
  [ "$(printf '%s' "$res" | jq -r '.took' 2>/dev/null)" = true ] && TOOK=1
  return 0
}
age() { # <epoch> -> "5m", "3h", "2d"
  local s=$(( $(now) - ${1:-0} ))
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 3600 ]; then printf '%sm' $(( s / 60 ))
  elif [ "$s" -lt 172800 ]; then printf '%sh' $(( s / 3600 ))
  else printf '%sd' $(( s / 86400 )); fi
}
# A ticket, for a reader: its title, who filed it for where, where it stands, the body, the replies.
# A close note that went to nobody (the filer's, with nobody holding the ticket) is the filer's alone.
render() { # <age> <viewer role>; stdin: the ticket
  jq -r --argjson now "$(now)" --arg age "$1" --arg viewer "${2:-}" "$CC_TICKET_JQ"' norm
    | (.to.name // (.to.root | split("/") | last)) as $to
    | (.from.name // (.from.root // "" | split("/") | last)) as $fromrepo
    | (.holder.name // .holder.key // "") as $h
    | phase($now) as $p
    | "Ticket \(.id): \(.title | oneline)\(edited)",
      "Filed \($age) ago by \(.from.key) in \($fromrepo) for \($to) (\(.to.root)).",
      (if $p == "closed" then
         (if .closed.told == "none" and $viewer != "filer" then "Closed by the \(.closed.by)."
          else "Closed by the \(.closed.by): \(.closed.note | oneline)\(.closed | edited)" end)
       elif $p == "held" then "Held by \($h)."
       elif $p == "offered" then "Offered to \($h), not taken yet."
       else "Open: nobody has it yet." end),
      (if (.body // "") != "" then "", .body else empty end),
      (if (.thread | length) > 0 then "", "Replies:",
         (.thread[] | "- the \(.by) (\(.key)): \(.text | oneline)\(edited)") else empty end)'
}
# This session's crossings on ticket $ID that still wait for Adam, one line each (for show).
my_waiting() {
  local st kind k p file
  while IFS=' ' read -r st kind k p file; do
    [ "$st" = pending ] || continue
    if [ "$k" = "$ME" ] || { [ -n "$ME_PID" ] && [ "$p" = "$ME_PID" ]; }; then
      case "$kind" in
        ticket-reply) printf -- '- your reply, waiting for Adam: %s\n' "$(jq -r '.original.text // .text // ""' "$file" 2>/dev/null | tr '\n' ' ')" ;;
        ticket-close) printf -- '- your close note, waiting for Adam: %s\n' "$(jq -r '.original.note // .note // ""' "$file" 2>/dev/null | tr '\n' ' ')" ;;
      esac
    fi
  done <<EOF
$(cc_cross_for_ticket "$ID")
EOF
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
  [ "$(bytes "$TITLE")" -le "$TITLE_MAX" ] || refuse "the title is longer than $TITLE_MAX bytes"
  BODY="$(trim "$BODY")"
  [ "$(bytes "$BODY")" -le "$BODY_MAX" ] || refuse "the body is $(bytes "$BODY") bytes; at most $BODY_MAX go in a ticket (point at a file for more)"
  [[ "$REPO" =~ [[:cntrl:]] ]] && refuse "--repo holds a control character"

  case "$REPO" in
    */*|.|..|"~"|"~/"*)
      p="$REPO"
      case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#"~/"}" ;; esac
      [ -d "$p" ] || refuse "no such folder: $p"
      TO="$(cc_repo_root "$p")" || refuse "can't enter $p"
      ;;
    *)
      # a name: the repos of the sessions Shepherd knows (their status files' folders), by folder name
      want="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
      MATCHES=""
      while IFS= read -r cwd; do
        [ -n "$cwd" ] && [ -d "$cwd" ] || continue
        r="$(cc_repo_root "$cwd")" || continue
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
  MINE="$(my_project)"
  [ "$TO" != "$MINE" ] && [ "$TO" != "$(cc_repo_root "$PWD")" ] \
    || refuse "$TO is this session's own repo -- a ticket is work for ANOTHER repo's sessions (hand one of your own a prompt with cc-send.sh)"

  ID="t$(now)-$$$RANDOM"
  FIELDS="$(jq -nc --arg id "$ID" --arg title "$TITLE" --arg body "$BODY" --arg mine "$MINE" --arg to "$TO" \
    '{kind: "ticket", ticket: $id, title: $title, body: $body,
      to: {root: $to, name: ($to | split("/") | last)},
      from: {root: $mine, name: ($mine | split("/") | last)}}')"
  CID="$(cross "$FIELDS")"
  ledger crossing_requested "$(jq -nc --arg id "$ID" --arg to "$TO" --arg cid "$CID" '{kind:"ticket", ticket:$id, repo:$to, cid:$cid}')"
  printf '%s\n' "$ID"
  held "ticket $ID" "${TO##*/} ($TO)"
  say "   Once he passes it, Shepherd offers it to a live session there -- an idle one before a busy one, never one waiting on Adam; with none, it waits on that repo's card."
  say "   Replies and the close reach you through your mailbox (or at your next start), each approved by Adam too; '$CMD_PATH wait $ID' in the background blocks until one comes."
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  if [ -z "$hb" ] || [ $(( $(date +%s) - hb )) -gt "$PANEL_MAX_AGE" ]; then
    say "⚠️ Shepherd isn't running, so Adam can't see it yet -- it waits in $CC_CROSS_DIR until Shepherd runs."
  fi
  exit 0
  ;;

# ---- take ----
take)
  [ $# -le 1 ] || usage_error "take takes just the ticket's id"
  ticket_id "${1:-}"
  need_ticket
  S="$(snapshot)"
  [ "$(role_of "$S")" = filer ] && not_yours "you filed ticket $ID -- the target repo's session takes it (reply or close it as the filer)"
  take_it "$S"
  ledger ticket_taken "$(jq -nc --arg id "$ID" '{ticket:$id}')"
  snapshot | render "$(age "$(snapshot | jq -r '.filed // 0')")" holder
  say "✅ Ticket $ID is yours. Reply as you go: $CMD_PATH reply $ID \"...\"; close it with $CMD_PATH close $ID --note \"what you did\". Adam approves each before the filer sees it."
  ;;

# ---- reply ----
reply)
  [ $# -eq 2 ] || usage_error "reply takes the ticket's id and the text, quoted"
  ticket_id "$1"
  need_ticket
  TEXT="$(trim "$2")"
  [ -n "$TEXT" ] || refuse "the reply is empty"
  [ "$(bytes "$TEXT")" -le "$REPLY_MAX" ] || refuse "the reply is $(bytes "$TEXT") bytes; at most $REPLY_MAX"
  S="$(snapshot)"
  [ "$(printf '%s' "$S" | jq -r --argjson now "$(now)" "$CC_TICKET_JQ"' norm | phase($now)')" != closed ] || refuse "ticket $ID is closed"
  ROLE="$(role_of "$S")" TOOK=""
  if [ "$ROLE" != filer ]; then take_it "$S"; ROLE=holder; S="$(snapshot)"; fi
  CID="$(cross "$(jq -nc --arg id "$ID" --arg role "$ROLE" --arg text "$TEXT" '{kind:"ticket-reply", ticket:$id, role:$role, text:$text}')")"
  ledger crossing_requested "$(jq -nc --arg id "$ID" --arg role "$ROLE" --arg cid "$CID" --arg took "$TOOK" \
    '{kind:"ticket-reply", ticket:$id, role:$role, cid:$cid} + (if $took != "" then {took:true} else {} end)')"
  [ -z "$TOOK" ] || say "✅ Ticket $ID is yours now."
  held "your reply on $ID" "$(other_name "$S" "$ROLE")"
  [ "$ROLE" = filer ] || say "   Close it with $CMD_PATH close $ID --note \"...\" when you're done."
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
  # the filer's own filing, still waiting for Adam: withdrawn (nothing ever crossed)
  if [ -n "$FILING" ]; then
    case "${FILING%% *}" in
      pending|approved)
        CID="$(cross "$(jq -nc --arg id "$ID" '{kind:"withdraw", ticket:$id}')")"
        ledger crossing_requested "$(jq -nc --arg id "$ID" --arg cid "$CID" '{kind:"withdraw", ticket:$id, cid:$cid}')"
        say "✅ Withdrew $ID before Adam passed it on -- nothing reached the other repo."
        exit 0 ;;
      *) refuse "ticket $ID was never filed -- nothing to close" ;;
    esac
  fi
  S="$(snapshot)"
  [ "$(printf '%s' "$S" | jq -r --argjson now "$(now)" "$CC_TICKET_JQ"' norm | phase($now)')" != closed ] || refuse "ticket $ID is closed"
  ROLE="$(role_of "$S")" TOOK=""
  if [ "$ROLE" = filer ] && [ "$(printf '%s' "$S" | jq -r '.holder == null')" = true ]; then
    # nobody holds it: the note goes to no one, so nothing crosses -- closed at once, the note private
    RES="$(update "$ID" 'if phase($now) == "closed" then {ticket: null, result: "closed"}
      elif is_filer and .holder == null then {ticket: (.closed = {by: "filer", key: $me, note: $note, at: $now, told: "none"}), result: "closed-it"}
      else {ticket: null, result: "held"} end' --arg note "$NOTE")"; rc=$?
    if [ "$rc" -eq 0 ]; then
      ledger ticket_closed "$(jq -nc --arg id "$ID" '{ticket:$id, role:"filer"}')"
      say "✅ Closed $ID -- nobody held it, so nothing went to the other repo."
      exit 0
    fi
    [ "$(printf '%s' "$RES" | jq -r '.result // empty' 2>/dev/null)" = held ] || refused "$RES" "$rc"
    S="$(snapshot)"   # someone took it meanwhile: the note crosses, so it waits for Adam
  fi
  if [ "$ROLE" != filer ]; then take_it "$S"; ROLE=holder; S="$(snapshot)"; fi
  CID="$(cross "$(jq -nc --arg id "$ID" --arg role "$ROLE" --arg note "$NOTE" '{kind:"ticket-close", ticket:$id, role:$role, note:$note}')")"
  ledger crossing_requested "$(jq -nc --arg id "$ID" --arg role "$ROLE" --arg cid "$CID" --arg took "$TOOK" \
    '{kind:"ticket-close", ticket:$id, role:$role, cid:$cid} + (if $took != "" then {took:true} else {} end)')"
  held "your close note on $ID" "$(other_name "$S" "$ROLE")"
  [ "$ROLE" = filer ] && say "   Once he passes it, the session holding it is told to stop." \
    || say "   Once he passes it, the ticket closes and the filer gets your note. Stop work on it."
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
  SECONDS=0
  # the filer's own filing, still waiting for Adam: wait for his decision first
  if [ -n "$FILING" ]; then
    say "⏳ Ticket $ID waits for Adam's approval (up to ${TIMEOUT}s here)..."
    while :; do
      case "${FILING%% *}" in
        denied)    printf 'Ticket %s was not filed: Adam didn'"'"'t pass it on (his note reaches you through your mailbox).\n' "$ID"; exit 0 ;;
        withdrawn) printf 'Ticket %s was withdrawn before it was filed.\n' "$ID"; exit 0 ;;
        void)      printf 'Ticket %s was not filed.\n' "$ID"; exit 0 ;;
      esac
      if cc_ticket_there "$ID" && [ "$(snapshot | jq -r "$CC_TICKET_JQ"' published' 2>/dev/null)" = true ]; then
        say "✅ Adam passed ticket $ID on -- now waiting for news on it."
        FILING=""
        break
      fi
      [ "$SECONDS" -lt "$TIMEOUT" ] || { say "⌛ cc-ticket: Adam hasn't decided on $ID in ${TIMEOUT}s."; exit 4; }
      sleep "$POLL"
      FILING="$(my_filing "$ID")" || FILING="pending -"
    done
  fi
  ROLE="$(role_of "$(snapshot)")"
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
        printf '%s\n' "$(printf '%s' "$S" | jq -r --arg r "$ROLE" '"Ticket \(.id) is closed (by \(if .closed.by == $r then "you" else "the " + .closed.by end))"
          + (if .closed.told == "none" and .closed.by != $r then "." else ": \(.closed.note)" end)')"
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
  if [ -n "$FILING" ]; then
    FFILE="${FILING#* }"
    case "${FILING%% *}" in
      pending|approved) STATE="not filed yet: waiting for Adam's approval" ;;
      denied) STATE="not filed: Adam didn't pass it on" ;;
      withdrawn) STATE="withdrawn before it was filed" ;;
      *) STATE="not filed" ;;
    esac
    jq -r --arg state "$STATE" '(.original // .) as $o
      | "Ticket \(.ticket) (\($state)): \($o.title // "")", "For \(.to.name // (.to.root // "" | split("/") | last)) (\(.to.root // "")).",
        (if ($o.body // "") != "" then "", $o.body else empty end)' "$FFILE"
    exit 0
  fi
  S="$(snapshot)" || { say "❌ cc-ticket: no ticket $ID"; exit 5; }
  ROLE="$(role_of "$S")"
  [ -n "$ROLE" ] || in_target_repo "$S" || not_yours "ticket $ID is between other repos -- only its filer, its holder or a session of $(target_name "$S") sees it"
  printf '%s' "$S" | render "$(age "$(printf '%s' "$S" | jq -r '.filed // 0')")" "$ROLE"
  W="$(my_waiting)"
  [ -z "$W" ] || printf '\n%s' "$W"
  ;;
list)
  [ $# -eq 0 ] || usage_error "list takes nothing"
  ROOT="$(my_project)"
  OUT=""
  for f in "$CC_TICKETS_DIR"/t*.json; do
    [ -f "$f" ] || continue
    line="$(jq -r --arg me "$ME" --arg pid "$ME_PID" --arg name "" --arg root "$ROOT" --argjson now "$(now)" \
      "$CC_TICKET_JQ $RULES"' norm | select(published) | phase($now) as $p
      | select(is_filer or is_holder or (.to.root == $root and ($p == "open" or $p == "lapsed" or $p == "offered")))
      | "\(.id)  \($p | if . == "lapsed" then "open" else . end)  \(.title | oneline)  (\(if is_filer then "you filed it" elif is_holder then "you hold it" else "waiting for this repo" end))"' "$f" 2>/dev/null)"
    [ -n "$line" ] && OUT="$OUT$line"$'\n'
  done
  # this session's filings that wait for Adam (no ticket yet)
  for f in "$CC_CROSS_DIR"/*.json; do
    [ -f "$f" ] || continue
    line="$(jq -r --arg me "$ME" --arg pid "$ME_PID" 'select(.kind == "ticket" and ((.state // "pending") == "pending" or .state == "approved")
        and (.from.key == $me or ($pid != "" and (.from.pid // "") == $pid)))
      | "\(.ticket)  waiting for Adam  \((.original.title // .title // "") | gsub("[[:cntrl:]]+"; " "))  (you filed it)"' "$f" 2>/dev/null)"
    [ -n "$line" ] || continue
    case "$OUT" in *"${line%%  *}  "*) continue ;; esac
    [ -f "$CC_TICKETS_DIR/${line%%  *}.json" ] && continue
    OUT="$OUT$line"$'\n'
  done
  if [ -z "$OUT" ]; then say "No tickets filed by, held by or waiting for this session."; exit 0; fi
  printf '%s' "$OUT"
  ;;
*)
  usage_error "unknown command: $CMD"
  ;;
esac
