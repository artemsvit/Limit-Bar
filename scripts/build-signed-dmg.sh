#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="Limit Bar"
PROJECT="Limit Bar.xcodeproj"
APP_NAME="Limit Bar"
TEAM_ID="${TEAM_ID:-8KK8V96Q6B}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Artem Svitelskyi (${TEAM_ID})}"
NOTARY_PROFILE="${NOTARY_PROFILE:-LimitBarNotary}"
NOTARIZE="${NOTARIZE:-0}"

SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/artemsvit/Limit-Bar/releases/download/updates/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-96VpvrwjTO2r7k7pmBJdFzPVvDeYPbO+uXpPqEuoXzU=}"

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Usage: $0 <marketing-version> <build-number>"
  echo "Example: NOTARIZE=1 $0 1.0.3 4"
  exit 64
fi

if ! security find-identity -v -p codesigning | grep -Fq "$DEVELOPER_ID_APPLICATION"; then
  echo "Missing signing identity: $DEVELOPER_ID_APPLICATION"
  echo "Install your Developer ID Application certificate in Keychain Access, then retry."
  exit 65
fi

DIST_ROOT="$ROOT_DIR/build/distribution/v${VERSION}"
ARCHIVE_PATH="$DIST_ROOT/${APP_NAME}.xcarchive"
STAGING_DIR="$DIST_ROOT/dmg-root"
ARTIFACTS_DIR="$DIST_ROOT/artifacts"
DMG_PATH="$ARTIFACTS_DIR/Limit-Bar-${VERSION}.dmg"

rm -rf "$DIST_ROOT"
mkdir -p "$STAGING_DIR" "$ARTIFACTS_DIR"

echo "Archiving $APP_NAME $VERSION ($BUILD) with Developer ID..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive did not produce app bundle: $APP_PATH"
  exit 66
fi

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | sed -n '/Authority=/p;/TeamIdentifier=/p;/Runtime Version=/p'

echo "Preparing DMG contents..."
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG..."
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

echo "Signing DMG..."
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting DMG for notarization with profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "Checking Gatekeeper assessment..."
  spctl -a -vv --type open "$DMG_PATH"
else
  echo "Notarization skipped. This DMG is signed but is not Gatekeeper-ready until notarized and stapled."
  echo "To create a Gatekeeper-ready DMG, store notary credentials and rerun:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id-email> --team-id $TEAM_ID --password <app-specific-password>"
  echo "  NOTARIZE=1 $0 $VERSION $BUILD"
fi

echo "Signed app: $APP_PATH"
echo "Signed DMG: $DMG_PATH"
