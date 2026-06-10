#!/usr/bin/env bash
#
# add-to-dock.sh — pin Shepherd.app to the macOS Dock (idempotent).
#
# The panel itself lives inside Hammerspoon (claude-dashboard.lua). Shepherd.app is
# a tiny launcher that toggles it via the hammerspoon:// URL scheme. This script
# adds that launcher to the Dock so it's one click away and persists across logins.
# Safe to re-run: if it's already in the Dock, it does nothing. Reversible: drag the
# icon off the Dock to remove it.
set -euo pipefail

APP="${1:-$HOME/Applications/Shepherd.app}"

if [ ! -d "$APP" ]; then
  echo "❌ $APP not found — run 'make app' first." >&2
  exit 1
fi

# Already pinned? (match the bundle path in the Dock's persistent-apps plist.)
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Shepherd.app"; then
  echo "✅ Shepherd.app is already in the Dock — nothing to do."
  exit 0
fi

# Prefer dockutil if it's installed (cleaner, no manual plist surgery).
if command -v dockutil >/dev/null 2>&1; then
  dockutil --add "$APP" --no-restart >/dev/null 2>&1 || true
  killall Dock 2>/dev/null || true
  echo "✅ added Shepherd.app to the Dock (via dockutil)."
  exit 0
fi

# Fallback: append a persistent-apps tile pointing at the app bundle, then restart
# the Dock so the change shows. The Dock restart is a ~1s flicker; nothing else.
TILE="<dict><key>tile-data</key><dict><key>file-data</key><dict>\
<key>_CFURLString</key><string>file://${APP}/</string>\
<key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
defaults write com.apple.dock persistent-apps -array-add "$TILE"
killall Dock 2>/dev/null || true
echo "✅ added Shepherd.app to the Dock. (If it doesn't appear immediately, log out/in.)"
