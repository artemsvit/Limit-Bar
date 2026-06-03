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
VOLUME_NAME="${APP_NAME} ${VERSION}"
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

generate_dmg_background() {
  local output_path="$1"

  xcrun swift - "$output_path" "$VERSION" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let version = CommandLine.arguments[2]
let size = NSSize(width: 720, height: 440)
let image = NSImage(size: size)

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    stroke.setStroke()
    path.lineWidth = lineWidth
    path.stroke()
}

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    value.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

image.lockFocus()

NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.082, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.105, green: 0.110, blue: 0.120, alpha: 1),
    NSColor(calibratedRed: 0.050, green: 0.052, blue: 0.058, alpha: 1)
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 90)

NSColor(calibratedRed: 0.26, green: 0.82, blue: 0.90, alpha: 0.16).setFill()
NSBezierPath(ovalIn: NSRect(x: -90, y: 210, width: 290, height: 290)).fill()
NSColor(calibratedRed: 0.62, green: 0.40, blue: 0.96, alpha: 0.14).setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: -120, width: 280, height: 280)).fill()

roundedRect(
    NSRect(x: 32, y: 32, width: 656, height: 376),
    radius: 28,
    fill: NSColor(calibratedWhite: 1, alpha: 0.035),
    stroke: NSColor(calibratedWhite: 1, alpha: 0.070)
)

text("Limit Bar", x: 58, y: 345, size: 36, weight: .bold, color: NSColor(calibratedWhite: 0.94, alpha: 1))
text("Drag to Applications", x: 60, y: 315, size: 17, weight: .semibold, color: NSColor(calibratedWhite: 0.68, alpha: 1))
text("Version \(version)", x: 588, y: 353, size: 13, weight: .semibold, color: NSColor(calibratedWhite: 0.55, alpha: 1))

let leftPanel = NSRect(x: 104, y: 115, width: 184, height: 176)
let rightPanel = NSRect(x: 428, y: 115, width: 184, height: 176)
roundedRect(leftPanel, radius: 22, fill: NSColor(calibratedWhite: 1, alpha: 0.040), stroke: NSColor(calibratedRed: 0.34, green: 0.85, blue: 0.92, alpha: 0.22))
roundedRect(rightPanel, radius: 22, fill: NSColor(calibratedWhite: 1, alpha: 0.040), stroke: NSColor(calibratedRed: 0.62, green: 0.43, blue: 0.96, alpha: 0.24))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 326, y: 205))
arrow.line(to: NSPoint(x: 394, y: 205))
arrow.move(to: NSPoint(x: 381, y: 220))
arrow.line(to: NSPoint(x: 396, y: 205))
arrow.line(to: NSPoint(x: 381, y: 190))
NSColor(calibratedWhite: 0.86, alpha: 0.56).setStroke()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

NSColor(calibratedRed: 0.31, green: 0.84, blue: 0.91, alpha: 0.62).setFill()
NSBezierPath(roundedRect: NSRect(x: 60, y: 62, width: 108, height: 5), xRadius: 3, yRadius: 3).fill()
NSColor(calibratedRed: 0.60, green: 0.41, blue: 0.95, alpha: 0.56).setFill()
NSBezierPath(roundedRect: NSRect(x: 174, y: 62, width: 84, height: 5), xRadius: 3, yRadius: 3).fill()
NSColor(calibratedRed: 0.98, green: 0.37, blue: 0.28, alpha: 0.55).setFill()
NSBezierPath(roundedRect: NSRect(x: 264, y: 62, width: 58, height: 5), xRadius: 3, yRadius: 3).fill()

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

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | sed -n '/Authority=/p;/TeamIdentifier=/p;/Runtime Version=/p'

echo "Preparing DMG contents..."
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
generate_dmg_background "$STAGING_DIR/.background/background.png"

echo "Creating DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$DMG_RW_PATH"

echo "Applying DMG Finder layout..."
ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW_PATH" -readwrite -noverify -noautoopen)"
DMG_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
VOLUME_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n 's#^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*##p' | head -n 1)"
if [[ -z "$DMG_DEVICE" || -z "$VOLUME_PATH" || ! -d "$VOLUME_PATH" ]]; then
  echo "Could not mount read/write DMG."
  printf '%s\n' "$ATTACH_OUTPUT"
  exit 67
fi

osascript <<EOF
tell application "Finder"
  activate
  open POSIX file "$VOLUME_PATH"
  delay 1
  set theWindow to container window of disk "$VOLUME_NAME"
  set current view of theWindow to icon view
  set toolbar visible of theWindow to false
  set statusbar visible of theWindow to false
  set bounds of theWindow to {120, 120, $((120 + DMG_WINDOW_WIDTH)), $((120 + DMG_WINDOW_HEIGHT))}
  set theViewOptions to icon view options of theWindow
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to 96
  set background picture of theViewOptions to ((POSIX file "$VOLUME_PATH/.background/background.png") as alias)
  set position of item "${APP_NAME}.app" of theWindow to {196, 236}
  set position of item "Applications" of theWindow to {520, 236}
  delay 3
  close theWindow
end tell
EOF

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
  spctl -a -vv --type open "$DMG_PATH"
else
  echo "Notarization skipped. This DMG is signed but is not Gatekeeper-ready until notarized and stapled."
  echo "To create a Gatekeeper-ready DMG, store notary credentials and rerun:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id-email> --team-id $TEAM_ID --password <app-specific-password>"
  echo "  NOTARIZE=1 $0 $VERSION $BUILD"
fi

echo "Signed app: $APP_PATH"
echo "Signed DMG: $DMG_PATH"
