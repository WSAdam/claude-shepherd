#!/usr/bin/env bash
# cc-fleet.sh - a driving Claude session's side of batch driving: propose a batch of worktree
# units, let Adam approve it ONCE in Shepherd, then have Shepherd open each unit's tab.
#
#   cc-fleet.sh propose --file <batch.json> [--wait-max <seconds>]
#       batch.json = {"title": "...", "mergeWhenGreen": true|false,
#                     "units": [{"type": "feat|fix|ui|docs", "slug": "...", "task": "..."}]}   (1-8 units)
#       Run it from inside the repo, in the BACKGROUND, and end the turn: Claude Code wakes the
#       session when Adam answers. Exit 0 BATCH APPROVED, 3 DENIED (+ note), 4 still waiting
#       (--wait-max), 5 withdrawn, 6 Shepherd isn't running, 2 refused (the reason is printed).
#   cc-fleet.sh tab --batch <id> --unit <slug> [--wait-max 120]
#       Shepherd opens an empty Claude tab in the repo's window and answers with the new
#       session's name and the message to send it (SendMessage). Driver only; approved batches only.
#   cc-fleet.sh status --batch <id>     Shepherd's view of the units, grouped by outcome (JSON)
#   cc-fleet.sh stop --batch <id>       ends the batch; its permissions go with it
#
# The approval lives in Shepherd (its own <id>.state.json), never in this file's word: a
# decision bound to the proposal's nonce, claimed with mv like the approval gate's.
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

FLEET_DIR="${CC_FLEET_DIR:-$HOME/.claude/cc-fleet}"
SESSIONS_DIR="${CC_SESSIONS_DIR:-$HOME/.claude/sessions}"
POLL="${CC_FLEET_POLL:-1}"
PANEL_MAX_AGE="${CC_MERGE_PANEL_MAX_AGE:-30}"

refuse() { echo "❌ cc-fleet: $*"; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "jq is required"
SID="${CLAUDE_CODE_SESSION_ID:-}"
# `alive` is exempt: it answers "is Shepherd up?", which is exactly what a caller that can't
# run the rest of these commands needs to know (2026-09-22). Everything else acts on a batch
# and is meaningless without a session to own it.
if [ "${1:-}" != "alive" ]; then
  [ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"
fi

shepherd_alive() {
  local hb now
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  [ -n "$hb" ] && [ $((now - hb)) -le "$PANEL_MAX_AGE" ]
}

batch_file() { # <id> -> path, refusing an id that could leave the dir
  case "$1" in ''|*[!A-Za-z0-9]*) refuse "bad batch id: $1" ;; esac
  printf '%s/%s.json' "$FLEET_DIR" "$1"
}

update_batch() { # <file> <jq filter> [jq args...]
  local f="$1" filter="$2"; shift 2
  local tmp="$f.tmp.$$"
  if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# Wait for <decision> bound to <nonce>; claim with mv, put a stranger's answer back. Prints
# the claimed JSON on stdout. Returns 0 claimed, 4 wait-max ran out, 5 <watched> gone.
wait_answer() { # <decision file> <nonce> <watched file> <wait-max>
  local dec="$1" nonce="$2" watched="$3" waitmax="$4" start claim
  start="$(date +%s)"
  while :; do
    [ -f "$watched" ] || return 5
    if [ -f "$dec" ]; then
      claim="$dec.claim.$$"
      if mv "$dec" "$claim" 2>/dev/null; then
        if [ "$(jq -r '.nonce // empty' "$claim" 2>/dev/null)" = "$nonce" ]; then
          cat "$claim"; rm -f "$claim" "$dec".parked.*
          return 0
        fi
        if ln "$claim" "$dec" 2>/dev/null; then rm -f "$claim"; else mv "$claim" "$dec.parked.$$" 2>/dev/null; fi
      fi
    fi
    if [ "$waitmax" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$waitmax" ]; then return 4; fi
    sleep "$POLL"
  done
}

cmd_propose() {
  local file="" waitmax=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  case "$waitmax" in ''|*[!0-9]*) refuse "--wait-max takes whole seconds" ;; esac
  [ -f "$file" ] || refuse "--file must name the batch JSON"
  local problems
  problems="$(jq -r '
    def slugok: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,39}$") and (test("\\.\\.") | not)
                and (test("\\.$") | not) and (test("\\.lock$") | not);
    if type != "object" then "not a JSON object" else
      [ (if (.title | type) != "string" or (.title | length) < 1 or (.title | length) > 120 then "title must be 1-120 characters" else empty end),
        (if has("mergeWhenGreen") and (.mergeWhenGreen | type) != "boolean" then "mergeWhenGreen must be true or false" else empty end),
        (if (.units | type) != "array" or (.units | length) < 1 or (.units | length) > 8 then "units must be a list of 1-8 units" else empty end),
        ((.units // []) | if type == "array" then .[] else empty end
          | (if (.type | IN("feat", "fix", "ui", "docs")) | not then "unit \(.slug // "?"): type must be feat, fix, ui or docs" else empty end),
            (if (.slug | slugok) | not then "unit \(.slug // "?"): slug must be lower-case letters, digits, . _ - (max 40)" else empty end),
            (if (.task | type) != "string" or (.task | length) < 1 or (.task | length) > 4000 then "unit \(.slug // "?"): task must be 1-4000 characters" else empty end)),
        (if ((.units // []) | type) == "array" and ((.units | map(.slug) | unique | length) != (.units | length)) then "slugs must be unique" else empty end)
      ] | .[] end' "$file" 2>&1)" || problems="the batch file isn't valid JSON"
  [ -z "$problems" ] || { echo "❌ cc-fleet: the batch was refused:"; printf '  %s\n' "$problems"; exit 2; }

  local common main
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || refuse "run it from inside the repo the units belong to"
  case "$common" in */.git) main="${common%/.git}" ;; *) refuse "the repo has no main checkout (a bare repo?)" ;; esac
  local taken=""
  while IFS=$'\t' read -r type slug; do
    git --git-dir="$common" show-ref --verify --quiet "refs/heads/$type/$slug" && taken="$taken $type/$slug"
    git --git-dir="$common" show-ref --verify --quiet "refs/heads/worktree-$slug" && taken="$taken worktree-$slug"
    [ -e "$main/.claude/worktrees/$slug" ] && taken="$taken .claude/worktrees/$slug"
  done < <(jq -r '.units[] | [.type, .slug] | @tsv' "$file")
  [ -z "$taken" ] || refuse "already exists:$taken"
  shepherd_alive || { echo "⚠️ Shepherd isn't running, so Adam can't approve a batch there. Ask him in chat, and run the units by hand."; exit 6; }

  mkdir -p "$FLEET_DIR" && chmod 700 "$FLEET_DIR" 2>/dev/null
  local now id nonce dname bf tmp
  now="$(date +%s)"; id="b${now}${RANDOM}"; nonce="$$.$now.$RANDOM"
  dname="$(jq -r '.name // empty' "$SESSIONS_DIR/${CLAUDE_PID:-none}.json" 2>/dev/null)"
  bf="$(batch_file "$id")"; tmp="$bf.tmp.$$"
  jq --arg id "$id" --arg nonce "$nonce" --arg sid "$SID" --arg pid "${CLAUDE_PID:-}" --arg dname "$dname" \
     --arg repo "$main" --arg common "$common" --argjson at "$now" '
    { v: 1, id: $id, nonce: $nonce, driver: { session_id: $sid, pid: $pid, name: $dname },
      repo: $repo, commonDir: $common, title: .title, mergeWhenGreen: (.mergeWhenGreen // false),
      units: [ .units[] | { type, slug, task, branch: (.type + "/" + .slug) } ], at: $at, phase: "proposed" }' \
     "$file" > "$tmp" && mv "$tmp" "$bf" || refuse "couldn't write the proposal in $FLEET_DIR"
  echo "⏳ Proposed batch $id ($(jq -r '.units | length' "$bf") units) to Adam in Shepherd. Waiting for his answer..."

  local ans rc
  ans="$(wait_answer "$FLEET_DIR/$id.decision" "$nonce" "$bf" "$waitmax")"; rc=$?
  if [ "$rc" -eq 5 ]; then echo "↩︎ The proposal was withdrawn."; exit 5; fi
  if [ "$rc" -eq 4 ]; then echo "⏳ Still waiting for Adam after ${waitmax}s -- batch $id stays proposed."; exit 4; fi
  local verdict grant note
  verdict="$(printf '%s' "$ans" | jq -r '.verdict // empty')"
  grant="$(printf '%s' "$ans" | jq -r '.grantMerge == true')"
  note="$(printf '%s' "$ans" | jq -r '.note // empty' | head -c 500)"
  if [ "$verdict" != "approve" ]; then
    update_batch "$bf" '.phase = "denied" | .note = $n' --arg n "$note"
    echo "DENIED: ${note:-(no note)}"
    echo "Adam didn't approve batch $id. Nothing was opened."
    exit 3
  fi
  update_batch "$bf" '.phase = "approved" | .approvedAt = $t' --argjson t "$(date +%s)"
  echo "BATCH APPROVED -- $(jq -r .title "$bf"): $(jq -r '.units | length' "$bf") units in $main."
  if [ "$grant" = "true" ]; then
    echo "Merges are delegated: Shepherd merges each unit once its own git check finds it ready (one per repo at a time)."
  else
    echo "Merges are NOT delegated: each unit stops at 'ready to merge' for Adam's click."
  fi
  echo "For each unit, open its tab, then SendMessage the printed session the printed message (notify_when_idle: true):"
  jq -r --arg id "$id" '.units[] | "  ~/.claude/cc-fleet.sh tab --batch \($id) --unit \(.slug)"' "$bf"
  echo "Follow them with the idle notices and ~/.claude/cc-fleet.sh status --batch $id (never poll ListAgents)."
  echo "When every unit has merged or blocked: ~/.claude/cc-fleet.sh stop --batch $id, then summarise for Adam."
  exit 0
}

cmd_tab() {
  local id="" slug="" waitmax=120
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) id="${2:-}"; shift 2 ;;
      --unit) slug="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  [ "$(jq -r .driver.session_id "$bf")" = "$SID" ] || refuse "only the session that proposed batch $id can open its tabs"
  [ "$(jq -r .phase "$bf")" = "approved" ] || refuse "batch $id isn't approved (it's $(jq -r .phase "$bf"))"
  [ -e "$FLEET_DIR/$id.stop" ] && refuse "batch $id was stopped"
  jq -e --arg s "$slug" '.units | any(.slug == $s)' "$bf" >/dev/null || refuse "batch $id has no unit '$slug'"
  if jq -e --arg s "$slug" '.units[$s].session != null' "$FLEET_DIR/$id.state.json" >/dev/null 2>&1; then
    refuse "unit $slug already has its tab ($(jq -r --arg s "$slug" '.units[$s].session.name' "$FLEET_DIR/$id.state.json"))"
  fi
  shepherd_alive || { echo "⚠️ Shepherd isn't running, so it can't open the tab."; exit 6; }
  local req="$FLEET_DIR/$id.tab-$slug.json" nonce tmp
  nonce="$$.$(date +%s).$RANDOM"; tmp="$req.tmp.$$"
  jq -n --arg b "$id" --arg s "$slug" --arg sid "$SID" --arg n "$nonce" --argjson at "$(date +%s)" \
    '{v: 1, batch: $b, slug: $s, session_id: $sid, nonce: $n, at: $at}' > "$tmp" && mv "$tmp" "$req" || refuse "couldn't write the tab request"
  echo "⏳ Asked Shepherd to open unit $slug's tab..."
  local ans rc
  ans="$(wait_answer "$FLEET_DIR/$id.tab-$slug.answer" "$nonce" "$req" "$waitmax")"; rc=$?
  rm -f "$req"
  [ "$rc" -eq 0 ] || refuse "Shepherd didn't open the tab within ${waitmax}s"
  if [ "$(printf '%s' "$ans" | jq -r '.ok == true')" != "true" ]; then
    refuse "Shepherd couldn't open unit $slug's tab: $(printf '%s' "$ans" | jq -r '.reason // "no reason given"')"
  fi
  echo "✅ Unit $slug's tab is open. Its session: $(printf '%s' "$ans" | jq -r .name)"
  echo "Send it this message with SendMessage (to: \"$(printf '%s' "$ans" | jq -r .name)\", notify_when_idle: true):"
  echo "-----"
  printf '%s\n' "$ans" | jq -r .message
  echo "-----"
  exit 0
}

cmd_status() {
  local id=""
  while [ $# -gt 0 ]; do case "$1" in --batch) id="${2:-}"; shift 2 ;; *) refuse "unknown option: $1" ;; esac; done
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  # Grouped by outcome, the way core.batchOutcomes groups them (merged-dirty counts as merged; a
  # session and no result = working; no session = unopened). Shepherd's state file is the source;
  # a missing or torn one reads as empty, so every unit is unopened.
  local state
  state="$(jq -c 'if type == "object" then . else {} end' "$FLEET_DIR/$id.state.json" 2>/dev/null)" || state=""
  [ -n "$state" ] || state='{}'
  jq -n --slurpfile b "$bf" --argjson s "$state" '
    def outcome($us):
      if ($us.result == "merged" or $us.result == "merged-dirty") then "merged"
      elif $us.result == "blocked" then "blocked"
      elif (($us.session | type) == "object") then "working"
      else "unopened" end;
    ($s.units | if type == "object" then . else {} end) as $su
    | [ $b[0].units[] | . as $u | ($su[$u.slug] | if type == "object" then . else {} end) as $us
        | { slug: $u.slug, branch: $u.branch, outcome: outcome($us),
            result: ($us.result // null), session: ($us.session.name? // null) } ] as $units
    | ([ "merged", "blocked", "working", "unopened" ]
       | map(. as $k | { key: $k, value: [ $units[] | select(.outcome == $k) | .slug ] }) | from_entries) as $o
    | { batch: $b[0].id, title: $b[0].title, phase: $b[0].phase, repo: $b[0].repo,
        grant: ($s.grant // null), counts: ($o | map_values(length)), outcomes: $o, units: $units }'
  exit 0
}

cmd_stop() {
  local id=""
  while [ $# -gt 0 ]; do case "$1" in --batch) id="${2:-}"; shift 2 ;; *) refuse "unknown option: $1" ;; esac; done
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  [ "$(jq -r .driver.session_id "$bf")" = "$SID" ] || refuse "only the session that proposed batch $id can stop it here (Adam can stop it in Shepherd)"
  : > "$FLEET_DIR/$id.stop"
  update_batch "$bf" '.phase = "stopped" | .stoppedAt = $t' --argjson t "$(date +%s)"
  echo "✅ Batch $id stopped: no more tabs, and no merges on its grant."
  exit 0
}

# Is Shepherd up? The one honest answer, because there is nothing else to look at.
# 2026-09-22: a session checked with `pgrep -fl -i shepherd`, found nothing and told Adam
# "Shepherd isn't running" -- while he was looking at that very question on its card. There
# is NO process called Shepherd: it is Lua (claude-dashboard.lua) running inside
# Hammerspoon, and ~/Applications/Shepherd.app is only a launcher. The panel's heartbeat is
# the signal every other command here already uses; this just says it out loud, so a session
# never has to invent a test. Deliberately usable with no Claude session id: a session that
# can't run the rest still needs to find out why.
cmd_alive() {
  local hb now age
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  if [ -n "$hb" ] && [ "$((now - hb))" -le "$PANEL_MAX_AGE" ]; then
    echo "✅ Shepherd is running (panel heartbeat $((now - hb))s old, inside Hammerspoon)."
    exit 0
  fi
  if [ -z "$hb" ]; then
    echo "⚠️ Shepherd isn't running: it has written no panel heartbeat (it may never have started here)."
  else
    age="$((now - hb))"
    echo "⚠️ Shepherd isn't running: its panel heartbeat is ${age}s old (stale past ${PANEL_MAX_AGE}s)."
  fi
  echo "   Shepherd is Lua inside Hammerspoon -- there is no process called Shepherd, so pgrep"
  echo "   proves nothing. Adam starts it from Shepherd.app, or Hammerspoon -> Reload Config."
  exit 6
}

case "${1:-}" in
  propose) shift; cmd_propose "$@" ;;
  tab)     shift; cmd_tab "$@" ;;
  status)  shift; cmd_status "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  alive)   shift; cmd_alive "$@" ;;
  *) echo "usage: cc-fleet.sh propose --file <batch.json> | tab --batch <id> --unit <slug> | status --batch <id> | stop --batch <id> | alive"
     exit 2 ;;
esac
