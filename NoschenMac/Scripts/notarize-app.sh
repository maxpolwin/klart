#!/usr/bin/env bash
# Notarizes and staples dist/Noschen.app after Scripts/make-app.sh has signed
# it with a real Developer ID Application identity. This is the step that
# actually removes the "Apple could not verify..." Gatekeeper warning for
# anyone besides you who opens the app.
#
# One-time setup (stores credentials in your login Keychain, not in the repo):
#
#   xcrun notarytool store-credentials "noschen-notary" \
#     --apple-id "you@example.com" \
#     --team-id "TEAM1234ID" \
#     --password "an-app-specific-password"
#
# The app-specific password comes from https://appleid.apple.com/account/manage
# (Sign-In and Security → App-Specific Passwords) — NOT your normal Apple ID
# password. Team ID is on https://developer.apple.com/account under Membership.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Noschen.app"
PROFILE="${NOTARY_PROFILE:-noschen-notary}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run Scripts/make-app.sh with SIGN_IDENTITY set first" >&2
  exit 1
fi

ZIP="dist/Noschen-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple for notarization (this can take a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling the notarization ticket to the app..."
xcrun stapler staple "$APP"

rm -f "$ZIP"
echo "Done. $APP is now notarized — verify with: spctl --assess --verbose \"$APP\""
