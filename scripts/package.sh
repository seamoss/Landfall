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

echo "▸ Icon (Icon Composer layers → Liquid Glass on macOS 26, flat icns for older)"
[ -d Resources/Landfall.icon ] || swift scripts/make-icon.swift icon Resources/Landfall.icon
ICONOUT="$(mktemp -d)"
# actool needs an absolute path to the .icon document.
xcrun actool --compile "$ICONOUT" --platform macosx --minimum-deployment-target 14.0 --app-icon Landfall \
  --output-partial-info-plist "$ICONOUT/partial.plist" "$PWD/Resources/Landfall.icon" >/dev/null
[ -f "$ICONOUT/Assets.car" ] || { echo "actool failed to compile the icon"; exit 1; }

echo "▸ Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Landfall"
cp "$ICONOUT/Assets.car" "$ICONOUT/Landfall.icns" "$APP/Contents/Resources/"
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
