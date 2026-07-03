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

# Read .gate.tools as a SPACE-separated string regardless of whether it was
# written as a string ("Bash Write") or hand-edited to a JSON array
# (["Bash","Write"]). jq -r on an array prints one element per line, which the
# space-delimited gated-tool test in cc-approve.sh would never match, silently
# disabling the gate (fail-open). Joining here keeps that security control closed.
# KEEP IN SYNC with core.parseToolList in cc-core.lua (accepts space/comma lists).
cc_config_toollist() {
  { [ -f "$CC_CONFIG_FILE" ] && cc_have_jq; } || return 0
  local out
  out="$(jq -r 'if (.gate.tools|type)=="array" then (.gate.tools|join(" "))
         elif (.gate.tools|type)=="string" then .gate.tools
         else empty end' "$CC_CONFIG_FILE" 2>/dev/null)"
  # R3-19: warn ONCE per process when gate.tools is PRESENT-but-empty (set to ""/[]).
  # An empty list can't distinguish "gate nothing on purpose" from "unset", so the
  # callers fall back to the default gated set -- a surprising silent override. The
  # supported "gate nothing" switches are the gate flag (cc-gate.enabled) and the
  # per-session None sentinel; say so loudly instead of failing silently.
  if [ -z "$out" ] && [ -z "${_CC_GATE_TOOLS_EMPTY_WARNED:-}" ] \
     && [ "$(jq -r 'if (.gate|has("tools")) then "y" else "n" end' "$CC_CONFIG_FILE" 2>/dev/null)" = "y" ]; then
    echo "[cc-lib] ⚠️  gate.tools is empty — falling back to the default gated set; to gate nothing fleet-wide disable the gate (cc-gate.enabled) or use the per-session None sentinel" >&2
    _CC_GATE_TOOLS_EMPTY_WARNED=1
  fi
  printf '%s' "$out"
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
  # CLAUDE_CODE_ENTRYPOINT=claude-vscode is authoritative and decided FIRST: the
  # VS Code/Cursor extension SETS it when spawning claude, so unlike KITTY_*/TERM
  # it can't be inherited from whatever shell cold-started the editor. Testing the
  # kitty env first meant a VS Code/Cursor launched from a kitty shell (`code .`)
  # handed EVERY session it hosts the launching kitty window's identity: keystrokes
  # routed to that kitty window and one forged per-window id was shared across all
  # editor windows (cross-window false prunes in core.staleDuplicateKeys). The
  # bundle id still disambiguates cursor-vs-vscode within the extension branch.
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    claude-vscode)
      case "${__CFBundleIdentifier:-}" in
        *todesktop*|*[Cc]ursor*) echo cursor; return ;;
      esac
      echo vscode; return ;;
  esac
  if [ -n "${KITTY_WINDOW_ID:-}" ] || [ "${TERM:-}" = "xterm-kitty" ]; then echo kitty; return; fi
  case "${__CFBundleIdentifier:-}" in
    *todesktop*|*[Cc]ursor*) echo cursor; return ;;
    *VSCode*|*VSCodium*)     echo vscode; return ;;
  esac
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    cli) echo terminal; return ;;
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

# The stable per-WINDOW host pid for a non-Kitty (VS Code/Cursor) session: walk our
# ancestry to the editor-integrated `claude` process (the one run with
# `--output-format stream-json`) and return ITS parent pid -- the editor window's host.
# A /clear spawns a fresh claude (new session_id) under the SAME host, so the old
# (ghost) tile and the new tile share it, while distinct editor windows have distinct
# hosts -- giving the panel a kitty-window-id equivalent to auto-prune /clear ghosts
# (see core.staleDuplicateKeys). Prints empty for Kitty (it has its own window id) or
# when no such ancestor is found within the bounded walk -- the safe side: the panel
# then never auto-prunes the tile and the 24h backstop owns its cleanup.
cc_window_host() {
  # Genuine kitty sessions have their own window id -- skip the walk. Decide by the
  # DETECTOR, not raw KITTY_WINDOW_ID: that env var is inherited by a VS Code/Cursor
  # cold-started from a kitty shell (`code .`), which would otherwise suppress
  # host_window capture for every session those windows host -- silently reverting
  # their /clear ghost cleanup to the 24h backstop (the regression 56622d1 fixed).
  [ "$(cc_detect_editor)" != "kitty" ] || { printf ''; return 0; }
  # Ancestry-walk depth cap. Observed shape is hook -> claude -> ext-host -> window-host
  # (~3-4 hops), so 8 is ~2x headroom; raising it just costs one `ps` per extra hop.
  local max_depth=8
  local pid="$PPID" cmd i=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt "$max_depth" ]; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    # Match the editor-integrated claude -- the VS Code/Cursor extension launches it with
    # `--output-format stream-json` -- LOOSELY, tolerant of reordered or injected flags,
    # so a future launch-flag change doesn't silently break the walk (which would revert
    # VS Code tiles to 24h-backstop-only ghost cleanup, with no error to signal it). Kept
    # as a LITERAL case pattern (not a $var) so the glob behaves identically in bash/zsh/sh.
    case "$cmd" in
      *claude*--output-format*stream-json*)
        ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  printf ''
}

# The per-window host id for a session, computed at most ONCE per session: reuse the
# value already in its status file, and only walk the process tree (cc_window_host)
# when it's absent. This keeps every hook event after a session's first off the `ps`
# path. Usage: cc_host_window "$key"  (empty when unknown / for Kitty).
cc_host_window() {
  local hw; hw="$(cc_read_field "$1" '.host_window')"
  [ -n "$hw" ] && { printf '%s' "$hw"; return 0; }
  cc_window_host
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

# Escape a string so it is safe to embed BETWEEN double quotes in a JSON literal.
# Used by the jq-absent fallback path (cc-status.sh) so a cwd/name containing a
# double-quote, backslash, control char, or newline still produces valid JSON.
# Order matters: backslash first, then quote, then control chars, then collapse
# any literal newlines to \n (awk, since the value may legally span lines).
cc_json_str() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
          -e 's/'"$(printf '\010')"'/\\b/g' \
          -e 's/'"$(printf '\014')"'/\\f/g' \
          -e 's/'"$(printf '\015')"'/\\r/g' \
          -e 's/'"$(printf '\011')"'/\\t/g' \
    | LC_ALL=C awk 'BEGIN{ORS=""; for(i=0;i<256;i++) _o[sprintf("%c",i)]=i}
        {if(NR>1)printf "\\n"; n=length($0);
         for(i=1;i<=n;i++){c=substr($0,i,1); v=_o[c];
           if(v<32) printf "\\u%04x", v; else printf "%s", c}}'
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
    # Self-heal a corrupt status file (hand-edit typo, partial rsync copy, truncated
    # write): invalid JSON on disk fails the merge above on EVERY subsequent hook
    # event -- no caller checks the return -- so the tile vanishes from the panel
    # and the session can never republish itself until SessionEnd. Retry from {}:
    # it succeeds iff the PATCH is valid (i.e. the failure was the file), rebuilding
    # the tile from this event's fields; a bad patch still returns 1, file untouched.
    if printf '{}' | jq -c --argjson patch "$2" '. * $patch' > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
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
# L2 per-session policy files: the resolved bundle the gate reads (cc-approve.sh)
# and the chosen-bundle override the panel writes. Hoisted here (defaults MUST match
# cc-approve.sh's CC_POLICY_DIR and the dashboard's POLICY_DIR/POLICY_OVERRIDE_DIR)
# so cc_remove reaps them on SessionEnd like the siblings above.
CC_POLICY_DIR="${CC_POLICY_DIR:-${HOME}/.claude/cc-policy}"
CC_POLICY_OVERRIDE_DIR="${CC_POLICY_OVERRIDE_DIR:-${HOME}/.claude/cc-policy-override}"
# DR6 per-session model auto-routing opt-in (presence = on). Hoisted here so cc_remove
# reaps it on SessionEnd like the siblings above (default MUST match the dashboard's
# AUTOMODEL_DIR). A new session gets a new key, so a stale opt-in can't silently carry over.
CC_AUTOMODEL_DIR="${CC_AUTOMODEL_DIR:-${HOME}/.claude/cc-automodel}"

# Remove a session entirely (used by SessionEnd) plus any stray decision/claim
# file and the per-session gated-tools override, approveRepeats memo, autopilot
# expiry, L2 policy files, and the model auto-routing opt-in (a new session gets a
# new key, so this just stops orphans accumulating).
cc_remove() {
  rm -f "$(cc_file "$1")" "$(cc_decision_file "$1")" "$(cc_decision_file "$1")".claim.* \
    "$CC_GATE_TOOLS_DIR/$1" "$CC_APPROVED_DIR/$1" "$CC_AUTOPILOT_DIR/$1" \
    "$CC_POLICY_DIR/$1" "$CC_POLICY_OVERRIDE_DIR/$1" "$CC_AUTOMODEL_DIR/$1" 2>/dev/null || true
}

# ---- Audit/event ledger ----------------------------------------------------
# Append-only JSONL record of fleet activity, one event per line, in a per-day
# (UTC) file under CC_LEDGER_DIR. OFF by default: nothing is written unless
# `ledger.enabled` is true in cc-config.json. Lines are KEPT well under PIPE_BUF
# (cc_ledger_append caps every string field), so concurrent O_APPEND writes from
# many sessions' hooks stay atomic.
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
  # {v,ts,id} first; caller fields merged on top (and win if they set any). Then
  # ENFORCE the small-line invariant the header comment relies on: an uncapped field
  # (the gate's full Bash command as a decision `summary`, a many-line prompt) makes
  # the line multi-KB, bash splits it across write()s, and concurrent appends
  # interleave mid-line and corrupt both records. Two-tier, measured in BYTES not
  # codepoints (jq `length`/`.[:n]` count codepoints -- 200 emoji = 800 bytes, so a
  # per-char cap does NOT bound bytes): (1) `capstr` via `walk` caps every string at
  # ANY depth to 200 bytes, trimming whole codepoints so no split UTF-8 byte reaches
  # the file; (2) `trimLineToBytes` shaves the globally-longest STRING LEAF until the
  # serialized line is <=480 bytes -- under the 512 POSIX PIPE_BUF floor regardless of
  # field count (tier 1 alone can't: N fields * 200 can still exceed it). trimLongest
  # targets the leaf `blen` actually measures (via paths/getpath) -- a top-level-only
  # trim would spin forever on a record whose over-budget bytes live in a nested field.
  line="$(printf '%s' "$1" | jq -c --argjson v 1 --argjson ts "$now" --arg id "$id" '
    def capstr($n): if type == "string" and (utf8bytelength) > $n
                    then (.[:$n] | until((utf8bytelength) <= $n; .[:-1])) else . end;
    def blen: tojson | utf8bytelength;
    def longestLeaf: . as $doc | reduce paths(strings) as $p ({p:null, n:-1};
      ($doc | getpath($p) | utf8bytelength) as $l | if $l > .n then {p:$p, n:$l} else . end) | .p;
    def trimLongest: longestLeaf as $p | if $p == null then . else setpath($p; getpath($p)[:-1]) end;
    def trimLineToBytes($max): until(blen <= $max
      or ([paths(strings) as $p | getpath($p) | select(length > 0)] | length) == 0; trimLongest);
    {v:$v, ts:$ts, id:$id} + .
    | walk(capstr(200))
    | trimLineToBytes(480)' 2>/dev/null)" || return 0
  [ -n "$line" ] && printf '%s\n' "$line" >> "$file" 2>/dev/null || true
}
