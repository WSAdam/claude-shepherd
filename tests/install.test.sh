#!/usr/bin/env bash
# install.test.sh - exercise install.sh against a temp HOME-like layout: files
# copied, hooks merged (with a backup) preserving the user's own hooks, the
# init.lua dofile added, and a re-run is a no-op. CC_INSTALL_NO_APP=1 keeps it
# hermetic (no Shepherd.app built into ~/Applications).

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

exists() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -e "$2" ]; then echo "ok   - $1"
  else TESTS_FAIL=$((TESTS_FAIL + 1)); echo "FAIL - $1 (missing $2)"; fi
}

# --- fresh install (no prior settings.json) ---
CDIR="$TMP/claude"; HSDIR="$TMP/hs"
CC_INSTALL_CLAUDE_DIR="$CDIR" CC_INSTALL_HS_DIR="$HSDIR" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1

exists "copies cc-lib.sh -> claude dir"     "$CDIR/cc-lib.sh"
exists "copies cc-approve.sh -> claude dir" "$CDIR/cc-approve.sh"
exists "copies cc-core.lua -> claude dir"   "$CDIR/cc-core.lua"
exists "copies dashboard -> hs dir"         "$HSDIR/claude-dashboard.lua"
exists "writes settings.json"               "$CDIR/settings.json"
assert_json "settings has our Stop hook" "$CDIR/settings.json" \
  '.hooks.Stop[0].hooks[0].command | contains("cc-status.sh")' "true"
# The status update MUST be the FIRST command in the approval hooks, so the tile flips
# to "Needs you" immediately -- not blocked behind a slower popup / desktop notification /
# network push (which is exactly what left a session showing "Working" at a live prompt).
assert_json "PermissionRequest runs cc-status FIRST" "$CDIR/settings.json" \
  '.hooks.PermissionRequest[0].hooks[0].command | contains("cc-status.sh")' "true"
assert_json "Notification runs cc-status FIRST" "$CDIR/settings.json" \
  '.hooks.Notification[0].hooks[0].command | contains("cc-status.sh")' "true"
# The cc-approve.sh entry MUST carry a timeout above the gate's 120s poll, or
# Claude Code kills the hook at its 60s default mid-wait (panel clicks in the
# 60-120s window would then dead-end on a decision file nothing consumes).
assert_json "cc-approve.sh hook carries a 130s timeout" "$CDIR/settings.json" \
  '.hooks.PreToolUse[0].hooks[] | select(.command | contains("cc-approve.sh")) | .timeout' "130"
exists "creates init.lua" "$HSDIR/init.lua"
assert_eq "init.lua has the dofile" "1" "$(grep -c 'claude-dashboard.lua' "$HSDIR/init.lua")"

# --- re-run is a no-op ---
before="$(cat "$CDIR/settings.json")"
CC_INSTALL_CLAUDE_DIR="$CDIR" CC_INSTALL_HS_DIR="$HSDIR" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "re-run: dofile not duplicated" "1" "$(grep -c 'claude-dashboard.lua' "$HSDIR/init.lua")"
assert_eq "re-run: settings unchanged" "$before" "$(cat "$CDIR/settings.json")"

# --- merge into an existing settings.json carrying the user's own hook ---
CDIR2="$TMP/claude2"; HSDIR2="$TMP/hs2"; mkdir -p "$CDIR2"
cat > "$CDIR2/settings.json" <<'JSON'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR2" CC_INSTALL_HS_DIR="$HSDIR2" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "merge preserves user key"      "$CDIR2/settings.json" '.model' "opus"
assert_json "merge keeps user's Stop hook"  "$CDIR2/settings.json" '.hooks.Stop[0].hooks[0].command' "echo mine"
assert_json "merge appends our Stop hook"   "$CDIR2/settings.json" \
  '[.hooks.Stop[].hooks[].command] | any(contains("cc-status.sh"))' "true"
exists "merge made a backup" "$(ls "$CDIR2"/settings.json.bak.* 2>/dev/null | head -1)"

# --- F-005: a user's OWN cc-prefixed hook (cc-notify.sh) on a wired event must NOT
# suppress wiring ours. Regression-tests install.sh's jq mirror of OUR_HOOK_SCRIPTS,
# which the core.test.lua mergeHooks cases can't reach. ---
CDIR3="$TMP/claude3"; HSDIR3="$TMP/hs3"; mkdir -p "$CDIR3"
cat > "$CDIR3/settings.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash $HOME/.claude/cc-notify.sh" } ] } ] } }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR3" CC_INSTALL_HS_DIR="$HSDIR3" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "F-005: user's cc-notify.sh keeps its Stop hook" "$CDIR3/settings.json" \
  '[.hooks.Stop[].hooks[].command] | any(contains("cc-notify.sh"))' "true"
assert_json "F-005: ours still appended past the user's cc-* hook" "$CDIR3/settings.json" \
  '[.hooks.Stop[].hooks[].command] | any(contains("cc-status.sh"))' "true"
assert_json "F-005: Stop now has 2 groups (user + ours)" "$CDIR3/settings.json" \
  '.hooks.Stop | length' "2"
before3="$(cat "$CDIR3/settings.json")"
CC_INSTALL_CLAUDE_DIR="$CDIR3" CC_INSTALL_HS_DIR="$HSDIR3" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "F-005: re-run with ours present is a no-op" "$before3" "$(cat "$CDIR3/settings.json")"

# F-005 false positive (DOCUMENTED + accepted): the match is an UNANCHORED substring, so
# a user hook whose basename ENDS in cc-status.sh (my-cc-status.sh) is mistaken for ours
# and SUPPRESSES wiring for that event. Pin today's behavior -- if the regex is ever
# anchored, this assertion flips, forcing a doc update (see OUR_HOOK_SCRIPTS in cc-core.lua).
CDIR4="$TMP/claude4"; HSDIR4="$TMP/hs4"; mkdir -p "$CDIR4"
cat > "$CDIR4/settings.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash $HOME/.claude/my-cc-status.sh" } ] } ] } }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR4" CC_INSTALL_HS_DIR="$HSDIR4" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "F-005 fp: my-cc-status.sh suppresses ours (Stop stays 1 group)" "$CDIR4/settings.json" \
  '.hooks.Stop | length' "1"
assert_json "F-005 fp: the user's my-cc-status.sh hook is intact" "$CDIR4/settings.json" \
  '.hooks.Stop[0].hooks[0].command | contains("my-cc-status.sh")' "true"
# Directly pin "ours was NOT wired" (catches ours sneaking in as a 2nd hook inside the
# existing group, which the group-count assert above would miss). Use the leading-slash
# form: our command is `bash "$HOME/.claude/cc-status.sh" ...` (contains "/cc-status.sh"),
# while the user's ".../my-cc-status.sh" does NOT -- so a bare contains("cc-status.sh")
# would be a tautology here.
assert_json "F-005 fp: ours (/cc-status.sh) was NOT wired" "$CDIR4/settings.json" \
  '[.hooks.Stop[].hooks[].command | select(contains("/cc-status.sh"))] | length' "0"

# --- timeout migration: an EXISTING install whose cc-approve.sh entry predates the
# timeout field gets it patched in place (the append-if-missing merge alone would
# skip PreToolUse because our scripts are already wired). ---
CDIR5="$TMP/claude5"; HSDIR5="$TMP/hs5"; mkdir -p "$CDIR5"
cat > "$CDIR5/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" pretooluse" },
  { "type": "command", "command": "bash \"$HOME/.claude/cc-approve.sh\"" } ] } ] } }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR5" CC_INSTALL_HS_DIR="$HSDIR5" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "migration: existing cc-approve.sh entry gains timeout 130" "$CDIR5/settings.json" \
  '.hooks.PreToolUse[0].hooks[1].timeout' "130"
assert_json "migration: PreToolUse group not duplicated" "$CDIR5/settings.json" \
  '.hooks.PreToolUse | length' "1"
assert_json "migration: cc-status.sh entry untouched (no timeout)" "$CDIR5/settings.json" \
  '.hooks.PreToolUse[0].hooks[0] | has("timeout")' "false"
before5="$(cat "$CDIR5/settings.json")"
CC_INSTALL_CLAUDE_DIR="$CDIR5" CC_INSTALL_HS_DIR="$HSDIR5" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "migration: re-run is a no-op" "$before5" "$(cat "$CDIR5/settings.json")"

# --- the migration pass visits EVERY hooks event, so it must be SHAPE-PRESERVING
# for events the installer doesn't own: a foreign event carrying a stray
# non-object element + a foreign object entry, and an object-valued (hand-edited)
# event group, must round-trip untouched. The old pass silently DROPPED the
# stray element and reshaped object-valued groups into arrays. ---
CDIR7="$TMP/claude7"; HSDIR7="$TMP/hs7"; mkdir -p "$CDIR7"
cat > "$CDIR7/settings.json" <<'JSON'
{ "hooks": {
    "PreCompact": [ { "hooks": [ { "type": "command", "command": "echo hi" } ] },
                    "stray-note",
                    { "matcher": "x", "note": "foreign object, no hooks array" } ],
    "SubagentStop": { "matcher": "", "hooks": [ { "type": "command", "command": "echo obj" } ] }
} }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR7" CC_INSTALL_HS_DIR="$HSDIR7" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "shape: PreCompact keeps all 3 elements" "$CDIR7/settings.json" \
  '.hooks.PreCompact | length' "3"
assert_json "shape: stray non-object element survives" "$CDIR7/settings.json" \
  '.hooks.PreCompact[1]' "stray-note"
assert_json "shape: foreign object entry untouched" "$CDIR7/settings.json" \
  '.hooks.PreCompact[2].note' "foreign object, no hooks array"
assert_json "shape: object-valued event group stays an object" "$CDIR7/settings.json" \
  '.hooks.SubagentStop | type' "object"
assert_json "shape: object-valued group content intact" "$CDIR7/settings.json" \
  '.hooks.SubagentStop.hooks[0].command' "echo obj"
# ...while the normal merge still wired our hooks alongside the foreign events
assert_json "shape: our hooks still merged next to foreign events" "$CDIR7/settings.json" \
  '[.hooks.PreToolUse[].hooks[]?.command? // empty] | any(test("cc-approve\\.sh"))' "true"

# --- appending to a pre-existing init.lua WITHOUT a trailing newline must not glue
# the dofile onto the user's last line (invalid Lua that breaks their whole config). ---
CDIR6="$TMP/claude6"; HSDIR6="$TMP/hs6"; mkdir -p "$HSDIR6"
printf 'local x = 1' > "$HSDIR6/init.lua"   # no trailing \n
CC_INSTALL_CLAUDE_DIR="$CDIR6" CC_INSTALL_HS_DIR="$HSDIR6" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "newline-less init.lua: user's line intact" "local x = 1" "$(head -n 1 "$HSDIR6/init.lua")"
assert_eq "newline-less init.lua: dofile on its OWN line" "1" \
  "$(grep -Fxc 'dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")' "$HSDIR6/init.lua")"

# --- #19: an event group that already carries SOME of our scripts must still gain
# a newly-shipped sibling hook. Installs from the dc92a23/e4efe32 era wired
# Stop/Notification/PermissionRequest with only cc-status.sh (cc-popup.sh did not
# exist yet); the old merge skipped the whole template group whenever ANY of our
# scripts was present, leaving cc-popup unwired forever. The upgrade must append
# just the missing entries into the group we already own (matcher preserved),
# stay idempotent, and never duplicate what's already wired. ---
CDIR8="$TMP/claude8"; HSDIR8="$TMP/hs8"; mkdir -p "$CDIR8"
cat > "$CDIR8/settings.json" <<'JSON'
{ "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" stop" } ] } ],
    "Notification": [ { "matcher": "", "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" notification" } ] } ],
    "PermissionRequest": [ { "matcher": "", "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" permissionrequest" } ] } ],
    "PreToolUse": [ { "matcher": "", "hooks": [
      { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" pretooluse" },
      { "type": "command", "command": "bash \"$HOME/.claude/cc-approve.sh\"", "timeout": 130 } ] } ]
} }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR8" CC_INSTALL_HS_DIR="$HSDIR8" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "#19: old-era install gains the 3 cc-popup wirings" "3" \
  "$(grep -c 'cc-popup' "$CDIR8/settings.json")"
assert_json "#19: Stop gains cc-popup" "$CDIR8/settings.json" \
  '[.hooks.Stop[].hooks[].command] | any(contains("cc-popup.sh"))' "true"
assert_json "#19: Notification gains cc-popup" "$CDIR8/settings.json" \
  '[.hooks.Notification[].hooks[].command] | any(contains("cc-popup.sh"))' "true"
assert_json "#19: PermissionRequest gains cc-popup" "$CDIR8/settings.json" \
  '[.hooks.PermissionRequest[].hooks[].command] | any(contains("cc-popup.sh"))' "true"
# appended INTO the group we own, not as a duplicate group
assert_json "#19: Stop stays one group" "$CDIR8/settings.json" '.hooks.Stop | length' "1"
assert_json "#19: PermissionRequest stays one group" "$CDIR8/settings.json" \
  '.hooks.PermissionRequest | length' "1"
assert_json "#19: the owned group's matcher is preserved" "$CDIR8/settings.json" \
  '.hooks.PermissionRequest[0].matcher' ""
# the already-wired entries were not duplicated
assert_json "#19: cc-status not duplicated in Stop" "$CDIR8/settings.json" \
  '[.hooks.Stop[].hooks[].command | select(contains("cc-status.sh"))] | length' "1"
assert_json "#19: PreToolUse (fully wired) untouched" "$CDIR8/settings.json" \
  '.hooks.PreToolUse[0].hooks | length' "2"
# events absent from the old install are still added wholesale
assert_json "#19: missing events still merged (SessionStart)" "$CDIR8/settings.json" \
  '[.hooks.SessionStart[].hooks[].command] | any(contains("cc-status.sh"))' "true"
before8="$(cat "$CDIR8/settings.json")"
CC_INSTALL_CLAUDE_DIR="$CDIR8" CC_INSTALL_HS_DIR="$HSDIR8" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "#19: re-run is a no-op (no duplicate popup entries)" "$before8" "$(cat "$CDIR8/settings.json")"
# a user's own group on the same event is untouched; ours receives the append
CDIR9="$TMP/claude9"; HSDIR9="$TMP/hs9"; mkdir -p "$CDIR9"
cat > "$CDIR9/settings.json" <<'JSON'
{ "hooks": { "Stop": [
    { "hooks": [ { "type": "command", "command": "echo mine" } ] },
    { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" stop" } ] }
] } }
JSON
CC_INSTALL_CLAUDE_DIR="$CDIR9" CC_INSTALL_HS_DIR="$HSDIR9" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "#19: user's own group untouched by the per-entry upgrade" "$CDIR9/settings.json" \
  '.hooks.Stop[0].hooks | length' "1"
assert_json "#19: cc-popup lands in OUR group, not the user's" "$CDIR9/settings.json" \
  '[.hooks.Stop[1].hooks[].command] | any(contains("cc-popup.sh"))' "true"

# --- #21: installs must replace files by same-dir rename (new inode), never an
# in-place cp/redirect truncate -- a hook process mid-execution (a cc-approve.sh
# waiter blocked in its 120s poll) keeps reading its old inode instead of garbled
# new bytes. Pin: the destination inode CHANGES across a re-install, content is
# intact, exec bits survive, and no dot-temps are left behind. ---
ino_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
ino_app_before="$(ino_of "$CDIR/cc-approve.sh")"
ino_dash_before="$(ino_of "$HSDIR/claude-dashboard.lua")"
CC_INSTALL_CLAUDE_DIR="$CDIR" CC_INSTALL_HS_DIR="$HSDIR" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "#21: hook script re-installed onto a NEW inode (rename, not truncate)" "changed" \
  "$([ -n "$ino_app_before" ] && [ "$(ino_of "$CDIR/cc-approve.sh")" != "$ino_app_before" ] && echo changed)"
assert_eq "#21: dashboard re-installed onto a NEW inode" "changed" \
  "$([ -n "$ino_dash_before" ] && [ "$(ino_of "$HSDIR/claude-dashboard.lua")" != "$ino_dash_before" ] && echo changed)"
assert_eq "#21: re-installed script content intact" "same" \
  "$(cmp -s "$ROOT/cc-approve.sh" "$CDIR/cc-approve.sh" && echo same)"
assert_eq "#21: exec bit preserved across the rename install" "exec" \
  "$([ -x "$CDIR/cc-approve.sh" ] && echo exec)"
assert_eq "#21: no dot-temp files left in the claude dir" "0" \
  "$(find "$CDIR" -name '.*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "#21: no dot-temp files left in the hs dir" "0" \
  "$(find "$HSDIR" -name '.*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
# the settings.json rewrite (CDIR8 went through a real merge) is temp+rename too:
# no .settings.json.tmp.* scratch left behind, and the merged file is valid JSON
assert_eq "#21: no settings.json temp left after a real merge" "0" \
  "$(find "$CDIR8" -name '.settings.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "#21: merged settings.json is valid JSON" "0" \
  "$(jq -e . "$CDIR8/settings.json" >/dev/null 2>&1; echo $?)"

# --- tooling check (`install.sh --tools-only`, powers `make doctor`): reports status,
# is NON-INTERACTIVE without a tty (never blocks tests/`make setup`), offers (prints) the
# brew command for a missing optional accelerator, and NEVER hard-fails. Simulate
# "brew present, fd missing" with a controlled PATH of symlinks (jq/rg/brew, no fd). ---
TOOLDIR="$TMP/tools"; mkdir -p "$TOOLDIR"
for b in jq rg brew; do src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$TOOLDIR/$b"; done
# fd intentionally absent (and not a system tool, so /usr/bin:/bin won't supply it)
TOUT="$TMP/tools.out"
PATH="$TOOLDIR:/usr/bin:/bin" bash "$ROOT/install.sh" --tools-only </dev/null >"$TOUT" 2>&1
assert_eq "tools-only: exits 0 (a missing optional never hard-fails)" "0" "$?"
assert_eq "tools-only: prints the tooling header" "1" "$(grep -Fc 'Tooling check' "$TOUT")"
assert_eq "tools-only: jq reported present with its path" "1" "$(grep -Fc "$TOOLDIR/jq" "$TOUT")"
assert_eq "tools-only: rg reported present with its path" "1" "$(grep -Fc "$TOOLDIR/rg" "$TOUT")"
assert_eq "tools-only: fd reported missing (degrades to find)" "1" "$(grep -Fc 'degrades to find' "$TOUT")"
assert_eq "tools-only: non-interactive -> prints 'brew install fd' (no prompt, no hang)" "1" "$(grep -Fc 'brew install fd' "$TOUT")"
assert_eq "tools-only: did NOT run the prompt text" "0" "$(grep -Fc 'install fd now with Homebrew' "$TOUT")"
# --tools-only exits before any copy/merge: a temp claude dir must NOT be created
assert_eq "tools-only: touches no config (early exit before copy)" "0" \
  "$([ -e "$TMP/tools-claude" ] && echo 1 || echo 0)"

finish
