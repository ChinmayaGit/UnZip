#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INSTALL_LOCAL=0
UNIVERSAL=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_LOCAL=1 ;;
    --arm64-only) UNIVERSAL=0 ;;
  esac
done

BIN=""
if [[ "$UNIVERSAL" -eq 1 ]]; then
  swift build -c release --arch arm64 --product UnZip
  swift build -c release --arch x86_64 --product UnZip
  ARM="$(find "$ROOT/.build" -path '*arm64*release/UnZip' -type f | head -n 1)"
  X86="$(find "$ROOT/.build" -path '*x86_64*release/UnZip' -type f | head -n 1)"
  if [[ -n "$ARM" && -n "$X86" ]]; then
    BIN="$ROOT/.build/UnZip-universal"
    lipo -create "$ARM" "$X86" -output "$BIN"
  fi
fi

if [[ -z "$BIN" ]]; then
  swift build -c release --product UnZip
  BIN="$ROOT/.build/release/UnZip"
fi

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

mkdir -p "$APP/Contents/Library/Services"
cp -R "$ROOT/Resources/Zip with UnZip.workflow" "$APP/Contents/Library/Services/"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

if [[ "$INSTALL_LOCAL" -eq 1 ]]; then
  USER_APPS="$HOME/Applications"
  mkdir -p "$USER_APPS"
  rm -rf "$USER_APPS/UnZip.app"
  cp -R "$APP" "$USER_APPS/UnZip.app"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$USER_APPS/UnZip.app" >/dev/null 2>&1 || true
  fi
  echo "Installed $USER_APPS/UnZip.app"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/UnZip" 2>/dev/null || echo unknown))"
