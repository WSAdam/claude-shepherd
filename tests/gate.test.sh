#!/usr/bin/env bash
# gate.test.sh - exercise cc-approve.sh (the opt-in approval gate) across its
# safety paths. Side-effect-free: temp CC_STATUS_DIR, no real sessions.
#
# ---- Why the decision IPC looks the way it does (rationale for the invariants
# the poll-loop comment in cc-approve.sh lists; each is pinned by a case below):
#
# * WHY A NONCE: decision-file mtimes have 1-second granularity, so a leftover
#   written sub-second BEFORE a request (e.g. a double-clicked Approve whose
#   first write was already consumed) is indistinguishable by time from a real
#   same-second answer. The per-request nonce ("allow <nonce>") binds an answer
#   to exactly one request. Legacy bare answers ("allow") survive but are
#   accepted only on a mtime STRICTLY newer (-gt) than the request second —
#   an equal-second bare leftover is rejected (case "ss1"), while a same-second
#   nonce-bound answer is consumed (case "ss3" + every answer() case).
# * WHY CLAIM-BY-MV: two waiters can share one session key (parallel subagents
#   inherit the parent session_id). mv to a PID-owned CLAIM is atomic, so two
#   waiters can never both consume one answer.
# * WHY HARDLINK RESTORE (not `mv -n`): a claimed answer that isn't ours is a
#   sibling's — it must go BACK. link(2) fails atomically with EEXIST, so a
#   FRESH decision the panel wrote while we held the claim is never clobbered
#   (`mv -n` is a check-then-rename race that could overwrite it), and the link
#   shares the inode, preserving the mtime the sibling's freshness check needs
#   (cases "st1" restore + "ss2").
# * WHY PARK ON COLLISION (never rm): if the restore hits EEXIST, the held
#   sibling answer is parked under a unique .claim.<pid>.parked.N name (the N
#   counter keeps a second collision from overwriting the first; cc_remove's
#   .claim.* glob sweeps them on SessionEnd) — an rm there silently destroyed
#   a human decision.
#   The collision window is sub-millisecond inside one poll iteration, so it
#   isn't orchestrable from a test; the invariant is "claimed-but-not-ours is
#   restored or parked, NEVER rm'd", and the restore half is pinned by "st1".
# * KNOWN LIMITATION (pinned by the "concurrent" case): the status JSON holds
#   ONE pending block per session key, so concurrent same-key requests
#   overwrite each other's published nonce — the panel can only ever answer
#   the most-recent request; earlier waiters fall back to the native prompt.
#   A real fix needs per-request pending entries (out of scope; documented).

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"
# Keep the base tests hermetic: no policy config, isolated policy dirs.
export CC_CONFIG_FILE="$TMP/none.json"
export CC_APPROVED_DIR="$TMP/appr"
export CC_AUTOPILOT_DIR="$TMP/auto"
export CC_GATE_TOOLS_DIR="$TMP/gtools"
export CC_POLICY_DIR="$TMP/policy"

APP="$ROOT/cc-approve.sh"
FLAG="$TMP/gate.enabled"
HB="$TMP/.panel-alive"
# 2026-09-28: was `rm -rf build`, which is now an always-ask command (held even with the gate
# off, "ask" with no panel) -- these cases pin the plain gate, so they use a plain command.
GATED='{"session_id":"g1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make build"}}'

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

# R2-04: an EMPTY (zero-byte) autopilot expiry file must be treated as 0 (fall
# through), NOT trigger `[: integer expression expected`. cat of an existing empty
# file succeeds, so `|| echo 0` never runs -> the sanitizer must include the ''
# alternative. Assert no decision AND no stderr noise.
: > "$CC_AUTOPILOT_DIR/apE"
apE_req='{"session_id":"apE","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make deploy"}}'
err="$(printf '%s' "$apE_req" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$POL" bash "$APP" 2>&1 >/dev/null)"
out="$(runpol x "$apE_req")"
assert_eq "R2-04: empty autopilot file -> no decision" "" "$out"
assert_eq "R2-04: empty autopilot file -> no integer-expression error" "" \
  "$(printf '%s' "$err" | grep -i 'integer expression' || true)"

# B: approve-repeats (pre-seeded approved-set) -> allow
# 2026-09-28: git push / git reset --hard became always-ask commands (never auto-approved);
# these two pin approveRepeats itself, so they use commands outside that list.
mkdir -p "$CC_APPROVED_DIR"; printf 'Bash|git fetch\n' > "$CC_APPROVED_DIR/r1"
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git fetch"}}')"
assert_eq "approveRepeats -> allow" "allow" "$(decision "$out")"

# B: an unseen command is NOT auto-allowed (no panel -> no output)
out="$(runpol x '{"session_id":"r1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}')"
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

# R2-05: gate.tools hand-edited to a JSON ARRAY must still gate (jq -r prints one
# element per line -> the space-delimited test never matches -> fail OPEN). The
# type-aware read joins the array to a space-separated string.
ARRCFG="$TMP/tools-arr.json"
echo '{"gate":{"tools":["Bash","Write"]}}' > "$ARRCFG"
( printf '%s' '{"session_id":"ta1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$ARRCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_arr" 2>/dev/null ) &
bg=$!
answer ta1 allow
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_arr" 2>/dev/null)"
assert_eq "R2-05: gate.tools as JSON array still gates -> allow" "allow" "$got"

# R3-19: a PRESENT-but-EMPTY gate.tools ("" or []) does NOT mean "gate nothing" -- it
# falls back to the default 5 (Bash/Write/Edit/...) and warns once on stderr (an empty
# value can't be told apart from unset; the supported "gate nothing" switches are the
# gate flag and the per-session None sentinel). Bash must still be gated, and the warning
# must be emitted.
EMPTYCFG="$TMP/tools-empty.json"
echo '{"gate":{"tools":[]}}' > "$EMPTYCFG"
( printf '%s' '{"session_id":"te1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$EMPTYCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_empty" 2>"$TMP/err_empty" ) &
bg=$!
answer te1 allow
wait $bg
got="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_empty" 2>/dev/null)"
assert_eq "R3-19: empty gate.tools falls back to default 5 (Bash still gated)" "allow" "$got"
if grep -q "gate.tools is empty" "$TMP/err_empty" 2>/dev/null; then
  assert_eq "R3-19: empty gate.tools warns on stderr" "warned" "warned"
else
  assert_eq "R3-19: empty gate.tools warns on stderr" "warned" "NO-WARNING"
fi

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
# (2026-09-28: `make build`, not `rm -rf build` -- an always-ask command is held regardless)
printf -- '-\n' > "$CC_GATE_TOOLS_DIR/ov2"
out="$(printf '%s' '{"session_id":"ov2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make build"}}' \
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

# ---- L2: per-session resolved policy bundle file (cc-policy/<key>) ----
# The panel writes core.resolvePolicy output here; the gate reads it as authoritative
# and opt-in (applies even with NO fleet policies enabled). CONFIG_FILE stays none.json
# (no fleet patterns) throughout, so a decision can ONLY come from the policy file.
mkdir -p "$CC_POLICY_DIR"

# A) policy-file autoDeny denies a gated tool with no fleet policy at all
date +%s > "$HB"
printf '{"autoDeny":["Bash(rm*)"],"bundle":"read-only"}' > "$CC_POLICY_DIR/pol1"
out="$(printf '%s' '{"session_id":"pol1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "policy file: autoDeny denies (no fleet policy needed)" "deny" "$(decision "$out")"

# B) policy-file autoAllow allows a gated tool
printf '{"autoAllow":["Bash(ls*)"],"bundle":"loose"}' > "$CC_POLICY_DIR/pol2"
out="$(printf '%s' '{"session_id":"pol2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "policy file: autoAllow allows" "allow" "$(decision "$out")"

# B2) R1-04: bundle autopilot:true auto-allows a gated tool with no fleet flag
printf '{"autopilot":true,"bundle":"loose"}' > "$CC_POLICY_DIR/polap"
out="$(printf '%s' '{"session_id":"polap","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"anything goes"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "policy file: bundle autopilot allows" "allow" "$(decision "$out")"

# B3) R1-04: autoDeny still beats bundle autopilot (deny must win)
printf '{"autopilot":true,"autoDeny":["Bash(rm*)"],"bundle":"loose"}' > "$CC_POLICY_DIR/polapd"
out="$(printf '%s' '{"session_id":"polapd","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "policy file: autoDeny beats bundle autopilot" "deny" "$(decision "$out")"

# C) policy file present but no rule matches -> routes to the panel (human decides)
date +%s > "$HB"
printf '{"autoDeny":["Bash(rm*)"]}' > "$CC_POLICY_DIR/pol3"
( printf '%s' '{"session_id":"pol3","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_pol3" 2>/dev/null ) &
bg=$!; wait_block "$TMP/pol3.json"; answer pol3 deny; wait $bg
assert_eq "policy file: non-matching rule -> routes to panel" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_pol3" 2>/dev/null)"

# D) key isolation: pol1's deny file must NOT affect a different session (no file ->
#    no auto-decision; with a dead panel it falls straight through to native).
echo 0 > "$HB"   # stale heartbeat -> immediate native fallback, no wait
# (2026-09-28: `rm -r build` still matches pol1's Bash(rm*), but isn't an always-ask command)
out="$(printf '%s' '{"session_id":"polX","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -r build"}}' \
    | CC_GATE_FLAG="$FLAG" bash "$APP" 2>/dev/null)"
assert_eq "policy file: key isolation (other session not auto-denied)" "" "$out"

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
# GNU stat first: `stat -f` means file-system status on GNU and SUCCEEDS, so a
# BSD-first fallback reads a mount point, not an mtime (2026-09-17, seen on Linux).
mt="$(stat -c %Y "$TMP/st1.decision" 2>/dev/null || stat -f %m "$TMP/st1.decision" 2>/dev/null)"
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
# (2026-09-28: `rm -r`, not `rm -rf` -- an always-ask command answers "ask" on a timeout)
( printf '%s' '{"session_id":"ss1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -r /important"}}' \
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
out="$(printf '%s' '{"session_id":"ss2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -r /important"}}' \
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

# ---- concurrent same-key requests: the nonce-overwrite limitation (documented)
# Two gated requests on ONE session key wait at once (parallel subagents share
# the parent session_id). Each publishes its nonce into the key's SINGLE
# pending block, so the second merge OVERWRITES the first's nonce: the panel
# can only ever see — and therefore answer — the most-recent request. This
# case pins the current degradation so a future per-request-pending fix has a
# target: the answered (last) waiter is satisfied, the earlier one falls back
# to the native prompt (empty output), and nothing is cross-answered.
date +%s > "$HB"
REQA='{"session_id":"cc1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"echo first"}}'
REQB='{"session_id":"cc1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"echo second"}}'
# A's timeout is the suite's wall-clock floor here -- it ALWAYS times out (that
# IS the assertion), so keep it short; its degradation holds whether it expires
# before or after B's answer lands. B gets margin so a slow box can't time the
# ANSWERED waiter out mid-orchestration (the failure mode of cutting it to 1-2s).
( printf '%s' "$REQA" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 \
    bash "$APP" > "$TMP/out_cc_a" 2>/dev/null ) &
bgA=$!
wait_block "$TMP/cc1.json"
nonceA=""
i=0; while [ "$i" -lt 100 ]; do
  nonceA="$(jq -r '.pending.nonce // empty' "$TMP/cc1.json" 2>/dev/null)"
  [ -n "$nonceA" ] && break
  sleep 0.05; i=$((i+1))
done
( printf '%s' "$REQB" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=3 \
    bash "$APP" > "$TMP/out_cc_b" 2>/dev/null ) &
bgB=$!
# wait until B's merge has overwritten the published nonce
i=0; while [ "$i" -lt 100 ]; do
  nB="$(jq -r '.pending.nonce // empty' "$TMP/cc1.json" 2>/dev/null)"
  [ -n "$nB" ] && [ "$nB" != "$nonceA" ] && break
  sleep 0.05; i=$((i+1))
done
answer cc1 allow   # reads the CURRENT (= B's) nonce, like the real panel
wait $bgB
wait $bgA
gotB="$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_cc_b" 2>/dev/null)"
assert_eq "concurrent same-key: the LAST request (panel-visible nonce) is answered" "allow" "$gotB"
assert_eq "concurrent same-key: the earlier waiter degrades to the native prompt" "" "$(cat "$TMP/out_cc_a" 2>/dev/null)"

# --- R1-36: a parallel cc-status.sh pretooluse clearing pending mid-gate must NOT
#     drop the answerability -- the top-level gate_nonce survives + binds a same-second
#     answer. Simulate the race: start the gate, wait for it to publish, then DELETE the
#     pending block (as cc-status.sh's CLEAR_PENDING would), then answer via gate_nonce.
date +%s > "$HB"
GN='{"session_id":"gn1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf q"}}'
( printf '%s' "$GN" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_gn" 2>/dev/null ) &
bg=$!
wait_block "$TMP/gn1.json"
# wait for the gate to publish gate_nonce, then simulate the racing pending-clear
gnonce=""; i=0
while [ "$i" -lt 100 ]; do
  gnonce="$(jq -r '.gate_nonce // empty' "$TMP/gn1.json" 2>/dev/null)"
  [ -n "$gnonce" ] && break
  sleep 0.05; i=$((i+1))
done
assert_eq "gate publishes a top-level gate_nonce" "0" "$([ -n "$gnonce" ] && echo 0 || echo 1)"
# cc-status.sh CLEAR_PENDING (read-modify-write) deletes the pending block out from under
# the gate -- mimic that with a direct jq delete of the pending block.
jq -c 'del(.pending)' "$TMP/gn1.json" > "$TMP/gn1.json.t" && mv "$TMP/gn1.json.t" "$TMP/gn1.json"
# the panel answers using the surviving gate_nonce (decisionContent's fallback)
printf 'allow %s' "$gnonce" > "$TMP/gn1.decision.tmp.$$"
mv "$TMP/gn1.decision.tmp.$$" "$TMP/gn1.decision"
wait $bg
assert_eq "R1-36: gate_nonce survives a pending-clear -> same-second answer consumed" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_gn" 2>/dev/null)"

# --- R1-37: on a poll-loop TIMEOUT (no answer), the gate clears its own pending block
#     and reverts status to working, so the tile doesn't keep lying "waiting".
date +%s > "$HB"
TO='{"session_id":"to1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"sleep"}}'
( printf '%s' "$TO" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 \
    bash "$APP" > "$TMP/out_to" 2>/dev/null ) &
bg=$!
wait_block "$TMP/to1.json"
wait $bg   # let it time out (no answer ever written)
assert_eq "R1-37: timeout reverts status to working" "working" "$(jq -r '.status' "$TMP/to1.json" 2>/dev/null)"
assert_eq "R1-37: timeout clears the stale pending block" "null" "$(jq -r '.pending' "$TMP/to1.json" 2>/dev/null)"
assert_eq "R1-37: timeout clears the gate field" "null" "$(jq -r '.gate' "$TMP/to1.json" 2>/dev/null)"
assert_eq "R1-37: timeout clears the gate_nonce" "null" "$(jq -r '.gate_nonce' "$TMP/to1.json" 2>/dev/null)"
assert_eq "R1-37: timeout still falls through to native (no decision)" "" "$(cat "$TMP/out_to" 2>/dev/null)"

# --- R3-18: ownership-aware gate teardown. When a waiter resolves/times out, it must
#     ONLY delete the shared gate/gate_nonce if it is still the survivor. A concurrent
#     sibling that re-armed the gate (new top-level gate_nonce) must keep its protection.
#     Simulate: start a waiter, let it publish gate_nonce, then OVERWRITE the top-level
#     gate_nonce with a sibling's value before the first waiter times out. After timeout,
#     the gate/gate_nonce must SURVIVE (they belong to the sibling now).
date +%s > "$HB"
RT='{"session_id":"rt1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"sleep"}}'
( printf '%s' "$RT" | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 \
    bash "$APP" > "$TMP/out_rt" 2>/dev/null ) &
bg=$!
wait_block "$TMP/rt1.json"
# wait for the gate to publish gate_nonce, then a sibling re-arms with a NEW nonce
i=0
while [ "$i" -lt 100 ]; do
  [ -n "$(jq -r '.gate_nonce // empty' "$TMP/rt1.json" 2>/dev/null)" ] && break
  sleep 0.05; i=$((i+1))
done
jq -c '.gate_nonce="sibling-nonce"' "$TMP/rt1.json" > "$TMP/rt1.json.t" && mv "$TMP/rt1.json.t" "$TMP/rt1.json"
wait $bg   # first waiter times out; its NONCE != current gate_nonce -> must NOT tear down
assert_eq "R3-18: a non-survivor timeout leaves the sibling's gate armed" \
  "waiting" "$(jq -r '.gate' "$TMP/rt1.json" 2>/dev/null)"
assert_eq "R3-18: a non-survivor timeout leaves the sibling's gate_nonce intact" \
  "sibling-nonce" "$(jq -r '.gate_nonce' "$TMP/rt1.json" 2>/dev/null)"

# ---- #18: approveRepeats SIG must not conflate newline-resliced commands ------
# The old SIG collapsed newlines to spaces (tr '\n' ' '), so `docker compose
# restart api` and `docker compose restart\napi` -- two SEPARATE shell commands --
# shared one signature, and a single approval of the one-line form silently
# auto-allowed the multi-line reslice. The encoding must be injective.
rm -f "$CC_APPROVED_DIR"/* 2>/dev/null
rm -f "$HB"
# read path: a recorded ONE-LINE approval auto-allows the identical command...
printf 'Bash|docker compose restart api\n' > "$CC_APPROVED_DIR/sg1"
out="$(printf '%s' '{"session_id":"sg1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"docker compose restart api"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "#18: identical one-line command auto-allows (control)" "allow" "$(decision "$out")"
# ...but must NOT be inherited by the newline-resliced variant (no panel -> no output)
out="$(printf '%s' '{"session_id":"sg1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"docker compose restart\napi"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "#18: newline-resliced variant is NOT auto-allowed" "" "$out"
# write path: a panel allow of a MULTI-LINE command records a lossless SIG
# (backslash doubled, newline -> literal backslash-n)...
date +%s > "$HB"
MLREQ='{"session_id":"sg2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make build\nmake deploy"}}'
( printf '%s' "$MLREQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" >/dev/null 2>&1 ) &
bg=$!; wait_block "$TMP/sg2.json"; answer sg2 allow; wait $bg
assert_eq "#18: multi-line approval records the encoded SIG" \
  'Bash|make build\nmake deploy' "$(cat "$CC_APPROVED_DIR/sg2" 2>/dev/null)"
rm -f "$HB"
# ...which auto-allows only the IDENTICAL multi-line command
out="$(printf '%s' "$MLREQ" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "#18: identical multi-line command auto-allows" "allow" "$(decision "$out")"
# and the space-joined one-line form does NOT inherit it
out="$(printf '%s' '{"session_id":"sg2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make build make deploy"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "#18: space-joined form does NOT inherit the approval" "" "$out"
# injectivity corner: a command carrying a LITERAL backslash-n (two chars) must
# not collide with the real-newline form's encoding
printf 'Bash|a\\\\nb\n' > "$CC_APPROVED_DIR/sg3"   # SIG of literal a\nb: backslash doubled
out="$(printf '%s' '{"session_id":"sg3","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"a\nb"}}' \
  | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" bash "$APP" 2>/dev/null)"
assert_eq "#18: real newline never matches a literal backslash-n SIG" "" "$out"

# ---- #25-pin: newline/tab-separated gated-tools lists must GATE, not fail open.
# Lua's parseToolList/resolveGateTools split on ANY whitespace, so the panel shows
# these lists as armed -- but the shell's space-delimited `case " $GATE_TOOLS "`
# match required literal spaces: a multiline config string / one-tool-per-line
# override file / tab-separated list gated NOTHING (the R2-05 fail-open class).
# a) config string with an embedded newline: the token AFTER the \n is gated
date +%s > "$HB"
MLCFG="$TMP/tools-ml.json"
printf '%s' '{"gate":{"tools":"Bash\nWrite"}}' > "$MLCFG"
( printf '%s' '{"session_id":"ml1","cwd":"/x/p","tool_name":"Write","tool_input":{"file_path":"/x/p/a.txt"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$MLCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ml1" 2>/dev/null ) &
bg=$!; answer ml1 allow; wait $bg
assert_eq "#25-pin: multiline gate.tools string gates the after-newline tool" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ml1" 2>/dev/null)"
# ...and a tool OUTSIDE the multiline list still falls straight through
out="$(printf '%s' '{"session_id":"ml2","cwd":"/x/p","tool_name":"Read","tool_input":{"file_path":"/x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$MLCFG" CC_PANEL_MAX_AGE=99999 bash "$APP" 2>/dev/null)"
assert_eq "#25-pin: tool outside the multiline list falls through" "" "$out"
# b) tab-separated config string
date +%s > "$HB"
TABCFG="$TMP/tools-tab.json"
printf '%s' '{"gate":{"tools":"Bash\tWrite"}}' > "$TABCFG"
( printf '%s' '{"session_id":"tb1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$TABCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_tb1" 2>/dev/null ) &
bg=$!; answer tb1 allow; wait $bg
assert_eq "#25-pin: tab-separated gate.tools still gates" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_tb1" 2>/dev/null)"
# c) per-session override file written one-tool-per-line (the natural shell idiom)
date +%s > "$HB"
printf 'WebFetch\nBash\n' > "$CC_GATE_TOOLS_DIR/ovnl"
( printf '%s' '{"session_id":"ovnl","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ovnl" 2>/dev/null ) &
bg=$!; answer ovnl allow; wait $bg
assert_eq "#25-pin: one-tool-per-line override file still gates" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ovnl" 2>/dev/null)"

# ---- #14-pin (#26): gate arming fully REPLACES the pending block. cc_merge is a
# recursive jq merge, so a leftover AskUserQuestion `ask` array (published by
# cc-status.sh for this same session key) used to ride into the armed pending and
# render dead option buttons on the Bash approval tile -- clicking one fired
# picker keystrokes into a session with no picker focused.
date +%s > "$HB"
printf '%s' '{"session_id":"ask1","name":"p","cwd":"/x/p","status":"approval","updated":100,"since":100,"pending":{"tool":"AskUserQuestion","summary":"Pick one","ask":[{"question":"Pick one","header":"Q"}]}}' > "$TMP/ask1.json"
( printf '%s' '{"session_id":"ask1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make x"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_ask1" 2>/dev/null ) &
bg=$!
i=0; n=""
while [ "$i" -lt 100 ]; do   # wait for the ARMED pending (nonce published)
  n="$(jq -r '.pending.nonce // empty' "$TMP/ask1.json" 2>/dev/null)"
  [ -n "$n" ] && break
  sleep 0.05; i=$((i+1))
done
assert_eq "#14-pin: armed pending carries the gate's own tool" \
  "Bash" "$(jq -r '.pending.tool' "$TMP/ask1.json" 2>/dev/null)"
assert_eq "#14-pin: the stale AskUserQuestion ask array is dropped" \
  "null" "$(jq -r '.pending.ask' "$TMP/ask1.json" 2>/dev/null)"
answer ask1 allow; wait $bg
assert_eq "#14-pin: the armed request still resolves normally" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ask1" 2>/dev/null)"

# ---- #12-pin (#27): the pending/status teardown is ownership-aware (the R3-18
# completion). A resolving/timing-out waiter used to `cc_del_field pending` +
# merge status:working UNCONDITIONALLY, wiping a sibling waiter's freshly
# re-armed LIVE pending block (parallel subagents share the session key) -- the
# sibling's approval never reached the panel and it silently timed out.
# a) TIMEOUT path: waiter A times out while sibling B owns the tile
date +%s > "$HB"
( printf '%s' '{"session_id":"sib1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"slow thing"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=2 \
    bash "$APP" > "$TMP/out_sib1" 2>/dev/null ) &
bg=$!
wait_block "$TMP/sib1.json"
i=0
while [ "$i" -lt 100 ]; do   # wait for A's arming
  [ -n "$(jq -r '.pending.nonce // empty' "$TMP/sib1.json" 2>/dev/null)" ] && break
  sleep 0.05; i=$((i+1))
done
# sibling B re-arms: a FOREIGN nonce owns pending + gate now
jq -c '.pending={tool:"Write",summary:"sibling req",message:"sibling req",nonce:"sib-n"}
       | .gate="waiting" | .gate_nonce="sib-n" | .status="approval"' \
  "$TMP/sib1.json" > "$TMP/sib1.json.t" && mv "$TMP/sib1.json.t" "$TMP/sib1.json"
wait $bg   # A times out; it does NOT own the pending anymore
assert_eq "#12-pin: timeout leaves the sibling's live pending intact" \
  "sib-n" "$(jq -r '.pending.nonce' "$TMP/sib1.json" 2>/dev/null)"
assert_eq "#12-pin: timeout leaves the sibling's tool visible" \
  "Write" "$(jq -r '.pending.tool' "$TMP/sib1.json" 2>/dev/null)"
assert_eq "#12-pin: timeout does not flip the sibling's tile to working" \
  "approval" "$(jq -r '.status' "$TMP/sib1.json" 2>/dev/null)"
assert_eq "#12-pin: the sibling's gate shield survives (R3-18 half still holds)" \
  "waiting" "$(jq -r '.gate' "$TMP/sib1.json" 2>/dev/null)"
assert_eq "#12-pin: A still degrades to the native prompt" "" "$(cat "$TMP/out_sib1" 2>/dev/null)"
# b) RESOLVE path: waiter A is answered (own nonce) while sibling B owns the tile
date +%s > "$HB"
( printf '%s' '{"session_id":"sib2","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_sib2" 2>/dev/null ) &
bg=$!
wait_block "$TMP/sib2.json"
nonceA=""; i=0
while [ "$i" -lt 100 ]; do
  nonceA="$(jq -r '.pending.nonce // empty' "$TMP/sib2.json" 2>/dev/null)"
  [ -n "$nonceA" ] && break
  sleep 0.05; i=$((i+1))
done
jq -c '.pending={tool:"Write",summary:"sibling req",message:"sibling req",nonce:"sib-n"}
       | .gate="waiting" | .gate_nonce="sib-n" | .status="approval"' \
  "$TMP/sib2.json" > "$TMP/sib2.json.t" && mv "$TMP/sib2.json.t" "$TMP/sib2.json"
printf 'allow %s' "$nonceA" > "$TMP/sib2.decision.tmp.$$"   # panel answers waiter A by ITS nonce
mv "$TMP/sib2.decision.tmp.$$" "$TMP/sib2.decision"
wait $bg
assert_eq "#12-pin: the answered waiter still resolves allow" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_sib2" 2>/dev/null)"
assert_eq "#12-pin: an allow resolution leaves the sibling's pending intact" \
  "sib-n" "$(jq -r '.pending.nonce' "$TMP/sib2.json" 2>/dev/null)"
assert_eq "#12-pin: an allow resolution keeps the sibling's tile on approval" \
  "approval" "$(jq -r '.status' "$TMP/sib2.json" 2>/dev/null)"

# ---- #28-pin: the waiter VERIFIES its arming (~1Hz) and replays it if the
# shared status file was clobbered mid-wait (cc-status.sh's residual snapshot->mv
# lost-update window drops gate, pending AND gate_nonce in one shot -- the panel
# then has nothing to answer and the waiter polled blind to the full timeout).
date +%s > "$HB"
( printf '%s' '{"session_id":"ra1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"make y"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=6 \
    bash "$APP" > "$TMP/out_ra1" 2>/dev/null ) &
bg=$!
wait_block "$TMP/ra1.json"
GN1=""; i=0
while [ "$i" -lt 100 ]; do   # capture the original arming nonce
  GN1="$(jq -r '.gate_nonce // empty' "$TMP/ra1.json" 2>/dev/null)"
  [ -n "$GN1" ] && break
  sleep 0.05; i=$((i+1))
done
# simulate the clobber: a full pre-arm snapshot lands -- NO gate/pending/gate_nonce
jq -nc '{session_id:"ra1",name:"p",cwd:"/x/p",status:"working",updated:1,since:1}' \
  > "$TMP/ra1.json.t" && mv "$TMP/ra1.json.t" "$TMP/ra1.json"
GN2=""; i=0
while [ "$i" -lt 100 ]; do   # the ~1Hz verify pass must replay the arming
  GN2="$(jq -r '.gate_nonce // empty' "$TMP/ra1.json" 2>/dev/null)"
  [ -n "$GN2" ] && break
  sleep 0.05; i=$((i+1))
done
assert_eq "#28-pin: clobbered arming is replayed with the SAME nonce" "$GN1" "$GN2"
assert_eq "#28-pin: the replay restores the pending block" \
  "Bash" "$(jq -r '.pending.tool' "$TMP/ra1.json" 2>/dev/null)"
answer ra1 allow; wait $bg
assert_eq "#28-pin: the re-armed request is panel-answerable" \
  "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_ra1" 2>/dev/null)"

# ---- a denial carries Adam's reason back to the session (2026-09-18) ----
# The note never rides the decision line (a bare "<verb> <nonce>", read with
# `read -r VERB RNONCE _` and hard-validated for the ssh path): it travels in a
# sidecar, <key>.decision.note = {"nonce":..,"note":..}, written BEFORE the
# decision exactly like FX.writeDecision does, and bound to the same nonce.
DEFAULT_DENY="Denied from the Claude Shepherd panel."
start_gated() { # $1 = session id, $2 = out file [, extra env assignments via env]
  date +%s > "$HB"
  ( printf '%s' "{\"session_id\":\"$1\",\"cwd\":\"/x/p\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\"}}" \
      | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
      bash "$APP" > "$2" 2>/dev/null ) &
  bg=$!
  wait_block "$TMP/$1.json"
}
wait_nonce() { # $1 = key -> prints the published request nonce
  local n="" i=0
  while [ "$i" -lt 100 ]; do
    n="$(jq -r '.pending.nonce // empty' "$TMP/$1.json" 2>/dev/null)"
    [ -n "$n" ] && break
    sleep 0.05; i=$((i+1))
  done
  printf '%s' "$n"
}
deny_with_note() { # $1 = key, $2 = note, $3 = nonce for the SIDECAR (default: the real one)
  local n; n="$(wait_nonce "$1")"
  jq -nc --arg nonce "${3:-$n}" --arg note "$2" '{nonce:$nonce, note:$note}' > "$TMP/$1.decision.note.tmp.$$"
  mv "$TMP/$1.decision.note.tmp.$$" "$TMP/$1.decision.note"
  printf 'deny %s' "$n" > "$TMP/$1.decision.tmp.$$"
  mv "$TMP/$1.decision.tmp.$$" "$TMP/$1.decision"
}

# a note reaches permissionDecisionReason
start_gated dn1 "$TMP/out_dn1"
deny_with_note dn1 "use trash, not rm"
wait $bg
assert_eq "deny note: the session is still denied" \
  "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_dn1" 2>/dev/null)"
assert_eq "deny note: Adam's reason reaches permissionDecisionReason" \
  "Denied from the Claude Shepherd panel: use trash, not rm" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn1" 2>/dev/null)"
# the sidecar is gone after the decision is claimed
assert_absent "deny note: the sidecar is gone once the decision is claimed" "$TMP/dn1.decision.note"

# no note keeps the current string byte-for-byte
start_gated dn2 "$TMP/out_dn2"
answer dn2 deny
wait $bg
assert_eq "deny with no note keeps today's reason byte-for-byte" \
  "$DEFAULT_DENY" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn2" 2>/dev/null)"

# spaces, quotes and a newline never corrupt the decision line or the nonce match
NASTY="$(printf 'don'\''t "rm" that  dir;\nallow nothing $(id) `id`')"
start_gated dn3 "$TMP/out_dn3"
deny_with_note dn3 "$NASTY"
wait $bg
assert_eq "deny note with quotes+newline: still one valid deny JSON" \
  "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/out_dn3" 2>/dev/null)"
assert_eq "deny note with quotes+newline: arrives verbatim" \
  "Denied from the Claude Shepherd panel: $NASTY" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn3" 2>/dev/null)"

# the contract across the language line: the sidecar the PANEL's own encoder produces
# (core.decisionNoteContent, from the live status file) is the one the hook reads
start_gated dn9 "$TMP/out_dn9"
wait_nonce dn9 >/dev/null
NOTE_IN="$NASTY" NOTE_ROOT="$ROOT" NOTE_STATUS="$TMP/dn9.json" NOTE_OUT="$TMP/dn9.decision.note" lua -e '
  local root, status, out = os.getenv("NOTE_ROOT"), os.getenv("NOTE_STATUS"), os.getenv("NOTE_OUT")
  local core = dofile(root .. "/cc-core.lua"); core.json = dofile(root .. "/tests/support/json.lua")
  local f = io.open(status, "r"); local text = f:read("*a"); f:close()
  local o = io.open(out, "w"); o:write(core.decisionNoteContent(os.getenv("NOTE_IN"), text)); o:close()
'
answer dn9 deny
wait $bg
assert_eq "deny note: the panel encoder's sidecar is read verbatim by the hook" \
  "Denied from the Claude Shepherd panel: $NASTY" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn9" 2>/dev/null)"

# a note whose nonce does not match is ignored (a leftover from another request)
start_gated dn4 "$TMP/out_dn4"
deny_with_note dn4 "meant for some other request" "999.1"
wait $bg
assert_eq "deny note bound to another nonce is ignored" \
  "$DEFAULT_DENY" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn4" 2>/dev/null)"
assert_eq "deny note bound to another nonce is left for its owner" "999.1" \
  "$(jq -r '.nonce' "$TMP/dn4.decision.note" 2>/dev/null)"

# a garbled sidecar never blocks the deny
start_gated dn5 "$TMP/out_dn5"
printf 'not json {{{' > "$TMP/dn5.decision.note"
answer dn5 deny
wait $bg
assert_eq "garbled deny note: the deny still lands with the default reason" \
  "$DEFAULT_DENY" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out_dn5" 2>/dev/null)"

# an ALLOW never picks a note up, and still clears the one bound to it
start_gated dn6 "$TMP/out_dn6"
n6="$(wait_nonce dn6)"
jq -nc --arg nonce "$n6" '{nonce:$nonce, note:"stale"}' > "$TMP/dn6.decision.note"
answer dn6 allow
wait $bg
assert_eq "allow with a bound note: still a plain allow" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}' "$(cat "$TMP/out_dn6")"
assert_absent "allow with a bound note: the sidecar is cleared" "$TMP/dn6.decision.note"

# SessionEnd sweep: cc_remove takes the sidecar with the rest of the key's files
printf '{}' > "$TMP/dn7.json"; printf '{"nonce":"1.1","note":"x"}' > "$TMP/dn7.decision.note"
( . "$ROOT/cc-lib.sh"; cc_remove dn7 ) >/dev/null 2>&1
assert_absent "cc_remove sweeps the deny-note sidecar" "$TMP/dn7.decision.note"

# the ledger's human-deny event carries the reason
echo '{ "ledger": { "enabled": true } }' > "$TMP/ledger-cfg.json"
date +%s > "$HB"
( printf '%s' '{"session_id":"dn8","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
    | CC_GATE_FLAG="$FLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
      CC_CONFIG_FILE="$TMP/ledger-cfg.json" CC_LEDGER_DIR="$TMP/ledger" \
    bash "$APP" > "$TMP/out_dn8" 2>/dev/null ) &
bg=$!
wait_block "$TMP/dn8.json"
deny_with_note dn8 "wrong directory"
wait $bg
assert_eq "ledger: the human deny records Adam's reason" "wrong directory" \
  "$(cat "$TMP"/ledger/*.jsonl 2>/dev/null | jq -r 'select(.type=="decision" and .session_id=="dn8").reason')"

# ---- always-ask commands (2026-09-28) ----------------------------------------
# Build program unit 5. A fixed list of commands (git push, rm -rf, history rewrites, publish)
# is held for Adam's click whatever the gate flag, autopilot, autoAllow, approveRepeats or a
# bundle says; with no panel (or no answer) the hook answers "ask", so Claude Code's own
# prompt shows even in auto mode. The parser judges parsed words, so quoted text never matches.

# -- the parser (cc_always_ask_match in cc-lib.sh) --
aa() { # $1 command, $2 extras (newline-separated) -> "held:<rule>" | "free"
  ( set -u; . "$ROOT/cc-lib.sh"   # set -u, like cc-approve.sh: bash 3.2 trips on empty arrays
    if cc_always_ask_match "$1" "${2:-}"; then printf 'held:%s' "$CC_AA_RULE"; else printf 'free'; fi ) 2>/dev/null
}
held() { assert_eq "always-ask holds: $1" "held:$2" "$(aa "$1" "${3:-}")"; }
free() { assert_eq "always-ask leaves alone: $1" "free" "$(aa "$1" "${2:-}")"; }

held 'git push' 'git push'
held 'git push origin main --force' 'git push'
held 'cd x && git push' 'git push'
held 'git -C ../main push' 'git push'
held 'git -c user.name=x --git-dir=.git --work-tree . push' 'git push'
held 'git --no-pager push origin' 'git push'
held 'make build; git push' 'git push'
held 'make test || git push' 'git push'
held "$(printf 'git add .\ngit push')" 'git push'
held 'git push 2>&1 | tee push.log' 'git push'
held 'nohup git push &' 'git push'
held '(cd x && git push)' 'git push'
held '{ git push; }' 'git push'
held 'if true; then git push; fi' 'git push'
held 'for r in a b; do git push "$r"; done' 'git push'
held 'sh -c "git push"' 'git push'
held "bash -lc 'cd x && git push'" 'git push'
held 'zsh -c "git status; git push"' 'git push'
held 'bash -euo pipefail -c "git push"' 'git push'
held 'sudo -u me git push' 'git push'
held 'env -i FOO=1 git push' 'git push'
held 'GIT_SSH_COMMAND="ssh -v" git push' 'git push'
held 'time git push' 'git push'
held 'command git push' 'git push'
held 'exec git push' 'git push'
held 'echo main | xargs -n1 git push origin' 'git push'
held "trap 'git push' EXIT" 'git push'
held 'rm -rf build' 'rm -rf'
held 'rm -fr build' 'rm -rf'
held 'rm -r -f build' 'rm -rf'
held 'rm -Rf build' 'rm -rf'
held 'rm --recursive --force build' 'rm -rf'
held 'rm build -rf' 'rm -rf'
held '/bin/rm -rfv build' 'rm -rf'
held '\rm -rf build' 'rm -rf'
held "find . -name '*.tmp' -exec rm -rf {} \\;" 'rm -rf'
held 'find . -type d -execdir rm -fr {} +' 'rm -rf'
held 'git reset --hard' 'git reset --hard'
held 'git reset HEAD~1 --hard' 'git reset --hard'
held 'git clean -f' 'git clean -f'
held 'git clean -fdx' 'git clean -f'
held 'git clean --force' 'git clean -f'
held 'git branch -D old' 'git branch -D'
held 'git branch --delete --force old' 'git branch -D'
held 'git worktree remove --force wt' 'git worktree remove --force'
held 'git worktree remove -f wt' 'git worktree remove --force'
held 'git checkout -- .' 'git checkout -- .'
held 'git checkout .' 'git checkout -- .'
held 'npm publish' 'publish'
held 'deno publish --allow-dirty' 'publish'
held 'cargo publish -p crate' 'publish'
held 'yarn npm publish' 'publish'
held 'npx jsr publish' 'publish'
held 'pnpm -r publish' 'publish'
held 'gh release create v1.0' 'gh release create'
held 'gh pr merge 12 --squash' 'gh pr merge'
# a command substitution, a backtick and a heredoc fed to a shell are commands too
held 'echo $(git push)' 'git push'
held 'echo `git push`' 'git push'
held "$(printf 'bash <<EOF\ngit push\nEOF')" 'git push'
held 'eval "git push"' 'git push'
# escalation: a held word hidden behind eval, $VAR, $(...) or an unparseable heredoc
held 'CMD="git push"; eval "$CMD"' 'hidden command'
held 'GIT=git; $GIT push' 'hidden command'
held 'git $(echo push)' 'hidden command'
held 'CMD="git push"; bash -c "$CMD"' 'hidden command'
held "$(printf 'cat <<EOF\ngit push')" 'hidden command'
# extras (policies.alwaysAsk.patterns / a bundle's alwaysAsk): the command, then words it
# contains in that order
held 'terraform apply -auto-approve' 'terraform apply' 'terraform apply'
held 'kubectl -n prod delete pod x' 'kubectl delete' "$(printf 'terraform apply\nkubectl delete')"

free 'git status'
free 'git log --oneline -5'
free 'git commit -m "git push later"'
free "git commit -m 'rm -rf build'"
free 'echo "git push"'
free 'echo git push'
free "echo 'rm -rf /'"
free 'ls # git push'
free 'rm -r dir'
free 'rm -f file.txt'
free 'rm "$tmp"'
free 'git reset HEAD~1'
free 'git reset --soft HEAD~1'
free 'git clean -n'
free 'git branch -d old'
free 'git worktree remove wt'
free 'git checkout main'
free 'git checkout -- src/a.lua'
free 'git restore src/a.lua'
free 'gh pr view 12'
free 'gh release list'
free 'npm run publish-docs'
free 'grep -r publish .'
free 'echo publish'
free 'command -v git'
free 'bash script.sh'
free 'git push-hooks-lint'
free "$(printf 'cat <<EOF > notes.md\ngit push\nrm -rf /\nEOF')"
# Claude Code's own commit idiom: a heredoc inside $(...) inside "...", apostrophes and all
free "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nDon'"'"'t push: merge branch, then reset --hard later (rm -rf tmp)\nEOF\n)"')"
free 'terraform plan' 'terraform apply'

# the rules Settings lists (core.ALWAYS_ASK_BUILTINS) are the ones the matcher holds, by label
lua - "$ROOT/cc-core.lua" > "$TMP/aa-builtins.txt" 2>/dev/null <<'LUA'
local core = dofile(arg[1])
for _, b in ipairs(core.ALWAYS_ASK_BUILTINS or {}) do print(b.rule .. "\t" .. b.example) end
LUA
assert_eq "always-ask: core.ALWAYS_ASK_BUILTINS was read" "10" "$(grep -c . "$TMP/aa-builtins.txt")"
while IFS=$'\t' read -r rule ex; do
  held "$ex" "$rule"
done < "$TMP/aa-builtins.txt"

# -- the hook (cc-approve.sh) --
AA_NOFLAG="$TMP/aa-gate-off"          # never created: the gate stays unarmed
aa_req() { printf '{"session_id":"%s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# held on the card with the gate unarmed, and Adam's click answers it
date +%s > "$HB"
( aa_req aa1 'cd x && git push' | CC_GATE_FLAG="$AA_NOFLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_aa1" 2>/dev/null ) &
bg=$!; wait_block "$TMP/aa1.json"
wait_nonce aa1 >/dev/null
assert_eq "always-ask: held on the card with the gate unarmed" "waiting" "$(jq -r '.gate' "$TMP/aa1.json" 2>/dev/null)"
assert_eq "always-ask: the card names the rule" "git push" "$(jq -r '.pending.alwaysAsk // empty' "$TMP/aa1.json" 2>/dev/null)"
answer aa1 allow; wait $bg
assert_eq "always-ask: Adam's Approve on the card lets it run" "allow" "$(decision "$(cat "$TMP/out_aa1")")"

# panel down: "ask", so Claude Code's own prompt shows (even in auto mode)
rm -f "$HB"
out="$(aa_req aa2 'git push' | CC_GATE_FLAG="$AA_NOFLAG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: panel down gives ask" "ask" "$(decision "$out")"
assert_eq "always-ask: the ask says which rule held it" \
  "Claude Shepherd always asks before git push." "$(reason "$out")"
out="$(aa_req aa3 'git -C ../main push' | CC_GATE_FLAG="$FLAG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: git -C form gives ask (gate armed, no panel)" "ask" "$(decision "$out")"
out="$(aa_req aa4 'sh -c \"git push\"' | CC_GATE_FLAG="$FLAG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: wrapped form gives ask" "ask" "$(decision "$out")"

# nothing automatic passes it: autoAllow, autopilot, approveRepeats, bundle autopilot,
# a None gate override, a gate.tools without Bash
AAPOL="$TMP/aa-policy.json"
cat > "$AAPOL" <<'JSON'
{ "policies": {
    "patterns": { "enabled": true, "autoAllow": ["Bash", "Bash(git*)"], "autoDeny": [] },
    "autopilot": { "enabled": true, "minutes": 15 },
    "approveRepeats": true } }
JSON
aapol() { aa_req "$1" "$2" | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$AAPOL" "${@:3}" bash "$APP" 2>/dev/null; }
assert_eq "always-ask: autoAllow can't pass it" "ask" "$(decision "$(aapol aa5 'git push')")"
echo 9999999999 > "$CC_AUTOPILOT_DIR/aa6"
assert_eq "always-ask: autopilot can't pass it" "ask" "$(decision "$(aapol aa6 'git push')")"
printf 'Bash|git push\n' > "$CC_APPROVED_DIR/aa7"
assert_eq "always-ask: approveRepeats can't pass it" "ask" "$(decision "$(aapol aa7 'git push')")"
printf '{"autopilot":true,"autoAllow":["Bash"],"bundle":"loose"}' > "$CC_POLICY_DIR/aa8"
assert_eq "always-ask: bundle autopilot can't pass it" "ask" "$(decision "$(aapol aa8 'rm -rf build')")"
printf -- '-\n' > "$CC_GATE_TOOLS_DIR/aa9"
assert_eq "always-ask: a None gate override can't free it" "ask" "$(decision "$(aapol aa9 'git reset --hard')")"
assert_eq "always-ask: a gate.tools without Bash can't free it" "ask" \
  "$(decision "$(aapol aa10 'npm publish' env CC_GATE_TOOLS=Write)")"
# ...while the same policies still pass an ordinary command
assert_eq "always-ask: the policies still pass an ordinary command" "allow" "$(decision "$(aapol aa11 'git status')")"

# an Approve is never remembered for approveRepeats
rm -f "$CC_APPROVED_DIR/aa12"
date +%s > "$HB"
( aa_req aa12 'git push' | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$REPCFG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 \
    bash "$APP" > "$TMP/out_aa12" 2>/dev/null ) &
bg=$!; wait_block "$TMP/aa12.json"; answer aa12 allow; wait $bg
assert_eq "always-ask: the held request resolves on the card" "allow" "$(decision "$(cat "$TMP/out_aa12")")"
assert_eq "always-ask: an Approve is never remembered" "" "$(grep -F 'git push' "$CC_APPROVED_DIR/aa12" 2>/dev/null)"

# no answer before the timeout: "ask", never a silent fall-through
date +%s > "$HB"
out="$(aa_req aa13 'git push' | CC_GATE_FLAG="$AA_NOFLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 bash "$APP" 2>/dev/null)"
assert_eq "always-ask: a timeout gives ask" "ask" "$(decision "$out")"
assert_eq "always-ask: a timeout clears the card's pending block" "null" "$(jq -r '.pending' "$TMP/aa13.json" 2>/dev/null)"

# autoDeny still wins
rm -f "$HB"
DENYCFG="$TMP/aa-deny.json"
echo '{"policies":{"patterns":{"enabled":true,"autoDeny":["Bash(git push*)"]}}}' > "$DENYCFG"
out="$(aa_req aa14 'git push' | CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$DENYCFG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: autoDeny still wins" "deny" "$(decision "$out")"

# ordinary commands are untouched with the gate unarmed, even with the panel up
date +%s > "$HB"
for c in 'git status' 'rm -r dir' 'git commit -m \"git push later\"'; do
  out="$(aa_req aa15 "$c" | CC_GATE_FLAG="$AA_NOFLAG" CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=1 bash "$APP" 2>/dev/null)"
  assert_eq "always-ask: untouched with the gate unarmed: $c" "" "$out"
done

# extras from policies.alwaysAsk.patterns, and a bundle's alwaysAsk (the resolved policy file)
rm -f "$HB"
EXCFG="$TMP/aa-extras.json"
cat > "$EXCFG" <<'JSON'
{ "policies": { "alwaysAsk": { "patterns": ["terraform apply"] },
    "bundles": { "k8s": { "alwaysAsk": ["kubectl delete"] } } } }
JSON
out="$(aa_req aa16 'terraform apply -auto-approve' | CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$EXCFG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: an extra from policies.alwaysAsk.patterns is held" "ask" "$(decision "$out")"
printf '{"alwaysAsk":["kubectl delete"],"bundle":"k8s"}' > "$CC_POLICY_DIR/aa17"
out="$(aa_req aa17 'kubectl -n prod delete pod x' | CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$EXCFG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: a bundle's alwaysAsk is held" "ask" "$(decision "$out")"
out="$(aa_req aa18 'kubectl -n prod delete pod x' | CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$EXCFG" bash "$APP" 2>/dev/null)"
assert_eq "always-ask: a bundle's alwaysAsk binds only its own session" "" "$out"

# the ledger: the fallback is by alwaysAsk; Adam's own click stays by human
ALCFG="$TMP/aa-ledger.json"; echo '{ "ledger": { "enabled": true } }' > "$ALCFG"
rm -f "$HB"
aa_req aa19 'git push' | CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$ALCFG" CC_LEDGER_DIR="$TMP/aaledger" bash "$APP" >/dev/null 2>&1
# outcome "fallback" (handed to Claude Code, rendered ⚠) -- an "ask" outcome read as ✅/approved
assert_eq "always-ask ledger: the fallback is recorded by alwaysAsk with its rule" "fallback|alwaysAsk|git push" \
  "$(cat "$TMP"/aaledger/*.jsonl 2>/dev/null | jq -r 'select(.type=="decision" and .session_id=="aa19") | "\(.outcome)|\(.by)|\(.pattern)"')"
date +%s > "$HB"
( aa_req aa20 'git push' | CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$ALCFG" CC_LEDGER_DIR="$TMP/aaledger" \
    CC_PANEL_MAX_AGE=99999 CC_GATE_TIMEOUT=5 bash "$APP" >/dev/null 2>&1 ) &
bg=$!; wait_block "$TMP/aa20.json"; answer aa20 deny; wait $bg
assert_eq "always-ask ledger: Adam's deny stays by human, with the rule" "deny|human|git push" \
  "$(cat "$TMP"/aaledger/*.jsonl 2>/dev/null | jq -r 'select(.type=="decision" and .session_id=="aa20") | "\(.outcome)|\(.by)|\(.pattern)"')"

# the cheap check: a non-Bash tool, or a Bash command with no held word, spawns no jq
# (this hook runs for every tool call)
SPY="$TMP/jqspy"; mkdir -p "$SPY"; REALJQ="$(command -v jq)"
printf '#!/bin/sh\necho jq >> "%s/calls"\nexec "%s" "$@"\n' "$SPY" "$REALJQ" > "$SPY/jq"; chmod +x "$SPY/jq"
rm -f "$HB" "$SPY/calls"
printf '%s' '{"session_id":"aa21","cwd":"/x/p","tool_name":"Read","tool_input":{"file_path":"/x/p/a"}}' \
  | PATH="$SPY:$PATH" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$TMP/none.json" bash "$APP" >/dev/null 2>&1
printf '%s' '{"session_id":"aa21","cwd":"/x/p","tool_name":"Write","tool_input":{"file_path":"/x/p/a","content":"git push"}}' \
  | PATH="$SPY:$PATH" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$TMP/none.json" bash "$APP" >/dev/null 2>&1
assert_eq "always-ask: a non-Bash tool spawns no jq" "0" "$(grep -c . "$SPY/calls" 2>/dev/null || echo 0)"
rm -f "$SPY/calls"
aa_req aa21 'ls -la' | PATH="$SPY:$PATH" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$TMP/none.json" bash "$APP" >/dev/null 2>&1
assert_eq "always-ask: a Bash command with no held word spawns no jq" "0" "$(grep -c . "$SPY/calls" 2>/dev/null || echo 0)"
rm -f "$SPY/calls"
aa_req aa21 'git push' | PATH="$SPY:$PATH" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$TMP/none.json" bash "$APP" >/dev/null 2>&1
assert_eq "always-ask: ...and the spy does see a held one (control)" "yes" \
  "$([ "$(grep -c . "$SPY/calls" 2>/dev/null || echo 0)" -gt 0 ] && echo yes || echo no)"
# the empty list a Settings Save writes costs nothing beyond what any config costs
spycount() { # $1 config file -> jq calls for a Bash `ls -la` with the gate unarmed
  rm -f "$SPY/calls"
  aa_req aa21 'ls -la' | PATH="$SPY:$PATH" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$1" bash "$APP" >/dev/null 2>&1
  grep -c . "$SPY/calls" 2>/dev/null || echo 0
}
printf '{ "ledger": { "enabled": false } }' > "$TMP/aa-base.json"
printf '{ "policies": { "alwaysAsk": { "patterns": [ ] } } }' > "$TMP/aa-emptyx.json"
printf '{ "policies": { "alwaysAsk": { "patterns": [ "terraform apply" ] } } }' > "$TMP/aa-somex.json"
base="$(spycount "$TMP/aa-base.json")"
assert_eq "always-ask: an empty extras list spawns no extra jq" "$base" "$(spycount "$TMP/aa-emptyx.json")"
assert_eq "always-ask: ...while a real one is read (control)" "yes" \
  "$([ "$(spycount "$TMP/aa-somex.json")" -gt "$base" ] && echo yes || echo no)"

# ---- talk mode (build program unit 6, 2026-09-28) ------------------------------------------
# A session in talk mode (~/.claude/cc-talk/<key>, the panel's toggle) can read and talk but not
# change anything: the Edit family is denied outside ~/.claude/ and the scratchpads
# (/private/tmp/claude-*/), and a Bash command that isn't read-only (cc_cmd_readonly in
# cc-lib.sh) is denied -- gate armed or not. Talk mode only ever denies; what it lets through
# goes on to the always-ask layer and the gate as before.

# -- the judge (cc_cmd_readonly in cc-lib.sh) --
roj() { # $1 command -> "readonly" | "changes"
  ( . "$ROOT/cc-lib.sh"
    if cc_cmd_readonly "$1"; then printf 'readonly'; else printf 'changes'; fi ) 2>/dev/null
}
ro() { assert_eq "talk: read-only: $1" "readonly" "$(roj "$1")"; }
rw() { assert_eq "talk: not read-only: $1" "changes" "$(roj "$1")"; }

ro 'ls -la'
ro 'git status && ls'
ro 'cat README.md | head -20'
ro 'grep -rn "talk" docs/ | wc -l'
ro 'rg -n foo --glob "*.lua"'
ro 'tail -n 50 cc-lib.sh'
ro 'find . -name "*.lua" -not -path "./.claude/*"'
ro "sed -n '1,20p' cc-approve.sh"
ro "sed -n -e '/^## /p' -e '\$=' README.md"
ro "jq -r '.status' ~/.claude/cc-status/x.json"
ro 'git log --oneline -5'
ro "git log --format='%h %s' | head"
ro 'git diff HEAD~1 -- cc-lib.sh'
ro 'git show --stat HEAD'
ro 'git branch --list'
ro 'git branch -a'
ro 'git -C ../main status'
ro 'git config --get user.name'
ro 'git stash list'
ro 'git worktree list'
ro 'ls 2>/dev/null || true'
ro 'grep foo a.txt 2>&1 | sort | uniq -c'
ro 'cd docs && ls'
ro 'echo "rm -rf / > x"'
ro "$(printf 'cat <<EOF\ntext > not-a-file\nEOF')"
ro 'LC_ALL=C sort file.txt'
ro 'find . -type f | xargs grep -l foo'
ro 'bash -c "git status"'
ro 'wc -l $(git ls-files)'
ro 'diff <(ls a) <(ls b)'
ro 'ls # a comment > x'
ro 'for f in *.md; do head -3 "$f"; done'

rw 'make build'
rw 'rm file'
rw 'mkdir x'
rw 'echo hi > notes.txt'
rw 'ls >> log.txt'
rw 'ls 2> err.log'
rw 'cat a &> b'
rw 'ls > $OUT'
rw 'sort -o out.txt in.txt'
rw 'uniq in.txt out.txt'
rw "sed -i '' s/a/b/ f"
rw 'sed -ni p f'
rw "sed 's/a/b/' f"
rw "sed -n 'w out.txt' f"
rw "sed -n 's/a/b/w out.txt' f"
rw "sed -n '1e date' f"
rw 'find . -name x -delete'
rw 'find . -exec cat {} \;'
rw 'git commit -m "x"'
rw 'git branch new-feature'
rw 'git branch -D old'
rw 'git checkout main'
rw 'git stash'
rw 'git config user.name x'
rw 'git -c core.pager=less log'
rw 'git diff --output=patch.txt'
rw 'git push'
rw 'ls && touch x'
rw 'echo $(touch x)'
rw 'cat `rm x`'
rw 'bash -c "touch x"'
rw '$EDITOR notes.md'
rw 'eval ls'
rw './ls'
rw 'npm test'
rw 'tee out.txt < in.txt'
rw 'rg --pre ./conv foo'
rw 'printf x | xargs rm'
rw 'GIT_EXTERNAL_DIFF=./x git diff'
rw 'diff <(ls a) >(tee b)'
rw 'sudo ls'

# -- the hook (cc-approve.sh) --
TALK="$TMP/talk"; mkdir -p "$TALK"
TH="$TMP/talkhome"; mkdir -p "$TH/.claude"
talk_req() { # $1 session, $2 tool, $3 tool_input JSON
  printf '{"session_id":"%s","cwd":"/x/p","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3"
}
talk() { # $1 session, $2 tool, $3 tool_input JSON [, env assignments that override]
  talk_req "$1" "$2" "$3" \
    | env HOME="$TH" CC_TALK_DIR="$TALK" CC_GATE_FLAG="$AA_NOFLAG" "${@:4}" bash "$APP" 2>/dev/null
}
touch "$TALK/tk1"
rm -f "$HB"
out="$(talk tk1 Edit '{"file_path":"/x/p/cc-lib.sh","old_string":"a","new_string":"b"}')"
assert_eq "talk: an Edit in the project is denied, gate unarmed" "deny" "$(decision "$out")"
assert_eq "talk: ...with the talk-mode reason" "Talk mode: discussion only" "$(reason "$out")"
for t in Write MultiEdit; do
  out="$(talk tk1 "$t" '{"file_path":"/x/p/new.md","content":"x"}')"
  assert_eq "talk: a $t in the project is denied" "deny" "$(decision "$out")"
done
out="$(talk tk1 NotebookEdit '{"notebook_path":"/x/p/n.ipynb","new_source":"x"}')"
assert_eq "talk: a NotebookEdit in the project is denied" "deny" "$(decision "$out")"
out="$(talk tk1 Write "{\"file_path\":\"$TH/.claude/projects/p/memory/note.md\",\"content\":\"x\"}")"
assert_eq "talk: a Write under ~/.claude/ goes on (memory, plans)" "" "$out"
out="$(talk tk1 Write '{"file_path":"/private/tmp/claude-503/proj/sess/scratchpad/a.md","content":"x"}')"
assert_eq "talk: a Write in a session scratchpad goes on" "" "$out"
out="$(talk tk1 Write "{\"file_path\":\"$TH/.claude/../Programming/x.md\",\"content\":\"x\"}")"
assert_eq "talk: a path that climbs out of ~/.claude/ is denied" "deny" "$(decision "$out")"
out="$(talk tk1 Write '{"file_path":"/private/tmp/claude-503/../../Users/x.md","content":"x"}')"
assert_eq "talk: ...and one that climbs out of the scratchpad" "deny" "$(decision "$out")"
out="$(talk tk1 Write "{\"file_path\":\"$TH/.claudette/x.md\",\"content\":\"x\"}")"
assert_eq "talk: a sibling of ~/.claude/ is not ~/.claude/" "deny" "$(decision "$out")"
out="$(talk tk1 Bash '{"command":"git status && ls"}')"
assert_eq "talk: a read-only command goes on" "" "$out"
out="$(talk tk1 Bash '{"command":"make build"}')"
assert_eq "talk: a command that isn't read-only is denied" "deny" "$(decision "$out")"
assert_eq "talk: ...with the talk-mode reason (Bash)" "Talk mode: discussion only" "$(reason "$out")"
out="$(talk tk1 Bash '{"command":"echo hi > notes.txt"}')"
assert_eq "talk: a redirect to a file is denied" "deny" "$(decision "$out")"
out="$(talk tk1 Read '{"file_path":"/x/p/a.txt"}')"
assert_eq "talk: reading goes on" "" "$out"
out="$(talk tk2 Edit '{"file_path":"/x/p/cc-lib.sh","old_string":"a","new_string":"b"}')"
assert_eq "talk: another session's flag doesn't bind this one" "" "$out"

# deny wins over an always-ask hold; a read-only always-ask command stays held
out="$(talk tk1 Bash '{"command":"git push"}')"
assert_eq "talk: an always-ask command is denied, not held (deny wins)" "deny" "$(decision "$out")"
printf '{ "policies": { "alwaysAsk": { "patterns": ["cat secrets*"] } } }' > "$TMP/talk-aa.json"
out="$(talk tk1 Bash '{"command":"cat secrets.txt"}' CC_CONFIG_FILE="$TMP/talk-aa.json")"
assert_eq "talk: a read-only always-ask command stays held (ask, no panel)" "ask" "$(decision "$out")"

# nothing automatic passes it: autoAllow, autopilot (the gate armed)
out="$(talk tk1 Bash '{"command":"make build"}' CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$AAPOL")"
assert_eq "talk: autoAllow can't pass a denied command" "deny" "$(decision "$out")"
echo 9999999999 > "$CC_AUTOPILOT_DIR/tk1"
out="$(talk tk1 Bash '{"command":"make build"}' CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$AAPOL")"
assert_eq "talk: autopilot can't pass it" "deny" "$(decision "$out")"
out="$(talk tk2 Bash '{"command":"make build"}' CC_GATE_FLAG="$FLAG" CC_CONFIG_FILE="$AAPOL")"
assert_eq "talk: ...while the same policies pass it for a session not in talk mode" "allow" "$(decision "$out")"

# the ledger: by talk
echo '{ "ledger": { "enabled": true } }' > "$TMP/talk-ledger.json"
talk tk1 Bash '{"command":"make build"}' CC_CONFIG_FILE="$TMP/talk-ledger.json" CC_LEDGER_DIR="$TMP/talkledger" >/dev/null
assert_eq "talk ledger: the denial is recorded by talk" "deny|talk|make build" \
  "$(cat "$TMP"/talkledger/*.jsonl 2>/dev/null | jq -r 'select(.type=="decision" and .session_id=="tk1") | "\(.outcome)|\(.by)|\(.summary)"')"

# the cheap check: with no session in talk mode, or only another one, nothing here starts a jq
TALK0="$TMP/talk-empty"; mkdir -p "$TALK0"
talkspy() { # $1 talk dir, $2 session -> jq calls for a Write in the project, gate unarmed
  rm -f "$SPY/calls"
  talk_req "$2" Write '{"file_path":"/x/p/a","content":"x"}' \
    | PATH="$SPY:$PATH" CC_TALK_DIR="$1" CC_GATE_FLAG="$AA_NOFLAG" CC_CONFIG_FILE="$TMP/none.json" bash "$APP" >/dev/null 2>&1
  grep -c . "$SPY/calls" 2>/dev/null || echo 0
}
assert_eq "talk: an empty cc-talk/ spawns no jq" "0" "$(talkspy "$TALK0" tk3)"
assert_eq "talk: no cc-talk/ at all spawns no jq" "0" "$(talkspy "$TMP/talk-none" tk3)"
assert_eq "talk: another session's flag spawns no jq for this one" "0" "$(talkspy "$TALK" tk3)"
assert_eq "talk: ...and the spy does see a session in talk mode (control)" "yes" \
  "$([ "$(talkspy "$TALK" tk1)" -gt 0 ] && echo yes || echo no)"

# SessionEnd sweep: cc_remove takes the flag with the rest of the key's files
touch "$TALK/tk4"
( CC_TALK_DIR="$TALK"; . "$ROOT/cc-lib.sh"; cc_remove tk4 ) >/dev/null 2>&1
assert_absent "talk: cc_remove drops the talk-mode flag" "$TALK/tk4"

# ---- worktree fence (build program unit 7, 2026-09-28) ---------------------------------------
# With gate.fence on, a session can't change a sibling worktree of its own repo: one with the same
# git common dir and a different toplevel. The main checkout is a sibling of a linked worktree, but
# a session whose cwd IS the main checkout may change main. Denied, gate armed or not: an Edit-family
# file in a sibling; mutating git aimed at one through -C, --git-dir, --work-tree, GIT_DIR= or
# GIT_WORK_TREE=, or after cd <sibling>; a redirection into one. Read-only git is fine, and so is the
# session's own approved merge (git -C <main> merge --ff-only <its branch>).
FR="$(cd "$TMP" && pwd -P)/fence"
MAIN="$FR/main"; WA="$MAIN/.claude/worktrees/a"; WB="$MAIN/.claude/worktrees/b"
fgit() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
fgit init -q "$MAIN"
fgit -C "$MAIN" commit -q --allow-empty -m init
fgit -C "$MAIN" worktree add -q "$WA" -b wa
fgit -C "$MAIN" worktree add -q "$WB" -b wb
mkdir -p "$WA/sub" "$FR/plain"
fgit init -q "$FR/other"
FCFG="$TMP/fence-on.json"; printf '{ "gate": { "fence": true } }' > "$FCFG"
FOFF="$TMP/fence-off.json"; printf '{ "gate": { "fence": false } }' > "$FOFF"
FMERGE="$TMP/fmerge"; mkdir -p "$FMERGE"
fence_req() { # $1 session, $2 cwd, $3 tool, $4 tool_input JSON
  jq -nc --arg s "$1" --arg c "$2" --arg t "$3" --argjson i "$4" '{session_id:$s, cwd:$c, tool_name:$t, tool_input:$i}'
}
fence() { # $1 session, $2 cwd, $3 tool, $4 tool_input JSON [, env assignments that override]
  fence_req "$1" "$2" "$3" "$4" \
    | env CC_CONFIG_FILE="$FCFG" CC_GATE_FLAG="$AA_NOFLAG" CC_MERGE_DIR="$FMERGE" "${@:5}" bash "$APP" 2>/dev/null
}
edit_in() { jq -nc --arg p "$1" '{file_path:$p, old_string:"a", new_string:"b"}'; }
cmd_in() { jq -nc --arg c "$1" '{command:$c}'; }
fdeny() { # $1 name, $2 cwd, $3 command -> denied
  assert_eq "fence: $1" "deny" "$(decision "$(fence f1 "$2" Bash "$(cmd_in "$3")")")"
}
fallow() { # $1 name, $2 cwd, $3 command -> left alone
  assert_eq "fence: $1" "" "$(fence f1 "$2" Bash "$(cmd_in "$3")")"
}
rm -f "$HB"

# the Edit family
out="$(fence f1 "$WA" Edit "$(edit_in "$WB/x.txt")")"
assert_eq "fence: an Edit into a sibling worktree is denied, gate unarmed" "deny" "$(decision "$out")"
assert_eq "fence: ...naming the path" "Worktree fence: $WB/x.txt belongs to another worktree of this repo" "$(reason "$out")"
out="$(fence f1 "$WA" Write "$(jq -nc --arg p "$MAIN/README.md" '{file_path:$p, content:"x"}')")"
assert_eq "fence: a Write into the main checkout from a linked worktree is denied" "deny" "$(decision "$out")"
out="$(fence f1 "$WA" NotebookEdit "$(jq -nc --arg p "$WB/n.ipynb" '{notebook_path:$p, new_source:"x"}')")"
assert_eq "fence: a NotebookEdit into a sibling is denied" "deny" "$(decision "$out")"
out="$(fence f1 "$WA" Edit "$(edit_in "$WA/../b/deep/new.txt")")"
assert_eq "fence: a path that climbs into a sibling is denied" "deny" "$(decision "$out")"
assert_eq "fence: own edits go on" "" "$(fence f1 "$WA" Edit "$(edit_in "$WA/sub/new.txt")")"
assert_eq "fence: ...a relative one too" "" "$(fence f1 "$WA" Edit "$(edit_in "sub/x.txt")")"
assert_eq "fence: a session in the main checkout may change main" "" "$(fence f1 "$MAIN" Edit "$(edit_in "$MAIN/README.md")")"
out="$(fence f1 "$MAIN" Edit "$(edit_in "$WB/x.txt")")"
assert_eq "fence: ...but not a linked worktree under it" "deny" "$(decision "$out")"
assert_eq "fence: another repo is not a sibling" "" "$(fence f1 "$WA" Edit "$(edit_in "$FR/other/x.txt")")"
assert_eq "fence: a folder in no repo is not a sibling" "" "$(fence f1 "$WA" Edit "$(edit_in "$FR/plain/x.txt")")"
assert_eq "fence: reading a sibling goes on" "" "$(fence f1 "$WA" Read "$(jq -nc --arg p "$WB/x.txt" '{file_path:$p}')")"

# mutating git aimed at a sibling
out="$(fence f1 "$WA" Bash "$(cmd_in "git -C $WB commit -m x")")"
assert_eq "fence: git -C sibling commit is denied" "deny" "$(decision "$out")"
assert_eq "fence: ...naming the sibling" "Worktree fence: $WB belongs to another worktree of this repo" "$(reason "$out")"
fdeny "git -C <main> commit from a linked worktree is denied" "$WA" "git -C $MAIN commit -m x"
fdeny "a relative git -C ../b is denied" "$WA" "git -C ../b add ."
fdeny "cd sibling && git commit is denied" "$WA" "cd $WB && git commit -m x"
fdeny "cd ../b; git add is denied" "$WA" "cd ../b; git add -A"
fdeny "(cd sibling && git commit) is denied" "$WA" "(cd $WB && git commit -m x)"
fdeny "sh -c \"cd sibling && git commit\" is denied" "$WA" "sh -c \"cd $WB && git commit -m x\""
fdeny "git --git-dir=<sibling's> commit is denied" "$WA" "git --git-dir=$MAIN/.git/worktrees/b commit -m x"
fdeny "GIT_DIR=<main's .git> git commit is denied" "$WA" "GIT_DIR=$MAIN/.git git commit -m x"
fdeny "git --work-tree=sibling add is denied" "$WA" "git --work-tree=$WB add ."
fdeny "GIT_WORK_TREE=sibling git add is denied" "$WA" "GIT_WORK_TREE=$WB git add -A"
fdeny "git -C sibling checkout is denied" "$WA" "git -C $WB checkout -b other"
fdeny "a redirection into a sibling is denied" "$WA" "cd $WB && git log > log.txt"
fdeny "...an absolute one too" "$WA" "git log > $WB/log.txt"
fdeny "a session in main can't commit in a linked worktree under it" "$MAIN" "git -C $WB commit -m x"
out="$(fence f1 "$WA" Bash "$(cmd_in "git -C $WB push")")"
assert_eq "fence: deny wins over an always-ask hold" "deny" "$(decision "$out")"

# read-only git and the session's own tree
fallow "git -C sibling status is allowed" "$WA" "git -C $WB status"
fallow "git -C main log / diff / show are allowed" "$WA" "git -C $MAIN log --oneline -3 && git -C $MAIN diff && git -C $MAIN show HEAD"
fallow "git -C main rev-parse / merge-base / worktree list are allowed" "$WA" "git -C $MAIN rev-parse HEAD; git -C $MAIN merge-base main wa; git -C $MAIN worktree list"
fallow "cd sibling && git status is allowed" "$WA" "cd $WB && git status && git log -1"
fallow "cd sibling && git log > /dev/null is allowed" "$WA" "cd $WB && git log > /dev/null 2>&1"
fallow "own git goes on" "$WA" "git add -A && git commit -m x"
fallow "git -C <own> commit goes on" "$WA" "git -C $WA commit -m x"
fallow "cd sub && git commit goes on" "$WA" "cd sub && git commit -m x"
fallow "a quoted cd in a commit message is only words" "$WA" "git commit -m \"cd $WB && git commit\""
fallow "a session in main may commit main" "$MAIN" "git commit -m x && git -C $MAIN merge --ff-only wa"
fallow "another repo is not a sibling (git)" "$WA" "git -C $FR/other commit -m x"

# fence off: everything goes on
assert_eq "fence off: an Edit into a sibling goes on" "" "$(fence f1 "$WA" Edit "$(edit_in "$WB/x.txt")" CC_CONFIG_FILE="$FOFF")"
assert_eq "fence off: git -C sibling commit goes on" "" "$(fence f1 "$WA" Bash "$(cmd_in "git -C $WB commit -m x")" CC_CONFIG_FILE="$FOFF")"
assert_eq "fence unset: an Edit into a sibling goes on" "" "$(fence f1 "$WA" Edit "$(edit_in "$WB/x.txt")" CC_CONFIG_FILE="$TMP/none.json")"

# the one exception: this session's own approved merge
fmreq() { # $1 session, $2 phase, $3 branch
  jq -nc --arg p "$2" --arg b "$3" --arg w "$WA" --arg c "$MAIN/.git" \
    '{v:1, phase:$p, branch:$b, base:"main", worktree:$w, commonDir:$c}' > "$FMERGE/$1.json"
}
FFM="$(cmd_in "git -C $MAIN merge --ff-only wa")"
fmreq f9 approved wa
assert_eq "fence: the approved merge git -C <main> merge --ff-only <own branch> goes on" "" "$(fence f9 "$WA" Bash "$FFM")"
assert_eq "fence: ...and its cd <main> && form" "" "$(fence f9 "$WA" Bash "$(cmd_in "cd $MAIN && git merge --ff-only wa")")"
assert_eq "fence: ...but no other branch" "deny" "$(decision "$(fence f9 "$WA" Bash "$(cmd_in "git -C $MAIN merge --ff-only wb")")")"
assert_eq "fence: ...and no merge that isn't --ff-only" "deny" "$(decision "$(fence f9 "$WA" Bash "$(cmd_in "git -C $MAIN merge wa")")")"
assert_eq "fence: ...and nothing chained after it" "deny" \
  "$(decision "$(fence f9 "$WA" Bash "$(cmd_in "git -C $MAIN merge --ff-only wa && git -C $MAIN commit -m x")")")"
assert_eq "fence: another session's approval doesn't count" "deny" "$(decision "$(fence f8 "$WA" Bash "$FFM")")"
fmreq f9 requested wa
assert_eq "fence: a merge request not yet approved doesn't count" "deny" "$(decision "$(fence f9 "$WA" Bash "$FFM")")"
fmreq f9 approved wb
assert_eq "fence: an approval for another branch doesn't count" "deny" "$(decision "$(fence f9 "$WA" Bash "$FFM")")"

# the ledger: by fence
echo '{ "gate": { "fence": true }, "ledger": { "enabled": true } }' > "$TMP/fence-ledger.json"
fence f1 "$WA" Bash "$(cmd_in "git -C $WB commit -m x")" CC_CONFIG_FILE="$TMP/fence-ledger.json" CC_LEDGER_DIR="$TMP/fenceledger" >/dev/null
assert_eq "fence ledger: the denial is recorded by fence" "deny|fence|git -C $WB commit -m x" \
  "$(cat "$TMP"/fenceledger/*.jsonl 2>/dev/null | jq -r 'select(.type=="decision" and .session_id=="f1") | "\(.outcome)|\(.by)|\(.summary)"')"

# the cheap path: a plain command, an own edit and own git spawn no git (this hook runs for every
# tool call); a request aimed outside the cwd's own toplevel does
GSPY="$TMP/gitspy"; mkdir -p "$GSPY"; REALGIT="$(command -v git)"
printf '#!/bin/sh\necho git >> "%s/calls"\nexec "%s" "$@"\n' "$GSPY" "$REALGIT" > "$GSPY/git"; chmod +x "$GSPY/git"
gitspy() { # $1 tool, $2 tool_input JSON -> git calls for session f1 in worktree a
  rm -f "$GSPY/calls"
  fence_req f1 "$WA" "$1" "$2" | PATH="$GSPY:$PATH" CC_CONFIG_FILE="$FCFG" CC_GATE_FLAG="$AA_NOFLAG" \
    CC_MERGE_DIR="$FMERGE" bash "$APP" >/dev/null 2>&1
  grep -c . "$GSPY/calls" 2>/dev/null || echo 0
}
assert_eq "fence: a plain command spawns no git" "0" "$(gitspy Bash "$(cmd_in "make build")")"
assert_eq "fence: an own edit spawns no git" "0" "$(gitspy Edit "$(edit_in "$WA/sub/new.txt")")"
assert_eq "fence: an edit outside any repo spawns no git" "0" "$(gitspy Edit "$(edit_in "$FR/plain/x.txt")")"
assert_eq "fence: own git spawns no git" "0" "$(gitspy Bash "$(cmd_in "git add -A && git commit -m x")")"
assert_eq "fence: cd into its own subfolder spawns no git" "0" "$(gitspy Bash "$(cmd_in "cd sub && git commit -m x")")"
assert_eq "fence: ...and the spy does see a sibling one (control)" "yes" \
  "$([ "$(gitspy Bash "$(cmd_in "git -C $WB commit -m x")")" -gt 0 ] && echo yes || echo no)"
# jq: any config file costs a jq or two at load (the malformed check, gate.tools), so the fence's
# own cost is the difference between the fence on and off
jqspy() { # $1 config, $2 tool, $3 tool_input JSON -> jq calls
  rm -f "$SPY/calls"
  fence_req f1 "$WA" "$2" "$3" | PATH="$SPY:$PATH" CC_CONFIG_FILE="$1" CC_GATE_FLAG="$AA_NOFLAG" bash "$APP" >/dev/null 2>&1
  grep -c . "$SPY/calls" 2>/dev/null || echo 0
}
assert_eq "fence: an own edit spawns no jq beyond what the fence off costs" \
  "$(jqspy "$FOFF" Edit "$(edit_in "$WA/sub/new.txt")")" "$(jqspy "$FCFG" Edit "$(edit_in "$WA/sub/new.txt")")"
assert_eq "fence: ...nor does a plain command" \
  "$(jqspy "$FOFF" Bash "$(cmd_in "make build")")" "$(jqspy "$FCFG" Bash "$(cmd_in "make build")")"
assert_eq "fence: ...nor own git" \
  "$(jqspy "$FOFF" Bash "$(cmd_in "git commit -m x")")" "$(jqspy "$FCFG" Bash "$(cmd_in "git commit -m x")")"

# defaults/: a fresh install has the fence on
assert_eq "fence: defaults/cc-config.json turns gate.fence on" "true" \
  "$(jq -r '.gate.fence' "$ROOT/defaults/cc-config.json")"

finish
