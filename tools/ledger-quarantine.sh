#!/usr/bin/env bash
# ledger-quarantine.sh - move the test suite's synthetic events out of Shepherd's audit ledger.
#
#   tools/ledger-quarantine.sh [--ledger DIR] [--dry-run]
#
# Before 2026-09-28, three test suites (status, ask, editor) drove the hooks without isolating the
# ledger, so while the ledger was on (defaults/cc-config.json turns it on) every `make test`
# appended ~40 fake events to the real ~/.claude/cc-ledger, skewing Insights. Their working
# folders never exist on a Mac: /p, /x/p, /U/x/..., /Users/x/..., /srv/..., /other/....
#
# Moves every event whose cwd is one of those into <ledger>/quarantine/<same file name>, keeping
# the order, and rewrites the day file atomically. Nothing is deleted. Today's (UTC) file is left
# alone: hooks append to it without a lock, so rewriting it could drop a live event -- run this
# again tomorrow for it. Idempotent. Needs jq.
set -u
LEDGER="${CC_LEDGER_DIR:-$HOME/.claude/cc-ledger}"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "ledger-quarantine: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "ledger-quarantine: jq is required" >&2; exit 2; }
[ -d "$LEDGER" ] || { echo "No ledger at $LEDGER -- nothing to do."; exit 0; }

FAKE='^(/p|/x/p|/U/x/.*|/Users/x/.*|/srv/.*|/other/.*)$'
TODAY="$(date -u +%Y-%m-%d).jsonl"
moved=0
for f in "$LEDGER"/*.jsonl; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # one tagged line per raw line: "Q<TAB>" for a synthetic event, "K<TAB>" for everything else
  # (unparseable lines are kept as they are)
  tagged="$(jq -Rr --arg re "$FAKE" '. as $raw | (try fromjson catch null) as $o
    | (if ($o | type) == "object" and (($o.cwd // "") | type) == "string" and (($o.cwd // "") | test($re))
       then "Q" else "K" end) + "\t" + $raw' "$f")"
  n="$(printf '%s\n' "$tagged" | awk -F '\t' '$1 == "Q"' | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] || continue
  if [ "$name" = "$TODAY" ]; then
    echo "$name: $n synthetic event(s) left in place -- today's file is live; run this again tomorrow."
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "$name: $n synthetic event(s) would move to quarantine/"
    moved=$((moved + n))
    continue
  fi
  mkdir -p "$LEDGER/quarantine"
  printf '%s\n' "$tagged" | awk 'substr($0, 1, 2) == "Q\t" { print substr($0, 3) }' >> "$LEDGER/quarantine/$name"
  printf '%s\n' "$tagged" | awk 'substr($0, 1, 2) == "K\t" { print substr($0, 3) }' > "$f.tmp.$$" \
    && mv -f "$f.tmp.$$" "$f"
  echo "$name: moved $n synthetic event(s) to quarantine/"
  moved=$((moved + n))
done
if [ "$DRY" = 1 ]; then
  echo "Dry run: $moved synthetic event(s) would move."
else
  echo "Moved $moved synthetic event(s)."
fi
exit 0
