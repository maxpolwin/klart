#!/usr/bin/env bash
# Assembles a distributable Noschen.app from the SwiftPM release build.
#
# By default this ad-hoc signs the bundle (fine for running on your own Mac).
# To sign with your own Developer ID so Gatekeeper doesn't warn other people
# who download it, pass your signing identity as SIGN_IDENTITY:
#
#   security find-identity -v -p codesigning        # find the exact name
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAM1234ID)" \
#     bash Scripts/make-app.sh
#
# A Developer ID signature alone still shows an "unidentified developer"
# prompt once for anything downloaded from the internet until it's also
# notarized — see Scripts/notarize-app.sh after this script succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release

APP="dist/Noschen.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Noschen "$APP/Contents/MacOS/Noschen"
cp Sources/NoschenApp/Resources/Info.plist "$APP/Contents/Info.plist"

# Reuse the project icon if present (repo root /build/icon.icns).
if [ -f ../build/icon.icns ]; then
  cp ../build/icon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  # Ad-hoc signature: fine for running locally, not for handing to anyone else.
  codesign --force --deep --sign - "$APP"
  echo "Built $APP (ad-hoc signed — only trusted on this Mac)"
else
  # Real identity + hardened runtime, required for notarization eligibility.
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "Built $APP (signed with: $SIGN_IDENTITY)"
  echo "Next: bash Scripts/notarize-app.sh   (to clear Gatekeeper for everyone)"
fi
