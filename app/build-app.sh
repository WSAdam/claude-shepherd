#!/usr/bin/env bash
#
# build-app.sh — construct Shepherd.app as a minimal hand-rolled bundle.
#
# Replaces the old osacompile applet. Field history: applets ship an Assets.car
# that overrides a swapped icon, carry NO CFBundleIdentifier, and every applet
# on the system shares the "applet" executable/icon names — macOS's icon cache
# kept rendering the generic applet icon through rebuilds, lsregister, re-pins,
# and Dock restarts. A hand-rolled bundle has its own executable name, its own
# icon name, and its own bundle id, so there is nothing left to collide with.
#
# The app is a one-shot launcher: clicking it opens the hammerspoon:// toggle
# URL (LaunchServices delivers the host LOWERCASED; the dashboard binds that
# spelling) and exits. LSUIElement keeps it from bouncing in the Dock.
set -euo pipefail

APP="${1:?usage: build-app.sh /path/to/Shepherd.app}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/MacOS/shepherd" <<'STUB'
#!/bin/sh
exec /usr/bin/open "hammerspoon://ccshepherdtoggle"
STUB
chmod +x "$APP/Contents/MacOS/shepherd"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Shepherd</string>
  <key>CFBundleDisplayName</key>     <string>Shepherd</string>
  <key>CFBundleIdentifier</key>      <string>com.claude-shepherd.launcher</string>
  <key>CFBundleVersion</key>         <string>2</string>
  <key>CFBundleShortVersionString</key> <string>1.1</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>shepherd</string>
  <key>CFBundleIconFile</key>        <string>shepherd</string>
  <key>LSMinimumSystemVersion</key>  <string>11.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Icon: PNG -> icns under the bundle's own name (make-icon.sh reads
# CFBundleIconFile, so it writes Resources/shepherd.icns here).
bash "$HERE/app/make-icon.sh" "$APP" || true

# Ad-hoc sign so Gatekeeper treats it like the old applet (right-click -> Open once).
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
touch "$APP"
echo "✅ built $APP (hand-rolled launcher bundle)"
