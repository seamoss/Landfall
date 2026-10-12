#!/bin/bash
# Build a universal, signed (and, if credentials are stored, notarized) Landfall.app and DMG in dist/.
#   IDENTITY        signing identity (default: your Developer ID Application certificate)
#   NOTARY_PROFILE  notarytool keychain profile (default: landfall-notary); skipped if missing
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application: SEANAN MC CULLOUGH (4J2T5H73JM)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-landfall-notary}"
VERSION="$(cat VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
APP=dist/Landfall.app
DMG="dist/Landfall-$VERSION.dmg"

echo "▸ Building universal release ($VERSION, build $BUILD)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/landfall"

echo "▸ Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
[ -f Resources/icon-1024.png ] || swift scripts/make-icon.swift Resources/icon-1024.png 1024
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "▸ Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Landfall"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R extras "$APP/Contents/Resources/extras" 2>/dev/null || true

echo "▸ Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --entitlements Resources/Landfall.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Landfall $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▸ Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP"
else
  echo "▸ Skipping notarization: no notarytool profile \"$NOTARY_PROFILE\". Store one with:"
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your-apple-id> --team-id 4J2T5H73JM"
fi

shasum -a 256 "$DMG"
echo "✓ $APP"
echo "✓ $DMG"
