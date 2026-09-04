#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product UnZip

BIN="$ROOT/.build/release/UnZip"
APP="$ROOT/dist/UnZip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/UnZip"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICON_PNG="$ROOT/.build/icon-1024.png"
ICONSET="$ROOT/.build/UnZip.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$ROOT/scripts/make-icon.swift" "$ICON_PNG"

if [[ -f "$ICON_PNG" ]]; then
  for dim in 16 32 64 128 256 512; do
    sips -z $dim $dim "$ICON_PNG" --out "$ICONSET/icon_${dim}x${dim}.png" >/dev/null
    sips -z $((dim*2)) $((dim*2)) "$ICON_PNG" --out "$ICONSET/icon_${dim}x${dim}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist" 2>/dev/null || true
fi

chmod +x "$APP/Contents/MacOS/UnZip"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
