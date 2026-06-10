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

finish
