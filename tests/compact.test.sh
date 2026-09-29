#!/usr/bin/env bash
# compact.test.sh - auto-compact with notes, the hook side (build program unit 16, 2026-09-29).
# Claude Code compacts a session at compact.atPct of its window (Shepherd sets
# env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE); a summary drops detail, so Shepherd has the session write
# its own notes first. Shepherd leaves ~/.claude/cc-notes/<key>.due-at ("<due> <compactAt>
# <window>", tokens) for each live session; the Stop hook compares the transcript's last usage with
# it and, once per compaction cycle, blocks the stop asking for ~/.claude/cc-notes/<key>.notes.md.
# PreCompact tells the summarizer the notes will be restored; SessionStart(compact) hands them back.
# Drives the REAL cc-status.sh over throwaway dirs.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_NOTES_DIR="$TMP/cc-notes"
export CC_INBOX_DIR="$TMP/cc-inbox"
mkdir -p "$CC_STATUS_DIR" "$CC_NOTES_DIR" "$CC_INBOX_DIR" "$TMP/tr"

CC="$ROOT/cc-status.sh"
CWD="/Users/x/Programming/compact-proj"
# stdout is what Claude Code reads from the hook; stderr is our log
evout() { printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$CC" "$1" 2>/dev/null; }
# stop_json <sid> [stop_hook_active] [permission_mode]
stop_json() {
  jq -nc --arg s "$1" --arg c "$CWD" --arg t "$TMP/tr/$1.jsonl" --argjson a "${2:-false}" --arg m "${3:-default}" \
    '{session_id:$s, cwd:$c, transcript_path:$t, hook_event_name:"Stop", stop_hook_active:$a, permission_mode:$m}'
}
# usage <sid> <input> <cache_read> <cache_create>: an assistant turn whose context is their sum
usage() {
  jq -nc --argjson i "$2" --argjson r "$3" --argjson c "$4" \
    '{type:"assistant", message:{role:"assistant", model:"claude-opus-5-5", usage:{input_tokens:$i,
      cache_read_input_tokens:$r, cache_creation_input_tokens:$c, output_tokens:500},
      content:[{type:"text", text:"working"}]}}' >> "$TMP/tr/$1.jsonl"
}
user_line() { printf '{"type":"user","message":{"role":"user","content":"go on"}}\n' >> "$TMP/tr/$1.jsonl"; }
due() { printf '%s %s %s\n' "$2" "$3" "$4" > "$CC_NOTES_DIR/$1.due-at"; }
reason() { printf '%s' "$1" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }

# ---- the first turn end past due-at asks for the notes, once (2026-09-29) ----
evout userpromptsubmit "{\"session_id\":\"c1\",\"cwd\":\"$CWD\",\"prompt\":\"build it\"}" >/dev/null
due c1 144000 153000 200000
usage c1 100 120000 3000
got="$(evout stop "$(stop_json c1)")"
assert_eq "below due-at the turn ends as usual" "" "$got"
assert_json "...done" "$CC_STATUS_DIR/c1.json" '.status' "done"

user_line c1; usage c1 50 141000 4000     # 145,050 tokens: past 144,000
got="$(evout stop "$(stop_json c1)")"
assert_eq "the first turn end past due-at blocks the stop" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"
r="$(reason "$got")"
assert_eq "...asking for the notes in this session's own notes file" "yes" "$(has "$r" "$CC_NOTES_DIR/c1.notes.md")"
assert_eq "...marked as Shepherd's" "[shepherd]" "$(printf '%s' "$r" | cut -c1-10)"
assert_eq "...saying when compaction comes" "yes" "$(has "$r" "153")"
assert_eq "...printed once, as one JSON object" "1" "$(printf '%s\n' "$got" | grep -c .)"
assert_json "...and the tile stays working while the session writes them" "$CC_STATUS_DIR/c1.json" '.status' "working"

user_line c1; usage c1 50 147000 1000
got="$(evout stop "$(stop_json c1)")"
assert_eq "once per cycle: the next turn end past due-at doesn't ask again" "" "$got"
assert_json "...and ends done" "$CC_STATUS_DIR/c1.json" '.status' "done"

# ---- a new cycle after compaction ----
user_line c1; usage c1 30 20000 2000      # the context dropped: compaction happened
got="$(evout stop "$(stop_json c1)")"
assert_eq "after compaction (below due-at again) nothing is asked" "" "$got"
user_line c1; usage c1 30 150000 2000
got="$(evout stop "$(stop_json c1)")"
assert_eq "...and the next crossing starts a new cycle: it asks again" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"

# ---- never while stop_hook_active, never in plan mode ----
due c2 144000 153000 200000
usage c2 10 150000 0
got="$(evout stop "$(stop_json c2 true)")"
assert_eq "no block while stop_hook_active (a block already kept this turn going)" "" "$got"
assert_json "...the turn ends done" "$CC_STATUS_DIR/c2.json" '.status' "done"
got="$(evout stop "$(stop_json c2)")"
assert_eq "...and the ask isn't lost: the next plain turn end asks" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"

due c3 144000 153000 200000
usage c3 10 150000 0
got="$(evout stop "$(stop_json c3 false plan)")"
assert_eq "no block in plan mode (the session can't write a file)" "" "$got"
got="$(evout stop "$(stop_json c3 false default)")"
assert_eq "...it asks once the session is out of plan mode" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"

# plan mode known only from the status file (an older Claude Code sends no permission_mode on Stop)
due c4 144000 153000 200000
usage c4 10 150000 0
evout userpromptsubmit "{\"session_id\":\"c4\",\"cwd\":\"$CWD\",\"prompt\":\"plan it\",\"permission_mode\":\"plan\"}" >/dev/null
got="$(evout stop "$(jq -nc --arg c "$CWD" --arg t "$TMP/tr/c4.jsonl" '{session_id:"c4", cwd:$c, transcript_path:$t, stop_hook_active:false}')")"
assert_eq "no block when the status file says plan mode" "" "$got"

# ---- nothing without a due-at, nothing in Shepherd's own runs ----
usage c5 10 190000 0
got="$(evout stop "$(stop_json c5)")"
assert_eq "no due-at (compaction off): never asks" "" "$got"
due c6 144000 153000 200000
usage c6 10 150000 0
got="$(CC_SHEPHERD_INTERNAL=1 evout stop "$(stop_json c6)")"
assert_eq "Shepherd's internal runs are never asked" "" "$got"

# ---- the transcript's LAST real usage ----
due c7 144000 153000 200000
usage c7 10 150000 0
jq -nc '{type:"assistant", isApiErrorMessage:true, message:{role:"assistant", model:"<synthetic>",
  usage:{input_tokens:0, cache_read_input_tokens:0, cache_creation_input_tokens:0, output_tokens:0},
  content:[{type:"text", text:"API Error"}]}}' >> "$TMP/tr/c7.jsonl"
got="$(evout stop "$(stop_json c7)")"
assert_eq "a synthetic zero-usage error record doesn't read as an empty context" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"
due c8 144000 153000 200000
usage c8 10 150000 0
printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read' >> "$TMP/tr/c8.jsonl"
got="$(evout stop "$(stop_json c8)")"
assert_eq "a torn last line is skipped: the last complete usage counts" "block" "$(printf '%s' "$got" | jq -r '.decision' 2>/dev/null)"
due c9 144000 153000 200000
got="$(evout stop "$(stop_json c9)")"
assert_eq "no transcript yet: nothing asked" "" "$got"

# ---- a mailbox message and the notes request in the same turn end: one block, both reasons ----
due m1 144000 153000 200000
usage m1 10 150000 0
mkdir -p "$CC_INBOX_DIR/m1"
jq -nc '{nonce:"aa11", text:"[shepherd] a message", at:1790000100}' > "$CC_INBOX_DIR/m1/1790000100-000001-aa11.msg"
got="$(evout stop "$(stop_json m1)")"
assert_eq "mailbox + notes: printed once, as one JSON object" "1" "$(printf '%s\n' "$got" | grep -c '^{')"
r="$(reason "$got")"
assert_eq "...carrying the message" "yes" "$(has "$r" "[shepherd] a message")"
assert_eq "...and the notes request" "yes" "$(has "$r" "$CC_NOTES_DIR/m1.notes.md")"

# ---- PreCompact: the summarizer is told the notes come back ----
due p1 144000 153000 200000
usage p1 10 150000 0
evout stop "$(stop_json p1)" >/dev/null           # asked: the cycle's marker is set
printf '# Notes\nThe task: ship unit 16.\n' > "$CC_NOTES_DIR/p1.notes.md"
got="$(evout precompact "{\"session_id\":\"p1\",\"cwd\":\"$CWD\",\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"custom_instructions\":\"\"}")"
assert_eq "precompact with notes tells the summary they will be restored" "yes" "$(has "$got" "$CC_NOTES_DIR/p1.notes.md")"
assert_eq "...as plain text (Claude Code adds it to the summary's instructions)" "no" "$(printf '%s' "$got" | jq -e . >/dev/null 2>&1 && echo yes || echo no)"
assert_json "...the tile reads working while it compacts" "$CC_STATUS_DIR/p1.json" '.status' "working"
usage p1 10 150000 0      # a compaction that failed: the context is still past due-at
got="$(evout stop "$(stop_json p1)")"
assert_eq "...a cycle ends only when the context drops below due-at: a failed compaction isn't asked twice" "" "$got"
got="$(evout precompact "{\"session_id\":\"p2\",\"cwd\":\"$CWD\",\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\"}")"
assert_eq "precompact without notes says nothing" "" "$got"

# ---- SessionStart(compact): the notes come back ----
printf '# Notes\nThe task: ship unit 16.\nNext: write the docs.\n' > "$CC_NOTES_DIR/s1.notes.md"
got="$(evout sessionstart "{\"session_id\":\"s1\",\"cwd\":\"$CWD\",\"source\":\"compact\"}")"
assert_eq "after compaction the session gets its notes back, labelled" "[Shepherd: notes]" "$(printf '%s\n' "$got" | head -1)"
assert_eq "...the whole note" "yes" "$(has "$got" "Next: write the docs.")"
assert_eq "...saying where the file is" "yes" "$(has "$got" "$CC_NOTES_DIR/s1.notes.md")"
for src in startup resume clear; do
  got="$(evout sessionstart "{\"session_id\":\"s1\",\"cwd\":\"$CWD\",\"source\":\"$src\"}")"
  assert_eq "a $src start isn't handed the compaction notes" "no" "$(has "$got" "Next: write the docs." | head -c 2)"
done
got="$(evout sessionstart "{\"session_id\":\"s2\",\"cwd\":\"$CWD\",\"source\":\"compact\"}")"
assert_eq "a compacted session with no notes is told nothing" "" "$got"

# capped at 12KB, cut with a pointer to the file for the rest
awk 'BEGIN { for (i = 0; i < 600; i++) print "note line " i " of a long set of working notes, padded out" }' > "$CC_NOTES_DIR/s3.notes.md"
got="$(evout sessionstart "{\"session_id\":\"s3\",\"cwd\":\"$CWD\",\"source\":\"compact\"}")"
n="$(printf '%s' "$got" | wc -c | tr -d ' ')"
if [ "$n" -gt 12288 ] && [ "$n" -le 13500 ]; then r=capped; else r="$n bytes"; fi
assert_eq "long notes are cut at 12KB" "capped" "$r"
assert_eq "...saying the rest is in the file" "yes" "$(has "$got" "cut at 12 KB")"
assert_eq "...never at the 8000-character cap of the other parts" "no" "$(has "$got" "capped at 8000 characters" | head -c 2)"
got="$(CC_SHEPHERD_INTERNAL=1 evout sessionstart "{\"session_id\":\"s1\",\"cwd\":\"$CWD\",\"source\":\"compact\"}")"
assert_eq "Shepherd's internal runs take nothing" "" "$got"

# ---- the ledger ----
export CC_CONFIG_FILE="$TMP/cfg.json"; printf '{"ledger":{"enabled":true}}' > "$CC_CONFIG_FILE"
export CC_LEDGER_DIR="$TMP/ledger"
due l1 144000 153000 200000
usage l1 10 150000 0
evout stop "$(stop_json l1)" >/dev/null
evout precompact "{\"session_id\":\"l1\",\"cwd\":\"$CWD\",\"trigger\":\"auto\"}" >/dev/null
assert_eq "the ask is ledgered as notes_requested, with the tokens" "150010" \
  "$(cat "$CC_LEDGER_DIR"/*.jsonl 2>/dev/null | jq -r 'select(.type == "notes_requested" and .key == "l1") | .tokens' | head -1)"
assert_eq "a compaction is ledgered with its trigger" "auto" \
  "$(cat "$CC_LEDGER_DIR"/*.jsonl 2>/dev/null | jq -r 'select(.type == "compaction" and .key == "l1") | .trigger' | head -1)"

finish
