#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="artemsvit/Limit-Bar"
SCHEME="Limit Bar"
PROJECT="Limit Bar.xcodeproj"
APP_NAME="Limit Bar"
SPARKLE_ACCOUNT="limit-bar"
FEED_TAG="updates"
SPARKLE_FEED_URL="https://github.com/${REPO}/releases/download/${FEED_TAG}/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="96VpvrwjTO2r7k7pmBJdFzPVvDeYPbO+uXpPqEuoXzU="
PUBLIC_RELEASE_NOTES_URL_PREFIX="https://limitbar.artsvit.com/releases/"

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Usage: $0 <marketing-version> <build-number>"
  echo "Example: $0 1.0.1 2"
  exit 64
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required: https://cli.github.com/"
  exit 69
fi

TAG="v${VERSION}"
RELEASE_NAME="${APP_NAME} ${VERSION}"
ARCHIVE_ROOT="$ROOT_DIR/build/releases/${TAG}"
ARCHIVE_PATH="$ARCHIVE_ROOT/${APP_NAME}.xcarchive"
EXPORT_DIR="$ARCHIVE_ROOT/export"
UPDATES_DIR="$ARCHIVE_ROOT/updates"
ZIP_NAME="Limit-Bar-${VERSION}.zip"
ZIP_PATH="$UPDATES_DIR/$ZIP_NAME"
RELEASE_BODY_PATH="$UPDATES_DIR/Limit-Bar-${VERSION}.md"
NOTES_PATH="$UPDATES_DIR/Limit-Bar-${VERSION}.html"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"

rm -rf "$ARCHIVE_ROOT"
mkdir -p "$EXPORT_DIR" "$UPDATES_DIR"

TEMP_PRIVATE_KEY_PATH=""
cleanup() {
  if [[ -n "$TEMP_PRIVATE_KEY_PATH" ]]; then
    rm -f "$TEMP_PRIVATE_KEY_PATH"
  fi
}
trap cleanup EXIT

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  TEMP_PRIVATE_KEY_PATH="$ARCHIVE_ROOT/sparkle-private-key"
  rm -f "$TEMP_PRIVATE_KEY_PATH"
  Vendor/Sparkle/bin/generate_keys --account "$SPARKLE_ACCOUNT" -x "$TEMP_PRIVATE_KEY_PATH" >/dev/null
  SPARKLE_PRIVATE_KEY="$(<"$TEMP_PRIVATE_KEY_PATH")"
fi

if [[ "${UNSIGNED_RELEASE:-0}" == "1" ]]; then
  DERIVED_DATA="$ARCHIVE_ROOT/DerivedData"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
  APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
else
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
  APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
fi

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

RELEASE_BODY_SOURCE="$ROOT_DIR/docs/releases/Limit-Bar-${VERSION}.md"
if [[ -f "$RELEASE_BODY_SOURCE" ]]; then
  cp "$RELEASE_BODY_SOURCE" "$RELEASE_BODY_PATH"
else
  cat > "$RELEASE_BODY_PATH" <<EOF
# ${RELEASE_NAME}

Release ${VERSION} (${BUILD}).
EOF
fi

RELEASE_PAGE_SOURCE="$ROOT_DIR/Landing/releases/Limit-Bar-${VERSION}.html"
if [[ ! -f "$RELEASE_PAGE_SOURCE" ]]; then
  echo "Missing public release page: $RELEASE_PAGE_SOURCE"
  exit 67
fi
cp "$RELEASE_PAGE_SOURCE" "$NOTES_PATH"

RELEASE_ASSET_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

printf '%s' "$SPARKLE_PRIVATE_KEY" | Vendor/Sparkle/bin/generate_appcast \
  --ed-key-file - \
  --download-url-prefix "$RELEASE_ASSET_PREFIX" \
  --release-notes-url-prefix "$PUBLIC_RELEASE_NOTES_URL_PREFIX" \
  --maximum-versions 1 \
  "$UPDATES_DIR"

gh release create "$TAG" \
  "$ZIP_PATH" \
  "$RELEASE_BODY_PATH" \
  "$NOTES_PATH" \
  "$APPCAST_PATH" \
  --repo "$REPO" \
  --title "$RELEASE_NAME" \
  --notes-file "$RELEASE_BODY_PATH"

if ! gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$FEED_TAG" \
    --repo "$REPO" \
    --title "${APP_NAME} Update Feed" \
    --notes "Stable Sparkle update feed." \
    --prerelease
fi

gh release upload "$FEED_TAG" "$APPCAST_PATH" --repo "$REPO" --clobber

echo "Published $RELEASE_NAME"
echo "Sparkle feed: $SPARKLE_FEED_URL"
