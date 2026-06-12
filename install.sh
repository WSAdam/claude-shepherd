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
# avoids colliding with a user's own cc-prefixed hook. The test() is an UNANCHORED
# substring (KEEP IN SYNC with core.OUR_HOOK_SCRIPTS), so a contrived my-cc-status.sh
# would be a false positive -- acceptable next to the old bare-"cc-" net.
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
      # Migrate older installs: the cc-approve.sh entry must carry a timeout above
      # the gate'\''s 120s poll or Claude Code kills the hook at its 60s default
      # mid-wait. The append-if-missing pass above skips events already wired, so
      # patch the timeout in place where it'\''s missing (idempotent). SHAPE-
      # PRESERVING: this pass visits every event (including ones we don'\''t own),
      # so it must never reshape them — the outer type=="array" guard leaves
      # object-valued event groups alone, and `.hooks? // null` turns the
      # suppressed lookup on a non-object element into null (else `map` would
      # silently DROP the element when the if yields empty).
      | .hooks |= with_entries(.value |= (if type == "array" then map(
          if ((.hooks? // null) | type) == "array" then
            .hooks |= map(if ((.command? // "") | test("cc-approve\\.sh")) and (has("timeout") | not)
                          then . + {timeout: 130} else . end)
          else . end)
        else . end))
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
  # A pre-existing init.lua may lack a trailing newline; appending straight onto
  # its last line would glue the dofile into invalid Lua (breaking the user's
  # whole config). Separate first. ($() strips a trailing \n, so non-empty
  # output from tail -c1 means the last byte is NOT a newline.)
  if [ -s "$INIT" ] && [ -n "$(tail -c1 "$INIT")" ]; then printf '\n' >> "$INIT"; fi
  printf '%s\n' "$DOFILE_LINE" >> "$INIT"
  echo "✅ added dofile to $INIT"
else
  echo "✅ dofile already in $INIT"
fi

# 4. Build the Dock launcher (skipped in tests). Hand-rolled bundle -- no
# osacompile dependency (see app/build-app.sh for why applets were dropped).
if [ -z "${CC_INSTALL_NO_APP:-}" ]; then
  make -C "$HERE" app || echo "⚠️  Shepherd.app build skipped"
fi

echo "ℹ️  Kitty users: Shepherd can auto-enable remote control in kitty.conf (Settings)."
echo "✅ install complete — open/reload Hammerspoon to start the panel."
