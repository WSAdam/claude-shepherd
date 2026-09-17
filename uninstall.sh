#!/usr/bin/env bash
#
# uninstall.sh - remove Claude Shepherd from this Mac (2026-09-17). The reverse of install.sh:
#   1. its hooks out of ~/.claude/settings.json (a backup is made; the user's own hooks and
#      every other setting stay -- including the defaults install filled in, now the user's),
#   2. the scripts + core it copied into ~/.claude and the dashboard in ~/.hammerspoon,
#   3. its dofile line from ~/.hammerspoon/init.lua,
#   4. the methodology block from ~/.claude/CLAUDE.md (a file holding nothing else goes),
#   5. ~/Applications/Shepherd.app (only the bundle with Shepherd's own id),
#   6. the VS Code tab bridge extension.
# Shepherd's settings and state (cc-config.json, cc-status/, the ledger, ...) stay unless
# --purge. Homebrew packages, Hammerspoon, VS Code and Claude Code are left installed.
# Safe to re-run. Same env overrides as install.sh (tests/uninstall.test.sh):
#   CC_INSTALL_CLAUDE_DIR, CC_INSTALL_HS_DIR, CC_UNINSTALL_APP_DIR, CC_CODE_CLI

set -u

CLAUDE_DIR="${CC_INSTALL_CLAUDE_DIR:-$HOME/.claude}"
HS_DIR="${CC_INSTALL_HS_DIR:-$HOME/.hammerspoon}"
APP_DIR="${CC_UNINSTALL_APP_DIR:-$HOME/Applications}"
SETTINGS="$CLAUDE_DIR/settings.json"
INIT="$HS_DIR/init.lua"
MD="$CLAUDE_DIR/CLAUDE.md"
PURGE=0
for arg in "$@"; do [ "$arg" = "--purge" ] && PURGE=1; done

# KEEP IN SYNC with install.sh's CLAUDE_FILES / HS_FILES
CLAUDE_FILES="cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-core.lua"
HS_FILES="claude-dashboard.lua cc-core.lua"
# Shepherd's settings and state under ~/.claude (--purge only)
STATE="cc-ab.json cc-agents.json cc-approved cc-ask cc-automodel cc-autopilot cc-autotitles.json cc-bridge
  cc-config.json cc-exports cc-fleet cc-gate-tools cc-gate.enabled cc-groups.json cc-hidden.json cc-labels.json
  cc-ledger cc-lock.json cc-mcp-configs cc-mcp.json cc-merge cc-policy cc-policy-override cc-presets.json
  cc-prompts cc-queue cc-recent-dirs.json cc-rules.json cc-schedules.json cc-scratch cc-shepherd.log
  cc-status cc-status-mirror cc-templates.json cc-worklist.json"

echo "🚀 uninstalling Claude Shepherd"

resolve_link() {
  local p="$1" t n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}

# 1. Hooks first, so no session runs a script that is about to go.
if [ -f "$SETTINGS" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq not found -- remove the cc-*.sh hooks from $SETTINGS by hand"
  elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "⚠️  couldn't parse $SETTINGS -- remove the cc-*.sh hooks by hand"
  else
    cleaned="$(jq '
      def ours: ((.command? // "") | type == "string") and ((.command? // "") | test("cc-(status|approve|popup|ask)\\.sh"));
      if (.hooks | type) != "object" then . else
        .hooks |= with_entries(
          if (.value | type) != "array" then . else
            .value |= map(if (type == "object") and ((.hooks? | type) == "array")
                          then (.hooks |= map(select(ours | not)))
                               | (if (.hooks | length) == 0 then empty else . end)
                          else . end)
          end)
        | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
      end' "$SETTINGS" 2>/dev/null)"
    if [ -z "$cleaned" ]; then
      echo "⚠️  couldn't edit $SETTINGS -- remove the cc-*.sh hooks by hand"
    elif [ "$cleaned" = "$(jq . "$SETTINGS")" ]; then
      echo "✅ no Shepherd hooks in $SETTINGS"
    else
      cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
      real="$(resolve_link "$SETTINGS")"
      printf '%s\n' "$cleaned" > "$(dirname "$real")/.settings.json.tmp.$$" \
        && mv -f "$(dirname "$real")/.settings.json.tmp.$$" "$real"
      echo "✅ removed Shepherd's hooks from $SETTINGS (backup made)"
    fi
  fi
fi

# 2. The files install.sh copied (only those names -- a user's own cc-*.sh stays).
for f in $CLAUDE_FILES; do rm -f "$CLAUDE_DIR/$f"; done
for f in $HS_FILES; do rm -f "$HS_DIR/$f"; done
echo "✅ removed Shepherd's scripts from $CLAUDE_DIR and the dashboard from $HS_DIR"

# 3. The dofile line (any live line loading the dashboard), keeping everything else.
if [ -f "$INIT" ] && grep -v '^[[:space:]]*--' "$INIT" | grep -Fq "claude-dashboard.lua"; then
  real="$(resolve_link "$INIT")"
  awk '!/claude-dashboard\.lua/ || /^[[:space:]]*--/' "$INIT" > "$(dirname "$real")/.init.lua.tmp.$$" \
    && mv -f "$(dirname "$real")/.init.lua.tmp.$$" "$real"
  echo "✅ removed the dashboard line from $INIT"
fi

# 4. The methodology block, plus the blank lines install put before it.
if [ -f "$MD" ] && grep -q 'shepherd-methodology:start' "$MD"; then
  real="$(resolve_link "$MD")"
  tmp="$(dirname "$real")/.CLAUDE.md.tmp.$$"
  awk '
    /shepherd-methodology:start/ { skip = 1; next }
    /shepherd-methodology:end/   { skip = 0; next }
    !skip { lines[++n] = $0 }
    END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }' "$MD" > "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$real"; echo "✅ removed the Shepherd methodology from $MD"
  else rm -f "$tmp" "$real"; echo "✅ removed $MD (it held only the Shepherd methodology)"; fi
fi

# 5. The Dock launcher -- only the bundle carrying Shepherd's id.
APP="$APP_DIR/Shepherd.app"
if [ -d "$APP" ] && grep -q 'com.claude-shepherd.launcher' "$APP/Contents/Info.plist" 2>/dev/null; then
  rm -rf "$APP"
  echo "✅ removed $APP (drag its icon off the Dock if it's pinned)"
fi

# 6. The VS Code tab bridge. Same CLI lookup as vscode-bridge/install-vsix.sh.
CLI="${CC_CODE_CLI:-}"
if [ -z "$CLI" ]; then CLI="$(command -v code 2>/dev/null || true)"; fi
if { [ -z "$CLI" ] || [ ! -x "$CLI" ]; } && [ -z "${CC_CODE_CLI:-}" ]; then
  VSAPP="$(mdfind "kMDItemCFBundleIdentifier == 'com.microsoft.VSCode'" 2>/dev/null | head -n 1)"
  [ -n "$VSAPP" ] && CLI="$VSAPP/Contents/Resources/app/bin/code"
fi
if [ -n "$CLI" ] && [ -x "$CLI" ]; then
  "$CLI" --uninstall-extension local.shepherd-bridge >/dev/null 2>&1 \
    && echo "✅ uninstalled the Shepherd tab bridge from VS Code (reload open windows)" \
    || echo "✅ the Shepherd tab bridge wasn't installed in VS Code"
  rm -f "$CLAUDE_DIR/cc-bridge/.installed"
else
  echo "⚠️  VS Code's command-line tool not found -- remove the Shepherd Bridge extension in VS Code by hand"
fi

# --purge: Shepherd's settings and state.
if [ "$PURGE" -eq 1 ]; then
  for s in $STATE; do rm -rf "${CLAUDE_DIR:?}/$s"; done
  rm -rf "$CLAUDE_DIR"/cc-ledger.* "$CLAUDE_DIR"/cc-exports.*
  echo "✅ removed Shepherd's settings and state from $CLAUDE_DIR"
else
  echo "ℹ️  kept Shepherd's settings and state in $CLAUDE_DIR (cc-config.json, cc-status/, ...) -- re-run with --purge to remove them"
fi

echo "✅ Shepherd uninstalled -- reload Hammerspoon (menu bar icon → Reload Config) to close the panel."
echo "   Hammerspoon, VS Code, Claude Code and the Homebrew packages are still installed."
