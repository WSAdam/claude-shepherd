#!/usr/bin/env bash
#
# cc-lib.sh - shared helpers for the babysitter status scripts.
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

# Babysitter's settings file. All orchestrator/policy behavior reads from here and
# defaults to OFF when the file or a key is missing.
CC_CONFIG_FILE="${CC_CONFIG_FILE:-${HOME}/.claude/cc-config.json}"

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

# Remove a session entirely (used by SessionEnd) plus any stray decision file.
cc_remove() {
  rm -f "$(cc_file "$1")" "$(cc_decision_file "$1")" 2>/dev/null || true
}
