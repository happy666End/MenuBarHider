#!/bin/bash
# Builds a signed, notarized MenuBarHider zip for a GitHub release into dist/.
# Needs: a "Developer ID Application" certificate in Keychain, a notarytool keychain profile
# (default "notary-profile", created with `xcrun notarytool store-credentials`), and xcodegen.
# Usage: TEAM=XXXXXXXXXX scripts/release.sh   (or `make release` with TEAM in local.mk)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM="${TEAM:?set TEAM to your Apple team id}"
PROFILE="${NOTARY_PROFILE:-notary-profile}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' MenuBarHider/Resources/Info.plist)
APP=build/Build/Products/Release/MenuBarHider.app
ZIP="dist/MenuBarHider-$VERSION.zip"

xcodegen generate --use-cache
xcodebuild -project MenuBarHider.xcodeproj -scheme MenuBarHider -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build | tail -3   # no get-task-allow: Apple rejects it
codesign --verify --deep --strict "$APP"

rm -rf dist && mkdir -p dist
ditto -c -k --keepParent "$APP" "$ZIP"
# notarytool exits 0 even when Apple rejects the archive, so check the verdict ourselves.
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee dist/notarize.log
grep -q 'status: Accepted' dist/notarize.log || { echo "notarization failed, see dist/notarize.log"; exit 1; }
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the download carries the stapled ticket
spctl -a -vv -t exec "$APP"
shasum -a 256 "$ZIP"
