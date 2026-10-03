#!/usr/bin/env bash
# stop-guards.test.sh - Shepherd's Stop guards, the hook side (mining round 2, 2026-10-02).
# A guard looks at how a turn ended and, when it shouldn't have ended that way, blocks the stop ONCE
# with a reason, so the session carries on (cc_stop_guard, cc-lib.sh). A1 builds the base and its
# first guard, stopGuards.question: a turn whose last paragraph asks Adam a question in prose is
# sent back to ask it with AskUserQuestion, where it reaches his Shepherd card. Drives the REAL
# cc-status.sh over throwaway dirs, and replays a corpus of REAL turn-final messages, scrubbed
# (tests/fixtures/transcripts/stop-*.jsonl).

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_INBOX_DIR="$TMP/cc-inbox"
export CC_NOTES_DIR="$TMP/cc-notes"
export CC_GUARD_DIR="$TMP/cc-guard"
export CC_ASK_DIR="$TMP/cc-ask"
mkdir -p "$CC_STATUS_DIR" "$CC_INBOX_DIR" "$CC_NOTES_DIR" "$TMP/tr"
ON="$TMP/guards-on.json"
printf '{"stopGuards":{"question":true}}' > "$ON"
export CC_CONFIG_FILE="$ON"
alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }   # Shepherd's panel heartbeat, fresh
alive

CC="$ROOT/cc-status.sh"
CWD="/Users/x/Programming/guard-proj"
FXT="$ROOT/tests/fixtures/transcripts"
REASON_TEXT="[shepherd] You ended by asking Adam in prose. Ask it with the AskUserQuestion tool so it reaches his Shepherd card."
# stdout is what Claude Code reads from the hook; stderr is our log
evout() { printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$CC" "$1" 2>/dev/null; }
# stop_json <sid> <last_assistant_message|-> [stop_hook_active] [permission_mode] [transcript]
# ("-" leaves last_assistant_message out, as an older Claude Code does)
stop_json() {
  jq -nc --arg s "$1" --arg c "$CWD" --arg m "$2" --argjson a "${3:-false}" --arg pm "${4:-default}" \
    --arg t "${5:-$TMP/tr/none.jsonl}" \
    '{session_id:$s, cwd:$c, transcript_path:$t, hook_event_name:"Stop", stop_hook_active:$a, permission_mode:$pm}
     + (if $m == "-" then {} else {last_assistant_message:$m} end)'
}
prompt() { evout userpromptsubmit "$(jq -nc --arg s "$1" --arg c "$CWD" '{session_id:$s, cwd:$c, prompt:"go on"}')" >/dev/null; }
decision() { printf '%s' "$1" | jq -r '.decision // empty' 2>/dev/null; }
reason() { printf '%s' "$1" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null; }
# asks <text>: does the detector read it as ending on a question to the reader?
asks() { if ( . "$ROOT/cc-lib.sh"; cc_question_asked "$1" ) >/dev/null 2>&1; then echo yes; else echo no; fi; }
question_of() { ( . "$ROOT/cc-lib.sh"; cc_question_asked "$1" ) 2>/dev/null; }

# ---- the detector (cc_question_asked): what reads as a question to the reader (2026-10-02) ----
# Real asks: the last sentence ends in "?" (core.turnEvidence's endsWithQuestion, the same rule)...
assert_eq "\"Want me to push?\" is a question" "yes" "$(asks "Three files changed, nothing committed. Want me to push?")"
assert_eq "\"A or B?\" is a question" "yes" "$(asks "Want them as one commit or two, and shall I push?")"
assert_eq "a one-word \"Go?\" is a question" "yes" "$(asks "I'd build the probe first, then the descriptor. Go?")"
assert_eq "a question in bold is a question" "yes" "$(asks "**Which one do you want first?**")"
assert_eq "...and one in parentheses" "yes" "$(asks "(Want me to take it?)")"
# ...or a sentence in the last paragraph asks the reader, and a reason follows it
assert_eq "\"Should I commit? It stays local.\" asks, then explains" "yes" \
  "$(asks "Should I commit this and fast-forward master? It stays local either way; nothing gets pushed.")"
assert_eq "\"Want me to fix it now? <why>\" asks, then explains" "yes" \
  "$(asks "Want me to fix it now? Sale-window preference first, fixture first, same as everything else today.")"
assert_eq "...and the question is what it prints" "Should I commit this and fast-forward master?" \
  "$(question_of "Should I commit this and fast-forward master? It stays local either way.")"
assert_eq "a question that introduces a list of options asks" "yes" \
  "$(asks "$(printf 'Two ways to go.\n\nWhich do you want?\n\n1. Commit only\n2. Commit and push')")"
# False positives it must not take for an ask
assert_eq "\"Questions? None.\" answers itself" "no" "$(asks "Open questions? None. All 4,412 tests pass.")"
assert_eq "a rhetorical question answered in the next breath is not an ask" "no" \
  "$(asks "Why did the card stay red? The hook never fired. Fixed in abc1234, suite green.")"
assert_eq "a question earlier in the message, then a plain last paragraph, is not an ask" "no" \
  "$(asks "$(printf 'Want me to push?\n\nActually, I pushed it already: main is at abc1234.')")"
assert_eq "a question inside a code fence is not an ask" "no" \
  "$(asks "$(printf 'Here is what the script prints:\n\n```\nProceed with the deploy? [y/N]\n```')")"
assert_eq "...nor inside an unclosed one" "no" "$(asks "$(printf 'Done.\n\n```\nwhat now?')")"
assert_eq "...nor in inline code" "no" "$(asks 'The prompt now reads `Continue?`')"
assert_eq "...nor in double quotes" "no" \
  "$(asks 'The question was "Which colour do you prefer?" and you picked Blue.')"
assert_eq "...nor in curly quotes" "no" "$(asks 'The caller said “Hello?” twice before the greeting.')"
assert_eq "...nor in a blockquote" "no" "$(asks "$(printf 'The old wording was:\n\n> Want me to push?')")"
assert_eq "a statement is not a question" "no" "$(asks "Committed as e658683, pushed, deployed.")"
assert_eq "...nor is an empty message" "no" "$(asks "")"

# ---- through the real Stop hook ----
prompt q1
got="$(evout stop "$(stop_json q1 "All green. Want me to push?")")"
assert_eq "a turn that ends asking in prose blocks the stop" "block" "$(decision "$got")"
assert_eq "...telling the session to ask with AskUserQuestion" "$REASON_TEXT" "$(reason "$got")"
assert_eq "...printed once, as one JSON object" "1" "$(printf '%s\n' "$got" | grep -c .)"
assert_json "...and the session stays working while it asks" "$CC_STATUS_DIR/q1.json" '.status' "working"
# stop_hook_active: that stop ends the turn the block kept going -- never block it again
got="$(evout stop "$(stop_json q1 "All green. Want me to push?" true)")"
assert_eq "no block while stop_hook_active (never loop)" "" "$got"
assert_json "...the session is done" "$CC_STATUS_DIR/q1.json" '.status' "done"
# once per turn, even if Claude Code ever left stop_hook_active off
got="$(evout stop "$(stop_json q1 "All green. Want me to push?")")"
assert_eq "the same turn is sent back once (the once-marker)" "" "$got"
T1="$(jq -r '.turn_id' "$CC_STATUS_DIR/q1.json")"
prompt q1
assert_eq "a new prompt is a new turn (turn_id), even within the same second" "different" \
  "$([ "$(jq -r '.turn_id' "$CC_STATUS_DIR/q1.json")" != "$T1" ] && echo different || echo same)"
got="$(evout stop "$(stop_json q1 "Pushed. Want me to deploy too?")")"
assert_eq "...and the next turn that ends asking is sent back again" "block" "$(decision "$got")"

got="$(evout stop "$(stop_json q2 "Committed as e658683, pushed, deployed.")")"
assert_eq "a turn that ends on a statement ends normally" "" "$got"
assert_json "...done" "$CC_STATUS_DIR/q2.json" '.status' "done"

# ---- when it stays out of the way ----
got="$(CC_CONFIG_FILE="$TMP/empty.json" evout stop "$(stop_json s1 "Want me to push?")")"
assert_eq "off unless stopGuards.question is on (a config that says nothing)" "" "$got"
printf '{"stopGuards":{"question":false}}' > "$TMP/off.json"
got="$(CC_CONFIG_FILE="$TMP/off.json" evout stop "$(stop_json s2 "Want me to push?")")"
assert_eq "...or switched off" "" "$got"
got="$(evout stop "$(stop_json s3 "Want me to start on unit 2?" false plan)")"
assert_eq "never in plan mode (a plan ends by asking to approve it)" "" "$got"
got="$(CC_SHEPHERD_INTERNAL=1 evout stop "$(stop_json s4 "Want me to push?")")"
assert_eq "never in Shepherd's own internal runs" "" "$got"
# a question already held for the card (cc-ask.sh): pending.ask, or an ask_until still ahead
printf '{"session_id":"s5","status":"approval","pending":{"tool":"AskUserQuestion","ask":[{"question":"Push?"}]}}' > "$CC_STATUS_DIR/s5.json"
got="$(evout stop "$(stop_json s5 "Want me to push?")")"
assert_eq "never while a question is already held on the card (pending.ask)" "" "$got"
printf '{"session_id":"s6","status":"approval","ask_nonce":"1.2","ask_until":%s}' "$(( $(date +%s) + 600 ))" > "$CC_STATUS_DIR/s6.json"
got="$(evout stop "$(stop_json s6 "Want me to push?")")"
assert_eq "...or by its nonce (ask_until still ahead)" "" "$got"
printf '{"session_id":"s7","status":"working","ask_nonce":"1.2","ask_until":%s}' "$(( $(date +%s) - 600 ))" > "$CC_STATUS_DIR/s7.json"
got="$(evout stop "$(stop_json s7 "Want me to push?")")"
assert_eq "...but a hold that ran out doesn't count" "block" "$(decision "$got")"
# remote: a machine where Shepherd's panel doesn't run (an SSH-bridged host has no heartbeat), so
# AskUserQuestion would reach no card there
rm -f "$CC_STATUS_DIR/.panel-alive"
got="$(evout stop "$(stop_json s8 "Want me to push?")")"
assert_eq "never where Shepherd isn't running (a remote host: no panel heartbeat)" "" "$got"
echo $(( $(date +%s) - 300 )) > "$CC_STATUS_DIR/.panel-alive"
got="$(evout stop "$(stop_json s9 "Want me to push?")")"
assert_eq "...or its heartbeat is stale" "" "$got"
alive

# ---- the text: last_assistant_message, else the transcript ----
TR="$TMP/tr/t1.jsonl"
jq -nc '{type:"user", message:{role:"user", content:"fix the build"}}' > "$TR"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Fixed. Want me to push it?"}]}}' >> "$TR"
jq -nc '{type:"system", subtype:"stop_hook_summary"}' >> "$TR"
got="$(evout stop "$(stop_json t1 - false default "$TR")")"
assert_eq "without last_assistant_message, the transcript's last assistant text is read" "block" "$(decision "$got")"
TR2="$TMP/tr/t2.jsonl"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Want me to push it?"}]}}' > "$TR2"
jq -nc '{type:"user", message:{role:"user", content:[{type:"text", text:"[Request interrupted by user]"}]}}' >> "$TR2"
got="$(evout stop "$(stop_json t2 - false default "$TR2")")"
assert_eq "...but never a question from before the turn's own prompt" "" "$got"
TR3="$TMP/tr/t3.jsonl"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Want me to run it?"}]}}' > "$TR3"
jq -nc '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"toolu_1", content:"ok"}]}}' >> "$TR3"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"toolu_2", name:"Bash", input:{}}]}}' >> "$TR3"
jq -nc '{type:"assistant", isSidechain:true, message:{role:"assistant", content:[{type:"text", text:"A subagent: done."}]}}' >> "$TR3"
got="$(evout stop "$(stop_json t3 - false default "$TR3")")"
assert_eq "...a tool result is not a prompt, and a subagent's text is not the turn's" "block" "$(decision "$got")"
got="$(evout stop "$(stop_json t4 - false default "$TMP/tr/missing.jsonl")")"
assert_eq "no text at all (no message, no transcript) ends normally" "" "$got"

# ---- precedence: mailbox > notes > question (> fakeDone > unfinished, A2/A3) ----
mkdir -p "$CC_INBOX_DIR/p1"
jq -nc '{nonce:"ab12", text:"[shepherd] Adam says: yes, push it.", at:1790000000, from:"shepherd"}' \
  > "$CC_INBOX_DIR/p1/1790000000-000001-ab12.msg"
got="$(evout stop "$(stop_json p1 "Want me to push?")")"
assert_eq "a mailbox message wins: it may be the very answer, so the question guard stands down" \
  "[shepherd] Adam says: yes, push it." "$(reason "$got")"
# the notes request (auto-compact) joins: notes first, then the question
TRN="$TMP/tr/p2.jsonl"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Want me to push?"}], usage:{input_tokens:150000}}}' > "$TRN"
printf '144000 153000 200000\n' > "$CC_NOTES_DIR/p2.due-at"
got="$(evout stop "$(stop_json p2 "Want me to push?" false default "$TRN")")"
r="$(reason "$got")"
case "$r" in "[shepherd] This session's context is at"*"$REASON_TEXT") r=ordered ;; esac
assert_eq "the notes request and the question join, notes first" "ordered" "$r"

# ---- one ledger event per block ----
LED="$TMP/ledger"
printf '{"ledger":{"enabled":true},"stopGuards":{"question":true}}' > "$TMP/ledger-on.json"
printf '%s' "$(stop_json l1 "Tests are green. Should I commit this? It stays local.")" \
  | CC_CONFIG_FILE="$TMP/ledger-on.json" CC_LEDGER_DIR="$LED" bash "$CC" stop >/dev/null 2>&1
got="$(cat "$LED"/*.jsonl 2>/dev/null | jq -r 'select(.type == "stop_guard") | "\(.key) \(.guard) \(.detail)"')"
assert_eq "the ledger records stop_guard: key, which guard, and what it caught (the question)" "l1 question Should I commit this?" "$got"
printf '%s' "$(stop_json l1 "Tests are green. Should I commit this? It stays local." true)" \
  | CC_CONFIG_FILE="$TMP/ledger-on.json" CC_LEDGER_DIR="$LED" bash "$CC" stop >/dev/null 2>&1
assert_eq "...one per block (a stop that isn't blocked records nothing)" "1" \
  "$(cat "$LED"/*.jsonl 2>/dev/null | jq -r 'select(.type == "stop_guard")' | jq -s length)"

# ---- the once-marker goes with the session, and only this session's ----
assert_eq "(fixture: q1 has a once-marker)" "yes" "$([ -e "$CC_GUARD_DIR/q1.question" ] && echo yes || echo no)"
evout sessionend "$(jq -nc --arg c "$CWD" '{session_id:"q1", cwd:$c}')" >/dev/null
assert_absent "SessionEnd removes the session's once-marker" "$CC_GUARD_DIR/q1.question"
assert_eq "...and leaves another session's" "yes" "$([ -e "$CC_GUARD_DIR/s7.question" ] && echo yes || echo no)"

# ---- the corpus: REAL turn-final messages, scrubbed (tests/fixtures/transcripts/stop-*.jsonl) ----
# Each window ends at a turn's final assistant record. Read both ways: as Claude Code 2.1.175 hands
# it over (last_assistant_message) and as an older one leaves it (the transcript alone).
corpus() { # <fixture> <want: block | pass> <what it is>
  local f="$FXT/$1" text got1 got2
  if [ ! -f "$f" ]; then assert_eq "$3 ($1)" "$2" "missing fixture"; return; fi
  text="$(tail -n 1 "$f" | jq -r '[.message.content[]? | select(.type == "text") | .text] | join("\n")')"
  rm -f "$CC_GUARD_DIR/c-$1.question" "$CC_GUARD_DIR/d-$1.question"
  got1="$(evout stop "$(stop_json "c-$1" "$text")")"
  got2="$(evout stop "$(stop_json "d-$1" - false default "$f")")"
  [ "$(decision "$got1")" = block ] && got1=block || got1=pass
  [ "$(decision "$got2")" = block ] && got2=block || got2=pass
  assert_eq "$3 ($1)" "$2 $2" "$got1 $got2"
}
corpus stop-asks-want-me-to-push.jsonl block "corpus: a report that ends \"Want me to push ...?\" is sent back"
corpus stop-asks-a-or-b.jsonl block "corpus: \"Which do you want: A, or B?\" is sent back"
corpus stop-asks-then-explains.jsonl block "corpus: \"Should I commit ...? It stays local ...\" asks, then explains: sent back"
corpus stop-asks-go.jsonl block "corpus: a plan that ends \"Go?\" is sent back"
corpus stop-question-in-code-fence.jsonl pass "corpus: a tool result quoted in a code fence, questions and all, ends normally"
corpus stop-quoted-question.jsonl pass "corpus: a report quoting the question it relayed ends normally"
corpus stop-rhetorical-question-mid-text.jsonl pass "corpus: a rhetorical question mid-text, a statement last, ends normally"
corpus stop-plain-report.jsonl pass "corpus: a plain report ends normally"
# The boundaries, pinned: the guard reads the LAST paragraph for a "?", so these two real asks
# pass. Widening either would also catch the rhetorical questions above; Adam's spec chose the
# last paragraph.
corpus stop-asks-earlier-paragraph.jsonl pass "corpus (boundary): \"Want me to push?\" a paragraph before the end passes"
corpus stop-say-go-imperative.jsonl pass "corpus (boundary): an imperative \"Say go and I'll build it\" has no \"?\" and passes"

# ---- the base A2/A3 extend: config, defaults, the remover on the panel side ----
assert_eq "defaults/cc-config.json ships stopGuards.question on" "true" \
  "$(jq -r '.stopGuards.question' "$ROOT/defaults/cc-config.json" 2>/dev/null)"

# ---- the "claims done" detector, cc_claims_done (A2, 2026-10-03; A3 reuses it) ----
# The final message says the work is finished: "done", "all green", "ready to merge", "complete".
# Masked like the question guard (code, quotes, blockquotes); a negated, conditional, future or
# questioning use claims nothing.
claims() { if ( . "$ROOT/cc-lib.sh"; cc_claims_done "$1" ) >/dev/null 2>&1; then echo yes; else echo no; fi; }
assert_eq "\"Done.\" claims done" "yes" "$(claims "Done. make lint && make test are green, everything committed.")"
assert_eq "\"All green\" claims done" "yes" "$(claims "All green: 4,412 tests pass.")"
assert_eq "\"all tests are green\" claims done" "yes" "$(claims "Rebased on main and all tests are green.")"
assert_eq "\"Ready to merge\" claims done" "yes" "$(claims "Ready to merge.")"
assert_eq "\"The unit is complete\" claims done" "yes" "$(claims "The unit is complete; the TODO line is flipped.")"
assert_eq "a negation in an earlier clause doesn't cancel a later claim" "yes" \
  "$(claims "Nothing is pushed; the unit is done.")"
assert_eq "\"Not done yet\" claims nothing" "no" "$(claims "Not done yet: the docs are left.")"
assert_eq "\"isn't complete\" claims nothing" "no" "$(claims "It isn't complete -- two tests still fail.")"
assert_eq "\"Not all green\" claims nothing" "no" "$(claims "Not all green: 3 failures in merge.test.sh.")"
assert_eq "\"almost done\" claims nothing" "no" "$(claims "Almost done; one test left to write.")"
assert_eq "a condition (\"once it's done\") claims nothing" "no" "$(claims "I'll ask for the merge once it's done.")"
assert_eq "...nor \"when ... ready to merge\"" "no" "$(claims "When the suite is green and it's ready to merge, I'll ask Shepherd.")"
assert_eq "\"still to be done\" claims nothing" "no" "$(claims "Two things are still to be done.")"
assert_eq "a question claims nothing" "no" "$(claims "Is the rebase done?")"
assert_eq "\"the complete diff\" (an adjective) claims nothing" "no" "$(claims "Here is the complete diff of the hook.")"
assert_eq "\"done\" in inline code claims nothing" "no" "$(claims 'The script prints `done` when it exits.')"
assert_eq "...nor in a code fence" "no" "$(claims "$(printf 'It prints:\n\n```\nall green, done\n```')")"
assert_eq "...nor in quotes" "no" "$(claims 'Shepherd shows "Ready to merge" on the card.')"
assert_eq "...nor in a blockquote" "no" "$(claims "$(printf 'The old reply was:\n\n> Done.')")"
assert_eq "\"incomplete\" and \"undone\" are other words" "no" "$(claims "The import is incomplete and one edit is undone.")"
assert_eq "...and an empty message claims nothing" "no" "$(claims "")"

# ---- the unfinished-unit reminder, stopGuards.unfinished (A2, 2026-10-03) ----
# A session in a .claude/worktrees/* checkout that ends a turn saying the work is done, with commits
# ahead of main and no merge request for that worktree, is reminded ONCE per head sha to ask for
# the merge: ExitWorktree, then cc-merge.sh request --worktree <path> in the background. A real
# temp repo and worktree; the merge requests are found by worktree, never by session key.
export CC_MERGE_DIR="$TMP/cc-merge"
mkdir -p "$CC_MERGE_DIR"
UON="$TMP/unfinished-on.json"
printf '{"stopGuards":{"question":true,"unfinished":true}}' > "$UON"
uev() { CC_CONFIG_FILE="$UON" evout "$@"; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac; }
gg() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }
REPO="$TMP/repo"
git init -q -b main "$REPO"
printf '.claude/worktrees/\n' > "$REPO/.gitignore"; printf 'base\n' > "$REPO/app.txt"
gg "$REPO" add -A; gg "$REPO" commit -qm init
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/u1" -b feat/u1
WT="$(git -C "$REPO/.claude/worktrees/u1" rev-parse --show-toplevel)"
COMMON="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)"
work() { printf '%s\n' "$2" >> "$1/work.txt"; gg "$1" add -A; gg "$1" commit -qm "$2"; }
work "$WT" "first change"
# ustop <sid> <cwd> <last message> [extra fields, a JSON object]
ustop() {
  local x="${4:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg s "$1" --arg c "$2" --arg m "$3" --argjson x "$x" \
    '{session_id:$s, cwd:$c, transcript_path:"/nonexistent", hook_event_name:"Stop", stop_hook_active:false,
      permission_mode:"default", last_assistant_message:$m} + $x'
}
# reqf <key> <worktree> <phase>: a merge request as cc-merge.sh writes it
reqf() {
  jq -n --arg k "$1" --arg w "$2" --arg c "$COMMON" --arg p "$3" \
    '{v:1, key:$k, session_id:$k, nonce:"1.2.3", worktree:$w, branch:"feat/u1", base:"main", commonDir:$c, phase:$p}' \
    > "$CC_MERGE_DIR/$1.json"
}
DONE_MSG="Done. make lint && make test are green and everything is committed."

got="$(uev stop "$(ustop u1 "$WT" "$DONE_MSG")")"
assert_eq "a unit worktree that says it's done, ahead of main, with no merge request, is reminded" "block" "$(decision "$got")"
r="$(reason "$got")"
assert_eq "...marked as Shepherd's" "[shepherd]" "$(printf '%s' "$r" | cut -c1-10)"
assert_eq "...naming the branch and how far ahead it is" "yes" "$(has "$r" "feat/u1 is 1 commit ahead of main")"
assert_eq "...to leave the worktree first (ExitWorktree, keep)" "yes" "$(has "$r" 'ExitWorktree (action "keep")')"
assert_eq "...then ask for this worktree from the main checkout" "yes" "$(has "$r" "~/.claude/cc-merge.sh request --worktree $WT --summary")"
assert_eq "...in the background" "yes" "$(has "$r" "in the background")"
assert_eq "...printed once, as one JSON object" "1" "$(printf '%s\n' "$got" | grep -c .)"
assert_json "...and the session stays working" "$CC_STATUS_DIR/u1.json" '.status' "working"
got="$(uev stop "$(ustop u1 "$WT" "$DONE_MSG" '{"stop_hook_active":true}')")"
assert_eq "never while stop_hook_active (the stop that ends the reminded turn)" "" "$got"
prompt u1
got="$(uev stop "$(ustop u1 "$WT" "$DONE_MSG")")"
assert_eq "once per head sha: the same commit isn't reminded again, even in a new turn" "" "$got"
work "$WT" "second change"
prompt u1
got="$(uev stop "$(ustop u1 "$WT" "Fixed the review note. All green.")")"
assert_eq "...a new commit that's claimed done is reminded again" "block" "$(decision "$got")"
assert_eq "...counting every commit ahead" "yes" "$(has "$(reason "$got")" "feat/u1 is 2 commits ahead of main")"

got="$(uev stop "$(ustop u2 "$WT" "Wrote the failing test; next I implement the guard.")")"
assert_eq "a turn that doesn't claim done isn't reminded" "" "$got"
got="$(uev stop "$(ustop u3 "$WT" "Not done yet: the docs are left.")")"
assert_eq "...nor one that says it isn't" "" "$got"
mkdir -p "$WT/sub"
got="$(uev stop "$(ustop u4 "$WT/sub" "$DONE_MSG")")"
assert_eq "a session in a subfolder of the worktree is reminded too" "block" "$(decision "$got")"

# a merge request for this worktree, from any session (a /clear changes the key), in any phase
reqf someone-else "$WT" requested
got="$(uev stop "$(ustop u5 "$WT" "$DONE_MSG")")"
assert_eq "a merge request for this worktree, made by another session key, means no reminder" "" "$got"
reqf someone-else "$WT" blocked
got="$(uev stop "$(ustop u5 "$WT" "$DONE_MSG")")"
assert_eq "...whatever its phase (blocked)" "" "$got"
reqf someone-else "/Users/x/elsewhere/.claude/worktrees/other" requested
got="$(uev stop "$(ustop u5 "$WT" "$DONE_MSG")")"
assert_eq "...but a request for another worktree doesn't count" "block" "$(decision "$got")"
rm -f "$CC_MERGE_DIR/someone-else.json"

# Adam answered Not yet for this very commit (cc-merge.sh leaves <key>.notyet)
jq -n --arg w "$WT" --arg c "$COMMON" --arg h "$(git -C "$WT" rev-parse HEAD)" \
  '{worktree:$w, commonDir:$c, branch:"feat/u1", head:$h, at:1790000000}' > "$CC_MERGE_DIR/asker.notyet"
got="$(uev stop "$(ustop u6 "$WT" "$DONE_MSG")")"
assert_eq "a commit Adam answered Not yet for isn't pushed back at him" "" "$got"
work "$WT" "acted on the note"
got="$(uev stop "$(ustop u6 "$WT" "$DONE_MSG")")"
assert_eq "...a commit after the Not yet is reminded" "block" "$(decision "$got")"
rm -f "$CC_MERGE_DIR/asker.notyet"

got="$(uev stop "$(ustop u7 "$WT" "$DONE_MSG" '{"background_tasks":[{"id":"bash_1","status":"running"}]}')")"
assert_eq "background work still in flight (background_tasks) means no reminder" "" "$got"
got="$(uev stop "$(ustop u7 "$WT" "$DONE_MSG" '{"background_tasks":[]}')")"
assert_eq "...an empty background_tasks doesn't stop it" "block" "$(decision "$got")"

got="$(uev stop "$(ustop u8 "$WT" "Done, all green. Want me to push?")")"
assert_eq "the question guard goes first: a turn that asks and claims done is sent back for the question only" \
  "$REASON_TEXT" "$(reason "$got")"

got="$(CC_CONFIG_FILE="$ON" evout stop "$(ustop u9 "$WT" "$DONE_MSG")")"
assert_eq "off unless stopGuards.unfinished is on" "" "$got"
got="$(uev stop "$(ustop m1 "$REPO" "$DONE_MSG")")"
assert_eq "the main checkout is never reminded" "" "$got"
git -C "$REPO" worktree add -q "$TMP/repo-sib" -b feat/sib
work "$TMP/repo-sib" "sibling change"
got="$(uev stop "$(ustop m2 "$TMP/repo-sib" "$DONE_MSG")")"
assert_eq "a worktree outside .claude/worktrees/ (a sibling folder) isn't a unit tab: no reminder" "" "$got"
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/u0" -b feat/u0
got="$(uev stop "$(ustop m3 "$REPO/.claude/worktrees/u0" "$DONE_MSG")")"
assert_eq "a unit worktree with no commits ahead of main isn't reminded" "" "$got"
got="$(uev stop "$(ustop m4 "/Users/x/nowhere/.claude/worktrees/gone" "$DONE_MSG")")"
assert_eq "...nor a folder that isn't a git checkout" "" "$got"

LED2="$TMP/ledger2"
printf '{"ledger":{"enabled":true},"stopGuards":{"unfinished":true}}' > "$TMP/ledger-unfinished.json"
printf '%s' "$(ustop l2 "$WT" "$DONE_MSG")" \
  | CC_CONFIG_FILE="$TMP/ledger-unfinished.json" CC_LEDGER_DIR="$LED2" bash "$CC" stop >/dev/null 2>&1
assert_eq "the ledger records the reminder as stop_guard, guard unfinished" "l2 unfinished" \
  "$(cat "$LED2"/*.jsonl 2>/dev/null | jq -r 'select(.type == "stop_guard") | "\(.key) \(.guard)"')"
assert_eq "...its once-marker holds the head sha" "$(git -C "$WT" rev-parse HEAD)" "$(cat "$CC_GUARD_DIR/l2.unfinished" 2>/dev/null)"

printf '{}' > "$CC_MERGE_DIR/u1.notyet"
evout sessionend "$(jq -nc --arg c "$WT" '{session_id:"u1", cwd:$c}')" >/dev/null
assert_absent "SessionEnd removes the session's reminder marker" "$CC_GUARD_DIR/u1.unfinished"
assert_absent "...and its Not yet record" "$CC_MERGE_DIR/u1.notyet"

assert_eq "defaults/cc-config.json ships stopGuards.unfinished on" "true" \
  "$(jq -r '.stopGuards.unfinished' "$ROOT/defaults/cc-config.json" 2>/dev/null)"

finish
