#!/bin/bash
# Makes a notarized, stapled zip of Simple Battery in dist/, for handing out
# outside the App Store (the private IOBluetooth read rules the store out).
#
# One-time setup: a "Developer ID Application" certificate in the keychain, and
# notary credentials saved as the "notary" profile:
#   xcrun notarytool store-credentials notary --apple-id YOU@EXAMPLE.COM --team-id YOURTEAMID
#
# The release is signed with Developer ID rather than the self-signed identity
# build.sh uses, so a Mac running it asks for Bluetooth permission afresh.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Simple Battery"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="Developer ID Application"

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "No '$IDENTITY' certificate in the keychain. See the setup notes at the top of release.sh." >&2
  exit 1
fi

./build.sh bundle
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "build/$NAME.app/Contents/Info.plist")
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "build/$NAME.app"

mkdir -p dist
ZIP="dist/${NAME// /-}-$VERSION.zip"
ditto -c -k --keepParent "build/$NAME.app" "$ZIP"
# Keep Apple's whole answer, then look for "Accepted". Piping straight into
# grep -q reported an accepted submission as failed: grep quits at its first
# match, and under pipefail the broken pipe left behind counts as an error.
RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr) || true
if ! grep -q "status: Accepted" <<<"$RESULT"; then
  echo "Notarization failed. For details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
  exit 1
fi
# Staple the ticket to the app so Gatekeeper can check it offline, then zip again.
xcrun stapler staple "build/$NAME.app"
rm "$ZIP"
ditto -c -k --keepParent "build/$NAME.app" "$ZIP"
rm -rf build
echo "Notarized: $ZIP"
