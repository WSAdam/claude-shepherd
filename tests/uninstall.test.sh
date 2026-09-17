#!/usr/bin/env bash
# uninstall.test.sh - uninstall.sh against a temp HOME-like layout (2026-09-17): after a real
# install.sh run into temp dirs, uninstall removes everything Shepherd put there -- its hooks,
# scripts, dashboard, init.lua line, app, methodology block -- and keeps what the user had:
# their own hooks, settings, CLAUDE.md text, init.lua lines and (without --purge) Shepherd's
# settings and state. A second run changes nothing. VS Code is a fake CLI that records calls.
. "$(dirname "$0")/lib.sh"

export CC_INSTALL_SKIP_TESTS=1 CC_INSTALL_NO_BRIDGE=1 CC_INSTALL_NO_APP=1
TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

C="$TMP/claude"; H="$TMP/hs"; A="$TMP/Applications"; mkdir -p "$C" "$H" "$A"
cat > "$C/settings.json" <<'JSON'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
JSON
printf '# my rules\n\nBe brief.\n' > "$C/CLAUDE.md"
printf 'hs.alert("mine")\n' > "$H/init.lua"
printf '#!/bin/sh\necho mine\n' > "$C/cc-mine.sh"
CC_INSTALL_CLAUDE_DIR="$C" CC_INSTALL_HS_DIR="$H" bash "$ROOT/install.sh" >/dev/null 2>&1
# what the app build and a running Shepherd would have left
mkdir -p "$A/Shepherd.app/Contents" "$C/cc-status" "$A/Other.app/Contents"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.claude-shepherd.launcher</string></dict></plist>\n' \
  > "$A/Shepherd.app/Contents/Info.plist"
printf '{}' > "$C/cc-status/abc.json"
mkdir -p "$C/cc-bridge"; printf '0.5.0' > "$C/cc-bridge/.installed"
FAKE="$TMP/code"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$TMP/code.calls" > "$FAKE"; chmod +x "$FAKE"

check_installed="$(grep -c 'cc-status.sh' "$C/settings.json")"
assert_eq "setup: the install really wired hooks and wrote the methodology" "yes" \
  "$([ "$check_installed" -gt 0 ] && grep -q 'shepherd-methodology:start' "$C/CLAUDE.md" && echo yes || echo no)"

run_uninstall() {
  CC_INSTALL_CLAUDE_DIR="$C" CC_INSTALL_HS_DIR="$H" CC_UNINSTALL_APP_DIR="$A" CC_CODE_CLI="$FAKE" \
    bash "$ROOT/uninstall.sh" "$@" >/dev/null 2>&1
}
run_uninstall

assert_eq "no Shepherd hook is left in settings.json" "0" \
  "$(jq '[.. | .command? // empty | select(test("cc-(status|approve|popup|ask)\\.sh"))] | length' "$C/settings.json")"
assert_json "the user's own Stop hook is kept" "$C/settings.json" '.hooks.Stop[0].hooks[0].command' "echo mine"
assert_json "...as the only Stop group" "$C/settings.json" '.hooks.Stop | length' "1"
assert_json "an event left with no hooks is dropped" "$C/settings.json" '.hooks | has("PreToolUse")' "false"
assert_json "the user's other settings are kept" "$C/settings.json" '.model' "opus"
for f in cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-core.lua; do
  assert_eq "removes $f from the claude dir" "gone" "$([ -e "$C/$f" ] && echo there || echo gone)"
done
assert_eq "a user's own cc-*.sh is kept" "there" "$([ -e "$C/cc-mine.sh" ] && echo there || echo gone)"
assert_eq "removes the dashboard from the Hammerspoon dir" "gone" \
  "$([ -e "$H/claude-dashboard.lua" ] || [ -e "$H/cc-core.lua" ] && echo there || echo gone)"
assert_eq "init.lua loses the dashboard line" "0" "$(grep -c 'claude-dashboard.lua' "$H/init.lua")"
assert_eq "...and keeps the user's own line" 'hs.alert("mine")' "$(cat "$H/init.lua")"
assert_eq "CLAUDE.md loses the methodology block" "0" "$(grep -c 'shepherd-methodology' "$C/CLAUDE.md")"
assert_eq "...and keeps the user's text as it was" "$(printf '# my rules\n\nBe brief.')" "$(cat "$C/CLAUDE.md")"
assert_eq "removes Shepherd.app" "gone" "$([ -e "$A/Shepherd.app" ] && echo there || echo gone)"
assert_eq "never touches another app" "there" "$([ -e "$A/Other.app" ] && echo there || echo gone)"
assert_eq "uninstalls the VS Code tab bridge" "1" \
  "$(grep -c -- '--uninstall-extension local.shepherd-bridge' "$TMP/code.calls" 2>/dev/null || true)"
assert_eq "without --purge, Shepherd's settings are kept" "there" "$([ -e "$C/cc-config.json" ] && echo there || echo gone)"
assert_eq "without --purge, Shepherd's state is kept" "there" "$([ -e "$C/cc-status/abc.json" ] && echo there || echo gone)"

before="$(cat "$C/settings.json" "$C/CLAUDE.md" "$H/init.lua")"
run_uninstall
assert_eq "a second uninstall changes nothing" "$before" "$(cat "$C/settings.json" "$C/CLAUDE.md" "$H/init.lua")"

run_uninstall --purge
assert_eq "--purge removes Shepherd's settings" "gone" "$([ -e "$C/cc-config.json" ] && echo there || echo gone)"
assert_eq "--purge removes Shepherd's state" "gone" "$([ -e "$C/cc-status" ] && echo there || echo gone)"
assert_eq "--purge still keeps the user's own files" "there" "$([ -e "$C/cc-mine.sh" ] && echo there || echo gone)"

# a CLAUDE.md that is only the block (a fresh machine) is removed, not left empty
C2="$TMP/claude2"; mkdir -p "$C2"
CC_INSTALL_CLAUDE_DIR="$C2" CC_INSTALL_HS_DIR="$TMP/hs2" bash "$ROOT/install.sh" >/dev/null 2>&1
CC_INSTALL_CLAUDE_DIR="$C2" CC_INSTALL_HS_DIR="$TMP/hs2" CC_UNINSTALL_APP_DIR="$A" CC_CODE_CLI="$FAKE" \
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1
assert_eq "a CLAUDE.md holding only the methodology is removed" "gone" "$([ -e "$C2/CLAUDE.md" ] && echo there || echo gone)"

finish
