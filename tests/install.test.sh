#!/usr/bin/env bash
# install.test.sh - exercise install.sh against a temp HOME-like layout: files
# copied, hooks merged (with a backup) preserving the user's own hooks, the
# init.lua dofile added, and a re-run is a no-op. CC_INSTALL_NO_APP=1 keeps it
# hermetic (no Shepherd.app built into ~/Applications).

. "$(dirname "$0")/lib.sh"

# Keep every install.sh call below hermetic and fast: without this the new pre-flight
# gate would re-enter `make test` -> run.sh -> this file -> install.sh, unbounded.
# The gate's own tests near the end clear it per-call to exercise the real thing.
export CC_INSTALL_SKIP_TESTS=1
# ...and never hand the companion extension to the real VS Code (bridge-build.test.sh
# covers packaging + install against a fake CLI).
export CC_INSTALL_NO_BRIDGE=1

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
# cc-ask.sh holds a question for Shepherd for up to 3600s (2026-09-11): its own group, so it
# runs for AskUserQuestion only, with a timeout above that wait.
assert_json "cc-ask.sh runs for AskUserQuestion only" "$CDIR/settings.json" \
  '[.hooks.PreToolUse[] | select(.hooks[].command | contains("cc-ask.sh")) | .matcher] | join(",")' "AskUserQuestion"
assert_json "cc-ask.sh carries a 3630s timeout" "$CDIR/settings.json" \
  '.hooks.PreToolUse[].hooks[] | select(.command | contains("cc-ask.sh")) | .timeout' "3630"
exists "copies cc-ask.sh -> claude dir" "$CDIR/cc-ask.sh"
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
# 2026-09-11 requirement change: the migration now also adds cc-ask.sh's own group, so
# PreToolUse holds 2 groups; the matcher-"" group itself is still never duplicated.
assert_json "migration: PreToolUse group not duplicated" "$CDIR5/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher == "")] | length' "1"
assert_json "migration: an older install gains cc-ask.sh in its own AskUserQuestion group" "$CDIR5/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[].command | contains("cc-ask.sh")] | length' "1"
assert_json "migration: ...and never in the every-tool group" "$CDIR5/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher == "") | .hooks[].command | select(contains("cc-ask.sh"))] | length' "0"
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
# "brew present, fd missing" with a controlled PATH: the real jq plus STUB rg/brew executables
# (the check only asks `command -v`; 2026-09-15: symlinking the host's rg/brew made this
# suite, and so `make setup`, fail on a machine without them). No fd. ---
TOOLDIR="$TMP/tools"; mkdir -p "$TOOLDIR"
ln -sf "$(command -v jq)" "$TOOLDIR/jq"
for b in rg brew; do printf '#!/bin/sh\nexit 0\n' > "$TOOLDIR/$b"; chmod +x "$TOOLDIR/$b"; done
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

# tools-only also reports lua and Hammerspoon.app. lua present (real PATH) vs absent
# (the controlled TOOLDIR above has no lua), and the app probe is a directory check
# redirected via CC_INSTALL_HAMMERSPOON_APP.
# 2026-09-15 requirement change: node is reported the same way, so each tool's line is
# counted on its own name rather than by the shared wording.
assert_eq "tools-only: lua reported missing when absent from PATH" "1" \
  "$(grep -Ec 'lua +MISSING \(required to run the tests\)' "$TOUT")"
assert_eq "tools-only: node reported missing when absent from PATH" "1" \
  "$(grep -Ec 'node +MISSING \(required to run the tests\)' "$TOUT")"
FAKEHS="$TMP/Hammerspoon.app"; mkdir -p "$FAKEHS"
HSOUT="$TMP/hs-present.out"
CC_INSTALL_HAMMERSPOON_APP="$FAKEHS" bash "$ROOT/install.sh" --tools-only </dev/null >"$HSOUT" 2>&1
assert_eq "tools-only: Hammerspoon.app reported present with its path" "1" "$(grep -Fc "$FAKEHS" "$HSOUT")"
HSOUT2="$TMP/hs-absent.out"
CC_INSTALL_HAMMERSPOON_APP="$TMP/nope.app" bash "$ROOT/install.sh" --tools-only </dev/null >"$HSOUT2" 2>&1
assert_eq "tools-only: Hammerspoon.app reported missing when absent" "1" \
  "$(grep -Fc 'Hammerspoon.app MISSING' "$HSOUT2")"
assert_eq "tools-only: still exits 0 with Hammerspoon missing (never hard-fails)" "0" "$?"

# --- pre-flight test gate: aborts BEFORE settings.json/init.lua when the suite is red,
# proceeds when green, and is bypassable. A fake `make` on a PATH-double stands in for
# the real suite (and touches a sentinel, so we can prove it was/wasn't invoked). ---
MAKEDIR="$TMP/fakemake"; mkdir -p "$MAKEDIR"
SENTINEL="$TMP/make-ran"
for b in lua node jq cp mv mkdir chmod date grep tail printf basename find; do
  src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$MAKEDIR/$b"
done
write_fake_make() {  # $1 = exit code
  cat > "$MAKEDIR/make" <<EOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit $1
EOF
  chmod +x "$MAKEDIR/make"
}

# gate aborts on a failing suite
write_fake_make 1; rm -f "$SENTINEL"
GCDIR="$TMP/gate-fail-claude"; GHDIR="$TMP/gate-fail-hs"
CC_INSTALL_SKIP_TESTS= CC_INSTALL_CLAUDE_DIR="$GCDIR" CC_INSTALL_HS_DIR="$GHDIR" CC_INSTALL_NO_APP=1 \
  PATH="$MAKEDIR:/usr/bin:/bin" bash "$ROOT/install.sh" >"$TMP/gate-fail.out" 2>&1
assert_eq "gate: a red suite exits nonzero" "1" "$?"
assert_eq "gate: prints the abort message" "1" "$(grep -Fc 'pre-flight tests failed' "$TMP/gate-fail.out")"
# 2026-09-15 requirement change: the copy ran BEFORE the gate, so a red suite still put the
# untested hook scripts where the already-wired hooks run them. A red suite now copies nothing.
assert_eq "gate: a red suite copies no hook scripts into the claude dir" "0" \
  "$([ -e "$GCDIR/cc-lib.sh" ] && echo 1 || echo 0)"
assert_eq "gate: a red suite copies no dashboard into the hammerspoon dir" "0" \
  "$([ -e "$GHDIR/claude-dashboard.lua" ] && echo 1 || echo 0)"
assert_eq "gate: settings.json NOT written" "0" "$([ -e "$GCDIR/settings.json" ] && echo 1 || echo 0)"
assert_eq "gate: init.lua dofile NOT added" "0" "$([ -e "$GHDIR/init.lua" ] && echo 1 || echo 0)"

# gate proceeds on a green suite
write_fake_make 0; rm -f "$SENTINEL"
GCDIR2="$TMP/gate-ok-claude"; GHDIR2="$TMP/gate-ok-hs"
CC_INSTALL_SKIP_TESTS= CC_INSTALL_CLAUDE_DIR="$GCDIR2" CC_INSTALL_HS_DIR="$GHDIR2" CC_INSTALL_NO_APP=1 \
  PATH="$MAKEDIR:/usr/bin:/bin" bash "$ROOT/install.sh" >"$TMP/gate-ok.out" 2>&1
assert_eq "gate: a green suite writes settings.json" "1" \
  "$([ -e "$GCDIR2/settings.json" ] && echo 1 || echo 0)"
assert_eq "gate: a green suite adds the init.lua dofile" "1" \
  "$(grep -Fc 'claude-dashboard.lua' "$GHDIR2/init.lua" 2>/dev/null || echo 0)"
assert_eq "gate: prints the pass message" "1" "$(grep -Fc 'pre-flight tests passed' "$TMP/gate-ok.out")"

# --skip-tests bypasses the gate entirely — `make` is never even invoked (sentinel absent)
write_fake_make 1; rm -f "$SENTINEL"
GCDIR3="$TMP/gate-skip-claude"; GHDIR3="$TMP/gate-skip-hs"
CC_INSTALL_SKIP_TESTS= CC_INSTALL_CLAUDE_DIR="$GCDIR3" CC_INSTALL_HS_DIR="$GHDIR3" CC_INSTALL_NO_APP=1 \
  PATH="$MAKEDIR:/usr/bin:/bin" bash "$ROOT/install.sh" --skip-tests >"$TMP/gate-skip.out" 2>&1
assert_eq "gate: --skip-tests installs despite a red suite" "1" \
  "$([ -e "$GCDIR3/settings.json" ] && echo 1 || echo 0)"
assert_eq "gate: --skip-tests never invokes make at all" "0" \
  "$([ -e "$SENTINEL" ] && echo 1 || echo 0)"
assert_eq "gate: --skip-tests prints the skip notice" "1" \
  "$(grep -Fc 'pre-flight tests skipped' "$TMP/gate-skip.out")"

# CC_INSTALL_SKIP_TESTS=1 is the env-var spelling of the same bypass
rm -f "$SENTINEL"
GCDIR4="$TMP/gate-env-claude"; GHDIR4="$TMP/gate-env-hs"
CC_INSTALL_SKIP_TESTS=1 CC_INSTALL_CLAUDE_DIR="$GCDIR4" CC_INSTALL_HS_DIR="$GHDIR4" CC_INSTALL_NO_APP=1 \
  PATH="$MAKEDIR:/usr/bin:/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "gate: CC_INSTALL_SKIP_TESTS=1 bypasses too" "1" \
  "$([ -e "$GCDIR4/settings.json" ] && echo 1 || echo 0)"
assert_eq "gate: env bypass never invokes make either" "0" \
  "$([ -e "$SENTINEL" ] && echo 1 || echo 0)"

# a missing `lua` aborts cleanly (cannot verify => do not touch config). Like the fd
# case above, lua is not a system tool, so /usr/bin:/bin can't supply it.
NOLUA="$TMP/nolua"; mkdir -p "$NOLUA"
for b in jq node make; do src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$NOLUA/$b"; done
GCDIR5="$TMP/gate-nolua-claude"; GHDIR5="$TMP/gate-nolua-hs"
CC_INSTALL_SKIP_TESTS= CC_INSTALL_CLAUDE_DIR="$GCDIR5" CC_INSTALL_HS_DIR="$GHDIR5" CC_INSTALL_NO_APP=1 \
  PATH="$NOLUA:/usr/bin:/bin" bash "$ROOT/install.sh" >"$TMP/gate-nolua.out" 2>&1
assert_eq "gate: missing lua exits nonzero" "1" "$?"
assert_eq "gate: missing lua prints 'cannot verify'" "1" \
  "$(grep -Fc 'cannot verify: lua not found' "$TMP/gate-nolua.out")"
assert_eq "gate: missing lua writes no settings.json" "0" \
  "$([ -e "$GCDIR5/settings.json" ] && echo 1 || echo 0)"

# ---- make install swaps scripts in with a rename (2026-09-11) ----
# `make install` used plain `cp`, which rewrites a script IN PLACE: bash reads a script lazily
# from its open fd, so a hook running at that moment (a gate waiter, a waiting merge request)
# resumed at its byte offset inside the NEW file. A rename leaves the running copy intact.
MCDIR="$TMP/make-claude"; MHDIR="$TMP/make-hs"; mkdir -p "$MCDIR" "$MHDIR"
printf 'old\n' > "$MCDIR/cc-approve.sh"; printf 'old\n' > "$MCDIR/cc-merge.sh"
exec 7< "$MCDIR/cc-approve.sh"       # a "running hook" holding the old file open
make -C "$ROOT" --no-print-directory install HS_DIR="$MHDIR" CLAUDE_DIR="$MCDIR" NO_TAB_BRIDGE=1 >/dev/null 2>&1
assert_eq "make install: exit 0" "0" "$?"
assert_eq "make install: a script already running keeps reading its own copy" "old" "$(cat <&7)"
exec 7<&-
cmp -s "$ROOT/cc-approve.sh" "$MCDIR/cc-approve.sh" && got=new || got=stale
assert_eq "make install: ...while the new copy is in place" "new" "$got"
cmp -s "$ROOT/cc-merge.sh" "$MCDIR/cc-merge.sh" && [ -x "$MCDIR/cc-merge.sh" ] && got=yes || got=no
assert_eq "make install: ships cc-merge.sh, executable" "yes" "$got"
ls -a "$MCDIR" | grep -q '\.tmp\.' && got=leftovers || got=clean
assert_eq "make install: leaves no temp files behind" "clean" "$got"
exists "install.sh: ships cc-merge.sh too" "$CDIR/cc-merge.sh"
exists "install.sh: ships cc-fleet.sh too" "$CDIR/cc-fleet.sh"
[ -x "$MCDIR/cc-ask.sh" ] && cmp -s "$ROOT/cc-ask.sh" "$MCDIR/cc-ask.sh" && got=yes || got=no
assert_eq "make install: ships cc-ask.sh, executable" "yes" "$got"

# ---- make reload never blocks a deploy (2026-09-11) ----
# The reload drops Hammerspoon's IPC port; an `hs -c` caught mid-reply then waited forever
# (a deploy sat 10 minutes on it). The recipe waits ~10s at most, then stops the client.
FAKEBIN="$TMP/fakehs"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nsleep 300\n' > "$FAKEBIN/hs"; chmod +x "$FAKEBIN/hs"
start=$(date +%s)
out="$(PATH="$FAKEBIN:$PATH" make -C "$ROOT" --no-print-directory reload 2>&1)"
took=$(( $(date +%s) - start ))
[ "$took" -le 15 ] && got=returned || got="blocked ${took}s"
assert_eq "make reload: a hung hs CLI can't block it" "returned" "$got"
case "$out" in *"hung"*) got=says ;; *) got=silent ;; esac
assert_eq "make reload: ...and it says the CLI hung" "says" "$got"
pgrep -f "$FAKEBIN/hs" >/dev/null && got=left || got=stopped
assert_eq "make reload: ...the hung client is stopped" "stopped" "$got"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/hs"
out="$(PATH="$FAKEBIN:$PATH" make -C "$ROOT" --no-print-directory reload 2>&1)"
case "$out" in *"Hammerspoon reloading (config re-read)"*) got=ok ;; *) got="$out" ;; esac
assert_eq "make reload: a normal reload still reports success" "ok" "$got"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/hs"
out="$(PATH="$FAKEBIN:$PATH" make -C "$ROOT" --no-print-directory reload 2>&1)"
case "$out" in *"not available"*) got=warns ;; *) got="$out" ;; esac
assert_eq "make reload: a failing hs CLI still warns" "warns" "$got"

# ---- installer bugs from the 2026-09-15 review ----
F="$TMP/fx"; mkdir -p "$F"

# 2026-09-15: run.sh calls `node` for ~10 suites, but neither the tooling check nor the gate named
# it, so a machine without node got "pre-flight tests failed" and a wall of "command not found".
# (Once the gate checks node, the gate tests above need node in their PATH double too.)
NONODE="$F/nojs-bin"; mkdir -p "$NONODE"
for b in lua jq; do src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$NONODE/$b"; done
PATH="$NONODE:/usr/bin:/bin" bash "$ROOT/install.sh" --tools-only </dev/null >"$F/nojs-tools.out" 2>&1
assert_eq "tooling check names node when it's missing (the test gate needs it)" "named" \
  "$(grep -q 'node' "$F/nojs-tools.out" && echo named || echo silent)"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$F/nojs-make-ran" > "$NONODE/make"; chmod +x "$NONODE/make"
CC_INSTALL_SKIP_TESTS= CC_INSTALL_CLAUDE_DIR="$F/nojs-claude" CC_INSTALL_HS_DIR="$F/nojs-hs" CC_INSTALL_NO_APP=1 \
  PATH="$NONODE:/usr/bin:/bin" bash "$ROOT/install.sh" </dev/null >"$F/nojs-gate.out" 2>&1
rc=$?
assert_eq "gate: a missing node stops the install and says so, before the suite runs" "stopped" \
  "$([ "$rc" -ne 0 ] && grep -q 'node' "$F/nojs-gate.out" && [ ! -e "$F/nojs-make-ran" ] && echo stopped || echo ran)"

# 2026-09-15: the merge wrote a temp file and renamed it over settings.json, so a symlinked
# (dotfiles-managed) settings.json became a plain file and the dotfiles copy never got the hooks.
LC="$F/link-claude"; mkdir -p "$LC" "$F/dotfiles"
echo '{"model":"opus"}' > "$F/dotfiles/settings.json"
ln -s "$F/dotfiles/settings.json" "$LC/settings.json"
CC_INSTALL_CLAUDE_DIR="$LC" CC_INSTALL_HS_DIR="$F/link-hs" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "a symlinked settings.json stays a symlink after the hook merge" "link" \
  "$([ -L "$LC/settings.json" ] && echo link || echo file)"
assert_json "...and the file it points to gains the hooks" "$F/dotfiles/settings.json" \
  '[.hooks.Stop[]?.hooks[]?.command] | any(contains("cc-status.sh"))' "true"

# 2026-09-15: install_file's cp failure was never checked (no set -e), so a checkout missing
# cc-ask.sh printed "copied" and "install complete", exit 0, with the hook wired to a missing file.
PR="$F/partial-repo"; mkdir -p "$PR"
cp "$ROOT"/install.sh "$ROOT"/settings-hooks.json "$ROOT"/cc-*.sh "$ROOT"/cc-core.lua "$ROOT"/claude-dashboard.lua "$PR/"
rm "$PR/cc-ask.sh"
CC_INSTALL_CLAUDE_DIR="$F/partial-claude" CC_INSTALL_HS_DIR="$F/partial-hs" CC_INSTALL_NO_APP=1 \
  bash "$PR/install.sh" </dev/null >"$F/partial.out" 2>&1
rc=$?
assert_eq "a checkout missing a hook script fails the install (nonzero exit)" "fail" \
  "$([ "$rc" -ne 0 ] && echo fail || echo ok)"
assert_eq "...and never prints install complete" "0" "$(grep -c 'install complete' "$F/partial.out")"

# 2026-09-15: the no-op check compared jq's re-serialisation with the raw file, so a fully wired
# settings.json in any other layout (4-space indent) was rewritten and backed up on every run.
IC="$F/indent-claude"; mkdir -p "$IC"
jq --indent 4 . "$CDIR/settings.json" > "$IC/settings.json"
before_i="$(cat "$IC/settings.json")"
CC_INSTALL_CLAUDE_DIR="$IC" CC_INSTALL_HS_DIR="$F/indent-hs" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "a fully wired settings.json in another layout is left byte-for-byte alone" "$before_i" "$(cat "$IC/settings.json")"
assert_eq "...and no backup is made" "0" "$(ls "$IC" | grep -c '\.bak\.')"

# 2026-09-15: an object-valued Stop group made jq's `+` fail, and the installer reported the
# valid JSON as "couldn't parse", pointing the user at the wrong problem.
OC="$F/obj-claude"; mkdir -p "$OC"
echo '{"hooks":{"Stop":{"hooks":[{"type":"command","command":"echo mine"}]}}}' > "$OC/settings.json"
CC_INSTALL_CLAUDE_DIR="$OC" CC_INSTALL_HS_DIR="$F/obj-hs" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >"$F/obj.out" 2>&1
assert_eq "valid JSON with an object-valued Stop group is never reported as unparseable" "0" \
  "$(grep -c "couldn't parse" "$F/obj.out")"
assert_json "...and the user's object-valued Stop group is left intact" "$OC/settings.json" \
  '.hooks.Stop.hooks[0].command' "echo mine"

# 2026-09-15: patch_approve only added a timeout when none was set, so an existing cc-approve.sh
# entry at 60s kept it, and Claude Code killed the 120s approval wait halfway.
TC="$F/t60-claude"; mkdir -p "$TC"
cat > "$TC/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "bash \"$HOME/.claude/cc-status.sh\" pretooluse" },
  { "type": "command", "command": "bash \"$HOME/.claude/cc-approve.sh\"", "timeout": 60 } ] } ] } }
JSON
CC_INSTALL_CLAUDE_DIR="$TC" CC_INSTALL_HS_DIR="$F/t60-hs" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_json "an existing cc-approve.sh timeout under 130s is raised to 130" "$TC/settings.json" \
  '.hooks.PreToolUse[0].hooks[1].timeout' "130"

# 2026-09-15: the dofile check was a bare grep for "claude-dashboard.lua", so a commented-out
# line counted as installed and a re-install never re-added the dashboard.
CH="$F/comment-hs"; mkdir -p "$CH"
printf -- '-- dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")\n' > "$CH/init.lua"
CC_INSTALL_CLAUDE_DIR="$F/comment-claude" CC_INSTALL_HS_DIR="$CH" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "a commented-out dashboard line doesn't count: install adds a live dofile" "1" \
  "$(grep -Fxc 'dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")' "$CH/init.lua")"

# 2026-09-15: add-to-dock.sh built the tile's file:// URL from the raw path, so an app under a
# path with a space (a HOME like "/Users/Jane Doe") got an unencoded URL the Dock can't resolve.
# defaults/killall/xattr are doubles: the real Dock is never touched.
DB="$F/dock-bin"; mkdir -p "$DB"
cat > "$DB/defaults" <<EOF
#!/bin/sh
[ "\$1" = write ] && echo "\$*" >> "$F/defaults.calls"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$DB/killall"; printf '#!/bin/sh\nexit 0\n' > "$DB/xattr"
chmod +x "$DB/defaults" "$DB/killall" "$DB/xattr"
SPACED="$F/Jane Doe/Applications/Shepherd.app"; mkdir -p "$SPACED"
PATH="$DB:/usr/bin:/bin" bash "$ROOT/app/add-to-dock.sh" "$SPACED" >/dev/null 2>&1
assert_eq "add-to-dock: a path with a space is percent-encoded in the Dock tile's URL" "encoded" \
  "$(grep -q 'Jane%20Doe' "$F/defaults.calls" 2>/dev/null && echo encoded || echo raw)"

# 2026-09-15: step 1 ran `chmod +x "$CLAUDE_DIR"/cc-*.sh`, a glob over the whole dir, so a user's
# own cc-prefixed script in ~/.claude had its mode changed by an install that never shipped it.
MC="$F/mode-claude"; mkdir -p "$MC"
printf '#!/bin/sh\necho mine\n' > "$MC/cc-mine.sh"; chmod 644 "$MC/cc-mine.sh"
CC_INSTALL_CLAUDE_DIR="$MC" CC_INSTALL_HS_DIR="$F/mode-hs" CC_INSTALL_NO_APP=1 \
  bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "a user's own cc-*.sh in the claude dir keeps its mode (install chmods only what it ships)" "644" \
  "$(stat -f '%Lp' "$MC/cc-mine.sh" 2>/dev/null || stat -c '%a' "$MC/cc-mine.sh")"

finish
