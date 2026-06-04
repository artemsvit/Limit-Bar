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
DMG_WINDOW_WIDTH=720
DMG_WINDOW_HEIGHT=440

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
VOLUME_NAME="$APP_NAME"
DMG_DS_STORE_TEMPLATE="$ROOT_DIR/Packaging/dmg/.DS_Store"
APP_NOTARY_ZIP_PATH="$ARTIFACTS_DIR/Limit-Bar-${VERSION}-app-notary.zip"
DMG_RW_PATH="$ARTIFACTS_DIR/Limit-Bar-${VERSION}-rw.dmg"
DMG_PATH="$ARTIFACTS_DIR/Limit-Bar-${VERSION}.dmg"
DMG_DEVICE=""

detach_dmg() {
  if [[ -n "$DMG_DEVICE" ]]; then
    hdiutil detach "$DMG_DEVICE" -quiet || true
    DMG_DEVICE=""
  fi
}
trap detach_dmg EXIT

resign_sparkle_bundle() {
  local sparkle_base="$1"

  local nested_targets=(
    "$sparkle_base/Autoupdate"
    "$sparkle_base/XPCServices/Downloader.xpc"
    "$sparkle_base/XPCServices/Installer.xpc"
    "$sparkle_base/Updater.app"
  )

  for target in "${nested_targets[@]}"; do
    if [[ -e "$target" ]]; then
      codesign --force \
        --sign "$DEVELOPER_ID_APPLICATION" \
        --timestamp \
        --options runtime \
        --preserve-metadata=identifier,entitlements,flags \
        "$target"
    fi
  done

  codesign --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --timestamp \
    --options runtime \
    --preserve-metadata=identifier,entitlements,flags \
    "$sparkle_base"
}

generate_dmg_background() {
  local output_path="$1"

  xcrun swift - "$output_path" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 720, height: 440)
let image = NSImage(size: size)

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    value.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

image.lockFocus()

NSColor(calibratedRed: 0.965, green: 0.968, blue: 0.972, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
    NSColor(calibratedRed: 0.930, green: 0.940, blue: 0.950, alpha: 1)
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 90)

text("Limit Bar", x: 76, y: 350, size: 34, weight: .bold, color: NSColor(calibratedWhite: 0.13, alpha: 1))
text("Drag to Applications", x: 78, y: 318, size: 17, weight: .medium, color: NSColor(calibratedWhite: 0.42, alpha: 1))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 326, y: 205))
arrow.line(to: NSPoint(x: 394, y: 205))
arrow.move(to: NSPoint(x: 381, y: 220))
arrow.line(to: NSPoint(x: 396, y: 205))
arrow.line(to: NSPoint(x: 381, y: 190))
NSColor(calibratedWhite: 0.48, alpha: 0.65).setStroke()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Could not render DMG background")
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT
}

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

echo "Re-signing nested Sparkle components..."
SPARKLE_BASE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE_BASE" ]]; then
  resign_sparkle_bundle "$SPARKLE_BASE"
  codesign --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --timestamp \
    --options runtime \
    --preserve-metadata=identifier,entitlements,flags \
    "$APP_PATH"
fi

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | sed -n '/Authority=/p;/TeamIdentifier=/p;/Runtime Version=/p'

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting app for notarization with profile: $NOTARY_PROFILE"
  ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP_PATH"
  xcrun notarytool submit "$APP_NOTARY_ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "Stapling app notarization ticket..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  rm -f "$APP_NOTARY_ZIP_PATH"
fi

echo "Preparing DMG contents..."
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
generate_dmg_background "$STAGING_DIR/.background/background.png"
SetFile -a V "$STAGING_DIR/.background" 2>/dev/null || true
if [[ ! -f "$DMG_DS_STORE_TEMPLATE" ]]; then
  echo "Missing DMG Finder layout template: $DMG_DS_STORE_TEMPLATE"
  exit 68
fi
cp "$DMG_DS_STORE_TEMPLATE" "$STAGING_DIR/.DS_Store"

echo "Creating DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$DMG_RW_PATH"

echo "Verifying DMG Finder layout..."
ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW_PATH" -readwrite -noverify -noautoopen)"
DMG_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
VOLUME_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n 's#^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*##p' | head -n 1)"
if [[ -z "$DMG_DEVICE" || -z "$VOLUME_PATH" || ! -d "$VOLUME_PATH" ]]; then
  echo "Could not mount read/write DMG."
  printf '%s\n' "$ATTACH_OUTPUT"
  exit 67
fi

if [[ ! -f "$VOLUME_PATH/.DS_Store" || ! -f "$VOLUME_PATH/.background/background.png" ]]; then
  echo "DMG is missing Finder layout metadata or background artwork."
  exit 68
fi

sync
sleep 1
detach_dmg

echo "Compressing DMG..."
hdiutil convert "$DMG_RW_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$DMG_PATH"
rm -f "$DMG_RW_PATH"

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
  spctl -a -vv --type open --context context:primary-signature "$DMG_PATH"
else
  echo "Notarization skipped. This DMG is signed but is not Gatekeeper-ready until notarized and stapled."
  echo "To create a Gatekeeper-ready DMG, store notary credentials and rerun:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id-email> --team-id $TEAM_ID --password <app-specific-password>"
  echo "  NOTARIZE=1 $0 $VERSION $BUILD"
fi

echo "Signed app: $APP_PATH"
echo "Signed DMG: $DMG_PATH"
