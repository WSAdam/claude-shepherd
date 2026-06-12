#!/usr/bin/env bash
# gate.test.sh - exercise cc-approve.sh (the opt-in approval gate) across its
# safety paths. Side-effect-free: temp CC_STATUS_DIR, no real sessions.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"
# Keep the base tests hermetic: no policy config, isolated policy dirs.
export CC_CONFIG_FILE="$TMP/none.json"
export CC_APPROVED_DIR="$TMP/appr"
export CC_AUTOPILOT_DIR="$TMP/auto"
export CC_GATE_TOOLS_DIR="$TMP/gtools"

APP="$ROOT/cc-approve.sh"
FLAG="$TMP/gate.enabled"
HB="$TMP/.panel-alive"
GATED='{"session_id":"g1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'

# Poll for the per-key status file the gate writes right before it begins waiting
# for a decision, so we answer only once the hook is actually blocked — robust on
# slow boxes (no fixed sleep that could race the hook's startup). ~5s timeout.
wait_block() { # $1 = status json path
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -f "$1" ] && return 0
    sleep 0.05; i=$((i+1))
  done
  return 1
}

# Answer a blocked request exactly like FX.writeDecision: echo the request nonce
# from the status JSON's pending block ("allow <nonce>") and deliver via tmp+mv.
# Polls for the nonce itself (the key's json may pre-exist from an earlier,
# already-resolved request whose pending block was cleared). The nonce binds the
# answer to THIS request — and lets the test write land in the SAME epoch second
# as the request start (a bare write there would be indistinguishable from a
# pre-request leftover and is rejected by design).
answer() { # $1 = key, $2 = allow|deny
  local n="" i=0
  while [ "$i" -lt 100 ]; do
    n="$(jq -r '.pending.nonce // empty' "$TMP/$1.json" 2>/dev/null)"
    [ -n "$n" ] && break
    sleep 0.05; i=$((i+1))
  done
  printf '%s %s' "$2" "$n" > "$TMP/$1.decision.tmp.$$"
  mv "$TMP/$1.decision.tmp.$$" "$TMP/$1.decision"
}

# 1. disabled -> silent no-op (this is what makes it safe to always wire)
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$TMP/nope" bash "$APP" 2>/dev/null)"
assert_eq "disabled: no stdout" "" "$out"

# 2. armed but panel not alive (no heartbeat) -> falls through, no decision
touch "$FLAG"
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=5 bash "$APP" 2>/dev/null)"
assert_eq "no heartbeat: no stdout (never freezes)" "" "$out"

# 3. armed + non-gated tool -> falls through (reads stay fast)
date +%s > "$HB"
READTOOL='{"session_id":"g2","cwd":"/x/p","tool_name":"Read","tool_input":{"file_path":"/x/p/a.txt"}}'
out="$(printf '%s' "$READTOOL" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "non-gated tool: no stdout" "" "$out"

# 4. armed + fresh panel + gated tool + ALLOW decision -> emits allow JSON.
# answer() lands sub-second after the request starts (same epoch second as NOW):
# only the nonce binding makes that consumable, so this also pins that a
# same-second nonce-bound answer is accepted.
date +%s > "$HB"
( printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_allow" 2>/dev/null ) &
bg=$!
wait_block "$TMP/g1.json"
answer g1 allow
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_allow" 2>/dev/null)"
assert_eq "allow decision -> permissionDecision allow" "allow" "$got"

# 5. armed + fresh panel + gated tool + DENY decision -> emits deny JSON
date +%s > "$HB"
( printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_deny" 2>/dev/null ) &
bg=$!
wait_block "$TMP/g1.json"
answer g1 deny
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_deny" 2>/dev/null)"
assert_eq "deny decision -> permissionDecision deny" "deny" "$got"

# 6. timeout with no decision -> no stdout (falls back to native prompt)
date +%s > "$HB"
out="$(printf '%s' "$GATED" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 \
    bash "$APP" 2>/dev/null)"
assert_eq "timeout: no decision emitted" "" "$out"

# ---- Phase 4c policies (decide WITHOUT a panel; no heartbeat needed) ----
# Remove the heartbeat left by earlier tests so the "no decision" cases fall
# through immediately instead of polling for a panel that isn't answering.
rm -f "$HB"
POL="$TMP/policy.json"
cat > "$POL" <<'JSON'
{ "policies": {
    "patterns": { "enabled": true, "autoDeny": ["Bash(rm -rf*)"], "autoAllow": ["Read", "Bash(ls*)"] },
    "autopilot": { "enabled": true, "minutes": 15 },
    "approveRepeats": true } }
JSON
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null; }
runpol() { printf '%s' "$2" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$POL" bash "$APP" 2>/dev/null; }

# D: pattern auto-deny (safety) wins, even though the panel isn't running
out="$(runpol x '{"session_id":"d1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
assert_eq "policy autoDeny -> deny" "deny" "$(decision "$out")"

# D: pattern auto-allow
out="$(runpol x '{"session_id":"a1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
assert_eq "policy autoAllow -> allow" "allow" "$(decision "$out")"

# C: per-session autopilot (future expiry) -> allow anything gated
mkdir -p "$CC_AUTOPILOT_DIR"; echo 9999999999 > "$CC_AUTOPILOT_DIR/ap1"
out="$(runpol x '{"session_id":"ap1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}')"
assert_eq "autopilot -> allow" "allow" "$(decision "$out")"

# C: expired autopilot does NOT auto-allow (no panel -> no output)
echo 1 > "$CC_AUTOPILOT_DIR/ap2"
out="$(runpol x '{"session_id":"ap2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}')"
assert_eq "expired autopilot -> no decision" "" "$out"

# B: approve-repeats (pre-seeded approved-set) -> allow
mkdir -p "$CC_APPROVED_DIR"; printf 'Bash|git push\n' > "$CC_APPROVED_DIR/r1"
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git push"}}')"
assert_eq "approveRepeats -> allow" "allow" "$(decision "$out")"

# B: an unseen command is NOT auto-allowed (no panel -> no output)
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}')"
assert_eq "unseen command -> no decision" "" "$out"

# ---- gate.tools: the gated-tool list is panel-editable via config ----
date +%s > "$HB"
TOOLSCFG="$TMP/tools.json"
echo '{"gate":{"tools":"WebFetch"}}' > "$TOOLSCFG"
# a tool in the custom list is now gated (waits -> ALLOW decision -> allow)
( printf '%s' '{"session_id":"t1","cwd":"/x/p","tool_name":"WebFetch","tool_input":{"url":"https://x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$TOOLSCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_tools" 2>/dev/null ) &
bg=$!
answer t1 allow
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_tools" 2>/dev/null)"
assert_eq "config gate.tools: custom tool is gated -> allow" "allow" "$got"
# a tool OUTSIDE the custom list falls straight through (Bash isn't gated here)
out="$(printf '%s' '{"session_id":"t2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$TOOLSCFG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "config gate.tools: tool outside list falls through" "" "$out"

# ---- precedence + approveRepeats write path (improve cards) ----
# A command matching BOTH autoDeny and autoAllow must be DENIED (safety first).
BOTH="$TMP/both.json"
cat > "$BOTH" <<'JSON'
{ "policies": { "patterns": { "enabled": true,
    "autoDeny": ["Bash(rm*)"], "autoAllow": ["Bash(rm*)"] } } }
JSON
out="$(printf '%s' '{"session_id":"p1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm x"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$BOTH" bash "$APP" 2>/dev/null)"
assert_eq "precedence: autoDeny beats autoAllow" "deny" "$(decision "$out")"

# approveRepeats: a panel ALLOW must append the SIG so the next identical request
# auto-allows (previously only the pre-seeded read path was covered).
rm -f "$CC_APPROVED_DIR"/* 2>/dev/null
REPCFG="$TMP/rep.json"; echo '{"policies":{"approveRepeats":true}}' > "$REPCFG"
date +%s > "$HB"
REQ='{"session_id":"rep1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"npm run build"}}'
( printf '%s' "$REQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" >/dev/null 2>&1 ) &
bg=$!; answer rep1 allow; wait $bg
assert_eq "approveRepeats: panel allow records the SIG" "Bash|npm run build" "$(cat "$CC_APPROVED_DIR/rep1" 2>/dev/null)"
# the 2nd identical request now auto-allows with NO panel (approveRepeats fires first)
rm -f "$HB"
out="$(printf '%s' "$REQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "approveRepeats: 2nd identical request auto-allows" "allow" "$(decision "$out")"

# ---- Feature D: per-session gated-tools override (least-privilege) ----
mkdir -p "$CC_GATE_TOOLS_DIR"

# A) override that gates a tool NOT in the fleet default -> that tool is now gated
date +%s > "$HB"
printf 'WebFetch\n' > "$CC_GATE_TOOLS_DIR/ov1"
( printf '%s' '{"session_id":"ov1","cwd":"/x/p","tool_name":"WebFetch","tool_input":{"url":"https://x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov1.json"; answer ov1 allow; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov1" 2>/dev/null)"
assert_eq "per-session override: added tool is gated -> allow" "allow" "$got"

# B) "-" override gates NOTHING: a normally-gated Bash falls straight through
printf -- '-\n' > "$CC_GATE_TOOLS_DIR/ov2"
out="$(printf '%s' '{"session_id":"ov2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "per-session override: '-' gates nothing (Bash falls through)" "" "$out"

# C) NO override -> Bash is still gated exactly as before (no regression)
date +%s > "$HB"
( printf '%s' '{"session_id":"ov3","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov3" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov3.json"; answer ov3 deny; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov3" 2>/dev/null)"
assert_eq "no override: Bash still gated (no regression)" "deny" "$got"

# D) key isolation: ov2's "-" override does NOT disable gating for a different key
date +%s > "$HB"
( printf '%s' '{"session_id":"ov4","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov4" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov4.json"; answer ov4 allow; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov4" 2>/dev/null)"
assert_eq "key isolation: another session still gates Bash" "allow" "$got"

# E) EMPTY override file is NOT a sentinel: it falls back to the fleet default, so Bash
# is STILL gated (B1: a blank/half-written file must not silently disable the gate).
date +%s > "$HB"
: > "$CC_GATE_TOOLS_DIR/ov5"
( printf '%s' '{"session_id":"ov5","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ov5" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ov5.json"; answer ov5 deny; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ov5" 2>/dev/null)"
assert_eq "empty override file: Bash still gated (empty = fleet default)" "deny" "$got"

# ---- per-request signatures: no tool-name-only SIG (blanket approval) ----
# NotebookEdit has no command/file_path; its SIG must key on notebook_path so ONE
# approveRepeats approval doesn't auto-allow EVERY future NotebookEdit.
rm -f "$CC_APPROVED_DIR"/* 2>/dev/null
date +%s > "$HB"
NB1='{"session_id":"nb1","cwd":"/x/p","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/x/p/a.ipynb","new_source":"x"}}'
( printf '%s' "$NB1" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" >/dev/null 2>&1 ) &
bg=$!; wait_block "$TMP/nb1.json"; answer nb1 allow; wait $bg
assert_eq "NotebookEdit SIG keys on notebook_path" "NotebookEdit|/x/p/a.ipynb" "$(cat "$CC_APPROVED_DIR/nb1" 2>/dev/null)"
rm -f "$HB"
# a DIFFERENT notebook is NOT auto-allowed (no panel -> no output)...
out="$(printf '%s' '{"session_id":"nb1","cwd":"/x/p","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/x/p/b.ipynb","new_source":"x"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "approveRepeats: a DIFFERENT notebook is NOT blanket-approved" "" "$out"
# ...while the SAME notebook is (Edit/Write file_path granularity)
out="$(printf '%s' "$NB1" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "approveRepeats: the SAME notebook auto-allows" "allow" "$(decision "$out")"

# A gated tool with NO recognized field at all gets a per-request tool_input
# digest SIG — never the constant "Tool|Tool".
DIGCFG="$TMP/dig.json"; echo '{"gate":{"tools":"Task"},"policies":{"approveRepeats":true}}' > "$DIGCFG"
date +%s > "$HB"
TK1='{"session_id":"dg1","cwd":"/x/p","tool_name":"Task","tool_input":{"prompt":"do A"}}'
( printf '%s' "$TK1" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$DIGCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" >/dev/null 2>&1 ) &
bg=$!; wait_block "$TMP/dg1.json"; answer dg1 allow; wait $bg
assert_eq "unknown-field tool: SIG is not the bare tool name" "" "$(grep -Fx 'Task|Task' "$CC_APPROVED_DIR/dg1" 2>/dev/null)"
rm -f "$HB"
out="$(printf '%s' '{"session_id":"dg1","cwd":"/x/p","tool_name":"Task","tool_input":{"prompt":"do B"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$DIGCFG" bash "$APP" 2>/dev/null)"
assert_eq "unknown-field tool: different tool_input is NOT blanket-approved" "" "$out"
out="$(printf '%s' "$TK1" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$DIGCFG" bash "$APP" 2>/dev/null)"
assert_eq "unknown-field tool: identical tool_input auto-allows via digest" "allow" "$(decision "$out")"

# ---- decision freshness + atomic consume (same-key concurrency hardening) ----
# A decision file OLDER than the request (mtime before the gate started waiting)
# is a stale answer to some EARLIER request: it must be discarded, not consumed.
date +%s > "$HB"
( printf '%s' '{"session_id":"st1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=2 \
    bash "$APP" > "$TMP/out_st1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/st1.json"
# Backdate BEFORE the file appears at the polled name (mv keeps the old mtime),
# so the gate can never glimpse it with a fresh timestamp.
printf 'allow' > "$TMP/st1.seed"
touch -t 202001010000 "$TMP/st1.seed"
mv "$TMP/st1.seed" "$TMP/st1.decision"
wait $bg
assert_eq "stale (backdated) decision is ignored -> timeout, no output" "" "$(cat "$TMP/out_st1" 2>/dev/null)"
# ...and the stale answer is RESTORED, not destroyed: "stale" is judged against
# THIS waiter's NOW, but the same mtime can be FRESH for an earlier-started
# sibling waiter on the same key (parallel subagents share the session_id). The
# old in-loop rm silently ate that sibling's answer; the claim must be put back
# (a hardlink shares the inode) with its mtime intact so an entitled sibling can
# still consume it.
assert_eq "stale decision is restored after timeout (not rm'd)" "allow" "$(cat "$TMP/st1.decision" 2>/dev/null)"
mt="$(stat -f %m "$TMP/st1.decision" 2>/dev/null || stat -c %Y "$TMP/st1.decision" 2>/dev/null)"
assert_eq "restore preserves the stale mtime (hardlink, not a rewrite)" "preserved" \
  "$([ -n "$mt" ] && [ "$mt" -lt 1600000000 ] && echo preserved)"

# The panel writes decisions via temp + atomic rename (FX.writeDecision), so the
# file APPEARS at the polled name fully written -- never created-then-filled (an
# empty glimpse used to fall through to the native prompt and discard the click).
# Pin that a decision DELIVERED that way (answer = nonce echo + tmp/mv, the exact
# FX.writeDecision idiom) is consumed normally.
date +%s > "$HB"
( printf '%s' '{"session_id":"at1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_at1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/at1.json"
answer at1 deny
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_at1" 2>/dev/null)"
assert_eq "atomic (tmp+mv) decision delivery is consumed" "deny" "$got"

# And the gate no longer rm's the decision file at startup (that could eat a
# concurrent sibling's fresh answer on the same key): a FRESH decision already
# sitting there when the hook starts is consumed, not destroyed. Bare content =
# the LEGACY (pre-nonce) panel format, accepted only on a strictly newer mtime —
# this also pins that old panels still work after a strictly-newer write.
date +%s > "$HB"
printf 'allow' > "$TMP/st2.decision"
touch -t 203001010000 "$TMP/st2.decision"   # future mtime: unambiguously fresh
out="$(printf '%s' '{"session_id":"st2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=2 bash "$APP" 2>/dev/null)"
assert_eq "fresh pre-existing decision is consumed (no startup rm)" "allow" "$(decision "$out")"

# ---- request binding (per-request nonce + strict legacy mtime) ----
# Second-granularity hole (R3): a LEGACY bare leftover whose mtime equals the
# request-start second predates the request (whole-second mtimes can't tell it
# from a real same-second answer), so it must NOT be consumed — bare answers are
# accepted only on a STRICTLY newer mtime. Under the old `-ge` check this
# leftover silently allowed a request the user never saw.
date +%s > "$HB"
( printf '%s' '{"session_id":"ss1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf /important"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=2 \
    bash "$APP" > "$TMP/out_ss1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/ss1.json"
REQ_NOW="$(jq -r '.since' "$TMP/ss1.json")"
printf 'allow' > "$TMP/ss1.seed"
ts="$(date -r "$REQ_NOW" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$REQ_NOW" +%Y%m%d%H%M.%S)"
touch -t "$ts" "$TMP/ss1.seed"     # mtime == the waiter's NOW, exactly
mv "$TMP/ss1.seed" "$TMP/ss1.decision"
wait $bg
assert_eq "bare leftover at the request-start second is NOT consumed" "" "$(cat "$TMP/out_ss1" 2>/dev/null)"

# A nonce-bound answer for a DIFFERENT request (e.g. a double-clicked Approve
# whose first write was already consumed) is never consumed regardless of mtime,
# and is RESTORED intact for the request that owns it (a concurrent sibling).
date +%s > "$HB"
printf 'allow 99999.1111111111' > "$TMP/ss2.decision"
touch -t 203001010000 "$TMP/ss2.decision"   # fresh mtime: would pass any time check
out="$(printf '%s' '{"session_id":"ss2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf /important"}}' \
  | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=2 bash "$APP" 2>/dev/null)"
assert_eq "wrong-nonce answer is never consumed (even with a fresh mtime)" "" "$out"
assert_eq "wrong-nonce answer is restored intact for its owner" \
  "allow 99999.1111111111" "$(cat "$TMP/ss2.decision" 2>/dev/null)"

# The matching nonce IS consumed even when the answer's mtime falls in the very
# second the request started (the case the legacy format must reject) — covered
# implicitly by every answer() test above; pin it explicitly with content check.
date +%s > "$HB"
( printf '%s' '{"session_id":"ss3","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ss3" 2>/dev/null ) &
bg=$!; answer ss3 allow; wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ss3" 2>/dev/null)"
assert_eq "matching-nonce answer is consumed (request binding)" "allow" "$got"
assert_eq "consumed decision file is removed" "gone" "$([ ! -f "$TMP/ss3.decision" ] && echo gone)"

finish
