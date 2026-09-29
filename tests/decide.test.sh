#!/usr/bin/env bash
# decide.test.sh - ~/.claude/cc-decide.sh, a question with a sensible default (2026-09-29, build
# program unit 28). A session asks Adam something it can answer itself: non-blocking, it gets the
# default at once and carries on; --blocking (run in the background), it waits for Adam's answer
# from Shepherd's Inbox and gets the default at its timeout. The question is recorded in
# ~/.claude/cc-decide/<key>.<epoch>-<pid>.json; Adam's answer is <id>.answer, bound to the record's
# nonce and claimed with mv (cc-ask's pattern). An answer that arrives after the session went on
# reaches it through the mailbox while it is live, else at its next start (the decisions part of
# cc_session_context, tested here). Drives the REAL cc-decide.sh and cc-status.sh over temp dirs.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_DECIDE_DIR="$TMP/cc-decide"
export CC_DECIDE_POLL=0.1
mkdir -p "$CC_STATUS_DIR" "$TMP/proj"
D="$ROOT/cc-decide.sh"
CC="$ROOT/cc-status.sh"
CWD="$TMP/proj"

alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }
dead() { echo 1 > "$CC_STATUS_DIR/.panel-alive"; }
# decide <out> <session id> args... -> $TMP/<out>.out (stdout), .err (stderr), .rc
decide() {
  local o="$1" sid="$2"; shift 2
  (cd "$CWD" && CLAUDE_CODE_SESSION_ID="$sid" bash "$D" "$@" > "$TMP/$o.out" 2> "$TMP/$o.err"; echo $? > "$TMP/$o.rc")
}
# the record of session key <key> (exactly that key: "s1" never matches "s1.x"'s records)
rec() { ls "$CC_DECIDE_DIR" 2>/dev/null | grep -E "^$(printf '%s' "$1" | sed 's/\./\\./g')\.[0-9]+-[0-9]+\.json$" | head -1; }
wait_rec() { # <key>: until its record shows up (5s at most)
  local i=0
  while [ -z "$(rec "$1")" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
answer() { # <record file> <answer> [nonce]: as FX.answerDecision writes it (temp, then renamed)
  local f="$CC_DECIDE_DIR/$1" n="${3:-}"
  [ -n "$n" ] || n="$(jq -r '.nonce' "$f")"
  jq -nc --arg n "$n" --arg a "$2" '{nonce:$n, answer:$a, at:1790000000}' > "${f%.json}.answer.tmp.1"
  mv "${f%.json}.answer.tmp.1" "${f%.json}.answer"
}
evout() { printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$CC" "$1" 2>/dev/null; }

# ---- the CLI's refusals ----
out="$(env -u CLAUDE_CODE_SESSION_ID bash "$D" --help 2>&1)"; rc=$?
assert_eq "--help works outside a session" "0" "$rc"
case "$out" in *"cc-decide.sh ask --question"*"--default"*"--blocking"*) r=yes ;; *) r="no: $out" ;; esac
assert_eq "...and shows the ask usage" "yes" "$r"
out="$(cd "$CWD" && env -u CLAUDE_CODE_SESSION_ID bash "$D" ask --question "Q?" --default a 2>&1)"; rc=$?
assert_eq "outside a Claude Code session: refused (exit 2)" "2" "$rc"
case "$out" in *CLAUDE_CODE_SESSION_ID*) r=yes ;; *) r="no: $out" ;; esac
assert_eq "...saying why" "yes" "$r"
decide noq s0 ask --default a
assert_eq "no --question: refused" "2" "$(cat "$TMP/noq.rc")"
decide nod s0 ask --question "Which?"
assert_eq "no --default: refused" "2" "$(cat "$TMP/nod.rc")"
decide notopt s0 ask --question "Which?" --default c --options "a|b"
assert_eq "a default that isn't one of the options: refused" "2" "$(cat "$TMP/notopt.rc")"
decide badcmd s0 frobnicate
assert_eq "an unknown subcommand: refused" "2" "$(cat "$TMP/badcmd.rc")"
assert_eq "...and nothing was recorded" "" "$(ls "$CC_DECIDE_DIR" 2>/dev/null)"

# ---- non-blocking: the default at once, the question recorded for the Inbox ----
start=$(date +%s)
decide nb s1 ask --question "Which port should the dev server use?" --default 4100 --options "4100|4200|5000"
took=$(( $(date +%s) - start ))
assert_eq "non-blocking: exits 0" "0" "$(cat "$TMP/nb.rc")"
assert_eq "...printing exactly the default on stdout" "4100" "$(cat "$TMP/nb.out")"
assert_eq "...at once (under 2s)" "yes" "$([ "$took" -lt 2 ] && echo yes || echo "took ${took}s")"
case "$(cat "$TMP/nb.err")" in *default*) r=yes ;; *) r="no: $(cat "$TMP/nb.err")" ;; esac
assert_eq "...and says on stderr it went with the default" "yes" "$r"
R1="$(rec s1)"
assert_eq "the question is recorded as <key>.<epoch>-<pid>.json" "yes" "$([ -n "$R1" ] && echo yes || echo no)"
F1="$CC_DECIDE_DIR/$R1"
assert_json "...its id is its name" "$F1" '.id' "${R1%.json}"
assert_json "...its session key" "$F1" '.key' "s1"
assert_json "...its session id" "$F1" '.session_id' "s1"
assert_json "...the question" "$F1" '.question' "Which port should the dev server use?"
assert_json "...the default" "$F1" '.default' "4100"
assert_json "...the options, as a list" "$F1" '.options | join(",")' "4100,4200,5000"
assert_json "...not blocking" "$F1" '.blocking' "false"
assert_json "...where it was asked" "$F1" '.cwd' "$(cd "$CWD" && pwd)"
assert_json "...when" "$F1" '(.asked | type)' "number"
assert_eq "...bound to a fresh nonce (16 hex digits)" "yes" \
  "$(jq -r '.nonce' "$F1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo "no: $(jq -r '.nonce' "$F1")")"
assert_eq "...written whole (no temp left)" "" "$(ls "$CC_DECIDE_DIR" | grep -v '\.json$')"
decide nb2 s1 ask --question "Tabs or spaces?" --default spaces
assert_eq "no --options: any default will do" "spaces" "$(cat "$TMP/nb2.out")"
assert_eq "...a second question is a second record" "2" "$(ls "$CC_DECIDE_DIR" | grep -c '^s1\.')"
assert_json "...with no options" "$CC_DECIDE_DIR/$(ls "$CC_DECIDE_DIR" | grep '^s1\.' | grep -v "$R1")" '.options | length' "0"

# ---- blocking: Adam's answer, bound to the nonce ----
alive
decide bl s2 ask --question "Ship it now?" --default no --options "yes|no" --blocking --wait 20 &
wait_rec s2
R2="$(rec s2)"
assert_eq "blocking: the question is recorded while it waits" "yes" "$([ -n "$R2" ] && echo yes || echo no)"
assert_json "...as blocking" "$CC_DECIDE_DIR/$R2" '.blocking' "true"
assert_json "...until its timeout" "$CC_DECIDE_DIR/$R2" '(.until - .asked)' "20"
assert_json "...naming the waiter" "$CC_DECIDE_DIR/$R2" '(.pid | type)' "number"
answer "$R2" "yes"
wait
assert_eq "blocking: exits 0" "0" "$(cat "$TMP/bl.rc")"
assert_eq "...printing Adam's answer" "yes" "$(cat "$TMP/bl.out")"
case "$(cat "$TMP/bl.err")" in *Adam*) r=yes ;; *) r="no: $(cat "$TMP/bl.err")" ;; esac
assert_eq "...and says it's Adam's answer" "yes" "$r"
assert_eq "...the answered question is gone, answer and claim with it" "" "$(ls "$CC_DECIDE_DIR" | grep '^s2\.')"

# a free-text answer (not one of the options) is Adam's to give
decide blf s2b ask --question "Name the branch?" --default feat/x --blocking --wait 20 &
wait_rec s2b
answer "$(rec s2b)" "feat/decisions-inbox"
wait
assert_eq "blocking: a free-text answer comes back as given" "feat/decisions-inbox" "$(cat "$TMP/blf.out")"

# ---- nonce-bound: an answer for another nonce is never taken ----
decide bn s3 ask --question "Rebase or merge?" --default rebase --options "rebase|merge" --blocking --wait 2 &
wait_rec s3
R3="$(rec s3)"
answer "$R3" "merge" "0000000000000000"
wait
assert_eq "an answer with the wrong nonce is not taken: the default at the timeout" "rebase" "$(cat "$TMP/bn.out")"
assert_absent "...and the forged answer was thrown away" "$CC_DECIDE_DIR/${R3%.json}.answer"

# ---- the timeout: the default, and the question stays open for a later answer ----
R3F="$CC_DECIDE_DIR/$R3"
assert_json "a timed-out question stays recorded, no longer blocking" "$R3F" '.blocking' "false"
assert_json "...marked timed out" "$R3F" '.timed_out' "true"
start=$(date +%s)
decide bt s4 ask --question "Squash the commits?" --default yes --blocking --wait 1
took=$(( $(date +%s) - start ))
assert_eq "blocking with no answer: the default at its timeout" "yes" "$(cat "$TMP/bt.out")"
assert_eq "...exits 0" "0" "$(cat "$TMP/bt.rc")"
assert_eq "...after about the wait (1-4s)" "yes" "$([ "$took" -ge 1 ] && [ "$took" -le 4 ] && echo yes || echo "took ${took}s")"
case "$(cat "$TMP/bt.err")" in *default*) r=yes ;; *) r="no: $(cat "$TMP/bt.err")" ;; esac
assert_eq "...saying it's the default" "yes" "$r"

# ---- Shepherd isn't running: nobody could answer, so the default at once ----
dead
start=$(date +%s)
decide bd s5 ask --question "Use the cache?" --default yes --blocking --wait 30
took=$(( $(date +%s) - start ))
assert_eq "blocking while Shepherd is down: the default" "yes" "$(cat "$TMP/bd.out")"
assert_eq "...at once" "yes" "$([ "$took" -lt 2 ] && echo yes || echo "took ${took}s")"
assert_json "...and the question waits in the Inbox, not blocking" "$CC_DECIDE_DIR/$(rec s5)" '.blocking' "false"

# ---- killed while waiting: the question lets go of blocking ----
alive
(cd "$CWD" && CLAUDE_CODE_SESSION_ID=s6 exec bash "$D" ask --question "Keep going?" --default yes --blocking --wait 30 > "$TMP/bk.out" 2>/dev/null) &
BK=$!
wait_rec s6
kill -TERM "$BK" 2>/dev/null; wait "$BK" 2>/dev/null
assert_json "a waiter that is stopped leaves its question open, not blocking" "$CC_DECIDE_DIR/$(rec s6)" '.blocking' "false"

# ---- the shell reads what the panel writes (core.decisionAnswerPayload is the one format) ----
lua_answer() { lua - "$ROOT/cc-core.lua" "$@" <<'LUA'
local core = dofile(arg[1])
core.json = dofile(arg[1]:gsub("cc%-core%.lua$", "tests/support/json.lua"))
local f = io.open(arg[2], "r"); local raw = f:read("*a"); f:close()
local d = core.parseDecision(arg[2]:match("[^/]+$"), raw)
if not d then io.stderr:write("parseDecision refused the record"); os.exit(1) end
local p, why = core.decisionAnswerPayload(d, arg[3], 1790000000)
if not p then io.stderr:write(tostring(why)); os.exit(1) end
io.write(core.json.encode(p))
LUA
}
decide bp s7 ask --question "Which docs page?" --default approvals --blocking --wait 20 &
wait_rec s7
R7="$(rec s7)"
body="$(lua_answer "$CC_DECIDE_DIR/$R7" "merging")"
assert_eq "core.parseDecision reads the record cc-decide.sh wrote" "yes" "$([ -n "$body" ] && echo yes || echo no)"
printf '%s' "$body" > "$CC_DECIDE_DIR/${R7%.json}.answer.tmp.2" && mv "$CC_DECIDE_DIR/${R7%.json}.answer.tmp.2" "$CC_DECIDE_DIR/${R7%.json}.answer"
wait
assert_eq "...and cc-decide.sh takes the answer core.decisionAnswerPayload wrote" "merging" "$(cat "$TMP/bp.out")"

# ---- a late answer at the session's next start: the decisions part ----
rm -rf "$CC_DECIDE_DIR"
decide la r1 ask --question "Which port should the dev server use?" --default 4100 --options "4100|4200"
RL="$(rec r1)"
answer "$RL" "4200"
got="$(evout sessionstart '{"session_id":"r1","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *"[Shepherd: decisions]"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "a resumed session is told Adam's late answer, labelled" "yes" "$r"
case "$got" in *"Which port should the dev server use?"*"4100"*"4200"*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "...the question, the default it went with and his answer" "yes" "$r"
assert_eq "...handed over once: the question and the answer are gone" "" "$(ls "$CC_DECIDE_DIR" | grep '^r1\.')"
got="$(evout sessionstart '{"session_id":"r1","cwd":"'"$CWD"'","source":"compact"}')"
case "$got" in *"[Shepherd: decisions]"*) r="told again" ;; *) r=once ;; esac
assert_eq "...and never again" "once" "$r"

decide lw r2 ask --question "Squash?" --default yes
answer "$(rec r2)" "no" "0000000000000000"
got="$(evout sessionstart '{"session_id":"r2","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *"[Shepherd: decisions]"*) r=shown ;; *) r="not shown" ;; esac
assert_eq "an answer with the wrong nonce is never shown" "not shown" "$r"

decide lo "r3.x" ask --question "Another session's question?" --default a
answer "$(rec r3.x)" "b"
got="$(evout sessionstart '{"session_id":"r3","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *"Another session"*) r=shown ;; *) r="not shown" ;; esac
assert_eq "another session's answer is never shown (r3 is not r3.x)" "not shown" "$r"
assert_eq "...and is left for it" "yes" "$([ -f "$CC_DECIDE_DIR/$(rec r3.x | sed 's/\.json$//').answer" ] && echo yes || echo no)"

decide ls r4 ask --question "Confirm the default?" --default keep
answer "$(rec r4)" "keep"
got="$(evout sessionstart '{"session_id":"r4","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *"[Shepherd: decisions]"*) r=shown ;; *) r="not shown" ;; esac
assert_eq "an answer that is the default changes nothing: not shown" "not shown" "$r"
assert_eq "...but the question is closed" "" "$(ls "$CC_DECIDE_DIR" | grep '^r4\.')"

# 2026-09-29: a question written over two lines was read as one line, so its default came back empty
decide lm r6 ask --question "$(printf 'Which base branch?\n(main is protected)')" --default develop
answer "$(rec r6)" "main"
got="$(evout sessionstart '{"session_id":"r6","cwd":"'"$CWD"'","source":"resume"}')"
case "$got" in *'Which base branch? (main is protected)" -- you went ahead with "develop"; Adam'*'"main"'*) r=yes ;; *) r="no: $got" ;; esac
assert_eq "a question over several lines is shown on one, with its default and the answer" "yes" "$r"

decide li r5 ask --question "Internal?" --default a
answer "$(rec r5)" "b"
got="$(CC_SHEPHERD_INTERNAL=1 evout sessionstart '{"session_id":"r5","cwd":"'"$CWD"'","source":"resume"}')"
assert_eq "Shepherd's own runs are told nothing" "" "$got"

# ---- SessionEnd (cc_remove): the key's open questions go, an answer waiting for a resume stays ----
rm -rf "$CC_DECIDE_DIR"
evout userpromptsubmit '{"session_id":"e1","cwd":"'"$CWD"'","prompt":"go"}' >/dev/null
decide eo e1 ask --question "Open one?" --default a
EO="$(rec e1)"
: > "$CC_DECIDE_DIR/${EO%.json}.json.tmp.4242"
: > "$CC_DECIDE_DIR/${EO%.json}.answer.claim.4242"
sleep 1
decide ea e1 ask --question "Answered one?" --default a
EA="$(ls "$CC_DECIDE_DIR" | grep -E '^e1\.[0-9]+-[0-9]+\.json$' | grep -v "$EO")"
answer "$EA" "b"
decide ex "e1.x" ask --question "Not e1's?" --default a
EX="$(rec e1.x)"
decide eold e9 ask --question "A week old?" --default a
EOLD="$(rec e9)"
touch -t 202601010000 "$CC_DECIDE_DIR/$EOLD"
: > "$CC_DECIDE_DIR/zz.1790000000-1.json.tmp.77"; touch -t 202601010000 "$CC_DECIDE_DIR/zz.1790000000-1.json.tmp.77"
evout sessionend '{"session_id":"e1","cwd":"'"$CWD"'","reason":"prompt_input_exit"}' >/dev/null
assert_absent "SessionEnd drops the session's open question" "$CC_DECIDE_DIR/$EO"
assert_absent "...a torn write of it" "$CC_DECIDE_DIR/${EO%.json}.json.tmp.4242"
assert_absent "...a claim of its answer" "$CC_DECIDE_DIR/${EO%.json}.answer.claim.4242"
assert_eq "...keeps an answered one for the session's next start" "yes" \
  "$([ -f "$CC_DECIDE_DIR/$EA" ] && [ -f "$CC_DECIDE_DIR/${EA%.json}.answer" ] && echo yes || echo no)"
assert_eq "...leaves another session's question alone (e1 is not e1.x)" "yes" "$([ -f "$CC_DECIDE_DIR/$EX" ] && echo yes || echo no)"
assert_absent "...and prunes a question over a week old" "$CC_DECIDE_DIR/$EOLD"
assert_absent "...and a stale torn write" "$CC_DECIDE_DIR/zz.1790000000-1.json.tmp.77"

finish
