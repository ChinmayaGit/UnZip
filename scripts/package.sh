#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
STAGE="$ROOT/.build/installer"
DMG_STAGE="$STAGE/dmg"
PKG_ROOT="$STAGE/pkgroot"
SCRIPTS="$STAGE/scripts"

"$ROOT/scripts/build-app.sh"

APP="$DIST/UnZip.app"
[[ -d "$APP" ]] || { echo "Missing $APP" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$DMG_STAGE" "$PKG_ROOT" "$SCRIPTS"

cp -R "$APP" "$DMG_STAGE/UnZip.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$ROOT/scripts/installer/How to Install.txt" "$DMG_STAGE/How to Install.txt"

DMG="$DIST/UnZip-$VERSION.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "UnZip $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

ZIP="$DIST/UnZip-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

cp -R "$APP" "$PKG_ROOT/UnZip.app"
cp "$ROOT/scripts/installer/postinstall" "$SCRIPTS/postinstall"
chmod +x "$SCRIPTS/postinstall"

COMPONENT="$STAGE/UnZip-component.pkg"
pkgbuild \
  --root "$PKG_ROOT" \
  --identifier com.unzip.app \
  --version "$VERSION" \
  --install-location /Applications \
  --scripts "$SCRIPTS" \
  "$COMPONENT" >/dev/null

RESOURCES="$STAGE/resources"
mkdir -p "$RESOURCES"
cp "$ROOT/scripts/installer/welcome.html" "$RESOURCES/"
cp "$ROOT/scripts/installer/conclusion.html" "$RESOURCES/"
cp "$ROOT/scripts/installer/distribution.xml" "$STAGE/distribution.xml"

PKG="$DIST/UnZip-$VERSION.pkg"
rm -f "$PKG"
productbuild \
  --distribution "$STAGE/distribution.xml" \
  --resources "$RESOURCES" \
  --package-path "$STAGE" \
  "$PKG" >/dev/null

# Ad-hoc sign the installer so it is at least consistent; Gatekeeper
# still requires a Developer ID + notarization for a silent first open.
productsign --sign - "$PKG" "$PKG.signed" >/dev/null 2>&1 && mv "$PKG.signed" "$PKG" || true

cat <<EOF
Installer files:

  $DMG
  $PKG
  $ZIP

Share any of these. Recipients need macOS 14 or later.
Without an Apple Developer ID the first launch may require
Control-click → Open.
EOF
