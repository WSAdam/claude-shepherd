#!/usr/bin/env bash
#
# cc-approve.sh - opt-in PreToolUse approval gate for Claude Shepherd, with policies.
#
# When armed (~/.claude/cc-gate.enabled), a permission request for a gated tool is
# first run through automatic policies (all OFF by default, configured in
# ~/.claude/cc-config.json); if none decides, it's routed to the panel for a human
# Approve/Deny. SAFE TO WIRE UNCONDITIONALLY: disabled gate, non-gated tool, or no
# decision + dead panel all fall straight back to Claude Code's native flow.
#
# Policy order (auto-decisions fire even if the panel isn't running):
#   1. policies.patterns.autoDeny   -> deny   (safety first)
#   2. policies.autopilot           -> allow  (this session, time-boxed)
#   3. policies.patterns.autoAllow  -> allow
#   4. policies.approveRepeats      -> allow  (same request approved before)
#   else -> panel; on a human "allow", remember it for approveRepeats.
#
# Only the decision JSON is ever written to stdout; logs go to stderr.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

GATE_FLAG="${CC_GATE_FLAG:-${HOME}/.claude/cc-gate.enabled}"
# Gated tools: env override (tests) wins, else the panel-editable `gate.tools`
# config string, else the default 5. Commas AND newlines/tabs are normalized to
# spaces: core.parseToolList/resolveGateTools split on any whitespace, so a
# hand-edited multiline "Bash\nWrite" string must gate too -- the space-only
# match below would otherwise fail OPEN while the panel shows those tools as
# gated (same fail-open class R2-05 fixed for the JSON-array form).
GATE_TOOLS="${CC_GATE_TOOLS:-$(cc_config_toollist)}"
GATE_TOOLS="${GATE_TOOLS:-Bash Write Edit MultiEdit NotebookEdit}"
GATE_TOOLS="$(printf '%s' "$GATE_TOOLS" | tr ',\n\t\r' '    ')"
GATE_TIMEOUT="${CC_GATE_TIMEOUT:-120}"
HEARTBEAT_MAX_AGE="${CC_PANEL_MAX_AGE:-5}"
APPROVED_DIR="$CC_APPROVED_DIR"    # defined in cc-lib.sh so SessionEnd can clean it
AUTOPILOT_DIR="$CC_AUTOPILOT_DIR"  # (same env-var overrides as before)
# Per-session gated-tools overrides (Feature D): one file per key, like cc-autopilot.
GATE_TOOLS_DIR="${CC_GATE_TOOLS_DIR:-${HOME}/.claude/cc-gate-tools}"
# Per-session resolved policy bundle (L2): one JSON file per key, written by the
# panel (core.resolvePolicy → {autoAllow,autoDeny,bundle}). When present its lists
# are AUTHORITATIVE and apply REGARDLESS of policies.patterns.enabled (attaching a
# bundle is an explicit opt-in). Absent → fall back to the fleet policies.patterns.*
# gated by .policies.patterns.enabled (unchanged). KEEP IN SYNC with
# core.resolvePolicy in cc-core.lua (which produces this file's contents).
POLICY_DIR="${CC_POLICY_DIR:-${HOME}/.claude/cc-policy}"

emit_allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
}
emit_deny() { # $1 = reason. Built via jq so a reason with quotes/backslashes can't
  # produce invalid JSON (jq is guaranteed here: the script exits early without it).
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# Match a request against a policy pattern. "Tool" matches by tool name;
# "Tool(glob)" also requires the command/summary to match the shell glob.
pattern_match() { # $1 tool, $2 summary, $3 pattern  -> 0 if match
  local tool="$1" cmd="$2" pat="$3" ptool inner
  case "$pat" in
    *"("*")")
      ptool="${pat%%(*}"
      inner="${pat#*(}"; inner="${inner%)}"
      [ "$tool" = "$ptool" ] || return 1
      case "$cmd" in $inner) return 0 ;; *) return 1 ;; esac
      ;;
    *)
      [ "$tool" = "$pat" ] && return 0 || return 1
      ;;
  esac
}

INPUT="$(cat 2>/dev/null || true)"

# Disabled -> normal flow.
[ -f "$GATE_FLAG" ] || exit 0
cc_have_jq || exit 0

TOOL="$(cc_get "$INPUT" '.tool_name')"

# Key derivation moves ABOVE the gated-tool check so the per-session override can be
# consulted (the override is keyed by session). The extra cost for a non-gated tool
# is one cc_key (a tr), negligible.
SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
NAME="$(basename "$CWD")"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

# Per-session gated-tools override (Feature D, least-privilege). A dedicated file
# mirrors cc-autopilot/<key>: absent -> use the fleet GATE_TOOLS computed above;
# "-"/"NONE" (any case) -> gate NOTHING for this session; else gate exactly the
# listed tools (commas/newlines/tabs normalized to spaces -- a one-tool-per-line
# file is the natural shell idiom and must gate, not silently fail open). One
# cat, no jq, on the hot path.
# KEEP IN SYNC with core.resolveGateTools in cc-core.lua: an EMPTY/whitespace file is
# NOT a "gate nothing" sentinel -- it leaves the fleet GATE_TOOLS untouched (so a
# blank or half-written override never silently disables the gate). Only "-"/"none".
if [ -f "$GATE_TOOLS_DIR/$KEY" ]; then
  OVR="$(cat "$GATE_TOOLS_DIR/$KEY" 2>/dev/null | tr ',\n\t\r' '    ')"
  case "$(printf '%s' "$OVR" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
    '')      : ;;                         # empty/whitespace -> no override (fleet default)
    -|none)  GATE_TOOLS="" ;;             # sentinel -> gate nothing this session
    *)       GATE_TOOLS="$OVR" ;;         # session-specific list wins
  esac
fi

# L2: the per-session resolved policy file (named bundle), keyed like the override
# above. Read once here (KEY is known); match_patterns consults it on the hot path.
POLICY_FILE="$POLICY_DIR/$KEY"
POLICY_BUNDLE=""
[ -f "$POLICY_FILE" ] && POLICY_BUNDLE="$(jq -r '.bundle // empty' "$POLICY_FILE" 2>/dev/null || true)"

# Not a gated tool (for this session) -> normal flow (reads etc. stay fast).
case " $GATE_TOOLS " in
  *" $TOOL "*) ;;
  *) exit 0 ;;
esac

# A short summary of what's being approved (Bash command, file path, notebook,
# URL...). KEEP IN SYNC with summarize_tool in cc-status.sh.
SUMMARY="$(cc_get "$INPUT" '.tool_input.command')"
[ -n "$SUMMARY" ] || SUMMARY="$(cc_get "$INPUT" '.tool_input.file_path')"
[ -n "$SUMMARY" ] || SUMMARY="$(cc_get "$INPUT" '.tool_input.notebook_path')"
[ -n "$SUMMARY" ] || SUMMARY="$(cc_get "$INPUT" '.tool_input.url')"
if [ -n "$SUMMARY" ]; then
  # The memo file is one SIG per line (grep -Fxq), so newlines in the summary
  # must be encoded -- but LOSSLESSLY. The old `tr '\n' ' '` collapsed them to
  # spaces, so `docker compose restart api` and `docker compose restart\napi`
  # (two SEPARATE shell commands) shared one SIG and a single approval of the
  # one-line form auto-allowed any newline-resliced variant. Escape '\' first,
  # then newline -> '\n', so the encoding is injective; single-line summaries
  # without backslashes keep their old byte-identical SIG.
  SIG_SUM="${SUMMARY//\\/\\\\}"
  SIG_SUM="${SIG_SUM//$'\n'/\\n}"
  SIG="$(printf '%s|%s' "$TOOL" "$SIG_SUM")"
else
  # No recognized field: keep the SIG per-request with a digest of the whole
  # tool_input (canonicalized by jq -S). A bare "Tool|Tool" SIG would let ONE
  # approveRepeats approval blanket-approve every future call of the tool.
  SIG="$(printf '%s|%s' "$TOOL" "$(printf '%s' "$INPUT" | jq -cS '.tool_input // {}' | cksum | tr ' ' '-')")"
  SUMMARY="$TOOL"
fi

# transcript_path -> stable projectKey (mirrors cc-core), for ledger lines.
TRANSCRIPT="$(cc_get "$INPUT" '.transcript_path')"
PROJECT_KEY=""
case "$TRANSCRIPT" in
  */projects/*/*.jsonl) PROJECT_KEY="${TRANSCRIPT##*/projects/}"; PROJECT_KEY="${PROJECT_KEY%%/*}" ;;
esac

# Append a `decision` event to the audit ledger. The gate branch IS the provenance.
# $1=outcome (allow|deny|fallback)  $2=by  $3=pattern (optional)
ledger_decision() {
  cc_ledger_enabled || return 0
  cc_ledger_append "$(jq -nc \
    --arg sid "$SESSION_ID" --arg key "$KEY" --arg name "$NAME" \
    --arg pk "$PROJECT_KEY" --arg cwd "$CWD" --arg tool "$TOOL" --arg sum "$SUMMARY" \
    --arg out "$1" --arg by "$2" --arg pat "${3:-}" \
    '{type:"decision", session_id:$sid, key:$key, name:$name, projectKey:$pk, cwd:$cwd,
      tool:$tool, summary:$sum, outcome:$out, by:$by}
     + (if $pat == "" then {} else {pattern:$pat} end)')"
}

# ---- Policy evaluation (Phase 4c) -----------------------------------------
PAT_ENABLED="$(cc_config '.policies.patterns.enabled' 'false')"

# Run the request against a config pattern list; on the FIRST match, log + record
# the ledger decision + emit it + exit. Shared by autoDeny and autoAllow (the two
# loops were byte-identical apart from the verb). $1 = jq path to the list,
# $2 = outcome (deny|allow), $3 = "by" label. No-op when patterns are disabled.
# L2: when a per-session POLICY_FILE exists its lists win and apply regardless of
# PAT_ENABLED (bundle = explicit opt-in); the ledger `by` carries the bundle name.
# Otherwise read the fleet `.policies.patterns.<leaf>` gated by PAT_ENABLED (old
# behavior). $1 = leaf (autoAllow|autoDeny), $2 = outcome (deny|allow), $3 = by.
match_patterns() {
  local leaf="$1" pats pat by="$3"
  if [ -f "$POLICY_FILE" ]; then
    pats="$(jq -r --arg k "$leaf" '.[$k][]? // empty' "$POLICY_FILE" 2>/dev/null)"
    [ -n "$POLICY_BUNDLE" ] && by="bundle:$POLICY_BUNDLE"
  else
    [ "$PAT_ENABLED" = "true" ] || return 0
    pats="$(cc_config_array ".policies.patterns.$leaf")"
  fi
  [ -n "$pats" ] || return 0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if pattern_match "$TOOL" "$SUMMARY" "$pat"; then
      if [ "$2" = "deny" ]; then
        echo "[cc-approve] ⛔ policy auto-deny ($pat): $TOOL ($KEY)" >&2
        ledger_decision deny "$by" "$pat"
        emit_deny "Auto-denied by Claude Shepherd policy."
      else
        echo "[cc-approve] ✅ policy auto-allow ($pat): $TOOL ($KEY)" >&2
        ledger_decision allow "$by" "$pat"
        emit_allow
      fi
      exit 0
    fi
  done <<< "$pats"
}

# 1. autoDeny (safety first)
match_patterns autoDeny deny autoDeny

# 2a. bundle autopilot: an attached/per-session bundle set autopilot:true. This is
# POLICY_FILE-authoritative (the resolved-policy file the panel writes), mirroring
# how autoAllow/autoDeny already honor POLICY_FILE. Placed AFTER autoDeny so deny
# still wins ("auto-approve everything not denied").
if [ -f "$POLICY_FILE" ] && [ "$(jq -r '.autopilot // empty' "$POLICY_FILE" 2>/dev/null)" = "true" ]; then
  echo "[cc-approve] 🛫 bundle autopilot auto-allow: $TOOL ($KEY)" >&2
  ledger_decision allow "bundle:${POLICY_BUNDLE:-?}"
  emit_allow
  exit 0
fi

# 2b. autopilot: this session is trusted for a time-boxed window
if [ "$(cc_config '.policies.autopilot.enabled' 'false')" = "true" ] && [ -f "$AUTOPILOT_DIR/$KEY" ]; then
  EXP="$(cat "$AUTOPILOT_DIR/$KEY" 2>/dev/null || echo 0)"
  case "$EXP" in ''|*[!0-9]*) EXP=0 ;; esac  # empty file: cat succeeds, so `|| echo 0` never runs
  if [ "$(cc_now)" -lt "$EXP" ]; then
    echo "[cc-approve] 🛫 autopilot auto-allow: $TOOL ($KEY)" >&2
    ledger_decision allow autopilot
    emit_allow
    exit 0
  fi
fi

# 3. autoAllow patterns
# SECURITY: an autoAllow glob is a PREFIX/shell-glob match on the command, so
# `Bash(ls*)` also auto-allows `ls; rm -rf /` or `ls && curl … | sh`. Keep
# autoAllow patterns tight (prefer exact tools like `Read`, or anchored commands)
# — autoDeny runs first and always wins, so deny dangerous shapes there.
match_patterns autoAllow allow autoAllow

# 4. approveRepeats: identical request already approved this session
if [ "$(cc_config '.policies.approveRepeats' 'false')" = "true" ]; then
  if [ -f "$APPROVED_DIR/$KEY" ] && grep -Fxq "$SIG" "$APPROVED_DIR/$KEY" 2>/dev/null; then
    echo "[cc-approve] 🔁 auto-allow (approved before): $TOOL ($KEY)" >&2
    ledger_decision allow approveRepeats
    emit_allow
    exit 0
  fi
fi

# ---- No policy decided: route to the panel --------------------------------
# Panel must be alive (fresh heartbeat) or we'd block on nothing -> normal flow.
HB_FILE="$(cc_heartbeat_file)"
[ -f "$HB_FILE" ] || exit 0
HB="$(cat "$HB_FILE" 2>/dev/null || echo 0)"
case "$HB" in *[!0-9]*) HB=0 ;; esac
AGE=$(( $(cc_now) - HB ))
[ "$AGE" -le "$HEARTBEAT_MAX_AGE" ] || exit 0

DECISION_FILE="$(cc_decision_file "$KEY")"
# Bind the answer to THIS request instead of clearing the file up front: a
# startup rm could eat a decision the panel just wrote for a CONCURRENT gated
# call on the same session key (parallel subagents share the parent session_id).
# Staleness is judged by mtime in the poll loop below; CLAIM is a name owned by
# this PID so two waiters can never both consume the same answer (mv is atomic).
CLAIM="${DECISION_FILE}.claim.$$"

NOW="$(cc_now)"   # the request start (whole seconds)
# Per-request nonce: published in the pending block, echoed back by the panel in
# the decision content ("allow <nonce>"), and required to match before this
# waiter consumes an answer. mtime alone can't bind answers to requests: it has
# 1-second granularity, so a leftover written sub-second BEFORE this request
# (e.g. a double-clicked Approve whose first write was already consumed) would
# look "fresh" and silently answer a request that was never displayed.
NONCE="$$.$NOW"
# R1-36: write the per-request nonce ALSO at top level (gate_nonce) -- the parallel
# cc-status.sh PreToolUse hook can clear the pending block (and with it pending.nonce)
# in the SAME event via its own read-modify-write race. A top-level field cc-status.sh
# never touches survives that clear, so decisionContent can still bind a same-second
# answer. cc-approve clears gate_nonce when it tears the gate down (below).
# #14: the old pending block is dropped so the armed one is authoritative:
# cc_merge is a recursive jq merge, so a key the fresh patch doesn't carry
# survives -- a leftover AskUserQuestion `ask` array (published by cc-status.sh
# for this same session key) would ride into the armed pending and render dead
# option buttons on the approval tile (the same leak cc-status.sh's full-replace
# fixed for its own writes). The del + merge happen in ONE atomic jq pass
# (cc_merge's tmp+mv idiom, incl. its corrupt-file self-heal): a separate
# cc_del_field-then-cc_merge leaves a window where a sibling's PermissionRequest
# re-publishes an `ask` pending between the two writes and the merge leaks it
# all over again.
ARM_PATCH="$(jq -nc \
  --arg sid "$SESSION_ID" --arg name "$NAME" --arg cwd "$CWD" \
  --argjson now "$NOW" --arg tool "$TOOL" --arg sum "$SUMMARY" --arg nonce "$NONCE" \
  '{session_id:$sid, name:$name, cwd:$cwd, status:"approval", updated:$now, since:$now, gate:"waiting", gate_nonce:$nonce, pending:{tool:$tool, summary:$sum, message:$sum, nonce:$nonce}}')"
ARM_FILE="$(cc_file "$KEY")"
arm_gate() {
  local tmp cur
  tmp="${ARM_FILE}.tmp.$$"
  cur="$(cat "$ARM_FILE" 2>/dev/null)"
  [ -n "$cur" ] || cur='{}'
  if printf '%s' "$cur" | jq -c --argjson patch "$ARM_PATCH" 'del(.pending) * $patch' > "$tmp" 2>/dev/null \
     || jq -nc --argjson patch "$ARM_PATCH" '$patch' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ARM_FILE"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}
arm_gate
echo "[cc-approve] ⏳ waiting on panel for $TOOL ($KEY): $SUMMARY" >&2

# Poll for the panel's decision (0.25s cadence). Load-bearing invariants --
# full rationale + the pinning cases (same-second accept/reject, concurrency)
# live at the top of tests/gate.test.sh:
#   1. never rm up front -- a startup rm could eat a concurrent sibling's answer;
#   2. consume via the PID-owned CLAIM mv -- two waiters can't both take one answer;
#   3. accept only if OURS -- nonce match, or for legacy bare answers an mtime
#      STRICTLY newer (-gt) than this request's start second;
#   4. a not-ours answer is RESTORED via atomic hardlink (mtime-preserving;
#      EEXIST protects a fresh write) or PARKED on collision -- never rm'd,
#      and there is no rm on timeout.
ITERS=$(( GATE_TIMEOUT * 4 ))
DECISION=""
PARKED=0
i=0
while [ "$i" -lt "$ITERS" ]; do
  if [ -f "$DECISION_FILE" ] && mv "$DECISION_FILE" "$CLAIM" 2>/dev/null; then
    VERB=""; RNONCE=""
    read -r VERB RNONCE _ < "$CLAIM" 2>/dev/null || true
    OURS=0
    if [ -n "$RNONCE" ]; then
      [ "$RNONCE" = "$NONCE" ] && OURS=1
    else
      MTIME="$(stat -f %m "$CLAIM" 2>/dev/null || stat -c %Y "$CLAIM" 2>/dev/null)"
      case "$MTIME" in ''|*[!0-9]*) MTIME=0 ;; esac
      [ "$MTIME" -gt "$NOW" ] && OURS=1
    fi
    if [ "$OURS" = 1 ]; then
      DECISION="$VERB"
      rm -f "$CLAIM" 2>/dev/null || true
      break
    fi
    if ln "$CLAIM" "$DECISION_FILE" 2>/dev/null; then   # atomic no-clobber restore
      rm -f "$CLAIM" 2>/dev/null || true
    else
      # EEXIST: the panel wrote a FRESH decision while we held this one. The
      # held answer is a sibling's -- rm'ing it here silently destroyed a human
      # decision (that waiter then timed out to the native prompt with no
      # trace). Park it under a unique name instead: diagnosable on disk, never
      # consumed by mistake, swept by cc_remove's .claim.* glob on SessionEnd.
      # PARKED counts up so a second collision in a later iteration can't
      # overwrite the first parked answer.
      mv "$CLAIM" "${CLAIM}.parked.${PARKED}" 2>/dev/null || true
      echo "[cc-approve] ⚠️ unconsumed sibling decision collided with a fresh write — parked as ${CLAIM##*/}.parked.${PARKED} (that waiter falls back to the native prompt)" >&2
      PARKED=$(( PARKED + 1 ))
    fi
  fi
  # #28: verify/replay the arming (~1Hz). cc-status.sh's snapshot->jq->mv apply
  # still has a residual lost-update window (and a bounded-retry exhaustion path)
  # where its mv replaces the file with content computed from a PRE-ARM snapshot,
  # dropping gate, pending AND gate_nonce in one clobber -- the panel then never
  # shows this request and we poll blind to the full GATE_TIMEOUT. While still
  # waiting, an EMPTY gate_nonce means nobody owns the gate (our arming was
  # clobbered, or a resolved sibling tore the shared fields down while ours is
  # still pending) -> replay our arming patch verbatim (same since:T1, so the
  # stale-approval escalation clock isn't restarted -- R3-15). A FOREIGN nonce is
  # a live sibling arm (R3-18 semantics: last armer owns the tile): touch nothing.
  if [ $(( i % 4 )) -eq 0 ] && [ -z "$(cc_read_field "$KEY" '.gate_nonce')" ]; then
    arm_gate
    echo "[cc-approve] ♻️ re-armed gate for $TOOL ($KEY): arming was clobbered/torn down mid-wait" >&2
  fi
  sleep 0.25
  i=$(( i + 1 ))
done

# R3-18: ownership-aware gate teardown. Two concurrent gated requests on one session
# key (parallel subagents share session_id) both write gate:"waiting"+gate_nonce. If the
# FIRST waiter to resolve/time-out deletes the SHARED gate fields unconditionally, a
# status event during the second waiter's remaining poll can revert its approval tile and
# drop its pending block (cc-status.sh's R1-36 protection keys off .gate=="waiting"). Only
# delete when we're still the survivor: the empty check preserves teardown for the single-
# waiter case (and after a sibling already cleaned up), the NONCE match for the genuine owner.
CUR_GN="$(cc_read_field "$KEY" '.gate_nonce')"
if [ -z "$CUR_GN" ] || [ "$CUR_GN" = "$NONCE" ]; then
  cc_del_field "$KEY" "gate"
  cc_del_field "$KEY" "gate_nonce"   # R1-36: the gate is resolved; drop the survivor nonce
fi
# NOTE: no rm of $DECISION_FILE here -- on a timeout it could be a sibling's
# fresh answer. Stale leftovers are ignored (claimed + restored) by every
# waiter's mtime check above, and cc_remove cleans up on SessionEnd.
rm -f "$CLAIM" 2>/dev/null || true

# #12 (R3-18 completion): the same ownership rule for the pending/status cleanup
# the resolve/timeout branches below share -- the pending twin of the gate guard
# above. Clearing unconditionally let the FIRST waiter to resolve/time out wipe a
# sibling's freshly re-armed pending block and flip status back to "working"
# (parallel subagents share the session key), so the sibling's approval never
# reached the panel and it silently timed out to the native prompt. So: pending
# is OURS (nonce match) -> full teardown (the R1-37 behavior); pending already
# gone (single waiter resolved, or cc-status.sh's pending-clear race -- R1-36)
# -> just drop the dead approval status; any OTHER live pending -- a sibling's
# re-arm (foreign nonce) or a nonce-less NATIVE prompt cc-status.sh published
# once our gate teardown lifted the gate=="waiting" shield -- owns the tile now:
# touch nothing.
clear_own_pending() {
  local pn
  pn="$(cc_read_field "$KEY" '.pending.nonce')"
  if [ "$pn" = "$NONCE" ]; then
    cc_del_field "$KEY" "pending"
  elif [ "$(cc_read_field "$KEY" '.pending | type')" = "object" ]; then
    return 0
  fi
  cc_merge "$KEY" "$(jq -nc --argjson now "$(cc_now)" '{status:"working", updated:$now, since:$now}')"
}

if [ "$DECISION" = "deny" ]; then
  clear_own_pending
  echo "[cc-approve] ❌ denied $TOOL ($KEY)" >&2
  ledger_decision deny human
  emit_deny "Denied from the Claude Shepherd panel."
  exit 0
elif [ "$DECISION" = "allow" ]; then
  clear_own_pending
  # Remember this approval so approveRepeats can auto-allow it next time.
  if [ "$(cc_config '.policies.approveRepeats' 'false')" = "true" ]; then
    mkdir -p "$APPROVED_DIR"
    grep -Fxq "$SIG" "$APPROVED_DIR/$KEY" 2>/dev/null || printf '%s\n' "$SIG" >> "$APPROVED_DIR/$KEY"
  fi
  echo "[cc-approve] ✅ allowed $TOOL ($KEY)" >&2
  ledger_decision allow human
  emit_allow
  exit 0
fi

# Timed out with no answer: leave it to Claude Code's native prompt.
# R1-37: clear our OWN published request state so the tile doesn't keep showing a
# waiting-for-approval block with a now-dead nonce until the next hook event. This is
# the session's own pending block (not the shared decision file), so it doesn't touch
# the "never rm the decision file on timeout" invariant above. Ownership-checked:
# a sibling's re-armed pending must survive our timeout (see clear_own_pending).
clear_own_pending
echo "[cc-approve] ⚠️  timeout after ${GATE_TIMEOUT}s, falling back to native prompt ($KEY)" >&2
ledger_decision fallback timeout-fallback
exit 0
