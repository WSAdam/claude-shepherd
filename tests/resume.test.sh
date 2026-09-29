#!/usr/bin/env bash
# resume.test.sh - resume at the usage limit's reset, the hook side (build program unit 13, 2026-09-29).
# A turn stopped by a usage limit fires StopFailure with error "rate_limit". cc-resume.sh (its own
# StopFailure group, matcher rate_limit, async + asyncRewake) writes ~/.claude/cc-resume/<key>.json
# and waits: for Shepherd's plan (<key>.plan.json, bound to the arm's nonce), then for the reset plus
# jitter, checking the session's pid and a cancel file. At the reset it prints the line to stderr and
# exits 2, which asyncRewake hands to the model. One waiter per session; no second attempt until a
# clean Stop clears the arm. Drives the REAL cc-resume.sh and cc-status.sh over throwaway dirs,
# with a fast poll and no jitter.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
KEEP=""
cleanup() { for p in $KEEP; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
export CC_STATUS_DIR="$TMP/status"
export CC_RESUME_DIR="$TMP/cc-resume"
export CC_RESUME_POLL=0.1
export CC_RESUME_JITTER=0
mkdir -p "$CC_STATUS_DIR"

HOOK="$ROOT/cc-resume.sh"
LINE="[shepherd] The usage limit has reset: continue the task."
LIMIT_MSG="You've hit your session limit · resets 3pm (America/New_York)"
CWD="/Users/x/Programming/limit-proj"

# a live stand-in for the session's claude process; killing it is the session dying
# (spawned in THIS shell, output closed: from inside $(...) the sleep would hold the pipe open
#  and the substitution would wait out all 300 seconds)
spawn_pid() { sleep 300 >/dev/null 2>&1 & KEEP="$KEEP $!"; printf -v "$1" '%s' "$!"; }
fail_json() { # <session_id> [error kind]
  jq -nc --arg s "$1" --arg c "$CWD" --arg e "${2:-rate_limit}" --arg m "$LIMIT_MSG" \
    '{session_id:$s, cwd:$c, hook_event_name:"StopFailure", error:$e, last_assistant_message:$m}'
}
# start <tag> <session_id> <pid> [error kind]: run the hook in the background, as Claude Code does
start() {
  ( printf '%s' "$(fail_json "$2" "${4:-rate_limit}")" \
      | CC_RESUME_SESSION_PID="$3" CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$HOOK" \
        >"$TMP/$1.out" 2>"$TMP/$1.err"; echo $? > "$TMP/$1.rc" ) &
}
# wait_rc <tag> [tenths]: the hook's exit code once it has exited, or "running"
wait_rc() {
  local i=0 n="${2:-40}"
  while [ ! -s "$TMP/$1.rc" ] && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i + 1)); done
  if [ -s "$TMP/$1.rc" ]; then cat "$TMP/$1.rc"; else echo running; fi
}
wait_file() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done; }
arm_field() { jq -r "$2" "$CC_RESUME_DIR/$1.json" 2>/dev/null; }
# plan <key> <nonce> <verdict> <resetAt> [now]: Shepherd's answer, written the way it writes it
plan() {
  jq -nc --arg n "$2" --arg v "$3" --argjson r "$4" --argjson now "${5:-false}" \
    '{nonce:$n, verdict:$v, resetAt:$r, now:$now}' > "$CC_RESUME_DIR/$1.plan.json.tmp" \
    && mv "$CC_RESUME_DIR/$1.plan.json.tmp" "$CC_RESUME_DIR/$1.plan.json"
}
NOW() { date +%s; }

# ---- arming ----
spawn_pid P1
start a1 s1 "$P1"
wait_file "$CC_RESUME_DIR/s1.json"
assert_eq "a usage limit arms the resume: cc-resume/<key>.json" "waiting" "$(arm_field s1 '.state')"
assert_eq "...with the error text Shepherd reads the reset from" "$LIMIT_MSG" "$(arm_field s1 '.message')"
assert_eq "...a nonce of its own" "yes" "$(arm_field s1 '.nonce' | grep -Eq '^[0-9a-zA-Z]{8,}$' && echo yes)"
assert_eq "...the session's pid" "$P1" "$(arm_field s1 '.pid')"
assert_eq "...the editor" "vscode" "$(arm_field s1 '.editor')"
assert_eq "...and when" "yes" "$(a="$(arm_field s1 '.armedAt')"; [ $(( $(NOW) - a )) -le 5 ] && echo yes)"
assert_eq "without Shepherd's plan it keeps waiting" "running" "$(wait_rc a1 5)"
N1="$(arm_field s1 '.nonce')"

# a plan for another arm (wrong nonce) is ignored, even one already past its reset
plan s1 "zz99zz99" wait "$(( $(NOW) - 60 ))"
assert_eq "a plan whose nonce isn't the arm's is ignored" "running" "$(wait_rc a1 5)"

# the reset in the future: still waiting; then passed: fire
plan s1 "$N1" wait "$(( $(NOW) + 3600 ))"
assert_eq "a plan with the reset an hour out: it waits" "running" "$(wait_rc a1 5)"
plan s1 "$N1" wait "$(( $(NOW) - 1 ))"
assert_eq "at the reset it exits 2 (asyncRewake wakes the model)" "2" "$(wait_rc a1)"
assert_eq "...with the line on stderr, and nothing else" "$LINE" "$(cat "$TMP/a1.err")"
assert_eq "...and nothing on stdout" "" "$(cat "$TMP/a1.out")"
assert_eq "...the arm records it fired" "fired" "$(arm_field s1 '.state')"
assert_eq "...when" "yes" "$(f="$(arm_field s1 '.firedAt')"; [ -n "$f" ] && [ $(( $(NOW) - f )) -le 5 ] && echo yes)"

# no second attempt until a clean Stop: a new usage limit on a fired arm leaves it alone
start a2 s1 "$P1"
assert_eq "a new limit before a clean Stop doesn't re-arm: it exits at once" "0" "$(wait_rc a2)"
assert_eq "...silently" "" "$(cat "$TMP/a2.err")"
assert_eq "...the arm keeps its nonce and state" "$N1 fired" "$(arm_field s1 '.nonce') $(arm_field s1 '.state')"

# a clean Stop clears the arm, the plan and a cancel file: the next limit arms afresh
touch "$CC_RESUME_DIR/s1.cancel"
printf '{"session_id":"s1","cwd":"%s","hook_event_name":"Stop"}' "$CWD" \
  | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$ROOT/cc-status.sh" stop >/dev/null 2>&1
assert_absent "a clean Stop clears the arm" "$CC_RESUME_DIR/s1.json"
assert_absent "...the plan" "$CC_RESUME_DIR/s1.plan.json"
assert_absent "...and a cancel file" "$CC_RESUME_DIR/s1.cancel"
start a3 s1 "$P1"
wait_file "$CC_RESUME_DIR/s1.json"
assert_eq "after a clean Stop the next limit arms again" "waiting" "$(arm_field s1 '.state')"
assert_eq "...with a new nonce" "yes" "$([ "$(arm_field s1 '.nonce')" != "$N1" ] && echo yes)"

# ---- one waiter per session ----
start a4 s1 "$P1"
assert_eq "a second limit while one waits exits at once (one waiter per session)" "0" "$(wait_rc a4)"
assert_eq "...and leaves the first waiter's arm alone" "waiting" "$(arm_field s1 '.state')"
assert_eq "...the first is still waiting" "running" "$(wait_rc a3 3)"

# ---- Cancel ----
touch "$CC_RESUME_DIR/s1.cancel"
assert_eq "Cancel: the waiter exits 0" "0" "$(wait_rc a3)"
assert_eq "...silently (nothing reaches the model)" "" "$(cat "$TMP/a3.err")"
assert_eq "...and the arm says cancelled" "cancelled" "$(arm_field s1 '.state')"

# ---- Resume now: Shepherd moves the reset to now ----
spawn_pid P2
start b1 s2 "$P2"
wait_file "$CC_RESUME_DIR/s2.json"
N2="$(arm_field s2 '.nonce')"
plan s2 "$N2" wait "$(( $(NOW) + 3600 ))"
assert_eq "waiting an hour out" "running" "$(wait_rc b1 3)"
plan s2 "$N2" wait "$(NOW)" true
assert_eq "Resume now: it fires at its next poll" "2" "$(wait_rc b1)"
assert_eq "...with the line" "$LINE" "$(cat "$TMP/b1.err")"

# ---- Shepherd says skip (a per-model limit, a window already tried, turned off) ----
spawn_pid P3
start c1 s3 "$P3"
wait_file "$CC_RESUME_DIR/s3.json"
plan s3 "$(arm_field s3 '.nonce')" skip "$(( $(NOW) - 1 ))"
assert_eq "a skip plan: the waiter exits 0 without firing" "0" "$(wait_rc c1)"
assert_eq "...silently" "" "$(cat "$TMP/c1.err")"
assert_eq "...the arm says skipped" "skipped" "$(arm_field s3 '.state')"
plan s3 "$(arm_field s3 '.nonce')" cancelled 0
assert_eq "(a skipped arm isn't re-armed before a clean Stop either)" "0" "$(start c2 s3 "$P3"; wait_rc c2)"

# ---- the session dies ----
spawn_pid P4
start d1 s4 "$P4"
wait_file "$CC_RESUME_DIR/s4.json"
plan s4 "$(arm_field s4 '.nonce')" wait "$(( $(NOW) + 3600 ))"
kill "$P4" 2>/dev/null; wait "$P4" 2>/dev/null
assert_eq "a dead session pid: the waiter exits 0" "0" "$(wait_rc d1)"
assert_eq "...silently" "" "$(cat "$TMP/d1.err")"

# ---- the session ends (cc_remove) or its arm is cleared ----
spawn_pid P5
start e1 s5 "$P5"
wait_file "$CC_RESUME_DIR/s5.json"
plan s5 "$(arm_field s5 '.nonce')" wait "$(( $(NOW) + 3600 ))"
touch "$CC_RESUME_DIR/s5.cancel" "$CC_RESUME_DIR/s5.json.tmp.123"
rm -f "$CC_RESUME_DIR/s5.cancel"
printf '{"session_id":"s5","cwd":"%s","hook_event_name":"SessionEnd"}' "$CWD" \
  | bash "$ROOT/cc-status.sh" sessionend >/dev/null 2>&1
assert_absent "SessionEnd removes the arm" "$CC_RESUME_DIR/s5.json"
assert_absent "...the plan" "$CC_RESUME_DIR/s5.plan.json"
assert_absent "...and a leftover temp" "$CC_RESUME_DIR/s5.json.tmp.123"
assert_eq "...and the waiter exits 0" "0" "$(wait_rc e1)"
assert_eq "...silently" "" "$(cat "$TMP/e1.err")"

# ---- a waiter that died without firing: the next limit takes over, same nonce ----
spawn_pid P6
mkdir -p "$CC_RESUME_DIR"
jq -nc --arg p "$P6" '{key:"s6", session_id:"s6", nonce:"keep1234abcd", pid:($p|tonumber), waiter:999999,
  editor:"vscode", kind:"rate_limit", message:"x", armedAt:1, state:"waiting"}' > "$CC_RESUME_DIR/s6.json"
start f1 s6 "$P6"
i=0; while [ "$(arm_field s6 '.waiter')" = "999999" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
assert_eq "a waiting arm whose waiter is gone is taken over" "running" "$(wait_rc f1 3)"
assert_eq "...keeping its nonce (Shepherd's plan still holds)" "keep1234abcd" "$(arm_field s6 '.nonce')"
assert_eq "...with the new limit's message" "$LIMIT_MSG" "$(arm_field s6 '.message')"
plan s6 keep1234abcd wait "$(( $(NOW) - 1 ))"
assert_eq "...and fires on the plan it already had" "2" "$(wait_rc f1)"

# ---- the hook's own time limit ----
spawn_pid P7
( printf '%s' "$(fail_json s7)" | CC_RESUME_SESSION_PID="$P7" CC_RESUME_MAX_WAIT=1 bash "$HOOK" \
    >"$TMP/g1.out" 2>"$TMP/g1.err"; echo $? > "$TMP/g1.rc" ) &
assert_eq "a waiter past its longest wait exits 0" "0" "$(wait_rc g1 30)"
assert_eq "...the arm says expired" "expired" "$(arm_field s7 '.state')"

# ---- never ----
spawn_pid P8
start h1 s8 "$P8" server_error
assert_eq "an error that isn't a usage limit arms nothing" "0" "$(wait_rc h1)"
assert_absent "...no arm" "$CC_RESUME_DIR/s8.json"
( printf '%s' "$(fail_json s9)" | CC_SHEPHERD_INTERNAL=1 bash "$HOOK" >/dev/null 2>&1; echo $? > "$TMP/h2.rc" ) &
assert_eq "Shepherd's own internal runs arm nothing" "0" "$(wait_rc h2)"
assert_absent "...no arm" "$CC_RESUME_DIR/s9.json"
( printf '{"session_id":"..","cwd":"/"}' | bash "$HOOK" >/dev/null 2>&1; echo $? > "$TMP/h3.rc" ) &
assert_eq "a key that could leave the folder arms nothing" "0" "$(wait_rc h3)"
assert_eq "...writing nothing outside it" "" "$(ls "$TMP" | grep -v -E '^(status|cc-resume|[a-z][0-9]+\.(out|err|rc))$')"

# ---- the wiring ----
H="$ROOT/settings-hooks.json"
assert_eq "settings-hooks.json: a StopFailure group with matcher rate_limit runs cc-resume.sh" "1" \
  "$(jq '[.hooks.StopFailure[] | select(.matcher == "rate_limit") | .hooks[] | select(.command | contains("cc-resume.sh"))] | length' "$H")"
assert_eq "...in the background (async)" "true" \
  "$(jq '[.hooks.StopFailure[] | select(.matcher == "rate_limit") | .hooks[] | select(.command | contains("cc-resume.sh"))][0].async' "$H")"
assert_eq "...waking the model when it exits 2 (asyncRewake)" "true" \
  "$(jq '[.hooks.StopFailure[] | select(.matcher == "rate_limit") | .hooks[] | select(.command | contains("cc-resume.sh"))][0].asyncRewake' "$H")"
assert_eq "...with a timeout that outlasts a weekly reset (>= 7 days)" "yes" \
  "$(t="$(jq '[.hooks.StopFailure[] | select(.matcher == "rate_limit") | .hooks[] | select(.command | contains("cc-resume.sh"))][0].timeout' "$H")"; [ "${t%.*}" -ge 604800 ] && echo yes)"
assert_eq "...never in the every-error group (cc-status.sh's)" "0" \
  "$(jq '[.hooks.StopFailure[] | select((.matcher // "") == "") | .hooks[] | select(.command | contains("cc-resume.sh"))] | length' "$H")"
assert_eq "SHIPPED lists cc-resume.sh as a hook" "1" "$(grep -cE '^cc-resume\.sh[[:space:]]+claude[[:space:]]+hook$' "$ROOT/SHIPPED")"
assert_eq "uninstall --purge removes cc-resume" "1" "$(grep -c 'cc-resume' "$ROOT/uninstall.sh")"

finish
