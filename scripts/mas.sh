#!/bin/bash
# Build the Mac App Store edition: generate the Xcode project, archive, and export a signed .pkg.
#   ./scripts/mas.sh            → dist/mas/Landfall.pkg (ready for Transporter / App Store Connect)
#   ./scripts/mas.sh --upload   → also upload the build to App Store Connect (TestFlight)
set -euo pipefail
cd "$(dirname "$0")/.."
export LANDFALL_VERSION="$(cat VERSION)"
export LANDFALL_BUILD="${LANDFALL_BUILD:-$(date +%Y%m%d%H%M)}"
OUT=dist/mas
ARCHIVE="$OUT/Landfall.xcarchive"

echo "▸ Generating Landfall.xcodeproj ($LANDFALL_VERSION, build $LANDFALL_BUILD)"
xcodegen generate --quiet
rm -rf "$OUT" && mkdir -p "$OUT"

echo "▸ Archiving (Mac App Store, sandboxed)"
xcodebuild -project Landfall.xcodeproj -scheme Landfall -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  archive -quiet

APP="$ARCHIVE/Products/Applications/Landfall.app"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
  || { echo "✗ the archived app is not sandboxed"; exit 1; }
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] && { echo "✗ Sparkle must not ship in the App Store build"; exit 1; }

echo "▸ Exporting for App Store Connect"
OPTIONS="$OUT/ExportOptions.plist"
cp scripts/ExportOptions-MAS.plist "$OPTIONS"
if [ "${1:-}" = "--upload" ]; then /usr/libexec/PlistBuddy -c "Set :destination upload" "$OPTIONS"; fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates -quiet

ls "$OUT"/*.pkg >/dev/null 2>&1 && echo "✓ $(ls "$OUT"/*.pkg)"
[ "${1:-}" = "--upload" ] && echo "✓ Uploaded build $LANDFALL_BUILD to App Store Connect"
echo "✓ $ARCHIVE"
