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
#   <key>.decision.note   the reason typed beside Deny, {"nonce","note"} (written first)
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
# A /clear mints a new session_id in the SAME claude process under the SAME host, so
# the old (ghost) tile and the new tile share it, while distinct editor windows have
# distinct hosts. Every Claude tab in one window shares the host too, which is why
# core.staleDuplicateKeys pairs tiles on host + session_pid, not the host alone (tabs
# are separate processes). Prints empty for Kitty (it has its own window id) or
# when no such ancestor is found within the bounded walk -- the safe side: the panel
# then never auto-prunes the tile and the 24h backstop owns its cleanup.
# The claude session process's OWN pid, and its parent (the per-window host id), from
# ONE walk: "<session_pid> <host_pid>", or empty when unknown / under kitty. The
# session pid is what tells a /clear ghost from a live sibling -- /clear keeps the
# SAME process and mints a new session id, so the retired session and its replacement
# are the only two tiles that can ever share one pid (a second chat is its own
# process). Callers below keep their single-value contracts.
cc_window_pair() {
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
        printf '%s %s' "$pid" "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  printf ''
}

# The per-window host id (the walk's second field). Contract unchanged: one value,
# empty when unknown / under kitty, always exit 0.
cc_window_host() {
  local pair; pair="$(cc_window_pair)"
  [ -n "$pair" ] || { printf ''; return 0; }
  printf '%s' "${pair#* }"
}

# The per-window host id for a session, computed at most ONCE per session: reuse the
# value already in its status file, and only walk the process tree (cc_window_host)
# when it's absent. This keeps every hook event after a session's first off the `ps`
# path. Usage: cc_host_window "$key"  (empty when unknown / for Kitty).
# The session's own process pid, computed at most ONCE per session: reuse the value
# already in its status file, and only walk the tree when it's absent -- same posture
# as cc_host_window. Usage: cc_session_pid "$key"  (empty when unknown / for Kitty).
cc_session_pid() {
  local sp; sp="$(cc_read_field "$1" '.session_pid')"
  [ -n "$sp" ] && { printf '%s' "$sp"; return 0; }
  local pair; pair="$(cc_window_pair)"
  [ -n "$pair" ] || { printf ''; return 0; }
  printf '%s' "${pair%% *}"
}

cc_host_window() {
  local hw; hw="$(cc_read_field "$1" '.host_window')"
  [ -n "$hw" ] && { printf '%s' "$hw"; return 0; }
  cc_window_host
}

# Append a line to the debug log when tracing is on -- either the CC_STATUS_DEBUG env
# var, or a `.debug-hooks` flag FILE in CC_DIR. The file trigger works for hooks spawned
# by a GUI editor session (VS Code/Cursor) whose environment we can't set, so raw hook
# payloads (event + full stdin) can be captured to lock down real field names / event
# ordering without guessing. Off unless explicitly enabled.
cc_debug() {
  [ -n "${CC_STATUS_DEBUG:-}" ] || [ -f "$CC_DIR/.debug-hooks" ] || return 0
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
# Ready-to-merge requests (cc-merge.sh) and Shepherd's answers to them, per session key.
# Default MUST match cc-merge.sh's and the dashboard's FX.MERGE_DIR.
CC_MERGE_DIR="${CC_MERGE_DIR:-${HOME}/.claude/cc-merge}"
# Adam's answers to a held AskUserQuestion (cc-ask.sh), per session key. Default MUST match
# the dashboard's FX.ASK_DIR.
CC_ASK_DIR="${CC_ASK_DIR:-${HOME}/.claude/cc-ask}"
# Talk mode's per-session flag (build program unit 6, 2026-09-28): presence = on, written by the
# panel's toggle, read by cc-approve.sh. Default MUST match the dashboard's FX.TALK_DIR.
CC_TALK_DIR="${CC_TALK_DIR:-${HOME}/.claude/cc-talk}"
# The session mailbox (build program unit 11a, 2026-09-29): a folder per session of the messages
# Shepherd left it (FX.mailboxSend). Default MUST match the dashboard's FX.INBOX_DIR.
CC_INBOX_DIR="${CC_INBOX_DIR:-${HOME}/.claude/cc-inbox}"
# The decisions inbox (build program unit 28, 2026-09-29): cc-decide.sh's questions,
# <key>.<epoch>-<pid>.json, and Adam's answers, <id>.answer. Default MUST match cc-decide.sh's
# (it sources this file) and the dashboard's FX.DECIDE_DIR.
CC_DECIDE_DIR="${CC_DECIDE_DIR:-${HOME}/.claude/cc-decide}"
# Resume at the usage limit's reset (build program unit 13, 2026-09-29): cc-resume.sh's arm
# (<key>.json), Shepherd's plan (<key>.plan.json) and the card's Cancel (<key>.cancel), per
# session key. A clean Stop clears them (cc-status.sh). Default MUST match the dashboard's FX.RESUME_DIR.
CC_RESUME_DIR="${CC_RESUME_DIR:-${HOME}/.claude/cc-resume}"
# Batch driving (cc-fleet.sh): every file of a batch is named <id>.<...> in this one folder.
# Default MUST match cc-fleet.sh's FLEET_DIR and the dashboard's FX.FLEET_DIR.
CC_FLEET_DIR="${CC_FLEET_DIR:-${HOME}/.claude/cc-fleet}"

# Pinned links (build program unit 31, 2026-09-29): cc-pin.sh keeps a worktree's links in
# CC_PINS_DIR/<encoded git root>.json. They belong to the WORKTREE, not a session key -- they
# outlive /clear and a respawn -- so the removers can't drop them by key. Instead both drop the
# pins of every worktree that is gone (its folder removed), their torn writes, and any pins file
# that names no worktree. KEEP IN SYNC with FX.prunePins. Default MUST match FX.PINS_DIR.
CC_PINS_DIR="${CC_PINS_DIR:-${HOME}/.claude/cc-pins}"
cc_pins_prune() {
  cc_have_jq || return 0
  local f root
  for f in "$CC_PINS_DIR"/*.json; do
    [ -f "$f" ] || continue
    root="$(jq -r 'if (.root | type) == "string" then .root else empty end' "$f" 2>/dev/null)"
    case "$root" in /*) [ -d "$root" ] && continue ;; esac
    rm -f "$f" "$f".tmp.* 2>/dev/null
    cc_debug "cc_pins_prune: dropped $f (its worktree ${root:-?} is gone)"
  done
  return 0
}

# Worktree leases (build program unit 27, 2026-09-29): Shepherd leases each worktree it starts a
# session for its own PORT and DB path, in CC_LEASE_DIR/<encoded main checkout>.json. Shepherd is
# the ONLY writer -- its sweep frees a gone worktree's lease and deletes the database file it named
# -- so the removers here drop only what nothing can use: a file that names no main checkout (or
# isn't named for its own) and a torn write a minute old (Shepherd renames at once).
# KEEP IN SYNC with FX.pruneLeaseFiles. Default MUST match FX.LEASE_DIR.
CC_LEASE_DIR="${CC_LEASE_DIR:-${HOME}/.claude/cc-lease}"
cc_lease_prune() {
  [ -d "$CC_LEASE_DIR" ] || return 0
  cc_have_jq || return 0
  local f main
  for f in "$CC_LEASE_DIR"/*.json; do
    [ -f "$f" ] || continue
    main="$(jq -r 'if (.main | type) == "string" then .main else empty end' "$f" 2>/dev/null)"
    case "$main" in
      /*) [ "${f##*/}" = "$(printf '%s' "${main%/}" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g').json" ] && continue ;;
    esac
    rm -f "$f" 2>/dev/null
    cc_debug "cc_lease_prune: dropped $f (it names no main checkout of its own)"
  done
  find "$CC_LEASE_DIR" -maxdepth 1 -name '*.json.tmp.*' -mmin +1 -exec rm -f {} + 2>/dev/null
  return 0
}

# A decisions-inbox file's name -> "<key> <id> <kind>" on stdout (kind: json | answer | part, a part
# being a torn write or a claim); 1 for anything else. The id is <key>.<epoch>-<pid>, the key
# everything before its last dot, so "k9.1.<id>" belongs to the key k9.1, never to k9.
# KEEP IN SYNC with core.decisionFileOf.
_cc_decide_name() { # $1 file name
  local n="$1" stem kind tail="x" id key
  case "$n" in
    *.json)          stem="${n%.json}"; kind=json ;;
    *.answer)        stem="${n%.answer}"; kind=answer ;;
    *.json.tmp.*)    stem="${n%.json.tmp.*}"; tail="${n##*.json.tmp.}"; kind=part ;;
    *.answer.tmp.*)  stem="${n%.answer.tmp.*}"; tail="${n##*.answer.tmp.}"; kind=part ;;
    *.answer.claim.*) stem="${n%.answer.claim.*}"; tail="${n##*.answer.claim.}"; kind=part ;;
    *) return 1 ;;
  esac
  case "$tail" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  id="${stem##*.}"; key="${stem%.*}"
  [ "$key" != "$stem" ] && [ -n "$key" ] || return 1
  case "$id" in *[!0-9-]*|-*|*-|*-*-*) return 1 ;; *-*) ;; *) return 1 ;; esac
  printf '%s %s %s' "$key" "$key.$id" "$kind"
}

# SessionEnd's share of the decisions inbox: the session's OPEN questions go, with their torn writes
# and claims. An ANSWERED one stays -- the session's next start (a resume) takes it -- until the
# prune below. KEEP IN SYNC with FX.decideRemove.
cc_decide_remove() { # $1 key
  local key="$1" f parsed k id kind
  case "$key" in ''|.|..|*/*) return 0 ;; esac
  [ -d "$CC_DECIDE_DIR" ] || return 0
  for f in "$CC_DECIDE_DIR/$key".*; do
    [ -e "$f" ] || continue
    parsed="$(_cc_decide_name "${f##*/}")" || continue
    read -r k id kind <<EOF
$parsed
EOF
    [ "$k" = "$key" ] || continue   # another session's (k9.1's files start "k9." too)
    case "$kind" in
      json) [ -f "$CC_DECIDE_DIR/$id.answer" ] || rm -f "$f" 2>/dev/null ;;
      part) rm -f "$f" 2>/dev/null ;;
    esac
  done
  return 0
}

# Every session's: a question or answer over a week old, an answer whose question is gone, and a
# torn write or claim a minute old (every writer renames at once). KEEP IN SYNC with FX.decidePrune.
cc_decide_prune() {
  [ -d "$CC_DECIDE_DIR" ] || return 0
  local f
  find "$CC_DECIDE_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.answer' \) -mtime +7 -exec rm -f {} + 2>/dev/null
  find "$CC_DECIDE_DIR" -maxdepth 1 -type f \( -name '*.tmp.*' -o -name '*.claim.*' \) -mmin +1 -exec rm -f {} + 2>/dev/null
  for f in "$CC_DECIDE_DIR"/*.answer; do
    [ -f "$f" ] || continue
    [ -f "${f%.answer}.json" ] || rm -f "$f" 2>/dev/null
  done
  return 0
}

# Remove a session entirely (used by SessionEnd) plus any stray decision/claim
# file and the per-session gated-tools override, approveRepeats memo, autopilot
# expiry, L2 policy files, and the model auto-routing opt-in (a new session gets a
# new key, so this just stops orphans accumulating).
# The *.parked.* and *.tmp.* globs are the leftovers of an interrupted handover
# (2026-09-19): cc-merge.sh parks an answer that isn't its own as
# <key>.decision.parked.<pid>, and every writer here goes temp-then-rename, so a
# crash in between leaves <key>.json.tmp.<pid> and friends. Both used to outlive
# the session that owned them -- keys are UUIDs, so nothing matched them again.
# <key>.checker.json (2026-09-29) is the merge checker's verdict, which only Shepherd writes.
# cc-resume/<key>.json, .plan.json and .cancel (2026-09-29): a resume waiting for a usage limit's
# reset -- its waiter sees the arm gone and stops.
# cc-pins/ (2026-09-29) is keyed by worktree, not session: cc_pins_prune drops only a gone worktree's.
# cc-lease/ (2026-09-29) is keyed by main checkout: cc_lease_prune drops only what nothing can use.
# cc-decide/ (2026-09-29): the session's open questions go; an answered one waits for its next start.
# KEEP THE FILE SET IN SYNC with FX.removeStatus in claude-dashboard.lua.
cc_remove() {
  rm -f "$(cc_file "$1")" "$(cc_file "$1")".tmp.* "$(cc_decision_file "$1")" \
    "$(cc_decision_file "$1")".claim.* \
    "$(cc_decision_file "$1")".note "$(cc_decision_file "$1")".note.tmp.* \
    "$CC_GATE_TOOLS_DIR/$1" "$CC_APPROVED_DIR/$1" "$CC_AUTOPILOT_DIR/$1" \
    "$CC_POLICY_DIR/$1" "$CC_POLICY_OVERRIDE_DIR/$1" "$CC_AUTOMODEL_DIR/$1" \
    "$CC_MERGE_DIR/$1.json" "$CC_MERGE_DIR/$1.decision" "$CC_MERGE_DIR/$1.decision".claim.* \
    "$CC_MERGE_DIR/$1.decision".parked.* "$CC_MERGE_DIR/$1.decision".tmp.* \
    "$CC_MERGE_DIR/$1.checker.json" "$CC_MERGE_DIR/$1.checker.json".tmp.* \
    "$CC_ASK_DIR/$1.answer" "$CC_ASK_DIR/$1.answer".claim.* \
    "$CC_ASK_DIR/$1.answer".tmp.* "$CC_TALK_DIR/$1" \
    "$CC_RESUME_DIR/$1.json" "$CC_RESUME_DIR/$1.json".tmp.* "$CC_RESUME_DIR/$1.plan.json" \
    "$CC_RESUME_DIR/$1.plan.json".tmp.* "$CC_RESUME_DIR/$1.cancel" \
    "$CC_NOTES_DIR/$1.due-at" "$CC_NOTES_DIR/$1.due-at".tmp.* "$CC_NOTES_DIR/$1.notes-asked" 2>/dev/null || true
  # The mailbox is a folder (cc-inbox/<key>/): its messages, claims and temps, then the folder.
  # A key that could name anything outside it (nothing, . or ..) never gets that far.
  local inbox="$CC_INBOX_DIR/$1"
  case "$1" in ''|.|..|*/*) ;; *)
    rm -f "$inbox"/* "$inbox"/.[!.]* 2>/dev/null
    rmdir "$inbox" 2>/dev/null ;;
  esac
  # Pinned links are per worktree, not per key: only those of a worktree that's gone (2026-09-29).
  cc_pins_prune
  # Worktree leases are per main checkout: only the files nothing can use (2026-09-29).
  cc_lease_prune
  # The decisions inbox: the session's open questions, then every session's stale files (2026-09-29).
  cc_decide_remove "$1"
  cc_decide_prune
  return 0
}

# Remove every file of one batch (2026-09-29): the proposal, Shepherd's state, the stop marker,
# decisions, tab requests and answers, the relayed events (<id>.events.jsonl) and their temps --
# everything named "<id>.<...>", never another batch's ("b1." is not a prefix of "b12.json").
# An id that isn't b + letters/digits (cc-fleet.sh's own ids) removes nothing.
# KEEP THE FILE SET IN SYNC with FX.removeBatch (core.batchFiles) in claude-dashboard.lua.
cc_fleet_remove_batch() {
  case "$1" in b[A-Za-z0-9]*) ;; *) return 0 ;; esac
  case "$1" in *[!A-Za-z0-9]*) return 0 ;; esac
  rm -f "$CC_FLEET_DIR/$1".* 2>/dev/null
  return 0
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

# ---- Always-ask commands (build program unit 5, 2026-09-28) ---------------------------------
# A fixed list of Bash commands is held for Adam's click whatever the gate flag, gate.tools,
# autopilot, autoAllow, approveRepeats or a policy bundle says (cc-approve.sh's pre-gate
# layer): git push; rm with both -r and -f; git reset --hard, clean -f, branch -D,
# worktree remove --force, checkout -- .; any tool's publish; gh release create; gh pr merge.
# The matcher judges PARSED words, never the raw text: `echo "git push"` and a commit message
# that mentions rm -rf are left alone, while `cd x && git push`, `git -C dir push`,
# `sh -c "..."`, the sudo/env/time/nohup/command/exec/xargs/find -exec/trap wrappers and
# `rm -r -f` are held. A held word behind eval, $VAR, $(...) or a heredoc that never ends is
# held as "hidden command". KEEP THE RULE LABELS IN SYNC with core.ALWAYS_ASK_BUILTINS
# (Settings lists them; tests/gate.test.sh runs each example through here).
# Runs under macOS /bin/bash 3.2 with set -u: every array expansion is guarded.
CC_AA_WORDS='push|rm|reset|clean|branch|worktree|checkout|publish|release|merge'
CC_AA_RULE=""
_CC_AA_US=$'\037'    # between a command's words
_CC_AA_DYN=$'\035'   # leads a word built from an expansion ($VAR, $(...), `...`)
_CC_AA_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*\+?='
_CC_SC_PLAIN=$'^[^\\\\\'"$`[:space:];&|<>()#]+'   # a run of characters with no shell meaning
_CC_SC_DQPLAIN=$'^[^"\\\\$`]+'                     # ...inside double quotes
_CC_SC_CMD=(); _CC_SC_IN=(); _CC_SC_BAD=""; _CC_SC_END=0; _CC_AA_W=(); _CC_AA_EXTRAS=()
_CC_SC_OUT=""   # output redirections that write a file (talk mode reads it), one per line
_CC_SC_OUTAT=() # ...and for each, the index in _CC_SC_CMD of the command it belongs to (the fence)
_CC_AA_KWRE=""; _CC_AA_ASSIGNS=""

# The pure-bash first look (this hook runs for every tool call): 0 when the always-ask layer
# must read the request. Only a Bash call qualifies, and only when its JSON carries a held
# word or a config / session policy file may name extra patterns. $1 = the hook's JSON.
cc_always_ask_candidate() {
  local re='"tool_name"[[:space:]]*:[[:space:]]*"Bash"' sid
  [[ $1 =~ $re ]] || return 1
  re="(^|[^[:alnum:]_]|\\\\[nrt])($CC_AA_WORDS)([^[:alnum:]_]|\$)"   # \n \t: JSON escapes
  [[ $1 =~ $re ]] && return 0
  cc_always_ask_names_extras "$CC_CONFIG_FILE" && return 0
  re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $1 =~ $re ]] && [ -n "${BASH_REMATCH[1]}" ]; then
    sid="${BASH_REMATCH[1]}"
    cc_always_ask_names_extras "$CC_POLICY_DIR/${sid//[^A-Za-z0-9._-]/_}" && return 0
  fi
  return 1
}

# 0 when file $1 may carry a non-empty always-ask list (policies.alwaysAsk.patterns, a
# bundle's alwaysAsk). Settings writes an empty {"patterns": []}; any other shape counts.
cc_always_ask_names_extras() {
  local txt="" re
  [ -f "$1" ] || return 1
  IFS= read -r -d '' txt < "$1" 2>/dev/null
  case "$txt" in *'"alwaysAsk"'*) ;; *) return 1 ;; esac
  re='"alwaysAsk"[[:space:]]*:[[:space:]]*(\{[[:space:]]*("patterns"[[:space:]]*:[[:space:]]*(\[[[:space:]]*\]|\{[[:space:]]*\})[[:space:]]*)?\}|\[[[:space:]]*\])'
  while [[ $txt =~ $re ]]; do txt="${txt/"${BASH_REMATCH[0]}"/}"; done
  case "$txt" in *'"alwaysAsk"'*) return 0 ;; esac
  return 1
}

# Is this Bash command held? $1 = the command, $2 = extra patterns, one per line: a command
# name, then words it must contain in that order (`terraform apply`, `kubectl delete`;
# * and ? work inside a word). 0 + CC_AA_RULE (the rule's label) when held.
cc_always_ask_match() {
  CC_AA_RULE=""
  local cmd="$1" extras="${2:-}" x w lit words="$CC_AA_WORDS" loose="" all=0
  local -a parts=()
  _CC_AA_EXTRAS=()
  if [ -n "$extras" ]; then
    while IFS= read -r x; do
      x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
      [ -n "$x" ] || continue
      _CC_AA_EXTRAS+=("$x")
      read -r -a parts <<< "$x"
      lit=0
      for w in ${parts[@]+"${parts[@]}"}; do
        case "$w" in
          *[\*\?\[]*) w="${w//[^A-Za-z0-9_.-]/}"; [ -n "$w" ] && { loose="$loose|${w//./\\.}"; lit=1; } ;;
          *) w="${w//[^A-Za-z0-9_.-]/}"; [ -n "$w" ] && { words="$words|${w//./\\.}"; lit=1; } ;;
        esac
      done
      [ "$lit" = 1 ] || all=1
    done <<< "$extras"
  fi
  # Held words: a text that carries none of them can't hold anything (the cheap exit), and
  # a hidden command is held only when one shows in its own words or an assignment.
  _CC_AA_KWRE="(^|[^[:alnum:]_])($words)([^[:alnum:]_]|\$)$loose"
  [ "$all" = 1 ] && _CC_AA_KWRE='.'
  [[ $cmd =~ $_CC_AA_KWRE ]] || return 1
  _CC_AA_ASSIGNS=""
  _cc_aa_text "$cmd" 0
}

# Split shell text into simple commands. $1 text, $2 mode, $3 start index. Appends each
# command to _CC_SC_CMD (words joined by US; a word built from an expansion is led by DYN and
# keeps the expansion's source text) and its heredoc / here-string to _CC_SC_IN. mode "sub"
# is the inside of a $( and stops at its closing ")", leaving the next index in _CC_SC_END.
# The inside of a $(...) or `...` runs too, so its commands are appended as it is met. A
# heredoc that never ends leaves its text in _CC_SC_BAD. An output redirection whose target
# is a file (not /dev/null, a tty or a descriptor copy) adds that target to _CC_SC_OUT.
_cc_sh_scan() {
  local LC_ALL=C
  local s="$1" mode="$2" i="$3" n=${#1}
  local c c2 j rest line word="" inw=0 wdyn=0 wq=0 redir=0 rout="" hd=0 hdstrip=0 hs=0 depth=0
  local cur="" ncur=0 herestr=""
  local -a hdd=() hds=() hdc=()
  while [ "$i" -lt "$n" ]; do
    if [[ ${s:i} =~ $_CC_SC_PLAIN ]]; then
      word="$word${BASH_REMATCH[0]}"; inw=1; i=$((i + ${#BASH_REMATCH[0]})); continue
    fi
    c="${s:i:1}"
    case "$c" in
      ' '|$'\t') _cc_sc_word; i=$((i + 1)) ;;
      $'\n') _cc_sc_cmd; i=$((i + 1)); [ ${#hdd[@]} -eq 0 ] || _cc_sc_heredocs ;;
      \\) c2="${s:i+1:1}"
          if [ "$c2" = $'\n' ]; then i=$((i + 2))
          else word="$word$c2"; inw=1; wq=1; i=$((i + 2)); fi ;;
      \') rest="${s:i+1}"; j="${rest%%\'*}"
          word="$word$j"; inw=1; wq=1; i=$((i + 2 + ${#j})) ;;
      \") _cc_sc_dquote ;;
      \$) _cc_sc_dollar ;;
      \`) _cc_sc_backtick ;;
      \#) if [ "$inw" = 1 ]; then word="$word#"; i=$((i + 1))
          else rest="${s:i}"; line="${rest%%$'\n'*}"; i=$((i + ${#line})); fi ;;
      '&') if [ "${s:i+1:1}" = '>' ]; then           # &> and &>> redirect, not a separator
             _cc_sc_word; redir=1; rout=file; i=$((i + 2)); [ "${s:i:1}" = '>' ] && i=$((i + 1))
           else _cc_sc_cmd; i=$((i + 1)); fi ;;
      ';'|'|') _cc_sc_cmd; i=$((i + 1)) ;;
      '<'|'>') _cc_sc_redirect ;;
      '(') _cc_sc_cmd; depth=$((depth + 1)); i=$((i + 1)) ;;
      ')') _cc_sc_cmd; i=$((i + 1))
           if [ "$depth" -gt 0 ]; then depth=$((depth - 1))
           elif [ "$mode" = sub ]; then _CC_SC_END=$i; return 0; fi ;;
      *) word="$word$c"; inw=1; i=$((i + 1)) ;;
    esac
  done
  _cc_sc_cmd
  [ ${#hdd[@]} -eq 0 ] || _cc_sc_heredocs
  _CC_SC_END=$n
}

# The scanner's helpers work on _cc_sh_scan's locals (bash scoping is dynamic).
_cc_sc_word() {   # end the word being built
  [ "$inw" = 1 ] || return 0
  if [ "$redir" = 1 ]; then redir=0                  # a redirection's target, not an argument
    [ -z "$rout" ] || _cc_sc_out
  elif [ "$hd" = 1 ]; then hdd+=("$word"); hds+=("$hdstrip"); hdc+=(-1); hd=0
  elif [ "$hs" = 1 ]; then herestr="$herestr$word"; hs=0
  else
    [ "$wdyn" = 1 ] && word="$_CC_AA_DYN$word"
    if [ "$ncur" = 0 ]; then cur="$word"; else cur="$cur$_CC_AA_US$word"; fi
    ncur=$((ncur + 1))
  fi
  word=""; inw=0; wdyn=0; wq=0
}

_cc_sc_cmd() {    # end the simple command
  local k idx
  _cc_sc_word
  # an output redirection with no target word: >(...) runs a command on what's written
  if [ "$redir" = 1 ] && [ -n "$rout" ]; then _CC_SC_OUT="$_CC_SC_OUT>("$'\n'; _CC_SC_OUTAT+=(${#_CC_SC_CMD[@]}); fi
  if [ "$ncur" -gt 0 ]; then
    _CC_SC_CMD+=("$cur"); _CC_SC_IN+=("$herestr")
    idx=$(( ${#_CC_SC_CMD[@]} - 1 ))
    for k in ${hdc[@]+"${!hdc[@]}"}; do [ "${hdc[k]}" = -1 ] && hdc[k]=$idx; done
  fi
  cur=""; ncur=0; herestr=""; redir=0; rout=""; hd=0; hs=0
}

_cc_sc_out() {    # the target of an output redirection: record it unless it writes no file
  local kind="$rout"
  rout=""
  if [ "$wdyn" = 0 ]; then
    case "$word" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty) return 0 ;; esac
    [ "$kind" = dup ] && [[ $word =~ ^([0-9]+-?|-)$ ]] && return 0   # >&2, >&-: a descriptor
  fi
  _CC_SC_OUT="$_CC_SC_OUT$word"$'\n'
  _CC_SC_OUTAT+=(${#_CC_SC_CMD[@]})   # the command it belongs to is appended next
}

_cc_sc_heredocs() {   # at the start of a line: read the bodies of the heredocs opened above it
  local k rest line cmp body found tab=$'\t'
  for k in ${hdd[@]+"${!hdd[@]}"}; do
    body=""; found=0
    while [ "$i" -lt "$n" ]; do
      rest="${s:i}"; line="${rest%%$'\n'*}"
      i=$((i + ${#line} + 1))
      cmp="$line"; [ "${hds[k]}" = 1 ] && cmp="${cmp#"${cmp%%[!$tab]*}"}"   # <<- strips tabs
      if [ "$cmp" = "${hdd[k]}" ]; then found=1; break; fi
      body="$body$line"$'\n'
    done
    [ "$i" -le "$n" ] || i=$n
    [ "$found" = 1 ] || _CC_SC_BAD="$_CC_SC_BAD$body"
    [ "${hdc[k]}" -ge 0 ] && _CC_SC_IN[${hdc[k]}]="${_CC_SC_IN[${hdc[k]}]}$body"
  done
  hdd=(); hds=(); hdc=()
}

_cc_sc_redirect() {   # at < or >: the next word is a target (or a heredoc's delimiter)
  if [ "$inw" = 1 ] && [ "$wq" = 0 ] && [[ $word =~ ^[0-9]+$ ]]; then word=""; inw=0   # 2>&1
  else _cc_sc_word; fi
  if [ "${s:i:2}" = '<<' ]; then
    if [ "${s:i+2:1}" = '<' ]; then hs=1; i=$((i + 3))
    else hd=1; hdstrip=0; i=$((i + 2)); [ "${s:i:1}" = '-' ] && { hdstrip=1; i=$((i + 1)); }; fi
  else
    # rout: file for >, >>, >|, <> and &>; dup for >& (a descriptor copy, or bash's &> spelling)
    local op="${s:i:1}"
    redir=1; i=$((i + 1))
    case "${s:i:1}" in
      '&') [ "$op" = '<' ] || rout=dup; i=$((i + 1)) ;;
      '>'|'|') rout=file; i=$((i + 1)) ;;
      *) [ "$op" = '<' ] || rout=file ;;
    esac
  fi
}

_cc_sc_dquote() {   # at an opening "
  local ch nx
  inw=1; wq=1; i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    if [[ ${s:i} =~ $_CC_SC_DQPLAIN ]]; then
      word="$word${BASH_REMATCH[0]}"; i=$((i + ${#BASH_REMATCH[0]})); continue
    fi
    ch="${s:i:1}"
    case "$ch" in
      \") i=$((i + 1)); return 0 ;;
      \\) nx="${s:i+1:1}"
          case "$nx" in
            \$|\`|\"|\\) word="$word$nx"; i=$((i + 2)) ;;
            $'\n') i=$((i + 2)) ;;
            *) word="$word\\"; i=$((i + 1)) ;;
          esac ;;
      \$) _cc_sc_dollar ;;
      \`) _cc_sc_backtick ;;
    esac
  done
}

_cc_sc_dollar() {   # at a $, bare or inside "..."
  local nx="${s:i+1:1}" j d rest inner off pre
  inw=1
  case "$nx" in
    '(')
      if [ "${s:i+2:1}" = '(' ]; then                  # $(( arithmetic )): only ever a number
        j=$((i + 3)); d=2
        while [ "$j" -lt "$n" ] && [ "$d" -gt 0 ]; do
          case "${s:j:1}" in '(') d=$((d + 1)) ;; ')') d=$((d - 1)) ;; esac
          j=$((j + 1))
        done
        word="${word}0"; i=$j
      else                                             # $( ... ) runs its own commands
        _cc_sh_scan "$s" sub $((i + 2))
        word="$word${s:i:_CC_SC_END-i}"; i=$_CC_SC_END; wdyn=1
      fi ;;
    '{')
      j=$((i + 2)); d=1
      while [ "$j" -lt "$n" ] && [ "$d" -gt 0 ]; do
        case "${s:j:1}" in '{') d=$((d + 1)) ;; '}') d=$((d - 1)) ;; esac
        j=$((j + 1))
      done
      inner="${s:i+2:j-i-3}"; off=0
      while :; do                                      # ${x:-$(cmd)} runs cmd
        rest="${inner:off}"; pre="${rest%%\$\(*}"
        [ "$pre" = "$rest" ] && break
        _cc_sh_scan "$inner" sub $((off + ${#pre} + 2))
        off=$_CC_SC_END
      done
      case "$inner" in *\`*) _CC_SC_BAD="$_CC_SC_BAD$inner" ;; esac
      word="$word${s:i:j-i}"; i=$j; wdyn=1 ;;
    \')                                                # $'...': escapes can spell anything
      j=$((i + 2))
      while [ "$j" -lt "$n" ]; do
        case "${s:j:1}" in \\) j=$((j + 2)); continue ;; \') break ;; esac
        j=$((j + 1))
      done
      inner="${s:i+2:j-i-2}"; word="$word$inner"
      case "$inner" in *\\*) wdyn=1 ;; esac
      i=$((j + 1)) ;;
    \") i=$((i + 1)); _cc_sc_dquote ;;                 # $"...": a translated string
    [A-Za-z_])
      rest="${s:i+1}"; [[ $rest =~ ^[A-Za-z0-9_]+ ]]
      word="$word\$${BASH_REMATCH[0]}"; i=$((i + 1 + ${#BASH_REMATCH[0]})); wdyn=1 ;;
    [0-9@*#?\$!-]) word="$word\$$nx"; i=$((i + 2)); wdyn=1 ;;
    *) word="$word\$"; i=$((i + 1)) ;;
  esac
}

_cc_sc_backtick() {   # at an opening `: the inside runs as commands
  local j=$((i + 1)) inner="" ch nx
  while [ "$j" -lt "$n" ]; do
    ch="${s:j:1}"
    if [ "$ch" = '\' ]; then
      nx="${s:j+1:1}"
      case "$nx" in \$|\`|\\) inner="$inner$nx" ;; *) inner="$inner\\$nx" ;; esac
      j=$((j + 2)); continue
    fi
    [ "$ch" = '`' ] && break
    inner="$inner$ch"; j=$((j + 1))
  done
  _cc_sh_scan "$inner" top 0
  word="$word${s:i:j+1-i}"; i=$((j + 1)); inw=1; wdyn=1
}

# Judge shell text: 0 + CC_AA_RULE when a command in it is held. $2 = nesting depth.
_cc_aa_text() {
  local depth="$2" k j bad
  local -a cmds=() ins=() w=()
  if [ "$depth" -gt 6 ]; then CC_AA_RULE="hidden command"; return 0; fi
  _CC_SC_CMD=(); _CC_SC_IN=(); _CC_SC_BAD=""
  _cc_sh_scan "$1" top 0
  if [ ${#_CC_SC_CMD[@]} -gt 0 ]; then cmds=("${_CC_SC_CMD[@]}"); ins=("${_CC_SC_IN[@]}"); fi
  bad="$_CC_SC_BAD"
  # NAME=value words anywhere: an assignment can carry the held word a later $VAR or eval runs
  for k in ${cmds[@]+"${!cmds[@]}"}; do
    _cc_aa_words "${cmds[k]}"
    for j in ${_CC_AA_W[@]+"${!_CC_AA_W[@]}"}; do
      [[ ${_CC_AA_W[j]#"$_CC_AA_DYN"} =~ $_CC_AA_ASSIGN_RE ]] && _CC_AA_ASSIGNS="$_CC_AA_ASSIGNS ${_CC_AA_W[j]}"
    done
  done
  for k in ${cmds[@]+"${!cmds[@]}"}; do
    _cc_aa_words "${cmds[k]}"
    w=("${_CC_AA_W[@]}")
    _cc_aa_cmd "$depth" "${ins[k]}" "${w[@]}" && return 0
  done
  if [ -n "$bad" ] && [[ $bad =~ $_CC_AA_KWRE ]]; then CC_AA_RULE="hidden command"; return 0; fi
  return 1
}

_cc_aa_words() {   # split one command back into _CC_AA_W
  local rest="$1"
  _CC_AA_W=()
  while :; do
    case "$rest" in
      *"$_CC_AA_US"*) _CC_AA_W+=("${rest%%"$_CC_AA_US"*}"); rest="${rest#*"$_CC_AA_US"}" ;;
      *) _CC_AA_W+=("$rest"); return 0 ;;
    esac
  done
}

# Judge one simple command. $1 depth, $2 its heredoc/here-string text, then its words.
# Looks through keywords, NAME=value prefixes and wrappers to the command that really runs.
_cc_aa_cmd() {
  local depth="$1" stdin="$2" x k=0 n base txt j hasc hass any joined
  local -a w=() d=() sw=()
  shift 2
  for x in "$@"; do
    case "$x" in
      "$_CC_AA_DYN"*) w+=("${x#"$_CC_AA_DYN"}"); d+=(1) ;;
      *) w+=("$x"); d+=(0) ;;
    esac
  done
  n=${#w[@]}
  txt="$* $_CC_AA_ASSIGNS"   # where a held word behind $VAR / eval / $(...) would show
  while :; do
    while [ "$k" -lt "$n" ]; do
      case "${w[k]}" in '!'|'{'|'}'|then|do|else|elif|if|while|until|fi|done|esac) k=$((k + 1)); continue ;; esac
      [[ ${w[k]} =~ $_CC_AA_ASSIGN_RE ]] && { k=$((k + 1)); continue; }
      break
    done
    [ "$k" -lt "$n" ] || return 1
    if [ "${d[k]}" = 1 ]; then _cc_aa_hidden "$txt"; return $?; fi   # $GIT push
    base="${w[k]##*/}"
    _cc_aa_extras && return 0
    case "$base" in
      sudo|doas) k=$((k + 1)); _cc_aa_opts '-u -g -C -D -h -p -r -t -T -U' ;;
      env)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            -S|--split-string) _cc_aa_text "${w[k+1]:-}" $((depth + 1)); return $? ;;
            -u|-C|-P|--unset|--chdir) k=$((k + 2)) ;;
            --) k=$((k + 1)); break ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      time) k=$((k + 1)); _cc_aa_opts '-f -o' ;;
      nohup|builtin) k=$((k + 1)); [ "${w[k]:-}" = -- ] && k=$((k + 1)) ;;
      nice) k=$((k + 1)); _cc_aa_opts '-n' ;;
      caffeinate) k=$((k + 1)); _cc_aa_opts '-t -w' ;;
      timeout) k=$((k + 1)); _cc_aa_opts '-s -k --signal --kill-after'; k=$((k + 1)) ;;
      command)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            -*v*|-*V*) return 1 ;;                      # command -v: a lookup, nothing runs
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      exec) k=$((k + 1)); _cc_aa_opts '-a' ;;
      xargs)
        k=$((k + 1))
        _cc_aa_opts '-I -L -n -P -s -E -d -a --max-args --max-procs --max-lines --delimiter --arg-file --replace --eof' ;;
      sh|bash|zsh|dash|ksh)
        k=$((k + 1)); hasc=0; hass=0
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            --rcfile|--init-file) k=$((k + 2)) ;;
            --*) k=$((k + 1)) ;;
            -*c*) hasc=1; k=$((k + 1)) ;;
            -*o|+*o|-O|+O) k=$((k + 2)) ;;                # -euo pipefail
            -*s*) hass=1; k=$((k + 1)) ;;
            -*|+*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        if [ "$hasc" = 1 ]; then
          [ "$k" -lt "$n" ] || return 1
          if [ "${d[k]}" = 1 ]; then _cc_aa_hidden "$txt"; return $?; fi
          _cc_aa_text "${w[k]}" $((depth + 1)); return $?
        fi
        [ "$hass" = 1 ] || [ "$k" -ge "$n" ] || return 1   # sh script.sh: a file we can't see
        [ -n "$stdin" ] || return 1
        _cc_aa_text "$stdin" $((depth + 1)); return $? ;;
      eval)
        k=$((k + 1)); any=0; joined=""; j=$k
        while [ "$j" -lt "$n" ]; do
          [ "${d[j]}" = 1 ] && any=1
          joined="$joined ${w[j]}"; j=$((j + 1))
        done
        [ "$any" = 1 ] && _cc_aa_hidden "$txt" && return 0
        _cc_aa_text "$joined" $((depth + 1)); return $? ;;
      trap)
        k=$((k + 1)); [ "${w[k]:-}" = -- ] && k=$((k + 1))
        [ "$k" -lt "$n" ] || return 1
        case "${w[k]}" in -*) return 1 ;; esac          # trap -p / -l / - SIG
        if [ "${d[k]}" = 1 ]; then _cc_aa_hidden "$txt"; return $?; fi
        _cc_aa_text "${w[k]}" $((depth + 1)); return $? ;;
      find)
        j=$((k + 1))
        while [ "$j" -lt "$n" ]; do
          case "${w[j]}" in
            -exec|-execdir|-ok|-okdir)
              j=$((j + 1)); sw=()
              while [ "$j" -lt "$n" ]; do
                case "${w[j]}" in ';'|'+') break ;; esac
                if [ "${d[j]}" = 1 ]; then sw+=("$_CC_AA_DYN${w[j]}"); else sw+=("${w[j]}"); fi
                j=$((j + 1))
              done
              _cc_aa_cmd "$depth" "" ${sw[@]+"${sw[@]}"} && return 0 ;;
          esac
          j=$((j + 1))
        done
        return 1 ;;
      *) _cc_aa_rules; return $? ;;
    esac
  done
}

_cc_aa_hidden() {   # $1 = where a hidden held word would show
  [[ $1 =~ $_CC_AA_KWRE ]] || return 1
  CC_AA_RULE="hidden command"
}

_cc_aa_opts() {   # skip the options at w[k]; $1 = the ones that take a separate value
  while [ "$k" -lt "$n" ]; do
    case "${w[k]}" in
      --) k=$((k + 1)); return 0 ;;
      -?*) case " $1 " in *" ${w[k]} "*) k=$((k + 2)) ;; *) k=$((k + 1)) ;; esac ;;
      *) return 0 ;;
    esac
  done
}

_cc_aa_flag() {   # is flag -$1 (in a short cluster) or long $2 among w[$3..] (up to --)?
  local j="$3"
  while [ "$j" -lt "$n" ]; do
    case "${w[j]}" in
      --) return 1 ;;
      --*) [ -n "$2" ] && [ "${w[j]}" = "$2" ] && return 0 ;;
      -*"$1"*) [ -n "$1" ] && return 0 ;;
    esac
    j=$((j + 1))
  done
  return 1
}

_cc_aa_extras() {   # an extra pattern: the command name, then words in that order
  local e j m
  local -a ew=()
  for e in ${_CC_AA_EXTRAS[@]+"${_CC_AA_EXTRAS[@]}"}; do
    read -r -a ew <<< "$e"
    [ ${#ew[@]} -gt 0 ] || continue
    # shellcheck disable=SC2053  # the extra's words are globs on purpose
    [[ $base == ${ew[0]} ]] || [[ ${w[k]} == ${ew[0]} ]] || continue
    j=$((k + 1)); m=1
    while [ "$m" -lt ${#ew[@]} ] && [ "$j" -lt "$n" ]; do
      # shellcheck disable=SC2053
      [[ ${w[j]} == ${ew[m]} ]] && m=$((m + 1))
      j=$((j + 1))
    done
    if [ "$m" -ge ${#ew[@]} ]; then CC_AA_RULE="$e"; return 0; fi
  done
  return 1
}

_cc_aa_rules() {   # the built-in list, on the command at w[k]
  local j sub c=0
  case "$base" in
    git)
      j=$((k + 1))
      while [ "$j" -lt "$n" ]; do                      # git's own options come first
        case "${w[j]}" in
          -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix) j=$((j + 2)) ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      [ "$j" -lt "$n" ] || return 1
      if [ "${d[j]}" = 1 ]; then _cc_aa_hidden "$txt"; return $?; fi   # git $SUB
      sub="${w[j]}"; j=$((j + 1))
      case "$sub" in
        push) CC_AA_RULE="git push"; return 0 ;;
        reset) _cc_aa_flag '' --hard "$j" && { CC_AA_RULE="git reset --hard"; return 0; } ;;
        clean) _cc_aa_flag f --force "$j" && { CC_AA_RULE="git clean -f"; return 0; } ;;
        branch)
          if _cc_aa_flag D '' "$j" || { _cc_aa_flag d --delete "$j" && _cc_aa_flag f --force "$j"; }; then
            CC_AA_RULE="git branch -D"; return 0
          fi ;;
        worktree)
          while [ "$j" -lt "$n" ]; do case "${w[j]}" in -*) j=$((j + 1)) ;; *) break ;; esac; done
          [ "${w[j]:-}" = remove ] && _cc_aa_flag f --force $((j + 1)) \
            && { CC_AA_RULE="git worktree remove --force"; return 0; } ;;
        checkout)
          while [ "$j" -lt "$n" ]; do
            case "${w[j]}" in .|./|:/|'*') CC_AA_RULE="git checkout -- ."; return 0 ;; esac
            j=$((j + 1))
          done ;;
      esac
      return 1 ;;
    gh)
      j=$((k + 1)); sub=""
      while [ "$j" -lt "$n" ] && [ "$c" -lt 2 ]; do
        case "${w[j]}" in
          -R|--repo) j=$((j + 1)) ;;
          -*) ;;
          *) sub="$sub ${w[j]}"; c=$((c + 1)) ;;
        esac
        j=$((j + 1))
      done
      case "$sub" in
        ' release create') CC_AA_RULE="gh release create"; return 0 ;;
        ' pr merge') CC_AA_RULE="gh pr merge"; return 0 ;;
      esac
      return 1 ;;
    rm)
      { _cc_aa_flag r --recursive $((k + 1)) || _cc_aa_flag R '' $((k + 1)); } \
        && _cc_aa_flag f --force $((k + 1)) && { CC_AA_RULE="rm -rf"; return 0; }
      return 1 ;;
    # print or search text, move around: a `publish` among their words is just a word
    echo|printf|cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|ls|cd|pushd|mkdir|touch|wc|man|which|type|file|stat|test|'['|open|code|vi|vim|nvim|nano|emacs)
      return 1 ;;
  esac
  j=$((k + 1))                                         # any tool's publish subcommand
  while [ "$j" -lt "$n" ] && [ "$c" -lt 2 ]; do
    case "${w[j]}" in
      -*) ;;
      publish) CC_AA_RULE="publish"; return 0 ;;
      *) c=$((c + 1)) ;;
    esac
    j=$((j + 1))
  done
  return 1
}

# ---- Talk mode (build program unit 6, 2026-09-28) -------------------------------------------
# A session in talk mode (CC_TALK_DIR/<key>, the panel's toggle) can read and talk but not
# change anything. cc-approve.sh denies its Edit-family calls outside ~/.claude/ and the
# scratchpads (cc_talk_path_ok), and every Bash command that isn't read-only (cc_cmd_readonly).
# Talk mode is a guard against changing things by accident, not a sandbox: an MCP tool, or a
# symlink under ~/.claude/, is out of its reach.

# The pure-bash first look (this hook runs for every tool call): 0 when the request is an
# Edit-family or Bash call from a session whose flag file exists. With no flag file at all it
# costs one glob. $1 = the hook's JSON.
cc_talk_candidate() {
  local f re
  for f in "$CC_TALK_DIR"/*; do
    [ -e "$f" ] || return 1                          # no flag file: nobody is in talk mode
    break
  done
  re='"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit|Bash)"'
  [[ $1 =~ $re ]] || return 1
  re='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
  [[ $1 =~ $re ]] || return 1
  [ -f "$CC_TALK_DIR/${BASH_REMATCH[1]//[^A-Za-z0-9._-]/_}" ]   # cc_key's sanitizing, in bash
}

# May the Edit family write path $1 in talk mode? Only under ~/.claude/ (memory, plans) or in a
# session's scratchpad (/private/tmp/claude-*/, also spelt /tmp/claude-*/), never through "..".
cc_talk_path_ok() {
  case "/$1/" in */../*) return 1 ;; esac
  case "$1" in
    "$HOME"/.claude/?*) return 0 ;;
    /private/tmp/claude-*/?*|/tmp/claude-*/?*) return 0 ;;
  esac
  return 1
}

# Is this Bash command read-only? $1 = the command. The same parse as cc_always_ask_match
# (_cc_sh_scan: && || ; | & and newlines, quotes, $(...), backticks, heredocs), then every
# command in it against a short list of readers (_cc_ro_cmd). A redirection to a file, a heredoc
# that never ends, a command named by an expansion ($CMD), a path outside the system bin dirs
# (./ls), or anything not on the list is not read-only. KEEP IN SYNC with
# docs/approvals-and-policies.md#talk-mode.
cc_cmd_readonly() { _cc_ro_text "$1" 0; }

_cc_ro_text() {   # $1 shell text, $2 nesting depth (sh -c inside sh -c)
  local depth="$2" k
  local -a cmds=()
  [ "$depth" -le 6 ] || return 1
  _CC_SC_CMD=(); _CC_SC_IN=(); _CC_SC_BAD=""; _CC_SC_OUT=""
  _cc_sh_scan "$1" top 0
  { [ -z "$_CC_SC_BAD" ] && [ -z "$_CC_SC_OUT" ]; } || return 1
  if [ ${#_CC_SC_CMD[@]} -gt 0 ]; then cmds=("${_CC_SC_CMD[@]}"); fi
  for k in ${cmds[@]+"${!cmds[@]}"}; do
    _cc_aa_words "${cmds[k]}"
    _cc_ro_cmd "$depth" 0 ${_CC_AA_W[@]+"${_CC_AA_W[@]}"} || return 1
  done
  return 0
}

# One simple command. $1 depth, $2 = 1 when xargs adds words to it from its input, then its
# words. Looks through keywords, NAME=value prefixes and wrappers to the command that runs.
_cc_ro_cmd() {
  local depth="$1" viaxargs="$2" x k=0 n base hasc
  local -a w=() d=()
  shift 2
  for x in "$@"; do
    case "$x" in
      "$_CC_AA_DYN"*) w+=("${x#"$_CC_AA_DYN"}"); d+=(1) ;;
      *) w+=("$x"); d+=(0) ;;
    esac
  done
  n=${#w[@]}
  while :; do
    while [ "$k" -lt "$n" ]; do
      case "${w[k]}" in '!'|'{'|'}'|then|do|else|elif|if|while|until|fi|done|esac) k=$((k + 1)); continue ;; esac
      if [[ ${w[k]} =~ $_CC_AA_ASSIGN_RE ]]; then
        x="${w[k]%%=*}"; _cc_ro_name "${x%+}" "${w[k]#*=}" || return 1
        k=$((k + 1)); continue
      fi
      break
    done
    [ "$k" -lt "$n" ] || return 0                      # only keywords and assignments
    [ "${d[k]}" = 0 ] || return 1                      # $CMD args: can't tell what runs
    case "${w[k]}" in
      /bin/*|/usr/bin/*|/usr/local/bin/*|/opt/homebrew/bin/*) ;;
      */*) return 1 ;;                                 # ./ls, bin/cat: not the system's reader
    esac
    base="${w[k]##*/}"
    if [ "$viaxargs" = 1 ]; then                       # its input can add any option
      case "$base" in
        cat|head|tail|wc|ls|grep|egrep|fgrep|echo|printf|stat|du|basename|dirname|realpath|readlink|cmp|md5|md5sum|shasum|sha1sum|sha256sum|cksum|strings|nl|jq) ;;
        *) return 1 ;;
      esac
    fi
    case "$base" in
      # wrappers: judge the command they run
      time) k=$((k + 1)); while [ "${w[k]:-}" = -p ]; do k=$((k + 1)); done; continue ;;
      nice) k=$((k + 1)); _cc_aa_opts '-n'; continue ;;
      timeout) k=$((k + 1)); _cc_aa_opts '-s -k --signal --kill-after'; k=$((k + 1)); continue ;;
      builtin) k=$((k + 1)); continue ;;
      command)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            -*v*|-*V*) return 0 ;;                     # command -v: a lookup, nothing runs
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      env)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            -u|--unset|-C|--chdir) k=$((k + 2)) ;;
            -i|-0|--ignore-environment|--null|-) k=$((k + 1)) ;;
            --) k=$((k + 1)); break ;;
            -*) return 1 ;;                            # -S splits a string into a command
            *) break ;;
          esac
        done
        continue ;;
      xargs)
        k=$((k + 1))
        _cc_aa_opts '-I -L -n -P -s -E -d -a --max-args --max-procs --max-lines --delimiter --arg-file --replace --eof'
        [ "$k" -lt "$n" ] || return 0                  # no command: xargs echoes
        viaxargs=1; continue ;;
      sh|bash|zsh|dash|ksh)
        k=$((k + 1)); hasc=0
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            --rcfile|--init-file) return 1 ;;
            --*) k=$((k + 1)) ;;
            -*c*) hasc=1; k=$((k + 1)) ;;
            -*o|+*o|-O|+O) k=$((k + 2)) ;;
            -*|+*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        { [ "$hasc" = 1 ] && [ "$k" -lt "$n" ] && [ "${d[k]}" = 0 ]; } || return 1   # a script file, stdin
        _cc_ro_text "${w[k]}" $((depth + 1)); return $? ;;
      # readers
      cat|head|tail|wc|ls|pwd|echo|printf|true|false|:|test|'['|'[['|which|type|whereis|stat|du|df|basename|dirname|realpath|readlink|date|uname|whoami|id|printenv|diff|cmp|comm|cut|tr|column|nl|paste|rev|fold|seq|strings|od|hexdump|md5|md5sum|shasum|sha1sum|sha256sum|cksum|jq|grep|egrep|fgrep|cd|pushd|popd|sleep|exit|set|ps|pgrep|lsof|case)
        return 0 ;;
      file) _cc_ro_no '-C --compile' ;;              # -C compiles a magic file
      rg) _cc_ro_no '--pre*' ;;                      # --pre runs a program on each file
      tree) _cc_ro_no '-o' ;;
      find) _cc_ro_no '-exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls' ;;
      sort) _cc_ro_no '-o* -[!-]*o* --output* --compress-program*' ;;
      uniq) _cc_ro_uniq ;;
      sed) _cc_ro_sed ;;
      git) _cc_ro_git ;;
      gh)
        case "${w[k+1]:-} ${w[k+2]:-}" in
          'pr view'|'pr list'|'pr diff'|'pr checks'|'pr status'|'issue view'|'issue list'|'issue status'|\
          'run view'|'run list'|'repo view'|'release view'|'release list'|'workflow list'|'workflow view'|'auth status')
            return 0 ;;
        esac
        return 1 ;;
      export|read)                                     # names they set, like NAME=value
        x=$((k + 1))
        while [ "$x" -lt "$n" ]; do
          case "${w[x]}" in
            -a|-d|-i|-n|-N|-p|-t|-u) [ "$base" = read ] && x=$((x + 1)) ;;
            -*) ;;
            *) _cc_ro_name "${w[x]%%=*}" "${w[x]#*=}" || return 1 ;;
          esac
          x=$((x + 1))
        done
        return 0 ;;
      for) _cc_ro_name "${w[k+1]:-}" x; return $? ;;
      *) return 1 ;;
    esac
    return $?
  done
}

# May a read-only command line set variable $1 (to $2)? Not one that makes a reader run
# something (GIT_EXTERNAL_DIFF, PAGER, PATH, zsh's tied path...): a script's own lowercase
# variables, and a few display settings.
_cc_ro_name() {
  case "$1" in
    path|fpath|cdpath|manpath|module_path) return 1 ;;
    *[a-z]*) return 0 ;;
    LC_*|LANG|LANGUAGE|TZ|NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|COLUMNS|LINES|TERM|GREP_COLOR|GREP_COLORS) return 0 ;;
    GIT_PAGER|PAGER) case "$2" in ''|cat) return 0 ;; esac ;;
  esac
  return 1
}

_cc_ro_no() {   # 0 when none of w[$2..] (default: the command's arguments) matches a glob in $1
  local j="${2:-$((k + 1))}" g
  local -a gs=()
  read -r -a gs <<< "$1"
  while [ "$j" -lt "$n" ]; do
    for g in "${gs[@]}"; do
      # shellcheck disable=SC2053  # the list is globs on purpose
      [[ ${w[j]} == $g ]] && return 1
    done
    j=$((j + 1))
  done
  return 0
}

_cc_ro_uniq() {   # uniq reads one file; a second one is where it writes
  local j=$((k + 1)) c=0
  while [ "$j" -lt "$n" ]; do
    case "${w[j]}" in
      -f|-s|-w|--skip-fields|--skip-chars|--check-chars) j=$((j + 1)) ;;
      -) c=$((c + 1)) ;;
      -*) ;;
      *) c=$((c + 1)) ;;
    esac
    j=$((j + 1))
  done
  [ "$c" -le 1 ]
}

# sed that only prints: -n, no -i/-I (in place), no -f (a script we can't see), and no w/W
# command, w flag or e (runs a command) in the script.
_cc_ro_sed() {
  local j=$((k + 1)) x quiet=0 given=0 sc
  local -a scripts=()
  while [ "$j" -lt "$n" ]; do
    x="${w[j]}"
    case "$x" in
      --) [ "$given" = 1 ] || scripts+=("${w[j+1]:-}"); break ;;
      -e|--expression) scripts+=("${w[j+1]:-}"); given=1; j=$((j + 2)); continue ;;
      --expression=*) scripts+=("${x#*=}"); given=1 ;;
      -n|--quiet|--silent) quiet=1 ;;
      -f|--file|--file=*|--in-place|--in-place=*) return 1 ;;
      --*) ;;
      -*)
        case "$x" in *[iIf]*) return 1 ;; esac
        case "$x" in *n*) quiet=1 ;; esac
        case "$x" in
          *e) scripts+=("${w[j+1]:-}"); given=1; j=$((j + 2)); continue ;;
          *e*) scripts+=("${x#*e}"); given=1 ;;
        esac ;;
      *) [ "$given" = 1 ] || { scripts+=("$x"); given=1; } ;;   # the script, then files
    esac
    j=$((j + 1))
  done
  [ "$quiet" = 1 ] || return 1
  for sc in ${scripts[@]+"${scripts[@]}"}; do _cc_ro_sedscript "$sc" || return 1; done
  return 0
}

_cc_ro_sedscript() {   # $1 a sed script: 0 when it only prints, deletes, holds and substitutes
  local s="$1" i=0 n=${#1} c dl
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    case "$c" in
      ' '|$'\t'|$'\n'|';'|'{'|'}'|'!'|','|'~'|'+'|'$'|[0-9]) i=$((i + 1)) ;;   # addresses, separators
      /) i=$((i + 1)); _cc_ro_upto / || return 1 ;;                            # /regex/
      \\) dl="${s:i+1:1}"; i=$((i + 2)); _cc_ro_upto "$dl" || return 1 ;;      # \cregexc
      s|y)
        dl="${s:i+1:1}"; i=$((i + 2))
        { [ -n "$dl" ] && _cc_ro_upto "$dl" && _cc_ro_upto "$dl"; } || return 1
        if [ "$c" = s ]; then
          while [ "$i" -lt "$n" ]; do
            case "${s:i:1}" in
              [0-9gpiImM]) i=$((i + 1)) ;;
              w|W|e) return 1 ;;                                               # s///w file, s///e
              *) break ;;
            esac
          done
        fi ;;
      p|P|=|l|q|Q|n|N|d|D|h|H|g|G|x|z|F) i=$((i + 1)) ;;
      b|t|T|:|r|R|a|i|c|'#')            # a label, a file it reads, text it prints: to the line's end
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" != $'\n' ]; do
          [ "${s:i:1}" = ';' ] && [ "$c" != '#' ] && [ "$c" != a ] && [ "$c" != i ] && [ "$c" != c ] && break
          i=$((i + 1))
        done ;;
      *) return 1 ;;                                                            # w, W, e, anything else
    esac
  done
  return 0
}

_cc_ro_upto() {   # move i past the next unescaped $1 in s; 1 when there is none
  local ch
  while [ "$i" -lt "$n" ]; do
    ch="${s:i:1}"
    if [ "$ch" = '\' ]; then i=$((i + 2)); continue; fi
    i=$((i + 1))
    [ "$ch" = "$1" ] && return 0
  done
  return 1
}

# git that only reads: status, log, diff, show and friends, and the listing forms of branch,
# tag, stash, worktree, remote, reflog and config. -c (core.pager, diff.external) and
# --output=<file> are not.
_cc_ro_git() {
  local j=$((k + 1)) sub
  while [ "$j" -lt "$n" ]; do                        # git's own options come first
    case "${w[j]}" in
      -c|--config-env|--config-env=*|--exec-path=*) return 1 ;;
      -C|--git-dir|--work-tree|--namespace|--super-prefix) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$n" ] || return 0                      # git --version
  [ "${d[j]}" = 0 ] || return 1                      # git $SUB
  sub="${w[j]}"; j=$((j + 1))
  _cc_ro_no '--output --output=*' "$j" || return 1
  case "$sub" in
    status|log|diff|show|blame|annotate|shortlog|describe|rev-parse|rev-list|ls-files|ls-tree|ls-remote|\
    cat-file|show-ref|for-each-ref|merge-base|name-rev|count-objects|check-ignore|check-attr|whatchanged|\
    diff-tree|diff-files|diff-index|range-diff|cherry|var|version|help|show-branch)
      return 0 ;;
    grep) _cc_ro_no '-O* --open-files-in-pager*' "$j"; return $? ;;   # -O runs a pager command
    branch) _cc_ro_listing "$j" dDmMcCuft l \
              '--delete* --move* --copy* --set-upstream* --unset-upstream --edit-description --force --track* --no-track --create-reflog --recurse-submodules'
            return $? ;;
    tag) _cc_ro_listing "$j" asufdmFe ln \
           '--annotate --sign --local-user* --force --delete --message* --file* --edit --no-sign --cleanup* --create-reflog --trailer*'
         return $? ;;
    stash) case "${w[j]:-}" in list|show) return 0 ;; esac; return 1 ;;
    worktree) [ "${w[j]:-}" = list ]; return $? ;;
    remote) case "${w[j]:-}" in ''|-v|--verbose|show|get-url) return 0 ;; esac; return 1 ;;
    reflog) case "${w[j]:-}" in ''|show|exists) return 0 ;; esac; return 1 ;;
    config) _cc_ro_gitconfig "$j"; return $? ;;
  esac
  return 1
}

# git branch / tag: only the listing forms. $1 its first word, $2 the short options that
# change something, $3 the short options that list, $4 the long ones that change (globs).
# A name with no listing option creates one.
_cc_ro_listing() {
  local j="$1" x pos=0 list=0 g
  local -a lm=()
  read -r -a lm <<< "$4"
  while [ "$j" -lt "$n" ]; do
    x="${w[j]}"
    case "$x" in
      --list|--show-current) list=1 ;;
      --contains|--no-contains|--merged|--no-merged|--points-at)
        list=1; case "${w[j+1]:-}" in ''|-*) ;; *) j=$((j + 1)) ;; esac ;;
      --contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*) list=1 ;;
      --sort|--format) j=$((j + 1)) ;;
      --*) for g in ${lm[@]+"${lm[@]}"}; do
             # shellcheck disable=SC2053
             [[ $x == $g ]] && return 1
           done ;;
      -?*) [[ ${x:1} =~ [$2] ]] && return 1
           [[ ${x:1} =~ [$3] ]] && list=1 ;;
      *) pos=$((pos + 1)) ;;
    esac
    j=$((j + 1))
  done
  [ "$pos" = 0 ] || [ "$list" = 1 ]
}

_cc_ro_gitconfig() {   # git config that reads: --get*, --list, get, list, or one bare key
  local j="$1" x pos=0 rd=0
  while [ "$j" -lt "$n" ]; do
    x="${w[j]}"
    case "$x" in
      --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|--list|-l) rd=1 ;;
      -f|--file|--blob|--type|--default) j=$((j + 1)) ;;
      --show-origin|--show-scope|--name-only|-z|--null|--includes|--no-includes|--global|--system|\
      --local|--worktree|--bool|--int|--bool-or-int|--path|--expiry-date|--type=*|--default=*|\
      --file=*|--blob=*) ;;
      -*) return 1 ;;                                  # --add, --unset, --replace-all, --edit ...
      *) if [ "$pos" = 0 ]; then
           case "$x" in
             get|list) rd=1 ;;
             set|unset|rename-section|remove-section|edit) return 1 ;;
           esac
         fi
         pos=$((pos + 1)) ;;
    esac
    j=$((j + 1))
  done
  [ "$rd" = 1 ] || [ "$pos" -le 1 ]                    # git config key reads; key value sets
}

# ---- What a new session is told at SessionStart (2026-09-28) --------------------------------
# Claude Code adds a SessionStart hook's stdout to the new session's context. cc-status.sh prints
# cc_session_context there, once, at the end. The context is built from parts: each is a function
# _cc_ctx_<name>, given (source key cwd), that prints its text or nothing. The builder labels each
# part "[Shepherd: <name>]" and caps the total at CC_CONTEXT_MAX characters; a part that would pass
# the cap is cut, and the parts after it are left out. A new part goes in CC_CONTEXT_PARTS.
CC_NOTES_DIR="${CC_NOTES_DIR:-${HOME}/.claude/cc-notes}"
# 2026-09-29: "notes" (auto-compact, unit 16) prints only after a compaction, and comes first there.
# 2026-09-29: "lease" (worktree leases, unit 27) is short and comes before the long parts, so a big
# handoff note or mailbox never crowds out which port is the session's own.
# 2026-09-29: "decisions" (the decisions inbox, unit 28) -- Adam's late answers -- is short too.
CC_CONTEXT_PARTS="notes lease decisions handoff mailbox"
CC_CONTEXT_MAX=8000
CC_PENDING_MAX_AGE=3600   # a respawn's note nobody took within the hour is stale

cc_session_context() { # $1 source (startup|resume|clear|compact), $2 key, $3 cwd
  [ -z "${CC_SHEPHERD_INTERNAL:-}" ] || return 0   # Shepherd's own runs take nothing
  local out="" name part block keep max="$CC_CONTEXT_MAX"
  # 2026-09-29: a compacted session's notes have their own 12KB (CC_NOTES_PART_MAX) on top of the
  # cap every other part shares, so the notes never crowd the rest out -- or get cut at 8000.
  [ "$1" != compact ] || max=$(( CC_CONTEXT_MAX + ${CC_NOTES_PART_MAX:-12288} + 512 ))
  local cut="[cut: Shepherd's session context is capped at $max characters]"
  for name in $CC_CONTEXT_PARTS; do
    part="$("_cc_ctx_$name" "$1" "$2" "$3")"
    [ -n "$part" ] || continue
    block="[Shepherd: $name]"$'\n'"$part"
    [ -z "$out" ] || block=$'\n\n'"$block"
    if [ $(( ${#out} + ${#block} + 1 )) -gt "$max" ]; then
      keep=$(( max - ${#cut} - 2 ))
      [ "$keep" -ge 0 ] || keep=0
      out="$out$block"
      out="${out:0:$keep}"$'\n'"$cut"
      break
    fi
    out="$out$block"
  done
  [ -z "$out" ] || printf '%s\n' "$out"
}

# 32-bit djb2 of $1's bytes as 8 hex digits: the same as core.cheapHash, so the shell finds the
# files Lua names with it. (Hex by hand: some awks print a large %x wrong.)
cc_hash() {
  printf '%s' "$1" | od -An -v -tu1 | awk 'BEGIN { h = 5381 }
    { for (i = 1; i <= NF; i++) h = (h * 33 + $i) % 4294967296 }
    END { s = ""; for (i = 0; i < 8; i++) { d = h % 16; s = substr("0123456789abcdef", d + 1, 1) s; h = (h - d) / 16 }
          printf "%s", s }'
}

cc_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }   # GNU first: its -f means file system

# The process a handoff note belongs to -- the same token as core.handoffMatch: an editor tab's
# claude pid and window (a /clear keeps both), or a kitty window. Empty when neither is known.
cc_handoff_match() { # $1 editor, $2 session_pid, $3 host_window, $4 kitty socket, $5 kitty window id
  case "$1" in
    [Kk][Ii][Tt][Tt][Yy])
      [ -n "$4" ] && [ -n "$5" ] || return 0
      printf 'kitty-%s' "$(cc_hash "$4#$5")" ;;
    *)
      case "$2" in ''|*[!0-9]*) return 0 ;; esac
      local host="$3"
      case "$host" in ''|*[!0-9]*) host=0 ;; esac
      printf 'pid-%s-%s' "$2" "$host" ;;
  esac
}

# The handoff part: after /clear a one-line pointer to the note the session before it left (the
# same claude process); after a respawn the whole note Shepherd left in pending/, taken once.
# A resumed or compacted session still has its own context, so it is told nothing.
_cc_ctx_handoff() { # $1 source, $2 key, $3 cwd
  case "$1" in
    clear) _cc_handoff_pointer "$2" ;;
    startup) _cc_handoff_pending "$2" "$3" ;;
  esac
}

_cc_handoff_pointer() { # $1 key
  local key="$1" us=$'\x1f' ed pid host sock wid tok f m best=0 note="" last
  cc_have_jq || return 0
  IFS="$us" read -r ed pid host sock wid <<EOF
$(jq -r --arg us "$us" '[.editor, .session_pid, .host_window, .kitty_listen_on, .kitty_window_id]
  | map(. // "" | tostring) | join($us)' "$(cc_file "$key")" 2>/dev/null)
EOF
  tok="$(cc_handoff_match "$ed" "$pid" "$host" "$sock" "$wid")"
  [ -n "$tok" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ "$f" != "$CC_NOTES_DIR/$key.handoff.md" ] || continue
    m="$(cc_mtime "$f")"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    if [ -z "$note" ] || [ "$m" -gt "$best" ]; then best="$m"; note="$f"; fi
  done <<EOF
$(grep -l -F -x -- "<!-- cc-handoff match:$tok -->" "$CC_NOTES_DIR"/*.handoff.md 2>/dev/null)
EOF
  [ -n "$note" ] || return 0
  last="$(sed -n 's/^Last turn: //p' "$note" 2>/dev/null | head -1)"
  printf 'Before /clear, this session left a handoff note%s: %s -- read it to pick up where it left off.\n' \
    "${last:+ (last turn: $last)}" "$note"
}

_cc_handoff_pending() { # $1 key, $2 cwd
  local key="$1" cwd="$2" lin id f claim m now
  lin="$(cc_read_field "$key" '.budget_lineage')"
  set -- "cwd-$(cc_hash "$cwd")"
  [ -z "$lin" ] || set -- "lineage-$(cc_hash "$lin")" "$@"
  now="$(cc_now)"
  for id in "$@"; do
    f="$CC_NOTES_DIR/pending/$id.md"
    [ -f "$f" ] || continue
    claim="$f.claim.$$"
    mv "$f" "$claim" 2>/dev/null || continue   # another session took it first
    m="$(cc_mtime "$claim")"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    if [ $(( now - m )) -le "$CC_PENDING_MAX_AGE" ]; then
      printf 'Shepherd respawned this session in place of one that stopped. The note it left:\n\n'
      cat "$claim"
      rm -f "$claim"
      echo "[cc-lib] ✅ handed the respawned session its note ($id)" >&2
      return 0
    fi
    rm -f "$claim"
    echo "[cc-lib] ⚠️ dropped a stale handoff note ($id): nobody took it within the hour" >&2
  done
}

# ---- The session mailbox (build program unit 11a, 2026-09-29) -------------------------------
# Shepherd hands a session a message without typing into its window: FX.mailboxSend leaves it in
# CC_INBOX_DIR/<key>/ as <epoch>-<seq>-<nonce>.msg, a JSON body {"nonce","text",...} written
# temp-then-rename, so the names sort oldest first and a half-written one never matches *.msg.
# The session takes it at its next turn end (cc-status.sh stop blocks the stop with it, through
# cc_stop_decision) or its next start (the mailbox part below). A message is claimed with mv, so
# it is handed over once, whoever races for it; a body whose nonce isn't its name's, or whose text
# is a slash command, is put back and left alone. KEEP THE RULES IN SYNC with core.parseMailbox.
CC_MAILBOX_PART_MAX=2000   # what a session's start may show; the rest waits, whole, for its turn end

_cc_mailbox_slash() { # is $1 a slash command, marked [shepherd] or not? (core.mailboxSlash)
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in "[shepherd]"*) s="${s:10}"; s="${s#"${s%%[![:space:]]*}"}" ;; esac
  case "$s" in /*) return 0 ;; esac
  return 1
}

# Hand over one message file: its text on stdout, the file gone. 1 when it is no message to hand
# over (another reader took it first, a wrong nonce, a slash command) -- those are left as they were.
# $2 = how it goes (stop | start), for the ledger; $3 = the session key.
_cc_mailbox_take() { # $1 file, $2 via, $3 key
  local f="$1" base nonce claim text
  base="${f##*/}"; base="${base%.msg}"; nonce="${base##*-}"
  case "$base" in [0-9]*-[0-9]*-*) ;; *) return 1 ;; esac
  case "$nonce" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  claim="$f.claim.$$"
  mv "$f" "$claim" 2>/dev/null || return 1   # another hook (or the panel) took it first
  text="$(jq -r --arg n "$nonce" 'select(.nonce == $n) | .text // empty' "$claim" 2>/dev/null)"
  if [ -z "$text" ] || _cc_mailbox_slash "$text"; then
    mv "$claim" "$f" 2>/dev/null
    echo "[cc-lib] ⚠️ left a mailbox message alone (${f##*/}): $([ -n "$text" ] && echo "a slash command" || echo "its nonce doesn't match its name")" >&2
    return 1
  fi
  rm -f "$claim"
  if cc_ledger_enabled; then
    cc_ledger_append "$(jq -nc --arg key "$3" --arg via "$2" --arg n "$nonce" \
      '{type:"mailbox_delivered", key:$key, via:$via, nonce:$n}')"
  fi
  echo "[cc-lib] ✅ handed session $3 its mailbox message ${f##*/} ($2)" >&2
  printf '%s' "$text"
}

# The oldest message waiting for session $1, handed over: its text on stdout. 1 when none waits.
cc_mailbox_claim() { # $1 key, $2 via (stop | start)
  local key="$1" f
  case "$key" in ''|.|..|*/*) return 1 ;; esac
  [ -d "$CC_INBOX_DIR/$key" ] || return 1
  cc_have_jq || return 1
  for f in "$CC_INBOX_DIR/$key"/*.msg; do
    [ -f "$f" ] || continue
    _cc_mailbox_take "$f" "${2:-stop}" "$key" && return 0
  done
  return 1
}

# The mailbox part of cc_session_context: every message still waiting, oldest first, handed over
# now -- as many as fit in CC_MAILBOX_PART_MAX. The first that doesn't fit, and every one after it,
# stays for the turn end: it is looked at before it is claimed, so it is never shown cut.
_cc_ctx_mailbox() { # $1 source, $2 key
  local key="$2" f text out="" n=0
  case "$key" in ''|.|..|*/*) return 0 ;; esac
  [ -d "$CC_INBOX_DIR/$key" ] || return 0
  cc_have_jq || return 0
  for f in "$CC_INBOX_DIR/$key"/*.msg; do
    [ -f "$f" ] || continue
    text="$(jq -r '.text // empty' "$f" 2>/dev/null)"
    [ $(( ${#out} + ${#text} + 2 )) -le "$CC_MAILBOX_PART_MAX" ] || break
    text="$(_cc_mailbox_take "$f" start "$key")" || continue
    [ -z "$out" ] || out="$out"$'\n\n'
    out="$out$text"
    n=$((n + 1))
  done
  [ -n "$out" ] || return 0
  if [ "$n" -eq 1 ]; then printf 'Shepherd left this session a message:\n\n%s\n' "$out"
  else printf 'Shepherd left this session %s messages, oldest first:\n\n%s\n' "$n" "$out"; fi
}

# ---- What a finished turn is told (2026-09-29) --------------------------------------------
# A Stop hook that prints {"decision":"block","reason":...} keeps the session going, with the
# reason as what to do next. cc-status.sh decides its reasons as it runs and prints them here,
# once, at the end of the script: each non-empty argument is one reason, joined by a blank line;
# nothing to say prints nothing. The caller never blocks a stop that stop_hook_active marks (it is
# the end of a turn a block already kept going), so a block can't loop. The mailbox is the first
# reason; unit 16 adds its notes request as another argument.
cc_stop_decision() {
  local reason="" r
  for r in "$@"; do
    [ -n "$r" ] || continue
    [ -z "$reason" ] || reason="$reason"$'\n\n'
    reason="$reason$r"
  done
  [ -n "$reason" ] || return 0
  cc_have_jq || return 0
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
}

# ---- Auto-compact with notes (build program unit 16, 2026-09-29) ---------------------------
# With compact.enabled Shepherd leaves each live session CC_NOTES_DIR/<key>.due-at, one line
# "<due> <compactAt> <window>" in tokens (core.compactDue): Claude Code compacts it at compactAt
# (env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE), and a summary drops detail. At the first turn end past
# due, cc-status.sh stop asks the session -- once per compaction cycle, through cc_stop_decision --
# to write its notes to <key>.notes.md. A cycle ends when the context drops below due again (the
# compaction happened), so a compaction that failed isn't asked twice. PreCompact tells the summary
# the notes come back; SessionStart(compact) hands them back (the notes part below).
CC_NOTES_PART_MAX=12288   # bytes of notes a compacted session gets back (core.COMPACT.notesMax)

# The context of the transcript's last real assistant turn, in tokens (input + both cache
# buckets, as core.contextTokens); nothing when there's none. Reads the last 256KB only; a torn
# last line, a sidechain and a zero-usage synthetic error record are skipped.
cc_transcript_context() { # $1 transcript path
  [ -f "$1" ] || return 0
  cc_have_jq || return 0
  tail -c 262144 "$1" 2>/dev/null | grep -F '"usage"' | tail -n 40 \
    | jq -R 'fromjson? | select(type == "object" and .type == "assistant" and .isSidechain != true)
             | .message.usage | select(type == "object")
             | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
             | select(. > 0)' 2>/dev/null | tail -n 1
}

# The Stop hook's notes request for session $1: the reason on stdout and 0 when the session should
# write its notes now; 1 (nothing printed) when it shouldn't. $2 = the hook's JSON. Never while
# stop_hook_active (a block already kept this turn going) or in plan mode (it can't write a file);
# the caller never asks in Shepherd's internal runs.
cc_notes_request() { # $1 key, $2 hook input
  local key="$1" in="$2" due cat win extra mode tokens asked path pct
  case "$key" in ''|.|..|*/*) return 1 ;; esac
  [ -f "$CC_NOTES_DIR/$key.due-at" ] || return 1
  read -r due cat win extra < "$CC_NOTES_DIR/$key.due-at" 2>/dev/null
  case "$due" in ''|*[!0-9]*) return 1 ;; esac
  case "$cat" in ''|*[!0-9]*) cat="" ;; esac
  case "$win" in ''|*[!0-9]*) win="" ;; esac
  [ "$(cc_get "$in" '.stop_hook_active')" != "true" ] || return 1
  mode="$(cc_get "$in" '.permission_mode')"
  [ -n "$mode" ] || mode="$(cc_read_field "$key" '.permission_mode')"
  [ "$mode" != "plan" ] || return 1
  tokens="$(cc_transcript_context "$(cc_get "$in" '.transcript_path')")"
  case "$tokens" in ''|*[!0-9]*) return 1 ;; esac
  asked="$CC_NOTES_DIR/$key.notes-asked"
  if [ "$tokens" -lt "$due" ]; then
    rm -f "$asked" 2>/dev/null   # below due-at again: the compaction happened, a new cycle begins
    return 1
  fi
  [ ! -e "$asked" ] || return 1  # asked already this cycle
  printf '%s\n' "$tokens" > "$asked" 2>/dev/null || return 1
  path="$CC_NOTES_DIR/$key.notes.md"
  pct=""; [ -n "$win" ] && [ "$win" -gt 0 ] && pct=" ($(( tokens * 100 / win ))% of its ${win}-token window)"
  if cc_ledger_enabled; then
    cc_ledger_append "$(jq -nc --arg key "$key" --argjson t "$tokens" --argjson d "$due" \
      '{type:"notes_requested", key:$key, tokens:$t, due:$d}')"
  fi
  echo "[cc-lib] 📝 asked session $key for its notes: $tokens tokens, due at $due" >&2
  printf '%s' "[shepherd] This session's context is at $tokens tokens$pct, and Claude Code will compact it automatically${cat:+ at about $cat tokens}. A summary drops detail, so save your working notes first: write them to $path (overwrite it; it is yours), under 12 KB. Include the task and its goal, what's done, what's in progress, the exact next steps, the decisions made and why, the files and commands involved, and anything else you'd need to carry on without this conversation. They are handed back to you right after the compaction. Then carry on with the task."
  return 0
}

# PreCompact: Claude Code adds a PreCompact hook's stdout to the summary's instructions. With
# notes saved, the summary is told they come back whole. Prints nothing without notes.
cc_precompact_context() { # $1 key
  local key="$1" path
  case "$key" in ''|.|..|*/*) return 0 ;; esac
  path="$CC_NOTES_DIR/$key.notes.md"
  [ -s "$path" ] || return 0
  printf '%s\n' "Shepherd: this session saved its working notes in $path, and they are handed back in full right after this compaction. Keep the summary to the conversation's current state and point to that file for the notes rather than restating them."
}

# The notes part of cc_session_context: after a compaction, the notes the session saved, whole up
# to CC_NOTES_PART_MAX bytes -- beyond that, cut, with the file named for the rest.
_cc_ctx_notes() { # $1 source, $2 key
  [ "$1" = compact ] || return 0
  local key="$2" path size
  case "$key" in ''|.|..|*/*) return 0 ;; esac
  path="$CC_NOTES_DIR/$key.notes.md"
  [ -s "$path" ] || return 0
  size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  printf 'Before this compaction you saved your working notes in %s. Here they are:\n\n' "$path"
  if [ "$size" -gt "$CC_NOTES_PART_MAX" ]; then
    head -c "$CC_NOTES_PART_MAX" "$path"
    printf '\n\n[notes cut at 12 KB -- read %s for the rest]\n' "$path"
  else
    cat "$path"
  fi
}

# The lease part of cc_session_context (worktree leases, build program unit 27, 2026-09-29): when
# the session's folder is a worktree Shepherd leased a port and database path to, or inside one,
# say so -- at every start, /clear and compaction, so a fresh context never loses its own port.
# Only a well-formed lease is shown (a whole-number port, absolute paths with no control character):
# the text lands in the session's context. lease.enabled false says nothing. The deepest match wins.
_cc_ctx_lease() { # $1 source, $2 key, $3 cwd
  local cwd="${3%/}" f line wt port db best="" bport="" bdb=""
  case "$cwd" in /*) ;; *) return 0 ;; esac
  [ -d "$CC_LEASE_DIR" ] || return 0
  cc_have_jq || return 0
  [ "$(cc_config '.lease.enabled' 'true')" != false ] || return 0
  for f in "$CC_LEASE_DIR"/*.json; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r wt port db; do
      [ -n "$wt" ] || continue
      [ "${#wt}" -gt "${#best}" ] || continue
      best="$wt" bport="$port" bdb="$db"
    done < <(jq -r --arg cwd "$cwd" '
      if (.leases | type) == "object" then .leases | to_entries[] else empty end
      | select((.key | type) == "string" and (.key | startswith("/")) and (.key | test("[[:cntrl:]]") | not))
      | select((.value | type) == "object")
      | select((.value.port | type) == "number" and .value.port >= 1 and .value.port <= 65535
               and .value.port == (.value.port | floor))
      | select((.value.db | type) == "string" and (.value.db | startswith("/")) and (.value.db | test("[[:cntrl:]]") | not))
      | (.key | rtrimstr("/")) as $wt
      | select($cwd == $wt or ($cwd | startswith($wt + "/")))
      | "\($wt)\t\(.value.port)\t\(.value.db)"' "$f" 2>/dev/null)
  done
  [ -n "$best" ] || return 0
  printf 'Shepherd leased this worktree (%s) its own port and database path: PORT=%s, DB_PATH=%s. Run any server it starts on that port and keep any database at that path, so parallel units never collide. Both are also in $(git rev-parse --git-dir)/shepherd-lease.env, which a project can source.\n' \
    "$best" "$bport" "$bdb"
}

# The decisions part of cc_session_context (the decisions inbox, build program unit 28, 2026-09-29):
# Adam's answers to questions this session asked with cc-decide.sh and went ahead on with their
# defaults, when they came after it stopped running (a live session gets them through its mailbox,
# FX.stepDecisions). Each answer is claimed with mv and shown only when its nonce is its question's;
# one that isn't is put back and never shown. An answer that IS the default closes the question and
# says nothing. As many as fit in CC_DECIDE_PART_MAX; the rest wait for the next start.
CC_DECIDE_PART_MAX=2000
_cc_ctx_decisions() { # $1 source, $2 key
  local key="$2" f parsed k id kind rec claim fields q d nonce a line out="" n=0 us=$'\x1f'
  case "$key" in ''|.|..|*/*) return 0 ;; esac
  [ -d "$CC_DECIDE_DIR" ] || return 0
  cc_have_jq || return 0
  for f in "$CC_DECIDE_DIR/$key".*.answer; do
    [ -f "$f" ] || continue
    parsed="$(_cc_decide_name "${f##*/}")" || continue
    read -r k id kind <<EOF
$parsed
EOF
    [ "$k" = "$key" ] && [ "$kind" = answer ] || continue
    rec="$CC_DECIDE_DIR/$id.json"
    [ -f "$rec" ] || continue
    # one line: a question may span several, and each answer is one line of the part
    fields="$(jq -r --arg us "$us" '[.nonce, .question, .default] | map(. // "" | tostring | gsub("[\\r\\n]+"; " ")) | join($us)' "$rec" 2>/dev/null)"
    IFS="$us" read -r nonce q d <<EOF
$fields
EOF
    [ -n "$nonce" ] || continue
    a="$(jq -r --arg n "$nonce" 'select(.nonce == $n) | .answer | select(type == "string") | gsub("^\\s+|\\s+$"; "") | gsub("[\\r\\n]+"; " ")' "$f" 2>/dev/null)"
    [ -n "$a" ] || continue   # another nonce, or empty: never shown (Shepherd throws it away)
    line="- You asked: \"$q\" -- you went ahead with \"$d\"; Adam's answer: \"$a\""
    [ "$a" = "$d" ] || [ $(( ${#out} + ${#line} + 1 )) -le "$CC_DECIDE_PART_MAX" ] || break
    claim="$f.claim.$$"
    mv "$f" "$claim" 2>/dev/null || continue   # another start (or Shepherd) took it first
    rm -f "$claim" "$rec" 2>/dev/null
    if cc_ledger_enabled; then
      cc_ledger_append "$(jq -nc --arg key "$key" --arg id "$id" '{type:"decision_answered", key:$key, id:$id, via:"start"}')"
    fi
    echo "[cc-lib] ✅ handed session $key Adam's answer to $id" >&2
    [ "$a" != "$d" ] || continue   # the default: nothing to change
    out="$out$line"$'\n'
    n=$((n + 1))
  done
  [ -n "$out" ] || return 0
  if [ "$n" -eq 1 ]; then printf 'Adam answered a question this session asked with cc-decide.sh and went ahead on with its default:\n'
  else printf 'Adam answered %s questions this session asked with cc-decide.sh and went ahead on with their defaults:\n' "$n"; fi
  printf '%s' "$out"
  printf 'If an answer changes something you did, adjust it; otherwise carry on.\n'
}

# ---- Worktree fence (build program unit 7, 2026-09-28) --------------------------------------
# With gate.fence on, a session can't change a sibling worktree of its own repo: another worktree
# with the same git common dir (git rev-parse --git-common-dir) and a different toplevel, asked of
# the target's nearest existing folder. The main checkout is a sibling of every linked worktree,
# but a session whose cwd IS the main checkout changes main as its own tree (the post-merge steps
# run there after ExitWorktree). cc-approve.sh denies an Edit-family file in a sibling, and in a
# Bash command that names git or cd: mutating git aimed at a sibling (-C, --git-dir, --work-tree,
# GIT_DIR=, GIT_WORK_TREE=, or after cd / pushd <sibling>) and an output redirection into one.
# Read-only git (_cc_ro_git: status, log, diff, show, rev-parse, merge-base, worktree list...) is
# fine, and so is the session's own approved merge, git -C <main> merge --ff-only <its branch>
# (cc_fence_merge_ok). Cheap first: a path whose nearest .git, found in pure bash, is the cwd's
# own (or that has none) is judged without git; only a path outside the cwd's own toplevel costs a
# git rev-parse. A folder named by an expansion ($DIR, $(...)) can't be judged and goes on: the
# fence guards against accidents, it isn't a sandbox. KEEP IN SYNC with
# docs/approvals-and-policies.md#worktree-fence.
CC_FENCE_TOP=""   # the sibling cc_fence_sibling found: its toplevel (a git dir for kind gitdir)
CC_FENCE_T=()     # cc_fence_targets' findings, each kind US path US branch
_CC_FENCE_TOP=""; _CC_FENCE_J=""
_CC_FENCE_OWN=""; _CC_FENCE_OWN_TOP=""; _CC_FENCE_OWN_COMMON=""; _CC_FENCE_OWN_GITDIR=""

# The pure-bash first look (this hook runs for every tool call): 0 when the fence must read the
# request. gate.fence has to be on; an Edit-family call qualifies unless its file is plainly in
# the cwd's own tree (or in none), a Bash call only when its command names git, cd or pushd and
# something that can point elsewhere (cd, pushd, -C, --git-dir, --work-tree, GIT_DIR,
# GIT_WORK_TREE, a redirection). $1 = the hook's JSON.
cc_fence_candidate() {
  local re tool txt="" cmd cwd p
  re='"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit|Bash)"'
  [[ $1 =~ $re ]] || return 1
  tool="${BASH_REMATCH[1]}"
  [ -f "$CC_CONFIG_FILE" ] || return 1
  IFS= read -r -d '' txt < "$CC_CONFIG_FILE" 2>/dev/null
  re='"fence"[[:space:]]*:[[:space:]]*true'
  [[ $txt =~ $re ]] || return 1                      # jq has the last word on the flag
  if [ "$tool" = Bash ]; then
    cmd="$1"
    re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
    [[ $1 =~ $re ]] && cmd="${BASH_REMATCH[1]}"
    re='(^|[^[:alnum:]_]|\\[nrt])(git|cd|pushd)([^[:alnum:]_]|$)'   # \n \t: JSON escapes
    [[ $cmd =~ $re ]] || return 1
    re='(^|[^[:alnum:]_]|\\[nrt])(cd|pushd|-C|--git-dir|--work-tree|GIT_DIR|GIT_WORK_TREE)([^[:alnum:]_]|$)|>'
    [[ $cmd =~ $re ]]
    return
  fi
  re='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
  [[ $1 =~ $re ]] || return 0
  cwd="${BASH_REMATCH[1]}"
  re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
  [[ $1 =~ $re ]] || return 0
  p="${BASH_REMATCH[2]}"
  case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
  ! cc_fence_cheap_own "$p" "$cwd"
}

# 0 when path $1 is plainly in the cwd $2's own tree, or in no git tree at all, judged in pure
# bash: the nearest .git at or above the path's nearest existing folder is the cwd's own (or there
# is none), with no ".." and no symlink on the way. 1 means git has to say.
cc_fence_cheap_own() {
  local p="${1%/}" own
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p/" in */../*|*/./*) return 1 ;; esac
  _cc_fence_top "$2" || return 1
  own="$_CC_FENCE_TOP"
  [ -n "$own" ] || return 0                          # the cwd is in no repo: it has no siblings
  while [ -n "$p" ] && [ ! -d "$p" ]; do p="${p%/*}"; done
  _cc_fence_top "$p" || return 1
  [ -z "$_CC_FENCE_TOP" ] || [ "$_CC_FENCE_TOP" = "$own" ]
}

_cc_fence_top() {   # the nearest folder at or above $1 holding a .git -> _CC_FENCE_TOP ("": none); 1 on a symlink
  local d="${1%/}"
  _CC_FENCE_TOP=""
  while :; do
    if [ -e "$d/.git" ]; then _CC_FENCE_TOP="${d:-/}"; return 0; fi
    [ -n "$d" ] || return 0
    [ -L "$d" ] && return 1
    d="${d%/*}"
  done
}

_cc_fence_own() {   # the cwd $1's own worktree, asked of git once per run; 1 when it isn't in one
  local out
  if [ -z "$_CC_FENCE_OWN" ]; then
    _CC_FENCE_OWN=none
    if out="$(git -C "$1" rev-parse --path-format=absolute --show-toplevel --git-common-dir --git-dir 2>/dev/null)"; then
      _CC_FENCE_OWN_TOP="${out%%$'\n'*}"; out="${out#*$'\n'}"
      _CC_FENCE_OWN_COMMON="${out%%$'\n'*}"; _CC_FENCE_OWN_GITDIR="${out#*$'\n'}"
      _CC_FENCE_OWN=yes
    fi
  fi
  [ "$_CC_FENCE_OWN" = yes ]
}

# Is path $1 (relative to the cwd $2) in a sibling worktree of the cwd's? 0 + CC_FENCE_TOP, the
# sibling's toplevel. $3 = gitdir when $1 is a git dir (--git-dir, GIT_DIR): then it is a
# sibling's when git calls it another git dir of the same repo.
cc_fence_sibling() {
  local p="$1" cwd="$2" kind="${3:-tree}" out common where
  CC_FENCE_TOP=""
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
  cc_fence_cheap_own "$p" "$cwd" && return 1
  _cc_fence_own "$cwd" || return 1
  if [ "$kind" = gitdir ]; then
    out="$(git --git-dir="$p" rev-parse --path-format=absolute --git-common-dir --git-dir 2>/dev/null)" || return 1
    common="${out%%$'\n'*}"; where="${out#*$'\n'}"
    { [ "$common" = "$_CC_FENCE_OWN_COMMON" ] && [ "$where" != "$_CC_FENCE_OWN_GITDIR" ]; } || return 1
  else
    while [ -n "$p" ] && [ ! -d "$p" ]; do p="${p%/*}"; done
    out="$(git -C "${p:-/}" rev-parse --path-format=absolute --git-common-dir --show-toplevel 2>/dev/null)" || return 1
    common="${out%%$'\n'*}"; where="${out#*$'\n'}"
    { [ "$common" = "$_CC_FENCE_OWN_COMMON" ] && [ "$where" != "$_CC_FENCE_OWN_TOP" ]; } || return 1
  fi
  CC_FENCE_TOP="$where"
}

cc_fence_main() {   # is the sibling cc_fence_sibling just found the main checkout (or its git dir)?
  [ "$CC_FENCE_TOP" = "$_CC_FENCE_OWN_COMMON" ] || [ "$CC_FENCE_TOP/.git" = "$_CC_FENCE_OWN_COMMON" ]
}

# Is branch $2 this session's own merge, approved by Adam? $1 = its key. The request cc-merge.sh
# wrote (CC_MERGE_DIR/<key>.json) must be approved, for this branch, from this worktree and repo.
cc_fence_merge_ok() {
  local f="$CC_MERGE_DIR/$1.json"
  { [ -n "$2" ] && [ -f "$f" ] && _cc_fence_own "${CWD:-$PWD}"; } || return 1
  [ "$(jq -r --arg b "$2" --arg w "$_CC_FENCE_OWN_TOP" --arg c "$_CC_FENCE_OWN_COMMON" \
    'if .phase == "approved" and .branch == $b and .worktree == $w and .commonDir == $c then "yes" else "no" end' \
    "$f" 2>/dev/null)" = yes ]
}

# What a Bash command changes, and where. $1 = the command, $2 = the cwd. Fills CC_FENCE_T with
# kind US path US branch: kind tree is a folder a mutating git runs in (-C, cd) or its
# --work-tree, or a redirection's file; kind gitdir is a mutating git's --git-dir / GIT_DIR.
# branch is set when the git command is exactly merge --ff-only <branch>. The same parse as
# cc_always_ask_match (_cc_sh_scan); a cd holds for the rest of the line, even out of a (...).
cc_fence_targets() {
  CC_FENCE_T=()
  _cc_fence_text "$1" "$2" 0
}

_cc_fence_text() {   # $1 shell text, $2 the folder it starts in ("": can't tell), $3 nesting depth
  local dir="$2" depth="$3" k j o
  local -a cmds=() outs=() outat=() stack=()
  [ "$depth" -le 6 ] || return 0
  _CC_SC_CMD=(); _CC_SC_IN=(); _CC_SC_BAD=""; _CC_SC_OUT=""; _CC_SC_OUTAT=()
  _cc_sh_scan "$1" top 0
  [ ${#_CC_SC_CMD[@]} -eq 0 ] || cmds=("${_CC_SC_CMD[@]}")
  if [ -n "$_CC_SC_OUT" ]; then
    [ ${#_CC_SC_OUTAT[@]} -eq 0 ] || outat=("${_CC_SC_OUTAT[@]}")
    while IFS= read -r o; do outs+=("$o"); done <<< "${_CC_SC_OUT%$'\n'}"
  fi
  for k in ${cmds[@]+"${!cmds[@]}"}; do
    for j in ${outat[@]+"${!outat[@]}"}; do          # the files this command's redirections write
      [ "${outat[j]}" = "$k" ] || continue
      _cc_fence_join "$dir" "${outs[j]:-}" && CC_FENCE_T+=("tree$_CC_AA_US$_CC_FENCE_J$_CC_AA_US")
    done
    _cc_aa_words "${cmds[k]}"
    _cc_fence_cmd "$depth" ${_CC_AA_W[@]+"${_CC_AA_W[@]}"}
  done
}

_cc_fence_join() {   # path $2 from folder $1 ("": can't tell) -> _CC_FENCE_J; 1 when it can't be told
  case "$2" in
    '') return 1 ;;
    /*) _CC_FENCE_J="$2" ;;
    '~') _CC_FENCE_J="$HOME" ;;
    '~/'*) _CC_FENCE_J="$HOME/${2:2}" ;;
    '~'*) return 1 ;;                                # ~user
    *) [ -n "$1" ] || return 1; _CC_FENCE_J="${1%/}/$2" ;;
  esac
}

# One simple command: follow cd / pushd / popd (the caller's dir and stack) and record what a
# mutating git changes. $1 depth, then its words. Looks through keywords, NAME=value prefixes and
# wrappers to the command that runs.
_cc_fence_cmd() {
  local depth="$1" x k=0 n base at gd="" wt="" hasc j joined
  local -a w=() d=()
  shift
  for x in "$@"; do
    case "$x" in
      "$_CC_AA_DYN"*) w+=("${x#"$_CC_AA_DYN"}"); d+=(1) ;;
      *) w+=("$x"); d+=(0) ;;
    esac
  done
  n=${#w[@]}
  at="$dir"                                          # env -C moves this one command only
  while :; do
    while [ "$k" -lt "$n" ]; do
      case "${w[k]}" in '!'|'{'|'}'|then|do|else|elif|if|while|until|fi|done|esac) k=$((k + 1)); continue ;; esac
      if [[ ${w[k]} =~ $_CC_AA_ASSIGN_RE ]]; then
        case "${w[k]}" in
          GIT_DIR=*) gd="${w[k]#*=}"; [ "${d[k]}" = 0 ] || gd="" ;;
          GIT_WORK_TREE=*) wt="${w[k]#*=}"; [ "${d[k]}" = 0 ] || wt="" ;;
        esac
        k=$((k + 1)); continue
      fi
      break
    done
    [ "$k" -lt "$n" ] || return 0
    [ "${d[k]}" = 0 ] || return 0                      # $CMD: can't tell what runs
    base="${w[k]##*/}"
    case "$base" in
      sudo|doas) k=$((k + 1)); _cc_aa_opts '-u -g -C -D -h -p -r -t -T -U' ;;
      env)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            -C|--chdir)
              if [ "${d[k+1]:-1}" = 0 ] && _cc_fence_join "$at" "${w[k+1]}"; then at="$_CC_FENCE_J"; else at=""; fi
              k=$((k + 2)) ;;
            --chdir=*)
              if [ "${d[k]}" = 0 ] && _cc_fence_join "$at" "${w[k]#*=}"; then at="$_CC_FENCE_J"; else at=""; fi
              k=$((k + 1)) ;;
            -S|--split-string)
              [ "${d[k+1]:-1}" = 0 ] && _cc_fence_text "${w[k+1]}" "$at" $((depth + 1))
              return 0 ;;
            -u|--unset) k=$((k + 2)) ;;
            --) k=$((k + 1)); break ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      time) k=$((k + 1)); _cc_aa_opts '-f -o' ;;
      nohup|builtin|exec) k=$((k + 1)); [ "${w[k]:-}" = -- ] && k=$((k + 1)) ;;
      nice) k=$((k + 1)); _cc_aa_opts '-n' ;;
      caffeinate) k=$((k + 1)); _cc_aa_opts '-t -w' ;;
      timeout) k=$((k + 1)); _cc_aa_opts '-s -k --signal --kill-after'; k=$((k + 1)) ;;
      command)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            -*v*|-*V*) return 0 ;;                     # command -v: a lookup, nothing runs
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      xargs)
        k=$((k + 1))
        _cc_aa_opts '-I -L -n -P -s -E -d -a --max-args --max-procs --max-lines --delimiter --arg-file --replace --eof' ;;
      sh|bash|zsh|dash|ksh)
        k=$((k + 1)); hasc=0
        while [ "$k" -lt "$n" ]; do
          case "${w[k]}" in
            --) k=$((k + 1)); break ;;
            --rcfile|--init-file) k=$((k + 2)) ;;
            --*) k=$((k + 1)) ;;
            -*c*) hasc=1; k=$((k + 1)) ;;
            -*o|+*o|-O|+O) k=$((k + 2)) ;;
            -*|+*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        [ "$hasc" = 1 ] && [ "$k" -lt "$n" ] && [ "${d[k]}" = 0 ] && _cc_fence_text "${w[k]}" "$at" $((depth + 1))
        return 0 ;;
      eval)
        joined=""; j=$((k + 1))
        while [ "$j" -lt "$n" ]; do
          [ "${d[j]}" = 0 ] || return 0
          joined="$joined ${w[j]}"; j=$((j + 1))
        done
        _cc_fence_text "$joined" "$at" $((depth + 1))
        return 0 ;;
      cd|pushd)
        j=$((k + 1))
        while [ "$j" -lt "$n" ]; do
          case "${w[j]}" in --) j=$((j + 1)); break ;; -[LPe@n]|-LP|-PL) j=$((j + 1)) ;; *) break ;; esac
        done
        [ "$base" = pushd ] && stack+=("$dir")
        if [ "$j" -ge "$n" ]; then dir="$HOME"
        elif [ "${d[j]}" = 0 ] && [ "${w[j]}" != - ] && _cc_fence_join "$dir" "${w[j]}"; then dir="$_CC_FENCE_J"
        else dir=""; fi                                # cd $X, cd -: can't tell from here on
        return 0 ;;
      popd)
        if [ ${#stack[@]} -gt 0 ]; then
          dir="${stack[${#stack[@]}-1]}"; unset "stack[${#stack[@]}-1]"
        else dir=""; fi
        return 0 ;;
      git) _cc_fence_git; return 0 ;;
      *) return 0 ;;
    esac
  done
}

# A git command at w[k] (on _cc_fence_cmd's locals): record the worktree and git dir it changes,
# unless it only reads. -c is left out of the read-only judgement: it can't aim git elsewhere.
_cc_fence_git() {
  local j=$((k + 1)) x sub si br="" ff=0 pos=0
  local -a rw=(git)
  while [ "$j" -lt "$n" ]; do                        # git's own options come first
    x="${w[j]}"
    case "$x" in
      -C) if [ "${d[j+1]:-1}" = 0 ] && _cc_fence_join "$at" "${w[j+1]}"; then at="$_CC_FENCE_J"; else at=""; fi
          j=$((j + 2)); continue ;;
      --git-dir|--work-tree)
          if [ "${d[j+1]:-1}" = 0 ]; then x="${w[j+1]}"; else x=""; fi
          if [ "${w[j]}" = --git-dir ]; then gd="$x"; else wt="$x"; fi
          j=$((j + 2)); continue ;;
      --git-dir=*) gd="${x#*=}"; [ "${d[j]}" = 0 ] || gd="" ;;
      --work-tree=*) wt="${x#*=}"; [ "${d[j]}" = 0 ] || wt="" ;;
      -c|--config-env|--namespace|--super-prefix) j=$((j + 2)); continue ;;
      --config-env=*|--exec-path=*) ;;
      -*) rw+=("$x") ;;
      *) break ;;
    esac
    j=$((j + 1))
  done
  [ "$j" -lt "$n" ] || return 0                      # git --version
  sub="${w[j]}"; si=$(( ${#rw[@]} + 1 ))              # where its arguments start in rw
  while [ "$j" -lt "$n" ]; do
    if [ "${d[j]}" = 1 ]; then rw+=("$_CC_AA_DYN${w[j]}"); else rw+=("${w[j]}"); fi
    j=$((j + 1))
  done
  _cc_fence_ro "${rw[@]}" && return 0
  if [ "$sub" = merge ]; then                        # merge --ff-only <branch>, and nothing else
    for x in "${rw[@]:si}"; do
      case "$x" in
        --ff-only) ff=$((ff + 1)) ;;
        -*|"$_CC_AA_DYN"*) ff=9 ;;
        *) br="$x"; pos=$((pos + 1)) ;;
      esac
    done
    { [ "$ff" = 1 ] && [ "$pos" = 1 ]; } || br=""
  fi
  if [ -n "$wt" ]; then
    _cc_fence_join "$at" "$wt" && CC_FENCE_T+=("tree$_CC_AA_US$_CC_FENCE_J$_CC_AA_US$br")
  elif [ -n "$at" ]; then
    CC_FENCE_T+=("tree$_CC_AA_US$at$_CC_AA_US$br")
  fi
  if [ -n "$gd" ]; then
    _cc_fence_join "$at" "$gd" && CC_FENCE_T+=("gitdir$_CC_AA_US$_CC_FENCE_J$_CC_AA_US$br")
  fi
  return 0
}

_cc_fence_ro() {   # read-only git? $@ = its words (git first), DYN marking an expansion
  local k=0 n x
  local -a w=() d=()
  for x in "$@"; do
    case "$x" in
      "$_CC_AA_DYN"*) w+=("${x#"$_CC_AA_DYN"}"); d+=(1) ;;
      *) w+=("$x"); d+=(0) ;;
    esac
  done
  n=${#w[@]}
  _cc_ro_git
}
