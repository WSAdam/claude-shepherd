#!/usr/bin/env bash
# Best-effort: produce a sheep icon and install it into a built .app's Resources.
# Prefers a committed PNG (docs/assets/shepherd.png); else renders the 🐑 glyph via
# Swift (Xcode Command Line Tools). Silently no-ops (keeps the default applet icon)
# if neither is available, so `make app` still succeeds on a bare machine.
set -euo pipefail

APP="${1:?usage: make-icon.sh /path/to/Shepherd.app}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root
SRC_PNG="$HERE/docs/assets/shepherd.png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

png="$TMP/shepherd.png"
if [ -f "$SRC_PNG" ]; then
  cp "$SRC_PNG" "$png"
elif command -v swift >/dev/null 2>&1; then
  swift - "$png" <<'SWIFT'
import Cocoa
let out = CommandLine.arguments[1]
let glyph = "🐑" as NSString
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let font = NSFont.systemFont(ofSize: 820)
let attrs: [NSAttributedString.Key: Any] = [.font: font]
let sz = glyph.size(withAttributes: attrs)
glyph.draw(at: NSPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2),
           withAttributes: attrs)
img.unlockFocus()
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
SWIFT
else
  echo "⚠️  no docs/assets/shepherd.png and no swift — keeping the default app icon"
  exit 0
fi

# PNG -> .iconset -> .icns (the default name osacompile's applet references).
set="$TMP/icon.iconset"; mkdir -p "$set"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$TMP/applet.icns"
cp "$TMP/applet.icns" "$APP/Contents/Resources/applet.icns"
touch "$APP"
echo "✅ installed sheep icon into $APP"
