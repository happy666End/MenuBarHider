#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY-Developer ID Application}"
TEAM="${TEAM:?set TEAM to your Apple team id}"
PROFILE="${NOTARY_PROFILE:-notary-profile}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "Release signing requires a Developer ID Application identity." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' MenuBarHider/Resources/Info.plist)
APP=build/Build/Products/Release/MenuBarHider.app
RELEASE_DIR="dist/$VERSION"
if [[ -e "$RELEASE_DIR" ]]; then
  echo "Release output already exists: $RELEASE_DIR. Preserve it before retrying." >&2
  exit 1
fi
mkdir -p dist
RELEASE_STAGE=$(mktemp -d "dist/.release-$VERSION.XXXXXX")
ZIP="$RELEASE_STAGE/MenuBarHider-$VERSION.zip"
DMG="$RELEASE_STAGE/MenuBarHider-$VERSION.dmg"
DMG_STAGE=
cleanup() {
  local result=$?
  if [[ -n "$DMG_STAGE" && -d "$DMG_STAGE" ]]; then
    rm -rf "$DMG_STAGE"
  fi
  if [[ "$result" -ne 0 ]]; then
    echo "Release stopped. Diagnostics remain in $RELEASE_STAGE." >&2
  fi
}
trap cleanup EXIT

xcodegen generate --use-cache
xcodebuild -project MenuBarHider.xcodeproj -scheme MenuBarHider -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build 2>&1 | tee "$RELEASE_STAGE/build.log" | tail -3
codesign --verify --deep --strict "$APP"

# notarytool can exit successfully for a rejected archive.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$RELEASE_STAGE/notarize.log"
grep -Eq '^[[:space:]]*status: Accepted[[:space:]]*$' "$RELEASE_STAGE/notarize.log" || {
  echo "ZIP notarization failed. See $RELEASE_STAGE/notarize.log." >&2
  exit 1
}
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv -t exec "$APP"

DMG_STAGE=$(mktemp -d)
ditto "$APP" "$DMG_STAGE/MenuBarHider.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname MenuBarHider -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$RELEASE_STAGE/notarize-dmg.log"
grep -Eq '^[[:space:]]*status: Accepted[[:space:]]*$' "$RELEASE_STAGE/notarize-dmg.log" || {
  echo "DMG notarization failed. See $RELEASE_STAGE/notarize-dmg.log." >&2
  exit 1
}
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
(
  cd "$RELEASE_STAGE"
  shasum -a 256 "MenuBarHider-$VERSION.zip" "MenuBarHider-$VERSION.dmg" > SHA256SUMS
)
if [[ -e "$RELEASE_DIR" ]]; then
  echo "Release output appeared during the build: $RELEASE_DIR. Staged files are preserved." >&2
  exit 1
fi
mv "$RELEASE_STAGE" "$RELEASE_DIR"
cat "$RELEASE_DIR/SHA256SUMS"
echo "Release files: $RELEASE_DIR. Publish only the ZIP, DMG, and SHA256SUMS."
