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
printf '{"version":1,"files":{}}' > "$C/cc-usage-state.json"
mkdir -p "$C/cc-talk"; printf '1' > "$C/cc-talk/abc"
mkdir -p "$C/cc-notes/pending"; printf '# Handoff\n' > "$C/cc-notes/abc.handoff.md"
mkdir -p "$C/cc-inbox/abc"; printf '{"nonce":"ab"}' > "$C/cc-inbox/abc/1790000000-000001-ab.msg"
mkdir -p "$C/cc-decide"; printf '{"id":"abc.1790000000-1","key":"abc"}' > "$C/cc-decide/abc.1790000000-1.json"
mkdir -p "$C/cc-resume"; printf '{"key":"abc","nonce":"ab","state":"waiting"}' > "$C/cc-resume/abc.json"
mkdir -p "$C/cc-pins"; printf '{"v":1,"root":"/r","pins":[]}' > "$C/cc-pins/-r.json"
mkdir -p "$C/cc-lease/db"; printf '{"v":1,"main":"/r","leases":{}}' > "$C/cc-lease/-r.json"
mkdir -p "$C/cc-bridge"; printf '0.5.0' > "$C/cc-bridge/.installed"
mkdir -p "$C/cc-send"; printf '{"nonce":"ab"}' > "$C/cc-send/shell.1790000000-1.answer"
printf '{"v":1,"repos":{}}' > "$C/cc-reqs.json"
mkdir -p "$C/cc-tickets"; printf '{"v":1,"id":"t1790000000-1"}' > "$C/cc-tickets/t1790000000-1.json"
mkdir -p "$C/cc-audit/-r"; printf -- '- [ ] [LOW] AUD-001 x\n' > "$C/cc-audit/-r/AUDIT-FINDINGS.md"
printf '{"v":1,"labels":{"toolu_a":{"verdict":"ok"}}}' > "$C/cc-skill-labels.json"
mkdir -p "$C/cc-coach"; printf '{"v":1,"root":"/r","state":"done"}' > "$C/cc-coach/-r.json"
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

# 2026-09-28 requirement change: cc-worktree-guard.sh (one worktree, one agent) is a Shepherd hook too.
# 2026-09-29 requirement change: and cc-resume.sh (resume at the usage limit's reset).
assert_eq "no Shepherd hook is left in settings.json" "0" \
  "$(jq '[.. | .command? // empty | select(test("cc-(status|approve|popup|ask|worktree-guard|resume)\\.sh"))] | length' "$C/settings.json")"
assert_json "the user's own Stop hook is kept" "$C/settings.json" '.hooks.Stop[0].hooks[0].command' "echo mine"
assert_json "...as the only Stop group" "$C/settings.json" '.hooks.Stop | length' "1"
assert_json "an event left with no hooks is dropped" "$C/settings.json" '.hooks | has("PreToolUse")' "false"
assert_json "the user's other settings are kept" "$C/settings.json" '.model' "opus"
# 2026-09-29: cc-send.sh (a prompt for a live session, from any shell) is shipped too.
# 2026-09-29: cc-ticket.sh (cross-repo tickets) is shipped too.
for f in cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-commits.sh cc-worktree-guard.sh cc-resume.sh cc-send.sh cc-ticket.sh cc-core.lua; do
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
# 2026-09-29: Adam's skill-run labels (cc-skill-labels.json) are his data: only --purge takes them
assert_eq "without --purge, your skill-run labels are kept" "there" "$([ -e "$C/cc-skill-labels.json" ] && echo there || echo gone)"

before="$(cat "$C/settings.json" "$C/CLAUDE.md" "$H/init.lua")"
run_uninstall
assert_eq "a second uninstall changes nothing" "$before" "$(cat "$C/settings.json" "$C/CLAUDE.md" "$H/init.lua")"

run_uninstall --purge
assert_eq "--purge removes Shepherd's settings" "gone" "$([ -e "$C/cc-config.json" ] && echo there || echo gone)"
assert_eq "--purge removes Shepherd's state" "gone" "$([ -e "$C/cc-status" ] && echo there || echo gone)"
# 2026-09-28: the saved usage totals (cc-usage-state.json) are Shepherd's state too
assert_eq "--purge removes the saved usage totals" "gone" "$([ -e "$C/cc-usage-state.json" ] && echo there || echo gone)"
# 2026-09-28: talk mode's per-session flags (cc-talk/) are Shepherd's state too
assert_eq "--purge removes the talk-mode flags" "gone" "$([ -e "$C/cc-talk" ] && echo there || echo gone)"
# 2026-09-28: the handoff notes (cc-notes/) are Shepherd's state too
assert_eq "--purge removes the handoff notes" "gone" "$([ -e "$C/cc-notes" ] && echo there || echo gone)"
# 2026-09-29: the session mailbox (cc-inbox/) is Shepherd's state too
assert_eq "--purge removes the session mailbox" "gone" "$([ -e "$C/cc-inbox" ] && echo there || echo gone)"
# 2026-09-29: the decisions inbox (cc-decide/) is Shepherd's state too
assert_eq "--purge removes the open decisions" "gone" "$([ -e "$C/cc-decide" ] && echo there || echo gone)"
# 2026-09-29: the resumes waiting for a usage limit's reset (cc-resume/) are Shepherd's state too
assert_eq "--purge removes the resumes waiting for a limit reset" "gone" "$([ -e "$C/cc-resume" ] && echo there || echo gone)"
# 2026-09-29: the pinned links (cc-pins/) are Shepherd's state too
assert_eq "--purge removes the pinned links" "gone" "$([ -e "$C/cc-pins" ] && echo there || echo gone)"
# 2026-09-29: the worktree leases (cc-lease/, with the default database folder inside it) too
assert_eq "--purge removes the worktree leases" "gone" "$([ -e "$C/cc-lease" ] && echo there || echo gone)"
# 2026-09-29: cc-send's requests and answers (cc-send/) too
assert_eq "--purge removes cc-send's requests" "gone" "$([ -e "$C/cc-send" ] && echo there || echo gone)"
# 2026-09-29: the requirement ids Shepherd minted (cc-reqs.json) too
assert_eq "--purge removes the minted requirement ids" "gone" "$([ -e "$C/cc-reqs.json" ] && echo there || echo gone)"
# 2026-09-29: the cross-repo tickets (cc-tickets/) too
assert_eq "--purge removes the cross-repo tickets" "gone" "$([ -e "$C/cc-tickets" ] && echo there || echo gone)"
# 2026-09-29: the find-only audits' findings, settings and MCP configs (cc-audit/) too
assert_eq "--purge removes the find-only audits" "gone" "$([ -e "$C/cc-audit" ] && echo there || echo gone)"
# 2026-09-29: and the skill-run labels (cc-skill-labels.json)
assert_eq "--purge removes the skill-run labels" "gone" "$([ -e "$C/cc-skill-labels.json" ] && echo there || echo gone)"
# 2026-09-29: the coach's records and its log of merge notes (cc-coach/) too
assert_eq "--purge removes the coach's records" "gone" "$([ -e "$C/cc-coach" ] && echo there || echo gone)"
assert_eq "--purge still keeps the user's own files" "there" "$([ -e "$C/cc-mine.sh" ] && echo there || echo gone)"

# a CLAUDE.md that is only the block (a fresh machine) is removed, not left empty
C2="$TMP/claude2"; mkdir -p "$C2"
CC_INSTALL_CLAUDE_DIR="$C2" CC_INSTALL_HS_DIR="$TMP/hs2" bash "$ROOT/install.sh" >/dev/null 2>&1
CC_INSTALL_CLAUDE_DIR="$C2" CC_INSTALL_HS_DIR="$TMP/hs2" CC_UNINSTALL_APP_DIR="$A" CC_CODE_CLI="$FAKE" \
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1
assert_eq "a CLAUDE.md holding only the methodology is removed" "gone" "$([ -e "$C2/CLAUDE.md" ] && echo there || echo gone)"

# 2026-09-28: uninstall.sh kept its own copy of the file list and of the hook names, so a script
# a later release ships (newhook_repo, tests/lib.sh) would be installed and wired, then left
# behind by the uninstall -- a hook still wired to a script it just deleted. Both now come from
# SHIPPED, and the uninstall takes out exactly what the install put in.
NH="$(newhook_repo "$TMP/newhook-repo")"
C3="$TMP/claude3"; H3="$TMP/hs3"; mkdir -p "$C3"
cat > "$C3/settings.json" <<'JSON'
{ "model": "opus", "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ],
    "StopFailure": [ { "matcher": "rate_limit", "hooks": [ { "type": "command", "command": "echo limited" } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo bash" } ] } ],
    "PreCompact": [ { "hooks": [ { "type": "command", "command": "echo compacting" } ] } ] } }
JSON
users_hooks="$(jq -S .hooks "$C3/settings.json")"
CC_INSTALL_CLAUDE_DIR="$C3" CC_INSTALL_HS_DIR="$H3" bash "$NH/install.sh" >/dev/null 2>&1
assert_eq "(fixture: the install wired the new hook)" "yes" \
  "$(grep -q 'cc-newhook.sh' "$C3/settings.json" && [ -e "$C3/cc-newhook.sh" ] && echo yes || echo no)"
CC_INSTALL_CLAUDE_DIR="$C3" CC_INSTALL_HS_DIR="$H3" CC_UNINSTALL_APP_DIR="$A" CC_CODE_CLI="$FAKE" \
  bash "$NH/uninstall.sh" >/dev/null 2>&1
assert_eq "uninstall removes exactly the hooks install added (the user's own are all that's left)" \
  "$users_hooks" "$(jq -S .hooks "$C3/settings.json")"
assert_eq "uninstall removes a script a later release added to SHIPPED" "gone" \
  "$([ -e "$C3/cc-newhook.sh" ] && echo there || echo gone)"
left=""
for f in $(cd "$NH" && ls -1 cc-*.sh cc-core.lua claude-dashboard.lua); do
  [ -e "$C3/$f" ] || [ -e "$H3/$f" ] && left="$left $f"
done
assert_eq "...and every other file it shipped" "" "$left"

finish
