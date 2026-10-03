#!/usr/bin/env bash
# cc-run.sh - a checklist run's session reports on its item (mining round 2 unit D3b, 2026-10-03).
#
#   cc-run.sh done <run> <item> [--note "<what you did>"]
#   cc-run.sh blocked <run> <item> --note "<why>"      (or: blocked <run> <item> "<why>")
#   cc-run.sh --help
#
# Run selected in Shepherd's My List works through the items Adam picked one at a time, each in a
# fresh session whose brief names the run and the item. A file line (TODO.md, a playbook) is done
# when its box is ticked in the file; any other item (Adam's own, an audit finding) is done only
# when its session runs `cc-run.sh done`. Any item's session can say it is stuck with `blocked`,
# which pauses the run and tells Adam. The report is ~/.claude/cc-run/<run>.<item>.<epoch>-<pid>.json,
# written temp-then-rename beside the run's own <run>.run.json (Shepherd's; read here only to check
# the run and item exist). Shepherd takes it on its next tick, only from that item's own session
# (core.runRecordReport), and checks the item off when the session's turn ends. core.parseRunReport
# (cc-core.lua) reads the same record; KEEP THE FIELDS IN SYNC. Exit codes: 0 reported, 2 refused
# (the reason is on stderr).
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

CC_RUN_DIR="${CC_RUN_DIR:-${HOME}/.claude/cc-run}"
NOTE_MAX=300

usage() {
  cat <<'EOF'
cc-run.sh done <run> <item> [--note "<what you did>"]
cc-run.sh blocked <run> <item> --note "<why>"

Report on the checklist-run item your brief named (Shepherd's Run selected in My List):
  done     the item is finished (for an item with no box to tick: Adam's own, an audit finding).
           Shepherd checks it off in My List when your turn ends and closes your tab.
  blocked  you can't finish it: the run pauses and Adam is told why. The note is required.
The note is one line of at most 300 characters. Must run inside a Claude Code session
(CLAUDE_CODE_SESSION_ID): Shepherd takes a report only from the item's own session.
EOF
}

refuse() { echo "❌ cc-run: $*" >&2; exit 2; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"

VERDICT="${1:-}"
case "$VERDICT" in
  done|blocked) shift ;;
  '') usage >&2; exit 2 ;;
  *) refuse "unknown report: $VERDICT (done or blocked -- see cc-run.sh --help)" ;;
esac
RUN="${1:-}" ITEM="${2:-}"
[ $# -ge 2 ] && shift 2 || shift $#
printf '%s' "$RUN" | grep -qE '^r[0-9a-f]{6,16}$' || refuse "not a run id: '$RUN' (your brief names it, like r1a2b3c4d)"
printf '%s' "$ITEM" | grep -qE '^[1-9][0-9]{0,3}$' || refuse "not an item number: '$ITEM' (your brief names it)"

NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --note)
      [ $# -ge 2 ] || refuse "--note needs a value"
      NOTE="$2"; shift 2 ;;
    --*) refuse "unknown option: $1 (see cc-run.sh --help)" ;;
    *) [ -z "$NOTE" ] || refuse "one note only"; NOTE="$1"; shift ;;
  esac
done
# every whitespace run one space, trimmed
NOTE="$(printf '%s' "$NOTE" | tr '\n\r\t' '   ' | tr -s ' ')"
NOTE="${NOTE#"${NOTE%%[![:space:]]*}"}"
NOTE="${NOTE%"${NOTE##*[![:space:]]}"}"
[ "${#NOTE}" -le "$NOTE_MAX" ] || refuse "the note is longer than $NOTE_MAX characters -- one line, please"
[ "$VERDICT" != "blocked" ] || [ -n "$NOTE" ] || refuse "say why it's blocked: cc-run.sh blocked $RUN $ITEM --note \"<why>\""

STATE="$CC_RUN_DIR/$RUN.run.json"
[ -r "$STATE" ] || refuse "no checklist run $RUN here -- check the run id in your brief"
jq -e --argjson n "$ITEM" '(.items // []) | map(select(.n == $n)) | length == 1' "$STATE" >/dev/null 2>&1 \
  || refuse "run $RUN has no item $ITEM -- check the item number in your brief"

NOW="$(cc_now)"
ID="$NOW-$$"
REC="$CC_RUN_DIR/$RUN.$ITEM.$ID.json"
JSON="$(jq -nc --arg id "$ID" --arg run "$RUN" --argjson item "$ITEM" --arg verdict "$VERDICT" --arg note "$NOTE" \
  --arg sid "$SID" --arg cwd "$PWD" --argjson at "$NOW" \
  '{v:1, id:$id, run:$run, item:$item, verdict:$verdict, note:(if $note == "" then null else $note end),
    session_id:$sid, cwd:$cwd, at:$at}')" || refuse "couldn't build the report"

TMP="$REC.tmp.$$"
if ! { printf '%s\n' "$JSON" > "$TMP" 2>/dev/null && mv "$TMP" "$REC"; }; then
  rm -f "$TMP" 2>/dev/null
  refuse "couldn't write the report to $CC_RUN_DIR"
fi

if cc_ledger_enabled; then
  cc_ledger_append "$(jq -nc --arg run "$RUN" --argjson item "$ITEM" --arg verdict "$VERDICT" --arg sid "$SID" \
    '{type:"run_report", run:$run, item:$item, verdict:$verdict, session_id:$sid}')"
fi
if [ "$VERDICT" = done ]; then
  echo "✅ cc-run: reported item $ITEM of run $RUN done -- Shepherd checks it off when your turn ends"
else
  echo "⏸ cc-run: reported item $ITEM of run $RUN blocked -- the run pauses and Adam is told why"
fi
exit 0
