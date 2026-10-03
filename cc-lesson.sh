#!/usr/bin/env bash
# cc-lesson.sh - file a one-line lesson for this repo's coach (mining round 2 unit B4, 2026-10-03).
#
#   cc-lesson.sh "<one line>"
#   cc-lesson.sh --help
#
# A session that learned something the hard way (a trap, a wrong assumption, a command that bit)
# files it from anywhere inside the repo, a worktree included. The words are joined into one line
# (at most 400 characters) and recorded as ~/.claude/cc-lesson/<epoch>-<pid>.json, written
# temp-then-rename, naming the repo by its git common dir. Shepherd takes each record on its next
# tick and puts it in that repo's coach log as a `learned` entry: the coach's next run reads it as
# evidence, and it counts toward an evidence run (coach.evidence.minItems). Shepherd needn't be
# running: the record waits. core.parseLesson (cc-core.lua) reads the same record; KEEP THE FIELDS
# IN SYNC. Exit codes: 0 filed, 2 refused (the reason is on stderr).
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

LESSON_MAX=400

usage() {
  cat <<'EOF'
cc-lesson.sh "<one line>"

File a lesson for this repo's coach: something a session learned the hard way that its CLAUDE.md
should say. Run it from inside the repo (a worktree counts as its repo). The words are joined into
one line of at most 400 characters. Shepherd puts it in the repo's coach log; the coach's next run
reads it as evidence, and enough new evidence starts a run (coach.evidence).
EOF
}

refuse() { echo "❌ cc-lesson: $*" >&2; exit 2; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  --) shift ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"

# every whitespace run one space, trimmed
TEXT="$(printf '%s' "$*" | tr '\n\r\t' '   ' | tr -s ' ')"
TEXT="${TEXT#"${TEXT%%[![:space:]]*}"}"
TEXT="${TEXT%"${TEXT##*[![:space:]]}"}"
[ -n "$TEXT" ] || refuse "give the lesson: cc-lesson.sh \"<one line>\""
[ "${#TEXT}" -le "$LESSON_MAX" ] || refuse "the lesson is longer than $LESSON_MAX characters -- one line, please"

IDENT="$(git rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null)" \
  || refuse "not inside a git repo (a lesson is filed for the repo you're in)"
TOP="${IDENT%%$'\n'*}"
COMMON="${IDENT#*$'\n'}"
{ [ -n "$TOP" ] && [ -n "$COMMON" ] && [ "$TOP" != "$IDENT" ]; } || refuse "not inside a git repo's checkout"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"

NOW="$(cc_now)"
ID="$NOW-$$"
REC="$CC_LESSON_DIR/$ID.json"
SID="${CLAUDE_CODE_SESSION_ID:-}"
JSON="$(jq -nc --arg id "$ID" --arg common "$COMMON" --arg top "$TOP" --arg branch "$BRANCH" --arg cwd "$PWD" \
  --arg text "$TEXT" --arg sid "$SID" --argjson at "$NOW" \
  '{v:1, id:$id, commonDir:$common, toplevel:$top, branch:(if $branch == "" then null else $branch end), cwd:$cwd,
    text:$text, session_id:(if $sid == "" then null else $sid end), at:$at}')" || refuse "couldn't build the record"

mkdir -p "$CC_LESSON_DIR" 2>/dev/null && chmod 700 "$CC_LESSON_DIR" 2>/dev/null
TMP="$REC.tmp.$$"
if ! { printf '%s\n' "$JSON" > "$TMP" 2>/dev/null && mv "$TMP" "$REC"; }; then
  rm -f "$TMP" 2>/dev/null
  refuse "couldn't write the lesson to $CC_LESSON_DIR"
fi

if cc_ledger_enabled; then
  cc_ledger_append "$(jq -nc --arg id "$ID" --arg common "$COMMON" --arg sid "$SID" \
    '{type:"lesson_filed", id:$id, repo:$common} + (if $sid == "" then {} else {session_id:$sid} end)')"
fi
echo "📝 cc-lesson: filed for $(basename "${COMMON%/.git}") -- the coach reads it on its next run ($ID)"
exit 0
