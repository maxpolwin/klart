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
#
# Scripts/Klart.entitlements also carries keychain-access-groups for the Xcode
# build. That entitlement is restricted — it must be backed by a provisioning
# profile, which this script never embeds — so sign with a copy that omits it
# (a signature claiming it without a profile is killed at launch). The result
# has no data-protection keychain: no stored API keys, no vault, no Touch ID.
# Run the Xcode build (Scripts/generate-xcodeproj.sh) for those.
ENT_DIR="$(mktemp -d)"
trap 'rm -rf "$ENT_DIR"' EXIT
ENTITLEMENTS="$ENT_DIR/Klart.entitlements"
cp Scripts/Klart.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ENTITLEMENTS"

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
#
# Each signature is read back into a variable before being matched. Piping
# codesign straight into `grep -q` reads as equivalent and is not: `grep -q`
# exits the moment it matches, which closes the pipe, so codesign takes SIGPIPE
# on its next write and dies with 141 — and `pipefail` at the top of this script
# then reports that as this check failing. The runtime check below failed that
# way on every single run; the entitlements one escaped it only by writing
# little enough to finish before grep left.
if ! entitlements="$(codesign --display --entitlements - "$APP" 2>/dev/null)"; then
  echo "error: could not read the signature's entitlements back" >&2
  exit 1
fi
if ! signature="$(codesign --display --verbose=4 "$APP" 2>&1)"; then
  echo "error: could not read the signature back: $signature" >&2
  exit 1
fi

grep -q "com.apple.security.app-sandbox" <<< "$entitlements" \
  || { echo "error: app-sandbox entitlement missing from signature" >&2; exit 1; }

# The line this matches reads e.g.
#   CodeDirectory v=20500 size=8206 flags=0x10002(adhoc,runtime) hashes=246+7
# The flag has to sit inside the flags token itself, so that the unrelated
# "Runtime Version=26.5.0" printed a few lines further down cannot satisfy it.
grep -q "flags=[^ ]*runtime" <<< "$signature" \
  || { echo "error: hardened runtime flag missing from signature" >&2
       echo "       codesign reported: $(grep -m1 "flags=" <<< "$signature" || true)" >&2
       exit 1; }

echo "Verified: App Sandbox + Hardened Runtime present in signature"
