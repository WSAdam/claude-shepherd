#!/usr/bin/env bash
# editor.test.sh - cc-status.sh detects the host editor and captures
# permission_mode / effort / kitty handles from the inherited env. Writes only to
# a throwaway CC_STATUS_DIR. Uses `env -i` so the HOST's env can't leak into the
# detection (this machine itself sets CLAUDE_CODE_ENTRYPOINT, etc.).

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
CC="$ROOT/cc-status.sh"

# run <event> <json> [VAR=val ...] - clean env + only the vars we pass.
run() {
  local ev="$1" json="$2"; shift 2
  env -i HOME="$HOME" PATH="$PATH" CC_STATUS_DIR="$TMP" "$@" \
    bash "$CC" "$ev" <<<"$json" >/dev/null 2>&1
}

# VS Code extension
F="$TMP/vsc.json"
run sessionstart '{"session_id":"vsc","cwd":"/U/x/proj-a"}' \
  CLAUDE_CODE_ENTRYPOINT=claude-vscode __CFBundleIdentifier=com.microsoft.VSCode
assert_json "vscode entrypoint -> editor=vscode" "$F" '.editor' "vscode"

# Cursor (todesktop bundle)
F="$TMP/cur.json"
run sessionstart '{"session_id":"cur","cwd":"/U/x/proj-c"}' \
  __CFBundleIdentifier=com.todesktop.230313mzl4w4u92
assert_json "cursor bundle -> editor=cursor" "$F" '.editor' "cursor"

# Kitty terminal + permission_mode (stdin) + effort + kitty handles (env)
F="$TMP/kit.json"
run userpromptsubmit '{"session_id":"kit","cwd":"/U/x/proj-k","permission_mode":"plan","prompt_text":"hi"}' \
  CLAUDE_CODE_ENTRYPOINT=cli TERM=xterm-kitty KITTY_WINDOW_ID=7 \
  KITTY_LISTEN_ON=unix:/tmp/mykitty CLAUDE_EFFORT=high
assert_json "kitty env -> editor=kitty"        "$F" '.editor' "kitty"
assert_json "kitty window id captured"          "$F" '.kitty_window_id' "7"
assert_json "kitty listen socket captured"      "$F" '.kitty_listen_on' "unix:/tmp/mykitty"
assert_json "permission_mode captured (stdin)"  "$F" '.permission_mode' "plan"
assert_json "effort captured (env)"             "$F" '.effort' "high"

# plain (non-kitty) CLI terminal
F="$TMP/term.json"
run sessionstart '{"session_id":"term","cwd":"/U/x/proj-t"}' \
  CLAUDE_CODE_ENTRYPOINT=cli TERM=xterm-256color
assert_json "cli non-kitty -> editor=terminal" "$F" '.editor' "terminal"

# no signals at all -> safe default vscode (non-breaking)
F="$TMP/def.json"
run sessionstart '{"session_id":"def","cwd":"/U/x/proj-d"}'
assert_json "no signals -> default vscode" "$F" '.editor' "vscode"

finish
