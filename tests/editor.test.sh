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

# Kitty terminal + permission_mode (stdin) + effort + kitty handles + provider env
F="$TMP/kit.json"
run userpromptsubmit '{"session_id":"kit","cwd":"/U/x/proj-k","permission_mode":"plan","prompt_text":"hi"}' \
  CLAUDE_CODE_ENTRYPOINT=cli TERM=xterm-kitty KITTY_WINDOW_ID=7 \
  KITTY_LISTEN_ON=unix:/tmp/mykitty CLAUDE_EFFORT=high \
  ANTHROPIC_MODEL=gemini-2.5-pro ANTHROPIC_BASE_URL=http://localhost:4000
assert_json "kitty env -> editor=kitty"        "$F" '.editor' "kitty"
assert_json "kitty window id captured"          "$F" '.kitty_window_id' "7"
assert_json "kitty listen socket captured"      "$F" '.kitty_listen_on' "unix:/tmp/mykitty"
assert_json "permission_mode captured (stdin)"  "$F" '.permission_mode' "plan"
assert_json "effort captured (env)"             "$F" '.effort' "high"
assert_json "model captured (env)"              "$F" '.model' "gemini-2.5-pro"
assert_json "base_url captured (env)"           "$F" '.base_url' "http://localhost:4000"

# no provider env -> no model/base_url keys (default Anthropic, bare claude)
F="$TMP/nomodel.json"
run sessionstart '{"session_id":"nomodel","cwd":"/U/x/proj-n"}' CLAUDE_CODE_ENTRYPOINT=cli
assert_json "no provider env -> model absent"   "$F" '.model // "none"' "none"

# plain (non-kitty) CLI terminal
F="$TMP/term.json"
run sessionstart '{"session_id":"term","cwd":"/U/x/proj-t"}' \
  CLAUDE_CODE_ENTRYPOINT=cli TERM=xterm-256color
assert_json "cli non-kitty -> editor=terminal" "$F" '.editor' "terminal"

# no signals at all -> safe default vscode (non-breaking)
F="$TMP/def.json"
run sessionstart '{"session_id":"def","cwd":"/U/x/proj-d"}'
assert_json "no signals -> default vscode" "$F" '.editor' "vscode"

# --- #12: a VS Code/Cursor cold-started from a kitty shell (`code .`) inherits
# KITTY_WINDOW_ID/KITTY_LISTEN_ON/TERM, forging ONE kitty window's identity onto
# every session those editor windows host. The non-inheritable entrypoint
# (CLAUDE_CODE_ENTRYPOINT=claude-vscode, set by the extension itself) must win
# over the inherited kitty env, AND the forged kitty handles must NOT be recorded
# in the status file (they fed core.staleDuplicateKeys' termId: cross-window
# false prunes, a shared respawn budget, `kitty @` keystroke misrouting).
F="$TMP/vsk.json"
run sessionstart '{"session_id":"vsk","cwd":"/U/x/proj-vk"}' \
  CLAUDE_CODE_ENTRYPOINT=claude-vscode __CFBundleIdentifier=com.microsoft.VSCode \
  TERM=xterm-kitty KITTY_WINDOW_ID=9 KITTY_LISTEN_ON=unix:/tmp/mykitty
assert_json "#12: vscode-from-kitty -> editor=vscode"      "$F" '.editor' "vscode"
assert_json "#12: forged kitty window id NOT recorded"     "$F" '.kitty_window_id // "absent"' "absent"
assert_json "#12: forged kitty socket NOT recorded"        "$F" '.kitty_listen_on // "absent"' "absent"

# the bundle id still disambiguates Cursor inside the entrypoint branch
F="$TMP/cuk.json"
run sessionstart '{"session_id":"cuk","cwd":"/U/x/proj-ck"}' \
  CLAUDE_CODE_ENTRYPOINT=claude-vscode __CFBundleIdentifier=com.todesktop.230313mzl4w4u92 \
  TERM=xterm-kitty KITTY_WINDOW_ID=9 KITTY_LISTEN_ON=unix:/tmp/mykitty
assert_json "#12: cursor-from-kitty -> editor=cursor"      "$F" '.editor' "cursor"
assert_json "#12: cursor-from-kitty records no kitty id"   "$F" '.kitty_window_id // "absent"' "absent"

# a GENUINE kitty session (no extension entrypoint) still records both handles --
# the kitty test above pins the value; pin here that the #12 gate didn't break it
F="$TMP/gk.json"
run sessionstart '{"session_id":"gk","cwd":"/U/x/proj-gk"}' \
  CLAUDE_CODE_ENTRYPOINT=cli TERM=xterm-kitty KITTY_WINDOW_ID=4 KITTY_LISTEN_ON=unix:/tmp/k2
assert_json "#12: genuine kitty still records the window id" "$F" '.kitty_window_id' "4"
assert_json "#12: genuine kitty still records the socket"    "$F" '.kitty_listen_on' "unix:/tmp/k2"

finish
