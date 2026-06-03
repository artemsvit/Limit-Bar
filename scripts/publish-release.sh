#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="artemsvit/Limit-Bar"
SCHEME="Limit Bar"
PROJECT="Limit Bar.xcodeproj"
APP_NAME="Limit Bar"
SPARKLE_ACCOUNT="limit-bar"
SPARKLE_FEED_URL="https://github.com/${REPO}/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="96VpvrwjTO2r7k7pmBJdFzPVvDeYPbO+uXpPqEuoXzU="

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

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  Vendor/Sparkle/bin/generate_keys --account "$SPARKLE_ACCOUNT" -p >/dev/null
fi

TAG="v${VERSION}"
RELEASE_NAME="${APP_NAME} ${VERSION}"
ARCHIVE_ROOT="$ROOT_DIR/build/releases/${TAG}"
ARCHIVE_PATH="$ARCHIVE_ROOT/${APP_NAME}.xcarchive"
EXPORT_DIR="$ARCHIVE_ROOT/export"
UPDATES_DIR="$ARCHIVE_ROOT/updates"
ZIP_NAME="Limit-Bar-${VERSION}.zip"
ZIP_PATH="$UPDATES_DIR/$ZIP_NAME"
NOTES_PATH="$UPDATES_DIR/Limit-Bar-${VERSION}.md"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"

rm -rf "$ARCHIVE_ROOT"
mkdir -p "$EXPORT_DIR" "$UPDATES_DIR"

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

cat > "$NOTES_PATH" <<EOF
# ${RELEASE_NAME}

Release ${VERSION} (${BUILD}).
EOF

DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | Vendor/Sparkle/bin/generate_appcast \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-versions 1 \
    "$UPDATES_DIR"
else
  Vendor/Sparkle/bin/generate_appcast \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-versions 1 \
    "$UPDATES_DIR"
fi

gh release create "$TAG" \
  "$ZIP_PATH" \
  "$APPCAST_PATH" \
  --repo "$REPO" \
  --title "$RELEASE_NAME" \
  --notes-file "$NOTES_PATH"

echo "Published $RELEASE_NAME"
echo "Sparkle feed: $SPARKLE_FEED_URL"
