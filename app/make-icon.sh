#!/usr/bin/env bash
# Best-effort: produce the Shepherd Dock icon and install it into a built .app's
# Resources. Prefers a committed PNG (docs/assets/shepherd.png -- drop your own black
# German-shepherd-face image there to override, 1024x1024 square); else draws a black
# GSD-head silhouette via Swift (Xcode Command Line Tools). Silently no-ops (keeps the
# default applet icon) if neither is available, so `make app` still succeeds on a bare
# machine. The menubar icon stays 🐑 (the flock) -- this is only the Dock/app icon.
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
let size: CGFloat = 1024
let pad: CGFloat = 96
// Left-facing German-shepherd head silhouette (erect ear, snout, neck) in an arbitrary
// design space; normalized below to center + fit the canvas with a transparent margin.
// These points are a MACHINE-DERIVED ordered outline traversed once (move -> line-loop ->
// close), NOT hand-tuned art: reordering or inserting a pair distorts the polygon. To change
// the shape, regenerate the outline from source art rather than nudging integers here. (This
// is only the no-committed-PNG fallback; docs/assets/shepherd.png is the real icon.)
let pts: [(CGFloat, CGFloat)] = [
  (158,505),(250,545),(360,568),(442,582),(470,640),(495,705),(516,724),
  (548,966),(664,720),(706,648),(758,575),(806,430),(812,250),
  (640,232),(548,250),(472,330),(372,388),(262,442),(200,478)
]
let xs = pts.map { $0.0 }, ys = pts.map { $0.1 }
let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
let scale = min((size - 2*pad)/(maxX - minX), (size - 2*pad)/(maxY - minY))
let offX = (size - (maxX - minX)*scale)/2 - minX*scale
let offY = (size - (maxY - minY)*scale)/2 - minY*scale
func tp(_ p: (CGFloat, CGFloat)) -> NSPoint { NSPoint(x: p.0*scale + offX, y: p.1*scale + offY) }
let bp = NSBezierPath()
bp.move(to: tp(pts[0]))
for q in pts.dropFirst() { bp.line(to: tp(q)) }
bp.close()
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor.black.set()
bp.fill()
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
# Install under the bundle's DECLARED icon name (CFBundleIconFile): the
# hand-rolled bundle uses "shepherd" -- deliberately NOT "applet", the name
# every osacompile applet on the system shares, which macOS's icon cache
# lumps together (field-proven: the generic applet icon survived rebuilds,
# a fresh bundle id, lsregister, re-pins, and Dock restarts).
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || echo applet)"
ICON_NAME="${ICON_NAME%.icns}"
iconutil -c icns "$set" -o "$TMP/icon.icns"
cp "$TMP/icon.icns" "$APP/Contents/Resources/${ICON_NAME}.icns"
# Legacy applet-bundle cleanup (no-ops on the hand-rolled bundle): Assets.car +
# CFBundleIconName override the .icns; applets also ship no bundle identifier.
rm -f "$APP/Contents/Resources/Assets.car"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.claude-shepherd.launcher" \
  "$APP/Contents/Info.plist" 2>/dev/null || true
touch "$APP"
echo "✅ installed shepherd icon into $APP (Resources/${ICON_NAME}.icns)"
