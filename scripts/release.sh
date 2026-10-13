#!/bin/bash
# Cut a release: bump VERSION, test, build + sign + notarize, sign for Sparkle and update appcast.xml,
# tag, publish a GitHub release with the DMG, then push main (which makes the update feed live).
#
#   ./scripts/release.sh 0.5.1             full release (also installs it locally)
#   ./scripts/release.sh 0.5.1 --dry-run   everything up to the notarized DMG; no commit, tag, push or release
#   ./scripts/release.sh 0.5.1 --no-install
#
# Release notes come from CHANGELOG.md: the "## [Unreleased]" section is renamed to the new version.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
DRY=0; INSTALL=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

REPO="seamoss/Landfall"
NOTARY_PROFILE="${NOTARY_PROFILE:-landfall-notary}"
TAG="v$VERSION"
DMG="dist/Landfall-$VERSION.dmg"
fail() { echo "✗ $*" >&2; exit 1; }

# ── Preflight ──────────────────────────────────────────────────────────────
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh <major.minor.patch> [--dry-run] [--no-install]"
[ "$(git branch --show-current)" = "main" ] || fail "release from main"
[ -z "$(git status --porcelain)" ] || fail "working tree has uncommitted changes"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in sync with origin/main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "no notarytool profile \"$NOTARY_PROFILE\" — releases must be notarized (see README › Releasing)"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve >/dev/null
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 || fail "no Sparkle signing key in the keychain (see README › Releasing)"
grep -q '^## \[Unreleased\]' CHANGELOG.md || fail "CHANGELOG.md has no \"## [Unreleased]\" section"
NOTES_BODY="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | sed -e '/./,$!d')"
[ -n "$(echo "$NOTES_BODY" | tr -d '[:space:]')" ] || fail "the Unreleased section of CHANGELOG.md is empty"

PREV_VERSION="$(cat VERSION)"
restore() { echo "$PREV_VERSION" > VERSION; git checkout -q -- CHANGELOG.md appcast.xml; }
[ $DRY = 1 ] && trap restore EXIT

echo "▸ Releasing $TAG (was $PREV_VERSION)$([ $DRY = 1 ] && echo ' — dry run')"
echo "$VERSION" > VERSION
TODAY="$(date +%Y-%m-%d)"
sed -i '' "s/^## \[Unreleased\]/## [Unreleased]\\
\\
## [$VERSION] - $TODAY/" CHANGELOG.md

# ── Build ──────────────────────────────────────────────────────────────────
echo "▸ Tests"
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
swift test >/dev/null 2>&1 || fail "tests failed"

echo "▸ Package, sign, notarize"
./scripts/package.sh
xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "$DMG is not notarized/stapled"
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rejects $DMG"
spctl -a -t execute dist/Landfall.app 2>/dev/null || fail "Gatekeeper rejects Landfall.app"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"

echo "▸ Sparkle feed"
BUILD_NUM="$(defaults read "$PWD/dist/Landfall.app/Contents/Info.plist" CFBundleVersion)"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"
echo "$NOTES_BODY" > dist/changelog-section.md
python3 scripts/appcast.py --version "$VERSION" --build "$BUILD_NUM" \
  --url "https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" \
  --signature "$SIGNATURE" --notes dist/changelog-section.md \
  --notes-link "https://github.com/$REPO/releases/tag/$TAG"
xmllint --noout appcast.xml || fail "appcast.xml is not valid XML"

NOTES="dist/release-notes-$VERSION.md"
{
  echo "$NOTES_BODY"
  echo
  echo "## Install"
  echo "Download \`$(basename "$DMG")\`, open it and drag Landfall to Applications. Signed with Developer ID and notarized by Apple."
  echo "Requires macOS 14 or later; Apple Silicon and Intel. Updating: quit Landfall from its menu first."
  echo
  echo "SHA-256: \`$SHA\`"
} > "$NOTES"

if [ $DRY = 1 ]; then
  echo "✓ Dry run complete: $DMG is notarized. Notes preview: $NOTES"
  exit 0
fi

# ── Publish ────────────────────────────────────────────────────────────────
echo "▸ Commit, tag, push"
git add VERSION CHANGELOG.md appcast.xml
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Landfall $VERSION"
# The tag first: the feed on main must not point at a DMG that isn't uploaded yet.
git push -q origin "$TAG"

echo "▸ GitHub release"
TITLE="Landfall $VERSION"
FIRST="$(echo "$NOTES_BODY" | grep -m1 -E '^### |^- ' | sed -E 's/^(### |- )//; s/\*\*//g; s/[:.].*$//')"
[ -n "$FIRST" ] && TITLE="$TITLE — $FIRST"
gh release create "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES" "$DMG" "$DMG.sha256"

echo "▸ Publishing the update feed"
git push -q origin main

if [ $INSTALL = 1 ]; then
  echo "▸ Installing locally"
  ./scripts/install.sh
fi

echo "✓ $(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
