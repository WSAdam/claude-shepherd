#!/usr/bin/env bash
#
# cc-lib.sh - shared helpers for the Claude Shepherd status scripts.
#
# Sourced by cc-status.sh (the per-event status writer) and cc-approve.sh
# (the opt-in PreToolUse approval gate). Holds the bits both need: where state
# lives, how a session is keyed, JSON field extraction, and atomic merge/delete
# of a session's status file.
#
# State layout (all under CC_DIR):
#   <key>.json       one file per session (key = sanitized session_id)
#   <key>.decision   panel writes "allow"/"deny" here to answer the gate
#   .panel-alive     panel heartbeat (epoch seconds); gate only blocks if fresh
#
# Everything here logs to stderr only — stdout is reserved for hook decisions.

CC_DIR="${CC_STATUS_DIR:-${HOME}/.claude/cc-status}"
mkdir -p "$CC_DIR" 2>/dev/null || true

# Do we have jq? The enriched/merge features require it; callers degrade if not.
cc_have_jq() { command -v jq >/dev/null 2>&1; }

# Claude Shepherd's settings file. All orchestrator/policy behavior reads from here and
# defaults to OFF when the file or a key is missing.
CC_CONFIG_FILE="${CC_CONFIG_FILE:-${HOME}/.claude/cc-config.json}"

# Fail-safe diagnostics: if the file EXISTS but doesn't parse (a hand-edit typo),
# every cc_config read below silently falls back to its default — which turns
# user-ENABLED features (audit ledger, autoDeny patterns) off. The defaults still
# win (fail-safe), but say so loudly, once per process, on stderr.
if [ -f "$CC_CONFIG_FILE" ] && cc_have_jq && ! jq -e . "$CC_CONFIG_FILE" >/dev/null 2>&1; then
  echo "[cc-lib] ⚠️  $CC_CONFIG_FILE is malformed — config reads fall back to defaults" >&2
fi

# Read a config value by jq path, falling back to a default. A literal `false`
# is returned as "false" (NOT treated as missing), so booleans work correctly.
# Usage: cc_config '.policies.approveRepeats' 'false'
cc_config() {
  local v=""
  if [ -f "$CC_CONFIG_FILE" ] && cc_have_jq; then
    v="$(jq -r "$1" "$CC_CONFIG_FILE" 2>/dev/null)"
  fi
  if [ -z "$v" ] || [ "$v" = "null" ]; then v="$2"; fi
  printf '%s' "$v"
}

# Print a config array's items, one per line (empty if missing).
# Usage: cc_config_array '.policies.patterns.autoDeny'
cc_config_array() {
  { [ -f "$CC_CONFIG_FILE" ] && cc_have_jq; } || return 0
  jq -r "${1}[]? // empty" "$CC_CONFIG_FILE" 2>/dev/null
}

cc_now() { date +%s; }

# Detect the host editor from the hook's environment. Shared by cc-status.sh
# (records it per session) and cc-popup.sh (routes the focus-on-finish pop to the
# right app). Returns: kitty | cursor | vscode | terminal.
cc_detect_editor() {
  if [ -n "${KITTY_WINDOW_ID:-}" ] || [ "${TERM:-}" = "xterm-kitty" ]; then echo kitty; return; fi
  case "${__CFBundleIdentifier:-}" in
    *todesktop*|*[Cc]ursor*) echo cursor; return ;;
    *VSCode*|*VSCodium*)     echo vscode; return ;;
  esac
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    claude-vscode) echo vscode; return ;;
    cli)           echo terminal; return ;;
  esac
  echo vscode  # safe default -> unchanged VS Code behavior
}

# macOS app name to `open -a` for an editor kind. Empty for kitty/terminal -- a
# terminal session has no separate editor window worth popping.
cc_editor_app() {
  case "$1" in
    cursor) printf 'Cursor' ;;
    vscode) printf 'Visual Studio Code' ;;
    *)      printf '' ;;
  esac
}

# Append a line to the debug log when CC_STATUS_DEBUG is set. Used to capture
# raw hook stdin once during install so real payload field names can be locked.
cc_debug() {
  [ -n "${CC_STATUS_DEBUG:-}" ] || return 0
  printf '%s %s\n' "$(cc_now)" "$*" >> "$CC_DIR/.debug.log" 2>/dev/null || true
}

# Read a value from a JSON string by jq path; empty string if missing/no jq.
# Usage: cc_get "$json" '.session_id'
cc_get() {
  cc_have_jq || { printf ''; return 0; }
  printf '%s' "$1" | jq -r "${2} // empty" 2>/dev/null || printf ''
}

# Turn a session id (or any string) into a filesystem-safe key.
cc_sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Resolve the storage key for a session. Prefer the real session_id; fall back
# to the cwd basename so the scripts still work when run by hand for testing.
# Usage: cc_key "$session_id" "$cwd"
cc_key() {
  local raw="$1"
  [ -n "$raw" ] || raw="$(basename "${2:-$PWD}")"
  cc_sanitize "$raw"
}

cc_file() { printf '%s/%s.json' "$CC_DIR" "$1"; }
cc_decision_file() { printf '%s/%s.decision' "$CC_DIR" "$1"; }
cc_heartbeat_file() { printf '%s/.panel-alive' "$CC_DIR"; }

# Read the current status string for a key ("" if the file is absent/empty).
cc_current_status() {
  local f; f="$(cc_file "$1")"
  [ -f "$f" ] || { printf ''; return 0; }
  cc_get "$(cat "$f" 2>/dev/null)" '.status'
}

# Read an arbitrary field from a key's status file.
cc_read_field() {
  local f; f="$(cc_file "$1")"
  [ -f "$f" ] || { printf ''; return 0; }
  cc_get "$(cat "$f" 2>/dev/null)" "$2"
}

# Deep-merge a JSON patch object into a session's file, written atomically so
# the dashboard never reads a half-written file. Usage: cc_merge "$key" "$patch"
cc_merge() {
  cc_have_jq || return 0
  local f tmp cur
  f="$(cc_file "$1")"
  tmp="${f}.tmp.$$"
  cur="$(cat "$f" 2>/dev/null)"
  [ -n "$cur" ] || cur='{}'
  if printf '%s' "$cur" | jq -c --argjson patch "$2" '. * $patch' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Delete a top-level field from a session's file (atomic). No-op if absent.
cc_del_field() {
  cc_have_jq || return 0
  local f tmp
  f="$(cc_file "$1")"
  [ -f "$f" ] || return 0
  tmp="${f}.tmp.$$"
  if jq -c "del(.${2})" "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Per-session gated-tools override dir (Feature D), mirroring cc-autopilot. Defined
# here so SessionEnd can clean it up; cc-approve.sh reads the same path on its hot path.
CC_GATE_TOOLS_DIR="${CC_GATE_TOOLS_DIR:-${HOME}/.claude/cc-gate-tools}"
# Same deal for the per-key approveRepeats memo + autopilot expiry files written by
# cc-approve.sh/the panel: hoisted here so cc_remove can stop those orphans too.
CC_APPROVED_DIR="${CC_APPROVED_DIR:-${HOME}/.claude/cc-approved}"
CC_AUTOPILOT_DIR="${CC_AUTOPILOT_DIR:-${HOME}/.claude/cc-autopilot}"

# Remove a session entirely (used by SessionEnd) plus any stray decision/claim
# file and the per-session gated-tools override, approveRepeats memo, and
# autopilot expiry (a new session gets a new key, so this just stops orphans
# accumulating).
cc_remove() {
  rm -f "$(cc_file "$1")" "$(cc_decision_file "$1")" "$(cc_decision_file "$1")".claim.* \
    "$CC_GATE_TOOLS_DIR/$1" "$CC_APPROVED_DIR/$1" "$CC_AUTOPILOT_DIR/$1" 2>/dev/null || true
}

# ---- Audit/event ledger ----------------------------------------------------
# Append-only JSONL record of fleet activity, one event per line, in a per-day
# (UTC) file under CC_LEDGER_DIR. OFF by default: nothing is written unless
# `ledger.enabled` is true in cc-config.json. Lines are well under PIPE_BUF, so
# concurrent O_APPEND writes from many sessions' hooks stay atomic.
CC_LEDGER_DIR="${CC_LEDGER_DIR:-${HOME}/.claude/cc-ledger}"

cc_ledger_enabled() { [ "$(cc_config '.ledger.enabled' 'false')" = "true" ]; }

# Append one event. $1 = a jq-built JSON object of the event's fields (must carry
# at least `type`; callers add session_id/name/cwd/key + type-specific fields).
# v/ts/id are stamped here so callers stay simple. No-op unless enabled + jq, and
# unless the event's type is in `ledger.captureTypes` (empty = capture everything).
cc_ledger_append() {
  cc_ledger_enabled || return 0
  cc_have_jq || return 0
  # Optional type allow-list: only filter when captureTypes is non-empty.
  local types t
  types="$(cc_config_array '.ledger.captureTypes')"
  if [ -n "$types" ]; then
    t="$(printf '%s' "$1" | jq -r '.type // empty' 2>/dev/null)"
    [ -n "$t" ] && ! printf '%s\n' "$types" | grep -Fxq "$t" && return 0
  fi
  mkdir -p "$CC_LEDGER_DIR" 2>/dev/null || true
  local now id day file line
  now="$(cc_now)"
  id="${now}-$$-${RANDOM}"
  day="$(date -u +%Y-%m-%d)"
  file="$CC_LEDGER_DIR/${day}.jsonl"
  # {v,ts,id} first; caller fields merged on top (and win if they set any).
  line="$(printf '%s' "$1" | jq -c --argjson v 1 --argjson ts "$now" --arg id "$id" \
    '{v:$v, ts:$ts, id:$id} + .' 2>/dev/null)" || return 0
  [ -n "$line" ] && printf '%s\n' "$line" >> "$file" 2>/dev/null || true
}
