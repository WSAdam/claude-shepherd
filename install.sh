#!/usr/bin/env bash
#
# install.sh - idempotent first-run setup for Claude Shepherd.
#
# Copies the hook scripts + pure core into ~/.claude and the dashboard into
# ~/.hammerspoon, merges our hooks into ~/.claude/settings.json (backing up
# first), ensures the dofile in ~/.hammerspoon/init.lua, and builds the
# Shepherd.app Dock launcher. SAFE TO RE-RUN: a second run is a no-op.
#
# The hook merge mirrors core.mergeHooks (cc-core.lua, unit-tested): for each
# event, append our group only if none of OUR scripts (cc-status/approve/popup.sh)
# is wired yet; otherwise skip. Matching our exact names (not a bare "cc-" substring)
# avoids colliding with a user's own cc-prefixed hook.
#
# Env overrides (used by tests/install.test.sh to stay hermetic):
#   CC_INSTALL_CLAUDE_DIR, CC_INSTALL_HS_DIR, CC_INSTALL_NO_APP

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CC_INSTALL_CLAUDE_DIR:-$HOME/.claude}"
HS_DIR="${CC_INSTALL_HS_DIR:-$HOME/.hammerspoon}"
SETTINGS="$CLAUDE_DIR/settings.json"
TEMPLATE="$HERE/settings-hooks.json"
INIT="$HS_DIR/init.lua"
DOFILE_LINE='dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")'

have_jq() { command -v jq >/dev/null 2>&1; }

mkdir -p "$CLAUDE_DIR" "$HS_DIR"

# 1. Scripts + core -> ~/.claude ; dashboard + core -> ~/.hammerspoon.
cp "$HERE"/cc-lib.sh "$HERE"/cc-status.sh "$HERE"/cc-approve.sh "$HERE"/cc-popup.sh "$HERE"/cc-core.lua "$CLAUDE_DIR/"
chmod +x "$CLAUDE_DIR"/cc-*.sh
cp "$HERE"/claude-dashboard.lua "$HERE"/cc-core.lua "$HS_DIR/"
echo "✅ copied hook scripts + core -> $CLAUDE_DIR ; dashboard -> $HS_DIR"

# 2. Merge hooks into settings.json (back up first; idempotent append-if-missing).
if have_jq; then
  if [ ! -f "$SETTINGS" ]; then
    jq --argjson tmpl "$(cat "$TEMPLATE")" -n '{hooks: $tmpl.hooks}' > "$SETTINGS"
    echo "✅ wrote hooks to new $SETTINGS"
  else
    merged="$(jq --argjson tmpl "$(cat "$TEMPLATE")" '
      .hooks //= {}
      | reduce ($tmpl.hooks | to_entries[]) as $e (.;
          ([ (.hooks[$e.key] // [])[].hooks[]?.command? // empty ] | any(test("cc-(status|approve|popup)\\.sh"))) as $has
          | if $has then . else .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value) end)
    ' "$SETTINGS" 2>/dev/null)"
    if [ -z "$merged" ]; then
      echo "⚠️  couldn't parse $SETTINGS — leaving it; merge $TEMPLATE by hand"
    elif [ "$merged" = "$(cat "$SETTINGS")" ]; then
      echo "✅ hooks already present in $SETTINGS (no change)"
    else
      cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
      printf '%s\n' "$merged" > "$SETTINGS"
      echo "✅ merged hooks into $SETTINGS (backup made)"
    fi
  fi
else
  echo "⚠️  jq not found — install jq, then merge $TEMPLATE into $SETTINGS"
fi

# 3. Ensure init.lua dofiles the dashboard.
if [ ! -f "$INIT" ] || ! grep -Fq "claude-dashboard.lua" "$INIT"; then
  printf '%s\n' "$DOFILE_LINE" >> "$INIT"
  echo "✅ added dofile to $INIT"
else
  echo "✅ dofile already in $INIT"
fi

# 4. Build the Dock launcher (skipped in tests / when osacompile is absent).
if [ -z "${CC_INSTALL_NO_APP:-}" ] && command -v osacompile >/dev/null 2>&1; then
  make -C "$HERE" app || echo "⚠️  Shepherd.app build skipped"
fi

echo "ℹ️  Kitty users: Shepherd can auto-enable remote control in kitty.conf (Settings)."
echo "✅ install complete — open/reload Hammerspoon to start the panel."
