#!/usr/bin/env bash
# Assembles a distributable Klart.app from the SwiftPM release build.
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

APP="dist/Klart.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Klart "$APP/Contents/MacOS/Klart"
cp Sources/KlartApp/Resources/Info.plist "$APP/Contents/Info.plist"

# Reuse the project icon if present (repo root /build/icon.icns).
if [ -f ../build/icon.icns ]; then
  cp ../build/icon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Both paths sign with the Hardened Runtime and the App Sandbox entitlements
# (sandbox + outgoing-network-only). The bundle is a single executable, so one
# codesign invocation covers it — no --deep needed.
ENTITLEMENTS="Scripts/Klart.entitlements"

if [ "$SIGN_IDENTITY" = "-" ]; then
  # Ad-hoc signature: fine for running locally, not for handing to anyone else.
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
    --sign - "$APP"
  echo "Built $APP (ad-hoc signed — only trusted on this Mac)"
else
  # Real identity + hardened runtime, required for notarization eligibility.
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "Built $APP (signed with: $SIGN_IDENTITY)"
  echo "Next: bash Scripts/notarize-app.sh   (to clear Gatekeeper for everyone)"
fi

# Fail the build if the sandbox or hardened runtime didn't take.
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
  || { echo "error: app-sandbox entitlement missing from signature" >&2; exit 1; }
codesign --display --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime" \
  || { echo "error: hardened runtime flag missing from signature" >&2; exit 1; }
echo "Verified: App Sandbox + Hardened Runtime present in signature"
